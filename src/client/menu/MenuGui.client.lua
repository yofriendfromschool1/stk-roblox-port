--!strict
-- SPDX-License-Identifier: GPL-3.0-or-later
-- Ported 1:1 from data/gui/screens/{main_menu,race_setup,tracks_and_gp,karts,track_info}.stkgui (STK 1.5).

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CatalogData = require(Shared.menu.CatalogData)
local ClassicSkin = require("./ClassicSkin")
local ClientSessionState = require("../ClientSessionState")
local MenuBackdrop = require("./MenuBackdrop")
local MenuFlow = require(Shared.menu.MenuFlow)
local MenuIcons = require(Shared.menu.MenuIcons)
local OptionsPanel = require("./OptionsPanel")

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui") :: PlayerGui

local gui = Instance.new("ScreenGui")
gui.Name = "OpenKartMenuGui"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.DisplayOrder = 20
gui.Parent = playerGui

local connections: { RBXScriptConnection } = {}
local function trackConn(conn: RBXScriptConnection)
	table.insert(connections, conn)
	gui:SetAttribute("ListenerCount", #connections)
end

local menuState = MenuFlow.create()
local backdrop = MenuBackdrop.create(gui)

-- Global GuiService:GetGuiInset() safe container for all interactive menu widgets
local menuSafeRoot = Instance.new("Frame")
menuSafeRoot.Name = "MenuSafeRoot"
menuSafeRoot.BackgroundTransparency = 1
menuSafeRoot.BorderSizePixel = 0
menuSafeRoot.ZIndex = 5
menuSafeRoot.Parent = gui

local function updateSafeInsets()
	local insetTL, insetBR = GuiService:GetGuiInset()
	menuSafeRoot.Position = UDim2.fromOffset(insetTL.X, insetTL.Y)
	menuSafeRoot.Size = UDim2.new(1, -(insetTL.X + insetBR.X), 1, -(insetTL.Y + insetBR.Y))
end
updateSafeInsets()

local function makeHeader(parent: Instance, titleText: string): TextLabel
	local lbl = Instance.new("TextLabel")
	lbl.Name = "Header"
	lbl.BackgroundTransparency = 1
	lbl.Position = UDim2.fromScale(0.10, 0.01)
	lbl.Size = UDim2.fromScale(0.80, 0.08)
	lbl.TextScaled = true
	lbl.TextXAlignment = Enum.TextXAlignment.Center
	lbl.Text = titleText
	lbl.ZIndex = 12
	ClassicSkin.applyHeaderGradient(lbl)
	lbl.Parent = parent
	return lbl
end

local function makeScreenFrame(name: string): Frame
	local f = Instance.new("Frame")
	f.Name = name
	f.Size = UDim2.fromScale(1, 1)
	f.BackgroundTransparency = 1
	f.Visible = false
	f.ZIndex = 6
	f.Parent = menuSafeRoot
	return f
end

local function makeBackButton(parent: Instance, onBack: () -> ()): ImageButton
	-- .stkgui: <icon-button id="back" x="1%" y="0" height="9%" icon="gui/icons/back.png"/>
	local btn = Instance.new("ImageButton")
	btn.Name = "BackButton"
	btn.Position = UDim2.fromScale(0.01, 0.01)
	btn.Size = UDim2.fromScale(0.09, 0.09)
	btn.SizeConstraint = Enum.SizeConstraint.RelativeYY
	btn.BackgroundTransparency = 1
	btn.BorderSizePixel = 0
	btn.Image = MenuIcons.Back
	btn.ScaleType = Enum.ScaleType.Fit
	btn.ZIndex = 16
	btn.Parent = parent
	trackConn(btn.Activated:Connect(onBack))
	return btn
end

-- Screen 1: MAIN MENU (main_menu.stkgui)
local menuScreen = makeScreenFrame("Screen_MENU")
local logoTitle = Instance.new("TextLabel")
logoTitle.Name = "LogoHeader"
logoTitle.BackgroundTransparency = 1
logoTitle.Position = UDim2.fromScale(0.05, 0.06)
logoTitle.Size = UDim2.fromScale(0.48, 0.16)
logoTitle.TextScaled = true
logoTitle.TextXAlignment = Enum.TextXAlignment.Left
logoTitle.Text = "OPENKART"
logoTitle.ZIndex = 12
ClassicSkin.applyHeaderGradient(logoTitle)
logoTitle.Parent = menuScreen

local topRow = Instance.new("Frame")
topRow.Name = "TopRow"
topRow.AnchorPoint = Vector2.new(0.5, 0.5)
topRow.Position = UDim2.fromScale(0.50, 0.56)
topRow.Size = UDim2.fromOffset(520, 168)
topRow.BackgroundTransparency = 1
topRow.ZIndex = 10
topRow.Parent = menuScreen

local function makeMainTopCard(
	name: string,
	label: string,
	icon: string,
	focusIcon: string,
	idx: number,
	onClick: () -> ()
)
	local btn = Instance.new("TextButton")
	btn.Name = name
	btn.Position = UDim2.fromOffset((idx - 1) * 180, 0)
	btn.Size = UDim2.fromOffset(156, 166)
	btn.BackgroundTransparency = 1
	btn.BorderSizePixel = 0
	btn.Text = ""
	btn.ZIndex = 10
	btn.Parent = topRow

	local halo = Instance.new("ImageLabel")
	halo.BackgroundTransparency = 1
	halo.Position = UDim2.fromOffset(-6, -6)
	halo.Size = UDim2.fromOffset(168, 168)
	halo.Image = MenuIcons.SkinGlassIconFocusHalo
	halo.Visible = false
	halo.ZIndex = 9
	halo.Parent = btn

	local img = Instance.new("ImageLabel")
	img.BackgroundTransparency = 1
	img.Position = UDim2.fromOffset(14, 4)
	img.Size = UDim2.fromOffset(128, 128)
	img.Image = icon
	img.ScaleType = Enum.ScaleType.Fit
	img.ZIndex = 11
	img.Parent = btn

	local txt = Instance.new("TextLabel")
	txt.BackgroundTransparency = 1
	txt.Position = UDim2.fromOffset(0, 134)
	txt.Size = UDim2.new(1, 0, 0, 28)
	txt.Font = ClassicSkin.FONT_BODY
	txt.TextSize = 16
	txt.TextColor3 = ClassicSkin.COLOR_TEXT_FOCUSED
	txt.TextStrokeTransparency = 0.35
	txt.Text = label
	txt.ZIndex = 12
	txt.Parent = btn

	trackConn(btn.MouseEnter:Connect(function()
		img.Image = focusIcon
		halo.Visible = true
	end))
	trackConn(btn.MouseLeave:Connect(function()
		img.Image = icon
		halo.Visible = false
	end))
	trackConn(btn.Activated:Connect(onClick))
end

local bottomBar = Instance.new("ImageLabel")
bottomBar.Name = "BottomBar"
bottomBar.Position = UDim2.fromScale(0, 0.80)
bottomBar.Size = UDim2.fromScale(1, 0.20)
bottomBar.BackgroundTransparency = 1
bottomBar.Image = MenuIcons.SkinBottomBar
bottomBar.ScaleType = Enum.ScaleType.Stretch
bottomBar.ZIndex = 8
bottomBar.Parent = menuScreen

local subtitle = Instance.new("TextLabel")
subtitle.Name = "Attribution"
subtitle.BackgroundTransparency = 1
subtitle.Position = UDim2.fromScale(0.03, 0.25)
subtitle.Size = UDim2.fromScale(0.50, 0.55)
subtitle.Font = ClassicSkin.FONT_BODY
subtitle.TextSize = 15
subtitle.TextXAlignment = Enum.TextXAlignment.Left
subtitle.TextColor3 = ClassicSkin.COLOR_TEXT_NEUTRAL
subtitle.Text = "Unofficial SuperTuxKart 1.5 Port (GPLv3-or-later)"
subtitle.ZIndex = 10
subtitle.Parent = bottomBar

local bottomRow = Instance.new("Frame")
bottomRow.Name = "BottomRow"
bottomRow.Position = UDim2.fromScale(0.58, 0.12)
bottomRow.Size = UDim2.fromScale(0.40, 0.80)
bottomRow.BackgroundTransparency = 1
bottomRow.ZIndex = 10
bottomRow.Parent = bottomBar

local function makeMainBottomBtn(name: string, label: string, icon: string, idx: number, onClick: () -> ())
	local btn = Instance.new("TextButton")
	btn.Name = name
	btn.Position = UDim2.fromOffset((idx - 1) * 96, 4)
	btn.Size = UDim2.fromOffset(82, 86)
	btn.BackgroundTransparency = 1
	btn.BorderSizePixel = 0
	btn.Text = ""
	btn.ZIndex = 10
	btn.Parent = bottomRow

	local img = Instance.new("ImageLabel")
	img.BackgroundTransparency = 1
	img.Position = UDim2.fromOffset(9, 2)
	img.Size = UDim2.fromOffset(64, 64)
	img.Image = icon
	img.ScaleType = Enum.ScaleType.Fit
	img.ZIndex = 11
	img.Parent = btn

	local txt = Instance.new("TextLabel")
	txt.BackgroundTransparency = 1
	txt.Position = UDim2.fromOffset(0, 66)
	txt.Size = UDim2.new(1, 0, 0, 18)
	txt.Font = ClassicSkin.FONT_BODY
	txt.TextSize = 13
	txt.TextColor3 = ClassicSkin.COLOR_TEXT_NEUTRAL
	txt.Text = label
	txt.ZIndex = 11
	txt.Parent = btn

	trackConn(btn.Activated:Connect(onClick))
end

-- Screen 2: RACE SETUP / MODE (race_setup.stkgui)
local modeScreen = makeScreenFrame("Screen_MODE")
makeHeader(modeScreen, "Race Setup")

local diffHeader = Instance.new("TextLabel")
diffHeader.BackgroundTransparency = 1
diffHeader.Position = UDim2.fromScale(0.02, 0.11)
diffHeader.Size = UDim2.fromScale(0.96, 0.04)
diffHeader.Font = ClassicSkin.FONT_BODY
diffHeader.TextScaled = true
diffHeader.TextXAlignment = Enum.TextXAlignment.Left
diffHeader.TextColor3 = ClassicSkin.COLOR_TEXT_FOCUSED
diffHeader.TextStrokeTransparency = 0.35
diffHeader.Text = "Select a difficulty"
diffHeader.ZIndex = 12
diffHeader.Parent = modeScreen

local diffBox =
	ClassicSkin.makeGlassBox(modeScreen, "DifficultyBox", UDim2.fromScale(0.02, 0.16), UDim2.fromScale(0.96, 0.29), 8)

local gameModeHeader = Instance.new("TextLabel")
gameModeHeader.BackgroundTransparency = 1
gameModeHeader.Position = UDim2.fromScale(0.02, 0.47)
gameModeHeader.Size = UDim2.fromScale(0.96, 0.04)
gameModeHeader.Font = ClassicSkin.FONT_BODY
gameModeHeader.TextScaled = true
gameModeHeader.TextXAlignment = Enum.TextXAlignment.Left
gameModeHeader.TextColor3 = ClassicSkin.COLOR_TEXT_FOCUSED
gameModeHeader.TextStrokeTransparency = 0.35
gameModeHeader.Text = "Select a game mode"
gameModeHeader.ZIndex = 12
gameModeHeader.Parent = modeScreen

local gameModeBox =
	ClassicSkin.makeGlassBox(modeScreen, "GameModeBox", UDim2.fromScale(0.02, 0.52), UDim2.fromScale(0.96, 0.44), 8)

-- Screen 3: TRACK SELECT (tracks_and_gp.stkgui)
local trackScreen = makeScreenFrame("Screen_TRACK")
makeHeader(trackScreen, "All Tracks")
local trackBox =
	ClassicSkin.makeGlassBox(trackScreen, "TrackBox", UDim2.fromScale(0.02, 0.12), UDim2.fromScale(0.96, 0.84), 8)

-- Screen 4: KART SELECT (karts.stkgui)
local kartScreen = makeScreenFrame("Screen_KART")
makeHeader(kartScreen, "Choose a Kart")
local kartBox =
	ClassicSkin.makeGlassBox(kartScreen, "KartBox", UDim2.fromScale(0.02, 0.62), UDim2.fromScale(0.96, 0.35), 8)

-- Screen 5: TRACK INFO / CONFIG (track_info.stkgui)
local configScreen = makeScreenFrame("Screen_CONFIG")
local configTrackHeader = makeHeader(configScreen, "Shifting Sands")
local configCard =
	ClassicSkin.makeGlassBox(configScreen, "ConfigCard", UDim2.fromScale(0.02, 0.11), UDim2.fromScale(0.68, 0.85), 8)
local configRightCol = Instance.new("Frame")
configRightCol.Name = "RightPane"
configRightCol.Position = UDim2.fromScale(0.72, 0.11)
configRightCol.Size = UDim2.fromScale(0.26, 0.85)
configRightCol.BackgroundTransparency = 1
configRightCol.ZIndex = 8
configRightCol.Parent = configScreen

-- Screen 6: LOADING
local loadingScreen = makeScreenFrame("Screen_LOADING")
local loadingLbl = makeHeader(loadingScreen, "Loading...")
loadingLbl.Position = UDim2.fromScale(0.1, 0.44)
loadingLbl.Size = UDim2.fromScale(0.8, 0.12)

-- Screen 7: OPTIONS (options_*.stkgui)
local optionsScreen = makeScreenFrame("Screen_OPTIONS")
makeHeader(optionsScreen, "SuperTuxKart Options")
local optionsPanel = OptionsPanel.create(optionsScreen, trackConn)

-- Screen 8: ABOUT
local aboutScreen = makeScreenFrame("Screen_ABOUT")
makeHeader(aboutScreen, "About OpenKart")
local aboutBox =
	ClassicSkin.makeGlassBox(aboutScreen, "AboutBox", UDim2.fromScale(0.06, 0.13), UDim2.fromScale(0.88, 0.80), 8)
local aboutBody = Instance.new("TextLabel")
aboutBody.Name = "AboutText"
aboutBody.Position = UDim2.fromOffset(24, 20)
aboutBody.Size = UDim2.new(1, -48, 1, -40)
aboutBody.BackgroundTransparency = 1
aboutBody.Font = ClassicSkin.FONT_BODY
aboutBody.TextSize = 17
aboutBody.TextWrapped = true
aboutBody.TextXAlignment = Enum.TextXAlignment.Left
aboutBody.TextYAlignment = Enum.TextYAlignment.Top
aboutBody.TextColor3 = ClassicSkin.COLOR_TEXT_CREDITS
aboutBody.Text = "OpenKart — Unofficial Roblox Port of SuperTuxKart 1.5 (pinned SVN rev 18627).\n\n"
	.. "Upstream: https://supertuxkart.net\n"
	.. "Source License: GNU General Public License v3.0 or later (GPLv3-or-later).\n"
	.. "Media & Classic Skin Assets: Audited per-file in assets/CREDITS.md (CC-BY-SA 3.0/4.0, CC0, GPL-2+).\n\n"
	.. "Local 2-Player Mode: Shared dynamic camera with 2 gamepads via GamepadSelect (P1 keyboard + P2 gamepad supported)."
aboutBody.ZIndex = 12
aboutBody.Parent = aboutBox

local screens: { [MenuFlow.Screen]: Frame } = {
	MENU = menuScreen,
	MODE = modeScreen,
	TRACK = trackScreen,
	KART = kartScreen,
	CONFIG = configScreen,
	LOADING = loadingScreen,
	OPTIONS = optionsScreen,
	ABOUT = aboutScreen,
}

local summaryLabel: TextLabel
local lapsValueLabel: TextLabel
local aiValueLabel: TextLabel
local aiRowFrame: Frame
local modeDiffButtons: { [string]: TextButton } = {}

local function renderScreen()
	updateSafeInsets()
	local isRacing = ClientSessionState.get().phase == "RACING"
	gui.Enabled = not isRacing

	if isRacing then
		backdrop.setActive(false, false)
	elseif menuState.screen == "MENU" then
		backdrop.setViewportRect(UDim2.fromScale(0.52, 0.04), UDim2.fromScale(0.45, 0.44))
		backdrop.setActive(true, true)
	elseif menuState.screen == "KART" then
		backdrop.setViewportRect(UDim2.fromScale(0.24, 0.11), UDim2.fromScale(0.52, 0.48))
		backdrop.setActive(true, true)
	else
		backdrop.setActive(true, false)
	end

	for name, frame in pairs(screens) do
		frame.Visible = (not isRacing) and (name == menuState.screen)
	end

	local cfg = menuState.config
	for diffId, btn in pairs(modeDiffButtons) do
		ClassicSkin.setButtonSelected(btn, cfg.difficulty == diffId)
	end

	if summaryLabel then
		local trackEntry = CatalogData.tracks[1]
		configTrackHeader.Text = if trackEntry then trackEntry.name else "Shifting Sands"
		summaryLabel.Text = string.format(
			"Mode: %s (%s)  |  Difficulty: %s  |  Kart: %s",
			cfg.playMode,
			cfg.raceType,
			cfg.difficulty,
			cfg.kartId
		)
		lapsValueLabel.Text = tostring(cfg.laps)
		aiValueLabel.Text = tostring(cfg.aiCount)
		aiRowFrame.Visible = (cfg.raceType == "NORMAL_RACE")
	end
	if menuState.screen == "OPTIONS" then
		optionsPanel.refresh()
	end
end

makeMainTopCard("SingleplayerBtn", "Singleplayer", MenuIcons.MenuRace, MenuIcons.MenuRaceFocus, 1, function()
	MenuFlow.selectPlayMode(menuState, "SINGLEPLAYER")
	renderScreen()
end)
makeMainTopCard("Local2PBtn", "Local 2P", MenuIcons.MenuMulti, MenuIcons.MenuMultiFocus, 2, function()
	MenuFlow.selectPlayMode(menuState, "LOCAL_2P")
	renderScreen()
end)
makeMainTopCard("OnlineBtn", "Online", MenuIcons.MenuOnline, MenuIcons.MenuOnlineFocus, 3, function()
	MenuFlow.selectPlayMode(menuState, "ONLINE")
	renderScreen()
end)
makeMainBottomBtn("OptionsBtn", "Options", MenuIcons.MainOptions, 1, function()
	MenuFlow.openOptions(menuState)
	renderScreen()
end)
makeMainBottomBtn("AboutBtn", "About", MenuIcons.MainAbout, 2, function()
	MenuFlow.openAbout(menuState)
	renderScreen()
end)

local function goBack()
	MenuFlow.back(menuState)
	renderScreen()
end

makeBackButton(modeScreen, goBack)
makeBackButton(trackScreen, goBack)
makeBackButton(kartScreen, goBack)
makeBackButton(configScreen, goBack)
makeBackButton(optionsScreen, goBack)
makeBackButton(aboutScreen, goBack)

-- Populate race_setup.stkgui Difficulty ribbon (128x128 icons)
local diffs: { { id: MenuFlow.Difficulty, label: string, icon: string } } = {
	{ id = "novice", label = "Novice", icon = MenuIcons.DifficultyEasy },
	{ id = "intermediate", label = "Intermediate", icon = MenuIcons.DifficultyMedium },
	{ id = "expert", label = "Expert", icon = MenuIcons.DifficultyHard },
	{ id = "best", label = "SuperTux", icon = MenuIcons.DifficultyBest },
}
for idx, d in ipairs(diffs) do
	local btn = ClassicSkin.makeGlassButton(
		diffBox,
		"Diff_" .. d.id,
		"",
		UDim2.fromScale(0.04 + (idx - 1) * 0.24, 0.12),
		UDim2.fromScale(0.20, 0.76),
		trackConn
	)
	local ico = Instance.new("ImageLabel")
	ico.BackgroundTransparency = 1
	ico.AnchorPoint = Vector2.new(0.5, 0)
	ico.Position = UDim2.fromScale(0.5, 0.08)
	ico.Size = UDim2.fromScale(0.65, 0.65)
	ico.SizeConstraint = Enum.SizeConstraint.RelativeYY
	ico.Image = d.icon
	ico.ScaleType = Enum.ScaleType.Fit
	ico.ZIndex = 13
	ico.Parent = btn

	local lbl = Instance.new("TextLabel")
	lbl.BackgroundTransparency = 1
	lbl.Position = UDim2.fromScale(0.05, 0.74)
	lbl.Size = UDim2.fromScale(0.90, 0.22)
	lbl.Font = ClassicSkin.FONT_BODY
	lbl.TextScaled = true
	lbl.TextColor3 = ClassicSkin.COLOR_TEXT_NEUTRAL
	lbl.Text = d.label
	lbl.ZIndex = 13
	lbl.Parent = btn

	modeDiffButtons[d.id] = btn
	trackConn(btn.Activated:Connect(function()
		MenuFlow.setConfig(menuState, { difficulty = d.id })
		renderScreen()
	end))
end

-- Populate race_setup.stkgui Game Mode buttons (96x96 icons)
local function makeModeCard(name: string, title: string, icon: string, xScale: number, raceType: MenuFlow.RaceType)
	local btn = ClassicSkin.makeGlassButton(
		gameModeBox,
		name,
		"",
		UDim2.fromScale(xScale, 0.14),
		UDim2.fromOffset(180, 150),
		trackConn
	)
	local img = Instance.new("ImageLabel")
	img.BackgroundTransparency = 1
	img.Position = UDim2.fromOffset(42, 14)
	img.Size = UDim2.fromOffset(96, 96)
	img.Image = icon
	img.ScaleType = Enum.ScaleType.Fit
	img.ZIndex = 13
	img.Parent = btn

	local lbl = Instance.new("TextLabel")
	lbl.BackgroundTransparency = 1
	lbl.Position = UDim2.fromOffset(8, 114)
	lbl.Size = UDim2.new(1, -16, 0, 28)
	lbl.Font = ClassicSkin.FONT_BODY
	lbl.TextSize = 18
	lbl.TextColor3 = ClassicSkin.COLOR_TEXT_NEUTRAL
	lbl.Text = title
	lbl.ZIndex = 13
	lbl.Parent = btn

	trackConn(btn.Activated:Connect(function()
		MenuFlow.selectRaceType(menuState, raceType)
		renderScreen()
	end))
end
makeModeCard("NormalRaceBtn", "Normal Race", MenuIcons.ModeNormal, 0.22, "NORMAL_RACE")
makeModeCard("TimeTrialBtn", "Time Trial", MenuIcons.ModeTimeTrial, 0.56, "TIME_TRIAL")

-- Populate tracks_and_gp.stkgui (176x132 track cards strictly from playable CatalogData.tracks)
for idx, track in ipairs(CatalogData.tracks) do
	local card = ClassicSkin.makeGlassButton(
		trackBox,
		"TrackCard_" .. track.id,
		"",
		UDim2.fromOffset(24 + (idx - 1) * 260, 24),
		UDim2.fromOffset(230, 196),
		trackConn
	)
	local shot = Instance.new("ImageLabel")
	shot.BackgroundColor3 = Color3.fromRGB(16, 24, 38)
	shot.BorderSizePixel = 0
	shot.Position = UDim2.fromOffset(27, 14)
	shot.Size = UDim2.fromOffset(176, 132)
	shot.Image = track.screenshotId
	shot.ScaleType = Enum.ScaleType.Crop
	shot.ZIndex = 13
	shot.Parent = card

	local title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.Position = UDim2.fromOffset(10, 152)
	title.Size = UDim2.fromOffset(210, 22)
	title.Font = ClassicSkin.FONT_BODY
	title.TextSize = 17
	title.TextColor3 = ClassicSkin.COLOR_TEXT_NEUTRAL
	title.Text = track.name
	title.ZIndex = 13
	title.Parent = card

	local meta = Instance.new("TextLabel")
	meta.BackgroundTransparency = 1
	meta.Position = UDim2.fromOffset(10, 174)
	meta.Size = UDim2.fromOffset(210, 16)
	meta.Font = ClassicSkin.FONT_BODY
	meta.TextSize = 12
	meta.TextColor3 = ClassicSkin.COLOR_TEXT_EMPHASIS
	meta.Text = string.format("By %s | %d Laps", track.designer, track.defaultLaps)
	meta.ZIndex = 13
	meta.Parent = card

	trackConn(card.Activated:Connect(function()
		MenuFlow.selectTrack(menuState, track.id)
		renderScreen()
	end))
end

-- Populate karts.stkgui (90x90 kart grid strictly from playable CatalogData.karts)
for idx, kart in ipairs(CatalogData.karts) do
	local card = ClassicSkin.makeGlassButton(
		kartBox,
		"KartCard_" .. kart.id,
		"",
		UDim2.fromOffset(28 + (idx - 1) * 160, 20),
		UDim2.fromOffset(140, 146),
		trackConn
	)
	local ico = Instance.new("ImageLabel")
	ico.BackgroundTransparency = 1
	ico.Position = UDim2.fromOffset(25, 10)
	ico.Size = UDim2.fromOffset(90, 90)
	ico.Image = kart.iconId
	ico.ScaleType = Enum.ScaleType.Fit
	ico.ZIndex = 13
	ico.Parent = card

	local kname = Instance.new("TextLabel")
	kname.BackgroundTransparency = 1
	kname.Position = UDim2.fromOffset(8, 104)
	kname.Size = UDim2.fromOffset(124, 22)
	kname.Font = ClassicSkin.FONT_BODY
	kname.TextSize = 17
	kname.TextColor3 = ClassicSkin.COLOR_TEXT_NEUTRAL
	kname.Text = kart.name
	kname.ZIndex = 13
	kname.Parent = card

	local ktype = Instance.new("TextLabel")
	ktype.BackgroundTransparency = 1
	ktype.Position = UDim2.fromOffset(8, 124)
	ktype.Size = UDim2.fromOffset(124, 16)
	ktype.Font = ClassicSkin.FONT_BODY
	ktype.TextSize = 12
	ktype.TextColor3 = ClassicSkin.COLOR_TEXT_EMPHASIS
	ktype.Text = kart.kartType
	ktype.ZIndex = 13
	ktype.Parent = card

	trackConn(card.Activated:Connect(function()
		MenuFlow.selectKart(menuState, kart.id)
		renderScreen()
	end))
end

-- Populate track_info.stkgui (Left 68% spinners, Right 30% screenshot + author + 64x64 green_check Start Race)
summaryLabel = Instance.new("TextLabel")
summaryLabel.BackgroundTransparency = 1
summaryLabel.Position = UDim2.fromOffset(24, 20)
summaryLabel.Size = UDim2.new(1, -48, 0, 32)
summaryLabel.Font = ClassicSkin.FONT_BODY
summaryLabel.TextSize = 16
summaryLabel.TextXAlignment = Enum.TextXAlignment.Left
summaryLabel.TextColor3 = ClassicSkin.COLOR_TEXT_EMPHASIS
summaryLabel.ZIndex = 12
summaryLabel.Parent = configCard

local function makeSpinnerRow(name: string, label: string, y: number, onStep: (number) -> ()): (Frame, TextLabel)
	local row = Instance.new("Frame")
	row.Name = name
	row.BackgroundTransparency = 1
	row.Position = UDim2.fromOffset(24, y)
	row.Size = UDim2.new(1, -48, 0, 44)
	row.ZIndex = 11
	row.Parent = configCard

	local spinnerBg = Instance.new("ImageLabel")
	spinnerBg.BackgroundTransparency = 1
	spinnerBg.Size = UDim2.fromOffset(160, 44)
	spinnerBg.Image = MenuIcons.SkinGlassSpinner
	spinnerBg.ScaleType = Enum.ScaleType.Stretch
	spinnerBg.ZIndex = 11
	spinnerBg.Parent = row

	local minus = Instance.new("TextButton")
	minus.Name = "Minus"
	minus.Size = UDim2.fromOffset(44, 44)
	minus.BackgroundTransparency = 1
	minus.Font = ClassicSkin.FONT_TITLE
	minus.TextSize = 20
	minus.TextColor3 = ClassicSkin.COLOR_TEXT_NEUTRAL
	minus.Text = "<"
	minus.ZIndex = 13
	minus.Parent = row

	local val = Instance.new("TextLabel")
	val.Name = "Value"
	val.BackgroundTransparency = 1
	val.Position = UDim2.fromOffset(44, 0)
	val.Size = UDim2.fromOffset(72, 44)
	val.Font = ClassicSkin.FONT_TITLE
	val.TextSize = 20
	val.TextColor3 = ClassicSkin.COLOR_TEXT_NEUTRAL
	val.Text = "5"
	val.ZIndex = 13
	val.Parent = row

	local plus = Instance.new("TextButton")
	plus.Name = "Plus"
	plus.Position = UDim2.fromOffset(116, 0)
	plus.Size = UDim2.fromOffset(44, 44)
	plus.BackgroundTransparency = 1
	plus.Font = ClassicSkin.FONT_TITLE
	plus.TextSize = 20
	plus.TextColor3 = ClassicSkin.COLOR_TEXT_NEUTRAL
	plus.Text = ">"
	plus.ZIndex = 13
	plus.Parent = row

	local lbl = Instance.new("TextLabel")
	lbl.BackgroundTransparency = 1
	lbl.Position = UDim2.fromOffset(180, 0)
	lbl.Size = UDim2.new(1, -180, 1, 0)
	lbl.Font = ClassicSkin.FONT_BODY
	lbl.TextSize = 18
	lbl.TextXAlignment = Enum.TextXAlignment.Left
	lbl.TextColor3 = ClassicSkin.COLOR_TEXT_NEUTRAL
	lbl.Text = label
	lbl.ZIndex = 12
	lbl.Parent = row

	trackConn(minus.Activated:Connect(function()
		onStep(-1)
	end))
	trackConn(plus.Activated:Connect(function()
		onStep(1)
	end))
	return row, val
end

local _, lapsLbl = makeSpinnerRow("LapsRow", "Number of laps", 84, function(delta)
	MenuFlow.setConfig(menuState, { laps = menuState.config.laps + delta })
	renderScreen()
end)
lapsValueLabel = lapsLbl

local aiRow, aiLbl = makeSpinnerRow("AiRow", "Number of AI karts", 148, function(delta)
	MenuFlow.setConfig(menuState, { aiCount = menuState.config.aiCount + delta })
	renderScreen()
end)
aiRowFrame = aiRow
aiValueLabel = aiLbl

local trackPreview = Instance.new("ImageLabel")
trackPreview.Name = "TrackScreenshot"
trackPreview.Size = UDim2.fromScale(1, 0.38)
trackPreview.BackgroundColor3 = Color3.fromRGB(14, 24, 40)
trackPreview.BorderSizePixel = 0
trackPreview.Image = MenuIcons.SandtrackScreenshot
trackPreview.ScaleType = Enum.ScaleType.Fit
trackPreview.ZIndex = 10
trackPreview.Parent = configRightCol

local infoBox =
	ClassicSkin.makeGlassBox(configRightCol, "InfoBox", UDim2.fromScale(0, 0.40), UDim2.fromScale(1, 0.37), 9)
local authorLbl = Instance.new("TextLabel")
authorLbl.BackgroundTransparency = 1
authorLbl.Position = UDim2.fromScale(0.06, 0.25)
authorLbl.Size = UDim2.fromScale(0.88, 0.50)
authorLbl.Font = ClassicSkin.FONT_BODY
authorLbl.TextSize = 17
authorLbl.TextWrapped = true
authorLbl.TextColor3 = ClassicSkin.COLOR_TEXT_NEUTRAL
authorLbl.Text = "Track by ctdabomb\nShifting Sands (STK 1.5)"
authorLbl.ZIndex = 12
authorLbl.Parent = infoBox

local startRaceBtn = Instance.new("TextButton")
startRaceBtn.Name = "StartRaceBtn"
startRaceBtn.Position = UDim2.fromScale(0.15, 0.79)
startRaceBtn.Size = UDim2.fromScale(0.70, 0.20)
startRaceBtn.BackgroundTransparency = 1
startRaceBtn.BorderSizePixel = 0
startRaceBtn.Text = ""
startRaceBtn.ZIndex = 12
startRaceBtn.Parent = configRightCol

local startCheckIco = Instance.new("ImageLabel")
startCheckIco.BackgroundTransparency = 1
startCheckIco.AnchorPoint = Vector2.new(0.5, 0)
startCheckIco.Position = UDim2.fromScale(0.5, 0.04)
startCheckIco.Size = UDim2.fromOffset(64, 64)
startCheckIco.Image = MenuIcons.GreenCheck
startCheckIco.ScaleType = Enum.ScaleType.Fit
startCheckIco.ZIndex = 13
startCheckIco.Parent = startRaceBtn

local startLbl = Instance.new("TextLabel")
startLbl.BackgroundTransparency = 1
startLbl.Position = UDim2.fromOffset(0, 68)
startLbl.Size = UDim2.new(1, 0, 0, 24)
startLbl.Font = ClassicSkin.FONT_BODY
startLbl.TextSize = 18
startLbl.TextColor3 = ClassicSkin.COLOR_TEXT_FOCUSED
startLbl.TextStrokeTransparency = 0.3
startLbl.Text = "Start Race"
startLbl.ZIndex = 13
startLbl.Parent = startRaceBtn

trackConn(startRaceBtn.Activated:Connect(function()
	MenuFlow.startRace(menuState)
	renderScreen()
	local remotes = ReplicatedStorage:FindFirstChild("OpenKartRemotes")
	local cmd = if remotes then remotes:FindFirstChild("SessionCommand") else nil
	if cmd and cmd:IsA("RemoteEvent") then
		cmd:FireServer("START_RACE", menuState.config)
	end
end))

ClientSessionState.subscribe(function(session)
	if session.phase == "RACING" then
		MenuFlow.onRaceLoaded(menuState)
	elseif session.phase == "MENU" and (menuState.screen == "RACING" or menuState.screen == "LOADING") then
		MenuFlow.returnToMenu(menuState)
	end
	renderScreen()
end)

renderScreen()
