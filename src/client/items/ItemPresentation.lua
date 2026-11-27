--!strict
-- src/client/items/ItemPresentation.lua
-- SPDX-License-Identifier: GPL-3.0-or-later
-- ported from src/items/item.cpp:L458-L508, src/items/item.hpp:L415 (STK 1.5)
-- Visual renderer for arena pickups & dropped hazards.
-- Strictly requires hydrated MeshPart templates from ReplicatedStorage.Assets.Items
-- (zero primitive Part fallbacks) and asserts live MeshId + 2 mm bounds against ItemBoundsData.
-- Bubblegum visual roles:
--   - Held powerup: HUD icon bubblegum-icon.png (bound in GameHud.client.lua)
--   - Dropped road hazard: bubblegum.rbxmx (gum mesh below)
--   - Forward-fired shield bubble: bubblegum_shield.rbxmx (in Assets.Items; Attachment runtime flagged in port-map.md)

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ItemVisuals = require("./ItemVisuals")
local ItemWorld = require(Shared.items.ItemWorld)
local Units = require(Shared.Units)

export type VisualSubpart = ItemVisuals.VisualSubpart

export type ItemVisualInstance = {
	id: number,
	modelId: string,
	container: Model,
	subparts: { VisualSubpart },
	wasAvailable: boolean,
	respawnAnimStartSec: number?,
}

export type ItemPresentationController = {
	folder: Folder,
	instances: { [number]: ItemVisualInstance },
}

local TYPE_TO_MODEL_ID: { [ItemWorld.ItemType]: string } = {
	["small-nitro"] = "nitrotank-small",
	["big-nitro"] = "nitrotank-big",
	["item"] = "gift-box",
	["banana"] = "banana",
	["bubblegum"] = "bubblegum",
}

local ItemPresentation = {}

local function instantiateVisual(entry: ItemWorld.ItemEntry, folder: Folder): ItemVisualInstance?
	local modelId = TYPE_TO_MODEL_ID[entry.itemType]
	if modelId == nil then
		error(string.format("[OpenKart] Unmapped ItemType '%s' for MeshPart lookup", tostring(entry.itemType)))
	end
	local initiallyAvailable = entry.ticksTillReturn <= 0
	local created = ItemVisuals.create(modelId, "pickup")
	if created == nil then
		return nil
	end

	local cloned = created.model
	cloned.Name = string.format("Item_%d_%s", entry.id, modelId)
	local subparts = created.subparts

	cloned.Parent = folder
	return {
		id = entry.id,
		modelId = modelId,
		container = cloned,
		subparts = subparts,
		wasAvailable = initiallyAvailable,
		respawnAnimStartSec = nil,
	}
end

function ItemPresentation.create(): ItemPresentationController
	local existing = Workspace:FindFirstChild("LocalArenaItems")
	if existing then
		existing:Destroy()
	end
	local folder = Instance.new("Folder")
	folder.Name = "LocalArenaItems"
	folder.Parent = Workspace
	return {
		folder = folder,
		instances = {},
	}
end

function ItemPresentation.sync(ctrl: ItemPresentationController, itemWorld: ItemWorld.ItemWorldState, nowSec: number)
	debug.profilebegin("OpenKart_ItemSync")
	local seen: { [number]: boolean } = {}
	for _, entry in itemWorld.items do
		if entry.itemType == "item" and not itemWorld.haveBonusBoxes then
			continue
		end
		seen[entry.id] = true
		local expectedModelId = TYPE_TO_MODEL_ID[entry.itemType]
		local vis: ItemVisualInstance? = ctrl.instances[entry.id]
		if vis ~= nil and vis.modelId ~= expectedModelId then
			vis.container:Destroy()
			ctrl.instances[entry.id] = nil
			vis = nil
		end
		if vis == nil then
			local created = instantiateVisual(entry, ctrl.folder)
			if created == nil then
				continue
			end
			ctrl.instances[entry.id] = created
			vis = created
		end
		local activeVis = vis :: ItemVisualInstance
		local originPos = Vector3.new(
			Units.metersToStuds(entry.pos.x),
			Units.metersToStuds(entry.pos.y),
			Units.metersToStuds(-entry.pos.z)
		)

		-- STK ItemState::rotating() = (type != ITEM_BUBBLEGUM) at 120/40 = 3.0 rad/s (item.hpp:L415, item.cpp:L492-L504)
		local spinAngle = if entry.itemType ~= "bubblegum" then ((nowSec * 3.0) % (2.0 * math.pi)) else 0.0
		local spinRot = if spinAngle ~= 0.0 then CFrame.Angles(0, spinAngle, 0) else CFrame.identity
		local originCf = CFrame.new(originPos) * spinRot

		-- STK Item::updateGraphics 1.0 s elastic squash-and-stretch appear animation (item.cpp:L464-L485)
		local isAvailable = entry.ticksTillReturn <= 0
		if isAvailable and not activeVis.wasAvailable then
			activeVis.respawnAnimStartSec = nowSec
		elseif not isAvailable then
			activeVis.respawnAnimStartSec = nil
		end
		activeVis.wasAvailable = isAvailable

		local factorH = 1.0
		local factorV = 1.0
		if isAvailable and activeVis.respawnAnimStartSec ~= nil then
			local p = math.max(0.0, nowSec - activeVis.respawnAnimStartSec)
			if p < 1.0 then
				local f = 1.0 - p
				factorV = math.max(0.05, math.sin(-13.0 * (math.pi * 0.5) * (p + 1.0)) * (2.0 ^ (-10.0 * p)) + 1.0)
				factorH = math.max(0.05, 1.0 - (f ^ 5 - f ^ 3 * math.sin(f * math.pi)))
			else
				activeVis.respawnAnimStartSec = nil
			end
		end

		local transparency = if not isAvailable then 1.0 elseif entry.deactiveTicks > 0 then 0.5 else 0.0

		for _, sp in activeVis.subparts do
			local scaledPos = Vector3.new(sp.localPos.X * factorH, sp.localPos.Y * factorV, sp.localPos.Z * factorH)
			sp.part.Size = Vector3.new(sp.baseSize.X * factorH, sp.baseSize.Y * factorV, sp.baseSize.Z * factorH)
			sp.part.CFrame = originCf * CFrame.new(scaledPos) * sp.baseRot
			sp.part.Transparency = transparency
		end
	end

	for id, vis in ctrl.instances do
		if not seen[id] then
			vis.container:Destroy()
			ctrl.instances[id] = nil
		end
	end
	debug.profileend()
end

return table.freeze(ItemPresentation)
