--!strict
-- tests/GamepadSelect.spec.luau
-- SPDX-License-Identifier: GPL-3.0-or-later

local GamepadSelect = require("../src/shared/input/GamepadSelect")

local function assertEqual(actual: any, expected: any, label: string)
	if actual ~= expected then
		error(string.format("%s: expected %s, got %s", label, tostring(expected), tostring(actual)))
	end
end

local tests = {}

table.insert(tests, {
	name = "idle pad below deadzone is ignored",
	fn = function()
		local pads = {
			{
				slot = 1,
				axes = { thumbstick1X = 0.14, thumbstick1Y = -0.14, triggerR2 = 0.05, triggerL2 = 0.0 },
			},
		}
		assertEqual(GamepadSelect.pickActive(pads, 0.15), nil, "single idle pad")
	end,
})

table.insert(tests, {
	name = "active pad chosen regardless of slot index (slot 2 and slot 3)",
	fn = function()
		local padsSlot2 = {
			{
				slot = 1,
				axes = { thumbstick1X = 0.05, thumbstick1Y = 0.0, triggerR2 = 0.0, triggerL2 = 0.0 },
			},
			{
				slot = 2,
				axes = { thumbstick1X = -0.60, thumbstick1Y = 0.0, triggerR2 = 0.0, triggerL2 = 0.0 },
			},
		}
		assertEqual(GamepadSelect.pickActive(padsSlot2, 0.15), 2, "slot 2 active while slot 1 idle")

		local padsSlot3 = {
			{
				slot = 1,
				axes = { thumbstick1X = 0.0, thumbstick1Y = 0.0, triggerR2 = 0.0, triggerL2 = 0.0 },
			},
			{
				slot = 2,
				axes = { thumbstick1X = 0.10, thumbstick1Y = 0.10, triggerR2 = 0.0, triggerL2 = 0.0 },
			},
			{
				slot = 3,
				axes = { thumbstick1X = 0.0, thumbstick1Y = 0.0, triggerR2 = 0.80, triggerL2 = 0.0 },
			},
		}
		assertEqual(GamepadSelect.pickActive(padsSlot3, 0.15), 3, "slot 3 active via trigger while slots 1-2 idle")
	end,
})

table.insert(tests, {
	name = "two active pads -> greater magnitude wins (and last-active wins ties)",
	fn = function()
		local padsSecondWins = {
			{
				slot = 1,
				axes = { thumbstick1X = 0.40, thumbstick1Y = 0.0, triggerR2 = 0.0, triggerL2 = 0.0 },
			},
			{
				slot = 2,
				axes = { thumbstick1X = 0.0, thumbstick1Y = 0.0, triggerR2 = 0.75, triggerL2 = 0.0 },
			},
		}
		assertEqual(GamepadSelect.pickActive(padsSecondWins, 0.15), 2, "slot 2 greater magnitude")

		local padsFirstWins = {
			{
				slot = 1,
				axes = { thumbstick1X = -0.85, thumbstick1Y = 0.0, triggerR2 = 0.0, triggerL2 = 0.0 },
			},
			{
				slot = 2,
				axes = { thumbstick1X = 0.50, thumbstick1Y = 0.0, triggerR2 = 0.0, triggerL2 = 0.0 },
			},
		}
		assertEqual(GamepadSelect.pickActive(padsFirstWins, 0.15), 1, "slot 1 greater magnitude")

		local padsTie = {
			{
				slot = 1,
				axes = { thumbstick1X = 0.60, thumbstick1Y = 0.0, triggerR2 = 0.0, triggerL2 = 0.0 },
			},
			{
				slot = 3,
				axes = { thumbstick1X = -0.60, thumbstick1Y = 0.0, triggerR2 = 0.0, triggerL2 = 0.0 },
			},
		}
		assertEqual(GamepadSelect.pickActive(padsTie, 0.15), 3, "last-active wins equal magnitude tie")
	end,
})

table.insert(tests, {
	name = "all idle or empty -> nil",
	fn = function()
		assertEqual(GamepadSelect.pickActive({}, 0.15), nil, "empty pad list")

		local allIdle = {
			{
				slot = 1,
				axes = { thumbstick1X = 0.14, thumbstick1Y = 0.12, triggerR2 = 0.0, triggerL2 = 0.0 },
			},
			{
				slot = 2,
				axes = { thumbstick1X = -0.10, thumbstick1Y = 0.0, triggerR2 = 0.15, triggerL2 = 0.0 },
			},
		}
		assertEqual(GamepadSelect.pickActive(allIdle, 0.15), nil, "all pads at or below deadzone")
	end,
})

return tests
