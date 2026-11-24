# OpenKart Divergences Log

Every behavioral or architectural divergence from pinned upstream **SuperTuxKart `1.5`** (`supertuxkart/stk-code`, commit `1fb491f507216c5d181ccd85f29ff08eca003827`) is recorded here with its cause (`engine limit`, `platform policy`, or `ToS`).

---

## Accepted Architectural Divergences (`AGENTS.md`)

| Area | Upstream STK `1.5` | OpenKart Behavior | Cause |
|---|---|---|---|
| **Vehicle Physics Solver** | Bullet Physics (`lib/bullet` + `src/physics/btKart.cpp`) raycast vehicle with bilateral zero-slip tire constraint (`<friction slip="10000000"/>`). | Pure-Luau 120 Hz fixed-step rigid-body + 4-wheel raycast solver ([physics-spec.md](physics-spec.md)) with parameterized Pacejka slip-angle → grip curve tuned to match upstream `R(v)` radii, steep-slope sliding, knockback slip release, suspension, and downforce. | **Engine limit** — C++/Bullet native runtime cannot execute on Roblox; deterministic Luau solver also required for prediction/reconciliation. |
| **Networking & Synchronization** | ENet peer-to-peer / LAN host with global `RewindManager` state rollbacks (`src/network/`). | Server-authoritative Roblox match loop (`8–20` players) over `RemoteEvent` / `UnreliableRemoteEvent` with client-side input prediction/reconciliation and remote interpolation. | **Engine limit / platform policy** — Roblox controls transport, sockets, and server-client trust boundaries. |
| **Track & Kart Addons** | Runtime dynamic download & mounting of `.zip` addon packs (`src/addons/`). | Offline-converted curated packs built into the place via `tools/stk2rbx` and audited per-file in [CREDITS.md](../assets/CREDITS.md). | **Platform policy** — Roblox prohibits arbitrary dynamic code/asset loading at runtime. |

---

## Asset / Console & Minor Engine Divergences

| Item | Observation | Cause & Resolution |
|---|---|---|
| **`ContentId: rbxassetid://203785492 failed due to: Asset type does not match requested type`** | Logged 3 times during Studio Solo Play playtests (`run 1` and after deleting template `Workspace.Baseplate` and `Workspace.SpawnLocation`). Audited Edit DataModel (`NOT_FOUND_IN_EDIT_DM`); `203785492` does not exist anywhere in `openkart-dev.rbxl`, `src/`, or `assets/`. | **Engine limit / Studio playtest environment** — Originates from Roblox Studio's built-in Solo Play character/CoreScripts pipeline rather than OpenKart or the removed template `Baseplate`/`SpawnLocation`. Safe to ignore as non-OpenKart Studio console noise; revisit if observed in a published blank place test. |
