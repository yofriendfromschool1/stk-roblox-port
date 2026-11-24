# OpenKart Architectural Decisions

This log records Month 1+ engineering decisions and any future changes to baseline assumptions (`AGENTS.md`).

---

## 1. `120 Hz` Fixed-Timestep Accumulator (`src/shared/sim/FixedStep.lua`)
- **Decision:** Run deterministic physics simulation at `PHYSICS_FPS = 120` (`FIXED_DT = 1 / 120 s`) via an accumulator decoupled from variable `RunService.Heartbeat` `dt` (`MAX_FRAME_DT = 0.25 s`, `MAX_SUBSTEPS = 8`, remainder carry, debt drop + callback when capped).
- **Rationale:** Matches STK `1.5` (`data/stk_config.xml:L147`, `src/main_loop.cpp:L460-L463`), preserves integer 120 Hz tick timers (`Skidding`, `MaxSpeed`, timed knockback/rotation, nitro), and never assumes a fixed 60 Hz `Heartbeat` rate.
- **Multiplayer Clock & Debt-Shedding Invariants:**
  - `MAX_SUBSTEPS = 8` caps simulation at `8 / 120 ≈ 66.7 ms` per frame (`~15 fps`), shedding excess accumulator debt below `~15 fps`.
  - **Single authoritative clock:** Server `simTick` is the single authoritative simulation clock. When the server sheds debt (`onDebtDropped`), it must broadcast its authoritative `simTick` + snapshot so clients reconcile to the server's tick count rather than their own.
  - **Wall-clock race timers:** Race clocks, split times, and lap timers must use wall-clock time (`workspace:GetServerTimeNow()`), never accumulated simulation ticks (`simTick * FIXED_DT`), so a lagging server never yields slower race times.

## 2. Pure-Luau Rigid-Body Integrator & SI Metric Internal Units
- **Decision:** Kart chassis motion (`position`, `orientation`, `linearVel`, `angularVel`), suspension spring-damper forces, and tire forces are integrated in pure Luau using SI metric units (`m`, `kg`, `s`, `N`, `rad`), querying track geometry via an injected `WorldQuery` interface and writing interpolated anchored `CFrame`s for visual/collider presentation.
- **Rationale:** Enables identical execution in headless Lune tests (`lune run tests/run.luau`) and Roblox Server/Client prediction & reconciliation.

## 3. World Scale Freedom (`METERS_PER_STUD`)
- **Decision:** Initial boundary scale is set to `METERS_PER_STUD = 0.28` in [Units.lua](../src/shared/Units.lua) and [coords.py](../tools/stk2rbx/coords.py), with explicit flexibility to re-evaluate before finalizing `.spm` spatial mesh chunking.
- **Rationale:** Because the pure-Luau integrator runs entirely in SI meters without Roblox gravity, friction, or dynamic rigid bodies, `METERS_PER_STUD` is purely a rendering, `float32` coordinate precision, and `BasePart.Size` (`2048`-stud limit) chunking choice at the boundary. Smaller stud extents reduce float32 drift and the number of spatial chunks needed for large tracks (`sandtrack_track.spm` spans `6543.5 × 4598.1` studs at `0.28 m/stud`).

## 4. `rojo serve` vs. `rojo build` Workflow
- **Decision:** Keep `rojo serve` as the live Studio development loop, and treat `rojo build default.project.json -o openkart-dev.rbxl` as a CI/verification/publish build artifact only (never hand-edit `.rbxl` files).
- **Rationale:** Changes to `default.project.json` (e.g., adding `Workspace.Tracks`) require restarting `rojo serve` and reconnecting the Studio plugin to avoid live-session vs. `.rbxl` build drift (`AGENTS.md` corresponding-source rule).

## 5. Offline Track Conversion Boundary (`tools/stk2rbx`) & Reflection Audit
- **Decision:** Track layouts, drivelines, checkpoints, items, and meshes are parsed offline from pinned `stk-assets` by `tools/stk2rbx` (pure Python 3 stdlib, GPLv3+) into Rojo `.model.json` / converted assets. Driveline quads and checkpoints are emitted strictly as non-collidable, non-touchable query volumes (`CanCollide = false`, `CanTouch = false`, `CanQuery = true`, `Transparency = 1`).
- **Reflection & Winding Mandate:** Converting left-handed Irrlicht (`+Z` forward) to right-handed Roblox (`-Z` forward) applies `S = diag(1, 1, -1)`, which is an **improper reflection (`det(S) = -1`)**. Therefore `flip_triangle_winding` (`i0, i1, i2` → `i0, i2, i1`) is mathematically mandatory and must never be removed, or converted meshes will render inside-out. (By contrast, orientation matrices transform via similarity `S * R_irr * S`, so `det(R_rbx) = det(S)^2 * det(R_irr) = +1`.)
- **`sandtrack_track.spm` Empirical Triangle Audit (`11,444` tris across `16` submeshes):**
  - `11,230` triangles agree directly (`dot > 0`) with stored outward vertex normals after `S` + `flip_triangle_winding`.
  - `178` zero-dot triangles (`148` `road.jpg`, `20` `sand.png`, `10` `texture_egypte.jpg`) all have `area = 0.00000000 m²` (degenerate zero-area slivers; safe to strip on mesh export).
  - `36` negative average-normal-dot triangles (`0` in `road.jpg` out of `3,064` road triangles; `30` in `texture_egypte.jpg`, `2` in `camel_col.jpg`, `2` in `sand.png`, `2` in `woodPost.png`): `3` are degenerate micro-tris (`area <= 1e-6 m²`) and `33` are valid triangles with mixed-sign per-vertex smooth normals spanning sharp creases. **`0 / 11,444` non-degenerate triangles have all three vertex normals opposing the geometric face normal**, confirming zero flipped submeshes and zero track surface winding holes (`test_sandtrack_spm_winding_audit` in `tools/stk2rbx/test_stk2rbx.py`).

## 6. Next-Phase Sequencing: Park Mesh Export, Build Greybox Kart Solver First
- **Decision:** Park full `.spm` → `.glb` mesh export and `> 2048`-stud spatial chunking until after the Month 2 drift-feel gate (`"does drift feel good"`). Next build `src/shared/sim/KartSolver.lua` as pure math against [physics-spec.md](physics-spec.md) with Lune tests (zero-velocity floor, reverse slip guard, airtime skid-charge persistence), followed by a Roblox wrapper driving on a flat greybox plane with live telemetry.
- **Rationale:** `tools/stk2rbx` XML → logic-volume conversion and mesh cap auditing are proven (`sandtrack` needs spatial chunking on 4 submeshes). Sinking weeks into `.glb` material splitting and chunking before validating drift feel on a flat plane violates the Month 2 gate priority (`AGENTS.md`).
