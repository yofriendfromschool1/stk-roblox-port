--!strict
-- src/shared/race/Standings.lua
-- SPDX-License-Identifier: GPL-3.0-or-later
-- ported from src/modes/linear_world.cpp:L875-L930, src/modes/world_with_rank.cpp:L89-L92 (STK 1.5)
-- Pure-Luau standings sorter: lap -> checkpoint -> distance (finished karts sorted ahead by finishTime).

export type StandingsEntry = {
	id: string,
	kartId: string?,
	displayName: string?,
	lap: number,
	checkpoint: number,
	distance: number,
	initialPosition: number?,
	finished: boolean?,
	finishTime: number?,
	bestLapTicks: number?,
}

export type RankedEntry = {
	id: string,
	rank: number,
	total: number,
	entry: StandingsEntry,
}

local Standings = {}

local function comesBefore(a: StandingsEntry, b: StandingsEntry): boolean
	local aFin = a.finished == true
	local bFin = b.finished == true
	if aFin ~= bFin then
		return aFin
	end
	if aFin and bFin then
		local ta = a.finishTime or math.huge
		local tb = b.finishTime or math.huge
		if ta ~= tb then
			return ta < tb
		end
	end

	-- Active race progress: higher lap -> higher checkpoint -> greater distance along segment
	if a.lap ~= b.lap then
		return a.lap > b.lap
	end
	if a.checkpoint ~= b.checkpoint then
		return a.checkpoint > b.checkpoint
	end
	if a.distance ~= b.distance then
		return a.distance > b.distance
	end

	-- Deterministic tie-break matching linear_world.cpp:L925 (initial grid position) then id
	local ia = a.initialPosition or math.huge
	local ib = b.initialPosition or math.huge
	if ia ~= ib then
		return ia < ib
	end
	return a.id < b.id
end

function Standings.compute(entries: { StandingsEntry }): { RankedEntry }
	local copy: { StandingsEntry } = table.clone(entries)
	table.sort(copy, comesBefore)

	local total = #copy
	local ranked: { RankedEntry } = table.create(total)
	for i, entry in copy do
		ranked[i] = {
			id = entry.id,
			rank = i,
			total = total,
			entry = entry,
		}
	end
	return ranked
end

function Standings.getRankForId(entries: { StandingsEntry }, id: string): (number, number)
	local ranked = Standings.compute(entries)
	local total = #ranked
	for _, r in ranked do
		if r.id == id then
			return r.rank, total
		end
	end
	if total == 0 then
		return 1, 1
	end
	return total, total
end

return table.freeze(Standings)
