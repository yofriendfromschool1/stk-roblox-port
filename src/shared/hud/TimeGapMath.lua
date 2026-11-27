--!strict
-- src/shared/hud/TimeGapMath.lua
-- SPDX-License-Identifier: GPL-3.0-or-later
-- ported from src/modes/linear_world.cpp:L620-L725 (STK 1.5) with documented divergences:
-- 1) Displays time gaps for 30.0 s after the leader crosses each lap line (user request;
--    upstream uses 8 s at linear_world.cpp:L668).
-- 2) Lapped karts (>= 1 full lap behind leader) display "+N Lap" / "+N Laps".

local FixedStep = require("../sim/FixedStep")
local RaceHudMath = require("./RaceHudMath")
local Standings = require("../race/Standings")

export type GapEntry = {
	text: string,
	r: number,
	g: number,
	b: number,
	visible: boolean,
}

export type GapJitterCache = {
	lastLeaderLap: number,
	minTicksByKartId: { [string]: number },
}

local GAP_WINDOW_TICKS = FixedStep.timeToTicks(30.0)
local START_GO_TICK = 240
local QUANTIZE_TICKS = 6 -- 50 ms at 120 Hz to prevent per-frame sub-frame flicker

local TimeGapMath = {}

function TimeGapMath.createCache(): GapJitterCache
	return {
		lastLeaderLap = -1,
		minTicksByKartId = {},
	}
end

local function computeLapProgressColor(lap: number, totalLaps: number, finished: boolean): (number, number, number)
	if finished or (totalLaps > 0 and lap >= totalLaps) then
		return 255, 45, 45
	end
	if lap >= 0 and totalLaps > 1 then
		local frac = math.clamp(lap / math.max(1, totalLaps - 1), 0, 1)
		local gb = math.floor(255 * (1.0 - frac))
		return 255, gb, gb
	end
	return 255, 255, 255
end

function TimeGapMath.computeGaps(
	ranked: { Standings.RankedEntry },
	currentRaceTick: number,
	totalLaps: number,
	cache: GapJitterCache?
): { [string]: GapEntry }
	local out: { [string]: GapEntry } = {}
	if #ranked == 0 then
		return out
	end

	-- 1) Find leader lap & earliest lap-crossing tick among leader-lap karts (linear_world.cpp:L623-L654)
	local lapsOfLeader = -1
	local ticksOfLeader = math.huge
	for _, r in ipairs(ranked) do
		local kLap = r.entry.lap
		local kTick = r.entry.lapStartTick or START_GO_TICK
		if kLap > lapsOfLeader then
			lapsOfLeader = kLap
			ticksOfLeader = kTick
		elseif kLap == lapsOfLeader then
			ticksOfLeader = math.min(ticksOfLeader, kTick)
		end
	end

	if cache ~= nil and lapsOfLeader ~= cache.lastLeaderLap then
		cache.lastLeaderLap = lapsOfLeader
		table.clear(cache.minTicksByKartId)
	end

	local inGapWindow = lapsOfLeader > 0 and (currentRaceTick - ticksOfLeader) <= GAP_WINDOW_TICKS

	for _, r in ipairs(ranked) do
		local kLap = r.entry.lap
		local kTick = r.entry.lapStartTick or START_GO_TICK
		local cr, cg, cb = computeLapProgressColor(kLap, totalLaps, r.entry.finished == true)

		if not inGapWindow then
			out[r.id] = { text = "", r = cr, g = cg, b = cb, visible = false }
		else
			local lapDiff = lapsOfLeader - kLap
			if lapDiff >= 2 then
				local behindLaps = lapDiff - 1
				local suffix = if behindLaps == 1 then "Lap" else "Laps"
				out[r.id] = {
					text = string.format("+%d %s", behindLaps, suffix),
					r = cr,
					g = cg,
					b = cb,
					visible = true,
				}
			elseif r.rank == 1 then
				local leaderTime = RaceHudMath.formatRaceTime(FixedStep.ticksToTime(math.max(0, kTick - START_GO_TICK)))
				out[r.id] = {
					text = " " .. leaderTime,
					r = cr,
					g = cg,
					b = cb,
					visible = true,
				}
			else
				local rawTicksBehind = if kLap == lapsOfLeader
					then math.max(0, kTick - ticksOfLeader)
					else math.max(0, currentRaceTick - ticksOfLeader)
				local quantized = math.floor(rawTicksBehind / QUANTIZE_TICKS) * QUANTIZE_TICKS
				if kLap ~= lapsOfLeader and cache ~= nil then
					local prev = cache.minTicksByKartId[r.id]
					if prev ~= nil and quantized < prev then
						quantized = prev
					end
					cache.minTicksByKartId[r.id] = quantized
				end
				local gapStr = RaceHudMath.formatRaceTime(FixedStep.ticksToTime(quantized))
				out[r.id] = {
					text = "+" .. gapStr,
					r = cr,
					g = cg,
					b = cb,
					visible = true,
				}
			end
		end
	end

	return out
end

return TimeGapMath
