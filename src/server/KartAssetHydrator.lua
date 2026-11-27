--!strict
-- src/server/KartAssetHydrator.lua
-- SPDX-License-Identifier: GPL-3.0-or-later
-- Hydrates MeshPart MeshId/MeshSize in ReplicatedStorage.Assets.Karts via InsertService
-- when Rojo live-sync cannot write MeshPart.MeshId directly from .model.json.

local InsertService = game:GetService("InsertService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ItemBoundsData = require(Shared.items.ItemBoundsData)
local KartBoundsData = require(Shared.kart.KartBoundsData)
local SandtrackData = require(Shared.track.SandtrackData)

local KartAssetHydrator = {}
local hydratedKartCache: { [string]: boolean } = {}
local inFlightKarts: { [string]: boolean } = {}

local function getTargetCollisionFidelity(placeholder: MeshPart): Enum.CollisionFidelity
	if placeholder:GetAttribute("DesiredCollisionFidelity") == "PreciseConvexDecomposition" then
		return Enum.CollisionFidelity.PreciseConvexDecomposition
	end
	return placeholder.CollisionFidelity
end

local function needsHydration(placeholder: MeshPart): boolean
	if placeholder.MeshId == "" or placeholder.MeshSize.Magnitude <= 1e-4 then
		return true
	end
	if placeholder:GetAttribute("DesiredCollisionFidelity") == "PreciseConvexDecomposition" then
		return placeholder.CollisionFidelity ~= Enum.CollisionFidelity.PreciseConvexDecomposition
	end
	return false
end

local function hydrateMeshPart(placeholder: MeshPart): MeshPart?
	local targetFidelity = getTargetCollisionFidelity(placeholder)
	-- Rojo .model.json writes MeshId without MeshSize; zero MeshSize causes Roblox to distort Size.
	if not needsHydration(placeholder) then
		return placeholder
	end

	local rawAssetId = placeholder:GetAttribute("MeshAssetId")
	if type(rawAssetId) ~= "string" or rawAssetId == "" then
		rawAssetId = placeholder.MeshId
	end
	if type(rawAssetId) ~= "string" or rawAssetId == "" then
		return nil
	end

	local ok, createdOrErr = pcall(function(): MeshPart
		return InsertService:CreateMeshPartAsync(rawAssetId, targetFidelity, Enum.RenderFidelity.Precise)
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
	created.DoubleSided = placeholder.DoubleSided
	created.Size = placeholder.Size
	created.CFrame = placeholder.CFrame
	created.Color = placeholder.Color
	created.Material = placeholder.Material
	created.TextureID = placeholder.TextureID

	for attrName, attrVal in placeholder:GetAttributes() do
		created:SetAttribute(attrName, attrVal)
	end

	for _, child in placeholder:GetChildren() do
		child.Parent = created
	end

	created.Parent = placeholder.Parent
	placeholder:Destroy()
	return created
end

function KartAssetHydrator.assertSubmeshBounds(model: Model, expectedByPart: { [string]: { number } }, tol: number?)
	local tolerance = tol or 0.01
	for partName, exp in expectedByPart do
		local child = model:FindFirstChild(partName)
		if not (child and child:IsA("MeshPart")) then
			error(string.format("[OpenKart] Missing MeshPart '%s' in %s", partName, model.Name))
		end
		local mp = child :: MeshPart
		if mp.MeshId == "" or mp.MeshSize.Magnitude <= 1e-4 then
			error(
				string.format(
					"[OpenKart] Unhydrated MeshPart '%s' in %s (MeshId='%s', MeshSize=%.4f,%.4f,%.4f)",
					partName,
					model.Name,
					mp.MeshId,
					mp.MeshSize.X,
					mp.MeshSize.Y,
					mp.MeshSize.Z
				)
			)
		end
		local expX = math.max(exp[1], 0.05)
		local expY = math.max(exp[2], 0.05)
		local expZ = math.max(exp[3], 0.05)
		local dx = math.abs(mp.Size.X - expX)
		local dy = math.abs(mp.Size.Y - expY)
		local dz = math.abs(mp.Size.Z - expZ)
		local mdx = math.abs(mp.MeshSize.X - expX)
		local mdy = math.abs(mp.MeshSize.Y - expY)
		local mdz = math.abs(mp.MeshSize.Z - expZ)
		if
			dx > tolerance
			or dy > tolerance
			or dz > tolerance
			or mdx > tolerance
			or mdy > tolerance
			or mdz > tolerance
		then
			error(
				string.format(
					"[OpenKart] Bounds mismatch on %s.%s: Size=(%.4f,%.4f,%.4f) MeshSize=(%.4f,%.4f,%.4f) expected=(%.4f,%.4f,%.4f)",
					model.Name,
					partName,
					mp.Size.X,
					mp.Size.Y,
					mp.Size.Z,
					mp.MeshSize.X,
					mp.MeshSize.Y,
					mp.MeshSize.Z,
					exp[1],
					exp[2],
					exp[3]
				)
			)
		end
	end
end

local function hydrateModelFolder(folder: Instance?, boundsLookup: { [string]: { [string]: { number } } }?): number
	if folder == nil then
		return 0
	end
	local toHydrate: { { model: Model, part: MeshPart } } = {}
	local models: { Model } = {}
	for _, assetModel in folder:GetChildren() do
		if assetModel:IsA("MeshPart") then
			if needsHydration(assetModel) then
				table.insert(toHydrate, { model = assetModel :: any, part = assetModel })
			end
		elseif assetModel:IsA("Model") then
			table.insert(models, assetModel)
			for _, child in assetModel:GetChildren() do
				if child:IsA("MeshPart") and needsHydration(child) then
					table.insert(toHydrate, { model = assetModel, part = child })
				end
			end
		end
	end

	-- Parallelize network hydration when dev live-sync leaves MeshSize == 0; baked .rbxmx skips completely.
	local hydratedCount = 0
	if #toHydrate > 0 then
		local t0 = os.clock()
		local pending = #toHydrate
		for _, item in toHydrate do
			task.spawn(function()
				local mp = hydrateMeshPart(item.part)
				if mp ~= nil and mp.MeshId ~= "" and mp.MeshSize.Magnitude > 1e-4 then
					hydratedCount += 1
				end
				pending -= 1
			end)
		end
		while pending > 0 do
			task.wait()
		end
		print(
			string.format(
				"[OpenKart] Parallel hydrated %d/%d MeshParts in %s (%.1f ms)",
				hydratedCount,
				#toHydrate,
				folder.Name,
				(os.clock() - t0) * 1000
			)
		)
	end

	for _, assetModel in models do
		local allReady = true
		for _, child in assetModel:GetChildren() do
			if child:IsA("MeshPart") and (child.MeshId == "" or child.MeshSize.Magnitude <= 1e-4) then
				allReady = false
				break
			end
		end
		if allReady and boundsLookup ~= nil then
			local expected = boundsLookup[assetModel.Name]
			if expected ~= nil then
				KartAssetHydrator.assertSubmeshBounds(assetModel, expected, ItemBoundsData.TOLERANCE_STUDS)
			end
		end
		assetModel:SetAttribute("MeshesHydrated", allReady)
	end

	return hydratedCount
end

-- Lazy per-kart hydration: hydrates only the requested kart template on demand (never the full roster at boot).
function KartAssetHydrator.hydrateKart(kartId: string): boolean
	if hydratedKartCache[kartId] then
		return true
	end
	while inFlightKarts[kartId] do
		task.wait(0.05)
	end
	if hydratedKartCache[kartId] then
		return true
	end
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local kartsFolder = if assets then assets:FindFirstChild("Karts") else nil
	if kartsFolder == nil then
		return false
	end
	local template = kartsFolder:FindFirstChild(kartId)
	if not (template and template:IsA("Model")) then
		return false
	end

	inFlightKarts[kartId] = true
	local toHydrate: { MeshPart } = {}
	for _, child in template:GetChildren() do
		if child:IsA("MeshPart") and needsHydration(child) then
			table.insert(toHydrate, child)
		end
	end
	if #toHydrate > 0 then
		local t0 = os.clock()
		local pending = #toHydrate
		local hydratedCount = 0
		for _, part in toHydrate do
			task.spawn(function()
				local mp = hydrateMeshPart(part)
				if mp ~= nil and mp.MeshId ~= "" and mp.MeshSize.Magnitude > 1e-4 then
					hydratedCount += 1
				end
				pending -= 1
			end)
		end
		while pending > 0 do
			task.wait()
		end
		print(
			string.format(
				"[OpenKart] Lazy hydrated kart '%s' (%d/%d MeshParts in %.1f ms)",
				kartId,
				hydratedCount,
				#toHydrate,
				(os.clock() - t0) * 1000
			)
		)
	end

	local allReady = true
	for _, child in template:GetChildren() do
		if child:IsA("MeshPart") and (child.MeshId == "" or child.MeshSize.Magnitude <= 1e-4) then
			allReady = false
			break
		end
	end
	if allReady then
		local expected = KartBoundsData.karts[kartId]
		if expected ~= nil then
			KartAssetHydrator.assertSubmeshBounds(template, expected, KartBoundsData.TOLERANCE_STUDS)
		end
		hydratedKartCache[kartId] = true
	end
	template:SetAttribute("MeshesHydrated", allReady)
	inFlightKarts[kartId] = nil
	return allReady
end

function KartAssetHydrator.hydrateAll(): number
	local t0 = os.clock()
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	if assets == nil then
		return 0
	end
	-- Boot hydrates ONLY Items and Tracks (0 karts hydrated at boot; karts hydrate lazily on preview/race).
	local kartsCount = 0
	local itemBounds: { [string]: { [string]: { number } } } = {}
	for itemId, subs in ItemBoundsData.items do
		local byPart: { [string]: { number } } = {}
		for partName, info in subs do
			byPart[partName] = info.size
		end
		itemBounds[itemId] = byPart
	end
	local itemsCount = hydrateModelFolder(assets:FindFirstChild("Items"), itemBounds)
	local tracksFolder = assets:FindFirstChild("Tracks")
	local tracksCount = 0
	if tracksFolder then
		for _, trackModel in tracksFolder:GetChildren() do
			if trackModel:IsA("Model") then
				for _, subFolder in trackModel:GetChildren() do
					if subFolder:IsA("Folder") then
						tracksCount += hydrateModelFolder(subFolder, nil)
					end
				end
				if trackModel.Name == "sandtrack" then
					local surfaces = trackModel:FindFirstChild("Surfaces")
					if surfaces then
						local expBounds =
							SandtrackData.expectedBounds :: { [string]: { size: { number }, tris: number } }
						for pname, info in expBounds do
							if string.sub(pname, 1, 8) == "Submesh_" then
								local mp = surfaces:FindFirstChild(pname)
								if mp and mp:IsA("MeshPart") then
									local dx = math.abs(mp.Size.X - info.size[1])
									local dy = math.abs(mp.Size.Y - info.size[2])
									local dz = math.abs(mp.Size.Z - info.size[3])
									if dx > 0.05 or dy > 0.05 or dz > 0.05 then
										error(string.format("[OpenKart] Sandtrack bounds mismatch on %s", pname))
									end
								end
							end
						end
					end
				end
			end
		end
	end
	print(
		string.format(
			"[OpenKart] HydrateAll total=%.1f ms (karts=%d items=%d tracks=%d)",
			(os.clock() - t0) * 1000,
			kartsCount,
			itemsCount,
			tracksCount
		)
	)
	local itemsFolder = assets:FindFirstChild("Items")
	if itemsFolder then
		for _, itemModel in itemsFolder:GetChildren() do
			if itemModel:IsA("Model") then
				for _, child in itemModel:GetChildren() do
					if child:IsA("BasePart") and not child:IsA("MeshPart") then
						error(
							string.format(
								"[OpenKart] Non-MeshPart '%s' found in item template '%s'",
								child.Name,
								itemModel.Name
							)
						)
					end
				end
				local expected = itemBounds[itemModel.Name]
				if expected ~= nil then
					KartAssetHydrator.assertSubmeshBounds(itemModel, expected, ItemBoundsData.TOLERANCE_STUDS)
				end
			end
		end
	end
	return kartsCount + itemsCount + tracksCount
end

return table.freeze(KartAssetHydrator)
