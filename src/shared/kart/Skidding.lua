--!strict
-- src/shared/kart/Skidding.lua
-- SPDX-License-Identifier: GPL-3.0-or-later
-- ported from src/karts/skidding.cpp:L148-L221, L330-L624 (STK 1.5)

local FixedStep = require("../sim/FixedStep")
local KartTuning = require("../KartTuning")

export type SkidControl = "NONE" | "NO_DIRECTION" | "LEFT" | "RIGHT"

export type SkidStateName =
	"SKID_NONE"
	| "SKID_ACCUMULATE_LEFT"
	| "SKID_ACCUMULATE_RIGHT"
	| "SKID_SHOW_GFX_LEFT"
	| "SKID_SHOW_GFX_RIGHT"
	| "SKID_BREAK"

export type SkidReleaseBonus = {
	tier: number,
	bonusSpeed: number,
	instantGain: number,
	bonusForce: number,
	bonusTicks: number,
	fadeOutTicks: number,
	timedRotationTicks: number,
	timedRotationTotalRad: number,
}

export type SkidState = {
	state: SkidStateName,
	skidTimeTicks: number,
	skidFactor: number,
	steeringFraction: number,
	visualRotation: number,
	remainingJumpTime: number,
	hopHeight: number,
	bonusReady: boolean,
	currentTier: number,
}

local Skidding = {}

function Skidding.new(): SkidState
	return {
		state = "SKID_NONE",
		skidTimeTicks = 0,
		skidFactor = 1.0,
		steeringFraction = 0.0,
		visualRotation = 0.0,
		remainingJumpTime = 0.0,
		hopHeight = 0.0,
		bonusReady = false,
		currentTier = 0,
	}
end

function Skidding.reset(s: SkidState)
	s.state = "SKID_NONE"
	s.skidTimeTicks = 0
	s.skidFactor = 1.0
	s.steeringFraction = 0.0
	s.visualRotation = 0.0
	s.remainingJumpTime = 0.0
	s.hopHeight = 0.0
	s.bonusReady = false
	s.currentTier = 0
end

-- Determines current charge tier and bonus payload (src/karts/skidding.cpp:L605-L624)
function Skidding.getSkidBonus(skidTimeTicks: number): (number, number, number, number)
	local cfg = KartTuning.skid
	local elapsed = FixedStep.ticksToTime(skidTimeTicks)
	local bonusTime = 0.0
	local bonusSpeed = 0.0
	local bonusForce = 0.0
	local count = #cfg.bonusSpeed

	for i = 1, count do
		if elapsed <= cfg.timeTillBonus[i] then
			return i - 1, bonusTime, bonusSpeed, bonusForce
		end
		bonusSpeed = cfg.bonusSpeed[i]
		bonusTime = cfg.bonusTime[i]
		bonusForce = cfg.bonusForce[i]
	end
	return count, bonusTime, bonusSpeed, bonusForce
end

-- Computes locked-direction steering fraction & visual drift yaw (src/karts/skidding.cpp:L148-L221)
local function updateSteering(s: SkidState, steer: number, dt: number): number
	local cfg = KartTuning.skid
	local skidTimeSec = FixedStep.ticksToTime(s.skidTimeTicks)
	local steerResult = 0.0
	local reduceDelta = cfg.reduceTurnMax - cfg.reduceTurnMin

	if s.state == "SKID_SHOW_GFX_LEFT" or s.state == "SKID_SHOW_GFX_RIGHT" or s.state == "SKID_NONE" then
		steerResult = steer
		if skidTimeSec < cfg.visualTime and skidTimeSec > 0 then
			local f = s.visualRotation - s.visualRotation * dt / skidTimeSec
			if (f < 0 and s.visualRotation > 0) or (f > 0 and s.visualRotation < 0) then
				s.visualRotation = 0
			else
				s.visualRotation = f
			end
		elseif s.state == "SKID_NONE" then
			s.visualRotation = 0
		end
	elseif s.state == "SKID_BREAK" then
		steerResult = steer
		local step = cfg.breakVisualStepPerTick
		if s.visualRotation > step then
			s.visualRotation -= step
		elseif s.visualRotation < -step then
			s.visualRotation += step
		else
			Skidding.reset(s)
		end
	elseif s.state == "SKID_ACCUMULATE_RIGHT" then
		-- Map steer [-1, +1] -> f [0, 1] -> steerResult [+0.2, +0.8] (skidding.cpp:L186-L195)
		local f = (1.0 + steer) * 0.5
		steerResult = cfg.reduceTurnMin + reduceDelta * f
		if skidTimeSec < cfg.visualTime then
			s.visualRotation = cfg.visual * steerResult * (skidTimeSec / cfg.visualTime)
		else
			s.visualRotation = cfg.visual * steerResult
		end
	elseif s.state == "SKID_ACCUMULATE_LEFT" then
		-- Map steer [-1, +1] -> f [-1, 0] -> steerResult [-0.8, -0.2] (skidding.cpp:L199-L208)
		local f = (-1.0 + steer) * 0.5
		steerResult = -cfg.reduceTurnMin + reduceDelta * f
		if skidTimeSec < cfg.visualTime then
			s.visualRotation = cfg.visual * steerResult * (skidTimeSec / cfg.visualTime)
		else
			s.visualRotation = cfg.visual * steerResult
		end
	end

	-- Clamp visual rotation to [-1, +1] rad (skidding.cpp:L215-L218)
	s.visualRotation = math.clamp(s.visualRotation, -cfg.visualClamp, cfg.visualClamp)
	return steerResult
end

-- Inverse steering remap during active skid (src/karts/skidding.cpp:L231-L249)
function Skidding.getSteeringWhenSkidding(s: SkidState, steer: number): number
	local cfg = KartTuning.skid
	local delta = cfg.reduceTurnMax - cfg.reduceTurnMin
	if s.state == "SKID_ACCUMULATE_RIGHT" then
		local f = (steer - cfg.reduceTurnMin) / delta
		return math.clamp(f * 2.0 - 1.0, -1.0, 1.0)
	elseif s.state == "SKID_ACCUMULATE_LEFT" then
		local f = (steer + cfg.reduceTurnMin) / delta
		return math.clamp(f * 2.0 + 1.0, -1.0, 1.0)
	end
	return steer
end

-- Advances the STK 6-state skidding machine by 1 fixed tick (src/karts/skidding.cpp:L353-L595)
function Skidding.update(
	s: SkidState,
	ticks: number,
	isOnGround: boolean,
	speed: number,
	steer: number,
	skidControl: SkidControl,
	gravity: number
): SkidReleaseBonus?
	local cfg = KartTuning.skid
	local dt = FixedStep.ticksToTime(ticks)

	s.remainingJumpTime -= dt
	if s.remainingJumpTime > 0 then
		local tHop = cfg.graphicalJumpTime - s.remainingJumpTime
		local v0 = 0.5 * gravity * cfg.graphicalJumpTime
		s.hopHeight = math.max(0.0, v0 * tHop - 0.5 * gravity * tHop * tHop)
	else
		s.remainingJumpTime = 0.0
		s.hopHeight = 0.0
	end

	-- No skidding backwards or while too slow (skidding.cpp:L376-L380)
	if speed < cfg.minSpeed and s.state ~= "SKID_NONE" and s.state ~= "SKID_BREAK" then
		s.state = "SKID_BREAK"
	end

	s.bonusReady = false
	-- Skid factor builds on ground and resets immediately to 1.0 when airborne (skidding.cpp:L383-L406)
	if isOnGround then
		if
			math.abs(steer) > cfg.minSteerThreshold
			and speed > cfg.minSpeed
			and (skidControl == "LEFT" or skidControl == "RIGHT")
		then
			s.skidFactor += cfg.increase * dt / cfg.timeTillMax
		elseif s.skidFactor > 1.0 then
			s.skidFactor *= cfg.decrease
		end
	else
		s.skidFactor = 1.0
	end
	s.skidFactor = math.clamp(s.skidFactor, 1.0, cfg.max)

	local releaseBonus: SkidReleaseBonus? = nil

	if s.state == "SKID_NONE" then
		if (skidControl == "LEFT" or skidControl == "RIGHT") and s.remainingJumpTime <= 0 and speed >= cfg.minSpeed then
			s.state = if skidControl == "RIGHT" then "SKID_ACCUMULATE_RIGHT" else "SKID_ACCUMULATE_LEFT"
			s.remainingJumpTime = cfg.graphicalJumpTime
			s.skidTimeTicks = 0
			s.currentTier = 0
		end
	elseif s.state == "SKID_BREAK" then
		s.currentTier = 0
	elseif s.state == "SKID_ACCUMULATE_LEFT" or s.state == "SKID_ACCUMULATE_RIGHT" then
		-- Note: skidding.cpp:L525-L536 intentionally does NOT reset skidState or skidTimeTicks when
		-- airborne; charge persists across brief airtime while speed >= minSpeed and drift stays held.
		s.skidTimeTicks += ticks
		local level, bonusTime, bonusSpeed, bonusForce = Skidding.getSkidBonus(s.skidTimeTicks)
		s.currentTier = level
		if level >= 1 then
			s.bonusReady = true
		end

		if skidControl == "NONE" then
			s.state = if s.state == "SKID_ACCUMULATE_LEFT" then "SKID_SHOW_GFX_LEFT" else "SKID_SHOW_GFX_RIGHT"
			local skidTimeSec = FixedStep.ticksToTime(s.skidTimeTicks)
			local tRevert = math.min(skidTimeSec, cfg.visualTime, cfg.revertVisualTime)
			local revertTicks = FixedStep.timeToTicks(tRevert)

			local totalRotRad = s.visualRotation * cfg.postSkidRotateFactor
			s.skidTimeTicks = revertTicks

			releaseBonus = {
				tier = level,
				bonusSpeed = bonusSpeed,
				instantGain = bonusSpeed * cfg.bonusInstantFraction,
				bonusForce = bonusForce,
				bonusTicks = FixedStep.timeToTicks(bonusTime),
				fadeOutTicks = FixedStep.timeToTicks(cfg.bonusFadeOutTime),
				timedRotationTicks = revertTicks,
				timedRotationTotalRad = totalRotRad,
			}
		end
	elseif s.state == "SKID_SHOW_GFX_LEFT" or s.state == "SKID_SHOW_GFX_RIGHT" then
		s.currentTier = 0
		if s.skidTimeTicks > 0 then
			s.skidTimeTicks -= ticks
		end
		if s.skidTimeTicks <= 0 then
			s.skidTimeTicks = 0
			s.state = "SKID_NONE"
			s.visualRotation = 0
		end
	end

	s.steeringFraction = updateSteering(s, steer, dt)
	return releaseBonus
end

return table.freeze(Skidding)
