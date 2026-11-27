--!strict
-- SPDX-License-Identifier: GPL-3.0-or-later
-- Client-side reactive store for UserSettings, synced with server SettingsStore.

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local SettingsSchema = require(Shared.settings.SettingsSchema)

export type Listener = (settings: SettingsSchema.UserSettings) -> ()

local ClientSettingsState = {}

local current: SettingsSchema.UserSettings = SettingsSchema.defaults()
local persisted = false
local loaded = false
local listeners: { Listener } = {}
local debugHookBound = false

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
	if RunService:IsStudio() and not debugHookBound then
		debugHookBound = true
		local lp = Players.LocalPlayer
		if lp ~= nil then
			lp:GetAttributeChangedSignal("OpenKartDebugApplySettingsJson"):Connect(function()
				local rawJson = lp:GetAttribute("OpenKartDebugApplySettingsJson")
				if type(rawJson) == "string" and #rawJson > 0 then
					local ok, decoded = pcall(function()
						return HttpService:JSONDecode(rawJson)
					end)
					if ok and type(decoded) == "table" then
						ClientSettingsState.update(function(draft)
							local merged = SettingsSchema.sanitize(decoded)
							draft.graphics = merged.graphics
							draft.audio = merged.audio
							draft.ui = merged.ui
							draft.input = merged.input
						end)
					end
				end
			end)
		end
	end
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
