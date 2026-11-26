--!strict
-- SPDX-License-Identifier: GPL-3.0-or-later
-- Applies UserSettings strictly to client-owned instances (never writes replicated Lighting properties).

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local SettingsSchema = require(Shared.settings.SettingsSchema)

local SettingsApplier = {}

local function getOrCreateClientEffect(className: "BloomEffect" | "SunRaysEffect", name: string): any
	local existing = Lighting:FindFirstChild(name)
	if existing and existing:IsA(className) then
		return existing
	end
	local eff = Instance.new(className)
	eff.Name = name
	if className == "BloomEffect" then
		(eff :: BloomEffect).Intensity = 0.25
		(eff :: BloomEffect).Size = 18
		(eff :: BloomEffect).Threshold = 1.25
	else
		(eff :: SunRaysEffect).Intensity = 0.08
		(eff :: SunRaysEffect).Spread = 0.45
	end
	eff.Parent = Lighting
	return eff
end

function SettingsApplier.applyClientPostEffects(enabled: boolean): ()
	local bloom = getOrCreateClientEffect("BloomEffect", "OpenKartClientBloom") :: BloomEffect
	local sunRays = getOrCreateClientEffect("SunRaysEffect", "OpenKartClientSunRays") :: SunRaysEffect
	bloom.Enabled = enabled == true
	sunRays.Enabled = enabled == true
end

function SettingsApplier.applyGraphicsToWorkspace(
	settings: SettingsSchema.UserSettings,
	visualKarts: { [string]: any },
	kartPresentationModule: any
): ()
	SettingsApplier.applyClientPostEffects(settings.graphics.postEffects)
	local mult = SettingsSchema.getParticleRateMultiplier(settings.graphics.particles)
	for _, visual in pairs(visualKarts) do
		kartPresentationModule.applyVisualSettings(visual, settings.graphics.shadows, mult)
	end
end

return SettingsApplier
