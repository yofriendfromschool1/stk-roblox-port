--!strict
-- tests/CollisionAndBowling.spec.luau
-- SPDX-License-Identifier: GPL-3.0-or-later

local FixedStep = require("../src/shared/sim/FixedStep")
local Flyable = require("../src/shared/sim/Flyable")
local GreyboxProtocol = require("../src/shared/net/GreyboxProtocol")
local ItemEffectState = require("../src/shared/sim/ItemEffectState")
local ItemTuning = require("../src/shared/ItemTuning")
local KartSolver = require("../src/shared/sim/KartSolver")
local KartTuning = require("../src/shared/KartTuning")
local Math3D = require("../src/shared/sim/Math3D")

local function assertTrue(cond: boolean, msg: string)
	if not cond then
		error(msg)
	end
end

local tests = {}

table.insert(tests, {
	name = "all 18 roster profiles have positive collision dimensions and zero dimensions fail loudly",
	fn = function()
		for _, kid in ipairs(KartTuning.KART_ORDER) do
			local p = KartTuning.buildProfileForKart(kid, "best")
			assertTrue(p.width > 0, kid .. " width <= 0")
			assertTrue(p.length > 0, kid .. " length <= 0")
			assertTrue(p.collisionHeight > 0, kid .. " collisionHeight <= 0")
		end
		local ok = pcall(function()
			KartTuning.buildProfile(
				"medium",
				"best",
				{ width = 0, height = 0.5, length = 1.0, cogShiftY = 0.25 },
				"bad"
			)
		end)
		assertTrue(not ok, "zero width should fail loudly")
	end,
})

table.insert(tests, {
	name = "head-on and glancing kart-kart collisions across 4 distinct karts on flat and 25 deg ramp",
	fn = function()
		local testKarts = { "adiumy", "amanda", "sara_the_racer", "wilber" }
		local playerProf = KartTuning.buildProfileForKart("tux", "best")
		local dt = FixedStep.FIXED_DT

		for pass = 1, 2 do
			for _, targetKid in ipairs(testKarts) do
				local targetProf = KartTuning.buildProfileForKart(targetKid, "best")
				for _, mode in ipairs({ "head_on", "glancing", "ramp_25deg" }) do
					local pitch = if mode == "ramp_25deg" then math.rad(25.0) else 0.0
					local qPitch = Math3D.quatFromAxisAngle({ x = 1, y = 0, z = 0 }, pitch)
					local offsetX = if mode == "glancing" then 0.45 * (playerProf.width + targetProf.width) else 0.0

					local a = KartSolver.createState(playerProf, { x = 0.0, y = 0.30, z = 0.0 }, 0.0)
					a.rot = qPitch
					a.linVel = { x = 0.0, y = 0.0, z = 20.0 }
					a.speed = 20.0

					local dyRamp = if mode == "ramp_25deg" then 1.2 * math.tan(pitch) else 0.0
					local b = KartSolver.createState(targetProf, { x = offsetX, y = 0.30 + dyRamp, z = 1.2 }, 0.0)
					b.rot = qPitch
					b.linVel = { x = 0.0, y = 0.0, z = -10.0 }
					b.speed = -10.0

					local participants = {
						{ id = 1, state = a },
						{ id = -102, state = b },
					}
					local totalCols = 0
					for _ = 1, 10 do
						a.prevPos = { x = a.pos.x, y = a.pos.y, z = a.pos.z }
						b.prevPos = { x = b.pos.x, y = b.pos.y, z = b.pos.z }
						a.pos.x += a.linVel.x * dt
						a.pos.y += a.linVel.y * dt
						a.pos.z += a.linVel.z * dt
						b.pos.x += b.linVel.x * dt
						b.pos.y += b.linVel.y * dt
						b.pos.z += b.linVel.z * dt
						totalCols += KartSolver.resolveKartKartCollisions(participants)
					end
					assertTrue(totalCols > 0, string.format("pass %d %s %s had 0 collisions", pass, targetKid, mode))
					local sep = math.sqrt((b.pos.x - a.pos.x) ^ 2 + (b.pos.z - a.pos.z) ^ 2)
					assertTrue(
						sep >= 0.4 * (playerProf.width + targetProf.width),
						string.format("pass %d %s %s insufficient separation %.3f", pass, targetKid, mode, sep)
					)
				end
			end
		end
	end,
})

table.insert(tests, {
	name = "swept bowling hits 20/20 across varied angles & speeds with server/client parity and zero squash",
	fn = function()
		local shooterProf = KartTuning.buildProfileForKart("tux", "best")
		local targetProf = KartTuning.buildProfileForKart("sara_the_racer", "best")
		local dt = FixedStep.FIXED_DT
		local hits = 0

		local flatWorldQuery = {
			raycast = function(origin: Math3D.Vec3, dir: Math3D.Vec3, maxDist: number)
				if dir.y < -0.5 and origin.y >= 0.0 and origin.y + dir.y * maxDist <= 0.0 then
					local t = -origin.y / dir.y
					return {
						point = { x = origin.x + dir.x * t, y = 0.0, z = origin.z + dir.z * t },
						normal = { x = 0, y = 1, z = 0 },
						distance = t,
						materialName = "road.jpg",
					}
				end
				return nil
			end,
		}

		for idx = 1, 20 do
			local srvFly = Flyable.createWorld()
			local cliFly = Flyable.createWorld()

			local targetSrv = KartSolver.createState(targetProf, { x = 0, y = 0.30, z = 14.0 }, 0.0)
			local crossVx = ((idx % 5) - 2) * 8.0
			local fwdVz = (idx % 4) * 8.0
			targetSrv.linVel = { x = crossVx, y = 0.0, z = fwdVz }
			targetSrv.speed = fwdVz

			local shooterSrv = KartSolver.createState(shooterProf, { x = 0, y = 0.30, z = 0.0 }, 0.0)
			shooterSrv.speed = 25.0
			local sProxySrv = KartSolver.makeFlyableProxy(1, shooterSrv, 2, "best")
			local tProxySrv =
				KartSolver.makeFlyableProxy(GreyboxProtocol.resolveNumericKartId("ai_2", 1), targetSrv, 1, "best")

			local ballSrv = Flyable.spawnBowling(srvFly, sProxySrv, false)
			local ballSpeed = Math3D.len(ballSrv.vel)
			local relX = targetSrv.pos.x - ballSrv.pos.x
			local relZ = targetSrv.pos.z - ballSrv.pos.z
			local qa = (crossVx * crossVx + fwdVz * fwdVz) - ballSpeed * ballSpeed
			local qb = 2.0 * (relX * crossVx + relZ * fwdVz)
			local qc = relX * relX + relZ * relZ
			local disc = math.max(0.0, qb * qb - 4.0 * qa * qc)
			local t1 = (-qb + math.sqrt(disc)) / (2.0 * qa)
			local t2 = (-qb - math.sqrt(disc)) / (2.0 * qa)
			local estT = if t1 > 0 and (t1 < t2 or t2 <= 0) then t1 else t2
			local ix = targetSrv.pos.x + targetSrv.linVel.x * estT
			local iz = targetSrv.pos.z + targetSrv.linVel.z * estT
			local aimDir = Math3D.normalize(
				{ x = ix - ballSrv.pos.x, y = 0, z = iz - ballSrv.pos.z },
				{ x = 0, y = 0, z = 1 }
			)
			ballSrv.vel = Math3D.scale(aimDir, ballSpeed)

			-- Mirror exact initial state onto client via Flyable snapshot & canonical numeric ID
			Flyable.applySnapshot(cliFly, Flyable.captureSnapshot(srvFly))
			local targetCli = KartSolver.createState(targetProf, targetSrv.pos, 0.0)
			targetCli.linVel = { x = crossVx, y = 0.0, z = fwdVz }
			targetCli.speed = fwdVz
			local cliExploded = false
			local tProxyCli =
				KartSolver.makeFlyableProxy(GreyboxProtocol.resolveNumericKartId("ai_2", 1), targetCli, 1, "best")
			tProxyCli.onExplode = function()
				cliExploded = true
			end
			local sProxyCli = KartSolver.makeFlyableProxy(1, shooterSrv, 2, "best")

			local srvHitTick = -1
			local cliHitTick = -1
			for tick = 1, 80 do
				targetSrv.prevPos = { x = targetSrv.pos.x, y = targetSrv.pos.y, z = targetSrv.pos.z }
				targetSrv.pos.x += targetSrv.linVel.x * dt
				targetSrv.pos.z += targetSrv.linVel.z * dt
				KartSolver.refreshFlyableProxy(tProxySrv, targetSrv, 1)
				Flyable.step(srvFly, { sProxySrv, tProxySrv }, flatWorldQuery, dt, nil, tick)

				targetCli.prevPos = { x = targetCli.pos.x, y = targetCli.pos.y, z = targetCli.pos.z }
				targetCli.pos.x += targetCli.linVel.x * dt
				targetCli.pos.z += targetCli.linVel.z * dt
				KartSolver.refreshFlyableProxy(tProxyCli, targetCli, 1)
				Flyable.step(cliFly, { sProxyCli, tProxyCli }, flatWorldQuery, dt, nil, tick)

				if srvHitTick < 0 and targetSrv.itemEffect.effectType == ItemEffectState.EFFECT_EXPLOSION then
					srvHitTick = tick
				end
				if cliHitTick < 0 and cliExploded then
					cliHitTick = tick
				end
				if srvHitTick > 0 and cliHitTick > 0 then
					break
				end
			end

			assertTrue(srvHitTick > 0, string.format("shot #%d missed on server", idx))
			assertTrue(
				srvHitTick == cliHitTick,
				string.format("shot #%d server/client mismatch (srv=%d, cli=%d)", idx, srvHitTick, cliHitTick)
			)
			assertTrue(
				targetSrv.itemEffect.effectType == ItemEffectState.EFFECT_EXPLOSION,
				string.format("shot #%d expected EXPLOSION, got %d", idx, targetSrv.itemEffect.effectType)
			)
			hits += 1
		end
		assertTrue(hits == 20, string.format("expected 20/20 hits, got %d", hits))

		-- Verify grazing miss strictly outside bowling RADIUS (0.44 m) does NOT false-hit
		local hitOut, _ = Flyable.segmentIntersectsExpandedOBB(
			{ x = 0.70, y = 0.0, z = -2.0 },
			{ x = 0.70, y = 0.0, z = 2.0 },
			{ x = 0.2295, y = 0.3456, z = 0.5760 },
			ItemTuning.bowling.RADIUS
		)
		assertTrue(not hitOut, "grazing miss outside 0.44 m radius should not register hit")
	end,
})

table.insert(tests, {
	name = "GreyboxProtocol round-trips isExploding and resolveNumericKartId matches server IDs",
	fn = function()
		assertTrue(GreyboxProtocol.resolveNumericKartId("Dummy_1") == -1001, "Dummy_1 -> -1001")
		assertTrue(GreyboxProtocol.resolveNumericKartId("ai_2") == -102, "ai_2 -> -102")
		assertTrue(GreyboxProtocol.resolveNumericKartId("ai_3") == -103, "ai_3 -> -103")
		assertTrue(GreyboxProtocol.resolveNumericKartId("local_p2") == -2, "local_p2 -> -2")
		assertTrue(GreyboxProtocol.resolveNumericKartId("7225229891") == 7225229891, "UserId numeric")

		local st = KartSolver.createState(KartTuning.buildProfileForKart("tux", "best"))
		local snap = KartSolver.captureNetState(st)
		local pkt = GreyboxProtocol.packSnapshot(1, 1, 1, snap, "", {
			{
				id = "ai_2",
				kartId = "amanda",
				pos = { 1, 2, 3 },
				rot = { 1, 0, 0, 0 },
				linVel = { 0, 0, 0 },
				speed = 0,
				steer = 0,
				attachmentType = 0,
				plungerFaceTicks = 0,
				isSquashed = false,
				isExploding = true,
				rank = 2,
			},
		})
		local unpacked = GreyboxProtocol.unpackSnapshot(pkt, "")
		assertTrue(unpacked ~= nil and unpacked.remoteKarts ~= nil, "unpacked remoteKarts")
		local rk = (unpacked :: any).remoteKarts[1]
		assertTrue(rk.isExploding == true, "isExploding round-trip true")
		assertTrue(rk.isSquashed == false, "isSquashed round-trip false")
	end,
})

return tests
