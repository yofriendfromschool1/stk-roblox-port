# Walkthrough: Raycast Kart Physics Specification

## Changes Made

- **Created [physics-spec.md](physics-spec.md)** (562 lines) specifying OpenKart's custom Luau raycast kart physics solver grounded in pinned SuperTuxKart `1.5` (`C:\dev\stk-code`, commit `1fb491f507216c5d181ccd85f29ff08eca003827`).
- No code files (`.lua` / `.luau`) were modified.

### Specification Coverage
1. **Locked Architectural Decisions & Coordinate Frames (Section 1):** `120 Hz` (`1/120 s`) fixed timestep, SI meters internally converting at the Roblox boundary via [Units.lua](../src/shared/Units.lua) (`1 stud = 0.28 m`, `+Z` ↔ `-Z` forward flip), deterministic pure-Luau rigid-body integrator driving an anchored `CFrame`, and parameterized slip-angle → grip curve paired with STK's `Skidding` state machine (with tunable `driftRearGripScale = 1.0`).
2. **Fixed Timestep & 13-Stage Per-Tick Pipeline (Section 2):** Accumulator with `MAX_FRAME_DT = 1/15 s`, `MAX_SUBSTEPS = 8`, render interpolation, and exact causal tick ordering mirroring `Kart::update` → `Kart::updatePhysics` → `btKart::updateVehicle`.
3. **Chassis Geometry & 4-Wheel Raycast Suspension (Section 3):** Bevelled hull (`0.5, 0.0, 0.3`), CoG bottom shift, `0.30 m` rest / `0.29 m` travel / `1.09 m` ray length, `0.95×` inward seam-snag fallback, asymmetric spring-damper (`stiffness = 280`, compression `15`, relaxation `35`, critically damped rebound), off-ground `trackConnectionAccel = 2.0 m/s²` per wheel, and 4-wheel speed-proportional downforce (`downwardImpulseFactor = 5.0`).
4. **Powertrain, Steering & Slip-Angle → Grip Curve (Section 4):** Gear multiplier table, `applyAirFriction` (`+39.33 * |v| * m/350 - 5 * |v|^1.5`), `0.4/0.6` 4WD wheel split (`2.0×` total force), braking ramp & `< 5 m/s` parking brake, two-zone digital steer ramp (`0.225 s` full lock / `0.10 s` reset), speed-indexed turn-radius table `R(v)`, Pacejka-lite slip-angle → grip curve (`B = 12.0, C = 1.35, E = -0.5, μ_peak = 2.8`) with overshoot impulse guard, steep-slope sliding (`dot(n, up) ∈ [0.85, 0.90]`), and `MaxSpeed` boost/slowdown layering.
5. **Drift State Machine with Charge Tiers (Section 5):** Complete 6-state Mermaid state diagram (`SKID_NONE`, `SKID_ACCUMULATE_{LEFT,RIGHT}`, `SKID_SHOW_GFX_{LEFT,RIGHT}`, `SKID_BREAK`), `SC_NO_DIRECTION` latch, `0.4 s` graphical hop (`0.196 m` apex), `[0.2, 0.8]` locked-direction steering remap, visual yaw clamp `[-1, 1] rad`, Tier 0 / Tier 1 (`1.0 s`, `+4.5 m/s`, `+2.25 m/s` instant) / Tier 2 (`3.0 s`, `+6.5 m/s`, `+3.25 m/s` instant, supersedes Tier 1), and post-skid `setTimedRotation` alignment.
6. **Airtime Physics & Recovery (Section 6):** Partial vs. 0-wheel airborne rules, angular velocity damping (`0.95, 0.25, 0.95`), zeroed airborne linear damping, `smoothFlyingImpulse = 250` auto-leveling, `17.81 m/s²` effective airborne gravity, jump animation trigger, and upside-down (`> 60°` & `< 3 m/s`) / void-fall (`> 17 m` below AABB or `> 25 m` from sector) auto-rescue.
7. **Knockback Impulses & Collisions (Section 7):** Non-stacking timed central impulses with tire-slip release (`skidInfo = 0`), kart–kart mass/speed/ramming squared-factor lateral knockback (`3000 * f²` over `0.1 s`), speed-indexed wall restitution (`1.0 → 0.2`) + `PUSH_BACK` bumpers (`-4000` + `2.0 s` lockout), and item disruptions (explosion, bubblegum, plunger rubber band, anvil, parachute, swatter).
8. **Measurable Handling-Targets Table (Section 8):** 31 quantitative metrics in both SI and Roblox studs (`tux` Medium reference on `best` difficulty) mapped directly to future headless Lune test harnesses.
9. **Upstream Constants Inventory (Section 9):** Complete extraction checklist for `src/shared/KartTuning.lua` distinguishing `XML` parameters from hardcoded `C++` constants across 7 subsystems.

## Validation Results

- **Upstream Citation Audit:** Verified `122/122` `file:Lstart[-Lend]` references in `docs/physics-spec.md` exist within valid line bounds of `C:\dev\stk-code` (0 errors), and spot-checked 15 key lines verbatim against `data/stk_config.xml`, `data/kart_characteristics.xml`, `data/official_karts.xml`, `src/tracks/track.cpp`, `src/karts/kart.cpp`, `src/karts/kart_properties.cpp`, and `src/physics/btKart.cpp`.
- **Cross-Reference & Link Audit:** Fixed a Section 7 → Section 8 reference on line 7 and replaced a dead relative link to the not-yet-created `src/shared/KartTuning.lua` with inline code formatting.
- **Working Tree Check:** Confirmed via `git status --short` that only documentation under `docs/` was added; no `.lua`/`.luau` source or test files were altered.

## Next Steps

- Record the accepted Bullet physics divergence and `120 Hz` / pure-Luau integrator decisions in `docs/divergences.md` and `docs/decisions.md` when starting Month 1 physics implementation.
- Extract the Section 9 constants into `src/shared/KartTuning.lua` and implement `KartSolver` + Lune handling-target tests against Section 8.
