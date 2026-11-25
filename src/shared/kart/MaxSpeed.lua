--!strict
-- src/shared/kart/MaxSpeed.lua
-- SPDX-License-Identifier: GPL-3.0-or-later
-- ported from src/karts/max_speed.hpp:L37-L125, src/karts/max_speed.cpp:L66-L220, L256-L332, L400-L455 (STK 1.5)

local KartTuning = require("../KartTuning")

-- Full STK SpeedIncrease / SpeedDecrease category enums (max_speed.hpp:L37-L53)
export type SpeedIncreaseCategory = "ZIPPER" | "SLIPSTREAM" | "NITRO" | "RUBBER" | "SKIDDING" | "RED_SKIDDING"
export type SpeedDecreaseCategory = "TERRAIN" | "AI" | "BUBBLE" | "SQUASH"

export type SpeedIncreaseEntry = {
	active: boolean,
	maxAddSpeed: number,
	currentSpeedup: number,
	engineForce: number,
	durationTicks: number,
	fadeOutTicks: number,
}

export type SpeedDecreaseEntry = {
	active: boolean,
	targetFraction: number,
	currentFraction: number,
	fadeInTicks: number,
	durationTicks: number,
}

export type MaxSpeedState = {
	baseMaxSpeed: number,
	currentMaxSpeed: number,
	effectiveCapSpeed: number,
	additionalEngineForce: number,
	minSpeed: number,
	increases: { [string]: SpeedIncreaseEntry },
	decreases: { [string]: SpeedDecreaseEntry },
}

local INCREASE_CATEGORIES: { SpeedIncreaseCategory } = {
	"ZIPPER",
	"SLIPSTREAM",
	"NITRO",
	"RUBBER",
	"SKIDDING",
	"RED_SKIDDING",
}

local DECREASE_CATEGORIES: { SpeedDecreaseCategory } = {
	"TERRAIN",
	"AI",
	"BUBBLE",
	"SQUASH",
}

local MaxSpeed = {}
MaxSpeed.INCREASE_CATEGORIES = table.freeze(INCREASE_CATEGORIES)
MaxSpeed.DECREASE_CATEGORIES = table.freeze(DECREASE_CATEGORIES)

local function newIncreaseEntry(): SpeedIncreaseEntry
	return {
		active = false,
		maxAddSpeed = 0,
		currentSpeedup = 0,
		engineForce = 0,
		durationTicks = 0,
		fadeOutTicks = 0,
	}
end

function MaxSpeed.new(baseMaxSpeed: number): MaxSpeedState
	local increases: { [string]: SpeedIncreaseEntry } = {}
	for _, cat in INCREASE_CATEGORIES do
		increases[cat] = newIncreaseEntry()
	end

	return {
		baseMaxSpeed = baseMaxSpeed,
		currentMaxSpeed = baseMaxSpeed,
		effectiveCapSpeed = baseMaxSpeed,
		additionalEngineForce = 0,
		minSpeed = -1,
		increases = increases,
		decreases = {},
	}
end

function MaxSpeed.reset(state: MaxSpeedState)
	state.currentMaxSpeed = state.baseMaxSpeed
	state.effectiveCapSpeed = state.baseMaxSpeed
	state.additionalEngineForce = 0
	state.minSpeed = -1
	for _, cat in INCREASE_CATEGORIES do
		local entry = state.increases[cat]
		entry.active = false
		entry.maxAddSpeed = 0
		entry.currentSpeedup = 0
		entry.engineForce = 0
		entry.durationTicks = 0
		entry.fadeOutTicks = 0
	end
	table.clear(state.decreases)
end

local function updateIncreaseEntry(entry: SpeedIncreaseEntry, ticks: number)
	if not entry.active then
		entry.currentSpeedup = 0
		return
	end
	if ticks > 0 then
		entry.durationTicks -= ticks
	end
	if entry.durationTicks < -entry.fadeOutTicks then
		entry.active = false
		entry.maxAddSpeed = 0
		entry.currentSpeedup = 0
		entry.engineForce = 0
		entry.durationTicks = 0
		entry.fadeOutTicks = 0
		return
	end
	entry.currentSpeedup = entry.maxAddSpeed
	if entry.durationTicks > 0 or entry.fadeOutTicks <= 0 then
		return
	end
	-- Linear fade-out over fadeOutTicks (src/karts/max_speed.cpp:L216-L218)
	local elapsedFade = math.abs(entry.durationTicks)
	local ratio = math.clamp(elapsedFade / entry.fadeOutTicks, 0, 1)
	entry.currentSpeedup = entry.maxAddSpeed * (1 - ratio)
end

function MaxSpeed.increaseMaxSpeed(
	state: MaxSpeedState,
	category: SpeedIncreaseCategory,
	addSpeed: number,
	engineForce: number,
	durationTicks: number,
	fadeOutTicks: number
)
	if addSpeed < 0 or engineForce < 0 then
		return
	end
	local entry = state.increases[category]
	entry.active = true
	entry.maxAddSpeed = addSpeed
	entry.currentSpeedup = addSpeed
	entry.engineForce = engineForce
	entry.durationTicks = durationTicks
	entry.fadeOutTicks = math.max(fadeOutTicks, 0)
end

function MaxSpeed.setSlowdown(
	state: MaxSpeedState,
	category: SpeedDecreaseCategory,
	maxSpeedFraction: number,
	fadeInTicks: number,
	durationTicks: number?
)
	if maxSpeedFraction < 0 then
		return
	end
	local duration = if durationTicks ~= nil then durationTicks else -1
	local fade = math.max(0, math.floor(fadeInTicks))
	local existing = state.decreases[category]
	if existing then
		existing.active = true
		existing.targetFraction = maxSpeedFraction
		existing.fadeInTicks = fade
		existing.durationTicks = duration
	else
		state.decreases[category] = {
			active = true,
			targetFraction = maxSpeedFraction,
			currentFraction = 1.0,
			fadeInTicks = fade,
			durationTicks = duration,
		}
	end
end

function MaxSpeed.update(state: MaxSpeedState, ticks: number, isOnGround: boolean)
	-- Slowdowns: take minimum fraction (src/karts/max_speed.cpp:L306-L332, L406-L413)
	local slowdownFactor = 1.0
	for _, slowdown in state.decreases do
		if slowdown.active then
			if slowdown.durationTicks > -1 and ticks > 0 then
				slowdown.durationTicks -= ticks
				if slowdown.durationTicks < 0 then
					slowdown.durationTicks = 0
					slowdown.currentFraction = 1.0
					slowdown.targetFraction = 1.0
					slowdown.active = false
				end
			end

			if slowdown.active and ticks > 0 then
				local diff = slowdown.currentFraction - slowdown.targetFraction
				if diff > 0 then
					if slowdown.fadeInTicks > 0 and diff * slowdown.fadeInTicks > ticks then
						slowdown.currentFraction -= ticks / slowdown.fadeInTicks
					else
						slowdown.currentFraction = slowdown.targetFraction
					end
				else
					-- Returning to a faster/normal surface clears terrain cap immediately (max_speed.cpp:L330-L331)
					slowdown.currentFraction = slowdown.targetFraction
				end
			end

			if slowdown.active and slowdown.currentFraction < slowdownFactor then
				slowdownFactor = slowdown.currentFraction
			end
		end
	end

	-- Speed increases: sum all categories (src/karts/max_speed.cpp:L415-L426, max_speed.hpp:L117-L120)
	local addForce = 0.0
	local maxSpeed = state.baseMaxSpeed
	for _, cat in INCREASE_CATEGORIES do
		local entry = state.increases[cat]
		updateIncreaseEntry(entry, ticks)
		if entry.active then
			maxSpeed += entry.currentSpeedup
			-- SpeedIncrease::getEngineForce returns 0 once durationTicks <= 0 (during fade-out)
			if entry.durationTicks > 0 then
				addForce += entry.engineForce
			end
		end
	end

	-- RED_SKIDDING suppresses SKIDDING when both are active (src/karts/max_speed.cpp:L427-L433)
	local skidEntry = state.increases["SKIDDING"]
	local redSkidEntry = state.increases["RED_SKIDDING"]
	if skidEntry.active and skidEntry.durationTicks > 0 and redSkidEntry.active and redSkidEntry.durationTicks > 0 then
		maxSpeed -= skidEntry.currentSpeedup
		addForce -= skidEntry.engineForce
	end

	state.currentMaxSpeed = maxSpeed * slowdownFactor
	state.additionalEngineForce = addForce

	if isOnGround then
		state.effectiveCapSpeed = state.currentMaxSpeed
	else
		state.effectiveCapSpeed = KartTuning.physics.MAX_SPEED_AIRBORNE
	end
end

function MaxSpeed.getSpeedIncreaseTicksLeft(state: MaxSpeedState, category: SpeedIncreaseCategory): number
	local entry = state.increases[category]
	if entry == nil or not entry.active then
		return -1
	end
	return entry.durationTicks
end

function MaxSpeed.isSpeedIncreaseActive(state: MaxSpeedState, category: SpeedIncreaseCategory): boolean
	local entry = state.increases[category]
	return entry ~= nil and entry.active and entry.durationTicks > -entry.fadeOutTicks
end

function MaxSpeed.instantSpeedIncrease(
	state: MaxSpeedState,
	category: SpeedIncreaseCategory,
	addMaxSpeed: number,
	speedBoost: number,
	engineForce: number,
	durationTicks: number,
	fadeOutTicks: number,
	currentSpeed: number,
	isOnGround: boolean
): number
	MaxSpeed.increaseMaxSpeed(state, category, addMaxSpeed, engineForce, durationTicks, fadeOutTicks)
	MaxSpeed.update(state, 0, isOnGround)
	local targetSpeed = math.min(currentSpeed + speedBoost, state.currentMaxSpeed)
	if state.minSpeed > targetSpeed then
		targetSpeed = state.minSpeed
	end
	return targetSpeed
end

return table.freeze(MaxSpeed)
