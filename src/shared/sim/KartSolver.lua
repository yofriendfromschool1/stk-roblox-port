--!strict
-- src/shared/sim/KartSolver.lua
-- SPDX-License-Identifier: GPL-3.0-or-later
-- ported from src/physics/btKart.cpp:L225-L639, L750-L993,
-- src/karts/kart.cpp:L912-L924, L1216-L1245, L1513-L1529, L2610-L2958 (STK 1.5)
-- Pure-math Luau raycast kart physics solver (zero Roblox API dependencies).

local FixedStep = require("./FixedStep")
local ItemTuning = require("../ItemTuning")
local ItemWorld = require("../items/ItemWorld")
local KartTuning = require("../KartTuning")
local Math3D = require("./Math3D")
local MaxSpeed = require("../kart/MaxSpeed")
local Nitro = require("../kart/Nitro")
local Skidding = require("../kart/Skidding")
local SurfaceMaterials = require("../track/SurfaceMaterials")

export type Vec3 = Math3D.Vec3
export type Quat = Math3D.Quat
export type SkidControl = Skidding.SkidControl

export type RayHit = {
	distance: number,
	point: Vec3,
	normal: Vec3,
	highTireAdhesion: boolean?,
	surfaceGrip: number?,
	materialName: string?,
}

export type SweepHit = {
	fraction: number,
	point: Vec3,
	normal: Vec3,
	materialName: string?,
}

export type Contact = {
	point: Vec3,
	normal: Vec3,
	depth: number,
	materialName: string?,
	isWheel: boolean,
}

export type WorldQuery = {
	raycast: (origin: Vec3, dir: Vec3, length: number) -> RayHit?,
	sweepChassis: ((center: Vec3, rot: Quat, halfExtents: Vec3, delta: Vec3) -> SweepHit?)?,
	checkChassisOverlap: ((center: Vec3, rot: Quat, halfExtents: Vec3) -> boolean)?,
}

export type KartInput = {
	accel: number,
	brake: boolean,
	steer: number, -- [-1, +1]: negative = left, positive = right (STK convention)
	drift: boolean,
	nitro: boolean?,
	fire: boolean?,
	skidControl: SkidControl?,
	instantSteer: boolean?,
}

export type WheelState = {
	isInContact: boolean,
	suspensionLength: number,
	rawHitDistance: number,
	compressionRatio: number,
	suspensionRelVel: number,
	clippedInvContactDot: number,
	suspensionForce: number,
	contactPointWS: Vec3,
	contactNormalWS: Vec3,
	hardPointWS: Vec3,
	slipAngleRad: number,
	highTireAdhesion: boolean,
	surfaceGrip: number,
	materialName: string,
}

export type KartState = {
	profile: KartTuning.KartProfile,
	pos: Vec3,
	rot: Quat,
	linVel: Vec3,
	angVel: Vec3,
	speed: number, -- signed forward speed (m/s)
	steer: number, -- smoothed steer in [-1, +1]
	latchedSkidControl: SkidControl,
	brakeTicks: number,
	numWheelsOnGround: number,
	isOnGround: boolean,
	wheels: { WheelState },
	skid: Skidding.SkidState,
	maxSpeedState: MaxSpeed.MaxSpeedState,
	nitro: Nitro.NitroState,
	-- Powerup inventory & PA_FIRE edge trigger (powerup.hpp:L22, kart.cpp:L1643-L1654)
	heldPowerup: number,
	heldPowerupCount: number,
	fireWasDown: boolean,
	-- Timed impulses & post-skid alignment rotation (btKart.cpp:L504-L533)
	timedImpulseTicks: number,
	timedImpulsePerSec: Vec3,
	timedRotationTicks: number,
	timedRotationRate: number,
	-- Surface state & collision reaction (kart.cpp:L1709-L1737, L2445-L2460)
	activeMaterialName: string,
	resetTriggered: boolean,
	lastCollisionReaction: SurfaceMaterials.CollisionReaction,
	bounceBackTicks: number,
	-- Last non-overlapping pose for static overlap recovery
	lastSafePos: Vec3,
	lastSafeRot: Quat,
	-- Telemetry
	maxSlipAngleRad: number,
	frontSteerAngleRad: number,
	maxCompressionRatio: number,
	depenetrationCount: number,
	chassisSweepHitCount: number,
	gravity: number,
}

export type NetIncreaseSnapshot = {
	cat: MaxSpeed.SpeedIncreaseCategory,
	maxAddSpeed: number,
	currentSpeedup: number,
	engineForce: number,
	durationTicks: number,
	fadeOutTicks: number,
}

export type NetState = {
	pos: { number },
	rot: { number },
	linVel: { number },
	angVel: { number },
	steer: number,
	latchedSkidControl: SkidControl,
	brakeTicks: number,
	skidState: Skidding.SkidStateName,
	skidTimeTicks: number,
	skidFactor: number,
	steeringFraction: number,
	visualRotation: number,
	hopHeight: number,
	remainingJumpTime: number,
	bonusReady: boolean,
	currentTier: number,
	nitroEnergy: number,
	minNitroTicks: number,
	energyToMinRatio: number,
	nitroActive: boolean,
	timedImpulseTicks: number,
	timedImpulsePerSec: { number },
	timedRotationTicks: number,
	timedRotationRate: number,
	bounceBackTicks: number,
	terrainFraction: number,
	terrainTargetFraction: number,
	terrainFadeTicks: number,
	squashFraction: number?,
	squashTargetFraction: number?,
	squashFadeTicks: number?,
	squashDurationTicks: number?,
	heldPowerup: number?,
	heldPowerupCount: number?,
	fireWasDown: boolean?,
	increases: { NetIncreaseSnapshot },
	itemWorldSnapshot: ItemWorld.ItemWorldSnapshot?,
}

export type KartTelemetry = {
	speedMps: number,
	maxSlipAngleRad: number,
	skidState: Skidding.SkidStateName,
	skidTier: number,
	skidTimeSec: number,
	skidFactor: number,
	steeringFraction: number,
	visualSkidYaw: number,
	hopHeight: number,
	isAirborne: boolean,
	isOnGround: boolean,
	numWheelsOnGround: number,
	currentMaxSpeed: number,
	activeMaterialName: string,
	resetTriggered: boolean,
	lastCollisionReaction: SurfaceMaterials.CollisionReaction,
	nitroEnergy: number,
	nitroMaxEnergy: number,
	nitroActive: boolean,
	maxCompressionRatio: number,
	chassisSweepHits: number,
}

local MAX_IGNORE_RAY_PASSES = 4

local KartSolver = {}

local function newWheelState(): WheelState
	return {
		isInContact = false,
		suspensionLength = KartTuning.suspension.rest,
		rawHitDistance = KartTuning.suspension.rest,
		compressionRatio = 0.0,
		suspensionRelVel = 0,
		clippedInvContactDot = 1.0,
		suspensionForce = 0,
		contactPointWS = { x = 0, y = 0, z = 0 },
		contactNormalWS = { x = 0, y = 1, z = 0 },
		hardPointWS = { x = 0, y = 0, z = 0 },
		slipAngleRad = 0,
		highTireAdhesion = false,
		surfaceGrip = 1.0,
		materialName = "default",
	}
end

function KartSolver.createState(profile: KartTuning.KartProfile?, spawnPos: Vec3?, spawnYawRad: number?): KartState
	local prof = profile or KartTuning.buildProfile("medium", "best")
	local pos = if spawnPos then { x = spawnPos.x, y = spawnPos.y, z = spawnPos.z } else { x = 0, y = 0.30, z = 0 }
	local rot = if spawnYawRad and spawnYawRad ~= 0
		then Math3D.quatFromAxisAngle({ x = 0, y = 1, z = 0 }, spawnYawRad)
		else Math3D.quatIdentity()

	return {
		profile = prof,
		pos = pos,
		rot = rot,
		linVel = { x = 0, y = 0, z = 0 },
		angVel = { x = 0, y = 0, z = 0 },
		speed = 0,
		steer = 0,
		latchedSkidControl = "NONE",
		brakeTicks = 0,
		numWheelsOnGround = 0,
		isOnGround = false,
		wheels = { newWheelState(), newWheelState(), newWheelState(), newWheelState() },
		skid = Skidding.new(),
		maxSpeedState = MaxSpeed.new(prof.maxSpeed),
		nitro = Nitro.new(prof.nitro.max),
		heldPowerup = ItemTuning.POWERUP_NONE,
		heldPowerupCount = 0,
		fireWasDown = false,
		timedImpulseTicks = 0,
		timedImpulsePerSec = { x = 0, y = 0, z = 0 },
		timedRotationTicks = 0,
		timedRotationRate = 0,
		activeMaterialName = "default",
		resetTriggered = false,
		lastCollisionReaction = "normal",
		bounceBackTicks = 0,
		lastSafePos = { x = pos.x, y = pos.y, z = pos.z },
		lastSafeRot = { w = rot.w, x = rot.x, y = rot.y, z = rot.z },
		maxSlipAngleRad = 0,
		frontSteerAngleRad = 0,
		maxCompressionRatio = 0,
		depenetrationCount = 0,
		chassisSweepHitCount = 0,
		gravity = KartTuning.physics.DEFAULT_GRAVITY,
	}
end

function KartSolver.captureNetState(state: KartState, itemWorld: ItemWorld.ItemWorldState?): NetState
	local increases: { NetIncreaseSnapshot } = {}
	for _, cat in MaxSpeed.INCREASE_CATEGORIES do
		local entry = state.maxSpeedState.increases[cat]
		if entry.active then
			table.insert(increases, {
				cat = cat :: MaxSpeed.SpeedIncreaseCategory,
				maxAddSpeed = entry.maxAddSpeed,
				currentSpeedup = entry.currentSpeedup,
				engineForce = entry.engineForce,
				durationTicks = entry.durationTicks,
				fadeOutTicks = entry.fadeOutTicks,
			})
		end
	end
	local terrain = state.maxSpeedState.decreases["TERRAIN"]
	local squash = state.maxSpeedState.decreases["SQUASH"]
	return {
		pos = { state.pos.x, state.pos.y, state.pos.z },
		rot = { state.rot.w, state.rot.x, state.rot.y, state.rot.z },
		linVel = { state.linVel.x, state.linVel.y, state.linVel.z },
		angVel = { state.angVel.x, state.angVel.y, state.angVel.z },
		steer = state.steer,
		latchedSkidControl = state.latchedSkidControl,
		brakeTicks = state.brakeTicks,
		skidState = state.skid.state,
		skidTimeTicks = state.skid.skidTimeTicks,
		skidFactor = state.skid.skidFactor,
		steeringFraction = state.skid.steeringFraction,
		visualRotation = state.skid.visualRotation,
		hopHeight = state.skid.hopHeight,
		remainingJumpTime = state.skid.remainingJumpTime,
		bonusReady = state.skid.bonusReady,
		currentTier = state.skid.currentTier,
		nitroEnergy = state.nitro.energy,
		minNitroTicks = state.nitro.minNitroTicks,
		energyToMinRatio = state.nitro.energyToMinRatio,
		nitroActive = state.nitro.active,
		timedImpulseTicks = state.timedImpulseTicks,
		timedImpulsePerSec = { state.timedImpulsePerSec.x, state.timedImpulsePerSec.y, state.timedImpulsePerSec.z },
		timedRotationTicks = state.timedRotationTicks,
		timedRotationRate = state.timedRotationRate,
		bounceBackTicks = state.bounceBackTicks,
		terrainFraction = if terrain then terrain.currentFraction else 1.0,
		terrainTargetFraction = if terrain then terrain.targetFraction else 1.0,
		terrainFadeTicks = if terrain then terrain.fadeInTicks else 0,
		squashFraction = if squash then squash.currentFraction else 1.0,
		squashTargetFraction = if squash then squash.targetFraction else 1.0,
		squashFadeTicks = if squash then squash.fadeInTicks else 0,
		squashDurationTicks = if squash then squash.durationTicks else 0,
		heldPowerup = state.heldPowerup,
		heldPowerupCount = state.heldPowerupCount,
		fireWasDown = state.fireWasDown,
		increases = increases,
		itemWorldSnapshot = if itemWorld ~= nil then ItemWorld.captureSnapshot(itemWorld) else nil,
	}
end

function KartSolver.applyNetState(state: KartState, snap: NetState, itemWorld: ItemWorld.ItemWorldState?)
	state.pos = { x = snap.pos[1], y = snap.pos[2], z = snap.pos[3] }
	state.rot = { w = snap.rot[1], x = snap.rot[2], y = snap.rot[3], z = snap.rot[4] }
	state.linVel = { x = snap.linVel[1], y = snap.linVel[2], z = snap.linVel[3] }
	state.angVel = { x = snap.angVel[1], y = snap.angVel[2], z = snap.angVel[3] }
	state.lastSafePos = { x = snap.pos[1], y = snap.pos[2], z = snap.pos[3] }
	state.lastSafeRot = { w = snap.rot[1], x = snap.rot[2], y = snap.rot[3], z = snap.rot[4] }
	state.steer = snap.steer
	state.latchedSkidControl = snap.latchedSkidControl
	state.brakeTicks = snap.brakeTicks

	state.skid.state = snap.skidState
	state.skid.skidTimeTicks = snap.skidTimeTicks
	state.skid.skidFactor = snap.skidFactor
	state.skid.steeringFraction = snap.steeringFraction
	state.skid.visualRotation = snap.visualRotation
	state.skid.hopHeight = snap.hopHeight
	state.skid.remainingJumpTime = snap.remainingJumpTime
	state.skid.bonusReady = snap.bonusReady
	state.skid.currentTier = snap.currentTier

	state.nitro.energy = snap.nitroEnergy
	state.nitro.minNitroTicks = snap.minNitroTicks
	state.nitro.energyToMinRatio = snap.energyToMinRatio
	state.nitro.active = snap.nitroActive

	state.heldPowerup = snap.heldPowerup or ItemTuning.POWERUP_NONE
	state.heldPowerupCount = snap.heldPowerupCount or 0
	state.fireWasDown = snap.fireWasDown == true

	state.timedImpulseTicks = snap.timedImpulseTicks
	state.timedImpulsePerSec = {
		x = snap.timedImpulsePerSec[1],
		y = snap.timedImpulsePerSec[2],
		z = snap.timedImpulsePerSec[3],
	}
	state.timedRotationTicks = snap.timedRotationTicks
	state.timedRotationRate = snap.timedRotationRate
	state.bounceBackTicks = snap.bounceBackTicks

	MaxSpeed.reset(state.maxSpeedState)
	for _, inc in snap.increases do
		local target = state.maxSpeedState.increases[inc.cat]
		target.active = true
		target.maxAddSpeed = inc.maxAddSpeed
		target.currentSpeedup = inc.currentSpeedup
		target.engineForce = inc.engineForce
		target.durationTicks = inc.durationTicks
		target.fadeOutTicks = inc.fadeOutTicks
	end
	if snap.terrainTargetFraction < 1.0 or snap.terrainFraction < 1.0 then
		MaxSpeed.setSlowdown(state.maxSpeedState, "TERRAIN", snap.terrainTargetFraction, snap.terrainFadeTicks, -1)
		local terrain = state.maxSpeedState.decreases["TERRAIN"]
		if terrain then
			terrain.currentFraction = snap.terrainFraction
		end
	end
	local squashTarget = snap.squashTargetFraction or 1.0
	local squashFrac = snap.squashFraction or 1.0
	if squashTarget < 1.0 or squashFrac < 1.0 then
		MaxSpeed.setSlowdown(
			state.maxSpeedState,
			"SQUASH",
			squashTarget,
			snap.squashFadeTicks or 0,
			snap.squashDurationTicks or 0
		)
		local squash = state.maxSpeedState.decreases["SQUASH"]
		if squash then
			squash.currentFraction = squashFrac
		end
	end

	if itemWorld ~= nil and snap.itemWorldSnapshot ~= nil then
		ItemWorld.applySnapshot(itemWorld, snap.itemWorldSnapshot)
	end

	local _, _, fwd = Math3D.quatBasis(state.rot)
	local signed = Math3D.dot(state.linVel, fwd)
	state.speed = if math.abs(signed) < KartTuning.physics.SPEED_DEADBAND then 0.0 else signed
end

function KartSolver.setPowerup(state: KartState, powerupId: number, count: number)
	if powerupId <= ItemTuning.POWERUP_NONE or count <= 0 then
		state.heldPowerup = ItemTuning.POWERUP_NONE
		state.heldPowerupCount = 0
		return
	end
	state.heldPowerup = powerupId
	state.heldPowerupCount = math.clamp(math.floor(count), 1, ItemTuning.timing.MAX_POWERUPS)
end

-- Slice 1 banana contact effect: SQUASH MaxSpeed slowdown (powerup.xml:L88 / kart_characteristics.xml:L260-L261)
-- plus upward/yaw knockback impulse.
function KartSolver.applyBananaHit(state: KartState)
	local b = ItemTuning.banana
	MaxSpeed.setSlowdown(
		state.maxSpeedState,
		"SQUASH",
		b.SQUASH_SLOWDOWN,
		FixedStep.timeToTicks(b.SQUASH_FADE_IN_SEC),
		FixedStep.timeToTicks(b.SQUASH_DURATION_SEC)
	)
	state.linVel.y = math.max(state.linVel.y, b.KNOCKBACK_UP_VEL)
	state.timedRotationTicks = b.KNOCKBACK_YAW_TICKS
	state.timedRotationRate = b.KNOCKBACK_YAW_RATE
end

function KartSolver.addNitro(state: KartState, amount: number): number
	return Nitro.collect(state.nitro, amount)
end

-- Guarded wheel slip angle (docs/physics-spec.md §4.3):
-- 1) Below SLIP_SPEED_FLOOR (0.05 m/s) returns 0 (avoids atan2(0, 0) and standstill steer rotation).
-- 2) Uses max(|vFwd|, SLIP_EPSILON_SPEED) so negative vFwd (reverse) never returns +-pi.
function KartSolver.computeSlipAngle(vFwd: number, vLat: number): number
	local speedSq = vFwd * vFwd + vLat * vLat
	local floor = KartTuning.physics.SLIP_SPEED_FLOOR
	if speedSq < floor * floor then
		return 0.0
	end
	local denom = math.max(math.abs(vFwd), KartTuning.physics.SLIP_EPSILON_SPEED)
	return math.atan2(vLat, denom)
end

-- Pacejka-lite lateral grip curve mu(alpha) (docs/physics-spec.md §4.3)
function KartSolver.evaluateLateralGrip(alpha: number): number
	local tire = KartTuning.tire
	local bx = tire.B * alpha
	local inner = bx - tire.E * (bx - math.atan(bx))
	return tire.muPeak * math.sin(tire.C * math.atan(inner))
end

-- Smooth digital steer ramp (src/karts/controller/player_controller.cpp:L268-L313)
local function updateSmoothedSteer(state: KartState, input: KartInput, dt: number)
	local target = math.clamp(input.steer, -1.0, 1.0)
	if input.instantSteer then
		state.steer = target
		return
	end
	if KartTuning.turn.disableWhileUnskid and state.latchedSkidControl == "NONE" and state.skid.visualRotation ~= 0 then
		state.steer = 0
		return
	end

	local cur = state.steer
	local returningToCenter = (target == 0)
		or (target < 0 and cur > 0)
		or (target > 0 and cur < 0)
		or (math.abs(target) < math.abs(cur) and target * cur > 0)

	local rateTime = if returningToCenter
		then KartTuning.turn.timeResetSteer
		else Math3D.evalPiecewiseLinear(KartTuning.turn.timeFullSteer, math.abs(cur))
	local maxDelta = dt / rateTime

	local diff = target - cur
	if math.abs(diff) <= maxDelta then
		state.steer = target
	else
		state.steer = math.clamp(cur + Math3D.sign(diff) * maxDelta, -1.0, 1.0)
	end
end

-- Latch SC_NO_DIRECTION -> SC_LEFT / SC_RIGHT when drift button is held (player_controller.cpp:L152-L174)
local function resolveSkidControl(state: KartState, input: KartInput): SkidControl
	local explicit: SkidControl? = input.skidControl
	if explicit ~= nil then
		state.latchedSkidControl = explicit
		return explicit
	end
	if not input.drift then
		local noneVal: SkidControl = "NONE"
		state.latchedSkidControl = noneVal
		return noneVal
	end
	if state.latchedSkidControl == "LEFT" or state.latchedSkidControl == "RIGHT" then
		return state.latchedSkidControl
	end
	local thresh = KartTuning.skid.minSteerThreshold
	if input.steer < -thresh then
		local leftVal: SkidControl = "LEFT"
		state.latchedSkidControl = leftVal
		return leftVal
	elseif input.steer > thresh then
		local rightVal: SkidControl = "RIGHT"
		state.latchedSkidControl = rightVal
		return rightVal
	else
		local noDirVal: SkidControl = "NO_DIRECTION"
		state.latchedSkidControl = noDirVal
		return noDirVal
	end
end

-- Speed-indexed maximum wheel steer angle (src/karts/kart.cpp:L912-L924)
local function getMaxSteerAngle(profile: KartTuning.KartProfile, speedAbs: number): number
	local tbl = profile.turnRadius
	local n = #tbl
	if n == 0 then
		return 0
	end
	local function entryAngle(idx: number): number
		return math.sin(1.0 / tbl[idx][2]) * profile.wheelBase
	end
	if speedAbs <= tbl[1][1] then
		return entryAngle(1)
	end
	for i = 2, n do
		if speedAbs <= tbl[i][1] then
			local x0 = tbl[i - 1][1]
			local x1 = tbl[i][1]
			local a0 = entryAngle(i - 1)
			local a1 = entryAngle(i)
			local t = (speedAbs - x0) / (x1 - x0)
			return a0 + (a1 - a0) * t
		end
	end
	return entryAngle(n)
end

-- Gear force lookup (src/karts/kart.cpp:L1216-L1235)
local function getActualWheelForce(profile: KartTuning.KartProfile, speed: number, addForce: number): number
	local ratios = profile.gearSwitchRatio
	local powers = profile.gearPowerIncrease
	for i = 1, #ratios do
		if speed <= profile.maxSpeed * ratios[i] then
			return profile.enginePower * powers[i] + addForce
		end
	end
	return profile.enginePower + addForce * KartTuning.engine.overGearAddForceMult
end

-- Air friction & Bullet linear damping compensation (src/karts/kart.cpp:L2738-L2773)
local function applyAirFriction(enginePower: number, speed: number, mass: number): number
	local eng = KartTuning.engine
	local absSpeed = math.abs(speed)
	local massFactor = mass / eng.airDragRefMass
	local linearComp = eng.airDragLinearComp * absSpeed * massFactor
	local nonlinearDrag = absSpeed * math.sqrt(absSpeed) * eng.airDragNonlinearCoeff
	return enginePower + linearComp - nonlinearDrag
end

-- World-space angular impulse using body-frame diagonal inverse inertia (angularFactor pre-baked)
local function applyWorldTorqueImpulse(state: KartState, torqueImpulseWS: Vec3)
	local qConj = Math3D.quatConjugate(state.rot)
	local tauLocal = Math3D.quatRotateVec(qConj, torqueImpulseWS)
	local invI = state.profile.invInertia
	local dOmegaLocal: Vec3 = {
		x = tauLocal.x * invI.x,
		y = tauLocal.y * invI.y,
		z = tauLocal.z * invI.z,
	}
	local dOmegaWS = Math3D.quatRotateVec(state.rot, dOmegaLocal)
	state.angVel.x += dOmegaWS.x
	state.angVel.y += dOmegaWS.y
	state.angVel.z += dOmegaWS.z
end

local function applyImpulseAtPoint(state: KartState, impulseWS: Vec3, relPosWS: Vec3)
	local invM = state.profile.invMass
	state.linVel.x += impulseWS.x * invM
	state.linVel.y += impulseWS.y * invM
	state.linVel.z += impulseWS.z * invM

	if relPosWS.x ~= 0 or relPosWS.y ~= 0 or relPosWS.z ~= 0 then
		local torqueImp = Math3D.cross(relPosWS, impulseWS)
		applyWorldTorqueImpulse(state, torqueImp)
	end
end

-- Compute denominator m^-1 + dir . ((I^-1 (r x dir)) x r) for exact stop impulse
local function computeEffectiveInvMass(state: KartState, relPosWS: Vec3, dirWS: Vec3): number
	local rCrossD = Math3D.cross(relPosWS, dirWS)
	local qConj = Math3D.quatConjugate(state.rot)
	local localRcd = Math3D.quatRotateVec(qConj, rCrossD)
	local invI = state.profile.invInertia
	local invIRcdLocal: Vec3 = {
		x = localRcd.x * invI.x,
		y = localRcd.y * invI.y,
		z = localRcd.z * invI.z,
	}
	local invIRcdWS = Math3D.quatRotateVec(state.rot, invIRcdLocal)
	local angularTerm = Math3D.dot(dirWS, Math3D.cross(invIRcdWS, relPosWS))
	return state.profile.invMass + angularTerm
end

local function velocityAtRelPos(state: KartState, relPosWS: Vec3): Vec3
	local rotVel = Math3D.cross(state.angVel, relPosWS)
	return {
		x = state.linVel.x + rotVel.x,
		y = state.linVel.y + rotVel.y,
		z = state.linVel.z + rotVel.z,
	}
end

-- Single wheel raycast with 0.95x inward seam-snag fallback (src/physics/btKart.cpp:L225-L359)
local function raycastWheel(
	state: KartState,
	wheelIndex: number,
	worldQuery: WorldQuery,
	wheelDirWS: Vec3,
	fraction: number
): boolean
	local susp = KartTuning.suspension
	local wheel = state.wheels[wheelIndex]
	local hpLocal = state.profile.wheelHardpoints[wheelIndex]
	local scaledHp: Vec3 = { x = hpLocal.x * fraction, y = hpLocal.y * fraction, z = hpLocal.z * fraction }
	local hpWS = Math3D.add(state.pos, Math3D.quatRotateVec(state.rot, scaledHp))
	wheel.hardPointWS = hpWS

	local minSuspLen = susp.rest - susp.travel
	local maxSuspLen = susp.rest + susp.travel
	local rayLen = maxSuspLen + susp.rayExtraLength
	local bias = KartTuning.collision.wheelRayOriginBias

	-- Start slightly above hardpoint along chassis +Y so bottomed-out wheels still catch the surface,
	-- while skipping ignore="Y" layers such as oasis-water.png.
	local castOrigin = Math3D.sub(hpWS, Math3D.scale(wheelDirWS, bias))
	local remainingLen = rayLen + bias
	local accumulatedDist = 0.0
	local validHit: RayHit? = nil
	local trueDist = 0.0

	for _ = 1, MAX_IGNORE_RAY_PASSES do
		local hit = worldQuery.raycast(castOrigin, wheelDirWS, remainingLen)
		if hit == nil then
			break
		end
		local mat = SurfaceMaterials.get(hit.materialName)
		if mat.ignore then
			local stepDist = hit.distance + 1e-3
			if stepDist >= remainingLen then
				break
			end
			accumulatedDist += stepDist
			castOrigin = Math3D.add(castOrigin, Math3D.scale(wheelDirWS, stepDist))
			remainingLen -= stepDist
		else
			trueDist = accumulatedDist + hit.distance - bias
			if trueDist < maxSuspLen then
				validHit = hit
			end
			break
		end
	end

	if validHit ~= nil then
		local mat = SurfaceMaterials.get(validHit.materialName)
		local normalWS = Math3D.normalize(validHit.normal, { x = 0, y = 1, z = 0 })
		wheel.isInContact = true
		wheel.contactNormalWS = normalWS
		wheel.contactPointWS = validHit.point
		wheel.rawHitDistance = trueDist
		wheel.compressionRatio = math.clamp((susp.rest - trueDist) / susp.travel, 0.0, 2.0)
		wheel.suspensionLength = math.clamp(trueDist, minSuspLen, maxSuspLen)
		wheel.materialName = validHit.materialName or mat.name
		wheel.highTireAdhesion = if validHit.highTireAdhesion ~= nil
			then validHit.highTireAdhesion
			else mat.highTireAdhesion
		wheel.surfaceGrip = (validHit.surfaceGrip or 1.0) * mat.friction

		local denom = Math3D.dot(normalWS, wheelDirWS)
		if denom >= susp.minContactDot then
			wheel.suspensionRelVel = 0.0
			wheel.clippedInvContactDot = susp.maxInvContactDot
		else
			local invDot = -1.0 / denom
			local relPos = Math3D.sub(validHit.point, state.pos)
			local vPoint = velocityAtRelPos(state, relPos)
			local projVel = Math3D.dot(normalWS, vPoint)
			wheel.suspensionRelVel = projVel * invDot
			wheel.clippedInvContactDot = invDot
		end
		return true
	end

	wheel.isInContact = false
	wheel.suspensionLength = susp.rest
	wheel.rawHitDistance = susp.rest
	wheel.compressionRatio = 0.0
	wheel.suspensionRelVel = 0.0
	wheel.contactNormalWS = Math3D.scale(wheelDirWS, -1.0)
	wheel.contactPointWS = Math3D.add(hpWS, Math3D.scale(wheelDirWS, rayLen))
	wheel.clippedInvContactDot = 1.0
	wheel.highTireAdhesion = false
	wheel.surfaceGrip = 1.0
	wheel.materialName = "default"
	return false
end

-- Steep-slope wheel adhesion (src/karts/kart.cpp:L2906-L2958)
local function computeSlopeGrip(wheel: WheelState, gravityUp: Vec3): (number, boolean)
	if wheel.highTireAdhesion then
		return 1.0, false
	end
	local tire = KartTuning.tire
	local d = Math3D.dot(wheel.contactNormalWS, gravityUp)
	if d > tire.slidingFullNormalDot then
		return 1.0, false
	elseif d < tire.slidingMinNormalDot then
		return 0.0, true
	end
	return math.clamp((d - tire.slidingMinNormalDot) / tire.slidingRampDivisor, 0.0, 1.0), true
end

-- Speed floor/ceiling enforcement (src/physics/btKart.cpp:L963-L993)
local function adjustSpeed(state: KartState, minSpeed: number, maxSpeed: number, groundNormal: Vec3)
	local speed = Math3D.len(state.linVel)
	if minSpeed > 0 and speed < minSpeed then
		if speed > 1e-6 then
			local upComp = Math3D.scale(groundNormal, Math3D.dot(groundNormal, state.linVel))
			local planar = Math3D.sub(state.linVel, upComp)
			local planarLen = Math3D.len(planar)
			if planarLen > 1e-6 then
				local ratio = minSpeed / planarLen
				state.linVel = Math3D.add(Math3D.scale(planar, ratio), upComp)
			end
		else
			local _, _, fwd = Math3D.quatBasis(state.rot)
			state.linVel = Math3D.scale(fwd, minSpeed)
		end
	elseif speed > 0 and maxSpeed >= 0 and speed > maxSpeed then
		local ratio = maxSpeed / speed
		state.linVel = Math3D.scale(state.linVel, ratio)
	end
end

local function computeChassisHalfExtents(profile: KartTuning.KartProfile): Vec3
	return {
		x = 0.5 * profile.width,
		y = 0.5 * profile.collisionHeight,
		z = 0.5 * profile.length,
	}
end

local function computeBoxCenter(pos: Vec3, rot: Quat, halfExtents: Vec3): Vec3
	local _, up, _ = Math3D.quatBasis(rot)
	return Math3D.add(pos, Math3D.scale(up, halfExtents.y))
end

local function gatherWheelBottomContacts(state: KartState, minSuspLen: number, contacts: { Contact }): number
	local maxComp = 0.0
	for i = 1, 4 do
		local w = state.wheels[i]
		if w.isInContact then
			if w.compressionRatio > maxComp then
				maxComp = w.compressionRatio
			end
			if w.rawHitDistance < minSuspLen then
				table.insert(contacts, {
					point = w.contactPointWS,
					normal = w.contactNormalWS,
					depth = minSuspLen - w.rawHitDistance,
					materialName = w.materialName,
					isWheel = true,
				})
				state.depenetrationCount += 1
			end
		end
	end
	return maxComp
end

local function gatherChassisOverlapContacts(
	state: KartState,
	worldQuery: WorldQuery,
	halfExtents: Vec3,
	contacts: { Contact }
): boolean
	local checkFn = worldQuery.checkChassisOverlap
	local sweepFn = worldQuery.sweepChassis
	if checkFn == nil then
		return false
	end

	local boxCenter = computeBoxCenter(state.pos, state.rot, halfExtents)
	if not checkFn(boxCenter, state.rot, halfExtents) then
		return false
	end
	if sweepFn == nil then
		return true
	end

	local colCfg = KartTuning.collision
	-- 1) Sweep from last non-overlapping pose to current pose to recover penetration normal
	local safeCenter = computeBoxCenter(state.lastSafePos, state.lastSafeRot, halfExtents)
	local recoveryDelta = Math3D.sub(boxCenter, safeCenter)
	local recoveryDist = Math3D.len(recoveryDelta)
	if recoveryDist > 1e-5 then
		local recHit = sweepFn(safeCenter, state.lastSafeRot, halfExtents, recoveryDelta)
		if recHit ~= nil and not SurfaceMaterials.get(recHit.materialName).ignore then
			local recNormal = Math3D.normalize(recHit.normal, { x = 0, y = 1, z = 0 })
			local depth = (1.0 - math.clamp(recHit.fraction, 0.0, 1.0)) * recoveryDist + colCfg.sweepSkinWidth
			table.insert(contacts, {
				point = recHit.point,
				normal = recNormal,
				depth = depth,
				materialName = recHit.materialName,
				isWheel = false,
			})
			state.chassisSweepHitCount += 1
		end
	end

	-- 2) 6-axis shrunk-core outward probes handle pure rotation and multi-wall inside corners
	local right, up, fwd = Math3D.quatBasis(state.rot)
	local coreR = colCfg.overlapCoreRatio
	local perpR = colCfg.overlapPerpRatio
	local probes: { { dir: Vec3, core: Vec3, sweepDist: number } } = {
		{
			dir = right,
			core = { x = halfExtents.x * coreR, y = halfExtents.y * perpR, z = halfExtents.z * perpR },
			sweepDist = halfExtents.x * (1.0 - coreR) + colCfg.sweepSkinWidth,
		},
		{
			dir = Math3D.scale(right, -1.0),
			core = { x = halfExtents.x * coreR, y = halfExtents.y * perpR, z = halfExtents.z * perpR },
			sweepDist = halfExtents.x * (1.0 - coreR) + colCfg.sweepSkinWidth,
		},
		{
			dir = fwd,
			core = { x = halfExtents.x * perpR, y = halfExtents.y * perpR, z = halfExtents.z * coreR },
			sweepDist = halfExtents.z * (1.0 - coreR) + colCfg.sweepSkinWidth,
		},
		{
			dir = Math3D.scale(fwd, -1.0),
			core = { x = halfExtents.x * perpR, y = halfExtents.y * perpR, z = halfExtents.z * coreR },
			sweepDist = halfExtents.z * (1.0 - coreR) + colCfg.sweepSkinWidth,
		},
		{
			dir = up,
			core = { x = halfExtents.x * perpR, y = halfExtents.y * coreR, z = halfExtents.z * perpR },
			sweepDist = halfExtents.y * (1.0 - coreR) + colCfg.sweepSkinWidth,
		},
		{
			dir = Math3D.scale(up, -1.0),
			core = { x = halfExtents.x * perpR, y = halfExtents.y * coreR, z = halfExtents.z * perpR },
			sweepDist = halfExtents.y * (1.0 - coreR) + colCfg.sweepSkinWidth,
		},
	}

	for _, probe in probes do
		local hit = sweepFn(boxCenter, state.rot, probe.core, Math3D.scale(probe.dir, probe.sweepDist))
		if hit ~= nil and not SurfaceMaterials.get(hit.materialName).ignore then
			local penDepth = probe.sweepDist * (1.0 - math.clamp(hit.fraction, 0.0, 1.0))
			if penDepth > 0.0 then
				table.insert(contacts, {
					point = hit.point,
					normal = Math3D.normalize(hit.normal, Math3D.scale(probe.dir, -1.0)),
					depth = penDepth,
					materialName = hit.materialName,
					isWheel = false,
				})
				state.chassisSweepHitCount += 1
			end
		end
	end

	return true
end

local function evalWallRestitution(speedMps: number): number
	return Math3D.evalPiecewiseLinear(KartTuning.collision.wallRestitution, math.abs(speedMps))
end

local function resolveContacts(state: KartState, contacts: { Contact })
	local colCfg = KartTuning.collision
	for _, c in contacts do
		if SurfaceMaterials.get(c.materialName).collisionReaction == "reset" then
			state.resetTriggered = true
			state.lastCollisionReaction = "reset"
		end
		if c.depth > 0.0 then
			state.pos = Math3D.add(state.pos, Math3D.scale(c.normal, c.depth))
		end
		local vn = Math3D.dot(state.linVel, c.normal)
		if vn < 0.0 then
			local noBounce = c.isWheel
				or (c.normal.y > colCfg.drivableNormalMinY)
				or (math.abs(vn) < colCfg.restContactBounceVel)
			local restitution = if noBounce then 0.0 else evalWallRestitution(state.speed)
			state.linVel = Math3D.sub(state.linVel, Math3D.scale(c.normal, (1.0 + restitution) * vn))
		end
		local relC = Math3D.sub(c.point, state.pos)
		local vPoint = velocityAtRelPos(state, relC)
		local vcn = Math3D.dot(vPoint, c.normal)
		if vcn < 0.0 then
			local effInv = computeEffectiveInvMass(state, relC, c.normal)
			if effInv > 1e-9 then
				applyImpulseAtPoint(state, Math3D.scale(c.normal, -vcn / effInv), relC)
			end
		end
	end
end

function KartSolver.step(state: KartState, input: KartInput, worldQuery: WorldQuery, dt: number)
	local profile = state.profile
	local suspCfg = KartTuning.suspension
	local stabCfg = KartTuning.stability
	local engCfg = KartTuning.engine
	local gravity = state.gravity
	local gravityUp: Vec3 = { x = 0, y = 1, z = 0 }

	-- 1. Smooth steer input & resolve drift latch
	updateSmoothedSteer(state, input, dt)
	local skidControl: SkidControl = resolveSkidControl(state, input)

	-- Refresh forward signed speed before controller/skidding update
	local chassisRight, chassisUp, chassisFwd = Math3D.quatBasis(state.rot)
	local rawSignedSpeed = Math3D.dot(state.linVel, chassisFwd)
	state.speed = if math.abs(rawSignedSpeed) < KartTuning.physics.SPEED_DEADBAND then 0.0 else rawSignedSpeed

	-- 2. 4-wheel suspension raycasts with 0.95x inward seam fallback (btKart.cpp:L225-L243)
	local wheelDirWS = Math3D.scale(chassisUp, -1.0)
	local numGrounded = 0
	for i = 1, 4 do
		local hit = raycastWheel(state, i, worldQuery, wheelDirWS, 1.0)
		if not hit then
			hit = raycastWheel(state, i, worldQuery, wheelDirWS, suspCfg.seamRetryFraction)
		end
		if hit then
			numGrounded += 1
		end
	end
	state.numWheelsOnGround = numGrounded
	state.isOnGround = (numGrounded == 4)

	-- 2b. Surface material effects: slowdown, reset, pushback (kart.cpp:L1709-L1737, L2445-L2460)
	state.resetTriggered = false
	state.lastCollisionReaction = "normal"
	if state.bounceBackTicks > 0 then
		state.bounceBackTicks -= 1
	end

	local selectedMat: SurfaceMaterials.SurfaceMaterial? = nil
	if numGrounded > 0 then
		for i = 1, 4 do
			local w = state.wheels[i]
			if w.isInContact then
				local mat = SurfaceMaterials.get(w.materialName)
				local shouldSelect = (selectedMat == nil)
					or (mat.collisionReaction ~= "normal" and (selectedMat :: SurfaceMaterials.SurfaceMaterial).collisionReaction == "normal")
					or (mat.reset and not (selectedMat :: SurfaceMaterials.SurfaceMaterial).reset)
					or (
						(selectedMat :: SurfaceMaterials.SurfaceMaterial).collisionReaction == "normal"
						and not (selectedMat :: SurfaceMaterials.SurfaceMaterial).reset
						and mat.maxSpeedFraction
							< (selectedMat :: SurfaceMaterials.SurfaceMaterial).maxSpeedFraction
					)
				if shouldSelect then
					selectedMat = mat
				end
			end
		end
	end

	if selectedMat ~= nil then
		state.activeMaterialName = selectedMat.name
		if selectedMat.collisionReaction == "reset" or (selectedMat.reset and state.isOnGround) then
			state.resetTriggered = true
			state.lastCollisionReaction = "reset"
		elseif selectedMat.collisionReaction == "push" then
			state.lastCollisionReaction = "push"
			if state.bounceBackTicks <= FixedStep.timeToTicks(0.2) then
				local dir = Math3D.normalize(state.linVel, chassisFwd)
				local push = { x = dir.x, y = 0.1, z = dir.z }
				applyImpulseAtPoint(state, Math3D.scale(push, -4000.0), { x = 0, y = 0, z = 0 })
				state.bounceBackTicks = FixedStep.timeToTicks(2.0)
			end
		else
			MaxSpeed.setSlowdown(
				state.maxSpeedState,
				"TERRAIN",
				selectedMat.maxSpeedFraction,
				FixedStep.timeToTicks(selectedMat.slowdownTime),
				-1
			)
		end
	else
		state.activeMaterialName = "air"
	end

	-- 3. Drift state machine (Skidding::update) & MaxSpeed update
	local releaseBonus =
		Skidding.update(state.skid, 1, state.isOnGround, rawSignedSpeed, state.steer, skidControl, gravity)
	local instantMinSpeed = 0.0
	if releaseBonus ~= nil then
		if releaseBonus.timedRotationTicks > 0 then
			state.timedRotationTicks = releaseBonus.timedRotationTicks
			state.timedRotationRate = releaseBonus.timedRotationTotalRad
				/ FixedStep.ticksToTime(releaseBonus.timedRotationTicks)
		end
		if releaseBonus.tier >= 1 and releaseBonus.bonusTicks > 0 then
			local cat: MaxSpeed.SpeedIncreaseCategory = if releaseBonus.tier == 1 then "SKIDDING" else "RED_SKIDDING"
			instantMinSpeed = MaxSpeed.instantSpeedIncrease(
				state.maxSpeedState,
				cat,
				releaseBonus.bonusSpeed,
				releaseBonus.instantGain,
				releaseBonus.bonusForce,
				releaseBonus.bonusTicks,
				releaseBonus.fadeOutTicks,
				math.max(0.0, rawSignedSpeed),
				state.isOnGround
			)
		end
	end
	MaxSpeed.update(state.maxSpeedState, 1, state.isOnGround)
	Nitro.update(state.nitro, profile.nitro, state.maxSpeedState, 1, input.nitro == true, state.isOnGround)
	MaxSpeed.update(state.maxSpeedState, 0, state.isOnGround)

	-- Front wheel steer angle from speed-indexed R(v) * skidding.steeringFraction (kart.cpp:L2649-L2651)
	local frontSteerAngle = getMaxSteerAngle(profile, math.abs(rawSignedSpeed)) * state.skid.steeringFraction
	state.frontSteerAngleRad = frontSteerAngle

	-- 4. Powertrain: gears, nitro engineMult, air drag, brakes, reverse, parking brake (kart.cpp:L2779-L2893)
	local baseWheelForce = getActualWheelForce(profile, rawSignedSpeed, state.maxSpeedState.additionalEngineForce)
	if MaxSpeed.getSpeedIncreaseTicksLeft(state.maxSpeedState, "NITRO") > 0 then
		baseWheelForce *= profile.nitro.engineMult
	end
	local accel = math.clamp(input.accel, 0.0, 1.0)
	local appliedEngineForce = 0.0
	local brakeLimit = 0.0

	if accel > 0 then
		local power = baseWheelForce
		if rawSignedSpeed < 0 then
			power *= engCfg.reverseAccelMultiplier
		end
		power = applyAirFriction(power, rawSignedSpeed, profile.mass)
		appliedEngineForce = power * accel
		state.brakeTicks = 0
	else
		local brakingPower = baseWheelForce
		local netPower = applyAirFriction(baseWheelForce, rawSignedSpeed, profile.mass)
		if input.brake then
			if rawSignedSpeed > 0 then
				appliedEngineForce = netPower - brakingPower * engCfg.brakePowerMultiplier
				state.brakeTicks += 1
				local mult = 1.0 + FixedStep.ticksToTime(state.brakeTicks) * profile.brakeTimeIncrease
				brakeLimit = profile.brakeFactor * mult
			else
				brakeLimit = 0.0
				local maxRev = state.maxSpeedState.currentMaxSpeed * profile.maxSpeedReverseRatio
				if -rawSignedSpeed < maxRev then
					appliedEngineForce = netPower - brakingPower * engCfg.brakePowerMultiplier
				else
					appliedEngineForce = 0.0
				end
			end
		else
			state.brakeTicks = 0
			if math.abs(rawSignedSpeed) < engCfg.parkBrakeMaxSpeed then
				appliedEngineForce = 0.0
				brakeLimit = engCfg.parkBrakeForce
			else
				appliedEngineForce = netPower - brakingPower
				brakeLimit = 0.0
			end
		end
	end

	-- 5. Apply gravity & airborne stabilization (btKart.cpp:L438-L461, kart.cpp:L1513-L1529)
	state.linVel.y -= gravity * dt

	if numGrounded == 0 then
		-- Zero pitch & roll angVel, then apply uprighting torque impulse (btKart.cpp:L448-L460)
		local axis = Math3D.cross(chassisUp, gravityUp)
		state.angVel.x = 0
		state.angVel.z = 0
		applyWorldTorqueImpulse(state, Math3D.scale(axis, stabCfg.smoothFlyingImpulse))
	end

	if not state.isOnGround then
		local damp = KartTuning.air.angularDampingPerTick
		state.angVel.x *= damp.x
		state.angVel.y *= damp.y
		state.angVel.z *= damp.z
	end

	-- 6. Suspension spring-damper forces & off-ground wheel pull (btKart.cpp:L465-L500, L586-L639)
	for i = 1, 4 do
		local w = state.wheels[i]
		if not w.isInContact then
			-- Pulls lifted wheel toward ground; adds -8 m/s^2 airborne gravity across 4 wheels
			w.suspensionForce = -stabCfg.trackConnectionAccel * profile.mass
		else
			local lengthDiff = suspCfg.rest - w.suspensionLength
			if suspCfg.expSpringResponse then
				lengthDiff *= math.abs(lengthDiff) / suspCfg.rest
			end
			local springTerm = suspCfg.stiffness * lengthDiff * w.clippedInvContactDot
			local damping = if w.suspensionRelVel < 0
				then KartTuning.wheels.dampingCompression
				else KartTuning.wheels.dampingRelaxation
			local fWheel = (springTerm - damping * w.suspensionRelVel) * profile.mass
			w.suspensionForce = math.clamp(fWheel, 0.0, suspCfg.maxForce)
		end

		local impulse = Math3D.scale(w.contactNormalWS, w.suspensionForce * dt)
		local relPos = if w.isInContact then Math3D.sub(w.contactPointWS, state.pos) else { x = 0, y = 0, z = 0 }
		applyImpulseAtPoint(state, impulse, relPos)
	end

	-- 4-wheel speed-proportional downforce (btKart.cpp:L493-L500), tick-rate normalized
	if numGrounded == 4 and stabCfg.downwardImpulseFactor ~= 0 then
		local downMag = -math.abs(rawSignedSpeed) * stabCfg.downwardImpulseFactor * (dt * KartTuning.physics.FPS)
		local downImp = Math3D.scale(chassisUp, downMag)
		applyImpulseAtPoint(state, downImp, { x = 0, y = 0, z = 0 })
	end

	-- 7. Longitudinal & slip-angle lateral tire impulses (docs/physics-spec.md §4.3)
	local wheelFwdImp = { 0.0, 0.0, 0.0, 0.0 }
	local wheelLatImp = { 0.0, 0.0, 0.0, 0.0 }
	local wheelFwdDirs: { Vec3 } = {}
	local wheelAxleDirs: { Vec3 } = {}
	local wheelRelLat: { Vec3 } = {}
	local wheelVLat = { 0.0, 0.0, 0.0, 0.0 }
	local maxAbsSlip = 0.0

	local isDrifting = (state.skid.state == "SKID_ACCUMULATE_LEFT" or state.skid.state == "SKID_ACCUMULATE_RIGHT")
	local knockbackGrip = if state.timedImpulseTicks > 0 then 0.0 else 1.0
	local totalBrakeStopNeeded = 0.0
	local totalBrakeDesired = 0.0

	for i = 1, 4 do
		local w = state.wheels[i]
		w.slipAngleRad = 0.0
		wheelFwdDirs[i] = chassisFwd
		wheelAxleDirs[i] = chassisRight
		wheelRelLat[i] = { x = 0, y = 0, z = 0 }

		if w.isInContact then
			local isFront = (i == 1 or i == 2)
			local steerAng = if isFront then frontSteerAngle else 0.0

			-- Rotate chassisRight around chassisUp by +steerAng (steer > 0 turns +Z toward +X right)
			local rawAxle = if steerAng ~= 0
				then Math3D.quatRotateVec(Math3D.quatFromAxisAngle(chassisUp, steerAng), chassisRight)
				else chassisRight
			-- Project axle onto contact plane
			local nDotAxle = Math3D.dot(rawAxle, w.contactNormalWS)
			local axle = Math3D.normalize(Math3D.sub(rawAxle, Math3D.scale(w.contactNormalWS, nDotAxle)), chassisRight)
			-- Wheel forward = axle x normal (check: (+1,0,0) x (0,1,0) = (0,0,+1) = +Z forward!)
			local fwd = Math3D.normalize(Math3D.cross(axle, w.contactNormalWS), chassisFwd)

			wheelAxleDirs[i] = axle
			wheelFwdDirs[i] = fwd

			-- Project out suspension axis first so vertical lever arm induces zero phantom lift/roll torque (btKart.cpp:L858-L878)
			local relPos = Math3D.sub(w.contactPointWS, state.pos)
			local deltaVec = Math3D.sub(w.hardPointWS, w.contactPointWS)
			local deltaLen = Math3D.len(deltaVec)
			local relLat = relPos
			if deltaLen > 1e-6 then
				local dUnit = Math3D.scale(deltaVec, 1.0 / deltaLen)
				relLat = Math3D.sub(relLat, Math3D.scale(dUnit, Math3D.dot(relLat, dUnit)))
			end
			local upDot = Math3D.dot(relLat, chassisUp)
			relLat = Math3D.sub(relLat, Math3D.scale(chassisUp, upDot * (1.0 - stabCfg.rollInfluence)))
			wheelRelLat[i] = relLat

			local vPoint = velocityAtRelPos(state, relPos)
			local vFwd = Math3D.dot(vPoint, fwd)
			local vLat = Math3D.dot(vPoint, axle)
			wheelVLat[i] = vLat

			-- Guarded slip angle (zero-velocity floor & reverse |v_fwd| guard)
			local alpha = KartSolver.computeSlipAngle(vFwd, vLat)
			w.slipAngleRad = alpha
			if math.abs(alpha) > maxAbsSlip then
				maxAbsSlip = math.abs(alpha)
			end

			-- Effective grip scale
			local slopeGrip, slidingActive = computeSlopeGrip(w, gravityUp)
			local driftGrip = if not isFront and isDrifting then KartTuning.tire.driftRearGripScale else 1.0
			local gEff = slopeGrip * w.surfaceGrip * driftGrip * knockbackGrip

			-- Longitudinal impulse: 0.4 front / 0.6 rear 4WD split (kart.cpp:L3084-L3085)
			local driveSplit = if isFront then engCfg.frontWheelDriveSplit else engCfg.rearWheelDriveSplit
			local jFwd = 0.0
			if appliedEngineForce ~= 0 then
				jFwd = (appliedEngineForce * driveSplit) * dt
			elseif brakeLimit > 0 then
				local stopImp = -vFwd * profile.mass / numGrounded
				local maxImp = brakeLimit
				jFwd = math.clamp(stopImp, -maxImp, maxImp)
				if math.abs(jFwd) < engCfg.lowBrakeShakeThreshold then
					jFwd *= engCfg.lowBrakeShakeScale
				end
				totalBrakeStopNeeded = -rawSignedSpeed * profile.mass
				totalBrakeDesired += jFwd
			end

			-- Lateral impulse from Pacejka-lite curve with per-wheel stop cap
			local jLat = 0.0
			if alpha ~= 0 and gEff > 0 and w.suspensionForce > 0 then
				local mu = math.abs(KartSolver.evaluateLateralGrip(alpha))
				local fLat = -Math3D.sign(vLat) * mu * gEff * w.suspensionForce
				local effInvMass = computeEffectiveInvMass(state, relLat, axle)
				local jStop = math.abs(vLat) / effInvMass
				jLat = math.clamp(fLat * dt, -jStop, jStop)
			end

			-- Traction circle coupling when sliding (btKart.cpp:L794-L828)
			if (slidingActive or state.timedImpulseTicks > 0) and gEff < 1.0 then
				local maxCombined = gEff * KartTuning.tire.muPeak * w.suspensionForce * dt
				local fx = jFwd * KartTuning.tire.fwdTractionScale
				local fy = jLat
				local mag = math.sqrt(fx * fx + fy * fy)
				if mag > maxCombined and mag > 1e-9 then
					local scale = maxCombined / mag
					jFwd *= scale
					jLat *= scale
				end
			end

			wheelFwdImp[i] = jFwd
			wheelLatImp[i] = jLat
		end
	end
	state.maxSlipAngleRad = maxAbsSlip

	-- Clamp combined parking/braking impulse so braking never overshoots zero speed
	if appliedEngineForce == 0 and brakeLimit > 0 and math.abs(totalBrakeDesired) > 1e-9 then
		if
			math.abs(totalBrakeDesired) > math.abs(totalBrakeStopNeeded)
			and totalBrakeDesired * totalBrakeStopNeeded > 0
		then
			local brakeScale = math.abs(totalBrakeStopNeeded) / math.abs(totalBrakeDesired)
			for i = 1, 4 do
				wheelFwdImp[i] *= brakeScale
			end
		end
	end

	-- Symmetric 4-wheel lateral overshoot clamp: computes exact combined dv_lat at every wheel
	-- so symmetric wheel pairs never reverse v_lat or jitter at low speeds while keeping zero yaw bias.
	local sumLatImp: Vec3 = { x = 0, y = 0, z = 0 }
	local sumLatTorque: Vec3 = { x = 0, y = 0, z = 0 }
	for i = 1, 4 do
		if wheelLatImp[i] ~= 0 then
			local imp = Math3D.scale(wheelAxleDirs[i], wheelLatImp[i])
			sumLatImp = Math3D.add(sumLatImp, imp)
			sumLatTorque = Math3D.add(sumLatTorque, Math3D.cross(wheelRelLat[i], imp))
		end
	end

	local latScale = 1.0
	if Math3D.lenSq(sumLatImp) > 0 or Math3D.lenSq(sumLatTorque) > 0 then
		local qConj = Math3D.quatConjugate(state.rot)
		local tauLoc = Math3D.quatRotateVec(qConj, sumLatTorque)
		local invI = profile.invInertia
		local dOmegaCombined = Math3D.quatRotateVec(state.rot, {
			x = tauLoc.x * invI.x,
			y = tauLoc.y * invI.y,
			z = tauLoc.z * invI.z,
		})
		local dLinCombined = Math3D.scale(sumLatImp, profile.invMass)

		for i = 1, 4 do
			if wheelLatImp[i] ~= 0 and math.abs(wheelVLat[i]) > 1e-9 then
				local dvPoint = Math3D.add(dLinCombined, Math3D.cross(dOmegaCombined, wheelRelLat[i]))
				local dvLat = Math3D.dot(dvPoint, wheelAxleDirs[i])
				-- If combined impulse reverses vLat[i], scale all lateral impulses down uniformly
				if wheelVLat[i] * (wheelVLat[i] + dvLat) < 0 and math.abs(dvLat) > 1e-9 then
					local s = math.abs(wheelVLat[i]) / math.abs(dvLat)
					if s < latScale then
						latScale = s
					end
				end
			end
		end
	end

	-- Apply longitudinal impulses centrally (COMPATIBLE_0_7_3, btKart.cpp:L842-L845) & lateral impulses
	for i = 1, 4 do
		if wheelFwdImp[i] ~= 0 then
			applyImpulseAtPoint(state, Math3D.scale(wheelFwdDirs[i], wheelFwdImp[i]), { x = 0, y = 0, z = 0 })
		end
		if wheelLatImp[i] ~= 0 then
			applyImpulseAtPoint(state, Math3D.scale(wheelAxleDirs[i], wheelLatImp[i] * latScale), wheelRelLat[i])
		end
	end

	-- 8. Timed central knockback impulse (btKart.cpp:L504-L510)
	if state.timedImpulseTicks > 0 then
		applyImpulseAtPoint(state, Math3D.scale(state.timedImpulsePerSec, dt), { x = 0, y = 0, z = 0 })
		state.timedImpulseTicks -= 1
	end

	-- 9. Bullet-equivalent chassis linear damping when grounded (kart.cpp:L1523-L1529)
	local linDamp = if state.isOnGround then stabCfg.chassisLinearDamping else KartTuning.air.linearDamping
	if linDamp > 0 then
		local dampFactor = (1.0 - linDamp) ^ dt
		state.linVel.x *= dampFactor
		state.linVel.y *= dampFactor
		state.linVel.z *= dampFactor
	end

	-- 10. Post-skid timed chassis rotation alignment (btKart.cpp:L514-L533)
	if state.timedRotationTicks > 0 then
		local dYaw = state.timedRotationRate * dt
		local qAdd = Math3D.quatFromAxisAngle({ x = 0, y = 1, z = 0 }, dYaw)
		state.rot = Math3D.quatNormalize(Math3D.quatMul(state.rot, qAdd))
		state.timedRotationTicks -= 1
	end

	-- 10b. Pre-sweep boost/cap speed enforcement so instant boosts (Tier 1/2, nitro, zipper)
	-- are always swept and projected against walls rather than bypassing collision (fix 3).
	local groundNormal = if numGrounded > 0 then state.wheels[1].contactNormalWS else gravityUp
	adjustSpeed(state, instantMinSpeed, state.maxSpeedState.effectiveCapSpeed, groundNormal)

	-- 10c. Unified resting contact manifold pass (wheel bottom-out + static chassis overlap recovery)
	local colCfg = KartTuning.collision
	local minSuspLen = suspCfg.rest - suspCfg.travel
	local halfExtents = computeChassisHalfExtents(profile)

	local maxComp = 0.0
	for pass = 1, colCfg.maxContactResolvePasses do
		local contacts: { Contact } = {}
		if pass == 1 then
			maxComp = gatherWheelBottomContacts(state, minSuspLen, contacts)
		end
		local overlapped = gatherChassisOverlapContacts(state, worldQuery, halfExtents, contacts)
		if #contacts == 0 then
			if not overlapped then
				break
			end
			-- Fallback positional push if overlapped without geometric probe hits
			local fallbackDir = Math3D.sub(state.lastSafePos, state.pos)
			if Math3D.lenSq(fallbackDir) > 1e-10 then
				state.pos = Math3D.vecLerp(state.pos, state.lastSafePos, 0.5)
			end
			break
		end
		resolveContacts(state, contacts)
	end
	state.maxCompressionRatio = maxComp

	-- 11. Swept chassis collide-and-slide translation + post-rotation overlap guard
	if worldQuery.sweepChassis ~= nil then
		local sweepFn = worldQuery.sweepChassis
		local remainingDt = dt
		for _ = 1, colCfg.maxSweepIters do
			if remainingDt <= 1e-6 then
				break
			end
			local delta = Math3D.scale(state.linVel, remainingDt)
			local deltaDist = Math3D.len(delta)
			if deltaDist < 1e-6 then
				state.pos = Math3D.add(state.pos, delta)
				break
			end
			local boxCenter = computeBoxCenter(state.pos, state.rot, halfExtents)
			local sweepHit = sweepFn(boxCenter, state.rot, halfExtents, delta)
			if sweepHit == nil or SurfaceMaterials.get(sweepHit.materialName).ignore then
				state.pos = Math3D.add(state.pos, delta)
				break
			end

			state.chassisSweepHitCount += 1
			if SurfaceMaterials.get(sweepHit.materialName).collisionReaction == "reset" then
				state.resetTriggered = true
				state.lastCollisionReaction = "reset"
			end

			local hitNormal = Math3D.normalize(sweepHit.normal, { x = 0, y = 1, z = 0 })
			local skinFrac = colCfg.sweepSkinWidth / deltaDist
			local frac = math.clamp(sweepHit.fraction, 0.0, 1.0)
			local safeFrac = math.max(0.0, frac - skinFrac)
			state.pos = Math3D.add(state.pos, Math3D.scale(delta, safeFrac))
			if frac <= 1e-4 then
				state.pos = Math3D.add(state.pos, Math3D.scale(hitNormal, colCfg.sweepSkinWidth))
			end

			local vn = Math3D.dot(state.linVel, hitNormal)
			if vn < 0 then
				local noBounce = (hitNormal.y > colCfg.drivableNormalMinY)
					or (math.abs(vn) < colCfg.restContactBounceVel)
				local restitution = if noBounce then 0.0 else evalWallRestitution(state.speed)
				state.linVel = Math3D.sub(state.linVel, Math3D.scale(hitNormal, (1.0 + restitution) * vn))
			end
			remainingDt *= math.max(0.0, 1.0 - safeFrac)
		end
	else
		state.pos.x += state.linVel.x * dt
		state.pos.y += state.linVel.y * dt
		state.pos.z += state.linVel.z * dt
	end

	state.rot = Math3D.quatIntegrateAngVel(state.rot, state.angVel, dt)

	-- Post-rotation static overlap guard so angular spin cannot rotate a corner into a wall
	if worldQuery.checkChassisOverlap ~= nil then
		for _ = 1, 2 do
			local rotContacts: { Contact } = {}
			if not gatherChassisOverlapContacts(state, worldQuery, halfExtents, rotContacts) then
				break
			end
			if #rotContacts > 0 then
				resolveContacts(state, rotContacts)
			else
				state.rot = {
					w = state.lastSafeRot.w,
					x = state.lastSafeRot.x,
					y = state.lastSafeRot.y,
					z = state.lastSafeRot.z,
				}
				state.angVel = { x = 0, y = 0, z = 0 }
				break
			end
		end
		if
			worldQuery.checkChassisOverlap(computeBoxCenter(state.pos, state.rot, halfExtents), state.rot, halfExtents)
		then
			state.rot = {
				w = state.lastSafeRot.w,
				x = state.lastSafeRot.x,
				y = state.lastSafeRot.y,
				z = state.lastSafeRot.z,
			}
			state.pos = { x = state.lastSafePos.x, y = state.lastSafePos.y, z = state.lastSafePos.z }
		else
			state.lastSafePos = { x = state.pos.x, y = state.pos.y, z = state.pos.z }
			state.lastSafeRot = { w = state.rot.w, x = state.rot.x, y = state.rot.y, z = state.rot.z }
		end
	else
		state.lastSafePos = { x = state.pos.x, y = state.pos.y, z = state.pos.z }
		state.lastSafeRot = { w = state.rot.w, x = state.rot.x, y = state.rot.y, z = state.rot.z }
	end

	-- 12. Post-contact max-speed ceiling enforcement without re-injecting projected boost into walls
	adjustSpeed(state, 0.0, state.maxSpeedState.effectiveCapSpeed, groundNormal)

	-- Update signed forward speed telemetry (kart.cpp:L1838)
	local _, _, newFwd = Math3D.quatBasis(state.rot)
	local signedAfter = Math3D.dot(state.linVel, newFwd)
	state.speed = if math.abs(signedAfter) < KartTuning.physics.SPEED_DEADBAND then 0.0 else signedAfter
end

export type ItemStepOptions = {
	isServer: boolean?,
	kartId: number?,
	rollPowerup: ((state: KartState, ev: ItemWorld.ItemPickupEvent) -> (number, number))?,
	advanceItemWorld: boolean?,
}

function KartSolver.stepWithItems(
	state: KartState,
	input: KartInput,
	worldQuery: WorldQuery,
	dt: number,
	itemWorld: ItemWorld.ItemWorldState?,
	opts: ItemStepOptions?
): { ItemWorld.ItemPickupEvent }
	local options: ItemStepOptions = opts or {}
	if itemWorld ~= nil and options.advanceItemWorld ~= false then
		ItemWorld.tick(itemWorld)
	end

	KartSolver.step(state, input, worldQuery, dt)

	local fireDown = (input.fire == true)
	local fireClicked = fireDown and not state.fireWasDown
	state.fireWasDown = fireDown

	if fireClicked and itemWorld ~= nil and state.heldPowerupCount > 0 then
		state.heldPowerupCount -= 1
		if state.heldPowerupCount <= 0 then
			state.heldPowerup = ItemTuning.POWERUP_NONE
			state.heldPowerupCount = 0
		end
		local _, _, fwd = Math3D.quatBasis(state.rot)
		local backDist = 0.5 * state.profile.length + ItemTuning.geometry.BANANA_DROP_CLEARANCE
		local dropPos = Math3D.sub(state.pos, Math3D.scale(fwd, backDist))
		ItemWorld.dropBanana(itemWorld, dropPos, options.kartId or 1, worldQuery)
	end

	if itemWorld == nil then
		return {}
	end

	local events = ItemWorld.checkHits(
		itemWorld,
		state.pos,
		options.kartId or 1,
		state.profile.nitro.smallContainer,
		state.profile.nitro.bigContainer
	)
	for _, ev in events do
		if ev.isNitro then
			Nitro.collect(state.nitro, ev.nitroAmount)
		elseif ev.isBonusBox then
			if options.isServer and options.rollPowerup ~= nil then
				local powerupId, count = options.rollPowerup(state, ev)
				KartSolver.setPowerup(state, powerupId, count)
			end
		elseif ev.isHazard then
			KartSolver.applyBananaHit(state)
		end
	end
	return events
end

KartSolver.evalWallRestitution = evalWallRestitution

function KartSolver.getTelemetry(state: KartState): KartTelemetry
	return {
		speedMps = state.speed,
		maxSlipAngleRad = state.maxSlipAngleRad,
		skidState = state.skid.state,
		skidTier = state.skid.currentTier,
		skidTimeSec = FixedStep.ticksToTime(state.skid.skidTimeTicks),
		skidFactor = state.skid.skidFactor,
		steeringFraction = state.skid.steeringFraction,
		visualSkidYaw = state.skid.visualRotation,
		hopHeight = state.skid.hopHeight,
		isAirborne = state.numWheelsOnGround == 0,
		isOnGround = state.isOnGround,
		numWheelsOnGround = state.numWheelsOnGround,
		currentMaxSpeed = state.maxSpeedState.currentMaxSpeed,
		activeMaterialName = state.activeMaterialName,
		resetTriggered = state.resetTriggered,
		lastCollisionReaction = state.lastCollisionReaction,
		nitroEnergy = state.nitro.energy,
		nitroMaxEnergy = state.nitro.maxEnergy,
		nitroActive = state.nitro.active,
		maxCompressionRatio = state.maxCompressionRatio,
		chassisSweepHits = state.chassisSweepHitCount,
	}
end

return table.freeze(KartSolver)
