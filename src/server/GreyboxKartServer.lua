--!strict
-- src/server/GreyboxKartServer.lua
-- SPDX-License-Identifier: GPL-3.0-or-later
-- Server-authoritative 120 Hz KartSolver simulation broadcasting 30 Hz state snapshots over
-- UnreliableRemoteEvent (no replicated anchored visual parts; client renders & predicts locally).

local AssetService = game:GetService("AssetService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local AIController = require(Shared.ai.AIController)
local CheckManager = require(Shared.race.CheckManager)
local FixedStep = require(Shared.sim.FixedStep)
local Flyable = require(Shared.sim.Flyable)
local GreyboxArenaData = require(Shared.track.GreyboxArenaData)
local GreyboxProtocol = require(Shared.net.GreyboxProtocol)
local ItemTuning = require(Shared.ItemTuning)
local ItemWorld = require(Shared.items.ItemWorld)
local KartAssetHydrator = require("./KartAssetHydrator")
local KartSolver = require(Shared.sim.KartSolver)
local KartTuning = require(Shared.KartTuning)
local LobbyState = require(Shared.net.LobbyState)
local Math3D = require(Shared.sim.Math3D)
local MenuFlow = require(Shared.menu.MenuFlow)
local PowerupManager = require(Shared.items.PowerupManager)
local RaceState = require(Shared.sim.RaceState)
local ReservedLobbyService = require("./ReservedLobbyService")
local RobloxWorldQuery = require(Shared.sim.RobloxWorldQuery)
local SandtrackCollisionData = require(Shared.track.SandtrackCollisionData)
local SandtrackRoadProbeData = require(Shared.track.SandtrackRoadProbeData)
local SettingsStore = require("./SettingsStore")
local Standings = require(Shared.race.Standings)
local TestDummyKart = require(Shared.race.TestDummyKart)
local TrackRegistry = require(Shared.track.TrackRegistry)

type PlayerKartEntry = {
	player: Player,
	state: KartSolver.KartState,
	progress: AIController.AIState,
	input: KartSolver.KartInput,
	lastInputSeq: number,
	resetSeq: number,
	resetRequested: boolean,
	forceSnapshot: boolean,
	resetNoticeText: string,
	resetNoticeExpirySec: number,
	lastDiagLogSec: number,
	lastLoggedSweepCount: number,
}

local DEBUG_ALLOW_NITRO_GRANT = RunService:IsStudio()

local SNAPSHOT_INTERVAL_SEC = 1 / GreyboxProtocol.SNAPSHOT_RATE_HZ

local RBX_MATERIALS: { [string]: Enum.Material } = {
	Concrete = Enum.Material.Concrete,
	Sand = Enum.Material.Sand,
	Slate = Enum.Material.Slate,
	Glass = Enum.Material.Glass,
	Sandstone = Enum.Material.Sandstone,
	Neon = Enum.Material.Neon,
}

local GreyboxKartServer = {}

local function addLabel(parent: BasePart, text: string, yOffsetStuds: number, color: Color3?)
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "PatchLabel"
	billboard.Size = UDim2.fromOffset(220, 32)
	billboard.StudsOffset = Vector3.new(0, yOffsetStuds, 0)
	billboard.AlwaysOnTop = false
	billboard.MaxDistance = 120
	billboard.Parent = parent

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundColor3 = Color3.fromRGB(14, 16, 22)
	label.BackgroundTransparency = 0.25
	label.BorderSizePixel = 0
	label.Font = Enum.Font.Code
	label.TextSize = 14
	label.TextColor3 = color or Color3.fromRGB(240, 244, 250)
	label.Text = text
	label.Parent = billboard
end

local function makeSurfacePart(
	parent: Instance,
	name: string,
	size: Vector3,
	cf: CFrame,
	color: Color3,
	material: Enum.Material,
	surfaceMaterialName: string,
	canCollide: boolean?,
	transparency: number?
): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	local collide = if canCollide ~= nil then canCollide else true
	part.CanCollide = collide
	part.CanTouch = false
	part.CanQuery = collide
	part.Size = size
	part.CFrame = cf
	part.Color = color
	part.Material = material
	part.Transparency = transparency or 0
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part:SetAttribute("SurfaceMaterial", surfaceMaterialName)
	part.Parent = parent
	return part
end

local function buildThinRoadMeshProbe(parent: Instance): MeshPart?
	local ok, result = pcall(function(): MeshPart
		local em = AssetService:CreateEditableMesh()
		local vIds: { number } = table.create(#SandtrackRoadProbeData.vertices)
		for i, v in SandtrackRoadProbeData.vertices do
			vIds[i] = em:AddVertex(Vector3.new(v[1], v[2], v[3]))
		end
		for _, tri in SandtrackRoadProbeData.triangles do
			em:AddTriangle(vIds[tri[1]], vIds[tri[2]], vIds[tri[3]])
		end
		return AssetService:CreateMeshPartAsync(Content.fromObject(em), {
			CollisionFidelity = Enum.CollisionFidelity.PreciseConvexDecomposition,
			RenderFidelity = Enum.RenderFidelity.Precise,
		})
	end)

	if not ok then
		warn("[OpenKart] SandtrackRoadProbe CreateMeshPartAsync failed: " .. tostring(result))
		return nil
	end

	local meshPart = result
	meshPart.Name = "SandtrackRoadProbe"
	meshPart.Anchored = true
	meshPart.CanCollide = true
	meshPart.CanTouch = false
	meshPart.CanQuery = true
	meshPart.DoubleSided = true
	meshPart.Color = Color3.fromRGB(70, 75, 84)
	meshPart.Material = Enum.Material.Asphalt
	-- CreateMeshPartAsync preserves local vertex origin (min_y = 0), so place cleanly at ground Y = 0.05
	meshPart.CFrame = CFrame.new(-18, 0.05, -36)
	meshPart:SetAttribute("SurfaceMaterial", SandtrackRoadProbeData.sourceMaterial)
	meshPart:SetAttribute("ProbeTriangles", #SandtrackRoadProbeData.triangles)
	meshPart:SetAttribute("SourceTrack", SandtrackRoadProbeData.sourceTrack)
	meshPart.Parent = parent
	addLabel(meshPart, "SANDTRACK ROAD PROBE (64 tris)", 3.0, Color3.fromRGB(165, 225, 255))
	return meshPart
end

local function createGreyboxArena(): (Folder, BasePart)
	local existingArena = Workspace:FindFirstChild(GreyboxProtocol.ARENA_NAME)
	if existingArena and existingArena:IsA("Model") then
		local existingSurfaces = existingArena:FindFirstChild("Surfaces")
		if existingSurfaces and existingSurfaces:IsA("Folder") and existingArena.PrimaryPart then
			return existingSurfaces, existingArena.PrimaryPart
		end
	end

	local arena = Instance.new("Model")
	arena.Name = GreyboxProtocol.ARENA_NAME
	arena.ModelStreamingMode = Enum.ModelStreamingMode.Persistent

	local surfaces = Instance.new("Folder")
	surfaces.Name = "Surfaces"
	surfaces.Parent = arena

	local primaryRoad: BasePart? = nil
	for _, box in GreyboxArenaData.boxes do
		local cf = CFrame.new(box.pos[1], box.pos[2], box.pos[3])
			* CFrame.Angles(math.rad(box.rotDeg[1]), math.rad(box.rotDeg[2]), math.rad(box.rotDeg[3]))
		local part = makeSurfacePart(
			surfaces,
			box.name,
			Vector3.new(box.size[1], box.size[2], box.size[3]),
			cf,
			Color3.fromRGB(box.colorRgb[1], box.colorRgb[2], box.colorRgb[3]),
			RBX_MATERIALS[box.rbxMaterial] or Enum.Material.Concrete,
			box.material,
			box.canCollide,
			box.transparency
		)
		if box.isPrimary then
			primaryRoad = part
		end
		if box.label and box.labelY and box.labelColorRgb then
			addLabel(
				part,
				box.label,
				box.labelY,
				Color3.fromRGB(box.labelColorRgb[1], box.labelColorRgb[2], box.labelColorRgb[3])
			)
		end
	end
	assert(primaryRoad ~= nil, "GreyboxArenaData missing isPrimary box")
	local primaryPart: BasePart = primaryRoad

	-- Real sandtrack road.jpg thin-mesh collision probe (64 tris)
	buildThinRoadMeshProbe(surfaces)

	-- Flush non-collidable, non-queryable visual grid lines
	local planeSize = GreyboxArenaData.planeSizeStuds
	local half = planeSize * 0.5
	local gridSpacing = GreyboxArenaData.gridSpacingStuds

	local gridFolder = Instance.new("Folder")
	gridFolder.Name = "GridLines"
	gridFolder.Parent = arena

	for offset = -half, half, gridSpacing do
		local isCenter = (offset == 0)
		local thickness = if isCenter then 0.35 else 0.12
		local color = if isCenter then Color3.fromRGB(220, 185, 70) else Color3.fromRGB(98, 102, 110)

		local lineX = Instance.new("Part")
		lineX.Name = "GridX_" .. tostring(offset)
		lineX.Anchored = true
		lineX.CanCollide = false
		lineX.CanTouch = false
		lineX.CanQuery = false
		lineX.Material = Enum.Material.SmoothPlastic
		lineX.Color = color
		lineX.Size = Vector3.new(planeSize, 0.02, thickness)
		lineX.CFrame = CFrame.new(0, 0.005, offset)
		lineX.Parent = gridFolder

		local lineZ = Instance.new("Part")
		lineZ.Name = "GridZ_" .. tostring(offset)
		lineZ.Anchored = true
		lineZ.CanCollide = false
		lineZ.CanTouch = false
		lineZ.CanQuery = false
		lineZ.Material = Enum.Material.SmoothPlastic
		lineZ.Color = color
		lineZ.Size = Vector3.new(thickness, 0.02, planeSize)
		lineZ.CFrame = CFrame.new(offset, 0.005, 0)
		lineZ.Parent = gridFolder
	end

	arena.PrimaryPart = primaryPart
	arena.Parent = Workspace
	return surfaces, primaryPart
end

local function sanitizeInput(raw: any): (KartSolver.KartInput, number, boolean, boolean)
	if type(raw) ~= "table" then
		return { accel = 0, brake = false, steer = 0, drift = false, nitro = false, fire = false, lookBack = false },
			0,
			false,
			false
	end
	local seq = if type(raw.seq) == "number" and raw.seq == raw.seq then math.floor(raw.seq) else 0
	local accel = if type(raw.accel) == "number" and raw.accel == raw.accel then math.clamp(raw.accel, 0, 1) else 0
	local steer = if type(raw.steer) == "number" and raw.steer == raw.steer then math.clamp(raw.steer, -1, 1) else 0
	local brake = raw.brake == true
	local drift = raw.drift == true
	local nitro = raw.nitro == true
	local fire = raw.fire == true
	local lookBack = raw.lookBack == true
	local reset = raw.reset == true
	local grantNitro = raw.debugGrantNitro == true
	return {
		accel = accel,
		brake = brake,
		steer = steer,
		drift = drift,
		nitro = nitro,
		fire = fire,
		lookBack = lookBack,
	},
		seq,
		reset,
		grantNitro
end

local function fireSnapshotPacket(
	telemetryRemote: UnreliableRemoteEvent,
	entry: PlayerKartEntry,
	currentTick: number,
	now: number,
	itemWorld: ItemWorld.ItemWorldState,
	flyableWorld: Flyable.FlyableWorldState,
	remoteKarts: { GreyboxProtocol.RemoteKartState }
)
	local notice = if now < entry.resetNoticeExpirySec then entry.resetNoticeText else ""
	local payload, noticeArg = GreyboxProtocol.packSnapshot(
		currentTick,
		entry.lastInputSeq,
		entry.resetSeq,
		KartSolver.captureNetState(entry.state, itemWorld, flyableWorld),
		notice,
		remoteKarts,
		Workspace:GetServerTimeNow()
	)
	telemetryRemote:FireClient(entry.player, payload, noticeArg)
end

local function buildChunkMeshPart(chunk: SandtrackCollisionData.CollisionChunk): (boolean, MeshPart | string)
	local function tryCreate(extrudeBackface: boolean, fidelity: Enum.CollisionFidelity): (boolean, any)
		return pcall(function(): MeshPart
			local em = AssetService:CreateEditableMesh()
			local vIds: { number } = table.create(#chunk.verts // 3)
			for i = 1, #chunk.verts, 3 do
				table.insert(vIds, em:AddVertex(Vector3.new(chunk.verts[i], chunk.verts[i + 1], chunk.verts[i + 2])))
			end
			for i = 1, #chunk.tris, 3 do
				em:AddTriangle(vIds[chunk.tris[i]], vIds[chunk.tris[i + 1]], vIds[chunk.tris[i + 2]])
			end
			if extrudeBackface then
				local backIds: { number } = table.create(#vIds)
				for i = 1, #chunk.verts, 3 do
					table.insert(
						backIds,
						em:AddVertex(Vector3.new(chunk.verts[i], chunk.verts[i + 1] - 0.05, chunk.verts[i + 2]))
					)
				end
				for i = 1, #chunk.tris, 3 do
					em:AddTriangle(backIds[chunk.tris[i + 2]], backIds[chunk.tris[i + 1]], backIds[chunk.tris[i]])
				end
			end
			return AssetService:CreateMeshPartAsync(Content.fromObject(em), {
				CollisionFidelity = fidelity,
				RenderFidelity = Enum.RenderFidelity.Automatic,
			})
		end)
	end
	local ok, res = tryCreate(false, Enum.CollisionFidelity.PreciseConvexDecomposition)
	if not ok then
		ok, res = tryCreate(true, Enum.CollisionFidelity.PreciseConvexDecomposition)
	end
	if not ok then
		ok, res = tryCreate(true, Enum.CollisionFidelity.Hull)
	end
	return ok, res
end

local function loadTrackGeometry(trackId: string): (Folder, BasePart)
	local prevLegacy = Workspace:FindFirstChild("Tracks")
	if prevLegacy then
		prevLegacy:Destroy()
	end
	local prevArena = Workspace:FindFirstChild(GreyboxProtocol.ARENA_NAME)
	if prevArena then
		prevArena:Destroy()
	end
	local prevActive = Workspace:FindFirstChild(TrackRegistry.ACTIVE_TRACK_MODEL_NAME)
	if prevActive then
		prevActive:Destroy()
	end

	if trackId == "openkart_arena" then
		return createGreyboxArena()
	end

	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local tracksFolder = if assets then assets:FindFirstChild("Tracks") else nil
	local template = if tracksFolder then tracksFolder:FindFirstChild(trackId) else nil
	if template and template:IsA("Model") then
		local cloned = template:Clone()
		cloned.Name = TrackRegistry.ACTIVE_TRACK_MODEL_NAME
		cloned.ModelStreamingMode = Enum.ModelStreamingMode.Persistent
		local surfaces = cloned:FindFirstChild("Surfaces")
		local primary: BasePart? = cloned.PrimaryPart or cloned:FindFirstChildWhichIsA("BasePart", true)
		if surfaces and surfaces:IsA("Folder") and primary then
			if trackId == "sandtrack" then
				local total = #SandtrackCollisionData
				local remaining = total
				local failedCount = 0
				local doneEvent = Instance.new("BindableEvent")
				local batchLimit = 16
				local nextIdx = 1
				local function spawnNext()
					while nextIdx <= total do
						local idx = nextIdx
						nextIdx += 1
						local chunk = SandtrackCollisionData[idx]
						local ok, partOrErr = buildChunkMeshPart(chunk)
						if ok then
							local mp = partOrErr :: MeshPart
							mp.Name = string.format("ColChunk_%03d_%s", idx, chunk.materialStem)
							mp.Anchored = true
							mp.CanCollide = true
							mp.CanTouch = false
							mp.CanQuery = true
							mp.DoubleSided = true
							mp.Transparency = 1
							mp.CFrame = CFrame.new(chunk.center[1], chunk.center[2], chunk.center[3])
							mp:SetAttribute("SurfaceMaterial", chunk.material)
							mp.Parent = surfaces
						else
							failedCount += 1
							warn(
								string.format(
									"[OpenKart] ColChunk_%03d_%s failed: %s",
									idx,
									chunk.materialStem,
									tostring(partOrErr)
								)
							)
						end
						remaining -= 1
						if remaining == 0 then
							doneEvent:Fire()
						end
					end
				end
				for _ = 1, math.min(batchLimit, total) do
					task.spawn(spawnNext)
				end
				if remaining > 0 then
					doneEvent.Event:Wait()
				end
				doneEvent:Destroy()
				assert(
					failedCount == 0,
					string.format("[OpenKart] %d sandtrack collision chunks failed to build", failedCount)
				)
			end
			for _, desc in cloned:GetDescendants() do
				if desc:IsA("BasePart") then
					if desc:IsDescendantOf(surfaces) then
						assert(
							desc.CanCollide == desc.CanQuery,
							string.format(
								"[OpenKart] Surfaces part '%s' flag mismatch: CanCollide=%s CanQuery=%s",
								desc.Name,
								tostring(desc.CanCollide),
								tostring(desc.CanQuery)
							)
						)
					else
						desc.CanCollide = false
						desc.CanQuery = false
					end
				end
			end
			cloned.PrimaryPart = primary
			cloned.Parent = Workspace
			return surfaces, primary
		end
		cloned:Destroy()
	end

	warn(string.format("[OpenKart] Track template '%s' missing; falling back to openkart_arena", trackId))
	return createGreyboxArena()
end

function GreyboxKartServer.start()
	Players.CharacterAutoLoads = false
	KartAssetHydrator.hydrateAll()

	local activeTrack = TrackRegistry.get(TrackRegistry.DEFAULT_TRACK_ID)
	local surfacesFolder, arenaPrimaryPart = loadTrackGeometry(activeTrack.trackId)
	Workspace:SetAttribute("OpenKartActiveTrack", activeTrack.trackId)
	Workspace:SetAttribute("OpenKartRaceStartTime", Workspace:GetServerTimeNow())
	local worldQuery = RobloxWorldQuery.create(surfacesFolder)

	local remotesFolder = Instance.new("Folder")
	remotesFolder.Name = GreyboxProtocol.REMOTES_FOLDER
	remotesFolder.Parent = ReplicatedStorage

	local inputRemote = Instance.new("RemoteEvent")
	inputRemote.Name = GreyboxProtocol.INPUT_REMOTE
	inputRemote.Parent = remotesFolder

	local telemetryRemote = Instance.new("UnreliableRemoteEvent")
	telemetryRemote.Name = GreyboxProtocol.TELEMETRY_REMOTE
	telemetryRemote.Parent = remotesFolder

	SettingsStore.bindRemotes(remotesFolder)

	local sessionCommandRemote = Instance.new("RemoteEvent")
	sessionCommandRemote.Name = "SessionCommand"
	sessionCommandRemote.Parent = remotesFolder

	local sessionStateRemote = Instance.new("RemoteEvent")
	sessionStateRemote.Name = "SessionState"
	sessionStateRemote.Parent = remotesFolder

	local localP2InputRemote = Instance.new("RemoteEvent")
	localP2InputRemote.Name = "LocalP2Input"
	localP2InputRemote.Parent = remotesFolder

	local lobbyCommandRemote = Instance.new("RemoteEvent")
	lobbyCommandRemote.Name = "LobbyCommand"
	lobbyCommandRemote.Parent = remotesFolder

	local lobbyStateRemote = Instance.new("RemoteEvent")
	lobbyStateRemote.Name = "LobbyState"
	lobbyStateRemote.Parent = remotesFolder

	local DIFFICULTY_INDEX: { [string]: number } = {
		novice = 0,
		intermediate = 1,
		expert = 2,
		best = 3,
	}

	local sessionPhase: "MENU" | "LOBBY" | "RACING" = "MENU"
	local inLobbySession = false
	local lobbyFinishReturnAt: number? = nil
	local lobby = LobbyState.create({
		serverName = "OpenKart Lobby",
		trackId = activeTrack.trackId,
		laps = 5,
		difficulty = "intermediate",
		raceType = "NORMAL_RACE",
		maxPlayers = 8,
		aiCount = 3,
	})
	local sessionConfig: MenuFlow.SessionConfig = MenuFlow.sanitizeSessionConfig(nil)
	local profile = KartTuning.buildProfile("medium", sessionConfig.difficulty)
	local raceClock = RaceState.create(sessionConfig.laps)
	local function initRaceProgress(
		state: KartSolver.KartState,
		spawnPos: { x: number, y: number, z: number },
		yaw: number
	)
		local p = CheckManager.initKartProgress(activeTrack.checkpoints, spawnPos, yaw)
		state.race.raceTick = raceClock.raceTick
		state.race.phase = raceClock.phase
		state.race.lap = p.lap
		state.race.nextCheckpoint = p.nextCheckpoint
		state.race.raceFinished = p.raceFinished
		state.race.finishTick = p.finishTick
	end

	local itemWorld = ItemWorld.fromArenaSpec(activeTrack :: any, sessionConfig.raceType)
	local flyableWorld = Flyable.createWorld()
	local dummyEnabled = true
	local dummyState =
		TestDummyKart.create(profile, nil, activeTrack.dummyStartPos, activeTrack.dummyStartYawRad, 10007)
	initRaceProgress(dummyState, activeTrack.dummyStartPos, activeTrack.dummyStartYawRad)
	local dummyAI = TestDummyKart.createAIState(
		dummyState,
		activeTrack.drivelineQuadCenters,
		activeTrack.drivelineBranches,
		sessionConfig.difficulty
	)
	local extraAIs: { { id: number, sid: string, state: KartSolver.KartState, ai: AIController.AIState } } = {}
	local localP2State: KartSolver.KartState? = nil
	local localP2AI: AIController.AIState? = nil
	local localP2Owner: Player? = nil
	local localP2Input: KartSolver.KartInput = {
		accel = 0,
		brake = false,
		steer = 0,
		drift = false,
		nitro = false,
		fire = false,
		lookBack = false,
	}
	local LOCAL_P2_KART_ID = -2
	local LOCAL_P2_STRING_ID = "local_p2"
	local powerupMgr = PowerupManager.new(
		sessionConfig.raceType,
		DIFFICULTY_INDEX[sessionConfig.difficulty] or 1,
		ItemTuning.IMPLEMENTED_POWERUPS
	)
	local rollCounter = 0
	local entries: { [Player]: PlayerKartEntry } = {}
	local totalDroppedDebt = 0.0
	local snapshotAccum = 0.0

	local function gridOffsetPos(
		basePos: { x: number, y: number, z: number },
		yawRad: number,
		lateralOffset: number,
		backOffset: number
	): { x: number, y: number, z: number }
		local fwdX = math.sin(yawRad)
		local fwdZ = math.cos(yawRad)
		local rightX = math.cos(yawRad)
		local rightZ = -math.sin(yawRad)
		return {
			x = basePos.x + rightX * lateralOffset - fwdX * backOffset,
			y = basePos.y,
			z = basePos.z + rightZ * lateralOffset - fwdZ * backOffset,
		}
	end

	local function broadcastSessionState(targetPlayer: Player?)
		local payload = {
			phase = sessionPhase,
			config = sessionConfig,
			localP2Active = localP2State ~= nil,
		}
		if targetPlayer ~= nil then
			sessionStateRemote:FireClient(targetPlayer, payload)
		else
			sessionStateRemote:FireAllClients(payload)
		end
	end

	local function broadcastLobbyState(targetPlayer: Player?)
		local payload = {
			type = "SNAPSHOT",
			snapshot = LobbyState.getPublicSnapshot(lobby),
		}
		if targetPlayer ~= nil then
			lobbyStateRemote:FireClient(targetPlayer, payload)
		else
			lobbyStateRemote:FireAllClients(payload)
		end
	end

	local function applySessionStart(rawConfig: any, requestingPlayer: Player?, fromLobby: boolean?)
		inLobbySession = (fromLobby == true)
		lobbyFinishReturnAt = nil
		sessionConfig = MenuFlow.sanitizeSessionConfig(rawConfig)
		profile = KartTuning.buildProfile("medium", sessionConfig.difficulty)
		raceClock = RaceState.create(sessionConfig.laps)
		itemWorld = ItemWorld.fromArenaSpec(activeTrack :: any, sessionConfig.raceType)
		flyableWorld = Flyable.createWorld()
		local playerTotal = 0
		for _ in entries do
			playerTotal += 1
		end
		local totalRacers = math.max(
			1,
			playerTotal
				+ (if sessionConfig.raceType == "NORMAL_RACE" then sessionConfig.aiCount else 0)
				+ (if sessionConfig.playMode == "LOCAL_2P" then 1 else 0)
		)
		powerupMgr = PowerupManager.new(
			sessionConfig.raceType,
			totalRacers,
			ItemTuning.IMPLEMENTED_POWERUPS,
			sessionConfig.difficulty
		)
		dummyEnabled = (sessionConfig.raceType == "NORMAL_RACE" and sessionConfig.aiCount >= 1)
		dummyState =
			TestDummyKart.create(profile, nil, activeTrack.dummyStartPos, activeTrack.dummyStartYawRad, 10007 + 7919)
		initRaceProgress(dummyState, activeTrack.dummyStartPos, activeTrack.dummyStartYawRad)
		dummyAI = TestDummyKart.createAIState(
			dummyState,
			activeTrack.drivelineQuadCenters,
			activeTrack.drivelineBranches,
			sessionConfig.difficulty
		)

		extraAIs = {}
		if sessionConfig.raceType == "NORMAL_RACE" and sessionConfig.aiCount >= 2 then
			for i = 2, sessionConfig.aiCount do
				local row = math.floor((i + playerTotal - 1) / 2)
				local side = if ((i + playerTotal) % 2) == 0 then -2.4 else 2.4
				local spawnPos = gridOffsetPos(activeTrack.startPos, activeTrack.startYawRad, side, row * 3.5)
				local seed = 10007 + i * 7919
				local aiState = KartSolver.createState(profile, spawnPos, activeTrack.startYawRad, seed)
				initRaceProgress(aiState, spawnPos, activeTrack.startYawRad)
				table.insert(extraAIs, {
					id = -100 - i,
					sid = "ai_" .. tostring(i),
					state = aiState,
					ai = AIController.createState(
						activeTrack.drivelineQuadCenters,
						aiState.pos,
						seed,
						activeTrack.drivelineBranches :: any,
						sessionConfig.difficulty
					),
				})
			end
		end

		if sessionConfig.playMode == "LOCAL_2P" then
			local p2Pos = gridOffsetPos(activeTrack.startPos, activeTrack.startYawRad, 2.8, 0.0)
			local p2 = KartSolver.createState(profile, p2Pos, activeTrack.startYawRad)
			initRaceProgress(p2, p2Pos, activeTrack.startYawRad)
			localP2State = p2
			localP2AI = AIController.createState(
				activeTrack.drivelineQuadCenters,
				p2.pos,
				nil,
				activeTrack.drivelineBranches :: any,
				sessionConfig.difficulty
			)
			localP2Owner = requestingPlayer
			localP2Input = {
				accel = 0,
				brake = false,
				steer = 0,
				drift = false,
				nitro = false,
				fire = false,
				lookBack = false,
			}
		else
			localP2State = nil
			localP2AI = nil
			localP2Owner = nil
		end

		Workspace:SetAttribute("OpenKartRaceStartTime", Workspace:GetServerTimeNow())
		local slotIdx = 0
		for _, entry in entries do
			slotIdx += 1
			local pRow = math.floor((slotIdx - 1) / 2)
			local pSide = if slotIdx == 1 then 0.0 elseif (slotIdx % 2) == 0 then 2.4 else -2.4
			local pSpawn = if slotIdx == 1
				then activeTrack.startPos
				else gridOffsetPos(activeTrack.startPos, activeTrack.startYawRad, pSide, pRow * 3.5)
			entry.player.ReplicationFocus = arenaPrimaryPart
			entry.state =
				KartSolver.createState(profile, pSpawn, activeTrack.startYawRad, 10007 + math.abs(entry.player.UserId))
			initRaceProgress(entry.state, pSpawn, activeTrack.startYawRad)
			entry.progress = AIController.createState(activeTrack.drivelineQuadCenters, entry.state.pos)
			entry.input = {
				accel = 0,
				brake = false,
				steer = 0,
				drift = false,
				nitro = false,
				fire = false,
				lookBack = false,
			}
			entry.resetSeq += 1
			entry.forceSnapshot = true
		end
		sessionPhase = "RACING"
		broadcastSessionState(nil)
	end

	local function resetFullRace()
		applySessionStart(sessionConfig, localP2Owner, inLobbySession)
	end

	sessionCommandRemote.OnServerEvent:Connect(function(player: Player, cmd: any, payload: any)
		if cmd == "REQUEST_STATE" then
			broadcastSessionState(player)
		elseif cmd == "START_RACE" then
			applySessionStart(payload, player, false)
		elseif cmd == "RETURN_TO_MENU" then
			inLobbySession = false
			lobbyFinishReturnAt = nil
			sessionPhase = "MENU"
			localP2State = nil
			localP2AI = nil
			localP2Owner = nil
			extraAIs = {}
			broadcastSessionState(nil)
		end
	end)

	local function getLobbyUserId(player: Player): number
		return if player.UserId ~= 0 then player.UserId else 1
	end

	local function handleReturnToLobby()
		LobbyState.returnToLobby(lobby)
		sessionPhase = "LOBBY"
		lobbyFinishReturnAt = nil
		localP2State = nil
		localP2AI = nil
		localP2Owner = nil
		extraAIs = {}
		broadcastLobbyState(nil)
		broadcastSessionState(nil)
	end

	lobbyCommandRemote.OnServerEvent:Connect(function(player: Player, cmd: any, payload: any)
		local uid = getLobbyUserId(player)
		if cmd == "REQUEST_LOBBY_STATE" then
			broadcastLobbyState(player)
		elseif cmd == "JOIN_LOBBY" then
			LobbyState.addPlayer(lobby, uid, player.Name)
			if sessionPhase ~= "RACING" then
				sessionPhase = "LOBBY"
			end
			broadcastLobbyState(nil)
			broadcastSessionState(player)
		elseif cmd == "LEAVE_LOBBY" then
			LobbyState.removePlayer(lobby, uid)
			if not inLobbySession and sessionPhase == "LOBBY" then
				sessionPhase = "MENU"
			end
			broadcastLobbyState(nil)
			broadcastSessionState(player)
		elseif cmd == "SUBMIT_PASSWORD" then
			local pw = if type(payload) == "table" then payload.password else payload
			local ok, reason = LobbyState.submitPassword(lobby, uid, pw)
			lobbyStateRemote:FireClient(player, {
				type = "PASSWORD_RESULT",
				ok = ok,
				reason = reason,
			})
			if ok then
				broadcastLobbyState(nil)
			end
		elseif cmd == "UPDATE_SETTINGS" then
			local ok = LobbyState.updateSettings(lobby, uid, payload)
			if ok then
				broadcastLobbyState(nil)
			end
		elseif cmd == "SET_KART" then
			local kartId = if type(payload) == "table" then payload.kartId else payload
			local ok = LobbyState.setPlayerKart(lobby, uid, kartId)
			if ok then
				broadcastLobbyState(nil)
			end
		elseif cmd == "SET_READY" then
			local readyVal = if type(payload) == "table" then payload.ready == true else payload == true
			local ok = LobbyState.setPlayerReady(lobby, uid, readyVal)
			if ok then
				broadcastLobbyState(nil)
			end
		elseif cmd == "START_LOBBY_RACE" then
			local ok, cfg = LobbyState.startRace(lobby, uid)
			if ok and cfg ~= nil then
				broadcastLobbyState(nil)
				applySessionStart(cfg, player, true)
			end
		elseif cmd == "RETURN_TO_LOBBY" then
			if uid == lobby.hostUserId and inLobbySession then
				handleReturnToLobby()
			end
		elseif cmd == "CREATE_RESERVED_SERVER" then
			if uid == lobby.hostUserId then
				local res = ReservedLobbyService.createReservedLobby(player, lobby.settings)
				lobbyStateRemote:FireClient(player, {
					type = "RESERVED_RESULT",
					ok = res.ok,
					reason = res.reason,
					entry = res.entry,
				})
			end
		elseif cmd == "LIST_RESERVED_SERVERS" then
			local res = ReservedLobbyService.listReservedLobbies()
			lobbyStateRemote:FireClient(player, {
				type = "RESERVED_LIST",
				ok = res.ok,
				reason = res.reason,
				entries = res.entries,
			})
		elseif cmd == "JOIN_RESERVED_SERVER" then
			local lid = if type(payload) == "table" then tostring(payload.lobbyId or "") else tostring(payload or "")
			local ok, reason = ReservedLobbyService.teleportToReservedLobby(player, lid)
			lobbyStateRemote:FireClient(player, {
				type = "RESERVED_JOIN_RESULT",
				ok = ok,
				reason = reason,
			})
		end
	end)

	if RunService:IsStudio() then
		local studioLobbyHook = Instance.new("BindableFunction")
		studioLobbyHook.Name = "OpenKartStudioLobbyHook"
		studioLobbyHook.Parent = remotesFolder
		studioLobbyHook.OnInvoke = function(op: string, a: any, b: any): (any, any)
			if op == "getSnapshot" then
				return LobbyState.getPublicSnapshot(lobby), nil
			elseif op == "addGuest" then
				local _, admitted = LobbyState.addPlayer(lobby, tonumber(a) or 202, tostring(b or "Guest"))
				broadcastLobbyState(nil)
				return admitted, nil
			elseif op == "submitGuestPassword" then
				local ok, reason = LobbyState.submitPassword(lobby, tonumber(a) or 202, tostring(b or ""))
				if ok then
					broadcastLobbyState(nil)
				end
				return ok, reason
			elseif op == "setGuestReady" then
				local ok, reason = LobbyState.setPlayerReady(lobby, tonumber(a) or 202, b == true)
				if ok then
					broadcastLobbyState(nil)
				end
				return ok, reason
			elseif op == "removeGuest" then
				LobbyState.removePlayer(lobby, tonumber(a) or 202)
				broadcastLobbyState(nil)
				return true, nil
			end
			return nil, "UNKNOWN_OP"
		end
	end

	localP2InputRemote.OnServerEvent:Connect(function(player: Player, rawPacket: any)
		if sessionPhase ~= "RACING" or localP2State == nil or player ~= localP2Owner then
			return
		end
		local sanitized, _, wantsReset = sanitizeInput(rawPacket)
		localP2Input = sanitized
		if wantsReset and localP2State ~= nil then
			localP2State = KartSolver.createState(profile, activeTrack.startPos, activeTrack.startYawRad)
			initRaceProgress(localP2State :: KartSolver.KartState, activeTrack.startPos, activeTrack.startYawRad)
		end
	end)

	if RunService:IsStudio() then
		local debugItemRemote = Instance.new("RemoteEvent")
		debugItemRemote.Name = "OpenKartDebugGrantItem"
		debugItemRemote.Parent = remotesFolder
		debugItemRemote.OnServerEvent:Connect(function(player: Player, itemType: any, itemCount: any)
			local entry = entries[player]
			if not entry or type(itemType) ~= "number" then
				return
			end
			local clampedType = math.clamp(math.floor(itemType), 0, 10)
			local count = if type(itemCount) == "number" then math.clamp(math.floor(itemCount), 0, 3) else 1
			entry.state.heldPowerup = clampedType
			entry.state.heldPowerupCount = if clampedType == 0 then 0 else math.max(1, count)
		end)

		local restartRaceRemote = Instance.new("RemoteEvent")
		restartRaceRemote.Name = "OpenKartDebugRestartRace"
		restartRaceRemote.Parent = remotesFolder
		restartRaceRemote.OnServerEvent:Connect(function(_player: Player)
			resetFullRace()
		end)

		local switchTrackRemote = Instance.new("RemoteEvent")
		switchTrackRemote.Name = "OpenKartSwitchTrack"
		switchTrackRemote.Parent = remotesFolder
		switchTrackRemote.OnServerEvent:Connect(function(_player: Player, nextTrackId: any)
			if type(nextTrackId) ~= "string" then
				return
			end
			activeTrack = TrackRegistry.get(nextTrackId)
			surfacesFolder, arenaPrimaryPart = loadTrackGeometry(activeTrack.trackId)
			worldQuery = RobloxWorldQuery.create(surfacesFolder)
			Workspace:SetAttribute("OpenKartActiveTrack", activeTrack.trackId)
			resetFullRace()
		end)
	end

	local stepper: FixedStep.Accumulator
	stepper = FixedStep.new({
		onDebtDropped = function(dropped: number)
			totalDroppedDebt += dropped
			warn(string.format("[OpenKart] FixedStep shed %.4fs debt at tick %d", dropped, stepper:getTick()))
		end,
	})

	local function spawnForPlayer(player: Player)
		if entries[player] then
			return
		end
		player.ReplicationFocus = arenaPrimaryPart
		local state = KartSolver.createState(profile, activeTrack.startPos, activeTrack.startYawRad)
		initRaceProgress(state, activeTrack.startPos, activeTrack.startYawRad)

		entries[player] = {
			player = player,
			state = state,
			progress = AIController.createState(activeTrack.drivelineQuadCenters, state.pos),
			input = {
				accel = 0,
				brake = false,
				steer = 0,
				drift = false,
				nitro = false,
				fire = false,
				lookBack = false,
			},
			lastInputSeq = 0,
			resetSeq = 1,
			resetRequested = false,
			forceSnapshot = true,
			resetNoticeText = "",
			resetNoticeExpirySec = 0,
			lastDiagLogSec = 0,
			lastLoggedSweepCount = 0,
		}
	end

	local function removeForPlayer(player: Player)
		entries[player] = nil
		LobbyState.removePlayer(lobby, getLobbyUserId(player))
		broadcastLobbyState(nil)
	end

	Players.PlayerAdded:Connect(spawnForPlayer)
	Players.PlayerRemoving:Connect(removeForPlayer)
	for _, player in Players:GetPlayers() do
		spawnForPlayer(player)
	end

	inputRemote.OnServerEvent:Connect(function(player: Player, rawPacket: any)
		local entry = entries[player]
		if not entry then
			return
		end
		local sanitized, seq, wantsReset, wantsGrantNitro = sanitizeInput(rawPacket)
		entry.input = sanitized
		if seq > entry.lastInputSeq then
			entry.lastInputSeq = seq
		end
		if wantsReset then
			entry.resetRequested = true
		end
		if DEBUG_ALLOW_NITRO_GRANT and wantsGrantNitro then
			KartSolver.addNitro(entry.state, profile.nitro.bigContainer)
			entry.forceSnapshot = true
		end
	end)

	local function computeStandingsAndProxies(): ({ [string]: number }, { Flyable.KartProxy })
		local racers: { TestDummyKart.RacerProgress } = {}
		local idx = 0
		if dummyEnabled then
			idx += 1
			table.insert(racers, {
				id = TestDummyKart.DUMMY_STRING_ID,
				state = dummyState,
				initialPosition = idx,
				aiState = dummyAI,
			})
		end
		for _, extra in extraAIs do
			idx += 1
			table.insert(racers, {
				id = extra.sid,
				state = extra.state,
				initialPosition = idx,
				aiState = extra.ai,
			})
		end
		if localP2State ~= nil and localP2AI ~= nil then
			idx += 1
			table.insert(racers, {
				id = LOCAL_P2_STRING_ID,
				state = localP2State,
				initialPosition = idx,
				aiState = localP2AI,
			})
		end
		for _, entry in entries do
			idx += 1
			local sid = tostring(if entry.player.UserId ~= 0 then entry.player.UserId else idx)
			table.insert(racers, {
				id = sid,
				state = entry.state,
				initialPosition = idx,
				aiState = entry.progress,
			})
		end
		local ranked = Standings.compute(
			TestDummyKart.buildStandingsEntries(racers, activeTrack.drivelineQuadCenters, activeTrack.checkpoints)
		)
		local rankById: { [string]: number } = {}
		for _, r in ranked do
			rankById[r.id] = r.rank
		end
		local proxies: { Flyable.KartProxy } = {}
		if dummyEnabled then
			table.insert(
				proxies,
				KartSolver.makeFlyableProxy(
					TestDummyKart.DUMMY_KART_ID,
					dummyState,
					rankById[TestDummyKart.DUMMY_STRING_ID] or 1,
					sessionConfig.difficulty
				)
			)
		end
		for _, extra in extraAIs do
			table.insert(
				proxies,
				KartSolver.makeFlyableProxy(extra.id, extra.state, rankById[extra.sid] or 1, sessionConfig.difficulty)
			)
		end
		if localP2State ~= nil then
			table.insert(
				proxies,
				KartSolver.makeFlyableProxy(
					LOCAL_P2_KART_ID,
					localP2State,
					rankById[LOCAL_P2_STRING_ID] or 2,
					sessionConfig.difficulty
				)
			)
		end
		local pIdx = 1
		for _, entry in entries do
			pIdx += 1
			local numId = if entry.player.UserId ~= 0 then entry.player.UserId else pIdx
			local sid = tostring(numId)
			table.insert(
				proxies,
				KartSolver.makeFlyableProxy(numId, entry.state, rankById[sid] or 2, sessionConfig.difficulty)
			)
		end
		return rankById, proxies
	end

	RunService.Heartbeat:Connect(function(dt: number)
		if sessionPhase ~= "RACING" then
			return
		end
		debug.profilebegin("OpenKart_ServerSim")
		local _, _ = stepper:advance(dt, function(fixedDt: number)
			local prevPhase = raceClock.phase
			local racePhase: RaceState.RacePhase = RaceState.step(raceClock) :: RaceState.RacePhase
			local raceTick = raceClock.raceTick
			ItemWorld.tick(itemWorld)
			local rankById, preProxies = computeStandingsAndProxies()

			local function buildAIContext(
				aiState: AIController.AIState,
				ks: KartSolver.KartState,
				aiPosIdx: number
			): AIController.AIContext
				local playerDist = 0.0
				for _, e in entries do
					playerDist = aiState.totalDistance - e.progress.totalDistance
					break
				end
				local nearestAheadDist = 999.0
				local nearestBehindDist = 999.0
				local aheadAngleAbs = 3.14
				local behindAngleAbs = 3.14
				local aheadInvuln = false
				local behindInvuln = false
				local aheadHasShield = false
				local invRot = Math3D.quatConjugate(ks.rot)
				local function checkOpp(oppState: KartSolver.KartState, oppDist: number)
					if oppState == ks then
						return
					end
					local lc = Math3D.quatRotateVec(invRot, Math3D.sub(oppState.pos, ks.pos))
					local ang = math.atan2(math.abs(lc.x), math.abs(lc.z))
					local delta = oppDist - aiState.totalDistance
					if delta >= 0.0 and lc.z > 0.0 and delta < nearestAheadDist then
						nearestAheadDist = delta
						aheadAngleAbs = ang
						aheadInvuln = oppState.itemEffect.invulnerableTicks > 0
						aheadHasShield = oppState.attachmentType == ItemTuning.ATTACHMENT_BUBBLEGUM_SHIELD
					elseif delta < 0.0 and lc.z < 0.0 and -delta < nearestBehindDist then
						nearestBehindDist = -delta
						behindAngleAbs = ang
						behindInvuln = oppState.itemEffect.invulnerableTicks > 0
					end
				end
				for _, e in entries do
					checkOpp(e.state, e.progress.totalDistance)
				end
				if localP2State ~= nil and localP2AI ~= nil then
					checkOpp(localP2State, localP2AI.totalDistance)
				end
				if dummyEnabled then
					checkOpp(dummyState, dummyAI.totalDistance)
				end
				for _, ex in extraAIs do
					checkOpp(ex.state, ex.ai.totalDistance)
				end
				return {
					difficulty = sessionConfig.difficulty :: string,
					distToPlayer = playerDist,
					aiPos = aiPosIdx,
					numAi = sessionConfig.aiCount,
					nearestAheadDist = nearestAheadDist,
					nearestBehindDist = nearestBehindDist,
					aheadAngleAbs = aheadAngleAbs,
					behindAngleAbs = behindAngleAbs,
					aheadInvuln = aheadInvuln,
					behindInvuln = behindInvuln,
					aheadHasShield = aheadHasShield,
					itemWorld = itemWorld,
					lapsRemaining = math.max(1, raceClock.totalLaps - math.max(0, ks.race.lap)),
				}
			end

			if dummyEnabled then
				local dummyRank = rankById[TestDummyKart.DUMMY_STRING_ID] or 1
				local rawDummyInput = if dummyState.race.raceFinished
					then AIController.computeCoastInput(
						dummyAI,
						dummyState,
						activeTrack.drivelineQuadCenters,
						fixedDt,
						activeTrack.drivelineBranches :: any
					)
					else TestDummyKart.computeCruiseInput(
						dummyState,
						dummyAI,
						fixedDt,
						nil,
						activeTrack.drivelineQuadCenters,
						buildAIContext(dummyAI, dummyState, 1),
						activeTrack.drivelineBranches
					)
				local dummyInput = KartSolver.stepRaceInput(dummyState, rawDummyInput, raceTick, racePhase)
				KartSolver.stepWithItems(dummyState, dummyInput, worldQuery, fixedDt, itemWorld, {
					isServer = true,
					advanceItemWorld = false,
					kartId = TestDummyKart.DUMMY_KART_ID,
					flyableWorld = flyableWorld,
					allKartProxies = preProxies,
					drivelineCenters = activeTrack.drivelineQuadCenters,
					rank = dummyRank,
					difficulty = sessionConfig.difficulty :: string,
					rollPowerup = function(_s, ev)
						rollCounter += 1
						local seed = math.floor(os.clock() * 1000)
							+ rollCounter * 7919
							+ ev.id * 101
							+ itemWorld.elapsedTicks * 31
						return powerupMgr:getRandomPowerup(dummyRank, seed, itemWorld.elapsedTicks * fixedDt)
					end,
				})
				CheckManager.stepKart(
					dummyState.race,
					activeTrack.checkpoints,
					dummyState.prevPos,
					dummyState.pos,
					raceTick,
					raceClock.totalLaps
				)
			end

			for aiIdx, extra in extraAIs do
				local extraRank = rankById[extra.sid] or 1
				local rawExtraInput = if extra.state.race.raceFinished
					then AIController.computeCoastInput(
						extra.ai,
						extra.state,
						activeTrack.drivelineQuadCenters,
						fixedDt,
						activeTrack.drivelineBranches :: any
					)
					else TestDummyKart.computeCruiseInput(
						extra.state,
						extra.ai,
						fixedDt,
						nil,
						activeTrack.drivelineQuadCenters,
						buildAIContext(extra.ai, extra.state, aiIdx + 1),
						activeTrack.drivelineBranches
					)
				local extraInput = KartSolver.stepRaceInput(extra.state, rawExtraInput, raceTick, racePhase)
				KartSolver.stepWithItems(extra.state, extraInput, worldQuery, fixedDt, itemWorld, {
					isServer = true,
					advanceItemWorld = false,
					kartId = extra.id,
					flyableWorld = flyableWorld,
					allKartProxies = preProxies,
					drivelineCenters = activeTrack.drivelineQuadCenters,
					rank = extraRank,
					difficulty = sessionConfig.difficulty :: string,
					rollPowerup = function(_s, ev)
						rollCounter += 1
						local seed = math.floor(os.clock() * 1000)
							+ rollCounter * 7919
							+ ev.id * 101
							+ itemWorld.elapsedTicks * 31
						return powerupMgr:getRandomPowerup(extraRank, seed, itemWorld.elapsedTicks * fixedDt)
					end,
				})
				CheckManager.stepKart(
					extra.state.race,
					activeTrack.checkpoints,
					extra.state.prevPos,
					extra.state.pos,
					raceTick,
					raceClock.totalLaps
				)
			end

			if localP2State ~= nil and localP2AI ~= nil then
				local p2Raw = if localP2State.race.raceFinished
					then AIController.computeCoastInput(
						localP2AI,
						localP2State,
						activeTrack.drivelineQuadCenters,
						fixedDt
					)
					else localP2Input
				local p2Filtered = KartSolver.stepRaceInput(localP2State, p2Raw, raceTick, racePhase)
				KartSolver.stepWithItems(localP2State, p2Filtered, worldQuery, fixedDt, itemWorld, {
					isServer = true,
					advanceItemWorld = false,
					kartId = LOCAL_P2_KART_ID,
					flyableWorld = flyableWorld,
					allKartProxies = preProxies,
					drivelineCenters = activeTrack.drivelineQuadCenters,
					rank = rankById[LOCAL_P2_STRING_ID] or 2,
					difficulty = sessionConfig.difficulty :: string,
					rollPowerup = function(_s, ev)
						rollCounter += 1
						local seed = math.floor(os.clock() * 1000)
							+ rollCounter * 7919
							+ ev.id * 101
							+ itemWorld.elapsedTicks * 31
						return powerupMgr:getRandomPowerup(
							rankById[LOCAL_P2_STRING_ID] or 2,
							seed,
							itemWorld.elapsedTicks * fixedDt
						)
					end,
				})
				CheckManager.stepKart(
					localP2State.race,
					activeTrack.checkpoints,
					localP2State.prevPos,
					localP2State.pos,
					raceTick,
					raceClock.totalLaps
				)
				AIController.updateProgress(localP2AI, localP2State.pos, activeTrack.drivelineQuadCenters)
			end

			local collisionParticipants: { KartSolver.CollisionParticipant } = {}
			local activeStates: { KartSolver.KartState } = {}
			if dummyEnabled then
				table.insert(collisionParticipants, { id = TestDummyKart.DUMMY_KART_ID, state = dummyState })
				table.insert(activeStates, dummyState)
			end
			for _, extra in extraAIs do
				table.insert(collisionParticipants, { id = extra.id, state = extra.state })
				table.insert(activeStates, extra.state)
			end
			if localP2State ~= nil then
				table.insert(collisionParticipants, { id = LOCAL_P2_KART_ID, state = localP2State })
				table.insert(activeStates, localP2State)
			end
			local playerFallbackIdx = 1
			local playerCount = 0
			local finishedPlayerCount = 0

			for _, entry in entries do
				playerCount += 1
				playerFallbackIdx += 1
				if
					entry.resetRequested
					or entry.state.pos.y < activeTrack.voidResetYMeters
					or entry.state.resetTriggered
				then
					if entry.state.resetTriggered then
						entry.resetNoticeText = "RESET (" .. entry.state.activeMaterialName .. ")"
						entry.resetNoticeExpirySec = os.clock() + 1.5
					end
					local savedRace = entry.state.race
					entry.state = KartSolver.createState(profile, activeTrack.startPos, activeTrack.startYawRad)
					entry.state.race = {
						raceTick = raceTick,
						phase = racePhase,
						lap = savedRace.lap,
						nextCheckpoint = savedRace.nextCheckpoint,
						raceFinished = savedRace.raceFinished,
						finishTick = savedRace.finishTick,
						startupHasPressed = savedRace.startupHasPressed,
						startupBoostMps = if RaceState.isStartPhase(racePhase) then 0.0 else savedRace.startupBoostMps,
						startupPenaltyTicks = savedRace.startupPenaltyTicks,
						startupBoostFired = savedRace.startupBoostFired,
					}
					entry.progress = AIController.createState(activeTrack.drivelineQuadCenters, entry.state.pos)
					entry.resetSeq += 1
					entry.resetRequested = false
					entry.forceSnapshot = true
				else
					local kartId = if entry.player.UserId ~= 0 then entry.player.UserId else playerFallbackIdx
					local myRank = rankById[tostring(kartId)] or 2
					local rawPlayerInput = if entry.state.race.raceFinished
						then AIController.computeCoastInput(
							entry.progress,
							entry.state,
							activeTrack.drivelineQuadCenters,
							fixedDt
						)
						else entry.input
					local filteredInput = KartSolver.stepRaceInput(entry.state, rawPlayerInput, raceTick, racePhase)
					local events =
						KartSolver.stepWithItems(entry.state, filteredInput, worldQuery, fixedDt, itemWorld, {
							isServer = true,
							advanceItemWorld = false,
							kartId = kartId,
							flyableWorld = flyableWorld,
							allKartProxies = preProxies,
							drivelineCenters = activeTrack.drivelineQuadCenters,
							rank = myRank,
							difficulty = "best",
							rollPowerup = function(_s, ev)
								rollCounter += 1
								local seed = math.floor(os.clock() * 1000)
									+ rollCounter * 7919
									+ ev.id * 101
									+ itemWorld.elapsedTicks * 31
								return powerupMgr:getRandomPowerup(myRank, seed, itemWorld.elapsedTicks * fixedDt)
							end,
						})
					local chkChanged = CheckManager.stepKart(
						entry.state.race,
						activeTrack.checkpoints,
						entry.state.prevPos,
						entry.state.pos,
						raceTick,
						raceClock.totalLaps
					)
					AIController.updateProgress(entry.progress, entry.state.pos, activeTrack.drivelineQuadCenters)
					table.insert(collisionParticipants, { id = kartId, state = entry.state })
					table.insert(activeStates, entry.state)
					if racePhase ~= prevPhase or chkChanged or #events > 0 then
						entry.forceSnapshot = true
					end
				end
				if entry.state.race.raceFinished then
					finishedPlayerCount += 1
				end
			end

			if playerCount > 0 and finishedPlayerCount == playerCount and raceClock.delayFinishStartTick < 0 then
				RaceState.enterDelayFinish(raceClock)
				for _, entry in entries do
					entry.state.race.phase = raceClock.phase
					entry.forceSnapshot = true
				end
			end

			if KartSolver.resolveKartKartCollisions(collisionParticipants) > 0 then
				for _, other in entries do
					other.forceSnapshot = true
				end
			end

			local ssParticipants: { KartSolver.SlipstreamParticipant } = table.create(#collisionParticipants)
			for _, cp in collisionParticipants do
				local isDummy = (cp.id == TestDummyKart.DUMMY_KART_ID)
				local diffPreset = KartTuning.difficulties[cp.state.profile.difficulty]
				local disableSS = isDummy and diffPreset ~= nil and diffPreset.aiDisableSlipstreamUsage
				table.insert(ssParticipants, {
					id = cp.id,
					state = cp.state,
					disableSlipstream = disableSS,
				})
			end
			if KartSolver.stepSlipstream(ssParticipants, fixedDt, stepper:getTick()) > 0 then
				for _, other in entries do
					other.forceSnapshot = true
				end
			end

			for _, attackerState in activeStates do
				if attackerState.attachmentType == ItemTuning.ATTACHMENT_SWATTER then
					if KartSolver.checkSwatterHits(attackerState, activeStates, itemWorld.elapsedTicks) > 0 then
						for _, other in entries do
							other.forceSnapshot = true
						end
					end
				end
			end

			local _, postProxies = computeStandingsAndProxies()
			local preFlyCount = #flyableWorld.entries
			local preEffects: { [Player]: number } = {}
			for player, entry in entries do
				preEffects[player] = entry.state.itemEffect.effectType
			end
			Flyable.step(
				flyableWorld,
				postProxies,
				worldQuery,
				fixedDt,
				activeTrack.drivelineQuadCenters,
				itemWorld.elapsedTicks
			)
			local flyChanged = (#flyableWorld.entries ~= preFlyCount)
			for player, entry in entries do
				if flyChanged or entry.state.itemEffect.effectType ~= preEffects[player] then
					entry.forceSnapshot = true
				end
			end

			if inLobbySession and sessionPhase == "RACING" then
				local pTotal = 0
				local pFinished = 0
				for _, entry in entries do
					pTotal += 1
					if entry.state.race.raceFinished then
						pFinished += 1
					end
				end
				if pTotal > 0 and pFinished == pTotal then
					if lobbyFinishReturnAt == nil then
						lobbyFinishReturnAt = os.clock() + 6.0
					elseif os.clock() >= lobbyFinishReturnAt then
						handleReturnToLobby()
					end
				end
			end
		end)
		debug.profileend()

		local now = os.clock()
		local currentTick = stepper:getTick()
		snapshotAccum += dt
		local periodicDue = snapshotAccum >= SNAPSHOT_INTERVAL_SEC
		if periodicDue then
			snapshotAccum %= SNAPSHOT_INTERVAL_SEC
		end

		local latestRanks, _ = computeStandingsAndProxies()
		local function getRemoteSlipstreamTimes(s: KartSolver.KartState): (number, number)
			local ssTime = if s.slipstream.inZone then math.max(0.0, s.slipstream.slipstreamTime) else 0.0
			local ssInc = s.maxSpeedState.increases["SLIPSTREAM"]
			local fadeRatio = if ssInc.active and ssInc.maxAddSpeed > 0
				then (ssInc.currentSpeedup / ssInc.maxAddSpeed)
				else 0.0
			local ssBonus = math.max(s.slipstream.bonusTime, fadeRatio)
			return ssTime, ssBonus
		end
		local dummySSTime, dummySSBonus = getRemoteSlipstreamTimes(dummyState)
		local dummyTel = KartSolver.getTelemetry(dummyState)
		local dummyRemoteState: GreyboxProtocol.RemoteKartState = {
			id = TestDummyKart.DUMMY_STRING_ID,
			pos = { dummyState.pos.x, dummyState.pos.y, dummyState.pos.z },
			rot = { dummyState.rot.w, dummyState.rot.x, dummyState.rot.y, dummyState.rot.z },
			linVel = { dummyState.linVel.x, dummyState.linVel.y, dummyState.linVel.z },
			speed = dummyState.speed,
			steer = dummyState.steer,
			attachmentType = dummyTel.attachmentType,
			attachmentTicksLeft = dummyTel.attachmentTicksLeft,
			plungerFaceTicks = dummyTel.plungerFaceTicks,
			timedImpulseTicks = dummyState.timedImpulseTicks,
			isSquashed = dummyTel.isSquashed,
			skidState = dummyTel.skidState,
			skidTier = dummyTel.skidTier,
			nitroActive = dummyTel.nitroActive,
			rank = latestRanks[TestDummyKart.DUMMY_STRING_ID] or 1,
			lap = dummyState.race.lap,
			nextCheckpoint = dummyState.race.nextCheckpoint,
			raceFinished = dummyState.race.raceFinished,
			finishTick = dummyState.race.finishTick,
			trackNodeIdx = dummyAI.trackNodeIdx,
			slipstreamTime = dummySSTime,
			slipstreamBonusTime = dummySSBonus,
		}

		for _, entry in entries do
			local curr = entry.state
			local currTel = KartSolver.getTelemetry(curr)
			if
				(
					curr.maxCompressionRatio >= 1.0
					or curr.chassisSweepHitCount > entry.lastLoggedSweepCount
					or currTel.slipstreamInZone
					or currTel.slipstreamActive
				) and (now - entry.lastDiagLogSec) > 0.25
			then
				entry.lastDiagLogSec = now
				entry.lastLoggedSweepCount = curr.chassisSweepHitCount
				local n1 = curr.wheels[1].contactNormalWS
				print(
					string.format(
						"[OpenKart Diag] v=%.2fm/s y=%.3fm comp=%.2f sweeps=%d depen=%d mat=%s n1=(%.2f,%.2f,%.2f) ssInZone=%s chargeTicks=%d ready=%s act=%s max=%.2f",
						curr.speed,
						curr.pos.y,
						curr.maxCompressionRatio,
						curr.chassisSweepHitCount,
						curr.depenetrationCount,
						curr.activeMaterialName,
						n1.x,
						n1.y,
						n1.z,
						tostring(currTel.slipstreamInZone),
						currTel.slipstreamChargeTicks,
						tostring(currTel.slipstreamReady),
						tostring(currTel.slipstreamActive),
						currTel.currentMaxSpeed
					)
				)
			end

			if periodicDue or entry.forceSnapshot then
				entry.forceSnapshot = false
				local remotesForPlayer: { GreyboxProtocol.RemoteKartState } = {}
				if dummyEnabled then
					table.insert(remotesForPlayer, dummyRemoteState)
				end
				for _, extra in extraAIs do
					local eTel = KartSolver.getTelemetry(extra.state)
					local eSSTime, eSSBonus = getRemoteSlipstreamTimes(extra.state)
					table.insert(remotesForPlayer, {
						id = extra.sid,
						pos = { extra.state.pos.x, extra.state.pos.y, extra.state.pos.z },
						rot = { extra.state.rot.w, extra.state.rot.x, extra.state.rot.y, extra.state.rot.z },
						linVel = { extra.state.linVel.x, extra.state.linVel.y, extra.state.linVel.z },
						speed = extra.state.speed,
						steer = extra.state.steer,
						attachmentType = eTel.attachmentType,
						attachmentTicksLeft = eTel.attachmentTicksLeft,
						plungerFaceTicks = eTel.plungerFaceTicks,
						timedImpulseTicks = extra.state.timedImpulseTicks,
						isSquashed = eTel.isSquashed,
						skidState = eTel.skidState,
						skidTier = eTel.skidTier,
						nitroActive = eTel.nitroActive,
						rank = latestRanks[extra.sid] or 1,
						lap = extra.state.race.lap,
						nextCheckpoint = extra.state.race.nextCheckpoint,
						raceFinished = extra.state.race.raceFinished,
						finishTick = extra.state.race.finishTick,
						trackNodeIdx = extra.ai.trackNodeIdx,
						slipstreamTime = eSSTime,
						slipstreamBonusTime = eSSBonus,
					})
				end
				if localP2State ~= nil and localP2AI ~= nil then
					local p2Tel = KartSolver.getTelemetry(localP2State)
					local p2SSTime, p2SSBonus = getRemoteSlipstreamTimes(localP2State)
					table.insert(remotesForPlayer, {
						id = LOCAL_P2_STRING_ID,
						pos = { localP2State.pos.x, localP2State.pos.y, localP2State.pos.z },
						rot = { localP2State.rot.w, localP2State.rot.x, localP2State.rot.y, localP2State.rot.z },
						linVel = { localP2State.linVel.x, localP2State.linVel.y, localP2State.linVel.z },
						speed = localP2State.speed,
						steer = localP2State.steer,
						attachmentType = p2Tel.attachmentType,
						attachmentTicksLeft = p2Tel.attachmentTicksLeft,
						plungerFaceTicks = p2Tel.plungerFaceTicks,
						timedImpulseTicks = localP2State.timedImpulseTicks,
						isSquashed = p2Tel.isSquashed,
						skidState = p2Tel.skidState,
						skidTier = p2Tel.skidTier,
						nitroActive = p2Tel.nitroActive,
						rank = latestRanks[LOCAL_P2_STRING_ID] or 2,
						lap = localP2State.race.lap,
						nextCheckpoint = localP2State.race.nextCheckpoint,
						raceFinished = localP2State.race.raceFinished,
						finishTick = localP2State.race.finishTick,
						trackNodeIdx = localP2AI.trackNodeIdx,
						slipstreamTime = p2SSTime,
						slipstreamBonusTime = p2SSBonus,
					})
				end
				for _, other in entries do
					if other ~= entry then
						local sid = tostring(if other.player.UserId ~= 0 then other.player.UserId else 1)
						local oTel = KartSolver.getTelemetry(other.state)
						local oSSTime, oSSBonus = getRemoteSlipstreamTimes(other.state)
						table.insert(remotesForPlayer, {
							id = sid,
							pos = { other.state.pos.x, other.state.pos.y, other.state.pos.z },
							rot = { other.state.rot.w, other.state.rot.x, other.state.rot.y, other.state.rot.z },
							linVel = { other.state.linVel.x, other.state.linVel.y, other.state.linVel.z },
							speed = other.state.speed,
							steer = other.state.steer,
							attachmentType = oTel.attachmentType,
							attachmentTicksLeft = oTel.attachmentTicksLeft,
							plungerFaceTicks = oTel.plungerFaceTicks,
							timedImpulseTicks = other.state.timedImpulseTicks,
							isSquashed = oTel.isSquashed,
							skidState = oTel.skidState,
							skidTier = oTel.skidTier,
							nitroActive = oTel.nitroActive,
							rank = latestRanks[sid] or 1,
							lap = other.state.race.lap,
							nextCheckpoint = other.state.race.nextCheckpoint,
							raceFinished = other.state.race.raceFinished,
							finishTick = other.state.race.finishTick,
							trackNodeIdx = other.progress.trackNodeIdx,
							slipstreamTime = oSSTime,
							slipstreamBonusTime = oSSBonus,
						})
					end
				end
				fireSnapshotPacket(telemetryRemote, entry, currentTick, now, itemWorld, flyableWorld, remotesForPlayer)
			end
		end
	end)
end

return table.freeze(GreyboxKartServer)
