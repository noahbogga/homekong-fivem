-----------------------------------------------------------------
-- hk-handling :: client/main.lua
-- Main loop: detects vehicle, reads state, dispatches to systems.
-----------------------------------------------------------------

local vehlib = exports['hk-vehlib']
local function bind(fn) return function(...) return fn(nil, ...) end end

-- Export refs cached ONCE at load (hk-vehlib is a fxmanifest dependency → started
-- first). Each `exports['hk-vehlib'].fn` access allocates a FRESH wrapper closure
-- (CFX runtime scheduler.lua:717), so calling `vehlib:fn()` per frame churns the
-- GC — that's the real per-frame cost here, not the arithmetic. We resolve each
-- wrapper once. The wrapper is `function(self, ...)` and DISCARDS self, forwarding
-- only `...`, so a colon call `vehlib:fn(veh)` passes self=proxy, args=veh. To keep
-- call sites clean we wrap once in `bind`, which tail-calls with a nil self slot
-- (discarded) so `vl_fn(veh)` forwards veh correctly. Tail call = no extra frame.
local vl_getDrivenVehicle = bind(vehlib.getDrivenVehicle)
local vl_getState         = bind(vehlib.getState)
local vl_setTorque        = bind(vehlib.setTorque)
local vl_setRpmRaw        = bind(vehlib.setRpmRaw)   -- (veh,0..1) paint needle; drift spin-rpm pin uses it as LAST writer
local vl_restoreHandling  = bind(vehlib.restoreHandling)
local vl_scaleHandling    = bind(vehlib.scaleHandling)
local vl_restoreField     = bind(vehlib.restoreField)

-- Shared state that all modules can read
HK = HK or {}
HK.vehicle = 0
HK.state = nil
HK.driftMode = false
HK.tcMode = 2           -- 0=Off, 1=Low, 2=High (default from config)
HK.escActive = false    -- ESC currently intervening

-- Smoothing state (shared across modules for torque blending)
HK.torqueMult = 1.0     -- final torque multiplier applied this frame
HK.brakeForceMult = 1.0 -- final fBrakeForce multiplier this frame (brake model + ABS compose here)
HK.tcFactor = 0.0       -- TC intervention factor (0=none, 1=full cut)
HK.escFactor = 0.0      -- ESC intervention factor

-- Driver assist toggles (per-player, persist across cars this session). ABS/TC are ON by
-- default; the player can switch either OFF via /abs /tc or the F1 radial-menu vehicle options.
-- Simple on/off — no multi-stage modes. The speedo's TC/ABS pills show the OFF state.
HK.absOff = false
HK.tcOff  = false

-- Launch / wheelie shared flags
HK.launching = false    -- [A3] launch boost currently active
HK.launchT = 0.0        -- [A3] launch ramp value (1=just launched, 0=done)
HK.wheelieHeld = false  -- [F1] wheelie key currently held

-- PEDAL MODEL MASTER TOGGLE (2026-08-12) — /pedalmodel flips this live. Default OFF so the throttle/
-- brake synthesis + control injection is fully bypassed (native W/S drives the car, effThrottle mirrors
-- raw) until explicitly enabled for testing. Lets us confirm whether gear-stuck / drift regressions are
-- caused by the model by simply toggling it off. Seeded from config so a server can ship it on later.
HK.pedalModelOn = (Config.Drivetrain and Config.Drivetrain.ThrottleModel
                   and Config.Drivetrain.ThrottleModel.EnabledByDefault) == true

-- STEERING MODEL master toggle (/steermodel), DEFAULT OFF for A/B testing (mirrors /pedalmodel).
HK.steerModelOn = (Config.Drivetrain and Config.Drivetrain.SteeringModel
                   and Config.Drivetrain.SteeringModel.EnabledByDefault) == true

-----------------------------------------------------------------
-- GRIP-FIELD ARBITER (2026-08-16) — SINGLE WRITER for the three SHARED driven-grip fields:
--   fTractionCurveMax, fTractionCurveMin, fLowSpeedTractionLossMult.
--
-- WHY: vehlib's scaleHandling/restoreField is LAST-WRITER-WINS on ONE native cache per field. Five
-- features scaled these SAME three fields with INDEPENDENT restores (launch-traction, burnout, TC-off
-- GripDrop, the LC grip bump, and drift). When two overlapped, whoever called restoreField FIRST wiped the
-- cached native out from under a feature still using it — so the survivor's next scaleHandling re-captured
-- an ALREADY-MODIFIED value as "native", and the field either stuck reduced or the effect silently died and
-- never came back. That restore race is the real "launch drag disappears after a while for no reason" bug
-- (NOT a pcall throw — which is why no error ever showed). The arbiter removes the race: features CLAIM a
-- multiplier each frame; ONE committer resolves the highest-priority claim per field and writes it ONCE.
--
-- SCOPE: the WHEELSPIN FAMILY (launch-traction, burnout, TC-off GripDrop, LC bump) PLUS drift as of
-- Phase 2 (2026-08-14). Drift claims the three shared curve fields at prio 100 (top of the ladder) as
-- STATIC entry-ramp targets — its real per-frame grip cliff is a SEPARATE native (setTractionLossMult
-- 0xAFD262ACCA64479A), never on the shared cache. When Config.GripArbiter.DriftClaim=false, drift reverts
-- to its own capture/restore and the arbiter STANDS ASIDE while HK.driftMode is true (Phase 1 behaviour).
--
-- USAGE (per frame, inside a feature tick):
--   HK.gripClaim(owner, priority, {max=mMax, min=mMin, low=mLow})   -- claim this frame (re-claim each tick)
--   HK.gripRelease(owner)                                          -- stop claiming (or just don't re-claim)
-- Then HK.gripCommit(veh) runs ONCE after all ticks. A claim lives for ONE frame (cleared post-commit) so a
-- feature that stops ticking automatically yields — no stale hold. Priority breaks ties (higher wins).
-----------------------------------------------------------------
HK.GRIP_FIELDS = { 'fTractionCurveMax', 'fTractionCurveMin', 'fLowSpeedTractionLossMult' }
-- Priority ladder (higher = owns grip when several claim at once). Mirrors the existing handoff intent:
-- launch pre-empts TC-off; burnout is the strongest wheelspin state.
-- burnout (deliberate fry) > lc (deliberate STAGED launch — should HOOK, bumps grip UP) > launch-traction
-- (sloppy floor-it launch — should SPIN, drops grip) > tcoff (ambient grip drop). LC out-ranks launch so a
-- proper handbrake-staged launch bites instead of spinning when both arm on the same frame.
-- Phase 2 (2026-08-14): DRIFT is now a first-class claimant at the TOP of the ladder. When held it owns
-- grip over the whole wheelspin escalation (excessive wheelspin → burnout → drift → wheelspin-drift all
-- resolve here, drift wins). Drift only claims the three shared curve fields as STATIC entry-ramp targets;
-- its real per-frame grip cliff is a SEPARATE native (setTractionLossMult 0xAFD262ACCA64479A), untouched.
HK.GRIP_PRIO = { drift = 100, burnout = 80, lc = 70, launch = 60, tcoff = 20, downforce = 10 }
HK._gripClaims = {}          -- owner -> { prio, max, min, low } for THIS frame
HK._gripActive = false       -- did the arbiter write the fields last commit? (restore-once latch)

-- Claim the shared grip fields this frame. mults default to 1.0 (no change) if omitted.
function HK.gripClaim(owner, prio, mults)
    HK._gripClaims[owner] = {
        _name = owner,
        prio = prio or 0,
        max  = (mults and mults.max) or 1.0,
        min  = (mults and mults.min) or 1.0,
        low  = (mults and mults.low) or 1.0,
    }
end

function HK.gripRelease(owner)
    HK._gripClaims[owner] = nil
end

-- Resolve + write ONCE. Called after every feature tick. Picks the highest-priority claim (all three
-- fields move together per owner — that's how every current feature uses them), writes native*mult via
-- vehlib, or restores when nobody claims. Stands aside in drift (drift owns the fields).
function HK.gripCommit(veh)
    if not (Config.GripArbiter and Config.GripArbiter.Enabled ~= false) then return end
    if not veh or veh == 0 or not DoesEntityExist(veh) then
        HK._gripClaims = {}; return
    end
    -- DRIFT (Phase 2): drift now CLAIMS through the arbiter like every other feature (prio 100, owns grip
    -- when held). We only stand aside in the LEGACY path — when the drift-claim migration is switched OFF
    -- via Config.GripArbiter.DriftClaim=false, drift.lua reverts to its own capture/restore and we must not
    -- fight it. With DriftClaim on (default) we fall through and commit drift's claim like any other.
    if HK.driftMode == true and not (Config.GripArbiter and Config.GripArbiter.DriftClaim ~= false) then
        HK._gripClaims = {}
        HK._gripActive = false     -- drift's legacy restore path owns cleanup; we assert nothing
        return
    end

    -- pick the winning claim (highest prio; ties -> whichever pairs iterate last, deterministic enough
    -- since real overlaps are prio-distinct).
    local win, winPrio = nil, -1
    for _, c in pairs(HK._gripClaims) do
        if c.prio > winPrio then win, winPrio = c, c.prio end
    end

    if win then
        vl_scaleHandling(veh, 'fTractionCurveMax', win.max)
        vl_scaleHandling(veh, 'fTractionCurveMin', win.min)
        vl_scaleHandling(veh, 'fLowSpeedTractionLossMult', win.low)
        HK._gripActive = true
        if HK.dbgGrip == nil then HK.dbgGrip = {} end
        HK.dbgGrip.owner, HK.dbgGrip.prio = win._name, winPrio
        HK.dbgGrip.max, HK.dbgGrip.min, HK.dbgGrip.low = win.max, win.min, win.low
        HK.dbgGrip.at = GetGameTimer()
    elseif HK._gripActive then
        -- nobody claims this frame -> hand all three fields back to native ONCE.
        vl_restoreField(veh, 'fTractionCurveMax')
        vl_restoreField(veh, 'fTractionCurveMin')
        vl_restoreField(veh, 'fLowSpeedTractionLossMult')
        HK._gripActive = false
        if HK.dbgGrip then HK.dbgGrip.owner, HK.dbgGrip.prio = 'none', 0; HK.dbgGrip.at = GetGameTimer() end
    end

    HK._gripClaims = {}          -- claims are single-frame; features re-claim each tick
end

-- Full reset (vehicle swap / resource stop): drop claims + restore if we were asserting.
function HK.gripArbiterReset(veh)
    HK._gripClaims = {}
    if HK._gripActive and veh and veh ~= 0 and DoesEntityExist(veh) then
        vl_restoreField(veh, 'fTractionCurveMax')
        vl_restoreField(veh, 'fTractionCurveMin')
        vl_restoreField(veh, 'fLowSpeedTractionLossMult')
    end
    HK._gripActive = false
end

-----------------------------------------------------------------
-- HELPERS
-----------------------------------------------------------------
local function smooth(current, target, tau, dt)
    if tau <= 0 or dt <= 0 then return target end
    local alpha = 1.0 - math.exp(-dt / tau)
    return current + (target - current) * alpha
end

local function tprLerpClamp(x, x0, x1, y0, y1)
    if x1 == x0 then return y0 end
    local t = (x - x0) / (x1 - x0)
    if t < 0 then t = 0 elseif t > 1 then t = 1 end
    return y0 + (y1 - y0) * t
end

-----------------------------------------------------------------
-- SHARED RECENTER TAPER (2026-08-13)
-- The "fix the rear then return to center/stabilized" family (drift exit-recovery yaw damp, AWD/RWD
-- spin softeners) all scale the yaw RATE toward zero. Their engage/release is smoothed, but the damp
-- force itself stayed at full strength all the way down to zero yaw — so the last stretch back to
-- straight got yanked flat (reads as an instant snap / over-correction jolt at the settle, worst on a
-- planted AWD like the GTR at the widest angle or a corner-brake grip loss).
--
-- This returns a 0..1 multiplier that FADES the recenter force as the car nears straight, so the
-- return decelerates into center (asymptotic settle) instead of hitting a wall. Design (see the long
-- discussion): YAW RATE owns the near-center settle — it's the same variable the actor writes, so the
-- loop closes cleanly and momentum swinging back THROUGH center still gets damped (kills overshoot).
-- SLIP ANGLE is a soft FLOOR only: while the car is genuinely sideways it holds the taper up so the
-- fade can't back off early, but it can never command more than yaw at real rotation. Both low = both
-- release = smooth settle. Callers MULTIPLY their existing damp coefficient by this.
--   @param yawRate number  rad/s (sign irrelevant; magnitude used)
--   @param slipDeg number   |slip angle| in degrees (0 if unknown → pure yaw taper)
--   @param opts table|nil    optional per-call floor override {floorWeight, floorGate, floorFull}.
--                            Consumers that operate through the LOW/MID slip band (drift exit, which
--                            straightens the car THROUGH 6-18°) need a stronger, earlier-saturating
--                            floor so recenter stays full while sideways and only fades near center —
--                            unlike the spin softeners, which are gated high (22/32°) so the default
--                            floor is always saturated for them. See the AWD drift-exit fix (v7.22).
--   @return number 0..1
-----------------------------------------------------------------
function HK.recenterTaper(yawRate, slipDeg, opts)
    local c = Config.RecenterTaper
    if not c or c.Enabled == false then return 1.0 end   -- disabled → no taper (legacy full-force)
    opts = opts or nil

    local yaw  = math.abs(yawRate or 0.0)
    local slip = math.abs(slipDeg or 0.0)

    -- YAW term: 0 at/below ZeroRate (near straight) → 1 at/above FullRate (real rotation).
    local yawF = tprLerpClamp(yaw, c.YawZeroRate or 0.15, c.YawFullRate or 0.60, 0.0, 1.0)

    -- SLIP soft-floor: 0 below the gate → up to FloorWeight above FullDeg. Holds the taper up while
    -- the car is still pointing sideways so the force can't fade while genuinely mid-slide. Per-call
    -- opts override the config defaults (drift exit passes a stronger/earlier floor — see @param opts).
    local fW = (opts and opts.floorWeight) or c.SlipFloorWeight  or 0.85
    local fG = (opts and opts.floorGate)   or c.SlipFloorGateDeg or 6.0
    local fF = (opts and opts.floorFull)   or c.SlipFloorFullDeg or 18.0
    local slipFloor = fW * tprLerpClamp(slip, fG, fF, 0.0, 1.0)

    -- Yaw owns near-center; slip can only raise the floor, never exceed a genuine-rotation yaw term.
    local taper = yawF
    if slipFloor > taper then taper = slipFloor end
    if taper > 1.0 then taper = 1.0 elseif taper < 0.0 then taper = 0.0 end
    return taper
end

-----------------------------------------------------------------
-- DEVICE-AGNOSTIC EFFECTIVE THROTTLE (2026-08-13)
-- The throttle-graduated features (RWD wheelspin assist, throttle-steer, future modules) assume an
-- ANALOG pedal. But keyboard W (control 71) is BINARY — GetControlNormal only ever returns 0.0 or 1.0,
-- so a keyboard player skips every "moderate gas" band and teleports to full throttle, making all the
-- throttle nuance invisible to them. This synthesizes a single EFFECTIVE throttle (0..1) that behaves
-- the same across keyboard / controller / wheel, plus an rpmFactor so low-rpm full-throttle rotates less.
--
-- OWNERSHIP: this is the ONE stateful integrator that reads raw input over time. vehlib.getState is
-- stateless by design (rebuilds every call), so it can't own the squeeze ramp / low-pass / device timer.
-- main.lua's loop is the single per-frame owner: it runs this ONCE right after the state snapshot and
-- writes state.effThrottle + state.rpmFactor onto it, so every downstream feature just reads the field.
-- When throttle moves into vehlib later, this lifts out as a stateful sub-module unchanged.
--
-- DETECTION: keyboard only ever produces exactly 0 or 1. If we ever see a raw value strictly inside
-- (eps, 1-eps), the device has an analog axis → pass the real pedal through a light low-pass and hold
-- analog mode for AnalogDetectMs (so brief full-press/full-release on a pad doesn't flip us to synth).
-- Otherwise BINARY → synthesize pedal travel from how long W has been held.
-- SHARED PEDAL ENGINE. Throttle and brake (and later steering) all run the same integrator so there's
-- one tested code path. Each pedal owns a small state table P; `pos` is the INTERNAL LINEAR travel
-- (0..1) and gamma is applied on OUTPUT so the curve never distorts the integration. Returns the shaped
-- 0..1 output. rateScale multiplies the up-ramp speed (rpm/speed/reverse shaping — caller computes it).
--   Features shared with the racing sims we modelled on:
--     * ramp (AC "steer/gas speed"), ease-in, gamma (AC pedal "gamma"), tap-to-hold feathering.
local function newPedal()
    return { pos = 0.0, analog = false, lastAnalog = -1e9, lastVeh = 0,
             wasPressed = false, lastTapAt = -1e9, cadence = 0.0, pressStartedAt = -1e9 }
end

-- INPUTS ARE PASSED IN, NOT INFERRED FROM THE CONTROL VALUE. Earlier the engine read GetControlNormal
-- to both (a) detect analog and (b) get the pedal — but we ALSO SetControlNormal our own output onto the
-- same control, so next frame it read its OWN injection back, flagged the device "analog," and low-passed
-- its own echo (the flip-flop / stuck / lag bug). Now the caller supplies:
--   analog  = true if a real analog device (controller) is active — from IsInputDisabled(2), NOT the value
--   pressed = the PHYSICAL key boolean (IsDisabledControlPressed) — immune to our SetControlNormal
--   analogVal = the real 0..1 axis value, ONLY meaningful/clean when analog (we never inject for analog)
local function stepKeyPedal(P, pressed, analogVal, analog, dt, now, pc, rateScale)
    P.analog = analog
    local maxPos = pc.MaxPos or 1.0    -- hard ceiling on travel (reverse caps this so it can't wind to full)

    if P.analog then
        -- ANALOG: light low-pass, native modulation preserved.
        P.pos = smooth(P.pos, analogVal or 0.0, (pc.AnalogLowpassMs or 90.0) / 1000.0, dt)
    elseif pc.SimpleRamp then
        -- SIMPLE RAMP MODE (reverse): NO tap-hold. Pure press-integrate / release-decay with ease-in and
        -- the caller's rateScale. Held key ramps up (stretched slow via UpMs + rateScale); release decays.
        -- This is the "creep backward under control" path — reverse doesn't want feathering, just a long ramp.
        if pressed then
            local up   = (pc.UpMs or 900.0) / 1000.0
            local rf   = pc.RiseFloorMult or 0.18
            local ease = rf + (1.0 - rf) * (P.pos / (maxPos > 0 and maxPos or 1.0))
            P.pos = P.pos + (dt / up) * ease * (rateScale or 1.0)
        else
            P.pos = P.pos - dt / ((pc.DownMs or 300.0) / 1000.0)
        end
        if P.pos > maxPos then P.pos = maxPos elseif P.pos < 0.0 then P.pos = 0.0 end
    else
        -- TAP CADENCE → TARGET (v3, "steady cadence"). v2 decayed cadence CONTINUOUSLY, so the target
        -- itself sagged between taps and the pedal chased a collapsing signal (that's why the hold died).
        -- Now cadence is HELD steady between taps and only fades once you've stopped tapping for
        -- TapMemoryMs — so the target is rock-stable and the pedal LOCKS onto it. Rising edge measures the
        -- tap gap → cadence (0..1); a real key-hold past HoldDetectMs is the separate "floor it" path.
        if pressed and not P.wasPressed then
            P.pressStartedAt = now
            local gap = now - (P.lastTapAt or -1e9)
            P.lastTapAt = now
            local c = tprLerpClamp(gap, pc.TapFastGapMs or 110.0, pc.TapSlowGapMs or 420.0, 1.0, 0.0)
            P.cadence = c                  -- set directly: each tap re-measures the current rhythm
        end
        P.wasPressed = pressed

        local holding  = pressed and (now - (P.pressStartedAt or now)) >= (pc.HoldDetectMs or 175.0)
        local sinceTap = now - (P.lastTapAt or -1e9)

        if holding then
            -- GENUINE HOLD (key down past a tap's length) → integrate up to full with ease-in + rate shaping.
            local up   = (pc.UpMs or 380.0) / 1000.0
            local rf   = pc.RiseFloorMult or 0.35
            local ease = rf + (1.0 - rf) * (P.pos / (maxPos > 0 and maxPos or 1.0))
            P.pos = P.pos + (dt / up) * ease * (rateScale or 1.0)
        elseif sinceTap < (pc.TapMemoryMs or 550.0) then
            -- TAP-FEATHER → CONVERGE to the cadence-set target and LOCK (cadence steady = stable target).
            local floorT = pc.TapTargetFloor or 0.15
            local ceilT  = pc.TapTargetCeil  or 0.90
            local target = (floorT + P.cadence * (ceilT - floorT)) * maxPos
            P.pos = smooth(P.pos, target, (pc.TapConvergeMs or 130.0) / 1000.0, dt)
        else
            -- IDLE (tapping stopped past TapMemoryMs, key not held) → fade cadence out and release to 0.
            P.cadence = 0.0
            P.pos = P.pos - dt / ((pc.DownMs or 260.0) / 1000.0)
        end
        if P.pos > maxPos then P.pos = maxPos elseif P.pos < 0.0 then P.pos = 0.0 end
    end

    -- GAMMA on output: >1 gives finer control in the bottom half of the pedal (a light press sits low
    -- instead of racing to mid). Applied to output only — integration stays linear.
    local g = pc.Gamma or 1.0
    if g ~= 1.0 then return P.pos ^ g end
    return P.pos
end

local tmPedal = newPedal()      -- throttle pedal state
HK.tmPedal = tmPedal            -- expose for the gearbox throttle-dropout diagnostic (read-only there)

-- PHYSICAL KEY READ VIA RAW SCAN CODES (2026-08-12) — the "stuck W" fix.
-- We SetControlNormal(71/72) our modeled output EVERY frame. That override pollutes BOTH ways of
-- reading the same control: GetControlNormal (value) AND IsDisabledControlPressed (boolean). So the
-- next frame's read sees OUR injection, not the player's key — reports W "held" forever, self-feeds
-- (pressed→holding→eff high→inject high→pressed…), and only clears when something else resets the
-- control (gear change's DisableControlAction, or alt-tab dropping focus). That's the exact stuck-W
-- symptom. THE RULE: never read a control you also write. Raw scan-code reads (IsRawKeyDown) bypass
-- the control system entirely, so they can NEVER see our injection. W=0x57, S=0x53 (GTA defaults).
-- Limitation: a player who rebinds forward/back off W/S won't be detected on keyboard (rare); the
-- analog (controller/wheel) path is unaffected — it never injects, so its GetControlNormal is clean.
local RAWKEY_W = 87   -- physical 'W' virtual-key code (forward throttle)
local RAWKEY_S = 83   -- physical 'S' virtual-key code (brake / reverse)
local RAWKEY_A = 65   -- physical 'A' virtual-key code (steer left) — same never-read-what-you-write rule
local RAWKEY_D = 68   -- physical 'D' virtual-key code (steer right)
local rawKeysOk = true -- cleared if IsRawKeyDown faults on this build (fall back to control reads)

local function readPhysicalPedals()
    local keyboard = not not IsInputDisabled(2)   -- truthy → true (1==true is false in Lua — the old bug)

    local tPressed, bPressed, tAxis, bAxis
    if keyboard and rawKeysOk then
        local ok1, wDown = pcall(IsRawKeyDown, RAWKEY_W)
        local ok2, sDown = pcall(IsRawKeyDown, RAWKEY_S)
        if ok1 and ok2 then
            tPressed = wDown and true or false     -- PHYSICAL key state — immune to our SetControlNormal
            bPressed = sDown and true or false
            tAxis = tPressed and 1.0 or 0.0        -- keyboard is binary; the model synthesizes the ramp
            bAxis = bPressed and 1.0 or 0.0
        else
            rawKeysOk = false                       -- native unavailable on this build → stop trying
        end
    end
    if tPressed == nil then
        -- ANALOG (controller LT/RT / wheel) — or raw keys unavailable. In analog mode we never inject, so
        -- the ENABLED control value isn't polluted by us. BUT the reverse/neutral rework (and the rev
        -- limiter) DisableControlAction(0, 71/72) on many frames, and GetControlNormal returns 0 for a
        -- DISABLED control — so on a pad, LT/RT read 0 exactly in neutral + reverse. That was the "brake
        -- light doesn't come on in neutral / reverse still needs the brake key to move / W+S features don't
        -- fire on a controller" bug: keyboard dodges it via IsRawKeyDown (bypasses the control system), the
        -- analog path had no immunity. FIX: take the max of the enabled AND disabled normals — the disabled
        -- read survives DisableControlAction, so the true trigger axis reaches HK._pedalThrottle/_pedalBrake
        -- and every downstream consumer (brake lights, reverse drive, burnout, launch) works on a pad.
        tAxis = math.max(GetControlNormal(0, 71) or 0.0, GetDisabledControlNormal(0, 71) or 0.0)
        bAxis = math.max(GetControlNormal(0, 72) or 0.0, GetDisabledControlNormal(0, 72) or 0.0)
        tPressed = tAxis > 0.5
        bPressed = bAxis > 0.5
    end

    -- NEUTRAL-EXIT THROTTLE CUT: the double-tap-W that pulls out of neutral is TWO fast W presses; the
    -- second press is still physically held on the frame the gate opens, so the box would engage a gear and
    -- lurch forward off that same tap. gearbox sets HK._neutralExitThrCut=true at the exit — here we FORCE
    -- throttle to 0 until W is fully RELEASED, so leaving N is inert and the driver must press W again to go.
    if HK._neutralExitThrCut then
        if tPressed then
            tAxis, tPressed = 0.0, false        -- swallow the held double-tap throttle
        else
            HK._neutralExitThrCut = false        -- W released → re-arm; next fresh press drives normally
        end
    end

    HK._pedalInputKeyboard = keyboard
    HK._pedalThrottle = tAxis
    HK._pedalBrake = bAxis
    HK._pedalThrottlePressed = tPressed
    HK._pedalBrakePressed = bPressed
    return keyboard, tAxis, bAxis, tPressed, bPressed
end

function HK.ThrottleModel_Tick(state, dt)
    -- MASTER TOGGLE OFF (/pedalmodel): full bypass. Leave state.throttle/brake as the NATIVE snapshot
    -- (getState's GetControlNormal) so drift/gearbox/drivetrain behave EXACTLY as before this model
    -- existed, mirror effThrottle=raw, and inject nothing (Apply also early-outs). This is the isolation
    -- switch — if a regression disappears with the model off, the model owns it.
    if not HK.pedalModelOn then
        state.effThrottle = state.throttle or 0.0
        state.effBrake    = state.brake or 0.0
        state.rpmFactor   = 1.0
        state.throttleIsAnalog = false
        HK._injThrottle = 0.0
        HK._injAnalog = true      -- makes Apply skip even if it's somehow reached
        return
    end

    local cfg = Config.Drivetrain and Config.Drivetrain.ThrottleModel
    local keyboard, throttleRaw, brakeRaw, throttlePressed, brakePressed = readPhysicalPedals()
    -- Replace the snapshot's controls with the physical values. This prevents every downstream
    -- assist (especially drivetrain gates) from seeing a previous frame's injected output.
    state.throttle = throttleRaw
    state.brake = brakeRaw
    state.rawHardwareThrottle = throttleRaw
    state.rawHardwareBrake = brakeRaw

    if not cfg or cfg.Enabled == false then
        -- Disabled → pass the physical pedal straight through so features still have the fields.
        state.effThrottle = throttleRaw
        state.rpmFactor   = 1.0
        state.throttleIsAnalog = not keyboard
        return
    end

    -- Reset the integrator when the driven vehicle changes (no ramp carried across cars).
    if state.vehicle ~= tmPedal.lastVeh then
        tmPedal.lastVeh = state.vehicle
        tmPedal.pos     = throttleRaw
        tmPedal.wasPressed = throttlePressed
    end

    -- REVERSE is a real GEAR now (HK.inReverseGear), NOT "S held at a stop" (2026-08-14 rework). The
    -- accelerator is ALWAYS W (throttle): in a forward gear W drives forward, in a reverse gear W
    -- produces BACKWARD thrust (ThrottleModel_Apply routes W's modeled value onto GTA's reverse
    -- control). S is ALWAYS the brake — never a reverse-accelerator. `reversing` now just selects the
    -- slower reverse RAMP shape (creeping backward = precision), sourced from the SAME W pedal.
    local reversing = (HK.inReverseGear == true)
    local raw = throttleRaw
    local pressed = throttlePressed
    local analog = not keyboard
    local analogVal = throttleRaw
    local now = state.gameTimer or 0

    -- RATE SCALE — throttle build speed, shaped BOTH ways per the sims:
    --   REVERSE: one flat, even-slower mult (rpm meaningless in reverse — creeping wants precision).
    --   RPM:  slower at low rpm (fragile launch/low-gear feather) → faster at high rpm (committed, snappy).
    --   SPEED: slower at high speed (throttle comes in gently on corner-exit = anti snap-oversteer),
    --          barely affected low. Multiplies onto rpm so rpm dominates but the top softens at speed.
    local rateScale
    if reversing then
        rateScale = cfg.ReverseRampMult or 0.45
    else
        local rpmScale = tprLerpClamp(state.rpm or 0.0,
            cfg.RpmRampLow or 0.30, cfg.RpmRampHigh or 0.70, cfg.RpmRampLowMult or 0.60, cfg.RpmRampHighMult or 1.30)
        local spdScale = tprLerpClamp(state.speedKmh or 0.0,
            cfg.SpeedRampLowKmh or 40.0, cfg.SpeedRampHighKmh or 150.0, cfg.SpeedRampLowMult or 1.0, cfg.SpeedRampHighMult or 0.80)
        rateScale = rpmScale * spdScale
    end

    -- The shared engine reads UpMs/DownMs/etc — map the throttle's config field names onto them.
    local pc = {
        AnalogEpsilon = cfg.AnalogEpsilon, AnalogDetectMs = cfg.AnalogDetectMs, AnalogLowpassMs = cfg.AnalogLowpassMs,
        UpMs = cfg.SqueezeUpMs, DownMs = cfg.SqueezeDownMs, RiseFloorMult = cfg.RiseFloorMult, Gamma = cfg.Gamma,
        HoldDetectMs = cfg.HoldDetectMs, TapFastGapMs = cfg.TapFastGapMs, TapSlowGapMs = cfg.TapSlowGapMs,
        TapTargetFloor = cfg.TapTargetFloor, TapTargetCeil = cfg.TapTargetCeil, TapConvergeMs = cfg.TapConvergeMs,
        TapMemoryMs = cfg.TapMemoryMs,
    }
    if reversing then
        -- REVERSE: NOT a cap problem — it's a RAMP problem. GTA's native reverse winds up too fast and
        -- fishtails. So reverse uses SIMPLE-RAMP mode (no tap-hold — you don't feather reverse) with a
        -- genuinely STRETCHED build: base UpMs is ≥2× the forward sweep, and it's stretched FURTHER at low
        -- speed (creeping off a standstill is the twitchy part). A long hold of S keeps building (extends
        -- speed) but stays much slower than GTA the whole way. No MaxPos — you can reach full, just slowly.
        -- (source is W now, not S — reverse is a real gear; the ramp shape is unchanged.)
        pc.SimpleRamp    = true
        pc.RiseFloorMult = cfg.ReverseRiseFloorMult or 0.18
        -- stretch: at/below ReverseSlowKmh use the LONG ramp, easing to the (still slow) base by ReverseFastKmh
        local revUp = tprLerpClamp(state.speedKmh or 0.0,
            cfg.ReverseSlowKmh or 3.0, cfg.ReverseFastKmh or 25.0,
            cfg.ReverseUpMsLow or 1500.0, cfg.ReverseUpMs or 900.0)
        pc.UpMs   = revUp
        pc.DownMs = cfg.ReverseDownMs or 300.0
        rateScale = cfg.ReverseRampMult or 0.45
    end
    local tm_eff = stepKeyPedal(tmPedal, pressed, analogVal, analog, dt, now, pc, rateScale)
    local tm_analog = tmPedal.analog

    -- RPM factor: low rpm = little torque = less rotation, so full throttle down low shouldn't command
    -- full aggression. Features that steer with throttle multiply by this to match real power delivery.
    state.rpmFactor = tprLerpClamp(state.rpm or 0.0,
        cfg.RpmFloor or 0.30, cfg.RpmFull or 0.70, cfg.RpmFloorMult or 0.45, 1.0)
    state.effThrottle = tm_eff
    state.throttleIsAnalog = tm_analog
    state.throttleReversing = reversing
    HK.tmCadence = tmPedal.cadence

    -- Stash what to inject; the ACTUAL SetControlNormal happens in HK.ThrottleModel_Apply, called
    -- AFTER the gearbox tick so we never fight its DisableControlAction (see that function).
    HK._injThrottle = tm_eff
    HK._injReversing = reversing
    HK._injAnalog = tm_analog
    HK._injPressed = pressed        -- physical key still held (for the full-throttle stand-aside)
end

-- APPLY the modeled pedal to the vehicle — called AFTER Gearbox_Tick in the main loop so the gearbox's
-- DisableControlAction (reverse-gate / launch / force-upshift) has already run first. This is the ONLY
-- place we SetControlNormal(71/72). SetControlNormal is per-frame, so NOT writing = native control passes.
--
-- FULL-THROTTLE CONTINUOUS PIN (2026-08-14 — the real gear-stuck fix): the old "stand-aside" (below)
-- tried to STOP writing at full and let native W drive, on the theory that our write would defeat the
-- limiter's throttle-kill upshift. That was wrong for DCT-auto (its upshift is RPM-driven via
-- requestGear, not throttle-driven) AND it was unreliable: when modeled eff sat just under INJECT_FULL
-- we wrote a PARTIAL 0.98x every frame; when it crossed above we wrote nothing and leaned on native W.
-- That partial/gap flicker (vs OFF-mode's flat native 1.0) kept knocking rpm out of the razor-thin
-- upshift band on cars whose ratio mode caps upRpm at ~redline (sport/hyper) → "stuck at gear N, eff
-- shows 1.00". The limiter runs AFTER this apply and cuts revs via TORQUE (+ its own DisableControlAction
-- last), so a clean continuous SetControlNormal(71,1.0) can't defeat it. So: when the model is pinned
-- full and the key is physically held, write a rock-steady 1.0 — faithfully reproducing OFF-mode.
-- FULL-THROTTLE STAND-ASIDE (2026-08-12 — the gear-stuck fix): on an auto/DCT the ONLY way it upshifts
-- at full throttle is the rev limiter hitting redline and DisableControlAction(71)'ing to kill throttle
-- so the shift lands. If we re-write SetControlNormal(71, 1.0) every frame we DEFEAT that kill → car
-- sits at redline in the gear forever, everything pinned 1.00 (the reported 4→5 stuck). IsControlEnabled
-- doesn't reliably reflect a same-frame DisableControlAction, so instead: once the modeled pedal has
-- reached (near) full AND the physical key is held, injecting adds NOTHING over native W — so we STAND
-- ASIDE and let native W through. Injection then only acts where it actually shapes the pedal (the
-- ramp-up feather and the release rolloff), and can never fight the limiter's throttle-kill upshift.
local INJECT_FULL = 0.985   -- at/above this modeled level, injecting == native W, so let native pass
function HK.ThrottleModel_Apply()
    if not HK.pedalModelOn then return end        -- master toggle off = never inject (native W/S drives)
    local cfg = Config.Drivetrain and Config.Drivetrain.ThrottleModel
    if not cfg or cfg.Enabled == false or cfg.ApplyInput == false then return end
    if HK._injAnalog or HK.driftMode then return end

    -- LIMITER HANDOFF (2026-08-14 — the REAL gear-stuck fix): the gearbox rev-limiter runs INSIDE
    -- Gearbox_Tick (just before this apply) and DisableControlAction(0,71) to KILL throttle so rpm
    -- drops off the ceiling — and it's that rpm OSCILLATION (drop off limiter → throttle back →
    -- climb) that sweeps up through the DCT-auto upshift point (upRpm ~0.98, just under the 0.985
    -- limiter) and fires the shift. If we re-write SetControlNormal(71,1.0) here we RE-PIN throttle
    -- every frame and DEFEAT that kill → rpm sticks pinned at the limiter, never oscillates up to the
    -- shift point, gear won't upshift (exactly why RELEASING + re-pressing W — which hand-makes the
    -- oscillation — DID shift). So when HK.gbLimiterOn, write NOTHING and let the gearbox's kill win,
    -- identical to OFF-mode. HK.gbLimiterOn is published by applyRevLimiter and reset each frame in
    -- the main loop (so a frame where the gearbox tick doesn't run can't leave it latched).
    if HK.gbLimiterOn then return end

    local eff = HK._injThrottle or 0.0

    -- TURBO THROTTLE LAG (the felt engagement step): Turbo_Tick publishes HK.turboThrottleMult (spool-
    -- gated, floor..1.0). Multiplying the injected pedal by it makes the throttle plate feel CHOKED
    -- off-boost then RUSH in as boost arrives — the pedal-side lag you actually feel. Perf-neutral: it
    -- reaches 1.0 at full spool, so peak throttle/top speed is unchanged; it only delays onset. Skipped
    -- for reverse (turbo lag on reverse creep would feel broken) and on analog (we never inject there).
    local turboT = HK.turboThrottleMult
    if turboT == nil then turboT = 1.0 end
    if turboT < 1.0 and not HK._injReversing then
        eff = eff * turboT
    end

    if HK._injReversing then
        -- REVERSE GEAR (2026-08-14 rework). GTA overloads the pedals by VELOCITY: control 72 (S)
        -- reverse-ACCELERATES when stopped/backward, control 71 (W) BRAKES when moving backward. We
        -- want W=go-backward, S=brake, so we SWAP the injection onto the native controls:
        --   * modeled W pedal (`eff`, slow reverse ramp) -> control 72  = reverse thrust
        --   * physical S -> control 71                                  = reverse brake
        -- fBrakeForce (scaled by the brake model) still sets braking STRENGTH; control 71 is just the
        -- "brake pressed" signal in reverse (mirrors how keyboard S is a binary press forward). Net:
        -- S is NEVER a reverse-accelerator — it only ever brakes.
        -- REVERSE: nothing to inject on the controls. The gearbox DISABLES both 71 and 72 in a reverse
        -- gear (control 72 can't be shared with physical S), and reverse motion is driven DIRECTLY by
        -- velocity in HK.ReverseDrive_Tick (W = accel backward, S = brake). So this branch is a no-op —
        -- writing to a disabled control does nothing. Kept for clarity / the _injReversing debug flag.
    else
        -- FORWARD: when NOT on the limiter, pin a clean continuous 1.0 at full (matches OFF-mode's flat
        -- native hold — no partial/gap flicker). Below full, write the modeled value every frame (0
        -- included) so ramp-feather and release-to-0 are honoured with no latch. The limiter case is
        -- handled by the early-return above, so a full hold that hits redline hands throttle back to
        -- the gearbox's kill instead of fighting it. NOTE: turbo lag can hold eff below INJECT_FULL even
        -- with the key pinned, so the choked pedal is written faithfully (that's the intended feel).
        if eff >= INJECT_FULL and HK._injPressed then
            SetControlNormal(0, 71, 1.0)
        else
            SetControlNormal(0, 71, eff)
        end
    end
end

-- REVERSE SPEED CAP + SLOW RAMP (2026-08-14 v2) — real cars reverse SLOWLY (short reverse gearing tops
-- out ~30-45 km/h) and build to it gradually. GTA lets you reverse nearly as fast as you drive.
--
-- WHY NOT control 72: v1 tried limiting/zeroing the reverse-accelerator (control 72). It did NOTHING —
-- on this gearbox reverse thrust comes from DRIVE FORCE + gear selection, not the 72 analog magnitude
-- (72 mostly gates direction). So both the cap AND the slow ramp were invisible. This governs backward
-- SPEED DIRECTLY instead, independent of how reverse power reaches the wheels: a ceiling that RAMPS from
-- low up to MaxKmh, and each frame we clamp backward speed to it by adding just enough FORWARD velocity
-- to shave the excess. We only ever REMOVE backward motion (never add), so lifting S still coasts down
-- naturally and there's no launch/yank (the drift-exit hazard was ADDING velocity along a pitched axis;
-- here we use the FLATTENED forward vector and only subtract the over-ceiling component).
--
-- SAFETY: only acts when PHYSICALLY MOVING BACKWARD (forwardSpeed < 0). Slide forward at speed + stab S →
-- forwardSpeed stays POSITIVE → never fires (that S is just braking). Gear/gate state isn't consulted.
local revCeilKmh = 0.0      -- current ramping reverse ceiling (km/h); climbs from RampStart to MaxKmh
local revRampT = 0.0        -- normalised ramp progress 0->1 (so we can ease the shape, not just linear)
local revWasActive = false  -- were we reversing last frame (to (re)seed the ramp on engage)
function HK.ReverseCap_Tick(state, dt)
    local rc = Config.Gearbox and Config.Gearbox.ReverseSpeedCap
    if not rc or rc.Enabled == false then return end
    local fwd = state.forwardSpeed or 0.0     -- m/s; NEGATIVE = actually moving backward
    dt = dt or state.frameTime or 0.016

    -- Not reversing (moving forward / stopped): reset so the NEXT reverse ramps slow from scratch.
    if fwd > -0.10 then
        if fwd > 0.5 then revWasActive = false; revCeilKmh = 0.0; revRampT = 0.0 end   -- clearly forward → full reset
        return                                                          -- near-stop: hold state, do nothing
    end

    local maxKmh   = rc.MaxKmh or 40.0
    local startKmh = math.min(rc.RampStartKmh or 6.0, maxKmh)
    -- Seed the ceiling on the frame reverse engages (start low so it builds gradually, not from whatever
    -- speed a roll-back had). Then ramp toward MaxKmh over RampMs on a normalised PROGRESS integrator so
    -- we can EASE the shape (linear climb then a hard slam into the cap felt abrupt). revRampT 0->1.
    if not revWasActive then
        revWasActive = true
        revCeilKmh   = startKmh
        revRampT     = 0.0
    end
    if revRampT < 1.0 then
        local dtMs = dt * 1000.0
        revRampT = math.min(1.0, revRampT + dtMs / math.max(1.0, rc.RampMs or 2500.0))
        -- EASE-OUT (smoothstep-style, cubic): fast off the standstill, then tapers gently as it nears the
        -- cap so the ceiling glides in instead of the car walking straight into a wall. e = 1-(1-t)^3.
        local inv = 1.0 - revRampT
        local eased = 1.0 - inv * inv * inv
        revCeilKmh = startKmh + (maxKmh - startKmh) * eased
    end

    local revKmh = -fwd * 3.6
    HK.dbgRevCap = { revKmh = revKmh, cap = revCeilKmh, max = maxKmh, at = GetGameTimer() }
    if revKmh <= revCeilKmh then return end   -- under the (ramping) ceiling → let it build

    -- Over ceiling: add FORWARD velocity to cancel exactly the excess backward speed. Flattened forward
    -- vector (horizontal only — pitch would skew the basis and pop the car, the terrain/drift-exit bug).
    local vel = state.velocity
    if not vel then return end
    local f = GetEntityForwardVector(state.vehicle)
    if not f then return end
    local fx, fy = f.x, f.y
    local fmag = math.sqrt(fx * fx + fy * fy)
    if fmag < 1e-4 then return end
    fx, fy = fx / fmag, fy / fmag
    local excessMs = (revKmh - revCeilKmh) / 3.6      -- m/s of backward speed to remove
    SetEntityVelocity(state.vehicle, vel.x + fx * excessMs, vel.y + fy * excessMs, vel.z)
end

-- FULL VELOCITY-DRIVEN REVERSE (2026-08-14 rework). THE LESSON from many rounds: GTA control 72 CANNOT
-- be shared between "our W injection" and "suppress a physically-held S" — SetControlNormal can't hold a
-- control below a held key, so any scheme that keeps 72 enabled leaks the physical key (both W and S end
-- up reversing, and wheel-braking can't beat the engine's reverse drive force). So in reverse the gearbox
-- DISABLES BOTH 71 and 72 (no native reverse thrust at all) and we drive backward speed DIRECTLY here —
-- the same SetEntityVelocity mechanism ReverseCap already uses to cap it, now doing the whole job:
--   * W  -> accelerate backward toward the cap
--   * S  -> brake backward speed toward 0 (firm, car-like)
--   * neither -> coast down (engine-brake)
-- Longitudinal-ONLY: we decompose velocity into the forward-axis component (which we control) and the
-- lateral remainder (preserved untouched) so STEERING while reversing still works. Only runs when in a
-- reverse gear AND the pedal model is injecting (keyboard); analog/wheel/off falls back to the native
-- reverse (control 72) that the gearbox leaves live in that path, capped by ReverseCap_Tick above.
function HK.ReverseDrive_Tick(state, dt)
    if HK.inReverseGear ~= true then return end
    local injecting = HK.pedalModelOn and not HK._injAnalog and not HK.driftMode
    if not injecting then return end
    local rd = Config.Gearbox and Config.Gearbox.ReverseDrive
    if not rd or rd.Enabled == false then return end
    if IsEntityInAir(state.vehicle) then return end
    dt = dt or state.frameTime or 0.016

    local vel = state.velocity
    local f   = GetEntityForwardVector(state.vehicle)
    if not vel or not f then return end
    local fx, fy = f.x, f.y
    local fmag = math.sqrt(fx * fx + fy * fy)
    if fmag < 1e-4 then return end
    fx, fy = fx / fmag, fy / fmag

    local fwd    = state.forwardSpeed or 0.0        -- m/s; NEGATIVE = moving backward
    local revKmh = -fwd * 3.6                       -- backward speed (+ = going backward)
    if revKmh < 0.0 then revKmh = 0.0 end           -- rolling forward: treat as 0 backward

    local W = HK._pedalThrottle or 0.0              -- physical W (0..1)
    local S = HK._pedalBrake or 0.0                 -- physical S (0..1)
    local maxKmh = (Config.Gearbox.ReverseSpeedCap and Config.Gearbox.ReverseSpeedCap.MaxKmh) or 42.0

    -- SLOPE (gravity along the forward axis). f.z is the forward vector's vertical component: nose-DOWN
    -- gives f.z<0, nose-UP gives f.z>0. Backward speed (revKmh) is +ve going backward, so an UPHILL nose
    -- (f.z>0) should ADD backward roll (the car rolls back down the hill) and a downhill nose should shed
    -- it. grade = f.z ≈ sin(pitch); accel = g*sin along-slope. Off the brake this makes reverse roll back
    -- on a hill like a real car; on the brake the brake term still wins.
    local rc = Config.Gearbox and Config.Gearbox.RollCreep
    local gravKmhPerS = 0.0
    if rc and rc.Enabled ~= false then
        gravKmhPerS = (rc.GravityKmhPerS or 34.0) * f.z    -- +f.z (nose up) => +backward roll
    end

    local dv
    if S > 0.05 then
        dv = -(rd.BrakeKmhPerS or 60.0) * S * dt    -- brake toward 0
    elseif W > 0.05 then
        dv =  (rd.AccelKmhPerS or 22.0) * W * dt    -- accelerate backward
    else
        dv = -(rd.CoastKmhPerS or 14.0) * dt        -- coast down
    end
    dv = dv + gravKmhPerS * dt                       -- slope roll (both branches; brake still dominates)
    local newKmh = revKmh + dv
    if newKmh < 0.0 then newKmh = 0.0 elseif newKmh > maxKmh then newKmh = maxKmh end

    -- Decompose velocity: longitudinal (along forward vector) vs lateral remainder. Control ONLY the
    -- longitudinal component; keep the lateral (turning) velocity so steering while reversing works.
    local vdotf = vel.x * fx + vel.y * fy           -- current longitudinal m/s (+ = forward)
    local latx, laty = vel.x - vdotf * fx, vel.y - vdotf * fy
    local targetLong = -(newKmh / 3.6)              -- backward = negative along forward vector
    SetEntityVelocity(state.vehicle, latx + fx * targetLong, laty + fy * targetLong, vel.z)

    -- REVERSE BRAKE LIGHT. In a reverse gear we DISABLE both control 71/72, so GTA's native brake-light
    -- logic never fires (it follows the brake control, which we've killed) — that's why the brake light
    -- "went missing" in reverse only. We drive it DIRECTLY here off our real brake input (S = the
    -- physical S key, HK._pedalBrake): light ON while S is held, OFF otherwise — exactly like a forward
    -- gear. Reasserted every frame (the game re-evaluates it). NOTE: this is the BRAKE lamp only; the
    -- dim red running-ring at night comes from the headlights (SetVehicleLights) and is unaffected.
    if SetVehicleBrakeLights then SetVehicleBrakeLights(state.vehicle, S > 0.05) end

    HK.dbgRevCap = { revKmh = newKmh, cap = maxKmh, max = maxKmh, at = GetGameTimer() }
end

-----------------------------------------------------------------
-- ROLL / CREEP BASE LAYER (2026-08-16) — the missing low-speed longitudinal model for a FORWARD or
-- NEUTRAL car. GTA auto-holds a stopped car (no idle creep, no slope roll); real cars without an e-brake
-- CREEP forward in gear and ROLL on any grade when you're not fully on the brake. This is the base every
-- launch/wheelspin sits on: it's what makes the car "roll forward at the end" of a spin instead of
-- stopping dead. Mirrors ReverseDrive_Tick (direct longitudinal velocity, lateral preserved) but for the
-- forward/neutral side, and only inside the low-speed CRAWL band — above HandoffKmh real engine torque
-- owns motion and this stands aside.
--
-- BEHAVIOUR (user spec):
--   * IN GEAR (D): idle CREEP pulls toward CreepKmh on the flat (torque-converter walk) + gravity; engine-
--     braking resistance caps a downhill runaway. Manual boxes creep MORE (ManualCreepMult).
--   * NEUTRAL / clutch held: NO creep — just gravity with low resistance = free roll; on flat it COASTS to
--     a stop (rolling resistance), only slopes move it. (User: "coast to a stop" on flat neutral.)
--   * BRAKE scales the drive terms down; full brake pins it (partial brake = partial hold = "didn't fully
--     hold brake -> rolls").
--   * Feeds wheelspin: only runs when NOT burnoutActive / launchTractionActive, so the frame a spin tapers
--     the roll takes over and the car rolls forward off the line.
-----------------------------------------------------------------
function HK.RollCreep_Tick(state, dt)
    local rc = Config.Gearbox and Config.Gearbox.RollCreep
    if not rc or rc.Enabled == false then return end
    if HK.inReverseGear == true then return end             -- reverse handles its own roll (above)
    -- Don't fight the spin gestures — they own low-speed motion while active. The instant they release,
    -- this resumes and rolls the car forward (the "how a wheelspin rolls forward at the end" link).
    if HK.burnoutActive == true or HK.launchTractionActive == true then return end
    if HK.driftMode == true then return end                 -- drift owns its own low-speed motion
    local veh = state.vehicle
    if not veh or veh == 0 or not DoesEntityExist(veh) then return end
    if IsEntityInAir(veh) then return end
    dt = dt or state.frameTime or 0.016
    if dt <= 0.0 then dt = 0.016 end

    local vel = state.velocity
    local f   = GetEntityForwardVector(veh)
    if not vel or not f then return end
    local fx, fy = f.x, f.y
    local fmag = math.sqrt(fx * fx + fy * fy)
    if fmag < 1e-4 then return end
    fx, fy = fx / fmag, fy / fmag

    local fwdMs = state.forwardSpeed or 0.0                  -- m/s, + = forward
    local kmh   = fwdMs * 3.6                                -- signed forward km/h
    -- CRAWL BAND: only shape motion below HandoffKmh. Above it, real drive torque owns the car — bail so
    -- we never cap acceleration or fight the gearbox. Also bail if moving backward faster than a hair
    -- (that's reverse/rollback territory handled elsewhere) unless we're the ones rolling it.
    local handoff = rc.HandoffKmh or 12.0
    if kmh > handoff then return end

    -- INPUTS (device-agnostic via the pedal signals, immune to DisableControlAction).
    local W = HK._pedalThrottle or 0.0
    local S = HK._pedalBrake or 0.0
    -- Real throttle above a hair means the player is launching — hand off to drive torque, don't creep.
    if W > (rc.ThrottleHandoff or 0.10) then return end

    local inNeutral = (HK.gbInNeutral == true) or (HK.gbClutchHeld == true)

    -- SLOPE term: gravity along the forward axis. f.z<0 = nose down = roll FORWARD (+kmh). accel ≈ g*sin.
    local grav = -(rc.GravityKmhPerS or 34.0) * f.z         -- -f.z: nose-down (f.z<0) => +forward

    -- CREEP term: only in gear, only forward, tapering to 0 as we approach CreepKmh (torque-converter
    -- walk). Manual boxes creep more (user). Zero in neutral (free-roll).
    local creepTarget = 0.0
    if not inNeutral then
        local base = rc.CreepKmh or 9.0
        if HK.gbManual == true then base = base * (rc.ManualCreepMult or 1.35) end
        creepTarget = base
        -- UPHILL CREEP CUT (2026-08-16 — the "it can roll UPWARDS without throttle" bug): idle creep is a
        -- weak torque-converter walk. Its seek rate (resist ~8) is on the order of full gravity (~12), so
        -- inside the crawl band creep would out-pull gravity and CLIMB even a steep hill on its own. A real
        -- idling auto creeps on the flat/downhill but a hill HOLDS it or rolls it back. Fade creep toward 0
        -- as uphill grade (f.z>0 = nose up) rises, so on an incline gravity wins.
        if f.z > 0.0 then
            local grade = rc.CreepHillGrade or 0.10        -- ~6°: creep fully gone above this uphill grade
            local cut = 1.0 - math.min(1.0, f.z / math.max(grade, 1e-3))
            creepTarget = creepTarget * cut
        end
    end

    -- RESISTANCE: rolling + engine-brake drag that pulls speed toward 0 (stronger in gear = engine brake,
    -- lighter in neutral = free-wheel). This is what makes NEUTRAL on the flat coast to a stop and caps a
    -- downhill roll instead of letting gravity run away.
    local resist = inNeutral and (rc.NeutralResistKmhPerS or 3.0) or (rc.GearResistKmhPerS or 8.0)

    -- Compose the target-seeking accel. In gear we chase creepTarget (+ gravity); the resistance term is
    -- folded into the chase toward creepTarget (below it we accelerate up to it, above it we're dragged
    -- down). In neutral there's no creep pull, so it's pure gravity vs resistance.
    local dvdt
    if inNeutral then
        -- gravity accelerates; resistance opposes CURRENT motion (sign-based) so it coasts to rest on flat.
        local rsign = (kmh > 0.05) and -1.0 or ((kmh < -0.05) and 1.0 or 0.0)
        dvdt = grav + resist * rsign
    else
        -- in gear: seek (creepTarget) with the resistance acting as the approach rate, plus gravity. Below
        -- target we're pulled up toward it; above (e.g. gravity pushed us past) we're dragged back down.
        local toward = creepTarget - kmh
        local seek = math.max(-resist, math.min(resist, toward))   -- clamp the chase rate to resist
        dvdt = grav + seek
    end

    -- ABSOLUTE HOLD: a held HANDBRAKE or a firm FOOTBRAKE pins the car completely — it cancels the slope
    -- pull entirely, it does NOT just slow a rate gravity can out-push (that was the "creeps on a hill even
    -- with both brakes held" bug: my rate-based brake lost to gravity on a steep grade, and I never read the
    -- handbrake AT ALL — so on FWD it only "worked" when GTA's own native handbrake happened to resist).
    -- Robust handbrake read (same OR the gearbox uses): cached flag + live pressed (normal + disabled) +
    -- native vehicle handbrake, so it's independent of who DisableControlAction's control 76.
    local hbHeld = (state.handbrake == true)
                or IsControlPressed(0, 76) or IsDisabledControlPressed(0, 76)
                or (GetVehicleHandbrake(veh) == true)
    local fullBrake = S >= (rc.BrakeHoldMin or 0.55)
    if hbHeld or fullBrake then
        -- ABSOLUTE HOLD applies ONLY once the car is essentially STOPPED (|kmh| <= HoldPinKmh): it PINS a
        -- settled car against creep/gravity so a held brake/handbrake on a hill can't be out-pushed. It must
        -- NOT fire while the car is still rolling into the crawl band — zeroing velocity there was the
        -- "instant stop at ~20-and-under when I press brake" teleport. ABOVE the pin speed we DECELERATE at
        -- a firm rate toward 0 (a normal brake-to-stop), and only clamp once we settle.
        local pinKmh = rc.HoldPinKmh or 3.0
        if math.abs(kmh) <= pinKmh then
            -- SETTLED: pin velocity to 0 so a held brake/handbrake holds against creep + gravity (a stopped
            -- car on a hill can't be out-pushed). Only kicks in once the car has genuinely crawled to rest.
            local vdotf0 = vel.x * fx + vel.y * fy
            SetEntityVelocity(veh, vel.x - vdotf0 * fx, vel.y - vdotf0 * fy, vel.z)
            if S > 0.05 and HK.setStandstillBrakeLight then HK.setStandstillBrakeLight(veh, true) end
            HK.dbgRollCreep = { kmh = kmh, new = 0.0, grav = grav, creep = creepTarget,
                                neut = inNeutral, brk = S, hb = (hbHeld == true), held = true, at = GetGameTimer() }
            return
        end
        -- STILL ROLLING with real speed in the crawl band. Two cases:
        --  (a) FORWARD (kmh > 0): DON'T override velocity — let GTA's own (buffed) native footbrake
        --      decelerate on its real physics curve. Overriding with a forced ramp was the "instant stop"
        --      bug (a clamp discontinuity at the 12 km/h handoff). Native braking is smooth down to the pin.
        --  (b) BACKWARD (kmh < 0, a downhill/creep rollback): the standstill-brake code DISABLES control 72
        --      whenever forwardSpeed < 0.5 (includes any backward roll), so GTA's NATIVE FOOTBRAKE IS DEAD
        --      here — standing aside meant the footbrake couldn't stop a backward roll at all (it just
        --      coasted), while the handbrake (control 76, never disabled) bit instantly. That's the reported
        --      "footbrake can't stop a backward roll but handbrake can" bug. So on a backward roll we ACTIVELY
        --      decelerate longitudinal velocity toward 0 ourselves, scaled by pedal (handbrake = full).
        if kmh < 0.0 then
            local pedal = hbHeld and 1.0 or math.min(1.0, S)
            local decel = (rc.RollbackBrakeKmhPerS or 45.0) * pedal
            local newKmh = kmh + decel * dt          -- kmh<0, add positive → toward 0
            if newKmh > 0.0 then newKmh = 0.0 end
            local vdotf0 = vel.x * fx + vel.y * fy
            local latx0, laty0 = vel.x - vdotf0 * fx, vel.y - vdotf0 * fy
            local tl = newKmh / 3.6
            SetEntityVelocity(veh, latx0 + fx * tl, laty0 + fy * tl, vel.z)
        end
        if S > 0.05 and HK.setStandstillBrakeLight then HK.setStandstillBrakeLight(veh, true) end
        HK.dbgRollCreep = { kmh = kmh, new = kmh, grav = grav, creep = creepTarget,
                            neut = inNeutral, brk = S, hb = (hbHeld == true),
                            held = (kmh < 0.0) and 'rollback' or 'native', at = GetGameTimer() }
        return
    end

    -- PARTIAL FOOTBRAKE (below the hold threshold): scales DOWN the go-forward drive and adds braking
    -- toward 0, so a light brake = a slow roll ("didn't FULLY hold the brake → rolls"). Never reverses.
    if S > 0.02 then
        local bkKmhPerS = (rc.BrakeKmhPerS or 40.0) * S
        if dvdt > 0.0 then dvdt = dvdt * (1.0 - math.min(1.0, S)) end
        local bsign = (kmh > 0.05) and -1.0 or ((kmh < -0.05) and 1.0 or 0.0)
        dvdt = dvdt + bkKmhPerS * bsign
    end

    local newKmh = kmh + dvdt * dt
    -- clamp inside the crawl band; never let roll push past handoff (drive torque takes over there anyway)
    if newKmh > handoff then newKmh = handoff end
    -- don't manufacture meaningful backward speed from creep/brake noise — allow a gentle rollback on a
    -- real uphill (grav>0 while nose-up), floored so it can't run away into fake reverse.
    local rollbackFloor = -(rc.MaxRollbackKmh or 8.0)
    if newKmh < rollbackFloor then newKmh = rollbackFloor end
    -- deadband: settle to a true stop instead of jittering around 0.
    if math.abs(newKmh) < (rc.StopDeadbandKmh or 0.15) then newKmh = 0.0 end

    -- Write ONLY the longitudinal component; preserve lateral (turning) velocity so steering still works
    -- (same decomposition ReverseDrive_Tick uses).
    local vdotf = vel.x * fx + vel.y * fy
    local latx, laty = vel.x - vdotf * fx, vel.y - vdotf * fy
    local targetLong = newKmh / 3.6
    SetEntityVelocity(veh, latx + fx * targetLong, laty + fy * targetLong, vel.z)

    -- Brake light while genuinely braking at crawl (native lamp is killed at standstill by the reverse rework).
    if S > 0.05 and HK.setStandstillBrakeLight then HK.setStandstillBrakeLight(veh, true) end

    HK.dbgRollCreep = { kmh = kmh, new = newKmh, grav = grav, creep = creepTarget,
                        neut = inNeutral, brk = S, at = GetGameTimer() }
end

-----------------------------------------------------------------
-- STEERING MODEL (2026-08-14) — device-agnostic analog steering for keyboard.
-- Keyboard A/D is BINARY and GTA applies its own twitchy ramp to control 59. This synthesizes smooth
-- analog "steering travel" the way sim racers do for keyboard players (Assetto/adam10603/iRacing):
--   * LINEAR time-ramp (NOT the throttle's ease-in gamma) — sims keep the keyboard ramp linear and put
--     the nonlinearity into speed-scaling instead.
--   * SLOWER build than the throttle — over-steer instantly costs front grip, so steer-in is damped
--     harder than throttle build (explicit sim-tuning guidance).
--   * RECENTER FASTER than steer-in, toward ZERO (not velocity-heading) — drift.lua already owns the
--     caster / countersteer-toward-velocity behaviour; this stays a pure input-shaper so the two don't
--     fight. Off-drift, recentering to 0 = a released wheel springing back.
--   * SPEED-SCALED RATE — slower slew at speed (anti-twitch). Composes with Config.SteerRangeLowSpeed,
--     which scales max ANGLE (fSteeringLock); this scales the RATE. Orthogonal, both wanted.
-- SINGLE WRITER on control 59 (same control hk-handling reads as state.steer), so sim + visuals + GTA
-- all agree. SAME feedback-loop rule as the pedals: we WRITE 59, so we must NOT read it — physical A/D
-- come from IsRawKeyDown (immune to our SetControlNormal). Analog devices pass through untouched.
local steerModelCur = 0.0     -- smoothed -1..1 we push into control 59 (0.5 = center after remap)
local steerModelVeh = nil     -- last vehicle (reset the integrator on a vehicle change)

local function readPhysicalSteer()
    -- Returns (keyboard, targetDir -1/0/+1, leftDown, rightDown). Keyboard only; nil target on analog.
    local keyboard = not not IsInputDisabled(2)
    if not (keyboard and rawKeysOk) then return keyboard, nil, false, false end
    local okA, aDown = pcall(IsRawKeyDown, RAWKEY_A)
    local okD, dDown = pcall(IsRawKeyDown, RAWKEY_D)
    if not (okA and okD) then rawKeysOk = false; return keyboard, nil, false, false end
    local left  = aDown and true or false
    local right = dDown and true or false
    local dir = 0.0
    if left and not right then dir = -1.0
    elseif right and not left then dir = 1.0 end   -- both or neither = 0 (recenter)
    return keyboard, dir, left, right
end

-- STEER TAP-HOLD (2026-08-14) — the steering sibling of the pedal tap-hold. On keyboard, holding A/D
-- winds to FULL lock (the normal-corner case, unchanged). But to hold a SHALLOW constant angle you must
-- feather-tap, and a pure ramp turns that into a sawtooth (winds in on press, springs back on release).
-- This converts rhythmic tapping into a STABLE partial-lock target the slew then holds. Direction MUST be
-- remembered (between taps the key is up → instantaneous dir=0, which would sawtooth); P.lastDir owns it.
-- Returns a SIGNED target (-1..1); the tick's slew drives toward it (so this needs no converge rate).
local stSteer = { wasPressed = false, lastTapAt = -1e9, cadence = 0.0, lastDir = 0.0 }

local function steerTapTarget(P, dir, now, tc)
    -- dir: instantaneous -1/0/+1 steer direction from the keys THIS frame (0 = neither / both).
    -- SEMANTICS (steering, not throttle): while a key is DOWN we ALWAYS target FULL lock in that
    -- direction — turn-in is never delayed, a normal held corner winds straight to full. The tap-hold
    -- magic is entirely in the RELEASE: between taps we don't spring all the way back to center, we
    -- settle to a cadence-set PARTIAL lock. So rhythmic feathering time-slices full(down)↔partial(up)
    -- and the slew settles at a shallow held angle; faster taps = higher cadence = higher partial floor.
    local pressed = (dir ~= 0.0)
    -- Flicking L↔R without releasing is a fresh corner the other way: new rising edge + reset the rhythm.
    local flipped = pressed and P.lastDir ~= 0.0 and dir ~= P.lastDir

    if pressed and (not P.wasPressed or flipped) then
        local gap = now - (P.lastTapAt or -1e9)
        P.lastTapAt = now
        -- On a flip the gap is against the OTHER direction's tap = meaningless → start that side at cadence 0.
        P.cadence = flipped and 0.0
            or tprLerpClamp(gap, tc.TapFastGapMs or 110.0, tc.TapSlowGapMs or 400.0, 1.0, 0.0)
    end
    if pressed then P.lastDir = dir end
    P.wasPressed = pressed

    local sinceTap = now - (P.lastTapAt or -1e9)

    if pressed then
        return dir                  -- key down → full lock this direction (no turn-in delay; a hold winds to full)
    elseif sinceTap < (tc.TapMemoryMs or 320.0) and P.lastDir ~= 0.0 then
        -- RELEASED but still in a tap rhythm → settle to a cadence-set PARTIAL lock instead of full recenter.
        local floorT = tc.TapTargetFloor or 0.22   -- lock held at the slowest countable tap rhythm
        local ceilT  = tc.TapTargetCeil  or 0.80   -- lock held at the fastest feather (<1: full is hold-only)
        return P.lastDir * (floorT + P.cadence * (ceilT - floorT))
    else
        P.cadence = 0.0; P.lastDir = 0.0
        return 0.0                  -- idle (no tap for TapMemoryMs, key up) → full recenter
    end
end

-- Called from the main loop AFTER drift's steering writes and only when NOT in drift mode (drift owns
-- the wheel via SetVehicleSteeringAngle). pcall-isolated by the caller like the pedal ticks.
function HK.SteeringModel_Tick(state, dt)
    local cfg = Config.Drivetrain and Config.Drivetrain.SteeringModel
    if not HK.steerModelOn or not cfg or cfg.Enabled == false then
        HK._steerModelActive = false
        return
    end

    local keyboard, dir, left, right = readPhysicalSteer()
    HK._steerKbd = keyboard; HK._steerLeft = left; HK._steerRight = right

    -- Analog device (controller/wheel): never inject — its control 59 is already smooth + clean.
    if not keyboard or dir == nil then
        HK._steerModelActive = false
        steerModelCur = state.steer or 0.0     -- track so a keyboard→pad handoff doesn't jump
        return
    end

    -- Reset the integrator on a vehicle change (no steer carried across cars).
    if state.vehicle ~= steerModelVeh then
        steerModelVeh = state.vehicle
        steerModelCur = 0.0
    end

    local kmh = state.speedKmh or 0.0
    -- SPEED-SCALED RATE: slew slower at speed (anti-twitch). Lerp a multiplier from LowMult (<=LowKmh)
    -- down to HighMult (>=HighKmh). Applied to BOTH steer-in and recenter base rates.
    local spdMult = tprLerpClamp(kmh,
        cfg.SpeedRateLowKmh or 30.0, cfg.SpeedRateHighKmh or 160.0,
        cfg.SpeedRateLowMult or 1.0, cfg.SpeedRateHighMult or 0.45)

    -- LINEAR rate-limited slew (NO ease-in gamma). Rates are "units of -1..1 travel per second"; a rate
    -- R sweeps full lock in 1/R seconds. Steer-in is the SLOW one; recenter is faster (released wheel
    -- springs back). SteerInMs/RecenterMs express the sweep time in ms for readability.
    local inRate  = 1000.0 / math.max(1.0, (cfg.SteerInMs or 420.0))
    local outRate = 1000.0 / math.max(1.0, (cfg.RecenterMs or 260.0))

    -- RWD SLIDE-CATCH: RWD steers a little differently to FWD/AWD — when the tail is out you need the
    -- wheel back (and to opposite lock) FAST to catch it. Compute a per-drivetrain rate bump that only
    -- wakes up when a RWD car is genuinely sliding, so normal driving feel is untouched. Recenter/cross
    -- (the catch) gets the strong bump; wind-in gets a milder one so you can't over-rotate into the slide.
    local catchIn, catchOut = 1.0, 1.0
    local scfg = cfg.RwdSlideCatch
    if scfg and scfg.Enabled ~= false and HK.dbgDrive and HK.dbgDrive.class == 'rwd'
        and kmh >= (scfg.MinSpeedKmh or 25.0) then
        local fwdS = state.forwardSpeed or 0.0
        local latS = state.lateralSpeed or 0.0
        local slipDeg = (fwdS > 1.0) and math.abs(math.deg(math.atan(latS / fwdS))) or 0.0
        -- 0 at the gate → 1 at full slip (linear).
        local g0, g1 = (scfg.SlipGateDeg or 12.0), (scfg.SlipFullDeg or 35.0)
        local t = (slipDeg - g0) / math.max(0.001, (g1 - g0))
        if t < 0.0 then t = 0.0 elseif t > 1.0 then t = 1.0 end
        HK._rwdCatchT = t
        if t > 0.001 then
            catchIn  = 1.0 + ((scfg.TurnInMult   or 1.15) - 1.0) * t
            catchOut = 1.0 + ((scfg.RecenterMult or 1.45) - 1.0) * t
        end
    else
        HK._rwdCatchT = 0.0
    end

    -- TARGET: raw bang-bang (-1/0/+1) by default, or a SIGNED tap-hold target when TapHold is on. Tap-hold
    -- lets rhythmic A/D feathering settle on a STABLE partial lock (shallow constant angle) instead of
    -- sawtoothing; a genuine hold still winds to full. The slew below drives cur toward whichever target.
    local target
    if cfg.TapHold == true then
        target = steerTapTarget(stSteer, dir, state.gameTimer or GetGameTimer(), cfg)
    else
        target = dir
    end

    local rate
    if target == 0.0 then
        rate = outRate * catchOut                       -- recentering to 0 (catch: bring it back fast)
    elseif (target > 0.0) == (steerModelCur >= 0.0) then
        rate = inRate * catchIn                          -- winding toward a same-side lock (mild catch bump)
    else
        rate = outRate * catchOut                        -- crossing center (flick L↔R = the countersteer catch): fast
    end
    rate = rate * spdMult

    local step = rate * dt
    if steerModelCur < target then
        steerModelCur = math.min(steerModelCur + step, target)
    elseif steerModelCur > target then
        steerModelCur = math.max(steerModelCur - step, target)
    end
    if steerModelCur < -1.0 then steerModelCur = -1.0 elseif steerModelCur > 1.0 then steerModelCur = 1.0 end

    -- Optional MILD on-center gamma (desensitize dead-center only). Default 1.0 (off) — sims add this
    -- only if on-center feels darty; the ramp itself stays linear. Sign-preserving: |x|^g * sign.
    local g = cfg.Gamma or 1.0
    local out = steerModelCur
    if g ~= 1.0 then
        local s = (out < 0.0) and -1.0 or 1.0
        out = s * (math.abs(out) ^ g)
    end

    -- REVERSE RANGE CLAMP: limit steering angle to 75% in reverse (turning too fast at full range).
    -- Negative forwardSpeed = backing up (same reverse gate as the throttle/brake reversal).
    if (state.forwardSpeed or 0.0) < 0.5 then
        out = out * (cfg.ReverseRangeMult or 0.75)
    end

    -- AIRBORNE RECENTER: GTA turns a steered front-wheel angle into body YAW in the air (no tyre grip),
    -- so a carried steer angle off a ramp spins the car sideways instead of flying it forward. Ease the
    -- WRITTEN angle toward center while airborne so nothing gets injected and it lands flat. We ease BOTH
    -- `out` (the value written this frame) AND `steerModelCur` (the integrator) toward 0 so there's no
    -- snap-back on touchdown — the wheel re-winds from center to whatever the player is holding.
    if cfg.AirborneRecenter ~= false and state.onAllWheels == false then
        local aTau = (cfg.AirborneRecenterMs or 140.0) / 1000.0
        local a = 1.0 - math.exp(-dt / math.max(0.001, aTau))
        out = out + (0.0 - out) * a
        steerModelCur = steerModelCur + (0.0 - steerModelCur) * a
    end

    -- SINGLE WRITE to control 59. Range is SYMMETRIC -1..1 (0 = center) for BOTH read and write —
    -- SetControlNormal(59) is NOT 0..1 here. (The old (out+1)*0.5 remap mapped center→0.5 = half-lock
    -- right: the "always steers right at idle" bug, copied from hk-wheel's identical mistake. Write raw.)
    SetControlNormal(0, 59, out)
    HK._steerModelActive = true
    HK._steerModelOut = out
    -- Publish rate detail for /handlingdbg: base sweep times (ms) + the speed multiplier + the EFFECTIVE
    -- (speed-scaled) sweep times. Effective sweep time = baseMs / spdMult (a smaller mult = slower slew =
    -- longer sweep). inSweepMs = time to wind to full lock at THIS speed; outSweepMs = time to recenter to 0.
    local m = (spdMult > 0.001) and spdMult or 0.001
    HK.dbgSteerModel = { cur = steerModelCur, out = out, dir = dir, target = target,
                         spdMult = spdMult, cadence = stSteer.cadence,
                         inMs = cfg.SteerInMs or 420.0, outMs = cfg.RecenterMs or 260.0,
                         inSweepMs = (cfg.SteerInMs or 420.0) / m,     -- wind-to-full at this speed
                         outSweepMs = (cfg.RecenterMs or 260.0) / m,   -- recenter-to-0 at this speed
                         inRate = inRate * spdMult, outRate = outRate * spdMult,  -- units/sec effective
                         rate = rate, activeRate = rate,               -- the rate chosen THIS frame
                         catchT = HK._rwdCatchT or 0.0,                -- RWD slide-catch engagement 0..1 (0 unless RWD + sliding)
                         catchIn = catchIn, catchOut = catchOut,       -- the applied rate multipliers
                         at = GetGameTimer() }
end

-----------------------------------------------------------------
-- DRIFT STEERING INPUT SHAPER (2026-09-06) — see Config.Drift.Steering. In drift mode the normal
-- steering model is skipped, so keyboard A/D hits control 59 as RAW BINARY (instant snap to lock =
-- the "noclip heading turn" the tail then follows in one frame). This is a drift-tuned twin of
-- SteeringModel_Tick: it eases the INPUT (soft center via Gamma, smooth outer via OuterEase, slow
-- turn-in via SteerInMs) and writes control 59 as the SOLE writer during drift. It does NOT touch
-- drift physics; CounterSteer still writes SetVehicleSteeringAngle on top when a slide is committed
-- (as it already does today over the raw binary), so this only replaces the snap with a smooth ramp.
-- SEPARATE integrator + tap state from the normal model so entering/leaving drift never cross-talks.
local driftSteerCur = 0.0
local driftSteerVeh = nil
local stDriftSteer = { wasPressed = false, lastTapAt = -1e9, cadence = 0.0, lastDir = 0.0 }
-- HOLD-THEN-RECENTER (2026-09-06): on release the steer angle FREEZES for HoldMs (the slide sustains),
-- THEN winds back to center over RecenterMs. driftSteerRelAt = when the keys went neutral (0 = keys held).
local driftSteerRelAt   = 0
local driftSteerHoldFrom = 0.0   -- the |angle| captured at release (the plateau we hold before recentering)

function HK.DriftSteering_Tick(state, dt)
    local cfg = Config.Drift and Config.Drift.Steering
    if not cfg or cfg.Enabled == false then HK._driftSteerActive = false; return end

    local keyboard, dir = readPhysicalSteer()
    -- Analog device (pad/wheel): control 59 is already smooth + player-owned; never inject.
    if not keyboard or dir == nil then
        HK._driftSteerActive = false
        driftSteerCur = state.steer or 0.0     -- track so a pad->keyboard handoff doesn't jump
        driftSteerRelAt = 0                    -- clear the release timer (no stale hold across handoff)
        return
    end

    -- Reset the integrator on a vehicle change (no steer carried across cars).
    if state.vehicle ~= driftSteerVeh then
        driftSteerVeh = state.vehicle; driftSteerCur = 0.0
        driftSteerRelAt = 0; driftSteerHoldFrom = 0.0
    end

    local kmh = state.speedKmh or 0.0
    local spdMult = tprLerpClamp(kmh,
        cfg.SpeedRateLowKmh or 30.0, cfg.SpeedRateHighKmh or 160.0,
        cfg.SpeedRateLowMult or 1.0, cfg.SpeedRateHighMult or 0.55)

    local inRate  = 1000.0 / math.max(1.0, (cfg.SteerInMs or 1400.0))
    local outRate = 1000.0 / math.max(1.0, (cfg.RecenterMs or 1200.0))
    local nowMs   = state.gameTimer or GetGameTimer()

    -- TARGET via the SAME tap-hold as the normal model (shallow held angle on feathering).
    local target = steerTapTarget(stDriftSteer, dir, nowMs,
        { TapFastGapMs = 110.0, TapSlowGapMs = 400.0, TapTargetFloor = 0.22, TapTargetCeil = 0.80, TapMemoryMs = 320.0 })

    -- HOLD-THEN-RECENTER: while the player is actively steering (target ~= 0) we wind toward it. On
    -- RELEASE (target == 0) we do NOT immediately head to center — we FREEZE the angle for ReleaseHoldMs
    -- (the slide sustains at its current sideways angle), then wind back over RecenterMs. Any fresh steer
    -- input during the hold OR the recenter cancels it and takes over (you can re-commit mid-recovery).
    local rate
    if target ~= 0.0 then
        driftSteerRelAt = 0                                       -- actively steering: clear the release timer
        local winding = (target > 0.0) == (driftSteerCur >= 0.0)
        if winding then
            rate = inRate
            local es = cfg.OuterEaseStart or 0.55
            local ac = math.abs(driftSteerCur)
            if ac > es then
                local t = (ac - es) / math.max(0.001, 1.0 - es)  -- 0 at start -> 1 at full lock
                if t > 1.0 then t = 1.0 end
                local mn = cfg.OuterEaseMinMult or 0.45
                rate = rate * (1.0 - (1.0 - mn) * t)             -- glide into the stop
            end
        else
            rate = outRate                                       -- crossing center on a flick
        end
        rate = rate * spdMult
        local step = rate * dt
        if driftSteerCur < target then driftSteerCur = math.min(driftSteerCur + step, target)
        elseif driftSteerCur > target then driftSteerCur = math.max(driftSteerCur - step, target) end
    else
        -- RELEASED (keys neutral): hold, then recenter.
        if driftSteerRelAt == 0 then
            driftSteerRelAt   = nowMs                             -- mark release; capture the plateau
            driftSteerHoldFrom = math.abs(driftSteerCur)
        end
        local held = nowMs - driftSteerRelAt
        local holdMs = cfg.ReleaseHoldMs or 2400.0
        if held < holdMs then
            -- FREEZE: leave driftSteerCur exactly where it is (the slide holds its angle).
        else
            rate = outRate * spdMult                             -- wind back to center over RecenterMs
            local step = rate * dt
            if driftSteerCur > 0.0 then driftSteerCur = math.max(0.0, driftSteerCur - step)
            elseif driftSteerCur < 0.0 then driftSteerCur = math.min(0.0, driftSteerCur + step) end
        end
    end
    if driftSteerCur < -1.0 then driftSteerCur = -1.0 elseif driftSteerCur > 1.0 then driftSteerCur = 1.0 end

    -- SOFT CENTER: |x|^Gamma * sign desensitizes the dead-center band (gentle tilt near neutral),
    -- full lock unchanged. This is the "middle slower/smoother" the user asked for.
    local out = driftSteerCur
    local g = cfg.Gamma or 1.0
    if g ~= 1.0 then out = ((out < 0.0) and -1.0 or 1.0) * (math.abs(out) ^ g) end

    -- SOLE control-59 writer during drift (raw symmetric -1..1, 0 = center — same as the normal model).
    SetControlNormal(0, 59, out)
    HK._driftSteerActive = true
    HK._driftSteerOut = out
    HK.dbgDriftSteer = { cur = driftSteerCur, out = out, dir = dir, target = target,
                         spdMult = spdMult, rate = rate, at = GetGameTimer(),
                         relMs = (driftSteerRelAt > 0) and (nowMs - driftSteerRelAt) or 0,
                         holding = (driftSteerRelAt > 0 and (nowMs - driftSteerRelAt) < (cfg.ReleaseHoldMs or 2400.0)) }
end

-----------------------------------------------------------------
-- BRAKE PEDAL MODEL (2026-08-13) — device-agnostic effective brake.
-- The brake side of the same story: keyboard S is binary, so a keyboard driver can only slam 100%
-- brake and lock up — no threshold braking, no trail-braking into a corner. This synthesizes an
-- effective brake (state.effBrake) on the SAME shared pedal engine as throttle, with its OWN gamma
-- (brake wants finer control near the top of travel than throttle) and its own speed scaling
-- (high-speed = ramp in a touch slower so you can't instantly lock the fronts — threshold-brake feel).
-- The brake "pedal" is S ONLY when moving forward; when reversing S is the accelerator (owned by the
-- throttle model above), so we hold the brake pedal at 0 then to avoid double-counting S.
local bkPedal = newPedal()

-- Brake ONSET-CURVE state (see Config.Drivetrain.BrakeModel.OnsetCurve): a 0..1 ramp that eases the
-- brake FORCE in when you first press, softer/longer while steering. `ramp` is the raw 0..1 progress
-- (time-based), `lastVeh` resets it on a car swap.
local bkOnset = { ramp = 0.0, lastVeh = 0 }

function HK.BrakeModel_Tick(state, dt)
    if not HK.pedalModelOn then                    -- master toggle off = native brake, effBrake mirrors raw
        state.effBrake = state.brake or 0.0
        return
    end
    local cfg = Config.Drivetrain and Config.Drivetrain.BrakeModel
    if not cfg or cfg.Enabled == false then
        state.effBrake = state.brake or 0.0
        return
    end
    if state.vehicle ~= bkPedal.lastVeh then
        bkPedal.lastVeh = state.vehicle
        bkPedal.pos     = 0.0
    end

    -- Physical brake read (set on the snapshot by ThrottleModel_Tick's readPhysicalPedals, which runs
    -- first). keyboard = digital device; brakeRaw is the physical value (booleanized on keyboard).
    local keyboard   = HK._pedalInputKeyboard == true
    local brakeRaw   = HK._pedalBrake or (state.brake or 0.0)
    local brakePressed = HK._pedalBrakePressed == true

    -- S is ALWAYS the brake now (2026-08-14 rework) — reverse is a real gear driven by W, so S no
    -- longer doubles as the reverse-accelerator. Brake the physical S every frame regardless of
    -- gear/direction. (Reverse braking strength still flows through fBrakeForce below.)
    local raw = brakeRaw
    local pressed = brakePressed
    local analog = not keyboard
    local analogVal = raw
    local now = state.gameTimer or 0

    -- SPEED SCALE: at high speed, ramp brake in slightly SLOWER so a keyboard stab can't instantly lock
    -- the fronts — encourages threshold braking. Near 1.0 at low speed (park/creep braking stays crisp).
    local spdScale = tprLerpClamp(state.speedKmh or 0.0,
        cfg.SpeedRampLowKmh or 40.0, cfg.SpeedRampHighKmh or 160.0, cfg.SpeedRampLowMult or 1.0, cfg.SpeedRampHighMult or 0.75)

    local pc = {
        AnalogEpsilon = cfg.AnalogEpsilon, AnalogDetectMs = cfg.AnalogDetectMs, AnalogLowpassMs = cfg.AnalogLowpassMs,
        UpMs = cfg.SqueezeUpMs, DownMs = cfg.SqueezeDownMs, RiseFloorMult = cfg.RiseFloorMult, Gamma = cfg.Gamma,
        HoldDetectMs = cfg.HoldDetectMs, TapFastGapMs = cfg.TapFastGapMs, TapSlowGapMs = cfg.TapSlowGapMs,
        TapTargetFloor = cfg.TapTargetFloor, TapTargetCeil = cfg.TapTargetCeil, TapConvergeMs = cfg.TapConvergeMs,
        TapMemoryMs = cfg.TapMemoryMs,
    }
    state.effBrake = stepKeyPedal(bkPedal, pressed, analogVal, analog, dt, now, pc, spdScale)
    state.brakeIsAnalog = bkPedal.analog

    -- CONSUMER: translate the modeled pedal into actual brake force. GTA brakes at a strength set by
    -- fBrakeForce and gated by the raw control (binary on keyboard). Since a keyboard stab reads raw=1.0
    -- but the MODEL says effBrake<1.0 during the ramp, we scale fBrakeForce by (effBrake / raw) so the
    -- car brakes at the modeled fraction — graduated threshold braking instead of instant lockup. Analog
    -- devices already modulate natively, so only apply to synthesized (keyboard) input to avoid
    -- double-attenuating a real pedal. Composes onto HK.brakeForceMult (ABS multiplies its pulse on top).
    if not bkPedal.analog and raw > 0.01 and Config.Drivetrain.BrakeModel.ApplyForce ~= false then
        local ratio = state.effBrake / raw
        if ratio < 0.0 then ratio = 0.0 elseif ratio > 1.0 then ratio = 1.0 end
        HK.brakeForceMult = HK.brakeForceMult * ratio
    end

    -- ONSET CURVE: ease the brake FORCE in on a curve when you first press, softer + longer while
    -- steering — real drivers roll onto the pedal, especially trail-braking into a corner. Applies to
    -- ALL devices (analog + keyboard) since it scales HK.brakeForceMult, and is REDUCTION-only so full
    -- braking is always reached after the window (never caps peak force). Uses effBrake as the "pressed"
    -- signal so it tracks the modeled pedal, and resets quickly on release so the next stab re-arms.
    if cfg.OnsetCurve and Config.Drivetrain.BrakeModel.ApplyForce ~= false then
        if state.vehicle ~= bkOnset.lastVeh then
            bkOnset.lastVeh = state.vehicle
            bkOnset.ramp = 0.0
        end
        local eff = state.effBrake or 0.0
        if eff > 0.02 then
            -- steering makes the onset longer (more lock = more added time = gentler turn-in)
            local steerAbs = math.abs(state.steer or 0.0)
            if steerAbs > 1.0 then steerAbs = 1.0 end
            local onsetMs = (cfg.OnsetMs or 260.0) + (cfg.OnsetSteerExtraMs or 300.0) * steerAbs
            if onsetMs < 1.0 then onsetMs = 1.0 end
            bkOnset.ramp = bkOnset.ramp + (dt * 1000.0) / onsetMs
            if bkOnset.ramp > 1.0 then bkOnset.ramp = 1.0 end
        else
            -- released: bleed the ramp back down quickly so a fresh press starts from the floor again
            local relMs = cfg.OnsetReleaseMs or 120.0
            if relMs < 1.0 then relMs = 1.0 end
            bkOnset.ramp = bkOnset.ramp - (dt * 1000.0) / relMs
            if bkOnset.ramp < 0.0 then bkOnset.ramp = 0.0 end
        end
        -- shape the raw ramp into the force fraction: ease-in curve from a floor up to 1.0. The floor
        -- (initial bite) is lower when steering hard, so corner-entry braking starts gentler.
        local steerAbs = math.abs(state.steer or 0.0)
        if steerAbs > 1.0 then steerAbs = 1.0 end
        local floor = (cfg.OnsetFloor or 0.35)
                    + ((cfg.OnsetMinFloorAtLock or 0.22) - (cfg.OnsetFloor or 0.35)) * steerAbs
        local shaped = bkOnset.ramp ^ (cfg.OnsetGamma or 1.8)
        local frac = floor + (1.0 - floor) * shaped
        if frac < 0.0 then frac = 0.0 elseif frac > 1.0 then frac = 1.0 end
        if frac < 0.999 then
            HK.brakeForceMult = HK.brakeForceMult * frac
        end
    end
end

-- Notify: prefer qb-core / qbx_core if present, fall back to GTA native.
-- Resource state is checked at call time (notifications are infrequent and
-- user-triggered), so load order can't lock us into the wrong backend.
-- @param msg string   clean message text (no GTA color codes)
-- @param ntype string 'success' | 'error' | 'primary' (default 'primary')
local function notify(msg, ntype)
    ntype = ntype or 'primary'

    if GetResourceState('qb-core') == 'started' or GetResourceState('qbx_core') == 'started' then
        -- QBCore notify event (qbx_core supports the legacy event for compat)
        TriggerEvent('QBCore:Notify', msg, ntype)
        return
    end

    -- GTA native fallback: prepend a color hint based on the type
    local color = '~w~'
    if ntype == 'success' then color = '~g~'
    elseif ntype == 'error' then color = '~r~'
    elseif ntype == 'primary' then color = '~o~' end

    SetNotificationTextEntry('STRING')
    AddTextComponentString(color .. msg)
    DrawNotification(false, false)
end
HK.notify = notify   -- expose for sibling modules (blinker.lua etc.)

-----------------------------------------------------------------
-- KEYBINDS
-----------------------------------------------------------------

-- PEDAL MODEL MASTER TOGGLE — /pedalmodel [on|off]. Default OFF (native W/S drives). Live-flips the
-- whole throttle/brake synthesis + control injection so we can A/B test regressions (gear-stuck, drift).
RegisterCommand('pedalmodel', function(_, args)
    local a = (args and args[1] or ''):lower()
    if a == 'on' then HK.pedalModelOn = true
    elseif a == 'off' then HK.pedalModelOn = false
    else HK.pedalModelOn = not HK.pedalModelOn end
    local msg = 'Pedal model ' .. (HK.pedalModelOn and 'ON (synth + injection)' or 'OFF (native W/S)')
    print('[hk-pedalmodel] ' .. msg)
    notify(msg, HK.pedalModelOn and 'success' or 'primary')
end, false)

-- STEERING MODEL MASTER TOGGLE — /steermodel [on|off]. Default OFF (native A/D). Live-flips the
-- keyboard analog-steering synthesis + control-59 injection so it can be A/B tested independently.
RegisterCommand('steermodel', function(_, args)
    local a = (args and args[1] or ''):lower()
    if a == 'on' then HK.steerModelOn = true
    elseif a == 'off' then HK.steerModelOn = false
    else HK.steerModelOn = not HK.steerModelOn end
    local msg = 'Steering model ' .. (HK.steerModelOn and 'ON (keyboard synth)' or 'OFF (native A/D)')
    print('[hk-steermodel] ' .. msg)
    notify(msg, HK.steerModelOn and 'success' or 'primary')
end, false)

-- Drift mode — HOLD to drift (key down = on, key up = off)
RegisterCommand('+hk_drift', function()
    if HK.vehicle == 0 then return end
    if HK.driftMode then return end          -- already holding (key-repeat guard)
    -- BLOCK drift on NON-LAND vehicles (boat/heli/plane/train). smallboat has TractionCurveMax=0
    -- which divide-by-zeros the slip math, and drift is meaningless on water/air/rail anyway. Bikes/
    -- quads are land vehicles and stay allowed. Class ids: 14 boat, 15 heli, 16 plane, 21 train.
    local vclass = GetVehicleClass(HK.vehicle)
    if vclass == 14 or vclass == 15 or vclass == 16 or vclass == 21 then
        if Config.Drift.NotifyOnToggle then notify('Drift not available on this vehicle', 'error') end
        return
    end
    -- BLOCK drift on the COMFORT-AUTO daily box (PUBLIC mode 0, not EVs). Drift stays
    -- allowed on EVs/hybrids/manual/DCT/sequential. Gated on config (default on).
    if Config.Drift.BlockOnComfortAuto ~= false then
        local ok, isComfort = pcall(function() return exports['hk-handling']:IsComfortAuto(HK.vehicle) end)
        if ok and isComfort then
            if Config.Drift.NotifyOnToggle then notify('Drift not available on this vehicle', 'error') end
            return
        end
    end
    HK.driftMode = true
    DriftMode_Enable(HK.vehicle)
    if Config.Drift.NotifyOnToggle then notify('Drift mode', 'success') end
end, false)
RegisterCommand('-hk_drift', function()
    if not HK.driftMode then return end       -- wasn't active (e.g. pressed outside vehicle)
    HK.driftMode = false
    DriftMode_Disable(HK.vehicle)
    if Config.Drift.NotifyOnToggle then notify('Grip mode', 'primary') end
end, false)
RegisterKeyMapping('+hk_drift', 'Hold for Drift Mode', 'keyboard', Config.Keys.ToggleDrift)

-- Controlled wheelie (hold)
RegisterCommand('+hk_wheelie', function()
    HK.wheelieHeld = true
end, false)
RegisterCommand('-hk_wheelie', function()
    HK.wheelieHeld = false
end, false)
RegisterKeyMapping('+hk_wheelie', 'Hold for Controlled Wheelie', 'keyboard', Config.Keys.Wheelie)

-- /setwheelielaunch <0|1|clear> is now a SERVER command (server/gearbox.lua) with DB persistence —
-- it resolves the current vehicle's model via the same client round-trip as /setturbo and writes
-- hk_handling.wheelieLaunch, then syncs it into HK.manualModels[hash].wheelieLaunch for the gate in
-- wheelie.lua. (It used to be this client session-only table, which reset on restart — the reason a
-- set never "stuck".) HK.wheelieLaunchModels is kept only as a same-frame local fallback; nothing
-- writes it now, so it stays empty and the DB flag is authoritative.
HK.wheelieLaunchModels = HK.wheelieLaunchModels or {}

-----------------------------------------------------------------
-- MAIN LOOP
-----------------------------------------------------------------
CreateThread(function()
    -- Init TC mode from config
    HK.tcMode = Config.TractionControl.DefaultMode or 2

    while true do
        local sleep = 200

        if Config.Enabled then
            local veh = vl_getDrivenVehicle()

            if veh then
                sleep = 0
                HK.vehicle = veh
                HK.state = vl_getState(veh)
                local dt = HK.state.frameTime

                -- EFFECTIVE THROTTLE: synthesize a device-agnostic analog pedal (state.effThrottle) and
                -- rpmFactor onto the snapshot BEFORE any feature reads it. Single stateful owner (see
                -- HK.ThrottleModel_Tick). Every throttle-graduated feature should read state.effThrottle
                -- rather than the raw binary state.throttle so keyboard players get the full band too.
                -- pcall-ISOLATED (same guard as Payload_Tick): the pedal model is the NEWEST hot code and
                -- has twice thrown a fault that silently KILLED this whole thread — taking AWD/drift/
                -- gearbox down with it (that's why "AWD help vanished" kept recurring). A fault here must
                -- NEVER cascade: on error we fall back to raw pedals so the rest of the loop runs intact.
                local okThr, errThr = pcall(HK.ThrottleModel_Tick, HK.state, dt)
                if not okThr then
                    HK.state.effThrottle = HK.state.throttle or 0.0
                    HK.state.rpmFactor = 1.0
                    HK._injThrottle = 0.0; HK._injAnalog = true   -- analog flag = skip injection this frame
                    if not HK._throttleErr then
                        HK._throttleErr = true
                        print('[hk-handling] ThrottleModel_Tick error (raw fallback): ' .. tostring(errThr))
                    end
                end
                local okB, errB = pcall(HK.BrakeModel_Tick, HK.state, dt)
                if not okB then
                    HK.state.effBrake = HK.state.brake or 0.0
                    if not HK._brakeErr then
                        HK._brakeErr = true
                        print('[hk-handling] BrakeModel_Tick error (raw fallback): ' .. tostring(errB))
                    end
                end

                -- Reset torque multiplier each frame (systems reduce it)
                HK.torqueMult = 1.0
                HK.brakeForceMult = 1.0   -- brake model + ABS compose onto this, applied once below
                HK.launchT = 0.0
                HK.gbLimiterOn = false    -- gearbox limiter sets this true when cutting throttle (see applyRevLimiter);
                HK.gbLimiterByCap = false -- ...and this true only on the speed-cap path; reset both here so a frame
                                          -- where Gearbox_Tick doesn't run can't leave them latched
                HK.turboThrottleMult = 1.0 -- turbo pedal-lag scalar; Turbo_Tick sets it (<1 = choked). Reset here so
                                          -- a frame where the turbo tick doesn't run can't leave the pedal choked.

                -- AIRBORNE FORCE CUTOFF: track how long the car has been FULLY off the ground. Past
                -- Config.AirborneForceCutMs we set HK.airForceCut so the pushy physics ticks below
                -- stand down (see the guarded dispatch) — mid-air, any force we add just shoves the
                -- car sideways (no tyres to react against). Resets to 0 the instant it lands.
                -- MUST use IsEntityInAir (WHOLE car off the ground), NOT onAllWheels==false: a WHEELIE
                -- lifts the FRONT wheels so onAllWheels is false the entire time the nose is up — using
                -- that fired the cut mid-wheelie, killing the lift torque → nose dropped → wheels
                -- touched → cut released → torque returned = the rear-end JITTER. IsEntityInAir stays
                -- false during a wheelie (rear wheels planted), so the wheelie runs clean; it only goes
                -- true when the car genuinely leaves the ground (a jump), which is what this guard is for.
                if IsEntityInAir(veh) then
                    HK.airborneMs = (HK.airborneMs or 0.0) + (dt * 1000.0)
                else
                    HK.airborneMs = 0.0
                end
                HK.airForceCut = (Config.AirborneForceCutEnabled ~= false)
                                 and (HK.airborneMs >= (Config.AirborneForceCutMs or 600))

                -- DISABLE PHYSICAL HANDBRAKE: must run EVERY frame BEFORE game input processing
                -- so spacebar doesn't engage brake during drift mode. v7.11: also disable if the
                -- drift KEY is held (even if +hk_drift hasn't fired yet) to prevent the race where
                -- pressing space BEFORE drift-key activates the native handbrake before we can block it.
                -- IsDisabledControlPressed checks the RAW key state (CAPS = control 137 in FiveM).
                -- 2026-08-14 CONTROLLER FIX: control 137 (INPUT_VEH_PUSHBIKE_SPRINT) is CAPSLOCK on
                -- keyboard but the A BUTTON on a controller — the SAME physical button as the handbrake
                -- (control 76). So on a pad, pressing handbrake read as "drift key held" and this line
                -- disabled the handbrake — it defeated itself, and the controller handbrake stopped
                -- working. The raw-key pre-check only ever mattered for the KEYBOARD race (Space before
                -- CAPS registers), so gate it to keyboard input only. IsInputDisabled(2) = true when the
                -- last input was keyboard/mouse, false on a gamepad. On a pad we fall back to HK.driftMode
                -- (the actual state), which is the correct, race-free behaviour there.
                local driftKeyHeld = IsInputDisabled(2) and IsDisabledControlPressed(0, 137)  -- CAPS, keyboard only
                if HK.driftMode or driftKeyHeld then
                    DisableControlAction(0, 76, true)
                end

                -- === RUN SYSTEMS (order matters: TC/ESC reduce torque, drift modifies handling) ===

                -- Drift mode — reassert per-frame native knobs while held.
                -- After release, the exit-recovery window (yaw damp + grip ramp)
                -- runs until it closes itself — see DriftMode_RecoveryTick.
                -- Drift ticks PUSH the car (yaw couple + lateral velocity) — skip while the airborne
                -- cutoff is active so a sustained-air car isn't shoved sideways by drift forces.
                if Config.Drift.Enabled and not HK.airForceCut then
                    if HK.driftMode then
                        DriftMode_Tick(veh, HK.state, dt)
                    elseif DriftMode_RecoveryActive and DriftMode_RecoveryActive() then
                        DriftMode_RecoveryTick(veh, HK.state, dt)
                    end
                end

                -- S-KEY-AS-WHEELSPIN brake kill (2026-08-14): during drift, when driftkey+W+S is held
                -- on an eligible car, DriftMode_Tick sets HK.driftNoBrakeSpin so the footbrake doesn't
                -- BLEED the speed/rpm the wheelspin (and the wheelie off it) needs. GTA's brake force
                -- from a physically-held S flows through control 72; DISABLE it this frame so S stops
                -- braking (our pedal reads use IsRawKeyDown so W+S DETECTION still works — see readPhysicalPedals).
                if HK.driftNoBrakeSpin then
                    DisableControlAction(0, 72, true)
                end

                -- DRIFT BRAKE LIGHT (2026-09-06): same family as the reverse / neutral / standstill lamps.
                -- The lamp should light whenever S is held in drift — INCLUDING while driftNoBrakeSpin has
                -- killed control 72 (native light follows 72, so it'd go dark exactly when the wheelspin
                -- is on). Drive it DIRECTLY off the physical S key (HK._pedalBrake, immune to Disable*),
                -- so "S input = brake light" regardless of whether S is actually braking this frame. It's a
                -- per-frame override (not a latch) so it must be reasserted every frame S is down; when S
                -- releases we hand control back to native by writing false once. Keyboard-agnostic (works
                -- on pad too since _pedalBrake is device-agnostic).
                if HK.driftMode and SetVehicleBrakeLights and veh and veh ~= 0 then
                    SetVehicleBrakeLights(veh, (HK._pedalBrake or 0.0) > 0.05)
                end

                -- Manual gearbox — shift machine (field set disjoint from drift)
                if Config.Gearbox.Enabled and HK.manualActive then
                    Gearbox_Tick(veh, HK.state, dt)
                end

                -- APPLY the modeled throttle to the control AFTER the gearbox — so its throttle-kill
                -- states (reverse-gate / launch / force-upshift, all via DisableControlAction 71/72)
                -- have already run and win cleanly, and our write can't be left latched from a prior
                -- frame. Writes every frame (0 included) so a released key drops to zero immediately.
                -- pcall-isolated for the same reason as the model ticks (must never kill the loop).
                pcall(HK.ThrottleModel_Apply)

                -- REVERSE SPEED CAP + SLOW RAMP — governs backward SPEED directly (not control 72, which
                -- doesn't drive reverse thrust here). Only acts when physically moving BACKWARD, so a
                -- forward slide + S can't trip it. Ramps a ceiling up to MaxKmh then clamps to it.
                pcall(HK.ReverseCap_Tick, HK.state, dt)

                -- FULL VELOCITY-DRIVEN REVERSE (keyboard/pedal-model in a reverse gear): W accelerates
                -- backward, S brakes, neither coasts — driven directly by SetEntityVelocity because
                -- control 72 can't be shared with the physical S key. No-op unless HK.inReverseGear and
                -- injecting; analog/off keeps native reverse (capped by ReverseCap_Tick above).
                pcall(HK.ReverseDrive_Tick, HK.state, dt)

                -- ROLL / CREEP base layer (forward + neutral). Low-speed crawl: idle creep in gear, free
                -- roll in neutral, slope roll on any grade, brake-scaled. Runs after reverse (which owns
                -- its own roll) and self-skips while a spin gesture / drift owns low-speed motion. Feeds
                -- wheelspin's "roll forward at the end". pcall-isolated (SetEntityVelocity on a live handle).
                if HK.RollCreep_Tick then pcall(HK.RollCreep_Tick, HK.state, dt) end

                -- AUTO-BLINKER (steering-driven turn signals). LAlt arms it (single arm control — reverse
                -- does NOT auto-arm). No-op when disarmed. pcall-isolated (light native calls).
                if HK.Blinker_Tick then pcall(HK.Blinker_Tick, veh, HK.state, dt) end

                -- Traction Control
                if Config.TractionControl.Enabled and HK.tcMode > 0 and not HK.tcOff then
                    TractionControl_Tick(veh, HK.state, dt)
                else
                    HK.tcFactor = 0.0   -- player-off / disabled: no lingering cut
                end

                -- Stability Control (ESC) — skip if drift mode active. pcall-isolated like
                -- every physics tick in this loop: a throw here (e.g. on a dying vehicle
                -- handle) must not kill the whole thread and take the gearbox down with it.
                if Config.ESC.Enabled and not (Config.ESC.DisableInDriftMode and HK.driftMode) then
                    local okE, errE = pcall(ESC_Tick, veh, HK.state, dt)
                    if not okE and not HK._escErr then
                        HK._escErr = true
                        print('[hk-handling] ESC_Tick error (stability control disabled): ' .. tostring(errE))
                    end
                end

                -- [A3] Launch Control — REPLACED. The old generic LaunchControl_Tick (client/
                -- launch.lua, throttle+brake staging on any car) is retired. ECU launch control
                -- now lives IN the gearbox (client/gearbox.lua), gated to DCT-auto / EV / hybrid-EV
                -- and driven off our gear-ratio rpm projection + the neutral state machine.

                -- [A4] Rev Limiter (cuts torque at redline)
                if Config.RevLimiter.Enabled then
                    RevLimiter_Tick(veh, HK.state, dt)
                end

                -- [B*] Burnout / gear-1 rev limiter. Owns the redline bounce in GEAR 1
                -- (the gearbox limiter skips gear 1); Stage 2/3 add the drift-mode burnout
                -- + wheelie charge. Cuts HK.torqueMult, so runs BEFORE vl_setTorque below.
                -- pcall-isolated (NEW file): a fault must never take down the main loop.
                -- REVERSE GEAR: none of the forward W+S gestures apply. In a reverse gear controls
                -- 71/72 are disabled and motion is driven by ReverseDrive_Tick (SetEntityVelocity).
                -- The burnout/free-rev/wheelspin ticks force-spin wheels + add a forward creep force,
                -- which in reverse fights the velocity model and makes the car buck/nose-lift ("goes
                -- crazy bumping up and down"). Skip the whole block while HK.inReverseGear.
                if Config.Burnout and Config.Burnout.Enabled and Burnout_Tick and not HK.inReverseGear then
                    -- "disabled for safety" must mean ACTUALLY skip the tick, not just mute the print:
                    -- a tick that sets HK.torqueMult=0 (plant the car) and THEN throws leaves torque
                    -- stranded at 0 = "rpm moves but car won't move" until the gesture disengages. So
                    -- gate on the error flag so a faulting tick never runs (and never strands torque) again.
                    if not HK._burnoutErr then
                        local okBo, errBo = pcall(Burnout_Tick, veh, HK.state, dt)
                        if not okBo then
                            HK._burnoutErr = true
                            print('[hk-handling] Burnout_Tick error (disabled for safety): ' .. tostring(errBo))
                        end
                    end
                    -- STEP 1: PLAIN W+S FREE-REV (no drift). Plants the car + fast rev to redline
                    -- bounce. Runs first; if it OWNS the frame the wheelspin tick is skipped (they're
                    -- mutually exclusive — free-rev = NO drift key, wheelspin = drift key held).
                    -- THREE-STATE REV MODEL: moved to the gearbox (HK.RevAgainstThrottle_Tick — the
                    -- engine side). It reads the box's own neutral/clutch/mode signals (published at
                    -- the top of Gearbox_Tick) and is the LAST rpm writer of the frame, exactly where
                    -- the old burnout free-rev ran. Sets HK.freeRevActive when it owns the frame.
                    local freeReving = false
                    if HK.RevAgainstThrottle_Tick and not HK._burnoutFrErr then
                        local okFr, resFr = pcall(HK.RevAgainstThrottle_Tick, veh, HK.state, dt)
                        if okFr then
                            freeReving = resFr == true
                        else
                            HK._burnoutFrErr = true
                            HK.torqueMult = 1.0   -- undo any torque-kill a half-run tick left stranded
                            print('[hk-handling] RevAgainstThrottle_Tick error (disabled for safety): ' .. tostring(resFr))
                        end
                    end
                    -- STAGE 2: burnout wheelspin (drift + W + S) — pumps torque surplus + builds
                    -- HK.launchCharge. Runs after the limiter, before vl_setTorque. Skipped while the
                    -- plain W+S free-rev owns the frame. The free-rev tick MOVED into the gearbox
                    -- (RevAgainstThrottle_Tick, runs inside Gearbox_Tick above) — it sets
                    -- HK.freeRevActive, so read THAT for the mutual-exclusion gate here (the local
                    -- freeReving is now always false since the burnout.lua stub is disabled).
                    local freeRevOwns = freeReving or (HK.freeRevActive == true)
                    if Burnout_WheelspinTick and not freeRevOwns then
                        local okBw, errBw = pcall(Burnout_WheelspinTick, veh, HK.state, dt)
                        if not okBw and not HK._burnoutWsErr then
                            HK._burnoutWsErr = true
                            print('[hk-handling] Burnout_WheelspinTick error (disabled for safety): ' .. tostring(errBw))
                        end
                    elseif freeRevOwns and HK.burnoutActive then
                        HK.burnoutActive = false   -- free-rev owns the frame; ensure wheelspin flag is clear
                    end
                end

                -- [B3] LAUNCH TRACTION — auto-wheelspin off the line (gears 1-2). Cuts HK.torqueMult so it
                -- runs BEFORE vl_setTorque, and AFTER the burnout block so it sees HK.burnoutActive fresh
                -- (mutually exclusive — the manual drift-key wheelspin owns the frame if the player's doing
                -- it). Skipped in reverse (no forward launch). pcall-isolated like its siblings.
                if Config.LaunchTraction and Config.LaunchTraction.Enabled and LaunchTraction_Tick
                   and not HK.inReverseGear then
                    if not HK._launchTrErr then
                        local okLt, errLt = pcall(LaunchTraction_Tick, veh, HK.state, dt)
                        if not okLt then
                            HK._launchTrErr = true
                            -- DIAGNOSTIC (2026-08-16): keep the ACTUAL error so /handlingdbg can show WHY the
                            -- launch drag "just went" — a print scrolls off and is easy to miss. This is the
                            -- smoking gun for the repeated mid-session fault we've never actually seen.
                            HK.dbgLaunchErr = { msg = tostring(errLt), n = (HK.dbgLaunchErr and HK.dbgLaunchErr.n or 0) + 1,
                                                at = GetGameTimer() }
                            print('[hk-handling] LaunchTraction_Tick error (disabled for safety): ' .. tostring(errLt))
                        end
                    end
                end

                -- [W1] Passenger Weight — accel debuff by passenger count (torque
                -- only; never touches top speed). Last torque consumer before apply.
                -- pcall-isolated: a fault in this newest module must NEVER take down
                -- the main loop (which would silently revert the gearbox to native
                -- GTA behaviour). Guard on the fn existing too in case it failed load.
                if Config.Payload and Config.Payload.Enabled and Payload_Tick then
                    local ok, err = pcall(Payload_Tick, veh, HK.state, dt)
                    if not ok and not HK._payloadErr then
                        HK._payloadErr = true
                        print('[hk-handling] Payload_Tick error (disabled for safety): ' .. tostring(err))
                    end
                end

                -- DRIFT TORQUE CEILING (2026-08-13): while drifting, cap drive torque a hair below
                -- native (default 92%) so the SCRIPT never commands 100% drive during a slide — there's
                -- always native headroom, and on exit the car settles onto native forces instead of us
                -- handing back from a boosted state. Philosophy lever ("let native physics carry more"),
                -- NOT a cut you feel — the slide still breathes. Stacks under any TC/ESC cut (min wins).
                if HK.driftMode and Config.Drift.TorqueCeiling and Config.Drift.TorqueCeiling < 1.0 then
                    if HK.torqueMult > Config.Drift.TorqueCeiling then
                        HK.torqueMult = Config.Drift.TorqueCeiling
                    end
                end

                -- WHEELIE DRIVE COMPENSATION (2026-08-14): during a launch wheelie the FRONT wheels are
                -- off the ground, and GTA delivers less drive on two contact patches (its vehicles are
                -- never true RWD) — so a wheelie car actually accelerates SLOWER while the nose is up. Add
                -- back a torque boost for the duration the wheelie is active so it pulls away instead of
                -- bogging. Applied LAST (after all cuts) so it's a clean top-up; scales with how high the
                -- nose is (HK.dbgWheelie.f, the lift factor) so it fades in/out with the lift, not a step.
                -- Gated on Config.Wheelie.DriveCompEnabled; DriveCompMult is the peak multiplier at full lift.
                if HK.wheelieActive and Config.Wheelie and Config.Wheelie.DriveCompEnabled ~= false then
                    -- FRONT-WHEELS-OFF TORQUE (2026-08-14, user: "stronger speed and torque during the
                    -- time the FRONT WHEEL is NOT touching ground"). While the actual front wheels are up
                    -- (HK.wheelieFrontOff, measured in wheelie.lua) apply the firm FrontOffTorque surge —
                    -- on two contact patches GTA delivers less drive, so this keeps it pulling HARD at the
                    -- pinned redline. When the front is DOWN (nose still settling) fall back to the gentler
                    -- pitch-scaled DriveComp so the top-up fades out smoothly with the nose.
                    if HK.wheelieFrontOff == true then
                        HK.torqueMult = HK.torqueMult * (Config.Wheelie.FrontOffTorque or 1.45)
                    else
                        local liftF = HK.wheelieLiftF or 1.0
                        if liftF < 0.0 then liftF = 0.0 elseif liftF > 1.0 then liftF = 1.0 end
                        local comp = 1.0 + ((Config.Wheelie.DriveCompMult or 1.35) - 1.0) * liftF
                        HK.torqueMult = HK.torqueMult * comp
                    end
                end

                -- BRAKE OVERRIDE (2026-08-14) — full throttle + brake should SLOW the car. On a real car the
                -- brakes are sized to arrest the whole car's energy, so they comfortably overpower engine
                -- drive torque; modern ECUs even enforce this in software (a "brake override system" cuts
                -- throttle when both pedals are pressed, mandated after the unintended-acceleration recalls).
                -- Our limiter already prioritised the brake AT the rev limit, but mid-range W+S left full
                -- drive torque fighting the brakes so the car wouldn't slow. Cut drive torque by the brake
                -- amount here so the brakes win everywhere. GATED to genuine forward motion (speedKmh above
                -- BrakeOverrideMinKmh) so the standstill W+S gestures — burnout / free-rev / launch staging,
                -- all at ~0 km/h — keep their footbrake-against-throttle hold untouched. Reverse is its own
                -- velocity model (S already brakes there), so skip it. Physical S key = reliable read.
                -- EXCLUDE the intentional W+S gestures: the wheelspin burnout (drift key + W + S, sustains
                -- to ~55 km/h) and the plain free-rev — both are DELIBERATE throttle-against-brake combos
                -- that must NOT be torque-cut. driftMode also owns its own handling. Everything else with
                -- W+S at speed is a driver trying to slow with the brakes = override applies.
                local boCfg = Config.BrakeOverride
                local gestureLive = HK.burnoutActive or HK.freeRevActive or HK.driftMode
                if boCfg and boCfg.Enabled ~= false and not HK.inReverseGear and not gestureLive then
                    local sKey = HK._pedalBrake or 0.0
                    local wKey = HK._pedalThrottle or 0.0
                    local kmh  = (HK.state and HK.state.speedKmh) or 0.0
                    if sKey >= (boCfg.MinBrake or 0.15) and wKey >= (boCfg.MinThrottle or 0.15)
                       and kmh >= (boCfg.MinKmh or 8.0) then
                        -- Scale the cut with brake pressure: light brush trims a little, full slam cuts to
                        -- MaxCut (default 0 = full fuel-cut, brakes fully win). Linear in brake fraction.
                        local maxCut = boCfg.MaxCut or 0.0
                        local cut = 1.0 - (1.0 - maxCut) * sKey
                        if cut < 0.0 then cut = 0.0 elseif cut > 1.0 then cut = 1.0 end
                        if cut < HK.torqueMult then HK.torqueMult = cut end
                    end
                end

                -- Apply combined torque multiplier (TC/ESC/limiter cut, launch boosts)
                vl_setTorque(veh, HK.torqueMult)
                HK.torqueMultApplied = HK.torqueMult    -- final value this frame (diagnostics read this,
                                                        -- since HK.torqueMult resets to 1.0 next frame top)

                -- DRIFT BRAKE-TORQUE SPIN RPM PIN — LAST rpm writer of the frame. drift.lua
                -- (DriftMode_Tick, runs before the gearbox) captured the peak rpm reached under
                -- the brake-torque load + set HK.driftSpinRpm when the brake released with
                -- throttle still on. The gearbox is the rpm owner and painted its own value
                -- already; paint the pin AFTER it so the needle holds at the spin peak instead
                -- of bogging. Cosmetic (vl_setRpmRaw = zero drive force) — the sustain of the
                -- spin itself is the grip work that comes next. pcall-isolated (live handle).
                if HK.driftSpinRpm and veh and veh ~= 0 then
                    pcall(vl_setRpmRaw, veh, HK.driftSpinRpm)
                end

                -- WHEELIE RPM-MAX-WHILE-LIFTED PIN — same LAST-writer paint as the drift spin pin above.
                -- wheelie.lua (Wheelie_Tick, runs after the gearbox) sets HK.wheelieSpinRpm while the nose
                -- is genuinely up so the needle holds at redline through the lift ("MAX RPM WHEN LIFTED
                -- UP"), then clears it the instant the nose drops. Safe on autos because wheelie.lua also
                -- sets HK.wheelieHoldGear so the gearbox won't phantom-upshift on the painted rpm. Cosmetic
                -- (vl_setRpmRaw = zero drive force); DriveComp above supplies the real pull. pcall-isolated.
                if HK.wheelieSpinRpm and veh and veh ~= 0 then
                    pcall(vl_setRpmRaw, veh, HK.wheelieSpinRpm)
                end

                -- Drivetrain-aware base handling (RWD assist / AWD understeer / FWD)
                -- — not in drift mode (drift owns handling then).
                -- GUARDED: Drivetrain_Tick is a NEW file (client/drivetrain.lua, renamed from
                -- awd.lua). A client that hasn't reconnected since the rename still has the old
                -- file cached, so the global may be nil there — an unguarded call throws every
                -- frame and KILLS the whole tick thread (drift + regen + everything). The fn-exists
                -- guard means a stale client just skips drivetrain handling until they reconnect,
                -- instead of losing all vehicle dynamics. See the new-files-need-reconnect gotcha.
                -- AWD EXIT-RAMP GATE (2026-08-13 v7.22): during the drift exit-recovery window HK.driftMode
                -- is already false, so without this the AWD drivetrain branch (understeer/power-save/
                -- governor — all write fDriveBiasFront) would run the SAME frame as the recovery tick's
                -- smooth ramp of that field and clobber it every frame = the AWD exit snap. RWD never
                -- touches drive bias, which is why only AWD exit was rough. Skip Drivetrain_Tick while the
                -- ramp owns the field; the window restores native on close, so the next tick recaptures
                -- correctly. Only true for AWD cars mid-exit-window (fn-guarded for stale clients).
                -- Also skip while the airborne cutoff is active: Drivetrain_Tick's per-wheel brakers /
                -- lift-rotation PUSH the chassis, and they already instant-release at takeoff (0ms), so by
                -- the 600ms cut they're released — skipping now just keeps them from re-engaging mid-air.
                local awdRamping = DriftMode_AwdBiasRamping and DriftMode_AwdBiasRamping()
                if Config.Drivetrain and Config.Drivetrain.Enabled and Drivetrain_Tick
                   and not HK.driftMode and not awdRamping and not HK.airForceCut then
                    -- pcall-isolated: Drivetrain_Tick is where the AWD/RWD cornering help lives and it
                    -- reads state fields the pedal model now rewrites — if it ever throws, the thread
                    -- dies HERE (after taphold already ran), giving the exact "taphold works but AWD
                    -- gone" signature. Guard it and surface the error so an AWD-logic fault is visible
                    -- instead of silently killing every system after it (ABS/diff/downforce too).
                    local okD, errD = pcall(Drivetrain_Tick, veh, HK.state, dt)
                    if not okD and not HK._drivetrainErr then
                        HK._drivetrainErr = true
                        print('[hk-handling] Drivetrain_Tick error (AWD/RWD help disabled): ' .. tostring(errD))
                    end
                end

                -- ABS (modifies brake force per-frame) — skip in drift mode
                -- (the diff sim owns per-wheel braking then; stacking risks lockup)
                if Config.ABS.Enabled and not HK.driftMode and not HK.absOff then
                    ABS_Tick(veh, HK.state, dt)
                end

                -- ABS-OFF RESPONSE — the mirror of ABS: runs ONLY when the player has ABS switched off.
                -- Locking the wheels kills front-steering (plow), lengthens the stop slightly, and lets a
                -- rear-dominant lock rotate the tail (emergent). Publishes HK.absOffBrakeMult (composed onto
                -- brakeForceMult just below) + resists yaw via the flip-proof path. Skip in drift (diff owns
                -- braking). pcall-isolated like the other physics ticks — a throw here must not kill the loop.
                if Config.ABSOff and Config.ABSOff.Enabled and not HK.driftMode and HK.absOff and ABSOff_Tick then
                    local okAO, errAO = pcall(ABSOff_Tick, veh, HK.state, dt)
                    if okAO then
                        local aom = HK.absOffBrakeMult or 1.0
                        if aom < 0.999 then HK.brakeForceMult = (HK.brakeForceMult or 1.0) * aom end
                    elseif not HK._absOffErr then
                        HK._absOffErr = true
                        print('[hk-handling] ABSOff_Tick error (ABS-off feel disabled): ' .. tostring(errAO))
                    end
                else
                    HK.absOffBrakeMult = 1.0
                end

                -- BRAKE-FORCE BUFF (2026-08-14) — Config.BrakeBoost. Compute the reward buff (chip/antilag/
                -- gearbox-type/native-brake-mod all-time + high-speed curve) and COMPOSE it onto the same
                -- brakeForceMult the model + ABS use. This is a MULTIPLY: a reduction (ABS/model < 1.0) and
                -- a buff (> 1.0) stack correctly (e.g. 0.9 pulse on a 1.3 buffed car = 1.17). Runs outside
                -- drift mode (the diff owns braking there) so buffs don't fight the per-wheel sim.
                if not HK.driftMode and HK.BrakeBuff_Tick then
                    local okBB = pcall(HK.BrakeBuff_Tick, veh, HK.state)
                    if okBB and HK.brakeBuffMult and HK.brakeBuffMult ~= 1.0 then
                        HK.brakeForceMult = (HK.brakeForceMult or 1.0) * HK.brakeBuffMult
                    end
                end

                -- LOW-SPEED BRAKE SOFTENER (2026-08-16) — GTA's fBrakeForce is a CONSTANT decel independent of
                -- speed, so the same force that stops the car from 100 also SLAMS it to a halt at crawl (it
                -- drops below the RollCreep pin band in a blink = the "instant stop / first 35 km/h gone /
                -- sudden stop at low speed" report). Real brakes ease off near a stop. Gradually WEAKEN brake
                -- force below LowSpeedBrakeKmh (35): full strength at/above 35, fading to LowSpeedBrakeMin
                -- (0.60 = 40% weaker) as speed → 0. Composes onto brakeForceMult (REDUCTION-only, stacks with
                -- ABS/model/buff). Skips drift (diff owns braking). Not the handbrake (fHandBrakeForce).
                if not HK.driftMode and Config.LowSpeedBrake and Config.LowSpeedBrake.Enabled ~= false then
                    local lsbKmh = Config.LowSpeedBrake.Kmh or 35.0
                    local kmhNow = math.abs(HK.state and HK.state.speedKmh or 0.0)
                    if kmhNow < lsbKmh then
                        local minM = Config.LowSpeedBrake.Min or 0.60
                        local f = kmhNow / math.max(lsbKmh, 1e-3)          -- 0 at stop → 1 at 35
                        local soft = minM + (1.0 - minM) * f               -- minM at stop → 1.0 at 35
                        HK.brakeForceMult = (HK.brakeForceMult or 1.0) * soft
                    end
                end

                -- APPLY COMPOSED BRAKE FORCE. The brake model (keyboard threshold-braking scale), ABS
                -- (lockup pulse) and the brake-force BUFF all multiplied onto HK.brakeForceMult; apply the
                -- product to fBrakeForce ONCE. scaleHandling sets from the ORIGINAL each frame, so we only
                -- touch the field when the mult is non-unity — EITHER a reduction (< 0.999) OR a buff
                -- (> 1.001) — and restore it the frame it returns to 1.0 (so native braking is byte-exact
                -- when nothing's intervening). Skip in drift mode (diff owns per-wheel braking).
                if not HK.driftMode then
                    local bfm = HK.brakeForceMult or 1.0
                    if bfm < 0.999 or bfm > 1.001 then
                        vl_scaleHandling(veh, 'fBrakeForce', bfm)
                        HK._brakeForceScaled = true
                    elseif HK._brakeForceScaled then
                        vl_restoreField(veh, 'fBrakeForce')
                        HK._brakeForceScaled = false
                    end
                elseif HK._brakeForceScaled then
                    vl_restoreField(veh, 'fBrakeForce')
                    HK._brakeForceScaled = false
                end

                -- STEERING MODEL (2026-08-14) — keyboard analog-steer synthesis, NORMAL mode only.
                -- Writes control 59 (single writer; drift owns the wheel via SetVehicleSteeringAngle so
                -- we skip it there). pcall-isolated like the pedal ticks so a throw can't kill the loop.
                -- Runs BEFORE the range cut below: this shapes the -1..1 INPUT; that scales max ANGLE.
                if not HK.driftMode then
                    if HK._driftSteerActive then HK._driftSteerActive = false end  -- left drift: hand 59 back
                    local okSt, errSt = pcall(HK.SteeringModel_Tick, HK.state, dt)
                    if not okSt then
                        HK._steerModelActive = false
                        if not HK._steerModelErr then
                            HK._steerModelErr = true
                            print('[hk-handling] SteeringModel_Tick error (native A/D fallback): ' .. tostring(errSt))
                        end
                    end
                else
                    if HK._steerModelActive then
                        HK._steerModelActive = false   -- entering drift: stop the normal model claiming 59
                    end
                    -- DRIFT STEERING SHAPER (2026-09-06): smooth the A/D input in drift so the front angle
                    -- eases in (soft center + smooth outer) instead of the raw binary snap. CounterSteer
                    -- still writes SetVehicleSteeringAngle on top when a slide is committed. pcall-isolated
                    -- like the other model ticks so a throw falls back to native A/D, never kills the loop.
                    local okDs, errDs = pcall(HK.DriftSteering_Tick, HK.state, dt)
                    if not okDs then
                        HK._driftSteerActive = false
                        if not HK._driftSteerErr then
                            HK._driftSteerErr = true
                            print('[hk-handling] DriftSteering_Tick error (native A/D fallback): ' .. tostring(errDs))
                        end
                    end
                end

                -- GLOBAL STEERING RANGE CUT (2026-08-13) — normal mode only.
                -- Config.SteerRangeMult trims the max wheel-lock (fSteeringLock) so the
                -- left-right range is tighter in all modes. Drift mode folds the same
                -- factor into its own lock scale (see drift.lua), so we SKIP it here to
                -- avoid double-scaling / fighting drift's write. scaleHandling always
                -- scales off the captured native value, so this is idempotent per frame;
                -- we restore the field the moment the factor is unity (byte-exact native).
                if not HK.driftMode then
                    -- SPEED-GRADUATED lock: at low speed boost the multiplier toward LowMult (tight-corner
                    -- agility — you're off-throttle there so more angle is safe), easing to the flat
                    -- SteerRangeMult baseline by HighKmh. One scaleHandling write either way.
                    local base = Config.SteerRangeMult or 1.0
                    local srm  = base
                    local ls = Config.SteerRangeLowSpeed
                    if ls and ls.Enabled ~= false then
                        local spd  = HK.state.speedKmh or 0.0
                        local high = ls.HighKmh or 145.0
                        if spd <= high then
                            -- low-speed boost: LowMult (crawl) linearly down to baseline by HighKmh
                            srm = tprLerpClamp(spd, ls.LowKmh or 20.0, high, ls.LowMult or base, base)
                        else
                            -- high-speed taper: baseline -> TopMult by TopKmh, smoothstep-eased so it
                            -- tightens gently and keeps slowing the closer you get to top speed.
                            local top    = ls.TopKmh or 450.0
                            local topM   = ls.TopMult or base
                            local t = (spd - high) / (top - high)
                            if t < 0 then t = 0 elseif t > 1 then t = 1 end
                            t = t * t * (3.0 - 2.0 * t)   -- smoothstep
                            srm = base + (topM - base) * t
                        end
                    end
                    HK.dbgSteerMult = srm   -- overlay readout
                    if srm < 0.999 or srm > 1.001 then
                        vl_scaleHandling(veh, 'fSteeringLock', srm)
                        HK._steerRangeScaled = true
                    elseif HK._steerRangeScaled then
                        vl_restoreField(veh, 'fSteeringLock')
                        HK._steerRangeScaled = false
                    end
                elseif HK._steerRangeScaled then
                    -- Entering drift: hand fSteeringLock back to drift's own scaling.
                    HK._steerRangeScaled = false
                end

                -- [X6] Differential sim (brake-based torque vectoring).
                -- Runs after torque blend; engages locked preset in drift,
                -- gentle LSD always-on if configured. Self-gates internally.
                if Config.Diff.Enabled then
                    Diff_Tick(veh, HK.state, dt)
                end

                -- Downforce. pcall-ISOLATED (like Drivetrain/pedal ticks): this applies
                -- physics force and a fault here MUST NEVER kill the loop — an unguarded
                -- throw on a dying/stale handle previously took the whole main thread
                -- (and the gearbox tick above it) down with it → "No such entity" spam.
                if Config.Downforce.Enabled and Downforce_Tick then
                    local okDF, errDF = pcall(Downforce_Tick, veh, HK.state, dt)
                    if not okDF and not HK._dfErrOnce then
                        HK._dfErrOnce = true
                        print('[hk-handling] Downforce_Tick error (downforce disabled this run): ' .. tostring(errDF))
                    end
                end

                -- DRS / Active Aero (pcall-isolated for the same reason). Skip while airborne-cut:
                -- it scales drag/force and there's no aero to manage on a car sitting in the air.
                if Config.DRS.Enabled and DRS_Tick and not HK.airForceCut then
                    pcall(DRS_Tick, veh, HK.state, dt)
                end

                -- [F1] Controlled Wheelie (pitch-couple, hold key). pcall-isolated — this
                -- applies forces on the raw handle, so a throw on a dying vehicle must not
                -- kill the loop (and the pitch couple is the rebuilt net-zero-force path).
                -- NO airForceCut GUARD (2026-08-26): the wheelie PITCHES THE NOSE UP, which makes
                -- IsEntityInAir read true, which fired the cut mid-lift → killed the torque → nose
                -- dropped → wheels touched → torque returned = the REAR-END JITTER. The wheelie is a
                -- standing-launch effect (<120 km/h, ~1.5s window) so you're never jumping when it
                -- runs, and it self-limits internally (grounded gate + pitchFade). The video-era
                -- wheelie had no airborne guard at all — this restores that. The cut still applies to
                -- drift/drivetrain/DRS above, where a real ramp jump is the actual hazard.
                if Config.Wheelie.Enabled then
                    local okW, errW = pcall(Wheelie_Tick, veh, HK.state, dt)
                    if not okW and not HK._wheelieErr then
                        HK._wheelieErr = true
                        print('[hk-handling] Wheelie_Tick error (controlled wheelie disabled): ' .. tostring(errW))
                    end
                end

                -- [F2] Drag Launch Headlift (automatic pitch-couple). pcall-isolated too.
                -- Skip while airborne-cut (same reason as the wheelie above).
                if Config.Headlift.Enabled and not HK.airForceCut then
                    local okH, errH = pcall(Headlift_Tick, veh, HK.state, dt)
                    if not okH and not HK._headliftErr then
                        HK._headliftErr = true
                        print('[hk-handling] Headlift_Tick error (drag headlift disabled): ' .. tostring(errH))
                    end
                end

                -- [F3] Wheelie/Handbrake bug guard — co-applies foot brake when the
                -- handbrake is pulled with the nose up in low gear, defusing the native
                -- velocity-dump bug. Self-gates internally; runs last so it sees the
                -- final input state for this frame.
                if Config.WheelieGuard and Config.WheelieGuard.Enabled and WheelieGuard_Tick then
                    WheelieGuard_Tick(veh, HK.state, dt)
                end

                -- GRIP-FIELD ARBITER COMMIT (2026-08-16). MUST run AFTER every feature tick that claims the
                -- shared grip fields (launch-traction, burnout, TC-off GripDrop in Drivetrain_Tick, LC bump
                -- in the gearbox tick) — it resolves the highest-priority claim and writes the three fields
                -- ONCE, or restores them when nobody claims. Single writer = no restore race. pcall-isolated
                -- so a throw here can't kill the loop; the catch-all vl_restoreHandling on exit still cleans up.
                if HK.gripCommit then pcall(HK.gripCommit, veh) end

            else
                -- Left vehicle: clean up
                if HK.vehicle ~= 0 then
                    if HK.driftMode then
                        DriftMode_Disable(HK.vehicle)
                        HK.driftMode = false
                    end

                    -- === CRIT-3: clear ALL module + shared state on vehicle change ===
                    -- Guarded calls so this is safe no matter which modules are
                    -- loaded/enabled. Prevents phantom intervention on the first
                    -- frame in the next vehicle.
                    HK.launching   = false
                    HK.launchT     = 0.0
                    HK.wheelieHeld = false
                    HK.tcFactor    = 0.0
                    HK.escFactor   = 0.0
                    HK.escActive   = false
                    if DriftMode_Reset then DriftMode_Reset() end
                    if Drivetrain_Reset then Drivetrain_Reset() end
                    if ESC_Reset       then ESC_Reset(HK.vehicle)     end
                    if Downforce_Reset then Downforce_Reset(HK.vehicle) end
                    if DRS_Reset       then DRS_Reset(HK.vehicle)     end
                    if Wheelie_Reset   then Wheelie_Reset()           end
                    if Burnout_Reset   then Burnout_Reset()           end
                    if LaunchTraction_Reset then LaunchTraction_Reset() end
                    if HK.gripArbiterReset then HK.gripArbiterReset(HK.vehicle) end   -- drop grip claims + restore
                    -- CLEAR THE PER-TICK ERROR LATCHES on vehicle exit. These latch true on the FIRST fault
                    -- and (previously) were NEVER reset — so a single TRANSIENT error (an entity handle that
                    -- briefly went invalid as another player's vehicle streamed in, a collision mid-launch,
                    -- being yanked from the seat) pinned that feature OFF for the rest of the session. That
                    -- was the "launch drag just disappears after a while and never comes back" report. Clearing
                    -- them here means re-entering ANY vehicle re-arms the feature, so a one-frame glitch
                    -- self-heals instead of killing the gesture permanently.
                    HK._launchTrErr  = false
                    HK._burnoutErr   = false
                    HK._burnoutWsErr = false
                    HK._burnoutFrErr = false
                    HK._payloadErr   = false
                    if Diff_Release   then Diff_Release(HK.vehicle) end
                    if Diff_Reset     then Diff_Reset()     end
                    if Gearbox_Disable then Gearbox_Disable(HK.vehicle) end
                    if Gearbox_Reset   then Gearbox_Reset()   end
                    if Payload_Reset   then Payload_Reset()   end
                    if HK.Blinker_Reset then HK.Blinker_Reset(HK.vehicle) end

                    -- Restore any modified handling (catch-all)
                    vl_restoreHandling(HK.vehicle)
                    HK.vehicle = 0
                    HK.state = nil
                end
            end
        end

        Wait(sleep)
    end
end)

-- ── hk-race integration: read-only SpeedCalData lookup ──────────────────────
-- SpeedCalData is keyed by SPAWN CODE (e.g. "chiron"). A vehicle entity gives us a
-- model HASH, and GetDisplayNameFromVehicleModel returns a LABEL (not the spawn
-- code) so string lookups miss. We build a hash->entry index once (GetHashKey of
-- each spawn code) and accept either a hash (number) or a spawn-code string.
-- Row fields: n, t60, t100, t160, t200, top (km/h). Consumed by hk-race tiers.
local _speedCalByHash
local function _buildSpeedCalIndex()
    _speedCalByHash = {}
    if not (HK and HK.SpeedCalData) then return end
    for spawn, entry in pairs(HK.SpeedCalData) do
        _speedCalByHash[GetHashKey(spawn) & 0xFFFFFFFF] = entry
    end
end
exports("getSpeedCal", function(key)
    if not (HK and HK.SpeedCalData) or key == nil then return nil end
    if type(key) == "number" then
        if not _speedCalByHash then _buildSpeedCalIndex() end
        return _speedCalByHash[math.floor(key) & 0xFFFFFFFF]
    end
    -- string spawn code
    return HK.SpeedCalData[tostring(key):lower()]
end)

-- Drift mode state export (read by hk-racecam)
exports("GetDriftMode", function()
    return HK and HK.driftMode == true
end)
