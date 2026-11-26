--!strict
-- src/shared/race/CheckManager.lua
-- SPDX-License-Identifier: GPL-3.0-or-later
-- ported from src/tracks/check_manager.cpp, src/tracks/check_structure.cpp:L45-L75, L220-L247,
-- src/tracks/check_line.cpp:L86-L230, and src/modes/linear_world.cpp:L376-L526 (STK 1.5).
-- Pure-Luau ordered checkpoint & lap validator (zero Roblox API).

local TrackRegistry = require("../track/TrackRegistry")

export type KartCheckProgress = {
	lap: number,
	nextCheckpoint: number,
	raceFinished: boolean,
	finishTick: number,
}

export type CheckpointGraph = {
	byGroup: { [number]: { TrackRegistry.CheckpointSpec } },
	maxActivateGroup: number,
	lapGroupId: number,
}

local UNDER_MIN_HEIGHT_M = 1.0 -- check_line.cpp:L86
local OVER_MIN_HEIGHT_M = 4.0 -- check_line.cpp:L90
local ENDPOINT_EPS = 1e-4

local CheckManager = {}

local function cross2d(ax: number, az: number, bx: number, bz: number, cx: number, cz: number): number
	return (bx - ax) * (cz - az) - (bz - az) * (cx - ax)
end

local function onSegment2d(ax: number, az: number, bx: number, bz: number, px: number, pz: number): boolean
	return px >= math.min(ax, bx) - ENDPOINT_EPS
		and px <= math.max(ax, bx) + ENDPOINT_EPS
		and pz >= math.min(az, bz) - ENDPOINT_EPS
		and pz <= math.max(az, bz) + ENDPOINT_EPS
end

-- 2D XZ segment intersection between (pOld -> pNew) and check-line (c1 -> c2),
-- with STK CheckLine vertical tolerance [-1.0 m, +4.0 m] (check_line.cpp:L86-L90).
function CheckManager.crossesCheckLine(
	oldX: number,
	oldY: number,
	oldZ: number,
	newX: number,
	newY: number,
	newZ: number,
	chk: TrackRegistry.CheckpointSpec
): boolean
	local minY = math.min(chk.p1.y, chk.p2.y) - UNDER_MIN_HEIGHT_M
	local maxY = math.max(chk.p1.y, chk.p2.y) + OVER_MIN_HEIGHT_M
	if (oldY < minY and newY < minY) or (oldY > maxY and newY > maxY) then
		return false
	end

	local c1x, c1z = chk.p1.x, chk.p1.z
	local c2x, c2z = chk.p2.x, chk.p2.z

	local d1 = cross2d(c1x, c1z, c2x, c2z, oldX, oldZ)
	local d2 = cross2d(c1x, c1z, c2x, c2z, newX, newZ)
	local d3 = cross2d(oldX, oldZ, newX, newZ, c1x, c1z)
	local d4 = cross2d(oldX, oldZ, newX, newZ, c2x, c2z)

	if ((d1 > 0 and d2 < 0) or (d1 < 0 and d2 > 0)) and ((d3 > 0 and d4 < 0) or (d3 < 0 and d4 > 0)) then
		return true
	end
	if math.abs(d1) <= ENDPOINT_EPS and onSegment2d(c1x, c1z, c2x, c2z, oldX, oldZ) then
		return true
	end
	if math.abs(d2) <= ENDPOINT_EPS and onSegment2d(c1x, c1z, c2x, c2z, newX, newZ) then
		return true
	end
	if math.abs(d3) <= ENDPOINT_EPS and onSegment2d(oldX, oldZ, newX, newZ, c1x, c1z) then
		return true
	end
	if math.abs(d4) <= ENDPOINT_EPS and onSegment2d(oldX, oldZ, newX, newZ, c2x, c2z) then
		return true
	end
	return false
end

function CheckManager.buildGraph(checkpoints: { TrackRegistry.CheckpointSpec }): CheckpointGraph
	local byGroup: { [number]: { TrackRegistry.CheckpointSpec } } = {}
	local maxActivateGroup = 0
	for _, chk in checkpoints do
		local groupId = if chk.kind == "lap" then 0 else chk.id
		local list = byGroup[groupId]
		if list == nil then
			list = {}
			byGroup[groupId] = list
		end
		table.insert(list, chk)
		if chk.kind ~= "lap" and groupId > maxActivateGroup then
			maxActivateGroup = groupId
		end
	end
	return {
		byGroup = byGroup,
		maxActivateGroup = maxActivateGroup,
		lapGroupId = 0,
	}
end

-- Determines whether a kart spawns behind the lap line (lap = -1, nextCheckpoint = 0)
-- or already past it along start forward (lap = 0, nextCheckpoint = 1).
function CheckManager.initKartProgress(
	checkpoints: { TrackRegistry.CheckpointSpec },
	startPos: { x: number, y: number, z: number },
	startYawRad: number?
): KartCheckProgress
	local lapChk: TrackRegistry.CheckpointSpec? = nil
	for _, chk in checkpoints do
		if chk.kind == "lap" then
			lapChk = chk
			break
		end
	end
	local initialLap = -1
	local initialNext = 0
	if lapChk ~= nil then
		local yaw = startYawRad or 0.0
		local fwdX = math.sin(yaw)
		local fwdZ = math.cos(yaw)
		local midX = 0.5 * (lapChk.p1.x + lapChk.p2.x)
		local midZ = 0.5 * (lapChk.p1.z + lapChk.p2.z)
		local relDot = (startPos.x - midX) * fwdX + (startPos.z - midZ) * fwdZ
		if relDot >= 0.0 then
			initialLap = 0
			initialNext = if #checkpoints > 1 then 1 else 0
		end
	else
		initialLap = 0
		initialNext = 0
	end
	return {
		lap = initialLap,
		nextCheckpoint = initialNext,
		raceFinished = false,
		finishTick = -1,
	}
end

local function resolveNextGroup(
	chk: TrackRegistry.CheckpointSpec,
	checkpoints: { TrackRegistry.CheckpointSpec }
): number
	for _, targetId in chk.otherIds do
		for _, candidate in checkpoints do
			if candidate.id == targetId then
				return if candidate.kind == "lap" then 0 else candidate.id
			end
		end
	end
	return 0
end

-- Evaluates movement from prevPos -> currPos against the kart's currently active checkpoint group.
-- Returns (changed: boolean, lapIncremented: boolean, justFinished: boolean).
function CheckManager.stepKart(
	progress: KartCheckProgress,
	checkpoints: { TrackRegistry.CheckpointSpec },
	prevPos: { x: number, y: number, z: number },
	currPos: { x: number, y: number, z: number },
	raceTick: number,
	totalLaps: number
): (boolean, boolean, boolean)
	if #checkpoints == 0 then
		return false, false, false
	end
	local graph = CheckManager.buildGraph(checkpoints)
	local activeList = graph.byGroup[progress.nextCheckpoint]
	if activeList == nil then
		return false, false, false
	end

	for _, chk in activeList do
		if CheckManager.crossesCheckLine(prevPos.x, prevPos.y, prevPos.z, currPos.x, currPos.y, currPos.z, chk) then
			local nextGroup = resolveNextGroup(chk, checkpoints)
			if progress.nextCheckpoint == 0 then
				local lapIncremented = false
				local justFinished = false
				if not progress.raceFinished then
					progress.lap += 1
					lapIncremented = true
					if progress.lap >= totalLaps then
						progress.raceFinished = true
						progress.finishTick = raceTick
						justFinished = true
					end
				end
				progress.nextCheckpoint = if graph.maxActivateGroup > 0 then nextGroup else 0
				return true, lapIncremented, justFinished
			else
				progress.nextCheckpoint = nextGroup
				return true, false, false
			end
		end
	end

	return false, false, false
end

-- Converts active nextCheckpoint into a monotonic integer within a lap for Standings.compute:
-- pre-start (lap < 0) -> 0; post-last-activate (nextCheckpoint == 0, lap >= 0) -> maxActivateGroup + 1;
-- otherwise nextCheckpoint.
function CheckManager.getMonotonicCheckpoint(
	lap: number,
	nextCheckpoint: number,
	checkpoints: { TrackRegistry.CheckpointSpec }
): number
	if lap < 0 then
		return 0
	end
	local graph = CheckManager.buildGraph(checkpoints)
	if nextCheckpoint == 0 then
		return graph.maxActivateGroup + 1
	end
	return nextCheckpoint
end

return table.freeze(CheckManager)
