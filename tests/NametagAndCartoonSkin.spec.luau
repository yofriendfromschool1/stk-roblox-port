--!strict
-- tests/NametagAndCartoonSkin.spec.luau
-- SPDX-License-Identifier: GPL-3.0-or-later

local GreyboxProtocol = require("../src/shared/net/GreyboxProtocol")
local ItemTuning = require("../src/shared/ItemTuning")
local KartSolver = require("../src/shared/sim/KartSolver")
local KartTuning = require("../src/shared/KartTuning")
local SkinIconResolver = require("../src/shared/menu/SkinIconResolver")
local SkinVariantPalette = require("../src/shared/settings/SkinVariantPalette")

local tests: { { name: string, fn: () -> () } } = {}

table.insert(tests, {
	name = "SkinVariantPalette round-trips all 6 variants and provides distinct single-source RGB colors",
	fn = function()
		local seenRgb: { [string]: boolean } = {}
		for idx, name in ipairs(SkinVariantPalette.VARIANT_ORDER) do
			assert(SkinVariantPalette.nameToIndex(name) == idx, "nameToIndex mismatch for " .. name)
			assert(SkinVariantPalette.indexToName(idx) == name, "indexToName mismatch for " .. tostring(idx))
			local byName = SkinVariantPalette.getVariantRgb(name)
			local byIdx = SkinVariantPalette.getVariantRgb(idx)
			assert(
				byName.r == byIdx.r and byName.g == byIdx.g and byName.b == byIdx.b,
				"RGB mismatch between name and idx for " .. name
			)
			local key = string.format("%d,%d,%d", byName.r, byName.g, byName.b)
			assert(not seenRgb[key], "Duplicate variantColor RGB: " .. key)
			seenRgb[key] = true
		end
	end,
})

table.insert(tests, {
	name = "GreyboxProtocol round-trips skinVariantIdx (1..6) on RemoteKartState",
	fn = function()
		local prof = KartTuning.buildProfileForKart("tux", "best")
		local st = KartSolver.createState(prof, { x = 0, y = 1, z = 0 }, 0)
		local ns = KartSolver.captureNetState(st)
		local remotes: { GreyboxProtocol.RemoteKartState } = {}
		for idx = 1, 6 do
			table.insert(remotes, {
				id = "bot_" .. tostring(idx),
				kartId = "tux",
				pos = { idx * 2, 1, 0 },
				rot = { 1, 0, 0, 0 },
				linVel = { 0, 0, 0 },
				speed = 10,
				steer = 0,
				attachmentType = 0,
				plungerFaceTicks = 0,
				isSquashed = false,
				rank = idx,
				skinVariantIdx = idx,
			})
		end
		local buf, notice = GreyboxProtocol.packSnapshot(100, 10, 0, ns, "", remotes, 123.45)
		local unpacked = GreyboxProtocol.unpackSnapshot(buf, notice)
		assert(unpacked ~= nil, "unpackSnapshot returned nil")
		assert(unpacked.remoteKarts ~= nil and #unpacked.remoteKarts == 6, "expected 6 remote karts")
		for idx = 1, 6 do
			assert(
				unpacked.remoteKarts[idx].skinVariantIdx == idx,
				string.format(
					"expected skinVariantIdx=%d, got %s",
					idx,
					tostring(unpacked.remoteKarts[idx].skinVariantIdx)
				)
			)
		end
	end,
})

table.insert(tests, {
	name = "SkinIconResolver returns distinct Classic vs Cartoon assets for all 10 powerups, 25 menu icons, and HUD highlight",
	fn = function()
		local powerups = {
			ItemTuning.POWERUP_BUBBLEGUM,
			ItemTuning.POWERUP_CAKE,
			ItemTuning.POWERUP_BOWLING,
			ItemTuning.POWERUP_ZIPPER,
			ItemTuning.POWERUP_PLUNGER,
			ItemTuning.POWERUP_SWITCH,
			ItemTuning.POWERUP_SWATTER,
			ItemTuning.POWERUP_RUBBERBALL,
			ItemTuning.POWERUP_PARACHUTE,
			ItemTuning.POWERUP_ANVIL,
		}
		for _, pId in ipairs(powerups) do
			local cAsset = SkinIconResolver.getPowerupIcon(pId, "Classic")
			local kAsset = SkinIconResolver.getPowerupIcon(pId, "Cartoon")
			assert(string.sub(cAsset, 1, 13) == "rbxassetid://", "Missing Classic powerup icon for " .. tostring(pId))
			assert(string.sub(kAsset, 1, 13) == "rbxassetid://", "Missing Cartoon powerup icon for " .. tostring(pId))
			assert(cAsset ~= kAsset, "Classic and Cartoon powerup icon must differ for " .. tostring(pId))
		end

		local menuKeys = {
			"MenuRace",
			"MenuRaceFocus",
			"MenuMulti",
			"MenuMultiFocus",
			"MenuOnline",
			"MenuOnlineFocus",
			"MainOptions",
			"MainAbout",
			"OptionsVideo",
			"OptionsAudio",
			"OptionsUi",
			"OptionsInput",
			"Back",
			"DifficultyEasy",
			"DifficultyMedium",
			"DifficultyHard",
			"DifficultyBest",
			"ModeNormal",
			"ModeTimeTrial",
			"GreenCheck",
			"StatMass",
			"StatSpeed",
			"StatAccel",
			"StatNitro",
			"RandomKart",
		}
		for _, key in ipairs(menuKeys) do
			local cAsset = SkinIconResolver.getMenuIcon(key, "Classic")
			local kAsset = SkinIconResolver.getMenuIcon(key, "Cartoon")
			assert(string.sub(cAsset, 1, 13) == "rbxassetid://", "Missing Classic menu icon for " .. key)
			assert(string.sub(kAsset, 1, 13) == "rbxassetid://", "Missing Cartoon menu icon for " .. key)
			assert(cAsset ~= kAsset, "Classic and Cartoon menu icon must differ for " .. key)
		end

		local hlClassic = SkinIconResolver.getHudHighlightAsset("Classic")
		local hlCartoon = SkinIconResolver.getHudHighlightAsset("Cartoon")
		assert(hlClassic ~= hlCartoon, "HUD highlight asset must differ between Classic and Cartoon")

		local missing = SkinIconResolver.getMissingCartoonReport()
		assert(#missing.kartPortraits == 18, "Expected 18 documented missing cartoon kart portraits")
		assert(#missing.hudGauges == 5, "Expected 5 documented missing cartoon HUD gauge sprites")
	end,
})

return tests
