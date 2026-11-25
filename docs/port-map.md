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
| **GUI Engine, Fonts & Localization** | `src/guiengine/*` (`engine.*`, `widget.*`, `widgets/*`, `layout_manager.*`, `skin.*`, `screen_loader.*`, `modaldialog.*`, `scalable_font.*`), `src/font/*`, `lib/sheenbidi/*`, `lib/tinygettext/*`, `data/skins/*`, `data/ttf/*` | `Replaced by engine` | Roblox `ScreenGui` / UI instances and `LocalizationService`. Screen/HUD layout is rebuilt natively on Roblox UI while preserving STK HUD layout & metrics (`docs/hud-spec.md`; `src/shared/hud/RaceHudMath.lua`, `src/shared/race/Standings.lua`, `src/client/HudState.lua`, `src/client/GameHud.client.lua` — `In progress`: mode-conditional visibility, speedometer, nitro gauge, elapsed timer, gauge-center rank, top-left Tux icon, & minimap active; unbuilt slots inactive). |
| **UI Screen Framework & Menus** | `src/states_screens/*` (`main_menu_screen.*`, `kart_selection.*`, `tracks_and_gp_screen.*`, `options/*`, `dialogs/*`, `help/*`, `online/*`, `race_gui*`, `race_result_gui.*`, `credits.*`, etc.) | `Replaced by engine` | Native Roblox client UI controllers (lobby, kart/track vote, HUD, race results, attribution/credits). Only race HUD data formatting and credits attribution carry over conceptually. |
| **Bullet Physics Engine & World** | `lib/bullet/*`, `src/physics/physics.*`, `src/physics/triangle_mesh.*`, `src/physics/stk_dynamics_world.hpp`, `src/physics/irr_debug_drawer.*`, `src/physics/kart_motion_state.hpp`, `src/physics/user_pointer.hpp` | `Replaced by engine` | **Accepted divergence:** Bullet cannot run on Roblox. Track collision uses Roblox `Workspace` raycasts/shapecasts against converted track geometry; kart vehicle dynamics are reimplemented in a custom fixed-timestep Luau solver (see Part 2 & Part 3). |
| **Low-Level Input & Hardware Drivers** | `src/input/*` (`device_manager.*`, `keyboard_*`, `gamepad_*`, `sdl_controller.*`, `multitouch_device.*`, `wiimote*`), `lib/wiiuse/*` | `Replaced by engine` | Roblox `UserInputService` / `ContextActionService` (keyboard, gamepad, touch) mapped into STK's logical `KartControl` input struct (`steer`, `accel`, `brake`, `nitro`, `skid`, `fire`, `look_back`, `rescue`). |
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
| `src/modes/world_status.{cpp,hpp}` | `src/shared/race/RacePhase.lua` | Shared | P0 | `Not started` | Race phase state machine (`SETUP_PHASE`, `READY_PHASE`, `SET_PHASE`, `GO_PHASE`, `RACE_PHASE`, `DELAY_FINISH_PHASE`, `RESULT_DISPLAY_PHASE`) + start-boost timing window. |

### 3.2 Kart Tuning, Stats & Characteristics (P0)

| Upstream File(s) | Target Luau Module | Layer | Priority | Status | Notes |
|---|---|---|---|---|---|
| `data/stk_config.xml`, `data/kart_characteristics.xml`, `src/config/stk_config.{cpp,hpp}` | `src/shared/KartTuning.lua` | Shared | P0 | `Ported` | All global, class (`light`/`medium`/`heavy`), difficulty, suspension, engine, turn, skid, and airtime constants with STK `1.5` `file:Lline` citations (`buildProfile` defaults to Medium `tux`). |
| `src/karts/abstract_characteristic.{cpp,hpp}`, `xml_characteristic.{cpp,hpp}`, `cached_characteristic.{cpp,hpp}`, `combined_characteristic.{cpp,hpp}` | `src/shared/kart/KartCharacteristics.lua` | Shared | P0 | `Not started` | Hierarchical stat inheritance & difficulty/kart-type combining (light / medium / heavy / base). |
| `src/karts/kart_properties.{cpp,hpp}`, `kart_properties_manager.{cpp,hpp}`, `official_karts.{cpp,hpp}`, `data/official_karts.xml` | `src/shared/kart/KartProperties.lua` | Shared | P0 | `Not started` | Per-kart stats registry generated from `kart.xml` + `kart_characteristics.xml` via `tools/stk2rbx`. |

### 3.3 Kart Controller, Physics Solver, Drift/Skid & Slipstream (P0 — Month 2 Gate)

| Upstream File(s) | Target Luau Module | Layer | Priority | Status | Notes |
|---|---|---|---|---|---|
| `src/karts/controller/kart_control.{cpp,hpp}` | `src/shared/kart/KartControl.lua` | Shared | P0 | `Not started` | Normalized input struct (`steer`, `accel`, `brake`, `nitro`, `skid`, `fire`, `lookBack`, `rescue`). |
| `src/karts/controller/controller.{cpp,hpp}`, `player_controller.{cpp,hpp}`, `local_player_controller.{cpp,hpp}` | `src/client/input/PlayerInputController.lua` | Client | P0 | `Not started` | Maps Roblox keyboard/gamepad/touch input + steer smoothing into `KartControl`. |
| `src/physics/btKart.{cpp,hpp}`, `src/physics/btKartRaycast.{cpp,hpp}` | `src/shared/sim/KartSolver.lua` | Shared | P0 | `Diverged` | **Accepted divergence:** Pure-math Luau 4-wheel raycast suspension (upward origin bias + bottom-out depenetration + `delta_vec` roll-torque projection), swept chassis collision (`WorldQuery.sweepChassis` / `Workspace:Blockcast`), Pacejka slip-angle solver, + greybox wrapper (`GreyboxKartServer` / `GreyboxKartClient`). |
| `src/karts/skidding.{cpp,hpp}` | `src/shared/kart/Skidding.lua` | Shared | P0 | `Ported` | STK 6-state skid machine (`SKID_NONE`, `SKID_ACCUMULATE_LEFT/RIGHT`, `SKID_SHOW_GFX_LEFT/RIGHT`, `SKID_BREAK`), `[0.2, 0.8]` remap, `1.0s`/`3.0s` charge tiers, entry hop, and airtime charge persistence (`skidding.cpp:L376-L406, L525-L536`). |
| `src/karts/max_speed.{cpp,hpp}` | `src/shared/kart/MaxSpeed.lua` | Shared | P0 | `Ported` | Full 6 increase (`ZIPPER`, `SLIPSTREAM`, `NITRO`, `RUBBER`, `SKIDDING`, `RED_SKIDDING`) & 4 decrease (`TERRAIN`, `AI`, `BUBBLE`, `SQUASH`) enums, fade-out `engineForce = 0` gate (`max_speed.hpp:L117-L120`), slowdown fade-in, airborne `9999.9` cap. |
| `src/karts/kart.{cpp,hpp}` *(nitro subset)* | `src/shared/kart/Nitro.lua` | Shared | P0 | `Ported` | STK nitro reserve, `64`-tick minimum burn commitment, proportional partial-burn duration, ground-only boost activation, `engineMult` + `MS_INCREASE_NITRO` (`kart.cpp:L2244-L2302, L2786-L2789`). |
| `src/graphics/slip_stream.{cpp,hpp}` | `src/shared/kart/SlipStream.lua` | Shared | P0 | `Not started` | Slipstream detection zone behind ahead karts, collect/ready/active timers, speed bonus integration with `MaxSpeed`. |
| `src/karts/kart.{cpp,hpp}`, `abstract_kart.{cpp,hpp}`, `moveable.{cpp,hpp}` | `src/shared/kart/KartState.lua` | Shared | P0 | `Not started` | Core kart tick: acceleration, braking, reverse, nitro energy tank & consumption, zipper activation, off-road/surface queries, kart-kart collision response, start-boost trigger. |
| `src/karts/abstract_kart_animation.{cpp,hpp}`, `rescue_animation.{cpp,hpp}`, `explosion_animation.{cpp,hpp}`, `cannon_animation.{cpp,hpp}` | `src/shared/kart/KartAnimations.lua` | Shared | P0 | `Not started` | Gameplay-controlling animation states (out-of-bounds rescue lift & placement on driveline, hit spinout/explosion flight, cannon Bezier flight). |
| `src/graphics/camera/camera.{cpp,hpp}`, `camera_normal.{cpp,hpp}`, `camera_end.{cpp,hpp}` | `src/client/camera/KartCamera.lua` | Client | P0 | `In progress` | STK `CM_NORMAL` follow camera + `CM_REVERSE` hold-to-look-back (`B`, `PA_LOOK_BACK`, `keyboard_config.cpp:L64`, `player_controller.cpp:L222-L223`) live in `GreyboxKartClient.client.lua`; pending extraction into `KartCamera.lua` + `camera_end`. |
| `src/karts/kart_gfx.{cpp,hpp}`, `kart_model.{cpp,hpp}`, `src/graphics/skid_marks.{cpp,hpp}` | `src/client/kart/KartPresentation.lua` | Client | P0 | `Not started` | Visual-only presentation: wheel spin/steer, chassis tilt, skid-tier spark color, nitro flame, slipstream lines, skid marks. |

### 3.4 Track Data Pipeline, Drivelines, Surfaces & Checkpoints (P0–P1)

| Upstream File(s) | Target Luau Module / Tool | Layer | Priority | Status | Notes |
|---|---|---|---|---|---|
| `src/tracks/track.{cpp,hpp}`, `model_definition_loader.{cpp,hpp}`, `src/graphics/b3d_mesh_loader.*`, `sp_mesh_loader.*` | `tools/stk2rbx/` | Tool | P0 | `In progress` | Month 1 spike on `sandtrack` (`stk-assets` rev `18627`): parses `track.xml`, `quads.xml`, `graph.xml`, `scene.xml`, inspects `.spm`/`.b3d` meshes, audits Roblox caps, emits `assets/roblox/tracks/sandtrack.model.json`. |
| `src/graphics/material.{cpp,hpp}`, `material_manager.{cpp,hpp}` | `src/shared/track/SurfaceMaterials.lua` | Shared | P0 | `Ported` | Pure-Luau surface material lookup (`sandtrack/materials.xml` rev `18627`: `maxSpeedFraction`, `slowdownTime`, `highTireAdhesion`, `ignore`, `reset`, `fallingEffect`, `collisionReaction`), wired into `MaxSpeed.setSlowdown` & `KartSolver`. |
| `src/tracks/terrain_info.{cpp,hpp}` | `src/shared/track/TerrainInfo.lua` | Shared | P0 | `Not started` | Ground height, surface normal, and surface material query beneath kart/projectiles using Roblox raycasts. |
| `src/tracks/quad.{cpp,hpp}`, `graph.{cpp,hpp}`, `drive_graph.{cpp,hpp}`, `drive_node.{cpp,hpp}`, `drive_node_2d.{cpp,hpp}`, `drive_node_3d.{cpp,hpp}`, `bounding_box_3d.hpp` | `src/shared/track/DriveGraph.lua` | Shared | P0 | `Not started` | Driveline quad graph, distance-down-track (`distanceFromStart`), track-width offset, shortest-path successor lookup, rescue target lookup. |
| `src/tracks/track_sector.{cpp,hpp}` | `src/shared/track/TrackSector.lua` | Shared | P0 | `Not started` | Tracks each kart's current driveline quad, distance from start, off-track detection, wrong-way detection, and last valid rescue node. |
| `src/tracks/check_manager.{cpp,hpp}`, `check_structure.{cpp,hpp}`, `check_line.{cpp,hpp}`, `check_lap.{cpp,hpp}`, `check_cylinder.{cpp,hpp}`, `check_sphere.{cpp,hpp}`, `check_cannon.{cpp,hpp}`, `check_trigger.{cpp,hpp}`, `check_goal.{cpp,hpp}` | `src/server/track/CheckManager.lua` (geometry helpers in `src/shared/track/CheckGeometry.lua`) | Server / Shared | P0 | `Not started` | **Server-authoritative** checkpoint activation chains, lap completion validation, anti-shortcut rules, cannon entry, and goal triggers. Never trust client-reported laps. |
| `src/tracks/bezier_curve.{cpp,hpp}` | `src/shared/math/BezierCurve.lua` | Shared | P1 | `Not started` | Cubic Bezier evaluation for track cannons (`check_cannon` / `cannon_animation`). |
| `src/tracks/track_manager.{cpp,hpp}` | `src/shared/track/TrackRegistry.lua` | Shared | P1 | `Not started` | Curated catalog of converted tracks and metadata. |
| `src/tracks/track_object.{cpp,hpp}`, `track_object_manager.{cpp,hpp}`, `track_object_presentation.{cpp,hpp}`, `src/animations/animation_base.{cpp,hpp}`, `ipo.{cpp,hpp}`, `three_d_animation.{cpp,hpp}` | `src/shared/track/TrackObjects.lua`, `src/shared/track/IpoAnimator.lua` | Shared / Server | P2 | `Not started` | Moving obstacles, Blender IPO curve animations, animated hazards, and physics objects on tracks. |
| `src/tracks/arena_graph.{cpp,hpp}`, `arena_node.{cpp,hpp}`, `arena_node_3d.hpp` | `src/shared/track/ArenaGraph.lua` | Shared | P2 | `Not started` | Navigation mesh graph for battle / CTF / soccer arenas. |

### 3.5 Items, Powerups, Projectiles & Attachments (P1)

| Upstream File(s) | Target Luau Module | Layer | Priority | Status | Notes |
|---|---|---|---|---|---|
| `data/powerup.xml`, `data/items.xml`, `src/items/powerup_manager.{cpp,hpp}` | `src/shared/ItemTuning.lua`, `src/server/items/PowerupManager.lua` | Shared / Server | P1 | `Not started` | **Server-authoritative** rank-weighted item probability tables and item box rolls. |
| `src/items/item.{cpp,hpp}`, `item_manager.{cpp,hpp}`, `item_event_info.{cpp,hpp}` | `src/server/items/ItemManager.lua` | Server | P1 | `Not started` | Track pickups (gift boxes, nitro small/big, bananas, bubblegum), respawn timers, dropped hazards, and pickup validation. |
| `src/items/powerup.{cpp,hpp}` | `src/server/items/Powerup.lua` | Server | P1 | `Not started` | Held powerup slot, multi-charge counts (e.g., 3× bowling/cake/zipper), activation dispatch. Backward item throwing (`PA_LOOK_BACK` + `PA_FIRE`) depends on this unbuilt items subsystem (not stubbed). |
| `src/items/projectile_manager.{cpp,hpp}`, `flyable.{cpp,hpp}` | `src/server/items/ProjectileManager.lua`, `src/shared/items/Flyable.lua` | Server / Shared | P1 | `Not started` | Projectile lifecycle, forward/backward firing (depends on unbuilt items subsystem; not stubbed), ground-following height, wall bounces, and hit detection. |
| `src/items/bowling.{cpp,hpp}` | `src/server/items/Bowling.lua` | Server | P1 | `Not started` | Straight/bouncing bowling ball projectile. |
| `src/items/cake.{cpp,hpp}` | `src/server/items/Cake.lua` | Server | P1 | `Not started` | Homing cake projectile targeting nearest ahead kart. |
| `src/items/plunger.{cpp,hpp}`, `rubber_band.{cpp,hpp}` | `src/server/items/Plunger.lua`, `src/server/items/RubberBand.lua` | Server | P1 | `Not started` | Forward elastic pull (`RubberBand`) and backward face-splat (`Attachment::ATTACH_PLUNGER_FACE`). |
| `src/items/rubber_ball.{cpp,hpp}` | `src/server/items/RubberBall.lua` | Server | P1 | `Not started` | Basket/rubber ball following the driveline graph to hit the 1st-place kart (STK's blue-shell equivalent). |
| `src/items/swatter.{cpp,hpp}` | `src/server/items/Swatter.lua` | Server | P1 | `Not started` | Timed melee swatter attachment: squashes nearby karts and swats incoming bombs. |
| `src/items/attachment.{cpp,hpp}`, `attachment_manager.{cpp,hpp}`, `attachment_plugin.hpp` | `src/server/items/Attachment.lua` | Server | P1 | `Not started` | Kart attachments: parachute, anvil, bomb (with pass-on-collision), bubblegum shield, swatter, plunger face, squash state. |

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
| `src/karts/kart_rewinder.{cpp,hpp}`, `src/network/rewind_manager.{cpp,hpp}`, `rewind_queue.{cpp,hpp}`, `rewind_info.{cpp,hpp}`, `rewinder.{cpp,hpp}`, `event_rewinder.{cpp,hpp}`, `smooth_network_body.{cpp,hpp}`, `network_timer_synchronizer.hpp` | `src/client/net/KartPrediction.lua`, `src/client/net/RemoteKartInterpolator.lua` | Client | P1 | `Diverged` | **Accepted divergence:** Client-side input prediction & state reconciliation against server ticks; buffered interpolation for remote karts (replaces STK ENet global rewind). |

### 3.8 AI Controllers (P2)

| Upstream File(s) | Target Luau Module | Layer | Priority | Status | Notes |
|---|---|---|---|---|---|
| `src/karts/controller/ai_base_controller.{cpp,hpp}`, `ai_base_lap_controller.{cpp,hpp}`, `skidding_ai.{cpp,hpp}`, `ai_properties.{cpp,hpp}`, `end_controller.{cpp,hpp}` | `src/server/ai/RaceAIController.lua`, `src/shared/ai/AIProperties.lua` | Server / Shared | P2 | `Not started` | Driveline-following racing AI with difficulty scaling, skidding, item use, and post-finish autopilot (`EndController`). |
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
