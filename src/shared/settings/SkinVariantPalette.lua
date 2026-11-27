--!strict
-- src/shared/settings/SkinVariantPalette.lua
-- SPDX-License-Identifier: GPL-3.0-or-later
-- Ported from data/skins/{classic,cartoon}*/stkskin.xml (STK 1.5).
-- Single source of truth for skin variant palettes and the shared kart/nametag variant color.

local SettingsSchema = require("./SettingsSchema")

export type RgbColor = {
	r: number,
	g: number,
	b: number,
}

export type VariantPaletteSpec = {
	variantColor: RgbColor,
	nametagStroke: RgbColor,
	headerTop: RgbColor,
	headerBottom: RgbColor,
	textNeutral: RgbColor,
	textFocused: RgbColor,
	textBright: RgbColor,
	textEmphasis: RgbColor,
	textCredits: RgbColor,
	boxTint: RgbColor,
	buttonTint: RgbColor,
	buttonFocusTint: RgbColor,
	bottomBarTint: RgbColor,
	backdropTint: RgbColor,
}

local function rgb(r: number, g: number, b: number): RgbColor
	return { r = r, g = g, b = b }
end

local NAMETAG_STROKE: RgbColor = rgb(15, 15, 20)

local VARIANT_ORDER: { SettingsSchema.SkinVariantName } = {
	"Peach",
	"Coal",
	"Desert",
	"Forest",
	"Ocean",
	"Ruby",
}

local NAME_TO_INDEX: { [string]: number } = {}
for idx, name in ipairs(VARIANT_ORDER) do
	NAME_TO_INDEX[name] = idx
end

local PALETTES: { [string]: VariantPaletteSpec } = {
	-- data/skins/classic/stkskin.xml:L240-L280
	Peach = {
		variantColor = rgb(255, 190, 55),
		nametagStroke = NAMETAG_STROKE,
		headerTop = rgb(255, 128, 0),
		headerBottom = rgb(255, 220, 15),
		textNeutral = rgb(0, 0, 0),
		textFocused = rgb(255, 255, 255),
		textBright = rgb(255, 145, 0),
		textEmphasis = rgb(0, 0, 180),
		textCredits = rgb(65, 15, 0),
		boxTint = rgb(255, 255, 255),
		buttonTint = rgb(255, 255, 255),
		buttonFocusTint = rgb(255, 255, 255),
		bottomBarTint = rgb(255, 255, 255),
		backdropTint = rgb(255, 255, 255),
	},
	-- data/skins/classic-coal/stkskin.xml
	Coal = {
		variantColor = rgb(190, 200, 215),
		nametagStroke = NAMETAG_STROKE,
		headerTop = rgb(140, 140, 140),
		headerBottom = rgb(235, 235, 235),
		textNeutral = rgb(230, 230, 230),
		textFocused = rgb(255, 255, 255),
		textBright = rgb(240, 240, 240),
		textEmphasis = rgb(175, 210, 255),
		textCredits = rgb(220, 220, 220),
		boxTint = rgb(80, 84, 92),
		buttonTint = rgb(95, 100, 110),
		buttonFocusTint = rgb(140, 148, 162),
		bottomBarTint = rgb(90, 94, 102),
		backdropTint = rgb(130, 136, 146),
	},
	-- data/skins/classic-desert/stkskin.xml
	Desert = {
		variantColor = rgb(255, 235, 85),
		nametagStroke = NAMETAG_STROKE,
		headerTop = rgb(165, 120, 20),
		headerBottom = rgb(255, 255, 45),
		textNeutral = rgb(25, 18, 0),
		textFocused = rgb(255, 255, 255),
		textBright = rgb(255, 230, 40),
		textEmphasis = rgb(120, 65, 0),
		textCredits = rgb(70, 40, 0),
		boxTint = rgb(255, 238, 195),
		buttonTint = rgb(255, 226, 155),
		buttonFocusTint = rgb(255, 205, 95),
		bottomBarTint = rgb(255, 220, 130),
		backdropTint = rgb(245, 222, 175),
	},
	-- data/skins/classic-forest/stkskin.xml
	Forest = {
		variantColor = rgb(95, 235, 130),
		nametagStroke = NAMETAG_STROKE,
		headerTop = rgb(60, 230, 150),
		headerBottom = rgb(80, 190, 0),
		textNeutral = rgb(0, 25, 10),
		textFocused = rgb(255, 255, 255),
		textBright = rgb(0, 160, 70),
		textEmphasis = rgb(0, 95, 45),
		textCredits = rgb(15, 55, 25),
		boxTint = rgb(205, 245, 215),
		buttonTint = rgb(185, 240, 200),
		buttonFocusTint = rgb(115, 215, 145),
		bottomBarTint = rgb(175, 235, 185),
		backdropTint = rgb(185, 235, 195),
	},
	-- data/skins/classic-ocean/stkskin.xml
	Ocean = {
		variantColor = rgb(85, 195, 255),
		nametagStroke = NAMETAG_STROKE,
		headerTop = rgb(100, 200, 220),
		headerBottom = rgb(80, 120, 245),
		textNeutral = rgb(0, 10, 35),
		textFocused = rgb(255, 255, 255),
		textBright = rgb(28, 176, 255),
		textEmphasis = rgb(0, 45, 175),
		textCredits = rgb(10, 30, 80),
		boxTint = rgb(205, 232, 255),
		buttonTint = rgb(185, 220, 255),
		buttonFocusTint = rgb(110, 180, 255),
		bottomBarTint = rgb(165, 215, 255),
		backdropTint = rgb(175, 215, 255),
	},
	-- data/skins/classic-ruby/stkskin.xml
	Ruby = {
		variantColor = rgb(255, 95, 170),
		nametagStroke = NAMETAG_STROKE,
		headerTop = rgb(255, 30, 200),
		headerBottom = rgb(255, 100, 100),
		textNeutral = rgb(25, 0, 12),
		textFocused = rgb(255, 255, 255),
		textBright = rgb(255, 30, 150),
		textEmphasis = rgb(145, 0, 80),
		textCredits = rgb(65, 0, 25),
		boxTint = rgb(255, 215, 232),
		buttonTint = rgb(255, 195, 220),
		buttonFocusTint = rgb(255, 120, 175),
		bottomBarTint = rgb(255, 185, 210),
		backdropTint = rgb(255, 190, 215),
	},
}

local SkinVariantPalette = {}

SkinVariantPalette.VARIANT_ORDER = VARIANT_ORDER
SkinVariantPalette.NAMETAG_STROKE = NAMETAG_STROKE

function SkinVariantPalette.nameToIndex(name: string?): number
	if type(name) == "string" then
		local idx = NAME_TO_INDEX[name]
		if idx ~= nil then
			return idx
		end
	end
	return 1
end

function SkinVariantPalette.indexToName(idx: number?): SettingsSchema.SkinVariantName
	if type(idx) == "number" then
		local clamped = math.clamp(math.floor(idx), 1, #VARIANT_ORDER)
		return VARIANT_ORDER[clamped]
	end
	return VARIANT_ORDER[1]
end

function SkinVariantPalette.getPalette(variantOrIdx: (string | number)?): VariantPaletteSpec
	local name: string
	if type(variantOrIdx) == "number" then
		name = SkinVariantPalette.indexToName(variantOrIdx)
	elseif type(variantOrIdx) == "string" and PALETTES[variantOrIdx] ~= nil then
		name = variantOrIdx
	else
		name = "Peach"
	end
	return PALETTES[name]
end

function SkinVariantPalette.getVariantRgb(variantOrIdx: (string | number)?): RgbColor
	return SkinVariantPalette.getPalette(variantOrIdx).variantColor
end

return table.freeze(SkinVariantPalette)
