--!strict
-- src/shared/items/PowerupManager.lua
-- SPDX-License-Identifier: GPL-3.0-or-later
-- Ported from src/items/powerup_manager.cpp:L264-L627 (STK 1.5, commit 1fb491f5).
-- Server-authoritative powerup weight interpolation and weighted random roll.

local ItemTuning = require("../ItemTuning")

local PowerupManager = {}
PowerupManager.__index = PowerupManager

export type PowerupManager = {
	modeName: string,
	numKarts: number,
	isFollowLeader: boolean,
	haveBonusBoxes: boolean,
	isBattle: boolean,
	sections: { ItemTuning.PowerupEntry },
	summedWeightsForRank: { { number } },
	getRandomPowerup: (self: PowerupManager, rank: number, randomSeed: number, elapsedSec: number?) -> (number, number),
	getRankWeights: (self: PowerupManager, rank: number) -> { single: { number }, multi: { number }, total: number },
}

local function roundHalfUp(x: number): number
	return math.floor(x + 0.5)
end

-- Ported from PowerupManager::WeightsData::interpolate (powerup_manager.cpp:L271-L295).
local function interpolateTables(
	prevTable: ItemTuning.WeightTableForKarts,
	nextTable: ItemTuning.WeightTableForKarts,
	numKarts: number
): { ItemTuning.PowerupEntry }
	local f = (numKarts - prevTable.numKarts) / (nextTable.numKarts - prevTable.numKarts)
	local out: { ItemTuning.PowerupEntry } = {}
	local nLast = ItemTuning.POWERUP_LAST
	for cl = 1, #prevTable.sections do
		local wPrev = prevTable.sections[cl]
		local wNext = nextTable.sections[cl]
		local single = table.create(nLast, 0)
		local multi = table.create(nLast, 0)
		for i = 1, nLast do
			single[i] = roundHalfUp(wPrev.single[i] * (1 - f) + wNext.single[i] * f)
			multi[i] = roundHalfUp(wPrev.multi[i] * (1 - f) + wNext.multi[i] * f)
		end
		table.insert(out, { single = single, multi = multi })
	end
	return out
end

-- Ported from PowerupManager::WeightsData::convertRankToSection (powerup_manager.cpp:L312-L375),
-- converted to 1-based Lua indices (rank in [1..numKarts]).
local function convertRankToSection(
	rank: number,
	numKarts: number,
	numSections: number,
	isFollowLeader: boolean
): (number, number, number)
	if numSections == 1 or rank == 1 then
		return 1, 1, 1.0
	end
	if rank >= numKarts then
		return numSections, numSections, 1.0
	end
	if isFollowLeader and rank == 2 then
		return 2, 2, 1.0
	end

	local firstSectionIdx = if isFollowLeader then 2 else 1
	local spanCount = numSections - firstSectionIdx
	local kartsPerFraction = (numKarts - firstSectionIdx) / spanCount

	local section = 0
	while (rank - firstSectionIdx) > (section + 1) * kartsPerFraction do
		section += 1
	end

	-- C++: *prev = first_section_index + section - 1 (0-based) -> +1 in Lua 1-based
	local prevSec = firstSectionIdx + section
	local nextSec = prevSec + 1
	local weight = (rank - firstSectionIdx - section * kartsPerFraction) / kartsPerFraction
	return prevSec, nextSec, weight
end

-- Ported from PowerupManager::computeWeightsForRace + WeightsData::precomputeWeights
-- (src/items/powerup_manager.cpp:L384-L403, L523-L592).
function PowerupManager.new(
	modeName: string?,
	numKarts: number?,
	allowedPowerups: { [number]: boolean }?
): PowerupManager
	local resolvedMode = modeName or "NORMAL_RACE"
	local modeInfo = (ItemTuning.modes :: any)[resolvedMode] or ItemTuning.modes.NORMAL_RACE
	local karts = math.max(1, math.floor(numKarts or 1))
	local weightList = (ItemTuning.WEIGHT_LISTS :: any)[modeInfo.weightClass]

	local prevIdx = 1
	local nextIdx = 1
	for i = 2, #weightList do
		local n = weightList[i].numKarts
		if
			(n < weightList[prevIdx].numKarts and weightList[prevIdx].numKarts > karts)
			or (n > weightList[prevIdx].numKarts and n <= karts)
		then
			prevIdx = i
		end
		if
			(n > weightList[nextIdx].numKarts and weightList[nextIdx].numKarts < karts)
			or (n < weightList[nextIdx].numKarts and n >= karts)
		then
			nextIdx = i
		end
	end

	local sections: { ItemTuning.PowerupEntry }
	if prevIdx == nextIdx then
		sections = {}
		for _, sec in weightList[prevIdx].sections do
			table.insert(sections, {
				single = table.clone(sec.single),
				multi = table.clone(sec.multi),
			})
		end
	else
		sections = interpolateTables(weightList[prevIdx], weightList[nextIdx], karts)
	end

	if allowedPowerups ~= nil then
		for _, sec in sections do
			for j = 1, ItemTuning.POWERUP_LAST do
				if allowedPowerups[j] ~= true then
					sec.single[j] = 0
					sec.multi[j] = 0
				end
			end
		end
	end

	local summedWeightsForRank: { { number } } = table.create(karts)
	local nLast = ItemTuning.POWERUP_LAST
	for rank = 1, karts do
		local prevSec, nextSec, weight = convertRankToSection(rank, karts, #sections, modeInfo.isFollowLeader)
		local summed = table.create(2 * nLast, 0)
		local sum = 0
		for j = 1, nLast do
			local av = (1 - weight) * sections[prevSec].single[j] + weight * sections[nextSec].single[j]
			sum += roundHalfUp(av)
			summed[j] = sum
		end
		for j = 1, nLast do
			local av = (1 - weight) * sections[prevSec].multi[j] + weight * sections[nextSec].multi[j]
			sum += roundHalfUp(av)
			summed[nLast + j] = sum
		end
		summedWeightsForRank[rank] = summed
	end

	local self = {
		modeName = resolvedMode,
		numKarts = karts,
		isFollowLeader = modeInfo.isFollowLeader,
		haveBonusBoxes = modeInfo.haveBonusBoxes,
		isBattle = modeInfo.isBattle,
		sections = sections,
		summedWeightsForRank = summedWeightsForRank,
	}
	return setmetatable(self, PowerupManager) :: any
end

-- Returns interpolated single/multi weight arrays and total weight for 1-based rank.
function PowerupManager:getRankWeights(rank: number): { single: { number }, multi: { number }, total: number }
	local allSummed: { { number } } = (self :: any).summedWeightsForRank
	local clampedRank = math.clamp(math.floor(rank), 1, #allSummed)
	local summed: { number } = allSummed[clampedRank]
	local nLast = ItemTuning.POWERUP_LAST
	local single = table.create(nLast, 0)
	local multi = table.create(nLast, 0)
	local prevSum = 0
	for i = 1, nLast do
		single[i] = summed[i] - prevSum
		prevSum = summed[i]
	end
	for i = 1, nLast do
		multi[i] = summed[nLast + i] - prevSum
		prevSum = summed[nLast + i]
	end
	return {
		single = single,
		multi = multi,
		total = summed[#summed],
	}
end

-- Ported from WeightsData::getRandomItem + PowerupManager::getRandomPowerup
-- (src/items/powerup_manager.cpp:L415-L448, L605-L627).
-- Returns (powerupId, count) where count is 1 (single) or 3 (multi).
function PowerupManager:getRandomPowerup(rank: number, randomSeed: number, elapsedSec: number?): (number, number)
	local allSummed: { { number } } = (self :: any).summedWeightsForRank
	local clampedRank = math.clamp(math.floor(rank), 1, #allSummed)
	local summed: { number } = allSummed[clampedRank]
	local total = summed[#summed]
	if total <= 0 then
		return ItemTuning.POWERUP_NONE, 0
	end

	-- Put random number in [1 .. total] matching C++:
	-- random_number = (random_number % summed_weights.back()) + 1
	local rolled = (math.floor(math.abs(randomSeed)) % total) + 1
	local idx = 1
	while rolled > summed[idx] do
		idx += 1
	end

	local powerupId = idx
	local count = 1
	local nTypes = ItemTuning.POWERUP_LAST - ItemTuning.POWERUP_FIRST + 1
	if powerupId > ItemTuning.POWERUP_LAST then
		powerupId -= nTypes
		count = 3
	end

	-- Prevents early explosive items within first 15.0 s (powerup_manager.cpp:L618-L625)
	if elapsedSec ~= nil and elapsedSec < ItemTuning.timing.NO_EXPLOSIVE_TIMEOUT_SEC then
		if powerupId == ItemTuning.POWERUP_CAKE or powerupId == ItemTuning.POWERUP_RUBBERBALL then
			powerupId = ItemTuning.POWERUP_BOWLING
		end
	end

	return powerupId, count
end

return PowerupManager
