--!strict
-- src/shared/race/CheckManager.lua
-- SPDX-License-Identifier: GPL-3.0-or-later
-- ported from src/tracks/check_manager.cpp, src/tracks/check_structure.cpp:L45-L75, L220-L247,
-- src/tracks/check_line.cpp:L86-L230, and src/modes/linear_world.cpp:L376-L526 (STK 1.5).
-- Pure-Luau ordered checkpoint & lap validator (zero Roblox API).

local SurfaceMaterials = require("../track/SurfaceMaterials")
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

export type RescueWorldQuery = {
	raycast: (origin: any, dir: any, length: number) -> any?,
}

local function segmentIntersect2D(
	ax: number,
	az: number,
	bx: number,
	bz: number,
	cx: number,
	cz: number,
	dx: number,
	dz: number
): (boolean, number, number)
	local rx = bx - ax
	local rz = bz - az
	local sx = dx - cx
	local sz = dz - cz
	local denom = rx * sz - rz * sx
	if math.abs(denom) <= 1e-8 then
		return false, 0, 0
	end
	local qpx = cx - ax
	local qpz = cz - az
	local t = (qpx * sz - qpz * sx) / denom
	local u = (qpx * rz - qpz * rx) / denom
	if t >= -1e-4 and t <= 1.0 + 1e-4 and u >= -1e-4 and u <= 1.0 + 1e-4 then
		return true, ax + t * rx, az + t * rz
	end
	return false, 0, 0
end

-- Computes rescue placement at the last crossed checkline (nextCheckpoint - 1),
-- oriented along the driveline tangent at that checkline.
function CheckManager.getRescuePose(
	checkpoints: { TrackRegistry.CheckpointSpec },
	lap: number,
	nextCheckpoint: number,
	drivelinePoints: { { x: number, y: number?, z: number } },
	startPos: { x: number, y: number, z: number },
	startYawRad: number?,
	worldQuery: RescueWorldQuery?,
	kartHeightMeters: number?
): ({ x: number, y: number, z: number }, number, number)
	local fallbackYaw = startYawRad or 0.0
	if #checkpoints == 0 or (lap < 0 and nextCheckpoint == 0) then
		return { x = startPos.x, y = startPos.y, z = startPos.z }, fallbackYaw, -1
	end

	local graph = CheckManager.buildGraph(checkpoints)
	local lastCrossedGroup = if nextCheckpoint == 0 then graph.maxActivateGroup else (nextCheckpoint - 1)
	local candidates = graph.byGroup[lastCrossedGroup]
	if candidates == nil or #candidates == 0 then
		return { x = startPos.x, y = startPos.y, z = startPos.z }, fallbackYaw, -1
	end

	-- Pick primary checkline in group (lowest id so group 0 selects main lap line id=0).
	local chk = candidates[1]
	for i = 2, #candidates do
		if candidates[i].id < chk.id then
			chk = candidates[i]
		end
	end

	local ix = 0.5 * (chk.p1.x + chk.p2.x)
	local iz = 0.5 * (chk.p1.z + chk.p2.z)
	local yawRad = fallbackYaw
	local nDriveline = #drivelinePoints
	local foundIntersection = false

	if nDriveline >= 2 then
		for i = 1, nDriveline do
			local nextI = if i == nDriveline then 1 else i + 1
			local a = drivelinePoints[i]
			local b = drivelinePoints[nextI]
			local hit, hx, hz = segmentIntersect2D(a.x, a.z, b.x, b.z, chk.p1.x, chk.p1.z, chk.p2.x, chk.p2.z)
			if hit then
				ix = hx
				iz = hz
				local dx = b.x - a.x
				local dz = b.z - a.z
				if dx * dx + dz * dz > 1e-8 then
					yawRad = math.atan2(dx, dz)
				end
				foundIntersection = true
				break
			end
		end

		if not foundIntersection then
			local bestDistSq = math.huge
			local bestIdx = 1
			for i = 1, nDriveline do
				local pt = drivelinePoints[i]
				local dx = pt.x - ix
				local dz = pt.z - iz
				local d2 = dx * dx + dz * dz
				if d2 < bestDistSq then
					bestDistSq = d2
					bestIdx = i
				end
			end
			local prevIdx = if bestIdx == 1 then nDriveline else bestIdx - 1
			local nextIdx = if bestIdx == nDriveline then 1 else bestIdx + 1
			local dx = drivelinePoints[nextIdx].x - drivelinePoints[prevIdx].x
			local dz = drivelinePoints[nextIdx].z - drivelinePoints[prevIdx].z
			if dx * dx + dz * dz > 1e-8 then
				yawRad = math.atan2(dx, dz)
			end
		end
	end

	-- Interpolate checkline endpoint height at (ix, iz).
	local segDx = chk.p2.x - chk.p1.x
	local segDz = chk.p2.z - chk.p1.z
	local segLenSq = segDx * segDx + segDz * segDz
	local tSeg = if segLenSq > 1e-8
		then math.clamp(((ix - chk.p1.x) * segDx + (iz - chk.p1.z) * segDz) / segLenSq, 0, 1)
		else 0.5
	local baseY = chk.p1.y + (chk.p2.y - chk.p1.y) * tSeg
	local halfH = 0.5 * (kartHeightMeters or 0.7)
	local targetY = baseY + halfH

	if worldQuery ~= nil then
		local hit = worldQuery.raycast({ x = ix, y = baseY + 6.0, z = iz }, { x = 0, y = -1, z = 0 }, 16.0)
		if hit ~= nil then
			targetY = hit.point.y + halfH
		end
	end

	return { x = ix, y = targetY, z = iz }, yawRad, lastCrossedGroup
end

-- Maps a checkline group id to the driveline quad index where the driveline crosses it
-- (or nearest driveline node if no segment intersects).
function CheckManager.getCheckpointQuadIndex(
	checkpoints: { TrackRegistry.CheckpointSpec },
	groupId: number,
	drivelinePoints: { { x: number, y: number?, z: number } }
): number?
	local nDriveline = #drivelinePoints
	if nDriveline == 0 or #checkpoints == 0 then
		return nil
	end
	local graph = CheckManager.buildGraph(checkpoints)
	local candidates = graph.byGroup[groupId]
	if candidates == nil or #candidates == 0 then
		return nil
	end
	local chk = candidates[1]
	for i = 2, #candidates do
		if candidates[i].id < chk.id then
			chk = candidates[i]
		end
	end
	if nDriveline >= 2 then
		for i = 1, nDriveline do
			local nextI = if i == nDriveline then 1 else i + 1
			local a = drivelinePoints[i]
			local b = drivelinePoints[nextI]
			local hit = segmentIntersect2D(a.x, a.z, b.x, b.z, chk.p1.x, chk.p1.z, chk.p2.x, chk.p2.z)
			if hit then
				return i
			end
		end
	end
	local mx = 0.5 * (chk.p1.x + chk.p2.x)
	local mz = 0.5 * (chk.p1.z + chk.p2.z)
	local bestIdx = 1
	local bestDistSq = math.huge
	for i = 1, nDriveline do
		local pt = drivelinePoints[i]
		local dx = pt.x - mx
		local dz = pt.z - mz
		local d2 = dx * dx + dz * dz
		if d2 < bestDistSq then
			bestDistSq = d2
			bestIdx = i
		end
	end
	return bestIdx
end

-- Computes driveline quad center pose & tangent heading (src/modes/linear_world.cpp:L854-L868,
-- src/tracks/drive_node.cpp:L81-L83, src/modes/world.cpp:L938-L939).
-- Target Y comes directly from the driveline quad center (never current state Y or a fresh downward raycast).
function CheckManager.computeDrivelineQuadPose(
	drivelinePoints: { { x: number, y: number?, z: number } },
	quadIdx: number,
	fallbackY: number?,
	_worldQuery: RescueWorldQuery?,
	kartHeightMeters: number?
): ({ x: number, y: number, z: number }, number, boolean)
	local n = #drivelinePoints
	if n == 0 then
		return { x = 0, y = fallbackY or 0.0, z = 0 }, 0.0, false
	end
	local idx = ((quadIdx - 1) % n) + 1
	local center = drivelinePoints[idx]
	local nextIdx = (idx % n) + 1
	local nextPt = drivelinePoints[nextIdx]
	local dx = nextPt.x - center.x
	local dz = nextPt.z - center.z
	local yawRad = if (dx * dx + dz * dz) > 1e-8 then math.atan2(dx, dz) else 0.0
	local halfH = 0.5 * (kartHeightMeters or 0.7)
	local quadY = if type(center.y) == "number" then center.y :: number else (fallbackY or 0.0)
	local targetY = quadY + halfH

	return { x = center.x, y = targetY, z = center.z }, yawRad, true
end

-- Checkline-requirement clamp matching TrackSector::update (src/tracks/track_sector.cpp:L91-L118):
-- returns true iff quadIdx is within the active sector [prevChecklineQuad, nextChecklineQuad).
function CheckManager.isQuadAllowedForProgress(
	quadIdx: number,
	lap: number,
	nextCheckpoint: number,
	checkpoints: { TrackRegistry.CheckpointSpec },
	drivelinePoints: { { x: number, y: number?, z: number } }
): boolean
	if #drivelinePoints == 0 or #checkpoints == 0 then
		return true
	end
	if lap < 0 and nextCheckpoint == 0 then
		return false
	end
	local graph = CheckManager.buildGraph(checkpoints)
	local nextQ = CheckManager.getCheckpointQuadIndex(checkpoints, nextCheckpoint, drivelinePoints)
	local prevGroup = if nextCheckpoint == 0 then graph.maxActivateGroup else (nextCheckpoint - 1)
	local prevQ = CheckManager.getCheckpointQuadIndex(checkpoints, prevGroup, drivelinePoints)
	if prevQ == nil or nextQ == nil then
		return true
	end
	if prevQ < nextQ then
		return quadIdx >= prevQ and quadIdx < nextQ
	end
	return quadIdx >= prevQ or quadIdx < nextQ
end

function CheckManager.findNearestQuadIndex(
	drivelinePoints: { { x: number, y: number?, z: number } },
	x: number,
	z: number,
	hintQuadIdx: number?
): (number, number)
	local n = #drivelinePoints
	if n == 0 then
		return 0, math.huge
	end
	local bestIdx = 1
	local bestDistSq = math.huge
	local bestHintDist = math.huge
	for i = 1, n do
		local pt = drivelinePoints[i]
		local dx = pt.x - x
		local dz = pt.z - z
		local d2 = dx * dx + dz * dz
		if d2 < bestDistSq - 1e-6 then
			bestDistSq = d2
			bestIdx = i
			bestHintDist = if hintQuadIdx ~= nil then math.abs(i - hintQuadIdx) else 0
		elseif hintQuadIdx ~= nil and math.abs(d2 - bestDistSq) <= 1e-6 then
			local hd = math.abs(i - hintQuadIdx)
			if hd < bestHintDist then
				bestIdx = i
				bestHintDist = hd
			end
		end
	end
	return bestIdx, bestDistSq
end

-- Resolves rescue placement from recorded lastRescuePose, clamped so placement is never ahead of nextCheckpoint.
-- When lastRescuePose is unrecorded (lastRescueQuadIdx <= 0), falls back to the nearest driveline quad center
-- on the active track (never origin or StartPositions).
function CheckManager.resolveClampedRescuePose(
	lastRescueQuadIdx: number,
	lastRescuePos: { x: number, y: number, z: number },
	lastRescueYawRad: number,
	checkpoints: { TrackRegistry.CheckpointSpec },
	lap: number,
	nextCheckpoint: number,
	drivelinePoints: { { x: number, y: number?, z: number } },
	startPos: { x: number, y: number, z: number },
	startYawRad: number?,
	_worldQuery: RescueWorldQuery?,
	kartHeightMeters: number?,
	currentPos: { x: number, y: number, z: number }?
): ({ x: number, y: number, z: number }, number, number)
	if
		lastRescueQuadIdx > 0
		and CheckManager.isQuadAllowedForProgress(lastRescueQuadIdx, lap, nextCheckpoint, checkpoints, drivelinePoints)
	then
		return { x = lastRescuePos.x, y = lastRescuePos.y, z = lastRescuePos.z }, lastRescueYawRad, lastRescueQuadIdx
	end
	local n = #drivelinePoints
	if lastRescueQuadIdx > 0 and n > 0 then
		local nextQ = CheckManager.getCheckpointQuadIndex(checkpoints, nextCheckpoint, drivelinePoints)
		if nextQ ~= nil then
			local clampedQ = if nextQ > 1 then nextQ - 1 else n
			local qPos, qYaw, valid =
				CheckManager.computeDrivelineQuadPose(drivelinePoints, clampedQ, lastRescuePos.y, nil, kartHeightMeters)
			if valid then
				return qPos, qYaw, clampedQ
			end
		end
	end
	if n > 0 then
		local refPos = currentPos or startPos
		local nearestQ = CheckManager.findNearestQuadIndex(drivelinePoints, refPos.x, refPos.z, nil)
		if nearestQ > 0 then
			local qPos, qYaw, valid =
				CheckManager.computeDrivelineQuadPose(drivelinePoints, nearestQ, startPos.y, nil, kartHeightMeters)
			if valid then
				return qPos, qYaw, nearestQ
			end
		end
	end
	return { x = startPos.x, y = startPos.y, z = startPos.z }, startYawRad or 0.0, 0
end

-- Post-rescue assertion: verifies drivable ground exists within maxGroundDistMeters below pos.
-- If ground is missing or reset/ignore, snaps to the nearest driveline quad center and returns ok=false.
function CheckManager.verifyRescuePlacement(
	pos: { x: number, y: number, z: number },
	yawRad: number,
	drivelinePoints: { { x: number, y: number?, z: number } },
	worldQuery: RescueWorldQuery?,
	kartHeightMeters: number?,
	maxGroundDistMeters: number?
): ({ x: number, y: number, z: number }, number, boolean, string?)
	if worldQuery == nil then
		return pos, yawRad, true, nil
	end
	local maxDist = maxGroundDistMeters or 2.0
	local rayOrigin = { x = pos.x, y = pos.y + 0.1, z = pos.z }
	local hit = worldQuery.raycast(rayOrigin, { x = 0, y = -1, z = 0 }, maxDist + 0.1)
	if hit ~= nil then
		local mat = SurfaceMaterials.get((hit :: any).materialName)
		local distBelow = pos.y - hit.point.y
		if
			not mat.ignore
			and not mat.reset
			and mat.collisionReaction ~= "reset"
			and distBelow >= -0.05
			and distBelow <= maxDist
		then
			return pos, yawRad, true, nil
		end
	end
	local nearestQ = CheckManager.findNearestQuadIndex(drivelinePoints, pos.x, pos.z, nil)
	if nearestQ > 0 then
		local snapPos, snapYaw =
			CheckManager.computeDrivelineQuadPose(drivelinePoints, nearestQ, pos.y, nil, kartHeightMeters)
		return snapPos,
			snapYaw,
			false,
			string.format(
				"no drivable ground within %.2fm below (%.2f, %.2f, %.2f); snapped to quad #%d",
				maxDist,
				pos.x,
				pos.y,
				pos.z,
				nearestQ
			)
	end
	return pos, yawRad, false, "no drivable ground below rescue placement and no driveline quads"
end

return table.freeze(CheckManager)
