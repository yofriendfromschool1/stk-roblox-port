--!strict
-- tests/Items.spec.luau
-- SPDX-License-Identifier: GPL-3.0-or-later

local FixedStep = require("../src/shared/sim/FixedStep")
local GreyboxArenaData = require("../src/shared/track/GreyboxArenaData")
local GreyboxProtocol = require("../src/shared/net/GreyboxProtocol")
local ItemEffectState = require("../src/shared/sim/ItemEffectState")
local ItemTuning = require("../src/shared/ItemTuning")
local ItemWorld = require("../src/shared/items/ItemWorld")
local KartSolver = require("../src/shared/sim/KartSolver")
local KartTuning = require("../src/shared/KartTuning")
local Math3D = require("../src/shared/sim/Math3D")
local PowerupManager = require("../src/shared/items/PowerupManager")

type Vec3 = Math3D.Vec3
type WorldQuery = KartSolver.WorldQuery

export type TestCase = {
	name: string,
	fn: () -> (),
}

local function assertEqual(actual: any, expected: any, label: string?)
	if actual ~= expected then
		local prefix = if label then label .. ": " else ""
		error(string.format("%sexpected %s, got %s", prefix, tostring(expected), tostring(actual)))
	end
end

local function assertNear(actual: number, expected: number, eps: number?, label: string?)
	local tolerance = eps or 1e-6
	if actual ~= actual or math.abs(actual - expected) > tolerance then
		local prefix = if label then label .. ": " else ""
		error(string.format("%sexpected %s (+/-%g), got %s", prefix, tostring(expected), tolerance, tostring(actual)))
	end
end

local function makeFlatPlaneWorld(groundY: number): WorldQuery
	return {
		raycast = function(origin: Vec3, dir: Vec3, length: number): KartSolver.RayHit?
			if math.abs(dir.y) < 1e-9 then
				return nil
			end
			local t = (groundY - origin.y) / dir.y
			if t >= 0 and t <= length then
				return {
					distance = t,
					point = {
						x = origin.x + dir.x * t,
						y = groundY,
						z = origin.z + dir.z * t,
					},
					normal = { x = 0, y = 1, z = 0 },
					materialName = "road.jpg",
				}
			end
			return nil
		end,
	}
end

return {
	{
		name = "PowerupManager solo rank-1 weight table matches data/powerup.xml",
		fn = function()
			local mgr = PowerupManager.new("NORMAL_RACE", 1)
			local weights = mgr:getRankWeights(1)
			assertEqual(weights.total, 1000, "solo rank 1 total weight")
			assertEqual(weights.single[ItemTuning.POWERUP_BUBBLEGUM], 140, "bubblegum weight")
			assertEqual(weights.single[ItemTuning.POWERUP_CAKE], 0, "cake weight")
			assertEqual(weights.single[ItemTuning.POWERUP_BOWLING], 300, "bowling weight")
			assertEqual(weights.single[ItemTuning.POWERUP_ZIPPER], 100, "zipper weight")
			assertEqual(weights.single[ItemTuning.POWERUP_PLUNGER], 225, "plunger weight")
			assertEqual(weights.single[ItemTuning.POWERUP_SWITCH], 75, "switch weight")
			assertEqual(weights.single[ItemTuning.POWERUP_SWATTER], 160, "swatter weight")
			assertEqual(weights.single[ItemTuning.POWERUP_RUBBERBALL], 0, "rubberball weight")

			local cases = {
				{ seed = 0, pid = ItemTuning.POWERUP_BUBBLEGUM },
				{ seed = 139, pid = ItemTuning.POWERUP_BUBBLEGUM },
				{ seed = 140, pid = ItemTuning.POWERUP_BOWLING },
				{ seed = 439, pid = ItemTuning.POWERUP_BOWLING },
				{ seed = 440, pid = ItemTuning.POWERUP_ZIPPER },
				{ seed = 539, pid = ItemTuning.POWERUP_ZIPPER },
				{ seed = 540, pid = ItemTuning.POWERUP_PLUNGER },
				{ seed = 764, pid = ItemTuning.POWERUP_PLUNGER },
				{ seed = 765, pid = ItemTuning.POWERUP_SWITCH },
				{ seed = 839, pid = ItemTuning.POWERUP_SWITCH },
				{ seed = 840, pid = ItemTuning.POWERUP_SWATTER },
				{ seed = 999, pid = ItemTuning.POWERUP_SWATTER },
			}
			for _, tc in cases do
				local pid, cnt = mgr:getRandomPowerup(1, tc.seed, 0.0)
				assertEqual(pid, tc.pid, "seed " .. tostring(tc.seed))
				assertEqual(cnt, 1, "solo count")
			end
		end,
	},
	{
		name = "PowerupManager multi-kart interpolation & early explosive downgrade",
		fn = function()
			-- At numKarts = 5, last rank (5) uses section 4 (has CAKE single=105 & RUBBERBALL single=40)
			local mgr5 = PowerupManager.new("NORMAL_RACE", 5)
			local w5 = mgr5:getRankWeights(5)
			-- Single weights precede multi; seed inside CAKE interval [145..249] -> CAKE when >=15s, BOWLING when <15s
			local cakeSeed = w5.single[ItemTuning.POWERUP_BUBBLEGUM] -- 145
			local pidEarly, cntEarly = mgr5:getRandomPowerup(5, cakeSeed, 5.0)
			assertEqual(pidEarly, ItemTuning.POWERUP_BOWLING, "early explosive downgraded to bowling")
			assertEqual(cntEarly, 1, "early downgrade keeps count=1")

			local pidLate, _ = mgr5:getRandomPowerup(5, cakeSeed, 20.0)
			assertEqual(pidLate, ItemTuning.POWERUP_CAKE, "after 15s timeout allows cake")
		end,
	},
	{
		name = "PowerupManager gated to IMPLEMENTED_POWERUPS matches upstream solo rank 1 weights (9/10 gate)",
		fn = function()
			local gated = PowerupManager.new("NORMAL_RACE", 1, ItemTuning.IMPLEMENTED_POWERUPS)
			local weights = gated:getRankWeights(1)
			assertEqual(
				weights.total,
				1000,
				"gated total equals BUBBLEGUM(140)+BOWLING(300)+ZIPPER(100)+PLUNGER(225)+SWITCH(75)+SWATTER(160)"
			)
			assertEqual(weights.single[ItemTuning.POWERUP_BUBBLEGUM], 140, "bubblegum weight preserved")
			assertEqual(weights.single[ItemTuning.POWERUP_BOWLING], 300, "bowling weight preserved")
			assertEqual(weights.single[ItemTuning.POWERUP_ZIPPER], 100, "zipper weight preserved")
			assertEqual(weights.single[ItemTuning.POWERUP_PLUNGER], 225, "plunger weight preserved")
			assertEqual(weights.single[ItemTuning.POWERUP_SWITCH], 75, "switch weight preserved")
			assertEqual(weights.single[ItemTuning.POWERUP_SWATTER], 160, "swatter weight preserved")
			assertEqual(weights.single[ItemTuning.POWERUP_ANVIL], 0, "unimplemented anvil zeroed")
			for seed = 0, 999 do
				local pid, _ = gated:getRandomPowerup(1, seed, 20.0)
				assert(ItemTuning.IMPLEMENTED_POWERUPS[pid] == true, "gated roll yields only implemented powerups")
			end
		end,
	},
	{
		name = "PowerupManager 10000-roll solo distribution matches upstream data/powerup.xml weights",
		fn = function()
			local mgr = PowerupManager.new("NORMAL_RACE", 1, nil)
			local weights = mgr:getRankWeights(1)
			local counts = table.create(ItemTuning.POWERUP_LAST, 0)
			local nRolls = 10000
			math.randomseed(42)
			for _ = 1, nRolls do
				local seed = math.random(0, 2147483646)
				local pid, _ = mgr:getRandomPowerup(1, seed, 20.0)
				counts[pid] += 1
			end
			for i = ItemTuning.POWERUP_FIRST, ItemTuning.POWERUP_LAST do
				local expectedFrac = (weights.single[i] + weights.multi[i]) / weights.total
				local actualFrac = counts[i] / nRolls
				assertNear(
					actualFrac,
					expectedFrac,
					0.015,
					"10000-roll distribution for " .. ItemTuning.POWERUP_NAMES[i]
				)
			end
		end,
	},
	{
		name = "PA_FIRE on POWERUP_ZIPPER triggers MaxSpeed ZIPPER boost and consumes charge",
		fn = function()
			local world = makeFlatPlaneWorld(0.0)
			local profile = KartTuning.buildProfile("medium", "best")
			local state = KartSolver.createState(profile, { x = 0, y = 0.291, z = 0 }, 0)
			state.linVel = { x = 0, y = 0, z = 20.0 }
			state.speed = 20.0
			local itemWorld = ItemWorld.createEmpty("NORMAL_RACE")
			KartSolver.setPowerup(state, ItemTuning.POWERUP_ZIPPER, 1)

			KartSolver.stepWithItems(state, {
				accel = 1.0,
				brake = false,
				steer = 0,
				drift = false,
				fire = true,
			}, world, FixedStep.FIXED_DT, itemWorld, { isServer = true, kartId = 3 })

			assertEqual(state.heldPowerup, ItemTuning.POWERUP_NONE, "ZIPPER consumed")
			assertEqual(state.heldPowerupCount, 0, "ZIPPER charge decremented to 0")
			assert(state.maxSpeedState.increases["ZIPPER"] ~= nil, "ZIPPER MaxSpeed category active")
			assertNear(state.speed, 24.5, 0.5, "ZIPPER grants instant +4.5 m/s speed gain")
			assertEqual(#itemWorld.items, 0, "ZIPPER does not drop a hazard")
		end,
	},
	{
		name = "ItemWorld loads arena items, omits bonus boxes in TIME_TRIAL, & enforces 240-tick respawn",
		fn = function()
			local normalWorld = ItemWorld.fromArenaSpec(GreyboxArenaData, "NORMAL_RACE")
			assertEqual(#normalWorld.items, 10, "NORMAL_RACE loads all 10 arena items")

			local ttWorld = ItemWorld.fromArenaSpec(GreyboxArenaData, "TIME_TRIAL")
			-- 4 nitro + 3 bananas = 7 (3 bonus boxes excluded by StandardRace::haveBonusBoxes == false)
			assertEqual(#ttWorld.items, 7, "TIME_TRIAL excludes bonus boxes")

			-- Hit small-nitro at (-4, 0.4, 12) in STK coordinates
			local hits1 = ItemWorld.checkHits(normalWorld, { x = -4.0, y = 0.35, z = 12.0 }, 1, 1.0, 3.0)
			assertEqual(#hits1, 1, "first hit collects small-nitro")
			assertEqual(hits1[1].isNitro, true, "small-nitro isNitro")
			assertNear(hits1[1].nitroAmount, 1.0, 1e-6, "small-nitro amount")

			-- Tick 239 times -> still on cooldown
			for _ = 1, 239 do
				ItemWorld.tick(normalWorld)
				local midHits = ItemWorld.checkHits(normalWorld, { x = -4.0, y = 0.35, z = 12.0 }, 1, 1.0, 3.0)
				assertEqual(#midHits, 0, "cannot re-collect before 240 ticks")
			end
			-- Tick 240 -> respawns!
			ItemWorld.tick(normalWorld)
			local hits2 = ItemWorld.checkHits(normalWorld, { x = -4.0, y = 0.35, z = 12.0 }, 1, 1.0, 3.0)
			assertEqual(#hits2, 1, "item respawns at exactly 240 ticks (2.0s)")
		end,
	},
	{
		name = "Bubblegum forward activates 10s shield, absorbs 1 hit -> drops floor gum; expiry also drops gum",
		fn = function()
			local world = makeFlatPlaneWorld(0.0)
			local profile = KartTuning.buildProfile("medium", "best")
			local state = KartSolver.createState(profile, { x = 0, y = 0.291, z = 0 }, 0)
			local itemWorld = ItemWorld.createEmpty("NORMAL_RACE")
			KartSolver.setPowerup(state, ItemTuning.POWERUP_BUBBLEGUM, 1)

			-- Forward PA_FIRE -> activates 1200-tick (10.0s) bubblegum shield
			KartSolver.stepWithItems(state, {
				accel = 0,
				brake = false,
				steer = 0,
				drift = false,
				fire = true,
				lookBack = false,
			}, world, FixedStep.FIXED_DT, itemWorld, { isServer = true, kartId = 7 })

			assertEqual(state.heldPowerupCount, 0, "PA_FIRE consumes bubblegum")
			assertEqual(KartSolver.isShielded(state), true, "shield active")
			assertEqual(state.attachmentType, ItemTuning.ATTACHMENT_BUBBLEGUM_SHIELD, "attachment is shield")
			assertEqual(state.attachmentTicksLeft, 1200, "shield duration is 1200 ticks (10.0s)")
			assertEqual(#itemWorld.items, 0, "no floor gum dropped on shield activation")

			-- Absorb one banana hit -> pops shield & drops ITEM_BUBBLEGUM at kart ground pos (NOT banana!)
			ItemWorld.addTrackItem(itemWorld, 1, "banana", { x = 5.0, y = 0.0, z = 5.0 })
			state.pos = { x = 5.0, y = 0.291, z = 5.0 }
			KartSolver.stepWithItems(state, {
				accel = 0,
				brake = false,
				steer = 0,
				drift = false,
			}, world, FixedStep.FIXED_DT, itemWorld, { isServer = true, kartId = 7 })

			assertEqual(KartSolver.isShielded(state), false, "banana hit popped shield")
			assertEqual(state.attachmentType, ItemTuning.ATTACHMENT_NONE, "attachment cleared after shield drop")
			assertEqual(#itemWorld.items, 2, "banana remains (respawning) + dropped bubblegum created")
			local dropped = itemWorld.items[2]
			assertEqual(dropped.itemType, "bubblegum", "popped shield drops ITEM_BUBBLEGUM, NOT banana")
			assertEqual(dropped.deactiveTicks, 180, "dropped gum has 180-tick (1.5s) owner immunity")

			-- Projectile/squash absorb helper + natural 1200-tick expiry also drops ITEM_BUBBLEGUM
			local sExpire = KartSolver.createState(profile, { x = 0, y = 0.291, z = 0 }, 0)
			local iwExpire = ItemWorld.createEmpty("NORMAL_RACE")
			KartSolver.setPowerup(sExpire, ItemTuning.POWERUP_BUBBLEGUM, 1)
			KartSolver.stepWithItems(sExpire, {
				accel = 0,
				brake = false,
				steer = 0,
				drift = false,
				fire = true,
			}, world, FixedStep.FIXED_DT, iwExpire, { isServer = true, kartId = 9 })
			for _ = 1, 1199 do
				KartSolver.stepWithItems(sExpire, {
					accel = 0,
					brake = false,
					steer = 0,
					drift = false,
				}, world, FixedStep.FIXED_DT, iwExpire, { isServer = true, kartId = 9 })
				assertEqual(KartSolver.isShielded(sExpire), true, "shield stays up through tick 1199")
			end
			-- Tick 1200 hits 0 -> expires & drops floor gum
			KartSolver.stepWithItems(sExpire, {
				accel = 0,
				brake = false,
				steer = 0,
				drift = false,
			}, world, FixedStep.FIXED_DT, iwExpire, { isServer = true, kartId = 9 })
			assertEqual(KartSolver.isShielded(sExpire), false, "shield expires at 1200 ticks")
			assertEqual(#iwExpire.items, 1, "expired shield drops 1 item")
			assertEqual(iwExpire.items[1].itemType, "bubblegum", "expired shield drops bubblegum")

			-- Projectile absorb check via applySquashHit
			local sProj = KartSolver.createState(profile, { x = 0, y = 0.291, z = 0 }, 0)
			local iwProj = ItemWorld.createEmpty("NORMAL_RACE")
			KartSolver.setPowerup(sProj, ItemTuning.POWERUP_BUBBLEGUM, 1)
			KartSolver.stepWithItems(sProj, {
				accel = 0,
				brake = false,
				steer = 0,
				drift = false,
				fire = true,
			}, world, FixedStep.FIXED_DT, iwProj, { isServer = true, kartId = 3 })
			local squashed = KartSolver.applySquashHit(sProj)
			assertEqual(squashed, false, "shield absorbs incoming squash/projectile hit")
			KartSolver.stepWithItems(sProj, {
				accel = 0,
				brake = false,
				steer = 0,
				drift = false,
			}, world, FixedStep.FIXED_DT, iwProj, { isServer = true, kartId = 3 })
			assertEqual(KartSolver.isShielded(sProj), false, "shield cleared after projectile absorb")
			assertEqual(#iwProj.items, 1, "projectile-popped shield drops bubblegum")
			assertEqual(iwProj.items[1].itemType, "bubblegum", "dropped item is bubblegum")
		end,
	},
	{
		name = "Look-back + PA_FIRE drops floor bubblegum (180t owner immunity), and shield ignores floor gum",
		fn = function()
			local world = makeFlatPlaneWorld(0.0)
			local profile = KartTuning.buildProfile("medium", "best")
			local state = KartSolver.createState(profile, { x = 0, y = 0.291, z = 0 }, 0)
			local itemWorld = ItemWorld.createEmpty("NORMAL_RACE")
			KartSolver.setPowerup(state, ItemTuning.POWERUP_BUBBLEGUM, 1)

			-- Hold lookBack + PA_FIRE -> drops ITEM_BUBBLEGUM directly without activating shield
			KartSolver.stepWithItems(state, {
				accel = 0,
				brake = false,
				steer = 0,
				drift = false,
				fire = true,
				lookBack = true,
			}, world, FixedStep.FIXED_DT, itemWorld, { isServer = true, kartId = 7 })

			assertEqual(KartSolver.isShielded(state), false, "look-back drop must not activate shield")
			assertEqual(#itemWorld.items, 1, "one dropped bubblegum created")
			local gum = itemWorld.items[1]
			assertEqual(gum.itemType, "bubblegum", "dropped item is bubblegum")
			assertEqual(gum.deactiveTicks, 180, "owner immunity is 180 ticks (1.5s)")

			-- Shielded kart drives over the floor bubblegum -> ignores it completely!
			local shieldedKart = KartSolver.createState(profile, { x = gum.pos.x, y = 0.291, z = gum.pos.z }, 0)
			shieldedKart.attachmentType = ItemTuning.ATTACHMENT_BUBBLEGUM_SHIELD
			shieldedKart.attachmentTicksLeft = 600
			gum.deactiveTicks = 0
			local shieldHits = KartSolver.stepWithItems(shieldedKart, {
				accel = 1.0,
				brake = false,
				steer = 0,
				drift = false,
			}, world, FixedStep.FIXED_DT, itemWorld, { isServer = true, kartId = 8, advanceItemWorld = false })
			assertEqual(#shieldHits, 0, "shielded kart bypasses floor gum")
			assertEqual(#itemWorld.items, 1, "floor gum stays on track after shielded kart passes")
			assertEqual(KartSolver.isShielded(shieldedKart), true, "floor gum does NOT pop shield")
			assertEqual(
				shieldedKart.itemEffect.effectType,
				ItemEffectState.EFFECT_NONE,
				"shielded kart receives zero effect"
			)

			-- Unshielded kart drives over floor gum -> 1.0s (120t) BUBBLE 0.3x slowdown, engine cut, disappearCounter=0
			local unshielded = KartSolver.createState(profile, { x = gum.pos.x, y = 0.291, z = gum.pos.z }, 0)
			unshielded.linVel = { x = 0, y = 0, z = 20.0 }
			unshielded.speed = 20.0
			local hits = KartSolver.stepWithItems(unshielded, {
				accel = 1.0,
				brake = false,
				steer = 0,
				drift = false,
			}, world, FixedStep.FIXED_DT, itemWorld, { isServer = true, kartId = 9, advanceItemWorld = false })
			assertEqual(#hits, 1, "unshielded kart collects floor gum")
			assertEqual(hits[1].isBubblegum, true, "event flagged isBubblegum")
			assertEqual(hits[1].isBanana, false, "event is NOT banana")
			assertEqual(#itemWorld.items, 0, "disappear-counter=1 removes floor gum")
			assertEqual(
				unshielded.itemEffect.effectType,
				ItemEffectState.EFFECT_BUBBLEGUM_SLOW,
				"bubblegum routed through ItemEffectState"
			)
			assertEqual(KartSolver.getTelemetry(unshielded).bubblegumTicks, 120, "bubblegumTicks = 120 (1.0s)")
			assertEqual(
				ItemEffectState.isThrottleSuppressed(unshielded.itemEffect),
				true,
				"floor gum suppresses throttle"
			)
			-- Re-trigger blocked while active
			assertEqual(
				KartSolver.applyBubblegumHit(unshielded, 100),
				false,
				"re-trigger blocked while floor gum active"
			)
			local bubble = unshielded.maxSpeedState.decreases["BUBBLE"]
			assert(bubble ~= nil, "BUBBLE slowdown active")
			assertNear((bubble :: any).targetFraction, 0.3, 1e-6, "BUBBLE slows to 0.3x")
			assertEqual(unshielded.maxSpeedState.decreases["SQUASH"], nil, "floor gum does NOT set SQUASH")
			-- Verify throttle suppression ends after exact 120 ticks & speed stays clamped near 0.3 * maxSpeed
			for t = 1, 119 do
				KartSolver.stepWithItems(unshielded, {
					accel = 1.0,
					brake = false,
					steer = 0,
					drift = false,
				}, world, FixedStep.FIXED_DT, itemWorld, { isServer = true, kartId = 9, advanceItemWorld = false })
				assert(
					ItemEffectState.isThrottleSuppressed(unshielded.itemEffect),
					"throttle suppressed through tick " .. tostring(t)
				)
			end
			KartSolver.stepWithItems(unshielded, {
				accel = 1.0,
				brake = false,
				steer = 0,
				drift = false,
			}, world, FixedStep.FIXED_DT, itemWorld, { isServer = true, kartId = 9, advanceItemWorld = false })
			assertEqual(
				ItemEffectState.isThrottleSuppressed(unshielded.itemEffect),
				false,
				"floor gum clears on tick 120"
			)
			assert(unshielded.speed <= profile.maxSpeed * 0.3 + 0.5, "floor gum slows speed to <= 0.3 * maxSpeed")
		end,
	},
	{
		name = "Banana hit attaches PARACHUTE / ANVIL / BOMB per upstream STK mod-3 table (no squash)",
		fn = function()
			local profile = KartTuning.buildProfile("medium", "best")
			-- Slot 0 (ticks=0..15): PARACHUTE (360 ticks = 3.0s, 5x air drag)
			local sPara = KartSolver.createState(profile, { x = 0, y = 0.291, z = 0 }, 0)
			sPara.speed = 20.0
			KartSolver.applyBananaHit(sPara, 0, false)
			assertEqual(sPara.attachmentType, ItemTuning.ATTACHMENT_PARACHUTE, "slot 0 -> PARACHUTE")
			assertEqual(sPara.attachmentTicksLeft, 360, "parachute 360 ticks")
			assertEqual(sPara.maxSpeedState.decreases["SQUASH"], nil, "banana never sets SQUASH")

			-- Slot 1 (ticks=16..31): ANVIL (240 ticks = 2.0s, 0.2x speed factor, +150 kg)
			local sAnvil = KartSolver.createState(profile, { x = 0, y = 0.291, z = 0 }, 0)
			sAnvil.linVel = { x = 0, y = 0, z = 20.0 }
			sAnvil.speed = 20.0
			KartSolver.applyBananaHit(sAnvil, 16, false)
			assertEqual(sAnvil.attachmentType, ItemTuning.ATTACHMENT_ANVIL, "slot 1 -> ANVIL")
			assertEqual(sAnvil.attachmentTicksLeft, 240, "anvil 240 ticks")
			assertNear(sAnvil.linVel.z, 4.0, 1e-5, "anvil adjusts speed immediately by 0.2x")

			-- Slot 2 (ticks=32..47): BOMB (3600 ticks = 30.0s in NORMAL_RACE)
			local sBomb = KartSolver.createState(profile, { x = 0, y = 0.291, z = 0 }, 0)
			KartSolver.applyBananaHit(sBomb, 32, false)
			assertEqual(sBomb.attachmentType, ItemTuning.ATTACHMENT_BOMB, "slot 2 -> BOMB")
			assertEqual(sBomb.attachmentTicksLeft, 3600, "bomb 3600 ticks")
		end,
	},
	{
		name = "Deterministic net snapshot & unacknowledged input replay across shield, look-back gum, and pickups",
		fn = function()
			local world = makeFlatPlaneWorld(0.0)
			local profile = KartTuning.buildProfile("medium", "best")
			local mgr = PowerupManager.new("NORMAL_RACE", 1)

			local srvItemWorld = ItemWorld.createEmpty("NORMAL_RACE")
			ItemWorld.addTrackItem(srvItemWorld, 1, "small-nitro", { x = 0, y = 0.291, z = 6.0 })
			ItemWorld.addTrackItem(srvItemWorld, 2, "item", { x = 0, y = 0.291, z = 12.0 })
			ItemWorld.addTrackItem(srvItemWorld, 3, "big-nitro", { x = 0, y = 0.291, z = 18.0 })

			local cliItemWorld = ItemWorld.createEmpty("NORMAL_RACE")
			ItemWorld.addTrackItem(cliItemWorld, 1, "small-nitro", { x = 0, y = 0.291, z = 6.0 })
			ItemWorld.addTrackItem(cliItemWorld, 2, "item", { x = 0, y = 0.291, z = 12.0 })
			ItemWorld.addTrackItem(cliItemWorld, 3, "big-nitro", { x = 0, y = 0.291, z = 18.0 })

			local srvState = KartSolver.createState(profile, { x = 0, y = 0.291, z = 0 }, 0)
			local cliState = KartSolver.createState(profile, { x = 0, y = 0.291, z = 0 }, 0)

			local history: { { seq: number, input: KartSolver.KartInput } } = {}
			local ackSeq = 0
			local ackNums: { number } = {}
			local ackIncs: { { number } }? = nil
			local ackNotice: string? = nil
			local ackItems: any = nil

			local totalTicks = 240
			local ackAtTick = 170
			for tick = 1, totalTicks do
				local input: KartSolver.KartInput = {
					accel = 1.0,
					brake = false,
					steer = 0.0,
					drift = false,
					nitro = false,
					fire = (tick == 195),
					lookBack = (tick == 195), -- unacknowledged look-back + PA_FIRE drops floor bubblegum
				}
				table.insert(history, { seq = tick, input = input })

				KartSolver.stepWithItems(srvState, input, world, FixedStep.FIXED_DT, srvItemWorld, {
					isServer = true,
					kartId = 42,
					rollPowerup = function(_s, _ev)
						-- Seed 0 in rank-1 NORMAL_RACE deterministically rolls POWERUP_BUBBLEGUM
						return mgr:getRandomPowerup(1, 0, tick * FixedStep.FIXED_DT)
					end,
				})
				KartSolver.stepWithItems(cliState, input, world, FixedStep.FIXED_DT, cliItemWorld, {
					isServer = false,
					kartId = 42,
				})

				if tick == ackAtTick then
					ackSeq = tick
					ackNums, ackIncs, ackNotice, ackItems = GreyboxProtocol.packSnapshot(
						tick,
						tick,
						1,
						KartSolver.captureNetState(srvState, srvItemWorld),
						""
					)
				end
			end

			assertEqual(srvState.heldPowerup, ItemTuning.POWERUP_NONE, "server spent BUBBLEGUM on tick 195")
			assertEqual(#srvItemWorld.items, 4, "3 track items + 1 dropped bubblegum")
			assertEqual(srvItemWorld.items[4].itemType, "bubblegum", "dropped item #4 is bubblegum")

			local packet = GreyboxProtocol.unpackSnapshot(ackNums, ackIncs, ackNotice, ackItems)
			assertEqual(packet ~= nil, true, "snapshot unpacked")
			local pkt = packet :: GreyboxProtocol.TelemetryPacket
			KartSolver.applyNetState(cliState, pkt.netState, cliItemWorld)
			for _, entry in history do
				if entry.seq > ackSeq then
					KartSolver.stepWithItems(cliState, entry.input, world, FixedStep.FIXED_DT, cliItemWorld, {
						isServer = false,
						kartId = 42,
					})
				end
			end

			assertNear(cliState.pos.x, srvState.pos.x, 1e-6, "reconciled pos.x")
			assertNear(cliState.pos.y, srvState.pos.y, 1e-6, "reconciled pos.y")
			assertNear(cliState.pos.z, srvState.pos.z, 1e-6, "reconciled pos.z")
			assertNear(cliState.nitro.energy, srvState.nitro.energy, 1e-6, "reconciled nitro")
			assertEqual(cliState.attachmentType, srvState.attachmentType, "reconciled attachmentType")
			assertEqual(cliState.attachmentTicksLeft, srvState.attachmentTicksLeft, "reconciled attachmentTicksLeft")
			assertEqual(cliState.itemEffect.effectType, srvState.itemEffect.effectType, "reconciled effectType")
			assertEqual(
				cliState.itemEffect.ticksRemaining,
				srvState.itemEffect.ticksRemaining,
				"reconciled ticksRemaining"
			)
			assertEqual(#cliItemWorld.items, #srvItemWorld.items, "reconciled item count")
			for i = 1, #srvItemWorld.items do
				assertEqual(cliItemWorld.items[i].id, srvItemWorld.items[i].id, "item id match")
				assertEqual(cliItemWorld.items[i].itemType, srvItemWorld.items[i].itemType, "itemType match")
				assertEqual(
					cliItemWorld.items[i].ticksTillReturn,
					srvItemWorld.items[i].ticksTillReturn,
					"item respawn timer match"
				)
				assertEqual(
					cliItemWorld.items[i].deactiveTicks,
					srvItemWorld.items[i].deactiveTicks,
					"item deactiveTicks match"
				)
			end
		end,
	},
	{
		name = "Bomb explosion forces 0 m/s dead stop, suppresses input for exact 180 ticks, & blocks re-trigger for 7s",
		fn = function()
			local world = makeFlatPlaneWorld(0.0)
			local profile = KartTuning.buildProfile("medium", "best")
			local state = KartSolver.createState(profile, { x = 0, y = 0.291, z = 0 }, 0)
			local itemWorld = ItemWorld.createEmpty("NORMAL_RACE")

			-- Accelerate to >18 m/s first (3.5s = 420 ticks)
			for _ = 1, 420 do
				KartSolver.stepWithItems(state, {
					accel = 1.0,
					brake = false,
					steer = 0.0,
					drift = false,
				}, world, FixedStep.FIXED_DT, itemWorld, { isServer = true, kartId = 1 })
			end
			assert(state.speed > 18.0, "kart accelerated past 18 m/s before bomb detonation")

			-- Detonate bomb via banana-on-bomb (attachment.cpp:L323-L335)
			state.attachmentType = ItemTuning.ATTACHMENT_BOMB
			state.attachmentTicksLeft = 100
			ItemWorld.addTrackItem(itemWorld, 1, "banana", { x = state.pos.x, y = 0.0, z = state.pos.z })
			KartSolver.stepWithItems(state, {
				accel = 1.0,
				brake = false,
				steer = 1.0,
				drift = true,
			}, world, FixedStep.FIXED_DT, itemWorld, { isServer = true, kartId = 1 })

			local originPos = { x = state.pos.x, y = state.pos.y, z = state.pos.z }
			assertEqual(state.itemEffect.effectType, ItemEffectState.EFFECT_EXPLOSION, "explosion active")
			assertEqual(state.itemEffect.ticksRemaining, 180, "1.5s = 180 ticks")
			assertEqual(state.itemEffect.invulnerableTicks, 840, "7.0s = 840 ticks invulnerability")
			assertEqual(KartSolver.isDriverInputSuppressed(state), true, "driver input suppressed immediately")
			assertNear(state.speed, 0.0, 1e-6, "forward speed dropped to 0 m/s immediately")
			assertEqual(KartSolver.triggerExplosion(state, 500, true), false, "re-trigger blocked during explosion")
			assertEqual(KartSolver.applySquashHit(state, 5.0, 0.5, 500), false, "squash blocked during explosion")

			local peakY = originPos.y
			KartSolver.setPowerup(state, ItemTuning.POWERUP_ZIPPER, 1)
			for tick = 1, 180 do
				assertEqual(
					KartSolver.isDriverInputSuppressed(state),
					true,
					"suppressed before tick " .. tostring(tick)
				)
				KartSolver.stepWithItems(state, {
					accel = 1.0,
					brake = false,
					steer = 1.0,
					drift = true,
					fire = true,
				}, world, FixedStep.FIXED_DT, itemWorld, { isServer = true, kartId = 1 })
				assertNear(state.speed, 0.0, 1e-6, "speed stays 0 on explosion tick " .. tostring(tick))
				assertNear(state.pos.x, originPos.x, 1e-4, "zero X translation during explosion")
				assertNear(state.pos.z, originPos.z, 1e-4, "zero Z translation during explosion")
				if state.pos.y > peakY then
					peakY = state.pos.y
				end
			end

			assert(peakY > originPos.y + 2.0, "explosion tossed kart vertically in parabolic arc")
			assertNear(state.pos.y, originPos.y, 1e-4, "landed cleanly back at origin Y at tick 180")
			assertEqual(KartSolver.isDriverInputSuppressed(state), false, "input unlocked after exact 180 ticks")
			assertEqual(state.heldPowerupCount, 1, "PA_FIRE was blocked during explosion")
			assertEqual(
				state.itemEffect.invulnerableTicks,
				660,
				"840 - 180 = 660 ticks post-explosion invulnerability remaining"
			)
			assertEqual(
				KartSolver.triggerExplosion(state, 700, true),
				false,
				"re-trigger blocked during 7s invulnerability"
			)

			-- Tick 181+ accepts throttle again from 0 m/s
			for _ = 1, 5 do
				KartSolver.stepWithItems(state, {
					accel = 1.0,
					brake = false,
					steer = 0.0,
					drift = false,
				}, world, FixedStep.FIXED_DT, itemWorld, { isServer = true, kartId = 1 })
			end
			assert(state.speed > 0.1, "kart accelerates cleanly from 0 m/s after explosion ends")
		end,
	},
	{
		name = "POWERUP_SWATTER removes bomb, squashes nearby kart (600t @ 0.5x), & POWERUP_SWITCH swaps items (600t)",
		fn = function()
			local world = makeFlatPlaneWorld(0.0)
			local profile = KartTuning.buildProfile("medium", "best")
			local itemWorld = ItemWorld.createEmpty("NORMAL_RACE")
			ItemWorld.addTrackItem(itemWorld, 1, "item", { x = 0, y = 0.2, z = 30 })
			ItemWorld.addTrackItem(itemWorld, 2, "banana", { x = 0, y = 0.2, z = 40 })
			ItemWorld.addTrackItem(itemWorld, 3, "big-nitro", { x = 0, y = 0.2, z = 50 })

			-- Swatter removes active bomb in 192 ticks (40/25s) and does not explode
			local sBombSwat = KartSolver.createState(profile, { x = 0, y = 0.291, z = 0 }, 0)
			sBombSwat.attachmentType = ItemTuning.ATTACHMENT_BOMB
			sBombSwat.attachmentTicksLeft = 100
			KartSolver.setPowerup(sBombSwat, ItemTuning.POWERUP_SWATTER, 1)
			KartSolver.stepWithItems(sBombSwat, {
				accel = 1.0,
				brake = false,
				steer = 0.0,
				drift = false,
				fire = true,
			}, world, FixedStep.FIXED_DT, itemWorld, { isServer = true, kartId = 1 })
			assertEqual(sBombSwat.attachmentType, ItemTuning.ATTACHMENT_SWATTER, "SWATTER replaced active BOMB")
			assertEqual(sBombSwat.attachmentTicksLeft, 192, "bomb-removal swing is 192 ticks (40/25s)")

			-- Fresh Swatter lasts 1200 ticks & squashes nearby kart within 3m (r^2 < 9) of SWAT_POS_OFFSET after 0.5s guard + 20t swing
			local attacker = KartSolver.createState(profile, { x = 0, y = 0.291, z = 0 }, 0)
			local victim = KartSolver.createState(profile, { x = 0, y = 0.291, z = 2.5 }, 0)
			victim.linVel = { x = 0, y = 0, z = 22.0 }
			victim.speed = 22.0
			KartSolver.setPowerup(attacker, ItemTuning.POWERUP_SWATTER, 1)
			KartSolver.stepWithItems(attacker, {
				accel = 1.0,
				brake = false,
				steer = 0.0,
				drift = false,
				fire = true,
			}, world, FixedStep.FIXED_DT, itemWorld, { isServer = true, kartId = 2 })
			assertEqual(attacker.attachmentType, ItemTuning.ATTACHMENT_SWATTER, "SWATTER attached")
			assertEqual(attacker.attachmentTicksLeft, 1200, "SWATTER duration is 1200 ticks (10s)")

			local hitCount = 0
			for t = 1, 90 do
				attacker.attachmentTicksLeft -= 1
				hitCount += KartSolver.checkSwatterHits(attacker, { attacker, victim }, 10 + t)
			end
			assertEqual(hitCount, 1, "swatter squashed nearby victim after start guard + swing")
			assertEqual(victim.itemEffect.effectType, ItemEffectState.EFFECT_SQUASH, "victim has EFFECT_SQUASH")
			assertEqual(victim.itemEffect.ticksRemaining, 600, "swatter squash duration = 600 ticks (5s)")
			assertEqual(KartSolver.isDriverInputSuppressed(victim), false, "squash leaves steering enabled")
			assertEqual(
				KartSolver.checkSwatterHits(attacker, { attacker, victim }, 11),
				0,
				"no squash re-trigger while active"
			)

			-- Release PA_FIRE for 1 tick before firing POWERUP_SWITCH
			KartSolver.stepWithItems(attacker, {
				accel = 1.0,
				brake = false,
				steer = 0.0,
				drift = false,
				fire = false,
			}, world, FixedStep.FIXED_DT, itemWorld, { isServer = true, kartId = 2 })

			-- POWERUP_SWITCH swaps items globally for 600 ticks (5s) then restores
			KartSolver.setPowerup(attacker, ItemTuning.POWERUP_SWITCH, 1)
			KartSolver.stepWithItems(attacker, {
				accel = 1.0,
				brake = false,
				steer = 0.0,
				drift = false,
				fire = true,
			}, world, FixedStep.FIXED_DT, itemWorld, { isServer = true, kartId = 2 })
			assertEqual(itemWorld.switchTicks, 600, "SWITCH sets 600-tick (5s) global timer")
			assertEqual(itemWorld.items[1].itemType, "banana", "gift-box swapped to banana")
			assertEqual(itemWorld.items[2].itemType, "item", "banana swapped to gift-box")
			assertEqual(itemWorld.items[3].itemType, "bubblegum", "big-nitro swapped to bubblegum")

			for _ = 1, 600 do
				ItemWorld.tick(itemWorld)
			end
			assertEqual(itemWorld.switchTicks, 0, "tick 600 reaches 0")
			ItemWorld.tick(itemWorld)
			assertEqual(itemWorld.switchTicks, -1, "tick 601 expires switch")
			assertEqual(itemWorld.items[1].itemType, "item", "gift-box restored")
			assertEqual(itemWorld.items[2].itemType, "banana", "banana restored")
			assertEqual(itemWorld.items[3].itemType, "big-nitro", "big-nitro restored")
		end,
	},
	{
		name = "Mid-explosion & mid-switch state survives captureNetState/GreyboxProtocol/applyNetState + replay identically",
		fn = function()
			local world = makeFlatPlaneWorld(0.0)
			local profile = KartTuning.buildProfile("medium", "best")
			local srvItems = ItemWorld.createEmpty("NORMAL_RACE")
			ItemWorld.addTrackItem(srvItems, 1, "item", { x = 0, y = 0.2, z = 30 })
			ItemWorld.addTrackItem(srvItems, 2, "banana", { x = 0, y = 0.2, z = 5 })

			local cliItems = ItemWorld.createEmpty("NORMAL_RACE")
			ItemWorld.addTrackItem(cliItems, 1, "item", { x = 0, y = 0.2, z = 30 })
			ItemWorld.addTrackItem(cliItems, 2, "banana", { x = 0, y = 0.2, z = 5 })

			local srv = KartSolver.createState(profile, { x = 0, y = 0.291, z = 0 }, 0)
			local cli = KartSolver.createState(profile, { x = 0, y = 0.291, z = 0 }, 0)
			srv.linVel = { x = 0, y = 0, z = 20.0 }
			srv.speed = 20.0
			cli.linVel = { x = 0, y = 0, z = 20.0 }
			cli.speed = 20.0
			srv.attachmentType = ItemTuning.ATTACHMENT_BOMB
			srv.attachmentTicksLeft = 5
			cli.attachmentType = ItemTuning.ATTACHMENT_BOMB
			cli.attachmentTicksLeft = 5
			KartSolver.setPowerup(srv, ItemTuning.POWERUP_SWITCH, 1)
			KartSolver.setPowerup(cli, ItemTuning.POWERUP_SWITCH, 1)

			-- Fire SWITCH at tick 1, bomb timer expires/detonates at tick 5, snapshot at tick 40 mid-explosion, replay to tick 210
			local history: { { seq: number, input: KartSolver.KartInput } } = {}
			local ackPayload: buffer? = nil
			local ackNotice: string? = nil
			for tick = 1, 210 do
				local inp: KartSolver.KartInput = {
					accel = 1.0,
					brake = false,
					steer = 0.5,
					drift = false,
					fire = (tick == 1),
				}
				table.insert(history, { seq = tick, input = inp })
				KartSolver.stepWithItems(srv, inp, world, FixedStep.FIXED_DT, srvItems, { isServer = true, kartId = 5 })
				KartSolver.stepWithItems(
					cli,
					inp,
					world,
					FixedStep.FIXED_DT,
					cliItems,
					{ isServer = false, kartId = 5 }
				)
				if tick == 40 then
					ackPayload, ackNotice =
						GreyboxProtocol.packSnapshot(40, 40, 1, KartSolver.captureNetState(srv, srvItems), "")
				end
			end

			local pkt = GreyboxProtocol.unpackSnapshot(ackPayload, ackNotice)
			assert(pkt ~= nil, "mid-explosion snapshot unpacked")
			KartSolver.applyNetState(cli, (pkt :: GreyboxProtocol.TelemetryPacket).netState, cliItems)
			for _, entry in history do
				if entry.seq > 40 then
					KartSolver.stepWithItems(
						cli,
						entry.input,
						world,
						FixedStep.FIXED_DT,
						cliItems,
						{ isServer = false, kartId = 5 }
					)
				end
			end

			assertNear(cli.pos.x, srv.pos.x, 1e-6, "reconciled pos.x after explosion")
			assertNear(cli.pos.y, srv.pos.y, 1e-6, "reconciled pos.y after explosion")
			assertNear(cli.pos.z, srv.pos.z, 1e-6, "reconciled pos.z after explosion")
			assertNear(cli.speed, srv.speed, 1e-6, "reconciled speed after explosion")
			assertEqual(cli.itemEffect.effectType, srv.itemEffect.effectType, "reconciled effectType")
			assertEqual(
				cli.itemEffect.invulnerableTicks,
				srv.itemEffect.invulnerableTicks,
				"reconciled invulnerableTicks"
			)
			assertEqual(cliItems.switchTicks, srvItems.switchTicks, "reconciled switchTicks")
			assertEqual(cliItems.items[1].itemType, srvItems.items[1].itemType, "reconciled switched itemType")
		end,
	},
}
