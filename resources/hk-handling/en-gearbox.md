# hk-handling — Gearbox Guide

This resource simulates a real clutch-and-gear drivetrain on top of GTA's engine.
Every vehicle has **two independent settings**, both stored per model in the
database and applied automatically the moment any player drives that car:

1. **Gearbox TYPE** (0–6) — *what kind of box it is*: our automatic, manual, DCT,
   sequential, etc. Set with `/setgear`.
2. **Gear-ratio MODE** (0–3) — *the shift-feel character* layered on top of the
   type: Default / Sport / Drag / Hypercar. Set with `/gearratio`.

They are orthogonal: an Automatic (Paddle) can run a Drag ratio feel, a Manual can run a
Hypercar ratio feel, and so on. This guide covers both, plus how the
**jim-mechanic gearbox upgrade** promotes a car.

> **About RPM in this guide:** GTA's engine RPM is a 0.00–1.00 value with an *idle
> floor of ~0.20* (it never reads 0 while running). Throughout this doc we talk in
> **REAL REV%** — the intuitive 0–100% you see on the `/rpmdebug` overlay — where
> 0% = idle and 100% = redline. Internally the code uses the raw 0–1 value.

---

## Quick mode list (gearbox TYPE)

| Type | Name | Class | Clutch? | Who it's for |
|:----:|------|-------|---------|--------------|
| **0** | NEW Automatic | Automatic | No | **The default.** Our comfort auto — overrides GTA's box |
| **1** | Classic Manual | Manual H-pattern | Optional | Drivers who want full clutch control |
| **2** | Automatic (Paddle) | Torque-converter auto + paddle | No | Everyday cars, GT/luxury — smooth auto you can override |
| **3** | Sport DCT | Dual-clutch (sharper) | No | Aggressive sports/supercar shifts |
| **4** | Super DCT | Dual-clutch (razor) | No | Hypercar; can be locked paddle-only |
| **5** | Sequential Dogbox | Sequential (hybrid) | Optional | Skill mode — rewards shift timing |
| **6** | GTA Native | Stock automatic | No | **Debug only** — raw GTA, sim disabled |

> **Default behaviour:** any car-class vehicle with no database row runs **Type 0
> (NEW Automatic)** — our box, not GTA's. **Type 6** is the *only* way to get raw
> stock GTA behaviour, and it's intended for debugging.

<!-- CHUNK2 -->
---

## Type 0 — NEW Automatic (the default)

A smooth, **better-than-stock automatic** that replaces GTA's own box on every car
that doesn't have another type assigned. It picks gears for you, shifts gently with
a brief torque dip so it feels like a real torque-converter auto (not an instant
snap), holds an anti-hunt dwell so it won't oscillate on hills, and eases torque off
the line for a smooth pull-away. No clutch, no skill input — just drive.

---

## Type 1 — Classic Manual

A full **manual transmission** with an optional clutch.

- **Shift up / down** with your shift keys. You climb one gear at a time.
- **Clutch (optional):** holding the clutch key while shifting gives a clean,
  boosted shift. Shifting **without** the clutch still works, but:
  - **Rev-match it** (engine RPM close to what the new gear wants) → **bonus power**.
    This is the skill reward.
  - **Miss the rev-match** → a brief drop to neutral (a "missed gate") then a mild
    **bog** for a moment. Nail it, or hold the clutch.
- **Neutral:** hold both shift keys together (temporary).
- **Reverse:** shift down past neutral.
- **Lugging:** in too high a gear at too-low revs the engine bogs but never dies — a
  small "lug floor" keeps it rolling.

**How to drive it well:** hold the clutch for safe clean shifts, or go clutchless and
nail the rev-match for the power bonus.

---

## Types 2 / 3 / 4 — Auto-with-paddle family

All three shift themselves and let you pull a paddle any time to take manual control;
the clutch key hands it back to auto. They share ONE gear engine but split into two
**distinct feels** — a torque converter (type 2) vs a dual-clutch (types 3/4):

- **Type 2 — Automatic (Paddle):** a modern performance **torque-converter** auto
  (think ZF 8-speed) that also takes paddles. Elastic, refined feel: revs run a touch
  ahead of the gear under load then settle (converter slip), shifts **slur softly when
  cruising and bang firm at full throttle**, and there's a gentle throttle-gated shove
  on the upshift. The everyday/GT choice — smooth, but sharp when you ask.
- **Type 3 — Sport DCT:** a real **dual-clutch**. Rigid and immediate — a firm, always-
  there kick on *every* upshift regardless of throttle. Faster, revs out higher.
- **Type 4 — Super DCT:** the sharpest — near-instant race shifts, the hardest kick,
  holds to the limiter. Can be locked to **paddle-only** per vehicle (no auto shifting)
  for a true race feel via `/setgear 4 1`.

The split is deliberate: the **torque converter feels elastic and load-variable**, the
**dual-clutch feels rigid and always-firm** — so a DCT is the more aggressive, more
rewarding choice on a sports car. All three have:
- **Over-rev downshift protection** — try a downshift that would over-rev and the box
  blips a warning, briefly slips, applies a short penalty, then snaps back to the safe
  gear and locks further downshifts during the window.
- **ECU-limited neutral revs** — won't slam the revs like the manual does.
- A **redline-shift power boost** when you nail a manual upshift near the top.

**Start-in-neutral:** a freshly-entered DCT car (engine was off) starts in **neutral**
and waits for a **handbrake (spacebar) tap** before engaging a gear — the "release
park" feel. (Server-toggleable; see `DctAutoStartInNeutral`.)

**How to drive them:** leave it in auto and enjoy, or use the paddles to override.
Higher types reward deliberate, rhythmic shifting and feel more hardcore.

---

## Type 5 — Sequential Dogbox (the skill mode)

A **sequential dogbox** — like a race/rally car. The most involved type and the one
with the richest feel. It revs up fast (light dogbox internals) and **grades every
upshift** by how well you time it.

### The upshift zones (2nd gear and up)

When you upshift from 2nd or higher, the shift is graded by your **REAL REV%** at the
moment you press shift:

| REAL REV% | Result | What happens |
|-----------|--------|--------------|
| Below ~73% | **SLUG** | Shifted too early. Gear still engages (never neutral) but **bogs** — soft pull for a moment. |
| ~73–79% | **ENGAGE** | Clean engage. No bonus, no penalty. |
| **~79–91%** | **PERFECT** ⭐ | Nailed it! Big **torque boost** for the next gear + a callout. |
| ~91–94% | **ENGAGE** | Clean engage (just past the perfect window). |
| Above ~94% | **BOUNCE** ❌ | Revved too high — the dogs clash and **reject** the shift. Press shift again. |

### Launch & 1st gear

- **Neutral → 1st (launch):** rev up and go. REAL REV% in the **launch window
  (~66–82%)** gives a **launch boost**. A low-rev / idle pull-away just engages
  cleanly — **it never bogs**.
- **1st → 2nd:** eligible for **either** the launch window **or** the perfect window.
  **Never bogs, never bounces** — the "pull away nicely" shift.
- **2nd → 3rd and up:** full grading (the zones table above).

### Downshifts

- **With clutch held:** wide, forgiving synchro-style window — easy clean downshift.
- **Clutchless:** tight window; you must rev-match yourself. A bad match gives a brief
  harsh "dog clunk" penalty, but the gear **still engages** (a dogbox never drops to
  neutral on a missed downshift).

### How to drive it well

Wind it out, shift right as you approach the top of the rev range (but not past ~94%
or it bounces), and time shifts to land in the perfect window for the next-gear boost.
Off the line: rev into the launch window and go.

---

## Type 6 — GTA Native (debug only)

The gearbox simulation is **disabled**. The car drives exactly like stock GTA — the
game handles shifting, no clutch, no rev-matching, no shift feel from this resource.
This is the **only** way to get raw native behaviour, and it's meant for debugging /
A-B comparison (e.g. against `/accel`). It has **no jim-upgrade path** — a native car
stays native even with the manual upgrade installed.

---

## Gear-ratio MODES (`/gearratio`) — the shift-feel layer

On top of the type, each car can run one of four **ratio modes** that retune *when*
the box shifts and *how hard it pulls* — **without ever changing the car's real top
speed**. They modulate whatever type is active.

| Mode | Name | Character |
|:----:|------|-----------|
| **0** | Default | Stock shift feel. The safe baseline — byte-identical to no ratio mode. |
| **1** | Sport | Harsh, punchy launch (low-gear torque + faster revs) but **smooth, unhurried upshifts**. |
| **2** | Drag | **Short early gears** — 1st/2nd bang through fast, revs climb hard, strong launch punch. |
| **3** | Hypercar | **Ratios scale up the ladder** — low gears short & hard, high gears hold longer ("never runs out of gears"), near-instant shifts. |

> **Top speed is never touched.** Ratio modes only change shift points, hold, and
> low-gear punch. The car still reaches exactly its `handling.meta` top speed in every
> mode. (Acceleration is also kept honest — see *Speed-invariant design* below.)

---

## Jim-mechanic gearbox upgrade

If [jim-mechanic](#) is installed and a car has the **gearbox upgrade**, the car is
automatically **promoted** — its type steps up, and in most cases it gains a ratio
mode too. This is detected live; install or remove the upgrade and the box re-arms
on the spot.

| Base type | Upgrades to | Ratio granted |
|:---------:|-------------|:-------------:|
| 0 NEW Automatic | **2** Automatic (Paddle) | — (ratio untouched) |
| 1 Classic Manual | **5** Sequential Dogbox | — (ratio untouched) |
| 2 Automatic (Paddle) | **3** Sport DCT | Sport (1) |
| 3 Sport DCT | **4** Super DCT | Sport (1) |
| 4 Super DCT | **4** Super DCT | Hypercar (3) |
| 5 Sequential Dogbox | **1** Classic Manual | Drag (2) |
| 6 GTA Native | *locked — no upgrade* | — |

> **Admin ratio always wins.** If you've already set a car's ratio with `/gearratio`,
> the upgrade won't overwrite it — instead a Sport-tuned car steps up to Hypercar,
> while Drag and Hypercar stay as they are. A car still on the default ratio receives
> the granted ratio in the table above. Types 0 and 1 never touch the ratio at all.

---

## Admin commands

```
/setgear <type|remove> [forcePaddle]
    type        0–6 (see the type table). 'remove' / 'clear' / 'none' deletes the row.
    forcePaddle 0 = normal (default)
                1 = force paddle-only (DCT never auto-shifts)
                2 = force-auto (DCT locked in auto, paddles inert)
    Sets the gearbox TYPE for the model you're sitting in. Preserves its ratio.

/gearratio <0–3>
    0 Default / 1 Sport / 2 Drag / 3 Hypercar.
    Sets the shift-FEEL for the model you're sitting in. Preserves its type.
    ⚠ Re-resolved when the box arms — RE-ENTER the vehicle to feel the change.
    (Rejected on type 6 — native cars aren't processed.)
```

Both are per **model** (every instance of that car, for every player) and stored in
the database. No menus, no per-player setup.

### Keys (FiveM-rebindable)

| Action | Default | Meaning per type |
|--------|:-------:|------------------|
| Shift up | `K` | Manual / sequential / DCT paddle |
| Shift down | `J` | Manual / sequential / DCT paddle |
| Clutch | `LSHIFT` | Manual = held clutch · DCT = auto↔paddle toggle · seq = mainly downshift |

**Neutral** has no dedicated key: hold **both** shift keys together (temporary on
manual/seq, latched after a double-tap on DCT). **Reverse:** rotate down past neutral.

---

## Speed-invariant design (for server owners)

This resource's mandate is **change gear FEEL, not acceleration or top speed**:

- **Top speed is a hard invariant.** The box never writes top-speed fields and
  disables its rev-limiter speed-cap in the top gear, so every car always reaches its
  real `handling.meta` top speed.
- **Acceleration stays honest.** Because our box shifts smarter than GTA's lazy native
  box, DCT cars would otherwise be ~0.3–0.8s faster to 100 km/h (GTA bogs on a bad
  upshift; we don't). An **Accel-Match** trim claws that back — a torque-only cut
  (always ≤ 1.0, so it can never *add* power) across the mid-speed band, landing 0–100
  back on the native figure. Off by default for non-DCT types; one global depth knob,
  no per-car tuning.
- The only sustained >1.0 effects are **opt-in** (a brief DCT upshift boost, optional
  Launch Control) — never silent always-on power.

---

## Notes for tuners

- All shift "feel" values live in `config.lua` under `Config.Gearbox` (shared),
  `Config.Gearbox.DctProfiles` (per-DCT-tier), `Config.Gearbox.Seq` (sequential),
  `Config.Gearbox.RatioModes` (the four ratio modes), `Config.Gearbox.Manual`
  (mode-1 skill reward/penalty), and `Config.Gearbox.AccelMatch` (the speed guard).
- RPM thresholds in config are in the **raw 0–1** scale. Convert from REAL REV% with:
  `raw = 0.20 + 0.80 × rev%`.
- Adding a new DCT tier = one more `DctProfiles` entry + a `ModeLabels` row — no code
  changes to the shift engine.
- The on-screen RPM tool is `/rpmdebug` (RAW, derived RPM, REAL REV%, gear).
- The 0–100 timer is `/accel` — use it to verify a mode against `/setgear 6` (native)
  on the same car.
