--!strict
-- src/shared/sim/Slipstream.lua
-- SPDX-License-Identifier: GPL-3.0-or-later
-- ported from src/graphics/slip_stream.cpp:L152-L176, L265-L274, L664-L668, L714-L1148,
-- src/tracks/quad.cpp:L46-L57, L115-L143, src/tracks/graph.cpp:L44-L45 (STK 1.5)
-- Pure-Luau slipstream wake detection, credit accumulation/decay, and boost activation.

local FixedStep = require("./FixedStep")
local KartTuning = require("../KartTuning")
local Math3D = require("./Math3D")
local MaxSpeed = require("../kart/MaxSpeed")

export type SlipstreamMode = "NONE" | "COLLECT"

export type Quad2D = {
	p0x: number,
	p0z: number,
	p1x: number,
	p1z: number,
	p2x: number,
	p2z: number,
	p3x: number,
	p3z: number,
}

export type SlipstreamState = {
	mode: SlipstreamMode,
	inZone: boolean,
	chargeTicks: number,
	slipstreamTime: number,
	bonusTime: number,
	bonusActive: boolean,
	currentTargetId: number?,
	previousTargetId: number?,
	speedIncreaseTick: number,
	speedIncreaseDurationTicks: number,
	inInnerQuad: boolean,
	inOuterQuad: boolean,
	mainQuad: Quad2D,
	innerQuad: Quad2D,
	outerQuad: Quad2D,
}

export type NetSlipstreamState = {
	mode: SlipstreamMode,
	inZone: boolean,
	chargeTicks: number,
	slipstreamTime: number,
	bonusTime: number,
	bonusActive: boolean,
	currentTargetId: number?,
	previousTargetId: number?,
	speedIncreaseTick: number,
	speedIncreaseDurationTicks: number,
	inInnerQuad: boolean,
	inOuterQuad: boolean,
}

export type Participant = {
	id: number,
	pos: Math3D.Vec3,
	prevPos: Math3D.Vec3,
	rot: Math3D.Quat,
	linVel: Math3D.Vec3,
	speed: number,
	isOnGround: boolean,
	width: number,
	length: number,
	slipstreamCfg: KartTuning.SlipstreamProfile,
	maxSpeedState: MaxSpeed.MaxSpeedState,
	slipstream: SlipstreamState,
	disableSlipstream: boolean?,
	isGhost: boolean?,
	isInAnimation: boolean?,
	isEliminated: boolean?,
	onApplyInstantSpeed: ((newMinSpeed: number) -> ())?,
}

local Slipstream = {}

local function makeInitialQuad(kartWidth: number, kartLength: number): Quad2D
	local halfW = kartWidth * 0.5
	local halfL = kartLength * 0.5
	return {
		p0x = -halfW,
		p0z = halfL,
		p1x = 0.0,
		p1z = -halfL,
		p2x = 0.0,
		p2z = -halfL,
		p3x = halfW,
		p3z = halfL,
	}
end

local function setQuad(
	q: Quad2D,
	p0x: number,
	p0z: number,
	p1x: number,
	p1z: number,
	p2x: number,
	p2z: number,
	p3x: number,
	p3z: number
)
	q.p0x = p0x
	q.p0z = p0z
	q.p1x = p1x
	q.p1z = p1z
	q.p2x = p2x
	q.p2z = p2z
	q.p3x = p3x
	q.p3z = p3z
end

-- Ported from Vec3::sideOfLine2D (src/utils/vec3.hpp:L209-L214)
local function sideOfLine2D(px: number, pz: number, sx: number, sz: number, ex: number, ez: number): number
	return (ex - sx) * (pz - sz) - (ez - sz) * (px - sx)
end

function Slipstream.new(kartWidth: number, kartLength: number): SlipstreamState
	return {
		mode = "NONE",
		inZone = false,
		chargeTicks = 0,
		slipstreamTime = 0.0,
		bonusTime = 0.0,
		bonusActive = false,
		currentTargetId = nil,
		previousTargetId = nil,
		speedIncreaseTick = -1,
		speedIncreaseDurationTicks = -1,
		inInnerQuad = false,
		inOuterQuad = false,
		mainQuad = makeInitialQuad(kartWidth, kartLength),
		innerQuad = makeInitialQuad(kartWidth, kartLength),
		outerQuad = makeInitialQuad(kartWidth, kartLength),
	}
end

function Slipstream.reset(ss: SlipstreamState, kartWidth: number, kartLength: number)
	ss.mode = "NONE"
	ss.inZone = false
	ss.chargeTicks = 0
	ss.slipstreamTime = 0.0
	ss.bonusTime = 0.0
	ss.bonusActive = false
	ss.currentTargetId = nil
	ss.previousTargetId = nil
	ss.speedIncreaseTick = -1
	ss.speedIncreaseDurationTicks = -1
	ss.inInnerQuad = false
	ss.inOuterQuad = false
	ss.mainQuad = makeInitialQuad(kartWidth, kartLength)
	ss.innerQuad = makeInitialQuad(kartWidth, kartLength)
	ss.outerQuad = makeInitialQuad(kartWidth, kartLength)
end

function Slipstream.isReady(ss: SlipstreamState, cfg: KartTuning.SlipstreamProfile): boolean
	return ss.chargeTicks > FixedStep.timeToTicks(cfg.minCollectTime)
end

function Slipstream.inUse(ss: SlipstreamState): boolean
	return ss.bonusTime > 0.0
end

-- Ported from Quad::pointInside (src/tracks/quad.cpp:L115-L143, src/tracks/graph.cpp:L44-L45)
function Slipstream.pointInsideQuad(q: Quad2D, localPos: Math3D.Vec3): boolean
	local cfg = KartTuning.slipstream
	if localPos.y > cfg.quadMaxHeightTesting or localPos.y < cfg.quadMinHeightTesting then
		return false
	end
	local px = localPos.x
	local pz = localPos.z
	if sideOfLine2D(px, pz, q.p0x, q.p0z, q.p2x, q.p2z) < 0.0 then
		return sideOfLine2D(px, pz, q.p0x, q.p0z, q.p1x, q.p1z) >= 0.0
			and sideOfLine2D(px, pz, q.p1x, q.p1z, q.p2x, q.p2z) >= 0.0
	else
		return sideOfLine2D(px, pz, q.p2x, q.p2z, q.p3x, q.p3z) > 0.0
			and sideOfLine2D(px, pz, q.p3x, q.p3z, q.p0x, q.p0z) >= 0.0
	end
end

-- Ported from SlipStream::updateQuad (src/graphics/slip_stream.cpp:L714-L815)
-- Computes main, outer, and inner wake trapezoids in target-kart local XZ space,
-- bending the rear edge along actual travel direction (prevPos - pos).
function Slipstream.updateQuad(
	ss: SlipstreamState,
	pos: Math3D.Vec3,
	prevPos: Math3D.Vec3,
	rot: Math3D.Quat,
	speed: number,
	kartWidth: number,
	kartLength: number,
	cfg: KartTuning.SlipstreamProfile
)
	local consts = KartTuning.slipstream

	-- Actual backward travel vector in world space: moving = normalize(prevPos - pos)
	-- In local kart space (+Z forward), backward heading is (0, 0, -1), so
	-- noffset_local = quatRotateVec(invRot, moving) - (0, 0, -1).
	local mx = prevPos.x - pos.x
	local my = prevPos.y - pos.y
	local mz = prevPos.z - pos.z
	local lenSq = mx * mx + my * my + mz * mz
	local noffsetX = 0.0
	local noffsetZ = 0.0
	if lenSq > 1e-12 then
		local invLen = 1.0 / math.sqrt(lenSq)
		local movingUnit = { x = mx * invLen, y = my * invLen, z = mz * invLen }
		local localMoving = Math3D.quatRotateVec(Math3D.quatConjugate(rot), movingUnit)
		noffsetX = localMoving.x
		noffsetZ = localMoving.z + 1.0
	end

	local speedFactor = speed / cfg.baseSpeed
	local length = cfg.length * speedFactor
	local kw = kartWidth
	local ew = cfg.width * speedFactor
	local kl = kartLength
	local offx = (kl * 0.5 + length) * noffsetX
	local offz = (kl * 0.5 + length) * noffsetZ

	local p0x, p0z = -kw * 0.5, kl * 0.5
	local p3x, p3z = kw * 0.5, kl * 0.5

	setQuad(
		ss.mainQuad,
		p0x,
		p0z,
		-ew * 0.5 + offx,
		-kl * 0.5 - length + offz,
		ew * 0.5 + offx,
		-kl * 0.5 - length + offz,
		p3x,
		p3z
	)

	local outerScale = consts.outerQuadScale
	setQuad(
		ss.outerQuad,
		p0x,
		p0z,
		(-ew * 0.5 + offx) * outerScale,
		-kl * 0.5 - (length + offz) * outerScale,
		(ew * 0.5 + offx) * outerScale,
		-kl * 0.5 - (length + offz) * outerScale,
		p3x,
		p3z
	)

	local innerFactor = cfg.innerFactor * math.sqrt(math.max(0.0, speedFactor))
	local innerLength = length * innerFactor
	local innerEw = ew * innerFactor
	if innerEw > consts.innerWidthSubtract then
		innerEw -= consts.innerWidthSubtract
	else
		innerEw = 0.0
	end
	local innerOffx = (kl * 0.5 + innerLength) * noffsetX
	local innerOffz = (kl * 0.5 + innerLength) * noffsetZ

	setQuad(
		ss.innerQuad,
		p0x,
		p0z,
		-innerEw * 0.5 + innerOffx,
		-kl * 0.5 - innerLength + innerOffz,
		innerEw * 0.5 + innerOffx,
		-kl * 0.5 - innerLength + innerOffz,
		p3x,
		p3z
	)
end

-- Ported from SlipStream::update + SlipStream::updateSpeedIncrease (src/graphics/slip_stream.cpp:L855-L1148)
-- Runs as a two-pass multi-participant step sorted by participant id so results are
-- independent of input array insertion order.
function Slipstream.stepAll(participants: { Participant }, dt: number, worldTick: number): number
	local n = #participants
	if n == 0 then
		return 0
	end

	local sorted = table.clone(participants)
	table.sort(sorted, function(a: Participant, b: Participant): boolean
		return a.id < b.id
	end)

	local consts = KartTuning.slipstream

	-- Pass 1: update every kart's wake quads from this tick's state before any containment checks.
	for _, p in sorted do
		if not p.disableSlipstream and not p.isGhost and p.speed > consts.quadUpdateMinSpeed then
			Slipstream.updateQuad(p.slipstream, p.pos, p.prevPos, p.rot, p.speed, p.width, p.length, p.slipstreamCfg)
		end
	end

	-- Pass 2: detect wake containment, accumulate/decay credits, trigger boost on exit.
	local triggeredCount = 0
	for _, p in sorted do
		local ss = p.slipstream
		local cfg = p.slipstreamCfg

		if p.disableSlipstream or p.isGhost then
			ss.inZone = false
			continue
		end

		ss.bonusTime = math.max(0.0, ss.bonusTime - dt)
		if ss.bonusTime <= 0.0 then
			ss.bonusActive = false
		end

		if p.speed < cfg.minSpeed - consts.collectorMinSpeedMargin then
			ss.mode = "NONE"
			ss.inZone = false
			ss.chargeTicks = 0
			ss.inInnerQuad = false
			ss.inOuterQuad = false
			continue
		end

		local isSstreaming = false
		local isInnerSstreaming = false
		local isOuterSstreaming = false
		local targetScores: { [number]: number } = {}

		for _, target in sorted do
			if target == p or target.isInAnimation or target.isGhost or target.isEliminated then
				if ss.previousTargetId == target.id then
					ss.previousTargetId = nil
				end
				continue
			end

			local delta = Math3D.sub(p.pos, target.pos)
			local lc = Math3D.quatRotateVec(Math3D.quatConjugate(target.rot), delta)
			if math.abs(lc.y) > consts.verticalAbsLimit then
				continue
			end

			local targetCfg = target.slipstreamCfg
			if target.speed < targetCfg.minSpeed then
				if ss.previousTargetId == target.id then
					ss.previousTargetId = nil
				end
				continue
			end

			local speedFactor = target.speed / targetCfg.baseSpeed
			local l = targetCfg.length * consts.outerQuadScale * speedFactor + target.length + 0.5 * p.length
			local deltaSq = Math3D.lenSq(delta)
			if deltaSq > l * l then
				if ss.previousTargetId == target.id then
					ss.previousTargetId = nil
				end
				continue
			end

			local targetSS = target.slipstream
			if Slipstream.pointInsideQuad(targetSS.innerQuad, lc) then
				isInnerSstreaming = true
				isSstreaming = true
				targetScores[target.id] = consts.innerTargetScoreBase - deltaSq
				continue
			end

			if Slipstream.pointInsideQuad(targetSS.mainQuad, lc) then
				isSstreaming = true
				targetScores[target.id] = consts.mainTargetScoreBase - deltaSq
				continue
			elseif ss.previousTargetId == target.id then
				ss.previousTargetId = nil
			end

			if Slipstream.pointInsideQuad(targetSS.outerQuad, lc) then
				isOuterSstreaming = true
				continue
			end
		end

		local bestTargetId: number? = nil
		local bestTargetScore = 0.0
		for _, target in sorted do
			local score = targetScores[target.id]
			if score ~= nil and score > bestTargetScore then
				bestTargetScore = score
				bestTargetId = target.id
			end
		end

		if bestTargetId ~= ss.currentTargetId then
			ss.previousTargetId = ss.currentTargetId
			ss.currentTargetId = bestTargetId
		end

		local prevCleared = (ss.previousTargetId ~= nil and targetScores[ss.previousTargetId :: number] == nil)
		if Slipstream.isReady(ss, cfg) and (ss.currentTargetId == nil or prevCleared) then
			local additionalTime = ss.slipstreamTime * cfg.durationFactor
			if ss.bonusTime <= 0.0 then
				ss.bonusTime = additionalTime
			else
				ss.bonusTime += additionalTime
			end
			ss.chargeTicks = 0
			ss.slipstreamTime = 0.0
			ss.bonusActive = true
			ss.speedIncreaseDurationTicks = FixedStep.timeToTicks(ss.bonusTime)
			ss.speedIncreaseTick = worldTick
		end

		ss.inZone = isSstreaming
		local maxCollectTicks = FixedStep.timeToTicks(cfg.maxCollectTime)
		if not isSstreaming then
			ss.inInnerQuad = false
			ss.inOuterQuad = isOuterSstreaming
			local decayTicks = if isOuterSstreaming then consts.outerDecayRate else consts.outsideDecayRate
			ss.chargeTicks = math.max(0, ss.chargeTicks - decayTicks)
			if isOuterSstreaming then
				ss.slipstreamTime -= dt * consts.outerDecayRate
			else
				ss.slipstreamTime -= dt * consts.outsideDecayRate
			end
			if ss.slipstreamTime < 0.0 or ss.chargeTicks <= 0 then
				ss.chargeTicks = 0
				ss.mode = "NONE"
			end
		else
			ss.inInnerQuad = isInnerSstreaming
			ss.inOuterQuad = false
			local addTicks = if isInnerSstreaming then consts.innerCollectRate else 1
			local addTime = if isInnerSstreaming then consts.innerCollectRate * dt else dt
			ss.chargeTicks =
				math.min(maxCollectTicks, if ss.mode == "NONE" then addTicks else ss.chargeTicks + addTicks)
			ss.slipstreamTime = if ss.mode == "NONE" then addTime else ss.slipstreamTime + addTime
			if ss.slipstreamTime > cfg.maxCollectTime then
				ss.slipstreamTime = cfg.maxCollectTime
			end
			ss.mode = "COLLECT"
		end

		if ss.speedIncreaseTick == worldTick then
			local instantMinSpeed = MaxSpeed.instantSpeedIncrease(
				p.maxSpeedState,
				"SLIPSTREAM",
				cfg.maxSpeedIncrease,
				cfg.maxSpeedIncrease,
				cfg.addPower,
				ss.speedIncreaseDurationTicks,
				FixedStep.timeToTicks(cfg.fadeOutTime),
				math.max(0.0, p.speed),
				p.isOnGround
			)
			if p.onApplyInstantSpeed ~= nil then
				p.onApplyInstantSpeed(instantMinSpeed)
			end
			triggeredCount += 1
		end
	end

	return triggeredCount
end

function Slipstream.captureNet(ss: SlipstreamState): NetSlipstreamState
	return {
		mode = ss.mode,
		inZone = ss.inZone,
		chargeTicks = ss.chargeTicks,
		slipstreamTime = ss.slipstreamTime,
		bonusTime = ss.bonusTime,
		bonusActive = ss.bonusActive,
		currentTargetId = ss.currentTargetId,
		previousTargetId = ss.previousTargetId,
		speedIncreaseTick = ss.speedIncreaseTick,
		speedIncreaseDurationTicks = ss.speedIncreaseDurationTicks,
		inInnerQuad = ss.inInnerQuad,
		inOuterQuad = ss.inOuterQuad,
	}
end

function Slipstream.applyNet(ss: SlipstreamState, snap: NetSlipstreamState?, kartWidth: number, kartLength: number)
	if snap == nil then
		Slipstream.reset(ss, kartWidth, kartLength)
		return
	end
	ss.mode = snap.mode
	ss.inZone = snap.inZone
	ss.chargeTicks = snap.chargeTicks
	ss.slipstreamTime = snap.slipstreamTime
	ss.bonusTime = snap.bonusTime
	ss.bonusActive = snap.bonusActive
	ss.currentTargetId = snap.currentTargetId
	ss.previousTargetId = snap.previousTargetId
	ss.speedIncreaseTick = snap.speedIncreaseTick
	ss.speedIncreaseDurationTicks = snap.speedIncreaseDurationTicks
	ss.inInnerQuad = snap.inInnerQuad
	ss.inOuterQuad = snap.inOuterQuad
end

return table.freeze(Slipstream)
