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
local AIController = require(Shared.ai.AIController)
local CheckManager = require(Shared.race.CheckManager)
local ClientSessionState = require("./ClientSessionState")
local ClientSettingsState = require("./ClientSettingsState")
local FixedStep = require(Shared.sim.FixedStep)
local Flyable = require(Shared.sim.Flyable)
local FlyablePresentation = require("./items/FlyablePresentation")
local GreyboxProtocol = require(Shared.net.GreyboxProtocol)
local HudState = require("./HudState")
local InputMapper = require("./InputMapper")
local ItemPresentation = require("./items/ItemPresentation")
local ItemTuning = require(Shared.ItemTuning)
local ItemWorld = require(Shared.items.ItemWorld)
local KartPresentation = require("./kart/KartPresentation")
local RefereePresentation = require("./kart/RefereePresentation")
local KartSolver = require(Shared.sim.KartSolver)
local KartTuning = require(Shared.KartTuning)
local Math3D = require(Shared.sim.Math3D)
local RaceState = require(Shared.sim.RaceState)
local ReconciliationSmoother = require(Shared.net.ReconciliationSmoother)
local RemoteInterp = require(Shared.net.RemoteInterp)
local RobloxWorldQuery = require(Shared.sim.RobloxWorldQuery)
local SettingsApplier = require("./SettingsApplier")
local SettingsSchema = require(Shared.settings.SettingsSchema)
local SfxEvents = require(Shared.audio.SfxEvents)
local SfxPlayer = require("./SfxPlayer")
local SlipstreamVfxMath = require(Shared.kart.SlipstreamVfxMath)
local Standings = require(Shared.race.Standings)
local TouchControls = require("./TouchControls")
local TrackRegistry = require(Shared.track.TrackRegistry)
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
	panel.Size = UDim2.fromOffset(680, 286)
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
	local itemLbl = makeRow("Item", 6, 15, Color3.fromRGB(255, 225, 115))
	local matLbl = makeRow("Material", 7, 15, Color3.fromRGB(240, 225, 155))
	local airLbl = makeRow("Airborne", 8, 15, Color3.fromRGB(115, 240, 145))
	local camDiagLbl = makeRow("CamDiag", 9, 14, Color3.fromRGB(195, 220, 255))

	local controlsLbl = makeRow("Controls", 10, 12, Color3.fromRGB(165, 172, 185))
	controlsLbl.Text = if IS_STUDIO
		then "Arrows/WASD: Drive | V/Shift: Drift | N: Nitro | Space: Fire | B: Look-Back | G: +3 Nitro | [/]: Cycle Item | R: Reset | F3: Debug | F8: Local"
		else "Arrows/WASD: Drive | V/Shift: Drift | N: Nitro | Space: Fire | B: Look-Back | Backspace/R: Reset | F3: Debug HUD"

	local switcherFrame: Frame? = nil
	if IS_STUDIO then
		local sf = Instance.new("Frame")
		sf.Name = "DebugItemSwitcher"
		sf.LayoutOrder = 11
		sf.Size = UDim2.new(1, 0, 0, 50)
		sf.BackgroundTransparency = 1
		sf.Parent = panel

		local grid = Instance.new("UIGridLayout")
		grid.CellSize = UDim2.fromOffset(72, 22)
		grid.CellPadding = UDim2.fromOffset(4, 4)
		grid.Parent = sf
		switcherFrame = sf
	end

	local creditLbl = makeRow("Attribution", 12, 11, Color3.fromRGB(125, 132, 145))
	creditLbl.Text = "Unofficial SuperTuxKart 1.5 port (supertuxkart.net)"

	return {
		gui = gui,
		title = title,
		speed = speedLbl,
		slip = slipLbl,
		skid = skidLbl,
		nitro = nitroLbl,
		item = itemLbl,
		mat = matLbl,
		air = airLbl,
		camDiag = camDiagLbl,
		switcherFrame = switcherFrame,
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
local hydrateKartRemote = if remotesFolder then remotesFolder:FindFirstChild("HydrateKart") :: RemoteFunction? else nil

local profile = KartTuning.buildProfileForKart("tux", "best")
local visuals = KartPresentation.create(localPlayer, profile, "tux")
local startReferee = RefereePresentation.createStartReferee()
local smoothedCamYaw: number? = nil
local smoothedCamY: number? = nil

local localKartId = if localPlayer.UserId ~= 0 then localPlayer.UserId else 2
local activeTrack = TrackRegistry.get(
	if type(Workspace:GetAttribute("OpenKartActiveTrack")) == "string"
		then Workspace:GetAttribute("OpenKartActiveTrack") :: string
		else TrackRegistry.DEFAULT_TRACK_ID
)
local localItemWorld = ItemWorld.fromArenaSpec(activeTrack :: any, "NORMAL_RACE")
local localFlyableWorld = Flyable.createWorld()
local itemVisuals = ItemPresentation.create()
local flyableVisuals = FlyablePresentation.create()
local latestRemoteKarts: { GreyboxProtocol.RemoteKartState } = {}
local remoteKartStates: { [string]: KartSolver.KartState } = {}
local remoteKartVisuals: { [string]: KartPresentation.VisualKart } = {}
local remoteInterpBuffers: { [string]: RemoteInterp.Buffer } = {}
local sfxPlayer = SfxPlayer.create()
local localAudioTracker = SfxEvents.createTracker()
local remoteAudioTrackers: { [string]: SfxEvents.AudioTracker } = {}

local localStepper = FixedStep.new()
local localState = KartSolver.createState(profile, activeTrack.startPos, activeTrack.startYawRad)
local initProgress =
	CheckManager.initKartProgress(activeTrack.checkpoints, activeTrack.startPos, activeTrack.startYawRad)
localState.race.lap = initProgress.lap
localState.race.nextCheckpoint = initProgress.nextCheckpoint
local localRaceTick = 0
local localDelayFinishStartTick = -1
local localTotalLaps = KartTuning.race.DEFAULT_LAPS
local localProgress = AIController.createState(activeTrack.drivelineQuadCenters, localState.pos)
local prevPose = capturePose(localState)
local currPose = capturePose(localState)

local cachedWorldQuery: KartSolver.WorldQuery? = nil
local function resolveWorldQuery(): KartSolver.WorldQuery?
	if cachedWorldQuery ~= nil then
		return cachedWorldQuery
	end
	local activeModel = Workspace:FindFirstChild(TrackRegistry.ACTIVE_TRACK_MODEL_NAME)
	local arena = if activeModel then activeModel else Workspace:FindFirstChild(GreyboxProtocol.ARENA_NAME)
	local surfaces = if arena then arena:FindFirstChild("Surfaces") else nil
	if surfaces then
		cachedWorldQuery = RobloxWorldQuery.create(surfaces)
	end
	return cachedWorldQuery
end

local localOnlyMode = false

if IS_STUDIO and hud.switcherFrame then
	local debugItemRemote = remotesFolder:FindFirstChild("OpenKartDebugGrantItem")
	local allItems = {
		ItemTuning.POWERUP_BUBBLEGUM,
		ItemTuning.POWERUP_CAKE,
		ItemTuning.POWERUP_BOWLING,
		ItemTuning.POWERUP_ZIPPER,
		ItemTuning.POWERUP_PLUNGER,
		ItemTuning.POWERUP_SWITCH,
		ItemTuning.POWERUP_SWATTER,
		ItemTuning.POWERUP_RUBBERBALL,
		ItemTuning.POWERUP_PARACHUTE,
		ItemTuning.POWERUP_ANVIL,
	}
	local debugItemIdx = 1
	local function grantDebugItem(itemType: number)
		local count = if itemType == ItemTuning.POWERUP_CAKE or itemType == ItemTuning.POWERUP_BOWLING then 3 else 1
		if localOnlyMode then
			localState.heldPowerup = itemType
			localState.heldPowerupCount = count
		elseif debugItemRemote and debugItemRemote:IsA("RemoteEvent") then
			(debugItemRemote :: RemoteEvent):FireServer(itemType, count)
		end
	end
	for _, itemType in allItems do
		local btn = Instance.new("TextButton")
		btn.Name = "ItemBtn_" .. tostring(itemType)
		btn.BackgroundColor3 = Color3.fromRGB(35, 42, 58)
		btn.TextColor3 = Color3.fromRGB(240, 240, 245)
		btn.Font = Enum.Font.Code
		btn.TextSize = 11
		btn.Text = string.sub(ItemTuning.POWERUP_NAMES[itemType] or "?", 1, 8)
		btn.Parent = hud.switcherFrame
		btn.Activated:Connect(function()
			grantDebugItem(itemType)
		end)
	end
	local switchTrackRemote = remotesFolder:FindFirstChild("OpenKartSwitchTrack")
	if switchTrackRemote and switchTrackRemote:IsA("RemoteEvent") then
		local trackBtn = Instance.new("TextButton")
		trackBtn.Name = "TrackSwitchBtn"
		trackBtn.BackgroundColor3 = Color3.fromRGB(48, 72, 54)
		trackBtn.TextColor3 = Color3.fromRGB(240, 244, 250)
		trackBtn.Font = Enum.Font.Code
		trackBtn.TextSize = 11
		trackBtn.Text = "Arena"
		trackBtn.Parent = hud.switcherFrame
		trackBtn.Activated:Connect(function()
			local nextId = if activeTrack.trackId == "sandtrack" then "openkart_arena" else "sandtrack"
			trackBtn.Text = if nextId == "sandtrack" then "Arena" else "Sandtrk"
			(switchTrackRemote :: RemoteEvent):FireServer(nextId)
		end)
	end
	UserInputService.InputBegan:Connect(function(inputObj: InputObject, gameProcessed: boolean)
		if gameProcessed then
			return
		end
		if inputObj.KeyCode == Enum.KeyCode.RightBracket then
			debugItemIdx = (debugItemIdx % #allItems) + 1
			grantDebugItem(allItems[debugItemIdx])
		elseif inputObj.KeyCode == Enum.KeyCode.LeftBracket then
			debugItemIdx = ((debugItemIdx - 2) % #allItems) + 1
			grantDebugItem(allItems[debugItemIdx])
		end
	end)
end
local inputSeq = 0
local lastReceivedServerTick = 0
local lastAppliedServerTick = 0
local lastResetSeq = 0
local pendingSnapshot: TelemetryPacket? = nil
local reconciler = ReconciliationSmoother.new(
	ReconciliationSmoother.DEFAULT_TAU_SEC,
	ReconciliationSmoother.DEFAULT_SNAP_THRESHOLD_METERS
)
local resetNoticeText = ""
local resetNoticeExpirySec = 0.0
local lastCorrectionErrMeters = 0.0
local lastReplayedTicks = 0
local inputHistory: { InputHistoryEntry } = {}

Workspace:GetAttributeChangedSignal("OpenKartActiveTrack"):Connect(function()
	local rawId = Workspace:GetAttribute("OpenKartActiveTrack")
	activeTrack = TrackRegistry.get(if type(rawId) == "string" then rawId else TrackRegistry.DEFAULT_TRACK_ID)
	cachedWorldQuery = nil
	localItemWorld =
		ItemWorld.fromArenaSpec(activeTrack :: any, ClientSessionState.get().config.raceType or "NORMAL_RACE")
	localFlyableWorld = Flyable.createWorld()
	localState = KartSolver.createState(profile, activeTrack.startPos, activeTrack.startYawRad)
	local p = CheckManager.initKartProgress(activeTrack.checkpoints, activeTrack.startPos, activeTrack.startYawRad)
	localState.race.lap = p.lap
	localState.race.nextCheckpoint = p.nextCheckpoint
	localRaceTick = 0
	localDelayFinishStartTick = -1
	localProgress = AIController.createState(activeTrack.drivelineQuadCenters, localState.pos)
	table.clear(inputHistory)
	ReconciliationSmoother.reset(reconciler)
	smoothedCamYaw = nil
	smoothedCamY = nil
	prevPose = capturePose(localState)
	currPose = capturePose(localState)
end)

local lastSent: ClientInputPacket = {
	seq = 0,
	accel = 0,
	brake = false,
	steer = 0,
	drift = false,
	nitro = false,
	fire = false,
	reset = false,
	debugGrantNitro = false,
}
local lastSentTime = 0.0
local inputMapper: any = nil
local function triggerPauseMenu()
	if ClientSessionState.get().phase ~= "RACING" then
		return
	end
	local paused = not HudState.get().isPaused
	HudState.setPaused(paused)
	if inputMapper ~= nil then
		inputMapper.setSuppressed(paused)
	end
end
HudState.setPauseHandler(triggerPauseMenu)

local touchControls = TouchControls.create({
	onPause = triggerPauseMenu,
})
inputMapper = InputMapper.createLive({
	isStudio = IS_STUDIO,
	getTouchState = touchControls.getState,
	onPause = triggerPauseMenu,
	onToggleDebugHud = function()
		hud.gui.Enabled = not hud.gui.Enabled
	end,
	onToggleLocalMode = function()
		localOnlyMode = not localOnlyMode
		lastCorrectionErrMeters = 0.0
		lastReplayedTicks = 0
		pendingSnapshot = nil
		ReconciliationSmoother.reset(reconciler)
		table.clear(inputHistory)
	end,
})

local function sampleInput(): (KartSolver.KartInput, boolean, boolean, boolean)
	return inputMapper.sample()
end

local activeCameraPreset: SettingsSchema.CameraPreset = "Normal"
local sessionCommandRemote = remotesFolder:WaitForChild("SessionCommand", 10) :: RemoteEvent?
local sessionStateRemote = remotesFolder:WaitForChild("SessionState", 10) :: RemoteEvent?
local localP2InputRemote = remotesFolder:WaitForChild("LocalP2Input", 10) :: RemoteEvent?
local fastestLapRemote = remotesFolder:WaitForChild("FastestLap", 10) :: RemoteEvent?
local lastP2SentTime = 0.0

if fastestLapRemote then
	fastestLapRemote.OnClientEvent:Connect(function(payload: any)
		if type(payload) == "table" and type(payload.timeTicks) == "number" and payload.timeTicks > 0 then
			HudState.setFastestLap({
				kartId = tonumber(payload.kartId) or 0,
				holderName = tostring(payload.holderName or ""),
				timeTicks = payload.timeTicks,
				receivedAtSec = os.clock(),
			})
		end
	end)
end

ClientSettingsState.subscribe(function(settings)
	inputMapper.setBindings(settings.input)
	SfxPlayer.applyAudioSettings(sfxPlayer, settings.audio)
	activeCameraPreset = settings.ui.cameraPreset
	local allVisuals: { [string]: any } = { ["local"] = visuals }
	for id, rv in remoteKartVisuals do
		allVisuals[id] = rv
	end
	SettingsApplier.applyGraphicsToWorkspace(settings, allVisuals, KartPresentation)
end)
ClientSettingsState.loadFromServerAsync()

if sessionStateRemote then
	sessionStateRemote.OnClientEvent:Connect(function(payload: any)
		if type(payload) ~= "table" then
			return
		end
		local phase = if payload.phase == "RACING" then "RACING" elseif payload.phase == "LOBBY" then "LOBBY" else "MENU"
		local cfg = payload.config
		if phase ~= "RACING" then
			ClientSessionState.set({
				phase = phase :: any,
				config = cfg,
				localP2Active = payload.localP2Active == true,
			})
			inputMapper.setSuppressed(true)
			inputMapper.setLocalTwoPlayer(cfg ~= nil and cfg.playMode == "LOCAL_2P")
			visuals.model.Parent = nil
			if startReferee ~= nil then
				startReferee.model.Parent = nil
			end
			for _, rv in remoteKartVisuals do
				rv.model:Destroy()
			end
			table.clear(remoteKartVisuals)
			table.clear(remoteInterpBuffers)
			table.clear(remoteKartStates)
			SfxPlayer.clearMatchSounds(sfxPlayer)
			SfxEvents.resetTracker(localAudioTracker)
			table.clear(remoteAudioTrackers)
			HudState.setPaused(false)
			HudState.setFastestLap(nil)
			HudState.get().ready = false
		else
			-- Keep input/render suppressed while hydrating and rebuilding models (prevents re-entrant yield/Parent-locked errors)
			inputMapper.setSuppressed(true)
			HudState.setPaused(false)
			HudState.setFastestLap(nil)
			localItemWorld = ItemWorld.fromArenaSpec(
				activeTrack :: any,
				if cfg and cfg.raceType then cfg.raceType else "NORMAL_RACE"
			)
			localTotalLaps = if cfg and type(cfg.laps) == "number" then cfg.laps else KartTuning.race.DEFAULT_LAPS
			local selectedKartId = if cfg and type(cfg.kartId) == "string" then cfg.kartId else "tux"
			local selectedDiff = if cfg and cfg.difficulty then cfg.difficulty else "intermediate"
			local assetsFolder = ReplicatedStorage:FindFirstChild("Assets")
			local kartsFolder = if assetsFolder then assetsFolder:FindFirstChild("Karts") else nil
			local existingTemplate = if kartsFolder then kartsFolder:FindFirstChild(selectedKartId) else nil
			local hasMesh = false
			if existingTemplate then
				for _, d in existingTemplate:GetDescendants() do
					if d:IsA("MeshPart") then
						hasMesh = true
						break
					end
				end
			end
			if not hasMesh and hydrateKartRemote then
				pcall(function()
					hydrateKartRemote:InvokeServer(selectedKartId)
				end)
			end
			profile = KartTuning.buildProfileForKart(selectedKartId, selectedDiff)
			if visuals.model then
				visuals.model:Destroy()
			end
			for _, rv in remoteKartVisuals do
				rv.model:Destroy()
			end
			table.clear(remoteKartVisuals)
			table.clear(remoteInterpBuffers)
			table.clear(remoteKartStates)
			SfxPlayer.clearMatchSounds(sfxPlayer)
			SfxEvents.resetTracker(localAudioTracker)
			table.clear(remoteAudioTrackers)
			SfxPlayer.applyAudioSettings(sfxPlayer, ClientSettingsState.get().audio)
			visuals = KartPresentation.create(localPlayer, profile, selectedKartId)
			local sInit = ClientSettingsState.get()
			KartPresentation.applyVisualSettings(
				visuals,
				sInit.graphics.shadows,
				SettingsSchema.getParticleRateMultiplier(sInit.graphics.particles)
			)
			visuals.model.Parent = Workspace
			localState = KartSolver.createState(profile, activeTrack.startPos, activeTrack.startYawRad)
			local defPowerup, defCount =
				ItemTuning.getDefaultCollectibles(if cfg then cfg.raceType else "NORMAL_RACE", localTotalLaps)
			if defCount > 0 then
				KartSolver.setPowerup(localState, defPowerup, defCount)
			end
			localProgress = AIController.createState(activeTrack.drivelineQuadCenters, localState.pos)
			table.clear(inputHistory)
			pendingSnapshot = nil
			lastAppliedServerTick = 0
			lastReceivedServerTick = 0
			smoothedCamYaw = nil
			smoothedCamY = nil
			ReconciliationSmoother.reset(reconciler)
			prevPose = capturePose(localState)
			currPose = capturePose(localState)
			ClientSessionState.set({
				phase = phase :: any,
				config = cfg,
				localP2Active = payload.localP2Active == true,
			})
			inputMapper.setLocalTwoPlayer(cfg ~= nil and cfg.playMode == "LOCAL_2P")
			inputMapper.setSuppressed(false)
		end
	end)
end

if sessionCommandRemote then
	sessionCommandRemote:FireServer("REQUEST_STATE")
end
inputMapper.setSuppressed(ClientSessionState.get().phase ~= "RACING")
if ClientSessionState.get().phase ~= "RACING" then
	visuals.model.Parent = nil
end

telemetryRemote.OnClientEvent:Connect(function(rawPayload: any, rawNotice: any)
	if localOnlyMode then
		return
	end
	local snapshot = GreyboxProtocol.unpackSnapshot(rawPayload, rawNotice)
	if snapshot == nil then
		return
	end
	-- UnreliableRemoteEvent can deliver packets out of order; discard stale ticks immediately
	if snapshot.tick <= lastReceivedServerTick then
		return
	end
	lastReceivedServerTick = snapshot.tick
	pendingSnapshot = snapshot
end)

local function syncRemoteKartStates(remotes: { GreyboxProtocol.RemoteKartState })
	local seen: { [string]: boolean } = {}
	for _, rk in remotes do
		seen[rk.id] = true
		local rs = remoteKartStates[rk.id]
		if rs == nil then
			rs = KartSolver.createState(profile, { x = rk.pos[1], y = rk.pos[2], z = rk.pos[3] }, 0)
			remoteKartStates[rk.id] = rs
		end
		rs.pos = { x = rk.pos[1], y = rk.pos[2], z = rk.pos[3] }
		rs.lastSafePos = { x = rk.pos[1], y = rk.pos[2], z = rk.pos[3] }
		rs.rot = { w = rk.rot[1], x = rk.rot[2], y = rk.rot[3], z = rk.rot[4] }
		rs.lastSafeRot = { w = rk.rot[1], x = rk.rot[2], y = rk.rot[3], z = rk.rot[4] }
		local rv = rk.linVel
		if rv ~= nil then
			rs.linVel = { x = rv[1] or 0, y = rv[2] or 0, z = rv[3] or 0 }
		else
			local _, _, rFwd = Math3D.quatBasis(rs.rot)
			rs.linVel = Math3D.scale(rFwd, rk.speed)
		end
		rs.speed = rk.speed
		rs.steer = rk.steer
		rs.attachmentType = rk.attachmentType
		rs.attachmentTicksLeft = rk.attachmentTicksLeft or 0
		rs.itemEffect.plungerFaceTicks = rk.plungerFaceTicks
		rs.timedImpulseTicks = rk.timedImpulseTicks or 0
	end
	for id, _ in remoteKartStates do
		if not seen[id] then
			remoteKartStates[id] = nil
		end
	end
end

local function buildClientCollisionParticipants(): { KartSolver.CollisionParticipant }
	local list: { KartSolver.CollisionParticipant } = {
		{ id = localKartId, state = localState },
	}
	for idx, rk in latestRemoteKarts do
		local rs = remoteKartStates[rk.id]
		if rs ~= nil then
			local numericId = tonumber(rk.id) or -(1000 + idx)
			table.insert(list, { id = numericId, state = rs })
		end
	end
	return list
end

local function formatKartDisplayName(kartId: string?): string
	local k = kartId or "tux"
	return string.upper(string.sub(k, 1, 1)) .. string.sub(k, 2)
end

local function buildClientStandingsAndProxies(): ({ Standings.StandingsEntry }, number, { Flyable.KartProxy })
	local localName = if #localPlayer.DisplayName > 0 then localPlayer.DisplayName else localPlayer.Name
	local entries: { Standings.StandingsEntry } = {
		{
			id = "local",
			kartId = profile.kartId,
			displayName = localName,
			lap = localState.race.lap,
			checkpoint = CheckManager.getMonotonicCheckpoint(
				localState.race.lap,
				localState.race.nextCheckpoint,
				activeTrack.checkpoints
			),
			distance = localProgress.lapDistance,
			initialPosition = 2,
			finished = localState.race.raceFinished,
			finishTime = if localState.race.raceFinished and localState.race.finishTick >= 0
				then RaceState.getRaceElapsedSec(localState.race.finishTick)
				else nil,
			bestLapTicks = localState.race.bestLapTicks,
		},
	}
	for idx, rk in latestRemoteKarts do
		local rPos = { x = rk.pos[1], y = rk.pos[2], z = rk.pos[3] }
		local _, rDist = AIController.computeTrackProgress(rPos, activeTrack.drivelineQuadCenters)
		local rLap = rk.lap or -1
		local rNextChk = rk.nextCheckpoint or 0
		local rFin = rk.raceFinished == true
		local rFinTick = rk.finishTick or -1
		local rName = if rk.id == "local_p2"
			then "Player 2"
			elseif rk.id == "dummy" or string.sub(rk.id, 1, 3) == "ai_" then formatKartDisplayName(rk.kartId)
			else rk.id
		table.insert(entries, {
			id = rk.id,
			kartId = rk.kartId,
			displayName = rName,
			lap = rLap,
			checkpoint = CheckManager.getMonotonicCheckpoint(rLap, rNextChk, activeTrack.checkpoints),
			distance = rDist,
			initialPosition = idx,
			finished = rFin,
			finishTime = if rFin and rFinTick >= 0 then RaceState.getRaceElapsedSec(rFinTick) else nil,
			bestLapTicks = rk.bestLapTicks,
		})
	end
	local myRank = Standings.getRankForId(entries, "local")
	local proxies: { Flyable.KartProxy } = {
		KartSolver.makeFlyableProxy(localKartId, localState, myRank, "best"),
	}
	for idx, rk in latestRemoteKarts do
		local numericId = tonumber(rk.id) or -(1000 + idx)
		local rs = remoteKartStates[rk.id]
		if rs ~= nil then
			table.insert(proxies, KartSolver.makeFlyableProxy(numericId, rs, rk.rank, "best"))
		else
			table.insert(proxies, {
				id = numericId,
				pos = { x = rk.pos[1], y = rk.pos[2], z = rk.pos[3] },
				rot = { w = rk.rot[1], x = rk.rot[2], y = rk.rot[3], z = rk.rot[4] },
				linVel = { x = 0, y = 0, z = rk.speed },
				speed = rk.speed,
				width = profile.width,
				height = profile.collisionHeight,
				length = profile.length,
				rank = rk.rank,
				baseMaxSpeed = profile.maxSpeed,
				isInvulnerable = false,
				isInAnimation = false,
				isShielded = (rk.attachmentType == ItemTuning.ATTACHMENT_BUBBLEGUM_SHIELD),
				hasBomb = (rk.attachmentType == ItemTuning.ATTACHMENT_BOMB),
				onExplode = function() end,
				onSquash = function() end,
				onPlungerFace = function() end,
				onRubberBandPull = function() end,
			})
		end
	end
	return entries, myRank, proxies
end

-- STK normal/reverse follow-camera state (src/graphics/camera/camera_normal.cpp:L102-L144, L224-L241, user_config.hpp:L1046-L1066)
local camCfg = KartTuning.camera
local camOffsetX = 0.0
local camOffsetY = camCfg.heightBase
local camOffsetZ = -camCfg.distanceBase * math.sqrt(camCfg.smoothPosition)
local wasLookingBack = false

local function signedYawAngleDeg(fromDir: Vector3, toDir: Vector3): number
	local crossY = fromDir.X * toDir.Z - fromDir.Z * toDir.X
	local dot = math.clamp(fromDir.X * toDir.X + fromDir.Z * toDir.Z, -1.0, 1.0)
	return math.deg(math.atan2(crossY, dot))
end

RunService:BindToRenderStep("OpenKartClientFrame", Enum.RenderPriority.Camera.Value + 1, function(dt: number)
	local sessionState = ClientSessionState.get()
	if sessionState.phase ~= "RACING" then
		SfxPlayer.stopAllLoops(sfxPlayer)
		return
	end
	local now = os.clock()
	local solverInput, wantsReset, wantsGrantNitro, lookBack = sampleInput()
	if
		sessionState.config.playMode == "LOCAL_2P"
		and localP2InputRemote
		and (now - lastP2SentTime) >= INPUT_HEARTBEAT_SEC
	then
		local p2Input, p2Reset = inputMapper.samplePlayer2()
		lastP2SentTime = now
		localP2InputRemote:FireServer({
			seq = inputSeq + 1,
			accel = p2Input.accel,
			brake = p2Input.brake,
			steer = p2Input.steer,
			drift = p2Input.drift,
			nitro = p2Input.nitro,
			fire = p2Input.fire,
			lookBack = p2Input.lookBack,
			reset = p2Reset,
			grantNitro = false,
		})
	end

	if wantsGrantNitro then
		KartSolver.addNitro(localState, profile.nitro.bigContainer)
	end
	if wantsReset then
		localState = KartSolver.createState(profile, activeTrack.startPos, activeTrack.startYawRad)
		localProgress = AIController.createState(activeTrack.drivelineQuadCenters, localState.pos)
		table.clear(inputHistory)
		pendingSnapshot = nil
		ReconciliationSmoother.reset(reconciler)
		prevPose = capturePose(localState)
		currPose = capturePose(localState)
	end

	local worldQuery = resolveWorldQuery()
	if pendingSnapshot ~= nil and not localOnlyMode and worldQuery ~= nil then
		local snapshot = pendingSnapshot :: TelemetryPacket
		pendingSnapshot = nil
		if snapshot.tick > lastAppliedServerTick then
			lastAppliedServerTick = snapshot.tick
			latestRemoteKarts = snapshot.remoteKarts or {}
			syncRemoteKartStates(latestRemoteKarts)
			local snapServerTime = snapshot.serverTime or Workspace:GetServerTimeNow()
			for _, rk in latestRemoteKarts do
				local ibuf = remoteInterpBuffers[rk.id]
				if not ibuf then
					ibuf = RemoteInterp.createBuffer()
					remoteInterpBuffers[rk.id] = ibuf
				end
				RemoteInterp.push(ibuf, {
					serverTime = snapServerTime,
					pos = { x = rk.pos[1], y = rk.pos[2], z = rk.pos[3] },
					rot = { w = rk.rot[1], x = rk.rot[2], y = rk.rot[3], z = rk.rot[4] },
					vel = if rk.linVel then { x = rk.linVel[1], y = rk.linVel[2], z = rk.linVel[3] } else nil,
					speed = rk.speed,
					steer = rk.steer,
				})
			end
			local preAlpha = localStepper:getAlpha()
			local preInterpPos = Math3D.vecLerp(prevPose.pos, currPose.pos, preAlpha)
			local preInterpRot = Math3D.quatSlerp(prevPose.rot, currPose.rot, preAlpha)
			local renderedBeforePos, renderedBeforeRot =
				ReconciliationSmoother.apply(reconciler, preInterpPos, preInterpRot)

			if snapshot.resetSeq > lastResetSeq then
				lastResetSeq = snapshot.resetSeq
				KartSolver.applyNetState(localState, snapshot.netState, localItemWorld, localFlyableWorld)
				localRaceTick = localState.race.raceTick
				if
					(localState.race.phase == "DELAY_FINISH_PHASE" or localState.race.phase == "RESULT_DISPLAY_PHASE")
					and localDelayFinishStartTick < 0
				then
					localDelayFinishStartTick = localRaceTick
				elseif
					RaceState.isActiveRacePhase(localState.race.phase) or RaceState.isStartPhase(localState.race.phase)
				then
					localDelayFinishStartTick = -1
				end
				localProgress = AIController.createState(activeTrack.drivelineQuadCenters, localState.pos)
				table.clear(inputHistory)
				prevPose = capturePose(localState)
				currPose = capturePose(localState)
				ReconciliationSmoother.reset(reconciler)
				lastCorrectionErrMeters = 0.0
				lastReplayedTicks = 0
				if snapshot.resetNotice ~= "" then
					resetNoticeText = snapshot.resetNotice
					resetNoticeExpirySec = now + 1.5
				end
			else
				local oldCurrPos = currPose.pos
				local oldCurrRot = currPose.rot
				local prePos = localState.pos
				local retained: { InputHistoryEntry } = {}
				for _, entry in inputHistory do
					if entry.seq > snapshot.lastInputSeq then
						table.insert(retained, entry)
					end
				end
				inputHistory = retained

				KartSolver.applyNetState(localState, snapshot.netState, localItemWorld, localFlyableWorld)
				localRaceTick = localState.race.raceTick
				if
					(localState.race.phase == "DELAY_FINISH_PHASE" or localState.race.phase == "RESULT_DISPLAY_PHASE")
					and localDelayFinishStartTick < 0
				then
					localDelayFinishStartTick = localRaceTick
				elseif
					RaceState.isActiveRacePhase(localState.race.phase) or RaceState.isStartPhase(localState.race.phase)
				then
					localDelayFinishStartTick = -1
				end
				local replayCount = #inputHistory
				if replayCount > 0 then
					for idx, entry in inputHistory do
						if idx == replayCount then
							prevPose = capturePose(localState)
						end
						localRaceTick += 1
						local rPhase: RaceState.RacePhase = RaceState.phaseAtTick(
							localRaceTick,
							if localDelayFinishStartTick >= 0 then localDelayFinishStartTick else nil
						) :: RaceState.RacePhase
						local rRawInput = if localState.race.raceFinished
							then AIController.computeCoastInput(
								localProgress,
								localState,
								activeTrack.drivelineQuadCenters,
								FixedStep.FIXED_DT
							)
							else entry.input
						local rFilteredInput = KartSolver.stepRaceInput(localState, rRawInput, localRaceTick, rPhase)
						local _, myRank, proxies = buildClientStandingsAndProxies()
						KartSolver.stepWithItems(
							localState,
							rFilteredInput,
							worldQuery,
							FixedStep.FIXED_DT,
							localItemWorld,
							{
								isServer = false,
								kartId = localKartId,
								flyableWorld = localFlyableWorld,
								allKartProxies = proxies,
								drivelineCenters = activeTrack.drivelineQuadCenters,
								rank = myRank,
								difficulty = "best",
							}
						)
						if not KartSolver.isRescuing(localState) then
							CheckManager.stepKart(
								localState.race,
								activeTrack.checkpoints,
								localState.prevPos,
								localState.pos,
								localRaceTick,
								localTotalLaps
							)
							KartSolver.updateLastRescuePose(
								localState,
								activeTrack.checkpoints,
								activeTrack.drivelineQuadCenters,
								worldQuery,
								activeTrack.drivelineBranches
							)
						end
						local rParticipants = buildClientCollisionParticipants()
						KartSolver.resolveKartKartCollisions(rParticipants)
						if localState.attachmentType == ItemTuning.ATTACHMENT_SWATTER then
							KartSolver.checkSwatterHits(
								localState,
								rParticipants,
								localItemWorld.elapsedTicks,
								localItemWorld.isBattle
							)
						end
						AIController.updateProgress(localProgress, localState.pos, activeTrack.drivelineQuadCenters)
						local _, _, postProxies = buildClientStandingsAndProxies()
						for _, proxy in postProxies do
							local pState = (proxy :: any)._state
							if pState ~= nil then
								KartSolver.refreshFlyableProxy(proxy, pState, proxy.rank)
							end
						end
						Flyable.step(
							localFlyableWorld,
							postProxies,
							worldQuery,
							FixedStep.FIXED_DT,
							activeTrack.drivelineQuadCenters,
							localItemWorld.elapsedTicks
						)
					end
					currPose = capturePose(localState)
				else
					currPose = capturePose(localState)
					-- Preserve previous-tick span when 0 unacked ticks exist so alpha stays continuous
					local posShift = Math3D.sub(currPose.pos, oldCurrPos)
					local rotShift =
						Math3D.quatNormalize(Math3D.quatMul(currPose.rot, Math3D.quatConjugate(oldCurrRot)))
					prevPose.pos = Math3D.add(prevPose.pos, posShift)
					prevPose.rot = Math3D.quatNormalize(Math3D.quatMul(rotShift, prevPose.rot))
				end

				local postInterpPos = Math3D.vecLerp(prevPose.pos, currPose.pos, preAlpha)
				local postInterpRot = Math3D.quatSlerp(prevPose.rot, currPose.rot, preAlpha)
				ReconciliationSmoother.recordCorrection(
					reconciler,
					renderedBeforePos,
					renderedBeforeRot,
					postInterpPos,
					postInterpRot
				)
				lastReplayedTicks = replayCount
				lastCorrectionErrMeters = Math3D.len(Math3D.sub(localState.pos, prePos))
			end
		end
	end

	local steppedThisFrame = false
	if worldQuery ~= nil then
		debug.profilebegin("OpenKart_ClientSim")
		localStepper:advance(dt, function(fixedDt: number)
			steppedThisFrame = true
			inputSeq += 1
			prevPose = capturePose(localState)
			if
				(localState.pos.y < activeTrack.voidResetYMeters or localState.resetTriggered)
				and not KartSolver.isRescuing(localState)
			then
				if localState.resetTriggered then
					resetNoticeText = "RESET (" .. localState.activeMaterialName .. ")"
					resetNoticeExpirySec = os.clock() + 1.5
				end
				local targetPos, targetYawRad = CheckManager.resolveClampedRescuePose(
					localState.lastRescueQuadIdx,
					localState.lastRescuePos,
					localState.lastRescueYawRad,
					activeTrack.checkpoints,
					localState.race.lap,
					localState.race.nextCheckpoint,
					activeTrack.drivelineQuadCenters,
					activeTrack.startPos,
					activeTrack.startYawRad,
					worldQuery,
					profile.collisionHeight,
					localState.pos
				)
				local verifiedPos, verifiedYaw, groundOk, errReason = CheckManager.verifyRescuePlacement(
					targetPos,
					targetYawRad,
					activeTrack.drivelineQuadCenters,
					worldQuery,
					profile.collisionHeight
				)
				if not groundOk then
					warn(string.format("[OpenKart][Rescue] Post-rescue ground check failed: %s", tostring(errReason)))
				end
				KartSolver.triggerRescue(localState, verifiedPos, verifiedYaw)
			end
			localRaceTick += 1
			local lPhase: RaceState.RacePhase = RaceState.phaseAtTick(
				localRaceTick,
				if localDelayFinishStartTick >= 0 then localDelayFinishStartTick else nil
			) :: RaceState.RacePhase
			if
				IS_STUDIO
				and Workspace:GetAttribute("OpenKartAutopilot") == true
				and not localState.race.raceFinished
			then
				if (lPhase :: string) == "SET_PHASE" and localRaceTick >= RaceState.SET_START_TICK + 2 then
					solverInput = {
						accel = 1.0,
						brake = false,
						steer = 0.0,
						drift = false,
						nitro = false,
						fire = false,
						lookBack = false,
					}
				elseif RaceState.isRacePhase(lPhase) then
					solverInput = AIController.computeInput(
						localProgress,
						localState,
						activeTrack.drivelineQuadCenters,
						fixedDt,
						profile.maxSpeed
					)
				end
			end
			local rawStepInput = if localState.race.raceFinished
				then AIController.computeCoastInput(
					localProgress,
					localState,
					activeTrack.drivelineQuadCenters,
					fixedDt
				)
				else solverInput
			table.insert(inputHistory, {
				seq = inputSeq,
				input = {
					accel = rawStepInput.accel,
					brake = rawStepInput.brake,
					steer = rawStepInput.steer,
					drift = rawStepInput.drift,
					nitro = rawStepInput.nitro,
					fire = rawStepInput.fire,
					lookBack = rawStepInput.lookBack,
				},
			})
			if #inputHistory > MAX_INPUT_HISTORY then
				table.remove(inputHistory, 1)
			end
			local filteredInput = KartSolver.stepRaceInput(localState, rawStepInput, localRaceTick, lPhase)
			local _, myRank, proxies = buildClientStandingsAndProxies()
			KartSolver.stepWithItems(localState, filteredInput, worldQuery, fixedDt, localItemWorld, {
				isServer = false,
				kartId = localKartId,
				flyableWorld = localFlyableWorld,
				allKartProxies = proxies,
				drivelineCenters = activeTrack.drivelineQuadCenters,
				rank = myRank,
				difficulty = "best",
			})
			if not KartSolver.isRescuing(localState) then
				CheckManager.stepKart(
					localState.race,
					activeTrack.checkpoints,
					localState.prevPos,
					localState.pos,
					localRaceTick,
					localTotalLaps
				)
				KartSolver.updateLastRescuePose(
					localState,
					activeTrack.checkpoints,
					activeTrack.drivelineQuadCenters,
					worldQuery,
					activeTrack.drivelineBranches
				)
			end
			local lParticipants = buildClientCollisionParticipants()
			KartSolver.resolveKartKartCollisions(lParticipants)
			if localState.attachmentType == ItemTuning.ATTACHMENT_SWATTER then
				KartSolver.checkSwatterHits(
					localState,
					lParticipants,
					localItemWorld.elapsedTicks,
					localItemWorld.isBattle
				)
			end
			AIController.updateProgress(localProgress, localState.pos, activeTrack.drivelineQuadCenters)
			local _, _, postProxies = buildClientStandingsAndProxies()
			for _, proxy in postProxies do
				local pState = (proxy :: any)._state
				if pState ~= nil then
					KartSolver.refreshFlyableProxy(proxy, pState, proxy.rank)
				end
			end
			Flyable.step(
				localFlyableWorld,
				postProxies,
				worldQuery,
				fixedDt,
				activeTrack.drivelineQuadCenters,
				localItemWorld.elapsedTicks
			)
			currPose = capturePose(localState)
		end)
		debug.profileend()
	end

	ItemPresentation.sync(itemVisuals, localItemWorld, now)

	-- Sync remote karts (including TestDummyKart) and Flyable projectiles
	local kartPositionsById: { [number]: Vector3 } = {}
	local remoteMinimapPoses: { HudState.RemoteMinimapPose } = {}
	local seenRemotes: { [string]: boolean } = {}
	local defaultSusp = {
		KartTuning.suspension.rest,
		KartTuning.suspension.rest,
		KartTuning.suspension.rest,
		KartTuning.suspension.rest,
	}
	local remoteRenderTime = Workspace:GetServerTimeNow() - RemoteInterp.DEFAULT_INTERP_DELAY_SEC
	for idx, rk in latestRemoteKarts do
		seenRemotes[rk.id] = true
		local rv = remoteKartVisuals[rk.id]
		if rv == nil then
			local rKartId = rk.kartId or "tux"
			local rProf = KartTuning.buildProfileForKart(rKartId, "best")
			rv = KartPresentation.create(rk.id, rProf, rKartId)
			remoteKartVisuals[rk.id] = rv
			local sNow = ClientSettingsState.get()
			KartPresentation.applyVisualSettings(
				rv,
				sNow.graphics.shadows,
				SettingsSchema.getParticleRateMultiplier(sNow.graphics.particles)
			)
		end
		local ibuf = remoteInterpBuffers[rk.id]
		local sampled = if ibuf then RemoteInterp.sample(ibuf, remoteRenderTime) else nil
		local rPos = if sampled then sampled.pos else { x = rk.pos[1], y = rk.pos[2], z = rk.pos[3] }
		local rRot = if sampled then sampled.rot else { w = rk.rot[1], x = rk.rot[2], y = rk.rot[3], z = rk.rot[4] }
		local rSpeed = if sampled then sampled.speed else rk.speed
		local rSteer = if sampled then sampled.steer else rk.steer
		local rCf = RobloxWorldQuery.stkPoseToRobloxCFrame(rPos, rRot, 0, 0)
		local rSSTime = rk.slipstreamTime or 0.0
		local remoteVfxInput: SlipstreamVfxMath.SlipstreamVfxInput = {
			inZone = rSSTime > 0.0,
			chargeTicks = FixedStep.timeToTicks(rSSTime),
			minCollectTicks = FixedStep.timeToTicks(profile.slipstream.minCollectTime),
		}
		KartPresentation.update(
			rv,
			rCf,
			rSpeed,
			dt,
			rSteer,
			defaultSusp,
			rk.skidTier or 0,
			rk.skidState or "SKID_NONE",
			rk.nitroActive == true,
			rk.attachmentType,
			rk.isSquashed,
			rk.plungerFaceTicks,
			remoteVfxInput,
			rk.attachmentTicksLeft,
			if rk.attachmentType == ItemTuning.ATTACHMENT_SWATTER
				then {
					phase = rk.swatterPhase or 0,
					animTicks = rk.swatterAnimTicks or 0,
					bombMode = rk.swatterBombMode == true,
					targetYawRad = rk.swatterTargetYawRad or 0.0,
				}
				else nil,
			rk.rescueTicks
		)
		local numericId = tonumber(rk.id) or -(1000 + idx)
		kartPositionsById[numericId] =
			Vector3.new(Units.metersToStuds(rPos.x), Units.metersToStuds(rPos.y), Units.metersToStuds(-rPos.z))
		table.insert(remoteMinimapPoses, { id = rk.id, kartId = rk.kartId, x = rPos.x, z = rPos.z })

		local rTr = remoteAudioTrackers[rk.id]
		if not rTr then
			rTr = SfxEvents.createTracker()
			remoteAudioTrackers[rk.id] = rTr
		end
		local rRs = remoteKartStates[rk.id]
		local rStep = SfxEvents.step(rTr, {
			speedMps = rk.speed,
			maxSpeedMps = profile.maxSpeed,
			isOnGround = if rRs then rRs.isOnGround else true,
			skidState = rk.skidState or "SKID_NONE",
			nitroActive = rk.nitroActive == true,
			nitroEnergy = 0.0,
			nitroMax = profile.nitro.max,
			heldPowerup = 0,
			heldPowerupCount = 0,
			attachmentType = rk.attachmentType,
			itemEffectType = if rk.isSquashed then 2 elseif rRs then rRs.itemEffect.effectType else 0,
			plungerFaceTicks = rk.plungerFaceTicks,
			bounceBackTicks = if rRs then rRs.bounceBackTicks else 0,
		}, dt, false)
		SfxPlayer.applyStep(sfxPlayer, rk.id, rStep, rv.model.PrimaryPart or rv.sparkLeft)
	end
	for id, rv in remoteKartVisuals do
		if not seenRemotes[id] then
			SfxPlayer.removeKartLoops(sfxPlayer, id)
			rv.model:Destroy()
			remoteKartVisuals[id] = nil
			remoteAudioTrackers[id] = nil
			remoteInterpBuffers[id] = nil
		end
	end

	local changed = solverInput.accel ~= lastSent.accel
		or solverInput.brake ~= lastSent.brake
		or solverInput.steer ~= lastSent.steer
		or solverInput.drift ~= lastSent.drift
		or solverInput.nitro ~= lastSent.nitro
		or (solverInput.fire == true) ~= (lastSent.fire == true)
		or (solverInput.lookBack == true) ~= (lastSent.lookBack == true)
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
			fire = solverInput.fire == true,
			lookBack = solverInput.lookBack == true,
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
	ReconciliationSmoother.decay(reconciler, dt)
	local finalPos, finalRot = ReconciliationSmoother.apply(reconciler, interpPos, interpRot)
	local interpYaw = prevPose.visualSkidYaw + (currPose.visualSkidYaw - prevPose.visualSkidYaw) * alpha
	local interpHop = prevPose.hopHeight + (currPose.hopHeight - prevPose.hopHeight) * alpha
	local interpSpeedMps = prevPose.speedMps + (currPose.speedMps - prevPose.speedMps) * alpha
	local interpNitroEnergy = prevPose.nitroEnergy + (currPose.nitroEnergy - prevPose.nitroEnergy) * alpha

	local renderPose = RobloxWorldQuery.stkPoseToRobloxCFrame(finalPos, finalRot, 0, 0)
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
	debug.profilebegin("OpenKart_KartPres")
	local localVfxInput: SlipstreamVfxMath.SlipstreamVfxInput = {
		inZone = localState.slipstream.inZone,
		chargeTicks = localState.slipstream.chargeTicks,
		minCollectTicks = FixedStep.timeToTicks(profile.slipstream.minCollectTime),
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
		tel.nitroActive,
		tel.attachmentType,
		tel.isSquashed,
		tel.plungerFaceTicks,
		localVfxInput,
		tel.attachmentTicksLeft,
		if tel.attachmentType == ItemTuning.ATTACHMENT_SWATTER
			then {
				phase = tel.swatterPhase,
				animTicks = tel.swatterAnimTicks,
				bombMode = tel.swatterBombMode,
				targetYawRad = tel.swatterTargetYawRad,
			}
			else nil,
		tel.rescueTicks
	)
	RefereePresentation.updateStartReferee(startReferee, renderPose, localState.race.phase, localState.race.raceTick)
	kartPositionsById[localKartId] = bodyCFrame.Position
	FlyablePresentation.sync(flyableVisuals, localFlyableWorld, now, kartPositionsById)
	if localFlyableWorld.cancelEffects and #localFlyableWorld.cancelEffects > 0 then
		for _, ce in localFlyableWorld.cancelEffects do
			if ce.sfxId then
				SfxPlayer.playOneShot(sfxPlayer, ce.sfxId, visuals.model.PrimaryPart or visuals.sparkLeft, 1.0)
			end
		end
		table.clear(localFlyableWorld.cancelEffects)
	end
	local standingsEntries, myRank, _ = buildClientStandingsAndProxies()
	local localAudioStep = SfxEvents.step(localAudioTracker, {
		speedMps = interpSpeedMps,
		maxSpeedMps = profile.maxSpeed,
		isOnGround = localState.isOnGround,
		skidState = tel.skidState,
		nitroActive = tel.nitroActive,
		nitroEnergy = interpNitroEnergy,
		nitroMax = profile.nitro.max,
		heldPowerup = localState.heldPowerup,
		heldPowerupCount = localState.heldPowerupCount,
		attachmentType = tel.attachmentType,
		itemEffectType = localState.itemEffect.effectType,
		plungerFaceTicks = tel.plungerFaceTicks,
		bounceBackTicks = localState.bounceBackTicks,
		racePhase = localState.race.phase,
		lap = localState.race.lap,
		totalLaps = localTotalLaps,
		raceFinished = localState.race.raceFinished,
		rank = myRank,
		startupBoostFired = localState.race.startupBoostFired,
		startupBoostMps = localState.race.startupBoostMps,
		startupPenaltyTicks = localState.race.startupPenaltyTicks,
	}, dt, true)
	SfxPlayer.applyStep(sfxPlayer, "local", localAudioStep, visuals.model.PrimaryPart or visuals.sparkLeft)
	debug.profileend()

	local attrStart = Workspace:GetAttribute("OpenKartRaceStartTime")
	local raceStartServerTime = if type(attrStart) == "number" then attrStart else Workspace:GetServerTimeNow()
	local nitroGateOpen = (solverInput.accel > 0 and localState.isOnGround) or tel.nitroActive
	local finishTimeSec: number? = if localState.race.raceFinished and localState.race.finishTick >= 0
		then RaceState.getRaceElapsedSec(localState.race.finishTick)
		else nil
	HudState.publish(
		finalPos.x,
		finalPos.z,
		interpSpeedMps,
		profile.maxSpeed,
		interpNitroEnergy,
		profile.nitro.max,
		tel.nitroActive,
		"NORMAL_RACE",
		raceStartServerTime,
		localState.race.lap,
		CheckManager.getMonotonicCheckpoint(
			localState.race.lap,
			localState.race.nextCheckpoint,
			activeTrack.checkpoints
		),
		localProgress.lapDistance,
		localState.heldPowerup,
		localState.heldPowerupCount,
		nitroGateOpen,
		tel.plungerFaceTicks,
		standingsEntries,
		remoteMinimapPoses,
		localKartId,
		{
			racePhase = localState.race.phase,
			raceTick = localState.race.raceTick,
			raceElapsedSec = RaceState.getRaceElapsedSec(localState.race.raceTick),
			totalLaps = localTotalLaps,
			nextCheckpoint = localState.race.nextCheckpoint,
			raceFinished = localState.race.raceFinished,
			finishTimeSec = finishTimeSec,
			startupBoostMps = localState.race.startupBoostMps,
			startupBoostFired = localState.race.startupBoostFired,
			startupPenaltyTicks = localState.race.startupPenaltyTicks,
		},
		profile.kartId,
		localState.race.bestLapTicks
	)

	-- STK CameraNormal speed-proportional pull-back + skid_angle/2 offset + constant 80 deg vertical FOV
	-- + CM_REVERSE look-back (B / PA_LOOK_BACK); derived strictly from physical renderPose
	-- (src/graphics/camera/camera_normal.cpp:L98-L146, L224-L241, L344-L349, camera.cpp:L139-L141, L200-L204)
	local camera = Workspace.CurrentCamera
	local cameraDirFlat = Vector3.new(renderPose.LookVector.X, 0, renderPose.LookVector.Z)
	if camera then
		debug.profilebegin("OpenKart_Camera")
		camera.CameraType = Enum.CameraType.Scriptable
		camera.FieldOfView = camCfg.fovDeg

		local camPresetScale = SettingsSchema.getCameraPresetScale(activeCameraPreset)
		local ratio = math.max(tel.speedMps / profile.maxSpeed, camCfg.minRatio)
		local wantedBack = math.max(
			(camCfg.distanceBase + camCfg.distanceSpeedFactor * ratio) * math.sqrt(camCfg.smoothPosition),
			camCfg.minDistance
		) * camPresetScale.distanceScale
		local wantedUp = (camCfg.heightBase + ratio / camCfg.heightSpeedDivisor) + camPresetScale.heightOffset

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
		local targetYaw: number
		if flatLook.Magnitude > 1e-4 then
			targetYaw = math.atan2(-flatLook.X, -flatLook.Z)
		else
			targetYaw = smoothedCamYaw or 0.0
		end
		if smoothedCamYaw == nil then
			smoothedCamYaw = targetYaw
		else
			local dYaw = ((targetYaw - (smoothedCamYaw :: number) + math.pi) % (2.0 * math.pi)) - math.pi
			smoothedCamYaw = (smoothedCamYaw :: number) + dYaw * rotLerp
		end
		if smoothedCamY == nil then
			smoothedCamY = renderPose.Position.Y
		else
			smoothedCamY = (smoothedCamY :: number) + (renderPose.Position.Y - (smoothedCamY :: number)) * posLerp
		end

		local targetYawCf = CFrame.fromOrientation(0, targetYaw, 0)
		local yawOnly = CFrame.fromOrientation(0, smoothedCamYaw :: number, 0)

		if lookBack then
			-- CM_REVERSE snaps immediately (smoothing = false, camera_normal.cpp:L226-L230)
			-- while background normal state keeps advancing above (L344-L349).
			local backDistStuds = Units.metersToStuds(camCfg.backwardDistance)
			local aboveStuds = Units.metersToStuds(camCfg.backwardAboveKart)
			local upTanStuds = backDistStuds * math.tan(math.rad(camCfg.backwardUpAngleDeg))
			local reversePos = renderPose.Position
				+ targetYawCf.LookVector * backDistStuds
				+ Vector3.new(0, aboveStuds + upTanStuds, 0)
			local reverseTarget = renderPose.Position + Vector3.new(0, aboveStuds, 0)
			camera.CFrame = CFrame.lookAt(reversePos, reverseTarget)
		else
			if wasLookingBack then
				-- CM_REVERSE -> CM_NORMAL snaps behind kart cleanly instead of sweeping through chassis (camera.cpp:L200-L204)
				smoothedCamYaw = targetYaw
				smoothedCamY = renderPose.Position.Y
				yawOnly = targetYawCf
				camOffsetX = 0.0
				camOffsetY = camCfg.reverseReturnUp
				camOffsetZ = -camCfg.reverseReturnBack
			end
			local camBaseY = math.max(smoothedCamY :: number, renderPose.Position.Y - 0.15)
			local lookLeadY = renderPose.LookVector.Y * Units.metersToStuds(2.0)
			local p2Visual = if sessionState.config.playMode == "LOCAL_2P" then remoteKartVisuals["local_p2"] else nil
			if p2Visual ~= nil and p2Visual.model.PrimaryPart ~= nil then
				local p1Pos = renderPose.Position
				local p2Pos = p2Visual.model.PrimaryPart.Position
				local midpoint = (p1Pos + p2Pos) * 0.5
				local sep = (p1Pos - p2Pos).Magnitude
				local extraPull = math.clamp(sep * 0.75, 0, 32)
				local camPos = Vector3.new(midpoint.X, camBaseY, midpoint.Z)
					+ yawOnly.RightVector * Units.metersToStuds(camOffsetX)
					+ Vector3.new(0, Units.metersToStuds(camOffsetY) + extraPull * 0.35, 0)
					+ yawOnly.LookVector * (Units.metersToStuds(camOffsetZ) - extraPull)
				local lookTarget = midpoint + Vector3.new(0, Units.metersToStuds(camCfg.lookTargetY) + lookLeadY, 0)
				camera.CFrame = CFrame.lookAt(camPos, lookTarget)
			else
				local camPos = Vector3.new(renderPose.Position.X, camBaseY, renderPose.Position.Z)
					+ yawOnly.RightVector * Units.metersToStuds(camOffsetX)
					+ Vector3.new(0, Units.metersToStuds(camOffsetY), 0)
					+ yawOnly.LookVector * Units.metersToStuds(camOffsetZ)
				if camPos.Y < renderPose.Position.Y + 0.5 then
					camPos = Vector3.new(camPos.X, renderPose.Position.Y + 0.5, camPos.Z)
				end
				local lookTarget = renderPose.Position
					+ Vector3.new(0, Units.metersToStuds(camCfg.lookTargetY) + lookLeadY, 0)
				camera.CFrame = CFrame.lookAt(camPos, lookTarget)
			end
		end
		cameraDirFlat = Vector3.new(camera.CFrame.LookVector.X, 0, camera.CFrame.LookVector.Z)
		localPlayer:SetAttribute("DebugCamPitchDeg", math.deg(math.asin(math.clamp(camera.CFrame.LookVector.Y, -1, 1))))
		localPlayer:SetAttribute("DebugCamPosY", camera.CFrame.Position.Y)
		localPlayer:SetAttribute("DebugKartPosY", renderPose.Position.Y)
		wasLookingBack = lookBack
		debug.profileend()
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

	local powerupName = ItemTuning.POWERUP_NAMES[localState.heldPowerup] or "NONE"
	local statusTags = ""
	if tel.attachmentType ~= ItemTuning.ATTACHMENT_NONE then
		local attName = ItemTuning.ATTACHMENT_NAMES[tel.attachmentType] or "ATTACH"
		statusTags ..= string.format(" [%s %.1fs]", attName, FixedStep.ticksToTime(tel.attachmentTicksLeft))
	end
	if tel.inputSuppressed then
		statusTags ..= string.format(" [EXPLODE %.1fs]", FixedStep.ticksToTime(tel.effectTicksRemaining))
	elseif tel.bubblegumTicks > 0 then
		statusTags ..= string.format(" [BUBBLE %.1fs]", FixedStep.ticksToTime(tel.bubblegumTicks))
	elseif tel.isSquashed then
		statusTags ..= string.format(" [SQUASH %.1fs]", FixedStep.ticksToTime(tel.effectTicksRemaining))
	end
	if tel.invulnerableTicks > 0 and not tel.inputSuppressed then
		statusTags ..= string.format(" [INVULN %.1fs]", FixedStep.ticksToTime(tel.invulnerableTicks))
	end
	if localItemWorld.switchTicks >= 0 then
		statusTags ..= string.format(" [SWITCH %.1fs]", FixedStep.ticksToTime(localItemWorld.switchTicks))
	end
	if tel.plungerFaceTicks > 0 then
		statusTags ..= string.format(" [PLUNGER_FACE %.1fs]", FixedStep.ticksToTime(tel.plungerFaceTicks))
	end
	if localState.heldPowerupCount > 0 then
		hud.item.Text = string.format("ITEM:  %s x%d%s", powerupName, localState.heldPowerupCount, statusTags)
		hud.item.TextColor3 = Color3.fromRGB(255, 225, 115)
	else
		hud.item.Text = string.format("ITEM:  NONE%s", statusTags)
		hud.item.TextColor3 = if statusTags ~= "" then Color3.fromRGB(255, 145, 220) else Color3.fromRGB(150, 158, 172)
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
