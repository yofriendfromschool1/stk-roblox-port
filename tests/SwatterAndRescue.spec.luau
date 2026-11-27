--!strict
-- tests/SwatterAndRescue.spec.luau
-- SPDX-License-Identifier: GPL-3.0-or-later

local CheckManager = require("../src/shared/race/CheckManager")
local FixedStep = require("../src/shared/sim/FixedStep")
local GreyboxProtocol = require("../src/shared/net/GreyboxProtocol")
local ItemEffectState = require("../src/shared/sim/ItemEffectState")
local ItemTuning = require("../src/shared/ItemTuning")
local ItemWorld = require("../src/shared/items/ItemWorld")
local KartSolver = require("../src/shared/sim/KartSolver")
local KartTuning = require("../src/shared/KartTuning")
local KartVisualMath = require("../src/shared/kart/KartVisualMath")
local SandtrackData = require("../src/shared/track/SandtrackData")

local function assertEqual(actual: any, expected: any, msg: string)
	if actual ~= expected then
		error(string.format("%s: expected %s, got %s", msg, tostring(expected), tostring(actual)))
	end
end

local function assertTrue(cond: boolean, msg: string)
	if not cond then
		error(msg)
	end
end

local function makeFlatPlaneWorld(groundY: number): KartSolver.WorldQuery
	return {
		raycast = function(origin, dir, length)
			if dir.y < 0 and origin.y >= groundY then
				local dist = (origin.y - groundY) / -dir.y
				if dist >= 0 and dist <= length then
					return {
						distance = dist,
						point = { x = origin.x, y = groundY, z = origin.z },
						normal = { x = 0, y = 1, z = 0 },
						highTireAdhesion = false,
						surfaceGrip = 1.0,
						materialName = "sand",
					}
				end
			end
			return nil
		end,
	}
end

return {
	{
		name = "4-kart swatter group squashes strictly 1 victim per swing and respects start guard",
		fn = function()
			local profile = KartTuning.buildProfile("medium", "best")
			local attacker = KartSolver.createState(profile, { x = 0, y = 0.291, z = 0 }, 0)
			attacker.attachmentType = ItemTuning.ATTACHMENT_SWATTER
			attacker.attachmentTicksLeft = 1200

			local v1 = KartSolver.createState(profile, { x = 0, y = 0.291, z = -1.2 }, 0)
			local v2 = KartSolver.createState(profile, { x = 0.2, y = 0.291, z = -1.5 }, 0)
			local v3 = KartSolver.createState(profile, { x = -0.2, y = 0.291, z = -1.8 }, 0)
			local parts: { KartSolver.CollisionParticipant } = {
				{ id = 1, state = attacker },
				{ id = 2, state = v1 },
				{ id = 3, state = v2 },
				{ id = 4, state = v3 },
			}

			-- First 60 ticks (0.5 s start guard) must not start swing
			for t = 1, 59 do
				attacker.attachmentTicksLeft -= 1
				assertEqual(KartSolver.checkSwatterHits(attacker, parts, t, false), 0, "start guard blocks swing")
			end
			assertEqual(attacker.swatterPhase, ItemTuning.SWATTER_PHASE_AIMING, "still aiming before 0.5s")

			-- Advance past 0.5s guard + 20t TO_TARGET downswing -> hits strictly 1 kart
			local totalHits = 0
			for t = 60, 85 do
				attacker.attachmentTicksLeft -= 1
				totalHits += KartSolver.checkSwatterHits(attacker, parts, t, false)
			end
			assertEqual(totalHits, 1, "strictly 1 victim squashed per swing")
			assertEqual(v1.itemEffect.effectType, ItemEffectState.EFFECT_SQUASH, "closest kart v1 squashed")
			assertEqual(v2.itemEffect.effectType, ItemEffectState.EFFECT_NONE, "v2 not squashed on same swing")
			assertEqual(v3.itemEffect.effectType, ItemEffectState.EFFECT_NONE, "v3 not squashed on same swing")
			assertEqual(attacker.swatterPhase, ItemTuning.SWATTER_PHASE_FROM_TARGET, "entered FROM_TARGET cooldown")
		end,
	},
	{
		name = "Swatter hit-region checks SWAT_POS_OFFSET (0, 0.2, -0.4), not kart center",
		fn = function()
			local profile = KartTuning.buildProfile("medium", "best")
			local attacker = KartSolver.createState(profile, { x = 0, y = 0.2, z = 0 }, 0)
			attacker.attachmentType = ItemTuning.ATTACHMENT_SWATTER
			attacker.attachmentTicksLeft = 1130 -- past 0.5s start guard

			-- Front kart at z = +2.8: dist to kart center is 2.8m (< 3.0), but dist to SWAT_POS_OFFSET z=-0.4 is 3.2m (> 3.0)
			local frontKart = KartSolver.createState(profile, { x = 0, y = 0.2, z = 2.8 }, 0)
			KartSolver.checkSwatterHits(attacker, { { id = 1, state = attacker }, { id = 2, state = frontKart } }, 100)
			assertEqual(
				attacker.swatterPhase,
				ItemTuning.SWATTER_PHASE_AIMING,
				"front kart outside swatter offset range"
			)

			-- Rear kart at z = -3.2: dist to kart center is 3.2m (> 3.0), but dist to SWAT_POS_OFFSET z=-0.4 is 2.8m (< 3.0)
			local rearKart = KartSolver.createState(profile, { x = 0, y = 0.2, z = -3.2 }, 0)
			KartSolver.checkSwatterHits(attacker, { { id = 1, state = attacker }, { id = 3, state = rearKart } }, 101)
			assertEqual(
				attacker.swatterPhase,
				ItemTuning.SWATTER_PHASE_TO_TARGET,
				"rear kart inside swatter offset range"
			)
		end,
	},
	{
		name = "Swatter victim tie-breaking is deterministic by kartId and bit-identical across protocol replay",
		fn = function()
			local profile = KartTuning.buildProfile("medium", "best")
			local a1 = KartSolver.createState(profile, { x = 0, y = 0.2, z = 0 }, 0)
			a1.attachmentType = ItemTuning.ATTACHMENT_SWATTER
			a1.attachmentTicksLeft = 1130
			local t10A = KartSolver.createState(profile, { x = 1.0, y = 0.2, z = -0.4 }, 0)
			local t20A = KartSolver.createState(profile, { x = -1.0, y = 0.2, z = -0.4 }, 0)

			local a2 = KartSolver.createState(profile, { x = 0, y = 0.2, z = 0 }, 0)
			a2.attachmentType = ItemTuning.ATTACHMENT_SWATTER
			a2.attachmentTicksLeft = 1130
			local t10B = KartSolver.createState(profile, { x = 1.0, y = 0.2, z = -0.4 }, 0)
			local t20B = KartSolver.createState(profile, { x = -1.0, y = 0.2, z = -0.4 }, 0)

			-- Opposite input list orders must still pick id=10
			KartSolver.checkSwatterHits(
				a1,
				{ { id = 20, state = t20A }, { id = 10, state = t10A }, { id = 1, state = a1 } },
				100
			)
			KartSolver.checkSwatterHits(
				a2,
				{ { id = 1, state = a2 }, { id = 10, state = t10B }, { id = 20, state = t20B } },
				100
			)
			assertEqual(a1.swatterTargetId, 10, "picks lowest kartId on exact distance tie (order A)")
			assertEqual(a2.swatterTargetId, 10, "picks lowest kartId on exact distance tie (order B)")

			-- Round-trip through GreyboxProtocol snapshot mid-swing and verify identical victim hit
			local ns = KartSolver.captureNetState(a1)
			local buf = GreyboxProtocol.packSnapshot(100, 10, 0, ns, "")
			local unpacked = GreyboxProtocol.unpackSnapshot(buf, nil)
			assertTrue(unpacked ~= nil, "unpacked swatter snapshot")
			local aReplayed = KartSolver.createState(profile)
			KartSolver.applyNetState(aReplayed, (unpacked :: GreyboxProtocol.TelemetryPacket).netState)
			assertEqual(aReplayed.swatterTargetId, 10, "swatterTargetId preserved across protocol")
			assertEqual(aReplayed.swatterPhase, ItemTuning.SWATTER_PHASE_TO_TARGET, "swatterPhase preserved")

			local hitsA, hitsR = 0, 0
			for step = 1, 25 do
				a1.attachmentTicksLeft -= 1
				aReplayed.attachmentTicksLeft -= 1
				hitsA += KartSolver.checkSwatterHits(
					a1,
					{ { id = 1, state = a1 }, { id = 10, state = t10A }, { id = 20, state = t20A } },
					100 + step
				)
				hitsR += KartSolver.checkSwatterHits(
					aReplayed,
					{ { id = 1, state = aReplayed }, { id = 10, state = t10B }, { id = 20, state = t20B } },
					100 + step
				)
			end
			assertEqual(hitsA, 1, "original hit count == 1")
			assertEqual(hitsR, 1, "replayed hit count == 1")
			assertEqual(
				t10B.itemEffect.effectType,
				ItemEffectState.EFFECT_SQUASH,
				"replayed swatter hits identical victim id=10"
			)
			assertEqual(t20B.itemEffect.effectType, ItemEffectState.EFFECT_NONE, "victim id=20 untouched")
		end,
	},
	{
		name = "Bomb-removal swatter runs 192 ticks, skips swatting, animates bomb knockoff, and clears attachment",
		fn = function()
			local world = makeFlatPlaneWorld(0.0)
			local profile = KartTuning.buildProfile("medium", "best")
			local itemWorld = ItemWorld.createEmpty("NORMAL_RACE")
			local k = KartSolver.createState(profile, { x = 0, y = 0.291, z = 0 }, 0)
			local nearby = KartSolver.createState(profile, { x = 0, y = 0.291, z = -0.5 }, 0)

			k.attachmentType = ItemTuning.ATTACHMENT_BOMB
			k.attachmentTicksLeft = 600
			KartSolver.setPowerup(k, ItemTuning.POWERUP_SWATTER, 1)
			KartSolver.stepWithItems(
				k,
				{ accel = 1, brake = false, steer = 0, drift = false, fire = true },
				world,
				FixedStep.FIXED_DT,
				itemWorld,
				{ isServer = true, kartId = 1 }
			)

			assertEqual(k.attachmentType, ItemTuning.ATTACHMENT_SWATTER, "bomb replaced by swatter")
			assertEqual(k.attachmentTicksLeft, 192, "bomb-removal duration = 192 ticks (1.6s)")
			assertEqual(k.swatterBombMode, true, "swatterBombMode set")

			-- Animation checks at frame 0 (192t), frame 33.75 (30t), frame 37.5 (12t)
			local p0 = KartVisualMath.computeSwatterAnimation(192, 0, 0, true, 0)
			assertEqual(p0.showBomb, true, "bomb visible at start of removal")
			assertEqual(p0.bombOffsetXMeters, 0, "bomb at rest before frame 32.5")

			local pFly = KartVisualMath.computeSwatterAnimation(30, 0, 0, true, 0)
			assertEqual(pFly.showBomb, true, "bomb visible while flying off (frame 33.75)")
			assertTrue(pFly.bombOffsetXMeters < -1.0, "bomb knocked off sideways at frame 33.75")

			local pHide = KartVisualMath.computeSwatterAnimation(12, 0, 0, true, 0)
			assertEqual(pHide.showBomb, false, "bomb hidden after frame 35")

			-- Advance full 192 ticks: nearby opponent must NOT be squashed, and attachment clears cleanly
			for t = 1, 192 do
				KartSolver.stepWithItems(
					k,
					{ accel = 0, brake = false, steer = 0, drift = false, fire = false },
					world,
					FixedStep.FIXED_DT,
					itemWorld,
					{ isServer = true, kartId = 1, advanceItemWorld = false }
				)
				assertEqual(
					KartSolver.checkSwatterHits(k, { { id = 1, state = k }, { id = 2, state = nearby } }, t),
					0,
					"bomb removal never swats opponents"
				)
			end
			assertEqual(k.attachmentType, ItemTuning.ATTACHMENT_NONE, "swatter cleared after 192 ticks")
			assertEqual(k.swatterBombMode, false, "swatterBombMode cleared")
		end,
	},
	{
		name = "Continuous lastRescuePose records grounded drivable quads, ignores air/reset, clamps at missed checkline, and rescues in single-digit meters",
		fn = function()
			local profile = KartTuning.buildProfile("medium", "best")
			local nodes = SandtrackData.drivelineQuadCenters
			local chks = SandtrackData.checkpoints :: any
			local world = makeFlatPlaneWorld(-140.0)

			local samples = {
				{ nextChk = 1, quad = 32 },
				{ nextChk = 2, quad = 87 },
				{ nextChk = 3, quad = 142 },
				{ nextChk = 4, quad = 224 },
				{ nextChk = 0, quad = 254 },
			}
			for _, s in samples do
				local q = nodes[s.quad]
				local qn = nodes[(s.quad % #nodes) + 1]
				local dx, dz = qn.x - q.x, qn.z - q.z
				local len = math.max(1e-6, math.sqrt(dx * dx + dz * dz))
				local k = KartSolver.createState(profile, { x = q.x, y = -139.65, z = q.z }, 0)
				k.race.lap = 0
				k.race.nextCheckpoint = s.nextChk
				k.isOnGround = true
				k.activeMaterialName = "road.jpg"
				assertTrue(KartSolver.updateLastRescuePose(k, chks, nodes, nil), "records on drivable road")
				assertEqual(k.lastRescueQuadIdx, s.quad, "recorded nearest quad")

				-- Move 4m off-track into void/reset and rescue
				local offX = q.x + (-dz / len) * 4.0
				local offZ = q.z + (dx / len) * 4.0
				k.pos = { x = offX, y = -145.0, z = offZ }
				k.isOnGround = false
				k.activeMaterialName = "oasis-water.png"
				assertEqual(KartSolver.updateLastRescuePose(k, chks, nodes, nil), false, "does not record airborne")

				local rPos, rYaw, rQuad = CheckManager.resolveClampedRescuePose(
					k.lastRescueQuadIdx,
					k.lastRescuePos,
					k.lastRescueYawRad,
					chks,
					k.race.lap,
					k.race.nextCheckpoint,
					nodes,
					SandtrackData.startTransforms[1].pos,
					SandtrackData.startTransforms[1].yawRad,
					nil,
					profile.collisionHeight
				)
				assertEqual(rQuad, s.quad, "rescues to recorded quad")
				local dist = math.sqrt((offX - rPos.x) ^ 2 + (offZ - rPos.z) ^ 2)
				assertTrue(dist < 10.0, string.format("single-digit rescue distance (%.2fm)", dist))
				local expectedYaw = math.atan2(dx, dz)
				assertTrue(math.abs(rYaw - expectedYaw) < 1e-4, "heading matches quad tangent")
			end

			-- Do NOT record on ignore/reset surfaces even when grounded
			local kSurf = KartSolver.createState(profile, { x = nodes[32].x, y = -139.65, z = nodes[32].z }, 0)
			kSurf.race.lap = 0
			kSurf.race.nextCheckpoint = 1
			kSurf.isOnGround = true
			kSurf.activeMaterialName = "road.jpg"
			assertTrue(KartSolver.updateLastRescuePose(kSurf, chks, nodes, nil), "initial valid record")
			kSurf.pos = { x = nodes[33].x, y = -139.65, z = nodes[33].z }
			for _, badMat in { "oasis-water.png", "seabed.jpg", "transparence2.png" } do
				kSurf.activeMaterialName = badMat
				assertEqual(KartSolver.updateLastRescuePose(kSurf, chks, nodes, nil), false, "ignores " .. badMat)
				assertEqual(kSurf.lastRescueQuadIdx, 32, "preserves previous quad on " .. badMat)
			end

			-- Deliberately MISS checkline 2 (quad 90): drive to quad 88, then skip to quad 96 while nextCheckpoint stays 2
			local kMiss = KartSolver.createState(profile, { x = nodes[88].x, y = -139.65, z = nodes[88].z }, 0)
			kMiss.race.lap = 0
			kMiss.race.nextCheckpoint = 2
			kMiss.isOnGround = true
			kMiss.activeMaterialName = "road.jpg"
			assertTrue(KartSolver.updateLastRescuePose(kMiss, chks, nodes, nil), "recorded quad 88 before CHK 2")
			kMiss.pos = { x = nodes[96].x, y = -139.65, z = nodes[96].z }
			assertEqual(KartSolver.updateLastRescuePose(kMiss, chks, nodes, nil), false, "clamped past missed CHK 2")
			assertEqual(kMiss.lastRescueQuadIdx, 88, "stays at quad 88 just before missed CHK 2")

			local rPosM, rYawM, rQuadM = CheckManager.resolveClampedRescuePose(
				kMiss.lastRescueQuadIdx,
				kMiss.lastRescuePos,
				kMiss.lastRescueYawRad,
				chks,
				kMiss.race.lap,
				kMiss.race.nextCheckpoint,
				nodes,
				SandtrackData.startTransforms[1].pos,
				SandtrackData.startTransforms[1].yawRad,
				nil,
				profile.collisionHeight
			)
			assertEqual(rQuadM, 88, "rescue clamped just before missed CHK 2")
			assertTrue(KartSolver.triggerRescue(kMiss, rPosM, rYawM), "triggerRescue succeeds")
			local ns = KartSolver.captureNetState(kMiss)
			local buf = GreyboxProtocol.packSnapshot(200, 5, 0, ns, "")
			local unpacked = GreyboxProtocol.unpackSnapshot(buf, nil)
			assertTrue(unpacked ~= nil, "unpacked rescue snapshot")
			local kReplayed = KartSolver.createState(profile)
			KartSolver.applyNetState(kReplayed, (unpacked :: GreyboxProtocol.TelemetryPacket).netState)
			assertEqual(kReplayed.lastRescueQuadIdx, 88, "lastRescueQuadIdx preserved across protocol")
			for _ = 1, 144 do
				KartSolver.step(
					kMiss,
					{ accel = 1, brake = false, steer = 0, drift = false },
					world,
					FixedStep.FIXED_DT
				)
				KartSolver.step(
					kReplayed,
					{ accel = 1, brake = false, steer = 0, drift = false },
					world,
					FixedStep.FIXED_DT
				)
			end
			assertTrue(
				math.abs(kMiss.pos.x - nodes[88].x) < 1e-4 and math.abs(kMiss.pos.z - nodes[88].z) < 1e-4,
				"landed on quad 88"
			)
			assertTrue(
				math.abs(kMiss.pos.x - kReplayed.pos.x) < 1e-6 and math.abs(kMiss.pos.z - kReplayed.pos.z) < 1e-6,
				"replay bit-identical"
			)
			assertEqual(kMiss.race.nextCheckpoint, 2, "nextCheckpoint preserved")
		end,
	},
	{
		name = "Rescue places kart at last crossed checkline along driveline tangent without rewinding nextCheckpoint",
		fn = function()
			-- Crossed checkline 1 (nextCheckpoint = 2) -> rescue places at checkline 1
			local pos1, yaw1, grp1 = CheckManager.getRescuePose(
				SandtrackData.checkpoints :: any,
				0,
				2,
				SandtrackData.drivelineQuadCenters,
				SandtrackData.startTransforms[1].pos,
				SandtrackData.startTransforms[1].yawRad,
				nil,
				0.7
			)
			assertEqual(grp1, 1, "last crossed checkline group == 1")
			local chk1 = SandtrackData.checkpoints[2] -- id = 1
			local minX = math.min(chk1.p1.x, chk1.p2.x) - 0.5
			local maxX = math.max(chk1.p1.x, chk1.p2.x) + 0.5
			local minZ = math.min(chk1.p1.z, chk1.p2.z) - 0.5
			local maxZ = math.max(chk1.p1.z, chk1.p2.z) + 0.5
			assertTrue(
				pos1.x >= minX and pos1.x <= maxX and pos1.z >= minZ and pos1.z <= maxZ,
				"rescue pos lies on checkline 1"
			)

			-- Deliberately MISS checkline 2 (nextCheckpoint stays 2, even if kart is far ahead) -> still rescues to checkline 1!
			local profile = KartTuning.buildProfile("medium", "best")
			local world = makeFlatPlaneWorld(pos1.y - 0.35)
			local k = KartSolver.createState(profile, { x = -250, y = -160, z = -60 }, 1.2)
			k.race.lap = 0
			k.race.nextCheckpoint = 2
			k.attachmentType = ItemTuning.ATTACHMENT_BOMB
			k.attachmentTicksLeft = 300
			k.speed = 25.0
			k.linVel = { x = 10, y = -5, z = 20 }

			assertTrue(KartSolver.triggerRescue(k, pos1, yaw1), "triggerRescue succeeds")
			assertEqual(
				k.attachmentType,
				ItemTuning.ATTACHMENT_NONE,
				"rescue clears attachment (rescue_animation.cpp:L76)"
			)
			assertEqual(k.race.nextCheckpoint, 2, "nextCheckpoint preserved on rescue trigger")

			-- Protocol round-trip mid-rescue
			local ns = KartSolver.captureNetState(k)
			local buf = GreyboxProtocol.packSnapshot(200, 5, 0, ns, "")
			local unpacked = GreyboxProtocol.unpackSnapshot(buf, nil)
			assertTrue(unpacked ~= nil, "unpacked rescue snapshot")
			local kReplayed = KartSolver.createState(profile)
			KartSolver.applyNetState(kReplayed, (unpacked :: GreyboxProtocol.TelemetryPacket).netState)
			assertEqual(
				kReplayed.itemEffect.effectType,
				ItemEffectState.EFFECT_RESCUE,
				"EFFECT_RESCUE preserved across protocol"
			)

			-- Advance 58 ticks (40% lift): still at original XZ, lifted upward
			for _ = 1, 58 do
				KartSolver.step(k, { accel = 1, brake = false, steer = 1, drift = true }, world, FixedStep.FIXED_DT)
				KartSolver.step(
					kReplayed,
					{ accel = 1, brake = false, steer = 1, drift = true },
					world,
					FixedStep.FIXED_DT
				)
			end
			assertTrue(k.pos.y > -160.0 + 1.5, "kart lifts during first 40% of rescue")
			assertTrue(math.abs(k.pos.x - -250) < 1e-4, "XZ fixed during lift phase")

			-- Finish remaining 86 ticks (total 144 ticks = 1.2 s)
			for _ = 1, 86 do
				KartSolver.step(k, { accel = 1, brake = false, steer = 1, drift = true }, world, FixedStep.FIXED_DT)
				KartSolver.step(
					kReplayed,
					{ accel = 1, brake = false, steer = 1, drift = true },
					world,
					FixedStep.FIXED_DT
				)
			end
			assertEqual(KartSolver.isRescuing(k), false, "rescue finishes after 144 ticks")
			assertEqual(k.race.nextCheckpoint, 2, "nextCheckpoint never rewound")
			assertEqual(k.race.lap, 0, "lap never rewound")
			assertTrue(
				math.abs(k.pos.x - pos1.x) < 1e-4 and math.abs(k.pos.z - pos1.z) < 1e-4,
				"landed on checkline 1 target XZ"
			)
			assertTrue(
				math.abs(k.pos.x - kReplayed.pos.x) < 1e-6 and math.abs(k.pos.z - kReplayed.pos.z) < 1e-6,
				"replay rescue bit-identical"
			)
		end,
	},
	{
		name = "Time Trial grants numLaps zippers (3/5/10) and omits bonus boxes",
		fn = function()
			local ttWorld = ItemWorld.fromArenaSpec(SandtrackData, "TIME_TRIAL")
			local bonusBoxes = 0
			for _, it in ipairs(ttWorld.items) do
				if it.itemType == "item" then
					bonusBoxes += 1
				end
			end
			assertEqual(bonusBoxes, 0, "time trial omits bonus boxes")

			local profile = KartTuning.buildProfile("medium", "best")
			for _, laps in ipairs({ 3, 5, 10 }) do
				local pType, pCount = ItemTuning.getDefaultCollectibles("TIME_TRIAL", laps)
				assertEqual(pType, ItemTuning.POWERUP_ZIPPER, "time trial default collectible is zipper")
				assertEqual(pCount, laps, "time trial zipper count equals laps")
				local k = KartSolver.createState(profile)
				KartSolver.setPowerup(k, pType, pCount)
				assertEqual(k.heldPowerup, ItemTuning.POWERUP_ZIPPER, "kart heldPowerup is zipper")
				assertEqual(k.heldPowerupCount, laps, "kart heldPowerupCount preserved up to 255")
			end

			local nType, nCount = ItemTuning.getDefaultCollectibles("NORMAL_RACE", 5)
			assertEqual(nType, ItemTuning.POWERUP_NONE, "normal race starts empty")
			assertEqual(nCount, 0, "normal race count is 0")
		end,
	},
	{
		name = "3D quad center rescue Y, nil lastRescuePose nearest-quad fallback, and verifyRescuePlacement",
		fn = function()
			local profile = KartTuning.buildProfile("medium", "best")
			local nodes = SandtrackData.drivelineQuadCenters
			local chks = SandtrackData.checkpoints :: any
			for i, pt in ipairs(nodes) do
				assertTrue(type(pt.y) == "number", "Sandtrack quad " .. tostring(i) .. " has numeric y")
			end

			-- Fall immediately from spawn before any grounded tick (lastRescueQuadIdx == 0)
			local startPos = SandtrackData.startTransforms[1].pos
			local kVoid = KartSolver.createState(profile, { x = startPos.x, y = -245.0, z = startPos.z }, 0)
			assertEqual(kVoid.lastRescueQuadIdx, 0, "no grounded tick yet")
			local rPos0, _, rQuad0 = CheckManager.resolveClampedRescuePose(
				kVoid.lastRescueQuadIdx,
				kVoid.lastRescuePos,
				kVoid.lastRescueYawRad,
				chks,
				kVoid.race.lap,
				kVoid.race.nextCheckpoint,
				nodes,
				startPos,
				SandtrackData.startTransforms[1].yawRad,
				nil,
				profile.collisionHeight,
				kVoid.pos
			)
			assertTrue(rQuad0 > 0, "falls back to nearest driveline quad, not startPos/origin")
			local expectedY0 = (nodes[rQuad0].y :: number) + 0.5 * profile.collisionHeight
			assertTrue(
				math.abs(rPos0.y - expectedY0) < 1e-4,
				string.format("fallback Y comes from quad center (expected %.3f, got %.3f)", expectedY0, rPos0.y)
			)

			-- verifyRescuePlacement passes when ground is within ~1m below and snaps when missing
			local q142 = nodes[142]
			local groundY = q142.y :: number
			local goodWorld = makeFlatPlaneWorld(groundY)
			local placementPos = { x = q142.x, y = groundY + 0.5 * profile.collisionHeight, z = q142.z }
			local _, _, okGood =
				CheckManager.verifyRescuePlacement(placementPos, 0, nodes, goodWorld, profile.collisionHeight)
			assertTrue(okGood, "verifyRescuePlacement passes with ground below")

			local emptyWorld = {
				raycast = function()
					return nil
				end,
			}
			local snapPos, _, okBad, reason = CheckManager.verifyRescuePlacement(
				{ x = q142.x, y = -245.0, z = q142.z },
				0,
				nodes,
				emptyWorld,
				profile.collisionHeight
			)
			assertEqual(okBad, false, "verifyRescuePlacement fails when no ground below")
			assertTrue(type(reason) == "string" and #reason > 0, "verifyRescuePlacement returns reason")
			assertTrue(
				math.abs(snapPos.y - (groundY + 0.5 * profile.collisionHeight)) < 1e-4,
				"verifyRescuePlacement snaps to nearest quad center Y"
			)
		end,
	},
}
