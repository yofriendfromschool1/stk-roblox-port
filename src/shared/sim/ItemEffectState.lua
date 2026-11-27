--!strict
-- src/shared/sim/ItemEffectState.lua
-- SPDX-License-Identifier: GPL-3.0-or-later
-- ported from src/karts/explosion_animation.cpp:L44-L287,
-- src/karts/abstract_kart_animation.cpp:L41-L134, and
-- src/karts/kart.cpp:L1160-L1180, L1500-L1501, L1862-L1882, L2791-L2798 (STK 1.5)
-- Unified kart item-hit effect state machine (explosion stop/arc, squash slowdown, floor bubblegum stall).

local FixedStep = require("./FixedStep")
local ItemTuning = require("../ItemTuning")
local Math3D = require("./Math3D")

type Vec3 = Math3D.Vec3
type Quat = Math3D.Quat

local ItemEffectState = {}

ItemEffectState.EFFECT_NONE = 0
ItemEffectState.EFFECT_EXPLOSION = 1
ItemEffectState.EFFECT_SQUASH = 2
ItemEffectState.EFFECT_BUBBLEGUM_SLOW = 3
ItemEffectState.EFFECT_RESCUE = 4

ItemEffectState.RESCUE_DURATION_SEC = 1.2 -- data/kart_characteristics.xml:L292
ItemEffectState.RESCUE_HEIGHT_M = 2.0 -- data/kart_characteristics.xml:L292
ItemEffectState.RESCUE_LIFT_FRACTION = 0.4 -- src/karts/rescue_animation.cpp:L140

ItemEffectState.EFFECT_NAMES = table.freeze({
	[0] = "NONE",
	[1] = "EXPLOSION",
	[2] = "SQUASH",
	[3] = "BUBBLEGUM_SLOW",
	[4] = "RESCUE",
})

export type State = {
	effectType: number,
	ticksRemaining: number,
	totalTicks: number,
	suppressThrottle: boolean,
	suppressSteer: boolean,
	suppressDrift: boolean,
	suppressFire: boolean,
	invulnerableTicks: number,
	originPos: Vec3,
	originRot: Quat,
	normal: Vec3,
	initUpVel: number,
	gravity: number,
	addHeadingRate: number,
	addPitchRate: number,
	addRollRate: number,
	torqueSign: boolean,
	slowdownFraction: number,
	parachuteDragActive: boolean,
	plungerFaceTicks: number,
	externalPullAccel: Vec3,
	externalPullTicks: number,
	rescueTargetPos: Vec3,
	rescueTargetRot: Quat,
	rescueHeight: number,
}

export type NetEffectState = {
	effectType: number,
	ticksRemaining: number,
	totalTicks: number,
	suppressThrottle: boolean,
	suppressSteer: boolean,
	suppressDrift: boolean,
	suppressFire: boolean,
	invulnerableTicks: number,
	originPos: { number },
	originRot: { number },
	normal: { number },
	initUpVel: number,
	gravity: number,
	addHeadingRate: number,
	addPitchRate: number,
	addRollRate: number,
	torqueSign: boolean,
	slowdownFraction: number,
	parachuteDragActive: boolean,
	plungerFaceTicks: number,
	externalPullAccel: { number },
	externalPullTicks: number,
	rescueTargetPos: { number }?,
	rescueTargetRot: { number }?,
	rescueHeight: number?,
}

export type StepResult = {
	activeType: number,
	explosionPos: Vec3?,
	explosionRot: Quat?,
	finishedExplosion: boolean,
	bubblegumTorqueY: number,
	externalPullAccel: Vec3?,
}

local function cloneVec3(v: Vec3): Vec3
	return { x = v.x, y = v.y, z = v.z }
end

local function cloneQuat(q: Quat): Quat
	return { w = q.w, x = q.x, y = q.y, z = q.z }
end

function ItemEffectState.create(): State
	return {
		effectType = ItemEffectState.EFFECT_NONE,
		ticksRemaining = 0,
		totalTicks = 0,
		suppressThrottle = false,
		suppressSteer = false,
		suppressDrift = false,
		suppressFire = false,
		invulnerableTicks = 0,
		originPos = { x = 0, y = 0, z = 0 },
		originRot = Math3D.quatIdentity(),
		normal = { x = 0, y = 1, z = 0 },
		initUpVel = 0,
		gravity = 0,
		addHeadingRate = 0,
		addPitchRate = 0,
		addRollRate = 0,
		torqueSign = false,
		slowdownFraction = 1.0,
		parachuteDragActive = false,
		plungerFaceTicks = 0,
		externalPullAccel = { x = 0, y = 0, z = 0 },
		externalPullTicks = 0,
		rescueTargetPos = { x = 0, y = 0, z = 0 },
		rescueTargetRot = Math3D.quatIdentity(),
		rescueHeight = ItemEffectState.RESCUE_HEIGHT_M,
	}
end

function ItemEffectState.setParachuteDrag(eff: State, active: boolean)
	eff.parachuteDragActive = active
end

function ItemEffectState.getAirDragMultiplier(eff: State): number
	return if eff.parachuteDragActive then ItemTuning.parachute.FRICTION else 1.0
end

-- Ported from Kart::blockViewWithPlunger (src/karts/kart.cpp:L606-L618): does NOT extend if already blocked.
function ItemEffectState.triggerPlungerFace(eff: State, durationSec: number): boolean
	if eff.plungerFaceTicks > 0 then
		return false
	end
	eff.plungerFaceTicks = FixedStep.timeToTicks(durationSec)
	return true
end

function ItemEffectState.clearPlungerFace(eff: State)
	eff.plungerFaceTicks = 0
end

-- Transient rubber-band acceleration applied cleanly during KartSolver.step (rubber_band.cpp:L304-L312).
function ItemEffectState.applyRubberBandForce(eff: State, accelVec: Vec3, ticks: number?)
	eff.externalPullAccel = { x = accelVec.x, y = accelVec.y, z = accelVec.z }
	eff.externalPullTicks = math.max(1, ticks or 1)
end

function ItemEffectState.isActive(eff: State): boolean
	return eff.effectType ~= ItemEffectState.EFFECT_NONE and eff.ticksRemaining > 0
end

-- True when kart animation (explosion or rescue) overrides full driver control & physics integration.
function ItemEffectState.isDriverInputSuppressed(eff: State): boolean
	return (eff.effectType == ItemEffectState.EFFECT_EXPLOSION or eff.effectType == ItemEffectState.EFFECT_RESCUE)
		and eff.ticksRemaining > 0
end

-- True when forward throttle / engine drive force is forced to zero (explosion OR floor bubblegum).
function ItemEffectState.isThrottleSuppressed(eff: State): boolean
	return eff.suppressThrottle and eff.ticksRemaining > 0
end

function ItemEffectState.isInvulnerable(eff: State): boolean
	return eff.invulnerableTicks > 0
end

-- Re-trigger & invulnerability gate (explosion_animation.cpp:L50, L81; kart.cpp:L1864; item.cpp:L149).
function ItemEffectState.canTrigger(eff: State, targetType: number): boolean
	if
		(eff.effectType == ItemEffectState.EFFECT_EXPLOSION or eff.effectType == ItemEffectState.EFFECT_RESCUE)
		and eff.ticksRemaining > 0
	then
		return false
	end
	if targetType == ItemEffectState.EFFECT_EXPLOSION then
		return eff.invulnerableTicks <= 0
	elseif targetType == ItemEffectState.EFFECT_SQUASH then
		if eff.invulnerableTicks > 0 then
			return false
		end
		if eff.effectType == ItemEffectState.EFFECT_SQUASH and eff.ticksRemaining > 0 then
			return false
		end
		return true
	elseif targetType == ItemEffectState.EFFECT_BUBBLEGUM_SLOW then
		if eff.effectType == ItemEffectState.EFFECT_BUBBLEGUM_SLOW and eff.ticksRemaining > 0 then
			return false
		end
		return true
	end
	return false
end

-- Trigger upstream RescueAnimation (src/karts/rescue_animation.cpp:L51-L183):
-- 1.2s total, lifts 2.0m for first 40% (58 ticks) from originPos, then drops onto rescueTargetPos/Rot.
function ItemEffectState.triggerRescue(
	eff: State,
	startPos: Vec3,
	startRot: Quat,
	targetPos: Vec3,
	targetRot: Quat,
	durationSec: number?,
	height: number?
): boolean
	if eff.effectType == ItemEffectState.EFFECT_RESCUE and eff.ticksRemaining > 0 then
		return false
	end
	local timer = durationSec or ItemEffectState.RESCUE_DURATION_SEC
	local ticks = FixedStep.timeToTicks(timer)

	eff.effectType = ItemEffectState.EFFECT_RESCUE
	eff.ticksRemaining = ticks
	eff.totalTicks = ticks
	eff.suppressThrottle = true
	eff.suppressSteer = true
	eff.suppressDrift = true
	eff.suppressFire = true
	eff.originPos = cloneVec3(startPos)
	eff.originRot = Math3D.quatNormalize(cloneQuat(startRot))
	eff.rescueTargetPos = cloneVec3(targetPos)
	eff.rescueTargetRot = Math3D.quatNormalize(cloneQuat(targetRot))
	eff.rescueHeight = height or ItemEffectState.RESCUE_HEIGHT_M
	eff.torqueSign = false
	eff.slowdownFraction = 1.0
	return true
end

-- Trigger upstream ExplosionAnimation (explosion_animation.cpp:L44-L240):
-- 1.5s direct hit (0.75s splash), complete horizontal stop, in-place vertical arc + spin,
-- full driver input suppression, and 7.0s (840 ticks) post-explosion invulnerability.
function ItemEffectState.triggerExplosion(
	eff: State,
	pos: Vec3,
	rot: Quat,
	normal: Vec3,
	gravity: number,
	createdTicks: number?,
	directHit: boolean?
): boolean
	if not ItemEffectState.canTrigger(eff, ItemEffectState.EFFECT_EXPLOSION) then
		return false
	end

	local isDirect = (directHit ~= false)
	local timer = ItemTuning.bomb.EXPLOSION_DURATION_SEC
	if not isDirect then
		timer *= 0.5
	end
	local ticks = FixedStep.timeToTicks(timer)
	local tickSeed = createdTicks or 0
	local maxRot = if isDirect then 2 else 1
	local freq = (2.0 * math.pi) / timer

	eff.effectType = ItemEffectState.EFFECT_EXPLOSION
	eff.ticksRemaining = ticks
	eff.totalTicks = ticks
	eff.suppressThrottle = true
	eff.suppressSteer = true
	eff.suppressDrift = true
	eff.suppressFire = true
	eff.invulnerableTicks = FixedStep.timeToTicks(ItemTuning.bomb.INVULNERABILITY_SEC)

	eff.originPos = cloneVec3(pos)
	eff.originRot = Math3D.quatNormalize(cloneQuat(rot))
	eff.normal = Math3D.normalize(normal, { x = 0, y = 1, z = 0 })
	eff.gravity = gravity
	eff.initUpVel = 0.5 * timer * gravity
	eff.addHeadingRate = ((math.floor(tickSeed / 9) % (2 * maxRot + 1)) - maxRot) * freq
	eff.addPitchRate = ((math.floor(tickSeed / 10) % (2 * maxRot + 1)) - maxRot) * freq
	eff.addRollRate = ((math.floor(tickSeed / 11) % (2 * maxRot + 1)) - maxRot) * freq
	eff.torqueSign = false
	eff.slowdownFraction = 1.0
	return true
end

-- Trigger Kart::setSquash slowdown effect (kart.cpp:L1862-L1882).
function ItemEffectState.triggerSquash(eff: State, durationSec: number?, slowdown: number?): boolean
	if not ItemEffectState.canTrigger(eff, ItemEffectState.EFFECT_SQUASH) then
		return false
	end
	local dSec = durationSec or ItemTuning.rubberBall.SQUASH_DURATION_SEC
	local slow = slowdown or ItemTuning.rubberBall.SQUASH_SLOWDOWN
	local ticks = FixedStep.timeToTicks(dSec)

	eff.effectType = ItemEffectState.EFFECT_SQUASH
	eff.ticksRemaining = ticks
	eff.totalTicks = ticks
	eff.suppressThrottle = false
	eff.suppressSteer = false
	eff.suppressDrift = false
	eff.suppressFire = false
	eff.slowdownFraction = slow
	return true
end

-- Trigger floor ITEM_BUBBLEGUM slowdown + engine_power=0 + +-500 yaw torque (kart.cpp:L1160-L1180, L2791-L2798).
function ItemEffectState.triggerBubblegumSlow(eff: State, worldTicks: number?): boolean
	if not ItemEffectState.canTrigger(eff, ItemEffectState.EFFECT_BUBBLEGUM_SLOW) then
		return false
	end
	local bg = ItemTuning.bubblegum
	local ticks = FixedStep.timeToTicks(bg.DURATION_SEC)
	local tNow = worldTicks or 0

	eff.effectType = ItemEffectState.EFFECT_BUBBLEGUM_SLOW
	eff.ticksRemaining = ticks
	eff.totalTicks = ticks
	eff.suppressThrottle = true
	eff.suppressSteer = false
	eff.suppressDrift = false
	eff.suppressFire = false
	eff.torqueSign = (math.floor(tNow / 10) % 2) == 0
	eff.slowdownFraction = bg.SPEED_FRACTION
	return true
end

local function clearActiveEffect(eff: State)
	eff.effectType = ItemEffectState.EFFECT_NONE
	eff.ticksRemaining = 0
	eff.totalTicks = 0
	eff.suppressThrottle = false
	eff.suppressSteer = false
	eff.suppressDrift = false
	eff.suppressFire = false
	eff.slowdownFraction = 1.0
end

function ItemEffectState.clear(eff: State)
	clearActiveEffect(eff)
end

-- Advance active effect & invulnerability by 1 fixed 120 Hz tick.
function ItemEffectState.tick(eff: State): StepResult
	if eff.invulnerableTicks > 0 then
		eff.invulnerableTicks -= 1
	end
	if eff.plungerFaceTicks > 0 then
		eff.plungerFaceTicks -= 1
	end
	local pullAccel: Vec3? = nil
	if eff.externalPullTicks > 0 then
		pullAccel = cloneVec3(eff.externalPullAccel)
		eff.externalPullTicks -= 1
		if eff.externalPullTicks <= 0 then
			eff.externalPullAccel = { x = 0, y = 0, z = 0 }
		end
	end

	local activeType = eff.effectType
	if activeType == ItemEffectState.EFFECT_NONE or eff.ticksRemaining <= 0 then
		if activeType ~= ItemEffectState.EFFECT_NONE then
			clearActiveEffect(eff)
		end
		return {
			activeType = ItemEffectState.EFFECT_NONE,
			explosionPos = nil,
			explosionRot = nil,
			finishedExplosion = false,
			bubblegumTorqueY = 0.0,
			externalPullAccel = pullAccel,
		}
	end

	if activeType == ItemEffectState.EFFECT_EXPLOSION then
		local elapsedTicks = eff.totalTicks - eff.ticksRemaining + 1
		local dur = FixedStep.ticksToTime(elapsedTicks)
		local vel = eff.initUpVel - 0.5 * eff.gravity * dur
		local height = math.max(0.0, dur * vel)

		eff.ticksRemaining -= 1
		if eff.ticksRemaining <= 0 then
			local endPos = cloneVec3(eff.originPos)
			local endRot = cloneQuat(eff.originRot)
			clearActiveEffect(eff)
			return {
				activeType = ItemEffectState.EFFECT_EXPLOSION,
				explosionPos = endPos,
				explosionRot = endRot,
				finishedExplosion = true,
				bubblegumTorqueY = 0.0,
				externalPullAccel = nil,
			}
		end

		local nextPos = Math3D.add(eff.originPos, Math3D.scale(eff.normal, height))
		local qYaw = Math3D.quatFromAxisAngle({ x = 0, y = 1, z = 0 }, eff.addHeadingRate * dur)
		local qPitch = Math3D.quatFromAxisAngle({ x = 1, y = 0, z = 0 }, eff.addPitchRate * dur)
		local qRoll = Math3D.quatFromAxisAngle({ x = 0, y = 0, z = 1 }, eff.addRollRate * dur)
		local qSpin = Math3D.quatMul(Math3D.quatMul(qYaw, qPitch), qRoll)
		local nextRot = Math3D.quatNormalize(Math3D.quatMul(eff.originRot, qSpin))

		return {
			activeType = activeType,
			explosionPos = nextPos,
			explosionRot = nextRot,
			finishedExplosion = false,
			bubblegumTorqueY = 0.0,
			externalPullAccel = nil,
		}
	elseif activeType == ItemEffectState.EFFECT_RESCUE then
		local elapsedTicks = eff.totalTicks - eff.ticksRemaining + 1
		local splitTicks = math.max(1, math.round(eff.totalTicks * ItemEffectState.RESCUE_LIFT_FRACTION))

		eff.ticksRemaining -= 1
		if eff.ticksRemaining <= 0 then
			local endPos = cloneVec3(eff.rescueTargetPos)
			local endRot = cloneQuat(eff.rescueTargetRot)
			clearActiveEffect(eff)
			return {
				activeType = ItemEffectState.EFFECT_RESCUE,
				explosionPos = endPos,
				explosionRot = endRot,
				finishedExplosion = true,
				bubblegumTorqueY = 0.0,
				externalPullAccel = nil,
			}
		end

		local nextPos: Vec3
		local nextRot: Quat
		local rescueVel = eff.rescueHeight / math.max(1e-6, FixedStep.ticksToTime(eff.totalTicks))
		if elapsedTicks <= splitTicks then
			local dur = FixedStep.ticksToTime(elapsedTicks)
			local _, originUp = Math3D.quatBasis(eff.originRot)
			nextPos = Math3D.add(eff.originPos, Math3D.scale(originUp, dur * rescueVel))
			nextRot = cloneQuat(eff.originRot)
		else
			local remDur = math.max(0.0, FixedStep.ticksToTime(eff.totalTicks - elapsedTicks))
			local _, targetUp = Math3D.quatBasis(eff.rescueTargetRot)
			nextPos = Math3D.add(eff.rescueTargetPos, Math3D.scale(targetUp, remDur * rescueVel))
			nextRot = cloneQuat(eff.rescueTargetRot)
		end

		return {
			activeType = activeType,
			explosionPos = nextPos,
			explosionRot = nextRot,
			finishedExplosion = false,
			bubblegumTorqueY = 0.0,
			externalPullAccel = nil,
		}
	end

	local torqueY = 0.0
	if activeType == ItemEffectState.EFFECT_BUBBLEGUM_SLOW then
		local sign = if eff.torqueSign then 1.0 else -1.0
		torqueY = ItemTuning.bubblegum.TORQUE * sign
	end

	eff.ticksRemaining -= 1
	if eff.ticksRemaining <= 0 then
		clearActiveEffect(eff)
	end

	return {
		activeType = activeType,
		explosionPos = nil,
		explosionRot = nil,
		finishedExplosion = false,
		bubblegumTorqueY = torqueY,
		externalPullAccel = pullAccel,
	}
end

function ItemEffectState.captureNet(eff: State): NetEffectState
	return {
		effectType = eff.effectType,
		ticksRemaining = eff.ticksRemaining,
		totalTicks = eff.totalTicks,
		suppressThrottle = eff.suppressThrottle,
		suppressSteer = eff.suppressSteer,
		suppressDrift = eff.suppressDrift,
		suppressFire = eff.suppressFire,
		invulnerableTicks = eff.invulnerableTicks,
		originPos = { eff.originPos.x, eff.originPos.y, eff.originPos.z },
		originRot = { eff.originRot.w, eff.originRot.x, eff.originRot.y, eff.originRot.z },
		normal = { eff.normal.x, eff.normal.y, eff.normal.z },
		initUpVel = eff.initUpVel,
		gravity = eff.gravity,
		addHeadingRate = eff.addHeadingRate,
		addPitchRate = eff.addPitchRate,
		addRollRate = eff.addRollRate,
		torqueSign = eff.torqueSign,
		slowdownFraction = eff.slowdownFraction,
		parachuteDragActive = eff.parachuteDragActive,
		plungerFaceTicks = eff.plungerFaceTicks,
		externalPullAccel = { eff.externalPullAccel.x, eff.externalPullAccel.y, eff.externalPullAccel.z },
		externalPullTicks = eff.externalPullTicks,
		rescueTargetPos = { eff.rescueTargetPos.x, eff.rescueTargetPos.y, eff.rescueTargetPos.z },
		rescueTargetRot = {
			eff.rescueTargetRot.w,
			eff.rescueTargetRot.x,
			eff.rescueTargetRot.y,
			eff.rescueTargetRot.z,
		},
		rescueHeight = eff.rescueHeight,
	}
end

function ItemEffectState.applyNet(eff: State, snap: NetEffectState)
	eff.effectType = snap.effectType
	eff.ticksRemaining = snap.ticksRemaining
	eff.totalTicks = snap.totalTicks
	eff.suppressThrottle = snap.suppressThrottle
	eff.suppressSteer = snap.suppressSteer
	eff.suppressDrift = snap.suppressDrift
	eff.suppressFire = snap.suppressFire
	eff.invulnerableTicks = snap.invulnerableTicks
	eff.originPos = { x = snap.originPos[1], y = snap.originPos[2], z = snap.originPos[3] }
	eff.originRot = { w = snap.originRot[1], x = snap.originRot[2], y = snap.originRot[3], z = snap.originRot[4] }
	eff.normal = { x = snap.normal[1], y = snap.normal[2], z = snap.normal[3] }
	eff.initUpVel = snap.initUpVel
	eff.gravity = snap.gravity
	eff.addHeadingRate = snap.addHeadingRate
	eff.addPitchRate = snap.addPitchRate
	eff.addRollRate = snap.addRollRate
	eff.torqueSign = snap.torqueSign
	eff.slowdownFraction = snap.slowdownFraction
	eff.parachuteDragActive = snap.parachuteDragActive == true
	eff.plungerFaceTicks = snap.plungerFaceTicks or 0
	if snap.externalPullAccel ~= nil then
		eff.externalPullAccel = {
			x = snap.externalPullAccel[1] or 0,
			y = snap.externalPullAccel[2] or 0,
			z = snap.externalPullAccel[3] or 0,
		}
	else
		eff.externalPullAccel = { x = 0, y = 0, z = 0 }
	end
	eff.externalPullTicks = snap.externalPullTicks or 0
	if snap.rescueTargetPos ~= nil then
		eff.rescueTargetPos = {
			x = snap.rescueTargetPos[1] or 0,
			y = snap.rescueTargetPos[2] or 0,
			z = snap.rescueTargetPos[3] or 0,
		}
	else
		eff.rescueTargetPos = { x = 0, y = 0, z = 0 }
	end
	if snap.rescueTargetRot ~= nil then
		eff.rescueTargetRot = {
			w = snap.rescueTargetRot[1] or 1,
			x = snap.rescueTargetRot[2] or 0,
			y = snap.rescueTargetRot[3] or 0,
			z = snap.rescueTargetRot[4] or 0,
		}
	else
		eff.rescueTargetRot = Math3D.quatIdentity()
	end
	eff.rescueHeight = snap.rescueHeight or ItemEffectState.RESCUE_HEIGHT_M
end

return table.freeze(ItemEffectState)
