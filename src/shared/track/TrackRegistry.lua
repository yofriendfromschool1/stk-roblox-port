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

return table.freeze(TrackRegistry)
