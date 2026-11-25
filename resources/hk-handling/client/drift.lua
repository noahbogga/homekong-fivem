-----------------------------------------------------------------
-- hk-handling :: client/drift.lua  —  SCRATCH REBUILD (2026-08-14)
-- [D3] Drift Mode — HOLD to drift.  Speed-regime model.
--
-- WHY THE REBUILD: the old file (drift.lua.bak, 2478 lines) accreted a dozen
-- independently-gated assists (servo, power-assist, forward-push, governor,
-- input-suppress, transition, collision-catch...) plus their tombstones. The
-- recovery wrote grip DIRECTLY (setTractionLossMult / restoreField) OUTSIDE the
-- grip arbiter, so it lost the last-writer-wins race whenever another grip
-- feature was live = "recovery out of place." And nothing DROVE the car forward
-- below ~8 km/h (every propulsion helper gated ≥8), so a standstill drift had
-- ice grip + no drive → steering just shoved the whole body sideways.
--
-- NEW MODEL — one continuous tick keyed on speed, three blended regimes:
--   A LAUNCH  (0 → LaunchFadeKmh):   torque hold + rear grip-loss so the driven axle
--             OVERPOWERS grip and the tyres SPIN — forward motion emerges from that
--             wheelspin (real drive force), NOT injected velocity. Gear held low
--             (HK.driftHoldGear) = high rpm + torque = the real high-rev launch flare.
--             This absorbs the old standstill burnout gesture (unified).
--   B BUILD   (Launch → SlideMinKmh): forward drive fades out, drift grip-cut
--             ramps in — the "wheelspin slide" that carries into a real drift.
--   C SLIDE   (SlideMinKmh+):        the good high-speed slide — counter-steer
--             catch + slip-angle grip firm-up + governor yaw cap (ported).
--
-- GRIP: ALL grip goes through the global arbiter (HK.gripClaim, prio 'drift'=100)
-- for the 3 shared curve fields, PLUS the private slide cliff native
-- (setTractionLossMult 0xAFD262ACCA64479A). Recovery ALSO claims through the
-- arbiter and releases — the committer restores ONCE (no race). Steering is
-- NATIVE below the slide regime; assists only run in regime C.
--
-- No engine-RPM writes. Torque is only ever the shared HK.torqueMult (regime A).
-- Public API unchanged (drop-in restart, no reconnect): DriftMode_Enable/Disable/
-- Tick/RecoveryTick/RecoveryActive/Reset/AwdBiasRamping, HK.driftMode, DriftDbg.
-----------------------------------------------------------------

local vehlib = exports['hk-vehlib']
local function bind(fn) return function(...) return fn(nil, ...) end end

-- Export refs cached ONCE at load (per-access allocates a wrapper closure; cache
-- avoids per-frame GC churn in the tick). Wrapper is function(self,...) — bind
-- forwards a nil self slot so call sites stay clean: vl_setTractionLossMult(veh,x).
local vl_getHandling            = bind(vehlib.getHandling)
local vl_setHandling            = bind(vehlib.setHandling)
local vl_restoreField           = bind(vehlib.restoreField)
local vl_setDriftTyres          = bind(vehlib.setDriftTyres)
local vl_setHandbrake           = bind(vehlib.setHandbrake)
local vl_setReducedSuspension   = bind(vehlib.setReducedSuspension)
local vl_setReduceGrip          = bind(vehlib.setReduceGrip)
local vl_setTractionLossMult    = bind(vehlib.setTractionLossMult)
local vl_detectWheelspin        = bind(vehlib.detectWheelspin)   -- (veh,thresh)->spinning,worstDiff(m/s): launch settle sensor
local vl_setBurnout             = bind(vehlib.setBurnout)        -- SetVehicleBurnout(veh,bool) — force driven wheels loose (no brake)

-----------------------------------------------------------------
-- MODULE STATE (all file-local; the only shared writes are HK.torqueMult in
-- regime A and the grip-arbiter claims, both single-frame).
-----------------------------------------------------------------
local driftApplied  = false   -- one-shot overrides currently applied?
local isFWD         = false   -- cached on enable (FWD can't power-oversteer → gets the tuck branch)
local hbUntil       = 0       -- GetGameTimer() ms until the auto-handbrake tap ends (0 = none)

-- Regime / drive state ----------------------------------------------------------
local lastLossApplied = 1.0   -- last private traction-loss native value set (recovery ramps FROM here)

-- AWD drive-bias shift (send power rearward so an AWD car can slide) ------------
local awdDriftShifted     = false
local awdDriftBiasApplied = nil
local awdDriftBiasNative  = nil

-- Counter-steer (regime C) ------------------------------------------------------
local csActive = false
local csAngle  = 0.0

-- Flick / transition (regime C) -------------------------------------------------
local transWindowUntil = 0
local lastSteerSign    = 0

-- Gear ceiling + launch (symptom #5, reworked): drifting commits to a gear — the box
-- holds the gear (block auto-upshift, allow downshift) via HK.driftHoldGear so revs +
-- torque stay HIGH and the gear self-limits top speed (no velocity injection). The
-- standstill launch is just "drift, held low, at low speed" + a low-speed torque/rear-
-- grip-loss EMPHASIS (wLaunch, a smooth fade — no phase machine, no per-car speed line).

-- Brake-torque spin RPM PIN (2026-08-14): the native brake-torque wheelspin is drift
-- key + S (brake) + W (throttle) — the engine loads against the held brake + revs to
-- (near) max. When the driver LIFTS the brake to send the car, native rpm would BOG
-- down to a speed-matched rpm, killing the spin feel. Instead we capture the PEAK rpm
-- reached while braked, and on brake release (throttle still on) PIN the needle there
-- (published HK.driftSpinRpm, painted AFTER the gearbox in main.lua = last writer).
local spinPeakRpm   = 0.0     -- peak state.rpm captured during the current brake-torque load
local spinArmed     = false   -- true once a brake-torque spin has revved past ArmRpm (pin allowed on release)
local spinPinStart  = 0       -- GetGameTimer() ms the pin began (safety hold-time backstop)
local spinSettleSince = 0     -- ms the wheelspin has been continuously SETTLED (0 = still spinning)
-- FORCED-SPIN RPM PAINT (2026-08-14): SetVehicleBurnout caps native rpm at ~0.55, so on a /setwheelie
-- car we paint the needle up to the limiter ourselves with a bounce. These carry the rising needle +
-- oscillation phase across frames; reset when the spin ends.
local spinPaintRpm  = 0.0     -- current painted needle (0..1), rises to RpmTarget while forced-spinning
local spinBouncePhase = 0.0   -- limiter-bounce oscillator phase (radians), advanced per frame

-- S-KEY-AS-WHEELSPIN eligibility cache (2026-08-14). GetVehicleMod needs a SetVehicleModKit
-- first (heavy) + can flicker -1 for a frame (see the modkit-flicker memory), so we resolve
-- eligibility ONCE per vehicle and cache it. Recomputed on veh-swap (DriftMode_Enable/Reset).
local snbEligible   = false   -- did THIS car pass the muscle+mods OR opt-in gate?
local snbEligVeh    = 0       -- vehicle the cache was computed for
local snbForcing    = false   -- did we call SetVehicleBurnout(true) last frame? (clear on release)
HK.driftNoBrakeSpin = false   -- published: true while driftkey+W+S wheelspin owns the frame (main.lua reads to kill the brake)

-- Resolve S-key-wheelspin eligibility for a vehicle (cached). Opt-in (wheelieLaunch, the same
-- flag /setwheelielaunch persists) ALWAYS qualifies. Otherwise auto: VC_MUSCLE + L3 engine +
-- L3 suspension. Mirrors wheelie.lua's modkit-safe read discipline.
local function resolveSpinEligible(veh, state)
    local snb = (Config.Drift.Regime or {}).SpinNoBrake or {}
    -- Opt-in bypass first (per-model DB flag + same-frame session set).
    local mk = GetEntityModel(veh) & 0xFFFFFFFF
    local dbRow = HK.manualModels and HK.manualModels[mk]
    if (dbRow and dbRow.wheelieLaunch == 1)
       or (HK.wheelieLaunchModels and HK.wheelieLaunchModels[mk]) then
        return true
    end
    -- Auto path: muscle + built drivetrain.
    if snb.RequireMuscle ~= false and (state.class or -1) ~= 4 then return false end
    SetVehicleModKit(veh, 0)                     -- REQUIRED before GetVehicleMod reads are valid
    local eng  = GetVehicleMod(veh, 11)          -- engine tier -1..3
    local susp = GetVehicleMod(veh, 15)          -- suspension tier -1..3
    return eng >= (snb.MinEngineMod or 2) and susp >= (snb.MinSuspMod or 2)
end

-- Angle-cap steering governor (the "cap + slowdown" the rebuild dropped) ---------
-- Space OPENS the slip-angle cap: tap = discrete steps, hold = continuous ramp;
-- a smoothed applied value eases toward the target (slow open / fast close) so a
-- tap doesn't burst it. Drift-key alone = tight MinFullDeg default.
local commitCapSteps    = 0    -- integer: discrete tap clicks toward the TARGET
local commitCapHoldRamp = 0.0  -- 0..1: continuous hold pressure toward the TARGET
local commitCapApplied  = 0.0  -- 0..1: SMOOTHED value the cap actually reads
local commitRiseT       = 0.0  -- 0..1 rise-progress (ease-in shaping while opening)
local commitExtraDeg    = 0.0  -- tier-2 TARGET degrees beyond FullDeg (extra taps)
local commitExtraApplied = 0.0 -- tier-2 SMOOTHED applied extra degrees
local handbrakeLastState = false -- edge-detect for space taps

-- Exit recovery -----------------------------------------------------------------
local recoveryUntil = 0       -- GetGameTimer() ms the window ends (0 = inactive)
local recoveryStart = 0
local recoveryVeh   = 0

-- Crash auto-exit + spin bookkeeping -------------------------------------------
local lastSpeed         = nil
local crashExitCooldown = 0
local firstFrameThisEnable = true

-- FWD tuck window ---------------------------------------------------------------
local fwdTuckUntil = 0

-- DEBUG isolation toggles (/driftdbg <key>) ------------------------------------
DriftDbg = DriftDbg or {
    drive = true,   -- regime-A forward drive + torque hold
    grip  = true,   -- grip-curve claim + private slide cliff
    csteer = true,  -- regime-C counter-steer catch
    gov   = true,   -- regime-C governor yaw cap
    cap   = true,   -- steering governor: InputSuppress slowdown + AngleFirmUp cap
    flick = true,   -- transition grip drop + yaw bleed
    yawwrite = true, -- master: skip ALL setYaw writes
}

-----------------------------------------------------------------
-- SMALL HELPERS
-----------------------------------------------------------------
local function clamp(x, lo, hi) if x < lo then return lo elseif x > hi then return hi else return x end end
local function lerpClamp(x, x0, x1, y0, y1)
    if x1 == x0 then return y0 end
    local t = (x - x0) / (x1 - x0)
    if t < 0.0 then t = 0.0 elseif t > 1.0 then t = 1.0 end
    return y0 + (y1 - y0) * t
end

-- True when drift routes the 3 shared curve fields through the global arbiter
-- (default). Flip Config.GripArbiter.DriftClaim=false to fall back to direct writes.
function DriftClaimsGrip()
    return (HK and HK.gripClaim
        and Config.GripArbiter and Config.GripArbiter.Enabled ~= false
        and Config.GripArbiter.DriftClaim ~= false) and true or false
end

-----------------------------------------------------------------
-- INPUT SUPPRESS INTENSITY (ported): 0..1 multiplier on the EXTRA slide the drift
-- key induces, from speed × gear × current-angle. This is the PROACTIVE governor
-- that keeps you out of the uncatchable state — the "slowdown / no instant
-- oversteer" the user relies on. Lower = less extra slide. 1.0 = full slide.
-----------------------------------------------------------------
local function DriftMode_InputIntensity(veh, state)
    local scfg = Config.Drift.InputSuppress
    if not scfg or not scfg.Enabled then return 1.0 end

    local kmh = state.speedKmh or 0.0
    local iSpeed = lerpClamp(kmh, scfg.SpeedFullKmh or 110.0, scfg.SpeedZeroKmh or 300.0, 1.0, scfg.SpeedMinIntensity or 0.35)

    local iGear = 1.0
    if scfg.GearEnabled then
        local cur = state.gear or GetVehicleCurrentGear(veh) or 1
        local top = GetVehicleHighGear(veh) or 1
        if top and top > 1 and cur and cur >= 1 then
            local frac = (cur - 1) / (top - 1)
            iGear = lerpClamp(frac, scfg.GearLowFrac or 0.3, 1.0, scfg.GearLowIntensity or 1.0, scfg.GearHighIntensity or 0.6)
        end
    end

    local iAngle = 1.0
    if scfg.AngleEnabled then
        local yaw = math.abs(state.yawRate or 0.0)
        iAngle = lerpClamp(yaw, scfg.AngleFullRate or 0.30, scfg.AngleZeroRate or 0.85, 1.0, scfg.AngleMinIntensity or 0.30)
    end

    return iSpeed * iGear * iAngle
end

-- High-speed governor speed factor: 0 below LowKmh (no governing, keep the tight
-- low-speed drift) → 1 at/above HighKmh. Scales the high-speed grip firm-up.
local function DriftMode_GovSpeedFactor(state, gcfg)
    return lerpClamp(state.speedKmh or 0.0, gcfg.LowKmh or 120.0, gcfg.HighKmh or 240.0, 0.0, 1.0)
end

-----------------------------------------------------------------
-- YAW-ONLY WRITE (ported verbatim from the old build — it is the frame-correct
-- yaw writer and the fix for the "bounce/shake on hills, A/D flips the car" bug).
-- Changes ONLY the car-frame yaw rate, leaving pitch/roll exactly as physics has
-- them: read LIVE local angular velocity, substitute desired local yaw, rotate
-- back to WORLD via the car's own basis. Bump-guards (skips on fast pitch/roll)
-- and near-flip-guards. USED ONLY in regime C (never at low speed) + recovery.
-----------------------------------------------------------------
local function setYaw(veh, newLocalYawRate)
    if DriftDbg and DriftDbg.yawwrite == false then return end
    local lav = GetEntityRotationVelocity(veh)   -- LOCAL: (pitchRate, rollRate, yawRate)

    local bg = Config.Drift and Config.Drift.BumpGuardRate
    if bg == nil then bg = 0.35 end
    if bg > 0.0 and (math.abs(lav.x) > bg or math.abs(lav.y) > bg) then
        return   -- transient bump frame: don't clobber the suspension's pitch/roll damping
    end

    local m1, m2, m3 = GetEntityMatrix(veh)
    local fwd = GetEntityForwardVector(veh)
    local function dot(a, b) return a.x*b.x + a.y*b.y + a.z*b.z end

    local cand = { m1, m2, m3 }
    local fi, best = 1, math.abs(dot(m1, fwd))
    for i = 2, 3 do
        local d = math.abs(dot(cand[i], fwd))
        if d > best then best, fi = d, i end
    end
    local forwardV = cand[fi]

    local r1, r2
    for i = 1, 3 do if i ~= fi then if not r1 then r1 = cand[i] else r2 = cand[i] end end end
    local upV, rightV
    if math.abs(r1.z) >= math.abs(r2.z) then upV, rightV = r1, r2 else upV, rightV = r2, r1 end

    if math.abs(upV.z) < 0.35 then return end   -- near-flip: let physics own it

    local wx = lav.x*rightV.x + lav.y*forwardV.x + newLocalYawRate*upV.x
    local wy = lav.x*rightV.y + lav.y*forwardV.y + newLocalYawRate*upV.y
    local wz = lav.x*rightV.z + lav.y*forwardV.z + newLocalYawRate*upV.z
    SetEntityAngularVelocity(veh, wx, wy, wz)
end

-----------------------------------------------------------------
-- PHYSICS-SAFE GATE (ported): true only when it's safe to write yaw/lateral —
-- all wheels down, not mid-collision, body not pitched/rolled past limits.
-- Used to gate the regime-C assists (never the low-speed drive).
-----------------------------------------------------------------
local collisionCooldownUntil = 0
local function DriftMode_PhysicsSafe(veh, state, scfg)
    local now = GetGameTimer()
    if HasEntityCollidedWithAnything(veh) then
        collisionCooldownUntil = now + ((scfg and scfg.CollisionCooldownMs) or 500)
    end
    if now < collisionCooldownUntil then return false end
    if not scfg or scfg.RequireOnAllWheels ~= false then
        local onWheels = state.onAllWheels
        if onWheels == nil then onWheels = IsVehicleOnAllWheels(veh) end
        if not onWheels then return false end
    end
    local pitch, roll = state.pitch, state.roll
    if pitch == nil or roll == nil then
        local rot = GetEntityRotation(veh, 2); pitch, roll = rot.x, rot.y
    end
    if math.abs(pitch) > ((scfg and scfg.MaxPitchDeg) or 12.0) then return false end
    if math.abs(roll)  > ((scfg and scfg.MaxRollDeg)  or 20.0) then return false end
    return true
end

-----------------------------------------------------------------
-- ENABLE: arm the one-shot native knobs + capture baselines. Called from
-- main.lua on drift-key press (HK.driftMode already set true there).
-----------------------------------------------------------------
function DriftMode_Enable(veh)
    local cfg = Config.Drift
    if not cfg or not cfg.Enabled then return end
    if not veh or veh == 0 or not DoesEntityExist(veh) then return end
    if driftApplied then return end
    driftApplied = true

    firstFrameThisEnable = true
    fwdTuckUntil = 0
    lastLossApplied = 1.0

    -- Resolve S-key-wheelspin eligibility for this car ONCE (modkit reads are heavy + flicker).
    snbEligVeh  = veh
    local okE, elig = pcall(resolveSpinEligible, veh, HK.state or {})
    snbEligible = okE and elig or false

    -- DRIVETRAIN LAYOUT (cached): FWD cars can't power-oversteer → tuck branch.
    isFWD = false
    if cfg.FWD and cfg.FWD.Enabled then
        local ok, lay = pcall(function() return vehlib.getDrivetrainLayout(nil, veh) end)
        if ok and lay and lay.layout == 'FWD' then isFWD = true end
    end

    -- CLEAN GRIP HAND-OFF: force the shared curve fields back to native + drop all
    -- wheelspin claims on the entry frame, so drift's own claim takes over from a
    -- clean native cache (no stale TC-off / launch / burnout scale poisoning entry).
    if _G.TCOff_GripRestore then _G.TCOff_GripRestore(veh) end
    if HK.gripArbiterReset then HK.gripArbiterReset(veh) end
    if _G.ESC_Restore then _G.ESC_Restore(veh) end

    -- LEGACY grip baseline (only used when the arbiter is OFF): capture native curve
    -- values AFTER the resets above so a stale scale can't poison the baseline.
    if not DriftClaimsGrip() and not isFWD and cfg.UseHandlingCurves then
        HK._driftCurveOrig = {
            max = vl_getHandling(veh, 'fTractionCurveMax'),
            min = vl_getHandling(veh, 'fTractionCurveMin'),
            low = vl_getHandling(veh, 'fLowSpeedTractionLossMult'),
        }
    else
        HK._driftCurveOrig = nil
    end

    -- CORE: R* drift-tyre mode (persists until cleared).
    if cfg.UseDriftTyres then vl_setDriftTyres(veh, true) end

    -- Reduced suspension: skip on a damaged body (rides unevenly → bounce).
    if cfg.UseReducedSuspension then
        local ok, hp = pcall(GetVehicleBodyHealth, veh)
        if not (ok and hp and hp < (cfg.DamagedBodyHealth or 950.0)) then
            vl_setReducedSuspension(veh, true)
        end
    end

    -- STEERING LOCK: extra counter-steer range so the player can hold a slide.
    if cfg.SteeringLockMult and cfg.SteeringLockMult ~= 1.0 then
        local orig = vl_getHandling(veh, 'fSteeringLock')
        if orig and orig > 0.0 then vl_setHandling(veh, 'fSteeringLock', orig * cfg.SteeringLockMult) end
    end

    -- LOOSER TAIL: small rearward traction-bias nudge (RWD/AWD only).
    if not isFWD and cfg.TractionBiasFrontDelta and cfg.TractionBiasFrontDelta ~= 0.0 then
        local orig = vl_getHandling(veh, 'fTractionBiasFront')
        if orig and orig > 0.0 then
            vl_setHandling(veh, 'fTractionBiasFront', clamp(orig + cfg.TractionBiasFrontDelta, 0.1, 0.9))
        end
    end

    -- AWD DRIVE-BIAS SHIFT: send power rearward so an AWD car slides instead of
    -- washing wide. Ramped back on exit (a one-frame jump is a torque jolt).
    awdDriftShifted = false
    if not isFWD and cfg.AwdDriftDriveBias and cfg.AwdDriftDriveBias.Enabled ~= false then
        local db = cfg.AwdDriftDriveBias
        local orig = vl_getHandling(veh, 'fDriveBiasFront')
        if orig and orig >= (db.MinFrontBias or 0.45) then
            local target = math.max(orig - (db.RearShift or 0.22), db.MinBias or 0.20)
            vl_setHandling(veh, 'fDriveBiasFront', target)
            awdDriftShifted = true
            awdDriftBiasApplied = target
            awdDriftBiasNative  = orig
        end
    end

    -- AUTO-HANDBRAKE INITIATION: brief tap to break the rear loose (mid-speed only).
    if cfg.UseAutoHandbrake then
        local kmh = GetEntitySpeed(veh) * 3.6
        if kmh >= (cfg.AutoHandbrakeMinKmh or 20.0) and kmh <= (cfg.AutoHandbrakeMaxKmh or 160.0) then
            hbUntil = GetGameTimer() + (cfg.AutoHandbrakeMs or 160)
        end
    end

    -- Angle-cap governor starts fresh at the tight default (drift-key-only cap).
    commitCapSteps = 0; commitCapHoldRamp = 0.0; commitCapApplied = 0.0
    commitRiseT = 0.0; commitExtraDeg = 0.0; commitExtraApplied = 0.0
    handbrakeLastState = false
end

-----------------------------------------------------------------
-- FWD TICK (ported, trimmed): weight-transfer cornering for front-drive cars.
-- On a lift/handbrake while cornering, briefly spike rear traction-loss so the
-- nose tucks in; cancel the instant throttle returns. Cornering rotation, not a
-- held drift. Uses the PRIVATE slide-cliff native only (never the shared curves).
-----------------------------------------------------------------
function DriftMode_FWDTick(veh, state, dt)
    local fcfg = Config.Drift.FWD
    if not fcfg or not fcfg.Enabled then return end
    local now   = GetGameTimer()
    local thr   = state.effThrottle or state.throttle or 0.0
    local kmh   = state.speedKmh or 0.0
    local steer = math.abs(state.steer or 0.0)

    if thr >= (fcfg.HookThrottle or 0.45) then
        if fwdTuckUntil > 0 then fwdTuckUntil = 0; vl_setTractionLossMult(veh, 1.0); lastLossApplied = 1.0 end
        return
    end
    local lifting  = thr <= (fcfg.LiftThrottle or 0.25)
    local braking  = state.handbrake == true
    local cornering = kmh >= (fcfg.MinSpeedKmh or 25.0) and steer >= (fcfg.MinSteer or 0.20)
    if fwdTuckUntil == 0 and cornering and (lifting or braking) then
        fwdTuckUntil = now + (fcfg.WindowMs or 500)
    end
    if fwdTuckUntil > 0 then
        if now >= fwdTuckUntil then
            fwdTuckUntil = 0; vl_setTractionLossMult(veh, 1.0); lastLossApplied = 1.0
        else
            local rem = clamp((fwdTuckUntil - now) / (fcfg.WindowMs or 500), 0.0, 1.0)
            local loss = 1.0 + ((fcfg.RotateLoss or 1.6) - 1.0) * rem
            vl_setTractionLossMult(veh, loss); lastLossApplied = loss
        end
    end
end

-----------------------------------------------------------------
-- COUNTER-STEER CATCH (regime C, ported): fills only the GAP toward ideal
-- opposite-lock (reading the actual wheel angle, which already includes the
-- player's input), so a correct countersteer leaves no gap = auto-yield, and it
-- NEVER steers into the spin. Bounded slide permit, cannot doughnut. Speed-gated.
-----------------------------------------------------------------
local function DriftMode_CounterSteerTick(veh, state, dt)
    local ccfg = Config.Drift.CounterSteer
    if not ccfg or not ccfg.Enabled then return end
    if DriftDbg and DriftDbg.csteer == false then return end

    local yaw = state.yawRate or 0.0
    local kmh = state.speedKmh or 0.0
    if math.abs(yaw) < (ccfg.MinYawRate or 0.30) or kmh < (ccfg.MinSpeedKmh or 20.0) then
        csActive = false; return
    end
    local maxAngle = vl_getHandling(veh, 'fSteeringLock') or 40.0
    if maxAngle <= 0.0 then return end

    local frac = math.min(math.abs(yaw) * (ccfg.YawToAngle or 0.55), ccfg.MaxAngleFrac or 0.9)
    local idealAngle = -(yaw >= 0 and 1.0 or -1.0) * frac * maxAngle
    local cur = GetVehicleSteeringAngle(veh) or 0.0

    local strength = ccfg.Strength or 0.55
    if IsInputDisabled(2) then strength = strength * (ccfg.KeyboardStrengthMult or 1.5) end
    if ccfg.SpeedBoostEnabled then
        strength = strength * lerpClamp(kmh, ccfg.SpeedBoostLowKmh or 180.0, ccfg.SpeedBoostHighKmh or 280.0, 1.0, ccfg.SpeedBoostMult or 1.8)
    end
    if ccfg.LowSpeedReductionEnabled then
        strength = strength * lerpClamp(kmh, ccfg.LowSpeedReductionFullKmh or 45.0, ccfg.LowSpeedReductionKmh or 140.0, ccfg.LowSpeedReductionMult or 0.3, 1.0)
    end
    if ccfg.RunawayEnabled then
        strength = strength * lerpClamp(math.abs(yaw), ccfg.RunawayYaw or 0.75, ccfg.RunawayYawMax or 1.60, 1.0, ccfg.RunawayMult or 2.0)
    end
    if strength > 1.0 then strength = 1.0 end

    local steer = state.steer or 0.0
    if (idealAngle < 0 and steer < 0) or (idealAngle > 0 and steer > 0) then
        strength = strength * (1.0 - (ccfg.PlayerYield or 0.85) * math.min(math.abs(steer), 1.0))
    end
    if strength <= 0.0 then csActive = false; return end

    local target = cur + (idealAngle - cur) * strength
    if not csActive then csAngle = cur; csActive = true end
    csAngle = csAngle + (target - csAngle) * (1.0 - math.exp(-(ccfg.Smoothing or 12.0) * dt))
    SetVehicleSteeringAngle(veh, csAngle + 0.0)
end

-----------------------------------------------------------------
-- GRIP APPLY: single place that sets ALL grip for the frame. The 3 shared curve
-- fields go through the arbiter (prio drift=100); the private slide-cliff native
-- (setTractionLossMult) is drift-only, set directly. `slide` 0..1 = how much of
-- full drift grip-loss to apply (0 = stock grip, 1 = full drift). `lossOverride`
-- is the private loss native value (>=1.0 looser). Front grip is preserved by NOT
-- cutting the shared curves harder than the config target * slide.
-----------------------------------------------------------------
local function applyDriftGrip(veh, cfg, slide, lossOverride)
    if DriftDbg and DriftDbg.grip == false then return end
    slide = clamp(slide, 0.0, 1.0)

    -- SHARED CURVE FIELDS: blend each mult from 1.0 (stock) → configMult by `slide`.
    if not isFWD and cfg.UseHandlingCurves then
        local function blendMult(m) return 1.0 + ((m or 1.0) - 1.0) * slide end
        if DriftClaimsGrip() then
            HK.gripClaim('drift', (HK.GRIP_PRIO and HK.GRIP_PRIO.drift) or 100, {
                max = blendMult(cfg.TractionCurveMaxMult),
                min = blendMult(cfg.TractionCurveMinMult),
                low = blendMult(cfg.LowSpeedTractionLossMult),
            })
        elseif HK._driftCurveOrig then
            -- Legacy (arbiter off): direct scale from the baseline captured on enable.
            local orig = HK._driftCurveOrig
            vl_setHandling(veh, 'fTractionCurveMax', orig.max * blendMult(cfg.TractionCurveMaxMult))
            vl_setHandling(veh, 'fTractionCurveMin', orig.min * blendMult(cfg.TractionCurveMinMult))
            vl_setHandling(veh, 'fLowSpeedTractionLossMult', orig.low * blendMult(cfg.LowSpeedTractionLossMult))
        end
    end

    -- PRIVATE SLIDE-CLIFF NATIVE: the real "greasiness" lever, drift-only, 1.0=stock.
    if cfg.UseTractionLossOverride and lossOverride then
        local blended = 1.0 + (lossOverride - 1.0) * slide
        vl_setTractionLossMult(veh, blended)
        lastLossApplied = blended
    end
end

-----------------------------------------------------------------
-- MAIN TICK — one continuous model over three blended speed regimes.
-- Called every frame from main.lua while HK.driftMode is true.
-----------------------------------------------------------------
function DriftMode_Tick(veh, state, dt)
    local cfg = Config.Drift
    if not driftApplied then return end

    -- FWD BRANCH: front-drive cars use the weight-transfer tuck, not the rear model.
    if isFWD then DriftMode_FWDTick(veh, state, dt); return end

    local now = GetGameTimer()
    local kmh = state.speedKmh or 0.0
    local thr = state.effThrottle or state.throttle or 0.0

    -- CRASH AUTO-EXIT: a sudden speed-magnitude drop in ONE frame = a crash. Drop
    -- out of drift so physics reset cleanly (NOT a vector-delta test — a drift
    -- rotates the velocity vector fast while keeping speed, which false-fires that).
    local ecfg = cfg.Stabilizer and cfg.Stabilizer.CrashAutoExit
    if (ecfg == nil or ecfg.Enabled ~= false) and now > crashExitCooldown then
        local vel = state.velocity
        local curSpeed = vel and math.sqrt(vel.x*vel.x + vel.y*vel.y + vel.z*vel.z) or nil
        if curSpeed and lastSpeed then
            local drop = lastSpeed - curSpeed
            local thresh = (ecfg and ecfg.SpeedDropThreshold) or 7.0
            local minMs  = ((ecfg and ecfg.MinSpeedKmh) or 25.0) / 3.6
            if drop > thresh and lastSpeed > minMs then
                if HK and HK.driftMode ~= nil then HK.driftMode = false end
                DriftMode_Disable(veh)
                crashExitCooldown = now + ((ecfg and ecfg.CooldownMs) or 1500)
                lastSpeed = nil
                return
            end
        end
        lastSpeed = curSpeed
    end

    -- AIRBORNE: suspend all drift handling this frame (stay in drift mode). Applying
    -- grip cuts to only the grounded wheels spins the car around the contact point.
    -- Also drop the gear ceiling + spin-rpm pin so the gearbox shifts/revs normally in the air.
    if not IsVehicleOnAllWheels(veh) then
        firstFrameThisEnable = false
        HK.driftHoldGear = false
        HK.driftSpinRpm = nil; spinArmed = false; spinPeakRpm = 0.0; spinPinStart = 0; spinSettleSince = 0
        spinPaintRpm = 0.0; spinBouncePhase = 0.0
        HK.driftNoBrakeSpin = false; HK.driftSpinActive = false; HK.driftSpinReleaseAt = 0
        if snbForcing then vl_setBurnout(veh, false); snbForcing = false end
        return
    end

    -- AUTO-HANDBRAKE tap (initiation) — reassert while the window is open.
    if hbUntil > 0 then
        if now < hbUntil then vl_setHandbrake(veh, true) else vl_setHandbrake(veh, false); hbUntil = 0 end
    end

    -----------------------------------------------------------------
    -- GEAR CEILING + LAUNCH (symptom #5, reworked). A drifter commits to a gear:
    -- the box must NOT auto-upshift (an upshift drops rpm → drops torque → kills the
    -- slide and just gains speed) but MAY still downshift (slowing / braking into a
    -- corner). So while drifting grounded + coupled we publish HK.driftHoldGear and
    -- the gearbox blocks every auto-upshift (all owned modes) while letting downshifts
    -- through — a ratchet ceiling. This is what caps top speed WITHOUT any velocity
    -- injection: a held low gear self-limits at its own redline.
    --
    -- The standstill "launch" then needs NO phase machine — it's just "drift, held in
    -- 1st, at low speed": revs/torque ride high naturally off the gearing, and we add
    -- a low-speed EMPHASIS (wLaunch) that boosts torque + fries the REAR (private
    -- slide-cliff native only, front keeps grip = still steers) so the tyres overpower
    -- grip and the car SLIDES forward through real drive force. wLaunch is a smooth
    -- low-speed fade, NOT a discrete handoff — every car benefits regardless of its
    -- torque, so there's no per-car speed line to get wrong.
    -----------------------------------------------------------------
    local rc = cfg.Regime or {}
    local slideMin   = rc.SlideMinKmh  or 30.0
    local slideFull  = rc.SlideFullKmh or 80.0

    local coupled   = not (HK.gbInNeutral == true or HK.gbClutchHeld == true or HK.inReverseGear == true)
    local grounded  = IsVehicleOnAllWheels(veh)

    -- Live wheelspin magnitude (m/s of driven-wheel over-speed) — debug/telemetry only now.
    local _, worstSpin = vl_detectWheelspin(veh, 0.0)
    worstSpin = worstSpin or 0.0

    -- GEAR CEILING: hold the gear (block auto-upshift, allow downshift) for the whole
    -- time we're drifting on the ground with drive coupled. Cleared when neutral /
    -- clutched / in reverse / airborne so the box shifts normally there.
    HK.driftHoldGear = (grounded and coupled) or false

    -- wLaunch: LOW-SPEED launch emphasis 0..1. 1.0 down low, fades to 0 by LaunchFadeKmh.
    -- Drives ONLY the torque boost + rear grip-loss override below (never velocity).
    local wLaunch = lerpClamp(kmh, rc.LaunchFadeLoKmh or 5.0, rc.LaunchFadeKmh or 40.0, 1.0, 0.0)
    local wSlide  = lerpClamp(kmh, slideMin, slideFull, 0.0, 1.0)
    -- grip-cut depth: eases in from ~0 at standstill to full by slideMin, then holds.
    local slideDepth = lerpClamp(kmh, rc.GripRampLoKmh or 6.0, slideMin, rc.GripFloor or 0.15, 1.0)

    -----------------------------------------------------------------
    -- S-KEY-AS-WHEELSPIN (2026-08-14 REWORK). During drift, S changes meaning by throttle:
    --   • driftkey + W + S (throttle present) → NATIVE WHEELSPIN, NO FOOTBRAKE. The OLD
    --     brake-torque spin loaded the engine against the HELD brake — which BLED speed +
    --     rpm, so a slow car never reached the high-torque out-of-gear-ratio spin a wheelie
    --     needs (LC works precisely because it spins WITHOUT braking). So here we FORCE the
    --     rears loose (SetVehicleBurnout, hybrid) + hold torque + drop rear grip, and
    --     SUPPRESS the footbrake (HK.driftNoBrakeSpin → main.lua kills the brake) so the
    --     car keeps rolling and the spin goes out-of-boundary. PURELY STATE BASED: as long
    --     as driftkey + W + S are all HELD (any order), we're in wheelspin — no press
    --     sequence, no arm-edge. We still PIN the rpm needle FLAT at the captured peak so
    --     the gauge reads the real high load and doesn't bog while spinning.
    --   • driftkey + S, NO throttle → normal footbrake (untouched — do nothing here).
    -- Gated per-vehicle (snbEligible, resolved on enable): VC_MUSCLE + L3 engine + L3
    -- suspension, OR any /setwheelielaunch opt-in car. Ineligible cars keep native S.
    --
    -- The RELEASE still keys on the PHYSICAL SPIN ending (worstSpin settle, immune to our
    -- paint feedback) so the pin hands back cleanly; wheelie.lua reads the same settle to
    -- fire Path B off the real hooking energy.
    -----------------------------------------------------------------
    local snb     = rc.SpinNoBrake or {}
    local rpmNow  = state.rpm or 0.0
    -- physical S key first (HK._pedalBrake — same robust read the burnout tick uses; the
    -- reverse rework can zero control 72 so state.brake is unreliable at a stop).
    local brkNow  = HK._pedalBrake or state.effBrake or state.brake or 0.0
    local sHeld   = brkNow >= (snb.BrakeGate or rc.SpinBrakeGate or 0.5)
    local wHeld   = thr >= (snb.ThrottleGate or rc.DriveThrottleGate or 0.15)
    -- WHEELSPIN CONTEXT: eligible car, grounded, coupled, and W+S both held. This is the
    -- entire gate — held-state, evaluated every frame, no sequence.
    local spinCtx = (snb.Enabled ~= false) and snbEligible and grounded and coupled and wHeld and sHeld
    HK.driftSpinRpm     = nil     -- default: no pin this frame (main.lua only paints when set)
    HK.driftNoBrakeSpin = false   -- default: don't suppress the brake
    if spinCtx then
        -- FORCE THE SPIN (hybrid): break the driven wheels loose regardless of power so a
        -- slow car still reaches the out-of-boundary spin. Cleared the frame it ends.
        local forced = (snb.ForceBurnout ~= false)
        if forced then
            vl_setBurnout(veh, true); snbForcing = true
        end
        -- SUPPRESS THE FOOTBRAKE so S doesn't bleed speed/rpm while we spin (main.lua reads this).
        HK.driftNoBrakeSpin = true
        -- ARM: on the FORCED path, SetVehicleBurnout CAPS native rpm at ~0.55, so state.rpm can't reach
        -- SpinArmRpm (0.80) — arm on the PHYSICAL spin only (worstSpin, immune to the cap). On the
        -- non-forced path (ForceBurnout=false), keep the old rpm-AND-spin gate.
        if rpmNow > spinPeakRpm then spinPeakRpm = rpmNow end
        if forced then
            if worstSpin >= (snb.SpinArmMps or rc.SpinArmMps or 2.5) then spinArmed = true end
        else
            if spinPeakRpm >= (rc.SpinArmRpm or 0.80) and worstSpin >= (rc.SpinArmMps or 3.0) then
                spinArmed = true
            end
        end
        -- RPM PAINT while spinning. Forced path: PAINT our own needle up to the limiter with a bounce
        -- (real cars scream at redline when the tyres are lit; GTA's canned 0.55 looks dead). Non-forced:
        -- pin flat at the captured native peak as before.
        if spinArmed then
            if forced then
                local tgt = snb.RpmTarget or 0.99
                spinPaintRpm = spinPaintRpm + (tgt - spinPaintRpm) * math.min(1.0, (snb.RpmRise or 4.0) * dt)
                spinBouncePhase = spinBouncePhase + (snb.RpmBounceHz or 13.0) * 2.0 * math.pi * dt
                if spinBouncePhase > 1e6 then spinBouncePhase = spinBouncePhase % (2.0 * math.pi) end
                -- bounce only once the needle is up near target (a rising needle shouldn't flutter)
                local bAmt = (snb.RpmBounce or 0.055) * math.max(0.0, (spinPaintRpm - 0.6) / 0.4)
                local painted = spinPaintRpm - bAmt * (0.5 - 0.5 * math.cos(spinBouncePhase))
                if painted > 1.0 then painted = 1.0 elseif painted < 0.0 then painted = 0.0 end
                HK.driftSpinRpm = painted
                if spinPeakRpm < painted then spinPeakRpm = painted end   -- so the release pin holds high too
            else
                HK.driftSpinRpm = spinPeakRpm   -- FLAT hold at max, no decay
            end
        end
        HK.burnoutActive = true    -- publish the gesture flag (gauge/gearbox/launch-traction busy)
        HK.driftSpinActive = spinArmed   -- true while a REAL W+S wheelspin owns the frame (wheelie reads it)
        -- PHYSICS FEEL (hybrid, the other half): hold torque UP so the driven axle overpowers grip
        -- and the spin runs out-of-boundary at ANY speed (regime A's torque hold fades by ~40km/h, so
        -- mid-drive needs its own). This is what makes the forced burnout feel like real drive, not a
        -- canned effect. The forced SetVehicleBurnout already breaks the rears loose, so we do NOT also
        -- override the private slide-cliff native here — that field is regime-A/recovery-owned and a
        -- mid-drive write would leave the rear fried until the recovery tick (no reset path at speed).
        HK.torqueMult = (HK.torqueMult or 1.0) * (snb.TorqueMult or 1.9)
        spinPinStart = 0; spinSettleSince = 0
    else
        -- Not in W+S wheelspin. Clear the forced burnout if we were forcing it. If we were
        -- spinning last frame and just left the context (released S / lifted W), stamp the
        -- release moment so wheelie.lua can fire Path B off the real hooking energy.
        if snbForcing then vl_setBurnout(veh, false); snbForcing = false end
        if HK.driftSpinActive then HK.driftSpinReleaseAt = now end
        HK.driftSpinActive = false
        if spinArmed and grounded and coupled and wHeld and not sHeld then
            -- RELEASED S (still on the gas): HOLD the pin at the captured peak until the
            -- physical wheelspin SETTLES (worstSpin caught, immune to paint feedback) — the
            -- natural end of the spin — then hand rpm back. wheelie.lua fires off this same window.
            if spinPinStart == 0 then spinPinStart = now end
            if worstSpin < (rc.SpinSettleMps or 2.0) then
                if spinSettleSince == 0 then spinSettleSince = now end
            else
                spinSettleSince = 0
            end
            local settled  = spinSettleSince ~= 0 and (now - spinSettleSince) >= (rc.SpinSettleMs or 300)
            local timedOut = (now - spinPinStart) >= (rc.SpinPinMaxMs or 6000)  -- safety backstop only
            if settled or timedOut then
                spinArmed = false; spinPeakRpm = 0.0; spinPinStart = 0; spinSettleSince = 0
                spinPaintRpm = 0.0; spinBouncePhase = 0.0
            else
                HK.driftSpinRpm = spinPeakRpm
            end
        else
            -- off throttle / ineligible / airborne / decoupled: reset so a fresh spin starts clean.
            spinArmed = false; spinPeakRpm = 0.0; spinPinStart = 0; spinSettleSince = 0
            spinPaintRpm = 0.0; spinBouncePhase = 0.0
        end
    end

    HK.dbgDrift = HK.dbgDrift or {}
    HK.dbgDrift.kmh = kmh; HK.dbgDrift.wLaunch = wLaunch; HK.dbgDrift.wSlide = wSlide; HK.dbgDrift.slide = slideDepth
    HK.dbgDrift.launch = (wLaunch > 0.01); HK.dbgDrift.spin = worstSpin; HK.dbgDrift.holdGear = HK.driftHoldGear
    HK.dbgDrift.spinRpm = HK.driftSpinRpm or 0.0; HK.dbgDrift.spinPeak = spinPeakRpm

    -----------------------------------------------------------------
    -- GRIP: compute the private slide-cliff loss (throttle-sustained) then apply
    -- ALL grip in one place. Depth scales in with speed so the standstill launch
    -- keeps near-stock front grip (car steers) and the slide opens up as it builds.
    -----------------------------------------------------------------
    local loss = cfg.TractionLossMult or 1.0
    if cfg.ThrottleSustain then
        local gate = cfg.SustainThrottleGate or 0.5
        if thr > gate then
            local t = clamp((thr - gate) / (1.0 - gate), 0.0, 1.0)
            loss = loss + ((cfg.TractionLossOnThrottle or 1.0) - loss) * t
        end
    end

    -- TRANSITION (flick) grip drop: on a steering reversal while sliding, briefly
    -- drop rear grip so momentum swings the tail across. Regime C territory.
    if wSlide > 0.05 and cfg.Transition and cfg.Transition.Enabled and not (DriftDbg and DriftDbg.flick == false) then
        local steer = state.steer or 0.0
        local sign = steer > 0.15 and 1 or (steer < -0.15 and -1 or 0)
        if sign ~= 0 and lastSteerSign ~= 0 and sign ~= lastSteerSign then
            transWindowUntil = now + (cfg.Transition.WindowMs or 260)
        end
        if sign ~= 0 then lastSteerSign = sign end
        if transWindowUntil > 0 and now < transWindowUntil then
            loss = math.min(loss + (cfg.Transition.LossBoost or 0.0), cfg.Transition.LossCeiling or 3.0)
            if cfg.Transition.YawBleedEnabled then
                local av = state.angularVelocity
                if av then setYaw(veh, av.z * math.exp(-(cfg.Transition.YawBleedDamp or 5.0) * dt)) end
            end
        elseif transWindowUntil > 0 then transWindowUntil = 0 end
    end

    -----------------------------------------------------------------
    -- STEERING GOVERNOR — the "cap + slowdown" that stops instant, uncatchable
    -- oversteer (restored from the pre-rebuild build). Three proactive levers on
    -- the raw `loss`, all applied BEFORE the slideDepth blend in applyDriftGrip:
    --   1) high-speed grip firm-up (Governor) — pull loss toward base at speed
    --   2) InputSuppress — scale the EXTRA slide by speed/gear/angle intensity
    --   3) AngleFirmUp — past a slip-angle cap, firm grip back + scrub yaw. Space
    --      OPENS the cap (tap = steps, hold = ramp) for wide committed slides.
    -- All only ever ADD grip / REDUCE yaw, so none can spin the car or fire at
    -- the standstill launch (they read real slip angle + speed, near-zero there).
    -----------------------------------------------------------------
    local base = cfg.TractionLossMult or 1.0
    if not (DriftDbg and DriftDbg.cap == false) then
        -- (1) HIGH-SPEED GRIP FIRM-UP: blend the excess loss back toward base grip
        -- as speed rises, so the rear keeps bite at speed but stays loose down low.
        local gcfg = cfg.Governor
        if gcfg and gcfg.Enabled and loss > base then
            local gsf = DriftMode_GovSpeedFactor(state, gcfg)
            if gsf > 0.0 then
                loss = loss - (loss - base) * ((gcfg.GripFirmAtHigh or 0.0) * gsf)
            end
        end

        -- (2) INPUT SUPPRESS: scale the EXTRA slide (loss above planted base) by the
        -- speed×gear×angle intensity so the drift key induces less rotation the
        -- faster you go / taller the gear / more sideways you already are. This is
        -- the primary angle bound and the "slowdown" the user relies on.
        if cfg.InputSuppress and cfg.InputSuppress.Enabled and loss > base then
            local intensity = DriftMode_InputIntensity(veh, state)
            loss = base + (loss - base) * intensity
        end

        -- (3) COMMIT CAP state machine — space OPENS the slip-angle cap. Tap = a
        -- discrete step toward the target, hold = a continuous ramp; a smoothed
        -- applied value eases toward it (slow open / fast close). Drift-key alone
        -- collapses to the tight MinFullDeg default.
        local afcfg = cfg.AngleFirmUp
        if afcfg and afcfg.Enabled ~= false then
            local handbrake = IsDisabledControlPressed(0, 76)  -- space / handbrake key
            local stepDeg   = afcfg.CommitStepDeg or 2.0
            local capRange  = math.max((afcfg.FullDeg or 24.85) - (afcfg.MinFullDeg or 11.235), 0.01)

            if handbrake then
                local rampMs = afcfg.CommitHoldRampMs or 600.0
                commitCapHoldRamp = math.min(1.0, commitCapHoldRamp + (rampMs > 0 and (1000.0/rampMs) or 999.0) * dt)
                if not handbrakeLastState then           -- tap edge: bump discrete target
                    local maxSteps = math.floor(capRange / stepDeg)
                    if commitCapSteps < maxSteps then
                        commitCapSteps = commitCapSteps + 1
                        commitCapHoldRamp = math.max(commitCapHoldRamp, (commitCapSteps * stepDeg) / capRange)
                    else                                  -- tier-2: extend beyond FullDeg
                        commitExtraDeg = math.min(commitExtraDeg + (afcfg.ExtraStepDeg or 2.0), afcfg.ExtraMaxDeg or 20.0)
                    end
                end
            else
                if handbrakeLastState then commitCapSteps = 0; commitExtraDeg = 0.0 end  -- release: snap target to base
                if commitCapHoldRamp > 0.0 then
                    local decayMs = afcfg.CommitHoldDecayMs or 400.0
                    commitCapHoldRamp = math.max(0.0, commitCapHoldRamp - (decayMs > 0 and (1000.0/decayMs) or 999.0) * dt)
                end
            end
            handbrakeLastState = handbrake

            -- SMOOTH APPLY: ease commitCapApplied toward the raw target (slow rise
            -- with ease-in shaping, fast fall) so a tap opens gently, release closes quick.
            local target = math.min(math.max((commitCapSteps * stepDeg) / capRange, commitCapHoldRamp), 1.0)
            local rising = target > commitCapApplied
            local rate   = 1000.0 / ((rising and (afcfg.CommitApplyRiseMs or 120)) or (afcfg.CommitApplyFallMs or 180))
            if rising then
                local riseSec = ((afcfg.CommitApplyRiseMs or 120) / 1000.0)
                commitRiseT = math.min(1.0, commitRiseT + (riseSec > 0 and (dt / riseSec) or 1.0))
                local fm = afcfg.CommitRiseFloorMult or 0.25
                rate = rate * (fm + (1.0 - fm) * commitRiseT)
            else
                commitRiseT = 0.0
            end
            commitCapApplied = commitCapApplied + (target - commitCapApplied) * (1.0 - math.exp(-rate * dt))
            local extraRate = 1000.0 / ((commitExtraDeg > commitExtraApplied and (afcfg.CommitApplyRiseMs or 120)) or (afcfg.CommitApplyFallMs or 180))
            commitExtraApplied = commitExtraApplied + (commitExtraDeg - commitExtraApplied) * (1.0 - math.exp(-extraRate * dt))

            HK.dbgDrift.capOpen = commitCapApplied

            -- ANGLE FIRM-UP: as the real slip angle grows past StartDeg, pull loss
            -- toward FirmTarget (below base = rear regains grip) reaching full pull
            -- at the effective cap; past the cap, a direct yaw scrub arrests the
            -- excess rotation (only-ever-reduce, same safe mechanism as the flick
            -- bleed). This is the hard "cap on steering" that keeps the car catchable.
            local fwd = state.forwardSpeed or 0.0
            local lat = state.lateralSpeed or 0.0
            if fwd > 1.0 and kmh >= (afcfg.MinSpeedKmh or 20.0) then
                local slipDeg  = math.abs(math.deg(math.atan(lat / fwd)))
                local startDeg = afcfg.StartDeg or 5.0
                local minFull  = afcfg.MinFullDeg or 11.235
                local capOpen  = commitCapApplied * ((afcfg.FullDeg or 24.85) - minFull)
                local effFull  = math.min(minFull + capOpen, afcfg.FullDeg or 24.85) + commitExtraApplied
                if slipDeg > startDeg then
                    local f = clamp((slipDeg - startDeg) / math.max(effFull - startDeg, 0.01), 0.0, 1.0)
                    loss = loss + ((afcfg.FirmTarget or 0.45) - loss) * f * (afcfg.Strength or 1.0)
                    if afcfg.YawLimit ~= false and slipDeg >= effFull then
                        local av = state.angularVelocity
                        if av then setYaw(veh, av.z * math.exp(-(afcfg.YawLimitDamp or 7.0) * f * dt)) end
                    end
                end
                HK.dbgDrift.slipDeg = slipDeg; HK.dbgDrift.effFull = effFull
            end
        end
    end

    applyDriftGrip(veh, cfg, slideDepth, loss)

    -----------------------------------------------------------------
    -- REGIME A — LOW-SPEED LAUNCH EMPHASIS (the "high torque vs grip" fry off the
    -- line). NO velocity injection — the car moves ONLY through real drive force. Two
    -- levers, both fading out by LaunchFadeKmh:
    --   1) TORQUE HOLD — boost the shared torque so the driven axle OVERPOWERS the
    --      reduced rear grip. Held in a low gear (HK.driftHoldGear) this rides the
    --      engine into the limiter = high rpm + high torque at low road speed = the
    --      real "high-rev launch" flare (natural, from the gearing — no fake paint).
    --   2) REAR GRIP-LOSS — override the PRIVATE slide-cliff native up so the REAR
    --      breaks traction and SPINS (applyDriftGrip pins it near stock down low via
    --      GripFloor to keep FRONT grip for steering — that alone kills the fry). The
    --      spinning driven tyres are what push the car forward: forward motion EMERGES
    --      from the wheelspin via GTA physics, it is not added. Front curves untouched
    --      = front keeps grip = the car still steers as it slides forward.
    -----------------------------------------------------------------
    if wLaunch > 0.0 and thr > (rc.DriveThrottleGate or 0.15) and not (DriftDbg and DriftDbg.drive == false) then
        -- TORQUE HOLD: multiply the shared torque so the driven axle overpowers the
        -- (reduced) grip and keeps frying — this is the "longer torque at launch".
        local tqHold = 1.0 + ((rc.LaunchTorqueMult or 1.7) - 1.0) * wLaunch * thr
        HK.torqueMult = (HK.torqueMult or 1.0) * tqHold

        -- LAUNCH WHEELSPIN: override the PRIVATE slide-cliff native so the REAR
        -- fries off the line (applyDriftGrip pinned it near stock via GripFloor to
        -- keep FRONT grip for steering — but that killed the rear fry). Blend stock
        -- 1.0 → LaunchLossMult by launch intensity. Shared curves untouched = front
        -- keeps grip = still steers. Only the private (rear-only) native moves.
        if cfg.UseTractionLossOverride and not (DriftDbg and DriftDbg.grip == false) then
            local lm = rc.LaunchLossMult or 1.6
            local launchLoss = 1.0 + (lm - 1.0) * wLaunch * thr
            if launchLoss > lastLossApplied then
                vl_setTractionLossMult(veh, launchLoss)
                lastLossApplied = launchLoss
                HK.dbgDrift.launchLoss = launchLoss
            end
        end

        HK.dbgDrift.tqHold = tqHold; HK.dbgDrift.drive = 0.0
        -- UNIFIED BURNOUT: publish the wheelspin-gesture flag so the gauge, gearbox
        -- coupling (control-72 exemption) and launch-traction "busy" check treat this
        -- drift launch exactly like the old burnout gesture. burnout.lua's own
        -- Burnout_WheelspinTick stands down while HK.driftMode is true (regime A owns it).
        HK.burnoutActive = true
    else
        HK.dbgDrift.tqHold = 1.0; HK.dbgDrift.drive = 0.0
        if wLaunch <= 0.0 then HK.burnoutActive = false end   -- past launch regime: no gesture
    end

    -----------------------------------------------------------------
    -- REGIME C — SLIDE ASSISTS (only meaningful authority once wSlide ramps in).
    -- Counter-steer catch + governor yaw cap. Both speed-gated internally AND
    -- physics-safe-gated, and both only ever REDUCE |yaw| (never add rotation),
    -- so they cannot doughnut or fire at the standstill launch.
    -----------------------------------------------------------------
    if wSlide > 0.0 then
        local scfg = cfg.Stabilizer
        local safe = scfg and scfg.Enabled and DriftMode_PhysicsSafe(veh, state, scfg) or false

        if not (DriftDbg and DriftDbg.csteer == false) and cfg.CounterSteer and cfg.CounterSteer.Enabled then
            DriftMode_CounterSteerTick(veh, state, dt)
        elseif csActive then
            csActive = false; csAngle = 0.0
        end

        -- GOVERNOR YAW CAP: past a speed-dependent yaw ceiling, damp the OVERSHOOT
        -- so the angle stops growing into a spin at speed. Only-ever-reduce-yaw.
        local gcfg = cfg.Governor
        if safe and gcfg and gcfg.Enabled and gcfg.YawCapEnabled and not (DriftDbg and DriftDbg.gov == false)
           and not (transWindowUntil > 0 and now < transWindowUntil) then
            local gsf = lerpClamp(kmh, gcfg.StartKmh or 30.0, gcfg.FullKmh or 180.0, 0.0, 1.0)
            if gsf > 0.0 then
                local cap = (gcfg.YawCapLow or 1.30) + ((gcfg.YawCapHigh or 0.55) - (gcfg.YawCapLow or 1.30)) * gsf
                local yaw = state.yawRate or 0.0
                local ayaw = math.abs(yaw)
                if cap > 0.0 and ayaw > cap then
                    local over = (ayaw - cap) / cap
                    local factor = math.exp(-(gcfg.YawCapDamp or 4.0) * math.min(over, 1.0) * dt)
                    local av = state.angularVelocity
                    if av then
                        local newZ = av.z * factor
                        if math.abs(newZ) < cap then newZ = (av.z >= 0) and cap or -cap end
                        setYaw(veh, newZ)
                    end
                end
            end
        end
    elseif csActive then
        csActive = false; csAngle = 0.0
    end

    firstFrameThisEnable = false
end

-----------------------------------------------------------------
-- DISABLE: undo everything once. Grip is handed back via the ARBITER (release the
-- claim → committer restores the shared curves ONCE, no last-writer race). The
-- private slide-cliff native is ramped back by the recovery tick (armed here),
-- not snapped — an instant grip return while still rotating spins the car.
-----------------------------------------------------------------
function DriftMode_Disable(veh)
    if not driftApplied then return end
    driftApplied = false
    -- Release the gear ceiling + spin-rpm pin so the box resumes normal shifting/revs.
    HK.driftHoldGear = false
    HK.driftSpinRpm = nil; spinArmed = false; spinPeakRpm = 0.0; spinPinStart = 0; spinSettleSince = 0
    spinPaintRpm = 0.0; spinBouncePhase = 0.0
    -- Clear the S-key-wheelspin flags + drop any forced burnout (drift key released ends it).
    HK.driftNoBrakeSpin = false; HK.driftSpinActive = false
    if snbForcing and veh and veh ~= 0 and DoesEntityExist(veh) then vl_setBurnout(veh, false) end
    snbForcing = false
    if not veh or veh == 0 or not DoesEntityExist(veh) then return end
    local cfg = Config.Drift

    if cfg.UseDriftTyres then vl_setDriftTyres(veh, false) end
    if cfg.UseReducedSuspension then vl_setReducedSuspension(veh, false) end
    if hbUntil > 0 then vl_setHandbrake(veh, false); hbUntil = 0 end
    if cfg.UseReduceGripOnHandbrake then vl_setReduceGrip(veh, false) end

    -- PRIVATE handling fields drift set directly → restore now (not the source of
    -- the exit snap once the grip cliff is arbiter-owned).
    vl_restoreField(veh, 'fSteeringLock')
    vl_restoreField(veh, 'fTractionBiasFront')

    -- SHARED curve fields: stop claiming → arbiter restores ONCE on the first
    -- no-claim commit (single-writer). Legacy path restores directly.
    if DriftClaimsGrip() then
        if HK.gripRelease then HK.gripRelease('drift') end
    else
        vl_restoreField(veh, 'fTractionCurveMax')
        vl_restoreField(veh, 'fTractionCurveMin')
        vl_restoreField(veh, 'fLowSpeedTractionLossMult')
    end

    -- EXIT RECOVERY: arm the window (ramp the private loss native back to 1.0 +
    -- bleed leftover yaw) instead of snapping. Only when moving fast enough to
    -- carry catchable yaw; otherwise restore instantly + hand AWD bias back.
    local rec = cfg.Recovery
    local kmh = GetEntitySpeed(veh) * 3.6
    if rec and rec.Enabled and cfg.UseTractionLossOverride and kmh >= (rec.MinSpeedKmh or 0.0) then
        local now = GetGameTimer()
        recoveryStart = now
        recoveryUntil = now + (rec.DurationMs or 800)
        recoveryVeh   = veh
        -- leave the loss native where the tick left it; recovery ramps from there.
    else
        if cfg.UseTractionLossOverride then vl_setTractionLossMult(veh, 1.0); lastLossApplied = 1.0 end
        if awdDriftShifted then
            vl_restoreField(veh, 'fDriveBiasFront')
            awdDriftShifted = false; awdDriftBiasApplied = nil; awdDriftBiasNative = nil
        end
    end
end

-----------------------------------------------------------------
-- EXIT RECOVERY TICK — ramp the PRIVATE slide-cliff native back to stock over the
-- window + gently bleed leftover yaw so the car recenters instead of snapping.
-- The SHARED curves are NOT touched here — the arbiter already handed them back
-- once on release (that was the old "recovery out of place" race: recovery wrote
-- grip directly and lost to whatever else was claiming). AWD drive-bias is ramped
-- back across the window too. Called from main.lua while RecoveryActive().
-----------------------------------------------------------------
function DriftMode_RecoveryTick(veh, state, dt)
    local cfg = Config.Drift
    local rec = cfg and cfg.Recovery
    if not rec or not rec.Enabled or recoveryUntil == 0 then return end
    if not veh or veh == 0 or veh ~= recoveryVeh or not DoesEntityExist(veh) then
        recoveryUntil = 0; recoveryVeh = 0; return
    end

    local now = GetGameTimer()
    local dur = rec.DurationMs or 800
    local p = clamp((now - recoveryStart) / math.max(dur, 1), 0.0, 1.0)   -- 0..1 window progress

    -- GRIP RAMP: ease the private loss native from where the tick left it back to
    -- 1.0 (stock) across the window. Smoothstep so it eases on and off.
    if cfg.UseTractionLossOverride then
        local s = p * p * (3.0 - 2.0 * p)
        local val = lastLossApplied + (1.0 - lastLossApplied) * s
        vl_setTractionLossMult(veh, val)
    end

    -- YAW BLEED: only-ever-reduce |yaw|, eased in over the hold-off then decaying.
    local holdoff = (rec.RecenterHoldoffMs or 0.0) / math.max(dur, 1)
    if p > holdoff then
        local damp = (rec.YawDampStart or 0.9) * (1.0 - p)   -- decays to 0 by window end
        -- speed-scale: bleed big yaw faster up top
        local kmh = state.speedKmh or (GetEntitySpeed(veh) * 3.6)
        damp = damp * lerpClamp(kmh, rec.SpeedLowKmh or 40.0, rec.SpeedHighKmh or 160.0, 1.0, rec.YawDampHighMult or 2.2)
        if damp > 0.0 then
            local av = state.angularVelocity or GetEntityRotationVelocity(veh)
            if av then setYaw(veh, av.z * math.exp(-damp * dt)) end
        end
    end

    -- AWD DRIVE-BIAS RAMP: move fDriveBiasFront back to native across the window.
    if awdDriftShifted and awdDriftBiasApplied and awdDriftBiasNative then
        local val = awdDriftBiasApplied + (awdDriftBiasNative - awdDriftBiasApplied) * p
        vl_setHandling(veh, 'fDriveBiasFront', val)
    end

    -- WINDOW CLOSE.
    if now >= recoveryUntil then
        if cfg.UseTractionLossOverride then vl_setTractionLossMult(veh, 1.0); lastLossApplied = 1.0 end
        if awdDriftShifted then
            vl_restoreField(veh, 'fDriveBiasFront')
            awdDriftShifted = false; awdDriftBiasApplied = nil; awdDriftBiasNative = nil
        end
        recoveryUntil = 0; recoveryVeh = 0
    end
end

function DriftMode_RecoveryActive() return recoveryUntil ~= 0 end
function DriftMode_AwdBiasRamping() return awdDriftShifted and recoveryUntil ~= 0 end

-----------------------------------------------------------------
-- FULL RESET (vehicle swap / resource stop): drop all state cleanly.
-----------------------------------------------------------------
function DriftMode_Reset()
    driftApplied = false
    isFWD = false
    hbUntil = 0
    fwdTuckUntil = 0
    lastLossApplied = 1.0
    awdDriftShifted = false; awdDriftBiasApplied = nil; awdDriftBiasNative = nil
    csActive = false; csAngle = 0.0
    transWindowUntil = 0; lastSteerSign = 0
    commitCapSteps = 0; commitCapHoldRamp = 0.0; commitCapApplied = 0.0
    commitRiseT = 0.0; commitExtraDeg = 0.0; commitExtraApplied = 0.0
    handbrakeLastState = false
    HK.driftHoldGear = false
    HK.driftSpinRpm = nil; spinArmed = false; spinPeakRpm = 0.0; spinPinStart = 0; spinSettleSince = 0
    spinPaintRpm = 0.0; spinBouncePhase = 0.0
    HK.driftNoBrakeSpin = false; HK.driftSpinActive = false; HK.driftSpinReleaseAt = 0
    snbForcing = false; snbEligible = false; snbEligVeh = 0
    recoveryUntil = 0; recoveryStart = 0; recoveryVeh = 0
    lastSpeed = nil; crashExitCooldown = 0
    firstFrameThisEnable = true
    collisionCooldownUntil = 0
end

-----------------------------------------------------------------
-- DEBUG: /driftdbg [key]  — toggle a subsystem's isolation flag, or report all.
-----------------------------------------------------------------
RegisterCommand('driftdbg', function(_, args)
    local key = args[1]
    local order = { 'drive', 'grip', 'csteer', 'gov', 'cap', 'flick', 'yawwrite' }
    local function report()
        local parts = {}
        for _, k in ipairs(order) do parts[#parts+1] = k .. '=' .. tostring(DriftDbg[k]) end
        local msg = table.concat(parts, '  ')
        print('[driftdbg] ' .. msg)
        TriggerEvent('chat:addMessage', { args = { '[driftdbg]', msg } })
    end
    if not key then report(); return end
    if key == 'off' or key == 'on' then
        local v = (key == 'on')
        for _, k in ipairs(order) do DriftDbg[k] = v end
        report(); return
    end
    if DriftDbg[key] == nil then
        TriggerEvent('chat:addMessage', { args = { '[driftdbg]', 'unknown key: ' .. tostring(key) } })
        return
    end
    DriftDbg[key] = not DriftDbg[key]
    report()
end, false)
