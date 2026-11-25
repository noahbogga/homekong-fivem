-----------------------------------------------------------------
-- hk-handling :: client/burnout.lua
-- [B*] Burnout / wheelspin + gear-1 rev limiter.
--
-- Built in stages (each independently testable):
--   STAGE 1 (this file, live): universal soft rev limiter for GEAR 1.
--     applyRevLimiter (gearbox.lua) only covers gears >= 2 on the auto/DCT
--     boxes and skips gear 1, so holding 1st (or spinning a burnout in 1st)
--     never bounces off a redline today. This fills that gap for ALL cars.
--   STAGE 2 (pending): 1st + handbrake + drift-mode BURNOUT — rears light up,
--     car creeps + tail slews, builds HK.launchCharge (torque surplus).
--   STAGE 3 (pending): wheelie rebased on HK.launchCharge hooking up.
--
-- SAFETY: all module state is file-local; the only shared write is HK.torqueMult
-- (the frame's torque multiplier, reset to 1.0 each frame top in main.lua and
-- consumed by vl_setTorque). No handling-field writes, no ApplyForceToEntity.
-- Called pcall-guarded from the main loop so a fault here can't kill the box.
-----------------------------------------------------------------

-- vehlib bindings (cache once — avoids per-frame wrapper-closure GC churn).
local vehlib = exports['hk-vehlib']
local function bind(fn) return function(...) return fn(nil, ...) end end
local vl_detectWheelspin = bind(vehlib.detectWheelspin)   -- (veh,thresh)->spinning,worstDiff(m/s)
local vl_setBurnout      = bind(vehlib.setBurnout)        -- SetVehicleBurnout(veh, bool) — forces driven wheels to spin+smoke
local vl_setHandbrake    = bind(vehlib.setHandbrake)      -- SetVehicleHandbrake(veh, bool) — the PHYSICAL e-brake
local vl_setReduceGrip   = bind(vehlib.setReduceGrip)     -- SetVehicleReduceGrip(veh, bool) — coarse grip cut
local vl_setTractionLoss = bind(vehlib.setTractionLossMult) -- override traction-loss mult (1.0 stock, higher = more slide); re-apply/frame
-- HANDLING-FIELD scaling (scales from cached native, idempotent, LAST WRITER WINS). Burnout runs
-- AFTER drift in the tick, so these override drift's grip fields for the burnout frames. This is the
-- PROVEN wheelspin lever (see TCOff_GripTick): drop the traction curves + raise low-speed loss.
local vl_scaleHandling   = bind(vehlib.scaleHandling)    -- (veh, field, mult) — native*mult
local vl_restoreField    = bind(vehlib.restoreField)     -- (veh, field) — back to cached native
local vl_getHandling     = bind(vehlib.getHandling)      -- (veh, field) — live value read
local vl_setHandling     = bind(vehlib.setHandling)      -- (veh, field, value) — absolute set (captures orig once)
local vl_setRpmRaw       = bind(vehlib.setRpmRaw)        -- (veh, 0..1) — PAINT the rev needle (zero drive force, perf-neutral). Free-rev uses this.

-- STAGE 1 STATE ------------------------------------------------
local limiterOn   = false   -- gear-1 limiter hysteresis latch
local flutterPhase = 0.0    -- bounce oscillator phase (rad)

-- STAGE 2 STATE ------------------------------------------------
-- HK.launchCharge (0..ChargeMax) is the stored TORQUE SURPLUS a burnout builds — the
-- energy that later HOOKS UP to lift the nose (Stage 3). Lives on HK so Stage 3
-- (wheelie) can read it. Reset here too. burnoutActive is published for the speedo/dbg.
HK.launchCharge = HK.launchCharge or 0.0
local burnoutForced = false   -- did we call SetVehicleBurnout(true) last frame? (so we clear it on release)
local wobblePhase   = 0.0      -- BUILD-phase tail-wag oscillator phase (rad)
local freeRevRpm    = 0.0      -- STEP-1 painted free-rev needle (0..1), integrated frame to frame
local freeRevFlutter = 0.0     -- STEP-1 redline-bounce oscillator phase (rad)
local freeRevOn     = false    -- STEP-1 redline-bounce hysteresis latch

-- WHEELSPIN SESSION STATE MACHINE (2026-08-16 rework — user gate spec) ----------------------------
--   OFF       — nothing; watch for the entry gesture.
--   ACTIVE    — a spin is live. Enters ONLY from near-standstill (<= EntryMaxKmh) with CAPS+W; once lit
--               it SUSTAINS while CAPS is held all the way up (grip returns 90->120, then a grippy slide
--               above). Re-pressing CAPS during a session stays wheelspin (drift underneath, not a new mode).
--   SLIDEOUT  — CAPS released while sliding: keep the grip drop and RAMP it back to native over SlideOutMs
--               (~1.5s) so the car keeps sliding a beat instead of snapping to grip. Re-press CAPS -> ACTIVE.
--   CONVERTED — a spacebar/handbrake TAP during a session hands off to normal drift; wheelspin stands down
--               and will NOT re-arm until the session fully ends (CAPS released) and a fresh <=15 entry.
local WS_OFF, WS_ACTIVE, WS_SLIDEOUT, WS_CONVERTED = 0, 1, 2, 3
local wsPhase          = WS_OFF
local wsSlideOutUntil  = 0     -- GetGameTimer() ms the slide-out ramp ends
local wsSlideOutSpin0  = 0.0   -- spin value at the instant CAPS was released (ramp starts here -> 0)
local wsGripOwned      = false -- did we override the grip curve fields this session? (restore-once)
local wsHbLast         = false -- handbrake (control 76) held last frame — for the tap edge (convert)

-- GRIP BASE: everything the session writes uses vl_scaleHandling, which multiplies the TRUE captured
-- native value (vehlib caches the original on first touch), so ramping the spin scalar -> 0 lands the
-- fields EXACTLY on native and restoreField hands the cache back cleanly. No manual native snapshot
-- needed. NOTE: while drift is on underneath, this overrides drift's own grip reduction with our
-- native*mult; when the session ends we restoreField to native (drift's Disable restore then no-ops
-- harmlessly). A drift continued straight out of a >120 wheelspin therefore runs on native traction
-- curves rather than drift's slightly-reduced ones — intended (grip has "returned" by then).

-- Restore the grip curve fields the session overrode back to the native baseline and release vehlib's
-- cache ownership (restoreField), so drift/others can re-own them cleanly. Called on any session end.
local function wsReleaseGrip(veh)
    -- Drop the arbiter claim on the 3 shared curve fields (committer restores them when nobody claims).
    if HK.gripRelease then HK.gripRelease('burnout') end
    if veh and veh ~= 0 and DoesEntityExist(veh) then
        -- fTractionBiasFront is NOT arbiter-owned — always our direct restore.
        vl_restoreField(veh, 'fTractionBiasFront')
        -- If the arbiter was OFF we wrote the curves directly; restore them too (harmless no-op if the
        -- arbiter already handed them back / never captured them under this owner).
        if not (Config.GripArbiter and Config.GripArbiter.Enabled ~= false) then
            vl_restoreField(veh, 'fTractionCurveMax')
            vl_restoreField(veh, 'fTractionCurveMin')
            vl_restoreField(veh, 'fLowSpeedTractionLossMult')
        end
    end
    wsGripOwned = false
end

-- LOW-SPEED YAW INJECTION (2026-08-16 fix for "steering just translates the whole car, nose won't turn").
-- Below ~15 km/h there is almost no lateral tyre force, so a steer input can't generate a yaw moment
-- through grip — the car slides bodily sideways. A burnout/donut needs the rotation INJECTED. Writes ONLY
-- the car-frame yaw rate (blended toward a target), preserving pitch/roll exactly via the car's own basis
-- (same technique as drift's setYaw). Skips near-flip and on hard pitch/roll bumps so it never clobbers
-- the suspension's own damping. desiredLocalYaw in rad/s (+ = counter-clockwise = left), blend 0..1.
local function wsSetYaw(veh, desiredLocalYaw, blend)
    local lav = GetEntityRotationVelocity(veh)   -- LOCAL (pitchRate, rollRate, yawRate)
    if math.abs(lav.x) > 0.6 or math.abs(lav.y) > 0.6 then return end  -- bump frame: let physics damp it
    local m1, m2, m3 = GetEntityMatrix(veh)
    local fwd = GetEntityForwardVector(veh)
    local function dot(a, b) return a.x*b.x + a.y*b.y + a.z*b.z end
    local cand = { m1, m2, m3 }
    local fi, best = 1, math.abs(dot(m1, fwd))
    for i = 2, 3 do local d = math.abs(dot(cand[i], fwd)); if d > best then best, fi = d, i end end
    local forwardV = cand[fi]
    local r1, r2
    for i = 1, 3 do if i ~= fi then if not r1 then r1 = cand[i] else r2 = cand[i] end end end
    local upV, rightV
    if math.abs(r1.z) >= math.abs(r2.z) then upV, rightV = r1, r2 else upV, rightV = r2, r1 end
    if math.abs(upV.z) < 0.35 then return end   -- near-flip: don't fight it
    local newYaw = lav.z + (desiredLocalYaw - lav.z) * (blend or 0.15)
    local wx = lav.x*rightV.x + lav.y*forwardV.x + newYaw*upV.x
    local wy = lav.x*rightV.y + lav.y*forwardV.y + newYaw*upV.y
    local wz = lav.x*rightV.z + lav.y*forwardV.z + newYaw*upV.z
    SetEntityAngularVelocity(veh, wx, wy, wz)
end

-- Hand the grip fields back to DRIFT'S held values (the snapshot we took at engage), NOT to native —
-- native is drift's to restore at DriftMode_Disable. Absolute writes preserve vehlib's native cache so
-- Turn the native STATIONARY burnout OFF once, on the transition out of a planted brake-stand. Grip-field
-- restore is owned by wsReleaseGrip (called by the state machine on session end), NOT here.
local function clearBurnout(veh)
    if veh and veh ~= 0 and DoesEntityExist(veh) then
        if burnoutForced then vl_setBurnout(veh, false) end
    end
    burnoutForced = false
end

-- Reset on vehicle swap / disable so a new car starts clean.
function Burnout_Reset()
    limiterOn    = false
    flutterPhase = 0.0
    freeRevRpm    = 0.0
    freeRevFlutter = 0.0
    freeRevOn     = false
    HK.freeRevActive = false
    HK.revFlutterPhase = 0.0        -- three-state rev model (gearbox.lua) — clear its bounce state
    HK.revBounceOn     = false
    HK.burnoutLimiterOn = false
    if HK.vehicle and HK.vehicle ~= 0 and DoesEntityExist(HK.vehicle) then
        if burnoutForced then vl_setBurnout(HK.vehicle, false) end
        -- Restore any grip fields the session overrode back to native (restoreField). vl_scaleHandling
        -- captured the true native value, so this is a clean hand-back; drift (if on) re-owns next frame.
        wsReleaseGrip(HK.vehicle)
    end
    burnoutForced = false
    wsPhase = WS_OFF
    wsGripOwned = false
    wsHbLast = false
    wsSlideOutUntil = 0
    HK._wsSpinLast = 0.0
    HK.launchCharge = 0.0
    HK.burnoutActive = false
end

-----------------------------------------------------------------
-- STEP 1: PLAIN W+S FREE-REV — MOVED (2026-08-15) to gearbox.lua.
-- The free-rev gesture AND the new three-state rev model (soft / hard / loaded) now live in
-- HK.RevAgainstThrottle_Tick (gearbox.lua), next to applyRevLimiter + the flywheel sim — it's
-- engine behavior, not a burnout thing, and there it reads the box's own neutral/clutch/mode
-- locals directly. This function is retired to a no-op stub so no stale call site can double-paint
-- the needle; it's kept only so an old build's reference can't error. burnout.lua now owns ONLY the
-- drift-key tire-fry (Burnout_WheelspinTick) + the gear-1 limiter (Burnout_Tick).
-----------------------------------------------------------------
function Burnout_FreeRevTick(veh, state, dt)
    HK.freeRevActive = false
    freeRevOn  = false
    return false
end

-- (legacy free-rev body removed; see HK.RevAgainstThrottle_Tick in gearbox.lua)
--[==[ DEAD — retained history only
    local cfg  = Config.Burnout
    local fr   = cfg and cfg.FreeRev
    local thr   = math.max(GetControlNormal(0, 71), GetDisabledControlNormal(0, 71))
    local brk   = HK._pedalBrake or math.max(GetControlNormal(0, 72), GetDisabledControlNormal(0, 72))
    local kmh   = state.speedKmh or 0.0
    local drift = (HK.driftMode == true)

    -- GATE: W + S both held, NO drift key (drift+W+S is Step 2's wheelspin), near standstill,
    -- on the ground. NOT drift is what keeps this and the wheelspin mutually exclusive. A pure EV
    -- has no engine to rev — painting a fake ICE scream would be wrong, so skip it (HK.gbIsEV set
    -- by the gearbox at Enable).
    -- NOTE (2026-08-15): the standalone W+S free-rev + the new three-state rev model were MOVED to
    -- gearbox.lua (RevAgainstThrottle_Tick, next to applyRevLimiter + the flywheel sim — that's the
    -- engine side). This tick is now DISABLED here to avoid double-painting the needle; it stays as
    -- a stub only so an old build's call site can't error. burnout.lua keeps ONLY the drift-key
    -- tire-fry (Burnout_WheelspinTick) + the gear-1 limiter (Burnout_Tick).
    do
        freeRevOn  = false
        freeRevRpm = state.rpm or 0.0
        return false
    end

]==]

-----------------------------------------------------------------
-- STAGE 1: GEAR-1 SOFT REV LIMITER
-- Mirrors the gearbox limiter's redline/hysteresis but ONLY in gear 1 (which the
-- gearbox limiter skips). Cuts HK.torqueMult with a flutter so the engine bounces
-- off the cut — no self-brake (gear 1 just bounces, like a real manual). This is
-- also the ceiling a burnout/free-rev pushes against.
-----------------------------------------------------------------
function Burnout_Tick(veh, state, dt)
    local cfg = Config.Burnout
    HK.burnoutLimiterOn = false

    local gear = state.gear or 0
    local rpm  = state.rpm or 0.0
    local thr  = state.effThrottle or state.throttle or 0.0
    -- STAGE 1 DIAG: publish every frame so /handlingdbg proves the module is loaded
    -- and shows the exact gate inputs (why the limiter is / isn't firing).
    HK.dbgBurnout = { loaded = true, g = gear, rpm = rpm, thr = thr,
                      air = IsEntityInAir(veh), on = false }

    if not cfg or cfg.Enabled == false then limiterOn = false; return end

    local lcfg = cfg.Limiter
    if not lcfg or lcfg.Enabled == false then limiterOn = false; return end

    -- Only gear 1 (gearbox limiter owns >= 2, neutral free-rev is owned by the
    -- gearbox flywheel sim). Off-throttle = no fight.
    -- AIRBORNE GATE: use IsEntityInAir (WHOLE car off the ground), NOT onAllWheels.
    -- A hard launch in a RWD spins/unloads the rear wheels → onAllWheels goes false
    -- while the car is firmly on the ground — that's the launch/burnout case where we
    -- MOST want the limiter to bounce. onAllWheels==false only means "a wheel is up"
    -- (spinning), not "airborne". Same lesson the wheelie code already applies.
    local trulyAirborne = IsEntityInAir(veh)
    if gear ~= 1 or thr < (lcfg.MinThrottle or 0.45) or trulyAirborne then
        limiterOn = false
        HK.dbgBurnout.man = nil; HK.dbgBurnout.spin = nil
        return
    end

    -- WHO GETS THE GEAR-1 LIMITER (2026-08-14): NOT every car that brushes gear-1
    -- redline. An AUTO/paddle box (e.g. 911ts on paddle) hits gear-1 redline for a
    -- moment on a CLEAN hooked-up launch then upshifts itself — it shouldn't bounce.
    -- The limiter is only meaningful when the gear is genuinely PINNED at redline:
    --   (a) a MANUAL/sequential box holding 1st (real money-shift-protection cut), OR
    --   (b) the wheels are actually SPINNING (burnout / wheelspin launch) on any box.
    -- Both are box-agnostic (no car-name lists). vl_detectWheelspin returns the worst
    -- wheel-vs-ground slip (m/s); a clean hookup reads near 0, a spin reads high.
    local isManual = (HK.gbManual == true)
    local spinning, slipMs = vl_detectWheelspin(veh, lcfg.SpinThreshold or 2.5)
    HK.dbgBurnout.man = isManual
    HK.dbgBurnout.spin = spinning
    HK.dbgBurnout.slip = slipMs   -- raw worst wheel-vs-ground slip (m/s) for tuning SpinThreshold
    if not (isManual or spinning) then
        limiterOn = false
        return
    end

    -- GROUND-TRUTH SPEED CAP (2026-08-14 — the "gear 1 leaks past redline" fix). Like the gearbox
    -- limiter for gears 2+, the rpm read here is DE-BIASED/painted on manual, so rpm can sit under
    -- redline while the needle shows the cut → the rpm trip never fires and gear 1 accelerates past its
    -- true ratio top. The gear RATIO + mfv are un-paintable physics: the speed where gear 1 hits redline
    -- is redline * K * mfv / ratio (identical basis to applyRevLimiter's capKmh). Trip the bounce on
    -- EITHER rpm OR speed so a painted-low rpm can't let the car leak through. Gated on SpeedBounce.
    local redline  = lcfg.Redline or 0.985
    local reengage = lcfg.ReengageRpm or 0.965
    local capKmh
    if lcfg.SpeedBounce ~= false then
        local K   = (Config.Gearbox and Config.Gearbox.RatioSeedK) or 1.199
        local mfv = GetVehicleHandlingFloat(veh, 'CHandlingData', 'fInitialDriveMaxFlatVel')
        local ratio = GetVehicleGearRatio(veh, 1)
        if ratio and ratio > 0 and mfv and mfv > 0 then
            capKmh = redline * K * mfv / ratio
        end
    end
    local kmh = state.speedKmh or 0.0
    local dipKmh = lcfg.DipKmh or 6.0

    -- Hysteresis: engage at redline OR the speed cap; release once BOTH drop back (rpm below ReengageRpm
    -- AND speed below cap-dip) so it flutters instead of locking solid.
    local overRpm   = rpm >= redline
    local overSpeed = capKmh and kmh >= capKmh
    if overRpm or overSpeed then
        limiterOn = true
    elseif rpm < reengage and (not capKmh or kmh <= capKmh - dipKmh) then
        limiterOn = false
    end
    HK.dbgBurnout.g1cap = capKmh
    if not limiterOn then return end

    HK.burnoutLimiterOn = true
    if HK.dbgBurnout then HK.dbgBurnout.on = true end

    -- BRAKE PRIORITY (2026-08-14): the gear-1 limiter flutters torque between the cut and FULL power
    -- (bounce = 1.0 half the time). Holding throttle at the gear-1 rev limit and pressing the brake then
    -- fights those full-power halves → the car won't slow (gear 1 was the "doesn't slow at the limiter"
    -- case; gears 2+ are handled by applyRevLimiter's own brake priority). While genuinely braking, kill
    -- the bounce and hold the FULL cut so the brakes win — same rule as the gearbox limiter. Physical S
    -- key (HK._pedalBrake) is the reliable read (immune to any DisableControlAction / pedal-model swap).
    local brakeSig = HK._pedalBrake or state.effBrake or state.brake or 0.0
    local braking  = (lcfg.BrakePriority ~= false) and (brakeSig >= (lcfg.BrakePriorityMin or 0.15))
    if braking then
        HK.torqueMult = HK.torqueMult * (lcfg.CutMult or 0.0)
        return
    end

    -- Flutter the cut so it bounces audibly/visually off the limiter.
    flutterPhase = flutterPhase + (dt * (lcfg.FlutterHz or 20.0) * math.pi * 2.0)
    if flutterPhase > math.pi * 2.0 then flutterPhase = flutterPhase - math.pi * 2.0 end

    -- Oscillate between full cut (CutMult) and full power for the bounce. No
    -- self-brake — gear 1 just bounces off the fuel-cut.
    -- SPEED-CAP OVERRIDE: if we're OVER the ground-truth speed cap (the painted-rpm leak case), the
    -- flutter's full-power halves would let the car keep creeping past the cap. So while genuinely
    -- over-speed, hold the FULL cut (no power halves) — bounce off the cap cleanly instead of leaking.
    -- The rpm-only bounce (at/under cap, rpm at redline) keeps its audible flutter unchanged.
    local overCapNow = capKmh and (kmh >= capKmh)
    local bounce
    if overCapNow then
        bounce = (lcfg.CutMult or 0.0)
    else
        bounce = (math.sin(flutterPhase) > 0.0) and (lcfg.CutMult or 0.0) or 1.0
    end
    HK.torqueMult = HK.torqueMult * bounce
end

-----------------------------------------------------------------
-- STAGE 2: BURNOUT / WHEELSPIN  (1st gear + handbrake + drift mode)
--
-- The deliberate, on-demand wheelspin. GATE: gear 1 (or 0/reverse-not) + handbrake
-- held + drift mode ON + near standstill. WHY those three:
--   * DRIFT MODE already kills TC+ABS and drops the grip curves — the real-world
--     "traction control OFF" prerequisite for any burnout. It also OWNS the three
--     traction-curve fields every frame, so burnout must NOT write grip (writer
--     conflict); it works purely through TORQUE on top of drift's dropped grip.
--   * HANDBRAKE is the deliberate gesture. In drift mode the physical handbrake is
--     disabled (main.lua), so the rears are NOT locked — they SPIN and the car can
--     CREEP FORWARD: a rolling burnout, not a static brake stand. state.handbrake
--     still reads the key (vehlib robust read), so it's a clean trigger.
--
-- WHAT IT DOES while held:
--   (1) FORCE THE SPIN: SetVehicleBurnout(veh,true) breaks the driven wheels loose
--       (spin + smoke) — the native purpose-built for this; a torque multiplier alone
--       can't overcome GTA's grip. Cleared with setBurnout(false) the frame it ends.
--   (2) CHARGE: integrate HK.launchCharge up while the wheels are actually spinning —
--       this is the stored surplus Stage 3 hooks up into a nose lift. Bigger/longer
--       spin = more charge. Decays when not spinning (surplus bleeds off).
-- Drivetrain-aware: RWD gets the full effect; FWD/AWD get less (driveline fights it).
--
-- This runs AFTER Burnout_Tick (limiter) in the same frame, both before vl_setTorque.
-----------------------------------------------------------------
function Burnout_WheelspinTick(veh, state, dt)
    local cfg = Config.Burnout
    local bcfg = cfg and cfg.Wheelspin

    -- UNIFIED (2026-08-14 REBUILD): the DRIFT+W standstill wheelspin/burnout is now owned by
    -- drift.lua regime A (DriftMode_Tick runs BEFORE this and drives the car forward through the
    -- spin + publishes HK.burnoutActive). While the drift key is held, this tick fully stands down —
    -- do NOT touch HK.burnoutActive (regime A set it this frame) and do NOT write grip/torque here.
    -- Clear our own session state once so nothing lingers when drift later releases.
    if HK.driftMode == true then
        if wsPhase ~= WS_OFF or wsGripOwned then
            clearBurnout(veh); wsReleaseGrip(veh)
            wsPhase = WS_OFF; HK._wsSpinLast = 0.0
        end
        return
    end

    HK.burnoutActive = false
    if not cfg or cfg.Enabled == false or not bcfg or bcfg.Enabled == false then
        clearBurnout(veh)
        -- bleed any residual charge when the feature is off
        if (HK.launchCharge or 0.0) > 0.0 then
            HK.launchCharge = math.max(0.0, HK.launchCharge - dt / (bcfg and bcfg.DecayTau or 0.5))
        end
        return
    end
    -- TRANSIENT-INVALIDITY GUARD (same as launchtraction.lua): a player encounter can leave veh/state
    -- invalid for a frame; without this the first native throws, main.lua latches HK._burnoutWsErr, and the
    -- gesture stays DEAD all session. Bail cleanly on a bad frame + drop any stale state so nothing lingers.
    if not veh or veh == 0 or not DoesEntityExist(veh) or not state then
        clearBurnout(veh); wsReleaseGrip(veh)
        wsPhase = WS_OFF; HK._wsSpinLast = 0.0
        return
    end

    local gear = state.gear or 0
    local kmh  = state.speedKmh or 0.0
    -- THROTTLE read: the raw physical W (immune to the DisableControlAction(71) that fires at a
    -- forward-gear stop — the exact reason state.effThrottle can read ~0 at idle and the gesture never
    -- armed "in gear at idle"). Same robust read burnoutGestureLive uses. Falls back to state values.
    local thrRaw = math.max(GetControlNormal(0, 71), GetDisabledControlNormal(0, 71))
    local thr  = math.max(thrRaw, state.effThrottle or 0.0, state.throttle or 0.0)
    local brk  = state.effBrake or state.brake or 0.0
    local drift = (HK.driftMode == true)
    -- NEUTRAL GUARD (2026-08-16): do NOT use state.gear >= 1 — at a DEAD STOP GTA reports gear 0 (so
    -- an in-gear burnout never armed) and in LOGICAL neutral GTA momentarily engages gear 1 (so neutral
    -- WRONGLY armed and the wheels crept slowly with no drive torque). Both are the known unreliable
    -- native-gear reading (see gearbox.lua ~4120). Use the box's own logical-neutral flag instead: a
    -- burnout needs the driveline COUPLED (a real forward gear), so block neutral + clutch explicitly.
    local inNeutral = (HK.gbInNeutral == true) or (HK.gbClutchHeld == true) or HK.inReverseGear == true

    -- ENTRY window: wheelspin arms ONLY from near-standstill (kmh <= EntryMaxKmh, 15). S = optional
    -- PLANTED modifier (static brake-stand), read via HK._pedalBrake below (control 72 is disabled at a
    -- standstill by the reverse rework). sustainMax kept for the debug/limit references below.
    local entryMax   = bcfg.EntryMaxKmh or 15.0
    local sustainMax = bcfg.MaxSpeedKmh or 120.0

    -- STATE MACHINE (2026-08-16 rework — user gate spec). Because +hk_drift is HOLD-to-drift, releasing
    -- CAPS fires DriftMode_Disable which restores grip THAT frame — so a persistent slide can only live in
    -- THIS tick (runs every frame regardless of drift). Phases: OFF / ACTIVE / SLIDEOUT / CONVERTED.
    --   ENTRY  — ACTIVE arms ONLY from near-standstill (kmh <= EntryMaxKmh, 15) with CAPS + real W, coupled,
    --            grounded. Above the entry speed, holding CAPS is just a NORMAL drift (never a wheelspin).
    --   SUSTAIN— once ACTIVE, hold it while CAPS is down all the way up; grip returns over GripReturnLoKmh
    --            ->HiKmh (90->120) so the loose spin tightens into a grippy slide; stays a slide above.
    --   SLIDEOUT (user: "on release, slowly ramp back to normal grip") — CAPS released while sliding: keep
    --            the current spin and ramp it to 0 over SlideOutMs (~1.5s) so the car slides a beat longer
    --            instead of snapping to grip. Re-pressing CAPS during ACTIVE or SLIDEOUT resumes ACTIVE.
    --   CONVERT— a spacebar/handbrake TAP during a session hands off to normal drift (drift's already on
    --            underneath); wheelspin stands down and will NOT re-arm until CAPS is released + a fresh
    --            <=15 entry. Prevents bouncing back into wheelspin mid-drift.
    local now      = GetGameTimer()
    local capsHeld = drift                                    -- +hk_drift is hold-to-drift, so drift==CAPS held
    local grounded = not IsEntityInAir(veh)
    local coupled  = not inNeutral
    -- Handbrake TAP edge (convert to drift). Control 76 is force-disabled every frame (main.lua), so read
    -- the DISABLED state — same reason drift.lua reads IsDisabledControlPressed(0,76).
    local hbNow    = IsDisabledControlPressed(0, 76)
    local hbTap    = hbNow and not wsHbLast
    wsHbLast       = hbNow

    -- Session END. HARD KILL only when genuinely AIRBORNE (whole car off the ground) — a car in the air
    -- shouldn't be dragged, and there's a global airborne cutoff besides. Loss of drivetrain COUPLING
    -- (the transient neutral/clutch blip during a 1->2 upshift mid-drag, or a real shift to neutral) must
    -- NOT snap grip back — that was the "drag finishes and grip returns INSTANTLY, rpm drops, wheels stop,
    -- car lurches forward on a weird force" bug. Route coupled-loss through SLIDEOUT so grip always RAMPS
    -- back over SlideOutMs; a re-couple while still holding CAPS resumes the spin next frame (the resume
    -- below also requires coupled, so a genuine neutral just rides the ramp out cleanly).
    if wsPhase ~= WS_OFF and not grounded then
        clearBurnout(veh); wsReleaseGrip(veh)
        wsPhase = WS_OFF
    elseif wsPhase == WS_ACTIVE and not coupled then
        wsPhase = WS_SLIDEOUT
        wsSlideOutUntil = now + (bcfg.SlideOutMs or 1500)
        wsSlideOutSpin0 = HK._wsSpinLast or 1.0
    end

    -- CONVERT: a handbrake tap during ACTIVE/SLIDEOUT hands the slide to normal drift and locks wheelspin
    -- out for the rest of this CAPS hold. Grip goes back to native (restoreField); drift re-owns it next
    -- frame with its own values (it's still on underneath while CAPS is held).
    if (wsPhase == WS_ACTIVE or wsPhase == WS_SLIDEOUT) and hbTap then
        clearBurnout(veh); wsReleaseGrip(veh)
        wsPhase = WS_CONVERTED
    end

    -- ENTRY / RESUME.
    if wsPhase == WS_OFF then
        if capsHeld and coupled and grounded
           and thr >= (bcfg.MinThrottle or 0.55) and kmh <= entryMax then
            wsPhase = WS_ACTIVE
        end
    elseif wsPhase == WS_SLIDEOUT then
        -- Resume the spin only if CAPS is (still) held AND the driveline is coupled again. Requiring
        -- coupled here is what stops a real neutral+CAPS from ping-ponging ACTIVE<->SLIDEOUT every frame
        -- (which would reset the ramp timer forever and never hand grip back). A momentary upshift blip
        -- re-couples within a frame or two, so a genuine drag resumes seamlessly.
        if capsHeld and coupled then wsPhase = WS_ACTIVE end
    elseif wsPhase == WS_CONVERTED then
        if not capsHeld then wsPhase = WS_OFF end            -- release CAPS to clear the drift lock
    end

    -- CAPS released while ACTIVE -> begin the SLIDEOUT ramp (grip eases back over SlideOutMs).
    if wsPhase == WS_ACTIVE and not capsHeld then
        wsPhase = WS_SLIDEOUT
        wsSlideOutUntil = now + (bcfg.SlideOutMs or 1500)
        wsSlideOutSpin0 = HK._wsSpinLast or 1.0             -- ramp from the spin level we were sliding at
    end

    HK.dbgBurnout = HK.dbgBurnout or {}
    HK.dbgBurnout.boPhaseN = wsPhase
    HK.dbgBurnout.boChg = HK.launchCharge or 0.0
    HK.dbgBurnout.boDrift = drift
    HK.dbgBurnout.boThr   = thr
    HK.dbgBurnout.boGear  = gear
    HK.dbgBurnout.boNeut  = inNeutral
    HK.dbgBurnout.boKmh   = kmh

    -- Not in a spin-producing phase -> stop everything, bleed charge, done.
    if wsPhase ~= WS_ACTIVE and wsPhase ~= WS_SLIDEOUT then
        HK._wsSpinLast = 0.0
        clearBurnout(veh)
        if wsGripOwned then wsReleaseGrip(veh) end
        if (HK.launchCharge or 0.0) > 0.0 then
            HK.launchCharge = math.max(0.0, HK.launchCharge - dt / (bcfg.DecayTau or 0.5))
        end
        return
    end

    HK.burnoutActive = true

    -- DRIVETRAIN SCALE: RWD is the headline; FWD/AWD get less (driveline fights a
    -- stationary spin). HK.dbgDrive.class is set by drivetrain.lua ('rwd'/'awd'/'fwd').
    local cls = (HK.dbgDrive and HK.dbgDrive.class) or 'rwd'
    local dtScale = (bcfg.DriveScale and bcfg.DriveScale[cls]) or 1.0
    local planted = false   -- (planted brake-stand computed below from HK._pedalBrake)

    vl_setHandbrake(veh, false)       -- unlock the axle so the driven wheels can spin

    -- SPIN SCALAR (0..1) — the single intensity lever. Everything below scales off it, and every grip
    -- field is written via vl_scaleHandling (native * mult), so spin -> 0 lands EXACTLY on native.
    --   base 1.0 while ACTIVE below the grip-return band.
    --   GRIP-RETURN TAPER (90->120): user "90-120 is the max wheelspin moment — decrease loose spin, more
    --     grip". Smoothstep spin DOWN across GripReturnLoKmh->HiKmh so the loose spin tightens into a
    --     grippy slide; above HiKmh spin floors at GripReturnFloor (still a slide, not full grip).
    --   SLIDEOUT RAMP (user "on release slowly ramp back to normal grip"): in WS_SLIDEOUT, override spin
    --     with a linear ramp from the level we released at down to 0 over SlideOutMs.
    --   THROTTLE MODULATION: full W = slidy; feathered = more controllable. Multiplies spin by
    --     SlideFloor..1.0. (In SLIDEOUT the throttle is usually off; the ramp owns it, so skip throttle mod.)
    local loKmh   = bcfg.GripReturnLoKmh or 90.0
    local hiKmh   = bcfg.GripReturnHiKmh or 120.0
    local gripFloor = bcfg.GripReturnFloor or 0.15
    local spin = 1.0
    if kmh > loKmh then
        local t = (kmh - loKmh) / math.max(hiKmh - loKmh, 1e-4)
        if t < 0.0 then t = 0.0 elseif t > 1.0 then t = 1.0 end
        local s = t * t * (3.0 - 2.0 * t)                       -- smoothstep 0..1
        spin = 1.0 - (1.0 - gripFloor) * s                      -- 1.0 -> gripFloor across the band
    end
    if wsPhase == WS_SLIDEOUT then
        local rem = wsSlideOutUntil - now
        local frac = rem / math.max(bcfg.SlideOutMs or 1500, 1)
        if frac < 0.0 then frac = 0.0 elseif frac > 1.0 then frac = 1.0 end
        spin = math.min(spin, wsSlideOutSpin0 * frac)           -- ramp down to 0; never exceed the taper
        if rem <= 0 then
            -- ramp done: hand grip back to native, end the session cleanly.
            clearBurnout(veh); wsReleaseGrip(veh)
            wsPhase = WS_OFF
            HK._wsSpinLast = 0.0
            HK.burnoutActive = false
            HK.dbgBurnout.boPhaseN = WS_OFF
            return
        end
    else
        local slideFloor = bcfg.SlideFloor or 0.35
        local slidiness  = slideFloor + (1.0 - slideFloor) * math.min(1.0, math.max(0.0, thr))
        spin = spin * slidiness
        HK.dbgBurnout.boSlidy = slidiness
    end
    if spin < 0.0 then spin = 0.0 elseif spin > 1.0 then spin = 1.0 end
    HK._wsSpinLast = spin
    HK.dbgBurnout.boSpin = spin

    local eff = dtScale * spin   -- drivetrain-scaled intensity used by every effect below

    -- PLANTED brake-stand (S / footbrake held) — GTA's STATIONARY burnout, pins the car by design.
    -- Read HK._pedalBrake (raw scan code): control 72 is permanently disabled at a standstill by the
    -- reverse rework, so state.brake reads 0 with S held. Only in ACTIVE (a slide-out shouldn't re-plant).
    local brkPlant = HK._pedalBrake or brk or 0.0
    planted = (wsPhase == WS_ACTIVE) and (brkPlant >= (bcfg.BrakeGate or 0.5)) and (kmh <= entryMax + 5.0)
    if planted then
        if dtScale > 0.0 then vl_setBurnout(veh, true); burnoutForced = true end
        HK.dbgBurnout.boInBurnout = IsVehicleInBurnout and IsVehicleInBurnout(veh) or nil
    else
        if burnoutForced then vl_setBurnout(veh, false); burnoutForced = false end
    end
    HK.dbgBurnout.boPhase = planted and 'brakestand' or 'rolling'

    -- OVERPOWER: extra engine torque so the driven wheels spin FASTER than grip (the fry + the forward
    -- drag). Scaled by eff so it eases with the grip-return taper, slide-out ramp AND throttle.
    local spinMult = bcfg.SpinTorqueMult or 2.5
    HK.torqueMult = HK.torqueMult * (1.0 + (spinMult - 1.0) * eff)

    -- DRAG LAUNCH (rolling only): drop the traction curves (native * mult) so the driven wheels break
    -- loose + smoke but keep PARTIAL kinetic grip — the overpower then drags the car forward through the
    -- spin. vl_scaleHandling always multiplies the CAPTURED NATIVE value, so composing off native is safe
    -- even with drift on underneath (our write wins this frame; on session end restoreField hands native
    -- back and drift re-owns it next frame). wsGripOwned latches so we restore exactly once.
    if not planted and eff > 0.0 then
        local mxMult = 1.0 - (bcfg.GripMaxReduction or 0.30) * eff        -- peak grip down
        local mnMult = 1.0 - (bcfg.GripMinReduction or 0.45) * eff        -- breakaway grip down (the drag tell)
        local spMult = 1.0 + (bcfg.GripLowSpeedSpinAdd or 0.80) * eff     -- low-speed fry up
        -- GRIP-FIELD ARBITER (2026-08-16): CLAIM the three shared curve fields (burnout = highest wheelspin
        -- priority) so our restore can't be raced by launch-traction / TC-off. Committer writes once.
        -- fTractionBiasFront is NOT shared — we still manage it directly here. Kill-switch falls back to a
        -- direct write (identical to before).
        if Config.GripArbiter and Config.GripArbiter.Enabled ~= false and HK.gripClaim then
            HK.gripClaim('burnout', (HK.GRIP_PRIO and HK.GRIP_PRIO.burnout) or 80,
                         { max = mxMult, min = mnMult, low = spMult })
        else
            vl_scaleHandling(veh, 'fTractionCurveMax', mxMult)
            vl_scaleHandling(veh, 'fTractionCurveMin', mnMult)
            vl_scaleHandling(veh, 'fLowSpeedTractionLossMult', spMult)
        end
        -- FRONT-BIAS: the curve drop is GLOBAL (kills front grip too) so at higher speed steering yaws the
        -- nose again. RWD/AWD only (FWD nose IS the spinning axle). Native * mult, scaled by eff. NOT shared
        -- with the arbiter (only the 3 curve fields are), so this stays a direct write.
        local cls2 = (HK.dbgDrive and HK.dbgDrive.class) or 'rwd'
        if cls2 ~= 'fwd' then
            local biasMult = 1.0 + (bcfg.SteerBiasFrontMult or 0.30) * eff
            vl_scaleHandling(veh, 'fTractionBiasFront', biasMult)
            HK.dbgBurnout.boBias = biasMult
        end
        wsGripOwned = true
        HK.dbgBurnout.boGripMx = mxMult
        HK.dbgBurnout.boGripMn = mnMult
    elseif wsGripOwned and planted then
        wsReleaseGrip(veh)   -- planted this frame: hand grip back so the static fry owns it
    end

    -- STEERING (2026-08-16 rework #3 — user: "kill the noclip left/right, steer like the launch does").
    -- We DELIBERATELY do NOT inject a yaw rate anymore. The old wsSetYaw injection force-rotated the whole
    -- entity about its up axis regardless of where the wheels pointed = the "noclip" feel the user hated.
    -- Launch-traction steers great with ZERO forced rotation: it drops the traction curves so the DRIVEN
    -- axle breaks loose, but the FRONT tyres still keep partial grip, so A/D generates real lateral force
    -- and the nose turns through the tyres — physically correct, no teleport-rotation. Wheelspin now does
    -- the same: the grip-curve drop + the front-bias boost above (fTractionBiasFront up, RWD/AWD) preserve
    -- front steering authority so native steering rotates the car via real tyre forces. Nothing to write
    -- here — the grip fields already did the work. yawInjected stays false so the wobble runs normally.
    local yawInjected = false

    -- FORWARD-SPEED SCRUB (user: "the car moves too fast during the slide, ≥1/3 cut ok"). Scrub the
    -- FORWARD-projected velocity by SlideSpeedCut each frame (extra rolling resistance) so it composes
    -- with the drag instead of fighting it. Sign-safe (only scrubs real forward motion), lateral slide
    -- velocity untouched (sideways slide stays alive), scaled by eff.
    if not planted and eff > 0.0 then
        local cut = (bcfg.SlideSpeedCut or 0.34) * eff
        if cut > 0.0 then
            local fwd = GetEntityForwardVector(veh)
            local vel = GetEntityVelocity(veh)
            local along = vel.x * fwd.x + vel.y * fwd.y + vel.z * fwd.z
            if along > 0.5 then
                local scrub = along * cut
                SetEntityVelocity(veh, vel.x - fwd.x * scrub, vel.y - fwd.y * scrub, vel.z - fwd.z * scrub)
                HK.dbgBurnout.boScrub = scrub
            end
        end
    end

    -- TINY TAIL WOBBLE: a drivetrain-dependent 0.1-0.3° tail twitch while spinning (RWD wags most).
    -- Skipped when yaw was injected this frame (both write yaw — the injection wins).
    -- MUST go through wsSetYaw, NOT a raw SetEntityAngularVelocity(av.x, av.y, wobRad): that old write fed
    -- the car's LOCAL pitch/roll rates straight into the WORLD setter, so on any pitched/rolled frame it
    -- re-injected rotation on the wrong axis and PUMPED every frame — the "rear bounces up/down, stronger
    -- the longer it spins, then flips on release" bug (the exact frame-mismatch drift.lua documents).
    -- wsSetYaw round-trips pitch/roll through the car's own basis (a true no-op) and only touches yaw, and
    -- it bump-guards + near-flip-guards. Blend high so the tiny oscillation reads as a crisp wag.
    if (bcfg.WobbleDeg or 0.0) > 0.0 and not planted and not yawInjected then
        wobblePhase = wobblePhase + dt * (bcfg.WobbleHz or 1.5) * 6.2831853
        local wobRad = (bcfg.WobbleDeg or 0.2) * eff * 0.017453293 * math.sin(wobblePhase)
        wsSetYaw(veh, wobRad, bcfg.WobbleBlend or 0.5)          -- frame-correct yaw wag; pitch/roll exact
    end

    -- (2) CHARGE — integrate the stored surplus while the wheels are ACTUALLY spinning.
    -- Measured off the real slip sensor so a car that hooks up (no spin) banks nothing;
    -- a proper spin banks fast. Normalised by SlipForFull so the rate is slip-scaled.
    local _, slipMs = vl_detectWheelspin(veh, 0.1)
    local slipFrac = slipMs / (bcfg.SlipForFull or 8.0)
    if slipFrac < 0.0 then slipFrac = 0.0 elseif slipFrac > 1.0 then slipFrac = 1.0 end
    local chargeMax = bcfg.ChargeMax or 1.0
    HK.launchCharge = (HK.launchCharge or 0.0) + slipFrac * dtScale * dt / (bcfg.ChargeTau or 0.9)
    if HK.launchCharge > chargeMax then HK.launchCharge = chargeMax end

    HK.dbgBurnout.boChg = HK.launchCharge
    HK.dbgBurnout.boSlip = slipMs
    HK.dbgBurnout.boCls = cls
end
