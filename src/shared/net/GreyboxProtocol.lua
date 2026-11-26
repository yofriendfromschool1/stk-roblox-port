--!strict
-- src/shared/net/GreyboxProtocol.lua
-- SPDX-License-Identifier: GPL-3.0-or-later

local Flyable = require("../sim/Flyable")
local ItemEffectState = require("../sim/ItemEffectState")
local ItemTuning = require("../ItemTuning")
local ItemWorld = require("../items/ItemWorld")
local KartSolver = require("../sim/KartSolver")
local MaxSpeed = require("../kart/MaxSpeed")
local RaceState = require("../sim/RaceState")
local Skidding = require("../kart/Skidding")
local Slipstream = require("../sim/Slipstream")

export type RemoteKartState = {
	id: string,
	pos: { number },
	rot: { number },
	linVel: { number }?,
	speed: number,
	steer: number,
	attachmentType: number,
	attachmentTicksLeft: number?,
	plungerFaceTicks: number,
	timedImpulseTicks: number?,
	isSquashed: boolean,
	rank: number,
	lap: number?,
	nextCheckpoint: number?,
	raceFinished: boolean?,
	finishTick: number?,
	trackNodeIdx: number?,
	slipstreamTime: number?,
	slipstreamBonusTime: number?,
}

export type ClientInputPacket = {
	seq: number,
	accel: number,
	brake: boolean,
	steer: number,
	drift: boolean,
	nitro: boolean,
	fire: boolean?,
	lookBack: boolean?,
	reset: boolean,
	debugGrantNitro: boolean,
}

export type TelemetryPacket = {
	tick: number,
	lastInputSeq: number,
	resetSeq: number,
	serverTime: number?,
	resetNotice: string,
	netState: KartSolver.NetState,
	remoteKarts: { RemoteKartState }?,
}

local SKID_CONTROLS: { Skidding.SkidControl } = { "NONE", "NO_DIRECTION", "LEFT", "RIGHT" }
local SKID_CONTROL_TO_ID: { [Skidding.SkidControl]: number } = {}
for idx, name in SKID_CONTROLS do
	SKID_CONTROL_TO_ID[name :: Skidding.SkidControl] = idx
end

local SKID_STATES: { Skidding.SkidStateName } = {
	"SKID_NONE",
	"SKID_ACCUMULATE_LEFT",
	"SKID_ACCUMULATE_RIGHT",
	"SKID_SHOW_GFX_LEFT",
	"SKID_SHOW_GFX_RIGHT",
	"SKID_BREAK",
}
local SKID_STATE_TO_ID: { [Skidding.SkidStateName]: number } = {}
for idx, name in SKID_STATES do
	SKID_STATE_TO_ID[name :: Skidding.SkidStateName] = idx
end

local INC_CATS: { MaxSpeed.SpeedIncreaseCategory } = {
	"ZIPPER",
	"SLIPSTREAM",
	"NITRO",
	"RUBBER",
	"SKIDDING",
	"RED_SKIDDING",
}
local INC_CAT_TO_ID: { [MaxSpeed.SpeedIncreaseCategory]: number } = {}
for idx, name in INC_CATS do
	INC_CAT_TO_ID[name :: MaxSpeed.SpeedIncreaseCategory] = idx
end

local ITEM_TYPES: { ItemWorld.ItemType } = { "small-nitro", "big-nitro", "item", "banana", "bubblegum" }
local ITEM_TYPE_TO_ID: { [ItemWorld.ItemType]: number } = {}
for idx, name in ITEM_TYPES do
	ITEM_TYPE_TO_ID[name :: ItemWorld.ItemType] = idx
end

local FLYABLE_KINDS: { Flyable.FlyableKind } = { "bowling", "cake", "plunger", "rubber_ball" }
local FLYABLE_KIND_TO_ID: { [Flyable.FlyableKind]: number } = {}
for idx, name in FLYABLE_KINDS do
	FLYABLE_KIND_TO_ID[name :: Flyable.FlyableKind] = idx
end

local CORE_HEADER_BYTES = 248
local ITEM_EFFECT_BASE_BYTES = 12
local ITEM_EFFECT_EXPLOSION_BYTES = 88
local ITEM_EFFECT_PULL_BYTES = 16
local INCREASE_ENTRY_BYTES = 17
local COOLDOWN_ENTRY_BYTES = 6
local DYNAMIC_ITEM_ENTRY_BYTES = 28
local FLYABLE_BASE_BYTES = 84
local FLYABLE_CUSTOM_PHYS_BYTES = 12
local FLYABLE_TARGET_BYTES = 8
local FLYABLE_RUBBER_BYTES = 8
local FLYABLE_PLUNGER_BYTES = 23
local REMOTE_KART_FIXED_BYTES = 67
local SLIPSTREAM_BYTES = 65

local function defaultFlyablePhys(kind: Flyable.FlyableKind): (number, number, number)
	if kind == "bowling" then
		return ItemTuning.bowling.RADIUS, ItemTuning.bowling.GRAVITY, ItemTuning.bowling.RESTITUTION
	elseif kind == "cake" then
		return ItemTuning.cake.RADIUS, ItemTuning.cake.GRAVITY, ItemTuning.cake.RESTITUTION
	elseif kind == "plunger" then
		return ItemTuning.plunger.RADIUS, 0.0, 0.5
	else
		return ItemTuning.rubberBall.RADIUS, 0.0, 0.0
	end
end

local function hasCustomFlyablePhys(e: Flyable.NetFlyableEntry): boolean
	local defR, defG, defE = defaultFlyablePhys(e.kind)
	return math.abs(e.radius - defR) > 1e-6
		or math.abs(e.gravity - defG) > 1e-6
		or math.abs(e.restitution - defE) > 1e-6
end

local function hasRubberBallFields(e: Flyable.NetFlyableEntry): boolean
	return e.kind == "rubber_ball" or e.deleteTicks ~= -1 or e.drivelineIdx ~= 1 or e.bouncePhaseSec ~= 0.0
end

local function hasPlungerBandFields(e: Flyable.NetFlyableEntry): boolean
	return e.keepAliveTicks >= 0 or e.bandState ~= 0
end

local function computeItemEffectBytes(eff: ItemEffectState.NetEffectState): number
	local size = ITEM_EFFECT_BASE_BYTES
	if eff.effectType == ItemEffectState.EFFECT_EXPLOSION then
		size += ITEM_EFFECT_EXPLOSION_BYTES
	end
	if eff.slowdownFraction ~= 1.0 or eff.externalPullTicks > 0 then
		size += ITEM_EFFECT_PULL_BYTES
	end
	return size
end

local function computeFlyableEntryBytes(e: Flyable.NetFlyableEntry): number
	local size = FLYABLE_BASE_BYTES
	if hasCustomFlyablePhys(e) then
		size += FLYABLE_CUSTOM_PHYS_BYTES
	end
	if e.targetKartId ~= 0 then
		size += FLYABLE_TARGET_BYTES
	end
	if hasRubberBallFields(e) then
		size += FLYABLE_RUBBER_BYTES
	end
	if hasPlungerBandFields(e) then
		size += FLYABLE_PLUNGER_BYTES
	end
	return size
end

local GreyboxProtocol = {}

GreyboxProtocol.REMOTES_FOLDER = "OpenKartRemotes"
GreyboxProtocol.INPUT_REMOTE = "KartInput"
GreyboxProtocol.TELEMETRY_REMOTE = "KartTelemetry"
GreyboxProtocol.ARENA_NAME = "GreyboxArena"
GreyboxProtocol.LOCAL_KARTS_FOLDER = "LocalGreyboxKarts"
GreyboxProtocol.PLANE_NAME = "GreyboxPlane"
GreyboxProtocol.SNAPSHOT_RATE_HZ = 30
GreyboxProtocol.SPAWN_HEIGHT_METERS = 0.35
GreyboxProtocol.VOID_RESET_Y_METERS = -20.0

local function clampU8(n: number): number
	return math.clamp(math.round(n), 0, 255)
end

local function clampI8(n: number): number
	return math.clamp(math.round(n), -128, 127)
end

local function clampU16(n: number): number
	return math.clamp(math.round(n), 0, 65535)
end

local function clampU32(n: number): number
	return math.clamp(math.round(n), 0, 4294967295)
end

local function clampI16(n: number): number
	return math.clamp(math.round(n), -32768, 32767)
end

local function clampI32(n: number): number
	return math.clamp(math.round(n), -2147483648, 2147483647)
end

local function isItemEffectActive(eff: ItemEffectState.NetEffectState?): boolean
	if eff == nil then
		return false
	end
	return eff.effectType ~= 0
		or eff.ticksRemaining > 0
		or eff.invulnerableTicks > 0
		or eff.plungerFaceTicks > 0
		or eff.externalPullTicks > 0
		or eff.parachuteDragActive
end

local function isSlipstreamStateActive(ss: Slipstream.NetSlipstreamState?): boolean
	if ss == nil then
		return false
	end
	return ss.mode == "COLLECT"
		or ss.inZone
		or ss.chargeTicks > 0
		or ss.slipstreamTime > 0.0
		or ss.bonusTime > 0.0
		or ss.bonusActive
		or ss.currentTargetId ~= nil
		or ss.previousTargetId ~= nil
		or ss.speedIncreaseTick >= 0
		or ss.inInnerQuad
		or ss.inOuterQuad
end

-- Pack authoritative snapshot into a compact binary Luau buffer well below UnreliableRemoteEvent's ~900-byte limit.
function GreyboxProtocol.packSnapshot(
	tick: number,
	lastInputSeq: number,
	resetSeq: number,
	ns: KartSolver.NetState,
	resetNotice: string,
	remoteKarts: { RemoteKartState }?,
	serverTime: number?
): (buffer, string?)
	local eff = ns.itemEffect
	local hasItemEffect = isItemEffectActive(eff)
	local iw = ns.itemWorldSnapshot
	local hasItemWorld = iw ~= nil
	local fw = ns.flyableSnapshot
	local hasFlyables = fw ~= nil and (#fw.entries > 0 or fw.nextId > 1)
	local nRemotes = if remoteKarts ~= nil then math.min(#remoteKarts, 255) else 0
	local hasRemoteKarts = nRemotes > 0
	local ss = ns.slipstream
	local hasSlipstream = isSlipstreamStateActive(ss)

	local nIncs = math.min(#ns.increases, 255)
	local totalBytes = CORE_HEADER_BYTES
		+ (if hasItemEffect and eff ~= nil then computeItemEffectBytes(eff) else 0)
		+ (if hasSlipstream then SLIPSTREAM_BYTES else 0)
		+ 1
		+ nIncs * INCREASE_ENTRY_BYTES

	local nCooldowns = 0
	local nDynamics = 0
	if iw ~= nil then
		nCooldowns = math.min(#iw.trackCooldowns, 255)
		nDynamics = math.min(#iw.dynamicItems, 255)
		totalBytes += 10 + nCooldowns * COOLDOWN_ENTRY_BYTES + nDynamics * DYNAMIC_ITEM_ENTRY_BYTES
	end

	local nFlyables = 0
	if hasFlyables and fw ~= nil then
		nFlyables = math.min(#fw.entries, 255)
		totalBytes += 3
		for idx = 1, nFlyables do
			totalBytes += computeFlyableEntryBytes(fw.entries[idx])
		end
	end

	local remoteIds: { string } = {}
	if hasRemoteKarts and remoteKarts ~= nil then
		totalBytes += 1
		for idx = 1, nRemotes do
			local rid = string.sub(remoteKarts[idx].id, 1, 255)
			remoteIds[idx] = rid
			totalBytes += 1 + #rid + REMOTE_KART_FIXED_BYTES
		end
	end

	local buf = buffer.create(totalBytes)
	local off = 0

	buffer.writeu32(buf, off, clampU32(tick))
	off += 4
	buffer.writeu32(buf, off, clampU32(lastInputSeq))
	off += 4
	buffer.writeu16(buf, off, clampU16(resetSeq))
	off += 2
	buffer.writef64(buf, off, serverTime or 0.0)
	off += 8

	-- 13 f64 kinematics for exact deterministic replay (104 B)
	buffer.writef64(buf, off, ns.pos[1])
	buffer.writef64(buf, off + 8, ns.pos[2])
	buffer.writef64(buf, off + 16, ns.pos[3])
	buffer.writef64(buf, off + 24, ns.rot[1])
	buffer.writef64(buf, off + 32, ns.rot[2])
	buffer.writef64(buf, off + 40, ns.rot[3])
	buffer.writef64(buf, off + 48, ns.rot[4])
	buffer.writef64(buf, off + 56, ns.linVel[1])
	buffer.writef64(buf, off + 64, ns.linVel[2])
	buffer.writef64(buf, off + 72, ns.linVel[3])
	buffer.writef64(buf, off + 80, ns.angVel[1])
	buffer.writef64(buf, off + 88, ns.angVel[2])
	buffer.writef64(buf, off + 96, ns.angVel[3])
	off += 104

	-- 19 f32 secondary scalars (76 B)
	buffer.writef32(buf, off, ns.steer)
	buffer.writef32(buf, off + 4, ns.skidFactor)
	buffer.writef32(buf, off + 8, ns.steeringFraction)
	buffer.writef32(buf, off + 12, ns.visualRotation)
	buffer.writef32(buf, off + 16, ns.hopHeight)
	buffer.writef32(buf, off + 20, ns.remainingJumpTime)
	buffer.writef32(buf, off + 24, ns.nitroEnergy)
	buffer.writef32(buf, off + 28, ns.energyToMinRatio)
	buffer.writef32(buf, off + 32, ns.timedImpulsePerSec[1])
	buffer.writef32(buf, off + 36, ns.timedImpulsePerSec[2])
	buffer.writef32(buf, off + 40, ns.timedImpulsePerSec[3])
	buffer.writef32(buf, off + 44, ns.timedRotationRate)
	buffer.writef32(buf, off + 48, ns.terrainFraction)
	buffer.writef32(buf, off + 52, ns.terrainTargetFraction)
	buffer.writef32(buf, off + 56, ns.squashFraction or 1.0)
	buffer.writef32(buf, off + 60, ns.squashTargetFraction or 1.0)
	buffer.writef32(buf, off + 64, ns.attachmentInitialSpeed or 0.0)
	buffer.writef32(buf, off + 68, ns.bubbleFraction or 1.0)
	buffer.writef32(buf, off + 72, ns.bubbleTargetFraction or 1.0)
	off += 76

	-- sectionFlags (1 B)
	local sectionFlags = (if ns.bonusReady then 1 else 0)
		+ (if ns.nitroActive then 2 else 0)
		+ (if ns.fireWasDown then 4 else 0)
		+ (if hasItemEffect then 8 else 0)
		+ (if hasItemWorld then 16 else 0)
		+ (if hasFlyables then 32 else 0)
		+ (if hasRemoteKarts then 64 else 0)
		+ (if hasSlipstream then 128 else 0)
	buffer.writeu8(buf, off, sectionFlags)
	off += 1

	-- 7 small enum/count bytes (7 B)
	buffer.writeu8(buf, off, SKID_CONTROL_TO_ID[ns.latchedSkidControl] or 1)
	buffer.writeu8(buf, off + 1, SKID_STATE_TO_ID[ns.skidState] or 1)
	buffer.writeu8(buf, off + 2, clampU8(ns.currentTier))
	buffer.writeu8(buf, off + 3, clampU8(ns.heldPowerup or 0))
	buffer.writeu8(buf, off + 4, clampU8(ns.heldPowerupCount or 0))
	buffer.writeu8(buf, off + 5, clampU8(ns.attachmentType or 0))
	buffer.writeu8(buf, off + 6, clampU8(ns.stuckTicks or 0))
	off += 7

	-- 12 i16 tick counters (24 B)
	buffer.writei16(buf, off, clampI16(ns.brakeTicks))
	buffer.writei16(buf, off + 2, clampI16(ns.skidTimeTicks))
	buffer.writei16(buf, off + 4, clampI16(ns.minNitroTicks))
	buffer.writei16(buf, off + 6, clampI16(ns.timedImpulseTicks))
	buffer.writei16(buf, off + 8, clampI16(ns.timedRotationTicks))
	buffer.writei16(buf, off + 10, clampI16(ns.bounceBackTicks))
	buffer.writei16(buf, off + 12, clampI16(ns.terrainFadeTicks))
	buffer.writei16(buf, off + 14, clampI16(ns.squashFadeTicks or 0))
	buffer.writei16(buf, off + 16, clampI16(ns.squashDurationTicks or 0))
	buffer.writei16(buf, off + 18, clampI16(ns.attachmentTicksLeft or 0))
	buffer.writei16(buf, off + 20, clampI16(ns.bubbleFadeTicks or 0))
	buffer.writei16(buf, off + 22, clampI16(ns.bubbleDurationTicks or 0))
	off += 24

	-- 18-byte race & start-bonus state
	local race = ns.race
	local racePhaseId = if race ~= nil then (RaceState.PHASE_TO_ID[race.phase] or 1) else 1
	local raceFlags = if race ~= nil
		then (if race.raceFinished then 1 else 0) + (if race.startupHasPressed then 2 else 0) + (if race.startupBoostFired
			then 4
			else 0)
		else 0
	buffer.writeu32(buf, off, clampU32(if race ~= nil then race.raceTick else 0))
	buffer.writei32(buf, off + 4, clampI32(if race ~= nil then race.finishTick else -1))
	buffer.writef32(buf, off + 8, if race ~= nil then race.startupBoostMps else 0.0)
	buffer.writeu8(buf, off + 12, clampU8(racePhaseId))
	buffer.writei8(buf, off + 13, clampI8(if race ~= nil then race.lap else -1))
	buffer.writeu8(buf, off + 14, clampU8(if race ~= nil then race.nextCheckpoint else 0))
	buffer.writeu8(buf, off + 15, raceFlags)
	buffer.writei16(buf, off + 16, clampI16(if race ~= nil then race.startupPenaltyTicks else 0))
	off += 18

	if hasItemEffect and eff ~= nil then
		local hasExp = (eff.effectType == ItemEffectState.EFFECT_EXPLOSION)
		local hasPull = (eff.slowdownFraction ~= 1.0 or eff.externalPullTicks > 0)
		local effFlags = (if eff.suppressThrottle then 1 else 0)
			+ (if eff.suppressSteer then 2 else 0)
			+ (if eff.suppressDrift then 4 else 0)
			+ (if eff.suppressFire then 8 else 0)
			+ (if eff.torqueSign then 16 else 0)
			+ (if eff.parachuteDragActive then 32 else 0)
			+ (if hasExp then 64 else 0)
			+ (if hasPull then 128 else 0)
		buffer.writeu8(buf, off, clampU8(eff.effectType))
		buffer.writeu8(buf, off + 1, effFlags)
		buffer.writei16(buf, off + 2, clampI16(eff.ticksRemaining))
		buffer.writei16(buf, off + 4, clampI16(eff.totalTicks))
		buffer.writei16(buf, off + 6, clampI16(eff.invulnerableTicks))
		buffer.writei16(buf, off + 8, clampI16(eff.plungerFaceTicks))
		buffer.writei16(buf, off + 10, clampI16(eff.externalPullTicks))
		off += ITEM_EFFECT_BASE_BYTES
		if hasExp then
			buffer.writef64(buf, off, eff.originPos[1])
			buffer.writef64(buf, off + 8, eff.originPos[2])
			buffer.writef64(buf, off + 16, eff.originPos[3])
			buffer.writef64(buf, off + 24, eff.originRot[1])
			buffer.writef64(buf, off + 32, eff.originRot[2])
			buffer.writef64(buf, off + 40, eff.originRot[3])
			buffer.writef64(buf, off + 48, eff.originRot[4])
			buffer.writef32(buf, off + 56, eff.normal[1])
			buffer.writef32(buf, off + 60, eff.normal[2])
			buffer.writef32(buf, off + 64, eff.normal[3])
			buffer.writef32(buf, off + 68, eff.initUpVel)
			buffer.writef32(buf, off + 72, eff.gravity)
			buffer.writef32(buf, off + 76, eff.addHeadingRate)
			buffer.writef32(buf, off + 80, eff.addPitchRate)
			buffer.writef32(buf, off + 84, eff.addRollRate)
			off += ITEM_EFFECT_EXPLOSION_BYTES
		end
		if hasPull then
			buffer.writef32(buf, off, eff.slowdownFraction)
			buffer.writef32(buf, off + 4, eff.externalPullAccel[1])
			buffer.writef32(buf, off + 8, eff.externalPullAccel[2])
			buffer.writef32(buf, off + 12, eff.externalPullAccel[3])
			off += ITEM_EFFECT_PULL_BYTES
		end
	end

	if hasSlipstream and ss ~= nil then
		local ssFlags = (if ss.mode == "COLLECT" then 1 else 0)
			+ (if ss.bonusActive then 2 else 0)
			+ (if ss.currentTargetId ~= nil then 4 else 0)
			+ (if ss.previousTargetId ~= nil then 8 else 0)
			+ (if ss.inInnerQuad then 16 else 0)
			+ (if ss.inOuterQuad then 32 else 0)
			+ (if ss.inZone then 64 else 0)
		buffer.writeu8(buf, off, ssFlags)
		buffer.writef64(buf, off + 1, ss.slipstreamTime)
		buffer.writef64(buf, off + 9, ss.bonusTime)
		buffer.writef64(buf, off + 17, ss.currentTargetId or 0)
		buffer.writef64(buf, off + 25, ss.previousTargetId or 0)
		buffer.writei32(buf, off + 33, clampI32(ss.speedIncreaseTick))
		buffer.writei16(buf, off + 37, clampI16(ss.speedIncreaseDurationTicks))
		local pp = ns.prevPos or ns.pos
		buffer.writef64(buf, off + 39, pp[1])
		buffer.writef64(buf, off + 47, pp[2])
		buffer.writef64(buf, off + 55, pp[3])
		buffer.writei16(buf, off + 63, clampI16(ss.chargeTicks))
		off += SLIPSTREAM_BYTES
	end

	buffer.writeu8(buf, off, nIncs)
	off += 1
	for idx = 1, nIncs do
		local inc = ns.increases[idx]
		buffer.writeu8(buf, off, INC_CAT_TO_ID[inc.cat] or 1)
		buffer.writef32(buf, off + 1, inc.maxAddSpeed)
		buffer.writef32(buf, off + 5, inc.currentSpeedup)
		buffer.writef32(buf, off + 9, inc.engineForce)
		buffer.writei16(buf, off + 13, clampI16(inc.durationTicks))
		buffer.writei16(buf, off + 15, clampI16(inc.fadeOutTicks))
		off += INCREASE_ENTRY_BYTES
	end

	if iw ~= nil then
		buffer.writei32(buf, off, clampI32(iw.elapsedTicks))
		buffer.writeu16(buf, off + 4, clampU16(iw.nextDynamicId))
		buffer.writei16(buf, off + 6, clampI16(iw.switchTicks or -1))
		buffer.writeu8(buf, off + 8, nCooldowns)
		buffer.writeu8(buf, off + 9, nDynamics)
		off += 10
		for idx = 1, nCooldowns do
			local cd = iw.trackCooldowns[idx]
			buffer.writeu16(buf, off, clampU16(cd.id))
			buffer.writei16(buf, off + 2, clampI16(cd.ticksTillReturn))
			buffer.writei16(buf, off + 4, clampI16(cd.deactiveTicks))
			off += COOLDOWN_ENTRY_BYTES
		end
		for idx = 1, nDynamics do
			local dyn = iw.dynamicItems[idx]
			buffer.writeu16(buf, off, clampU16(dyn.id))
			buffer.writeu8(buf, off + 2, ITEM_TYPE_TO_ID[dyn.itemType] or 4)
			buffer.writeu8(buf, off + 3, if dyn.originalType then (ITEM_TYPE_TO_ID[dyn.originalType] or 0) else 0)
			buffer.writef32(buf, off + 4, dyn.pos.x)
			buffer.writef32(buf, off + 8, dyn.pos.y)
			buffer.writef32(buf, off + 12, dyn.pos.z)
			buffer.writei16(buf, off + 16, clampI16(dyn.deactiveTicks))
			buffer.writei16(buf, off + 18, clampI16(dyn.disappearCounter))
			buffer.writef64(buf, off + 20, dyn.ownerId)
			off += DYNAMIC_ITEM_ENTRY_BYTES
		end
	end

	if hasFlyables and fw ~= nil then
		buffer.writeu16(buf, off, clampU16(fw.nextId))
		buffer.writeu8(buf, off + 2, nFlyables)
		off += 3
		for idx = 1, nFlyables do
			local e = fw.entries[idx]
			local customPhys = hasCustomFlyablePhys(e)
			local hasTarget = (e.targetKartId ~= 0)
			local hasRubber = hasRubberBallFields(e)
			local hasPlunger = hasPlungerBandFields(e)
			local bFlags = (if e.reverseMode then 1 else 0)
				+ (if e.isBattle then 2 else 0)
				+ (if e.hasHitSomething then 4 else 0)
				+ (if e.movedToInfinity then 8 else 0)
				+ (if customPhys then 16 else 0)
				+ (if hasTarget then 32 else 0)
				+ (if hasRubber then 64 else 0)
				+ (if hasPlunger then 128 else 0)
			buffer.writeu16(buf, off, clampU16(e.id))
			buffer.writeu8(buf, off + 2, FLYABLE_KIND_TO_ID[e.kind] or 1)
			buffer.writeu8(buf, off + 3, bFlags)
			buffer.writef64(buf, off + 4, e.ownerId)
			buffer.writef64(buf, off + 12, e.pos[1])
			buffer.writef64(buf, off + 20, e.pos[2])
			buffer.writef64(buf, off + 28, e.pos[3])
			buffer.writef64(buf, off + 36, e.vel[1])
			buffer.writef64(buf, off + 44, e.vel[2])
			buffer.writef64(buf, off + 52, e.vel[3])
			buffer.writef32(buf, off + 60, e.rot[1])
			buffer.writef32(buf, off + 64, e.rot[2])
			buffer.writef32(buf, off + 68, e.rot[3])
			buffer.writef32(buf, off + 72, e.rot[4])
			buffer.writef32(buf, off + 76, e.speedScalar)
			buffer.writei16(buf, off + 80, clampI16(e.ticksSinceThrown))
			buffer.writei16(buf, off + 82, clampI16(e.maxLifespanTicks))
			off += FLYABLE_BASE_BYTES
			if customPhys then
				buffer.writef32(buf, off, e.radius)
				buffer.writef32(buf, off + 4, e.gravity)
				buffer.writef32(buf, off + 8, e.restitution)
				off += FLYABLE_CUSTOM_PHYS_BYTES
			end
			if hasTarget then
				buffer.writef64(buf, off, e.targetKartId)
				off += FLYABLE_TARGET_BYTES
			end
			if hasRubber then
				buffer.writei16(buf, off, clampI16(e.deleteTicks))
				buffer.writei16(buf, off + 2, clampI16(e.drivelineIdx))
				buffer.writef32(buf, off + 4, e.bouncePhaseSec)
				off += FLYABLE_RUBBER_BYTES
			end
			if hasPlunger then
				buffer.writei16(buf, off, clampI16(e.keepAliveTicks))
				buffer.writeu8(buf, off + 2, clampU8(e.bandState))
				buffer.writef64(buf, off + 3, e.bandTargetKartId)
				buffer.writef32(buf, off + 11, e.bandAnchorPos[1])
				buffer.writef32(buf, off + 15, e.bandAnchorPos[2])
				buffer.writef32(buf, off + 19, e.bandAnchorPos[3])
				off += FLYABLE_PLUNGER_BYTES
			end
		end
	end

	if hasRemoteKarts and remoteKarts ~= nil then
		buffer.writeu8(buf, off, nRemotes)
		off += 1
		for idx = 1, nRemotes do
			local rk = remoteKarts[idx]
			local rid = remoteIds[idx]
			local idLen = #rid
			buffer.writeu8(buf, off, idLen)
			buffer.writestring(buf, off + 1, rid)
			local rOff = off + 1 + idLen
			buffer.writef32(buf, rOff, rk.pos[1])
			buffer.writef32(buf, rOff + 4, rk.pos[2])
			buffer.writef32(buf, rOff + 8, rk.pos[3])
			buffer.writef32(buf, rOff + 12, rk.rot[1])
			buffer.writef32(buf, rOff + 16, rk.rot[2])
			buffer.writef32(buf, rOff + 20, rk.rot[3])
			buffer.writef32(buf, rOff + 24, rk.rot[4])
			local rv = rk.linVel
			buffer.writef32(buf, rOff + 28, if rv then (rv[1] or 0) else 0)
			buffer.writef32(buf, rOff + 32, if rv then (rv[2] or 0) else 0)
			buffer.writef32(buf, rOff + 36, if rv then (rv[3] or 0) else 0)
			buffer.writef32(buf, rOff + 40, rk.speed)
			buffer.writef32(buf, rOff + 44, rk.steer)
			buffer.writeu8(buf, rOff + 48, clampU8(rk.attachmentType))
			buffer.writei16(buf, rOff + 49, clampI16(rk.plungerFaceTicks))
			buffer.writei16(buf, rOff + 51, clampI16(rk.timedImpulseTicks or 0))
			local rkFlags = (if rk.isSquashed then 1 else 0) + (if rk.raceFinished then 2 else 0)
			buffer.writeu8(buf, rOff + 53, rkFlags)
			buffer.writeu8(buf, rOff + 54, clampU8(rk.rank))
			buffer.writei8(buf, rOff + 55, clampI8(rk.lap or -1))
			buffer.writeu16(buf, rOff + 56, clampU16(rk.trackNodeIdx or 1))
			buffer.writeu8(buf, rOff + 58, clampU8(math.max(0, rk.slipstreamTime or 0) * (255 / 8.0)))
			buffer.writeu8(buf, rOff + 59, clampU8(math.max(0, rk.slipstreamBonusTime or 0) * (255 / 8.0)))
			buffer.writei16(buf, rOff + 60, clampI16(rk.attachmentTicksLeft or 0))
			buffer.writeu8(buf, rOff + 62, clampU8(rk.nextCheckpoint or 0))
			buffer.writei32(buf, rOff + 63, clampI32(rk.finishTick or -1))
			off = rOff + REMOTE_KART_FIXED_BYTES
		end
	end

	assert(off == totalBytes, "GreyboxProtocol buffer size mismatch")
	local noticeArg: string? = if resetNotice ~= "" then resetNotice else nil
	return buf, noticeArg
end

function GreyboxProtocol.unpackSnapshot(rawPayload: any, rawNotice: any): TelemetryPacket?
	if type(rawPayload) ~= "buffer" then
		return nil
	end
	local buf = rawPayload :: buffer
	local bufLen = buffer.len(buf)
	if bufLen < CORE_HEADER_BYTES + 1 then
		return nil
	end

	local off = 0
	local tick = buffer.readu32(buf, off)
	local lastInputSeq = buffer.readu32(buf, off + 4)
	local resetSeq = buffer.readu16(buf, off + 8)
	local serverTime = buffer.readf64(buf, off + 10)
	off += 18

	local pos = { buffer.readf64(buf, off), buffer.readf64(buf, off + 8), buffer.readf64(buf, off + 16) }
	local rot = {
		buffer.readf64(buf, off + 24),
		buffer.readf64(buf, off + 32),
		buffer.readf64(buf, off + 40),
		buffer.readf64(buf, off + 48),
	}
	local linVel = { buffer.readf64(buf, off + 56), buffer.readf64(buf, off + 64), buffer.readf64(buf, off + 72) }
	local angVel = { buffer.readf64(buf, off + 80), buffer.readf64(buf, off + 88), buffer.readf64(buf, off + 96) }
	off += 104

	local steer = buffer.readf32(buf, off)
	local skidFactor = buffer.readf32(buf, off + 4)
	local steeringFraction = buffer.readf32(buf, off + 8)
	local visualRotation = buffer.readf32(buf, off + 12)
	local hopHeight = buffer.readf32(buf, off + 16)
	local remainingJumpTime = buffer.readf32(buf, off + 20)
	local nitroEnergy = buffer.readf32(buf, off + 24)
	local energyToMinRatio = buffer.readf32(buf, off + 28)
	local timedImpulsePerSec = {
		buffer.readf32(buf, off + 32),
		buffer.readf32(buf, off + 36),
		buffer.readf32(buf, off + 40),
	}
	local timedRotationRate = buffer.readf32(buf, off + 44)
	local terrainFraction = buffer.readf32(buf, off + 48)
	local terrainTargetFraction = buffer.readf32(buf, off + 52)
	local squashFraction = buffer.readf32(buf, off + 56)
	local squashTargetFraction = buffer.readf32(buf, off + 60)
	local attachmentInitialSpeed = buffer.readf32(buf, off + 64)
	local bubbleFraction = buffer.readf32(buf, off + 68)
	local bubbleTargetFraction = buffer.readf32(buf, off + 72)
	off += 76

	local sectionFlags = buffer.readu8(buf, off)
	off += 1
	local bonusReady = bit32.btest(sectionFlags, 1)
	local nitroActive = bit32.btest(sectionFlags, 2)
	local fireWasDown = bit32.btest(sectionFlags, 4)
	local hasItemEffect = bit32.btest(sectionFlags, 8)
	local hasItemWorld = bit32.btest(sectionFlags, 16)
	local hasFlyables = bit32.btest(sectionFlags, 32)
	local hasRemoteKarts = bit32.btest(sectionFlags, 64)
	local hasSlipstream = bit32.btest(sectionFlags, 128)

	local skidCtrlId = buffer.readu8(buf, off)
	local skidStateId = buffer.readu8(buf, off + 1)
	local currentTier = buffer.readu8(buf, off + 2)
	local heldPowerup = buffer.readu8(buf, off + 3)
	local heldPowerupCount = buffer.readu8(buf, off + 4)
	local attachmentType = buffer.readu8(buf, off + 5)
	local stuckTicks = buffer.readu8(buf, off + 6)
	off += 7

	local brakeTicks = buffer.readi16(buf, off)
	local skidTimeTicks = buffer.readi16(buf, off + 2)
	local minNitroTicks = buffer.readi16(buf, off + 4)
	local timedImpulseTicks = buffer.readi16(buf, off + 6)
	local timedRotationTicks = buffer.readi16(buf, off + 8)
	local bounceBackTicks = buffer.readi16(buf, off + 10)
	local terrainFadeTicks = buffer.readi16(buf, off + 12)
	local squashFadeTicks = buffer.readi16(buf, off + 14)
	local squashDurationTicks = buffer.readi16(buf, off + 16)
	local attachmentTicksLeft = buffer.readi16(buf, off + 18)
	local bubbleFadeTicks = buffer.readi16(buf, off + 20)
	local bubbleDurationTicks = buffer.readi16(buf, off + 22)
	off += 24

	local raceTick = buffer.readu32(buf, off)
	local finishTick = buffer.readi32(buf, off + 4)
	local startupBoostMps = buffer.readf32(buf, off + 8)
	local racePhaseId = buffer.readu8(buf, off + 12)
	local raceLap = buffer.readi8(buf, off + 13)
	local raceNextCheckpoint = buffer.readu8(buf, off + 14)
	local raceFlags = buffer.readu8(buf, off + 15)
	local startupPenaltyTicks = buffer.readi16(buf, off + 16)
	off += 18
	local raceState: KartSolver.KartRaceState = {
		raceTick = raceTick,
		phase = RaceState.ID_TO_PHASE[racePhaseId] or "COUNTDOWN_3",
		lap = raceLap,
		nextCheckpoint = raceNextCheckpoint,
		raceFinished = bit32.btest(raceFlags, 1),
		finishTick = finishTick,
		startupHasPressed = bit32.btest(raceFlags, 2),
		startupBoostMps = startupBoostMps,
		startupPenaltyTicks = startupPenaltyTicks,
		startupBoostFired = bit32.btest(raceFlags, 4),
	}

	local itemEffect: ItemEffectState.NetEffectState
	if hasItemEffect then
		if off + ITEM_EFFECT_BASE_BYTES > bufLen then
			return nil
		end
		local effType = buffer.readu8(buf, off)
		local effFlags = buffer.readu8(buf, off + 1)
		local ticksRemaining = buffer.readi16(buf, off + 2)
		local totalTicks = buffer.readi16(buf, off + 4)
		local invulnerableTicks = buffer.readi16(buf, off + 6)
		local plungerFaceTicks = buffer.readi16(buf, off + 8)
		local externalPullTicks = buffer.readi16(buf, off + 10)
		off += ITEM_EFFECT_BASE_BYTES

		local originPos = { 0, 0, 0 }
		local originRot = { 1, 0, 0, 0 }
		local normal = { 0, 1, 0 }
		local initUpVel = 0.0
		local gravity = 0.0
		local addHeadingRate = 0.0
		local addPitchRate = 0.0
		local addRollRate = 0.0
		if bit32.btest(effFlags, 64) then
			if off + ITEM_EFFECT_EXPLOSION_BYTES > bufLen then
				return nil
			end
			originPos = {
				buffer.readf64(buf, off),
				buffer.readf64(buf, off + 8),
				buffer.readf64(buf, off + 16),
			}
			originRot = {
				buffer.readf64(buf, off + 24),
				buffer.readf64(buf, off + 32),
				buffer.readf64(buf, off + 40),
				buffer.readf64(buf, off + 48),
			}
			normal = {
				buffer.readf32(buf, off + 56),
				buffer.readf32(buf, off + 60),
				buffer.readf32(buf, off + 64),
			}
			initUpVel = buffer.readf32(buf, off + 68)
			gravity = buffer.readf32(buf, off + 72)
			addHeadingRate = buffer.readf32(buf, off + 76)
			addPitchRate = buffer.readf32(buf, off + 80)
			addRollRate = buffer.readf32(buf, off + 84)
			off += ITEM_EFFECT_EXPLOSION_BYTES
		end

		local slowdownFraction = 1.0
		local externalPullAccel = { 0, 0, 0 }
		if bit32.btest(effFlags, 128) then
			if off + ITEM_EFFECT_PULL_BYTES > bufLen then
				return nil
			end
			slowdownFraction = buffer.readf32(buf, off)
			externalPullAccel = {
				buffer.readf32(buf, off + 4),
				buffer.readf32(buf, off + 8),
				buffer.readf32(buf, off + 12),
			}
			off += ITEM_EFFECT_PULL_BYTES
		end

		itemEffect = {
			effectType = effType,
			ticksRemaining = ticksRemaining,
			totalTicks = totalTicks,
			suppressThrottle = bit32.btest(effFlags, 1),
			suppressSteer = bit32.btest(effFlags, 2),
			suppressDrift = bit32.btest(effFlags, 4),
			suppressFire = bit32.btest(effFlags, 8),
			torqueSign = bit32.btest(effFlags, 16),
			parachuteDragActive = bit32.btest(effFlags, 32),
			invulnerableTicks = invulnerableTicks,
			originPos = originPos,
			originRot = originRot,
			normal = normal,
			initUpVel = initUpVel,
			gravity = gravity,
			addHeadingRate = addHeadingRate,
			addPitchRate = addPitchRate,
			addRollRate = addRollRate,
			slowdownFraction = slowdownFraction,
			plungerFaceTicks = plungerFaceTicks,
			externalPullAccel = externalPullAccel,
			externalPullTicks = externalPullTicks,
		}
	else
		itemEffect = {
			effectType = 0,
			ticksRemaining = 0,
			totalTicks = 0,
			suppressThrottle = false,
			suppressSteer = false,
			suppressDrift = false,
			suppressFire = false,
			torqueSign = false,
			parachuteDragActive = false,
			invulnerableTicks = 0,
			originPos = { 0, 0, 0 },
			originRot = { 1, 0, 0, 0 },
			normal = { 0, 1, 0 },
			initUpVel = 0,
			gravity = 0,
			addHeadingRate = 0,
			addPitchRate = 0,
			addRollRate = 0,
			slowdownFraction = 1.0,
			plungerFaceTicks = 0,
			externalPullAccel = { 0, 0, 0 },
			externalPullTicks = 0,
		}
	end

	local slipstream: Slipstream.NetSlipstreamState? = nil
	local prevPos: { number }? = nil
	if hasSlipstream then
		if off + SLIPSTREAM_BYTES > bufLen then
			return nil
		end
		local ssFlags = buffer.readu8(buf, off)
		local hasCur = bit32.btest(ssFlags, 4)
		local hasPrev = bit32.btest(ssFlags, 8)
		local chargeTicks = buffer.readi16(buf, off + 63)
		slipstream = {
			mode = if bit32.btest(ssFlags, 1) then "COLLECT" else "NONE",
			inZone = bit32.btest(ssFlags, 64),
			chargeTicks = chargeTicks,
			slipstreamTime = buffer.readf64(buf, off + 1),
			bonusTime = buffer.readf64(buf, off + 9),
			bonusActive = bit32.btest(ssFlags, 2),
			currentTargetId = if hasCur then buffer.readf64(buf, off + 17) else nil,
			previousTargetId = if hasPrev then buffer.readf64(buf, off + 25) else nil,
			speedIncreaseTick = buffer.readi32(buf, off + 33),
			speedIncreaseDurationTicks = buffer.readi16(buf, off + 37),
			inInnerQuad = bit32.btest(ssFlags, 16),
			inOuterQuad = bit32.btest(ssFlags, 32),
		}
		prevPos = {
			buffer.readf64(buf, off + 39),
			buffer.readf64(buf, off + 47),
			buffer.readf64(buf, off + 55),
		}
		off += SLIPSTREAM_BYTES
	end

	if off + 1 > bufLen then
		return nil
	end
	local nIncs = buffer.readu8(buf, off)
	off += 1
	if off + nIncs * INCREASE_ENTRY_BYTES > bufLen then
		return nil
	end
	local increases: { KartSolver.NetIncreaseSnapshot } = table.create(nIncs)
	for _ = 1, nIncs do
		local cat = INC_CATS[buffer.readu8(buf, off)]
		if cat ~= nil then
			table.insert(increases, {
				cat = cat :: MaxSpeed.SpeedIncreaseCategory,
				maxAddSpeed = buffer.readf32(buf, off + 1),
				currentSpeedup = buffer.readf32(buf, off + 5),
				engineForce = buffer.readf32(buf, off + 9),
				durationTicks = buffer.readi16(buf, off + 13),
				fadeOutTicks = buffer.readi16(buf, off + 15),
			})
		end
		off += INCREASE_ENTRY_BYTES
	end

	local itemWorldSnapshot: ItemWorld.ItemWorldSnapshot? = nil
	if hasItemWorld then
		if off + 10 > bufLen then
			return nil
		end
		local elapsedTicks = buffer.readi32(buf, off)
		local nextDynamicId = buffer.readu16(buf, off + 4)
		local switchTicks = buffer.readi16(buf, off + 6)
		local nCooldowns = buffer.readu8(buf, off + 8)
		local nDynamics = buffer.readu8(buf, off + 9)
		off += 10
		if off + nCooldowns * COOLDOWN_ENTRY_BYTES + nDynamics * DYNAMIC_ITEM_ENTRY_BYTES > bufLen then
			return nil
		end
		local cooldowns: { ItemWorld.NetTrackCooldown } = table.create(nCooldowns)
		for _ = 1, nCooldowns do
			table.insert(cooldowns, {
				id = buffer.readu16(buf, off),
				ticksTillReturn = buffer.readi16(buf, off + 2),
				deactiveTicks = buffer.readi16(buf, off + 4),
			})
			off += COOLDOWN_ENTRY_BYTES
		end
		local dynamics: { ItemWorld.NetDynamicItem } = table.create(nDynamics)
		for _ = 1, nDynamics do
			local typeId = buffer.readu8(buf, off + 2)
			local origId = buffer.readu8(buf, off + 3)
			local origType: ItemWorld.ItemType? = if origId > 0 then ITEM_TYPES[origId] :: ItemWorld.ItemType? else nil
			table.insert(dynamics, {
				id = buffer.readu16(buf, off),
				itemType = (ITEM_TYPES[typeId] or "banana") :: ItemWorld.ItemType,
				originalType = origType,
				pos = {
					x = buffer.readf32(buf, off + 4),
					y = buffer.readf32(buf, off + 8),
					z = buffer.readf32(buf, off + 12),
				},
				deactiveTicks = buffer.readi16(buf, off + 16),
				disappearCounter = buffer.readi16(buf, off + 18),
				ownerId = buffer.readf64(buf, off + 20),
			})
			off += DYNAMIC_ITEM_ENTRY_BYTES
		end
		itemWorldSnapshot = {
			elapsedTicks = elapsedTicks,
			nextDynamicId = nextDynamicId,
			switchTicks = switchTicks,
			trackCooldowns = cooldowns,
			dynamicItems = dynamics,
		}
	end

	local flyableSnapshot: Flyable.FlyableSnapshot? = nil
	if hasFlyables then
		if off + 3 > bufLen then
			return nil
		end
		local nextId = buffer.readu16(buf, off)
		local nFly = buffer.readu8(buf, off + 2)
		off += 3
		local fEntries: { Flyable.NetFlyableEntry } = table.create(nFly)
		for _ = 1, nFly do
			if off + FLYABLE_BASE_BYTES > bufLen then
				return nil
			end
			local id = buffer.readu16(buf, off)
			local kindId = buffer.readu8(buf, off + 2)
			local kind: Flyable.FlyableKind = if kindId == 2
				then "cake"
				elseif kindId == 3 then "plunger"
				elseif kindId == 4 then "rubber_ball"
				else "bowling"
			local bFlags = buffer.readu8(buf, off + 3)
			local ownerId = buffer.readf64(buf, off + 4)
			local ePos = {
				buffer.readf64(buf, off + 12),
				buffer.readf64(buf, off + 20),
				buffer.readf64(buf, off + 28),
			}
			local eVel = {
				buffer.readf64(buf, off + 36),
				buffer.readf64(buf, off + 44),
				buffer.readf64(buf, off + 52),
			}
			local eRot = {
				buffer.readf32(buf, off + 60),
				buffer.readf32(buf, off + 64),
				buffer.readf32(buf, off + 68),
				buffer.readf32(buf, off + 72),
			}
			local speedScalar = buffer.readf32(buf, off + 76)
			local ticksSinceThrown = buffer.readi16(buf, off + 80)
			local maxLifespanTicks = buffer.readi16(buf, off + 82)
			off += FLYABLE_BASE_BYTES

			local radius, gravity, restitution = defaultFlyablePhys(kind)
			if bit32.btest(bFlags, 16) then
				if off + FLYABLE_CUSTOM_PHYS_BYTES > bufLen then
					return nil
				end
				radius = buffer.readf32(buf, off)
				gravity = buffer.readf32(buf, off + 4)
				restitution = buffer.readf32(buf, off + 8)
				off += FLYABLE_CUSTOM_PHYS_BYTES
			end

			local targetKartId = 0
			if bit32.btest(bFlags, 32) then
				if off + FLYABLE_TARGET_BYTES > bufLen then
					return nil
				end
				targetKartId = buffer.readf64(buf, off)
				off += FLYABLE_TARGET_BYTES
			end

			local deleteTicks = -1
			local drivelineIdx = 1
			local bouncePhaseSec = 0.0
			if bit32.btest(bFlags, 64) then
				if off + FLYABLE_RUBBER_BYTES > bufLen then
					return nil
				end
				deleteTicks = buffer.readi16(buf, off)
				drivelineIdx = buffer.readi16(buf, off + 2)
				bouncePhaseSec = buffer.readf32(buf, off + 4)
				off += FLYABLE_RUBBER_BYTES
			end

			local keepAliveTicks = -1
			local bandState = 0
			local bandTargetKartId = 0
			local bandAnchorPos = { 0, 0, 0 }
			if bit32.btest(bFlags, 128) then
				if off + FLYABLE_PLUNGER_BYTES > bufLen then
					return nil
				end
				keepAliveTicks = buffer.readi16(buf, off)
				bandState = buffer.readu8(buf, off + 2)
				bandTargetKartId = buffer.readf64(buf, off + 3)
				bandAnchorPos = {
					buffer.readf32(buf, off + 11),
					buffer.readf32(buf, off + 15),
					buffer.readf32(buf, off + 19),
				}
				off += FLYABLE_PLUNGER_BYTES
			end

			table.insert(fEntries, {
				id = id,
				kind = kind,
				ownerId = ownerId,
				pos = ePos,
				vel = eVel,
				rot = eRot,
				radius = radius,
				gravity = gravity,
				restitution = restitution,
				speedScalar = speedScalar,
				ticksSinceThrown = ticksSinceThrown,
				maxLifespanTicks = maxLifespanTicks,
				reverseMode = bit32.btest(bFlags, 1),
				isBattle = bit32.btest(bFlags, 2),
				hasHitSomething = bit32.btest(bFlags, 4),
				movedToInfinity = bit32.btest(bFlags, 8),
				keepAliveTicks = keepAliveTicks,
				targetKartId = targetKartId,
				deleteTicks = deleteTicks,
				drivelineIdx = drivelineIdx,
				bouncePhaseSec = bouncePhaseSec,
				bandState = bandState,
				bandTargetKartId = bandTargetKartId,
				bandAnchorPos = bandAnchorPos,
			})
		end
		flyableSnapshot = {
			nextId = nextId,
			entries = fEntries,
		}
	end

	local remoteKarts: { RemoteKartState }? = nil
	if hasRemoteKarts then
		if off + 1 > bufLen then
			return nil
		end
		local nRem = buffer.readu8(buf, off)
		off += 1
		local rList: { RemoteKartState } = table.create(nRem)
		for _ = 1, nRem do
			if off + 1 > bufLen then
				return nil
			end
			local idLen = buffer.readu8(buf, off)
			if off + 1 + idLen + REMOTE_KART_FIXED_BYTES > bufLen then
				return nil
			end
			local rid = buffer.readstring(buf, off + 1, idLen)
			local rOff = off + 1 + idLen
			local rkFlags = buffer.readu8(buf, rOff + 53)
			table.insert(rList, {
				id = rid,
				pos = { buffer.readf32(buf, rOff), buffer.readf32(buf, rOff + 4), buffer.readf32(buf, rOff + 8) },
				rot = {
					buffer.readf32(buf, rOff + 12),
					buffer.readf32(buf, rOff + 16),
					buffer.readf32(buf, rOff + 20),
					buffer.readf32(buf, rOff + 24),
				},
				linVel = {
					buffer.readf32(buf, rOff + 28),
					buffer.readf32(buf, rOff + 32),
					buffer.readf32(buf, rOff + 36),
				},
				speed = buffer.readf32(buf, rOff + 40),
				steer = buffer.readf32(buf, rOff + 44),
				attachmentType = buffer.readu8(buf, rOff + 48),
				plungerFaceTicks = buffer.readi16(buf, rOff + 49),
				timedImpulseTicks = buffer.readi16(buf, rOff + 51),
				isSquashed = bit32.btest(rkFlags, 1),
				raceFinished = bit32.btest(rkFlags, 2),
				rank = buffer.readu8(buf, rOff + 54),
				lap = buffer.readi8(buf, rOff + 55),
				trackNodeIdx = buffer.readu16(buf, rOff + 56),
				slipstreamTime = buffer.readu8(buf, rOff + 58) * (8.0 / 255),
				slipstreamBonusTime = buffer.readu8(buf, rOff + 59) * (8.0 / 255),
				attachmentTicksLeft = buffer.readi16(buf, rOff + 60),
				nextCheckpoint = buffer.readu8(buf, rOff + 62),
				finishTick = buffer.readi32(buf, rOff + 63),
			})
			off = rOff + REMOTE_KART_FIXED_BYTES
		end
		remoteKarts = rList
	end

	local netState: KartSolver.NetState = {
		pos = pos,
		prevPos = prevPos,
		rot = rot,
		linVel = linVel,
		angVel = angVel,
		steer = steer,
		latchedSkidControl = SKID_CONTROLS[skidCtrlId] or "NONE",
		brakeTicks = brakeTicks,
		skidState = SKID_STATES[skidStateId] or "SKID_NONE",
		skidTimeTicks = skidTimeTicks,
		skidFactor = skidFactor,
		steeringFraction = steeringFraction,
		visualRotation = visualRotation,
		hopHeight = hopHeight,
		remainingJumpTime = remainingJumpTime,
		bonusReady = bonusReady,
		currentTier = currentTier,
		nitroEnergy = nitroEnergy,
		minNitroTicks = minNitroTicks,
		energyToMinRatio = energyToMinRatio,
		nitroActive = nitroActive,
		timedImpulsePerSec = timedImpulsePerSec,
		timedImpulseTicks = timedImpulseTicks,
		timedRotationTicks = timedRotationTicks,
		timedRotationRate = timedRotationRate,
		bounceBackTicks = bounceBackTicks,
		stuckTicks = stuckTicks,
		terrainFraction = terrainFraction,
		terrainTargetFraction = terrainTargetFraction,
		terrainFadeTicks = terrainFadeTicks,
		heldPowerup = heldPowerup,
		heldPowerupCount = heldPowerupCount,
		fireWasDown = fireWasDown,
		squashFraction = squashFraction,
		squashTargetFraction = squashTargetFraction,
		squashFadeTicks = squashFadeTicks,
		squashDurationTicks = squashDurationTicks,
		attachmentType = attachmentType,
		attachmentTicksLeft = attachmentTicksLeft,
		attachmentInitialSpeed = attachmentInitialSpeed,
		bubbleFraction = bubbleFraction,
		bubbleTargetFraction = bubbleTargetFraction,
		bubbleFadeTicks = bubbleFadeTicks,
		bubbleDurationTicks = bubbleDurationTicks,
		itemEffect = itemEffect,
		increases = increases,
		slipstreamChargeTicks = if slipstream ~= nil then slipstream.chargeTicks else 0,
		slipstream = slipstream,
		race = raceState,
		itemWorldSnapshot = itemWorldSnapshot,
		flyableSnapshot = flyableSnapshot,
	}

	return {
		tick = tick,
		lastInputSeq = lastInputSeq,
		resetSeq = resetSeq,
		serverTime = serverTime,
		resetNotice = if type(rawNotice) == "string" then rawNotice else "",
		netState = netState,
		remoteKarts = remoteKarts,
	}
end

return table.freeze(GreyboxProtocol)
