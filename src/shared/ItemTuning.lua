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

-- Live roll gate: restrict server bonus-box rolls to implemented behaviors only.
-- Full data/powerup.xml tables remain intact in WEIGHT_LISTS; logged in docs/divergences.md.
-- Note: ITEM_BANANA is a track hazard in data/items.xml (never in powerup.xml).
ItemTuning.IMPLEMENTED_POWERUPS = table.freeze({
	[ItemTuning.POWERUP_BUBBLEGUM] = true,
	[ItemTuning.POWERUP_CAKE] = true,
	[ItemTuning.POWERUP_BOWLING] = true,
	[ItemTuning.POWERUP_ZIPPER] = true,
	[ItemTuning.POWERUP_PLUNGER] = true,
	[ItemTuning.POWERUP_SWITCH] = true,
	[ItemTuning.POWERUP_SWATTER] = true,
	[ItemTuning.POWERUP_RUBBERBALL] = true,
	[ItemTuning.POWERUP_PARACHUTE] = true,
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

-- AttachmentType enum matching src/items/attachment.hpp (subset ported in Slice 1/2)
ItemTuning.ATTACHMENT_NONE = 0
ItemTuning.ATTACHMENT_PARACHUTE = 1
ItemTuning.ATTACHMENT_ANVIL = 2
ItemTuning.ATTACHMENT_BOMB = 3
ItemTuning.ATTACHMENT_BUBBLEGUM_SHIELD = 4
ItemTuning.ATTACHMENT_SWATTER = 5

ItemTuning.ATTACHMENT_NAMES = table.freeze({
	[0] = "NONE",
	[1] = "PARACHUTE",
	[2] = "ANVIL",
	[3] = "BOMB",
	[4] = "BUBBLEGUM_SHIELD",
	[5] = "SWATTER",
})

-- Floor bubblegum & shield constants (data/kart_characteristics.xml:L238-L239, data/stk_config.xml:L248)
ItemTuning.bubblegum = table.freeze({
	DURATION_SEC = 1.0, -- data/kart_characteristics.xml:L238 duration="1"
	SPEED_FRACTION = 0.3, -- data/kart_characteristics.xml:L238 speed-fraction="0.3"
	TORQUE = 500.0, -- data/kart_characteristics.xml:L238 torque="500"
	FADE_IN_SEC = 0.01, -- data/kart_characteristics.xml:L238 fade-in-time="0.01"
	SHIELD_DURATION_SEC = 10.0, -- data/kart_characteristics.xml:L239 shield-duration="10.0" / stk_config.xml:L248
	DISAPPEAR_COUNTER = 1, -- data/stk_config.xml:L248 disappear-counter="1"
	RESTRICT_WEAPONS = false, -- data/stk_config.xml:L248 restrict-weapons="false"
	-- Expiring bubblegum shield flash timings (src/items/attachment.cpp:L654-L667)
	SHIELD_SLOW_FLASH_THRESHOLD_SEC = 3.0,
	SHIELD_SLOW_FLASH_PERIOD_SEC = 0.2,
	SHIELD_FAST_FLASH_THRESHOLD_SEC = 0.5,
	SHIELD_FAST_FLASH_PERIOD_SEC = 0.07,
})

-- Banana-triggered & item-triggered attachment constants (kart_characteristics.xml:L211, L229-L231, L301)
ItemTuning.parachute = table.freeze({
	FRICTION = 5.0, -- data/kart_characteristics.xml:L229 friction="5.0"
	DURATION_SEC = 3.0, -- data/kart_characteristics.xml:L229 duration="3" (banana)
	DURATION_OTHER_SEC = 2.5, -- data/kart_characteristics.xml:L229 duration-other="2.5" (powerup)
	DURATION_RANK_MULT = 1.5, -- data/kart_characteristics.xml:L230 duration-rank-mult="1.5"
	DURATION_SPEED_MULT = 1.35, -- data/kart_characteristics.xml:L230 duration-speed-mult="1.35"
	LBOUND_FRACTION = 0.5, -- data/kart_characteristics.xml:L231 lbound-fraction="0.5"
	UBOUND_FRACTION = 0.3, -- data/kart_characteristics.xml:L231 ubound-fraction="0.3"
	MAX_SPEED = 30.0, -- data/kart_characteristics.xml:L231 max-speed="30"
})

ItemTuning.anvil = table.freeze({
	DURATION_SEC = 2.0, -- data/kart_characteristics.xml:L211 duration="2.0"
	WEIGHT_KG = 150.0, -- data/kart_characteristics.xml:L211 weight="150"
	SPEED_FACTOR = 0.2, -- data/kart_characteristics.xml:L211 speed-factor="0.2"
})

ItemTuning.bomb = table.freeze({
	DURATION_SEC = 30.0, -- data/stk_config.xml:L221 time="30.0"
	EXPLOSION_DURATION_SEC = 1.5, -- data/kart_characteristics.xml:L301 duration="1.5"
	RADIUS = 6.0, -- data/kart_characteristics.xml:L301 radius="6"
	INVULNERABILITY_SEC = 7.0, -- data/kart_characteristics.xml:L302 invulnerability-time="7"
})

-- Switch (swapper) duration (data/stk_config.xml:L242 <switch time="5" items="1 0 4 4 2 2 6"/>)
ItemTuning.switch = table.freeze({
	DURATION_SEC = 5.0,
})

-- Swatter constants (data/kart_characteristics.xml:L260-L261, src/items/swatter.cpp:L48-L83, L151-L166, L253-L305)
ItemTuning.SWATTER_PHASE_AIMING = 0
ItemTuning.SWATTER_PHASE_TO_TARGET = 1
ItemTuning.SWATTER_PHASE_FROM_TARGET = 2

ItemTuning.swatter = table.freeze({
	DURATION_SEC = 10.0,
	DISTANCE_SQUARED = 9.0,
	SQUASH_DURATION_SEC = 5.0,
	SQUASH_SLOWDOWN = 0.5,
	BOMB_REMOVE_SEC = 40.0 / 25.0,
	POS_OFFSET = table.freeze({ x = 0.0, y = 0.2, z = -0.4 }),
	START_GUARD_SEC = 0.5,
	END_GUARD_SEC = 0.75,
	SWING_DOWN_SEC = 0.166666672,
	SWING_UP_SEC = 0.5,
	ANGLE_OFFSET_DEG = 105.0,
	BOMB_FPS = 25.0,
	BOMB_TOTAL_FRAMES = 40.0,
	BOMB_FLY_START_FRAME = 32.5,
	BOMB_HIDE_FRAME = 35.0,
})

-- Flyable base constants (src/items/flyable.cpp:L537-L542)
ItemTuning.flyable = table.freeze({
	OWNER_IMMUNITY_SEC = 2.0,
	HIT_RADIUS_KART = 0.85,
})

-- Cake projectile constants (data/powerup.xml:L10-L13, src/items/cake.cpp:L48, L96-L106, flyable.cpp:L291, L305)
ItemTuning.cake = table.freeze({
	SPEED = 50.0,
	MAX_DISTANCE = 90.0,
	CONE_MAX_DIST = 50.0,
	CONE_COS_MIN = 0.54,
	GRAVITY = 9.8,
	BASE_SPEED_ADD = 16.0,
	OWNER_SPEED_REF = 23.0,
	REVERSE_SPEED_DIV = 3.6,
	UP_VEL_DIV = 7.0,
	MIN_HEIGHT = 0.2,
	MAX_HEIGHT = 1.0,
	RESTITUTION = 0.5,
	RADIUS = 0.34,
})

-- Bowling ball constants (data/powerup.xml:L4-L8, src/items/bowling.cpp:L37, L63-L70, L96, L209-L238)
ItemTuning.bowling = table.freeze({
	SPEED = 4.0,
	MASS = 50.0,
	FORCE_TO_TARGET = 40.0,
	MAX_DISTANCE = 25.0,
	MAX_ATTRACTION_ANGLE_RAD = 1.3,
	LIFESPAN_SEC = 20.0,
	GRAVITY = 70.0,
	RESTITUTION = 0.4,
	MIN_SPEED_MULT = 4.0,
	MIN_HEIGHT = 0.2,
	MAX_HEIGHT = 1.0,
	RADIUS = 0.44,
})

-- Plunger + rubber band constants (data/powerup.xml:L92-L96, data/kart_characteristics.xml:L269-L271, L350, L354)
ItemTuning.plunger = table.freeze({
	SPEED = 35.0,
	SPEED_MULT = 2.0,
	AIM_MAX_DISTANCE = 30.0,
	MAX_DISTANCE = 25.0,
	BAND_MAX_LENGTH = 50.0,
	BAND_FORCE = 1500.0,
	BAND_DURATION_SEC = 1.0,
	BAND_SPEED_INCREASE = 7.0,
	BAND_FADE_OUT_SEC = 3.0,
	BAND_TRACK_SNAP_DIST = 10.0,
	IN_FACE_TIME_BY_DIFF = table.freeze({
		easy = 3.0,
		medium = 4.0,
		hard = 4.5,
		best = 4.5,
	}),
	RADIUS = 0.35,
})

-- Basketball (rubber-ball) constants (data/powerup.xml:L75-L89, src/items/rubber_ball.cpp:L294-L364)
ItemTuning.rubberBall = table.freeze({
	SPEED = 40.0,
	MIN_SPEED_OFFSET = 10.0, -- rubber_ball.cpp:L355-L356 clamps XML 9.0 -> 10.0
	MAX_SPEED_OFFSET = 29.0,
	MIN_OFFSET_DISTANCE = 50.0,
	MAX_OFFSET_DISTANCE = 250.0,
	INTERVAL_SEC = 1.0,
	MIN_HEIGHT = 0.0,
	MAX_HEIGHT = 4.0,
	FAST_PING_DISTANCE = 50.0,
	TARGET_DISTANCE = 15.0,
	TARGET_MAX_ANGLE_RAD = math.rad(90.0),
	DELETE_TIME_SEC = 5.0,
	SQUASH_SLOWDOWN = 0.5, -- data/powerup.xml:L88 squash-slowdown="0.5"
	SQUASH_DURATION_SEC = 2.0, -- data/powerup.xml:L88 squash-duration="2"
	SQUASH_FADE_IN_SEC = 0.1, -- src/karts/kart.cpp:L1879 time2Ticks(0.1f)
	RADIUS = 0.92,
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

-- StandardRace::getDefaultCollectibles (src/modes/standard_race.cpp:L49-L59) &
-- World::getDefaultCollectibles (src/modes/world.cpp:L1476-L1480).
-- Time Trial grants numLaps zippers at race start; all other modes start empty.
function ItemTuning.getDefaultCollectibles(raceType: string?, totalLaps: number?): (number, number)
	if raceType == "TIME_TRIAL" then
		local laps = if type(totalLaps) == "number" then math.floor(totalLaps) else 1
		return ItemTuning.POWERUP_ZIPPER, math.clamp(laps, 1, 255)
	end
	return ItemTuning.POWERUP_NONE, 0
end

return ItemTuning
