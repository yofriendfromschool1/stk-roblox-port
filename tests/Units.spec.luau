--!strict
-- tests/Units.spec.luau
-- SPDX-License-Identifier: GPL-3.0-or-later

local Units = require("../src/shared/Units")

local function assertNear(actual: number, expected: number, eps: number?, label: string?)
	local tolerance = eps or 1e-9
	if math.abs(actual - expected) > tolerance then
		local prefix = if label then label .. ": " else ""
		error(string.format("%sexpected %s (±%g), got %s", prefix, tostring(expected), tolerance, tostring(actual)))
	end
end

export type TestCase = {
	name: string,
	fn: () -> (),
}

local tests: { TestCase } = {
	{
		name = "constants match locked 1.0 m/stud scale and module is frozen",
		fn = function()
			assert(Units.METERS_PER_STUD == 1.0, "METERS_PER_STUD should equal 1.0")
			assertNear(Units.STUDS_PER_METER * Units.METERS_PER_STUD, 1, 1e-12, "reciprocal product")
			assert(table.isfrozen(Units) == true, "Units table should be frozen")
		end,
	},
	{
		name = "length conversions (meters <-> studs)",
		fn = function()
			assert(Units.metersToStuds(0) == 0, "0 m should be 0 studs")
			assert(Units.studsToMeters(0) == 0, "0 studs should be 0 m")
			assertNear(Units.metersToStuds(1.0), 1, 1e-12, "1.0 m -> 1 stud")
			assertNear(Units.studsToMeters(1), 1.0, 1e-12, "1 stud -> 1.0 m")

			for _, meters in { -12.5, -0.5, 0.14, 1, 42.75 } do
				local studs = Units.metersToStuds(meters)
				assertNear(Units.studsToMeters(studs), meters, 1e-12, "meters round-trip")
			end
		end,
	},
	{
		name = "speed conversions (m/s, km/h, studs/s)",
		fn = function()
			assertNear(Units.mpsToStudsPerSec(1.0), 1, 1e-12, "1.0 m/s -> 1 stud/s")
			assertNear(Units.studsPerSecToMps(1), 1.0, 1e-12, "1 stud/s -> 1.0 m/s")
			assertNear(Units.kmhToMps(36), 10, 1e-12, "36 km/h -> 10 m/s")
			assertNear(Units.mpsToKmh(10), 36, 1e-12, "10 m/s -> 36 km/h")
			assertNear(Units.kmhToStudsPerSec(36), 10, 1e-12, "36 km/h -> studs/s")
			assertNear(Units.studsPerSecToKmh(10), 36, 1e-12, "studs/s -> 36 km/h")

			for _, kmh in { -50, 0, 18.5, 90, 120 } do
				local sps = Units.kmhToStudsPerSec(kmh)
				assertNear(Units.studsPerSecToKmh(sps), kmh, 1e-11, "km/h <-> studs/s round-trip")
			end
		end,
	},
	{
		name = "acceleration conversions (m/s^2 <-> studs/s^2)",
		fn = function()
			assertNear(Units.mps2ToStudsPerSec2(9.8), 9.8, 1e-12, "9.8 m/s^2 -> 9.8 studs/s^2")
			assertNear(Units.studsPerSec2ToMps2(9.8), 9.8, 1e-12, "9.8 studs/s^2 -> 9.8 m/s^2")
		end,
	},
}

return tests
