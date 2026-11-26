--!strict
-- src/shared/net/RemoteInterp.lua
-- SPDX-License-Identifier: GPL-3.0-or-later
-- Pure Luau remote-kart snapshot interpolation buffer (zero Roblox API).
-- Supports sorted insert, stale drop, bracketed lerp/slerp, and 200 ms bounded extrapolation.

local Math3D = require("../sim/Math3D")

type Vec3 = Math3D.Vec3
type Quat = Math3D.Quat

export type Snapshot = {
	serverTime: number,
	pos: Vec3,
	rot: Quat,
	vel: Vec3?,
	speed: number,
	steer: number,
}

export type SampledPose = {
	pos: Vec3,
	rot: Quat,
	speed: number,
	steer: number,
}

export type Buffer = {
	maxSamples: number,
	samples: { Snapshot },
}

local RemoteInterp = {}

RemoteInterp.DEFAULT_INTERP_DELAY_SEC = 0.10
RemoteInterp.MAX_EXTRAPOLATION_SEC = 0.20

function RemoteInterp.createBuffer(maxSamples: number?): Buffer
	return {
		maxSamples = maxSamples or 32,
		samples = {},
	}
end

local function cloneSnapshot(snap: Snapshot): Snapshot
	return {
		serverTime = snap.serverTime,
		pos = { x = snap.pos.x, y = snap.pos.y, z = snap.pos.z },
		rot = { w = snap.rot.w, x = snap.rot.x, y = snap.rot.y, z = snap.rot.z },
		vel = if snap.vel then { x = snap.vel.x, y = snap.vel.y, z = snap.vel.z } else nil,
		speed = snap.speed,
		steer = snap.steer,
	}
end

-- Sorted insert by serverTime; replaces duplicate timestamp and drops oldest beyond maxSamples.
function RemoteInterp.push(buf: Buffer, snap: Snapshot): boolean
	local samples = buf.samples
	local n = #samples
	if n >= buf.maxSamples and snap.serverTime <= samples[1].serverTime then
		-- Stale snapshot older than our oldest retained sample
		return false
	end

	local cloned = cloneSnapshot(snap)
	local insertIdx = n + 1
	for i = n, 1, -1 do
		if math.abs(samples[i].serverTime - cloned.serverTime) < 1e-6 then
			samples[i] = cloned
			return true
		elseif samples[i].serverTime < cloned.serverTime then
			insertIdx = i + 1
			break
		end
		if i == 1 then
			insertIdx = 1
		end
	end

	table.insert(samples, insertIdx, cloned)
	while #samples > buf.maxSamples do
		table.remove(samples, 1)
	end
	return true
end

function RemoteInterp.sample(buf: Buffer, renderTime: number): SampledPose?
	local samples = buf.samples
	local n = #samples
	if n == 0 then
		return nil
	end
	if n == 1 or renderTime <= samples[1].serverTime then
		local s = samples[1]
		return {
			pos = { x = s.pos.x, y = s.pos.y, z = s.pos.z },
			rot = { w = s.rot.w, x = s.rot.x, y = s.rot.y, z = s.rot.z },
			speed = s.speed,
			steer = s.steer,
		}
	end

	local latest = samples[n]
	if renderTime >= latest.serverTime then
		local dtExtrap = math.min(renderTime - latest.serverTime, RemoteInterp.MAX_EXTRAPOLATION_SEC)
		local vel = latest.vel
		if vel == nil then
			local prev = samples[n - 1]
			local span = latest.serverTime - prev.serverTime
			if span > 1e-5 then
				vel = Math3D.scale(Math3D.sub(latest.pos, prev.pos), 1.0 / span)
			else
				vel = { x = 0, y = 0, z = 0 }
			end
		end
		local extrapPos = Math3D.add(latest.pos, Math3D.scale(vel :: Vec3, dtExtrap))
		return {
			pos = extrapPos,
			rot = { w = latest.rot.w, x = latest.rot.x, y = latest.rot.y, z = latest.rot.z },
			speed = latest.speed,
			steer = latest.steer,
		}
	end

	-- Find bracketing pair samples[i] <= renderTime <= samples[i+1]
	for i = n - 1, 1, -1 do
		local a = samples[i]
		local b = samples[i + 1]
		if renderTime >= a.serverTime and renderTime <= b.serverTime then
			local span = b.serverTime - a.serverTime
			local alpha = if span > 1e-6 then math.clamp((renderTime - a.serverTime) / span, 0.0, 1.0) else 0.0
			return {
				pos = Math3D.vecLerp(a.pos, b.pos, alpha),
				rot = Math3D.quatSlerp(a.rot, b.rot, alpha),
				speed = a.speed + (b.speed - a.speed) * alpha,
				steer = a.steer + (b.steer - a.steer) * alpha,
			}
		end
	end

	return nil
end

return RemoteInterp
