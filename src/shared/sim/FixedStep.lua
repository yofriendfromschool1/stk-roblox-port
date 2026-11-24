--!strict
-- src/shared/sim/FixedStep.lua
-- SPDX-License-Identifier: GPL-3.0-or-later
-- ported from src/main_loop.cpp:L460-L463, src/config/stk_config.hpp:L314-L320 (STK 1.5)

local PHYSICS_FPS = 120
local FIXED_DT = 1 / PHYSICS_FPS
local MAX_FRAME_DT = 0.25
local MAX_SUBSTEPS = 8
local ACCUM_EPS = 1e-9

export type AccumulatorOptions = {
	maxSubsteps: number?,
	maxFrameDt: number?,
	onDebtDropped: ((droppedSeconds: number) -> ())?,
}

export type Accumulator = {
	advance: (self: Accumulator, dt: number, stepFn: (fixedDt: number, tick: number) -> ()) -> (number, number),
	getAlpha: (self: Accumulator) -> number,
	getTick: (self: Accumulator) -> number,
	getAccumulator: (self: Accumulator) -> number,
	reset: (self: Accumulator) -> (),
}

local FixedStep = {}

FixedStep.PHYSICS_FPS = PHYSICS_FPS
FixedStep.FIXED_DT = FIXED_DT
FixedStep.MAX_FRAME_DT = MAX_FRAME_DT
FixedStep.MAX_SUBSTEPS = MAX_SUBSTEPS

function FixedStep.ticksToTime(ticks: number): number
	return ticks / PHYSICS_FPS
end

function FixedStep.timeToTicks(seconds: number): number
	return math.floor(seconds * PHYSICS_FPS)
end

function FixedStep.new(options: AccumulatorOptions?): Accumulator
	local opts = options or {} :: AccumulatorOptions
	local maxSubsteps = opts.maxSubsteps or MAX_SUBSTEPS
	local maxFrameDt = opts.maxFrameDt or MAX_FRAME_DT
	local onDebtDropped = opts.onDebtDropped

	local accumulator = 0
	local tick = 0

	local instance: Accumulator = {
		advance = function(
			_self: Accumulator,
			dt: number,
			stepFn: (fixedDt: number, tick: number) -> ()
		): (number, number)
			if dt <= 0 then
				return 0, 0
			end

			accumulator += math.min(dt, maxFrameDt)

			local steps = 0
			while accumulator + ACCUM_EPS >= FIXED_DT and steps < maxSubsteps do
				tick += 1
				stepFn(FIXED_DT, tick)
				accumulator -= FIXED_DT
				if accumulator < 0 then
					accumulator = 0
				end
				steps += 1
			end

			local droppedDebt = 0
			if steps == maxSubsteps and accumulator + ACCUM_EPS >= FIXED_DT then
				droppedDebt = accumulator
				accumulator = 0
				if onDebtDropped then
					onDebtDropped(droppedDebt)
				end
			end

			return steps, droppedDebt
		end,

		getAlpha = function(_self: Accumulator): number
			return math.clamp(accumulator / FIXED_DT, 0, 1)
		end,

		getTick = function(_self: Accumulator): number
			return tick
		end,

		getAccumulator = function(_self: Accumulator): number
			return accumulator
		end,

		reset = function(_self: Accumulator)
			accumulator = 0
			tick = 0
		end,
	}

	return instance
end

return table.freeze(FixedStep)
