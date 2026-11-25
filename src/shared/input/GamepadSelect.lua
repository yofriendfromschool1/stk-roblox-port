--!strict
-- src/shared/input/GamepadSelect.lua
-- SPDX-License-Identifier: GPL-3.0-or-later
-- Pure Luau active-gamepad selection across multiple connected gamepad slots.
-- Picks the pad with the greatest single-axis magnitude above deadzone (last-active wins on ties).

local GamepadSelect = {}

export type GamepadAxes = {
	thumbstick1X: number,
	thumbstick1Y: number?,
	triggerR2: number,
	triggerL2: number,
}

export type PadEntry<T> = {
	slot: T,
	axes: GamepadAxes,
}

function GamepadSelect.getPadMagnitude(axes: GamepadAxes): number
	return math.max(
		math.abs(axes.thumbstick1X or 0.0),
		math.abs(axes.thumbstick1Y or 0.0),
		math.abs(axes.triggerR2 or 0.0),
		math.abs(axes.triggerL2 or 0.0)
	)
end

-- Returns the slot of the pad with greatest axis magnitude above deadzone, or nil if all pads are idle.
-- Does not sum across pads; on equal magnitude, later (last-active) entries win.
function GamepadSelect.pickActive<T>(pads: { PadEntry<T> }, deadzone: number?): T?
	local dz = deadzone or 0.15
	local bestSlot: T? = nil
	local bestMag = dz

	for _, pad in pads do
		local mag = GamepadSelect.getPadMagnitude(pad.axes)
		if mag > dz and mag >= bestMag then
			bestMag = mag
			bestSlot = pad.slot
		end
	end

	return bestSlot
end

return GamepadSelect
