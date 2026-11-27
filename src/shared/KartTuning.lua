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

export type SlipstreamProfile = {
	baseSpeed: number,
	length: number,
	width: number,
	innerFactor: number,
	minCollectTime: number,
	maxCollectTime: number,
	addPower: number,
	minSpeed: number,
	maxSpeedIncrease: number,
	durationFactor: number,
	fadeOutTime: number,
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
	slipstreamLengthMult: number,
	slipstreamDurationFactorMult: number,
	slipstreamFadeOutMult: number,
	startupBoostMult: number,
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
	aiDisableSlipstreamUsage: boolean,
}

export type KartDimensions = {
	width: number,
	height: number,
	length: number,
	cogShiftY: number,
}

export type KartRosterSpec = {
	id: string,
	name: string,
	className: "light" | "medium" | "heavy",
	hasWheels: boolean,
	dims: KartDimensions,
}

export type KartStatSummary = {
	kartId: string,
	name: string,
	className: "light" | "medium" | "heavy",
	massKg: number,
	maxSpeedMps: number,
	enginePowerN: number,
	accelEff: number,
	nitroConsumption: number,
	massBar: number,
	speedBar: number,
	accelBar: number,
	nitroBar: number,
}

export type KartProfile = {
	kartId: string,
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
	slipstream: SlipstreamProfile,
	turnRadius: { TablePoint },
	gearSwitchRatio: { number },
	gearPowerIncrease: { number },
	startupTimes: { number },
	startupBoosts: { number },
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

-- Slipstream constants (data/kart_characteristics.xml:L341-L343, src/graphics/slip_stream.cpp:L779-L1108, src/tracks/graph.cpp:L44-L45)
KartTuning.slipstream = {
	baseSpeed = 20.0, -- L341 base-speed="20" (m/s)
	length = 8.0, -- L341 length="8" (m)
	width = 4.0, -- L341 width="4" (m)
	innerFactor = 0.5, -- L341 inner-factor="0.5"
	minCollectTime = 2.5, -- L342 min-collect-time="2.5" (s)
	maxCollectTime = 8.0, -- L342 max-collect-time="8" (s)
	addPower = 300.0, -- L342 add-power="300" (N)
	minSpeed = 8.0, -- L342 min-speed="8" (m/s)
	maxSpeedIncrease = 3.0, -- L343 max-speed-increase="3" (m/s)
	durationFactor = 1.0, -- L343 duration-factor="1"
	fadeOutTime = 2.0, -- L343 fade-out-time="2" (s)
	quadUpdateMinSpeed = 1.0, -- src/graphics/slip_stream.cpp:L869 (m/s)
	collectorMinSpeedMargin = 2.0, -- src/graphics/slip_stream.cpp:L896 (m/s)
	outerQuadScale = 1.1, -- src/graphics/slip_stream.cpp:L779-L780, L978
	innerWidthSubtract = 0.5, -- src/graphics/slip_stream.cpp:L804 (m)
	verticalAbsLimit = 6.0, -- src/graphics/slip_stream.cpp:L952 (m)
	quadMinHeightTesting = -1.0, -- src/tracks/graph.cpp:L44 (m)
	quadMaxHeightTesting = 5.0, -- src/tracks/graph.cpp:L45 (m)
	innerCollectRate = 2.0, -- src/graphics/slip_stream.cpp:L1108
	outerDecayRate = 1.0, -- src/graphics/slip_stream.cpp:L1086
	outsideDecayRate = 3.0, -- src/graphics/slip_stream.cpp:L1088
	innerTargetScoreBase = 2000.0, -- src/graphics/slip_stream.cpp:L995
	mainTargetScoreBase = 1000.0, -- src/graphics/slip_stream.cpp:L1008
}

-- Zipper item / pad speed boost (data/kart_characteristics.xml:L249-L250)
KartTuning.zipper = {
	duration = 3.5, -- L249 duration="3.5" (s)
	force = 250.0, -- L249 force="250.0" (N)
	speedGain = 4.5, -- L249 speed-gain="4.5" (m/s)
	maxSpeedIncrease = 15.0, -- L249 max-speed-increase="15" (m/s)
	fadeOutTime = 1.0, -- L250 fade-out-time="1.0" (s)
}

-- Startup boost & early-press penalty (data/kart_characteristics.xml:L281-L282, data/stk_config.xml:L99, src/karts/kart.cpp:L2619-L2623)
KartTuning.startup = {
	penaltySec = 1.0, -- data/stk_config.xml:L99 (<startup penalty="1" />)
	penaltyTicks = 120, -- time2Ticks(1.0f) at 120 Hz
	times = { 0.3, 0.5 }, -- data/kart_characteristics.xml:L281 (s after SET starts)
	boosts = { 8.0, 4.0 }, -- data/kart_characteristics.xml:L282 (m/s)
	minSpeedFraction = 0.9, -- src/karts/kart.cpp:L2620
	engineForce = 200.0, -- src/karts/kart.cpp:L2621 (N)
	durationSec = 5.0, -- src/karts/kart.cpp:L2622 (s)
	fadeOutSec = 5.0, -- src/karts/kart.cpp:L2623 (s)
}

-- Race phase durations & lap count (src/modes/world_status.cpp:L83-L84, L322, L347, L374, L437-L438; data/stk_config.xml:L214, L217)
KartTuning.race = {
	DEFAULT_LAPS = 5, -- OpenKart divergence from STK 3 laps (docs/divergences.md)
	READY_TICKS = 120, -- 1.0 s ("Ready!", world_status.cpp:L322)
	SET_TICKS = 120, -- 1.0 s ("Set!", world_status.cpp:L347)
	GO_TICKS = 120, -- 1.0 s ("Go!", world_status.cpp:L374)
	MUSIC_END_TICKS = 960, -- 8.0 s after GO (stk_config.xml:L217)
	DELAY_FINISH_TICKS = 120, -- 1.0 s after finish (stk_config.xml:L214)
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
	-- Kart-kart collision impulse constants (src/physics/physics.cpp:L438-L558, data/stk_config.xml:L479)
	kartImpulse = 3000.0, -- N, collision="3000" (data/stk_config.xml:L479)
	kartImpulseTime = 0.1, -- s (12 ticks at 120 Hz), impulse-time="0.1" (data/stk_config.xml:L479)
	kartRatioMin = 0.8, -- src/physics/physics.cpp:L485-L486
	kartRatioMax = 1.25, -- src/physics/physics.cpp:L483-L484
	kartRamBonusMax = 2.0, -- src/physics/physics.cpp:L512-L522
	kartRamVelFloor = 2.0, -- m/s, src/physics/physics.cpp:L510, L519
}

-- AI controller constants (src/karts/controller/ai_base_controller.cpp, skidding_ai.cpp, data/stk_config.xml:L350-L424)
KartTuning.ai = {
	acceleration = 1.0, -- src/config/stk_config.cpp:L250, skidding_ai.cpp:L2056
	timeFullSteer = 0.1, -- s (data/stk_config.xml:L350, L407)
	skiddingThreshold = 2.0, -- hard/best (data/stk_config.xml:L405, L424)
	sharpCurveAngleRad = 1.5, -- rad (src/karts/controller/skidding_ai.cpp:L2725)
	oversteerFactor = 2.0, -- src/karts/controller/ai_base_controller.cpp:L149
	plungerSteerCap = 0.5, -- src/karts/controller/ai_base_controller.cpp:L198-L202
	lookaheadTimeSec = 0.65, -- s speed-scaled lookahead multiplier L(v) = clamp(|v|*0.65, 6, 28)
	lookaheadMinM = 6.0, -- m
	lookaheadMaxM = 28.0, -- m
	defaultCruiseSpeedMps = 25.0, -- m/s (AI speed is governed by KartProfile + MS_DECREASE_AI, not throttle cap)
	maxMainLateralOffsetM = 1.8, -- m (bounded within sandtrack main road min width 7.33 m -> +-3.66 m)
	maxBranchLateralOffsetM = 1.1, -- m (bounded within temple shortcut min width 6.05 m -> +-3.02 m)
}

export type AIPropsPreset = {
	timeFullSteer: number,
	skiddingThreshold: number,
	itemSkill: number,
	nitroUsage: number,
	shortcutProb: number,
	rbSkidProb: { TablePoint },
	firstSpeedCap: { TablePoint },
	lastSpeedCap: { TablePoint },
	disableSlipstreamUsage: boolean,
	shieldIncomingRadius: number,
	minStartDelay: number,
	maxStartDelay: number,
}

-- Per-difficulty AI parameters (data/stk_config.xml:L349-L426)
KartTuning.aiByDifficulty = {
	easy = {
		timeFullSteer = 0.1,
		skiddingThreshold = 4.0,
		itemSkill = 1,
		nitroUsage = 0,
		shortcutProb = 0.15,
		rbSkidProb = { { 0, 0.0 } },
		firstSpeedCap = { { -100, 1.0 }, { -50, 0.9 }, { 0, 0.85 }, { 100, 0.65 } },
		lastSpeedCap = { { -150, 0.92 }, { -50, 0.75 }, { 50, 0.6 } },
		disableSlipstreamUsage = true,
		shieldIncomingRadius = 0,
		minStartDelay = 0.3,
		maxStartDelay = 0.5,
	},
	medium = {
		timeFullSteer = 0.1,
		skiddingThreshold = 3.0,
		itemSkill = 2,
		nitroUsage = 1,
		shortcutProb = 0.40,
		rbSkidProb = { { 0, 0.0 } },
		firstSpeedCap = { { 20, 1.0 }, { 60, 0.9 }, { 100, 0.85 } },
		lastSpeedCap = { { -50, 0.94 }, { 0, 0.85 }, { 100, 0.75 } },
		disableSlipstreamUsage = false,
		shieldIncomingRadius = 10,
		minStartDelay = 0.25,
		maxStartDelay = 0.4,
	},
	hard = {
		timeFullSteer = 0.1,
		skiddingThreshold = 2.0,
		itemSkill = 3,
		nitroUsage = 2,
		shortcutProb = 0.65,
		rbSkidProb = { { -50, 1.0 }, { -20, 0.7 }, { 20, 0.2 }, { 50, 0.0 } },
		firstSpeedCap = { { 50, 1.0 }, { 150, 0.9 } },
		lastSpeedCap = { { 0, 0.96 }, { 80, 0.8 } },
		disableSlipstreamUsage = false,
		shieldIncomingRadius = 8,
		minStartDelay = 0.15,
		maxStartDelay = 0.28,
	},
	best = {
		timeFullSteer = 0.1,
		skiddingThreshold = 2.0,
		itemSkill = 4,
		nitroUsage = 3,
		shortcutProb = 0.85,
		rbSkidProb = { { 0, 1.0 } },
		firstSpeedCap = { { 0, 1.0 } },
		lastSpeedCap = { { 0, 1.0 } },
		disableSlipstreamUsage = false,
		shieldIncomingRadius = 6,
		minStartDelay = 0.15,
		maxStartDelay = 0.2,
	},
} :: { [string]: AIPropsPreset }

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
	-- Comfort divergence logged in docs/divergences.md (deadzone, critically-damped Y spring, velocity clamp, look low-pass)
	verticalDeadzoneStuds = 0.35,
	verticalStiffness = 28.0,
	verticalDamping = 10.6,
	verticalMaxVelStudsPerSec = 26.0,
	lookTargetSmoothSec = 0.12,
}

local DIFFICULTY_ALIASES: { [string]: "easy" | "medium" | "hard" | "best" } = {
	novice = "easy",
	easy = "easy",
	intermediate = "medium",
	medium = "medium",
	expert = "hard",
	hard = "hard",
	best = "best",
}

function KartTuning.normalizeDifficulty(diff: string?): "easy" | "medium" | "hard" | "best"
	if type(diff) == "string" then
		local mapped = DIFFICULTY_ALIASES[string.lower(diff)]
		if mapped ~= nil then
			return mapped :: "easy" | "medium" | "hard" | "best"
		end
	end
	return "best"
end

-- Difficulty multipliers (data/kart_characteristics.xml:L347-L362; data/stk_config.xml:L353, L372, L391, L410)
KartTuning.difficulties = {
	easy = {
		enginePowerMult = 0.7,
		maxSpeedMult = 0.6,
		nitroEngineForceMult = 1.0,
		nitroMaxSpeedIncreaseMult = 1.0,
		nitroMaxMult = 1.0,
		aiDisableSlipstreamUsage = true, -- stk_config.xml:L353
	}, -- L348-L351 (no nitro override on easy)
	medium = {
		enginePowerMult = 0.83,
		maxSpeedMult = 0.8,
		nitroEngineForceMult = 1.0,
		nitroMaxSpeedIncreaseMult = 1.0,
		nitroMaxMult = 1.0,
		aiDisableSlipstreamUsage = false, -- stk_config.xml:L372
	}, -- L352-L355
	hard = {
		enginePowerMult = 0.92,
		maxSpeedMult = 0.92,
		nitroEngineForceMult = 1.0,
		nitroMaxSpeedIncreaseMult = 1.0,
		nitroMaxMult = 1.0,
		aiDisableSlipstreamUsage = false, -- stk_config.xml:L391
	}, -- L356-L358
	best = {
		enginePowerMult = 1.0,
		maxSpeedMult = 1.0,
		nitroEngineForceMult = 1.0,
		nitroMaxSpeedIncreaseMult = 1.0,
		nitroMaxMult = 1.0,
		aiDisableSlipstreamUsage = false, -- stk_config.xml:L410
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
		slipstreamLengthMult = 0.9, -- L376 (xml_characteristic.cpp:L568 ignores collect-time)
		slipstreamDurationFactorMult = 1.0, -- L377
		slipstreamFadeOutMult = 1.0, -- L377
		startupBoostMult = 1.0, -- L373 (<startup boost="*1 *1" />)
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
		slipstreamLengthMult = 1.0, -- base 1.0
		slipstreamDurationFactorMult = 0.8, -- L389
		slipstreamFadeOutMult = 1.0, -- L389
		startupBoostMult = 0.8, -- L386 (<startup boost="*0.8 *0.8" />)
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
		slipstreamLengthMult = 1.1, -- L401 (xml_characteristic.cpp:L568 ignores collect-time)
		slipstreamDurationFactorMult = 0.6, -- L402
		slipstreamFadeOutMult = 1.0, -- L402
		startupBoostMult = 0.6, -- L398 (<startup boost="*0.6 *0.6" />)
		turnRadius = { { 0, 2.6 }, { 10, 9.75 }, { 25, 19.5 }, { 45, 39.0 } }, -- L392
		gearSwitchRatio = { 0.1, 0.25, 0.45, 0.7, 1.0, 4.0 }, -- L395
		gearPowerIncrease = { 2.0, 1.7, 1.5, 1.3, 1.15, 1.0 }, -- L396
	},
} :: { [string]: KartClassPreset }

function KartTuning.buildProfile(
	className: string?,
	difficulty: string?,
	dims: KartDimensions?,
	kartId: string?
): KartProfile
	local clsName = className or "medium"
	local diffName = KartTuning.normalizeDifficulty(difficulty)
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
		kartId = kartId or "tux",
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
		slipstream = {
			baseSpeed = KartTuning.slipstream.baseSpeed,
			length = KartTuning.slipstream.length * cls.slipstreamLengthMult,
			width = KartTuning.slipstream.width,
			innerFactor = KartTuning.slipstream.innerFactor,
			minCollectTime = KartTuning.slipstream.minCollectTime,
			maxCollectTime = KartTuning.slipstream.maxCollectTime,
			addPower = KartTuning.slipstream.addPower,
			minSpeed = KartTuning.slipstream.minSpeed,
			maxSpeedIncrease = KartTuning.slipstream.maxSpeedIncrease,
			durationFactor = KartTuning.slipstream.durationFactor * cls.slipstreamDurationFactorMult,
			fadeOutTime = KartTuning.slipstream.fadeOutTime * cls.slipstreamFadeOutMult,
		},
		turnRadius = cls.turnRadius,
		gearSwitchRatio = cls.gearSwitchRatio,
		gearPowerIncrease = cls.gearPowerIncrease,
		startupTimes = { KartTuning.startup.times[1], KartTuning.startup.times[2] },
		startupBoosts = {
			KartTuning.startup.boosts[1] * cls.startupBoostMult,
			KartTuning.startup.boosts[2] * cls.startupBoostMult,
		},
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

-- Official 18-kart STK 1.5 roster (data/official_karts.xml:L3-L20, karts/*/kart.xml).
-- No kart.xml declares per-kart characteristic overrides; all physics derive from className + dims.
KartTuning.KART_ORDER = {
	"adiumy",
	"amanda",
	"beastie",
	"emule",
	"gavroche",
	"gnu",
	"hexley",
	"kiki",
	"konqi",
	"nolok",
	"pidgin",
	"puffy",
	"sara_the_racer",
	"sara_the_wizard",
	"suzanne",
	"tux",
	"wilber",
	"xue",
}

KartTuning.karts = {
	adiumy = {
		id = "adiumy",
		name = "Adiumy",
		className = "medium",
		hasWheels = true,
		dims = { width = 0.852, height = 0.775, length = 0.943, cogShiftY = 0.2829 }, -- official_karts.xml:L3
	},
	amanda = {
		id = "amanda",
		name = "Amanda",
		className = "heavy",
		hasWheels = true,
		dims = { width = 1.119, height = 0.764, length = 1.476, cogShiftY = 0.382 }, -- official_karts.xml:L4
	},
	beastie = {
		id = "beastie",
		name = "Godette",
		className = "heavy",
		hasWheels = true,
		dims = { width = 0.837, height = 0.847, length = 1.490, cogShiftY = 0.4235 }, -- official_karts.xml:L5
	},
	emule = {
		id = "emule",
		name = "Emule",
		className = "medium",
		hasWheels = true,
		dims = { width = 0.625, height = 0.735, length = 1.146, cogShiftY = 0.3438 }, -- official_karts.xml:L6
	},
	gavroche = {
		id = "gavroche",
		name = "Gavroche",
		className = "medium",
		hasWheels = true,
		dims = { width = 0.770, height = 0.614, length = 1.272, cogShiftY = 0.307 }, -- official_karts.xml:L7
	},
	gnu = {
		id = "gnu",
		name = "Gnu",
		className = "medium",
		hasWheels = false,
		dims = { width = 0.770, height = 0.949, length = 1.345, cogShiftY = 0.4035 }, -- official_karts.xml:L8
	},
	hexley = {
		id = "hexley",
		name = "Hexley",
		className = "light",
		hasWheels = true,
		dims = { width = 0.611, height = 0.858, length = 1.608, cogShiftY = 0.429 }, -- official_karts.xml:L9
	},
	kiki = {
		id = "kiki",
		name = "Kiki",
		className = "light",
		hasWheels = true,
		dims = { width = 0.866, height = 0.974, length = 1.227, cogShiftY = 0.3681 }, -- official_karts.xml:L10
	},
	konqi = {
		id = "konqi",
		name = "Konqi",
		className = "medium",
		hasWheels = true,
		dims = { width = 0.931, height = 0.857, length = 1.588, cogShiftY = 0.4285 }, -- official_karts.xml:L11
	},
	nolok = {
		id = "nolok",
		name = "Nolok",
		className = "medium",
		hasWheels = true,
		dims = { width = 0.725, height = 0.645, length = 1.413, cogShiftY = 0.3225 }, -- official_karts.xml:L12
	},
	pidgin = {
		id = "pidgin",
		name = "Pidgin",
		className = "heavy",
		hasWheels = true,
		dims = { width = 0.781, height = 0.627, length = 1.243, cogShiftY = 0.3135 }, -- official_karts.xml:L13
	},
	puffy = {
		id = "puffy",
		name = "Puffy",
		className = "heavy",
		hasWheels = true,
		dims = { width = 1.109, height = 0.621, length = 1.573, cogShiftY = 0.3105 }, -- official_karts.xml:L14
	},
	sara_the_racer = {
		id = "sara_the_racer",
		name = "Pepper",
		className = "light",
		hasWheels = false,
		dims = { width = 0.459, height = 0.989, length = 1.152, cogShiftY = 0.3456 }, -- official_karts.xml:L15
	},
	sara_the_wizard = {
		id = "sara_the_wizard",
		name = "Sara",
		className = "medium",
		hasWheels = true,
		dims = { width = 0.500, height = 0.959, length = 1.220, cogShiftY = 0.366 }, -- official_karts.xml:L16
	},
	suzanne = {
		id = "suzanne",
		name = "Suzanne",
		className = "medium",
		hasWheels = true,
		dims = { width = 0.935, height = 0.645, length = 1.405, cogShiftY = 0.3225 }, -- official_karts.xml:L17
	},
	tux = {
		id = "tux",
		name = "Tux",
		className = "medium",
		hasWheels = true,
		dims = { width = 0.821, height = 0.675, length = 1.437, cogShiftY = 0.3375 }, -- official_karts.xml:L18
	},
	wilber = {
		id = "wilber",
		name = "Wilber",
		className = "light",
		hasWheels = true,
		dims = { width = 0.837, height = 0.871, length = 1.715, cogShiftY = 0.4355 }, -- official_karts.xml:L19
	},
	xue = {
		id = "xue",
		name = "Xue",
		className = "medium",
		hasWheels = false,
		dims = { width = 1.006, height = 0.944, length = 1.446, cogShiftY = 0.4338 }, -- official_karts.xml:L20
	},
} :: { [string]: KartRosterSpec }

function KartTuning.getKartSpec(kartId: string?): KartRosterSpec
	if type(kartId) == "string" then
		local found = KartTuning.karts[kartId]
		if found ~= nil then
			return found
		end
	end
	return KartTuning.karts.tux
end

function KartTuning.buildProfileForKart(kartId: string?, difficulty: string?): KartProfile
	local spec = KartTuning.getKartSpec(kartId)
	return KartTuning.buildProfile(spec.className, difficulty, spec.dims, spec.id)
end

-- Exact STK KartStatsWidget normalization at DIFFICULTY_BEST + HANDICAP_NONE
-- (src/guiengine/widgets/kart_stats_widget.cpp:L94-L128, src/karts/kart_properties.cpp:L713-L735).
function KartTuning.computeKartStatBars(kartId: string?): KartStatSummary
	local spec = KartTuning.getKartSpec(kartId)
	local prof = KartTuning.buildProfile(spec.className, "best", spec.dims, spec.id)
	local cls = KartTuning.kartClasses[spec.className] or KartTuning.kartClasses.medium

	local baseAccel = prof.enginePower / prof.mass
	local gearInc = prof.gearPowerIncrease
	local gearRatio = prof.gearSwitchRatio
	local currentGear = 1
	local sum = 0.0
	for i = 1, 110 do
		sum += gearInc[currentGear] * baseAccel * (150 - i)
		-- Matches C++ unsigned int integer division `i / 100 >= gear_switch_ratio[current_gear]` (kart_properties.cpp:L728)
		if (i // 100) >= gearRatio[currentGear] and currentGear < #gearInc then
			currentGear += 1
		end
	end
	local accelEff = sum / 10395.0
	local nitroCons = KartTuning.nitro.consumption * cls.nitroConsumptionMult

	return {
		kartId = spec.id,
		name = spec.name,
		className = spec.className,
		massKg = prof.mass,
		maxSpeedMps = prof.maxSpeed,
		enginePowerN = prof.enginePower,
		accelEff = accelEff,
		nitroConsumption = nitroCons,
		massBar = math.clamp(prof.mass / 3.89, 0.0, 100.0), -- kart_stats_widget.cpp:L107
		speedBar = math.clamp((prof.maxSpeed - 20.0) * 15.0, 0.0, 100.0), -- kart_stats_widget.cpp:L113
		accelBar = math.clamp(accelEff * 10.0, 0.0, 100.0), -- kart_stats_widget.cpp:L120
		nitroBar = math.clamp(90.0 / nitroCons, 0.0, 100.0), -- kart_stats_widget.cpp:L126
	}
end

return deepFreeze(KartTuning)
