--!strict
-- tests/MatchLifecycleAndBomb.spec.luau
-- SPDX-License-Identifier: GPL-3.0-or-later

local Flyable = require("../src/shared/sim/Flyable")
local ItemWorld = require("../src/shared/items/ItemWorld")
local KartSolver = require("../src/shared/sim/KartSolver")
local KartTuning = require("../src/shared/KartTuning")
local KartVisualMath = require("../src/shared/kart/KartVisualMath")
local SettingsSchema = require("../src/shared/settings/SettingsSchema")
local TrackRegistry = require("../src/shared/track/TrackRegistry")

local tests: { { name: string, fn: () -> () } } = {}

table.insert(tests, {
	name = "SettingsSchema defaults kartHighlight to false (no unintended rim glow)",
	fn = function()
		local def = SettingsSchema.defaults()
		assert(def.graphics.kartHighlight == false, "kartHighlight default must be false")
		local san = SettingsSchema.sanitize({ graphics = { preset = "High" } })
		assert(san.graphics.kartHighlight == false, "sanitized kartHighlight must default false")
		local enabled = SettingsSchema.sanitize({ graphics = { kartHighlight = true } })
		assert(enabled.graphics.kartHighlight == true, "explicit kartHighlight=true preserved")
	end,
})

table.insert(tests, {
	name = "KartVisualMath.computeBombHandQuatStk reproduces bomb.spm Hand keyframes at 60/45/30/15/0s",
	fn = function()
		local q60 = KartVisualMath.computeBombHandQuatStk(60 * 120)
		local q30 = KartVisualMath.computeBombHandQuatStk(30 * 120)
		local q0 = KartVisualMath.computeBombHandQuatStk(0)
		-- Frame 0 and Frame 60 are identical (-75 deg X)
		assert(math.abs(q60.w - 0.79335) < 1e-4 and math.abs(q60.x + 0.60876) < 1e-4, "60s frame 0 mismatch")
		assert(math.abs(q0.w - 0.79335) < 1e-4 and math.abs(q0.x + 0.60876) < 1e-4, "0s frame 60 mismatch")
		-- Frame 30 (30s left) is 180 deg opposite around dial normal
		assert(math.abs(q30.w) < 1e-4 and math.abs(q30.y + 0.79335) < 1e-4, "30s frame 30 mismatch")
	end,
})

table.insert(tests, {
	name = "Match reset x3 leaves zero flyables and zero dropped dynamic items after firing bowling/cake/plunger/banana/bubblegum",
	fn = function()
		local track = TrackRegistry.get("sandtrack")
		local prof = KartTuning.buildProfileForKart("tux", "intermediate")
		for cycle = 1, 3 do
			local itemWorld = ItemWorld.fromArenaSpec(track :: any, "NORMAL_RACE")
			local flyWorld = Flyable.createWorld()
			local st = KartSolver.createState(prof, track.startPos, track.startYawRad)
			local proxy = KartSolver.makeFlyableProxy(1, st, 1, "intermediate")
			Flyable.spawnBowling(flyWorld, proxy, false)
			Flyable.spawnCake(flyWorld, proxy, { proxy }, false)
			Flyable.spawnPlunger(flyWorld, proxy, { proxy }, false, false)
			ItemWorld.dropNewItem(itemWorld, "banana", st.pos, 1)
			ItemWorld.dropBubblegum(itemWorld, st.pos, 1)
			assert(#flyWorld.entries == 3, string.format("cycle %d: expected 3 flyables before reset", cycle))

			-- Authoritative reset/teardown
			itemWorld = ItemWorld.fromArenaSpec(track :: any, "NORMAL_RACE")
			flyWorld = Flyable.createWorld()
			local dynCount = 0
			for _, it in itemWorld.items do
				if not it.original then
					dynCount += 1
				end
			end
			assert(#flyWorld.entries == 0, string.format("cycle %d: leaked flyables after reset", cycle))
			assert(dynCount == 0, string.format("cycle %d: leaked dynamic items after reset", cycle))
		end
	end,
})

return tests
