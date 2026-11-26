--!strict
-- src/client/GameHud.client.lua
-- SPDX-License-Identifier: GPL-3.0-or-later
-- ported from src/states_screens/race_gui.cpp:L171-L266, L300-L487, L564-L784, L795-L1131,
-- src/states_screens/race_gui_base.cpp:L785-L1256 (STK 1.5)
-- Faithful mode-conditional STK RaceGUI port bound strictly to interpolated render state (HudState).
-- Blocked elements/sub-elements per docs/hud-spec.md remain explicitly inactive.

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local localPlayer = Players.LocalPlayer
local Shared = ReplicatedStorage:WaitForChild("Shared")
local ClientSessionState = require("./ClientSessionState")
local ClientSettingsState = require("./ClientSettingsState")
local HudState = require("./HudState")
local ItemTuning = require(Shared.ItemTuning)
local RaceHudMath = require(Shared.hud.RaceHudMath)
local RaceState = require(Shared.sim.RaceState)
local Standings = require(Shared.race.Standings)
local TrackRegistry = require(Shared.track.TrackRegistry)

-- Verified CC0 GUI icons (author: Alayan, stk-code data/gui/icons/licenses.txt:L193-L198; audited in assets/CREDITS.md)
local SPEED_BACK_ASSET = "rbxassetid://118820075105703"
local SPEED_FORE_ASSET = "rbxassetid://76789188667868"
local GAUGE_EMPTY_ASSET = "rbxassetid://86943125927894"
local GAUGE_FULL_ASSET = "rbxassetid://125310951299234"
local GAUGE_FULL_BRIGHT_ASSET = "rbxassetid://103689241713508"

-- Verified GPL 2.0 kart icon (author: Anthony "yeKcim" Carré, karts/tux/licenses.txt:L7-L9, rev 18627;
-- Tux character by Larry Ewing using The GIMP; audited in assets/CREDITS.md)
local TUX_ICON_ASSET = "rbxassetid://106784086588016"
local ICONS_FRAME_ASSET = "rbxassetid://128866264800446"

-- Powerup HUD icons mapped per data/powerup.xml & DEP-5 re-audit (data/gui/icons/licenses.txt:L13-L24 + data/models/licenses.txt;
-- audited in assets/CREDITS.md, uploaded via upload_image).
local POWERUP_ICON_ASSETS: { [number]: string } = {
	[ItemTuning.POWERUP_BUBBLEGUM] = "rbxassetid://101181393814939",
	[ItemTuning.POWERUP_CAKE] = "rbxassetid://79582540802688",
	[ItemTuning.POWERUP_BOWLING] = "rbxassetid://130692326246436",
	[ItemTuning.POWERUP_ZIPPER] = "rbxassetid://105041309293311",
	[ItemTuning.POWERUP_PLUNGER] = "rbxassetid://101469144956890",
	[ItemTuning.POWERUP_SWITCH] = "rbxassetid://106092822459296",
	[ItemTuning.POWERUP_SWATTER] = "rbxassetid://126762223468459",
	[ItemTuning.POWERUP_RUBBERBALL] = "rbxassetid://73902710731702",
	[ItemTuning.POWERUP_PARACHUTE] = "rbxassetid://84448883940909",
	[ItemTuning.POWERUP_ANVIL] = "rbxassetid://85031117296474",
}

-- Verified CC-BY-SA-3.0 plunger-in-face overlay (stk-assets/textures/plungerface.png rev 18627; credits in assets/CREDITS.md)
local PLUNGER_FACE_ASSET = "rbxassetid://86029430083812"

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

-- Global GuiService:GetGuiInset() safe-area container so no HUD element sits under the Roblox topbar.
local hudSafeRoot = Instance.new("Frame")
hudSafeRoot.Name = "HudSafeRoot"
hudSafeRoot.BackgroundTransparency = 1
hudSafeRoot.BorderSizePixel = 0
hudSafeRoot.Parent = gui

local function updateSafeRootBounds(): (number, number)
	local insetTL, insetBR = GuiService:GetGuiInset()
	hudSafeRoot.Position = UDim2.fromOffset(insetTL.X, insetTL.Y)
	hudSafeRoot.Size = UDim2.new(1, -(insetTL.X + insetBR.X), 1, -(insetTL.Y + insetBR.Y))
	return insetTL.X + insetBR.X, insetTL.Y + insetBR.Y
end
updateSafeRootBounds()

-- RaceGUIBase::drawPlungerInFace overlay (race_gui_base.cpp:L1263-L1335)
local plungerFaceOverlay = Instance.new("ImageLabel")
plungerFaceOverlay.Name = "PlungerInFaceOverlay"
plungerFaceOverlay.BackgroundTransparency = 1
plungerFaceOverlay.AnchorPoint = Vector2.new(0.5, 0.5)
plungerFaceOverlay.Position = UDim2.fromScale(0.5, 0.5)
plungerFaceOverlay.Size = UDim2.fromScale(0.45, 0.6)
plungerFaceOverlay.ScaleType = Enum.ScaleType.Fit
plungerFaceOverlay.Image = PLUNGER_FACE_ASSET
plungerFaceOverlay.ZIndex = 50
plungerFaceOverlay.Visible = false
plungerFaceOverlay.Parent = gui

-- Bindable Element #1: Speedometer (speedback.png + 8-segment speedfore.png, race_gui.cpp:L1011-L1131)
local speedRoot = Instance.new("Frame")
speedRoot.Name = "Speedometer"
speedRoot.BackgroundTransparency = 1
speedRoot.BorderSizePixel = 0
speedRoot.Parent = hudSafeRoot

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
rankLabel.Parent = hudSafeRoot

-- Bindable Element #3: Nitro Energy Meter (gauge_empty.png + 5-segment gauge_full[_bright].png, race_gui.cpp:L795-L886)
local energyRoot = Instance.new("Frame")
energyRoot.Name = "EnergyMeter"
energyRoot.BackgroundTransparency = 1
energyRoot.BorderSizePixel = 0
energyRoot.Parent = hudSafeRoot

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
timerLabel.Parent = hudSafeRoot

-- Lap Counter (top right under timer, race_gui.cpp:L1287-L1292)
local lapLabel = Instance.new("TextLabel")
lapLabel.Name = "LapCounter"
lapLabel.BackgroundTransparency = 1
lapLabel.BorderSizePixel = 0
lapLabel.Font = Enum.Font.GothamBlack
lapLabel.TextXAlignment = Enum.TextXAlignment.Right
lapLabel.TextYAlignment = Enum.TextYAlignment.Center
lapLabel.TextColor3 = Color3.fromRGB(255, 232, 130)
lapLabel.TextStrokeColor3 = Color3.fromRGB(10, 12, 16)
lapLabel.TextStrokeTransparency = 0.0
lapLabel.TextScaled = true
lapLabel.Text = "Lap 1 / 5"
lapLabel.Visible = false
lapLabel.ZIndex = 4
lapLabel.Parent = hudSafeRoot

-- Ready/Set/Go + Start Boost / Lap Toast Banner (race_gui_base.cpp:L734-L779, linear_world.cpp:L414-L461)
local countdownLabel = Instance.new("TextLabel")
countdownLabel.Name = "ReadySetGoBanner"
countdownLabel.BackgroundTransparency = 1
countdownLabel.BorderSizePixel = 0
countdownLabel.Font = Enum.Font.GothamBlack
countdownLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
countdownLabel.TextStrokeColor3 = Color3.fromRGB(10, 12, 18)
countdownLabel.TextStrokeTransparency = 0.0
countdownLabel.TextScaled = true
countdownLabel.Text = ""
countdownLabel.Visible = false
countdownLabel.ZIndex = 20
countdownLabel.Parent = hudSafeRoot

local subBannerLabel = Instance.new("TextLabel")
subBannerLabel.Name = "RaceSubBanner"
subBannerLabel.BackgroundTransparency = 1
subBannerLabel.BorderSizePixel = 0
subBannerLabel.Font = Enum.Font.GothamBold
subBannerLabel.TextColor3 = Color3.fromRGB(255, 220, 75)
subBannerLabel.TextStrokeColor3 = Color3.fromRGB(10, 12, 18)
subBannerLabel.TextStrokeTransparency = 0.0
subBannerLabel.TextScaled = true
subBannerLabel.Text = ""
subBannerLabel.Visible = false
subBannerLabel.ZIndex = 20
subBannerLabel.Parent = hudSafeRoot

-- Finish Results Card
local finishCard = Instance.new("Frame")
finishCard.Name = "FinishBanner"
finishCard.AnchorPoint = Vector2.new(0.5, 0.5)
finishCard.Position = UDim2.fromScale(0.5, 0.38)
finishCard.Size = UDim2.fromOffset(380, 200)
finishCard.BackgroundColor3 = Color3.fromRGB(16, 20, 30)
finishCard.BackgroundTransparency = 0.2
finishCard.BorderSizePixel = 0
finishCard.Visible = false
finishCard.ZIndex = 25
finishCard.Parent = hudSafeRoot

local finishCorner = Instance.new("UICorner")
finishCorner.CornerRadius = UDim.new(0, 12)
finishCorner.Parent = finishCard

local finishStroke = Instance.new("UIStroke")
finishStroke.Color = Color3.fromRGB(255, 215, 80)
finishStroke.Thickness = 2
finishStroke.Parent = finishCard

local finishTitle = Instance.new("TextLabel")
finishTitle.Name = "Title"
finishTitle.BackgroundTransparency = 1
finishTitle.Position = UDim2.fromOffset(16, 12)
finishTitle.Size = UDim2.new(1, -32, 0, 42)
finishTitle.Font = Enum.Font.GothamBlack
finishTitle.TextColor3 = Color3.fromRGB(255, 225, 90)
finishTitle.TextStrokeTransparency = 0.2
finishTitle.TextScaled = true
finishTitle.Text = "FINISHED!"
finishTitle.ZIndex = 26
finishTitle.Parent = finishCard

local finishRankLabel = Instance.new("TextLabel")
finishRankLabel.Name = "RankSummary"
finishRankLabel.BackgroundTransparency = 1
finishRankLabel.Position = UDim2.fromOffset(16, 56)
finishRankLabel.Size = UDim2.new(1, -32, 0, 32)
finishRankLabel.Font = Enum.Font.GothamBold
finishRankLabel.TextColor3 = Color3.fromRGB(240, 244, 252)
finishRankLabel.TextScaled = true
finishRankLabel.Text = "1st Place — 00:00.000"
finishRankLabel.ZIndex = 26
finishRankLabel.Parent = finishCard

local finishStandingsLabel = Instance.new("TextLabel")
finishStandingsLabel.Name = "StandingsList"
finishStandingsLabel.BackgroundTransparency = 1
finishStandingsLabel.Position = UDim2.fromOffset(20, 94)
finishStandingsLabel.Size = UDim2.new(1, -40, 0, 94)
finishStandingsLabel.Font = Enum.Font.Code
finishStandingsLabel.TextSize = 15
finishStandingsLabel.TextYAlignment = Enum.TextYAlignment.Top
finishStandingsLabel.TextXAlignment = Enum.TextXAlignment.Left
finishStandingsLabel.TextColor3 = Color3.fromRGB(215, 225, 240)
finishStandingsLabel.Text = ""
finishStandingsLabel.ZIndex = 26
finishStandingsLabel.Parent = finishCard

local function sendReturnToMenu()
	local remotes = ReplicatedStorage:FindFirstChild("OpenKartRemotes")
	local cmd = if remotes then remotes:FindFirstChild("SessionCommand") else nil
	if cmd and cmd:IsA("RemoteEvent") then
		cmd:FireServer("RETURN_TO_MENU")
	end
end

local finishMenuBtn = Instance.new("TextButton")
finishMenuBtn.Name = "FinishBackToMenuBtn"
finishMenuBtn.Size = UDim2.fromOffset(180, 32)
finishMenuBtn.AnchorPoint = Vector2.new(0.5, 1)
finishMenuBtn.Position = UDim2.new(0.5, 0, 1, -10)
finishMenuBtn.BackgroundColor3 = Color3.fromRGB(36, 98, 178)
finishMenuBtn.BorderSizePixel = 0
finishMenuBtn.Font = Enum.Font.GothamBold
finishMenuBtn.TextSize = 14
finishMenuBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
finishMenuBtn.Text = "Back to Menu"
finishMenuBtn.ZIndex = 27
finishMenuBtn.Parent = finishCard

local finishMenuBtnCorner = Instance.new("UICorner")
finishMenuBtnCorner.CornerRadius = UDim.new(0, 6)
finishMenuBtnCorner.Parent = finishMenuBtn
finishMenuBtn.Activated:Connect(sendReturnToMenu)

local raceMenuBtn = Instance.new("TextButton")
raceMenuBtn.Name = "RaceBackToMenuBtn"
raceMenuBtn.Position = UDim2.fromOffset(8, 8)
raceMenuBtn.Size = UDim2.fromOffset(92, 28)
raceMenuBtn.BackgroundColor3 = Color3.fromRGB(20, 30, 52)
raceMenuBtn.BackgroundTransparency = 0.2
raceMenuBtn.BorderSizePixel = 0
raceMenuBtn.Font = Enum.Font.GothamBold
raceMenuBtn.TextSize = 13
raceMenuBtn.TextColor3 = Color3.fromRGB(240, 244, 252)
raceMenuBtn.Text = "Menu"
raceMenuBtn.ZIndex = 12
raceMenuBtn.Parent = hudSafeRoot

local raceMenuBtnCorner = Instance.new("UICorner")
raceMenuBtnCorner.CornerRadius = UDim.new(0, 6)
raceMenuBtnCorner.Parent = raceMenuBtn
raceMenuBtn.Activated:Connect(sendReturnToMenu)

local fpsLabel = Instance.new("TextLabel")
fpsLabel.Name = "FpsCounter"
fpsLabel.BackgroundColor3 = Color3.fromRGB(16, 22, 36)
fpsLabel.BackgroundTransparency = 0.35
fpsLabel.BorderSizePixel = 0
fpsLabel.Position = UDim2.fromOffset(108, 8)
fpsLabel.Size = UDim2.fromOffset(78, 28)
fpsLabel.Font = Enum.Font.Code
fpsLabel.TextSize = 13
fpsLabel.TextColor3 = Color3.fromRGB(145, 240, 170)
fpsLabel.Text = "60 FPS"
fpsLabel.ZIndex = 12
fpsLabel.Parent = hudSafeRoot

local fpsCorner = Instance.new("UICorner")
fpsCorner.CornerRadius = UDim.new(0, 6)
fpsCorner.Parent = fpsLabel

local fpsSampleAccum = 0.0
local fpsSampleFrames = 0

-- Bindable Element #5: Top-Left Player Icon List (race_gui_base.cpp:L785-L1096)
local playerIconRoot = Instance.new("Frame")
playerIconRoot.Name = "PlayerIconsList"
playerIconRoot.BackgroundTransparency = 1
playerIconRoot.BorderSizePixel = 0
playerIconRoot.Parent = hudSafeRoot

type PlayerIconRow = {
	rowFrame: Frame,
	highlightFrame: ImageLabel,
	icon: ImageLabel,
}
local playerIconRows: { PlayerIconRow } = {}

local function getOrCreatePlayerIconRow(idx: number): PlayerIconRow
	local existing = playerIconRows[idx]
	if existing then
		return existing
	end
	local rowFrame = Instance.new("Frame")
	rowFrame.Name = "PlayerRow_" .. tostring(idx)
	rowFrame.BackgroundTransparency = 1
	rowFrame.BorderSizePixel = 0
	rowFrame.Parent = playerIconRoot

	local highlight = Instance.new("ImageLabel")
	highlight.Name = "LocalHighlight"
	highlight.BackgroundTransparency = 1
	highlight.BorderSizePixel = 0
	highlight.Position = UDim2.fromOffset(-6, -6)
	highlight.Size = UDim2.new(1, 12, 1, 12)
	highlight.Image = ICONS_FRAME_ASSET
	highlight.ImageColor3 = Color3.fromRGB(255, 70, 70)
	highlight.ScaleType = Enum.ScaleType.Fit
	highlight.ZIndex = 2
	highlight.Visible = false
	highlight.Parent = rowFrame

	local icon = Instance.new("ImageLabel")
	icon.Name = "KartIcon"
	icon.BackgroundTransparency = 1
	icon.BorderSizePixel = 0
	icon.Size = UDim2.fromScale(1, 1)
	icon.Image = TUX_ICON_ASSET
	icon.ScaleType = Enum.ScaleType.Fit
	icon.ZIndex = 3
	icon.Parent = rowFrame

	local row: PlayerIconRow = {
		rowFrame = rowFrame,
		highlightFrame = highlight,
		icon = icon,
	}
	playerIconRows[idx] = row
	return row
end

createBlockedSlot(playerIconRoot, "PlungerBadgeSlot", "Blocked: Plunger / Attachment unbuilt (P1)")
createBlockedSlot(playerIconRoot, "AttachmentBadgeSlot", "Blocked: Attachment unbuilt (P1)")

-- Bindable Element #9: Top-Center Held Powerup Icons & Count (race_gui_base.cpp:L380-L456)
local powerupRoot = Instance.new("Frame")
powerupRoot.Name = "PowerupIconsRoot"
powerupRoot.BackgroundTransparency = 1
powerupRoot.BorderSizePixel = 0
powerupRoot.Size = UDim2.fromScale(1, 1)
powerupRoot.Visible = false
powerupRoot.ZIndex = 4
powerupRoot.Parent = hudSafeRoot

type PowerupSlotWidget = {
	frame: Frame,
	image: ImageLabel,
	fallbackLabel: TextLabel,
}
local powerupSlots: { PowerupSlotWidget } = table.create(RaceHudMath.POWERUP_MAX_STACK)
for i = 1, RaceHudMath.POWERUP_MAX_STACK do
	local slotFrame = Instance.new("Frame")
	slotFrame.Name = "PowerupIcon_" .. tostring(i)
	slotFrame.BackgroundColor3 = Color3.fromRGB(22, 28, 42)
	slotFrame.BackgroundTransparency = 0.25
	slotFrame.BorderSizePixel = 0
	slotFrame.Visible = false
	slotFrame.ZIndex = 4 + i
	slotFrame.Parent = powerupRoot

	local frameBg = Instance.new("ImageLabel")
	frameBg.Name = "IconsFrame"
	frameBg.BackgroundTransparency = 1
	frameBg.BorderSizePixel = 0
	frameBg.Size = UDim2.fromScale(1, 1)
	frameBg.Image = ICONS_FRAME_ASSET
	frameBg.ScaleType = Enum.ScaleType.Fit
	frameBg.ZIndex = 4 + i
	frameBg.Parent = slotFrame

	local img = Instance.new("ImageLabel")
	img.Name = "Icon"
	img.BackgroundTransparency = 1
	img.BorderSizePixel = 0
	img.Size = UDim2.fromScale(1, 1)
	img.ScaleType = Enum.ScaleType.Fit
	img.ZIndex = 5 + i
	img.Parent = slotFrame

	local lbl = Instance.new("TextLabel")
	lbl.Name = "FallbackName"
	lbl.BackgroundTransparency = 1
	lbl.Size = UDim2.fromScale(0.9, 0.9)
	lbl.Position = UDim2.fromScale(0.05, 0.05)
	lbl.Font = Enum.Font.GothamBold
	lbl.TextColor3 = Color3.fromRGB(255, 235, 130)
	lbl.TextStrokeTransparency = 0.2
	lbl.TextScaled = true
	lbl.Text = ""
	lbl.ZIndex = 6 + i
	lbl.Parent = slotFrame

	powerupSlots[i] = {
		frame = slotFrame,
		image = img,
		fallbackLabel = lbl,
	}
end

local powerupCountLabel = Instance.new("TextLabel")
powerupCountLabel.Name = "PowerupManyCount"
powerupCountLabel.BackgroundTransparency = 1
powerupCountLabel.Font = Enum.Font.GothamBlack
powerupCountLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
powerupCountLabel.TextStrokeColor3 = Color3.fromRGB(10, 12, 16)
powerupCountLabel.TextStrokeTransparency = 0.0
powerupCountLabel.TextXAlignment = Enum.TextXAlignment.Left
powerupCountLabel.TextYAlignment = Enum.TextYAlignment.Center
powerupCountLabel.TextScaled = true
powerupCountLabel.Visible = false
powerupCountLabel.ZIndex = 12
powerupCountLabel.Parent = powerupRoot

-- Bindable Element #6: Bottom-Left Minimap (race_gui.cpp:L171-L266, L564-L784, graph.cpp:L590-L595)
local minimapRoot = Instance.new("Frame")
minimapRoot.Name = "MiniMap"
minimapRoot.BackgroundColor3 = Color3.fromRGB(16, 20, 28)
minimapRoot.BackgroundTransparency = 0.55
minimapRoot.BorderSizePixel = 0
minimapRoot.ClipsDescendants = false
minimapRoot.Parent = hudSafeRoot

local minimapBorder = Instance.new("UIStroke")
minimapBorder.Color = Color3.fromRGB(225, 232, 245)
minimapBorder.Transparency = 0.45
minimapBorder.Thickness = 1.5
minimapBorder.Parent = minimapRoot

local minimapCorner = Instance.new("UICorner")
minimapCorner.CornerRadius = UDim.new(0, 6)
minimapCorner.Parent = minimapRoot

local function getActiveTrack()
	local rawId = Workspace:GetAttribute("OpenKartActiveTrack")
	return TrackRegistry.get(if type(rawId) == "string" then rawId else TrackRegistry.DEFAULT_TRACK_ID)
end

local activeHudTrack = getActiveTrack()
local drivelineSegments: { Frame } = {}
local branchSegments: { { seg: Frame, a: { x: number, z: number }, b: { x: number, z: number } } } = {}
local quadDots: { Frame } = {}

local function rebuildMinimapGeometry()
	for _, seg in drivelineSegments do
		seg:Destroy()
	end
	table.clear(drivelineSegments)
	for _, b in branchSegments do
		b.seg:Destroy()
	end
	table.clear(branchSegments)
	for _, qd in quadDots do
		qd:Destroy()
	end
	table.clear(quadDots)

	local outlineCount = math.max(0, #activeHudTrack.drivelineQuadCenters - 1)
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

	local branches = activeHudTrack.drivelineBranches
	if branches ~= nil then
		for bIdx, br in branches do
			for sIdx = 1, math.max(0, #br.points - 1) do
				local seg = Instance.new("Frame")
				seg.Name = string.format("BranchSeg_%d_%d", bIdx, sIdx)
				seg.AnchorPoint = Vector2.new(0.5, 0.5)
				seg.BackgroundColor3 = Color3.fromRGB(220, 226, 238)
				seg.BackgroundTransparency = 0.25
				seg.BorderSizePixel = 0
				seg.ZIndex = 2
				seg.Parent = minimapRoot
				table.insert(branchSegments, {
					seg = seg,
					a = br.points[sIdx],
					b = br.points[sIdx + 1],
				})
			end
		end
	end

	for i = 1, #activeHudTrack.drivelineQuadCenters do
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
end

rebuildMinimapGeometry()

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

local remoteMinimapMarkers: { [string]: Frame } = {}

local function getOrCreateRemoteMinimapMarker(id: string): Frame
	local existing = remoteMinimapMarkers[id]
	if existing then
		return existing
	end
	local marker = Instance.new("Frame")
	marker.Name = "RemoteKartDot_" .. id
	marker.AnchorPoint = Vector2.new(0.5, 0.5)
	marker.BackgroundColor3 = Color3.fromRGB(115, 195, 255)
	marker.BorderSizePixel = 0
	marker.ZIndex = 4
	marker.Parent = minimapRoot

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = marker

	local icon = Instance.new("ImageLabel")
	icon.Name = "KartIcon"
	icon.BackgroundTransparency = 1
	icon.BorderSizePixel = 0
	icon.Size = UDim2.fromScale(1, 1)
	icon.Image = TUX_ICON_ASSET
	icon.ScaleType = Enum.ScaleType.Fit
	icon.ZIndex = 5
	icon.Parent = marker

	remoteMinimapMarkers[id] = marker
	return marker
end

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
footer.Parent = hudSafeRoot

-- Explicitly inactive blocked RaceGUI / RaceGUIBase elements per docs/hud-spec.md & docs/port-map.md
local blockedSlots = {
	{ "LiveDifferenceSlot", "Blocked: LinearWorld / GhostReplay unbuilt" },
	{ "GoalBannerSlot", "Blocked: SoccerWorld unbuilt" },
	{ "MessagesSlot", "Blocked: World / Item event feed unbuilt" },
	{ "MusicDescriptionSlot", "Blocked: MusicManager presentation unbuilt" },
	{ "PlungerFaceSlot", "Blocked: Plunger / Attachment + external plungerface.png" },
}
for _, spec in blockedSlots do
	createBlockedSlot(gui, spec[1], spec[2])
end

local arenaBounds: RaceHudMath.MinimapBounds = {
	minX = activeHudTrack.minimapBounds.minX,
	maxX = activeHudTrack.minimapBounds.maxX,
	minZ = activeHudTrack.minimapBounds.minZ,
	maxZ = activeHudTrack.minimapBounds.maxZ,
	range = activeHudTrack.minimapBounds.range,
}

local lastViewportW = -1
local lastViewportH = -1

Workspace:GetAttributeChangedSignal("OpenKartActiveTrack"):Connect(function()
	activeHudTrack = getActiveTrack()
	arenaBounds = {
		minX = activeHudTrack.minimapBounds.minX,
		maxX = activeHudTrack.minimapBounds.maxX,
		minZ = activeHudTrack.minimapBounds.minZ,
		maxZ = activeHudTrack.minimapBounds.maxZ,
		range = activeHudTrack.minimapBounds.range,
	}
	rebuildMinimapGeometry()
	lastViewportW = -1
end)
local lastMinimapMode = -1
local lastTotalKarts = -1
local cachedSpeedRect: RaceHudMath.HudRect = RaceHudMath.computeSpeedometerRect(800, 450)
local cachedRankAnchor: RaceHudMath.RankAnchor = RaceHudMath.computeRankAnchor(cachedSpeedRect)
local cachedMinimapLayout: RaceHudMath.MinimapLayout = RaceHudMath.computeMinimapLayout(800, 450, 0)

local rankAnimState: "NONE" | "SMALLER" | "BIGGER" = "NONE"
local rankAnimDuration = 0.0
local lastRank = 1
local shownRank = 1

local timerUpdateAccum = 0.1
local lastTimerText = ""
local lastSpeedRatio = -1.0
local lastNitroRatio = -1.0
local lastNitroUsing: boolean? = nil
local lastNitroGateOpen: boolean? = nil
local lastRankText = ""
local lastRankSizePx = -1
local lastMmX = math.huge
local lastMmY = math.huge
local lastPowerupId = -1
local lastPowerupCount = -1
local lastPowerupW = -1
local lastPowerupH = -1
local lastVisTimer: boolean? = nil
local lastVisLaps: boolean? = nil
local lastVisSpeedEnergy: boolean? = nil
local lastVisRankDigit: boolean? = nil
local lastVisPlayerIcons: boolean? = nil
local lastVisMiniMap: boolean? = nil
local lastVisPowerups: boolean? = nil
local lastHudLap = -2
local lapToastText = ""
local lapToastExpirySec = 0.0
local subToastText = ""
local subToastExpirySec = 0.0
local wasStartBoostFired = false
local wasPenaltyShown = false

local function getIsTouchLayout(): boolean
	if RunService:IsStudio() and localPlayer:GetAttribute("ForceTouchPreview") == true then
		return true
	end
	return UserInputService.TouchEnabled and #UserInputService:GetConnectedGamepads() == 0
end

local lastTouchLayout: boolean? = nil

local function layoutStaticElements(vw: number, vh: number, minimapVisible: boolean, totalKarts: number, _rank: number)
	cachedSpeedRect = RaceHudMath.computeSpeedometerRect(vw, vh)
	cachedRankAnchor = RaceHudMath.computeRankAnchor(cachedSpeedRect)
	applyRect(speedRoot, cachedSpeedRect)
	applyRect(energyRoot, RaceHudMath.computeEnergyMeterRect(vw, vh))
	applyRect(timerLabel, RaceHudMath.computeTimerRect(vw, vh))
	applyRect(lapLabel, RaceHudMath.computeLapRect(vw, vh))
	local cdRect = RaceHudMath.computeCountdownAnchor(vw, vh)
	applyRect(countdownLabel, cdRect)
	subBannerLabel.Position = UDim2.fromOffset(cdRect.x, cdRect.y + cdRect.height + 6)
	subBannerLabel.Size = UDim2.fromOffset(cdRect.width, math.max(24, math.floor(cdRect.height * 0.36)))

	local isTouchMode = getIsTouchLayout()
	lastTouchLayout = isTouchMode
	cachedMinimapLayout = RaceHudMath.computeMinimapLayout(vw, vh, 0, isTouchMode)
	if ClientSettingsState.get().ui.minimapDisplay == 2 then
		local baseW = cachedMinimapLayout.width
		local baseH = cachedMinimapLayout.height
		local newW = math.floor(baseW * 1.35)
		local newH = math.floor(baseH * 1.35)
		cachedMinimapLayout.width = newW
		cachedMinimapLayout.height = newH
		cachedMinimapLayout.y = math.max(8, cachedMinimapLayout.y - (newH - baseH))
	end
	minimapRoot.Position = UDim2.fromOffset(cachedMinimapLayout.x, cachedMinimapLayout.y)
	minimapRoot.Size = UDim2.fromOffset(cachedMinimapLayout.width, cachedMinimapLayout.height)
	mmKartMarker.Size = UDim2.fromOffset(cachedMinimapLayout.playerIconSize, cachedMinimapLayout.playerIconSize)

	local bottomMargin = if minimapVisible and not isTouchMode
		then (cachedMinimapLayout.height + cachedMinimapLayout.mapBottom)
		else 0
	local topRect = RaceHudMath.computePlayerIconRect(vw, vh, totalKarts, bottomMargin, 1, true)
	playerIconRoot.Position = UDim2.fromOffset(topRect.x, math.max(topRect.y, 44))
	playerIconRoot.Size = UDim2.fromOffset(topRect.width, math.max(topRect.height, totalKarts * (topRect.height + 2)))

	-- Project canonical driveline quad centers through RaceHudMath.projectToMinimap
	local centers = activeHudTrack.drivelineQuadCenters
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
	for _, bs in branchSegments do
		local ax, ay = RaceHudMath.projectToMinimap(
			bs.a.x,
			bs.a.z,
			arenaBounds,
			cachedMinimapLayout.width,
			cachedMinimapLayout.height,
			false
		)
		local bx, by = RaceHudMath.projectToMinimap(
			bs.b.x,
			bs.b.z,
			arenaBounds,
			cachedMinimapLayout.width,
			cachedMinimapLayout.height,
			false
		)
		setLineSegment(bs.seg, ax, ay, bx, by, 2)
	end
	local sx, sy = RaceHudMath.projectToMinimap(
		activeHudTrack.startPos.x,
		activeHudTrack.startPos.z,
		arenaBounds,
		cachedMinimapLayout.width,
		cachedMinimapLayout.height,
		false
	)
	startTick.Position = UDim2.fromOffset(sx, sy)
end

RunService:BindToRenderStep("OpenKartGameHud", Enum.RenderPriority.Camera.Value + 2, function(dt: number)
	local inRacing = ClientSessionState.get().phase == "RACING"
	if gui.Enabled ~= inRacing then
		gui.Enabled = inRacing
	end
	if not inRacing then
		return
	end
	debug.profilebegin("OpenKart_GameHud")
	local userSettings = ClientSettingsState.get()
	fpsLabel.Visible = userSettings.ui.showFps
	if userSettings.ui.showFps and dt > 0 then
		fpsSampleAccum += dt
		fpsSampleFrames += 1
		if fpsSampleAccum >= 0.25 then
			local fps = math.floor(fpsSampleFrames / fpsSampleAccum + 0.5)
			fpsLabel.Text = string.format("%d FPS", fps)
			fpsSampleAccum = 0.0
			fpsSampleFrames = 0
		end
	end
	local renderHud = HudState.get()
	local standingsInput: { Standings.StandingsEntry } = if renderHud.standingsEntries ~= nil
			and #renderHud.standingsEntries > 0
		then renderHud.standingsEntries
		else {
			{
				id = "local",
				lap = renderHud.lap,
				checkpoint = renderHud.checkpoint,
				distance = renderHud.distance,
				initialPosition = 1,
			},
		}
	local rank, totalKarts = Standings.getRankForId(standingsInput, "local")
	local inRacePhase = renderHud.ready and RaceState.isRacePhase(renderHud.racePhase :: RaceState.RacePhase)
	local vis = RaceHudMath.getModeVisibility(renderHud.raceMode, {
		isRacePhase = inRacePhase,
		numKarts = totalKarts,
		hasNavMesh = true,
	})
	vis.showMiniMap = vis.showMiniMap and (userSettings.ui.minimapDisplay ~= 0)

	local currentTouchLayout = getIsTouchLayout()
	local camera = Workspace.CurrentCamera
	if camera then
		local padX, padY = updateSafeRootBounds()
		local vp = camera.ViewportSize
		local vw = math.max(1, math.floor(vp.X - padX))
		local vh = math.max(1, math.floor(vp.Y - padY))
		local mmFlag = if vis.showMiniMap then userSettings.ui.minimapDisplay else 0
		if
			vw > 0
			and vh > 0
			and (
				vw ~= lastViewportW
				or vh ~= lastViewportH
				or mmFlag ~= lastMinimapMode
				or totalKarts ~= lastTotalKarts
				or currentTouchLayout ~= lastTouchLayout
			)
		then
			lastViewportW = vw
			lastViewportH = vh
			lastMinimapMode = mmFlag
			lastTotalKarts = totalKarts
			layoutStaticElements(vw, vh, vis.showMiniMap, totalKarts, rank)
		end
	end

	-- Apply mode-conditional visibility only on changes (race_gui.cpp:L314-L407)
	-- Upstream hides speed/energy/rank when multitouch controls are active (race_gui.cpp:L399-L402).
	local showSpeedEnergy = vis.showSpeedAndEnergy and not currentTouchLayout
	if lastVisSpeedEnergy ~= showSpeedEnergy then
		lastVisSpeedEnergy = showSpeedEnergy
		speedRoot.Visible = showSpeedEnergy
		energyRoot.Visible = showSpeedEnergy
	end
	if lastVisTimer ~= vis.showTimer then
		lastVisTimer = vis.showTimer
		timerLabel.Visible = vis.showTimer
	end
	if lastVisLaps ~= vis.showLaps then
		lastVisLaps = vis.showLaps
		lapLabel.Visible = vis.showLaps
	end
	local showRank = showSpeedEnergy and vis.showRankDigit
	if lastVisRankDigit ~= showRank then
		lastVisRankDigit = showRank
		rankLabel.Visible = showRank
	end
	if lastVisPlayerIcons ~= vis.showPlayerIcons then
		lastVisPlayerIcons = vis.showPlayerIcons
		playerIconRoot.Visible = vis.showPlayerIcons
	end
	if lastVisMiniMap ~= vis.showMiniMap then
		lastVisMiniMap = vis.showMiniMap
		minimapRoot.Visible = vis.showMiniMap
	end

	if not renderHud.ready then
		if lastSpeedRatio ~= 0.0 then
			lastSpeedRatio = 0.0
			speedHalf1.container.Visible = false
			speedHalf2.container.Visible = false
		end
		if lastNitroRatio ~= 0.0 then
			lastNitroRatio = 0.0
			energyFill.container.Visible = false
		end
		debug.profileend()
		return
	end

	-- 1) Elapsed race timer (deterministic from raceTick / finishTimeSec) + Lap Counter + Countdown / Finish Banners
	local nowSec = os.clock()
	if vis.showTimer then
		timerUpdateAccum += dt
		if timerUpdateAccum >= 0.05 then
			timerUpdateAccum %= 0.05
			local elapsedSec = renderHud.finishTimeSec or renderHud.raceElapsedSec
			local nextText = RaceHudMath.formatRaceTime(elapsedSec)
			if nextText ~= lastTimerText then
				lastTimerText = nextText
				timerLabel.Text = nextText
			end
		end
	end
	if vis.showLaps then
		lapLabel.Text = RaceHudMath.formatLapText(renderHud.lap, renderHud.totalLaps)
	end

	-- Lap increment toast (linear_world.cpp:L414-L461)
	if renderHud.lap > lastHudLap then
		if lastHudLap >= 0 and renderHud.lap > 0 and not renderHud.raceFinished then
			if renderHud.lap + 1 == renderHud.totalLaps then
				lapToastText = "FINAL LAP!"
				lapToastExpirySec = nowSec + 3.0
			else
				lapToastText = string.format("LAP %d", renderHud.lap + 1)
				lapToastExpirySec = nowSec + 2.0
			end
		end
		lastHudLap = renderHud.lap
	elseif renderHud.lap < lastHudLap then
		lastHudLap = renderHud.lap
		lapToastText = ""
		lapToastExpirySec = 0.0
	end

	-- Start boost / false-start toast
	if renderHud.startupBoostFired and renderHud.startupBoostMps > 0 and not wasStartBoostFired then
		wasStartBoostFired = true
		subToastText = "START BOOST!"
		subToastExpirySec = nowSec + 1.5
	elseif not renderHud.startupBoostFired then
		wasStartBoostFired = false
	end
	if renderHud.startupPenaltyTicks > 0 and not wasPenaltyShown then
		wasPenaltyShown = true
		subToastText = "FALSE START!"
		subToastExpirySec = nowSec + 1.5
	elseif
		renderHud.startupPenaltyTicks == 0 and RaceState.isStartPhase(renderHud.racePhase :: RaceState.RacePhase)
	then
		wasPenaltyShown = false
	end

	local cdText = RaceState.getCountdownText(renderHud.racePhase :: RaceState.RacePhase)
	if cdText ~= nil then
		countdownLabel.Visible = true
		countdownLabel.Text = cdText
		if cdText == "Go!" then
			countdownLabel.TextColor3 = Color3.fromRGB(95, 255, 130)
		elseif cdText == "Set!" then
			countdownLabel.TextColor3 = Color3.fromRGB(255, 225, 80)
		else
			countdownLabel.TextColor3 = Color3.fromRGB(255, 100, 80)
		end
	elseif nowSec < lapToastExpirySec and lapToastText ~= "" then
		countdownLabel.Visible = true
		countdownLabel.Text = lapToastText
		countdownLabel.TextColor3 = if lapToastText == "FINAL LAP!"
			then Color3.fromRGB(255, 120, 95)
			else Color3.fromRGB(255, 235, 140)
	else
		countdownLabel.Visible = false
	end

	if nowSec < subToastExpirySec and subToastText ~= "" then
		subBannerLabel.Visible = true
		subBannerLabel.Text = subToastText
		subBannerLabel.TextColor3 = if subToastText == "FALSE START!"
			then Color3.fromRGB(255, 95, 95)
			else Color3.fromRGB(255, 220, 75)
	else
		subBannerLabel.Visible = false
	end

	if renderHud.raceFinished then
		finishCard.Visible = true
		local finSec = renderHud.finishTimeSec or renderHud.raceElapsedSec
		finishRankLabel.Text =
			string.format("%s Place — %s", RaceHudMath.formatOrdinal(rank), RaceHudMath.formatRaceTime(finSec))
		local sortedFinish = Standings.compute(standingsInput)
		local lines: { string } = {}
		for _, r in sortedFinish do
			local label = if r.id == "local" or r.id == tostring(renderHud.localKartId) then "You" else r.id
			local status = if r.entry.finished == true and r.entry.finishTime ~= nil
				then RaceHudMath.formatRaceTime(r.entry.finishTime)
				else string.format(
					"Lap %d/%d",
					math.clamp(r.entry.lap + 1, 1, renderHud.totalLaps),
					renderHud.totalLaps
				)
			table.insert(lines, string.format("%s  %-10s  %s", RaceHudMath.formatOrdinal(r.rank), label, status))
		end
		finishStandingsLabel.Text = table.concat(lines, "\n")
	else
		finishCard.Visible = false
	end

	-- 2) Speedometer CanvasGroup masks updated only when snapped ratio changes
	if showSpeedEnergy then
		local speedRatio = RaceHudMath.snapSpeedRatio(renderHud.speedMps)
		if math.abs(speedRatio - lastSpeedRatio) > 1e-4 then
			lastSpeedRatio = speedRatio
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
		end

		-- 3) Nitro Energy Meter CanvasGroup mask updated only when ratio, nitroUsing, or nitroGateOpen toggles
		local nitroRatio = RaceHudMath.snapNitroRatio(renderHud.nitroEnergy, renderHud.nitroMaxEnergy)
		if
			math.abs(nitroRatio - lastNitroRatio) > 1e-4
			or renderHud.nitroUsing ~= lastNitroUsing
			or renderHud.nitroGateOpen ~= lastNitroGateOpen
		then
			lastNitroRatio = nitroRatio
			lastNitroUsing = renderHud.nitroUsing
			lastNitroGateOpen = renderHud.nitroGateOpen
			if nitroRatio <= 0.0 then
				energyFill.container.Visible = false
			else
				energyFill.container.Visible = true
				local isGatedClosed = (not renderHud.nitroUsing) and not renderHud.nitroGateOpen
				if isGatedClosed then
					energyFill.image.Image = GAUGE_FULL_ASSET
					energyFill.image.ImageTransparency = 0.55
					energyFill.image.ImageColor3 = Color3.fromRGB(145, 160, 180)
				else
					energyFill.image.Image = if renderHud.nitroUsing then GAUGE_FULL_BRIGHT_ASSET else GAUGE_FULL_ASSET
					energyFill.image.ImageTransparency = 0
					energyFill.image.ImageColor3 = Color3.fromRGB(255, 255, 255)
				end
				local currDeg = RaceHudMath.computeNitroSweepAngleDeg(nitroRatio)
				energyFill.gradStart.Rotation = currDeg - 90.0
				energyFill.gradEnd.Rotation = RaceHudMath.NITRO_START_DEG + 90.0
			end
		end
	end

	-- 4) Gauge-center rank digit + STK shrink/expand animation (updated only on change)
	if showRank then
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

		local sizePx = math.max(10, math.floor(cachedRankAnchor.fontSize * scale))
		local rankText = tostring(shownRank)
		if sizePx ~= lastRankSizePx or rankText ~= lastRankText then
			lastRankSizePx = sizePx
			lastRankText = rankText
			rankLabel.Position = UDim2.fromOffset(cachedRankAnchor.x, cachedRankAnchor.y)
			rankLabel.Size = UDim2.fromOffset(sizePx * 2, sizePx)
			rankLabel.TextSize = sizePx
			rankLabel.Text = rankText
		end
	end

	-- 5) Minimap interpolated kart dots (local + RemoteInterp remote karts)
	if vis.showMiniMap then
		local kx, ky = RaceHudMath.projectToMinimap(
			renderHud.pos.x,
			renderHud.pos.z,
			arenaBounds,
			cachedMinimapLayout.width,
			cachedMinimapLayout.height,
			false
		)
		if math.abs(kx - lastMmX) >= 0.25 or math.abs(ky - lastMmY) >= 0.25 then
			lastMmX = kx
			lastMmY = ky
			mmKartMarker.Position = UDim2.fromOffset(kx, ky)
		end

		local seenRemoteMm: { [string]: boolean } = {}
		if renderHud.remotePoses ~= nil then
			for _, rp in renderHud.remotePoses do
				seenRemoteMm[rp.id] = true
				local marker = getOrCreateRemoteMinimapMarker(rp.id)
				marker.Visible = true
				marker.Size = UDim2.fromOffset(cachedMinimapLayout.aiIconSize, cachedMinimapLayout.aiIconSize)
				local rx, ry = RaceHudMath.projectToMinimap(
					rp.x,
					rp.z,
					arenaBounds,
					cachedMinimapLayout.width,
					cachedMinimapLayout.height,
					false
				)
				marker.Position = UDim2.fromOffset(rx, ry)
			end
		end
		for rid, marker in remoteMinimapMarkers do
			if not seenRemoteMm[rid] then
				marker.Visible = false
			end
		end
	end

	-- 5b) PlayerIconsList ordered by Standings.compute rank (1st at top) with local-player highlight
	if vis.showPlayerIcons and lastViewportW > 0 and lastViewportH > 0 then
		local sortedEntries = if renderHud.standingsEntries then Standings.compute(renderHud.standingsEntries) else nil
		local count = if sortedEntries then #sortedEntries else 1
		local isTouchMode = getIsTouchLayout()
		if lastTouchLayout ~= isTouchMode then
			layoutStaticElements(lastViewportW, lastViewportH, vis.showMiniMap, count, shownRank)
		end
		local bottomMargin = if vis.showMiniMap and not isTouchMode
			then (cachedMinimapLayout.height + cachedMinimapLayout.mapBottom)
			else 0
		local playerW =
			RaceHudMath.computePlayerIconRect(lastViewportW, lastViewportH, count, bottomMargin, 1, true).width
		local aiW = math.floor(playerW * 5 / 6)
		local yOff = 0
		for idx = 1, count do
			local entry = if sortedEntries then sortedEntries[idx] else nil
			local isLocal = if entry then (entry.id == "local" or entry.id == tostring(renderHud.localKartId)) else true
			local w = if isLocal then playerW else aiW
			local row = getOrCreatePlayerIconRow(idx)
			row.rowFrame.Visible = true
			row.rowFrame.Position = UDim2.fromOffset(0, yOff)
			row.rowFrame.Size = UDim2.fromOffset(w, w)
			row.highlightFrame.Visible = isLocal
			if isLocal then
				local pulse = 0.5 + 0.5 * math.cos(os.clock() * 2.0)
				row.highlightFrame.ImageTransparency = 0.05 + 0.30 * (1.0 - pulse)
			end
			yOff += playerW + 2
		end
		for idx = count + 1, #playerIconRows do
			playerIconRows[idx].rowFrame.Visible = false
		end
	end

	-- 6) Held Powerup Icons & Count (updated only when item/count/viewport changes)
	local showHeldPowerups = vis.showPowerups and renderHud.heldPowerup > 0 and renderHud.heldPowerupCount > 0
	if lastVisPowerups ~= showHeldPowerups then
		lastVisPowerups = showHeldPowerups
		powerupRoot.Visible = showHeldPowerups
	end
	if
		showHeldPowerups
		and lastViewportW > 0
		and lastViewportH > 0
		and (
			renderHud.heldPowerup ~= lastPowerupId
			or renderHud.heldPowerupCount ~= lastPowerupCount
			or lastViewportW ~= lastPowerupW
			or lastViewportH ~= lastPowerupH
		)
	then
		lastPowerupId = renderHud.heldPowerup
		lastPowerupCount = renderHud.heldPowerupCount
		lastPowerupW = lastViewportW
		lastPowerupH = lastViewportH
		local layout = RaceHudMath.computePowerupLayout(lastViewportW, lastViewportH, renderHud.heldPowerupCount, 0)
		local iconAsset = POWERUP_ICON_ASSETS[renderHud.heldPowerup] or ""
		local powerupName = ItemTuning.POWERUP_NAMES[renderHud.heldPowerup] or "ITEM"
		for i = 1, RaceHudMath.POWERUP_MAX_STACK do
			local slot = powerupSlots[i]
			local r = layout.rects[i]
			if r ~= nil then
				slot.frame.Visible = true
				slot.frame.Position = UDim2.fromOffset(r.x, r.y)
				slot.frame.Size = UDim2.fromOffset(r.width, r.height)
				if iconAsset ~= "" then
					slot.image.Image = iconAsset
					slot.image.Visible = true
					slot.fallbackLabel.Visible = false
					slot.frame.BackgroundTransparency = 1.0
				else
					slot.image.Visible = false
					slot.fallbackLabel.Text = powerupName
					slot.fallbackLabel.Visible = true
					slot.frame.BackgroundTransparency = 0.25
				end
			else
				slot.frame.Visible = false
			end
		end
		if layout.manyText ~= nil and layout.manyRect ~= nil then
			local mr = layout.manyRect
			powerupCountLabel.Visible = true
			powerupCountLabel.Position = UDim2.fromOffset(mr.x, mr.y)
			powerupCountLabel.Size = UDim2.fromOffset(mr.width, mr.height)
			powerupCountLabel.Text = layout.manyText
		else
			powerupCountLabel.Visible = false
		end
	end

	-- 7) Plunger-in-face screen obstruction (RaceGUIBase::drawPlungerInFace, race_gui_base.cpp:L1263-L1335)
	local plungerTicks = renderHud.plungerFaceTicks
	if plungerTicks > 0 then
		plungerFaceOverlay.Visible = true
		local remSec = plungerTicks / 120.0
		local yOff = if remSec < 0.5 then -(1.0 - remSec * 2.0) * 0.65 else math.sin(remSec * 7.0) * 0.02
		local xOff = math.cos(remSec * 5.0) * 0.02
		plungerFaceOverlay.Position = UDim2.fromScale(0.5 + xOff, 0.5 + yOff)
	else
		plungerFaceOverlay.Visible = false
	end
	debug.profileend()
end)
