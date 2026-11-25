--!strict
-- src/shared/net/GreyboxProtocol.lua
-- SPDX-License-Identifier: GPL-3.0-or-later

local KartSolver = require("../sim/KartSolver")
local MaxSpeed = require("../kart/MaxSpeed")
local Skidding = require("../kart/Skidding")

export type ClientInputPacket = {
	seq: number,
	accel: number,
	brake: boolean,
	steer: number,
	drift: boolean,
	nitro: boolean,
	reset: boolean,
	debugGrantNitro: boolean,
}

export type TelemetryPacket = {
	tick: number,
	lastInputSeq: number,
	resetSeq: number,
	resetNotice: string,
	netState: KartSolver.NetState,
}

local SKID_CONTROLS: { Skidding.SkidControl } = { "NONE", "NO_DIRECTION", "LEFT", "RIGHT" }
local SKID_CONTROL_TO_ID: { [Skidding.SkidControl]: number } = {}
for idx, name in SKID_CONTROLS do
	SKID_CONTROL_TO_ID[name :: Skidding.SkidControl] = idx
end

local SKID_STATES: { Skidding.SkidStateName } = {
	"SKID_NONE",
	"SKID_ACCUMULATE_LEFT",
	"SKID_ACCUMULATE_RIGHT",
	"SKID_SHOW_GFX_LEFT",
	"SKID_SHOW_GFX_RIGHT",
	"SKID_BREAK",
}
local SKID_STATE_TO_ID: { [Skidding.SkidStateName]: number } = {}
for idx, name in SKID_STATES do
	SKID_STATE_TO_ID[name :: Skidding.SkidStateName] = idx
end

local INC_CATS: { MaxSpeed.SpeedIncreaseCategory } = {
	"ZIPPER",
	"SLIPSTREAM",
	"NITRO",
	"RUBBER",
	"SKIDDING",
	"RED_SKIDDING",
}
local INC_CAT_TO_ID: { [MaxSpeed.SpeedIncreaseCategory]: number } = {}
for idx, name in INC_CATS do
	INC_CAT_TO_ID[name :: MaxSpeed.SpeedIncreaseCategory] = idx
end

local GreyboxProtocol = {}

GreyboxProtocol.REMOTES_FOLDER = "OpenKartRemotes"
GreyboxProtocol.INPUT_REMOTE = "KartInput"
GreyboxProtocol.TELEMETRY_REMOTE = "KartTelemetry"
GreyboxProtocol.ARENA_NAME = "GreyboxArena"
GreyboxProtocol.LOCAL_KARTS_FOLDER = "LocalGreyboxKarts"
GreyboxProtocol.PLANE_NAME = "GreyboxPlane"
GreyboxProtocol.SNAPSHOT_RATE_HZ = 30
GreyboxProtocol.SPAWN_HEIGHT_METERS = 0.35
GreyboxProtocol.VOID_RESET_Y_METERS = -20.0

-- Pack authoritative snapshot into compact flat numeric arrays well below UnreliableRemoteEvent's ~900-byte MTU
function GreyboxProtocol.packSnapshot(
	tick: number,
	lastInputSeq: number,
	resetSeq: number,
	ns: KartSolver.NetState,
	resetNotice: string
): ({ number }, { { number } }?, string?)
	local nums: { number } = {
		tick,
		lastInputSeq,
		resetSeq,
		ns.pos[1],
		ns.pos[2],
		ns.pos[3],
		ns.rot[1],
		ns.rot[2],
		ns.rot[3],
		ns.rot[4],
		ns.linVel[1],
		ns.linVel[2],
		ns.linVel[3],
		ns.angVel[1],
		ns.angVel[2],
		ns.angVel[3],
		ns.steer,
		SKID_CONTROL_TO_ID[ns.latchedSkidControl] or 1,
		ns.brakeTicks,
		SKID_STATE_TO_ID[ns.skidState] or 1,
		ns.skidTimeTicks,
		ns.skidFactor,
		ns.steeringFraction,
		ns.visualRotation,
		ns.hopHeight,
		ns.remainingJumpTime,
		if ns.bonusReady then 1 else 0,
		ns.currentTier,
		ns.nitroEnergy,
		ns.minNitroTicks,
		ns.energyToMinRatio,
		if ns.nitroActive then 1 else 0,
		ns.timedImpulsePerSec[1],
		ns.timedImpulsePerSec[2],
		ns.timedImpulsePerSec[3],
		ns.timedImpulseTicks,
		ns.timedRotationTicks,
		ns.timedRotationRate,
		ns.bounceBackTicks,
		ns.terrainFraction,
		ns.terrainTargetFraction,
		ns.terrainFadeTicks,
	}

	local incs: { { number } }? = nil
	if #ns.increases > 0 then
		local list: { { number } } = {}
		for _, inc in ns.increases do
			table.insert(list, {
				INC_CAT_TO_ID[inc.cat] or 1,
				inc.maxAddSpeed,
				inc.currentSpeedup,
				inc.engineForce,
				inc.durationTicks,
				inc.fadeOutTicks,
			})
		end
		incs = list
	end

	local noticeArg: string? = if resetNotice ~= "" then resetNotice else nil
	return nums, incs, noticeArg
end

function GreyboxProtocol.unpackSnapshot(rawNums: any, rawIncs: any, rawNotice: any): TelemetryPacket?
	if type(rawNums) ~= "table" or #rawNums < 42 then
		return nil
	end
	local nums = rawNums :: { number }
	local increases: { KartSolver.NetIncreaseSnapshot } = {}
	if type(rawIncs) == "table" then
		for _, row in rawIncs :: { { number } } do
			if type(row) == "table" and #row >= 6 then
				local cat = INC_CATS[row[1]]
				if cat ~= nil then
					table.insert(increases, {
						cat = cat :: MaxSpeed.SpeedIncreaseCategory,
						maxAddSpeed = row[2],
						currentSpeedup = row[3],
						engineForce = row[4],
						durationTicks = row[5],
						fadeOutTicks = row[6],
					})
				end
			end
		end
	end

	local netState: KartSolver.NetState = {
		pos = { nums[4], nums[5], nums[6] },
		rot = { nums[7], nums[8], nums[9], nums[10] },
		linVel = { nums[11], nums[12], nums[13] },
		angVel = { nums[14], nums[15], nums[16] },
		steer = nums[17],
		latchedSkidControl = SKID_CONTROLS[nums[18]] or "NONE",
		brakeTicks = nums[19],
		skidState = SKID_STATES[nums[20]] or "SKID_NONE",
		skidTimeTicks = nums[21],
		skidFactor = nums[22],
		steeringFraction = nums[23],
		visualRotation = nums[24],
		hopHeight = nums[25],
		remainingJumpTime = nums[26],
		bonusReady = nums[27] == 1,
		currentTier = nums[28],
		nitroEnergy = nums[29],
		minNitroTicks = nums[30],
		energyToMinRatio = nums[31],
		nitroActive = nums[32] == 1,
		timedImpulsePerSec = { nums[33], nums[34], nums[35] },
		timedImpulseTicks = nums[36],
		timedRotationTicks = nums[37],
		timedRotationRate = nums[38],
		bounceBackTicks = nums[39],
		terrainFraction = nums[40],
		terrainTargetFraction = nums[41],
		terrainFadeTicks = nums[42],
		increases = increases,
	}

	return {
		tick = nums[1],
		lastInputSeq = nums[2],
		resetSeq = nums[3],
		resetNotice = if type(rawNotice) == "string" then rawNotice else "",
		netState = netState,
	}
end

return table.freeze(GreyboxProtocol)
