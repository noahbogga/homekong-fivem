-----------------------------------------------------------------
-- hk-handling :: client/downforce.lua
-- [G1] Speed-Dependent Downforce — car gets planted at high speed
-- [G2] DRS / Active Aero — reduce drag on straights, boost on brake
-----------------------------------------------------------------

local vehlib = exports['hk-vehlib']
local function bind(fn) return function(...) return fn(nil, ...) end end
-- Cache export refs once (avoids per-frame wrapper-closure GC churn; see gearbox.lua).
-- NOTE: downforce is now GRAVITY-only (SetVehicleGravityAmount) — no applyForce.
-- These two are for the DRS/active-aero drag scaling below.
local vl_restoreField  = bind(vehlib.restoreField)
local vl_scaleHandling = bind(vehlib.scaleHandling)
local vl_getHandling   = bind(vehlib.getHandling)

-- Per-vehicle cached aero rating (2026-09-07). The car's fDownforceModifier from its
-- handling.meta (a FiveM CHandlingData field, ~42/166 of our cars carry it; Chiron 0.70,
-- gallardo 0.04). Mixed casing in the metas (fDownforceModifier / fDownForceModifier) but
-- GetVehicleHandlingFloat is case-insensitive on the field name, so one read covers both.
-- 0 (or no field) = no aero bonus, baseline plant only. Cached so we don't read every frame.
local dfAero, dfAeroVeh = 0.0, nil
local function aeroRating(veh)
    if dfAeroVeh ~= veh then
        local a = vl_getHandling(veh, 'fDownforceModifier') or 0.0
        if a ~= a or a < 0.0 then a = 0.0 end   -- NaN / bogus guard
        dfAero, dfAeroVeh = a, veh
    end
    return dfAero
end

local function clamp(v, lo, hi)
    if v < lo then return lo elseif v > hi then return hi else return v end
end

-----------------------------------------------------------------
-- [G1] DOWNFORCE — speed-scaled GRAVITY plant. (Rewritten 2026-08-14.)
--
-- The GTA arcade problem: past ~150 km/h cars go light, the nose lifts, and they
-- float/skate over bumps. The FIX is NOT per-frame ApplyForceToEntity — injecting
-- external force every frame at speed floods GTA's physics solver and drops the
-- car into slow-motion (an architecture problem, not a magnitude one). Real GTA
-- downforce is GRAVITY: SetVehicleGravityAmount presses the whole car down the
-- way the engine natively expects, with zero solver load. (Ref: cfx "better
-- downforce fix" — gravity + traction-bias, never external force.)
--
-- Front/rear BALANCE is deliberately NOT downforce's job: heavier gravity just
-- amplifies whatever fTractionBiasFront the car runs. drivetrain.lua is the SOLE
-- writer of that field (AWD/RWD/FWD/drift capture→shift→restore); it also owns
-- the gentle high-speed bias CENTERING (pull toward 0.5) that keeps the extra
-- gravity from amplifying understeer/oversteer. Downforce here = gravity ONLY.
--
-- Scales as v² (real aero) over Min..MaxSpeedKmh, tiered by gearbox type
-- (HK.dbgPublicType) so hypercars plant harder and traffic cars stay mild.
--
-- !!! GRAVITY IS ABSOLUTE, NOT A 1.0-BASED MULTIPLIER !!! (2026-08-14 root cause)
-- SetVehicleGravityAmount takes an ABSOLUTE value: ~9.8 = NORMAL earth gravity
-- (confirmed: trainer gravity presets are {0.0, 5.0, 9.8=Default, 50, ...}).
-- vehlib's "1.0 = normal" comment is WRONG (same as its applyForce comment was).
-- Passing 1.0..1.18 set gravity to ~1/8 normal → the car floated in slow-motion.
-- That was the real bug in ALL THREE downforce versions. FIX: capture the car's
-- own native gravity via GetVehicleGravityAmount at first touch and scale RELATIVE
-- to it (no hardcoded 9.8) — GravityAtMax is now a multiplier ON the native base.
-----------------------------------------------------------------

-- Persisted so we hand gravity back cleanly when we drop below threshold / enter
-- drift / go airborne (avoid stomping a value some other system might own).
local dfGravityHeld = false
-- The vehicle's OWN native gravity (absolute), captured per-vehicle so we restore
-- to the true baseline instead of a guessed constant.
local dfBaseGrav, dfBaseVeh = nil, nil

local function tierMult(cfg)
    local pt = HK and HK.dbgPublicType
    if pt == nil then return cfg.TierDefault or 0.45 end
    local m = cfg.TierMult and cfg.TierMult[pt]
    return m or (cfg.TierDefault or 0.45)
end

-- Capture (once per vehicle) the car's native gravity so all scaling is relative.
local function baseGrav(veh)
    if dfBaseVeh ~= veh then
        local g = GetVehicleGravityAmount(veh)
        -- Guard: if the read is bogus (0/NaN — e.g. we already scaled it), fall back
        -- to GTA's default 9.8 rather than trust a corrupted value.
        if not g or g ~= g or g < 1.0 then g = 9.8 end
        dfBaseGrav, dfBaseVeh = g, veh
    end
    return dfBaseGrav or 9.8
end

-- Give gravity back to the car's NATIVE value and clear the latch + debug.
local function dfReleaseGravity(veh)
    if dfGravityHeld then
        SetVehicleGravityAmount(veh, baseGrav(veh))
        dfGravityHeld = false
    end
    if HK and HK.hdbgOn then HK.dbgDownforce = nil end
end

function Downforce_Tick(veh, state, dt)
    local cfg = Config.Downforce
    local kmh = state.speedKmh or 0.0

    -- Stand down: in drift (drift owns grip) or below the speed threshold (city untouched).
    -- 2026-09-08 DOWNHILL-BUMP FIX: the old gate released the WHOLE plant the instant ANY wheel
    -- left the ground (`not onAllWheels`) — but that's EXACTLY when the car goes light over a
    -- downhill bump/crest and needs to be sucked back down. Releasing there made the float WORSE.
    -- Gravity can only pull DOWN (never flings — the blow-up was per-frame ApplyForce, not gravity),
    -- so we now KEEP it planted through bumps and only release for a GENUINE full-car jump
    -- (IsEntityInAir = the whole car airborne off a ramp), where scaling gravity mid-flight would
    -- change the arc. A single wheel unloading over a crest is NOT that.
    if (HK and HK.driftMode) or kmh < cfg.MinSpeedKmh or IsEntityInAir(veh) then
        dfReleaseGravity(veh)
        return
    end
    -- BUMP DETECT: a wheel has unloaded (crest/bump) but the car is not a true jump. Firm the
    -- gravity plant briefly so the car is pulled back onto the road instead of skating light.
    local wheelsUp = not (state.onAllWheels or IsVehicleOnAllWheels(veh))

    -- Speed intensity 0..1, then a tunable curve (2026-09-08). v² (Curve=2) buried the
    -- whole plant at the very top and felt like nothing at real cornering speeds; Curve
    -- ~1.3 builds the plant through the mid-high range where you actually corner. t hits
    -- 1.0 by MaxSpeedKmh (200) and stays there above it (clamped) = full plant sustained.
    local t    = clamp((kmh - cfg.MinSpeedKmh) / (cfg.MaxSpeedKmh - cfg.MinSpeedKmh), 0.0, 1.0)
    local t2   = t ^ (cfg.Curve or 1.3)
    local tier = tierMult(cfg)

    -- Gravity plant: native × (1.0 → GravityAtMax), tier-scaled. GravityAtMax is a
    -- MULTIPLIER on the car's real gravity (1.18 = 18% heavier at full speed).
    local base = baseGrav(veh)
    local mult = 1.0 + (cfg.GravityAtMax - 1.0) * t2 * tier

    -- BUMP BOOST (2026-09-08): when a wheel has unloaded over a downhill bump/crest at speed,
    -- add extra gravity so the car is SUCKED back onto the road instead of floating light and
    -- skittering. Scales with speed (t2) so it's a high-speed anti-float effect, not a low-speed
    -- drag. BumpBoost=0.30 => up to +30% extra gravity on top of the plant while a wheel is up.
    if wheelsUp then
        mult = mult + (cfg.BumpBoost or 0.30) * t2
    end

    -- TOP-SPEED RELEASE (2026-08-14, user request). The extra gravity adds rolling/load drag,
    -- so a car's terminal speed lands ~5-10 km/h UNDER its native mfv (vs a pure-fx server with
    -- no downforce system). We don't want a random cap — instead FADE the extra gravity delta back
    -- toward 1.0 as the car approaches ITS OWN top speed (HK.gbTopKmh, per-car from
    -- GetVehicleEstimatedMaxSpeed). So the plant stays full through the mid-high range (where float
    -- actually shows), then eases off in the last TopReleaseFrac of the car's speed band — by the
    -- time it's at terminal speed the multiplier is ~1.0 and top speed matches native mfv again.
    -- Only trims the DELTA above 1.0 (never pulls gravity below native), and only when we know the
    -- car's top speed; unknown -> no release (full plant, old behaviour).
    if cfg.TopSpeedRelease ~= false and HK and HK.gbTopKmh and HK.gbTopKmh > 0 then
        local relFrac = cfg.TopReleaseFrac or 0.15          -- last 15% of the speed band releases
        local relStart = HK.gbTopKmh * (1.0 - relFrac)
        if kmh > relStart then
            -- 0 at relStart -> 1 at (and past) gbTopKmh; ease the delta out linearly.
            local r = (kmh - relStart) / (HK.gbTopKmh - relStart)
            if r > 1.0 then r = 1.0 elseif r < 0.0 then r = 0.0 end
            mult = 1.0 + (mult - 1.0) * (1.0 - r)
        end
    end

    local grav = base * mult
    SetVehicleGravityAmount(veh, grav)
    dfGravityHeld = true

    -- ── GRIP PLANT (2026-09-07 — the primary downforce) ──────────────────────
    -- Real mechanical grip that scales with speed, claimed through the grip arbiter
    -- at the lowest priority so any active maneuver (drift/burnout/LC/launch/tc-off)
    -- instantly overrides it. BASELINE (tier-scaled) + AERO BONUS (per-car, scaled by
    -- fDownforceModifier). Same v² curve as gravity so the plant grows with speed; the
    -- lower onset (MinSpeedKmh 50) is what gives the steadier mid-speed ride.
    local gcfg = cfg.Grip
    local gripMax = 1.0
    if gcfg and gcfg.Enabled ~= false and HK.gripClaim then
        local baseBump = (gcfg.BaseGripAtMax or 1.08) - 1.0
        -- aero fraction 0..1: this car's fDownforceModifier vs the "full aero" reference.
        local aero    = aeroRating(veh)
        local aeroRef = gcfg.AeroRef or 0.70
        local aeroFrac = (aeroRef > 0.0) and (aero / aeroRef) or 0.0
        if aeroFrac > 1.0 then aeroFrac = 1.0 elseif aeroFrac < 0.0 then aeroFrac = 0.0 end
        local aeroBump = ((gcfg.AeroGripAtMax or 1.14) - 1.0) * aeroFrac
        -- total grip mult at THIS speed: (baseline + aero) × v² × tier
        gripMax = 1.0 + (baseBump + aeroBump) * t2 * tier
        -- breakaway grip (fTractionCurveMin) planted LESS so the slide feel is preserved.
        local gripMin = 1.0 + (gripMax - 1.0) * (gcfg.MinBump or 0.5)
        HK.gripClaim('downforce', (HK.GRIP_PRIO and HK.GRIP_PRIO.downforce) or (gcfg.Prio or 10),
                     { max = gripMax, min = gripMin, low = 1.0 })
    end

    if HK and HK.hdbgOn then
        HK.dbgDownforce = { t = t, tier = tier, grav = grav, mult = mult, base = base, kmh = kmh,
                            grip = gripMax, aero = aeroRating(veh), bump = wheelsUp }
    end
end

-- Called from main.lua on vehicle exit/change: restore the car we're leaving to
-- its native gravity (else an abandoned car stays planted/light) and clear the
-- per-vehicle capture so the NEXT car re-reads its own native baseline.
function Downforce_Reset(veh)
    if dfGravityHeld and veh and veh ~= 0 and DoesEntityExist(veh) then
        SetVehicleGravityAmount(veh, dfBaseGrav or 9.8)
    end
    dfGravityHeld = false
    dfBaseGrav, dfBaseVeh = nil, nil
    dfAero, dfAeroVeh = 0.0, nil   -- 2026-09-07: re-read the next car's own aero rating
    -- grip claim is single-frame (arbiter drops it when we stop re-claiming); nothing to release here
    if HK then HK.dbgDownforce = nil end
end

-----------------------------------------------------------------
-- [G2] DRS / ACTIVE AERO
-- 2026-08-14 REBUILD (reconciled to current architecture):
--   * THREE clean states, ONE write per frame: OPEN (low drag, straight+fast+off-brake),
--     AERO-BRAKE (high drag under hard braking at speed), or NEUTRAL (native drag).
--     Each state is a single scaleHandling / restoreField — no double-write like the old
--     brake branch (which restored then re-scaled the same frame).
--   * drsState string latch (was the drsActive bool) tracks WHICH mode is applied, so a
--     transition only writes on the edge. DRS_Reset clears it on veh-swap — the old bool
--     never reset, so after leaving a car mid-DRS the next car saw drsActive=true and
--     never re-applied (stale-flag bug).
--   * STANDDOWN in drift (diff/drift own the car's feel) and when airborne (drag on a
--     freewheeling car is meaningless) — mirrors Downforce_Tick's guards.
--   * fInitialDragCoeff is single-writer here (nothing else scales it); scaleHandling's
--     first-capture-wins keeps it byte-exact on restore.
-----------------------------------------------------------------

-- '' = native drag applied, 'open' = low-drag, 'brake' = aero-brake high-drag.
local drsState = ''

local function drsApply(veh, want, mult)
    if drsState == want then return end          -- already in this state — no write
    if want == '' then
        vl_restoreField(veh, 'fInitialDragCoeff') -- back to native (byte-exact)
    else
        -- restore first if we were in the OTHER scaled state, so scaleHandling always
        -- scales from the true native (restoreField nils the capture; scale re-captures).
        if drsState ~= '' then vl_restoreField(veh, 'fInitialDragCoeff') end
        vl_scaleHandling(veh, 'fInitialDragCoeff', mult)
    end
    drsState = want
end

function DRS_Tick(veh, state, dt)
    local cfg = Config.DRS
    local kmh = state.speedKmh or 0.0

    -- STANDDOWN: drift owns the car's feel; airborne drag is meaningless. Hand drag
    -- back to native and clear the latch (so re-entry writes cleanly).
    if (HK and HK.driftMode) or (state.onAllWheels == false) then
        drsApply(veh, '', 1.0)
        if HK and HK.hdbgOn then HK.dbgDRS = { mode = 'stand', kmh = kmh } end
        return
    end

    local braking    = (state.brake or 0.0) > 0.1
    local steerAngle = math.abs(GetVehicleSteeringAngle(veh))
    local straight   = steerAngle <= cfg.MaxSteerAngle

    if cfg.BrakeBoostEnabled and braking and kmh >= cfg.BrakeBoostMinSpeed then
        -- AERO BRAKING: more drag = shorter stop from high speed.
        drsApply(veh, 'brake', cfg.BrakeBoostMult)
    elseif kmh >= cfg.MinSpeedKmh and straight and not (braking and cfg.NoBraking) then
        -- DRS OPEN: shed drag on a fast straight for more top speed.
        drsApply(veh, 'open', cfg.DragMultActive)
    else
        -- NEUTRAL: native drag.
        drsApply(veh, '', 1.0)
    end

    if HK and HK.hdbgOn then
        HK.dbgDRS = { mode = (drsState == '' and 'off' or drsState), kmh = kmh, steer = steerAngle }
    end
end

-- Called from main.lua on vehicle exit/change: restore native drag on the car we're
-- leaving and clear the latch so the NEXT car starts from a clean native baseline
-- (the old drsActive bool never reset — stale flag suppressed re-apply on the next car).
function DRS_Reset(veh)
    if drsState ~= '' and veh and veh ~= 0 and DoesEntityExist(veh) then
        vl_restoreField(veh, 'fInitialDragCoeff')
    end
    drsState = ''
    if HK then HK.dbgDRS = nil end
end
