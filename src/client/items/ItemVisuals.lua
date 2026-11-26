--!strict
-- src/client/items/ItemVisuals.lua
-- SPDX-License-Identifier: GPL-3.0-or-later
-- Unified item visual factory cloning hydrated ReplicatedStorage.Assets.Items templates
-- (preserving all MeshParts and SurfaceAppearance children) for pickups, flyables, and attachments.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ItemBoundsData = require(Shared.items.ItemBoundsData)

export type Variant = "pickup" | "flyable" | "attachment"

export type VisualSubpart = {
	part: MeshPart,
	localPos: Vector3,
	baseRot: CFrame,
	baseSize: Vector3,
}

export type CreatedItemVisual = {
	modelId: string,
	model: Model,
	subparts: { VisualSubpart },
}

local VARIANT_MODEL_MAP: { [string]: { [Variant]: string } } = {
	["small-nitro"] = { pickup = "nitrotank-small" },
	["big-nitro"] = { pickup = "nitrotank-big" },
	["item"] = { pickup = "gift-box" },
	["banana"] = { pickup = "banana" },
	["bubblegum"] = { pickup = "bubblegum", attachment = "bubblegum_shield" },
	["bubblegum_shield"] = { attachment = "bubblegum_shield" },
	["bowling"] = { flyable = "bowling", pickup = "bowling" },
	["cake"] = { flyable = "cake", pickup = "cake" },
	["rubber_ball"] = { flyable = "rubber_ball", pickup = "rubber_ball" },
	["plunger"] = { flyable = "plunger", attachment = "plunger", pickup = "plunger" },
	["parachute"] = { attachment = "parachute", pickup = "parachute" },
	["anchor"] = { attachment = "anchor", pickup = "anchor" },
	["anvil"] = { attachment = "anchor", pickup = "anchor" },
	["bomb"] = { attachment = "bomb", pickup = "bomb" },
	["swatter"] = { attachment = "swatter", pickup = "swatter" },
}

local ItemVisuals = {}

function ItemVisuals.resolveModelId(itemType: string, variant: Variant?): string
	local v: Variant = variant or "pickup"
	local entry = VARIANT_MODEL_MAP[itemType]
	if entry then
		return entry[v]
			or entry["pickup" :: Variant]
			or entry["flyable" :: Variant]
			or entry["attachment" :: Variant]
			or itemType
	end
	return itemType
end

function ItemVisuals.resolveTemplate(modelId: string): Model?
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
	if template:GetAttribute("HasUploadedMeshes") ~= true then
		error(string.format("[OpenKart] Item template %s missing HasUploadedMeshes=true", modelId))
	end
	if template:GetAttribute("MeshesHydrated") ~= true then
		return nil
	end
	return template
end

function ItemVisuals.assertBounds(model: Model, modelId: string)
	local expectedParts = ItemBoundsData.items[modelId]
	if expectedParts == nil then
		return
	end
	local tol = ItemBoundsData.TOLERANCE_STUDS
	for _, child in model:GetChildren() do
		if child:IsA("BasePart") and not child:IsA("MeshPart") then
			error(string.format("[OpenKart] Primitive BasePart '%s' forbidden in item %s", child.Name, modelId))
		end
	end
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
			or math.abs(mp.MeshSize.X - expSize[1]) > tol
			or math.abs(mp.MeshSize.Y - expSize[2]) > tol
			or math.abs(mp.MeshSize.Z - expSize[3]) > tol
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

function ItemVisuals.create(itemType: string, variant: Variant?): CreatedItemVisual?
	local modelId = ItemVisuals.resolveModelId(itemType, variant)
	local template = ItemVisuals.resolveTemplate(modelId)
	if template == nil then
		return nil
	end

	-- Clone preserves all MeshParts and SurfaceAppearance children.
	local cloned = template:Clone()
	ItemVisuals.assertBounds(cloned, modelId)

	local subparts: { VisualSubpart } = {}
	for _, child in cloned:GetChildren() do
		if child:IsA("MeshPart") then
			local mp = child :: MeshPart
			mp.Anchored = true
			mp.CanCollide = false
			mp.CanTouch = false
			mp.CanQuery = false
			mp.Massless = true
			local lx = mp:GetAttribute("LocalPosX")
			local ly = mp:GetAttribute("LocalPosY")
			local lz = mp:GetAttribute("LocalPosZ")
			local localPos = if type(lx) == "number"
					and type(ly) == "number"
					and type(lz) == "number"
				then Vector3.new(lx, ly, lz)
				else mp.Position
			local baseRot = if mp:GetAttribute("ImportFlipY180") == true
				then CFrame.Angles(0, math.pi, 0)
				else CFrame.identity
			table.insert(subparts, {
				part = mp,
				localPos = localPos,
				baseRot = baseRot,
				baseSize = mp.Size,
			})
		end
	end

	if #subparts == 0 then
		cloned:Destroy()
		return nil
	end

	return {
		modelId = modelId,
		model = cloned,
		subparts = subparts,
	}
end

return table.freeze(ItemVisuals)
