--!strict
-- src/client/GameHud.client.lua
-- SPDX-License-Identifier: GPL-3.0-or-later
-- ported from src/states_screens/race_gui.cpp:L171-L266, L300-L487, L564-L784, L795-L1131,
-- src/states_screens/race_gui_base.cpp:L785-L1256 (STK 1.5)
-- Faithful mode-conditional STK RaceGUI port bound strictly to interpolated render state (HudState).
-- Blocked elements/sub-elements per docs/hud-spec.md remain explicitly inactive.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local localPlayer = Players.LocalPlayer
local Shared = ReplicatedStorage:WaitForChild("Shared")
local GreyboxArenaData = require(Shared.track.GreyboxArenaData)
local HudState = require("./HudState")
local RaceHudMath = require(Shared.hud.RaceHudMath)
local Standings = require(Shared.race.Standings)

-- Verified CC0 GUI icons (author: Alayan, stk-code data/gui/icons/licenses.txt:L193-L198; audited in assets/CREDITS.md)
local SPEED_BACK_ASSET = "rbxassetid://118820075105703"
local SPEED_FORE_ASSET = "rbxassetid://76789188667868"
local GAUGE_EMPTY_ASSET = "rbxassetid://86943125927894"
local GAUGE_FULL_ASSET = "rbxassetid://125310951299234"
local GAUGE_FULL_BRIGHT_ASSET = "rbxassetid://103689241713508"

-- Verified GPL 2.0 kart icon (author: Anthony "yeKcim" Carré, karts/tux/licenses.txt:L7-L9, rev 18627;
-- Tux character by Larry Ewing using The GIMP; audited in assets/CREDITS.md)
local TUX_ICON_ASSET = "rbxassetid://106784086588016"

local RANK_ANIM_DURATION_SEC = 0.4 -- race_gui.cpp:L953
local RANK_MIN_SHRINK = 0.3 -- race_gui.cpp:L954

local HARD_MASK_TRANSPARENCY = NumberSequence.new({
	NumberSequenceKeypoint.new(0.0, 0.0),
	NumberSequenceKeypoint.new(0.499, 0.0),
	NumberSequenceKeypoint.new(0.501, 1.0),
	NumberSequenceKeypoint.new(1.0, 1.0),
})

type RadialSlice = {
	container: Frame,
	gradStart: UIGradient,
	gradEnd: UIGradient,
	image: ImageLabel,
}

local function makeRadialSlice(
	parent: Instance,
	name: string,
	assetId: string,
	centerX: number,
	centerY: number,
	zIndex: number
): RadialSlice
	local container = Instance.new("Frame")
	container.Name = name
	container.BackgroundTransparency = 1
	container.BorderSizePixel = 0
	container.Size = UDim2.fromScale(1, 1)
	container.ClipsDescendants = true
	container.Visible = false
	container.ZIndex = zIndex
	container.Parent = parent

	local maskStart = Instance.new("CanvasGroup")
	maskStart.Name = "MaskStart"
	maskStart.BackgroundTransparency = 1
	maskStart.BorderSizePixel = 0
	maskStart.Size = UDim2.fromScale(3, 3)
	maskStart.AnchorPoint = Vector2.new(0.5, 0.5)
	maskStart.Position = UDim2.fromScale(centerX, centerY)
	maskStart.Parent = container

	local gradStart = Instance.new("UIGradient")
	gradStart.Transparency = HARD_MASK_TRANSPARENCY
	gradStart.Parent = maskStart

	local maskEnd = Instance.new("CanvasGroup")
	maskEnd.Name = "MaskEnd"
	maskEnd.BackgroundTransparency = 1
	maskEnd.BorderSizePixel = 0
	maskEnd.Size = UDim2.fromScale(1, 1)
	maskEnd.AnchorPoint = Vector2.new(0.5, 0.5)
	maskEnd.Position = UDim2.fromScale(0.5, 0.5)
	maskEnd.Parent = maskStart

	local gradEnd = Instance.new("UIGradient")
	gradEnd.Transparency = HARD_MASK_TRANSPARENCY
	gradEnd.Parent = maskEnd

	local image = Instance.new("ImageLabel")
	image.Name = "FillTexture"
	image.BackgroundTransparency = 1
	image.BorderSizePixel = 0
	image.Image = assetId
	image.ScaleType = Enum.ScaleType.Stretch
	image.Size = UDim2.fromScale(1 / 3, 1 / 3)
	image.AnchorPoint = Vector2.new(centerX, centerY)
	image.Position = UDim2.fromScale(0.5, 0.5)
	image.Parent = maskEnd

	return {
		container = container,
		gradStart = gradStart,
		gradEnd = gradEnd,
		image = image,
	}
end

local function createBlockedSlot(parent: Instance, name: string, reason: string): Frame
	local slot = Instance.new("Frame")
	slot.Name = name
	slot.BackgroundTransparency = 1
	slot.Size = UDim2.fromOffset(0, 0)
	slot.Visible = false
	slot.Active = false
	slot:SetAttribute("BlockedReason", reason)
	slot.Parent = parent
	return slot
end

local function applyRect(frame: GuiObject, rect: RaceHudMath.HudRect)
	frame.Position = UDim2.fromOffset(rect.x, rect.y)
	frame.Size = UDim2.fromOffset(rect.width, rect.height)
end

local function setLineSegment(line: Frame, x0: number, y0: number, x1: number, y1: number, thickness: number)
	local dx = x1 - x0
	local dy = y1 - y0
	local len = math.sqrt(dx * dx + dy * dy)
	line.Position = UDim2.fromOffset(0.5 * (x0 + x1), 0.5 * (y0 + y1))
	line.Size = UDim2.fromOffset(math.max(1, math.floor(len + 0.5)), thickness)
	line.Rotation = math.deg(math.atan2(dy, dx))
end

local playerGui = localPlayer:WaitForChild("PlayerGui")
local gui = Instance.new("ScreenGui")
gui.Name = "OpenKartGameHud"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = playerGui

-- Bindable Element #1: Speedometer (speedback.png + 8-segment speedfore.png, race_gui.cpp:L1011-L1131)
local speedRoot = Instance.new("Frame")
speedRoot.Name = "Speedometer"
speedRoot.BackgroundTransparency = 1
speedRoot.BorderSizePixel = 0
speedRoot.Parent = gui

local speedBack = Instance.new("ImageLabel")
speedBack.Name = "Background"
speedBack.BackgroundTransparency = 1
speedBack.BorderSizePixel = 0
speedBack.Size = UDim2.fromScale(1, 1)
speedBack.Image = SPEED_BACK_ASSET
speedBack.ScaleType = Enum.ScaleType.Stretch
speedBack.ZIndex = 1
speedBack.Parent = speedRoot

local speedHalf1 = makeRadialSlice(
	speedRoot,
	"ForegroundHalf1",
	SPEED_FORE_ASSET,
	RaceHudMath.SPEED_CENTER_X,
	RaceHudMath.SPEED_CENTER_Y,
	2
)
local speedHalf2 = makeRadialSlice(
	speedRoot,
	"ForegroundHalf2",
	SPEED_FORE_ASSET,
	RaceHudMath.SPEED_CENTER_X,
	RaceHudMath.SPEED_CENTER_Y,
	2
)

-- Bindable Element #2: Gauge-Center Rank Digit (race_gui.cpp:L914-L1001, Standings.lua)
local rankLabel = Instance.new("TextLabel")
rankLabel.Name = "RankDigit"
rankLabel.BackgroundTransparency = 1
rankLabel.BorderSizePixel = 0
rankLabel.AnchorPoint = Vector2.new(0.5, 0.5)
rankLabel.Font = Enum.Font.GothamBlack
rankLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
rankLabel.TextStrokeColor3 = Color3.fromRGB(12, 14, 18)
rankLabel.TextStrokeTransparency = 0.0
rankLabel.TextScaled = false
rankLabel.Text = "1"
rankLabel.ZIndex = 4
rankLabel.Parent = gui

-- Bindable Element #3: Nitro Energy Meter (gauge_empty.png + 5-segment gauge_full[_bright].png, race_gui.cpp:L795-L886)
local energyRoot = Instance.new("Frame")
energyRoot.Name = "EnergyMeter"
energyRoot.BackgroundTransparency = 1
energyRoot.BorderSizePixel = 0
energyRoot.Parent = gui

local energyBack = Instance.new("ImageLabel")
energyBack.Name = "Background"
energyBack.BackgroundTransparency = 1
energyBack.BorderSizePixel = 0
energyBack.Size = UDim2.fromScale(1, 1)
energyBack.Image = GAUGE_EMPTY_ASSET
energyBack.ScaleType = Enum.ScaleType.Stretch
energyBack.ZIndex = 1
energyBack.Parent = energyRoot

local energyFill = makeRadialSlice(
	energyRoot,
	"ForegroundFill",
	GAUGE_FULL_ASSET,
	RaceHudMath.NITRO_CENTER_X,
	RaceHudMath.NITRO_CENTER_Y,
	2
)
createBlockedSlot(energyRoot, "NitroCoinTargetSlot", "Blocked: Challenge coin target mode unbuilt (P3)")

-- Bindable Element #4: Global Elapsed Race Timer (top right, race_gui.cpp:L415-L487)
local timerLabel = Instance.new("TextLabel")
timerLabel.Name = "GlobalTimer"
timerLabel.BackgroundTransparency = 1
timerLabel.BorderSizePixel = 0
timerLabel.Font = Enum.Font.Code
timerLabel.TextXAlignment = Enum.TextXAlignment.Right
timerLabel.TextYAlignment = Enum.TextYAlignment.Center
timerLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
timerLabel.TextStrokeColor3 = Color3.fromRGB(10, 12, 16)
timerLabel.TextStrokeTransparency = 0.0
timerLabel.TextScaled = true
timerLabel.Text = "00:00.000"
timerLabel.ZIndex = 4
timerLabel.Parent = gui
createBlockedSlot(timerLabel, "LapSplitsSlot", "Blocked: CheckManager lap splits unbuilt (P0)")

-- Bindable Element #5: Top-Left Player Icon (race_gui_base.cpp:L785-L1054)
local playerIconRoot = Instance.new("Frame")
playerIconRoot.Name = "PlayerIconsList"
playerIconRoot.BackgroundTransparency = 1
playerIconRoot.BorderSizePixel = 0
playerIconRoot.Parent = gui

local localPlayerIcon = Instance.new("ImageLabel")
localPlayerIcon.Name = "LocalKartIcon"
localPlayerIcon.BackgroundTransparency = 1
localPlayerIcon.BorderSizePixel = 0
localPlayerIcon.Size = UDim2.fromScale(1, 1)
localPlayerIcon.Image = TUX_ICON_ASSET
localPlayerIcon.ScaleType = Enum.ScaleType.Fit
localPlayerIcon.ZIndex = 3
localPlayerIcon.Parent = playerIconRoot

createBlockedSlot(playerIconRoot, "IconsFrameSlot", "Blocked: icons-frame.png skipped (unverified license)")
createBlockedSlot(playerIconRoot, "HeldPowerupBadgeSlot", "Blocked: Powerup / PowerupManager unbuilt (P1)")
createBlockedSlot(playerIconRoot, "PlungerBadgeSlot", "Blocked: Plunger / Attachment unbuilt (P1)")
createBlockedSlot(playerIconRoot, "AttachmentBadgeSlot", "Blocked: Attachment unbuilt (P1)")
createBlockedSlot(playerIconRoot, "FinishedFlagSlot", "Blocked: CheckManager race finish unbuilt (P0)")

-- Bindable Element #6: Bottom-Left Minimap (race_gui.cpp:L171-L266, L564-L784, graph.cpp:L590-L595)
local minimapRoot = Instance.new("Frame")
minimapRoot.Name = "MiniMap"
minimapRoot.BackgroundColor3 = Color3.fromRGB(16, 20, 28)
minimapRoot.BackgroundTransparency = 0.55
minimapRoot.BorderSizePixel = 0
minimapRoot.ClipsDescendants = false
minimapRoot.Parent = gui

local minimapBorder = Instance.new("UIStroke")
minimapBorder.Color = Color3.fromRGB(225, 232, 245)
minimapBorder.Transparency = 0.45
minimapBorder.Thickness = 1.5
minimapBorder.Parent = minimapRoot

local minimapCorner = Instance.new("UICorner")
minimapCorner.CornerRadius = UDim.new(0, 6)
minimapCorner.Parent = minimapRoot

local outlineCount = math.max(0, #GreyboxArenaData.drivelineQuadCenters - 1)
local drivelineSegments: { Frame } = table.create(outlineCount)
for i = 1, outlineCount do
	local seg = Instance.new("Frame")
	seg.Name = "DrivelineSeg_" .. tostring(i)
	seg.AnchorPoint = Vector2.new(0.5, 0.5)
	seg.BackgroundColor3 = Color3.fromRGB(220, 226, 238)
	seg.BackgroundTransparency = 0.25
	seg.BorderSizePixel = 0
	seg.ZIndex = 2
	seg.Parent = minimapRoot
	drivelineSegments[i] = seg
end

local quadDots: { Frame } = table.create(#GreyboxArenaData.drivelineQuadCenters)
for i = 1, #GreyboxArenaData.drivelineQuadCenters do
	local qdot = Instance.new("Frame")
	qdot.Name = "QuadCenter_" .. tostring(i)
	qdot.AnchorPoint = Vector2.new(0.5, 0.5)
	qdot.Size = UDim2.fromOffset(4, 4)
	qdot.BackgroundColor3 = Color3.fromRGB(185, 195, 212)
	qdot.BackgroundTransparency = 0.25
	qdot.BorderSizePixel = 0
	qdot.ZIndex = 2
	qdot.Parent = minimapRoot
	local qc = Instance.new("UICorner")
	qc.CornerRadius = UDim.new(1, 0)
	qc.Parent = qdot
	quadDots[i] = qdot
end

-- Start/Finish quad-0 marker (graph.cpp:L229-L273)
local startTick = Instance.new("Frame")
startTick.Name = "LapLineTick"
startTick.AnchorPoint = Vector2.new(0.5, 0.5)
startTick.Size = UDim2.fromOffset(10, 3)
startTick.BackgroundColor3 = Color3.fromRGB(235, 70, 70)
startTick.BorderSizePixel = 0
startTick.ZIndex = 3
startTick.Parent = minimapRoot

-- Player kart dot + icon projected from interpolated renderHud.pos
local mmKartMarker = Instance.new("Frame")
mmKartMarker.Name = "PlayerKartDot"
mmKartMarker.AnchorPoint = Vector2.new(0.5, 0.5)
mmKartMarker.BackgroundColor3 = Color3.fromRGB(255, 65, 65)
mmKartMarker.BorderSizePixel = 0
mmKartMarker.ZIndex = 4
mmKartMarker.Parent = minimapRoot

local mmKartCorner = Instance.new("UICorner")
mmKartCorner.CornerRadius = UDim.new(1, 0)
mmKartCorner.Parent = mmKartMarker

local mmKartStroke = Instance.new("UIStroke")
mmKartStroke.Color = Color3.fromRGB(255, 255, 255)
mmKartStroke.Thickness = 1.5
mmKartStroke.Parent = mmKartMarker

local mmKartIcon = Instance.new("ImageLabel")
mmKartIcon.Name = "PlayerKartIcon"
mmKartIcon.BackgroundTransparency = 1
mmKartIcon.BorderSizePixel = 0
mmKartIcon.Size = UDim2.fromScale(1, 1)
mmKartIcon.Image = TUX_ICON_ASSET
mmKartIcon.ScaleType = Enum.ScaleType.Fit
mmKartIcon.ZIndex = 5
mmKartIcon.Parent = mmKartMarker

createBlockedSlot(minimapRoot, "AIKartMarkersSlot", "Blocked: AI / Multiplayer opponent karts unbuilt (P1-P2)")
createBlockedSlot(minimapRoot, "CTFFlagMarkersSlot", "Blocked: CaptureTheFlag mode unbuilt (P2)")
createBlockedSlot(minimapRoot, "SoccerBallMarkerSlot", "Blocked: SoccerWorld mode unbuilt (P2)")
createBlockedSlot(minimapRoot, "BasketballMarkersSlot", "Blocked: ProjectileManager / RubberBall unbuilt (P1)")

-- Attribution & debug telemetry key hint (AGENTS.md Identity requirement)
local footer = Instance.new("TextLabel")
footer.Name = "AttributionFooter"
footer.BackgroundTransparency = 1
footer.AnchorPoint = Vector2.new(0, 1)
footer.Position = UDim2.new(0, 12, 1, -8)
footer.Size = UDim2.fromOffset(480, 18)
footer.Font = Enum.Font.Code
footer.TextSize = 12
footer.TextXAlignment = Enum.TextXAlignment.Left
footer.TextColor3 = Color3.fromRGB(220, 226, 236)
footer.TextStrokeTransparency = 0.4
footer.Text = "OpenKart (unofficial SuperTuxKart 1.5 port) | F3: Telemetry"
footer.Parent = gui

-- Explicitly inactive blocked RaceGUI / RaceGUIBase elements per docs/hud-spec.md & docs/port-map.md
local blockedSlots = {
	{ "LiveDifferenceSlot", "Blocked: LinearWorld / GhostReplay unbuilt" },
	{ "LapCounterSlot", "Blocked: CheckManager lap crossing unbuilt" },
	{ "PowerupIconsSlot", "Blocked: Powerup / PowerupManager unbuilt" },
	{ "ReadySetGoSlot", "Blocked: RacePhase countdown unbuilt" },
	{ "GoalBannerSlot", "Blocked: SoccerWorld unbuilt" },
	{ "MessagesSlot", "Blocked: World / Item event feed unbuilt" },
	{ "MusicDescriptionSlot", "Blocked: MusicManager presentation unbuilt" },
	{ "PlungerFaceSlot", "Blocked: Plunger / Attachment + unverified plungerface.png" },
}
for _, spec in blockedSlots do
	createBlockedSlot(gui, spec[1], spec[2])
end

local arenaBounds: RaceHudMath.MinimapBounds = {
	minX = GreyboxArenaData.minimapBounds.minX,
	maxX = GreyboxArenaData.minimapBounds.maxX,
	minZ = GreyboxArenaData.minimapBounds.minZ,
	maxZ = GreyboxArenaData.minimapBounds.maxZ,
	range = GreyboxArenaData.minimapBounds.range,
}

local lastViewportW = -1
local lastViewportH = -1
local lastMinimapMode = -1
local lastTotalKarts = -1
local cachedSpeedRect: RaceHudMath.HudRect = RaceHudMath.computeSpeedometerRect(800, 450)
local cachedRankAnchor: RaceHudMath.RankAnchor = RaceHudMath.computeRankAnchor(cachedSpeedRect)
local cachedMinimapLayout: RaceHudMath.MinimapLayout = RaceHudMath.computeMinimapLayout(800, 450, 0)

local rankAnimState: "NONE" | "SMALLER" | "BIGGER" = "NONE"
local rankAnimDuration = 0.0
local lastRank = 1
local shownRank = 1

local function layoutStaticElements(vw: number, vh: number, minimapVisible: boolean, totalKarts: number, rank: number)
	cachedSpeedRect = RaceHudMath.computeSpeedometerRect(vw, vh)
	cachedRankAnchor = RaceHudMath.computeRankAnchor(cachedSpeedRect)
	applyRect(speedRoot, cachedSpeedRect)
	applyRect(energyRoot, RaceHudMath.computeEnergyMeterRect(vw, vh))
	applyRect(timerLabel, RaceHudMath.computeTimerRect(vw, vh))

	cachedMinimapLayout = RaceHudMath.computeMinimapLayout(vw, vh, 0)
	minimapRoot.Position = UDim2.fromOffset(cachedMinimapLayout.x, cachedMinimapLayout.y)
	minimapRoot.Size = UDim2.fromOffset(cachedMinimapLayout.width, cachedMinimapLayout.height)
	mmKartMarker.Size = UDim2.fromOffset(cachedMinimapLayout.playerIconSize, cachedMinimapLayout.playerIconSize)

	local bottomMargin = if minimapVisible then (cachedMinimapLayout.height + cachedMinimapLayout.mapBottom) else 0
	applyRect(playerIconRoot, RaceHudMath.computePlayerIconRect(vw, vh, totalKarts, bottomMargin, rank, true))

	-- Project canonical driveline quad centers through RaceHudMath.projectToMinimap
	local centers = GreyboxArenaData.drivelineQuadCenters
	local projected: { { number } } = table.create(#centers)
	for i, c in centers do
		local px, py = RaceHudMath.projectToMinimap(
			c.x,
			c.z,
			arenaBounds,
			cachedMinimapLayout.width,
			cachedMinimapLayout.height,
			false
		)
		projected[i] = { px, py }
		quadDots[i].Position = UDim2.fromOffset(px, py)
	end
	for i = 1, #drivelineSegments do
		setLineSegment(
			drivelineSegments[i],
			projected[i][1],
			projected[i][2],
			projected[i + 1][1],
			projected[i + 1][2],
			3
		)
	end
	local sx, sy =
		RaceHudMath.projectToMinimap(0, 0, arenaBounds, cachedMinimapLayout.width, cachedMinimapLayout.height, false)
	startTick.Position = UDim2.fromOffset(sx, sy)
end

RunService:BindToRenderStep("OpenKartGameHud", Enum.RenderPriority.Camera.Value + 2, function(dt: number)
	local renderHud = HudState.get()
	local standingsInput: { Standings.StandingsEntry } = {
		{
			id = "local",
			lap = renderHud.lap,
			checkpoint = renderHud.checkpoint,
			distance = renderHud.distance,
			initialPosition = 1,
		},
	}
	local rank, totalKarts = Standings.getRankForId(standingsInput, "local")
	local vis = RaceHudMath.getModeVisibility(renderHud.raceMode, {
		isRacePhase = renderHud.ready,
		numKarts = totalKarts,
		hasNavMesh = true,
	})

	local camera = Workspace.CurrentCamera
	if camera then
		local vp = camera.ViewportSize
		local vw = math.floor(vp.X)
		local vh = math.floor(vp.Y)
		local mmFlag = if vis.showMiniMap then 1 else 0
		if
			vw > 0
			and vh > 0
			and (
				vw ~= lastViewportW
				or vh ~= lastViewportH
				or mmFlag ~= lastMinimapMode
				or totalKarts ~= lastTotalKarts
			)
		then
			lastViewportW = vw
			lastViewportH = vh
			lastMinimapMode = mmFlag
			lastTotalKarts = totalKarts
			layoutStaticElements(vw, vh, vis.showMiniMap, totalKarts, rank)
		end
	end

	-- Apply mode-conditional visibility (race_gui.cpp:L314-L407)
	speedRoot.Visible = vis.showSpeedAndEnergy
	energyRoot.Visible = vis.showSpeedAndEnergy
	timerLabel.Visible = vis.showTimer
	rankLabel.Visible = vis.showSpeedAndEnergy and vis.showRankDigit
	playerIconRoot.Visible = vis.showPlayerIcons
	minimapRoot.Visible = vis.showMiniMap

	if not renderHud.ready then
		speedHalf1.container.Visible = false
		speedHalf2.container.Visible = false
		energyFill.container.Visible = false
		return
	end

	-- 1) Elapsed race timer from wall-clock Workspace:GetServerTimeNow() (race_gui.cpp:L415-L487)
	if vis.showTimer then
		local elapsedSec = math.max(0.0, Workspace:GetServerTimeNow() - renderHud.raceStartServerTime)
		timerLabel.Text = RaceHudMath.formatRaceTime(elapsedSec)
	end

	-- 2) Speedometer from interpolated speedMps (race_gui.cpp:L1048-L1130)
	if vis.showSpeedAndEnergy then
		local speedRatio = RaceHudMath.snapSpeedRatio(renderHud.speedMps)
		if speedRatio <= 0.0 then
			speedHalf1.container.Visible = false
			speedHalf2.container.Visible = false
		else
			speedHalf1.container.Visible = true
			local half1Ratio = math.min(speedRatio, 0.5)
			local half1EndDeg = RaceHudMath.computeSpeedSweepAngleDeg(half1Ratio)
			speedHalf1.gradStart.Rotation = RaceHudMath.SPEED_START_DEG - 90.0
			speedHalf1.gradEnd.Rotation = half1EndDeg + 90.0

			if speedRatio > 0.5 then
				speedHalf2.container.Visible = true
				local fullEndDeg = RaceHudMath.computeSpeedSweepAngleDeg(speedRatio)
				speedHalf2.gradStart.Rotation = RaceHudMath.SPEED_MID_DEG - 90.0
				speedHalf2.gradEnd.Rotation = fullEndDeg + 90.0
			else
				speedHalf2.container.Visible = false
			end
		end

		-- 3) Nitro Energy Meter from interpolated nitroEnergy (race_gui.cpp:L805-L886)
		local nitroRatio = RaceHudMath.snapNitroRatio(renderHud.nitroEnergy, renderHud.nitroMaxEnergy)
		if nitroRatio <= 0.0 then
			energyFill.container.Visible = false
		else
			energyFill.container.Visible = true
			energyFill.image.Image = if renderHud.nitroUsing then GAUGE_FULL_BRIGHT_ASSET else GAUGE_FULL_ASSET
			local currDeg = RaceHudMath.computeNitroSweepAngleDeg(nitroRatio)
			energyFill.gradStart.Rotation = currDeg - 90.0
			energyFill.gradEnd.Rotation = RaceHudMath.NITRO_START_DEG + 90.0
		end
	end

	-- 4) Gauge-center rank digit + STK shrink/expand animation (race_gui.cpp:L914-L1001)
	if vis.showSpeedAndEnergy and vis.showRankDigit then
		if rankAnimState == "NONE" then
			if lastRank ~= rank then
				rankAnimDuration = 0.0
				rankAnimState = "SMALLER"
			else
				shownRank = rank
			end
		else
			rankAnimDuration += dt
		end

		local scale = 1.0
		if rankAnimState == "SMALLER" then
			scale = 1.0 - rankAnimDuration / RANK_ANIM_DURATION_SEC
			shownRank = lastRank
			if scale < RANK_MIN_SHRINK then
				rankAnimState = "BIGGER"
				rankAnimDuration = 0.0
				lastRank = rank
				shownRank = rank
				scale = RANK_MIN_SHRINK
			end
		elseif rankAnimState == "BIGGER" then
			scale = rankAnimDuration / RANK_ANIM_DURATION_SEC + RANK_MIN_SHRINK
			shownRank = lastRank
			if scale > 1.0 then
				rankAnimState = "NONE"
				scale = 1.0
			end
		end

		rankLabel.Position = UDim2.fromOffset(cachedRankAnchor.x, cachedRankAnchor.y)
		local sizePx = math.max(10, math.floor(cachedRankAnchor.fontSize * scale))
		rankLabel.Size = UDim2.fromOffset(sizePx * 2, sizePx)
		rankLabel.TextSize = sizePx
		rankLabel.Text = tostring(shownRank)
	end

	-- 5) Minimap interpolated kart dot via identical projectToMinimap transform (race_gui.cpp:L678-L698)
	if vis.showMiniMap then
		local kx, ky = RaceHudMath.projectToMinimap(
			renderHud.pos.x,
			renderHud.pos.z,
			arenaBounds,
			cachedMinimapLayout.width,
			cachedMinimapLayout.height,
			false
		)
		mmKartMarker.Position = UDim2.fromOffset(kx, ky)
	end
end)
