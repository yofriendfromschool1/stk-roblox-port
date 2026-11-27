--!strict
-- src/server/ReservedLobbyService.lua
-- SPDX-License-Identifier: GPL-3.0-or-later
-- Roblox MemoryStoreService + TeleportService reserved-server lobby registry.
-- Security: passwords hashed server-side via PasswordHash (never stored/sent plaintext),
-- accessCode never sent to clients, and TeleportData verified against MemoryStore registry.

local HttpService = game:GetService("HttpService")
local MemoryStoreService = game:GetService("MemoryStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TeleportService = game:GetService("TeleportService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local PasswordHash = require(Shared.net.PasswordHash)

export type ReservedServerEntry = {
	lobbyId: string,
	accessCode: string,
	joinToken: string,
	serverName: string,
	trackId: string,
	difficulty: string,
	raceType: string,
	maxPlayers: number,
	hasPassword: boolean,
	passwordSalt: string,
	passwordHash: string,
	hostUserId: number,
	hostName: string,
	playerCount: number,
	createdAt: number,
}

export type PublicReservedServerSummary = {
	lobbyId: string,
	serverName: string,
	trackId: string,
	difficulty: string,
	raceType: string,
	maxPlayers: number,
	hasPassword: boolean,
	hostName: string,
	playerCount: number,
	createdAt: number,
}

export type TeleportFailureCallback = (player: Player, reason: string, retrying: boolean, message: string) -> ()

local REGISTRY_MAP_NAME = "OpenKartReservedLobbies_v2"
local ENTRY_TTL_SEC = 600
local TTL_REFRESH_INTERVAL_SEC = 120
local MAX_TELEPORT_RETRIES = 2

local ReservedLobbyService = {}

local studioDevRegistry: { [string]: ReservedServerEntry } = {}
local activeRefreshLoops: { [string]: boolean } = {}
local pendingTeleports: { [number]: { lobbyId: string, retries: number } } = {}
local teleportFailureCb: TeleportFailureCallback? = nil
local initFailedBound = false

local function canUseLiveServices(): boolean
	return (not RunService:IsStudio()) and game.PlaceId > 0
end

local function getRegistryMap(): MemoryStoreSortedMap?
	local ok, res = pcall(function()
		return MemoryStoreService:GetSortedMap(REGISTRY_MAP_NAME)
	end)
	if ok then
		return res :: MemoryStoreSortedMap
	end
	return nil
end

local function makePublicSummary(v: ReservedServerEntry): PublicReservedServerSummary
	return {
		lobbyId = v.lobbyId,
		serverName = v.serverName,
		trackId = v.trackId,
		difficulty = v.difficulty,
		raceType = v.raceType,
		maxPlayers = v.maxPlayers,
		hasPassword = v.hasPassword,
		hostName = v.hostName,
		playerCount = v.playerCount or 1,
		createdAt = v.createdAt,
	}
end

local function fetchEntry(lobbyId: string): (ReservedServerEntry?, string?)
	if not canUseLiveServices() then
		local devEntry = studioDevRegistry[lobbyId]
		if devEntry == nil then
			return nil, "LOBBY_NOT_FOUND"
		end
		return devEntry, nil
	end
	local map = getRegistryMap()
	if map == nil then
		return nil, "MEMORYSTORE_UNAVAILABLE"
	end
	local ok, entry = pcall(function()
		return map:GetAsync(lobbyId)
	end)
	if not ok or type(entry) ~= "table" or type((entry :: ReservedServerEntry).accessCode) ~= "string" then
		return nil, "LOBBY_NOT_FOUND"
	end
	return entry :: ReservedServerEntry, nil
end

local function doTeleport(player: Player, entry: ReservedServerEntry): (boolean, string?)
	local opts = Instance.new("TeleportOptions");
	(opts :: any).ReservedServerAccessCode = entry.accessCode
	opts:SetTeleportData({
		lobbyId = entry.lobbyId,
		joinToken = entry.joinToken,
		hostUserId = entry.hostUserId,
	})
	local tpOk, tpErr = pcall(function()
		TeleportService:TeleportAsync(game.PlaceId, { player }, opts)
	end)
	if not tpOk then
		return false, tostring(tpErr or "TELEPORT_FAILED")
	end
	return true, nil
end

function ReservedLobbyService.setTeleportFailureHandler(cb: TeleportFailureCallback?)
	teleportFailureCb = cb
	if not initFailedBound and not RunService:IsStudio() then
		initFailedBound = true
		TeleportService.TeleportInitFailed:Connect(function(player: Player, result: Enum.TeleportResult, errMsg: string)
			local pending = pendingTeleports[player.UserId]
			if pending == nil then
				return
			end
			if pending.retries < MAX_TELEPORT_RETRIES then
				pending.retries += 1
				local attempt = pending.retries
				if teleportFailureCb ~= nil then
					teleportFailureCb(
						player,
						result.Name,
						true,
						string.format(
							"Teleport failed (%s). Retrying (%d/%d)...",
							result.Name,
							attempt,
							MAX_TELEPORT_RETRIES
						)
					)
				end
				task.delay(attempt * 1.5, function()
					if player.Parent == nil then
						pendingTeleports[player.UserId] = nil
						return
					end
					local entry = fetchEntry(pending.lobbyId)
					if entry == nil then
						pendingTeleports[player.UserId] = nil
						if teleportFailureCb ~= nil then
							teleportFailureCb(player, "LOBBY_EXPIRED", false, "Lobby expired during teleport retry.")
						end
						return
					end
					local ok, retryErr = doTeleport(player, entry)
					if not ok and teleportFailureCb ~= nil then
						teleportFailureCb(player, retryErr or "TELEPORT_FAILED", false, "Teleport retry failed.")
					end
				end)
			else
				pendingTeleports[player.UserId] = nil
				if teleportFailureCb ~= nil then
					teleportFailureCb(
						player,
						result.Name,
						false,
						string.format("Teleport failed after retries: %s (%s)", result.Name, errMsg)
					)
				end
			end
		end)
	end
end

function ReservedLobbyService.startTtlRefresh(lobbyId: string, getPlayerCountFn: () -> number)
	if activeRefreshLoops[lobbyId] then
		return
	end
	activeRefreshLoops[lobbyId] = true
	task.spawn(function()
		while activeRefreshLoops[lobbyId] do
			task.wait(TTL_REFRESH_INTERVAL_SEC)
			if not activeRefreshLoops[lobbyId] then
				break
			end
			local entry = fetchEntry(lobbyId)
			if entry == nil then
				break
			end
			entry.playerCount = getPlayerCountFn()
			if canUseLiveServices() then
				local map = getRegistryMap()
				if map ~= nil then
					pcall(function()
						map:SetAsync(lobbyId, entry, ENTRY_TTL_SEC)
					end)
				end
			else
				studioDevRegistry[lobbyId] = entry
			end
		end
	end)
end

function ReservedLobbyService.stopTtlRefresh(lobbyId: string)
	activeRefreshLoops[lobbyId] = nil
end

function ReservedLobbyService.createReservedLobby(
	hostPlayer: Player,
	settings: { [string]: any },
	rawPassword: string?
): { ok: boolean, reason: string?, entry: PublicReservedServerSummary? }
	local pwStr = if type(rawPassword) == "string" then rawPassword else ""
	local hasPw = #pwStr > 0
	local salt = HttpService:GenerateGUID(false)
	local pwHash = if hasPw then PasswordHash.hashPassword(pwStr, salt) else ""
	local joinToken = HttpService:GenerateGUID(false)
	local lobbyId = string.format("%d_%d", hostPlayer.UserId, os.time())

	local accessCode = "STUDIO_DEV_" .. lobbyId
	if canUseLiveServices() then
		local reserveOk, codeOrErr = pcall(function()
			return TeleportService:ReserveServerAsync(game.PlaceId)
		end)
		if not reserveOk or type(codeOrErr) ~= "string" then
			return {
				ok = false,
				reason = "RESERVE_FAILED",
				entry = nil,
			}
		end
		accessCode = codeOrErr
	end

	local entry: ReservedServerEntry = {
		lobbyId = lobbyId,
		accessCode = accessCode,
		joinToken = joinToken,
		serverName = tostring(settings.serverName or "OpenKart Lobby"),
		trackId = tostring(settings.trackId or "sandtrack"),
		difficulty = tostring(settings.difficulty or "intermediate"),
		raceType = tostring(settings.raceType or "NORMAL_RACE"),
		maxPlayers = tonumber(settings.maxPlayers) or 8,
		hasPassword = hasPw,
		passwordSalt = salt,
		passwordHash = pwHash,
		hostUserId = hostPlayer.UserId,
		hostName = hostPlayer.Name,
		playerCount = 1,
		createdAt = os.time(),
	}

	if canUseLiveServices() then
		local map = getRegistryMap()
		if map == nil then
			return { ok = false, reason = "MEMORYSTORE_UNAVAILABLE", entry = nil }
		end
		local setOk = pcall(function()
			map:SetAsync(lobbyId, entry, ENTRY_TTL_SEC)
		end)
		if not setOk then
			return { ok = false, reason = "MEMORYSTORE_WRITE_FAILED", entry = nil }
		end
	else
		studioDevRegistry[lobbyId] = entry
	end

	return {
		ok = true,
		reason = nil,
		entry = makePublicSummary(entry),
	}
end

function ReservedLobbyService.listReservedLobbies(): {
	ok: boolean,
	reason: string?,
	entries: { PublicReservedServerSummary },
}
	if not canUseLiveServices() then
		local out: { PublicReservedServerSummary } = {}
		for _, v in pairs(studioDevRegistry) do
			table.insert(out, makePublicSummary(v))
		end
		table.sort(out, function(a, b)
			return a.createdAt > b.createdAt
		end)
		return {
			ok = true,
			reason = nil,
			entries = out,
		}
	end
	local map = getRegistryMap()
	if map == nil then
		return {
			ok = false,
			reason = "MEMORYSTORE_UNAVAILABLE",
			entries = {},
		}
	end
	local ok, items = pcall(function()
		return map:GetRangeAsync(Enum.SortDirection.Descending, 20)
	end)
	if not ok or type(items) ~= "table" then
		return {
			ok = false,
			reason = "MEMORYSTORE_READ_FAILED",
			entries = {},
		}
	end
	local out: { PublicReservedServerSummary } = {}
	for _, item in ipairs(items :: { { value: any } }) do
		if type(item.value) == "table" then
			table.insert(out, makePublicSummary(item.value :: ReservedServerEntry))
		end
	end
	return {
		ok = true,
		reason = nil,
		entries = out,
	}
end

function ReservedLobbyService.joinReservedLobby(
	player: Player,
	lobbyId: string,
	candidatePassword: string?
): (boolean, string?)
	local entry, errReason = fetchEntry(lobbyId)
	if entry == nil then
		return false, errReason or "LOBBY_NOT_FOUND"
	end
	if entry.hasPassword then
		local cand = if type(candidatePassword) == "string" then candidatePassword else ""
		if not PasswordHash.verify(cand, entry.passwordSalt, entry.passwordHash) then
			return false, "WRONG_PASSWORD"
		end
	end
	if not canUseLiveServices() then
		-- Studio dev path: skip TeleportAsync after validating password & registry entry
		return true, nil
	end
	pendingTeleports[player.UserId] = { lobbyId = lobbyId, retries = 0 }
	local tpOk, tpReason = doTeleport(player, entry)
	if not tpOk then
		pendingTeleports[player.UserId] = nil
		return false, tpReason
	end
	return true, nil
end

-- Server-side TeleportData verification upon arrival in a reserved server.
function ReservedLobbyService.validateArrival(player: Player): (boolean, string?, ReservedServerEntry?)
	if not canUseLiveServices() or game.PrivateServerId == "" then
		return true, nil, nil
	end
	local joinData = player:GetJoinData()
	local tpData: any = if type(joinData) == "table" then (joinData :: any).TeleportData else nil
	if type(tpData) ~= "table" or type(tpData.lobbyId) ~= "string" or type(tpData.joinToken) ~= "string" then
		return false, "MISSING_TELEPORT_DATA", nil
	end
	local entry, err = fetchEntry(tpData.lobbyId)
	if entry == nil then
		return false, err or "LOBBY_NOT_FOUND", nil
	end
	if tpData.joinToken ~= entry.joinToken then
		return false, "INVALID_JOIN_TOKEN", nil
	end
	return true, nil, entry
end

return table.freeze(ReservedLobbyService)
