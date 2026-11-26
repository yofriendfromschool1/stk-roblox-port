--!strict
-- src/server/ReservedLobbyService.lua
-- SPDX-License-Identifier: GPL-3.0-or-later
-- Roblox-only MemoryStoreService + TeleportService reserved-server lobby registry.
-- NOTE: Requires a published Roblox place (game.PlaceId > 0) and cannot execute ReserveServerAsync/TeleportAsync in Studio.

local MemoryStoreService = game:GetService("MemoryStoreService")
local RunService = game:GetService("RunService")
local TeleportService = game:GetService("TeleportService")

export type ReservedServerEntry = {
	lobbyId: string,
	accessCode: string,
	serverName: string,
	trackId: string,
	difficulty: string,
	raceType: string,
	maxPlayers: number,
	hasPassword: boolean,
	hostName: string,
	createdAt: number,
}

local REGISTRY_MAP_NAME = "OpenKartReservedLobbies_v1"
local ENTRY_TTL_SEC = 3600

local ReservedLobbyService = {}

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

function ReservedLobbyService.createReservedLobby(
	hostPlayer: Player,
	settings: { [string]: any }
): { ok: boolean, reason: string?, entry: ReservedServerEntry? }
	if not canUseLiveServices() then
		return {
			ok = false,
			reason = "PUBLISHED_PLACE_REQUIRED",
			entry = nil,
		}
	end

	local reserveOk, accessCode = pcall(function()
		return TeleportService:ReserveServerAsync(game.PlaceId)
	end)
	if not reserveOk or type(accessCode) ~= "string" then
		return {
			ok = false,
			reason = "RESERVE_FAILED",
			entry = nil,
		}
	end

	local lobbyId = string.format("%d_%d", hostPlayer.UserId, os.time())
	local entry: ReservedServerEntry = {
		lobbyId = lobbyId,
		accessCode = accessCode,
		serverName = settings.serverName,
		trackId = settings.trackId,
		difficulty = settings.difficulty,
		raceType = settings.raceType,
		maxPlayers = settings.maxPlayers,
		hasPassword = settings.hasPassword,
		hostName = hostPlayer.Name,
		createdAt = os.time(),
	}

	local map = getRegistryMap()
	if map ~= nil then
		pcall(function()
			map:SetAsync(lobbyId, entry, ENTRY_TTL_SEC)
		end)
	end

	return {
		ok = true,
		reason = nil,
		entry = entry,
	}
end

function ReservedLobbyService.listReservedLobbies(): { ok: boolean, reason: string?, entries: { ReservedServerEntry } }
	if not canUseLiveServices() then
		return {
			ok = false,
			reason = "PUBLISHED_PLACE_REQUIRED",
			entries = {},
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
	local out: { ReservedServerEntry } = {}
	for _, item in ipairs(items :: { { value: any } }) do
		if type(item.value) == "table" then
			local v = item.value :: ReservedServerEntry
			table.insert(out, {
				lobbyId = v.lobbyId,
				accessCode = "", -- never broadcast raw access code to clients in list view
				serverName = v.serverName,
				trackId = v.trackId,
				difficulty = v.difficulty,
				raceType = v.raceType,
				maxPlayers = v.maxPlayers,
				hasPassword = v.hasPassword,
				hostName = v.hostName,
				createdAt = v.createdAt,
			})
		end
	end
	return {
		ok = true,
		reason = nil,
		entries = out,
	}
end

function ReservedLobbyService.teleportToReservedLobby(player: Player, lobbyId: string): (boolean, string?)
	if not canUseLiveServices() then
		return false, "PUBLISHED_PLACE_REQUIRED"
	end
	local map = getRegistryMap()
	if map == nil then
		return false, "MEMORYSTORE_UNAVAILABLE"
	end
	local ok, entry = pcall(function()
		return map:GetAsync(lobbyId)
	end)
	if not ok or type(entry) ~= "table" or type((entry :: ReservedServerEntry).accessCode) ~= "string" then
		return false, "LOBBY_NOT_FOUND"
	end
	local opts = Instance.new("TeleportOptions");
	(opts :: any).ReservedServerAccessCode = (entry :: ReservedServerEntry).accessCode
	local tpOk = pcall(function()
		TeleportService:TeleportAsync(game.PlaceId, { player }, opts)
	end)
	if not tpOk then
		return false, "TELEPORT_FAILED"
	end
	return true, nil
end

return table.freeze(ReservedLobbyService)
