--!strict
-- tests/run.luau
-- SPDX-License-Identifier: GPL-3.0-or-later

local suites = {
	{ name = "Units", tests = require("./Units.spec") },
	{ name = "FixedStep", tests = require("./FixedStep.spec") },
	{ name = "KartSolver", tests = require("./KartSolver.spec") },
	{ name = "KartVisualMath", tests = require("./KartVisualMath.spec") },
	{ name = "RaceHudMath", tests = require("./RaceHudMath.spec") },
	{ name = "Standings", tests = require("./Standings.spec") },
	{ name = "Items", tests = require("./Items.spec") },
}

local passed = 0
local failed = 0

for _, suite in suites do
	for _, testCase in suite.tests do
		local ok, err = pcall(testCase.fn)
		if ok then
			passed += 1
			print(string.format("PASS [%s] %s", suite.name, testCase.name))
		else
			failed += 1
			print(string.format("FAIL [%s] %s: %s", suite.name, testCase.name, tostring(err)))
		end
	end
end

print(string.format("Summary: %d passed, %d failed", passed, failed))

if failed > 0 then
	error(string.format("%d test(s) failed", failed))
end
