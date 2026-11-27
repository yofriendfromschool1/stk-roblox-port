--!strict
-- tests/CameraProjectileAnim.spec.luau
-- SPDX-License-Identifier: GPL-3.0-or-later

local FixedStep = require("../src/shared/sim/FixedStep")
local Flyable = require("../src/shared/sim/Flyable")
local GreyboxProtocol = require("../src/shared/net/GreyboxProtocol")
local ItemEffectState = require("../src/shared/sim/ItemEffectState")
local KartSolver = require("../src/shared/sim/KartSolver")
local KartTuning = require("../src/shared/KartTuning")
local Math3D = require("../src/shared/sim/Math3D")
local RaceState = require("../src/shared/sim/RaceState")

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

local function assertNear(actual: number, expected: number, tol: number, msg: string)
	if math.abs(actual - expected) > tol then
		error(string.format("%s: expected %.4f +- %.4f, got %.4f", msg, expected, tol, actual))
	end
end

return {
	{
		name = "drifting projectiles launch along getAlignedRotation (visual skid), never physical rot",
		fn = function()
			local prof = KartTuning.buildProfileForKart("tux", "intermediate")
			for _, visYaw in { -0.45, 0.45 } do
				local ks = KartSolver.createState(prof, { x = 0, y = 0.5, z = 0 }, 0.0)
				ks.speed = 20.0
				ks.skid.visualRotation = visYaw
				local aligned = KartSolver.getAlignedRotation(ks)
				local _, _, alignedFwd = Math3D.quatBasis(aligned)
				local _, _, physFwd = Math3D.quatBasis(ks.rot)
				assertTrue(math.abs(alignedFwd.x - physFwd.x) > 0.3, "alignedFwd differs from physFwd")

				local fw = Flyable.createWorld()
				local proxy = KartSolver.makeFlyableProxy(1, ks, 1, "intermediate")

				local b = Flyable.spawnBowling(fw, proxy, false)
				local bDir = Math3D.normalize(b.vel, { x = 0, y = 0, z = 1 })
				assertNear(bDir.x, alignedFwd.x, 1e-4, "bowling dir.x matches alignedFwd")
				assertNear(bDir.z, alignedFwd.z, 1e-4, "bowling dir.z matches alignedFwd")

				local c = Flyable.spawnCake(fw, proxy, { proxy }, false)
				local cHoriz = Math3D.normalize({ x = c.vel.x, y = 0, z = c.vel.z }, { x = 0, y = 0, z = 1 })
				assertNear(cHoriz.x, alignedFwd.x, 1e-4, "non-homing cake horiz dir.x matches alignedFwd")
				assertNear(cHoriz.z, alignedFwd.z, 1e-4, "non-homing cake horiz dir.z matches alignedFwd")

				local p = Flyable.spawnPlunger(fw, proxy, { proxy }, false, false)
				local pDir = Math3D.normalize(p.vel, { x = 0, y = 0, z = 1 })
				assertNear(pDir.x, alignedFwd.x, 1e-4, "non-homing plunger dir.x matches alignedFwd")
				assertNear(pDir.z, alignedFwd.z, 1e-4, "non-homing plunger dir.z matches alignedFwd")
			end
		end,
	},
	{
		name = "refreshFlyableProxy updates pos, rot, alignedRot, and speed in place",
		fn = function()
			local prof = KartTuning.buildProfileForKart("tux", "intermediate")
			local ks = KartSolver.createState(prof, { x = 1, y = 2, z = 3 }, 0.0)
			local proxy = KartSolver.makeFlyableProxy(1, ks, 2, "intermediate")
			ks.pos = { x = 10, y = 4, z = -5 }
			ks.speed = 24.5
			ks.skid.visualRotation = 0.35
			KartSolver.refreshFlyableProxy(proxy, ks, 1)
			assertNear(proxy.pos.x, 10, 1e-5, "refreshed pos.x")
			assertNear(proxy.speed, 24.5, 1e-5, "refreshed speed")
			assertEqual(proxy.rank, 1, "refreshed rank")
			assertTrue(proxy.alignedRot ~= nil, "alignedRot populated")
			if proxy.alignedRot ~= nil then
				local _, _, fwd = Math3D.quatBasis(proxy.alignedRot)
				assertTrue(math.abs(fwd.x) > 0.25, "refreshed alignedRot reflects visualRotation")
			end
		end,
	},
	{
		name = "rescue bird uniform velocity carry, 144-tick input suppression, and netstate roundtrip",
		fn = function()
			local prof = KartTuning.buildProfileForKart("tux", "intermediate")
			local ks = KartSolver.createState(prof, { x = 5, y = -10, z = 5 }, 0.0)
			local targetPos = { x = 2, y = 0.5, z = 2 }
			assertTrue(KartSolver.triggerRescue(ks, targetPos, math.pi * 0.5), "triggerRescue ok")
			assertEqual(ks.rescueTicks, 144, "initial rescueTicks == 144")

			local ns = KartSolver.captureNetState(ks)
			local remotes: { GreyboxProtocol.RemoteKartState } = {
				{
					id = "ai_2",
					kartId = "adiumy",
					pos = { 0, 1, 0 },
					rot = { 1, 0, 0, 0 },
					linVel = { 0, 0, 0 },
					speed = 0,
					steer = 0,
					attachmentType = 0,
					plungerFaceTicks = 0,
					isSquashed = false,
					rank = 2,
					rescueTicks = 77,
				},
			}
			local buf = GreyboxProtocol.packSnapshot(100, 1, 0, ns, "", remotes, 0.5)
			local unpacked = GreyboxProtocol.unpackSnapshot(buf)
			assertTrue(unpacked ~= nil, "unpack ok")
			if unpacked ~= nil then
				assertEqual(unpacked.netState.rescueTicks, 144, "netState rescueTicks == 144")
				assertTrue(unpacked.remoteKarts ~= nil, "remoteKarts present")
				if unpacked.remoteKarts ~= nil then
					assertEqual(unpacked.remoteKarts[1].rescueTicks, 77, "remote rescueTicks == 77")
				end
			end

			local flatWorld: KartSolver.WorldQuery = {
				raycast = function()
					return nil
				end,
			}
			-- Step 58 ticks (40% lift phase at uniform 2.0/1.2 m/s => 0.8056 m lift)
			for _ = 1, 58 do
				KartSolver.step(
					ks,
					{ accel = 1, brake = false, steer = 1, drift = false },
					flatWorld,
					FixedStep.FIXED_DT
				)
			end
			assertTrue(ItemEffectState.isDriverInputSuppressed(ks.itemEffect), "still suppressed at tick 58")
			assertNear(ks.pos.y, -10.0 + (58 / 120) * (2.0 / 1.2), 0.02, "uniform lift height at 40% split")
			assertEqual(ks.rescueTicks, 144 - 58, "rescueTicks decrements deterministically")

			-- Step remaining 86 ticks to tick 144
			for _ = 59, 144 do
				KartSolver.step(
					ks,
					{ accel = 1, brake = false, steer = 1, drift = false },
					flatWorld,
					FixedStep.FIXED_DT
				)
			end
			assertTrue(not ItemEffectState.isDriverInputSuppressed(ks.itemEffect), "control returns at tick 144")
			assertEqual(ks.rescueTicks, 0, "rescueTicks == 0 after completion")
			assertNear(ks.pos.x, targetPos.x, 0.01, "landed at targetPos.x")
			assertNear(ks.pos.z, targetPos.z, 0.01, "landed at targetPos.z")
		end,
	},
	{
		name = "Ready/Set/Go start referee timing constants match world_status.cpp",
		fn = function()
			assertEqual(RaceState.SET_START_TICK, 120, "SET starts at 1.0s (120 ticks)")
			assertEqual(RaceState.GO_TICK, 240, "GO starts at 2.0s (240 ticks)")
			assertEqual(RaceState.MUSIC_START_TICK, 360, "MUSIC starts at 3.0s (360 ticks)")
		end,
	},
}
