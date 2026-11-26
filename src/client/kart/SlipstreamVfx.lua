--!strict
-- src/client/kart/SlipstreamVfx.lua
-- SPDX-License-Identifier: GPL-3.0-or-later
-- ported from src/graphics/slip_stream.cpp:L53-L56, L594-L615, L664-L668 (STK 1.5)
-- Pooled per-kart slipstream trailing-streak ParticleEmitter positioned AHEAD of the chassis (-Z),
-- sweeping tight forward-to-back streaks around the kart, colored strictly by sim charge state.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local KartTuning = require(Shared.KartTuning)
local SlipstreamVfxMath = require(Shared.kart.SlipstreamVfxMath)
local Units = require(Shared.Units)

export type SlipstreamVfxInstance = {
	regionPart: Part,
	emitter: ParticleEmitter,
	localCf: CFrame,
	lastEnabled: boolean,
	lastStage: SlipstreamVfxMath.SlipstreamVfxStage,
	lastQuantIntensity: number,
}

-- Self-authored CC0 single-streak radial core (assets/vfx/slipstream/streak_core_cc0.png)
local STREAK_TEXTURE = "rbxassetid://94906245797716"

local CHARGING_COLOR = ColorSequence.new(Color3.fromRGB(255, 255, 255))
local CHARGED_COLOR = ColorSequence.new(Color3.fromRGB(255, 208, 41))

local STREAK_SIZE_SEQ = NumberSequence.new(0.45)
local CLEAR_TRANSPARENCY = NumberSequence.new(1)
-- Positive Squash elongates ParticleEmitter along VelocityParallel motion axis (+Y)
local STREAK_SQUASH = NumberSequence.new(1.5)

local SlipstreamVfx = {}

function SlipstreamVfx.create(parentModel: Instance, profile: KartTuning.KartProfile): SlipstreamVfxInstance
	-- Thin cross-sectional box AHEAD of the chassis (-Z forward in Roblox) so streaks
	-- sweep forward-to-back around both sides and over the kart in a tight airflow band.
	local wStuds = Units.metersToStuds(math.max(1.45, profile.width * 1.75))
	local hStuds = Units.metersToStuds(0.50)
	local lStuds = Units.metersToStuds(0.20)

	local regionPart = Instance.new("Part")
	regionPart.Name = "SlipstreamRegion"
	regionPart.Anchored = true
	regionPart.CanCollide = false
	regionPart.CanTouch = false
	regionPart.CanQuery = false
	regionPart.Massless = true
	regionPart.Transparency = 1.0
	regionPart.Size = Vector3.new(wStuds, hStuds, lStuds)
	regionPart.TopSurface = Enum.SurfaceType.Smooth
	regionPart.BottomSurface = Enum.SurfaceType.Smooth
	regionPart.Parent = parentModel

	local localCf = CFrame.new(0, Units.metersToStuds(0.55), Units.metersToStuds(-1.65))
	regionPart.CFrame = localCf

	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "SlipstreamEmitter"
	emitter.Enabled = false
	emitter.Texture = STREAK_TEXTURE
	emitter.Orientation = Enum.ParticleOrientation.VelocityParallel
	emitter.VelocityInheritance = 0
	emitter.LockedToPart = false
	emitter.EmissionDirection = Enum.NormalId.Back
	emitter.LightEmission = 1.0
	emitter.Brightness = 2.5
	emitter.Color = CHARGING_COLOR
	emitter.Size = STREAK_SIZE_SEQ
	emitter.Squash = STREAK_SQUASH
	emitter.Transparency = CLEAR_TRANSPARENCY
	emitter.SpreadAngle = Vector2.new(2.5, 2.0)
	emitter.Rate = 0
	emitter.Lifetime = NumberRange.new(0.16, 0.24)
	emitter.Speed = NumberRange.new(12, 18)
	emitter.Parent = regionPart

	return {
		regionPart = regionPart,
		emitter = emitter,
		localCf = localCf,
		lastEnabled = false,
		lastStage = "NONE",
		lastQuantIntensity = -1,
	}
end

function SlipstreamVfx.update(
	vfx: SlipstreamVfxInstance,
	kartOriginCf: CFrame,
	inp: SlipstreamVfxMath.SlipstreamVfxInput?
)
	vfx.regionPart.CFrame = kartOriginCf * vfx.localCf

	if inp == nil then
		if vfx.lastEnabled then
			vfx.emitter.Enabled = false
			vfx.lastEnabled = false
			vfx.lastStage = "NONE"
			vfx.lastQuantIntensity = -1
		end
		return
	end

	local params = SlipstreamVfxMath.evaluate(inp)
	if params.enabled ~= vfx.lastEnabled then
		vfx.emitter.Enabled = params.enabled
		vfx.lastEnabled = params.enabled
	end

	if not params.enabled then
		vfx.lastStage = "NONE"
		vfx.lastQuantIntensity = -1
		return
	end

	local quantIntensity = math.round(params.intensity * 20)
	if params.stage ~= vfx.lastStage then
		vfx.emitter.Color = if params.stage == "CHARGED" then CHARGED_COLOR else CHARGING_COLOR
		vfx.lastStage = params.stage
		vfx.lastQuantIntensity = -1
	end

	if quantIntensity ~= vfx.lastQuantIntensity then
		vfx.lastQuantIntensity = quantIntensity
		vfx.emitter.Rate = params.rate
		local peakT = math.clamp(1.0 - params.peakAlpha, 0.05, 0.95)
		local tailT = math.clamp(1.0 - params.peakAlpha * 0.85, 0.1, 0.98)
		vfx.emitter.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.25, peakT),
			NumberSequenceKeypoint.new(0.75, tailT),
			NumberSequenceKeypoint.new(1, 1),
		})
	end
end

function SlipstreamVfx.destroy(vfx: SlipstreamVfxInstance)
	vfx.emitter.Enabled = false
	vfx.regionPart:Destroy()
end

return table.freeze(SlipstreamVfx)
