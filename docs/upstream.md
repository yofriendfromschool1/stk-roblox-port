# Upstream Reference: SuperTuxKart

OpenKart is an unofficial port of **SuperTuxKart (STK)** to Roblox. This document pins the exact upstream revision we port from, records the out-of-repo reference checkout locations, tracks trademark status, and inventories every license file present in the pinned upstream tree.

> **Policy:** Never silently retarget the pinned tag or commit. Retargeting requires an explicit decision in `docs/decisions.md` and an audit of upstream file/line citations across all ported modules.

---

## Pinned Upstream Version

| Field | Value |
|---|---|
| Upstream project | SuperTuxKart (`https://supertuxkart.net/`) |
| Source repository | `https://github.com/supertuxkart/stk-code` |
| Pinned release tag | `1.5` |
| Tag object type | Lightweight tag |
| Pinned commit SHA | `1fb491f507216c5d181ccd85f29ff08eca003827` |
| Commit date | `2025-10-19 21:42:37 +0200` (released `2025-10-20`) |
| Commit author | Alayan (`25536748+Alayan-stk-2@users.noreply.github.com`) |
| Commit subject | `Disable the donate button on mobile platforms` |
| `CMakeLists.txt` `PROJECT_VERSION` | `1.5` |
| Assets repository | `https://svn.code.sf.net/p/supertuxkart/code/stk-assets` (SVN, per `INSTALL.md`) |
| Pinned assets SVN revision | `18627` (fetched `tracks/sandtrack` for the Month 1 `tools/stk2rbx` spike) |

### Rationale for Tag `1.5`
- `1.5` is the latest stable release in the 1.x line (the final major 1.x release before *SuperTuxKart Evolution*).
- It provides an immutable, well-tested reference for kart physics (`btKart`, `Kart`, `Skidding`, `MaxSpeed`, `SlipStream`), track drivelines/checkpoints, items/powerups, and race modes without tracking moving development branches (`1.5.1` / `1.6` milestones).

### Module Citation Format
Every ported Luau module must cite its upstream origin using this tag:

```lua
-- ported from src/karts/kart.cpp:L210-L268 (STK 1.5)
```

---

## Local Clone Locations (Outside This Repo)

Upstream repositories are kept **outside** `C:\dev\openkart` so that un-audited media and C++ third-party libraries can never be accidentally committed into the OpenKart repository.

| Repository | Local Path | Status | Clone / Checkout Command |
|---|---|---|---|
| `stk-code` (tag `1.5`) | `C:\dev\stk-code` | Checked out (shallow, detached HEAD at `1fb491f507216c5d181ccd85f29ff08eca003827`) | `git clone --depth 1 --branch 1.5 https://github.com/supertuxkart/stk-code.git C:\dev\stk-code` |
| `stk-assets` (SVN) | `C:\dev\stk-assets` | Partial checkout (`tracks/sandtrack` at rev `18627` via `tools/stk2rbx fetch`) | `svn co https://svn.code.sf.net/p/supertuxkart/code/stk-assets C:\dev\stk-assets` |

Verification command against `C:\dev\stk-code`:

```powershell
git -C C:\dev\stk-code rev-parse HEAD
git -C C:\dev\stk-code describe --tags --exact-match
```

Expected output: `1fb491f507216c5d181ccd85f29ff08eca003827` and `1.5`.

---

## Trademark, Attribution & Identity Status

- **Port status:** Unofficial port of SuperTuxKart.
- **Roblox title `"SuperTuxKart"`:** **PENDING upstream permission.** GPLv3 grants copyright permissions, not trademark rights. Use the fallback title **`OpenKart`** everywhere on Roblox until written trademark permission is obtained and recorded here.
- **Required attribution:** Upstream attribution and link (`https://supertuxkart.net/` and `https://github.com/supertuxkart/stk-code`) must be displayed both in-game (title/credits screen) and in this repository.
- **OpenKart license:** `GPL-3.0-or-later` (`LICENSE` at repo root; `-- SPDX-License-Identifier: GPL-3.0-or-later` on every source file). Never relicense.

---

## Upstream Coordinate & Unit Reference

Recorded from `C:\dev\stk-code\README.md`:
- **STK world coordinates:** `X` right, `Y` up, `Z` forward (metric SI units: meters, m/s, m/s^2).
- **Blender export convention:** `X` right, `Y` forward, `Z` up (STK exporters convert XY ground to XZ ground).
- **Roblox world coordinates:** `X` right, `Y` up, `-Z` forward (right-handed; `1 stud = 0.28 m` in `src/shared/Units.lua`).
- `tools/stk2rbx` and physics ports must account for the handedness / forward-axis flip (`+Z` vs `-Z`) and meter-to-stud scaling explicitly.

---

## License File Inventory (`stk-code@1.5`)

Audited directly from `C:\dev\stk-code` at commit `1fb491f507216c5d181ccd85f29ff08eca003827`.

### 1. Core Codebase & Project Credits

| Path in `stk-code` | License / Summary | Relevance to OpenKart |
|---|---|---|
| `COPYING` | **GPL-3.0-or-later** (GNU General Public License v3 or any later version) for all SuperTuxKart code; explicitly notes that `data/` files use mixed licenses (GPL, CC-BY, CC-BY-SA, Public Domain) documented in per-subdirectory `licenses.txt` files. | Governs all ported Luau code (`OpenKart` is `GPL-3.0-or-later`). |
| `data/CREDITS` | Upstream contributor credits list; states STK code is GPL 3.0 and assets use Creative Commons and other licenses. | Source for in-game & repo attribution. |

### 2. In-Repo Data, UI Artwork, Fonts & Shaders (`data/`)

> **Important:** Upstream media is **not** uniformly CC-BY-SA. Every file imported into `assets/` must be audited individually and recorded in `assets/CREDITS.md` (with zero Nintendo IP and zero unverified files).

| Path in `stk-code` | License(s) Declared | Scope / Notes |
|---|---|---|
| `data/gui/icons/licenses.txt` | **Mixed:** `CC-BY-SA 3.0`, `CC-BY-SA 3.0+`, `CC-BY-SA 4`, `CC BY 3.0`, `CC0`, `GPL-2+` (Debian copyright format 1.0) | GUI icons and `materials.xml`. Must audit per-icon before reuse. |
| `data/gui/icons/android/licenses.txt` | `CC-BY-SA 4.0` (Néd J. Édoire, 2017) | Touch-control icons (`blur_bg_button*.png`, `drift.png`, `nitro*.png`, `pause.png`, `steering_wheel.png`, `thunderbird_reset.png`, `wing_mirror.png`). |
| `data/skins/cartoon/licenses.txt` | `CC-BY-SA 3.0`, `CC-BY-SA 4.0`, `OFL-1.1` (SIL Open Font License 1.1) | Cartoon skin assets and embedded `Inter-UI-Black.ttf` (v2.5). |
| `data/skins/cartoon-coal/licenses.txt` | `CC-BY-SA 3.0`, `OFL-1.1` (note: contains `Copyright: ???` entries from peach skin — do **not** import unverified files) | Cartoon-coal skin variant. |
| `data/skins/cartoon-desert/licenses.txt` | `CC-BY-SA 3.0`, `OFL-1.1` | Cartoon-desert skin variant. |
| `data/skins/cartoon-forest/licenses.txt` | `CC-BY-SA 3.0`, `OFL-1.1` | Cartoon-forest skin variant. |
| `data/skins/cartoon-ocean/licenses.txt` | `CC-BY-SA 3.0`, `OFL-1.1` | Cartoon-ocean skin variant. |
| `data/skins/cartoon-ruby/licenses.txt` | `CC-BY-SA 3.0`, `OFL-1.1` | Cartoon-ruby skin variant. |
| `data/skins/classic/License.txt` | `CC-BY-SA 3.0` / `CC-BY-SA 3+` | Classic skin assets (Magne Djupvik, OpenGameArt / onyum.com, yeKcim). |
| `data/skins/classic-coal/License.txt` | `CC-BY-SA 3.0` / `CC-BY-SA 3+` | Classic-coal skin variant. |
| `data/skins/classic-desert/License.txt` | `CC-BY-SA 3.0` / `CC-BY-SA 3+` | Classic-desert skin variant. |
| `data/skins/classic-forest/License.txt` | `CC-BY-SA 3.0` / `CC-BY-SA 3+` | Classic-forest skin variant. |
| `data/skins/classic-ocean/License.txt` | `CC-BY-SA 3.0` / `CC-BY-SA 3+` | Classic-ocean skin variant. |
| `data/skins/classic-ruby/License.txt` | `CC-BY-SA 3.0` / `CC-BY-SA 3+` | Classic-ruby skin variant. |
| `data/skins/common/License.txt` | `CC-BY-SA 3.0` (yeKcim / Anthony Carré) | `glass_section.png` shared across classic skins. |
| `data/ttf/LICENSE` | `GPL-3.0` with font embedding exception + `Apache-2.0` (`wqyMicroHei`); `OFL-1.1` (`Noto`, `Cantarell`, `SigmarOne`) | Bundled TTF fonts. Not ported directly (Roblox uses platform fonts). |
| `data/ttf/SIL Open Font License.txt` | `OFL-1.1` (full text, Vernon Adams, Sigmar One) | Full OFL 1.1 license text. |
| `data/shaders/MLAA_COPYING` | **2-clause BSD-style** with attribution clause (Jimenez et al. 2010, Lauri Kasanen 2011) | MLAA shader. Not ported (Roblox renderer). |

### 3. Vendored Third-Party Libraries (`lib/` and header-only in `src/utils/`)

None of the vendored C/C++ libraries under `lib/` are compiled into or ported to OpenKart; they are replaced by Roblox engine/platform services. They are inventoried here for completeness so we never copy code from a vendored library by mistake without knowing its license.

| Directory / File(s) in `stk-code` | License File(s) or Header Source | License | Ported? |
|---|---|---|---|
| `lib/angelscript/` | Header in `lib/angelscript/include/angelscript.h` (no standalone file) | `Zlib` | No (Roblox Luau) |
| `lib/bullet/` | `lib/bullet/LICENSE`, `lib/bullet/BulletLicense.txt`, `lib/bullet/AUTHORS` | `Zlib` | No (reimplemented Luau kart solver; `src/physics/btKart.*` is GPLv3+ STK code used as behavioral reference) |
| `lib/dnsc/` | `lib/dnsc/LICENSE` | `MIT` | No (Roblox networking) |
| `lib/enet/` | `lib/enet/LICENSE`, `lib/enet/docs/license.dox` | `MIT` | No (Roblox networking) |
| `lib/graphics_engine/` | STK renderer (covered by root `COPYING` GPLv3+); generated loaders `src/gl.c`, `src/vulkan.c` have SPDX `(WTFPL OR CC0-1.0) AND Apache-2.0` | `GPL-3.0-or-later` + glad loader SPDX | No (Roblox renderer) |
| `lib/graphics_utils/` | Header in `lib/graphics_utils/mipmap/imgresize.c` (no standalone file) | `Zlib` | No (Roblox texture pipeline) |
| `lib/irrlicht/` | `lib/irrlicht/doc/irrlicht-license.txt`, `bzip2-license.txt`, `jpglib-license.txt`, `libpng-license.txt` | `Zlib` (Irrlicht), `bzip2-1.0.6`, `IJG`, `Libpng` | No (Roblox engine) |
| `lib/libsquish/` | `lib/libsquish/LICENSE.txt` | `MIT` | No (Roblox texture pipeline) |
| `lib/mcpp/` | Header in `lib/mcpp/main.c` (no standalone file) | `BSD-2-Clause` (with public domain DECUS heritage) | No (build/shader preprocessor) |
| `lib/mojoal/` | `lib/mojoal/LICENSE.txt` | `Zlib` | No (Roblox `SoundService`) |
| `lib/sheenbidi/` | `lib/sheenbidi/LICENSE` | `Apache-2.0` | No (Roblox text rendering) |
| `lib/simd_wrapper/simde/` | `lib/simd_wrapper/simde/COPYING` | `MIT` | No (native SIMD) |
| `lib/tinygettext/` | `lib/tinygettext/LICENSE.md` | `Zlib` | No (Roblox Localization) |
| `lib/wiiuse/` | `lib/wiiuse/LICENSE`, `lib/wiiuse/cmake/LICENSE_1_0.txt` (CMake modules: `BSL-1.0`) | `GPL-3.0` (`BSL-1.0` for CMake helpers) | No (Wiimote driver) |
| `src/utils/utf8.h`, `src/utils/utf8/` | Header in `src/utils/utf8.h` | `BSL-1.0` (Boost-style permissive, Nemanja Trifunovic 2006) | No (Luau `utf8` library) |

### 4. External Assets Repository (`stk-assets` — Future Audit)

Track models, kart models, textures, music, and SFX live outside `stk-code` in the separate `stk-assets` SVN repository. Each track, kart, texture pack, music track, and SFX directory in `stk-assets` ships its own `licenses.txt` (Debian copyright format) with mixed licenses (`CC-BY`, `CC-BY-SA`, `CC0`/Public Domain, `GPL`, etc.).

Before importing any batch of upstream assets into `assets/`:
1. Pin the `stk-assets` SVN revision in the table at the top of this file.
2. Run the `asset-auditor` subagent against every file in the batch.
3. Record author, source URL, license, and changes in `assets/CREDITS.md`. Skip anything unverified or containing Nintendo IP.
