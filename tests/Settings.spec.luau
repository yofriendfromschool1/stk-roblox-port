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
			assertEqual(def.ui.minimapDisplay, 1, "default minimap")
			assertEqual(def.input.keyboard.accelerate, "W", "default accel key")

			local s = SettingsSchema.sanitize({
				graphics = { preset = "Ultra", shadows = "yes", particles = 9, postEffects = false },
				audio = { masterMuted = true, engineVolume = -2, sfxVolume = 4, uiVolume = 0.5 },
				ui = { minimapDisplay = 5, showFps = false, cameraPreset = "Orbital" },
				input = {
					keyboard = { accelerate = "E", brake = "InvalidKeyName" },
					gamepad = { fire = "ButtonX", nitro = "InvalidBtn" },
				},
			})
			assertEqual(s.graphics.preset, "High", "invalid preset falls back")
			assertEqual(s.graphics.particles, 2, "particles clamped")
			assertEqual(s.graphics.postEffects, false, "postEffects preserved")
			assertEqual(s.audio.engineVolume, 0, "engineVol clamped min")
			assertEqual(s.audio.sfxVolume, 1, "sfxVol clamped max")
			assertEqual(s.audio.uiVolume, 0.5, "uiVol preserved")
			assertEqual(s.ui.minimapDisplay, 2, "minimap clamped")
			assertEqual(s.ui.cameraPreset, "Normal", "invalid cameraPreset fallback")
			assertEqual(s.input.keyboard.accelerate, "E", "valid rebound key kept")
			assertEqual(s.input.keyboard.brake, "S", "invalid key rejected")
			assertEqual(s.input.gamepad.fire, "ButtonX", "valid gamepad bind kept")
			assertEqual(s.input.gamepad.nitro, "ButtonB", "invalid gamepad bind rejected")
		end,
	},
	{
		name = "graphics presets, particle multipliers, and camera scales",
		fn = function()
			local low = SettingsSchema.applyGraphicsPreset("Low")
			assertEqual(low.shadows, false, "low shadows")
			assertEqual(low.particles, 0, "low particles")
			assertEqual(low.postEffects, false, "low postEffects")

			assertEqual(SettingsSchema.getParticleRateMultiplier(0), 0, "mult 0")
			assertEqual(SettingsSchema.getParticleRateMultiplier(1), 0.4, "mult 1")
			assertEqual(SettingsSchema.getParticleRateMultiplier(2), 1.0, "mult 2")

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
