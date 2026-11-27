--!strict
-- src/shared/menu/KartSelectMath.lua
-- SPDX-License-Identifier: GPL-3.0-or-later
-- Pure-Luau kart class filtering, search filtering, and random kart selection
-- ported from src/states_screens/kart_selection.cpp (STK 1.5).

export type KartClassFilter = "all" | "light" | "medium" | "heavy"

export type FilterableKart = {
	id: string,
	name: string,
	kartType: string,
	kartClass: string?,
	iconId: string,
	playable: boolean,
}

local CLASS_FILTERS: { KartClassFilter } = { "all", "light", "medium", "heavy" }

local CLASS_LABELS: { [KartClassFilter]: string } = {
	all = "All",
	light = "Light",
	medium = "Medium",
	heavy = "Heavy",
}

local KartSelectMath = {}
KartSelectMath.CLASS_FILTERS = CLASS_FILTERS
KartSelectMath.CLASS_LABELS = CLASS_LABELS

function KartSelectMath.getClassForEntry(entry: FilterableKart): string
	if type(entry.kartClass) == "string" and entry.kartClass ~= "" then
		return string.lower(entry.kartClass)
	end
	local kt = string.lower(entry.kartType or "medium")
	if kt == "light" or kt == "medium" or kt == "heavy" then
		return kt
	end
	return "medium"
end

function KartSelectMath.filterKarts<T>(karts: { T }, classFilter: KartClassFilter, searchQuery: string?): { T }
	local trimmed = if type(searchQuery) == "string" then string.gsub(searchQuery, "^%s*(.-)%s*$", "%1") else ""
	local q = string.lower(trimmed)
	local out: { T } = {}
	for _, entry in ipairs(karts) do
		local k = entry :: any
		if k.playable then
			local cls = KartSelectMath.getClassForEntry(k)
			local classOk = (classFilter == "all") or (cls == classFilter)
			local searchOk = (q == "") or (string.find(string.lower(k.name or k.id), q, 1, true) ~= nil)
			if classOk and searchOk then
				table.insert(out, entry)
			end
		end
	end
	return out
end

function KartSelectMath.stepClassFilter(current: KartClassFilter, delta: number): KartClassFilter
	local idx = 1
	for i, f in ipairs(CLASS_FILTERS) do
		if f == current then
			idx = i
			break
		end
	end
	local n = #CLASS_FILTERS
	local nextIdx = ((idx - 1 + delta) % n) + 1
	return CLASS_FILTERS[nextIdx]
end

function KartSelectMath.pickRandomKartId<T>(filteredKarts: { T }, seed: number): string?
	if #filteredKarts == 0 then
		return nil
	end
	local idx = (math.floor(math.abs(seed)) % #filteredKarts) + 1
	return (filteredKarts[idx] :: any).id
end

return table.freeze(KartSelectMath)
