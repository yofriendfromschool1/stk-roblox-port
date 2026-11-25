--!strict
-- tests/RaceHudMath.spec.luau
-- SPDX-License-Identifier: GPL-3.0-or-later

local RaceHudMath = require("../src/shared/hud/RaceHudMath")

export type TestCase = {
	name: string,
	fn: () -> (),
}

local function assertNear(actual: number, expected: number, eps: number?, label: string?)
	local tolerance = eps or 1e-6
	if actual ~= actual or math.abs(actual - expected) > tolerance then
		local prefix = if label then label .. ": " else ""
		error(string.format("%sexpected %s (+/-%g), got %s", prefix, tostring(expected), tolerance, tostring(actual)))
	end
end

local tests: { TestCase } = {
	{
		name = "computeScale matches sqrt(W/800) * sqrt(H/450) from race_gui.cpp:L378-L379",
		fn = function()
			assertNear(RaceHudMath.computeScale(800, 450), 1.0, 1e-6, "800x450 base scale")
			assertNear(RaceHudMath.computeScale(1280, 720), 1.6, 1e-6, "1280x720 scale")
			assertNear(RaceHudMath.computeScale(1920, 1080), 2.4, 1e-6, "1920x1080 scale")
		end,
	},
	{
		name = "computeSpeedometerRect and computeEnergyMeterRect match bottom-right layout",
		fn = function()
			-- At 800x450 (scale = 1.0): speedometer 128x128 at (648, 312); energy 94x94 at (696, 344)
			local sRect = RaceHudMath.computeSpeedometerRect(800, 450)
			assert(sRect.width == 128 and sRect.height == 128, "speedometer size at 800x450")
			assert(sRect.x == 648 and sRect.y == 312, "speedometer pos at 800x450")

			local eRect = RaceHudMath.computeEnergyMeterRect(800, 450)
			assert(eRect.width == 94 and eRect.height == 94, "energy meter size at 800x450")
			assert(eRect.x == 696 and eRect.y == 344, "energy meter pos at 800x450")

			-- Energy meter sits slightly closer to bottom-right corner than speedometer at 1920x1080 too
			local s1080 = RaceHudMath.computeSpeedometerRect(1920, 1080)
			local e1080 = RaceHudMath.computeEnergyMeterRect(1920, 1080)
			assert(s1080.width == 307 and e1080.width == 225, "1080p scaled dimensions")
			assert(e1080.x + e1080.width > s1080.x + s1080.width, "energy aligns further right than speedometer")
		end,
	},
	{
		name = "snapSpeedRatio enforces zero gate, 40 m/s ceiling, and 1/8 segment border snap",
		fn = function()
			assertNear(RaceHudMath.snapSpeedRatio(-5.0), 0.0, 1e-6, "reverse speed hidden")
			assertNear(RaceHudMath.snapSpeedRatio(0.0), 0.0, 1e-6, "zero speed hidden")
			assertNear(RaceHudMath.snapSpeedRatio(50.0), 1.0, 1e-6, "clamped above 40 m/s")
			assertNear(RaceHudMath.snapSpeedRatio(20.0), 0.5 - 0.0045, 1e-6, "border snap at 0.5")
			assertNear(RaceHudMath.snapSpeedRatio(10.0), 0.25 - 0.0045, 1e-6, "border snap at 0.25")
			assertNear(RaceHudMath.snapSpeedRatio(15.0), 0.375 - 0.0045, 1e-6, "border snap at 0.375")
			assertNear(RaceHudMath.snapSpeedRatio(12.0), 0.30, 1e-6, "mid-segment unclipped")
		end,
	},
	{
		name = "snapNitroRatio enforces bounds and 1/5 segment border snap",
		fn = function()
			assertNear(RaceHudMath.snapNitroRatio(0.0, 20.0), 0.0, 1e-6, "empty nitro")
			assertNear(RaceHudMath.snapNitroRatio(25.0, 20.0), 1.0, 1e-6, "clamped full nitro")
			assertNear(RaceHudMath.snapNitroRatio(4.0, 20.0), 0.2 - 0.003, 1e-6, "border snap at 0.2")
			assertNear(RaceHudMath.snapNitroRatio(10.0, 20.0), 0.5, 1e-6, "mid-segment unclipped")
		end,
	},
	{
		name = "radial sweep angles traverse monotonically within half-plane bounds",
		fn = function()
			local s0 = RaceHudMath.computeSpeedSweepAngleDeg(0.0)
			local sHalf = RaceHudMath.computeSpeedSweepAngleDeg(0.5)
			local sFull = RaceHudMath.computeSpeedSweepAngleDeg(1.0)
			assert(s0 < sHalf and sHalf < sFull, "speed sweep increases CW monotonically")
			assert(sHalf - s0 < 180.0 and sFull - sHalf < 180.0, "each speed half spans < 180 deg")

			local n0 = RaceHudMath.computeNitroSweepAngleDeg(0.0)
			local nFull = RaceHudMath.computeNitroSweepAngleDeg(1.0)
			assert(n0 > nFull, "nitro sweep decreases CCW monotonically")
			assert(n0 - nFull < 180.0, "nitro arc spans < 180 deg")
		end,
	},
	{
		name = "getModeVisibility reproduces STK per-mode HUD flags from src/modes/*.hpp",
		fn = function()
			local normal = RaceHudMath.getModeVisibility("NORMAL_RACE", { isRacePhase = true, numKarts = 4 })
			assert(
				normal.showTimer and normal.showRankDigit and normal.showLaps and normal.showLapsTarget,
				"normal race"
			)
			assert(normal.showMiniMap and normal.showPlayerIcons and normal.showSpeedAndEnergy, "normal race widgets")

			local lapTrial = RaceHudMath.getModeVisibility("LAP_TRIAL", { isRacePhase = true, numKarts = 2 })
			assert(lapTrial.showTimer and lapTrial.showLaps and not lapTrial.showLapsTarget, "lap trial hides target")

			local soccer = RaceHudMath.getModeVisibility("SOCCER", { isRacePhase = true, soccerPlayerList = false })
			assert(soccer.showTimer and not soccer.showRankDigit and not soccer.showLaps, "soccer mode")
			assert(not soccer.showPlayerIcons, "soccer player list option respected")

			local overworld = RaceHudMath.getModeVisibility("OVERWORLD", { isRacePhase = true })
			assert(not overworld.showTimer and not overworld.showRankDigit and not overworld.showLaps, "overworld")

			local tutorial = RaceHudMath.getModeVisibility("TUTORIAL", { isRacePhase = true })
			assert(not tutorial.showTimer and not tutorial.showLaps and not tutorial.showPlayerIcons, "tutorial")

			local countdown = RaceHudMath.getModeVisibility("TIME_TRIAL", { isRacePhase = false })
			assert(not countdown.showTimer and countdown.showMiniMap and not countdown.showSpeedAndEnergy, "countdown")
		end,
	},
	{
		name = "formatRaceTime, computeTimerRect, computeRankAnchor, and computePlayerIconRect match STK",
		fn = function()
			assert(RaceHudMath.formatRaceTime(0) == "00:00.000", "zero time")
			assert(RaceHudMath.formatRaceTime(-2.5) == "00:00.000", "negative clamped")
			assert(RaceHudMath.formatRaceTime(65.432) == "01:05.432", "mm:ss.mmm formatting")
			assert(RaceHudMath.formatRaceTime(4000.0) == "59:59.999", "capped at 59:59.999")

			local tRect = RaceHudMath.computeTimerRect(800, 450)
			assert(tRect.y == 9 and tRect.x + tRect.width == 790, "top-right timer margin 10 and 2% Y")

			local sRect = RaceHudMath.computeSpeedometerRect(800, 450)
			local rAnchor = RaceHudMath.computeRankAnchor(sRect)
			assert(rAnchor.x == sRect.x + math.floor(0.64 * sRect.width), "rank X = 0.64 * meter_width")
			assert(
				rAnchor.y == sRect.y + sRect.height - math.floor(0.49 * sRect.height),
				"rank Y = -0.49 * meter_height"
			)

			local pRect = RaceHudMath.computePlayerIconRect(1024, 720, 1, 180, 1, true)
			assert(pRect.x == 10 and pRect.y == 25 and pRect.width == 60, "top-left local kart icon at 1024w")
		end,
	},
	{
		name = "projectToMinimap matches Graph::makeMiniMap & Track::mapPoint2MiniMap for outline and kart dot",
		fn = function()
			local layout = RaceHudMath.computeMinimapLayout(800, 450, 0)
			assert(layout.width == 168 and layout.x == 9 and layout.mapBottom == 9, "minimap layout at 800x450")

			-- Symmetric 512x512 arena: origin maps to exact center of minimap
			local arenaPts = {
				{ x = -256, z = -256 },
				{ x = 256, z = 256 },
			}
			local bounds = RaceHudMath.computeMinimapBounds(arenaPts)
			assertNear(bounds.range, 512, 1e-6, "arena range")

			local cx, cy = RaceHudMath.projectToMinimap(0, 0, bounds, 200, 200, false)
			assertNear(cx, 100, 1e-6, "origin maps to minimap center X")
			assertNear(cy, 100, 1e-6, "origin maps to minimap center Y")

			-- Corners: (+X, +Z_stk) -> right-top (200, 0); (-X, -Z_stk) -> left-bottom (0, 200)
			local rtx, rty = RaceHudMath.projectToMinimap(256, 256, bounds, 200, 200, false)
			assertNear(rtx, 200, 1e-6, "maxX -> right edge")
			assertNear(rty, 0, 1e-6, "maxZ -> top edge")
			local lbx, lby = RaceHudMath.projectToMinimap(-256, -256, bounds, 200, 200, false)
			assertNear(lbx, 0, 1e-6, "minX -> left edge")
			assertNear(lby, 200, 1e-6, "minZ -> bottom edge")

			-- Soccer blue-team invertXZ flips both axes cleanly even on asymmetric bounds
			local asymBounds = RaceHudMath.computeMinimapBounds({ { x = -10, z = 0 }, { x = 30, z = 20 } })
			assertNear(asymBounds.range, 40, 1e-6, "asymmetric max(dx, dz)")
			local ix, iy = RaceHudMath.projectToMinimap(30, 20, asymBounds, 100, 100, true)
			assertNear(ix, 0, 1e-6, "inverted maxX -> 0")
			assertNear(iy, 100, 1e-6, "inverted maxZ -> mapHeight")
		end,
	},
}

return tests
