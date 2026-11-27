--!strict
-- tests/PhaseABFixes.spec.luau
-- SPDX-License-Identifier: GPL-3.0-or-later

local AIController = require("../src/shared/ai/AIController")
local CheckManager = require("../src/shared/race/CheckManager")
local FixedStep = require("../src/shared/sim/FixedStep")
local GreyboxProtocol = require("../src/shared/net/GreyboxProtocol")
local ItemWorld = require("../src/shared/items/ItemWorld")
local KartSolver = require("../src/shared/sim/KartSolver")
local KartTuning = require("../src/shared/KartTuning")
local MaxSpeed = require("../src/shared/kart/MaxSpeed")
local Nitro = require("../src/shared/kart/Nitro")
local RaceHudMath = require("../src/shared/hud/RaceHudMath")
local SandtrackData = require("../src/shared/track/SandtrackData")
local Skidding = require("../src/shared/kart/Skidding")
local TrackRegistry = require("../src/shared/track/TrackRegistry")

local function assertEqual(actual: any, expected: any, msg: string)
	if actual ~= expected then
		error(string.format("%s: expected %s, got %s", msg, tostring(expected), tostring(actual)))
	end
end

local function assertTrue(cond: boolean, msg: string)
	if not cond then
		error(msg)
	end
end

local function assertNear(actual: number, expected: number, tol: number, msg: string)
	if math.abs(actual - expected) > tol then
		error(string.format("%s: expected %.4f +- %.4f, got %.4f", msg, expected, tol, actual))
	end
end

return {
	{
		name = "drift hop peak (~0.196m) and tier thresholds (1.0s, 3.0s)",
		fn = function()
			local s = Skidding.new()
			local peak = 0.0
			for _ = 1, 60 do
				Skidding.update(s, 1, true, 15.0, 1.0, "RIGHT", 9.8)
				if s.hopHeight > peak then
					peak = s.hopHeight
				end
			end
			assertNear(peak, 0.196, 0.01, "skid hop peak")

			local t1 = Skidding.getSkidBonus(FixedStep.timeToTicks(1.0) + 1)
			local t2 = Skidding.getSkidBonus(FixedStep.timeToTicks(3.0) + 1)
			assertEqual(t1, 1, "tier 1 at >1.0s")
			assertEqual(t2, 2, "tier 2 at >3.0s")
		end,
	},
	{
		name = "nitro activates on nitroPressed even airborne/no accel; speed boost grounded-only",
		fn = function()
			local prof = KartTuning.buildProfileForKart("tux", "intermediate")
			local st = Nitro.new(prof.nitro)
			local ms = MaxSpeed.new()
			st.energy = 5.0
			local increaseSpeed = Nitro.update(st, prof.nitro, ms, 1, true, false, false)
			assertTrue(st.minNitroTicks > 0, "nitro activates on nitroPressed without ground or accel")
			assertTrue(not increaseSpeed and not st.active, "nitro speed boost does not apply when airborne")
			assertTrue(st.energy < 5.0, "nitro energy drains while active")
		end,
	},
	{
		name = "formatStkTime matches STK mm:ss.cc formatting",
		fn = function()
			assertEqual(RaceHudMath.formatStkTime(0.0), "00:00.00", "zero time")
			assertEqual(RaceHudMath.formatStkTime(65.432), "01:05.43", "1m5.43s")
			assertEqual(RaceHudMath.formatStkTime(5.05), "00:05.05", "5.05s")
		end,
	},
	{
		name = "CheckManager lap completion and GreyboxProtocol fastestLap roundtrip",
		fn = function()
			local track = TrackRegistry.get("sandtrack")
			local prog = CheckManager.initKartProgress(track.checkpoints, track.startPos, track.startYawRad)
			prog.lap = 0
			prog.nextCheckpoint = 0
			prog.lapStartTick = 240
			local cp0 = track.checkpoints[1]
			local cpX = (cp0.p1.x + cp0.p2.x) * 0.5
			local cpY = (cp0.p1.y + cp0.p2.y) * 0.5
			local cpZ = (cp0.p1.z + cp0.p2.z) * 0.5
			local dx = cp0.p2.x - cp0.p1.x
			local dz = cp0.p2.z - cp0.p1.z
			local len = math.max(1e-6, math.sqrt(dx * dx + dz * dz))
			local nx = -dz / len
			local nz = dx / len
			local changed, lapInc, _, lapTicks = CheckManager.stepKart(
				prog,
				track.checkpoints,
				{ x = cpX - nx * 2.0, y = cpY, z = cpZ - nz * 2.0 },
				{ x = cpX + nx * 2.0, y = cpY, z = cpZ + nz * 2.0 },
				1240,
				3
			)
			assertTrue(changed and lapInc, "lap incremented")
			assertEqual(lapTicks, 1000, "completedLapTicks")
			assertEqual(prog.bestLapTicks, 1000, "bestLapTicks updated")

			local prof = KartTuning.buildProfileForKart("tux", "intermediate")
			local ks = KartSolver.createState(prof, track.startPos, track.startYawRad)
			ks.race.lapStartTick = 240
			ks.race.bestLapTicks = 1000
			ks.lastRescueBranchIdx = 1
			ks.aiStuckTicks = 42
			ks.aiLastProgressDist = 123.5
			ks.fastestLapTicks = 1000
			ks.fastestLapKartId = "7"
			ks.fastestLapHolderName = "Tux"

			local ns = KartSolver.captureNetState(ks)
			local remotes: { GreyboxProtocol.RemoteKartState } = {
				{
					id = "ai_2",
					kartId = "adiumy",
					pos = { 0, 1, 0 },
					rot = { 1, 0, 0, 0 },
					linVel = { 0, 0, 0 },
					speed = 0,
					steer = 0,
					attachmentType = 0,
					plungerFaceTicks = 0,
					isSquashed = false,
					rank = 2,
					bestLapTicks = 1050,
				},
			}
			local buf = GreyboxProtocol.packSnapshot(500, 10, 0, ns, "", remotes, 1.5)
			local unpacked = GreyboxProtocol.unpackSnapshot(buf)
			assertTrue(unpacked ~= nil, "unpackSnapshot succeeded")
			if unpacked ~= nil then
				assertEqual(unpacked.netState.race.bestLapTicks, 1000, "netState bestLapTicks")
				assertEqual(unpacked.netState.lastRescueBranchIdx, 1, "netState lastRescueBranchIdx")
				assertEqual(unpacked.netState.aiStuckTicks, 42, "netState aiStuckTicks")
				assertNear(unpacked.netState.aiLastProgressDist or 0, 123.5, 0.01, "netState aiLastProgressDist")
				assertEqual(unpacked.netState.fastestLapTicks, 1000, "netState fastestLapTicks")
				assertEqual(unpacked.netState.fastestLapKartId, "7", "netState fastestLapKartId")
				assertEqual(unpacked.netState.fastestLapHolderName, "Tux", "netState fastestLapHolderName")
				assertTrue(unpacked.remoteKarts ~= nil and #unpacked.remoteKarts == 1, "1 remote kart")
				if unpacked.remoteKarts ~= nil then
					assertEqual(unpacked.remoteKarts[1].bestLapTicks, 1050, "remote bestLapTicks")
				end
			end
		end,
	},
	{
		name = "Time Trial ItemWorld disables bonus boxes",
		fn = function()
			local track = TrackRegistry.get("sandtrack")
			local iw = ItemWorld.fromArenaSpec(track :: any, "TIME_TRIAL")
			assertEqual(iw.haveBonusBoxes, false, "haveBonusBoxes false in TIME_TRIAL")
			local visibleBoxes = 0
			for _, it in iw.items do
				if it.itemType == "item" and iw.haveBonusBoxes then
					visibleBoxes += 1
				end
			end
			assertEqual(visibleBoxes, 0, "0 visible bonus boxes in TIME_TRIAL")
		end,
	},
	{
		name = "AIController.stepStuckWatchdog triggers at 240 ticks and resets when moving",
		fn = function()
			local track = TrackRegistry.get("sandtrack")
			local prof = KartTuning.buildProfileForKart("tux", "intermediate")
			local ks = KartSolver.createState(prof, track.startPos, track.startYawRad)
			local ai =
				AIController.createState(track.drivelineQuadCenters, ks.pos, 12345, track.drivelineBranches :: any)

			ks.speed = 0.5
			ks.aiLastProgressDist = ai.totalDistance
			local firedAt = -1
			for tick = 1, 250 do
				if AIController.stepStuckWatchdog(ai, ks, true, false) then
					firedAt = tick
					break
				end
			end
			assertEqual(firedAt, 240, "watchdog triggers at tick 240")

			-- Moving slowly (e.g. sand/hairpin at 3 m/s) resets watchdog
			ks.speed = 3.0
			for _ = 1, 300 do
				assertTrue(not AIController.stepStuckWatchdog(ai, ks, true, false), "no false positive when moving")
			end
		end,
	},
	{
		name = "Sandtrack temple shortcut (Branch 1) rescue stays on Branch 1 at 3 points",
		fn = function()
			local track = TrackRegistry.get("sandtrack")
			local branches = SandtrackData.drivelineBranches
			assertTrue(branches ~= nil and #branches >= 1, "sandtrack has branch 1")
			local b1 = branches[1]
			local prof = KartTuning.buildProfileForKart("tux", "intermediate")
			local testIndices = { 8, 24, 40 }
			for _, bqIdx in testIndices do
				local pt = b1.points[bqIdx]
				local ks = KartSolver.createState(prof, { x = pt.x, y = pt.y + 0.35, z = pt.z }, 0.0)
				ks.isOnGround = true
				ks.activeMaterialName = "sand"
				ks.race.lap = 0
				ks.race.nextCheckpoint = #track.checkpoints
				local ok = KartSolver.updateLastRescuePose(
					ks,
					track.checkpoints,
					track.drivelineQuadCenters,
					nil,
					branches,
					1,
					bqIdx
				)
				assertTrue(ok, "updateLastRescuePose succeeded on branch 1 quad " .. tostring(bqIdx))
				assertEqual(ks.lastRescueBranchIdx, 1, "recorded branchIdx == 1")
				local tPos, _, _, tBranch = CheckManager.resolveClampedRescuePose(
					ks.lastRescueQuadIdx,
					ks.lastRescuePos,
					ks.lastRescueYawRad,
					track.checkpoints,
					ks.race.lap,
					ks.race.nextCheckpoint,
					track.drivelineQuadCenters,
					track.startPos,
					track.startYawRad,
					nil,
					prof.collisionHeight,
					ks.pos,
					ks.lastRescueBranchIdx,
					branches
				)
				assertEqual(tBranch, 1, "resolved rescue branch == 1")
				local dist = math.sqrt((tPos.x - pt.x) ^ 2 + (tPos.y - pt.y) ^ 2 + (tPos.z - pt.z) ^ 2)
				assertTrue(dist < 3.0, string.format("rescue distance < 3m on branch 1 (got %.2fm)", dist))
			end
		end,
	},
}
