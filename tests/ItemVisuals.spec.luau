--!strict
-- tests/ItemVisuals.spec.luau
-- SPDX-License-Identifier: GPL-3.0-or-later
-- Permanent build assertion: no item MeshPart may exist with empty TextureID and no SurfaceAppearance ColorMap
-- (outside the documented unverified-texture exclusions in assets/CREDITS.md), and all item spawn paths
-- must route through ItemVisuals.create without direct Instance.new("MeshPart").

local fs = require("@lune/fs")

-- Explicitly excluded in assets/CREDITS.md:L26 due to missing/typoed upstream licenses.txt entries:
local UNVERIFIED_TEXTURE_ALLOWLIST: { [string]: boolean } = {
	["parachute.rbxmx"] = true,
	["plunger.rbxmx"] = true,
	["rubber_ball.rbxmx"] = true,
}

local tests = {}

table.insert(tests, {
	name = "PERMANENT: all verified item .rbxmx MeshParts have TextureID or SurfaceAppearance ColorMap",
	fn = function()
		local dir = "assets/roblox/items"
		for _, entry in fs.readDir(dir) do
			if string.sub(entry, -6) == ".rbxmx" and not UNVERIFIED_TEXTURE_ALLOWLIST[entry] then
				local content = fs.readFile(dir .. "/" .. entry)
				local hasTex = string.find(content, '<Content name="TextureID"><url>rbxassetid://', 1, true) ~= nil
				local hasSa = string.find(content, '<Item class="SurfaceAppearance"', 1, true) ~= nil
					and string.find(content, '<Content name="ColorMap"><url>rbxassetid://', 1, true) ~= nil
				if not (hasTex or hasSa) then
					error(
						string.format(
							"Untextured item MeshPart in %s/%s (missing TextureID and SurfaceAppearance ColorMap)",
							dir,
							entry
						)
					)
				end
			end
		end
	end,
})

table.insert(tests, {
	name = "PERMANENT: no direct Instance.new('MeshPart') in item/flyable/kart presentation paths",
	fn = function()
		local files = {
			"src/client/items/ItemPresentation.lua",
			"src/client/items/FlyablePresentation.lua",
			"src/client/kart/KartPresentation.lua",
		}
		for _, fp in files do
			local content = fs.readFile(fp)
			if string.find(content, 'Instance.new("MeshPart")', 1, true) ~= nil then
				error(
					string.format(
						"Forbidden direct Instance.new('MeshPart') in %s; route through ItemVisuals.create",
						fp
					)
				)
			end
		end
	end,
})

return tests
