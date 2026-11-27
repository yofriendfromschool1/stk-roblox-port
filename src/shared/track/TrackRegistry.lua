--!strict
-- src/shared/track/TrackRegistry.lua
-- SPDX-License-Identifier: GPL-3.0-or-later
-- Registry of playable OpenKart tracks (defaulting to Shifting Sands / sandtrack).

local GreyboxArenaData = require("./GreyboxArenaData")
local Math3D = require("../sim/Math3D")
local SandtrackData = require("./SandtrackData")

export type DrivelineBranch = {
	fromQuad: number,
	toQuad: number,
	points: { { x: number, y: number?, z: number } },
}

export type CheckpointSpec = {
	id: number,
	kind: string,
	otherIds: { number },
	sameGroup: { number },
	p1: { x: number, y: number, z: number },
	p2: { x: number, y: number, z: number },
}

export type TrackConfig = {
	trackId: string,
	name: string,
	voidResetYMeters: number,
	startPos: Math3D.Vec3,
	startYawRad: number,
	dummyStartPos: Math3D.Vec3,
	dummyStartYawRad: number,
	drivelineQuadCenters: { { x: number, y: number?, z: number } },
	drivelineBranches: { DrivelineBranch }?,
	checkpoints: { CheckpointSpec },
	minimapBounds: { minX: number, maxX: number, minZ: number, maxZ: number, range: number },
	items: { GreyboxArenaData.ArenaItemSpec },
}

local TrackRegistry = {}

TrackRegistry.DEFAULT_TRACK_ID = "sandtrack"
TrackRegistry.ACTIVE_TRACK_MODEL_NAME = "OpenKartActiveTrack"

local slot0 = SandtrackData.startTransforms[1]
local slot1 = SandtrackData.startTransforms[2]

local TRACKS: { [string]: TrackConfig } = {
	sandtrack = {
		trackId = "sandtrack",
		name = SandtrackData.name,
		voidResetYMeters = SandtrackData.voidResetYMeters,
		startPos = { x = slot0.pos.x, y = slot0.pos.y, z = slot0.pos.z },
		startYawRad = slot0.yawRad,
		dummyStartPos = { x = slot1.pos.x, y = slot1.pos.y, z = slot1.pos.z },
		dummyStartYawRad = slot1.yawRad,
		drivelineQuadCenters = SandtrackData.drivelineQuadCenters,
		drivelineBranches = SandtrackData.drivelineBranches :: any,
		checkpoints = SandtrackData.checkpoints :: any,
		minimapBounds = SandtrackData.minimapBounds,
		items = SandtrackData.items :: any,
	},
	openkart_arena = {
		trackId = "openkart_arena",
		name = "OpenKart Greybox Arena",
		voidResetYMeters = -20.0,
		startPos = { x = 0.0, y = 0.35, z = 0.0 },
		startYawRad = 0.0,
		dummyStartPos = { x = 0.0, y = 0.35, z = 6.0 },
		dummyStartYawRad = math.pi * 0.5,
		drivelineQuadCenters = GreyboxArenaData.drivelineQuadCenters,
		drivelineBranches = {},
		checkpoints = {
			{
				id = 0,
				kind = "lap",
				otherIds = { 1 },
				sameGroup = { 0 },
				p1 = { x = 0.0, y = 0.0, z = -6.0 },
				p2 = { x = 0.0, y = 0.0, z = 18.0 },
			},
			{
				id = 1,
				kind = "activate",
				otherIds = { 2 },
				sameGroup = { 1 },
				p1 = { x = 100.0, y = 0.0, z = -49.0 },
				p2 = { x = 130.0, y = 0.0, z = -49.0 },
			},
			{
				id = 2,
				kind = "activate",
				otherIds = { 3 },
				sameGroup = { 2 },
				p1 = { x = 0.0, y = 0.0, z = -116.0 },
				p2 = { x = 0.0, y = 0.0, z = -92.0 },
			},
			{
				id = 3,
				kind = "activate",
				otherIds = { 0 },
				sameGroup = { 3 },
				p1 = { x = -130.0, y = 0.0, z = -49.0 },
				p2 = { x = -100.0, y = 0.0, z = -49.0 },
			},
		},
		minimapBounds = GreyboxArenaData.minimapBounds,
		items = GreyboxArenaData.items,
	},
}

function TrackRegistry.get(trackId: string?): TrackConfig
	if type(trackId) == "string" and TRACKS[trackId] ~= nil then
		return TRACKS[trackId]
	end
	return TRACKS[TrackRegistry.DEFAULT_TRACK_ID]
end

local function wrapPi(a: number): number
	return ((a + math.pi) % (2.0 * math.pi)) - math.pi
end

-- Returns TrackConfig oriented forward or reversed (src/tracks/drive_graph.cpp:L53-L56, check_manager.cpp:L88-L91).
function TrackRegistry.getOriented(trackId: string?, reverse: boolean?): TrackConfig
	local base = TrackRegistry.get(trackId)
	if reverse ~= true then
		return base
	end

	-- Reverse driveline loop keeping index 1 at start line: [1, N, N-1, ..., 2]
	local origCenters = base.drivelineQuadCenters
	local revCenters: { { x: number, y: number?, z: number } } = {}
	if #origCenters > 0 then
		table.insert(revCenters, { x = origCenters[1].x, y = origCenters[1].y, z = origCenters[1].z })
		for i = #origCenters, 2, -1 do
			local p = origCenters[i]
			table.insert(revCenters, { x = p.x, y = p.y, z = p.z })
		end
	end

	-- Reverse checkpoint graph edges (A -> B becomes B -> A)
	local revOtherMap: { [number]: { number } } = {}
	for _, chk in ipairs(base.checkpoints) do
		revOtherMap[chk.id] = {}
	end
	for _, chk in ipairs(base.checkpoints) do
		for _, targetId in ipairs(chk.otherIds) do
			local list = revOtherMap[targetId]
			if list ~= nil then
				table.insert(list, chk.id)
			end
		end
	end
	local revCheckpoints: { CheckpointSpec } = {}
	for _, chk in ipairs(base.checkpoints) do
		table.insert(revCheckpoints, {
			id = chk.id,
			kind = chk.kind,
			otherIds = revOtherMap[chk.id] or {},
			sameGroup = table.clone(chk.sameGroup),
			p1 = { x = chk.p1.x, y = chk.p1.y, z = chk.p1.z },
			p2 = { x = chk.p2.x, y = chk.p2.y, z = chk.p2.z },
		})
	end

	local revBranches: { DrivelineBranch } = {}
	if base.drivelineBranches ~= nil then
		for _, br in ipairs(base.drivelineBranches) do
			local pts: { { x: number, y: number?, z: number } } = {}
			for i = #br.points, 1, -1 do
				local pt = br.points[i]
				table.insert(pts, { x = pt.x, y = pt.y, z = pt.z })
			end
			table.insert(revBranches, {
				fromQuad = br.toQuad,
				toQuad = br.fromQuad,
				points = pts,
			})
		end
	end

	-- Flip start yaw 180 deg and place behind lap line along reversed heading
	local revStartYaw = wrapPi(base.startYawRad + math.pi)
	local revDummyYaw = wrapPi(base.dummyStartYawRad + math.pi)
	local fwdX = math.sin(revStartYaw)
	local fwdZ = math.cos(revStartYaw)

	return {
		trackId = base.trackId,
		name = base.name,
		voidResetYMeters = base.voidResetYMeters,
		startPos = { x = base.startPos.x - fwdX * 4.0, y = base.startPos.y, z = base.startPos.z - fwdZ * 4.0 },
		startYawRad = revStartYaw,
		dummyStartPos = {
			x = base.dummyStartPos.x - fwdX * 4.0,
			y = base.dummyStartPos.y,
			z = base.dummyStartPos.z - fwdZ * 4.0,
		},
		dummyStartYawRad = revDummyYaw,
		drivelineQuadCenters = revCenters,
		drivelineBranches = revBranches,
		checkpoints = revCheckpoints,
		minimapBounds = base.minimapBounds,
		items = base.items,
	}
end

return table.freeze(TrackRegistry)
