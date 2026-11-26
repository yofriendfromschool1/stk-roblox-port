--!strict
-- src/shared/kart/KartVisualMath.lua
-- SPDX-License-Identifier: GPL-3.0-or-later
-- ported from src/karts/kart_model.cpp:L142-L145, L1267-L1301,
-- src/items/attachment.cpp:L654-L668 (STK 1.5)
-- Pure-Luau visual wheel spin, steering angle, suspension displacement,
-- and expiring bubblegum-shield flash helpers.

local FixedStep = require("../sim/FixedStep")
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

return table.freeze(KartVisualMath)
