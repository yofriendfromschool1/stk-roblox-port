--!strict
-- src/shared/kart/KartVisualMath.lua
-- SPDX-License-Identifier: GPL-3.0-or-later
-- ported from src/karts/kart_model.cpp:L142-L145, L1267-L1301,
-- src/items/attachment.cpp:L654-L668 (STK 1.5)
-- Pure-Luau visual wheel spin, steering angle, suspension displacement,
-- and expiring bubblegum-shield flash helpers.

local FixedStep = require("../sim/FixedStep")
local Math3D = require("../sim/Math3D")
local ItemTuning = require("../ItemTuning")

local KartVisualMath = {}

-- Equilibrium flat-road suspension length: rest (0.30) - g / (4 * stiffness) = 0.291244 m
KartVisualMath.DEFAULT_REST_SUSPENSION_M = 0.2912
KartVisualMath.MIN_VISUAL_SUSPENSION_M = -0.07 -- src/karts/kart_model.cpp:L142
KartVisualMath.MAX_VISUAL_SUSPENSION_M = 0.20 -- src/karts/kart_model.cpp:L143
KartVisualMath.MAX_VISUAL_STEER_RAD = math.rad(30)

local TWO_PI = 2 * math.pi

-- Advance wheel roll rotation in radians wrapped to [0, 2*pi) (kart_model.cpp:L1293-L1295).
function KartVisualMath.advanceWheelSpin(prevRad: number, speedMps: number, dt: number, radiusMeters: number): number
	if radiusMeters <= 1e-4 or dt <= 0 then
		return prevRad % TWO_PI
	end
	local delta = (speedMps * dt) / radiusMeters
	return (prevRad + delta) % TWO_PI
end

-- Map normalized STK steer [-1, +1] (-1 = left, +1 = right) to front wheel yaw radians.
function KartVisualMath.computeSteerWheelAngleRad(steer: number): number
	return math.clamp(steer, -1.0, 1.0) * KartVisualMath.MAX_VISUAL_STEER_RAD
end

-- Compute vertical visual offset for wheel i relative to rest suspension (kart_model.cpp:L1286-L1288).
function KartVisualMath.computeWheelSuspensionOffsetY(
	suspensionLength: number,
	restSuspension: number?,
	minSusp: number?,
	maxSusp: number?
): number
	local rest = restSuspension or KartVisualMath.DEFAULT_REST_SUSPENSION_M
	local lo = minSusp or KartVisualMath.MIN_VISUAL_SUSPENSION_M
	local hi = maxSusp or KartVisualMath.MAX_VISUAL_SUSPENSION_M
	return math.clamp(rest - suspensionLength, lo, hi)
end

-- Shift kart-origin Y=0 (wheel bottom plane) so tires sit on road Y=0 at rest suspension.
function KartVisualMath.computeBodyGroundOffsetY(restSuspension: number?): number
	local rest = restSuspension or KartVisualMath.DEFAULT_REST_SUSPENSION_M
	return -rest
end

-- Expiring bubblegum shield flash visibility (src/items/attachment.cpp:L654-L668).
function KartVisualMath.isBubblegumShieldVisible(attachmentTicksLeft: number): boolean
	if attachmentTicksLeft <= 0 then
		return false
	end
	local bg = ItemTuning.bubblegum
	local slowFlashes = FixedStep.timeToTicks(bg.SHIELD_SLOW_FLASH_THRESHOLD_SEC)
	if attachmentTicksLeft >= slowFlashes then
		return true
	end
	local fastFlashes = FixedStep.timeToTicks(bg.SHIELD_FAST_FLASH_THRESHOLD_SEC)
	local periodSec = if attachmentTicksLeft < fastFlashes
		then bg.SHIELD_FAST_FLASH_PERIOD_SEC
		else bg.SHIELD_SLOW_FLASH_PERIOD_SEC
	local ticksPerFlash = math.max(1, FixedStep.timeToTicks(periodSec))
	local division = attachmentTicksLeft // ticksPerFlash
	return (division % 2) == 0
end

export type SwatterAnimPose = {
	swatterYawRad: number,
	swatterSwingPitchRad: number,
	showBomb: boolean,
	bombOffsetXMeters: number,
	bombRotXRad: number,
}

-- Tick-driven swatter & bomb-removal swing pose (src/items/swatter.cpp:L111-L226, L247-L385).
function KartVisualMath.computeSwatterAnimation(
	attachmentTicksLeft: number,
	swatterPhase: number?,
	swatterAnimTicks: number?,
	swatterBombMode: boolean?,
	swatterTargetYawRad: number?
): SwatterAnimPose
	local sw = ItemTuning.swatter
	if swatterBombMode == true then
		local totalTicks = FixedStep.timeToTicks(sw.BOMB_REMOVE_SEC)
		local elapsedTicks = math.clamp(totalTicks - attachmentTicksLeft, 0, totalTicks)
		local frame = (elapsedTicks * FixedStep.FIXED_DT) * sw.BOMB_FPS
		local pitchRad: number
		if frame < 24.0 then
			pitchRad = -0.55 * (frame / 24.0)
		elseif frame < sw.BOMB_FLY_START_FRAME then
			local t = (frame - 24.0) / (sw.BOMB_FLY_START_FRAME - 24.0)
			pitchRad = -0.55 + (1.35 - -0.55) * t
		else
			local t =
				math.clamp((frame - sw.BOMB_FLY_START_FRAME) / (sw.BOMB_TOTAL_FRAMES - sw.BOMB_FLY_START_FRAME), 0, 1)
			pitchRad = 1.35 * (1.0 - t)
		end
		local showBomb = frame < sw.BOMB_HIDE_FRAME
		local bombOffsetX = 0.0
		local bombRotX = 0.0
		if showBomb and frame >= sw.BOMB_FLY_START_FRAME then
			local delta = frame - sw.BOMB_FLY_START_FRAME
			bombOffsetX = -delta
			bombRotX = -delta
		end
		return {
			swatterYawRad = math.pi,
			swatterSwingPitchRad = pitchRad,
			showBomb = showBomb,
			bombOffsetXMeters = bombOffsetX,
			bombRotXRad = bombRotX,
		}
	end

	local phase = swatterPhase or ItemTuning.SWATTER_PHASE_AIMING
	local animTicks = swatterAnimTicks or 0
	local pitchRad = -0.25
	if phase == ItemTuning.SWATTER_PHASE_TO_TARGET then
		local downTicks = math.max(1, FixedStep.timeToTicks(sw.SWING_DOWN_SEC))
		local t = math.clamp(1.0 - (attachmentTicksLeft - animTicks) / downTicks, 0.0, 1.0)
		pitchRad = -0.25 + (1.35 - -0.25) * t
	elseif phase == ItemTuning.SWATTER_PHASE_FROM_TARGET then
		local upTicks = math.max(1, FixedStep.timeToTicks(sw.SWING_UP_SEC))
		local t = math.clamp(1.0 - (attachmentTicksLeft - animTicks) / upTicks, 0.0, 1.0)
		pitchRad = 1.35 + (-0.25 - 1.35) * t
	end

	return {
		swatterYawRad = swatterTargetYawRad or 0.0,
		swatterSwingPitchRad = pitchRad,
		showBomb = false,
		bombOffsetXMeters = 0.0,
		bombRotXRad = 0.0,
	}
end

export type BombArrowState = {
	timeLeftSec: number,
	angleDeg: number,
	urgentFlash: boolean,
}

-- Ported from src/items/attachment.cpp:L684-L692 (60-step counterclockwise dial down to 0 at detonation)
function KartVisualMath.computeBombArrowState(ticksLeft: number): BombArrowState
	local clampedTicks = math.max(0, ticksLeft)
	local timeLeftSec = FixedStep.ticksToTime(clampedTicks)
	local frac60 = math.clamp(timeLeftSec, 0.0, 60.0)
	local angleDeg = -(frac60 * 6.0)
	local urgentFlash = timeLeftSec <= 3.0 and (math.floor(clampedTicks / 12) % 2 == 0)
	return {
		timeLeftSec = timeLeftSec,
		angleDeg = angleDeg,
		urgentFlash = urgentFlash,
	}
end

-- Exact STK 1.5 bomb.spm Hand bone keyframes at frames [0, 15, 30, 45, 60] (attachment.cpp:L684-L692).
-- Frame advances 0 -> 60 as time_left counts down 60 s -> 0 s: frame = 60 - clamp(timeLeftSec, 0, 60).
local BOMB_HAND_KEYFRAMES: { { frame: number, q: Math3D.Quat } } = {
	{ frame = 0, q = { w = 0.79335, x = -0.60876, y = 0.0, z = 0.0 } },
	{ frame = 15, q = { w = 0.56099, x = -0.43046, y = -0.56099, z = 0.43046 } },
	{ frame = 30, q = { w = 0.0, x = 0.0, y = -0.79335, z = 0.60876 } },
	{ frame = 45, q = { w = 0.56099, x = -0.43046, y = 0.56099, z = -0.43046 } },
	{ frame = 60, q = { w = 0.79335, x = -0.60876, y = 0.0, z = 0.0 } },
}

KartVisualMath.BOMB_HAND_PIVOT_STK = { x = 0.0, y = 0.46325, z = -1.1002 }

function KartVisualMath.computeBombHandQuatStk(ticksLeft: number): Math3D.Quat
	local timeLeftSec = FixedStep.ticksToTime(math.max(0, ticksLeft))
	local frame = math.clamp(60.0 - math.clamp(timeLeftSec, 0.0, 60.0), 0.0, 60.0)
	for i = 1, #BOMB_HAND_KEYFRAMES - 1 do
		local a = BOMB_HAND_KEYFRAMES[i]
		local b = BOMB_HAND_KEYFRAMES[i + 1]
		if frame <= b.frame or i == #BOMB_HAND_KEYFRAMES - 1 then
			local span = math.max(1e-6, b.frame - a.frame)
			local t = math.clamp((frame - a.frame) / span, 0.0, 1.0)
			return Math3D.quatSlerp(a.q, b.q, t)
		end
	end
	return BOMB_HAND_KEYFRAMES[1].q
end

return table.freeze(KartVisualMath)
