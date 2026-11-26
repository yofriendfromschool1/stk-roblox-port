--!strict
-- SPDX-License-Identifier: GPL-3.0-or-later
-- Client-side reactive store for UserSettings, synced with server SettingsStore.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local SettingsSchema = require(Shared.settings.SettingsSchema)

export type Listener = (settings: SettingsSchema.UserSettings) -> ()

local ClientSettingsState = {}

local current: SettingsSchema.UserSettings = SettingsSchema.defaults()
local persisted = false
local loaded = false
local listeners: { Listener } = {}

local function notify()
	for _, cb in ipairs(listeners) do
		cb(current)
	end
end

function ClientSettingsState.get(): SettingsSchema.UserSettings
	return current
end

function ClientSettingsState.isPersisted(): boolean
	return persisted
end

function ClientSettingsState.subscribe(cb: Listener): () -> ()
	table.insert(listeners, cb)
	cb(current)
	return function()
		local idx = table.find(listeners, cb)
		if idx then
			table.remove(listeners, idx)
		end
	end
end

function ClientSettingsState.update(mutator: (draft: SettingsSchema.UserSettings) -> ()): ()
	local draft = SettingsSchema.sanitize(current)
	mutator(draft)
	current = SettingsSchema.sanitize(draft)
	notify()
	task.spawn(function()
		local remotes = ReplicatedStorage:FindFirstChild("OpenKartRemotes")
		if not remotes then
			return
		end
		local rf = remotes:FindFirstChild("SettingsSync")
		if rf and rf:IsA("RemoteFunction") then
			local ok, res = pcall(function()
				return rf:InvokeServer("SAVE", current)
			end)
			if ok and type(res) == "table" and type(res.persisted) == "boolean" then
				persisted = res.persisted
			end
		end
	end)
end

function ClientSettingsState.loadFromServerAsync(): ()
	if loaded then
		return
	end
	loaded = true
	task.spawn(function()
		local remotes = ReplicatedStorage:WaitForChild("OpenKartRemotes", 10)
		if not remotes then
			return
		end
		local rf = remotes:WaitForChild("SettingsSync", 10)
		if rf and rf:IsA("RemoteFunction") then
			local ok, res = pcall(function()
				return rf:InvokeServer("LOAD")
			end)
			if ok and type(res) == "table" and res.settings ~= nil then
				current = SettingsSchema.sanitize(res.settings)
				persisted = res.persisted == true
				notify()
			end
		end
	end)
end

return ClientSettingsState
