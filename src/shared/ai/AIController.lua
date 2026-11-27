--!strict
-- src/shared/ai/AIController.lua
-- SPDX-License-Identifier: GPL-3.0-or-later
-- ported from src/karts/controller/ai_base_controller.cpp:L86-L216,
-- src/karts/controller/ai_base_lap_controller.cpp:L195-L240,
-- src/karts/controller/ai_properties.cpp:L128-L136, and
-- src/karts/controller/skidding_ai.cpp:L330-L500, L1081-L1741, L1989-L2450, L2695-L3120 (STK 1.5)

local ItemTuning = require("../ItemTuning")
local KartSolver = require("../sim/KartSolver")
local KartTuning = require("../KartTuning")
local Math3D = require("../sim/Math3D")
local MaxSpeed = require("../kart/MaxSpeed")
local Skidding = require("../kart/Skidding")

type Vec3 = Math3D.Vec3

export type DrivelinePoint = {
	x: number,
	y: number?,
	z: number,
}

export type DrivelineBranch = {
	fromQuad: number,
	toQuad: number,
	points: { DrivelinePoint },
}

export type RouteGraph = {
	mainCount: number,
	totalNodes: number,
	nodes: { DrivelinePoint },
	successors: { { number } },
	isBranch: { boolean },
	mainEquiv: { number },
	cumDistances: { number },
	totalMainLength: number,
}

export type AIContext = {
	difficulty: string?,
	distToPlayer: number?,
	aiPos: number?,
	numAi: number?,
	nearestAheadDist: number?,
	nearestBehindDist: number?,
	aheadAngleAbs: number?,
	behindAngleAbs: number?,
	aheadInvuln: boolean?,
	behindInvuln: boolean?,
	aheadHasShield: boolean?,
	incomingThreat: boolean?,
	applySpeedCap: boolean?,
	itemWorld: any?,
	lapsRemaining: number?,
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
	skidProbState: number, -- 0: NOT_YET, 1: SKID, 2: NO_SKID
	timeSinceLastShot: number,
	lastUsedPowerup: number,
	rngState: number,
	curveDir: number, -- -1 left, 0 straight, +1 right
	curveRadius: number,
	curveLastNode: number,
	curveAngleRad: number,
	lateralOffsetM: number,
	plannedShortcut: boolean,
	usedShortcutThisLap: boolean,
	lastRoute: string,
	completedRoutes: { string },
	nextNodeIndex: { number },
	nextNodeChoices: { [number]: number },
}

export type NetAIState = {
	trackNodeIdx: number,
	lap: number,
	checkpoint: number,
	lapDistance: number,
	totalDistance: number,
	passedMidpoint: boolean,
	prevSteer: number,
	rngState: number,
	lateralOffsetM: number,
	plannedShortcut: boolean,
	usedShortcutThisLap: boolean,
	lastRoute: string,
	nextNodeIndex: { number },
	nextNodeChoices: { [number]: number },
}

local SKID_PROBAB_NOT_YET = 0
local SKID_PROBAB_SKID = 1
local SKID_PROBAB_NO_SKID = 2

local DEFAULT_ROAD_HALF_WIDTH_M = 5.5

local AIController = {}

local function nextRand01(ai: AIState, kartState: KartSolver.KartState?): number
	if kartState ~= nil then
		local r = KartSolver.nextRand01(kartState)
		ai.rngState = kartState.rngState
		return r
	end
	ai.rngState = (ai.rngState * 1664525 + 1013904223) % 4294967296
	return ai.rngState / 4294967296
end

local function coerceSeed(seed: number?): number
	if type(seed) ~= "number" or seed ~= seed then
		return 135792468
	end
	local s = math.floor(math.abs(seed)) % 4294967296
	if s == 0 then
		return 135792468
	end
	return s
end

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

local function evalPiecewise(points: { { number } }, x: number): number
	local count = #points
	if count == 0 then
		return 1.0
	end
	if x <= points[1][1] then
		return points[1][2]
	end
	for i = 2, count do
		local x0, y0 = points[i - 1][1], points[i - 1][2]
		local x1, y1 = points[i][1], points[i][2]
		if x <= x1 then
			local span = x1 - x0
			if math.abs(span) < 1e-6 then
				return y1
			end
			local t = (x - x0) / span
			return y0 + (y1 - y0) * t
		end
	end
	return points[count][2]
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

local graphCache: { [any]: { [any]: RouteGraph } } = {}
local NO_BRANCH_KEY = newproxy(false)

local function buildRouteGraph(points: { DrivelinePoint }, branches: { DrivelineBranch }?): RouteGraph
	local bKey: any = if branches ~= nil then branches else NO_BRANCH_KEY
	local byPts = graphCache[points]
	if byPts ~= nil and byPts[bKey] ~= nil then
		return byPts[bKey]
	end

	local mainCount = #points
	local cum, totalMain = buildCumDistances(points)
	local nodes: { DrivelinePoint } = table.create(mainCount)
	local successors: { { number } } = table.create(mainCount)
	local isBranch: { boolean } = table.create(mainCount)
	local mainEquiv: { number } = table.create(mainCount)

	for i = 1, mainCount do
		nodes[i] = points[i]
		isBranch[i] = false
		mainEquiv[i] = i
		successors[i] = if mainCount > 0 then { wrapIdx(i + 1, mainCount) } else { 1 }
	end

	if branches ~= nil and mainCount >= 2 then
		for _, br in branches do
			local bPts = br.points
			local bLen = #bPts
			if bLen > 0 then
				local fromIdx = math.clamp(br.fromQuad + 1, 1, mainCount)
				local toIdx = math.clamp(br.toQuad + 1, 1, mainCount)
				local spanEquiv = (toIdx - fromIdx) % mainCount
				local startNodeIdx = #nodes + 1
				table.insert(successors[fromIdx], startNodeIdx)
				for j = 1, bLen do
					local idx = #nodes + 1
					nodes[idx] = bPts[j]
					isBranch[idx] = true
					local frac = j / (bLen + 1)
					local eq = fromIdx + spanEquiv * frac
					if eq > mainCount then
						eq = ((eq - 1) % mainCount) + 1
					end
					mainEquiv[idx] = eq
					if j < bLen then
						successors[idx] = { idx + 1 }
					else
						successors[idx] = { toIdx }
					end
				end
			end
		end
	end

	local g: RouteGraph = {
		mainCount = mainCount,
		totalNodes = #nodes,
		nodes = nodes,
		successors = successors,
		isBranch = isBranch,
		mainEquiv = mainEquiv,
		cumDistances = cum,
		totalMainLength = totalMain,
	}
	if byPts == nil then
		byPts = {}
		graphCache[points] = byPts
	end
	byPts[bKey] = g
	return g
end

local function findNearestNode(
	pos: Vec3,
	graph: RouteGraph,
	hintIdx: number?,
	nextNodeIndex: { number }?
): (number, number)
	local total = graph.totalNodes
	if total == 0 then
		return 1, 0.0
	end
	local nodes = graph.nodes
	local bestIdx = 1
	local bestDistSq = math.huge

	if hintIdx ~= nil and hintIdx >= 1 and hintIdx <= total then
		local function testNode(idx: number)
			local pt = nodes[idx]
			if pt == nil then
				return
			end
			local d2 = (pt.x - pos.x) ^ 2 + (pt.z - pos.z) ^ 2
			if d2 < bestDistSq then
				bestDistSq = d2
				bestIdx = idx
			end
		end

		testNode(hintIdx)
		-- Backward small window along main/hint
		if hintIdx <= graph.mainCount then
			for off = -3, -1 do
				testNode(wrapIdx(hintIdx + off, graph.mainCount))
			end
		else
			for off = -3, -1 do
				local cand = hintIdx + off
				if cand >= 1 then
					testNode(cand)
				end
			end
		end

		-- Forward walk along chosen nextNodeIndex + fork successors
		local walk = hintIdx
		for _ = 1, 14 do
			local succList = graph.successors[walk]
			if succList ~= nil then
				for _, sIdx in succList do
					testNode(sIdx)
				end
			end
			local rawNxt: number? = if nextNodeIndex ~= nil then nextNodeIndex[walk] else nil
			local nxt: number = if rawNxt ~= nil
				then rawNxt
				elseif succList ~= nil and succList[1] ~= nil then succList[1]
				else walk
			testNode(nxt)
			walk = nxt
		end
	end

	if bestDistSq > (25.0 * 25.0) or hintIdx == nil then
		bestDistSq = math.huge
		for idx = 1, total do
			local pt = nodes[idx]
			local d2 = (pt.x - pos.x) ^ 2 + (pt.z - pos.z) ^ 2
			if d2 < bestDistSq then
				bestDistSq = d2
				bestIdx = idx
			end
		end
	end
	return bestIdx, math.sqrt(bestDistSq)
end

local function computeLapDistanceAtNode(pos: Vec3, graph: RouteGraph, nodeIdx: number): (number, number)
	local mainN = graph.mainCount
	if mainN == 0 then
		return 0.0, 0.0
	end
	if nodeIdx > mainN then
		local eq = graph.mainEquiv[nodeIdx] or 1.0
		local baseIdx = math.clamp(math.floor(eq), 1, mainN)
		local nextIdx = wrapIdx(baseIdx + 1, mainN)
		local d0 = graph.cumDistances[baseIdx]
		local d1 = if nextIdx > baseIdx then graph.cumDistances[nextIdx] else graph.totalMainLength
		local frac = eq - baseIdx
		return d0 + (d1 - d0) * frac, graph.totalMainLength
	end
	local p0 = graph.nodes[nodeIdx]
	local p1 = graph.nodes[wrapIdx(nodeIdx + 1, mainN)]
	local sx = p1.x - p0.x
	local sz = p1.z - p0.z
	local segLenSq = sx * sx + sz * sz
	local along = 0.0
	if segLenSq > 1e-8 then
		local t = math.clamp(((pos.x - p0.x) * sx + (pos.z - p0.z) * sz) / segLenSq, 0.0, 1.0)
		along = t * math.sqrt(segLenSq)
	end
	return graph.cumDistances[nodeIdx] + along, graph.totalMainLength
end

-- Ported from AIBaseLapController::computePath (src/karts/controller/ai_base_lap_controller.cpp:L141-L192),
-- extended with difficulty-weighted shortcut preference and deterministic per-kart lateral lane offset.
function AIController.computePath(
	ai: AIState,
	kartState: KartSolver.KartState?,
	points: { DrivelinePoint },
	branches: { DrivelineBranch }?,
	difficulty: string?
)
	local graph = buildRouteGraph(points, branches)
	local normDiff =
		KartTuning.normalizeDifficulty(difficulty or (if kartState ~= nil then kartState.profile.difficulty else nil))
	local props = KartTuning.aiByDifficulty[normDiff] or KartTuning.aiByDifficulty.best
	local shortcutProb = props.shortcutProb or 0.5

	local nextIdx: { number } = table.create(graph.totalNodes)
	local choices: { [number]: number } = {}
	local tookShortcut = false
	for i = 1, graph.totalNodes do
		local succs = graph.successors[i]
		if #succs <= 1 then
			nextIdx[i] = succs[1] or i
		else
			local u = nextRand01(ai, kartState)
			local choiceIdx = if u < shortcutProb then 2 else 1
			nextIdx[i] = succs[choiceIdx]
			choices[i] = choiceIdx
			if choiceIdx > 1 then
				tookShortcut = true
			end
		end
	end
	ai.nextNodeIndex = nextIdx
	ai.nextNodeChoices = choices
	ai.plannedShortcut = tookShortcut

	local uLat = nextRand01(ai, kartState)
	ai.lateralOffsetM = (uLat * 2.0 - 1.0) * KartTuning.ai.maxMainLateralOffsetM
end

function AIController.createState(
	points: { DrivelinePoint },
	initialPos: Vec3,
	rngSeed: number?,
	branches: { DrivelineBranch }?,
	difficulty: string?
): AIState
	local graph = buildRouteGraph(points, branches)
	local startIdx = findNearestNode(initialPos, graph, nil, nil)
	local lapDist, _ = computeLapDistanceAtNode(initialPos, graph, startIdx)
	local n = math.max(1, graph.mainCount)
	local ai: AIState = {
		trackNodeIdx = startIdx,
		lap = 0,
		checkpoint = math.floor(((startIdx - 1) * 4) / n),
		lapDistance = lapDist,
		totalDistance = lapDist,
		passedMidpoint = false,
		prevSteer = 0.0,
		lastLookaheadDistM = KartTuning.ai.lookaheadMinM,
		skidProbState = SKID_PROBAB_NOT_YET,
		timeSinceLastShot = 0.0,
		lastUsedPowerup = ItemTuning.POWERUP_NONE,
		rngState = coerceSeed(rngSeed),
		curveDir = 0,
		curveRadius = 1000.0,
		curveLastNode = startIdx,
		curveAngleRad = 0.0,
		lateralOffsetM = 0.0,
		plannedShortcut = false,
		usedShortcutThisLap = false,
		lastRoute = "MAIN",
		completedRoutes = {},
		nextNodeIndex = {},
		nextNodeChoices = {},
	}
	AIController.computePath(ai, nil, points, branches, difficulty)
	return ai
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
		rngState = ai.rngState,
		lateralOffsetM = ai.lateralOffsetM,
		plannedShortcut = ai.plannedShortcut,
		usedShortcutThisLap = ai.usedShortcutThisLap,
		lastRoute = ai.lastRoute,
		nextNodeIndex = table.clone(ai.nextNodeIndex),
		nextNodeChoices = table.clone(ai.nextNodeChoices),
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
	ai.rngState = coerceSeed(snap.rngState)
	ai.lateralOffsetM = snap.lateralOffsetM
	ai.plannedShortcut = snap.plannedShortcut
	ai.usedShortcutThisLap = snap.usedShortcutThisLap
	ai.lastRoute = snap.lastRoute
	ai.nextNodeIndex = table.clone(snap.nextNodeIndex)
	ai.nextNodeChoices = table.clone(snap.nextNodeChoices)
end

-- Ported from AIProperties::getSpeedCap (src/karts/controller/ai_properties.cpp:L128-L136).
function AIController.computeSpeedCap(difficulty: string?, distToPlayer: number, aiPos: number, numAi: number): number
	local normDiff = KartTuning.normalizeDifficulty(difficulty)
	local props = KartTuning.aiByDifficulty[normDiff] or KartTuning.aiByDifficulty.best
	local wfirst = 1.0
	if numAi >= 2 then
		wfirst = 1.0 - ((aiPos - 1) / (numAi - 1))
	end
	local firstCap = evalPiecewise(props.firstSpeedCap, distToPlayer)
	local lastCap = evalPiecewise(props.lastSpeedCap, distToPlayer)
	return wfirst * firstCap + (1.0 - wfirst) * lastCap
end

-- Update sector index, checkpoint, and wrap-around lap counter along the branching driveline
-- (src/karts/controller/ai_base_lap_controller.cpp:L124-L130, L200-L220).
function AIController.updateProgress(
	ai: AIState,
	pos: Vec3,
	points: { DrivelinePoint },
	branches: { DrivelineBranch }?,
	difficulty: string?,
	kartState: KartSolver.KartState?
)
	local graph = buildRouteGraph(points, branches)
	local n = graph.mainCount
	if n < 2 then
		return
	end
	if #ai.nextNodeIndex ~= graph.totalNodes then
		AIController.computePath(ai, kartState, points, branches, difficulty)
	end

	local prevIdx = ai.trackNodeIdx
	local nextIdx, _ = findNearestNode(pos, graph, prevIdx, ai.nextNodeIndex)
	ai.trackNodeIdx = nextIdx
	if nextIdx > n then
		ai.usedShortcutThisLap = true
	end

	local prevEquiv = graph.mainEquiv[prevIdx] or 1
	local nextEquiv = graph.mainEquiv[nextIdx] or 1
	local midLo = math.floor(n * 0.35)
	local midHi = math.floor(n * 0.75)
	if nextEquiv >= midLo and nextEquiv <= midHi then
		ai.passedMidpoint = true
	end
	if prevEquiv > math.floor(n * 0.75) and nextEquiv <= math.max(2, math.floor(n * 0.25)) and ai.passedMidpoint then
		local routeTag = if ai.usedShortcutThisLap then "SHORTCUT" else "MAIN"
		ai.lastRoute = routeTag
		table.insert(ai.completedRoutes, routeTag)
		ai.usedShortcutThisLap = false
		ai.lap += 1
		ai.passedMidpoint = false
		AIController.computePath(ai, kartState, points, branches, difficulty)
	end

	local lapDist, totalLen = computeLapDistanceAtNode(pos, graph, nextIdx)
	ai.lapDistance = lapDist
	ai.checkpoint = math.floor(((math.floor(nextEquiv) - 1) * 4) / n)
	ai.totalDistance = ai.lap * totalLen + lapDist
end

-- Stateless track progress lookup for any racer (player or remote) on the closed loop.
function AIController.computeTrackProgress(pos: Vec3, points: { DrivelinePoint }): (number, number)
	local graph = buildRouteGraph(points, nil)
	local nodeIdx, _ = findNearestNode(pos, graph, nil, nil)
	local lapDist, _ = computeLapDistanceAtNode(pos, graph, nodeIdx)
	return nodeIdx, lapDist
end

local function lateralDistToSegment(px: number, pz: number, a: DrivelinePoint, b: DrivelinePoint): number
	local sx = b.x - a.x
	local sz = b.z - a.z
	local lenSq = sx * sx + sz * sz
	if lenSq < 1e-8 then
		return math.sqrt((px - a.x) ^ 2 + (pz - a.z) ^ 2)
	end
	local t = math.clamp(((px - a.x) * sx + (pz - a.z) * sz) / lenSq, 0.0, 1.0)
	local cx = a.x + sx * t
	local cz = a.z + sz * t
	return math.sqrt((px - cx) ^ 2 + (pz - cz) ^ 2)
end

local function offsetPointLaterally(
	px: number,
	pz: number,
	dirX: number,
	dirZ: number,
	offsetM: number
): (number, number)
	local len = math.sqrt(dirX * dirX + dirZ * dirZ)
	if len < 1e-6 or math.abs(offsetM) < 1e-4 then
		return px, pz
	end
	-- Right-hand normal to (dirX, dirZ) in XZ
	local rx = dirZ / len
	local rz = -dirX / len
	return px + rx * offsetM, pz + rz * offsetM
end

-- Ported from SkiddingAI::findNonCrashingPoint + collectItems (src/karts/controller/skidding_ai.cpp:L625-L710, L2695-L2774).
function AIController.selectLookaheadPoint(
	ai: AIState,
	kartState: KartSolver.KartState,
	points: { DrivelinePoint },
	branches: { DrivelineBranch }?,
	ctx: AIContext?
): Vec3
	local graph = buildRouteGraph(points, branches)
	local n = graph.mainCount
	if n == 0 then
		return { x = kartState.pos.x, y = kartState.pos.y, z = kartState.pos.z + 10.0 }
	end
	if #ai.nextNodeIndex ~= graph.totalNodes then
		AIController.computePath(ai, kartState, points, branches, kartState.profile.difficulty)
	end
	local nodes = graph.nodes
	local nextMap = ai.nextNodeIndex
	local function nextOf(idx: number): number
		return nextMap[idx] or wrapIdx(idx + 1, n)
	end

	local cfg = KartTuning.ai
	local currIdx = math.clamp(ai.trackNodeIdx, 1, graph.totalNodes)
	local lastNode = nextOf(currIdx)
	local pCurr = nodes[currIdx]
	local pNext = nodes[lastNode]
	local baseAngle = math.atan2(pNext.x - pCurr.x, pNext.z - pCurr.z)

	local maxLane = if graph.isBranch[currIdx] then cfg.maxBranchLateralOffsetM else cfg.maxMainLateralOffsetM
	local curveAtten = math.clamp(1.0 - math.abs(ai.curveAngleRad) / 1.2, 0.25, 1.0)
	local laneOffset = math.clamp(ai.lateralOffsetM, -maxLane, maxLane) * curveAtten

	-- Off-road recovery: steer directly toward next driveline center (skidding_ai.cpp:L413-L417)
	local sideDist = lateralDistToSegment(kartState.pos.x, kartState.pos.z, pCurr, pNext)
	if sideDist > DEFAULT_ROAD_HALF_WIDTH_M + 0.5 then
		ai.lastLookaheadDistM = math.sqrt((pNext.x - kartState.pos.x) ^ 2 + (pNext.z - kartState.pos.z) ^ 2)
		return { x = pNext.x, y = kartState.pos.y, z = pNext.z }
	end

	-- Seek nitro containers safely on-road (skidding_ai.cpp:L625-L710)
	local normDiff = KartTuning.normalizeDifficulty(
		if ctx ~= nil and ctx.difficulty ~= nil then ctx.difficulty else kartState.profile.difficulty
	)
	local aiProps = KartTuning.aiByDifficulty[normDiff] or KartTuning.aiByDifficulty.best
	if
		ctx ~= nil
		and ctx.itemWorld ~= nil
		and type(ctx.itemWorld.items) == "table"
		and aiProps.nitroUsage >= 1
		and kartState.nitro.energy < kartState.profile.nitro.max * 0.9
		and math.abs(ai.curveAngleRad) < 0.55
	then
		local invRot = Math3D.quatConjugate(kartState.rot)
		local bestItemPos: Vec3? = nil
		local bestScore = math.huge
		for _, entry in ipairs(ctx.itemWorld.items) do
			if
				(entry.itemType == "big-nitro" or entry.itemType == "small-nitro")
				and (entry.ticksTillReturn or 0) <= 0
				and (entry.deactiveTicks or 0) <= 0
			then
				local lc = Math3D.quatRotateVec(invRot, Math3D.sub(entry.pos, kartState.pos))
				if lc.z >= 3.0 and lc.z <= 28.0 and math.abs(lc.x) <= 4.5 and math.abs(lc.y) <= 2.5 then
					local roadDist = lateralDistToSegment(entry.pos.x, entry.pos.z, pCurr, pNext)
					if roadDist <= DEFAULT_ROAD_HALF_WIDTH_M - 0.8 then
						local score = lc.z - (if entry.itemType == "big-nitro" then 6.0 else 0.0)
						if score < bestScore then
							bestScore = score
							bestItemPos = entry.pos
						end
					end
				end
			end
		end
		if bestItemPos ~= nil then
			ai.lastLookaheadDistM =
				math.sqrt((bestItemPos.x - kartState.pos.x) ^ 2 + (bestItemPos.z - kartState.pos.z) ^ 2)
			return { x = bestItemPos.x, y = kartState.pos.y, z = bestItemPos.z }
		end
	end

	local kartLength = math.max(1.2, kartState.profile.length)
	local halfWidth = kartState.profile.width * 0.5
	local maxSafeHalfRoad = DEFAULT_ROAD_HALF_WIDTH_M - halfWidth
	local speedLookaheadMax =
		math.clamp(math.abs(kartState.speed) * cfg.lookaheadTimeSec, cfg.lookaheadMinM, cfg.lookaheadMaxM)
	ai.lastLookaheadDistM = speedLookaheadMax
	local maxIter = math.min(18, math.max(2, graph.totalNodes - 2))
	local walkNode = currIdx
	local accum = 0.0

	for _ = 1, maxIter do
		local targetSector = nextOf(walkNode)
		local b = nodes[walkNode]
		local c = nodes[targetSector]
		local segLen = math.sqrt((c.x - b.x) ^ 2 + (c.z - b.z) ^ 2)
		local nextAngle = math.atan2(c.x - b.x, c.z - b.z)
		if math.abs(normalizeAngle(nextAngle - baseAngle)) > cfg.sharpCurveAngleRad then
			local ox, oz = offsetPointLaterally(c.x, c.z, c.x - b.x, c.z - b.z, laneOffset * 0.5)
			return { x = ox, y = kartState.pos.y, z = oz }
		end

		if accum + segLen >= speedLookaheadMax and segLen > 1e-6 then
			local frac = math.clamp((speedLookaheadMax - accum) / segLen, 0.0, 1.0)
			local px = b.x + (c.x - b.x) * frac
			local pz = b.z + (c.z - b.z) * frac
			local ox, oz = offsetPointLaterally(px, pz, c.x - b.x, c.z - b.z, laneOffset)
			return {
				x = ox,
				y = kartState.pos.y,
				z = oz,
			}
		end

		-- Chord road-width safety check (skidding_ai.cpp:L2752-L2768)
		local dx = c.x - kartState.pos.x
		local dz = c.z - kartState.pos.z
		local len = math.sqrt(dx * dx + dz * dz)
		local steps = math.clamp(math.floor(len / kartLength), 3, 40)
		if len > 1e-4 then
			local dirX = dx / len
			local dirZ = dz / len
			for stepIdx = 2, steps do
				local sx = kartState.pos.x + dirX * kartLength * stepIdx
				local sz = kartState.pos.z + dirZ * kartLength * stepIdx
				local minSegDist = math.huge
				local checkIdx = currIdx
				for _ = 1, maxIter do
					local nextCheck = nextOf(checkIdx)
					local d = lateralDistToSegment(sx, sz, nodes[checkIdx], nodes[nextCheck])
					if d < minSegDist then
						minSegDist = d
					end
					if nextCheck == targetSector then
						break
					end
					checkIdx = nextCheck
				end
				if minSegDist > maxSafeHalfRoad then
					local ox, oz = offsetPointLaterally(b.x, b.z, c.x - b.x, c.z - b.z, laneOffset * 0.5)
					return { x = ox, y = kartState.pos.y, z = oz }
				end
			end
		end

		accum += segLen
		baseAngle = nextAngle
		walkNode = targetSector
	end

	local fallback = nodes[walkNode]
	return { x = fallback.x, y = kartState.pos.y, z = fallback.z }
end

-- Ported from SkiddingAI::determineTrackDirection + handleCurve (skidding_ai.cpp:L2780-L2891).
local function updateTrackCurve(
	ai: AIState,
	kartState: KartSolver.KartState,
	points: { DrivelinePoint },
	branches: { DrivelineBranch }?
): number
	local graph = buildRouteGraph(points, branches)
	local n = graph.mainCount
	if n < 4 then
		ai.curveDir = 0
		ai.curveRadius = 1000.0
		ai.curveAngleRad = 0.0
		return 0.0
	end
	local nodes = graph.nodes
	local nextMap = ai.nextNodeIndex
	local function nextOf(idx: number): number
		return nextMap[idx] or wrapIdx(idx + 1, n)
	end

	local currIdx = math.clamp(ai.trackNodeIdx, 1, graph.totalNodes)
	local nextIdx = nextOf(currIdx)
	local p0 = nodes[currIdx]
	local p1 = nodes[nextIdx]
	local segAngle = math.atan2(p1.x - p0.x, p1.z - p0.z)

	-- Kart heading yaw from forward vector (+Z in STK local)
	local fwd = Math3D.quatRotateVec(kartState.rot, { x = 0, y = 0, z = 1 })
	local kartAngle = math.atan2(fwd.x, fwd.z)
	local angleToTrack = normalizeAngle(segAngle - kartAngle)

	-- Sum upcoming turn angles along the next ~18 segments to detect sustained left/right curve
	local totalTurn = 0.0
	local arcLen = 0.0
	local prevAng = segAngle
	local idx = nextIdx
	local firstSign = 0
	local lastCurveNode = nextIdx
	local straightGap = 0
	for _ = 1, math.min(18, math.max(2, graph.totalNodes - 2)) do
		local nIdx = nextOf(idx)
		local a = nodes[idx]
		local b = nodes[nIdx]
		local ang = math.atan2(b.x - a.x, b.z - a.z)
		local delta = normalizeAngle(ang - prevAng)
		local seg = math.sqrt((b.x - a.x) ^ 2 + (b.z - a.z) ^ 2)
		if math.abs(delta) > 0.015 then
			local sign = if delta > 0 then 1 else -1
			if firstSign == 0 then
				firstSign = sign
			end
			if sign == firstSign then
				totalTurn += delta
				arcLen += seg
				lastCurveNode = nIdx
				straightGap = 0
			else
				break
			end
		elseif firstSign ~= 0 then
			straightGap += 1
			arcLen += seg
			if straightGap > 2 then
				break
			end
		end
		prevAng = ang
		idx = nIdx
	end

	if firstSign == 0 or math.abs(totalTurn) < 0.22 then
		ai.curveDir = 0
		ai.curveRadius = 1000.0
		ai.curveAngleRad = 0.0
		ai.curveLastNode = nextIdx
	else
		ai.curveDir = firstSign
		ai.curveAngleRad = math.abs(totalTurn)
		ai.curveRadius = math.max(4.0, arcLen / math.max(0.1, ai.curveAngleRad))
		ai.curveLastNode = lastCurveNode
	end
	return angleToTrack
end

-- Ported from SkiddingAI::canSkid (src/karts/controller/skidding_ai.cpp:L2899-L3014).
local function canSkid(
	ai: AIState,
	kartState: KartSolver.KartState,
	steerFraction: number,
	wasSkidding: boolean
): boolean
	if math.abs(steerFraction) > 1.5 then
		if wasSkidding then
			return math.abs(steerFraction) < 2.5
		end
		return false
	end
	if ai.curveDir == 0 then
		return false
	end
	local speed = math.abs(kartState.speed)
	if speed < KartTuning.skid.minSpeed then
		return false
	end
	-- Estimated duration of the curve with STK's 1.5x heuristic (skidding_ai.cpp:L2964)
	local duration = 1.5 * (ai.curveRadius * ai.curveAngleRad) / math.max(speed, 1.0)
	if wasSkidding and duration < 0.65 then
		return false
	end
	if (steerFraction > 0.0 and ai.curveDir < 0) or (steerFraction < 0.0 and ai.curveDir > 0) then
		return false
	end
	return duration > KartTuning.skid.timeTillBonus[1]
end

-- Ported from AIBaseController::steerToPoint (src/karts/controller/ai_base_controller.cpp:L86-L150).
function AIController.steerToPoint(kartState: KartSolver.KartState, aimPoint: Vec3, skiddingThreshold: number?): number
	local cfg = KartTuning.ai
	local thresh = skiddingThreshold or cfg.skiddingThreshold
	local maxSteer = KartSolver.getMaxSteerAngle(kartState.profile, math.abs(kartState.speed))
	local lc = Math3D.quatRotateVec(Math3D.quatConjugate(kartState.rot), Math3D.sub(aimPoint, kartState.pos))

	if math.abs(lc.x) > math.abs(lc.z) or lc.z <= 0.0 then
		local sign = if lc.x >= 0.0 then 1.0 else -1.0
		return sign * (maxSteer * thresh + 0.1)
	end
	if math.abs(lc.x) < 1e-6 then
		return 0.0
	end

	local radius = (lc.x * lc.x + lc.z * lc.z) / (2.0 * lc.x)
	local sinSteer = kartState.profile.wheelBase / radius
	if sinSteer <= -1.0 then
		return -maxSteer * thresh - 0.1
	elseif sinSteer >= 1.0 then
		return maxSteer * thresh + 0.1
	end
	return math.asin(sinSteer) * cfg.oversteerFactor
end

-- Ported from SkiddingAI::handleItems (src/karts/controller/skidding_ai.cpp:L1081-L1284, L1600-L1671).
local function decideItemFire(
	ai: AIState,
	kartState: KartSolver.KartState,
	dt: number,
	itemSkill: number,
	ctx: AIContext
): (boolean, boolean)
	local ptype = kartState.heldPowerup
	if ptype == ItemTuning.POWERUP_NONE or kartState.itemEffect.effectType == 1 then
		return false, false
	end

	ai.timeSinceLastShot += dt
	if ptype ~= ai.lastUsedPowerup then
		ai.timeSinceLastShot = 50.0
	end

	if itemSkill <= 0 then
		return false, false
	elseif itemSkill == 1 then
		local waitSec = 5.0 + nextRand01(ai, kartState) * 5.0
		if ai.timeSinceLastShot > waitSec then
			ai.timeSinceLastShot = 0.0
			ai.lastUsedPowerup = ptype
			return true, false
		end
		return false, false
	end

	local shieldTicks = kartState.attachmentTicksLeft
	local hasShield = kartState.attachmentType == ItemTuning.ATTACHMENT_BUBBLEGUM_SHIELD and shieldTicks > 240
	local aheadDist = ctx.nearestAheadDist or 999.0
	local behindDist = ctx.nearestBehindDist or 999.0
	local aheadAng = ctx.aheadAngleAbs or 3.14
	local behindAng = ctx.behindAngleAbs or 3.14
	local fire = false
	local lookBack = false

	if ptype == ItemTuning.POWERUP_BUBBLEGUM then
		if itemSkill == 2 or ctx.incomingThreat or behindDist < 12.0 then
			fire = ai.timeSinceLastShot > 1.5
		end
	elseif ptype == ItemTuning.POWERUP_CAKE then
		if not hasShield and ((aheadDist < 45.0 and aheadAng < 0.35) or (behindDist < 20.0 and behindAng < 0.35)) then
			fire = ai.timeSinceLastShot > 2.5
			lookBack = behindDist < aheadDist and behindAng < 0.35
		end
	elseif ptype == ItemTuning.POWERUP_BOWLING then
		local delay = if itemSkill == 2 then 5.0 else 3.0
		if not hasShield and ai.timeSinceLastShot >= delay then
			local straightAhead = aheadAng < 0.2 and aheadDist < 10.0 and not (ctx.aheadInvuln == true)
			local straightBehind = behindAng < 0.2 and behindDist < 30.0 and not (ctx.behindInvuln == true)
			if itemSkill >= 4 and ctx.aheadHasShield then
				straightAhead = false
			end
			if straightAhead or straightBehind then
				fire = true
				lookBack = straightBehind and (not straightAhead or behindDist < aheadDist)
			end
		end
	elseif ptype == ItemTuning.POWERUP_PLUNGER then
		if not hasShield and ai.timeSinceLastShot >= 5.0 then
			local fb = (behindDist < aheadDist and behindDist < 30.0) or aheadDist > 120.0
			local dist = if fb then behindDist else aheadDist
			if dist < 30.0 or ai.timeSinceLastShot > 10.0 then
				fire = true
				lookBack = fb
			end
		end
	elseif ptype == ItemTuning.POWERUP_ZIPPER then
		fire = kartState.isOnGround and math.abs(ai.prevSteer) < 0.4 and ai.timeSinceLastShot > 1.0
	elseif ptype == ItemTuning.POWERUP_SWITCH then
		fire = ai.timeSinceLastShot > 3.0
	elseif ptype == ItemTuning.POWERUP_PARACHUTE then
		fire = ai.timeSinceLastShot > 3.5
	elseif ptype == ItemTuning.POWERUP_SWATTER then
		if not hasShield and (itemSkill == 2 or aheadDist < 8.0 or behindDist < 8.0) then
			fire = ai.timeSinceLastShot > 1.5
		end
	elseif ptype == ItemTuning.POWERUP_RUBBERBALL then
		if not hasShield and aheadDist < 180.0 then
			fire = ai.timeSinceLastShot > 2.0
		end
	end

	if fire then
		ai.timeSinceLastShot = 0.0
		ai.lastUsedPowerup = ptype
	end
	return fire, lookBack
end

-- Ported from SkiddingAI::handleSteering + handleAccelerationAndBraking + setSteering
-- (skidding_ai.cpp:L330-L500, L1989-L2068, L3029-L3120).
function AIController.computeInput(
	ai: AIState,
	kartState: KartSolver.KartState,
	points: { DrivelinePoint },
	dt: number,
	targetSpeedMps: number?,
	context: AIContext?,
	branches: { DrivelineBranch }?
): KartSolver.KartInput
	local ctx: AIContext = context or {}
	local normDiff = KartTuning.normalizeDifficulty(ctx.difficulty or kartState.profile.difficulty)
	local props = KartTuning.aiByDifficulty[normDiff] or KartTuning.aiByDifficulty.best

	if ctx.applySpeedCap ~= false and targetSpeedMps == nil then
		local speedCap = AIController.computeSpeedCap(normDiff, ctx.distToPlayer or 0.0, ctx.aiPos or 1, ctx.numAi or 1)
		MaxSpeed.setSlowdown(kartState.maxSpeedState, "AI", speedCap, 0, -1)
	end

	AIController.updateProgress(ai, kartState.pos, points, branches, normDiff, kartState)
	local angleToTrack = updateTrackCurve(ai, kartState, points, branches)
	local aimPoint = AIController.selectLookaheadPoint(ai, kartState, points, branches, ctx)
	local rawAngle = AIController.steerToPoint(kartState, aimPoint, props.skiddingThreshold)

	local maxSteer = math.max(1e-4, KartSolver.getMaxSteerAngle(kartState.profile, math.abs(kartState.speed)))
	local steerFraction = rawAngle / maxSteer

	-- Skid probability FSM (skidding_ai.cpp:L3036-L3064)
	local wasSkidding = kartState.latchedSkidControl ~= "NONE"
	local skidCtrl: KartSolver.SkidControl = "NONE"
	if not canSkid(ai, kartState, steerFraction, wasSkidding) then
		ai.skidProbState = SKID_PROBAB_NOT_YET
		skidCtrl = "NONE"
	else
		local dirCtrl: KartSolver.SkidControl = if steerFraction > 0.0 then "RIGHT" else "LEFT"
		if ai.skidProbState == SKID_PROBAB_NOT_YET then
			local prob = evalPiecewise(props.rbSkidProb, ctx.distToPlayer or 0.0)
			if nextRand01(ai, kartState) < prob then
				ai.skidProbState = SKID_PROBAB_SKID
			else
				ai.skidProbState = SKID_PROBAB_NO_SKID
			end
		end
		skidCtrl = if ai.skidProbState == SKID_PROBAB_SKID then dirCtrl else "NONE"
	end

	steerFraction = math.clamp(steerFraction, -1.0, 1.0)
	if kartState.itemEffect.plungerFaceTicks > 0 then
		local cap = math.clamp(0.35 + props.itemSkill * 0.10, 0.35, 0.90)
		steerFraction = math.clamp(steerFraction, -cap, cap)
	end

	-- Cancel skid if steering opposes active skid direction (skidding_ai.cpp:L3101-L3120)
	local ss = kartState.skid.state
	if
		(ss == "SKID_ACCUMULATE_LEFT" and steerFraction > 0.35)
		or (ss == "SKID_ACCUMULATE_RIGHT" and steerFraction < -0.35)
	then
		skidCtrl = "NONE"
	end
	if skidCtrl ~= "NONE" and (ss == "SKID_ACCUMULATE_LEFT" or ss == "SKID_ACCUMULATE_RIGHT") then
		steerFraction = math.clamp(Skidding.getSteeringWhenSkidding(kartState.skid, steerFraction), -1.0, 1.0)
	end

	local maxChange = dt / math.max(0.01, props.timeFullSteer)
	local nextSteer: number
	if ai.prevSteer < steerFraction then
		nextSteer = math.min(steerFraction, ai.prevSteer + maxChange)
	else
		nextSteer = math.max(steerFraction, ai.prevSteer - maxChange)
	end
	ai.prevSteer = nextSteer

	-- Acceleration & Braking (skidding_ai.cpp:L1989-L2068)
	local accel = KartTuning.ai.acceleration
	local brake = false
	local speed = math.abs(kartState.speed)
	if speed > 5.0 and math.abs(angleToTrack) > 0.22222 * math.pi then
		brake = true
		accel = 0.0
	elseif targetSpeedMps ~= nil and kartState.speed > targetSpeedMps then
		accel = 0.0
	end
	if not brake and kartState.itemEffect.plungerFaceTicks > 0 then
		local thresh = math.clamp(0.3 + props.itemSkill * 0.15, 0.3, 1.0)
		if kartState.speed > kartState.maxSpeedState.currentMaxSpeed * thresh then
			accel = 0.0
		end
	end

	-- Nitro usage (skidding_ai.cpp:L2193-L2364)
	local nitro = false
	local hasSlowdownAttachment = kartState.attachmentType == ItemTuning.ATTACHMENT_PARACHUTE
		or kartState.attachmentType == ItemTuning.ATTACHMENT_ANVIL
	if
		not brake
		and kartState.isOnGround
		and not kartState.race.raceFinished
		and not hasSlowdownAttachment
		and kartState.nitro.energy > 0.0
	then
		local nSkill = props.nitroUsage
		if nSkill >= 1 then
			local reserve = if nSkill == 2 then 4.0 elseif nSkill >= 3 then 8.0 else 0.0
			local numAi = ctx.numAi or 1
			local aiPos = ctx.aiPos or 1
			if nSkill >= 2 and numAi > 1 and aiPos >= numAi then
				reserve = math.min(reserve, 2.0)
			end
			-- Near-finish reserve drain (skidding_ai.cpp:L2296-L2318)
			if nSkill >= 2 and reserve > 0.0 then
				local graph = buildRouteGraph(points, branches)
				local lapsRem = math.max(1, ctx.lapsRemaining or 1)
				local remDist = math.max(0.0, graph.totalMainLength * lapsRem - ai.lapDistance)
				local estFinishSec = remDist / math.max(12.0, kartState.profile.maxSpeed * 0.85)
				local nitroActiveSec = kartState.profile.nitro.duration
				local nitroFadeSec = kartState.profile.nitro.fadeOutTime
				local nitroCons = math.max(0.1, kartState.profile.nitro.consumptionPerTick * 120.0)
				local maxTimeEffect = ((nitroActiveSec + nitroFadeSec) / nitroCons) * kartState.nitro.energy * 2.0
				if 2.5 * maxTimeEffect >= estFinishSec then
					local scaled = estFinishSec / (2.5 * maxTimeEffect / math.max(0.1, kartState.nitro.energy)) - 0.5
					reserve = math.max(0.0, math.min(reserve, scaled))
				end
			end
			if kartState.attachmentType == ItemTuning.ATTACHMENT_BOMB and nSkill >= 2 then
				reserve = 0.0
			end
			local canBurst = (nSkill == 1)
				or (kartState.speed > 0.90 * kartState.maxSpeedState.currentMaxSpeed)
				or (kartState.speed > 2.0 and kartState.speed < 5.0)
			if
				(kartState.nitro.energy > reserve or kartState.nitro.energy >= 4.0)
				and canBurst
				and math.abs(nextSteer) < 0.65
			then
				nitro = true
			end
		end
	end

	local fire, lookBack = decideItemFire(ai, kartState, dt, props.itemSkill, ctx)

	return {
		accel = accel,
		brake = brake,
		steer = nextSteer,
		drift = skidCtrl ~= "NONE",
		skidControl = skidCtrl,
		nitro = nitro,
		fire = fire,
		lookBack = lookBack,
	}
end

-- Post-finish coasting: follow driveline lookahead steering at zero throttle/brake (no freeze/despawn).
function AIController.computeCoastInput(
	ai: AIState,
	kartState: KartSolver.KartState,
	points: { DrivelinePoint },
	dt: number,
	branches: { DrivelineBranch }?
): KartSolver.KartInput
	local steered = AIController.computeInput(ai, kartState, points, dt, 0.0, { applySpeedCap = false }, branches)
	return {
		accel = 0.0,
		brake = false,
		steer = steered.steer,
		drift = false,
		skidControl = "NONE",
		nitro = false,
		fire = false,
		lookBack = false,
	}
end

return table.freeze(AIController)
