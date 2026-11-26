--!strict
-- src/shared/net/LobbyState.lua
-- SPDX-License-Identifier: GPL-3.0-or-later
-- ported conceptually from src/network/protocols/server_lobby.cpp &
-- data/gui/screens/online/{create_server,networking_lobby}.stkgui (STK 1.5).
-- Pure-Luau server-authoritative in-server lobby state machine (zero Roblox API).

local CatalogData = require("../menu/CatalogData")
local MenuFlow = require("../menu/MenuFlow")

export type LobbyPhase = "LOBBY" | "RACING"

export type LobbySettings = {
	serverName: string,
	trackId: string,
	laps: number,
	difficulty: MenuFlow.Difficulty,
	raceType: MenuFlow.RaceType,
	maxPlayers: number,
	aiCount: number,
	hasPassword: boolean,
}

export type LobbyPlayer = {
	userId: number,
	name: string,
	kartId: string,
	ready: boolean,
	admitted: boolean,
}

export type PublicLobbySnapshot = {
	phase: LobbyPhase,
	hostUserId: number?,
	settingsLocked: boolean,
	settings: LobbySettings,
	players: { LobbyPlayer },
}

export type Lobby = {
	phase: LobbyPhase,
	hostUserId: number?,
	settingsLocked: boolean,
	settings: LobbySettings,
	_password: string,
	players: { LobbyPlayer },
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
	for _, entry in ipairs(CatalogData.karts) do
		if entry.playable then
			return entry.id
		end
	end
	return "tux"
end

local function sanitizeServerName(raw: any): string
	if type(raw) ~= "string" then
		return "OpenKart Lobby"
	end
	local trimmed = string.gsub(raw, "^%s*(.-)%s*$", "%1")
	if #trimmed == 0 then
		return "OpenKart Lobby"
	end
	return string.sub(trimmed, 1, 30)
end

local function sanitizePassword(raw: any): string
	if type(raw) ~= "string" then
		return ""
	end
	return string.sub(raw, 1, 255)
end

local function findPlayerIndex(state: Lobby, userId: number): number?
	for i, p in ipairs(state.players) do
		if p.userId == userId then
			return i
		end
	end
	return nil
end

local function countAdmitted(state: Lobby): number
	local count = 0
	for _, p in ipairs(state.players) do
		if p.admitted then
			count += 1
		end
	end
	return count
end

local LobbyState = {}

function LobbyState.create(initial: { [string]: any }?): Lobby
	local src: { [string]: any } = if type(initial) == "table" then initial else {}
	local pw = sanitizePassword(src.password)
	local raceType: MenuFlow.RaceType = if type(src.raceType) == "string" and VALID_RACE_TYPES[src.raceType]
		then src.raceType :: MenuFlow.RaceType
		else "NORMAL_RACE"
	local diff: MenuFlow.Difficulty = if type(src.difficulty) == "string" and VALID_DIFFICULTIES[src.difficulty]
		then src.difficulty :: MenuFlow.Difficulty
		else "intermediate"
	local trackId = if type(src.trackId) == "string" and isPlayableTrack(src.trackId)
		then src.trackId
		else defaultTrackId()
	local laps = math.clamp(if type(src.laps) == "number" then math.floor(src.laps + 0.5) else 5, 1, 20)
	local maxPlayers =
		math.clamp(if type(src.maxPlayers) == "number" then math.floor(src.maxPlayers + 0.5) else 8, 2, 20)
	local aiRaw = if type(src.aiCount) == "number" then math.floor(src.aiCount + 0.5) else 3
	local aiCount = if raceType == "TIME_TRIAL" then 0 else math.clamp(aiRaw, 0, 11)

	return {
		phase = "LOBBY",
		hostUserId = nil,
		settingsLocked = false,
		settings = {
			serverName = sanitizeServerName(src.serverName),
			trackId = trackId,
			laps = laps,
			difficulty = diff,
			raceType = raceType,
			maxPlayers = maxPlayers,
			aiCount = aiCount,
			hasPassword = #pw > 0,
		},
		_password = pw,
		players = {},
	}
end

function LobbyState.addPlayer(state: Lobby, userId: number, name: string): (LobbyPlayer, boolean)
	local existingIdx = findPlayerIndex(state, userId)
	if existingIdx ~= nil then
		local existing = state.players[existingIdx]
		existing.name = name
		return existing, existing.admitted
	end

	local isFirst = (#state.players == 0 or state.hostUserId == nil)
	local canAdmitWithoutPw = isFirst
		or (
			not state.settings.hasPassword
			and countAdmitted(state) < state.settings.maxPlayers
			and not state.settingsLocked
		)
	local player: LobbyPlayer = {
		userId = userId,
		name = name,
		kartId = defaultKartId(),
		ready = false,
		admitted = canAdmitWithoutPw,
	}
	table.insert(state.players, player)
	if isFirst then
		state.hostUserId = userId
	end
	return player, player.admitted
end

function LobbyState.removePlayer(state: Lobby, userId: number): number?
	local idx = findPlayerIndex(state, userId)
	if idx == nil then
		return state.hostUserId
	end
	table.remove(state.players, idx)
	if state.hostUserId == userId then
		state.hostUserId = nil
		for _, p in ipairs(state.players) do
			if p.admitted then
				state.hostUserId = p.userId
				break
			end
		end
		if state.hostUserId == nil and #state.players > 0 then
			state.players[1].admitted = true
			state.hostUserId = state.players[1].userId
		end
	end
	return state.hostUserId
end

function LobbyState.submitPassword(state: Lobby, userId: number, candidate: any): (boolean, string?)
	local idx = findPlayerIndex(state, userId)
	if idx == nil then
		return false, "NOT_IN_LOBBY"
	end
	local p = state.players[idx]
	if p.admitted then
		return true, nil
	end
	if state.settingsLocked or state.phase ~= "LOBBY" then
		return false, "LOCKED"
	end
	if countAdmitted(state) >= state.settings.maxPlayers then
		return false, "LOBBY_FULL"
	end
	local candStr = if type(candidate) == "string" then candidate else ""
	if candStr ~= state._password then
		return false, "WRONG_PASSWORD"
	end
	p.admitted = true
	return true, nil
end

function LobbyState.updateSettings(state: Lobby, actorUserId: number, patch: { [string]: any }): (boolean, string?)
	if actorUserId ~= state.hostUserId then
		return false, "NOT_HOST"
	end
	if state.settingsLocked or state.phase ~= "LOBBY" then
		return false, "LOCKED"
	end
	if type(patch) ~= "table" then
		return false, "INVALID_PATCH"
	end

	local raceSettingsChanged = false
	if patch.serverName ~= nil then
		state.settings.serverName = sanitizeServerName(patch.serverName)
	end
	if patch.trackId ~= nil and type(patch.trackId) == "string" and isPlayableTrack(patch.trackId) then
		if state.settings.trackId ~= patch.trackId then
			state.settings.trackId = patch.trackId
			raceSettingsChanged = true
		end
	end
	if patch.laps ~= nil and type(patch.laps) == "number" then
		local laps = math.clamp(math.floor(patch.laps + 0.5), 1, 20)
		if state.settings.laps ~= laps then
			state.settings.laps = laps
			raceSettingsChanged = true
		end
	end
	if patch.difficulty ~= nil and type(patch.difficulty) == "string" and VALID_DIFFICULTIES[patch.difficulty] then
		if state.settings.difficulty ~= patch.difficulty then
			state.settings.difficulty = patch.difficulty :: MenuFlow.Difficulty
			raceSettingsChanged = true
		end
	end
	if patch.raceType ~= nil and type(patch.raceType) == "string" and VALID_RACE_TYPES[patch.raceType] then
		if state.settings.raceType ~= patch.raceType then
			state.settings.raceType = patch.raceType :: MenuFlow.RaceType
			raceSettingsChanged = true
		end
	end
	if patch.maxPlayers ~= nil and type(patch.maxPlayers) == "number" then
		state.settings.maxPlayers = math.clamp(math.floor(patch.maxPlayers + 0.5), 2, 20)
	end
	if patch.aiCount ~= nil and type(patch.aiCount) == "number" then
		local ai = math.clamp(math.floor(patch.aiCount + 0.5), 0, 11)
		if state.settings.aiCount ~= ai then
			state.settings.aiCount = ai
			raceSettingsChanged = true
		end
	end
	if state.settings.raceType == "TIME_TRIAL" then
		state.settings.aiCount = 0
	end
	if patch.password ~= nil then
		state._password = sanitizePassword(patch.password)
		state.settings.hasPassword = (#state._password > 0)
	end

	if raceSettingsChanged then
		for _, p in ipairs(state.players) do
			if p.userId ~= state.hostUserId then
				p.ready = false
			end
		end
	end
	return true, nil
end

function LobbyState.setPlayerKart(state: Lobby, userId: number, kartId: any): (boolean, string?)
	if state.settingsLocked or state.phase ~= "LOBBY" then
		return false, "LOCKED"
	end
	local idx = findPlayerIndex(state, userId)
	if idx == nil or not state.players[idx].admitted then
		return false, "NOT_ADMITTED"
	end
	if type(kartId) ~= "string" or not isPlayableKart(kartId) then
		return false, "INVALID_KART"
	end
	state.players[idx].kartId = kartId
	return true, nil
end

function LobbyState.setPlayerReady(state: Lobby, userId: number, ready: boolean): (boolean, string?)
	if state.settingsLocked or state.phase ~= "LOBBY" then
		return false, "LOCKED"
	end
	local idx = findPlayerIndex(state, userId)
	if idx == nil or not state.players[idx].admitted then
		return false, "NOT_ADMITTED"
	end
	state.players[idx].ready = (ready == true)
	return true, nil
end

function LobbyState.canStart(state: Lobby, actorUserId: number): (boolean, string?)
	if actorUserId ~= state.hostUserId then
		return false, "NOT_HOST"
	end
	if state.phase ~= "LOBBY" or state.settingsLocked then
		return false, "ALREADY_STARTED"
	end
	local admittedCount = 0
	for _, p in ipairs(state.players) do
		if p.admitted then
			admittedCount += 1
			if not p.ready then
				return false, "PLAYERS_NOT_READY"
			end
		end
	end
	if admittedCount == 0 then
		return false, "NO_PLAYERS"
	end
	return true, nil
end

function LobbyState.startRace(state: Lobby, actorUserId: number): (boolean, MenuFlow.SessionConfig?, string?)
	local ok, reason = LobbyState.canStart(state, actorUserId)
	if not ok then
		return false, nil, reason
	end
	state.settingsLocked = true
	state.phase = "RACING"
	local cfg = MenuFlow.sanitizeSessionConfig({
		playMode = "ONLINE",
		raceType = state.settings.raceType,
		trackId = state.settings.trackId,
		kartId = defaultKartId(),
		difficulty = state.settings.difficulty,
		laps = state.settings.laps,
		aiCount = state.settings.aiCount,
	})
	return true, cfg, nil
end

function LobbyState.returnToLobby(state: Lobby): ()
	state.phase = "LOBBY"
	state.settingsLocked = false
	for _, p in ipairs(state.players) do
		p.ready = false
	end
end

function LobbyState.getPublicSnapshot(state: Lobby): PublicLobbySnapshot
	local playersCopy: { LobbyPlayer } = table.create(#state.players)
	for i, p in ipairs(state.players) do
		playersCopy[i] = {
			userId = p.userId,
			name = p.name,
			kartId = p.kartId,
			ready = p.ready,
			admitted = p.admitted,
		}
	end
	return {
		phase = state.phase,
		hostUserId = state.hostUserId,
		settingsLocked = state.settingsLocked,
		settings = {
			serverName = state.settings.serverName,
			trackId = state.settings.trackId,
			laps = state.settings.laps,
			difficulty = state.settings.difficulty,
			raceType = state.settings.raceType,
			maxPlayers = state.settings.maxPlayers,
			aiCount = state.settings.aiCount,
			hasPassword = state.settings.hasPassword,
		},
		players = playersCopy,
	}
end

return table.freeze(LobbyState)
