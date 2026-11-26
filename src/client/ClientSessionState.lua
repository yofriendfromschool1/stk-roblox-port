--!strict
-- SPDX-License-Identifier: GPL-3.0-or-later
-- Shared client state bridging MenuGui, GreyboxKartClient, and GameHud.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local MenuFlow = require(Shared.menu.MenuFlow)

export type SessionPhase = "MENU" | "LOADING" | "RACING"

export type ReplicatedSessionState = {
	phase: SessionPhase,
	config: MenuFlow.SessionConfig,
	localP2Active: boolean,
}

local ClientSessionState = {}

local current: ReplicatedSessionState = {
	phase = "MENU",
	config = MenuFlow.sanitizeSessionConfig(nil),
	localP2Active = false,
}

local listeners: { (state: ReplicatedSessionState) -> () } = {}

function ClientSessionState.get(): ReplicatedSessionState
	return current
end

function ClientSessionState.set(nextState: ReplicatedSessionState): ()
	current = nextState
	for _, cb in ipairs(listeners) do
		cb(current)
	end
end

function ClientSessionState.subscribe(cb: (state: ReplicatedSessionState) -> ()): () -> ()
	table.insert(listeners, cb)
	cb(current)
	return function()
		local idx = table.find(listeners, cb)
		if idx then
			table.remove(listeners, idx)
		end
	end
end

return ClientSessionState
