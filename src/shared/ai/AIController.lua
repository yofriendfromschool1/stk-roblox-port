--!strict
-- src/shared/ai/AIController.lua
-- SPDX-License-Identifier: GPL-3.0-or-later
-- ported from src/karts/controller/ai_base_controller.cpp:L86-L216,
-- src/karts/controller/ai_base_lap_controller.cpp:L195-L240, and
-- src/karts/controller/skidding_ai.cpp:L469-L500, L2695-L2774 (STK 1.5)

local KartSolver = require("../sim/KartSolver")
local KartTuning = require("../KartTuning")
local Math3D = require("../sim/Math3D")

type Vec3 = Math3D.Vec3

export type DrivelinePoint = {
	x: number,
	z: number,
}

export type AIState = {
	trackNodeIdx: number,
	lap: number,
	checkpoint: number,
	lapDistance: number,
	totalDistance: number,
	passedMidpoint: boolean,
	prevSteer: number,
	lastLookaheadDistM: number,
}

export type NetAIState = {
	trackNodeIdx: number,
	lap: number,
	checkpoint: number,
	lapDistance: number,
	totalDistance: number,
	passedMidpoint: boolean,
	prevSteer: number,
}

local AIController = {}

local function normalizeAngle(angle: number): number
	local a = angle % (2.0 * math.pi)
	if a > math.pi then
		a -= 2.0 * math.pi
	elseif a < -math.pi then
		a += 2.0 * math.pi
	end
	return a
end

local function wrapIdx(idx: number, n: number): number
	return ((idx - 1) % n) + 1
end

local function buildCumDistances(points: { DrivelinePoint }): ({ number }, number)
	local n = #points
	local cum: { number } = table.create(n, 0.0)
	local total = 0.0
	for i = 1, n do
		cum[i] = total
		local p0 = points[i]
		local p1 = points[wrapIdx(i + 1, n)]
		total += math.sqrt((p1.x - p0.x) ^ 2 + (p1.z - p0.z) ^ 2)
	end
	return cum, total
end

function AIController.computeTotalLapLength(points: { DrivelinePoint }): number
	local _, total = buildCumDistances(points)
	return total
end

local function findNearestNode(pos: Vec3, points: { DrivelinePoint }, hintIdx: number?): (number, number)
	local n = #points
	if n == 0 then
		return 1, 0.0
	end
	local bestIdx = 1
	local bestDistSq = math.huge
	if hintIdx ~= nil and hintIdx >= 1 and hintIdx <= n then
		for offset = -3, 10 do
			local idx = wrapIdx(hintIdx + offset, n)
			local pt = points[idx]
			local d2 = (pt.x - pos.x) ^ 2 + (pt.z - pos.z) ^ 2
			if d2 < bestDistSq then
				bestDistSq = d2
				bestIdx = idx
			end
		end
	end
	if bestDistSq > (25.0 * 25.0) or hintIdx == nil then
		bestDistSq = math.huge
		for idx = 1, n do
			local pt = points[idx]
			local d2 = (pt.x - pos.x) ^ 2 + (pt.z - pos.z) ^ 2
			if d2 < bestDistSq then
				bestDistSq = d2
				bestIdx = idx
			end
		end
	end
	return bestIdx, math.sqrt(bestDistSq)
end

local function computeLapDistanceAtNode(pos: Vec3, points: { DrivelinePoint }, nodeIdx: number): (number, number)
	local n = #points
	if n == 0 then
		return 0.0, 0.0
	end
	local cum, totalLen = buildCumDistances(points)
	local p0 = points[nodeIdx]
	local p1 = points[wrapIdx(nodeIdx + 1, n)]
	local sx = p1.x - p0.x
	local sz = p1.z - p0.z
	local segLenSq = sx * sx + sz * sz
	local along = 0.0
	if segLenSq > 1e-8 then
		local t = math.clamp(((pos.x - p0.x) * sx + (pos.z - p0.z) * sz) / segLenSq, 0.0, 1.0)
		along = t * math.sqrt(segLenSq)
	end
	return cum[nodeIdx] + along, totalLen
end

function AIController.createState(points: { DrivelinePoint }, initialPos: Vec3): AIState
	local startIdx = findNearestNode(initialPos, points, nil)
	local lapDist, _ = computeLapDistanceAtNode(initialPos, points, startIdx)
	local n = math.max(1, #points)
	return {
		trackNodeIdx = startIdx,
		lap = 0,
		checkpoint = math.floor(((startIdx - 1) * 4) / n),
		lapDistance = lapDist,
		totalDistance = lapDist,
		passedMidpoint = false,
		prevSteer = 0.0,
		lastLookaheadDistM = KartTuning.ai.lookaheadMinM,
	}
end

function AIController.captureNet(ai: AIState): NetAIState
	return {
		trackNodeIdx = ai.trackNodeIdx,
		lap = ai.lap,
		checkpoint = ai.checkpoint,
		lapDistance = ai.lapDistance,
		totalDistance = ai.totalDistance,
		passedMidpoint = ai.passedMidpoint,
		prevSteer = ai.prevSteer,
	}
end

function AIController.applyNet(ai: AIState, snap: NetAIState)
	ai.trackNodeIdx = snap.trackNodeIdx
	ai.lap = snap.lap
	ai.checkpoint = snap.checkpoint
	ai.lapDistance = snap.lapDistance
	ai.totalDistance = snap.totalDistance
	ai.passedMidpoint = snap.passedMidpoint
	ai.prevSteer = snap.prevSteer
end

-- Update sector index, checkpoint, and wrap-around lap counter along the closed driveline
-- (src/karts/controller/ai_base_lap_controller.cpp:L200-L220).
function AIController.updateProgress(ai: AIState, pos: Vec3, points: { DrivelinePoint })
	local n = #points
	if n < 2 then
		return
	end
	local prevIdx = ai.trackNodeIdx
	local nextIdx, _ = findNearestNode(pos, points, prevIdx)
	ai.trackNodeIdx = nextIdx

	local midLo = math.floor(n * 0.35)
	local midHi = math.floor(n * 0.75)
	if nextIdx >= midLo and nextIdx <= midHi then
		ai.passedMidpoint = true
	end
	if prevIdx > math.floor(n * 0.75) and nextIdx <= math.max(2, math.floor(n * 0.25)) and ai.passedMidpoint then
		ai.lap += 1
		ai.passedMidpoint = false
	end

	local lapDist, totalLen = computeLapDistanceAtNode(pos, points, nextIdx)
	ai.lapDistance = lapDist
	ai.checkpoint = math.floor(((nextIdx - 1) * 4) / n)
	ai.totalDistance = ai.lap * totalLen + lapDist
end

-- Stateless track progress lookup for any racer (player or remote) on the closed loop.
function AIController.computeTrackProgress(pos: Vec3, points: { DrivelinePoint }): (number, number)
	local nodeIdx, _ = findNearestNode(pos, points, nil)
	local lapDist, _ = computeLapDistanceAtNode(pos, points, nodeIdx)
	return nodeIdx, lapDist
end

-- Speed-scaled lookahead target selection along closed driveline with sharp-turn guard
-- (src/karts/controller/skidding_ai.cpp:L469-L500, L2695-L2774).
function AIController.selectLookaheadPoint(
	ai: AIState,
	kartState: KartSolver.KartState,
	points: { DrivelinePoint }
): Vec3
	local n = #points
	if n == 0 then
		return { x = kartState.pos.x, y = kartState.pos.y, z = kartState.pos.z + 10.0 }
	end
	local cfg = KartTuning.ai
	local lookaheadDist =
		math.clamp(math.abs(kartState.speed) * cfg.lookaheadTimeSec, cfg.lookaheadMinM, cfg.lookaheadMaxM)
	ai.lastLookaheadDistM = lookaheadDist

	local idx = wrapIdx(ai.trackNodeIdx, n)
	local pCurr = points[idx]
	local pNext = points[wrapIdx(idx + 1, n)]
	local prevAngle = math.atan2(pNext.x - pCurr.x, pNext.z - pCurr.z)

	local accum = 0.0
	for _ = 1, n do
		local nextIdx = wrapIdx(idx + 1, n)
		local nextNextIdx = wrapIdx(nextIdx + 1, n)
		local a = points[idx]
		local b = points[nextIdx]
		local c = points[nextNextIdx]
		local segLen = math.sqrt((b.x - a.x) ^ 2 + (b.z - a.z) ^ 2)

		local nextAngle = math.atan2(c.x - b.x, c.z - b.z)
		if math.abs(normalizeAngle(nextAngle - prevAngle)) > cfg.sharpCurveAngleRad then
			return { x = b.x, y = kartState.pos.y, z = b.z }
		end

		if accum + segLen >= lookaheadDist and segLen > 1e-6 then
			local frac = math.clamp((lookaheadDist - accum) / segLen, 0.0, 1.0)
			return {
				x = a.x + (b.x - a.x) * frac,
				y = kartState.pos.y,
				z = a.z + (b.z - a.z) * frac,
			}
		end
		accum += segLen
		prevAngle = nextAngle
		idx = nextIdx
	end

	local fallback = points[wrapIdx(ai.trackNodeIdx + 1, n)]
	return { x = fallback.x, y = kartState.pos.y, z = fallback.z }
end

-- Ported from AIBaseController::steerToPoint (src/karts/controller/ai_base_controller.cpp:L86-L150).
function AIController.steerToPoint(kartState: KartSolver.KartState, aimPoint: Vec3): number
	local cfg = KartTuning.ai
	local maxSteer = KartSolver.getMaxSteerAngle(kartState.profile, math.abs(kartState.speed))
	local lc = Math3D.quatRotateVec(Math3D.quatConjugate(kartState.rot), Math3D.sub(aimPoint, kartState.pos))

	if math.abs(lc.x) > math.abs(lc.z) or lc.z <= 0.0 then
		local sign = if lc.x >= 0.0 then 1.0 else -1.0
		return sign * (maxSteer * cfg.skiddingThreshold + 0.1)
	end
	if math.abs(lc.x) < 1e-6 then
		return 0.0
	end

	local radius = (lc.x * lc.x + lc.z * lc.z) / (2.0 * lc.x)
	local sinSteer = kartState.profile.wheelBase / radius
	if sinSteer <= -1.0 then
		return -maxSteer * cfg.skiddingThreshold - 0.1
	elseif sinSteer >= 1.0 then
		return maxSteer * cfg.skiddingThreshold + 0.1
	end
	return math.asin(sinSteer) * cfg.oversteerFactor
end

-- Ported from SkiddingAI::handleSteering + AIBaseController::setSteering
-- (skidding_ai.cpp:L469-L500, ai_base_controller.cpp:L185-L216).
function AIController.computeInput(
	ai: AIState,
	kartState: KartSolver.KartState,
	points: { DrivelinePoint },
	dt: number,
	targetSpeedMps: number?
): KartSolver.KartInput
	AIController.updateProgress(ai, kartState.pos, points)
	local aimPoint = AIController.selectLookaheadPoint(ai, kartState, points)
	local rawAngle = AIController.steerToPoint(kartState, aimPoint)

	local maxSteer = math.max(1e-4, KartSolver.getMaxSteerAngle(kartState.profile, math.abs(kartState.speed)))
	local steerFraction = math.clamp(rawAngle / maxSteer, -1.0, 1.0)
	local cfg = KartTuning.ai
	if kartState.itemEffect.plungerFaceTicks > 0 then
		steerFraction = math.clamp(steerFraction, -cfg.plungerSteerCap, cfg.plungerSteerCap)
	end

	local maxChange = dt / cfg.timeFullSteer
	local nextSteer: number
	if ai.prevSteer < steerFraction then
		nextSteer = math.min(steerFraction, ai.prevSteer + maxChange)
	else
		nextSteer = math.max(steerFraction, ai.prevSteer - maxChange)
	end
	ai.prevSteer = nextSteer

	local cruiseTarget = targetSpeedMps or cfg.defaultCruiseSpeedMps
	local accel = if kartState.speed < cruiseTarget then 0.85 else 0.0
	if math.abs(nextSteer) > 0.85 and kartState.speed > cruiseTarget * 0.75 then
		accel = math.min(accel, 0.5)
	end

	return {
		accel = accel,
		brake = false,
		steer = nextSteer,
		drift = false,
		nitro = false,
		fire = false,
		lookBack = false,
	}
end

return table.freeze(AIController)
