--!strict
-- SPDX-License-Identifier: GPL-3.0-or-later
-- Server-side DataStore persistence for player settings with session-only fallback.

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local SettingsSchema = require(Shared.settings.SettingsSchema)

local SettingsStore = {}

local DATASTORE_NAME = "OpenKartPlayerSettings_v1"
local store: DataStore? = nil
local storeAvailable = false
local sessionCache: { [number]: SettingsSchema.UserSettings } = {}
local saveListeners: { (player: Player, settings: SettingsSchema.UserSettings) -> () } = {}

local function tryGetStore(): DataStore?
	if store ~= nil then
		return store
	end
	local ok, ds = pcall(function()
		return DataStoreService:GetDataStore(DATASTORE_NAME)
	end)
	if ok and ds ~= nil then
		store = ds
		storeAvailable = true
	else
		storeAvailable = false
	end
	return store
end

function SettingsStore.isPersistent(): boolean
	tryGetStore()
	return storeAvailable
end

function SettingsStore.loadForPlayer(player: Player): (SettingsSchema.UserSettings, boolean)
	local cached = sessionCache[player.UserId]
	if cached ~= nil then
		return cached, storeAvailable
	end
	local ds = tryGetStore()
	if ds ~= nil then
		local key = "u_" .. tostring(player.UserId)
		local ok, raw = pcall(function()
			return ds:GetAsync(key)
		end)
		if ok then
			local sanitized = SettingsSchema.sanitize(raw)
			sessionCache[player.UserId] = sanitized
			return sanitized, true
		end
	end
	local fallback = SettingsSchema.defaults()
	sessionCache[player.UserId] = fallback
	return fallback, false
end

function SettingsStore.getCachedVariantName(player: Player): SettingsSchema.SkinVariantName
	local cached = sessionCache[player.UserId]
	if cached ~= nil then
		return cached.ui.skinVariant
	end
	return "Peach"
end

function SettingsStore.onSettingsSaved(cb: (player: Player, settings: SettingsSchema.UserSettings) -> ()): () -> ()
	table.insert(saveListeners, cb)
	return function()
		local idx = table.find(saveListeners, cb)
		if idx then
			table.remove(saveListeners, idx)
		end
	end
end

function SettingsStore.saveForPlayer(player: Player, raw: any): (SettingsSchema.UserSettings, boolean)
	local sanitized = SettingsSchema.sanitize(raw)
	sessionCache[player.UserId] = sanitized
	for _, cb in ipairs(saveListeners) do
		cb(player, sanitized)
	end
	local ds = tryGetStore()
	if ds ~= nil then
		local key = "u_" .. tostring(player.UserId)
		local ok = pcall(function()
			ds:SetAsync(key, sanitized)
		end)
		return sanitized, ok
	end
	return sanitized, false
end

function SettingsStore.bindRemotes(remotesFolder: Folder)
	local existing = remotesFolder:FindFirstChild("SettingsSync")
	local rf: RemoteFunction = if existing and existing:IsA("RemoteFunction")
		then existing
		else Instance.new("RemoteFunction")
	rf.Name = "SettingsSync"
	rf.Parent = remotesFolder

	rf.OnServerInvoke = function(player: Player, action: any, payload: any): any
		if action == "LOAD" then
			local settings, persisted = SettingsStore.loadForPlayer(player)
			return {
				settings = settings,
				persisted = persisted,
			}
		elseif action == "SAVE" then
			local settings, persisted = SettingsStore.saveForPlayer(player, payload)
			return {
				settings = settings,
				persisted = persisted,
			}
		end
		return nil
	end

	Players.PlayerRemoving:Connect(function(player: Player)
		sessionCache[player.UserId] = nil
	end)
end

return SettingsStore
