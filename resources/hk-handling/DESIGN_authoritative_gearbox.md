# hk-handling — Authoritative Gearbox Rewrite (Design for sign-off)

Status: DESIGN — not yet implemented. Supersedes the mfvFloor / SettleVerify / folded-ratio-cap
patch war. Written 2026-08-14.

## The one-line root cause (proven live via /gbgeartest on the 911ts)

`ModifyVehicleTopSpeed` — which we are REQUIRED to call for `fInitialDriveMaxFlatVel` /
`fInitialDriveForce` writes to take effect — itself forces a GTA transmission re-setup that
**re-folds the gear-ratio table**. Every time the script adjusted top speed, it silently re-folded
the gears. The lambra chip, fingerprint flicker, mfv runaway, and torque-death were all downstream
symptoms of fighting that recompute instead of overwriting its output.

### /gbgeartest evidence (911ts, live count = 9, meta nInitialDriveGears = 8)
- BEFORE: `g1=3.3333 … g9=0.8000` folds=0 (GTA's own clean band, already accounts for the +1 trans mod)
- T1 write clean band via `SetVehicleGearRatio` → read back EXACT, folds=0 → **direct write works**
- T2 idle 3s → band unchanged → **holds without per-frame re-assert (on its own)**
- T3 `ModifyVehicleTopSpeed(veh,0.0)` → `g7=0.6864 g8=0.7494 g9=0.9000` folds=2 → **re-setup clobbers/folds**

## Validated facts (from 4 research streams + live DB + live probe)

- `SET_VEHICLE_GEAR_RATIO` (0x496EF2F2) — live-writable per-gear ratio setter. WORKS + HOLDS.
- `SET_VEHICLE_HANDLING_FLOAT` writes `fInitialDriveMaxFlatVel`/`fInitialDriveForce` into CHandlingData
  but they only APPLY after a transmission re-setup → must call `ModifyVehicleTopSpeed`.
- `nInitialDriveGears` is spawn-baked — writing it live is ignored. `GetVehicleHighGear` is the live count.
- Per-frame `SetVehicleHandlingFloat` / `SetVehicleGearRatio` are cost-safe (NOT the ApplyForceToEntity
  solver-flood class — those are force natives that accumulate; these just mutate a struct).
- Owner-local physics + thin statebag for display is the community-standard replication shape
  (matches existing hk_gearsync_rpm / hk_drivestate bridge).
- Gear count > 8–9 overflows GTA's ratio array — we must NEVER inflate count. (911ts at 9 = fine.)
- Owned vehicle DB truth: `player_vehicles` row = complete mod snapshot. `lambrachip` column is the
  ONLY source for the lambra chip (escrowed, no statebag). `mods` = json.encode(GetVehicleProperties),
  but can be `'{}'` on freshly-bought-never-stored cars → must fall back to live reads.

## Core principle: we AUTHOR the ratio table; GTA's fold never reaches the physics

Gear COUNT floats naturally = meta base + mod deltas (the trans-mod +1 STAYS, never debounced/forced).
We only ever author the ratio VALUES across `1..GetVehicleHighGear(veh)`, whatever N is.

## Design

### A. Clean-band capture (per model, self-healing cache key)
- On entry, once the live table reads folds=0 at the current count, capture it as the clean band.
- Cache key = `model + modFingerprint + stockSig` (stockSig = rounded hash of raw stock handling read),
  so a handling.meta edit auto-busts the cache — no manual reset to forget.
- Session-scoped derivation (rebuilt on entry); GTA only reloads metas on restart anyway.
- Optional: seed meta anchors (mfv/driveForce/gears) from hkcarpack handling.meta at startup into
  hk_handling table so anchors are DB-known from first boot (Phase 3 optimization, not required).

### B. Authoritative write order (the fix)
Every apply cycle (on entry, on re-setup event, + cheap per-frame safety re-write):
1. `SetVehicleHandlingFloat` fInitialDriveMaxFlatVel + fInitialDriveForce (our mfv/driveForce targets)
2. `ModifyVehicleTopSpeed(veh, …)` — forces re-setup so (1) applies (AND re-folds — expected)
3. `SetVehicleGearRatio(veh, g, cleanBand[g])` for g=1..N — OVERWRITES the fold before physics reads it
NEVER reverse this order. Re-assert after every re-setup trigger (mod install, modkit re-init).
Retire: mfvFloor clamp, SettleVerify, DropFoldedGears, reduced-ratio toggle-as-fix.

### C. Limiter + projection read OUR targets, never GTA live
capKmh / gear projection derive from cleanBand + our mfv target (already partially done this session).

### D. Ownership-first mod detection → one modStack multiplier
- OWNED (row exists by trimmed plate OR fakeplate):
  - chip = `player_vehicles.lambrachip` (authoritative; reuse existing chipQuery/HK.brakeChipHas)
  - native mods + jim status: prefer LIVE reads (fresher than DB snapshot); DB `mods` only if non-empty
- UNOWNED (no row): live native slots only; chip CANNOT exist here (item-installed, DB-persisted)
- Signals already reachable: GetVehicleMod(11/13/12)+IsToggleModOn(18); LocalPlayer.state.hk_antilag;
  LocalPlayer.state.hk_nosBoostLevel; Entity(veh).state.vehicleStatus (jim oillevel/shaftlevel/etc)
- modStack → mfvTarget = mfvBase*(1+Σtop%), driveForceTarget = driveForceBase*(1+Σpwr%), clamped ≥ base
  (structurally never slower than stock even if a mod is missed).

## Phasing
- Phase 1: clean-band capture + authoritative write order (B) + limiter reads-our-targets (C).
  THIS is the torque-death fix; independent of any mod detection.
- Phase 2: ownership-first modStack (D) feeding mfv/driveForce targets.
- Phase 3 (optional): DB-seed meta anchors at startup for fewer live captures.

## Non-negotiables (standing constraints)
- Follow the live gear count (meta+mods); never statically cut it; never inflate past 9.
- Modding must never make a car slower than stock.
- Edit top-level `config.lua` (NOT client/config.lua — stale, not in manifest).
- Cannot restart remotely; user runs `restart hk-handling`. Verify all Lua with `luac5.4 -p`.
