--!strict
-- tests/Difficulty.spec.luau
-- SPDX-License-Identifier: GPL-3.0-or-later

local ItemTuning = require("../src/shared/ItemTuning")
local KartSolver = require("../src/shared/sim/KartSolver")
local KartTuning = require("../src/shared/KartTuning")
local PowerupManager = require("../src/shared/items/PowerupManager")

local function assertTrue(cond: boolean, msg: string)
	if not cond then
		error(msg, 2)
	end
end

return {
	{
		name = "difficulty tiers scale prof.maxSpeed and currentMaxSpeed strictly monotonically",
		fn = function()
			local order = { "novice", "intermediate", "expert", "best" }
			local expected = {
				novice = 15.0,
				intermediate = 20.0,
				expert = 23.0,
				best = 25.0,
			}
			local prev = 0.0
			for _, diff in ipairs(order) do
				local prof = KartTuning.buildProfile("medium", diff)
				local ks = KartSolver.createState(prof, { x = 0, y = 0.5, z = 0 }, 0)
				local curMax = ks.maxSpeedState.currentMaxSpeed
				assertTrue(
					math.abs(prof.maxSpeed - expected[diff]) < 1e-4,
					string.format("%s prof.maxSpeed=%.2f expected=%.2f", diff, prof.maxSpeed, expected[diff])
				)
				assertTrue(math.abs(curMax - expected[diff]) < 1e-4, diff .. " currentMaxSpeed mismatch")
				assertTrue(prof.maxSpeed > prev, diff .. " must exceed previous tier")
				prev = prof.maxSpeed
			end
		end,
	},
	{
		name = "10000-roll item distribution differs measurably across difficulties",
		fn = function()
			local function rollCounts(diff: string): { [number]: number }
				local pm = PowerupManager.new("NORMAL_RACE", 4, ItemTuning.IMPLEMENTED_POWERUPS, diff)
				local counts: { [number]: number } = {}
				for i = 1, 10000 do
					local pid, _ = pm:getRandomPowerup(2, i * 1103515245 + 12345, 30.0)
					counts[pid] = (counts[pid] or 0) + 1
				end
				return counts
			end
			local cNovice = rollCounts("novice")
			local cBest = rollCounts("best")
			assertTrue(
				(cNovice[ItemTuning.POWERUP_BUBBLEGUM] or 0) > (cBest[ItemTuning.POWERUP_BUBBLEGUM] or 0),
				"novice rolls more bubblegum shields than best"
			)
			assertTrue(
				(cBest[ItemTuning.POWERUP_CAKE] or 0) > (cNovice[ItemTuning.POWERUP_CAKE] or 0),
				"best rolls more cakes than novice"
			)
		end,
	},
}
