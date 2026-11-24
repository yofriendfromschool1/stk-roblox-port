--!strict
-- tests/FixedStep.spec.luau
-- SPDX-License-Identifier: GPL-3.0-or-later

local FixedStep = require("../src/shared/sim/FixedStep")

export type TestCase = {
	name: string,
	fn: () -> (),
}

local function assertNear(actual: number, expected: number, eps: number?, label: string?)
	local tolerance = eps or 1e-9
	if math.abs(actual - expected) > tolerance then
		local prefix = if label then label .. ": " else ""
		error(string.format("%sexpected %s (+/-%g), got %s", prefix, tostring(expected), tolerance, tostring(actual)))
	end
end

local function simulateSequence(
	dtSequence: { number }
): { x: number, v: number, tick: number, acc: number, alpha: number }
	local stepper = FixedStep.new()
	local x = 0
	local v = 0
	local accel = 18.5
	local drag = 0.025

	for _, dt in dtSequence do
		stepper:advance(dt, function(fixedDt: number)
			v += (accel - drag * v * v) * fixedDt
			x += v * fixedDt
		end)
	end

	return {
		x = x,
		v = v,
		tick = stepper:getTick(),
		acc = stepper:getAccumulator(),
		alpha = stepper:getAlpha(),
	}
end

local tests: { TestCase } = {
	{
		name = "FixedStep constants and tick helpers match STK 120 Hz baseline",
		fn = function()
			assert(FixedStep.PHYSICS_FPS == 120, "PHYSICS_FPS should equal 120")
			assertNear(FixedStep.FIXED_DT, 1 / 120, 1e-12, "FIXED_DT")
			assert(FixedStep.MAX_FRAME_DT == 0.25, "MAX_FRAME_DT should equal 0.25")
			assert(FixedStep.MAX_SUBSTEPS == 8, "MAX_SUBSTEPS should equal 8")
			assert(table.isfrozen(FixedStep) == true, "FixedStep table should be frozen")

			assertNear(FixedStep.ticksToTime(120), 1.0, 1e-12, "120 ticks -> 1 s")
			assert(FixedStep.timeToTicks(1.0) == 120, "1.0 s -> 120 ticks")
			assert(FixedStep.timeToTicks(0.7) == 84, "0.7 s -> 84 ticks")
		end,
	},
	{
		name = "irregular dt sequences produce identical state for identical elapsed time",
		fn = function()
			-- All four sequences sum to exactly 0.100 s (12 ticks at 120 Hz)
			local seqA = { 0.016, 0.033, 0.008, 0.043 }
			local seqB = { 0.008, 0.016, 0.033, 0.017, 0.026 }
			local seqC = { 1 / 60, 1 / 60, 1 / 60, 1 / 60, 1 / 60, 1 / 60 }
			local seqD = {}
			for _ = 1, 12 do
				table.insert(seqD, 1 / 120)
			end

			local resA = simulateSequence(seqA)
			local resB = simulateSequence(seqB)
			local resC = simulateSequence(seqC)
			local resD = simulateSequence(seqD)

			assert(resA.tick == 12, "seqA should execute 12 ticks")
			assert(resB.tick == 12, "seqB should execute 12 ticks")
			assert(resC.tick == 12, "seqC should execute 12 ticks")
			assert(resD.tick == 12, "seqD should execute 12 ticks")

			assert(resA.x == resB.x and resA.x == resC.x and resA.x == resD.x, "final position must be bit-identical")
			assert(resA.v == resB.v and resA.v == resC.v and resA.v == resD.v, "final velocity must be bit-identical")
			assertNear(resA.acc, 0, 1e-9, "remainder after exact 100 ms")

			-- Non-integer tick total: 0.070 s = 8 ticks (66.6667 ms) + 3.3333 ms remainder
			local partialA = simulateSequence({ 0.016, 0.033, 0.008, 0.013 })
			local partialB = simulateSequence({ 0.010, 0.010, 0.010, 0.010, 0.010, 0.010, 0.010 })

			assert(partialA.tick == 8 and partialB.tick == 8, "70 ms should execute 8 ticks")
			assert(partialA.x == partialB.x, "partial elapsed position must match")
			assert(partialA.v == partialB.v, "partial elapsed velocity must match")
			assertNear(partialA.acc, 0.070 - 8 / 120, 1e-9, "remainder carried")
			assertNear(partialA.alpha, partialB.alpha, 1e-9, "interpolation alpha matches")
		end,
	},
	{
		name = "stall frame (200 ms) caps substeps at MAX_SUBSTEPS and sheds debt",
		fn = function()
			local debtCalls = 0
			local lastDebt = 0
			local stepper = FixedStep.new({
				onDebtDropped = function(dropped: number)
					debtCalls += 1
					lastDebt = dropped
				end,
			})

			local stepsLog: { number } = {}
			for _, dt in { 0.016, 0.033, 0.008, 0.200 } do
				local steps = stepper:advance(dt, function() end)
				table.insert(stepsLog, steps)
			end

			-- Prior remainder before 0.200 s: 0.057 s - 6/120 = 0.007 s
			-- 0.007 + 0.200 = 0.207 s -> 8 substeps (0.06667 s) executed, ~0.14033 s debt shed
			assert(stepsLog[4] == FixedStep.MAX_SUBSTEPS, "stall frame must cap at MAX_SUBSTEPS (8)")
			assert(debtCalls == 1, "onDebtDropped should be called once on stall frame")
			assertNear(lastDebt, (0.057 - 6 / 120 + 0.200) - 8 / 120, 1e-9, "dropped debt")
			assert(stepper:getAccumulator() == 0, "accumulator must reset to 0 after debt shed")

			-- Normal frame after stall resumes cleanly
			local nextSteps, nextDebt = stepper:advance(1 / 120, function() end)
			assert(nextSteps == 1 and nextDebt == 0, "post-stall normal frame should advance 1 step")
		end,
	},
	{
		name = "non-positive dt is a no-op and reset clears state",
		fn = function()
			local stepper = FixedStep.new()
			local s0, d0 = stepper:advance(0, function() end)
			local sNeg, dNeg = stepper:advance(-0.05, function() end)
			assert(s0 == 0 and d0 == 0 and sNeg == 0 and dNeg == 0, "non-positive dt should not advance")

			stepper:advance(0.02, function() end)
			assert(stepper:getTick() == 2, "expected 2 ticks")
			assert(stepper:getAccumulator() > 0, "expected leftover accumulator")

			stepper:reset()
			assert(stepper:getTick() == 0, "reset must clear tick")
			assert(stepper:getAccumulator() == 0, "reset must clear accumulator")
		end,
	},
}

return tests
