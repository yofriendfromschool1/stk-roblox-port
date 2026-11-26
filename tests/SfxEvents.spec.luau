--!strict
-- tests/SfxEvents.spec.luau
-- SPDX-License-Identifier: GPL-3.0-or-later

local ItemEffectState = require("../src/shared/sim/ItemEffectState")
local ItemTuning = require("../src/shared/ItemTuning")
local SfxEvents = require("../src/shared/audio/SfxEvents")

local function assertEqual(actual: any, expected: any, label: string)
	if actual ~= expected then
		error(string.format("%s: expected %s, got %s", label, tostring(expected), tostring(actual)))
	end
end

local function assertNear(actual: number, expected: number, eps: number, label: string)
	if math.abs(actual - expected) > eps then
		error(string.format("%s: expected %.4f +/- %.4f, got %.4f", label, expected, eps, actual))
	end
end

local function makeSnap(overrides: { [string]: any }?): SfxEvents.KartAudioSnapshot
	local s: any = {
		speedMps = 0.0,
		maxSpeedMps = 23.0,
		isOnGround = true,
		skidState = "SKID_NONE",
		nitroActive = false,
		nitroEnergy = 0.0,
		nitroMax = 20.0,
		heldPowerup = 0,
		heldPowerupCount = 0,
		attachmentType = 0,
		itemEffectType = ItemEffectState.EFFECT_NONE,
		plungerFaceTicks = 0,
		bounceBackTicks = 0,
	}
	if overrides then
		for k, v in overrides do
			s[k] = v
		end
	end
	return s
end

local tests = {}

table.insert(tests, {
	name = "skid and nitro loops start/stop on transitions and stop when airborne",
	fn = function()
		local tr = SfxEvents.createTracker()
		local r0 = SfxEvents.step(tr, makeSnap({}), 1 / 60, true)
		assertEqual(r0.engineActive, true, "engine starts")
		assertEqual(r0.skidActive, false, "skid initially off")
		assertEqual(r0.nitroActive, false, "nitro initially off")

		local r1 =
			SfxEvents.step(tr, makeSnap({ skidState = "SKID_ACCUMULATE_LEFT", nitroActive = true }), 1 / 60, true)
		assertEqual(r1.skidActive, true, "skid active")
		assertEqual(r1.nitroActive, true, "nitro active")
		assertEqual(#r1.loopTransitions, 2, "two loop starts")

		-- Steady state: no duplicate loop transitions
		local r2 =
			SfxEvents.step(tr, makeSnap({ skidState = "SKID_ACCUMULATE_LEFT", nitroActive = true }), 1 / 60, true)
		assertEqual(#r2.loopTransitions, 0, "no duplicate transitions while held")

		-- Grounded -> airborne stops both skid and nitro loops
		local r3 = SfxEvents.step(
			tr,
			makeSnap({ isOnGround = false, skidState = "SKID_ACCUMULATE_LEFT", nitroActive = true }),
			1 / 60,
			true
		)
		assertEqual(r3.skidActive, false, "skid stops in air")
		assertEqual(r3.nitroActive, false, "nitro stops in air")
		assertEqual(#r3.loopTransitions, 2, "two loop stops")
	end,
})

table.insert(tests, {
	name = "one-shot events fire exactly once per transition (pickup, use, collision, effect)",
	fn = function()
		local tr = SfxEvents.createTracker()
		SfxEvents.step(tr, makeSnap({}), 1 / 60, true)

		-- Item pickup
		local rPick = SfxEvents.step(
			tr,
			makeSnap({ heldPowerup = ItemTuning.POWERUP_BUBBLEGUM, heldPowerupCount = 1 }),
			1 / 60,
			true
		)
		assertEqual(#rPick.oneShots, 1, "pickup fires once")
		assertEqual(rPick.oneShots[1].id, "grab_collectable", "pickup sfx")

		-- Same held item next frame: no duplicate
		local rHold = SfxEvents.step(
			tr,
			makeSnap({ heldPowerup = ItemTuning.POWERUP_BUBBLEGUM, heldPowerupCount = 1 }),
			1 / 60,
			true
		)
		assertEqual(#rHold.oneShots, 0, "no duplicate pickup")

		-- Item use -> bubblegum shield inflate
		local rUse = SfxEvents.step(
			tr,
			makeSnap({
				heldPowerup = 0,
				heldPowerupCount = 0,
				attachmentType = ItemTuning.ATTACHMENT_BUBBLEGUM_SHIELD,
			}),
			1 / 60,
			true
		)
		assertEqual(#rUse.oneShots, 1, "use fires once")
		assertEqual(rUse.oneShots[1].id, "inflate", "bubblegum shield inflate")

		-- Collision while shielded -> boing
		local rBoing = SfxEvents.step(
			tr,
			makeSnap({
				attachmentType = ItemTuning.ATTACHMENT_BUBBLEGUM_SHIELD,
				bounceBackTicks = 10,
			}),
			1 / 60,
			true
		)
		assertEqual(#rBoing.oneShots, 1, "boing fires once")
		assertEqual(rBoing.oneShots[1].id, "boing", "shield collision boing")

		-- Explosion effect
		local rExp = SfxEvents.step(
			tr,
			makeSnap({
				itemEffectType = ItemEffectState.EFFECT_EXPLOSION,
				bounceBackTicks = 0,
			}),
			1 / 60,
			true
		)
		assertEqual(#rExp.oneShots, 1, "explosion fires once")
		assertEqual(rExp.oneShots[1].id, "explosion", "explosion sfx")
	end,
})

table.insert(tests, {
	name = "engine pitch curve increases with speed and decays when airborne",
	fn = function()
		local tr = SfxEvents.createTracker()
		local pIdle = SfxEvents.computeEnginePlaybackSpeed(tr, 0.0, 23.0, true, 1 / 60)
		assertNear(pIdle, 0.6, 1e-4, "idle pitch = 0.6")

		local pHalf = SfxEvents.computeEnginePlaybackSpeed(tr, 11.5, 23.0, true, 1 / 60)
		assertEqual(pHalf > pIdle, true, "half speed pitch > idle")

		local pAir = SfxEvents.computeEnginePlaybackSpeed(tr, 11.5, 23.0, false, 0.5)
		assertEqual(pAir < pHalf, true, "airborne pitch decays")
	end,
})

table.insert(tests, {
	name = "countdown, start boost, penalty, final lap, and finish SFX transitions fire for local player",
	fn = function()
		local tr = SfxEvents.createTracker()
		-- Init on COUNTDOWN_3
		SfxEvents.step(tr, makeSnap({ racePhase = "COUNTDOWN_3", lap = -1, totalLaps = 5 }), 1 / 60, true)

		local rReady =
			SfxEvents.step(tr, makeSnap({ racePhase = "READY_PHASE", lap = -1, totalLaps = 5 }), 1 / 60, true)
		assertEqual(#rReady.oneShots, 1, "READY_PHASE fires pre_start_race")
		assertEqual(rReady.oneShots[1].id, "pre_start_race", "READY_PHASE id")

		local rGo = SfxEvents.step(
			tr,
			makeSnap({
				racePhase = "GO_PHASE",
				lap = -1,
				totalLaps = 5,
				startupBoostFired = true,
				startupBoostMps = 6.4,
			}),
			1 / 60,
			true
		)
		assertEqual(#rGo.oneShots, 2, "GO + start boost fires two oneShots")
		assertEqual(rGo.oneShots[1].id, "start_race", "GO id")
		assertEqual(rGo.oneShots[2].id, "wee", "start boost id")

		local rFinal = SfxEvents.step(
			tr,
			makeSnap({
				racePhase = "RACE_PHASE",
				lap = 4,
				totalLaps = 5,
				startupBoostFired = true,
				startupBoostMps = 6.4,
			}),
			1 / 60,
			true
		)
		assertEqual(#rFinal.oneShots, 1, "final lap fires fanfare")
		assertEqual(rFinal.oneShots[1].id, "last_lap_fanfare", "final lap id")

		local rWin = SfxEvents.step(
			tr,
			makeSnap({
				racePhase = "RACE_PHASE",
				lap = 5,
				totalLaps = 5,
				raceFinished = true,
				rank = 1,
				startupBoostFired = true,
				startupBoostMps = 6.4,
			}),
			1 / 60,
			true
		)
		assertEqual(#rWin.oneShots, 1, "finish rank 1 fires victory")
		assertEqual(rWin.oneShots[1].id, "race_finish_victory", "victory id")
	end,
})

return tests
