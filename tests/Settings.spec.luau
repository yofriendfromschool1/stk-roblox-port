--!strict
-- tests/Settings.spec.luau
-- SPDX-License-Identifier: GPL-3.0-or-later

local InputMapper = require("../src/client/InputMapper")
local SettingsSchema = require("../src/shared/settings/SettingsSchema")

local function assertEqual(actual: any, expected: any, msg: string)
	if actual ~= expected then
		error(string.format("%s: expected %s, got %s", msg, tostring(expected), tostring(actual)), 2)
	end
end

local function assertTrue(cond: boolean, msg: string)
	if not cond then
		error(msg, 2)
	end
end

return {
	{
		name = "defaults and sanitize clamp invalid values",
		fn = function()
			local def = SettingsSchema.defaults()
			assertEqual(def.graphics.preset, "High", "default preset")
			assertEqual(def.graphics.bloom, true, "default bloom")
			assertEqual(def.graphics.depthOfField, true, "default dof")
			assertEqual(def.graphics.sunRays, true, "default sunRays")
			assertEqual(def.graphics.colorCorrection, true, "default colorCorrection")
			assertEqual(def.graphics.trackDetail, "High", "default trackDetail")
			assertEqual(def.ui.skin, "Classic", "default skin")
			assertEqual(def.ui.skinVariant, "Peach", "default skinVariant")
			assertEqual(def.ui.minimapDisplay, 0, "default minimap bottom-left (0)")
			assertEqual(def.ui.fontSize, 3, "default fontSize Medium (3)")
			assertEqual(def.ui.showFps, false, "default showFps false")
			assertEqual(def.ui.showOtherPowerups, false, "default showOtherPowerups false")
			assertEqual(def.input.keyboard.accelerate, "W", "default accel key")

			local s = SettingsSchema.sanitize({
				graphics = {
					preset = "Ultra",
					shadows = "yes",
					particles = 9,
					postEffects = false,
					trackDetail = "Extreme",
				},
				audio = { masterMuted = true, engineVolume = -2, sfxVolume = 4, uiVolume = 0.5 },
				ui = {
					skin = "Neon",
					skinVariant = "Purple",
					minimapDisplay = 5,
					fontSize = 99,
					showFps = true,
					showOtherPowerups = true,
					cameraPreset = "Orbital",
				},
				input = {
					keyboard = { accelerate = "E", brake = "InvalidKeyName" },
					gamepad = { fire = "ButtonX", nitro = "InvalidBtn" },
				},
			})
			assertEqual(s.graphics.preset, "High", "invalid preset falls back")
			assertEqual(s.graphics.particles, 2, "particles clamped")
			assertEqual(s.graphics.bloom, false, "legacy postEffects=false seeds bloom")
			assertEqual(s.graphics.depthOfField, false, "legacy postEffects=false seeds dof")
			assertEqual(s.graphics.sunRays, false, "legacy postEffects=false seeds sunRays")
			assertEqual(s.graphics.colorCorrection, false, "legacy postEffects=false seeds colorCorrection")
			assertEqual(s.graphics.trackDetail, "High", "invalid trackDetail falls back")
			assertEqual(s.audio.engineVolume, 0, "engineVol clamped min")
			assertEqual(s.audio.sfxVolume, 1, "sfxVol clamped max")
			assertEqual(s.audio.uiVolume, 0.5, "uiVol preserved")
			assertEqual(s.ui.skin, "Classic", "invalid skin falls back")
			assertEqual(s.ui.skinVariant, "Peach", "invalid variant falls back")
			assertEqual(s.ui.minimapDisplay, 3, "minimap clamped to 0..3")
			assertEqual(s.ui.fontSize, 5, "fontSize clamped to 1..5")
			assertEqual(s.ui.showFps, true, "showFps preserved")
			assertEqual(s.ui.showOtherPowerups, true, "showOtherPowerups preserved")
			assertEqual(s.ui.cameraPreset, "Normal", "invalid cameraPreset fallback")
			assertEqual(s.input.keyboard.accelerate, "E", "valid rebound key kept")
			assertEqual(s.input.keyboard.brake, "S", "invalid key rejected")
			assertEqual(s.input.gamepad.fire, "ButtonX", "valid gamepad bind kept")
			assertEqual(s.input.gamepad.nitro, "ButtonB", "invalid gamepad bind rejected")
		end,
	},
	{
		name = "graphics presets, particle multipliers, font scales, and camera scales",
		fn = function()
			local low = SettingsSchema.applyGraphicsPreset("Low")
			assertEqual(low.shadows, false, "low shadows")
			assertEqual(low.particles, 0, "low particles")
			assertEqual(low.bloom, false, "low bloom")
			assertEqual(low.depthOfField, false, "low dof")
			assertEqual(low.sunRays, false, "low sunRays")
			assertEqual(low.colorCorrection, false, "low colorCorrection")
			assertEqual(low.trackDetail, "Low", "low trackDetail")

			local med = SettingsSchema.applyGraphicsPreset("Medium")
			assertEqual(med.bloom, true, "med bloom")
			assertEqual(med.depthOfField, false, "med dof")
			assertEqual(med.trackDetail, "Medium", "med trackDetail")

			assertEqual(SettingsSchema.getParticleRateMultiplier(0), 0, "mult 0")
			assertEqual(SettingsSchema.getParticleRateMultiplier(1), 0.4, "mult 1")
			assertEqual(SettingsSchema.getParticleRateMultiplier(2), 1.0, "mult 2")

			assertEqual(SettingsSchema.getFontSizeLabel(1), "Very small", "font label 1")
			assertEqual(SettingsSchema.getFontSizeLabel(3), "Medium", "font label 3")
			assertTrue(SettingsSchema.getFontSizeScale(1) < SettingsSchema.getFontSizeScale(3), "font scale monotonic")
			assertTrue(SettingsSchema.getFontSizeScale(3) < SettingsSchema.getFontSizeScale(5), "font scale monotonic")
			assertEqual(SettingsSchema.getMinimapLabel(0), "In the bottom-left", "minimap 0")
			assertEqual(SettingsSchema.getMinimapLabel(1), "On the right side", "minimap 1")
			assertEqual(SettingsSchema.getMinimapLabel(2), "Hidden", "minimap 2")
			assertEqual(SettingsSchema.getMinimapLabel(3), "Centered", "minimap 3")

			local closeCam = SettingsSchema.getCameraPresetScale("Close")
			local farCam = SettingsSchema.getCameraPresetScale("Far")
			assertTrue(closeCam.distanceScale < 1.0 and farCam.distanceScale > 1.0, "camera scales differ")
		end,
	},
	{
		name = "InputMapper honors rebound keyboard and gamepad bindings",
		fn = function()
			local binds = SettingsSchema.defaults().input
			binds.keyboard.accelerate = "E"
			binds.keyboard.fire = "Q"
			local mappedW = InputMapper.fromKeyboard({ W = true }, false, false, binds.keyboard)
			assertEqual(mappedW.kartInput.accel, 0, "old W ignored when rebound to E")
			local mappedE = InputMapper.fromKeyboard({ E = true, Q = true }, false, false, binds.keyboard)
			assertEqual(mappedE.kartInput.accel, 1.0, "rebound E accelerates")
			assertEqual(mappedE.kartInput.fire, true, "rebound Q fires")

			binds.gamepad.fire = "ButtonX"
			local gpMapped = InputMapper.fromGamepad(
				{ thumbstick1X = 0, triggerR2 = 0, triggerL2 = 0 },
				{ ButtonX = true },
				false,
				binds.gamepad
			)
			assertEqual(gpMapped.kartInput.fire, true, "rebound gamepad ButtonX fires")
		end,
	},
}
