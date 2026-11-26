--!strict
-- tests/Slipstream.spec.luau
-- SPDX-License-Identifier: GPL-3.0-or-later

local FixedStep = require("../src/shared/sim/FixedStep")
local GreyboxProtocol = require("../src/shared/net/GreyboxProtocol")
local KartSolver = require("../src/shared/sim/KartSolver")
local KartTuning = require("../src/shared/KartTuning")
local Math3D = require("../src/shared/sim/Math3D")
local MaxSpeed = require("../src/shared/kart/MaxSpeed")
local Slipstream = require("../src/shared/sim/Slipstream")
local SlipstreamVfxMath = require("../src/shared/kart/SlipstreamVfxMath")

local DT = FixedStep.FIXED_DT
local FLAT_FLOOR: KartSolver.WorldQuery = {
	raycast = function(origin: KartSolver.Vec3, dir: KartSolver.Vec3, length: number): KartSolver.RayHit?
		if dir.y < -0.5 and origin.y >= 0 and origin.y + dir.y * length <= 0 then
			local t = -origin.y / dir.y
			return {
				distance = t,
				point = { x = origin.x + dir.x * t, y = 0, z = origin.z + dir.z * t },
				normal = { x = 0, y = 1, z = 0 },
				materialName = "road.jpg",
			}
		end
		return nil
	end,
}

local function assertNear(actual: number, expected: number, tol: number, label: string)
	if math.abs(actual - expected) > tol then
		error(string.format("%s: expected %.6f +/- %.6f, got %.6f", label, expected, tol, actual))
	end
end

local function makeMovingKart(pos: KartSolver.Vec3, speed: number, yawRad: number?): KartSolver.KartState
	local profile = KartTuning.buildProfile("medium", "best")
	local s = KartSolver.createState(profile, pos, yawRad or 0)
	local _, _, fwd = Math3D.quatBasis(s.rot)
	s.linVel = Math3D.scale(fwd, speed)
	s.prevPos = Math3D.sub(pos, Math3D.scale(fwd, speed * DT))
	s.speed = speed
	s.isOnGround = true
	s.numWheelsOnGround = 4
	return s
end

local function advanceSyntheticState(s: KartSolver.KartState, dt: number)
	s.prevPos = { x = s.pos.x, y = s.pos.y, z = s.pos.z }
	local _, _, fwd = Math3D.quatBasis(s.rot)
	s.linVel = Math3D.scale(fwd, s.speed)
	s.pos = Math3D.add(s.pos, Math3D.scale(s.linVel, dt))
end

local function makeFlatInput(accel: number, steer: number?): KartSolver.KartInput
	return {
		accel = accel,
		brake = false,
		steer = steer or 0,
		drift = false,
		nitro = false,
		fire = false,
		lookBack = false,
	}
end

return {
	{
		name = "region detection: inner 2x, main 1x, outer/outside/vertical gates",
		fn = function()
			-- At target speed = 20 (= baseSpeed), length = 8 m, width = 4 m.
			-- Main quad rear edge: z = -0.7185 - 8 = -8.7185.
			-- Inner quad: innerFactor = 0.5 * sqrt(1) = 0.5 -> length = 4 m, rear z = -0.7185 - 4 = -4.7185.
			-- Outer quad: rear z = -0.7185 - 8 * 1.1 = -9.5185.
			local target = makeMovingKart({ x = 0, y = 0.3, z = 0 }, 20.0)
			local inInner = makeMovingKart({ x = 0, y = 0.3, z = -3.0 }, 20.0)
			local inMain = makeMovingKart({ x = 0, y = 0.3, z = -6.5 }, 20.0)
			local tooFarBack = makeMovingKart({ x = 0, y = 0.3, z = -11.0 }, 20.0)
			local tooFarSide = makeMovingKart({ x = 3.0, y = 0.3, z = -6.5 }, 20.0)
			local ahead = makeMovingKart({ x = 0, y = 0.3, z = 3.0 }, 20.0)
			local tooHigh = makeMovingKart({ x = 0, y = 5.5, z = -3.0 }, 20.0)
			local tooLow = makeMovingKart({ x = 0, y = -1.2, z = -3.0 }, 20.0)

			-- Test each follower in isolation against target so followers do not draft each other
			for idx, follower in { inInner, inMain, tooFarBack, tooFarSide, ahead, tooHigh, tooLow } do
				KartSolver.stepSlipstream({
					{ id = 1, state = target },
					{ id = idx + 1, state = follower },
				}, DT, 1)
			end

			assert(inInner.slipstream.mode == "COLLECT" and inInner.slipstream.inInnerQuad, "expected inner quad")
			assertNear(inInner.slipstream.slipstreamTime, 2 * DT, 1e-9, "inner 2x rate")

			assert(inMain.slipstream.mode == "COLLECT" and not inMain.slipstream.inInnerQuad, "expected main quad")
			assertNear(inMain.slipstream.slipstreamTime, DT, 1e-9, "main 1x rate")

			assert(tooFarBack.slipstream.mode == "NONE", "outside rear edge must not collect")
			assert(tooFarSide.slipstream.mode == "NONE", "outside lateral edge must not collect")
			assert(ahead.slipstream.mode == "NONE", "ahead of target must not collect")
			assert(tooHigh.slipstream.mode == "NONE", "above +5m quad limit must not collect")
			assert(tooLow.slipstream.mode == "NONE", "below -1m quad limit must not collect")
		end,
	},
	{
		name = "misalignment: reversing/low forward speed and velocity-bent wake",
		fn = function()
			-- Follower inside wake but reversing/low forward speed (< 6.0 m/s) -> NONE
			local target = makeMovingKart({ x = 0, y = 0.3, z = 0 }, 20.0)
			local reversing = makeMovingKart({ x = 0, y = 0.3, z = -5.0 }, -10.0)
			KartSolver.stepSlipstream({
				{ id = 1, state = target },
				{ id = 2, state = reversing },
			}, DT, 1)
			assert(reversing.slipstream.mode == "NONE", "reversing follower must not collect")

			-- Target heading +Z but sliding diagonally (+X, +Z) so wake bends toward -X behind target.
			local slidingTarget = makeMovingKart({ x = 0, y = 0.3, z = 0 }, 20.0)
			local stepDist = 20.0 * DT
			local invSqrt2 = 1.0 / math.sqrt(2.0)
			slidingTarget.prevPos = {
				x = -stepDist * invSqrt2,
				y = 0.3,
				z = -stepDist * invSqrt2,
			}
			-- Follower straight behind target (+Z=0, -6.5) falls outside bent wake;
			-- follower in the bent wake (-X, -Z) collects.
			local straightBehind = makeMovingKart({ x = 0, y = 0.3, z = -6.5 }, 20.0)
			local inBentWake = makeMovingKart({ x = -4.5, y = 0.3, z = -5.5 }, 20.0)

			KartSolver.stepSlipstream({
				{ id = 1, state = slidingTarget },
				{ id = 2, state = straightBehind },
				{ id = 3, state = inBentWake },
			}, DT, 1)

			assert(straightBehind.slipstream.mode == "NONE", "straight-back point must miss velocity-bent wake")
			assert(inBentWake.slipstream.mode == "COLLECT", "point inside velocity-bent wake must collect")
		end,
	},
	{
		name = "speed and controller gates (min speed, quad min speed, disableSlipstream, ghost/animation)",
		fn = function()
			local fastTarget = makeMovingKart({ x = 0, y = 0.3, z = 0 }, 20.0)
			local slowCollector = makeMovingKart({ x = 0, y = 0.3, z = -5.0 }, 5.9)
			local easyAI = makeMovingKart({ x = 0, y = 0.3, z = -5.0 }, 20.0)
			KartSolver.stepSlipstream({
				{ id = 1, state = fastTarget },
				{ id = 2, state = slowCollector },
				{ id = 3, state = easyAI, disableSlipstream = true },
			}, DT, 1)
			assert(slowCollector.slipstream.mode == "NONE", "collector < 6.0 m/s must not collect")
			assert(easyAI.slipstream.mode == "NONE", "disableSlipstream must block collection")

			local slowTarget = makeMovingKart({ x = 0, y = 0.3, z = 0 }, 7.9)
			local fastFollower = makeMovingKart({ x = 0, y = 0.3, z = -5.0 }, 20.0)
			local ghostTarget = makeMovingKart({ x = 10, y = 0.3, z = 0 }, 20.0)
			local followerBehindGhost = makeMovingKart({ x = 10, y = 0.3, z = -5.0 }, 20.0)
			local elimTarget = makeMovingKart({ x = 20, y = 0.3, z = 0 }, 20.0)
			local followerBehindElim = makeMovingKart({ x = 20, y = 0.3, z = -5.0 }, 20.0)

			KartSolver.stepSlipstream({
				{ id = 10, state = slowTarget },
				{ id = 11, state = fastFollower },
				{ id = 12, state = ghostTarget, isGhost = true },
				{ id = 13, state = followerBehindGhost },
				{ id = 14, state = elimTarget, isEliminated = true },
				{ id = 15, state = followerBehindElim },
			}, DT, 1)

			assert(fastFollower.slipstream.mode == "NONE", "target < 8.0 m/s must be skipped")
			assert(followerBehindGhost.slipstream.mode == "NONE", "ghost target must be skipped")
			assert(followerBehindElim.slipstream.mode == "NONE", "eliminated target must be skipped")
		end,
	},
	{
		name = "boost timing, magnitude (+3 m/s, +300 N), linear fade-out, outer decay, and stacking",
		fn = function()
			-- Medium profile: durationFactor = 0.8, fadeOutTime = 2.0 s (240 ticks).
			local target = makeMovingKart({ x = 0, y = 0.3, z = 0 }, 20.0)
			local follower = makeMovingKart({ x = 0, y = 0.3, z = -6.0 }, 20.0)
			local participants: { KartSolver.SlipstreamParticipant } = {
				{ id = 1, state = target },
				{ id = 2, state = follower },
			}

			-- Collect for 2.0 s (< 2.5 s minCollectTime) -> exiting must NOT trigger boost.
			for tick = 1, 240 do
				advanceSyntheticState(target, DT)
				advanceSyntheticState(follower, DT)
				KartSolver.stepSlipstream(participants, DT, tick)
			end
			assert(not Slipstream.isReady(follower.slipstream, follower.profile.slipstream), "2.0s < 2.5s not ready")
			follower.pos.x = 10.0 -- pull out
			KartSolver.stepSlipstream(participants, DT, 241)
			assert(not follower.slipstream.bonusActive, "must not boost before minCollectTime")

			-- Reset and collect for 3.0 s (360 ticks) in main quad (> 2.5 s).
			follower = makeMovingKart({ x = 0, y = 0.3, z = -6.0 }, 20.0)
			target = makeMovingKart({ x = 0, y = 0.3, z = 0 }, 20.0)
			participants = {
				{ id = 1, state = target },
				{ id = 2, state = follower },
			}
			for tick = 1, 360 do
				advanceSyntheticState(target, DT)
				advanceSyntheticState(follower, DT)
				KartSolver.stepSlipstream(participants, DT, tick)
			end
			assertNear(follower.slipstream.slipstreamTime, 3.0, 1e-6, "3.0s collected")
			assert(Slipstream.isReady(follower.slipstream, follower.profile.slipstream), "ready > 2.5s")
			assert(not follower.slipstream.bonusActive, "boost must NOT activate while still inside wake")

			-- Exit wake on tick 361: bonusTime = 3.0 * 0.8 = 2.4 s = 288 ticks.
			local preExitSpeed = follower.speed
			advanceSyntheticState(target, DT)
			follower.prevPos = { x = follower.pos.x, y = follower.pos.y, z = follower.pos.z }
			follower.pos = { x = follower.pos.x + 8.0, y = follower.pos.y, z = follower.pos.z + 20.0 * DT }
			local triggered = KartSolver.stepSlipstream(participants, DT, 361)
			assert(triggered == 1, "expected 1 boost trigger on wake exit")
			assert(follower.slipstream.bonusActive, "bonusActive on exit")
			assertNear(follower.speed, preExitSpeed + 3.0, 1e-6, "instant +3.0 m/s speed kick")

			local ssInc = follower.maxSpeedState.increases["SLIPSTREAM"]
			assert(ssInc.active, "SLIPSTREAM MaxSpeed entry active")
			assertNear(ssInc.maxAddSpeed, 3.0, 1e-6, "maxAddSpeed")
			assertNear(ssInc.engineForce, 300.0, 1e-6, "addPower")
			local expectedDurTicks = FixedStep.timeToTicks(follower.slipstream.bonusTime)
			assert(ssInc.durationTicks == expectedDurTicks, "durationTicks matches bonusTime")
			assert(ssInc.durationTicks >= 287 and ssInc.durationTicks <= 288, "durationTicks ~ 2.4s")
			assert(ssInc.fadeOutTicks == 240, "fadeOutTicks == 240")
			assertNear(follower.maxSpeedState.additionalEngineForce, 300.0, 1e-6, "additionalEngineForce during hold")
			assertNear(follower.maxSpeedState.currentMaxSpeed, follower.profile.maxSpeed + 3.0, 1e-6, "maxSpeed +3")

			-- Step (expectedDurTicks - 1) ticks -> still 1 tick left in hold; then 1 tick -> durationTicks == 0 (fade starts).
			MaxSpeed.update(follower.maxSpeedState, expectedDurTicks - 1, true)
			assert(ssInc.durationTicks == 1, "expected 1 hold tick remaining")
			assertNear(follower.maxSpeedState.additionalEngineForce, 300.0, 1e-6, "engineForce still active at dur=1")
			MaxSpeed.update(follower.maxSpeedState, 1, true)
			assert(ssInc.durationTicks == 0, "expected dur=0 at fade start")
			assertNear(follower.maxSpeedState.additionalEngineForce, 0.0, 1e-6, "engineForce drops to 0 on fade")
			assertNear(ssInc.currentSpeedup, 3.0, 1e-6, "speedup starts at 3.0 at fade start")

			-- Halfway through 240-tick fade-out: 120 ticks -> ~1.5 m/s.
			MaxSpeed.update(follower.maxSpeedState, 120, true)
			assertNear(ssInc.currentSpeedup, 1.5, 1e-6, "linear fade midpoint")

			-- Exact expiry: 120 ticks hits -240 (still active=true, ratio=1 -> 0); +1 tick (< -240) deactivates.
			MaxSpeed.update(follower.maxSpeedState, 121, true)
			assert(not ssInc.active, "SLIPSTREAM entry expired after fadeOutTicks")
			assertNear(ssInc.currentSpeedup, 0.0, 1e-6, "speedup 0 after expiry")
			assertNear(
				follower.maxSpeedState.currentMaxSpeed,
				follower.profile.maxSpeed,
				1e-6,
				"base maxSpeed restored"
			)
		end,
	},
	{
		name = "outer quad decays at 1x vs 3x outside, and maxCollectTime clamps at 8.0s",
		fn = function()
			-- At speed=20: main rear z = -8.7185, outer rear z = -9.5185.
			local target = makeMovingKart({ x = 0, y = 0.3, z = 0 }, 20.0)
			local follower = makeMovingKart({ x = 0, y = 0.3, z = -6.0 }, 20.0)
			local participants: { KartSolver.SlipstreamParticipant } = {
				{ id = 1, state = target },
				{ id = 2, state = follower },
			}

			-- Collect 10s in inner quad -> clamped to 8.0 s.
			follower.pos.z = -3.0
			for tick = 1, 1200 do
				advanceSyntheticState(target, DT)
				advanceSyntheticState(follower, DT)
				KartSolver.stepSlipstream(participants, DT, tick)
			end
			assertNear(follower.slipstream.slipstreamTime, 8.0, 1e-6, "clamped at maxCollectTime=8.0s")

			-- Move to outer quad (z = target.pos.z - 9.1): decays at 1*dt.
			-- Note: since slipstreamTime > 2.5 and currentTargetId changed to nil, reset bonus first or test decay < 2.5s.
			follower.slipstream.chargeTicks = 240
			follower.slipstream.slipstreamTime = 2.0
			follower.slipstream.mode = "COLLECT"
			follower.slipstream.currentTargetId = 1
			follower.pos.z = target.pos.z - 9.1
			follower.prevPos = { x = follower.pos.x, y = follower.pos.y, z = follower.pos.z - 20.0 * DT }
			KartSolver.stepSlipstream(participants, DT, 1201)
			assert(follower.slipstream.inOuterQuad, "expected outer quad")
			assertNear(follower.slipstream.slipstreamTime, 2.0 - DT, 1e-6, "outer quad decays at 1*dt")

			-- Move completely outside (z = target.pos.z - 20): decays at 3*dt.
			follower.pos.z = target.pos.z - 20.0
			follower.prevPos = { x = follower.pos.x, y = follower.pos.y, z = follower.pos.z - 20.0 * DT }
			KartSolver.stepSlipstream(participants, DT, 1202)
			assertNear(follower.slipstream.slipstreamTime, 2.0 - 4 * DT, 1e-6, "outside decays at 3*dt")
		end,
	},
	{
		name = "bit-identical capture/restore/replay across NetState and GreyboxProtocol snapshot",
		fn = function()
			local prof = KartTuning.buildProfile("medium", "best")
			local lead = KartSolver.createState(prof, { x = 0, y = 0.30, z = 0 }, 0)
			local chase = KartSolver.createState(prof, { x = 0, y = 0.30, z = -5.0 }, 0)

			-- Accelerate both karts together so chase collects inside lead's wake.
			for tick = 1, 420 do
				KartSolver.step(lead, makeFlatInput(1.0, 0), FLAT_FLOOR, DT)
				KartSolver.step(chase, makeFlatInput(1.0, 0), FLAT_FLOOR, DT)
				KartSolver.stepSlipstream({
					{ id = -1, state = lead },
					{ id = 100, state = chase },
				}, DT, tick)
			end
			assert(chase.slipstream.mode == "COLLECT", "expected active collection before capture")

			-- Capture chase via NetState + GreyboxProtocol buffer round-trip.
			local leadSnap = KartSolver.captureNetState(lead, nil, nil)
			local chaseSnap = KartSolver.captureNetState(chase, nil, nil)
			local buf, _ = GreyboxProtocol.packSnapshot(420, 420, 0, chaseSnap, "", nil, 3.5)
			local pkt = GreyboxProtocol.unpackSnapshot(buf, nil)
			assert(pkt ~= nil, "unpackSnapshot failed")

			local leadClone = KartSolver.createState(prof)
			local chaseClone = KartSolver.createState(prof)
			KartSolver.applyNetState(leadClone, leadSnap, nil, nil)
			KartSolver.applyNetState(chaseClone, (pkt :: GreyboxProtocol.TelemetryPacket).netState, nil, nil)

			-- Replay 360 ticks including steering out of wake -> boost trigger -> partial fade.
			for tick = 421, 780 do
				local steer = if tick >= 460 and tick <= 500 then 0.5 else 0.0
				KartSolver.step(lead, makeFlatInput(1.0, 0), FLAT_FLOOR, DT)
				KartSolver.step(chase, makeFlatInput(1.0, steer), FLAT_FLOOR, DT)
				KartSolver.stepSlipstream({
					{ id = -1, state = lead },
					{ id = 100, state = chase },
				}, DT, tick)

				KartSolver.step(leadClone, makeFlatInput(1.0, 0), FLAT_FLOOR, DT)
				KartSolver.step(chaseClone, makeFlatInput(1.0, steer), FLAT_FLOOR, DT)
				KartSolver.stepSlipstream({
					{ id = -1, state = leadClone },
					{ id = 100, state = chaseClone },
				}, DT, tick)
			end

			assert(chase.pos.x == chaseClone.pos.x, "pos.x mismatch")
			assert(chase.pos.y == chaseClone.pos.y, "pos.y mismatch")
			assert(chase.pos.z == chaseClone.pos.z, "pos.z mismatch")
			assert(chase.linVel.x == chaseClone.linVel.x, "linVel.x mismatch")
			assert(chase.linVel.z == chaseClone.linVel.z, "linVel.z mismatch")
			assert(chase.speed == chaseClone.speed, "speed mismatch")
			assert(chase.slipstream.chargeTicks == chaseClone.slipstream.chargeTicks, "chargeTicks mismatch")
			assert(chase.slipstream.inZone == chaseClone.slipstream.inZone, "inZone mismatch")
			assert(chase.slipstream.slipstreamTime == chaseClone.slipstream.slipstreamTime, "slipstreamTime mismatch")
			assert(chase.slipstream.bonusTime == chaseClone.slipstream.bonusTime, "bonusTime mismatch")
			assert(
				chase.maxSpeedState.increases["SLIPSTREAM"].currentSpeedup
					== chaseClone.maxSpeedState.increases["SLIPSTREAM"].currentSpeedup,
				"SLIPSTREAM speedup mismatch"
			)
		end,
	},
	{
		name = "pair-order independence across all 3-kart input permutations (including id -1)",
		fn = function()
			local perms = {
				{ 1, 2, 3 },
				{ 1, 3, 2 },
				{ 2, 1, 3 },
				{ 2, 3, 1 },
				{ 3, 1, 2 },
				{ 3, 2, 1 },
			}
			local refResults: { { speed: number, time: number, targetId: number? } } = {}

			for pIdx, perm in perms do
				local k1 = makeMovingKart({ x = 0, y = 0.3, z = 0 }, 20.0)
				local k2 = makeMovingKart({ x = 0, y = 0.3, z = -3.0 }, 20.0)
				local k3 = makeMovingKart({ x = 0, y = 0.3, z = -6.5 }, 20.0)
				local baseList: { KartSolver.SlipstreamParticipant } = {
					{ id = -1, state = k1 },
					{ id = 10, state = k2 },
					{ id = 20, state = k3 },
				}
				local ordered: { KartSolver.SlipstreamParticipant } = {
					baseList[perm[1]],
					baseList[perm[2]],
					baseList[perm[3]],
				}

				for tick = 1, 120 do
					advanceSyntheticState(k1, DT)
					advanceSyntheticState(k2, DT)
					advanceSyntheticState(k3, DT)
					KartSolver.stepSlipstream(ordered, DT, tick)
				end

				local snap = {
					{ speed = k1.speed, time = k1.slipstream.slipstreamTime, targetId = k1.slipstream.currentTargetId },
					{ speed = k2.speed, time = k2.slipstream.slipstreamTime, targetId = k2.slipstream.currentTargetId },
					{ speed = k3.speed, time = k3.slipstream.slipstreamTime, targetId = k3.slipstream.currentTargetId },
				}
				if pIdx == 1 then
					refResults = snap
				else
					for k = 1, 3 do
						assert(snap[k].speed == refResults[k].speed, "perm speed mismatch")
						assert(snap[k].time == refResults[k].time, "perm time mismatch")
						assert(snap[k].targetId == refResults[k].targetId, "perm targetId mismatch")
					end
				end
			end
		end,
	},
	{
		name = "SlipstreamVfxMath two-state charge: CHARGING (white) -> CHARGED (yellow) -> NONE on exit",
		fn = function()
			local idle = SlipstreamVfxMath.evaluate({
				inZone = false,
				chargeTicks = 0,
				minCollectTicks = 300,
			})
			assert(not idle.enabled and idle.stage == "NONE", "idle must disable emitter")

			local cEarly = SlipstreamVfxMath.evaluate({
				inZone = true,
				chargeTicks = 60,
				minCollectTicks = 300,
			})
			local cMid = SlipstreamVfxMath.evaluate({
				inZone = true,
				chargeTicks = 240,
				minCollectTicks = 300,
			})
			local cReady = SlipstreamVfxMath.evaluate({
				inZone = true,
				chargeTicks = 301,
				minCollectTicks = 300,
			})
			assert(cEarly.enabled and cEarly.stage == "CHARGING", "early collect")
			assert(cEarly.colorR == 255 and cEarly.colorG == 255 and cEarly.colorB == 255, "charging is white")
			assert(cMid.enabled and cMid.stage == "CHARGING" and cMid.intensity > cEarly.intensity, "collect ramps")
			assert(cReady.enabled and cReady.stage == "CHARGED" and cReady.rate > cMid.rate, "charged ramps rate")
			assert(cReady.colorR == 255 and cReady.colorG == 208 and cReady.colorB == 41, "charged is yellow")

			local postExit = SlipstreamVfxMath.evaluate({
				inZone = false,
				chargeTicks = 0,
				minCollectTicks = 300,
			})
			assert(not postExit.enabled and postExit.stage == "NONE", "post-exit boost must disable streaks")
		end,
	},
	{
		name = "RemoteKartState slipstreamTime/BonusTime round-trip via GreyboxProtocol + 2/20-kart bench",
		fn = function()
			local prof = KartTuning.buildProfile("medium", "best")
			local s = KartSolver.createState(prof, { x = 0, y = 0.3, z = 0 }, 0)
			local ns = KartSolver.captureNetState(s, nil, nil)
			local remotes: { GreyboxProtocol.RemoteKartState } = {
				{
					id = "Dummy_1",
					pos = { 1, 0.3, 2 },
					rot = { 1, 0, 0, 0 },
					linVel = { 0, 0, 16 },
					speed = 16,
					steer = 0,
					attachmentType = 0,
					plungerFaceTicks = 0,
					timedImpulseTicks = 0,
					isSquashed = false,
					rank = 1,
					lap = 0,
					trackNodeIdx = 1,
					slipstreamTime = 3.2,
					slipstreamBonusTime = 1.6,
				},
			}
			local buf, _ = GreyboxProtocol.packSnapshot(10, 10, 0, ns, "", remotes, 1.0)
			local pkt = GreyboxProtocol.unpackSnapshot(buf, nil)
			assert(pkt ~= nil and pkt.remoteKarts ~= nil and #pkt.remoteKarts == 1, "expected remoteKart")
			local rk = (pkt.remoteKarts :: { GreyboxProtocol.RemoteKartState })[1]
			assertNear(rk.slipstreamTime or 0, 3.2, 0.04, "remote slipstreamTime quantized round-trip")
			assertNear(rk.slipstreamBonusTime or 0, 1.6, 0.04, "remote slipstreamBonusTime quantized round-trip")

			local function benchKarts(count: number, iters: number): number
				local parts: { KartSolver.SlipstreamParticipant } = {}
				for i = 1, count do
					local ks = makeMovingKart({ x = 0, y = 0.3, z = -i * 3.5 }, 20.0)
					table.insert(parts, { id = i, state = ks })
				end
				local t0 = os.clock()
				for tick = 1, iters do
					for _, p in parts do
						advanceSyntheticState(p.state, DT)
						SlipstreamVfxMath.evaluate({
							inZone = p.state.slipstream.inZone,
							chargeTicks = p.state.slipstream.chargeTicks,
							minCollectTicks = FixedStep.timeToTicks(p.state.profile.slipstream.minCollectTime),
						})
					end
					KartSolver.stepSlipstream(parts, DT, tick)
				end
				return (os.clock() - t0) * 1e6 / iters
			end
			local us2 = benchKarts(2, 500)
			local us20 = benchKarts(20, 200)
			print(string.format("[Slipstream Bench] 2-kart=%.1f us/tick | 20-kart=%.1f us/tick", us2, us20))
			assert(us20 < 2000, "20-kart slipstream+VFX math must stay well under 2ms/tick")
		end,
	},
}
