--!strict
-- SPDX-License-Identifier: GPL-3.0-or-later
-- Applies UserSettings strictly to client-owned instances (never writes replicated Lighting properties).

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local SettingsSchema = require(Shared.settings.SettingsSchema)
local TrackRegistry = require(Shared.track.TrackRegistry)

local SettingsApplier = {}

local function getOrCreateClientEffect(
	className: "BloomEffect" | "DepthOfFieldEffect" | "SunRaysEffect" | "ColorCorrectionEffect",
	name: string
): any
	local existing = Lighting:FindFirstChild(name)
	if existing and existing:IsA(className) then
		return existing
	end
	local eff = Instance.new(className)
	eff.Name = name
	if className == "BloomEffect" then
		(eff :: BloomEffect).Intensity = 0.65
		(eff :: BloomEffect).Size = 24
		(eff :: BloomEffect).Threshold = 0.95
	elseif className == "DepthOfFieldEffect" then
		(eff :: DepthOfFieldEffect).FocusDistance = 28
		(eff :: DepthOfFieldEffect).InFocusRadius = 38
		(eff :: DepthOfFieldEffect).FarIntensity = 0.45
		(eff :: DepthOfFieldEffect).NearIntensity = 0.0
	elseif className == "SunRaysEffect" then
		(eff :: SunRaysEffect).Intensity = 0.25
		(eff :: SunRaysEffect).Spread = 0.65
	else
		(eff :: ColorCorrectionEffect).Brightness = 0.05
		(eff :: ColorCorrectionEffect).Contrast = 0.18
		(eff :: ColorCorrectionEffect).Saturation = 0.25
		(eff :: ColorCorrectionEffect).TintColor = Color3.fromRGB(255, 246, 230)
	end
	eff.Parent = Lighting
	return eff
end

function SettingsApplier.applyClientPostEffects(graphics: SettingsSchema.GraphicsSettings): ()
	local bloom = getOrCreateClientEffect("BloomEffect", "OpenKartClientBloom") :: BloomEffect
	local dof = getOrCreateClientEffect("DepthOfFieldEffect", "OpenKartClientDepthOfField") :: DepthOfFieldEffect
	local sunRays = getOrCreateClientEffect("SunRaysEffect", "OpenKartClientSunRays") :: SunRaysEffect
	local colorCorr =
		getOrCreateClientEffect("ColorCorrectionEffect", "OpenKartClientColorCorrection") :: ColorCorrectionEffect

	bloom.Enabled = graphics.bloom == true
	dof.Enabled = graphics.depthOfField == true
	sunRays.Enabled = graphics.sunRays == true
	colorCorr.Enabled = graphics.colorCorrection == true
end

function SettingsApplier.applyTrackDetail(trackDetail: SettingsSchema.TrackDetailLevel): ()
	local activeTrack = Workspace:FindFirstChild(TrackRegistry.ACTIVE_TRACK_MODEL_NAME)
	if not activeTrack then
		return
	end
	local propsFolder = activeTrack:FindFirstChild("Props")
	if not propsFolder then
		return
	end
	for _, desc in ipairs(propsFolder:GetDescendants()) do
		if desc:IsA("BasePart") then
			if trackDetail == "High" then
				desc.LocalTransparencyModifier = 0
			elseif trackDetail == "Medium" then
				desc.LocalTransparencyModifier = if desc.Size.Magnitude >= 22 then 0 else 1
			else
				desc.LocalTransparencyModifier = 1
			end
		end
	end
end

function SettingsApplier.applyGraphicsToWorkspace(
	settings: SettingsSchema.UserSettings,
	visualKarts: { [string]: any },
	kartPresentationModule: any
): ()
	SettingsApplier.applyClientPostEffects(settings.graphics)
	SettingsApplier.applyTrackDetail(settings.graphics.trackDetail)
	local mult = SettingsSchema.getParticleRateMultiplier(settings.graphics.particles)
	for _, visual in pairs(visualKarts) do
		kartPresentationModule.applyVisualSettings(
			visual,
			settings.graphics.shadows,
			mult,
			settings.graphics.kartHighlight
		)
	end
end

return SettingsApplier
