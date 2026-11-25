# SuperTuxKart 1.5 SFX Specification

- **Source directory:** `C:\Program Files\SuperTuxKart 1.5\data\sfx\` (68 `.ogg` files total; 53 registered in `sfx.xml`, 15 track-object/ambient/unused)
- **Provenance:** `stk-assets/sfx/` at SVN rev `18627`
- **Excluded:** `data/music/` (no music ported)
- **Upstream engine & controller audio citations:**
  - `src/audio/sfx_manager.hpp:L98-L111` (`CustomSFX` enum: `CUSTOM_HORN`, `CUSTOM_CRASH`, `CUSTOM_WIN`, `CUSTOM_EXPLODE`, `CUSTOM_GOO`, `CUSTOM_PASS`, `CUSTOM_ZIPPER`, `CUSTOM_NAME`, `CUSTOM_ATTACH`, `CUSTOM_SHOOT`)
  - `src/audio/sfx_manager.cpp:L550-L599` (`SFXManager::loadSfx()` reading `data/sfx/sfx.xml`)
  - `src/karts/kart.cpp:L2682-L2725` (`Kart::updateEngineSFX()` pitch/speed curve)
  - `stk-assets/karts/tux/kart.xml:L12` (`<sounds engine="large"/>` — per-kart engine selection; `horn` and `crash` fall back to global `horn.ogg`, `crash.ogg`, `crash2.ogg`, `crash3.ogg` unless overridden per-kart)

## Stereo-but-Positional Flags

| File | Channels | `sfx.xml` `positional` | Action |
|---|---|---|---|
| `car_revup.ogg` | 2 (stereo) | `true` (`sfx.xml:L25`) | Downmix to mono (`ffmpeg -ac 1`) if uploaded; unused in `src/` |
| `WilhelmScream.ogg` | 2 (stereo) | `true` (`sfx.xml:L70`) | **Do not upload** (dubious PD provenance + unused in `src/`) |

## Provenance / License Flags (Do Not Upload Unverified)

| File | Finding in `data/sfx/licenses.txt` | Decision |
|---|---|---|
| `bowling_shoot.ogg` | **Missing** from `data/sfx/licenses.txt` and root `stk-assets/licenses.txt` | **Do not upload** until provenance verified |
| `WilhelmScream.ogg` | `licenses.txt:L408-L415` — `"Dubious; but supposedly no one's ever tried to sue anyone because of it."` | **Do not upload** |
| `dark.ogg` | `licenses.txt:L91-L94` — `"Source unknown"`, unused in `src/` & `sfx.xml` | **Do not upload** |
| `rain.ogg` | `licenses.txt:L297-L307` — `License: CC-BY 3.0 (?)` (ambiguous source file), track weather only | **Do not upload** |
| `break.ogg` | `licenses.txt:L45-L50` — `Copyright ????`, `"TODO: Ask her."`, unused in `src/` & `sfx.xml` | **Do not upload** |
| `grab_collectable.ogg` | `licenses.txt:L166-L172` — `Copyright: ????`, Tintagel public-domain statement with archive.org URL | Review; core nitro pickup SFX |
| `locked.ogg` | `licenses.txt:L221-L224` — `Copyright: ???? "Stephan"`, `pdsounds.org` without URL | UI-only; skip if not needed |

---

## Complete SFX Table (All 68 `.ogg` Files)

### 1. Registered in `data/sfx/sfx.xml` (53 files)

| Event / Purpose | File (Size, Ch) | Citation | Positional | Looping | Volume (`sfx.xml`) | Pitch Behavior | License (`licenses.txt`) |
|---|---|---|---|---|---|---|---|
| Track jet/airplane ambient | `airplane_jetEngine.ogg` (61,633 B, 1ch) | `sfx.xml:L16` (track object) | Positional (`rolloff=0.2`) | Track-defined | `1.0` | `1.0` | `CC-BY-SA 3.0` |
| Anvil item use / UI click | `anvil.ogg` (7,535 B, 1ch) | `src/items/powerup.cpp:L172`, `src/main_loop.cpp:L486` | Positional (`rolloff=0.5`) in race; 2D in UI | No | `1.0` | `1.0` | `GPLv2+` |
| Kart respawn / lobby join | `appear.ogg` (11,381 B, 1ch) | `src/karts/kart_rewinder.cpp:L123`, `src/network/protocols/client_lobby.cpp:L640` | 2D | No | `1.0` | `1.0` | `CC0` |
| Rubber ball bounce | `ball_bounce.ogg` (7,247 B, 1ch) | `src/items/rubber_ball.cpp:L75,L706` | Positional | No | `0.5` | `1.0` | `GPLv2+` |
| Bubblegum shield collision | `boing.ogg` (23,585 B, 1ch) | `src/karts/kart.cpp:L179,L2514` | Positional (`rolloff=0.5`) | No | `1.0` | `1.0` | `CC0` |
| Bowling ball rolling | `bowling_roll.ogg` (29,533 B, 1ch) | `src/items/bowling.cpp:L40-L43,L142` | Positional (`rolloff=0.05`) | Yes | `1.0` | `1.0` | `CC-BY-SA 3.0, CC-BY 3.0` |
| Bowling ball launch | `bowling_shoot.ogg` (5,265 B, 1ch) | `src/items/powerup.cpp:L168,L225` | Positional (`rolloff=0.05`) | No | `1.0` | `1.0` | **UNVERIFIED (missing)** |
| Bubblegum shield pop/explode | `bubblegum_explode.ogg` (14,699 B, 1ch) | `src/items/attachment.cpp:L554-L555` | Positional (`rolloff=0.5`) | No | `1.0` | `1.0` | `CC-BY 3.0` |
| Wrong-way / error buzz | `bzzt.ogg` (8,087 B, 1ch) | `src/karts/controller/local_player_controller.cpp:L89` | 2D | No | `1.0` | `1.0` | `GPLv2` |
| Unused engine rev | `car_revup.ogg` (53,372 B, **2ch**) | `sfx.xml:L25` (unused in `src/`) | Positional (`rolloff=0.2`) | No | `0.5` | `1.0` | `CC-BY 3.0` |
| Bomb attachment countdown | `clock.ogg` (87,331 B, 1ch) | `src/items/attachment.cpp:L679-L683` | Positional (`rolloff=0.2`) | Yes | `1.0` | `1.0` | `public-domain` |
| Kart crash / bowling hit (1/3) | `crash.ogg` (12,266 B, 1ch) | `src/karts/kart.cpp:L175,L2520`, `src/items/bowling.cpp:L197` | Positional (`rolloff=0.5`) | No | `1.0` (scaled by impact speed) | `1.0` | `CC-BY-SA 4.0` |
| Kart crash (2/3) | `crash2.ogg` (9,152 B, 1ch) | `src/karts/kart.cpp:L176,L2520` | Positional (`rolloff=0.5`) | No | `1.0` (scaled by impact speed) | `1.0` | `CC-BY-SA 4.0` |
| Kart crash (3/3) | `crash3.ogg` (10,523 B, 1ch) | `src/karts/kart.cpp:L177,L2520` | Positional (`rolloff=0.5`) | No | `1.0` (scaled by impact speed) | `1.0` | `CC-BY-SA 4.0` |
| Nitro bar full / lobby ready | `energy_bar_full.ogg` (30,203 B, 1ch) | `src/karts/controller/local_player_controller.cpp:L92` | 2D | No | `1.0` | `1.0` | `public-domain` |
| Nitro bar drops below threshold | `energy_bar_unfull.ogg` (21,537 B, 2ch) | `src/karts/controller/local_player_controller.cpp:L93` | 2D | No | `1.0` | `1.0` | `CC-0` |
| Per-kart engine (large, e.g. Tux) | `engine_large.ogg` (36,881 B, 1ch) | `src/karts/kart_properties.cpp:L590`, `stk-assets/karts/tux/kart.xml:L12`, `src/karts/kart.cpp:L2682-L2725` | Positional (`rolloff=0.2`) | Yes | `0.5` | `0.6 + (0.9*f + 3*fmod(min(f,1), 1/3)) * 0.35` | `CC-BY-SA 3.0` |
| Per-kart engine (small, default) | `engine_small.ogg` (58,100 B, 1ch) | `src/karts/kart_properties.cpp:L101,L591`, `src/karts/kart.cpp:L2682-L2725` | Positional (`rolloff=0.2`) | Yes | `0.4` | `0.6 + (0.9*f + 3*fmod(min(f,1), 1/3)) * 0.35` | `CC-BY-SA 3.0 / GPL3 / GPL2` |
| Bomb / cake explosion | `explosion.ogg` (17,836 B, 1ch) | `src/items/attachment.cpp:L311,L528` | Positional (`rolloff=0.05`) | No | `1.0` | `1.0` | `CC0` |
| Unused forcefield | `forcefield.ogg` (14,796 B, 1ch) | `sfx.xml:L35` (unused in `src/`) | 2D | No | `1.0` | `1.0` | `public-domain CC0` |
| Soccer / CTF goal scored | `goal_scored.ogg` (195,625 B, 2ch) | `src/modes/soccer_world.cpp:L283`, `src/modes/capture_the_flag.cpp:L71` | 2D | No | `1.0` | `1.0` | `CC-BY 3.0` |
| Bubblegum drop / goo terrain | `goo.ogg` (15,097 B, 1ch) | `src/items/powerup.cpp:L180`, `src/karts/kart.cpp:L178,L1176` | Positional (`rolloff=0.2`) | No | `1.0` | `1.0` | `CC-BY 3.0` |
| Grand Prix end applause | `gp_end.ogg` (69,154 B, 1ch) | `src/states_screens/grand_prix_win.cpp:L219` | 2D | No | `1.0` | `1.0` | `CC-BY 3.0` |
| Nitro / item pickup | `grab_collectable.ogg` (7,581 B, 1ch) | `src/karts/controller/local_player_controller.cpp:L91` | 2D | No | `1.0` | `1.0` | `public-domain` |
| Swatter squash hit | `hammer.ogg` (11,528 B, 1ch) | `src/items/swatter.cpp:L190,L214` | Positional (`rolloff=0.05`) | No | `1.0` | `1.0` | `CC-BY 3.0` |
| Default kart horn | `horn.ogg` (9,528 B, 1ch) | `src/karts/kart.cpp:L174,L2536` | Positional (`rolloff=0.2`) | No | `0.9` | `1.0` | `CC-BY 3.0` |
| Bubblegum shield inflate | `inflate.ogg` (17,238 B, 1ch) | `src/items/powerup.cpp:L379-L383` | Positional (`rolloff=0.1`) | No | `1.0` | `1.0` | `CC-BY 3.0` |
| Jump pad / ramp | `jump.ogg` (6,554 B, 1ch) | `src/karts/kart.cpp:L1797` | Positional | No | `1.0` | `1.0` | `CC0` |
| Final lap fanfare | `last_lap_fanfare.ogg` (71,399 B, 2ch) | `src/modes/linear_world.cpp:L63` | 2D | No | `1.0` | `1.0` | `CC-BY-SA 3.0+` |
| Locked challenge / track UI | `locked.ogg` (33,005 B, 1ch) | `src/challenges/unlock_manager.cpp:L54` | 2D | No | `1.0` | `1.0` | `public-domain` |
| Track machine ambient | `machine_sound.ogg` (25,919 B, 1ch) | `sfx.xml:L49` (track object) | Positional | Track-defined | `1.0` | `1.0` | `CC-BY 3.0` |
| Nitro boost active | `nitro.ogg` (87,396 B, 1ch) | `src/karts/kart.cpp:L186,L2288-L2300` | Positional (`rolloff=0.15`) | Yes (while active) | `1.0` | `1.0` | `public-domain CC0` |
| Parachute deploy | `parachute.ogg` (6,936 B, 1ch) | `src/items/powerup.cpp:L176` | Positional (`rolloff=0.5`) | No | `1.0` | `1.0` | `zlib / GPL 2.0 / CC-BY 3.0` |
| Lobby / track UI pop | `plopp.ogg` (10,646 B, 2ch) | `src/network/protocols/client_lobby.cpp:L939` | 2D | No | `1.0` | `1.0` | `CC0` |
| Plunger face obstruction | `plunger.ogg` (7,924 B, 1ch) | `src/items/plunger.cpp:L210` | 2D | No | `1.0` | `1.0` | `CC-BY-SA 3.0` |
| Track portal ambient | `portal.ogg` (7,677 B, 1ch) | `sfx.xml:L52` (track object) | Positional | Track-defined | `1.0` | `1.0` | `CC-BY-SA 3.0` |
| Countdown 3-2-1 beep | `pre_start_race.ogg` (24,954 B, 2ch) | `src/modes/world_status.cpp:L49`, `src/modes/world.cpp:L981` | 2D | No | `1.0` | `1.0` | `CC-BY-SA 3.0` |
| Race finish (non-victory) | `race_finish.ogg` (132,578 B, 2ch) | `src/states_screens/race_result_gui.cpp:L131` | 2D | No | `1.0` | `1.0` | `CC-BY-SA 3.0+` |
| Race finish (victory) | `race_finish_victory.ogg` (91,592 B, 1ch) | `src/states_screens/race_result_gui.cpp:L131` | 2D | No | `1.0` | `1.0` | `CC-BY-SA 3.0` |
| Weather rain loop | `rain.ogg` (65,295 B, 2ch) | `src/graphics/weather.cpp:L43,L99` | 2D | Yes | `1.0` | `1.0` | `CC-BY 3.0 (?)` |
| Cake / plunger fire | `shoot.ogg` (13,163 B, 1ch) | `src/items/powerup.cpp:L191,L277` | Positional (`rolloff=0.1`) | No | `1.0` | `1.0` | `GPL 2.0` |
| Drift / skid loop | `skid.ogg` (39,246 B, 1ch) | `src/karts/kart.cpp:L2641-L2646,L3067` | Positional (`rolloff=0.5`) | Yes (while skidding) | `1.0` | `1.0` | `CC-BY 3.0` |
| Water splash terrain | `splash.ogg` (46,735 B, 1ch) | `data/tracks/*/materials.xml`, `src/karts/kart.cpp:L1946` | Positional (`rolloff=0.05`) | Terrain loop | `1.0` | Speed-mapped (`0.80`–`1.20`) | `CC-BY-SA 4.0` |
| Countdown GO! beep | `start_race.ogg` (29,024 B, 2ch) | `src/modes/world_status.cpp:L50` | 2D | No | `1.0` | `1.0` | `CC-BY-SA 3.0` |
| Bowling ball strike | `strike.ogg` (35,488 B, 1ch) | `src/items/bowling.cpp:L195` | Positional (`rolloff=0.05`) | No | `1.0` | `1.0` | `CC-BY-SA 3.0` |
| Switch item swap | `swap.ogg` (22,393 B, 1ch) | `src/items/powerup.cpp:L184` | 2D | No | `1.0` | `1.0` | `public-domain CC0` |
| Swatter swing | `swatter.ogg` (16,916 B, 1ch) | `src/items/swatter.cpp:L192,L214` | Positional (`rolloff=0.05`) | No | `1.0` | `1.0` | `CC-BY 3.0` |
| Weather thunder | `thunder.ogg` (31,901 B, 1ch) | `src/graphics/weather.cpp:L37` | 2D | No | `1.0` | `1.0` | `CC-BY 3.0` |
| Track intro fanfare | `track_intro.ogg` (80,707 B, 2ch) | `src/modes/world_status.cpp:L51` | 2D | No | `1.0` | `1.0` | `CC-BY-SA 3.0+` |
| Off-track / penalty | `ugh.ogg` (5,607 B, 1ch) | `src/karts/controller/local_player_controller.cpp:L90` | 2D | No | `1.0` | `1.0` | `GPL 2.0` |
| Kart select / CTF flag | `wee.ogg` (5,022 B, 1ch) | `src/karts/controller/local_player_controller.cpp:L88` | 2D | No | `1.0` | `1.0` | `GPL 2.0` |
| Unused scream | `WilhelmScream.ogg` (14,438 B, **2ch**) | `sfx.xml:L70` (unused in `src/`) | Positional (`rolloff=0.10`) | No | `1.0` | `1.0` | **UNVERIFIED (dubious PD)** |
| Wooden bridge terrain | `wooden_bridge.ogg` (10,380 B, 1ch) | `data/tracks/snowtuxpeak/materials.xml:L9`, `src/karts/kart.cpp:L1946` | Positional (`rolloff=0.2`) | Terrain loop | `0.4` | Speed-mapped (`1.00`–`1.70`) | `public-domain` |

### 2. Track-Ambient / Unused `.ogg` Files Not in `data/sfx/sfx.xml` (15 files)

| File (Size, Ch) | Usage | License (`licenses.txt`) |
|---|---|---|
| `break.ogg` (81,111 B, 2ch) | Unused in `src/` & `sfx.xml` | `CC-BY-SA 3.0` (TODO provenance) |
| `car_accel.ogg` (29,463 B, 1ch) | Unused in `src/` & `sfx.xml` | `CC-BY 3.0` |
| `dark.ogg` (109,189 B, 2ch) | Unused in `src/` & `sfx.xml` | `CC0` (Source unknown) |
| `exotic-birds.ogg` (118,883 B, 1ch) | Track ambient only | `public-domain CC0` |
| `exotic-birds_2.ogg` (165,003 B, 1ch) | Track ambient only | `public-domain CC0` |
| `fireworks_show.ogg` (84,514 B, 1ch) | Track ambient only | `public-domain CC0` |
| `gnu_flute.ogg` (439,364 B, 2ch) | Track ambient only | `CC-BY 3.0` |
| `lenautile_restaurant.ogg` (202,187 B, 1ch) | Track ambient only | `public-domain CC0` |
| `metal_clang.ogg` (100,519 B, 2ch) | Unused in `src/` & `sfx.xml` | `CC-BY 3.0` |
| `river_loop.ogg` (182,578 B, 1ch) | Track ambient only | `public-domain CC0` |
| `sara_airport_pa.ogg` (490,102 B, 1ch) | Track ambient only | `CC-BY-SA 4.0` |
| `spaceship.ogg` (241,938 B, 1ch) | Track ambient only | `CC-BY-SA 3.0` |
| `static-radio.ogg` (1,270,567 B, 1ch) | Track ambient only | `CC-BY 3.0` |
| `tractor_beam.ogg` (114,240 B, 2ch) | Track ambient only | `CC-BY 3.0` |
| `waterfall_loop_2.ogg` (168,566 B, 1ch) | Track ambient only | `public-domain CC0` |
