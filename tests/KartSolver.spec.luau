--!strict
-- tests/KartSolver.spec.luau
-- SPDX-License-Identifier: GPL-3.0-or-later

local FixedStep = require("../src/shared/sim/FixedStep")
local KartSolver = require("../src/shared/sim/KartSolver")
local KartTuning = require("../src/shared/KartTuning")
local Math3D = require("../src/shared/sim/Math3D")

type Vec3 = Math3D.Vec3
type RayHit = KartSolver.RayHit
type WorldQuery = KartSolver.WorldQuery
type KartInput = KartSolver.KartInput

export type TestCase = {
	name: string,
	fn: () -> (),
}

local function assertNear(actual: number, expected: number, eps: number?, label: string?)
	local tolerance = eps or 1e-6
	if actual ~= actual or math.abs(actual - expected) > tolerance then
		local prefix = if label then label .. ": " else ""
		error(string.format("%sexpected %s (+/-%g), got %s", prefix, tostring(expected), tolerance, tostring(actual)))
	end
end

local function makeFlatPlaneWorld(groundY: number): WorldQuery
	return {
		raycast = function(origin: Vec3, dir: Vec3, length: number): RayHit?
			if math.abs(dir.y) < 1e-9 then
				return nil
			end
			local t = (groundY - origin.y) / dir.y
			if t >= 0 and t <= length then
				return {
					distance = t,
					point = {
						x = origin.x + dir.x * t,
						y = groundY,
						z = origin.z + dir.z * t,
					},
					normal = { x = 0, y = 1, z = 0 },
				}
			end
			return nil
		end,
	}
end

local function makeEmptyAirWorld(): WorldQuery
	return {
		raycast = function(_origin: Vec3, _dir: Vec3, _length: number): RayHit?
			return nil
		end,
	}
end

local function extractYaw(q: Math3D.Quat): number
	local _, _, fwd = Math3D.quatBasis(q)
	return math.atan2(fwd.x, fwd.z)
end

local tests: { TestCase } = {
	{
		name = "zero-velocity slip floor prevents NaN and steering at rest does not rotate chassis",
		fn = function()
			-- Speed floor guard (< 0.05 m/s -> 0 slip)
			assert(KartSolver.computeSlipAngle(0, 0) == 0, "slip(0, 0) must equal 0")
			assert(KartSolver.computeSlipAngle(0.02, 0.03) == 0, "slip below 0.05 m/s floor must equal 0")
			assert(KartSolver.computeSlipAngle(-0.02, -0.02) == 0, "negative tiny vel below floor must equal 0")

			-- Steering at rest on flat ground must never rotate chassis or induce drift
			local world = makeFlatPlaneWorld(0)
			local state =
				KartSolver.createState(KartTuning.buildProfile("medium", "best"), { x = 0, y = 0.291, z = 0 }, 0)
			local input: KartInput = { accel = 0, brake = false, steer = 1.0, drift = false, instantSteer = true }

			for _ = 1, 120 do
				KartSolver.step(state, input, world, FixedStep.FIXED_DT)
			end

			local yaw = extractYaw(state.rot)
			assertNear(yaw, 0, 1e-6, "yaw after 1s full steer at rest")
			assertNear(state.pos.x, 0, 1e-5, "lateral drift at rest")
			assertNear(state.pos.z, 0, 1e-5, "longitudinal drift at rest")
			assertNear(KartSolver.getTelemetry(state).maxSlipAngleRad, 0, 1e-9, "slip at rest")
		end,
	},
	{
		name = "reverse slip guard avoids +-pi sign flip and reverses cleanly",
		fn = function()
			-- Raw atan2(2, -10) would be +2.944 rad (~pi); guarded must use |v_fwd| -> ~+0.1974 rad
			local alpha = KartSolver.computeSlipAngle(-10.0, 2.0)
			assertNear(alpha, math.atan2(2.0, 10.0), 1e-6, "guarded reverse slip angle")
			local alphaNeg = KartSolver.computeSlipAngle(-10.0, -2.0)
			assertNear(alphaNeg, -math.atan2(2.0, 10.0), 1e-6, "guarded reverse negative slip angle")

			-- Pacejka lateral grip sign matches slip angle sign (so -sign(v_lat)*|mu| opposes v_lat)
			local muPos = KartSolver.evaluateLateralGrip(alpha)
			local muNeg = KartSolver.evaluateLateralGrip(alphaNeg)
			assert(muPos > 0.5 and muPos <= KartTuning.tire.muPeak + 1e-6, "positive slip grip in range")
			assertNear(muNeg, -muPos, 1e-9, "grip curve odd symmetry")

			-- Drive in reverse from rest on flat plane and verify reverse top speed + turning stability
			local world = makeFlatPlaneWorld(0)
			local state =
				KartSolver.createState(KartTuning.buildProfile("medium", "best"), { x = 0, y = 0.291, z = 0 }, 0)
			local revInput: KartInput = { accel = 0, brake = true, steer = 0.0, drift = false }

			for _ = 1, 480 do
				KartSolver.step(state, revInput, world, FixedStep.FIXED_DT)
			end

			-- Medium reverse cap = 25 * 0.65 * 0.75 = 12.1875 m/s
			local expectedRev = 25.0 * 0.65 * 0.75
			assertNear(state.speed, -expectedRev, 0.25, "reverse top speed")

			-- Steer while reversing for 1 s: must remain finite, grounded, and never flip sign/explode
			local revSteer: KartInput = { accel = 0, brake = true, steer = 0.8, drift = false }
			for _ = 1, 120 do
				KartSolver.step(state, revSteer, world, FixedStep.FIXED_DT)
			end
			assert(state.speed < -5.0 and state.speed == state.speed, "still reversing cleanly")
			assert(state.numWheelsOnGround == 4, "4 wheels grounded while reverse steering")
			assert(math.abs(extractYaw(state.rot)) > 0.05, "steering in reverse actually turns chassis")
		end,
	},
	{
		name = "airtime skid-charge persistence matches skidding.cpp:L376-L406, L525-L536 and charge tiers 1.0s/3.0s",
		fn = function()
			local flatWorld = makeFlatPlaneWorld(0)
			local airWorld = makeEmptyAirWorld()
			local profile = KartTuning.buildProfile("medium", "best")

			-- 1) Steering remap check across [-1, 0, +1] while in SKID_ACCUMULATE_RIGHT and LEFT
			local sRight = KartSolver.createState(profile, { x = 0, y = 0.291, z = 0 }, 0)
			sRight.linVel = { x = 0, y = 0, z = 20.0 }
			sRight.speed = 20.0
			KartSolver.step(sRight, {
				accel = 1,
				brake = false,
				steer = 1.0,
				drift = true,
				skidControl = "RIGHT",
				instantSteer = true,
			}, flatWorld, FixedStep.FIXED_DT)
			assert(sRight.skid.state == "SKID_ACCUMULATE_RIGHT", "entered SKID_ACCUMULATE_RIGHT")
			assertNear(sRight.skid.steeringFraction, 0.8, 1e-6, "right drift full inner steer -> +0.8")

			KartSolver.step(sRight, {
				accel = 1,
				brake = false,
				steer = -1.0,
				drift = true,
				skidControl = "RIGHT",
				instantSteer = true,
			}, flatWorld, FixedStep.FIXED_DT)
			assertNear(sRight.skid.steeringFraction, 0.2, 1e-6, "right drift full outer countersteer -> +0.2")

			local sLeft = KartSolver.createState(profile, { x = 0, y = 0.291, z = 0 }, 0)
			sLeft.linVel = { x = 0, y = 0, z = 20.0 }
			sLeft.speed = 20.0
			KartSolver.step(sLeft, {
				accel = 1,
				brake = false,
				steer = -1.0,
				drift = true,
				skidControl = "LEFT",
				instantSteer = true,
			}, flatWorld, FixedStep.FIXED_DT)
			assert(sLeft.skid.state == "SKID_ACCUMULATE_LEFT", "entered SKID_ACCUMULATE_LEFT")
			assertNear(sLeft.skid.steeringFraction, -0.8, 1e-6, "left drift full inner steer -> -0.8")
			KartSolver.step(sLeft, {
				accel = 1,
				brake = false,
				steer = 1.0,
				drift = true,
				skidControl = "LEFT",
				instantSteer = true,
			}, flatWorld, FixedStep.FIXED_DT)
			assertNear(sLeft.skid.steeringFraction, -0.2, 1e-6, "left drift full outer countersteer -> -0.2")

			-- 2) Airtime persistence: accumulate 0.6 s on ground, fly 0.6 s in air, land & release
			local state = KartSolver.createState(profile, { x = 0, y = 0.291, z = 0 }, 0)
			state.linVel = { x = 0, y = 0, z = 22.0 }
			state.speed = 22.0
			local driftInput: KartInput = {
				accel = 1,
				brake = false,
				steer = 0.5,
				drift = true,
				skidControl = "RIGHT",
				instantSteer = true,
			}

			-- 72 ticks (0.6 s) grounded -> skidFactor > 1.0, skidTimeTicks == 71 (tick 1 enters state with 0)
			for _ = 1, 72 do
				KartSolver.step(state, driftInput, flatWorld, FixedStep.FIXED_DT)
			end
			assert(state.skid.state == "SKID_ACCUMULATE_RIGHT", "still accumulating after 0.6s")
			assert(state.skid.skidFactor > 1.5, "skidFactor built up on ground")
			local ticksBeforeAir = state.skid.skidTimeTicks
			assert(ticksBeforeAir >= 70, "accumulated ~71 ticks before airtime")

			-- Lift off into air for 72 ticks (0.6 s): give slight upward vy so kart stays airborne
			state.linVel.y = 5.5
			for _ = 1, 72 do
				KartSolver.step(state, driftInput, airWorld, FixedStep.FIXED_DT)
				local telAir = KartSolver.getTelemetry(state)
				assert(telAir.isAirborne == true, "must be airborne in empty air")
				assertNear(
					telAir.skidFactor,
					1.0,
					1e-9,
					"skidFactor resets to 1.0 immediately in air (skidding.cpp:L399)"
				)
				assert(telAir.skidState == "SKID_ACCUMULATE_RIGHT", "skidState persists in air (skidding.cpp:L525)")
			end
			assert(state.skid.skidTimeTicks == ticksBeforeAir + 72, "skidTimeTicks kept incrementing in air")
			assert(KartSolver.getTelemetry(state).skidTier == 1, "crossed 1.0s Tier 1 threshold across airtime")

			-- Land back on ground at flat elevation and release drift -> Tier 1 boost (+2.25 m/s instant, 29.5 cap)
			state.pos.y = 0.291
			state.linVel.y = 0
			local preReleaseSpeed = state.speed
			KartSolver.step(state, {
				accel = 1,
				brake = false,
				steer = 0.0,
				drift = false,
				skidControl = "NONE",
				instantSteer = true,
			}, flatWorld, FixedStep.FIXED_DT)

			assert(state.skid.state == "SKID_SHOW_GFX_RIGHT", "release transitions to SKID_SHOW_GFX_RIGHT")
			assert(state.timedRotationTicks > 0, "post-skid timedRotation scheduled")
			assertNear(state.maxSpeedState.currentMaxSpeed, 29.5, 1e-4, "Tier 1 MaxSpeed cap = 25 + 4.5")
			assert(state.speed >= preReleaseSpeed + 1.8, "Tier 1 instant speed jump applied on release")

			-- 3) Tier 2 (> 3.0 s = > 360 ticks) boost (+3.25 m/s instant, 31.5 m/s cap)
			local sTier2 = KartSolver.createState(profile, { x = 0, y = 0.291, z = 0 }, 0)
			sTier2.linVel = { x = 0, y = 0, z = 22.0 }
			sTier2.speed = 22.0
			for _ = 1, 370 do
				KartSolver.step(sTier2, driftInput, flatWorld, FixedStep.FIXED_DT)
			end
			assert(KartSolver.getTelemetry(sTier2).skidTier == 2, "Tier 2 reached after > 3.0 s")
			KartSolver.step(sTier2, {
				accel = 1,
				brake = false,
				steer = 0,
				drift = false,
				skidControl = "NONE",
				instantSteer = true,
			}, flatWorld, FixedStep.FIXED_DT)
			assertNear(sTier2.maxSpeedState.currentMaxSpeed, 31.5, 1e-4, "Tier 2 MaxSpeed cap = 25 + 6.5")

			-- 4) Below 10 m/s aborts to SKID_BREAK with no boost
			local sAbort = KartSolver.createState(profile, { x = 0, y = 0.291, z = 0 }, 0)
			sAbort.linVel = { x = 0, y = 0, z = 15.0 }
			sAbort.speed = 15.0
			for _ = 1, 30 do
				KartSolver.step(sAbort, driftInput, flatWorld, FixedStep.FIXED_DT)
			end
			sAbort.linVel = { x = 0, y = 0, z = 5.0 }
			sAbort.speed = 5.0
			KartSolver.step(sAbort, driftInput, flatWorld, FixedStep.FIXED_DT)
			assert(sAbort.skid.state == "SKID_BREAK", "speed < 10 m/s triggers SKID_BREAK")
		end,
	},
	{
		name = "determinism under irregular dt sequences through FixedStep",
		fn = function()
			local function runDtSequence(dtList: { number }): KartSolver.KartState
				local world = makeFlatPlaneWorld(0)
				local state =
					KartSolver.createState(KartTuning.buildProfile("medium", "best"), { x = 0, y = 0.291, z = 0 }, 0)
				state.linVel = { x = 0, y = 0, z = 16.0 }
				state.speed = 16.0
				local stepper = FixedStep.new()
				local input: KartInput = {
					accel = 1,
					brake = false,
					steer = 0.65,
					drift = true,
				}
				for _, dt in dtList do
					stepper:advance(dt, function(fixedDt: number)
						KartSolver.step(state, input, world, fixedDt)
					end)
				end
				return state
			end

			-- All 3 sequences total exactly 0.500 s (60 ticks at 120 Hz)
			local irregular = {
				0.016,
				0.033,
				0.008,
				0.043,
				0.025,
				0.012,
				0.039,
				0.024,
				0.009,
				0.041,
				0.017,
				0.033,
				0.016,
				0.033,
				0.008,
				0.043,
				0.050,
				0.050,
			}
			local sixtyHz = {}
			for _ = 1, 30 do
				table.insert(sixtyHz, 1 / 60)
			end
			local oneTwentyHz = {}
			for _ = 1, 60 do
				table.insert(oneTwentyHz, 1 / 120)
			end

			local a = runDtSequence(irregular)
			local b = runDtSequence(sixtyHz)
			local c = runDtSequence(oneTwentyHz)

			assert(a.pos.x == b.pos.x and a.pos.x == c.pos.x, "pos.x must be bit-identical")
			assert(a.pos.y == b.pos.y and a.pos.y == c.pos.y, "pos.y must be bit-identical")
			assert(a.pos.z == b.pos.z and a.pos.z == c.pos.z, "pos.z must be bit-identical")
			assert(a.rot.w == b.rot.w and a.rot.y == c.rot.y, "rot quaternion must be bit-identical")
			assert(a.linVel.x == b.linVel.x and a.linVel.z == c.linVel.z, "linVel must be bit-identical")
			assert(
				a.skid.state == b.skid.state and a.skid.skidTimeTicks == c.skid.skidTimeTicks,
				"skid state must match"
			)
		end,
	},
	{
		name = "4-wheel suspension sag, straight top speed, and airborne gravity/leveling hit spec targets",
		fn = function()
			local flatWorld = makeFlatPlaneWorld(0)
			local profile = KartTuning.buildProfile("medium", "best")

			-- 1) Static equilibrium sag at rest (~0.0088 m -> suspLen ~0.291 m)
			local sRest = KartSolver.createState(profile, { x = 0, y = 0.30, z = 0 }, 0)
			local idle: KartInput = { accel = 0, brake = false, steer = 0, drift = false }
			for _ = 1, 240 do
				KartSolver.step(sRest, idle, flatWorld, FixedStep.FIXED_DT)
			end
			assert(sRest.numWheelsOnGround == 4, "all 4 wheels grounded at rest")
			assertNear(sRest.pos.y, 0.2912, 0.006, "static equilibrium height")

			-- 2) 0.5 m drop test settles cleanly within 0.5 s without bottoming out
			local sDrop = KartSolver.createState(profile, { x = 0, y = 0.80, z = 0 }, 0)
			local minY = math.huge
			for _ = 1, 120 do
				KartSolver.step(sDrop, idle, flatWorld, FixedStep.FIXED_DT)
				if sDrop.pos.y < minY then
					minY = sDrop.pos.y
				end
			end
			assert(minY > 0.05, "drop test must not bottom out chassis")
			assertNear(sDrop.pos.y, 0.2912, 0.02, "drop test settled height")

			-- 3) Straight full throttle reaches 25.0 m/s (+/- 0.15 m/s) with zero yaw drift
			local sTop = KartSolver.createState(profile, { x = 0, y = 0.291, z = 0 }, 0)
			local fullGas: KartInput = { accel = 1, brake = false, steer = 0, drift = false }
			for _ = 1, 960 do -- 8 s
				KartSolver.step(sTop, fullGas, flatWorld, FixedStep.FIXED_DT)
			end
			assertNear(sTop.speed, 25.0, 0.15, "Medium base top speed")
			assert(math.abs(extractYaw(sTop.rot)) < math.rad(0.1), "straight-line yaw drift < 0.1 deg")

			-- 4) Level airborne effective gravity = -(g + 4 * trackConnectionAccel) = -17.80665 m/s^2
			local airWorld = makeEmptyAirWorld()
			local sAirLevel = KartSolver.createState(profile, { x = 0, y = 10.0, z = 0 }, 0)
			local vy0 = sAirLevel.linVel.y
			for _ = 1, 30 do -- 0.25 s
				KartSolver.step(sAirLevel, idle, airWorld, FixedStep.FIXED_DT)
			end
			local measuredG = (vy0 - sAirLevel.linVel.y) / 0.25
			assertNear(measuredG, 9.80665 + 4 * 2.0, 0.05, "level airborne effective gravity")

			-- 5) Rolled airborne kart auto-levels under smoothFlyingImpulse = 250
			local sAirRoll = KartSolver.createState(profile, { x = 0, y = 10.0, z = 0 }, 0)
			sAirRoll.rot = Math3D.quatFromAxisAngle({ x = 0, y = 0, z = 1 }, math.rad(25))
			for _ = 1, 30 do
				KartSolver.step(sAirRoll, idle, airWorld, FixedStep.FIXED_DT)
			end
			local _, upAir, _ = Math3D.quatBasis(sAirRoll.rot)
			assert(upAir.y > math.cos(math.rad(15)), "smoothFlyingImpulse levels rolled airborne kart")

			-- 6) Steady-state cornering at 25 m/s tracks STK R(25) = 17.25 m cleanly without spinout
			local sTurn = KartSolver.createState(profile, { x = 0, y = 0.291, z = 0 }, 0)
			sTurn.linVel = { x = 0, y = 0, z = 25.0 }
			sTurn.speed = 25.0
			local fullRight: KartInput = { accel = 1, brake = false, steer = 1.0, drift = false, instantSteer = true }
			for _ = 1, 240 do -- 2 s steady turn
				KartSolver.step(sTurn, fullRight, flatWorld, FixedStep.FIXED_DT)
			end
			local yawRate = math.abs(sTurn.angVel.y)
			assert(yawRate > 0.5, "kart turns cleanly under full steer at 25 m/s")
			local measuredRadius = math.abs(sTurn.speed) / yawRate
			assert(
				measuredRadius > 12.0 and measuredRadius < 22.0,
				"steady turn radius at 25 m/s reasonable: " .. tostring(measuredRadius)
			)
			assert(sTurn.numWheelsOnGround == 4, "4 wheels stay grounded during high-speed cornering")
		end,
	},
}

return tests
