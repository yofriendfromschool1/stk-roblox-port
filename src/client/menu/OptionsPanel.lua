--!strict
-- SPDX-License-Identifier: GPL-3.0-or-later
-- Ported from data/gui/screens/options/options_{video,audio,ui,input}.stkgui (STK 1.5).

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

local function makeRowLabel(parent: Instance, text: string, y: number, x: number?): TextLabel
	local lbl = Instance.new("TextLabel")
	lbl.BackgroundTransparency = 1
	lbl.Position = UDim2.fromOffset(x or 24, y)
	lbl.Size = UDim2.fromOffset(230, 34)
	lbl.Font = ClassicSkin.FONT_BODY
	lbl.TextSize = 16
	lbl.TextXAlignment = Enum.TextXAlignment.Left
	lbl.TextColor3 = ClassicSkin.COLOR_TEXT_NEUTRAL
	lbl.Text = text
	lbl.ZIndex = 12
	lbl.Parent = parent
	return lbl
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

	-- 1) Graphics page (options_video.stkgui)
	local videoPage = pages.video
	makeRowLabel(videoPage, "Quality Preset", 18)
	local presetLowBtn = ClassicSkin.makeGlassButton(
		videoPage,
		"PresetLowBtn",
		"Low",
		UDim2.fromOffset(270, 16),
		UDim2.fromOffset(92, 36),
		trackConn
	)
	local presetMedBtn = ClassicSkin.makeGlassButton(
		videoPage,
		"PresetMedBtn",
		"Medium",
		UDim2.fromOffset(370, 16),
		UDim2.fromOffset(100, 36),
		trackConn
	)
	local presetHighBtn = ClassicSkin.makeGlassButton(
		videoPage,
		"PresetHighBtn",
		"High",
		UDim2.fromOffset(478, 16),
		UDim2.fromOffset(92, 36),
		trackConn
	)

	makeRowLabel(videoPage, "Kart Shadows", 72)
	local shadowsBtn = ClassicSkin.makeGlassButton(
		videoPage,
		"ShadowsToggleBtn",
		"On",
		UDim2.fromOffset(270, 70),
		UDim2.fromOffset(140, 36),
		trackConn
	)

	makeRowLabel(videoPage, "Particles", 126)
	local particlesBtn = ClassicSkin.makeGlassButton(
		videoPage,
		"ParticlesCycleBtn",
		"Full",
		UDim2.fromOffset(270, 124),
		UDim2.fromOffset(140, 36),
		trackConn
	)

	makeRowLabel(videoPage, "Client Post-FX (Bloom/Rays)", 180)
	local postFxBtn = ClassicSkin.makeGlassButton(
		videoPage,
		"PostFxToggleBtn",
		"On",
		UDim2.fromOffset(270, 178),
		UDim2.fromOffset(140, 36),
		trackConn
	)

	local persistNote = makeRowLabel(videoPage, "Persistence: Checking...", 240)
	persistNote.Size = UDim2.new(1, -48, 0, 28)
	persistNote.TextColor3 = ClassicSkin.COLOR_TEXT_EMPHASIS

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

	-- 3) Interface page (options_ui.stkgui)
	local uiPage = pages.ui
	makeRowLabel(uiPage, "Minimap Display", 18)
	local minimapBtn = ClassicSkin.makeGlassButton(
		uiPage,
		"MinimapCycleBtn",
		"Corner",
		UDim2.fromOffset(270, 16),
		UDim2.fromOffset(170, 36),
		trackConn
	)

	makeRowLabel(uiPage, "Show FPS Counter", 72)
	local fpsBtn = ClassicSkin.makeGlassButton(
		uiPage,
		"ShowFpsToggleBtn",
		"On",
		UDim2.fromOffset(270, 70),
		UDim2.fromOffset(140, 36),
		trackConn
	)

	makeRowLabel(uiPage, "Camera Preset", 126)
	local camPresetBtn = ClassicSkin.makeGlassButton(
		uiPage,
		"CameraPresetBtn",
		"Normal",
		UDim2.fromOffset(270, 124),
		UDim2.fromOffset(140, 36),
		trackConn
	)

	-- 4) Controls page (options_input.stkgui)
	local inputPage = pages.input
	local capturePrompt = makeRowLabel(inputPage, "Click any action to rebind (Esc cancels)", 8)
	capturePrompt.Size = UDim2.new(1, -240, 0, 28)
	capturePrompt.TextColor3 = ClassicSkin.COLOR_TEXT_EMPHASIS

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
		ClassicSkin.setButtonText(shadowsBtn, if s.graphics.shadows then "On" else "Off")
		ClassicSkin.setButtonText(
			particlesBtn,
			if s.graphics.particles == 0 then "Off" elseif s.graphics.particles == 1 then "Reduced" else "Full"
		)
		ClassicSkin.setButtonText(postFxBtn, if s.graphics.postEffects then "On" else "Off")
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

		ClassicSkin.setButtonText(
			minimapBtn,
			if s.ui.minimapDisplay == 0 then "Hidden" elseif s.ui.minimapDisplay == 1 then "Corner" else "Large"
		)
		ClassicSkin.setButtonText(fpsBtn, if s.ui.showFps then "On" else "Off")
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

	trackConn(shadowsBtn.Activated:Connect(function()
		ClientSettingsState.update(function(s)
			s.graphics.shadows = not s.graphics.shadows
		end)
	end))
	trackConn(particlesBtn.Activated:Connect(function()
		ClientSettingsState.update(function(s)
			s.graphics.particles = (s.graphics.particles + 1) % 3
		end)
	end))
	trackConn(postFxBtn.Activated:Connect(function()
		ClientSettingsState.update(function(s)
			s.graphics.postEffects = not s.graphics.postEffects
		end)
	end))
	trackConn(muteBtn.Activated:Connect(function()
		ClientSettingsState.update(function(s)
			s.audio.masterMuted = not s.audio.masterMuted
		end)
	end))
	trackConn(minimapBtn.Activated:Connect(function()
		ClientSettingsState.update(function(s)
			s.ui.minimapDisplay = (s.ui.minimapDisplay + 1) % 3
		end)
	end))
	trackConn(fpsBtn.Activated:Connect(function()
		ClientSettingsState.update(function(s)
			s.ui.showFps = not s.ui.showFps
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
