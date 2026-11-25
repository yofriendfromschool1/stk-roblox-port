# SuperTuxKart Items & Powerups Spec (`STK 1.5`)

Source audit of pinned upstream **SuperTuxKart `1.5`** (`supertuxkart/stk-code`, commit `1fb491f507216c5d181ccd85f29ff08eca003827`). All timing values use STK's fixed physics rate of `120 Hz` (`1 tick = 1/120 s`).

---

## 1. Race Mode Rules & Item Collection Eligibility

| Mechanism | Upstream Behavior | Source Citation |
|---|---|---|
| **Bonus Box Suppression in Time Trial** | `StandardRace::haveBonusBoxes()` returns `RaceManager::get()->getMinorMode() != RaceManager::MINOR_MODE_TIME_TRIAL`. All other standard race modes (`NORMAL_RACE`, `FOLLOW_LEADER`, `LAP_TRIAL`, etc.) spawn bonus boxes (`ITEM_BONUS_BOX`). | `src/modes/standard_race.cpp:L64-L68` |
| **Time Trial Starting Zippers** | In `MINOR_MODE_TIME_TRIAL`, each kart starts with `POWERUP_ZIPPER` and count equal to `RaceManager::get()->getNumLaps()` (`kart->setPowerup(POWERUP_ZIPPER, num_laps)`). | `src/modes/standard_race.cpp:L49-L59` |
| **Track Item Loading Gate** | `Track::itemCommand` handles `banana`, `item` (`ITEM_BONUS_BOX`), `small-nitro`, `big-nitro`, and `easter-egg`. If `item_type == ITEM_BONUS_BOX && !World::getWorld()->haveBonusBoxes()`, loading returns early (nitro containers and bananas still spawn in Time Trial). | `src/tracks/track.cpp:L2750-L2800` |
| **Per-Kart & World Collection Gate** | `ItemManager::checkItemHit(AbstractKart *kart)` returns immediately when `m_disable_item_collection` is set or `kart->getType() == RaceManager::KT_AI && dynamic_cast<SpareTireAI*>(...)`. | `src/items/item_manager.cpp:L395-L420` |
| **Shield vs Bubblegum Immunity** | During `ItemManager::checkItemHit`, `ITEM_BUBBLEGUM` and `ITEM_BUBBLEGUM_NOLOK` are skipped while `kart->isShielded()`. | `src/items/item_manager.cpp:L430-L436` |
| **Powerup Weight List by Minor Mode** | `PowerupManager::computeWeightsForRace` maps minor mode to XML list: `TIME_TRIAL`/`LAP_TRIAL`/`NORMAL_RACE` -> `race-weight-list`; `FOLLOW_LEADER` -> `ftl-weight-list`; `3_STRIKES`/`FREE_FOR_ALL`/`CAPTURE_THE_FLAG` -> `battle-weight-list`; `TUTORIAL` -> `tutorial-weight-list`; `EASTER_EGG`/`OVERWORLD`/`CUTSCENE`/`SOCCER` -> `soccer-weight-list`. | `src/items/powerup_manager.cpp:L528-L547` |

---

## 2. Item Placement, Raycast Drop, Hitbox & Respawn Timers

| Rule | Upstream Value / Logic | Source Citation |
|---|---|---|
| **Scene XML Tags -> `ItemType`** | `banana` -> `ITEM_BANANA`; `item` -> `ITEM_BONUS_BOX`; `small-nitro` -> `ITEM_NITRO_SMALL`; `big-nitro` -> `ITEM_NITRO_BIG`; `easter-egg` -> `ITEM_EASTER_EGG`. | `src/tracks/track.cpp:L2758-L2782`, `src/items/item.hpp` |
| **`drop="true"` Default & Terrain Snap** | In `Track::itemCommand`, `drop` defaults to `true`. `ItemManager::dropNewItem` raycasts downward from `xyz` along track/kart normal and places the item at `hit_point + normal * (-0.05f)` (and `placeItem` instantiates `ItemState` + `Item`). | `src/tracks/track.cpp:L2788-L2839`, `src/items/item_manager.cpp:L306`, `L345-L366` |
| **Dropped-Item Owner Immunity** | `ItemState` constructor initializes `m_deactive_ticks = owner ? stk_config->time2Ticks(1.5f) : 0` (`180` ticks at `120 Hz`). `Item::hitKart` ignores `m_owner` while `getDeactivatedTicks() > 0`. | `src/items/item.cpp:L61-L62`, `src/items/item.hpp:L404-L407` |
| **Collision Hitbox (`m_distance_2`)** | `ItemState` sets `m_distance_2 = 1.2f` (squared distance radius threshold, i.e., $1.2\text{ m}^2$, $r \approx 1.095\text{ m}$). `Item::hitKart` computes local delta `lc = xyz - kart->getXYZ()`, halves vertical delta `lc.y /= 2.0f`, and triggers hit when `lc.length2() < m_distance_2`. | `src/items/item.cpp:L228`, `src/items/item.hpp:L408-L413` |
| **Respawn Timers (`stk_config.xml`)** | `<item-return-time bonusbox="2.0" nitro="2.0" banana="2.0" bubblegum="2.0"/>` -> `240` ticks (`2.0 s`) at `120 Hz`. `ItemState::collected` assigns respawn ticks by type; in battle modes (`World::getWorld()->isBattleMode()`), respawn delay is multiplied by `3` (`720` ticks / `6.0 s`). | `data/stk_config.xml:L226`, `src/items/item.cpp:L136-L182` |
| **Consumable Disappear Counter** | `ITEM_BUBBLEGUM` / `ITEM_BUBBLEGUM_NOLOK` sets `m_used_up_counter = stk_config->m_bubblegum_counter` (`1`, from `<bubblegum disappear-counter="1" shield-time="10.0" restrict-weapons="false"/>`); other items use `-1` (infinite respawns). On hit with `m_used_up_counter > 0`, `collected()` decrements the counter, sets `m_deactive_ticks = time2Ticks(0.5f)` (`60` ticks), sets `m_ticks_till_return = -1`, and `ItemManager::update` deletes the item when `isUsedUp()`. | `src/items/item.cpp:L92-L93`, `L136-L152`, `data/stk_config.xml:L248`, `src/items/item_manager.cpp:L479-L507` |

---

## 3. Nitro Containers vs Powerups (and `ITEM_BANANA` vs `POWERUP_BUBBLEGUM`)

### 3.1 Nitro Containers vs Gift Boxes
- **Nitro containers (`ITEM_NITRO_SMALL`, `ITEM_NITRO_BIG`) are NOT powerups:**
  - `Kart::collectedItem` checks `item->getType() == Item::ITEM_NITRO_SMALL` (`+1` via `m_nitro_small_container`) and `ITEM_NITRO_BIG` (`+3` via `m_nitro_big_container`), clamping collected energy up to `m_nitro_max` (`20.0`, `data/kart_characteristics.xml:L318-L320`).
  - Nitro is stored in the continuous nitro tank (`m_collected_energy`) and spent via `PA_NITRO` (`N`), independent of held powerups (`src/karts/kart.cpp:L1139-L1165`).
- **Bonus / Gift boxes (`ITEM_BONUS_BOX`) roll held powerups:**
  - `Kart::collectedItem` calls `m_powerup->hitBonusBox(n, item, add_info)` (`src/karts/kart.cpp:L1166-L1171`).
  - `Powerup::hitBonusBox` computes a deterministic roll via `PowerupManager::getRandomPowerup(m_kart->getPosition(), &n, rnd)` where `rnd` combines random/box/tick state (`src/items/powerup.cpp:L508-L598`).
  - Under default `<powerup collect-mode="new" no-explosive-items-timeout="15.0"/>` (`data/stk_config.xml:L237`), collecting a box replaces any held powerup (`POWERUP_MODE_NEW`), up to `MAX_POWERUPS = 5` (`src/items/powerup.hpp:L22`).
  - During the first `15.0 s` after race start (`m_no_explosive_items_timeout`), `getRandomPowerup` downgrades `POWERUP_CAKE` and `POWERUP_RUBBERBALL` to `POWERUP_BOWLING` (`src/items/powerup_manager.cpp:L618-L625`).

### 3.2 `ITEM_BANANA` vs `POWERUP_BUBBLEGUM`
- **`ITEM_BANANA` (pre-placed track hazard):** In STK `1.5`, driving into an `ITEM_BANANA` invokes `Attachment::hitBanana` (`src/items/attachment.cpp:L270-L393`), attaching a random negative attachment (`PARACHUTE`, `ANVIL`, or `BOMB`; or extending a held bomb timer by `max(curr, explosionDuration + 2.0f)`).
- **`POWERUP_BUBBLEGUM` (held powerup #1):** Pressing `PA_FIRE` (`Space`, `src/input/keyboard_config.cpp:L63`, edge-triggered into `m_fire_clicked` in `src/karts/kart.cpp:L1643-L1654`) activates `Powerup::use()` (`src/items/powerup.cpp:L247-L265`): if looking back it drops an `ITEM_BUBBLEGUM` behind the kart (`ItemManager::dropNewItem`); otherwise it creates a bubblegum shield (`10.0 s`).
- **OpenKart Slice 1 note:** See [divergences.md](divergences.md) for how Slice 1 exercises `PA_FIRE` drop + `ITEM_BANANA` / `SQUASH` contact effect prior to porting `Attachment` and `POWERUP_BUBBLEGUM` shields.

---

## 4. Full Powerup Weight Tables (`data/powerup.xml`)

Powerup enum order (`src/items/powerup_manager.hpp`, 10 columns matching XML `single` and `multi` attributes):
`1: BUBBLEGUM`, `2: CAKE`, `3: BOWLING`, `4: ZIPPER`, `5: PLUNGER`, `6: SWITCH`, `7: SWATTER`, `8: RUBBERBALL`, `9: PARACHUTE`, `10: ANVIL` (`single` grants `n = 1`, `multi` grants `n = 3` at `src/items/powerup_manager.cpp:L610-L616`).

### 4.1 `race-weight-list` (`data/powerup.xml:L153-L222`)

#### `num-karts="1"` (`L154-L169`)
| Section | Mode | BUBBLE | CAKE | BOWL | ZIPPER | PLUNGER | SWITCH | SWATTER | RUBBER | PARA | ANVIL | Sum |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 0 (Rank 1) | `single` | 140 | 0 | 300 | 100 | 225 | 75 | 160 | 0 | 0 | 0 | 1000 |
| 0 (Rank 1) | `multi` | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| 1 | `single` | 150 | 0 | 295 | 130 | 200 | 70 | 135 | 0 | 0 | 0 | 980 |
| 1 | `multi` | 0 | 0 | 20 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 20 |
| 2 | `single` | 150 | 0 | 310 | 135 | 180 | 65 | 135 | 0 | 0 | 0 | 975 |
| 2 | `multi` | 0 | 0 | 25 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 25 |
| 3 | `single` | 155 | 0 | 280 | 180 | 170 | 60 | 125 | 0 | 0 | 0 | 970 |
| 3 | `multi` | 0 | 0 | 30 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 30 |
| 4 (Last) | `single` | 170 | 0 | 180 | 275 | 150 | 50 | 85 | 0 | 0 | 0 | 910 |
| 4 (Last) | `multi` | 0 | 0 | 90 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 90 |

#### `num-karts="5"` (`L170-L182`)
| Section | Mode | BUBBLE | CAKE | BOWL | ZIPPER | PLUNGER | SWITCH | SWATTER | RUBBER | PARA | ANVIL | Sum |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 0 | `single` | 130 | 80 | 260 | 75 | 230 | 60 | 165 | 0 | 0 | 0 | 1000 |
| 0 | `multi` | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| 1 | `single` | 150 | 135 | 240 | 125 | 145 | 45 | 135 | 0 | 0 | 0 | 975 |
| 1 | `multi` | 0 | 0 | 25 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 25 |
| 2 | `single` | 150 | 135 | 225 | 144 | 135 | 36 | 135 | 15 | 0 | 0 | 975 |
| 2 | `multi` | 0 | 0 | 25 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 25 |
| 3 | `single` | 160 | 120 | 140 | 205 | 110 | 30 | 100 | 70 | 30 | 0 | 965 |
| 3 | `multi` | 0 | 0 | 35 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 35 |
| 4 | `single` | 145 | 105 | 45 | 240 | 0 | 24 | 0 | 40 | 80 | 0 | 679 |
| 4 | `multi` | 40 | 0 | 80 | 175 | 26 | 0 | 0 | 0 | 0 | 0 | 321 |

#### `num-karts="9"` (`L183-L195`)
| Section | Mode | BUBBLE | CAKE | BOWL | ZIPPER | PLUNGER | SWITCH | SWATTER | RUBBER | PARA | ANVIL | Sum |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 0 | `single` | 120 | 60 | 290 | 50 | 270 | 40 | 170 | 0 | 0 | 0 | 1000 |
| 0 | `multi` | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| 1 | `single` | 145 | 150 | 230 | 120 | 160 | 30 | 135 | 0 | 0 | 0 | 970 |
| 1 | `multi` | 0 | 0 | 30 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 30 |
| 2 | `single` | 150 | 130 | 205 | 152 | 130 | 24 | 130 | 44 | 0 | 0 | 965 |
| 2 | `multi` | 0 | 0 | 35 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 35 |
| 3 | `single` | 165 | 115 | 130 | 245 | 70 | 18 | 84 | 50 | 30 | 0 | 907 |
| 3 | `multi` | 0 | 0 | 60 | 0 | 33 | 0 | 0 | 0 | 0 | 0 | 93 |
| 4 | `single` | 100 | 80 | 35 | 200 | 0 | 12 | 0 | 16 | 67 | 0 | 510 |
| 4 | `multi` | 90 | 0 | 90 | 290 | 20 | 0 | 0 | 0 | 0 | 0 | 490 |

#### `num-karts="14"` (`L196-L208`)
| Section | Mode | BUBBLE | CAKE | BOWL | ZIPPER | PLUNGER | SWITCH | SWATTER | RUBBER | PARA | ANVIL | Sum |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 0 | `single` | 110 | 40 | 320 | 25 | 300 | 30 | 175 | 0 | 0 | 0 | 1000 |
| 0 | `multi` | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| 1 | `single` | 140 | 155 | 240 | 110 | 170 | 20 | 135 | 0 | 0 | 0 | 970 |
| 1 | `multi` | 0 | 0 | 30 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 30 |
| 2 | `single` | 150 | 125 | 210 | 159 | 145 | 15 | 120 | 36 | 0 | 0 | 960 |
| 2 | `multi` | 0 | 0 | 40 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 40 |
| 3 | `single` | 135 | 105 | 115 | 234 | 60 | 12 | 70 | 35 | 24 | 0 | 790 |
| 3 | `multi` | 40 | 0 | 80 | 40 | 50 | 0 | 0 | 0 | 0 | 0 | 210 |
| 4 | `single` | 90 | 70 | 15 | 175 | 0 | 0 | 0 | 0 | 50 | 0 | 400 |
| 4 | `multi` | 120 | 0 | 125 | 325 | 30 | 0 | 0 | 0 | 0 | 0 | 600 |

#### `num-karts="20"` (`L209-L221`)
| Section | Mode | BUBBLE | CAKE | BOWL | ZIPPER | PLUNGER | SWITCH | SWATTER | RUBBER | PARA | ANVIL | Sum |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 0 | `single` | 100 | 0 | 370 | 0 | 330 | 20 | 180 | 0 | 0 | 0 | 1000 |
| 0 | `multi` | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| 1 | `single` | 135 | 160 | 240 | 100 | 185 | 15 | 135 | 0 | 0 | 0 | 970 |
| 1 | `multi` | 0 | 0 | 30 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 30 |
| 2 | `single` | 150 | 120 | 200 | 165 | 148 | 10 | 105 | 27 | 0 | 0 | 925 |
| 2 | `multi` | 0 | 0 | 50 | 0 | 25 | 0 | 0 | 0 | 0 | 0 | 75 |
| 3 | `single` | 125 | 90 | 100 | 262 | 50 | 8 | 50 | 20 | 15 | 0 | 720 |
| 3 | `multi` | 50 | 0 | 100 | 50 | 80 | 0 | 0 | 0 | 0 | 0 | 280 |
| 4 | `single` | 75 | 60 | 0 | 125 | 0 | 0 | 0 | 0 | 35 | 0 | 295 |
| 4 | `multi` | 150 | 0 | 155 | 400 | 0 | 0 | 0 | 0 | 0 | 0 | 705 |

### 4.2 Other Mode Weight Lists (`data/powerup.xml:L224-L265`)

- **`ftl-weight-list` (`num-karts="1"`, `L224-L241`):**
  - Section 0 (leader): `single=[35, 0, 25, 35, 25, 15, 25, 0, 0, 0]`, `multi=[20, 0, 0, 20, 0, 0, 0, 0, 0, 0]` (sum `200`)
  - Section 1: `single=[25, 0, 60, 25, 58, 2, 30, 0, 0, 0]`, `multi=[0 x 10]` (sum `200`)
  - Section 2: `single=[35, 0, 55, 35, 25, 3, 25, 0, 0, 0]`, `multi=[0, 0, 10, 0, 12, 0, 0, 0, 0, 0]` (sum `200`)
  - Section 3: `single=[25, 0, 40, 45, 15, 5, 15, 10, 5, 0]`, `multi=[10, 0, 15, 15, 0, 0, 0, 0, 0, 0]` (sum `200`)
  - Section 4 (last): `single=[20, 0, 15, 25, 0, 0, 0, 0, 15, 0]`, `multi=[20, 0, 25, 80, 0, 0, 0, 0, 0, 0]` (sum `200`)
- **`battle-weight-list` (`num-karts="1"`, `L243-L249`):**
  - Section 0: `single=[10, 30, 60, 0, 0, 10, 30, 0, 0, 0]`, `multi=[0, 0, 5, 0, 0, 0, 0, 0, 0, 0]` (sum `145`)
- **`soccer-weight-list` (`num-karts="1"`, `L251-L257`):**
  - Section 0: `single=[0, 30, 60, 0, 0, 10, 30, 0, 0, 0]`, `multi=[0, 0, 5, 0, 0, 0, 0, 0, 0, 0]` (sum `135`)
- **`tutorial-weight-list` (`num-karts="1"`, `L259-L265`):**
  - Section 0: `single=[0 x 10]`, `multi=[0, 0, 100, 0, 0, 0, 0, 0, 0, 0]` (sum `100`)

---

## 5. Solo Kart at Difficulty `3` (`DIFFICULTY_BEST`) — Exact Selection

1. **Difficulty does NOT alter item weights:** `RaceManager::DIFFICULTY_BEST = 3` (`"best"`, `src/race/race_manager.hpp:L231-L238, L611`) scales physics/AI kart characteristics in `data/kart_characteristics.xml`, NOT `PowerupManager` weight tables (`computeWeightsForRace` uses only minor mode and `num_karts`).
2. **Mode & Table:** In a standard race (`MINOR_MODE_NORMAL_RACE`), `computeWeightsForRace` selects `race-weight-list` (`src/items/powerup_manager.cpp:L532`). For `numKarts = 1`, `prev_index == next_index` selects `<weights num-karts="1">` without kart-count interpolation (`L574-L584`).
3. **Rank -> Section:** For `rank = 1`, `WeightsData::convertRankToSection(1, ...)` unconditionally picks `prev = next = 0, weight = 1.0f` (`src/items/powerup_manager.cpp:L317-L320`).
4. **Effective Column (`num-karts="1"`, Section `0`, `data/powerup.xml:L159-L160`):**
   - `BUBBLEGUM (single)`: `140` (`14.0%`)
   - `BOWLING (single)`: `300` (`30.0%`)
   - `ZIPPER (single)`: `100` (`10.0%`)
   - `PLUNGER (single)`: `225` (`22.5%`)
   - `SWITCH (single)`: `75` (`7.5%`)
   - `SWATTER (single)`: `160` (`16.0%`)
   - `CAKE`, `RUBBERBALL`, `PARACHUTE`, `ANVIL`, and all `multi`: `0` (`0.0%`)
   - **Total weight = `1000`** (note `CAKE` and `RUBBERBALL` already have `0` weight in solo `num-karts="1"` Section `0`, so the 15 s no-explosive timeout has no effect in solo Section `0`).
