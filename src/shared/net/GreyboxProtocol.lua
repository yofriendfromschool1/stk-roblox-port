--!strict
-- src/shared/net/GreyboxProtocol.lua
-- SPDX-License-Identifier: GPL-3.0-or-later

local ItemWorld = require("../items/ItemWorld")
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
	fire: boolean?,
	lookBack: boolean?,
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

local ITEM_TYPES: { ItemWorld.ItemType } = { "small-nitro", "big-nitro", "item", "banana", "bubblegum" }
local ITEM_TYPE_TO_ID: { [ItemWorld.ItemType]: number } = {}
for idx, name in ITEM_TYPES do
	ITEM_TYPE_TO_ID[name :: ItemWorld.ItemType] = idx
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
): ({ number }, { { number } }?, string?, { any }?)
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
		ns.heldPowerup or 0,
		ns.heldPowerupCount or 0,
		if ns.fireWasDown then 1 else 0,
		ns.squashFraction or 1.0,
		ns.squashTargetFraction or 1.0,
		ns.squashFadeTicks or 0,
		ns.squashDurationTicks or 0,
		ns.attachmentType or 0,
		ns.attachmentTicksLeft or 0,
		ns.attachmentInitialSpeed or 0.0,
		ns.bubbleFraction or 1.0,
		ns.bubbleTargetFraction or 1.0,
		ns.bubbleFadeTicks or 0,
		ns.bubbleDurationTicks or 0,
	}

	local eff = ns.itemEffect
	if eff ~= nil then
		local flags = (if eff.suppressThrottle then 1 else 0)
			+ (if eff.suppressSteer then 2 else 0)
			+ (if eff.suppressDrift then 4 else 0)
			+ (if eff.suppressFire then 8 else 0)
			+ (if eff.torqueSign then 16 else 0)
		nums[57] = eff.effectType
		nums[58] = eff.ticksRemaining
		nums[59] = eff.totalTicks
		nums[60] = flags
		nums[61] = eff.invulnerableTicks
		nums[62] = eff.originPos[1]
		nums[63] = eff.originPos[2]
		nums[64] = eff.originPos[3]
		nums[65] = eff.originRot[1]
		nums[66] = eff.originRot[2]
		nums[67] = eff.originRot[3]
		nums[68] = eff.originRot[4]
		nums[69] = eff.normal[1]
		nums[70] = eff.normal[2]
		nums[71] = eff.normal[3]
		nums[72] = eff.initUpVel
		nums[73] = eff.gravity
		nums[74] = eff.addHeadingRate
		nums[75] = eff.addPitchRate
		nums[76] = eff.addRollRate
		nums[77] = eff.slowdownFraction
	else
		for i = 57, 76 do
			nums[i] = 0
		end
		nums[65] = 1
		nums[70] = 1
		nums[77] = 1.0
	end

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

	local itemsArg: { any }? = nil
	local iw = ns.itemWorldSnapshot
	if iw ~= nil then
		local cooldownRows: { { number } } = {}
		for _, cd in iw.trackCooldowns do
			table.insert(cooldownRows, { cd.id, cd.ticksTillReturn, cd.deactiveTicks })
		end
		local dynRows: { { number } } = {}
		for _, dyn in iw.dynamicItems do
			table.insert(dynRows, {
				dyn.id,
				ITEM_TYPE_TO_ID[dyn.itemType] or 4,
				dyn.pos.x,
				dyn.pos.y,
				dyn.pos.z,
				dyn.deactiveTicks,
				dyn.disappearCounter,
				dyn.ownerId,
				if dyn.originalType then (ITEM_TYPE_TO_ID[dyn.originalType] or 0) else 0,
			})
		end
		local packed: { any } = table.create(5)
		packed[1] = iw.elapsedTicks
		packed[2] = iw.nextDynamicId
		packed[3] = cooldownRows
		packed[4] = dynRows
		packed[5] = iw.switchTicks or -1
		itemsArg = packed
	end

	local noticeArg: string? = if resetNotice ~= "" then resetNotice else nil
	return nums, incs, noticeArg, itemsArg
end

function GreyboxProtocol.unpackSnapshot(rawNums: any, rawIncs: any, rawNotice: any, rawItems: any): TelemetryPacket?
	if type(rawNums) ~= "table" or #rawNums < 77 then
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

	local itemWorldSnapshot: ItemWorld.ItemWorldSnapshot? = nil
	if type(rawItems) == "table" and #rawItems >= 4 then
		local ri = rawItems :: { any }
		local cooldowns: { ItemWorld.NetTrackCooldown } = {}
		if type(ri[3]) == "table" then
			for _, row in ri[3] :: { { number } } do
				if type(row) == "table" and #row >= 3 then
					table.insert(cooldowns, {
						id = row[1],
						ticksTillReturn = row[2],
						deactiveTicks = row[3],
					})
				end
			end
		end
		local dynamics: { ItemWorld.NetDynamicItem } = {}
		if type(ri[4]) == "table" then
			for _, row in ri[4] :: { { number } } do
				if type(row) == "table" and #row >= 8 then
					local origId = row[9]
					local origType: ItemWorld.ItemType? = if type(origId) == "number" and origId > 0
						then ITEM_TYPES[origId] :: ItemWorld.ItemType?
						else nil
					table.insert(dynamics, {
						id = row[1],
						itemType = (ITEM_TYPES[row[2]] or "banana") :: ItemWorld.ItemType,
						originalType = origType,
						pos = { x = row[3], y = row[4], z = row[5] },
						deactiveTicks = row[6],
						disappearCounter = row[7],
						ownerId = row[8],
					})
				end
			end
		end
		itemWorldSnapshot = {
			elapsedTicks = if type(ri[1]) == "number" then ri[1] else 0,
			nextDynamicId = if type(ri[2]) == "number" then ri[2] else 1,
			switchTicks = if type(ri[5]) == "number" then ri[5] else -1,
			trackCooldowns = cooldowns,
			dynamicItems = dynamics,
		}
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
		heldPowerup = nums[43],
		heldPowerupCount = nums[44],
		fireWasDown = nums[45] == 1,
		squashFraction = nums[46],
		squashTargetFraction = nums[47],
		squashFadeTicks = nums[48],
		squashDurationTicks = nums[49],
		attachmentType = nums[50],
		attachmentTicksLeft = nums[51],
		attachmentInitialSpeed = nums[52],
		bubbleFraction = nums[53],
		bubbleTargetFraction = nums[54],
		bubbleFadeTicks = nums[55],
		bubbleDurationTicks = nums[56],
		itemEffect = {
			effectType = nums[57],
			ticksRemaining = nums[58],
			totalTicks = nums[59],
			suppressThrottle = (math.floor(nums[60]) % 2) == 1,
			suppressSteer = (math.floor(nums[60] / 2) % 2) == 1,
			suppressDrift = (math.floor(nums[60] / 4) % 2) == 1,
			suppressFire = (math.floor(nums[60] / 8) % 2) == 1,
			torqueSign = (math.floor(nums[60] / 16) % 2) == 1,
			invulnerableTicks = nums[61],
			originPos = { nums[62], nums[63], nums[64] },
			originRot = { nums[65], nums[66], nums[67], nums[68] },
			normal = { nums[69], nums[70], nums[71] },
			initUpVel = nums[72],
			gravity = nums[73],
			addHeadingRate = nums[74],
			addPitchRate = nums[75],
			addRollRate = nums[76],
			slowdownFraction = nums[77],
		},
		increases = increases,
		itemWorldSnapshot = itemWorldSnapshot,
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
