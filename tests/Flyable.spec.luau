--!strict
-- tests/Flyable.spec.luau
-- SPDX-License-Identifier: GPL-3.0-or-later

local FixedStep = require("../src/shared/sim/FixedStep")
local Flyable = require("../src/shared/sim/Flyable")
local GreyboxArenaData = require("../src/shared/track/GreyboxArenaData")
local GreyboxProtocol = require("../src/shared/net/GreyboxProtocol")
local ItemEffectState = require("../src/shared/sim/ItemEffectState")
local ItemTuning = require("../src/shared/ItemTuning")
local ItemWorld = require("../src/shared/items/ItemWorld")
local KartSolver = require("../src/shared/sim/KartSolver")
local KartTuning = require("../src/shared/KartTuning")
local Math3D = require("../src/shared/sim/Math3D")
local PowerupManager = require("../src/shared/items/PowerupManager")
local Standings = require("../src/shared/race/Standings")
local TestDummyKart = require("../src/shared/race/TestDummyKart")

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

local function makeFlatPlaneWorld(groundY: number, wallXPos: number?): WorldQuery
	return {
		raycast = function(origin: Vec3, dir: Vec3, length: number): KartSolver.RayHit?
			local bestT = length + 1.0
			local bestHit: KartSolver.RayHit? = nil
			if math.abs(dir.y) > 1e-9 then
				local t = (groundY - origin.y) / dir.y
				if t >= 0 and t <= length and t < bestT then
					bestT = t
					bestHit = {
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
			end
			if wallXPos ~= nil and math.abs(dir.x) > 1e-9 then
				local tW = (wallXPos - origin.x) / dir.x
				if tW >= 0 and tW <= length and tW < bestT then
					bestT = tW
					bestHit = {
						distance = tW,
						point = {
							x = wallXPos,
							y = origin.y + dir.y * tW,
							z = origin.z + dir.z * tW,
						},
						normal = { x = if dir.x > 0 then -1 else 1, y = 0, z = 0 },
						materialName = "road.jpg",
					}
				end
			end
			return bestHit
		end,
	}
end

return {
	{
		name = "IMPLEMENTED_POWERUPS gate enables 9 items & 2-kart Rank-2 10000-roll pool includes all 5 new items",
		fn = function()
			local allowedCount = 0
			for _, v in pairs(ItemTuning.IMPLEMENTED_POWERUPS) do
				if v then
					allowedCount += 1
				end
			end
			assertEqual(allowedCount, 9, "9 powerups enabled in IMPLEMENTED_POWERUPS")
			assert(ItemTuning.IMPLEMENTED_POWERUPS[ItemTuning.POWERUP_CAKE], "CAKE enabled")
			assert(ItemTuning.IMPLEMENTED_POWERUPS[ItemTuning.POWERUP_BOWLING], "BOWLING enabled")
			assert(ItemTuning.IMPLEMENTED_POWERUPS[ItemTuning.POWERUP_PLUNGER], "PLUNGER enabled")
			assert(ItemTuning.IMPLEMENTED_POWERUPS[ItemTuning.POWERUP_RUBBERBALL], "RUBBERBALL enabled")
			assert(ItemTuning.IMPLEMENTED_POWERUPS[ItemTuning.POWERUP_PARACHUTE], "PARACHUTE enabled")

			local mgr2 = PowerupManager.new("NORMAL_RACE", 2, ItemTuning.IMPLEMENTED_POWERUPS)
			local weights2 = mgr2:getRankWeights(2)
			local counts = table.create(ItemTuning.POWERUP_LAST, 0)
			math.randomseed(1337)
			local nRolls = 10000
			for _ = 1, nRolls do
				local pid = mgr2:getRandomPowerup(2, math.random(0, 2147483646), 25.0)
				counts[pid] += 1
			end
			for _, pid in ipairs({
				ItemTuning.POWERUP_BUBBLEGUM,
				ItemTuning.POWERUP_CAKE,
				ItemTuning.POWERUP_BOWLING,
				ItemTuning.POWERUP_ZIPPER,
				ItemTuning.POWERUP_PLUNGER,
				ItemTuning.POWERUP_SWITCH,
				ItemTuning.POWERUP_SWATTER,
				ItemTuning.POWERUP_RUBBERBALL,
				ItemTuning.POWERUP_PARACHUTE,
			}) do
				local expFrac = (weights2.single[pid] + weights2.multi[pid]) / weights2.total
				assert(expFrac > 0, "rank-2 weight > 0 for " .. ItemTuning.POWERUP_NAMES[pid])
				assertNear(
					counts[pid] / nRolls,
					expFrac,
					0.015,
					"2-kart rank-2 roll frac " .. ItemTuning.POWERUP_NAMES[pid]
				)
			end
		end,
	},
	{
		name = "TestDummyKart appears ahead in Standings and flips rank when player overtakes",
		fn = function()
			local profile = KartTuning.buildProfile("medium", "best")
			local player = KartSolver.createState(profile, { x = 0, y = 0.291, z = 0 }, 0)
			local dummy = TestDummyKart.create(profile)
			local dummyAI = TestDummyKart.createAIState(dummy)

			local entries1 = TestDummyKart.buildStandingsEntries({
				{ id = TestDummyKart.DUMMY_STRING_ID, state = dummy, initialPosition = 1, aiState = dummyAI },
				{ id = "player", state = player, initialPosition = 2 },
			})
			assertEqual((Standings.getRankForId(entries1, TestDummyKart.DUMMY_STRING_ID)), 1, "dummy starts Rank 1")
			assertEqual((Standings.getRankForId(entries1, "player")), 2, "player starts Rank 2")

			-- Overtake along the North straight (x = 0 -> +60 at z = 6.0)
			player.pos = { x = 36.0, y = 0.291, z = 6.0 }
			local entries2 = TestDummyKart.buildStandingsEntries({
				{ id = TestDummyKart.DUMMY_STRING_ID, state = dummy, initialPosition = 1, aiState = dummyAI },
				{ id = "player", state = player, initialPosition = 2 },
			})
			assertEqual((Standings.getRankForId(entries2, "player")), 1, "player becomes Rank 1 after overtake")
			assertEqual((Standings.getRankForId(entries2, TestDummyKart.DUMMY_STRING_ID)), 2, "dummy becomes Rank 2")
		end,
	},
	{
		name = "POWERUP_PARACHUTE targets ahead kart via Standings, routes 5x drag through ItemEffectState, & pops shield",
		fn = function()
			local world = makeFlatPlaneWorld(0.0)
			local profile = KartTuning.buildProfile("medium", "best")
			local itemWorld = ItemWorld.createEmpty("NORMAL_RACE")

			local attacker = KartSolver.createState(profile, { x = 0, y = 0.291, z = 0 }, 0)
			local leader = TestDummyKart.create(profile, 32.0)
			leader.speed = 15.0
			leader.linVel = { x = 0, y = 0, z = 15.0 }

			-- Shielded leader absorbs parachute and keeps no drag
			leader.attachmentType = ItemTuning.ATTACHMENT_BUBBLEGUM_SHIELD
			leader.attachmentTicksLeft = 600
			KartSolver.setPowerup(attacker, ItemTuning.POWERUP_PARACHUTE, 1)
			local proxiesShield = {
				KartSolver.makeFlyableProxy(TestDummyKart.DUMMY_KART_ID, leader, 1, "best"),
				KartSolver.makeFlyableProxy(1, attacker, 2, "best"),
			}
			KartSolver.stepWithItems(
				attacker,
				{ accel = 0, brake = false, steer = 0, drift = false, fire = true },
				world,
				FixedStep.FIXED_DT,
				itemWorld,
				{
					isServer = true,
					kartId = 1,
					rank = 2,
					allKartProxies = proxiesShield,
				}
			)
			assertEqual(KartSolver.isShielded(leader), false, "parachute popped leader shield")
			assertEqual(ItemEffectState.getAirDragMultiplier(leader.itemEffect), 1.0, "shield blocked parachute drag")

			-- Release fire, then fire fresh parachute against unshielded leader at 15 m/s
			leader.attachmentType = ItemTuning.ATTACHMENT_NONE
			leader.attachmentTicksLeft = 0
			KartSolver.stepWithItems(
				attacker,
				{ accel = 0, brake = false, steer = 0, drift = false, fire = false },
				world,
				FixedStep.FIXED_DT,
				itemWorld,
				{ isServer = true, kartId = 1 }
			)
			KartSolver.setPowerup(attacker, ItemTuning.POWERUP_PARACHUTE, 1)
			local proxiesOpen = {
				KartSolver.makeFlyableProxy(TestDummyKart.DUMMY_KART_ID, leader, 1, "best"),
				KartSolver.makeFlyableProxy(1, attacker, 2, "best"),
			}
			KartSolver.stepWithItems(
				attacker,
				{ accel = 0, brake = false, steer = 0, drift = false, fire = true },
				world,
				FixedStep.FIXED_DT,
				itemWorld,
				{
					isServer = true,
					kartId = 1,
					rank = 2,
					allKartProxies = proxiesOpen,
				}
			)
			assertEqual(leader.attachmentType, ItemTuning.ATTACHMENT_PARACHUTE, "parachute attached to leader")
			-- 2.5s * 1.5 rank_mult * (1 + (15/30)*(1.35-1)) = 4.40625s -> math.floor(450 * 1.175) = 528 ticks
			assertEqual(leader.attachmentTicksLeft, 528, "rank+speed scaled duration = 528 ticks")
			assertNear(
				ItemEffectState.getAirDragMultiplier(leader.itemEffect),
				5.0,
				1e-6,
				"ItemEffectState carries 5x parachute drag"
			)

			-- Drag noticeably slows leader even under throttle; early speed-loss detaches cleanly
			local vBefore = leader.speed
			for _ = 1, 60 do
				KartSolver.stepWithItems(
					leader,
					{ accel = 0, brake = true, steer = 0, drift = false },
					world,
					FixedStep.FIXED_DT,
					itemWorld,
					{
						isServer = true,
						kartId = TestDummyKart.DUMMY_KART_ID,
						advanceItemWorld = false,
					}
				)
			end
			assert(leader.speed < vBefore, "parachute + brake slows speed")
			assertEqual(
				leader.attachmentType,
				ItemTuning.ATTACHMENT_NONE,
				"braking below threshold detaches parachute early"
			)
			assertEqual(ItemEffectState.getAirDragMultiplier(leader.itemEffect), 1.0, "drag cleared after detach")
		end,
	},
	{
		name = "POWERUP_CAKE aims ballistic lead shot in forward cone and explodes target (180t stop)",
		fn = function()
			local world = makeFlatPlaneWorld(0.0)
			local profile = KartTuning.buildProfile("medium", "best")
			local itemWorld = ItemWorld.createEmpty("NORMAL_RACE")
			local flyWorld = Flyable.createWorld()

			local attacker = KartSolver.createState(profile, { x = 0, y = 0.291, z = 0 }, 0)
			attacker.speed = 20.0
			attacker.linVel = { x = 0, y = 0, z = 20.0 }
			local dummy = TestDummyKart.create(profile, 22.0)
			dummy.speed = 10.0
			dummy.linVel = { x = 0, y = 0, z = 10.0 }

			KartSolver.setPowerup(attacker, ItemTuning.POWERUP_CAKE, 1)
			local preProxies = {
				KartSolver.makeFlyableProxy(TestDummyKart.DUMMY_KART_ID, dummy, 1, "best"),
				KartSolver.makeFlyableProxy(1, attacker, 2, "best"),
			}
			KartSolver.stepWithItems(
				attacker,
				{ accel = 1, brake = false, steer = 0, drift = false, fire = true },
				world,
				FixedStep.FIXED_DT,
				itemWorld,
				{
					isServer = true,
					kartId = 1,
					rank = 2,
					flyableWorld = flyWorld,
					allKartProxies = preProxies,
				}
			)
			assertEqual(#flyWorld.entries, 1, "cake projectile spawned")
			assertEqual(flyWorld.entries[1].kind, "cake", "kind is cake")
			assertEqual(flyWorld.entries[1].targetKartId, TestDummyKart.DUMMY_KART_ID, "cake aimed at cone target")

			local hit = false
			for t = 1, 180 do
				local proxies = {
					KartSolver.makeFlyableProxy(TestDummyKart.DUMMY_KART_ID, dummy, 1, "best"),
					KartSolver.makeFlyableProxy(1, attacker, 2, "best"),
				}
				KartSolver.stepWithItems(
					dummy,
					{ accel = 0.65, brake = false, steer = 0, drift = false },
					world,
					FixedStep.FIXED_DT,
					itemWorld,
					{ isServer = true, kartId = TestDummyKart.DUMMY_KART_ID, advanceItemWorld = false }
				)
				KartSolver.stepWithItems(
					attacker,
					{ accel = 0.5, brake = false, steer = 0, drift = false },
					world,
					FixedStep.FIXED_DT,
					itemWorld,
					{ isServer = true, kartId = 1, advanceItemWorld = false }
				)
				Flyable.step(flyWorld, proxies, world, FixedStep.FIXED_DT, GreyboxArenaData.drivelineQuadCenters, t)
				if dummy.itemEffect.effectType == ItemEffectState.EFFECT_EXPLOSION then
					hit = true
					break
				end
			end
			assert(hit, "cake converged and exploded dummy kart")
			assertNear(dummy.speed, 0.0, 1e-6, "cake explosion zeroed dummy forward speed")
			assertEqual(KartSolver.isDriverInputSuppressed(dummy), true, "cake explosion suppressed dummy input")
		end,
	},
	{
		name = "POWERUP_BOWLING rolls straight, bounces off wall (e=0.4), & triggers direct-only explosion",
		fn = function()
			-- Vertical wall at x = 6.0; fire bowling rightward (yaw = pi/2 -> +X) and check bounce
			local worldWall = makeFlatPlaneWorld(0.0, 6.0)
			local profile = KartTuning.buildProfile("medium", "best")
			local itemWorld = ItemWorld.createEmpty("NORMAL_RACE")
			local flyWorld = Flyable.createWorld()

			local shooter = KartSolver.createState(profile, { x = 2.0, y = 0.291, z = 0 }, math.pi * 0.5)
			local p0 = KartSolver.makeFlyableProxy(1, shooter, 1, "best")
			local bowl = Flyable.spawnBowling(flyWorld, p0, false)
			assertEqual(bowl.kind, "bowling", "spawned bowling ball")
			assertEqual(bowl.maxLifespanTicks, 2400, "bowling lifespan = 20s (2400t)")
			assert(bowl.vel.x > 30.0, "bowling launches along shooter forward (+X)")

			local bounced = false
			for t = 1, 60 do
				Flyable.step(flyWorld, { p0 }, worldWall, FixedStep.FIXED_DT, GreyboxArenaData.drivelineQuadCenters, t)
				if flyWorld.entries[1] and flyWorld.entries[1].vel.x < 0 then
					bounced = true
					break
				end
			end
			assert(bounced, "bowling ball rebounded off wall")

			-- Direct hit explodes target, does NOT splash bystander 3m away
			local flatWorld = makeFlatPlaneWorld(0.0)
			local fw2 = Flyable.createWorld()
			local owner = KartSolver.createState(profile, { x = 0, y = 0.291, z = 0 }, 0)
			local target = TestDummyKart.create(profile, 8.0)
			local bystander = KartSolver.createState(profile, { x = 3.0, y = 0.291, z = 8.0 }, 0)
			KartSolver.setPowerup(owner, ItemTuning.POWERUP_BOWLING, 1)
			local pList = {
				KartSolver.makeFlyableProxy(TestDummyKart.DUMMY_KART_ID, target, 1, "best"),
				KartSolver.makeFlyableProxy(2, bystander, 2, "best"),
				KartSolver.makeFlyableProxy(1, owner, 3, "best"),
			}
			KartSolver.stepWithItems(
				owner,
				{ accel = 1, brake = false, steer = 0, drift = false, fire = true },
				flatWorld,
				FixedStep.FIXED_DT,
				itemWorld,
				{
					isServer = true,
					kartId = 1,
					rank = 3,
					flyableWorld = fw2,
					allKartProxies = pList,
				}
			)
			for t = 1, 60 do
				local stepProxies = {
					KartSolver.makeFlyableProxy(TestDummyKart.DUMMY_KART_ID, target, 1, "best"),
					KartSolver.makeFlyableProxy(2, bystander, 2, "best"),
					KartSolver.makeFlyableProxy(1, owner, 3, "best"),
				}
				Flyable.step(fw2, stepProxies, flatWorld, FixedStep.FIXED_DT, GreyboxArenaData.drivelineQuadCenters, t)
				if target.itemEffect.effectType == ItemEffectState.EFFECT_EXPLOSION then
					break
				end
			end
			assertEqual(target.itemEffect.effectType, ItemEffectState.EFFECT_EXPLOSION, "bowling hit exploded target")
			assertEqual(
				bystander.itemEffect.effectType,
				ItemEffectState.EFFECT_NONE,
				"bowling does NOT splash bystander"
			)
		end,
	},
	{
		name = "POWERUP_PLUNGER forward pulls via RubberBand (120t) and backward triggers 540t plunger-face obstruction",
		fn = function()
			local world = makeFlatPlaneWorld(0.0)
			local profile = KartTuning.buildProfile("medium", "best")
			local itemWorld = ItemWorld.createEmpty("NORMAL_RACE")
			local flyWorld = Flyable.createWorld()

			local owner = KartSolver.createState(profile, { x = 0, y = 0.291, z = 0 }, 0)
			local dummy = TestDummyKart.create(profile, 14.0)
			KartSolver.setPowerup(owner, ItemTuning.POWERUP_PLUNGER, 1)

			local preProxies = {
				KartSolver.makeFlyableProxy(TestDummyKart.DUMMY_KART_ID, dummy, 1, "best"),
				KartSolver.makeFlyableProxy(1, owner, 2, "best"),
			}
			KartSolver.stepWithItems(
				owner,
				{ accel = 0, brake = false, steer = 0, drift = false, fire = true, lookBack = false },
				world,
				FixedStep.FIXED_DT,
				itemWorld,
				{
					isServer = true,
					kartId = 1,
					rank = 2,
					flyableWorld = flyWorld,
					allKartProxies = preProxies,
				}
			)
			assertEqual(#flyWorld.entries, 1, "plunger spawned")

			for t = 1, 40 do
				local stepProxies = {
					KartSolver.makeFlyableProxy(TestDummyKart.DUMMY_KART_ID, dummy, 1, "best"),
					KartSolver.makeFlyableProxy(1, owner, 2, "best"),
				}
				KartSolver.stepWithItems(
					owner,
					{ accel = 0, brake = false, steer = 0, drift = false },
					world,
					FixedStep.FIXED_DT,
					itemWorld,
					{ isServer = true, kartId = 1, advanceItemWorld = false }
				)
				KartSolver.stepWithItems(
					dummy,
					{ accel = 0, brake = false, steer = 0, drift = false },
					world,
					FixedStep.FIXED_DT,
					itemWorld,
					{ isServer = true, kartId = TestDummyKart.DUMMY_KART_ID, advanceItemWorld = false }
				)
				Flyable.step(flyWorld, stepProxies, world, FixedStep.FIXED_DT, GreyboxArenaData.drivelineQuadCenters, t)
			end
			assert(
				flyWorld.entries[1] ~= nil and flyWorld.entries[1].bandState == 2,
				"forward plunger attached rubber band to dummy"
			)
			assert(
				owner.maxSpeedState.increases["RUBBER"] ~= nil,
				"rubber band grants RUBBER MaxSpeed increase to owner"
			)

			-- Backward plunger attaches plunger-in-face for 540 ticks (4.5s on best)
			local flyBack = Flyable.createWorld()
			local chaser = KartSolver.createState(profile, { x = 0, y = 0.291, z = -10.0 }, 0)
			local frontKart = KartSolver.createState(profile, { x = 0, y = 0.291, z = 0 }, 0)
			KartSolver.setPowerup(frontKart, ItemTuning.POWERUP_PLUNGER, 1)
			local backPre = {
				KartSolver.makeFlyableProxy(1, frontKart, 1, "best"),
				KartSolver.makeFlyableProxy(2, chaser, 2, "best"),
			}
			KartSolver.stepWithItems(
				frontKart,
				{ accel = 0, brake = false, steer = 0, drift = false, fire = true, lookBack = true },
				world,
				FixedStep.FIXED_DT,
				itemWorld,
				{
					isServer = true,
					kartId = 1,
					rank = 1,
					flyableWorld = flyBack,
					allKartProxies = backPre,
				}
			)
			for t = 1, 30 do
				local stepProxies = {
					KartSolver.makeFlyableProxy(1, frontKart, 1, "best"),
					KartSolver.makeFlyableProxy(2, chaser, 2, "best"),
				}
				Flyable.step(flyBack, stepProxies, world, FixedStep.FIXED_DT, GreyboxArenaData.drivelineQuadCenters, t)
				if chaser.itemEffect.plungerFaceTicks > 0 then
					break
				end
			end
			assertEqual(chaser.itemEffect.plungerFaceTicks, 540, "backward plunger blocks view for 540 ticks (4.5s)")
			assertEqual(
				KartSolver.applyPlungerFaceHit(chaser, "best"),
				false,
				"plunger face does not re-trigger while active"
			)
		end,
	},
	{
		name = "POWERUP_RUBBERBALL follows drivelineQuadCenters, squashes mid kart, & explodes Rank-1 target",
		fn = function()
			local world = makeFlatPlaneWorld(0.0)
			local profile = KartTuning.buildProfile("medium", "best")
			local itemWorld = ItemWorld.createEmpty("NORMAL_RACE")
			local flyWorld = Flyable.createWorld()

			-- North straight of closed loop: z = 6.0, heading +X (yaw = pi/2)
			local yawEast = math.pi * 0.5
			local attacker = KartSolver.createState(profile, { x = -52.0, y = 0.291, z = 6.0 }, yawEast)
			local midKart = KartSolver.createState(profile, { x = -12.0, y = 0.291, z = 6.0 }, yawEast)
			local rank1 = KartSolver.createState(profile, { x = 60.0, y = 0.291, z = 6.0 }, yawEast)
			local rank1AI = TestDummyKart.createAIState(rank1)
			KartSolver.setPowerup(attacker, ItemTuning.POWERUP_RUBBERBALL, 1)

			local preProxies = {
				KartSolver.makeFlyableProxy(TestDummyKart.DUMMY_KART_ID, rank1, 1, "best"),
				KartSolver.makeFlyableProxy(2, midKart, 2, "best"),
				KartSolver.makeFlyableProxy(1, attacker, 3, "best"),
			}
			KartSolver.stepWithItems(
				attacker,
				{ accel = 1, brake = false, steer = 0, drift = false, fire = true },
				world,
				FixedStep.FIXED_DT,
				itemWorld,
				{
					isServer = true,
					kartId = 1,
					rank = 3,
					flyableWorld = flyWorld,
					allKartProxies = preProxies,
					drivelineCenters = GreyboxArenaData.drivelineQuadCenters,
				}
			)
			assertEqual(#flyWorld.entries, 1, "rubber ball spawned")
			local rb = flyWorld.entries[1]
			assertEqual(rb.kind, "rubber_ball", "kind is rubber_ball")
			assertEqual(rb.targetKartId, TestDummyKart.DUMMY_KART_ID, "selected Rank-1 dummy via Standings")

			local initialIdx = rb.drivelineIdx
			local advancedDriveline = false
			local hitRank1 = false
			for t = 1, 1200 do
				local stepProxies = {
					KartSolver.makeFlyableProxy(TestDummyKart.DUMMY_KART_ID, rank1, 1, "best"),
					KartSolver.makeFlyableProxy(2, midKart, 2, "best"),
					KartSolver.makeFlyableProxy(1, attacker, 3, "best"),
				}
				KartSolver.stepWithItems(
					rank1,
					TestDummyKart.computeCruiseInput(rank1, rank1AI, FixedStep.FIXED_DT, 10.0),
					world,
					FixedStep.FIXED_DT,
					itemWorld,
					{ isServer = true, kartId = TestDummyKart.DUMMY_KART_ID, advanceItemWorld = false }
				)
				Flyable.step(flyWorld, stepProxies, world, FixedStep.FIXED_DT, GreyboxArenaData.drivelineQuadCenters, t)
				if flyWorld.entries[1] and flyWorld.entries[1].drivelineIdx ~= initialIdx then
					advancedDriveline = true
				end
				if rank1.itemEffect.effectType == ItemEffectState.EFFECT_EXPLOSION then
					hitRank1 = true
					break
				end
			end
			assert(advancedDriveline, "rubber ball advanced along drivelineQuadCenters")
			assertEqual(
				midKart.itemEffect.effectType,
				ItemEffectState.EFFECT_SQUASH,
				"rubber ball squashed intermediate kart en route"
			)
			assert(hitRank1, "rubber ball reached and exploded Rank-1 target")
		end,
	},
	{
		name = "Flyable state survives captureNetState/GreyboxProtocol/applyNetState + replay identically",
		fn = function()
			local world = makeFlatPlaneWorld(0.0)
			local profile = KartTuning.buildProfile("medium", "best")
			local srvItems = ItemWorld.createEmpty("NORMAL_RACE")
			local cliItems = ItemWorld.createEmpty("NORMAL_RACE")
			local srvFly = Flyable.createWorld()
			local cliFly = Flyable.createWorld()

			local srv = KartSolver.createState(profile, { x = 0, y = 0.291, z = 0 }, 0)
			local cli = KartSolver.createState(profile, { x = 0, y = 0.291, z = 0 }, 0)
			local srvTarget = TestDummyKart.create(profile, 22.0)
			local cliTarget = TestDummyKart.create(profile, 22.0)

			KartSolver.setPowerup(srv, ItemTuning.POWERUP_BOWLING, 1)
			KartSolver.setPowerup(cli, ItemTuning.POWERUP_BOWLING, 1)

			local history: { { seq: number, input: KartSolver.KartInput } } = {}
			local ackPayload: buffer? = nil
			local ackNotice: string? = nil

			for tick = 1, 80 do
				local inp: KartSolver.KartInput =
					{ accel = 1.0, brake = false, steer = 0.0, drift = false, fire = (tick == 1) }
				table.insert(history, { seq = tick, input = inp })

				local srvP = {
					KartSolver.makeFlyableProxy(TestDummyKart.DUMMY_KART_ID, srvTarget, 1, "best"),
					KartSolver.makeFlyableProxy(1, srv, 2, "best"),
				}
				KartSolver.stepWithItems(srv, inp, world, FixedStep.FIXED_DT, srvItems, {
					isServer = true,
					kartId = 1,
					rank = 2,
					flyableWorld = srvFly,
					allKartProxies = srvP,
				})
				Flyable.step(srvFly, srvP, world, FixedStep.FIXED_DT, GreyboxArenaData.drivelineQuadCenters, tick)

				local cliP = {
					KartSolver.makeFlyableProxy(TestDummyKart.DUMMY_KART_ID, cliTarget, 1, "best"),
					KartSolver.makeFlyableProxy(1, cli, 2, "best"),
				}
				KartSolver.stepWithItems(cli, inp, world, FixedStep.FIXED_DT, cliItems, {
					isServer = false,
					kartId = 1,
					rank = 2,
					flyableWorld = cliFly,
					allKartProxies = cliP,
				})
				Flyable.step(cliFly, cliP, world, FixedStep.FIXED_DT, GreyboxArenaData.drivelineQuadCenters, tick)

				if tick == 10 then
					local remoteSample: { GreyboxProtocol.RemoteKartState } = {
						{
							id = TestDummyKart.DUMMY_STRING_ID,
							pos = { srvTarget.pos.x, srvTarget.pos.y, srvTarget.pos.z },
							rot = { srvTarget.rot.w, srvTarget.rot.x, srvTarget.rot.y, srvTarget.rot.z },
							speed = srvTarget.speed,
							steer = srvTarget.steer,
							attachmentType = srvTarget.attachmentType,
							plungerFaceTicks = srvTarget.itemEffect.plungerFaceTicks,
							isSquashed = false,
							rank = 1,
						},
					}
					ackPayload, ackNotice = GreyboxProtocol.packSnapshot(
						10,
						10,
						1,
						KartSolver.captureNetState(srv, srvItems, srvFly),
						"",
						remoteSample
					)
				end
			end

			assert(ackPayload ~= nil, "mid-flight flyable buffer packed")
			assert(
				buffer.len(ackPayload :: buffer) < 850,
				string.format(
					"binary snapshot fits UnreliableRemoteEvent MTU (got %d B)",
					buffer.len(ackPayload :: buffer)
				)
			)
			local pkt = GreyboxProtocol.unpackSnapshot(ackPayload, ackNotice)
			assert(pkt ~= nil and pkt.netState.flyableSnapshot ~= nil, "mid-flight flyable snapshot unpacked")
			assert(
				pkt.remoteKarts ~= nil and #pkt.remoteKarts == 1 and pkt.remoteKarts[1].id == "Dummy_1",
				"remoteKarts round-trips in binary buffer"
			)
			KartSolver.applyNetState(cli, (pkt :: GreyboxProtocol.TelemetryPacket).netState, cliItems, cliFly)
			cliTarget = TestDummyKart.create(profile, 22.0)

			for _, entry in history do
				if entry.seq > 10 then
					local cliP = {
						KartSolver.makeFlyableProxy(TestDummyKart.DUMMY_KART_ID, cliTarget, 1, "best"),
						KartSolver.makeFlyableProxy(1, cli, 2, "best"),
					}
					KartSolver.stepWithItems(cli, entry.input, world, FixedStep.FIXED_DT, cliItems, {
						isServer = false,
						kartId = 1,
						rank = 2,
						flyableWorld = cliFly,
						allKartProxies = cliP,
					})
					Flyable.step(
						cliFly,
						cliP,
						world,
						FixedStep.FIXED_DT,
						GreyboxArenaData.drivelineQuadCenters,
						entry.seq
					)
				end
			end

			assertNear(cli.pos.z, srv.pos.z, 1e-6, "reconciled kart Z")
			assertEqual(#cliFly.entries, #srvFly.entries, "reconciled active flyable count")
			assertEqual(
				cliTarget.itemEffect.effectType,
				srvTarget.itemEffect.effectType,
				"reconciled target hit effect"
			)
			if #srvFly.entries > 0 then
				assertNear(cliFly.entries[1].pos.z, srvFly.entries[1].pos.z, 1e-5, "reconciled projectile Z")
			end
		end,
	},
	{
		name = "Flyable owner immunity (<2.0s), post-2.0s bowling self-hit, secondary splash exclusion, & sandtrack elevation",
		fn = function()
			local profile = KartTuning.buildProfile("medium", "best")
			local flatWorld = makeFlatPlaneWorld(0.0)

			-- 1) Bowling owner immunity < 240 ticks, then self-hit >= 240 ticks
			local fw1 = Flyable.createWorld()
			local owner = KartSolver.createState(profile, { x = 0, y = 0.291, z = 0 }, 0)
			local ownerProxy = KartSolver.makeFlyableProxy(1, owner, 1, "best")
			local bowl = Flyable.spawnBowling(fw1, ownerProxy, false)
			bowl.ticksSinceThrown = 100
			bowl.pos = { x = owner.pos.x, y = owner.pos.y, z = owner.pos.z }
			Flyable.step(fw1, { ownerProxy }, flatWorld, FixedStep.FIXED_DT, GreyboxArenaData.drivelineQuadCenters, 1)
			assertEqual(owner.itemEffect.effectType, ItemEffectState.EFFECT_NONE, "owner immune before 2.0s")
			assertEqual(#fw1.entries, 1, "bowling survives immune owner overlap")

			bowl.ticksSinceThrown = 240
			bowl.pos = { x = owner.pos.x, y = owner.pos.y, z = owner.pos.z }
			Flyable.step(fw1, { ownerProxy }, flatWorld, FixedStep.FIXED_DT, GreyboxArenaData.drivelineQuadCenters, 2)
			assertEqual(
				owner.itemEffect.effectType,
				ItemEffectState.EFFECT_EXPLOSION,
				"bowling explodes owner after 2.0s"
			)
			assertEqual(#fw1.entries, 0, "bowling consumed on post-2.0s self-hit")

			-- 2) Secondary splash excludes owner while hitting nearby bystander
			local fw2 = Flyable.createWorld()
			local cakeOwner = KartSolver.createState(profile, { x = 0, y = 0.291, z = 0 }, 0)
			local bystander = KartSolver.createState(profile, { x = 2.5, y = 0.291, z = 0 }, 0)
			local pCakeOwner = KartSolver.makeFlyableProxy(1, cakeOwner, 1, "best")
			local pBystander = KartSolver.makeFlyableProxy(2, bystander, 2, "best")
			local cake = Flyable.spawnCake(fw2, pCakeOwner, { pCakeOwner, pBystander }, false)
			cake.pos = { x = 1.25, y = 0.1, z = 0 }
			cake.vel = { x = 0, y = -20.0, z = 0 }
			Flyable.step(
				fw2,
				{ pCakeOwner, pBystander },
				flatWorld,
				FixedStep.FIXED_DT,
				GreyboxArenaData.drivelineQuadCenters,
				3
			)
			assertEqual(
				cakeOwner.itemEffect.effectType,
				ItemEffectState.EFFECT_NONE,
				"secondary cake splash excludes owner"
			)
			assertEqual(
				bystander.itemEffect.effectType,
				ItemEffectState.EFFECT_EXPLOSION,
				"secondary cake splash hits bystander"
			)

			-- 3) Sandtrack elevation (y = -140.4 m) not culled by OOB check
			local sandWorld = makeFlatPlaneWorld(-140.7)
			local fw3 = Flyable.createWorld()
			local sOwner = KartSolver.createState(profile, { x = 0, y = -140.4, z = 0 }, 0)
			local psOwner = KartSolver.makeFlyableProxy(1, sOwner, 1, "best")
			Flyable.spawnBowling(fw3, psOwner, false)
			for t = 1, 30 do
				Flyable.step(fw3, { psOwner }, sandWorld, FixedStep.FIXED_DT, nil, t)
			end
			assertEqual(#fw3.entries, 1, "bowling at y=-140.4m survives OOB check")
			assertNear(
				fw3.entries[1].pos.y,
				-140.7 + ItemTuning.bowling.RADIUS,
				0.05,
				"bowling rolls on thin sandtrack road"
			)

			-- 4) Swept 3D OBB hit catches high-speed head-on bowling pass (70 m/s relative)
			local fw4 = Flyable.createWorld()
			local victim = KartSolver.createState(profile, { x = 0, y = 0.291, z = 10.0 }, 0)
			local pVictim = KartSolver.makeFlyableProxy(2, victim, 1, "best")
			local shooter = KartSolver.createState(profile, { x = 0, y = 0.291, z = 0.0 }, 0)
			local pShooter = KartSolver.makeFlyableProxy(1, shooter, 2, "best")
			local fastBall = Flyable.spawnBowling(fw4, pShooter, false)
			fastBall.pos = { x = 0, y = 0.75, z = 8.9 }
			fastBall.vel = { x = 0, y = 0, z = 70.0 }
			Flyable.step(fw4, { pShooter, pVictim }, flatWorld, FixedStep.FIXED_DT, nil, 1)
			assertEqual(
				victim.itemEffect.effectType,
				ItemEffectState.EFFECT_EXPLOSION,
				"swept OBB catches fast pass at hood height"
			)

			-- 5) 4 active bowling balls + active explosion stays well under Roblox 900-byte UnreliableRemoteEvent cap
			local fw5 = Flyable.createWorld()
			local p5 = KartSolver.makeFlyableProxy(1, victim, 1, "best")
			for _ = 1, 4 do
				Flyable.spawnBowling(fw5, p5, false)
			end
			local ns5 = KartSolver.captureNetState(victim, ItemWorld.createEmpty("NORMAL_RACE"), fw5)
			local buf5 = GreyboxProtocol.packSnapshot(100, 50, 0, ns5, "", {
				{
					id = "Dummy_1",
					pos = { 0, 0.29, 10 },
					rot = { 1, 0, 0, 0 },
					linVel = { 0, 0, 15 },
					speed = 15,
					steer = 0,
					attachmentType = 0,
					attachmentTicksLeft = 240,
					plungerFaceTicks = 0,
					timedImpulseTicks = 0,
					isSquashed = false,
					rank = 1,
					lap = 0,
					trackNodeIdx = 1,
					slipstreamTime = 0,
					slipstreamBonusTime = 0,
				},
			}, 1.0)
			assert(
				buffer.len(buf5) < 850,
				string.format("4 bowling balls + explosion snapshot too large: %d bytes", buffer.len(buf5))
			)
			local unpacked5 = GreyboxProtocol.unpackSnapshot(buf5, nil)
			assert(unpacked5 ~= nil, "compact 4-bowling snapshot unpacked")
			if unpacked5 ~= nil then
				assertEqual(
					unpacked5.netState.itemEffect.effectType,
					ItemEffectState.EFFECT_EXPLOSION,
					"explosion preserved in compact snapshot"
				)
				assertEqual(
					unpacked5.netState.flyableSnapshot ~= nil and #unpacked5.netState.flyableSnapshot.entries or 0,
					4,
					"all 4 bowling balls preserved in compact snapshot"
				)
				assertEqual(
					unpacked5.remoteKarts ~= nil and unpacked5.remoteKarts[1].attachmentTicksLeft or 0,
					240,
					"remote kart attachmentTicksLeft preserved in compact snapshot"
				)
			end
		end,
	},
}
