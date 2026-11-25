--!strict
-- tests/Reconciliation.spec.luau
-- SPDX-License-Identifier: GPL-3.0-or-later

local Math3D = require("../src/shared/sim/Math3D")
local ReconciliationSmoother = require("../src/shared/net/ReconciliationSmoother")

local function assertNear(actual: number, expected: number, tol: number, label: string)
	if math.abs(actual - expected) > tol then
		error(string.format("%s: expected %.6f +/- %.6f, got %.6f", label, expected, tol, actual))
	end
end

return {
	{
		name = "recordCorrection preserves rendered pose and decays pos+rot exponentially toward zero",
		fn = function()
			local s = ReconciliationSmoother.new(0.10, 3.0)
			local beforePos = { x = 1.0, y = 0.5, z = 10.0 }
			local beforeRot = Math3D.quatFromAxisAngle({ x = 0, y = 1, z = 0 }, math.rad(20))
			local newPos = { x = 0.2, y = 0.3, z = 9.4 }
			local newRot = Math3D.quatFromAxisAngle({ x = 0, y = 1, z = 0 }, math.rad(5))

			local snapped = ReconciliationSmoother.recordCorrection(s, beforePos, beforeRot, newPos, newRot)
			assert(not snapped, "sub-threshold residual must smooth rather than snap")

			local immediatePos, immediateRot = ReconciliationSmoother.apply(s, newPos, newRot)
			assertNear(immediatePos.x, beforePos.x, 1e-6, "immediate apply preserves X")
			assertNear(immediatePos.y, beforePos.y, 1e-6, "immediate apply preserves Y")
			assertNear(immediatePos.z, beforePos.z, 1e-6, "immediate apply preserves Z")
			local rotDot = math.abs(
				immediateRot.w * beforeRot.w
					+ immediateRot.x * beforeRot.x
					+ immediateRot.y * beforeRot.y
					+ immediateRot.z * beforeRot.z
			)
			assertNear(rotDot, 1.0, 1e-6, "immediate apply preserves rotation")

			-- Decay by 1 * tau (0.10 s): error magnitude shrinks by exp(-1)
			ReconciliationSmoother.decay(s, 0.10)
			local expectedScale = math.exp(-1.0)
			assertNear(s.errPos.x, 0.8 * expectedScale, 1e-5, "errPos.x decays by exp(-dt/tau)")
			assertNear(s.errPos.z, 0.6 * expectedScale, 1e-5, "errPos.z decays by exp(-dt/tau)")
			local errAngleRad = 2.0 * math.acos(math.clamp(s.errRot.w, -1.0, 1.0))
			assertNear(errAngleRad, math.rad(15.0) * expectedScale, 1e-4, "angular error decays by exp(-dt/tau)")

			-- After many tau intervals, residual snaps cleanly to zero
			for _ = 1, 20 do
				ReconciliationSmoother.decay(s, 0.10)
			end
			assertNear(Math3D.len(s.errPos), 0.0, 1e-8, "position error converges to 0")
			assertNear(s.errRot.w, 1.0, 1e-8, "rotation error converges to identity")
		end,
	},
	{
		name = "antipodal quaternion sign flip picks shortest hemisphere without 360-deg spin",
		fn = function()
			local s = ReconciliationSmoother.new(0.10, 3.0)
			local q = Math3D.quatFromAxisAngle({ x = 0, y = 1, z = 0 }, math.rad(35))
			local negQ = { w = -q.w, x = -q.x, y = -q.y, z = -q.z }
			local pos = { x = 0, y = 0, z = 0 }

			ReconciliationSmoother.recordCorrection(s, pos, q, pos, negQ)
			assert(s.errRot.w >= 0.999999, "shortest-hemisphere error w must stay positive near 1.0")
		end,
	},
	{
		name = "large desync above snapThresholdMeters hard-snaps without residual lag",
		fn = function()
			local s = ReconciliationSmoother.new(0.10, 3.0)
			local beforePos = { x = 0, y = 0, z = 0 }
			local newPos = { x = 5.0, y = 0, z = 0 }
			local idRot = Math3D.quatIdentity()

			local snapped = ReconciliationSmoother.recordCorrection(s, beforePos, idRot, newPos, idRot)
			assert(snapped, "delta > 3.0 m must snap")
			local outPos, _ = ReconciliationSmoother.apply(s, newPos, idRot)
			assertNear(outPos.x, 5.0, 1e-8, "snapped apply hits newPos.x immediately")
		end,
	},
	{
		name = "zero-error deterministic replay leaves exact zero residual",
		fn = function()
			local s = ReconciliationSmoother.new(0.10, 3.0)
			local pos = { x = 12.5, y = 0.291, z = -4.0 }
			local rot = Math3D.quatFromAxisAngle({ x = 0, y = 1, z = 0 }, math.rad(-42))

			local snapped = ReconciliationSmoother.recordCorrection(s, pos, rot, pos, rot)
			assert(not snapped, "zero-delta does not trigger snap")
			assertNear(Math3D.len(s.errPos), 0.0, 1e-8, "errPos is zero")
			assertNear(s.errRot.w, 1.0, 1e-8, "errRot is identity")
		end,
	},
}
