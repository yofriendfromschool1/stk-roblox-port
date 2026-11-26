--!strict
-- src/shared/sim/RaceState.lua
-- SPDX-License-Identifier: GPL-3.0-or-later
-- ported from src/modes/world_status.hpp:L43-L176, src/modes/world_status.cpp:L83-L84, L319-L455,
-- src/karts/controller/player_controller.cpp:L331-L356, L421-L424,
-- src/karts/controller/local_player_controller.cpp:L182-L197,
-- src/karts/kart.cpp:L1197-L1210, L2612-L2625, data/kart_characteristics.xml:L281-L282,
-- and data/stk_config.xml:L99, L214, L217 (STK 1.5).
-- Pure-Luau deterministic race phase machine & start-bonus evaluator (zero Roblox API).

local FixedStep = require("./FixedStep")
local KartTuning = require("../KartTuning")

export type RacePhase =
	"COUNTDOWN_3"
	| "READY_PHASE"
	| "SET_PHASE"
	| "GO_PHASE"
	| "MUSIC_PHASE"
	| "RACE_PHASE"
	| "DELAY_FINISH_PHASE"
	| "RESULT_DISPLAY_PHASE"

export type RaceClock = {
	raceTick: number,
	phase: RacePhase,
	totalLaps: number,
	delayFinishStartTick: number,
}

export type RaceKartInputLike = {
	accel: number,
	brake: boolean,
	steer: number,
	drift: boolean,
	nitro: boolean?,
	fire: boolean?,
	lookBack: boolean?,
	skidControl: any?,
	instantSteer: boolean?,
}

local RaceState = {}

local READY_START_TICK = KartTuning.race.COUNTDOWN_3_TICKS
local SET_START_TICK = READY_START_TICK + KartTuning.race.READY_TICKS
local GO_TICK = SET_START_TICK + KartTuning.race.SET_TICKS
local MUSIC_START_TICK = GO_TICK + KartTuning.race.GO_TICKS
local RACE_START_TICK = GO_TICK + KartTuning.race.MUSIC_END_TICKS
local DELAY_FINISH_TICKS = KartTuning.race.DELAY_FINISH_TICKS

RaceState.READY_START_TICK = READY_START_TICK
RaceState.SET_START_TICK = SET_START_TICK
RaceState.GO_TICK = GO_TICK
RaceState.MUSIC_START_TICK = MUSIC_START_TICK
RaceState.RACE_START_TICK = RACE_START_TICK
RaceState.DELAY_FINISH_TICKS = DELAY_FINISH_TICKS

local PHASE_TO_ID: { [RacePhase]: number } = {
	COUNTDOWN_3 = 1,
	READY_PHASE = 2,
	SET_PHASE = 3,
	GO_PHASE = 4,
	MUSIC_PHASE = 5,
	RACE_PHASE = 6,
	DELAY_FINISH_PHASE = 7,
	RESULT_DISPLAY_PHASE = 8,
}

local ID_TO_PHASE: { RacePhase } = {
	"COUNTDOWN_3" :: RacePhase,
	"READY_PHASE" :: RacePhase,
	"SET_PHASE" :: RacePhase,
	"GO_PHASE" :: RacePhase,
	"MUSIC_PHASE" :: RacePhase,
	"RACE_PHASE" :: RacePhase,
	"DELAY_FINISH_PHASE" :: RacePhase,
	"RESULT_DISPLAY_PHASE" :: RacePhase,
}

RaceState.PHASE_TO_ID = table.freeze(PHASE_TO_ID)
RaceState.ID_TO_PHASE = table.freeze(ID_TO_PHASE)

function RaceState.phaseAtTick(raceTick: number, delayFinishStartTick: number?): RacePhase
	if delayFinishStartTick ~= nil and delayFinishStartTick >= 0 then
		if raceTick - delayFinishStartTick > DELAY_FINISH_TICKS then
			return "RESULT_DISPLAY_PHASE" :: RacePhase
		end
		return "DELAY_FINISH_PHASE" :: RacePhase
	end
	if raceTick < READY_START_TICK then
		return "COUNTDOWN_3" :: RacePhase
	elseif raceTick < SET_START_TICK then
		return "READY_PHASE" :: RacePhase
	elseif raceTick < GO_TICK then
		return "SET_PHASE" :: RacePhase
	elseif raceTick < MUSIC_START_TICK then
		return "GO_PHASE" :: RacePhase
	elseif raceTick < RACE_START_TICK then
		return "MUSIC_PHASE" :: RacePhase
	else
		return "RACE_PHASE" :: RacePhase
	end
end

function RaceState.create(totalLaps: number?): RaceClock
	return {
		raceTick = 0,
		phase = "COUNTDOWN_3" :: RacePhase,
		totalLaps = totalLaps or KartTuning.race.DEFAULT_LAPS,
		delayFinishStartTick = -1,
	}
end

function RaceState.step(clock: RaceClock): RacePhase
	clock.raceTick += 1
	clock.phase = RaceState.phaseAtTick(clock.raceTick, clock.delayFinishStartTick)
	return clock.phase
end

function RaceState.enterDelayFinish(clock: RaceClock)
	if clock.delayFinishStartTick < 0 then
		clock.delayFinishStartTick = clock.raceTick
	end
	clock.phase = RaceState.phaseAtTick(clock.raceTick, clock.delayFinishStartTick)
end

-- WorldStatus::isStartPhase (world_status.hpp:L170)
function RaceState.isStartPhase(phase: RacePhase): boolean
	return phase == "COUNTDOWN_3" or phase == "READY_PHASE" or phase == "SET_PHASE"
end

-- WorldStatus::isRacePhase (world_status.hpp:L172-L173)
function RaceState.isRacePhase(phase: RacePhase): boolean
	return not RaceState.isStartPhase(phase)
end

-- WorldStatus::isActiveRacePhase (world_status.hpp:L175-L176)
function RaceState.isActiveRacePhase(phase: RacePhase): boolean
	return phase == "GO_PHASE" or phase == "MUSIC_PHASE" or phase == "RACE_PHASE"
end

function RaceState.isThrottleAllowed(phase: RacePhase): boolean
	return not RaceState.isStartPhase(phase)
end

function RaceState.isSteeringAllowed(phase: RacePhase): boolean
	return not RaceState.isStartPhase(phase)
end

function RaceState.getCountdownValue(phase: RacePhase): number?
	if phase == "COUNTDOWN_3" then
		return 3
	elseif phase == "READY_PHASE" then
		return 2
	elseif phase == "SET_PHASE" then
		return 1
	elseif phase == "GO_PHASE" then
		return 0
	end
	return nil
end

function RaceState.getCountdownText(phase: RacePhase): string?
	if phase == "COUNTDOWN_3" then
		return "3"
	elseif phase == "READY_PHASE" then
		return "2"
	elseif phase == "SET_PHASE" then
		return "1"
	elseif phase == "GO_PHASE" then
		return "GO!"
	end
	return nil
end

function RaceState.getTicksSinceGo(raceTick: number): number
	return math.max(0, raceTick - GO_TICK)
end

function RaceState.getRaceElapsedSec(raceTick: number): number
	return RaceState.getTicksSinceGo(raceTick) * FixedStep.FIXED_DT
end

-- Kart::getStartupBoostFromStartTicks (src/karts/kart.cpp:L1197-L1210, data/kart_characteristics.xml:L281-L282)
function RaceState.isInStartBonusWindow(raceTick: number, profile: KartTuning.KartProfile): (boolean, number)
	local ticksSinceSet = raceTick - SET_START_TICK
	if ticksSinceSet < 0 or raceTick >= GO_TICK then
		return false, 0.0
	end
	local t = ticksSinceSet * FixedStep.FIXED_DT
	for i = 1, #profile.startupTimes do
		if t <= profile.startupTimes[i] then
			return true, profile.startupBoosts[i] or 0.0
		end
	end
	return false, 0.0
end

-- Evaluates first accel press during countdown:
-- before SET_PHASE -> 0 boost + 120-tick (1.0 s) penalty;
-- during SET_PHASE -> start-bonus window test; at/after GO -> 0 boost, 0 penalty.
function RaceState.evaluateStartupAccel(raceTick: number, profile: KartTuning.KartProfile): (number, number)
	if raceTick < SET_START_TICK then
		return 0.0, KartTuning.startup.penaltyTicks
	end
	local ok, boost = RaceState.isInStartBonusWindow(raceTick, profile)
	if ok then
		return boost, 0
	end
	return 0.0, 0
end

function RaceState.filterInputForPhase<T>(phase: RacePhase, rawInput: T & RaceKartInputLike, penaltyTicks: number): T
	if RaceState.isStartPhase(phase) then
		return {
			accel = 0,
			brake = false,
			steer = 0,
			drift = false,
			nitro = false,
			fire = false,
			lookBack = rawInput.lookBack,
			skidControl = "NONE",
			instantSteer = rawInput.instantSteer,
		} :: any
	end
	if penaltyTicks > 0 then
		return {
			accel = 0,
			brake = false,
			steer = rawInput.steer,
			drift = rawInput.drift,
			nitro = false,
			fire = rawInput.fire,
			lookBack = rawInput.lookBack,
			skidControl = rawInput.skidControl,
			instantSteer = rawInput.instantSteer,
		} :: any
	end
	return rawInput
end

return RaceState
