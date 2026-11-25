--!strict
-- src/shared/items/ItemWorld.lua
-- SPDX-License-Identifier: GPL-3.0-or-later
-- Ported from src/items/item_manager.cpp:L306-L507, src/items/item.cpp:L61-L228,
-- and src/tracks/track.cpp:L2750-L2800 (STK 1.5, commit 1fb491f5).
-- Pure-Luau fixed-step item placement, pickup collision, respawn timers, and state snapshots.

local FixedStep = require("../sim/FixedStep")
local ItemTuning = require("../ItemTuning")
local KartTuning = require("../KartTuning")
local Math3D = require("../sim/Math3D")
local Units = require("../Units")

local ItemWorld = {}

export type ItemType = "small-nitro" | "big-nitro" | "item" | "banana" | "bubblegum"

export type ItemEntry = {
	id: number,
	itemType: ItemType,
	pos: Math3D.Vec3,
	ticksTillReturn: number,
	deactiveTicks: number,
	disappearCounter: number,
	ownerId: number,
	original: boolean,
}

export type ItemWorldState = {
	items: { ItemEntry },
	nextDynamicId: number,
	haveBonusBoxes: boolean,
	isBattle: boolean,
	numTrackItems: number,
	elapsedTicks: number,
}

export type ItemPickupEvent = {
	id: number,
	itemType: ItemType,
	isNitro: boolean,
	nitroAmount: number,
	isBonusBox: boolean,
	isBanana: boolean,
	isBubblegum: boolean,
}

export type NetTrackCooldown = {
	id: number,
	ticksTillReturn: number,
	deactiveTicks: number,
}

export type NetDynamicItem = {
	id: number,
	itemType: ItemType,
	pos: Math3D.Vec3,
	deactiveTicks: number,
	disappearCounter: number,
	ownerId: number,
}

export type ItemWorldSnapshot = {
	elapsedTicks: number,
	nextDynamicId: number,
	trackCooldowns: { NetTrackCooldown },
	dynamicItems: { NetDynamicItem },
}

local function cloneVec3(v: Math3D.Vec3): Math3D.Vec3
	return { x = v.x, y = v.y, z = v.z }
end

local function returnTicksForType(itemType: ItemType, isBattle: boolean): number
	local sec = ItemTuning.timing.BONUSBOX_RETURN_SEC
	if itemType == "small-nitro" or itemType == "big-nitro" then
		sec = ItemTuning.timing.NITRO_RETURN_SEC
	elseif itemType == "banana" then
		sec = ItemTuning.timing.BANANA_RETURN_SEC
	elseif itemType == "bubblegum" then
		sec = ItemTuning.timing.BUBBLEGUM_RETURN_SEC
	end
	local ticks = FixedStep.timeToTicks(sec)
	if isBattle then
		ticks *= ItemTuning.timing.BATTLE_RETURN_MULTIPLIER
	end
	return ticks
end

function ItemWorld.createEmpty(modeName: string?): ItemWorldState
	local resolvedMode = modeName or "NORMAL_RACE"
	local modeInfo = (ItemTuning.modes :: any)[resolvedMode] or ItemTuning.modes.NORMAL_RACE
	return {
		items = {},
		nextDynamicId = 1,
		haveBonusBoxes = modeInfo.haveBonusBoxes,
		isBattle = modeInfo.isBattle,
		numTrackItems = 0,
		elapsedTicks = 0,
	}
end

-- Build deterministic ItemWorld from generated GreyboxArenaData (pos in Roblox studs, negated Z -> STK meters).
function ItemWorld.fromArenaSpec(arenaData: any, modeName: string?): ItemWorldState
	local world = ItemWorld.createEmpty(modeName)
	local rawItems = if type(arenaData) == "table" and type(arenaData.items) == "table" then arenaData.items else {}
	local maxId = 0
	for idx, raw in rawItems do
		local id = if type(raw.id) == "number" then raw.id else idx
		local itemType: ItemType = if raw.itemType == "small-nitro"
			then "small-nitro"
			elseif raw.itemType == "big-nitro" then "big-nitro"
			elseif raw.itemType == "item" then "item"
			elseif raw.itemType == "bubblegum" then "bubblegum"
			else "banana"
		-- Track::itemCommand skips bonus boxes when !haveBonusBoxes() (src/tracks/track.cpp:L2789-L2795)
		if itemType == "item" and not world.haveBonusBoxes then
			continue
		end
		local p = raw.pos
		local stkPos: Math3D.Vec3 = {
			x = p[1] / Units.STUDS_PER_METER,
			y = p[2] / Units.STUDS_PER_METER,
			z = -p[3] / Units.STUDS_PER_METER,
		}
		local entry: ItemEntry = {
			id = id,
			itemType = itemType,
			pos = stkPos,
			ticksTillReturn = 0,
			deactiveTicks = 0,
			disappearCounter = -1,
			ownerId = 0,
			original = true,
		}
		table.insert(world.items, entry)
		if id > maxId then
			maxId = id
		end
	end
	table.sort(world.items, function(a: ItemEntry, b: ItemEntry): boolean
		return a.id < b.id
	end)
	world.numTrackItems = maxId
	world.nextDynamicId = maxId + 1
	return world
end

function ItemWorld.addTrackItem(world: ItemWorldState, id: number, itemType: ItemType, stkPos: Math3D.Vec3): ItemEntry?
	if itemType == "item" and not world.haveBonusBoxes then
		return nil
	end
	local entry: ItemEntry = {
		id = id,
		itemType = itemType,
		pos = cloneVec3(stkPos),
		ticksTillReturn = 0,
		deactiveTicks = 0,
		disappearCounter = -1,
		ownerId = 0,
		original = true,
	}
	table.insert(world.items, entry)
	table.sort(world.items, function(a: ItemEntry, b: ItemEntry): boolean
		return a.id < b.id
	end)
	if id > world.numTrackItems then
		world.numTrackItems = id
	end
	if world.nextDynamicId <= world.numTrackItems then
		world.nextDynamicId = world.numTrackItems + 1
	end
	return entry
end

-- Ported from ItemManager::dropNewItem (src/items/item_manager.cpp:L281-L335)
-- & ItemState::ItemState owner immunity (src/items/item.cpp:L61-L62: 1.5s = 180 ticks).
function ItemWorld.dropNewItem(
	world: ItemWorldState,
	itemType: ItemType,
	stkPos: Math3D.Vec3,
	ownerId: number?,
	worldQuery: any?
): ItemEntry
	local dropPos = cloneVec3(stkPos)
	if worldQuery ~= nil and type(worldQuery.raycast) == "function" then
		local rayOrigin: Math3D.Vec3 = {
			x = dropPos.x,
			y = dropPos.y + ItemTuning.geometry.DROP_RAY_HEIGHT,
			z = dropPos.z,
		}
		local hit = worldQuery.raycast(rayOrigin, { x = 0, y = -1, z = 0 }, ItemTuning.geometry.DROP_RAY_MAX_DIST)
		if hit ~= nil and hit.materialName ~= "oasis-water.png" then
			local n = hit.normal or { x = 0, y = 1, z = 0 }
			-- STK ItemManager::dropNewItem places at hit_point + up * -0.05 (item_manager.cpp:L306)
			dropPos = {
				x = hit.point.x + n.x * ItemTuning.geometry.DROP_OFFSET_NORMAL,
				y = hit.point.y + n.y * ItemTuning.geometry.DROP_OFFSET_NORMAL,
				z = hit.point.z + n.z * ItemTuning.geometry.DROP_OFFSET_NORMAL,
			}
		end
	end

	local id = world.nextDynamicId
	world.nextDynamicId += 1
	local resolvedOwner = ownerId or 0
	local deactiveTicks = if resolvedOwner ~= 0 then FixedStep.timeToTicks(ItemTuning.timing.OWNER_DEACTIVE_SEC) else 0
	local disappearCounter = if itemType == "bubblegum" then ItemTuning.bubblegum.DISAPPEAR_COUNTER else -1

	local entry: ItemEntry = {
		id = id,
		itemType = itemType,
		pos = dropPos,
		ticksTillReturn = 0,
		deactiveTicks = deactiveTicks,
		disappearCounter = disappearCounter,
		ownerId = resolvedOwner,
		original = false,
	}
	table.insert(world.items, entry)
	return entry
end

function ItemWorld.dropBubblegum(
	world: ItemWorldState,
	stkPos: Math3D.Vec3,
	ownerId: number?,
	worldQuery: any?
): ItemEntry
	return ItemWorld.dropNewItem(world, "bubblegum", stkPos, ownerId, worldQuery)
end

function ItemWorld.dropBanana(world: ItemWorldState, stkPos: Math3D.Vec3, ownerId: number?, worldQuery: any?): ItemEntry
	return ItemWorld.dropNewItem(world, "banana", stkPos, ownerId, worldQuery)
end

-- Ported from ItemManager::update + ItemState::update (item_manager.cpp:L479-L507, item.cpp:L185-L212).
function ItemWorld.tick(world: ItemWorldState)
	world.elapsedTicks += 1
	for i = #world.items, 1, -1 do
		local entry = world.items[i]
		if entry.deactiveTicks > 0 then
			entry.deactiveTicks -= 1
		elseif entry.ticksTillReturn > 0 then
			entry.ticksTillReturn -= 1
			if entry.ticksTillReturn == 0 and entry.disappearCounter == 0 then
				table.remove(world.items, i)
			end
		elseif entry.disappearCounter == 0 then
			table.remove(world.items, i)
		end
	end
end

-- Ported from ItemManager::checkItemHit + Item::hitKart + ItemState::collected
-- (item_manager.cpp:L395-L440, item.hpp:L404-L413, item.cpp:L136-L182, L228).
function ItemWorld.checkHits(
	world: ItemWorldState,
	kartPos: Math3D.Vec3,
	kartId: number?,
	nitroSmallAmount: number?,
	nitroBigAmount: number?,
	isShielded: boolean?
): { ItemPickupEvent }
	local events: { ItemPickupEvent } = {}
	local resolvedKartId = kartId or 1
	local smallAmt = nitroSmallAmount or KartTuning.nitro.smallContainer
	local bigAmt = nitroBigAmount or KartTuning.nitro.bigContainer
	local maxD2 = ItemTuning.geometry.DISTANCE_SQUARED
	local shielded = (isShielded == true)

	local idx = 1
	while idx <= #world.items do
		local entry = world.items[idx]
		-- Shielded karts drive over floor bubblegum without triggering or popping shield (item_manager.cpp:L412-L418)
		local shieldBypassBubblegum = shielded and entry.itemType == "bubblegum"
		local skip = shieldBypassBubblegum
			or entry.ticksTillReturn > 0
			or (entry.deactiveTicks > 0 and (entry.ownerId == 0 or entry.ownerId == resolvedKartId))

		if not skip then
			local dx = entry.pos.x - kartPos.x
			local dy = (entry.pos.y - kartPos.y) * 0.5
			local dz = entry.pos.z - kartPos.z
			local d2 = dx * dx + dy * dy + dz * dz
			if d2 < maxD2 then
				if entry.disappearCounter > 0 then
					entry.disappearCounter -= 1
				end

				local removed = false
				if entry.disappearCounter == 0 then
					table.remove(world.items, idx)
					removed = true
				else
					entry.ticksTillReturn = returnTicksForType(entry.itemType, world.isBattle)
				end

				local isNitro = (entry.itemType == "small-nitro" or entry.itemType == "big-nitro")
				local nitroAmount = if entry.itemType == "big-nitro"
					then bigAmt
					elseif entry.itemType == "small-nitro" then smallAmt
					else 0
				local isBonusBox = (entry.itemType == "item")
				local isBanana = (entry.itemType == "banana")
				local isBubblegum = (entry.itemType == "bubblegum")

				table.insert(events, {
					id = entry.id,
					itemType = entry.itemType,
					isNitro = isNitro,
					nitroAmount = nitroAmount,
					isBonusBox = isBonusBox,
					isBanana = isBanana,
					isBubblegum = isBubblegum,
				})

				if removed then
					continue
				end
			end
		end

		idx += 1
	end

	return events
end

function ItemWorld.captureSnapshot(world: ItemWorldState): ItemWorldSnapshot
	local trackCooldowns: { NetTrackCooldown } = {}
	local dynamicItems: { NetDynamicItem } = {}
	for _, entry in world.items do
		if entry.original then
			if entry.ticksTillReturn > 0 or entry.deactiveTicks > 0 then
				table.insert(trackCooldowns, {
					id = entry.id,
					ticksTillReturn = entry.ticksTillReturn,
					deactiveTicks = entry.deactiveTicks,
				})
			end
		else
			table.insert(dynamicItems, {
				id = entry.id,
				itemType = entry.itemType,
				pos = cloneVec3(entry.pos),
				deactiveTicks = entry.deactiveTicks,
				disappearCounter = entry.disappearCounter,
				ownerId = entry.ownerId,
			})
		end
	end
	return {
		elapsedTicks = world.elapsedTicks,
		nextDynamicId = world.nextDynamicId,
		trackCooldowns = trackCooldowns,
		dynamicItems = dynamicItems,
	}
end

function ItemWorld.applySnapshot(world: ItemWorldState, snap: ItemWorldSnapshot)
	world.elapsedTicks = snap.elapsedTicks
	world.nextDynamicId = snap.nextDynamicId

	local cooldownById: { [number]: NetTrackCooldown } = {}
	for _, cd in snap.trackCooldowns do
		cooldownById[cd.id] = cd
	end

	for i = #world.items, 1, -1 do
		local entry = world.items[i]
		if entry.original then
			local cd = cooldownById[entry.id]
			if cd ~= nil then
				entry.ticksTillReturn = cd.ticksTillReturn
				entry.deactiveTicks = cd.deactiveTicks
			else
				entry.ticksTillReturn = 0
				entry.deactiveTicks = 0
			end
		else
			table.remove(world.items, i)
		end
	end

	for _, dyn in snap.dynamicItems do
		table.insert(world.items, {
			id = dyn.id,
			itemType = dyn.itemType,
			pos = cloneVec3(dyn.pos),
			ticksTillReturn = 0,
			deactiveTicks = dyn.deactiveTicks,
			disappearCounter = dyn.disappearCounter,
			ownerId = dyn.ownerId,
			original = false,
		})
	end
	table.sort(world.items, function(a: ItemEntry, b: ItemEntry): boolean
		return a.id < b.id
	end)
end

return ItemWorld
