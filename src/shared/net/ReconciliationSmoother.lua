--!strict
-- src/shared/net/ReconciliationSmoother.lua
-- SPDX-License-Identifier: GPL-3.0-or-later
-- Exponential residual visual error smoother for server-reconciled client prediction poses.
-- Smooths both position and shortest-hemisphere quaternion rotation residuals (tau = 0.10 s)
-- while snapping cleanly on large desyncs (> 3.0 m). Pure Luau (zero Roblox API).

local Math3D = require("../sim/Math3D")

export type Vec3 = Math3D.Vec3
export type Quat = Math3D.Quat

export type ReconciliationSmootherState = {
	tauSec: number,
	snapThresholdMeters: number,
	errPos: Vec3,
	errRot: Quat,
}

local ReconciliationSmoother = {}

ReconciliationSmoother.DEFAULT_TAU_SEC = 0.10
ReconciliationSmoother.DEFAULT_SNAP_THRESHOLD_METERS = 3.0

local IDENTITY_QUAT: Quat = { w = 1.0, x = 0.0, y = 0.0, z = 0.0 }
local ZERO_VEC: Vec3 = { x = 0.0, y = 0.0, z = 0.0 }

function ReconciliationSmoother.new(tauSec: number?, snapThresholdMeters: number?): ReconciliationSmootherState
	return {
		tauSec = tauSec or ReconciliationSmoother.DEFAULT_TAU_SEC,
		snapThresholdMeters = snapThresholdMeters or ReconciliationSmoother.DEFAULT_SNAP_THRESHOLD_METERS,
		errPos = { x = 0.0, y = 0.0, z = 0.0 },
		errRot = { w = 1.0, x = 0.0, y = 0.0, z = 0.0 },
	}
end

function ReconciliationSmoother.reset(state: ReconciliationSmootherState)
	state.errPos = { x = 0.0, y = 0.0, z = 0.0 }
	state.errRot = { w = 1.0, x = 0.0, y = 0.0, z = 0.0 }
end

-- Record visual error between the previously displayed pose and the newly reconciled pose.
-- Returns true if the residual exceeded snapThresholdMeters and snapped directly to the new pose.
function ReconciliationSmoother.recordCorrection(
	state: ReconciliationSmootherState,
	renderedBeforePos: Vec3,
	renderedBeforeRot: Quat,
	newInterpPos: Vec3,
	newInterpRot: Quat
): boolean
	local deltaPos = Math3D.sub(renderedBeforePos, newInterpPos)
	if Math3D.len(deltaPos) > state.snapThresholdMeters then
		ReconciliationSmoother.reset(state)
		return true
	end

	local rawRot = Math3D.quatNormalize(Math3D.quatMul(renderedBeforeRot, Math3D.quatConjugate(newInterpRot)))
	if rawRot.w < 0.0 then
		rawRot = {
			w = -rawRot.w,
			x = -rawRot.x,
			y = -rawRot.y,
			z = -rawRot.z,
		}
	end

	state.errPos = deltaPos
	state.errRot = rawRot
	return false
end

function ReconciliationSmoother.decay(state: ReconciliationSmootherState, dt: number)
	if dt <= 0.0 then
		return
	end
	if state.tauSec <= 0.0 then
		ReconciliationSmoother.reset(state)
		return
	end

	local k = math.exp(-dt / state.tauSec)
	local decayedPos = Math3D.scale(state.errPos, k)
	if Math3D.lenSq(decayedPos) < 1e-10 then
		state.errPos = ZERO_VEC
	else
		state.errPos = decayedPos
	end

	local decayedRot = Math3D.quatSlerp(IDENTITY_QUAT, state.errRot, k)
	if 1.0 - math.abs(decayedRot.w) < 1e-8 then
		state.errRot = IDENTITY_QUAT
	else
		state.errRot = decayedRot
	end
end

function ReconciliationSmoother.apply(
	state: ReconciliationSmootherState,
	interpPos: Vec3,
	interpRot: Quat
): (Vec3, Quat)
	return Math3D.add(interpPos, state.errPos), Math3D.quatNormalize(Math3D.quatMul(state.errRot, interpRot))
end

return table.freeze(ReconciliationSmoother)
