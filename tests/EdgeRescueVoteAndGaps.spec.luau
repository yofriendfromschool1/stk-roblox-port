--!strict
-- tests/EdgeRescueVoteAndGaps.spec.luau
-- SPDX-License-Identifier: GPL-3.0-or-later

local CheckManager = require("../src/shared/race/CheckManager")
local EdgeRescue = require("../src/shared/sim/EdgeRescue")
local GreyboxProtocol = require("../src/shared/net/GreyboxProtocol")
local KartSolver = require("../src/shared/sim/KartSolver")
local KartTuning = require("../src/shared/KartTuning")
local KartVisualMath = require("../src/shared/kart/KartVisualMath")
local LobbyState = require("../src/shared/net/LobbyState")
local PasswordHash = require("../src/shared/net/PasswordHash")
local Standings = require("../src/shared/race/Standings")
local TimeGapMath = require("../src/shared/hud/TimeGapMath")
local TrackRegistry = require("../src/shared/track/TrackRegistry")

local function assertEqual(actual: any, expected: any, msg: string)
	if actual ~= expected then
		error(string.format("%s: expected %s, got %s", msg, tostring(expected), tostring(actual)), 2)
	end
end

local function assertTrue(cond: boolean, msg: string)
	if not cond then
		error(msg, 2)
	end
end

return {
	{
		name = "EdgeRescue: grounded edge never rescues; airborne over road never rescues; void fall rescues after grace",
		fn = function()
			local roadQuery = {
				raycast = function()
					return { materialName = "road.jpg" }
				end,
			}
			local voidQuery = {
				raycast = function()
					return nil
				end,
			}

			-- Grounded near edge: never rescues
			local r1, t1 = EdgeRescue.evaluate({
				numWheelsGrounded = 2,
				pos = { x = 0, y = 5, z = 0 },
				linVelY = -5.0,
				airborneDescentTicks = 50,
				racePhase = "RACE_PHASE",
				isRescuing = false,
				hasItemAnimation = false,
				worldQuery = voidQuery,
			})
			assertEqual(r1, false, "grounded near edge never rescues")
			assertEqual(t1, 0, "grounded resets descent ticks")

			-- Zipper jump with drivable road within RESCUE_PROBE_DEPTH_M below: never rescues
			local r2 = EdgeRescue.evaluate({
				numWheelsGrounded = 0,
				pos = { x = 0, y = 5, z = 0 },
				linVelY = -5.0,
				airborneDescentTicks = 60,
				racePhase = "RACE_PHASE",
				isRescuing = false,
				hasItemAnimation = false,
				worldQuery = roadQuery,
			})
			assertEqual(r2, false, "jump over drivable road does not rescue")

			-- Countdown / active rescue / item animation excluded
			local rCountdown = EdgeRescue.evaluate({
				numWheelsGrounded = 0,
				pos = { x = 0, y = 5, z = 0 },
				linVelY = -10.0,
				airborneDescentTicks = 60,
				racePhase = "READY_PHASE",
				isRescuing = false,
				hasItemAnimation = false,
				worldQuery = voidQuery,
			})
			assertEqual(rCountdown, false, "countdown excluded")

			-- Void fall triggers once grace ticks reached
			local ticks = 0
			local triggered = false
			for _ = 1, EdgeRescue.AIRBORNE_GRACE_TICKS do
				local hit, nextT = EdgeRescue.evaluate({
					numWheelsGrounded = 0,
					pos = { x = 0, y = 5, z = 0 },
					linVelY = -6.0,
					airborneDescentTicks = ticks,
					racePhase = "RACE_PHASE",
					isRescuing = false,
					hasItemAnimation = false,
					worldQuery = voidQuery,
				})
				ticks = nextT
				triggered = hit
			end
			assertEqual(triggered, true, "void fall triggers at grace ticks")
		end,
	},
	{
		name = "PasswordHash: salted hash verifies matching password and rejects wrong password",
		fn = function()
			local h = PasswordHash.hashPassword("secret123", "salt_abc")
			assertEqual(#h, 64, "SHA-256 hex length")
			assertTrue(PasswordHash.verify("secret123", "salt_abc", h), "matching password verifies")
			assertEqual(PasswordHash.verify("wrong", "salt_abc", h), false, "wrong password rejected")
			assertEqual(PasswordHash.verify("secret123", "other_salt", h), false, "wrong salt rejected")
		end,
	},
	{
		name = "LobbyState voting: playable candidates, deterministic tiebreak, and 1-player resolution",
		fn = function()
			local lobby = LobbyState.create({ trackId = "sandtrack", laps = 3 })
			LobbyState.addPlayer(lobby, 10, "Host")
			LobbyState.setPlayerReady(lobby, 10, true)

			local ok, err = LobbyState.beginVoting(lobby, 10, 100.0, 25.0)
			assertTrue(ok and err == nil, "beginVoting succeeds")
			assertEqual(lobby.phase, "VOTING", "phase is VOTING")
			assertTrue(#lobby.voting.candidates >= 1, "has playable candidates")

			local vOk, allVoted = LobbyState.submitVote(lobby, 10, {
				trackId = "sandtrack",
				laps = 5,
				reverse = true,
			})
			assertTrue(vOk and allVoted, "1-player vote marks allVoted")
			local cfg = LobbyState.resolveVoting(lobby)
			assertEqual(cfg.trackId, "sandtrack", "resolved track")
			assertEqual(cfg.laps, 5, "resolved laps")
			assertEqual(cfg.reverse, true, "resolved reverse")
			assertEqual(lobby.phase, "RACING", "phase transitions to RACING")

			-- Multi-player deterministic tiebreak: lowest laps & reverse=false wins ties
			LobbyState.returnToLobby(lobby)
			LobbyState.addPlayer(lobby, 20, "Guest")
			LobbyState.setPlayerReady(lobby, 10, true)
			LobbyState.setPlayerReady(lobby, 20, true)
			LobbyState.beginVoting(lobby, 10, 200.0, 25.0)
			LobbyState.submitVote(lobby, 10, { trackId = "sandtrack", laps = 7, reverse = true })
			LobbyState.submitVote(lobby, 20, { trackId = "sandtrack", laps = 2, reverse = false })
			local tieCfg = LobbyState.resolveVoting(lobby)
			assertEqual(tieCfg.laps, 2, "tiebreak picks lowest laps")
			assertEqual(tieCfg.reverse, false, "tiebreak picks reverse=false")
		end,
	},
	{
		name = "TrackRegistry.getOriented(reverse=true) reverses driveline, start yaw, and checkpoints",
		fn = function()
			local fwd = TrackRegistry.getOriented("sandtrack", false)
			local rev = TrackRegistry.getOriented("sandtrack", true)
			assertTrue(math.abs(math.abs(rev.startYawRad - fwd.startYawRad) - math.pi) < 1e-4, "start yaw flipped pi")
			assertEqual(#rev.drivelineQuadCenters, #fwd.drivelineQuadCenters, "driveline length preserved")
			assertTrue(
				rev.drivelineQuadCenters[2].x == fwd.drivelineQuadCenters[#fwd.drivelineQuadCenters].x,
				"driveline reversed"
			)
			local prog = CheckManager.initKartProgress(rev.checkpoints, rev.startPos, rev.startYawRad)
			assertEqual(prog.lap, -1, "reversed spawn starts behind lap line (lap=-1)")
		end,
	},
	{
		name = "TimeGapMath: 30s post-lap window, crossing-time delta, monotonic jitter filter, lapped display",
		fn = function()
			local cache = TimeGapMath.createCache()
			local entriesLap0: { Standings.StandingsEntry } = {
				{ id = "1", lap = 0, checkpoint = 1, distance = 50, lapStartTick = 240 },
				{ id = "2", lap = 0, checkpoint = 1, distance = 20, lapStartTick = 240 },
			}
			local ranked0 = Standings.compute(entriesLap0)
			local gaps0 = TimeGapMath.computeGaps(ranked0, 600, 3, cache)
			assertEqual(gaps0["1"].visible, false, "hidden before leader completes Lap 1")

			-- Leader crosses Lap 1 at tick 1240; P2 crossed at 1420 (+1.5s); P3 still on Lap 0; P4 lapped (leader Lap 2 vs Lap 0)
			local entriesLap1: { Standings.StandingsEntry } = {
				{ id = "1", lap = 1, checkpoint = 1, distance = 10, lapStartTick = 1240 },
				{ id = "2", lap = 1, checkpoint = 1, distance = 5, lapStartTick = 1420 },
				{ id = "3", lap = 0, checkpoint = 2, distance = 90, lapStartTick = 240 },
			}
			local ranked1 = Standings.compute(entriesLap1)
			local gaps1 = TimeGapMath.computeGaps(ranked1, 1480, 3, cache)
			assertEqual(gaps1["1"].visible, true, "leader lap time visible within 30s")
			assertEqual(gaps1["2"].text, "+00:01.500", "P2 shows crossing delta +00:01.500")
			assertEqual(gaps1["3"].text, "+00:02.000", "P3 shows live delta +00:02.000")

			-- Past 30s (1240 + 3600 + 1 = 4841): hidden
			local gapsExpired = TimeGapMath.computeGaps(ranked1, 4850, 3, cache)
			assertEqual(gapsExpired["2"].visible, false, "hidden after 30s window")

			-- Lapped kart: leader lap 2 vs kart lap 0 -> +1 Lap
			local entriesLapped: { Standings.StandingsEntry } = {
				{ id = "1", lap = 2, checkpoint = 1, distance = 10, lapStartTick = 2440 },
				{ id = "4", lap = 0, checkpoint = 1, distance = 5, lapStartTick = 240 },
			}
			local rankedLapped = Standings.compute(entriesLapped)
			local gapsLapped = TimeGapMath.computeGaps(rankedLapped, 2500, 3, cache)
			assertEqual(gapsLapped["4"].text, "+1 Lap", "lapped kart displays +1 Lap")
		end,
	},
	{
		name = "KartVisualMath.computeBombArrowState & GreyboxProtocol lapStartTick round-trip",
		fn = function()
			local b1 = KartVisualMath.computeBombArrowState(3600) -- 30s
			local b2 = KartVisualMath.computeBombArrowState(1200) -- 10s
			local b0 = KartVisualMath.computeBombArrowState(120) -- 1s (urgent)
			assertEqual(b1.angleDeg, -180.0, "30s -> -180 deg")
			assertEqual(b2.angleDeg, -60.0, "10s -> -60 deg")
			assertEqual(b0.urgentFlash, true, "1s -> urgentFlash active")

			local prof = KartTuning.buildProfileForKart("tux", "intermediate")
			local ks = KartSolver.createState(prof, { x = 0, y = 0.5, z = 0 }, 0)
			local ns = KartSolver.captureNetState(ks)
			local buf = GreyboxProtocol.packSnapshot(10, 1, 1, ns, "", {
				{
					id = "dummy",
					kartId = "adiumy",
					pos = { 1, 2, 3 },
					rot = { 1, 0, 0, 0 },
					linVel = { 0, 0, 0 },
					speed = 0,
					steer = 0,
					attachmentType = 0,
					plungerFaceTicks = 0,
					isSquashed = false,
					rank = 2,
					lapStartTick = 1357,
				},
			}, 1.0)
			local unpacked = GreyboxProtocol.unpackSnapshot(buf, nil)
			assertTrue(unpacked ~= nil and unpacked.remoteKarts ~= nil, "unpacked remoteKarts")
			if unpacked ~= nil and unpacked.remoteKarts ~= nil then
				assertEqual(unpacked.remoteKarts[1].lapStartTick, 1357, "lapStartTick round-trip")
			end
		end,
	},
}
