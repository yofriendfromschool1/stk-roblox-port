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

return tests
