# SuperTuxKart → Roblox port

## Upstream
- This IS a port of SuperTuxKart, not a reimplementation or rebrand.
- Pinned upstream version/commit lives in docs/upstream.md. Never silently retarget.
- Port faithfully. Every behavioral divergence needs an entry in
  docs/divergences.md with cause (engine limit / platform policy / ToS).
- Cite origin in every ported module:
    -- ported from src/karts/kart.cpp:L210-L268 (STK <tag>)
- Keep docs/port-map.md current: upstream file → Luau module → status.
- May reference https://supertuxkart.net and upstream docs for behavioral intent. Pinned STK 1.5 source is authoritative for all constants. Log any conflict in divergences.md.

## License
- GPLv3-or-later. SPDX header on every source file. Never relicense.
- Screen every Wally dependency's license; reject GPL-incompatible.
- Corresponding source must always build: repo + Rojo produces a place file
  matching what's published. Flag drift.
- assets/ carries its own CC licenses + CREDITS.md. Audit per-file; STK media
  is NOT uniformly CC-BY-SA. Skip anything unverified. No Nintendo IP.

## Identity
- Unofficial port. Attribution + upstream link in-game and in repo.
- Roblox title "SuperTuxKart": PENDING upstream permission (docs/upstream.md).
  GPLv3 grants copyright, not trademark. Use a fallback title until resolved.

## Accepted divergences — do not re-litigate
- Physics: Bullet's raycast vehicle cannot be ported. Reimplement a solver
  reproducing STK kart-controller behavior; constants sourced from upstream.
- Netcode: STK LAN → Roblox server-authoritative, 8–20 players.
- Addons: no dynamic loading on Roblox; curated packs instead.
- Everything else ports faithfully: items, modes, kart stats, drivelines,
  checkpoints, skid tiers, slipstream, powerups.

## Source of truth
- Filesystem → Rojo → Studio. NEVER write Luau via MCP.
- MCP is for: instance inspection, playtests, console output, screenshots,
  and executing committed converter scripts.
- Tracks/karts come from upstream data via tools/stk2rbx. NEVER hand-build or
  AI-generate track layouts. Changing a track = changing the converter or its
  input, not placing parts in Studio.

## Architecture
- Server owns item rolls, checkpoint order, lap validation, results. Client
  predicts and reconciles. Never trust client-reported laps or pickups.
- Fixed timestep, decoupled from render framerate.
- Tuning constants in src/shared/KartTuning.lua with upstream citations.
  No magic numbers in the solver.

## Verify before claiming done
    if (!(Test-Path types/globalTypes.d.luau)) { throw "Missing types/globalTypes.d.luau" }
    stylua --check src/ tests/
    selene src/ tests/
    luau-lsp analyze --definitions=@roblox=types/globalTypes.d.luau --sourcemap sourcemap.json src/
    lune run tests/run.luau
Run these yourself. Fix failures before reporting success. Missing Roblox global
definitions (`types/globalTypes.d.luau`) or `[ERROR] Failed to read definitions file`
is a hard failure — never ignore missing-definitions warnings. Feel and visuals
require a human playtest — say so; never assert "feels good".

## Workflow
- Use subagents for independent parallel work.
- Small modules, one responsibility, typed Luau (--!strict where practical).
- All planning, audit, and walkthrough artifacts go in docs/, never the brain directory.
- Update docs/decisions.md when a design decision changes.
- Commit messages: imperative, one line, subsystem prefix (physics:, net:, track:).

## Current phase
Month 1: upstream pin + stk2rbx spike on ONE track + kart physics skeleton.
GO/NO-GO at end of month 2 is "does drift feel good". No content ahead of that gate.

## Secrets
- ROBLOX_OPEN_CLOUD_KEY is an env var. Never print, echo, log, or write its
  value to any file. Never commit it. Reference it only as os.environ[...].
- If a command would echo the key, redact it. Report "key present" not the value.

VERIFY: run stylua, selene, luau-lsp with @roblox defs, and lune tests. PASTE THE
ACTUAL OUTPUT. Do not report success without a green run. Do not search the web
for functions in this repo — they are local.

LICENSING RESOLUTION (do not re-block covered files)
- A license grant is valid at any scope upstream wrote it: per-file, directory,
  package, or wildcard. "No filename stanza" != unlicensed.
- For each of the 10 flagged textures, check in order: textures/licenses.txt
  wildcard/default -> root stk-assets/licenses.txt -> package stanza whose path
  scope includes the file. Stop at first hit.
- The 7 stklib_* textures are package-covered by root licenses.txt. Import them.
  Cite stanza + line range, attribute Jean-Manuel Clémençon CC-BY-SA 4.0, and
  record coverage scope as "package-level" in CREDITS.md.
- transparence2.png: verify alpha extrema. If fully transparent, implement as a
  native transparent Part preserving collision-reaction="reset"; log as an
  implementation choice. If partially transparent, log a visual divergence.
- stktex_generic_WoodA.png / gfx_sandAnimated_a.png: report which submeshes
  reference them BEFORE deciding. If no grant is found anywhere, do NOT import.
  Substitute (CC0 or self-authored) with a divergences.md entry naming the
  original file and reason, or omit with a logged gap if non-drivable.
- Add a "coverage scope" column to CREDITS.md so per-file vs package-level
  grants are distinguishable.