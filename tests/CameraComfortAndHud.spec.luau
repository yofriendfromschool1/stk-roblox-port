--!strict
-- tests/CameraComfortAndHud.spec.luau
-- SPDX-License-Identifier: GPL-3.0-or-later

local CameraComfort = require("../src/shared/camera/CameraComfort")
local GreyboxProtocol = require("../src/shared/net/GreyboxProtocol")
local HudNotifications = require("../src/shared/hud/HudNotifications")
local KartSolver = require("../src/shared/sim/KartSolver")
local KartTuning = require("../src/shared/KartTuning")

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
		name = "CameraComfort: small bumps inside deadzone produce zero vertical velocity",
		fn = function()
			local st = CameraComfort.createState()
			local cfg: CameraComfort.CameraComfortConfig = {
				deadzone = 0.55,
				tau = 0.35,
				maxVel = 14.0,
				lookSmoothSec = 0.22,
			}
			local y0, _, v0 = CameraComfort.step(st, 10.0, 11.0, 1 / 60, cfg)
			assertEqual(y0, 10.0, "initializes at targetY")
			assertEqual(v0, 0.0, "initial velocity zero")

			for i = 1, 30 do
				local bumpY = 10.0 + 0.25 * math.sin(i * 0.6)
				local cy, _, vy = CameraComfort.step(st, bumpY, bumpY + 1.0, 1 / 60, cfg)
				assertEqual(cy, 10.0, "camera Y stays steady inside deadzone")
				assertEqual(vy, 0.0, "camera Y velocity stays 0 inside deadzone")
			end
		end,
	},
	{
		name = "CameraComfort: ramp/drop clamped by maxVel without overshoot oscillation",
		fn = function()
			local st = CameraComfort.createState()
			local cfg: CameraComfort.CameraComfortConfig = {
				deadzone = 0.55,
				tau = 0.35,
				maxVel = 14.0,
				lookSmoothSec = 0.22,
			}
			CameraComfort.step(st, 0.0, 1.0, 1 / 60, cfg)
			local maxObservedVel = 0.0
			local maxObservedY = -math.huge
			for _ = 1, 180 do
				local cy, _, vy = CameraComfort.step(st, 20.0, 21.0, 1 / 60, cfg)
				maxObservedVel = math.max(maxObservedVel, math.abs(vy))
				maxObservedY = math.max(maxObservedY, cy)
				assertTrue(math.abs(vy) <= cfg.maxVel + 1e-6, "velocity clamped within maxVel")
			end
			assertTrue(maxObservedVel > 8.0, "camera climbs ramp")
			assertTrue(maxObservedY <= 20.0 - cfg.deadzone + 0.05, "no significant overshoot oscillation")
		end,
	},
	{
		name = "CameraComfort: 30 fps vs 60 fps vs 120 fps equivalence on temple descent",
		fn = function()
			local cfg: CameraComfort.CameraComfortConfig = {
				deadzone = 0.55,
				tau = 0.35,
				maxVel = 14.0,
				lookSmoothSec = 0.22,
			}
			local function simulateDescent(fps: number): (number, number)
				local st = CameraComfort.createState()
				local dt = 1.0 / fps
				CameraComfort.step(st, 0.0, 0.5, dt, cfg)
				local totalSteps = fps * 2
				local camY = 0.0
				local lookY = 0.0
				for s = 1, totalSteps do
					local t = s * dt
					local kartY = -6.0 * t
					camY, lookY = CameraComfort.step(st, kartY, kartY + 0.5, dt, cfg)
				end
				return camY, lookY
			end
			local y30, l30 = simulateDescent(30)
			local y60, l60 = simulateDescent(60)
			local y120, l120 = simulateDescent(120)
			assertTrue(
				math.abs(y30 - y60) < 0.08,
				string.format("30 vs 60 camY drift too large: %.4f vs %.4f", y30, y60)
			)
			assertTrue(
				math.abs(y60 - y120) < 0.04,
				string.format("60 vs 120 camY drift too large: %.4f vs %.4f", y60, y120)
			)
			assertTrue(
				math.abs(l30 - l60) < 0.05,
				string.format("30 vs 60 lookY drift too large: %.4f vs %.4f", l30, l60)
			)
			assertTrue(
				math.abs(l60 - l120) < 0.03,
				string.format("60 vs 120 lookY drift too large: %.4f vs %.4f", l60, l120)
			)
		end,
	},
	{
		name = "HudNotifications: no start-boost toast and rescue suppresses duplicate edges",
		fn = function()
			local ns = HudNotifications.createState()
			-- Match start: lap 0, no toast
			HudNotifications.step(ns, {
				inRacing = true,
				racePhase = "RACE_PHASE",
				raceTick = 240,
				resetSeq = 1,
				lap = 0,
				totalLaps = 3,
				raceFinished = false,
				startupPenaltyTicks = 0,
				rescueTicks = 0,
			}, 1.0)
			assertEqual(ns.subToastText, "", "no start-boost toast at Go!")

			-- Lap 1 -> LAP 2 toast
			HudNotifications.step(ns, {
				inRacing = true,
				racePhase = "RACE_PHASE",
				raceTick = 300,
				resetSeq = 1,
				lap = 1,
				totalLaps = 3,
				raceFinished = false,
				startupPenaltyTicks = 0,
				rescueTicks = 0,
			}, 2.0)
			assertEqual(ns.lapToastText, "LAP 2", "lap edge triggers LAP 2")

			-- Rescue clears subToast and suppresses edge during/after rescue
			HudNotifications.step(ns, {
				inRacing = true,
				racePhase = "RACE_PHASE",
				raceTick = 360,
				resetSeq = 1,
				lap = 1,
				totalLaps = 3,
				raceFinished = false,
				startupPenaltyTicks = 0,
				rescueTicks = 120,
			}, 3.0)
			assertEqual(ns.subToastText, "", "no toast during rescue")
			HudNotifications.step(ns, {
				inRacing = true,
				racePhase = "RACE_PHASE",
				raceTick = 480,
				resetSeq = 1,
				lap = 1,
				totalLaps = 3,
				raceFinished = false,
				startupPenaltyTicks = 0,
				rescueTicks = 0,
			}, 4.0)
			assertEqual(ns.subToastText, "", "no duplicate toast exiting rescue")
		end,
	},
	{
		name = "GreyboxProtocol: RemoteKartState heldPowerup and heldPowerupCount round-trip",
		fn = function()
			local prof = KartTuning.buildProfileForKart("tux", "intermediate")
			local ks = KartSolver.createState(prof, { x = 0, y = 0.5, z = 0 }, 0)
			local netState = KartSolver.captureNetState(ks)
			local remotes: { GreyboxProtocol.RemoteKartState } = {
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
					heldPowerup = 3,
					heldPowerupCount = 2,
				},
			}
			local buf = GreyboxProtocol.packSnapshot(10, 1, 1, netState, "", remotes, 1.0)
			local unpacked = GreyboxProtocol.unpackSnapshot(buf, nil)
			assertTrue(unpacked ~= nil and unpacked.remoteKarts ~= nil, "unpacked remoteKarts")
			if unpacked ~= nil and unpacked.remoteKarts ~= nil then
				assertEqual(unpacked.remoteKarts[1].heldPowerup, 3, "heldPowerup round-trip")
				assertEqual(unpacked.remoteKarts[1].heldPowerupCount, 2, "heldPowerupCount round-trip")
			end
		end,
	},
}
