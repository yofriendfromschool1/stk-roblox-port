--!strict
-- tests/MultiKart.spec.luau
-- SPDX-License-Identifier: GPL-3.0-or-later

local AIController = require("../src/shared/ai/AIController")
local FixedStep = require("../src/shared/sim/FixedStep")
local GreyboxArenaData = require("../src/shared/track/GreyboxArenaData")
local GreyboxProtocol = require("../src/shared/net/GreyboxProtocol")
local ItemEffectState = require("../src/shared/sim/ItemEffectState")
local ItemTuning = require("../src/shared/ItemTuning")
local ItemWorld = require("../src/shared/items/ItemWorld")
local KartSolver = require("../src/shared/sim/KartSolver")
local KartTuning = require("../src/shared/KartTuning")
local Math3D = require("../src/shared/sim/Math3D")
local TestDummyKart = require("../src/shared/race/TestDummyKart")

local function assertEqual(actual: any, expected: any, label: string)
	if actual ~= expected then
		error(string.format("%s: expected %s, got %s", label, tostring(expected), tostring(actual)))
	end
end

local function assertNear(actual: number, expected: number, tol: number, label: string)
	if math.abs(actual - expected) > tol then
		error(string.format("%s: expected %.6f +- %.6f, got %.6f", label, expected, tol, actual))
	end
end

local function makeFlatPlaneWorld(yPlane: number?): KartSolver.WorldQuery
	local planeY = yPlane or 0.0
	return {
		raycast = function(origin: Math3D.Vec3, dir: Math3D.Vec3, length: number): KartSolver.RayHit?
			if math.abs(dir.y) < 1e-6 then
				return nil
			end
			local t = (planeY - origin.y) / dir.y
			if t >= 0 and t <= length then
				return {
					distance = t,
					point = {
						x = origin.x + dir.x * t,
						y = planeY,
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
		name = "Swatter squash on non-local dummy kart expires after exact 600 ticks (5.0s)",
		fn = function()
			local world = makeFlatPlaneWorld(0.0)
			local profile = KartTuning.buildProfile("medium", "best")
			local itemWorld = ItemWorld.createEmpty("NORMAL_RACE")

			local attacker = KartSolver.createState(profile, { x = 0, y = 0.291, z = 0 }, 0)
			attacker.attachmentType = ItemTuning.ATTACHMENT_SWATTER
			attacker.attachmentTicksLeft = 1200

			local dummy = TestDummyKart.create(profile, 2.0)
			local dummyAI = TestDummyKart.createAIState(dummy)

			local hits = KartSolver.checkSwatterHits(attacker, { attacker, dummy }, 0)
			assertEqual(hits, 1, "swatter squashes dummy within 3m")

			local swattedTel = KartSolver.getTelemetry(dummy)
			assertEqual(swattedTel.isSquashed, true, "dummy marked squashed immediately")
			assertEqual(swattedTel.effectType, ItemEffectState.EFFECT_SQUASH, "ItemEffectState EFFECT_SQUASH active")
			assertEqual(
				swattedTel.effectTicksRemaining,
				600,
				"swatter squash duration is exact 600 ticks (5.0s, data/kart_characteristics.xml:L260)"
			)

			for _ = 1, 599 do
				KartSolver.stepWithItems(
					dummy,
					TestDummyKart.computeCruiseInput(dummy, dummyAI, FixedStep.FIXED_DT),
					world,
					FixedStep.FIXED_DT,
					itemWorld,
					{ isServer = true, kartId = TestDummyKart.DUMMY_KART_ID, advanceItemWorld = false }
				)
			end
			local preExpiryTel = KartSolver.getTelemetry(dummy)
			assertEqual(preExpiryTel.isSquashed, true, "still squashed at tick 599")
			assert(preExpiryTel.currentMaxSpeed < profile.maxSpeed * 0.6, "max speed capped to 0.5x while squashed")

			KartSolver.stepWithItems(
				dummy,
				TestDummyKart.computeCruiseInput(dummy, dummyAI, FixedStep.FIXED_DT),
				world,
				FixedStep.FIXED_DT,
				itemWorld,
				{ isServer = true, kartId = TestDummyKart.DUMMY_KART_ID, advanceItemWorld = false }
			)
			local expiredTel = KartSolver.getTelemetry(dummy)
			assertEqual(expiredTel.isSquashed, false, "squash expired on tick 600")
			assertEqual(expiredTel.effectType, ItemEffectState.EFFECT_NONE, "ItemEffectState cleared to NONE")
			assertEqual(expiredTel.effectTicksRemaining, 0, "effect ticks remaining == 0")
			assert(dummy.maxSpeedState.decreases["SQUASH"] == nil, "SQUASH slowdown removed cleanly from MaxSpeed")
			assertNear(expiredTel.currentMaxSpeed, profile.maxSpeed, 1e-4, "full maxSpeed restored after squash")
		end,
	},
	{
		name = "Kart-kart collision exchanges momentum with exact inverse-mass ratio & pair-order determinism",
		fn = function()
			local lightProf = KartTuning.buildProfile("light", "best") -- 210 kg
			local heavyProf = KartTuning.buildProfile("heavy", "best") -- 350 kg
			local mL = lightProf.mass
			local mH = heavyProf.mass

			local kLight = KartSolver.createState(lightProf, { x = 0, y = 0.291, z = 0.0 }, 0)
			local kHeavy = KartSolver.createState(heavyProf, { x = 0, y = 0.291, z = 1.2 }, 0)
			kLight.linVel = { x = 0, y = 0, z = 12.0 }
			kLight.speed = 12.0
			kHeavy.linVel = { x = 0, y = 0, z = -4.0 }
			kHeavy.speed = -4.0

			local pBefore = mL * 12.0 + mH * -4.0

			-- Order-invariance check with id-sorted pairs
			local kLight2 = KartSolver.createState(lightProf, { x = 0, y = 0.291, z = 0.0 }, 0)
			local kHeavy2 = KartSolver.createState(heavyProf, { x = 0, y = 0.291, z = 1.2 }, 0)
			kLight2.linVel = { x = 0, y = 0, z = 12.0 }
			kLight2.speed = 12.0
			kHeavy2.linVel = { x = 0, y = 0, z = -4.0 }
			kHeavy2.speed = -4.0

			local cols1 = KartSolver.resolveKartKartCollisions({
				{ id = 1, state = kLight },
				{ id = 2, state = kHeavy },
			})
			local cols2 = KartSolver.resolveKartKartCollisions({
				{ id = 2, state = kHeavy2 },
				{ id = 1, state = kLight2 },
			})
			assertEqual(cols1, 1, "overlapping karts detected")
			assertEqual(cols2, 1, "reversed order resolves identically")
			assertNear(kLight.pos.z, kLight2.pos.z, 0.0, "bit-identical light pos under reversed array")
			assertNear(kHeavy.linVel.z, kHeavy2.linVel.z, 0.0, "bit-identical heavy vel under reversed array")

			local pAfter = mL * kLight.linVel.z + mH * kHeavy.linVel.z
			assertNear(pAfter, pBefore, 1e-6, "total linear momentum conserved across kart-kart impact")

			local dvLight = math.abs(kLight.linVel.z - 12.0)
			local dvHeavy = math.abs(kHeavy.linVel.z - -4.0)
			assert(dvLight > 1.0 and dvHeavy > 0.5, "both karts receive non-zero velocity change (not a wall stop)")
			assertNear(dvLight / dvHeavy, mH / mL, 1e-5, "delta-v ratio equals inverse mass ratio (mH/mL)")
			assertEqual(kLight.timedImpulseTicks, 12, "timed central push armed on light kart (0.1s)")
			assertEqual(kHeavy.timedImpulseTicks, 12, "timed central push armed on heavy kart (0.1s)")
			assert(kLight.timedImpulsePerSec.z < 0 and kHeavy.timedImpulsePerSec.z > 0, "opposing separation impulses")
			assert(kHeavy.pos.z - kLight.pos.z >= 1.43, "karts separated cleanly along normal")
		end,
	},
	{
		name = "Kart-kart collision state is bit-identical across captureNetState/GreyboxProtocol/applyNetState/replay",
		fn = function()
			local world = makeFlatPlaneWorld(0.0)
			local profile = KartTuning.buildProfile("medium", "best")
			local srvItems = ItemWorld.createEmpty("NORMAL_RACE")
			local cliItems = ItemWorld.createEmpty("NORMAL_RACE")

			local srvA = KartSolver.createState(profile, { x = 0, y = 0.291, z = 0.0 }, 0)
			local srvB = KartSolver.createState(profile, { x = 0, y = 0.291, z = 4.0 }, 0)
			local cliA = KartSolver.createState(profile, { x = 0, y = 0.291, z = 0.0 }, 0)
			local cliB = KartSolver.createState(profile, { x = 0, y = 0.291, z = 4.0 }, 0)

			local history: { { seq: number, inpA: KartSolver.KartInput, inpB: KartSolver.KartInput } } = {}
			local ackPayloadA: buffer? = nil
			local ackPayloadB: buffer? = nil
			local ackNoticeA: string? = nil
			local ackNoticeB: string? = nil

			for tick = 1, 120 do
				local inpA: KartSolver.KartInput = { accel = 1.0, brake = false, steer = 0.0, drift = false }
				local inpB: KartSolver.KartInput = { accel = 0.2, brake = false, steer = 0.0, drift = false }
				table.insert(history, { seq = tick, inpA = inpA, inpB = inpB })

				KartSolver.stepWithItems(
					srvA,
					inpA,
					world,
					FixedStep.FIXED_DT,
					srvItems,
					{ isServer = true, kartId = 1 }
				)
				KartSolver.stepWithItems(
					srvB,
					inpB,
					world,
					FixedStep.FIXED_DT,
					srvItems,
					{ isServer = true, kartId = 2, advanceItemWorld = false }
				)
				KartSolver.resolveKartKartCollisions({
					{ id = 1, state = srvA },
					{ id = 2, state = srvB },
				})

				KartSolver.stepWithItems(
					cliA,
					inpA,
					world,
					FixedStep.FIXED_DT,
					cliItems,
					{ isServer = false, kartId = 1 }
				)
				KartSolver.stepWithItems(
					cliB,
					inpB,
					world,
					FixedStep.FIXED_DT,
					cliItems,
					{ isServer = false, kartId = 2, advanceItemWorld = false }
				)
				KartSolver.resolveKartKartCollisions({
					{ id = 1, state = cliA },
					{ id = 2, state = cliB },
				})

				if tick == 45 then
					ackPayloadA, ackNoticeA =
						GreyboxProtocol.packSnapshot(45, 45, 1, KartSolver.captureNetState(srvA, srvItems), "")
					ackPayloadB, ackNoticeB =
						GreyboxProtocol.packSnapshot(45, 45, 1, KartSolver.captureNetState(srvB), "")
				end
			end

			local pktA = GreyboxProtocol.unpackSnapshot(ackPayloadA, ackNoticeA)
			local pktB = GreyboxProtocol.unpackSnapshot(ackPayloadB, ackNoticeB)
			assert(pktA ~= nil and pktB ~= nil, "collision snapshots unpacked")
			KartSolver.applyNetState(cliA, (pktA :: GreyboxProtocol.TelemetryPacket).netState, cliItems)
			KartSolver.applyNetState(cliB, (pktB :: GreyboxProtocol.TelemetryPacket).netState)

			for _, h in history do
				if h.seq > 45 then
					KartSolver.stepWithItems(
						cliA,
						h.inpA,
						world,
						FixedStep.FIXED_DT,
						cliItems,
						{ isServer = false, kartId = 1 }
					)
					KartSolver.stepWithItems(
						cliB,
						h.inpB,
						world,
						FixedStep.FIXED_DT,
						cliItems,
						{ isServer = false, kartId = 2, advanceItemWorld = false }
					)
					KartSolver.resolveKartKartCollisions({
						{ id = 1, state = cliA },
						{ id = 2, state = cliB },
					})
				end
			end

			assertNear(cliA.pos.z, srvA.pos.z, 1e-6, "replayed A pos.z")
			assertNear(cliB.pos.z, srvB.pos.z, 1e-6, "replayed B pos.z")
			assertNear(cliA.linVel.z, srvA.linVel.z, 1e-6, "replayed A linVel.z")
			assertNear(cliB.linVel.z, srvB.linVel.z, 1e-6, "replayed B linVel.z")
			assertEqual(cliA.timedImpulseTicks, srvA.timedImpulseTicks, "replayed A timedImpulseTicks")
			assertEqual(cliB.timedImpulseTicks, srvB.timedImpulseTicks, "replayed B timedImpulseTicks")
		end,
	},
	{
		name = "AIController speed-scaled lookahead & full lap completion on 48-node closed driveline (+2/20-kart bench)",
		fn = function()
			local world = makeFlatPlaneWorld(0.0)
			local profile = KartTuning.buildProfile("medium", "best")
			local pts = GreyboxArenaData.drivelineQuadCenters
			assert(#pts == 48, "arena_spec closed driveline has 48 points")

			local aiKart = TestDummyKart.create(profile)
			local aiState = TestDummyKart.createAIState(aiKart)

			-- Speed-scaled lookahead test (slow vs fast lookahead distance)
			aiKart.speed = 5.0
			local aimSlow = AIController.selectLookaheadPoint(aiState, aiKart, pts)
			local distSlow = aiState.lastLookaheadDistM
			aiKart.speed = 24.0
			local aimFast = AIController.selectLookaheadPoint(aiState, aiKart, pts)
			local distFast = aiState.lastLookaheadDistM
			assert(distFast > distSlow, "lookahead distance increases with speed")
			assert(aimFast.x > aimSlow.x, "faster lookahead reaches further along +X straight")
			aiKart.speed = 0.0

			local maxCrossTrackM = 0.0
			local lapCompleted = false
			for _ = 1, 5000 do
				local inp = TestDummyKart.computeCruiseInput(aiKart, aiState, FixedStep.FIXED_DT, 16.0)
				KartSolver.step(aiKart, inp, world, FixedStep.FIXED_DT)
				local nearestPt = pts[aiState.trackNodeIdx]
				local d = math.sqrt((aiKart.pos.x - nearestPt.x) ^ 2 + (aiKart.pos.z - nearestPt.z) ^ 2)
				if d > maxCrossTrackM then
					maxCrossTrackM = d
				end
				if aiState.lap >= 1 then
					lapCompleted = true
					break
				end
			end
			assert(lapCompleted, "AI completed 1 full lap on 48-node closed driveline")
			assert(
				maxCrossTrackM < GreyboxArenaData.drivelineWidthM * 0.5,
				string.format("AI remained inside road width (max offset %.2fm)", maxCrossTrackM)
			)

			-- Per-tick timing benchmark: 2 karts (measured) & 20 karts (extrapolated + measured)
			local function benchKarts(nKarts: number, ticks: number): number
				local karts: { KartSolver.CollisionParticipant } = {}
				local ais: { AIController.AIState } = {}
				for i = 1, nKarts do
					local ang = ((i - 1) / nKarts) * 2.0 * math.pi
					local st = KartSolver.createState(
						profile,
						{ x = math.cos(ang) * 35.0, y = 0.291, z = -49.0 + math.sin(ang) * 35.0 },
						ang
					)
					table.insert(karts, { id = i, state = st })
					table.insert(ais, AIController.createState(pts, st.pos))
				end
				local itemW = ItemWorld.createEmpty("NORMAL_RACE")
				local t0 = os.clock()
				for _ = 1, ticks do
					ItemWorld.tick(itemW)
					for kIdx = 1, nKarts do
						local inp =
							AIController.computeInput(ais[kIdx], karts[kIdx].state, pts, FixedStep.FIXED_DT, 16.0)
						KartSolver.stepWithItems(karts[kIdx].state, inp, world, FixedStep.FIXED_DT, itemW, {
							isServer = true,
							kartId = kIdx,
							advanceItemWorld = false,
						})
					end
					KartSolver.resolveKartKartCollisions(karts)
				end
				return ((os.clock() - t0) * 1e6) / ticks
			end

			local us2 = benchKarts(2, 500)
			local us20 = benchKarts(20, 200)
			print(
				string.format(
					"[Bench] 2-kart: %.1f us/tick (extrapolated 20-kart linear=%.1f us/tick, measured 20-kart=%.1f us/tick / 8333 us budget)",
					us2,
					us2 * 10.0,
					us20
				)
			)
		end,
	},
}
