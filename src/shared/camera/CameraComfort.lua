--!strict
-- src/shared/camera/CameraComfort.lua
-- SPDX-License-Identifier: GPL-3.0-or-later
-- Camera vertical comfort filter: deadzone, critically-damped vertical spring,
-- vertical velocity clamp, and separate look-target low-pass filter.
-- Upstream STK 1.5 baseline (src/graphics/camera/camera_normal.cpp:L121-L146,
-- src/config/user_config.hpp:L1046,L1051) uses 1st-order exponential lag without
-- deadzone or look-target filtering; comfort additions logged in docs/divergences.md.

export type CameraComfortConfig = {
	deadzone: number,
	stiffness: number,
	damping: number,
	maxVel: number,
	lookSmoothSec: number,
}

export type CameraComfortState = {
	initialized: boolean,
	deadzoneAnchorY: number,
	camY: number,
	camVelY: number,
	lookY: number,
}

local MAX_SUBSTEP_DT = 1 / 120

local CameraComfort = {}

function CameraComfort.createState(): CameraComfortState
	return {
		initialized = false,
		deadzoneAnchorY = 0.0,
		camY = 0.0,
		camVelY = 0.0,
		lookY = 0.0,
	}
end

function CameraComfort.reset(state: CameraComfortState, posY: number, lookY: number): ()
	state.initialized = true
	state.deadzoneAnchorY = posY
	state.camY = posY
	state.camVelY = 0.0
	state.lookY = lookY
end

function CameraComfort.step(
	state: CameraComfortState,
	targetY: number,
	targetLookY: number,
	dt: number,
	cfg: CameraComfortConfig
): (number, number, number)
	if not state.initialized or dt <= 0.0 then
		CameraComfort.reset(state, targetY, targetLookY)
		return state.camY, state.lookY, state.camVelY
	end

	local deadzone = math.max(0.0, cfg.deadzone)
	local stiffness = math.max(0.1, cfg.stiffness)
	local damping = math.max(0.0, cfg.damping)
	local maxVel = math.max(0.5, cfg.maxVel)

	-- 1) Vertical deadzone: bumps within +/- deadzone around anchor do not move the spring target.
	local err = targetY - state.deadzoneAnchorY
	if math.abs(err) > deadzone then
		state.deadzoneAnchorY = targetY - math.sign(err) * deadzone
	end

	-- 2) Critically-damped vertical spring (sub-stepped at <= 1/120 s for stability).
	local remaining = math.min(dt, 0.25)
	while remaining > 1e-6 do
		local subDt = math.min(remaining, MAX_SUBSTEP_DT)
		local accelY = stiffness * (state.deadzoneAnchorY - state.camY) - damping * state.camVelY
		state.camVelY = math.clamp(state.camVelY + accelY * subDt, -maxVel, maxVel)
		state.camY += state.camVelY * subDt
		remaining -= subDt
	end

	if math.abs(state.deadzoneAnchorY - state.camY) < 1e-4 and math.abs(state.camVelY) < 1e-4 then
		state.camY = state.deadzoneAnchorY
		state.camVelY = 0.0
	end

	-- 3) Separate exponential low-pass on vertical look target.
	local alpha = if cfg.lookSmoothSec > 1e-4 then 1.0 - math.exp(-dt / cfg.lookSmoothSec) else 1.0
	state.lookY += (targetLookY - state.lookY) * alpha

	return state.camY, state.lookY, state.camVelY
end

return CameraComfort
