--!strict
-- SPDX-License-Identifier: GPL-3.0-or-later
-- Ported from data/gui/screens/options/options_{video,audio,ui,input}.stkgui & src/config/user_config.hpp (STK 1.5).

export type GraphicsPreset = "Low" | "Medium" | "High"
export type TrackDetailLevel = "Low" | "Medium" | "High"
export type CameraPreset = "Normal" | "Close" | "Far"
export type SkinName = "Classic" | "Cartoon"
export type SkinVariantName = "Peach" | "Coal" | "Desert" | "Forest" | "Ocean" | "Ruby"

export type KeyboardBindings = {
	accelerate: string,
	brake: string,
	steerLeft: string,
	steerRight: string,
	drift: string,
	fire: string,
	nitro: string,
	lookBack: string,
	rescue: string,
}

export type GamepadBindings = {
	accelerate: string,
	brake: string,
	drift: string,
	fire: string,
	nitro: string,
	lookBack: string,
	rescue: string,
}

export type GraphicsSettings = {
	preset: GraphicsPreset,
	bloom: boolean,
	depthOfField: boolean,
	sunRays: boolean,
	colorCorrection: boolean,
	particles: number,
	shadows: boolean,
	kartHighlight: boolean,
	trackDetail: TrackDetailLevel,
}

export type UserSettings = {
	version: number,
	graphics: GraphicsSettings,
	audio: {
		masterMuted: boolean,
		sfxVolume: number,
		engineVolume: number,
		uiVolume: number,
	},
	ui: {
		skin: SkinName,
		skinVariant: SkinVariantName,
		minimapDisplay: number,
		fontSize: number,
		showFps: boolean,
		showOtherPowerups: boolean,
		cameraPreset: CameraPreset,
	},
	input: {
		keyboard: KeyboardBindings,
		gamepad: GamepadBindings,
	},
}

local VALID_PRESETS: { [string]: boolean } = {
	Low = true,
	Medium = true,
	High = true,
}

local VALID_TRACK_DETAIL: { [string]: boolean } = {
	Low = true,
	Medium = true,
	High = true,
}

local VALID_CAMERA_PRESETS: { [string]: boolean } = {
	Normal = true,
	Close = true,
	Far = true,
}

local VALID_SKINS: { [string]: boolean } = {
	Classic = true,
	Cartoon = true,
}

local VALID_SKIN_VARIANTS: { [string]: boolean } = {
	Peach = true,
	Coal = true,
	Desert = true,
	Forest = true,
	Ocean = true,
	Ruby = true,
}

local VALID_KEYBOARD_NAMES: { [string]: boolean } = {
	W = true,
	A = true,
	S = true,
	D = true,
	Q = true,
	E = true,
	R = true,
	F = true,
	B = true,
	C = true,
	X = true,
	Z = true,
	Up = true,
	Down = true,
	Left = true,
	Right = true,
	Space = true,
	LeftShift = true,
	RightShift = true,
	LeftControl = true,
	RightControl = true,
	Return = true,
}

local VALID_GAMEPAD_NAMES: { [string]: boolean } = {
	ButtonA = true,
	ButtonB = true,
	ButtonX = true,
	ButtonY = true,
	ButtonL1 = true,
	ButtonR1 = true,
	ButtonL2 = true,
	ButtonR2 = true,
	ButtonL3 = true,
	ButtonR3 = true,
	DPadUp = true,
	DPadDown = true,
	DPadLeft = true,
	DPadRight = true,
}

local SettingsSchema = {}

SettingsSchema.SKIN_ORDER = { "Classic", "Cartoon" } :: { SkinName }
SettingsSchema.SKIN_VARIANT_ORDER = { "Peach", "Coal", "Desert", "Forest", "Ocean", "Ruby" } :: { SkinVariantName }
SettingsSchema.TRACK_DETAIL_ORDER = { "Low", "Medium", "High" } :: { TrackDetailLevel }

-- Upstream STK 1.5 font size labels for normal UI range 1..5 (options_screen_ui.cpp:L89-L109)
local FONT_SIZE_LABELS: { [number]: string } = {
	[1] = "Very small",
	[2] = "Small",
	[3] = "Medium",
	[4] = "Large",
	[5] = "Very large",
}

local FONT_SIZE_SCALES: { [number]: number } = {
	[1] = 0.80,
	[2] = 0.90,
	[3] = 1.00,
	[4] = 1.12,
	[5] = 1.25,
}

-- Upstream STK 1.5 minimap display options 0..3 (options_screen_ui.cpp:L64-L80, user_config.hpp:L1278-L1279)
local MINIMAP_LABELS: { [number]: string } = {
	[0] = "In the bottom-left",
	[1] = "On the right side",
	[2] = "Hidden",
	[3] = "Centered",
}

function SettingsSchema.defaults(): UserSettings
	return {
		version = 2,
		graphics = {
			preset = "High",
			bloom = true,
			depthOfField = true,
			sunRays = true,
			colorCorrection = true,
			particles = 2,
			shadows = true,
			kartHighlight = false,
			trackDetail = "High",
		},
		audio = {
			masterMuted = false,
			sfxVolume = 0.85,
			engineVolume = 0.85,
			uiVolume = 0.85,
		},
		ui = {
			skin = "Classic", -- user_config.hpp:L1269
			skinVariant = "Peach", -- data/skins/classic/stkskin.xml:L11
			minimapDisplay = 0, -- user_config.hpp:L1278 (0 bottom-left)
			fontSize = 3, -- user_config.hpp:L715 (3 Medium)
			showFps = false, -- user_config.hpp:L652
			showOtherPowerups = false, -- user_config.hpp:L491
			cameraPreset = "Normal",
		},
		input = {
			keyboard = {
				accelerate = "W",
				brake = "S",
				steerLeft = "A",
				steerRight = "D",
				drift = "Space",
				fire = "F",
				nitro = "LeftShift",
				lookBack = "B",
				rescue = "R",
			},
			gamepad = {
				accelerate = "ButtonR2",
				brake = "ButtonL2",
				drift = "ButtonR1",
				fire = "ButtonA",
				nitro = "ButtonB",
				lookBack = "ButtonX",
				rescue = "ButtonY",
			},
		},
	}
end

local function clamp01(value: any, fallback: number): number
	if type(value) ~= "number" or value ~= value then
		return fallback
	end
	return math.clamp(value, 0, 1)
end

local function clampInt(value: any, minVal: number, maxVal: number, fallback: number): number
	if type(value) ~= "number" or value ~= value then
		return fallback
	end
	return math.clamp(math.floor(value + 0.5), minVal, maxVal)
end

function SettingsSchema.sanitize(raw: any): UserSettings
	local out = SettingsSchema.defaults()
	if type(raw) ~= "table" then
		return out
	end

	local gfx = raw.graphics
	if type(gfx) == "table" then
		if type(gfx.preset) == "string" and VALID_PRESETS[gfx.preset] then
			out.graphics.preset = gfx.preset :: GraphicsPreset
		end
		local legacyPost = if type(gfx.postEffects) == "boolean" then gfx.postEffects else nil
		if type(gfx.bloom) == "boolean" then
			out.graphics.bloom = gfx.bloom
		elseif legacyPost ~= nil then
			out.graphics.bloom = legacyPost
		end
		if type(gfx.depthOfField) == "boolean" then
			out.graphics.depthOfField = gfx.depthOfField
		elseif legacyPost ~= nil then
			out.graphics.depthOfField = legacyPost
		end
		if type(gfx.sunRays) == "boolean" then
			out.graphics.sunRays = gfx.sunRays
		elseif legacyPost ~= nil then
			out.graphics.sunRays = legacyPost
		end
		if type(gfx.colorCorrection) == "boolean" then
			out.graphics.colorCorrection = gfx.colorCorrection
		elseif legacyPost ~= nil then
			out.graphics.colorCorrection = legacyPost
		end
		out.graphics.particles = clampInt(gfx.particles, 0, 2, out.graphics.particles)
		if type(gfx.shadows) == "boolean" then
			out.graphics.shadows = gfx.shadows
		end
		if type(gfx.kartHighlight) == "boolean" then
			out.graphics.kartHighlight = gfx.kartHighlight
		end
		if type(gfx.trackDetail) == "string" and VALID_TRACK_DETAIL[gfx.trackDetail] then
			out.graphics.trackDetail = gfx.trackDetail :: TrackDetailLevel
		end
	end

	local audio = raw.audio
	if type(audio) == "table" then
		if type(audio.masterMuted) == "boolean" then
			out.audio.masterMuted = audio.masterMuted
		end
		out.audio.sfxVolume = clamp01(audio.sfxVolume, out.audio.sfxVolume)
		out.audio.engineVolume = clamp01(audio.engineVolume, out.audio.engineVolume)
		out.audio.uiVolume = clamp01(audio.uiVolume, out.audio.uiVolume)
	end

	local ui = raw.ui
	if type(ui) == "table" then
		if type(ui.skin) == "string" and VALID_SKINS[ui.skin] then
			out.ui.skin = ui.skin :: SkinName
		end
		if type(ui.skinVariant) == "string" and VALID_SKIN_VARIANTS[ui.skinVariant] then
			out.ui.skinVariant = ui.skinVariant :: SkinVariantName
		end
		out.ui.minimapDisplay = clampInt(ui.minimapDisplay, 0, 3, out.ui.minimapDisplay)
		out.ui.fontSize = clampInt(ui.fontSize, 1, 5, out.ui.fontSize)
		if type(ui.showFps) == "boolean" then
			out.ui.showFps = ui.showFps
		end
		if type(ui.showOtherPowerups) == "boolean" then
			out.ui.showOtherPowerups = ui.showOtherPowerups
		end
		if type(ui.cameraPreset) == "string" and VALID_CAMERA_PRESETS[ui.cameraPreset] then
			out.ui.cameraPreset = ui.cameraPreset :: CameraPreset
		end
	end

	local input = raw.input
	if type(input) == "table" then
		if type(input.keyboard) == "table" then
			for key, defaultVal in pairs(out.input.keyboard :: { [string]: string }) do
				local candidate = input.keyboard[key]
				if type(candidate) == "string" and VALID_KEYBOARD_NAMES[candidate] then
					(out.input.keyboard :: { [string]: string })[key] = candidate
				else
					(out.input.keyboard :: { [string]: string })[key] = defaultVal
				end
			end
		end
		if type(input.gamepad) == "table" then
			for key, defaultVal in pairs(out.input.gamepad :: { [string]: string }) do
				local candidate = input.gamepad[key]
				if type(candidate) == "string" and VALID_GAMEPAD_NAMES[candidate] then
					(out.input.gamepad :: { [string]: string })[key] = candidate
				else
					(out.input.gamepad :: { [string]: string })[key] = defaultVal
				end
			end
		end
	end

	return out
end

function SettingsSchema.applyGraphicsPreset(preset: GraphicsPreset): GraphicsSettings
	if preset == "Low" then
		return {
			preset = "Low",
			bloom = false,
			depthOfField = false,
			sunRays = false,
			colorCorrection = false,
			particles = 0,
			shadows = false,
			kartHighlight = false,
			trackDetail = "Low",
		}
	elseif preset == "Medium" then
		return {
			preset = "Medium",
			bloom = true,
			depthOfField = false,
			sunRays = false,
			colorCorrection = true,
			particles = 1,
			shadows = true,
			kartHighlight = false,
			trackDetail = "Medium",
		}
	end
	return {
		preset = "High",
		bloom = true,
		depthOfField = true,
		sunRays = true,
		colorCorrection = true,
		particles = 2,
		shadows = true,
		kartHighlight = false,
		trackDetail = "High",
	}
end

function SettingsSchema.getParticleRateMultiplier(particlesLevel: number): number
	if particlesLevel <= 0 then
		return 0
	elseif particlesLevel == 1 then
		return 0.4
	end
	return 1.0
end

function SettingsSchema.getFontSizeLabel(level: number): string
	local clamped = clampInt(level, 1, 5, 3)
	return FONT_SIZE_LABELS[clamped] or "Medium"
end

function SettingsSchema.getFontSizeScale(level: number): number
	local clamped = clampInt(level, 1, 5, 3)
	return FONT_SIZE_SCALES[clamped] or 1.0
end

function SettingsSchema.getMinimapLabel(mode: number): string
	local clamped = clampInt(mode, 0, 3, 0)
	return MINIMAP_LABELS[clamped] or "In the bottom-left"
end

function SettingsSchema.getCameraPresetScale(preset: CameraPreset): {
	distanceScale: number,
	heightOffset: number,
}
	if preset == "Close" then
		return { distanceScale = 0.82, heightOffset = -0.35 }
	elseif preset == "Far" then
		return { distanceScale = 1.28, heightOffset = 0.55 }
	end
	return { distanceScale = 1.0, heightOffset = 0.0 }
end

return SettingsSchema
