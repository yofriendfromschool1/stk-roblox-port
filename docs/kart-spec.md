# SuperTuxKart 1.5 Tux Kart Specification (`karts/tux`, rev `18627`)

- **Upstream source:** `stk-assets/karts/tux/` pinned at SVN rev `18627` (`https://svn.code.sf.net/p/supertuxkart/code/!svn/bc/18627/stk-assets/karts/tux/`)
- **Upstream engine references:** `stk-code` tag `1.5` (`1fb491f507216c5d181ccd85f29ff08eca003827`; `src/karts/kart_model.cpp`, `src/graphics/sp_mesh_loader.cpp`, `lib/graphics_engine/include/ge_animation.hpp`, `data/official_karts.xml`)
- **OpenKart scale:** `METERS_PER_STUD = 1.0` (`1` meter = `1` stud), coordinate transform `S = diag(1, 1, -1)` with `flip_triangle_winding`
- **Generated static assembly:** [`tux.model.json`](../assets/roblox/karts/tux.model.json) and `.glb` exports under `build/karts/tux/` via [`kart_emit.py`](../tools/stk2rbx/kart_emit.py)

---

## 1. Directory Inventory (19 Files, SVN rev `18627`)

Every file in `stk-assets/karts/tux/` was audited per-file against `karts/tux/licenses.txt` and recorded in [CREDITS.md](../assets/CREDITS.md). Zero `Copyright: ???` entries exist in this directory.

| File | Role | License (`karts/tux/licenses.txt`) | OpenKart Status |
|---|---|---|---|
| `kart.xml` | Kart metadata, animations, wheels, nitro emitters, headlights, hat socket, exhaust ref | `CC-BY-SA 3.0` (`Julian "XGhost" Schönbächler`) | Parsed by `tools/stk2rbx/kart_emit.py` |
| `materials.xml` | Per-texture gloss maps & colorization flags (`4` materials) | `CC-BY-SA 3.0` | Parsed & audited; texture conversion deferred |
| `tux.spm` | Combined kart body + Tux driver skeletal mesh (`SPMA`) | `CC-BY-SA 3.0` + Tux attribution (`Larry Ewing / The GIMP`) | Exported as static `Body` + `Driver` `.glb` (`frame 20` straight pose) |
| `wheel-front-left.spm`, `wheel-front-right.spm`, `wheel-rear-left.spm`, `wheel-rear-right.spm` | Rigid wheel meshes (`SPMN`) | `CC-BY-SA 3.0` | Exported as 4 static wheel `.glb`s + Rojo nodes |
| `headlight.spm` | Night-only spotlight & glow cone mesh (`SPMN`) | `public-domain` (`Benau`, 2017) | **Excluded** (references un-audited external textures in `data/textures/`) |
| `tux_icon.png` | HUD & minimap player icon (`8,807` B) | `GPL 2.0` (`yeKcim`) + Tux attribution (`Larry Ewing / The GIMP`) | Imported & uploaded (`rbxassetid://106784086588016`) |
| `engine.png`, `engine_gloss.png`, `tux_body.png`, `tux_body_gloss.png`, `tux_shadow.png`, `tuxkart.png`, `tuxkart_gloss.png`, `wheel.png`, `wheel_gloss.png` | Diffuse textures, gloss maps, projected shadow decal | `CC-BY-SA 3.0` (+ Tux attribution on `tux_body.png`) | Audited; deferred to Roblox PBR texture pass |
| `licenses.txt` | Debian DEP-5 per-file copyright ledger | — | Audited in `assets/CREDITS.md` |

---

## 2. `kart.xml` Configuration (`karts/tux/kart.xml:L1-L55`)

Parsed by `KartModel::loadInfo` (`src/karts/kart_model.cpp:L167-L253`).

### 2.1 Top-Level Attributes & Sounds (`kart.xml:L3-L12`)
- `name="Tux"`, `version="3"`, `kart_type="medium"`, `groups="standard"`, `rgb="1.00 0.00 0.00"`
- `model-file="tux.spm"`, `icon-file="tux_icon.png"`, `minimap-icon-file="tux_icon.png"`, `shadow-file="tux_shadow.png"`
- `<sounds engine="large"/>` (`kart.xml:L12`)

### 2.2 Animation Frame Indices (`kart.xml:L13-L23`)
`KartModel` defaults to `m_animation_speed = 25` fps (`src/karts/kart_model.cpp:L156`):
- Steering pose range: `left = 0`, `straight = 20`, `right = 40`
- Winning sequence: `start-winning = 60`, `start-winning-loop = 233`, `end-winning = 320`
- Losing sequence: `start-losing = 340`, `start-losing-loop = 412`, `end-losing = 550`
- Jump sequence: `start-jump = 570`, `start-jump-loop = 604`

### 2.3 Wheels (`kart.xml:L24-L33`, `kart_model.cpp:L198-L204, L471-L486`)
In `KartModel::attachModel`, wheel graphics radius is computed from each wheel mesh's Y extent:
`m_wheel_graphics_radius[i] = 0.5f * (wheel_max.getY() - wheel_min.getY())` (`kart_model.cpp:L478`). Notice each wheel's `position.y` in `kart.xml` equals its radius (`0.110 m` front, `0.140 m` rear), so wheel bottoms sit at local `Y = 0.000 m`.

| Slot | Model File | STK `position` (m) | Roblox Pos (studs, `S = diag(1,1,-1)`) | Mesh Radius `0.5 * H` (m) | Suspension Defaults (`kart_model.cpp:L142-L145`) |
|---|---|---|---|---|---|
| `front-left` | `wheel-front-left.spm` | `(-0.319630, 0.110000, +0.410000)` | `(-0.3196, 0.1100, -0.4100)` | `0.1099` | `min = -0.07`, `max = 0.20` m |
| `front-right` | `wheel-front-right.spm` | `(+0.319625, 0.110000, +0.410000)` | `(+0.3196, 0.1100, -0.4100)` | `0.1099` | `min = -0.07`, `max = 0.20` m |
| `rear-left` | `wheel-rear-left.spm` | `(-0.355000, 0.140000, -0.340000)` | `(-0.3550, 0.1400, +0.3400)` | `0.1400` | `min = -0.07`, `max = 0.20` m |
| `rear-right` | `wheel-rear-right.spm` | `(+0.355000, 0.140000, -0.340000)` | `(+0.3550, 0.1400, +0.3400)` | `0.1400` | `min = -0.07`, `max = 0.20` m |

### 2.4 Attachments, Emitters & Headlights (`kart.xml:L34-L54`)
- **Nitro emitters (`kart.xml:L34-L37`):**
  - `nitro-emitter-a`: STK `(0.200000, 0.360000, -0.580000)` → Roblox `(0.20, 0.36, +0.58)` studs
  - `nitro-emitter-b`: STK `(-0.200000, 0.360000, -0.580000)` → Roblox `(-0.20, 0.36, +0.58)` studs
- **Headlights (`kart.xml:L38-L49`, `kart_model.cpp:L530-L562`):** 2× `headlight.spm` attached to bone `"Car"` at STK `(-0.258784, 0.125951, 0.704622)` and `(+0.259808, 0.125951, 0.704622)`, `rotation="-0.000011 -0.000000 0.000000"`, `scale="1 1 1"`. Only spawned when `track->getIsDuringDay() == false` (`kart_model.cpp:L533`). **Excluded from OpenKart export** because `headlight.spm` references external `data/textures/{gfxGlow_blue_a,gfxGlow_red_a,stk_conelight_a}.png` that are not yet license-audited.
- **Hat socket (`kart.xml:L50-L53`, `kart_model.cpp:L234-L246, L564-L578`):** `bone="Head"`, STK `position=(-0.000000, 0.690000, -0.030000)`, `rotation=(-7.594650, 0.000002, 0.000016)`, `scale=(1, 1, 1)`.
- **Exhaust (`kart.xml:L54`, `data/gfx/kart_exhaust.xml:L1-L30`):** Shared STK box particle emitter (`0.05 × 0.05 × 0.10 m`), `smoke.png`, rate `200–300/s`, lifetime `10–40 ms`, size `0.05–0.10` (`5x` growth).

---

## 3. `materials.xml` (`karts/tux/materials.xml:L1-L8`)

| Material Texture (`name`) | `gloss-map` | `colorizable` | `colorization-factor` | Part in Static Export |
|---|---|---|---|---|
| `engine.png` | `engine_gloss.png` | `Y` | `0.00` | `Body` (`tux.spm` submesh 0) |
| `tux_body.png` | `tux_body_gloss.png` | `—` | `—` | `Driver` (`tux.spm` submesh 1) |
| `tuxkart.png` | `tuxkart_gloss.png` | `Y` | `0.00` | `Body` (`tux.spm` submesh 2) |
| `wheel.png` | `wheel_gloss.png` | `—` | `—` | `Body` steering wheel/hub (`tux.spm` submesh 3) + 4 `Wheel*` meshes |

---

## 4. `.spm` Mesh Audit (All 6 Meshes)

| Mesh File | Format | Size (B) | Verts | Tris | Submeshes | STK Bounds Min → Max (m) | STK Extent `[W, H, L]` (m) |
|---|---|---|---|---|---|---|---|
| `tux.spm` | `SPMA` | `173,029` | `2,962` | `4,626` | `4` | `(-0.4106, 0.0763, -0.7013)` → `(0.4106, 0.7522, 0.7366)` | `(0.8213, 0.6759, 1.4379)` |
| `— submesh 0 (engine.png)` | `SPMA` | — | `1,247` | `2,086` | — | `(-0.3676, 0.1958, -0.7013)` → `(0.3676, 0.5492, 0.5543)` | `(0.7352, 0.3534, 1.2556)` |
| `— submesh 1 (tux_body.png)` | `SPMA` | — | `864` | `1,354` | — | `(-0.1817, 0.1064, -0.1435)` → `(0.1817, 0.7522, 0.2988)` | `(0.3634, 0.6458, 0.4423)` |
| `— submesh 2 (tuxkart.png)` | `SPMA` | — | `660` | `924` | — | `(-0.4106, 0.0763, -0.5792)` → `(0.4106, 0.3058, 0.7366)` | `(0.8213, 0.2295, 1.3158)` |
| `— submesh 3 (wheel.png)` | `SPMA` | — | `191` | `262` | — | `(-0.2596, 0.0800, -0.5822)` → `(0.2596, 0.5131, 0.4400)` | `(0.5192, 0.4331, 1.0222)` |
| `wheel-front-left.spm` | `SPMN` | `7,539` | `259` | `384` | `1` (`wheel.png`) | `(-0.0989, -0.1099, -0.1099)` → `(0.0989, 0.1099, 0.1099)` | `(0.1978, 0.2198, 0.2198)` |
| `wheel-front-right.spm` | `SPMN` | `7,539` | `259` | `384` | `1` (`wheel.png`) | `(-0.0989, -0.1099, -0.1099)` → `(0.0989, 0.1099, 0.1099)` | `(0.1978, 0.2198, 0.2198)` |
| `wheel-rear-left.spm` | `SPMN` | `7,635` | `259` | `400` | `1` (`wheel.png`) | `(-0.1260, -0.1400, -0.1400)` → `(0.1760, 0.1400, 0.1400)` | `(0.3020, 0.2800, 0.2800)` |
| `wheel-rear-right.spm` | `SPMN` | `7,635` | `259` | `400` | `1` (`wheel.png`) | `(-0.1760, -0.1400, -0.1400)` → `(0.1260, 0.1400, 0.1400)` | `(0.3020, 0.2800, 0.2800)` |
| **Static Assembly Total (`Body + Driver + 4 Wheels`)** | — | — | **`3,998`** | **`6,194`** | **`8` parts / `6` GLB nodes** | World assembly Y span: `0.0000` (wheels) → `0.7522` (driver head) | Well below Roblox's `20,000` tri cap |
| `headlight.spm` *(excluded)* | `SPMN` | `1,116` | `43` | `44` | `3` (`gfxGlow_blue_a`, `gfxGlow_red_a`, `stk_conelight_a`) | `(-0.0721, -0.0711, -1.2755)` → `(0.0702, 0.0713, 0.4930)` | `(0.1424, 0.1424, 1.7685)` |

### 4.1 Collision Chassis Bounds Parity (`data/official_karts.xml:L18` vs `tux.spm`)
In `KartModel::loadModels` (`src/karts/kart_model.cpp:L649-L650, L766-L777`), STK measures the `m_mesh` (`tux.spm`, containing both chassis and driver) AABB and truncates each dimension to 3 decimals (`int(v * 1000) / 1000.0f`):
- `tux.spm` raw extent: `(0.82126, 0.67595, 1.43788)` m (`= studs` at `METERS_PER_STUD = 1.0`)
- Truncated 3 decimal places: `(0.821, 0.675, 1.437)`
- `data/official_karts.xml:L18`: `<kart name="tux" type="medium" width="0.821" height="0.675" length="1.437" gravity-shift="0 0.3375 0"/>` — **exact match**.

---

## 5. Animation Mechanism (`tux.spm` — Bone-Driven `SPMA`, Not Vertex Frames)

`tux.spm` uses STK's skinned skeletal **`SPMA`** binary format (`src/graphics/sp_mesh_loader.cpp:L268, L405-L418, L630-L645, L698-L766`; `lib/graphics_engine/include/ge_animation.hpp:L43-L145`):
- **Pre-computed rest pose (`sp_mesh_loader.cpp:L268`):** Vertex positions/normals stored in the mesh buffers are already in the pre-computed straight pose (`m_bind_frame = 20`, matching `kart.xml:L14` `straight="20"`), allowing static `frame 20` extraction without evaluating bone matrices.
- **Per-vertex skinning payload:** `4 × int16` joint indices + `4 × float16` bone weights (`16` bytes per vertex).
- **Armature trailer:** `1` armature, `16` joints (`used = 16`, `total = 16`), `60` sparse keyframes spanning frames `0..613` (`LocRotScale` 40-byte TRS records interpolated via linear location/scale + quaternion slerp in `Armature::getPose`, `ge_animation.hpp:L147-L247`).
- **Exact 16-bone hierarchy parsed from `tux.spm`:**
  - Roots (`parent = -1`): `[0] Car`, `[1] Steer`, `[2] Body`, `[10] Hand.R`, `[13] Hand.L`
  - Children of `[2] Body`: `[3] Leg.R` → `[14] Feet.R`; `[4] Leg.L` → `[15] Feet.L`; `[5] Arm1.R` → `[7] Arm2.R` → `[9] Arm3.R`; `[6] Arm1.L` → `[11] Arm2.L` → `[12] Arm3.L`; `[8] Head`

---

## 6. Roblox Native Representation Gaps (Flagged)

| Upstream Feature (`karts/tux`) | Gap in Roblox Native Representation | OpenKart Handling |
|---|---|---|
| **SPMA skeletal animation + `kart.xml` frame ranges (`left=0`, `straight=20`, `right=40`, win/lose/jump)** | Roblox does not load STK `.spm`/`SPMA` binaries and represents skeletal animation via rigged `Bone` hierarchies + `AnimationClip` / Motor6D transforms. | **First pass exports static straight pose (`frame 20`) + separate rigid wheels** (`WheelFrontLeft/Right`, `WheelRearLeft/Right` can still steer/spin rigidly in Luau). Logged in [divergences.md](divergences.md). |
| **Bone-attached sockets (`headlight.spm` on `"Car"`, `hat` on `"Head"`)** | Static `MeshPart` hierarchy has no `Bone` nodes until the rigged glTF/FBX pass. | `NitroEmitterA/B` emitted as `Attachment`s on `ChassisRoot`; `hat` socket metadata recorded in `Tux` `Attributes`; `headlight.spm` excluded (external textures un-audited). |
| **STK `gloss-map` (`*_gloss.png`)** | Irrlicht/STK shader gloss maps pack specular intensity/shininess differently from Roblox PBR `SurfaceAppearance` (`ColorMap`, `RoughnessMap`, `MetalnessMap`, `NormalMap`). | Deferred to texture/PBR pass; requires offline gloss → roughness/metalness channel conversion. |
| **STK `colorizable="Y"` HSV-shift shader (`engine.png`, `tuxkart.png`)** | Roblox `SurfaceAppearance.Color` / `MeshPart.Color` performs multiplicative RGB tinting rather than STK's hue-shifting colorization shader. | Either bake/palette-shift offline per colorway or note RGB-tint approximation when textures land. |
| **Projected ground shadow (`tux_shadow.png`)** | No Irrlicht projected kart shadow plane; Roblox uses dynamic directional ShadowMap or a custom raycasted `Decal`/Part. | Rely on native Roblox shadows (or add raycasted shadow quad later if needed). |
| **STK particle XML (`kart_exhaust.xml` + `smoke.png`) & nitro emitters** | XML box emitter with ms lifetimes must translate to Roblox `ParticleEmitter` properties (`Rate`, `Lifetime`, `Size` `NumberSequence`). | Nitro `Attachment` coordinates preserved on `ChassisRoot`; faithful emitter tuning deferred to `KartPresentation.lua`. |
