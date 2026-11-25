--!strict
-- src/shared/track/SurfaceMaterials.lua
-- SPDX-License-Identifier: GPL-3.0-or-later
-- ported from src/graphics/material.cpp:L100-L187, L502-L541,
-- src/karts/kart.cpp:L1709-L1737, L2414-L2464 (STK 1.5)
-- Pure-Luau track surface material lookup (zero Roblox API dependencies).

export type CollisionReaction = "normal" | "reset" | "push" | "push-soccer"

export type SurfaceMaterial = {
	name: string,
	maxSpeedFraction: number,
	slowdownTime: number,
	highTireAdhesion: boolean,
	ignore: boolean,
	reset: boolean,
	fallingEffect: boolean,
	surface: boolean,
	belowSurface: boolean,
	collisionDetect: boolean,
	collisionReaction: CollisionReaction,
	friction: number,
}

export type MaterialOverrides = {
	maxSpeedFraction: number?,
	slowdownTime: number?,
	highTireAdhesion: boolean?,
	ignore: boolean?,
	reset: boolean?,
	fallingEffect: boolean?,
	surface: boolean?,
	belowSurface: boolean?,
	collisionDetect: boolean?,
	collisionReaction: CollisionReaction?,
	friction: number?,
}

local function makeMaterial(name: string, overrides: MaterialOverrides?): SurfaceMaterial
	local o: MaterialOverrides = overrides or {}
	local falling = o.fallingEffect == true
	-- src/graphics/material.cpp:L159-L160: falling-effect forces m_drive_reset = true
	local reset = (o.reset == true) or falling
	return table.freeze({
		name = name,
		maxSpeedFraction = o.maxSpeedFraction or 1.0,
		slowdownTime = o.slowdownTime or 1.0,
		highTireAdhesion = o.highTireAdhesion == true,
		ignore = o.ignore == true,
		reset = reset,
		fallingEffect = falling,
		surface = o.surface == true,
		belowSurface = o.belowSurface == true,
		collisionDetect = o.collisionDetect == true,
		collisionReaction = o.collisionReaction or ("normal" :: CollisionReaction),
		friction = o.friction or 1.0,
	})
end

local DEFAULT_MATERIAL = makeMaterial("default")

-- Transcribed from stk-assets/tracks/sandtrack/materials.xml:L3-L13 (rev 18627)
local SANDTRACK_ENTRIES: { SurfaceMaterial } = {
	-- <material name="oasis-water.png" shader="displace" ignore="Y"/> (L4)
	makeMaterial("oasis-water.png", { ignore = true }),
	-- <material name="pyramidwall.jpg" high-adhesion="Y"/> (L5)
	makeMaterial("pyramidwall.jpg", { highTireAdhesion = true }),
	-- <material name="road.jpg" normal-map="road_nm.png"/> (L6)
	makeMaterial("road.jpg"),
	-- <material name="sand.png" slowdown-time="1.50" max-speed="0.50" normal-map="sand_nm.png"/> (L7)
	makeMaterial("sand.png", { maxSpeedFraction = 0.50, slowdownTime = 1.50 }),
	-- <material name="seabed.jpg" reset="Y"/> (L8)
	makeMaterial("seabed.jpg", { reset = true }),
	-- <material name="transparence2.png" shader="alphatest" collision-detect="Y" collision-reaction="reset"/> (L9)
	makeMaterial("transparence2.png", { collisionDetect = true, collisionReaction = "reset" }),
	-- <material name="water_light.png" surface="Y" falling-effect="Y" water-splash="Y"> (L10)
	makeMaterial("water_light.png", { surface = true, fallingEffect = true }),
}

local SANDTRACK_TABLE: { [string]: SurfaceMaterial } = {}
for _, mat in SANDTRACK_ENTRIES do
	SANDTRACK_TABLE[string.lower(mat.name)] = mat
end
table.freeze(SANDTRACK_TABLE)

local SurfaceMaterials = {}
SurfaceMaterials.DEFAULT = DEFAULT_MATERIAL
SurfaceMaterials.SANDTRACK = SANDTRACK_TABLE

function SurfaceMaterials.get(name: string?, overrides: { [string]: SurfaceMaterial }?): SurfaceMaterial
	if name == nil or name == "" then
		return DEFAULT_MATERIAL
	end
	local key = string.lower(name)
	if overrides ~= nil then
		local found = overrides[key] or overrides[name]
		if found ~= nil then
			return found
		end
	end
	return SANDTRACK_TABLE[key] or DEFAULT_MATERIAL
end

return table.freeze(SurfaceMaterials)
