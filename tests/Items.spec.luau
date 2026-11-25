--!strict
-- tests/Items.spec.luau
-- SPDX-License-Identifier: GPL-3.0-or-later

local FixedStep = require("../src/shared/sim/FixedStep")
local GreyboxArenaData = require("../src/shared/track/GreyboxArenaData")
local GreyboxProtocol = require("../src/shared/net/GreyboxProtocol")
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
		name = "PowerupManager gated to IMPLEMENTED_POWERUPS rolls BUBBLEGUM and ZIPPER proportionally",
		fn = function()
			local gated = PowerupManager.new("NORMAL_RACE", 1, ItemTuning.IMPLEMENTED_POWERUPS)
			local weights = gated:getRankWeights(1)
			assertEqual(weights.total, 240, "gated total equals BUBBLEGUM(140) + ZIPPER(100)")
			assertEqual(weights.single[ItemTuning.POWERUP_BUBBLEGUM], 140, "bubblegum weight preserved")
			assertEqual(weights.single[ItemTuning.POWERUP_ZIPPER], 100, "zipper weight preserved")
			assertEqual(weights.single[ItemTuning.POWERUP_BOWLING], 0, "unimplemented bowling zeroed")
			local sawBubble = false
			local sawZipper = false
			for seed = 0, 239 do
				local pid, cnt = gated:getRandomPowerup(1, seed, 0.0)
				assert(
					pid == ItemTuning.POWERUP_BUBBLEGUM or pid == ItemTuning.POWERUP_ZIPPER,
					"gated roll yields only implemented powerups"
				)
				assertEqual(cnt, 1, "gated roll count=1")
				if pid == ItemTuning.POWERUP_BUBBLEGUM then
					sawBubble = true
				elseif pid == ItemTuning.POWERUP_ZIPPER then
					sawZipper = true
				end
			end
			assert(sawBubble and sawZipper, "gated table rolls both bubblegum and zipper")
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
		name = "PA_FIRE drops banana behind kart with 1.5s owner immunity & triggers SQUASH on hit",
		fn = function()
			local world = makeFlatPlaneWorld(0.0)
			local profile = KartTuning.buildProfile("medium", "best")
			local state = KartSolver.createState(profile, { x = 0, y = 0.35, z = 0 }, 0)
			local itemWorld = ItemWorld.createEmpty("NORMAL_RACE")
			KartSolver.setPowerup(state, ItemTuning.POWERUP_BOWLING, 1)

			-- Press PA_FIRE while grounded
			KartSolver.stepWithItems(state, {
				accel = 0,
				brake = false,
				steer = 0,
				drift = false,
				fire = true,
			}, world, FixedStep.FIXED_DT, itemWorld, { isServer = true, kartId = 7 })

			assertEqual(state.heldPowerupCount, 0, "PA_FIRE consumes held powerup")
			assertEqual(state.heldPowerup, ItemTuning.POWERUP_NONE, "powerup cleared at 0 charges")
			assertEqual(#itemWorld.items, 1, "one dropped banana exists")
			local banana = itemWorld.items[1]
			assertEqual(banana.itemType, "banana", "dropped item is banana")
			local expectedZ = -(0.5 * profile.length + ItemTuning.geometry.BANANA_DROP_CLEARANCE)
			assertNear(banana.pos.z, expectedZ, 0.05, "dropped behind rear bumper")
			assertEqual(banana.deactiveTicks, 180, "owner immunity is 180 ticks (1.5s)")

			-- Another kart (kartId=8) immediately hitting the banana gets hit right away
			local otherKart = KartSolver.createState(profile, { x = banana.pos.x, y = 0.35, z = banana.pos.z }, 0)
			local otherHits = KartSolver.stepWithItems(otherKart, {
				accel = 0,
				brake = false,
				steer = 0,
				drift = false,
			}, world, FixedStep.FIXED_DT, itemWorld, { isServer = true, kartId = 8, advanceItemWorld = false })
			assertEqual(#otherHits, 1, "other kart triggers banana without owner immunity")
			assertEqual(#itemWorld.items, 0, "consumed dropped banana disappears")
			assertEqual(otherKart.maxSpeedState.decreases["SQUASH"] ~= nil, true, "SQUASH slowdown active")
			assertNear(otherKart.linVel.y, ItemTuning.banana.KNOCKBACK_UP_VEL, 0.15, "banana upward knockback")
			assertNear(otherKart.timedRotationRate, ItemTuning.banana.KNOCKBACK_YAW_RATE, 1e-6, "banana yaw rate")

			-- Now verify owner immunity blocks hits for 179 ticks then hits on tick 180
			local itemWorld2 = ItemWorld.createEmpty("NORMAL_RACE")
			local dropped = ItemWorld.dropBanana(itemWorld2, { x = 0, y = 0.3, z = 0 }, 7, world)
			assertEqual(dropped.deactiveTicks, 180)
			for _ = 1, 179 do
				ItemWorld.tick(itemWorld2)
				local immuneHits = ItemWorld.checkHits(itemWorld2, { x = 0, y = 0.3, z = 0 }, 7)
				assertEqual(#immuneHits, 0, "owner immune during first 179 ticks")
			end
			ItemWorld.tick(itemWorld2)
			local postImmuneHits = ItemWorld.checkHits(itemWorld2, { x = 0, y = 0.3, z = 0 }, 7)
			assertEqual(#postImmuneHits, 1, "owner vulnerable at tick 180")
		end,
	},
	{
		name = "Deterministic net snapshot & unacknowledged input replay across nitro, box pickup, & banana drop",
		fn = function()
			local world = makeFlatPlaneWorld(0.0)
			local profile = KartTuning.buildProfile("medium", "best")
			local mgr = PowerupManager.new("NORMAL_RACE", 1)

			-- Authoritative server setup with nitro + box + track banana
			local srvItemWorld = ItemWorld.createEmpty("NORMAL_RACE")
			ItemWorld.addTrackItem(srvItemWorld, 1, "small-nitro", { x = 0, y = 0.35, z = 6.0 })
			ItemWorld.addTrackItem(srvItemWorld, 2, "item", { x = 0, y = 0.35, z = 12.0 })
			ItemWorld.addTrackItem(srvItemWorld, 3, "big-nitro", { x = 0, y = 0.35, z = 18.0 })

			-- Client mirrors exact initial arena track items
			local cliItemWorld = ItemWorld.createEmpty("NORMAL_RACE")
			ItemWorld.addTrackItem(cliItemWorld, 1, "small-nitro", { x = 0, y = 0.35, z = 6.0 })
			ItemWorld.addTrackItem(cliItemWorld, 2, "item", { x = 0, y = 0.35, z = 12.0 })
			ItemWorld.addTrackItem(cliItemWorld, 3, "big-nitro", { x = 0, y = 0.35, z = 18.0 })

			local srvState = KartSolver.createState(profile, { x = 0, y = 0.35, z = 0 }, 0)
			local cliState = KartSolver.createState(profile, { x = 0, y = 0.35, z = 0 }, 0)

			local history: { { seq: number, input: KartSolver.KartInput } } = {}
			local ackSeq = 0
			local ackNums: { number } = {}
			local ackIncs: { { number } }? = nil
			local ackNotice: string? = nil
			local ackItems: any = nil

			local totalTicks = 240
			local ackAtTick = 170 -- after nitro #1 and box #2 have been collected on server
			for tick = 1, totalTicks do
				local input: KartSolver.KartInput = {
					accel = 1.0,
					brake = false,
					steer = 0.0,
					drift = false,
					nitro = false,
					fire = (tick == 195), -- unacknowledged PA_FIRE after ackAtTick
				}
				table.insert(history, { seq = tick, input = input })

				KartSolver.stepWithItems(srvState, input, world, FixedStep.FIXED_DT, srvItemWorld, {
					isServer = true,
					kartId = 42,
					rollPowerup = function(_s, ev)
						return mgr:getRandomPowerup(1, ev.id * 101 + 140, tick * FixedStep.FIXED_DT)
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

			-- Verify box #2 rolled BOWLING x1 on server
			assertEqual(srvState.heldPowerup, ItemTuning.POWERUP_NONE, "server spent BOWLING on tick 195 fire")
			assertEqual(srvState.heldPowerupCount, 0, "server count consumed on fire")
			assertNear(srvState.nitro.energy, 4.0, 1e-6, "server collected small (+1) + big (+3) nitro")
			assertEqual(#srvItemWorld.items, 4, "3 track items + 1 dropped banana")

			-- Reconcile client from ackAtTick snapshot and replay ticks 171..240
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

			-- Exact parity between client replay & authoritative server after reconciliation
			assertNear(cliState.pos.x, srvState.pos.x, 1e-6, "reconciled pos.x")
			assertNear(cliState.pos.y, srvState.pos.y, 1e-6, "reconciled pos.y")
			assertNear(cliState.pos.z, srvState.pos.z, 1e-6, "reconciled pos.z")
			assertNear(cliState.nitro.energy, srvState.nitro.energy, 1e-6, "reconciled nitro")
			assertEqual(cliState.heldPowerup, srvState.heldPowerup, "reconciled heldPowerup")
			assertEqual(cliState.heldPowerupCount, srvState.heldPowerupCount, "reconciled heldPowerupCount")
			assertEqual(cliState.fireWasDown, srvState.fireWasDown, "reconciled fireWasDown")
			assertEqual(#cliItemWorld.items, #srvItemWorld.items, "reconciled item count")
			for i = 1, #srvItemWorld.items do
				assertEqual(cliItemWorld.items[i].id, srvItemWorld.items[i].id, "item id match")
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
}
