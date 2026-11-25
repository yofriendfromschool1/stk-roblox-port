--!strict
-- src/server/Main.server.lua
-- SPDX-License-Identifier: GPL-3.0-or-later

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Hello = require(ReplicatedStorage.Shared.Hello)
local GreyboxKartServer = require(script.Parent.GreyboxKartServer)

print("[OpenKart]", Hello.greeting)
GreyboxKartServer.start()
