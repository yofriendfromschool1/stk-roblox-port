--!strict
-- src/shared/kart/SlipstreamVfxMath.lua
-- SPDX-License-Identifier: GPL-3.0-or-later
-- ported from src/graphics/slip_stream.cpp:L53-L56, L594-L615, L664-L668 (STK 1.5)
-- Pure-Luau slipstream two-state charge VFX evaluator (zero Roblox API).
-- Color and visibility are driven strictly by sim charge state:
--   inZone == true and chargeTicks <= minCollectTicks -> CHARGING (white 255,255,255)
--   inZone == true and chargeTicks >  minCollectTicks -> CHARGED  (yellow 255,208,41)
--   inZone == false                                   -> NONE     (off)

export type SlipstreamVfxStage = "NONE" | "CHARGING" | "CHARGED"

export type SlipstreamVfxInput = {
	inZone: boolean,
	chargeTicks: number,
	minCollectTicks: number,
}

export type SlipstreamVfxParams = {
	enabled: boolean,
	stage: SlipstreamVfxStage,
	intensity: number,
	rate: number,
	peakAlpha: number,
	colorR: number,
	colorG: number,
	colorB: number,
}

local SlipstreamVfxMath = {}

function SlipstreamVfxMath.evaluate(inp: SlipstreamVfxInput): SlipstreamVfxParams
	if not inp.inZone or inp.chargeTicks <= 0 then
		return {
			enabled = false,
			stage = "NONE",
			intensity = 0.0,
			rate = 0.0,
			peakAlpha = 0.0,
			colorR = 255,
			colorG = 255,
			colorB = 255,
		}
	end

	local minTicks = math.max(1, inp.minCollectTicks)
	if inp.chargeTicks > minTicks then
		local extra = math.clamp((inp.chargeTicks - minTicks) / 660.0, 0.0, 1.0)
		local intensity = 0.75 + 0.25 * extra
		return {
			enabled = true,
			stage = "CHARGED",
			intensity = intensity,
			rate = 70.0 + 20.0 * extra,
			peakAlpha = 0.95,
			-- STK slipstream2.png measured bright-pixel average RGB(255, 208, 41)
			colorR = 255,
			colorG = 208,
			colorB = 41,
		}
	end

	local progress = math.clamp(inp.chargeTicks / minTicks, 0.0, 1.0)
	return {
		enabled = true,
		stage = "CHARGING",
		intensity = 0.25 + 0.50 * progress,
		rate = 40.0 + 25.0 * progress,
		peakAlpha = 0.75 + 0.20 * progress,
		-- STK slipstream.png measured bright-pixel average RGB(255, 255, 255)
		colorR = 255,
		colorG = 255,
		colorB = 255,
	}
end

return table.freeze(SlipstreamVfxMath)
