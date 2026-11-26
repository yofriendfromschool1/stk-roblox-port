--!strict
-- tests/FlyableCollision.spec.luau
-- SPDX-License-Identifier: GPL-3.0-or-later

local FixedStep = require("../src/shared/sim/FixedStep")
local Flyable = require("../src/shared/sim/Flyable")

local function assertEqual(actual: any, expected: any, label: string)
	if actual ~= expected then
		error(string.format("%s: expected %s, got %s", label, tostring(expected), tostring(actual)))
	end
end

local function makeBall(id: number, ownerId: number, x: number, z: number, vx: number, vz: number): Flyable.FlyableEntry
	return {
		id = id,
		kind = "bowling",
		ownerId = ownerId,
		pos = { x = x, y = 0.5, z = z },
		vel = { x = vx, y = 0, z = vz },
		rot = { w = 1, x = 0, y = 0, z = 0 },
		radius = 0.5,
		gravity = 0.0,
		restitution = 0.4,
		speedScalar = 20.0,
		ticksSinceThrown = 10,
		maxLifespanTicks = -1,
		reverseMode = false,
		isBattle = false,
		hasHitSomething = false,
		movedToInfinity = false,
		keepAliveTicks = -1,
		targetKartId = 0,
		deleteTicks = -1,
		drivelineIdx = 1,
		bouncePhaseSec = 0,
		bandState = 0,
		bandTargetKartId = 0,
		bandAnchorPos = { x = 0, y = 0, z = 0 },
	}
end

local tests = {}

table.insert(tests, {
	name = "two bowling balls cancel deterministically and fire crash cancel effects",
	fn = function()
		local w = Flyable.createWorld()
		w.nextId = 3
		table.insert(w.entries, makeBall(1, 1, 0, 0, 10, 0))
		table.insert(w.entries, makeBall(2, 2, 0.8, 0, -10, 0))

		Flyable.step(w, {}, nil, FixedStep.FIXED_DT, nil, 10)
		assertEqual(#w.entries, 0, "both bowling balls removed on head-on cancel")
		assertEqual(w.cancelEffects ~= nil and #w.cancelEffects or 0, 2, "two crash cancel effects emitted")
		if w.cancelEffects then
			assertEqual(w.cancelEffects[1].sfxId, "crash", "bowling cancel sfx is crash")
		end
	end,
})

table.insert(tests, {
	name = "three simultaneous bowling balls resolve without double-destroy & pair order is insertion-independent",
	fn = function()
		local wA = Flyable.createWorld()
		wA.nextId = 4
		table.insert(wA.entries, makeBall(1, 1, 0, 0, 0, 0))
		table.insert(wA.entries, makeBall(2, 2, 0.5, 0, 0, 0))
		table.insert(wA.entries, makeBall(3, 3, 0.7, 0, 0, 0))
		Flyable.step(wA, {}, nil, FixedStep.FIXED_DT, nil, 10)

		-- Pair (1,2) cancels first; ball 3 is skipped by dead 1 and 2, so ball 3 survives!
		assertEqual(#wA.entries, 1, "exactly 1 ball survives 3-way simultaneous overlap")
		assertEqual(wA.entries[1].id, 3, "ball 3 survives without double-destroy")
		assertEqual(wA.cancelEffects ~= nil and #wA.cancelEffects or 0, 2, "only 2 cancel effects, no double-destroy")

		-- Reversed insertion order (3, 2, 1) must produce identical result
		local wB = Flyable.createWorld()
		wB.nextId = 4
		table.insert(wB.entries, makeBall(3, 3, 0.7, 0, 0, 0))
		table.insert(wB.entries, makeBall(2, 2, 0.5, 0, 0, 0))
		table.insert(wB.entries, makeBall(1, 1, 0, 0, 0, 0))
		Flyable.step(wB, {}, nil, FixedStep.FIXED_DT, nil, 10)

		assertEqual(#wB.entries, 1, "reversed insertion also leaves 1 survivor")
		assertEqual(wB.entries[1].id, 3, "reversed insertion also leaves id=3")
	end,
})

table.insert(tests, {
	name = "flyable cancellation survives captureSnapshot/applySnapshot/replay identically",
	fn = function()
		local w1 = Flyable.createWorld()
		w1.nextId = 3
		table.insert(w1.entries, makeBall(1, 1, 0, 0, 10, 0))
		table.insert(w1.entries, makeBall(2, 2, 1.1, 0, -10, 0))

		local snap = Flyable.captureSnapshot(w1)
		local w2 = Flyable.createWorld()
		Flyable.applySnapshot(w2, snap)

		for tick = 1, 5 do
			Flyable.step(w1, {}, nil, FixedStep.FIXED_DT, nil, tick)
			Flyable.step(w2, {}, nil, FixedStep.FIXED_DT, nil, tick)
		end

		assertEqual(#w1.entries, 0, "w1 cancelled")
		assertEqual(#w2.entries, 0, "w2 cancelled identically after restore+replay")
	end,
})

return tests
