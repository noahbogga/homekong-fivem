-----------------------------------------------------------------
-- hk-handling :: client/wheelie.lua
-- [F1] Controlled Wheelie — hold key under power to lift the nose,
--      self-limiting pitch so the car balances instead of looping.
-- [F2] Drag Launch Headlift — automatic gentle nose lift during a
--      hard standing start (synergizes with Launch Control).
--
-- NOTE on pitch sign: GetEntityRotation (order 2) reports pitch as
-- rot.x. On most vehicles NOSE-UP is POSITIVE. If wheelies feel
-- inverted in-game, flip the sign of `pitch` below (one-line change).
-----------------------------------------------------------------

local vehlib = exports['hk-vehlib']
local function bind(fn) return function(...) return fn(nil, ...) end end
-- Cache export refs once (avoids per-frame wrapper-closure GC churn; see gearbox.lua).
local vl_applyForce  = bind(vehlib.applyForce)
local vl_getHandling = bind(vehlib.getHandling)
local vl_smoothstep  = bind(vehlib.smoothstep)
-- 2026-08-14 REAR-THRUST RERAMP: the nose-lift is now driven by REAR THRUST = drive torque × how
-- HOOKED the rear tyres are (grip fraction), measured live from wheelspin — the physically-correct
-- wheelie driver (front lifts as a REACTION to the rears biting), replacing the old measured-accel
-- proxy. vl_detectWheelspin(veh, thresh) -> spinning, worstDiff(m/s): driven-wheel over-speed vs
-- ground speed, IMMUNE to our rpm paint (it reads GetVehicleWheelSpeed, a physical measurement).
local vl_detectWheelspin = bind(vehlib.detectWheelspin)

-- 2026-08-14 REBUILD — the ORIGINAL wheelie/headlift used vehlib.applyLift, a NET UPWARD
-- force via ApplyForceToEntity forceType 1 (IMPULSE). That is the EXACT blow-up that
-- killed downforce: an impulse compounds Δv every frame, so a per-frame upward impulse
-- launched the car / choked the physics solver into slow-motion (see the hk-handling
-- downforce memory). FIX = a PITCH COUPLE with forceType 0 (continuous, non-compounding):
-- an up-force at the FRONT + an EQUAL down-force at the REAR. Net linear force = ZERO
-- (cannot translate/launch the car), net effect = pure nose-up pitch torque — the same
-- net-zero-couple trick drift's yaw force uses safely in production. FORCE_TYPE_FORCE (0)
-- is a steady per-frame force (self-limits against the pitch fade below), not a Δv kick.
-- 2026-08-14 v3 — the force COUPLE (v2) still launched the car: two big +Z/-Z forces at
-- ±2.2m only cancel in theory; in the solver, with the rear tyres planted the whole body
-- pivots off the back and takes off. The correct primitive for "ONLY the nose rotates up,
-- the car does NOT move" is a PURE PITCH TORQUE — forceType 4 (TORQUE). With type 4 the
-- vector IS a torque about the CoM (offset ignored), so net LINEAR force is exactly zero:
-- the centre of mass physically cannot translate, it can only rotate. Nose-up = torque
-- about the vehicle-local -X axis (pitch). Continuous (re-applied per frame), self-limiting
-- against the pitch fade below.
local FORCE_TYPE_TORQUE = 4

-- 2026-08-14 v4 — THE ROOT-CAUSE FIX. forceType 4 was NEVER a torque here. The GTA enum is
-- DISPUTED across sources: Cfx docs say 4 = APPLY_TYPE_TORQUE, but the RAGE/GTA enum says
-- 4 = FORCE_NO_ROT (a LINEAR force with rotation suppressed). Nothing else in this entire
-- codebase uses forceType 4 — drift's proven yaw rotation uses a force COUPLE at the default
-- type, not 4. So our single flat right-vector "(mag·rx, mag·ry, 0)" was applied as a pure
-- SIDEWAYS PUSH at the CoM → the exact "bog that bounces the car left/right" symptom. No axis,
-- sign, or magnitude tuning could ever fix it because it wasn't rotating the car at all.
--
-- FIX = the PROVEN rotation primitive already trusted in production: SetEntityAngularVelocity,
-- exactly as drivetrain's applyYawScale uses it. It can ONLY rotate the body about its CoM — it
-- physically cannot translate the car, so a sideways bog is impossible by construction. We drive
-- the LOCAL pitch axis toward a nose-up rate and write roll + yaw straight back UNTOUCHED (so we
-- never inject roll). Same matrix decomposition as applyYawScale: pitch→rightV, roll→forwardV,
-- yaw→upV. SIGN: the ISOLATION PROBE established local pitch-rate > 0 == nose-UP (it labelled the
-- launch "noseUP" at +pr), so a positive target here lifts the nose.
-- rollDamp (2026-08-14): 0..1 scale kept on the LOCAL roll rate while we lift. 1.0 = roll left fully
-- untouched (the characterful "one wheel first + countersteer" feel); lower CENTRES the lift by bleeding
-- the launch body-roll so both front wheels come up together. The ×2.5 force amplified the small natural
-- roll into a visible one-wheel-up-first, so we damp roll IN PROPORTION to how hard we're lifting.
-- yawDamp (2026-08-14): same idea on the LOCAL yaw rate. Boosting launch speed/torque with the front
-- light lets rear wheelspin walk the car left/right; bleeding a slice of yaw while lifting keeps it
-- tracking straighter WITHOUT killing the driver's own steering (we only shrink |yaw|, never add).
local function addPitchRate(veh, targetRate, rollDamp, yawDamp)
    if targetRate <= 0.0 then return end
    local lav = GetEntityRotationVelocity(veh)   -- LOCAL rad/s: x=pitch, y=roll, z=yaw
    -- Only ever ADD nose-up: if the body is already pitching up faster than our target (e.g. a
    -- ramp), leave it — never yank the rate DOWN (that would fight real physics). No accumulation:
    -- we SET toward a bounded target each frame, not add on top of last frame's value.
    local newPitch = lav.x
    if targetRate > newPitch then newPitch = targetRate end
    -- ROLL LEVELLING: scale the roll rate toward 0 (only ever SHRINKS |roll| — can't add roll/flip).
    local newRoll = lav.y
    if rollDamp and rollDamp < 1.0 then newRoll = lav.y * rollDamp end
    -- YAW LEVELLING: scale the yaw rate toward 0 (only ever SHRINKS |yaw| — steer-in still works).
    local newYaw = lav.z
    if yawDamp and yawDamp < 1.0 then newYaw = lav.z * yawDamp end
    if newPitch == lav.x and newRoll == lav.y and newYaw == lav.z then return end   -- nothing to change this frame

    local m1, m2, m3 = GetEntityMatrix(veh)
    local fwdV = GetEntityForwardVector(veh)
    local function dot(a, b) return a.x*b.x + a.y*b.y + a.z*b.z end
    local cand = { m1, m2, m3 }
    local fi, best = 1, math.abs(dot(m1, fwdV))
    for i = 2, 3 do
        local d = math.abs(dot(cand[i], fwdV))
        if d > best then best, fi = d, i end
    end
    local forwardV = cand[fi]
    local r1, r2
    for i = 1, 3 do if i ~= fi then if not r1 then r1 = cand[i] else r2 = cand[i] end end end
    local upV, rightV
    if math.abs(r1.z) >= math.abs(r2.z) then upV, rightV = r1, r2 else upV, rightV = r2, r1 end
    if math.abs(upV.z) < 0.35 then return end   -- near-flip: let physics own it (same guard as applyYawScale)

    -- world = rightV*pitch + forwardV*roll + upV*yaw
    local wx = rightV.x*newPitch + forwardV.x*newRoll + upV.x*newYaw
    local wy = rightV.y*newPitch + forwardV.y*newRoll + upV.y*newYaw
    local wz = rightV.z*newPitch + forwardV.z*newRoll + upV.z*newYaw
    SetEntityAngularVelocity(veh, wx, wy, wz)
end

-----------------------------------------------------------------
-- [F1] CONTROLLED WHEELIE
-----------------------------------------------------------------

-- 2026-08-14 v2 — LAUNCH-DRIVEN (no key). The wheelie is now a LAUNCH-SEQUENCE effect on
-- MUSCLE cars only, triggered automatically:
--   AUTOMATIC muscle -> active only while launch mode is live (HK.launching, the LC boost window).
--   MANUAL   muscle -> fires on the N->1 shift edge (the clutch-dump launch) + holds a short window.
-- HK.wheelieHeld / the alt key are no longer used here.
local wheelieFactor = 0.0     -- smoothed 0..1 ramp (slow rise, fast fall)
local wheeliePrevGear = nil   -- last frame's gear (kept for dbg / future use)
local wheelieLaunchUntil = 0  -- gameTimer deadline the launch-lift window is held to
local wheeliePrevFwd = 0.0    -- last frame's forward speed, for accel measurement
local wheelieAccel = 0.0      -- smoothed longitudinal accel (m/s^2)
local wheeliePrevPitch = 0.0  -- last frame's pitch, for detecting the top of a bounce
-- BOUNCE STATE MACHINE (2026-08-14). The wheelie is now 1 or 2 DISCRETE bounces, not a sustained
-- hold: nose punches UP (rising), the pitch fade eases it over the top, it falls back (falling), and
-- ONLY a fast + hard-pulling car gets a 2nd, weaker spring-back bounce (gravity vs suspension). Max 2.
local wheelieBouncePhase = 'idle' -- 'idle' | 'rising' | 'falling'
local wheelieBounceN = 0          -- how many bounces this launch has started
local wheelieBounceMax = 1        -- how many bounces THIS launch is allowed (1, or 2 for fast cars)
local wheelieEngaged = false      -- armed for this launch (consumed until we settle / relaunch)
local wheelieBounceMag = 1.0      -- this bounce's peak scale (decays per bounce = spring-back)
local wheelieOnset  = 0.0         -- 0..1 force-onset ramp: eases the lift torque IN so it doesn't slam
local wheelieModFrac = 0.0        -- 0 = stock, 1 = fully modded: sampled once per launch (arm)
local wheelieForceRand = 1.0      -- per-launch random force multiplier (1 ± PitchRateRandomPct), rolled at arm
-- PATH B — DELIBERATE IN-GEAR WHEELIE (2026-08-14 v3, S-RELEASE TRANSIENT). SEPARATE from the frozen
-- launch wheelie (Path A). While ALREADY driving in gears SeqMinGear..SeqMaxGear, in drift mode, going
-- STRAIGHT, on the gas: HOLD S to LOAD the driveline (rev/torque against the brake), then RELEASE S ->
-- the snap-release fires the nose up. This is the clutch-up / snap wheelie, NOT the wheelspin wheelie:
-- it does NOT need the tyres to break loose (which the log proved only happens in gears 1-2), so it
-- works up to gear 4 — but the log also showed rpm loads LOWER the taller the gear, so we scale the
-- lift strength DOWN by gear (gear 1 = full send, tall gears = a gentle ramp-up loft, like real life).
-- Steering past the gate locks it out. NO clamp — wrong timing can loop/crash (user intent).
local wheelieNormalUntil = 0      -- window the Path-B lift is held open to after the S-release fire
local wheelieSeqLoadMs   = 0.0    -- ms the load state (drift+S+gas+straight+rpm) has been held
local wheeliePrevBrakeHeld = false -- last frame's footbrake-held, for the S-RELEASE edge detect
local wheelieLastSpinRelAt = 0    -- last consumed HK.driftSpinReleaseAt stamp (fire Path B once per spin)
local wheelieArmSource   = nil    -- 'launch' | 'normal' — which path armed the current window (gear scale + dbg)
-- RPM PIN (2026-08-14 reramp): a real drag wheelie holds the engine at/near REDLINE the whole time
-- the nose is up — the rears are hooked and driving hard, rpm can't bog. Capture the peak rpm reached
-- during the lift and PIN the needle there while the nose is genuinely up (mirrors the confirmed-good
-- HK.driftSpinRpm pattern: cosmetic paint via vl_setRpmRaw as the frame's LAST rpm writer, in main.lua).
-- Safe on auto boxes ONLY because we also HOLD the launch gear while pinning (HK.wheelieHoldGear) so the
-- painted-high rpm can't trip a phantom upshift — exactly why the drift gear-ceiling makes its pin safe.
local wheeliePeakRpm = 0.0
-- SHOOT MODEL (2026-08-14): peak-hold of the rear-wheel slip = "how loaded the rears GOT" this launch.
-- Rises to any new slip peak instantly, bleeds slowly, so the forward-yank lift survives the split
-- second the slip collapses when the tyres hook. Reset on veh-swap / disengage.
local wheelieSpinEnergy = 0.0
-- FRONT-WHEELS-OFF TRACKING (2026-08-14, user): the gear-hold / rpm-max / speed+torque boost gate on
-- the ACTUAL front wheels being off the ground (measured, NOT pitch). wheelieWasAir = were they off
-- last frame, so we can stamp the landing-settle deadline the instant they touch back down.
local wheelieWasAir = false

-- MOD LEVEL 0..1 for THIS car — how built the engine/transmission/turbo are. Drives both how
-- hard the nose lifts AND how insane the forward drag-pull is: a stock car barely lifts + pulls
-- gently, a full-mod car does the old-school drag "yank away". Uses the SetVehicleModKit-before-read
-- discipline (see the modkit-flicker memory) so GetVehicleMod returns real values, not -1 flicker.
-- Engine (mod 11) + transmission (mod 13) are 0..3 tiers; turbo (mod 18) is a 0/1 toggle. Weighted
-- so a maxed engine dominates, turbo adds the final kick. Returns 0..1.
local function wheelieModLevel(veh)
    if veh == 0 then return 0.0 end
    SetVehicleModKit(veh, 0)                       -- MUST set the kit before reads or mods report -1
    local eng = GetVehicleMod(veh, 11)             -- engine tier: -1 none, 0..3
    local trn = GetVehicleMod(veh, 13)             -- transmission tier: -1 none, 0..3
    local turbo = IsToggleModOn(veh, 18) and 1 or 0
    if eng < 0 then eng = 0 end
    if trn < 0 then trn = 0 end
    -- engine 60% + transmission 25% + turbo 15%. Each tier maps 0..3 -> 0..1.
    local frac = (eng / 3.0) * 0.60 + (trn / 3.0) * 0.25 + turbo * 0.15
    if frac < 0.0 then frac = 0.0 elseif frac > 1.0 then frac = 1.0 end
    return frac
end

-- FRONT WHEELS OFF THE GROUND — the ACTUAL wheel test the user asked for (NOT nose pitch). Wheel
-- indices: 0=FL 1=FR 2=RL 3=RR. On a launch the rears physically cannot lift, so "some wheel off but
-- the car is NOT airborne" (the proven wheelie test at gearbox.lua ~6476) means the FRONT is up. We
-- confirm with GetVehicleWheelSurfaceMaterial on the two front wheels: it reports the ground material
-- under a wheel and reads a sentinel (typically -1 / a huge uint) when the wheel is in the air. Require
-- BOTH: the car not fully on its wheels AND not a real jump. Belt-and-braces so a genuine air-time
-- (IsEntityInAir) never counts, and a normal grounded launch never false-positives.
local function frontWheelsOff(veh, state)
    if not veh or veh == 0 then return false end
    local inAir = IsEntityInAir(veh)
    local onAll = state and state.onAllWheels
    if onAll == nil then onAll = IsVehicleOnAllWheels(veh) end
    -- RAW CAPTURE (2026-08-14): the surface-material sentinel guess was wrong (always read grounded
    -- though the nose visibly lifts), so publish the real values to /handlingdbg to see what air reads.
    local flTouch = GetVehicleWheelSurfaceMaterial(veh, 0)
    local frTouch = GetVehicleWheelSurfaceMaterial(veh, 1)
    if HK then
        HK.dbgFOraw = { inAir = inAir, onAll = onAll, fl = flTouch, fr = frTouch }
    end
    -- PRIMARY TEST (the proven wheelie test from gearbox.lua ~6476): a wheel is off the ground but the
    -- car is NOT a genuine jump. On a launch the REARS physically cannot lift, so this = the FRONT is up.
    -- No longer requires the surface-material sentinel (that guess never fired). IsEntityInAir alone can
    -- flick true on a hard nose-up, so DON'T hard-bail on it — only treat it as a jump if ALL wheels are
    -- off (a true launch-off-a-crest), which onAll can't tell us; keep it lenient: front off = not onAll.
    if onAll then return false end                              -- all four planted = no lift
    return true
end

-- ================================================================================================
-- FRONT-WHEELS-OFF PHYSICS (2026-08-14, user). Gates on the ACTUAL front wheels being off the ground
-- (frontWheelsOff — measured, NOT nose pitch). Runs EVERY engaged frame regardless of bounce phase,
-- because the front can still be up during 'falling'. While the front is up:
--   • HOLD THE GEAR + block auto-upshift (AUTO cars only — a manual driver owns their own shifts).
--   • PIN RPM to max ("MAX RPM WHEN LIFTED UP") — the needle can't bog with only the rears driving.
--   • RAISE THE SPEED CAP + flag a torque boost (main.lua) so it keeps accelerating hard at redline,
--     since on two contact patches GTA delivers less drive and would otherwise stall at the limiter.
-- The auto-upshift is deferred until ~UpshiftLandMs AFTER the front touches back down (a real car
-- settles, THEN grabs the next gear) — stamped on the air->ground edge.
-- ================================================================================================
function wheelieFrontOffPhysics(veh, state, cfg, isManual)
    local frontOff = frontWheelsOff(veh, state)
    HK.wheelieSpinRpm = nil
    HK.wheelieHoldGear = false
    HK.wheelieSpeedCapBoost = nil
    -- THROTTLE GATE (2026-09-07 — user: "wheelie cars pin to MAX RPM whenever airborne, even just
    -- hanging up, WITHOUT pressing throttle"). frontWheelsOff() returns true for ANY non-planted
    -- state (onAllWheels false) with no pedal test — so a car merely hanging in the air (a jump, a
    -- crest, a nose-up) got its needle pinned to redline off-throttle. A REAL wheelie/launch is
    -- always ON THE GAS, so only pin rpm / hold the gear / boost the cap when the driver is actually
    -- applying throttle. Off-gas airborne now falls through to the normal rpm model (needle follows
    -- the free-spinning wheels / decays naturally) instead of a false redline pin.
    local onGasNow = (state.effThrottle or state.throttle or 0.0) >= (cfg.MinThrottle or 0.85)
    if frontOff and onGasNow then
        local rpmNow = state.rpm or 0.0
        if rpmNow > wheeliePeakRpm then wheeliePeakRpm = rpmNow end
        local pinTo = math.max(wheeliePeakRpm, cfg.RpmPinTarget or 0.98)
        if pinTo > 1.0 then pinTo = 1.0 end
        HK.wheelieSpinRpm = pinTo
        if not isManual then HK.wheelieHoldGear = true end     -- gear hold AUTO-only
        HK.wheelieSpeedCapBoost = cfg.SpeedCapBoost or 1.15
        HK.wheelieFrontOff = true
        wheelieWasAir = true
    else
        HK.wheelieFrontOff = false
        if wheelieWasAir then
            HK.wheelieUpshiftLandUntil = (state.gameTimer or GetGameTimer()) + (cfg.UpshiftLandMs or 120)
            wheelieWasAir = false
        end
    end
end

function Wheelie_Tick(veh, state, dt)
    local cfg = Config.Wheelie

    local pitch = state.pitch   -- nose-up positive (see header note)

    -- ISOLATION PROBE (2026-08-26 v2 — PEAK-CAPTURE + FREEZE). The raw per-frame rate flickered too
    -- fast to read, so instead we CAPTURE the largest rotation of the launch and HOLD it on screen for
    -- HoldMs after, plus snapshot WHICH module was active at that peak instant. GetEntityRotationVelocity
    -- is LOCAL rad/s: x=pitch (nose up/down), y=roll (side/side), z=yaw (flat spin / rear step-out).
    -- Read the frozen ROTDBG line AFTER the launch — it names the worst axis and who was applying force.
    if HK and HK.hdbgOn and veh ~= 0 then
        local av = GetEntityRotationVelocity(veh)
        local pr, rr, yr = av and av.x or 0.0, av and av.y or 0.0, av and av.z or 0.0
        local now = state.gameTimer or GetGameTimer()
        -- magnitude of the worst single axis this frame
        local worstMag, worstAxis = math.abs(pr), 'pitch'
        if math.abs(rr) > worstMag then worstMag, worstAxis = math.abs(rr), 'roll' end
        if math.abs(yr) > worstMag then worstMag, worstAxis = math.abs(yr), 'yaw' end

        HK.dbgRotHold = HK.dbgRotHold or { until_ = 0, pPk = 0.0, rPk = 0.0, yPk = 0.0 }
        local H = HK.dbgRotHold
        -- Window expired -> reset ALL three axis peaks and start fresh.
        if now > (H.until_ or 0) then
            H.pPk, H.rPk, H.yPk = 0.0, 0.0, 0.0
            H.rollAtCut = false
        end
        -- Track EACH axis's peak INDEPENDENTLY (the whole point: a small ROLL under a big nose-up
        -- pitch was being masked by "worst single axis"). Keep the signed value at each axis's peak.
        if math.abs(pr) > H.pPk then H.pPk = math.abs(pr); H.prS = pr end
        if math.abs(rr) > H.rPk then
            H.rPk = math.abs(rr); H.rrS = rr
            -- Snapshot WHO was active at the ROLL peak specifically — that's the sideways culprit.
            -- 2026-08-14: FIXED field mapping. The old probe read HK.dbgFwd (FWD-only) on a muscle/RWD
            -- car so it ALWAYS showed 0 and could hide the real writer. Now capture the FULL RWD arsenal
            -- (dbgRwd.{po,cs,lift,spin,plant,rot,brake,pspin,legacy}) as one worst-factor number, plus
            -- the launch/wheelie state, so the frozen line can't lie about who was engaged at the roll.
            H.rKmh   = state.speedKmh or 0.0
            H.rCut   = (HK.airForceCut == true)
            H.rWmag  = (HK.dbgWheelie and HK.dbgWheelie.mag) or 0.0
            H.rLaunch = (HK.launching == true)
            local rw = HK.dbgRwd or {}
            -- worst engagement across every RWD tool that could write a force this frame
            local rwdWorst, rwdWho = 0.0, '-'
            for k, v in pairs({ po = rw.po, cs = rw.cs, lift = rw.lift, spin = rw.spin,
                                plant = rw.plant, rot = rw.rot, brake = rw.brake,
                                pspin = rw.pspin, legacy = rw.legacy }) do
                if type(v) == 'number' and v > rwdWorst then rwdWorst, rwdWho = v, k end
            end
            H.rRwd   = rwdWorst
            H.rRwdWho = rwdWho
            -- SpinSoftener specifically (the only ungated straight-line yaw writer) — call it out separately
            H.rSpin  = rw.spin or 0.0
            local aw = HK.dbgAwd or {}
            local awdWorst = 0.0
            for _, v in ipairs({ aw.tv or 0, aw.gov or 0, aw.save or 0, aw.spinsoft or 0, aw.lift or 0 }) do
                if v > awdWorst then awdWorst = v end
            end
            H.rAwd   = awdWorst
            local fw = HK.dbgFwd or {}
            H.rFwd   = fw.spinsoft or fw.spincut or fw.torqueSteer or fw.lift or 0.0
        end
        if math.abs(yr) > H.yPk then H.yPk = math.abs(yr); H.yrS = yr end
        -- Extend the freeze whenever ANY axis is meaningfully rotating (a launch in progress).
        if worstMag > 0.08 then H.until_ = now + 4000 end
        HK.dbgRot = { pr = pr, rr = rr, yr = yr, air = (state.onAllWheels == false),
                      inair = IsEntityInAir(veh), cut = (HK.airForceCut == true), kmh = state.speedKmh or 0.0 }
    end

    -- CAR-TYPE GATE: MUSCLE (GetVehicleClass == 4), OR a car explicitly OPTED IN via
    -- /setwheelielaunch. The opt-in path exists because giving a custom car the vc_muscle class
    -- makes GTA feed BUGGY handling flags to addon vehicles (the whole reason for the [F3] guard);
    -- marking it vc_sport dodges those bugs, and /setwheelielaunch 1 restores the launch wheelie
    -- on it anyway. DB-PERSISTED per-model (server hk_handling.wheelieLaunch, synced into
    -- HK.manualModels[hash].wheelieLaunch = 1); the session table HK.wheelieLaunchModels is a
    -- fallback for the same-frame local set before the DB round-trip returns. 0 in the DB = an
    -- explicit OFF override that even wins over the muscle class (mark a buggy muscle car vc_sport
    -- AND /setwheelielaunch 0 to fully silence it).
    local mk = GetEntityModel(veh) & 0xFFFFFFFF
    local dbRow = HK.manualModels and HK.manualModels[mk]
    local dbFlag = dbRow and dbRow.wheelieLaunch          -- nil unset | 0 off | 1 on
    local optedIn = (dbFlag == 1) or (HK.wheelieLaunchModels and HK.wheelieLaunchModels[mk])
    local muscle  = (state.class == 4)
    local allowed = (dbFlag ~= 0) and (optedIn or (cfg.OnlyMuscle == false) or muscle)
    if not allowed then
        -- Show WHY it's off (class gate) rather than a blank line, so the dbg screen is useful
        -- on any car. f=0, gate flag set. Cleared only on veh-swap (Wheelie_Reset).
        if HK and HK.hdbgOn then
            HK.dbgWheelie = { f = 0.0, pitch = state.pitch or 0.0, mag = 0.0,
                              gate = 'not-muscle', class = state.class or -1 }
        end
        wheelieFactor = 0.0
        wheeliePrevGear = state.gear or 0
        wheeliePrevFwd = state.forwardSpeed or 0.0
        wheeliePeakRpm = 0.0
        wheelieSpinEnergy = 0.0
        wheelieNormalUntil = 0
        wheelieSeqLoadMs = 0.0
        wheeliePrevBrakeHeld = false
        wheelieLastSpinRelAt = 0
        wheelieArmSource = nil
        HK.wheelieActive = false
        HK.wheelieLiftF = 0.0
        HK.wheelieSpinRpm = nil
        HK.wheelieHoldGear = false
        HK.wheelieFakeSpin = false
        HK.wheelieFrontOff = false
        HK.wheelieSpeedCapBoost = nil
        wheelieWasAir = false
        return
    end

    local g = state.gear or 0

    -- LONGITUDINAL ACCEL (m/s^2), smoothed — this drives how HIGH the nose lifts. A hard
    -- launch (big accel) lifts more; a lazy roll barely lifts. EMA so it isn't 1-frame noise.
    local fwd = state.forwardSpeed or 0.0
    if dt > 0.0 then
        local aRaw = (fwd - (wheeliePrevFwd or fwd)) / dt
        local aTau = cfg.AccelTau or 0.12
        wheelieAccel = wheelieAccel + (aRaw - wheelieAccel) * (1.0 - math.exp(-dt / aTau))
    end
    wheeliePrevFwd = fwd

    -- ============================================================================================
    -- 2026-08-14 SHOOT MODEL (user: "when driver exits brake and SHOOTS OUT the fast-spinning wheels
    -- it PHYSICALLY pulls the vehicle rear-down"). The wheelie is the HOOK event: the rears spin up
    -- (loaded energy), then they BITE and that traction spike yanks the car forward → weight shifts
    -- rearward → nose lifts. So lift ∝ drive torque × HOW MUCH THEY WERE SPINNING (loaded) × HOW MUCH
    -- THEY'RE HOOKING NOW (grip returning). Peaks exactly at "was spinning fast, now gripping".
    -- (This replaces the old grip-HUMP, which peaked mid-slip and collapsed on a hard spin — so it
    -- never armed off a real launch, the reason the wheelie wasn't firing.)
    -- ============================================================================================
    local spinning, worstSpin = vl_detectWheelspin(veh, 0.0)
    worstSpin = worstSpin or 0.0
    local spinFull = cfg.SpinFullMps or 8.0
    -- SPIN ENERGY = peak-hold of the slip with a slow bleed: "how loaded the rears GOT this launch".
    -- Rises instantly to any new peak, decays at SpinEnergyDecay m/s per second so the shoot survives
    -- the split-second the slip actually collapses on the hook.
    if worstSpin > wheelieSpinEnergy then
        wheelieSpinEnergy = worstSpin
    else
        wheelieSpinEnergy = wheelieSpinEnergy - dt * (cfg.SpinEnergyDecay or 6.0)
        if wheelieSpinEnergy < 0.0 then wheelieSpinEnergy = 0.0 end
    end
    local spinEnergyNorm = wheelieSpinEnergy / spinFull
    if spinEnergyNorm > 1.0 then spinEnergyNorm = 1.0 end
    -- HOOK FRAC = how much the rears are biting RIGHT NOW (inverse of current slip): 1 = fully hooked,
    -- 0 = spinning at full. The grip RETURNING is what pulls the car forward.
    local hookFrac = 1.0 - (worstSpin / spinFull)
    if hookFrac < 0.0 then hookFrac = 0.0 elseif hookFrac > 1.0 then hookFrac = 1.0 end
    -- SHOOT 0..1 = loaded energy × currently hooking. High only when it WAS spinning and is NOW gripping.
    local shoot = spinEnergyNorm * hookFrac
    -- Torque fraction 0..1 from the committed drive-torque multiplier (a bog/cut kills lift; boost adds).
    local tqApplied = HK.torqueMultApplied or 1.0
    local tqFloor = cfg.TorqueFloor or 0.5
    local tqMax   = cfg.TorqueForMax or 1.8
    local tqFrac  = tqFloor + (1.0 - tqFloor) * vl_smoothstep(1.0, tqMax, tqApplied)
    if tqFrac < 0.0 then tqFrac = 0.0 elseif tqFrac > 1.0 then tqFrac = 1.0 end
    -- REAR THRUST 0..1 = torque × shoot. The physical lift driver — the forward yank of the hook.
    local rearThrust = tqFrac * shoot

    -- WHEELSPIN PRESENT — the gesture flag OR raw measured slip. Either counts (the burnout gesture may
    -- not have formally armed, but real slip off a hard launch still means the rears are lit).
    local wheelspinNow = (HK.burnoutActive == true) or (worstSpin >= (cfg.SpinArmMps or 3.0))

    -- LAUNCH TRIGGER (2026-08-14 — REVERTED to the LC gate + a DRIFT-KEY + WHEELSPIN check on top).
    -- HK.launching is the authoritative "LC just fired" signal (gearbox.lua). We now ALSO require the
    -- driver to be in DRIFT MODE (caps held) AND the rears to be spinning — miss either and the wheelie
    -- does NOT engage. This makes the wheelie a deliberate act (hold drift + launch + light the rears),
    -- and the spin naturally rides with it. The window holds LaunchWindowMs past the flag so it fades.
    local isManual = (HK.gbManual == true)
    local gateOk = (HK.driftMode == true) and wheelspinNow
    if HK.launching == true and gateOk then
        wheelieLaunchUntil = (state.gameTimer or 0) + (cfg.LaunchWindowMs or 1500)
        if wheelieArmSource == nil then wheelieArmSource = 'launch' end
    end

    -- ============================================================================================
    -- PATH B — DELIBERATE IN-GEAR WHEELIE (2026-08-14 v3, S-RELEASE TRANSIENT). Independent of launch.
    -- LOAD: in drift mode, going STRAIGHT, on the gas, gear in SeqMinGear..SeqMaxGear, rolling in the
    -- Seq speed band, HOLD S — this winds the driveline (the log's rpm/spin climb while drift+W+S held).
    -- FIRE: RELEASE S while still on the gas + straight -> the snap-release opens wheelieNormalUntil.
    -- Requires the load to have been held at least SeqLoadMinMs (so a stab doesn't fire) — the log shows
    -- the wind takes ~200-400ms to build. Does NOT require wheelspin (that's gear-1/2 only); the snap
    -- transient exists in every gear. Lift strength is scaled by gear downstream (SeqGearScale).
    local now = state.gameTimer or GetGameTimer()
    local brakeHeldNow = (HK._pedalBrake or state.effBrake or state.brake or 0.0) > (cfg.SeqBrakeMin or 0.5)
    do
        -- ============================================================================
        -- PATH B REBASE (2026-08-14): the OLD trigger tracked a brake-LOAD-ms then fired on
        -- the S-release edge. That was physically wrong — the drift W+S footbrake BLED speed
        -- + rpm, so a slow car never built the torque the loft needs. drift.lua now owns the
        -- W+S wheelspin (SetVehicleBurnout + torque hold + NO footbrake — the LC-like state
        -- that goes out of the gear-ratio boundary), publishing:
        --   HK.driftSpinActive    — true while a REAL armed wheelspin owns the frame
        --   HK.driftSpinReleaseAt — GetGameTimer() stamp of the frame that spin ENDED (hook)
        -- We FIRE Path B on that release stamp: the spin hooking up IS the forward yank that
        -- shoots the nose. Only drift.lua stamps releaseAt after a genuinely ARMED spin (engine
        -- high AND wheels over-speeding), so it already gates out a mere stab — no load-ms here.
        -- ============================================================================
        local steerAbs   = math.abs(state.steer or 0.0)
        local straight   = steerAbs < (cfg.SeqSteerMaxAbs or 0.35)
        local seqGearOk  = (g >= (cfg.SeqMinGear or 1)) and (g <= (cfg.SeqMaxGear or 4))
        local seqSpeedOk = (state.speedKmh or 0.0) >= (cfg.SeqMinKmh or 8.0)
                           and (state.speedKmh or 0.0) <= (cfg.SeqMaxKmh or 160.0)
        local onGasNow   = (state.effThrottle or state.throttle or 0.0) >= (cfg.MinThrottle or 0.85)
        local launchLive = (state.gameTimer or 0) < wheelieLaunchUntil   -- Path A owns the launch window
        -- SPIN-RELEASE EDGE: the drift W+S wheelspin just ended (releaseAt stamped within the
        -- last SeqReleaseGraceMs). Keep wheelieSeqLoadMs as a debug mirror of the spin state.
        wheelieSeqLoadMs = HK.driftSpinActive and (wheelieSeqLoadMs + (dt * 1000.0)) or 0.0
        local relAt        = HK.driftSpinReleaseAt or 0
        local relFresh     = relAt > 0 and (now - relAt) <= (cfg.SeqReleaseGraceMs or 120)
        local spinReleaseEdge = relFresh and relAt ~= wheelieLastSpinRelAt
        if spinReleaseEdge
           and (HK.driftMode == true) and straight and seqGearOk and seqSpeedOk and onGasNow
           and not launchLive then
            wheelieNormalUntil = now + (cfg.SeqWindowMs or cfg.LaunchWindowMs or 1200)
            if wheelieArmSource == nil then wheelieArmSource = 'normal' end
            wheelieLastSpinRelAt = relAt   -- consume this stamp so we fire once per spin
        end
    end
    wheeliePrevBrakeHeld = brakeHeldNow

    wheeliePrevGear = g
    local launchTrig = ((state.gameTimer or 0) < wheelieLaunchUntil) or (now < wheelieNormalUntil)
    if (state.gameTimer or 0) >= wheelieLaunchUntil and now >= wheelieNormalUntil then wheelieArmSource = nil end

    -- FAKE GEAR 1 — REMOVED (2026-08-14 v6, user: "this will not be a paint over speedo and so much bug
    -- rn"). The fake-paint-1-over-neutral experiment is gone entirely. Launch Control now engages a REAL
    -- gear 1 the moment it STAGES (red pill) — see launchStageTick / the per-mode callers in gearbox.lua —
    -- so the speedo shows a genuine gear with no display override, and exiting LC without launching stays
    -- in gear 1 (never snaps back to N). HK.wheelieFakeSpin is pinned false so any stale reader is inert.
    HK.wheelieFakeSpin = false

    -- ENGAGE DELAY (user 2026-08-14): DON'T lift the instant the launch fires — at a dead standstill
    -- the rear tyres haven't hooked/spun up yet, so an immediate lift just flips the car before it
    -- moves. Wait until it's picked up a bit of speed (EngageAboveKmh) so the rears are spinning and
    -- the wheelie lifts DURING the pull, the muscle way. The launch window still bounds it.
    local movingEnough = state.speedKmh >= (cfg.EngageAboveKmh or 12.0)

    local onGas   = (state.effThrottle or state.throttle) >= cfg.MinThrottle
    local grounded = (not cfg.RequireGrounded) or state.onAllWheels or pitch > 2.0
    -- Path B (in-gear gesture) may fire at higher speed than the launch cap allows (gear 3-4 at
    -- 140+ km/h), so when THIS window was armed by Path B use the Seq speed ceiling instead.
    local speedCeil = (wheelieArmSource == 'normal') and (cfg.SeqMaxKmh or 160.0) or cfg.MaxSpeedKmh
    local inEnvelope = launchTrig
        and onGas
        and state.speedKmh >= cfg.MinSpeedKmh
        and state.speedKmh <= speedCeil
        and grounded
        and pitch < cfg.MaxPitch

    -- BOUNCE STATE MACHINE. idle -> (engage) rising -> (apex) falling -> (landed) rising again if
    -- another bounce is allowed, else back to idle. "Bounce" = the nose punches up then gravity
    -- pulls it back; a harder-pulling launch springs it up more times (1..MaxBounces, thrust-scaled + ±1).
    if not wheelieEngaged then
        -- ARM one launch. 2026-08-14: while ScaleByShoot is OFF (verifying the gate in isolation) the
        -- shoot/grip is NOT required to arm — the LC + drift + W + S gate (launchTrig, inside inEnvelope)
        -- + moving is enough. With ScaleByShoot ON, also require the shoot spike (rearThrust >= ThrustArm).
        local thrustArmed = (cfg.ScaleByShoot == false) or (rearThrust >= (cfg.ThrustArm or 0.18))
        if inEnvelope and movingEnough and thrustArmed then
            wheelieEngaged   = true
            wheelieBounceN   = 0
            -- BOUNCE COUNT 1..3, SCALED BY REAR THRUST at engage (2026-08-14 reramp; was accel). The
            -- harder the rears are driving at engage, the more spring-back bounces. Map thrust from the
            -- arm floor (ThrustArm = 1 bounce) up to 1.0 (= MaxBounces) linearly, then jitter ±1 so it's
            -- not perfectly deterministic (a strong launch usually 2-3, a soft one usually 1).
            do
                local aLo   = cfg.ThrustArm or 0.18
                local aHi   = cfg.ThrustForMax or 0.75
                local maxB  = cfg.MaxBounces or 3
                -- With shoot scaling OFF, use a mid bounce count (don't derive from the ~0 shoot).
                local frac  = (cfg.ScaleByShoot == false) and 0.5
                              or ((aHi > aLo) and ((rearThrust - aLo) / (aHi - aLo)) or 0.0)
                if frac < 0.0 then frac = 0.0 elseif frac > 1.0 then frac = 1.0 end
                -- base 1..maxB from accel, then ± a single-step jitter so neighbours can swap
                local base  = 1 + math.floor(frac * (maxB - 1) + 0.5)
                local jit   = math.random(-1, 1)      -- -1 / 0 / +1
                local n     = base + jit
                if n < 1 then n = 1 elseif n > maxB then n = maxB end
                wheelieBounceMax = n
            end
            wheelieBouncePhase = 'rising'
            wheelieBounceN   = 1
            wheelieBounceMag = 1.0                     -- first bounce = full height
            wheelieOnset     = 0.0                     -- restart the force-onset ramp for this launch
            wheelieModFrac   = wheelieModLevel(veh)    -- sample how modded the car is ONCE, at launch
            -- PER-LAUNCH RANDOM FORCE (2026-08-14, user ask): roll a lower/stronger multiplier ONCE per
            -- launch, ±PitchRateRandomPct (default 12%) around 1.0, so no two launches lift identically.
            local rpct = cfg.PitchRateRandomPct or 0.12
            wheelieForceRand = 1.0 + (math.random() * 2.0 - 1.0) * rpct
        end
    elseif not inEnvelope then
        -- Left the launch envelope (off gas / window closed / airborne / capped) -> end the sequence.
        wheelieEngaged = false
        wheelieBouncePhase = 'idle'
    end

    -- Drive the phase from the pitch. RISING: torque up until we cross the apex (pitch stops climbing
    -- or hits TargetPitch), then FALLING (no torque, gravity brings it down). On landing (pitch back
    -- near flat) either start the next weaker bounce or finish.
    if wheelieBouncePhase == 'rising' then
        -- Apex = reached TargetPitch, OR the nose has genuinely lifted (past BoostMinPitch) and then
        -- started dropping. The BoostMinPitch guard stops standstill suspension jitter from tripping a
        -- false "dropping" apex in the first frames before the nose has actually come up.
        local liftedEnough = pitch > (cfg.BoostMinPitch or 3.0)
        local apex = (pitch >= (cfg.TargetPitch or 18.0))
                     or (liftedEnough and pitch < (wheeliePrevPitch - 0.05))
        if apex then wheelieBouncePhase = 'falling' end
    elseif wheelieBouncePhase == 'falling' then
        if pitch <= (cfg.BounceLandPitch or 2.0) then
            if wheelieBounceN < wheelieBounceMax and inEnvelope then
                wheelieBounceN   = wheelieBounceN + 1
                wheelieBounceMag = wheelieBounceMag * (cfg.BounceDecay or 0.6)   -- spring-back = weaker
                wheelieBouncePhase = 'rising'
            else
                wheelieEngaged = false
                wheelieBouncePhase = 'idle'
            end
        end
    end
    wheeliePrevPitch = pitch

    -- FORWARD SPEED BOOST (user: "speed SHOULD gain WHILE the nose is up, FASTER than flat"). In a real
    -- drag wheelie the front wheels leave the ground so they stop scrubbing and weight loads the driven
    -- rears = MORE forward drive, not less. The old bug: the pitch-torque tilts the nose up, which tilts
    -- engine thrust partly skyward, so speed stalled. Fix = add a ground-plane forward velocity increment
    -- while the nose is up (the codebase's blessed mass-independent pattern from drift PowerAssist — z
    -- dropped so a pitched nose never injects UP velocity). Scaled by how high the nose is (more lift =
    -- more weight transfer = more push) and gated to on-gas + under a speed cap so it's a launch effect.
    -- MOD-SCALED DRAG PULL: the forward yank rides the same wheelieModFrac as the lift. Stock =
    -- ModBoostMin (a gentle nudge so the nose-up still adds a little), full-mod = ModBoostMax (the
    -- insane old-school drag "pulls away" surge). This is what makes a built car FEEL built off the line.
    if wheelieEngaged and onGas and pitch > (cfg.BoostMinPitch or 3.0)
       and (state.speedKmh or 0.0) <= (cfg.BoostMaxKmh or 140.0) and dt > 0.0 then
        local liftFrac = vl_smoothstep(cfg.BoostMinPitch or 3.0, cfg.TargetPitch or 18.0, pitch)
        local modBoostMin = cfg.ModBoostMin or 0.5
        local modBoostMax = cfg.ModBoostMax or 2.0
        local modBoost = modBoostMin + (modBoostMax - modBoostMin) * wheelieModFrac
        -- FRONT-OFF SURGE (2026-08-14 user: "acceleration didn't differ from the front wheel touching
        -- ground or not"). The pitch-scaled boost above is the same whether the wheels are actually up
        -- or the nose is just tilted. Add a clear STEP when the real front wheels are off the ground:
        -- multiply the forward surge by FrontOffBoost so there's a felt "pulls away harder once the
        -- fronts lift" — the drag-launch payoff. Falls to 1.0 (pitch-only boost) the instant they touch.
        local frontOffMul = (HK.wheelieFrontOff == true) and (cfg.FrontOffBoost or 1.6) or 1.0
        local accelMs2 = (cfg.BoostAccelMs2 or 6.0) * liftFrac * wheelieBounceMag * modBoost * frontOffMul
        local give = accelMs2 * dt                     -- m/s this frame (mass-independent)
        if give > 0.0 then
            local fv = GetEntityForwardVector(veh)
            local hmag = math.sqrt(fv.x*fv.x + fv.y*fv.y)
            if hmag >= 0.001 then
                local hx, hy = fv.x / hmag, fv.y / hmag
                local vel = GetEntityVelocity(veh)
                SetEntityVelocity(veh, vel.x + hx * give, vel.y + hy * give, vel.z)  -- z untouched
            end
        end
    end

    -- Not bouncing right now -> smooth the factor down and bail (still publish dbg so /handlingdbg
    -- shows WHY: waiting for launch, too slow to engage, or between/after bounces).
    if wheelieBouncePhase ~= 'rising' then
        wheelieFactor = wheelieFactor + (0.0 - wheelieFactor) * (1.0 - math.exp(-dt / (cfg.ReleaseTau or 0.06)))
        -- Nose may still be up during 'falling' (wheelieEngaged true) — keep the flag honest so the
        -- gearbox keeps upshifting until the sequence fully ends; false once we've landed/disengaged.
        HK.wheelieActive = (wheelieEngaged == true) and (wheelieBouncePhase == 'falling')
        HK.wheelieLiftF  = wheelieFactor
        -- FRONT-WHEELS-OFF physics still runs here: during 'falling' the front can STILL be off the
        -- ground, so the gear-hold / rpm-pin / speed-cap must persist on the ACTUAL wheel state (not the
        -- bounce phase). It self-releases + stamps the landing-settle deadline the moment the wheels touch.
        wheelieFrontOffPhysics(veh, state, cfg, isManual)
        if wheelieBouncePhase == 'idle' and not (HK.wheelieFrontOff == true) then wheeliePeakRpm = 0.0 end
        if HK and HK.hdbgOn then
            local why = 'wait-LC'
            if launchTrig then
                why = (not movingEnough) and 'wait-spd'
                    or (wheelieBouncePhase == 'falling') and 'falling'
                    or (wheelieEngaged and 'landed' or 'no-lift')
            end
            HK.dbgWheelie = { f = wheelieFactor, pitch = pitch, mag = 0.0,
                              trig = launchTrig, man = isManual, accel = wheelieAccel,
                              thrust = rearThrust, spin = worstSpin, shoot = shoot,
                              energy = spinEnergyNorm, hook = hookFrac, wsp = wheelspinNow,
                              gate = why, bN = wheelieBounceN, bMax = wheelieBounceMax,
                              src = wheelieArmSource or '-', loadMs = wheelieSeqLoadMs,
                              brk = brakeHeldNow,
                              spinAct = HK.driftSpinActive == true,
                              spinRelMs = (HK.driftSpinReleaseAt and HK.driftSpinReleaseAt > 0)
                                          and (now - HK.driftSpinReleaseAt) or nil }
        end
        return
    end

    -- RISING: ramp the lift factor UP fast (AttackTau) toward this bounce's peak scale.
    wheelieFactor = wheelieFactor + (wheelieBounceMag - wheelieFactor) * (1.0 - math.exp(-dt / (cfg.AttackTau or 0.18)))

    -- SMOOTH CURVED FADE-OUT (2026-08-26): the torque used to fade only between TargetPitch*0.6 and
    -- MaxPitch, so at the apex (TargetPitch) it was still ~74% and then HARD-CUT to 0 when the phase
    -- flipped rising->falling = an abrupt snap the user felt. Now it eases to ZERO by TargetPitch on a
    -- smoothstep curve (FadeStartPitchFrac..1.0 of TargetPitch), so the torque is already ~0 at the
    -- phase switch = a genuinely smooth trailing edge. Paired with the onset ramp (fade-IN), the force
    -- now swells in and eases out on curves at both ends; accelScale below ties the whole magnitude to
    -- how hard the car is actually accelerating ("goes accordingly to the speed of accelerated").
    local pitchFade = 1.0
    if pitch > 0.0 then
        local fadeStart = (cfg.TargetPitch or 18.0) * (cfg.FadeStartPitchFrac or 0.35)
        pitchFade = 1.0 - vl_smoothstep(fadeStart, cfg.TargetPitch or 18.0, pitch)
    end

    -- SHOOT-SCALED STRENGTH 0..1. When ScaleByShoot is ON the nose lift rides REAR THRUST (torque ×
    -- shoot, the hook yank computed at the top of the tick). 2026-08-14: while we VERIFY THE GATE in
    -- isolation, ScaleByShoot = false pins this to 1.0 so the lift is a clean, constant-strength pop the
    -- moment the gate (LC + drift + W + S) fires — no grip math muddying whether the engagement is right.
    -- Flip ScaleByShoot back on once the gate is confirmed to re-couple the lift to the physical shoot.
    local thrustScale = 1.0
    if cfg.ScaleByShoot ~= false then
        thrustScale = vl_smoothstep(cfg.ThrustArm or 0.18, cfg.ThrustForMax or 0.75, rearThrust)
    end

    -- FORCE-ONSET RAMP (2026-08-26): ease the torque IN over OnsetMs on a gamma curve instead of
    -- slamming full torque on frame 1. A torque spike far too strong for the frame's grip/speed made
    -- the body over-rotate unpredictably (sometimes the tail came up instead of the nose) — a smooth
    -- onset keeps the rear planted so the nose rises predictably. Ramps 0->1 while rising, so each
    -- bounce's punch builds rather than jolts.
    wheelieOnset = wheelieOnset + (dt * 1000.0) / (cfg.OnsetMs or 220.0)
    if wheelieOnset > 1.0 then wheelieOnset = 1.0 end
    local onsetShaped = wheelieOnset ^ (cfg.OnsetGamma or 1.6)

    -- MOD-SCALED LIFT (2026-08-26): a stock car barely lifts, a fully-modded car lifts hard — the
    -- old-school drag look. wheelieModFrac (0..1, sampled at launch) lerps between ModLiftMin and
    -- ModLiftMax. Stock still gets ModLiftMin so it lifts a little; full-mod reaches ModLiftMax.
    local modLiftMin = cfg.ModLiftMin or 0.45
    local modLiftMax = cfg.ModLiftMax or 1.15
    local modLift = modLiftMin + (modLiftMax - modLiftMin) * wheelieModFrac

    -- 2026-08-14 v4: the effect is now an ANGULAR RATE (rad/s nose-up), not an N·m force — see
    -- addPitchRate. PitchRateMax is the peak nose-up rate a full-authority bounce reaches; all the
    -- existing 0..1 shapers (bounce factor, pitch fade, accel scale, torque scale, onset curve, mod
    -- lift) ride on top exactly as before, so the FEEL knobs are unchanged — only the primitive that
    -- actually rotates the car changed. LaunchForceCapPct still trims the peak for headroom.
    -- ×PitchRateGain (2026-08-14 user: "make applied force x2.5") lifts the peak; wheelieForceRand is
    -- this launch's ±12% lower/stronger roll (sampled at arm) so each launch varies a touch.
    local peakRate = (cfg.PitchRateMax or 1.4) * (cfg.PitchRateGain or 2.5) * (cfg.LaunchForceCapPct or 0.56)
    -- PATH-B GEAR SCALE (2026-08-14 v3): the snap-release wheelie works in every gear, but a real car
    -- lofts LESS the taller the gear (less torque multiplication + less load — the log showed rpm loads
    -- lower in gears 3-4). So when Path B armed this window, scale the lift by gear: gear 1 = full, each
    -- gear up multiplies by SeqGearFalloff (<1). Path A (launch) is UNAFFECTED (scale stays 1.0).
    local seqGearScale = 1.0
    if wheelieArmSource == 'normal' then
        local gg = state.gear or 1
        if gg < 1 then gg = 1 end
        seqGearScale = (cfg.SeqGearFalloff or 0.7) ^ (gg - 1)
        local floorS = cfg.SeqGearScaleFloor or 0.25
        if seqGearScale < floorS then seqGearScale = floorS end
    end
    local rate = peakRate * wheelieFactor * pitchFade * thrustScale * onsetShaped * modLift * wheelieForceRand * seqGearScale
    local mag = rate   -- keep the dbg field name (shown as the effective lift on /handlingdbg)
    if rate > 0.0 then
        -- ROLL-LEVEL the lift: bleed the body-roll IN PROPORTION to how hard we're lifting (wheelieFactor),
        -- so the ×2.5 punch brings both front wheels up together instead of one-then-the-other. At full lift
        -- roll is scaled to RollLevelMin; between bounces it eases back to 1.0 (natural roll = the fun
        -- countersteer feel returns). 1.0 disables levelling entirely (pure character).
        local rollLevelMin = cfg.RollLevelMin or 0.35
        local rollDamp = 1.0 - (1.0 - rollLevelMin) * math.min(wheelieFactor, 1.0)
        -- YAW-LEVEL the lift too (2026-08-14): the boosted launch speed/torque let rear wheelspin walk
        -- the car left/right ("going left and right a bit too much"). Bleed a slice of yaw the same way
        -- we bleed roll — scaled by how hard we're lifting — so it tracks straighter. YawLevelMin=1.0
        -- disables it (all steer authority kept); lower = straighter launch. Milder than roll by default
        -- so the driver's own steer-in still reads through.
        local yawLevelMin = cfg.YawLevelMin or 0.6
        local yawDamp = 1.0 - (1.0 - yawLevelMin) * math.min(wheelieFactor, 1.0)
        addPitchRate(veh, rate, rollDamp, yawDamp)   -- proven SetEntityAngularVelocity primitive: nose up, zero translation
    end

    -- ============================================================================================
    -- FRONT-WHEELS-OFF PHYSICS (2026-08-14, user). Everything here gates on the ACTUAL front wheels
    -- being off the ground (frontWheelsOff — measured, NOT nose pitch). While the front is up:
    --   • HOLD THE GEAR + block auto-upshift (AUTO cars only — a manual driver owns their own shifts).
    --   • PIN RPM to max ("MAX RPM WHEN LIFTED UP") — the needle can't bog with only the rears driving.
    --   • KEEP ACCELERATING at that pinned redline: raise the speed cap + add a torque/rpm boost, because
    --     on two contact patches GTA delivers less drive so the car would otherwise stall at redline.
    -- The auto-upshift is deferred until ~UpshiftLandMs AFTER the front wheels touch back down (the old
    -- "upshift during the wheelie" was wrong — a real car can't shift its weight-loaded launch gear while
    -- the nose is up). We stamp the landing deadline on the air->ground edge.
    -- ============================================================================================
    wheelieFrontOffPhysics(veh, state, cfg, isManual)

    -- Publish "a wheelie is lifting the nose right now" so the gearbox auto-upshift can tell a WHEELIE
    -- (front wheels up, rear planted → onAllWheels false but NOT airborne) apart from a real jump and
    -- keep upshifting through it. True across rising AND falling (nose still up); cleared on disengage.
    -- wheelieLiftF is the live 0..1 lift factor (unconditional, NOT dbg-gated) so main.lua's drive
    -- compensation fades with the actual nose height even when /handlingdbg is closed.
    HK.wheelieActive = (wheelieEngaged == true)
    HK.wheelieLiftF  = wheelieFactor

    if HK and HK.hdbgOn then
        HK.dbgWheelie = { f = wheelieFactor, pitch = pitch, mag = mag,
                          trig = launchTrig, man = isManual, accel = wheelieAccel,
                          thrust = rearThrust, spin = worstSpin, shoot = shoot,
                          energy = spinEnergyNorm, hook = hookFrac,
                          tScale = thrustScale, tq = tqApplied,
                          onset = onsetShaped, mod = wheelieModFrac, modLift = modLift,
                          spinRpm = HK.wheelieSpinRpm or 0.0, hold = HK.wheelieHoldGear or false,
                          gate = 'rising', bN = wheelieBounceN, bMax = wheelieBounceMax,
                          src = wheelieArmSource or '-', loadMs = wheelieSeqLoadMs,
                          gScale = seqGearScale,
                          spinAct = HK.driftSpinActive == true,
                          spinRelMs = (HK.driftSpinReleaseAt and HK.driftSpinReleaseAt > 0)
                                      and (now - HK.driftSpinReleaseAt) or nil }
    end
end

-----------------------------------------------------------------
-- [F2] DRAG LAUNCH HEADLIFT (automatic)
-----------------------------------------------------------------

local headliftFactor = 0.0
local prevFwdSpeed = 0.0
local headliftStart = 0
local headliftActive = false

function Headlift_Tick(veh, state, dt)
    local cfg = Config.Headlift

    -- Skip AWD/FWD-ish cars (they don't squat-and-lift the same way)
    local frontBias = vl_getHandling(veh, 'fDriveBiasFront')
    if frontBias >= cfg.SkipIfFrontBiasAbove then
        headliftFactor = 0.0
        prevFwdSpeed = state.forwardSpeed
        return
    end

    -- Compute longitudinal acceleration (m/s^2) from forward speed delta
    local accel = 0.0
    if dt > 0.0 then
        accel = (state.forwardSpeed - prevFwdSpeed) / dt
    end
    prevFwdSpeed = state.forwardSpeed

    local pitch = state.pitch

    -- Trigger. 2026-09-06: two modes.
    --  RequireLaunchControl=true (default) → eligibility is a LIVE LC LAUNCH ONLY (HK.launching).
    --    No accel/throttle heuristic → the old "auto-fired on any hard RWD stab" bug is gone.
    --  RequireLaunchControl=false → legacy standalone trigger (low speed + pinned throttle +
    --    hard accel), kept for reference/rollback.
    local launching = HK.launching == true
    local eligible
    if cfg.RequireLaunchControl then
        eligible = launching
            and (state.onAllWheels or pitch < 2.0)
            and (pitch < cfg.MaxPitch)
    else
        eligible = (state.speedKmh <= cfg.MaxSpeedKmh)
            and ((state.effThrottle or state.throttle) >= cfg.MinThrottle)
            and (accel >= cfg.MinAccelMs2 or launching)
            and (state.onAllWheels or pitch < 2.0)
            and (pitch < cfg.MaxPitch)
    end

    -- Duration cap per launch
    if eligible and not headliftActive then
        headliftActive = true
        headliftStart = state.gameTimer
    end
    if headliftActive and (state.gameTimer - headliftStart) > cfg.MaxDurationMs then
        eligible = false
    end
    if not eligible then
        headliftActive = false
    end

    -- Smooth ramp
    local target = eligible and 1.0 or 0.0
    local tau = eligible and cfg.AttackTau or cfg.ReleaseTau
    headliftFactor = headliftFactor + (target - headliftFactor) * (1.0 - math.exp(-dt / tau))

    if headliftFactor < 0.01 then return end

    -- Fade out near the (low) pitch cap
    local pitchFade = 1.0
    if pitch > 0.0 then
        pitchFade = 1.0 - vl_smoothstep(cfg.MaxPitch * 0.5, cfg.MaxPitch, pitch)
    end

    -- Stronger lift early in a Launch Control launch
    local launchScale = launching and (1.0 + (HK.launchT or 0.0) * 0.4) or 1.0

    local mag = cfg.LiftForceN * headliftFactor * pitchFade * launchScale
    if mag > 0.0 then
        -- Same safe pitch couple as the wheelie (net-zero linear force), just gentler
        -- and pitch-capped low (MaxPitch ~12°) — a subtle drag-launch nose unload.
        applyPitchCouple(veh, mag, cfg.LiftOffsetY)
    end

    if HK and HK.hdbgOn then
        HK.dbgHeadlift = { f = headliftFactor, pitch = pitch, mag = mag, launch = launching }
    end
end

-----------------------------------------------------------------
-- RESET (vehicle swap) — clear the smoothed factors so a new car starts from zero
-- (no carried-over lift ramp) and drop the debug readouts. Called from main.lua.
-----------------------------------------------------------------
function Wheelie_Reset()
    wheelieFactor = 0.0
    wheeliePrevGear = nil
    wheelieLaunchUntil = 0
    wheelieNormalUntil = 0
    wheelieSeqLoadMs = 0.0
    wheeliePrevBrakeHeld = false
    wheelieLastSpinRelAt = 0
    wheelieArmSource = nil
    wheeliePrevFwd = 0.0
    wheelieAccel = 0.0
    wheeliePrevPitch = 0.0
    wheelieBouncePhase = 'idle'
    wheelieBounceN = 0
    wheelieBounceMax = 1
    wheelieEngaged = false
    wheelieBounceMag = 1.0
    headliftFactor = 0.0
    prevFwdSpeed = 0.0
    headliftActive = false
    wheeliePeakRpm = 0.0
    wheelieSpinEnergy = 0.0
    wheelieWasAir = false
    if HK then
        HK.dbgWheelie, HK.dbgHeadlift = nil, nil
        HK.wheelieActive = false; HK.wheelieLiftF = 0.0
        HK.wheelieSpinRpm = nil; HK.wheelieHoldGear = false
        HK.wheelieFakeSpin = false
        HK.wheelieFrontOff = false; HK.wheelieSpeedCapBoost = nil
        HK.wheelieUpshiftLandUntil = 0
    end
end
