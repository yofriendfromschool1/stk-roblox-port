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
InputMapper.MAX_WHEEL_ANGLE_RAD = math.pi * 0.5

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

export type KeyboardBindings = {
	accelerate: string,
	brake: string,
	steerLeft: string,
	steerRight: string,
	drift: string,
	fire: string,
	nitro: string,
	lookBack: string,
	rescue: string,
}

export type GamepadBindings = {
	accelerate: string,
	brake: string,
	drift: string,
	fire: string,
	nitro: string,
	lookBack: string,
	rescue: string,
}

export type InputBindings = {
	keyboard: KeyboardBindings,
	gamepad: GamepadBindings,
}

export type LiveMapper = {
	sample: () -> (KartInput, boolean, boolean, boolean),
	samplePlayer2: () -> (KartInput, boolean),
	setBindings: (bindings: InputBindings) -> (),
	setSuppressed: (suppressed: boolean) -> (),
	setLocalTwoPlayer: (enabled: boolean) -> (),
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

-- Drag-angle wheel mapping: touch offset (dx, dy) from wheel center -> (steer in [-1, 1], wheelAngleDeg)
-- Uses STK touch deadzone (0.1), sensitivity_x (0.2), and max deflection (+-90 deg).
function InputMapper.computeTouchWheelSteer(
	dx: number,
	dy: number,
	deadzone: number?,
	sensitivityX: number?,
	maxAngleRad: number?
): (number, number)
	if dx == 0.0 and dy == 0.0 then
		return 0.0, 0.0
	end
	local dz = deadzone or InputMapper.TOUCH_DEADZONE
	local sens = sensitivityX or InputMapper.TOUCH_SENSITIVITY_X
	local maxAng = maxAngleRad or InputMapper.MAX_WHEEL_ANGLE_RAD
	local rawAngle = math.atan2(dx, math.abs(dy))
	local clampedAngle = math.clamp(rawAngle, -maxAng, maxAng)
	local norm = clampedAngle / maxAng
	local rotDeg = math.deg(clampedAngle)
	if math.abs(norm) <= dz then
		return 0.0, rotDeg
	end
	local mag = InputMapper.getTouchSteeringFactor(math.abs(norm), dz, sens)
	return if norm < 0.0 then -mag else mag, rotDeg
end

-- Default keyboard bindings from src/input/keyboard_config.cpp:L54-L65 (STK 1.5)
function InputMapper.fromKeyboard(
	keysDown: { [string]: boolean },
	resetPulse: boolean?,
	grantNitroPulse: boolean?,
	bindings: KeyboardBindings?
): MappedInput
	local accelKey = if bindings then bindings.accelerate else "W"
	local brakeKey = if bindings then bindings.brake else "S"
	local leftKey = if bindings then bindings.steerLeft else "A"
	local rightKey = if bindings then bindings.steerRight else "D"
	local driftKey = if bindings then bindings.drift else "V"
	local nitroKey = if bindings then bindings.nitro else "N"
	local fireKey = if bindings then bindings.fire else "Space"
	local lookBackKey = if bindings then bindings.lookBack else "B"

	local accel = if keysDown[accelKey] or (not bindings and keysDown.Up) then 1.0 else 0.0
	local brake = (keysDown[brakeKey] == true) or (not bindings and keysDown.Down == true)

	local steer = 0.0
	if keysDown[leftKey] or (not bindings and keysDown.Left) then
		steer -= 1.0
	end
	if keysDown[rightKey] or (not bindings and keysDown.Right) then
		steer += 1.0
	end

	local drift = (keysDown[driftKey] == true)
		or (not bindings and ((keysDown.LeftShift == true) or (keysDown.RightShift == true)))
	local nitro = (keysDown[nitroKey] == true)
	local fire = (keysDown[fireKey] == true)
	local lookBack = (keysDown[lookBackKey] == true)

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
	resetPulse: boolean?,
	bindings: GamepadBindings?
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
	local accelBtn = if bindings then bindings.accelerate else "ButtonY"
	local buttonAccel = if buttonsDown[accelBtn] then 1.0 else 0.0
	local accel = math.max(triggerAccel, buttonAccel)

	local brakeBtn = if bindings then bindings.brake else "ButtonX"
	local driftBtn = if bindings then bindings.drift else "ButtonR1"
	local nitroBtn = if bindings then bindings.nitro else "ButtonL1"
	local fireBtn = if bindings then bindings.fire else "ButtonB"
	local lookBackBtn = if bindings then bindings.lookBack else "ButtonA"
	local rescueBtn = if bindings then bindings.rescue else "DPadUp"

	local brake = (axes.triggerL2 >= InputMapper.TRIGGER_THRESHOLD) or (buttonsDown[brakeBtn] == true)
	local drift = (buttonsDown[driftBtn] == true)
	local nitro = (buttonsDown[nitroBtn] == true)
	local fire = (buttonsDown[fireBtn] == true)
	local lookBack = (buttonsDown[lookBackBtn] == true) or (not bindings and buttonsDown.ButtonR3 == true)
	local reset = (resetPulse == true) or (buttonsDown.ButtonSelect == true) or (buttonsDown[rescueBtn] == true)

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

local function isGamepadInputType(userInputType: Enum.UserInputType): boolean
	return string.sub(userInputType.Name, 1, 7) == "Gamepad"
end

local function readGamepadAxes(userInputService: UserInputService, slot: Enum.UserInputType): GamepadAxes
	local axes: GamepadAxes = {
		thumbstick1X = 0.0,
		thumbstick1Y = 0.0,
		triggerR2 = 0.0,
		triggerL2 = 0.0,
	}
	for _, inputObj in userInputService:GetGamepadState(slot) do
		if inputObj.KeyCode == Enum.KeyCode.Thumbstick1 then
			axes.thumbstick1X = inputObj.Position.X
			axes.thumbstick1Y = inputObj.Position.Y
		elseif inputObj.KeyCode == Enum.KeyCode.ButtonR2 then
			axes.triggerR2 = inputObj.Position.Z
		elseif inputObj.KeyCode == Enum.KeyCode.ButtonL2 then
			axes.triggerL2 = inputObj.Position.Z
		end
	end
	return axes
end

function InputMapper.createLive(options: LiveOptions): LiveMapper
	local GuiService = game:GetService("GuiService")
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local UserInputService = game:GetService("UserInputService")
	local Shared = ReplicatedStorage:WaitForChild("Shared")
	local GamepadSelect = require(Shared.input.GamepadSelect)

	-- Prevent gamepad UI focus navigation from stealing driving buttons
	GuiService.AutoSelectGuiEnabled = false
	GuiService.SelectedObject = nil

	local resetPulse = false
	local grantNitroPulse = false
	local connectedGamepads: { Enum.UserInputType } = UserInputService:GetConnectedGamepads()
	local lastActiveSlot: Enum.UserInputType? = nil
	local gamepadButtonsBySlot: { [Enum.UserInputType]: { [string]: boolean } } = {}

	local function setGamepadButton(slot: Enum.UserInputType, keyCode: Enum.KeyCode, isDown: boolean)
		local buttonsDown = gamepadButtonsBySlot[slot]
		if not buttonsDown then
			buttonsDown = {}
			gamepadButtonsBySlot[slot] = buttonsDown
		end
		if keyCode == Enum.KeyCode.ButtonA then
			buttonsDown.ButtonA = isDown
		elseif keyCode == Enum.KeyCode.ButtonB then
			buttonsDown.ButtonB = isDown
		elseif keyCode == Enum.KeyCode.ButtonX then
			buttonsDown.ButtonX = isDown
		elseif keyCode == Enum.KeyCode.ButtonY then
			buttonsDown.ButtonY = isDown
		elseif keyCode == Enum.KeyCode.ButtonL1 then
			buttonsDown.ButtonL1 = isDown
		elseif keyCode == Enum.KeyCode.ButtonR1 then
			buttonsDown.ButtonR1 = isDown
		elseif keyCode == Enum.KeyCode.ButtonR3 then
			buttonsDown.ButtonR3 = isDown
		elseif keyCode == Enum.KeyCode.DPadLeft then
			buttonsDown.DPadLeft = isDown
		elseif keyCode == Enum.KeyCode.DPadRight then
			buttonsDown.DPadRight = isDown
		elseif keyCode == Enum.KeyCode.DPadUp then
			buttonsDown.DPadUp = isDown
		elseif keyCode == Enum.KeyCode.ButtonSelect then
			buttonsDown.ButtonSelect = isDown
		end
	end

	local connectedConn = UserInputService.GamepadConnected:Connect(function(_slot: Enum.UserInputType)
		connectedGamepads = UserInputService:GetConnectedGamepads()
	end)

	local disconnectedConn = UserInputService.GamepadDisconnected:Connect(function(slot: Enum.UserInputType)
		connectedGamepads = UserInputService:GetConnectedGamepads()
		gamepadButtonsBySlot[slot] = nil
		if lastActiveSlot == slot then
			lastActiveSlot = nil
		end
	end)

	local currentBindings: InputBindings = {
		keyboard = {
			accelerate = "W",
			brake = "S",
			steerLeft = "A",
			steerRight = "D",
			drift = "Space",
			fire = "F",
			nitro = "LeftShift",
			lookBack = "B",
			rescue = "R",
		},
		gamepad = {
			accelerate = "ButtonR2",
			brake = "ButtonL2",
			drift = "ButtonR1",
			fire = "ButtonA",
			nitro = "ButtonB",
			lookBack = "ButtonX",
			rescue = "ButtonY",
		},
	}
	local suppressed = false
	local localTwoPlayer = false

	local function resolveKeyCode(name: string): Enum.KeyCode?
		local ok, kc = pcall(function()
			return (Enum.KeyCode :: any)[name]
		end)
		if ok and typeof(kc) == "EnumItem" then
			return kc :: Enum.KeyCode
		end
		return nil
	end

	local function setBindings(bindings: InputBindings)
		currentBindings = bindings
	end

	local function setSuppressed(value: boolean)
		suppressed = value == true
	end

	local function setLocalTwoPlayer(enabled: boolean)
		localTwoPlayer = enabled == true
	end

	local function beganConnHandler(inputObj: InputObject, gameProcessed: boolean)
		if isGamepadInputType(inputObj.UserInputType) then
			GuiService.SelectedObject = nil
			lastActiveSlot = inputObj.UserInputType
			setGamepadButton(inputObj.UserInputType, inputObj.KeyCode, true)
			local rescueBtn = resolveKeyCode(currentBindings.gamepad.rescue)
			if
				not suppressed
				and (
					inputObj.KeyCode == Enum.KeyCode.ButtonSelect
					or inputObj.KeyCode == Enum.KeyCode.DPadUp
					or (rescueBtn ~= nil and inputObj.KeyCode == rescueBtn)
				)
			then
				resetPulse = true
			end
			return
		end
		if gameProcessed then
			return
		end
		local rescueKey = resolveKeyCode(currentBindings.keyboard.rescue)
		if
			not suppressed
			and ((rescueKey ~= nil and inputObj.KeyCode == rescueKey) or inputObj.KeyCode == Enum.KeyCode.Backspace)
		then
			resetPulse = true
		elseif inputObj.KeyCode == Enum.KeyCode.F3 then
			if options.onToggleDebugHud then
				options.onToggleDebugHud()
			end
		elseif not suppressed and options.isStudio and inputObj.KeyCode == Enum.KeyCode.G then
			grantNitroPulse = true
		elseif options.isStudio and inputObj.KeyCode == Enum.KeyCode.F8 then
			if options.onToggleLocalMode then
				options.onToggleLocalMode()
			end
		end
	end

	local beganConn = UserInputService.InputBegan:Connect(beganConnHandler)

	local endedConn = UserInputService.InputEnded:Connect(function(inputObj: InputObject)
		if isGamepadInputType(inputObj.UserInputType) then
			setGamepadButton(inputObj.UserInputType, inputObj.KeyCode, false)
		end
	end)

	local function sample(): (KartInput, boolean, boolean, boolean)
		if suppressed then
			resetPulse = false
			grantNitroPulse = false
			return {
				accel = 0,
				brake = false,
				steer = 0,
				drift = false,
				nitro = false,
				fire = false,
				lookBack = false,
			},
				false,
				false,
				false
		end

		local kb = currentBindings.keyboard
		local keysDown: { [string]: boolean } = {}
		local keyNames = {
			kb.accelerate,
			kb.brake,
			kb.steerLeft,
			kb.steerRight,
			kb.drift,
			kb.fire,
			kb.nitro,
			kb.lookBack,
			kb.rescue,
		}
		for _, keyName in ipairs(keyNames) do
			local kc = resolveKeyCode(keyName)
			if kc ~= nil then
				keysDown[keyName] = UserInputService:IsKeyDown(kc)
			end
		end

		local kbMapped = InputMapper.fromKeyboard(keysDown, resetPulse, options.isStudio and grantNitroPulse, kb)
		resetPulse = false
		grantNitroPulse = false

		local gpMapped = EMPTY_MAPPED
		if not localTwoPlayer and #connectedGamepads > 0 then
			local pads: { GamepadSelect.PadEntry<Enum.UserInputType> } = {}
			local axesBySlot: { [Enum.UserInputType]: GamepadAxes } = {}
			for _, slot in connectedGamepads do
				local axes = readGamepadAxes(UserInputService, slot)
				axesBySlot[slot] = axes
				table.insert(pads, { slot = slot, axes = axes })
			end

			local activeSlot = GamepadSelect.pickActive(pads, InputMapper.GAMEPAD_DEADZONE)
			if activeSlot ~= nil then
				lastActiveSlot = activeSlot
			end

			local selectedSlot = activeSlot or lastActiveSlot
			if selectedSlot ~= nil and axesBySlot[selectedSlot] ~= nil then
				gpMapped = InputMapper.fromGamepad(
					axesBySlot[selectedSlot],
					gamepadButtonsBySlot[selectedSlot] or {},
					false,
					currentBindings.gamepad
				)
			end
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

	local function samplePlayer2(): (KartInput, boolean)
		if suppressed or not localTwoPlayer or #connectedGamepads == 0 then
			return {
				accel = 0,
				brake = false,
				steer = 0,
				drift = false,
				nitro = false,
				fire = false,
				lookBack = false,
			},
				false
		end
		-- In Local 2P, P1 uses keyboard (or Gamepad1 if >=2 pads) and P2 uses the dedicated second gamepad (or first gamepad if only 1 connected).
		local p2Slot: Enum.UserInputType? = if #connectedGamepads >= 2
			then connectedGamepads[2]
			else connectedGamepads[1]
		if p2Slot == nil then
			return {
				accel = 0,
				brake = false,
				steer = 0,
				drift = false,
				nitro = false,
				fire = false,
				lookBack = false,
			},
				false
		end
		local axes = readGamepadAxes(UserInputService, p2Slot)
		local mapped = InputMapper.fromGamepad(axes, gamepadButtonsBySlot[p2Slot] or {}, false, currentBindings.gamepad)
		return mapped.kartInput, mapped.reset
	end

	local function destroy()
		connectedConn:Disconnect()
		disconnectedConn:Disconnect()
		beganConn:Disconnect()
		endedConn:Disconnect()
	end

	return {
		sample = sample,
		samplePlayer2 = samplePlayer2,
		setBindings = setBindings,
		setSuppressed = setSuppressed,
		setLocalTwoPlayer = setLocalTwoPlayer,
		destroy = destroy,
	}
end

return InputMapper
