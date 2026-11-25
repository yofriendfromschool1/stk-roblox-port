--!strict
-- src/shared/sim/Math3D.lua
-- SPDX-License-Identifier: GPL-3.0-or-later
-- Pure-Luau 3D vector, quaternion, and interpolation math (zero Roblox API).

export type Vec3 = {
	x: number,
	y: number,
	z: number,
}

export type Quat = {
	w: number,
	x: number,
	y: number,
	z: number,
}

local Math3D = {}

function Math3D.vec3(x: number, y: number, z: number): Vec3
	return { x = x, y = y, z = z }
end

function Math3D.add(a: Vec3, b: Vec3): Vec3
	return { x = a.x + b.x, y = a.y + b.y, z = a.z + b.z }
end

function Math3D.sub(a: Vec3, b: Vec3): Vec3
	return { x = a.x - b.x, y = a.y - b.y, z = a.z - b.z }
end

function Math3D.scale(v: Vec3, s: number): Vec3
	return { x = v.x * s, y = v.y * s, z = v.z * s }
end

function Math3D.dot(a: Vec3, b: Vec3): number
	return a.x * b.x + a.y * b.y + a.z * b.z
end

function Math3D.cross(a: Vec3, b: Vec3): Vec3
	return {
		x = a.y * b.z - a.z * b.y,
		y = a.z * b.x - a.x * b.z,
		z = a.x * b.y - a.y * b.x,
	}
end

function Math3D.lenSq(v: Vec3): number
	return v.x * v.x + v.y * v.y + v.z * v.z
end

function Math3D.len(v: Vec3): number
	return math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
end

function Math3D.normalize(v: Vec3, fallback: Vec3?): Vec3
	local l = math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
	if l < 1e-9 then
		return fallback or { x = 0, y = 1, z = 0 }
	end
	local inv = 1.0 / l
	return { x = v.x * inv, y = v.y * inv, z = v.z * inv }
end

function Math3D.vecLerp(a: Vec3, b: Vec3, alpha: number): Vec3
	return {
		x = a.x + (b.x - a.x) * alpha,
		y = a.y + (b.y - a.y) * alpha,
		z = a.z + (b.z - a.z) * alpha,
	}
end

function Math3D.sign(x: number): number
	if x > 0 then
		return 1
	elseif x < 0 then
		return -1
	end
	return 0
end

function Math3D.quatIdentity(): Quat
	return { w = 1, x = 0, y = 0, z = 0 }
end

function Math3D.quatNormalize(q: Quat): Quat
	local l = math.sqrt(q.w * q.w + q.x * q.x + q.y * q.y + q.z * q.z)
	if l < 1e-12 then
		return { w = 1, x = 0, y = 0, z = 0 }
	end
	local inv = 1.0 / l
	return { w = q.w * inv, x = q.x * inv, y = q.y * inv, z = q.z * inv }
end

function Math3D.quatConjugate(q: Quat): Quat
	return { w = q.w, x = -q.x, y = -q.y, z = -q.z }
end

function Math3D.quatMul(a: Quat, b: Quat): Quat
	return {
		w = a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z,
		x = a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
		y = a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
		z = a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
	}
end

function Math3D.quatFromAxisAngle(axis: Vec3, angleRad: number): Quat
	local half = angleRad * 0.5
	local s = math.sin(half)
	local n = Math3D.normalize(axis, { x = 0, y = 1, z = 0 })
	return {
		w = math.cos(half),
		x = n.x * s,
		y = n.y * s,
		z = n.z * s,
	}
end

function Math3D.quatRotateVec(q: Quat, v: Vec3): Vec3
	-- v' = v + 2 * q_vec x (q_vec x v + w * v)
	local tx = 2 * (q.y * v.z - q.z * v.y)
	local ty = 2 * (q.z * v.x - q.x * v.z)
	local tz = 2 * (q.x * v.y - q.y * v.x)
	return {
		x = v.x + q.w * tx + (q.y * tz - q.z * ty),
		y = v.y + q.w * ty + (q.z * tx - q.x * tz),
		z = v.z + q.w * tz + (q.x * ty - q.y * tx),
	}
end

function Math3D.quatBasis(q: Quat): (Vec3, Vec3, Vec3)
	-- Columns of rotation matrix: right (+X), up (+Y), fwd (+Z)
	local xx = q.x * q.x
	local yy = q.y * q.y
	local zz = q.z * q.z
	local xy = q.x * q.y
	local xz = q.x * q.z
	local yz = q.y * q.z
	local wx = q.w * q.x
	local wy = q.w * q.y
	local wz = q.w * q.z

	local right: Vec3 = {
		x = 1 - 2 * (yy + zz),
		y = 2 * (xy + wz),
		z = 2 * (xz - wy),
	}
	local up: Vec3 = {
		x = 2 * (xy - wz),
		y = 1 - 2 * (xx + zz),
		z = 2 * (yz + wx),
	}
	local fwd: Vec3 = {
		x = 2 * (xz + wy),
		y = 2 * (yz - wx),
		z = 1 - 2 * (xx + yy),
	}
	return right, up, fwd
end

function Math3D.quatIntegrateAngVel(q: Quat, omega: Vec3, dt: number): Quat
	-- World-space angular velocity integration: dq = 0.5 * (0, omega) * q * dt
	local halfDt = 0.5 * dt
	local dqW = -omega.x * q.x - omega.y * q.y - omega.z * q.z
	local dqX = omega.x * q.w + omega.y * q.z - omega.z * q.y
	local dqY = omega.y * q.w + omega.z * q.x - omega.x * q.z
	local dqZ = omega.z * q.w + omega.x * q.y - omega.y * q.x
	return Math3D.quatNormalize({
		w = q.w + dqW * halfDt,
		x = q.x + dqX * halfDt,
		y = q.y + dqY * halfDt,
		z = q.z + dqZ * halfDt,
	})
end

function Math3D.quatSlerp(a: Quat, b: Quat, alpha: number): Quat
	local dot = a.w * b.w + a.x * b.x + a.y * b.y + a.z * b.z
	local bw, bx, by, bz = b.w, b.x, b.y, b.z
	if dot < 0 then
		dot = -dot
		bw, bx, by, bz = -bw, -bx, -by, -bz
	end
	if dot > 0.9995 then
		return Math3D.quatNormalize({
			w = a.w + (bw - a.w) * alpha,
			x = a.x + (bx - a.x) * alpha,
			y = a.y + (by - a.y) * alpha,
			z = a.z + (bz - a.z) * alpha,
		})
	end
	local theta0 = math.acos(math.clamp(dot, -1, 1))
	local sinTheta0 = math.sin(theta0)
	local s0 = math.sin((1 - alpha) * theta0) / sinTheta0
	local s1 = math.sin(alpha * theta0) / sinTheta0
	return {
		w = a.w * s0 + bw * s1,
		x = a.x * s0 + bx * s1,
		y = a.y * s0 + by * s1,
		z = a.z * s0 + bz * s1,
	}
end

function Math3D.evalPiecewiseLinear(points: { { number } }, x: number): number
	local n = #points
	if n == 0 then
		return 0
	end
	if x <= points[1][1] then
		return points[1][2]
	end
	for i = 2, n do
		local x1 = points[i][1]
		if x <= x1 then
			local x0 = points[i - 1][1]
			local y0 = points[i - 1][2]
			local y1 = points[i][2]
			local denom = x1 - x0
			if denom <= 1e-9 then
				return y1
			end
			local t = (x - x0) / denom
			return y0 + (y1 - y0) * t
		end
	end
	return points[n][2]
end

return table.freeze(Math3D)
