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
local HudState = require("./HudState")
local KartPresentation = require("./kart/KartPresentation")
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
	speedMps: number,
	nitroEnergy: number,
}

type InputHistoryEntry = {
	seq: number,
	input: KartSolver.KartInput,
}

local remotesFolder = ReplicatedStorage:WaitForChild(GreyboxProtocol.REMOTES_FOLDER)
local inputRemote = remotesFolder:WaitForChild(GreyboxProtocol.INPUT_REMOTE) :: RemoteEvent
local telemetryRemote = remotesFolder:WaitForChild(GreyboxProtocol.TELEMETRY_REMOTE) :: UnreliableRemoteEvent

local IS_STUDIO = RunService:IsStudio()
local SPAWN_HEIGHT_METERS = GreyboxProtocol.SPAWN_HEIGHT_METERS
local VOID_RESET_Y_METERS = GreyboxProtocol.VOID_RESET_Y_METERS
local INPUT_HEARTBEAT_SEC = 1 / GreyboxProtocol.SNAPSHOT_RATE_HZ
local MAX_INPUT_HISTORY = 240

local function createDebugHud()
	local playerGui = localPlayer:WaitForChild("PlayerGui")
	local gui = Instance.new("ScreenGui")
	gui.Name = "OpenKartDebugHud"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.Enabled = false -- toggled on/off via F3
	gui.Parent = playerGui

	local panel = Instance.new("Frame")
	panel.Name = "TelemetryPanel"
	panel.Position = UDim2.fromOffset(16, 56)
	panel.Size = UDim2.fromOffset(640, 262)
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
	local camDiagLbl = makeRow("CamDiag", 8, 14, Color3.fromRGB(195, 220, 255))

	local controlsLbl = makeRow("Controls", 9, 12, Color3.fromRGB(165, 172, 185))
	controlsLbl.Text = if IS_STUDIO
		then "Arrows/WASD: Drive | V/Shift: Drift | N: Nitro | B: Look-Back | G: +3 Nitro | Backspace/R: Reset | F3: Debug HUD | F8: Local-Only"
		else "Arrows/WASD: Drive | V/Shift: Drift | N: Nitro | B: Look-Back | Backspace/R: Reset | F3: Debug HUD"

	local creditLbl = makeRow("Attribution", 10, 11, Color3.fromRGB(125, 132, 145))
	creditLbl.Text = "Unofficial SuperTuxKart 1.5 port (supertuxkart.net)"

	return {
		gui = gui,
		title = title,
		speed = speedLbl,
		slip = slipLbl,
		skid = skidLbl,
		nitro = nitroLbl,
		mat = matLbl,
		air = airLbl,
		camDiag = camDiagLbl,
	}
end

local function capturePose(state: KartSolver.KartState): SnapshotPose
	return {
		pos = { x = state.pos.x, y = state.pos.y, z = state.pos.z },
		rot = { w = state.rot.w, x = state.rot.x, y = state.rot.y, z = state.rot.z },
		visualSkidYaw = state.skid.visualRotation,
		hopHeight = state.skid.hopHeight,
		speedMps = state.speed,
		nitroEnergy = state.nitro.energy,
	}
end

local hud = createDebugHud()
local profile = KartTuning.buildProfile("medium", "best")
local visuals = KartPresentation.create(localPlayer, profile, "tux")

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
	elseif inputObj.KeyCode == Enum.KeyCode.F3 then
		hud.gui.Enabled = not hud.gui.Enabled
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
local function sampleInput(): (KartSolver.KartInput, boolean, boolean, boolean)
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
	-- Hold-to-look-back (PA_LOOK_BACK = IRR_KEY_B, keyboard_config.cpp:L64, player_controller.cpp:L222-L223)
	local lookBack = UserInputService:IsKeyDown(Enum.KeyCode.B)

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
	},
		reset,
		grantNitro,
		lookBack
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

-- STK normal/reverse follow-camera state (src/graphics/camera/camera_normal.cpp:L102-L144, L224-L241, user_config.hpp:L1046-L1066)
local camCfg = KartTuning.camera
local camOffsetX = 0.0
local camOffsetY = camCfg.heightBase
local camOffsetZ = -camCfg.distanceBase * math.sqrt(camCfg.smoothPosition)
local smoothedCamRot: CFrame? = nil
local wasLookingBack = false

local function signedYawAngleDeg(fromDir: Vector3, toDir: Vector3): number
	local crossY = fromDir.X * toDir.Z - fromDir.Z * toDir.X
	local dot = math.clamp(fromDir.X * toDir.X + fromDir.Z * toDir.Z, -1.0, 1.0)
	return math.deg(math.atan2(crossY, dot))
end

RunService:BindToRenderStep("OpenKartClientFrame", Enum.RenderPriority.Camera.Value + 1, function(dt: number)
	local now = os.clock()
	local solverInput, wantsReset, wantsGrantNitro, lookBack = sampleInput()

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

	-- Accumulator-remainder interpolation (alpha in [0, 1]) split cleanly:
	-- renderPose = interpolated physical pose (no visualSkidYaw / no hop) -> camera ONLY
	-- bodyCFrame = renderPose + hop + visualSkidYaw -> kart chassis presentation ONLY
	local alpha = localStepper:getAlpha()
	local interpPos = Math3D.vecLerp(prevPose.pos, currPose.pos, alpha)
	local interpRot = Math3D.quatSlerp(prevPose.rot, currPose.rot, alpha)
	local interpYaw = prevPose.visualSkidYaw + (currPose.visualSkidYaw - prevPose.visualSkidYaw) * alpha
	local interpHop = prevPose.hopHeight + (currPose.hopHeight - prevPose.hopHeight) * alpha
	local interpSpeedMps = prevPose.speedMps + (currPose.speedMps - prevPose.speedMps) * alpha
	local interpNitroEnergy = prevPose.nitroEnergy + (currPose.nitroEnergy - prevPose.nitroEnergy) * alpha

	local renderPose = RobloxWorldQuery.stkPoseToRobloxCFrame(interpPos, interpRot, 0, 0)
	local hopOffset = Vector3.new(0, Units.metersToStuds(interpHop), 0)
	local bodyCFrame = (renderPose + hopOffset)
		* (if interpYaw ~= 0 then CFrame.Angles(0, -interpYaw, 0) else CFrame.identity)

	local tel = KartSolver.getTelemetry(localState)
	local wheelSuspensions = {
		localState.wheels[1].suspensionLength,
		localState.wheels[2].suspensionLength,
		localState.wheels[3].suspensionLength,
		localState.wheels[4].suspensionLength,
	}
	KartPresentation.update(
		visuals,
		bodyCFrame,
		interpSpeedMps,
		dt,
		localState.steer,
		wheelSuspensions,
		tel.skidTier,
		tel.skidState,
		tel.nitroActive
	)

	local attrStart = Workspace:GetAttribute("OpenKartRaceStartTime")
	local raceStartServerTime = if type(attrStart) == "number" then attrStart else Workspace:GetServerTimeNow()
	HudState.publish(
		interpPos.x,
		interpPos.z,
		interpSpeedMps,
		profile.maxSpeed,
		interpNitroEnergy,
		profile.nitro.max,
		solverInput.nitro == true or tel.nitroActive,
		"TIME_TRIAL",
		raceStartServerTime,
		0,
		0,
		math.max(0.0, interpPos.z)
	)

	-- STK CameraNormal speed-proportional pull-back + skid_angle/2 offset + constant 80 deg vertical FOV
	-- + CM_REVERSE look-back (B / PA_LOOK_BACK); derived strictly from physical renderPose
	-- (src/graphics/camera/camera_normal.cpp:L98-L146, L224-L241, L344-L349, camera.cpp:L139-L141, L200-L204)
	local camera = Workspace.CurrentCamera
	local cameraDirFlat = Vector3.new(renderPose.LookVector.X, 0, renderPose.LookVector.Z)
	if camera then
		camera.CameraType = Enum.CameraType.Scriptable
		camera.FieldOfView = camCfg.fovDeg

		local ratio = math.max(tel.speedMps / profile.maxSpeed, camCfg.minRatio)
		local wantedBack = math.max(
			(camCfg.distanceBase + camCfg.distanceSpeedFactor * ratio) * math.sqrt(camCfg.smoothPosition),
			camCfg.minDistance
		)
		local wantedUp = camCfg.heightBase + ratio / camCfg.heightSpeedDivisor

		local skidFactor = math.clamp(interpYaw, -1.0, 1.0)
		local skidAngle = math.asin(skidFactor)
		local camDist = -wantedBack
		local wantedOffsetX = camDist * math.sin(skidAngle * 0.5)
		local wantedOffsetY = wantedUp
		local wantedOffsetZ = camDist * math.cos(skidAngle * 0.5)

		local posLerp = math.clamp(dt / camCfg.smoothPosition, 0.0, 1.0)
		local rotLerp = math.clamp(dt / camCfg.smoothRotation, 0.0, 1.0)
		camOffsetX += (wantedOffsetX - camOffsetX) * posLerp
		camOffsetY += (wantedOffsetY - camOffsetY) * posLerp
		camOffsetZ += (wantedOffsetZ - camOffsetZ) * posLerp

		local flatLook = Vector3.new(renderPose.LookVector.X, 0, renderPose.LookVector.Z)
		local targetRotCf = if flatLook.Magnitude > 1e-4
			then CFrame.lookAt(Vector3.zero, flatLook.Unit, Vector3.yAxis)
			else (smoothedCamRot or CFrame.identity)
		if smoothedCamRot == nil then
			smoothedCamRot = targetRotCf
		else
			smoothedCamRot = smoothedCamRot:Lerp(targetRotCf, rotLerp)
		end

		if lookBack then
			-- CM_REVERSE snaps immediately (smoothing = false, camera_normal.cpp:L226-L230)
			-- while background normal state keeps advancing above (L344-L349).
			local backDistStuds = Units.metersToStuds(camCfg.backwardDistance)
			local aboveStuds = Units.metersToStuds(camCfg.backwardAboveKart)
			local upTanStuds = backDistStuds * math.tan(math.rad(camCfg.backwardUpAngleDeg))
			local reversePos = renderPose.Position
				+ targetRotCf.LookVector * backDistStuds
				+ Vector3.new(0, aboveStuds + upTanStuds, 0)
			local reverseTarget = renderPose.Position + Vector3.new(0, aboveStuds, 0)
			camera.CFrame = CFrame.lookAt(reversePos, reverseTarget)
		else
			if wasLookingBack then
				-- CM_REVERSE -> CM_NORMAL snaps behind kart cleanly instead of sweeping through chassis (camera.cpp:L200-L204)
				smoothedCamRot = targetRotCf
				camOffsetX = 0.0
				camOffsetY = camCfg.reverseReturnUp
				camOffsetZ = -camCfg.reverseReturnBack
			end
			local rotOnly = smoothedCamRot :: CFrame
			local camPos = renderPose.Position
				+ rotOnly.RightVector * Units.metersToStuds(camOffsetX)
				+ Vector3.new(0, Units.metersToStuds(camOffsetY), 0)
				+ rotOnly.LookVector * Units.metersToStuds(camOffsetZ)
			local lookTarget = renderPose.Position + Vector3.new(0, Units.metersToStuds(camCfg.lookTargetY), 0)
			camera.CFrame = CFrame.lookAt(camPos, lookTarget)
		end
		cameraDirFlat = Vector3.new(camera.CFrame.LookVector.X, 0, camera.CFrame.LookVector.Z)
		wasLookingBack = lookBack
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

	-- 3-vector / 3-angle camera drift diagnostic (heading, velocity with low-speed & reverse fallback, camera)
	local rawHdgFlat = Vector3.new(renderPose.LookVector.X, 0, renderPose.LookVector.Z)
	local headingDir = if rawHdgFlat.Magnitude > 1e-4 then rawHdgFlat.Unit else Vector3.new(0, 0, -1)
	local velRbx = Vector3.new(localState.linVel.x, 0, -localState.linVel.z)
	local velocityDir = headingDir
	local velMode = "VEL"
	if velRbx.Magnitude < KartTuning.physics.SLIP_SPEED_FLOOR then
		velMode = "LOW"
	elseif velRbx:Dot(headingDir) < 0 then
		velMode = "REV"
	else
		velocityDir = velRbx.Unit
	end
	local cameraDir = if cameraDirFlat.Magnitude > 1e-4 then cameraDirFlat.Unit else headingDir

	local angCamHdg = signedYawAngleDeg(headingDir, cameraDir)
	local angCamVel = signedYawAngleDeg(velocityDir, cameraDir)
	local skidHdgVel = signedYawAngleDeg(velocityDir, headingDir)
	hud.camDiag.Text = string.format(
		"CAM[%s]: a(C,H)=%+5.1f | a(C,V)=%+5.1f | a(H,V)=%+5.1f | vis=%+5.1f",
		velMode,
		angCamHdg,
		angCamVel,
		skidHdgVel,
		math.deg(interpYaw)
	)
end)
