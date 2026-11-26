--!strict
-- tests/RaceFlow.spec.luau
-- SPDX-License-Identifier: GPL-3.0-or-later

local AIController = require("../src/shared/ai/AIController")
local CheckManager = require("../src/shared/race/CheckManager")
local FixedStep = require("../src/shared/sim/FixedStep")
local GreyboxProtocol = require("../src/shared/net/GreyboxProtocol")
local KartSolver = require("../src/shared/sim/KartSolver")
local KartTuning = require("../src/shared/KartTuning")
local RaceState = require("../src/shared/sim/RaceState")
local SandtrackData = require("../src/shared/track/SandtrackData")

local function assertTrue(cond: boolean, msg: string)
	if not cond then
		error(msg, 2)
	end
end

local function assertNear(actual: number, expected: number, eps: number, msg: string)
	if math.abs(actual - expected) > eps then
		error(string.format("%s: expected %.6f, got %.6f (eps=%.6f)", msg, expected, actual, eps), 2)
	end
end

local function makeFlatWorldQuery(groundY: number?): KartSolver.WorldQuery
	local yFloor = groundY or 0.0
	return {
		raycast = function(origin, dir, length)
			if dir.y >= -1e-6 then
				return nil
			end
			local t = (yFloor - origin.y) / dir.y
			if t < 0 or t > length then
				return nil
			end
			return {
				distance = t,
				point = { x = origin.x + dir.x * t, y = yFloor, z = origin.z + dir.z * t },
				normal = { x = 0, y = 1, z = 0 },
				highTireAdhesion = false,
				surfaceGrip = 1.0,
				materialName = "road.jpg",
			}
		end,
	}
end

local tests = {}

table.insert(tests, {
	name = "Phase transitions occur at exact cited 120 Hz ticks",
	fn = function()
		local clock = RaceState.create()
		assertTrue(clock.totalLaps == 5, "default laps should be 5")
		assertTrue(clock.phase == "COUNTDOWN_3", "tick 0 is COUNTDOWN_3")
		assertTrue(RaceState.getCountdownText(clock.phase) == "3", "tick 0 text is 3")
		assertTrue(not RaceState.isThrottleAllowed(clock.phase), "throttle blocked in COUNTDOWN_3")
		assertTrue(not RaceState.isSteeringAllowed(clock.phase), "steering blocked in COUNTDOWN_3")

		for _ = 1, 119 do
			RaceState.step(clock)
		end
		assertTrue(clock.raceTick == 119 and clock.phase == "COUNTDOWN_3", "tick 119 still COUNTDOWN_3")

		RaceState.step(clock)
		assertTrue(clock.raceTick == 120 and clock.phase == "READY_PHASE", "tick 120 enters READY_PHASE")
		assertTrue(RaceState.getCountdownText(clock.phase) == "2", "READY_PHASE text is 2")

		for _ = 1, 120 do
			RaceState.step(clock)
		end
		assertTrue(clock.raceTick == 240 and clock.phase == "SET_PHASE", "tick 240 enters SET_PHASE")
		assertTrue(RaceState.getCountdownText(clock.phase) == "1", "SET_PHASE text is 1")

		for _ = 1, 120 do
			RaceState.step(clock)
		end
		assertTrue(clock.raceTick == 360 and clock.phase == "GO_PHASE", "tick 360 enters GO_PHASE")
		assertTrue(RaceState.getCountdownText(clock.phase) == "GO!", "GO_PHASE text is GO!")
		assertTrue(RaceState.isThrottleAllowed(clock.phase), "throttle allowed at GO")
		assertTrue(RaceState.isSteeringAllowed(clock.phase), "steering allowed at GO")

		for _ = 1, 120 do
			RaceState.step(clock)
		end
		assertTrue(clock.raceTick == 480 and clock.phase == "MUSIC_PHASE", "tick 480 enters MUSIC_PHASE")

		for _ = 1, 840 do
			RaceState.step(clock)
		end
		assertTrue(clock.raceTick == 1320 and clock.phase == "RACE_PHASE", "tick 1320 enters RACE_PHASE")

		RaceState.enterDelayFinish(clock)
		assertTrue(clock.phase == "DELAY_FINISH_PHASE", "enterDelayFinish switches to DELAY_FINISH_PHASE")
		for _ = 1, 121 do
			RaceState.step(clock)
		end
		assertTrue(clock.phase == "RESULT_DISPLAY_PHASE", "121 ticks after finish enters RESULT_DISPLAY_PHASE")
	end,
})

table.insert(tests, {
	name = "Countdown zeroes input without skipping KartSolver.step so suspension settles",
	fn = function()
		local prof = KartTuning.buildProfile("medium", "best")
		local state = KartSolver.createState(prof, { x = 0, y = 0.65, z = 0 }, 0)
		local wq = makeFlatWorldQuery(0.0)
		local clock = RaceState.create()
		local fullInput: KartSolver.KartInput = {
			accel = 1.0,
			brake = false,
			steer = 1.0,
			drift = true,
			nitro = false,
			fire = false,
		}

		for _ = 1, 359 do
			local phase = RaceState.step(clock)
			local filtered = KartSolver.stepRaceInput(state, fullInput, clock.raceTick, phase)
			assertNear(filtered.accel, 0.0, 1e-6, "countdown accel must be 0")
			assertNear(filtered.steer, 0.0, 1e-6, "countdown steer must be 0")
			KartSolver.step(state, filtered, wq, FixedStep.FIXED_DT)
		end

		assertTrue(state.numWheelsOnGround == 4, "all 4 wheels settled on ground during countdown")
		assertNear(state.speed, 0.0, 0.05, "kart remains stationary during countdown")
		local yBeforeGo = state.pos.y

		local goPhase = RaceState.step(clock)
		assertTrue(goPhase == "GO_PHASE", "tick 360 is GO_PHASE")
		local goFiltered = KartSolver.stepRaceInput(state, fullInput, clock.raceTick, goPhase)
		KartSolver.step(state, goFiltered, wq, FixedStep.FIXED_DT)
		assertNear(state.pos.y, yBeforeGo, 0.02, "no vertical sink/snap on GO transition")
	end,
})

table.insert(tests, {
	name = "Start bonus granted inside SET_PHASE window and denied outside / penalized on early press",
	fn = function()
		local prof = KartTuning.buildProfile("medium", "best")
		local wq = makeFlatWorldQuery(0.0)

		-- Tier 1: press at SET_PHASE tick 240 (0.0s) and tick 276 (0.3s)
		local ok0, boost0 = RaceState.isInStartBonusWindow(240, prof)
		assertTrue(ok0, "tick 240 in window")
		assertNear(boost0, 8.0 * 0.8, 1e-4, "medium tier 1 boost")

		local ok30, boost30 = RaceState.isInStartBonusWindow(276, prof)
		assertTrue(ok30, "tick 276 (0.3s) in tier 1 window")
		assertNear(boost30, 8.0 * 0.8, 1e-4, "medium tier 1 boundary boost")

		-- Tier 2: press at tick 277 (0.308s) and tick 300 (0.5s)
		local ok31, boost31 = RaceState.isInStartBonusWindow(277, prof)
		assertTrue(ok31, "tick 277 in tier 2 window")
		assertNear(boost31, 4.0 * 0.8, 1e-4, "medium tier 2 boost")

		local ok50, boost50 = RaceState.isInStartBonusWindow(300, prof)
		assertTrue(ok50, "tick 300 (0.5s) in tier 2 window")
		assertNear(boost50, 4.0 * 0.8, 1e-4, "medium tier 2 boundary boost")

		-- Outside window: tick 301 (> 0.5s) and tick 360 (at GO)
		local okLate, boostLate = RaceState.isInStartBonusWindow(301, prof)
		assertTrue(not okLate and boostLate == 0.0, "tick 301 denied start boost")
		local okGo, boostGo = RaceState.isInStartBonusWindow(360, prof)
		assertTrue(not okGo and boostGo == 0.0, "tick 360 denied start boost")

		-- Full solver check: tier 1 press fires ZIPPER boost on GO tick 360
		local sGood = KartSolver.createState(prof, { x = 0, y = 0.35, z = 0 }, 0)
		local idle: KartSolver.KartInput = { accel = 0, brake = false, steer = 0, drift = false }
		local goInput: KartSolver.KartInput = { accel = 1, brake = false, steer = 0, drift = false }
		for t = 1, 359 do
			local p = RaceState.phaseAtTick(t, nil)
			local inp = if t >= 250 then goInput else idle
			local f = KartSolver.stepRaceInput(sGood, inp, t, p)
			KartSolver.step(sGood, f, wq, FixedStep.FIXED_DT)
		end
		local fGo = KartSolver.stepRaceInput(sGood, goInput, 360, "GO_PHASE")
		KartSolver.step(sGood, fGo, wq, FixedStep.FIXED_DT)
		assertTrue(sGood.race.startupBoostFired, "startupBoostFired set on GO")
		assertTrue(sGood.maxSpeedState.increases["ZIPPER"].active, "ZIPPER MaxSpeed active on GO")
		assertTrue(sGood.speed >= 5.5, "kart receives immediate speed surge on GO")

		-- Early press in READY_PHASE (tick 150) triggers 120-tick penalty after GO
		local sEarly = KartSolver.createState(prof, { x = 0, y = 0.35, z = 0 }, 0)
		for t = 1, 359 do
			local p = RaceState.phaseAtTick(t, nil)
			local inp = if t == 150 then goInput else idle
			local f = KartSolver.stepRaceInput(sEarly, inp, t, p)
			KartSolver.step(sEarly, f, wq, FixedStep.FIXED_DT)
		end
		assertTrue(sEarly.race.startupBoostMps == 0.0, "early press gets 0 boost")
		assertTrue(sEarly.race.startupPenaltyTicks == 120, "early press gets 120-tick penalty")
		local fPen = KartSolver.stepRaceInput(sEarly, goInput, 360, "GO_PHASE")
		assertNear(fPen.accel, 0.0, 1e-6, "early-press penalty zeroes throttle on GO")
	end,
})

table.insert(tests, {
	name = "Ordered Sandtrack checkpoints enforce sequence, 5 laps, and temple shortcut",
	fn = function()
		local chks = SandtrackData.checkpoints :: any
		local slot0 = SandtrackData.startTransforms[1]
		local prog = CheckManager.initKartProgress(chks, slot0.pos, slot0.yawRad)
		assertTrue(prog.lap == -1 and prog.nextCheckpoint == 0, "spawns behind start line: lap=-1 next=0")

		-- Cross start line: lap -1 -> 0, nextCheckpoint 0 -> 1
		local _, lapInc0, _ = CheckManager.stepKart(
			prog,
			chks,
			{ x = 1.0, y = -140.0, z = 6.0 },
			{ x = 1.0, y = -140.0, z = 10.0 },
			370,
			5
		)
		assertTrue(lapInc0 and prog.lap == 0 and prog.nextCheckpoint == 1, "first crossing starts lap 1 (lap=0)")

		-- Repeatedly crossing start line without checkpoints 1..4 must NOT increment lap
		local chgRepeat, lapIncRepeat, _ = CheckManager.stepKart(
			prog,
			chks,
			{ x = 1.0, y = -140.0, z = 6.0 },
			{ x = 1.0, y = -140.0, z = 10.0 },
			400,
			5
		)
		assertTrue(not chgRepeat and not lapIncRepeat and prog.lap == 0, "re-crossing start without 1..4 ignored")

		-- Skipping check 2 (crossing check 3 directly) must NOT advance nextCheckpoint
		local chgSkip, _, _ = CheckManager.stepKart(
			prog,
			chks,
			{ x = -270.0, y = -153.0, z = -70.0 },
			{ x = -255.0, y = -153.0, z = -64.0 },
			500,
			5
		)
		assertTrue(not chgSkip and prog.nextCheckpoint == 1, "skipping check 2 does not advance")

		-- Complete 5 full ordered laps via driveline + temple shortcut branch (148 -> 257..302 -> 207)
		local mainPts = SandtrackData.drivelineQuadCenters
		local shortcut = SandtrackData.drivelineBranches[1]
		local route: { { x: number, y: number, z: number } } = {}
		for i = 1, 148 do
			table.insert(route, { x = mainPts[i].x, y = -140.0, z = mainPts[i].z })
		end
		for _, bp in shortcut.points do
			table.insert(route, { x = bp.x, y = -140.0, z = bp.z })
		end
		for i = 207, #mainPts do
			table.insert(route, { x = mainPts[i].x, y = -140.0, z = mainPts[i].z })
		end
		--Adjust Y around check 3 (-153) & check 4 (-136) by using midpoint Y of nearest check or flat -140?
		-- Check 3 is at y=-153, check 4 at y=-136: use per-point Y interpolated to hit within [-1,+4]m vertical band!
		for idx, pt in route do
			if pt.x < -200 then
				route[idx] = { x = pt.x, y = -153.0, z = pt.z }
			elseif pt.z < -100 and pt.x > -80 then
				route[idx] = { x = pt.x, y = -136.0, z = pt.z }
			end
		end

		local simProg = CheckManager.initKartProgress(chks, slot0.pos, slot0.yawRad)
		local prev = { x = slot0.pos.x, y = -140.0, z = slot0.pos.z }
		local tick = 370
		for lapIter = 1, 5 do
			for _, pt in route do
				tick += 10
				CheckManager.stepKart(simProg, chks, prev, pt, tick, 5)
				prev = pt
			end
			-- Close loop back across start line (quad 256 -> quad 1)
			tick += 10
			local finishLineEnd = { x = 1.37, y = -140.4, z = 11.15 }
			CheckManager.stepKart(simProg, chks, { x = 1.0, y = -140.4, z = 6.0 }, finishLineEnd, tick, 5)
			prev = finishLineEnd
			if lapIter < 5 then
				assertTrue(not simProg.raceFinished, "not finished before lap 5")
			end
		end
		assertTrue(simProg.lap == 5 and simProg.raceFinished, "temple shortcut completes all 5 laps cleanly")
		assertTrue(simProg.finishTick > 370, "finishTick recorded")
	end,
})

table.insert(tests, {
	name = "Post-finish coasting zeroes throttle and steers along driveline without freezing",
	fn = function()
		local prof = KartTuning.buildProfile("medium", "best")
		local pts = SandtrackData.drivelineQuadCenters
		local state = KartSolver.createState(prof, { x = pts[1].x, y = 0.35, z = pts[1].z }, 0.0)
		state.linVel = { x = 0, y = 0, z = 20.0 }
		state.speed = 20.0
		state.race.raceFinished = true
		state.race.finishTick = 5000
		local ai = AIController.createState(pts, state.pos)
		local wq = makeFlatWorldQuery(0.0)

		for _ = 1, 120 do
			local coastIn = AIController.computeCoastInput(ai, state, pts, FixedStep.FIXED_DT)
			assertNear(coastIn.accel, 0.0, 1e-6, "coast accel must be 0")
			assertTrue(not coastIn.brake, "coast brake must be false")
			KartSolver.step(state, coastIn, wq, FixedStep.FIXED_DT)
		end

		assertTrue(
			state.speed < 20.0 and state.speed > 5.0,
			"kart coasts smoothly rather than freezing or accelerating"
		)
	end,
})

table.insert(tests, {
	name = "Race, lap, checkpoint, and start-bonus state survive capture/pack/unpack/apply/replay identically",
	fn = function()
		local prof = KartTuning.buildProfile("medium", "best")
		local wq = makeFlatWorldQuery(0.0)
		local state = KartSolver.createState(prof, { x = 0, y = 0.35, z = 0 }, 0)
		state.race = {
			raceTick = 412,
			phase = "GO_PHASE",
			lap = 2,
			nextCheckpoint = 3,
			raceFinished = false,
			finishTick = -1,
			startupHasPressed = true,
			startupBoostMps = 6.4,
			startupPenaltyTicks = 0,
			startupBoostFired = true,
		}

		local ns = KartSolver.captureNetState(state, nil, nil)
		local buf, _ = GreyboxProtocol.packSnapshot(412, 99, 1, ns, "", nil, 12.5)
		assertTrue(buffer.len(buf) < 900, string.format("snapshot size %d exceeds 900B limit", buffer.len(buf)))

		local unpacked = GreyboxProtocol.unpackSnapshot(buf, nil)
		assertTrue(unpacked ~= nil, "unpackSnapshot succeeded")
		local r = (unpacked :: GreyboxProtocol.TelemetryPacket).netState.race
		assertTrue(r ~= nil, "unpacked race state present")
		local rr = r :: KartSolver.KartRaceState
		assertTrue(rr.raceTick == 412 and rr.phase == "GO_PHASE", "raceTick & phase round-tripped")
		assertTrue(rr.lap == 2 and rr.nextCheckpoint == 3, "lap & nextCheckpoint round-tripped")
		assertTrue(rr.startupBoostFired and math.abs(rr.startupBoostMps - 6.4) < 1e-4, "start boost round-tripped")

		local clone = KartSolver.createState(prof, { x = 0, y = 0.35, z = 0 }, 0)
		KartSolver.applyNetState(clone, (unpacked :: GreyboxProtocol.TelemetryPacket).netState, nil, nil)
		local inp: KartSolver.KartInput = { accel = 1, brake = false, steer = 0.2, drift = false }
		for i = 1, 60 do
			local t = 412 + i
			local ph = RaceState.phaseAtTick(t, nil)
			local f1 = KartSolver.stepRaceInput(state, inp, t, ph)
			local f2 = KartSolver.stepRaceInput(clone, inp, t, ph)
			KartSolver.step(state, f1, wq, FixedStep.FIXED_DT)
			KartSolver.step(clone, f2, wq, FixedStep.FIXED_DT)
		end
		assertNear(clone.pos.x, state.pos.x, 1e-6, "replayed pos.x identical")
		assertNear(clone.pos.z, state.pos.z, 1e-6, "replayed pos.z identical")
		assertNear(clone.speed, state.speed, 1e-6, "replayed speed identical")
	end,
})

return tests
