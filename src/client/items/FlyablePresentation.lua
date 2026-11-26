--!strict
-- src/client/items/FlyablePresentation.lua
-- SPDX-License-Identifier: GPL-3.0-or-later
-- Visual renderer for active Flyable projectiles (bowling, cake, plunger, rubber_ball) & rubber band.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Flyable = require(Shared.sim.Flyable)
local ItemVisuals = require("./ItemVisuals")
local RobloxWorldQuery = require(Shared.sim.RobloxWorldQuery)
local Units = require(Shared.Units)

export type FlyableVisual = {
	id: number,
	kind: Flyable.FlyableKind,
	container: Model,
	subpart: MeshPart,
	baseRot: CFrame,
	bandPart: Part?,
}

export type FlyablePresentationController = {
	folder: Folder,
	instances: { [number]: FlyableVisual },
}

local FlyablePresentation = {}

local function createVisual(entry: Flyable.FlyableEntry, folder: Folder): FlyableVisual?
	local created = ItemVisuals.create(entry.kind, "flyable")
	if created == nil then
		return nil
	end

	local cloned = created.model
	cloned.Name = string.format("Fly_%d_%s", entry.id, entry.kind)
	local mainPart = created.subparts[1].part
	local baseRot = created.subparts[1].baseRot

	local bandPart: Part? = nil
	if entry.kind == "plunger" then
		local p = Instance.new("Part")
		p.Name = "RubberBand"
		p.Anchored = true
		p.CanCollide = false
		p.CanTouch = false
		p.CanQuery = false
		p.Massless = true
		p.Material = Enum.Material.Neon
		p.Color = Color3.fromRGB(205, 35, 35)
		p.Transparency = 1.0
		p.Size = Vector3.new(0.14, 0.14, 1.0)
		p.Parent = cloned
		bandPart = p
	end

	cloned.Parent = folder
	return {
		id = entry.id,
		kind = entry.kind,
		container = cloned,
		subpart = mainPart :: MeshPart,
		baseRot = baseRot,
		bandPart = bandPart,
	}
end

function FlyablePresentation.create(): FlyablePresentationController
	local existing = Workspace:FindFirstChild("LocalFlyables")
	if existing then
		existing:Destroy()
	end
	local folder = Instance.new("Folder")
	folder.Name = "LocalFlyables"
	folder.Parent = Workspace
	return {
		folder = folder,
		instances = {},
	}
end

function FlyablePresentation.sync(
	ctrl: FlyablePresentationController,
	flyWorld: Flyable.FlyableWorldState,
	nowSec: number,
	kartPositionsById: { [number]: Vector3 }
)
	local seen: { [number]: boolean } = {}
	for _, entry in flyWorld.entries do
		seen[entry.id] = true
		local vis: FlyableVisual? = ctrl.instances[entry.id]
		if vis == nil then
			local created = createVisual(entry, ctrl.folder)
			if created == nil then
				continue
			end
			ctrl.instances[entry.id] = created
			vis = created
		end
		local active = vis :: FlyableVisual
		if entry.movedToInfinity then
			active.subpart.Transparency = 1.0
		else
			active.subpart.Transparency = 0.0
			local cf = RobloxWorldQuery.stkPoseToRobloxCFrame(entry.pos, entry.rot, 0, 0)
			if entry.kind == "bowling" or entry.kind == "cake" or entry.kind == "rubber_ball" then
				cf = cf * CFrame.Angles(0, (nowSec * 6.0) % (2.0 * math.pi), 0)
			end
			active.subpart.CFrame = cf * active.baseRot
		end

		if active.bandPart ~= nil then
			local ownerRbx: Vector3? = kartPositionsById[entry.ownerId]
			local targetRbx: Vector3? = nil
			if entry.bandState == 1 then
				targetRbx = Vector3.new(
					Units.metersToStuds(entry.pos.x),
					Units.metersToStuds(entry.pos.y),
					Units.metersToStuds(-entry.pos.z)
				)
			elseif entry.bandState == 2 then
				targetRbx = kartPositionsById[entry.bandTargetKartId] :: Vector3?
			elseif entry.bandState == 3 then
				targetRbx = Vector3.new(
					Units.metersToStuds(entry.bandAnchorPos.x),
					Units.metersToStuds(entry.bandAnchorPos.y),
					Units.metersToStuds(-entry.bandAnchorPos.z)
				)
			end

			if ownerRbx ~= nil and targetRbx ~= nil and (targetRbx - ownerRbx).Magnitude > 0.1 then
				local dist = (targetRbx - ownerRbx).Magnitude
				active.bandPart.Size = Vector3.new(0.14, 0.14, dist)
				active.bandPart.CFrame = CFrame.lookAt((ownerRbx + targetRbx) * 0.5, targetRbx)
				active.bandPart.Transparency = 0.0
			else
				active.bandPart.Transparency = 1.0
			end
		end
	end

	for id, vis in ctrl.instances do
		if not seen[id] then
			vis.container:Destroy()
			ctrl.instances[id] = nil
		end
	end
end

return table.freeze(FlyablePresentation)
