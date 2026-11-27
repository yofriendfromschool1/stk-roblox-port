--!strict
-- src/shared/camera/CameraComfort.lua
-- SPDX-License-Identifier: GPL-3.0-or-later
-- Camera vertical comfort filter: deadzone, framerate-independent exponential follow
-- (alpha = 1 - exp(-dt / tau)), vertical velocity clamp, and separate look-target low-pass filter.
-- Upstream STK 1.5 baseline (src/graphics/camera/camera_normal.cpp:L121-L146,
-- src/config/user_config.hpp:L1046,L1051) uses 1st-order exponential lag without
-- deadzone or look-target filtering; comfort additions logged in docs/divergences.md.

export type CameraComfortConfig = {
	deadzone: number,
	tau: number,
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
	local tau = math.max(0.0, cfg.tau)
	local maxVel = math.max(0.5, cfg.maxVel)

	-- 1) Vertical deadzone: bumps within +/- deadzone around anchor do not move the target.
	local err = targetY - state.deadzoneAnchorY
	if math.abs(err) > deadzone then
		state.deadzoneAnchorY = targetY - math.sign(err) * deadzone
	end

	-- 2) Framerate-independent exponential position follow with vertical velocity clamp.
	local alphaY = if tau > 1e-4 then 1.0 - math.exp(-dt / tau) else 1.0
	local desiredY = state.camY + (state.deadzoneAnchorY - state.camY) * alphaY
	local maxStep = maxVel * dt
	local deltaY = math.clamp(desiredY - state.camY, -maxStep, maxStep)
	state.camVelY = if dt > 1e-6 then deltaY / dt else 0.0
	state.camY += deltaY

	if math.abs(state.deadzoneAnchorY - state.camY) < 1e-4 and math.abs(state.camVelY) < 1e-4 then
		state.camY = state.deadzoneAnchorY
		state.camVelY = 0.0
	end

	-- 3) Separate framerate-independent exponential low-pass on vertical look target.
	local alphaLook = if cfg.lookSmoothSec > 1e-4 then 1.0 - math.exp(-dt / cfg.lookSmoothSec) else 1.0
	state.lookY += (targetLookY - state.lookY) * alphaLook

	return state.camY, state.lookY, state.camVelY
end

return CameraComfort
