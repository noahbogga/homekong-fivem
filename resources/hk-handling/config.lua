-----------------------------------------------------------------
-- hk-handling :: config.lua
-- All tunables for the vehicle dynamics systems.
-----------------------------------------------------------------

Config = {}

-----------------------------------------------------------------
-- GLOBAL
-----------------------------------------------------------------
Config.Enabled = true
Config.Debug = false

-- AUTO-BLINKER (2026-08-14) — Assetto-Corsa-style steering-driven turn signals.
-- TOP-LEVEL (client/blinker.lua reads Config.AutoBlinker — must NOT be nested in Config.Drivetrain).
-- TOGGLE with Left-Alt. While ARMED the indicators follow the STEERING angle:
--   steer LEFT  past OnPct  -> left blinker;  steer RIGHT past OnPct -> right blinker
--   |steer| <= OffPct       -> HAZARDS (both, near-center presence)
-- Uses state.steer (-1 left .. +1 right), the same value the steering model owns. The LAlt toggle is
-- the SINGLE arm control — when ON it works the same in forward AND reverse; when OFF we touch nothing
-- (native reverse lights + the manual -/=/backspace blinker still work). Publishes HK.blinker.
Config.AutoBlinker = {
    Enabled          = true,
    EnabledByDefault = false,  -- seeds HK.blinkerArmed. false = start DISARMED (LAlt turns it on).
    ToggleControl    = 19,     -- INPUT_CHARACTER_WHEEL = LEFT ALT (tap toggle; RegisterKeyMapping too)
    OnPct            = 0.15,   -- |steer| past this (15%) picks a side (left/right)
    OffPct           = 0.15,   -- |steer| at/below this = hazards (both). Same as OnPct = clean 15% split.
    DebounceMs       = 180.0,  -- min ms a side must persist before switching (anti-flicker at threshold)
}

-- DRIFT HAZARDS (2026-09-06) — flash BOTH indicators as hazards while drift mode is held, on a plain
-- FAST even-duty blink ( . . . . . . — faster than the normal turn-signal rate, no pause). NOTE: the
-- indicator native (SetVehicleIndicatorLights) is ON/OFF only — there is NO brightness/alpha, so a
-- dim-fade isn't possible; we just run a quick steady on/off. Driven every frame from blinker.lua (the
-- module that already owns indicator writes and reasserts each frame to beat the escrowed -/=/backspace
-- LVC blinker). Drift ALWAYS wins: even with the auto-blinker armed, drift mode shows the hazard (the
-- steering turn-signal is suppressed for the duration). On drift exit the indicators are cleared to OFF
-- (the auto-blinker does NOT resume a stale signal — see the handoff in blinker.lua).
Config.DriftHazard = {
    Enabled     = true,
    -- FAST even blink (ms). OnMs on, OffMs off, repeat. Keep both small + roughly equal for a crisp
    -- rapid strobe that's clearly faster than the ~340ms native turn-signal blink.
    OnMs        = 90.0,    -- ms ON per flash
    OffMs       = 90.0,    -- ms OFF between flashes
    -- Only run above this speed so a stationary drift-toggle isn't strobing at a standstill. 0 = always.
    MinSpeedKmh = 0.0,
}

-- BRAKE OVERRIDE (2026-08-14): on a real car the brakes overpower engine drive torque (they're sized to
-- arrest the whole car's kinetic energy), and modern ECUs enforce it — a "brake override system" cuts
-- throttle when both pedals are pressed. So full throttle + brake should SLOW the car, not fight to a
-- standstill of speed. When braking AND on throttle above the min speed, cut drive torque by the brake
-- amount so the brakes win. Gated above MinKmh so the standstill W+S gestures (burnout / free-rev /
-- launch staging, all ~0 km/h) keep their footbrake-vs-throttle hold. Reverse skipped (its own model).
Config.BrakeOverride = {
    Enabled     = true,
    MinBrake    = 0.15,   -- physical S at least this to count as braking (ignore analog noise)
    MinThrottle = 0.15,   -- physical W at least this — only override when actually ON the throttle
    MinKmh      = 8.0,    -- only above this speed (below = standstill W+S gestures own the footbrake hold)
    MaxCut      = 0.22,   -- torque left at FULL brake (0 = full fuel-cut; 0.22 = leave 22% engine push-
                          -- through so the override is ~22% weaker — felt too strong at full cut). Cut
                          -- scales linearly with brake amount. Raise for more push-through, lower for less.
}

-- AIRBORNE FORCE CUTOFF (2026-08-14): once a car has been off ALL wheels for longer than
-- AirborneForceCutMs, STOP applying our physics forces to it (drivetrain per-wheel brakers,
-- drift yaw/lateral, wheelie/headlift lift, DRS/downforce pushes). GTA converts any stray
-- force/torque we add mid-air into a sideways shove with no tyres to resist it — that's the
-- "car flies off a ramp and drifts left/right on its own" bug. A brief hop (<600ms) still gets
-- our normal handling (kerbs, small jumps feel right); only sustained air hands control fully
-- back to the game so the car flies straight and lands clean. Input SHAPING (throttle/brake/
-- steer models) and gearbox logic keep running — this only gates things that PUSH the chassis.
Config.AirborneForceCutEnabled = true
Config.AirborneForceCutMs = 600

-- GLOBAL STEERING RANGE (2026-08-13): a flat cut to the left-right wheel-lock
-- range that applies in BOTH normal and drift mode. fSteeringLock (max wheel
-- angle, deg) is the single source of truth for range — normal mode uses the
-- car's native lock, drift mode scales it by Config.Drift.SteeringLockMult, and
-- both the drift counter-steer and the AWD high-speed limiter read the live lock.
-- Scaling that one field with this factor tightens the whole range everywhere.
--   1.0 = native range; 0.58 = 42% less left-right travel; 0.70 = 30% less.
-- Applied per-frame in the main loop (normal) and folded into the drift scale.
-- 2026-08-12: user "cornering angle too limited, need at least 20% more angle." This global cut was
-- the dominant limiter on normal cornering (the AWD SteerLimit only acts >150 km/h). 0.58 → 0.70
-- (+20.7% wheel lock). Applies to ALL cars + folds into drift's lock scale, so drift counter-steer
-- range widens proportionally too. If that's too much for drift specifically, split it later.
-- NOTE: this is the HIGH-SPEED baseline. Low speed gets a much bigger angle via SteerRangeLowSpeed below.
-- 2026-08-14: +15% overall — user "make it increase back 15%". 0.70 -> 0.805 (baseline), and LowMult/
-- TopMult below bumped the same 15% so the WHOLE speed curve opens up proportionally, not just the mid.
Config.SteerRangeMult = 0.805

-- LOW-SPEED STEERING BOOST (2026-08-12): user "below 80, especially 20-60, tight corners need much
-- more angle — and you're barely on throttle there so it's safe to open it up." The flat SteerRangeMult
-- above is tuned for stable high-speed cornering, but that same tight lock makes low-speed hairpins/
-- parking-lot turns feel trucky. So we SCALE THE MULTIPLIER UP as speed drops: at/below LowKmh the wheel
-- lock reaches LowMult (ABOVE native 1.0 = more lock than stock, for genuine tight-corner agility),
-- easing back to the flat SteerRangeMult by HighKmh. Only the multiplier changes — still one
-- scaleHandling write on fSteeringLock, still never touches handling.meta. Folds into drift too.
-- Three-segment speed curve on the lock multiplier:
--   crawl (<=LowKmh) ......... LowMult   (full agility boost, MORE than native)
--   LowKmh -> HighKmh ........ lerp down to the SteerRangeMult baseline
--   HighKmh -> TopKmh ........ smooth (eased) taper baseline -> TopMult, gradually slowing throughout
--   >=TopKmh ................. TopMult   (tightest lock, high-speed stability)
Config.SteerRangeLowSpeed = {
    Enabled = true,
    LowKmh  = 20.0,   -- at/below this speed = full low-speed boost (LowMult)
    HighKmh = 198.0,  -- baseline (Config.SteerRangeMult) reached here — boost fully faded by 198
    LowMult = 1.265,  -- fSteeringLock scale at/below LowKmh. >1 = MORE than native lock.
                      -- 2026-08-14: 1.25 -> 1.38 (~+10% tighter turn-in below ~120), then 1.38 -> 1.10
                      -- (user: "less turn, ~20% to scale") — cut the low-speed lock ~20%. Then 1.10 -> 1.265
                      -- (+15% overall bump). This is the crawl ANCHOR that lerps to the 0.805 baseline, so the
                      -- boost is strongest at crawl and fades to baseline by ~120. Whole curve +15%.
    TopKmh  = 450.0,  -- at/above this = TopMult (tightest lock for top-speed stability)
    TopMult = 0.69,   -- fSteeringLock scale at/above TopKmh. Smoothstep-eased from baseline so it
                      -- tightens gently and keeps slowing the closer you get to 450.
                      -- 2026-08-14: 0.60 -> 0.69 (+15% overall bump).
}

-- Keybinds (FiveM RegisterKeyMapping names)
Config.Keys = {
    ToggleDrift = 'CAPS',       -- toggle drift mode on/off
    ToggleTC    = 'LCONTROL',   -- cycle TC modes (Off / Low / High) -- placeholder
                                -- (moved off LSHIFT so the gearbox clutch can use it)
    Wheelie     = 'LMENU',      -- hold to pop a controlled wheelie (Left Alt)
    ShiftUp     = 'K',          -- gearbox: shift up
    ShiftDown   = 'J',          -- gearbox: shift down
    Clutch      = 'LSHIFT',     -- ONE gear key (rebindable in FiveM). Interpreted per transmission:
                                -- manual = held clutch; DCT = auto<->paddle toggle (edge).
    -- NOTE: NEUTRAL has NO dedicated key. It is reached by holding BOTH shift keys
    -- (ShiftUp+ShiftDown) together — temporary in manual, latched after 800ms in DCT —
    -- or by rotating down past the lowest gear.
}

-----------------------------------------------------------------
-- [D3] DRIFT MODE
-- Foundation: R*'s built-in drift-tyre model (SET_DRIFT_TYRES), which
-- our server's build 3570 supports. On top of that we layer the things
-- the native does NOT give: counter-steer range (fSteeringLock) and a
-- looser tail (fTractionBiasFront). HOLD-to-drift.
--
-- Why native-based: SET_DRIFT_TYRES is R*'s real drift physics, far
-- better than scaling traction curves by hand. The optional traction-
-- loss / slip-angle natives let us tune intensity. The handling-curve
-- scales from the old approach are kept behind a flag as a fallback.
-----------------------------------------------------------------
Config.Drift = {
    Enabled = true,   -- [TESTING: first feature we're verifying in-game]
    Debug   = false,   -- print SET_DRIFT_TYRES readback to F8 console (diagnosing)

    -- DRIFT TORQUE CEILING (2026-08-13): cap drive torque this fraction of native while drifting, so
    -- the script never commands 100% drive during a slide — always leaves native headroom, so the car
    -- settles onto native forces on exit instead of us handing back from a boosted state. Applied in
    -- main.lua under any TC/ESC cut (min wins). Gentle by design ("native-first" lever, not a felt
    -- power cut — the slide still breathes). 1.0 = disabled (full native torque). Applied in main loop.
    TorqueCeiling = 0.92,

    -----------------------------------------------------------------
    -- CORE (native-based — the foundation)
    -----------------------------------------------------------------
    -- SET_DRIFT_TYRES: R* drift-tyre mode. This is the main slide enabler.
    UseDriftTyres = true,

    -- _SET_OVERRIDE_TRACTION_LOSS_MULTIPLIER: continuous traction-loss
    -- scaler while drifting. 1.0 = stock, higher = loses grip more readily
    -- (more slide). KuzQuality's range is 0.1-10. Reasserted per frame.
    UseTractionLossOverride = true,
    TractionLossMult        = 0.79,  -- 2026-08-10 v30: was 0.85. Reduced 7% overall slide (0.85 × 0.93 = 0.7905)
                                     -- PHASE 1 (2026-08-08): was 0.7. Raised toward stock now that the
                                     -- grip-cliff (TractionCurveMinMult) is fixed and no longer needs base
                                     -- loss to compensate. Higher base grip = the car SETTLES cleanly when
                                     -- you lift instead of drifting on; throttle sustain still adds slide on
                                     -- top. Residual-floor principle: lean on grip, not greasiness.

    -- THROTTLE-LINKED SUSTAIN: real drifts are held with throttle (power
    -- oversteer), not RPM. We scale traction-loss UP with throttle so the
    -- rear stays loose while you're on the gas, and settles when you lift —
    -- exactly the "partial throttle maintains the slide" technique. This is
    -- what makes a held drift sustainable. NO rpm/torque writes (would fight
    -- the gearbox + caused the gear-1 bug).
    -- 2026-08-10 v5: user "held drift movement to slide is too strong, tone down
    -- by 17%" — TractionLossOnThrottle 1.20→1.00 (17% reduction: 1.20-0.20=1.00).
    -- This is the BASE slide strength when holding drift+throttle. Now at 1.00
    -- (neutral) so throttle sustains the drift without adding extra rotation force.
    ThrottleSustain      = true,
    TractionLossOnThrottle = 1.00,   -- PHASE 1 (2026-08-08): was 1.55, then 1.20, now 1.00 (17% cut)
                                     -- Physics research (real/Forza/AC) is unanimous: power SUSTAINS
                                     -- drift angle, grip reduction ALLOWS it. If a car over-rotates you
                                     -- cut POWER aggressiveness, you don't add grip loss. 1.00 = throttle
                                     -- maintains the slide at neutral (no extra rotation push).
                                     -- Throttle/RPM feel + sound unchanged (no torque/rpm writes).
    SustainThrottleGate  = 0.5,      -- was 0.3 — raised so LIGHT maintenance throttle keeps grip
                                     -- (a holdable balance band); only deliberate throttle past 0.5
                                     -- ramps toward the slide ceiling. Fixes "can't hold a steady slide".

    -- _SET_DRIFT_SLIP_ANGLE_LIMITS: (durationScalar, amplitudeScalar,
    -- slipAngleLimit). First two = controller rumble, last = slip-angle
    -- threshold. Param semantics are fuzzy, so OFF by default — enable
    -- only when we're ready to feel out values in-game.
    UseSlipAngleLimits = false,
    SlipRumbleDuration = 1.0,
    SlipRumbleAmplitude = 1.0,
    SlipAngleLimit     = 0.6,

    -- SET_REDUCED_SUSPENSION_FORCE: lowers stance. Needs handling.meta
    -- strAdvancedFlags 0x8000 + 0x4000000 on the car, so OFF by default.
    UseReducedSuspension = false,

    -- BUMP GUARD (2026-08-12 v7.18): every drift yaw assist writes the FULL angular-velocity vector
    -- via SetEntityAngularVelocity, which overwrites the physics substep's pitch/roll for that frame
    -- and re-imposes the stale start-of-frame pitch/roll RATE — fighting the suspension's own damping.
    -- On flat ground that's ~0 so it's invisible, but over bumps/dips/hills it pumps the up/down &
    -- rear bounce every frame (the assist fires almost continuously). setYaw skips the write on any
    -- frame where the body is pitching OR rolling faster than this many rad/s, letting physics damp
    -- the bump. Yaw control loses at most that one frame. LOWER = calmer on rough ground but yaw assist
    -- drops out more readily on bumps; RAISE toward 0.6 if drifts over bumps feel like they lose steer
    -- authority. 0 disables the guard (old always-write behaviour = the bounce).
    BumpGuardRate = 0.35,

    -- DAMAGED-BODY SUSPENSION GATE (2026-08-12): reduced suspension on a physically deformed
    -- chassis rides unevenly and feeds the up/down bounce (only visible outside godmode). Below
    -- this body health (GetVehicleBodyHealth, 0..1000; 1000 = pristine) we skip reduced suspension
    -- on entry and drop it live if the body takes damage mid-drift, keeping stock suspension so the
    -- car stays planted. Only relevant when UseReducedSuspension is on.
    DamagedBodyHealth = 950.0,

    -- AUTO-HANDBRAKE INITIATION: brief handbrake tap on drift-key press to
    -- kick the rear loose, so you don't need to hit space yourself to start.
    -- The TAP DURATION is the anti-snap control: too long = the locked rear
    -- snaps you into a spin; too short = doesn't break loose. NO rpm/engine
    -- writes here (that's rev-limiter territory + fights the gearbox).
    -- Mid-drift you can still tap SPACE yourself to re-kick / tighten angle.
    UseAutoHandbrake   = true,
    AutoHandbrakeMs    = 160,    -- was 210 — still too much kick; shorter tap breaks the rear loose
                                 -- just enough to start without over-sliding on initiation
    AutoHandbrakeMinKmh = 20.0,  -- below this speed, skip the tap (no point standing still)
    AutoHandbrakeMaxKmh = 160.0, -- above this, skip it (high-speed handbrake = snap-spin)

    -----------------------------------------------------------------
    -- CONTROL LAYER (handling fields the native doesn't touch)
    -----------------------------------------------------------------
    -- THE HOLD ENABLER: extra steering lock so you can counter-steer and
    -- HOLD the slide instead of spinning. Scaled off the car's own lock.
    SteeringLockMult       = 1.60,  -- was 1.40 — more counter-steer angle (bigger front steer lock)

    -- ABSOLUTE nudge of fTractionBiasFront. IMPORTANT: 0.5 = equal grip,
    -- HIGHER = more front grip = LESS rear grip = MORE oversteer/drift.
    -- (Earlier this was negative, which made the rear GRIPPIER — backwards.)
    -- Positive = looser tail, easier to break loose and hold a donut.
    -- Captured + clamped 0.1-0.9 + restored.
    TractionBiasFrontDelta = 0.04, -- positive = looser rear. Eased from 0.08 — too much rotated
                                   -- the car sideways instead of driving forward through the drift.

    -- AWD DRIFT DRIVE-BIAS SHIFT (2026-08-10 v21 — Phase 2). The drift model cuts GRIP but not
    -- where POWER goes (fDriveBiasFront). On AWD the driven front wheels pull the nose straight —
    -- the car washes WIDE before it rotates (hold-key), and a space kick spins because front drive
    -- FIGHTS the rotation. Real drifters send power rearward to make an AWD car slide. This shifts
    -- fDriveBiasFront toward the rear for the drift's duration (AWD only; RWD already rear, FWD skip).
    -- Captured + restored on exit. Gated on native front-bias so RWD cars are untouched.
    AwdDriftDriveBias = {
        Enabled      = true,
        MinFrontBias = 0.45,  -- only shift cars with at least this native fDriveBiasFront (AWD 0.5/0.6)
        RearShift    = 0.22,  -- how far toward the rear to move it (0.60→0.38, 0.50→0.28)
        MinBias      = 0.20,  -- never drop below this (keep SOME front drive so it still tracks)
    },

    -- ABSOLUTE suspension overrides while drifting (exact value, NOT a multiplier).
    -- Captured + restored on drift exit. Set to nil to disable a field.
    -- 2026-08-12 DISABLED — VERTICAL BOUNCE ROOT CAUSE. These SOFTENED the suspension on drift
    -- entry: fSuspensionForce 2.1-2.3 → 1.8 (softer springs) and, worse, fSuspensionReboundDamp
    -- 2.4 → 1.8 (−25% rebound damping). Underdamped rebound + softer springs = the car POGOS on
    -- any non-flat ground — every hill/dip/bump compresses the suspension and it springs back
    -- overshooting instead of settling → the "front or rear bounces up/down while just holding
    -- drift and driving" the user hit (no crash needed). Flat test ground + godmode masked it.
    -- The native handling.meta suspension is professionally damped; leave it alone (nil = no
    -- override). If a drift "sit/react" feel is wanted later, tune rebound damp UP or equal to
    -- native, never below, and change spring force only slightly.
    SuspensionForceAbs       = nil,  -- was 1.8 — disabled (kept native, no pogo)
    SuspensionReboundDampAbs = nil,  -- was 1.8 — disabled (this cut was the main bounce cause)

    -----------------------------------------------------------------
    -- FALLBACK (handling-curve approach — GUARANTEED to work on any car)
    -- SetVehicleHandlingFloat works regardless of drift-tyre data, so this
    -- is the reliable slide. ON now while we verify whether the drift-tyre
    -- native does anything on these custom add-on cars.
    -----------------------------------------------------------------
    UseHandlingCurves        = true,
    TractionCurveLateralMult = 1.30,  -- was 0.55 — now 130% of stock lateral grip (more side bite = holds the slide line better, harder to wash out)
    TractionCurveMaxMult     = 0.84,  -- 2026-08-10 v30: was 0.90. Reduced 7% (0.90 × 0.93 = 0.837)
    -- PHASE 1 GRIP-CLIFF FIX (2026-08-08): was 0.40. In GTA's tyre model fTractionCurveMin
    -- is grip PAST optimal slip = the grip you have WHILE SLIDING (the "residual floor").
    -- hkcarpack is tuned with FLAT curves (Min==Max on 69/145 cars, within ~1% on the rest),
    -- so cutting Min to 0.40x while Max stays 0.90x manufactured a grip CLIFF: the instant the
    -- rear broke past peak it fell to ~40% grip = icy, uncatchable, nothing to lean on to flick
    -- the other way. Physics research: the sliding tyre must KEEP substantial lateral force so
    -- the driver can hold angle AND build yaw for transitions. Track Max closely to keep the
    -- intentional flat curve (0.85 vs 0.90) = planted slide instead of ice.
    -- 2026-08-10 redeye fix: even with counter-steer tuning, 35-120 km/h too loose on RWD.
    -- Raised 0.85→0.88 (closer to Max 0.90) to give more residual grip floor during slide.
    -- 2026-08-10 v30: both Min+Max reduced 7% overall (0.88 × 0.93 = 0.818, track Max 0.84).
    TractionCurveMinMult     = 0.82,
    AntiRollBarForceMult     = 0.75,
    HandBrakeForceMult       = 0.9,   -- was 1.05 — still too much kick; below stock so the e-brake
                                      -- breaks the rear loose gently instead of locking it hard
    -- 2026-08-10 v8: user "low-speed corner drift breaks loose too late" — lowered 0.8→0.65
    -- so low-speed grip is LESS firm (easier to initiate slide on drift-key tap at 40-90 km/h).
    -- 2026-08-10 v30: reduced 7% overall (0.65 × 0.93 = 0.6045).
    LowSpeedTractionLossMult = 0.60,  -- was 0.65 — now 60% of stock (easier low-speed break-loose)

    -- Blunt fallback grip cut (legacy). Leave false.
    UseReduceGripOnHandbrake = false,

    -- Notification on drift on/off. Uses QBCore notify if qb-core/qbx_core
    -- is running, else the GTA native popup. With HOLD this fires often.
    -- OFF: hk-speedo now shows drift/grip state (+ the ABS/TC pulsing), so the
    -- "Drift mode" / "Grip mode" QB toasts are redundant.
    NotifyOnToggle = false,

    -- Block drift mode on the COMFORT-AUTO daily box (PUBLIC gearbox type 0). These are the
    -- basic/utility cars that shouldn't slide. EVs, hybrids, manual, DCT and sequential are
    -- all still allowed to drift. false = allow drift on everything (old behaviour).
    BlockOnComfortAuto = true,

    -----------------------------------------------------------------
    -- REGIME MODEL (2026-08-14 SCRATCH REBUILD) — one continuous drift tick keyed
    -- on speed, three blended regimes. This is the spine of the new drift.lua.
    --
    --   A LAUNCH (0 → LaunchFadeKmh): torque hold + rear grip-loss so the driven axle
    --     OVERPOWERS grip and the tyres SPIN. LaunchTorqueMult HOLDS engine torque up
    --     ("longer torque at launch") and LaunchLossMult fries the REAR — forward
    --     motion EMERGES from the wheelspin (real drive force), NOT injected velocity.
    --     The gear is held low (drift gear ceiling) so rpm+torque ride high = the real
    --     high-rev launch flare. Front grip stays near stock (grip-cut ~GripFloor down
    --     here) so native front-tyre steering turns the car. Absorbs the old burnout gesture.
    --   B BUILD (Launch → SlideMinKmh): forward drive fades out, grip-cut depth
    --     ramps toward full — the wheelspin slide that carries into a real drift.
    --   C SLIDE (SlideMinKmh → SlideFullKmh): counter-steer + governor authority
    --     ramps in (the high-speed slide that "was as good as it was").
    -----------------------------------------------------------------
    Regime = {
        SlideMinKmh  = 30.0,   -- slide assists (counter-steer/governor) start ramping here
        SlideFullKmh = 80.0,   -- full slide authority at/above here

        -- Grip-cut depth ramp: how much of the full drift grip-loss applies vs speed.
        GripRampLoKmh = 6.0,   -- below this, depth pinned at GripFloor (near-stock front grip = steers)
        GripFloor     = 0.15,  -- minimum grip-cut depth at standstill (0 = stock grip, 1 = full drift)

        -----------------------------------------------------------------
        -- LOW-SPEED LAUNCH EMPHASIS (2026-08-14 symptom #5, reworked). A drift launch
        -- from a standstill is NO LONGER a phase machine — it's just "drift, held in a
        -- low gear (drift gear ceiling → block auto-upshift, allow downshift), at low
        -- speed". Held low, revs+torque ride high off the gearing (the real high-rev
        -- flare — no fake rpm paint), and this EMPHASIS layer boosts torque + fries the
        -- rear so the tyres overpower grip and SPIN. Forward motion emerges from that
        -- wheelspin (real drive force), NOT injected velocity. wLaunch is a smooth
        -- LOW-SPEED FADE (1.0 at LaunchFadeLoKmh → 0 at LaunchFadeKmh) so every car
        -- benefits regardless of torque — no per-car handoff/speed-line to get wrong.
        -----------------------------------------------------------------
        LaunchFadeLoKmh   = 5.0,   -- full launch emphasis at/below here
        LaunchFadeKmh     = 40.0,  -- emphasis faded to 0 at/above here (blends into the plain slide)

        DriveThrottleGate = 0.15,  -- need at least this throttle for the torque hold + rear fry
        LaunchTorqueMult  = 1.7,   -- peak shared-torque multiplier at full throttle (holds the spin)

        -- BRAKE-TORQUE SPIN RPM PIN (2026-08-14). Native brake-torque wheelspin = drift +
        -- S(brake) + W(throttle) → engine revs to ~max against the held brake with the
        -- wheels spinning. On brake RELEASE we PIN the needle FLAT at the captured max and
        -- HOLD it until grip physically returns (the real wheelspin SETTLES — worstSpin,
        -- not rpm, since rpm is contaminated by our own paint feedback). Cosmetic pin; the
        -- spin sustain itself is the grip work that comes next.
        SpinBrakeGate = 0.5,   -- brake fraction that counts as "loading against the brake"
        SpinArmRpm    = 0.80,  -- peak rpm must reach this (0..1) while braked to arm the pin
        SpinArmMps    = 3.0,   -- AND driven-wheel over-speed (m/s) must reach this = a REAL spin (idle→spin detect)
        SpinSettleMps = 2.0,   -- release: wheelspin worstDiff (m/s) below this = grip catching
        SpinSettleMs  = 300,   -- debounce: spin must stay settled this long before the pin releases
        SpinPinMaxMs  = 6000,  -- SAFETY backstop only: hard cap on pin hold (real release is the settle)

        -- ============================================================================
        -- S-KEY-AS-WHEELSPIN (2026-08-14, user rework). The OLD footbrake-load spin above
        -- was physically wrong for mid-drive: holding S loads the engine against the HELD
        -- BRAKE, which BLEEDS speed + rpm — a slow car never reaches the high-torque,
        -- out-of-gear-ratio spin that a wheelie needs to loft. Launch Control works because
        -- it drives the spin WITHOUT braking. So in drift mode, S changes meaning:
        --   • driftkey + W + S (throttle present) → NATIVE WHEELSPIN, NO FOOTBRAKE. We
        --     suppress the brake this frame (so speed isn't bled) and force the rears loose
        --     (SetVehicleBurnout) + hold torque + drop rear grip (hybrid). The car keeps
        --     rolling and the rears go out-of-boundary — the LC-like state. Purely STATE
        --     based: as long as all three are HELD (any order), we're in wheelspin.
        --   • driftkey + S, NO throttle → normal footbrake (untouched).
        -- Gated per-vehicle (SpinNoBrake.Eligible): auto for VC_MUSCLE with L3 engine + L3
        -- suspension, OR any car opted in via /setwheelielaunch (reuses that flag).
        -- ============================================================================
        SpinNoBrake = {
            Enabled       = true,
            ThrottleGate  = 0.15,   -- W must exceed this for W+S to mean "wheelspin" (else S = footbrake)
            BrakeGate     = 0.5,    -- S (HK._pedalBrake) must exceed this to count as held
            -- HYBRID break-loose: force the spin AND layer the physical feel (torque + grip drop).
            ForceBurnout  = true,   -- SetVehicleBurnout(true) — guarantees break-loose even on a slow car
            TorqueMult    = 1.9,    -- shared-torque hold while spinning (overpower grip; ~LaunchTorqueMult+)
            -- RPM PAINT while forced-spinning (2026-08-14 fix). SetVehicleBurnout PINS native rpm at ~0.55,
            -- so the old arm gate (needs state.rpm >= SpinArmRpm 0.80) could NEVER trip on a /setwheelie car
            -- and the needle sat at GTA's canned 0.55. A real car SCREAMS at the limiter when the tyres are
            -- lit, so we PAINT the rpm ourselves: arm on the PHYSICAL spin (worstSpin, immune to the cap) and
            -- ride the needle up to RpmTarget with a limiter BOUNCE. HK.driftSpinRpm is painted last in main.lua.
            RpmTarget     = 0.99,   -- rpm the painted needle rides to while spinning (near limiter)
            RpmRise       = 4.0,    -- how fast the needle climbs to target (per second, ~0.25s to full)
            RpmBounce     = 0.055,  -- limiter bounce depth: needle oscillates RpmTarget-this .. RpmTarget
            RpmBounceHz    = 13.0,  -- limiter bounce frequency (Hz) — the rev-limiter flutter
            SpinArmMps    = 2.5,    -- PHYSICAL driven-wheel over-speed (m/s) that arms the paint (forced path)
            -- RearLossMult reserved: NOT applied mid-drive — the private slide-cliff native is
            -- regime-A/recovery-owned + has no reset path at speed, so a write here would leave the
            -- rear fried. The forced SetVehicleBurnout already breaks the rears loose.
            -- ELIGIBILITY (auto path): VC_MUSCLE + built drivetrain. Opt-in (wheelieLaunch) bypasses all.
            RequireMuscle = true,   -- state.class == 4
            MinEngineMod  = 2,      -- GetVehicleMod(veh,11) >= this (0..3 tiers; 2 = "level 3" in-game label)
            MinSuspMod    = 2,      -- GetVehicleMod(veh,15) >= this (suspension tier)
        },

        -- LAUNCH WHEELSPIN: at launch the SHARED curves stay near GripFloor (front
        -- grip kept so the car STEERS), which also pins the private slide-cliff near
        -- stock (1.0) = no rear fry — that's why "the grip loss isn't in place" off
        -- the line. This overrides the PRIVATE slide-cliff native (rear wheelspin
        -- only, higher = more slide) to a burnout value while the launch emphasis is
        -- active on throttle. The front keeps grip so the launch still steers.
        LaunchLossMult = 1.6,   -- private-native value at peak launch (matches FWD tuck fry). 1.0 = off.
    },

    -----------------------------------------------------------------
    -- ENTRY RAMP (2026-08-12 v7.1) — slow the angle build-up
    -----------------------------------------------------------------
    -- Problem: instant grip cut on drift-key press = rear breaks loose too fast,
    -- angle runs away before player can react/tap-space to tighten. The handling
    -- field edits (TractionCurveMin/Max/etc) apply on one frame = instant slide.
    --
    -- Fix: on drift entry, ramp the grip cuts from 0% (stock grip) to 100% (full
    -- drift grip) over a short window. So the rear breaks loose progressively
    -- instead of all-at-once, giving the player time to feel it start and adjust.
    Entry = {
        Enabled = true,
        RampMs = 1620,   -- v7.10: 1200→1620 (+35% slower). Ramp grip cuts from 0→100% over 1.62 seconds (very slow entry so player has full control over angle build-up)
    },

    -----------------------------------------------------------------
    -- EXIT RECOVERY (2026-08-08) — the "bounce back to center" fix
    -----------------------------------------------------------------
    -- Problem: releasing drift restored full grip on ONE frame while the car was
    -- still rotating (leftover yaw) and sideways. Instant grip + leftover yaw =
    -- the rear bites while sideways -> snap/pivot instead of straightening, and
    -- countersteer can't save it because grip snapped back all at once. Physics
    -- research: instant grip RECOVERY is exactly what spins a car on transition.
    --
    -- Fix: a short recovery window armed on drift exit that (a) actively DAMPS the
    -- leftover yaw rate so the car recenters, and (b) ramps grip back gradually
    -- instead of snapping. Yaw damping can only ever REDUCE rotation (scales the
    -- live z-angular-velocity toward 0), so it can never rotate the car the wrong
    -- way — it just bleeds off the spin you're already carrying.
    Recovery = {
        Enabled = true,

        -- RECENTER TAPER FLOOR (2026-08-13 v7.22): drift exit passes this stronger slip floor to the
        -- shared HK.recenterTaper. Unlike the spin softeners (gated at high slip, so their default
        -- floor is always saturated), the drift exit straightens the car THROUGH the low/mid slip band
        -- — so it needs recenter held at (near) full force while still sideways, fading only in the
        -- final near-center degrees. Without this, low-speed exits (already weak by the speed-scale)
        -- got double-weakened and the drift angle opened up. floorWeight 1.0 = full hold while sideways;
        -- gate/full 4→10° = fade only in the last stretch back to straight. nil → uses config defaults.
        RecenterTaperFloor = { floorWeight = 1.0, floorGate = 4.0, floorFull = 10.0 },

        -- 2026-08-10 v20: release recovery was recentering too aggressively on some exits,
        -- especially AWD/high-speed releases. Lengthen the handoff and reduce the initial yaw
        -- damping so the car settles progressively instead of feeling auto-centered/cheated.
        -- 2026-08-12 v7.1: user "exit drift mode still way too rapid, from the vehicle still tilting
        -- left right and back to straight in all a sudden." Stretched from 1100→1800ms so the recovery
        -- window lasts longer and the car eases back instead of snapping straight.
        -- 2026-08-12 v7.17: 1800→1950 to make room for the new front-of-window hold-off (300ms) without
        -- the attack (750ms) band overlapping the tail.
        -- 2026-08-12 v7.18b: hold-off 300→450, so 1950→2100 to keep the bands clean. Bands: 0-450 free
        -- slide, 450-1200 attack ramp, 1200 hold, 1200-2100 smoothstep tail-out (decayStart = 2100-900 =
        -- 1200 = holdoff+attack). Clean.
        DurationMs = 2100,

        -- HOLD-OFF (2026-08-12 v7.17): free-slide dead-time at the FRONT of the recovery window where NO
        -- centering happens (yaw damp + slip-smoother both stay at zero). User: on exit the car "shoots
        -- out too early, before the drift has finished sliding — it's not the force, it's the timing, it
        -- comes too early." The recenter used to begin easing in the instant the drift key released, so it
        -- straightened the car mid-slide and redirected the sideways scrub into forward speed. This lets
        -- the slide play out under its own momentum first, THEN the smoothstep attack begins. Raise for a
        -- longer free slide before the car settles; lower to bring the recenter in sooner. 0 = old behaviour.
        -- 2026-08-14: user "drift-mode autofix returns to original state too fast" (same note as the
        -- AWD handbrake). Lengthen the free-slide dead-time 450→620 so the slide plays out longer
        -- before ANY centering engages. Paired with a softer YawDampStart below.
        RecenterHoldoffMs = 620.0,   -- v7.18b: 300→450; 2026-08-14: 450→620 (longer free slide before the recenter engages)

        -- YAW DAMPING: fraction of leftover yaw rate removed per second at the
        -- START of the window, decaying to 0 by the end. 0 = no damping, higher =
        -- snaps straight faster. This is the "recenter" force.
        -- 2026-08-12 GRIP-DRIFT v6.2: user "on release the recenter comes too fast + shoots the car
        -- forward — I hadn't finished fixing the angle with my own steering yet." Lowered 2.0→1.1 so
        -- the recenter is a gentle backstop, not a snap. The forward "boost" was the fast recenter
        -- redirecting still-sideways (scrubbing) speed into forward speed; a gentler bleed removes it.
        -- 2026-08-12 v7.1: user "exit still too rapid." Lowered 1.1→0.75 so the backstop is even gentler.
        -- 2026-08-12 v7.20: the 2.0→1.1→0.75 slides were WORKAROUNDS for the forward-launch — each drop
        -- masked the launch by weakening centering. The launch is now fixed at the root (grip lateral-gate
        -- + window-end scrub-close + steer-through yield), and steer-through DECOUPLED base-centering from
        -- "yield to the player's wheel." So base centering can go firmer without re-introducing the launch:
        -- when you're steering, the yield still backs it off; when you're not, grip still can't hook the
        -- scrub. Raised 0.75→1.0 per user "the force coming out to centering can increase a bit."
        -- 2026-08-12 v7.21: user "increase to 1.18, more forgiving." Firmer backstop catches the yaw
        -- sooner so the exit self-corrects with less player input needed.
        -- 2026-08-14: user "exit fixes too fast" — softened 1.18→0.92 so the recenter backstop is
        -- gentler and the car eases straight instead of auto-fixing. Paired with the longer holdoff
        -- above. If this now under-corrects on high-speed exits, the speed-scale (YawDampHighMult 2.2)
        -- still lifts it up top; raise back toward 1.1 if low-speed exits feel too loose.
        YawDampStart = 0.92,   -- per-second damping coefficient at t=0 of window (was 2.0, 3.5, 1.1, 0.75, 1.0, 1.18)

        -- 2026-08-12 v6.4: the REAL fix per user — it's the ONSET TIMING, not the strength. The
        -- (1-p) recenter profile is at MAX the instant you release (grabs hardest mid-correction).
        -- Ease it in over this many ms so the first moment after release is gentle (your own steering
        -- leads), then the backstop builds. 0 = disabled (instant, old behaviour).
        -- 2026-08-12 v7.1: stretched from 320→500ms so more of the 1800ms window is ramping up gently.
        -- 2026-08-12 v7.15: 500→750ms. The attack curve is now SMOOTHSTEP (was linear — a linear ramp
        -- still grabbed at t=0 because it jumps to constant slope instantly). Smoothstep starts at zero
        -- slope so the centering creeps in; stretching to 750ms makes that gentle onset clearly felt.
        -- 2026-08-12 v7.15b: briefly bumped to 1000ms to compensate for a full-authority softkick change
        -- that turned out to make things GRABBIER — that change was reverted, so this is back to 750ms.
        RecenterAttackMs = 750.0,

        -- RELEASE TAIL (2026-08-12 v7.6): user "the exit `help` fades out way too fast and the vehicle
        -- loses control instantly." The old (1-p) profile decayed the damping LINEARLY across the whole
        -- window, so it started dropping the instant you released and the tail was already near-zero
        -- while the car still carried catchable yaw. Now the damping SUSTAINS at full strength until the
        -- final RecenterDecayMs, then fades out over just that tail with a smoothstep (gentle out of the
        -- hold AND gentle onto zero — no abrupt "help vanished" at the very end). Envelope shape over the
        -- 1800ms window with a 900ms tail: 0-500 attack ramp-up, 500-900 held full, 900-1800 smooth fade.
        RecenterDecayMs = 900.0,

        -- SPEED-SCALED RECENTER (2026-08-08). The damping strength scales with
        -- speed so the car centers LATE at low speed (hang the slide out longer,
        -- more playful) and centers EARLY at high speed (bleed the big yaw energy
        -- fast so it doesn't wash out into a spin). YawDampStart above is the
        -- REFERENCE value; these multiply it at each end of the band and lerp
        -- between. Set both to 1.0 to disable speed scaling.
        -- 2026-08-10 v4: user "grip holding needs to be slightly faster on higher
        -- speed" — raised YawDampHighMult 1.8→2.2 so high-speed recovery (180+ km/h)
        -- recenters/grips sooner, bleeds yaw energy faster.
        -- 2026-08-10 v8: user "low-speed 90° corner exit too wide, doesn't straighten
        -- tight enough" — raised YawDampLowMult 0.55→0.90 so low-speed recovery grips
        -- and straightens faster (tighter exit from shizilukou-style corners).
        SpeedScaleEnabled = true,
        SpeedScaleLowKmh  = 60.0,    -- at/below this speed use the Low multiplier
        SpeedScaleHighKmh = 180.0,   -- at/above this speed use the High multiplier. Lowered from 240
                                     -- so full centering strength lands by ~180 instead of 240 —
                                     -- the whole 1xx band now gets meaningfully more recentering
                                     -- (was only partway up the ramp and under-damped).
        YawDampLowMult    = 0.90,    -- low speed: stronger damping (was 0.55, now tighter exit)
        YawDampHighMult   = 2.2,     -- high speed: stronger damping = recenters EARLY (was 1.8)

        -- SOFT-KICK (2026-08-10 v22): when the drift is released right after a SPACE-KICK, the
        -- leftover yaw is intentional (you just kicked the tail out) — so recovery scales its
        -- recenter force by this so it doesn't "auto-fix"/slam the rotation flat. Still bleeds SOME
        -- yaw (never a full stand-down) so a kick-and-bail can't spin away. Lower = gentler fixing.
        SoftKickDampMult  = 0.4,

        -- Only damp yaw above this rate (rad/s) — below it the car is basically
        -- straight already and we don't want to fight small natural steering.
        YawDampMinRate = 0.35,

        -- PLAYER-AWARE: if the player is actively countersteering INTO the slide
        -- (helping recenter), scale our damping DOWN by this much at full steer so
        -- their input leads and ours just backstops. 0 = ignore player, 1 = fully
        -- defer to a countersteering player. Gap-fill philosophy.
        -- 2026-08-12 v6.4: REVERTED 0.9→0.6. Raising it to 0.9 made recovery back off so far it
        -- stopped helping save a real slide ("harder to save/correct"). The onset-timing ramp
        -- (RecenterAttackMs) is the correct fix for the "too rapid" feel, not gutting the yield.
        YawDampPlayerYield = 0.6,   -- SUPERSEDED by SteerThrough* below (v7.26); left for reference.

        -- STEER-THROUGH (2026-08-13 v7.26): let steering DIRECT the exit line before the recovery centers.
        -- Backs off BOTH the yaw damp and the slip-smoother proportionally to steer input, so the car
        -- follows the front wheels first and only fully centers as you return to neutral — fixes "on exit
        -- it just goes forward, it should've steered first." STEER-OUT BIASED: strong yield steering OUT
        -- of the slide (guiding the nose / counter-steer), light steering INTO it (holding into the drift
        -- at release can't re-induce a slide — centering still wins there). Each is a 0..1 max yield scaled
        -- by |steer|. Raise Out toward 1.0 for a fully wheel-led exit; lower for more auto-centering.
        SteerThroughYieldOut = 0.85,  -- max yield when steering OUT of the slide (counter / onto new line)
        SteerThroughYieldIn  = 0.30,  -- max yield when steering INTO the slide (kept low = safe, still centers)
        SteerThroughDeadzone = 0.12,  -- |steer| below this = no yield (kills keyboard/stick noise)

        -- GRIP RAMP: over the window, ease the drift grip fields back to stock
        -- instead of restoring instantly. true = gradual (no snap bite), false =
        -- instant restore (old behaviour). The ramp uses this same window.
        GradualGripRestore = true,

        -- GRIP LATERAL-SCRUB GATE (2026-08-13): the fix for "still sliding, release, car auto-adjusts
        -- fast and shoots forward at the angle's center point." The time-based grip ramp above is blind
        -- to how sideways the car still is — releasing mid-slide lets grip climb back on the CLOCK and
        -- bite a still-large lateral velocity, redirecting that sideways scrub into a FORWARD launch
        -- (a real tyre burns it as friction; GTA hooks it up). This gate caps grip return by how much
        -- lateral scrub actually remains: grip returns no faster than the slide bleeds off, so it can't
        -- convert scrub to thrust. Ties restoration to car STATE, not just elapsed time.
        GripLateralGate = {
            Enabled   = true,
            -- v7.25: band widened ~1/3 (6.0→7.5, band 4.5→6.0) so grip returns ~1/3 SLOWER / more gradual
            -- — the residual forward-force onset eases in more, per "cut the forwarding force in slower."
            LatGateMs = 7.5,   -- |lateral| m/s at/above which grip is HELD at drift level (sliding hard)
            LatFullMs = 1.5,   -- |lateral| m/s at/below which grip is fully allowed to return (near straight)
        },

        -- GRIP CLOSE GATE (2026-08-13 v7.24): the window-END grip restore used to snap traction-loss to
        -- 1.0 UNCONDITIONALLY when the timer expired — ignoring the scrub gate that held grip low through
        -- the ramp. If the car was still sliding at expiry (more likely now the faster space-cap lets you
        -- hold a wide angle later), that snap hooked the remaining lateral velocity forward = the rare
        -- exit launch that came back. Now the close honors the same scrub allowance: if still sliding, the
        -- window is held open in small steps until the slide bleeds (or the safety extension cap elapses).
        GripCloseAllow      = 0.85,   -- scrub allowance (0..1) required to actually close & restore grip; below this, hold open
        GripCloseHoldMs     = 60.0,   -- how long to extend the window each tick while still sliding at expiry
        GripCloseMaxExtendMs = 1500.0,-- hard safety cap on total extension past DurationMs (a permanent donut can't hold recovery open forever)

        -- Speed gate: below this km/h skip recovery entirely (a low-speed exit
        -- has little yaw energy and instant restore feels fine + more responsive).
        MinSpeedKmh = 25.0,

        -- EXIT SLIP-SMOOTHER (2026-08-12 v7.10): on drift release, GENTLY bleed off the car's SIDEWAYS
        -- (lateral) velocity so the slide settles smoothly onto its own heading instead of leaving the
        -- player to purely catch it. This is NOT a forward push — v7.7's forward nudge burst/felt too
        -- rapid + too early. Instead we only ever REMOVE lateral velocity (the "slip"), never add
        -- forward speed, so it physically CANNOT boost or launch the car. Pure, gentle slip damping.
        -- Uses an exponential bleed (smooth by nature, no step), a DELAYED smoothstep ease-in (so it
        -- doesn't grab the instant you release), and rides the recovery release-tail so it fades out
        -- smoothly. Removes only the lateral component along the ground-plane right vector — z + forward
        -- untouched, so no vertical bounce and no forward surge.
        -- v7.10: GATED now — only fires if the car is ACTIVELY STRAIGHTENING (slip angle dropping).
        -- Prevents the "push during transitions" bug: holding drift + tap A + quick release now doesn't
        -- trigger the smoother because the car is still building/holding angle sideways, not centering.
        ExitNudge = {
            Enabled      = true,
            SlipDamp     = 0.54,   -- v7.10: 0.72→0.54 (−25% more). Per-second fraction of lateral velocity bled at full envelope.
                                   -- Gentle. Higher = firmer/faster settle, lower = looser/longer slide.
            OnsetDelayMs = 250.0,  -- wait this long AFTER release before the smoother starts (fixes
                                   -- "a bit too early" — your own steering owns the first moment).
            EaseInMs     = 960.0,  -- v7.9: 600→960 (+60% slower ramp). Smoothstep ease-IN over this duration so it arrives gradually,
                                   -- never a burst (fixes "too rapid — should release smoothly").
            MinSpeedKmh  = 25.0,   -- below this, no smoothing (low-speed exits don't need it).
            MaxSpeedKmh  = 140.0,  -- above this, fade to 0 (never a high-speed grab).

            -- v7.10 GATE: only fire if the car is ACTUALLY STRAIGHTENING (slip angle dropping, not still building/holding).
            -- Threshold in deg/s: slip must be dropping by at least this much to consider the car "centering."
            StraighteningThreshold = 8.0,  -- deg/s. If slip angle is dropping faster than this, car is centering → smoother fires.
                                           -- Below this rate, car is still sliding/holding sideways → no smoothing (fixes transition push).
        },
    },

    -----------------------------------------------------------------
    -- HIGH-SPEED SLIP GOVERNOR (2026-08-08) — arcade high-speed drift
    -----------------------------------------------------------------
    -- Problem: the drift tune that feels right at ~80 km/h is way too loose at
    -- 160-320 km/h. There's far more yaw energy + lateral velocity up there, so
    -- the rear washes past a holdable angle into a spin. A single fixed tune
    -- CAN'T serve both speeds. Forza's arcade fix: as speed rises, CAP the slide
    -- angle and firm the rear grip back up, turning a high-speed drift into a wide
    -- controllable SWEEP instead of a spin. Runs inside DriftMode_Tick.
    --
    -- Two levers, both scaled by a 0..1 "speed factor" that ramps from LowKmh
    -- (governor off, full loose low-speed drift) to HighKmh (governor at max):
    --   1) grip firm-up: blend the throttle traction-loss back DOWN toward planted
    --      grip so the rear keeps more bite the faster you go.
    --   2) yaw cap: softly damp yaw rate when it exceeds a speed-dependent ceiling,
    --      so the ANGLE stops growing past what's catchable at that speed. Same
    --      only-ever-reduce-yaw safety as the exit recovery (can't flip the car).
    Governor = {
        Enabled = true,

        -- Speed band the governor ramps across (km/h). Below LowKmh = no governing
        -- (keep the tight low-speed drift you already like). At/above HighKmh =
        -- full governing. 320 km/h sits above HighKmh so it's fully governed.
        LowKmh  = 120.0,
        HighKmh = 240.0,

        -- GRIP FIRM-UP: at full speed factor, pull the throttle traction-loss this
        -- fraction of the way back toward the (planted) base loss. 0 = no firm-up,
        -- 1 = high-speed throttle grip == base grip (very planted). This is what
        -- keeps the rear from washing out at speed while staying loose down low.
        GripFirmAtHigh = 0.7,

        -- YAW CAP: reactive angle ceiling. DISABLED 2026-08-08 — it acted AFTER
        -- you were already over-rotating and the hard clamp felt like an invisible
        -- wall fighting your input ("high speed got worse"). The proactive
        -- Config.Drift.InputSuppress (below) prevents the over-rotation up front
        -- instead, so nothing needs catching. Flip true to re-enable as a backstop.
        YawCapEnabled = false,

        -- YAW CAP: max yaw rate (rad/s) allowed before we softly damp, at LowKmh
        -- and at HighKmh. Lower at speed = tighter angle ceiling = wide sweep, not
        -- a spin. These are the "how sideways can you get" limits per speed.
        YawCapLow  = 1.30,   -- rad/s allowed at LowKmh (still very slidey)
        YawCapHigh = 0.55,   -- rad/s allowed at HighKmh (wide controllable sweep)

        -- How hard to damp yaw once it exceeds the cap (per-second coefficient).
        -- Only the OVERSHOOT past the cap is damped, and only ever reduces yaw.
        YawCapDamp = 4.0,

        -- PLAYER-AWARE: countersteering into the slide backs the yaw cap off by up
        -- to this fraction at full steer, so a skilled player can still push a
        -- bigger angle at speed. Same gap-fill philosophy as recovery.
        YawCapPlayerYield = 0.5,
    },

    -----------------------------------------------------------------
    -- INPUT SUPPRESS (2026-08-08) — proactive "how much slide" governor
    -----------------------------------------------------------------
    -- Replaces the reactive yaw cap. Instead of catching an over-rotation after
    -- it happens (which felt like a wall), this scales DOWN how much slide the
    -- drift key induces up front, from three factors, so you never reach the
    -- uncatchable state. Multiplies the drift's EXTRA traction-loss (the part
    -- above the planted base grip) by an intensity 0..1:
    --
    --   * SPEED  — the main lever. Full slide at/below SpeedFullKmh, tapering to
    --              SpeedMinIntensity at/above SpeedZeroKmh. Fixes high-speed washout.
    --   * GEAR   — at the same speed, a LOW gear (high rpm, more torque to the
    --              wheels) drifts livelier than a TALL gear (cruising). Current gear
    --              vs the car's top gear -> low gear keeps intensity, tall gear eases it.
    --   * ANGLE  — self-limiter: the more sideways you ALREADY are (yaw rate), the
    --              less extra slide the key adds, so the car eases toward a holdable
    --              angle and stops instead of rotating further the longer you hold.
    --
    -- The three combine multiplicatively but each is floored so one factor can't
    -- kill the drift entirely. Flick transitions are applied AFTER this, so a
    -- direction change still breaks the rear loose even when the angle limiter is
    -- easing a held slide.
    InputSuppress = {
        Enabled = true,

        -- SPEED factor
        -- 2026-08-10 v3: user "65-135 km/h corner turn too strong, easy to slide out
        -- after 4-5 flicks" — raised SpeedFullKmh 90→110 so the MID-SPEED band (65-135)
        -- gets suppression earlier (it was still in the "full slide" zone below 90).
        -- This makes the drift key induce LESS rotation in exactly that problem range.
        SpeedFullKmh    = 110.0,  -- at/below this, full slide (was 90.0)
        SpeedZeroKmh    = 300.0,  -- at/above this, slide is squeezed to SpeedMinIntensity
        SpeedMinIntensity = 0.35, -- floor: even at 300+ the key still induces THIS much slide

        -- GEAR factor (needs current gear + the car's top gear)
        GearEnabled     = true,
        GearLowIntensity  = 1.0,  -- intensity multiplier in 1st/low gear (full liveliness)
        GearHighIntensity = 0.6,  -- intensity multiplier in the top gear (calmer)
        -- gears at/below this fraction of top gear get GearLowIntensity; the top
        -- gear gets GearHighIntensity; lerp between. (e.g. 0.3 -> bottom ~30% of the
        -- gear range is fully lively.)
        GearLowFrac     = 0.3,

        -- ANGLE self-limiter (yaw rate in rad/s)
        -- 2026-08-12 GRIP-DRIFT v6: with the yaw servo DEAD, this is now the PRIMARY angle bound
        -- for a drift-key-only slide (there's no controller forcing/capping rotation anymore).
        -- Tightened to plateau the slide at a MODERATE, catchable angle so it sustains instead of
        -- running away into a spinout. The spacebar commit (BoostRelaxSuppress below) relaxes this
        -- ceiling back toward full slide, so BIG NFS-wide angles come from space, not the drift key.
        AngleEnabled    = true,
        AngleFullRate   = 0.30,   -- at/below this yaw, no angle suppression (full slide) — was 0.35
        AngleZeroRate   = 0.85,   -- at/above this yaw, intensity hits the floor — was 1.30 (tightened: bound the default angle sooner)
        AngleMinIntensity = 0.30, -- floor: a big existing slide still lets SOME extra through — was 0.25

        -- SPACEBAR COMMIT (2026-08-12 GRIP-DRIFT v6): how far a full space commit relaxes ALL the
        -- above suppression back toward full slide. 1.0 = a full commit lifts the ceiling entirely
        -- (widest NFS angle); lower = space opens the angle less. Scaled by the live boost amount,
        -- so a tap = momentary partial lift, holding space = sustained full lift.
        BoostRelaxSuppress = 1.0,
    },

    -----------------------------------------------------------------
    -- LARGE-ANGLE GRIP FIRM-UP (2026-08-12 GRIP-DRIFT v6.1)
    -----------------------------------------------------------------
    -- Fixes "rear gives out too much at a larger corner angle / when the drift key is held slightly
    -- too long" — the slide ran away instead of plateauing because nothing firmed the rear BELOW
    -- base grip. As the real slip angle grows past StartDeg, this pulls the traction-loss down toward
    -- FirmTarget (below base = rear regains bite), reaching full pull at FullDeg. Pure negative
    -- feedback on the measured slip angle = stable, no forced yaw. A spacebar commit RELAXES it
    -- (CommitRelax) so a deliberate wide slide isn't fought. Applied to the HELD slide after the
    -- commit grip-drop, before the flick boost (so flick transitions can still break the rear loose).
    -- 2026-08-12 GRIP-DRIFT v6.4: user "on JUST holding the drift key I shouldn't be able to slide
    -- more than ~35° either side, maybe less — the degree only ramps up on SPACE." The v6.3 firm-up
    -- was too SOFT: it pulled grip toward 0.60, which still lets the rear slide, so it never actually
    -- CAPPED the angle (why it "wasn't halved"). Now it's a real grip WALL: as the slip angle nears
    -- FullDeg the rear regains FULL native grip (FirmTarget 1.0), so the angle physically stops
    -- growing — a hard-ish ceiling at ~FullDeg. Space commit still fully relaxes it (CommitRelax 1.0)
    -- so tap/hold space is the ONLY way past the cap (exactly the user's ask). Lower FullDeg = tighter.
    -- 2026-08-12 v6.5 — CRITICAL DIRECTION FIX. Traction-loss: LOWER value = MORE grip, higher =
    -- more slide (base drift = 0.79). To ARREST a slide the firm-up must pull loss DOWN (grippier),
    -- not up. v6.4's FirmTarget=1.0 was ABOVE base AND equal to what ThrottleSustain already sets on
    -- gas, so the firm-up did nothing = "no cap, keeps sliding off, counter-steer has no grip to bite".
    -- Now FirmTarget=0.50 (well below base 0.79) so at the cap the rear regains STRONG grip and the
    -- angle physically stops. CommitRelax lowered 1.0→0.55 so even a full space commit only PARTIALLY
    -- lifts the cap (keeps 45% of the grip wall) — a full lift + BoostGripDrop was instant-spinning.
    -- 2026-08-12 v6.7: user "halve the cap again, and it still slides past 26° L/R." Two changes:
    -- (1) halved the cap band — FullDeg 26→13, StartDeg 11→6 (drift-key-only now caps ~13° from
    -- center). (2) the slide was OVERSHOOTING the cap because FirmTarget 0.50 only slowed the slide,
    -- didn't fully stop it — dropped FirmTarget 0.50→0.30 so the rear grips HARD at the limit and the
    -- angle actually stops instead of creeping past. Space commit (CommitRelax 0.90) still lifts the
    -- cap to go wide on demand.
    AngleFirmUp = {
        Enabled     = true,
        StartDeg    = 5.0,    -- below this slip angle: free slide (no firm-up)
        FullDeg     = 24.850, -- v7.23: base +6% (MinFullDeg→11.235) AND space-added RANGE cut 15%: was range 16.018 → 13.615, so 11.235+13.615=24.850. Space OPENS the cap to this (space-hold max angle).
        MinFullDeg  = 11.235, -- v7.23: 10.599 + 6% (BASE cap, drift-key held alone). FullDeg is the WIDE (space commit).

        -- v7.25 SECOND-TIER TAPS: hold/tap tier-1 maxes at FullDeg (above) UNCHANGED. Once maxed, each
        -- ADDITIONAL space TAP extends the cap this many degrees BEYOND FullDeg, up to ExtraMaxDeg total.
        -- Lets a held drift clear most corners but require taps for extra angle on the tight ones. Eases
        -- in/out with the same CommitApplyRise/Fall smoothing as tier-1; collapses on space release.
        ExtraStepDeg = 2.0,   -- degrees added per extra tap beyond FullDeg
        ExtraMaxDeg  = 20.0,  -- hard cap on total extra beyond FullDeg (so max reachable = FullDeg + this)
        FirmTarget  = 0.45,   -- grip firm-up toward the cap (the YAW LIMITER below does the hard cap now)
        Strength    = 1.0,    -- 0..1 overall strength of the pull toward FirmTarget

        -- v7.10: UN-INVERTED back to original v6 behavior. Space now OPENS the cap for wider freedom (MinFullDeg→FullDeg).
        -- Drift-key alone = tight default (MinFullDeg ~10°). Tap/hold space = progressively opens toward wide (FullDeg ~26.7°).
        CommitStepDeg    = 2.0,   -- v7.18: 5.0→2.0. Finer discrete click per TAP AND smaller initial hold-pop (the visible "steps" were the chunky 5° increments — taps stair-stepped and a hold jumped 5° on the first frame).
        CommitHoldRampMs = 600,   -- v7.16: 1000→600 (40% faster). Hold space: 0→1 TARGET ramp over this duration (continuous open beyond taps)
        CommitStepDecayMs = 800,  -- taps linger: one discrete step decays every this many ms (committed decisions)
        CommitHoldDecayMs = 400,  -- hold releases faster: TARGET ramp decays over this duration (active pressure)

        -- v7.14 SMOOTH ENGAGEMENT: the cap doesn't read the tap/hold TARGET directly (that bursts on a
        -- tap). Instead a smoothed applied value EASES toward the target — slow up, fast down:
        CommitApplyRiseMs = 120,  -- v7.23: 330→200→120. Space tap/hold felt delayed (target jumps instantly, applied cap eased over the old 330ms). Now prompt; the ease-in shape below keeps a soft onset so 120ms doesn't pop.
        CommitRiseFloorMult = 0.25, -- v7.23 ease-in: approach rate at the START of the open = this × full, ramping to 1.0 → "slow raise first then faster." Lower = softer onset / more pronounced acceleration; 1.0 = old linear-rate feel.
        CommitApplyFallMs = 180,  -- applied cap eases DOWN toward target over ~this long (fast close on release)

        MinSpeedKmh = 20.0,   -- skip at crawl (low-speed pivots handled by the throttle gate elsewhere)

        -- 2026-08-12 v6.8 YAW LIMITER — the actual hard cap. Grip modulation alone couldn't arrest an
        -- already-rotating car (drift tyres + momentum), so past FullDeg this directly scrubs the EXCESS
        -- yaw (only-ever-reduce, same safe mechanism as the flick/recovery bleeds — NOT the abandoned
        -- servo, which added rotation). This is what makes ~FullDeg a real wall. Now TIGHTENS with space.
        YawLimit     = true,
        YawLimitDamp = 7.0,   -- how hard to scrub yaw past the cap (higher = firmer wall). Scales with how far past effectiveFullDeg.
        -- NOTE (v7.18): the up/down bounce this limiter seemed to cause is actually the shared setYaw
        -- write clobbering suspension pitch/roll on bumps — fixed globally by Config.Drift.BumpGuardRate.
    },

    -----------------------------------------------------------------
    -- COUNTER-STEER ASSIST (2026-08-08) — gap-fill auto-catch
    -----------------------------------------------------------------
    -- GTA drifting is hard because you must feed exact opposite-lock manually and
    -- keyboard steer is DIGITAL (full/off, no fine angle). This assist computes
    -- the IDEAL opposite-lock steering angle from the current yaw/slide, then only
    -- supplies the GAP between what the player is already inputting and that ideal.
    --
    --   * not countersteering -> assist supplies most of the catch (feels auto)
    --   * countersteering hard -> assist backs off, player input leads (skill wins)
    --
    -- So it HELPS without fighting: a player who countersteers correctly barely
    -- feels it; a player who doesn't gets saved from spinning. Only ever steers
    -- toward the slide (opposite lock) — never adds lock INTO the spin.
    --
    -- Keyboard players can't modulate (digital A/D) so they get a stronger assist
    -- than analog wheel/pad users, auto-detected each frame.
    -- DRIFT STEERING INPUT SHAPER (2026-09-06) — the fix for the long-standing "A/D feels like a
    -- noclip heading SNAP in drift." In drift mode the normal keyboard steering model is SKIPPED, so
    -- the front wheels get RAW BINARY A/D (instant jump to full lock the moment you tap). With the
    -- rear grip dropped, that instant front angle rotates the car in a single frame = the harsh
    -- "noclip left/right heading turn," and it's why the center + outer have zero smoothing. This runs
    -- a drift-TUNED input smoother on control 59 (keyboard only) so turn-in EASES in (soft center) and
    -- the approach to lock EASES too (smooth outer) instead of snapping. It ONLY shapes the INPUT —
    -- drift's grip-cliff + CounterSteer physics are untouched, and CounterSteer's direct-angle override
    -- still owns the wheel in a committed slide (it already runs on top of control 59 today, so
    -- smoothing 59 introduces no new fight — it just replaces the binary snap the yield/flick logic reads).
    Steering = {
        Enabled     = true,
        -- RAMP TIMES (ms to sweep center->full-lock / full->center). SLOWER than the normal-mode steer
        -- model (420/260) on purpose: in drift the rear is loose, so a fast front angle snaps the tail.
        -- 2026-09-06 v3: user "still too fast — angle should build slowly AND the recovery should HOLD
        -- then wind back so slides are sustainable." Turn-in slowed further (980->1400 = wind the angle
        -- in over time). On RELEASE the angle now FREEZES for HoldMs, THEN recenters over RecenterMs
        -- (hold-then-recenter, see main.lua) — the wheel no longer springs straight back. CounterSteer
        -- still catches a committed slide on top, so slow input can't make it uncatchable.
        SteerInMs   = 1400.0,  -- ms of held A/D to wind from center to full lock (slow build = dial the angle in)
        -- RELEASE ENVELOPE: hold the captured angle, then wind back to center.
        ReleaseHoldMs = 2400.0,-- ms the angle FREEZES after release (the slide sustains at its current angle)
        RecenterMs    = 1200.0,-- ms to actually wind back to center AFTER the hold (the recovery movement)
        -- SPEED-SCALED RATE: multiplier on BOTH rates. 1.0 at/below LowKmh -> HighMult at/above HighKmh.
        -- Slower at speed = calmer, less darty when the car already carries yaw energy.
        SpeedRateLowKmh  = 30.0,
        SpeedRateHighKmh = 160.0,
        SpeedRateLowMult = 1.0,
        SpeedRateHighMult= 0.55,
        -- SOFT CENTER (the "middle slower/smoother"): output = |x|^Gamma * sign. >1 desensitizes the
        -- dead-center band so small inputs produce a gentle, gradual tilt instead of a hard heading kick.
        -- Full lock (|x|=1) is unchanged; only the middle is softened. 1.0 = linear (off).
        Gamma       = 1.5,
        -- OUTER EASE (the "outer smoother"): as the integrator winds OUT past OuterEaseStart, slow the
        -- slew toward OuterEaseMinMult so the wheel GLIDES into full lock instead of slamming the stop.
        -- Only applies while winding out (never on recenter/flick-back). 1.0 mult = no ease.
        OuterEaseStart   = 0.55,   -- |cur| where the outer slowdown begins
        OuterEaseMinMult = 0.45,   -- rate multiplier at full lock (0.45 = ~55% slower into the stop)
    },

    CounterSteer = {
        Enabled = true,

        -- Base fraction of the ideal opposite-lock angle the assist will fill when
        -- the player gives NO steering input. 0 = off, 1 = full auto-catch.
        Strength = 0.55,

        -- Keyboard boost: digital steer can't fine-tune, so multiply Strength by
        -- this when the player is on keyboard/mouse (not a controller/wheel).
        KeyboardStrengthMult = 1.5,

        -- HIGH-SPEED BOOST (2026-08-08): a slide gets away fastest at speed, so ramp
        -- the assist strength UP above SpeedBoostLowKmh, reaching SpeedBoostMult at
        -- SpeedBoostHighKmh. Below the low mark = normal Strength (no extra help).
        -- 2026-08-08 v2: boost now starts at 100 (was 180) so the whole 120-180 band
        -- gets progressively more catch — that range spun out too easily with flat
        -- base strength. SpeedBoostMult raised so the top of the ramp catches harder.
        -- 2026-08-10: raised mult 2.2→2.5 and extended ramp 260→280 for even more
        -- 120-180 controllability (user: "can be higher").
        -- 2026-08-10 v2: user "120-180 still not enough help" — raised mult 2.5→3.0
        -- and lowered start 100→80 so the 120-180 band gets even more of the ramp.
        -- 2026-08-10 v4: user "high speed A/D flick countersteers too fast even on short
        -- tap" — lowered mult 3.0→2.4 so high-speed catch is gentler/smoother, doesn't
        -- snap the angle back too aggressively during intentional flicks.
        SpeedBoostEnabled = true,
        SpeedBoostLowKmh  = 80.0,   -- boost starts ramping here (was 100)
        SpeedBoostHighKmh = 280.0,  -- full boost at/above here
        SpeedBoostMult    = 2.4,    -- Strength multiplier at high speed (was 3.0)

        -- LOW-SPEED REDUCTION (2026-08-08): low speed drifts are slow/controllable, the player
        -- doesn't need much assist. But the old logic BOOSTED strength at low speed (up to 1.3x),
        -- which made free drift mode send the car into tight donut spins at 40-60 km/h — the
        -- counter-steer was fighting the player's manual control too hard.
        -- 2026-08-10 v19: INVERTED the low-speed logic. Now strength REDUCES at low speed (0.3x
        -- at/below 45 km/h, ramping back to 1.0 by 140 km/h). This gives the player full manual
        -- authority at low speed where slides are gentle, and the assist only kicks in harder at
        -- mid/high speed where slides get away fast. Free drift mode now feels controllable at low
        -- speed instead of auto-spinning into donuts.
        LowSpeedReductionEnabled = true,
        LowSpeedReductionKmh     = 140.0,  -- reduction fades out as you accelerate past this
        LowSpeedReductionFullKmh = 45.0,   -- full reduction (0.3x strength) at/below here
        LowSpeedReductionMult    = 0.3,    -- Strength multiplier at low speed (was 1.3 boost, now 0.3 cut)

        -- RUNAWAY CATCH (2026-08-08): the real fix for "controllable window too small".
        -- When yaw exceeds RunawayYaw (~the point the rear passes and starts to spin),
        -- ramp assist strength up by an EXTRA multiplier, reaching RunawayMult at
        -- RunawayYawMax. Below RunawayYaw it does NOTHING, so a mild steady slide is
        -- never glued — this only fights the actual runaway that ends in a spin.
        RunawayEnabled = true,
        RunawayYaw     = 0.65,   -- rad/s where the slide starts running away (extra catch begins)
        RunawayYawMax  = 1.60,   -- rad/s where extra catch hits RunawayMult (full save)
        RunawayMult    = 2.0,    -- extra strength multiplier at RunawayYawMax

        -- How much an actively-countersteering player SUPPRESSES the assist, at
        -- full opposite-lock input. 1 = fully defer to the player (assist -> 0 when
        -- they're steering right into the slide), 0 = ignore player (always assist).
        PlayerYield = 0.85,

        -- Maps yaw rate (rad/s) to a target steering-angle fraction (0..1 of the
        -- car's max steering angle). Higher yaw = more opposite lock wanted. The
        -- ideal angle = clamp(yaw * YawToAngle, 0, MaxAngleFrac).
        YawToAngle   = 0.55,
        MaxAngleFrac = 0.9,   -- never ask for more than 90% of full lock

        -- Gates
        MinYawRate  = 0.30,   -- below this yaw the car's basically straight; no assist
        MinSpeedKmh = 20.0,   -- no assist at crawl (parking manoeuvres)

        -- Smoothing: how fast the applied assist angle eases toward its target
        -- (per-second rate for an exp-smooth). Higher = snappier, lower = softer.
        -- 2026-08-10 v4: user "high speed flicks countersteer too rapid" — lowered
        -- 12.0→8.0 so the assist angle changes more gradually (smoother transitions).
        Smoothing   = 8.0,

        -- PLAYER STEER AUTHORITY (2026-08-08): the "my countersteer doesn't fix the
        -- angle" fix. In drift mode rear grip is dropped, so the FRONT tires also
        -- lack the bite to actually rotate the car straight when you countersteer —
        -- the wheels visually turn to opposite lock but the slide angle won't shrink.
        -- This gives your OWN input real authority: when you steer PAST the angle
        -- needed to merely HOLD the current slide (idealAngle), bleed yaw in
        -- proportion to that EXCESS opposite-lock. Holding ideal = sustain (no
        -- change); cranking beyond it = straighten, like real front-end grip would.
        -- Only ever REDUCES |yaw| (same safety as recovery/governor) — never injects
        -- a spin, never flips. Gated to the player actually countersteering.
        -- 2026-08-10 v3: user "35-45° tilt can't catch back with manual countersteer" —
        -- raised Gain 3.0→5.0 (stronger yaw bleed per unit of excess opposite-lock) so
        -- the player's own A/D input has more power to straighten a mid-angle slide.
        PlayerAuthorityEnabled = true,
        PlayerAuthorityGain    = 5.0,   -- yaw-bleed strength per unit of excess opposite-lock (was 3.0)
        PlayerAuthorityMaxDamp = 6.0,   -- cap on the per-frame damp coefficient (exp), safety
        PlayerAuthorityDeadzone= 0.08,  -- ignore tiny excess (fraction of full lock) — no jitter

        -- Apply only while drift mode is held? true = drift-only (safest, no effect
        -- on normal driving). false = also assist normal-driving slides (e.g. after
        -- the drift-key recovery). Keep true unless you want always-on catch.
        DriftOnly   = true,
    },

    -----------------------------------------------------------------
    -- POWER ASSIST (2026-08-08) — throttle-scaled slide sustain
    -----------------------------------------------------------------
    -- Problem: a slide SCRUBS speed (sideways tires bleed momentum), so below
    -- ~60 km/h the car slows past the point the rear can stay loose, grip snaps
    -- back and the drift dies. Native lsdrift-style scripts feed drive force to
    -- keep the rear spinning. We do the same BUT scaled by the player's ACTUAL
    -- throttle — no gas = no push, more gas = more sustain. It's an assist ON
    -- your input, never a replacement (no straight-line auto-nitro).
    --
    -- Applied as a local-forward force via ApplyForceToEntity, mass-relative so
    -- it feels identical on a light car and a heavy one. Gated to a real drift
    -- (throttle held + actually sliding sideways) and strongest at low speed,
    -- fading out by FadeHighKmh so it never adds top-end shove.
    -- MODEL (2026-08-08 rev): "continuable", not "auto-sliding". A slide SCRUBS
    -- forward speed (sideways tires bleed momentum); once the car slows past the
    -- point the rear can stay loose, grip re-catches and the drift ENDS. So the
    -- drift isn't continuable — you can't keep it alive by managing throttle.
    -- The FIX is to COMPENSATE the scrub, NOT add energy: each frame, measure the
    -- forward speed LOST since last frame and give back only a fraction of it,
    -- capped so total forward speed can NEVER rise above what you already had.
    -- Result: the drift stops decaying on its own (you can hold/link it on the
    -- gas), but power can't make it slide MORE than a real drift, and lifting off
    -- lets it settle. Scaled by throttle so it's still an assist on YOUR input.
    PowerAssist = {
        Enabled = true,

        -- Gate: only compensate when the player is ON the gas and actually sliding.
        -- ThrottleGate = min throttle (0..1). YawGate = min |yaw| (rad/s) that
        -- counts as sliding, so it never fires in a straight line.
        ThrottleGate = 0.15,
        YawGate      = 0.30,

        -- Recover: fraction of the per-frame forward-speed LOSS to give back
        -- (0..1). 1.0 would fully cancel scrub (drift never slows); lower lets it
        -- gently bleed so it's continuable, not eternal. Scaled by throttle after.
        Recover      = 0.85,

        -- Hard ceiling: never let the assist push forward speed above this multiple
        -- of the forward speed measured LAST frame. Guarantees it compensates, and
        -- cannot accelerate the car. Keep at ~1.0 (1.0 = "hold, never gain").
        MaxGainMult  = 1.0,

        -- Speed fade: full at/below FadeLowKmh, tapering to zero at FadeHighKmh so
        -- it's a LOW-SPEED sustain (where slides die), not a high-speed effect.
        FadeLowKmh   = 55.0,
        FadeHighKmh  = 130.0,

        -- Yaw scale: more compensation as the angle grows (a committed slide gets
        -- sustained, a tiny wiggle barely any). Reaches full at YawFull.
        YawFull      = 0.90,

        MinSpeedKmh  = 8.0,   -- below this the car's basically stopped; no assist
    },

    -----------------------------------------------------------------
    -- IN-DRIFT TRANSITION (2026-08-08) — flick direction mid-drift
    -----------------------------------------------------------------
    -- The original complaint: hard to change direction mid-drift (figure-8 /
    -- S-curve / linked drifts). Physics research: a transition is REDIRECTED yaw
    -- MOMENTUM, not re-broken grip — but the rear has to briefly let go so the
    -- car's own momentum can swing to the new side. If the rear stays planted
    -- when you flick, the car keeps sliding the old way (won't rotate).
    --
    -- Detection = a STEERING REVERSAL: the player swings steer from one side
    -- through center to the other while already sliding. On that reversal we open
    -- a short window that DROPS rear grip (raises traction-loss) so momentum
    -- carries the tail across, then it closes and normal drift grip resumes.
    --
    -- SAFETY: we only ever REDUCE grip briefly — we never inject yaw/torque — so
    -- the worst case is a touch more looseness for a few hundred ms, which the
    -- recovery + governor already handle. It cannot spin the car on its own.
    Transition = {
        Enabled = true,

        -- A flick is detected when steer crosses from beyond +Thresh to beyond
        -- -Thresh (or vice-versa) within DetectMs. Keyboard steer is DIGITAL
        -- (full -1/0/+1) so a flick is a clean sign flip; wheel/pad needs a real
        -- swing, hence the threshold.
        SteerThreshold = 0.35,   -- must pass beyond +/- this on each side to count
        DetectMs       = 450,    -- max time between the two sides to count as one flick (2026-08-12 v6.3: 350→450 so a slightly slower sway still registers as a flick and gets the yaw-scrub, instead of missing the window and letting yaw run free = spin on the 3rd sway)

        -- Only allow transitions while genuinely sliding — no point loosening the
        -- rear when the car is basically straight. Gate on current yaw rate.
        MinYawRate = 0.30,       -- rad/s of existing rotation required to arm a flick

        -- The assist window once a flick fires.
        WindowMs   = 260,        -- how long the grip drop lasts
        LossBoost  = 0.6,        -- ADDED to traction-loss during the window (higher = looser
                                 -- rear = swings across more eagerly). Added on top of the
                                 -- normal drift loss, clamped by LossCeiling.
        LossCeiling = 2.4,       -- never let the windowed loss exceed this (anti-spin clamp)

        -- Speed gate: transitions matter most at mid speed. Below this, the
        -- low-speed drift is already flickable enough; skip to stay tight.
        MinSpeedKmh = 30.0,

        -- YAW BLEED during the transition window (2026-08-08). Without it, each flick
        -- ADDS angular momentum on top of the old spin instead of REPLACING it — so
        -- after 2-3 direction changes (left→right→sharp-turn) total |yaw| is huge and
        -- the car spins out. Real flicks involve weight transfer that scrubs the old
        -- momentum AND redirects to the new side; we're only doing redirect (grip drop).
        -- Fix = damp yaw during the flick window to bleed the old spin so the new input
        -- starts clean. Same SetEntityAngularVelocity(z*factor) the recovery uses — can
        -- only reduce |yaw|, never flips sign. Fires ONLY for ~200ms on flick detection,
        -- not continuously, so it doesn't interfere with holding a slide.
        -- 2026-08-10: raised 5.0→8.0 (user: still bleeds out after 3-4 flicks).
        -- 2026-08-12 v6.3: raised 8.0→11.0 (user: "can't sway more than TWICE before it spins out").
        -- Each reversal must scrub MORE of the accumulated spin so the next sway starts clean.
        YawBleedEnabled = true,
        YawBleedDamp    = 11.0,  -- damp coeff (exp): how fast to bleed old spin (higher = faster)

        -- POST-FLICK DRIVE-OUT (2026-08-08). After a clean direction change the car
        -- has scrubbed speed (grip-drop + yaw bleed), so it bogs on the new heading.
        -- This arms a short window AFTER the grip-drop closes where PowerAssist is
        -- allowed to add a little NET forward push (not just scrub-compensation) so
        -- you can drive OUT onto the new line — the real "get back on power to re-load
        -- the rear on the new side" feel. Still throttle-scaled: no gas = no boost.
        PostFlick = {
            Enabled    = true,
            DurationMs = 500,    -- how long the boost lasts after the grip-drop window closes
            Boost      = 1.6,    -- PowerAssist gain multiplier during the window (>1 = net push)
            GainMult   = 1.05,   -- raises PowerAssist's speed ceiling this much during the window
                                 -- (lets it add a SMALL net speed, ~5%, to carry onto the new line)
        },
    },

    -----------------------------------------------------------------
    -- HIGH-SPEED STABILIZER (2026-08-10) — "drift less, slide more"
    -----------------------------------------------------------------
    -- Problem (160-240 km/h): car bleeds out after 1-2 flicks, and when it goes it
    -- goes FAST — the controllable window is tiny. User wants "drift less (angle),
    -- slide more (lateral motion)" with linear/point-to-point tracking like NFS No
    -- Limits, where the car can be SIDEWAYS but velocity stays on the racing line.
    --
    -- Research insight (NFS): "drifting by itself does not slow your car, only
    -- turning left or right does" — drift ANGLE is decoupled from velocity vector.
    -- The more extreme the angle the more nitro, but speed loss = steering input
    -- magnitude, not slide itself. Players modulate angle to stay below the
    -- speed-bleed threshold → visually dramatic but trajectory stable.
    --
    -- Implementation: at 160+ km/h, apply a gentle continuous YAW CAP (not reactive
    -- like the old Governor yaw cap that felt like a wall, but a soft linear drag on
    -- rotation rate) so the car can hold a big VISUAL angle but yaw rate stays low →
    -- tracks smoothly instead of whipping around. The "drift angle ≠ spin rate"
    -- decoupling. This is an ARCADE DIRECTOR that enforces stable high-speed slides,
    -- philosophically different from the physics-driven counter-steer (which still
    -- runs and helps RECOVER). This PREVENTS the runaway from starting.
    Stabilizer = {
        Enabled = true,

        -- Speed band: no stabilization below StartKmh (keep mid-speed playful), full
        -- at/above FullKmh. The 160+ band gets progressively more linearization.
        -- 2026-08-10 v2: user "allow unlimited speed cap" — removed FullKmh ceiling,
        -- now it's StartKmh 160 and ramps continuously upward with speed (no cap) so
        -- 300+ gets even stronger stabilization than 240. The faster you go, the more
        -- the director keeps you linear.
        -- 2026-08-10 v5: user "orbit nose center point needs to move forward at high speed"
        -- for NFS-style point-to-point drifting — lowered StartKmh 160→130 so the "pivot
        -- forward" effect begins earlier in the speed band. Added SpeedScaleExponent 1.8
        -- for exponential ramp (mild at 130-160, aggressive at 200+, smooth between).
        -- 2026-08-10 v6: user "too late to come out, should start at 65kmh slow then ramp
        -- to 95+" — lowered StartKmh 130→65 and FullKmh 280→95 so the effect begins much
        -- earlier (mid-speed cornering) and reaches full strength by ~95 km/h. Lowered
        -- exponent 1.8→1.3 (gentler curve) and raised threshold 0.18→0.30 so it only
        -- suppresses LARGER rotations (lets you turn corners, only caps tail-swing/spin).
        -- 2026-08-10 v7: user "65 start fucked up low-speed drift, but high-speed close" —
        -- raised StartKmh 65→100 and FullKmh 95→180 for a LONG transition blend (100-180),
        -- keeps 40-95 playful/untouched, high-speed gets smooth ramp. Added PlayerYieldEnabled
        -- to gate stabilizer on steering intent: backs off when player steers INTO the slide
        -- (turning), only caps when countersteering/neutral (holding angle). Keyboard digital
        -- input handled via deadzone (±0.1) so tap corrections don't disable the cap.
        -- 2026-08-10 v12: user "vectoring drift should activate from 0kmh, hard cap angle at
        -- 32% tilt (0.56 rad)" — StartKmh 15→0 so vectoring is always active when drift key
        -- held (handbrake = free drift), and YawDragThreshold 0.38→0.19 (HALF) so angle cap
        -- is ~32% tilt max (0.56 rad yaw rate ~= 32° visual slide angle at typical drift speed).
        StartKmh = 0.0,         -- vectoring active from 0kmh (was 15)
        FullKmh  = 180.0,       -- full strength here, long blend 0-180
        SpeedScaleExponent = 1.3, -- power curve: gentler exponential

        -- YAW DRAG: continuously damp yaw rate above DragThreshold (rad/s) by this
        -- exponential factor per frame. Unlike the counter-steer (which fills a gap
        -- toward an ideal angle), this is a gentle LINEAR DRAG on rotation itself —
        -- the higher |yaw|, the more it bleeds per frame. Keeps slides SMOOTH.
        -- Low values (3-6) feel natural; high (10+) lock the heading hard.
        -- 2026-08-10 v2: user "doesn't feel like it's kicking in" — raised damp 5.0→10.0
        -- and lowered threshold 0.40→0.25. BUT v3: 10.0 caused vehicle shaking/front-end
        -- lift (physics instability from too-aggressive yaw correction) — backed down to
        -- 7.0 as a middle ground (still stronger than original 5.0, but stable).
        -- 2026-08-10 v5: user wants "pivot forward" feel at 130+ km/h — raised damp 7.0→9.0
        -- (stronger rotation suppression) and lowered threshold 0.25→0.18 (engages earlier).
        -- 2026-08-10 v6: user "capping too much manual steer, can't turn corners" — raised
        -- threshold 0.18→0.30 (only caps LARGE yaw/spin, lets cornering rotation through)
        -- and lowered damp 9.0→6.0 (gentler suppression when it does engage).
        -- 2026-08-10 v7: user "limits too much, slide angle needs bigger to push forward" —
        -- raised threshold 0.30→0.38 (lets more tail-swing through, bigger visual angle)
        -- and lowered damp 6.0→5.0 (gentler cap, less fighting manual steer).
        -- 2026-08-10 v12: user "32% tilt cap max for vectoring drift" — threshold 0.38→0.19
        -- (HALF the cap) so vectoring mode limits to ~32% tilt / 0.56 rad yaw max.
        -- 2026-08-10 v14: yaw-rate cap RETIRED for vectoring — replaced by the SLIP-ANGLE
        -- servo below (SlipVectoring). Yaw drag remains only as a fallback if SlipVectoring
        -- is disabled. Threshold raised back so it doesn't fight the slip servo.
        YawDragThreshold = 0.60,  -- fallback only (slip servo owns vectoring now)
        YawDragDamp      = 1.8,   -- damp coeff (exp): VERY gentle continuous drag

        -- SLIP-ANGLE VECTORING (2026-08-10 v14): the CORRECT drift model. Instead of capping
        -- how FAST the car spins (yaw rate), we manage the SLIP ANGLE — the angle between where
        -- the car POINTS (heading) and where it's actually MOVING (velocity vector). That gap IS
        -- the drift. atan2(lateralSpeed, forwardSpeed) measures it directly.
        --
        -- Model:
        --   1) Steer input rotates the car's heading away from its velocity -> creates slip angle
        --      (the car goes sideways while still traveling along its curving path = SLIDING).
        --   2) Slip angle is CAPPED at MaxSlipDeg (32% tilt ~= 29 deg). Past the cap we apply a
        --      counter-yaw so it can't grow further -> never spins to a circle.
        --   3) A forward push along the VELOCITY direction sustains speed (the "goes forward while
        --      angled" feel) so the slide doesn't bog down.
        --   4) When steer releases, the heading springs BACK toward the velocity vector (slip
        --      decays to 0) -> self-recovers within the capped range.
        SlipVectoring = {
            Enabled = true,
            -- MAX slip angle in degrees. 32% tilt: tan(angle)=0.32 -> ~17.7 deg is "32% grade",
            -- but user means ~32% of a 90 deg spin visual = ~29 deg. Use 29 deg as the ceiling.
            MaxSlipDeg = 29.0,       -- hard cap on heading-vs-velocity angle (the visual drift angle)
            MinSpeedKmh = 8.0,       -- below this speed, no slip vectoring (parking/idle, atan2 noisy)

            -- STEER -> SLIP: how strongly steering input builds the slip angle. Higher = reaches the
            -- cap faster / smaller steer input needed. Scaled by speed so it's controllable.
            -- 2026-08-10 v15: slowed build/return by 80% (6.0->1.2, 4.5->0.9) so the transitions
            -- are smooth and controllable instead of snappy/flicking. Steer hold accumulates angle,
            -- steer tap adds angle, opposite steer reduces angle — all gradual.
            -- 2026-08-10 v16: slowed another 12% (1.2->1.056, 0.9->0.792) for even smoother control.
            SteerToSlip = 1.6,       -- steer input (0..1) * this = target slip fraction of MaxSlip
            SlipBuildRate = 1.056,   -- how fast actual slip approaches the target (per sec, was 1.2)
            SlipReturnRate = 0.792,  -- how fast slip decays back to 0 when steer released (per sec, was 0.9)

            -- YAW SERVO: the force that rotates the body to achieve the target slip. Pushes yaw
            -- toward the slip target and HARD-STOPS at the cap (counter-yaw past MaxSlipDeg).
            -- 2026-08-10 v15: reduced servo gain 3.2->1.8 so rotation is smoother, less aggressive.
            -- 2026-08-10 v16: reduced another 12% (1.8->1.584) for even smoother rotation.
            -- 2026-08-10 v18: converted to a PD servo. YawServoDamp brakes the approach so it
            -- SETTLES on the target instead of overshooting + cap-slamming (the "one stage bounce").
            -- ServoAuthority blends our correction into the game's yaw instead of overwriting it,
            -- which cuts the "way too much force" sideways torque. Lower = the game keeps more physics.
            -- 2026-08-10 v24: SlipBuildRate reduced 45% (6.0->3.3) for slower drift engagement on first click.
            -- SERVO BOUNCE FIX (2026-08-12 v3 — GAIN REDUCTION, replaces the failed slew-limiter).
            -- The v2 slew-limiter made the up/down bounce WORSE: rate-limiting the OUTPUT of a
            -- closed-loop controller adds LAG, which destabilizes the feedback loop (same failure
            -- mode as the D-filter tamer). A PD servo rings when P-gain is too high or D-damping too
            -- low relative to the disturbance rate — the terrain bumps inject fast disturbances the
            -- loop can't track, so it oscillates. FIX: CUT THE GAINS so it's critically damped:
            -- lower P (YawServoGain), raise D (YawServoDamp), lower blend (ServoAuthority). Gentler
            -- servo = still steers the slip angle, doesn't ring on bumps. Tune: if it still bounces,
            -- lower Gain / raise Damp more; if drift feels too weak, nudge Gain back up.
            YawServoGain  = 1.05,    -- P term (was 1.584): lowered ~34% to stop ringing on bumps
            YawServoDamp  = 0.70,    -- D term (was 0.40): raised to brake slip velocity harder = damped
            ServoAuthority = 0.30,   -- 0..1 blend (was 0.45): gentler nudge, game keeps more physics
            CapCounterGain = 3.0,    -- counter-yaw strength when slip exceeds the cap (was 5.0, softened)

            -- YAW-RATE FORCE SERVO (2026-08-12 v5): replaces SetEntityAngularVelocity for the slip
            -- servo. Two equal/opposite local lateral forces at front/rear create a yaw moment
            -- without overwriting pitch/roll physics. It is a VELOCITY servo: drives toward a
            -- capped TARGET yaw rate (force ∝ targetYawRate - currentYawRate), so force → 0 at the
            -- target and BRAKES on overshoot — it cannot wind up into a circle like the v4 actuator
            -- (which pushed force ∝ desired-change and accumulated momentum into a full spin).
            -- Independently gated by all-wheels, collision cooldown, and stricter pitch/roll limits.
            -- Set false to return to stable standalone grip drift while keeping the target calc.
            YawTorqueEnabled     = false,    -- DISABLED 2026-08-12: v5 rate-servo still doughnuts at low speed (yaw-force→pirouette, no lateral coupling). Forced-yaw vectoring abandoned; see memory. Reverts to stable standalone grip drift.
            YawTorqueTargetGain  = 2.2,      -- slipErr(rad) -> desired yaw rate (rad/s); how eagerly it vectors
            YawTorqueYawCeiling  = 1.6,      -- HARD max |yaw rate| the servo will ever drive (rad/s) = spin guard
            YawTorqueForceGain   = 1600.0,   -- N per rad/s of yaw-rate error (conservative start after circle bug)
            YawTorqueMaxForce    = 3000.0,   -- cap each opposing force (never mass-scaled)
            YawTorqueArm         = 1.15,     -- local longitudinal force offset (metres)
            YawTorqueMaxPitchDeg = 6.0,      -- tighter than general stabilizer gate
            YawTorqueMaxRollDeg  = 10.0,
            YawTorqueReentryMs   = 350.0,    -- fade torque back after terrain/contact gate opens
            -- 2026-08-10 v25: the SAFETY hard-stop ceiling is a FIXED multiple of MaxSlipDeg, not the
            -- decaying boost ceiling. Must sit at/above the peak boost (BoostMult 1.45) so a car at a
            -- boosted angle isn't slammed back when the boost decays. 1.6 > 1.45 = safe margin.
            CapCeilingMult = 1.6,    -- hard-stop at MaxSlipDeg × this (29° × 1.6 ≈ 46°, above boost's 42°)

            -- SLIP BUILD/RETURN RATES (2026-08-10 v24): SlipBuildRate controls how fast the target
            -- slip angle grows when you steer. Lower = slower drift engagement, gentler initial rotation.
            SlipBuildRate  = 3.3,    -- approach rate when building slip (was 6.0, reduced 45%)
            -- 2026-08-10 v27: SlipReturnRate lowered 4.5→2.3 so the angle centers back SLOWER when
            -- you let off A/D (the slide winds out more gradually). Simple exponential spring-back.
            SlipReturnRate = 2.3,    -- return rate when steering released (lower = slower centering)

            -- SPEED-SCALED BUILD RATE (2026-08-10 v26): the angle should build SLOWER as speed rises
            -- (a fast car shouldn't snap sideways). The build rate scales from full at BuildRateLowKmh
            -- down to (rate × BuildRateHighMult) at BuildRateHighKmh. Return/spring-back is unaffected.
            BuildRateLowKmh  = 60.0,  -- full build rate at/below this speed
            BuildRateHighKmh = 180.0, -- fully scaled-down build rate at/above this speed
            BuildRateHighMult = 0.82, -- build 18% slower at high speed (1.0 - 0.18)

            -- LOW-SPEED SLOWDOWN (2026-08-10 v31): below ~45 km/h the angle ramped up WAY too
            -- fast (snaps sideways at parking-lot speed) — on RWD too, not just AWD. Scale the
            -- build rate down 68% at/below BuildRateVLowKmh, easing back to full by
            -- BuildRateVLowFullKmh. Runs on TOP of the high-speed scale above. Return unaffected.
            BuildRateVLowKmh     = 45.0,  -- at/below this = full slowdown
            BuildRateVLowFullKmh = 70.0,  -- at/above this = no low-speed slowdown
            BuildRateVLowMult    = 0.32,  -- 68% slower at very low speed (1.0 - 0.68)

            -- LOW-SPEED ANGLE CAP (2026-08-10 v33): below ~25 km/h the slide still reached too
            -- WIDE an angle (slid out at 10 km/h). This caps the slip CEILING (max angle) at crawl
            -- speed, not just the build rate — 45% of full angle at/below LowCapKmh, easing to full
            -- by LowCapFullKmh. Applied before the boost mult so a kick from a crawl can't fling it.
            -- 2026-08-11: even WITH throttle, sub-30 km/h swung too aggressively (the ceiling the
            -- throttle gate opened back up was still a wide slide angle, and it ramped to full by
            -- 45 so 30 was already loose). Tightened: much smaller ceiling at crawl (0.45→0.25) and
            -- the capped band stretched up (25/45 → 35/60) so the whole sub-30 range stays tight and
            -- eases into full angle more gradually. This governs the MAX low-speed slide angle for
            -- BOTH on- and off-throttle (the throttle gate multiplies on top of this).
            LowCapKmh     = 35.0,  -- at/below this = tightest angle cap
            LowCapFullKmh = 60.0,  -- at/above this = full angle allowed
            LowCapMult    = 0.25,  -- 25% of MaxSlipDeg at/below LowCapKmh (was 0.45 — too wide)

            -- LOW-SPEED THROTTLE GATE (2026-08-11): stop the Yangwang-U8 / G-wagon "tank-turn" —
            -- at crawl speed, just holding A/D with NO throttle would drive the slip ceiling up and
            -- pivot the car sideways in place. A real drift needs POWER to break the rear loose down
            -- low. This gates the slip CEILING by throttle when slow: 0 gas + slow → ~no slide
            -- (LowThrottleGateFloor of the ceiling = basically normal steering), full gas → full
            -- ceiling (low-speed donuts still work). The gate fades out by LowThrottleGateFullKmh so
            -- momentum/lift drifting at speed is UNTOUCHED. Raise the KmH values to gate a wider
            -- low-speed band; lower the Floor toward 0 to kill the off-throttle slide harder.
            LowThrottleGateKmh     = 40.0,  -- at/below this = fully throttle-gated (need gas to slide)
            LowThrottleGateFullKmh = 70.0,  -- at/above this = gate off (momentum drift unaffected)
            LowThrottleGateFloor   = 0.05,  -- slip ceiling at 0 gas when slow (fraction; ~0 = just steers)

            -- THROTTLE-DRIVEN BUILD (2026-08-10 v31): the drift angle builds in proportion to how
            -- hard you're on the gas (a real drift is throttle-driven). At 0 gas the build runs at
            -- BuildThrottleFloor of the rate; full gas = full rate. Floored so light maintenance
            -- throttle still lets the angle build (not a dead zone).
            BuildThrottleFloor = 0.30,    -- min build multiplier at zero throttle

            -- FORWARD PUSH: sustain speed along the velocity vector so the slide "goes forward"
            -- instead of bogging. Throttle-scaled (no gas = no push). Small — just offsets scrub.
            ForwardPush = 1.4,       -- forward force along velocity dir (m/s^2-ish), throttle-scaled
            ForwardPushThrottleGate = 0.15, -- need at least this throttle for the push

            -- FORWARD-PUSH SPEED CEILING (2026-08-13): the push is a propulsive force with no cap of
            -- its own — GTA's native drive force is drag-limited, but this adds ON TOP. Over a long
            -- WOT hold (10s+) it pumps speed PAST where the car should sit, which shoves km/h outside
            -- the band every speed-scaled drift curve (build rate, governor cap, maxSlip, recenter) was
            -- tuned for → they all pin to their high-speed clamp at once = "values go crazy." This is
            -- the ROOT-CAUSE fix: the push may only SUSTAIN a slide (offset scrub), never pump past the
            -- ceiling. Fades out over PushFadeKmh below the cap so it eases off, no hard wall.
            ForwardPushMaxKmh  = 180.0,  -- above this speed the push contributes nothing (0)
            ForwardPushFadeKmh = 30.0,   -- fade the push to 0 across this band below the cap (150→180)
        },

        -- ANGLE HOLDER (2026-08-10 v10): DISABLED — was too aggressive, fought manual control
        -- and bounced to inverted angles. Replaced by very gentle continuous yaw drag above.
        AngleHolderEnabled = false,  -- DISABLE the active servo system
        AngleAccumRate = 0.3,      -- how much of current yaw to blend into target per input (0..1)
        AngleHoldStrength = 2.5,   -- servo gain: how aggressively to push toward target yaw
        AngleReturnRate = 0.015,   -- target decay per frame (at 60fps) once hold expires
        AngleReturnDamp = 1.5,     -- yaw drag during return phase (gentler than hold phase)

        -- PLAYER STEERING YIELD: back off yaw drag when the player is actively steering
        -- INTO the slide (same direction as yaw = trying to turn/rotate more). Only cap
        -- when countersteering (holding angle) or neutral (coasting). Keyboard digital
        -- input handled via SteerDeadzone so tap corrections still register as intent.
        PlayerYieldEnabled = true,
        PlayerYieldSteerDeadzone = 0.1,  -- treat |steer| < this as neutral (keyboard tap noise)
        PlayerYieldAmount = 0.85,        -- how much to back off when steering into slide (0..1)

        -- LATERAL BIAS SHIFT (2026-08-10 v8): DISABLED for vectoring mode.
        -- Research correction: NFS No Limits drift DOES follow curved paths (corners), NOT
        -- straight lines. The "point-to-point" concept means angle doesn't slow you (you can
        -- be sideways but maintain speed), NOT that trajectory is linear. The lateral bias
        -- force was pushing the car straight, which is WRONG. Vectoring drift should be a
        -- shallow-angle ARC that maintains speed, not a forced straight line.
        -- 2026-08-10 v13: DISABLED entirely in vectoring mode. Let the car naturally drift in
        -- an arc at the yaw-capped angle (32% tilt max), no lateral force interference.
        LateralBiasEnabled = false,      -- DISABLED — was forcing straight trajectory (wrong)
        LateralBiasLowSpeedKmh  = 100.0,
        LateralBiasHighSpeedKmh = 200.0,
        LateralBiasLowMult  = 0.23,
        LateralBiasHighMult = 0.35,
        LateralBiasForceScale = 0.6,
        LateralBiasDriftOnly = true,

        -- SAFETY GATES (2026-08-10 v9): the lateral bias (and yaw drag) must NOT fire when
        -- the physics state is fragile, or it amplifies instability into violent shaking.
        -- All three gate BOTH the lateral bias AND the yaw-drag stabilizer.
        --   1) GROUND CONTACT: skip when not on all wheels (airborne / mid-collision-bounce).
        --      Applying lateral force with no tire contact = uncontrolled spin/shake.
        --   2) COLLISION COOLDOWN: after any collision, skip for CollisionCooldownMs so the
        --      impact resolves naturally instead of our force stacking on the bounce.
        --   3) PITCH/ROLL LIMIT: skip when the car's pitch or roll exceeds these (deg) — a
        --      steep hill, dip, or bump tilts the body and our flat-plane assumptions break,
        --      so we stand down and let stock physics handle the uneven surface.
        RequireOnAllWheels   = true,
        CollisionCooldownMs  = 500,   -- disable assists for this long after a collision
        MaxPitchDeg          = 12.0,  -- skip assists when |pitch| exceeds this (hill/dip/bump)
        MaxRollDeg           = 20.0,  -- skip assists when |roll| exceeds this (banking/tilt)

        -- STEERING RESISTANCE: at high speed, reduce the steering input's ability to
        -- ADD yaw (so flicks are less violent) but keep its ability to HOLD the line.
        -- Mechanically: scale the player's steer input down by this fraction during
        -- stabilization, so hard flicks become gentler corrections. 1.0 = no change,
        -- 0.5 = steering is half as aggressive. Does NOT affect counter-steer assist.
        SteerResistance  = 0.70,  -- at full speed, scale steering input to 70% (gentler)

        -- Apply only while drift mode is held? true = drift-only (no effect on normal
        -- high-speed cornering). false = also stabilize non-drift slides at speed.
        -- HANDBRAKE SLIP BOOST (INVERTED v7 2026-08-12): REMOVED. The old v6 space commit (opened angle
        -- by relaxing InputSuppress + adding grip-drop) is GONE. Space now TIGHTENS the angle cap instead
        -- (see AngleFirmUp.CommitStepDeg / CommitHoldRampMs above). The knobs below are TOMBSTONES — kept
        -- for config backwards-compat but no longer used by the code. FreeDriftLatch still works (space
        -- disables assists until car is caught), SpinoutBailout still works (standalone feature).
        HandbrakeSlipBoost = false,    -- TOMBSTONE (v7): disabled, space no longer boosts slip ceiling
        BoostMult = 1.45,              -- TOMBSTONE (v7): no longer used (was normalisation reference for boostAmt)
        BoostGripDrop = 0.12,          -- TOMBSTONE (v7): no longer used (space doesn't add grip-drop anymore)
        BoostDurationMs = 550,         -- TOMBSTONE (v7): no longer used (tap extension now via CommitStepDecayMs)
        BoostDecayMs = 350,            -- TOMBSTONE (v7): no longer used (hold decay now via CommitHoldDecayMs)
        DriftOnly = true,

        -- FREE-DRIFT LATCH (2026-08-10 v32): after a space kick, counter-steer OWNS rotation
        -- (servo stands down) until the car is actually CAUGHT — not on a fixed boost timer.
        -- The old timer let the servo re-engage mid-slide and fight the player's counter-steer,
        -- so a slide "couldn't be counter-steered back". The latch releases only once slip AND
        -- yaw are both below these thresholds (car is essentially straightened), handing rotation
        -- back to the vectoring servo. A safety timeout also releases it if it never settles.
        FreeDriftLatch = true,
        LatchReleaseSlipDeg = 8.0,     -- release when |slip angle| under this (degrees)
        LatchReleaseYawRate = 0.45,    -- AND |yaw rate| under this (rad/s)
        LatchTimeoutMs = 4000,         -- safety: force-release after this long even if not settled

        -- SPINOUT BAILOUT (2026-08-11): the counter-steer assist + vectoring servo assume any yaw
        -- is a CATCHABLE drift slide. Once the car is genuinely SPUN (sideways past ~drift range,
        -- sliding backwards, or doing full circles after a crash/kick), that assumption is wrong —
        -- the normal slip calc atan(lat/fwd) collapses toward 0 as the nose passes 90° (forward
        -- velocity flips sign), so the servo goes blind and the counter-steer keeps yanking the
        -- wheel = "interferes too hard" during a spin/crash. FIX: detect a real spinout via the
        -- FULL-RANGE slip angle (atan2, ±180°) or a violent yaw spin, and STAND DOWN every assist
        -- (servo, counter-steer, forward push, yaw governor) until the car settles back into drift
        -- range. Hysteresis (Enter > Exit) so it doesn't chatter at the boundary. Pure bailout —
        -- it never ADDS force, it just stops fighting; stock physics owns the spin.
        SpinoutBailout = {
            Enabled       = true,
            EnterSlipDeg  = 100.0,  -- |full slip| past this = spun out (nose no longer leads velocity)
            ExitSlipDeg   = 55.0,   -- resume assists once |full slip| drops back under this (back in range)
            EnterYawRate  = 3.4,    -- OR |yaw rate| past this (rad/s ~ a full spin) = bail regardless of slip
            ExitYawRate   = 1.3,    -- and yaw must be under this to resume (settled)
            MinSpeedKmh   = 12.0,   -- below this, a spin is harmless/parking — don't bother bailing
        },

        -- COLLISION GRIP-CATCH (2026-08-11): drift mode cuts rear grip so the tail is loose — which
        -- means tapping/crashing the rear mid-drift spins the car FAST (no grip to resist the impact
        -- impulse). On a fresh impact, briefly RESTORE grip to native so the tyres bite and arrest
        -- the spin, and bleed the excess yaw the hit injected (only-ever-reduce, never adds). This is
        -- what a real car does — the tyres are still there to catch it. The window edge-detects a NEW
        -- collision so scraping a wall doesn't hold grip restored forever.
        -- COLLISION GRIP-CATCH (2026-08-11) — DISABLED 2026-08-12. Was too sensitive to road
        -- bumps (GTA marks minor terrain contact as a collision) and fought the new crash
        -- auto-exit. Superseded by CrashAutoExit below. Kept for reference; Enabled=false.
        CollisionGripCatch = {
            Enabled     = false,
            WindowMs    = 650,
            CatchGrip   = 1.0,
            YawBleedDamp = 6.0,
        },

        -- CRASH AUTO-EXIT (2026-08-12) — a real crash mid-drift alters the whole slide
        -- calculation (spun nose, injected yaw), so rather than fight it we DROP OUT of drift
        -- mode entirely and let stock physics own the crash. Detected via a big frame-to-frame
        -- VELOCITY DELTA (a hard hit dumps speed suddenly) — small road bumps don't produce
        -- that delta so they WON'T exit drift. Gated on a min speed so low-speed nudges are
        -- ignored, and a cooldown so it can't re-trigger while the car is still settling.
        -- v2 (2026-08-12): detect via SPEED-MAGNITUDE DROP, not velocity-vector delta. A drift
        -- rotates the velocity vector fast while keeping speed, so a vector test kicked you out
        -- mid-drift. A crash dumps speed in one frame; that's what we watch now.
        CrashAutoExit = {
            Enabled = true,
            SpeedDropThreshold = 7.0,   -- m/s LOST in ONE frame = crash (~25 km/h instant loss). Bumps don't dump speed.
            MinSpeedKmh = 25.0,         -- must have been going this fast for a loss to count as a crash
            CooldownMs  = 1500,         -- lockout after exit (prevents re-trigger spam)
        },
    },

    -----------------------------------------------------------------
    -- FWD WEIGHT-TRANSFER (2026-08-08) — cornering, not a real drift
    -----------------------------------------------------------------
    -- The 6 FWD cars (civic, cooper05, fk2, golf75r19, ikx3_civicr23, mk3vr6,
    -- fDriveBiasFront > 0.90) CAN'T power-oversteer — throttle pulls them
    -- straight. Instead of a broken slide, the drift key gives them lift-off /
    -- handbrake ROTATE-ON-ENTRY: the rear briefly lets go so the nose tucks into
    -- the corner, then hooks back up as you get ON throttle ("pull out on power").
    -- It's cornering rotation, not a sustained drift — by design.
    --
    -- Detected via VehLib.getDrivetrainLayout == 'FWD' (cached on enable). When a
    -- FWD car is detected we SKIP the normal rear-loosening drift model and run
    -- this branch instead, so the two never stack.
    FWD = {
        Enabled = true,

        -- 2026-08-14 REWORK: WEIGHT-TRANSITION drift. FWD can't power-oversteer, so the slide is driven
        -- by LONGITUDINAL WEIGHT TRANSFER — lift/brake moves weight FORWARD, the light rear steps out;
        -- feed throttle and weight goes back, the rear plants, fronts pull you straight out. The rear
        -- traction-loss is CONTINUOUS (∝ how far weight moved forward), not a timed pop — so you hold and
        -- steer the slide with the pedals. See DriftMode_FWDTick (tracks weight inline; HK.load is stale
        -- in drift mode). "Pull out on power" EMERGES from the weight model, no special-case branch.
        MinSpeedKmh  = 25.0,
        MinSteer     = 0.20,     -- must be actually turning to rotate (|steer|) — straight-line lift never loosens

        -- WEIGHT-TRANSFER TRACKING (inline mirror of Config.Drivetrain.WeightTransfer):
        AccelTau     = 0.08,     -- smoothing of measured dv/dt (s)
        AccelMaxMs2  = 12.0,     -- accel (m/s^2) that maps to full longitudinal load
        AccelWeight  = 0.55,     -- blend: measured accel vs pedal intent (0.55 = accel-anchored)

        -- REAR-UNLOAD → rear traction-loss. Only the FORWARD half of the transfer unloads the rear.
        -- DEDICATED FWD MODE (2026-08-14): the weight-transfer response is AMPLIFIED (UnloadGain) so a
        -- deliberate flick/lift in a front-drive car genuinely rotates — feels assisted, but still 100%
        -- weight-driven (no shift = no slide = stays hard to pull off). Rear grip set BETWEEN lock-hard
        -- and moderate: a clear FWD slide, but keeps enough residual grip to catch with steering.
        UnloadGate   = 0.12,     -- dead-band: a small lift below this won't step the rear out (still needs technique)
        UnloadFull   = 0.75,     -- forward-shift at which the (pre-gain) unload is full
        UnloadGain   = 1.15,     -- AMPLIFY the response, but modestly — 1.5 made the rear step out too easily ("side turn very easily")
        RotateLoss   = 1.58,     -- rear traction-loss at full unload (between lock-hard ~1.7 and moderate ~1.4); 1.0 = planted
        WindowMs     = 500,      -- MIN-HOLD floor: a brief lift/handbrake stab still holds the kick this long
        EngageTau    = 0.07,     -- rear steps out this fast
        HoldTau      = 0.22,     -- decays this slow while within the min-hold window (sustained slide)
        ReleaseTau   = 0.10,     -- decays this fast once past the window (grip returns)

        -- HANDBRAKE = the primary FWD tool (real FWD drift is e-brake-led). While held it pins this floor
        -- under the rear-unload REGARDLESS of throttle, so you lock-and-hold the slide through the corner.
        HandbrakeHold= 0.90,     -- rear-unload floor while handbrake held (0.90 = rears nearly locked out)

        -- ON-THROTTLE HOOK-UP: without handbrake, real power plants the rear (pull out on power). WITH the
        -- e-brake held, throttle instead PULLS the front through the slide (see PullRecover) — no plant.
        HookThrottle = 0.45,

        -- THROTTLE-PULL SUSTAIN — the driven fronts pull the car along its heading, so on the gas mid-slide
        -- the FWD car keeps driving forward instead of scrubbing dead. Scrub-only (restores lost fwd speed,
        -- never accelerates), faded out by speed. This is what makes throttle SUSTAIN a FWD drift.
        PullRecover     = 0.70,  -- fraction of scrubbed forward speed given back (0 = off)
        PullThrottle    = 0.30,  -- need at least this throttle for the pull
        PullFadeLowKmh  = 55.0,  -- full pull at/below here…
        PullFadeHighKmh = 130.0, -- …fading to zero by here (low/mid-speed sustain only)

        -- Steering assist toward the corner (gentle, scaled by rear-unload — only helps while rotating).
        SteerAssist  = 0.3,

        -- EXIT COUNTER-ASSIST (2026-08-14) — a FWD car straightens the OPPOSITE way to RWD. RWD recovery
        -- YIELDS to countersteer (a driven rear + your wheel balances the exit). But a FWD rear is still
        -- loose during the grip-ramp, so countersteer alone can't pull it straight — and the RWD recovery
        -- steps aside, so NOTHING straightens it ("countersteer + throttle doesn't straighten the car").
        -- For a FWD exit we INVERT it: when you countersteer, the recovery yaw-damp gets STRONGER (helps the
        -- driven fronts hook and pull onto their heading), and throttle pulls the nose forward out of the
        -- slide. Only-ever-reduce yaw (setYaw), so it can't overshoot into a spin the other way.
        ExitCounterAssist  = 1.35,  -- 1.8→1.35: countersteer MULTIPLIES the exit yaw-damp by up to this. 1.8 straightened too fast/snappy.
        ExitPullRecover    = 0.60,  -- on-throttle forward pull during the FWD exit (scrub-only, same safe bleed)
        ExitPullThrottle   = 0.20,  -- min throttle for the exit pull

        -- ANGLE CAP + BUILD-RATE DAMP — the FWD branch returns BEFORE the RWD/AWD AngleFirmUp limiter,
        -- so without this a FWD slide builds angle instantly ("side turn very easily") AND runs to any
        -- angle then springs off the loaded front axle on release. TWO layers, both only-ever-reduce
        -- yaw via setYaw (can ONLY shrink |yaw|, never add rotation — NOT the dead servo):
        --   (1) BUILD-RATE DAMP: a gentle CONTINUOUS yaw bleed the moment the car starts rotating past
        --       CapStartDeg. This slows how fast the angle builds so it's not a snap, and — because it's
        --       always shaving a little yaw — the angle becomes something you HOLD against throttle/steer
        --       instead of a spike that runs away. Ramps in from CapStartDeg→CapFullDeg.
        --   (2) HARD WALL: past CapFullDeg the scrub goes firm so the angle physically stops.
        CapEnabled   = true,
        CapStartDeg  = 6.0,      -- 8→6: start the build-rate damp EARLIER so the angle can't snap in before it's caught
        CapFullDeg   = 18.0,     -- 20→18: tighter FWD ceiling — no wide swing
        CapBuildDamp = 5.0,      -- 3.2→5.0: firmer CONTINUOUS bleed while building (StartDeg→FullDeg); slows angle build + holdable
        CapYawDamp   = 10.0,     -- firm wall strength past CapFullDeg
        -- SPEED-SCALE the build-rate damp: "when too fast it's easy to push sideways" — a fast FWD car
        -- should RESIST breaking loose harder. Multiply CapBuildDamp across a speed band so it's near
        -- baseline slow and much firmer at speed (the front tyres would be planted-heavy at speed anyway).
        CapSpeedLowKmh   = 55.0,  -- baseline damp at/below here
        CapSpeedHighKmh  = 130.0, -- full boosted damp at/above here
        CapSpeedHighMult = 2.2,   -- CapBuildDamp ×2.2 at high speed (resists the easy high-speed side-push)
    },
}

-----------------------------------------------------------------
-- [X6] DIFFERENTIAL SIMULATION (brake-based torque vectoring)
-- GTA simulates an OPEN diff: the unloaded inner wheel spins free and
-- robs torque from the gripping wheel. Real performance/drift cars run
-- an LSD or locked diff so both driven wheels turn together.
--
-- We fake it: detect the left-vs-right speed delta WITHIN the driven
-- axle and brake the faster wheel (SetVehicleWheelBrakePressure) to pull
-- it back toward its pair. Result: predictable power-on grip + linear,
-- holdable drift instead of a twitchy open-diff slide.
--
-- Runs on whichever axle(s) are driven (RWD rear, FWD front, AWD both).
-- Throttle-gated — the per-wheel brake native is only reliable on power.
--
-- TWO PRESETS:
--   LSD    = gentle, optional always-on (OEM corner-exit traction)
--   Locked = aggressive, auto-engaged in drift mode (consistent slides)
-----------------------------------------------------------------
Config.Diff = {
    Enabled = true,    -- 2026-08-08: enabled for drift. Locked preset auto-engages in drift
                       -- mode only (AlwaysOnLSD stays off), so normal driving is untouched.
                       -- If the per-wheel brake native no-ops on this build the diff simply
                       -- does nothing (vl_brakeWheel guards on SetVehicleWheelBrakePressure).

    -- Gentle LSD: run always (not just in drift) on driven axle.
    -- Leave OFF until validated — it touches braking every frame.
    AlwaysOnLSD = false,

    -- Gates
    MinSpeedKmh  = 8.0,    -- below this, leave the diff alone (parking/crawl)
    MinThrottle  = 0.15,   -- only lock under power (native unreliable off-throttle)

    -- LSD preset (gentle — corner-exit traction, OEM feel)
    LSD = {
        Deadband    = 1.5,   -- m/s of L-R delta before we act (ignore small diffs)
        LockGain    = 0.08,  -- brake pressure per m/s of delta over deadband
        MaxPressure = 0.25,  -- cap on per-wheel brake pressure (0-1)
    },

    -- Locked preset (aggressive — auto-used in drift mode for linear slides)
    Locked = {
        Deadband    = 0.5,
        LockGain    = 0.15,
        MaxPressure = 0.60,
    },

    -- Skip under player braking (per-wheel brake + brake pedal = lockup risk;
    -- also ABS owns braking then). Diff is a power/coast tool.
    SkipUnderBraking = true,
}
-- Detects wheelspin and reduces torque to regain grip.
-- Three modes: Off / Low / High intervention.
-----------------------------------------------------------------
Config.TractionControl = {
    Enabled = true,             -- ON by default; players switch OFF per-car via /tc or F1 radial menu

    -- Modes: 0=Off, 1=Low, 2=High
    DefaultMode = 2,

    -- Wheelspin detection: difference between wheel speed and ground speed (m/s)
    -- that counts as "spinning". Lower = more sensitive.
    SpinThresholdLow  = 4.0,    -- Low mode: only intervenes on heavy spin
    SpinThresholdHigh = 2.0,    -- High mode: intervenes early

    -- How much to cut torque when spin detected (multiplier)
    TorqueCutLow  = 0.6,        -- Low mode: gentle cut (60% power)
    TorqueCutHigh = 0.3,        -- High mode: aggressive cut (30% power)

    -- Minimum speed to activate (don't interfere with parking)
    MinSpeedKmh = 8.0,

    -- Smoothing (prevents harsh on/off feeling)
    AttackTau = 0.05,           -- fast engage (catch spin quickly)
    ReleaseTau = 0.20,          -- smooth release back to full power
}

-----------------------------------------------------------------
-- [D2] ABS SIMULATION
-- Detects locked wheels under braking and pulses brake force.
-----------------------------------------------------------------
Config.ABS = {
    Enabled = true,             -- ON by default; players switch OFF per-car via /abs or F1 radial menu

    -- Minimum vehicle speed for ABS to activate (m/s)
    MinSpeed = 5.0,

    -- How much to reduce brake force when wheels lock
    BrakeReductionMult = 0.35,  -- pulse between full and 35%

    -- Pulse frequency (how fast ABS cycles)
    PulseRateHz = 12.0,         -- 12 cycles per second (realistic ABS)

    -- Detection: wheel is "locked" if its speed < this % of vehicle speed
    LockThreshold = 0.15,       -- wheel spinning at <15% of ground speed = locked
}

-----------------------------------------------------------------
-- ABS-OFF DRIVETRAIN RESPONSE (2026-08-14) — makes "/abs off" (or the F1 radial toggle) FEEL like a
-- real car with no ABS, instead of just "brake pulse stops". With ABS off, standing on the brakes
-- LOCKS the wheels, and that has three real consequences we simulate. All are layout-agnostic (a
-- locked wheel behaves the same whatever axle drives) and ALL recover the instant you ease the brake:
--   (1) STEERING LOSS — locked FRONT wheels have no lateral grip, so the car plows STRAIGHT no matter
--       how much lock you dial in (the classic "stomp the brakes and sail off the road"). Simulated by
--       the flip-proof applyYawScale yaw-rate resist (never forces yaw, only resists it), scaled by
--       front-lock × steer input × brake. This is the skill tell: threshold-brake to keep steering.
--   (2) LONGER STOP — locked (sliding) rubber has LESS grip than a wheel right at the threshold, so a
--       full-lock stop is slightly longer than a threshold stop. A small fBrakeForce trim while locked
--       (StopPenalty), so brake-just-below-lockup is genuinely the fastest — arcade-legible payoff.
--   (3) REAR-LOCK ROTATION — locking the REARS under trail-braking steps the tail out (the fronts
--       still steer, the rears slide). A gentle rotation aid (rides the same yaw path, bounded) so
--       Scandi-flick / brake-to-rotate works with ABS off. Small — the drama is the front-lock plow.
-- ARCADE TUNING: thresholds are forgiving (you have to really stomp to lock), recovery is instant, and
-- the steering isn't KILLED to zero — it's heavily resisted, so a determined stab of countersteer +
-- brake-ease still saves you. Realistic function, arcade catchability. Gate reads HK.absOff.
-----------------------------------------------------------------
Config.ABSOff = {
    Enabled       = true,
    MinSpeedKmh   = 12.0,       -- below this, locking is harmless (parking); leave braking alone
    BrakeGate     = 0.55,       -- need real brake pressure before lock effects arm (forgiving — you
                                -- have to actually stand on it, a light brush won't plow you)

    -- (1) STEERING LOSS on front lock
    Steer = {
        Enabled       = true,
        SteerGate     = 0.10,   -- need real steering input for the plow to matter (straight-line = nothing)
        MaxYawResist  = 0.55,   -- 0..1: peak yaw-rate REDUCTION at full front-lock+steer+brake. NOT 1.0 —
                                -- leaves 45% of your rotation so a hard countersteer still bites (arcade save)
        EngageTau     = 0.05,   -- fast onset (lockup is abrupt)
        ReleaseTau    = 0.08,   -- fast recovery the instant a wheel unlocks (ease the brake → steer back)
    },

    -- (2) LONGER STOPPING DISTANCE while locked (slid rubber < threshold grip)
    Stop = {
        Enabled     = true,
        Penalty     = 0.12,     -- fBrakeForce trim at full lock (0.12 = 12% less bite locked than threshold).
                                -- Kept small — realistic-ish without making ABS-off feel broken.
        EngageTau   = 0.06,
        ReleaseTau  = 0.10,
    },

    -- (3) REAR-LOCK ROTATION (trail-brake tail-out with ABS off) — EMERGENT, never forced.
    -- We do NOT inject yaw (that servo is permanently abandoned — drift/oversteer must emerge from grip).
    -- Instead: the steering-plow in (1) is keyed to FRONT lock only. When the REARS are the ones locking
    -- (trail-braking unloads the rear → rears lock first), the plow BACKS OFF proportionally, so the
    -- natural tail-out GTA already produces on a grip-less rear axle is allowed to come through instead of
    -- being straightened away. RearBias below is how strongly rear-dominant lock cancels the front plow.
    Rotate = {
        Enabled   = true,
        RearBias  = 1.0,   -- 0..1: how much a rear-dominant lock cancels the front-lock plow (1.0 = fully
                           -- let the tail rotate when rears are the locked pair; 0 = always plow straight)
    },
}

-----------------------------------------------------------------
-- [G1] SPEED-DEPENDENT DOWNFORCE
-- Car gets heavier/more planted at high speed.
-----------------------------------------------------------------
Config.Downforce = {
    Enabled = true,

    -- HOW IT WORKS: pure SetVehicleGravityAmount, scaled by speed. NO per-frame
    -- ApplyForceToEntity — that floods GTA's physics solver at speed and causes
    -- slow-motion. Gravity presses the whole car down the way the engine expects.
    -- Front/rear balance is NOT done here (heavier gravity just amplifies the
    -- car's fTractionBiasFront); the gentle high-speed bias CENTERING below,
    -- consumed by drivetrain.lua (the sole traction-bias writer), handles that.

    -- Speed range where the plant scales 0 → full. 2026-09-08 REWORK v2: reference the
    -- FULL plant at 200 km/h (a real fast-corner speed, NOT 300 where nobody corners), so
    -- the grip is genuinely FELT through the mid-high range. Above MaxSpeedKmh the plant
    -- just stays at full (clamped). Onset stays low for a steady ride out of slow corners.
    MinSpeedKmh = 50.0,         -- below this: native (very-low-speed feel untouched)
    MaxSpeedKmh = 110.0,        -- at/above this: FULL plant (2026-09-08: lowered 200→110 to test — plant lands early)

    -- CURVE SHAPE: v² buried almost all the plant at the very top and made it feel like
    -- nothing at normal speeds. Use a gentler exponent so the grip BUILDS through the
    -- mid-range where you actually corner. 1.0 = linear, 2.0 = old v² (late), 1.3 ≈ a
    -- real aero feel that's already meaningful by 120-150 km/h.
    Curve = 1.3,

    -- ── GRAVITY (a real press-DOWN, paired with the grip) ────────────────────
    -- 2026-09-08: 1.06 was imperceptible. Downforce IRL presses the car into the road —
    -- bring back a firm-but-safe gravity plant so the car physically STICKS, not just grips.
    -- Multiplier ON the car's own native gravity (vehlib caps at 2.0, we stay well under).
    -- 1.22 at 200 km/h = clearly planted without the slow-motion solver issues (gravity is
    -- the safe lever; it was the per-frame ApplyForce that blew up, never gravity).
    GravityAtMax = 1.22,

    -- BUMP BOOST (2026-09-08 — "going downhill should STICK, those weird bumps are weird").
    -- The plant now STAYS ON through bumps (only releases for a genuine full-car ramp jump).
    -- When a wheel unloads over a crest/bump at speed, add THIS much extra gravity (× speed
    -- curve) to suck the car back onto the road instead of floating light + skittery. 0.30 =
    -- up to +30% extra while a wheel is up; raise if downhill bumps still feel floaty.
    BumpBoost = 0.30,

    -- ── GRIP PLANT (THE primary downforce — now sized to actually be FELT) ────
    -- Real MECHANICAL grip scaled with speed via the grip arbiter (fTractionCurveMax/Min).
    -- v1's +8%-at-300km/h numbers were nothing; these are sized so the car feels GLUED
    -- through fast corners like a real downforce car — noticeable, not subtle.
    --   • BASELINE: every car gets a tier-scaled grip bump (float/skate hits all cars).
    --     gripMult = 1 + (BaseGripAtMax-1)·curve(t)·tier.
    --   • AERO BONUS: cars whose handling.meta carries fDownforceModifier get EXTRA grip
    --     on top, proportional to that rating (Chiron 0.70 = full bonus). No-field cars
    --     still get the (now meaningful) baseline.
    -- Claimed through HK.gripClaim at prio 'downforce' (lowest) so ANY active maneuver
    -- (drift/burnout/LC/launch/tc-off) instantly overrides it.
    Grip = {
        Enabled       = true,
        BaseGripAtMax = 1.35,   -- baseline grip mult at MaxSpeedKmh, tier 1.0 (+35% grip planted — FELT)
        AeroGripAtMax = 1.30,   -- EXTRA grip on top for a full-aero car (so a Chiron ≈ +65% vs a plain car's +35%)
        AeroRef       = 0.70,   -- fDownforceModifier that counts as "full aero" (Chiron = 0.70)
        MinBump       = 0.60,   -- fTractionCurveMin gets this FRACTION of the max bump (breakaway planted, some slide kept)
        Prio          = 10,     -- grip-arbiter priority (below tcoff=20 so everything overrides passive plant)
    },

    -- TOP-SPEED RELEASE: the extra gravity costs ~5-10 km/h of terminal speed vs a
    -- pure-fx server (no downforce). Rather than cap anything, fade the extra gravity
    -- delta back to 1.0 as the car nears ITS OWN top speed (per-car, from
    -- GetVehicleEstimatedMaxSpeed via HK.gbTopKmh), so terminal speed matches native
    -- mfv while the mid-high plant is untouched. TopReleaseFrac = the top slice of the
    -- speed band over which the release happens (0.15 = last 15%). Larger = the plant
    -- eases off earlier/more gradually (softer, gives back a touch more speed sooner);
    -- smaller = holds plant longer then releases sharply right at the top.
    TopSpeedRelease = true,
    TopReleaseFrac  = 0.15,

    -- TIER by gearbox type (HK.dbgPublicType, auto-detected — NO car-name lists).
    -- 0=traffic/default (mild) .. 5=F1box (strongest). Scales the gravity delta
    -- above 1.0, so a tier-0.45 car at full speed = 1.0 + 0.18*0.45 ≈ 1.081.
    -- Even slow traffic cars get SOME plant (float hits them too), just gentle.
    TierMult = {
        [0] = 0.45,   -- generic / traffic / shitbox — mild
        [1] = 0.70,   -- manual / sequential
        [2] = 0.85,   -- paddle auto (torque-converter feel)
        [3] = 0.90,   -- DCT
        [4] = 1.00,   -- hypercar / LST
        [5] = 1.10,   -- F1BOX (Valkyrie-class)
        [6] = 0.95,   -- quadturbo
    },
    TierDefault = 0.45,         -- used when HK.dbgPublicType is nil (untracked car)

    -- HIGH-SPEED TRACTION-BIAS CENTERING (consumed by drivetrain.lua).
    -- The forum warning: extra gravity amplifies any off-center fTractionBiasFront,
    -- so at speed an understeery/oversteery car gets WORSE. Counter it by pulling
    -- the bias a hair toward 0.5 as speed rises — 3rd-decimal only (0.498..0.502),
    -- so we never overdo it. Composes with drivetrain's own bias shifts; only
    -- applied on straight-line high-speed cruise (never while a cornering tool
    -- owns the field that frame). See Drivetrain_Tick centering pass.
    BiasCenter = {
        Enabled      = true,
        SpeedLoKmh   = 140.0,   -- below this: no centering
        SpeedFullKmh = 300.0,   -- at this: full MaxNudge
        MaxNudge     = 0.003,   -- max shift toward 0.5 (3rd decimal — keep tiny)
    },
}

-----------------------------------------------------------------
-- [G2] ACTIVE AERO / DRS
-- Reduces drag on straights for higher top speed.
-- Increases drag under braking for shorter stops.
-----------------------------------------------------------------
Config.DRS = {
    -- 2026-08-14: ENABLED after the rebuild (3-state single-writer drag, DRS_Reset on
    -- veh-swap, drift/airborne standdown). fInitialDragCoeff is single-writer here.
    Enabled = true,

    -- Activation conditions (ALL must be true to activate DRS)
    MinSpeedKmh = 100.0,        -- must be going fast
    MaxSteerAngle = 3.0,        -- must be driving straight (degrees)
    NoBraking = true,           -- must not be braking

    -- Drag coefficient multiplier when DRS is active (less drag = more top speed)
    DragMultActive = 0.70,      -- 70% of original drag (30% reduction)

    -- Brake boost: INCREASE drag when braking hard at speed (aero braking)
    BrakeBoostEnabled = true,
    BrakeBoostMult = 1.25,      -- 125% of original drag under heavy braking
    BrakeBoostMinSpeed = 80.0,  -- only above this speed
}

-----------------------------------------------------------------
-- [E1] STABILITY CONTROL (ESC)
-- Limits oversteer at high speed by cutting torque when yaw rate
-- exceeds what's expected for the steering input.
-----------------------------------------------------------------
Config.ESC = {
    -- 2026-08-14: ENABLED after the rebuild (single-writer ARB via _G.ESC_Restore at
    -- drift entry + ESC_Reset on veh-swap; torque cut composes with TC via HK.torqueMult).
    Enabled = true,

    -- Yaw rate threshold (rad/s). Above this = oversteer detected.
    -- Scaled by speed: at low speed, allow more yaw (turning is normal).
    YawRateThresholdBase = 1.2,  -- rad/s at high speed
    YawRateThresholdLow  = 3.0,  -- rad/s at low speed (more permissive)

    -- Speed range for threshold interpolation
    LowSpeedKmh = 30.0,
    HighSpeedKmh = 120.0,

    -- Extra yaw tolerance per unit of steering input (0..1 steer × this, rad/s). Higher
    -- = ESC lets the driver rotate the car more before it calls it oversteer.
    SteerTolerance = 1.5,

    -- Intervention: how much to cut torque when oversteer detected
    TorqueCut = 0.4,            -- 40% power during intervention (0=full cut, 1=no cut)

    -- Also boost ARB to resist further rotation
    ARBBoostMult = 2.0,         -- double ARB during intervention

    -- Smoothing (fast attack so it catches the slide; slow release so it doesn't pump)
    AttackTau = 0.06,
    ReleaseTau = 0.30,

    -- Don't activate in drift mode (they conflict — drift OWNS ARB + rotation).
    DisableInDriftMode = true,
}

-----------------------------------------------------------------
-- [A3] LAUNCH CONTROL  ** DEPRECATED — NOT THE ACTIVE FEATURE **
-- This is the OLD generic brake+throttle launch (client/launch.lua LaunchControl_Tick),
-- which is DEAD/uncalled (main.lua no longer ticks it; launch.lua is kept loaded only for
-- RevLimiter_Tick). The ACTIVE launch control lives in client/gearbox.lua and reads
-- Config.Gearbox.Launch (NOT this block). Nothing here is wired: Enabled=false, and
-- NotifyOnStage below does NOTHING. Left in place to avoid touching launch.lua; ignore
-- for the current feature. TODO: delete once RevLimiter_Tick is moved out of launch.lua.
-- Hold throttle + brake while stopped to "stage". The revs hold at
-- a target, wheelspin is capped, then on brake release the car gets
-- a brief torque boost off the line. Drag-strip style standing start.
-----------------------------------------------------------------
Config.LaunchControl = {
    Enabled = false,

    -- Staging: must be near-stopped, throttle held, brake held
    StageMaxSpeedKmh = 3.0,     -- must be basically stopped to stage
    StageMinThrottle = 0.85,    -- throttle held this hard to arm
    StageMinBrake    = 0.55,    -- brake held this hard to arm

    -- Held RPM while staged (0.0-1.0). Builds boost / anti-lag feel.
    StagedRpm = 0.78,

    -- Anti-wheelspin while staged: cap torque so it doesn't just smoke
    StagedTorqueMult = 0.55,

    -- LAUNCH (brake released while staged + throttle still down)
    LaunchBoostMult   = 1.85,   -- torque multiplier at the instant of launch
    LaunchDurationMs  = 1400,   -- how long the boost tapers over
    LaunchEndSpeedKmh = 90.0,   -- boost fully gone by this speed (whichever first)

    -- Traction during launch window: let TC still protect, but allow
    -- a little more slip for that "hooking up" feel
    LaunchSpinThreshold = 5.5,  -- m/s wheel-vs-ground before cutting

    NotifyOnStage = true,   -- DEAD: not read by the active launch control (Config.Gearbox.Launch)
}

-----------------------------------------------------------------
-- [A4] REV LIMITER
-- Caps RPM at redline and adds a bouncing "hard cut" feel by
-- briefly dropping torque when the limiter is hit. Also gives a
-- soft clutch-in rev hold in neutral.
-----------------------------------------------------------------
Config.RevLimiter = {
    Enabled = false,

    -- RPM ceiling (0.0-1.0). GTA reports ~1.0 near redline.
    Redline = 0.95,

    -- When RPM is at/above Redline, cut torque this hard to create the
    -- bounce off the limiter (lower = harsher bounce).
    CutMult = 0.0,

    -- Bounce oscillation: re-engage power once RPM drops below this
    -- (hysteresis band so it flutters instead of locking solid).
    ReengageRpm = 0.92,

    -- Hard-cut flutter frequency (Hz) for the audible/visual bounce.
    FlutterHz = 18.0,

    -- Only limit while in gear and under throttle (don't fight idle).
    MinThrottle = 0.5,

    -- Neutral / clutch rev hold: when in neutral (gear 0) cap revs here
    -- so revving in place doesn't peg redline instantly.
    NeutralRevCap = 0.70,
    LimitInNeutral = true,
}

-----------------------------------------------------------------
-- [B*] BURNOUT / WHEELSPIN + GEAR-1 LIMITER  (client/burnout.lua)
-- Fills the gap the gearbox limiter leaves: applyRevLimiter (gearbox.lua) only
-- covers gears >= 2 on the AUTO/DCT boxes and explicitly skips GEAR 1. So manual
-- holding 1st (and a spinning burnout in 1st) has NO redline bounce today — this
-- module owns GEAR 1 so every car bounces off a redline there too.
--
-- NEUTRAL is deliberately NOT touched here: the gearbox already free-revs to
-- redline in neutral (coastNeutralTick + NeutralRevMax=1.0, the flywheel sim).
-- Adding a second rpm writer would fight it every frame. A real limiter is never
-- "disabled" anyway — in neutral there's just no load, so the blip screams up and
-- the (existing) ceiling catches it. That already works.
--
-- REALISM: the surplus of torque a burnout builds is what later HOOKS UP to lift
-- the nose (the wheelie). Launch mode alone stays flat — no nose lift — it only
-- matches rpm to grip and pulls. The wheelie now comes from HK.launchCharge built
-- by wheelspin, hooking up on release. See client/burnout.lua + client/wheelie.lua.
-----------------------------------------------------------------
Config.Burnout = {
    Enabled = true,

    -----------------------------------------------------------------
    -- STEP 1: PLAIN W+S FREE-REV (no drift, no wheelspin) — 2026-08-14
    -- The FOUNDATION the wheelspin (Step 2) is built on. Hold W (throttle) + S (brake)
    -- with NO drift key, at a stop: the car stays PLANTED (footbrake holds it, tires grip,
    -- nothing breaks loose) while the engine free-revs FAST up to redline and BOUNCES off
    -- the limiter — the classic "rev against the brake" scream. Mutually exclusive with the
    -- Step-2 wheelspin gesture (that one REQUIRES the drift key). Perf-neutral: drive torque
    -- is cut to 0 so the painted needle/note is pure cosmetics (same basis as the flywheel
    -- neutral rev). Step 2 will reuse this rev base and add the wheels breaking loose.
    -----------------------------------------------------------------
    FreeRev = {
        Enabled     = true,
        -- GATE: W and S both at least this (real throttle + real brake). No drift key.
        MinThrottle = 0.5,
        BrakeGate   = 0.5,
        -- Only free-rev from a near standstill (rev-against-the-brake, not while rolling).
        MaxKmh      = 5.0,
        -- ============================================================= THREE-STATE REV MODEL
        -- (2026-08-15) The rev-against-throttle gesture now has THREE distinct feels, chosen by
        -- whether the box is in NEUTRAL and whether the FOOTBRAKE is held. Manual (mode 1) gates
        -- the free-rev on the CLUTCH (LSHIFT) — you can't spin a real manual's engine free in gear
        -- without declutching. Autos/DCT/seq discriminate by neutral-selection + footbrake.
        --
        --   [2] NEUTRAL + FOOTBRAKE + throttle  -> HARD FREE-REV: fast slam to redline, sharp cut.
        --       (the headline "burst on tap, scream to max" — uses the base Redline/RevUpRate below.)
        --   [1] NEUTRAL + throttle, NO brake    -> SOFT limiter: gentler climb, LOWER ceiling.
        --   [3] IN GEAR + FOOTBRAKE + throttle  -> LOADED limiter: STRONGER than [1] (lower ceiling,
        --       harder/faster flutter) — the engine is loaded through the driveline, revs don't fly.
        --
        -- STATE [2] — hard free-rev (the headline: RAW rapid RRAW-RRAW slam to MAX + hard bounce).
        -- With drive force zeroed + gear 1 forced (audio trick), the engine has NO load, so it should
        -- rev like a free engine: instant snap to the TRUE ceiling then a hard, fast fuel-cut stutter.
        -- RevUpRate = per-frame exp-ease rate; 260 = full slam in ~1 frame (raw, no lazy climb).
        RevUpRate   = 780.0,    -- 3x (was 260): near-instant paint slam + snappier bounce down
        Redline     = 1.00,     -- TRUE max (was 0.99 = never quite topped out = "not maxed")
        -- ReengageRpm is the fuel-cut BOUNCE FLOOR. Keep it ABOVE the speedo's redline arm point
        -- (Config.Gearbox.RevLimiterRedline ~= 0.985) so the WHOLE bounce stays in the red zone and the
        -- speedo shows sustained RED at max — a floor of 0.82 dropped the needle way below 0.985 each
        -- cycle (~57x/sec at 28Hz), so red only flickered at the peak = "doesn't show red". 0.985 keeps
        -- the entire bounce inside the red band while still audibly stuttering off the cut.
        ReengageRpm = 0.985,    -- tight bounce at the very top (was 0.82 = fell out of the red zone)
        FlutterHz   = 28.0,     -- RAPID stutter off the limiter (the "rraw-rraw-rraw", was 20)
        -- FREE-REV TORQUE BOOST (the "horn boost" for the rev). free mode is now a REAL native gear 1
        -- vs the brake — the engine climbs by overcoming its own rotational inertia, so MORE engine
        -- torque = FASTER rpm rise. Multiply HK.torqueMult by this while free-revving so the needle
        -- flies up. vehlib caps torque at 5.0x, so anything past ~4.5 gets clamped. Drive force is real
        -- (it's a true gear 1) but the footbrake holds the car, so the extra torque goes into REVS not
        -- motion. Set 1.0 to disable the boost (pure vanilla gear-1 torque).
        FreeRevTorqueBoost = 1.0,   -- 1.0 = OFF (torque boost hurt the feel). Real gear-1 torque only.
        -- FREE-REV INERTIA BOOST — the RIGHT lever for "rev to max faster". fDriveInertia is GTA's
        -- rotating-mass float: HIGHER = the engine spins up (and down) FASTER for the same torque. While
        -- brake-held free-revving we MULTIPLY the car's live fDriveInertia by this, then restore the exact
        -- prior value the frame the gesture ends. 3.0 = roughly 3x rev-up/down speed (user asked "3x").
        -- This is native + perf-neutral (only active during the stationary rev), unlike a torque hack.
        FreeRevInertiaBoost = 20.0,  -- 20x: fast native climb feeding the pin (was 40x)
        -- SUSTAINED-REV CUTOUT ("engine protection"): sit pinned near redline too long and the ECU
        -- pulls fuel — throttle auto-releases and the revs fall, exactly like a real limiter babysitter.
        -- Only counts time spent ABOVE HoldCutRpm (the actual limiter zone), so short blips never trip.
        -- Re-arms once you drop below HoldRearmRpm (back off the throttle). Set HoldCutSec = 0 to disable.
        HoldCutSec   = 0,       -- 0 = OFF (sustained-rev cutout removed). Whole timer/cut block no-ops.
        HoldCutRpm   = 0.93,    -- timer only ARMS once rpm crosses this (near redline / "reached max")
        HoldRearmRpm = 0.60,    -- must fall below this to re-arm (lift throttle) after a cut
        -- STATE [1] — NEUTRAL soft limiter (no brake): DELIBERATELY much gentler + LOWER than [2] so
        -- the brake-held scream is obviously different. Lazy crawl to a low ceiling, soft wobble.
        SoftRevUpRate   = 10.0,  -- crawls up (vs the free slam) — clear tactile difference
        -- NEUTRAL NO-LOAD REV LIMIT (real cars cap free-revving lower to protect the engine — nothing
        -- for the flywheel to spin, so the ECU limits it well below the loaded redline). Expressed in
        -- REAL rpm on our 0-8000 display scale (GTA's native rpm is a 0-1 float; 8000 = full = 1.0).
        -- The code converts to the 0-1 SoftRedline: e.g. 4400/8000 = 0.55. Per-vehicle flavour: each
        -- car picks a random cap in [SoftRevCapMinRpm, SoftRevCapMaxRpm] once on entry, so not every
        -- car cuts at the exact same needle (real engines vary). Set Min==Max for a fixed cap.
        SoftRevCapMinRpm = 4200,
        SoftRevCapMaxRpm = 4500,
        SoftRevScaleRpm  = 8000, -- the display full-scale (must match the speedo's Redline/8000)
        SoftRedline     = 0.55,  -- FALLBACK if the RealRpm knobs are removed (4400/8000). ~4400 rpm.
        SoftReengageRpm  = 0.48,  -- flutter floor a touch under the cap
        SoftFlutterHz   = 8.0,
        -- NEUTRAL NO-BRAKE REV DROP: lifting W in plain neutral (NO brake) eases the needle DOWN to
        -- idle at this exp rate instead of snapping — the lazy free-engine coast-down. This tick OWNS
        -- the needle the whole fall (nothing can stomp it). Free-rev (brake-held) still snaps back
        -- instantly; only this no-brake lift glides. LOWER = slower drop.
        NeutralDropRate = 1.5,   -- slow rev fall in neutral-no-brake. lower = slower. (3.0 -> 1.5 = 2x slower)
        -- STATE [3] — IN-GEAR loaded limiter (footbrake AND/OR handbrake held, clutch NOT held on
        -- manual): rev-against-the-brakes in gear at a standstill. Caps at ~5000 rpm — a real engine
        -- loaded through the driveline against the brakes won't fly to redline like a free rev, so it
        -- limits well below the loaded top. Expressed on the 0-8000 display scale: 0.63 * 8000 = 5040.
        -- HARDER/faster flutter than the neutral soft limit [1] (loaded driveline bounce). Was 0.95
        -- (~7600) = looked like NO limiter vs the neutral cap; now a clear ~5000 cut. (2026-08-16)
        LoadRevUpRate   = 22.0,
        LoadRedline     = 0.63,     -- ~5040 rpm cap (was 0.95 ≈ 7600 = effectively no limit)
        LoadReengageRpm  = 0.56,    -- flutter floor ~4480 rpm (bounce band 4480-5040)
        LoadFlutterHz   = 22.0,
    },

    -----------------------------------------------------------------
    -- STAGE 1: soft limiter for GEAR 1 (always armed, all drivetrains)
    -----------------------------------------------------------------
    Limiter = {
        Enabled     = true,
        -- Redline point (0..1 of GTA rpm). Matches the gearbox limiter's below-top
        -- redline so the bounce point feels identical across the whole rev range.
        Redline     = 0.985,
        -- Hysteresis: once bouncing, power returns below this so it flutters rather
        -- than locking solid (the audible "brraap" off the limiter).
        ReengageRpm = 0.965,
        -- Torque left ON during a bounce (0 = full fuel-cut / hardest bounce). Gear 1
        -- gets NO self-brake — it just bounces, exactly like a real manual off the cut.
        CutMult     = 0.0,
        -- Flutter frequency (Hz) of the cut so the bounce reads audibly/visually.
        FlutterHz   = 20.0,
        -- Only fight the engine under genuine throttle (don't touch idle/coast).
        MinThrottle = 0.45,
        -- WHO gets the gear-1 bounce: a MANUAL box holding 1st, OR any box with the
        -- wheels actually SPINNING past this slip (m/s, wheel-vs-ground). An auto/paddle
        -- box on a CLEAN hooked-up launch reads ~0 slip → no bounce (it upshifts itself),
        -- so a 911ts in normal paddle driving won't flutter. A burnout/wheelspin reads
        -- well above this. Lower = easier to trigger the spin bounce; higher = stricter.
        -- Measured live: clean gear-1 launch ~0.9 m/s, launch-control spin ~6 m/s.
        SpinThreshold = 2.5,
        -- BRAKE PRIORITY (2026-08-14): the gear-1 limiter flutters torque between the cut and FULL power.
        -- Holding throttle at the gear-1 rev limit + braking would fight those full-power halves so the
        -- car wouldn't slow. While braking, hold the FULL cut so the brakes win (mirrors the gearbox
        -- limiter's brake priority for gears 2+). Min = pedal fraction that counts as braking.
        BrakePriority    = true,
        BrakePriorityMin = 0.15,
        -- GROUND-TRUTH SPEED CAP (2026-08-14 fix). The gear-1 rpm read is de-biased/painted on manual, so
        -- rpm can sit under Redline while the needle shows the cut → the rpm trip never fires and gear 1
        -- ACCELERATES past its true ratio top (same leak as gears 2+ on manual). Trip the bounce on EITHER
        -- rpm OR the un-paintable ratio speed cap (redline * RatioSeedK * mfv / gearRatio). DipKmh is the
        -- speed drop before the bounce releases (flutter depth). SpeedBounce=false = old rpm-only behaviour.
        SpeedBounce = true,
        -- TIGHT dip so the over-cap hold releases almost immediately = fast fuel-cut flutter (a real
        -- manual has no ECU governor; redline is a rapid brraap, not a slow coast-down). Was 6.0 (a lazy
        -- ~800ms bounce). ~1 km/h re-engages right away for the sharp redline chatter.
        DipKmh      = 1.0,
    },

    -----------------------------------------------------------------
    -- STAGE 2: BURNOUT / WHEELSPIN  (1st gear + handbrake + DRIFT MODE)
    -- The deliberate, on-demand wheelspin. Drift mode is REQUIRED — it's the "TC off"
    -- prerequisite (drift kills TC+ABS + drops grip). Builds HK.launchCharge = the
    -- stored torque surplus that Stage 3 hooks up into a nose-lift wheelie.
    -----------------------------------------------------------------
    Wheelspin = {
        Enabled     = true,

        -- GATE / STATE MACHINE (2026-08-16 rework — user gate spec). +hk_drift is HOLD-to-drift, so the
        -- CAPS key is shared: wheelspin and drift both live under it. The state machine keeps them from
        -- overlapping (see burnout.lua Burnout_WheelspinTick):
        --   ENTRY   — wheelspin arms ONLY from near-standstill (kmh <= EntryMaxKmh) with CAPS + real W,
        --             coupled + grounded. Hold CAPS ABOVE that speed = a NORMAL drift (never a wheelspin).
        --   SUSTAIN — once lit, hold it while CAPS is down all the way up. Grip returns over the
        --             GripReturn band (below) so 90->120 tightens the loose spin into a grippy slide.
        --   SLIDEOUT— release CAPS while sliding: grip RAMPS back to native over SlideOutMs (slides a beat
        --             longer, no snap). Re-press CAPS during ACTIVE/SLIDEOUT resumes the spin.
        --   CONVERT — tap SPACEBAR (handbrake) during a session -> hands off to normal drift; wheelspin
        --             won't re-arm until CAPS is released + a fresh <=15 entry.
        --   MinThrottle — W must be at least this to arm (real throttle).
        --   BrakeGate   — S(footbrake) >= this = PLANTED static brake-stand (only near the entry speed).
        --   EntryMaxKmh — arm only at/below this (near idle) so driving + CAPS never trips a wheelspin.
        --   MaxSpeedKmh — informational cap reference (the GripReturn band owns the actual tighten-up).
        MinThrottle = 0.55,
        BrakeGate   = 0.5,
        EntryMaxKmh = 15.0,
        MaxSpeedKmh = 120.0,

        -- GRIP-RETURN BAND (user: "90-120 is the max wheelspin moment — decrease loose spin, more grip").
        -- The spin scalar smoothsteps DOWN from 1.0 to GripReturnFloor across GripReturnLoKmh->HiKmh, so
        -- the loose spin tightens into a grippy slide through the band and holds a light slide above it.
        GripReturnLoKmh = 90.0,
        GripReturnHiKmh = 120.0,
        GripReturnFloor = 0.15,   -- residual slide intensity above the band (0 = full grip, 1 = full loose)

        -- SLIDEOUT (user: "on release, slowly ramp back to normal grip"): ms to ramp the spin from the
        -- release level down to 0 (native grip) after CAPS is let go. Longer = keeps sliding longer.
        SlideOutMs = 1500,

        -- TWO MECHANISMS (2026-08-16 "draggable wheelspin that slides forward"):
        --   PLANTED (S held) — SetVehicleBurnout = static brake-stand fry (pinned by design).
        --   ROLLING (no S)   — DROP the traction curves so the wheels break loose + smoke but keep partial
        --                      kinetic grip; the overpower torque then DRAGS the car forward through the
        --                      spinning wheels (a real rolling drag launch). This replaced the old
        --                      SetVehicleBurnout+CreepForce combo, which fought itself (native pin vs a
        --                      velocity shove) and only crept.
        -- Knobs:
        --   SpinTorqueMult    — extra engine torque so the wheels spin FASTER/harder than grip (the fry
        --                       AND the forward drag force in rolling mode). 2.5 = strong.
        --   GripMaxReduction  — how far peak grip (fTractionCurveMax) drops at full effect (rolling). Higher = looser.
        --   GripMinReduction  — how far breakaway grip (fTractionCurveMin) drops — the biggest "it's spinning" tell.
        --   GripLowSpeedSpinAdd— low-speed traction-loss ADDED (fLowSpeedTractionLossMult up) = fries off the line.
        --   WobbleDeg/Hz      — tiny tail wag while spinning (deg of yaw, drivetrain-scaled: RWD full). 0=off.
        SpinTorqueMult     = 2.5,
        GripMaxReduction   = 0.30,
        GripMinReduction   = 0.45,
        GripLowSpeedSpinAdd = 0.80,
        WobbleDeg          = 0.2,
        WobbleHz           = 1.5,
        WobbleBlend        = 0.5,   -- how hard the wobble yaw is chased via wsSetYaw (frame-correct write)

        -- STEERING + FEEL (2026-08-16):
        --   YawInjectMaxRate — LOW-SPEED STEERING FIX (user: "steering just moves the whole car sideways,
        --                      nose won't turn"). Below YawInjectHiKmh there's no lateral tyre force to
        --                      rotate the car, so we INJECT a steer-driven yaw rate (donut). rad/s at full
        --                      steer + standstill; faded to 0 by YawInjectHiKmh where grip steering takes
        --                      over. Higher = spins the nose faster on the spot. 0 = off.
        --   YawInjectHiKmh   — speed where the yaw injection has fully faded out (front-bias handles above).
        --   YawInjectBlend   — how hard the injected yaw rate is chased each frame (0..1); higher = snappier.
        --   SteerBiasFrontMult— above the yaw-inject band the curve drop is global (kills FRONT grip too),
        --                      so push fTractionBiasFront FORWARD by native*(1+this*eff) (RWD/AWD only) to
        --                      keep front bite for grip-steering. Higher = sharper nose, less rear-out.
        --   SlideFloor       — throttle modulates slidiness. Full W = loosest; lifting off eases grip back
        --                      toward this FLOOR (never fully hooks while a session is live) so you keep
        --                      sliding + can steer. 0.35 = zero throttle runs the slide at 35% intensity.
        --   SlideSpeedCut    — the drag-forward hauls the car too fast for a slide. Scrub this fraction of
        --                      the FORWARD-projected velocity each frame (lateral untouched). ~1/3 cut.
        YawInjectMaxRate   = 1.6,
        YawInjectHiKmh     = 55.0,
        YawInjectBlend     = 0.18,
        SteerBiasFrontMult = 0.30,
        SlideFloor         = 0.35,
        SlideSpeedCut      = 0.34,
        -- CreepForce (DEPRECATED 2026-08-16): the old velocity-shove rolling hack. Replaced by the grip
        -- drop above (real physics drag). Left at 0 = off; the code no longer reads it.
        CreepForce         = 0.0,

        -- CHARGE INTEGRATION: HK.launchCharge builds while the wheels actually SPIN.
        -- ChargeTau = seconds of full-slip spin to build one unit of charge (lower = faster
        -- build). SlipForFull = slip (m/s) that counts as "fully spinning" for the build rate.
        -- ChargeMax = ceiling. DecayTau = seconds to bleed a full charge back to 0 when NOT
        -- spinning (the surplus dissipates if you don't hook it up).
        ChargeTau   = 0.9,
        SlipForFull = 8.0,
        ChargeMax   = 1.0,
        DecayTau    = 0.5,

        -- DRIVETRAIN SCALE: RWD is the headline burnout; FWD/AWD fight themselves (driveline
        -- windup) so they get less surplus AND build charge slower. Keyed by drive class.
        DriveScale = {
            rwd = 1.0,
            awd = 0.45,
            fwd = 0.35,
        },
    },
}

-----------------------------------------------------------------
-- [B3] LAUNCH TRACTION (2026-08-16) — auto-wheelspin off the line (client/launchtraction.lua).
-- Real launch feel in gears 1-2: stab full throttle from a stop → tyres break loose (engine RAWRs, car
-- only creeps); feather or TAP-TAP-TAP W under the grip limit → clean hard launch. No drift key. This is
-- the traction model the AccelStretch stopgap was waiting on — it self-limits powerful cars by GRIP, so
-- slow cars (which don't break loose) stop being over-slowed by the global AccelStretch cut.
-- TWO triggers: A) LEVEL (grip budget rises with speed; throttle above it spins) + B) RATE (a violent
-- throttle STAB spins harder). Tapping wins on both counts.
-----------------------------------------------------------------
-----------------------------------------------------------------
-- GRIP-FIELD ARBITER (2026-08-16). Single-writer layer for the three shared driven-grip fields
-- (fTractionCurveMax/Min/fLowSpeedTractionLossMult). Features CLAIM a multiplier each frame; one committer
-- writes the highest-priority claim once (see HK.gripCommit in main.lua). Phase 1 = wheelspin family
-- (launch-traction, burnout, TC-off GripDrop, LC bump); drift keeps its own capture/restore and the arbiter
-- stands aside while drifting. Set Enabled=false to revert every migrated feature to direct vehlib writes.
-----------------------------------------------------------------
Config.GripArbiter = {
    Enabled = true,
    -- Phase 2 (2026-08-14): route DRIFT's three shared curve fields through the arbiter (prio 100, drift
    -- owns grip over the whole wheelspin family when held). false = drift reverts to its own legacy
    -- capture/restore and the arbiter stands aside during drift (Phase 1 behaviour).
    DriftClaim = true,
}

Config.LaunchTraction = {
    Enabled = true,
    Debug   = false,

    -- SCOPE: which gears + up to what speed the launch limit applies. Gear 1 = the classic launch;
    -- gear 2 lets a hard 1->2 on a powerful car chirp/spin. Index = gear, value = ceiling km/h.
    PerGearMaxKmh = { 55.0, 90.0 },

    -- GRIP BUDGET (Behavior A — level). The throttle fraction the tyres accept, rising with speed.
    --   Grip0       — budget at 0 km/h (low = flooring from a stop spins). 0.35 = only 35% throttle sticks.
    --   Grip1       — budget at GripFullKmh (>1 so full throttle hooks once rolling).
    --   GripFullKmh — speed where the budget reaches Grip1 (grip has "returned").
    --   FlyMassGripScale — powerful cars (HK.flyMass<1) get LESS budget (break loose easier); heavy/weak
    --                      (>1) get more. 0.5 = ±50% of the fm deviation. 0 = ignore power.
    Grip0            = 0.35,
    Grip1            = 1.05,
    GripFullKmh      = 45.0,
    FlyMassGripScale = 0.5,

    -- PER-CLASS LAUNCH CHARACTER (TC ON). Each drivetrain launches differently, not just "spins more/less":
    --   grip        — grip-budget multiplier (was DriveGripScale). RWD 1.0 loosest, AWD grippiest, FWD mid.
    --   torqueCut   — scales LaunchTorqueCut. AWD bogs LESS (it hooks + squats), RWD bogs full.
    --   spinShow    — scales the visible traction-curve drop (smoke). AWD shows the least (four-wheel bite).
    --   revFlare    — scales RevFlareTarget. AWD flares less (less wheelspin to rev against).
    --   torqueSteer — FWD-only: launch spin tugs the nose toward one side (yaw nudge, deg/s-ish). 0 = none.
    -- RWD: spins easiest, big bog + flare, no torque steer. AWD: hooks + squats, minimal bog/smoke, quickest
    -- clean getaway. FWD: front scrabble + torque-steer wander even with TC, mild.
    Class = {
        rwd = { grip = 1.00, torqueCut = 1.00, spinShow = 1.00, revFlare = 1.00, torqueSteer = 0.00 },
        awd = { grip = 1.35, torqueCut = 0.70, spinShow = 0.65, revFlare = 0.80, torqueSteer = 0.00 },
        fwd = { grip = 1.12, torqueCut = 0.88, spinShow = 0.85, revFlare = 0.92, torqueSteer = 0.55 },
    },

    -- TC OFF — the DriveGripScale bonus IS traction control doing its job. Turn /tc off and claw it back so
    -- AWD/FWD can break traction on launch too (not just RWD). Reads HK.dtTCOff.on (TC armed + switched off).
    --   GripClawback — grip-budget multiplier per class when TC is off (AWD/FWD lose most of their bonus).
    --   TorqueCutBoost / SpinShowBoost / RevFlareBoost — launch effects get louder with TC off.
    TCOff = {
        Enabled        = true,
        GripClawback   = { rwd = 0.92, awd = 0.72, fwd = 0.82 },
        TorqueCutBoost = 1.25,
        SpinShowBoost  = 1.30,
        RevFlareBoost  = 1.15,
    },

    -- STAB penalty (Behavior B — rate). A fast throttle jab (dThr/dt above StabThresh per second) adds a
    -- decaying penalty that eats into the grip budget, so a violent stab spins even mid-launch.
    --   StabThresh  — throttle units/sec above which a jab counts (2.5 ≈ 0->full in 0.4s).
    --   StabGain    — how much penalty each unit of over-rate adds.
    --   StabMax     — ceiling on the penalty.
    --   StabDecayMs — how fast the penalty bleeds off after the jab (so a tap's stab is gone by next tap).
    StabThresh  = 2.5,
    StabGain    = 0.15,
    StabMax     = 0.6,
    StabDecayMs = 200,

    -- OVERSHOOT -> spin. How far (throttle + stab) exceeds the budget, times OverGain, clamped 0..1.
    OverGain = 1.6,
    -- SLIP CONFIRM: only fully commit the bog when the wheels are ACTUALLY loose (belt-and-suspenders so an
    -- AWD car that hooks up despite a stab isn't falsely bogged). SlipRef = slip (m/s) that counts as fully
    -- spinning; MinCommit = bog fraction applied when commanded-but-not-yet-slipping (tyres about to break).
    SlipRef   = 3.0,
    MinCommit = 0.4,

    -- EFFECTS (all scaled by spin):
    --   LaunchTorqueCut  — forward-drive cut at full spin (the "creeps only a bit"). 0.6 = up to 60% cut,
    --                      hard-capped at 0.9 so it never fully kills drive (always a creep).
    --   Grip*Reduction / GripLowSpeedSpinAdd — the visible spin/smoke (traction-curve drop, native*mult).
    --   RevFlare/RevFlareTarget — publish a requested rpm floor (HK.launchRevFloor) so the engine can RAWR
    --                      while road speed stays low. Conservative: the gearbox owns the needle; this is a
    --                      floor request, honored if wired, harmless if not (the spin is already visible).
    LaunchTorqueCut     = 0.6,
    -- UPHILL RELIEF: fade the torque bog out as the uphill grade rises so a hard throttle can still CLIMB a
    -- steep hill (on a climb the loaded tyres read as slip and would otherwise bog drive to a crawl). Bog is
    -- full on the flat, ZERO at this grade (sin(pitch): ~0.30 ≈ a 17° hill). Downhill launches bog normally.
    HillReliefGrade     = 0.30,
    GripMaxReduction    = 0.25,
    GripMinReduction    = 0.40,
    GripLowSpeedSpinAdd = 0.70,
    RevFlare            = true,
    RevFlareTarget      = 0.85,
}

-----------------------------------------------------------------
-- [D5] DYNAMIC AWD SIMULATION (faked via drive/traction bias)
-- Shifts drive bias toward the front when the rear is spinning or the
-- car is rotating too much, then relaxes back to the car's native bias
-- on a clean straight. Makes RWD feel like it has an electronic AWD
-- safety net without permanently changing the car's character.
-----------------------------------------------------------------
-- RECENTER TAPER (2026-08-13) — shared by the "fix rear then return to center" family
-- (drift exit-recovery yaw damp + AWD/RWD spin softeners). Fades the recenter force as the car nears
-- straight so the return eases into center instead of snapping flat at the settle. Yaw rate owns the
-- near-center fade (same variable the damp writes → clean asymptote, kills overshoot swinging back
-- through center); slip angle is a soft floor that holds the taper up while genuinely sideways so it
-- can't back off mid-slide. Consumed via HK.recenterTaper(yawRate, slipDeg); callers multiply their
-- damp coefficient by it. TUNING deferred to end-of-project pass — these are conservative starts.
-----------------------------------------------------------------
Config.RecenterTaper = {
    Enabled        = true,
    YawZeroRate    = 0.15,   -- rad/s: at/below this the car is "straight" → taper 0 (force faded out)
    YawFullRate    = 0.60,   -- rad/s: at/above this → full recenter force (real rotation)
    SlipFloorGateDeg = 6.0,  -- deg: slip below this contributes no floor
    SlipFloorFullDeg = 18.0, -- deg: slip at/above this → full floor weight
    SlipFloorWeight  = 0.85, -- max taper the slip floor can hold up (never a hard 1.0 → yaw still leads)
}

-----------------------------------------------------------------
-- DRIVETRAIN-AWARE base handling (client/drivetrain.lua). Classifies each
-- car by fDriveBiasFront and routes to a per-drivetrain branch. Runs OUTSIDE
-- drift mode only. Classification (from the drivetrain-threshold notes):
--   RWD  : bias < 0.49   -> real oversteer model (progressive oversteer + counter-steer + lift + softener + drive-out)
--   AWD  : 0.49 .. 0.61  -> understeer on power + traction governor + torque vectoring + power-out save
--   FWD  : bias > 0.61   -> full hot-hatch model (understeer, drive-out, lift + speed-scale + snap softener, torque steer, sport-diff, spin penalty, brake understeer)
-- Was Config.AWD (RWD-only wheelspin assist); expanded 2026-08-10.
Config.Drivetrain = {
    Enabled = true,

    ----------------------------------------------------------------
    -- WEIGHT-TRANSFER SPINE (2026-08-14) — the central load model.
    -- GTA's vehicle physics is a rigid box with static per-axle grip: braking never unloads the rear,
    -- accel never unloads the front, cornering never shifts grip to the outside. Every drivetrain
    -- helper we've built (power understeer, lift rotation, drive-out plant, spin softeners...) is a
    -- targeted fake for ONE consequence of the weight transfer GTA is missing. This computes the load
    -- ONCE per frame into HK.load so every tool can read a single consistent signal instead of each
    -- re-deriving throttle×lateral×speed its own way. PHASE 2 = additive + read-only: it publishes the
    -- signal + overlay but nothing consumes it yet. Existing helpers get migrated to read it ONE AT A
    -- TIME (feel-checked each) so the tuned RWD/AWD feel can't regress in a big-bang rewrite.
    --   HK.load = { long -1..1 (- brake/nose-down .. + accel/squat), lat -1..1 (sign=turn dir),
    --               front 0..1, rear 0..1 (effective axle loads), accel m/s^2 (smoothed dv/dt) }
    WeightTransfer = {
        Enabled       = true,
        -- Longitudinal load comes from BOTH the pedal inputs (immediate intent) and the measured
        -- longitudinal accel (ground truth). Blend so it responds instantly to a pedal but is anchored
        -- by real accel (a pedal held against a wall = no transfer).
        AccelMaxMs2   = 12.0,   -- |long accel| that maps to full ±1 load from the measured-accel term (~1.2g)
        AccelWeight   = 0.55,   -- how much of `long` comes from measured accel vs pedal intent (0..1)
        AccelTau      = 0.08,   -- smoothing (s) on the raw dv/dt accel estimate (kills frame noise)
        LongTau       = 0.10,   -- smoothing (s) on the final longitudinal load
        -- Lateral load from cornering. Uses lateral speed (m/s sideways) scaled by how fast we're going
        -- (a given slip angle loads the tyres more at speed), plus yaw as the direction/urgency cue.
        LatMaxMs      = 8.0,    -- lateral speed (m/s) that maps to full ±1 lateral load
        LatTau        = 0.10,   -- smoothing (s) on lateral load
        -- Axle-load split. Static 0.5/0.5 at rest; long load shifts it (brake→front, accel→rear).
        AxleShiftMax  = 0.35,   -- max fraction shifted off one axle onto the other at full long load
    },

    ----------------------------------------------------------------
    -- TC-OFF DRIVETRAIN RESPONSE (2026-08-14) — makes "/tc off" (or the F1 radial toggle) FEEL like a
    -- real TC-off, per drivetrain, instead of just "engine stops cutting torque". Two moves, opposite
    -- directions, both realistic:
    --   (1) STAND DOWN the TC-LIKE stability tools — the ones whose whole job is to tame a power spike:
    --       RWD ProgressiveOversteer's torque-feather, FWD SpinPenalty's cut, AWD TractionGovernor's
    --       forward-bias "plant". With TC off, these back off (scaled by StabilityStandDown) so the
    --       wheels are ALLOWED to break loose — that's the point of switching TC off.
    --   (2) let the rotation-CHARACTER tools speak up a touch (RWD PowerSpin fry, FWD TorqueSteer tug)
    --       via CharacterBoost, so the loss of traction is dramatic and legible, not just "slidey".
    -- ARCADE SAFETY NET: the yaw-RATE softeners (RWD/FWD SpinSoftener) are DELIBERATELY left at full
    -- authority — they only ever slow how FAST a slide develops, never cap the angle. So TC-off gives
    -- you the full drama + more angle, but the rate stays human-catchable. Realistic function, arcade
    -- forgiveness. Gate reads HK.tcOff (set by /tc and the radial menu, replicated statebag hk_tc_off).
    TCOff = {
        Enabled           = true,
        StabilityStandDown = 0.70,  -- 0..1: how much the TC-like stability cuts are REDUCED when TC off
                                    -- (0.70 = they run at 30% strength — mostly out of the way, but a
                                    -- sliver remains so a violent snap is still slightly feathered).
        CharacterBoost    = 1.35,   -- multiply the rotation-character tools' engagement (PowerSpin/
                                    -- TorqueSteer) when TC off. Kept modest — the real drama comes from
                                    -- the stand-down freeing the wheels, this just sharpens the tell.
        RwdOversteerFree  = true,   -- RWD: stand down ProgressiveOversteer torque-feather
        FwdSpinFree       = true,   -- FWD: stand down SpinPenalty torque cut
        AwdGovernorEase   = 0.55,   -- AWD: 0..1 fraction to EASE the traction-governor's plant when TC
                                    -- off (0.55 = plant runs at 45%). AWD never goes full-loose (4wd),
                                    -- but it should rotate + light up far more than TC-on.

        -- PROACTIVE GRIP DROP (2026-08-14) — the piece that makes TC-off actually FELT. The stand-down/
        -- boost above only change how the tools REACT to slip that already exists; on a grippy car you
        -- may never generate that slip, so "off" felt the same as "on". This drops peak driven-axle grip
        -- (fTractionCurveMax) WHILE ON THROTTLE the moment TC is off — an always-present effect: plant the
        -- gas and the car genuinely wants to break loose / step out, exactly like a real TC-off pull-away.
        -- Scaled in by throttle so cruising is untouched; restored to native instantly when TC goes back
        -- on or you lift. This is the SINGLE writer of fTractionCurveMax outside drift (verified) so no
        -- field-ownership conflict. Speed-faded so it's strongest where you feel it (launches/corner exit).
        -- Three grip fields drop together (same trio drift.lua uses to break a car loose — safe to
        -- reuse here because drift force-disables TC, so the two never write at once):
        --   * fTractionCurveMax  = PEAK grip. Cutting it lowers the ceiling the driven axle can hold.
        --   * fTractionCurveMin  = BREAKAWAY grip past peak. THIS is the one you feel — cut it and the
        --                          tail steps out / fronts scrabble the instant you overpower the tyre.
        --   * fLowSpeedTractionLossMult = off-the-line wheelspin. Higher = more launch fry (the classic
        --                          "TC off, floor it, wheels light up" tell). We RAISE this one.
        GripDrop = {
            Enabled        = true,
            MaxReduction   = 0.22,   -- peak fTractionCurveMax cut at full throttle (0.22 = 22% less peak grip)
            MinReduction   = 0.34,   -- fTractionCurveMin (breakaway) cut — bigger than peak: this is the
                                     -- field that makes "off" actually step out. 0.34 = 34% less hold past peak.
            LowSpeedSpinAdd = 0.60,  -- fLowSpeedTractionLossMult BOOST at full effect (0.60 = +60% → the
                                     -- driven wheels fry off the line / on corner-exit stabs, TC-off signature)
            ThrottleGate   = 0.30,   -- below this throttle, no drop (cruising/trailing throttle stays planted)
            ThrottleFull   = 0.80,   -- throttle at which the drop is at max (lowered so it bites sooner)
            SpeedLowKmh    = 5.0,    -- full effect from here…
            SpeedHighKmh   = 200.0,  -- …tapering to HighSpeedFloor by here (was 140 → 0, which killed the
                                     -- feel exactly where fast cars corner; now it persists up top)
            HighSpeedFloor = 0.45,   -- residual effect fraction at/above SpeedHighKmh (never fully fades —
                                     -- so a 200+ km/h corner-exit stab still steps the tail out)
            EngageTau      = 0.09,   -- smooth in (no grip cliff)
            ReleaseTau     = 0.13,   -- smooth back to native on lift / TC-on
        },
    },

    ----------------------------------------------------------------
    -- THROTTLE MODEL (2026-08-13) — device-agnostic effective throttle.
    -- The throttle-graduated features (RWD #1/#3/#4, and anything else that reads a throttle band)
    -- assume an ANALOG pedal. But MOST players are on KEYBOARD, where W is binary — GetControlNormal
    -- 71 only ever returns 0.0 or 1.0. Without help, a keyboard player skips every "moderate gas" band
    -- and teleports to full throttle instantly, so all the throttle-as-steering nuance is invisible to
    -- them. We synthesize an EFFECTIVE analog throttle from time-pressed + rpm that works the same
    -- across keyboard / controller / (future) wheel:
    --   * KEYBOARD (binary): tapping/short-hold ramps effective throttle up over SqueezeUpMs, so a tap
    --     sits you in the plant band and a hold sweeps you into throttle-steer — feathering by tapping
    --     becomes the keyboard half-pedal. Release decays over SqueezeDownMs.
    --   * CONTROLLER / WHEEL (analog): the real 0..1 passes through a light low-pass (barely altered —
    --     just a hair of realistic pedal travel), so their native modulation is preserved.
    --   * RPM factor: scales aggression so low-rpm full throttle doesn't over-rotate (no revs = no
    --     torque = no rotation), matching real power delivery. Exposed as state.rpmFactor for features.
    -- Detection: if the raw control value is ever seen strictly between the analog epsilons across a
    -- short window, we treat the device as ANALOG and pass through; otherwise BINARY (keyboard) and we
    -- synthesize. Auto-detects per session, no per-player config.
    ThrottleModel = {
        Enabled       = true,
        EnabledByDefault = true, -- seeds HK.pedalModelOn at load (throttle+brake models on by default; /pedalmodel toggles)
        ApplyInput    = true,   -- inject the modeled pedal via SetControlNormal(71) so tap-hold actually drives the car (false = gauge/assist only)
        InjectEpsilon = 0.02,   -- don't inject below this (lets the gearbox's throttle-kill states win cleanly)
        SqueezeUpMs   = 440.0,  -- keyboard: base ms of held W to sweep 0→1. 320→440: user "not smoothing the throttle enough" — longer sweep = more analog-feeling build (rpm/speed curves still shape it).
        SqueezeDownMs = 340.0,  -- keyboard: BASE decay ms with NO recent taps. 420→340: user "exit a little too long". Still slower than a rise-tap so a clean lift bleeds revs gently, not instantly.
        -- EASE-IN (slow-then-fast within the sweep): rate = RiseFloorMult + (1-RiseFloorMult)*progress.
        -- Lower floor = creeps off zero harder before accelerating. 1.0 = linear (no ease).
        RiseFloorMult  = 0.35,
        -- RPM-SCALED RAMP: slower pedal build at low rpm (fragile launch/low-gear — feather), faster up
        -- high (committed — snap in). Multiplies the ramp rate across the rpm band. Set both to 1.0 to disable.
        RpmRampLow     = 0.30,   -- rpm (0..1) at/below which RpmRampLowMult applies
        RpmRampHigh    = 0.70,   -- rpm at/above which RpmRampHighMult applies
        RpmRampLowMult = 0.60,   -- ramp-rate multiplier at low rpm (<1 = slower build off the bottom)
        RpmRampHighMult= 1.30,   -- ramp-rate multiplier at high rpm (>1 = snappier build up top)
        -- REVERSE: when reversing (S is the accelerator), skip rpm scaling and use this ONE flat, even
        -- slower multiplier — creeping backward wants a heavy, precise pedal. Lowest of all the ramps.
        ReverseRampMult = 0.45,  -- reverse ramp-rate multiplier (< RpmRampLowMult = slower than forward low-rpm)
        -- REVERSE = STRETCHED RAMP (not a cap): native GTA reverse winds up too fast and fishtails. Reverse
        -- uses SIMPLE-RAMP mode (no tap-hold — you don't feather reverse), with a build that's ≥2× the
        -- forward sweep and stretched EVEN LONGER at low speed (creeping off a standstill is the twitchy
        -- part). Holding S keeps building speed but stays much slower than GTA the whole way. Full IS
        -- reachable — just slowly. (Forward SqueezeUpMs is 320, so 900/1500 here are ~3-5× slower.)
        ReverseUpMs          = 900.0, -- reverse ramp ms at higher reverse speed (already moving back)
        ReverseUpMsLow       = 1500.0,-- reverse ramp ms at/below ReverseSlowKmh (creep off standstill — longest)
        ReverseSlowKmh       = 3.0,   -- at/below this reverse speed use ReverseUpMsLow (the long ramp)
        ReverseFastKmh       = 25.0,  -- at/above this, ramp eases back to ReverseUpMs
        ReverseDownMs        = 300.0, -- reverse release decay ms
        ReverseRiseFloorMult = 0.18,  -- reverse ease-in floor (very low = strong slow creep before it builds)
        -- SPEED-SCALED RAMP (2026-08-13): at high speed, throttle comes in a touch SLOWER so corner-exit
        -- power doesn't snap the rear loose (anti snap-oversteer). Multiplies onto the rpm scale. 1.0/1.0=off.
        SpeedRampLowKmh  = 40.0,  -- km/h at/below which SpeedRampLowMult applies
        SpeedRampHighKmh = 150.0, -- km/h at/above which SpeedRampHighMult applies
        SpeedRampLowMult = 1.0,   -- ramp mult at low speed (1.0 = unchanged)
        SpeedRampHighMult= 0.80,  -- ramp mult at high speed (<1 = gentler throttle up top)
        -- GAMMA (AC-style pedal curve): output = pos^Gamma. >1 = finer control in the bottom half (a light
        -- press sits low instead of racing to mid). Integration stays linear; only the OUTPUT is shaped. 1.0=off.
        Gamma          = 1.4,
        -- TAP-CADENCE → TARGET HOLD (v2, "converge not integrate"). Tapping W rhythmically CONVERGES the
        -- pedal to a steady target level set by how fast you tap, and LOCKS there (no hump up/down). Faster
        -- taps = higher target; lazy taps = lower; holding the key past HoldDetectMs = a real floor-it that
        -- ramps to full. Gap between taps → cadence (0..1): <=TapFastGapMs → 1, >=TapSlowGapMs → 0.
        HoldDetectMs   = 175.0,  -- key held longer than this (ms) = genuine hold (ramp to full), not a tap
        TapFastGapMs   = 110.0,  -- tap gap (ms) at/below which cadence = 1.0 (fast spam)
        TapSlowGapMs   = 420.0,  -- tap gap at/above which cadence = 0
        TapTargetFloor = 0.15,   -- held throttle target at slowest countable tap rate (× maxPos)
        TapTargetCeil  = 0.90,   -- held throttle target at fastest spam (× maxPos; <1 so full is hold-only)
        TapConvergeMs  = 130.0,  -- how fast the pedal eases to the tap target (smaller = snappier lock)
        TapMemoryMs    = 550.0,  -- after this long with no tap (and not held), release to 0
        CadenceDecayMs = 700.0,  -- how fast the cadence memory fades once you stop tapping
        AnalogLowpassMs = 90.0, -- controller/wheel: light smoothing time-constant (small = barely-there pedal lag)
        AnalogEpsilon = 0.06,   -- raw value seen in (eps, 1-eps) → device is analog. Keyboard only ever hits 0 or 1
        AnalogDetectMs = 1500.0,-- once an analog value is seen, stay in analog mode this long before reconsidering
        RpmFloor      = 0.30,   -- rpm (0..1) at/below which rpmFactor = RpmFloorMult (bogging, little torque)
        RpmFull       = 0.70,   -- rpm at/above which rpmFactor = 1.0 (in the power)
        RpmFloorMult  = 0.45,   -- aggression multiplier at/below RpmFloor (low-rpm full throttle rotates less)
    },

    ----------------------------------------------------------------
    -- BRAKE MODEL (2026-08-13) — device-agnostic effective brake, mirror of the throttle model on the
    -- SAME shared pedal engine. Keyboard S is binary (slam-or-nothing → instant lockup); this synthesizes
    -- graduated brake travel so keyboard players get threshold braking and trail-braking. Its OWN gamma
    -- (brake wants finer feel near the TOP of travel) and OWN speed scaling (ramp slower at speed so a
    -- stab can't instantly lock the fronts). state.effBrake is what a brake consumer should read.
    -- CONSUMER: effBrake scales fBrakeForce (keyboard synth only), composed with ABS via HK.brakeForceMult.
    BrakeModel = {
        Enabled       = true,
        ApplyForce    = true,   -- actually scale fBrakeForce by the modeled pedal (false = model+overlay only, no feel)
        SqueezeUpMs   = 300.0,  -- keyboard: base ms of held S to sweep brake 0→1 (slightly quicker than gas — you want brakes NOW)
        SqueezeDownMs = 200.0,  -- ms to release (quick — foot off the brake is immediate)
        RiseFloorMult = 0.45,   -- ease-in floor (higher than throttle — initial bite comes on sooner)
        -- BRAKE GAMMA: separate from throttle. >1 = finer modulation low in travel (threshold braking).
        Gamma         = 1.5,
        -- SPEED SCALE: high speed = ramp in slower (anti front-lock / threshold-brake feel); crisp when slow.
        SpeedRampLowKmh  = 40.0,
        SpeedRampHighKmh = 160.0,
        SpeedRampLowMult = 1.0,
        SpeedRampHighMult= 0.75,
        -- ONSET CURVE (2026-08-14): brake FORCE eases in on a curve instead of slamming to full the
        -- instant you press — like a real driver rolling onto the pedal. Works for ALL devices (scales
        -- fBrakeForce via HK.brakeForceMult), not just the keyboard pedal synth. On the press edge a
        -- 0→1 ramp runs over OnsetMs along an ease-in curve (^OnsetGamma), starting at OnsetFloor (never
        -- zero — you still slow immediately), reaching full bite at the end. STEERING makes it softer +
        -- longer: the more lock held, the more OnsetSteerExtraMs is added and the lower the initial bite
        -- (OnsetMinFloorAtLock), so trail-braking into a corner is smooth instead of snapping the front.
        -- A straight-line stab still gets the (mild) curve. Reduction-only (≤1.0): full braking power is
        -- always reached after the window — this shapes the FIRST fraction of a second, never caps force.
        OnsetCurve        = true,
        OnsetMs           = 260.0,  -- straight-line time (ms) for brake force to ease from floor to full
        OnsetGamma        = 1.8,    -- ease-in shape (>1 = softer at the very start, firming up)
        OnsetFloor        = 0.35,   -- initial bite fraction at the press instant, STRAIGHT line
        OnsetSteerExtraMs = 300.0,  -- extra onset time added at FULL steering lock (progressive corner entry)
        OnsetMinFloorAtLock = 0.22, -- initial bite fraction at FULL lock (lower than straight = gentler turn-in)
        OnsetReleaseMs    = 120.0,  -- ms for the onset ramp to reset after releasing the brake (quick re-arm)
        -- TAP-CADENCE → TARGET (v2): tap S rhythmically to CONVERGE and LOCK a partial brake (cadence
        -- braking / corner balance). Same converge mechanism as throttle.
        HoldDetectMs   = 175.0,
        TapFastGapMs   = 110.0,
        TapSlowGapMs   = 420.0,
        TapTargetFloor = 0.15,
        TapTargetCeil  = 0.85,   -- slightly under throttle's — hard braking should mean a real hold
        TapConvergeMs  = 110.0,  -- brake locks a hair snappier
        TapMemoryMs    = 500.0,
        CadenceDecayMs = 600.0,
        AnalogLowpassMs = 90.0,
        AnalogEpsilon = 0.06,
        AnalogDetectMs = 1500.0,
    },

    ----------------------------------------------------------------
    -- STEERING MODEL (2026-08-14) — device-agnostic analog STEER for keyboard, third of the input-model
    -- trio (throttle/brake/steer). Keyboard A/D are binary (full-lock-or-nothing → darty, twitchy), so we
    -- synthesize graduated steering travel: hold A/D and the wheel WINDS toward lock over time; release and
    -- it SPRINGS back to center faster. Analog devices (pad/wheel) pass through their native control 59.
    -- DESIGN (from sim-racing research — Assetto/iRacing/adam10603 keyboard-steer):
    --   * TIME-RAMP is LINEAR (no ease-in gamma on the ramp itself). Nonlinearity lives in SPEED-SCALING.
    --   * Steer-IN is SLOWER than the throttle build (a wheel is heavier than a pedal, and slow-in is what
    --     keeps keyboard steering from snapping the car sideways). RECENTER is FASTER than steer-in (a
    --     released wheel springs back). Countersteer is DRIFT's job — we only wind toward / spring to zero.
    --   * SPEED-SCALED RATE: at speed the slew slows (anti-twitch); crisp when slow (parking/low-speed).
    --     This is the RATE knob. It composes with Config.SteerRangeLowSpeed, which scales the max ANGLE
    --     (fSteeringLock). Orthogonal: one shapes how FAST the input moves, the other how FAR it can go.
    -- SINGLE WRITER on control 59 (what hk-handling reads as state.steer). Keyboard-only, off-drift, toggle
    -- via /steermodel. NOT tied to hk-wheel (that companion path is a separate, untested trial).
    SteeringModel = {
        Enabled          = true,
        EnabledByDefault = true,   -- seeds HK.steerModelOn at load (mirror of the pedal models' toggle seed)
        -- RAMP TIMES (ms to sweep center→full-lock / full→center). Steer-in slow, recenter fast.
        SteerInMs   = 420.0,   -- ms of held A/D to wind from center to full lock (slower than throttle's 440 build feel — heavy wheel)
        RecenterMs  = 260.0,   -- ms to spring back to center on release (faster than steer-in — released wheel returns)
        -- SPEED-SCALED RATE: multiplier on BOTH rates. 1.0 at/below LowKmh → HighMult at/above HighKmh.
        SpeedRateLowKmh  = 30.0,   -- km/h at/below which SpeedRateLowMult applies (full, crisp low-speed steer)
        SpeedRateHighKmh = 160.0,  -- km/h at/above which SpeedRateHighMult applies (slowest, calmest high-speed steer)
        SpeedRateLowMult = 1.0,    -- rate mult at low speed (1.0 = unchanged, snappy parking steer)
        SpeedRateHighMult= 0.45,   -- rate mult at high speed (<1 = gentler, slower wind so high-speed isn't darty)
        -- ON-CENTER GAMMA (optional): output = |x|^Gamma * sign. >1 desensitizes dead-center only. 1.0 = off
        -- (linear — the default; the ramp already gives the feel, add this only if on-center feels twitchy).
        Gamma            = 1.0,
        -- REVERSE RANGE CLAMP: scale the steering output while backing up (forwardSpeed < 0.5). Reverse
        -- steers too fast at full range, so limit the lock. 0.75 = 75% of full angle. 1.0 = no clamp.
        ReverseRangeMult = 0.75,
        -- AIRBORNE RECENTER (2026-08-14): GTA converts a steered FRONT-WHEEL angle into vehicle YAW while
        -- airborne (no tyre grip to resist it) — so any held/carried steer angle when you leave a ramp
        -- SPINS the car in the air instead of letting it fly forward ("Dr Strange pushed it sideways").
        -- Fix: while off all wheels, ease the steering output toward CENTER so no air-yaw is injected and
        -- the car lands straight. Fast tau (the wheels should snap flat in the air). Recovers instantly on
        -- touchdown (the integrator re-winds from center to whatever the player is holding). This does NOT
        -- fight mid-air stunt control from other systems — it only zeroes the STEER angle we write.
        AirborneRecenter    = true,
        AirborneRecenterMs  = 140.0,   -- ms to ease the wheel to center once airborne (fast = flat quickly)
        -- TAP-HOLD (steering sibling of the pedal tap-hold): rhythmic A/D feathering settles on a STABLE
        -- partial lock (a shallow constant angle) instead of sawtoothing; a genuine hold still winds to full.
        -- The slew above drives to whichever target, so no separate converge rate. Direction is remembered
        -- between taps (P.lastDir) since the key is up mid-cadence. false = pure bang-bang steer-in/recenter.
        TapHold        = true,
        TapFastGapMs   = 110.0,  -- tap gap (ms) at/below which cadence = 1.0 (fast feather = more lock held)
        TapSlowGapMs   = 400.0,  -- tap gap at/above which cadence = 0 (lazy feather = shallow lock held)
        TapTargetFloor = 0.22,   -- held lock at slowest countable tap (× full) — the minimum a tap can set
        TapTargetCeil  = 0.80,   -- held lock at fastest feather (× full; <1 so full lock stays hold-only)
        TapMemoryMs    = 320.0,  -- after this long with no tap (key up) the wheel recenters (springs back)

        -- RWD SLIDE-CATCH (2026-08-14) — the ONE place the steer model behaves differently per drivetrain.
        -- RWD lives on countersteer: when the tail steps out you must throw opposite lock and bring it
        -- back FAST to catch the slide. FWD/AWD basically never countersteer, so they keep the calm base
        -- rates. This speeds the steer-model slew ONLY when: class == RWD, the car is genuinely sliding
        -- (slip angle past the gate), and above a min speed. Scaled by how far it's out (0 at the gate →
        -- full by SlipFullDeg), so normal RWD driving feels identical — the bump only wakes up in a slide.
        -- Recenter/cross-center (the catch direction) gets the big bump; winding-in gets a smaller one so
        -- you can't accidentally over-rotate INTO the slide faster than you can catch it. Reads the class
        -- from HK.dbgDrive (Drivetrain_Tick runs earlier the same frame). Keyboard-synth only (like the
        -- rest of the steer model); analog wheel/pad already has full-rate manual control.
        RwdSlideCatch = {
            Enabled       = true,
            MinSpeedKmh   = 25.0,   -- below this, low-speed pivots don't need the catch bump
            SlipGateDeg   = 12.0,   -- slip angle (heading vs velocity) where the catch bump starts
            SlipFullDeg   = 35.0,   -- at/above this slip, the full bump applies
            RecenterMult  = 1.45,   -- recenter + cross-center (the catch) up to 45% faster at full slide
            TurnInMult    = 1.15,   -- winding toward lock only 15% faster (don't over-rotate into the slide)
        },
    },


    ----------------------------------------------------------------
    -- HANDBRAKE-RELEASE CUSHION (2026-08-14) — ALL DRIVETRAINS.
    -- When you let go of the handbrake, GTA re-grips the locked rear wheels in a single frame. That
    -- instantaneous re-grip is a velocity DISCONTINUITY: it snaps forward speed down too hard AND turns
    -- any leftover tail-out into a yaw spin ("spins in a weird way"). Same native velocity-dump family
    -- as the airborne-landing / hard-downshift re-grip. This softens the release for a short window:
    -- caps the decel (adding back only the excess speed the snap stole — never pushes faster than you
    -- were going) and bleeds the yaw/lateral transient. Fades out by the time speed drops to HALF the
    -- release speed (user: "scale it off slower for at least half the speed"). Sign-safe throughout.
    ----------------------------------------------------------------
    HandbrakeRelease = {
        Enabled       = true,
        MinReleaseKmh = 15.0,   -- below this speed at release, skip (parking-speed = no violent snap)
        CushionMs     = 900,    -- hard end of the cushion window after release (ms)
        FadeToFrac    = 0.5,    -- fade the cushion to zero as speed drops to this FRACTION of the
                                -- release speed. 0.5 = eased off across the top half of the speed you
                                -- had when you let go (the "at least half the speed" the user asked for).
        MaxDecelMs2   = 7.0,    -- cap decel to this (m/s²); anything harder gets the excess speed added
                                -- back. ~0.7g — a firm but not neck-snapping slowdown. LOWER = gentler
                                -- (holds more speed through the release); HIGHER = lets it slow harder.
        YawDampScale  = 0.85,   -- yaw-rate multiplier at full strength (0.85 = bleed 15%/frame of spin).
                                -- LOWER = kills the release-spin harder; 1.0 = no yaw cushion.
        LatDampScale  = 0.9,    -- lateral-velocity multiplier at full strength (bleed 10%/frame of slide)
        MinLatMs      = 0.5,    -- don't bother damping lateral below this (straight-line release)
        BrakeCancel   = 0.4,    -- foot brake above this cancels the cushion (a real stop you asked for)
    },

    ----------------------------------------------------------------
    -- RWD: wheelspin assist (fake AWD safety net for rear-drive cars)
    -- [ENABLED 2026-07-18] Sends power/traction forward when the rear
    -- slips or the car rotates hard, relaxing to native on a clean straight.
    ----------------------------------------------------------------
    RWD = {
        Enabled = true,

        -- 2026-08-13: LEGACY FAKE-AWD ASSIST — RETIRED by default. The old behavior sent drive/
        -- traction bias FORWARD (toward 0.50, momentarily faking AWD) whenever the rear spun or the
        -- car rotated hard — an arcade traction net that made RWD feel LESS like RWD (real rear-drive
        -- cars don't grow front driveshafts when they step out; the driver catches it). Replaced by a
        -- real RWD model (progressive power-oversteer etc. below). Flip this true to restore the old
        -- safety net if a real build ever feels worse.
        LegacyAssist = false,

        -- How far toward the front we can push bias when slipping (legacy assist only).
        -- 0.5 = even split. Added to native bias, capped here.
        MaxFrontBias = 0.50,

        -- Slip detection: rear wheel spin (m/s over ground) to start shifting.
        SpinThreshold = 3.0,

        -- Yaw assist: also pull power forward when rotating hard (rad/s).
        YawAssistThreshold = 1.4,

        -- Speed gate — below this, leave bias alone (low-speed maneuvering).
        MinSpeedKmh = 15.0,

        -- Smoothing of the bias transition.
        EngageTau  = 0.144,   -- 2026-08-13: +20% engage time (0.12→0.144) — all AWD help eases in slower
        ReleaseTau = 0.45,

        -- Also nudge front traction bias so the front bites when powered (legacy assist only).
        TractionBiasAssist = 0.06,  -- max added to fTractionBiasFront

        -- PROGRESSIVE POWER-OVERSTEER (2026-08-13 — real RWD build #1). GTA's RWD doesn't break
        -- traction too FAR, it breaks too FAST — the tail snaps out on a yaw-acceleration spike that's
        -- almost impossible to catch. Real RWD lets go PROGRESSIVELY: wheelspin builds, the rear
        -- steps out over a beat, and a skilled driver feathers throttle / catches it. So we smooth the
        -- RATE of breakaway, not its magnitude — you can still hang the tail fully out; it just won't
        -- snap. Mechanism: when rear wheelspin is RISING FAST (the spike that causes the snap), apply a
        -- light, brief engine-torque trim (same HK.torqueMult path as TractionControl — a torque cut,
        -- no bog) to feather that spike. Steady-state slides aren't touched (rate ~0 = no cut), and
        -- it NEVER adds grip or bias — it can't save you, only slow the initial snap so it's catchable.
        ProgressiveOversteer = {
            Enabled       = true,
            MinSpeedKmh   = 18.0,   -- below this, low-speed spin is harmless — leave it
            ThrottleGate  = 0.55,   -- only feather under real power (this targets power-on snap, not gentle slides)
            SlipRiseGate  = 6.0,    -- rear-slip RISE rate (m/s per second) that starts the feather — the spike that snaps the tail
            SlipRiseFull  = 22.0,   -- rise rate at which the feather is at full strength
            MaxTorqueCut  = 0.16,   -- max fraction of engine torque trimmed at a full spike (0.16 = cut 16%). Gentle — feathers the spike, doesn't kill drive
            EngageTau     = 0.05,   -- fast engage (must catch the spike as it happens)
            ReleaseTau    = 0.14,   -- ease back on quickly once the spike passes (don't linger and bog)
        },

        -- COUNTER-STEER REWARD (2026-08-13 — real RWD build #2). Right now nothing rewards CATCHING a
        -- slide — you apply opposite lock and the car just does whatever native physics says. In a real
        -- RWD, counter-steering points the front tyres INTO the slide and the car hooks back up as the
        -- rotation settles. This is SKILL IN, STABILITY OUT: when the rear is stepping out (rotating
        -- past a threshold) AND you're steering to OPPOSE that rotation (correct counter-lock — same
        -- yaw-vs-steer sign test the drift recovery uses), we gently help the slide settle via the
        -- only-ever-REDUCE lateral damp (can't add slide or flip), scaled by how much correct counter-
        -- steer you're giving. Do NOTHING if you don't catch it — no counter-lock = no help, so a
        -- panic-spin still spins. Both on/off throttle (you counter-steer regardless).
        CounterSteerReward = {
            Enabled       = true,
            MinSpeedKmh   = 22.0,   -- below this, low-speed rotation is fine — leave it
            -- 2026-08-13 FIX: the yaw+counter-lock test alone fired during NORMAL hard cornering too
            -- (yaw is high in any hard corner, and steer/yaw are opposite-signed there as well), which
            -- damped lateral velocity every corner = a false "AWD-grip" buff. Gate on real OVERSTEER via
            -- SLIP ANGLE (heading vs velocity): normal cornering keeps slip small; only a genuine slide
            -- grows it. This is now the PRIMARY gate — the reward can't touch a car that isn't sliding.
            SlipGateDeg   = 12.0,   -- rear must be sliding past this slip angle (deg) before ANY reward — normal cornering is well under this
            SlipFullDeg   = 32.0,   -- slip angle at which the slide counts as "full" for scaling
            YawGate       = 0.45,   -- rear must ALSO be rotating past this yaw rate (rad/s) to count as "stepping out"
            YawFull       = 2.2,    -- yaw rate at which the slide is "full" (reward scales up to here)
            SteerGate     = 0.12,   -- need at least this much correct counter-lock (|steer|) to earn any help
            MaxLatDamp    = 4.2,    -- max lateral-slide damp at full slide + full counter-lock (settles the slide as you catch it)
            EngageTau     = 0.06,   -- engage quick (help the catch the moment you apply lock)
            ReleaseTau    = 0.20,   -- ease off gently as the slide settles / you unwind the lock
            MinLatMs      = 0.5,    -- ignore tiny sideways speeds
        },

        -- LIFT-OFF / THROTTLE ROTATION (2026-08-13 — real RWD build #3). The RWD signature GTA lacks:
        -- lift mid-corner → weight shifts forward, the rear goes light, and the car ROTATES into the
        -- turn (tucks the nose in / trail-brake rotation). GTA's RWD just tracks on rails off-throttle.
        -- We add that rotation with the PROVEN inner-rear brake vectoring (same vl_brakeWheel path as
        -- AWD torque vectoring — capped well below lockup, only ever ADDS to ONE wheel, can't flip),
        -- NOT a yaw-velocity servo (that was the abandoned wheelie-flip approach). Tuned PLAYFUL /
        -- TAIL-HAPPY: a noticeable tuck that can step the rear out if you lift hard mid-corner — and
        -- #2 (counter-steer reward) is right there to let you catch it. Fades out as you get back on
        -- the power (that's #1's / #4's territory) so they never fight. Off-throttle biased, scaled by
        -- how hard you lifted (brake deepens it — trail-braking) and how loaded the corner is.
        LiftRotation = {
            Enabled        = true,
            MinSpeedKmh    = 30.0,   -- below this, native low-speed rotation is fine
            LiftGate       = 0.25,   -- throttle at/below this = "lifted" (full effect at 0; fades to 0 by the gate)
            SteerGate      = 0.14,   -- need at least this steering (|steer|) to count as cornering
            LatGateMs      = 1.2,    -- and at least this lateral speed (m/s) — real cornering load, not straight-line
            LatFullMs      = 6.0,    -- lateral speed at which rotation is at full strength
            BrakeBoost     = 0.5,    -- extra rotation from trail-braking: adds up to this fraction more at full brake (weight-forward = more rotation)
            MaxPressure    = 0.20,   -- cap on inner-rear brake for the tuck (tail-happy — noticeably more than AWD's 0.14 lift tuck). Higher = more rotation
            EngageTau      = 0.11,   -- smooth engage (ease the rotation in as you lift)
            ReleaseTau     = 0.15,   -- smooth release (ease off as you pick the throttle back up)
        },

        -- SPIN SOFTENER (2026-08-13 — real RWD build): GTA's core RWD problem — the rear doesn't step
        -- out too FAR, it steps out too FAST, so rapidly you can't counter-steer/save it before it's
        -- gone. Same tool as the AWD softener (scale the yaw RATE down a capped amount at real slip, so
        -- the spin builds slow enough to catch) but tuned STRONGER for RWD, which genuinely spins harder
        -- and needs the catchable window more. Slows the rotation; NEVER stops it — do nothing and you
        -- still spin, so it stays raw RWD (no auto-save). Slip-angle gated so normal cornering is native.
        -- Unlike AWD's version this does NOT fade with throttle: RWD power-on spin is the main event, so
        -- the softener works on-power too (progressive-oversteer #1 feathers torque; this feathers yaw).
        SpinSoftener = {
            Enabled          = true,
            MinSpeedKmh      = 25.0,   -- below this, low-speed pivots are left alone
            SlipGateDeg      = 16.0,   -- 2026-08-14: 22→16. BrakeRotation+PowerSpin build rotation faster; wake the softener EARLIER (while the slide is still small) so it's catchable, not snap-past-you. Does NOT reduce peak rotation — only the build-RATE
            SlipFullDeg      = 45.0,   -- at/above this slip, max reduction is applied
            MaxYawReduction  = 0.40,   -- 2026-08-14: 0.30→0.40. A touch more yaw-rate authority at full slip so a big mirror-driven step-out is still recoverable. Never zeroes it (rotation stays, just slower to develop)
            EngageTau        = 0.08,   -- 2026-08-14: 0.10→0.08. React a hair faster to the quicker onset
        },

        -- CORNER-EXIT DRIVE-OUT + THROTTLE-STEER (2026-08-13 — real RWD build #4). The RWD "soul": the
        -- THROTTLE is a steering input. GTA models no weight transfer, so on exit a RWD either grips on
        -- rails or spins — there's no satisfying "sit down and drive out," and no rotating the car with
        -- the gas. This makes the throttle a full expression range on corner exit, crossfaded by how
        -- much gas you feed:
        --   * MODERATE throttle → SQUAT & HOOK-UP (Part A): shift traction bias slightly REARWARD so the
        --     rear bites and you drive out planted & satisfying (real weight-shift-rearward grip). A
        --     modest shift — plants the drive-out, doesn't rail the car. Restores to native off-power.
        --   * HIGH throttle → THROTTLE-STEER (Part B): plant fades, a gentle inner-rear brake vectors
        --     the car round — hang the tail with your right foot (same proven vl_brakeWheel path as #3,
        --     capped below lockup, can't flip). Too much and it breaks loose — #1/softener/#2 handle it.
        -- Both gated on real corner context (steering + lateral load + on-power) so straight-line and
        -- steady cornering stay native — no grip buff (the #2 lesson). Inner rear: steer>0=RR, <0=RL.
        DriveOut = {
            Enabled          = true,
            MinSpeedKmh      = 30.0,   -- below this, native low-speed behavior is fine
            SteerGate        = 0.14,   -- need at least this steering (|steer|) to count as cornering
            LatGateMs        = 1.5,    -- and at least this lateral speed (m/s) — real cornering, not straight-line
            LatFullMs        = 6.0,    -- lateral speed at which the effect is at full strength
            -- Part A: squat / hook-up (rear-grip plant).
            PlantThrGate     = 0.30,   -- plant starts once throttle passes this (accelerating out)
            PlantThrPeak     = 0.65,   -- plant is fullest here (the satisfying drive-out band)
            PlantThrFade     = 0.85,   -- plant fades to 0 by this throttle (rotation takes over up high)
            PlantBiasShift   = 0.05,   -- how far to shift fTractionBiasFront toward the REAR at full plant (more rear grip = hooks up). Modest — plants, doesn't rail
            PlantEngageTau   = 0.12,   -- smooth engage
            PlantReleaseTau  = 0.20,   -- smooth release back to native traction bias
            -- Part B: throttle-steer (power-on rotation).
            RotThrGate       = 0.70,   -- throttle-steer starts up high (this is the tail-hang, not the plant)
            RotThrFull       = 1.0,    -- full throttle-steer at WOT
            RotMaxPressure   = 0.16,   -- cap on inner-rear brake for throttle-steer (gentler than #3's 0.20 — on-power it compounds with wheelspin)
            RotEngageTau     = 0.10,   -- smooth engage
            RotReleaseTau    = 0.15,   -- smooth release
        },
        -- WEIGHT-TRANSFER MIRROR #1: BRAKE-ROTATION (2026-08-14, first HK.load consumer, gated OFF).
        -- Hard trail-braking unloads the rear (load.rear drops below 0.5) and a RWD's light tail steps
        -- out — you rotate on the brake. Today only a throttle LIFT rotates (LiftRotation); this is the
        -- braking partner. Inner-rear vector, capped below lockup. Flip Enabled=true to live-test.
        BrakeRotation = {
            Enabled     = true,    -- Phase 3 mirror — LIVE 2026-08-14 (tuning w/ drift)
            MinSpeedKmh = 30.0,    -- below this, native low-speed braking is fine
            BrakeGate   = 0.25,    -- need at least this brake pressure to count as trail-braking
            BrakeFull   = 0.80,    -- brake at which the depth term is full
            SteerGate   = 0.14,    -- and real steering
            LatGateMs   = 1.2,     -- and real lateral load (cornering, not straight-line braking)
            LatFullMs   = 6.0,
            UnloadGate  = 0.05,    -- rear-unload (0.5 - load.rear) must exceed this before it engages
            UnloadFull  = 0.30,    -- rear-unload at which the weight-transfer term is full (~load.rear 0.20)
            MaxPressure = 0.18,    -- inner-rear brake cap (a touch under LiftRotation's 0.20 — brake already loads front)
            EngageTau   = 0.10,
            ReleaseTau  = 0.16,
        },
        -- WEIGHT-TRANSFER MIRROR #2: POWER-SPIN / OPEN-DIFF INSIDE-WHEEL (2026-08-14, LIVE + confirmed).
        -- Rear-axle mirror of FWD_TorqueSteer: hard power mid-corner spins the lightly-loaded inside-rear
        -- first → the car rotates. Detect genuine rear wheelspin (RL/RR vs ground) in a corner and pulse
        -- the inner-rear so the break is progressive, not an all-or-nothing snap. Complements DriveOut
        -- Part B (which vectors on throttle regardless of spin). Shipped 2026-08-14, tuned w/ SpinSoftener.
        PowerSpin = {
            Enabled      = true,   -- Phase 3 mirror — LIVE 2026-08-14 (tuning w/ drift)
            MinThrottle  = 0.60,   -- only under real power
            SpinThreshMs = 2.0,    -- rear wheel must over-speed ground by this (m/s) = genuine spin
            SteerGate    = 0.12,   -- in a corner
            LatGateMs    = 1.0,
            LatFullMs    = 6.0,
            SpeedLowKmh  = 10.0,   -- full effect from here…
            SpeedZeroKmh = 120.0,  -- …fading to nothing by here (high-speed rear spin is its own danger)
            MaxPressure  = 0.10,   -- gentle — it compounds with the actual wheelspin already happening
            EngageTau    = 0.06,
            ReleaseTau   = 0.12,
        },
    },

    ----------------------------------------------------------------
    -- AWD: realistic understeer on power (Phase 1, 2026-08-10)
    -- Real AWD cars (0.49-0.61 bias) push wide when you charge a corner
    -- on power — the front pull straightens the nose (understeer), rear
    -- stays planted. Opposite of RWD power-oversteer.
    ----------------------------------------------------------------
    AWD = {
        Understeer = {
            Enabled = true,

            -- Only apply understeer past this throttle (light cruising = neutral).
            ThrottleGate = 0.35,

            -- OFF-THROTTLE STABILITY FLOOR (2026-08-10 v13): below the gate the help used to drop
            -- to 0 — an on/off cliff that made lift-off feel suddenly slide-y. Keep a fraction of
            -- the help while COASTING so lift-off still rotates MORE than on-power (realistic) but
            -- without the cliff. Braking fades the floor out (trail-braking rotation preserved).
            CoastFloor = 0.40,   -- fraction of full help kept while coasting (0 = old cliff behavior)
            BrakeCut   = 0.6,    -- brake level at which the coast floor is fully removed

            -- Speed band the understeer effect ramps across. Low speed = gentle
            -- (parking maneuvering stays neutral), high speed = full effect
            -- (fast corners show AWD understeer most).
            -- 2026-08-10 v16: user wants the helper scaled DOWN more under 140 (lower speed = less
            -- help). Extended the ramp to 140 (SpeedHighKmh 130→140) and dropped the low floor
            -- 0.25→0.10 so it climbs from much less help at the bottom. HiSpeedLowKmh below is
            -- anchored to the SAME 140 so the base ramp hands off to the high-speed extension cleanly.
            SpeedLowKmh  = 50.0,
            SpeedHighKmh = 140.0,
            -- 2026-08-13 v7.26: user "low-speed AWD help needs more support first." Low-speed floor
            -- 0.10→0.28 so the sub-50 band climbs from meaningfully more help (was near-nothing).
            SpeedLowMult  = 0.28,   -- 28% of full understeer at/below SpeedLowKmh (was 0.10)
            SpeedHighMult = 1.0,    -- 100% at/above SpeedHighKmh

            -- SUB-140 BOOST (2026-08-12): lift the under-140 cornering help +6% overall WITHOUT
            -- touching the >140 top range (HiSpeedMult owns that). A multiplier on the base speed
            -- ramp that peaks at SubBoostMult mid-band and eases back to 1.0 exactly at SpeedHighKmh
            -- (140) so the handoff to the high-speed extension stays seamless (no kink).
            SubBoostEnabled = true,
            SubBoostPeakKmh = 95.0,   -- where the +6% is fullest (middle of the sub-140 band)
            SubBoostMult    = 1.06,   -- +6% at the peak, tapering to 1.0 at 140 and at low-speed fade

            -- LOW-SPEED FADE (2026-08-10 v15): inverse of the high-speed steer limit. Below
            -- LowFadeFullKmh the front-bias help just plowed the nose wide (worst coasting) — fade
            -- the WHOLE effect out to zero by LowFadeZeroKmh so slow corners go native/neutral.
            -- 2026-08-11: full-help point pushed 70→80 so the whole ~80-and-below band gets LOWER
            -- help (same smooth ramp, just stretched — at any speed under 80 the fade is now smaller).
            LowFadeFullKmh = 80.0,  -- at/above this = full help (mid/high-speed behavior unchanged)
            LowFadeZeroKmh = 25.0,  -- at/below this = no help at all (native low-speed steering)

            -- HIGH-SPEED EXTENSION (2026-08-10 v9): above SpeedHighKmh the base scale is flat, so
            -- 250 vs 350 felt the same. Keep firming the front-bias past the base cap so the faster
            -- you go the more the car resists a left-right transition (slower, more stable weave).
            -- Multiplier on the bias shift: 1.0 at HiSpeedLowKmh climbing to HiSpeedMult at Full.
            HiSpeedLowKmh  = 140.0,  -- where high-speed firming starts (anchored = SpeedHighKmh 140)
            HiSpeedFullKmh = 340.0,  -- top-end where it's fully firmed (near hypercar Vmax)
            HiSpeedMult    = 1.68,   -- v7.20: 1.6→1.68 (+5% top-range help). Worst-case 0.60-bias Chiron: 0.60 + 0.1006×1.68 = 0.769, still under MaxBias 0.82.

            -- STEER scale (2026-08-10 v4): ease the understeer in with steering angle so the
            -- onset isn't abrupt near full lock. Little steering = little push, ramping to full
            -- only toward hard lock (squared curve in code = gentle low/mid, grows late).
            SteerLow     = 0.15,    -- below this wheel angle = SteerLowMult (barely any understeer)
            SteerHigh    = 0.85,    -- at/above this = full understeer allowed
            SteerLowMult = 0.15,    -- understeer floor at low steering (before the squaring)

            -- How far to shift fDriveBiasFront toward the front at full demand.
            -- e.g. native 0.50 + 0.13 = 0.63 (more front pull = more understeer).
            -- 2026-08-10 v2: bumped 0.12→0.13 (user wanted max-apex nose push ~5-8% stronger).
            -- 2026-08-10 v11: global AWD turn-helper tone-down 18% (0.13 → 0.107). Scaling BiasShift
            -- reduces the WHOLE assist proportionally (base + high-speed extension all multiply off it).
            -- 2026-08-10 v16: another global 17% off (0.107 → 0.089).
            -- 2026-08-12 v7.19: global AWD cornering-help scale UP 13% (0.089 → 0.1006). BiasShift is the
            -- master knob — base ramp + high-speed extension (HiSpeedMult) all multiply off it, so this
            -- lifts the WHOLE understeer/turn-in help proportionally. Still clears MaxBias 0.82 (worst
            -- case 0.60-bias Chiron: 0.60 + 0.1006×1.6 = 0.761).
            BiasShift = 0.1006,

            -- SPEED-GRADUATED WIDEN (2026-08-13): scale the whole cornering help up more at low speed
            -- than high — low speed +12% (had the least help), high speed +6% (already firm). Multiplies
            -- the master (BiasShift) so base + high-speed extension lift together, proportionally.
            WidenEnabled = true,
            WidenLoKmh   = 40.0,    -- at/below this = full low-speed lift (WidenLoMult)
            WidenHiKmh   = 200.0,   -- at/above this = high-speed lift (WidenHiMult)
            -- 2026-08-13 v7.26: user "AWD help needs MORE — low speed first, and ≥30% stronger/wider for
            -- cornering at the top of the gauge." Low-speed lift +12%→+34% (had the least help, wanted most
            -- first); high-speed lift +9%→+34% (the ≥30% top-gauge widen). MaxBias raised to fit (below).
            WidenLoMult  = 1.34,    -- +34% at low speed (was +12% — low speed gets the biggest bump)
            WidenHiMult  = 1.34,    -- +34% at high speed (the ≥30% top-gauge cornering widen)
            -- 2026-08-10 v9: 0.78→0.82 so the high-speed extension (HiSpeedMult) isn't clipped on
            -- 0.60-bias AWD (Chiron: 0.60 + 0.13×1.6 = 0.808). Still short of full-FWD feel.
            -- 2026-08-13 v7.26: 0.82→0.85 to fit the +34% widen without clipping (worst-case Chiron
            -- 0.60 + 0.1006×1.68×1.34 = 0.826). Still short of full-FWD (1.0) feel.
            MaxBias   = 0.85,       -- never shift past this (avoid full-FWD feel)

            -- Smoothing: engage quick (responsive power-on push), release slower
            -- so lifting off / trail-braking rotates the car back gracefully.
            -- 2026-08-10 v4: EngageTau raised 0.10→0.16 — the onset was too abrupt toward full
            -- lock; a longer tau eases the front-pull in more gradually instead of snapping.
            -- 2026-08-13: +20% engage time (0.16→0.192) — all AWD help eases in slower.
            EngageTau  = 0.192,
            ReleaseTau = 0.20,

            -- ACCEL-AWARE ENGAGE (2026-08-10 v7): monster-power AWD (Chiron) accelerates through
            -- the speed band faster than the assist ramps in, so the help feels like it's chasing
            -- the power. When longitudinal accel is high, pull the engage tau down toward AccelTauMin
            -- so the front-bias shift snaps in fast enough to keep pace. Rising edge only.
            -- 2026-08-10 v10: band recalibrated 15/45 → 5/24. The old 45 km/h/s "full boost" point
            -- was standing-launch acceleration you never see at speed — a Chiron pulling through
            -- 150 km/h does only ~20-25 km/h/s, so the boost barely engaged and the assist lagged
            -- the power (user: "at 140-160 accel is faster than the awd fixing"). These values match
            -- real at-speed cornering acceleration so the engage ramp actually keeps pace.
            AccelBoostEnabled = true,
            AccelKmhSLow  = 5.0,    -- Δkmh/s where the boost starts easing in (gentle accel)
            AccelKmhSHigh = 24.0,   -- Δkmh/s for full boost (hard at-speed pull, e.g. Chiron @150)
            AccelTauMin   = 0.045,  -- engage tau at full accel (fast ~45ms ramp)

            -- LANDING SETTLE (2026-08-10 v8): while airborne + this long after touchdown, hold bias
            -- at native (no engage) so the landing speed-spike can't snap the front-pull on and step
            -- a slightly-yawed landing out. Let the tyres settle before the diff pulls again.
            LandSettleMs  = 260,

            -- REACTION LATENCY (2026-08-10 v5): a real AWD ECU senses the road with a small
            -- variable delay before acting — it doesn't react on the same tick. On a fresh
            -- turn-in/on-power edge, hold off engaging for a randomized delay scaled by urgency
            -- (fast + more steering = QUICKER reaction, shorter delay). Makes the assist feel like
            -- it's reading the road instead of snapping on robotically.
            -- 2026-08-10 v6: reduced 70% (20-80ms → 6-24ms, jitter 12→3.6) — the delay was too
            -- noticeable/laggy; a real diff reacts faster than that. Now a subtle sense, not a wait.
            Reaction = {
                Enabled  = true,
                MinMs    = 6.0,     -- fastest reaction (high speed / hard steering)
                MaxMs    = 24.0,    -- slowest reaction (gentle low-speed input)
                JitterMs = 3.6,     -- ± random spread so it never feels metronomic
                DemandGate = 0.05,  -- understeer demand above this counts as a fresh edge
            },
        },

        -- BUMP-SLIDE SUPPRESSION (2026-08-10): GTA's bad-mapping bumps briefly unload the tyres
        -- and make AWD cars slide when they physically shouldn't. On a detected bump (lost wheel
        -- contact or a vertical-velocity spike) we open a short window and DAMP the sideways
        -- velocity the bump kicked in — the car keeps tracking straight. Only ever reduces lateral
        -- velocity (never adds), so it can't cause a slide/flip. AWD-only.
        BumpSuppress = {
            Enabled = true,
            MinSpeedKmh  = 30.0,   -- below this, bumps are harmless — skip
            -- 2026-08-10 v2: user wants it to START EARLIER (more sensitive) and GO UP MORE
            -- (stronger). Lowered spike threshold 0.9→0.55 so it catches smaller bumps sooner,
            -- raised damp 6.0→9.0 so the sideways skip is killed harder, longer window.
            VertSpikeMs2 = 0.55,   -- |Δ vertical velocity| per frame that counts as a bump hit (lower = earlier)
            WindowMs     = 320,    -- how long to damp lateral after a bump (was 250)
            LatDamp      = 9.0,    -- lateral-velocity damp coefficient (higher = kills slide faster)
            MinLatMs     = 0.4,    -- don't bother damping tiny sideways speeds (was 0.5)
            -- LANDING LAUNCH FIX (2026-08-14): correction now runs ONLY once wheels are back down (never
            -- airborne — that pre-rotated the landing + launched the car forward), and EASES in from the
            -- touchdown frame over this many ms so it can't yank the velocity vector. Raise if landing
            -- still feels grabby; lower toward 0 for a firmer (older-feeling) immediate catch.
            LandEaseMs   = 180.0,
        },

        -- BRAKE STABILITY (2026-08-10 v18, v19 model fix): the understeer helper shifts DRIVE bias,
        -- which is inert under braking — so on the brakes the AWD assist had no tool and the car
        -- stepped out on a short tap + steer. This damps sideways slide while foot-braking (only
        -- reduces, never adds). MODEL: a modern AWD's FOOT brake goes through ABS/ESC — you can't
        -- brake-spin it with the pedal, it just stops planted → FULL correction at any brake level.
        -- The HANDBRAKE locks the rears (bypasses ESC) → this FOOT-brake correction stays off; the
        -- handbrake gets its own pivot+catch model instead (see HandbrakeAssist below).
        BrakeStability = {
            Enabled      = true,
            MinSpeedKmh  = 25.0,   -- below this, braking slides are harmless — skip
            BrakeGate    = 0.12,   -- need at least this foot-brake input for correction to apply
            LatDamp      = 8.20,   -- v7.19: 5.0→8.20 (firmer foot-brake anti-slide; braked AWD corners stay planted harder)
            MinLatMs     = 0.4,    -- ignore tiny sideways speeds
        },

        -- HANDBRAKE PIVOT + CATCH (2026-08-12 v7.19): real-life AWD handbrake behaviour. The handbrake
        -- locks the REAR wheels → the tail breaks loose and the car PIVOTS (the rotation you want). But
        -- the AWD's FRONT axle still grips and pulls the nose back toward its heading, so the slide
        -- SETTLES instead of spinning (a RWD would keep going). We reproduce the SEQUENCE: free-rotate
        -- for FreeRotateMs after the yank (full pivot, no interference), then ease in a front-axle
        -- "catch" that damps the sideways slide so the tail comes back. Same only-ever-reduce-lateral
        -- mechanism as BrakeStability/BumpSuppress (can't add slide or flip). Only runs while the
        -- handbrake is held; releases straight to native.
        HandbrakeAssist = {
            Enabled      = true,
            MinSpeedKmh  = 20.0,   -- below this, a handbrake pull is a parking pivot — leave it native/playful
            -- 2026-08-14: user "on handbrake-held the autofix returns to original state too fast"
            -- (tested Chiron, ultra-high torque). The front-axle catch grabbed the tail back too
            -- quickly after the pivot. Three levers eased: longer free pivot (260→380), slower catch
            -- onset (360→520), gentler damp (3.2→2.4) so the slide holds out + settles progressively.
            FreeRotateMs = 380.0,  -- free pivot window right after the yank before the catch begins (was 260; higher = rotates more before settling)
            CatchEaseMs  = 520.0,  -- catch eases in over this (smoothstep) so the tail isn't snapped back — it loads like real front tyres (was 360)
            CatchDamp    = 2.4,    -- front-axle recovery strength (lateral-slide damp; higher = catches/settles harder, lower = looser/longer slide) (was 3.2)
            MinLatMs     = 1.2,    -- need at least this much sideways speed to catch (a straight-line handbrake stop has ~0 — no catch)
            -- SPEED SCALE: catch harder at speed (a fast handbrake slide would spin), gentler down low
            -- (keep tight low-speed rotations playful). Mult at/below SpeedLowKmh → full (1.0) by SpeedHighKmh.
            SpeedLowKmh  = 30.0,
            SpeedHighKmh = 110.0,
            SpeedLowMult = 0.55,
        },

        -- CORNER-EXIT TRACTION GOVERNOR (2026-08-12 v7.20, feature #1): THE defining AWD trait GTA
        -- lacks — boot the throttle on corner exit and the car HOOKS UP and drives out, instead of the
        -- driven wheels spinning and the tail stepping wide. Real AWD manages this by routing torque to
        -- the axle WITH grip. Two layers: (1) PRIMARY bias TRANSFER — on throttle-induced rear
        -- wheelspin, shift drive bias forward so torque goes to the gripping front axle (a transfer, not
        -- a cut, so it drives out, no bog); layered on top of the understeer bias. (2) BACKSTOP torque
        -- trim — only if slip is STILL excessive (genuinely low grip), a gentle cut via HK.torqueMult.
        -- Fires ON THROTTLE only (corner-exit drive-out, not lift/brake). Uses rear-wheel-vs-ground
        -- overspeed (same detector as the RWD assist). Skips airborne/landing.
        TractionGovernor = {
            Enabled       = true,
            ThrottleGate  = 0.25,   -- need at least this throttle for the governor to act (drive-out only)
            MinSpeedKmh   = 20.0,   -- below this, low-speed spin is playful — leave native
            SpinThreshold = 2.2,    -- m/s the rear wheels overspeed the ground before it counts as spin (lower = earlier/more sensitive)
            SpinFull      = 7.0,    -- m/s of overspeed = full intervention strength
            BiasTransfer  = 0.14,   -- max forward drive-bias shift at full spin (the PRIMARY hook-up; higher = plants harder / more front-drive feel)
            MaxBias       = 0.85,   -- never transfer past this fDriveBiasFront (avoid full-FWD feel on exit)
            BackstopSlip  = 7.0,    -- m/s of overspeed above which the torque-trim backstop kicks in (= SpinFull: transfer alone handles up to here)
            MinTorqueMult = 0.72,   -- hardest backstop cut (72% power floor) — gentle by design; the transfer does the primary work
            EngageTau     = 0.072,  -- 2026-08-13: +20% engage time (0.06→0.072). Still quick (catch spin before the tail steps out), just eased
            ReleaseTau    = 0.22,   -- slower release (don't yank bias/torque back the instant grip returns)

            -- POWER-OUT SAVE (2026-08-12 v7.21, feature #1b): lift-off oversteer recovery. When you're
            -- OFF the gas mid-corner and the rear steps out (weight forward, rear light — real lift-off
            -- oversteer), getting BACK ON the throttle should SAVE it: torque routes hard to the front
            -- axle so the front bites and drags the nose back onto its heading — you power out of the
            -- slide (a real AWD trait; GTA doesn't model it). THROTTLE-ONLY: off-throttle the rear keeps
            -- sliding (lift-off oversteer stays real); the more gas you feed the stronger the pull-straight.
            -- Can't spin the car — a front axle pulling forward-along-heading is inherently stabilizing.
            PowerSave = {
                Enabled       = true,
                SlipGateDeg   = 8.0,    -- rear must be sliding past this slip angle (heading vs velocity) to count as stepping out
                SlipFullDeg   = 26.0,   -- slip angle at which the save is at full strength
                ThrottleGate  = 0.15,   -- need at least this throttle for the save to engage (it's the throttle-only recovery)
                BiasTransfer  = 0.20,   -- max forward bias shift at full slip+throttle (stronger than the on-power hook-up — it's actively rescuing)
                MaxBias       = 0.88,   -- ceiling for the save's forward bias (a hair higher than the exit governor — max front bite to rescue)
                CatchDamp     = 2.6,    -- gentle lateral-slide damp that helps bleed the step-out (only-ever-reduce sideways velocity, scaled by throttle+slip; 0 = bias-only save)
                EngageTau     = 0.250,  -- 2026-08-12: was 0.05 (too rapid), → 0.208 (−76% rate). 2026-08-13: +20% engage time (0.208→0.250) — feathers in even more gently
                ReleaseTau    = 0.28,   -- ease out gently once the car's back in line
                MinSpeedKmh   = 25.0,   -- below this, a step-out is a low-speed pivot — leave it
            },

            -- EXTREME-SLIP SPIN SOFTENER (2026-08-13): GTA's native spin-happiness past the furthest
            -- angle is the risk that keeps AWD from being OP. BUT — real AWD with both axles gripping
            -- resists the SNAP: rotation builds slower, so a real driver gets a catchable window. GTA
            -- under-models this — at the limit an AWD lets go about as instantly as a RWD, so the snap
            -- feels cheap. This softener slows the RATE of the final spin (not the spin itself): you
            -- still lose it if you do nothing, but counter-steer / throttle-save / handbrake now have
            -- time to work. Engages ONLY at extreme slip (past angles you'd never touch in a clean
            -- corner, only when already sideways & losing it), and fades out with throttle (hands off
            -- to PowerSave). Off-throttle-only = skill and risk stay intact, no OP auto-rescue.
            SpinSoftener = {
                Enabled          = true,
                SlipGateDeg      = 32.0,   -- yaw-rate reduction starts when slip (heading vs velocity) exceeds this (never touched in clean cornering)
                SlipFullDeg      = 50.0,   -- at/above this slip, max reduction is applied (full spin-out territory)
                MaxYawReduction  = 0.25,   -- max fraction of yaw rate to remove at full slip (0.25 = cuts spin rate by 25%, never zero)
                ThrottleFadeStart= 0.10,   -- begin fading out the softener once throttle exceeds this (hand off to PowerSave)
                ThrottleFadeEnd  = 0.30,   -- above this throttle, softener is fully disengaged (PowerSave owns the rescue)
                MinSpeedKmh      = 30.0,   -- below this, low-speed pivots are left alone
            },

            -- TORQUE VECTORING (2026-08-13 — feature #2): real AWD brakes the INNER-REAR wheel under
            -- power mid-corner. That wheel dragging creates a yaw moment that ROTATES the car toward
            -- the apex (tightens your line), while the other three wheels — especially the outer rear —
            -- keep pulling, so you DON'T lose forward drive. GTA models none of this; the AWD just
            -- washes wide. Safe mechanism: only-ever-ADD brake force to ONE inner-rear wheel (via
            -- vl_brakeWheel / SetVehicleWheelBrakePressure — same proven path as diff.lua/wheelieguard,
            -- non-latching so released every frame). Never touches throttle or the other 3 wheels, so
            -- it can't kill drive or flip. Force is capped well below lockup — it scrubs, never locks.
            -- Engages only cornering UNDER POWER (throttle + steering + lateral load) with the AWD
            -- planted; fades out at low speed. Runs outside drift only (Drivetrain_Tick is gated off in
            -- drift), so it never fights Diff's drift-mode wheel braking.
            TorqueVector = {
                Enabled       = true,
                MinSpeedKmh   = 40.0,   -- below this, native rotation is fine — leave it
                ThrottleGate  = 0.30,   -- only vector under power (this is corner-EXIT rotation, not a brake tool)
                SteerGate     = 0.12,   -- need at least this much steering input (|steer|) to count as cornering
                LatGateMs     = 1.5,    -- and at least this much lateral speed (m/s) — real cornering load, not straight-line
                LatFullMs     = 7.0,    -- lateral speed at which vectoring is at full strength
                MaxPressure   = 0.22,   -- cap on inner-rear brake pressure (0..1). Well below lockup — scrubs, never locks. Higher = tighter rotation
                EngageTau     = 0.12,   -- 2026-08-13: +20% engage time (0.10→0.12) — ease the brake in slower, no snap
                ReleaseTau    = 0.16,   -- smooth release (ease off as you unwind the corner)
            },

            -- OFF-THROTTLE BALANCE (2026-08-13 — feature #3): the mirror of torque vectoring, for when
            -- you LIFT mid-corner. Real cars are throttle-adjustable: lifting shifts weight forward, the
            -- front bites, the rear lightens, and the car ROTATES more — you tuck the nose in by lifting.
            -- GTA doesn't model it, so an AWD just keeps washing wide off-throttle. But push it too far
            -- and lift-off oversteer gets nervous. So this does BOTH, regime-separated by SLIP ANGLE so
            -- they never fight:
            --   * LOW slip (nose pushing wide, understeering) → TUCK-IN: a gentle inner-rear brake adds
            --     rotation to tighten the line (same safe capped mechanism as TorqueVector, off-throttle).
            --   * RISING slip (rear stepping out) → tuck-in fades and a CALMING damp fades in (only-ever-
            --     reduce lateral velocity, same as BrakeStability — can't add slide/flip) so it stays
            --     composed instead of snapping loose.
            -- Tuck-in holds off while TorqueVector still owns the inner-rear brake (throttle release tail),
            -- so the two never write the same wheel the same frame. Off-throttle only; fades at low speed.
            LiftBalance = {
                Enabled        = true,
                MinSpeedKmh    = 35.0,   -- below this, native low-speed rotation is fine
                LiftGate       = 0.15,   -- throttle at/below this = "lifted" (dead zone up to TorqueVector's 0.30 gate, so they're exclusive)
                SteerGate      = 0.15,   -- need at least this steering (|steer|) to count as cornering
                -- Tuck-in (understeer regime): adds rotation when the nose is washing wide.
                TuckSlipMax    = 5.0,    -- below this slip angle (deg) = understeering → full tuck-in
                TuckSlipZero   = 11.0,   -- by this slip, tuck-in is fully faded (car's rotating enough — don't add more)
                TuckMaxPressure= 0.14,   -- cap on inner-rear brake for tuck-in (gentler than TorqueVector — it's a subtle lift-in, not corner-exit drive)
                TuckEngageTau  = 0.14,   -- smooth engage (ease the tuck in)
                TuckReleaseTau = 0.18,   -- smooth release
                -- Calming damp (oversteer regime): bleeds the sideways step-out so lift-off stays composed.
                DampSlipMin    = 9.0,    -- above this slip angle the calming damp begins (overlaps tuck's tail slightly; both tiny there)
                DampSlipFull   = 24.0,   -- full calming damp at/above this slip
                DampLat        = 3.0,    -- lateral-slide damp strength at full (only ever REDUCES sideways velocity)
                MinLatMs       = 0.4,    -- ignore tiny sideways speeds
            },
        },

        -- HIGH-SPEED STEER LIMIT (2026-08-10 v12): GTA's native speed-sensitive steering is too
        -- gentle for hypercar speeds — with the AWD helper planting the rear, the leftover
        -- high-speed darting stands out. Above StartKmh, steepen it: scale the steering multiplier
        -- from 1.0 down toward MinScale as speed climbs to FullKmh, so the same input produces less
        -- side-to-side sway the faster you go (real high-speed stability). AWD-only for now; runtime
        -- native SetVehicleSteeringScale, restored on exit — NEVER touches handling.meta.
        -- 2026-08-10 v17: REWORKED mechanism. The old version scaled steering ANGLE down, which
        -- built a wall you couldn't steer past at speed ("can't turn at 220"). Now it's a RATE
        -- limiter: full lock is ALWAYS reachable at any speed, but the wheel SWINGS more slowly the
        -- faster you go — so you can't dart across 3 lanes in a second, but holding A/D still brings
        -- the car all the way around. Limits how fast the wheel ANGLE changes (deg/s), not the max.
        SteerLimit = {
            Enabled    = true,
            StartKmh   = 150.0,   -- below this = full native steering rate (no limit)
            FullKmh    = 320.0,   -- at/above this = slowest swing rate (MinRateFrac)
            MaxRateDeg = 220.0,   -- deg/sec the wheel may swing at/below StartKmh (full, snappy)
            MinRateFrac = 0.35,   -- at FullKmh, swing rate is 35% of MaxRateDeg (slow, deliberate)
            -- 2026-08-11: gentle MAX-ANGLE taper layered on the rate limit — trims top-end sideways
            -- angle so the car sways tighter at speed. Proportional+smooth (NOT the v17 hard wall):
            -- full lock scales from 100% at StartKmh down to MinAngleFrac at FullKmh, always turnable.
            MinAngleFrac = 0.85,  -- at FullKmh, full lock reaches 85% of demand (15% tighter at top)
        },
    },

    ----------------------------------------------------------------
    -- FWD BRANCH — real front-wheel-drive hot-hatch character (implemented).
    ----------------------------------------------------------------
    -- ── FWD BRANCH (2026-08-14) — real front-wheel-drive character ──────────────
    -- FWD cars (fDriveBiasFront > 0.61) ran pure native before this. Target feel = balanced-realistic
    -- base + torque steer under hard power-out + slightly-elevated lift-off rotation. The full tool set:
    -- power understeer, corner-exit drive-out, lift-off rotation (+ speed-scale + snap spin softener),
    -- torque steer, sport-diff (LSD) hook-up, front-spin torque penalty, braking understeer — all
    -- mirroring the AWD/RWD mechanisms (fDriveBiasFront/fTractionBiasFront shifts + inner-wheel brake
    -- vectoring + yaw-rate scale), grounded-gated + exp-tau smoothed. NEVER touches handling.meta.
    FWD = {
        Enabled = true,

        -- (1) POWER UNDERSTEER — the defining FWD trait. On throttle + steered + speed, push
        -- fDriveBiasFront further FORWARD so the nose plows wide (fronts steer AND drive = they wash out
        -- under power). Mirror of AWD_Understeer but pushed harder (a FWD SHOULD understeer on power).
        PowerUndersteer = {
            Enabled      = true,
            MaxAddFront  = 0.12,   -- max fDriveBiasFront added on top of native at full demand (0.12 = strong plow)
            ThrottleGate = 0.30,   -- throttle at/below which the on-power component is 0
            CoastFloor   = 0.20,   -- fraction of the effect kept off-throttle (small — FWD plows mostly ON power)
            BrakeCut     = 0.50,   -- brake level that fully removes the coast floor (so trail-braking rotates, doesn't plow)
            SpeedLowKmh  = 45.0,   -- understeer ramps in from here...
            SpeedHighKmh = 120.0,  -- ...to full by here (fast corners show it most)
            SpeedLowMult = 0.25,
            SpeedHighMult= 1.0,
            SteerLow     = 0.15,   -- steer where the effect starts (squared curve = gentle low/mid)
            SteerHigh    = 0.85,   -- steer where it reaches full
            SteerLowMult = 0.15,
            LowFadeZeroKmh = 22.0, -- below this the whole effect fades to 0 (slow corners stay neutral)
            LowFadeFullKmh = 65.0, -- full effect at/above this
            EngageTau    = 0.10,   -- ramp-in time constant (s)
            ReleaseTau   = 0.16,   -- ramp-out time constant (s)
            LandSettleMs = 260,    -- after a landing, hold bias native for this long (tyres settle before diff pulls)
        },

        -- (2) LIFT-OFF ROTATION — hot-hatch tail rotation on lift/trail-brake. Inner-rear brake vectoring
        -- (vl_brakeWheel, non-latching, only ADDS to one wheel — can't flip). "Touch of 2": a notch above
        -- balanced, below the RWD playful level. Brake deepens it (trail-brake rotation, tool #3 folded in).
        LiftRotation = {
            Enabled     = true,
            MaxPressure = 0.17,    -- peak inner-rear brake pressure at full demand (RWD uses 0.20; FWD a touch less)
            LiftGate    = 0.25,    -- throttle at/below this counts as a lift
            SteerGate   = 0.14,    -- need at least this much steering
            LatGateMs   = 1.2,     -- and this much lateral speed (genuinely loaded corner)
            LatFullMs   = 6.0,     -- lateral speed for full corner-load factor
            BrakeBoost  = 0.6,     -- braking while lifted deepens rotation by up to this × (trail-brake) — >RWD's 0.5
            MinSpeedKmh = 28.0,
            EngageTau   = 0.10,
            ReleaseTau  = 0.15,
        },

        -- (4) CORNER-EXIT DRIVE-OUT — on power out of a corner, shift fTractionBiasFront FORWARD so the
        -- fronts claw grip and pull the car straight out (planted, opposite of RWD's rearward squat).
        DriveOut = {
            Enabled      = true,
            MaxAddFront  = 0.10,   -- max fTractionBiasFront added forward at full power-exit
            ThrottleGate = 0.35,   -- power must exceed this to plant the fronts
            SteerRelease = 0.55,   -- effect grows as the wheel UNWINDS below this (exit, not apex)
            MinSpeedKmh  = 30.0,
            EngageTau    = 0.09,
            ReleaseTau   = 0.18,
        },

        -- (5) TORQUE STEER — the authentic tug. On hard power with FRONT wheelspin at low-ish speed, add a
        -- brief yaw pull toward the spinning side via an inner-front brake pulse. Small + fades with speed
        -- + hard-power-only so cruising is clean. This is the "annoying but real" bit the user asked for.
        TorqueSteer = {
            Enabled      = true,
            MinThrottle  = 0.70,   -- only under HARD power
            SpinThreshMs = 2.0,    -- front wheel must spin this much faster than ground (m/s) to count
            MaxPressure  = 0.10,   -- peak front-wheel brake pulse (small — a tug, not a grab)
            SpeedLowKmh  = 8.0,    -- full effect from here...
            SpeedZeroKmh = 90.0,   -- ...fading to 0 by here (torque steer is a low/mid-speed launch thing)
            EngageTau    = 0.05,   -- fast on (it's a reactive tug)
            ReleaseTau   = 0.12,
        },

        -- ── JDM PACK (2026-08-14) — the missing half of FWD character ──────────────

        -- (6) LSD / SPORT-DIFF HOOK-UP — the defining hot-hatch trait (Type R / Megane RS / Focus RS).
        -- A real e-diff/LSD sends power to the LOADED OUTSIDE front, which is ahead of the CG → a yaw
        -- moment that pulls the nose INTO the corner on power (tightens the line, drives out planted) —
        -- the counterweight to the open-diff plow. GTA can't model a diff, so we do what real e-diffs do:
        -- brake the INSIDE-FRONT so torque shoves to the outside. Only for cars flagged as sport-diff
        -- (SportDiff.Models list OR /sportdiff override) — economy FWD keeps plowing (PowerUndersteer).
        SportDiff = {
            Enabled     = true,
            -- WHO gets the LSD hook is decided by the TUNED fDriveBiasFront (same philosophy as the
            -- drivetrain classifier — the handling value we set per car IS the answer, never a name list).
            -- FWD band is 0.61..1.0; we split it: economy open-diff plow below SportDiffBias, sporty LSD
            -- hook at/above. Tune a hot-hatch's fDriveBiasFront >= this to give it the Type-R hook; leave
            -- an economy FWD lower and it keeps plowing (PowerUndersteer). /sportdiff on|off|auto overrides.
            SportDiffBias = 0.72,    -- fDriveBiasFront at/above this (within the FWD band) = LSD sport-diff car
            MaxPressure = 0.14,      -- peak inside-front brake to fake torque-vector-to-outside
            ThrottleGate= 0.35,      -- power must exceed this to engage the diff hook
            SteerGate   = 0.12,      -- and be turning
            LatGateMs   = 1.5,       -- and genuinely loaded (lateral speed)
            LatFullMs   = 6.0,
            MinSpeedKmh = 22.0,
            SpeedLowKmh = 30.0,      -- hook ramps up with speed a touch (fast corners show it most)
            SpeedHighKmh= 110.0,
            SpeedLowMult= 0.55,
            SpeedHighMult=1.0,
            EngageTau   = 0.08,
            ReleaseTau  = 0.16,
            -- When a sport-diff car is hooking up, DAMPEN the power-understeer plow so the two don't
            -- cancel to mush — the diff should WIN on these cars (that's the point). 0..1 of the plow kept.
            UndersteerDampen = 0.45,
        },

        -- (7) FRONT WHEELSPIN DRIVE PENALTY — real FWD frying its fronts goes NOWHERE (wasted torque).
        -- GTA barely models this. Cut engine torque while the fronts spin faster than ground. Ties into
        -- the same front-spin signal as TorqueSteer. Re-applies torque at end of the FWD tick (the
        -- drivetrain tick runs AFTER main.lua's vl_setTorque, so we can't use HK.torqueMult here).
        SpinPenalty = {
            Enabled      = true,
            SpinThreshMs = 2.5,    -- front over-speed vs ground (m/s) to start cutting
            SpinFullMs   = 7.0,    -- full cut by here
            MinThrottle  = 0.55,   -- only when actually asking for power
            MaxCut       = 0.35,   -- max fraction of torque removed at full spin (0.35 = down to 65%)
            SpeedZeroKmh = 70.0,   -- fade the penalty out by here (high-speed spin is rare / less bog-y)
            EngageTau    = 0.06,
            ReleaseTau   = 0.14,
        },

        -- (8) SPEED-SCALED LIFT-OFF — make LiftRotation speed-dependent: gentle tuck at low speed, a
        -- genuine tail-swing up high (the scary hot-hatch lift-off snap). Multiplies LiftRotation's
        -- pressure. Set both mults to 1.0 to disable (LiftRotation then behaves speed-flat as before).
        LiftSpeedScale = {
            Enabled     = true,
            LowKmh      = 45.0,    -- at/below → LowMult (gentle)
            HighKmh     = 120.0,   -- at/above → HighMult (full snap)
            LowMult     = 0.55,
            HighMult    = 1.35,    -- >1 = MORE rotation than base up high (the snap)
        },

        -- (8b) LIFT-SNAP SPIN SOFTENER — the safety net BEHIND LiftSpeedScale. That 1.35x amplification
        -- gives a fast FWD hatch a genuine mid-corner lift-off snap; without a yaw-rate softener behind
        -- it (RWD/AWD both have one, FWD didn't) a high-speed snap could build faster than a human can
        -- catch → uncatchable spin. Same proven path as RWD_SpinSoftener: once the rear has genuinely
        -- stepped out (real slip angle), scale the yaw RATE down (never zero) so the slide develops slow
        -- enough to counter-steer. Reads yaw only — no throttle, no wheel — can't flip. Gated a notch
        -- higher/faster than RWD: FWD shouldn't be sliding in normal driving, so we only step in on a
        -- true snap (SlipGateDeg 26 vs RWD's 22) and only above real speed (MinSpeedKmh 55).
        SpinSoftener = {
            Enabled          = true,
            MinSpeedKmh      = 55.0,   -- only high-speed lift-snaps (low-speed FWD rotation is harmless + fun)
            SlipGateDeg      = 26.0,   -- softening starts past this slip angle (higher than RWD — FWD shouldn't slide normally)
            SlipFullDeg      = 48.0,   -- at/above this slip, max reduction is applied
            MaxYawReduction  = 0.32,   -- cut snap rate up to 32% at full slip. Never zeroes it (keep it catchable, not killed)
            EngageTau        = 0.09,   -- smooth engage (ease the yaw scale in, no snap)
        },

        -- (9) BRAKING UNDERSTEER / FRONT-LOCK — fronts do ~70% of FWD braking and can lock, washing out
        -- steering on hard entry. Fake it: on hard braking + steering, briefly reduce the STEER input's
        -- authority (scale fSteeringLock down) so the nose pushes wide on the brakes until you ease off.
        -- Small + high-brake-only so normal trail-braking (which should ROTATE via LiftRotation) is clean.
        BrakeUndersteer = {
            Enabled     = true,
            BrakeGate   = 0.75,    -- only above this brake level (HARD braking → front lock territory)
            SteerGate   = 0.15,
            MinSpeedKmh = 40.0,    -- needs speed to matter
            MaxLockCut  = 0.22,    -- max fraction of steering lock removed at full lock-up (nose plows)
            EngageTau   = 0.07,
            ReleaseTau  = 0.13,
        },

        -- (10) BRAKING-STRAIGHTEN (2026-08-14) — the weight-transfer spine mirror of RWD_BrakeRotation,
        -- OPPOSITE sign. RWD reads load.rear (braking unloads rear → tail out). FWD reads load.front:
        -- braking LOADS the driven+steering front axle → the car tracks STRAIGHT (real FWD engine-braking
        -- is stabilising, like a cart towed from the front). STRAIGHT-LINE ONLY — cornering is owned by
        -- LiftRotation/BrakeUndersteer, so the steer gate here is a CEILING (fades out as you turn in).
        -- Damps the yaw RATE (never zero) via the shared flip-proof applyYawScale — no wheel, no throttle.
        BrakeStraighten = {
            Enabled        = true,
            MinSpeedKmh    = 35.0,   -- below this, low-speed manoeuvring is left alone
            BrakeGate      = 0.15,   -- braking above this counts (also fires on a full lift, see LiftGate)
            BrakeFull      = 0.85,   -- brake at which the depth term is full (harder stop = more composure)
            LiftGate       = 0.10,   -- throttle at/below this also arms it (engine-braking straighten off the gas)
            LiftFloor      = 0.30,   -- a pure lift (no brake) counts as this much "brake depth" for the term
            SteerCeil      = 0.30,   -- CEILING: real steering hands off to the rotation tools; fades out by here
            LoadGate       = 0.05,   -- front-load above static 0.5 must exceed this before it engages
            LoadFull       = 0.30,   -- front-load at which the weight-transfer term is full (~load.front 0.80)
            MaxYawReduction= 0.22,   -- max yaw-rate damp at full engagement (gentle — this is composure, not a lock)
            EngageTau      = 0.09,
            ReleaseTau     = 0.15,
        },
    },

    ----------------------------------------------------------------
    -- REAR-WHEEL STEER (4WS) SPEED GATE (2026-08-11)
    -- For cars carrying HF_STEER_ALL_WHEELS (strHandlingFlags bit 0x80) — e.g. the
    -- AMG ONE. GTA's flag steers the rears IN-PHASE at the full front lock at EVERY
    -- speed, which is only right at HIGH speed (flat, stable lane-changes). At LOW
    -- speed real 4WS counter-steers the rears for agility; GTA's in-phase version
    -- instead makes the car translate sideways and turn wide. GTA can't do a partial
    -- or counter-phase rear angle (the flag is on/off, tied to fSteeringLock), so we
    -- do the next best thing: CLEAR the bit below LowKmh (rears straight → the car
    -- rotates normally) and SET it above HighKmh (rears in-phase → stability). The
    -- band between the two is hysteresis so it doesn't chatter at the crossover.
    -- Runs for ANY flagged car regardless of drivetrain. Restored on exit. This
    -- toggles a runtime handling INT (SetVehicleHandlingInt) — NEVER handling.meta.
    -- DISABLED 2026-08-11: live test confirmed GTA CACHES strHandlingFlags at vehicle spawn and
    -- does NOT re-read it mid-drive — the rears still steered at 0 km/h despite the bit being
    -- cleared. So this speed-gate can't take effect (float handling fields apply live; steering/
    -- model FLAGS are baked at init). No native sets rear-steer angle/phase independently either,
    -- so there's no live workaround. Left dormant in case an apply-at-spawn approach is ever tried.
    RearSteer = {
        Enabled = false,
        LowKmh  = 45.0,   -- at/below this the rear-steer bit is CLEARED (car rotates normally)
        HighKmh = 70.0,   -- at/above this the bit is SET (rears steer in-phase for stability)
    },
}

-----------------------------------------------------------------
-- BRAKE-FORCE BUFF (2026-08-14) — uses the previously-unused fBrakeForce x1.00 headroom to REWARD a
-- built-up car with stronger brakes. Two independent additive layers, both stacked onto fBrakeForce:
--   (A) ALL-TIME buff (constant while the qualifying gear is fitted) — parts you've installed:
--         lambra tuner chip (player_vehicles.lambrachip) ..... +Chip
--         antilag fitted (jim-mechanic, hk_antilag statebag) .. +Antilag
--         gearbox is DCT (public types 3/4/5) ................. +DctBonus   (either DCT variant)
--         gearbox is manual/sequential (public 1/6) .......... +ManualBonus
--         native brake mod GetVehicleMod(veh,12) L1/L2/L3 .... BrakeMod[1/2/3]
--   (B) SPEED curve — extra bite that only comes in at high speed (heavier car needs more stopping
--         force up top). Piecewise-smooth interpolation between the breakpoints below, 0 under Start.
-- Both are ADDITIVE deltas on the x1.00 base (e.g. +0.08 -> x1.08). Composed into HK.brakeForceMult
-- alongside the keyboard brake model + ABS. This is a REALISM/reward layer, not a handling.meta edit.
-----------------------------------------------------------------
Config.BrakeBoost = {
    Enabled     = true,
    -- (A) all-time part buffs (added while fitted; each is a delta on the x1.00 base)
    Chip        = 0.08,   -- lambra tuner chip installed on this vehicle (DB row)
    Antilag     = 0.04,   -- jim-mechanic antilag fitted
    DctBonus    = 0.20,   -- gearbox is either DCT variant (public 3/4/5)
    ManualBonus = 0.10,   -- gearbox is manual or sequential (public 1/6)
    -- native in-game brake upgrade level (GetVehicleMod(veh,12) -> 0/1/2 == L1/L2/L3). index by level+1.
    BrakeMod    = { [1] = 0.12, [2] = 0.18, [3] = 0.25 },
    -- (B) high-speed curve: {kmh, deltaAdd}. Below the first knot = 0; between knots = smooth (smoothstep)
    -- interpolation; above the last knot = held at the last delta. Deltas are cumulative targets, not steps.
    SpeedCurve  = {
        { 185.0, 0.00 },   -- curve starts engaging at 185 km/h
        { 255.0, 0.09 },
        { 340.0, 0.18 },
        { 460.0, 0.22 },
        { 500.0, 0.30 },
    },
    MaxTotal    = 1.20,   -- safety clamp on the SUM of all buff deltas (fBrakeForce mult never exceeds 1+this)
}

-----------------------------------------------------------------
-- LOW-SPEED BRAKE SOFTENER (2026-08-16). GTA's fBrakeForce is a CONSTANT decel regardless of speed, so the
-- force that stops the car from 100 also SLAMS it to a halt at crawl (drops below the RollCreep pin band in
-- a blink = the "instant stop / first 35 km/h gone" report). Real brakes ease off near a stop. Gradually
-- WEAKEN brake force below Kmh: full strength at/above Kmh, fading linearly to Min as speed → 0.
-- Composed onto HK.brakeForceMult (main.lua, reduction-only, stacks with ABS/model/buff). Handbrake untouched.
-----------------------------------------------------------------
Config.LowSpeedBrake = {
    Enabled = true,
    Kmh     = 35.0,   -- at/above this = full brake strength; below = softened
    Min     = 0.60,   -- brake force at a dead stop = 60% (40% weaker); ramps up to 1.0 by Kmh
}

-----------------------------------------------------------------
-- [F1] CONTROLLED WHEELIE SYSTEM (replaces CF_CAN_WHEELIE)
-- Hold the wheelie key under hard acceleration to lift the front via
-- ApplyForceToEntity. Self-limits pitch angle so the car doesn't loop.
-----------------------------------------------------------------
Config.Wheelie = {
    -- 2026-08-14 v3: PURE PITCH TORQUE (forceType 4), NOT a force couple. The v2 couple still
    -- launched the car (two big +Z/-Z forces only cancel in theory; the body pivoted off the
    -- planted rear tyres and flew). A torque about the CoM has ZERO net linear force — the car
    -- CANNOT translate, only the nose rotates up. LAUNCH-DRIVEN, no key. MUSCLE only. AUTO
    -- muscle lifts while launch mode is live (HK.launching); MANUAL muscle on a genuine N/R->1
    -- launch shift (spawn-in-gear-1 can't trip it). Lift HEIGHT scales with measured accel.
    -- Watch /handlingdbg WHEELIE line (f/pitch/mag/trig/man/accel/aScale).
    Enabled = true,

    -- CAR-TYPE GATE (2026-08-14): MUSCLE class only. Manual vs auto changes only the TRIGGER
    -- (N->1 edge vs launch-mode window), handled in code — both get the wheelie on launch.
    OnlyMuscle   = true,        -- require GetVehicleClass == 4 (Muscle)

    -- Manual muscle: how long the wheelie window stays open after the N->1 launch shift (ms).
    LaunchWindowMs = 1500,

    -- ============================================================================================
    -- PATH B — DELIBERATE IN-GEAR WHEELIE (2026-08-14 v3, S-RELEASE TRANSIENT). Independent of launch
    -- mode. While ALREADY driving in drift mode, going STRAIGHT, on the gas, in gears SeqMinGear..
    -- SeqMaxGear within the Seq speed band: HOLD S to LOAD the driveline (rev/torque against the brake),
    -- then RELEASE S -> the snap-release lofts the nose. This is the CLUTCH-UP / snap wheelie, NOT the
    -- wheelspin wheelie — the log proved native wheelspin only breaks the tyres loose in gears 1-2, but
    -- the snap transient exists in EVERY gear. It just lofts LESS the taller the gear (SeqGearFalloff),
    -- matching real physics: gear 1 = full send, gear 3-4 = a gentle ramp-up loft. Wrong timing can
    -- loop/crash the car (intended — a skill gesture, no nanny clamp). If this proves fiddly we fall
    -- back to the wheelspin-detect trigger restricted to gears 1-2.
    -- ============================================================================================
    SeqMinGear      = 1,        -- Path B lowest gear
    SeqMaxGear      = 3,        -- Path B highest gear (gear 1-3 only; gear 4+ is unrealistic for a snap wheelie)
    SeqMinKmh       = 8.0,      -- must already be rolling
    SeqMaxKmh       = 160.0,    -- Path B speed ceiling (higher than the launch cap so tall gears qualify)
    SeqSteerMaxAbs  = 0.35,     -- |state.steer| at/above this = "turning" -> no in-gear wheelie (no drift overlap)
    SeqBrakeMin     = 0.5,      -- footbrake (S) threshold that counts as "held" for the load/release edge
    SeqLoadMinMs    = 180.0,    -- (legacy, unused since the spin-release rebase) old brake-load min hold
    -- 2026-08-14 REBASE: Path B now fires off drift.lua's REAL W+S wheelspin release
    -- (HK.driftSpinReleaseAt), not a brake-load timer. This is the grace window after that
    -- stamp in which the release edge still counts as "fresh" (fire once per spin).
    SeqReleaseGraceMs = 120,    -- fire Path B if the spin released within this many ms
    SeqWindowMs     = 1200,     -- how long the Path-B lift window stays open after the release fire
    SeqGearFalloff  = 0.7,      -- lift multiplier PER GEAR above 1st (gear1=1.0, gear2=0.7, gear3=0.49)
    SeqGearScaleFloor = 0.35,   -- never scale the lift below this (so gear 3 still lofts noticeably)

    -- Conditions to allow a wheelie
    MinThrottle    = 0.85,      -- must be on the gas
    MinSpeedKmh    = 0.0,       -- launches start from a standstill, so allow 0
    MaxSpeedKmh    = 120.0,     -- no wheelies at top speed
    RequireGrounded = true,     -- only when wheels are down

    -- ENGAGE DELAY (2026-08-14): don't lift at a DEAD standstill — the rears need a moment to light up
    -- or an instant lift flips the car before it moves. But 12 was too late (nose came up AFTER the grip
    -- had already hooked). Drop to 4 so the lift fires as the rears break loose and the car just starts
    -- to move — the front comes up DURING the spin, not after it hooks. Raise if it flips at a standstill.
    -- 2026-08-14 v3: 4 was TOO early ("wheelie came in a bit too early lol") — the nose popped before
    -- the launch had really settled. 12 was too late (fired after the grip hooked). 6 splits it: the
    -- rears are lit and it's just rolling, so the lift rides the spin without jumping the gun.
    EngageAboveKmh = 6.0,       -- no nose lift until we're at least this fast into the launch

    -- PEAK CAP: scales LiftTorqueNm down so a max bounce still has headroom (the accel/torque
    -- scalers ride on top). Lower = tamer peak.
    LaunchForceCapPct = 0.56,

    -- MASTER FORCE SCALE (2026-08-26 v2). HISTORY: 0.35 was set after "good! nose lift now" at
    -- FULL force, on the theory the full torque over-rotated. But the transcript is unambiguous —
    -- FULL force + +mag = "nose lift" (correct); the SAME sign at 0.35 = "back to rear lifting".
    -- A pitch TORQUE can't lift the rear (it rotates about the CoM: nose-up == tail-down). So the
    -- rear-lift is a ~constant NATIVE nose-down/squat these muscle ADDON cars do on a hard launch;
    -- FULL torque overpowers it (nose up), 0.35 loses to it (rear shows through). The cut WAS the
    -- regression. Restore FULL authority for stock (1.0) so it always wins the pitch; the onset
    -- curve below still eases it IN (the "come as a curve, not a slam" ask) WITHOUT cutting the
    -- peak. Mod scales ABOVE this. If the TOP ever feels too strong, trim from here — but only
    -- from a confirmed nose-up state, never back down toward the rear-lift zone.
    -- 2026-08-26 v3: user "the force is still too strong anyway just 15% of current force". Current
    -- was 1.0, so 0.15. The SIDEWAYS/ROLL was a GEOMETRY bug (local-X torque axis leaking into roll
    -- under launch body-roll), now fixed by the ground-horizontal axis in wheelie.lua — so this is a
    -- pure strength knob again, safe to drop. Onset curve + accel-scale + the new trailing fade
    -- (FadeOutMs) shape it smoothly in and out.
    PitchForceScale = 0.15,

    -- 2026-08-14 v4: PITCH RATE (rad/s) — the peak nose-up ANGULAR RATE a full-authority bounce reaches.
    -- REPLACES the N·m torque path (LiftTorqueNm/PitchForceScale), which was applied via the disputed
    -- forceType 4 and turned out to be a sideways PUSH, not a rotation (the left/right bog). addPitchRate
    -- now drives the local pitch axis via SetEntityAngularVelocity (the proven applyYawScale primitive) so
    -- it can ONLY rotate the nose up, never translate. ~1.2–1.6 rad/s = a strong drag nose-lift; lower for
    -- a gentler pop. All the existing 0..1 shapers (fade/onset/accel/mod) still ride on top. LiftTorqueNm
    -- and PitchForceScale above are now DEAD for the rate path (kept only so the old dbg refs don't nil).
    PitchRateMax = 1.4,

    -- 2026-08-14 user: "make applied force x2.5". Master multiplier on the nose-up rate — trim here if
    -- the nose comes up too hard/soft (this is the clean single strength knob now the rate path works).
    -- v2 (2026-08-14 user: "force is too sudden and not a smooth curvage coming" + "ends fast, longer
    -- lasting"): 2.5 slammed the nose to the apex in ~200ms then quit. Drop to 1.9 so it CLIMBS more
    -- gradually — a lower rate takes longer to reach the (now higher) apex, so the lift both eases in
    -- smoother AND lasts longer. Pair with the raised TargetPitch below (more travel) + longer OnsetMs.
    PitchRateGain = 1.9,

    -- PER-LAUNCH RANDOM (2026-08-14 user: "random for a lower or stronger 12% gauge near there"). Each
    -- launch rolls a force multiplier of 1 ± this fraction ONCE at arm, so no two lifts are identical.
    PitchRateRandomPct = 0.12,

    -- ROLL LEVELLING (2026-08-14 user: "not center enough, sends the right front wheel up first then the
    -- left / vice versa"). The ×2.5 force amplified the car's natural launch body-roll into a visible
    -- one-wheel-up-first. This bleeds the roll rate while lifting so both front wheels come up together.
    -- Roll is scaled to this fraction at FULL lift, easing back to 1.0 (untouched) between bounces so the
    -- fun countersteer-to-straighten feel still returns. LOWER = more centred/level; 1.0 = no levelling
    -- (pure character, the old feel). 0.35 = mostly level at the punch but not robotically flat.
    RollLevelMin = 0.35,

    -- YAW LEVELLING (2026-08-14): after we boosted launch speed/torque, rear wheelspin started to walk
    -- the car left/right during the lift ("going left and right a bit too much"). Same treatment as roll:
    -- bleed the yaw rate while lifting, scaled by how hard we're lifting, so the launch tracks straighter.
    -- Only ever SHRINKS |yaw| (never adds), and eases back to 1.0 between bounces, so the driver's own
    -- steer-in and the countersteer feel still read through. LOWER = straighter launch; 1.0 = disabled
    -- (all yaw authority kept). 0.6 = a gentle straightener, milder than roll so it doesn't feel on-rails.
    YawLevelMin = 0.6,

    -- FORCE-ONSET CURVE (2026-08-26): ease the lift torque IN instead of slamming it. OnsetMs = how
    -- long (ms) to reach full torque; OnsetGamma shapes the curve (>1 = slow start then build, the
    -- gentle drag-launch swell). A smooth onset also keeps the rear planted so the NOSE rises (a
    -- torque spike over-rotated the body and sometimes lifted the tail instead).
    -- v2 (2026-08-14 user: "force is too sudden, not a smooth curvage"): stretch the onset 220->380ms
    -- so the torque swells IN over a longer curve — the nose rises like a drag car loading up, not a
    -- jolt. Gamma stays >1 so it starts soft and builds.
    OnsetMs    = 380.0,
    OnsetGamma = 1.6,

    -- SMOOTH FADE-OUT (2026-08-26): the torque eases to ZERO between FadeStartPitchFrac*TargetPitch
    -- and TargetPitch (on a smoothstep), so it's already ~0 at the apex — no hard cut when the bounce
    -- flips rising->falling. LOWER = starts fading sooner = gentler/earlier top-out; higher = holds
    -- lift longer then fades late. Pairs with OnsetMs (fade-IN) for a curved swell at both ends.
    -- 2026-08-14 v2: with TargetPitch raised to 26, a 0.35 frac started fading at ~9° — too early, the
    -- nose ran out of push before the fronts lifted. 0.55 holds full force through the low/mid climb
    -- (fade starts ~14°) so the wheels actually leave the ground, THEN eases to 0 by the 26° apex.
    FadeStartPitchFrac = 0.55,

    -- MOD-SCALED LIFT (2026-08-26): how hard the nose lifts by how modded the car is (engine +
    -- transmission + turbo, sampled at launch). Stock -> ModLiftMin, full-mod -> ModLiftMax. Stock
    -- still lifts a bit; a built car lifts hard — the old-school drag look the user wants.
    -- 2026-08-26 v3: with PitchForceScale back to 1.0 (see its note — the 0.35 cut was the rear-lift
    -- regression, not a fix), stock MUST sit at the confirmed-good FULL force so it always wins the
    -- native nose-down. So ModLiftMin = 1.0 (stock == the "good! nose lift now" force), ModLiftMax
    -- adds extra drag pull for a built car. This is now the ONLY mod-lift lever; keep stock at 1.0
    -- unless a stock car is confirmed to over-rotate (then trim PitchForceScale, not this floor).
    ModLiftMin = 1.0,    -- stock: the full confirmed nose-up force (must beat the native squat)
    ModLiftMax = 1.35,   -- full-mod: stronger nose lift + harder drag than stock

    -- MOD-SCALED DRAG PULL (2026-08-26): the forward "yank away" surge while the nose is up, scaled
    -- by the same mod level. Stock -> ModBoostMin (gentle), full-mod -> ModBoostMax (insane drag pull).
    -- Multiplies BoostAccelMs2. Crank ModBoostMax if built cars should launch even harder.
    ModBoostMin = 0.5,
    ModBoostMax = 2.0,

    -- BOUNCE MACHINE (2026-08-14 REBUILD): the wheelie is now 1 or 2 DISCRETE bounces (nose punches
    -- up, gravity pulls it back), NOT a sustained hold. A car that runs FAST and PULLS HARD earns a
    -- 2nd, weaker spring-back bounce (suspension rebound); everything else gets exactly one. Max 2.
    -- RESTORED 2026-08-26 from config.lua.bounce-bak-054831 (the state live during the 2026-08-19
    -- 01:47 demo video). The later "v5 PD-damped 120 N·m" retune was what killed the good feel.
    -- BOUNCE COUNT 1..MaxBounces, SCALED BY THE ACCEL GATHERED (2026-08-14, user ask). REPLACES the old
    -- binary TwoBounce* (fast car => 2, else 1) which almost always resolved to 2. Now the accel at engage
    -- maps linearly from MinAccelMs2 (=1 bounce) to BounceMaxAccelMs2 (=MaxBounces), then jitters ±1 so a
    -- given launch isn't perfectly predictable: a soft pull usually pops once, a hard launch 2-3 times.
    MaxBounces        = 3,      -- ceiling on spring-back bounces per launch
    BounceMaxAccelMs2 = 11.0,   -- accel (m/s^2) at engage that earns the full MaxBounces
    -- (TwoBounceTopKmh / TwoBounceAccelMs2 retired 2026-08-14 — kept out; the accel map above owns count.)
    BounceDecay       = 0.6,    -- each later bounce peak = previous * this (spring-back is weaker than the punch)
    BounceLandPitch   = 2.0,    -- pitch (deg) at/under which a falling bounce counts as "landed"

    -- FORWARD SPEED BOOST (user: speed should GAIN faster while the nose is up, like a real drag car
    -- — front wheels off the ground, weight on the rears). Applied as a ground-plane forward velocity
    -- increment (mass-independent; z dropped so the pitched nose never injects upward velocity).
    -- 2026-08-14 user "more speed getting off from it": BoostAccelMs2 6.0 -> 10.0 (stronger drag surge
    -- while the nose is up) and BoostMaxKmh 140 -> 170 so the pull carries further before it cuts.
    BoostAccelMs2 = 10.0,       -- extra forward accel (m/s^2) at full nose-up (scaled by lift + bounce)
    BoostMinPitch = 3.0,        -- no boost until the nose is at least this high (front actually light)
    BoostMaxKmh   = 170.0,      -- launch effect only — no boost past this speed

    -- WHEELIE DRIVE COMPENSATION (2026-08-14 user: front wheels up = GTA gives less drive on two contact
    -- patches, so a wheelie car accelerates slower while the nose is up). Adds a TORQUE top-up (applied
    -- last in main.lua, after all cuts) for as long as the wheelie is active, scaled by nose height so it
    -- fades in/out with the lift. This makes up for the lost front-wheel drive so wheelie-able cars pull
    -- AWAY on launch instead of bogging. DriveCompMult = peak torque multiplier at full nose-up.
    DriveCompEnabled = true,
    DriveCompMult    = 1.35,    -- 1.35 = +35% drive torque at full lift (fades to 1.0 as the nose drops)

    -- TORQUE-SCALED BOUNCE: bounce height rides HK.torqueMultApplied (final drive torque). Map
    -- [1.0 .. TorqueForMax] -> [TorqueFloor .. 1.0]: a stock 1.0 pull still lifts (floored), extra
    -- launch torque bounces higher, a bog barely lifts.
    TorqueFloor   = 0.5,        -- lift fraction at a plain 1.0-torque launch (never zero)
    TorqueForMax  = 1.8,        -- torqueMultApplied that yields full (1.0) bounce scale

    -- LIFT TORQUE (N·m, pure pitch). The height knob. History: 12000 flew, 1200 too strong, 120 too
    -- weak/wouldn't ramp with the old damping. Rebuilt bounce machine removed the rate-damp that was
    -- starving it; 900 gives a real punch that the pitch fade + apex still cap. Raise/lower in-game.
    LiftTorqueNm = 900.0,

    -- ACCEL-SCALED HEIGHT (2026-08-14 reramp: DEAD for the lift — the nose now rides REAR THRUST, not
    -- measured accel, see the reramp block below. Kept only so old dbg refs to wheelieAccel don't nil).
    MinAccelMs2    = 3.0,
    AccelForMaxMs2 = 9.0,
    AccelTau       = 0.12,      -- smoothing on the accel measurement (still shown on /handlingdbg)

    -- ============================================================================================
    -- 2026-08-14 REAR-THRUST RERAMP — the nose-lift is now driven by the PHYSICAL wheelie cause:
    -- REAR THRUST = drive torque × how HOOKED the rear tyres are (grip fraction), both measured live.
    -- The front lifts as a REACTION to the rears biting, exactly like a real drag car. The trigger is
    -- ANY hard low-speed launch tied to the wheelspin logic (not just Launch Control), and the engine
    -- holds MAX RPM while the nose is up (redline pin), the gear held so the pin can't phantom-upshift.
    -- ============================================================================================

    -- SHOOT MODEL (the physical wheelie: the rears spin up = loaded, then HOOK = forward yank = nose
    -- up). Lift ∝ torque × spin-energy × how-hooked-now. Read from vl_detectWheelspin (worst driven
    -- wheel over-speed vs ground, m/s):
    --   • SPIN ENERGY = peak-hold of the slip / SpinFullMps, bleeding at SpinEnergyDecay m/s per s —
    --     "how loaded the rears GOT". Survives the split-second the slip collapses on the hook.
    --   • HOOK FRAC = 1 - slip/SpinFullMps — how much the rears are biting RIGHT NOW.
    --   • SHOOT = energy × hook: high only when it WAS spinning fast and is NOW gripping (the yank).
    -- 2026-08-14 GATE-VERIFY TOGGLE. false = the lift is a clean CONSTANT-strength pop the instant the
    -- gate fires (LC + drift-key + W + S), with the shoot/grip NOT gating arm and NOT scaling height —
    -- so we can confirm the ENGAGEMENT is correct in isolation. true = re-couple the lift to the shoot
    -- model (torque × spin-energy × hook) for the physical rear-down yank. Flip to true once the gate
    -- feels right. The shoot values are still computed + shown on /handlingdbg either way.
    ScaleByShoot = false,

    SpinFullMps     = 8.0,      -- slip (m/s) treated as a "full" spin (energy + hook normalise to this)
    SpinEnergyDecay = 6.0,      -- how fast the loaded spin-energy bleeds (m/s per second) once slip drops

    -- SHOOT arm/scale (rearThrust = torqueFrac × shoot, both 0..1). The shoot spikes briefly at the
    -- hook, so the arm floor is low; the lift-scale maps arm..ForMax onto the nose-up rate.
    ThrustArm    = 0.18,        -- min shoot-thrust to ARM a wheelie (the hook spike clears this)
    ThrustForMax = 0.75,        -- shoot-thrust that yields the FULL nose-up rate

    -- WHEELSPIN GATE for the trigger. The wheelie now REVERTS to the LC gate (HK.launching) AND
    -- requires drift-key (HK.driftMode) + wheelspin. SpinArmMps = the slip (m/s) that counts as the
    -- rears being genuinely lit if the burnout gesture flag (HK.burnoutActive) isn't set.
    SpinArmMps   = 3.0,

    -- RPM MAX WHILE LIFTED (user: "IT NEEDS MAX RPM WHEN LIFTED UP"). While the ACTUAL FRONT WHEELS are
    -- off the ground (measured, not pitch) the needle pins toward RpmPinTarget (or the peak rpm actually
    -- reached, whichever is higher) via the cosmetic vl_setRpmRaw path in main.lua, and the gear is held
    -- (AUTO cars only) so the painted rpm can't phantom-upshift. Both release when the front touches down.
    RpmPinMinPitch = 3.0,       -- (legacy — pin now gates on front wheels off, not pitch)
    RpmPinTarget   = 0.98,      -- pin the needle to this fraction of redline while the front is up

    -- FRONT-WHEELS-OFF ACCELERATION (2026-08-14, user: "still accelerate even at max rpm, not upshifted,
    -- as only two wheels on ground — raise the speed cap, stronger speed + torque during that time").
    -- While the front is up the held gear would normally pin at its rev-limiter speed-cap; raise that cap
    -- so the car keeps pulling at redline. SpeedCapBoost multiplies the cap (1.15 = +15% top for the gear).
    -- FrontOffTorque is the drive-torque multiplier applied in main.lua while the front is off (the real
    -- "keep accelerating hard on the rears" surge, stronger than the pitch-fade DriveComp it supersedes).
    SpeedCapBoost   = 1.15,     -- raise the held-gear rev-limiter speed-cap by this factor while front is up
    FrontOffTorque  = 1.45,     -- drive-torque multiplier while the front wheels are off the ground
    FrontOffBoost   = 1.6,      -- forward-velocity surge multiplier while the fronts are actually off (felt step)

    -- LANDING-SETTLE UPSHIFT DELAY (user: "auto upshift only when hitting the ground ~120ms later").
    -- The auto box is blocked from upshifting the whole time the front is up, THEN held this many ms more
    -- after the front wheels touch back down so the car settles before it grabs the next gear. Auto-only.
    UpshiftLandMs   = 120,      -- ms after front-wheel touchdown before the auto-upshift is allowed

    -- Pitch limiting (degrees of nose-up). Torque fades to 0 near the cap so the bounce eases over
    -- its apex instead of flipping over backwards.
    -- 2026-08-14 v2 (user: "acceleration didn't differ from the front wheel touching ground or not" +
    -- "ends fast, longer lasting"). 18° often wasn't high enough to actually LIFT the front wheels off
    -- the tarmac, so frontWheelsOff() rarely fired and the FrontOffTorque/speed-cap boost never kicked
    -- in — hence "no difference". Raise the apex to 26° so the fronts genuinely leave the ground (the
    -- boost engages) AND there's more travel before apex, so the rising force lasts longer. MaxPitch
    -- stays 30 as the anti-flip hard cap (the fade eases torque to ~0 before we reach it).
    TargetPitch  = 26.0,        -- the angle each bounce eases toward (its apex)
    MaxPitch     = 32.0,        -- hard cap: no torque past this

    -- Ramp smoothing on the lift factor. 2026-08-14 v2 (user: "too sudden, not a smooth curvage"):
    -- AttackTau 0.18 -> 0.30 so the factor climbs more gradually into each bounce — a swelling drag
    -- lift, not a punch. Release stays quick so a bounce still drops cleanly into its fall.
    AttackTau  = 0.30,          -- gradual swell into each bounce (smoother onset)
    ReleaseTau = 0.06,          -- fast drop between/after bounces

    NotifyOnAction = false,
}

-----------------------------------------------------------------
-- [F2] DRAG LAUNCH HEADLIFT
-- Automatic (no key): during a hard standing-start launch, the nose
-- lifts briefly like a drag car squatting and unloading the front.
-- Ties into Launch Control — fires when a launch is in progress.
-----------------------------------------------------------------
Config.Headlift = {
    -- 2026-08-14: ENABLED after the force-path rebuild (same net-zero pitch couple as
    -- the wheelie, gentler + pitch-capped low). Fires automatically on a hard launch;
    -- HK.launching/HK.launchT from the CURRENT gearbox launch control feed it. TUNE
    -- LiftForceN in-game (per-side). Watch /handlingdbg HEADLIFT line.
    -- 2026-08-14 DISABLED: this auto-fired a nose-lift on RWD launches with NO key held
    -- (explains "jumping without holding alt" on the RWD Redeye but not AWD Chiron/911ts).
    -- Never a requested feature; the wheelie [F1] is the intentional key-held one.
    -- 2026-09-06 RE-ENABLED as the LC LAUNCH VISUAL: user wants a subtle nose-lift to show
    -- the car is LAUNCHING. Now gated STRICTLY to a real Launch Control launch window
    -- (RequireLaunchControl=true → fires ONLY while HK.launching is set by the gearbox LC),
    -- so the old auto-fire-on-any-RWD-stab bug can't come back. Force scaled to ~1/10 of the
    -- old wheelie-grade lift ("1/10 or even less") and pitch-capped very low = a subtle cue.
    Enabled = true,

    -- STRICT LC GATE (2026-09-06): true = the lift ONLY happens during a live LC launch
    -- (HK.launching). false = the old standalone accel trigger (MaxSpeed/MinThrottle/MinAccel)
    -- comes back — that's what auto-fired on plain RWD launches, so keep this true.
    RequireLaunchControl = true,

    -- Trigger conditions — ONLY consulted when RequireLaunchControl=false (legacy path)
    MaxSpeedKmh   = 70.0,       -- only at the start of the run
    MinThrottle   = 0.9,        -- pinned throttle
    MinAccelMs2   = 4.0,        -- must be accelerating hard (m/s^2)

    -- Lift force — ~1/10 of the old wheelie-grade value (5500). Just unloads the nose a hair
    -- for the launch cue. Tune in-game against /handlingdbg HEADLIFT; raise a touch if you
    -- can't see the lift, but keep it subtle (this is a cue, not a wheelie).
    LiftForceN    = 550.0,
    LiftOffsetY   = 2.0,

    -- Pitch cap — VERY low now (subtle launch cue, not a squat/wheelie)
    MaxPitch      = 4.0,

    -- How long the headlift can stay active per launch (ms) — clamped to the launch window
    MaxDurationMs = 1600,

    -- Smoothing
    AttackTau  = 0.08,
    ReleaseTau = 0.25,

    -- Skip only genuinely front-biased cars (true FWD econoboxes don't launch-lift). RWD +
    -- AWD supercars (bias ~0.4-0.55) still get the cue. Raised 0.55→0.65 so AWD launches lift.
    SkipIfFrontBiasAbove = 0.65,
}

-----------------------------------------------------------------
-- [F3] MUSCLE HANDBRAKE BUG GUARD (throttle-gated)
-- ROOT: on muscle (class 4), forcing engine/transmission state while the car is
-- handbraked triggers GTA's hardcoded nose-lift reaction and discharges the whole
-- velocity vector (snap ~20km/h -> 0 + 180 heading flip). Native /setgear 6 is
-- IMMUNE because it stands the box fully down.
--
-- INSIGHT: the bug needs the handbrake, and you only pull the handbrake when you
-- are OFF the throttle (coasting / braking). So the danger condition is simply:
--   class 4  +  gear 1/2  +  handbrake held  +  throttle ~released
-- While that holds, behave like native [6]. The instant you get back on the gas,
-- hand control back to our box.
--
-- DRAG-SAFE: a launch is handbrake + FULL throttle (rev-build) -> throttle is high
-- -> never suspends -> our box keeps the RPM model & launch feel. Releasing the
-- handbrake to go = throttle high = our box. The ONLY time we fall to native is
-- handbrake + no gas (the slam), which is exactly the bug window.
-- SPAM-PROOF: handbrake-spam while OFF gas = native the whole time = immune;
-- handbrake-spam while ON gas = our box but that's a rev-build (no velocity to
-- dump) = safe. The old "our box + handbrake + low throttle" danger window is gone.
-----------------------------------------------------------------
Config.WheelieGuard = {
    Enabled       = true,
    OnlyMuscle    = true,    -- 100% confirmed only class 4 (Muscle) hits this bug
    MaxGear       = 2,       -- bug bites in 1st/2nd only

    -- Throttle gate (with hysteresis to avoid flicker right at the boundary):
    --   suspend when throttle drops to/below ThrottleOff while handbraked,
    --   resume when throttle rises to/above ThrottleOn.
    ThrottleOff   = 0.15,    -- <= this with handbrake = OFF gas = fall to native [6]
    ThrottleOn    = 0.35,    -- >= this = back on the gas = resume our box

    -- LOW-SPEED OVERRIDE — the throttle gate alone leaks: under ~20 km/h the handbrake
    -- dumps the whole velocity vector no matter what the throttle is doing (a slow car
    -- with bad rpm timing can still have the e-brake engage harder than it's moving), so
    -- "on the gas = safe" let the bug through. Below SuspendBelowKmh the handbrake ALONE
    -- suspends (throttle ignored) — this band IS the bug's envelope. A drag launch never
    -- grabs the handbrake, so it stays untouched. Above ResumeBelowKmh + on the gas we
    -- resume (genuine high-speed handbrake-drift, where the bug doesn't bite).
    SuspendBelowKmh = 25.0,  -- handbrake at/below this speed => suspend regardless of throttle
    ResumeAboveKmh  = 33.0,  -- only resume mid-handbrake once above this AND back on the gas
                             -- (must be > SuspendBelowKmh — the gap is the speed hysteresis)

    -- Nose-up gate — NOT active (handbrake+throttle is enough). If ever needed, the
    -- suspend can additionally require the nose up past NoseUpPitch.
    RequireNoseUp = false,
    NoseUpPitch   = 3.0,     -- deg nose-up (state.pitch is nose-up positive)

    -- COAST SNAP GUARD (NO handbrake) — the SAME native velocity-dump bug on muscle
    -- addon cars also fires on a plain coast-to-idle: after a launch, coasting down
    -- through ~15 km/h in gear 1/2 OFF the gas, the rigid-body solver snaps the car to
    -- a dead stop (no handbrake involved). Root is identical to the handbrake flip, so
    -- the fix is identical: stand the box down to native [6] (which is immune) through
    -- the snap band. This is a STAND-DOWN only — NO brake plant (a coast must not gain
    -- braking). Resume the instant you touch the gas, or once back above CoastResumeKmh.
    CoastGuard    = true,    -- master toggle for the no-handbrake coast stand-down
    CoastBelowKmh = 22.0,    -- off-gas, gear 1/2, below this speed => stand down to native
    CoastResumeKmh = 28.0,   -- resume our box once coasting back above this (> CoastBelowKmh)

    -- LOW-SPEED BRAKE PLANT — the engine-write suspend defuses most cars, but some
    -- muscle cars still flip when the handbrake is grabbed at very low speed. Planting
    -- real brake pressure on ALL wheels keeps the load symmetric so the rigid-body
    -- solver has no asymmetric impulse to discharge. ON by default now (the suspend
    -- alone wasn't enough). See client/wheelieguard.lua.
    BrakePlant    = true,    -- master toggle for the low-speed brake plant
    BrakeBelowKmh = 36.0,    -- only plant when slower than this (the flip envelope)
    BrakeDelayMs  = 30,      -- hold the handbrake in-window this long before planting
                             -- (lets a quick tap / flick slip past untouched)
    BrakeLevel    = 1.0,     -- 0..1 brake pressure per wheel (1.0 = full). Lower if a
                             -- catch feels too abrupt.
}




-----------------------------------------------------------------
-- [W1] PASSENGER WEIGHT — acceleration debuff scaled by passenger count.
-- Each occupied NON-DRIVER seat (player OR npc) bleeds a little acceleration
-- via the engine torque multiplier (NOT mass, NOT drive force) so TOP SPEED is
-- never affected — only the rate of acceleration. The debuff FADES OUT near the
-- car's top speed so it is mathematically zero at terminal velocity (honours the
-- speed invariant). Default = no passengers = no debuff = level 1 (stock).
-----------------------------------------------------------------
Config.Payload = {
    Enabled          = false,  -- [BASELINE TEST] disabled for clean stock-power retest (was true)
    PerPassenger     = 0.05,   -- accel debuff per occupied non-driver seat (-5% each)
    MaxDebuff        = 0.15,   -- hard cap total (-15% = 3 passengers; 3 extra levels over stock)
    CountNpcs        = true,   -- count NPC passengers too (weight is weight)
    -- HIGH-SPEED FADE: keep the debuff at full strength while accelerating, then
    -- ramp it to ZERO over the top fraction of the car's speed range so it can
    -- never shave top speed. Fade is computed vs the car's own fInitialDriveMaxFlatVel
    -- (self-calibrating per vehicle — no per-car tuning).
    FadeStartFrac    = 0.80,   -- below this fraction of top speed = full debuff
    FadeEndFrac      = 0.97,   -- by this fraction = zero debuff (top speed untouched)
    PollMs           = 500,    -- re-count seats / re-read max-vel at this cadence (not per-frame)
}

-----------------------------------------------------------------
-- [B*] MANUAL GEARBOX
-- Original HOMEKONG implementation.
-- Engine-side enabler: SET_TRANSMISSION_REDUCED_GEAR_RATIO (build 3095+; server 3570).
-- Owns fInitialDriveForce + RPM + throttle controls. Drift owns grip/suspension —
-- disjoint field sets, so the two never stomp each other.
-----------------------------------------------------------------
Config.Gearbox = {
    Enabled = true,                  -- [TESTING step 3: detection/activation verify]
    Debug   = false,                  -- F8 prints while bringing it up

    -- EXTERNAL-RESYNC GUARD. Detects when another resource re-syncs the vehicle's
    -- handling out from under our drive-force write-cache (jim's pushVehicle when
    -- /admincustoms opens, or an entity-control migration) and re-asserts, fixing the
    -- "stuck at 0 velocity until respawn" bug. DriveForceResync=false disables the check;
    -- DriveForceResyncMs = how often (ms) to sample the live value (250 = 4x/sec, cheap).
    DriveForceResync   = true,
    DriveForceResyncMs = 250,
    -- PER-FRAME EXTERNAL-ZERO CATCHER. The 250ms resync above heals a slow drift, but an escrowed
    -- chip / jim turbo on an owned+modded car can write fInitialDriveForce=0 for ~150ms mid-gear
    -- (proven by ring-buffer telemetry: torqueApplied stayed 1.1-1.2 while df dropped to 0 = NOT a
    -- shift = external clobber). This catches it EVERY frame when our mirror says drive should be
    -- live (>0) but the live float reads 0 — re-asserts in one frame instead of up to 250ms. Only
    -- writes when actually clobbered; never fights a legitimate shift/neutral decouple (mirror==0).
    DriveForceZeroCatch = true,

    -- ── GEAR + RPM PASSENGER / SPECTATOR SYNC ───────────────────────────────────
    -- The gearbox runs DRIVER-LOCAL: our tick paints rpm (SetVehicleCurrentRpm) AND owns the gear
    -- (incl. N/R via the reverse gate) only on the driver's client. On a passenger/spectator's
    -- client the SAME car is still running GTA's OWN local auto-box — a different (always-forward)
    -- gear that re-pitches the note and FIGHTS a bare rpm write (why rpm only "kinda" carried), and
    -- never produces free-rev NEUTRAL or REVERSE. The engine note is f(native gear, rpm), so we
    -- stream BOTH the driver's native gear AND the painted rpm and pin both remotely each frame.
    -- EV engine AUDIO (the electric hum swap) is synced separately via hk_ev_audio; this is the ICE
    -- engine-NOTE (gear/shift/launch/N/R). Pure feel — no physics/force, zero perf impact.
    RpmSync = {
        Enabled       = true,
        PublishHz     = 20,       -- driver push rate (change-detected + bucketed; statebag sets replicate)
        Bucket        = 0.02,     -- min normalised-rpm delta before we re-publish (a GEAR change always publishes)
        ApplyRangeM   = 120.0,    -- only re-apply on remote cars within this many metres (audible range)
        StaleMs       = 400,      -- if the bag hasn't updated in this long, stop forcing (driver left / bag died)
    },

    -- MANUAL (type 1) PERFECT SHIFT. Gives the classic-manual box the same perfect-shift
    -- reward as the sequential dogbox: a CLUTCH-HELD upshift landed in the Seq perfect rpm
    -- window (Seq.UpPerfectLo/Hi) earns Seq.UpshiftBonus torque + the gold gauge glow +
    -- a callout. Clutchless upshifts and clutched shifts outside the window are unchanged.
    -- Uses the Seq.* values so manual and sequential feel identical. false = disable.
    ManualPerfectShift = true,

    -- GEARBOX MODE. Controls which calibration/learning system is active.
    --   easy   = simple box, no RPM writes, no ratio/jim/expert cal
    --   normal = full box + background GTA-native 0-100 open-loop learner (default)
    --   expert = legacy SpeedCal / /setspeed / /accelcal / autocal system
    Mode = 'normal',

    -- ELECTRIC VEHICLES — a real EV runs ONE fixed reduction (no gearbox). GTA models
    -- them with nInitialDriveGears <= 1. Our ICE comfort box shapes shifts that don't
    -- ── REVERSE SPEED CAP ───────────────────────────────────────────────────────
    -- Real cars reverse SLOWLY — one short reverse gear tops out ~30-45 km/h. GTA lets you reverse almost
    -- as fast as you drive forward, which feels arcadey. This caps backward speed. SAFETY: it only acts on
    -- PHYSICAL backward motion (forwardSpeed < 0), never on gear/gate state — so sliding forward at speed
    -- and stabbing S (which just brakes) can NEVER be mistaken for reverse and capped. Enforced by zeroing
    -- the reverse accelerator at the cap (soft ceiling via drag, no velocity yank). See HK.ReverseCap_Tick.
    ReverseSpeedCap = {
        Enabled      = true,
        MaxKmh       = 42.0,    -- top reverse speed (km/h). Realistic short-reverse-gear ceiling.
        RampStartKmh = 6.0,     -- ceiling seeded here the frame reverse engages, then climbs to MaxKmh (slow build off standstill)
        RampMs       = 3800.0,  -- ms to ramp the ceiling from RampStartKmh up to MaxKmh (bigger = slower reverse acceleration)
    },

    -- REVERSE DRIVE (2026-08-14 rework — W drives reverse, S brakes). Control 72 can't be SHARED between
    -- "our W-injection" and "suppress physical S" (SetControlNormal can't hold a control below a held
    -- key), so reverse is driven by DIRECT VELOCITY instead of the control system — the same proven
    -- mechanism ReverseCap_Tick uses to CAP it. Both 71 and 72 are disabled in reverse; W adds backward
    -- velocity up to the cap, S brakes it. Feels like a slow short reverse gear.
    ReverseDrive = {
        Enabled     = true,
        AccelKmhPerS = 22.0,    -- how fast W builds backward speed (km/h per second). Lower = lazier reverse.
        BrakeKmhPerS = 32.0,    -- how fast S sheds backward speed (km/h per second). Firm but not grabby (60->32).
        CoastKmhPerS = 14.0,    -- passive decel when neither pedal held (engine-brake coast to stop).
    },

    -- ── ROLL / CREEP BASE LAYER (2026-08-16) ───────────────────────────────────
    -- The low-speed longitudinal model GTA is missing: a real car with no e-brake CREEPS forward in gear
    -- and ROLLS on any slope when you're not fully on the brake. This is the base every launch/wheelspin
    -- sits on — it's what rolls the car forward at the END of a spin instead of stopping dead. Only shapes
    -- the CRAWL band (below HandoffKmh); above that real engine torque owns motion. See HK.RollCreep_Tick
    -- (main.lua) + the slope term added to HK.ReverseDrive_Tick.
    RollCreep = {
        Enabled          = true,
        HandoffKmh       = 12.0,   -- above this forward speed, drive torque owns the car — this stands aside.
        ThrottleHandoff  = 0.10,   -- real throttle above this = player launching → hand off (no creep).
        -- CREEP (in gear, torque-converter walk toward this on the flat). User picked strong (8-12); manual
        -- boxes roll MORE via ManualCreepMult. Neutral has NO creep (free-roll, coasts to stop on flat).
        CreepKmh         = 10.0,
        ManualCreepMult  = 1.35,
        -- idle creep is a weak torque-converter walk: it must NOT climb a hill on its own (the "rolls
        -- upwards without throttle" bug). Fade creep to 0 as uphill grade (nose-up f.z) rises; fully gone
        -- above CreepHillGrade (~0.10 ≈ 6°), so on any real incline gravity wins and it holds/rolls back.
        CreepHillGrade   = 0.10,
        -- SLOPE: gravity along the forward axis, scaled by sin(pitch). Tuned DOWN from 34 (rolled to the
        -- 12 km/h handoff way too fast on a hill — user wanted ~65% slower) to a gentle, believable creep-
        -- roll. Applies in gear, neutral AND reverse. Raise for eager hills, lower for lazy ones.
        GravityKmhPerS   = 12.0,
        -- FOOTBRAKE HOLD: at/above this pedal (0..1) the footbrake is an ABSOLUTE hold at crawl (pins the
        -- car, cancels the slope). Below it, a partial brake = a partial (slow-roll) hold. Handbrake always
        -- pins regardless of this. 0.55 ≈ a firm press, so a light drag still lets it creep.
        BrakeHoldMin     = 0.55,
        -- RESISTANCE toward rest: engine-brake in gear (firm), free-wheel in neutral (light = long coast).
        GearResistKmhPerS    = 8.0,
        NeutralResistKmhPerS = 3.0,
        -- BRAKE at crawl: how fast a full brake pins the car (km/h per second), scaled by pedal. Partial
        -- brake = partial hold (the "didn't fully hold brake → rolls" behaviour).
        BrakeKmhPerS     = 40.0,
        MaxRollbackKmh   = 8.0,    -- cap how fast an uphill can roll the car backward (never runs into fake reverse).
        StopDeadbandKmh  = 0.15,   -- below this |speed| settle to a hard 0 (no jitter around standstill).
        -- ABSOLUTE HOLD is now speed-gated so braking down through the crawl band DECELERATES instead of
        -- teleporting to 0 (the "instant stop at ~20-and-under" bug). Only PIN once settled below HoldPinKmh;
        -- above it (still in the band) a firm brake/handbrake decelerates at HoldDecelKmhPerS.
        HoldPinKmh       = 3.0,    -- at/below this the held brake/handbrake pins velocity to 0 (against creep/gravity).
        HoldDecelKmhPerS = 55.0,   -- UNUSED (forward braking now defers to native) — kept for reference.
        -- BACKWARD-ROLL BRAKE: while rolling BACKWARD (downhill/creep rollback) the standstill code disables
        -- native control 72, so the native footbrake is dead — we must decelerate the rollback ourselves.
        -- Rate (km/h per s) scaled by footbrake pedal; handbrake counts as full. This is why the footbrake
        -- couldn't stop a backward roll (only handbrake could) before 2026-08-16.
        RollbackBrakeKmhPerS = 45.0,
    },

    -- ── REVERSE GATE (EV + comfort auto + DCT-auto) ────────────────────────────
    -- Realistic modern-automatic R<->N<->D shuffle. Full sequence from moving forward:
    --   moving + HOLD brake -> speed hits 0 -> NEUTRAL (free-roll) -> RELEASE brake, press
    --   brake again -> REVERSE. Out of reverse: press THROTTLE -> NEUTRAL -> throttle again
    --   (or keep holding it — auto-walks after WalkStepMs) -> DRIVE (gear 1). A held brake
    --   never rolls straight into reverse; a held throttle in reverse walks R->N->D so you
    --   just pull away. Speedo shows R / N / gear as the gate moves. Applies to pure EVs,
    --   comfort auto (mode 0) and DCT-autos; manual/sequential/paddle keep their own ladder.
    ReverseGate = {
        Enabled      = true,
        StopKmh      = 2.0,    -- "stopped" threshold — neutral arms at/below this speed
        BrakePress   = 0.5,    -- brake input above this counts as "braking" (0..1)
        ThrottleExit = 0.15,   -- throttle above this counts as "pressed" (steps the gate)
        WalkStepMs   = 220,    -- held-throttle dwell in NEUTRAL before auto-walking N->D (so the
                               -- speedo visibly passes through N between R and 1)
        -- KEY-DRIVEN REVERSE (2026-08-14 rework #2). S is a PURE BRAKE now — it no longer
        -- selects reverse. ALL automatic modes (comfort auto, DCT-auto, hybrid e-mode) now
        -- reach reverse the SAME way manuals do: DOWNSHIFT key walks D->N->R, UPSHIFT key
        -- walks R->N->D. Reverse then DRIVES by velocity (W = back, S = brake) via the same
        -- HK.ReverseDrive_Tick the manuals use — no native brake-to-reverse anywhere. Pure EVs
        -- ditch Neutral entirely: J+K (both shift keys together) TOGGLES D<->R. Set false to
        -- restore the legacy brake-to-N->press-S-again reverse gate (single-line revert).
        KeyDriven    = true,
        NToRMaxKmh   = 8.0,    -- key-driven: N->R only engages at/below this speed (safety, like manual)
    },

    -- ── ECU LAUNCH CONTROL (DCT-auto / EV / hybrid-EV ONLY) ─────────────────────
    -- Emulates real ECU software-controlled launch. Sequence: be in NEUTRAL -> hold HANDBRAKE
    -- + FULL THROTTLE -> the ECU holds the computed optimal launch rpm (per-car, from our gear-
    -- ratio data — highest rpm that hooks up without frying the tyres) -> RELEASE the handbrake
    -- (throttle still down) -> LAUNCH: engages gear 1 with a small FADING torque surge. Manuals
    -- never use this (they get perfect-shift boosts instead). Rev-hold uses the real launch-rev
    -- native AND a forced rpm feed (belt-and-braces: the native is unproven on addon cars).
    Launch = {
        Enabled        = true,
        StageThrottle  = 0.90,   -- throttle >= this (with handbrake, in N) = STAGED
        StageBailThrottle = 0.5, -- throttle drops below this while staged = cancel
        StageMaxKmh    = 4.0,    -- can only stage at/below this speed (a standstill)
        -- BRAKE LIGHT WHILE STAGED (2026-08-14): light the brake lamps the whole time launch
        -- mode is STAGED (the wound-up hold). IRL a launch is a two-foot brake-torque hold, so
        -- the brake lights are on; arcade-wise we just mirror that visually. Asserted every
        -- staged frame (SetVehicleBrakeLights is per-frame) and reverts the instant the launch
        -- fires or the stage bails. Set false to disable.
        BrakeLightWhenStaged = true,
        -- Per-car launch rpm band (0..1). computeLaunchRpm maps gear-1 ratio into this range:
        -- short 1st (more wheel torque) -> lower rpm; tall 1st -> higher. TractionFactor scales
        -- the whole thing (raise for grippier launches / more aggression; custom cars vary).
        -- REALISTIC LAUNCH HOLD (was 0.90-0.99, near redline): no real car's launch control sits
        -- at full redline on the line — it builds to a DESIRED launch rpm and HOLDS there. The old
        -- near-redline stage was a stopgap "until slip-limiting exists"; TractionControl below now
        -- exists and is enabled, so we hold at a realistic launch rpm and let TC + grip-assist
        -- manage the hook. The staged engine is CAPPED at this rpm by the game's launch rev limiter
        -- (setMaxLaunchRevs) — it no longer ramps to full. Tune against the telemetry harness
        -- (0-100 / peak-g / peak-slip per launch); raise if the hooked launch bogs, lower if it spins.
        LaunchRpmMin   = 0.60,
        LaunchRpmMax   = 0.75,
        TractionFactor = 1.0,
        -- SELF-TUNING LAUNCH RPM (per model). The gear-1-ratio estimate is grip-blind, so the same
        -- computed rpm hooks one car (P1) and spins/bogs another (M4 G82) = LC slower than no-LC on
        -- some cars. After each measured 0-100 pull the learner nudges a per-model rpm offset from
        -- the pull's peak wheel-slip vs TractionControl.TargetSlip: spun past the grip band -> stage
        -- lower; never reached it while TC sat idle -> stage higher; hooked near target -> hold.
        -- Converges each car onto its own fastest launch over a handful of pulls. Session-only.
        LearnRpm       = true,   -- false = disable the learner (pure gear-1 estimate)
        LearnStep      = 0.02,   -- rpm offset moved per pull (small = stable, converges over ~5-8 launches)
        LearnMaxTrim   = 0.15,   -- |offset| ceiling so a noisy pull can't run the rpm away
        -- HARD-THROTTLE DRAG LAUNCH SURGE (2026-08-14, user: "nudge the hard throttle (W-HOLD) launch
        -- stronger on the start launch drag — W tap-tap-tap stays the same"). BoostMult is applied ONLY
        -- in launchBoostApply while lcPhase=='launched' — i.e. a STAGED launch (handbrake + WOT in
        -- neutral, then fire). The W-tap-tap-tap "pull-away" re-engage never stages a launch, so it is
        -- untouched by this surge — exactly the split the user asked for. 1.2 = +20% torque at the launch
        -- instant, tapering to 1.0 over BoostMs / by EndSpeedKmh. (1.6 was too much.) AWD gets MORE via
        -- the Drivetrain.awd overlay below (its driven front axle hooks harder, so it can use the power).
        -- 2026-09-06 AGGRESSIVE STABILITY PASS (user: LC "must be more stable and faster than
        -- launching directly"). Base surge nudged 1.2→1.28 so a staged launch clearly out-pulls
        -- a plain WOT. Per-drivetrain blocks below push harder where the layout can take it.
        BoostMult      = 1.28,   -- +28% off-the-line surge on a hard-throttle staged launch (RWD/FWD base)
        BoostMs        = 2400,   -- window that HK.launching (nose-lift visual) stays set
        EndSpeedKmh    = 90.0,   -- launch phase fully ends by here regardless (whichever first)

        -- ── TRACTION CONTROL (slip governor) ─────────────────────────────────────
        -- THE missing piece that makes LC actually quick. We stage near redline, so on
        -- release the tyres would light up + waste grip (spin = slower than a clean hook).
        -- This measures wheel-vs-ground slip every launch frame and CUTS torque to hold the
        -- tyres at their peak-grip slip band. Cut-only (never adds power — honours the accel
        -- invariant). Runs only during the launch window (lcPhase=='launched'); normal driving
        -- is untouched. Set Enabled=false to go back to the raw redline dump.
        -- 2026-09-06 AGGRESSIVE PASS: tighter slip band + harder/faster catch = the launch HOOKS
        -- instead of frying grip (spin is slower than a clean hook). MinTorque raised so the cut
        -- never bogs the pull — it trims spin without killing drive. Per-class blocks override.
        TractionControl = {
            Enabled      = true,
            TargetSlip   = 2.0,   -- m/s slip to hold (tightened 2.2→2.0 = catch spin sooner)
            DeadBand     = 0.6,   -- m/s grace below target (0.8→0.6 = start trimming a hair earlier)
            Gain         = 0.70,  -- cut per m/s of excess slip (0.55→0.70 = firmer, quicker settle)
            MinTorque    = 0.30,  -- torque floor (0.25→0.30 = trims spin but keeps pulling, no bog)
            AttackPerSec = 8.0,   -- how fast the cut deepens (6→8 = catches a spin faster)
            ReleasePerSec= 3.0,   -- how fast the cut backs off as slip recovers (per second) — smoother than attack
            LaunchRpmDrop= 0.0,   -- optional: subtract this from the staged launch rpm now that TC catches spin
                                  -- (0 = keep the near-redline stage; raise ~0.05-0.10 to stage a touch lower)
        },

        -- ── GRIP ASSIST (initial-bite) ───────────────────────────────────────────
        -- Kills the BOG off the line. The slip governor (TractionControl above) only ever
        -- CUTS power — it can't help the car HOOK in the first instant, so a low-grip launch
        -- still bogs before the tyres bite. This gives a brief fTractionCurveMax (tyre grip)
        -- bump at the launch instant that FADES OUT fast (over Ms) so there's no arcade-grippy
        -- feel and no snap when it ends — just a sharper initial hook. Scales from the car's
        -- REAL grip (vehlib captures the original), fully restored when the window closes.
        -- Drift owns the same field but a standstill launch and a slide never overlap.
        -- 2026-09-06 AGGRESSIVE PASS: the grip bite is the lever that makes LC BOTH faster AND more
        -- stable (more tyre grip at the instant = hooks the surge instead of spinning it away). Bumped
        -- 1.5→1.75 bite over a slightly longer 700→850ms fade so the whole off-line phase is planted.
        GripAssist = {
            Enabled = true,
            Mult    = 1.75,  -- fTractionCurveMax multiplier AT the launch instant (fades to 1.0). Higher = harder bite
            Ms      = 850,   -- fade the bump out over this many ms (short — just the launch, not the whole pull)
        },

        -- BAIL GRACE (controllers): throttle must stay below StageBailThrottle for this long
        -- (ms) to cancel a stage — stops a momentary analog-trigger wobble silently killing the
        -- launch. Keyboard (binary W) never dips so it's unaffected. Raise if controllers still
        -- lose stages to trigger noise.
        BailGraceMs    = 250,

        -- ── MANUAL LAUNCH (gearMode 1, H-pattern stick) ──────────────────────────
        -- 2026-08-14: the true-manual box now gets a launch stage too, same machinery as the
        -- auto/DCT one. SEQUENCE: sit in NEUTRAL, hold handbrake + full throttle → STAGE (revs
        -- hold at the LC target). Leave neutral by UPSHIFTING into 1st → FIRE. The handbrake is
        -- only the neutral hold: releasing it a moment BEFORE the upshift still launches (the
        -- upshift is the trigger, within StageManualGraceMs of the release). Fields here OVERRIDE
        -- the base Launch fields for gearMode 1 only; anything unset falls back to base. Same
        -- values as base for now — separated so manual can be tuned independently later.
        Manual = {
            Enabled            = true,   -- false = manual reverts to no-LC (today's behaviour)
            StageManualGraceMs = 400,    -- upshift within this long after a handbrake release still fires
            -- STAGING HOLD (2026-08-14, user intent): launch control stages on the HANDBRAKE ONLY.
            -- StageOnFootbrake=false means holding throttle+FOOTBRAKE in neutral just REVS the engine
            -- (bounces off the limiter) and never arms/fires the launch — so W+S is a rev, not an
            -- accidental launch. Set true to also allow the old brake-torque footbrake staging (a
            -- footbrake launch: build revs on the brake, drop it, go). Kept as a flag so it's reversible.
            StageOnFootbrake   = false,
            -- BRAKE-TORQUE STAGING (only when StageOnFootbrake=true): manual/seq also stage on the
            -- footbrake held past StageBrake (+throttle floored, in neutral, standstill). If staged on
            -- the FOOTBRAKE, releasing it (brake < StageBrake*0.5) with throttle still floored FIRES the
            -- launch. If staged on the HANDBRAKE, the fire stays the upshift (handbrake release alone
            -- won't cancel/fire).
            StageBrake         = 0.55,   -- footbrake >= this (+throttle floored, in N) stages manual/seq (only if StageOnFootbrake)
        },

        -- ── PER-DRIVETRAIN LAUNCH PROFILES ───────────────────────────────────────
        -- 2026-08-14: RWD / AWD / FWD launch DIFFERENTLY. Each block OVERRIDES the base Launch
        -- fields (and nested TractionControl / GripAssist) for that drive class only; unset
        -- fields fall back to base. Class comes from HK.dbgDrive.class (fDriveBiasFront). These
        -- capture how each layout actually behaves off the line:
        --   RWD — spin-prone: stage a touch LOWER, catch spin HARD (low target slip, high gain).
        --   AWD — hooks: can use MORE rpm, let it bite (higher target slip, softer gain), big grip.
        --   FWD — front-load bog + torque steer: lower rpm, strong initial grip, moderate governor.
        -- Values start CLOSE to base so behaviour is sane immediately; tune each per-class live.
        Drivetrain = {
            -- 2026-09-06 AGGRESSIVE PASS per class:
            rwd = {
                -- spin-prone: catch spin HARD + strong bite so it hooks the surge, not fries it.
                LaunchRpmMin = 0.58, LaunchRpmMax = 0.72,
                TractionControl = { TargetSlip = 1.8, Gain = 0.85, MinTorque = 0.28 },  -- tighter+firmer than before
                GripAssist      = { Mult = 1.7, Ms = 800 },                             -- stronger initial hook
                -- physics lever (Phase 2, applied in launchBoostApply): extra rear grip bump on
                -- launch to help the driven axle hook without just cutting power. 1.0 = off.
                LaunchRearGripMult = 1.0,
            },
            awd = {
                LaunchRpmMin = 0.64, LaunchRpmMax = 0.80,
                -- HARD-THROTTLE SURGE (2026-08-14, user: "AWD needs 1.2 more than current"). AWD hooks
                -- both axles off the line, so it can put the extra power down cleanly. Overlays the base
                -- BoostMult (1.2) with 1.44 = 1.2 × 1.2 — i.e. 20% stronger again than the RWD/FWD base.
                -- AWD hooks both axles → put the power DOWN: bigger surge + big bite, softer governor
                -- (let it use the extra slip it can actually convert to grip). 1.44→1.55.
                BoostMult       = 1.55,
                TractionControl = { TargetSlip = 2.6, Gain = 0.50, MinTorque = 0.36 },  -- higher floor = keeps pulling
                GripAssist      = { Mult = 1.85, Ms = 900 },                            -- strongest bite (it can use it)
                -- physics lever (Phase 2): temporarily send more torque to the FRONT on launch
                -- (the classic AWD hook), faded over BiasMs. 0.0 = OFF (default — writing
                -- fDriveBiasFront overlaps drivetrain.lua's tcGov; keep off until isolated-tested).
                LaunchBiasFront = 0.0,
                LaunchBiasMs    = 900,
            },
            fwd = {
                -- FWD front-load bog + torque steer: strong initial grip to beat the bog, moderate
                -- governor so it doesn't fight the front axle scrabbling for grip.
                LaunchRpmMin = 0.56, LaunchRpmMax = 0.70,
                TractionControl = { TargetSlip = 2.0, Gain = 0.60, MinTorque = 0.32 },
                GripAssist      = { Mult = 1.85, Ms = 800 },  -- hardest bite = kills the FWD bog
                -- physics lever (Phase 2): damp torque-steer yaw on launch (front-drive pulls to
                -- one side under full power). 0.0 = off.
                LaunchTorqueSteerDamp = 0.0,
            },
        },

        -- ── WHEELIE-CAPABLE RWD OVERLAY ──────────────────────────────────────────
        -- 2026-08-14: a car flagged wheelieLaunch=1 (and classified RWD) launches to LIFT THE NOSE,
        -- not just to hook. A pure grip-maximised launch is the WRONG launch for a wheelie: it plants
        -- the tyres and keeps the chassis flat, fighting the very weight-transfer that raises the
        -- front. So when resolveLaunchProfile sees a wheelie RWD, it overlays THIS block LAST (after
        -- the rwd class block) to bias the launch toward a clean lift: stage a touch LOWER (a hair
        -- less initial wheelspin so torque reacts through the chassis and loads the rear), and allow
        -- a little MORE rear slip / softer governor so the rear can squat and the nose can come up
        -- instead of the TC nannying it flat. Only overlays on wheelie+RWD; every other car is
        -- untouched. Keep these gentle — this shapes the launch, the actual lift lives in wheelie.lua.
        Wheelie = {
            LaunchRpmMin = 0.54, LaunchRpmMax = 0.68,   -- a touch lower than base rwd (0.58/0.72)
            TractionControl = { TargetSlip = 2.4, Gain = 0.55, MinTorque = 0.26 },  -- allow a bit more squat/slip
            GripAssist      = { Mult = 1.35, Ms = 600 }, -- slightly less front-flattening initial bite
        },
    },

    -- exist (shift dips, early-upshift, rpm-flare damp) on a single-ratio car, so EVs get
    -- their OWN lightweight branch instead: no shift shaping, instant torque, just the
    -- hold-both-keys coast neutral (+ optional gentle launch). EVs still resolve to type 0
    -- and still honour /setspeed + AccelMatch (pure-torque trims, gear-agnostic).
    EV = {
        Enabled       = true,   -- false = EVs run the normal comfort box (old behaviour)
        DetectByGears = true,   -- treat nInitialDriveGears<=1 (or highGear<=1) as an EV
        DetectByNative = true,  -- also treat GetIsVehicleElectric(model)==true as an EV
                                -- (matches hk-speedo's electric detection exactly)
        NeutralGesture = true,  -- hold BOTH shift keys = momentary coast neutral
        -- Optional per-model overrides (keys = model hash as a number, value = true):
        --   Models        = force-treat these as EV even if they carry fake extra gears
        --   ExcludeModels = never treat these as EV (e.g. a geared hybrid you want ICE)
        -- PURE-EV model list (value = true). Guarantees these detect as pure EV even if their
        -- .meta carries fake extra gears or GetIsVehicleElectric misreports (addon cars vary).
        -- Native/gear auto-detect below still catches anything not listed here.
        Models        = {
            ['plaid']      = true,   -- Tesla Model S Plaid (tri-motor EV)
            ['gcmmiev2010']= true,   -- Mitsubishi i-MiEV (early pure-EV city car)
        },
        ExcludeModels = nil,
        -- Gentle off-the-line smoothing. OFF by default — EV character is instant torque.
        LaunchSmooth  = false,
        LaunchKmh     = 12.0,   -- fade the smoothing out by this speed
        LaunchPower   = 0.88,   -- torque mult at a dead stop (1.0 = no smoothing)

        -- ── REGEN BRAKING (one-pedal driving) ──────────────────────────────────
        -- Real EVs decelerate on throttle LIFT (motor -> generator). Two driver modes,
        -- toggled by TAPPING the clutch key (LSHIFT — free on an EV, no gears):
        --   'onepedal' = strong lift-off decel that HOLDS the car at a stop (Tesla-style)
        --   'coast'    = regen OFF, the car glides/freewheels on lift (sailing)
        -- Applied as a rearward FORCE at speed (feels like engine braking, scales with
        -- speed × how far off-throttle you are), switching to a BRAKE HOLD near standstill
        -- so it parks instead of trying to push backward. Releases instantly on throttle.
        -- D1/D2/D3 REGEN LADDER (+ Coast) — like most modern EVs (Hyundai/Kia/BYD/Nio).
        -- Controls: ShiftUp/Down (K/J) step the level up/down through D1->D2->D3; the
        -- CLUTCH key (LSHIFT) drops straight to COAST (express reset) from any level.
        --   Level 0 = COAST  : no regen, free glide/sail on lift
        --   Level 1 = D1     : mild (~0.10g) — near-coast, gentle
        --   Level 2 = D2     : medium (~0.15g) — everyday
        --   Level 3 = D3     : strong (~0.21g) one-pedal + brake-hold at stop (Tesla Hold-style)
        -- DecelG values are real-measured (SAE/owner data). Velocity bleed is the sole decel
        -- actuator, so each maps 1:1 to felt slowdown.
        Regen = {
            Enabled       = true,
            DefaultLevel  = 3,           -- level a fresh EV starts in (0=Coast,1=D1,2=D2,3=D3)
            Levels        = {            -- [level] = deceleration in g (0 = coast/no regen)
                [0] = 0.00,
                [1] = 0.10,
                [2] = 0.15,
                [3] = 0.21,
            },
            HoldAtStopLevel = 3,         -- levels >= this get the brake-HOLD at a standstill
                                         -- (true one-pedal); below just fade to a roll/creep.
            LiftThrottle  = 0.10,        -- regen engages only when throttle is below this (= "lifted")
            FullLiftAt    = 0.02,        -- throttle at/below this = FULL regen; between = proportional
            HoldBelowKmh  = 8.0,         -- below this: switch from decel to a brake HOLD (park it)
            HoldPressure  = 0.6,         -- brake pressure (0..1) applied to hold the car at a stop
            MaxForceScale = 1.0,         -- global scale on regen strength (safety/tuning)
        },

        -- ── CORNERING REGEN REDUCTION ──────────────────────────────────────────
        -- Real EVs ramp regen DOWN under lateral load so lifting off mid-corner doesn't
        -- dump weight forward -> understeer / snap-oversteer. Lateral accel is measured as
        -- |yawRate * speed| (v·ω). Below LoG = full regen; LoG..HiG = fade toward MinMult;
        -- above HiG = clamped at MinMult. Smoothed with a short attack/release so it eases
        -- in/out of the bend (no jerk). Crucial for EV composure at the limit.
        CornerRegen = {
            Enabled    = true,
            -- Lateral load = |yawRate*speed| (m/s²) — already turn-radius aware (tighter turn at
            -- a given speed = higher yaw = higher g). Retuned: the old 0.40->0.90g / 0.35 floor
            -- kicked in during NORMAL corners and cut regen so deep it felt like coasting. Now it
            -- only bleeds at genuinely HIGH lateral load and never drops below MinMult (keeps a
            -- clear engine-brake in every corner — only the hardest ones ease it).
            -- NOTE: GTA grip is arcade-high (SF90 fTractionCurveMax 2.5), so lateral-g reads
            -- much higher than real life — normal corners easily exceed 1g. Band pushed up +
            -- floor raised so the cut is subtle: at most a light easing, regen stays dominant.
            LoG        = 1.10,   -- lateral g below this = FULL regen (raised from 0.80 — onset was
                                 -- kicking in during normal corners; now only genuinely hard ones ease)
            HiG        = 1.80,   -- lateral g at/above this = max reduction (only near-limit slides)
            MinMult    = 0.85,   -- regen floor — at most a 15% ease (was 0.80; keeps engine-brake strong)
            AttackTau  = 0.20,   -- s — how fast regen eases DOWN entering a hard corner
            ReleaseTau = 0.30,   -- s — how fast it comes back on exit
        },

        -- ── INSTANT LINEAR TORQUE (the EV "kick") ──────────────────────────────
        -- Real EVs make peak torque from 0 rpm: a hard constant pull off the line that
        -- tapers as it nears top speed. This is a THROTTLE-GATED torque boost, strongest
        -- at low speed, eased to 1.0 by FadeFrac of top speed. Torque-only — never moves
        -- top speed (honours the invariant). Raise PeakMult for a stronger launch punch.
        LinearTorque = {
            Enabled  = true,
            PeakMult = 1.6,    -- low-speed torque multiplier at full throttle (1.0 = off)
            FadeFrac = 0.55,   -- boost fades to none by this fraction of the car's top speed
        },

    },

    -- ── HYBRIDS (full-electric-mode PHEVs: SF90, AMG ONE, E63, …) ───────────────
    -- A hybrid is NOT a pure EV: below a speed cap on light/moderate throttle it runs
    -- silent on the e-motor (capped power, linear, gentle auto-coast — NO regen toggle);
    -- exceed the cap OR floor past the kickdown detent and the ICE auto-engages, handing
    -- the car back to its NORMAL gearbox (DCT/manual/etc.) at full power. Auto-transition,
    -- like a real hybrid — it never refuses, it just wakes the engine.
    -- Detection is a MODEL LIST (GTA can't flag "hybrid in e-mode"); tune the global
    -- profile here or live via /hybridspeedcap.
    Hybrid = {
        Enabled  = true,
        -- MODEL LIST — spawn codes of the carpack's true PHEVs (web-verified). Value = true.
        -- (Yangwang U8 'u8' is meta'd as 1-gear so it detects as a PURE EV, not here.)
        Models   = {
            ['20sf90']     = true,   -- Ferrari SF90 (PHEV, eDrive ~135)
            ['fer296fh5']  = true,   -- Ferrari 296 GTB (PHEV, eDrive ~135)
            ['amgone1']    = true,   -- Mercedes-AMG ONE (F1 hybrid, ~18km EV)
            ['gemera']     = true,   -- Koenigsegg Gemera (PHEV, ~50km EV)
            ['bmwxm']      = true,   -- BMW XM (PHEV SUV, ~140)
            ['ikx3_val25'] = true,   -- Aston Martin Valhalla 2025 (PHEV, front e-drive ~140)
            ['oycrev']     = true,   -- Lamborghini Revuelto 2024 (PHEV, V12 + 3 e-motors, Città mode)
            ['918']        = true,   -- Porsche 918 Spyder (classic strong PHEV, e-mode ~150)
            ['p1']         = true,   -- McLaren P1 (borderline PHEV: real E-mode/IPAS, low practical e-speed)
            ['nsx17']      = true,   -- Acura NSX NC1 2017 (mild hybrid, marginal e-mode — low cap below)
            ['u8']         = true,   -- BYD Yangwang U8 2024 (quad-motor PHEV: ICE assists the EV). Was
                                     -- mis-detecting as a PURE EV off its 1-gear meta — it's a hybrid.
                                     -- ModelProfiles below caps it at 200 (real top) in e-mode.
            -- ['thevalkspdr'] -> reclassified SEMI/KERS (class 2), see SemiHybrid.Models below
        },
        -- PER-MODEL OVERRIDES (spawn code -> { CapKmh=, PowerFrac= }). Anything not listed
        -- uses the global defaults below. Keeps distinct cars distinct without a full system.
        ModelProfiles = {
            ['20sf90']  = { CapKmh = 135.0, PowerFrac = 0.28 },  -- SF90 eDrive ~135 km/h (162 kW front)
            ['fer296fh5']= { CapKmh = 135.0, PowerFrac = 0.24 }, -- 296 GTB eDrive ~135 (123 kW, ~20% system)
            ['amgone1'] = { CapKmh = 100.0, PowerFrac = 0.30 },  -- AMG ONE e-only lower speed, very high e-power
            ['gemera']  = { CapKmh = 150.0, PowerFrac = 0.34 },  -- Gemera very strong e-power (can dominate EV)
            ['bmwxm']   = { CapKmh = 140.0, PowerFrac = 0.25 },  -- XM PHEV SUV ~140
            ['ikx3_val25']= { CapKmh = 140.0, PowerFrac = 0.30 }, -- Valhalla PHEV, front-e-drive ~140 km/h (was 130)
            ['oycrev']  = { CapKmh = 140.0, PowerFrac = 0.30 },  -- Revuelto PHEV, strong front e-axle
            ['918']     = { CapKmh = 150.0, PowerFrac = 0.30 },  -- 918 Spyder ~150 km/h e-mode (210 kW e)
            ['p1']      = { CapKmh = 100.0, PowerFrac = 0.24 },  -- P1 real E-mode but low practical e-speed (132 kW)
            ['nsx17']   = { CapKmh = 30.0,  PowerFrac = 0.18 },  -- NSX 'Quiet mode': creep-only e
            ['u8']      = { CapKmh = 200.0, PowerFrac = 1.00 },  -- Yangwang U8: quad-motor PHEV, real top ~200
                                                                -- km/h, electric-DOMINANT (1197 hp). FULL e-mode
                                                                -- torque (PowerFrac 1.0) — no suppression; it's
                                                                -- the primary drive. Torque hard-cut holds 200.
                                                                -- The 1-gear meta gives NO gear reduction, so the
                                                                -- launch punch relies on fInitialDriveForce (0.52)
                                                                -- + EmodeLaunchMult, not a short 1st gear.
        },
        -- SPEEDO LOOK override (per-model, config FALLBACK — a DB row from /sethybrid arg4 wins).
        -- Decouples the CLUSTER LOOK from the drivetrain class: a full PHEV (class 1) still drives
        -- with its EV mode + HOLD-G + cap, but presents the electric side as a KERS-style charge/
        -- boost arc on the normal tach instead of the full Tesla-style EV split-ring. Matches real
        -- cars: the 918 & P1 have genuine E-mode/IPAS but their clusters read as boost meters, not
        -- EV readouts. Value = 'semi' (KERS look) or 'full' (EV cluster). Unlisted class-1 cars
        -- default to 'full'; class-2 cars are always 'semi'. In e-mode a 'semi'-look PHEV still
        -- shows green 'D' + a green throttle-driven bar; ICE mode shows real revs.
        SpeedoStyle = {
            ['918'] = 'semi',   -- 918 Spyder: real E-Power mode, but cluster reads as a power/boost meter
            ['p1']  = 'semi',   -- McLaren P1: IPAS boost overlay presentation, not an EV readout
        },
        -- GLOBAL e-mode profile (fallback for models without a ModelProfiles entry; also what
        -- /hybridspeedcap sets live):
        CapKmh       = 130.0,  -- e-mode top-speed cap (enforced by a HARD TORQUE CUT above it —
                               -- gears/ratio never cap speed, only torque does)
        PowerFrac    = 0.35,   -- e-mode STEADY torque fraction (raised 0.25->0.35: 0.25 felt gutless)
        -- AUTO-ICE: when true, the car auto-wakes the ICE at the cap / on kickdown (the seamless
        -- handoff). DISABLED for now (false) — hybrid STAYS electric, HARD-CAPPED at CapKmh, and
        -- only switches to the engine when you HOLD-G. Re-enable once the base EV drivetrain is solid.
        AutoICE      = false,
        KickdownThr  = 0.85,   -- (auto-ICE only) flooring past this throttle wakes the ICE below the cap
        HandoffThr   = 0.75,   -- (auto-ICE only) near-cap throttle push that wakes the ICE
        EmodeLaunchMult = 2.2, -- low-speed launch punch × PowerFrac (EV instant torque off the line;
                               -- eases over the first ~55% of the e-speed range). 1.0 = flat.
        EmodeMinMult    = 0.9, -- FLOOR on the e-mode torque multiplier — near-full sustained power
                               -- so the car pulls cleanly to the cap. Raise toward 1.0 for stronger.
        -- SINGLE-GEAR: pin gear 1 + reduced-ratio in e-mode for the one-gear EV FEEL (no shifting).
        -- pins gear 1 + raises fInitialDriveMaxFlatVel so gear 1 becomes a TALL single ratio
        -- that spans 0->cap (real-EV single reduction) — gear 1 keeps full launch torque so it
        -- pulls away AND reaches the cap on one gear. Real top-speed restored on ICE/exit.
        -- The SPEED CAP itself is still the torque hard-cut above (gears don't cap in GTA).
        -- SingleGear was REMOVED: pinning gear 1 hard-caps at gear-1's ceiling (~81), and
        -- raising maxFlatVel does NOT lift a reduced-ratio gear's ceiling (both proven in-game).
        -- GTA's box now SHIFTS in e-mode (reaches the real cap); the cap is the torque hard-cut.
        -- EmodeMinMult keeps power high so GTA upshifts cleanly (no lug). 'EV feel' = hk-speedo
        -- hides the gears in e-mode (visual), not a real single-gear pin.
        -- Hysteresis so the e-mode<->ICE boundary doesn't flip-flop:
        ResumeKmh    = 110.0,  -- must drop below this (also clamped to cap-20 for hysteresis)
        ResumeThr    = 0.50,   -- ...and throttle must be UNDER this to resume e-mode (real
                               -- hysteresis: prevents the e<->ICE ping-pong / restart-spam)
        -- REGEN (hybrids) — a SINGLE fixed level (no D1/D2/D3 selector; that's a pure-EV-only
        -- feature so pure EVs stand out). Applies in BOTH e-mode AND ICE/hybrid mode (realistic:
        -- the e-motors regen on lift either way), giving hybrids a 'semi one-pedal' feel incl. a
        -- stop-hold. Set to D3 strength — hybrids are fast cars that want strong engine braking.
        RegenDecelG   = 0.28,  -- lift-off deceleration (g) — ABOVE D3 (0.21) so the hybrid engine-
                               -- brake is clearly felt (fast heavy cars want strong regen). Dial 0.21-0.35.
        RegenLift     = 0.10,  -- throttle below this = regen engages (= "lifted")
        RegenHoldKmh  = 8.0,   -- below this: switch from decel to a brake HOLD (semi one-pedal)
        RegenHold     = 0.55,  -- brake pressure (0..1) that holds the car stopped
        -- HYBRID cornering-regen reduction — SEPARATE from the pure-EV CornerRegen so hybrids
        -- (fast cars) keep MORE engine braking in corners. Higher band + higher floor = barely
        -- eased even when leaning hard. Set Enabled=false to never reduce hybrid regen in corners.
        CornerRegen = {
            Enabled = true,
            LoG     = 1.00,    -- full regen below 1.0g lateral (most cornering untouched)
            HiG     = 1.80,    -- max reduction only near the grip limit
            MinMult = 0.75,    -- floor: at most a 25% ease (was 0.85/15% — braked a touch too much
                               -- in corners, so regen now backs off a little more when turning)
            AttackTau = 0.20,
            ReleaseTau = 0.30,
        },
        -- ENGINE START/STOP SOUND: the real-ignition CYCLE approach was REMOVED (GTA's crank
        -- has a ~1s delay that desynced from the mode change, the shutdown cut power, and it
        -- restart-spammed near the cap). The e-mode audio-BANK swap (EVAudio below) is now the
        -- sole transition cue — clean, no engine cycling. A safe canned one-shot could be added
        -- later via a dedicated custom soundset.
        -- DRIVER MODE — HOLD G toggles between TWO modes only (kept simple):
        --   'ev'     = electric: capped power, 1-gear smooth, coast regen, EV ENGINE SOUND,
        --              engine STAYS RUNNING (simulation — never cuts, so the speedo/control
        --              never drop). Still auto-wakes to full power at the cap (SF90 handoff).
        --   'normal' = the car's normal ICE/auto behaviour at full power (audio restored).
        DefaultUserMode = 'ev',   -- hybrids start electric (silent show-off pull-away)
        -- EV-mode engine SOUND. GTA can't runtime-flip the electric FLAG, but ForceVehicleEngineAudio
        -- can swap the engine sound. 'NEON' is GTA's electric-car audio — the SAME sound the Plaid
        -- uses (its meta audioNameHash is NEON). Set to a custom EV audio name if you add one.
        -- NOTE: swapping the audio bank causes a brief engine-audio re-init ("stumble") on the
        -- change — inherent to the native. Set EVAudioEnabled=false to skip the swap entirely
        -- (no stumble; the hybrid just runs its normal engine, quieter at low e-power).
        EVAudioEnabled = true,
        EVAudio      = 'NEON',
        -- EV→ICE VOLUME RE-PRIME (2026-08-14 v2). When ForceVehicleEngineAudio(veh,'') restores the
        -- stock engine coming BACK from EV mode, GTA's engine note comes back DIMMED (low volume)
        -- and only reaches full loudness at the NEXT gear change — the audio engine needs a gear
        -- EVENT to re-level. So on the e-mode->ICE edge we fire ONE REAL single shift inside the DCT
        -- branch (requestGear — the box honours it, unlike a phantom bump that the per-frame gear
        -- write nullified). Direction is chosen by rpm so it ALWAYS shifts once but NEVER bogs or
        -- over-revs: rpm above the engage-target band -> UPSHIFT one (rpm drops); below -> DOWNSHIFT
        -- one (rpm rises). The destination gear's projected rpm is checked against [Min,Max]; if
        -- unsafe it tries the other direction, skipping only if neither is safe. false = disable.
        EVReprimeShift = true,
        EVReprimeMinRpm = 0.30,   -- destination-gear projected rpm below this = bog risk -> reject that dir
        EVReprimeMaxRpm = 0.90,   -- destination-gear projected rpm above this = over-rev risk -> reject that dir

        -- ── SEMI / KERS HYBRID (class 2) ─────────────────────────────────────────
        -- A DIFFERENT hybrid class from the full PHEV above: the semi-hybrid has an
        -- actual e-motor but NO standalone electric drive mode — the ICE ALWAYS runs.
        -- The e-motor gives regen-on-lift (recover energy) + an ALWAYS-ON torque FILL
        -- blended into the engine's power (KERS). Think 918 Spyder / P1 / LaFerrari,
        -- or a mild-hybrid Benz with a small e-boost. HOLD-G does NOT toggle a mode
        -- (there's no EV mode to switch to) — it's just a faster ICE car with e-assist.
        -- A car becomes semi-hybrid via `/sethybrid semi [boostMult]` (DB-persisted,
        -- per model) — this block only holds the DEFAULTS when no per-car value is set.
        SemiHybrid = {
            Enabled   = true,
            -- CONFIG MODEL LIST (class-2 default for cars with no /sethybrid DB row). Same fallback
            -- pattern as Hybrid.Models above but for SEMI/KERS: ICE always runs, e-motor gives
            -- regen-on-lift + an always-on torque FILL — NO standalone EV mode, HOLD-G does nothing.
            -- Value = per-car BoostMult (the always-on fill ×). Scale it to the car's REAL e-assist
            -- power: a big KERS (Valkyrie/LaFerrari ~120 kW) fills hard; a 48V mild-hybrid (Sián
            -- 25 kW / RS7 12 kW) barely nudges. A DB row from /sethybrid still overrides this.
            Models = {
                ['thevalkspdr'] = 1.16,  -- Aston Valkyrie Spyder — F1-style KERS (~120 kW), strong fill
                ['aperta70']    = 1.16,  -- LaFerrari Aperta 70th — HY-KERS (120 kW), strong boost-fill
                ['dzsian']      = 1.05,  -- Lamborghini Sián — 48V supercap, 25 kW: small peak fill only
                ['rs721']       = 1.03,  -- Audi RS7 C8 — 48V mild hybrid, ~12 kW: minimal continuous assist
            },
            -- Always-on torque MULTIPLIER blended into ICE power while on throttle. The
            -- e-motor fills torque everywhere; strongest low-down (electric instant
            -- torque), easing toward 1.0 up top. Per-car override = /sethybrid semi <mult>.
            BoostMult = 1.10,   -- default fill at full assist (×1.10 = +10%). Per-car via evTorque.
            BoostFadeFrac = 0.60, -- e-assist fully faded to 1.0 by this fraction of top speed
                                  -- (electric torque tapers as speed builds, like a real KERS fill)
            BoostThrottle = 0.05, -- only assist when on the gas past this (no fill while coasting)
            -- REGEN on lift — the semi-hybrid recovers energy like the full PHEV. Reuses the
            -- Hybrid regen actuator (velocity-bleed + stop-hold). Slightly softer default than
            -- the full PHEV's 0.28 (semis are often lighter e-systems) — tune to taste.
            RegenDecelG  = 0.22,  -- lift-off decel (g). Dial 0.15-0.30.
            RegenLift    = 0.10,  -- throttle below this = regen engages
            RegenHoldKmh = 8.0,   -- below this: brake HOLD (semi one-pedal)
            RegenHold    = 0.50,  -- brake pressure that holds it stopped
            UseHybridCornerRegen = true,  -- reuse Hybrid.CornerRegen easing in corners
        },
    },

    -- ── REGEN BRAKE-LIGHT THRESHOLD ────────────────────────────────────────────
    -- Real EVs/hybrids (Tesla, Taycan, etc.) do NOT light the brake lights for light
    -- regen — regulation (UN ECE R13-H) only requires them once decel passes ~1.3 m/s²
    -- (~0.13g). So a gentle lift coasts DARK, and the lights only come on once regen is
    -- braking HARD, or the driver actually presses the brake pedal. This applies to ALL
    -- e-braking cars (pure EV, full PHEV, semi/KERS) via the shared regen actuator.
    RegenBrakeLight = {
        Enabled    = true,     -- false = old behaviour (lights on for ANY active regen)
        OnMs2      = 1.3,      -- regen decel (m/s²) at/above which the lights turn ON
                               -- (1.3 m/s² ≈ 0.13g = the real regulatory threshold).
        OffMs2     = 0.7,      -- and turn back OFF below this (UN ECE R13-H: the lamps MUST be
                               -- off below 0.7 m/s² — that's the regulatory de-activation point,
                               -- and it doubles as the hysteresis floor so they don't flicker).
        PedalAlways = true,    -- the FOOT brake pedal always lights them, regardless of
                               -- the regen decel (a real brake press is never suppressed).
        PedalThreshold = 0.06, -- pedal input (0..1) above which "the driver is braking".
        HoldLit    = true,     -- keep them lit during the stop-HOLD phase (car is being
                               -- actively held stopped = a real brake-light situation).
        RampUpMs   = 1300,     -- regen SPOOL-UP time (ms): decel eases 0 -> full over this on each
                               -- lift, instead of slamming to target on frame 1. This is the real
                               -- motor torque build — a Tesla takes ~0.5-1.5s of lift before regen
                               -- is at full strength, so the lamp only crosses OnMs2 well into the
                               -- lift. RAISE this for a later light / longer dark coast; LOWER for
                               -- an earlier one; 0 = instant full regen (light comes up at once).
        -- SPEED-DEPENDENT DECEL (power-limited motor law): the brake-light THRESHOLD is fixed
        -- (speed-independent, per UN ECE R13-H), but the decel a lift PRODUCES is not — a motor is
        -- power-capped (P = torque × speed), so the same lift makes milder decel at high speed. So
        -- the light comes on readily in the city, but needs a harder lift (or never) on the highway.
        SpeedFalloff = {
            Enabled = true,    -- false = flat constant-g regen at all speeds (light timing won't vary)
            BaseKmh = 50.0,    -- full regen torque up to here; above it torque falls ~ BaseKmh/speed.
                               -- So at 100 km/h decel is ~half of city strength = a later/no light.
            MinMult = 0.45,    -- floor so highway regen never fully vanishes (0.45 = 45% of full).
        },
    },

    -- COMFORT AUTO (mode 0) coast neutral: hold BOTH shift keys for a momentary neutral
    -- (drive cut + free-rev). Release hands the gear straight back to GTA. Pure coast
    -- button — comfort auto otherwise ignores the shift keys entirely. false = disable.
    AutoNeutralGesture = true,

    -- NORMAL LEARNER — background 0-100 calibration (Mode='normal' only).
    -- Phase A: first clean WOT pull runs GTA-native (box suspended), stores baseline.
    -- Phase B: subsequent pulls run with box, compute f = fApplied * T_ours / T_native.
    NormalLearn = {
        Enabled       = true,
        StartKmh      = 2.0,
        EndKmh        = 100.0,
        MidKmh        = 60.0,
        MinThrottle   = 0.92,
        StartThrottle = 0.95,
        BrakeMax      = 0.05,
        MaxSteer      = 0.35,
        MaxLiftMs     = 100,
        RequireStock  = true,
        MaxGrade      = 0.025,
        MinT100       = 1.2,
        MaxT100       = 40.0,
        MinRunGapMs   = 1500,
        TrimMin       = 0.94,
        TrimMax       = 1.08,
        CandRejectMin = 0.91,
        CandRejectMax = 1.11,
        -- Blend weight for the 60-100 segment vs full 0-100 when computing the
        -- trim candidate. 1.0 = pure 60-100 (ignore launch), 0.0 = pure 0-100,
        -- 0.7 = 70% segment / 30% full (default — favours top-end accuracy).
        SegWeight     = 0.7,
        MedianWindow  = 7,
        FirstAlpha    = 0.65,
        NormalAlpha   = 0.18,
        FirstMaxStep  = 0.08,
        NormalMaxStep = 0.025,
        Deadband      = 0.004,
        Debug         = false,
    },

    -- DETECTION. Post-migration the gearbox is resolved purely from the
    -- hk_handling DB table + the car-class default (see resolvePublicType in
    -- client/gearbox.lua). The old handling-flag triggers below are REMOVED —
    -- reading strHandlingFlags 0x1000000 / strAdvancedFlags 0x400 at runtime was
    -- unreliable (0/throws on many addon cars) and is no longer consulted.
    DefaultManualModels    = {},     -- model-hash list forced manual (+ statebag hk_manual)
    UseModTrigger          = false,  -- T3: transmission upgrade (mod slot 13). Off this phase
                                     -- (jim/mod has no effect on resolution until PHASE 1.5).

    -- JIM-MECHANIC INTEGRATION (fully OPTIONAL). hk-handling is standalone — the
    -- box resolves from the hk_handling DB table + the car-class default with NO
    -- jim installed. jim is only ever an EXTRA trigger, never a dependency.
    -- Turn Jim.Enabled OFF and the jim event bridge (vlad_gears:*) is not
    -- registered and jim is never consulted; the box runs purely on DB + default.
    Jim = {
        Enabled = true,              -- master switch for ALL jim-mechanic integration

        -- UPGRADE MAP (PHASE 1.5). When jim reports its gearbox upgrade on a car
        -- (jim's per-vehicle status.manual == 1, OR a legacy vlad_gears:activate
        -- event), the car's BASE gearbox is remapped per the table below. The base
        -- is whatever the car resolves to WITHOUT the upgrade (DB row / car-class
        -- default). Keys = PUBLIC base type; each entry is { type=, ratio= }:
        --   type  = the PUBLIC gearbox type the upgrade promotes the car TO.
        --   ratio = the gear-ratio mode (0-3) the upgrade GRANTS — but ONLY when the
        --           car is sitting at the DEFAULT ratio [0]. nil = do not touch ratio.
        -- A base type with NO entry (e.g. 6) is LOCKED: the upgrade does nothing.
        --
        -- EXISTING-RATIO RULE (the "IF the vehicle already has a /gearratio" clause):
        -- if the car ALREADY has an admin-set ratio (base ratio ~= 0), the admin
        -- value WINS over the entry's `ratio`, and is advanced per UpgradeRatioProgression
        -- below instead. So a model an admin tuned to Drag[2] keeps Drag, never gets
        -- overwritten by the upgrade's listed ratio. The entry's `ratio` only applies
        -- to a car still on the default [0].
        UpgradeMap = {
            [0] = { type = 2 },              -- AUTO        -> BASIC DCT      (ratio untouched)
            [1] = { type = 5 },              -- MANUAL      -> SEQUENTIAL DOG (ratio untouched)
            [2] = { type = 3, ratio = 1 },   -- BASIC DCT   -> SPORT DCT  + /gearratio 1 (Sport)
            [3] = { type = 4, ratio = 1 },   -- SPORT DCT   -> SUPER DCT  + /gearratio 1 (Sport)
            [4] = { type = 4, ratio = 3 },   -- SUPER DCT   -> SUPER DCT  + /gearratio 3 (Hyper)
            [5] = { type = 1, ratio = 2 },   -- SEQUENTIAL  -> CLASSIC MANUAL + /gearratio 2 (Drag)
            -- [6] GTA NATIVE: no entry = LOCKED (stays raw GTA even with the upgrade).
        },

        -- EXISTING-RATIO PROGRESSION. Used ONLY when an upgraded car already had an
        -- admin-set ratio (base ratio ~= 0). The admin's value is advanced through
        -- this table instead of being overwritten by the UpgradeMap entry's ratio:
        --   [1] Sport -> [3] Hyper   (a sport-tuned car steps up to hypercar feel)
        --   [2] Drag  -> [2] Drag    (no change)
        --   [3] Hyper -> [3] Hyper   (no change — already the top)
        -- A ratio not in this table is left as-is.
        UpgradeRatioProgression = {
            [1] = 3,
            [2] = 2,
            [3] = 3,
        },
    },


    -- GEARBOX MODES — PUBLIC numbering (hk_handling.manualType -> label). This is
    -- what the DB, /setgear, and the docs use. The CLIENT translates these to
    -- its FROZEN internal engine numbers in detectMode() (see PUBLIC_TO_INTERNAL).
    -- Adding a mode = a row here + a translation entry; no DB migration (TINYINT).
    --   0 = our automatic (DEFAULT; overrides GTA native). No row on a car-class
    --       vehicle also resolves here.
    --   6 = GTA-native automatic — DEBUG ONLY (script does not process the car).
    ModeLabels = {
        [0] = 'NEW automatic',          -- our comfort automatic; the default for car classes
        [1] = 'Classic H pattern Manual',-- classic H-pattern manual + clutch
        [2] = 'Automatic (Paddle)',     -- torque-converter automatic WITH paddle override (repurposed
                                        -- from the old "Basic DCT"). Runs on the internal DCT engine
                                        -- (mode 3) for paddle+auto, but retuned to a TC FEEL — see
                                        -- Config.Gearbox.TcFeel + DctProfiles[3]. Elastic rpm, load-
                                        -- variable shift firmness, throttle-gated kick. Perf-neutral.
        [3] = 'Sport DCT',              -- internal supercar-DCT profile (DctProfiles[4])
        [4] = 'Super DCT',              -- internal F1/hypercar-DCT profile (DctProfiles[5]); lock paddle-only per model via forcePaddle
        [5] = 'Sequential Dogbox',      -- hybrid sequential (dog upshift + synchro double-clutch downshift)
        [6] = 'GTA Native default automatic', -- raw GTA automatic, DEBUG ONLY — not processed by the script
    },


    -- SHIFT FEEL
    -- Clutch/neutral rev-raise RATE (per second, framerate-independent).
    -- A naive per-frame increment at ~1000Hz becomes ~16x faster at 60fps,
    -- which is why an unscaled port felt sluggish. This is
    -- the effective rev climb rate while declutched — raise for snappier revs.
    RevRaiseRate = 22.0,
    -- UPSHIFT REV-DROP ASSIST — the "engine brake on upshift" feel, done right.
    -- On an upshift the new (taller) gear wants LOWER revs at the same road speed, and
    -- GTA's own engine won't drop rpm fast enough on its own (worst at high speed), so
    -- the gear engaged off-rpm and felt gutless. During the upshift window (drive is
    -- already cut, car coasting) we WRITE the rpm DOWN toward the new gear's target,
    -- computed from the seeded/learned ratio (gbRpmPerSpeed). Direct rpm authority
    -- (reliable) — NOT torque-cut "engine brake" physics (slow/vague) or a blocking
    -- Wait (breaks the per-frame tick).
    --
    -- KEY: this is a fixed-rate ASSIST, NOT a snap-to-target. It pulls rpm down as far
    -- as the window allows but NEVER below the target (can't lug) and NEVER snaps to it.
    -- So a sensible-rpm upshift gets closed into the match window -> clean; a REDLINE
    -- upshift has too big a gap for the limited drop to close -> lands ABOVE the window
    -- -> sequential bounces (dogs clash), manual engages honestly. The drop STRENGTH is
    -- the skill/forgiveness knob: higher = more forgiving, lower = mis-shift easier.
    UpshiftRevDrop      = true,      -- enable the rev-drop assist during an upshift window
    UpshiftRevDropPerS  = 6.0,       -- rpm units/sec the assist pulls down (0..1 rpm scale). Sequential's
                                     -- 60ms window drops ~0.36 rpm; enough to visually smooth the transition
                                     -- from current-gear redline into the new gear's band. Higher = snappier.
    -- NEUTRAL rev-feed (no gear engaged -> revs climb freely to redline). Manual is
    -- RAW (slams to max almost instantly); DCT is ECU-limited (a capped climb rate,
    -- protected like a real DCT mechatronics). Both feed toward redline, not idle.
    NeutralRevRateManual = 105.0,    -- manual neutral: very fast (raw blip to max); -12% from 120 (was ramping a touch fast)
    NeutralRevRateDct    = 45.0,     -- DCT neutral: rev-climb rate (RAISED 31->45 so neutral revs
                                     -- climb higher/faster and reach the target snappily — the
                                     -- 'make neutral rev go higher' fix; also serves launch build-up)
    NeutralRevMax        = 1.0,      -- redline target when STATIONARY/idle in neutral (free-rev to max — show off)
    NeutralRevMaxMoving  = 0.90,     -- rev cap when MOVING in neutral (raised 0.80->0.90; less restrictive)
    NeutralRevCapKmh     = 8.0,      -- above this speed the moving cap applies; below (idle/crawl) = full redline

    -- REVERSE GEAR rev-feed (2026-08-14 rework). Reverse is a real gear driven by W now, but the drive
    -- frame doesn't paint rpm (it rode native wheelspeed = flat, since ReverseCap holds the car slow).
    -- So paint it here: a SHORT low reverse gear that revs SLOWLY toward a modest ceiling as you hold W.
    ReverseRevMax        = 0.55,     -- rpm ceiling in reverse at full W (short reverse gearing tops out low)
    ReverseRevRaiseRate  = 4.0,      -- how fast rpm climbs toward the W-scaled target (LOWER = slower, more real)
    ReverseRevFallRate   = 6.0,      -- how fast rpm falls back to idle on lift (engine-brake decay)

    -- ============================================================= FLYWHEEL SIMULATION (2026-08-16)
    -- Auto-detected per-car flywheel model. NO per-car flags. fDriveInertia turned out to be a DEAD
    -- signal (1.0 .meta default on nearly every car), so the mass is derived from signals that DO vary:
    -- vehicle mass (fMass) and engine power (fInitialDriveForce). specific = (mass/RefMass)/(force/RefForce);
    -- flyMass = specific ^ MassGamma, clamped MassMin..MassMax. A LIGHT+POWERFUL car (supercar) -> flyMass
    -- < 1 (light flywheel: snappy rev, fast drop); a HEAVY+WEAK car (truck/sedan) -> > 1 (heavy: lazy rev,
    -- long rev-hang). A car that actually TUNED fDriveInertia away from 1.0 overrides the mass path
    -- (InertiaOverrideEps). PHASE A (perf-neutral): the free-rev needle in neutral / clutch-in / mid-shift
    -- feeds through HK.flywheelRev — a mass-scaled ASYMMETRIC integrator (rev-up quicker than rev-down;
    -- both scaled by mass) so blips have weight and lifts hang+decay instead of GTA snapping rpm. Painted
    -- via vl_setRpmRaw (zero force), de-biased through HK.rpmPaintBias so the limiter/shift gates read TRUE
    -- physics rpm (the Chiron-regression guard). PHASE B (engine braking via a live fDriveInertia nudge on
    -- lift/brake) is gated separately — see EngineBraking below.
    Flywheel = {
        Enabled          = true,
        -- MASS/POWER signal (the real per-car spread):
        RefMass          = 1600.0, -- ~mid-roster fMass that maps to specific 1.0
        RefForce         = 0.30,   -- ~mid-roster fInitialDriveForce that maps to specific 1.0
        MassGamma        = 0.6,    -- <1 compresses the spread so extremes (a 900kg hypercar, a 4t truck) stay sane
        -- fDriveInertia OVERRIDE (only when a car genuinely tuned it):
        ReferenceInertia = 1.0,   -- di that maps to flyMass 1.0 on the override path
        InertiaOverrideEps = 0.15,-- |di - 1.0| beyond this = car tuned it on purpose -> use di, not mass/power
        -- clamps + rev rates:
        MassMin          = 0.6,   -- lightest allowed flywheel (snappiest rev)
        MassMax          = 1.8,   -- heaviest allowed flywheel (laziest rev / longest hang)
        RevUpRate        = 9.0,   -- base rev-UP ease rate (per s) at flyMass 1.0; divided by mass (heavy=slower)
        DownRatio        = 0.45,  -- rev-DOWN rate as a fraction of up (0.45 = lift hangs ~2.2x longer than a blip climbs)
        NeutralDownRatio = 0.32,  -- SLOWER rev-DOWN just for NEUTRAL free-rev lift (< DownRatio = coasts down a bit slower); shifts unaffected
        IdleRpm          = 0.20,  -- normalised idle the free engine decays TO on a full lift (not zero)
        -- PHASE B — ENGINE BRAKING (live fDriveInertia nudge; perf-adjacent, default OFF until Phase A
        -- feels right). On a throttle lift (and the lift->brake handoff) we nudge fDriveInertia so GTA's
        -- OWN engine braking scales with flywheel weight: a LIGHT flywheel slows the car more on a lift
        -- (race-car engine braking), a HEAVY one coasts further. Single-writer, restored on re-throttle.
        -- EV/hybrid regen will hook this same load-aware seam later (shares the velocity-bleed actuator).
        EngineBraking = {
            Enabled       = true,   -- Phase B LIVE (flywheel-scaled engine braking on lift/coast)
            LiftThrottle  = 0.10,   -- throttle below this = "off power" (engine-braking regime)
            MaxNudge      = 0.35,   -- max fractional fDriveInertia change at full effect (light flywheel)
            RampMs        = 250,    -- ease the nudge in/out so it doesn't step decel on lift/re-throttle
            MinKmh        = 8.0,    -- below this speed the nudge is off (no crawl/stall engine-braking)
            BrakeBlend    = 0.5,    -- extra engine-braking commitment blended in on the lift->brake handoff
        },
    },

    ShiftWithClutchMult  = 0.42,     -- with-clutch shift time scale (lower = clutch re-engages FASTER after a
                                     -- shift; was 0.62, shortened — clutch was lingering too long on release)
    ClutchOnly           = false,    -- require clutch held to accept a shift

    -- DCT AUTO START (modes 2/3/4 only): when you enter a car whose engine was OFF,
    -- the auto DCT begins in NEUTRAL and waits for a HANDBRAKE (spacebar) tap before
    -- engaging a gear — the "release park" feel. true (default) = require the tap;
    -- false = engage a safe gear immediately on entry (just drive off, no spacebar).
    -- Does NOT affect comfort auto [0] (it always drives off), nor manual/sequential
    -- (those pull away on clutch + shift). Only the DCT auto sub-mode reads this.
    DctAutoStartInNeutral  = true,
    -- DCT INIT SPEED-SANITY (the "spawned in 7th, drops slowly" bug): below this speed
    -- (km/h) the DCT init MUST start in 1st. If you HOLD accelerate while getting in
    -- before our box takes over, GTA's native auto floats the car to top gear and our
    -- init would otherwise trust that floated gear. A crawling car can only be in 1st.
    DctInitSlowKmh         = 30.0,
    -- Auto-DCT park-neutral RELEASE: throttle fraction (0..1) that pulls the box
    -- out of the start/park neutral. Press the gas past this and it engages a safe
    -- gear and drives off (replaces the old handbrake tap). Only the DCT auto
    -- sub-mode reads this; the both-shift-key neutral gesture is unaffected.
    DctReleaseThrottle     = 0.15,

    -- PROGRESSIVE AUTO-DOWNSHIFT (real-auto feel): the downshift rpm threshold scales with
    -- throttle between the keep-alive floor (AutoDownRpm, per-profile) at light pedal and the
    -- full kickdown rpm (AutoKickdownRpm) at WOT. Below DownProgLo = cruise (floor only, no
    -- part-throttle hunting); at/above DownProgHi = full eager kickdown. The bounce guard still
    -- blocks any drop that would instantly re-upshift, so this can't hunt. Raise DownProgLo if a
    -- car downshifts too eagerly at light throttle; lower DownProgHi for earlier kickdown.
    DownProgLo             = 0.15,   -- throttle below this = downshift at the idle floor only
    DownProgHi             = 0.90,   -- throttle at/above this = full kickdown rpm (old behavior)
    -- STALL-TIMEOUT UPSHIFT (2026-08-16) — fixes the "hangs a few seconds in gears 5-8 before it'll
    -- upshift" on tall-geared / hold-longer cars (confirmed on the chipped 911ts: rpm sat at 0.89
    -- under a 0.97 up-point at WOT for seconds because the pull flattens near the top of the gear).
    -- A real DCT never sits pinned mid-gear: if you're at WOT, not in the top gear, high in the band
    -- (within StallUpRpmBand of the up-point), and rpm has STOPPED climbing for StallUpMs, take the
    -- shift anyway. Tight-gated so a normal quick pull (reaches the up-point first) is unaffected, and
    -- part-throttle lugging stays the downshift's job. Set StallUpMs=0 to disable entirely.
    StallUpMs              = 800,    -- ms rpm may sit stalled just below the up-point at WOT before we shift
    StallUpThr             = 0.85,   -- only when throttle is at/above this (WOT-ish; not part-throttle)
    StallUpRpmBand         = 0.10,   -- "high in the band" = within this much rpm of the up-point
    -- COAST DOWNSHIFT CHARACTER (2026-08-14) — a TC auto and a DCT behave DIFFERENTLY when you
    -- lift off and coast. A torque-converter auto is LAZY: it holds the tall gear for smoothness/
    -- economy and only drops as rpm nears lugging (little engine braking). A DCT is EAGER: it
    -- pre-selects the lower gear and drops sooner, giving noticeable engine braking on a lift
    -- (the sporty "car slows when you lift" feel, partner to the brake multi-downshift). We shift
    -- the coast downshift threshold (only while coasting: throttle < CoastLiftThr) by these deltas
    -- off the per-profile AutoDownRpm floor. TC negative = holds LONGER (drops later, lower rpm);
    -- DCT positive = drops SOONER (higher rpm = keeps revs up for engine braking). The bounce
    -- guard still vets every drop so neither can hunt. Set both 0 to restore the old single behavior.
    -- NOTE: only the SCRIPT-driven autos (mode 3 TC / modes 4-5 DCT) read these. Comfort mode 2
    -- (public type 0) lets GTA's own gearbox shift, so it's unaffected — it already glides lazily.
    CoastDownBiasTc        = -0.05,  -- TC (mode 3 Automatic Paddle): lazier — hold the tall gear, glide
    CoastDownBiasDct       = 0.10,   -- DCT (modes 4/5 Sport/Super): eager — drop sooner for engine braking
    -- BRAKE DOWNSHIFT CHARACTER (2026-08-14) — real autos/DCTs downshift on the FOOT BRAKE to add
    -- engine braking and stay in a ready-to-launch gear ("brake-based downshifting"). We RAISE the
    -- downshift rpm threshold in proportion to brake pressure, so the box drops gears earlier the
    -- harder you brake — TC gently (slushbox stays smooth), DCT aggressively (pre-selected lower
    -- gear, sharp). Scales from 0 at BrakeDownGate up to the full bias at full brake. Only off the
    -- throttle (a trail-braked throttle blend still reads throttle for the kickdown map). The bounce
    -- + over-rev guards still vet every drop, and the DCT multi-down dwell makes the cascade rapid.
    -- Perf-neutral: braking is off-throttle, never touches WOT accel. HANDBRAKE is NOT included —
    -- a real e-brake is decoupled from the gearbox, so it commands no shift (handled separately).
    BrakeDownGate          = 0.15,   -- brake below this = no brake-linked downshift (light drag)
    BrakeDownBiasTc        = 0.10,   -- TC: gentle extra eagerness under braking (drops ~1 gear sooner hard)
    BrakeDownBiasDct       = 0.28,   -- DCT: aggressive — bangs down the box under hard braking
    -- DOWNSHIFT ANTI-HUNT HYSTERESIS: block a kickdown if the TARGET gear would land within
    -- this much (normalised rpm) of its OWN upshift point. Without a margin (zero-gap test) a
    -- target landing just below its up-point passed, then at WOT the rpm closed the gap and
    -- re-upshifted instantly = the ~190-210 km/h 2<->3 "bop" on wide-ladder hypercars. This is
    -- the downshift twin of the upshift guard's +0.06 margin. Raise if a car still hunts on a
    -- kickdown; lower if legitimate overtake downshifts feel blocked (too reluctant to drop).
    DownBounceMargin       = 0.10,
    -- TIP-IN MARGIN (2026-08-16 REWORK — the "coast to just-above-drop-rpm then throttle = bog/bop
    -- stuck in the SAME gear, drops a beat later" bug). The earlier attempt WIDENED the bounce margin
    -- on a tip-in, which was BACKWARDS: a wider margin BLOCKS the downshift, so the box lugs the tall
    -- gear (the bog) until road speed drops enough to clear even the wide margin — exactly the "stuck
    -- in 4, then 3, then 4" hunt. FIX: on a lazy tip-in be EAGER to drop — use a NARROW margin so the
    -- requested downshift actually fires. Runaway is still prevented by the hard over-rev guard
    -- (proj <= OverrevRpm) and the post-shift dwell (AutoDwellMs), which hold the dropped gear long
    -- enough that the follow-up upshift is clean. Heavy pedal (>= TipInThrMax) = real kickdown, base
    -- margin. Lower TipInBounceMargin toward 0 if a bog still shows; raise it if a tip-in drop hunts.
    TipInBounceMargin      = 0.04,   -- NARROW margin on a lazy tip-in = let the drop happen (was 0.22 = caused the bog)
    TipInThrMax            = 0.80,   -- pedal at/above this = real kickdown (use base margin)
    -- TIP-IN BOG AUTO-LIFT (2026-08-16 — the user's spec). The bog is an rpm OSCILLATION in a STUCK
    -- gear: the box wants to drop but the target gear is blocked, so rpm climbs, the blocked drop bleeds
    -- it back (a "bog-back"), it climbs again, bleeds again — never shifting. We don't touch the shift
    -- math; we WATCH the needle. Count bog-backs (rpm rises then falls past TipInBogBand) while on-power
    -- (throttle >= TipInBogThr) in a FIXED gear. On the TipInBogCount-th bog-back (2nd), release throttle
    -- for TipInBogLiftMs so rpm drops off the target gear's up-point and the downshift slots in clean;
    -- release auto-ends when the gear changes, then held throttle passes through again. AUTOMATIC only
    -- (manual/sequential excluded). Set TipInBogLiftMs = 0 to disable the whole thing.
    TipInBogCount          = 2,      -- release after this many bog-backs (the "twice" the user described)
    TipInBogBand           = 0.03,   -- rpm must fall this far after a climb to count one bog-back (hysteresis)
    TipInBogThr            = 0.30,   -- only watch while throttle is at/above this (a genuine on-power tip-in)
    TipInBogLiftMs         = 220,    -- length of the auto-lift after the 2nd bog-back. Raise if bog persists.
    -- 2026-08-16: the lift is now a PARTIAL throttle, not a full cut. TipInBogLiftFrac holds torque at
    -- this fraction during the window (0.22 = 22%) so the box downshifts without the sudden dead-engine
    -- silence + rpm rampthrough of the old full-0 kill. TipInBogDownWindowMs gates the WHOLE detector to
    -- only arm while the box has recently WANTED a downshift (rpm < the progressive drop threshold) — so
    -- an rpm oscillation up near an UPSHIFT point (WOT limiter bounce) can no longer misfire the lift.
    TipInBogLiftFrac       = 0.22,
    TipInBogDownWindowMs   = 250,

    -- LIFT-OFF UPSHIFT (the "coast-up" fix, 2026-08-14). When you LIFT OFF the throttle at
    -- speed, engine rpm can still sit above the part-throttle up-point (AutoUpRpm) in the
    -- CURRENT gear, so the auto kept upshifting — and because the bounce guard evaluated the
    -- next gear at the (near-zero) CURRENT throttle, the downshift threshold collapsed to the
    -- idle floor and almost any gear passed => a 4->6->7 CASCADE on lift, which then kicked
    -- straight back down the instant you squeezed the pedal (that gear could never hold power).
    -- FIX: while coasting (throttle < CoastLiftThr) the upshift guard evaluates the target gear
    -- against a RESUME throttle (CoastResumeThr) — "could I hold this gear when I get back on
    -- the power?" — instead of the current ~0. That kills the multi-gear overshoot + the
    -- snap-back. CoastUpMaxStep caps how many gears a lift can climb (1 = a single gentle
    -- coast-up, real TC economy behavior). DCT tiers can HOLD the gear on lift instead (engine
    -- braking, the sportier dual-clutch feel) via CoastUpMaxStepDct = 0.
    CoastLiftThr           = 0.12,   -- throttle below this = "coasting" (lift-off logic engages)
    CoastResumeThr         = 0.55,   -- assumed resume pedal — target gear must hold rpm at THIS load
    CoastUpMaxStep         = 1,      -- TC/comfort: at most ONE gear of coast-up per lift (no cascade)
    CoastUpMaxStepDct      = 0,      -- DCT tiers 4/5: HOLD the gear on lift (0 = no coast-up, engine-brake)

    -- AIRBORNE UPSHIFT BLOCK (2026-08-14 — the "+1 gear on landing off a ramp" fix). While
    -- airborne the driven wheels free-spin (no load), rpm pins at the limiter and the
    -- limiter-bypass fires a phantom upshift around touchdown = you land a gear too tall. The
    -- script-auto (modes 3/4/5) suspends UPSHIFTS while off all wheels AND for this settle
    -- window after landing (free-spun rpm is stale until the tyres regrip). Raise if a hard
    -- landing still bumps a gear; lower if a shift feels delayed after a small jump.
    AirLandSettleMs        = 260,

    -- NEUTRAL (no dedicated key) — hold BOTH shift keys together.
    NeutralReengage1stKmh  = 12.0,   -- DCT: leaving neutral below this speed engages 1st; above it uses the
                                     -- automatic safe-gear pick (bestGearForSpeed) so it never over-revs at speed.
    NeutralChordMs         = 40,     -- lone shift press waits this long before becoming a real shift, so the
                                     -- keys of the neutral gesture don't each fire a stray shift first.
    NeutralDoubleTapMs     = 250,    -- NEUTRAL gesture: press BOTH shift keys TWICE (up x2 + down x2) within
                                     -- this window -> neutral (manual + DCT). 250ms is a realistic human window
                                     -- for 4 presses; lower = stricter, higher = easier.
    NeutralBrakeDoubleTapMs = 300,   -- AUTO classes: two quick S (brake) taps within this window while STOPPED
                                     -- -> NEUTRAL. Was a single fresh S press, which tripped by accident on any
                                     -- stop; double-tap makes N deliberate. Lower = stricter, higher = easier.
    ManualNeutralLatch     = false,  -- manual: false = neutral is TEMPORARY (held only, returns to pre-neutral
                                     -- gear on release); true = latched until next shift (paddle-style, for
                                     -- a future manual-with-paddle feel). Default temporary.
    -- REVERSE (manual + DCT paddle). Reached by going DOWN past neutral.
    RealisticReverseManual = true,   -- manual/seq: true = R only engages when nearly stopped
                                     -- (<ReverseMaxKmh). NO held-brake required (2026-08-14: ditched
                                     -- the hold-S gate) — a plain downshift from N walks into R like
                                     -- any ladder rung. false = down-from-N -> R at any speed.
    RealisticReverseDct    = true,   -- DCT paddle: same meaning (near-stop speed gate only, no brake).
    ReverseMaxKmh          = 8.0,    -- realistic-reverse speed gate (must be below this to select R)
    -- (DCT AUTO sub-mode always uses GTA-native brake-to-reverse; these don't apply there.)

    -- SHIFT POWER MULTIPLIER — rewards a clutched shift, punishes a no-clutch
    -- one. Applied as an engine-torque multiplier DURING the shift window and
    -- for ShiftPowerHoldMs after the gear commits, then fades back to 1.0.
    -- (Separate from the duration penalty above — this is a POWER effect.)
    ShiftClutchBoost   = 1.0,        -- [BASELINE TEST] neutralised (was 1.1 = 110% on clutched shift)
    ShiftNoClutchPower = 0.90,       -- no-clutch, NON-rev-matched shift -> mild bog (the penalty). A clutchless
                                     -- shift you don't rev-match engages clean but down on power for the hold
                                     -- window; nail the rev-match for the RevMatchBonus upside instead. Set to
                                     -- 1.0 to remove the bog entirely (no penalty for a missed clutchless shift).
    ShiftPowerHoldMs   = 350,        -- how long the multiplier holds after commit (was 800; shortened so the
                                     -- post-shift power effect doesn't linger after the clutch re-engages)

    -- CLUTCHLESS REV-MATCH (skill reward). Shifting WITHOUT the clutch only pays off
    -- if you rev-match: if engine RPM is within RevMatchWindow of what the new gear
    -- wants at this speed -> BONUS. ANY other clutchless shift (off-match, or a gear
    -- not yet learned) keeps the no-clutch PENALTY (ShiftNoClutchPower bog). So
    -- clutch = safe/clean; clutchless = bonus only when you nail it, else a bog.
    RevMatchEnable     = true,
    RevMatchWindow     = 0.12,       -- |rpm - target| within this (0..1 rpm units) = matched -> bonus (a touch wider = easier to hit)
    RevMatchBonus      = 1.0,        -- [BASELINE TEST] neutralised (was 1.30 punch on rev-matched clutchless shift)
    RevMatchBonusMs    = 900,        -- how long the bonus/penalty power holds after commit (longer = more felt)
                                     -- (off-match penalty uses ShiftNoClutchPower above)
    RevMatchFailNeutralMs = 0,       -- FAILED clutchless shift: gear falls to NEUTRAL this long (a "missed
                                     -- gate"), THEN engages the gear you were going for. 0 = disable (default).
                                     -- DISABLED: a full second of neutral on every non-rev-matched clutchless
                                     -- upshift bled all the speed ("0 accel, slower and slower"). The gear now
                                     -- engages immediately; the clutchless penalty is just the ShiftNoClutchPower
                                     -- bog (below). Hold the Clutch key for a clean, boosted shift instead.

    -- COLD-START RATIO SEED — kill the "blind until each gear is driven once" delay.
    -- The learned table (gbRpmPerSpeed) is wiped on every vehicle entry, so rev-match,
    -- the auto/DCT shift-point projection and the per-gear rev-limiter cap were all
    -- guessing until each gear had been driven once. We now SEED every gear at Enable
    -- straight from the car's real handling.meta:
    --     rpmPerKmh[g] = nativeRatio[g] / (RatioSeedK * maxFlatVel)
    -- This isn't a fudge: fInitialDriveMaxFlatVel is the speed a 1.0-ratio gear hits
    -- redline, so normalised rpm = ratio*speed / (k*maxFlatVel) with a fixed
    -- km/h->gameunit constant. Live telemetry across cars spanning ~2x top speed
    -- (RX7 maxFlatVel 185, Agera 355) pinned K*maxFlatVel ~= 0.834 in EVERY gear, i.e.
    -- K ~= 0.834 / maxFlatVel * maxFlatVel... measured directly: rpmPerKmh/ratio * maxFlatVel
    -- = 0.833 (RX7) / 0.836 (Agera) — a 0.3% spread. So K = 1/0.834 ~= 1.199.
    -- Live learning still refines each gear from the first coupled frame; this only
    -- removes the cold-start error. Always derived from .meta, just instant.
    RatioSeedEnable = true,          -- seed gbRpmPerSpeed at Enable from .meta ratios
    RatioSeedK      = 1.199,         -- rpmPerKmh = ratio / (K * maxFlatVel); 1.199 = 1/0.834 (measured)
    -- MFV CEILING (2026-08-16 — spawn-with-mods fix, replaces SettleVerify's teardown loop). The mfv
    -- clamp no longer forces the car down to the (often STOCK-captured) floor; it lets mfv RIDE UP to
    -- floor*MfvCeilingRatio and only clamps ABOVE that (real corruption, e.g. the 2x re-stream bug).
    -- The lambra chip raises mfv ~1.06x (the honest modded top speed) — well under the ceiling — so it
    -- rides free; a 2x corruptor is still caught. No floor mutation => cannot ratchet.
    MfvCeilingRatio = 1.12,

    -- AUTHORITATIVE BAND (Phase 1, 2026-08-14) — the write-order fix proven by /gbgeartest. Instead of
    -- toggling reduced-ratio + clamping mfv and hoping GTA hands us a clean table, WE author the ratio
    -- table directly. Root cause proven live: ModifyVehicleTopSpeed (which we MUST call for mfv/
    -- driveForce writes to apply) itself forces a GTA transmission re-setup that RE-FOLDS the ratio
    -- table (T3: g7=0.686 g8=0.749 g9=0.900 folds=2). So the fix is the ORDER:
    --   1. SetVehicleHandlingFloat fInitialDriveMaxFlatVel + fInitialDriveForce (our targets)
    --   2. ModifyVehicleTopSpeed (makes step 1 apply — AND re-folds, expected)
    --   3. SetVehicleGearRatio(g, cleanBand[g]) for g=1..N (OVERWRITE the fold before physics reads it)
    -- The clean band is captured on entry once the live table reads folds=0 at the live gear count
    -- (meta + mod deltas; the trans-mod +1 STAYS — we author across whatever N GetVehicleHighGear gives).
    -- SetVehicleGearRatio WORKS + HOLDS (T1/T2); only a re-setup clobbers it (T3) — so we re-assert
    -- after re-setup + a cheap per-frame safety write (per-frame handling/ratio writes are cost-safe;
    -- NOT the ApplyForceToEntity solver-flood class). When ON, this SUPERSEDES the mfv floor/ceiling
    -- clamp + reduced-ratio toggle for geared cars. Keep OFF to A/B against the legacy path live.
    AuthoritativeBand = true,        -- master flag for the Phase-1 authoritative writer
    AuthoritativeBandDebug = false,  -- [hk-authband] per-cycle trace (capture / write / clobber-catch) — off, stable

    RatioSeedDebug  = false,         -- F8-print the seeded table once per Enable (off; noise)
    RatioProbeDebug = false,         -- the [hk-ratioprobe]/[hk-ratioprobe2] derivation probes. Kept in code
                                     -- (used to derive RatioSeedK); flip true to re-collect raw ratio telemetry.

    -- GEAR COUNT + FOLD HANDLING. gearcount = GTA's physical highGear (stock 911ts=8, +trans mod=9);
    -- we never STATICALLY cut the count at Enable. GTA hands out DIFFERENT ratio tables for the same
    -- modded car (sometimes a clean 9-speed to 315, sometimes one where g8/g9 fold LOWER than g7), and
    -- a single Enable-time read can't tell which — cutting there was wrong both ways (threw away a real
    -- top gear once; missed the fold another time). Instead the fold is trimmed LIVE at each upshift:
    -- LiveFoldGuard blocks an AUTO upshift into a gear that tops out lower than the current one, judged
    -- from the CURRENT live ratio table (HK.upshiftIsFold). Clean tables never trip it; a folded modded
    -- car simply stops climbing at its last useful gear and holds there. Self-corrects if the table
    -- changes; can never cut a genuinely-faster gear. Manual paddle/ladder still obeys the driver.
    LiveFoldGuard   = false,         -- (retired) auto-upshift fold block — off; the real bug was a STALE
                                     -- stock snapshot on a modded car, not a live fold. See SettleVerify.
    DropFoldedGears = false,         -- legacy STATIC Enable-time cut; keep OFF (it read stale tables)
    FoldGainEps     = 0.0,           -- min kmh a gear must add to not count as a fold (0 = any positive gain)

    -- MODDED-DRIVETRAIN SETTLE VERIFY (root-cause fix, 2026-08-15). Entering a car spawned WITH mods
    -- already fitted, GTA applies the gear COUNT instantly but LAGS the ratio/maxFlatVel recompute a
    -- few frames — so Gearbox_Enable snapshots the STOCK drivetrain (mfv=210.1, stock 315 ratios) on a
    -- car really geared for ~256+, and nothing re-captures (the mod-fingerprint watcher only fires on a
    -- mod CHANGE; spawn-with-mods never changes it). The stock floor then pins top speed to 315 and the
    -- live modded ratios fight it (oscillating/folded tables, short gears). This watches the live
    -- drivetrain for SettleVerifyMs after entry and re-snapshots the instant it diverges from the
    -- captured origins (the modded recompute landing) — re-capturing origins/floor/seed from the
    -- settled modded values. See client/gearbox.lua Gearbox_Enable + tick settle-verify block.
    SettleVerify    = false,         -- DISABLED 2026-08-14: on a car with a CONTINUOUS mfv corruptor
                                     -- (lambra tunerchip raising fInitialDriveMaxFlatVel every frame),
                                     -- SettleVerify saw the raise as "settled divergence", cleared the
                                     -- floor + re-Enabled, which re-armed SettleVerify -> infinite
                                     -- Disable/Enable loop that ratcheted mfv 210->236->...->503+ and
                                     -- tore the box down every 500ms (car dies to idle, can't exit).
                                     -- The mfv-floor clamp already handles the modded-mfv case.
    SettleVerifyMs  = 4000,          -- how long after entry to watch for the recompute to land

    -- ========================================================================
    -- GEAR-RATIO MODE (PHASE 2) — per-model "shift-feel character" preset.
    -- Stored in hk_handling.gearRatioMode (0-3), set by /gearratio, pushed to
    -- clients in HK.manualModels[hash].ratio, applied in Gearbox_Enable.
    --
    -- PRINCIPLE: NEVER moves the car's real top speed (fInitialDriveMaxFlatVel is
    -- the math ANCHOR, left alone). It only retunes WHEN the box shifts and how hard
    -- it pulls — shift-point rpm, downshift eagerness, shift speed, optional low-gear
    -- launch punch. Mode-AGNOSTIC: the same knobs modulate whatever the active mode
    -- (auto / DCT / manual / seq) already does, as MULTIPLIERS on its shift points.
    --
    -- ⚠ PLACEHOLDER NUMBERS — gentle/conservative starting values so the mechanism is
    -- safe to ship; real aggressive tuning happens in-game (PHASE 2D). Mode [0] is a
    -- pure no-op (all 1.0) = stock feel, the safe default.
    --
    -- KNOBS (multipliers on the active mode's values; 1.0 = unchanged):
    --   UpshiftRpmMult   >1 holds closer to redline (sport/hyper); <1 short-shifts
    --                    early (drag up top). Clamped under the limiter. Hits DCT
    --                    AutoUpRpm/WOT + comfort AutoEarlyShiftRpm.
    --   DownshiftRpmMult >1 = downshift sooner / eager engine-brake. DCT AutoDownRpm
    --                    + AutoKickdownRpm.
    --   ShiftTimeMult    <1 = faster shifts (hyper near-instant); >1 = lazier. Scales
    --                    shiftTimeUp/Down + DCT shift windows.
    --   LowGearTorque    launch punch in gears 1-2 (drag). Torque-only, fades by 3rd.
    --   LadderUpBias     PROGRESSIVE spread (hypercar "ratios scale up the ladder"). Per-
    --                    gear additive bias on the upshift point: gear 1 short-shifts
    --                    (bias below stock), and each gear up the box holds progressively
    --                    LONGER (bias climbs to +value by the top gear). 0 = uniform (off).
    --                    Combine with UpshiftRpmMult (flat) for a base + ramp.
    --   DriveInertiaMult >1 = engine revs up/down FASTER (snappier needle, hits shift
    --                    points sooner = pulls harder between shifts) WITHOUT changing
    --                    top speed. Applied at Enable, restored on Disable. Composes
    --                    with seq mode 6's own inertia mult (multiplied together).
    --   DriveForcePct    OPTIONAL +% on fInitialDriveForce, applied ONLY when
    --                    RatioUseDriveForce is true. Per-mode so each adds its own.
    -- ========================================================================
    RatioUseDriveForce = false,      -- MASTER toggle. false (default) = ratio modes are
                                     -- pure SHIFT-FEEL (never touch driveForce / power).
                                     -- true = ALSO layer each mode's DriveForcePct below.
    RatioModes = {
        -- [0] DEFAULT — pure no-op. Stock shift feel; the safe baseline for every car.
        [0] = {
            Label = 'DEFAULT',
            UpshiftRpmMult = 1.0, DownshiftRpmMult = 1.0, ShiftTimeMult = 1.0,
            LowGearTorque = 1.0, DriveForcePct = 0.0, DriveInertiaMult = 1.0, LadderUpBias = 0.0,
        },
        -- [1] SPORT — HARSH STARTUP, SMOOTH UPSHIFTS. Aggressive low-gear launch (punchy
        -- off the line + fast early revs) but the gear CHANGES themselves stay smooth and
        -- relaxed (no snappy short shift — that's the drag/hyper character). So: strong
        -- low-gear torque + snappier revs, hold gears a touch longer, but ShiftTimeMult
        -- stays >=1.0 (smooth, unhurried shifts) and DownshiftRpmMult only mildly eager.
        [1] = {
            Label = 'SPORT',
            UpshiftRpmMult = 1.10, DownshiftRpmMult = 1.12, ShiftTimeMult = 1.05,
            LowGearTorque = 1.08, DriveForcePct = 0.0, DriveInertiaMult = 1.06, LadderUpBias = 0.0,
            -- LowGearTorque + DriveInertiaMult are the only two knobs here that ADD
            -- acceleration (a >1.0 torque punch + faster revs). Playtest: at 1.18/1.12 a
            -- Chiron hit 2.1s 0-100 (native 2.87) — the SPORT punch overpowered AccelMatch's
            -- trim. Pulled ~halfway back to 1.0 (1.08/1.06) so it still FEELS punchy/snappy
            -- off the line without the big accel gain. The pure-feel knobs (UpshiftRpmMult /
            -- ShiftTimeMult / DownshiftRpmMult) are unchanged. Re-tune via /accel if needed.
        },
        -- [2] DRAG — SHORT EARLY GEARS, FAST RPM RAMPUPS. Low gears bang through quickly:
        -- early short-shift (low up-point) so 1st/2nd are over fast, and the revs climb
        -- HARD (high inertia mult = fast rampup) with a strong launch punch. Narrow-spread
        -- drag feel; real top speed unchanged.
        [2] = {
            Label = 'DRAG',
            UpshiftRpmMult = 0.82, DownshiftRpmMult = 1.05, ShiftTimeMult = 0.80,
            LowGearTorque = 1.22, DriveForcePct = 0.0, DriveInertiaMult = 1.30, LadderUpBias = 0.0,
        },
        -- [3] HYPERCAR — GEAR-RATIO SCALES UP THE LADDER (progressive spread). LadderUpBias
        -- makes gear 1 short-shift and each gear up the box hold progressively LONGER
        -- (low gears short + hard, high gears tall = "never runs out of gears"). Strong
        -- low-gear punch + fast early revs + near-instant shifts. The final-gear relaxation
        -- (client) still guarantees the top gear engages. UpshiftRpmMult kept ~1.0 so the
        -- ladder bias is the dominant shaping (not a flat hold on top of it).
        [3] = {
            Label = 'HYPERCAR',
            UpshiftRpmMult = 1.0, DownshiftRpmMult = 1.05, ShiftTimeMult = 0.70,
            LowGearTorque = 1.14, DriveForcePct = 0.0, DriveInertiaMult = 1.18, LadderUpBias = 0.12,
        },
        -- [4] LST — KOENIGSEGG LIGHT SPEED TRANSMISSION (one-off for the Gemera, 2026-08-14).
        -- The real LST is a 9-speed, 6-wet-clutch, synchro-less box whose signature is NOT
        -- "fast shifts" but SEAMLESS shifts (no perceptible torque interruption) + a HUGE
        -- progressive ladder (brutally short low gears for launch, very tall top gears so it
        -- "never runs out of gears"). This profile pushes HYPERCAR further in exactly those two
        -- axes and nothing else:
        --   * ShiftTimeMult 0.50 — near-zero shift time (seamless, beyond hypercar's 0.70). Paired
        --     with the type-4 DctProfiles[4] HandoffRetain (near-seamless torque hold) = no felt
        --     interruption, which is the LST's whole trick.
        --   * LadderUpBias 0.18 — the biggest spread of any mode: gear 1 short-shifts hardest and
        --     each gear up the box holds progressively LONGER (short+hard low, very tall high).
        --   * LowGearTorque 1.14 / DriveInertiaMult 1.20 — same launch punch + fast early revs as
        --     hypercar (a hair more inertia for the direct-drive rev snap).
        -- PERFORMANCE-NEUTRAL like every other ratio mode: RatioUseDriveForce is false so DriveForcePct
        -- is dormant, and AccelMatch still trims type-4 0-100 back near .meta. This is pure shift FEEL.
        -- NOTE: not in UpgradeMap/UpgradeRatioProgression, so a jim upgrade LEAVES an LST car on LST
        -- (resolveEffective: base ratio 4 ~= 0, progression[4] is nil -> ratio stays 4). Intentional.
        [4] = {
            Label = 'LST',
            UpshiftRpmMult = 1.0, DownshiftRpmMult = 1.05, ShiftTimeMult = 0.50,
            LowGearTorque = 1.14, DriveForcePct = 0.0, DriveInertiaMult = 1.20, LadderUpBias = 0.18,
        },
        -- [5] F1BOX — F1-DERIVED PADDLE BOX (AMG ONE / Valkyrie flavour, 2026-08-14). The character
        -- of a race-derived sequential-feel box: revs HARD to a stratospheric limiter, holds each gear
        -- to the very top (no early short-shift), and cracks off the next gear violently. This is the
        -- OPPOSITE shaping to LST/HYPERCAR's progressive-ladder — here every gear is held LONG and hard:
        --   * UpshiftRpmMult 1.15 — hold each gear much later (screams to redline before it'll change).
        --   * DownshiftRpmMult 1.20 — eager, aggressive rev-matched downshifts (race blip).
        --   * ShiftTimeMult 0.55 — brutal near-instant crack (a hair softer than LST's seamless 0.50
        --     because an F1 box you FEEL the bang; LST you don't).
        --   * LadderUpBias 0.0 — deliberately FLAT: no progressive spread. The hold-longer comes from
        --     UpshiftRpmMult, applied evenly to every gear (a race box has tight even ratios, not a
        --     road-car's tall overdrive up top).
        --   * DriveInertiaMult 1.22 — fastest rev pickup of any mode (light race flywheel snap).
        -- PERFORMANCE-NEUTRAL (RatioUseDriveForce false; AccelMatch trims type-4 0-100 near .meta).
        [5] = {
            Label = 'F1BOX',
            UpshiftRpmMult = 1.15, DownshiftRpmMult = 1.20, ShiftTimeMult = 0.55,
            LowGearTorque = 1.12, DriveForcePct = 0.0, DriveInertiaMult = 1.22, LadderUpBias = 0.0,
        },
        -- [6] QUADTURBO — BUGATTI W16 GRAND-TOURER (Chiron / Veyron / La Voiture Noire, 2026-08-14).
        -- The W16's signature is NOT snappy race shifts — it's an EFFORTLESS, seamless torque FLOOD:
        -- the quad-turbo makes so much torque so low that the box short-shifts early and surfs the fat
        -- mid-range in tall gears (the car pulls like a train from any rpm, no drama). So this is the
        -- CALM top-tier profile — the anti-F1BOX:
        --   * UpshiftRpmMult 0.90 — short-shift EARLY (the torque's already there; no need to rev out).
        --   * ShiftTimeMult 0.80 — quick but SMOOTH (grand-tourer refinement, not a race crack).
        --   * LadderUpBias 0.10 — mild progressive spread: short low gears, tall relaxed high gears for
        --     the ~400 km/h top end (a gentler version of the hypercar ladder).
        --   * LowGearTorque 1.16 — strongest low-gear surge of any mode (that immense off-boost shove).
        --   * DriveInertiaMult 1.08 — heavy, unhurried revs (a big W16 doesn't zing like a race V8).
        -- PERFORMANCE-NEUTRAL (RatioUseDriveForce false; AccelMatch trims type-4 0-100 near .meta).
        [6] = {
            Label = 'QUADTURBO',
            UpshiftRpmMult = 0.90, DownshiftRpmMult = 1.05, ShiftTimeMult = 0.80,
            LowGearTorque = 1.16, DriveForcePct = 0.0, DriveInertiaMult = 1.08, LadderUpBias = 0.10,
        },
    },

    -- ========================================================================
    -- ACCEL MATCH (speed-invariant guard). THE SCRIPT'S MANDATE is "change gear
    -- FEEL, not acceleration / top speed". Our gearbox shifts smarter than GTA's
    -- lazy native box, so in the mid-speed band (where GTA bogs on a bad upshift and
    -- we don't) cars net ~0.3-0.8s FASTER 0-100 than .meta. This claws that back with
    -- a TORQUE-ONLY trim (always <=1.0, never adds power) so 0-100 lands back near
    -- stock — WITHOUT touching shift feel, launch, or top speed.
    --
    -- CURVE (a smooth trapezoid over ABSOLUTE km/h — the bog band is a fixed low-gear
    -- phenomenon at real road speed, NOT a fraction of top speed, so absolute km/h is
    -- what actually tracks it across both a Chiron and an M3):
    --   below FadeInLoKmh        -> trim 1.0 (LAUNCH untouched)
    --   FadeInLoKmh..FadeInHiKmh -> smoothstep fade IN  (gentle ramp, 0->full)
    --   FadeInHiKmh..FadeOutLoKmh-> FULL trim (the bog-band plateau)
    --   FadeOutLoKmh..FadeOutHiKmh-> smoothstep fade OUT (full->0)
    --   above FadeOutHiKmh       -> trim 1.0 (TOP SPEED untouched)
    -- SAFETY: trim is always <=1.0 (cannot add power — the mandate's forbidden
    -- direction is locked out by construction). Depth is ONE knob (CurveDepth), no
    -- per-car tuning. Only under throttle; only for PUBLIC types in Modes.
    -- ========================================================================
    AccelMatch = {
        Enabled    = true,      -- master toggle (false = byte-identical to no trim)
        Modes      = { [2]=true, [3]=true, [4]=true },  -- PUBLIC gear types to trim. DCT only
                                -- by default: mode 0 (NEW auto) is already SLOWER than stock,
                                -- manual/seq (1/5) are driver-paced. Keyed by public type.
        -- Trapezoid edges in ABSOLUTE km/h. Tuned for the 60-100 bog band (0-60 matches
        -- stock, so keep the fade-in above ~45 to leave launch alone).
        FadeInLoKmh  = 48.0,    -- below this: no trim (launch safe)
        FadeInHiKmh  = 66.0,    -- full trim by here (start of the bog band)
        FadeOutLoKmh = 100.0,   -- full trim holds until here (the 100 benchmark)
        FadeOutHiKmh = 120.0,   -- trim fully gone by here (tightened from 150: 100+ already
                                -- tracks native, so release sooner instead of dragging the trim up)
        CurveDepth   = 0.28,    -- THE depth knob: peak torque cut at the plateau. 0.28 = -28%
                                -- torque through the bog band. LOWERED from 0.50 (2026-06-12):
                                -- 0.50 felt ~0.6-0.9s too slow in real driving (esp. full-throttle
                                -- 2nd gear, which passes right through the 48-120 km/h trim band).
                                -- Calibration history via /accel on Chiron mode 4: 0.36 -> 2.55s,
                                -- 0.58 -> 3.06s (~2.32s per depth unit), so 0.50 hit native ~2.87s
                                -- on the bench but over-bit in feel. Re-verify with /accel.
                                -- Raise = slower, lower = faster.
        Debug      = false,      -- F8-print speed/trim each frame the trim is active
    },

    -- ========================================================================
    -- ACCEL STRETCH (2026-08-16) — GLOBAL low-speed acceleration-time governor.
    -- GTA's own driving model launches EVERY car far too hard: sub-2s 0-60 and
    -- sub-2s 0-100 on cars that in reality do 2.7-3.5s (a McLaren Senna does 0-100
    -- in ~2.7s real, ~1.78s in-game). This is a game low-speed grip/torque flaw,
    -- NOT our handling.meta — so it applies to ALL cars regardless of tune. This is
    -- a single CUT-ONLY torque trim across the 0->100 km/h band: a uniform cut
    -- multiplies BOTH the 0-60 and the 0-100 TIME by the same factor, so you set one
    -- depth to stretch the whole low-speed sprint. Unlike AccelMatch (which is
    -- expert-only + mode-gated and aims for .meta), this runs for EVERY car/mode.
    --
    -- TIME MATH: time_multiplier ~= 1 / (1 - Depth) (drag makes it slightly less):
    --   Depth 0.30 -> ~1.43x | 0.33 -> ~1.49x | 0.35 -> ~1.54x  (your 1.42-1.55 target)
    -- SAFETY: trim is always <=1.0 — can NEVER add power (top speed + launch grip
    -- untouched). Skipped during launch control, free-rev/burnout, drift, reverse,
    -- and at a dead standstill (below FadeInLo) so nothing that needs full torque is
    -- starved. Road-speed based, so a wheelspinning launch (low road speed) is barely
    -- cut — the cut bites once the car is actually rolling.
    -- ========================================================================
    AccelStretch = {
        Enabled     = true,
        Depth       = 0.33,     -- THE knob: peak torque cut across 0-100 for a mid-roster car. ~1.49x time. Raise = slower.
        -- POWER-SCALED depth (stopgap until the traction/wheelspin model lands). GTA over-launches in
        -- proportion to power, so a flat Depth overshoots SLOW cars (~0.8s too long 0-100). Scales Depth
        -- DOWN for heavy/weak cars via HK.flyMass (mass/power). 0 = flat depth (old behaviour).
        DepthPowerScale = 0.55, -- how hard to back off per unit of (flyMass-1); raise = slow cars get even less cut
        DepthMinScale   = 0.40, -- floor: heaviest/weakest cars still keep at least this fraction of Depth
        FadeInLoKmh = 2.0,      -- below this: NO cut (dead-standstill — no stall/creep weirdness)
        FadeInHiKmh = 8.0,      -- full cut by here (ramps in fast so most of 0-60 is fully governed)
        FullToKmh   = 100.0,    -- full cut holds all the way to the 100 benchmark
        FadeOutHiKmh= 118.0,    -- cut fully gone by here (top speed + high-speed roll untouched)
        -- FEEL half (combines with the torque cut, doesn't replace it). Drops fDriveInertia below the
        -- Enable base so the engine spins its rotating mass up a beat slower under load = "building up to
        -- speed" instead of GTA's instant snap. 0 = torque-only (pure number). The torque cut still owns
        -- the actual 0-100 time; this is pure launch CHARACTER.
        -- Has its OWN fade (not the torque band) so it doesn't create a per-gear cliff: rises fast off
        -- the line, decays smoothly to 0 by FlyDecayToKmh (well before 3rd) so each gear gets slightly
        -- less laziness than the last — a natural progression, no "cut off" at the 2->3 shift.
        FlyReduce      = 0.18,  -- peak fDriveInertia reduction (lowered from 0.25 — low gears were too long)
        FlyFadeInLoKmh = 2.0,   -- no soften at dead standstill
        FlyFadeInHiKmh = 6.0,   -- peak laziness by here (right off the line)
        FlyDecayToKmh  = 85.0,  -- smoothly back to normal snappy rev by here (before the 2->3/3rd region)
        Debug          = false, -- F8-print speed/trim each active frame
    },

    -- ========================================================================
    -- SPEED CALIBRATION (/setspeed) — per-model acceleration trim so an admin can
    -- nudge a car onto its real-life 0-60/0-100/etc. figures WITHOUT touching
    -- rpm/gear (pure torque multiplier, so it can never cause the bog/wheelie bug).
    --
    -- PER-GEAR model: the four packed factors are GEARS 1/2/3/4+, NOT speed bands.
    -- The tick applies the factor for the car's ACTUAL current gear, so each factor
    -- rides GTA's real gear ratio and corrections stay isolated per gear (no speed-
    -- band cross-talk = no over/undershoot ping-pong). /accelcal + auto-cal LEARN the
    -- factors from real measured pulls, judging each gear on the speed range it drove.
    -- Packed into the speedCalC BIGINT (format unchanged from the old band scheme).
    -- ========================================================================
    SpeedCal = {
        Enabled    = true,
        -- LEGACY band edges — only the old-data fallback path reads this now; the
        -- per-gear tick ignores it. Kept so a pre-migration speedCalC still resolves.
        Bands      = { 60, 100, 160, 1e9 },
        FactorMin  = 0.40,     -- hard clamp floor. WIDENED from 0.70: GTA arcade cars are
                               -- often FAR faster than real life (a Chiron does 0-100 in ~2s
                               -- in-game vs 2.4s real, an R8 ~1.9s vs 3.4s real), so matching
                               -- real figures needs deep CUTS (down to ~0.45x). 0.40 allows it.
        FactorMax  = 1.40,     -- hard clamp ceiling (boosting a too-slow car)
        -- /accelcal is now ONE-SHOT FROM NEUTRAL: it suspends the factor, you floor the car
        -- once, and it sets factor = neutralTime/targetTime per gear (time ∝ 1/torque, so it
        -- lands in one pull and can't run away — the old measured/target FEEDBACK multiply
        -- compounded on itself and drifted granvia to the floor). ConvergeTolSec = a gear
        -- within this many seconds of target is left NEUTRAL (1.00 = already correct).
        ConvergeTolSec = 0.40,
        AccelCalArmTimeoutMs = 90000,  -- if a baseline pull is never completed, restore the
                                       -- factor after this long so it can't stay suspended.
        BlendKmh   = 6.0,      -- (legacy) linear blend width — unused by the per-gear tick
        Debug      = false,

        -- ============================================================
        -- AUTO-CAL — passive background telemetry = automatic /accel + /accelcal.
        -- The script watches NORMAL driving: the FIRST time a player does a clean
        -- standing-start full-throttle pull in a stock car, it captures the real
        -- per-gear segments and corrects that model's PER-GEAR factors toward the
        -- /setspeed target. It learns AGGRESSIVELY while far off, then STOPS once every
        -- reachable gear is within ConvergeTolSec of target (so a freshly-used car
        -- self-tunes in 2-3 pulls and then leaves itself alone). Cars never driven hard
        -- keep their neutral seed.
        --
        -- POLLUTION GUARDS (this writes a SHARED per-model row, so be paranoid):
        AutoCal = {
            Enabled        = true,
            RequireStock   = true,    -- ONLY capture if the vehicle is FULLY STOCK (no engine/
                                      -- turbo/transmission mods) — a modded car isn't the real
                                      -- car and would poison the baseline.
            StartKmh       = 2.0,     -- must begin from a near-dead stop (<= this) to count
            MinThrottle    = 0.90,    -- must hold near-full throttle the whole pull
            MaxSteer       = 0.35,    -- abort if steering hard (cornering loses time)
            -- Any of these mid-pull => DISCARD the whole run (not a clean WOT launch):
            --   handbrake, brake input, wheels off ground, collision, throttle drop.
            -- ONE-SHOT: auto-cal only watches a model that still has NO factor (neutral), so
            -- the pull it sees IS a clean baseline. It computes factor = neutral/target per
            -- gear once and LOCKS it; a learned model is never captured again. No nudging, no
            -- loop. (That's why the old Gain/Step/Deadband knobs are gone.)
            ConvergeTolSec = 0.40,    -- a gear within this many s of target stays NEUTRAL (1.00)
            MinRunGapMs    = 1500,    -- cooldown between accepted captures (anti-spam)
            Debug          = false,
        },
    },



    -- MODE 1 — CLASSIC MANUAL (own namespace; fully separate from DCT/seq).
    -- Only overrides that should differ from the shared SHIFT FEEL defaults live here.
    Manual = {
        -- Declutched keep-alive / downshift rev feed, MANUAL ONLY. Halved from the
        -- shared 22.0 because manual's downshift rev-match was feeding back too much
        -- rpm (over-blip). DCT still uses the top-level RevRaiseRate (22.0); seq uses
        -- Seq.RevRaiseRate. This isolates the manual feel from both.
        RevRaiseRate = 11.0,

        -- SHIFT REWARD / PENALTY — MODE 1 ONLY (seq mode 6 uses its own Seq.* system;
        -- DCT uses per-profile boosts). The top-level ShiftClutchBoost / RevMatchBonus /
        -- ShiftNoClutchPower / RevMatchFailNeutralMs were neutralised to 1.0/1.0/0.90/0
        -- for the clean RPM baseline test; these mode-1 overrides RE-ENABLE the skill
        -- feel for manual without touching seq (which shares ShiftClutchBoost). The
        -- manual branch reads `Manual.X` first, falling back to the top-level key.
        --   clutch held      -> ClutchBoost (steady, the safe/clean shift)
        --   clutchless + rev-matched -> RevMatchBonus (skill reward) for RevMatchBonusMs
        --   clutchless + missed      -> NoClutchPower bog AND a NeutralDrop "missed gate"
        -- Kept modest per playtest (bonus 1.08, not the old 1.30) — a real but not
        -- arcade reward; the penalty is what should bite. Speed-invariant: the >1.0
        -- bonus is brief + opt-in (you must nail a clutchless rev-match to get it).
        ClutchBoost          = 1.10,  -- clutched-shift steady boost (was neutralised to 1.0)
        RevMatchBonus        = 1.08,  -- clutchless rev-matched reward (user: "[1] only 1.08")
        RevMatchBonusMs      = 900,   -- how long the bonus/penalty power holds after commit
        NoClutchPower        = 0.82,  -- clutchless + off-match bog (deeper than the 0.90 baseline)
        NeutralFailMs        = 250,   -- clutchless + missed: drop to NEUTRAL this long ("missed gate"),
                                      -- then engage the target gear. 0 = disable. THE penalty that bites.
    },

    -- CLUTCH GAUGE (speedo display only — modes 1 & 6). The sim is binary (drive cuts instantly
    -- when the clutch is in / shifting / neutral), but a real pedal travels, so the gauge EASES a
    -- 0..1 value (1=out/engaged, 0=in/pressed) toward that binary target. Cosmetic, zero physics.
    -- TauIn tuned 2026-08-16: a quick clutch TAP should only nibble ~30% off the gauge (a stab reads
    -- as a stab), so a full disengage needs a real hold (~1s) or several taps. With 1-exp(-dt/tau) a
    -- ~120ms tap over tau=0.32 drops ~30%; ~500ms ~77%; ~1s ~96%. (Was 0.045 = a tap ate ~90%, too fast.)
    ClutchGaugeTauIn  = 0.32,    -- s — press-IN ease (a tap nibbles ~30%; full disengage needs a hold)
    ClutchGaugeTauOut = 0.11,    -- s — bite-OUT ease (slower: the clutch feathers back in)

    -- MODE 6 — HYBRID SEQUENTIAL DOGBOX (separate settings; mode 1 manual untouched).
    -- DOG engagement on UPSHIFTS: fast, clutchless-friendly, no penalty, big bonus on a
    -- perfect rev-match. SYNCHRO-assisted DOUBLE-CLUTCH on DOWNSHIFTS: clutch expected;
    -- a clutchless/badly-matched downshift grinds (penalty + brief neutral-drop). Uses
    -- the clutch (mainly for downshifts). Reuses the manual branch's machine.
    Seq = {
        ShiftUpMs        = 60,    -- dog upshift window (very fast, mechanical clunk)
        ShiftDownMs      = 180,   -- synchro downshift window (a bit slower, double-clutch feel)
        RevRaiseRate     = 22.0,  -- seq-only declutched keep-alive rev feed (independent of manual's)

        -- SEQUENTIAL UPSHIFT ZONES (rpm 0..1 scale, absolute — NOT relative to proj).
        -- These define where the dogs catch, where it's perfect, and where they reject.
        --   [0 .. UpEngageLo)       = SLUG: ENGAGES IMMEDIATELY with a x0.87 bog (no neutral).
        --                             Shifting too early just bogs you — it never drops to N.
        --   [UpEngageLo .. UpEngageHi] = ENGAGE: dogs catch, clean (no bonus/penalty)
        --   (UpPerfectLo .. UpPerfectHi) = PERFECT: subset of engage, bonus power
        --   (UpEngageHi .. 1.0]     = BOUNCE: dogs reject, kicks back
        -- NOTE: zones are in RAW (0-1). Convert from realrev% via raw = 0.20 + 0.80*rev.
        UpEngageLo   = 0.784,    -- bottom of the engagement zone = realrev 73% (below = SLUG bog)
        UpEngageHi   = 0.952,    -- BOUNCE above this = realrev 94% (raw 0.20+0.80*0.94)
        UpPerfectLo  = 0.832,    -- perfect zone start = realrev 79%
        UpPerfectHi  = 0.928,    -- perfect zone end   = realrev 91%
        UpSlugPenalty    = 0.87,  -- accel multiplier while the early-shift bog holds (engages, no neutral)
        UpSlugPenaltyMs  = 1000,  -- how long the early-shift bog holds after engaging (lengthened from 600
                                  -- so an early upshift bogs longer = stronger reason to wait for the zone)
        -- RPM PUSH (makes the perfect zone harder to nail). When rpm is at/above
        -- UpPushThreshold during the shift window, the assist PUSHES rpm UP toward
        -- UpPushTarget instead of dropping it. You have to TIME the shift, not just
        -- hold throttle and wait for the perfect zone.
        UpPushThreshold = 0.896,  -- push activates at realrev 87% (raw 0.20+0.80*0.87)
        UpPushTarget    = 0.936,  -- push toward realrev 92% (top of the perfect zone)
        UpPushRate      = 7.0,   -- how fast the push climbs (per-sec EMA rate). Raised from 4.0 so rpm
                                 -- ramps FASTER through the 87->92% realrev push zone.

        -- .META SCALING: fClutchChangeRateScaleUpShift reflects how sporty the car's
        -- transmission is (higher = faster clutch = sportier). Used to nudge the zones:
        -- sporty car (high rate) = slightly higher/tighter window (harder to nail perfect);
        -- lazy car (low rate) = slightly lower/wider (more forgiving). Clamped to ±7%.
        MetaClutchBaseline = 1.5,   -- TRUE average clutch rate (was 2.5, which was too high — pinned most
                                    -- cars to the -7% floor). 1.5 centres the scale on a realistic average,
                                    -- so when MetaScaleStrength is re-enabled, sporty cars (rate>1.5) tighten
                                    -- the window and lazy cars (rate<1.5) widen it, instead of all hitting the floor.
        MetaScaleStrength  = 0.0,   -- DISABLED for now (ready to re-enable). With baseline 1.5 fixed above,
                                    -- set e.g. 0.15 later to restore per-car window scaling. 0 = zones use the
                                    -- exact config values on every car, so realrev% targets are honoured 1:1.
        MetaScaleMax       = 0.07,  -- hard clamp: meta never moves zones more than ±7%

        -- UPSHIFT rewards/penalties
        UpshiftBonus     = 1.8,   -- PERFECT upshift TORQUE boost. 2026-08-14: dropped 2.6 -> 1.8 (perfect
                                  -- LAUNCH boost was too strong) — same knob feeds both the perfect-upshift
                                  -- reward AND the standing-launch boost (LaunchBoostLo/Hi window below).
                                  -- NOTE: this is a torque mult, not an rpm write — in GTA rpm =
                                  -- wheelspeed*ratio, so a raw rpm bump just decays; torque is what
                                  -- actually makes the next gear pull faster.
        UpshiftBonusMs   = 1200,  -- how long the PERFECT/launch boost holds (RAMPED UP from 700)
        UpMissPenalty    = 0.85,  -- power cut on a BOUNCE (dogs reject)
        UpMissPenaltyMs  = 120,   -- clash penalty hold (short; press shift again to retry)

        -- LAUNCH BOOST (manual standing start). Revving in NEUTRAL/1st and taking off
        -- in this window applies the UpshiftBonus torque for a harder launch. WIDER and
        -- LOWER than the PERFECT upshift window (a standing start sits at lower rev).
        -- Only a REWARD — a low-rev/idle pull-away still engages clean (never bogged).
        LaunchBoostLo    = 0.728, -- window bottom = realrev 66% (raw 0.20+0.80*0.66)
        LaunchBoostHi    = 0.856, -- window top    = realrev 82% (raw 0.20+0.80*0.82)

        -- DOWNSHIFT (synchro/double-clutch) — clutch expected.
        DownRevMatchWindow      = 0.08,  -- match window with NO clutch (tight — must rev-match yourself)
        DownSynchroWindow       = 0.30,  -- clutch HELD = synchro assist -> much wider/forgiving window
        DownNoClutchPenalty     = 0.8,   -- torque mult on a bad/clutchless downshift (harsh dog clunk)
                                         -- penalty duration is math.random(260,340)ms in code (no config key)
        -- NOTE: standalone ECU downshift protection was removed for now (will revisit
        -- when wiring the jim-mechanic manual upgrade later).

        -- DRIVE INERTIA MULT — how much faster the engine revs up/down compared to the
        -- car's stock .meta fDriveInertia. Controls how snappy the rev needle is, which
        -- effectively controls acceleration feel (revs climb faster -> hits shift points
        -- sooner -> pulls harder between shifts) WITHOUT changing top speed (that's locked
        -- by fInitialDriveMaxFlatVel). Applied at Enable for mode 6, restored on Disable.
        -- ADAPTIVE: cars that already have a high fDriveInertia (naturally fast-revving /
        -- short early gears) get a lower mult so they don't become uncontrollable. The
        -- code scales from DriveInertiaMult (max, for average cars) down to
        -- DriveInertiaMultMin (floor, for already-snappy cars). Threshold is the .meta
        -- fDriveInertia value above which scaling kicks in.
        DriveInertiaMult    = 3.4,    -- HIGHEST mult (applied to average/low-inertia cars) — SEQ FEATURE: faster rev ramp, not a power boost
        DriveInertiaMultMin = 2.8,    -- LOWEST mult (applied to already-high-inertia cars) — SEQ FEATURE
        DriveInertiaHighThreshold = 1.2,  -- .meta fDriveInertia above this = "already snappy"
        DriveInertiaHighCap       = 2.0,  -- .meta fDriveInertia at which the floor is fully reached
    },

    -- STALL — SOFT. Lugging the engine (too high a gear at too-low rpm) bleeds
    -- power but never kills it; the LUG FLOOR below keeps a little pull so it's
    -- never dead. Applies to manual AND DCT.
    StallThreshold = 0.25,           -- rpm below this (gear>=2, no clutch) = lugging. Raised from 0.18:
                                     -- the engine RPM floor is 0.200, so 0.18 could NEVER fire. 0.25 sits
                                     -- just above the floor so genuine tall-gear lugging triggers the bog.
    StallPowerMult = 0.45,           -- power while lugging (softer than before; never 0)
    StallMinGear   = 2,              -- only lug from this gear up (1st never stalls)
    -- LUG FLOOR — keeps a ROLLING tall-gear cruise alive without launching from
    -- a standstill. Gentle, tapers down for taller gears, gated on moving.
    LugBoost       = 1.0,            -- [BASELINE TEST] neutralised (was 1.18 gentle low-rpm lug fill)
    LugBoostMaxRpm = 0.30,           -- fade to 1.0 by this rpm. Widened from 0.22: the RPM floor is 0.200,
                                     -- so 0.22 was a razor-thin 0.02 band right at the floor (abrupt cliff).
                                     -- 0.30 lets the assist ramp out smoothly across the low-rev lug zone.
    LugMinSpeedKmh = 8.0,            -- no boost below this -> tall gear at 0 km/h bogs (realistic)
    LugMinThrottle = 0.5,            -- only assist under throttle
    LugGearFalloff = 0.5,            -- each gear above StallMinGear gets ~1/(1+0.5n) of the boost
    -- SPEED TAPER (the curve): keep the FULL lug assist in a low band (so a tall
    -- gear can get rolling), then GRADUALLY fade it to ZERO as speed climbs so the
    -- low-mid cruise accelerates slowly on natural pull (no over-acceleration).
    -- The band SCALES to the car's estimated top speed (a fraction, not fixed
    -- km/h), so '35 km/h on a 320 car' generalises to slow + fast cars alike.
    LugFullFrac     = 0.11,          -- full assist up to this fraction of top speed (~35 on a 320 car)
    LugFadeEndFrac  = 0.50,          -- assist reaches zero by this fraction of top speed (~160 on a 320 car)
    -- Fallbacks used ONLY if estimated top speed is unavailable (fixed km/h):
    LugFadeStartKmh = 40.0,          -- full lug assist at/below this speed
    LugFadeEndKmh   = 90.0,          -- zero lug assist at/above this speed

    -- REV LIMITER / PER-GEAR SPEED CAP (shared manual + DCT). At a gear's top,
    -- KILL throttle (so GTA can't force-upshift) + cut torque + light brake to
    -- force a real ~8-10 km/h dip, then re-engage = flutter off the limiter.
    RevLimiter            = true,
    RevLimiterRedline     = 0.985,   -- rpm fallback trigger (BELOW top gear — trips the upshift in time)
    RevLimiterReengage    = 0.965,   -- rpm fallback release (only if ratio unlearned)
    -- TOP-GEAR REDLINE (2026-08-14 top-speed fix): in the FINAL gear there's no upshift to time, so the
    -- old shared 0.985 cut torque ~1.5% rpm short of true redline — and in a tall top gear that sliver
    -- is 15-25 km/h of real top speed, so the car capped BELOW its native GTA/handling top. Let top gear
    -- pull almost to true redline and let GTA's own fInitialDriveMaxFlatVel terminal cap do the limiting.
    RevLimiterTopGearRedline  = 0.997,  -- top-gear cut point (near true redline; raise toward 1.0 for even more)
    RevLimiterTopGearReengage = 0.99,   -- tight top-gear flutter band so the bounce doesn't bleed top speed
    RevLimiterCut         = 0.0,     -- torque mult while limiting (0 = full cut) — BELOW top gear
    RevLimiterTopGearCut  = 0.15,    -- TOP-GEAR soft cut: real-car limiter flutter, not a hard chop.
                                     -- In the final gear there's no upshift to time, so we DON'T
                                     -- self-brake and DON'T full-cut — the engine bounces off the
                                     -- limiter and the car sits at its true terminal speed. Higher =
                                     -- more residual pull at the ceiling (softer flutter); 0.0 = a
                                     -- hard fuel-cut bounce (still no self-brake). ~0.10-0.20 is the
                                     -- real-car sweet spot: revs hang at the limiter, no bog-back.
    RevLimiterMinThrottle = 0.5,     -- only limit under throttle
    RevLimiterMinGear     = 2,       -- only cap from this gear up (1st pulls out fast)
    RevLimiterUseSpeedCap = true,    -- compute cap from learned rpm/speed ratio (reliable)
    -- 2026-08-14: user "rev limiter bounce ~120ms too slow to re-tick the next rev." The off-time
    -- between cuts is emergent (no ms timer): power re-engages once speed bleeds RevLimiterDipKmh,
    -- and RevLimiterBrake deepens+lengthens that dip. Shallower dip 9.0→6.0 + lighter brake
    -- 0.35→0.26 = the revs recover to the cap sooner, so the next bounce fires faster. If still
    -- slow, drop DipKmh toward 4-5; if it now sounds too buzzy/constant, nudge both back up.
    RevLimiterDipKmh      = 6.0,     -- speed drop before re-engage = flutter depth (was 9.0; lower = faster re-tick)
    RevLimiterBrake       = 0.26,    -- light all-wheel brake while limiting; forces the dip (was 0.35; lighter = quicker recover)
    -- BRAKE PRIORITY (2026-08-14 fix). At the rev limit in gear, pressing the brake (throttle still held)
    -- used to SPEED the car UP: the brake's speed dip tripped the limiter's flutter-release, snapping
    -- torque back to full. With this on, braking HOLDS the torque cut (no release, full cut even in top
    -- gear) so the brakes always win over drive torque at the limiter. Min = pedal fraction that counts
    -- as "braking" (ignores tiny analog noise). Off restores the old behaviour.
    RevLimiterBrakePriority    = true,
    RevLimiterBrakePriorityMin = 0.15,
    -- MANUAL SPEED-BOUNCE (2026-08-14 fix). Manual/sequential (modes 1/6) are "pureRpmCut" — they cut
    -- ONLY on rpm >= redline, no speed-cap (autos use the speed-cap to time upshifts). But manual rpm is
    -- DE-BIASED (paint subtracted), so the anchored rpm can sit under redline while the gauge shows the
    -- cut → the rpm trip never fires → the car ACCELERATES past the gear's true ratio top (the Zonda F
    -- "leaks through redline in gear" bug). Autos never leak because their un-paintable ratio speed-cap
    -- holds the ceiling. This gives manual the SAME ground-truth cap as a rev-bounce (still NO self-brake
    -- — a real manual just bounces off the fuel-cut). rpm cut still fires first at a genuine redline.
    RevLimiterManualSpeedBounce = true,
    -- FAST manual flutter: the manual speed-bounce re-engages after the car bleeds this many km/h off the
    -- cap. Autos use RevLimiterDipKmh (6-9) so the box can time an upshift; manual never upshifts for you,
    -- so a tight dip gives the rapid fuel-cut "brraap" a real ECU-less manual has (~100-200ms) instead of
    -- the lazy ~800ms coast-down bounce. Lower = faster/buzzier chatter; raise if it sounds too constant.
    RevLimiterManualDipKmh      = 1.0,
    RevLimiterGroundOnly  = true,    -- suspend the limiter when a wheel is off the ground.
                                     -- Airborne/light cars freewheel the driven wheels, so rpm
                                     -- spikes to redline on FAKE revs while road speed is flat —
                                     -- without this the limiter flutters (throttle-kill + brake
                                     -- pulse) and the box appears "stuck at gear N bouncing" until
                                     -- landing. true = don't limit off the ground (recommended).

    -- ── ENGINE TORQUE-CURVE FEEL ────────────────────────────────────────────────
    -- Real engines don't make flat torque across the rev range: a soft low-end that ramps in, a
    -- strong mid-range, then a taper as it screams to redline. GTA's stock delivery is flatter +
    -- more electric. TWO INDEPENDENT LAYERS, each separately gated:
    --
    --   LAYER A — RpmCharacter (PERF-NEUTRAL; PLAYER-shifted boxes ONLY = manual(1)/sequential(6)):
    --     shapes ONLY the rpm NEEDLE + engine-NOTE (via vl_setRpmRaw = zero drive force). A subtle
    --     "breathe" — the needle hangs a touch off-idle then rushes through the mid + holds a
    --     high-rpm rawr near redline. Pure audio/visual character; CANNOT change accel.
    --     GOTCHA (why NOT the auto boxes): SetVehicleCurrentRpm writes the SAME rpm the AUTO-shift
    --     logic reads back as state.rpm (upshift trip + atLimiter/pinned). On modes 3/4/5 the paint
    --     inflated the shift-decision rpm -> early/skipped/stuck shifts (the Chiron regression) AND
    --     broke mode-3 perf-neutrality. So it's gated to the two boxes where the DRIVER owns shift
    --     timing (rpm is not a shift input there). Auto boxes get character from Layer B instead.
    --
    --   LAYER B — PowerBand (PERF-RELEVANT — INTERNAL MODES 4 & 5 ONLY = public Sport/Super DCT):
    --     an rpm-shaped torque MULTIPLIER (HK.torqueMult) = a real power band. AREA-NORMALISED so
    --     the curve REDISTRIBUTES torque across the rev range without changing the average (a small
    --     net-neutral option) OR adds a peak (NetGain>0, the "may gain time" tiers). HARD-GATED off
    --     for internal 2 (public 0 comfort) + internal 3 (public 2 Automatic Paddle) — those MUST
    --     stay performance-neutral (see the type-neutrality invariant). Manual(1)/sequential(6)
    --     excluded too (driver-skill boxes; their delivery is a separate decision).
    TorqueCurve = {
        Enabled = true,

        -- LAYER A: rpm-needle / engine-note character. Perf-neutral (vl_setRpmRaw only).
        -- APPLIES ONLY to manual(1) + sequential(6) — see the GOTCHA above (painting rpm on an
        -- auto box corrupts its shift-decision read). Not mode-configurable on purpose.
        RpmCharacter = {
            Enabled     = true,
            -- Normalised-rpm breakpoints (0..1). Below LowRpm the needle lags slightly (soft
            -- low-end); above HighRpm it hangs/rawrs toward redline. Between = linear (no paint).
            LowRpm      = 0.22,
            HighRpm     = 0.82,
            -- Max needle OFFSET (normalised rpm) each region paints. Small — this is flavour, not
            -- a rev change you fight the box with. Low = needle sits this much BELOW physics rpm
            -- (lazy pickup); High = needle sits this much ABOVE (screaming hold near redline).
            LowLag      = 0.03,
            HighHang    = 0.04,
            -- Smoothing tau (s) so the painted offset eases in/out (no needle snap). exp-tau.
            Tau         = 0.12,
            -- Only paint under throttle (coast/brake = raw needle, so engine-braking reads true).
            MinThrottle = 0.15,
        },

        -- LAYER B: real torque power-band. PERF-RELEVANT — internal modes 4 & 5 ONLY.
        PowerBand = {
            Enabled     = true,
            Modes       = { [4] = true, [5] = true },   -- internal modes allowed (NEVER add 2 or 3)
            -- Curve shape as torque MULT at three rpm anchors (low / peak / redline). The shape is
            -- AREA-NORMALISED to average 1.0 across the rev range first (pure redistribution =
            -- perf-neutral), THEN scaled by (1 + NetGain) so NetGain is the ONLY thing that adds
            -- net power. NetGain 0 = redistribute only (feel, no time); >0 = the tiers that may gain.
            LowMult     = 0.90,     -- soft low-end (torque builds in)
            PeakMult    = 1.12,     -- strong mid-range punch
            PeakRpm     = 0.62,     -- where peak torque sits (normalised rpm)
            RedlineMult = 0.94,     -- tapering top-end (power holds, torque eases)
            NetGain     = 0.05,     -- net area added AFTER normalisation (0 = net-neutral; 0.05 = +5% mean)
            MinThrottle = 0.30,     -- only shape the band under real throttle (light pedal = calm)
            Tau         = 0.08,     -- smoothing so crossing an anchor doesn't step the torque
        },
    },

    -- ============================================================= TURBO
    -- TURBO SYSTEM (2026-08-14). Triggered by the NATIVE GTA turbo mod (mod type 18), which the
    -- jim-mechanic PERFORMANCE upgrade installs (IsToggleModOn(veh,18)). No mod = ZERO change (stock
    -- feel + stock power, car stays at spec — the hard requirement). Two layers, mirroring the
    -- torque-curve split:
    --   FEEL (perf-neutral, ALL gearbox modes): a spool model — boost pressure LAGS throttle tip-in
    --     (exp-tau), whistles as it builds, flutters on a throttle lift. Drives only the rpm-note +
    --     the boost gauge — ZERO net force, so a turbo'd car WITHOUT the power layer still hits the
    --     same top speed + accel. This is "mainly the driving feeling of it."
    --   POWER (perf-relevant, INTERNAL MODES 4 & 5 ONLY): one FLAT torque bump, EQUAL for every car
    --     (no per-car tuning), composed on top of Layer B via HK.torqueMult, scaled by spool so it
    --     builds in rather than snapping. Comfort(2)/paddle(3) stay perf-neutral (see type invariant).
    -- NOS NON-COLLISION: hk power = SetVehicleEngineTorqueMultiplier (HK.torqueMult); NOS =
    --   SetVehicleCheatPowerIncrease/TurboPressure/ModifyVehicleTopSpeed — DIFFERENT natives, can't
    --   clobber, no restore fight. Only overlap is FEEL, so the turbo whistle MUTES while NOS is
    --   active (reads the hk_nosBoostLevel statebag jim-mechanic already publishes). Same stand-down
    --   pattern as the antilag EV-suppression.
    Turbo = {
        Enabled       = true,
        ModIndex      = 18,      -- native GTA turbo mod type (jim-mechanic installs this). Trigger flag.

        -- FEEL layer (perf-neutral, all modes) --------------------------------------------------
        SpoolTauUp    = 0.52,    -- s: how slowly boost BUILDS as you get on throttle (lag). Higher = laggier. (was 0.45)
        SpoolTauDown  = 0.20,    -- s: how quickly boost BLEEDS when you lift (faster than build = real turbo).
        SpoolMinRpm   = 0.34,    -- below this normalised rpm the turbo makes ~no boost (off-boost / laggy bottom end). Raised 0.28->0.34 = more low-rpm lag.
        SpoolFullRpm  = 0.60,    -- at/above this rpm boost is fully available (on-boost). 0.60 = boost arrives EARLIER (~4K), no violent 5K slam. (was 0.72 = too peaky/laggy)
        SpoolCurve    = 1.3,     -- ease-in exponent on the rpm ramp (>1 = boost stays low then WAKES UP high). 1.3 = gentle wake-up, not an on/off spike. (was 1.8 = too abrupt)
        MinThrottle   = 0.20,    -- boost only builds above this throttle (light cruise = off-boost)
        WhistleRpmOff = 0.05,    -- max normalised-rpm needle LIFT the whistle paints at full spool (manual/seq only — audio/needle flavour). Raised 0.02->0.05 = more audible.
        FlutterOff    = 0.022,   -- brief needle DIP painted on a throttle lift while spooled (the flutter "pshh"), perf-neutral. (was 0.015)
        NoteTau       = 0.08,    -- smoothing (s) for the rpm-note paint so it eases (exp-tau). Lower = snappier whistle onset.

        -- POWER layer (perf-relevant, modes 4/5 only, FLAT & equal per car) ----------------------
        -- Shape (REAL turbo physics): off-boost the engine makes its full naturally-aspirated torque
        -- (mult 1.0, NO penalty), and boost ADDS on top as spool fills, PEAKING at (1+FlatPowerGain).
        -- mult = 1 + FlatPowerGain*spool. A real turbo car isn't WEAKER off-boost — it just hasn't
        -- gained boost yet. The lag→rush FEEL comes from the HitGain transient (below) + the keyboard
        -- pedal ThrottleFloor, not from a below-baseline torque cut. Only applies WITH the upgrade (modOn)
        -- in modes 4/5. No upgrade = at spec. Works on BOTH keyboard AND analog (wheel/controller).
        -- NOTE: SpoolChoke + TurboMinMult are RETIRED (2026-08-14) — the old choke cut torque below stock
        -- off-boost (unrealistic) and could spiral a heavy/tall-geared car to a crawl; TurboMinMult only
        -- existed to catch that spiral. With a clean 1.0 baseline neither is needed. Kept out of the math.
        FlatPowerGain = 0.18,    -- +18% torque at FULL spool = the on-boost pull. Peak = top-speed knob. Off-boost = 1.0 (full NA).
        -- BOOST HIT — a TRANSIENT surge the instant boost rushes online (spool climbing fast), on TOP of
        -- the steady curve, that fades as spool settles. This is the "it SLAMS on" punch — the thing that
        -- makes a turbo feel like a turbo instead of a smooth ramp. Proportional to how fast spool is
        -- rising (dSpool/dt), so it only fires when boost is actively coming on, never at steady WOT.
        HitGain       = 0.20,    -- peak transient torque bump at max spool-rate (+20% on top, momentarily). (was 0.28 = too aggressive slam)
        HitRateFull   = 2.2,     -- spool-rate (per sec) at which the hit is at full HitGain. Lower = easier to trigger the punch.
        -- MOVE-OFF GATE (pedal floor only, now that the torque choke is gone): the keyboard pedal
        -- ThrottleFloor FADES OUT near a standstill so a car can always pull away at full pedal, then the
        -- onset hold bites once rolling (felt accelerating through the revs, not as a dead start).
        ChokeMinKmh   = 3.0,     -- at/below this speed the pedal floor is OFF (full throttle to pull away)
        ChokeFullKmh  = 18.0,    -- at/above this speed the pedal floor is at full depth. Between = linear fade-in.
        Modes         = { [4] = true, [5] = true },  -- internal modes that get the POWER bump (NEVER add 2 or 3)
        PowerMinThrottle = 0.30, -- only add power under real throttle

        -- THROTTLE-LAG layer (the FELT engagement step — pedal-side, perf-neutral) ----------------
        -- This is what you FEEL: off-boost the throttle plate is CHOKED to ThrottleFloor of your press,
        -- easing to 100% as spool fills — a dead pedal that wakes up. Runs on the PEDAL MODEL (keyboard),
        -- ALL turbo modes (byDesign feel too), and is perf-neutral (reaches full throttle = same top end,
        -- only delays onset — exactly like the keyboard ramp). Analog devices pass through untouched.
        ThrottleFloor = 0.55,    -- effective throttle off-boost = 55% of what you press. LOWER = more dramatic lag/choke. 1.0 = no pedal lag. (was 0.28 — pulled back so choke×pedal-lag can't drop net force below drag on keyboard; now milder so drama lives in torque-side)
        -- LAG CURVE: how the choked pedal opens up as spool fills. The plate = ThrottleFloor + (1-Floor)*(spool^Curve).
        -- Curve = 1.0 is a linear fade (old behaviour). Curve > 1.0 HOLDS the pedal down through the low/mid spool
        -- then RUSHES it open near full boost = a real onset STEP you feel, not a smooth blend. This is the pedal-side
        -- twin of the torque SpoolCurve. Perf-neutral (still reaches 1.0 at full spool). Keyboard/pedal-model only.
        ThrottleLagCurve = 2.2,  -- >1 = dead longer then snaps open (dramatic). 1.0 = linear fade. (was 3.0 — pulled back to 2.2 so keyboard drama stays balanced)

        -- INTEGRATION ---------------------------------------------------------------------------
        NosMute       = true,    -- mute the turbo whistle/flutter FEEL while NOS is firing (hk_nosBoostLevel > 0) so the two don't double up
        Antilag       = true,    -- react to the jim-mechanic antilag part (hk_antilag statebag): (A) let antilag own the lift-off FX
                                 -- (mute our synthetic flutter dip so the two lift sounds don't muddy), and (B) HOLD turbo spool on a
                                 -- mid-corner lift instead of bleeding it (real antilag keeps the turbo lit = no lag on corner exit).
                                 -- Perf-safe: antilag can't be fitted without turbo mod 18, and held spool only feeds power ON-throttle
                                 -- in modes 4/5, so it adds ZERO top speed — it only removes the re-spool delay. false = ignore antilag.
        MaxBar        = 1.2,     -- cosmetic: full-spool boost gauge reading (bar) for the /handlingdbg boost line. Display only.

        -- TURBO-BY-DESIGN ROSTER ----------------------------------------------------------------
        -- Spawn codes of cars that are FORCED-INDUCTION FROM THE FACTORY. These get the turbo
        -- spool/whistle FEEL by DEFAULT (no jim-mechanic upgrade needed) — but ZERO power and NO
        -- extra top speed: they stay exactly at their tuned spec until the player installs the
        -- upgrade (native mod 18), which is the ONLY thing that adds the equal, flat power bump.
        -- A DB /setturbo override (hk_handling.turboDefault) beats this list per-model; pure EVs
        -- are auto-excluded. Classified against qb-core/shared/vehicles.lua + real engine facts.
        -- Keys are spawn codes (case-insensitive via GetHashKey). Populated 2026-08-14.
        DefaultModels = {
            -- German turbo (BMW/Mercedes/Audi/VW/Porsche forced-induction) --------------------
            ['16m4gts']=true, ['2019m5']=true, ['m4f82']=true, ['m4g82']=true, ['m6f13']=true,
            ['hkm4']=true, ['bmwxm']=true, ['x6mf16']=true, ['ikx3_m5cs22']=true, ['ikx3_bat23']=true,
            ['20s63c']=true, ['s65amg']=true, ['sl65bs']=true, ['c63s']=true, ['e632021']=true,
            ['merce63s']=true, ['amggt63']=true, ['amggts']=true, ['amgone1']=true, ['cla45']=true,
            ['cle53']=true, ['oycpro']=true, ['a6']=true, ['2016rs7']=true, ['rs721']=true,
            ['hktaxi']=true, ['golf75r19']=true, ['evo9']=true, ['lanex400']=true,
            ['ikx3_4gts25']=true, ['thettrs20']=true,
            -- Italian turbo (modern Ferrari/Lambo turbo, Alfa, Maserati) ----------------------
            ['20sf90']=true, ['fer296fh5']=true, ['ferf8fh5']=true, ['hk488']=true, ['aqv']=true,
            ['ikx3_gtam21']=true,
            -- Hyper / exotic turbo ------------------------------------------------------------
            ['chiron']=true, ['supersport']=true, ['lavn']=true, ['agera2011']=true, ['gemera']=true,
            ['devel22']=true, ['venomf5']=true, ['utopia23']=true, ['wmlykan16']=true, ['m600s']=true,
            ['senna']=true, ['570ss']=true, ['ikx3_750s23']=true, ['p1']=true, ['ikx3_val25']=true,
            -- JDM / rotary turbo --------------------------------------------------------------
            ['08r35']=true, ['thegtrn24']=true, ['r32']=true, ['rx7']=true, ['s15']=true,
            ['a80']=true, ['nsx17']=true, ['fk2']=true, ['ikx3_civicr23']=true, ['kiagt']=true,
            -- American forced-induction (supercharged Hellcats/GT500/Corvette-SC/Ford GT) -----
            ['redeye']=true, ['redeye21']=true, ['fgt']=true, ['gt17']=true, ['hkgt17']=true,
            ['gt50019']=true, ['ct5v2022']=true, ['focusrs']=true, ['gt430']=true,
            -- British / misc turbo ------------------------------------------------------------
            ['19ftype']=true, ['evoque']=true, ['oycdefender']=true, ['tgrgt']=true,
            -- Turbodiesel (bus/van) -----------------------------------------------------------
            ['hkbus']=true, ['galaxyroamer']=true, ['granvia']=true,
            -- PHEV with a turbo ICE -----------------------------------------------------------
            ['u8']=true,
            -- HK PURSUIT / INTERCEPTOR BUILDS — forced turbo (fictional built-up pursuit cars,
            -- override their NA base engine per owner request 2026-08-14). hk488/hkgt17/hkm4 are
            -- already turbo above by their real engine; these are the NA-base ones we force. -----
            ['hkchar']=true, ['hkmst']=true, ['hksave']=true, ['hkgt4rs']=true,
            ['fcust53']=true, ['intercept2']=true, ['hkrtaxi3']=true,
            -- NOTE: NA cars are intentionally ABSENT (no default feel; they only spool once the
            -- jim-mechanic turbo upgrade is installed). Pure EVs (plaid, gcmmiev2010) are absent
            -- AND hard-excluded in code. NA V-engines deliberately left out: 10r8/adr8 (R8 V10),
            -- 458it/430s/f812c21/aperta70 (Ferrari NA), 918/oycrev/thevalkspdr/dzsian (NA-V hybrids),
            -- lp610/lp640/lp670sv/lp700/murc640r/lamboreventon/centenario/18performante/thetcnca
            -- (Lambo NA V10/V12), slsamg/soullfa/ast/cgt/theviper96/v877, all classic muscle
            -- (chall70/charger69/ss69/mst302/soulrunner/cobra/sgt500), civic/continental17 (base NA).
        },
    },

    -- MODE 2 — COMFORT AUTOMATIC. A relaxed, easy auto box for ambulances,
    -- utility/work vehicles, entry cars and shitboxes. GTA fully owns gear
    -- selection (UP and DOWN) — we never pin a gear and never write RPM (doing
    -- either breaks downshifts + gear-change audio). We only: nudge an EARLY
    -- upshift at light throttle to keep revs low/quiet, soften the shift with a
    -- torque dip, hold an anti-hunt dwell, and ease torque off the line for a
    -- smooth (non-lurchy) pull-away. All effects are torque-only + a one-shot
    -- gear nudge GTA can override, so the box can never get 'stuck high'.
    AutoMinShiftMs           = 1100,  -- anti-hunt + lazier: min ms between shifts (higher = shifts less often / more relaxed)
    AutoShiftRateMult        = 0.731,  -- COMFORT: scale the car's fClutchChangeRateScale*Shift to this in mode 2
                                      -- (HIGHER = FASTER mechanical gear change). Raised 0.63->0.731 (+16% shift
                                      -- rate) per playtest: basic [0] auto was shifting a bit too slow. Restored on exit.
    AutoEarlyShiftRpm        = 0.45,  -- upshift early once cruising above this rpm (lower = calmer/quieter)
    AutoEarlyShiftMaxThrottle= 0.80,  -- ...but only at light throttle (flooring it keeps the gear)
    AutoEarlyShiftAllCars    = true,  -- COMFORT: apply the relaxed early-upshift to EVERY car (not just
                                      -- fast-shifting ones). This is the whole point for slow work/entry
                                      -- vehicles — they otherwise get no comfort behaviour at all.
    AutoEarlyShiftMaxShiftMs = 350,   -- (legacy) only used when AutoEarlyShiftAllCars=false: limit the
                                      -- early-shift to cars whose handling shift time <= this (ms).
    AutoShiftDipMs           = 197,   -- smooth torque-dip duration on each shift (longer = comfier/slower-feeling; +10% vs 179)
    AutoShiftDipPower        = 0.80,  -- power during the dip. DEEPENED 0.92->0.80: the near-seamless dip made
                                      -- the script's shifts cost almost no time, netting every car ~0.3-0.6s
                                      -- faster than .meta. A deeper torque interruption restores the real
                                      -- shift cost (speed-invariant aim) while staying smooth/comfy.
    -- THROTTLE DAMPING — soften light/progressive throttle so comfort mode isn't
    -- jumpy off a light press (eases toward full by AutoThrottleDampMax). Torque-only.
    AutoThrottleDamp         = 0.85,  -- torque scale at the lightest throttle (1.0 = no damping)
    AutoThrottleDampMax      = 0.60,  -- by this throttle fraction, damping is fully released (full power)
    -- RPM-FLARE DAMP — keep revs steady/quiet by gently trimming torque once past a
    -- comfortable cruise rpm at light-to-mid throttle (prevents the rev flare).
    AutoRpmCalm              = 0.55,  -- above this rpm...
    AutoRpmCalmThrottle      = 0.70,  -- ...and below this throttle...
    AutoRpmCalmPower         = 0.90,  -- ...trim torque to this (steadier, quieter cruise)
    -- GENTLE LAUNCH — ease torque off the line so a standing start is smooth, not
    -- a lurch (comfort/family feel). Fades back to full power by AutoLaunchKmh.
    AutoLaunchKmh            = 16.0,  -- below this speed the launch ease applies, fading out by it (wider = comfier creep)
    AutoLaunchPower          = 0.82,  -- torque at a dead stop under throttle (eases UP to 1.0 by AutoLaunchKmh)

    -- MODE 3/4 — DCT (dual-clutch). Semi-automatic: GTA auto-shifts; a paddle
    -- (K/J) engages manual sub-mode; the clutch key returns to auto. No real
    -- clutch. Manual upshift near redline => boost. Over-rev downshift protection:
    -- illegal drop => double-beep + torque penalty + revs pinned to max, brief
    -- dip then auto-return (downshift locked during it).
    -- Per-mode PROFILES below: [3]=NORMAL DCT (DSG-like), [4]=SUPERCAR DCT
    -- (PDK / Ferrari F1-DCT — near-instant shifts, revs out higher, milder/shorter
    -- penalty, sharper boost; Strada-relaxed in AUTO, Corsa-aggressive on paddles).
    DctNotify = false,        -- notification when swapping DCT auto<->manual (OFF: no
                              -- gear-mode toasts per request; also the ~b~/~w~ GTA colour
                              -- codes don't render in ox_lib anyway)
    DctBeepStack = 2,         -- illegal-downshift beep loudness = stacked PlaySoundFrontend
                              -- calls per beep (no volume arg exists; integer only).
                              -- 4*0.6 = 2.4 -> 2 (the -40% the user asked; = the original level).
    DownshiftRevMatchMs = 240, -- DCT downshift window MINIMUM (ms): the rev-match blip leads, gear
                              -- engages ~this long after, so the blip isn't right on top of the change.

    -----------------------------------------------------------------
    -- TORQUE-CONVERTER FEEL (shared 2026-08-14). The single source of truth for the
    -- "torque converter" character used by BOTH the comfort auto (PUBLIC 0, internal
    -- mode 2) AND the paddle automatic (PUBLIC 2, internal mode 3 / DctProfiles[3]).
    -- Factored out so future TC-feel edits live in ONE place and the two never drift.
    --
    -- IMPORTANT — these are FEEL-path only. They shape the rpm NEEDLE + engine AUDIO
    -- + the SHAPE of the shift torque-dip. They do NOT change net torque-over-time:
    --   * the ramped dip is AREA-MATCHED to the old flat dip (same integral -> same 0-100),
    --   * slip-flare + rev-feed only paint rpm (vl_setRpmRaw), never drive force.
    -- What makes a TC feel like a TC: elastic rpm that runs AHEAD of the ratio under
    -- load then locks up, shift firmness that BUILDS with throttle (soft slur cruising,
    -- firm bang at WOT — the ZF-8HP-in-sport feel), gentle rpm ramps.
    TcFeel = {
        -- RAMPED DIP: ease torque 1.0 -> DipFloor -> 1.0 across the shift window instead
        -- of a flat cut. AREA-MATCHED so the effective average equals the old flat power.
        -- Shape: 'tri' (linear down/up) or 'smooth' (smoothstep). DipShapeArea is the
        -- ratio of a triangular dip's area to a flat dip of the same floor (0.5) — the
        -- code deepens the floor to compensate so net cut is identical. See gearbox.lua.
        RampedDip       = true,
        DipShape        = 'smooth',  -- 'tri' | 'smooth' (smoothstep is gentler at the edges)
        -- Elastic rpm SLIP-FLARE (needle/audio only). Under load the painted rpm runs a
        -- little AHEAD of the ratio-locked value (converter slip), collapsing to locked at
        -- cruise (lockup) or off throttle. Magnitude is small + capped below redline.
        SlipFlare       = true,
        SlipMax         = 0.06,      -- max rpm added ahead of locked (0..1 rpm scale) at full slip
        SlipThrGate     = 0.15,      -- below this throttle: no flare (coasting = locked/quiet)
        SlipLockupKmh   = 70.0,      -- at/above this speed the converter is "locked" -> flare fades to 0
        SlipEngageTau   = 0.18,      -- flare builds in this fast (s) — soft, rubbery
        SlipReleaseTau  = 0.10,      -- and collapses this fast on lift/lockup
        SlipRedlineCap  = 0.97,      -- never paint above this (protect audio from a fake over-rev wail)
        -- Gentle rev ramps on shifts (softer needle motion; audio only).
        RevFeedRate     = 0.55,      -- slower blip climb than a DCT (swells, doesn't snap)
        RevMatchBlip    = 1.05,      -- barely-there downshift flare (TC autos hardly blip)
    },

    DctProfiles = {
        -- ===== [3] AUTOMATIC (PADDLE) — torque-converter auto WITH paddles =====
        -- Rebranded 2026-08-14 from "Basic DCT". This is NOT a dual-clutch; it's a
        -- modern performance torque-converter automatic (ZF-8HP flavour) that ALSO
        -- takes paddle overrides. Runs on the internal DCT engine (mode 3) because
        -- paddle control needs script-owned gears, but its FEEL is pulled from the
        -- shared Config.Gearbox.TcFeel: elastic slip-flare rpm, load-variable shift
        -- firmness (soft slur cruising, firm bang at WOT), gentle blips. The window
        -- range below is WIDE on purpose — Task-#18 throttle-grounding lerps across it.
        -- PERFORMANCE-NEUTRAL: WOT accel must still equal the tuned handling.meta.
        [3] = {
            Label          = 'Automatic (Paddle)',
            ShiftDipMs     = 340,    -- fallback window (mid of the load-variable range below)
            -- SHIFT WINDOW absorbed from handling.meta gear-change rate, clamped to this
            -- range. WIDER than a DCT: a TC slurs softly at cruise (Max) and bangs firm
            -- at WOT (Min). Task-#18 lerps across this by live throttle.
            -- 2026-08-14: user "even on a redeye a paddle shift takes ~800-1200ms" — the 460ms paddle
            -- window is a FULL torque cut (mode 3 never uses handoff-retain), and on a heavy car the
            -- dead pedal + rpm re-climb after it feels like ~1s. A real ZF-8HP is ~180ms WOT / ~250ms
            -- paddle. Halved the paddle window and pulled the auto band down; still a TC (softer than a
            -- DCT), just no longer a second-long gap. Perf-neutral (RampedDip area-matched; shorter cut
            -- is never slower than the meta).
            ShiftMinMs     = 180,    -- firmest (WOT "bang" — converter locked, snappy) [was 300]
            ShiftMaxMs     = 430,    -- softest (light-throttle "slur" — relaxed but not a full second) [was 540]
            ShiftAbsorb    = 0.45,   -- fraction of the raw handling shift time carried through [was 0.57]
            PaddleShiftMs  = 250,    -- MANUAL paddle shift window — responsive TC-auto paddle [was 460]
            ShiftDipPower  = 0.82,   -- dip FLOOR. Shaped by TcFeel.RampedDip into an AREA-MATCHED
                                     -- swell (1.0->floor->1.0) so net 0-100 is identical to the flat cut.
            EngageTargetRpm= 0.55,   -- on engage / gear-pick, aim RPM near here
            -- GENUINE AUTO shift points (script-driven; GTA auto-shift disabled)
            -- 2026-09-07 (user: "mainly gear hold longer, not too much"): raised the part-throttle
            -- up-point 0.72->0.80 so the TC holds each gear noticeably longer before short-shifting
            -- (still below the DCT's 0.91 = stays a relaxed TC, just not eager to upshift). Kickdown
            -- nudged 0.55->0.60 (downshifts a touch more willingly) and dwell 450->380 (reacts a bit
            -- quicker) — both mild so it's still distinctly softer/lazier than the Sport/Super DCTs.
            AutoUpRpm      = 0.80,   -- part-throttle upshift: holds longer than before (0.72), still < DCT 0.91
            AutoUpRpmWOT   = 0.93,   -- flat-out: still holds to near redline (perf-neutral WOT)
            AutoDownRpm    = 0.32,   -- auto downshift when rpm drops below this
            AutoKickdownRpm= 0.60,   -- flooring it below this rpm => kickdown one gear (was 0.55, drops a hair sooner)
            AutoDwellMs    = 380,    -- anti-hunt: still calmer/lazier than a DCT (was 450), reacts a touch quicker
            -- Redline manual-upshift boost
            BoostRpm       = 0.80,
            BoostMult      = 1.1,
            BoostHoldMs    = 600,
            -- Over-rev downshift protection
            OverrevRpm     = 0.95,   -- projected rpm above this = illegal downshift
            OverrevStep    = 0.18,   -- proxy fallback rpm/gear when ratio not learned
            OverrevMinMs   = 280,    -- penalty dip 280-480ms
            OverrevMaxMs   = 480,
            OverrevPower   = 0.7,    -- torque cut during the penalty hold
            -- Downshift rev-match blip. These MIRROR Config.Gearbox.TcFeel (single source
            -- of truth for the TC character); gearbox.lua prefers TcFeel for mode 3 but we
            -- keep them here so the profile is self-describing. TC autos barely blip.
            RevFeedRate    = 0.55,   -- slow, swelling blip (not a DCT snap)
            RevMatchBlip   = 1.05,   -- barely-there flare (~5% past landing rpm)
            -- POST-UPSHIFT KICK. TC mode 3 is THROTTLE-GATED (code multiplies KickAmp by
            -- live throttle): ~0 at cruise (smooth family swap), a firm shove at WOT
            -- (converter lockup "bang"). Area-fair sine pulse => 0-100 unchanged.
            KickAmp        = 0.09,   -- peak amp AT WOT (scaled down by throttle below that)
            KickMs         = 90,     -- pulse length (softer/longer than a DCT)
        },
        -- ===== [4] SUPERCAR DCT (PDK / Ferrari 7DCT / Lambo LDF) =====
        [4] = {
            Label          = 'Sport DCT',
            ShiftDipMs     = 48,     -- fallback window (was 45; +6% slower)
            ShiftMinMs     = 37,     -- snappier than basic (clear gap below mode 3)
            ShiftMaxMs     = 95,
            ShiftAbsorb    = 0.42,   -- absorbs less of the lazy handling time -> stays sharp (was 0.40; +6%)
            PaddleShiftMs  = 200,    -- MANUAL paddle shift window (slower than auto, sharper than basic DCT)
            ShiftDipPower  = 0.90,   -- post-commit torque dip. DEEPENED 0.97->0.90 (speed comp; still sharp —
                                     -- the short window keeps it feeling near-instant).
            EngageTargetRpm= 0.6,
            -- AUTO shifts up only SLIGHTLY early vs manual (acceleration stays in,
            -- just a touch less aggressive than paddle): higher than basic's 0.80.
            AutoUpRpm      = 0.91,   -- HOLDS each gear longer in AUTO part-throttle (was 0.86 — band felt
                                     -- too tight/narrow; let the engine stretch further before upshifting).
                                     -- WOT untouched below so 0-100 stays perf-anchored.
            AutoUpRpmWOT   = 0.95,   -- flat-out it still screams to redline (accel preserved)
            AutoDownRpm    = 0.27,   -- hold the tall gear a touch lower before dropping (was 0.30 — widens
                                     -- the bottom of the usable band).
            AutoKickdownRpm= 0.60,
            AutoDwellMs    = 250,    -- anti-hunt dwell (supercar: sharper than basic)
            BoostRpm       = 0.85,   -- tighter window, sharper reward
            BoostMult      = 1.13,
            BoostHoldMs    = 500,
            OverrevRpm     = 0.97,   -- revs out higher before illegal
            OverrevStep    = 0.18,
            OverrevMinMs   = 180,    -- milder/shorter penalty 180-260ms
            OverrevMaxMs   = 260,
            OverrevPower   = 0.82,
            -- Moderate-to-strong rev-match blip on downshifts (sharper than basic,
            -- not as savage as F1).
            RevFeedRate    = 1.0,
            RevMatchBlip   = 1.22,   -- stronger flare than basic
            -- POST-UPSHIFT KICK. DCT = CONSTANT (fires full amp on EVERY upshift at any
            -- throttle — rigid dual-clutch bang, not throttle-gated like the TC). This is
            -- the "more fun/powerful" DCT differentiator. Area-fair sine => 0-100 unchanged.
            KickAmp        = 0.12,   -- firm, always-there shove (sharper than the TC's gated 0.09)
            KickMs         = 70,     -- crisp/short (DCT snap)
            -- ===== DUAL-CLUTCH FEEL (2026-08-14) — the traits that separate a real DCT
            -- from the TC (mode 3). All FOUR gate on the internal DCT tiers (gearMode >= 4)
            -- so mode 3 keeps its perf-neutral full-decouple shift. =====
            -- (1) SEAMLESS TORQUE HANDOFF: a DCT pre-selects the next gear on the second
            -- clutch, so an UPSHIFT is a near-instant HANDOFF, not a full disconnect. Instead
            -- of cutting drive to zero for the window, RETAIN this fraction of engine torque
            -- (clutch stays coupled) so the pull barely drops = genuinely FASTER than the old
            -- full-cut. This is the primary "DCT is quicker" lever. Throttle-scaled: WOT keeps
            -- the full fraction (seamless); light pedal eases back toward a civil shift. A
            -- gear-ratio nudge keeps a hair more on taller steps. Never a full pass-through.
            HandoffRetain  = 0.55,   -- fraction of torque kept through an upshift window AT WOT
            -- (5) UPSHIFT IGNITION-CUT FLUTTER: a real DCT cracks the ignition on the WOT bang —
            -- a fast micro-flutter on the needle right at the upshift. Audio/needle only (rides
            -- the kick window). FlutterAmp = rpm wobble, FlutterCycles = crackle count over KickMs.
            FlutterAmp     = 0.018,  -- small (Sport: crisp, not harsh)
            FlutterCycles  = 2.0,    -- 2 crackles across the kick pulse
            -- (6) DRY-CLUTCH JUDDER: a DCT shunts/grabs on 1<->2 low-speed creep (dry clutch
            -- take-up) where a TC glides. Small torque shudder below JudderKmh at part throttle.
            JudderAmp      = 0.05,   -- +/- torque wobble amplitude (subtle)
            JudderKmh      = 14.0,   -- only below this speed (creep)
            JudderHz       = 11.0,   -- shudder frequency
            -- (7) REDUCED CREEP: a DCT BITES off the line, it doesn't crawl like a TC. Trim
            -- standing-start creep torque a touch (part-throttle, near standstill) for a direct
            -- take-up. 1.0 = no change; <1 = less creep. Kept mild so it never stalls/bogs.
            CreepMult      = 0.82,
            CreepKmh       = 6.0,    -- only applies below this speed at light throttle
            -- (2) RIGID RPM SNAP: on upshift commit, snap the needle instantly to the exact
            -- new-gear rpm (audio/needle only — perf-safe). Opposite of the TC's slip float.
            RpmSnap        = true,
            -- (3) RACE MULTI-DOWNSHIFT: under hard braking, bang down through gears rapidly
            -- (PDK bam-bam-bam) by collapsing the anti-hunt dwell to this while brake > 0.6.
            MultiDownDwellMs = 90,   -- Sport: quick but not frantic
            -- (4) SHARPER DOWNSHIFT BARK: snap the rev-match blip straight to the flared
            -- target (a sharp throttle crack) instead of the TC's gentle swell.
            RevBark        = true,
        },
        -- ===== [5] F1 / HYPERCAR DCT — the most EXTREME tier. Race-car character:
        -- the fastest, sharpest shifts; near-flat power; the most aggressive
        -- rev-match; no protective auto-upshift (holds to the limiter); harsh,
        -- low-creep manners. Has an automatic (screams to redline before upshifting)
        -- BUT is typically run paddle-only via the DB flag (/setgear 5 1 1) for
        -- a true F1 feel — set paddleOnly=1 on the model and it never auto-shifts. =====
        [5] = {
            Label          = 'Super DCT',
            ShiftDipMs     = 16.3,   -- fallback window (was 16; +2% slower)
            ShiftMinMs     = 14.3,   -- the fastest of any tier (clear gap below supercar's 37)
            ShiftMaxMs     = 38.8,
            ShiftAbsorb    = 0.224,  -- barely absorbs lazy handling time -> always razor-sharp (was 0.22; +2%)
            ShiftDipPower  = 0.96,   -- near-flat power delivery (race character). Eased 0.995->0.96 for the
                                     -- speed-comp pass; window is ~15ms so the time cost stays tiny (still F1-sharp).
            EngageTargetRpm= 0.65,
            -- AUTO shift points: HOLDS gears to the limiter — no protective early
            -- upshift. Race-car feel even when the automatic IS used. (Most cars on
            -- this tier run paddle-only via the DB flag, so this is the fallback.)
            AutoUpRpm      = 0.97,   -- only upshifts right at the limiter in AUTO
            AutoUpRpmWOT   = 0.99,   -- flat-out: bounces off the limiter before it lifts
            AutoDownRpm    = 0.26,   -- only drops very late (engine-brakes hard first)
            AutoKickdownRpm= 0.65,
            AutoDwellMs    = 180,    -- anti-hunt dwell (F1: shortest, still prevents the double-fire skip)
            BoostRpm       = 0.90,   -- tightest, sharpest reward window
            BoostMult      = 1.14,
            BoostHoldMs    = 420,
            -- Near-zero downshift protection — trusts the driver completely.
            OverrevRpm     = 0.995,  -- almost never illegal (driver controls everything)
            OverrevStep    = 0.18,
            OverrevMinMs   = 60,     -- ultra-short protection 60-120ms (rarely triggers)
            OverrevMaxMs   = 120,
            OverrevPower   = 1.0,    -- NO speed penalty (>=1.0 skips the cut) — still bumps gear
            -- MOST aggressive downshift rev-match blip (sharp, instant, mechanical).
            RevFeedRate    = 1.15,
            RevMatchBlip   = 1.30,   -- biggest flare — race-car throttle blip
            -- RACE LOW-SPEED HARSHNESS: minimal creep, direct/harsh crawl (not for
            -- traffic). Bleeds torque below LowSpeedKmh at part-throttle.
            LowSpeedCut    = 0.45,   -- torque mult when crawling part-throttle (harsh)
            LowSpeedKmh    = 18.0,   -- applies below this speed
            -- POST-UPSHIFT KICK. DCT = CONSTANT (every upshift, any throttle). Super DCT
            -- kicks HARDEST + sharpest — the violent race-car bang. Area-fair sine pulse.
            KickAmp        = 0.15,   -- biggest shove of any tier (F1 slam)
            KickMs         = 55,     -- shortest/sharpest pulse (near-instant crack)
            -- ===== DUAL-CLUTCH FEEL (2026-08-14). Super DCT is the MOST seamless + most
            -- aggressive tier — a race PDK barely interrupts torque and downshifts violently. =====
            HandoffRetain    = 0.72,  -- keeps even MORE torque through the window (near-seamless race pull)
            RpmSnap          = true,  -- hardest, cleanest needle snap
            MultiDownDwellMs = 55,    -- F1: brutal rapid-fire downshift cascade under braking
            RevBark          = true,  -- savage throttle crack on downshift
            -- Super DCT signatures — harsher/more mechanical than Sport across the board.
            FlutterAmp       = 0.028, -- bigger ignition-cut crackle (race bang)
            FlutterCycles    = 3.0,   -- 3 crackles (more violent)
            JudderAmp        = 0.08,  -- stronger dry-clutch grab (race clutch, not for traffic)
            JudderKmh        = 16.0,
            JudderHz         = 13.0,
            CreepMult        = 0.70,  -- barely creeps — a race DCT wants throttle to move
            CreepKmh         = 7.0,
        },
    },

    -- CLASS FILTER (nil = all classes; or a { [0]=true, [1]=true } set)
    AllowedClasses = nil,

    -- CAR-CLASS SET — which GetVehicleClass() ids count as "a car" for the
    -- default-on rule. A car-class vehicle with NO hk_handling row defaults to
    -- mode 0 (our automatic). Non-car classes (moto/cycle/boat/heli/plane/rail)
    -- with no row stay raw GTA native. A DB row ALWAYS wins regardless of class.
    --   0 Compacts 1 Sedans 2 SUVs 3 Coupes 4 Muscle 5 SportsClassic 6 Sports
    --   7 Super 9 Offroad 12 Vans 18 Emergency 20 Commercial 22 OpenWheel
    CarClasses = {
        [0]=true, [1]=true, [2]=true, [3]=true, [4]=true, [5]=true, [6]=true,
        [7]=true, [9]=true, [12]=true, [18]=true, [20]=true, [22]=true,
    },

    -- NOTE (RE-FIXED 2026-08-15): the gear count is now FOLD-DETECTED, not meta-capped. The earlier
    -- meta-count cap (UseMetaGearCount) was wrong on the OTHER side — it cut GTA's clean transmission
    -- gear (911ts full-mod topped 300 instead of 315, i.e. modding made the car SLOWER). GTA's trans
    -- mod adds a REAL taller gear on this car; we keep every gear that extends top speed and cut only
    -- genuine folds (top speed drops). See DropFoldedGears/FoldGainEps and Gearbox_Enable.
}

-----------------------------------------------------------------
-- RPM DEBUG OVERLAY  (client/rpmdebug.lua)
-- Tiny on-screen readout for tuning the 0-1 RPM thresholds. GTA only
-- exposes GetVehicleCurrentRpm as a 0.00-1.00 float (there is NO native
-- for true engine RPM), so we show that raw value (what every threshold
-- actually uses) PLUS a DERIVED rpm = raw * Redline so you have an
-- intuitive 4-5 digit number to eyeball. Toggle with /rpmdebug.
-----------------------------------------------------------------
Config.RpmDebug = {
    Enabled       = true,        -- master gate (set false to compile it out of the loop)
    ShowByDefault = false,       -- off on spawn; /rpmdebug toggles (dev/tuning tool)
    Redline       = 8000,        -- the rpm the 1.00 value maps to (tune to taste — purely cosmetic)
    IdleApprox    = 0.20,        -- assumed idle floor, used for the "real rev %" line ((rpm-idle)/(1-idle))
    -- ENGINE READOUT (2026-08-14) — real-number engine panel on /handlingdbg. GTA has no real
    -- rpm/HP/torque (the engine is a force coefficient, not a simulated powertrain), so we:
    --   * map raw rpm (0..1, idle≈0.20) onto a believable rev range,
    --   * EMULATE power/torque from PHYSICS (F=m·a using the measured accel from the weight-transfer
    --     spine, P=F·v, τ=P/ω) — this is the REAL power the car is putting down this instant at the
    --     wheels, not a spec sheet. Labeled "meas" on the overlay so it's clear it's measured.
    EngineIdleRpm   = 900,       -- rpm shown at raw idle (raw ≈ IdleApprox)
    EngineRedlineRpm= 8000,      -- rpm shown at raw 1.00 (redline)
    DragGScale      = 0.10,      -- tuning scale for the ESTIMATED air-drag G (dragCoeff×v² is unitless in GTA; this maps it to a readable G)
    Command       = 'rpmdebug',  -- chat/console command to toggle the overlay
    PosX          = 0.015,       -- screen anchor (0-1), top-left of the block
    PosY          = 0.40,
    Scale         = 0.45,        -- text size
    -- /handlingdbg — the full two-column HANDLING STATUS SCREEN (pedals+steer+reverse on the left,
    -- drivetrain+gear+drift on the right; centre kept clear). Persistent while toggled on. Separate
    -- from the little /rpmdebug readout above. Alias: /throttledbg.
    HandlingDbgDefault = false,  -- show the status screen on spawn (dev/tuning tool)
}

-- Reads the gear from our gearbox export.
-----------------------------------------------------------------
Config.Speedo = {
    Enabled        = true,           -- master gate for the gauge
    UseGearboxGear = true,           -- read gear from our gearbox
    ShowByDefault  = false,          -- show gauge on spawn (was ShowSpeedometerByDefault)
    AutoToggleWithManual = true,     -- SINGLE source of truth for show/hide-with-manual.
                                     -- The gearbox reads THIS (no duplicate gearbox-side flag).
    DefaultSkin    = 'default',
}
