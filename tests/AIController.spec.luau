--!strict
-- tests/AIController.spec.luau
-- SPDX-License-Identifier: GPL-3.0-or-later

local AIController = require("../src/shared/ai/AIController")
local GreyboxArenaData = require("../src/shared/track/GreyboxArenaData")
local ItemTuning = require("../src/shared/ItemTuning")
local KartSolver = require("../src/shared/sim/KartSolver")
local KartTuning = require("../src/shared/KartTuning")
local MaxSpeed = require("../src/shared/kart/MaxSpeed")

local function assertTrue(cond: boolean, msg: string)
	if not cond then
		error(msg, 2)
	end
end

return {
	{
		name = "AI triggers real Skidding via skidControl on sustained curves at high difficulty",
		fn = function()
			local pts = GreyboxArenaData.drivelineQuadCenters
			local prof = KartTuning.buildProfile("medium", "best")
			local ks = KartSolver.createState(prof, { x = pts[1].x, y = 0.4, z = pts[1].z }, math.pi * 0.5)
			ks.speed = 22.0
			ks.isOnGround = true
			local ai = AIController.createState(pts, ks.pos, 42)
			local sawSkid = false
			for _ = 1, 240 do
				local inp = AIController.computeInput(ai, ks, pts, 1 / 120, nil, {
					difficulty = "best",
					distToPlayer = 0.0,
					aiPos = 1,
					numAi = 1,
				})
				if inp.skidControl == "LEFT" or inp.skidControl == "RIGHT" then
					sawSkid = true
					assertTrue(inp.drift == true, "drift must match skidControl")
					break
				end
				-- Advance node along curve
				ai.trackNodeIdx = (ai.trackNodeIdx % #pts) + 1
				local p = pts[ai.trackNodeIdx]
				local pNext = pts[(ai.trackNodeIdx % #pts) + 1]
				ks.pos = { x = p.x, y = 0.4, z = p.z }
				local yaw = math.atan2(pNext.x - p.x, pNext.z - p.z)
				ks.rot = { w = math.cos(yaw * 0.5), x = 0, y = math.sin(yaw * 0.5), z = 0 }
			end
			assertTrue(sawSkid, "expected best AI to trigger skidControl on curve")
		end,
	},
	{
		name = "AI applies MS_DECREASE_AI speed cap and fires items / uses nitro per skill",
		fn = function()
			local pts = GreyboxArenaData.drivelineQuadCenters
			local profEasy = KartTuning.buildProfile("medium", "novice")
			local ksEasy = KartSolver.createState(profEasy, { x = pts[1].x, y = 0.4, z = pts[1].z }, math.pi * 0.5)
			local aiEasy = AIController.createState(pts, ksEasy.pos, 7)
			AIController.computeInput(aiEasy, ksEasy, pts, 1 / 120, nil, {
				difficulty = "novice",
				distToPlayer = 100.0,
				aiPos = 1,
				numAi = 1,
			})
			MaxSpeed.update(ksEasy.maxSpeedState, 1, true)
			assertTrue(MaxSpeed.isSpeedDecreaseActive(ksEasy.maxSpeedState, "AI"), "AI slowdown active")
			assertTrue(
				ksEasy.maxSpeedState.currentMaxSpeed < profEasy.maxSpeed,
				"novice AI ahead of player is speed-capped"
			)

			local profBest = KartTuning.buildProfile("medium", "best")
			local ksBest = KartSolver.createState(profBest, { x = pts[1].x, y = 0.4, z = pts[1].z }, math.pi * 0.5)
			ksBest.isOnGround = true
			ksBest.speed = 24.0
			ksBest.nitro.energy = 12.0
			ksBest.heldPowerup = ItemTuning.POWERUP_BOWLING
			ksBest.heldPowerupCount = 1
			local aiBest = AIController.createState(pts, ksBest.pos, 9)
			aiBest.timeSinceLastShot = 10.0
			local inpBest = AIController.computeInput(aiBest, ksBest, pts, 1 / 120, nil, {
				difficulty = "best",
				distToPlayer = 0.0,
				nearestAheadDist = 7.0,
				aheadAngleAbs = 0.05,
			})
			assertTrue(inpBest.nitro == true, "best AI uses nitro when grounded with reserve > 8")
			assertTrue(inpBest.fire == true, "best AI fires bowling ball at close aligned opponent")
		end,
	},
	{
		name = "AI seeks nearby nitro containers and gates nitro usage by difficulty",
		fn = function()
			local pts = GreyboxArenaData.drivelineQuadCenters
			local p0 = pts[1]
			local p1 = pts[2]
			local yaw = math.atan2(p1.x - p0.x, p1.z - p0.z)
			local fwdX = math.sin(yaw)
			local fwdZ = math.cos(yaw)
			local rightX = math.cos(yaw)
			local rightZ = -math.sin(yaw)
			local itemPos = { x = p0.x + fwdX * 14.0 + rightX * 2.5, y = 0.4, z = p0.z + fwdZ * 14.0 + rightZ * 2.5 }
			local fakeWorld = {
				items = {
					{ id = 1, itemType = "big-nitro", pos = itemPos, ticksTillReturn = 0, deactiveTicks = 0 },
				},
			}

			local prof = KartTuning.buildProfile("medium", "best")
			local ks = KartSolver.createState(prof, { x = p0.x, y = 0.4, z = p0.z }, yaw)
			ks.isOnGround = true
			ks.speed = 20.0
			local ai = AIController.createState(pts, ks.pos, 11)
			local aim = AIController.selectLookaheadPoint(ai, ks, pts, nil, {
				difficulty = "best",
				itemWorld = fakeWorld,
			})
			assertTrue(
				math.abs(aim.x - itemPos.x) < 0.01 and math.abs(aim.z - itemPos.z) < 0.01,
				"AI aims at nearby active big-nitro container"
			)

			-- Easy AI never uses nitro even with full tank
			local profEasy = KartTuning.buildProfile("medium", "novice")
			local ksEasy = KartSolver.createState(profEasy, { x = p0.x, y = 0.4, z = p0.z }, yaw)
			ksEasy.isOnGround = true
			ksEasy.nitro.energy = 15.0
			local aiEasy = AIController.createState(pts, ksEasy.pos, 13)
			local inpEasy = AIController.computeInput(aiEasy, ksEasy, pts, 1 / 120, nil, { difficulty = "novice" })
			assertTrue(inpEasy.nitro == false, "novice AI must not activate nitro")
		end,
	},
}
