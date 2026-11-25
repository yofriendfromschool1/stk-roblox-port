--!strict
-- src/shared/sim/Flyable.lua
-- SPDX-License-Identifier: GPL-3.0-or-later
-- ported from src/items/flyable.cpp:L65-L615, bowling.cpp:L36-L239, cake.cpp:L34-L168,
-- plunger.cpp:L42-L255, rubber_band.cpp:L56-L388, and rubber_ball.cpp:L186-L884 (STK 1.5)
-- Pure-math Luau projectile & rubber-band physics simulation with deterministic snapshots.

local FixedStep = require("./FixedStep")
local ItemTuning = require("../ItemTuning")
local Math3D = require("./Math3D")

type Vec3 = Math3D.Vec3
type Quat = Math3D.Quat

local Flyable = {}

export type FlyableKind = "bowling" | "cake" | "plunger" | "rubber_ball"

export type DrivelinePoint = {
	x: number,
	z: number,
}

export type KartProxy = {
	id: number,
	pos: Vec3,
	rot: Quat,
	linVel: Vec3,
	speed: number,
	length: number,
	rank: number,
	baseMaxSpeed: number,
	isInvulnerable: boolean,
	isInAnimation: boolean,
	isShielded: boolean,
	hasBomb: boolean,
	onExplode: (directHit: boolean, worldTicks: number) -> (),
	onSquash: (durationSec: number, slowdown: number, worldTicks: number) -> (),
	onPlungerFace: () -> (),
	onRubberBandPull: (forceVec: Vec3, grantBoost: boolean) -> (),
}

export type FlyableEntry = {
	id: number,
	kind: FlyableKind,
	ownerId: number,
	pos: Vec3,
	vel: Vec3,
	rot: Quat,
	radius: number,
	gravity: number,
	restitution: number,
	speedScalar: number,
	ticksSinceThrown: number,
	maxLifespanTicks: number,
	reverseMode: boolean,
	isBattle: boolean,
	hasHitSomething: boolean,
	movedToInfinity: boolean,
	keepAliveTicks: number,
	targetKartId: number,
	deleteTicks: number,
	drivelineIdx: number,
	bouncePhaseSec: number,
	-- RubberBand fields (plunger forward mode: 0=none, 1=to_plunger, 2=to_kart, 3=to_track)
	bandState: number,
	bandTargetKartId: number,
	bandAnchorPos: Vec3,
}

export type FlyableWorldState = {
	nextId: number,
	entries: { FlyableEntry },
}

export type NetFlyableEntry = {
	id: number,
	kind: FlyableKind,
	ownerId: number,
	pos: { number },
	vel: { number },
	rot: { number },
	radius: number,
	gravity: number,
	restitution: number,
	speedScalar: number,
	ticksSinceThrown: number,
	maxLifespanTicks: number,
	reverseMode: boolean,
	isBattle: boolean,
	hasHitSomething: boolean,
	movedToInfinity: boolean,
	keepAliveTicks: number,
	targetKartId: number,
	deleteTicks: number,
	drivelineIdx: number,
	bouncePhaseSec: number,
	bandState: number,
	bandTargetKartId: number,
	bandAnchorPos: { number },
}

export type FlyableSnapshot = {
	nextId: number,
	entries: { NetFlyableEntry },
}

local function cloneVec3(v: Vec3): Vec3
	return { x = v.x, y = v.y, z = v.z }
end

local function cloneQuat(q: Quat): Quat
	return { w = q.w, x = q.x, y = q.y, z = q.z }
end

function Flyable.createWorld(): FlyableWorldState
	return {
		nextId = 1,
		entries = {},
	}
end

local function findKartById(karts: { KartProxy }, id: number): KartProxy?
	for _, k in karts do
		if k.id == id then
			return k
		end
	end
	return nil
end

local function isOwnerImmune(entry: FlyableEntry, kartId: number): boolean
	return kartId == entry.ownerId
		and entry.ticksSinceThrown < FixedStep.timeToTicks(ItemTuning.flyable.OWNER_IMMUNITY_SEC)
end

-- Ported from Flyable::getClosestKart (src/items/flyable.cpp:L251-L316).
function Flyable.getClosestKart(
	originPos: Vec3,
	originFwd: Vec3?,
	ownerId: number,
	karts: { KartProxy },
	filterInCone: boolean,
	backwards: boolean,
	coneMaxDist: number?
): (KartProxy?, number)
	local minDistSq = 999999.9
	local best: KartProxy? = nil
	local maxCone = coneMaxDist or ItemTuning.cake.CONE_MAX_DIST

	for _, kart in karts do
		if kart.id == ownerId or kart.isInvulnerable or kart.isInAnimation then
			continue
		end
		local dx = kart.pos.x - originPos.x
		local dy = kart.pos.y - originPos.y
		local dz = kart.pos.z - originPos.z
		local dist2 = dx * dx + dy * dy + dz * dz + math.abs(dy) * 2.0

		if filterInCone and originFwd ~= nil then
			local len = math.sqrt(dx * dx + dy * dy + dz * dz)
			if len > maxCone or len < 1e-5 then
				continue
			end
			local fwd = if backwards then Math3D.scale(originFwd, -1.0) else originFwd
			local cosAngle = (dx * fwd.x + dy * fwd.y + dz * fwd.z) / (len * Math3D.len(fwd))
			if cosAngle < ItemTuning.cake.CONE_COS_MIN then
				continue
			end
		end

		if dist2 < minDistSq then
			minDistSq = dist2
			best = kart
		end
	end

	return best, minDistSq
end

-- Ported from Flyable::getLinearKartItemIntersection (src/items/flyable.cpp:L330-L390).
function Flyable.computeLeadIntercept(
	ownerPos: Vec3,
	ownerRot: Quat,
	targetPos: Vec3,
	targetRot: Quat,
	targetSpeed: number,
	projSpeedXZ: number,
	gravity: number,
	forwardOffset: number
): (number, number)
	local invRot = Math3D.quatConjugate(ownerRot)
	local relTarget = Math3D.quatRotateVec(invRot, Math3D.sub(targetPos, ownerPos))
	local _, _, targetFwdWS = Math3D.quatBasis(targetRot)
	local targetDirLocal = Math3D.quatRotateVec(invRot, targetFwdWS)

	local tx = targetDirLocal.x * targetSpeed
	local ty = targetDirLocal.y * targetSpeed
	local tz = targetDirLocal.z * targetSpeed

	local a = (tx * tx + tz * tz) - (projSpeedXZ * projSpeedXZ)
	local b = 2.0 * (tx * relTarget.x + tz * relTarget.z)
	local c = relTarget.x * relTarget.x + relTarget.z * relTarget.z

	local t: number
	if math.abs(a) < 1e-6 then
		t = if math.abs(b) > 1e-6 then -c / b else math.sqrt(math.max(0.0, c)) / math.max(1.0, projSpeedXZ)
	else
		local disc = math.max(0.0, b * b - 4.0 * a * c)
		local sq = math.sqrt(disc)
		local t1 = (-b + sq) / (2.0 * a)
		local t2 = (-b - sq) / (2.0 * a)
		if t1 >= 0.0 and (t1 < t2 or t2 < 0.0) then
			t = t1
		elseif t2 >= 0.0 then
			t = t2
		else
			t = math.sqrt(math.max(0.0, c)) / math.max(1.0, projSpeedXZ)
		end
	end

	t = math.max(0.05, t - forwardOffset / math.max(1.0, projSpeedXZ))
	local aimX = t * tx + relTarget.x
	local aimZ = t * tz + relTarget.z
	local fireAngle = math.atan2(aimX, aimZ)
	local upVel = (0.5 * t * gravity) + (relTarget.y / t) + ty
	return fireAngle, upVel
end

local function spawnProjectileBase(
	world: FlyableWorldState,
	kind: FlyableKind,
	ownerId: number,
	pos: Vec3,
	vel: Vec3,
	rot: Quat,
	radius: number,
	gravity: number,
	restitution: number,
	speedScalar: number,
	maxLifespanTicks: number,
	reverseMode: boolean,
	isBattle: boolean
): FlyableEntry
	local id = world.nextId
	world.nextId += 1
	local entry: FlyableEntry = {
		id = id,
		kind = kind,
		ownerId = ownerId,
		pos = pos,
		vel = vel,
		rot = rot,
		radius = radius,
		gravity = gravity,
		restitution = restitution,
		speedScalar = speedScalar,
		ticksSinceThrown = 0,
		maxLifespanTicks = maxLifespanTicks,
		reverseMode = reverseMode,
		isBattle = isBattle,
		hasHitSomething = false,
		movedToInfinity = false,
		keepAliveTicks = -1,
		targetKartId = 0,
		deleteTicks = -1,
		drivelineIdx = 1,
		bouncePhaseSec = 0.0,
		bandState = 0,
		bandTargetKartId = 0,
		bandAnchorPos = { x = 0, y = 0, z = 0 },
	}
	table.insert(world.entries, entry)
	return entry
end

-- Ported from Bowling::onFireFlyable (src/items/bowling.cpp:L201-L239).
function Flyable.spawnBowling(world: FlyableWorldState, owner: KartProxy, lookBack: boolean): FlyableEntry
	local cfg = ItemTuning.bowling
	local forwardOffset = 0.5 * owner.length + cfg.RADIUS
	local _, up, fwd = Math3D.quatBasis(owner.rot)
	local speed = cfg.SPEED
	local launchDir: Vec3
	if lookBack then
		forwardOffset = -forwardOffset
		speed = cfg.SPEED * 2.0 * 2.0
		launchDir = Math3D.scale(fwd, -1.0)
	else
		local base = math.max(owner.speed + cfg.SPEED, cfg.SPEED * cfg.MIN_SPEED_MULT)
		speed = base * 2.0
		launchDir = fwd
	end
	local spawnPos = Math3D.add(owner.pos, Math3D.add(Math3D.scale(fwd, forwardOffset), Math3D.scale(up, cfg.RADIUS)))
	local launchVel = Math3D.scale(launchDir, speed)
	return spawnProjectileBase(
		world,
		"bowling",
		owner.id,
		spawnPos,
		launchVel,
		cloneQuat(owner.rot),
		cfg.RADIUS,
		cfg.GRAVITY,
		cfg.RESTITUTION,
		speed,
		FixedStep.timeToTicks(cfg.LIFESPAN_SEC),
		lookBack,
		false
	)
end

-- Ported from Cake::onFireFlyable (src/items/cake.cpp:L79-L168).
function Flyable.spawnCake(
	world: FlyableWorldState,
	owner: KartProxy,
	karts: { KartProxy },
	lookBack: boolean
): FlyableEntry
	local cfg = ItemTuning.cake
	local forwardOffset = 0.5 * owner.length + cfg.RADIUS
	local speed = cfg.SPEED * (owner.speed / cfg.OWNER_SPEED_REF)
	if owner.speed < 0.0 then
		speed /= cfg.REVERSE_SPEED_DIV
	end
	speed = math.max(1.0, speed + cfg.BASE_SPEED_ADD)
	local upVel = speed / cfg.UP_VEL_DIV

	local _, up, fwd = Math3D.quatBasis(owner.rot)
	local closest, distSq = Flyable.getClosestKart(owner.pos, fwd, owner.id, karts, true, lookBack, cfg.CONE_MAX_DIST)
	local rot = cloneQuat(owner.rot)
	local targetId = 0

	if closest ~= nil and distSq < (cfg.MAX_DISTANCE * cfg.MAX_DISTANCE) and speed > closest.speed then
		targetId = closest.id
		local fireAngle, leadUpVel = Flyable.computeLeadIntercept(
			owner.pos,
			owner.rot,
			closest.pos,
			closest.rot,
			closest.speed,
			speed,
			cfg.GRAVITY,
			forwardOffset
		)
		rot = Math3D.quatNormalize(
			Math3D.quatMul(owner.rot, Math3D.quatFromAxisAngle({ x = 0, y = 1, z = 0 }, fireAngle))
		)
		upVel = leadUpVel
	elseif lookBack then
		rot =
			Math3D.quatNormalize(Math3D.quatMul(owner.rot, Math3D.quatFromAxisAngle({ x = 0, y = 1, z = 0 }, math.pi)))
	end

	local _, _, aimFwd = Math3D.quatBasis(rot)
	local spawnPos = Math3D.add(owner.pos, Math3D.add(Math3D.scale(aimFwd, forwardOffset), Math3D.scale(up, 0.6)))
	local launchVel = Math3D.add(Math3D.scale(aimFwd, speed), Math3D.scale(up, upVel))

	local entry = spawnProjectileBase(
		world,
		"cake",
		owner.id,
		spawnPos,
		launchVel,
		rot,
		cfg.RADIUS,
		cfg.GRAVITY,
		cfg.RESTITUTION,
		speed,
		-1,
		lookBack,
		false
	)
	entry.targetKartId = targetId
	return entry
end

-- Ported from Plunger::onFireFlyable (src/items/plunger.cpp:L59-L133).
function Flyable.spawnPlunger(
	world: FlyableWorldState,
	owner: KartProxy,
	karts: { KartProxy },
	lookBack: boolean,
	isBattle: boolean?
): FlyableEntry
	local cfg = ItemTuning.plunger
	local forwardOffset = 0.5 * owner.length + cfg.RADIUS
	local plungerSpeed = cfg.SPEED * cfg.SPEED_MULT
	local _, up, fwd = Math3D.quatBasis(owner.rot)
	local closest, distSq =
		Flyable.getClosestKart(owner.pos, fwd, owner.id, karts, true, lookBack, cfg.AIM_MAX_DISTANCE)

	local rot = cloneQuat(owner.rot)
	local upVel = 0.0
	local targetId = 0
	if closest ~= nil and distSq < (cfg.AIM_MAX_DISTANCE * cfg.AIM_MAX_DISTANCE) then
		targetId = closest.id
		local fireAngle, leadUp = Flyable.computeLeadIntercept(
			owner.pos,
			owner.rot,
			closest.pos,
			closest.rot,
			closest.speed,
			plungerSpeed,
			0.0,
			forwardOffset
		)
		rot = Math3D.quatNormalize(
			Math3D.quatMul(owner.rot, Math3D.quatFromAxisAngle({ x = 0, y = 1, z = 0 }, fireAngle))
		)
		upVel = leadUp
	elseif lookBack then
		rot =
			Math3D.quatNormalize(Math3D.quatMul(owner.rot, Math3D.quatFromAxisAngle({ x = 0, y = 1, z = 0 }, math.pi)))
	end

	local _, _, aimFwd = Math3D.quatBasis(rot)
	local spawnPos = Math3D.add(owner.pos, Math3D.add(Math3D.scale(aimFwd, forwardOffset), Math3D.scale(up, 0.5)))
	local launchVel = Math3D.add(Math3D.scale(aimFwd, plungerSpeed), Math3D.scale(up, upVel))

	local battleMode = isBattle == true
	local entry = spawnProjectileBase(
		world,
		"plunger",
		owner.id,
		spawnPos,
		launchVel,
		rot,
		cfg.RADIUS,
		0.0,
		0.5,
		plungerSpeed,
		-1,
		lookBack,
		battleMode
	)
	entry.targetKartId = targetId
	if not (lookBack or battleMode) then
		entry.bandState = 1 -- RB_TO_PLUNGER
	end
	return entry
end

local function selectRubberBallTarget(ownerId: number, karts: { KartProxy }): (KartProxy?, number)
	local rank1: KartProxy? = nil
	local bestRank = math.huge
	for _, k in karts do
		if k.rank < bestRank then
			bestRank = k.rank
			rank1 = k
		end
	end
	if rank1 == nil or rank1.id == ownerId then
		return rank1, FixedStep.timeToTicks(ItemTuning.rubberBall.DELETE_TIME_SEC)
	end
	return rank1, -1
end

local function findNearestDrivelineIdx(pos: Vec3, centers: { DrivelinePoint }?): number
	if centers == nil or #centers == 0 then
		return 1
	end
	local n = #centers
	local bestIdx = 1
	local bestDistSq = math.huge
	for i, c in centers do
		local dx = c.x - pos.x
		local dz = c.z - pos.z
		local d2 = dx * dx + dz * dz
		if d2 < bestDistSq then
			bestDistSq = d2
			bestIdx = i
		end
	end
	-- Advance to the next waypoint along the closed loop when right beside a center
	return (bestIdx % n) + 1
end

-- Ported from RubberBall::RubberBall & computeTarget (src/items/rubber_ball.cpp:L96-L226).
function Flyable.spawnRubberBall(
	world: FlyableWorldState,
	owner: KartProxy,
	karts: { KartProxy },
	drivelineCenters: { DrivelinePoint }?
): FlyableEntry
	local cfg = ItemTuning.rubberBall
	local target, delTicks = selectRubberBallTarget(owner.id, karts)
	local forwardOffset = 0.5 * owner.length + cfg.RADIUS
	local _, up, fwd = Math3D.quatBasis(owner.rot)
	local spawnPos = Math3D.add(owner.pos, Math3D.add(Math3D.scale(fwd, forwardOffset), Math3D.scale(up, 0.8)))
	local initSpeed = math.max(cfg.SPEED, owner.baseMaxSpeed + cfg.MIN_SPEED_OFFSET)
	local launchVel = Math3D.scale(fwd, initSpeed)

	local entry = spawnProjectileBase(
		world,
		"rubber_ball",
		owner.id,
		spawnPos,
		launchVel,
		cloneQuat(owner.rot),
		cfg.RADIUS,
		0.0,
		0.0,
		initSpeed,
		-1,
		false,
		false
	)
	entry.targetKartId = if target ~= nil then target.id else 0
	entry.deleteTicks = delTicks
	entry.drivelineIdx = findNearestDrivelineIdx(spawnPos, drivelineCenters)
	return entry
end

local function triggerExplosionHit(
	entry: FlyableEntry,
	directKart: KartProxy?,
	karts: { KartProxy },
	secondaryHits: boolean,
	worldTicks: number
)
	local radSq = ItemTuning.bomb.RADIUS * ItemTuning.bomb.RADIUS
	for _, k in karts do
		if not secondaryHits and k ~= directKart then
			continue
		end
		local isDirect = (k == directKart)
		if isDirect or Math3D.lenSq(Math3D.sub(k.pos, entry.pos)) <= radSq then
			k.onExplode(isDirect, worldTicks)
		end
	end
end

local function resolveProjectileKartHit(
	entry: FlyableEntry,
	kart: KartProxy,
	karts: { KartProxy },
	worldTicks: number
): boolean
	if entry.hasHitSomething or isOwnerImmune(entry, kart.id) then
		return false
	end

	if entry.kind == "bowling" then
		entry.hasHitSomething = true
		if kart.isShielded then
			kart.onExplode(true, worldTicks) -- Shield absorbs impact and drops bubblegum
		else
			triggerExplosionHit(entry, kart, karts, false, worldTicks)
		end
		return true
	elseif entry.kind == "cake" then
		entry.hasHitSomething = true
		if kart.isShielded then
			kart.onExplode(true, worldTicks)
		else
			triggerExplosionHit(entry, kart, karts, true, worldTicks)
		end
		return true
	elseif entry.kind == "rubber_ball" then
		if kart.id ~= entry.targetKartId then
			-- Non-target kart en route gets squashed or detonates active bomb (rubber_ball.cpp:L861-L872)
			local cfg = ItemTuning.rubberBall
			if kart.hasBomb then
				kart.onExplode(true, worldTicks)
			else
				kart.onSquash(cfg.SQUASH_DURATION_SEC, cfg.SQUASH_SLOWDOWN, worldTicks)
			end
			return false
		end
		entry.hasHitSomething = true
		if kart.isShielded then
			kart.onExplode(true, worldTicks)
		else
			triggerExplosionHit(entry, kart, karts, true, worldTicks)
		end
		return true
	elseif entry.kind == "plunger" then
		if entry.movedToInfinity then
			return false
		end
		if entry.reverseMode or entry.isBattle then
			kart.onPlungerFace()
			entry.movedToInfinity = true
			entry.hasHitSomething = true
			return true
		else
			entry.keepAliveTicks = FixedStep.timeToTicks(ItemTuning.plunger.BAND_DURATION_SEC)
			entry.movedToInfinity = true
			if kart.isShielded then
				kart.onExplode(true, worldTicks)
				entry.keepAliveTicks = 0
				entry.hasHitSomething = true
			else
				entry.bandState = 2 -- RB_TO_KART
				entry.bandTargetKartId = kart.id
			end
			return true
		end
	end
	return false
end

local function updateRubberBand(entry: FlyableEntry, karts: { KartProxy })
	if entry.bandState == 0 then
		return
	end
	local owner = findKartById(karts, entry.ownerId)
	if owner == nil then
		entry.keepAliveTicks = 0
		entry.hasHitSomething = true
		return
	end

	local endPos = entry.pos
	local hitKart: KartProxy? = nil
	if entry.bandState == 2 then
		hitKart = findKartById(karts, entry.bandTargetKartId)
		if hitKart ~= nil then
			endPos = hitKart.pos
		else
			entry.keepAliveTicks = 0
			entry.hasHitSomething = true
			return
		end
	elseif entry.bandState == 3 then
		endPos = entry.bandAnchorPos
	end

	local diff = Math3D.sub(endPos, owner.pos)
	local distSq = Math3D.lenSq(diff)
	local maxLen = ItemTuning.plunger.BAND_MAX_LENGTH
	if distSq > maxLen * maxLen then
		entry.keepAliveTicks = 0
		entry.hasHitSomething = true
		return
	end
	if entry.bandState == 3 and distSq < (ItemTuning.plunger.BAND_TRACK_SNAP_DIST ^ 2) then
		entry.keepAliveTicks = 0
		entry.hasHitSomething = true
		return
	end

	if entry.bandState == 2 or entry.bandState == 3 then
		local dir = Math3D.normalize(diff, { x = 0, y = 0, z = 1 })
		local pull = Math3D.scale(dir, ItemTuning.plunger.BAND_FORCE)
		owner.onRubberBandPull(pull, true)
		if hitKart ~= nil then
			hitKart.onRubberBandPull(Math3D.scale(pull, -1.0), false)
		end
	end
end

-- Ported from RubberBall::updatePhysics (rubber_ball.cpp:L415-L830).
local function stepRubberBall(
	entry: FlyableEntry,
	karts: { KartProxy },
	worldQuery: any?,
	dt: number,
	drivelineCenters: { DrivelinePoint }?
)
	local cfg = ItemTuning.rubberBall
	local target = findKartById(karts, entry.targetKartId)
	local distToTarget = if target ~= nil then Math3D.len(Math3D.sub(target.pos, entry.pos)) else 0.0

	-- Dynamic catch-up speed scaling with target distance (rubber_ball.cpp:L555-L580)
	local baseMax = if target ~= nil then target.baseMaxSpeed else 25.0
	local weight = math.clamp(
		(cfg.MAX_OFFSET_DISTANCE - distToTarget) / (cfg.MAX_OFFSET_DISTANCE - cfg.MIN_OFFSET_DISTANCE),
		0.0,
		1.0
	)
	local offset = weight * cfg.MIN_SPEED_OFFSET + (1.0 - weight) * cfg.MAX_SPEED_OFFSET
	local desiredSpeed = baseMax + offset
	entry.speedScalar = desiredSpeed

	-- Determine steer aim point: direct target homing inside TARGET_DISTANCE (15m), else next driveline quad center
	local aimPoint: Vec3
	if target ~= nil and (distToTarget < cfg.TARGET_DISTANCE or drivelineCenters == nil or #drivelineCenters == 0) then
		aimPoint = target.pos
	else
		local centers = drivelineCenters :: { DrivelinePoint }
		local nCenters = #centers
		local currIdx = ((entry.drivelineIdx - 1) % nCenters) + 1
		local nextIdx = (currIdx % nCenters) + 1
		local wp = centers[currIdx]
		local wpNext = centers[nextIdx]
		local dxWp = wp.x - entry.pos.x
		local dzWp = wp.z - entry.pos.z
		local segX = wpNext.x - wp.x
		local segZ = wpNext.z - wp.z
		local passedPlane = ((entry.pos.x - wp.x) * segX + (entry.pos.z - wp.z) * segZ) > 0.0
		if (dxWp * dxWp + dzWp * dzWp) < (18.0 * 18.0) or passedPlane then
			currIdx = nextIdx
			entry.drivelineIdx = currIdx
		end
		wp = centers[currIdx]
		aimPoint = { x = wp.x, y = entry.pos.y, z = wp.z }
	end

	local flatCur = Math3D.normalize({ x = entry.vel.x, y = 0, z = entry.vel.z }, { x = 0, y = 0, z = 1 })
	local flatDes = Math3D.normalize({ x = aimPoint.x - entry.pos.x, y = 0, z = aimPoint.z - entry.pos.z }, flatCur)
	local curYaw = math.atan2(flatCur.x, flatCur.z)
	local desYaw = math.atan2(flatDes.x, flatDes.z)
	local dYaw = (desYaw - curYaw + math.pi) % (2.0 * math.pi) - math.pi
	local maxTurn = cfg.TARGET_MAX_ANGLE_RAD * dt
	local nextYaw = curYaw + math.clamp(dYaw, -maxTurn, maxTurn)

	-- Parabolic ping-pong height oscillation (rubber_ball.cpp:L710-L745)
	local fastPing = target ~= nil and distToTarget < cfg.FAST_PING_DISTANCE
	local heightCap = cfg.MAX_HEIGHT
	local period = cfg.INTERVAL_SEC
	if fastPing then
		heightCap = math.min(cfg.MAX_HEIGHT, 0.5 * math.sqrt(math.max(0.04, distToTarget)))
		period = math.max(0.1, heightCap / 10.0)
	end
	entry.bouncePhaseSec = (entry.bouncePhaseSec + dt) % period
	local tNorm = entry.bouncePhaseSec / period
	local bounceFrac = 4.0 * tNorm * (1.0 - tNorm)
	local groundY = 0.0
	if worldQuery ~= nil and type(worldQuery.raycast) == "function" then
		local hit = worldQuery.raycast(
			{ x = entry.pos.x, y = entry.pos.y + 4.0, z = entry.pos.z },
			{ x = 0, y = -1, z = 0 },
			16.0
		)
		if hit ~= nil then
			groundY = hit.point.y
		end
	end

	entry.vel = { x = math.sin(nextYaw) * desiredSpeed, y = 0.0, z = math.cos(nextYaw) * desiredSpeed }
	entry.pos.x += entry.vel.x * dt
	entry.pos.z += entry.vel.z * dt
	entry.pos.y = groundY + entry.radius * 0.5 + heightCap * bounceFrac
end

-- Advance all active Flyables by one 120 Hz fixed step (server & client prediction parity).
function Flyable.step(
	world: FlyableWorldState,
	karts: { KartProxy },
	worldQuery: any?,
	dt: number,
	drivelineCenters: { DrivelinePoint }?,
	worldTicks: number?
)
	local ticksNow = worldTicks or 0
	for i = #world.entries, 1, -1 do
		local entry = world.entries[i]
		entry.ticksSinceThrown += 1

		-- 1. Plunger keep-alive rubber-band mode
		if entry.kind == "plunger" and entry.keepAliveTicks >= 0 then
			entry.keepAliveTicks -= 1
			if entry.keepAliveTicks <= 0 then
				entry.hasHitSomething = true
				table.remove(world.entries, i)
				continue
			end
			updateRubberBand(entry, karts)
			if entry.hasHitSomething then
				table.remove(world.entries, i)
			end
			continue
		end

		if entry.kind == "rubber_ball" and entry.deleteTicks > 0 then
			entry.deleteTicks -= 1
			if entry.deleteTicks <= 0 then
				entry.hasHitSomething = true
				table.remove(world.entries, i)
				continue
			end
		end

		if entry.maxLifespanTicks > -1 and entry.ticksSinceThrown > entry.maxLifespanTicks then
			entry.hasHitSomething = true
			table.remove(world.entries, i)
			continue
		end

		-- 2. Motion update
		if entry.kind == "rubber_ball" then
			stepRubberBall(entry, karts, worldQuery, dt, drivelineCenters)
		else
			-- Bowling attraction to closest kart within 25m and 1.3 rad (bowling.cpp:L88-L101)
			if entry.kind == "bowling" then
				local bCfg = ItemTuning.bowling
				local fwdDir = Math3D.normalize(entry.vel, { x = 0, y = 0, z = 1 })
				local closest, distSq =
					Flyable.getClosestKart(entry.pos, fwdDir, entry.ownerId, karts, false, false, bCfg.MAX_DISTANCE)
				if closest ~= nil and distSq < (bCfg.MAX_DISTANCE * bCfg.MAX_DISTANCE) then
					local toTarget = Math3D.sub(closest.pos, entry.pos)
					local dir = Math3D.normalize(toTarget, fwdDir)
					local cosA = math.clamp(Math3D.dot(fwdDir, dir), -1.0, 1.0)
					if math.acos(cosA) < bCfg.MAX_ATTRACTION_ANGLE_RAD then
						local accel = (bCfg.FORCE_TO_TARGET / bCfg.MASS) * dt
						entry.vel = Math3D.add(entry.vel, Math3D.scale(dir, accel))
					end
				end
			end

			entry.vel.y -= entry.gravity * dt
			local delta = Math3D.scale(entry.vel, dt)
			local dist = Math3D.len(delta)
			local hitObstacle = false
			local hitPoint: Vec3? = nil

			if worldQuery ~= nil and type(worldQuery.raycast) == "function" and dist > 1e-6 then
				local dir = Math3D.scale(delta, 1.0 / dist)
				local hit = worldQuery.raycast(entry.pos, dir, dist + entry.radius)
				if hit ~= nil and hit.materialName ~= "oasis-water.png" then
					local n = Math3D.normalize(hit.normal, { x = 0, y = 1, z = 0 })
					entry.pos = Math3D.add(hit.point, Math3D.scale(n, entry.radius + 0.02))
					hitPoint = hit.point
					if entry.kind == "plunger" and not entry.reverseMode and not entry.isBattle then
						hitObstacle = true
					else
						local vn = Math3D.dot(entry.vel, n)
						if vn < 0 then
							entry.vel = Math3D.sub(entry.vel, Math3D.scale(n, (1.0 + entry.restitution) * vn))
						end
					end
				else
					entry.pos = Math3D.add(entry.pos, delta)
				end
			else
				entry.pos = Math3D.add(entry.pos, delta)
				if entry.pos.y < entry.radius then
					entry.pos.y = entry.radius
					if entry.vel.y < 0 then
						entry.vel.y = -entry.vel.y * entry.restitution
					end
				end
			end

			if hitObstacle and entry.kind == "plunger" and hitPoint ~= nil then
				entry.keepAliveTicks = FixedStep.timeToTicks(ItemTuning.plunger.BAND_DURATION_SEC)
				entry.movedToInfinity = true
				entry.bandState = 3 -- RB_TO_TRACK
				entry.bandAnchorPos = cloneVec3(hitPoint)
			end
		end

		-- Out-of-bounds cleanup (flyable.cpp:L474-L479)
		if math.abs(entry.pos.x) > 265.0 or math.abs(entry.pos.z) > 265.0 or entry.pos.y < -20.0 then
			table.remove(world.entries, i)
			continue
		end

		if entry.kind == "plunger" and entry.bandState == 1 then
			updateRubberBand(entry, karts)
		end

		-- 3. Kart collision check
		local removed = false
		local hitRad = entry.radius + ItemTuning.flyable.HIT_RADIUS_KART
		local hitRadSq = hitRad * hitRad
		for _, k in karts do
			if Math3D.lenSq(Math3D.sub(k.pos, entry.pos)) <= hitRadSq then
				if resolveProjectileKartHit(entry, k, karts, ticksNow) then
					if entry.hasHitSomething then
						removed = true
						break
					end
				end
			end
		end

		if removed or entry.hasHitSomething then
			table.remove(world.entries, i)
		end
	end
end

function Flyable.captureSnapshot(world: FlyableWorldState): FlyableSnapshot
	local list: { NetFlyableEntry } = table.create(#world.entries)
	for _, e in world.entries do
		table.insert(list, {
			id = e.id,
			kind = e.kind,
			ownerId = e.ownerId,
			pos = { e.pos.x, e.pos.y, e.pos.z },
			vel = { e.vel.x, e.vel.y, e.vel.z },
			rot = { e.rot.w, e.rot.x, e.rot.y, e.rot.z },
			radius = e.radius,
			gravity = e.gravity,
			restitution = e.restitution,
			speedScalar = e.speedScalar,
			ticksSinceThrown = e.ticksSinceThrown,
			maxLifespanTicks = e.maxLifespanTicks,
			reverseMode = e.reverseMode,
			isBattle = e.isBattle,
			hasHitSomething = e.hasHitSomething,
			movedToInfinity = e.movedToInfinity,
			keepAliveTicks = e.keepAliveTicks,
			targetKartId = e.targetKartId,
			deleteTicks = e.deleteTicks,
			drivelineIdx = e.drivelineIdx,
			bouncePhaseSec = e.bouncePhaseSec,
			bandState = e.bandState,
			bandTargetKartId = e.bandTargetKartId,
			bandAnchorPos = { e.bandAnchorPos.x, e.bandAnchorPos.y, e.bandAnchorPos.z },
		})
	end
	return {
		nextId = world.nextId,
		entries = list,
	}
end

function Flyable.applySnapshot(world: FlyableWorldState, snap: FlyableSnapshot)
	world.nextId = snap.nextId
	local restored: { FlyableEntry } = table.create(#snap.entries)
	for _, n in snap.entries do
		table.insert(restored, {
			id = n.id,
			kind = n.kind,
			ownerId = n.ownerId,
			pos = { x = n.pos[1], y = n.pos[2], z = n.pos[3] },
			vel = { x = n.vel[1], y = n.vel[2], z = n.vel[3] },
			rot = { w = n.rot[1], x = n.rot[2], y = n.rot[3], z = n.rot[4] },
			radius = n.radius,
			gravity = n.gravity,
			restitution = n.restitution,
			speedScalar = n.speedScalar,
			ticksSinceThrown = n.ticksSinceThrown,
			maxLifespanTicks = n.maxLifespanTicks,
			reverseMode = n.reverseMode,
			isBattle = n.isBattle,
			hasHitSomething = n.hasHitSomething,
			movedToInfinity = n.movedToInfinity,
			keepAliveTicks = n.keepAliveTicks,
			targetKartId = n.targetKartId,
			deleteTicks = n.deleteTicks,
			drivelineIdx = n.drivelineIdx,
			bouncePhaseSec = n.bouncePhaseSec,
			bandState = n.bandState,
			bandTargetKartId = n.bandTargetKartId,
			bandAnchorPos = { x = n.bandAnchorPos[1], y = n.bandAnchorPos[2], z = n.bandAnchorPos[3] },
		})
	end
	world.entries = restored
end

return table.freeze(Flyable)
