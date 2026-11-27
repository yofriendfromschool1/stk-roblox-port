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
local KartBoundsData = require(Shared.kart.KartBoundsData)
local KartTuning = require(Shared.KartTuning)
local KartVisualMath = require(Shared.kart.KartVisualMath)
local RefereePresentation = require("./RefereePresentation")
local SkinVariantPalette = require(Shared.settings.SkinVariantPalette)
local SlipstreamVfx = require("./SlipstreamVfx")
local SlipstreamVfxMath = require(Shared.kart.SlipstreamVfxMath)
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
	slipstreamVfx: SlipstreamVfx.SlipstreamVfxInstance,
	rescueBird: RefereePresentation.RescueBirdHandle?,
	bombGui: BillboardGui?,
	bombHand: Frame?,
	bombSecLabel: TextLabel?,
	nametagGui: BillboardGui?,
	nametagLabel: TextLabel?,
	variantHighlight: Highlight?,
	appliedVariantIdx: number?,
	kartHeightM: number,
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

local WHEEL_SLOT_SET: { [string]: boolean } = {
	WheelFrontLeft = true,
	WheelFrontRight = true,
	WheelRearLeft = true,
	WheelRearRight = true,
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

local function assertKartLiveBounds(model: Model, kartId: string)
	local expected = KartBoundsData.karts[kartId]
	if expected == nil then
		return
	end
	local tol = KartBoundsData.TOLERANCE_STUDS
	for partName, exp in expected do
		local child = model:FindFirstChild(partName)
		if not (child and child:IsA("MeshPart")) then
			error(string.format("[OpenKart] %s missing MeshPart '%s'", kartId, partName))
		end
		local mp = child :: MeshPart
		if
			mp.MeshSize.Magnitude <= 1e-4
			or math.abs(mp.Size.X - math.max(exp[1], 0.05)) > tol
			or math.abs(mp.Size.Y - math.max(exp[2], 0.05)) > tol
			or math.abs(mp.Size.Z - math.max(exp[3], 0.05)) > tol
		then
			error(
				string.format(
					"[OpenKart] %s live MeshPart.Size mismatch on %s: Size=(%.4f,%.4f,%.4f) MeshSize=(%.4f,%.4f,%.4f) expected=(%.4f,%.4f,%.4f)",
					kartId,
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

function KartPresentation.create(
	kartKey: Player | string,
	profile: KartTuning.KartProfile,
	kartId: string?,
	nametagText: string?,
	skinVariant: (string | number)?
): VisualKart
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

	local resolvedKartId = kartId or "tux"
	local template = resolveHydratedKartTemplate(resolvedKartId)
	local model: Model
	local staticParts: { StaticSubpart } = {}
	local wheels: { WheelVisual } = {}
	local isTexturedMesh = false

	if template ~= nil then
		model = template:Clone()
		model.Name = "Kart_" .. keyStr
		assertKartLiveBounds(model, resolvedKartId)
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

		for _, child in model:GetChildren() do
			if child:IsA("BasePart") and child.Name ~= "ChassisRoot" and not WHEEL_SLOT_SET[child.Name] then
				local p = child :: BasePart
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

	local slipstreamVfx = SlipstreamVfx.create(model, profile)
	local rescueBird = RefereePresentation.createRescueBird(model)

	local bombGui: BillboardGui? = nil
	local bombHand: Frame? = nil
	local bombSecLabel: TextLabel? = nil
	local bombAttach = attachments[ItemTuning.ATTACHMENT_BOMB]
	if bombAttach ~= nil then
		local bg = Instance.new("BillboardGui")
		bg.Name = "BombCountdownGui"
		bg.Adornee = bombAttach.part
		bg.Size = UDim2.fromOffset(46, 46)
		bg.StudsOffsetWorldSpace = Vector3.new(0, 1.45, 0)
		bg.AlwaysOnTop = false
		bg.MaxDistance = 120
		bg.Enabled = false
		bg.Parent = bombAttach.part

		local dial = Instance.new("Frame")
		dial.Name = "Dial"
		dial.Size = UDim2.fromScale(1, 1)
		dial.BackgroundColor3 = Color3.fromRGB(22, 22, 28)
		dial.BackgroundTransparency = 0.15
		dial.BorderSizePixel = 0
		dial.Parent = bg

		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(1, 0)
		corner.Parent = dial

		local stroke = Instance.new("UIStroke")
		stroke.Color = Color3.fromRGB(255, 190, 40)
		stroke.Thickness = 2
		stroke.Parent = dial

		local handPivot = Instance.new("Frame")
		handPivot.Name = "ArrowPivot"
		handPivot.AnchorPoint = Vector2.new(0.5, 0.5)
		handPivot.Position = UDim2.fromScale(0.5, 0.5)
		handPivot.Size = UDim2.fromScale(1, 1)
		handPivot.BackgroundTransparency = 1
		handPivot.Parent = dial

		local hand = Instance.new("Frame")
		hand.Name = "ArrowHand"
		hand.AnchorPoint = Vector2.new(0.5, 1)
		hand.Position = UDim2.fromScale(0.5, 0.5)
		hand.Size = UDim2.fromOffset(4, 17)
		hand.BackgroundColor3 = Color3.fromRGB(255, 70, 50)
		hand.BorderSizePixel = 0
		hand.Parent = handPivot

		local secLbl = Instance.new("TextLabel")
		secLbl.Name = "SecondsLabel"
		secLbl.AnchorPoint = Vector2.new(0.5, 0.5)
		secLbl.Position = UDim2.fromScale(0.5, 0.5)
		secLbl.Size = UDim2.fromOffset(26, 16)
		secLbl.BackgroundTransparency = 1
		secLbl.Font = Enum.Font.FredokaOne
		secLbl.TextSize = 12
		secLbl.TextColor3 = Color3.fromRGB(255, 240, 190)
		secLbl.TextStrokeTransparency = 0.1
		secLbl.Text = "30"
		secLbl.Parent = dial

		bombGui = bg
		bombHand = handPivot
		bombSecLabel = secLbl
	end

	-- Nametag BillboardGui attached after hydration completes (world.cpp:L563-L564: nil for local kart)
	-- Constant screen-pixel size with UITextSizeConstraint + world-space 1.5 m offset (kart.cpp:L3436)
	local nametagGui: BillboardGui? = nil
	local nametagLabel: TextLabel? = nil
	if type(nametagText) == "string" and #nametagText > 0 and model.PrimaryPart ~= nil then
		local nt = Instance.new("BillboardGui")
		nt.Name = "KartNametag"
		nt.Adornee = model.PrimaryPart
		nt.Size = UDim2.fromOffset(180, 26)
		nt.StudsOffsetWorldSpace = Vector3.new(0, 1.5, 0)
		nt.MaxDistance = 250
		nt.AlwaysOnTop = false
		nt.Parent = model.PrimaryPart

		local ntLbl = Instance.new("TextLabel")
		ntLbl.Name = "NameLabel"
		ntLbl.Size = UDim2.fromScale(1, 1)
		ntLbl.BackgroundTransparency = 1
		ntLbl.Font = Enum.Font.FredokaOne
		ntLbl.TextScaled = true
		ntLbl.TextColor3 = Color3.fromRGB(255, 190, 55)
		ntLbl.TextStrokeColor3 = Color3.fromRGB(15, 15, 20)
		ntLbl.TextStrokeTransparency = 0.0
		ntLbl.Text = nametagText
		ntLbl.Parent = nt

		local sizeConstraint = Instance.new("UITextSizeConstraint")
		sizeConstraint.MinTextSize = 14
		sizeConstraint.MaxTextSize = 22
		sizeConstraint.Parent = ntLbl

		nametagGui = nt
		nametagLabel = ntLbl
	end

	local variantHighlight = Instance.new("Highlight")
	variantHighlight.Name = "OpenKartVariantTint"
	variantHighlight.Adornee = model
	variantHighlight.DepthMode = Enum.HighlightDepthMode.Occluded
	variantHighlight.FillTransparency = 0.72
	variantHighlight.OutlineTransparency = 0.15
	variantHighlight.Parent = model

	model.Parent = folder

	local createdVisual: VisualKart = {
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
		slipstreamVfx = slipstreamVfx,
		rescueBird = rescueBird,
		bombGui = bombGui,
		bombHand = bombHand,
		bombSecLabel = bombSecLabel,
		nametagGui = nametagGui,
		nametagLabel = nametagLabel,
		variantHighlight = variantHighlight,
		appliedVariantIdx = nil,
		kartHeightM = profile.collisionHeight,
	}
	KartPresentation.applySkinVariant(createdVisual, skinVariant)
	return createdVisual
end

export type SwatterAnimInput = {
	phase: number,
	animTicks: number,
	bombMode: boolean,
	targetYawRad: number,
}

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
	plungerFaceTicks: number?,
	slipstreamVfxInput: SlipstreamVfxMath.SlipstreamVfxInput?,
	attachmentTicksLeft: number?,
	swatterAnimInput: SwatterAnimInput?,
	rescueTicks: number?
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
	local particleMultAttr = visuals.model:GetAttribute("OpenKartParticleMult")
	local particleEnabled = if typeof(particleMultAttr) == "number" then particleMultAttr > 0 else true
	local emitSkid = isAccum and skidTier >= 1 and particleEnabled
	visuals.skidEmitterL.Enabled = emitSkid
	visuals.skidEmitterR.Enabled = emitSkid
	if emitSkid then
		local seqColor = ColorSequence.new(tierColor)
		visuals.skidEmitterL.Color = seqColor
		visuals.skidEmitterR.Color = seqColor
	end

	-- Nitro exhaust flame emitters + rear point light
	local emitNitro = nitroActive and particleEnabled
	visuals.nitroEmitterL.Enabled = emitNitro
	visuals.nitroEmitterR.Enabled = emitNitro
	visuals.nitroLight.Enabled = nitroActive

	-- Active kart attachment visual mesh + expiring shield flash + tick-driven swatter/bomb-removal (attachment.cpp:L570-L668, swatter.cpp:L111-L226)
	local activeAttach = attachmentType or ItemTuning.ATTACHMENT_NONE
	local swatterPose: KartVisualMath.SwatterAnimPose? = nil
	if activeAttach == ItemTuning.ATTACHMENT_SWATTER then
		local swIn = swatterAnimInput
		swatterPose = KartVisualMath.computeSwatterAnimation(
			attachmentTicksLeft or 0,
			if swIn then swIn.phase else nil,
			if swIn then swIn.animTicks else nil,
			if swIn then swIn.bombMode else false,
			if swIn then swIn.targetYawRad else 0.0
		)
	end

	for atype, att in visuals.attachments do
		if atype == activeAttach then
			if atype == ItemTuning.ATTACHMENT_SWATTER and swatterPose ~= nil then
				local swOff = ItemTuning.swatter.POS_OFFSET
				-- STK -Z behind kart maps to Roblox +Z behind kart
				local mountPosCf = CFrame.new(
					Units.metersToStuds(swOff.x),
					Units.metersToStuds(swOff.y),
					Units.metersToStuds(-swOff.z)
				)
				att.part.CFrame = kartOriginCf
					* mountPosCf
					* CFrame.Angles(0, -swatterPose.swatterYawRad, 0)
					* CFrame.Angles(swatterPose.swatterSwingPitchRad, 0, 0)
					* att.localCf
				att.part.Transparency = att.activeTransparency
			elseif atype == ItemTuning.ATTACHMENT_BUBBLEGUM_SHIELD and attachmentTicksLeft ~= nil then
				att.part.CFrame = kartOriginCf * att.localCf
				local visible = KartVisualMath.isBubblegumShieldVisible(attachmentTicksLeft)
				att.part.Transparency = if visible then att.activeTransparency else 1.0
			else
				att.part.CFrame = kartOriginCf * att.localCf
				att.part.Transparency = att.activeTransparency
			end
		elseif atype == ItemTuning.ATTACHMENT_BOMB and swatterPose ~= nil and swatterPose.showBomb then
			att.part.CFrame = kartOriginCf
				* CFrame.new(Units.metersToStuds(swatterPose.bombOffsetXMeters), 0, 0)
				* CFrame.Angles(swatterPose.bombRotXRad, 0, 0)
				* att.localCf
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

	SlipstreamVfx.update(visuals.slipstreamVfx, kartOriginCf, slipstreamVfxInput)
	RefereePresentation.updateRescueBird(visuals.rescueBird, kartOriginCf, visuals.kartHeightM, rescueTicks or 0)
	if visuals.bombGui ~= nil and visuals.bombHand ~= nil and visuals.bombSecLabel ~= nil then
		local showBombDial = activeAttach == ItemTuning.ATTACHMENT_BOMB
		visuals.bombGui.Enabled = showBombDial
		if showBombDial then
			local bState = KartVisualMath.computeBombArrowState(attachmentTicksLeft or 0)
			visuals.bombHand.Rotation = bState.angleDeg
			visuals.bombSecLabel.Text = tostring(math.ceil(bState.timeLeftSec))
			visuals.bombSecLabel.TextColor3 = if bState.urgentFlash
				then Color3.fromRGB(255, 65, 55)
				else Color3.fromRGB(255, 240, 190)
		end
	end
end

local function applyEmitterSettings(emitter: ParticleEmitter, particleMultiplier: number)
	local baseRate = emitter:GetAttribute("OpenKartBaseRate")
	if typeof(baseRate) ~= "number" then
		baseRate = emitter.Rate
		emitter:SetAttribute("OpenKartBaseRate", baseRate)
	end
	local mult = math.clamp(particleMultiplier, 0, 1)
	emitter.Rate = (baseRate :: number) * mult
	if mult <= 0 then
		emitter.Enabled = false
	end
end

function KartPresentation.applySkinVariant(visual: VisualKart, variantOrIdx: (string | number)?): ()
	local resolvedIdx = if type(variantOrIdx) == "number"
		then math.clamp(math.floor(variantOrIdx), 1, #SkinVariantPalette.VARIANT_ORDER)
		else SkinVariantPalette.nameToIndex(if type(variantOrIdx) == "string" then variantOrIdx else nil)
	if visual.appliedVariantIdx == resolvedIdx then
		return
	end
	visual.appliedVariantIdx = resolvedIdx
	local pal = SkinVariantPalette.getPalette(resolvedIdx)
	local c = Color3.fromRGB(pal.variantColor.r, pal.variantColor.g, pal.variantColor.b)
	if visual.variantHighlight ~= nil then
		visual.variantHighlight.FillColor = c
		visual.variantHighlight.OutlineColor = c
	end
	if visual.nametagLabel ~= nil then
		local st = pal.nametagStroke
		visual.nametagLabel.TextColor3 = c
		visual.nametagLabel.TextStrokeColor3 = Color3.fromRGB(st.r, st.g, st.b)
		visual.nametagLabel.TextStrokeTransparency = 0.0
	end
end

function KartPresentation.applyVisualSettings(visual: VisualKart, shadowsEnabled: boolean, particleMultiplier: number)
	visual.model:SetAttribute("OpenKartParticleMult", math.clamp(particleMultiplier, 0, 1))
	for _, sub in ipairs(visual.staticParts) do
		sub.part.CastShadow = shadowsEnabled
	end
	for _, wheel in ipairs(visual.wheels) do
		wheel.part.CastShadow = shadowsEnabled
	end
	applyEmitterSettings(visual.skidEmitterL, particleMultiplier)
	applyEmitterSettings(visual.skidEmitterR, particleMultiplier)
	applyEmitterSettings(visual.nitroEmitterL, particleMultiplier)
	applyEmitterSettings(visual.nitroEmitterR, particleMultiplier)
end

return table.freeze(KartPresentation)
