# hk-handling — Session Handoff

> Living handoff for the hk-handling gearbox / DCT work. Keep this accurate; the
> authoritative deep spec is the memory file (see below). If this file and the code
> disagree, the CODE wins — re-verify before trusting any claim here.

## DESIGN INVARIANT — speeds must match handling.meta (ALL modes, ALL future features)
HOMEKONG vehicles are tuned to real-life 0-60 / 0-100 / top-speed figures. The
script must NOT change those numbers:
- **Top speed = HARD invariant.** Never write `fInitialDriveMaxFlatVel`, never call
  `ModifyVehicleTopSpeed`. The rev-limiter speed-cap is DISABLED in the top gear
  (see applyRevLimiter `inTopGear`) so it can never brake a car below its handling
  top speed. Every car must reach exactly its handling.meta top speed.
- **Acceleration = spec is the baseline.** Power may dip BELOW 1.0 (shifts, clutch,
  stall, rev-limiter, ABS/TC) — that's fine, it nets out. Sustained power ABOVE 1.0
  is OPT-IN only and must stay that way: DCT upshift `BoostMult` (brief reward) and
  Launch Control (Enabled=false by default). A stock car in a normal mode matches
  its 0-100 spec; performance extras are explicit, not silent. (Per user 2026-06-09:
  top speed locked, acceleration kept as-is — do not add new always-on >1.0 boosts.)
- When adding a mode/feature: if it would change a straight-line speed number, it
  must be opt-in and documented here. Grip/cornering fields are exempt (not speed).

## Current state (2026-06-12)
Migration to `hk_handling` + PUBLIC mode renumber DONE. `forceManual` column + dead code
stripped. jim bridge clarified (jim already prefers our exports; `vlad_gears:*` is a dead
fallback kept as a safety net). PHASE 2 gear-ratio mechanism DONE (B1 design) — aggressive
numbers being playtested. Manual skill reward/penalty re-enabled (mode-1-only namespace).
Gearbox + DCT core were functional/tuned in earlier sessions; the three old driving issues
(top-of-gear over-accel, super-DCT auto-return, tall-gear low-rpm cruise) are RESOLVED.
Code-tidy pass (2026-06-12): MODE 1 wrapped in an explicit `if gearMode == 1 then` guard
(was the implicit fall-through "else"); triplicated keybind comment collapsed to one. No
behaviour change — both verified `luac -p` clean. New config toggle `DctAutoStartInNeutral`
(DCT auto spacebar-to-engage, default true = current behaviour) added.
RATIO-MODE HUNT FIX (2026-06-12): `/gearratio 3` (HYPERCAR) hunted 1<->2 — "bog twice
before 2nd" on Chiron AND M3 (so NOT torque/speed-match; pure logic). Root cause: the
DCT-auto downshift BOUNCE GUARD compared `proj(targetGear)` against the CURRENT gear's
upshift point. Modes 1/2 use a uniform `UpshiftRpmMult` (one point for all gears) so it
worked; mode 3's `LadderUpBias` gives each gear a DIFFERENT point, so the guard tested the
wrong (higher) threshold and let kickdown bounce g2->g1->re-upshift. Fix: factored the
per-gear shift point into `upshiftRpmFor(g)` (gearbox.lua, DCT auto block) and the guard now
tests `upshiftRpmFor(newTg)`. `luac -p` clean.
CORNERING BOG FIX (2026-06-12): basic DCT (m3e92) bogged in 1st "at end of gear" ONLY when
turning left-right; a dead-straight launch was fine. NOT a ratio bug — GTA fakes an OPEN DIFF,
so in a turn the unloaded inside driven wheel spins up and `GetVehicleCurrentRpm` follows it,
spiking engine rpm past the up-point while real ROAD speed lags -> premature 1->2 into a gear
too tall for the actual speed = bog. Worst on basic DCT (its 0.80 part-throttle up-point is
the lowest tier, easiest for a spike to clear). Fix: WHEELSPIN GUARD on the DCT-auto upshift
(gearbox.lua) — `rpmGrounded = curProj==nil or curProj >= upRpm-0.10`, where curProj =
`projectGearRpm(dctGear)` (the CURRENT gear's rpm at real ROAD speed). Upshift now also requires
rpmGrounded, so a spin spike with road speed still mid-gear can't trigger it (fires for real
once the car straightens). nil/unlearned => allowed (cold gear can't get stuck). Mirrors the
downshift bounce-guard's "road speed is ground truth" principle, for upshifts. Auto-only;
paddle/downshift/power untouched. `luac -p` clean.
WHEELIE/HANDBRAKE BUG GUARD [F3] (2026-06-12): NATIVE rigid-body bug (not ours) — pulling
the HANDBRAKE while the front wheels are off the ground makes GTA's wheel-constraint solver
dump the whole velocity vector in ONE physics step: car snaps ~20km/h -> 0 and the heading
flips. Bites only in 1st/2nd (low speed + high nose-up authority); seen on addon/modded cars.
Surfaced while building hk-racecam. The player's own hand-found workaround: tap the FOOT brake
(control 72) just before the handbrake — that plants all four wheels so the rear lock-up stays
symmetric and the solver has no asymmetric impulse to discharge. AUTOMATED that: new module
`client/wheelieguard.lua` + `WheelieGuard_Tick`, wired in main.lua AFTER Headlift (runs last so
it sees the final input state). Co-applies `SetControlNormal(0, 72, BrakeLevel)` on the SAME
frame the handbrake is held — the manual "just before" was only human timing; in code the brake
force and handbrake lock reach the same physics step, no race. GATES (all must hold, else no-op):
`state.handbrake` down; gear 1..MaxGear(=2); `speedKmh >= MinSpeedKmh(=5)` so the STANDING LAUNCH
is left alone (nose still flies up freely off the line, per user); `pitch >= NoseUpPitch(=3deg)`
nose-up = front wheels airborne. So normal handbrake turns (wheels down, pitch~0) and intentional
[F1] wheelies (no handbrake) are untouched. New config `Config.WheelieGuard` (Enabled, NoseUpPitch,
MinSpeedKmh, MaxGear, BrakeLevel). If a catch feels too abrupt, lower BrakeLevel (e.g. 0.6) — enough
chassis load to defuse without a dead stop. `luac -p` clean (wheelieguard.lua, main.lua, config.lua).

## Gearbox modes (CONFIRMED semantics — PUBLIC numbering, post-migration)
> Migration DONE: table is now `hk_handling` (was `defaultManual`), modes renumbered to
> the PUBLIC scheme below. The client translates PUBLIC -> FROZEN internal engine numbers
> in `PUBLIC_TO_INTERNAL` / `detectMode` (don't touch the internal numbers). `forceManual`
> column was DROPPED (dead vlad-era gate). Resolution = DB row + car-class default; jim is
> optional (PHASE 1.5 will wire the upgrade remap).
- **0** = NEW automatic — our comfort automatic; THE DEFAULT (car-class vehicles with no row
  resolve here). GTA's box drives; we only NUDGE it (early/lazy upshift, smooth dip,
  anti-hunt). No clutch. Early-RETURNs in the tick. (internal mode 2.)
- **1** = Classic H pattern Manual (clutch) — script owns gears, reduced-gear-ratio ON, clutch
  sim + soft stall + lug floor + rev-limiter. The only mode using the engine-side manual enabler.
  Skill reward/penalty re-enabled via `Config.Gearbox.Manual.*` (see PHASE 2 note). (internal 1.)
- **2** = Automatic (Paddle) — torque-converter auto WITH paddles (was "Basic DCT"). Runs on
  the internal DCT engine (mode 3) so paddle control works, but retuned to a TC FEEL via
  `Config.Gearbox.TcFeel` + `DctProfiles[3]`: elastic slip-flare rpm, load-variable shift
  firmness, throttle-gated upshift kick. PERF-NEUTRAL (WOT accel = the tuned meta). Auto
  sub-mode (script shifts) + paddle/manual sub-mode (K/J). Clutch key toggles. (internal 3.)
- **3** = Sport DCT — same engine, sharper profile (near-instant shifts, revs out higher).
  `DctProfiles[4]`. (internal 4.) [Label was "SUPERCAR DCT".]
- **4** = Super DCT — razor-sharp DCT, highest rev-out, most aggressive downshift rev-match.
  NOT paddle-only by design — paddle-only is the per-model DB flag (`forcePaddle=1`).
  `DctProfiles[5]`. (internal 5.) [Label was "F1-DCT".]
- **5** = Sequential Dogbox (hybrid) — shares the MANUAL machine, own complete branch (gated
  `gearMode==6` internal). DOG upshift (fast, clutchless-fine, no penalty, bonus on perfect
  rev-match). SYNCHRO double-clutch DOWNSHIFT. Tuned via `Config.Gearbox.Seq`. (internal 6.)
- **6** = GTA Native default automatic — DEBUG ONLY. Script does NOT process the car (raw GTA
  box). No upgrade path; `/gearratio` rejects it. The only way to get raw native. (internal nil.)
> NOTE: these are LABELS only (`Config.Gearbox.ModeLabels` + DctProfiles[].Label). The PUBLIC
> mode NUMBERS and the PUBLIC->internal mapping are UNCHANGED — renaming touched no logic/DB.

## PENDING (not done — future passes)
- PHASE 2D — gear-ratio aggressive number tuning (mechanism DONE; numbers being playtested).
- Wiring `Seq.EcuProtect` true when the jim-mechanic manual upgrade is detected.

## PHASE 1.5 — JIM-MECHANIC UPGRADE REMAP (DONE 2026-06-12, needs in-game playtest)
The jim gearbox upgrade now PROMOTES a car's gearbox type and can GRANT a gear-ratio mode.
Client-only — server/DB untouched (jim status is per-vehicle client state).
- **Detection** = `jimUpgradeActive(veh)` (gearbox.lua): `Jim.Enabled AND (toggled OR
  vl_jimIsManual(veh))`. `vl_jimIsManual` reads jim's `GetVehicleStatus(veh).manual==1`
  (authoritative, timing-independent); `toggled` is the legacy `vlad_gears:activate` latch.
- **Resolution** = `resolveEffective(veh)` returns (effectiveType, effectiveRatio), the SINGLE
  source of truth. `resolvePublicType`/`shouldProcess`/`detectMode` read its type; the
  Gearbox_Enable ratio block reads its ratio (via `local _, rmode = resolveEffective(veh)`).
- **TYPE map** (`Config.Gearbox.Jim.UpgradeMap`, entries are `{type=, ratio=}`):
  0→2 (no ratio), 1→5 (no ratio), 2→3 +ratio1, 3→4 +ratio1, 4→4 +ratio3, 5→1 +ratio2.
  Type 6 has NO entry = LOCKED (stays raw GTA even with the upgrade).
- **RATIO rule**: entries with NO `ratio` (types 0,1) leave ratio COMPLETELY untouched. Entries
  WITH a ratio: if base ratio==0 (default) grant entry.ratio; if base ratio~=0 (admin already
  tuned it) the ADMIN value WINS, advanced via `UpgradeRatioProgression` {1→3, 2→2, 3→3}.
  (User spec: admin-set ratio always wins over the upgrade's listed ratio.)
- **LIVE install/remove**: `onActivate`/`onDeactivate` now force Disable→Enable (Enable is
  idempotent, so a live upgrade on an already-armed car needs the re-resolve). onDeactivate
  re-resolves to BASE (keeps the box at DB/car-class default; upgrade was an add-on).
- **Behaviour note**: removed the old `if toggled then return 1` force-manual. The upgrade now
  only PROMOTES a car that already resolves to a base type 0-5; it can NOT create a box on a
  non-car/no-row vehicle (car-class default is the law; jim is an extra trigger, not a dep).
- All `luac -p` clean. PLAYTEST: install jim upgrade on a type-2 car → should become Sport DCT
  + Sport ratio; on a type-4 → Super DCT + Hyper ratio; verify an admin-preset ratio is honoured.

## Where the mode logic lives (keep these in sync when adding a tier)
- `autoMode` (Enable): `(gearMode==2) or (==3) or (==4) or (==5)`. Mode 1 absent (it's
  the manual enabler path). All DCT tiers (3/4/5) are auto-capable.
- DCT branch gate: `if gearMode == 3 or gearMode == 4 or gearMode == 5`.
- SEQ branch gate: `if gearMode == 6` (own complete branch, flat-indented body, returns).
- MANUAL branch gate: `if gearMode == 1` (explicit guard as of 2026-06-12 — was the
  implicit fall-through; auto/DCT return earlier, seq returns above, so it was the only
  mode reaching here, but the guard stops a future/unmapped mode running manual logic).
- gear-pin / GTA auto-shift block: `if gearMode == 1 or (gearMode == 3 and dctManual)`.
- `Config.Gearbox.DctProfiles[mode]` + `Config.Gearbox.ModeLabels[mode]` (config.lua).
- paddle-only: `paddleOnly = (P.PaddleOnly==true) or (db model flag paddle==1)` — DB flag
  is the live mechanism (no profile hardcodes PaddleOnly now).
- Profile fallback at DCT branch top: `DctProfiles[gearMode] or DctProfiles[3]` — a
  MISSING profile silently behaves like internal mode 3 (basic DCT).
- Server `/setgear <type|remove> [forcePaddle]` REQUIRES type, validates vs ModeLabels.
  `/gearratio <0-3>` validates vs RatioModes. Both preserve the OTHER's column.

## Performance pass — DONE this session (no feel change)
Root cause of per-frame cost was NOT the math — it was CFX export overhead. Verified
from the on-disk runtime source: `exports['hk-vehlib'].fn` allocates a FRESH wrapper
closure on every access (scheduler.lua:717), so `vehlib:fn()` in the tick churned the
GC ~4600x/sec. Fixes:
1. **Cached export refs** in all 10 client modules. Each file resolves its vehlib
   functions ONCE at load via a `bind` forwarder, then calls `vl_fn(veh)`. The wrapper
   is `function(self,...)` and discards self, so `bind` injects a nil self slot. ANY new
   vehlib call in the tick MUST be added to that file's cache block — do not reintroduce
   `vehlib:fn()` colon-calls in hot paths.
2. **fInitialDriveForce write dedupe** (gearbox): `setDriveForce(veh,value)` writes only
   on change; `lastDriveForce` mirror reset in Enable/Disable/Reset. Disable's restore is
   a DIRECT `vl_setHandling` (never deduped — must always land). gearbox OWNS this field;
   no other module writes it (verified), so the mirror can't go stale.
See memory `fivem-export-call-cost` for the full reasoning.

## Authoritative spec (READ FIRST for deep work)
`~/.claude/projects/C--Users-Administrator-Desktop-HOMEKONG/memory/hk-handling-gearbox-spec.md`
— the full evolving spec with every native quirk, fix, and tunable. Also:
`hk-handling-audit-findings.md`, `hk-handling-modern-natives.md`, `hk-handling-drift-default-1.md`.

## Critical lessons (don't re-learn the hard way)
- **Real-time power cuts use the ENGINE TORQUE MULTIPLIER, not fInitialDriveForce.**
  On build 3570, `fInitialDriveForce=0` does NOT cut wheel torque in real time (handling
  float only applies at spawn/refresh). Gearbox sets `HK.torqueMult=0`; main.lua applies
  it at setTorque AFTER Gearbox_Tick. fInitialDriveForce=0 is kept only for engine-brake feel.
- **255 gear bug**: reverse stored as -1 -> SetVehicleCurrentGear unsigned byte -> 255.
  `nativeGear(tg)`: R(-1) and N(0) both write native 0; forward passes through; never negative.
- **Instant-shift bug**: write the native gear ONLY on shift commit, gated `not shifting`.
- **Field ownership**: gearbox owns fInitialDriveForce + RPM + throttle controls + gear-set
  + reduced-gear-ratio. Drift owns steering/traction/suspension. Disjoint — keep it that way.
- DCT was failing because GTA's auto box fought our per-frame setCurrentGear. Fix = script
  owns ALL gears (reduced-gear-ratio ON whole DCT life). Don't reintroduce GTA auto-shift in DCT.

## Files in play
- `client/gearbox.lua` — main gearbox + DCT tick (most edits here).
- `client/main.lua` — main loop; dispatches Gearbox_Tick, applies HK.torqueMult at setTorque.
- `config.lua` — tunables (Config.Gearbox, DctProfiles[3/4/5], ModeLabels, RatioModes, Config.Speedo).
- `server/gearbox.lua` — hk_handling model list + /setgear + /gearratio admin commands.
- `sql/hk_handling.sql` — current schema. `migrate_to_hk_handling.sql` (defaultManual->hk_handling),
  `drop_defaultmanual.sql`, `alter_drop_forcemanual.sql` — run as needed (see file headers).
- vehlib: `client/drivetrain.lua` (gear/transmission primitives), `forces.lua` (torque/rpm),
  `handling.lua` (setHandling/restore), `state.lua` (per-frame snapshot — hk-handling is its
  ONLY consumer), `compat.lua` (jim bridge), `api.lua` (notify/smoothstep), `wheels.lua` (brakeWheel).

## Testing protocol
`restart hk-vehlib` THEN `restart hk-handling`. Stop the legacy gearbox resource first (shares K/J/LSHIFT
binds) if it's still loaded. Run the SQL in `sql/` if the schema changed. Drive a manual car (type 1),
a basic/supercar DCT (2/3), and an F1-DCT (4) to confirm paddle-only. For PHASE 2: `/gearratio 1/2/3`
then RE-ENTER the car, watch F8 for `[hk-gearbox] ratio mode N (...)`. Watch `resmon` for hk-handling ms.

## Keys / commands
- ShiftUp=K, ShiftDown=J, Clutch=LSHIFT (FiveM-rebindable). Clutch is interpreted per mode:
  mode 1 = held clutch; DCT (2/3/4) = edge toggle auto<->paddle (DB `forcePaddle=1` locks to
  paddle, no toggle); seq (5) = mainly downshift clutch.
- `/setgear <type|remove> [forcePaddle 0/1/2]` (admin) — set a MODEL's gearbox TYPE in DB.
  type 0-6 PUBLIC; `remove`/`clear`/`none` deletes the row. forcePaddle: 0 normal / 1 force
  paddle-only / 2 force-auto (DCT only). (The old `force` positional arg was REMOVED with the
  forceManual column.)
- `/gearratio <0-3>` (admin) — set a MODEL's gear-ratio (shift-feel) mode. 0=default 1=sport
  2=drag 3=hypercar. Independent of TYPE; preserves the row's manualType/forcePaddle.
  ⚠ Re-resolved at Enable, so re-enter the vehicle after changing it to feel the change.

## PHASE 2 — GEAR-RATIO MODE (mechanism DONE; numbers in playtest)
Per-model shift-FEEL preset (`hk_handling.gearRatioMode`, 0-3), set by `/gearratio`. NEVER
moves real top speed (`fInitialDriveMaxFlatVel` untouched). Config: `Config.Gearbox.RatioModes`
+ master toggle `RatioUseDriveForce` (default false = pure shift-feel, no power change).
- **Design = B1**: Config is NEVER mutated. `Gearbox_Enable` resolves the per-vehicle profile
  into module-level `gbRatio` (POINTS at `RatioModes[n]`, default [0] no-op). The tick reads
  `baseline * gbRatio.X` at each shift-point. Mode [0] = all-1.0 = byte-identical stock.
- **Knobs** (multipliers, 1.0 = unchanged): `UpshiftRpmMult` (DCT AutoUpRpm/WOT + comfort
  AutoEarlyShiftRpm, clamped under limiter), `DownshiftRpmMult` (DCT AutoDownRpm/Kickdown),
  `ShiftTimeMult` (manual/seq shiftTimeUp/Down at Enable + DCT dctWin/paddleWin in-tick),
  `LowGearTorque` (gears 1-2 torque punch, mode-agnostic), `DriveInertiaMult` (snappier revs,
  composes with seq's own inertia mult), `LadderUpBias` (PROGRESSIVE spread — per-gear additive
  upshift bias, -bias at g1 ramping to +bias at top gear; hypercar "ratios scale up the
  ladder"), `DriveForcePct` (gated on RatioUseDriveForce; baked into `gbDriveForceLive` — the
  value the tick RE-ENGAGES to — so `origins` stays true stock).
- **Mode characters** (current tune): [1] SPORT = harsh startup (low-gear punch + fast revs),
  SMOOTH upshifts (ShiftTimeMult 1.05, not snappy). [2] DRAG = short early gears (low up-point)
  + fast RPM rampup (DriveInertiaMult 1.30) + launch punch. [3] HYPERCAR = LadderUpBias 0.12
  (progressive spread) + near-instant shifts + low-gear punch.
- **FINAL-GEAR RELAXATION**: a high UpshiftRpmMult could push the second-to-last upshift point
  against the rev limiter so the top gear never engages (playtest: hyper "doesn't use last
  gear"). When the upshift target IS the top gear, the hold-longer mult is IGNORED and the
  car's stock up-point is used so the top gear always engages.
- **gbDriveForceLive trap (fixed)**: the tick re-engages drive force to `origins` on every
  shift/neutral-exit; a naive bump baked into the bump-then-restore would be wiped each shift.
  `gbDriveForceLive` holds the live (bumped or stock) value; Disable still restores `origins`.

## MANUAL (mode 1) skill reward/penalty — RE-ENABLED via Config.Gearbox.Manual.*
The top-level `ShiftClutchBoost`/`RevMatchBonus`/`ShiftNoClutchPower`/`RevMatchFailNeutralMs`
were neutralised (1.0/1.0/0.90/0) for the clean RPM baseline test. Re-enabling them top-level
would also affect SEQ (shares `ShiftClutchBoost`), so mode-1 overrides live in
`Config.Gearbox.Manual.*` and the manual branch reads `Manual.X or <top-level>`:
- `ClutchBoost=1.10` (clutched steady boost), `RevMatchBonus=1.08` (clutchless rev-matched
  reward — user: "[1] only 1.08"), `NoClutchPower=0.82` (off-match bog), `NeutralFailMs=250`
  (missed clutchless shift drops to neutral 250ms = the penalty that bites). Speed-invariant:
  the >1.0 bonus is brief + opt-in (must nail a clutchless rev-match).

## DCT AUTO START-IN-NEUTRAL toggle (Config.Gearbox.DctAutoStartInNeutral)
DCT auto sub-mode (modes 2/3/4) starts a freshly-entered car (engine was OFF on entry) in
NEUTRAL and waits for a HANDBRAKE (spacebar) tap before engaging a gear — the "release park"
feel. Toggle gates ONLY that fresh-start branch in the DCT code (`gearbox.lua`, the
`dctLastGear == -99` block): `true` (DEFAULT, current behaviour) = require the spacebar tap;
`false` = fall through and engage a safe gear immediately on entry (just drive off). Does NOT
touch comfort auto [0] (always drives off), manual [1]/seq [5] (pull away on clutch + shift),
the MOVING-entry case (always engages a speed-matched gear), or paddle/manual sub-mode.

## ACCEL MATCH — speed-invariant guard (Config.Gearbox.AccelMatch)
THE MANDATE: change gear FEEL, not acceleration/top speed. But our box shifts smarter than
GTA's native box, so DCT cars netted ~0.3-0.8s faster 0-100 (measured via /accel timer:
Chiron DCT ~2.1s vs native 2.87s) — ALL of it in the ~50-110 km/h bog band (GTA bogs on a
bad upshift, we don't). mode 0 (NEW auto) is already 0.3s SLOWER than native, so untrimmed.
- FIX = a TORQUE-ONLY trim, always <=1.0 so it can NEVER add power (the mandate's forbidden
  direction is locked out by construction). The trim is a smooth TRAPEZOID over ABSOLUTE
  km/h — the bog band is a fixed low-gear phenomenon at real road speed, so absolute km/h
  tracks it on a Chiron and an M3 alike (a top-speed fraction does NOT — it put the peak at
  ~112 km/h on a hypercar, missing the real band). The band (config, in km/h):
  - below `FadeInLoKmh` (48)        -> trim 1.0  (LAUNCH untouched)
  - `FadeInLoKmh`..`FadeInHiKmh` (66) -> smoothstep fade IN (0 -> full depth)
  - `FadeInHiKmh`..`FadeOutLoKmh` (100) -> FULL trim (the bog-band plateau)
  - `FadeOutLoKmh`..`FadeOutHiKmh` (120) -> smoothstep fade OUT (full -> 0)
  - above `FadeOutHiKmh` (120)        -> trim 1.0  (TOP SPEED untouched)
- DEPTH is ONE global knob `CurveDepth` (peak cut at the plateau) — NO per-car tuning (user:
  "i would not want to sell it as per car, insanely tiring"). Tuned once via /accel: on a
  Chiron mode 4, 0.36 -> 2.55s (0.32 fast), 0.58 -> 3.06s (0.19 slow), so CurveDepth=0.50
  lands on native ~2.87s (~2.32s per depth unit). The absolute-km/h band auto-covers other
  cars without retuning. THROTTLE-GATED: only trims when on power (thr>0.5 OR rpm>0.55).
- DCT-only by default (`Modes = {[2]=true,[3]=true,[4]=true]}`); `Enabled=false` => byte-
  identical to no trim. Active-flag `gbAccelTrim` (1/0) resolved ONCE at Enable (no per-frame
  type lookup); the curve math runs in the tick after LowGearTorque. `Debug=true` prints a
  per-frame `[hk-accelmatch]` line (kmh/thr/rpm/w/trim/torqueMult) — turn OFF once tuned.

## /accel — 0-100 acceleration timer (client/acceltimer.lua)
Self-contained (works in any mode incl. /setgear 6 native, doesn't need the gearbox active).
`/accel` arms it; come to a full stop, floor it; prints 0-60/100/160/200 splits to F8 + screen.
Use it to verify the speed-invariant aim: compare a mode vs `/setgear 6` (native) on the SAME car.

## Next: geartype / DCT updates
When adding/altering a tier: update `autoMode`, the DCT branch gate, the gear-pin gate,
`DctProfiles[mode]`, `ModeLabels[mode]`, and the server type clamp together. Consider making
`autoMode` profile-driven (`DctProfiles[gearMode] and not P.PaddleOnly`) so new tiers need
fewer edits. Any new hot-path vehlib call -> add to that file's `vl_*` cache block.

# ============================================================================
# SESSION ADDENDUM (2026-06-13) — muscle handbrake guard + per-model speed calibration
# ============================================================================
> Everything below was built AFTER the sections above. Where the old "WHEELIE/HANDBRAKE
> BUG GUARD [F3]" note describes a FOOT-BRAKE co-apply, that approach was ABANDONED — read
> this addendum, not that note, for the live behaviour. CODE still wins over both.

## 1. MUSCLE HANDBRAKE "180-SNAP" GUARD — FINAL = throttle-gated suspend (NOT braking)
ROOT CAUSE (re-diagnosed, correct this time): the snap is NOT a missing brake. It is the
gearbox FORCE-WRITING engine state (`SetVehicleCurrentRpm`/`SetVehicleCurrentGear` +
`SetVehicleTransmissionReducedGearRatio`) during the fragile handbrake+nose-up physics frame.
Native mode [6] never writes any of that, so `/setgear 6` is immune — proven in-game. Same
bug existed in the old `vlad_gears` script, same reason. The muscle handling.meta carries
`strAdvancedFlags 402` (the real trigger flag); the codebase chose NOT to edit handling.meta
— it suspends the writes from the script side instead.

THE FIX (client/gearbox.lua, top of `Gearbox_Tick`, runs BEFORE the early-return): when a
class-4 (Muscle) car is in gear 1/2 with the HANDBRAKE held and the player is OFF the gas,
the box mimics native [6] for those frames; back on the gas, it resumes. Pure detection — no
timers, no power scaling, no mass tricks. The earlier timer-cap / power-scale / nose-pitch
attempts were all dropped in favour of this.
- Two suspend layers, both flipped together by `gbSuspended`:
  1. `engineWritesSuspended` → `vl_setCurrentGear` / `vl_setRpmRaw` become no-ops (the raw
     `*_raw` variants are wrapped at gearbox.lua ~63-71, so ALL ~30 call sites are caught at
     once — never write per-frame engine state again without going through these).
  2. on suspend entry, `vl_setTransmissionReducedGearRatio(veh, false)` (the thing [6] also
     never sets); on resume, `muscleGuardReassertTransmission(veh)` re-enables it for non-auto
     modes / clears `dctStarted` for DCT.
- After the guard: `if gbSuspended then return end` (skips the whole tick = true [6] mimicry).
- GATES (`Config.WheelieGuard`): `Enabled=true`, `OnlyMuscle=true` (state.class==4 only — user
  100% confirmed only Muscle hits it), `MaxGear=2`. Throttle hysteresis: suspend when
  `thr <= ThrottleOff(0.15)`, resume when `thr >= ThrottleOn(0.35)` or handbrake released.
  `RequireNoseUp=false` (handbrake+throttle is enough; NoseUpPitch=3.0 kept as an optional
  extra gate). WHY throttle-gated: you only grab the handbrake off-throttle, drag launches are
  full-throttle (untouched), and spamming the handbrake while off-gas just stays native = immune.
- `client/wheelieguard.lua` still exists but is a LEGACY brake-plant fallback, default OFF
  (`Config.WheelieGuard.BrakePlant=false`). It uses `SetVehicleWheelBrakePressure` (the
  `SetControlNormal(0,72)` brake never engaged — the input reader overrode control 72). Only
  fires if BrakePlant is flipped true. The real fix is the gearbox suspend above.
- Reset path: `Gearbox_Disable`/reset clears `gbSpeedCal`, `engineWritesSuspended`.
- All `luac -p` clean.

## 2. PER-MODEL SPEED CALIBRATION — packed-int torque curve (pure torque, no bog risk)
GOAL: make in-game 0-60/100/160/top match real-life figures per car, WITHOUT touching rpm or
gear ratios (those cause the bog/wheelie bug). Mechanism = a per-band ENGINE TORQUE multiplier.
- **Encoding (`speedCalC` BIGINT, gearbox.lua ~80-108):** leading "1" sentinel
  (`SPC_SENTINEL = 1e16`) + 4 groups of 4 digits, each = factor×100. e.g. {0.90,1.16,1.00,1.00}
  → `10090011601000100`. The sentinel preserves leading zeros. It is NOT a hash and NOT rpm —
  it is four torque multipliers, one per speed band. `HK.speedCalPack`/`HK.speedCalUnpack`
  exported for autocal.lua.
- **Bands** (`Config.Gearbox.SpeedCal.Bands = {60,100,160,1e9}`): 0-60 / 60-100 / 100-160 / 160+.
  Aligned to the /accel splits AND to the GPT data fields. `BlendKmh=6.0` linear-blends across
  edges so no torque step. Clamps `FactorMin=0.40 .. FactorMax=1.40` (real cars are often FAR
  slower than GTA arcade, so deep cuts to ~0.45 are needed).
- **Application** (gearbox.lua ~980, in the tick after LowGearTorque): `if gbSpeedCal and
  throttle > 0.5 then HK.torqueMult *= speedCalFactorAt(gbSpeedCal, speedKmh)`. Throttle-gated,
  band-blended, torque-only → can never bog or wheelie.
- **Resolve** in `Gearbox_Enable`: unpacks `m.speedCalC` into module-level `gbSpeedCal` BEFORE
  the AccelMatch block. AccelMatch is then gated `if not gbSpeedCal then ...` — a car WITH a
  speed calibration turns AccelMatch OFF (the calibration supersedes it).
- **syncModels live-refresh**: for the already-applied current car, re-unpacks `gbSpeedCal` so
  /accelcal & auto-cal changes apply without re-entering the vehicle.

## 3. NEUTRAL-SEED reframe (KEY architectural decision — supersedes the open-loop formula)
The original idea was an open-loop FORMULA computing the factor from target time. It was DELETED
(`speedCalEstNativeTime`/`speedCalCompute` gone, comment left in place) — a deterministic formula
can't self-converge (same input → same output; it pushed chiron/adr8 the WRONG way, too fast).
NEW baseline = TRUST THE TUNER'S handling.meta:
- `/setspeed` stores ONLY the TARGET (`speedCal` raw), with factor `speedCalC = NULL`.
- NULL speedCalC = factor 1.00 = native [6] / handling.meta behaviour UNTOUCHED = safest seed
  (never worse than the hand-tuned car).
- The script then LEARNS the residual on top via measurement (auto-cal / /accelcal).
- Server `setSpeedModel`: the two columns are INDEPENDENT — `speedCal` (raw target, kept for
  re-editing) and `speedCalC` (learned packed factor). `packedCal<=0` or no target → `packedCal=nil`.

## 4. CALIBRATION — ONE-SHOT FROM NEUTRAL (/accelcal + auto-cal)  [REWRITTEN 2026-06-13]
> SUPERSEDES the old "measured feedback multiply" design, which RAN AWAY: it measured the
> car WITH the factor already applied, then multiplied the factor by measured/target again —
> the sensor read its own actuator, so it compounded and drifted granvia to the 0.40 floor
> (4x too slow). The fix is open-loop-FROM-MEASUREMENT: measure at NEUTRAL, compute once, lock.
- Model: the 4 packed slots are PER-GEAR factors (gear 1/2/3/4+). Because time ∝ 1/torque,
  `factor[gear] = neutralSegmentTime / targetSegmentTime` lands the target in ONE pull. No loop.
- **/accelcal** (admin → `accelcalRun`): does NOT read a prior /accel. It SUSPENDS the factor
  for the current model (`HK.speedCalSuspend(true)` → tick gate `not gbSpeedCalSuspend`), arms
  the timer in BASELINE mode (`HK.accelArmBaseline`), you floor it once from a stop. On completion
  the timer calls `HK.accelcalOnBaseline(gearSeg)` which computes via `speedCalComputeFromNeutral`
  (per-gear neutral/target, clamped FactorMin..Max, a gear within `ConvergeTolSec`=0.40s left at
  1.00), stores via `setSpeedModel`, and re-enables the factor. A 90s watchdog
  (`AccelCalArmTimeoutMs`) restores the factor if the pull is never completed.
- **client/autocal.lua** (passive): ONLY arms for a model with a target but NO factor yet
  (`m.speedCal and not m.speedCalC` = still neutral) — so the pull it watches IS a clean baseline.
  Computes the one-shot factor via the SAME `HK.speedCalComputeFromNeutral` and LOCKS it; a model
  that already has a factor is never captured again. No nudging, no feedback. `isStock(veh)` (mods
  11/12/13 + turbo 18), aborts on handbrake/brake/steer/airborne/collision/throttle-drop.
  `Config.Gearbox.SpeedCal.AutoCal`: `Enabled, RequireStock=true, StartKmh=2.0, MinThrottle=0.90,
  MaxSteer=0.35, ConvergeTolSec=0.40, MinRunGapMs=1500`. (Old Gain/Step/Deadband knobs DELETED.)
- The timer (acceltimer.lua) gained a `baseline` flag + `HK.accelArmBaseline`/`HK.accelCancel`
  hooks; a baseline run also completes on LIFT/top-out (slow cars never reach 200 km/h).
- RESET NOTE: clearing a runaway factor = `UPDATE hk_handling SET speedCalC=NULL WHERE ...`. Done
  2026-06-13 for granvia (was 0.40^4) + adr8; both relearn cleanly on the next baseline pull.

## 5. /accel result persistence + delta (client/acceltimer.lua)
Fixed: results used to vanish when /accel disarmed. Now sleep=0 whenever `armed or lastShown`,
drawn every frame, with a +/- delta column vs the previous run (green=faster, red=slower).
On run complete it publishes `HK.lastAccelSplits` (km/h→seconds) for /accelcal to consume.

## 6. AccelMatch CurveDepth lowered 0.50 → 0.28
DCT/automatic was too slow at 2nd gear — traced to AccelMatch OVER-trimming. `CurveDepth`
lowered to 0.28 (was 0.50). (NOTE: AccelMatch stays ON as part of the baseline for NON-calibrated
cars; a car with a speedCalC calibration disables AccelMatch entirely — see §2.)

## 7. Car-spec data pipeline (real-life figures for the targets)
- **client/speedcaldata.lua** (auto-generated): `HK.SpeedCalData` — 124 cars, real names + years
  pulled from qb-core `shared/vehicles.lua` + vehicle.meta. Current fields from the Grok pass:
  `n` (name), `k100`, `k160`, `top`. 4 cars excluded (ikx3_bat23, galaxyroamer, devel22, lavn).
- **/setspeedbulk** (server admin → client `bulkStart`): INSTANT — no spawning, just writes every
  HK.SpeedCalData target with factor nil (neutral seed). User confirmed: "124 ok, 0 skipped".
- **GPT re-query (IN FLIGHT):** Grok's 0-160 figures were physically inconsistent (chiron 0-160
  in 8.9s when it should be ~4.3). Switched to GPT. `listallcarspeed_gpt.txt` = v2 prompt, 128
  cars, 7 km/h-only fields `spawncode | real_name | t60 | t100 | t160 | t200 | topspeed`, with
  built-in consistency rules (monotonic t60<t100<t160<t200; t160 ≈ 1.7-2.4× t100; t200 ≈
  2.6-3.6× t100; topspeed ≥ last split; self-check instruction). WAITING on the user to send it
  to GPT and paste results back.
- **TODO when GPT data returns:** parse the 7-field reply → regenerate `client/speedcaldata.lua`
  (the generator currently expects the OLD format — UPDATE the parser for t60/t200/topspeed) →
  run a validation pass flagging any line that still breaks monotonic/gap rules → re-run
  /setspeedbulk to refresh targets.

## DB migration (REQUIRED for §2-§7)
`sql/add_speedcal.sql`:
`ALTER TABLE hk_handling ADD COLUMN speedCal VARCHAR(128) DEFAULT NULL,
 ADD COLUMN speedCalC BIGINT DEFAULT NULL;`
(User's successful /setspeedbulk implies this is already applied. Re-run on any fresh DB.)

## fxmanifest order (addendum modules)
client_scripts: `client/wheelieguard.lua`, then `client/speedcaldata.lua` (BEFORE gearbox),
`client/gearbox.lua`, then `client/autocal.lua` (AFTER gearbox — it uses HK.speedCalPack/Unpack).

## Commands added this session (all admin-gated, server/gearbox.lua)
- `/setspeed <kmh> <time>` — calibrate the CURRENT car's target for one band (stores target only,
  neutral seed). Accepts xx.xx / xx.x / x.x / x time formats. Pure torque — never rpm/gear.
- `/setspeedbulk` — apply all HK.SpeedCalData targets at once (instant, neutral seed).
- `/accelcal` — measured feedback: after an /accel run, correct the factor by measured/target.

## Addendum testing protocol
`restart hk-vehlib` THEN `restart hk-handling`. Verify: (a) a class-4 Muscle car in 1st/2nd —
grab handbrake OFF the gas, no 180-snap; back on gas, box resumes; full-throttle drag launch
untouched. (b) `/setspeed` a car, `/accel` it, `/accelcal`, repeat → time converges on target.
(c) drive a stock car hard from a stop → auto-cal F8 line should log a clean capture. All Lua
`luac -p` clean.
