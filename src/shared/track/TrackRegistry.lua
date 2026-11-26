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
	points: { { x: number, z: number } },
}

export type TrackConfig = {
	trackId: string,
	name: string,
	voidResetYMeters: number,
	startPos: Math3D.Vec3,
	startYawRad: number,
	dummyStartPos: Math3D.Vec3,
	dummyStartYawRad: number,
	drivelineQuadCenters: { { x: number, z: number } },
	drivelineBranches: { DrivelineBranch }?,
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
