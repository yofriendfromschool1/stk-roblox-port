--!strict
-- tests/ItemVisuals.spec.luau
-- SPDX-License-Identifier: GPL-3.0-or-later
-- Permanent build assertion: no item MeshPart may exist with empty TextureID and no SurfaceAppearance ColorMap,
-- and all item spawn paths must route through ItemVisuals.create without direct Instance.new("MeshPart").

local fs = require("@lune/fs")

local tests = {}

table.insert(tests, {
	name = "PERMANENT: all item .rbxmx MeshParts have TextureID or SurfaceAppearance ColorMap",
	fn = function()
		local dir = "assets/roblox/items"
		for _, entry in fs.readDir(dir) do
			if string.sub(entry, -6) == ".rbxmx" then
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
