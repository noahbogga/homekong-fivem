# hk-handling :: Migration + Relabel + Gear-Ratio-Mode — MASTER PLAN

> **READ THIS FIRST after any context reset.** This is the single source of truth for
> the in-progress work. It captures the full intent so the token window getting wiped
> does NOT lose the thread. Update the STATUS box as steps complete.

---

## ★ STATUS (update as we go) ★
- [x] PHASE 0  — questions answered. DECISIONS LOCKED (see below).
- [x] PHASE 1  — new `hk_handling` table + mode relabel/remap + resolution flip. DONE:
      * sql/hk_handling.sql (new table), sql/migrate_to_hk_handling.sql (old->new remap,
        keeps defaultManual for rollback).
      * server/gearbox.lua rewritten: loads hk_handling, /setgear uses public 0-6 +
        'remove' keyword, forcePaddle column, gearRatioMode carried, seedModel net event.
      * config.lua: ModeLabels -> public scheme; added Gearbox.CarClasses set.
      * client/gearbox.lua: PUBLIC_TO_INTERNAL map + resolvePublicType/shouldProcess/
        detectMode rewrite (internal numbers FROZEN), isCarClass default-on, maybeSeedModel
        (admin seed-on-sit, hash+spawn only — no name read), sync carries ratio.
      * ALL PARSE OK (config + client + server).
      * TODO IN-GAME: run migrate SQL, restart hk-handling, verify remap on a test car,
        then DROP defaultManual. jim has NO effect this phase (expected).
- [ ] PHASE 1.5 — jim-upgrade TYPE remap (DEFERRED by user: "we will do this later after we fully migrate")
- [~] PHASE 2  — gear-ratio-mode (0 default / 1 sport / 2 drag / 3 hyper). IN PROGRESS:
      * [x] 2A — config.lua: `RatioUseDriveForce` master toggle + `RatioModes` profile
            table (0-3), mode-agnostic MULTIPLIER knobs (UpshiftRpmMult / DownshiftRpmMult
            / ShiftTimeMult / LowGearTorque / DriveForcePct). PLACEHOLDER conservative
            numbers; mode [0] = pure no-op. Inserted after RatioSeed block. PARSE OK.
      * [x] 2B — server/gearbox.lua: `/gearratio [0-3]` command mirroring /setgear.
            Done: USAGE_RATIO + RegisterCommand('gearratio') validates vs RatioModes,
            requestRatioModel client roundtrip (name read only on this admin action,
            mirror of /setgear), setRatioModel server event writes gearRatioMode and
            PRESERVES existing manualType/forcePaddle (creates default row if none).
            PARSE OK (server + client).
      * [x] 2C — client/gearbox.lua: apply ratio profile in Gearbox_Enable (modulate
            shift points; NEVER touch maxFlatVel / real top speed). DONE (B1 design —
            Config never mutated, gbRatio just POINTS at the profile, tick reads
            baseline * gbRatio.X). Applied at:
              - shiftTimeUp/Down *= ShiftTimeMult (Enable, manual/seq) + dctWin/paddleWin
                *= ShiftTimeMult (tick, DCT), floored so a shift stays perceptible.
              - DCT auto upRpm *= UpshiftRpmMult (clamped under limiter); downRpm/kickRpm
                *= DownshiftRpmMult. Comfort AutoEarlyShiftRpm *= UpshiftRpmMult (clamped).
              - LowGearTorque: torqueMult punch in gears 1-2 under throttle (mode-agnostic,
                before mode branches; neutral/shift =0.0 overrides unaffected).
              - DriveForcePct (gated on RatioUseDriveForce): baked into gbDriveForceLive,
                the value the tick RE-ENGAGES to. `origins` stays true stock so Disable
                restores cleanly + the ratio bump is never baked into the snapshot.
                (Fixed the trap where tick re-engage to origins would wipe the bump.)
            gbRatio/gbDriveForceLive reset in state-reset; Debug print of resolved mode.
            mode [0] = all-1.0 no-op = byte-identical stock. PARSE OK (all 3 files).
      * [~] 2D — in-game playtest + fill aggressive numbers. ITERATION 1 (from playtest):
            - DRAG: shorter early gears -> UpshiftRpmMult 0.90->0.84, LowGearTorque 1.12->1.20.
            - SPORT: "didn't feel much" -> Up 1.05->1.12, Down 1.10->1.22, ShiftTime 0.90->0.80.
            - HYPER: revs faster early -> added DriveInertiaMult (new ratio knob) 1.12; eased
              UpshiftRpmMult 1.08->1.06; FINAL-GEAR RELAXATION fixes "doesn't use last gear"
              (top-gear upshift ignores the hold-longer mult, uses stock up-point).
            - NEW knob DriveInertiaMult on all ratio modes (snappier revs, composes w/ seq).
            - MANUAL (mode 1) skill reward/penalty RE-ENABLED via Config.Gearbox.Manual.*
              (was baseline-neutralised): ClutchBoost 1.10, RevMatchBonus 1.08 (user "[1] only
              1.08"), NoClutchPower 0.82, NeutralFailMs 250. Mode-1-only (seq shares the
              top-level ShiftClutchBoost, so overrides live in the Manual namespace).
            PARSE OK (all 3). AWAITING playtest iteration 2.
      * [~] 2D ITERATION 2 (playtest):
            - SPEED REGRESSION (every car ~0.3-0.6s faster than .meta): root cause = near-
              seamless shift dips made script shifts cost almost no time. FIX = deepen dips
              (speed-invariant, power-only, independent of shift duration): comfort
              AutoShiftDipPower 0.92->0.80; DCT[3] 0.9->0.82; DCT[4] 0.97->0.90; DCT[5]
              0.995->0.96. (Manual/seq already full-cut to 0.0, not implicated.)
            - basic [0] comfort shifted too slow -> AutoShiftRateMult 0.63->0.731 (+16% rate).
            - basic DCT[3] shifted too slow -> window -22% (ShiftDipMs/Min/Max + PaddleShiftMs).
            - type 6 (GTA native): /gearratio now REJECTS it server-side (box never runs to
              apply ratio anyway — Enable early-returns before gbRatio resolves; guard is
              defense-in-depth + clear admin message).
            PARSE OK (all 3). AWAITING playtest iteration 3.
      * [~] 2D ITERATION 3 — new mode characters + gear-type RENAME (labels only):
            - RENAME (ModeLabels + DctProfiles[].Label + server USAGE; NO renumber, NO DB/logic
              change): 0=NEW automatic, 1=Classic H pattern Manual, 2=Automatic (Paddle), 3=Sport DCT
              (was SUPERCAR), 4=Super DCT (was F1-DCT), 5=Sequential Dogbox, 6=GTA Native.
            - [1] SPORT = harsh startup + SMOOTH upshifts: LowGearTorque 1.18, DriveInertiaMult
              1.12, but ShiftTimeMult 1.05 (smooth, NOT snappy), DownshiftRpmMult 1.12 mild.
            - [2] DRAG = short early gears + fast RPM rampup: UpshiftRpmMult 0.82 (short-shift),
              DriveInertiaMult 1.30 (fast rampup), LowGearTorque 1.22.
            - [3] HYPERCAR = ratios scale up the ladder: NEW knob LadderUpBias 0.12 (per-gear
              additive upshift bias, -bias g1 -> +bias top gear = progressive spread).
              UpshiftRpmMult eased to 1.0 so ladder bias dominates. ShiftTimeMult 0.70.
            - NEW client logic: LadderUpBias ramp in DCT upshift (clamped under limiter, floor
              0.30); debug print extended (inertia + ladder).
            PARSE OK (all 3). AWAITING playtest iteration 4.
      * [~] 2D ITERATION 4 — ACCEL MATCH (speed-invariant guard). Playtest (timer): DCT
            netted ~0.8s FASTER 0-100 than GTA-native (Chiron 2.1 vs 2.9; M3 3.3 vs 4.1),
            ALL of it in the 60-110 km/h band (our box doesn't bog on the upshift GTA bogs
            on). mode 0 was already 0.3s SLOWER than native (fine). Violates the mandate
            (change feel, not accel). FIX = Config.Gearbox.AccelMatch: torque-only trim,
            always <=1.0 (can't add power by construction), faded by a SPEED WINDOW as a
            FRACTION of the car's own top speed (auto-adapts, zero per-car tuning): 1.0
            below WinLoFrac (launch safe), -> gbAccelTrim by WinPeakFrac, -> 1.0 by
            WinHiFrac (top speed safe). DEPTH auto-scales from stock fInitialDriveForce
            (punchier car = deeper), resolved ONCE at Enable (no tick推算, no shift-logic
            touch), indicator clamped 0..1, trim floored at MaxCut. DCT-only by default
            (AccelMatch.Modes={2,3,4}). 3 safety clamps per "safe to sell" requirement.
            client: gbAccelTrim resolved in Enable, applied in tick after LowGearTorque.
            PARSE OK (all 3). NEEDS timer re-test to tune MaxCut/MinCut/window fracs to
            land 0-100 back near native.
      * [~] 2D ITERATION 5 — AccelMatch REWRITE (iteration 4 barely fired: Chiron mode 3
            2.1->2.2 only). TWO bugs found via timer: (a) top-speed-FRACTION window put the
            peak at ~112 km/h on a hypercar, missing the real 60-100 bog band; (b) depth
            from fInitialDriveForce collapsed to ~0 (all cars ~0.2-0.35 force). FIX = the
            curve the user asked for: smooth TRAPEZOID over ABSOLUTE km/h + single depth
            knob. Config: FadeInLoKmh 48 / FadeInHiKmh 66 / FadeOutLoKmh 102 / FadeOutHiKmh
            150, CurveDepth 0.36 (-36% torque at the plateau; Chiron 60-100 needed ~1.9x
            slower). smoothstep edges. gbAccelTrim is now just an ACTIVE flag (type in
            Modes); depth+band in tick. Still torque-only <=1.0 (can't add power), launch
            (<48) + top speed (>150) untouched. PARSE OK. NEEDS timer re-test: tune
            CurveDepth to land 0-100 on native, adjust band edges if 0-60 moves.
- Conversational replies to the user: **HK Cantonese**. Docs/readmes in zh: **standard
  written Traditional Chinese** (NOT Cantonese vernacular). This planning doc: English.

## ★ LOCKED DECISIONS (PHASE 0/1) ★
1. **No DB row → OUR automatic [0]** (internal comfort-auto), but ONLY for CAR CLASSES
   (Compacts/Sedans/SUVs/Coupes/Muscle/SportsClassic/Sports/Super/Offroad/Vans/OpenWheel).
   Non-cars (moto/cycle/boat/heli/plane/train) stay raw GTA native. Fallback is the LAW:
   the script must NEVER depend on a row existing.
2. **Seed-on-sit (admin only):** when an ADMIN sits in a CAR-class vehicle with no row,
   auto-upsert a DEFAULT row (manualType=0, force=0, forcePaddle=0, gearRatioMode=0 —
   behaves identically to no-row). Deduped per-model per-session. Makes the table
   browsable/editable without changing behaviour. Admin-gated (no player-driven writes).
3. **jim has NO effect this phase** on no-row cars (manual upgrade no longer forces manual;
   car-class no-row already runs our-auto). The standalone jim / isManualVehicle triggers
   are REMOVED from processing-resolution this phase. Restored/remapped in PHASE 1.5.
4. **6-column table** (no extra reserved columns now — ALTER ADD COLUMN later is one line,
   repo already does it in addPaddleOnly.sql, so NO re-migration fear).
5. **Internal engine numbers are FROZEN.** DB/commands/labels/docs use the NEW public
   numbering; ONE translation table converts public→internal at the resolver. Blast radius
   = resolver + SQL/label layer only; the ~15 tuned gearMode branches are untouched.
6. **Enhanced jim tiers** (+1.5%/+3% speed, faster shift) = DEFERRED to PHASE 1.5.

## ★ NUMBER MAPS (authoritative) ★
PUBLIC (new) -> INTERNAL (frozen engine var `gearMode`):
  new 0 our-auto   -> internal 2 (comfort auto)
  new 1 manual     -> internal 1
  new 2 basic DCT  -> internal 3
  new 3 supercar    -> internal 4
  new 4 F1/hyper    -> internal 5
  new 5 sequential -> internal 6
  new 6 GTA-native -> nil (DO NOT PROCESS)

OLD DB value -> NEW public (migration remap):
  old 1 manual    -> new 1
  old 2 comfort   -> new 0
  old 3 DCT       -> new 2
  old 4 supercar  -> new 3
  old 5 F1        -> new 4
  old 6 seq       -> new 5
  (old 0 = no row, doesn't exist)


---

## WHY WE'RE HERE
Earlier work tried to make cars feel right by tinkering with RPM. Dead end: GTA's rpm is
emergent 0..1 (idle floor 0.200, gear-2+ ceiling ~0.985) and there is NO native to set a
redline or individual gear ratios. The user correctly redirected to **gear-ratio
STRATEGY** (shift points / hold / short-shift / spacing feel), which is far more "felt"
and is the real-life lever between Default/Sport/Drag/Hypercar.

We are ALSO migrating to a new consolidated SQL table and renumbering the gearbox modes
at the same time, because we're touching the DB layer anyway. **Order locked by user:**
do the SQL migration + relabel FIRST, then build gear-ratio-mode.

---

## HARD TECHNICAL CONSTRAINTS (do not forget these)
- **GTA cannot set individual gear ratios.** Grok's literal ratio strings (3.91/2.29/…)
  cannot be written to the physics engine. The only real levers are:
  - `fInitialDriveMaxFlatVel` — overall gearing length / top speed (shorter = lower number
    = faster accel, lower top speed).
  - `fInitialDriveForce` — low-end torque/force.
  - **Our own Lua sim** — shift points, hold-to-redline, short-shift, downshift aggression.
- **All handling writes are IN-MEMORY only** (`vl_setHandling` -> `SetVehicleHandlingFloat`
  on the live vehicle, with capture/restore). handling.meta file is NEVER written.
- **Ratio seed law (already in code):** `rpmPerKmh[g] = nativeRatio[g] / (K * maxFlatVel)`,
  K = 1.199. maxFlatVel is captured in `origins` and is the natural ANCHOR for shift-point
  math. `seedGearRatios()` @ client/gearbox.lua ~282; `projectRpmFor()` ~178.
- **Never read the vehicle NAME at runtime** (reading display name errors sometimes). Match
  ONLY on model (spawn id) and/or hash. `name` column is cosmetic/readability only.
- Parse-check after every edit: `luac -p config.lua && luac -p client/gearbox.lua`.

---

## CURRENT STATE (before migration) — so we know what we're changing FROM
- Table: **`defaultManual`** (sql/defaultManual.sql). Columns: id, model, hash (UNSIGNED
  32-bit, the ONLY match key), name (cosmetic), manualType TINYINT, forceManual TINYINT,
  paddleOnly TINYINT. UNIQUE KEY on hash.
- **Current manualType meaning:** 0 = auto/off (no row / unprocessed / GTA native),
  1 = manual+clutch, 2 = comfort auto, 3 = DCT, 4 = supercar DCT, 5 = F1-DCT, 6 = sequential.
- **forceManual:** 0 = apply manualType only if jim manual upgrade installed; 1 = always.
- **paddleOnly (DCT only, 3/4/5):** 0 = normal (auto + paddle), 1 = force paddle-only,
  **2 = force-AUTO (locked auto, paddles inert)** — ALREADY IMPLEMENTED.
- Server: `server/gearbox.lua` — loadManualModels(), pushModels(), /setgear command,
  setModel net event, getModelGearbox export. Pushes a hash->{type,paddle,ratio} map to
  clients; clients match by GetEntityModel. NO per-vehicle DB hits.
- Client mode resolution: `shouldProcess()` ~325, `detectMode()` ~340 (returns m.type if
  force==1 OR jim upgrade present). `ModeLabels` in config.lua ~524. DCT profiles
  config.lua ~826 ([3]/[4]/[5]). Sequential = mode 6.
- `getDisplayGear()` export is MODE-AWARE (~2007): mode 1/6 read seq/manual gear, 3/4/5
  read dctGear, mode 2 returns nil (GTA native).

---

## TARGET — new mode numbering (user's spec)
| New | Meaning                                              | Maps from old |
|-----|------------------------------------------------------|---------------|
| 0   | **OUR Automatic** (the old mode-2 comfort auto, now the DEFAULT; OVERRIDES GTA native) | old 2 |
| 1   | Classic manual gearbox + clutch                      | old 1 (same)  |
| 2   | **Automatic (Paddle)** — torque-converter auto + paddle (was "Basic DCT"; runs on internal DCT engine, TC feel) | old 3 |
| 3   | Supercar DCT                                          | old 4         |
| 4   | Hypercar / F1 DCT                                     | old 5         |
| 5   | Sequential gearbox manual (dog box)                  | old 6         |
| 6   | **GTA-native automatic — DEBUG ONLY** (no processing, no upgrade path) | (new; old 0's "native" role) |

> ⚠️ **THE [0] FLIP IS THE DANGEROUS PART.** Old [0] = "do nothing, GTA native". New [0] =
> "our automatic, overrides GTA". And old "do nothing" moves to new [6]. Every existing DB
> row's manualType must be remapped: **2→0, 1→1, 3→2, 4→3, 5→4, 6→5**, and any car that
> should stay raw-GTA becomes **6**. Rows with old type 0 don't exist (type 0 = no row).
> Decide whether "no row" now means new-[0] (our auto, default-on for ALL cars) or stays
> untouched native. (See OPEN QUESTIONS — "default-on scope".)

### "OUR automatic overrides GTA" requirement
User: *"we want OUR automatic to OVERRIDE the default gta automatic."* So new mode [0] is
the baseline for (potentially) every car — our comfort-auto logic runs instead of GTA's
box. New mode [6] is the ONLY way to get raw GTA native, and it's explicitly debug-only
with no jim-upgrade path.

---

## JIM-MECHANIC UPGRADE REMAP (new mode numbers)
When jim's gearbox upgrade is installed, the gearbox TYPE advances per this table:
| Base (new #)        | Upgraded to (new #) | Upgrade character |
|---------------------|---------------------|-------------------|
| [0] our automatic   | [2] basic DCT       | jim manual upgrade |
| [1] classic manual  | [5] sequential dog box | — |
| [2] basic DCT       | [3] supercar DCT    | — |
| [3] supercar DCT    | [3] supercar DCT **+1.5% speed + faster shift** (must stay BELOW [4] F1) | bonus+penalty tier |
| [4] F1 DCT          | [4] F1 DCT **+3% speed + 6% faster shift** (Drag focus, low-gear short rpm time, NO AUTO, F1 clutch-on-pedal) | bonus+penalty tier |
| [5] sequential      | [4] F1 DCT **+3% speed + 6% faster shift** (same Drag-focus F1+ tier as above) | bonus+penalty tier |
| [6] GTA native      | [6] GTA native (NO upgrade ability)                | locked |

> NOTE: [3]+ and [5]+ both land on an "F1+" enhanced tier; [3]'s own upgrade is a milder
> "supercar+" that must stay below F1. These "+x% speed / +y% faster shift" enhanced tiers
> are NEW behaviour to design — likely a flag/sub-type, not a brand-new mode number. Park
> the exact mechanism for PHASE 1 detail; don't invent it before confirming with user.

---

## FORCE PADDLE (confirm — mostly already built)
- forcePaddle [1] = ALWAYS force paddle  — EXISTS (paddleOnly=1).
- forcePaddle [2] = NEVER paddle, ALWAYS automatic in the special group (limits non-DCT
  modes off this always-auto group) — EXISTS as paddleOnly=2 (force-auto). VERIFY its
  behaviour matches "limits non-DCT modes off this always-automatic group" — current code
  only honours paddle flag on DCT modes (3/4/5 old numbers). May need to extend the
  force-auto lock to apply across the intended group under new numbering.

---

## NEW TABLE: `hk_handling`
User wants ONE table holding everything that presets a vehicle for this script. Proposed
columns (CONFIRM before creating):
- `id` INT AUTO_INCREMENT PK
- `model` VARCHAR — spawn id (e.g. 'rx7'). Match key (with hash). Cosmetic-safe.
- `hash` INT UNSIGNED, UNIQUE — primary runtime match key.
- `name` VARCHAR — display name, COSMETIC ONLY, **never read at runtime**.
- `manualType` TINYINT — new numbering 0..6 (default 0 = our auto).
- `forcePaddle` TINYINT — 0 normal / 1 always-paddle / 2 never-paddle-always-auto
  (rename of paddleOnly to match user's "force paddle" wording).
- `gearRatioMode` TINYINT — 0 default / 1 sport / 2 drag / 3 hypercar. **admin preset per
  model, stored in SQL** (user chose admin-preset, NOT player live-toggle).
- (reserved/optional) columns for future presets — confirm what else goes here so we don't
  re-migrate (user wants "everything that presets a vehicle" in this one table).

Migration SQL must: CREATE hk_handling, COPY rows from defaultManual with manualType
remapped (2→0,1→1,3→2,4→3,5→4,6→5), paddleOnly→forcePaddle, gearRatioMode default 0. Keep
defaultManual intact until verified (don't drop). Provide a rollback note.

---

## PHASE 2 — GEAR-RATIO-MODE (after migration)
User decisions locked:
- **Baseline anchor:** decision "2" = use car stock top speed via `fInitialDriveMaxFlatVel`,
  each mode applies a MULTIPLIER (gear-count independent, scales to 7/8/9-speed cars).
  PLUS a config-side switch to allow "maxFlatVel only (must)" OR "maxFlatVel + driveForce".
  → User said: *"is this needed? ask me about it again after more info."* → **RE-ASK** once
  PHASE 1 is done and we know the feel. Default assumption: maxFlatVel-only first.
- **Intensity:** *"只改手感(不動極速)"* = **change SHIFT FEEL ONLY, do NOT move real top
  speed.** So gear-ratio-mode primarily retunes shift points / hold / short-shift /
  downshift aggression in our Lua sim — NOT maxFlatVel after all (or only a whisker).
  ⚠ This is in slight tension with "anchor on maxFlatVel": resolve by treating maxFlatVel
  as the MATH anchor for shift-point % targets, while NOT actually changing the car's real
  top speed value. i.e. compute shift RPM/speed targets relative to stock top speed, but
  leave fInitialDriveMaxFlatVel itself (mostly) alone.
- **Scope:** admin preset per model, stored in SQL (`gearRatioMode` column).
- Command: `/gearratio [0,1,2,3]` (0 default, 1 sport, 2 drag, 3 hyper). Mirror the
  /setgear admin pattern (perm check, request model from client, write DB, push map).

### Mode characters (from Grok real-life review — implement as FEEL, not literal ratios)
- **0 Default:** early/lazy upshifts, holds tall gears, relaxed. Stock-like.
- **1 Sport:** hold gears longer (upshift near redline), aggressive proactive downshifts,
  feels "shorter" by staying in lower gears. Close mid-range.
- **2 Drag:** very short effective low gears (strong 1st/2nd launch pull, short rpm time in
  low gears), early upshifts up top, narrow spread, high wheelspin character. Top-speed
  feel limited (but we are NOT actually lowering real top speed — feel only).
- **3 Hypercar:** short low gears + long high gears (wide spread), MANY-gear feel, extremely
  fast shifts with near-zero power interruption, "never runs out of gears" up top.

### Real-life reference ratios (FEEL guidance only — DO NOT write literally to engine)
- Sport (911 GTS PDK): 3.91/2.29/1.58/1.18/0.94/0.79/0.68, final 3.09 — same physical
  ratios as normal, just holds longer + downshifts harder.
- Drag (Mustang/Camaro): 1st ~2.97-3.27, 2nd ~1.78-1.90, …, final 4.10-4.56 (very high).
- Hypercar (Jesko LST 9sp): 4.72/3.64/2.87/2.25/1.74/1.37/1.08/0.83/0.66, final ~3.5-4.0.

---

## OPEN QUESTIONS (PENDING — ask user before/at relevant phase)
1. **default-on scope:** does new [0] (our auto) apply to EVERY car by default (cars with no
   DB row), or only cars that have a row? "Override GTA automatic" suggests all cars, but
   that's a big behavioural change (every vehicle on the server starts running our box).
   ⚠ ASK before flipping.
2. **enhanced "+x% speed / +y% faster shift" tiers** ([3]+ supercar+, [4]/[5]+ F1+): new
   mode numbers, or a sub-flag on existing modes? Confirm mechanism before building.
3. **hk_handling extra columns:** what else "presets a vehicle" that should live here now so
   we don't re-migrate later? (drift defaults? per-car torque? confirm scope.)
4. **gear-ratio config switch** (maxFlatVel-only vs +driveForce): re-ask after PHASE 1.
5. **force-auto group:** confirm forcePaddle=2 "limits non-DCT modes off the always-auto
   group" — does this need to apply beyond DCT modes under the new numbering?

## PARSE / VERIFY CHECKLIST
- `luac -p config.lua && luac -p client/gearbox.lua && luac -p server/gearbox.lua`
- After SQL: confirm hk_handling populated + remap correct on a test row before dropping
  defaultManual. Restart hk-handling to reload server map + push to clients.

