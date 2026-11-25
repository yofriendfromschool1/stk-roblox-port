# OpenKart Performance Baseline & Measurements

Baseline telemetry, load-latency fixes, and 20-kart server scaling measurements recorded cleanly in Studio (`STK 1.5` port at `120 Hz` fixed-step, `METERS_PER_STUD = 1.0`).

---

## 1. Fixes Applied from Initial Bottleneck Audit

| Bottleneck | Root Cause Measured | Resolution Applied |
|---|---|---|
| **Missing Items (`ItemModels=0`) & `B` Look-Back Stall** | `src/client/items/ItemPresentation.lua` called yielding `WaitForChild("Items", 5)` inside `RunService:BindToRenderStep` when `ReplicatedStorage.Assets.Items` was unmounted in an older `rojo serve` session (`5 s × 10 items = 50 s` render freeze blocking `B` look-back and camera updates). | Removed ALL `WaitForChild`/`task.wait` yields from `ItemPresentation.lua`. Uses strictly non-yielding `FindFirstChild` + immediate `ItemBoundsData`-sized submesh fallback Parts when templates are absent/unhydrated, upgrading cleanly once templates hydrate. |
| **461 Redundant `Workspace.Tracks` BaseParts (`893 KB`)** | `default.project.json` mounted `Workspace.Tracks -> assets/roblox/tracks` (`sandtrack.model.json`, `461` BaseParts including `303` driveline quads) only for `GreyboxKartServer.lua` to hide them on boot. Minimap & lap math already consume pure `GreyboxArenaData.drivelineQuadCenters`. | Removed `Workspace.Tracks` mount from `default.project.json` (`461 → 0` unused parts) and removed the dead hiding loop from `GreyboxKartServer.lua`. |
| **Serial Server Boot Mesh Hydration** | `KartAssetHydrator` serially called `InsertService:CreateMeshPartAsync` `8` times at server boot because `.model.json` cannot serialize `InitialSize` (`MeshSize`). | Added baked `.rbxmx` (`InitialSize` + `MeshId` + `TextureID` + `AttributesSerialize`) in `tools/stk2rbx/kart_emit.py` so baked builds require **0** network fetches on boot (`< 1 ms` assertion check), plus parallel `task.spawn` fallback in `KartAssetHydrator.lua` when `MeshSize == 0`. |
| **Unthrottled `GameHud` / `CanvasGroup` Writes** | `timerLabel.Text`, `CanvasGroup` `UIGradient.Rotation`s, rank labels, minimap dots, and powerup slots updated every render frame even when unchanged. | Throttled race timer text writes to `10 Hz` and cached all `CanvasGroup`, rank, minimap dot, and powerup HUD properties so only changed values mutate instances. |

---

## 2. Spatial Query & 20-Kart Server Tick Budget (Measured)

Benchmark harness executed directly on live Roblox Server (`GreyboxArena.Surfaces` `WorldQuery`, Tux medium/best profile, active drifting + nitro + item ticks at `120 Hz`):

| Workload | Spatial Queries / sec | Measured Total / 120 Ticks | Per-Tick Cost | 60 Hz Frame Budget Equivalent (`16.67 ms`) |
|---|---|---|---|---|
| **1 Kart × 120 ticks** (`1.0 s` sim) | `960 / s` (`480` raycasts + `120` blockcasts + `360` overlaps) | `7.44 ms` | `62.0 µs / tick` | `0.12 ms / frame` (`0.7%`) |
| **20 Karts × 120 ticks** (`1.0 s` sim) | `19,200 / s` (`9,600` raycasts + `2,400` blockcasts + `7,200` overlaps) | `126.10 ms` | `1.05 ms / tick` | `2.10 ms / frame` (`12.6%`) |

### Breakdown (`1 kart × 120 ticks` with query timing wrapper)
- Spatial query API calls (`raycast`, `Blockcast`, `GetPartBoundsInBox`): `1.41 ms` / `5.76 ms` (**`24.5%`**)
- Pure-Luau solver + `ItemWorld` math: **`75.5%`**

> [!NOTE]
> These measurements were captured on the flat/ramp box geometry of `GreyboxArena` in Studio (`Sandbox`/`Local` Server). Published-place latency and full converted triangle-mesh track geometry (`sandtrack`) must be re-measured before finalizing 20-player server tick-rate/solver optimizations.

---

## 3. MicroProfiler Scopes Instrumented
- `OpenKart_ServerSim` (`GreyboxKartServer.lua` fixed-step accumulator)
- `OpenKart_ClientSim` (`GreyboxKartClient.client.lua` client prediction accumulator)
- `OpenKart_ItemSync` (`ItemPresentation.lua` frame visual sync)
- `OpenKart_KartPres` (`GreyboxKartClient.client.lua` kart transform + VFX update)
- `OpenKart_Camera` (`GreyboxKartClient.client.lua` camera transform)
- `OpenKart_GameHud` (`GameHud.client.lua` cached HUD pass)
