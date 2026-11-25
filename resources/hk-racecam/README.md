<div align="center">

# 🎥 hk-racecam

### Motorfest-style dynamic chase camera for FiveM

**A weighted, physics-reactive vehicle camera with idle-detected engagement — the cinematic chase cam from Forza Horizon and The Crew: Motorfest, built for FiveM.**

`v1.0.1` · `FiveM` · `QBCore / Standalone` · `Lua 5.4`

</div>

---

## ✨ Overview

`hk-racecam` is a drop-in scripted camera that gives every vehicle a weighty, reactive chase view without ever stealing the player's free-look. It watches your look input: stop moving the mouse for a moment and the cinematic cam eases in; touch the mouse and it instantly hands control back to the stock camera.

Unlike a rigid `SetCamRot` copy, every frame is positioned manually from the vehicle's heading and velocity, then eased toward — the lag *is* the weight. Layer on speed-reactive FOV, terrain-aware pitch, cornering lean, motion blur, and a true reverse cam, and you get a camera that feels alive at any speed.

> **One persistent camera, never destroyed mid-session.** Smooth engage/disengage blends, collision-aware framing, and per-vehicle adaptive sizing mean it just works — on a low coupe, a tall SUV, or any addon vehicle on your server.

---

## 🚀 What's New in 1.0.1

This release is a complete overhaul of the camera's **dynamics and feel** following extensive in-game tuning.

### Added
- **Rotational inertia** — the car now visibly rotates in frame through a turn (front swings one way, rear the other), with attack/release easing, velocity progression, a hard angle cap, and a short input-leap delay so it never kicks in jarringly.
- **Terrain pitch following** — the camera tilts to keep the road ahead visible on hills, with asymmetric uphill/downhill handling and slope-clearance so your own bodywork never blocks the view.
- **Handbrake punch** — a short, decel-scaled camera kick when you yank the handbrake (no motion if the car doesn't actually slow).
- **Camera collision** — synchronous shapetest pulls the cam in before it clips walls, barriers, or terrain, engaging slightly early so it never pokes through.
- **Cornering rear-swing** — the camera reframes toward the car's rear quarter in corners, Forza-style.
- **Cornering roll** — subtle camera bank into turns, driven by steering + lateral G-force.
- **Speed-scaled motion blur** and **high-speed FOV zoom** for a stronger sense of speed.

### Fixed
- **Reverse-cam "looks backwards" bug** — root-caused to `PointCamAtCoord` leaving the camera in a persistent pointing mode that silently overrode rotation. The cam now cleanly hands rotation back when returning to chase.
- **Reverse false-trigger on drifts** — a handbrake 180 / drift's brief backward slide no longer flips to the reverse cam (guarded by handbrake state, recent-throttle + forward-motion window, and lateral-slide detection).
- **Engage "fall-back" pop** — the camera no longer starts too far back and races to catch the accelerating car; the seed is clamped to the chase distance and velocity-compensated through the blend.
- **Downhill "camera into the ground" bug** — vertical velocity was dragging the camera down on descents; vertical compensation removed.

### Changed
- Smoother, progressive engage blend (ease-out dolly into the chase pose).
- Reworked per-V-mode framing (near / medium / far) and roof-anchored height so tall vehicles keep a consistent viewing angle.

---

## 📦 Installation

1. Place the `hk-racecam` folder in `server-data/resources/[standalone]/`.
2. Add to your `server.cfg`:
   ```cfg
   ensure hk-racecam
   ```
3. **(Optional)** For Discord role-based admin access to the live debug menu:
   - Ensure `badger_discord_api` is installed and started **before** `hk-racecam`.
   - Open `server.lua` and add your Discord admin role IDs to the `adminRoleIds` table.
4. Start the server (or `ensure hk-racecam` / `restart hk-racecam` from console).

### Requirements
| | |
|---|---|
| **FiveM artifacts** | Any recent build |
| **Framework** | QBCore *(optional — for notify + admin checks)*; runs standalone |
| **Dependencies** | None required. `qb-core` and `badger_discord_api` are optional integrations. |

---

## 🎮 Usage

### Player Controls
| Input | Action |
|-------|--------|
| **F7** | Cycle modes: off → chase → hood → off |
| **F4** | Lock / unlock motion (freezes dynamic sway & zoom for a static frame) |
| `/racecam` | Cycle modes (same as F7) |
| `/racecam <preset>` | Jump to a preset (`chase`, `hood`) |
| `/racecam off` | Turn the camera off |

The cam only engages while **driving** (not as a passenger) and above the configured minimum speed. Switching to first-person (V) hands control back automatically. Hold **C** to look behind — the camera flips to a reverse view and returns cleanly on release.

### Admin Debug Menu
**Command:** `/racecam_debug` *(admin only)*

A live NUI tuning panel — adjust framing on the fly and push changes without a restart:

| Button | Effect |
|--------|--------|
| **Apply (Me Only)** | Live-updates your client only (test safely) |
| **Broadcast to All** | Pushes changes to every player on the server instantly |
| **Save to Config** | Writes values back to `config.lua` (persists across restarts) |
| **Reset to Saved** | Reloads values from disk |

**Permission is checked in order:** `qb-core` admin → CFX ace (`IsPlayerAceAllowed`, server owner) → Discord role IDs (if `badger_discord_api` is configured).

---

## ⚙️ Configuration

All tuning lives in `config.lua`, heavily commented. Highlights:

- **Engagement** — idle threshold, ease in/out timing, smooth-engage blend.
- **Cornering** — roll, rotational inertia, rear-swing, pitch-following (uphill/downhill clearance).
- **Reverse** — true-reverse detection + handbrake-drift guard.
- **Collision**, **MotionBlur**, **SpeedFov**, **GForce**, **Adaptive** sizing, and per-V-mode distance/height overrides.

### Per-Vehicle Custom Presets
For vehicles needing manual tuning (oddly-sized addons, bikes, trucks), add entries to `Config.VehiclePresets`, keyed by spawn name (case-insensitive):

```lua
Config.VehiclePresets = {
    -- Per-preset override (only touches the presets you name):
    ['adder'] = {
        chase = { baseDistance = 7.0, baseHeight = 2.8, heightLift = 0.5 },
        hood  = { offset = vector3(0.0, 2.2, 0.7) },
    },
    -- Global override (applies to ALL presets on this vehicle):
    ['faggio'] = {
        baseDistance = 4.0,
        baseHeight   = 1.5,
    },
}
```

Resolution is cached on a triple cross-check (entity + preset name + model hash), so swapping vehicles, presets, or models forces a clean re-resolve. Only specify fields you want to change; nested tables (`fov`, `offset`) are replaced wholesale. Set `Config.Debug = true` to see `resolve:` lines confirming which config applied.

---

## 🔌 Exports

```lua
exports['hk-racecam']:SetArmed(true)       -- Enable / disable the cam mode
exports['hk-racecam']:SetPreset('chase')   -- Jump to a preset
exports['hk-racecam']:IsArmed()            -- bool: is the mode armed?
exports['hk-racecam']:IsEngaged()          -- bool: is the cam currently rendering?
exports['hk-racecam']:GetPreset()          -- string: current preset name
```

These let you wire the camera into radial menus, garages, or other resources.

---

## 🛠️ Compatibility & Notes

- Works with **any vehicle**, including custom/addon models — sizing is read at runtime from the model's bounding box, no `vehicle.meta` parsing needed.
- Never permanently disables free-look; the stock camera is always one mouse-flick away.
- All natives verified against [docs.fivem.net](https://docs.fivem.net).

---

## 📜 Changelog

### v1.0.1
Major dynamics overhaul — rotational inertia, terrain pitch-following, handbrake punch, camera collision, cornering roll & rear-swing, motion blur, high-speed zoom. Fixed reverse-cam orientation, drift false-triggers, engage fall-back, and the downhill camera-sink bug. See **What's New** above.

### v1.0.0
Initial release — idle-detected engagement, chase + hood presets, adaptive sizing, speed-reactive FOV, lateral swing, reverse cam, QBCore notify, live admin debug menu.

---

<div align="center">

Built for the **HOMEKONG** roleplay server.

</div>
