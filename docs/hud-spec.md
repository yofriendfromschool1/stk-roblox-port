# OpenKart Race HUD Specification (`race_gui` / `race_gui_base`)

Complete inventory of every HUD element rendered during racing in pinned upstream **SuperTuxKart `1.5`** (`src/states_screens/race_gui.{cpp,hpp}` and `src/states_screens/race_gui_base.{cpp,hpp}`), re-audited against `docs/port-map.md` implementation readiness.

---

## Global Scaling & Mode-Conditional Visibility

- **Primary viewport scaling** (`src/states_screens/race_gui.cpp:L377-L389`):
  - Single-player full screen:
    $$\text{scaling} = \sqrt{\frac{\text{viewport.W}}{800}} \times \sqrt{\frac{\text{viewport.H}}{450}}$$
- **Mode-conditional visibility matrix** (`RaceHudMath.getModeVisibility`, ported from `race_gui.cpp:L314-L407, L568-L582`, `race_gui_base.cpp:L385, L789-L791`, and `src/modes/*.hpp`):

| Mode | Timer (`shouldDrawTimer`) | Rank Digit (`shouldDrawSpeedometerDigit`) | Laps (`raceHasLaps`) | Laps Target (`showLapsTarget`) | MiniMap | Player Icons | Citations |
|---|---|---|---|---|---|---|---|
| `NORMAL_RACE` | Race phase | Yes | Yes | Yes | Unless hidden (`display==2`) | Yes | `standard_race.hpp`, `linear_world.hpp:L170, L240` |
| `TIME_TRIAL` | Race phase | Yes | Yes | Yes | Unless hidden | Yes | `linear_world.hpp:L170, L240` |
| `LAP_TRIAL` | Race phase | Yes | Yes | No | Unless hidden | Yes | `lap_trial.hpp:L34` |
| `FOLLOW_THE_LEADER` | Race phase | Yes | No | No | Unless hidden | Yes | `follow_the_leader.hpp:L64` |
| `THREE_STRIKES` | Race phase | Yes | No | No | If `hasNavMesh` | Yes | `three_strikes_battle.hpp:L122-L124` |
| `FREE_FOR_ALL` | Race phase | Yes | No | No | If `hasNavMesh` | Yes | `free_for_all.hpp:L56-L58` |
| `CAPTURE_THE_FLAG` | Race phase | Yes | No | No | If `hasNavMesh` | Yes | `capture_the_flag.hpp:L37` |
| `SOCCER` | `!isStartPhase()` | No | No | No | If `hasNavMesh` | If `m_soccer_player_list` | `soccer_world.hpp:L150-L158` |
| `OVERWORLD` | No | No | No | No | Unless hidden | Yes | `overworld.hpp:L55-L65` |
| `TUTORIAL` | No | Yes | No | No | Unless hidden | No | `tutorial_world.hpp:L48`, `race_gui.cpp:L334, L406` |

- **Minimap rotation audit (`user_config.hpp:L1272-L1292`, `track.cpp:L747-L760, L837-L850`):**
  - STK `1.5` has **no** minimap rotation user config setting. `UserConfigParams` exposes only `m_minimap_display` (`0` bottom-left, `1` middle-right, `2` hidden, `3` center), `m_minimap_size` (`180`), `m_minimap_ai_icon_size` (`16`), and `m_minimap_player_icon_size` (`20`). The only orientation flip in upstream STK is `m_minimap_invert_x_z` (180° X/Z flip) automatically enabled for Blue team in Soccer (`track.cpp:L747-L760`).

---

## HUD Elements Inventory

| # | Element | Upstream Citation(s) | Position & Size Expression (`W, H` = viewport/screen) | Texture(s) & License | Driving Data Source | Port Status (`docs/port-map.md`) |
|---|---|---|---|---|---|---|
| 1 | **Speedometer Background & 8-Segment Fill Arc** | `race_gui.cpp:L96-L97, L1011-L1131` | `s = min(scale.X, scale.Y)`, `W_m = floor(128 * s)`. `offset.X = W - W_m - 24 * s`, `offset.Y = H - 10 * s`; rect `[offset.X, offset.Y - W_m, offset.X + W_m, offset.Y]`. Center `A = (0.546, 0.566)`; 8-segment radial fan `127.05° -> 330.66°`; border snap at `i * 0.125`; hidden if `speed <= 0`. | `speedback.png`, `speedfore.png` (**CC0**, `Alayan`, `data/gui/icons/licenses.txt:L193-L198`) | Interpolated `speedMps / 40.0` (`HudState`) | **Bindable now** — active in `GameHud.client.lua` |
| 2 | **Nitro Energy Meter Background & 5-Segment Fill** | `race_gui.cpp:L795-L886`, `race_gui_base.cpp:L120-L122` | `G = floor(94 * s)`. `offset.X = W - G - 9.5 * s`, `offset.Y = H - 11.5 * s`; rect `[offset.X, offset.Y - G, offset.X + G, offset.Y]`. Center `A = (0.324, 0.350)`; 5-segment radial fan `117.44° -> -12.56°`; border snap at `i * 0.2`. Bright variant while nitro active. *(Sub-element `gauge_goal.png` blocked on Challenge coin target.)* | `gauge_empty.png`, `gauge_full.png`, `gauge_full_bright.png` (**CC0**, `Alayan`, `licenses.txt:L193-L198`) | Interpolated `nitroEnergy / nitroMaxEnergy` + `nitroUsing` (`HudState`) | **Bindable now** — active in `GameHud.client.lua`; `NitroCoinTargetSlot` inactive |
| 3 | **Rank / Speedometer Digit** | `race_gui.cpp:L914-L1001`, `world_with_rank.cpp:L89-L92`, `linear_world.cpp:L875-L930` | Centered at `(offset.X + 0.64 * W_m, offset.Y - 0.49 * W_m)` inside speedometer; height `0.4 * W_m`; shrinks `1.0 -> 0.3` and expands over `2 * 0.4 s` on rank transitions. | Digit text | `Standings.getRankForId` (`lap -> checkpoint -> distance`, returns `1/1` solo) | **Bindable now** — active in `GameHud.client.lua` |
| 4 | **Global Elapsed Race Timer** | `race_gui.cpp:L118-L121, L415-L487`, `string_utils.cpp:L565-L655` | Top-right: `X = [W - (10 + m_timer_width), W]`, `Y = [0.02 * H, 0.06 * H]`, formatted `MM:SS.mmm`. *(Countdown / Challenge Failed / lap splits remain blocked.)* | Monospace white text + black stroke | Wall-clock `Workspace:GetServerTimeNow() - raceStartServerTime` | **Bindable now** — elapsed timer active in `GameHud.client.lua`; `LapSplitsSlot` inactive |
| 5 | **Top-Left Player Icon** | `race_gui_base.cpp:L785-L838, L1033-L1055`, `kart.xml:L6-L7` | `x = 10`, `y = 25 + (rank - 1) * (w + 2)`; `w = clamp(floor((H - bottomMargin - 25) / numKarts) - 2, 35, floor(60 * W / 1024))` (`bottomMargin = m_map_height + m_map_bottom` when minimap bottom-left, else `0`). | `karts/tux/tux_icon.png` (**GPL 2.0**, `Anthony "yeKcim" Carré`, rev `18627`; Tux by `Larry Ewing / The GIMP`); `icons-frame.png` (`CC-BY-SA 3.0+`, DEP-5 wildcard `data/gui/icons/licenses.txt:L13-L24`) | `Standings` rank + local kart `tux_icon.png` | **Bindable now** — local Tux icon active; `IconsFrameSlot` (`icons-frame.png` copied & ready for upload); `PlungerBadgeSlot`, `AttachmentBadgeSlot`, `FinishedFlagSlot` inactive |
| 6 | **Bottom-Left Track Mini-Map & Player Kart Dot** | `race_gui.cpp:L171-L266, L564-L699`, `track.cpp:L837-L850`, `graph.cpp:L511-L540, L590-L595` | `s_map = min(W, H) / 480`; `map_w = map_h = floor(180 * s_map)` at `(floor(10 * s_map), H - floor(10 * s_map) - map_h)`. `playerIconSize = floor(20 * s_map)`. Projection: `scale = map_w / max(dx, dz)`, `drawX = (x - minX) * scale`, `localY = map_h - (z - minZ) * scale`. | `karts/tux/tux_icon.png` marker + projected quad-center outline | `GreyboxArenaData.drivelineQuadCenters` + interpolated `renderHud.pos` via `RaceHudMath.projectToMinimap` | **Bindable now** — outline & local kart dot active; `AIKartMarkersSlot`, `CTFFlagMarkersSlot`, `SoccerBallMarkerSlot`, `BasketballMarkersSlot` inactive |
| 7 | **Ghost Live Time Difference** | `race_gui.cpp:L493-L559` | `[W - (10 + timer_width), W]`, `Y = [0.07 * H, 0.11 * H]`. | Digit text | `LinearWorld::getLiveTimeDifference()` | **Blocked (subsystem unbuilt)** — `GhostReplay` (`P3`) |
| 8 | **Lap Counter / Flag (plus FFA / CTF / Soccer Score)** | `race_gui.cpp:L1266-L1414` | Below timer `Y = 0.12 * H`, icon `H / 19`. | `lap_flag.png` (`CC BY 3.0`, audited); `cup_gold.png` (skipped) | `CheckManager::getFinishedLapsOfKart()` | **Blocked (subsystem unbuilt)** — `CheckManager` (`P0`) |
| 9 | **Powerup Held Icons & Count** | `race_gui_base.cpp:L380-L456`, `user_config.hpp:L1298-L1303` | `scale = min(scale.X, scale.Y)`, `nSize = floor(64 * scale)`, `spacing = floor(32 * scale)`, top `y = floor(20 * scale.Y)`, centered at `W / 2` (or `3 * W / 4` when `W / H > 2.0` or `display == 1`); stacks `1..5` overlapping icons or `1` + `xN` badge when `> 5`. | `data/gui/icons/*.png` (`CC-BY-SA 3.0+`, DEP-5 `licenses.txt:L13-L24`; 8/10 also per-file in `data/models/licenses.txt`) | `HudState.heldPowerup` & `HudState.heldPowerupCount` via `RaceHudMath.computePowerupLayout` | **Bindable now** — live in `GameHud.client.lua` (slot + count bound; icon PNGs copied to `assets/gui/icons/` pending Creator upload IDs) |
| 10 | **Ready-Set-Go & Waiting Banner** | `race_gui_base.cpp:L734-L779` | Centered `(W / 2, H * 2 / 5)` `TitleFont`. | Text | `RacePhase` state machine | **Blocked (subsystem unbuilt)** — `RacePhase` (`P0`) |
| 11 | **GOAL! Banner** | `race_gui_base.cpp:L721-L730` | Centered `(W / 2, H / 2)` `TitleFont`. | Text | `SoccerWorld` | **Blocked (subsystem unbuilt)** — `SoccerWorld` (`P2`) |
| 12 | **Timed Messages (Important & Unimportant)** | `race_gui_base.cpp:L256-L351` | Top-quarter (`H / 4`) / bottom-center. | Text | Race / item events | **Blocked (subsystem unbuilt)** — Event feed (`P1`) |
| 13 | **Music Title & Composer Overlay** | `race_gui_base.cpp:L609-L718` | Bottom-center (`Y = H - 2.5 * fheight`). | `notes.png` (unverified — skipped) | `MusicManager` | **Blocked (subsystem unbuilt)** — Music metadata |
| 14 | **Plunger-in-Face Overlay** | `race_gui_base.cpp:L1263-L1355` | Centered `0.6 * W` square. | `plungerface.png` (unverified — skipped) | `Plunger` attachment | **Blocked (subsystem unbuilt)** — Items (`P1`) |
| 15 | **Story Mode Timer & Multitouch Overlay** | `race_gui.cpp:L81-L89, L305-L308` | Fullscreen touch / corner story clock. | Touch / text | `Overworld` / `RaceGUIMultitouch` | **Blocked (deferred)** (`P3`) |
