--!strict
-- src/shared/race/TestDummyKart.lua
-- SPDX-License-Identifier: GPL-3.0-or-later
-- Simulated second kart participant driven by AIController along the closed-loop arena driveline.

local AIController = require("../ai/AIController")
local GreyboxArenaData = require("../track/GreyboxArenaData")
local KartSolver = require("../sim/KartSolver")
local KartTuning = require("../KartTuning")
local Standings = require("./Standings")

local TestDummyKart = {}

TestDummyKart.DUMMY_KART_ID = -1
TestDummyKart.DUMMY_STRING_ID = "Dummy_1"
-- First waypoint of GreyboxArenaData.drivelineQuadCenters: (0, 6) heading +X directly ahead of player spawn (0, 0).
TestDummyKart.DEFAULT_SPAWN_X_METERS = 0.0
TestDummyKart.DEFAULT_SPAWN_Z_METERS = 6.0
TestDummyKart.DEFAULT_SPAWN_YAW_RAD = math.pi * 0.5
TestDummyKart.DEFAULT_CRUISE_SPEED_MPS = KartTuning.ai.defaultCruiseSpeedMps

export type RacerProgress = {
	id: string,
	state: KartSolver.KartState,
	initialPosition: number,
	aiState: AIController.AIState?,
}

function TestDummyKart.create(profile: KartTuning.KartProfile?, spawnZ: number?): KartSolver.KartState
	local prof = profile or KartTuning.buildProfile("medium", "best")
	local z = if spawnZ ~= nil then spawnZ else TestDummyKart.DEFAULT_SPAWN_Z_METERS
	local yaw = if spawnZ ~= nil then 0.0 else TestDummyKart.DEFAULT_SPAWN_YAW_RAD
	return KartSolver.createState(prof, { x = TestDummyKart.DEFAULT_SPAWN_X_METERS, y = 0.35, z = z }, yaw)
end

function TestDummyKart.createAIState(initialState: KartSolver.KartState): AIController.AIState
	return AIController.createState(GreyboxArenaData.drivelineQuadCenters, initialState.pos)
end

-- Lookahead steering along the closed driveline via ported STK AIController (ai_base_controller.cpp, skidding_ai.cpp).
function TestDummyKart.computeCruiseInput(
	state: KartSolver.KartState,
	aiState: AIController.AIState?,
	dt: number?,
	targetSpeedMps: number?
): KartSolver.KartInput
	local ai = aiState or AIController.createState(GreyboxArenaData.drivelineQuadCenters, state.pos)
	return AIController.computeInput(
		ai,
		state,
		GreyboxArenaData.drivelineQuadCenters,
		dt or (1.0 / 120.0),
		targetSpeedMps or TestDummyKart.DEFAULT_CRUISE_SPEED_MPS
	)
end

function TestDummyKart.buildStandingsEntries(racers: { RacerProgress }): { Standings.StandingsEntry }
	local pts = GreyboxArenaData.drivelineQuadCenters
	local entries: { Standings.StandingsEntry } = table.create(#racers)
	for _, r in racers do
		local lap = 0
		local checkpoint = 0
		local distance = 0.0
		if r.aiState ~= nil then
			lap = r.aiState.lap
			checkpoint = r.aiState.checkpoint
			distance = r.aiState.lapDistance
		else
			local nodeIdx, lapDist = AIController.computeTrackProgress(r.state.pos, pts)
			lap = 0
			checkpoint = math.floor(((nodeIdx - 1) * 4) / math.max(1, #pts))
			distance = lapDist
		end
		table.insert(entries, {
			id = r.id,
			lap = lap,
			checkpoint = checkpoint,
			distance = distance,
			initialPosition = r.initialPosition,
		})
	end
	return entries
end

return table.freeze(TestDummyKart)
