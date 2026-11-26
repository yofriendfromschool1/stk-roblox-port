--!strict
-- src/client/menu/LobbyPanel.lua
-- SPDX-License-Identifier: GPL-3.0-or-later
-- STK classic-skin online lobby UI (create_server.stkgui + networking_lobby.stkgui).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ClassicSkin = require("./ClassicSkin")
local LobbyState = require(Shared.net.LobbyState)
local MenuFlow = require(Shared.menu.MenuFlow)
local MenuIcons = require(Shared.menu.MenuIcons)

local LobbyPanel = {}

local function fireLobby(cmd: string, payload: any?)
	local remotes = ReplicatedStorage:FindFirstChild("OpenKartRemotes")
	local ev = if remotes then remotes:FindFirstChild("LobbyCommand") else nil
	if ev and ev:IsA("RemoteEvent") then
		ev:FireServer(cmd, payload)
	end
end

local function makeRowLabel(parent: Instance, text: string, x: number, y: number, w: number): TextLabel
	local lbl = Instance.new("TextLabel")
	lbl.BackgroundTransparency = 1
	lbl.Position = UDim2.fromOffset(x, y)
	lbl.Size = UDim2.fromOffset(w, 28)
	lbl.Font = ClassicSkin.FONT_BODY
	lbl.TextSize = 15
	lbl.TextColor3 = ClassicSkin.COLOR_TEXT_NEUTRAL
	lbl.TextXAlignment = Enum.TextXAlignment.Left
	lbl.Text = text
	lbl.ZIndex = 12
	lbl.Parent = parent
	return lbl
end

local function makeValueBox(parent: Instance, name: string, x: number, y: number, w: number): TextLabel
	local lbl = Instance.new("TextLabel")
	lbl.Name = name
	lbl.BackgroundColor3 = Color3.fromRGB(240, 244, 250)
	lbl.BackgroundTransparency = 0.15
	lbl.BorderSizePixel = 1
	lbl.BorderColor3 = Color3.fromRGB(90, 100, 120)
	lbl.Position = UDim2.fromOffset(x, y)
	lbl.Size = UDim2.fromOffset(w, 28)
	lbl.Font = ClassicSkin.FONT_BODY
	lbl.TextSize = 15
	lbl.TextColor3 = ClassicSkin.COLOR_TEXT_NEUTRAL
	lbl.Text = ""
	lbl.ZIndex = 12
	lbl.Parent = parent
	return lbl
end

function LobbyPanel.build(
	parent: Frame,
	trackConn: (RBXScriptConnection) -> (),
	onBack: () -> ()
): { refresh: () -> () }
	local localPlayer = Players.LocalPlayer
	local myUserId = if localPlayer then localPlayer.UserId else 0
	if myUserId == 0 and localPlayer then
		myUserId = 1
	end

	local backBtn = Instance.new("ImageButton")
	backBtn.Name = "LobbyBackBtn"
	backBtn.BackgroundTransparency = 1
	backBtn.BorderSizePixel = 0
	backBtn.Position = UDim2.fromScale(0.01, 0.005)
	backBtn.Size = UDim2.fromOffset(56, 56)
	backBtn.Image = MenuIcons.Back
	backBtn.ScaleType = Enum.ScaleType.Fit
	backBtn.ZIndex = 14
	backBtn.Parent = parent
	trackConn(backBtn.Activated:Connect(function()
		fireLobby("LEAVE_LOBBY")
		onBack()
	end))

	local headerLbl = Instance.new("TextLabel")
	headerLbl.Name = "LobbyHeader"
	headerLbl.BackgroundTransparency = 1
	headerLbl.Position = UDim2.fromScale(0.1, 0.005)
	headerLbl.Size = UDim2.fromScale(0.8, 0.085)
	headerLbl.Font = Enum.Font.FredokaOne
	headerLbl.TextScaled = true
	headerLbl.Text = "Online Lobby"
	headerLbl.ZIndex = 12
	headerLbl.Parent = parent
	ClassicSkin.applyHeaderGradient(headerLbl)

	local statusBanner = Instance.new("TextLabel")
	statusBanner.Name = "LobbyStatusLbl"
	statusBanner.BackgroundTransparency = 1
	statusBanner.Position = UDim2.fromScale(0.04, 0.095)
	statusBanner.Size = UDim2.fromScale(0.92, 0.045)
	statusBanner.Font = ClassicSkin.FONT_BODY
	statusBanner.TextSize = 16
	statusBanner.TextColor3 = ClassicSkin.COLOR_TEXT_FOCUSED
	statusBanner.TextStrokeTransparency = 0.35
	statusBanner.Text = "Connecting to lobby..."
	statusBanner.ZIndex = 12
	statusBanner.Parent = parent

	local settingsBox = ClassicSkin.makeGlassBox(
		parent,
		"LobbySettingsBox",
		UDim2.fromScale(0.03, 0.145),
		UDim2.fromScale(0.51, 0.81),
		10
	)
	local rosterBox = ClassicSkin.makeGlassBox(
		parent,
		"LobbyRosterBox",
		UDim2.fromScale(0.56, 0.145),
		UDim2.fromScale(0.41, 0.81),
		10
	)

	-- Settings controls (Left box)
	makeRowLabel(settingsBox, "Track:", 16, 14, 110)
	local trackValLbl = makeValueBox(settingsBox, "LobbyTrackVal", 130, 14, 240)
	trackValLbl.Text = "Shifting Sands (sandtrack)"

	makeRowLabel(settingsBox, "Mode:", 16, 52, 110)
	local modeNormalBtn = ClassicSkin.makeGlassButton(
		settingsBox,
		"LobbyModeNormalBtn",
		"Normal Race",
		UDim2.fromOffset(130, 50),
		UDim2.fromOffset(122, 32),
		trackConn
	)
	local modeTtBtn = ClassicSkin.makeGlassButton(
		settingsBox,
		"LobbyModeTTBtn",
		"Time Trial",
		UDim2.fromOffset(260, 50),
		UDim2.fromOffset(110, 32),
		trackConn
	)

	makeRowLabel(settingsBox, "Difficulty:", 16, 94, 110)
	local diffDefs: { { id: MenuFlow.Difficulty, label: string } } = {
		{ id = "novice", label = "Novice" },
		{ id = "intermediate", label = "Interm." },
		{ id = "expert", label = "Expert" },
		{ id = "best", label = "SuperTux" },
	}
	local diffBtns: { [string]: TextButton } = {}
	for i, d in ipairs(diffDefs) do
		local btn = ClassicSkin.makeGlassButton(
			settingsBox,
			"LobbyDiff_" .. d.id,
			d.label,
			UDim2.fromOffset(130 + (i - 1) * 76, 92),
			UDim2.fromOffset(72, 32),
			trackConn
		)
		diffBtns[d.id] = btn
	end

	makeRowLabel(settingsBox, "Laps:", 16, 138, 110)
	local lapsMinusBtn = ClassicSkin.makeGlassButton(
		settingsBox,
		"LobbyLapsMinus",
		"-",
		UDim2.fromOffset(130, 136),
		UDim2.fromOffset(36, 30),
		trackConn
	)
	local lapsValLbl = makeValueBox(settingsBox, "LobbyLapsVal", 172, 137, 64)
	local lapsPlusBtn = ClassicSkin.makeGlassButton(
		settingsBox,
		"LobbyLapsPlus",
		"+",
		UDim2.fromOffset(242, 136),
		UDim2.fromOffset(36, 30),
		trackConn
	)

	makeRowLabel(settingsBox, "Max Players:", 16, 178, 110)
	local maxMinusBtn = ClassicSkin.makeGlassButton(
		settingsBox,
		"LobbyMaxMinus",
		"-",
		UDim2.fromOffset(130, 176),
		UDim2.fromOffset(36, 30),
		trackConn
	)
	local maxValLbl = makeValueBox(settingsBox, "LobbyMaxVal", 172, 177, 64)
	local maxPlusBtn = ClassicSkin.makeGlassButton(
		settingsBox,
		"LobbyMaxPlus",
		"+",
		UDim2.fromOffset(242, 176),
		UDim2.fromOffset(36, 30),
		trackConn
	)

	makeRowLabel(settingsBox, "AI Karts:", 16, 218, 110)
	local aiMinusBtn = ClassicSkin.makeGlassButton(
		settingsBox,
		"LobbyAiMinus",
		"-",
		UDim2.fromOffset(130, 216),
		UDim2.fromOffset(36, 30),
		trackConn
	)
	local aiValLbl = makeValueBox(settingsBox, "LobbyAiVal", 172, 217, 64)
	local aiPlusBtn = ClassicSkin.makeGlassButton(
		settingsBox,
		"LobbyAiPlus",
		"+",
		UDim2.fromOffset(242, 216),
		UDim2.fromOffset(36, 30),
		trackConn
	)

	makeRowLabel(settingsBox, "Password:", 16, 260, 110)
	local hostPwBox = Instance.new("TextBox")
	hostPwBox.Name = "HostPasswordBox"
	hostPwBox.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	hostPwBox.BorderColor3 = Color3.fromRGB(90, 100, 120)
	hostPwBox.Position = UDim2.fromOffset(130, 258)
	hostPwBox.Size = UDim2.fromOffset(148, 30)
	hostPwBox.Font = ClassicSkin.FONT_BODY
	hostPwBox.TextSize = 14
	hostPwBox.TextColor3 = ClassicSkin.COLOR_TEXT_NEUTRAL
	hostPwBox.PlaceholderText = "(optional)"
	hostPwBox.ClearTextOnFocus = false
	hostPwBox.Text = ""
	hostPwBox.ZIndex = 12
	hostPwBox.Parent = settingsBox

	local applyPwBtn = ClassicSkin.makeGlassButton(
		settingsBox,
		"ApplyPasswordBtn",
		"Set PW",
		UDim2.fromOffset(284, 257),
		UDim2.fromOffset(72, 32),
		trackConn
	)
	local clearPwBtn = ClassicSkin.makeGlassButton(
		settingsBox,
		"ClearPasswordBtn",
		"Clear",
		UDim2.fromOffset(362, 257),
		UDim2.fromOffset(64, 32),
		trackConn
	)

	local reservedBtn = ClassicSkin.makeGlassButton(
		settingsBox,
		"CreateReservedBtn",
		"Publish Reserved Lobby",
		UDim2.fromOffset(16, 312),
		UDim2.fromOffset(200, 34),
		trackConn
	)
	local reservedLbl = makeRowLabel(settingsBox, "In-server lobby active", 224, 314, 230)
	reservedLbl.Name = "ReservedStatusLbl"
	reservedLbl.TextColor3 = ClassicSkin.COLOR_TEXT_CREDITS
	reservedLbl.TextSize = 13

	-- Roster & Ready/Start (Right box)
	local rosterTitle = makeRowLabel(rosterBox, "Players in Lobby:", 16, 12, 240)
	rosterTitle.TextSize = 17

	local rosterList = Instance.new("Frame")
	rosterList.Name = "LobbyRosterList"
	rosterList.BackgroundColor3 = Color3.fromRGB(235, 240, 248)
	rosterList.BackgroundTransparency = 0.25
	rosterList.BorderColor3 = Color3.fromRGB(110, 120, 140)
	rosterList.Position = UDim2.fromOffset(16, 44)
	rosterList.Size = UDim2.new(1, -32, 0, 210)
	rosterList.ZIndex = 12
	rosterList.Parent = rosterBox

	local rosterLayout = Instance.new("UIListLayout")
	rosterLayout.Padding = UDim.new(0, 4)
	rosterLayout.SortOrder = Enum.SortOrder.LayoutOrder
	rosterLayout.Parent = rosterList

	local kartLbl = makeRowLabel(rosterBox, "Selected Kart: Tux", 16, 266, 200)
	kartLbl.Name = "LobbyKartLbl"

	local readyBtn = ClassicSkin.makeGlassButton(
		rosterBox,
		"LobbyReadyBtn",
		"Ready",
		UDim2.fromOffset(16, 304),
		UDim2.fromOffset(150, 40),
		trackConn
	)
	local startBtn = ClassicSkin.makeGlassButton(
		rosterBox,
		"LobbyStartBtn",
		"Start Race",
		UDim2.fromOffset(178, 304),
		UDim2.fromOffset(170, 40),
		trackConn
	)

	-- Password Gate Overlay (for non-host clients when hasPassword == true and not yet admitted)
	local pwGate = ClassicSkin.makeGlassBox(
		parent,
		"LobbyPasswordGate",
		UDim2.fromScale(0.28, 0.30),
		UDim2.fromScale(0.44, 0.36),
		20
	)
	pwGate.Visible = false

	local pwGateTitle = makeRowLabel(pwGate, "Private Lobby — Enter Password", 24, 22, 340)
	pwGateTitle.TextSize = 18
	pwGateTitle.ZIndex = 21

	local pwInput = Instance.new("TextBox")
	pwInput.Name = "PasswordInput"
	pwInput.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	pwInput.BorderColor3 = Color3.fromRGB(80, 90, 110)
	pwInput.Position = UDim2.fromOffset(24, 68)
	pwInput.Size = UDim2.new(1, -48, 0, 36)
	pwInput.Font = ClassicSkin.FONT_BODY
	pwInput.TextSize = 16
	pwInput.TextColor3 = ClassicSkin.COLOR_TEXT_NEUTRAL
	pwInput.PlaceholderText = "Server password..."
	pwInput.ClearTextOnFocus = false
	pwInput.Text = ""
	pwInput.ZIndex = 21
	pwInput.Parent = pwGate

	local pwSubmitBtn = ClassicSkin.makeGlassButton(
		pwGate,
		"SubmitPasswordBtn",
		"Join Lobby",
		UDim2.fromOffset(24, 120),
		UDim2.fromOffset(150, 36),
		trackConn
	)
	pwSubmitBtn.ZIndex = 21

	local pwErrLbl = makeRowLabel(pwGate, "", 24, 168, 360)
	pwErrLbl.Name = "PasswordErrorLbl"
	pwErrLbl.TextColor3 = Color3.fromRGB(190, 30, 30)
	pwErrLbl.ZIndex = 21

	local latestSnap: LobbyState.PublicLobbySnapshot? = nil

	local function isHostAndUnlocked(): boolean
		if latestSnap == nil then
			return false
		end
		return latestSnap.hostUserId == myUserId and not latestSnap.settingsLocked and latestSnap.phase == "LOBBY"
	end

	local function renderSnap()
		local snap = latestSnap
		if snap == nil then
			statusBanner.Text = "Connecting to server lobby..."
			pwGate.Visible = false
			return
		end

		local s = snap.settings
		local hostName = "None"
		local me: LobbyState.LobbyPlayer? = nil
		local allReady = true
		local admittedCount = 0
		for _, p in ipairs(snap.players) do
			if p.userId == snap.hostUserId then
				hostName = p.name
			end
			if p.userId == myUserId then
				me = p
			end
			if p.admitted then
				admittedCount += 1
				if not p.ready then
					allReady = false
				end
			end
		end

		local lockTag = if snap.settingsLocked then "LOCKED (Racing)" else "Open"
		local pwTag = if s.hasPassword then "Private (Password)" else "Public"
		statusBanner.Text = string.format(
			"%s  |  Host: %s  |  %s  |  %s  |  %d/%d Players",
			s.serverName,
			hostName,
			lockTag,
			pwTag,
			admittedCount,
			s.maxPlayers
		)

		local needsPw = (me ~= nil and not me.admitted and s.hasPassword)
		pwGate.Visible = needsPw
		settingsBox.Visible = not needsPw
		rosterBox.Visible = not needsPw

		ClassicSkin.setButtonSelected(modeNormalBtn, s.raceType == "NORMAL_RACE")
		ClassicSkin.setButtonSelected(modeTtBtn, s.raceType == "TIME_TRIAL")
		for diffId, btn in pairs(diffBtns) do
			ClassicSkin.setButtonSelected(btn, s.difficulty == diffId)
		end

		lapsValLbl.Text = tostring(s.laps)
		maxValLbl.Text = tostring(s.maxPlayers)
		aiValLbl.Text = tostring(s.aiCount)

		local hostEdit = isHostAndUnlocked()
		hostPwBox.TextEditable = hostEdit
		applyPwBtn.Visible = hostEdit
		clearPwBtn.Visible = hostEdit

		for _, child in ipairs(rosterList:GetChildren()) do
			if child:IsA("TextLabel") then
				child:Destroy()
			end
		end
		for idx, p in ipairs(snap.players) do
			local row = Instance.new("TextLabel")
			row.Name = "PlayerRow_" .. tostring(p.userId)
			row.LayoutOrder = idx
			row.Size = UDim2.new(1, -8, 0, 28)
			row.BackgroundTransparency = 0.35
			row.BackgroundColor3 = if p.userId == snap.hostUserId
				then Color3.fromRGB(255, 240, 200)
				else Color3.fromRGB(255, 255, 255)
			row.BorderSizePixel = 0
			row.Font = ClassicSkin.FONT_BODY
			row.TextSize = 14
			row.TextXAlignment = Enum.TextXAlignment.Left
			row.TextColor3 = ClassicSkin.COLOR_TEXT_NEUTRAL
			local role = if p.userId == snap.hostUserId then "[HOST] " else ""
			local readyTxt = if not p.admitted then "[PW PENDING]" elseif p.ready then "[READY]" else "[WAITING]"
			row.Text = string.format("  %s%s  (%s)  %s", role, p.name, p.kartId, readyTxt)
			row.ZIndex = 13
			row.Parent = rosterList
		end

		local amReady = me ~= nil and me.ready
		ClassicSkin.setButtonText(readyBtn, if amReady then "Ready (On)" else "Ready")
		ClassicSkin.setButtonSelected(readyBtn, amReady)

		local isHost = (snap.hostUserId == myUserId)
		startBtn.Visible = isHost
		if isHost then
			local readyToStart = admittedCount > 0 and allReady and not snap.settingsLocked
			ClassicSkin.setButtonText(startBtn, if readyToStart then "Start Race" else "Wait Ready...")
			ClassicSkin.setButtonSelected(startBtn, readyToStart)
		end
	end

	trackConn(modeNormalBtn.Activated:Connect(function()
		if isHostAndUnlocked() then
			fireLobby("UPDATE_SETTINGS", { raceType = "NORMAL_RACE" })
		end
	end))
	trackConn(modeTtBtn.Activated:Connect(function()
		if isHostAndUnlocked() then
			fireLobby("UPDATE_SETTINGS", { raceType = "TIME_TRIAL" })
		end
	end))
	for diffId, btn in pairs(diffBtns) do
		trackConn(btn.Activated:Connect(function()
			if isHostAndUnlocked() then
				fireLobby("UPDATE_SETTINGS", { difficulty = diffId })
			end
		end))
	end
	trackConn(lapsMinusBtn.Activated:Connect(function()
		if isHostAndUnlocked() and latestSnap then
			fireLobby("UPDATE_SETTINGS", { laps = latestSnap.settings.laps - 1 })
		end
	end))
	trackConn(lapsPlusBtn.Activated:Connect(function()
		if isHostAndUnlocked() and latestSnap then
			fireLobby("UPDATE_SETTINGS", { laps = latestSnap.settings.laps + 1 })
		end
	end))
	trackConn(maxMinusBtn.Activated:Connect(function()
		if isHostAndUnlocked() and latestSnap then
			fireLobby("UPDATE_SETTINGS", { maxPlayers = latestSnap.settings.maxPlayers - 1 })
		end
	end))
	trackConn(maxPlusBtn.Activated:Connect(function()
		if isHostAndUnlocked() and latestSnap then
			fireLobby("UPDATE_SETTINGS", { maxPlayers = latestSnap.settings.maxPlayers + 1 })
		end
	end))
	trackConn(aiMinusBtn.Activated:Connect(function()
		if isHostAndUnlocked() and latestSnap then
			fireLobby("UPDATE_SETTINGS", { aiCount = latestSnap.settings.aiCount - 1 })
		end
	end))
	trackConn(aiPlusBtn.Activated:Connect(function()
		if isHostAndUnlocked() and latestSnap then
			fireLobby("UPDATE_SETTINGS", { aiCount = latestSnap.settings.aiCount + 1 })
		end
	end))
	trackConn(applyPwBtn.Activated:Connect(function()
		if isHostAndUnlocked() then
			fireLobby("UPDATE_SETTINGS", { password = hostPwBox.Text })
		end
	end))
	trackConn(clearPwBtn.Activated:Connect(function()
		if isHostAndUnlocked() then
			hostPwBox.Text = ""
			fireLobby("UPDATE_SETTINGS", { password = "" })
		end
	end))
	trackConn(readyBtn.Activated:Connect(function()
		if latestSnap == nil or latestSnap.settingsLocked then
			return
		end
		local amReady = false
		for _, p in ipairs(latestSnap.players) do
			if p.userId == myUserId then
				amReady = p.ready
				break
			end
		end
		fireLobby("SET_READY", { ready = not amReady })
	end))
	trackConn(startBtn.Activated:Connect(function()
		if isHostAndUnlocked() then
			fireLobby("START_LOBBY_RACE")
		end
	end))
	trackConn(pwSubmitBtn.Activated:Connect(function()
		fireLobby("SUBMIT_PASSWORD", { password = pwInput.Text })
	end))
	trackConn(reservedBtn.Activated:Connect(function()
		fireLobby("CREATE_RESERVED_SERVER")
	end))

	task.spawn(function()
		local remotes = ReplicatedStorage:WaitForChild("OpenKartRemotes", 10)
		if not remotes then
			return
		end
		local lobbyEv = remotes:WaitForChild("LobbyState", 10)
		if lobbyEv and lobbyEv:IsA("RemoteEvent") then
			trackConn(lobbyEv.OnClientEvent:Connect(function(msg: any)
				if type(msg) ~= "table" then
					return
				end
				if msg.type == "SNAPSHOT" and type(msg.snapshot) == "table" then
					latestSnap = msg.snapshot :: LobbyState.PublicLobbySnapshot
					renderSnap()
				elseif msg.type == "PASSWORD_RESULT" then
					if msg.ok then
						pwErrLbl.Text = ""
					else
						pwErrLbl.Text = "Rejected: " .. tostring(msg.reason or "WRONG_PASSWORD")
					end
				elseif msg.type == "RESERVED_RESULT" then
					if msg.ok and type(msg.entry) == "table" then
						reservedLbl.Text = "Reserved: " .. tostring(msg.entry.lobbyId)
					else
						reservedLbl.Text = "Reserved: " .. tostring(msg.reason or "UNAVAILABLE")
					end
				end
			end))
			fireLobby("REQUEST_LOBBY_STATE")
		end
	end)

	renderSnap()
	return { refresh = renderSnap }
end

return LobbyPanel
