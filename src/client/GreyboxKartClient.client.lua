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
local FixedStep = require(Shared.sim.FixedStep)
local Flyable = require(Shared.sim.Flyable)
local FlyablePresentation = require("./items/FlyablePresentation")
local GreyboxArenaData = require(Shared.track.GreyboxArenaData)
local GreyboxProtocol = require(Shared.net.GreyboxProtocol)
local HudState = require("./HudState")
local InputMapper = require("./InputMapper")
local ItemPresentation = require("./items/ItemPresentation")
local ItemTuning = require(Shared.ItemTuning)
local ItemWorld = require(Shared.items.ItemWorld)
local KartPresentation = require("./kart/KartPresentation")
local KartSolver = require(Shared.sim.KartSolver)
local KartTuning = require(Shared.KartTuning)
local Math3D = require(Shared.sim.Math3D)
local ReconciliationSmoother = require(Shared.net.ReconciliationSmoother)
local RemoteInterp = require(Shared.net.RemoteInterp)
local RobloxWorldQuery = require(Shared.sim.RobloxWorldQuery)
local SfxEvents = require(Shared.audio.SfxEvents)
local SfxPlayer = require("./SfxPlayer")
local Standings = require(Shared.race.Standings)
local TouchControls = require("./TouchControls")
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
local profile = KartTuning.buildProfile("medium", "best")
local visuals = KartPresentation.create(localPlayer, profile, "tux")

local localKartId = if localPlayer.UserId ~= 0 then localPlayer.UserId else 1
local localItemWorld = ItemWorld.fromArenaSpec(GreyboxArenaData, "NORMAL_RACE")
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
local localState = KartSolver.createState(profile, { x = 0, y = SPAWN_HEIGHT_METERS, z = 0 }, 0)
local localProgress = AIController.createState(GreyboxArenaData.drivelineQuadCenters, localState.pos)
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
local touchControls = TouchControls.create()
local inputMapper = InputMapper.createLive({
	isStudio = IS_STUDIO,
	getTouchState = touchControls.getState,
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
			local numericId = tonumber(rk.id) or -idx
			table.insert(list, { id = numericId, state = rs })
		end
	end
	return list
end

local function buildClientStandingsAndProxies(): ({ Standings.StandingsEntry }, number, { Flyable.KartProxy })
	local nPts = math.max(1, #GreyboxArenaData.drivelineQuadCenters)
	local entries: { Standings.StandingsEntry } = {
		{
			id = "local",
			lap = localProgress.lap,
			checkpoint = localProgress.checkpoint,
			distance = localProgress.lapDistance,
			initialPosition = 2,
		},
	}
	for idx, rk in latestRemoteKarts do
		local rPos = { x = rk.pos[1], y = rk.pos[2], z = rk.pos[3] }
		local rNode, rDist = AIController.computeTrackProgress(rPos, GreyboxArenaData.drivelineQuadCenters)
		local nIdx = rk.trackNodeIdx or rNode
		table.insert(entries, {
			id = rk.id,
			lap = rk.lap or 0,
			checkpoint = math.floor(((nIdx - 1) * 4) / nPts),
			distance = rDist,
			initialPosition = idx,
		})
	end
	local myRank = Standings.getRankForId(entries, "local")
	local proxies: { Flyable.KartProxy } = {
		KartSolver.makeFlyableProxy(localKartId, localState, myRank, "best"),
	}
	for idx, rk in latestRemoteKarts do
		local numericId = tonumber(rk.id) or -idx
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
		localProgress = AIController.createState(GreyboxArenaData.drivelineQuadCenters, localState.pos)
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
				localProgress = AIController.createState(GreyboxArenaData.drivelineQuadCenters, localState.pos)
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
				local replayCount = #inputHistory
				if replayCount > 0 then
					for idx, entry in inputHistory do
						if idx == replayCount then
							prevPose = capturePose(localState)
						end
						local _, myRank, proxies = buildClientStandingsAndProxies()
						KartSolver.stepWithItems(
							localState,
							entry.input,
							worldQuery,
							FixedStep.FIXED_DT,
							localItemWorld,
							{
								isServer = false,
								kartId = localKartId,
								flyableWorld = localFlyableWorld,
								allKartProxies = proxies,
								drivelineCenters = GreyboxArenaData.drivelineQuadCenters,
								rank = myRank,
								difficulty = "best",
							}
						)
						KartSolver.resolveKartKartCollisions(buildClientCollisionParticipants())
						AIController.updateProgress(
							localProgress,
							localState.pos,
							GreyboxArenaData.drivelineQuadCenters
						)
						Flyable.step(
							localFlyableWorld,
							proxies,
							worldQuery,
							FixedStep.FIXED_DT,
							GreyboxArenaData.drivelineQuadCenters,
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
			if localState.pos.y < VOID_RESET_Y_METERS or localState.resetTriggered then
				if localState.resetTriggered then
					resetNoticeText = "RESET (" .. localState.activeMaterialName .. ")"
					resetNoticeExpirySec = os.clock() + 1.5
				end
				localState = KartSolver.createState(profile, { x = 0, y = SPAWN_HEIGHT_METERS, z = 0 }, 0)
				localProgress = AIController.createState(GreyboxArenaData.drivelineQuadCenters, localState.pos)
				table.clear(inputHistory)
				pendingSnapshot = nil
				ReconciliationSmoother.reset(reconciler)
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
						fire = solverInput.fire,
						lookBack = solverInput.lookBack,
					},
				})
				if #inputHistory > MAX_INPUT_HISTORY then
					table.remove(inputHistory, 1)
				end
				local _, myRank, proxies = buildClientStandingsAndProxies()
				KartSolver.stepWithItems(localState, solverInput, worldQuery, fixedDt, localItemWorld, {
					isServer = false,
					kartId = localKartId,
					flyableWorld = localFlyableWorld,
					allKartProxies = proxies,
					drivelineCenters = GreyboxArenaData.drivelineQuadCenters,
					rank = myRank,
					difficulty = "best",
				})
				KartSolver.resolveKartKartCollisions(buildClientCollisionParticipants())
				AIController.updateProgress(localProgress, localState.pos, GreyboxArenaData.drivelineQuadCenters)
				Flyable.step(
					localFlyableWorld,
					proxies,
					worldQuery,
					fixedDt,
					GreyboxArenaData.drivelineQuadCenters,
					localItemWorld.elapsedTicks
				)
				currPose = capturePose(localState)
			end
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
			rv = KartPresentation.create(rk.id, profile, "tux")
			remoteKartVisuals[rk.id] = rv
		end
		local ibuf = remoteInterpBuffers[rk.id]
		local sampled = if ibuf then RemoteInterp.sample(ibuf, remoteRenderTime) else nil
		local rPos = if sampled then sampled.pos else { x = rk.pos[1], y = rk.pos[2], z = rk.pos[3] }
		local rRot = if sampled then sampled.rot else { w = rk.rot[1], x = rk.rot[2], y = rk.rot[3], z = rk.rot[4] }
		local rSpeed = if sampled then sampled.speed else rk.speed
		local rSteer = if sampled then sampled.steer else rk.steer
		local rCf = RobloxWorldQuery.stkPoseToRobloxCFrame(rPos, rRot, 0, 0)
		KartPresentation.update(
			rv,
			rCf,
			rSpeed,
			dt,
			rSteer,
			defaultSusp,
			0,
			"SKID_NONE",
			false,
			rk.attachmentType,
			rk.isSquashed,
			rk.plungerFaceTicks
		)
		local numericId = tonumber(rk.id) or -idx
		kartPositionsById[numericId] =
			Vector3.new(Units.metersToStuds(rPos.x), Units.metersToStuds(rPos.y), Units.metersToStuds(-rPos.z))
		table.insert(remoteMinimapPoses, { id = rk.id, x = rPos.x, z = rPos.z })

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
			skidState = "SKID_NONE",
			nitroActive = false,
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
		tel.plungerFaceTicks
	)
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
	}, dt, true)
	SfxPlayer.applyStep(sfxPlayer, "local", localAudioStep, visuals.model.PrimaryPart or visuals.sparkLeft)
	debug.profileend()

	local attrStart = Workspace:GetAttribute("OpenKartRaceStartTime")
	local raceStartServerTime = if type(attrStart) == "number" then attrStart else Workspace:GetServerTimeNow()
	local nitroGateOpen = (solverInput.accel > 0 and localState.isOnGround) or tel.nitroActive
	local standingsEntries, _, _ = buildClientStandingsAndProxies()
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
		0,
		0,
		math.max(0.0, finalPos.z),
		localState.heldPowerup,
		localState.heldPowerupCount,
		nitroGateOpen,
		tel.plungerFaceTicks,
		standingsEntries,
		remoteMinimapPoses,
		localKartId
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
