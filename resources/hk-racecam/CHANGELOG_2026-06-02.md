# hk-racecam Changes — 2026-06-02

## Phase 1: Quick fixes

### ✓ Debug menu keyboard passthrough
- Changed `SetNuiFocus(true, true)` so keyboard input stays active in-game while the menu is open (mouse-only NUI interaction).

### ✓ Transition zoom eliminated
- **Root cause:** Seed position at engage used raw `baselineDist`, but first frame of `updateFree` applied view-mode scale → mismatch drove zoom during RenderScriptCams blend.
- **Fix:** Apply view-mode scale at seed-time so the starting distance matches the target distance.
- Shortened blend times: `EaseInMs` 600→250, `EaseOutMs` 350→180 (snappier transitions).

### ✓ Motion blur boosted
- `CamBlur.StrengthAtTopSpeed` 0.60→1.20, kicks in at 160 km/h (was 180).
- `Timecycle.Enabled` now **true** (layered `rply_motionblur` modifier for extra directional smear at speed).
- `Timecycle.StrengthAtTopSpeed` 0.40→0.55.

### ✓ FOV gap (gear/RPM) tweaks
- `fov.min` 55→**63**, `fov.max` 63→**68** (narrower spread, higher baseline).
- Gear-shift FOV dip reduced to **1/3** original: `HeightDip/FovDip/DistanceDip` 0.20→**0.07** (the up/down bob was too much).

### ✓ Idle look-ahead + distance gap
- `lookAheadBase` 1.20→**0.60** (aims closer to car at idle, less "facing forward").
- `lookAheadSpeed` 3.5→**1.8** (less forward-lead at speed).
- `lookHeight` 1.0→**1.35** (raised aim point so closer look-ahead doesn't tilt down via PointCamAtCoord).

---

## Phase 2: Per-V-mode dedicated configs

### Architecture
Each V-key position now has dedicated overrides that merge on top of the base preset:
- **Mode 0** (Near, V pos 2)
- **Mode 1** (Medium, V pos 3)
- **Mode 2** (Far, V pos 4)
- **Mode 4** (First-person) → disengages

### Config structure: `Config.ViewModeOverrides`
- `_base` block: shared tweaks applied to ALL modes (baseHeight, heightLift, smoothness, fovSmoothness, fov min/max, lookAhead values).
- Per-mode blocks `[0]`, `[1]`, `[2]`: override specific fields (distanceTrim, maxBaseDistance, baseHeight, heightLift, etc.).

### User-specified values (after testing):
**ALL MODES (_base):**
- Base height 1.44, height lift 0.94
- Move lag 0.09, zoom lag 0.12 (fovSmoothness; equivalent to ~2 frame lag)
- FOV min 63, max 68
- lookAheadBase 0.60, lookAheadSpeed 1.8, lookHeight 1.35

**NEAR (mode 0):**
- Distance trim −0.6, accel zoom-out 0, max distance cap 1.3

**MEDIUM (mode 1):**
- Distance trim −1.15, max distance cap 5.8, base height 1.34, height lift 1.06

**FAR (mode 2):**
- Distance trim −4.5, base distance fallback 0, max distance cap 3.75, base height 1.18, height lift 1.02

### Implementation
- `applyViewModeOverrides(preset, viewMode)` merges `_base` + mode-specific overrides onto the resolved preset.
- Called per-frame in `updateFree` after `getResolvedPreset(veh)`, so V-key changes apply instantly.
- View-mode FOV offsets preserved: near −3.0°, medium −1.5°, far 0.0° (on top of the per-gear RPM-driven FOV).

---

## Remaining: Debug menu rework

The debug menu currently edits a single flat chase preset. With per-V-mode configs, the menu needs to:
1. Detect the current V-mode (`STATE.currentViewMode`).
2. Show the resolved values for that mode (after `_base` + mode-specific merge).
3. Apply slider changes to the active mode's override block.
4. Save writes back to `Config.ViewModeOverrides[mode]`.

Workflow: Player presses V in-game to switch modes → menu auto-follows → edit that mode live → Save.

**Status:** ✓ COMPLETE.

### Changes made:
**client.lua:**
- `openMenu` / `hk-racecam:openDebugMenu` now send `currentViewMode` + `resolvedChase` (the merged preset after view-mode overrides) to NUI.
- `applyChanges` callback writes to `Config.ViewModeOverrides[mode]` structure instead of directly to `Config.Presets.chase`:
  - Shared fields (smoothness, fovSmoothness, fov min/max, lookAheadBase) → `Config.ViewModeOverrides._base` (affects all modes).
  - Per-mode fields (distanceTrim, baseDistance, maxBaseDistance, maxExtraDistance, baseHeight, minHeight, heightLift) → `Config.ViewModeOverrides[mode]` (current mode only).

**script.js:**
- Added `currentViewMode` tracking and `VIEW_MODE_NAMES` map (0=NEAR, 1=MEDIUM, 2=FAR).
- `collectCurrentValues()` now includes `currentViewMode` in the payload sent back to Lua.
- New `loadResolvedChase(rc)` function loads chase sliders from the resolved preset (the merged values for the current V-mode).
- New `updateViewModeBadge()` function updates the view-mode indicator in the header.
- Message listener updated to handle `currentViewMode` and `resolvedChase` from Lua.

**index.html:**
- Added `.viewmode-bar` between header and tabs with:
  - "Editing V-mode:" label
  - `#viewmode-badge` showing the current mode name (e.g., "MEDIUM (V3)")
  - Hint text: "press V in-game to switch · reopen menu to refresh"

**style.css:**
- Styled `.viewmode-bar`, `.viewmode-badge`, `.viewmode-label`, `.viewmode-hint`.

### How it works:
1. Open the debug menu (`racecam_debug` command).
2. The badge shows which V-mode you're currently in (e.g., "NEAR (V2)").
3. Chase sliders show the **resolved values** for that mode (base preset + _base overrides + mode-specific overrides merged).
4. Press V in-game to switch view modes.
5. **Close and reopen** the menu to load the new mode's values (live switching without reopening is not implemented; you tune one mode at a time).
6. Click **Apply (Me Only)** to write changes to `Config.ViewModeOverrides[mode]` (live update, this client only).
7. Click **Save to Config** to persist the changes to `config.lua` on disk (requires server-side handler update — see below).

### Server-side TODO:
The `saveToConfig` server event (`hk-racecam:saveConfig`) currently writes `Config.Presets` to disk. It needs updating to also write `Config.ViewModeOverrides`. Without this, Save will write the old structure and break the per-V-mode system on next reload.

**Action required:** Update `server.lua` `hk-racecam:saveConfig` handler to serialize and write `Config.ViewModeOverrides` to `config.lua`. This is a **blocking issue** for the Save button — do not use Save until the server handler is updated.

---

## Server.lua Update — ✓ COMPLETE

**Updated `hk-racecam:saveConfig` handler:**
- Now rebuilds the entire `Config.ViewModeOverrides` block instead of editing the chase preset.
- Reads the server's live `Config.ViewModeOverrides` (shared_script) for modes NOT being edited, so saving mode 1 preserves prior edits to mode 0 and mode 2.
- Serializes `_base` (shared fields from incoming data) + per-mode blocks (edited mode uses incoming data, others use current server config, fallback to defaults).
- Uses `content:gsub('Config%.ViewModeOverrides = %b{}', fullOverridesBlock, 1)` to replace the entire block in one pass.
- Hood preset save unchanged.

**Safe to use "Save to Config" now** — the handler preserves all three modes correctly.

---

## C-Key Look Behind — ✓ COMPLETE

**New feature: hold C to look behind**
- While holding **C** (or controller R3), the camera instantly flips to reverse view (front of car looking back at driver), even when driving forward.
- Release C to return to chase view.
- Uses the same reverse-cam framing as physical reversing (locked distance/height/FOV from `Config.Reverse`).
- Reads controls 79 (`INPUT_VEH_LOOK_BEHIND`) and 26 (`INPUT_LOOK_BEHIND`) via `IsDisabledControlPressed` so it works even while look controls (1/2) are disabled by the cam.
- Toggle via `Config.Reverse.CKeyEnabled = true` (enabled by default).

**How it works:**
- `STATE.lookBehind` flag set per-frame from C-key state
- Reverse detection now: `physicallyReversing OR cKeyHeld`
- Instant response — no idle threshold, works while cam is engaged or not
- Does NOT trigger the look-detection disengage (C is not a look axis)

---

## FOV Tuning Pass 2 — ✓ COMPLETE

**Request:** Accel/decel FOV change too rapid → slow it down, narrow the FOV gaps.

### Applied Settings (per your specs)

**Shared (_base):**
- `fovSmoothness = 0.35` (was 0.12) — **3× slower visual FOV transitions**
- `smoothness = 0.09` (move lag unchanged)

**Mode 0 (NEAR, V pos 2):**
- Distance trim: -4.5
- Accel zoom-out: 0.25
- Max distance cap: 1.30
- Base height: 0.90, min height floor: 0.38, height lift: 0.80
- FOV: **62-68** (6° range)

**Mode 1 (MEDIUM, V pos 3):**
- Distance trim: -1.6
- Accel zoom-out: 0.25
- Max distance cap: 4.0
- Base height: 1.26, height lift: 0.92
- FOV: **50-50** (locked — no FOV change in this mode)
- Idle look-ahead: 1.2

**Mode 2 (FAR, V pos 4):**
- Distance trim: -0.8
- Accel zoom-out: 0.3
- Max distance cap: 5.8
- Base height: 1.34, height lift: 1.06
- FOV: **55-65** (10° range)

### What Changed
1. **FOV smoothness tripled** (0.12 → 0.35): visual FOV now lerps at ~35%/frame instead of ~12%/frame = **~3 frames of lag** vs <2 before. This is the main "slow down" fix.
2. **FOV ranges narrowed per mode**: near 6°, middle 0° (flat), far 10° — reduces the visual sweep during accel/decel.
3. **Per-mode FOV overrides**: each mode now has its own `fov = {min, max}` in `Config.ViewModeOverrides`, so middle can be locked flat while near/far have small dynamic ranges.

---

## Speed-Distance Ramping (minExtraDistance) — ✓ COMPLETE

**Problem:** At low speeds (0-100 km/h), the camera felt too close/forward because `maxExtraDistance` only applies at high speed. At idle, the camera starts at the base distance with no extra pull-back, creating a claustrophobic near-mode view until you hit ~100+ km/h.

**Solution:** Added `minExtraDistance` (idle starting point) + `maxExtraDistance` (high-speed pullback) **with speed ramping**. The distance now ramps smoothly:
```
distance = baseDist + lerp(minExtraDistance, maxExtraDistance, speedFactor)
where speedFactor = clamp(kmh / rampMaxSpeedKmh, 0, 1)
```

### New Config Fields
- **`minExtraDistance`**: Distance offset at 0 km/h (idle starting point). Camera starts further back even when stationary.
- **`maxExtraDistance`**: Distance offset at `rampMaxSpeedKmh+` (high-speed pullback). Replaces the old meaning (now it's the *top* of the ramp, not the only value).
- **`rampMaxSpeedKmh`**: Speed (km/h) at which the min→max blend completes. Default 120 km/h. Lives in `Config.ViewModeOverrides._base`, overrideable per-mode.

### Debug Menu Updates
Added 3 new sliders to the chase tab:
1. **"Start Dist (idle)"** — `minExtraDistance` (0-15 range, hard max 40)
2. **"Accel Zoom-Out (top)"** — `maxExtraDistance` (renamed label; 0-15 range, hard max 40)
3. **"Dist Ramp Speed (kmh)"** — `rampMaxSpeedKmh` (20-200 range, hard max 400)

### Current Per-Mode Settings (after your tuning)
- **NEAR (mode 0):** `minExtraDistance = 8.0`, `maxExtraDistance = 30.0` → starts 8 units back at idle, pulls to +30 at 120 km/h
- **MEDIUM (mode 1):** `minExtraDistance = 0.0`, `maxExtraDistance = 0.25` → minimal ramp
- **FAR (mode 2):** `minExtraDistance = 0.0`, `maxExtraDistance = 0.0` → no distance ramping

### Implementation Details
- **Seed position updated** (line 406 client.lua): `seedDist = baseDist + minExtraDistance` so the cam starts at the idle distance, not the naked base. Eliminates the engage zoom-in jump.
- **Config toggle:** `Config.SpeedDistanceRamp.Enabled = true` (default on). When off, falls back to legacy `maxExtraDistance * sf` (sf = speed factor capped to 220 km/h).
- **Server save handler updated:** now writes `minExtraDistance` and `rampMaxSpeedKmh` to config.lua, preserving all three modes correctly.

This fixes the "very forward POV at 0-100 km/h" issue — the camera now starts at a comfortable distance even when idle.

