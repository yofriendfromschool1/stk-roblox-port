--!strict
-- src/server/KartAssetHydrator.lua
-- SPDX-License-Identifier: GPL-3.0-or-later
-- Hydrates MeshPart MeshId/MeshSize in ReplicatedStorage.Assets.Karts via InsertService
-- when Rojo live-sync cannot write MeshPart.MeshId directly from .model.json.

local InsertService = game:GetService("InsertService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local KartAssetHydrator = {}

local function hydrateMeshPart(placeholder: MeshPart): MeshPart?
	if placeholder.MeshId ~= "" then
		return placeholder
	end

	local rawAssetId = placeholder:GetAttribute("MeshAssetId")
	if type(rawAssetId) ~= "string" or rawAssetId == "" then
		return nil
	end

	local ok, createdOrErr = pcall(function(): MeshPart
		return InsertService:CreateMeshPartAsync(rawAssetId, Enum.CollisionFidelity.Box, Enum.RenderFidelity.Precise)
	end)
	if not ok then
		warn(
			string.format(
				"[OpenKart] Failed to hydrate MeshPart %s (%s): %s",
				placeholder.Name,
				rawAssetId,
				tostring(createdOrErr)
			)
		)
		return nil
	end
	local created = createdOrErr :: MeshPart

	created.Name = placeholder.Name
	created.Anchored = placeholder.Anchored
	created.CanCollide = placeholder.CanCollide
	created.CanTouch = placeholder.CanTouch
	created.CanQuery = placeholder.CanQuery
	created.Massless = placeholder.Massless
	created.Size = placeholder.Size
	created.CFrame = placeholder.CFrame
	created.Color = placeholder.Color
	created.Material = placeholder.Material
	created.TextureID = placeholder.TextureID

	for attrName, attrVal in placeholder:GetAttributes() do
		created:SetAttribute(attrName, attrVal)
	end

	created.Parent = placeholder.Parent
	placeholder:Destroy()
	return created
end

function KartAssetHydrator.hydrateAll(): number
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local karts = if assets then assets:FindFirstChild("Karts") else nil
	if karts == nil then
		return 0
	end

	local hydratedCount = 0
	for _, kartModel in karts:GetChildren() do
		if kartModel:IsA("Model") then
			local allReady = true
			local snapshot: { Instance } = table.clone(kartModel:GetChildren())
			for _, child in snapshot do
				if child:IsA("MeshPart") then
					local mp = hydrateMeshPart(child)
					if mp ~= nil and mp.MeshId ~= "" then
						hydratedCount += 1
					else
						allReady = false
					end
				end
			end
			kartModel:SetAttribute("MeshesHydrated", allReady)
		end
	end

	return hydratedCount
end

return table.freeze(KartAssetHydrator)
