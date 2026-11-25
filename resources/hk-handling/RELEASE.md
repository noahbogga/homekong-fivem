<!--==============================================================
  hk-handling — HOMEKONG Vehicle Dynamics
  Release / feature documentation
================================================================-->

# hk-handling — Advanced Vehicle Dynamics for FiveM

> **One resource. Every car on your server, transformed.**
> Real transmissions, real drift, real differentials, real aero — a single
> unified physics layer that makes vanilla GTA driving feel a decade old.

`hk-handling` is a ground-up vehicle dynamics engine for FiveM. It is **not**
another "press shift to drift" script. It is a complete, modular driving layer:
a multi-type transmission system (our automatic, manual, three DCT tiers,
sequential dogbox) with a per-car **gear-ratio character** layer, brake-based
limited-slip & locked differentials, a native-powered drift system with true
counter-steer control, launch control, controlled wheelies, active aero, ABS,
traction & stability control — all sharing **one** clean physics core.

---

## Why this is different

Most handling/drift/gearbox scripts on the market do **one** thing and fight the
game to do it. We built a single coherent system where every module composes
through one torque/physics pipeline — so traction control, a DCT shift, and a
drift can all happen in the same frame without stomping each other.

What no other public release does the way we do:

- **Per-vehicle transmission *identity*.** Every model can be assigned a gearbox
  *type* (our automatic, classic manual, three DCT tiers, sequential dogbox)
  **and** a *gear-ratio character* (Default / Sport / Drag / Hypercar), both
  stored server-side and applied automatically the moment any player enters that
  car. A Supra feels like a manual; a 296 GTB feels like a paddle-shift PDK — with
  zero per-player setup.
- **A real Dual-Clutch simulation** — semi-automatic that shifts itself, drops
  into paddle-manual the instant you pull a paddle, and returns to auto on demand.
  With **over-rev downshift protection**: bang it down a gear too many and the
  ECU refuses, blips, and bounces you back — exactly like a modern supercar.
- **Speed-invariant by design.** A hard rule runs through the whole box: change
  gear *feel*, never the car's real acceleration or top speed. Every car still
  reaches its exact `handling.meta` top speed, and an Accel-Match trim keeps 0–100
  honest against the stock figure — so you tune character without breaking balance.
- **Brake-vectoring differentials.** GTA fakes an open diff; we simulate an LSD /
  locked diff by braking the over-spinning driven wheel, so power-on grip and
  drift are *consistent* instead of twitchy. Per-axle, drivetrain-aware.
- **Drift built on R\*'s own drift-tyre physics**, not crude grip-curve hacks —
  then layered with counter-steer lock, throttle-sustained slides and a
  brake-locked diff so you can actually *hold* an angle and ride it.

---

## The Transmission System — the centrepiece

Assign any vehicle **model** a gearbox type *and* a gear-ratio character. Both are
stored in the database and applied automatically to every instance of that car, for
every player, the moment they get in. No menus, no per-player config, no "turn it on
each time."

### Gearbox TYPE — `/setgear`

| Type | Name | Feel |
|:----:|------|------|
| `0` | **NEW Automatic** | The default on every car. A *better-than-stock* relaxed auto that **overrides GTA's box** — early/lazy upshifts, de-jerked shifts, anti-hunt, smooth launch. For cruisers and dailies. |
| `1` | **Classic Manual** | Full H-pattern with a real **clutch** — hold to declutch & coast, shift on K/J, clutched shifts are quick & rewarded, missed clutchless shifts bog. Engine-braking, soft-stall lugging, the lot. |
| `2` | **Automatic (Paddle)** | A modern **torque-converter** auto (ZF-8HP flavour) that also takes paddles. Drives itself, pull a paddle and it's instantly manual; clutch key drops it back to auto. Elastic feel: revs slip a touch ahead under load, shifts **slur soft at cruise and bang firm at WOT**, gentle throttle-gated upshift shove. The everyday/GT choice. |
| `3` | **Sport DCT** | A real **dual-clutch** — rigid and immediate, a firm kick on *every* upshift at any throttle. Faster than `2`, revs out higher, more urgent. |
| `4` | **Super DCT** | Hypercar tier: near-instant race shifts (~15 ms), holds to the limiter, the sharpest boost. Lockable **paddle-only** per car for a true race feel. |
| `5` | **Sequential Dogbox** | Race/rally hybrid. Fast clutchless dog upshifts **graded by timing** (perfect-shift boost / early-shift bog / over-rev bounce), synchro double-clutch downshifts. The skill mode. |
| `6` | **GTA Native** | **Debug only.** Sim disabled — raw stock GTA. The only way to get native behaviour; no upgrade path. |

> Any car with no database row defaults to **Type 0 (our automatic)** — our box runs,
> not GTA's. Type 6 is the lone opt-out, intended for debugging.

### Gear-ratio CHARACTER — `/gearratio`

A second, orthogonal dial: *how* the assigned box shifts, **without touching real top
speed**. Mix freely with any type.

| Mode | Name | Character |
|:----:|------|-----------|
| `0` | **Default** | Stock shift feel — the safe baseline. |
| `1` | **Sport** | Punchy launch, fast revs, but smooth unhurried upshifts. |
| `2` | **Drag** | Short early gears that bang through fast; hard launch. |
| `3` | **Hypercar** | Ratios scale up the ladder — short low gears, long high gears, near-instant shifts. |

### Jim-mechanic upgrade integration

When the **jim-mechanic gearbox upgrade** is installed on a car, the box auto-promotes
it live — the type steps up (e.g. Automatic (Paddle) → Sport DCT, Manual → Sequential) and, in
most cases, grants a sportier ratio character. An admin-set ratio is always respected
(the upgrade advances it rather than overwriting). Native (Type 6) cars are locked out
of the upgrade path. Install or remove the upgrade and the box re-arms on the spot.

### What makes the gearbox special

- **Clutch-gated manual that actually decouples drive** — holding the clutch
  genuinely cuts power to the wheels (engine free-revs, car coasts), with a
  framerate-correct rev-feed so re-engagement is smooth, not a jolt.
- **Over-rev downshift protection (DCT)** — you can *try* any downshift, but if
  it would over-rev the engine the box blips a warning, briefly slips the gear,
  applies a short power penalty, then snaps back to the safe gear — and locks
  further downshifts during the window so you can't force a 5→3 grenade.
- **Learned + seeded gear ratios** — the system seeds each car's rpm-per-speed from
  its real `handling.meta` at entry, then refines it live, so the over-rev guard and
  shift points are accurate to *that* vehicle from the first metre.
- **Cornering-aware shift logic** — ground-truths shift points against real road
  speed, so an open-diff wheelspin spike in a turn can't trigger a premature, bog-y
  upshift.
- **Per-gear rev limiter** — at redline in a held gear, power is cut so the car
  caps at that gear's real top speed (with a hysteresis flutter), instead of
  vanilla's "rev pegged but still accelerating" nonsense — while never capping the
  top gear below the car's true top speed.
- **Anti-lug floor** — crawling in a tall gear at low rpm stays sluggish-but-alive
  instead of dropping to zero pull.
- **Admin-driven, hot-applied** — set a model's gearbox/ratio with one command; the
  change re-arms on every player **live**, no re-spawning required.

### Framework integration

- **Jim-Mechanic ready** — the gearbox upgrade routes straight into our system and
  promotes the car's tier automatically (see above).
- **QBCore / qbx_core notifications** out of the box, with a clean GTA-native
  fallback when no framework is present.
- **Absorbed speedometer** — an on-screen gauge that reads the live gear from our
  box (no third-party gearbox dependency).

---

## Drift System

Built on Rockstar's **drift-tyre** physics (the LS-Tuners model), then layered
with everything the native alone doesn't give you:

- **Hold-to-drift** — one key. A brief **auto-handbrake tap** kicks the rear out
  to initiate, so you don't fumble for spacebar; tap it yourself mid-slide to
  re-kick and tighten the angle.
- **Throttle-sustained slides** — traction loss scales with throttle, so a light
  maintenance throttle holds a steady angle and stabbing the gas extends it.
  Power-oversteer, the way real drifting works — not RPM tricks.
- **Counter-steer lock** — extra steering range so you can actually catch and
  hold the slide instead of spinning.
- **Looser tail + tuned suspension** while drifting, all captured and cleanly
  restored the instant you let go.
- **Locked-diff pairing** — when the differential module is on, drift mode
  engages a locked-diff preset so both rear wheels turn together and the slide is
  linear and predictable.

## Differential Simulation (LSD / Locked)

GTA simulates an open diff — the unloaded wheel spins free and steals torque.
We fix it with **brake-based torque vectoring**: detect the left-vs-right speed
difference within the driven axle and brake the faster wheel to pull the pair
together.

- **Drivetrain-aware** — works on RWD (rear), FWD (front) and AWD (both axles).
- **Two presets** — a gentle always-on **LSD** for OEM corner-exit traction, and
  an aggressive **Locked** preset that auto-engages in drift mode.
- Throttle-gated and brake-aware so it never fights your inputs or the ABS.

## Full Dynamics Suite

Every system below is an independent, individually-toggleable module sharing the
same physics core:

| Module | What it does |
|--------|--------------|
| **Traction Control** | Off / Low / High. Detects wheelspin, smoothly trims torque to regain grip. |
| **ABS** | Detects locked wheels under braking and pulses brake force at a realistic cadence. |
| **Stability Control (ESC)** | Catches high-speed oversteer by trimming torque and stiffening the anti-roll bar. Auto-disables in drift mode. |
| **Speed-Dependent Downforce** | Planted at speed, light at low speed — gravity or true force-based, front/rear biasable. |
| **Active Aero / DRS** | Sheds drag on straights for top speed; adds drag under heavy braking for shorter stops. |
| **Launch Control** | Stage on throttle+brake, hold optimal revs, boosted launch on release. |
| **Controlled Wheelie** | Hold-to-wheelie via real force application, pitch self-limiting so it won't loop — a clean replacement for GTA's violent hardcoded muscle-car wheelie. |
| **Drag Headlift** | Automatic, subtle nose-lift during a hard standing start. |

---

## Architecture

`hk-handling` is built on a shared library, **`hk-vehlib`**, which centralises
telemetry, safe handling get/set/restore, force application, drivetrain natives
and notifications. Benefits:

- **One torque pipeline.** Every module composes through a single per-frame
  torque multiplier — modules never blindly overwrite each other.
- **Capture & restore.** Every handling-value change is captured and cleanly
  restored on exit, so the resource leaves no permanent marks on a vehicle.
- **Self-healing.** Detection re-arms automatically on vehicle change, noclip,
  teleport, or admin change — no "stuck in the wrong mode."
- **Client-authoritative, OneSync-safe.** Physics natives run only on the
  driver's client, exactly as FiveM requires.

---

## Configuration

Everything is driven from a single, heavily-commented **`config.lua`** — no code
edits required to tune the feel.

```lua
Config.Enabled = true     -- master switch
Config.Debug   = false    -- F8 diagnostics

Config.Keys = {
    ToggleDrift = 'CAPS',     -- hold to drift
    Wheelie     = 'LMENU',    -- hold for a controlled wheelie
    ShiftUp     = 'K',        -- gear up   (manual + DCT paddle)
    ShiftDown   = 'J',        -- gear down (manual + DCT paddle)
    Clutch      = 'LSHIFT',   -- ONE gear key, interpreted per transmission:
                              --   manual = held clutch / DCT = auto<->paddle
}
```

Each system has its own config block with an **`Enabled`** flag and full inline
documentation of every tunable — e.g. `Config.Drift`, `Config.Gearbox`,
`Config.Diff`, `Config.TractionControl`, `Config.ABS`, `Config.ESC`,
`Config.Downforce`, `Config.DRS`, `Config.LaunchControl`, `Config.Wheelie`,
`Config.Speedo`.

The gearbox carries **per-tier DCT profiles** (`Config.Gearbox.DctProfiles`) so
Basic / Sport / Super DCT each have their own shift speed, rev-out ceiling,
over-rev penalty window and boost; a **ratio-mode table** (`Config.Gearbox.RatioModes`,
the four shift-feel characters); a **sequential block** (`Config.Gearbox.Seq`); a
manual skill block (`Config.Gearbox.Manual`); the **jim-upgrade map**
(`Config.Gearbox.Jim`); and the **speed-invariant guard** (`Config.Gearbox.AccelMatch`).
Adding a new gearbox tier is just one more profile table, no code changes.

> **Drive-layout note:** the gearbox/drift systems read each vehicle's real
> drivetrain from `handling.meta`. Cars with correct `fDriveBiasFront` values
> (true RWD/FWD/AWD) get the most authentic behaviour. A grip-tuned car pack
> gets the best results.

---

## Requirements

- FiveM server on **game build 2372+** (drift-tyre natives); **3095+**
  recommended for the full transmission feature set. Tested on build **3570**.
- **oxmysql** (for the per-vehicle gearbox database).
- **QBCore / qbx_core** optional (notifications); works standalone otherwise.

---

## Credits & licensing

- All systems — manual transmission, DCT, sequential, comfort-automatic,
  core dynamics, differential, drift, and aero — are original HOMEKONG work.

**© HOMEKONG. Commercial release — not for redistribution.**


