--!strict
-- src/client/items/ItemPresentation.lua
-- SPDX-License-Identifier: GPL-3.0-or-later
-- Non-yielding visual renderer for arena pickups & dropped hazards.
-- Prefers hydrated ReplicatedStorage.Assets.Items templates (with live MeshPart.Size/MeshSize
-- assertions against ItemBoundsData.lua); falls back immediately without yielding to exact
-- ItemBoundsData-sized submesh Parts when a template is absent or unhydrated, upgrading cleanly
-- once ready.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ItemBoundsData = require(Shared.items.ItemBoundsData)
local ItemWorld = require(Shared.items.ItemWorld)
local Units = require(Shared.Units)

export type VisualSubpart = {
	part: BasePart,
	localPos: Vector3,
	baseRot: CFrame,
}

export type ItemVisualInstance = {
	id: number,
	modelId: string,
	container: Model,
	subparts: { VisualSubpart },
	usingFallback: boolean,
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

local TYPE_FALLBACK_COLORS: { [string]: Color3 } = {
	["nitrotank-small"] = Color3.fromRGB(70, 175, 255),
	["nitrotank-big"] = Color3.fromRGB(0, 225, 255),
	["gift-box"] = Color3.fromRGB(255, 205, 45),
	["banana"] = Color3.fromRGB(255, 235, 45),
	["bubblegum"] = Color3.fromRGB(246, 150, 209),
}

local warnedState: { [string]: boolean } = {}

local ItemPresentation = {}

-- Strictly non-yielding lookup so BindToRenderStep never stalls waiting on missing assets.
local function resolveReadyItemTemplate(modelId: string): Model?
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	if not assets then
		return nil
	end
	local items = assets:FindFirstChild("Items")
	if not items then
		return nil
	end
	local template = items:FindFirstChild(modelId)
	if not (template and template:IsA("Model")) then
		return nil
	end
	if template:GetAttribute("HasUploadedMeshes") == true and template:GetAttribute("MeshesHydrated") ~= true then
		return nil
	end
	return template
end

local function assertItemLiveBounds(model: Model, modelId: string)
	local expectedParts = ItemBoundsData.items[modelId]
	if expectedParts == nil then
		return
	end
	local tol = ItemBoundsData.TOLERANCE_STUDS
	for partName, expected in expectedParts do
		local child = model:FindFirstChild(partName)
		if not (child and child:IsA("MeshPart")) then
			error(string.format("[OpenKart] Item %s missing MeshPart '%s'", modelId, partName))
		end
		local mp = child :: MeshPart
		local expSize = expected.size
		if
			mp.MeshId == ""
			or mp.MeshSize.Magnitude <= 1e-4
			or math.abs(mp.Size.X - expSize[1]) > tol
			or math.abs(mp.Size.Y - expSize[2]) > tol
			or math.abs(mp.Size.Z - expSize[3]) > tol
		then
			error(
				string.format(
					"[OpenKart] Item %s.%s Size/MeshSize mismatch: Size=(%.4f,%.4f,%.4f) MeshSize=(%.4f,%.4f,%.4f) expected=(%.4f,%.4f,%.4f)",
					modelId,
					partName,
					mp.Size.X,
					mp.Size.Y,
					mp.Size.Z,
					mp.MeshSize.X,
					mp.MeshSize.Y,
					mp.MeshSize.Z,
					expSize[1],
					expSize[2],
					expSize[3]
				)
			)
		end
	end
end

local function buildBoundsFallback(entryId: number, modelId: string, folder: Folder): ItemVisualInstance
	local container = Instance.new("Model")
	container.Name = string.format("Item_%d_%s", entryId, modelId)
	local subparts: { VisualSubpart } = {}
	local expectedParts = ItemBoundsData.items[modelId]
	local color = TYPE_FALLBACK_COLORS[modelId] or Color3.fromRGB(255, 220, 60)

	if expectedParts ~= nil then
		for partName, info in expectedParts do
			local p = Instance.new("Part")
			p.Name = partName
			p.Anchored = true
			p.CanCollide = false
			p.CanTouch = false
			p.CanQuery = false
			p.Massless = true
			p.TopSurface = Enum.SurfaceType.Smooth
			p.BottomSurface = Enum.SurfaceType.Smooth
			p.Material = Enum.Material.SmoothPlastic
			p.Color = if partName == "Logo" or partName == "Ribbon" then Color3.fromRGB(245, 248, 255) else color
			p.Size = Vector3.new(info.size[1], info.size[2], info.size[3])
			p.Parent = container
			table.insert(subparts, {
				part = p :: BasePart,
				localPos = Vector3.new(info.center[1], info.center[2], info.center[3]),
				baseRot = CFrame.identity,
			})
		end
	end

	container.Parent = folder
	return {
		id = entryId,
		modelId = modelId,
		container = container,
		subparts = subparts,
		usingFallback = true,
	}
end

local function instantiateVisual(entry: ItemWorld.ItemEntry, folder: Folder): ItemVisualInstance
	local modelId = TYPE_TO_MODEL_ID[entry.itemType] or "banana"
	local template = resolveReadyItemTemplate(modelId)
	if template == nil then
		if not warnedState[modelId .. "_fallback"] then
			warnedState[modelId .. "_fallback"] = true
			warn(
				string.format(
					"[OpenKart] ReplicatedStorage.Assets.Items.%s unavailable; rendering ItemBoundsData-sized Parts without yielding",
					modelId
				)
			)
		end
		return buildBoundsFallback(entry.id, modelId, folder)
	end

	local cloned = template:Clone()
	cloned.Name = string.format("Item_%d_%s", entry.id, modelId)

	local hasMeshes = cloned:GetAttribute("HasUploadedMeshes") == true
	if hasMeshes then
		assertItemLiveBounds(cloned, modelId)
	elseif not warnedState[modelId .. "_noupload"] then
		warnedState[modelId .. "_noupload"] = true
		warn(
			string.format(
				"[OpenKart] Item %s has HasUploadedMeshes=false; awaiting Roblox asset IDs in assets/items/roblox_assets.json",
				modelId
			)
		)
	end

	local subparts: { VisualSubpart } = {}
	for _, child in cloned:GetChildren() do
		if child:IsA("BasePart") then
			local bp = child :: BasePart
			bp.Anchored = true
			bp.CanCollide = false
			bp.CanTouch = false
			bp.CanQuery = false
			bp.Massless = true
			if not bp:IsA("MeshPart") then
				bp.Color = TYPE_FALLBACK_COLORS[modelId] or bp.Color
				bp.Material = Enum.Material.SmoothPlastic
			end
			local lx = bp:GetAttribute("LocalPosX")
			local ly = bp:GetAttribute("LocalPosY")
			local lz = bp:GetAttribute("LocalPosZ")
			local localPos = if type(lx) == "number"
					and type(ly) == "number"
					and type(lz) == "number"
				then Vector3.new(lx, ly, lz)
				else bp.Position
			local baseRot = if bp:GetAttribute("ImportFlipY180") == true
				then CFrame.Angles(0, math.pi, 0)
				else CFrame.identity
			table.insert(subparts, {
				part = bp,
				localPos = localPos,
				baseRot = baseRot,
			})
		end
	end

	cloned.Parent = folder
	return {
		id = entry.id,
		modelId = modelId,
		container = cloned,
		subparts = subparts,
		usingFallback = false,
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
		seen[entry.id] = true
		local vis: ItemVisualInstance? = ctrl.instances[entry.id]
		if vis ~= nil and vis.usingFallback then
			local readyTemplate = resolveReadyItemTemplate(vis.modelId)
			if readyTemplate ~= nil then
				vis.container:Destroy()
				ctrl.instances[entry.id] = nil
				vis = nil
			end
		end
		local activeVis: ItemVisualInstance
		if vis == nil then
			local created = instantiateVisual(entry, ctrl.folder)
			ctrl.instances[entry.id] = created
			activeVis = created
		else
			activeVis = vis
		end
		local originPos = Vector3.new(
			Units.metersToStuds(entry.pos.x),
			Units.metersToStuds(entry.pos.y),
			Units.metersToStuds(-entry.pos.z)
		)
		local spinRot = if entry.itemType == "banana" or entry.itemType == "bubblegum"
			then CFrame.identity
			else CFrame.Angles(0, nowSec * 1.8, 0)
		local originCf = CFrame.new(originPos) * spinRot

		local transparency = if entry.ticksTillReturn > 0 then 1.0 elseif entry.deactiveTicks > 0 then 0.5 else 0.0

		for _, sp in activeVis.subparts do
			sp.part.CFrame = originCf * CFrame.new(sp.localPos) * sp.baseRot
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
