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
local FixedStep = require(Shared.sim.FixedStep)
local Flyable = require(Shared.sim.Flyable)
local GreyboxArenaData = require(Shared.track.GreyboxArenaData)
local GreyboxProtocol = require(Shared.net.GreyboxProtocol)
local ItemTuning = require(Shared.ItemTuning)
local ItemWorld = require(Shared.items.ItemWorld)
local KartAssetHydrator = require("./KartAssetHydrator")
local KartSolver = require(Shared.sim.KartSolver)
local KartTuning = require(Shared.KartTuning)
local PowerupManager = require(Shared.items.PowerupManager)
local RobloxWorldQuery = require(Shared.sim.RobloxWorldQuery)
local SandtrackRoadCollisionData = require(Shared.track.SandtrackRoadCollisionData)
local SandtrackRoadProbeData = require(Shared.track.SandtrackRoadProbeData)
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
	part.CanCollide = if canCollide ~= nil then canCollide else true
	part.CanTouch = false
	part.CanQuery = true
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

local function loadTrackGeometry(trackId: string): (Folder, BasePart)
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
				for idx, chunk in SandtrackRoadCollisionData do
					local ok, partOrErr = pcall(function(): MeshPart
						local em = AssetService:CreateEditableMesh()
						local vIds: { number } = table.create(#chunk.verts // 3)
						for i = 1, #chunk.verts, 3 do
							table.insert(
								vIds,
								em:AddVertex(Vector3.new(chunk.verts[i], chunk.verts[i + 1], chunk.verts[i + 2]))
							)
						end
						for i = 1, #chunk.tris, 3 do
							em:AddTriangle(vIds[chunk.tris[i]], vIds[chunk.tris[i + 1]], vIds[chunk.tris[i + 2]])
						end
						return AssetService:CreateMeshPartAsync(Content.fromObject(em), {
							CollisionFidelity = Enum.CollisionFidelity.PreciseConvexDecomposition,
							RenderFidelity = Enum.RenderFidelity.Automatic,
						})
					end)
					if ok then
						local mp = partOrErr :: MeshPart
						mp.Name = "RoadCollisionChunk_" .. tostring(idx)
						mp.Anchored = true
						mp.CanCollide = true
						mp.CanTouch = false
						mp.CanQuery = true
						mp.DoubleSided = true
						mp.Transparency = 1
						mp.CFrame = CFrame.new(chunk.center[1], chunk.center[2], chunk.center[3])
						mp:SetAttribute("SurfaceMaterial", "road.jpg")
						mp.Parent = surfaces
					else
						warn("[OpenKart] RoadCollisionChunk failed: " .. tostring(partOrErr))
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

	local profile = KartTuning.buildProfile("medium", "best")
	local itemWorld = ItemWorld.fromArenaSpec(activeTrack :: any, "NORMAL_RACE")
	local flyableWorld = Flyable.createWorld()
	local dummyState = TestDummyKart.create(profile, nil, activeTrack.dummyStartPos, activeTrack.dummyStartYawRad)
	local dummyAI = TestDummyKart.createAIState(dummyState, activeTrack.drivelineQuadCenters)
	local powerupMgr = PowerupManager.new("NORMAL_RACE", 2, ItemTuning.IMPLEMENTED_POWERUPS)
	local rollCounter = 0
	local entries: { [Player]: PlayerKartEntry } = {}
	local totalDroppedDebt = 0.0
	local snapshotAccum = 0.0

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
			itemWorld = ItemWorld.fromArenaSpec(activeTrack :: any, "NORMAL_RACE")
			flyableWorld = Flyable.createWorld()
			dummyState = TestDummyKart.create(profile, nil, activeTrack.dummyStartPos, activeTrack.dummyStartYawRad)
			dummyAI = TestDummyKart.createAIState(dummyState, activeTrack.drivelineQuadCenters)
			Workspace:SetAttribute("OpenKartActiveTrack", activeTrack.trackId)
			Workspace:SetAttribute("OpenKartRaceStartTime", Workspace:GetServerTimeNow())
			for _, entry in entries do
				entry.player.ReplicationFocus = arenaPrimaryPart
				entry.state = KartSolver.createState(profile, activeTrack.startPos, activeTrack.startYawRad)
				entry.progress = AIController.createState(activeTrack.drivelineQuadCenters, entry.state.pos)
				entry.resetSeq += 1
				entry.forceSnapshot = true
			end
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
		local racers: { TestDummyKart.RacerProgress } = {
			{
				id = TestDummyKart.DUMMY_STRING_ID,
				state = dummyState,
				initialPosition = 1,
				aiState = dummyAI,
			},
		}
		local idx = 1
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
		local ranked = Standings.compute(TestDummyKart.buildStandingsEntries(racers, activeTrack.drivelineQuadCenters))
		local rankById: { [string]: number } = {}
		for _, r in ranked do
			rankById[r.id] = r.rank
		end
		local proxies: { Flyable.KartProxy } = {
			KartSolver.makeFlyableProxy(
				TestDummyKart.DUMMY_KART_ID,
				dummyState,
				rankById[TestDummyKart.DUMMY_STRING_ID] or 1,
				"best"
			),
		}
		local pIdx = 1
		for _, entry in entries do
			pIdx += 1
			local numId = if entry.player.UserId ~= 0 then entry.player.UserId else pIdx
			local sid = tostring(numId)
			table.insert(proxies, KartSolver.makeFlyableProxy(numId, entry.state, rankById[sid] or 2, "best"))
		end
		return rankById, proxies
	end

	RunService.Heartbeat:Connect(function(dt: number)
		debug.profilebegin("OpenKart_ServerSim")
		local _, _ = stepper:advance(dt, function(fixedDt: number)
			ItemWorld.tick(itemWorld)
			local rankById, preProxies = computeStandingsAndProxies()

			KartSolver.stepWithItems(
				dummyState,
				TestDummyKart.computeCruiseInput(dummyState, dummyAI, fixedDt, nil, activeTrack.drivelineQuadCenters),
				worldQuery,
				fixedDt,
				itemWorld,
				{
					isServer = true,
					advanceItemWorld = false,
					kartId = TestDummyKart.DUMMY_KART_ID,
					flyableWorld = flyableWorld,
					allKartProxies = preProxies,
					drivelineCenters = activeTrack.drivelineQuadCenters,
					rank = rankById[TestDummyKart.DUMMY_STRING_ID] or 1,
					difficulty = "best",
				}
			)

			local collisionParticipants: { KartSolver.CollisionParticipant } = {
				{ id = TestDummyKart.DUMMY_KART_ID, state = dummyState },
			}
			local activeStates: { KartSolver.KartState } = { dummyState }
			local playerFallbackIdx = 1

			for _, entry in entries do
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
					entry.state = KartSolver.createState(profile, activeTrack.startPos, activeTrack.startYawRad)
					entry.progress = AIController.createState(activeTrack.drivelineQuadCenters, entry.state.pos)
					entry.resetSeq += 1
					entry.resetRequested = false
					entry.forceSnapshot = true
				else
					local kartId = if entry.player.UserId ~= 0 then entry.player.UserId else playerFallbackIdx
					local myRank = rankById[tostring(kartId)] or 2
					local events = KartSolver.stepWithItems(entry.state, entry.input, worldQuery, fixedDt, itemWorld, {
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
					AIController.updateProgress(entry.progress, entry.state.pos, activeTrack.drivelineQuadCenters)
					table.insert(collisionParticipants, { id = kartId, state = entry.state })
					table.insert(activeStates, entry.state)
					if #events > 0 then
						entry.forceSnapshot = true
					end
				end
			end

			if KartSolver.resolveKartKartCollisions(collisionParticipants) > 0 then
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
			Flyable.step(
				flyableWorld,
				postProxies,
				worldQuery,
				fixedDt,
				activeTrack.drivelineQuadCenters,
				itemWorld.elapsedTicks
			)
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
		local dummyTel = KartSolver.getTelemetry(dummyState)
		local dummyRemoteState: GreyboxProtocol.RemoteKartState = {
			id = TestDummyKart.DUMMY_STRING_ID,
			pos = { dummyState.pos.x, dummyState.pos.y, dummyState.pos.z },
			rot = { dummyState.rot.w, dummyState.rot.x, dummyState.rot.y, dummyState.rot.z },
			linVel = { dummyState.linVel.x, dummyState.linVel.y, dummyState.linVel.z },
			speed = dummyState.speed,
			steer = dummyState.steer,
			attachmentType = dummyTel.attachmentType,
			plungerFaceTicks = dummyTel.plungerFaceTicks,
			timedImpulseTicks = dummyState.timedImpulseTicks,
			isSquashed = dummyTel.isSquashed,
			rank = latestRanks[TestDummyKart.DUMMY_STRING_ID] or 1,
			lap = dummyAI.lap,
			trackNodeIdx = dummyAI.trackNodeIdx,
		}

		for _, entry in entries do
			local curr = entry.state
			if
				(curr.maxCompressionRatio >= 1.0 or curr.chassisSweepHitCount > entry.lastLoggedSweepCount)
				and (now - entry.lastDiagLogSec) > 0.25
			then
				entry.lastDiagLogSec = now
				entry.lastLoggedSweepCount = curr.chassisSweepHitCount
				local n1 = curr.wheels[1].contactNormalWS
				print(
					string.format(
						"[OpenKart Diag] v=%.2fm/s y=%.3fm comp=%.2f sweeps=%d depen=%d mat=%s n1=(%.2f,%.2f,%.2f)",
						curr.speed,
						curr.pos.y,
						curr.maxCompressionRatio,
						curr.chassisSweepHitCount,
						curr.depenetrationCount,
						curr.activeMaterialName,
						n1.x,
						n1.y,
						n1.z
					)
				)
			end

			if periodicDue or entry.forceSnapshot then
				entry.forceSnapshot = false
				local remotesForPlayer: { GreyboxProtocol.RemoteKartState } = { dummyRemoteState }
				for _, other in entries do
					if other ~= entry then
						local sid = tostring(if other.player.UserId ~= 0 then other.player.UserId else 1)
						local oTel = KartSolver.getTelemetry(other.state)
						table.insert(remotesForPlayer, {
							id = sid,
							pos = { other.state.pos.x, other.state.pos.y, other.state.pos.z },
							rot = { other.state.rot.w, other.state.rot.x, other.state.rot.y, other.state.rot.z },
							linVel = { other.state.linVel.x, other.state.linVel.y, other.state.linVel.z },
							speed = other.state.speed,
							steer = other.state.steer,
							attachmentType = oTel.attachmentType,
							plungerFaceTicks = oTel.plungerFaceTicks,
							timedImpulseTicks = other.state.timedImpulseTicks,
							isSquashed = oTel.isSquashed,
							rank = latestRanks[sid] or 1,
							lap = other.progress.lap,
							trackNodeIdx = other.progress.trackNodeIdx,
						})
					end
				end
				fireSnapshotPacket(telemetryRemote, entry, currentTick, now, itemWorld, flyableWorld, remotesForPlayer)
			end
		end
	end)
end

return table.freeze(GreyboxKartServer)
