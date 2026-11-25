--!strict
-- src/shared/kart/TuxBoundsData.lua
-- SPDX-License-Identifier: GPL-3.0-or-later
-- Source: build/karts/tux/tux-report.json (METERS_PER_STUD = 1.0, STK rev 18627).
-- Expected MeshPart bounds (Size and MeshSize in studs) per Tux submesh.

local TuxBoundsData = {}

TuxBoundsData.TOLERANCE_STUDS = 0.01

TuxBoundsData.submeshes = table.freeze({
	Body_Engine = table.freeze({ 0.73511, 0.35332, 1.25557 }),
	Body_Chassis = table.freeze({ 0.82126, 0.22952, 1.31575 }),
	Body_Steering = table.freeze({ 0.51925, 0.43313, 1.02222 }),
	Driver = table.freeze({ 0.36347, 0.64585, 0.44230 }),
	WheelFrontLeft = table.freeze({ 0.19783, 0.21981, 0.21981 }),
	WheelFrontRight = table.freeze({ 0.19783, 0.21981, 0.21981 }),
	WheelRearLeft = table.freeze({ 0.30200, 0.28000, 0.28000 }),
	WheelRearRight = table.freeze({ 0.30200, 0.28000, 0.28000 }),
}) :: { [string]: { number } }

return TuxBoundsData
