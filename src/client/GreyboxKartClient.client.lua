--!strict
-- src/client/GreyboxKartClient.client.lua
-- SPDX-License-Identifier: GPL-3.0-or-later
-- Client-side 120 Hz KartSolver prediction, exact server state-reset + input-replay reconciliation,
-- unordered snapshot guard, STK camera curve + 80 deg vertical FOV, Studio F8 bisect, & Nitro VFX.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local localPlayer = Players.LocalPlayer
local Shared = ReplicatedStorage:WaitForChild("Shared")
local FixedStep = require(Shared.sim.FixedStep)
local GreyboxProtocol = require(Shared.net.GreyboxProtocol)
local KartSolver = require(Shared.sim.KartSolver)
local KartTuning = require(Shared.KartTuning)
local Math3D = require(Shared.sim.Math3D)
local RobloxWorldQuery = require(Shared.sim.RobloxWorldQuery)
local Units = require(Shared.Units)

type ClientInputPacket = GreyboxProtocol.ClientInputPacket
type TelemetryPacket = GreyboxProtocol.TelemetryPacket

type SnapshotPose = {
	pos: Math3D.Vec3,
	rot: Math3D.Quat,
	visualSkidYaw: number,
	hopHeight: number,
}

type InputHistoryEntry = {
	seq: number,
	input: KartSolver.KartInput,
}

type LocalVisualKart = {
	model: Model,
	sparkLeft: Part,
	sparkRight: Part,
	skidEmitterL: ParticleEmitter,
	skidEmitterR: ParticleEmitter,
	nitroEmitterL: ParticleEmitter,
	nitroEmitterR: ParticleEmitter,
	nitroLight: PointLight,
}

local remotesFolder = ReplicatedStorage:WaitForChild(GreyboxProtocol.REMOTES_FOLDER)
local inputRemote = remotesFolder:WaitForChild(GreyboxProtocol.INPUT_REMOTE) :: RemoteEvent
local telemetryRemote = remotesFolder:WaitForChild(GreyboxProtocol.TELEMETRY_REMOTE) :: UnreliableRemoteEvent

local IS_STUDIO = RunService:IsStudio()
local SPAWN_HEIGHT_METERS = GreyboxProtocol.SPAWN_HEIGHT_METERS
local VOID_RESET_Y_METERS = GreyboxProtocol.VOID_RESET_Y_METERS
local INPUT_HEARTBEAT_SEC = 1 / GreyboxProtocol.SNAPSHOT_RATE_HZ
local MAX_INPUT_HISTORY = 240

local TIER_COLORS = {
	[0] = Color3.fromRGB(220, 225, 235),
	[1] = Color3.fromRGB(255, 210, 40),
	[2] = Color3.fromRGB(255, 65, 45),
}

local function buildLocalVisualKart(profile: KartTuning.KartProfile): LocalVisualKart
	local folder = Workspace:FindFirstChild(GreyboxProtocol.LOCAL_KARTS_FOLDER)
	if not folder then
		local f = Instance.new("Folder")
		f.Name = GreyboxProtocol.LOCAL_KARTS_FOLDER
		f.Parent = Workspace
		folder = f
	end

	local existing = (folder :: Folder):FindFirstChild("Kart_" .. tostring(localPlayer.UserId))
	if existing then
		existing:Destroy()
	end

	local model = Instance.new("Model")
	model.Name = "Kart_" .. tostring(localPlayer.UserId)

	local wStuds = Units.metersToStuds(profile.width)
	local hStuds = Units.metersToStuds(profile.collisionHeight)
	local lStuds = Units.metersToStuds(profile.length)

	local root = Instance.new("Part")
	root.Name = "Root"
	root.Anchored = true
	root.CanCollide = false
	root.CanTouch = false
	root.CanQuery = false
	root.Transparency = 1
	root.Size = Vector3.new(0.2, 0.2, 0.2)
	root.CFrame = CFrame.new(0, 2, 0)
	root.Parent = model

	local chassis = Instance.new("Part")
	chassis.Name = "Chassis"
	chassis.Anchored = true
	chassis.CanCollide = false
	chassis.CanTouch = false
	chassis.CanQuery = false
	chassis.Size = Vector3.new(wStuds, hStuds * 0.65, lStuds)
	chassis.Color = Color3.fromRGB(45, 130, 235)
	chassis.Material = Enum.Material.SmoothPlastic
	chassis.TopSurface = Enum.SurfaceType.Smooth
	chassis.BottomSurface = Enum.SurfaceType.Smooth
	chassis.CFrame = root.CFrame * CFrame.new(0, hStuds * 0.5, 0)
	chassis.Parent = model

	local nose = Instance.new("Part")
	nose.Name = "NoseMarker"
	nose.Anchored = true
	nose.CanCollide = false
	nose.CanTouch = false
	nose.CanQuery = false
	nose.Size = Vector3.new(wStuds * 0.65, hStuds * 0.35, lStuds * 0.25)
	nose.Color = Color3.fromRGB(245, 245, 250)
	nose.Material = Enum.Material.SmoothPlastic
	nose.CFrame = chassis.CFrame * CFrame.new(0, hStuds * 0.25, -lStuds * 0.35)
	nose.Parent = model

	local wheelNames = { "WheelFL", "WheelFR", "WheelRL", "WheelRR" }
	local wheelSize = Vector3.new(Units.metersToStuds(0.18), Units.metersToStuds(0.31), Units.metersToStuds(0.31))
	for i, hp in profile.wheelHardpoints do
		local wheel = Instance.new("Part")
		wheel.Name = wheelNames[i]
		wheel.Anchored = true
		wheel.CanCollide = false
		wheel.CanTouch = false
		wheel.CanQuery = false
		wheel.Size = wheelSize
		wheel.Color = Color3.fromRGB(30, 32, 36)
		wheel.Material = Enum.Material.Rubber
		wheel.CFrame = root.CFrame
			* CFrame.new(Units.metersToStuds(hp.x), Units.metersToStuds(hp.y - 0.12), Units.metersToStuds(-hp.z))
		wheel.Parent = model
	end

	-- Skid tier wheel spark indicators + emitters (src/karts/kart_gfx.cpp:L69-L89, L118-L123)
	local sparkSize = Vector3.new(Units.metersToStuds(0.13), Units.metersToStuds(0.10), Units.metersToStuds(0.16))
	local function makeSkidUnit(name: string, sideSign: number): (Part, ParticleEmitter)
		local bar = Instance.new("Part")
		bar.Name = name
		bar.Anchored = true
		bar.CanCollide = false
		bar.CanTouch = false
		bar.CanQuery = false
		bar.Size = sparkSize
		bar.Color = TIER_COLORS[0]
		bar.Material = Enum.Material.Neon
		bar.Transparency = 0.85
		bar.CFrame = root.CFrame * CFrame.new(sideSign * wStuds * 0.45, -0.05, lStuds * 0.48)
		bar.Parent = model

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
		return bar, em
	end

	local sparkLeft, skidEmitterL = makeSkidUnit("SparkLeft", -1)
	local sparkRight, skidEmitterR = makeSkidUnit("SparkRight", 1)

	-- PLACEHOLDER Nitro exhaust flame emitters & blue light (src/karts/kart_gfx.cpp:L55-L67, L101-L115:
	-- KGFX_NITRO1/KGFX_NITRO2 nitro.xml + m_nitro_light (0, 0.4, 1.0)); replace once attachments/particles port.
	local function makeExhaustUnit(name: string, sideSign: number): (Part, ParticleEmitter)
		local pipe = Instance.new("Part")
		pipe.Name = name
		pipe.Anchored = true
		pipe.CanCollide = false
		pipe.CanTouch = false
		pipe.CanQuery = false
		pipe.Size = Vector3.new(0.12, 0.12, 0.22)
		pipe.Color = Color3.fromRGB(60, 68, 82)
		pipe.Material = Enum.Material.Metal
		pipe.CFrame = chassis.CFrame * CFrame.new(sideSign * wStuds * 0.24, 0.05, lStuds * 0.56)
		pipe.Parent = model

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
		flame.Parent = pipe
		return pipe, flame
	end

	local exhaustL, nitroEmitterL = makeExhaustUnit("ExhaustLeft", -1)
	local _, nitroEmitterR = makeExhaustUnit("ExhaustRight", 1)

	local nitroLight = Instance.new("PointLight")
	nitroLight.Name = "NitroPlaceholderLight"
	nitroLight.Enabled = false
	nitroLight.Color = Color3.fromRGB(0, 102, 255) -- kart_gfx.cpp:L61 (0, 0.4, 1.0)
	nitroLight.Range = 10
	nitroLight.Brightness = 2.0
	nitroLight.Parent = exhaustL

	model.PrimaryPart = root
	model.Parent = folder

	return {
		model = model,
		sparkLeft = sparkLeft,
		sparkRight = sparkRight,
		skidEmitterL = skidEmitterL,
		skidEmitterR = skidEmitterR,
		nitroEmitterL = nitroEmitterL,
		nitroEmitterR = nitroEmitterR,
		nitroLight = nitroLight,
	}
end

local function createDebugHud()
	local playerGui = localPlayer:WaitForChild("PlayerGui")
	local gui = Instance.new("ScreenGui")
	gui.Name = "OpenKartDebugHud"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.Parent = playerGui

	local panel = Instance.new("Frame")
	panel.Name = "TelemetryPanel"
	panel.Position = UDim2.fromOffset(16, 56)
	panel.Size = UDim2.fromOffset(580, 236)
	panel.BackgroundColor3 = Color3.fromRGB(16, 18, 24)
	panel.BackgroundTransparency = 0.2
	panel.BorderSizePixel = 0
	panel.Parent = gui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = panel

	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, 10)
	padding.PaddingBottom = UDim.new(0, 10)
	padding.PaddingLeft = UDim.new(0, 12)
	padding.PaddingRight = UDim.new(0, 12)
	padding.Parent = panel

	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 4)
	layout.Parent = panel

	local function makeRow(name: string, order: number, size: number, color: Color3): TextLabel
		local lbl = Instance.new("TextLabel")
		lbl.Name = name
		lbl.LayoutOrder = order
		lbl.Size = UDim2.new(1, 0, 0, size + 6)
		lbl.BackgroundTransparency = 1
		lbl.Font = Enum.Font.Code
		lbl.TextSize = size
		lbl.TextColor3 = color
		lbl.TextXAlignment = Enum.TextXAlignment.Left
		lbl.Text = ""
		lbl.Parent = panel
		return lbl
	end

	local title = makeRow("Title", 1, 15, Color3.fromRGB(160, 210, 255))
	title.Text = "OPENKART TELEMETRY (120 Hz)"

	local speedLbl = makeRow("Speed", 2, 16, Color3.fromRGB(245, 245, 250))
	local slipLbl = makeRow("SlipAngle", 3, 15, Color3.fromRGB(220, 230, 240))
	local skidLbl = makeRow("SkidTier", 4, 15, Color3.fromRGB(235, 235, 240))
	local nitroLbl = makeRow("Nitro", 5, 15, Color3.fromRGB(130, 200, 255))
	local matLbl = makeRow("Material", 6, 15, Color3.fromRGB(240, 225, 155))
	local airLbl = makeRow("Airborne", 7, 15, Color3.fromRGB(115, 240, 145))

	local controlsLbl = makeRow("Controls", 8, 12, Color3.fromRGB(165, 172, 185))
	controlsLbl.Text = if IS_STUDIO
		then "Arrows/WASD: Drive | V/Shift: Drift | N: Nitro | G: +3 Nitro | Backspace/R: Reset | F8: Local-Only"
		else "Arrows/WASD: Drive | V/Shift: Drift | N: Nitro | Backspace/R: Reset"

	local creditLbl = makeRow("Attribution", 9, 11, Color3.fromRGB(125, 132, 145))
	creditLbl.Text = "Unofficial SuperTuxKart 1.5 port (supertuxkart.net)"

	return {
		title = title,
		speed = speedLbl,
		slip = slipLbl,
		skid = skidLbl,
		nitro = nitroLbl,
		mat = matLbl,
		air = airLbl,
	}
end

local function capturePose(state: KartSolver.KartState): SnapshotPose
	return {
		pos = { x = state.pos.x, y = state.pos.y, z = state.pos.z },
		rot = { w = state.rot.w, x = state.rot.x, y = state.rot.y, z = state.rot.z },
		visualSkidYaw = state.skid.visualRotation,
		hopHeight = state.skid.hopHeight,
	}
end

local hud = createDebugHud()
local profile = KartTuning.buildProfile("medium", "best")
local visuals = buildLocalVisualKart(profile)

local localStepper = FixedStep.new()
local localState = KartSolver.createState(profile, { x = 0, y = SPAWN_HEIGHT_METERS, z = 0 }, 0)
local prevPose = capturePose(localState)
local currPose = capturePose(localState)

local cachedWorldQuery: KartSolver.WorldQuery? = nil
local function resolveWorldQuery(): KartSolver.WorldQuery?
	if cachedWorldQuery ~= nil then
		return cachedWorldQuery
	end
	local arena = Workspace:FindFirstChild(GreyboxProtocol.ARENA_NAME)
	local surfaces = if arena then arena:FindFirstChild("Surfaces") else nil
	if surfaces then
		cachedWorldQuery = RobloxWorldQuery.create(surfaces)
	end
	return cachedWorldQuery
end

local localOnlyMode = false
local inputSeq = 0
local lastAppliedServerTick = 0
local lastResetSeq = 0
local resetNoticeText = ""
local resetNoticeExpirySec = 0.0
local lastCorrectionErrMeters = 0.0
local lastReplayedTicks = 0
local inputHistory: { InputHistoryEntry } = {}

local lastSent: ClientInputPacket = {
	seq = 0,
	accel = 0,
	brake = false,
	steer = 0,
	drift = false,
	nitro = false,
	reset = false,
	debugGrantNitro = false,
}
local lastSentTime = 0.0
local resetPulse = false
local grantNitroPulse = false

UserInputService.InputBegan:Connect(function(inputObj: InputObject, gameProcessed: boolean)
	if gameProcessed then
		return
	end
	if inputObj.KeyCode == Enum.KeyCode.R or inputObj.KeyCode == Enum.KeyCode.Backspace then
		resetPulse = true
	elseif IS_STUDIO and inputObj.KeyCode == Enum.KeyCode.G then
		grantNitroPulse = true
	elseif IS_STUDIO and inputObj.KeyCode == Enum.KeyCode.F8 then
		localOnlyMode = not localOnlyMode
		lastCorrectionErrMeters = 0.0
		lastReplayedTicks = 0
		table.clear(inputHistory)
	end
end)

-- Default keyboard bindings from src/input/keyboard_config.cpp:L54-L65 (STK 1.5)
local function sampleInput(): (KartSolver.KartInput, boolean, boolean)
	local accel = if UserInputService:IsKeyDown(Enum.KeyCode.W) or UserInputService:IsKeyDown(Enum.KeyCode.Up)
		then 1.0
		else 0.0
	local brake = UserInputService:IsKeyDown(Enum.KeyCode.S) or UserInputService:IsKeyDown(Enum.KeyCode.Down)

	local steer = 0.0
	if UserInputService:IsKeyDown(Enum.KeyCode.A) or UserInputService:IsKeyDown(Enum.KeyCode.Left) then
		steer -= 1.0
	end
	if UserInputService:IsKeyDown(Enum.KeyCode.D) or UserInputService:IsKeyDown(Enum.KeyCode.Right) then
		steer += 1.0
	end

	local drift = UserInputService:IsKeyDown(Enum.KeyCode.V)
		or UserInputService:IsKeyDown(Enum.KeyCode.LeftShift)
		or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)

	local nitro = UserInputService:IsKeyDown(Enum.KeyCode.N)

	local reset = resetPulse
	resetPulse = false

	local grantNitro = IS_STUDIO and grantNitroPulse
	grantNitroPulse = false

	return {
		accel = accel,
		brake = brake,
		steer = steer,
		drift = drift,
		nitro = nitro,
	}, reset, grantNitro
end

telemetryRemote.OnClientEvent:Connect(function(rawNums: any, rawIncs: any, rawNotice: any)
	if localOnlyMode then
		return
	end
	local snapshot = GreyboxProtocol.unpackSnapshot(rawNums, rawIncs, rawNotice)
	if snapshot == nil then
		return
	end
	-- UnreliableRemoteEvent can deliver packets out of order; discard stale ticks immediately
	if snapshot.tick <= lastAppliedServerTick then
		return
	end
	lastAppliedServerTick = snapshot.tick

	if snapshot.resetSeq > lastResetSeq then
		lastResetSeq = snapshot.resetSeq
		KartSolver.applyNetState(localState, snapshot.netState)
		table.clear(inputHistory)
		prevPose = capturePose(localState)
		currPose = capturePose(localState)
		lastCorrectionErrMeters = 0.0
		lastReplayedTicks = 0
		if snapshot.resetNotice ~= "" then
			resetNoticeText = snapshot.resetNotice
			resetNoticeExpirySec = os.clock() + 1.5
		end
		return
	end

	-- Exact state-reset + unacknowledged input replay reconciliation
	local worldQuery = resolveWorldQuery()
	if worldQuery == nil then
		return
	end

	local prePos = localState.pos
	local retained: { InputHistoryEntry } = {}
	for _, entry in inputHistory do
		if entry.seq > snapshot.lastInputSeq then
			table.insert(retained, entry)
		end
	end
	inputHistory = retained

	KartSolver.applyNetState(localState, snapshot.netState)
	for _, entry in inputHistory do
		prevPose = capturePose(localState)
		KartSolver.step(localState, entry.input, worldQuery, FixedStep.FIXED_DT)
	end
	currPose = capturePose(localState)

	lastReplayedTicks = #inputHistory
	lastCorrectionErrMeters = Math3D.len(Math3D.sub(localState.pos, prePos))
end)

-- STK normal follow-camera state (src/graphics/camera/camera_normal.cpp:L102-L142, user_config.hpp:L1046-L1066)
local camCfg = KartTuning.camera
local camBackMeters = Units.metersToStuds(camCfg.distanceBase * math.sqrt(camCfg.smoothPosition))
local camUpMeters = Units.metersToStuds(camCfg.heightBase)
local smoothedCamRot: CFrame? = nil

RunService:BindToRenderStep("OpenKartClientFrame", Enum.RenderPriority.Camera.Value + 1, function(dt: number)
	local now = os.clock()
	local solverInput, wantsReset, wantsGrantNitro = sampleInput()

	if wantsGrantNitro then
		KartSolver.addNitro(localState, profile.nitro.bigContainer)
	end
	if wantsReset then
		localState = KartSolver.createState(profile, { x = 0, y = SPAWN_HEIGHT_METERS, z = 0 }, 0)
		table.clear(inputHistory)
		prevPose = capturePose(localState)
		currPose = capturePose(localState)
	end

	local worldQuery = resolveWorldQuery()
	local steppedThisFrame = false
	if worldQuery ~= nil then
		localStepper:advance(dt, function(fixedDt: number)
			steppedThisFrame = true
			inputSeq += 1
			prevPose = capturePose(localState)
			if localState.pos.y < VOID_RESET_Y_METERS or localState.resetTriggered then
				if localState.resetTriggered then
					resetNoticeText = "RESET (" .. localState.activeMaterialName .. ")"
					resetNoticeExpirySec = os.clock() + 1.5
				end
				localState = KartSolver.createState(profile, { x = 0, y = SPAWN_HEIGHT_METERS, z = 0 }, 0)
				table.clear(inputHistory)
				prevPose = capturePose(localState)
				currPose = capturePose(localState)
			else
				table.insert(inputHistory, {
					seq = inputSeq,
					input = {
						accel = solverInput.accel,
						brake = solverInput.brake,
						steer = solverInput.steer,
						drift = solverInput.drift,
						nitro = solverInput.nitro,
					},
				})
				if #inputHistory > MAX_INPUT_HISTORY then
					table.remove(inputHistory, 1)
				end
				KartSolver.step(localState, solverInput, worldQuery, fixedDt)
				currPose = capturePose(localState)
			end
		end)
	end

	local changed = solverInput.accel ~= lastSent.accel
		or solverInput.brake ~= lastSent.brake
		or solverInput.steer ~= lastSent.steer
		or solverInput.drift ~= lastSent.drift
		or solverInput.nitro ~= lastSent.nitro
		or wantsReset
		or wantsGrantNitro

	if (changed or (now - lastSentTime) >= INPUT_HEARTBEAT_SEC) and (steppedThisFrame or changed) then
		local pkt: ClientInputPacket = {
			seq = inputSeq,
			accel = solverInput.accel,
			brake = solverInput.brake,
			steer = solverInput.steer,
			drift = solverInput.drift,
			nitro = solverInput.nitro == true,
			reset = wantsReset,
			debugGrantNitro = wantsGrantNitro,
		}
		if not localOnlyMode then
			inputRemote:FireServer(pkt)
		end
		lastSent = pkt
		lastSentTime = now
	end

	-- Accumulator-remainder interpolation (alpha in [0, 1]) driving BOTH kart body and camera
	local alpha = localStepper:getAlpha()
	local interpPos = Math3D.vecLerp(prevPose.pos, currPose.pos, alpha)
	local interpRot = Math3D.quatSlerp(prevPose.rot, currPose.rot, alpha)
	local interpYaw = prevPose.visualSkidYaw + (currPose.visualSkidYaw - prevPose.visualSkidYaw) * alpha
	local interpHop = prevPose.hopHeight + (currPose.hopHeight - prevPose.hopHeight) * alpha

	local renderCFrame = RobloxWorldQuery.stkPoseToRobloxCFrame(interpPos, interpRot, interpYaw, interpHop)
	visuals.model:PivotTo(renderCFrame)

	local tel = KartSolver.getTelemetry(localState)

	-- Skid wheel sparks + emitter (separate from Nitro exhaust)
	local tierColor = TIER_COLORS[tel.skidTier] or TIER_COLORS[0]
	local isAccum = (tel.skidState == "SKID_ACCUMULATE_LEFT" or tel.skidState == "SKID_ACCUMULATE_RIGHT")
	local sparkTrans = if isAccum then 0.0 else 0.85
	visuals.sparkLeft.Color = tierColor
	visuals.sparkRight.Color = tierColor
	visuals.sparkLeft.Transparency = sparkTrans
	visuals.sparkRight.Transparency = sparkTrans
	local emitSkid = isAccum and tel.skidTier >= 1
	visuals.skidEmitterL.Enabled = emitSkid
	visuals.skidEmitterR.Enabled = emitSkid
	if emitSkid then
		local seqColor = ColorSequence.new(tierColor)
		visuals.skidEmitterL.Color = seqColor
		visuals.skidEmitterR.Color = seqColor
	end

	-- PLACEHOLDER Nitro exhaust flames + blue light
	visuals.nitroEmitterL.Enabled = tel.nitroActive
	visuals.nitroEmitterR.Enabled = tel.nitroActive
	visuals.nitroLight.Enabled = tel.nitroActive

	-- STK CameraNormal speed-proportional pull-back + constant 80 deg vertical FOV
	-- (src/graphics/camera/camera_normal.cpp:L102-L142, camera.cpp:L139-L141)
	local camera = Workspace.CurrentCamera
	if camera then
		camera.CameraType = Enum.CameraType.Scriptable
		camera.FieldOfView = camCfg.fovDeg

		local ratio = math.max(tel.speedMps / profile.maxSpeed, camCfg.minRatio)
		local wantedBack = math.max(
			(camCfg.distanceBase + camCfg.distanceSpeedFactor * ratio) * math.sqrt(camCfg.smoothPosition),
			camCfg.minDistance
		)
		local wantedUp = camCfg.heightBase + ratio / camCfg.heightSpeedDivisor

		local posLerp = math.clamp(dt / camCfg.smoothPosition, 0.0, 1.0)
		local rotLerp = math.clamp(dt / camCfg.smoothRotation, 0.0, 1.0)
		camBackMeters += (Units.metersToStuds(wantedBack) - camBackMeters) * posLerp
		camUpMeters += (Units.metersToStuds(wantedUp) - camUpMeters) * posLerp

		local travelCf = if interpYaw ~= 0 then renderCFrame * CFrame.Angles(0, interpYaw, 0) else renderCFrame
		local targetRotCf = CFrame.fromMatrix(Vector3.zero, travelCf.RightVector, Vector3.yAxis, -travelCf.LookVector)
		if smoothedCamRot == nil then
			smoothedCamRot = targetRotCf
		else
			smoothedCamRot = smoothedCamRot:Lerp(targetRotCf, rotLerp)
		end

		local rotOnly = smoothedCamRot :: CFrame
		local camPos = renderCFrame.Position
			- rotOnly.LookVector * camBackMeters * math.cos(interpYaw * 0.5)
			+ rotOnly.RightVector * camBackMeters * math.sin(interpYaw * 0.5)
			+ Vector3.new(0, camUpMeters, 0)
		local lookTarget = renderCFrame.Position + Vector3.new(0, Units.metersToStuds(0.5), 0)
		camera.CFrame = CFrame.lookAt(camPos, lookTarget)
	end

	-- Debug HUD
	local modeLabel = if localOnlyMode
		then "LOCAL-ONLY [F8]"
		else string.format("REPLAY (err %.3fm | %dt)", lastCorrectionErrMeters, lastReplayedTicks)
	hud.title.Text = string.format("OPENKART TELEMETRY (120 Hz) | %s", modeLabel)

	local sps = Units.mpsToStudsPerSec(tel.speedMps)
	hud.speed.Text =
		string.format("SPEED: %6.2f m/s (%5.1f km/h | %5.1f st/s)", tel.speedMps, Units.mpsToKmh(tel.speedMps), sps)
	hud.slip.Text = string.format(
		"SLIP:  %5.1f deg  | CAP: %4.1f m/s | COMP: %.2f",
		math.deg(tel.maxSlipAngleRad),
		tel.currentMaxSpeed,
		tel.maxCompressionRatio
	)

	local tierLabel = if tel.skidTier == 2
		then "TIER 2 (RED)"
		elseif tel.skidTier == 1 then "TIER 1 (YELLOW)"
		else "TIER 0"
	hud.skid.Text = string.format("SKID:  %s | %s (%.2fs)", tierLabel, tel.skidState, tel.skidTimeSec)
	if tel.skidTier == 2 then
		hud.skid.TextColor3 = Color3.fromRGB(255, 85, 70)
	elseif tel.skidTier == 1 then
		hud.skid.TextColor3 = Color3.fromRGB(255, 215, 65)
	else
		hud.skid.TextColor3 = Color3.fromRGB(235, 235, 240)
	end

	local nitroTag = if tel.nitroActive then "ACTIVE" else "IDLE"
	hud.nitro.Text = string.format("NITRO: %4.1f / %4.1f [%s]", tel.nitroEnergy, tel.nitroMaxEnergy, nitroTag)
	if tel.nitroActive then
		hud.nitro.TextColor3 = Color3.fromRGB(90, 225, 255)
	elseif tel.nitroEnergy > 0 then
		hud.nitro.TextColor3 = Color3.fromRGB(165, 215, 255)
	else
		hud.nitro.TextColor3 = Color3.fromRGB(150, 158, 172)
	end

	local notice = if now < resetNoticeExpirySec then resetNoticeText else ""
	if notice ~= "" then
		hud.mat.Text = string.format("MAT:   %s | %s", tel.activeMaterialName, notice)
		hud.mat.TextColor3 = Color3.fromRGB(255, 95, 95)
	elseif tel.activeMaterialName == "sand.png" then
		hud.mat.Text = "MAT:   sand.png (50% SPEED CAP)"
		hud.mat.TextColor3 = Color3.fromRGB(255, 205, 90)
	elseif tel.activeMaterialName == "pyramidwall.jpg" then
		hud.mat.Text = "MAT:   pyramidwall.jpg (HIGH ADHESION)"
		hud.mat.TextColor3 = Color3.fromRGB(120, 230, 255)
	else
		hud.mat.Text = string.format("MAT:   %s", tel.activeMaterialName)
		hud.mat.TextColor3 = Color3.fromRGB(205, 225, 245)
	end

	if tel.isAirborne then
		hud.air.Text = string.format("STATE: AIRBORNE (0/4 wheels) | tick %d", localStepper:getTick())
		hud.air.TextColor3 = Color3.fromRGB(100, 215, 255)
	elseif tel.numWheelsOnGround < 4 then
		hud.air.Text =
			string.format("STATE: PARTIAL (%d/4 wheels) | tick %d", tel.numWheelsOnGround, localStepper:getTick())
		hud.air.TextColor3 = Color3.fromRGB(255, 185, 75)
	else
		hud.air.Text = string.format("STATE: GROUNDED (4/4 wheels) | tick %d", localStepper:getTick())
		hud.air.TextColor3 = Color3.fromRGB(115, 240, 145)
	end
end)
