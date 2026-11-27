--!strict
-- src/shared/menu/SkinIconResolver.lua
-- SPDX-License-Identifier: GPL-3.0-or-later
-- ported from src/guiengine/skin.cpp:L3129-L3163 (Skin::getThemedIcon, STK 1.5)
-- Routes powerup, menu, HUD highlight, and kart portrait icons through the active skin ("Classic" | "Cartoon").

local CatalogData = require("./CatalogData")
local ItemTuning = require("../ItemTuning")
local MenuIcons = require("./MenuIcons")
local SettingsSchema = require("../settings/SettingsSchema")

export type MissingCartoonReport = {
	kartPortraits: { string },
	hudGauges: { string },
}

local CLASSIC_POWERUP_ICONS: { [number]: string } = {
	[ItemTuning.POWERUP_BUBBLEGUM] = "rbxassetid://101181393814939",
	[ItemTuning.POWERUP_CAKE] = "rbxassetid://79582540802688",
	[ItemTuning.POWERUP_BOWLING] = "rbxassetid://130692326246436",
	[ItemTuning.POWERUP_ZIPPER] = "rbxassetid://105041309293311",
	[ItemTuning.POWERUP_PLUNGER] = "rbxassetid://101469144956890",
	[ItemTuning.POWERUP_SWITCH] = "rbxassetid://106092822459296",
	[ItemTuning.POWERUP_SWATTER] = "rbxassetid://126762223468459",
	[ItemTuning.POWERUP_RUBBERBALL] = "rbxassetid://73902710731702",
	[ItemTuning.POWERUP_PARACHUTE] = "rbxassetid://84448883940909",
	[ItemTuning.POWERUP_ANVIL] = "rbxassetid://85031117296474",
}

-- Audited CC-BY-SA 4.0 Cartoon powerup icons (data/skins/cartoon/data/gui/icons/, data/skins/cartoon/licenses.txt:L34-L37)
local CARTOON_POWERUP_ICONS: { [number]: string } = {
	[ItemTuning.POWERUP_BUBBLEGUM] = "rbxassetid://121600662169081",
	[ItemTuning.POWERUP_CAKE] = "rbxassetid://110662253813446",
	[ItemTuning.POWERUP_BOWLING] = "rbxassetid://119324307084867",
	[ItemTuning.POWERUP_ZIPPER] = "rbxassetid://86637055373560",
	[ItemTuning.POWERUP_PLUNGER] = "rbxassetid://77613246298554",
	[ItemTuning.POWERUP_SWITCH] = "rbxassetid://116793754892643",
	[ItemTuning.POWERUP_SWATTER] = "rbxassetid://76939093867050",
	[ItemTuning.POWERUP_RUBBERBALL] = "rbxassetid://132549530959588",
	[ItemTuning.POWERUP_PARACHUTE] = "rbxassetid://99923863653466",
	[ItemTuning.POWERUP_ANVIL] = "rbxassetid://98377453830223",
}

-- Audited CC-BY-SA 4.0 Cartoon menu icons (data/skins/cartoon/data/gui/icons/)
local CARTOON_MENU_ICONS: { [string]: string } = {
	MenuRace = "rbxassetid://111364134416550",
	MenuRaceFocus = "rbxassetid://122617309791620",
	MenuMulti = "rbxassetid://76815172805895",
	MenuMultiFocus = "rbxassetid://85615691449700",
	MenuOnline = "rbxassetid://136381494034870",
	MenuOnlineFocus = "rbxassetid://97757548319377",
	MainOptions = "rbxassetid://82149468088722",
	MainAbout = "rbxassetid://134458060342526",
	OptionsVideo = "rbxassetid://110772880775759",
	OptionsAudio = "rbxassetid://113816242397725",
	OptionsUi = "rbxassetid://125146732135185",
	OptionsInput = "rbxassetid://117571835967912",
	Back = "rbxassetid://89971227532159",
	DifficultyEasy = "rbxassetid://108749385276865",
	DifficultyMedium = "rbxassetid://117871506943299",
	DifficultyHard = "rbxassetid://79726787100026",
	DifficultyBest = "rbxassetid://84138586238863",
	ModeNormal = "rbxassetid://84158196020544",
	ModeTimeTrial = "rbxassetid://105843026187192",
	GreenCheck = "rbxassetid://82467681825570",
	StatMass = "rbxassetid://114568132043160",
	StatSpeed = "rbxassetid://86223127635551",
	StatAccel = "rbxassetid://108762846649734",
	StatNitro = "rbxassetid://114833176408350",
	RandomKart = "rbxassetid://127924971247771",
}

local CLASSIC_MENU_ICONS: { [string]: string } = {
	MenuRace = MenuIcons.MenuRace,
	MenuRaceFocus = MenuIcons.MenuRaceFocus,
	MenuMulti = MenuIcons.MenuMulti,
	MenuMultiFocus = MenuIcons.MenuMultiFocus,
	MenuOnline = MenuIcons.MenuOnline,
	MenuOnlineFocus = MenuIcons.MenuOnlineFocus,
	MainOptions = MenuIcons.MainOptions,
	MainAbout = MenuIcons.MainAbout,
	OptionsVideo = MenuIcons.OptionsVideo,
	OptionsAudio = MenuIcons.OptionsAudio,
	OptionsUi = MenuIcons.OptionsUi,
	OptionsInput = MenuIcons.OptionsInput,
	Back = MenuIcons.Back,
	DifficultyEasy = MenuIcons.DifficultyEasy,
	DifficultyMedium = MenuIcons.DifficultyMedium,
	DifficultyHard = MenuIcons.DifficultyHard,
	DifficultyBest = MenuIcons.DifficultyBest,
	ModeNormal = MenuIcons.ModeNormal,
	ModeTimeTrial = MenuIcons.ModeTimeTrial,
	GreenCheck = MenuIcons.GreenCheck,
	StatMass = MenuIcons.StatMass,
	StatSpeed = MenuIcons.StatSpeed,
	StatAccel = MenuIcons.StatAccel,
	StatNitro = MenuIcons.StatNitro,
	RandomKart = MenuIcons.RandomKart,
}

local HUD_HIGHLIGHT_CLASSIC = "rbxassetid://128866264800446" -- karts/tux/icons-frame.png
local HUD_HIGHLIGHT_CARTOON = "rbxassetid://73586125092974" -- data/skins/cartoon/bubble.png

local KART_ICON_BY_ID: { [string]: string } = {}
local MISSING_CARTOON_KART_PORTRAITS: { string } = {}
for _, kEntry in ipairs(CatalogData.karts) do
	KART_ICON_BY_ID[kEntry.id] = kEntry.iconId
	table.insert(MISSING_CARTOON_KART_PORTRAITS, kEntry.id)
end

local MISSING_CARTOON_GAUGES: { string } = {
	"speedback.png",
	"speedfore.png",
	"gauge_empty.png",
	"gauge_full.png",
	"gauge_full_bright.png",
}

local SkinIconResolver = {}

function SkinIconResolver.getPowerupIcon(powerupId: number, skin: SettingsSchema.SkinName?): string
	if skin == "Cartoon" then
		return CARTOON_POWERUP_ICONS[powerupId] or ""
	end
	return CLASSIC_POWERUP_ICONS[powerupId] or ""
end

function SkinIconResolver.getMenuIcon(key: string, skin: SettingsSchema.SkinName?): string
	if skin == "Cartoon" then
		return CARTOON_MENU_ICONS[key] or CLASSIC_MENU_ICONS[key] or ""
	end
	return CLASSIC_MENU_ICONS[key] or ""
end

-- Per STK 1.5 kart_properties.cpp:L321, L342 + data/skins/cartoon/data/:
-- STK 1.5 Cartoon skin ships no data/karts/ portrait overrides, so getThemedIcon falls back to canonical kart icons.
function SkinIconResolver.getKartIcon(kartId: string?, _skin: SettingsSchema.SkinName?): string
	if kartId ~= nil and KART_ICON_BY_ID[kartId] ~= nil then
		return KART_ICON_BY_ID[kartId]
	end
	return KART_ICON_BY_ID["tux"] or MenuIcons.TuxIcon
end

function SkinIconResolver.getHudHighlightAsset(skin: SettingsSchema.SkinName?): string
	if skin == "Cartoon" then
		return HUD_HIGHLIGHT_CARTOON
	end
	return HUD_HIGHLIGHT_CLASSIC
end

function SkinIconResolver.getMissingCartoonReport(): MissingCartoonReport
	return {
		kartPortraits = table.clone(MISSING_CARTOON_KART_PORTRAITS),
		hudGauges = table.clone(MISSING_CARTOON_GAUGES),
	}
end

return table.freeze(SkinIconResolver)
