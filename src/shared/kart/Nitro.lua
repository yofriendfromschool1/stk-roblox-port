--!strict
-- src/shared/kart/Nitro.lua
-- SPDX-License-Identifier: GPL-3.0-or-later
-- ported from src/karts/kart.cpp:L135-L136, L1141-L1185, L2244-L2302, L2786-L2789 (STK 1.5)
-- Pure-Luau STK nitro reserve, 64-tick minimum burn commitment, and MaxSpeed NITRO integration.

local FixedStep = require("../sim/FixedStep")
local KartTuning = require("../KartTuning")
local MaxSpeed = require("./MaxSpeed")

export type NitroState = {
	energy: number,
	maxEnergy: number,
	minNitroTicks: number,
	energyToMinRatio: number,
	active: boolean,
}

local Nitro = {}

function Nitro.new(maxEnergy: number?): NitroState
	return {
		energy = 0.0,
		maxEnergy = maxEnergy or KartTuning.nitro.max,
		minNitroTicks = 0,
		energyToMinRatio = 1.0,
		active = false,
	}
end

function Nitro.reset(state: NitroState)
	state.energy = 0.0
	state.minNitroTicks = 0
	state.energyToMinRatio = 1.0
	state.active = false
end

-- Add nitro reserve from a small/big bottle or debug grant (kart.cpp:L1141-L1185)
function Nitro.collect(state: NitroState, amount: number): number
	if amount <= 0 then
		return state.energy
	end
	state.energy = math.min(state.maxEnergy, state.energy + amount)
	return state.energy
end

-- Per-tick nitro consumption and MaxSpeed::MS_INCREASE_NITRO activation (kart.cpp:L2244-L2302)
-- Activation & continuation depend only on nitroPressed and energy > 0; speed increase is gated on isOnGround.
function Nitro.update(
	state: NitroState,
	nitroCfg: KartTuning.NitroProfile,
	maxSpeedState: MaxSpeed.MaxSpeedState,
	ticks: number,
	nitroPressed: boolean,
	isOnGround: boolean,
	_accelHeld: boolean?
): boolean
	if state.energy <= 0 then
		state.energy = 0.0
		state.minNitroTicks = 0
		state.active = false
		return false
	end

	local canActivate = nitroPressed
	if canActivate and state.minNitroTicks <= 0 and state.energy > 0 then
		state.minNitroTicks = nitroCfg.minConsumptionTicks
		local minConsumption = state.minNitroTicks * nitroCfg.consumptionPerTick
		state.energyToMinRatio = if minConsumption > 0 then math.min(1.0, state.energy / minConsumption) else 1.0
	end

	if state.minNitroTicks > 0 then
		state.minNitroTicks -= ticks
		-- Keep active while key + throttle remain held on ground after initial min burn completes
		if canActivate and state.minNitroTicks <= 0 then
			state.minNitroTicks = 1
		end
	end

	local increaseSpeed = (state.minNitroTicks > 0 and isOnGround)
	if not increaseSpeed and state.minNitroTicks <= 0 then
		state.active = false
		return false
	end

	state.energy -= nitroCfg.consumptionPerTick * ticks
	if state.energy < 0 then
		state.energy = 0.0
		state.minNitroTicks = 0
		state.active = false
		return false
	end

	if increaseSpeed then
		state.active = true
		MaxSpeed.increaseMaxSpeed(
			maxSpeedState,
			"NITRO",
			nitroCfg.maxSpeedIncrease,
			nitroCfg.engineForce,
			FixedStep.timeToTicks(nitroCfg.duration * state.energyToMinRatio),
			FixedStep.timeToTicks(nitroCfg.fadeOutTime)
		)
		return true
	end

	state.active = false
	return false
end

return table.freeze(Nitro)
