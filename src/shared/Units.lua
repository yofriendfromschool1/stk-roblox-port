--!strict
-- src/shared/Units.lua
-- SPDX-License-Identifier: GPL-3.0-or-later

local METERS_PER_STUD = 1.0
local STUDS_PER_METER = 1 / METERS_PER_STUD
local KMH_PER_MPS = 3.6

local Units = {}

Units.METERS_PER_STUD = METERS_PER_STUD
Units.STUDS_PER_METER = STUDS_PER_METER

function Units.metersToStuds(meters: number): number
	return meters * STUDS_PER_METER
end

function Units.studsToMeters(studs: number): number
	return studs * METERS_PER_STUD
end

function Units.mpsToStudsPerSec(mps: number): number
	return mps * STUDS_PER_METER
end

function Units.studsPerSecToMps(sps: number): number
	return sps * METERS_PER_STUD
end

function Units.mps2ToStudsPerSec2(mps2: number): number
	return mps2 * STUDS_PER_METER
end

function Units.studsPerSec2ToMps2(sps2: number): number
	return sps2 * METERS_PER_STUD
end

function Units.kmhToMps(kmh: number): number
	return kmh / KMH_PER_MPS
end

function Units.mpsToKmh(mps: number): number
	return mps * KMH_PER_MPS
end

function Units.kmhToStudsPerSec(kmh: number): number
	return (kmh / KMH_PER_MPS) * STUDS_PER_METER
end

function Units.studsPerSecToKmh(sps: number): number
	return sps * METERS_PER_STUD * KMH_PER_MPS
end

return table.freeze(Units)
