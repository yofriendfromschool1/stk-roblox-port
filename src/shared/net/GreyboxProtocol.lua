--!strict
-- src/shared/net/GreyboxProtocol.lua
-- SPDX-License-Identifier: GPL-3.0-or-later

local Flyable = require("../sim/Flyable")
local ItemEffectState = require("../sim/ItemEffectState")
local ItemWorld = require("../items/ItemWorld")
local KartSolver = require("../sim/KartSolver")
local MaxSpeed = require("../kart/MaxSpeed")
local Skidding = require("../kart/Skidding")

export type RemoteKartState = {
	id: string,
	pos: { number },
	rot: { number },
	linVel: { number }?,
	speed: number,
	steer: number,
	attachmentType: number,
	plungerFaceTicks: number,
	timedImpulseTicks: number?,
	isSquashed: boolean,
	rank: number,
	lap: number?,
	trackNodeIdx: number?,
}

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
	remoteKarts: { RemoteKartState }?,
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

local FLYABLE_KINDS: { Flyable.FlyableKind } = { "bowling", "cake", "plunger", "rubber_ball" }
local FLYABLE_KIND_TO_ID: { [Flyable.FlyableKind]: number } = {}
for idx, name in FLYABLE_KINDS do
	FLYABLE_KIND_TO_ID[name :: Flyable.FlyableKind] = idx
end

local CORE_HEADER_BYTES = 221
local ITEM_EFFECT_BYTES = 116
local INCREASE_ENTRY_BYTES = 17
local COOLDOWN_ENTRY_BYTES = 6
local DYNAMIC_ITEM_ENTRY_BYTES = 28
local FLYABLE_ENTRY_BYTES = 135
local REMOTE_KART_FIXED_BYTES = 58

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

local function clampU8(n: number): number
	return math.clamp(math.round(n), 0, 255)
end

local function clampU16(n: number): number
	return math.clamp(math.round(n), 0, 65535)
end

local function clampU32(n: number): number
	return math.clamp(math.round(n), 0, 4294967295)
end

local function clampI16(n: number): number
	return math.clamp(math.round(n), -32768, 32767)
end

local function clampI32(n: number): number
	return math.clamp(math.round(n), -2147483648, 2147483647)
end

local function isItemEffectActive(eff: ItemEffectState.NetEffectState?): boolean
	if eff == nil then
		return false
	end
	return eff.effectType ~= 0
		or eff.ticksRemaining > 0
		or eff.invulnerableTicks > 0
		or eff.plungerFaceTicks > 0
		or eff.externalPullTicks > 0
		or eff.parachuteDragActive
end

-- Pack authoritative snapshot into a compact binary Luau buffer well below UnreliableRemoteEvent's ~900-byte limit.
function GreyboxProtocol.packSnapshot(
	tick: number,
	lastInputSeq: number,
	resetSeq: number,
	ns: KartSolver.NetState,
	resetNotice: string,
	remoteKarts: { RemoteKartState }?
): (buffer, string?)
	local eff = ns.itemEffect
	local hasItemEffect = isItemEffectActive(eff)
	local iw = ns.itemWorldSnapshot
	local hasItemWorld = iw ~= nil
	local fw = ns.flyableSnapshot
	local hasFlyables = fw ~= nil and (#fw.entries > 0 or fw.nextId > 1)
	local nRemotes = if remoteKarts ~= nil then math.min(#remoteKarts, 255) else 0
	local hasRemoteKarts = nRemotes > 0

	local nIncs = math.min(#ns.increases, 255)
	local totalBytes = CORE_HEADER_BYTES
		+ (if hasItemEffect then ITEM_EFFECT_BYTES else 0)
		+ 1
		+ nIncs * INCREASE_ENTRY_BYTES

	local nCooldowns = 0
	local nDynamics = 0
	if iw ~= nil then
		nCooldowns = math.min(#iw.trackCooldowns, 255)
		nDynamics = math.min(#iw.dynamicItems, 255)
		totalBytes += 10 + nCooldowns * COOLDOWN_ENTRY_BYTES + nDynamics * DYNAMIC_ITEM_ENTRY_BYTES
	end

	local nFlyables = 0
	if hasFlyables and fw ~= nil then
		nFlyables = math.min(#fw.entries, 255)
		totalBytes += 3 + nFlyables * FLYABLE_ENTRY_BYTES
	end

	local remoteIds: { string } = {}
	if hasRemoteKarts and remoteKarts ~= nil then
		totalBytes += 1
		for idx = 1, nRemotes do
			local rid = string.sub(remoteKarts[idx].id, 1, 255)
			remoteIds[idx] = rid
			totalBytes += 1 + #rid + REMOTE_KART_FIXED_BYTES
		end
	end

	local buf = buffer.create(totalBytes)
	local off = 0

	buffer.writeu32(buf, off, clampU32(tick))
	off += 4
	buffer.writeu32(buf, off, clampU32(lastInputSeq))
	off += 4
	buffer.writeu16(buf, off, clampU16(resetSeq))
	off += 2

	-- 13 f64 kinematics for exact deterministic replay (104 B)
	buffer.writef64(buf, off, ns.pos[1])
	buffer.writef64(buf, off + 8, ns.pos[2])
	buffer.writef64(buf, off + 16, ns.pos[3])
	buffer.writef64(buf, off + 24, ns.rot[1])
	buffer.writef64(buf, off + 32, ns.rot[2])
	buffer.writef64(buf, off + 40, ns.rot[3])
	buffer.writef64(buf, off + 48, ns.rot[4])
	buffer.writef64(buf, off + 56, ns.linVel[1])
	buffer.writef64(buf, off + 64, ns.linVel[2])
	buffer.writef64(buf, off + 72, ns.linVel[3])
	buffer.writef64(buf, off + 80, ns.angVel[1])
	buffer.writef64(buf, off + 88, ns.angVel[2])
	buffer.writef64(buf, off + 96, ns.angVel[3])
	off += 104

	-- 19 f32 secondary scalars (76 B)
	buffer.writef32(buf, off, ns.steer)
	buffer.writef32(buf, off + 4, ns.skidFactor)
	buffer.writef32(buf, off + 8, ns.steeringFraction)
	buffer.writef32(buf, off + 12, ns.visualRotation)
	buffer.writef32(buf, off + 16, ns.hopHeight)
	buffer.writef32(buf, off + 20, ns.remainingJumpTime)
	buffer.writef32(buf, off + 24, ns.nitroEnergy)
	buffer.writef32(buf, off + 28, ns.energyToMinRatio)
	buffer.writef32(buf, off + 32, ns.timedImpulsePerSec[1])
	buffer.writef32(buf, off + 36, ns.timedImpulsePerSec[2])
	buffer.writef32(buf, off + 40, ns.timedImpulsePerSec[3])
	buffer.writef32(buf, off + 44, ns.timedRotationRate)
	buffer.writef32(buf, off + 48, ns.terrainFraction)
	buffer.writef32(buf, off + 52, ns.terrainTargetFraction)
	buffer.writef32(buf, off + 56, ns.squashFraction or 1.0)
	buffer.writef32(buf, off + 60, ns.squashTargetFraction or 1.0)
	buffer.writef32(buf, off + 64, ns.attachmentInitialSpeed or 0.0)
	buffer.writef32(buf, off + 68, ns.bubbleFraction or 1.0)
	buffer.writef32(buf, off + 72, ns.bubbleTargetFraction or 1.0)
	off += 76

	-- sectionFlags (1 B)
	local sectionFlags = (if ns.bonusReady then 1 else 0)
		+ (if ns.nitroActive then 2 else 0)
		+ (if ns.fireWasDown then 4 else 0)
		+ (if hasItemEffect then 8 else 0)
		+ (if hasItemWorld then 16 else 0)
		+ (if hasFlyables then 32 else 0)
		+ (if hasRemoteKarts then 64 else 0)
	buffer.writeu8(buf, off, sectionFlags)
	off += 1

	-- 6 small enum/count bytes (6 B)
	buffer.writeu8(buf, off, SKID_CONTROL_TO_ID[ns.latchedSkidControl] or 1)
	buffer.writeu8(buf, off + 1, SKID_STATE_TO_ID[ns.skidState] or 1)
	buffer.writeu8(buf, off + 2, clampU8(ns.currentTier))
	buffer.writeu8(buf, off + 3, clampU8(ns.heldPowerup or 0))
	buffer.writeu8(buf, off + 4, clampU8(ns.heldPowerupCount or 0))
	buffer.writeu8(buf, off + 5, clampU8(ns.attachmentType or 0))
	off += 6

	-- 12 i16 tick counters (24 B)
	buffer.writei16(buf, off, clampI16(ns.brakeTicks))
	buffer.writei16(buf, off + 2, clampI16(ns.skidTimeTicks))
	buffer.writei16(buf, off + 4, clampI16(ns.minNitroTicks))
	buffer.writei16(buf, off + 6, clampI16(ns.timedImpulseTicks))
	buffer.writei16(buf, off + 8, clampI16(ns.timedRotationTicks))
	buffer.writei16(buf, off + 10, clampI16(ns.bounceBackTicks))
	buffer.writei16(buf, off + 12, clampI16(ns.terrainFadeTicks))
	buffer.writei16(buf, off + 14, clampI16(ns.squashFadeTicks or 0))
	buffer.writei16(buf, off + 16, clampI16(ns.squashDurationTicks or 0))
	buffer.writei16(buf, off + 18, clampI16(ns.attachmentTicksLeft or 0))
	buffer.writei16(buf, off + 20, clampI16(ns.bubbleFadeTicks or 0))
	buffer.writei16(buf, off + 22, clampI16(ns.bubbleDurationTicks or 0))
	off += 24

	if hasItemEffect and eff ~= nil then
		local effFlags = (if eff.suppressThrottle then 1 else 0)
			+ (if eff.suppressSteer then 2 else 0)
			+ (if eff.suppressDrift then 4 else 0)
			+ (if eff.suppressFire then 8 else 0)
			+ (if eff.torqueSign then 16 else 0)
			+ (if eff.parachuteDragActive then 32 else 0)
		buffer.writeu8(buf, off, clampU8(eff.effectType))
		buffer.writeu8(buf, off + 1, effFlags)
		buffer.writei16(buf, off + 2, clampI16(eff.ticksRemaining))
		buffer.writei16(buf, off + 4, clampI16(eff.totalTicks))
		buffer.writei16(buf, off + 6, clampI16(eff.invulnerableTicks))
		buffer.writei16(buf, off + 8, clampI16(eff.plungerFaceTicks))
		buffer.writei16(buf, off + 10, clampI16(eff.externalPullTicks))
		buffer.writef64(buf, off + 12, eff.originPos[1])
		buffer.writef64(buf, off + 20, eff.originPos[2])
		buffer.writef64(buf, off + 28, eff.originPos[3])
		buffer.writef64(buf, off + 36, eff.originRot[1])
		buffer.writef64(buf, off + 44, eff.originRot[2])
		buffer.writef64(buf, off + 52, eff.originRot[3])
		buffer.writef64(buf, off + 60, eff.originRot[4])
		buffer.writef32(buf, off + 68, eff.normal[1])
		buffer.writef32(buf, off + 72, eff.normal[2])
		buffer.writef32(buf, off + 76, eff.normal[3])
		buffer.writef32(buf, off + 80, eff.initUpVel)
		buffer.writef32(buf, off + 84, eff.gravity)
		buffer.writef32(buf, off + 88, eff.addHeadingRate)
		buffer.writef32(buf, off + 92, eff.addPitchRate)
		buffer.writef32(buf, off + 96, eff.addRollRate)
		buffer.writef32(buf, off + 100, eff.slowdownFraction)
		buffer.writef32(buf, off + 104, eff.externalPullAccel[1])
		buffer.writef32(buf, off + 108, eff.externalPullAccel[2])
		buffer.writef32(buf, off + 112, eff.externalPullAccel[3])
		off += ITEM_EFFECT_BYTES
	end

	buffer.writeu8(buf, off, nIncs)
	off += 1
	for idx = 1, nIncs do
		local inc = ns.increases[idx]
		buffer.writeu8(buf, off, INC_CAT_TO_ID[inc.cat] or 1)
		buffer.writef32(buf, off + 1, inc.maxAddSpeed)
		buffer.writef32(buf, off + 5, inc.currentSpeedup)
		buffer.writef32(buf, off + 9, inc.engineForce)
		buffer.writei16(buf, off + 13, clampI16(inc.durationTicks))
		buffer.writei16(buf, off + 15, clampI16(inc.fadeOutTicks))
		off += INCREASE_ENTRY_BYTES
	end

	if iw ~= nil then
		buffer.writei32(buf, off, clampI32(iw.elapsedTicks))
		buffer.writeu16(buf, off + 4, clampU16(iw.nextDynamicId))
		buffer.writei16(buf, off + 6, clampI16(iw.switchTicks or -1))
		buffer.writeu8(buf, off + 8, nCooldowns)
		buffer.writeu8(buf, off + 9, nDynamics)
		off += 10
		for idx = 1, nCooldowns do
			local cd = iw.trackCooldowns[idx]
			buffer.writeu16(buf, off, clampU16(cd.id))
			buffer.writei16(buf, off + 2, clampI16(cd.ticksTillReturn))
			buffer.writei16(buf, off + 4, clampI16(cd.deactiveTicks))
			off += COOLDOWN_ENTRY_BYTES
		end
		for idx = 1, nDynamics do
			local dyn = iw.dynamicItems[idx]
			buffer.writeu16(buf, off, clampU16(dyn.id))
			buffer.writeu8(buf, off + 2, ITEM_TYPE_TO_ID[dyn.itemType] or 4)
			buffer.writeu8(buf, off + 3, if dyn.originalType then (ITEM_TYPE_TO_ID[dyn.originalType] or 0) else 0)
			buffer.writef32(buf, off + 4, dyn.pos.x)
			buffer.writef32(buf, off + 8, dyn.pos.y)
			buffer.writef32(buf, off + 12, dyn.pos.z)
			buffer.writei16(buf, off + 16, clampI16(dyn.deactiveTicks))
			buffer.writei16(buf, off + 18, clampI16(dyn.disappearCounter))
			buffer.writef64(buf, off + 20, dyn.ownerId)
			off += DYNAMIC_ITEM_ENTRY_BYTES
		end
	end

	if hasFlyables and fw ~= nil then
		buffer.writeu16(buf, off, clampU16(fw.nextId))
		buffer.writeu8(buf, off + 2, nFlyables)
		off += 3
		for idx = 1, nFlyables do
			local e = fw.entries[idx]
			local bFlags = (if e.reverseMode then 1 else 0)
				+ (if e.isBattle then 2 else 0)
				+ (if e.hasHitSomething then 4 else 0)
				+ (if e.movedToInfinity then 8 else 0)
			buffer.writeu16(buf, off, clampU16(e.id))
			buffer.writeu8(buf, off + 2, FLYABLE_KIND_TO_ID[e.kind] or 1)
			buffer.writef64(buf, off + 3, e.ownerId)
			buffer.writef64(buf, off + 11, e.pos[1])
			buffer.writef64(buf, off + 19, e.pos[2])
			buffer.writef64(buf, off + 27, e.pos[3])
			buffer.writef64(buf, off + 35, e.vel[1])
			buffer.writef64(buf, off + 43, e.vel[2])
			buffer.writef64(buf, off + 51, e.vel[3])
			buffer.writef32(buf, off + 59, e.rot[1])
			buffer.writef32(buf, off + 63, e.rot[2])
			buffer.writef32(buf, off + 67, e.rot[3])
			buffer.writef32(buf, off + 71, e.rot[4])
			buffer.writef32(buf, off + 75, e.radius)
			buffer.writef32(buf, off + 79, e.gravity)
			buffer.writef32(buf, off + 83, e.restitution)
			buffer.writef32(buf, off + 87, e.speedScalar)
			buffer.writei16(buf, off + 91, clampI16(e.ticksSinceThrown))
			buffer.writei16(buf, off + 93, clampI16(e.maxLifespanTicks))
			buffer.writeu8(buf, off + 95, bFlags)
			buffer.writei16(buf, off + 96, clampI16(e.keepAliveTicks))
			buffer.writef64(buf, off + 98, e.targetKartId)
			buffer.writei16(buf, off + 106, clampI16(e.deleteTicks))
			buffer.writei16(buf, off + 108, clampI16(e.drivelineIdx))
			buffer.writef32(buf, off + 110, e.bouncePhaseSec)
			buffer.writeu8(buf, off + 114, clampU8(e.bandState))
			buffer.writef64(buf, off + 115, e.bandTargetKartId)
			buffer.writef32(buf, off + 123, e.bandAnchorPos[1])
			buffer.writef32(buf, off + 127, e.bandAnchorPos[2])
			buffer.writef32(buf, off + 131, e.bandAnchorPos[3])
			off += FLYABLE_ENTRY_BYTES
		end
	end

	if hasRemoteKarts and remoteKarts ~= nil then
		buffer.writeu8(buf, off, nRemotes)
		off += 1
		for idx = 1, nRemotes do
			local rk = remoteKarts[idx]
			local rid = remoteIds[idx]
			local idLen = #rid
			buffer.writeu8(buf, off, idLen)
			buffer.writestring(buf, off + 1, rid)
			local rOff = off + 1 + idLen
			buffer.writef32(buf, rOff, rk.pos[1])
			buffer.writef32(buf, rOff + 4, rk.pos[2])
			buffer.writef32(buf, rOff + 8, rk.pos[3])
			buffer.writef32(buf, rOff + 12, rk.rot[1])
			buffer.writef32(buf, rOff + 16, rk.rot[2])
			buffer.writef32(buf, rOff + 20, rk.rot[3])
			buffer.writef32(buf, rOff + 24, rk.rot[4])
			local rv = rk.linVel
			buffer.writef32(buf, rOff + 28, if rv then (rv[1] or 0) else 0)
			buffer.writef32(buf, rOff + 32, if rv then (rv[2] or 0) else 0)
			buffer.writef32(buf, rOff + 36, if rv then (rv[3] or 0) else 0)
			buffer.writef32(buf, rOff + 40, rk.speed)
			buffer.writef32(buf, rOff + 44, rk.steer)
			buffer.writeu8(buf, rOff + 48, clampU8(rk.attachmentType))
			buffer.writei16(buf, rOff + 49, clampI16(rk.plungerFaceTicks))
			buffer.writei16(buf, rOff + 51, clampI16(rk.timedImpulseTicks or 0))
			buffer.writeu8(buf, rOff + 53, if rk.isSquashed then 1 else 0)
			buffer.writeu8(buf, rOff + 54, clampU8(rk.rank))
			buffer.writeu8(buf, rOff + 55, clampU8(rk.lap or 0))
			buffer.writeu16(buf, rOff + 56, clampU16(rk.trackNodeIdx or 1))
			off = rOff + REMOTE_KART_FIXED_BYTES
		end
	end

	assert(off == totalBytes, "GreyboxProtocol buffer size mismatch")
	local noticeArg: string? = if resetNotice ~= "" then resetNotice else nil
	return buf, noticeArg
end

function GreyboxProtocol.unpackSnapshot(rawPayload: any, rawNotice: any): TelemetryPacket?
	if type(rawPayload) ~= "buffer" then
		return nil
	end
	local buf = rawPayload :: buffer
	local bufLen = buffer.len(buf)
	if bufLen < CORE_HEADER_BYTES + 1 then
		return nil
	end

	local off = 0
	local tick = buffer.readu32(buf, off)
	local lastInputSeq = buffer.readu32(buf, off + 4)
	local resetSeq = buffer.readu16(buf, off + 8)
	off += 10

	local pos = { buffer.readf64(buf, off), buffer.readf64(buf, off + 8), buffer.readf64(buf, off + 16) }
	local rot = {
		buffer.readf64(buf, off + 24),
		buffer.readf64(buf, off + 32),
		buffer.readf64(buf, off + 40),
		buffer.readf64(buf, off + 48),
	}
	local linVel = { buffer.readf64(buf, off + 56), buffer.readf64(buf, off + 64), buffer.readf64(buf, off + 72) }
	local angVel = { buffer.readf64(buf, off + 80), buffer.readf64(buf, off + 88), buffer.readf64(buf, off + 96) }
	off += 104

	local steer = buffer.readf32(buf, off)
	local skidFactor = buffer.readf32(buf, off + 4)
	local steeringFraction = buffer.readf32(buf, off + 8)
	local visualRotation = buffer.readf32(buf, off + 12)
	local hopHeight = buffer.readf32(buf, off + 16)
	local remainingJumpTime = buffer.readf32(buf, off + 20)
	local nitroEnergy = buffer.readf32(buf, off + 24)
	local energyToMinRatio = buffer.readf32(buf, off + 28)
	local timedImpulsePerSec = {
		buffer.readf32(buf, off + 32),
		buffer.readf32(buf, off + 36),
		buffer.readf32(buf, off + 40),
	}
	local timedRotationRate = buffer.readf32(buf, off + 44)
	local terrainFraction = buffer.readf32(buf, off + 48)
	local terrainTargetFraction = buffer.readf32(buf, off + 52)
	local squashFraction = buffer.readf32(buf, off + 56)
	local squashTargetFraction = buffer.readf32(buf, off + 60)
	local attachmentInitialSpeed = buffer.readf32(buf, off + 64)
	local bubbleFraction = buffer.readf32(buf, off + 68)
	local bubbleTargetFraction = buffer.readf32(buf, off + 72)
	off += 76

	local sectionFlags = buffer.readu8(buf, off)
	off += 1
	local bonusReady = bit32.btest(sectionFlags, 1)
	local nitroActive = bit32.btest(sectionFlags, 2)
	local fireWasDown = bit32.btest(sectionFlags, 4)
	local hasItemEffect = bit32.btest(sectionFlags, 8)
	local hasItemWorld = bit32.btest(sectionFlags, 16)
	local hasFlyables = bit32.btest(sectionFlags, 32)
	local hasRemoteKarts = bit32.btest(sectionFlags, 64)

	local skidCtrlId = buffer.readu8(buf, off)
	local skidStateId = buffer.readu8(buf, off + 1)
	local currentTier = buffer.readu8(buf, off + 2)
	local heldPowerup = buffer.readu8(buf, off + 3)
	local heldPowerupCount = buffer.readu8(buf, off + 4)
	local attachmentType = buffer.readu8(buf, off + 5)
	off += 6

	local brakeTicks = buffer.readi16(buf, off)
	local skidTimeTicks = buffer.readi16(buf, off + 2)
	local minNitroTicks = buffer.readi16(buf, off + 4)
	local timedImpulseTicks = buffer.readi16(buf, off + 6)
	local timedRotationTicks = buffer.readi16(buf, off + 8)
	local bounceBackTicks = buffer.readi16(buf, off + 10)
	local terrainFadeTicks = buffer.readi16(buf, off + 12)
	local squashFadeTicks = buffer.readi16(buf, off + 14)
	local squashDurationTicks = buffer.readi16(buf, off + 16)
	local attachmentTicksLeft = buffer.readi16(buf, off + 18)
	local bubbleFadeTicks = buffer.readi16(buf, off + 20)
	local bubbleDurationTicks = buffer.readi16(buf, off + 22)
	off += 24

	local itemEffect: ItemEffectState.NetEffectState
	if hasItemEffect then
		if off + ITEM_EFFECT_BYTES > bufLen then
			return nil
		end
		local effType = buffer.readu8(buf, off)
		local effFlags = buffer.readu8(buf, off + 1)
		itemEffect = {
			effectType = effType,
			ticksRemaining = buffer.readi16(buf, off + 2),
			totalTicks = buffer.readi16(buf, off + 4),
			suppressThrottle = bit32.btest(effFlags, 1),
			suppressSteer = bit32.btest(effFlags, 2),
			suppressDrift = bit32.btest(effFlags, 4),
			suppressFire = bit32.btest(effFlags, 8),
			torqueSign = bit32.btest(effFlags, 16),
			parachuteDragActive = bit32.btest(effFlags, 32),
			invulnerableTicks = buffer.readi16(buf, off + 6),
			originPos = {
				buffer.readf64(buf, off + 12),
				buffer.readf64(buf, off + 20),
				buffer.readf64(buf, off + 28),
			},
			originRot = {
				buffer.readf64(buf, off + 36),
				buffer.readf64(buf, off + 44),
				buffer.readf64(buf, off + 52),
				buffer.readf64(buf, off + 60),
			},
			normal = {
				buffer.readf32(buf, off + 68),
				buffer.readf32(buf, off + 72),
				buffer.readf32(buf, off + 76),
			},
			initUpVel = buffer.readf32(buf, off + 80),
			gravity = buffer.readf32(buf, off + 84),
			addHeadingRate = buffer.readf32(buf, off + 88),
			addPitchRate = buffer.readf32(buf, off + 92),
			addRollRate = buffer.readf32(buf, off + 96),
			slowdownFraction = buffer.readf32(buf, off + 100),
			plungerFaceTicks = buffer.readi16(buf, off + 8),
			externalPullAccel = {
				buffer.readf32(buf, off + 104),
				buffer.readf32(buf, off + 108),
				buffer.readf32(buf, off + 112),
			},
			externalPullTicks = buffer.readi16(buf, off + 10),
		}
		off += ITEM_EFFECT_BYTES
	else
		itemEffect = {
			effectType = 0,
			ticksRemaining = 0,
			totalTicks = 0,
			suppressThrottle = false,
			suppressSteer = false,
			suppressDrift = false,
			suppressFire = false,
			torqueSign = false,
			parachuteDragActive = false,
			invulnerableTicks = 0,
			originPos = { 0, 0, 0 },
			originRot = { 1, 0, 0, 0 },
			normal = { 0, 1, 0 },
			initUpVel = 0,
			gravity = 0,
			addHeadingRate = 0,
			addPitchRate = 0,
			addRollRate = 0,
			slowdownFraction = 1.0,
			plungerFaceTicks = 0,
			externalPullAccel = { 0, 0, 0 },
			externalPullTicks = 0,
		}
	end

	if off + 1 > bufLen then
		return nil
	end
	local nIncs = buffer.readu8(buf, off)
	off += 1
	if off + nIncs * INCREASE_ENTRY_BYTES > bufLen then
		return nil
	end
	local increases: { KartSolver.NetIncreaseSnapshot } = table.create(nIncs)
	for _ = 1, nIncs do
		local cat = INC_CATS[buffer.readu8(buf, off)]
		if cat ~= nil then
			table.insert(increases, {
				cat = cat :: MaxSpeed.SpeedIncreaseCategory,
				maxAddSpeed = buffer.readf32(buf, off + 1),
				currentSpeedup = buffer.readf32(buf, off + 5),
				engineForce = buffer.readf32(buf, off + 9),
				durationTicks = buffer.readi16(buf, off + 13),
				fadeOutTicks = buffer.readi16(buf, off + 15),
			})
		end
		off += INCREASE_ENTRY_BYTES
	end

	local itemWorldSnapshot: ItemWorld.ItemWorldSnapshot? = nil
	if hasItemWorld then
		if off + 10 > bufLen then
			return nil
		end
		local elapsedTicks = buffer.readi32(buf, off)
		local nextDynamicId = buffer.readu16(buf, off + 4)
		local switchTicks = buffer.readi16(buf, off + 6)
		local nCooldowns = buffer.readu8(buf, off + 8)
		local nDynamics = buffer.readu8(buf, off + 9)
		off += 10
		if off + nCooldowns * COOLDOWN_ENTRY_BYTES + nDynamics * DYNAMIC_ITEM_ENTRY_BYTES > bufLen then
			return nil
		end
		local cooldowns: { ItemWorld.NetTrackCooldown } = table.create(nCooldowns)
		for _ = 1, nCooldowns do
			table.insert(cooldowns, {
				id = buffer.readu16(buf, off),
				ticksTillReturn = buffer.readi16(buf, off + 2),
				deactiveTicks = buffer.readi16(buf, off + 4),
			})
			off += COOLDOWN_ENTRY_BYTES
		end
		local dynamics: { ItemWorld.NetDynamicItem } = table.create(nDynamics)
		for _ = 1, nDynamics do
			local typeId = buffer.readu8(buf, off + 2)
			local origId = buffer.readu8(buf, off + 3)
			local origType: ItemWorld.ItemType? = if origId > 0 then ITEM_TYPES[origId] :: ItemWorld.ItemType? else nil
			table.insert(dynamics, {
				id = buffer.readu16(buf, off),
				itemType = (ITEM_TYPES[typeId] or "banana") :: ItemWorld.ItemType,
				originalType = origType,
				pos = {
					x = buffer.readf32(buf, off + 4),
					y = buffer.readf32(buf, off + 8),
					z = buffer.readf32(buf, off + 12),
				},
				deactiveTicks = buffer.readi16(buf, off + 16),
				disappearCounter = buffer.readi16(buf, off + 18),
				ownerId = buffer.readf64(buf, off + 20),
			})
			off += DYNAMIC_ITEM_ENTRY_BYTES
		end
		itemWorldSnapshot = {
			elapsedTicks = elapsedTicks,
			nextDynamicId = nextDynamicId,
			switchTicks = switchTicks,
			trackCooldowns = cooldowns,
			dynamicItems = dynamics,
		}
	end

	local flyableSnapshot: Flyable.FlyableSnapshot? = nil
	if hasFlyables then
		if off + 3 > bufLen then
			return nil
		end
		local nextId = buffer.readu16(buf, off)
		local nFly = buffer.readu8(buf, off + 2)
		off += 3
		if off + nFly * FLYABLE_ENTRY_BYTES > bufLen then
			return nil
		end
		local fEntries: { Flyable.NetFlyableEntry } = table.create(nFly)
		for _ = 1, nFly do
			local bFlags = buffer.readu8(buf, off + 95)
			table.insert(fEntries, {
				id = buffer.readu16(buf, off),
				kind = (FLYABLE_KINDS[buffer.readu8(buf, off + 2)] or "bowling") :: Flyable.FlyableKind,
				ownerId = buffer.readf64(buf, off + 3),
				pos = {
					buffer.readf64(buf, off + 11),
					buffer.readf64(buf, off + 19),
					buffer.readf64(buf, off + 27),
				},
				vel = {
					buffer.readf64(buf, off + 35),
					buffer.readf64(buf, off + 43),
					buffer.readf64(buf, off + 51),
				},
				rot = {
					buffer.readf32(buf, off + 59),
					buffer.readf32(buf, off + 63),
					buffer.readf32(buf, off + 67),
					buffer.readf32(buf, off + 71),
				},
				radius = buffer.readf32(buf, off + 75),
				gravity = buffer.readf32(buf, off + 79),
				restitution = buffer.readf32(buf, off + 83),
				speedScalar = buffer.readf32(buf, off + 87),
				ticksSinceThrown = buffer.readi16(buf, off + 91),
				maxLifespanTicks = buffer.readi16(buf, off + 93),
				reverseMode = bit32.btest(bFlags, 1),
				isBattle = bit32.btest(bFlags, 2),
				hasHitSomething = bit32.btest(bFlags, 4),
				movedToInfinity = bit32.btest(bFlags, 8),
				keepAliveTicks = buffer.readi16(buf, off + 96),
				targetKartId = buffer.readf64(buf, off + 98),
				deleteTicks = buffer.readi16(buf, off + 106),
				drivelineIdx = buffer.readi16(buf, off + 108),
				bouncePhaseSec = buffer.readf32(buf, off + 110),
				bandState = buffer.readu8(buf, off + 114),
				bandTargetKartId = buffer.readf64(buf, off + 115),
				bandAnchorPos = {
					buffer.readf32(buf, off + 123),
					buffer.readf32(buf, off + 127),
					buffer.readf32(buf, off + 131),
				},
			})
			off += FLYABLE_ENTRY_BYTES
		end
		flyableSnapshot = {
			nextId = nextId,
			entries = fEntries,
		}
	end

	local remoteKarts: { RemoteKartState }? = nil
	if hasRemoteKarts then
		if off + 1 > bufLen then
			return nil
		end
		local nRem = buffer.readu8(buf, off)
		off += 1
		local rList: { RemoteKartState } = table.create(nRem)
		for _ = 1, nRem do
			if off + 1 > bufLen then
				return nil
			end
			local idLen = buffer.readu8(buf, off)
			if off + 1 + idLen + REMOTE_KART_FIXED_BYTES > bufLen then
				return nil
			end
			local rid = buffer.readstring(buf, off + 1, idLen)
			local rOff = off + 1 + idLen
			table.insert(rList, {
				id = rid,
				pos = { buffer.readf32(buf, rOff), buffer.readf32(buf, rOff + 4), buffer.readf32(buf, rOff + 8) },
				rot = {
					buffer.readf32(buf, rOff + 12),
					buffer.readf32(buf, rOff + 16),
					buffer.readf32(buf, rOff + 20),
					buffer.readf32(buf, rOff + 24),
				},
				linVel = {
					buffer.readf32(buf, rOff + 28),
					buffer.readf32(buf, rOff + 32),
					buffer.readf32(buf, rOff + 36),
				},
				speed = buffer.readf32(buf, rOff + 40),
				steer = buffer.readf32(buf, rOff + 44),
				attachmentType = buffer.readu8(buf, rOff + 48),
				plungerFaceTicks = buffer.readi16(buf, rOff + 49),
				timedImpulseTicks = buffer.readi16(buf, rOff + 51),
				isSquashed = buffer.readu8(buf, rOff + 53) == 1,
				rank = buffer.readu8(buf, rOff + 54),
				lap = buffer.readu8(buf, rOff + 55),
				trackNodeIdx = buffer.readu16(buf, rOff + 56),
			})
			off = rOff + REMOTE_KART_FIXED_BYTES
		end
		remoteKarts = rList
	end

	local netState: KartSolver.NetState = {
		pos = pos,
		rot = rot,
		linVel = linVel,
		angVel = angVel,
		steer = steer,
		latchedSkidControl = SKID_CONTROLS[skidCtrlId] or "NONE",
		brakeTicks = brakeTicks,
		skidState = SKID_STATES[skidStateId] or "SKID_NONE",
		skidTimeTicks = skidTimeTicks,
		skidFactor = skidFactor,
		steeringFraction = steeringFraction,
		visualRotation = visualRotation,
		hopHeight = hopHeight,
		remainingJumpTime = remainingJumpTime,
		bonusReady = bonusReady,
		currentTier = currentTier,
		nitroEnergy = nitroEnergy,
		minNitroTicks = minNitroTicks,
		energyToMinRatio = energyToMinRatio,
		nitroActive = nitroActive,
		timedImpulsePerSec = timedImpulsePerSec,
		timedImpulseTicks = timedImpulseTicks,
		timedRotationTicks = timedRotationTicks,
		timedRotationRate = timedRotationRate,
		bounceBackTicks = bounceBackTicks,
		terrainFraction = terrainFraction,
		terrainTargetFraction = terrainTargetFraction,
		terrainFadeTicks = terrainFadeTicks,
		heldPowerup = heldPowerup,
		heldPowerupCount = heldPowerupCount,
		fireWasDown = fireWasDown,
		squashFraction = squashFraction,
		squashTargetFraction = squashTargetFraction,
		squashFadeTicks = squashFadeTicks,
		squashDurationTicks = squashDurationTicks,
		attachmentType = attachmentType,
		attachmentTicksLeft = attachmentTicksLeft,
		attachmentInitialSpeed = attachmentInitialSpeed,
		bubbleFraction = bubbleFraction,
		bubbleTargetFraction = bubbleTargetFraction,
		bubbleFadeTicks = bubbleFadeTicks,
		bubbleDurationTicks = bubbleDurationTicks,
		itemEffect = itemEffect,
		increases = increases,
		itemWorldSnapshot = itemWorldSnapshot,
		flyableSnapshot = flyableSnapshot,
	}

	return {
		tick = tick,
		lastInputSeq = lastInputSeq,
		resetSeq = resetSeq,
		resetNotice = if type(rawNotice) == "string" then rawNotice else "",
		netState = netState,
		remoteKarts = remoteKarts,
	}
end

return table.freeze(GreyboxProtocol)
