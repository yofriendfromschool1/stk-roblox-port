--!strict
-- SPDX-License-Identifier: GPL-3.0-or-later
-- Ported from data/gui/screens/options/options_{video,audio,ui,input}.stkgui (STK 1.5).

export type GraphicsPreset = "Low" | "Medium" | "High"
export type CameraPreset = "Normal" | "Close" | "Far"

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

export type UserSettings = {
	version: number,
	graphics: {
		preset: GraphicsPreset,
		shadows: boolean,
		particles: number,
		postEffects: boolean,
	},
	audio: {
		masterMuted: boolean,
		sfxVolume: number,
		engineVolume: number,
		uiVolume: number,
	},
	ui: {
		minimapDisplay: number,
		showFps: boolean,
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

local VALID_CAMERA_PRESETS: { [string]: boolean } = {
	Normal = true,
	Close = true,
	Far = true,
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

function SettingsSchema.defaults(): UserSettings
	return {
		version = 1,
		graphics = {
			preset = "High",
			shadows = true,
			particles = 2,
			postEffects = true,
		},
		audio = {
			masterMuted = false,
			sfxVolume = 0.85,
			engineVolume = 0.85,
			uiVolume = 0.85,
		},
		ui = {
			minimapDisplay = 1,
			showFps = true,
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
		if type(gfx.shadows) == "boolean" then
			out.graphics.shadows = gfx.shadows
		end
		out.graphics.particles = clampInt(gfx.particles, 0, 2, out.graphics.particles)
		if type(gfx.postEffects) == "boolean" then
			out.graphics.postEffects = gfx.postEffects
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
		out.ui.minimapDisplay = clampInt(ui.minimapDisplay, 0, 2, out.ui.minimapDisplay)
		if type(ui.showFps) == "boolean" then
			out.ui.showFps = ui.showFps
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

function SettingsSchema.applyGraphicsPreset(preset: GraphicsPreset): {
	preset: GraphicsPreset,
	shadows: boolean,
	particles: number,
	postEffects: boolean,
}
	if preset == "Low" then
		return { preset = "Low", shadows = false, particles = 0, postEffects = false }
	elseif preset == "Medium" then
		return { preset = "Medium", shadows = true, particles = 1, postEffects = false }
	end
	return { preset = "High", shadows = true, particles = 2, postEffects = true }
end

function SettingsSchema.getParticleRateMultiplier(particlesLevel: number): number
	if particlesLevel <= 0 then
		return 0
	elseif particlesLevel == 1 then
		return 0.4
	end
	return 1.0
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
