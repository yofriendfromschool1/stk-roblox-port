--!strict
-- src/client/HudState.lua
-- SPDX-License-Identifier: GPL-3.0-or-later
-- Holds the latest per-frame interpolated render state published by GreyboxKartClient
-- so GameHud never binds directly to raw snapshots or un-interpolated physics steps.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local RaceHudMath = require(Shared.hud.RaceHudMath)
local Standings = require(Shared.race.Standings)

export type RemoteMinimapPose = {
	id: string,
	x: number,
	z: number,
}

export type InterpolatedHudState = {
	ready: boolean,
	pos: RaceHudMath.Point2D,
	speedMps: number,
	maxSpeedMps: number,
	nitroEnergy: number,
	nitroMaxEnergy: number,
	nitroUsing: boolean,
	nitroGateOpen: boolean,
	heldPowerup: number,
	heldPowerupCount: number,
	plungerFaceTicks: number,
	standingsEntries: { Standings.StandingsEntry }?,
	remotePoses: { RemoteMinimapPose }?,
	localKartId: number,
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
	nitroGateOpen = true,
	heldPowerup = 0,
	heldPowerupCount = 0,
	plungerFaceTicks = 0,
	standingsEntries = nil,
	remotePoses = nil,
	localKartId = 1,
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
	heldPowerupCount: number?,
	nitroGateOpen: boolean?,
	plungerFaceTicks: number?,
	standingsEntries: { Standings.StandingsEntry }?,
	remotePoses: { RemoteMinimapPose }?,
	localKartId: number?
)
	currentState.ready = true
	currentState.pos.x = posX
	currentState.pos.z = posZ
	currentState.speedMps = speedMps
	currentState.maxSpeedMps = maxSpeedMps
	currentState.nitroEnergy = nitroEnergy
	currentState.nitroMaxEnergy = nitroMaxEnergy
	currentState.nitroUsing = nitroUsing
	currentState.nitroGateOpen = if nitroGateOpen ~= nil then nitroGateOpen else true
	currentState.heldPowerup = heldPowerup or 0
	currentState.heldPowerupCount = heldPowerupCount or 0
	currentState.plungerFaceTicks = plungerFaceTicks or 0
	currentState.standingsEntries = standingsEntries
	currentState.remotePoses = remotePoses
	currentState.localKartId = localKartId or 1
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
