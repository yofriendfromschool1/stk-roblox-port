--!strict
-- tests/MenuFlow.spec.luau
-- SPDX-License-Identifier: GPL-3.0-or-later

local CatalogData = require("../src/shared/menu/CatalogData")
local MenuFlow = require("../src/shared/menu/MenuFlow")

local function assertTrue(cond: boolean, msg: string)
	if not cond then
		error(msg, 2)
	end
end

local function assertEqual(actual: any, expected: any, msg: string)
	if actual ~= expected then
		error(string.format("%s: expected %s, got %s", msg, tostring(expected), tostring(actual)), 2)
	end
end

return {
	{
		name = "catalog contains playable sandtrack and all 18 official karts",
		fn = function()
			assertEqual(#CatalogData.tracks, 1, "track count")
			assertEqual(CatalogData.tracks[1].id, "sandtrack", "only sandtrack")
			assertTrue(CatalogData.tracks[1].playable, "sandtrack playable")
			assertEqual(#CatalogData.karts, 18, "kart count")
			local byId: { [string]: boolean } = {}
			for _, k in ipairs(CatalogData.karts) do
				assertTrue(k.playable, "kart playable: " .. k.id)
				byId[k.id] = true
			end
			assertTrue(byId["tux"] == true, "tux present")
			assertTrue(byId["hexley"] == true, "hexley present")
			assertTrue(byId["pidgin"] == true, "pidgin present")
		end,
	},
	{
		name = "full menu -> mode -> track -> kart -> config -> loading -> racing -> menu flow",
		fn = function()
			local st = MenuFlow.create()
			assertEqual(st.screen, "MENU", "initial screen")
			MenuFlow.selectPlayMode(st, "SINGLEPLAYER")
			assertEqual(st.screen, "MODE", "after playMode")
			MenuFlow.selectRaceType(st, "NORMAL_RACE")
			assertEqual(st.screen, "TRACK", "after raceType")
			assertTrue(MenuFlow.selectTrack(st, "sandtrack"), "select sandtrack")
			assertEqual(st.screen, "KART", "after track")
			assertTrue(MenuFlow.selectKart(st, "tux"), "select tux")
			assertEqual(st.screen, "CONFIG", "after kart")
			MenuFlow.setConfig(st, { difficulty = "expert", laps = 7, aiCount = 5 })
			assertEqual(st.config.difficulty, "expert", "difficulty")
			assertEqual(st.config.laps, 7, "laps")
			assertEqual(st.config.aiCount, 5, "aiCount")
			MenuFlow.startRace(st)
			assertEqual(st.screen, "LOADING", "after startRace")
			MenuFlow.onRaceLoaded(st)
			assertEqual(st.screen, "RACING", "after onRaceLoaded")
			MenuFlow.returnToMenu(st)
			assertEqual(st.screen, "MENU", "after returnToMenu")
		end,
	},
	{
		name = "back navigation and options/about return properly",
		fn = function()
			local st = MenuFlow.create()
			MenuFlow.selectPlayMode(st, "ONLINE")
			MenuFlow.selectRaceType(st, "NORMAL_RACE")
			MenuFlow.openOptions(st)
			assertEqual(st.screen, "OPTIONS", "openOptions")
			MenuFlow.back(st)
			assertEqual(st.screen, "TRACK", "back from options returns to TRACK")
			MenuFlow.openAbout(st)
			assertEqual(st.screen, "ABOUT", "openAbout")
			MenuFlow.back(st)
			assertEqual(st.screen, "TRACK", "back from about returns to TRACK")
			MenuFlow.back(st)
			assertEqual(st.screen, "MODE", "back to MODE")
			MenuFlow.back(st)
			assertEqual(st.screen, "MENU", "back to MENU")
		end,
	},
	{
		name = "sanitizeSessionConfig rejects invalid track/kart and clamps laps & time trial AI",
		fn = function()
			assertTrue(not MenuFlow.selectTrack(MenuFlow.create(), "openkart_arena"), "reject arena")
			assertTrue(not MenuFlow.selectKart(MenuFlow.create(), "nonexistent"), "reject unknown kart")
			local sanitized = MenuFlow.sanitizeSessionConfig({
				playMode = "BOGUS",
				raceType = "TIME_TRIAL",
				trackId = "openkart_arena",
				kartId = "badkart",
				difficulty = "godmode",
				laps = 99,
				aiCount = 8,
			})
			assertEqual(sanitized.playMode, "SINGLEPLAYER", "fallback playMode")
			assertEqual(sanitized.raceType, "TIME_TRIAL", "raceType")
			assertEqual(sanitized.trackId, "sandtrack", "fallback track")
			assertEqual(sanitized.kartId, "tux", "fallback kart")
			assertEqual(sanitized.difficulty, "intermediate", "fallback difficulty")
			assertEqual(sanitized.laps, 20, "clamped laps")
			assertEqual(sanitized.aiCount, 0, "time trial forces 0 AI")
		end,
	},
}
