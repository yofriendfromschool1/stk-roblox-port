--!strict
-- tests/KartSolver.spec.luau
-- SPDX-License-Identifier: GPL-3.0-or-later

local FixedStep = require("../src/shared/sim/FixedStep")
local GreyboxProtocol = require("../src/shared/net/GreyboxProtocol")
local KartSolver = require("../src/shared/sim/KartSolver")
local KartTuning = require("../src/shared/KartTuning")
local Math3D = require("../src/shared/sim/Math3D")
local MaxSpeed = require("../src/shared/kart/MaxSpeed")
local Nitro = require("../src/shared/kart/Nitro")

type Vec3 = Math3D.Vec3
type Quat = Math3D.Quat
type RayHit = KartSolver.RayHit
type SweepHit = KartSolver.SweepHit
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

local function makeMaterialPlaneWorld(getMatAt: (x: number, z: number) -> string, groundY: number?): WorldQuery
	local yLevel = groundY or 0.0
	return {
		raycast = function(origin: Vec3, dir: Vec3, length: number): RayHit?
			if math.abs(dir.y) < 1e-9 then
				return nil
			end
			local t = (yLevel - origin.y) / dir.y
			if t >= 0 and t <= length then
				local hx = origin.x + dir.x * t
				local hz = origin.z + dir.z * t
				return {
					distance = t,
					point = { x = hx, y = yLevel, z = hz },
					normal = { x = 0, y = 1, z = 0 },
					materialName = getMatAt(hx, hz),
				}
			end
			return nil
		end,
	}
end

local function makeLayeredPlanesWorld(layers: { { y: number, materialName: string } }): WorldQuery
	return {
		raycast = function(origin: Vec3, dir: Vec3, length: number): RayHit?
			local bestT: number? = nil
			local bestMat = ""
			local bestY = 0
			for _, layer in layers do
				if math.abs(dir.y) >= 1e-9 then
					local t = (layer.y - origin.y) / dir.y
					if t >= 0 and t <= length and (bestT == nil or t < bestT) then
						bestT = t
						bestMat = layer.materialName
						bestY = layer.y
					end
				end
			end
			if bestT ~= nil then
				return {
					distance = bestT,
					point = {
						x = origin.x + dir.x * bestT,
						y = bestY,
						z = origin.z + dir.z * bestT,
					},
					normal = { x = 0, y = 1, z = 0 },
					materialName = bestMat,
				}
			end
			return nil
		end,
	}
end

local function makeTiltedPlaneWorld(tiltDeg: number, materialName: string): WorldQuery
	-- Plane passing through origin rolled around Z by tiltDeg: normal = (-sin(theta), cos(theta), 0)
	local rad = math.rad(tiltDeg)
	local normal: Vec3 = { x = -math.sin(rad), y = math.cos(rad), z = 0 }
	return {
		raycast = function(origin: Vec3, dir: Vec3, length: number): RayHit?
			local denom = Math3D.dot(dir, normal)
			if math.abs(denom) < 1e-9 then
				return nil
			end
			local t = -Math3D.dot(origin, normal) / denom
			if t >= 0 and t <= length then
				return {
					distance = t,
					point = {
						x = origin.x + dir.x * t,
						y = origin.y + dir.y * t,
						z = origin.z + dir.z * t,
					},
					normal = normal,
					materialName = materialName,
				}
			end
			return nil
		end,
	}
end

-- Ground (Y=0, road.jpg) transitioning at z=wallStartZ into an upward-pitched ramp/wall at angleDeg
local function makeBankedWallWorld(
	angleDeg: number,
	wallStartZ: number,
	wallMaterial: string
): (WorldQuery, (p: Vec3) -> number)
	local rad = math.rad(angleDeg)
	local nWall: Vec3 = { x = 0, y = math.cos(rad), z = -math.sin(rad) }

	local function signedDistToWall(p: Vec3): number
		return p.y * nWall.y + (p.z - wallStartZ) * nWall.z
	end

	local world: WorldQuery = {
		raycast = function(origin: Vec3, dir: Vec3, length: number): RayHit?
			local bestHit: RayHit? = nil
			if math.abs(dir.y) >= 1e-9 then
				local tGround = -origin.y / dir.y
				if tGround >= 0 and tGround <= length then
					local hz = origin.z + dir.z * tGround
					if hz <= wallStartZ then
						bestHit = {
							distance = tGround,
							point = { x = origin.x + dir.x * tGround, y = 0, z = hz },
							normal = { x = 0, y = 1, z = 0 },
							materialName = "road.jpg",
						}
					end
				end
			end

			local denom = Math3D.dot(dir, nWall)
			if math.abs(denom) >= 1e-9 then
				local tWall = -signedDistToWall(origin) / denom
				if tWall >= 0 and tWall <= length then
					local pt: Vec3 = {
						x = origin.x + dir.x * tWall,
						y = origin.y + dir.y * tWall,
						z = origin.z + dir.z * tWall,
					}
					if pt.y >= -0.05 and (bestHit == nil or tWall < bestHit.distance) then
						bestHit = {
							distance = tWall,
							point = pt,
							normal = nWall,
							materialName = wallMaterial,
						}
					end
				end
			end
			return bestHit
		end,
		sweepChassis = function(center: Vec3, rot: Quat, halfExtents: Vec3, delta: Vec3): SweepHit?
			local rAxis, uAxis, fAxis = Math3D.quatBasis(rot)
			local effR = halfExtents.x * math.abs(Math3D.dot(rAxis, nWall))
				+ halfExtents.y * math.abs(Math3D.dot(uAxis, nWall))
				+ halfExtents.z * math.abs(Math3D.dot(fAxis, nWall))
			local d0 = signedDistToWall(center) - effR
			local dDelta = Math3D.dot(delta, nWall)
			if dDelta < -1e-9 then
				local frac = if d0 <= 0 then 0.0 else d0 / -dDelta
				if frac >= 0.0 and frac <= 1.0 then
					local hitCenter = Math3D.add(center, Math3D.scale(delta, frac))
					if hitCenter.y >= -halfExtents.y and hitCenter.z + halfExtents.z >= wallStartZ - 1.0 then
						return {
							fraction = frac,
							point = Math3D.sub(hitCenter, Math3D.scale(nWall, effR)),
							normal = nWall,
							materialName = wallMaterial,
						}
					end
				end
			end
			return nil
		end,
	}
	return world, signedDistToWall
end

type HalfSpacePlane = {
	point: Vec3,
	normal: Vec3,
	materialName: string,
}

local function obbEffectiveRadius(rot: Quat, halfExtents: Vec3, normal: Vec3): number
	local rAxis, uAxis, fAxis = Math3D.quatBasis(rot)
	return halfExtents.x * math.abs(Math3D.dot(rAxis, normal))
		+ halfExtents.y * math.abs(Math3D.dot(uAxis, normal))
		+ halfExtents.z * math.abs(Math3D.dot(fAxis, normal))
end

local function makeHalfSpacePlanesWorld(planes: { HalfSpacePlane }): WorldQuery
	return {
		raycast = function(origin: Vec3, dir: Vec3, length: number): RayHit?
			local bestHit: RayHit? = nil
			for _, pl in planes do
				local denom = Math3D.dot(dir, pl.normal)
				if denom < -1e-9 then
					local sdOrig = Math3D.dot(Math3D.sub(origin, pl.point), pl.normal)
					local t = -sdOrig / denom
					if t >= 0 and t <= length and (bestHit == nil or t < bestHit.distance) then
						bestHit = {
							distance = t,
							point = Math3D.add(origin, Math3D.scale(dir, t)),
							normal = pl.normal,
							materialName = pl.materialName,
						}
					end
				end
			end
			return bestHit
		end,
		sweepChassis = function(center: Vec3, rot: Quat, halfExtents: Vec3, delta: Vec3): SweepHit?
			local bestHit: SweepHit? = nil
			for _, pl in planes do
				local effR = obbEffectiveRadius(rot, halfExtents, pl.normal)
				local d0 = Math3D.dot(Math3D.sub(center, pl.point), pl.normal) - effR
				local dDelta = Math3D.dot(delta, pl.normal)
				if dDelta < -1e-9 then
					local frac = if d0 <= 0 then 0.0 else d0 / -dDelta
					if frac >= 0.0 and frac <= 1.0 and (bestHit == nil or frac < bestHit.fraction) then
						local hitCenter = Math3D.add(center, Math3D.scale(delta, frac))
						bestHit = {
							fraction = frac,
							point = Math3D.sub(hitCenter, Math3D.scale(pl.normal, effR)),
							normal = pl.normal,
							materialName = pl.materialName,
						}
					end
				end
			end
			return bestHit
		end,
		checkChassisOverlap = function(center: Vec3, rot: Quat, halfExtents: Vec3): boolean
			for _, pl in planes do
				local effR = obbEffectiveRadius(rot, halfExtents, pl.normal)
				local d0 = Math3D.dot(Math3D.sub(center, pl.point), pl.normal) - effR
				if d0 < -1e-5 then
					return true
				end
			end
			return false
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
	{
		name = "sand.png enforces 50% max-speed cap and road.jpg restores full speed",
		fn = function()
			local profile = KartTuning.buildProfile("medium", "best")
			-- z < 10: road.jpg; 10 <= z < 50: sand.png; z >= 50: road.jpg
			local world = makeMaterialPlaneWorld(function(_x: number, z: number): string
				if z >= 10.0 and z < 50.0 then
					return "sand.png"
				end
				return "road.jpg"
			end, 0.0)

			local state = KartSolver.createState(profile, { x = 0, y = 0.291, z = 0.0 }, 0)
			state.linVel = { x = 0, y = 0, z = 25.0 }
			state.speed = 25.0
			local fullGas: KartInput = { accel = 1, brake = false, steer = 0, drift = false }

			-- Drive across sand.png (z in [10, 50) -> 40 m at 25->12.5 m/s takes ~2.5 s)
			local sawSandCap = false
			for _ = 1, 300 do -- 2.5 s
				KartSolver.step(state, fullGas, world, FixedStep.FIXED_DT)
				if state.activeMaterialName == "sand.png" and state.maxSpeedState.currentMaxSpeed <= 12.55 then
					sawSandCap = true
				end
			end
			assert(sawSandCap, "kart entered sand.png and hit 50% speed cap (12.5 m/s)")
			assert(
				state.activeMaterialName == "sand.png",
				"should still be on sand after 2.5 s: " .. state.activeMaterialName
			)
			assertNear(state.maxSpeedState.currentMaxSpeed, 12.5, 0.01, "sand.png 50% currentMaxSpeed cap")
			assertNear(state.speed, 12.5, 0.25, "sand.png steady capped speed")

			-- Drive off sand.png onto road.jpg (z >= 50)
			for _ = 1, 240 do -- 2.0 s
				KartSolver.step(state, fullGas, world, FixedStep.FIXED_DT)
			end
			assert(state.activeMaterialName == "road.jpg", "kart transitioned back onto road.jpg")
			assertNear(state.maxSpeedState.currentMaxSpeed, 25.0, 0.01, "road.jpg restores 25.0 m/s cap")
			assert(state.speed > 18.0, "kart re-accelerates cleanly on road.jpg, got " .. tostring(state.speed))
		end,
	},
	{
		name = "oasis-water.png is non-colliding and falls through to air or seabed.jpg reset",
		fn = function()
			local profile = KartTuning.buildProfile("medium", "best")
			local idle: KartInput = { accel = 0, brake = false, steer = 0, drift = false }

			-- A) Water at Y = 0 over empty void: raycast ignores water so kart falls right through
			local waterOnlyWorld = makeLayeredPlanesWorld({
				{ y = 0.0, materialName = "oasis-water.png" },
			})
			local sVoid = KartSolver.createState(profile, { x = 0, y = 0.291, z = 0 }, 0)
			for _ = 1, 72 do -- 0.6 s
				KartSolver.step(sVoid, idle, waterOnlyWorld, FixedStep.FIXED_DT)
			end
			assert(sVoid.numWheelsOnGround == 0, "oasis-water.png must not support kart wheels")
			assert(sVoid.pos.y < -1.0, "kart falls through oasis-water.png, y=" .. tostring(sVoid.pos.y))

			-- B) Water at Y = 0 above seabed.jpg at Y = -2.0: passes through water, lands & triggers reset
			local layeredWorld = makeLayeredPlanesWorld({
				{ y = 0.0, materialName = "oasis-water.png" },
				{ y = -2.0, materialName = "seabed.jpg" },
			})
			local sSeabed = KartSolver.createState(profile, { x = 0, y = 0.291, z = 0 }, 0)
			local sawSeabedReset = false
			for _ = 1, 180 do -- 1.5 s
				KartSolver.step(sSeabed, idle, layeredWorld, FixedStep.FIXED_DT)
				if sSeabed.resetTriggered and sSeabed.activeMaterialName == "seabed.jpg" then
					sawSeabedReset = true
				end
			end
			assert(sawSeabedReset, "kart fell through water onto seabed.jpg and triggered reset")
			assert(sSeabed.pos.y < -1.5, "kart settled on Y=-2 seabed, got y=" .. tostring(sSeabed.pos.y))
		end,
	},
	{
		name = "transparence2.png & water_light.png trigger reset and pyramidwall.jpg gives high adhesion on 35 deg slope",
		fn = function()
			local profile = KartTuning.buildProfile("medium", "best")
			local idle: KartInput = { accel = 0, brake = false, steer = 0, drift = false }

			-- 1) transparence2.png collision-reaction="reset"
			local resetBarrierWorld = makeMaterialPlaneWorld(function()
				return "transparence2.png"
			end, 0.0)
			local sBarrier = KartSolver.createState(profile, { x = 0, y = 0.291, z = 0 }, 0)
			KartSolver.step(sBarrier, idle, resetBarrierWorld, FixedStep.FIXED_DT)
			local telBarrier = KartSolver.getTelemetry(sBarrier)
			assert(telBarrier.resetTriggered, "transparence2.png triggers reset")
			assert(telBarrier.lastCollisionReaction == "reset", "transparence2.png sets collisionReaction=reset")

			-- 2) water_light.png falling-effect="Y" forces reset=true
			local waterLightWorld = makeMaterialPlaneWorld(function()
				return "water_light.png"
			end, 0.0)
			local sWaterLight = KartSolver.createState(profile, { x = 0, y = 0.291, z = 0 }, 0)
			KartSolver.step(sWaterLight, idle, waterLightWorld, FixedStep.FIXED_DT)
			assert(sWaterLight.resetTriggered, "water_light.png triggers reset via falling-effect=Y")

			-- 3) 35 deg bank: dot(n, up) = cos(35 deg) = 0.819 < 0.85.
			-- road.jpg loses all slope grip (slides down -X), pyramidwall.jpg keeps full tire adhesion.
			local slopeRad = math.rad(35)
			local slopeRot = Math3D.quatFromAxisAngle({ x = 0, y = 0, z = 1 }, slopeRad)
			local _, slopeUp, _ = Math3D.quatBasis(slopeRot)

			local function runSlopeTest(matName: string): number
				local w = makeTiltedPlaneWorld(35, matName)
				local s = KartSolver.createState(profile, Math3D.scale(slopeUp, 0.291), 0)
				s.rot = slopeRot
				s.linVel = { x = 0, y = 0, z = 15.0 }
				s.speed = 15.0
				local gas: KartInput = { accel = 1, brake = false, steer = 0, drift = false }
				for _ = 1, 60 do -- 0.5 s
					KartSolver.step(s, gas, w, FixedStep.FIXED_DT)
				end
				local slopeRight, _, _ = Math3D.quatBasis(slopeRot)
				return math.abs(Math3D.dot(s.linVel, slopeRight))
			end

			local slideRoad = runSlopeTest("road.jpg")
			local slidePyramid = runSlopeTest("pyramidwall.jpg")
			assert(slideRoad > 1.5, "road.jpg should slide noticeably on 35 deg slope, got " .. tostring(slideRoad))
			assert(
				slidePyramid < slideRoad * 0.25,
				"pyramidwall.jpg high-adhesion must resist 35 deg slide vs road.jpg ("
					.. tostring(slidePyramid)
					.. " vs "
					.. tostring(slideRoad)
					.. ")"
			)
		end,
	},
	{
		name = "nitro reserve, 64-tick minimum burn, 30 m/s top speed, fade-out engineForce=0, and full MaxSpeed enum",
		fn = function()
			-- 1) Full upstream enum counts (max_speed.hpp:L37-L53)
			assert(#MaxSpeed.INCREASE_CATEGORIES == 6, "6 SpeedIncrease categories")
			assert(#MaxSpeed.DECREASE_CATEGORIES == 4, "4 SpeedDecrease categories")

			local profile = KartTuning.buildProfile("medium", "best")
			local ms = MaxSpeed.new(profile.maxSpeed)
			-- Engine force active during durationTicks > 0, zero during fade-out (max_speed.hpp:L117-L120)
			MaxSpeed.increaseMaxSpeed(ms, "ZIPPER", 15.0, 400.0, 2, 10)
			MaxSpeed.update(ms, 1, true)
			assert(ms.additionalEngineForce > 0, "ZIPPER adds engine force while duration > 0")
			MaxSpeed.update(ms, 2, true)
			assertNear(ms.additionalEngineForce, 0.0, 1e-6, "engineForce drops to 0 during fade-out")
			assert(ms.currentMaxSpeed > profile.maxSpeed, "speed increase fades smoothly after duration")

			-- 2) Nitro clamp + 64-tick minimum burn + proportional partial burn ratio (kart.cpp:L2244-L2302)
			local nitroState = Nitro.new(profile.nitro.max)
			assertNear(Nitro.collect(nitroState, 50.0), 20.0, 1e-6, "nitro reserve clamps at max=20.0")
			local burnMs = MaxSpeed.new(profile.maxSpeed)
			-- Press nitro + accel for 1 tick, then release; minNitroTicks counts down 63 -> 0 (ticks 1..63 active, tick 64 exits)
			local firstActive = Nitro.update(nitroState, profile.nitro, burnMs, 1, true, true, true)
			assert(firstActive == true, "tick 1 activates nitro")
			assert(nitroState.minNitroTicks == 63, "min burn starts at 64-1=63 ticks")
			for _ = 2, 63 do
				local active = Nitro.update(nitroState, profile.nitro, burnMs, 1, false, true, true)
				assert(active == true, "nitro stays active throughout 64-tick minimum burn")
			end
			local afterMin = Nitro.update(nitroState, profile.nitro, burnMs, 1, false, true, true)
			assert(afterMin == false, "nitro stops once 64-tick min burn expires with key released")

			-- Partial reserve below minConsumption scales NITRO duration proportionally
			local tinyNitro = Nitro.new(profile.nitro.max)
			local minConsumption = profile.nitro.minConsumptionTicks * profile.nitro.consumptionPerTick
			Nitro.collect(tinyNitro, minConsumption * 0.5)
			local partialMs = MaxSpeed.new(profile.maxSpeed)
			Nitro.update(tinyNitro, profile.nitro, partialMs, 1, true, true, true)
			assertNear(tinyNitro.energyToMinRatio, 0.5, 1e-4, "partial reserve scales energyToMinRatio")
			local expectedHalfTicks = FixedStep.timeToTicks(profile.nitro.duration * 0.5)
			assert(
				MaxSpeed.getSpeedIncreaseTicksLeft(partialMs, "NITRO") == expectedHalfTicks,
				"partial NITRO durationTicks scaled proportionally"
			)

			-- 3) Integrated solver: airborne nitro blocked, grounded nitro hits 30.0 m/s (+/- 0.25)
			local airWorld = makeEmptyAirWorld()
			local sAir = KartSolver.createState(profile, { x = 0, y = 10, z = 0 }, 0)
			KartSolver.addNitro(sAir, 10.0)
			KartSolver.step(
				sAir,
				{ accel = 1, brake = false, steer = 0, drift = false, nitro = true },
				airWorld,
				FixedStep.FIXED_DT
			)
			assert(sAir.nitro.active == false, "airborne kart does not trigger ground NITRO boost")

			local roadWorld = makeMaterialPlaneWorld(function()
				return "road.jpg"
			end, 0.0)
			local sNitro = KartSolver.createState(profile, { x = 0, y = 0.291, z = 0 }, 0)
			KartSolver.addNitro(sNitro, 20.0)
			local nitroInput: KartInput = { accel = 1, brake = false, steer = 0, drift = false, nitro = true }
			for _ = 1, 720 do -- 6.0 s full throttle + nitro
				KartSolver.step(sNitro, nitroInput, roadWorld, FixedStep.FIXED_DT)
			end
			local tel = KartSolver.getTelemetry(sNitro)
			assert(tel.nitroActive, "nitro stays active while reserve remains")
			assertNear(tel.currentMaxSpeed, 30.0, 0.05, "Medium NITRO max speed = 30.0 m/s")
			assertNear(tel.speedMps, 30.0, 0.25, "Medium kart achieves 30.0 m/s under NITRO")
		end,
	},
	{
		name = "fast drift at 25 m/s keeps all 4 wheels grounded with zero airborne liftoff",
		fn = function()
			local profile = KartTuning.buildProfile("medium", "best")
			local world = makeMaterialPlaneWorld(function()
				return "road.jpg"
			end, 0.0)
			local state = KartSolver.createState(profile, { x = 0, y = 0.291, z = 0 }, 0)
			state.linVel = { x = 0, y = 0, z = 25.0 }
			state.speed = 25.0

			local driftRight: KartInput = { accel = 1, brake = false, steer = 1.0, drift = true }
			for tick = 1, 420 do -- 3.5 s continuous fast drift (reaches Tier 2)
				KartSolver.step(state, driftRight, world, FixedStep.FIXED_DT)
				assert(
					state.numWheelsOnGround == 4,
					string.format(
						"fast drift lifted wheel at tick %d: grounded=%d y=%.3f",
						tick,
						state.numWheelsOnGround,
						state.pos.y
					)
				)
				assert(
					state.pos.y >= 0.20 and state.pos.y <= 0.35,
					string.format("fast drift height out of bounds at tick %d: y=%.3f", tick, state.pos.y)
				)
				local rightVec, upVec, _ = Math3D.quatBasis(state.rot)
				assert(
					upVec.y > math.cos(math.rad(4)),
					"chassis roll/pitch stayed near level: right.y=" .. tostring(rightVec.y)
				)
			end
			assert(state.skid.currentTier == 2, "fast drift charged cleanly to Tier 2 without liftoff")
		end,
	},
	{
		name = "25 m/s into 35, 45, and 60 deg banked walls produces zero penetration and clean slide",
		fn = function()
			local profile = KartTuning.buildProfile("medium", "best")
			local gas: KartInput = { accel = 1, brake = false, steer = 0, drift = false }

			for _, cfg in
				{
					{ deg = 35, mat = "pyramidwall.jpg" },
					{ deg = 45, mat = "pyramidwall.jpg" },
					{ deg = 60, mat = "road.jpg" },
				}
			do
				local wallZ = 10.0
				local world, signedDistToWall = makeBankedWallWorld(cfg.deg, wallZ, cfg.mat)
				local state = KartSolver.createState(profile, { x = 0, y = 0.291, z = 2.0 }, 0)
				state.linVel = { x = 0, y = 0, z = 25.0 }
				state.speed = 25.0

				local minSd = math.huge
				local maxZ = -math.huge
				for tick = 1, 180 do -- 1.5 s
					KartSolver.step(state, gas, world, FixedStep.FIXED_DT)
					assert(
						state.pos.x == state.pos.x and state.pos.y == state.pos.y and state.pos.z == state.pos.z,
						"non-NaN pos"
					)
					assert(
						state.pos.y >= -0.02,
						string.format("%d deg ground sink at tick %d: y=%.4f", cfg.deg, tick, state.pos.y)
					)
					local sd = signedDistToWall(state.pos)
					if sd < minSd then
						minSd = sd
					end
					if state.pos.z > maxZ then
						maxZ = state.pos.z
					end
				end

				assert(
					minSd >= -0.02,
					string.format("%d deg bank penetrated wall at 25 m/s: minSignedDist=%.4f m", cfg.deg, minSd)
				)
				assert(
					state.depenetrationCount + state.chassisSweepHitCount > 0,
					string.format("%d deg bank engaged depenetration/sweep contact", cfg.deg)
				)
				if cfg.deg <= 45 then
					assert(
						state.pos.y > 1.0,
						string.format("%d deg high-adhesion ramp climbed cleanly: y=%.2f", cfg.deg, state.pos.y)
					)
				else
					-- 60 deg steep wall deflects/slides rather than tunneling through wall plane
					assert(
						maxZ < wallZ + 4.0 and minSd >= -0.02,
						string.format("60 deg wall blocked tunneling cleanly (maxZ=%.2f)", maxZ)
					)
				end
			end
		end,
	},
	{
		name = "wheelRayOriginBias is subtracted cleanly before rawHitDistance and compressionRatio",
		fn = function()
			local profile = KartTuning.buildProfile("medium", "best")
			local world = makeFlatPlaneWorld(0.0)
			local state = KartSolver.createState(profile, { x = 0, y = 0.2912, z = 0 }, 0)
			local idle: KartInput = { accel = 0, brake = false, steer = 0, drift = false }
			KartSolver.step(state, idle, world, FixedStep.FIXED_DT)

			for i = 1, 4 do
				local w = state.wheels[i]
				assert(w.isInContact, "wheel " .. tostring(i) .. " in contact")
				assertNear(w.rawHitDistance, 0.2912, 5e-4, "bias-subtracted rawHitDistance")
				local expectedComp = (KartTuning.suspension.rest - 0.2912) / KartTuning.suspension.travel
				assertNear(w.compressionRatio, expectedComp, 2e-3, "bias-subtracted compressionRatio")
			end
			assert(state.depenetrationCount == 0, "no false bottom-out depenetration at rest height")
		end,
	},
	{
		name = "NITRO stacks with SKIDDING and RED_SKIDDING while RED_SKIDDING suppresses SKIDDING per max_speed.cpp",
		fn = function()
			local profile = KartTuning.buildProfile("medium", "best")
			local ms = MaxSpeed.new(profile.maxSpeed)
			-- NITRO (+5.0 m/s) + Tier 1 SKIDDING (+4.5 m/s) -> 34.5 m/s
			MaxSpeed.increaseMaxSpeed(ms, "NITRO", 5.0, 225.0, 120, 60)
			MaxSpeed.increaseMaxSpeed(ms, "SKIDDING", 4.5, 250.0, 120, 60)
			MaxSpeed.update(ms, 1, true)
			assertNear(ms.currentMaxSpeed, 34.5, 1e-6, "NITRO + SKIDDING stack to 34.5 m/s")
			assertNear(ms.additionalEngineForce, 475.0, 1e-6, "NITRO + SKIDDING engine forces sum")

			-- Adding RED_SKIDDING (+6.5 m/s, 350 N) suppresses SKIDDING while keeping NITRO stacked -> 36.5 m/s
			MaxSpeed.increaseMaxSpeed(ms, "RED_SKIDDING", 6.5, 350.0, 120, 60)
			MaxSpeed.update(ms, 1, true)
			assertNear(ms.currentMaxSpeed, 36.5, 1e-6, "NITRO + RED_SKIDDING suppress SKIDDING -> 36.5 m/s")
			assertNear(ms.additionalEngineForce, 575.0, 1e-6, "RED_SKIDDING suppresses SKIDDING engine force only")
		end,
	},
	{
		name = "resting 5s against 90 deg wall (plus Tier 1 drift boost) stays strictly non-penetrating",
		fn = function()
			local profile = KartTuning.buildProfile("medium", "best")
			local wallZ = 5.0
			local wallNormal: Vec3 = { x = 0, y = 0, z = -1 }
			local world = makeHalfSpacePlanesWorld({
				{ point = { x = 0, y = 0, z = 0 }, normal = { x = 0, y = 1, z = 0 }, materialName = "road.jpg" },
				{ point = { x = 0, y = 0, z = wallZ }, normal = wallNormal, materialName = "road.jpg" },
			})

			-- Press full throttle against vertical wall for 5.0 s (600 ticks)
			local state = KartSolver.createState(profile, { x = 0, y = 0.291, z = 4.0 }, 0)
			local gas: KartInput = { accel = 1, brake = false, steer = 0, drift = false }
			for tick = 1, 600 do
				KartSolver.step(state, gas, world, FixedStep.FIXED_DT)
				assert(
					state.pos.z <= wallZ + 0.02,
					string.format("head-on wall creep at tick %d: z=%.4f", tick, state.pos.z)
				)
			end

			-- Angled wall press with 1.1s drift + Tier 1 instant +2.25 m/s boost release at wall
			local sBoost = KartSolver.createState(profile, { x = 0, y = 0.291, z = 2.0 }, math.rad(15))
			sBoost.linVel = { x = 0, y = 0, z = 14.0 }
			sBoost.speed = 14.0
			local driftIntoWall: KartInput =
				{ accel = 1, brake = false, steer = 0.7, drift = true, skidControl = "RIGHT" }
			for tick = 1, 300 do -- 2.5 s across 1.0s Tier 1 trigger and release at 1.1s
				local inp = if tick <= 132 then driftIntoWall else gas
				KartSolver.step(sBoost, inp, world, FixedStep.FIXED_DT)
				assert(
					sBoost.pos.z <= wallZ + 0.02,
					string.format("Tier-1 wall boost penetrated at tick %d: z=%.4f", tick, sBoost.pos.z)
				)
			end
		end,
	},
	{
		name = "resting 5s pressing into 35 deg / 60 deg slopes and 90 deg inside corner stays outside all planes",
		fn = function()
			local profile = KartTuning.buildProfile("medium", "best")
			local gas: KartInput = { accel = 1, brake = false, steer = 0, drift = false }

			for _, deg in { 35, 60 } do
				local rad = math.rad(deg)
				local nSlope: Vec3 = { x = 0, y = math.cos(rad), z = -math.sin(rad) }
				local slopePt: Vec3 = { x = 0, y = 0, z = 5.0 }
				local world = makeHalfSpacePlanesWorld({
					{ point = { x = 0, y = 0, z = 0 }, normal = { x = 0, y = 1, z = 0 }, materialName = "road.jpg" },
					{ point = slopePt, normal = nSlope, materialName = "road.jpg" },
				})
				local s = KartSolver.createState(profile, { x = 0, y = 0.291, z = 3.5 }, 0)
				for tick = 1, 600 do
					KartSolver.step(s, gas, world, FixedStep.FIXED_DT)
					local sd = Math3D.dot(Math3D.sub(s.pos, slopePt), nSlope)
					assert(
						sd >= -0.02,
						string.format("%d deg resting slope penetrated at tick %d: sd=%.4f", deg, tick, sd)
					)
					assert(s.pos.y >= -0.02, string.format("%d deg ground sink at tick %d: y=%.4f", deg, tick, s.pos.y))
				end
			end

			-- 90 deg inside corner: North wall (Z <= 6) + East wall (X <= 6), approach diagonally at 45 deg
			local cornerWorld = makeHalfSpacePlanesWorld({
				{ point = { x = 0, y = 0, z = 0 }, normal = { x = 0, y = 1, z = 0 }, materialName = "road.jpg" },
				{ point = { x = 0, y = 0, z = 6.0 }, normal = { x = 0, y = 0, z = -1 }, materialName = "road.jpg" },
				{ point = { x = 6.0, y = 0, z = 0 }, normal = { x = -1, y = 0, z = 0 }, materialName = "road.jpg" },
			})
			local sCorner = KartSolver.createState(profile, { x = 4.0, y = 0.291, z = 4.0 }, math.rad(45))
			sCorner.linVel = { x = 8.0, y = 0, z = 8.0 }
			sCorner.speed = 11.3
			for tick = 1, 600 do
				KartSolver.step(sCorner, gas, cornerWorld, FixedStep.FIXED_DT)
				assert(
					sCorner.pos.z <= 6.02,
					string.format("inside corner Z penetrated at tick %d: z=%.4f", tick, sCorner.pos.z)
				)
				assert(
					sCorner.pos.x <= 6.02,
					string.format("inside corner X penetrated at tick %d: x=%.4f", tick, sCorner.pos.x)
				)
			end
		end,
	},
	{
		name = "captureNetState and applyNetState replay unacknowledged inputs deterministically",
		fn = function()
			local profile = KartTuning.buildProfile("medium", "best")
			local world = makeMaterialPlaneWorld(function()
				return "road.jpg"
			end, 0.0)

			local inputs: { KartInput } = {}
			for t = 1, 60 do
				inputs[t] = {
					accel = 1.0,
					brake = false,
					steer = if t > 15 then 0.8 else 0.0,
					drift = t > 20 and t < 50,
					nitro = t > 25,
				}
			end

			local sRef = KartSolver.createState(profile, { x = 0, y = 0.291, z = 0 }, 0)
			KartSolver.addNitro(sRef, 5.0)
			local snapAt20: KartSolver.NetState? = nil
			for t = 1, 60 do
				KartSolver.step(sRef, inputs[t], world, FixedStep.FIXED_DT)
				if t == 20 then
					snapAt20 = KartSolver.captureNetState(sRef)
				end
			end

			local sReplay = KartSolver.createState(profile, { x = 0, y = 0.291, z = 0 }, 0)
			KartSolver.applyNetState(sReplay, snapAt20 :: KartSolver.NetState)
			for t = 21, 60 do
				KartSolver.step(sReplay, inputs[t], world, FixedStep.FIXED_DT)
			end

			assertNear(sReplay.pos.x, sRef.pos.x, 1e-6, "replay pos.x")
			assertNear(sReplay.pos.y, sRef.pos.y, 1e-6, "replay pos.y")
			assertNear(sReplay.pos.z, sRef.pos.z, 1e-6, "replay pos.z")
			assertNear(sReplay.linVel.x, sRef.linVel.x, 1e-6, "replay linVel.x")
			assertNear(sReplay.linVel.z, sRef.linVel.z, 1e-6, "replay linVel.z")
			assertNear(sReplay.nitro.energy, sRef.nitro.energy, 1e-6, "replay nitro.energy")
			assert(sReplay.skid.state == sRef.skid.state, "replay skid.state")
		end,
	},
	{
		name = "wallRestitution follows STK 0:1.0, 5:1.0, 20:0.2 speed curve on dynamic impacts",
		fn = function()
			assertNear(KartSolver.evalWallRestitution(0.0), 1.0, 1e-6, "restitution at 0 m/s")
			assertNear(KartSolver.evalWallRestitution(5.0), 1.0, 1e-6, "restitution at 5 m/s")
			assertNear(KartSolver.evalWallRestitution(12.5), 0.6, 1e-6, "restitution at 12.5 m/s")
			assertNear(KartSolver.evalWallRestitution(20.0), 0.2, 1e-6, "restitution at 20 m/s")
			assertNear(KartSolver.evalWallRestitution(30.0), 0.2, 1e-6, "restitution clamped above 20 m/s")

			local profile = KartTuning.buildProfile("medium", "best")
			local wallZ = 5.0
			local world = makeHalfSpacePlanesWorld({
				{ point = { x = 0, y = 0, z = 0 }, normal = { x = 0, y = 1, z = 0 }, materialName = "road.jpg" },
				{ point = { x = 0, y = 0, z = wallZ }, normal = { x = 0, y = 0, z = -1 }, materialName = "road.jpg" },
			})
			local coast: KartInput = { accel = 0, brake = false, steer = 0, drift = false }

			local function bounceSpeedFrom(v0: number): number
				local s = KartSolver.createState(profile, { x = 0, y = 0.291, z = wallZ - 0.05 }, 0)
				s.linVel = { x = 0, y = 0, z = v0 }
				s.speed = v0
				for _ = 1, 10 do
					KartSolver.step(s, coast, world, FixedStep.FIXED_DT)
					if s.linVel.z < 0 then
						return -s.linVel.z
					end
				end
				return 0
			end

			local reboundAt10 = bounceSpeedFrom(10.0)
			local reboundAt20 = bounceSpeedFrom(20.0)
			assert(
				reboundAt10 > 5.0 and reboundAt10 < 9.0,
				string.format("10 m/s wall impact uses ~0.73 restitution: rebound=%.2f", reboundAt10)
			)
			assert(
				reboundAt20 > 2.5 and reboundAt20 < 5.0,
				string.format("20 m/s wall impact uses ~0.20 restitution: rebound=%.2f", reboundAt20)
			)
			assert(
				reboundAt10 > reboundAt20,
				string.format(
					"higher speed has lower restitution ratio: 10->%.2f vs 20->%.2f",
					reboundAt10,
					reboundAt20
				)
			)
		end,
	},
	{
		name = "nitro activation follows kart.cpp:L2249-L2296 (no accel gate; airborne drains without boost)",
		fn = function()
			local profile = KartTuning.buildProfile("medium", "best")
			local roadWorld = makeMaterialPlaneWorld(function()
				return "road.jpg"
			end, 0.0)
			local airWorld = makeEmptyAirWorld()

			-- 1) Grounded kart pressing nitro without accel activates and drains per kart.cpp:L2249
			local sNoAccel = KartSolver.createState(profile, { x = 0, y = 0.291, z = 0 }, 0)
			KartSolver.addNitro(sNoAccel, 10.0)
			for _ = 1, 20 do
				KartSolver.step(
					sNoAccel,
					{ accel = 0, brake = false, steer = 0, drift = false, nitro = true },
					roadWorld,
					FixedStep.FIXED_DT
				)
			end
			assert(sNoAccel.nitro.active, "nitro activates on nitroPressed even without accel > 0")
			assert(sNoAccel.nitro.minNitroTicks > 0, "minNitroTicks committed")
			assert(sNoAccel.nitro.energy < 10.0, "nitro energy drained on burn")

			-- 2) Airborne kart pressing nitro commits burn & drains energy, but does NOT apply speed boost
			local sAir = KartSolver.createState(profile, { x = 0, y = 10.0, z = 0 }, 0)
			KartSolver.addNitro(sAir, 10.0)
			for _ = 1, 10 do
				KartSolver.step(
					sAir,
					{ accel = 1, brake = false, steer = 0, drift = false, nitro = true },
					airWorld,
					FixedStep.FIXED_DT
				)
			end
			assert(not sAir.nitro.active, "nitro speed boost is gated on isOnGround")
			assert(sAir.nitro.minNitroTicks > 0, "minNitroTicks committed even while airborne")
			assert(sAir.nitro.energy < 10.0, "nitro energy drains while committed in air")

			-- 3) Committed 64-tick burn (activated with accel=1 & grounded) completes if accel + nitro are released
			local sCommit = KartSolver.createState(profile, { x = 0, y = 0.291, z = 0 }, 0)
			KartSolver.addNitro(sCommit, 20.0)
			KartSolver.step(
				sCommit,
				{ accel = 1, brake = false, steer = 0, drift = false, nitro = true },
				roadWorld,
				FixedStep.FIXED_DT
			)
			assert(sCommit.nitro.active, "tick 1 with accel+ground+nitro activates committed burn")
			assert(sCommit.nitro.minNitroTicks == 63, "64-tick commitment starts at 63 remaining ticks")
			for tick = 2, 63 do
				KartSolver.step(
					sCommit,
					{ accel = 0, brake = false, steer = 0, drift = false, nitro = false },
					roadWorld,
					FixedStep.FIXED_DT
				)
				assert(
					sCommit.nitro.active,
					string.format("committed burn must stay active at tick %d even with accel=0", tick)
				)
			end
			-- On tick 64, releasing nitro ends the committed burn cleanly
			KartSolver.step(
				sCommit,
				{ accel = 0, brake = false, steer = 0, drift = false, nitro = false },
				roadWorld,
				FixedStep.FIXED_DT
			)
			assert(not sCommit.nitro.active, "committed burn ends at tick 64 when nitro is released")
			assert(sCommit.nitro.minNitroTicks == 0, "minNitroTicks returns to 0 after committed burn")
		end,
	},
	{
		name = "60-tick stuck escape recovers instead of stranding",
		fn = function()
			local baseWorld = makeFlatPlaneWorld(0)
			local alwaysOverlapWorld: WorldQuery = {
				raycast = baseWorld.raycast,
				sweepChassis = nil,
				checkChassisOverlap = function(): boolean
					return true
				end,
			}
			local profile = KartTuning.buildProfile("medium", "best")
			local state = KartSolver.createState(profile, { x = 0, y = 0.291, z = 0 }, 0)
			local driveInput: KartInput = { accel = 1, brake = false, steer = 0, drift = false }

			for tick = 1, 59 do
				KartSolver.step(state, driveInput, alwaysOverlapWorld, FixedStep.FIXED_DT)
				assert(
					state.stuckTicks == tick,
					string.format("expected stuckTicks == %d at tick %d, got %d", tick, tick, state.stuckTicks)
				)
				assertNear(state.pos.z, 0, 1e-6, "pinned at spawn before 60-tick escape")
			end

			KartSolver.step(state, driveInput, alwaysOverlapWorld, FixedStep.FIXED_DT)
			assert(state.stuckTicks == 0, "stuckTicks resets to 0 on 60th overlapping tick")
			assert(state.pos.z > 1e-4, "kart escapes forward on 60th tick instead of stranding")
			assertNear(state.lastSafePos.z, state.pos.z, 1e-9, "lastSafePos updated to escaped pos")
		end,
	},
	{
		name = "stuckTicks survives capture/restore/replay and GreyboxProtocol pack/unpack identically",
		fn = function()
			local baseWorld = makeFlatPlaneWorld(0)
			local alwaysOverlapWorld: WorldQuery = {
				raycast = baseWorld.raycast,
				sweepChassis = nil,
				checkChassisOverlap = function(): boolean
					return true
				end,
			}
			local profile = KartTuning.buildProfile("medium", "best")
			local driveInput: KartInput = { accel = 1, brake = false, steer = 0, drift = false }

			-- Baseline: 65 continuous ticks
			local stateA = KartSolver.createState(profile, { x = 0, y = 0.291, z = 0 }, 0)
			for _ = 1, 65 do
				KartSolver.step(stateA, driveInput, alwaysOverlapWorld, FixedStep.FIXED_DT)
			end
			assert(stateA.stuckTicks == 5, "65 ticks = 1 escape (60) + 5 overlapping ticks")

			-- Replay: 25 ticks -> capture -> pack/unpack -> applyNetState -> 40 ticks
			local stateB = KartSolver.createState(profile, { x = 0, y = 0.291, z = 0 }, 0)
			for _ = 1, 25 do
				KartSolver.step(stateB, driveInput, alwaysOverlapWorld, FixedStep.FIXED_DT)
			end
			assert(stateB.stuckTicks == 25, "stuckTicks == 25 before snapshot")

			local snap = KartSolver.captureNetState(stateB)
			assert(snap.stuckTicks == 25, "captureNetState preserves stuckTicks")
			local buf, notice = GreyboxProtocol.packSnapshot(25, 25, 0, snap, "", nil, 0)
			local pkt = GreyboxProtocol.unpackSnapshot(buf, notice)
			assert(pkt ~= nil, "unpackSnapshot succeeded")
			assert((pkt :: any).netState.stuckTicks == 25, "GreyboxProtocol preserves stuckTicks")

			local stateC = KartSolver.createState(profile, { x = 0, y = 0.291, z = 0 }, 0)
			KartSolver.applyNetState(stateC, (pkt :: any).netState)
			assert(stateC.stuckTicks == 25, "applyNetState restores stuckTicks == 25")

			for _ = 1, 40 do
				KartSolver.step(stateC, driveInput, alwaysOverlapWorld, FixedStep.FIXED_DT)
			end

			assert(stateC.stuckTicks == stateA.stuckTicks, "post-replay stuckTicks matches baseline")
			assertNear(stateC.pos.x, stateA.pos.x, 1e-9, "post-replay pos.x bit-identical")
			assertNear(stateC.pos.y, stateA.pos.y, 1e-9, "post-replay pos.y bit-identical")
			assertNear(stateC.pos.z, stateA.pos.z, 1e-9, "post-replay pos.z bit-identical")
			assertNear(stateC.linVel.z, stateA.linVel.z, 1e-9, "post-replay linVel.z bit-identical")
		end,
	},
	{
		name = "real wall rollback never ratchets into wall after 60+ ticks of sustained throttle",
		fn = function()
			local baseWorld = makeFlatPlaneWorld(0)
			local wallOnlyWorld: WorldQuery = {
				raycast = baseWorld.raycast,
				sweepChassis = nil,
				checkChassisOverlap = function(center: Vec3, _rot: Quat, halfExtents: Vec3): boolean
					return (center.z + halfExtents.z) > 10.0
				end,
			}
			local profile = KartTuning.buildProfile("medium", "best")
			local state = KartSolver.createState(profile, { x = 0, y = 0.291, z = 8.0 }, 0)
			local driveInput: KartInput = { accel = 1, brake = false, steer = 0, drift = false }

			for _ = 1, 240 do
				KartSolver.step(state, driveInput, wallOnlyWorld, FixedStep.FIXED_DT)
				local frontZ = state.pos.z + 0.5 * profile.length
				assert(frontZ <= 10.0 + 1e-4, string.format("kart ratcheted past z=10 wall: frontZ=%.4f", frontZ))
			end
		end,
	},
}

return tests
