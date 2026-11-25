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

## 3. World Scale Lock (`METERS_PER_STUD = 1.0`)
- **Decision (Locked):** Boundary scale is locked to **`METERS_PER_STUD = 1.0`** (`1 stud = 1.0 m`) in [Units.lua](../src/shared/Units.lua) and [coords.py](../tools/stk2rbx/coords.py), paired with pure STK kart + driver meshes (`Players.CharacterAutoLoads = false`, no Roblox Humanoids/avatars, no Roblox Terrain). See `## Scale: METERS_PER_STUD = 1.0` below.
- **Rationale & Tiling Roadmap:** At `1.0 m/stud`, `sandtrack_track.spm` (`1724.9 × 232.7 × 1287.5 m`) fits within Roblox's `2048`-stud `BasePart.Size` cap on all three axes without spatial chunking. Other upstream tracks whose mesh or submesh bounds exceed `2048 m` still require spatial bucketing, so the spatial tiler remains on the `tools/stk2rbx` roadmap for multi-track support.

## 4. `rojo serve` vs. `rojo build` Workflow
- **Decision:** Keep `rojo serve` as the live Studio development loop, and treat `rojo build default.project.json -o openkart-dev.rbxl` as a CI/verification/publish build artifact only (never hand-edit `.rbxl` files).
- **Rationale:** Changes to `default.project.json` (e.g., adding `ReplicatedStorage.Assets.Items`) require restarting `rojo serve` and reconnecting the Studio plugin to avoid live-session vs. `.rbxl` build drift (`AGENTS.md` corresponding-source rule).

## 4.1 Baked `.rbxmx` MeshParts & Cached HUD Presentation
- **Decision:** Export converted kart models with native `MeshPart.InitialSize` (`MeshSize`) baked into `assets/roblox/karts/tux.rbxmx` instead of `.model.json` so built places skip runtime `InsertService:CreateMeshPartAsync` network fetches (keeping parallel `task.spawn` hydration in `KartAssetHydrator` only as a dev fallback when `MeshSize == 0`), drop the unused `Workspace.Tracks` Rojo mount (`461` redundant BaseParts), throttle HUD timer text to `10 Hz`, and cache HUD property writes so `CanvasGroup` radial masks only re-rasterize when values change. See [perf-baseline.md](perf-baseline.md) for measured Studio server 20-kart query timings.

## 5. Offline Track Conversion Boundary (`tools/stk2rbx`) & Reflection Audit
- **Decision:** Track layouts, drivelines, checkpoints, items, and meshes are parsed offline from pinned `stk-assets` by `tools/stk2rbx` (pure Python 3 stdlib, GPLv3+) into Rojo `.model.json` / converted assets. Driveline quads and checkpoints are emitted strictly as non-collidable, non-touchable query volumes (`CanCollide = false`, `CanTouch = false`, `CanQuery = true`, `Transparency = 1`).
- **Never audit geometry from Studio `BasePart.Size`:** Roblox silently clamps `BasePart.Size` to `2048` studs per axis (for example, `MainTrack`'s raw `6543.5 × 831.2 × 4598.1`-stud extent is truncated to `2048 × 831.2 × 2048` in Studio). Always perform bounding-box and cap audits directly from source `.spm`/`.b3d` files and emitted converter JSON/reports (`RawSizeStuds*` attributes and `build/*-report.json`), never by reading `BasePart.Size` back from Studio.
- **Reflection & Winding Mandate:** Converting left-handed Irrlicht (`+Z` forward) to right-handed Roblox (`-Z` forward) applies `S = diag(1, 1, -1)`, which is an **improper reflection (`det(S) = -1`)**. Therefore `flip_triangle_winding` (`i0, i1, i2` → `i0, i2, i1`) is mathematically mandatory and must never be removed, or converted meshes will render inside-out. (By contrast, orientation matrices transform via similarity `S * R_irr * S`, so `det(R_rbx) = det(S)^2 * det(R_irr) = +1`.)
- **`sandtrack_track.spm` Empirical Triangle Audit (`11,444` tris across `16` submeshes):**
  - `11,230` triangles agree directly (`dot > 0`) with stored outward vertex normals after `S` + `flip_triangle_winding`.
  - `178` zero-dot triangles (`148` `road.jpg`, `20` `sand.png`, `10` `texture_egypte.jpg`) all have `area = 0.00000000 m²` (degenerate zero-area slivers; safe to strip on mesh export).
  - `36` negative average-normal-dot triangles (`0` in `road.jpg` out of `3,064` road triangles; `30` in `texture_egypte.jpg`, `2` in `camel_col.jpg`, `2` in `sand.png`, `2` in `woodPost.png`): `3` are degenerate micro-tris (`area <= 1e-6 m²`) and `33` are valid triangles with mixed-sign per-vertex smooth normals spanning sharp creases. **`0 / 11,444` non-degenerate triangles have all three vertex normals opposing the geometric face normal**, confirming zero flipped submeshes and zero track surface winding holes (`test_sandtrack_spm_winding_audit` in `tools/stk2rbx/test_stk2rbx.py`).

## 6. Next-Phase Sequencing: Materials, Greybox Surface Patches & Thin-Mesh Probe
- **Decision:** Validate STK handling on real per-material physics parameters (`materials.xml`: sand slowdown, non-colliding water pass-through, reset triggers, `pyramidwall` high adhesion) in `KartSolver` + Lune tests and a material-patch greybox arena first, alongside ONE small `road.jpg` thin-mesh collision probe from `sandtrack_track.spm` (`tools/stk2rbx/road_probe.py`) before building the full `.spm` exporter and spatial tiler (still required for tracks exceeding `2048 m`).
- **Rationale:** `KartSolver` + `Skidding` + `MaxSpeed` can be tested offline in Lune and interactively on color-coded surface patches while verifying Roblox thin-mesh raycast collision fidelity (`PreciseConvexDecomposition` / `.glb`) on real STK road triangles before investing in full textured visual track export.

## 7. Thin-Mesh Collision Probe Findings (`sandtrack` `road.jpg`)
- **Probe Setup:** Extracted ONE contiguous 64-triangle `road.jpg` patch (`10.58 × 1.15 × 34.45` studs at `1.0 m/stud`) from `sandtrack_track.spm` (rev `18627`) via [road_probe.py](../tools/stk2rbx/road_probe.py), applying `S = diag(1, 1, -1)` (`det = -1`) and `flip_triangle_winding`. Emitted [sandtrack_road_patch.glb](../build/probes/sandtrack_road_patch.glb) and [SandtrackRoadProbeData.lua](../src/shared/track/SandtrackRoadProbeData.lua).
- **Studio Empirical Measurements (`MeshPart`, `PreciseConvexDecomposition`):**
  - Server downward raycasts hit **`64 / 64` triangles (`100%`, zero holes)** with **`64 / 64` upward outward normals (`MinNormY = 0.9904`)** and true road grade normals (e.g., `(-0.00, 1.00, 0.03)`).
  - `CreateMeshPartAsync` preserves the mesh's local vertex origin `(0, 0, 0)` (does not re-center to bounding-box midpoint), while `PreciseConvexDecomposition` thickens zero-thickness single-sided shells slightly into thin convex hulls (`0.0257–0.1341 m` thickness, max upward hull offset `+0.0945 m` over exact triangle centroids).
  - **Runtime `EditableMesh` vs `.glb` Import Boundary:** Client console logged `EditableMesh is not accessible. Go to the Security Tab in Experience Settings to enable this API.` Thus runtime `EditableMesh` works only as a Studio server probe; production track imports will use offline `.glb` → Roblox `MeshPart` AssetIds (with spatial tiling retained on the roadmap for tracks exceeding `2048 m` on any axis).

## Scale: METERS_PER_STUD = 1.0
Decision: pure STK kart meshes + STK driver models. No visible Roblox avatars.
Rationale: 1:1 asset fidelity. STK karts include driver models; substituting R15
avatars is a divergence, not a port. Physics is unaffected (solver is SI-native).
Consequences:
- Players.CharacterAutoLoads = false; no Humanoid, no default character scripts.
- Do NOT use Roblox Terrain (4-stud voxels = 4 m at this scale). Meshes only.
- Optional avatar-display mode may be added later as an explicit divergence.
