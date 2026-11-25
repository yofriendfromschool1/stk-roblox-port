--!strict
-- src/client/HudState.lua
-- SPDX-License-Identifier: GPL-3.0-or-later
-- Holds the latest per-frame interpolated render state published by GreyboxKartClient
-- so GameHud never binds directly to raw snapshots or un-interpolated physics steps.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local RaceHudMath = require(Shared.hud.RaceHudMath)

export type InterpolatedHudState = {
	ready: boolean,
	pos: RaceHudMath.Point2D,
	speedMps: number,
	maxSpeedMps: number,
	nitroEnergy: number,
	nitroMaxEnergy: number,
	nitroUsing: boolean,
	heldPowerup: number,
	heldPowerupCount: number,
	raceMode: RaceHudMath.RaceMode,
	raceStartServerTime: number,
	lap: number,
	checkpoint: number,
	distance: number,
}

local currentState: InterpolatedHudState = {
	ready = false,
	pos = { x = 0.0, z = 0.0 },
	speedMps = 0.0,
	maxSpeedMps = 25.0,
	nitroEnergy = 0.0,
	nitroMaxEnergy = 20.0,
	nitroUsing = false,
	heldPowerup = 0,
	heldPowerupCount = 0,
	raceMode = "TIME_TRIAL",
	raceStartServerTime = 0.0,
	lap = 0,
	checkpoint = 0,
	distance = 0.0,
}

local HudState = {}

function HudState.publish(
	posX: number,
	posZ: number,
	speedMps: number,
	maxSpeedMps: number,
	nitroEnergy: number,
	nitroMaxEnergy: number,
	nitroUsing: boolean,
	raceMode: RaceHudMath.RaceMode,
	raceStartServerTime: number,
	lap: number,
	checkpoint: number,
	distance: number,
	heldPowerup: number?,
	heldPowerupCount: number?
)
	currentState.ready = true
	currentState.pos.x = posX
	currentState.pos.z = posZ
	currentState.speedMps = speedMps
	currentState.maxSpeedMps = maxSpeedMps
	currentState.nitroEnergy = nitroEnergy
	currentState.nitroMaxEnergy = nitroMaxEnergy
	currentState.nitroUsing = nitroUsing
	currentState.heldPowerup = heldPowerup or 0
	currentState.heldPowerupCount = heldPowerupCount or 0
	currentState.raceMode = raceMode
	currentState.raceStartServerTime = raceStartServerTime
	currentState.lap = lap
	currentState.checkpoint = checkpoint
	currentState.distance = distance
end

function HudState.get(): InterpolatedHudState
	return currentState
end

return HudState
