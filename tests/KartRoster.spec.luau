--!strict
-- tests/KartRoster.spec.luau
-- SPDX-License-Identifier: GPL-3.0-or-later

local fs = require("@lune/fs")

local CatalogData = require("../src/shared/menu/CatalogData")
local FixedStep = require("../src/shared/sim/FixedStep")
local KartSelectMath = require("../src/shared/menu/KartSelectMath")
local KartSolver = require("../src/shared/sim/KartSolver")
local KartTuning = require("../src/shared/KartTuning")
local Math3D = require("../src/shared/sim/Math3D")

type Vec3 = Math3D.Vec3
type RayHit = KartSolver.RayHit
type WorldQuery = KartSolver.WorldQuery
type KartInput = KartSolver.KartInput

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

local function assertNear(actual: number, expected: number, eps: number, msg: string)
	if actual ~= actual or math.abs(actual - expected) > eps then
		error(string.format("%s: expected %s (+/-%g), got %s", msg, tostring(expected), eps, tostring(actual)), 2)
	end
end

local function makeFlatPlaneWorld(groundY: number): WorldQuery
	return {
		raycast = function(origin: Vec3, dir: Vec3, length: number): RayHit?
			if math.abs(dir.y) < 1e-9 then
				return nil
			end
			local t = (groundY - origin.y) / dir.y
			if t >= 0 and t <= length then
				return {
					distance = t,
					point = {
						x = origin.x + dir.x * t,
						y = groundY,
						z = origin.z + dir.z * t,
					},
					normal = { x = 0, y = 1, z = 0 },
				}
			end
			return nil
		end,
	}
end

local EXPECTED_BY_CLASS: {
	[string]: {
		massKg: number,
		maxSpeedMps: number,
		enginePowerN: number,
		accelEff: number,
		nitroConsumption: number,
		massBar: number,
		speedBar: number,
		accelBar: number,
		nitroBar: number,
	},
} =
	{
		light = {
			massKg = 210.0,
			maxSpeedMps = 23.75,
			enginePowerN = 760.0,
			accelEff = 9.904,
			nitroConsumption = 1.0,
			massBar = 53.98,
			speedBar = 56.25,
			accelBar = 99.04,
			nitroBar = 90.00,
		},
		medium = {
			massKg = 262.5,
			maxSpeedMps = 25.00,
			enginePowerN = 831.25,
			accelEff = 7.444,
			nitroConsumption = 1.25,
			massBar = 67.48,
			speedBar = 75.00,
			accelBar = 74.44,
			nitroBar = 72.00,
		},
		heavy = {
			massKg = 350.0,
			maxSpeedMps = 26.25,
			enginePowerN = 950.0,
			accelEff = 5.333,
			nitroConsumption = 1.67,
			massBar = 89.97,
			speedBar = 93.75,
			accelBar = 53.33,
			nitroBar = 53.89,
		},
	}

return {
	{
		name = "all 18 karts match upstream class physics and KartStatsWidget normalization",
		fn = function()
			assertEqual(#KartTuning.KART_ORDER, 18, "KART_ORDER count")
			assertEqual(#CatalogData.karts, 18, "CatalogData.karts count")

			local catalogById: { [string]: CatalogData.KartCatalogEntry } = {}
			for _, k in ipairs(CatalogData.karts) do
				catalogById[k.id] = k
			end

			for _, kartId in ipairs(KartTuning.KART_ORDER) do
				local spec = KartTuning.getKartSpec(kartId)
				local cat = catalogById[kartId]
				assertTrue(cat ~= nil, "catalog entry exists for " .. kartId)
				assertEqual(cat.kartType, spec.className, "className matches catalog for " .. kartId)
				assertTrue(cat.playable, "playable for " .. kartId)
				assertTrue(type(cat.iconId) == "string" and #cat.iconId > 0, "iconId present for " .. kartId)

				local exp = EXPECTED_BY_CLASS[spec.className]
				assertTrue(exp ~= nil, "expected class stats for " .. spec.className)

				local stats = KartTuning.computeKartStatBars(kartId)
				assertNear(stats.massKg, exp.massKg, 0.01, kartId .. " massKg")
				assertNear(stats.maxSpeedMps, exp.maxSpeedMps, 0.01, kartId .. " maxSpeedMps")
				assertNear(stats.enginePowerN, exp.enginePowerN, 0.01, kartId .. " enginePowerN")
				assertNear(stats.accelEff, exp.accelEff, 0.05, kartId .. " accelEff")
				assertNear(stats.nitroConsumption, exp.nitroConsumption, 0.001, kartId .. " nitroConsumption")
				assertNear(stats.massBar, exp.massBar, 0.02, kartId .. " massBar")
				assertNear(stats.speedBar, exp.speedBar, 0.02, kartId .. " speedBar")
				assertNear(stats.accelBar, exp.accelBar, 0.05, kartId .. " accelBar")
				assertNear(stats.nitroBar, exp.nitroBar, 0.02, kartId .. " nitroBar")
			end
		end,
	},
	{
		name = "KartSelectMath filters by class and search, steps filter, and picks deterministic random kart",
		fn = function()
			assertEqual(#KartSelectMath.filterKarts(CatalogData.karts, "all", ""), 18, "all count")
			assertEqual(#KartSelectMath.filterKarts(CatalogData.karts, "light", ""), 4, "light count")
			assertEqual(#KartSelectMath.filterKarts(CatalogData.karts, "medium", ""), 10, "medium count")
			assertEqual(#KartSelectMath.filterKarts(CatalogData.karts, "heavy", ""), 4, "heavy count")

			local pidFilter = KartSelectMath.filterKarts(CatalogData.karts, "all", "pid")
			assertEqual(#pidFilter, 1, "search 'pid' count")
			assertEqual(pidFilter[1].id, "pidgin", "search 'pid' result")

			assertEqual(KartSelectMath.stepClassFilter("all", 1), "light", "step +1 from all")
			assertEqual(KartSelectMath.stepClassFilter("all", -1), "heavy", "step -1 from all")
			assertEqual(KartSelectMath.stepClassFilter("heavy", 1), "all", "wrap +1 from heavy")

			local r1 = KartSelectMath.pickRandomKartId(CatalogData.karts, 42)
			local r2 = KartSelectMath.pickRandomKartId(CatalogData.karts, 42)
			assertEqual(r1, r2, "deterministic random pick")
			assertTrue(r1 ~= nil, "non-nil random pick")
		end,
	},
	{
		name = "Light (hexley), Medium (tux), and Heavy (pidgin) drive with distinct acceleration and max speed",
		fn = function()
			local world = makeFlatPlaneWorld(0)
			local dt = FixedStep.FIXED_DT
			local throttleInput: KartInput = {
				accel = 1,
				brake = 0,
				steer = 0,
				drift = false,
				skidControl = 0,
				nitro = false,
				fire = false,
				rescue = false,
			}

			local function runKart(kartId: string): (number, number, number)
				local prof = KartTuning.buildProfileForKart(kartId, "best")
				local st = KartSolver.createState(prof, { x = 0, y = 0.291, z = 0 }, 0)
				local earlySpeed = 0
				for tick = 1, 1200 do
					KartSolver.step(st, throttleInput, world, dt)
					if tick == 60 then
						earlySpeed = st.speed
					end
				end
				return earlySpeed, st.speed, st.maxSpeedState.currentMaxSpeed
			end

			local lightEarly, lightTop, lightCap = runKart("hexley")
			local medEarly, medTop, medCap = runKart("tux")
			local heavyEarly, heavyTop, heavyCap = runKart("pidgin")

			assertTrue(lightEarly > medEarly, string.format("early accel light (%g) > med (%g)", lightEarly, medEarly))
			assertTrue(medEarly > heavyEarly, string.format("early accel med (%g) > heavy (%g)", medEarly, heavyEarly))

			assertNear(lightCap, 23.75, 0.02, "hexley currentMaxSpeed")
			assertNear(medCap, 25.00, 0.02, "tux currentMaxSpeed")
			assertNear(heavyCap, 26.25, 0.02, "pidgin currentMaxSpeed")

			assertNear(lightTop, 23.75, 0.25, "hexley steady-state speed")
			assertNear(medTop, 25.00, 0.25, "tux steady-state speed")
			assertNear(heavyTop, 26.25, 0.25, "pidgin steady-state speed")
		end,
	},
	{
		name = "all 18 assets/roblox/karts/*.rbxmx files have zero untextured MeshParts",
		fn = function()
			for _, kartId in ipairs(KartTuning.KART_ORDER) do
				local path = string.format("assets/roblox/karts/%s.rbxmx", kartId)
				assertTrue(fs.isFile(path), "rbxmx exists: " .. path)
				local xml = fs.readFile(path)
				local meshPartCount = 0
				for props in string.gmatch(xml, '<Item class="MeshPart"[^>]*>(.-)</Item>') do
					meshPartCount += 1
					local meshId = string.match(props, '<Content name="MeshId"><url>([^<]+)</url></Content>')
					local texId = string.match(props, '<Content name="TextureID"><url>([^<]+)</url></Content>')
					assertTrue(meshId ~= nil and #meshId > 0, path .. " MeshPart missing MeshId")
					assertTrue(texId ~= nil and #texId > 0, path .. " MeshPart missing TextureID")
				end
				assertTrue(meshPartCount > 0, path .. " has at least 1 MeshPart")
			end
		end,
	},
}
