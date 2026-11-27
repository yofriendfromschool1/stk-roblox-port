--!strict
-- SPDX-License-Identifier: GPL-3.0-or-later
-- Ported from data/gui/screens/options/options_{video,audio,ui,input}.stkgui & options_screen_ui.cpp (STK 1.5).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ClassicSkin = require("./ClassicSkin")
local ClientSettingsState = require("../ClientSettingsState")
local MenuIcons = require(Shared.menu.MenuIcons)
local SettingsSchema = require(Shared.settings.SettingsSchema)

export type Panel = {
	root: Frame,
	refresh: () -> (),
	destroy: () -> (),
}

local OptionsPanel = {}

local function makeRowLabel(parent: Instance, text: string, y: number, x: number?, role: string?): TextLabel
	local lbl = Instance.new("TextLabel")
	lbl.BackgroundTransparency = 1
	lbl.Position = UDim2.fromOffset(x or 18, y)
	lbl.Size = UDim2.fromOffset(236, 34)
	lbl.Font = ClassicSkin.FONT_BODY
	lbl.TextSize = 15
	lbl.TextXAlignment = Enum.TextXAlignment.Left
	lbl.TextColor3 = ClassicSkin.COLOR_TEXT_NEUTRAL
	lbl.Text = text
	lbl.ZIndex = 12
	lbl:SetAttribute("OpenKartSkinRole", role or "BodyText")
	lbl:SetAttribute("OpenKartBaseTextSize", 15)
	lbl.Parent = parent
	return lbl
end

local function cycleInList<T>(list: { T }, current: T): T
	for i, v in ipairs(list) do
		if v == current then
			return list[(i % #list) + 1]
		end
	end
	return list[1]
end

function OptionsPanel.create(parent: Instance, trackConn: (RBXScriptConnection) -> ()): Panel
	-- options_*.stkgui:L8-L31 -> 20% left vertical-tabs, 2% spacer, 78% right box
	local root = Instance.new("Frame")
	root.Name = "OptionsPanel"
	root.Position = UDim2.fromScale(0.02, 0.11)
	root.Size = UDim2.fromScale(0.96, 0.86)
	root.BackgroundTransparency = 1
	root.BorderSizePixel = 0
	root.ZIndex = 8
	root.Parent = parent

	local tabCol = Instance.new("Frame")
	tabCol.Name = "TabBar"
	tabCol.Position = UDim2.fromScale(0, 0)
	tabCol.Size = UDim2.fromScale(0.20, 1)
	tabCol.BackgroundTransparency = 1
	tabCol.ZIndex = 10
	tabCol.Parent = root

	local contentBox =
		ClassicSkin.makeGlassBox(root, "ContentBox", UDim2.fromScale(0.22, 0), UDim2.fromScale(0.78, 1), 9)

	local tabs = {
		{ id = "video", label = "Graphics", icon = MenuIcons.OptionsVideo },
		{ id = "audio", label = "Audio", icon = MenuIcons.OptionsAudio },
		{ id = "ui", label = "Interface", icon = MenuIcons.OptionsUi },
		{ id = "input", label = "Controls", icon = MenuIcons.OptionsInput },
	}
	local activeTab = "video"
	local tabButtons: { [string]: TextButton } = {}
	local tabBgs: { [string]: ImageLabel } = {}
	local pages: { [string]: Frame } = {}

	for idx, t in ipairs(tabs) do
		local btn = Instance.new("TextButton")
		btn.Name = "Tab_" .. t.id
		btn.Position = UDim2.fromOffset(0, (idx - 1) * 74)
		btn.Size = UDim2.new(1, 0, 0, 66)
		btn.BackgroundTransparency = 1
		btn.BorderSizePixel = 0
		btn.Text = ""
		btn.ZIndex = 12
		btn.Parent = tabCol

		local bg = Instance.new("ImageLabel")
		bg.Size = UDim2.fromScale(1, 1)
		bg.BackgroundTransparency = 1
		bg.Image = MenuIcons.SkinGlassTabVert
		bg.ScaleType = Enum.ScaleType.Slice
		bg.SliceCenter = Rect.new(45, 28, 211, 36)
		bg.ZIndex = 11
		bg.Parent = btn

		local ico = Instance.new("ImageLabel")
		ico.BackgroundTransparency = 1
		ico.Position = UDim2.fromOffset(12, 13)
		ico.Size = UDim2.fromOffset(40, 40)
		ico.Image = t.icon
		ico.ZIndex = 13
		ico.Parent = btn

		local tabLbl = Instance.new("TextLabel")
		tabLbl.Name = "TabText"
		tabLbl.BackgroundTransparency = 1
		tabLbl.Position = UDim2.fromOffset(60, 0)
		tabLbl.Size = UDim2.new(1, -68, 1, 0)
		tabLbl.Font = ClassicSkin.FONT_BODY
		tabLbl.TextSize = 16
		tabLbl.TextXAlignment = Enum.TextXAlignment.Left
		tabLbl.TextColor3 = ClassicSkin.COLOR_TEXT_NEUTRAL
		tabLbl.Text = t.label
		tabLbl.ZIndex = 13
		tabLbl:SetAttribute("OpenKartBaseTextSize", 16)
		tabLbl.Parent = btn

		local page = Instance.new("Frame")
		page.Name = "Page_" .. t.id
		page.Position = UDim2.fromOffset(14, 14)
		page.Size = UDim2.new(1, -28, 1, -28)
		page.BackgroundTransparency = 1
		page.BorderSizePixel = 0
		page.Visible = (t.id == activeTab)
		page.ZIndex = 10
		page.Parent = contentBox

		tabButtons[t.id] = btn
		tabBgs[t.id] = bg
		pages[t.id] = page
	end

	-- 1) Graphics page (client-owned Lighting FX, particles, shadows, track detail)
	local videoScroll = Instance.new("ScrollingFrame")
	videoScroll.Name = "VideoScroll"
	videoScroll.Size = UDim2.fromScale(1, 1)
	videoScroll.CanvasSize = UDim2.fromOffset(0, 470)
	videoScroll.ScrollBarThickness = 6
	videoScroll.BackgroundTransparency = 1
	videoScroll.BorderSizePixel = 0
	videoScroll.ZIndex = 10
	videoScroll.Parent = pages.video

	makeRowLabel(videoScroll, "Quality Preset", 10)
	local presetLowBtn = ClassicSkin.makeGlassButton(
		videoScroll,
		"PresetLowBtn",
		"Low",
		UDim2.fromOffset(260, 8),
		UDim2.fromOffset(88, 34),
		trackConn
	)
	local presetMedBtn = ClassicSkin.makeGlassButton(
		videoScroll,
		"PresetMedBtn",
		"Medium",
		UDim2.fromOffset(356, 8),
		UDim2.fromOffset(96, 34),
		trackConn
	)
	local presetHighBtn = ClassicSkin.makeGlassButton(
		videoScroll,
		"PresetHighBtn",
		"High",
		UDim2.fromOffset(460, 8),
		UDim2.fromOffset(88, 34),
		trackConn
	)

	makeRowLabel(videoScroll, "Bloom", 56)
	local bloomBtn = ClassicSkin.makeGlassButton(
		videoScroll,
		"BloomToggleBtn",
		"On",
		UDim2.fromOffset(260, 54),
		UDim2.fromOffset(140, 34),
		trackConn
	)

	makeRowLabel(videoScroll, "Depth of Field", 102)
	local dofBtn = ClassicSkin.makeGlassButton(
		videoScroll,
		"DofToggleBtn",
		"On",
		UDim2.fromOffset(260, 100),
		UDim2.fromOffset(140, 34),
		trackConn
	)

	makeRowLabel(videoScroll, "Sun Rays", 148)
	local sunRaysBtn = ClassicSkin.makeGlassButton(
		videoScroll,
		"SunRaysToggleBtn",
		"On",
		UDim2.fromOffset(260, 146),
		UDim2.fromOffset(140, 34),
		trackConn
	)

	makeRowLabel(videoScroll, "Color Correction", 194)
	local colorCorrBtn = ClassicSkin.makeGlassButton(
		videoScroll,
		"ColorCorrToggleBtn",
		"On",
		UDim2.fromOffset(260, 192),
		UDim2.fromOffset(140, 34),
		trackConn
	)

	makeRowLabel(videoScroll, "Particle Density", 240)
	local particlesBtn = ClassicSkin.makeGlassButton(
		videoScroll,
		"ParticlesCycleBtn",
		"Full",
		UDim2.fromOffset(260, 238),
		UDim2.fromOffset(140, 34),
		trackConn
	)

	makeRowLabel(videoScroll, "Kart Shadows", 286)
	local shadowsBtn = ClassicSkin.makeGlassButton(
		videoScroll,
		"ShadowsToggleBtn",
		"On",
		UDim2.fromOffset(260, 284),
		UDim2.fromOffset(140, 34),
		trackConn
	)

	makeRowLabel(videoScroll, "Track Decoration Detail", 332)
	local trackDetailBtn = ClassicSkin.makeGlassButton(
		videoScroll,
		"TrackDetailCycleBtn",
		"High",
		UDim2.fromOffset(260, 330),
		UDim2.fromOffset(140, 34),
		trackConn
	)

	makeRowLabel(videoScroll, "Kart Outline Highlight", 378)
	local kartHighlightBtn = ClassicSkin.makeGlassButton(
		videoScroll,
		"KartHighlightToggleBtn",
		"Off",
		UDim2.fromOffset(260, 376),
		UDim2.fromOffset(140, 34),
		trackConn
	)

	local persistNote = makeRowLabel(videoScroll, "Persistence: Checking...", 424, 18, "EmphasisText")
	persistNote.Size = UDim2.new(1, -36, 0, 28)

	-- 2) Audio page (options_audio.stkgui)
	local audioPage = pages.audio
	makeRowLabel(audioPage, "Master Mute", 18)
	local muteBtn = ClassicSkin.makeGlassButton(
		audioPage,
		"MasterMuteBtn",
		"Unmuted",
		UDim2.fromOffset(270, 16),
		UDim2.fromOffset(140, 36),
		trackConn
	)

	local function makeSliderRow(
		page: Frame,
		label: string,
		namePrefix: string,
		y: number,
		onDelta: (number) -> ()
	): (TextLabel, ImageLabel)
		makeRowLabel(page, label, y)
		local minusBtn = ClassicSkin.makeGlassButton(
			page,
			namePrefix .. "Minus",
			"-",
			UDim2.fromOffset(270, y),
			UDim2.fromOffset(42, 36),
			trackConn
		)
		local barBg = Instance.new("Frame")
		barBg.Position = UDim2.fromOffset(318, y + 6)
		barBg.Size = UDim2.fromOffset(130, 24)
		barBg.BackgroundColor3 = Color3.fromRGB(200, 215, 235)
		barBg.BorderSizePixel = 0
		barBg.ZIndex = 11
		barBg.Parent = page
		local fill = Instance.new("ImageLabel")
		fill.BackgroundTransparency = 1
		fill.Size = UDim2.fromScale(0.85, 1)
		fill.Image = MenuIcons.SkinGlassGaugeFill
		fill.ScaleType = Enum.ScaleType.Stretch
		fill.ZIndex = 12
		fill.Parent = barBg
		local valLbl = makeRowLabel(page, "85%", y, 318)
		valLbl.Size = UDim2.fromOffset(130, 36)
		valLbl.TextXAlignment = Enum.TextXAlignment.Center
		valLbl.ZIndex = 13
		local plusBtn = ClassicSkin.makeGlassButton(
			page,
			namePrefix .. "Plus",
			"+",
			UDim2.fromOffset(454, y),
			UDim2.fromOffset(42, 36),
			trackConn
		)
		trackConn(minusBtn.Activated:Connect(function()
			onDelta(-0.15)
		end))
		trackConn(plusBtn.Activated:Connect(function()
			onDelta(0.15)
		end))
		return valLbl, fill
	end

	local engineValLbl, engineFill = makeSliderRow(audioPage, "Engine Volume", "EngineVol", 72, function(d)
		ClientSettingsState.update(function(s)
			s.audio.engineVolume = math.clamp(s.audio.engineVolume + d, 0, 1)
		end)
	end)
	local sfxValLbl, sfxFill = makeSliderRow(audioPage, "SFX Volume", "SfxVol", 126, function(d)
		ClientSettingsState.update(function(s)
			s.audio.sfxVolume = math.clamp(s.audio.sfxVolume + d, 0, 1)
		end)
	end)
	local uiValLbl, uiFill = makeSliderRow(audioPage, "UI Volume", "UiVol", 180, function(d)
		ClientSettingsState.update(function(s)
			s.audio.uiVolume = math.clamp(s.audio.uiVolume + d, 0, 1)
		end)
	end)

	-- 3) Interface page (options_ui.stkgui + options_screen_ui.cpp)
	local uiPage = pages.ui
	makeRowLabel(uiPage, "Skin", 10)
	local skinBtn = ClassicSkin.makeGlassButton(
		uiPage,
		"SkinCycleBtn",
		"Classic",
		UDim2.fromOffset(260, 8),
		UDim2.fromOffset(210, 34),
		trackConn
	)

	makeRowLabel(uiPage, "Skin variant", 56)
	local skinVariantBtn = ClassicSkin.makeGlassButton(
		uiPage,
		"SkinVariantCycleBtn",
		"Peach",
		UDim2.fromOffset(260, 54),
		UDim2.fromOffset(210, 34),
		trackConn
	)

	makeRowLabel(uiPage, "Minimap", 102)
	local minimapBtn = ClassicSkin.makeGlassButton(
		uiPage,
		"MinimapCycleBtn",
		"In the bottom-left",
		UDim2.fromOffset(260, 100),
		UDim2.fromOffset(210, 34),
		trackConn
	)

	makeRowLabel(uiPage, "Font size", 148)
	local fontMinusBtn = ClassicSkin.makeGlassButton(
		uiPage,
		"FontSizeMinus",
		"-",
		UDim2.fromOffset(260, 146),
		UDim2.fromOffset(38, 34),
		trackConn
	)
	local fontBarBg = Instance.new("Frame")
	fontBarBg.Position = UDim2.fromOffset(304, 151)
	fontBarBg.Size = UDim2.fromOffset(122, 24)
	fontBarBg.BackgroundColor3 = Color3.fromRGB(200, 215, 235)
	fontBarBg.BorderSizePixel = 0
	fontBarBg.ZIndex = 11
	fontBarBg.Parent = uiPage
	local fontFill = Instance.new("ImageLabel")
	fontFill.BackgroundTransparency = 1
	fontFill.Size = UDim2.fromScale(0.6, 1)
	fontFill.Image = MenuIcons.SkinGlassGaugeFill
	fontFill.ScaleType = Enum.ScaleType.Stretch
	fontFill.ZIndex = 12
	fontFill.Parent = fontBarBg
	local fontValLbl = makeRowLabel(uiPage, "Medium", 146, 304)
	fontValLbl.Size = UDim2.fromOffset(122, 34)
	fontValLbl.TextXAlignment = Enum.TextXAlignment.Center
	fontValLbl.ZIndex = 13
	local fontPlusBtn = ClassicSkin.makeGlassButton(
		uiPage,
		"FontSizePlus",
		"+",
		UDim2.fromOffset(432, 146),
		UDim2.fromOffset(38, 34),
		trackConn
	)

	makeRowLabel(uiPage, "Display FPS", 194)
	local fpsBtn = ClassicSkin.makeGlassButton(
		uiPage,
		"ShowFpsToggleBtn",
		"Off",
		UDim2.fromOffset(260, 192),
		UDim2.fromOffset(140, 34),
		trackConn
	)

	local otherPowLbl = makeRowLabel(uiPage, "Show other karts' held powerups", 240)
	otherPowLbl.Size = UDim2.fromOffset(238, 34)
	local otherPowBtn = ClassicSkin.makeGlassButton(
		uiPage,
		"OtherPowerupsToggleBtn",
		"Off",
		UDim2.fromOffset(260, 238),
		UDim2.fromOffset(140, 34),
		trackConn
	)

	makeRowLabel(uiPage, "Camera Preset", 286)
	local camPresetBtn = ClassicSkin.makeGlassButton(
		uiPage,
		"CameraPresetBtn",
		"Normal",
		UDim2.fromOffset(260, 284),
		UDim2.fromOffset(140, 34),
		trackConn
	)

	-- 4) Controls page (options_input.stkgui)
	local inputPage = pages.input
	local capturePrompt = makeRowLabel(inputPage, "Click any action to rebind (Esc cancels)", 8, 18, "EmphasisText")
	capturePrompt.Size = UDim2.new(1, -240, 0, 28)

	local kbSubTabBtn = ClassicSkin.makeGlassButton(
		inputPage,
		"InputSub_Keyboard",
		"Keyboard",
		UDim2.new(1, -222, 0, 6),
		UDim2.fromOffset(102, 32),
		trackConn
	)
	local gpSubTabBtn = ClassicSkin.makeGlassButton(
		inputPage,
		"InputSub_Gamepad",
		"Gamepad",
		UDim2.new(1, -112, 0, 6),
		UDim2.fromOffset(102, 32),
		trackConn
	)

	local kbActions: { { key: string, label: string } } = {
		{ key = "accelerate", label = "Accelerate" },
		{ key = "brake", label = "Brake" },
		{ key = "steerLeft", label = "Steer Left" },
		{ key = "steerRight", label = "Steer Right" },
		{ key = "drift", label = "Drift" },
		{ key = "fire", label = "Fire Item" },
		{ key = "nitro", label = "Nitro" },
		{ key = "lookBack", label = "Look Back" },
		{ key = "rescue", label = "Rescue" },
	}
	local gpActions: { { key: string, label: string } } = {
		{ key = "accelerate", label = "Accelerate" },
		{ key = "brake", label = "Brake" },
		{ key = "drift", label = "Drift" },
		{ key = "fire", label = "Fire Item" },
		{ key = "nitro", label = "Nitro" },
		{ key = "lookBack", label = "Look Back" },
		{ key = "rescue", label = "Rescue" },
	}
	local inputDeviceTab: "keyboard" | "gamepad" = "keyboard"
	local kbGroup = Instance.new("Frame")
	kbGroup.Name = "KeyboardGroup"
	kbGroup.BackgroundTransparency = 1
	kbGroup.Position = UDim2.fromOffset(0, 44)
	kbGroup.Size = UDim2.new(1, 0, 1, -44)
	kbGroup.Parent = inputPage

	local gpGroup = Instance.new("Frame")
	gpGroup.Name = "GamepadGroup"
	gpGroup.BackgroundTransparency = 1
	gpGroup.Position = UDim2.fromOffset(0, 44)
	gpGroup.Size = UDim2.new(1, 0, 1, -44)
	gpGroup.Visible = false
	gpGroup.Parent = inputPage

	local kbBindButtons: { [string]: TextButton } = {}
	local gpBindButtons: { [string]: TextButton } = {}
	local capturingAction: string? = nil
	local capturingDevice: "keyboard" | "gamepad" = "keyboard"

	for i, item in ipairs(kbActions) do
		local col = if i <= 5 then 0 else 1
		local row = if i <= 5 then (i - 1) else (i - 6)
		local x = 18 + col * 310
		local y = 4 + row * 44
		local lbl = makeRowLabel(kbGroup, item.label, y, x)
		lbl.Size = UDim2.fromOffset(125, 34)
		local btn = ClassicSkin.makeGlassButton(
			kbGroup,
			"Bind_" .. item.key,
			"?",
			UDim2.fromOffset(x + 130, y),
			UDim2.fromOffset(145, 34),
			trackConn
		)
		kbBindButtons[item.key] = btn
		trackConn(btn.Activated:Connect(function()
			capturingDevice = "keyboard"
			capturingAction = item.key
			capturePrompt.Text = "Press a key for " .. item.label .. " (Esc cancels)..."
		end))
	end

	for i, item in ipairs(gpActions) do
		local col = if i <= 4 then 0 else 1
		local row = if i <= 4 then (i - 1) else (i - 5)
		local x = 18 + col * 310
		local y = 4 + row * 44
		local lbl = makeRowLabel(gpGroup, item.label, y, x)
		lbl.Size = UDim2.fromOffset(125, 34)
		local btn = ClassicSkin.makeGlassButton(
			gpGroup,
			"BindGP_" .. item.key,
			"?",
			UDim2.fromOffset(x + 130, y),
			UDim2.fromOffset(145, 34),
			trackConn
		)
		gpBindButtons[item.key] = btn
		trackConn(btn.Activated:Connect(function()
			capturingDevice = "gamepad"
			capturingAction = item.key
			capturePrompt.Text = "Press a gamepad button for " .. item.label .. " (Esc cancels)..."
		end))
	end

	local resetBindsBtn = ClassicSkin.makeGlassButton(
		inputPage,
		"ResetBindingsBtn",
		"Reset Defaults",
		UDim2.fromOffset(328, 224),
		UDim2.fromOffset(275, 36),
		trackConn
	)

	local function isGamepadType(uit: Enum.UserInputType): boolean
		return uit.Value >= Enum.UserInputType.Gamepad1.Value and uit.Value <= Enum.UserInputType.Gamepad8.Value
	end

	trackConn(UserInputService.InputBegan:Connect(function(inputObj: InputObject)
		if capturingAction == nil then
			return
		end
		if inputObj.UserInputType == Enum.UserInputType.Keyboard and inputObj.KeyCode == Enum.KeyCode.Escape then
			capturingAction = nil
			capturePrompt.Text = "Click any action to rebind (Esc cancels)"
			return
		end
		if capturingDevice == "keyboard" and inputObj.UserInputType == Enum.UserInputType.Keyboard then
			local actionKey = capturingAction :: string
			capturingAction = nil
			local keyName = inputObj.KeyCode.Name
			ClientSettingsState.update(function(s)
				(s.input.keyboard :: { [string]: string })[actionKey] = keyName
			end)
			capturePrompt.Text = "Bound KB " .. actionKey .. " -> " .. keyName
		elseif capturingDevice == "gamepad" and isGamepadType(inputObj.UserInputType) then
			local actionKey = capturingAction :: string
			capturingAction = nil
			local btnName = inputObj.KeyCode.Name
			ClientSettingsState.update(function(s)
				(s.input.gamepad :: { [string]: string })[actionKey] = btnName
			end)
			capturePrompt.Text = "Bound GP " .. actionKey .. " -> " .. btnName
		end
	end))

	local function refresh()
		local s = ClientSettingsState.get()
		for id, btn in pairs(tabButtons) do
			local selected = (id == activeTab)
			tabBgs[id].Image = if selected then MenuIcons.SkinGlassTabVertFocus else MenuIcons.SkinGlassTabVert
			local tabText = btn:FindFirstChild("TabText")
			if tabText and tabText:IsA("TextLabel") then
				tabText.TextColor3 = if selected then ClassicSkin.COLOR_TEXT_FOCUSED else ClassicSkin.COLOR_TEXT_NEUTRAL
			end
			pages[id].Visible = selected
		end

		ClassicSkin.setButtonSelected(presetLowBtn, s.graphics.preset == "Low")
		ClassicSkin.setButtonSelected(presetMedBtn, s.graphics.preset == "Medium")
		ClassicSkin.setButtonSelected(presetHighBtn, s.graphics.preset == "High")
		ClassicSkin.setButtonText(bloomBtn, if s.graphics.bloom then "On" else "Off")
		ClassicSkin.setButtonText(dofBtn, if s.graphics.depthOfField then "On" else "Off")
		ClassicSkin.setButtonText(sunRaysBtn, if s.graphics.sunRays then "On" else "Off")
		ClassicSkin.setButtonText(colorCorrBtn, if s.graphics.colorCorrection then "On" else "Off")
		ClassicSkin.setButtonText(
			particlesBtn,
			if s.graphics.particles == 0 then "Off" elseif s.graphics.particles == 1 then "Reduced" else "Full"
		)
		ClassicSkin.setButtonText(shadowsBtn, if s.graphics.shadows then "On" else "Off")
		ClassicSkin.setButtonText(trackDetailBtn, s.graphics.trackDetail)
		ClassicSkin.setButtonText(kartHighlightBtn, if s.graphics.kartHighlight then "On" else "Off")
		persistNote.Text = if ClientSettingsState.isPersisted()
			then "Persistence: Saved to Roblox DataStore"
			else "Persistence: Session-only (DataStore unavailable)"

		ClassicSkin.setButtonText(muteBtn, if s.audio.masterMuted then "Muted" else "Unmuted")
		engineValLbl.Text = string.format("%d%%", math.floor(s.audio.engineVolume * 100 + 0.5))
		engineFill.Size = UDim2.fromScale(math.clamp(s.audio.engineVolume, 0, 1), 1)
		sfxValLbl.Text = string.format("%d%%", math.floor(s.audio.sfxVolume * 100 + 0.5))
		sfxFill.Size = UDim2.fromScale(math.clamp(s.audio.sfxVolume, 0, 1), 1)
		uiValLbl.Text = string.format("%d%%", math.floor(s.audio.uiVolume * 100 + 0.5))
		uiFill.Size = UDim2.fromScale(math.clamp(s.audio.uiVolume, 0, 1), 1)

		ClassicSkin.setButtonText(skinBtn, s.ui.skin)
		ClassicSkin.setButtonText(skinVariantBtn, s.ui.skinVariant)
		ClassicSkin.setButtonText(minimapBtn, SettingsSchema.getMinimapLabel(s.ui.minimapDisplay))
		fontValLbl.Text = SettingsSchema.getFontSizeLabel(s.ui.fontSize)
		fontFill.Size = UDim2.fromScale(math.clamp((s.ui.fontSize - 1) / 4, 0.08, 1), 1)
		ClassicSkin.setButtonText(fpsBtn, if s.ui.showFps then "On" else "Off")
		ClassicSkin.setButtonText(otherPowBtn, if s.ui.showOtherPowerups then "On" else "Off")
		ClassicSkin.setButtonText(camPresetBtn, s.ui.cameraPreset)

		kbGroup.Visible = (inputDeviceTab == "keyboard")
		gpGroup.Visible = (inputDeviceTab == "gamepad")
		ClassicSkin.setButtonSelected(kbSubTabBtn, inputDeviceTab == "keyboard")
		ClassicSkin.setButtonSelected(gpSubTabBtn, inputDeviceTab == "gamepad")

		for key, btn in pairs(kbBindButtons) do
			ClassicSkin.setButtonText(btn, (s.input.keyboard :: { [string]: string })[key] or "?")
		end
		for key, btn in pairs(gpBindButtons) do
			ClassicSkin.setButtonText(btn, (s.input.gamepad :: { [string]: string })[key] or "?")
		end
	end

	for id, btn in pairs(tabButtons) do
		trackConn(btn.Activated:Connect(function()
			activeTab = id
			refresh()
		end))
	end

	local function bindPreset(btn: TextButton, preset: SettingsSchema.GraphicsPreset)
		trackConn(btn.Activated:Connect(function()
			ClientSettingsState.update(function(s)
				s.graphics = SettingsSchema.applyGraphicsPreset(preset)
			end)
		end))
	end
	bindPreset(presetLowBtn, "Low")
	bindPreset(presetMedBtn, "Medium")
	bindPreset(presetHighBtn, "High")

	trackConn(bloomBtn.Activated:Connect(function()
		ClientSettingsState.update(function(s)
			s.graphics.bloom = not s.graphics.bloom
		end)
	end))
	trackConn(dofBtn.Activated:Connect(function()
		ClientSettingsState.update(function(s)
			s.graphics.depthOfField = not s.graphics.depthOfField
		end)
	end))
	trackConn(sunRaysBtn.Activated:Connect(function()
		ClientSettingsState.update(function(s)
			s.graphics.sunRays = not s.graphics.sunRays
		end)
	end))
	trackConn(colorCorrBtn.Activated:Connect(function()
		ClientSettingsState.update(function(s)
			s.graphics.colorCorrection = not s.graphics.colorCorrection
		end)
	end))
	trackConn(particlesBtn.Activated:Connect(function()
		ClientSettingsState.update(function(s)
			s.graphics.particles = (s.graphics.particles + 1) % 3
		end)
	end))
	trackConn(shadowsBtn.Activated:Connect(function()
		ClientSettingsState.update(function(s)
			s.graphics.shadows = not s.graphics.shadows
		end)
	end))
	trackConn(trackDetailBtn.Activated:Connect(function()
		ClientSettingsState.update(function(s)
			s.graphics.trackDetail = cycleInList(SettingsSchema.TRACK_DETAIL_ORDER, s.graphics.trackDetail) :: any
		end)
	end))
	trackConn(kartHighlightBtn.Activated:Connect(function()
		ClientSettingsState.update(function(s)
			s.graphics.kartHighlight = not s.graphics.kartHighlight
		end)
	end))

	trackConn(muteBtn.Activated:Connect(function()
		ClientSettingsState.update(function(s)
			s.audio.masterMuted = not s.audio.masterMuted
		end)
	end))

	trackConn(skinBtn.Activated:Connect(function()
		ClientSettingsState.update(function(s)
			s.ui.skin = cycleInList(SettingsSchema.SKIN_ORDER, s.ui.skin) :: any
		end)
	end))
	trackConn(skinVariantBtn.Activated:Connect(function()
		ClientSettingsState.update(function(s)
			s.ui.skinVariant = cycleInList(SettingsSchema.SKIN_VARIANT_ORDER, s.ui.skinVariant) :: any
		end)
	end))
	trackConn(minimapBtn.Activated:Connect(function()
		ClientSettingsState.update(function(s)
			s.ui.minimapDisplay = (s.ui.minimapDisplay + 1) % 4
		end)
	end))
	trackConn(fontMinusBtn.Activated:Connect(function()
		ClientSettingsState.update(function(s)
			s.ui.fontSize = math.clamp(s.ui.fontSize - 1, 1, 5)
		end)
	end))
	trackConn(fontPlusBtn.Activated:Connect(function()
		ClientSettingsState.update(function(s)
			s.ui.fontSize = math.clamp(s.ui.fontSize + 1, 1, 5)
		end)
	end))
	trackConn(fpsBtn.Activated:Connect(function()
		ClientSettingsState.update(function(s)
			s.ui.showFps = not s.ui.showFps
		end)
	end))
	trackConn(otherPowBtn.Activated:Connect(function()
		ClientSettingsState.update(function(s)
			s.ui.showOtherPowerups = not s.ui.showOtherPowerups
		end)
	end))
	trackConn(camPresetBtn.Activated:Connect(function()
		ClientSettingsState.update(function(s)
			if s.ui.cameraPreset == "Normal" then
				s.ui.cameraPreset = "Close"
			elseif s.ui.cameraPreset == "Close" then
				s.ui.cameraPreset = "Far"
			else
				s.ui.cameraPreset = "Normal"
			end
		end)
	end))

	trackConn(resetBindsBtn.Activated:Connect(function()
		ClientSettingsState.update(function(s)
			s.input = SettingsSchema.defaults().input
		end)
	end))
	trackConn(kbSubTabBtn.Activated:Connect(function()
		inputDeviceTab = "keyboard"
		capturingAction = nil
		refresh()
	end))
	trackConn(gpSubTabBtn.Activated:Connect(function()
		inputDeviceTab = "gamepad"
		capturingAction = nil
		refresh()
	end))

	local unsub = ClientSettingsState.subscribe(function()
		refresh()
	end)

	return {
		root = root,
		refresh = refresh,
		destroy = function()
			unsub()
			root:Destroy()
		end,
	}
end

return OptionsPanel
