--!strict
-- src/shared/sim/EdgeRescue.lua
-- SPDX-License-Identifier: GPL-3.0-or-later
-- Instant off-track / edge rescue detector.
-- Upstream STK 1.5 (src/karts/kart.cpp:L1696-L1708) rescues when !material and
-- (min->getY() - y > 17 || dist_to_sector > 25); this module triggers earlier
-- when airborne + descending past grace ticks with no drivable surface within
-- RESCUE_PROBE_DEPTH_M below (divergence logged in docs/divergences.md).

local SurfaceMaterials = require("../track/SurfaceMaterials")

export type EdgeRescueInput = {
	numWheelsGrounded: number,
	pos: { x: number, y: number, z: number },
	linVelY: number,
	airborneDescentTicks: number,
	racePhase: string,
	isRescuing: boolean,
	hasItemAnimation: boolean,
	worldQuery: any?,
}

local EdgeRescue = {}

EdgeRescue.RESCUE_PROBE_DEPTH_M = 8.0
EdgeRescue.AIRBORNE_GRACE_TICKS = 30 -- 0.25 s at 120 Hz
EdgeRescue.MIN_FALL_VEL_MPS = -3.0

local DOWN_DIR = { x = 0, y = -1, z = 0 }

function EdgeRescue.evaluate(params: EdgeRescueInput): (boolean, number)
	if
		params.numWheelsGrounded > 0
		or params.isRescuing
		or params.hasItemAnimation
		or not (params.racePhase == "RACE_PHASE" or params.racePhase == "GO_PHASE" or params.racePhase == "DELAY_FINISH_PHASE")
		or params.linVelY >= EdgeRescue.MIN_FALL_VEL_MPS
	then
		return false, 0
	end

	local nextTicks = params.airborneDescentTicks + 1
	if nextTicks < EdgeRescue.AIRBORNE_GRACE_TICKS then
		return false, nextTicks
	end

	if params.worldQuery ~= nil then
		local hit = params.worldQuery.raycast(params.pos, DOWN_DIR, EdgeRescue.RESCUE_PROBE_DEPTH_M)
		if hit ~= nil then
			local mat = SurfaceMaterials.get(hit.materialName)
			if not mat.reset and mat.collisionReaction ~= "reset" then
				return false, nextTicks
			end
		end
	end

	return true, nextTicks
end

return EdgeRescue
