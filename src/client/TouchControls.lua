--!strict
-- src/client/TouchControls.lua
-- SPDX-License-Identifier: GPL-3.0-or-later
-- Ported from src/states_screens/race_gui_multitouch.cpp:L203-L271 (STK 1.5).
-- On-screen touch steering wheel + action buttons, shown only when TouchEnabled and no gamepad connected.

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local InputMapper = require("./InputMapper")

local TouchControls = {}

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
		gui.Enabled = UserInputService.TouchEnabled and not hasGamepad
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

	-- Steering Wheel (bottom-left, race_gui_multitouch.cpp:L221-L224, L249-L251)
	local wheelFrame = Instance.new("Frame")
	wheelFrame.Name = "SteeringWheel"
	wheelFrame.SizeConstraint = Enum.SizeConstraint.RelativeYY
	wheelFrame.AnchorPoint = Vector2.new(0, 1)
	wheelFrame.Position = UDim2.fromScale(0.03, 1.0 - WHEEL_MARGIN)
	wheelFrame.Size = UDim2.fromScale(BTN2_SIZE, BTN2_SIZE)
	wheelFrame.BackgroundColor3 = Color3.fromRGB(20, 24, 34)
	wheelFrame.BackgroundTransparency = 0.45
	wheelFrame.BorderSizePixel = 0
	wheelFrame.Parent = gui

	local wheelCorner = Instance.new("UICorner")
	wheelCorner.CornerRadius = UDim.new(0.5, 0)
	wheelCorner.Parent = wheelFrame

	local wheelStroke = Instance.new("UIStroke")
	wheelStroke.Color = Color3.fromRGB(165, 200, 255)
	wheelStroke.Thickness = 2
	wheelStroke.Transparency = 0.25
	wheelStroke.Parent = wheelFrame

	local wheelKnob = Instance.new("Frame")
	wheelKnob.Name = "Knob"
	wheelKnob.AnchorPoint = Vector2.new(0.5, 0.5)
	wheelKnob.Position = UDim2.fromScale(0.5, 0.5)
	wheelKnob.Size = UDim2.fromScale(0.32, 0.32)
	wheelKnob.BackgroundColor3 = Color3.fromRGB(185, 215, 255)
	wheelKnob.BackgroundTransparency = 0.25
	wheelKnob.BorderSizePixel = 0
	wheelKnob.Parent = wheelFrame

	local knobCorner = Instance.new("UICorner")
	knobCorner.CornerRadius = UDim.new(0.5, 0)
	knobCorner.Parent = wheelKnob

	local wheelLabel = Instance.new("TextLabel")
	wheelLabel.Name = "Label"
	wheelLabel.AnchorPoint = Vector2.new(0.5, 1)
	wheelLabel.Position = UDim2.fromScale(0.5, 0.92)
	wheelLabel.Size = UDim2.fromScale(0.7, 0.14)
	wheelLabel.BackgroundTransparency = 1
	wheelLabel.Font = Enum.Font.GothamBold
	wheelLabel.TextScaled = true
	wheelLabel.TextColor3 = Color3.fromRGB(210, 225, 245)
	wheelLabel.Text = "STEER"
	wheelLabel.Parent = wheelFrame

	local function makeButton(
		parent: Instance,
		name: string,
		label: string,
		pos: UDim2,
		size: UDim2,
		accent: Color3
	): (Frame, UIStroke)
		local btn = Instance.new("Frame")
		btn.Name = name
		btn.AnchorPoint = Vector2.new(1, 1)
		btn.Position = pos
		btn.Size = size
		btn.BackgroundColor3 = Color3.fromRGB(20, 24, 34)
		btn.BackgroundTransparency = 0.4
		btn.BorderSizePixel = 0
		btn.Parent = parent

		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0.5, 0)
		corner.Parent = btn

		local stroke = Instance.new("UIStroke")
		stroke.Color = accent
		stroke.Thickness = 2
		stroke.Transparency = 0.2
		stroke.Parent = btn

		local txt = Instance.new("TextLabel")
		txt.Name = "Label"
		txt.AnchorPoint = Vector2.new(0.5, 0.5)
		txt.Position = UDim2.fromScale(0.5, 0.5)
		txt.Size = UDim2.fromScale(0.78, 0.42)
		txt.BackgroundTransparency = 1
		txt.Font = Enum.Font.GothamBold
		txt.TextScaled = true
		txt.TextColor3 = Color3.fromRGB(240, 244, 250)
		txt.Text = label
		txt.Parent = btn

		return btn, stroke
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

	local nitroBtn, nitroStroke = makeButton(
		rightGrid,
		"Nitro",
		"NITRO",
		UDim2.fromScale(1.0, 1.0 - rowStepY),
		cellBtnSize,
		Color3.fromRGB(90, 185, 255)
	)
	local driftBtn, driftStroke =
		makeButton(rightGrid, "Drift", "DRIFT", UDim2.fromScale(1.0, 1.0), cellBtnSize, Color3.fromRGB(255, 190, 90))
	local fireBtn, fireStroke = makeButton(
		rightGrid,
		"Fire",
		"ITEM",
		UDim2.fromScale(1.0 - colStepX, 1.0 - rowStepY),
		cellBtnSize,
		Color3.fromRGB(255, 115, 115)
	)
	local lookBackBtn, lookBackStroke = makeButton(
		rightGrid,
		"LookBack",
		"LOOK",
		UDim2.fromScale(1.0 - colStepX, 1.0),
		cellBtnSize,
		Color3.fromRGB(190, 200, 220)
	)
	local accelBtn, accelStroke = makeButton(
		rightGrid,
		"Accel",
		"GAS",
		UDim2.fromScale(1.0 - 2.0 * colStepX, 1.0),
		cellBtnSize,
		Color3.fromRGB(115, 240, 145)
	)
	local brakeBtn, brakeStroke = makeButton(
		rightGrid,
		"Brake",
		"BRAKE",
		UDim2.fromScale(1.0 - 2.0 * colStepX, 1.0 - rowStepY),
		cellBtnSize,
		Color3.fromRGB(240, 130, 130)
	)

	-- Top rescue/reset button (race_gui_multitouch.cpp:L257-L259)
	local resetBtn, resetStroke = makeButton(
		gui,
		"Reset",
		"RESET",
		UDim2.fromScale(0.35, MARGIN_SMALL + BTN_SMALL_SIZE),
		UDim2.fromScale(BTN_SMALL_SIZE, BTN_SMALL_SIZE),
		Color3.fromRGB(220, 220, 235)
	)
	resetBtn.SizeConstraint = Enum.SizeConstraint.RelativeYY
	resetBtn.AnchorPoint = Vector2.new(0, 1)

	type ButtonBinding = {
		frame: Frame,
		stroke: UIStroke,
		key: "accel" | "brake" | "drift" | "nitro" | "fire" | "lookBack" | "reset",
		activeTouch: InputObject?,
	}

	local buttons: { ButtonBinding } = {
		{ frame = accelBtn, stroke = accelStroke, key = "accel", activeTouch = nil },
		{ frame = brakeBtn, stroke = brakeStroke, key = "brake", activeTouch = nil },
		{ frame = driftBtn, stroke = driftStroke, key = "drift", activeTouch = nil },
		{ frame = nitroBtn, stroke = nitroStroke, key = "nitro", activeTouch = nil },
		{ frame = fireBtn, stroke = fireStroke, key = "fire", activeTouch = nil },
		{ frame = lookBackBtn, stroke = lookBackStroke, key = "lookBack", activeTouch = nil },
		{ frame = resetBtn, stroke = resetStroke, key = "reset", activeTouch = nil },
	}

	local wheelTouch: InputObject? = nil

	local function updateWheelFromPos(pos: Vector3)
		local absPos = wheelFrame.AbsolutePosition
		local absSize = wheelFrame.AbsoluteSize
		if absSize.X <= 0 or absSize.Y <= 0 then
			return
		end
		local ax = math.clamp((pos.X - absPos.X) / (absSize.X * 0.5) - 1.0, -1.0, 1.0)
		local ay = math.clamp((pos.Y - absPos.Y) / (absSize.Y * 0.5) - 1.0, -1.0, 1.0)
		state.wheelAxisX = ax
		state.wheelAxisY = ay
		state.wheelActive = true
		wheelKnob.Position = UDim2.fromScale(0.5 + ax * 0.32, 0.5 + ay * 0.32)
	end

	local function clearWheel()
		wheelTouch = nil
		state.wheelActive = false
		state.wheelAxisX = 0.0
		state.wheelAxisY = 0.0
		wheelKnob.Position = UDim2.fromScale(0.5, 0.5)
	end

	local function setButtonPressed(binding: ButtonBinding, pressed: boolean)
		(state :: any)[binding.key] = pressed
		binding.frame.BackgroundTransparency = if pressed then 0.15 else 0.4
		binding.stroke.Transparency = if pressed then 0.0 else 0.2
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
		-- Reset is a pulse
		state.reset = false
		return snapshot
	end

	local function destroy()
		beganConn:Disconnect()
		movedConn:Disconnect()
		endedConn:Disconnect()
		gpConn:Disconnect()
		gpDiscConn:Disconnect()
		touchPropConn:Disconnect()
		gui:Destroy()
	end

	return {
		gui = gui,
		getState = getState,
		destroy = destroy,
	}
end

return TouchControls
