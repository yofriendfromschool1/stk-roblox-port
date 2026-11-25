--!strict
-- src/client/InputMapper.lua
-- SPDX-License-Identifier: GPL-3.0-or-later
-- Ported from src/input/device_config.cpp:L225-L279, src/input/gamepad_config.cpp:L64-L144, L541-L551,
-- src/input/keyboard_config.cpp:L54-L65, and src/input/multitouch_device.cpp:L439-L504 (STK 1.5).
-- Client-side unified input mapper producing KartSolver.KartInput from Keyboard, Gamepad, and Touch.

local InputMapper = {}

-- Deadzone absent from src/input/device_config.cpp; src/input/gamepad_config.cpp:L64 defines
-- m_deadzone = 4096 (4096 / 32768 = 0.125). Rounded to 0.15 for Roblox thumbsticks (logged in docs/divergences.md).
InputMapper.GAMEPAD_DEADZONE = 0.15
InputMapper.TRIGGER_THRESHOLD = 0.25

-- Multitouch constants from src/config/user_config.hpp:L563, L569, L574 (STK 1.5)
InputMapper.TOUCH_DEADZONE = 0.1
InputMapper.TOUCH_SENSITIVITY_X = 0.2
InputMapper.TOUCH_SENSITIVITY_Y = 0.65

export type KartInput = {
	accel: number,
	brake: boolean,
	steer: number,
	drift: boolean,
	nitro: boolean?,
	fire: boolean?,
	lookBack: boolean?,
	skidControl: ("LEFT" | "NONE" | "NO_DIRECTION" | "RIGHT")?,
	instantSteer: boolean?,
}

export type MappedInput = {
	kartInput: KartInput,
	reset: boolean,
	grantNitro: boolean,
	lookBack: boolean,
}

export type GamepadAxes = {
	thumbstick1X: number,
	thumbstick1Y: number?,
	triggerR2: number,
	triggerL2: number,
}

export type TouchState = {
	wheelAxisX: number,
	wheelAxisY: number,
	wheelActive: boolean,
	accel: boolean,
	brake: boolean,
	drift: boolean,
	nitro: boolean,
	fire: boolean,
	lookBack: boolean,
	reset: boolean?,
}

export type LiveOptions = {
	isStudio: boolean,
	getTouchState: (() -> TouchState?)?,
	onToggleDebugHud: (() -> ())?,
	onToggleLocalMode: (() -> ())?,
}

export type LiveMapper = {
	sample: () -> (KartInput, boolean, boolean, boolean),
	destroy: () -> (),
}

-- Rescale thumbstick axis outside deadzone to [-1, +1]
function InputMapper.applyStickDeadzone(value: number, deadzone: number?): number
	local dz = deadzone or InputMapper.GAMEPAD_DEADZONE
	local mag = math.abs(value)
	if mag < dz or dz >= 1.0 then
		return 0.0
	end
	local rescaled = math.clamp((mag - dz) / (1.0 - dz), 0.0, 1.0)
	return if value < 0 then -rescaled else rescaled
end

-- Ported from src/input/multitouch_device.cpp:L439-L451 (STK 1.5)
function InputMapper.getTouchSteeringFactor(value: number, deadzone: number?, sensitivity: number?): number
	local dz = deadzone or InputMapper.TOUCH_DEADZONE
	local sens = sensitivity or InputMapper.TOUCH_SENSITIVITY_X
	if dz >= 1.0 then
		return 0.0
	end
	if sens >= 1.0 then
		return 1.0
	end
	local factor = (value - dz) / (1.0 - dz)
	factor *= 1.0 / (1.0 - sens)
	return math.clamp(factor, 0.0, 1.0)
end

-- Default keyboard bindings from src/input/keyboard_config.cpp:L54-L65 (STK 1.5)
function InputMapper.fromKeyboard(
	keysDown: { [string]: boolean },
	resetPulse: boolean?,
	grantNitroPulse: boolean?
): MappedInput
	local accel = if keysDown.W or keysDown.Up then 1.0 else 0.0
	local brake = (keysDown.S == true) or (keysDown.Down == true)

	local steer = 0.0
	if keysDown.A or keysDown.Left then
		steer -= 1.0
	end
	if keysDown.D or keysDown.Right then
		steer += 1.0
	end

	local drift = (keysDown.V == true) or (keysDown.LeftShift == true) or (keysDown.RightShift == true)
	local nitro = (keysDown.N == true)
	local fire = (keysDown.Space == true)
	local lookBack = (keysDown.B == true)

	return {
		kartInput = {
			accel = accel,
			brake = brake,
			steer = steer,
			drift = drift,
			nitro = nitro,
			fire = fire,
			lookBack = lookBack,
		},
		reset = resetPulse == true,
		grantNitro = grantNitroPulse == true,
		lookBack = lookBack,
	}
end

-- Gamepad mapping from src/input/gamepad_config.cpp:L125-L144, L541-L551 (STK 1.5)
-- Left thumbstick X / DPadLeft+Right -> steer; R2/ButtonY -> accel; L2/ButtonX -> brake;
-- ButtonR1 -> drift; ButtonL1 -> nitro; ButtonB -> fire; ButtonA/ButtonR3 -> lookBack; ButtonSelect/DPadUp -> reset.
function InputMapper.fromGamepad(
	axes: GamepadAxes,
	buttonsDown: { [string]: boolean },
	resetPulse: boolean?
): MappedInput
	local steer = InputMapper.applyStickDeadzone(axes.thumbstick1X, InputMapper.GAMEPAD_DEADZONE)
	if buttonsDown.DPadLeft then
		steer -= 1.0
	end
	if buttonsDown.DPadRight then
		steer += 1.0
	end
	steer = math.clamp(steer, -1.0, 1.0)

	local triggerAccel = if axes.triggerR2 > 0.05 then math.clamp(axes.triggerR2, 0.0, 1.0) else 0.0
	local buttonAccel = if buttonsDown.ButtonY then 1.0 else 0.0
	local accel = math.max(triggerAccel, buttonAccel)

	local brake = (axes.triggerL2 >= InputMapper.TRIGGER_THRESHOLD) or (buttonsDown.ButtonX == true)
	local drift = (buttonsDown.ButtonR1 == true)
	local nitro = (buttonsDown.ButtonL1 == true)
	local fire = (buttonsDown.ButtonB == true)
	local lookBack = (buttonsDown.ButtonA == true) or (buttonsDown.ButtonR3 == true)
	local reset = (resetPulse == true) or (buttonsDown.ButtonSelect == true) or (buttonsDown.DPadUp == true)

	return {
		kartInput = {
			accel = accel,
			brake = brake,
			steer = steer,
			drift = drift,
			nitro = nitro,
			fire = fire,
			lookBack = lookBack,
		},
		reset = reset,
		grantNitro = false,
		lookBack = lookBack,
	}
end

-- Multitouch mapping from src/input/multitouch_device.cpp:L455-L504 (STK 1.5)
function InputMapper.fromTouch(touch: TouchState, resetPulse: boolean?): MappedInput
	local steer = 0.0
	local wheelAccel = 0.0
	local wheelBrake = false

	if touch.wheelActive then
		if touch.wheelAxisX < -InputMapper.TOUCH_DEADZONE then
			steer = -InputMapper.getTouchSteeringFactor(
				math.abs(touch.wheelAxisX),
				InputMapper.TOUCH_DEADZONE,
				InputMapper.TOUCH_SENSITIVITY_X
			)
		elseif touch.wheelAxisX > InputMapper.TOUCH_DEADZONE then
			steer = InputMapper.getTouchSteeringFactor(
				math.abs(touch.wheelAxisX),
				InputMapper.TOUCH_DEADZONE,
				InputMapper.TOUCH_SENSITIVITY_X
			)
		end

		if touch.wheelAxisY < -InputMapper.TOUCH_DEADZONE then
			wheelAccel = InputMapper.getTouchSteeringFactor(
				math.abs(touch.wheelAxisY),
				InputMapper.TOUCH_DEADZONE,
				InputMapper.TOUCH_SENSITIVITY_Y
			)
		elseif touch.wheelAxisY > InputMapper.TOUCH_DEADZONE then
			wheelBrake = true
		end
	end

	local accel = math.max(if touch.accel then 1.0 else 0.0, wheelAccel)
	local brake = touch.brake or wheelBrake
	local lookBack = touch.lookBack
	local reset = (resetPulse == true) or (touch.reset == true)

	return {
		kartInput = {
			accel = accel,
			brake = brake,
			steer = steer,
			drift = touch.drift,
			nitro = touch.nitro,
			fire = touch.fire,
			lookBack = lookBack,
		},
		reset = reset,
		grantNitro = false,
		lookBack = lookBack,
	}
end

function InputMapper.combine(a: MappedInput, b: MappedInput, c: MappedInput): MappedInput
	local accel = math.clamp(math.max(a.kartInput.accel, b.kartInput.accel, c.kartInput.accel), 0.0, 1.0)
	local brake = a.kartInput.brake or b.kartInput.brake or c.kartInput.brake
	local steer = math.clamp(a.kartInput.steer + b.kartInput.steer + c.kartInput.steer, -1.0, 1.0)
	local drift = a.kartInput.drift or b.kartInput.drift or c.kartInput.drift
	local nitro = (a.kartInput.nitro == true) or (b.kartInput.nitro == true) or (c.kartInput.nitro == true)
	local fire = (a.kartInput.fire == true) or (b.kartInput.fire == true) or (c.kartInput.fire == true)
	local lookBack = a.lookBack or b.lookBack or c.lookBack
	local reset = a.reset or b.reset or c.reset
	local grantNitro = a.grantNitro or b.grantNitro or c.grantNitro

	return {
		kartInput = {
			accel = accel,
			brake = brake,
			steer = steer,
			drift = drift,
			nitro = nitro,
			fire = fire,
			lookBack = lookBack,
		},
		reset = reset,
		grantNitro = grantNitro,
		lookBack = lookBack,
	}
end

local EMPTY_MAPPED: MappedInput = {
	kartInput = {
		accel = 0.0,
		brake = false,
		steer = 0.0,
		drift = false,
		nitro = false,
		fire = false,
		lookBack = false,
	},
	reset = false,
	grantNitro = false,
	lookBack = false,
}

function InputMapper.createLive(options: LiveOptions): LiveMapper
	local GuiService = game:GetService("GuiService")
	local UserInputService = game:GetService("UserInputService")

	-- Prevent gamepad UI focus navigation from stealing driving buttons
	GuiService.AutoSelectGuiEnabled = false
	GuiService.SelectedObject = nil

	local resetPulse = false
	local grantNitroPulse = false
	local gamepadButtonsDown: { [string]: boolean } = {}

	local function setGamepadButton(keyCode: Enum.KeyCode, isDown: boolean)
		if keyCode == Enum.KeyCode.ButtonA then
			gamepadButtonsDown.ButtonA = isDown
		elseif keyCode == Enum.KeyCode.ButtonB then
			gamepadButtonsDown.ButtonB = isDown
		elseif keyCode == Enum.KeyCode.ButtonX then
			gamepadButtonsDown.ButtonX = isDown
		elseif keyCode == Enum.KeyCode.ButtonY then
			gamepadButtonsDown.ButtonY = isDown
		elseif keyCode == Enum.KeyCode.ButtonL1 then
			gamepadButtonsDown.ButtonL1 = isDown
		elseif keyCode == Enum.KeyCode.ButtonR1 then
			gamepadButtonsDown.ButtonR1 = isDown
		elseif keyCode == Enum.KeyCode.ButtonR3 then
			gamepadButtonsDown.ButtonR3 = isDown
		elseif keyCode == Enum.KeyCode.DPadLeft then
			gamepadButtonsDown.DPadLeft = isDown
		elseif keyCode == Enum.KeyCode.DPadRight then
			gamepadButtonsDown.DPadRight = isDown
		elseif keyCode == Enum.KeyCode.DPadUp then
			gamepadButtonsDown.DPadUp = isDown
		elseif keyCode == Enum.KeyCode.ButtonSelect then
			gamepadButtonsDown.ButtonSelect = isDown
		end
	end

	local beganConn = UserInputService.InputBegan:Connect(function(inputObj: InputObject, gameProcessed: boolean)
		if inputObj.UserInputType == Enum.UserInputType.Gamepad1 then
			GuiService.SelectedObject = nil
			setGamepadButton(inputObj.KeyCode, true)
			if inputObj.KeyCode == Enum.KeyCode.ButtonSelect or inputObj.KeyCode == Enum.KeyCode.DPadUp then
				resetPulse = true
			end
			return
		end
		if gameProcessed then
			return
		end
		if inputObj.KeyCode == Enum.KeyCode.R or inputObj.KeyCode == Enum.KeyCode.Backspace then
			resetPulse = true
		elseif inputObj.KeyCode == Enum.KeyCode.F3 then
			if options.onToggleDebugHud then
				options.onToggleDebugHud()
			end
		elseif options.isStudio and inputObj.KeyCode == Enum.KeyCode.G then
			grantNitroPulse = true
		elseif options.isStudio and inputObj.KeyCode == Enum.KeyCode.F8 then
			if options.onToggleLocalMode then
				options.onToggleLocalMode()
			end
		end
	end)

	local endedConn = UserInputService.InputEnded:Connect(function(inputObj: InputObject)
		if inputObj.UserInputType == Enum.UserInputType.Gamepad1 then
			setGamepadButton(inputObj.KeyCode, false)
		end
	end)

	local function sample(): (KartInput, boolean, boolean, boolean)
		local keysDown: { [string]: boolean } = {
			W = UserInputService:IsKeyDown(Enum.KeyCode.W),
			Up = UserInputService:IsKeyDown(Enum.KeyCode.Up),
			S = UserInputService:IsKeyDown(Enum.KeyCode.S),
			Down = UserInputService:IsKeyDown(Enum.KeyCode.Down),
			A = UserInputService:IsKeyDown(Enum.KeyCode.A),
			Left = UserInputService:IsKeyDown(Enum.KeyCode.Left),
			D = UserInputService:IsKeyDown(Enum.KeyCode.D),
			Right = UserInputService:IsKeyDown(Enum.KeyCode.Right),
			V = UserInputService:IsKeyDown(Enum.KeyCode.V),
			LeftShift = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift),
			RightShift = UserInputService:IsKeyDown(Enum.KeyCode.RightShift),
			N = UserInputService:IsKeyDown(Enum.KeyCode.N),
			Space = UserInputService:IsKeyDown(Enum.KeyCode.Space),
			B = UserInputService:IsKeyDown(Enum.KeyCode.B),
		}

		local kbMapped = InputMapper.fromKeyboard(keysDown, resetPulse, options.isStudio and grantNitroPulse)
		resetPulse = false
		grantNitroPulse = false

		local gpMapped = EMPTY_MAPPED
		if UserInputService:GetGamepadConnected(Enum.UserInputType.Gamepad1) then
			local axes: GamepadAxes = {
				thumbstick1X = 0.0,
				thumbstick1Y = 0.0,
				triggerR2 = 0.0,
				triggerL2 = 0.0,
			}
			for _, inputObj in UserInputService:GetGamepadState(Enum.UserInputType.Gamepad1) do
				if inputObj.KeyCode == Enum.KeyCode.Thumbstick1 then
					axes.thumbstick1X = inputObj.Position.X
					axes.thumbstick1Y = inputObj.Position.Y
				elseif inputObj.KeyCode == Enum.KeyCode.ButtonR2 then
					axes.triggerR2 = inputObj.Position.Z
				elseif inputObj.KeyCode == Enum.KeyCode.ButtonL2 then
					axes.triggerL2 = inputObj.Position.Z
				end
			end
			gpMapped = InputMapper.fromGamepad(axes, gamepadButtonsDown, false)
		end

		local touchMapped = EMPTY_MAPPED
		if options.getTouchState then
			local touchState = options.getTouchState()
			if touchState ~= nil then
				touchMapped = InputMapper.fromTouch(touchState, false)
			end
		end

		local combined = InputMapper.combine(kbMapped, gpMapped, touchMapped)
		return combined.kartInput, combined.reset, combined.grantNitro, combined.lookBack
	end

	local function destroy()
		beganConn:Disconnect()
		endedConn:Disconnect()
	end

	return {
		sample = sample,
		destroy = destroy,
	}
end

return InputMapper
