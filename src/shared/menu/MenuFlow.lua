--!strict
-- SPDX-License-Identifier: GPL-3.0-or-later
-- Ported from src/states_screens/main_menu_screen.cpp, race_setup_screen.cpp, and track_info_screen.cpp (STK 1.5).

local CatalogData = require("./CatalogData")

export type Screen =
	"MENU"
	| "MODE"
	| "TRACK"
	| "KART"
	| "CONFIG"
	| "LOBBY"
	| "LOADING"
	| "RACING"
	| "OPTIONS"
	| "ABOUT"

export type PlayMode = "SINGLEPLAYER" | "LOCAL_2P" | "ONLINE"
export type RaceType = "NORMAL_RACE" | "TIME_TRIAL"
export type Difficulty = "novice" | "intermediate" | "expert" | "best"

export type SessionConfig = {
	playMode: PlayMode,
	raceType: RaceType,
	trackId: string,
	kartId: string,
	difficulty: Difficulty,
	laps: number,
	aiCount: number,
	reverse: boolean,
}

export type MenuState = {
	screen: Screen,
	previousScreen: Screen,
	config: SessionConfig,
}

local VALID_PLAY_MODES: { [string]: boolean } = {
	SINGLEPLAYER = true,
	LOCAL_2P = true,
	ONLINE = true,
}

local VALID_RACE_TYPES: { [string]: boolean } = {
	NORMAL_RACE = true,
	TIME_TRIAL = true,
}

local VALID_DIFFICULTIES: { [string]: boolean } = {
	novice = true,
	intermediate = true,
	expert = true,
	best = true,
}

local MenuFlow = {}

local function isPlayableTrack(trackId: string): boolean
	for _, entry in ipairs(CatalogData.tracks) do
		if entry.id == trackId and entry.playable then
			return true
		end
	end
	return false
end

local function isPlayableKart(kartId: string): boolean
	for _, entry in ipairs(CatalogData.karts) do
		if entry.id == kartId and entry.playable then
			return true
		end
	end
	return false
end

local function defaultTrackId(): string
	for _, entry in ipairs(CatalogData.tracks) do
		if entry.playable then
			return entry.id
		end
	end
	return "sandtrack"
end

local function defaultKartId(): string
	if isPlayableKart("tux") then
		return "tux"
	end
	for _, entry in ipairs(CatalogData.karts) do
		if entry.playable then
			return entry.id
		end
	end
	return "tux"
end

function MenuFlow.sanitizeSessionConfig(raw: { [string]: any }?): SessionConfig
	local src: { [string]: any } = if type(raw) == "table" then raw else {}
	local playMode: PlayMode = if type(src.playMode) == "string" and VALID_PLAY_MODES[src.playMode]
		then src.playMode :: PlayMode
		else "SINGLEPLAYER"
	local raceType: RaceType = if type(src.raceType) == "string" and VALID_RACE_TYPES[src.raceType]
		then src.raceType :: RaceType
		else "NORMAL_RACE"
	local trackId = if type(src.trackId) == "string" and isPlayableTrack(src.trackId)
		then src.trackId
		else defaultTrackId()
	local kartId = if type(src.kartId) == "string" and isPlayableKart(src.kartId) then src.kartId else defaultKartId()
	local difficulty: Difficulty = if type(src.difficulty) == "string" and VALID_DIFFICULTIES[src.difficulty]
		then src.difficulty :: Difficulty
		else "intermediate"
	local lapsRaw = if type(src.laps) == "number" then math.floor(src.laps + 0.5) else 5
	local laps = math.clamp(lapsRaw, 1, 20)
	local aiRaw = if type(src.aiCount) == "number" then math.floor(src.aiCount + 0.5) else 3
	local aiCount = if raceType == "TIME_TRIAL" then 0 else math.clamp(aiRaw, 0, 11)
	local reverse = src.reverse == true

	return {
		playMode = playMode,
		raceType = raceType,
		trackId = trackId,
		kartId = kartId,
		difficulty = difficulty,
		laps = laps,
		aiCount = aiCount,
		reverse = reverse,
	}
end

function MenuFlow.create(initialConfig: { [string]: any }?): MenuState
	return {
		screen = "MENU",
		previousScreen = "MENU",
		config = MenuFlow.sanitizeSessionConfig(initialConfig),
	}
end

function MenuFlow.selectPlayMode(state: MenuState, playMode: PlayMode): ()
	if not VALID_PLAY_MODES[playMode] then
		return
	end
	state.config.playMode = playMode
	if playMode == "LOCAL_2P" and state.config.raceType == "TIME_TRIAL" then
		state.config.raceType = "NORMAL_RACE"
	end
	state.previousScreen = "MENU"
	state.screen = "MODE"
end

function MenuFlow.selectRaceType(state: MenuState, raceType: RaceType): ()
	if not VALID_RACE_TYPES[raceType] then
		return
	end
	state.config.raceType = raceType
	if raceType == "TIME_TRIAL" then
		state.config.aiCount = 0
	elseif state.config.aiCount == 0 and state.config.playMode == "SINGLEPLAYER" then
		state.config.aiCount = 3
	end
	state.previousScreen = "MODE"
	state.screen = "TRACK"
end

function MenuFlow.selectTrack(state: MenuState, trackId: string): boolean
	if not isPlayableTrack(trackId) then
		return false
	end
	state.config.trackId = trackId
	state.previousScreen = "TRACK"
	state.screen = "KART"
	return true
end

function MenuFlow.selectKart(state: MenuState, kartId: string): boolean
	if not isPlayableKart(kartId) then
		return false
	end
	state.config.kartId = kartId
	state.previousScreen = "KART"
	state.screen = "CONFIG"
	return true
end

function MenuFlow.setConfig(state: MenuState, patch: { [string]: any }): ()
	local merged = {
		playMode = state.config.playMode,
		raceType = state.config.raceType,
		trackId = state.config.trackId,
		kartId = state.config.kartId,
		difficulty = if patch.difficulty ~= nil then patch.difficulty else state.config.difficulty,
		laps = if patch.laps ~= nil then patch.laps else state.config.laps,
		aiCount = if patch.aiCount ~= nil then patch.aiCount else state.config.aiCount,
		reverse = if patch.reverse ~= nil then patch.reverse else state.config.reverse,
	}
	state.config = MenuFlow.sanitizeSessionConfig(merged)
end

function MenuFlow.startRace(state: MenuState): ()
	state.config = MenuFlow.sanitizeSessionConfig(state.config :: any)
	state.previousScreen = "CONFIG"
	state.screen = "LOADING"
end

function MenuFlow.onRaceLoaded(state: MenuState): ()
	state.previousScreen = "LOADING"
	state.screen = "RACING"
end

function MenuFlow.returnToMenu(state: MenuState): ()
	state.previousScreen = state.screen
	state.screen = "MENU"
end

function MenuFlow.openOptions(state: MenuState): ()
	if state.screen ~= "OPTIONS" then
		state.previousScreen = state.screen
	end
	state.screen = "OPTIONS"
end

function MenuFlow.openAbout(state: MenuState): ()
	if state.screen ~= "ABOUT" then
		state.previousScreen = state.screen
	end
	state.screen = "ABOUT"
end

function MenuFlow.openLobby(state: MenuState): ()
	state.config.playMode = "ONLINE"
	if state.screen ~= "LOBBY" then
		state.previousScreen = state.screen
	end
	state.screen = "LOBBY"
end

function MenuFlow.back(state: MenuState): ()
	if state.screen == "OPTIONS" or state.screen == "ABOUT" then
		state.screen = if state.previousScreen == "OPTIONS" or state.previousScreen == "ABOUT"
			then "MENU"
			else state.previousScreen
	elseif state.screen == "LOBBY" or state.screen == "MODE" then
		state.screen = "MENU"
	elseif state.screen == "TRACK" then
		state.screen = "MODE"
	elseif state.screen == "KART" then
		state.screen = "TRACK"
	elseif state.screen == "CONFIG" then
		state.screen = "KART"
	end
end

return MenuFlow
