--!strict
-- tests/RemoteInterp.spec.luau
-- SPDX-License-Identifier: GPL-3.0-or-later

local RemoteInterp = require("../src/shared/net/RemoteInterp")

local function assertNear(actual: number, expected: number, eps: number, label: string)
	if math.abs(actual - expected) > eps then
		error(string.format("%s: expected %.6f +/- %.6f, got %.6f", label, expected, eps, actual))
	end
end

local tests = {}

table.insert(tests, {
	name = "interpolation is exact at bracket endpoints and monotonic between them",
	fn = function()
		local buf = RemoteInterp.createBuffer(16)
		RemoteInterp.push(buf, {
			serverTime = 10.0,
			pos = { x = 0, y = 0, z = 0 },
			rot = { w = 1, x = 0, y = 0, z = 0 },
			speed = 10.0,
			steer = -0.5,
		})
		RemoteInterp.push(buf, {
			serverTime = 10.1,
			pos = { x = 10, y = 0, z = 20 },
			rot = { w = 1, x = 0, y = 0, z = 0 },
			speed = 20.0,
			steer = 0.5,
		})

		local s0 = RemoteInterp.sample(buf, 10.0) :: RemoteInterp.SampledPose
		assertNear(s0.pos.x, 0.0, 1e-6, "t0 x")
		assertNear(s0.speed, 10.0, 1e-6, "t0 speed")

		local sMid = RemoteInterp.sample(buf, 10.05) :: RemoteInterp.SampledPose
		assertNear(sMid.pos.x, 5.0, 1e-6, "mid x")
		assertNear(sMid.pos.z, 10.0, 1e-6, "mid z")
		assertNear(sMid.speed, 15.0, 1e-6, "mid speed")
		assertNear(sMid.steer, 0.0, 1e-6, "mid steer")

		local s1 = RemoteInterp.sample(buf, 10.1) :: RemoteInterp.SampledPose
		assertNear(s1.pos.x, 10.0, 1e-6, "t1 x")
		assertNear(s1.pos.z, 20.0, 1e-6, "t1 z")
	end,
})

table.insert(tests, {
	name = "out-of-order insert sorts cleanly, stale snapshots drop, extrapolation caps at 200ms",
	fn = function()
		local buf1 = RemoteInterp.createBuffer(3)
		RemoteInterp.push(buf1, {
			serverTime = 2.0,
			pos = { x = 20, y = 0, z = 0 },
			rot = { w = 1, x = 0, y = 0, z = 0 },
			speed = 10,
			steer = 0,
		})
		RemoteInterp.push(buf1, {
			serverTime = 1.0,
			pos = { x = 10, y = 0, z = 0 },
			rot = { w = 1, x = 0, y = 0, z = 0 },
			speed = 10,
			steer = 0,
		})
		RemoteInterp.push(buf1, {
			serverTime = 3.0,
			pos = { x = 30, y = 0, z = 0 },
			rot = { w = 1, x = 0, y = 0, z = 0 },
			speed = 10,
			steer = 0,
		})

		-- Stale snapshot older than oldest retained (1.0) when buffer is full
		local accepted = RemoteInterp.push(buf1, {
			serverTime = 0.5,
			pos = { x = 999, y = 0, z = 0 },
			rot = { w = 1, x = 0, y = 0, z = 0 },
			speed = 10,
			steer = 0,
		})
		if accepted then
			error("expected stale snapshot to be dropped")
		end

		-- Extrapolation at +0.10s and capped at +0.20s (vs +0.50s)
		local e10 = RemoteInterp.sample(buf1, 3.10) :: RemoteInterp.SampledPose
		assertNear(e10.pos.x, 31.0, 1e-5, "extrap 100ms")

		local e20 = RemoteInterp.sample(buf1, 3.20) :: RemoteInterp.SampledPose
		assertNear(e20.pos.x, 32.0, 1e-5, "extrap 200ms cap")

		local e50 = RemoteInterp.sample(buf1, 3.50) :: RemoteInterp.SampledPose
		assertNear(e50.pos.x, 32.0, 1e-5, "extrap holds at 200ms")

		-- Identical output for identical buffers
		local buf2 = RemoteInterp.createBuffer(3)
		RemoteInterp.push(buf2, {
			serverTime = 1.0,
			pos = { x = 10, y = 0, z = 0 },
			rot = { w = 1, x = 0, y = 0, z = 0 },
			speed = 10,
			steer = 0,
		})
		RemoteInterp.push(buf2, {
			serverTime = 2.0,
			pos = { x = 20, y = 0, z = 0 },
			rot = { w = 1, x = 0, y = 0, z = 0 },
			speed = 10,
			steer = 0,
		})
		RemoteInterp.push(buf2, {
			serverTime = 3.0,
			pos = { x = 30, y = 0, z = 0 },
			rot = { w = 1, x = 0, y = 0, z = 0 },
			speed = 10,
			steer = 0,
		})
		local a = RemoteInterp.sample(buf1, 2.35) :: RemoteInterp.SampledPose
		local b = RemoteInterp.sample(buf2, 2.35) :: RemoteInterp.SampledPose
		assertNear(a.pos.x, b.pos.x, 1e-6, "identical buffers produce identical output")
	end,
})

return tests
