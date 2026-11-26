--!strict
-- tests/InputMapper.spec.luau
-- SPDX-License-Identifier: GPL-3.0-or-later

local InputMapper = require("../src/client/InputMapper")

local function assertNear(actual: number, expected: number, eps: number, label: string)
	if math.abs(actual - expected) > eps then
		error(string.format("%s: expected %.6f +/- %.6f, got %.6f", label, expected, eps, actual))
	end
end

local function assertEqual(actual: any, expected: any, label: string)
	if actual ~= expected then
		error(string.format("%s: expected %s, got %s", label, tostring(expected), tostring(actual)))
	end
end

local function assertSameMappedInput(a: InputMapper.MappedInput, b: InputMapper.MappedInput, label: string)
	assertNear(a.kartInput.accel, b.kartInput.accel, 1e-6, label .. ".accel")
	assertEqual(a.kartInput.brake, b.kartInput.brake, label .. ".brake")
	assertNear(a.kartInput.steer, b.kartInput.steer, 1e-6, label .. ".steer")
	assertEqual(a.kartInput.drift, b.kartInput.drift, label .. ".drift")
	assertEqual(a.kartInput.nitro, b.kartInput.nitro, label .. ".nitro")
	assertEqual(a.kartInput.fire, b.kartInput.fire, label .. ".fire")
	assertEqual(a.kartInput.lookBack, b.kartInput.lookBack, label .. ".lookBack")
	assertEqual(a.reset, b.reset, label .. ".reset")
	assertEqual(a.lookBack, b.lookBack, label .. ".topLookBack")
end

local tests = {}

table.insert(tests, {
	name = "keyboard, gamepad, and touch produce identical KartInput structs for equivalent input",
	fn = function()
		local scenarios = {
			{
				name = "idle",
				kb = {},
				kbReset = false,
				gpAxes = { thumbstick1X = 0.0, triggerR2 = 0.0, triggerL2 = 0.0 },
				gpButtons = {},
				touch = {
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
				},
			},
			{
				name = "drive_steer_left_drift_nitro",
				kb = { W = true, A = true, V = true, N = true },
				kbReset = false,
				gpAxes = { thumbstick1X = -1.0, triggerR2 = 1.0, triggerL2 = 0.0 },
				gpButtons = { ButtonR1 = true, ButtonL1 = true },
				touch = {
					wheelAxisX = -1.0,
					wheelAxisY = 0.0,
					wheelActive = true,
					accel = true,
					brake = false,
					drift = true,
					nitro = true,
					fire = false,
					lookBack = false,
					reset = false,
				},
			},
			{
				name = "brake_steer_right_fire_lookback_reset",
				kb = { S = true, D = true, Space = true, B = true },
				kbReset = true,
				gpAxes = { thumbstick1X = 1.0, triggerR2 = 0.0, triggerL2 = 1.0 },
				gpButtons = { ButtonB = true, ButtonA = true, ButtonSelect = true },
				touch = {
					wheelAxisX = 1.0,
					wheelAxisY = 0.0,
					wheelActive = true,
					accel = false,
					brake = true,
					drift = false,
					nitro = false,
					fire = true,
					lookBack = true,
					reset = true,
				},
			},
		}

		for _, s in scenarios do
			local kbOut = InputMapper.fromKeyboard(s.kb, s.kbReset, false)
			local gpOut = InputMapper.fromGamepad(s.gpAxes, s.gpButtons, false)
			local touchOut = InputMapper.fromTouch(s.touch, false)

			assertSameMappedInput(kbOut, gpOut, s.name .. " kb vs gp")
			assertSameMappedInput(kbOut, touchOut, s.name .. " kb vs touch")
		end
	end,
})

table.insert(tests, {
	name = "gamepad thumbstick deadzone zeroes drift below 0.15 and rescales above",
	fn = function()
		assertNear(InputMapper.applyStickDeadzone(0.0), 0.0, 1e-6, "zero")
		assertNear(InputMapper.applyStickDeadzone(0.14), 0.0, 1e-6, "inside positive deadzone")
		assertNear(InputMapper.applyStickDeadzone(-0.14), 0.0, 1e-6, "inside negative deadzone")
		assertNear(InputMapper.applyStickDeadzone(1.0), 1.0, 1e-6, "full right")
		assertNear(InputMapper.applyStickDeadzone(-1.0), -1.0, 1e-6, "full left")
		local mid = InputMapper.applyStickDeadzone(0.575)
		assertNear(mid, 0.5, 1e-6, "midpoint rescale")
	end,
})

table.insert(tests, {
	name = "combine merges keyboard, gamepad, and touch cleanly",
	fn = function()
		local kb = InputMapper.fromKeyboard({ W = true }, false, true)
		local gp = InputMapper.fromGamepad(
			{ thumbstick1X = 0.0, triggerR2 = 0.0, triggerL2 = 0.0 },
			{ ButtonR1 = true },
			false
		)
		local touch = InputMapper.fromTouch({
			wheelAxisX = 0.0,
			wheelAxisY = 0.0,
			wheelActive = false,
			accel = false,
			brake = false,
			drift = false,
			nitro = true,
			fire = false,
			lookBack = true,
			reset = false,
		}, false)

		local merged = InputMapper.combine(kb, gp, touch)
		assertNear(merged.kartInput.accel, 1.0, 1e-6, "merged accel")
		assertEqual(merged.kartInput.drift, true, "merged drift")
		assertEqual(merged.kartInput.nitro, true, "merged nitro")
		assertEqual(merged.kartInput.lookBack, true, "merged lookBack")
		assertEqual(merged.grantNitro, true, "merged grantNitro")
	end,
})

table.insert(tests, {
	name = "touch steering wheel drag-angle mapping matches STK deadzone and sensitivity at boundary angles",
	fn = function()
		-- 0 deg -> deadzone -> 0
		local s0, r0 = InputMapper.computeTouchWheelSteer(0, -100)
		assertNear(s0, 0.0, 1e-6, "0 deg steer")
		assertNear(r0, 0.0, 1e-6, "0 deg rot")

		-- 9 deg (norm = 0.10 <= TOUCH_DEADZONE) -> 0
		local rad9 = math.rad(9)
		local s9, _ = InputMapper.computeTouchWheelSteer(math.sin(rad9) * 100, -math.cos(rad9) * 100)
		assertNear(s9, 0.0, 1e-6, "9 deg boundary deadzone")

		-- +/-45 deg -> norm = 0.5 -> factor = ((0.5 - 0.1)/0.9)/(1 - 0.2) = 0.555556
		local sPos45, rPos45 = InputMapper.computeTouchWheelSteer(100, -100)
		assertNear(sPos45, (0.5 - 0.1) / 0.9 / 0.8, 1e-5, "+45 deg steer")
		assertNear(rPos45, 45.0, 1e-4, "+45 deg rot")

		local sNeg45, rNeg45 = InputMapper.computeTouchWheelSteer(-100, -100)
		assertNear(sNeg45, -((0.5 - 0.1) / 0.9 / 0.8), 1e-5, "-45 deg steer")
		assertNear(rNeg45, -45.0, 1e-4, "-45 deg rot")

		-- +/-90 deg -> full +/-1.0
		local sPos90, rPos90 = InputMapper.computeTouchWheelSteer(100, 0)
		assertNear(sPos90, 1.0, 1e-6, "+90 deg steer")
		assertNear(rPos90, 90.0, 1e-4, "+90 deg rot")

		local sNeg90, rNeg90 = InputMapper.computeTouchWheelSteer(-100, 0)
		assertNear(sNeg90, -1.0, 1e-6, "-90 deg steer")
		assertNear(rNeg90, -90.0, 1e-4, "-90 deg rot")
	end,
})

return tests
