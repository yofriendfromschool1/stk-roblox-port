--!strict
-- src/client/kart/KartPresentation.lua
-- SPDX-License-Identifier: GPL-3.0-or-later
-- ported from src/karts/kart_model.cpp:L471-L486, L1267-L1311 (STK 1.5)
-- Client visual assembly for Tux kart (hydrated MeshParts, rigid wheel spin/steer/suspension,
-- skid sparks, and Nitro exhaust flames/light).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GreyboxProtocol = require(Shared.net.GreyboxProtocol)
local ItemTuning = require(Shared.ItemTuning)
local ItemVisuals = require("../items/ItemVisuals")
local KartTuning = require(Shared.KartTuning)
local KartVisualMath = require(Shared.kart.KartVisualMath)
local TuxBoundsData = require(Shared.kart.TuxBoundsData)
local Units = require(Shared.Units)

export type StaticSubpart = {
	part: BasePart,
	localCf: CFrame,
	baseSize: Vector3,
}

export type WheelVisual = {
	part: BasePart,
	localPos: Vector3,
	baseOrientCf: CFrame,
	radiusMeters: number,
	spinRad: number,
}

export type AttachmentVisual = {
	part: MeshPart,
	localCf: CFrame,
	activeTransparency: number,
}

export type VisualKart = {
	model: Model,
	isTexturedMesh: boolean,
	staticParts: { StaticSubpart },
	wheels: { WheelVisual }, -- 1: FL, 2: FR, 3: RL, 4: RR
	attachments: { [number]: AttachmentVisual },
	plungerFacePart: MeshPart?,
	plungerFaceLocalCf: CFrame,
	sparkLeft: Part,
	sparkRight: Part,
	sparkLocalLeftCf: CFrame,
	sparkLocalRightCf: CFrame,
	skidEmitterL: ParticleEmitter,
	skidEmitterR: ParticleEmitter,
	exhaustLeft: Part,
	exhaustRight: Part,
	exhaustLocalLeftCf: CFrame,
	exhaustLocalRightCf: CFrame,
	nitroEmitterL: ParticleEmitter,
	nitroEmitterR: ParticleEmitter,
	nitroLight: PointLight,
}

local TIER_COLORS: { [number]: Color3 } = {
	[0] = Color3.fromRGB(220, 225, 235),
	[1] = Color3.fromRGB(255, 210, 40),
	[2] = Color3.fromRGB(255, 65, 45),
}

local WHEEL_SLOT_NAMES = {
	"WheelFrontLeft",
	"WheelFrontRight",
	"WheelRearLeft",
	"WheelRearRight",
}

local STATIC_MESH_NAMES = {
	"Body_Engine",
	"Body_Chassis",
	"Body_Steering",
	"Driver",
}

local FLIP_Y180_CF = CFrame.Angles(0, math.pi, 0)

local KartPresentation = {}

local function resolveHydratedKartTemplate(kartId: string): Model?
	local assets = ReplicatedStorage:FindFirstChild("Assets") or ReplicatedStorage:WaitForChild("Assets", 5)
	if not assets then
		return nil
	end
	local karts = assets:FindFirstChild("Karts") or assets:WaitForChild("Karts", 5)
	if not karts then
		return nil
	end
	local template = karts:FindFirstChild(kartId) or karts:WaitForChild(kartId, 5)
	if not (template and template:IsA("Model")) then
		return nil
	end

	local deadline = os.clock() + 5.0
	while template:GetAttribute("MeshesHydrated") ~= true and os.clock() < deadline do
		local ready = true
		local meshCount = 0
		for _, child in template:GetChildren() do
			if child:IsA("MeshPart") then
				meshCount += 1
				if child.MeshId == "" then
					ready = false
					break
				end
			end
		end
		if ready and meshCount > 0 then
			break
		end
		task.wait(0.05)
	end

	for _, child in template:GetChildren() do
		if child:IsA("MeshPart") and (child.MeshId == "" or child.MeshSize.Magnitude <= 1e-4) then
			return nil
		end
	end
	return template
end

local function assertTuxLiveBounds(model: Model)
	local tol = TuxBoundsData.TOLERANCE_STUDS
	for partName, exp in TuxBoundsData.submeshes do
		local child = model:FindFirstChild(partName)
		if not (child and child:IsA("MeshPart")) then
			error(string.format("[OpenKart] Tux missing MeshPart '%s'", partName))
		end
		local mp = child :: MeshPart
		if
			mp.MeshSize.Magnitude <= 1e-4
			or math.abs(mp.Size.X - exp[1]) > tol
			or math.abs(mp.Size.Y - exp[2]) > tol
			or math.abs(mp.Size.Z - exp[3]) > tol
		then
			error(
				string.format(
					"[OpenKart] Tux live MeshPart.Size mismatch on %s: Size=(%.4f,%.4f,%.4f) MeshSize=(%.4f,%.4f,%.4f) expected=(%.4f,%.4f,%.4f)",
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

local function makeVfxHolder(
	name: string,
	size: Vector3,
	color: Color3,
	material: Enum.Material,
	parent: Instance
): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.Massless = true
	part.Size = size
	part.Color = color
	part.Material = material
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

local function attachVfx(
	model: Model,
	profile: KartTuning.KartProfile
): (
	Part,
	Part,
	CFrame,
	CFrame,
	ParticleEmitter,
	ParticleEmitter,
	Part,
	Part,
	CFrame,
	CFrame,
	ParticleEmitter,
	ParticleEmitter,
	PointLight
)
	local wStuds = Units.metersToStuds(profile.width)
	local lStuds = Units.metersToStuds(profile.length)

	local sparkSize = Vector3.new(Units.metersToStuds(0.13), Units.metersToStuds(0.10), Units.metersToStuds(0.16))
	local function makeSkidUnit(name: string, localCf: CFrame): (Part, CFrame, ParticleEmitter)
		local bar = makeVfxHolder(name, sparkSize, TIER_COLORS[0], Enum.Material.Neon, model)
		bar.Transparency = 0.85
		bar.CFrame = localCf

		local em = Instance.new("ParticleEmitter")
		em.Name = name .. "_Emitter"
		em.Enabled = false
		em.Rate = 45
		em.Lifetime = NumberRange.new(0.15, 0.30)
		em.Speed = NumberRange.new(2, 5)
		em.SpreadAngle = Vector2.new(25, 25)
		em.EmissionDirection = Enum.NormalId.Back
		em.Size = NumberSequence.new(0.14, 0.02)
		em.Color = ColorSequence.new(TIER_COLORS[1])
		em.LightEmission = 0.9
		em.Parent = bar
		return bar, localCf, em
	end

	-- Place sparks just behind rear wheels near ground contact (kart_gfx.cpp:L69-L89)
	local sparkLocalLeftCf = CFrame.new(-0.355, 0.05, 0.42)
	local sparkLocalRightCf = CFrame.new(0.355, 0.05, 0.42)
	local sparkLeft, _, skidEmitterL = makeSkidUnit("SparkLeft", sparkLocalLeftCf)
	local sparkRight, _, skidEmitterR = makeSkidUnit("SparkRight", sparkLocalRightCf)

	-- Nitro emitters at kart.xml:L34-L37 (+-0.20, 0.36, +0.58) relative to kart origin
	local function makeExhaustUnit(name: string, localCf: CFrame): (Part, CFrame, ParticleEmitter)
		local holder =
			makeVfxHolder(name, Vector3.new(0.08, 0.08, 0.08), Color3.fromRGB(60, 68, 82), Enum.Material.Metal, model)
		holder.Transparency = 1.0
		holder.CFrame = localCf

		local flame = Instance.new("ParticleEmitter")
		flame.Name = name .. "_NitroFlame"
		flame.Enabled = false
		flame.Rate = 75
		flame.Lifetime = NumberRange.new(0.12, 0.22)
		flame.Speed = NumberRange.new(6, 11)
		flame.SpreadAngle = Vector2.new(10, 10)
		flame.EmissionDirection = Enum.NormalId.Back
		flame.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.22),
			NumberSequenceKeypoint.new(1, 0.04),
		})
		flame.Color = ColorSequence.new(Color3.fromRGB(40, 215, 255), Color3.fromRGB(0, 102, 255))
		flame.LightEmission = 1.0
		flame.Parent = holder
		return holder, localCf, flame
	end

	local exhaustLocalLeftCf = CFrame.new(-math.min(0.20, wStuds * 0.25), 0.36, math.min(0.58, lStuds * 0.45))
	local exhaustLocalRightCf = CFrame.new(math.min(0.20, wStuds * 0.25), 0.36, math.min(0.58, lStuds * 0.45))
	local exhaustLeft, _, nitroEmitterL = makeExhaustUnit("ExhaustLeft", exhaustLocalLeftCf)
	local exhaustRight, _, nitroEmitterR = makeExhaustUnit("ExhaustRight", exhaustLocalRightCf)

	local nitroLight = Instance.new("PointLight")
	nitroLight.Name = "NitroLight"
	nitroLight.Enabled = false
	nitroLight.Color = Color3.fromRGB(0, 102, 255) -- kart_gfx.cpp:L61 (0, 0.4, 1.0)
	nitroLight.Range = 10
	nitroLight.Brightness = 2.0
	nitroLight.Parent = exhaustLeft

	return sparkLeft,
		sparkRight,
		sparkLocalLeftCf,
		sparkLocalRightCf,
		skidEmitterL,
		skidEmitterR,
		exhaustLeft,
		exhaustRight,
		exhaustLocalLeftCf,
		exhaustLocalRightCf,
		nitroEmitterL,
		nitroEmitterR,
		nitroLight
end

local function buildGreyboxFallback(model: Model, profile: KartTuning.KartProfile): ({ StaticSubpart }, { WheelVisual })
	local wStuds = Units.metersToStuds(profile.width)
	local hStuds = Units.metersToStuds(profile.collisionHeight)
	local lStuds = Units.metersToStuds(profile.length)

	local chassis = makeVfxHolder(
		"Chassis",
		Vector3.new(wStuds, hStuds * 0.65, lStuds),
		Color3.fromRGB(45, 130, 235),
		Enum.Material.SmoothPlastic,
		model
	)
	local nose = makeVfxHolder(
		"NoseMarker",
		Vector3.new(wStuds * 0.65, hStuds * 0.35, lStuds * 0.25),
		Color3.fromRGB(245, 245, 250),
		Enum.Material.SmoothPlastic,
		model
	)

	local staticParts: { StaticSubpart } = {
		{ part = chassis :: BasePart, localCf = CFrame.new(0, hStuds * 0.5, 0), baseSize = chassis.Size },
		{ part = nose :: BasePart, localCf = CFrame.new(0, hStuds * 0.75, -lStuds * 0.35), baseSize = nose.Size },
	}

	local wheels: { WheelVisual } = {}
	local wheelSize = Vector3.new(Units.metersToStuds(0.18), Units.metersToStuds(0.28), Units.metersToStuds(0.28))
	for i, hp in profile.wheelHardpoints do
		local w = makeVfxHolder(WHEEL_SLOT_NAMES[i], wheelSize, Color3.fromRGB(30, 32, 36), Enum.Material.Rubber, model)
		local r = if i <= 2 then 0.11 else 0.14
		table.insert(wheels, {
			part = w :: BasePart,
			localPos = Vector3.new(Units.metersToStuds(hp.x), r, Units.metersToStuds(-hp.z)),
			baseOrientCf = CFrame.identity,
			radiusMeters = r,
			spinRad = 0.0,
		})
	end

	return staticParts, wheels
end

function KartPresentation.create(kartKey: Player | string, profile: KartTuning.KartProfile, kartId: string?): VisualKart
	local keyStr = if typeof(kartKey) == "string" then kartKey else tostring((kartKey :: Player).UserId)
	local folder = Workspace:FindFirstChild(GreyboxProtocol.LOCAL_KARTS_FOLDER)
	if not folder then
		local f = Instance.new("Folder")
		f.Name = GreyboxProtocol.LOCAL_KARTS_FOLDER
		f.Parent = Workspace
		folder = f
	end

	local existing = (folder :: Folder):FindFirstChild("Kart_" .. keyStr)
	if existing then
		existing:Destroy()
	end

	local template = resolveHydratedKartTemplate(kartId or "tux")
	local model: Model
	local staticParts: { StaticSubpart } = {}
	local wheels: { WheelVisual } = {}
	local isTexturedMesh = false

	if template ~= nil then
		model = template:Clone()
		model.Name = "Kart_" .. keyStr
		if (kartId or "tux") == "tux" then
			assertTuxLiveBounds(model)
		end
		isTexturedMesh = true

		local chassisRoot = model:FindFirstChild("ChassisRoot")
		if chassisRoot and chassisRoot:IsA("BasePart") then
			chassisRoot.Anchored = true
			chassisRoot.CanCollide = false
			chassisRoot.CanTouch = false
			chassisRoot.CanQuery = false
			chassisRoot.Massless = true
			model.PrimaryPart = chassisRoot
			table.insert(staticParts, {
				part = chassisRoot,
				localCf = chassisRoot.CFrame,
				baseSize = chassisRoot.Size,
			})
		end

		for _, name in STATIC_MESH_NAMES do
			local p = model:FindFirstChild(name)
			if p and p:IsA("BasePart") then
				p.Anchored = true
				p.CanCollide = false
				p.CanTouch = false
				p.CanQuery = false
				p.Massless = true
				local lx = p:GetAttribute("LocalPosX")
				local ly = p:GetAttribute("LocalPosY")
				local lz = p:GetAttribute("LocalPosZ")
				local pos = if type(lx) == "number"
						and type(ly) == "number"
						and type(lz) == "number"
					then Vector3.new(lx, ly, lz)
					else p.Position
				local orient = if p:GetAttribute("ImportFlipY180") == true then FLIP_Y180_CF else CFrame.identity
				table.insert(staticParts, {
					part = p,
					localCf = CFrame.new(pos) * orient,
					baseSize = p.Size,
				})
			end
		end

		for i, slotName in WHEEL_SLOT_NAMES do
			local wPart = model:FindFirstChild(slotName)
			if wPart and wPart:IsA("BasePart") then
				wPart.Anchored = true
				wPart.CanCollide = false
				wPart.CanTouch = false
				wPart.CanQuery = false
				wPart.Massless = true
				local lx = wPart:GetAttribute("LocalPosX")
				local ly = wPart:GetAttribute("LocalPosY")
				local lz = wPart:GetAttribute("LocalPosZ")
				local pos = if type(lx) == "number"
						and type(ly) == "number"
						and type(lz) == "number"
					then Vector3.new(lx, ly, lz)
					else wPart.Position
				local rawR = wPart:GetAttribute("WheelRadiusStuds")
				local radius = if type(rawR) == "number"
					then Units.studsToMeters(rawR)
					else (if i <= 2 then 0.11 else 0.14)
				local orient = if wPart:GetAttribute("ImportFlipY180") == true then FLIP_Y180_CF else CFrame.identity
				table.insert(wheels, {
					part = wPart,
					localPos = pos,
					baseOrientCf = orient,
					radiusMeters = radius,
					spinRad = 0.0,
				})
			end
		end
	else
		warn("[OpenKart] Hydrated Tux template missing; falling back to greybox kart primitives")
		model = Instance.new("Model")
		model.Name = "Kart_" .. keyStr
		staticParts, wheels = buildGreyboxFallback(model, profile)
		local rootPart = makeVfxHolder(
			"ChassisRoot",
			Vector3.new(0.2, 0.2, 0.2),
			Color3.new(1, 1, 1),
			Enum.Material.SmoothPlastic,
			model
		)
		rootPart.Transparency = 1
		model.PrimaryPart = rootPart
		table.insert(staticParts, { part = rootPart :: BasePart, localCf = CFrame.identity, baseSize = rootPart.Size })
	end

	local sparkLeft, sparkRight, sparkLocalLeftCf, sparkLocalRightCf, skidEmitterL, skidEmitterR, exhaustLeft, exhaustRight, exhaustLocalLeftCf, exhaustLocalRightCf, nitroEmitterL, nitroEmitterR, nitroLight =
		attachVfx(model, profile)

	local attachmentDefs = {
		{ atype = ItemTuning.ATTACHMENT_BUBBLEGUM_SHIELD, itemId = "bubblegum_shield", trans = 0.45 },
		{ atype = ItemTuning.ATTACHMENT_PARACHUTE, itemId = "parachute", trans = 0.0 },
		{ atype = ItemTuning.ATTACHMENT_ANVIL, itemId = "anchor", trans = 0.0 },
		{ atype = ItemTuning.ATTACHMENT_BOMB, itemId = "bomb", trans = 0.0 },
		{ atype = ItemTuning.ATTACHMENT_SWATTER, itemId = "swatter", trans = 0.0 },
	}
	local attachments: { [number]: AttachmentVisual } = {}
	for _, def in attachmentDefs do
		local created = ItemVisuals.create(def.itemId, "attachment")
		if created then
			local mp = created.subparts[1].part
			mp.Name = "Attach_" .. def.itemId
			mp.Transparency = 1.0
			local localCf: CFrame
			if def.atype == ItemTuning.ATTACHMENT_BUBBLEGUM_SHIELD then
				-- attachment.cpp:L614-L615 scale = max(1.0, kart.highestPoint * 1.1)
				local shieldScale = math.max(1.0, profile.collisionHeight * 1.1)
				mp.Size = mp.Size * shieldScale
				localCf = CFrame.new(0, 0.35, 0) * created.subparts[1].baseRot
			else
				localCf = CFrame.new(created.subparts[1].localPos) * created.subparts[1].baseRot
			end
			mp.Parent = model
			created.model:Destroy()
			attachments[def.atype] = {
				part = mp,
				localCf = localCf,
				activeTransparency = def.trans,
			}
		end
	end

	local plungerFacePart: MeshPart? = nil
	-- Measured from tux.spm frame-20 Driver submesh eye/face surface (docs/kart-spec.md:L59-L83); rigid approximation.
	-- Unflipped plunger mesh places the +Z suction cup against Tux's beak/eyes (~z=-0.20) with handle extending -Z.
	local plungerFaceLocalCf = CFrame.new(0, 0.58, -0.62)
	local createdPlunger = ItemVisuals.create("plunger", "attachment")
	if createdPlunger then
		local pFace = createdPlunger.subparts[1].part
		pFace.Name = "Attach_plunger_face"
		pFace.Transparency = 1.0
		pFace.Parent = model
		createdPlunger.model:Destroy()
		plungerFacePart = pFace
	end

	model.Parent = folder

	return {
		model = model,
		isTexturedMesh = isTexturedMesh,
		staticParts = staticParts,
		wheels = wheels,
		attachments = attachments,
		plungerFacePart = plungerFacePart,
		plungerFaceLocalCf = plungerFaceLocalCf,
		sparkLeft = sparkLeft,
		sparkRight = sparkRight,
		sparkLocalLeftCf = sparkLocalLeftCf,
		sparkLocalRightCf = sparkLocalRightCf,
		skidEmitterL = skidEmitterL,
		skidEmitterR = skidEmitterR,
		exhaustLeft = exhaustLeft,
		exhaustRight = exhaustRight,
		exhaustLocalLeftCf = exhaustLocalLeftCf,
		exhaustLocalRightCf = exhaustLocalRightCf,
		nitroEmitterL = nitroEmitterL,
		nitroEmitterR = nitroEmitterR,
		nitroLight = nitroLight,
	}
end

function KartPresentation.update(
	visuals: VisualKart,
	bodyCFrame: CFrame,
	speedMps: number,
	dt: number,
	steer: number,
	wheelSuspensions: { number },
	skidTier: number,
	skidState: string,
	nitroActive: boolean,
	attachmentType: number?,
	isSquashed: boolean?,
	plungerFaceTicks: number?
)
	local groundOffsetY = Units.metersToStuds(KartVisualMath.computeBodyGroundOffsetY())
	local kartOriginCf = bodyCFrame * CFrame.new(0, groundOffsetY, 0)
	local squashScaleY = if isSquashed == true then 0.5 else 1.0

	for _, sp in visuals.staticParts do
		sp.part.Size = Vector3.new(sp.baseSize.X, sp.baseSize.Y * squashScaleY, sp.baseSize.Z)
		sp.part.CFrame = kartOriginCf * sp.localCf
	end

	local steerAngleRad = KartVisualMath.computeSteerWheelAngleRad(steer)
	for i, w in visuals.wheels do
		w.spinRad = KartVisualMath.advanceWheelSpin(w.spinRad, speedMps, dt, w.radiusMeters)
		local suspLen = wheelSuspensions[i] or KartVisualMath.DEFAULT_REST_SUSPENSION_M
		local suspOffsetY = Units.metersToStuds(KartVisualMath.computeWheelSuspensionOffsetY(suspLen))
		local steerCf = if i <= 2 then CFrame.Angles(0, -steerAngleRad, 0) else CFrame.identity
		w.part.CFrame = kartOriginCf
			* CFrame.new(w.localPos.X, w.localPos.Y + suspOffsetY, w.localPos.Z)
			* steerCf
			* w.baseOrientCf
			* CFrame.Angles(w.spinRad, 0, 0)
	end

	visuals.sparkLeft.CFrame = kartOriginCf * visuals.sparkLocalLeftCf
	visuals.sparkRight.CFrame = kartOriginCf * visuals.sparkLocalRightCf
	visuals.exhaustLeft.CFrame = kartOriginCf * visuals.exhaustLocalLeftCf
	visuals.exhaustRight.CFrame = kartOriginCf * visuals.exhaustLocalRightCf

	-- Skid tier wheel sparks (src/karts/kart_gfx.cpp:L69-L89, L118-L123)
	local tierColor = TIER_COLORS[skidTier] or TIER_COLORS[0]
	local isAccum = (skidState == "SKID_ACCUMULATE_LEFT" or skidState == "SKID_ACCUMULATE_RIGHT")
	local sparkTrans = if isAccum then 0.0 else 0.85
	visuals.sparkLeft.Color = tierColor
	visuals.sparkRight.Color = tierColor
	visuals.sparkLeft.Transparency = sparkTrans
	visuals.sparkRight.Transparency = sparkTrans
	local emitSkid = isAccum and skidTier >= 1
	visuals.skidEmitterL.Enabled = emitSkid
	visuals.skidEmitterR.Enabled = emitSkid
	if emitSkid then
		local seqColor = ColorSequence.new(tierColor)
		visuals.skidEmitterL.Color = seqColor
		visuals.skidEmitterR.Color = seqColor
	end

	-- Nitro exhaust flame emitters + rear point light
	visuals.nitroEmitterL.Enabled = nitroActive
	visuals.nitroEmitterR.Enabled = nitroActive
	visuals.nitroLight.Enabled = nitroActive

	-- Active kart attachment visual mesh (attachment.cpp:L570-L635)
	local activeAttach = attachmentType or ItemTuning.ATTACHMENT_NONE
	for atype, att in visuals.attachments do
		if atype == activeAttach then
			att.part.CFrame = kartOriginCf * att.localCf
			att.part.Transparency = att.activeTransparency
		else
			att.part.Transparency = 1.0
		end
	end

	if visuals.plungerFacePart ~= nil then
		if (plungerFaceTicks or 0) > 0 then
			visuals.plungerFacePart.CFrame = kartOriginCf * visuals.plungerFaceLocalCf
			visuals.plungerFacePart.Transparency = 0.0
		else
			visuals.plungerFacePart.Transparency = 1.0
		end
	end
end

return table.freeze(KartPresentation)
