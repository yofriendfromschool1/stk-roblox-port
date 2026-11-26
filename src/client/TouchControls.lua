--!strict
-- src/client/TouchControls.lua
-- SPDX-License-Identifier: GPL-3.0-or-later
-- Ported from src/states_screens/race_gui_multitouch.cpp:L203-L271, L379-L523 and
-- src/input/multitouch_device.cpp:L358-L504 (STK 1.5).
-- On-screen touch drag-angle steering wheel + action buttons with real STK Android textures
-- (audited in assets/CREDITS.md, CC-BY-SA 4.0), shown only when TouchEnabled and no gamepad connected.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local InputMapper = require("./InputMapper")

local TouchControls = {}

-- Verified CC-BY-SA 4.0 STK 1.5 Android multitouch textures (data/gui/icons/android/licenses.txt)
local TEX_STEERING_WHEEL = "rbxassetid://121527397863037"
local TEX_WHEEL_MASK_UP = "rbxassetid://106020955046968"
local TEX_WHEEL_MASK_DOWN = "rbxassetid://88639413454443"
local TEX_BG_BUTTON = "rbxassetid://138056251155457"
local TEX_BG_BUTTON_FOCUS = "rbxassetid://95283772383405"
local TEX_DRIFT = "rbxassetid://130967942117194"
local TEX_NITRO = "rbxassetid://83998478837258"
local TEX_WING_MIRROR = "rbxassetid://96145198722298"
local TEX_RESET = "rbxassetid://87263946566326"
local TEX_PAUSE = "rbxassetid://86852632601328"
local TEX_ACCELERATOR = "rbxassetid://137205787253998"

-- STK multitouch layout constants (race_gui_multitouch.cpp:L203-L238, user_config.hpp:L584 scale=1.2)
local SCALE = 1.2
local BTN_SIZE = 0.125 * SCALE -- 0.15 of screen height
local BTN2_SIZE = 0.35 * SCALE -- 0.42 of screen height (steering wheel)
local MARGIN = 0.075 * SCALE -- 0.09 of screen height
local COL_SIZE = BTN_SIZE + MARGIN -- 0.24 of screen height
local SMALL_RATIO = 0.75
local BTN_SMALL_SIZE = SMALL_RATIO * BTN_SIZE -- 0.1125 of screen height
local MARGIN_SMALL = SMALL_RATIO * MARGIN -- 0.0675 of screen height
local WHEEL_MARGIN = 0.6 * MARGIN -- 0.054 of screen height

export type Controller = {
	gui: ScreenGui,
	getState: () -> InputMapper.TouchState?,
	destroy: () -> (),
}

local function isPointInside(guiObj: GuiObject, pos: Vector3): boolean
	local absPos = guiObj.AbsolutePosition
	local absSize = guiObj.AbsoluteSize
	return pos.X >= absPos.X and pos.X <= absPos.X + absSize.X and pos.Y >= absPos.Y and pos.Y <= absPos.Y + absSize.Y
end

function TouchControls.create(): Controller
	local localPlayer = Players.LocalPlayer
	local playerGui = localPlayer:WaitForChild("PlayerGui")

	local gui = Instance.new("ScreenGui")
	gui.Name = "OpenKartTouchControls"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 5
	gui.Parent = playerGui

	local state: InputMapper.TouchState = {
		wheelAxisX = 0.0,
		wheelAxisY = 0.0,
		wheelActive = false,
		accel = false,
		brake = false,
		drift = false,
		nitro = false,
		fire = false,
		lookBack = false,
		reset = false,
	}

	local function updateVisibility()
		local hasGamepad = #UserInputService:GetConnectedGamepads() > 0
		local forcePreview = RunService:IsStudio() and localPlayer:GetAttribute("ForceTouchPreview") == true
		gui.Enabled = forcePreview or (UserInputService.TouchEnabled and not hasGamepad)
		if not gui.Enabled then
			state.wheelAxisX = 0.0
			state.wheelAxisY = 0.0
			state.wheelActive = false
			state.accel = false
			state.brake = false
			state.drift = false
			state.nitro = false
			state.fire = false
			state.lookBack = false
			state.reset = false
		end
	end

	-- Steering Wheel (bottom-left, race_gui_multitouch.cpp:L221-L224, L249-L251, L379-L400)
	local wheelFrame = Instance.new("Frame")
	wheelFrame.Name = "SteeringWheel"
	wheelFrame.SizeConstraint = Enum.SizeConstraint.RelativeYY
	wheelFrame.AnchorPoint = Vector2.new(0, 1)
	wheelFrame.Position = UDim2.fromScale(0.03, 1.0 - WHEEL_MARGIN)
	wheelFrame.Size = UDim2.fromScale(BTN2_SIZE, BTN2_SIZE)
	wheelFrame.BackgroundTransparency = 1
	wheelFrame.BorderSizePixel = 0
	wheelFrame.Parent = gui

	local wheelImage = Instance.new("ImageLabel")
	wheelImage.Name = "WheelImage"
	wheelImage.AnchorPoint = Vector2.new(0.5, 0.5)
	wheelImage.Position = UDim2.fromScale(0.5, 0.5)
	wheelImage.Size = UDim2.fromScale(1, 1)
	wheelImage.BackgroundTransparency = 1
	wheelImage.BorderSizePixel = 0
	wheelImage.Image = TEX_STEERING_WHEEL
	wheelImage.ScaleType = Enum.ScaleType.Fit
	wheelImage.ZIndex = 2
	wheelImage.Parent = wheelFrame

	local wheelMaskUp = Instance.new("ImageLabel")
	wheelMaskUp.Name = "MaskUp"
	wheelMaskUp.Size = UDim2.fromScale(1, 1)
	wheelMaskUp.BackgroundTransparency = 1
	wheelMaskUp.Image = TEX_WHEEL_MASK_UP
	wheelMaskUp.ImageTransparency = 1.0
	wheelMaskUp.ScaleType = Enum.ScaleType.Fit
	wheelMaskUp.ZIndex = 3
	wheelMaskUp.Parent = wheelImage

	local wheelMaskDown = Instance.new("ImageLabel")
	wheelMaskDown.Name = "MaskDown"
	wheelMaskDown.Size = UDim2.fromScale(1, 1)
	wheelMaskDown.BackgroundTransparency = 1
	wheelMaskDown.Image = TEX_WHEEL_MASK_DOWN
	wheelMaskDown.ImageTransparency = 1.0
	wheelMaskDown.ScaleType = Enum.ScaleType.Fit
	wheelMaskDown.ZIndex = 3
	wheelMaskDown.Parent = wheelImage

	local function makeTexturedButton(
		parent: Instance,
		name: string,
		iconAsset: string,
		pos: UDim2,
		size: UDim2,
		iconRotDeg: number?
	): (Frame, ImageLabel)
		local btn = Instance.new("Frame")
		btn.Name = name
		btn.AnchorPoint = Vector2.new(1, 1)
		btn.Position = pos
		btn.Size = size
		btn.BackgroundTransparency = 1
		btn.BorderSizePixel = 0
		btn.Parent = parent

		-- race_gui_multitouch.cpp:L372-L375, L515-L523: bg is 1.4x button size centered behind icon
		local bg = Instance.new("ImageLabel")
		bg.Name = "Bg"
		bg.AnchorPoint = Vector2.new(0.5, 0.5)
		bg.Position = UDim2.fromScale(0.5, 0.5)
		bg.Size = UDim2.fromScale(1.4, 1.4)
		bg.BackgroundTransparency = 1
		bg.Image = TEX_BG_BUTTON
		bg.ScaleType = Enum.ScaleType.Fit
		bg.ZIndex = 1
		bg.Parent = btn

		local icon = Instance.new("ImageLabel")
		icon.Name = "Icon"
		icon.Size = UDim2.fromScale(1, 1)
		icon.BackgroundTransparency = 1
		icon.Image = iconAsset
		icon.ScaleType = Enum.ScaleType.Fit
		icon.Rotation = iconRotDeg or 0
		icon.ZIndex = 2
		icon.Parent = btn

		return btn, bg
	end

	-- Right-hand columns container in RelativeYY coordinates (race_gui_multitouch.cpp:L219-L271)
	local gridW = COL_SIZE * 3.0
	local gridH = COL_SIZE * 2.0
	local rightGrid = Instance.new("Frame")
	rightGrid.Name = "RightButtons"
	rightGrid.SizeConstraint = Enum.SizeConstraint.RelativeYY
	rightGrid.AnchorPoint = Vector2.new(1, 1)
	rightGrid.Position = UDim2.fromScale(0.97, 1.0 - MARGIN)
	rightGrid.Size = UDim2.fromScale(gridW, gridH)
	rightGrid.BackgroundTransparency = 1
	rightGrid.Parent = gui

	local cellBtnSize = UDim2.fromScale(BTN_SIZE / gridW, BTN_SIZE / gridH)
	local colStepX = COL_SIZE / gridW
	local rowStepY = COL_SIZE / gridH

	local nitroBtn, nitroBg =
		makeTexturedButton(rightGrid, "Nitro", TEX_NITRO, UDim2.fromScale(1.0, 1.0 - rowStepY), cellBtnSize)
	local driftBtn, driftBg = makeTexturedButton(rightGrid, "Drift", TEX_DRIFT, UDim2.fromScale(1.0, 1.0), cellBtnSize)
	local fireBtn, fireBg = makeTexturedButton(
		rightGrid,
		"Fire",
		TEX_BG_BUTTON_FOCUS,
		UDim2.fromScale(1.0 - colStepX, 1.0 - rowStepY),
		cellBtnSize
	)
	local lookBackBtn, lookBackBg =
		makeTexturedButton(rightGrid, "LookBack", TEX_WING_MIRROR, UDim2.fromScale(1.0 - colStepX, 1.0), cellBtnSize)
	local accelBtn, accelBg =
		makeTexturedButton(rightGrid, "Accel", TEX_ACCELERATOR, UDim2.fromScale(1.0 - 2.0 * colStepX, 1.0), cellBtnSize)
	local brakeBtn, brakeBg = makeTexturedButton(
		rightGrid,
		"Brake",
		TEX_ACCELERATOR,
		UDim2.fromScale(1.0 - 2.0 * colStepX, 1.0 - rowStepY),
		cellBtnSize,
		180
	)

	-- Top pause & rescue/reset buttons (race_gui_multitouch.cpp:L254-L259)
	local pauseBtn, _pauseBg = makeTexturedButton(
		gui,
		"Pause",
		TEX_PAUSE,
		UDim2.fromScale(0.30, MARGIN_SMALL + BTN_SMALL_SIZE),
		UDim2.fromScale(BTN_SMALL_SIZE, BTN_SMALL_SIZE)
	)
	pauseBtn.SizeConstraint = Enum.SizeConstraint.RelativeYY
	pauseBtn.AnchorPoint = Vector2.new(0, 1)

	local resetBtn, resetBg = makeTexturedButton(
		gui,
		"Reset",
		TEX_RESET,
		UDim2.fromScale(0.30 + COL_SIZE * SMALL_RATIO, MARGIN_SMALL + BTN_SMALL_SIZE),
		UDim2.fromScale(BTN_SMALL_SIZE, BTN_SMALL_SIZE)
	)
	resetBtn.SizeConstraint = Enum.SizeConstraint.RelativeYY
	resetBtn.AnchorPoint = Vector2.new(0, 1)

	type ButtonBinding = {
		frame: Frame,
		bg: ImageLabel,
		key: "accel" | "brake" | "drift" | "nitro" | "fire" | "lookBack" | "reset",
		activeTouch: InputObject?,
	}

	local buttons: { ButtonBinding } = {
		{ frame = accelBtn, bg = accelBg, key = "accel", activeTouch = nil },
		{ frame = brakeBtn, bg = brakeBg, key = "brake", activeTouch = nil },
		{ frame = driftBtn, bg = driftBg, key = "drift", activeTouch = nil },
		{ frame = nitroBtn, bg = nitroBg, key = "nitro", activeTouch = nil },
		{ frame = fireBtn, bg = fireBg, key = "fire", activeTouch = nil },
		{ frame = lookBackBtn, bg = lookBackBg, key = "lookBack", activeTouch = nil },
		{ frame = resetBtn, bg = resetBg, key = "reset", activeTouch = nil },
	}

	local wheelTouch: InputObject? = nil

	local function updateWheelFromPos(pos: Vector3)
		local absPos = wheelFrame.AbsolutePosition
		local absSize = wheelFrame.AbsoluteSize
		if absSize.X <= 0 or absSize.Y <= 0 then
			return
		end
		local cx = absPos.X + absSize.X * 0.5
		local cy = absPos.Y + absSize.Y * 0.5
		local dx = pos.X - cx
		local dy = pos.Y - cy
		local steer, rotDeg = InputMapper.computeTouchWheelSteer(dx, dy)
		local angle =
			math.clamp(math.atan2(dx, math.abs(dy)), -InputMapper.MAX_WHEEL_ANGLE_RAD, InputMapper.MAX_WHEEL_ANGLE_RAD)
		state.wheelAxisX = angle / InputMapper.MAX_WHEEL_ANGLE_RAD
		state.wheelAxisY = math.clamp(dy / (absSize.Y * 0.5), -1.0, 1.0)
		state.wheelActive = true
		wheelImage.Rotation = rotDeg
		wheelMaskUp.ImageTransparency = if state.wheelAxisY < -InputMapper.TOUCH_DEADZONE then 0.35 else 1.0
		wheelMaskDown.ImageTransparency = if state.wheelAxisY > InputMapper.TOUCH_DEADZONE then 0.35 else 1.0
		gui:SetAttribute("LastWheelSteer", steer)
		gui:SetAttribute("LastWheelRotationDeg", rotDeg)
	end

	local function clearWheel()
		wheelTouch = nil
		state.wheelActive = false
		state.wheelAxisX = 0.0
		state.wheelAxisY = 0.0
		wheelImage.Rotation = 0
		wheelMaskUp.ImageTransparency = 1.0
		wheelMaskDown.ImageTransparency = 1.0
		gui:SetAttribute("LastWheelSteer", 0.0)
		gui:SetAttribute("LastWheelRotationDeg", 0.0)
	end

	local function setButtonPressed(binding: ButtonBinding, pressed: boolean)
		(state :: any)[binding.key] = pressed
		binding.bg.Image = if pressed then TEX_BG_BUTTON_FOCUS else TEX_BG_BUTTON
	end

	local simConn: RBXScriptConnection? = nil
	if RunService:IsStudio() then
		simConn = gui:GetAttributeChangedSignal("SimulatedDragOffset"):Connect(function()
			local off = gui:GetAttribute("SimulatedDragOffset")
			if typeof(off) == "Vector2" then
				local absPos = wheelFrame.AbsolutePosition
				local absSize = wheelFrame.AbsoluteSize
				local cx = absPos.X + absSize.X * 0.5
				local cy = absPos.Y + absSize.Y * 0.5
				updateWheelFromPos(Vector3.new(cx + off.X, cy + off.Y, 0))
			else
				clearWheel()
			end
		end)
	end

	local beganConn = UserInputService.InputBegan:Connect(function(inputObj: InputObject)
		if not gui.Enabled or inputObj.UserInputType ~= Enum.UserInputType.Touch then
			return
		end
		if wheelTouch == nil and isPointInside(wheelFrame, inputObj.Position) then
			wheelTouch = inputObj
			updateWheelFromPos(inputObj.Position)
			return
		end
		for _, b in buttons do
			if b.activeTouch == nil and isPointInside(b.frame, inputObj.Position) then
				b.activeTouch = inputObj
				setButtonPressed(b, true)
				return
			end
		end
	end)

	local movedConn = UserInputService.TouchMoved:Connect(function(inputObj: InputObject)
		if not gui.Enabled then
			return
		end
		if wheelTouch == inputObj then
			updateWheelFromPos(inputObj.Position)
		end
	end)

	local endedConn = UserInputService.InputEnded:Connect(function(inputObj: InputObject)
		if inputObj.UserInputType ~= Enum.UserInputType.Touch then
			return
		end
		if wheelTouch == inputObj then
			clearWheel()
		end
		for _, b in buttons do
			if b.activeTouch == inputObj then
				b.activeTouch = nil
				setButtonPressed(b, false)
			end
		end
	end)

	local gpConn = UserInputService.GamepadConnected:Connect(updateVisibility)
	local gpDiscConn = UserInputService.GamepadDisconnected:Connect(updateVisibility)
	local touchPropConn = UserInputService:GetPropertyChangedSignal("TouchEnabled"):Connect(updateVisibility)
	local previewConn = localPlayer:GetAttributeChangedSignal("ForceTouchPreview"):Connect(updateVisibility)

	updateVisibility()

	local function getState(): InputMapper.TouchState?
		if not gui.Enabled then
			return nil
		end
		local snapshot: InputMapper.TouchState = {
			wheelAxisX = state.wheelAxisX,
			wheelAxisY = state.wheelAxisY,
			wheelActive = state.wheelActive,
			accel = state.accel,
			brake = state.brake,
			drift = state.drift,
			nitro = state.nitro,
			fire = state.fire,
			lookBack = state.lookBack,
			reset = state.reset,
		}
		state.reset = false
		return snapshot
	end

	local function destroy()
		if simConn then
			simConn:Disconnect()
		end
		beganConn:Disconnect()
		movedConn:Disconnect()
		endedConn:Disconnect()
		gpConn:Disconnect()
		gpDiscConn:Disconnect()
		touchPropConn:Disconnect()
		previewConn:Disconnect()
		gui:Destroy()
	end

	return {
		gui = gui,
		getState = getState,
		destroy = destroy,
	}
end

return TouchControls
