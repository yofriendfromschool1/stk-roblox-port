--!strict
-- tests/AIRoutes.spec.luau
-- SPDX-License-Identifier: GPL-3.0-or-later

local AIController = require("../src/shared/ai/AIController")
local CheckManager = require("../src/shared/race/CheckManager")
local GreyboxProtocol = require("../src/shared/net/GreyboxProtocol")
local KartSolver = require("../src/shared/sim/KartSolver")
local KartTuning = require("../src/shared/KartTuning")
local SandtrackData = require("../src/shared/track/SandtrackData")

local function assertTrue(cond: boolean, msg: string)
	if not cond then
		error(msg, 2)
	end
end

local tests = {}

table.insert(tests, {
	name = "route choice and rngState survive capture/pack/unpack/apply/replay bit-identically",
	fn = function()
		local prof = KartTuning.buildProfile("medium", "best")
		local pts = SandtrackData.drivelineQuadCenters
		local branches = SandtrackData.drivelineBranches :: any
		local s1 = KartSolver.createState(
			prof,
			SandtrackData.startTransforms[2].pos,
			SandtrackData.startTransforms[2].yawRad,
			424242
		)
		local ai1 = AIController.createState(pts, s1.pos, 424242, branches, "best")

		local netKart = KartSolver.captureNetState(s1)
		local packed, _ = GreyboxProtocol.packSnapshot(1, 0, 1, netKart, "")
		local unpacked = GreyboxProtocol.unpackSnapshot(packed, nil)
		assertTrue(unpacked ~= nil, "unpackSnapshot failed")
		local netAI = AIController.captureNet(ai1)

		local s2 = KartSolver.createState(
			prof,
			SandtrackData.startTransforms[2].pos,
			SandtrackData.startTransforms[2].yawRad,
			999999
		)
		KartSolver.applyNetState(s2, (unpacked :: GreyboxProtocol.TelemetryPacket).netState)
		local ai2 = AIController.createState(pts, s2.pos, 999999, branches, "best")
		AIController.applyNet(ai2, netAI)

		assertTrue(s1.rngState == s2.rngState, "KartState.rngState mismatch after protocol round-trip")
		assertTrue(ai1.lateralOffsetM == ai2.lateralOffsetM, "lateralOffsetM mismatch")
		assertTrue(ai1.plannedShortcut == ai2.plannedShortcut, "plannedShortcut mismatch")

		-- Replay 120 ticks identically
		for _ = 1, 120 do
			local in1 = AIController.computeInput(ai1, s1, pts, 1 / 120, nil, { difficulty = "best" }, branches)
			local in2 = AIController.computeInput(ai2, s2, pts, 1 / 120, nil, { difficulty = "best" }, branches)
			assertTrue(math.abs(in1.steer - in2.steer) < 1e-12, "replayed steer diverged")
			assertTrue(in1.accel == in2.accel and in1.drift == in2.drift, "replayed input flags diverged")
		end
		assertTrue(s1.rngState == s2.rngState, "post-replay rngState diverged")
	end,
})

table.insert(tests, {
	name = "different seeds yield different routes and distinct lateral offsets",
	fn = function()
		local pts = SandtrackData.drivelineQuadCenters
		local branches = SandtrackData.drivelineBranches :: any
		local sawMain = false
		local sawShortcut = false
		local offsets: { [string]: boolean } = {}
		for i = 1, 30 do
			local seed = 10007 + i * 7919
			local ai =
				AIController.createState(pts, SandtrackData.startTransforms[2].pos, seed, branches, "intermediate")
			if ai.plannedShortcut then
				sawShortcut = true
			else
				sawMain = true
			end
			offsets[string.format("%.4f", ai.lateralOffsetM)] = true
		end
		assertTrue(sawMain and sawShortcut, "expected both MAIN and SHORTCUT routes across seeds")
		local uniqueOffsets = 0
		for _ in pairs(offsets) do
			uniqueOffsets += 1
		end
		assertTrue(uniqueOffsets >= 20, "expected distinct lateral offsets across seeds")
	end,
})

table.insert(tests, {
	name = "difficulty shifts shortcut frequency measurably across 1000 samples",
	fn = function()
		local pts = SandtrackData.drivelineQuadCenters
		local branches = SandtrackData.drivelineBranches :: any
		local function measure(diff: string): number
			local count = 0
			for i = 1, 1000 do
				local ai =
					AIController.createState(pts, SandtrackData.startTransforms[2].pos, 5000 + i * 313, branches, diff)
				if ai.plannedShortcut then
					count += 1
				end
			end
			return count
		end
		local nNovice = measure("novice")
		local nInter = measure("intermediate")
		local nExpert = measure("expert")
		local nBest = measure("best")
		assertTrue(
			nNovice < nInter and nInter < nExpert and nExpert < nBest,
			string.format(
				"expected novice(%d) < intermediate(%d) < expert(%d) < best(%d)",
				nNovice,
				nInter,
				nExpert,
				nBest
			)
		)
	end,
})

table.insert(tests, {
	name = "temple shortcut route satisfies ordered checkpoints and increments lap",
	fn = function()
		local pts = SandtrackData.drivelineQuadCenters
		local br = SandtrackData.drivelineBranches[1]
		local route: { { x: number, y: number, z: number } } = {}
		for i = 1, br.fromQuad + 1 do
			route[#route + 1] = { x = pts[i].x, y = -141.0, z = pts[i].z }
		end
		for _, p in ipairs(br.points) do
			route[#route + 1] = { x = p.x, y = -141.0, z = p.z }
		end
		for i = br.toQuad + 1, #pts do
			route[#route + 1] = { x = pts[i].x, y = -141.0, z = pts[i].z }
		end
		route[#route + 1] = { x = pts[1].x, y = -141.0, z = pts[1].z }

		local prog = CheckManager.initKartProgress(
			SandtrackData.checkpoints :: any,
			SandtrackData.startTransforms[1].pos,
			SandtrackData.startTransforms[1].yawRad
		)
		local lapBefore = prog.lap
		local prev = SandtrackData.startTransforms[1].pos
		for tick, cur in ipairs(route) do
			CheckManager.stepKart(prog, SandtrackData.checkpoints :: any, prev, cur, tick, 5)
			prev = cur
		end
		assertTrue(prog.lap == lapBefore + 1, string.format("expected lap %d, got %d", lapBefore + 1, prog.lap))
	end,
})

return tests
