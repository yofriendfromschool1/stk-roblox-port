--!strict
-- src/shared/KartTuning.lua
-- SPDX-License-Identifier: GPL-3.0-or-later
-- ported from data/stk_config.xml, data/kart_characteristics.xml, data/official_karts.xml,
-- src/karts/kart.cpp, src/karts/skidding.cpp, src/karts/max_speed.cpp, src/physics/btKart.cpp (STK 1.5)

export type Vec3Table = {
	x: number,
	y: number,
	z: number,
}

export type TablePoint = { number } -- { x, y }

export type NitroProfile = {
	engineForce: number,
	engineMult: number,
	consumptionPerTick: number,
	smallContainer: number,
	bigContainer: number,
	maxSpeedIncrease: number,
	duration: number,
	fadeOutTime: number,
	max: number,
	minConsumptionTicks: number,
}

export type KartClassPreset = {
	massMult: number,
	enginePowerMult: number,
	maxSpeedMult: number,
	brakeFactorMult: number,
	reverseRatioMult: number,
	nitroEngineForceMult: number,
	nitroConsumptionMult: number,
	nitroMaxSpeedIncreaseMult: number,
	nitroDurationMult: number,
	turnRadius: { TablePoint },
	gearSwitchRatio: { number },
	gearPowerIncrease: { number },
}

export type DifficultyPreset = {
	enginePowerMult: number,
	maxSpeedMult: number,
	nitroEngineForceMult: number,
	nitroMaxSpeedIncreaseMult: number,
	nitroMaxMult: number,
}

export type KartDimensions = {
	width: number,
	height: number,
	length: number,
	cogShiftY: number,
}

export type KartProfile = {
	className: string,
	difficulty: string,
	mass: number,
	invMass: number,
	enginePower: number,
	maxSpeed: number,
	brakeFactor: number,
	brakeTimeIncrease: number,
	maxSpeedReverseRatio: number,
	nitro: NitroProfile,
	turnRadius: { TablePoint },
	gearSwitchRatio: { number },
	gearPowerIncrease: { number },
	width: number,
	height: number,
	collisionHeight: number,
	length: number,
	wheelBase: number,
	invInertia: Vec3Table,
	wheelHardpoints: { Vec3Table }, -- 1: FL, 2: FR, 3: RL, 4: RR
}

local function deepFreeze<T>(tbl: T): T
	if type(tbl) == "table" and not table.isfrozen(tbl :: any) then
		for _, v in tbl :: any do
			if type(v) == "table" then
				deepFreeze(v)
			end
		end
		table.freeze(tbl :: any)
	end
	return tbl
end

local KartTuning = {}

-- Global physics & timing constants
KartTuning.physics = {
	FPS = 120, -- data/stk_config.xml:L147
	FIXED_DT = 1 / 120, -- data/stk_config.xml:L147
	DEFAULT_GRAVITY = 9.80665, -- src/tracks/track.cpp:L536
	SPEED_DEADBAND = 0.2, -- src/karts/kart.cpp:L1838
	MAX_SPEED_AIRBORNE = 9999.9, -- src/karts/max_speed.cpp:L453
	-- OpenKart pure-Luau solver slip-angle edge-case guards (docs/physics-spec.md §4.3)
	SLIP_SPEED_FLOOR = 0.05, -- m/s; below this speed slip angle = 0 and steering does not rotate chassis
	SLIP_EPSILON_SPEED = 0.5, -- m/s; low-speed regularization floor in atan2(v_lat, max(|v_fwd|, v_eps))
}

-- Suspension & wheel raycast constants
KartTuning.suspension = {
	stiffness = 280.0, -- data/kart_characteristics.xml:L37
	rest = 0.30, -- data/kart_characteristics.xml:L37 (m)
	travel = 0.29, -- data/kart_characteristics.xml:L37 (m)
	expSpringResponse = false, -- data/kart_characteristics.xml:L38
	maxForce = 32000.0, -- data/kart_characteristics.xml:L38 (N)
	rayExtraLength = 0.50, -- src/physics/btKart.cpp:L272 (m)
	seamRetryFraction = 0.95, -- src/physics/btKart.cpp:L238
	minContactDot = -0.1, -- src/physics/btKart.cpp:L328
	maxInvContactDot = 10.0, -- src/physics/btKart.cpp:L331 (1 / 0.1)
}

-- Wheel damping & fallback XML attachment offsets
KartTuning.wheels = {
	dampingRelaxation = 35.0, -- data/kart_characteristics.xml:L125
	dampingCompression = 15.0, -- data/kart_characteristics.xml:L125
	defaultOffsets = {
		{ x = -0.38, y = 0.0, z = 0.60 }, -- front-left, data/kart_characteristics.xml:L127
		{ x = 0.38, y = 0.0, z = 0.60 }, -- front-right, data/kart_characteristics.xml:L126
		{ x = -0.38, y = 0.0, z = -0.60 }, -- rear-left, data/kart_characteristics.xml:L129
		{ x = 0.38, y = 0.0, z = -0.60 }, -- rear-right, data/kart_characteristics.xml:L128
	},
}

-- Chassis stability & damping constants
KartTuning.stability = {
	rollInfluence = 0.3, -- data/kart_characteristics.xml:L53
	chassisLinearDamping = 0.2, -- data/kart_characteristics.xml:L54
	chassisAngularDamping = 0.0, -- data/kart_characteristics.xml:L55
	downwardImpulseFactor = 5.0, -- data/kart_characteristics.xml:L56 (N*s per m/s per 120 Hz tick)
	trackConnectionAccel = 2.0, -- data/kart_characteristics.xml:L57 (m/s^2 per off-ground wheel)
	angularFactor = { x = 0.25, y = 1.0, z = 0.5 }, -- data/kart_characteristics.xml:L58
	smoothFlyingImpulse = 250.0, -- data/kart_characteristics.xml:L59
}

-- Chassis bounds, bevel, and reference tux geometry
KartTuning.chassis = {
	maxHeightToLengthRatio = 0.6, -- src/karts/kart.cpp:L668
	bevelFactor = { x = 0.5, y = 0.0, z = 0.3 }, -- data/stk_config.xml:L480
	tux = {
		width = 0.821, -- data/official_karts.xml:L18
		height = 0.675, -- data/official_karts.xml:L18
		length = 1.437, -- data/official_karts.xml:L18
		cogShiftY = 0.3375, -- data/official_karts.xml:L18
	},
}

-- Base mass & powertrain constants
KartTuning.mass = {
	base = 350.0, -- data/kart_characteristics.xml:L115 (kg)
}

KartTuning.engine = {
	power = 950.0, -- data/kart_characteristics.xml:L100 (N)
	maxSpeed = 25.0, -- data/kart_characteristics.xml:L100 (m/s)
	brakeFactor = 15.0, -- data/kart_characteristics.xml:L100
	brakeTimeIncrease = 6.0, -- data/kart_characteristics.xml:L101 (s^-1)
	maxSpeedReverseRatio = 0.65, -- data/kart_characteristics.xml:L101
	frontWheelDriveSplit = 0.4, -- src/karts/kart.cpp:L3084
	rearWheelDriveSplit = 0.6, -- src/karts/kart.cpp:L3085
	airDragLinearComp = 39.33, -- src/karts/kart.cpp:L2747
	airDragRefMass = 350.0, -- src/karts/kart.cpp:L2746
	airDragNonlinearCoeff = 5.0, -- src/karts/kart.cpp:L2755 (5 * |v|^1.5)
	reverseAccelMultiplier = 5.0, -- src/karts/kart.cpp:L2810
	brakePowerMultiplier = 3.0, -- src/karts/kart.cpp:L2842, L2860
	parkBrakeMaxSpeed = 5.0, -- src/karts/kart.cpp:L2878 (m/s)
	parkBrakeForce = 20.0, -- src/karts/kart.cpp:L2882
	lowBrakeShakeThreshold = 10.0, -- src/physics/btKart.cpp:L781
	lowBrakeShakeScale = 0.5, -- src/physics/btKart.cpp:L782
	overGearAddForceMult = 2.0, -- src/karts/kart.cpp:L1233
}

-- Steering ramp constants
KartTuning.turn = {
	timeFullSteer = {
		{ 0.0, 0.17 },
		{ 0.5, 0.17 },
		{ 0.5, 0.28 },
		{ 1.0, 0.28 },
	}, -- data/kart_characteristics.xml:L83
	timeResetSteer = 0.10, -- data/kart_characteristics.xml:L84 (s)
	disableWhileUnskid = false, -- data/stk_config.xml:L277
}

-- Tire slip-angle -> lateral grip curve & steep-slope sliding
KartTuning.tire = {
	-- Simplified Pacejka Magic Formula (OpenKart pure-Luau replacement for Bullet bilateral constraint,
	-- docs/physics-spec.md §4.3; upstream Bullet disables slip via <friction slip="10000000"/> stk_config.xml:L435)
	B = 12.0, -- stiffness factor
	C = 1.35, -- shape factor
	E = -0.5, -- curvature factor
	muPeak = 2.8, -- peak lateral friction coefficient
	fwdTractionScale = 0.5, -- src/physics/btKart.cpp:L799 (fwdFactor = 0.5)
	driftRearGripScale = 1.0, -- OpenKart M2 tuning hook (1.0 = pure STK fidelity)
	slidingMinNormalDot = 0.85, -- src/karts/kart.cpp:L2940
	slidingFullNormalDot = 0.90, -- src/karts/kart.cpp:L2945
	slidingRampDivisor = 0.05, -- smooth [0.85, 0.90] ramp (docs/physics-spec.md §4.3; STK literal is 0.5f at kart.cpp:L2951)
}

-- Skidding / drift state machine & charge tiers
KartTuning.skid = {
	increase = 1.05, -- data/kart_characteristics.xml:L169
	decrease = 0.95, -- data/kart_characteristics.xml:L169
	max = 2.5, -- data/kart_characteristics.xml:L169
	timeTillMax = 0.5, -- data/kart_characteristics.xml:L169 (s)
	visual = 1.25, -- data/kart_characteristics.xml:L170
	visualTime = 0.7, -- data/kart_characteristics.xml:L170 (s)
	revertVisualTime = 0.7, -- data/kart_characteristics.xml:L170 (s)
	minSpeed = 10.0, -- data/kart_characteristics.xml:L171 (m/s)
	timeTillBonus = { 1.0, 3.0 }, -- data/kart_characteristics.xml:L171 (s)
	bonusSpeed = { 4.5, 6.5 }, -- data/kart_characteristics.xml:L172 (m/s)
	bonusTime = { 3.0, 4.0 }, -- data/kart_characteristics.xml:L172 (s)
	bonusForce = { 250.0, 350.0 }, -- data/kart_characteristics.xml:L173 (N)
	physicalJumpTime = 0.0, -- data/kart_characteristics.xml:L174 (s)
	graphicalJumpTime = 0.4, -- data/kart_characteristics.xml:L174 (s)
	postSkidRotateFactor = 1.0, -- data/kart_characteristics.xml:L175
	reduceTurnMin = 0.2, -- data/kart_characteristics.xml:L176
	reduceTurnMax = 0.8, -- data/kart_characteristics.xml:L176
	bonusInstantFraction = 0.5, -- src/karts/skidding.cpp:L556 (bonus_speed / 2)
	bonusFadeOutTime = 1.0, -- src/karts/skidding.cpp:L559 (s)
	breakVisualStepPerTick = 0.1, -- src/karts/skidding.cpp:L177-L178 (rad/tick)
	visualClamp = 1.0, -- src/karts/skidding.cpp:L215-L218 (rad)
	minSteerThreshold = 0.001, -- src/karts/skidding.cpp:L385
}

-- Airborne damping constants
KartTuning.air = {
	angularDampingPerTick = { x = 0.95, y = 0.25, z = 0.95 }, -- src/karts/kart.cpp:L1515-L1517
	linearDamping = 0.0, -- src/karts/kart.cpp:L1523
}

-- Nitro constants (data/kart_characteristics.xml:L318-L320, src/karts/kart_properties.cpp:L102)
KartTuning.nitro = {
	engineForce = 300.0, -- L318 (N)
	engineMult = 1.2, -- L318
	consumption = 1.0, -- L318 (units/s base)
	smallContainer = 1.0, -- L319
	bigContainer = 3.0, -- L319
	maxSpeedIncrease = 5.0, -- L320 (m/s)
	duration = 1.0, -- L320 (s)
	fadeOutTime = 2.4, -- L320 (s)
	max = 20.0, -- L320
	minConsumptionTicks = 64, -- src/karts/kart_properties.cpp:L102 (64 ticks at 120 Hz)
}

-- Swept chassis, overlap manifold, & wheel depenetration constants
KartTuning.collision = {
	-- Upstream STK speed-dependent kart restitution curve (data/stk_config.xml:L480, src/karts/kart.cpp:L742, L1454)
	wallRestitution = {
		{ 0.0, 1.0 },
		{ 5.0, 1.0 },
		{ 20.0, 0.2 },
	},
	-- OpenKart solver-internal contact heuristics (not upstream STK constants; see docs/divergences.md)
	drivableNormalMinY = 0.5, -- normals steeper than 60 deg bounce/slide as walls
	wheelRayOriginBias = 0.30, -- m above hardpoint so compressed wheels still detect surface
	sweepSkinWidth = 0.01, -- m clearance kept outside swept hit surface
	maxSweepIters = 3, -- collide-and-slide sub-iterations per physics tick
	overlapCoreRatio = 0.5, -- core box shrink along probed axis for overlap normal recovery
	overlapPerpRatio = 0.6, -- core box shrink perpendicular to probed axis (clears 90 deg inside corners)
	maxContactResolvePasses = 3, -- positional/velocity manifold resolution iterations per tick
	-- Replaces Bullet's m_restingContactRestitutionThreshold = 2 ticks (btContactSolverInfo.h:L82)
	-- because OpenKart's stateless swept/overlap manifold does not track persistent contact lifetimes.
	restContactBounceVel = 2.0, -- m/s normal-speed threshold below which wall contact has 0 restitution
}

-- Follow camera, look-back & vertical FOV constants
-- (data/stk_config.xml:L269, src/graphics/camera/camera_normal.cpp:L102-L144, L226-L230, camera.cpp:L203, user_config.hpp:L1046-L1066)
KartTuning.camera = {
	fovDeg = 80.0, -- vertical FOV in degrees (stk_config.xml:L269, user_config.hpp:L1066, matrix4.h:L1536)
	distanceBase = 2.8, -- camera_normal.cpp:L107
	distanceSpeedFactor = 5.6, -- camera_normal.cpp:L107
	minRatio = -0.12, -- camera_normal.cpp:L104
	minDistance = 2.0, -- camera_normal.cpp:L109 (distance=1 -> min_distance=2)
	heightBase = 0.85, -- camera_normal.cpp:L118
	heightSpeedDivisor = 2.5, -- camera_normal.cpp:L118
	lookTargetY = 0.5, -- camera_normal.cpp:L144
	smoothPosition = 0.2, -- user_config.hpp:L1046
	smoothRotation = 0.125, -- user_config.hpp:L1051
	backwardDistance = 2.0, -- user_config.hpp:L1056, camera_normal.cpp:L229
	backwardUpAngleDeg = 5.0, -- user_config.hpp:L1061, camera_normal.cpp:L227
	backwardAboveKart = 0.75, -- camera_normal.cpp:L226
	reverseReturnBack = 3.0, -- camera.cpp:L203 (abs(-3) offset on CM_REVERSE -> CM_NORMAL)
	reverseReturnUp = 1.6, -- camera.cpp:L203
}

-- Difficulty multipliers (data/kart_characteristics.xml:L347-L362, L418)
KartTuning.difficulties = {
	easy = {
		enginePowerMult = 0.7,
		maxSpeedMult = 0.6,
		nitroEngineForceMult = 0.8,
		nitroMaxSpeedIncreaseMult = 0.9,
		nitroMaxMult = 0.8,
	}, -- L349, L418
	medium = {
		enginePowerMult = 0.83,
		maxSpeedMult = 0.8,
		nitroEngineForceMult = 1.0,
		nitroMaxSpeedIncreaseMult = 1.0,
		nitroMaxMult = 1.0,
	}, -- L353
	hard = {
		enginePowerMult = 0.92,
		maxSpeedMult = 0.92,
		nitroEngineForceMult = 1.0,
		nitroMaxSpeedIncreaseMult = 1.0,
		nitroMaxMult = 1.0,
	}, -- L357
	best = {
		enginePowerMult = 1.0,
		maxSpeedMult = 1.0,
		nitroEngineForceMult = 1.0,
		nitroMaxSpeedIncreaseMult = 1.0,
		nitroMaxMult = 1.0,
	}, -- L361
} :: { [string]: DifficultyPreset }

-- Kart class presets (data/kart_characteristics.xml:L365-L404)
KartTuning.kartClasses = {
	light = {
		massMult = 0.6, -- L372
		enginePowerMult = 0.8, -- L368
		maxSpeedMult = 0.95, -- L368
		brakeFactorMult = 1.0, -- L368
		reverseRatioMult = 0.8, -- L369
		nitroEngineForceMult = 0.6, -- L375
		nitroConsumptionMult = 1.0, -- base 1.0
		nitroMaxSpeedIncreaseMult = 0.9, -- L375
		nitroDurationMult = 1.0, -- L375
		turnRadius = { { 0, 2.0 }, { 10, 7.5 }, { 25, 15.0 }, { 45, 30.0 } }, -- L367
		gearSwitchRatio = { 0.1, 0.25, 0.45, 0.7, 1.0, 4.0 }, -- L370
		gearPowerIncrease = { 2.8, 2.3, 1.9, 1.5, 1.25, 1.0 }, -- L371
	},
	medium = {
		massMult = 0.75, -- L385
		enginePowerMult = 0.875, -- L381
		maxSpeedMult = 1.0, -- L381
		brakeFactorMult = 0.8, -- L381
		reverseRatioMult = 0.75, -- L382
		nitroEngineForceMult = 0.75, -- L388
		nitroConsumptionMult = 1.25, -- L388
		nitroMaxSpeedIncreaseMult = 1.0, -- base 1.0
		nitroDurationMult = 1.0, -- base 1.0
		turnRadius = { { 0, 2.3 }, { 10, 8.625 }, { 25, 17.25 }, { 45, 34.5 } }, -- L380
		gearSwitchRatio = { 0.1, 0.25, 0.45, 0.7, 1.0, 4.0 }, -- L383
		gearPowerIncrease = { 2.4, 2.0, 1.7, 1.4, 1.2, 1.0 }, -- L384
	},
	heavy = {
		massMult = 1.0, -- L397
		enginePowerMult = 1.0, -- L393
		maxSpeedMult = 1.05, -- L393
		brakeFactorMult = 0.6, -- L393
		reverseRatioMult = 0.7, -- L394
		nitroEngineForceMult = 1.0, -- L400
		nitroConsumptionMult = 1.67, -- L400
		nitroMaxSpeedIncreaseMult = 1.1, -- L400
		nitroDurationMult = 1.0, -- base 1.0
		turnRadius = { { 0, 2.6 }, { 10, 9.75 }, { 25, 19.5 }, { 45, 39.0 } }, -- L392
		gearSwitchRatio = { 0.1, 0.25, 0.45, 0.7, 1.0, 4.0 }, -- L395
		gearPowerIncrease = { 2.0, 1.7, 1.5, 1.3, 1.15, 1.0 }, -- L396
	},
} :: { [string]: KartClassPreset }

function KartTuning.buildProfile(className: string?, difficulty: string?, dims: KartDimensions?): KartProfile
	local clsName = className or "medium"
	local diffName = difficulty or "best"
	local cls = KartTuning.kartClasses[clsName] or KartTuning.kartClasses.medium
	local diff = KartTuning.difficulties[diffName] or KartTuning.difficulties.best
	local d = dims or KartTuning.chassis.tux

	local mass = KartTuning.mass.base * cls.massMult
	local collisionHeight = math.min(d.height, KartTuning.chassis.maxHeightToLengthRatio * d.length)

	-- Solid-box principal moments of inertia I_x, I_y, I_z (src/karts/kart.cpp:L659-L735)
	local ix = (1 / 12) * mass * (collisionHeight * collisionHeight + d.length * d.length)
	local iy = (1 / 12) * mass * (d.width * d.width + d.length * d.length)
	local iz = (1 / 12) * mass * (d.width * d.width + collisionHeight * collisionHeight)

	-- Bevelled hull wheel attachment hardpoints (src/karts/kart.cpp:L736-L799, stk_config.xml:L480)
	local halfW = 0.5 * d.width
	local halfZ = 0.5 * d.length * (1.0 - KartTuning.chassis.bevelFactor.z)
	local wheelY = -0.5 * collisionHeight + d.cogShiftY

	local profile: KartProfile = {
		className = clsName,
		difficulty = diffName,
		mass = mass,
		invMass = 1.0 / mass,
		enginePower = KartTuning.engine.power * cls.enginePowerMult * diff.enginePowerMult,
		maxSpeed = KartTuning.engine.maxSpeed * cls.maxSpeedMult * diff.maxSpeedMult,
		brakeFactor = KartTuning.engine.brakeFactor * cls.brakeFactorMult,
		brakeTimeIncrease = KartTuning.engine.brakeTimeIncrease,
		maxSpeedReverseRatio = KartTuning.engine.maxSpeedReverseRatio * cls.reverseRatioMult,
		nitro = {
			engineForce = KartTuning.nitro.engineForce * cls.nitroEngineForceMult * diff.nitroEngineForceMult,
			engineMult = KartTuning.nitro.engineMult,
			consumptionPerTick = KartTuning.physics.FIXED_DT * KartTuning.nitro.consumption * cls.nitroConsumptionMult,
			smallContainer = KartTuning.nitro.smallContainer,
			bigContainer = KartTuning.nitro.bigContainer,
			maxSpeedIncrease = KartTuning.nitro.maxSpeedIncrease
				* cls.nitroMaxSpeedIncreaseMult
				* diff.nitroMaxSpeedIncreaseMult,
			duration = KartTuning.nitro.duration * cls.nitroDurationMult,
			fadeOutTime = KartTuning.nitro.fadeOutTime,
			max = KartTuning.nitro.max * diff.nitroMaxMult,
			minConsumptionTicks = KartTuning.nitro.minConsumptionTicks,
		},
		turnRadius = cls.turnRadius,
		gearSwitchRatio = cls.gearSwitchRatio,
		gearPowerIncrease = cls.gearPowerIncrease,
		width = d.width,
		height = d.height,
		collisionHeight = collisionHeight,
		length = d.length,
		wheelBase = d.length,
		invInertia = {
			x = KartTuning.stability.angularFactor.x / ix,
			y = KartTuning.stability.angularFactor.y / iy,
			z = KartTuning.stability.angularFactor.z / iz,
		},
		wheelHardpoints = {
			{ x = -halfW, y = wheelY, z = halfZ }, -- 1: FL
			{ x = halfW, y = wheelY, z = halfZ }, -- 2: FR
			{ x = -halfW, y = wheelY, z = -halfZ }, -- 3: RL
			{ x = halfW, y = wheelY, z = -halfZ }, -- 4: RR
		},
	}

	return deepFreeze(profile)
end

return deepFreeze(KartTuning)
