--!strict
-- src/shared/ItemTuning.lua
-- SPDX-License-Identifier: GPL-3.0-or-later
-- Upstream item & powerup tuning constants and full data/powerup.xml weight tables.
-- Cited from C++ / XML in supertuxkart/stk-code (STK 1.5, commit 1fb491f5).

local ItemTuning = {}

export type PowerupId = number

export type PowerupEntry = {
	single: { number },
	multi: { number },
}

export type WeightTableForKarts = {
	numKarts: number,
	sections: { PowerupEntry },
}

-- PowerupType enum order matching src/items/powerup_manager.hpp & data/powerup.xml (1..10).
ItemTuning.POWERUP_NONE = 0
ItemTuning.POWERUP_BUBBLEGUM = 1
ItemTuning.POWERUP_CAKE = 2
ItemTuning.POWERUP_BOWLING = 3
ItemTuning.POWERUP_ZIPPER = 4
ItemTuning.POWERUP_PLUNGER = 5
ItemTuning.POWERUP_SWITCH = 6
ItemTuning.POWERUP_SWATTER = 7
ItemTuning.POWERUP_RUBBERBALL = 8
ItemTuning.POWERUP_PARACHUTE = 9
ItemTuning.POWERUP_ANVIL = 10
ItemTuning.POWERUP_FIRST = 1
ItemTuning.POWERUP_LAST = 10

ItemTuning.POWERUP_NAMES = table.freeze({
	[0] = "NONE",
	[1] = "BUBBLEGUM",
	[2] = "CAKE",
	[3] = "BOWLING",
	[4] = "ZIPPER",
	[5] = "PLUNGER",
	[6] = "SWITCH",
	[7] = "SWATTER",
	[8] = "RUBBERBALL",
	[9] = "PARACHUTE",
	[10] = "ANVIL",
})

-- Slice 1 roll gate: restrict live server bonus-box rolls to implemented behaviors only.
-- Full data/powerup.xml tables remain intact in WEIGHT_LISTS; logged in docs/divergences.md.
ItemTuning.IMPLEMENTED_POWERUPS = table.freeze({
	[ItemTuning.POWERUP_BUBBLEGUM] = true,
}) :: { [number]: boolean }

-- Item / powerup timing and geometry constants (120 Hz fixed-step).
ItemTuning.timing = table.freeze({
	-- data/stk_config.xml:L226 <item-return-time bonusbox="2.0" nitro="2.0" banana="2.0" bubblegum="2.0"/>
	BONUSBOX_RETURN_SEC = 2.0,
	NITRO_RETURN_SEC = 2.0,
	BANANA_RETURN_SEC = 2.0,
	BUBBLEGUM_RETURN_SEC = 2.0,
	-- src/items/item.cpp:L161, L167, L172, L177
	BATTLE_RETURN_MULTIPLIER = 3,
	-- src/items/item.cpp:L61-L62 (m_deactive_ticks = time2Ticks(1.5f) = 180 ticks when dropped by kart)
	OWNER_DEACTIVE_SEC = 1.5,
	-- src/items/item.cpp:L149-L150
	BUBBLEGUM_DEACTIVE_SEC = 0.5,
	-- data/stk_config.xml:L248 <bubblegum disappear-counter="1" shield-time="10.0" restrict-weapons="false"/>
	BUBBLEGUM_DISAPPEAR_COUNTER = 1,
	-- data/stk_config.xml:L237 <powerup collect-mode="new" no-explosive-items-timeout="15.0"/>
	NO_EXPLOSIVE_TIMEOUT_SEC = 15.0,
	-- src/items/powerup.hpp:L22
	MAX_POWERUPS = 5,
})

ItemTuning.geometry = table.freeze({
	-- src/items/item.cpp:L228 m_distance_2 = 1.2f (sq. distance threshold in meters, with lc.y /= 2.0f)
	DISTANCE_SQUARED = 1.2,
	-- src/items/item_manager.cpp:L306 hit_point + up * (-0.05f)
	DROP_OFFSET_NORMAL = -0.05,
	-- src/items/item_manager.cpp:L300 raycast start offset above drop position
	DROP_RAY_HEIGHT = 1.5,
	DROP_RAY_MAX_DIST = 6.0,
	-- Extra clearance behind kart rear bumper (0.5 * length + clearance) for Slice 1 banana drop
	BANANA_DROP_CLEARANCE = 0.20,
})

-- Slice 1 banana contact effect using existing MaxSpeed SQUASH tuning (data/powerup.xml:L88,
-- data/kart_characteristics.xml:L260-L261) + short upward/yaw knockback impulse.
ItemTuning.banana = table.freeze({
	SQUASH_SLOWDOWN = 0.5,
	SQUASH_DURATION_SEC = 2.0,
	SQUASH_FADE_IN_SEC = 0.1,
	KNOCKBACK_UP_VEL = 3.5,
	KNOCKBACK_YAW_RATE = 4.0,
	KNOCKBACK_YAW_TICKS = 30,
})

-- StandardRace::haveBonusBoxes (src/modes/standard_race.cpp:L64-L68) and
-- PowerupManager::computeWeightsForRace mode mapping (src/items/powerup_manager.cpp:L528-L547).
ItemTuning.modes = table.freeze({
	NORMAL_RACE = { weightClass = "race", haveBonusBoxes = true, isBattle = false, isFollowLeader = false },
	TIME_TRIAL = { weightClass = "race", haveBonusBoxes = false, isBattle = false, isFollowLeader = false },
	LAP_TRIAL = { weightClass = "race", haveBonusBoxes = true, isBattle = false, isFollowLeader = false },
	FOLLOW_LEADER = { weightClass = "ftl", haveBonusBoxes = true, isBattle = false, isFollowLeader = true },
	BATTLE = { weightClass = "battle", haveBonusBoxes = true, isBattle = true, isFollowLeader = false },
	SOCCER = { weightClass = "soccer", haveBonusBoxes = true, isBattle = false, isFollowLeader = false },
	TUTORIAL = { weightClass = "tutorial", haveBonusBoxes = true, isBattle = false, isFollowLeader = false },
})

local function freezeEntry(single: { number }, multi: { number }): PowerupEntry
	table.freeze(single)
	table.freeze(multi)
	return table.freeze({
		single = single,
		multi = multi,
	})
end

local function freezeTable(numKarts: number, sections: { PowerupEntry }): WeightTableForKarts
	table.freeze(sections)
	return table.freeze({
		numKarts = numKarts,
		sections = sections,
	})
end

-- Complete weight tables from data/powerup.xml:L153-L265 (STK 1.5).
-- Order of the 10 weights in both single and multi:
--   { bubblegum, cake, bowling, zipper, plunger, switch, swatter, rubberball, parachute, anvil }
ItemTuning.WEIGHT_LISTS = table.freeze({
	-- data/powerup.xml:L153-L222 <race-weight-list>
	race = table.freeze({
		freezeTable(1, {
			freezeEntry({ 140, 0, 300, 100, 225, 75, 160, 0, 0, 0 }, { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }),
			freezeEntry({ 150, 0, 295, 130, 200, 70, 135, 0, 0, 0 }, { 0, 0, 20, 0, 0, 0, 0, 0, 0, 0 }),
			freezeEntry({ 150, 0, 310, 135, 180, 65, 135, 0, 0, 0 }, { 0, 0, 25, 0, 0, 0, 0, 0, 0, 0 }),
			freezeEntry({ 155, 0, 280, 180, 170, 60, 125, 0, 0, 0 }, { 0, 0, 30, 0, 0, 0, 0, 0, 0, 0 }),
			freezeEntry({ 170, 0, 180, 275, 150, 50, 85, 0, 0, 0 }, { 0, 0, 90, 0, 0, 0, 0, 0, 0, 0 }),
		}),
		freezeTable(5, {
			freezeEntry({ 130, 80, 260, 75, 230, 60, 165, 0, 0, 0 }, { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }),
			freezeEntry({ 150, 135, 240, 125, 145, 45, 135, 0, 0, 0 }, { 0, 0, 25, 0, 0, 0, 0, 0, 0, 0 }),
			freezeEntry({ 150, 135, 225, 144, 135, 36, 135, 15, 0, 0 }, { 0, 0, 25, 0, 0, 0, 0, 0, 0, 0 }),
			freezeEntry({ 160, 120, 140, 205, 110, 30, 100, 70, 30, 0 }, { 0, 0, 35, 0, 0, 0, 0, 0, 0, 0 }),
			freezeEntry({ 145, 105, 45, 240, 0, 24, 0, 40, 80, 0 }, { 40, 0, 80, 175, 26, 0, 0, 0, 0, 0 }),
		}),
		freezeTable(9, {
			freezeEntry({ 120, 60, 290, 50, 270, 40, 170, 0, 0, 0 }, { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }),
			freezeEntry({ 145, 150, 230, 120, 160, 30, 135, 0, 0, 0 }, { 0, 0, 30, 0, 0, 0, 0, 0, 0, 0 }),
			freezeEntry({ 150, 130, 205, 152, 130, 24, 130, 44, 0, 0 }, { 0, 0, 35, 0, 0, 0, 0, 0, 0, 0 }),
			freezeEntry({ 165, 115, 130, 245, 70, 18, 84, 50, 30, 0 }, { 0, 0, 60, 0, 33, 0, 0, 0, 0, 0 }),
			freezeEntry({ 100, 80, 35, 200, 0, 12, 0, 16, 67, 0 }, { 90, 0, 90, 290, 20, 0, 0, 0, 0, 0 }),
		}),
		freezeTable(14, {
			freezeEntry({ 110, 40, 320, 25, 300, 30, 175, 0, 0, 0 }, { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }),
			freezeEntry({ 140, 155, 240, 110, 170, 20, 135, 0, 0, 0 }, { 0, 0, 30, 0, 0, 0, 0, 0, 0, 0 }),
			freezeEntry({ 150, 125, 210, 159, 145, 15, 120, 36, 0, 0 }, { 0, 0, 40, 0, 0, 0, 0, 0, 0, 0 }),
			freezeEntry({ 135, 105, 115, 234, 60, 12, 70, 35, 24, 0 }, { 40, 0, 80, 40, 50, 0, 0, 0, 0, 0 }),
			freezeEntry({ 90, 70, 15, 175, 0, 0, 0, 0, 50, 0 }, { 120, 0, 125, 325, 30, 0, 0, 0, 0, 0 }),
		}),
		freezeTable(20, {
			freezeEntry({ 100, 0, 370, 0, 330, 20, 180, 0, 0, 0 }, { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }),
			freezeEntry({ 135, 160, 240, 100, 185, 15, 135, 0, 0, 0 }, { 0, 0, 30, 0, 0, 0, 0, 0, 0, 0 }),
			freezeEntry({ 150, 120, 200, 165, 148, 10, 105, 27, 0, 0 }, { 0, 0, 50, 0, 25, 0, 0, 0, 0, 0 }),
			freezeEntry({ 125, 90, 100, 262, 50, 8, 50, 20, 15, 0 }, { 50, 0, 100, 50, 80, 0, 0, 0, 0, 0 }),
			freezeEntry({ 75, 60, 0, 125, 0, 0, 0, 0, 35, 0 }, { 150, 0, 155, 400, 0, 0, 0, 0, 0, 0 }),
		}),
	}),
	-- data/powerup.xml:L224-L241 <ftl-weight-list>
	ftl = table.freeze({
		freezeTable(1, {
			freezeEntry({ 35, 0, 25, 35, 25, 15, 25, 0, 0, 0 }, { 20, 0, 0, 20, 0, 0, 0, 0, 0, 0 }),
			freezeEntry({ 25, 0, 60, 25, 58, 2, 30, 0, 0, 0 }, { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }),
			freezeEntry({ 35, 0, 55, 35, 25, 3, 25, 0, 0, 0 }, { 0, 0, 10, 0, 12, 0, 0, 0, 0, 0 }),
			freezeEntry({ 25, 0, 40, 45, 15, 5, 15, 10, 5, 0 }, { 10, 0, 15, 15, 0, 0, 0, 0, 0, 0 }),
			freezeEntry({ 20, 0, 15, 25, 0, 0, 0, 0, 15, 0 }, { 20, 0, 25, 80, 0, 0, 0, 0, 0, 0 }),
		}),
	}),
	-- data/powerup.xml:L243-L249 <battle-weight-list>
	battle = table.freeze({
		freezeTable(1, {
			freezeEntry({ 10, 30, 60, 0, 0, 10, 30, 0, 0, 0 }, { 0, 0, 5, 0, 0, 0, 0, 0, 0, 0 }),
		}),
	}),
	-- data/powerup.xml:L251-L257 <soccer-weight-list>
	soccer = table.freeze({
		freezeTable(1, {
			freezeEntry({ 0, 30, 60, 0, 0, 10, 30, 0, 0, 0 }, { 0, 0, 5, 0, 0, 0, 0, 0, 0, 0 }),
		}),
	}),
	-- data/powerup.xml:L259-L265 <tutorial-weight-list>
	tutorial = table.freeze({
		freezeTable(1, {
			freezeEntry({ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, { 0, 0, 100, 0, 0, 0, 0, 0, 0, 0 }),
		}),
	}),
})

return ItemTuning
