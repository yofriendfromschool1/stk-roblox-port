# SuperTuxKart 1.5 → OpenKart Port Map

This document maps the pinned upstream codebase (`stk-code` tag `1.5`, commit `1fb491f507216c5d181ccd85f29ff08eca003827`; see [upstream.md](upstream.md)) into two clear buckets:

1. **Engine & Platform Subsystems** — native C++ rendering, audio, GUI, physics engine, input drivers, networking transport, and OS glue **replaced by Roblox**. Do not port these.
2. **Game Logic Subsystems** — kart simulation behavior, tuning, drivelines, checkpoints, items, modes, and rules **we must port faithfully** (or adapt under an accepted divergence).

> **Maintenance rule:** Keep this table current as modules move from `Not started` → `In progress` → `Ported` / `Diverged`. Every ported Luau file must carry a header citation (`-- ported from <path>:L<start>-L<end> (STK 1.5)`), and every behavioral divergence must be logged in `docs/divergences.md`.

### Status Legend

| Status | Meaning |
|---|---|
| `Replaced by engine` | Engine/platform layer provided natively by Roblox; not ported. |
| `Not started` | Game logic to port; no Luau implementation yet. |
| `In progress` | Partially ported or active spike. |
| `Ported` | Faithfully ported to Luau with upstream citations and tests. |
| `Diverged` | Accepted architectural divergence (e.g., Bullet solver reimplementation, Roblox netcode, curated packs); behavior reproduces STK rules/feel where applicable. |
| `Deferred` | Post-gate / lower priority (do not build ahead of the Month 2 drift GO/NO-GO gate). |
| `N/A (Roblox-only)` | OpenKart helper/glue with no direct upstream counterpart. |

### Phase Priority Legend

- **P0 (Month 1–2 Gate):** Upstream pin, `tools/stk2rbx` single-track spike, fixed-timestep kart physics, drift/skid tiers, slipstream, camera, basic lap/checkpoint loop. **GO/NO-GO at end of Month 2: "does drift feel good".**
- **P1 (Post-Gate Core):** Items/powerups/projectiles, standard race & lap trial rules, Roblox server-authoritative netcode (8–20 players), HUD/menus.
- **P2 (Post-Gate Extended):** Additional modes (Follow the Leader, Battle, Capture the Flag, Soccer, Grand Prix), AI karts, track animated objects.
- **P3 (Deferred):** Story/overworld, tutorials, ghost replays, achievements, challenges, tips.

---

## Part 1: Engine & Platform Subsystems (Do NOT Port)

These upstream directories implement native C++ engine infrastructure that Roblox provides out of the box. Exceptions containing gameplay logic are called out explicitly in **Part 2**.

| Subsystem | Upstream Path(s) | Status | Roblox Replacement / Notes |
|---|---|---|---|
| **Renderer & Graphics Pipeline** | `src/graphics/*` *(except Part 2 items)*, `src/graphics/sp/*`, `lib/graphics_engine/*`, `lib/irrlicht/*`, `lib/graphics_utils/*`, `lib/libsquish/*`, `data/shaders/*` | `Replaced by engine` | Roblox rendering engine (`MeshPart`, `SurfaceAppearance`, `Lighting`, `ParticleEmitter`, `Trail`, `Beam`). Mesh/material import happens offline in `tools/stk2rbx` (`b3d`/`spm` → `.fbx`/`.glb`/Roblox meshes). |
| **Audio Engine** | `src/audio/*` (`sfx_openal.*`, `sfx_buffer.*`, `sfx_manager.*`, `music_ogg.*`, `music_manager.*`), `lib/mojoal/*` | `Replaced by engine` | Roblox `SoundService`, `Sound`, `AudioEmitter` / `AudioListener`. Game logic emits semantic audio events (engine pitch, skid tier, boost, hit); client presentation binds them to Roblox sounds. |
| **GUI Engine, Fonts & Localization** | `src/guiengine/*` (`engine.*`, `widget.*`, `widgets/*`, `layout_manager.*`, `skin.*`, `screen_loader.*`, `modaldialog.*`, `scalable_font.*`), `src/font/*`, `lib/sheenbidi/*`, `lib/tinygettext/*`, `data/skins/*`, `data/ttf/*` | `Replaced by engine` | Roblox `ScreenGui` / UI instances and `LocalizationService`. Screen/HUD layout is rebuilt natively on Roblox UI while preserving STK HUD layout & metrics (`docs/hud-spec.md`; `src/shared/hud/RaceHudMath.lua`, `src/shared/race/Standings.lua`, `src/client/HudState.lua`, `src/client/GameHud.client.lua` — `In progress`: mode-conditional visibility, speedometer, nitro gauge, elapsed timer, multi-kart rank via `Standings`, `plungerface.png` HUD obstruction (`drawPlungerInFace`), top-left Tux icon, & minimap active). |
| **UI Screen Framework & Menus** | `src/states_screens/*` (`main_menu_screen.*`, `kart_selection.*`, `tracks_and_gp_screen.*`, `options/*`, `dialogs/*`, `help/*`, `online/*`, `race_gui*`, `race_result_gui.*`, `credits.*`, etc.) | `Replaced by engine` | Native Roblox client UI controllers (lobby, kart/track vote, HUD, race results, attribution/credits). Only race HUD data formatting and credits attribution carry over conceptually. |
| **Bullet Physics Engine & World** | `lib/bullet/*`, `src/physics/physics.*`, `src/physics/triangle_mesh.*`, `src/physics/stk_dynamics_world.hpp`, `src/physics/irr_debug_drawer.*`, `src/physics/kart_motion_state.hpp`, `src/physics/user_pointer.hpp` | `Replaced by engine` | **Accepted divergence:** Bullet cannot run on Roblox. Track collision uses Roblox `Workspace` raycasts/shapecasts against converted track geometry; kart vehicle dynamics are reimplemented in a custom fixed-timestep Luau solver (see Part 2 & Part 3). |
| **Low-Level Input & Hardware Drivers** | `src/input/*` (`device_manager.*`, `keyboard_*`, `gamepad_*`, `sdl_controller.*`, `multitouch_device.*`, `wiimote*`), `lib/wiiuse/*` | `Replaced by engine` | Roblox `UserInputService` (keyboard, gamepad, touch) mapped into `KartSolver.KartInput` via `src/client/InputMapper.lua` and `src/client/TouchControls.lua` (`device_config.cpp`, `gamepad_config.cpp`, `keyboard_config.cpp`, `multitouch_device.cpp`, `race_gui_multitouch.cpp`). |
| **OS Entry Points, Filesystem & XML I/O** | `src/main.cpp`, `src/main_android.cpp`, `src/io/*` (`file_manager.*`, `xml_node.*`, `assets_android.*`, `rich_presence.*`, `utf_writer.*`), `android/`, `switch/`, `windows/` | `Replaced by engine` | Roblox DataModel runtime (`ServerScriptService`, `StarterPlayerScripts`). Upstream XML/scene parsing (`track.xml`, `scene.xml`, `quads.xml`, `graph.xml`, `kart.xml`, `kart_characteristics.xml`, `powerup.xml`) happens **offline** in `tools/stk2rbx` emitting Luau modules and `.rbxm`/`.rbxl` data. |
| **Low-Level Networking & Online Backend** | `lib/enet/*`, `lib/dnsc/*`, `src/network/network.*`, `stk_host.*`, `stk_peer.*`, `stk_ipv6.*`, `socket_address.*`, `stun_detection.hpp`, `crypto*`, `database_connector.*`, `server.*`, `servers_manager.*`, `child_loop.*`, `src/online/*` | `Replaced by engine` | **Accepted divergence:** Roblox handles transport, NAT traversal, accounts, servers, and matchmaking (`Players`, `RemoteEvent`, `UnreliableRemoteEvent`, `TeleportService`, `DataStoreService`). |
| **Dynamic Addon System** | `src/addons/*` (`addon.*`, `addons_manager.*`, `news_manager.*`, `zip.*`) | `Replaced by engine` | **Accepted divergence:** Roblox prohibits dynamic asset/code loading. Curated track/kart packs converted offline via `tools/stk2rbx` replace STK addons. |
| **Embedded Scripting VM** | `lib/angelscript/*`, `src/scriptengine/*` | `Replaced by engine` | Track triggers/scripted events run directly as Luau modules instead of AngelScript. |
| **C++ Runtime & Build Utilities** | `src/utils/*` (`aligned_array.hpp`, `can_be_deleted.hpp`, `crash_reporting.*`, `file_utils.*`, `leak_check.*`, `log.*`, `mem_utils.hpp`, `mini_glm.*`, `profiler.*`, `ptr_vector.hpp`, `singleton.hpp`, `synchronised.hpp`, `tls.hpp`, `utf8*`, `vec3.*`, etc.), `lib/mcpp/*`, `lib/simd_wrapper/*` | `Replaced by engine` | Luau standard library + Roblox types (`Vector3`, `CFrame`, `Random`, `os.clock`, `buffer`). Note: `src/utils/random_generator.*` and `src/utils/interpolation_array.hpp` may have small deterministic Luau equivalents if needed for item rolls or curves. |
| **Local User / Hardware Config** | `src/config/user_config.*`, `hardware_stats.*`, `player_profile.*`, `player_manager.*`, `favorite_status.*`, `saved_grand_prix.*` | `Replaced by engine` | Roblox player settings / `DataStoreService` persistence (post-gate). |

---

## Part 2: Engine-Adjacent Files That Contain Game Logic (Do NOT Accidentally Skip)

Several STK files live under `src/graphics/`, `src/physics/`, or `src/config/` even though they implement core gameplay mechanics or tuning data:

| Upstream File(s) | Why It Matters | Target Handling |
|---|---|---|
| `src/graphics/slip_stream.{cpp,hpp}` | Implements **slipstream gameplay math** (cone detection behind lead kart, buildup timer, ready/active duration, speed boost trigger) — not just visuals. | Port logic to `src/shared/kart/SlipStream.lua`; keep trail/wind VFX purely client-side. |
| `src/graphics/material.{cpp,hpp}`, `material_manager.{cpp,hpp}` | Stores **surface gameplay properties** (`friction`, `max_speed_fraction`, `slowdown_time`, `zipper` params, `reset`, `falling_effect`, `ignore`, `below_surface`, `surface_type`). | Extract gameplay fields in `tools/stk2rbx` into track material tables consumed by `src/shared/track/SurfaceMaterials.lua`. Ignore shader/rendering fields. |
| `src/graphics/camera/camera_normal.{cpp,hpp}`, `camera.{cpp,hpp}`, `camera_end.{cpp,hpp}` | Defines STK's **follow-camera feel** (target lag, drift yaw offset, reverse look-back, boost FOV/distance). | Reimplement on Roblox `Workspace.CurrentCamera` in `src/client/camera/KartCamera.lua` citing upstream constants. |
| `src/physics/btKart.{cpp,hpp}`, `btKartRaycast.{cpp,hpp}` | Bullet vehicle subclass containing STK's actual **driving & drift math**: wheel raycasts, suspension, lateral/sliding impulse, skidding yaw/angular velocity, zipper velocity injection, slope handling, uprighting torque, anti-capsize. | **Accepted divergence (behavioral spec):** Reimplement in `src/shared/physics/KartSolver.lua` reproducing STK's kinematics/feel with constants cited from `btKart.cpp` and `kart.cpp`. |
| `src/physics/physical_object.{cpp,hpp}` | Dynamic track hazards/props (pushable/exploding/resetting objects, soccer ball physics parameters). | Deferred to P2 (`src/server/track/PhysicalObjects.lua` / `tools/stk2rbx`). |
| `src/config/stk_config.{cpp,hpp}` + `data/stk_config.xml`, `data/kart_characteristics.xml`, `data/powerup.xml`, `data/items.xml` | Authoritative source of global physics, skid-tier, nitro, slipstream, difficulty, kart-stat, and item-weight constants. | Extract/transcribe with citations into `src/shared/KartTuning.lua` and `src/shared/ItemTuning.lua` (no magic numbers in solver). |

---

## Part 3: Game Logic Subsystems to Port

### 3.1 Core Simulation Loop & Race Phase Clock (P0)

| Upstream File(s) | Target Luau Module | Layer | Priority | Status | Notes |
|---|---|---|---|---|---|
| `src/main_loop.{cpp,hpp}` | `src/shared/sim/FixedStep.lua` | Shared | P0 | `Ported` | Fixed-timestep `120 Hz` accumulator (`FIXED_DT = 1/120`, `MAX_FRAME_DT = 0.25`, `MAX_SUBSTEPS = 8`) decoupled from variable-`dt` `Heartbeat`; Lune-tested (`tests/FixedStep.spec.luau`). |
| `src/modes/world_status.{cpp,hpp}` | `src/shared/sim/RaceState.lua` | Shared | P0 | `Ported` | Deterministic `120 Hz` race phase machine (`COUNTDOWN_3`, `READY_PHASE`, `SET_PHASE`, `GO_PHASE`, `MUSIC_PHASE`, `RACE_PHASE`, `DELAY_FINISH_PHASE`, `RESULT_DISPLAY_PHASE`) + `0.3s`/`0.5s` start-bonus window + `1.0s` early-press penalty. |

### 3.2 Kart Tuning, Stats & Characteristics (P0)

| Upstream File(s) | Target Luau Module | Layer | Priority | Status | Notes |
|---|---|---|---|---|---|
| `data/stk_config.xml`, `data/kart_characteristics.xml`, `data/official_karts.xml`, `src/config/stk_config.{cpp,hpp}`, `src/guiengine/widgets/kart_stats_widget.cpp` | `src/shared/KartTuning.lua`, `src/shared/kart/KartBoundsData.lua` | Shared | P0 | `Ported` | All global, class (`light`/`medium`/`heavy`), difficulty, suspension, engine, turn, skid, airtime constants, all 18 official kart specs/dimensions (`official_karts.xml:L3-L20`), `buildProfileForKart`, and `KartStatsWidget` bar normalization (`computeKartStatBars`) with STK `1.5` `file:Lline` citations. |
| `src/karts/abstract_characteristic.{cpp,hpp}`, `xml_characteristic.{cpp,hpp}`, `cached_characteristic.{cpp,hpp}`, `combined_characteristic.{cpp,hpp}` | `src/shared/KartTuning.lua` *(class + difficulty merge)* | Shared | P0 | `Ported` | Merged into `KartTuning.buildProfileForKart(kartId, difficulty)` for all 18 karts (`light`/`medium`/`heavy` + difficulty multipliers). |
| `src/karts/kart_properties.{cpp,hpp}`, `kart_properties_manager.{cpp,hpp}`, `official_karts.{cpp,hpp}`, `data/official_karts.xml` | `src/shared/KartTuning.lua` (`karts`, `KART_ORDER`), `src/shared/menu/CatalogData.lua` | Shared | P0 | `Ported` | Per-kart 18-kart registry generated from `kart.xml`, `official_karts.xml`, and `kart_characteristics.xml` via `tools/stk2rbx`. |

### 3.3 Kart Controller, Physics Solver, Drift/Skid & Slipstream (P0 — Month 2 Gate)

| Upstream File(s) | Target Luau Module | Layer | Priority | Status | Notes |
|---|---|---|---|---|---|
| `src/karts/controller/kart_control.{cpp,hpp}` | `src/shared/kart/KartControl.lua` | Shared | P0 | `Not started` | Normalized input struct (`steer`, `accel`, `brake`, `nitro`, `skid`, `fire`, `lookBack`, `rescue`). |
| `src/karts/controller/controller.{cpp,hpp}`, `player_controller.{cpp,hpp}`, `local_player_controller.{cpp,hpp}` | `src/client/input/PlayerInputController.lua` | Client | P0 | `Not started` | Maps Roblox keyboard/gamepad/touch input + steer smoothing into `KartControl`. |
| `src/physics/btKart.{cpp,hpp}`, `src/physics/btKartRaycast.{cpp,hpp}`, `src/physics/physics.cpp` *(KartKartCollision)* | `src/shared/sim/KartSolver.lua` | Shared | P0 | `Diverged` | **Accepted divergence:** Pure-math Luau 4-wheel raycast suspension (upward origin bias + bottom-out depenetration + `delta_vec` roll-torque projection), swept chassis collision (`WorldQuery.sweepChassis` / `Workspace:Blockcast`), Pacejka slip-angle solver, **pure-math 2D XZ OBB pairwise kart-kart collision + mass-weighted momentum exchange + STK `Physics::KartKartCollision` timed central push** (`resolveKartKartCollisions`, ID-sorted for replay determinism), + greybox wrapper (`GreyboxKartServer` / `GreyboxKartClient`). |
| `src/karts/skidding.{cpp,hpp}` | `src/shared/kart/Skidding.lua` | Shared | P0 | `Ported` | STK 6-state skid machine (`SKID_NONE`, `SKID_ACCUMULATE_LEFT/RIGHT`, `SKID_SHOW_GFX_LEFT/RIGHT`, `SKID_BREAK`), `[0.2, 0.8]` remap, `1.0s`/`3.0s` charge tiers, entry hop, and airtime charge persistence (`skidding.cpp:L376-L406, L525-L536`). |
| `src/karts/max_speed.{cpp,hpp}` | `src/shared/kart/MaxSpeed.lua` | Shared | P0 | `Ported` | Full 6 increase (`ZIPPER`, `SLIPSTREAM`, `NITRO`, `RUBBER`, `SKIDDING`, `RED_SKIDDING`) & 4 decrease (`TERRAIN`, `AI`, `BUBBLE`, `SQUASH`) enums, fade-out `engineForce = 0` gate (`max_speed.hpp:L117-L120`), slowdown fade-in & `<= 0` entry removal + `isSpeedDecreaseActive` (`kart.cpp:L1937-L1941`), airborne `9999.9` cap. |
| `src/karts/kart.{cpp,hpp}` *(nitro subset)* | `src/shared/kart/Nitro.lua` | Shared | P0 | `Ported` | STK nitro reserve, `64`-tick minimum burn commitment, proportional partial-burn duration, ground-only boost activation, `engineMult` + `MS_INCREASE_NITRO` (`kart.cpp:L2244-L2302, L2786-L2789`). |
| `src/graphics/slip_stream.{cpp,hpp}` | `src/shared/sim/Slipstream.lua` | Shared | P0 | `Ported` | 3-quad local-XZ wake with velocity-drift bending (`prevPos - pos`), `2x` inner / `1x` main collection, `1x` outer / `3x` outside decay, `2.5 s` ready threshold, on-exit `MS_INCREASE_SLIPSTREAM` (`+3.0 m/s`, `+300 N`, `2.0 s` linear fade-out) + instant speed boost; server-authoritative 120 Hz pass (`GreyboxKartServer.lua`). |
| `src/karts/kart.{cpp,hpp}`, `abstract_kart.{cpp,hpp}`, `moveable.{cpp,hpp}` | `src/shared/kart/KartState.lua` | Shared | P0 | `Not started` | Core kart tick: acceleration, braking, reverse, nitro energy tank & consumption, zipper activation, off-road/surface queries, kart-kart collision response, start-boost trigger. |
| `src/karts/abstract_kart_animation.{cpp,hpp}`, `rescue_animation.{cpp,hpp}`, `explosion_animation.{cpp,hpp}`, `cannon_animation.{cpp,hpp}` | `src/shared/sim/ItemEffectState.lua` *(explosion & rescue animations)*, `src/shared/sim/KartSolver.lua`, `src/shared/race/CheckManager.lua` | Shared | P1 *(explosion)* / P0 *(rescue)* | `In progress` | `ItemEffectState.lua` ports `ExplosionAnimation` (`1.5 s` / `180`-tick complete stop, parabolic vertical arc + spin, full driver input suppression, `7.0 s` / `840`-tick invulnerability), `RescueAnimation` (`1.2 s` / `144`-tick, `40%` lift `2.0 m` / `60%` drop onto continuously recorded driveline-quad `lastRescuePose` clamped by `nextCheckpoint`), and unifies bomb explosion, `Kart::setSquash` slowdown, and floor `ITEM_BUBBLEGUM` engine-cutoff stall with re-trigger gating. **Remaining:** `CannonAnimation`. |
| `src/graphics/camera/camera.{cpp,hpp}`, `camera_normal.{cpp,hpp}`, `camera_end.{cpp,hpp}` | `src/client/camera/KartCamera.lua` | Client | P0 | `In progress` | STK `CM_NORMAL` follow camera + `CM_REVERSE` hold-to-look-back (`B`, `PA_LOOK_BACK`, `keyboard_config.cpp:L64`, `player_controller.cpp:L222-L223`) live in `GreyboxKartClient.client.lua`; pending extraction into `KartCamera.lua` + `camera_end`. |
| `src/karts/kart_gfx.{cpp,hpp}`, `kart_model.{cpp,hpp}`, `src/graphics/skid_marks.{cpp,hpp}` | `src/client/kart/KartPresentation.lua`, `src/shared/kart/KartVisualMath.lua`, `src/server/KartAssetHydrator.lua` *(offline mesh conversion in `tools/stk2rbx/kart_emit.py`)* | Client / Shared / Server | P0 | `In progress` | Generalized 18-kart textured `MeshPart` assembly (`assets/roblox/karts/<id>.rbxmx`, including 0-wheel karts, lazily hydrated on demand via `KartAssetHydrator.hydrateKart` / `HydrateKart` remote), rigid front-wheel steer/spin/suspension (`KartVisualMath.lua` / `KartPresentation.lua`), skid sparks & Nitro exhaust active; skeletal driver lean deferred per `docs/divergences.md`. |

### 3.4 Track Data Pipeline, Drivelines, Surfaces & Checkpoints (P0–P1)

| Upstream File(s) | Target Luau Module / Tool | Layer | Priority | Status | Notes |
|---|---|---|---|---|---|
| `src/tracks/track.{cpp,hpp}`, `model_definition_loader.{cpp,hpp}`, `src/graphics/b3d_mesh_loader.*`, `sp_mesh_loader.*` | `tools/stk2rbx/` (`cli.py`, `kart_emit.py`, `kart_roster_upload.py`, `catalog_emit.py`, `road_probe.py`, `arena_emit.py`) | Tool | P0 | `In progress` | `sandtrack` logic + road probe (`stk-assets` rev `18627`), canonical dual-emitter `arena_spec.json` (with 48-node closed-loop stadium driveline → `GreyboxArenaData.lua` + `quads.xml`/`graph.xml`), and `kart_emit.py` static `SPMA`/`SPMN` 18-kart `.glb` + `.rbxmx` batch exporter (`assets/roblox/karts/<id>.rbxmx`). |
| `src/graphics/material.{cpp,hpp}`, `material_manager.{cpp,hpp}` | `src/shared/track/SurfaceMaterials.lua` | Shared | P0 | `Ported` | Pure-Luau surface material lookup (`sandtrack/materials.xml` rev `18627`: `maxSpeedFraction`, `slowdownTime`, `highTireAdhesion`, `ignore`, `reset`, `fallingEffect`, `collisionReaction`), wired into `MaxSpeed.setSlowdown` & `KartSolver`. |
| `src/tracks/terrain_info.{cpp,hpp}` | `src/shared/track/TerrainInfo.lua` | Shared | P0 | `Not started` | Ground height, surface normal, and surface material query beneath kart/projectiles using Roblox raycasts. |
| `src/tracks/quad.{cpp,hpp}`, `graph.{cpp,hpp}`, `drive_graph.{cpp,hpp}`, `drive_node.{cpp,hpp}`, `drive_node_2d.{cpp,hpp}`, `drive_node_3d.{cpp,hpp}`, `bounding_box_3d.hpp` | `src/shared/track/DriveGraph.lua` | Shared | P0 | `Not started` | Driveline quad graph, distance-down-track (`distanceFromStart`), track-width offset, shortest-path successor lookup, rescue target lookup. |
| `src/tracks/track_sector.{cpp,hpp}` | `src/shared/track/TrackSector.lua` | Shared | P0 | `Not started` | Tracks each kart's current driveline quad, distance from start, off-track detection, wrong-way detection, and last valid rescue node. |
| `src/tracks/check_manager.{cpp,hpp}`, `check_structure.{cpp,hpp}`, `check_line.{cpp,hpp}`, `check_lap.{cpp,hpp}`, `check_cylinder.{cpp,hpp}`, `check_sphere.{cpp,hpp}`, `check_cannon.{cpp,hpp}`, `check_trigger.{cpp,hpp}`, `check_goal.{cpp,hpp}` | `src/shared/race/CheckManager.lua` | Shared *(server-authoritative)* | P0 | `Ported` | Ordered `sameGroup` / `otherIds` checkpoint chains (`check-line` + `check-lap`), 5-lap completion & finish tick, monotonic checkpoint ranking for `Standings`. |
| `src/tracks/bezier_curve.{cpp,hpp}` | `src/shared/math/BezierCurve.lua` | Shared | P1 | `Not started` | Cubic Bezier evaluation for track cannons (`check_cannon` / `cannon_animation`). |
| `src/tracks/track_manager.{cpp,hpp}` | `src/shared/track/TrackRegistry.lua`, `src/shared/menu/CatalogData.lua`, `tools/stk2rbx/catalog_emit.py` | Shared / Tool | P1 | `Ported` | Curated catalog of converted playable tracks and karts (`sandtrack`, `tux`) generated from `roblox_assets.json` manifests. |
| `src/tracks/track_object.{cpp,hpp}`, `track_object_manager.{cpp,hpp}`, `track_object_presentation.{cpp,hpp}`, `src/animations/animation_base.{cpp,hpp}`, `ipo.{cpp,hpp}`, `three_d_animation.{cpp,hpp}` | `src/shared/track/TrackObjects.lua`, `src/shared/track/IpoAnimator.lua` | Shared / Server | P2 | `Not started` | Moving obstacles, Blender IPO curve animations, animated hazards, and physics objects on tracks. |
| `src/tracks/arena_graph.{cpp,hpp}`, `arena_node.{cpp,hpp}`, `arena_node_3d.hpp` | `src/shared/track/ArenaGraph.lua` | Shared | P2 | `Not started` | Navigation mesh graph for battle / CTF / soccer arenas. |

### 3.5 Items, Powerups, Projectiles & Attachments (P1)

| Upstream File(s) | Target Luau Module | Layer | Priority | Status | Notes |
|---|---|---|---|---|---|
| `data/powerup.xml`, `data/items.xml`, `src/items/powerup_manager.{cpp,hpp}` | `src/shared/ItemTuning.lua`, `src/shared/items/PowerupManager.lua`, `src/shared/items/ItemBoundsData.lua` | Shared *(invoked Server-only)* | P1 | `Ported (Slice 1)` | Full `powerup.xml` weight tables (`race`, `ftl`, `battle`, `soccer`, `tutorial`), kart-count interpolation, rank-to-section lookup, 15s no-explosive downgrade, and `StandardRace::haveBonusBoxes` (`TimeTrial` hides bonus boxes). Live server rolls use `ItemTuning.IMPLEMENTED_POWERUPS` (`9/10` active: `BUBBLEGUM`, `CAKE`, `BOWLING`, `ZIPPER`, `PLUNGER`, `SWITCH`, `SWATTER`, `RUBBERBALL`, `PARACHUTE`; `docs/divergences.md`) and run **server-only** (`GreyboxKartServer.lua`). `tools/stk2rbx/item_emit.py` exports all `16` item/powerup `.spm` meshes to `.glb` + `ItemBoundsData.lua`. |
| `src/items/item.{cpp,hpp}`, `item_manager.{cpp,hpp}`, `item_event_info.{cpp,hpp}` | `src/shared/items/ItemWorld.lua`, `src/client/items/ItemPresentation.lua`, `src/shared/sim/KartSolver.lua` | Shared / Client | P1 | `Ported` | `small-nitro` (+1) / `big-nitro` (+3) → `Nitro.collect`, `item` gift box → server-rolled `heldPowerup`/`heldPowerupCount`, 240-tick (`2.0 s`) respawn cooldowns, `180`-tick (`1.5 s`) dropped-hazard owner immunity, `disappear-counter=1`, hitbox `d^2 < 1.2` (`lc.y / 2`), STK `3.0 rad/s` spin & `1.0 s` appear-scale animation (`item.cpp:L458-L508`), per-type dispatch (`ITEM_BANANA` → attachment vs `ITEM_BUBBLEGUM` → `1.0 s`, `0.3×` `BUBBLE` slowdown + engine cutoff + `±500` torque; shielded karts bypass floor gum per `item_manager.cpp:L412-L418`). Rendered strictly as hydrated `MeshPart`s from `ReplicatedStorage.Assets.Items/*.rbxmx` (0 primitive Parts, `2 mm` bounds assertions) and bound to `GameHud.client.lua` with uploaded icons. |
| `src/items/powerup.{cpp,hpp}` | `src/shared/sim/KartSolver.lua` (`stepWithItems`, `applyParachuteAttack`) | Shared | P1 | `Ported` | Held slot (`MAX_POWERUPS = 5`), `PA_FIRE` edge-trigger (`Space`), `POWERUP_ZIPPER`, `POWERUP_BUBBLEGUM`, `POWERUP_SWITCH`, `POWERUP_SWATTER`, `POWERUP_PARACHUTE` (attaches to all karts ranked ahead via `Standings`, pops shield, `2.5 s * rankMult * speedMult`, `5×` air drag), plus `POWERUP_BOWLING`, `POWERUP_CAKE`, `POWERUP_PLUNGER`, and `POWERUP_RUBBERBALL` spawns routed through `Flyable`. |
| `src/items/projectile_manager.{cpp,hpp}`, `flyable.{cpp,hpp}` | `src/shared/sim/Flyable.lua`, `src/client/items/FlyablePresentation.lua` | Shared / Client | P1 | `Ported` | Shared deterministic `Flyable` projectile world (`getClosestKart`, `computeLeadIntercept`, lifetime, ground raycast/height-follow, wall bounce, direct & AoE splash hits, server authority, `captureSnapshot`/`applySnapshot` replay) + client `MeshPart` presentation synced over `GreyboxProtocol`. |
| `src/items/bowling.{cpp,hpp}` | `src/shared/sim/Flyable.lua` (`spawnBowling`, `step`) | Shared | P1 | `Ported` | Straight/bouncing roll (`20 s` / `2400`t lifetime, wall bounce `e = 0.4`, soft magnetic target steer `< 25 m` / `< 1.3 rad`, direct hit `EFFECT_EXPLOSION`). |
| `src/items/cake.{cpp,hpp}` | `src/shared/sim/Flyable.lua` (`spawnCake`, `step`) | Shared | P1 | `Ported` | Cone-aimed ballistic lead shot (`50 m` cone, `cos >= 0.54`, `90 m` max range, `g = 9.8`) + `EFFECT_EXPLOSION` + `6 m` AoE splash (`90`t). |
| `src/items/plunger.{cpp,hpp}`, `rubber_band.{cpp,hpp}` | `src/shared/sim/Flyable.lua` (`spawnPlunger`, `step`), `src/shared/sim/ItemEffectState.lua` | Shared | P1 | `Ported` | Forward elastic `RubberBand` pull (`70 m/s` shot, `1.0 s` / `120`t, `±1500 N` + `+7 m/s` `RUBBER` boost, snaps `> 50 m` or `< 10 m`); backward hit triggers `4.5 s` (`540`t on `best`) `plungerFaceTicks` (`GameHud` `plungerface.png` overlay + 3D `Attach_plunger_face`). |
| `src/items/rubber_ball.{cpp,hpp}` | `src/shared/sim/Flyable.lua` (`spawnRubberBall`, `step`) | Shared | P1 | `Ported` | Rank-1 targeting via `Standings`, follows `GreyboxArenaData.drivelineQuadCenters` (direct steer `< 15 m`), vertical bounce (`1.0 s` period, `4.0 m` max height), `0.5×` `2.0 s` squash on intermediate karts, `EFFECT_EXPLOSION` + `6 m` AoE on target (`5.0 s` self-target cap if Rank 1). |
| `src/items/swatter.{cpp,hpp}` | `src/shared/sim/KartSolver.lua` (`checkSwatterHits`), `src/client/kart/KartPresentation.lua` | Shared / Client | P1 | `Partial` | Timed `ATTACH_SWATTER` (`10.0 s`, bomb-removal `40/25 s`), `r^2 < 9.0 m^2` melee squash trigger routed through `ItemEffectState`, server multiplayer loop (`GreyboxKartServer`), and synced `swatter.rbxmx` attachment visual. **Deferred:** Swatter arm aiming swing animation & item-on-track squashing. |
| `src/items/attachment.{cpp,hpp}`, `attachment_manager.{cpp,hpp}`, `attachment_plugin.hpp` | `src/shared/sim/KartSolver.lua`, `src/shared/sim/ItemEffectState.lua`, `src/client/kart/KartPresentation.lua` | Shared / Client | P1 | `Ported (Rigid-Part Approx)` | Ported `ATTACH_BUBBLEGUM_SHIELD`, `ATTACH_SWATTER`, `ATTACH_PARACHUTE` (banana + `POWERUP_PARACHUTE`, `5×` air drag), `ATTACH_ANVIL`, `ATTACH_BOMB`, and `ATTACH_PLUNGER_FACE` (`plunger_face` indicator + `plungerFaceTicks` HUD overlay) with synced `.rbxmx` visuals (`docs/divergences.md`). **Deferred:** AI bomb pass on kart-kart contact. |

### 3.6 Race Modes, Ranking & Grand Prix (P1–P2)

| Upstream File(s) | Target Luau Module | Layer | Priority | Status | Notes |
|---|---|---|---|---|---|
| `src/race/race_manager.{cpp,hpp}` | `src/server/race/RaceManager.lua` | Server | P1 | `Not started` | Match configuration (mode, track, difficulty, lap count, kart roster) and match lifecycle transitions. |
| `src/modes/world.{cpp,hpp}`, `world_with_rank.{cpp,hpp}`, `linear_world.{cpp,hpp}` | `src/server/modes/World.lua`, `src/server/modes/LinearWorld.lua` | Server | P1 | `Not started` | Core race loop, starting grid placement, real-time rank computation (`lap`, `distanceFromStart`), lap timing, finish-time estimation, fastest-lap tracking, `kart_with_stats`. |
| `src/karts/kart_with_stats.{cpp,hpp}` | `src/server/race/KartStats.lua` | Server | P1 | `Not started` | Per-kart race telemetry (top speed, skids, off-track time, item hits). |
| `src/modes/standard_race.{cpp,hpp}` | `src/server/modes/StandardRace.lua` | Server | P1 | `Not started` | Standard multi-lap race + Time Trial variant (`MINOR_MODE_NORMAL_RACE`, `MINOR_MODE_TIME_TRIAL`). |
| `src/modes/lap_trial.{cpp,hpp}` | `src/server/modes/LapTrial.lua` | Server | P1 | `Not started` | Timed lap-count mode (`MINOR_MODE_LAP_TRIAL`). |
| `src/modes/follow_the_leader.{cpp,hpp}` | `src/server/modes/FollowTheLeader.lua` | Server | P2 | `Not started` | Elimination timer mode (`MINOR_MODE_FOLLOW_LEADER`). |
| `src/modes/three_strikes_battle.{cpp,hpp}`, `free_for_all.{cpp,hpp}` | `src/server/modes/BattleModes.lua` | Server | P2 | `Not started` | Arena battle modes (3-Strikes & Free-For-All). |
| `src/modes/capture_the_flag.{cpp,hpp}`, `ctf_flag.{cpp,hpp}` | `src/server/modes/CaptureTheFlag.lua` | Server | P2 | `Not started` | Arena CTF mode and flag carry/return state. |
| `src/modes/soccer_world.{cpp,hpp}` | `src/server/modes/SoccerWorld.lua` | Server | P2 | `Not started` | Arena soccer mode, ball scoring, and team resets. |
| `src/modes/easter_egg_hunt.{cpp,hpp}` | `src/server/modes/EasterEggHunt.lua` | Server | P2 | `Deferred` | Collectible hunt mode. |
| `src/race/grand_prix_data.{cpp,hpp}`, `grand_prix_manager.{cpp,hpp}`, `data/grandprix/*` | `src/shared/race/GrandPrix.lua` | Shared / Server | P2 | `Not started` | Multi-race cup definitions and point standings. |
| `src/race/highscores.{cpp,hpp}`, `highscore_manager.{cpp,hpp}` | `src/server/race/Leaderboards.lua` | Server | P2 | `Not started` | Best lap / race times backed by Roblox `OrderedDataStore`. |

### 3.7 Networking, Prediction & Reconciliation (P1 — Accepted Divergence)

| Upstream File(s) | Target Luau Module | Layer | Priority | Status | Notes |
|---|---|---|---|---|---|
| `src/network/protocols/server_lobby.{cpp,hpp}`, `client_lobby.{cpp,hpp}`, `lobby_protocol.{cpp,hpp}`, `game_setup.{cpp,hpp}`, `peer_vote.hpp`, `ranking.{cpp,hpp}` | `src/server/net/LobbyServer.lua`, `src/client/net/LobbyClient.lua` | Server / Client | P1 | `Diverged` | **Accepted divergence:** Roblox 8–20 player lobby, track/mode voting, kart selection, and match start synchronization over `RemoteEvent`. |
| `src/network/race_event_manager.{cpp,hpp}`, `protocols/game_protocol.{cpp,hpp}`, `game_events_protocol.{cpp,hpp}`, `src/items/network_item_manager.{cpp,hpp}` | `src/server/net/RaceReplicator.lua`, `src/client/net/RaceClientSync.lua` | Server / Client | P1 | `Diverged` | **Accepted divergence:** Server-authoritative state snapshots (`UnreliableRemoteEvent`) + reliable gameplay events (pickups, hits, laps, finishes). |
| `src/karts/kart_rewinder.{cpp,hpp}`, `src/network/rewind_manager.{cpp,hpp}`, `rewind_queue.{cpp,hpp}`, `rewind_info.{cpp,hpp}`, `rewinder.{cpp,hpp}`, `event_rewinder.{cpp,hpp}`, `smooth_network_body.{cpp,hpp}`, `network_timer_synchronizer.hpp` | `src/client/GreyboxKartClient.client.lua`, `src/shared/net/ReconciliationSmoother.lua` | Client / Shared | P1 | `Diverged` | **Accepted divergence:** Fixed-step snapshot application + unacknowledged input replay reconciliation with exponential position/rotation error smoothing (`ReconciliationSmoother`, `tau = 0.10 s`, `snap > 3.0 m`); replaces STK ENet global rewind & `SmoothNetworkBody`. |

### 3.8 AI Controllers (P2)

| Upstream File(s) | Target Luau Module | Layer | Priority | Status | Notes |
|---|---|---|---|---|---|
| `src/karts/controller/ai_base_controller.{cpp,hpp}`, `ai_base_lap_controller.{cpp,hpp}`, `skidding_ai.{cpp,hpp}`, `ai_properties.{cpp,hpp}`, `end_controller.{cpp,hpp}` | `src/shared/ai/AIController.lua`, `src/shared/race/TestDummyKart.lua`, `src/shared/KartTuning.lua` | Shared / Server | P2 | `Ported` | Ported `SkiddingAI` (`findNonCrashingPoint`, `determineTrackDirection`, `handleCurve`, `canSkid` -> `skidControl`/`drift`, `computeSpeedCap` -> `MaxSpeed.setSlowdown("AI")`, `handleItems` with `itemSkill`, `handleNitroAndZipper` with `nitroUsage`, `steerToPoint`, `time_full_steer`, `EndController`, `stk_config.xml` `aiByDifficulty` params), plus `computePath` fork/shortcut branching (`drivelineBranches`) and per-kart lateral lane offsets driven by `KartState.rngState`. |
| `src/karts/controller/arena_ai.{cpp,hpp}`, `battle_ai.{cpp,hpp}`, `soccer_ai.{cpp,hpp}`, `spare_tire_ai.{cpp,hpp}` | `src/server/ai/ArenaAIController.lua` | Server | P2 | `Deferred` | Arena/battle/soccer AI controllers. |
| `src/karts/controller/network_ai_controller.*`, `network_player_controller.hpp`, `test_ai.*` | — | — | — | `Replaced by engine` | Server directly drives AI karts; Roblox input replication replaces `NetworkPlayerController`. |

### 3.9 Replays, Ghosts & Single-Player Progression (P3 — Deferred)

| Upstream File(s) | Target Luau Module | Layer | Priority | Status | Notes |
|---|---|---|---|---|---|
| `src/replay/*`, `src/karts/ghost_kart.{cpp,hpp}`, `src/karts/controller/ghost_controller.{cpp,hpp}`, `src/race/history.{cpp,hpp}` | `src/shared/replay/GhostReplay.lua` | Shared | P3 | `Deferred` | Time-trial ghost recording & playback. |
| `src/achievements/*`, `data/achievements.xml` | `src/server/progression/Achievements.lua` | Server | P3 | `Deferred` | Roblox Badges / in-game achievements. |
| `src/challenges/*`, `data/challenges/*`, `src/modes/overworld.{cpp,hpp}`, `tutorial_world.{cpp,hpp}`, `tutorial_utils.{cpp,hpp}` | — | — | P3 | `Deferred` | Story mode, unlock tree, overworld, and tutorial. |
| `src/modes/cutscene_world.{cpp,hpp}`, `demo_world.{cpp,hpp}`, `profile_world.{cpp,hpp}`, `src/tips/*`, `data/tips.xml` | — | — | P3 | `Deferred` | Cutscenes, attract-mode demo, benchmark profile world, loading tips. |

---

## Part 4: Roblox-Only & Scaffold Modules

Files in OpenKart with no direct upstream STK C++ file.

| Luau Module | Layer | Status | Notes |
|---|---|---|---|
| `src/shared/Units.lua` | Shared | `N/A (Roblox-only)` | Meters ↔ studs (`1 stud = 1.0 m`), `m/s` ↔ `studs/s`, `m/s^2` ↔ `studs/s^2`, `km/h` conversions. Pure Luau, Lune-tested (`tests/Units.spec.luau`). |
| `src/shared/Hello.lua` | Shared | `N/A (Roblox-only)` | Initial Rojo sync smoke-test module (remove once gameplay modules land). |
| `src/server/Main.server.lua` | Server | `N/A (Roblox-only)` | Server entry point bootstrap (currently logs scaffold greeting). |
| `src/shared/menu/MenuFlow.lua` | Shared | `Ported` | Pure-Luau pre-race menu state machine (`MENU -> MODE -> TRACK -> KART -> CONFIG -> LOADING -> RACING`, `OPTIONS`, `ABOUT`) + `sanitizeSessionConfig` (`src/states_screens/{main_menu_screen,race_setup_screen,track_info_screen}.cpp`). |
| `src/shared/menu/MenuIcons.lua` | Shared | `Ported` | Uploaded STK 1.5 GUI icon asset IDs (`assets/gui/menu/roblox_assets.json`). |
| `src/shared/settings/SettingsSchema.lua` | Shared | `Ported` | Pure-Luau user settings defaults, sanitization, graphics presets, and camera scales (`data/gui/screens/options/options_{video,audio,ui,input}.stkgui`). |
| `src/server/SettingsStore.lua` | Server | `N/A (Roblox-only)` | `DataStoreService` (`OpenKartPlayerSettings_v1`) persistence with session-only fallback (`SettingsSync` remote). |
| `src/client/ClientSettingsState.lua`, `SettingsApplier.lua`, `ClientSessionState.lua` | Client | `N/A (Roblox-only)` | Client reactive settings/session stores and client-local `BloomEffect`/`SunRaysEffect` applier. |
| `src/client/menu/{ClassicSkin.lua,MenuBackdrop.lua,OptionsPanel.lua,LobbyPanel.lua,MenuGui.client.lua}`, `src/shared/menu/KartSelectMath.lua` | Client / Shared | `Ported` | STK `classic` skin 9-slice helper + `.stkgui`-matched main menu, lazy rotating 3D kart `ViewportFrame` backdrop, class-filtered (`All`/`Light`/`Medium`/`Heavy`) & searchable 18-kart selection with 4-bar `KartStatsWidget`, 4-tab Options panel, Online Lobby UI, and About credits screen. |
| `src/shared/net/LobbyState.lua`, `src/server/ReservedLobbyService.lua` | Shared / Server | `Diverged` | Server-authoritative in-server lobby (host transfer, server password gate, ready/lock/return-to-lobby) + `MemoryStoreService`/`TeleportService` reserved server scaffold (published place required). |
