--!strict
-- src/shared/hud/RaceHudMath.lua
-- SPDX-License-Identifier: GPL-3.0-or-later
-- ported from src/states_screens/race_gui.cpp:L171-L266, L320-L487, L564-L699, L795-L1131,
-- src/states_screens/race_gui_base.cpp:L785-L838, src/tracks/track.cpp:L837-L850,
-- src/tracks/graph.cpp:L511-L540, L590-L595, src/utils/string_utils.cpp:L565-L655 (STK 1.5)
-- Pure-math HUD layout, mode-conditional visibility, timer formatting, & minimap projection (zero Roblox API).

export type HudRect = {
	x: number,
	y: number,
	width: number,
	height: number,
}

export type RankAnchor = {
	x: number,
	y: number,
	fontSize: number,
}

export type MinimapLayout = {
	x: number,
	y: number,
	width: number,
	height: number,
	mapBottom: number,
	playerIconSize: number,
	aiIconSize: number,
}

export type MinimapBounds = {
	minX: number,
	maxX: number,
	minZ: number,
	maxZ: number,
	range: number,
}

export type Point2D = {
	x: number,
	z: number,
}

export type RaceMode =
	"NORMAL_RACE"
	| "TIME_TRIAL"
	| "LAP_TRIAL"
	| "FOLLOW_THE_LEADER"
	| "THREE_STRIKES"
	| "FREE_FOR_ALL"
	| "CAPTURE_THE_FLAG"
	| "SOCCER"
	| "OVERWORLD"
	| "TUTORIAL"

export type ModeVisibilityOptions = {
	isRacePhase: boolean?,
	hasGhostKarts: boolean?,
	numKarts: number?,
	minimapDisplay: number?, -- 0 bottom-left, 1 right, 2 hidden, 3 center (user_config.hpp:L1278)
	hasNavMesh: boolean?,
	powerupDisplay: number?, -- 0 center, 1 right, 2 hidden (user_config.hpp:L1299)
	isSpectatorTopView: boolean?,
	soccerPlayerList: boolean?,
	isMultitouch: boolean?,
}

export type ModeVisibility = {
	showTimer: boolean,
	showRankDigit: boolean,
	showLaps: boolean,
	showLapsTarget: boolean,
	showLiveDifference: boolean,
	showMiniMap: boolean,
	showPlayerIcons: boolean,
	showPowerups: boolean,
	showSpeedAndEnergy: boolean,
}

local SPEED_ANGLES_DEG = {
	127.05, -- B2: speed_ratio = 0.000
	152.54, -- C:  speed_ratio = 0.125
	177.71, -- D:  speed_ratio = 0.250
	203.45, -- E:  speed_ratio = 0.375
	228.89, -- F:  speed_ratio = 0.500
	254.32, -- G:  speed_ratio = 0.625
	279.63, -- H:  speed_ratio = 0.750
	305.35, -- I:  speed_ratio = 0.875
	330.66, -- J1: speed_ratio = 1.000
}

local NITRO_ANGLES_DEG = {
	117.44, -- B2: state = 0.0
	91.52, -- C:  state = 0.2
	65.52, -- D:  state = 0.4
	39.35, -- E:  state = 0.6
	13.32, -- F:  state = 0.8
	-12.56, -- G1: state = 1.0
}

local RaceHudMath = {
	REF_WIDTH = 800, -- race_gui.cpp:L378
	REF_HEIGHT = 450, -- race_gui.cpp:L379
	SPEED_WIDTH = 128, -- race_gui.cpp:L1018
	SPEED_MARGIN_RIGHT = 24.0, -- race_gui.cpp:L1029
	SPEED_MARGIN_BOTTOM = 10.0, -- race_gui.cpp:L1030
	GAUGE_WIDTH = 94, -- race_gui.cpp:L801
	GAUGE_MARGIN_RIGHT = 9.5, -- race_gui.cpp:L811
	GAUGE_MARGIN_BOTTOM = 11.5, -- race_gui.cpp:L812
	MAX_DISPLAY_SPEED_MPS = 40.0, -- race_gui.cpp:L1052
	SPEED_CENTER_X = 0.546, -- race_gui.cpp:L1076
	SPEED_CENTER_Y = 0.566, -- race_gui.cpp:L1077
	SPEED_START_DEG = SPEED_ANGLES_DEG[1],
	SPEED_MID_DEG = SPEED_ANGLES_DEG[5],
	SPEED_END_DEG = SPEED_ANGLES_DEG[9],
	NITRO_CENTER_X = 0.324, -- race_gui.cpp:L833
	NITRO_CENTER_Y = 0.350, -- race_gui.cpp:L834
	NITRO_START_DEG = NITRO_ANGLES_DEG[1],
	NITRO_END_DEG = NITRO_ANGLES_DEG[6],
	RANK_OFFSET_X_FRAC = 0.64, -- race_gui.cpp:L992
	RANK_OFFSET_Y_FRAC = 0.49, -- race_gui.cpp:L993
	RANK_HEIGHT_FRAC = 0.40, -- race_gui.cpp:L987
	TIMER_MARGIN_RIGHT = 10, -- race_gui.cpp:L426
	TIMER_TOP_FRAC = 0.02, -- race_gui.cpp:L469
	TIMER_BOTTOM_FRAC = 0.06, -- race_gui.cpp:L471
	MINIMAP_REF_DIM = 480.0, -- race_gui.cpp:L195
	MINIMAP_SIZE_DEFAULT = 180.0, -- user_config.hpp:L1282
	MINIMAP_PLAYER_ICON_SIZE = 20.0, -- user_config.hpp:L1290
	MINIMAP_AI_ICON_SIZE = 16.0, -- user_config.hpp:L1286
	MINIMAP_MARGIN = 10.0, -- race_gui.cpp:L242-L243
	PLAYER_LIST_X_BASE = 10, -- race_gui_base.cpp:L793
	PLAYER_LIST_Y_BASE = 25, -- race_gui_base.cpp:L796
	PLAYER_LIST_MIN_ICON = 35, -- race_gui_base.cpp:L824
	PLAYER_LIST_MAX_ICON_AT_1024 = 60, -- race_gui_base.cpp:L822
	POWERUP_SIZE_DEFAULT = 64.0, -- user_config.hpp:L1302
	POWERUP_MARGIN_TOP = 20.0, -- race_gui_base.cpp:L428
	POWERUP_MAX_STACK = 5, -- race_gui_base.cpp:L395
}

export type PowerupLayout = {
	iconSize: number,
	rects: { HudRect },
	manyText: string?,
	manyRect: HudRect?,
}

-- Mode-conditional visibility matching race_gui.cpp & src/modes/*.hpp (STK 1.5)
function RaceHudMath.getModeVisibility(mode: RaceMode, opts: ModeVisibilityOptions?): ModeVisibility
	local o: ModeVisibilityOptions = opts or {}
	local isRacePhase = if o.isRacePhase ~= nil then o.isRacePhase else true
	local isTutorial = (mode == "TUTORIAL")
	local isOverworld = (mode == "OVERWORLD")
	local isArenaMode = (mode == "THREE_STRIKES" or mode == "FREE_FOR_ALL" or mode == "CAPTURE_THE_FLAG")
	local isSoccer = (mode == "SOCCER")
	local isLinear = (mode == "NORMAL_RACE" or mode == "TIME_TRIAL" or mode == "LAP_TRIAL")

	local minimapDisplay = o.minimapDisplay or 0
	local hasNavMesh = if o.hasNavMesh ~= nil then o.hasNavMesh else not (isArenaMode or isSoccer)
	local showMiniMap = (minimapDisplay ~= 2) and (not (isArenaMode or isSoccer) or hasNavMesh)

	if not isRacePhase then
		return {
			showTimer = false,
			showRankDigit = false,
			showLaps = false,
			showLapsTarget = false,
			showLiveDifference = false,
			showMiniMap = showMiniMap,
			showPlayerIcons = false,
			showPowerups = false,
			showSpeedAndEnergy = false,
		}
	end

	local hasTimer = not isOverworld and not isTutorial
	local showRankDigit = (mode ~= "SOCCER" and not isOverworld)
	local showLaps = isLinear and not isTutorial
	local showLapsTarget = (mode == "NORMAL_RACE" or mode == "TIME_TRIAL")
	local numKarts = o.numKarts or 1
	local showLiveDifference = isLinear and (o.hasGhostKarts == true) and numKarts >= 2 and not isTutorial

	local soccerList = if o.soccerPlayerList ~= nil then o.soccerPlayerList else true
	local showPlayerIcons = not isTutorial and (not isSoccer or soccerList)
	local notTopView = not (o.isMultitouch == false and o.isSpectatorTopView == true) and (o.isSpectatorTopView ~= true)
	local showPowerups = notTopView and ((o.powerupDisplay or 0) ~= 2) and not (o.isMultitouch == true)
	local showSpeedAndEnergy = notTopView and not (o.isMultitouch == true)

	return {
		showTimer = hasTimer,
		showRankDigit = showRankDigit,
		showLaps = showLaps,
		showLapsTarget = showLapsTarget,
		showLiveDifference = showLiveDifference,
		showMiniMap = showMiniMap,
		showPlayerIcons = showPlayerIcons,
		showPowerups = showPowerups,
		showSpeedAndEnergy = showSpeedAndEnergy,
	}
end

-- Fullscreen single-player viewport scale factor (race_gui.cpp:L378-L379)
function RaceHudMath.computeScale(viewportW: number, viewportH: number): number
	if viewportW <= 0 or viewportH <= 0 then
		return 1.0
	end
	return math.sqrt(viewportW / RaceHudMath.REF_WIDTH) * math.sqrt(viewportH / RaceHudMath.REF_HEIGHT)
end

-- Speedometer bounding rectangle in screen pixels (race_gui.cpp:L1018-L1035)
function RaceHudMath.computeSpeedometerRect(viewportW: number, viewportH: number): HudRect
	local scale = RaceHudMath.computeScale(viewportW, viewportH)
	local meter = math.floor(RaceHudMath.SPEED_WIDTH * scale)
	local offsetX = math.floor(viewportW - meter - RaceHudMath.SPEED_MARGIN_RIGHT * scale)
	local offsetY = math.floor(viewportH - RaceHudMath.SPEED_MARGIN_BOTTOM * scale)
	return {
		x = offsetX,
		y = offsetY - meter,
		width = meter,
		height = meter,
	}
end

-- Nitro energy meter bounding rectangle in screen pixels (race_gui.cpp:L801-L819)
function RaceHudMath.computeEnergyMeterRect(viewportW: number, viewportH: number): HudRect
	local scale = RaceHudMath.computeScale(viewportW, viewportH)
	local gauge = math.floor(RaceHudMath.GAUGE_WIDTH * scale)
	local offsetX = math.floor(viewportW - gauge - RaceHudMath.GAUGE_MARGIN_RIGHT * scale)
	local offsetY = math.floor(viewportH - RaceHudMath.GAUGE_MARGIN_BOTTOM * scale)
	return {
		x = offsetX,
		y = offsetY - gauge,
		width = gauge,
		height = gauge,
	}
end

-- Gauge-center rank anchor inside speedometer rect (race_gui.cpp:L987-L995)
function RaceHudMath.computeRankAnchor(speedRect: HudRect): RankAnchor
	return {
		x = speedRect.x + math.floor(RaceHudMath.RANK_OFFSET_X_FRAC * speedRect.width),
		y = speedRect.y + speedRect.height - math.floor(
			RaceHudMath.RANK_HEIGHT_FRAC * speedRect.height * 0 + RaceHudMath.RANK_OFFSET_Y_FRAC * speedRect.height
		),
		fontSize = math.max(14, math.floor(RaceHudMath.RANK_HEIGHT_FRAC * speedRect.height)),
	}
end

-- Elapsed timer formatting matching StringUtils::timeToString(time, 3, true, false) (string_utils.cpp:L565-L655)
function RaceHudMath.formatRaceTime(seconds: number): string
	if seconds ~= seconds or seconds <= 0 then
		return "00:00.000"
	end
	local msTotal = math.floor(seconds * 1000.0 + 0.5)
	if msTotal >= 60 * 60 * 1000 then
		return "59:59.999"
	end
	local ms = msTotal % 1000
	local totalSec = math.floor(msTotal / 1000)
	local sec = totalSec % 60
	local min = math.floor(totalSec / 60) % 60
	return string.format("%02d:%02d.%03d", min, sec, ms)
end

-- Top-right global race timer rect (race_gui.cpp:L426, L468-L471)
function RaceHudMath.computeTimerRect(viewportW: number, viewportH: number): HudRect
	local y = math.floor(viewportH * RaceHudMath.TIMER_TOP_FRAC)
	local h = math.max(24, math.floor(viewportH * (RaceHudMath.TIMER_BOTTOM_FRAC - RaceHudMath.TIMER_TOP_FRAC)))
	-- Reserve width for "99:99.999" (approx 5.6 * height in monospace/digit font)
	local timerWidth = math.floor(h * 5.8)
	local distFromRight = RaceHudMath.TIMER_MARGIN_RIGHT + timerWidth
	return {
		x = math.max(0, viewportW - distFromRight),
		y = y,
		width = timerWidth,
		height = h,
	}
end

-- Minimap screen rect & icon sizes (race_gui.cpp:L194-L244, L584-L588)
function RaceHudMath.computeMinimapLayout(viewportW: number, viewportH: number, displayMode: number?): MinimapLayout
	local scaling = math.min(viewportW, viewportH) / RaceHudMath.MINIMAP_REF_DIM
	local mapWidth = math.floor(RaceHudMath.MINIMAP_SIZE_DEFAULT * scaling)
	local mapHeight = mapWidth
	local playerIconSize = math.floor(RaceHudMath.MINIMAP_PLAYER_ICON_SIZE * scaling)
	local aiIconSize = math.floor(RaceHudMath.MINIMAP_AI_ICON_SIZE * scaling)
	local mode = displayMode or 0

	local mapLeft: number
	local mapBottom: number
	if mode == 1 then
		mapLeft = math.floor(viewportW - mapWidth - RaceHudMath.MINIMAP_MARGIN * scaling)
		mapBottom = math.floor(3 * viewportH / 4 - mapHeight)
	elseif mode == 3 then
		mapLeft = math.min(math.floor(viewportW / 2), math.max(0, viewportW - mapWidth))
		mapBottom = math.floor(RaceHudMath.MINIMAP_MARGIN * scaling)
	else
		mapLeft = math.floor(RaceHudMath.MINIMAP_MARGIN * scaling)
		mapBottom = math.floor(RaceHudMath.MINIMAP_MARGIN * scaling)
	end

	local upperY = math.floor(viewportH - mapBottom - mapHeight)
	return {
		x = mapLeft,
		y = upperY,
		width = mapWidth,
		height = mapHeight,
		mapBottom = mapBottom,
		playerIconSize = playerIconSize,
		aiIconSize = aiIconSize,
	}
end

-- Bounding box & square span matching Graph::makeMiniMap (graph.cpp:L511-L542)
function RaceHudMath.computeMinimapBounds(points: { Point2D }): MinimapBounds
	if #points == 0 then
		return { minX = -1, maxX = 1, minZ = -1, maxZ = 1, range = 2 }
	end
	local minX, maxX = math.huge, -math.huge
	local minZ, maxZ = math.huge, -math.huge
	for _, p in points do
		if p.x < minX then
			minX = p.x
		end
		if p.x > maxX then
			maxX = p.x
		end
		if p.z < minZ then
			minZ = p.z
		end
		if p.z > maxZ then
			maxZ = p.z
		end
	end
	local dx = maxX - minX
	local dz = maxZ - minZ
	local range = math.max(dx, dz, 1e-6)
	return {
		minX = minX,
		maxX = maxX,
		minZ = minZ,
		maxZ = maxZ,
		range = range,
	}
end

-- World XZ -> local minimap pixels [0..mapWidth, 0..mapHeight]
-- Matches Track::mapPoint2MiniMap (track.cpp:L837-L850), Graph::mapPoint2MiniMap (graph.cpp:L590-L595),
-- and RaceGUI::drawGlobalMiniMap lower_y - draw_at.y (race_gui.cpp:L584-L588, L695-L698).
function RaceHudMath.projectToMinimap(
	x: number,
	z: number,
	bounds: MinimapBounds,
	mapWidth: number,
	mapHeight: number,
	invertXZ: boolean?
): (number, number)
	local scale = mapWidth / math.max(bounds.range, 1e-6)
	local px: number
	local pz: number
	if invertXZ then
		-- Matches Graph::createMeshSP invert_x_z (-X, -Z flips bounds [-max, -min])
		px = bounds.maxX - x
		pz = bounds.maxZ - z
	else
		px = x - bounds.minX
		pz = z - bounds.minZ
	end
	local drawX = px * scale
	local drawY = pz * scale * (mapHeight / math.max(mapWidth, 1e-6))
	return drawX, mapHeight - drawY
end

-- Top-left player icon column layout (race_gui_base.cpp:L793-L838, L1023, L1054)
function RaceHudMath.computePlayerIconRect(
	viewportW: number,
	viewportH: number,
	numKarts: number,
	bottomMargin: number,
	rankIndex: number,
	isLocal: boolean
): HudRect
	local xBase = RaceHudMath.PLAYER_LIST_X_BASE
	local yBase = RaceHudMath.PLAYER_LIST_Y_BASE
	local ySpace = math.max(RaceHudMath.PLAYER_LIST_MIN_ICON, viewportH - bottomMargin - yBase)
	local karts = math.max(1, numKarts)

	local playerW = math.floor(ySpace / karts) - 2
	local iconWidthMax = math.floor(RaceHudMath.PLAYER_LIST_MAX_ICON_AT_1024 * (viewportW / 1024.0))
	local iconWidthMin = RaceHudMath.PLAYER_LIST_MIN_ICON
	if iconWidthMin > iconWidthMax then
		iconWidthMin, iconWidthMax = iconWidthMax, iconWidthMin
	end
	playerW = math.clamp(playerW, iconWidthMin, iconWidthMax)

	local w = if isLocal then playerW else math.floor(playerW * 5 / 6)
	local pos = math.max(1, rankIndex)
	return {
		x = xBase,
		y = yBase + (pos - 1) * (playerW + 2),
		width = w,
		height = w,
	}
end

-- Speed ratio [0, 1] with STK's 8-segment 3D border snap (race_gui.cpp:L1048-L1123)
function RaceHudMath.snapSpeedRatio(speedMps: number): number
	if speedMps <= 0 then
		return 0.0
	end
	local ratio = math.clamp(speedMps / RaceHudMath.MAX_DISPLAY_SPEED_MPS, 0.0, 1.0)
	for i = 0, 7 do
		local edge = 0.125 * i
		if (ratio - edge < 0.00625 and ratio - edge >= 0.0) or (edge - ratio < 0.0045 and edge - ratio >= 0.0) then
			ratio = math.max(0.0, edge - 0.0045)
			break
		end
	end
	return ratio
end

-- Nitro ratio [0, 1] with STK's 5-segment 3D border snap (race_gui.cpp:L805-L877)
function RaceHudMath.snapNitroRatio(energy: number, maxEnergy: number): number
	if maxEnergy <= 0 or energy <= 0 then
		return 0.0
	end
	local ratio = math.clamp(energy / maxEnergy, 0.0, 1.0)
	for i = 0, 4 do
		local edge = 0.2 * i
		if (ratio - edge < 0.006 and ratio - edge >= 0.0) or (edge - ratio < 0.003 and edge - ratio >= 0.0) then
			ratio = math.max(0.0, edge - 0.003)
			break
		end
	end
	return ratio
end

local function interpolateSegmentAngle(angles: { number }, ratio: number): number
	local segments = #angles - 1
	local clamped = math.clamp(ratio, 0.0, 1.0)
	local scaled = clamped * segments
	local idx = math.min(math.floor(scaled) + 1, segments)
	local localT = scaled - (idx - 1)
	return angles[idx] + (angles[idx + 1] - angles[idx]) * localT
end

-- Clockwise sweep angle in degrees around SPEED_CENTER (127.05 -> 330.66)
function RaceHudMath.computeSpeedSweepAngleDeg(snappedRatio: number): number
	return interpolateSegmentAngle(SPEED_ANGLES_DEG, snappedRatio)
end

-- Counter-clockwise sweep angle in degrees around NITRO_CENTER (117.44 -> -12.56)
function RaceHudMath.computeNitroSweepAngleDeg(snappedRatio: number): number
	return interpolateSegmentAngle(NITRO_ANGLES_DEG, snappedRatio)
end

-- Held powerup icon strip & xN badge layout ported from RaceGUIBase::drawPowerupIcons
-- (src/states_screens/race_gui_base.cpp:L380-L456, user_config.hpp:L1298-L1303).
function RaceHudMath.computePowerupLayout(
	viewportW: number,
	viewportH: number,
	count: number,
	powerupDisplay: number?,
	powerupSize: number?
): PowerupLayout
	local displayMode = powerupDisplay or 0
	if displayMode == 2 or count < 1 or viewportW <= 0 or viewportH <= 0 then
		return {
			iconSize = 0,
			rects = {},
			manyText = nil,
			manyRect = nil,
		}
	end

	local n = math.floor(count)
	local manyPowerups = 0
	if n > RaceHudMath.POWERUP_MAX_STACK then
		manyPowerups = n
		n = 1
	end

	local scale = RaceHudMath.computeScale(viewportW, viewportH)
	local baseSize = powerupSize or RaceHudMath.POWERUP_SIZE_DEFAULT
	local nSize = math.floor(baseSize * scale)
	local itemSpacing = math.floor(scale * baseSize * 0.5)

	local x1: number
	if displayMode == 1 or (viewportW / viewportH) > 2.0 then
		x1 = math.floor(3 * (viewportW / 4)) - math.floor((n * itemSpacing) / 2)
	else
		x1 = math.floor(viewportW / 2) - math.floor((n * itemSpacing) / 2)
	end
	local y1 = math.floor(RaceHudMath.POWERUP_MARGIN_TOP * scale)

	local rects: { HudRect } = table.create(n)
	local x2 = 0
	for i = 0, n - 1 do
		x2 = math.floor((x1 + i * itemSpacing) - (itemSpacing / 2))
		rects[i + 1] = {
			x = x2,
			y = y1,
			width = nSize,
			height = nSize,
		}
	end

	local manyText: string? = nil
	local manyRect: HudRect? = nil
	if manyPowerups > 0 then
		manyText = "x" .. tostring(manyPowerups)
		manyRect = {
			x = x2 + nSize,
			y = y1,
			width = nSize,
			height = nSize,
		}
	end

	return {
		iconSize = nSize,
		rects = rects,
		manyText = manyText,
		manyRect = manyRect,
	}
end

return table.freeze(RaceHudMath)
