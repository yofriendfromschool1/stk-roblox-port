--!strict
-- src/shared/sim/RobloxWorldQuery.lua
-- SPDX-License-Identifier: GPL-3.0-or-later
-- Shared Roblox Workspace raycast/Blockcast WorldQuery + STK->Roblox CFrame boundary helper
-- used identically by Server authority and Client 120 Hz prediction.

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local KartSolver = require("./KartSolver")
local Math3D = require("./Math3D")
local Units = require("../Units")

local RobloxWorldQuery = {}

-- When Blockcast starts already intersecting a part, Roblox ignores that part and returns nil.
-- Broadphase uses GetPartBoundsInBox (cheap AABB reject); narrowphase uses GetPartsInPart
-- (exact CollisionFidelity / PreciseConvexDecomposition geometry, never blind to deep overlap).
-- If sweepChassis returns nil while overlapping, a shrunk-core Blockcast + backed-off center ray
-- recover the contact normal so the chassis can never phase through walls or ramp undersides.
local SWEEP_FALLBACK_CORE_SCALE = 0.45

local function getOrCreateOverlapProbe(): Part
	local probeName = if RunService:IsServer() then "_OpenKartChassisProbe_S" else "_OpenKartChassisProbe_C"
	local existing = Workspace:FindFirstChild(probeName)
	if existing and existing:IsA("Part") then
		return existing
	end
	local probe = Instance.new("Part")
	probe.Name = probeName
	probe.Anchored = true
	probe.CanCollide = false
	probe.CanQuery = false
	probe.CanTouch = false
	probe.Massless = true
	probe.CastShadow = false
	probe.Transparency = 1.0
	probe.Size = Vector3.new(1, 1, 1)
	probe.CFrame = CFrame.new(0, -10000, 0)
	probe.Parent = Workspace
	return probe
end

function RobloxWorldQuery.stkPoseToRobloxCFrame(
	pos: Math3D.Vec3,
	rot: Math3D.Quat,
	visualSkidYaw: number,
	hopHeight: number
): CFrame
	local rbxPos =
		Vector3.new(Units.metersToStuds(pos.x), Units.metersToStuds(pos.y + hopHeight), Units.metersToStuds(-pos.z))
	local right, up, fwd = Math3D.quatBasis(rot)
	-- Apply reflection S = diag(1, 1, -1) (det(S) = -1) to basis vectors; back_rbx = -fwd_rbx
	local rbxRight = Vector3.new(right.x, right.y, -right.z)
	local rbxUp = Vector3.new(up.x, up.y, -up.z)
	local rbxBack = Vector3.new(-fwd.x, -fwd.y, fwd.z)
	local baseCFrame = CFrame.fromMatrix(rbxPos, rbxRight, rbxUp, rbxBack)
	if visualSkidYaw ~= 0 then
		return baseCFrame * CFrame.Angles(0, -visualSkidYaw, 0)
	end
	return baseCFrame
end

function RobloxWorldQuery.create(surfacesFolder: Instance): KartSolver.WorldQuery
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Include
	rayParams.FilterDescendantsInstances = { surfacesFolder }
	rayParams.RespectCanCollide = true

	local sweepParams = RaycastParams.new()
	sweepParams.FilterType = Enum.RaycastFilterType.Include
	sweepParams.FilterDescendantsInstances = { surfacesFolder }
	sweepParams.RespectCanCollide = true

	local overlapParams = OverlapParams.new()
	overlapParams.FilterType = Enum.RaycastFilterType.Include
	overlapParams.FilterDescendantsInstances = { surfacesFolder }
	overlapParams.RespectCanCollide = true

	local probePart = getOrCreateOverlapProbe()

	local function hasExactOverlap(rbxCf: CFrame, rbxSize: Vector3): boolean
		if #Workspace:GetPartBoundsInBox(rbxCf, rbxSize, overlapParams) == 0 then
			return false
		end
		probePart.Size = rbxSize
		probePart.CFrame = rbxCf
		return #Workspace:GetPartsInPart(probePart, overlapParams) > 0
	end

	local function toSweepHit(result: RaycastResult, frac: number): KartSolver.SweepHit
		local rawMat = result.Instance:GetAttribute("SurfaceMaterial")
		local matName = if type(rawMat) == "string" then rawMat else nil
		return {
			fraction = math.clamp(frac, 0.0, 1.0),
			point = {
				x = Units.studsToMeters(result.Position.X),
				y = Units.studsToMeters(result.Position.Y),
				z = Units.studsToMeters(-result.Position.Z),
			},
			normal = {
				x = result.Normal.X,
				y = result.Normal.Y,
				z = -result.Normal.Z,
			},
			materialName = matName,
		}
	end

	local function toRobloxBoxCFrameAndSize(
		center: Math3D.Vec3,
		rot: Math3D.Quat,
		halfExtents: Math3D.Vec3
	): (CFrame, Vector3)
		local rbxCenter =
			Vector3.new(Units.metersToStuds(center.x), Units.metersToStuds(center.y), Units.metersToStuds(-center.z))
		local right, up, fwd = Math3D.quatBasis(rot)
		local rbxCf = CFrame.fromMatrix(
			rbxCenter,
			Vector3.new(right.x, right.y, -right.z),
			Vector3.new(up.x, up.y, -up.z),
			Vector3.new(-fwd.x, -fwd.y, fwd.z)
		)
		local rbxSize = Vector3.new(
			Units.metersToStuds(halfExtents.x * 2),
			Units.metersToStuds(halfExtents.y * 2),
			Units.metersToStuds(halfExtents.z * 2)
		)
		return rbxCf, rbxSize
	end

	return {
		raycast = function(origin: Math3D.Vec3, dir: Math3D.Vec3, length: number): KartSolver.RayHit?
			local rbxOrigin = Vector3.new(
				Units.metersToStuds(origin.x),
				Units.metersToStuds(origin.y),
				Units.metersToStuds(-origin.z)
			)
			local rbxDir = Vector3.new(dir.x, dir.y, -dir.z) * Units.metersToStuds(length)
			local result = Workspace:Raycast(rbxOrigin, rbxDir, rayParams)
			if result == nil then
				return nil
			end
			local rawMat = result.Instance:GetAttribute("SurfaceMaterial")
			local matName = if type(rawMat) == "string" then rawMat else nil
			return {
				distance = Units.studsToMeters(result.Distance),
				point = {
					x = Units.studsToMeters(result.Position.X),
					y = Units.studsToMeters(result.Position.Y),
					z = Units.studsToMeters(-result.Position.Z),
				},
				normal = {
					x = result.Normal.X,
					y = result.Normal.Y,
					z = -result.Normal.Z,
				},
				materialName = matName,
			}
		end,

		sweepChassis = function(
			center: Math3D.Vec3,
			rot: Math3D.Quat,
			halfExtents: Math3D.Vec3,
			delta: Math3D.Vec3
		): KartSolver.SweepHit?
			local rbxDelta =
				Vector3.new(Units.metersToStuds(delta.x), Units.metersToStuds(delta.y), Units.metersToStuds(-delta.z))
			local deltaMag = rbxDelta.Magnitude
			if deltaMag < 1e-6 then
				return nil
			end
			local rbxCf, rbxSize = toRobloxBoxCFrameAndSize(center, rot, halfExtents)
			local result = Workspace:Blockcast(rbxCf, rbxSize, rbxDelta, sweepParams)
			if result ~= nil then
				return toSweepHit(result, result.Distance / deltaMag)
			end

			-- Fallback when starting box already touches/penetrates a surface (Blockcast ignores initial overlaps)
			if not hasExactOverlap(rbxCf, rbxSize) then
				return nil
			end

			local dir = rbxDelta / deltaMag
			local halfAlong = 0.5
				* (
					math.abs(dir:Dot(rbxCf.RightVector)) * rbxSize.X
					+ math.abs(dir:Dot(rbxCf.UpVector)) * rbxSize.Y
					+ math.abs(dir:Dot(rbxCf.LookVector)) * rbxSize.Z
				)
			local coreSize = rbxSize * SWEEP_FALLBACK_CORE_SCALE
			local margin = halfAlong * (1.0 - SWEEP_FALLBACK_CORE_SCALE)
			local coreRes = Workspace:Blockcast(rbxCf, coreSize, dir * (margin + deltaMag), sweepParams)
			if coreRes ~= nil and coreRes.Normal:Dot(dir) < -1e-4 then
				return toSweepHit(coreRes, (coreRes.Distance - margin) / deltaMag)
			end

			local rayRes =
				Workspace:Raycast(rbxCf.Position - dir * halfAlong, dir * (2.0 * halfAlong + deltaMag), sweepParams)
			if rayRes ~= nil and rayRes.Normal:Dot(dir) < -1e-4 then
				return toSweepHit(rayRes, 0.0)
			end
			return nil
		end,

		checkChassisOverlap = function(center: Math3D.Vec3, rot: Math3D.Quat, halfExtents: Math3D.Vec3): boolean
			local rbxCf, rbxSize = toRobloxBoxCFrameAndSize(center, rot, halfExtents)
			return hasExactOverlap(rbxCf, rbxSize)
		end,
	}
end

return table.freeze(RobloxWorldQuery)
