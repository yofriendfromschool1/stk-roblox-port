--!strict
-- tests/LobbyState.spec.luau
-- SPDX-License-Identifier: GPL-3.0-or-later

local LobbyState = require("../src/shared/net/LobbyState")

local function assertTrue(cond: boolean, msg: string)
	if not cond then
		error(msg, 2)
	end
end

local tests = {}

table.insert(tests, {
	name = "first player becomes host and host transfers on leave",
	fn = function()
		local lobby = LobbyState.create()
		local p1, a1 = LobbyState.addPlayer(lobby, 101, "Alice")
		local p2, a2 = LobbyState.addPlayer(lobby, 202, "Bob")
		assertTrue(a1 and p1.userId == 101, "first player should be admitted")
		assertTrue(a2 and p2.userId == 202, "second player should be admitted in public lobby")
		assertTrue(lobby.hostUserId == 101, "Alice should be host")

		local newHost = LobbyState.removePlayer(lobby, 101)
		assertTrue(newHost == 202 and lobby.hostUserId == 202, "host should transfer to Bob when Alice leaves")
	end,
})

table.insert(tests, {
	name = "server-side password validation rejects wrong password and omits password from public snapshot",
	fn = function()
		local lobby = LobbyState.create()
		LobbyState.addPlayer(lobby, 101, "Host")
		local okSet = LobbyState.updateSettings(lobby, 101, { password = "secret_kart" })
		assertTrue(okSet, "host should be able to set password")

		local snap = LobbyState.getPublicSnapshot(lobby) :: any
		assertTrue(snap.settings.hasPassword == true, "public snapshot should expose hasPassword")
		assertTrue(
			snap._password == nil and snap.settings.password == nil,
			"password must never leak in public snapshot"
		)

		local guest, admitted = LobbyState.addPlayer(lobby, 202, "Guest")
		assertTrue(not admitted and not guest.admitted, "guest must wait for password before admission")

		local okWrong, errWrong = LobbyState.submitPassword(lobby, 202, "wrong_pw")
		assertTrue(not okWrong and errWrong == "WRONG_PASSWORD", "wrong password must be rejected")
		assertTrue(not guest.admitted, "guest must remain unadmitted after wrong password")

		local okRight, errRight = LobbyState.submitPassword(lobby, 202, "secret_kart")
		assertTrue(okRight and errRight == nil and guest.admitted, "correct password must admit guest")
	end,
})

table.insert(tests, {
	name = "host-only settings, ready gating, lock on start, and return to lobby preserving host & settings",
	fn = function()
		local lobby = LobbyState.create()
		LobbyState.addPlayer(lobby, 101, "Host")
		LobbyState.addPlayer(lobby, 202, "Guest")

		local nonHostOk, nonHostErr = LobbyState.updateSettings(lobby, 202, { laps = 7 })
		assertTrue(not nonHostOk and nonHostErr == "NOT_HOST", "non-host cannot change settings")

		assertTrue(
			LobbyState.updateSettings(lobby, 101, { laps = 4, difficulty = "best", aiCount = 2 }),
			"host update failed"
		)
		assertTrue(LobbyState.setPlayerReady(lobby, 101, true), "host ready failed")
		local canStartBefore, reasonBefore = LobbyState.canStart(lobby, 101)
		assertTrue(not canStartBefore and reasonBefore == "PLAYERS_NOT_READY", "cannot start before all players ready")

		assertTrue(LobbyState.setPlayerReady(lobby, 202, true), "guest ready failed")
		local canStartNow, _ = LobbyState.canStart(lobby, 101)
		assertTrue(canStartNow, "should be ready to start when all admitted players are ready")

		local started, cfg = LobbyState.startRace(lobby, 101)
		assertTrue(started and cfg ~= nil, "host startRace failed")
		assertTrue(lobby.settingsLocked and lobby.phase == "RACING", "settings must lock at race start")
		assertTrue((cfg :: any).laps == 4 and (cfg :: any).difficulty == "best", "startRace config mismatch")

		local lockedEditOk, lockedErr = LobbyState.updateSettings(lobby, 101, { laps = 2 })
		assertTrue(not lockedEditOk and lockedErr == "LOCKED", "settings must stay locked while racing")

		LobbyState.returnToLobby(lobby)
		assertTrue(lobby.phase == "LOBBY" and not lobby.settingsLocked, "returnToLobby should unlock")
		assertTrue(lobby.hostUserId == 101, "returnToLobby must preserve host")
		assertTrue(
			lobby.settings.laps == 4 and lobby.settings.difficulty == "best",
			"returnToLobby must preserve settings"
		)
		for _, p in ipairs(lobby.players) do
			assertTrue(not p.ready, "returnToLobby should reset ready flags")
		end
	end,
})

return tests
