# OpenKart Architectural Decisions

This log records Month 1+ engineering decisions and any future changes to baseline assumptions (`AGENTS.md`).

---

## 1. `120 Hz` Fixed-Timestep Accumulator (`src/shared/sim/FixedStep.lua`)
- **Decision:** Run deterministic physics simulation at `PHYSICS_FPS = 120` (`FIXED_DT = 1 / 120 s`) via an accumulator decoupled from variable `RunService.Heartbeat` `dt` (`MAX_FRAME_DT = 0.25 s`, `MAX_SUBSTEPS = 8`, remainder carry, debt drop + callback when capped).
- **Rationale:** Matches STK `1.5` (`data/stk_config.xml:L147`, `src/main_loop.cpp:L460-L463`), preserves integer 120 Hz tick timers (`Skidding`, `MaxSpeed`, timed knockback/rotation, nitro), and never assumes a fixed 60 Hz `Heartbeat` rate.

## 2. Pure-Luau Rigid-Body Integrator & SI Metric Internal Units
- **Decision:** Kart chassis motion (`position`, `orientation`, `linearVel`, `angularVel`), suspension spring-damper forces, and tire forces are integrated in pure Luau using SI metric units (`m`, `kg`, `s`, `N`, `rad`), querying track geometry via an injected `WorldQuery` interface and writing interpolated anchored `CFrame`s for visual/collider presentation.
- **Rationale:** Enables identical execution in headless Lune tests (`lune run tests/run.luau`) and Roblox Server/Client prediction & reconciliation.

## 3. World Scale Freedom (`METERS_PER_STUD`)
- **Decision:** Initial boundary scale is set to `METERS_PER_STUD = 0.28` in [Units.lua](../src/shared/Units.lua) and [coords.py](../tools/stk2rbx/coords.py), with explicit flexibility to re-evaluate before finalizing `.spm` spatial mesh chunking.
- **Rationale:** Because the pure-Luau integrator runs entirely in SI meters without Roblox gravity, friction, or dynamic rigid bodies, `METERS_PER_STUD` is purely a rendering, `float32` coordinate precision, and `BasePart.Size` (`2048`-stud limit) chunking choice at the boundary. Smaller stud extents reduce float32 drift and the number of spatial chunks needed for large tracks (`sandtrack_track.spm` spans `6543.5 × 4598.1` studs at `0.28 m/stud`).

## 4. `rojo serve` vs. `rojo build` Workflow
- **Decision:** Keep `rojo serve` as the live Studio development loop, and treat `rojo build default.project.json -o openkart-dev.rbxl` as a CI/verification/publish build artifact only (never hand-edit `.rbxl` files).
- **Rationale:** Changes to `default.project.json` (e.g., adding `Workspace.Tracks`) require restarting `rojo serve` and reconnecting the Studio plugin to avoid live-session vs. `.rbxl` build drift (`AGENTS.md` corresponding-source rule).

## 5. Offline Track Conversion Boundary (`tools/stk2rbx`)
- **Decision:** Track layouts, drivelines, checkpoints, items, and meshes are parsed offline from pinned `stk-assets` by `tools/stk2rbx` (pure Python 3 stdlib, GPLv3+) into Rojo `.model.json` / converted assets. Driveline quads and checkpoints are emitted strictly as non-collidable, non-touchable query volumes (`CanCollide = false`, `CanTouch = false`, `CanQuery = true`, `Transparency = 1`).
- **Rationale:** Prevents Studio manual-build drift, enforces LH (`+Z` forward) → RH (`-Z` forward) reflection symmetry (`S = diag(1, 1, -1)` + triangle winding reversal `i0, i1, i2 -> i0, i2, i1`), and avoids kart wheels colliding with invisible driveline boxes.
