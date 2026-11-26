--!strict
-- src/shared/audio/SfxEvents.lua
-- SPDX-License-Identifier: GPL-3.0-or-later
-- ported from src/karts/kart.cpp:L2268-L2302, L2500-L2525, L2637-L2647, L2682-L2725,
-- src/items/powerup.cpp:L167-L193, L379-L383, src/items/attachment.cpp:L554-L555, L679-L683,
-- src/items/swatter.cpp:L190-L192, src/items/plunger.cpp:L210,
-- and src/karts/controller/local_player_controller.cpp:L88-L93 (STK 1.5).
-- Pure Luau presentation-layer SFX transition detector and pitch curve (zero Roblox API).

local ItemEffectState = require("../sim/ItemEffectState")
local ItemTuning = require("../ItemTuning")

export type KartAudioSnapshot = {
	speedMps: number,
	maxSpeedMps: number,
	isOnGround: boolean,
	skidState: string,
	nitroActive: boolean,
	nitroEnergy: number,
	nitroMax: number,
	heldPowerup: number,
	heldPowerupCount: number,
	attachmentType: number,
	itemEffectType: number,
	plungerFaceTicks: number,
	bounceBackTicks: number,
	racePhase: string?,
	lap: number?,
	totalLaps: number?,
	raceFinished: boolean?,
	rank: number?,
	startupBoostFired: boolean?,
	startupBoostMps: number?,
	startupPenaltyTicks: number?,
}

export type OneShotEvent = {
	id: string,
	positional: boolean,
	volumeScale: number?,
}

export type LoopTransition = {
	id: string,
	action: "start" | "stop",
	positional: boolean,
}

export type AudioTracker = {
	initialized: boolean,
	lastFactorEngineSound: number,
	prev: KartAudioSnapshot,
	engineLoopActive: boolean,
	skidLoopActive: boolean,
	nitroLoopActive: boolean,
	bombLoopActive: boolean,
	crashCycle: number,
}

export type StepOutput = {
	enginePlaybackSpeed: number,
	engineActive: boolean,
	skidActive: boolean,
	nitroActive: boolean,
	bombActive: boolean,
	oneShots: { OneShotEvent },
	loopTransitions: { LoopTransition },
}

local SfxEvents = {}

local function cloneSnapshot(s: KartAudioSnapshot): KartAudioSnapshot
	return {
		speedMps = s.speedMps,
		maxSpeedMps = s.maxSpeedMps,
		isOnGround = s.isOnGround,
		skidState = s.skidState,
		nitroActive = s.nitroActive,
		nitroEnergy = s.nitroEnergy,
		nitroMax = s.nitroMax,
		heldPowerup = s.heldPowerup,
		heldPowerupCount = s.heldPowerupCount,
		attachmentType = s.attachmentType,
		itemEffectType = s.itemEffectType,
		plungerFaceTicks = s.plungerFaceTicks,
		bounceBackTicks = s.bounceBackTicks,
		racePhase = s.racePhase,
		lap = s.lap,
		totalLaps = s.totalLaps,
		raceFinished = s.raceFinished,
		rank = s.rank,
		startupBoostFired = s.startupBoostFired,
		startupBoostMps = s.startupBoostMps,
		startupPenaltyTicks = s.startupPenaltyTicks,
	}
end

function SfxEvents.createTracker(): AudioTracker
	return {
		initialized = false,
		lastFactorEngineSound = 0.0,
		prev = {
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
		},
		engineLoopActive = false,
		skidLoopActive = false,
		nitroLoopActive = false,
		bombLoopActive = false,
		crashCycle = 0,
	}
end

-- Ported from src/karts/kart.cpp:L2697-L2724 (STK 1.5)
function SfxEvents.computeEnginePlaybackSpeed(
	tracker: AudioTracker,
	speedMps: number,
	maxSpeedMps: number,
	isOnGround: boolean,
	dt: number
): number
	if isOnGround then
		local f = if maxSpeedMps > 0.0 then math.abs(speedMps) / maxSpeedMps else 1.0
		if f > 1.0 then
			f = 1.0 + (1.0 - 1.0 / f)
		end
		local fc = math.min(f, 1.0)
		local gears = 3.0 * (fc % 0.333334)
		tracker.lastFactorEngineSound = (0.9 * f + gears) * 0.35
	else
		tracker.lastFactorEngineSound = tracker.lastFactorEngineSound * math.max(0.0, 1.0 - 0.1 * dt)
		if math.abs(speedMps) < 0.1 then
			tracker.lastFactorEngineSound = 0.0
		end
	end
	return 0.6 + tracker.lastFactorEngineSound
end

local function powerupUseSfxId(powerupType: number, newAttachmentType: number): string?
	if powerupType == ItemTuning.POWERUP_BOWLING then
		-- bowling_shoot.ogg has unverified provenance in licenses.txt; falls back to shoot.ogg
		return "shoot"
	elseif powerupType == ItemTuning.POWERUP_ANVIL then
		return "anvil"
	elseif powerupType == ItemTuning.POWERUP_PARACHUTE then
		return "parachute"
	elseif powerupType == ItemTuning.POWERUP_BUBBLEGUM then
		if newAttachmentType == ItemTuning.ATTACHMENT_BUBBLEGUM_SHIELD then
			return "inflate"
		end
		return "goo"
	elseif powerupType == ItemTuning.POWERUP_SWITCH then
		return "swap"
	elseif powerupType == ItemTuning.POWERUP_SWATTER then
		return "swatter"
	elseif powerupType == ItemTuning.POWERUP_CAKE or powerupType == ItemTuning.POWERUP_PLUNGER then
		return "shoot"
	end
	return nil
end

local CRASH_IDS = { "crash", "crash2", "crash3" }

function SfxEvents.step(tracker: AudioTracker, curr: KartAudioSnapshot, dt: number, isLocalPlayer: boolean): StepOutput
	local enginePitch =
		SfxEvents.computeEnginePlaybackSpeed(tracker, curr.speedMps, curr.maxSpeedMps, curr.isOnGround, dt)
	local engineActive = true
	local skidActive = (curr.skidState == "SKID_ACCUMULATE_LEFT" or curr.skidState == "SKID_ACCUMULATE_RIGHT")
		and curr.isOnGround
	local nitroActive = curr.nitroActive and curr.isOnGround
	local bombActive = curr.attachmentType == ItemTuning.ATTACHMENT_BOMB

	local oneShots: { OneShotEvent } = {}
	local loopTransitions: { LoopTransition } = {}

	local function checkLoop(id: string, prevVal: boolean, nextVal: boolean, positional: boolean): boolean
		if nextVal ~= prevVal then
			table.insert(loopTransitions, {
				id = id,
				action = if nextVal then "start" else "stop",
				positional = positional,
			})
		end
		return nextVal
	end

	tracker.engineLoopActive = checkLoop("engine_large", tracker.engineLoopActive, engineActive, true)
	tracker.skidLoopActive = checkLoop("skid", tracker.skidLoopActive, skidActive, true)
	tracker.nitroLoopActive = checkLoop("nitro", tracker.nitroLoopActive, nitroActive, true)
	tracker.bombLoopActive = checkLoop("clock", tracker.bombLoopActive, bombActive, true)

	if not tracker.initialized then
		tracker.initialized = true
		tracker.prev = cloneSnapshot(curr)
		return {
			enginePlaybackSpeed = enginePitch,
			engineActive = engineActive,
			skidActive = skidActive,
			nitroActive = nitroActive,
			bombActive = bombActive,
			oneShots = oneShots,
			loopTransitions = loopTransitions,
		}
	end

	local prev = tracker.prev

	-- Collision / shield bounce (kart.cpp:L2500-L2525)
	if curr.bounceBackTicks > 0 and prev.bounceBackTicks == 0 then
		if
			curr.attachmentType == ItemTuning.ATTACHMENT_BUBBLEGUM_SHIELD
			or prev.attachmentType == ItemTuning.ATTACHMENT_BUBBLEGUM_SHIELD
		then
			table.insert(oneShots, { id = "boing", positional = true, volumeScale = 1.0 })
		else
			tracker.crashCycle = (tracker.crashCycle % 3) + 1
			local speedDelta = math.abs(prev.speedMps - curr.speedMps)
			local vol = math.clamp(math.sqrt(math.max(0.2, speedDelta) / 20.0), 0.2, 1.0)
			table.insert(oneShots, { id = CRASH_IDS[tracker.crashCycle], positional = true, volumeScale = vol })
		end
	end

	-- Item pickup / nitro pickup (local_player_controller.cpp:L91-L93)
	local pickedUpPowerup = (curr.heldPowerup ~= 0 and prev.heldPowerup == 0)
		or (curr.heldPowerup == prev.heldPowerup and curr.heldPowerupCount > prev.heldPowerupCount)
	local pickedUpNitro = curr.nitroEnergy > prev.nitroEnergy + 0.01

	if isLocalPlayer and (pickedUpPowerup or pickedUpNitro) then
		table.insert(oneShots, { id = "grab_collectable", positional = false, volumeScale = 1.0 })
	end

	if isLocalPlayer and curr.nitroMax > 0 then
		if curr.nitroEnergy >= curr.nitroMax and prev.nitroEnergy < curr.nitroMax then
			table.insert(oneShots, { id = "energy_bar_full", positional = false, volumeScale = 1.0 })
		elseif
			curr.nitroEnergy < prev.nitroMax * 0.25
			and prev.nitroEnergy >= curr.nitroMax * 0.25
			and not curr.nitroActive
		then
			table.insert(oneShots, { id = "energy_bar_unfull", positional = false, volumeScale = 1.0 })
		end
	end

	-- Item use (powerup.cpp:L167-L193, L379)
	local usedPowerup = prev.heldPowerup ~= 0
		and (curr.heldPowerup == 0 or curr.heldPowerupCount < prev.heldPowerupCount)
	if usedPowerup then
		local sfxId = powerupUseSfxId(prev.heldPowerup, curr.attachmentType)
		if sfxId then
			table.insert(oneShots, { id = sfxId, positional = sfxId ~= "swap", volumeScale = 1.0 })
		end
	end

	-- Hit / effect transitions (attachment.cpp:L311,L554; swatter.cpp:L190; kart.cpp:L1176; plunger.cpp:L210)
	if curr.itemEffectType ~= prev.itemEffectType then
		if curr.itemEffectType == ItemEffectState.EFFECT_EXPLOSION then
			table.insert(oneShots, { id = "explosion", positional = true, volumeScale = 1.0 })
		elseif curr.itemEffectType == ItemEffectState.EFFECT_SQUASH then
			table.insert(oneShots, { id = "hammer", positional = true, volumeScale = 1.0 })
		elseif curr.itemEffectType == ItemEffectState.EFFECT_BUBBLEGUM_SLOW then
			table.insert(oneShots, { id = "goo", positional = true, volumeScale = 1.0 })
		end
	end

	if isLocalPlayer and curr.plungerFaceTicks > 0 and prev.plungerFaceTicks == 0 then
		table.insert(oneShots, { id = "plunger", positional = false, volumeScale = 1.0 })
	end

	if
		prev.attachmentType == ItemTuning.ATTACHMENT_BUBBLEGUM_SHIELD
		and curr.attachmentType ~= ItemTuning.ATTACHMENT_BUBBLEGUM_SHIELD
		and curr.itemEffectType ~= ItemEffectState.EFFECT_EXPLOSION
	then
		table.insert(oneShots, { id = "bubblegum_explode", positional = true, volumeScale = 1.0 })
	end

	if isLocalPlayer then
		if curr.racePhase ~= nil and curr.racePhase ~= prev.racePhase then
			if curr.racePhase == "COUNTDOWN_3" or curr.racePhase == "READY_PHASE" or curr.racePhase == "SET_PHASE" then
				table.insert(oneShots, { id = "pre_start_race", positional = false, volumeScale = 1.0 })
			elseif curr.racePhase == "GO_PHASE" then
				table.insert(oneShots, { id = "start_race", positional = false, volumeScale = 1.0 })
			end
		end
		if curr.startupBoostFired == true and prev.startupBoostFired ~= true and (curr.startupBoostMps or 0) > 0 then
			table.insert(oneShots, { id = "wee", positional = false, volumeScale = 1.0 })
		end
		if (curr.startupPenaltyTicks or 0) > 0 and (prev.startupPenaltyTicks or 0) == 0 then
			table.insert(oneShots, { id = "bzzt", positional = false, volumeScale = 1.0 })
		end
		local totalLaps = curr.totalLaps or 5
		if
			totalLaps > 1
			and curr.lap ~= nil
			and prev.lap ~= nil
			and curr.lap == totalLaps - 1
			and prev.lap < totalLaps - 1
		then
			table.insert(oneShots, { id = "last_lap_fanfare", positional = false, volumeScale = 1.0 })
		end
		if curr.raceFinished == true and prev.raceFinished ~= true then
			local finishId = if (curr.rank or 1) == 1 then "race_finish_victory" else "race_finish"
			table.insert(oneShots, { id = finishId, positional = false, volumeScale = 1.0 })
		end
	end

	tracker.prev = cloneSnapshot(curr)

	return {
		enginePlaybackSpeed = enginePitch,
		engineActive = engineActive,
		skidActive = skidActive,
		nitroActive = nitroActive,
		bombActive = bombActive,
		oneShots = oneShots,
		loopTransitions = loopTransitions,
	}
end

return SfxEvents
