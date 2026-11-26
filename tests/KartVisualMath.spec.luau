--!strict
-- tests/KartVisualMath.spec.luau
-- SPDX-License-Identifier: GPL-3.0-or-later

local KartVisualMath = require("../src/shared/kart/KartVisualMath")

local function assertNear(actual: number, expected: number, eps: number, msg: string)
	if math.abs(actual - expected) > eps then
		error(string.format("%s: expected %.6f, got %.6f", msg, expected, actual))
	end
end

return {
	{
		name = "advanceWheelSpin integrates speed / radius and wraps 2*pi",
		fn = function()
			local frontR = 0.11
			local step1 = KartVisualMath.advanceWheelSpin(0.0, 22.0, 0.01, frontR)
			assertNear(step1, 2.0, 1e-6, "22 m/s * 0.01s / 0.11m = 2.0 rad")

			local wrapped = KartVisualMath.advanceWheelSpin(6.0, 22.0, 0.01, frontR)
			assert(wrapped >= 0 and wrapped < 2 * math.pi, "wrapped angle stays within [0, 2*pi)")
		end,
	},
	{
		name = "computeSteerWheelAngleRad clamps to +-30 deg",
		fn = function()
			assertNear(KartVisualMath.computeSteerWheelAngleRad(0), 0, 1e-6, "neutral steer")
			assertNear(KartVisualMath.computeSteerWheelAngleRad(-1), -math.rad(30), 1e-6, "full left clamp")
			assertNear(KartVisualMath.computeSteerWheelAngleRad(2.5), math.rad(30), 1e-6, "over-steer clamped")
		end,
	},
	{
		name = "computeWheelSuspensionOffsetY tracks rest delta and clamps STK min/max",
		fn = function()
			local rest = KartVisualMath.DEFAULT_REST_SUSPENSION_M
			assertNear(KartVisualMath.computeWheelSuspensionOffsetY(rest), 0.0, 1e-6, "zero offset at equilibrium")
			assertNear(
				KartVisualMath.computeWheelSuspensionOffsetY(rest - 0.05),
				0.05,
				1e-6,
				"compressed lifts wheel up"
			)
			assertNear(
				KartVisualMath.computeWheelSuspensionOffsetY(0.0),
				KartVisualMath.MAX_VISUAL_SUSPENSION_M,
				1e-6,
				"max clamp"
			)
			assertNear(
				KartVisualMath.computeWheelSuspensionOffsetY(1.0),
				KartVisualMath.MIN_VISUAL_SUSPENSION_M,
				1e-6,
				"min clamp"
			)
		end,
	},
	{
		name = "computeBodyGroundOffsetY aligns wheel bottoms with road plane at rest",
		fn = function()
			assertNear(
				KartVisualMath.computeBodyGroundOffsetY(0.2912),
				-0.2912,
				1e-6,
				"body origin shifted down by equilibrium suspension"
			)
		end,
	},
	{
		name = "isBubblegumShieldVisible matches STK slow/fast flash schedule",
		fn = function()
			-- Hidden at/below 0; steady at >= 3.0s (360 ticks)
			assert(not KartVisualMath.isBubblegumShieldVisible(-1), "negative ticks hidden")
			assert(not KartVisualMath.isBubblegumShieldVisible(0), "0 ticks hidden")
			assert(KartVisualMath.isBubblegumShieldVisible(1200), "10.0s steady visible")
			assert(KartVisualMath.isBubblegumShieldVisible(360), "3.0s steady boundary visible")

			-- Slow flash [60, 359]: ticksPerFlash = 24, visible iff (ticks // 24) % 2 == 0
			assert(KartVisualMath.isBubblegumShieldVisible(359), "359t -> 14 (even) visible")
			assert(KartVisualMath.isBubblegumShieldVisible(336), "336t -> 14 (even) visible")
			assert(not KartVisualMath.isBubblegumShieldVisible(335), "335t -> 13 (odd) hidden")
			assert(not KartVisualMath.isBubblegumShieldVisible(312), "312t -> 13 (odd) hidden")
			assert(KartVisualMath.isBubblegumShieldVisible(311), "311t -> 12 (even) visible")
			assert(KartVisualMath.isBubblegumShieldVisible(60), "60t -> 2 (even) visible")

			-- Fast flash [1, 59]: ticksPerFlash = floor(0.07 * 120) = 8, visible iff (ticks // 8) % 2 == 0
			assert(not KartVisualMath.isBubblegumShieldVisible(59), "59t -> 7 (odd) hidden")
			assert(not KartVisualMath.isBubblegumShieldVisible(56), "56t -> 7 (odd) hidden")
			assert(KartVisualMath.isBubblegumShieldVisible(55), "55t -> 6 (even) visible")
			assert(not KartVisualMath.isBubblegumShieldVisible(15), "15t -> 1 (odd) hidden")
			assert(not KartVisualMath.isBubblegumShieldVisible(8), "8t -> 1 (odd) hidden")
			assert(KartVisualMath.isBubblegumShieldVisible(7), "7t -> 0 (even) visible")
			assert(KartVisualMath.isBubblegumShieldVisible(1), "1t -> 0 (even) visible")
		end,
	},
}
