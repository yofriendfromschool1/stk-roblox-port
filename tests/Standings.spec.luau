--!strict
-- tests/Standings.spec.luau
-- SPDX-License-Identifier: GPL-3.0-or-later

local Standings = require("../src/shared/race/Standings")

export type TestCase = {
	name: string,
	fn: () -> (),
}

local tests: { TestCase } = {
	{
		name = "single kart returns rank 1 of 1",
		fn = function()
			local entries: { Standings.StandingsEntry } = {
				{ id = "tux", lap = 0, checkpoint = 0, distance = 12.5, initialPosition = 1 },
			}
			local rank, total = Standings.getRankForId(entries, "tux")
			assert(rank == 1 and total == 1, string.format("expected 1/1, got %d/%d", rank, total))
		end,
	},
	{
		name = "sorts active karts by lap desc -> checkpoint desc -> distance desc",
		fn = function()
			local entries: { Standings.StandingsEntry } = {
				{ id = "k_low_lap", lap = 1, checkpoint = 4, distance = 99.0, initialPosition = 1 },
				{ id = "k_high_dist", lap = 2, checkpoint = 1, distance = 45.0, initialPosition = 3 },
				{ id = "k_high_cp", lap = 2, checkpoint = 2, distance = 5.0, initialPosition = 4 },
				{ id = "k_low_dist", lap = 2, checkpoint = 1, distance = 12.0, initialPosition = 2 },
			}
			local ranked = Standings.compute(entries)
			assert(#ranked == 4, "expected 4 ranked entries")
			assert(ranked[1].id == "k_high_cp" and ranked[1].rank == 1, "lap 2 cp 2 is 1st")
			assert(ranked[2].id == "k_high_dist" and ranked[2].rank == 2, "lap 2 cp 1 higher dist is 2nd")
			assert(ranked[3].id == "k_low_dist" and ranked[3].rank == 3, "lap 2 cp 1 lower dist is 3rd")
			assert(ranked[4].id == "k_low_lap" and ranked[4].rank == 4, "lap 1 is 4th")
		end,
	},
	{
		name = "finished karts precede active karts ordered by finishTime then initialPosition",
		fn = function()
			local entries: { Standings.StandingsEntry } = {
				{ id = "active", lap = 3, checkpoint = 5, distance = 200.0, initialPosition = 1 },
				{
					id = "fin_second",
					lap = 3,
					checkpoint = 0,
					distance = 2.0,
					initialPosition = 1,
					finished = true,
					finishTime = 95.4,
				},
				{
					id = "fin_first",
					lap = 3,
					checkpoint = 0,
					distance = 1.0,
					initialPosition = 2,
					finished = true,
					finishTime = 94.1,
				},
				{ id = "tie_b", lap = 1, checkpoint = 1, distance = 10.0, initialPosition = 4 },
				{ id = "tie_a", lap = 1, checkpoint = 1, distance = 10.0, initialPosition = 3 },
			}
			local ranked = Standings.compute(entries)
			assert(ranked[1].id == "fin_first", "earliest finisher is 1st")
			assert(ranked[2].id == "fin_second", "second finisher is 2nd")
			assert(ranked[3].id == "active", "active leader is 3rd")
			assert(ranked[4].id == "tie_a", "tie broken by lower initialPosition first")
			assert(ranked[5].id == "tie_b", "tie broken by higher initialPosition second")
		end,
	},
}

return tests
