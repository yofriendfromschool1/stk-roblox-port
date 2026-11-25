--!strict
-- src/shared/race/TestDummyKart.lua
-- SPDX-License-Identifier: GPL-3.0-or-later
-- Deterministic driveline-following second test kart for Standings and projectile/item targeting.

local KartSolver = require("../sim/KartSolver")
local KartTuning = require("../KartTuning")
local Math3D = require("../sim/Math3D")
local Standings = require("./Standings")

local TestDummyKart = {}

TestDummyKart.DUMMY_KART_ID = -1
TestDummyKart.DUMMY_STRING_ID = "Dummy_1"
TestDummyKart.DEFAULT_SPAWN_Z_METERS = 32.0
TestDummyKart.DEFAULT_CRUISE_SPEED_MPS = 10.0

export type RacerProgress = {
	id: string,
	state: KartSolver.KartState,
	initialPosition: number,
}

function TestDummyKart.create(profile: KartTuning.KartProfile?, spawnZ: number?): KartSolver.KartState
	local prof = profile or KartTuning.buildProfile("medium", "best")
	local z = spawnZ or TestDummyKart.DEFAULT_SPAWN_Z_METERS
	return KartSolver.createState(prof, { x = 0, y = 0.35, z = z }, 0)
end

-- Simple deterministic controller that cruises along the arena driveline center at fixed speed.
function TestDummyKart.computeCruiseInput(state: KartSolver.KartState, targetSpeedMps: number?): KartSolver.KartInput
	local targetSpeed = targetSpeedMps or TestDummyKart.DEFAULT_CRUISE_SPEED_MPS
	-- Keep dummy on main straight driveline center (x = 0)
	local _, _, fwd = Math3D.quatBasis(state.rot)
	local yawErr = math.atan2(-state.pos.x * 0.08 - fwd.x, math.max(0.2, fwd.z))
	local steer = math.clamp(-yawErr * 1.5, -1.0, 1.0)
	local accel = if state.speed < targetSpeed then 0.65 else 0.0
	return {
		accel = accel,
		brake = false,
		steer = steer,
		drift = false,
		nitro = false,
		fire = false,
		lookBack = false,
	}
end

function TestDummyKart.loopIfPastEnd(state: KartSolver.KartState, resetZ: number?)
	if state.pos.z > 180.0 then
		state.pos = { x = 0.0, y = 0.35, z = resetZ or -160.0 }
		state.lastSafePos = { x = state.pos.x, y = state.pos.y, z = state.pos.z }
		state.rot = Math3D.quatIdentity()
		state.lastSafeRot = Math3D.quatIdentity()
	end
end

function TestDummyKart.buildStandingsEntries(racers: { RacerProgress }): { Standings.StandingsEntry }
	local entries: { Standings.StandingsEntry } = table.create(#racers)
	for _, r in racers do
		table.insert(entries, {
			id = r.id,
			lap = 0,
			checkpoint = 0,
			distance = r.state.pos.z,
			initialPosition = r.initialPosition,
		})
	end
	return entries
end

return table.freeze(TestDummyKart)
