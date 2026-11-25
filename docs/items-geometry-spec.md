# SuperTuxKart Item & Powerup Geometry Spec (`STK 1.5`)

Authoritative geometry, submesh, material, and license audit for all item & powerup models in pinned upstream **SuperTuxKart `1.5`** (`supertuxkart/stk-code`, commit `1fb491f507216c5d181ccd85f29ff08eca003827`), converted at locked scale `METERS_PER_STUD = 1.0` (`1 m = 1 stud`).

---

## 1. Authoritative Upstream Model Mapping

### 1.1 Track Pickups & Road Hazards (`data/items.xml:L1-L14`, `src/items/item_manager.cpp:L60-L127`)

`ItemManager::loadDefaultItemMeshes` reads `data/items.xml` and maps each logical item key to its authoritative high-res `.spm`, optional `lowmodel` LOD, `glow` RGB tint, and minimap/world `icon-<name>.png`:

| Key (`items.xml`) | Enum (`item.hpp`) | `model` | `lowmodel` | `glow` RGB | `icon` Texture (`data/textures/`) | Citation |
|---|---|---|---|---|---|---|
| `bonus-box` | `ITEM_BONUS_BOX` | `gift-box.spm` | `gift-box-low.spm` | `31 202 253` | `icon-bonus-box.png` | `data/items.xml:L3`, `item_manager.cpp:L76, L92, L121` |
| `banana` | `ITEM_BANANA` | `banana.spm` | `banana-low.spm` | `197 152 37` | `icon-banana.png` | `data/items.xml:L4`, `item_manager.cpp:L75` |
| `nitro-big` | `ITEM_NITRO_BIG` | `nitrotank-big.spm` | `nitrotank-big-low.spm` | `0 70 158` | `icon-nitro-big.png` | `data/items.xml:L5`, `item_manager.cpp:L78` |
| `nitro-small` | `ITEM_NITRO_SMALL` | `nitrotank-small.spm` | `nitrotank-small-low.spm` | `0 70 158` | `icon-nitro-small.png` | `data/items.xml:L6`, `item_manager.cpp:L79` |
| `bubblegum` | `ITEM_BUBBLEGUM` | `bubblegum.spm` | `bubblegum-low.spm` | `246 150 209` | `icon-bubblegum.png` | `data/items.xml:L10`, `item_manager.cpp:L77` |
| `bubblegum-nolok` | `ITEM_BUBBLEGUM_NOLOK` | `bubblegum-nolok.spm` | `bubblegum-nolok-low.spm` | `20 190 0` | `icon-bubblegum-nolok.png` | `data/items.xml:L11`, `item_manager.cpp:L80` |
| `easter-egg` | `ITEM_EASTER_EGG` | `easter_egg.spm` | *(none)* | `0 60 120` | `icon-easter-egg.png` | `data/items.xml:L12`, `item_manager.cpp:L81` |

### 1.2 Powerups & Attachments (`data/powerup.xml:L1-L97`, `src/items/powerup_manager.cpp`, `src/items/attachment.cpp`)

| Powerup (`powerup.xml`) | World / Projectile / Attachment Model | HUD Icon (`powerup.xml`) | Notes | Citation |
|---|---|---|---|---|
| `zipper` | *(none — speed/boost effect only)* | `zipper_collect.png` | Boost effect only (`Kart::handleZipper`) | `data/powerup.xml:L3` |
| `bowling` | `bowling.spm` | `bowling-icon.png` | Projectile | `data/powerup.xml:L4-L8` |
| `bubblegum` | `bubblegum.spm` (drop), `bubblegum_shield.spm` (shield) | `bubblegum-icon.png` | Drop / shield attachment | `data/powerup.xml:L9`, `data/items.xml:L10` |
| `cake` | `cake.spm` | `cake-icon.png` | Homing projectile | `data/powerup.xml:L10-L13` |
| `anchor` | `anchor.spm` | `anchor-icon.png` | Attachment | `data/powerup.xml:L14-L15` |
| `switch` | *(none — global item swap)* | `swap-icon.png` | Swap effect | `data/powerup.xml:L16` |
| `swatter` | `swatter.spm`, `swatter_anim.spm`, `bomb.spm` | `swatter-icon.png` | Attachment / bomb | `data/powerup.xml:L17`, `attachment_manager.cpp` |
| `rubber-ball` | `rubber_ball.spm` | `rubber_ball-icon.png` | Driveline projectile | `data/powerup.xml:L75-L89` |
| `parachute` | `parachute.spm` | `parachute-icon.png` | Attachment (`SPMA` bind pose) | `data/powerup.xml:L90-L91` |
| `plunger` | `plunger.spm` | `plunger-icon.png` | Projectile | `data/powerup.xml:L92-L96` |

### 1.3 Item Materials (`data/models/materials.xml:L1-L25`)

- `gift-loop.png` uses `gloss-map="gift-loop-gloss.png"` (`L5`).
- `stk_mod_nitroLogo.png` uses `shader="additive" disable-z-write="Y"` (`L13`) for the glowing `"N"` badge on `nitrotank-big.spm` and `nitrotank-small.spm`.
- `bowling.png` uses `gloss-map="bowling_spec.png"` (`L17`).
- `bubblegum_shield.png` & `bubblegum_shield_nolok.png` use `shader="alphablend" disable-z-write="Y"` (`L20-L21`).
- `parachute.png` uses `backface-culling="n" ignore="Y"` (`L22`).

---

## 2. Measured Source `.spm` Geometry & License Audit (`METERS_PER_STUD = 1.0`)

Audited via `tools/stk2rbx/mesh_inspect.py` against STK `1.5` (`data/models/*.spm` & `data/models/licenses.txt`):

| Model File | Format | Verts | Tris | Submeshes | Size `(W, H, L)` studs | Local BBox Min -> Max (studs) | Texture(s) | Texture License Status (`data/models/licenses.txt`) |
|---|---|---|---|---|---|---|---|---|
| `gift-box.spm` | `SPMN` | 280 | 245 | 2 | `[0.89864, 0.98570, 0.89864]` | `[-0.4493, 0.0887, -0.4493]` -> `[0.4493, 1.0744, 0.4493]` | `gift-box.png`, `gift-loop.png` | **VERIFIED** (`CC-BY-SA 3.0`: `L8-L29`, `L40-L45`) |
| `banana.spm` | `SPMN` | 303 | 334 | 1 | `[2.24253, 1.24308, 2.24214]` | `[-1.1414, 0.1519, -1.1211]` -> `[1.1011, 1.3950, 1.1211]` | `banana.png` | **VERIFIED** (`CC-BY-SA 3.0`: `L79-L83`) |
| `nitrotank-big.spm` | `SPMN` | 294 | 466 | 2 | `[0.80722, 1.39400, 1.39400]` | `[-0.4036, 0.1005, -0.6590]` -> `[0.4036, 1.4945, 0.7350]` | `stk_mod_nitroBarrel.png`, `stk_mod_nitroLogo.png` | **VERIFIED** (`CC-BY-SA 4.0`: `L107-L119`) |
| `nitrotank-small.spm` | `SPMN` | 302 | 398 | 2 | `[0.40034, 0.71903, 0.71903]` | `[-0.2002, 0.0859, -0.3207]` -> `[0.2002, 0.8049, 0.3984]` | `stk_mod_nitroBottle.png`, `stk_mod_nitroLogo.png` | **VERIFIED** (`CC-BY-SA 3.0`: `L142-L151` mesh, `CC-BY-SA 4.0`: `L114-L119` tex) |
| `bubblegum.spm` | `SPMN` | 180 | 310 | 1 | `[2.19902, 0.31964, 2.19063]` | `[-1.1057, 0.0000, -1.1559]` -> `[1.0933, 0.3196, 1.0347]` | `bubblegum.png` | **VERIFIED** (`CC-BY-SA 3.0`: `L14-L28`) |
| `bubblegum-nolok.spm` | `SPMN` | 306 | 415 | 1 | `[2.19902, 0.51767, 2.19063]` | `[-1.1057, 0.0000, -1.1559]` -> `[1.0933, 0.5177, 1.0347]` | `bubblegum_nolok.jpg` | **VERIFIED** (`CC-BY-SA 3.0`: `L52-L64`) |
| `easter_egg.spm` | `SPMN` | 92 | 112 | 1 | `[1.00000, 1.35000, 1.00000]` | `[-0.5000, 0.1716, -0.4838]` -> `[0.5000, 1.5216, 0.5162]` | `easter_egg_3.png` | **VERIFIED** (`CC-BY-SA 3.0`: `L122-L125`) |
| `bowling.spm` | `SPMN` | 367 | 320 | 1 | `[0.88000, 0.88000, 0.88000]` | `[-0.4400, -0.4400, -0.4400]` -> `[0.4400, 0.4400, 0.4400]` | `bowling.png` | **VERIFIED** (`CC-BY-SA 3.0`: `L85-L97`) |
| `cake.spm` | `SPMN` | 393 | 324 | 1 | `[0.68800, 0.66807, 0.68453]` | `[-0.3354, -0.2156, -0.3320]` -> `[0.3526, 0.4525, 0.3526]` | `cake.png` | **VERIFIED** (`CC-BY-SA 3.0`: `L17-L28`) |
| `anchor.spm` | `SPMN` | 334 | 470 | 1 | `[0.88256, 1.11602, 0.57600]` | `[-0.4413, -0.0461, -1.1880]` -> `[0.4413, 1.0699, -0.6120]` | `anchor.png` | **VERIFIED** (`CC-BY-SA 3.0`: `L8-L28`) |
| `rubber_ball.spm` | `SPMN` | 659 | 1212 | 1 | `[1.84012, 1.84012, 1.84068]` | `[-0.9201, -0.9202, -0.9216]` -> `[0.9201, 0.9200, 0.9190]` | `balldimpleddark.jpg` | **FLAGGED** — `rubber_ball.spm` is `CC-BY-SA 4.0` (`L113-L118`), `licenses.txt:L74` spells texture `balldimpledark.jpg` (1 `d`) vs actual file `balldimpleddark.jpg` (`2 d`s); texture upload skipped pending clarity |
| `parachute.spm` | `SPMA` | 222 | 228 | 1 | `[0.94791, 0.93237, 1.46978]` | `[-0.4740, 0.1082, -1.6084]` -> `[0.4740, 1.0405, -0.1386]` | `parachute.png` | **SKIPPED TEX** — `parachute.spm` is `CC-BY-SA 3.0` (`L23`), `parachute.png` omitted from `licenses.txt` |
| `plunger.spm` | `SPMN` | 148 | 216 | 1 | `[0.39242, 0.39242, 0.83877]` | `[-0.1859, -0.1768, -0.4112]` -> `[0.2065, 0.2156, 0.4276]` | `plunger.png` | **SKIPPED TEX** — `plunger.spm` is `CC-BY-SA 3.0` (`L24`), `plunger.png` omitted from `licenses.txt` |
| `swatter.spm` | `SPMA` | 573 | 580 | 1 | `[0.77614, 2.00261, 0.21815]` | `[-0.6705, 0.0005, -0.1056]` -> `[0.1056, 2.0031, 0.1125]` | `swatter.png` | **VERIFIED** (`CC-BY-SA 3.0`: `L102-L105`) |
| `bomb.spm` | `SPMA` | 295 | 266 | 1 | `[0.50000, 0.31119, 0.41926]` | `[-0.2500, 0.2440, -1.0442]` -> `[0.2500, 0.5552, -0.6249]` | `tnt-bomb.png` | **VERIFIED** (`CC-BY-SA 3.0`: `L13`, `L190-L195`) |
| `bubblegum_shield.spm` | `SPMN` | 174 | 308 | 1 | `[2.00000, 2.00000, 1.94985]` | `[-1.0000, -1.0000, -0.9749]` -> `[1.0000, 1.0000, 0.9749]` | `bubblegum_shield.png` | **VERIFIED** (`CC-BY-SA 3.0`: `L67-L72`) |
