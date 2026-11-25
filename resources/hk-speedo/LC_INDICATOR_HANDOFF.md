# hk-speedo — Launch Control (LC) Indicator Handoff

Goal: replace the temp `/lcdebug` on-screen text with a proper **LC indicator** in the gauge
NUI. Shows launch-control state: STAGED (armed, holding launch rpm) → LAUNCH! (fired, boost
active) → gone.

## Data sources (already wired in hk-handling — just consume)

### A. Driver — instant local read (export)
`exports['hk-handling']:GetLaunchState()` returns:
```lua
{
  active   = bool,             -- staged OR launched
  phase    = 'off'|'staged'|'launched',
  rpm      = 0..1,             -- the STAGED target launch rpm (0 unless phase=='staged')
  applied  = bool,             -- gearbox active on this car
  -- (diagnostic fields also present: gearMode,isEV,isHybrid,hybridEMode,dctNeutral,
  --  dctManual,revGate,lcSeen,lcHb,lcHbRaw,lcThr,lcKmh — ignore for the final UI)
}
```
This is the SAME export the temp overlay already calls (client.lua ~1285). Driver-local,
zero-latency — use it for the driver's own gauge.

### B. Passenger — replicated statebag (`hk_drivestate`)
hk-handling PUBLISHES to the vehicle bag (~10 Hz, change-detected). Read via the existing
`readDriveStateBag(veh)` (client.lua:498). Launch fields in the bag:
```lua
launchActive = bool,           -- staged OR launched
launchPhase  = 'off'|'staged'|'launched'
```
NOTE: the bag does **NOT** carry `launchRpm` (only the export does). If the indicator needs
the staged rpm number for a passenger view, add `launchRpm = ds.launch and ds.launch.rpm`
to the bag publisher in gearbox.lua `publishDriveState()` (~line 4178) AND to `buildDriveState()`
(~line 4136, alongside launchActive/launchPhase). For a simple STAGED/LAUNCH! badge you don't
need rpm on the passenger side — phase is enough.

## Unify with the existing pattern

The speedo already splits driver vs passenger everywhere:
- driver loop uses `getDriveState()` (export, client.lua:727)
- passenger loop uses `readDriveStateBag(veh)` (client.lua:1082 / :1174)

Mirror that: driver reads `GetLaunchState()`, passenger reads `launchActive/launchPhase` off
the bag snapshot. Feed a single normalized `{phase, rpm}` into the NUI so the render path is
identical for both seats.

## Phase → UI states

| phase       | meaning                                  | suggested UI                                   |
|-------------|------------------------------------------|------------------------------------------------|
| `off`       | not launching                            | hide the LC badge entirely                     |
| `staged`    | armed: handbrake+full throttle held in N | pulsing "LC" / "STAGED" badge (amber). Optional: a small launch-rpm marker on the rev arc at `rpm` (0..1, maps to the same normalized-rpm the tach uses). |
| `launched`  | fired: gear 1 in, boost fading           | brief flash "LAUNCH!" (green), then fade with the boost window |

Timings for reference (config.lua `Config.Gearbox.Launch`):
- staged: holds `LaunchRpmMin..Max` (0.70..0.92) computed per-car.
- launched → boost `BoostMs = 2400` (just raised), or ends early at `EndSpeedKmh = 90` / on
  throttle lift. So "LAUNCH!" should auto-clear when phase flips back to `off` (don't
  hardcode 2400 in the UI — poll phase; the boost can end before 2.4s on a fast car).

## Wiring steps

1. In the DRIVER gauge loop, after `getDriveState()`, also grab launch:
   `local ok, lc = pcall(function() return exports['hk-handling']:GetLaunchState() end)`
   normalize → `{phase = lc.phase or 'off', rpm = lc.rpm or 0}`.
2. In the PASSENGER loop, from the bag snapshot: `{phase = bag.launchPhase or 'off', rpm = 0}`
   (rpm only if you added it to the bag per the NOTE above).
3. Push `{phase, rpm}` to the NUI via the existing SendNUIMessage channel the gauge uses
   (find the gauge's per-frame message in client.lua and add an `lc` field), OR draw it
   natively if you keep the LC badge outside the NUI.
4. HTML/CSS: add an `.lc-badge` element in `html/` + `style.css`. Match the existing badge
   styling (the A/M gearbox pill / ⚡ pill are the closest siblings — reuse their pill shape).
   `staged` = amber pulse; `launched` = green flash. `off` = `display:none`.
5. REMOVE the temp debug block (client.lua ~1252–1307, the `hkDrawDbg` fn + `/lcdebug` command
   + its CreateThread) once the NUI badge is confirmed working. Leave `GetLaunchState`'s
   diagnostic fields in place (harmless, cheap) or trim to `{active,phase,rpm}` later.

## Gotchas

- The gauge already hides on engine-off (client.lua ~612) — LC badge should ride the same
  visibility gate (no LC when the gauge is hidden).
- Don't confuse `launchPhase=='launched'` with a normal drive: it's a transient (≤ boost
  window). Poll phase every frame; when it returns to `off`, clear the badge.
- Restart order unchanged: hk-vehlib → hk-handling → hk-speedo.
- Single source of truth is hk-handling. Do NOT compute launch state speedo-side; only render.
