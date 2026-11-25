-----------------------------------------------------------------
-- hk-handling :: client/gearbox.lua
-- [B*] Manual gearbox — original HOMEKONG implementation.
--
-- STEP 3 scope: detection + enable/disable + statebag + event bridge ONLY.
-- No per-frame shift/clutch/stall logic yet (that's steps 4-5). This step
-- proves activation fires cleanly from jim-mechanic and on flagged cars.
--
-- Integration contract (matches the events jim-mechanic already triggers, so
-- jim needs NO edits): jim enters a car -> 'vlad_gears:entered_listener'; if the
-- car has the manual upgrade (VehicleStatus.manual==1) -> 'vlad_gears:activate'.
-- We listen on those exact names (they are jim's external API — not our code).
-- We also expose our own 'hk-handling:gearbox:*' aliases and exports.
--
-- Field ownership (vs drift): gearbox OWNS fInitialDriveForce + RPM + throttle
-- controls + gear/engine/reduced-ratio. Drift owns grip/suspension. Disjoint.
-----------------------------------------------------------------

local vehlib = exports['hk-vehlib']
local function bind(fn) return function(...) return fn(nil, ...) end end

-- Export refs cached ONCE at load. Each `exports['hk-vehlib'].fn` access allocates
-- a fresh wrapper closure in the CFX runtime (scheduler.lua:717), so calling
-- `vl_fn()` per frame churns the GC every frame — the real per-frame cost in
-- this hot tick, not the math. We resolve each wrapper once here. The wrapper is
-- `function(self, ...)` and discards self, so `bind` forwards with a nil self slot
-- (tail call, no extra frame) and call sites stay clean: vl_setHandling(veh, f, v).
local vl_applyForce                   = bind(vehlib.applyForce)
local vl_brakeWheel                   = bind(vehlib.brakeWheel)
local vl_computeShiftTimeMs           = bind(vehlib.computeShiftTimeMs)
local vl_detectWheelspin              = bind(vehlib.detectWheelspin)   -- (veh,thresh)->spinning,worstDiff(m/s) = launch slip sensor
local vl_getCurrentGear               = bind(vehlib.getCurrentGear)
local vl_getDrivetrainOrigins         = bind(vehlib.getDrivetrainOrigins)
local vl_getDrivetrainLayout          = bind(vehlib.getDrivetrainLayout)
local vl_getHighGear                  = bind(vehlib.getHighGear)
local vl_getModModifier               = bind(vehlib.getModModifier)
local vl_getThrottleOffset            = bind(vehlib.getThrottleOffset)
local vl_getVehicleMod                = bind(vehlib.getVehicleMod)
local vl_hasJimMechanic               = bind(vehlib.hasJimMechanic)
-- vl_isManualVehicle (handling-flag detection) removed — no longer consulted;
-- resolution is DB row + car-class default only. See resolvePublicType.
local vl_isRightHandDrive             = bind(vehlib.isRightHandDrive)
local vl_jimIsManual                  = bind(vehlib.jimIsManual)
local vl_notify                       = bind(vehlib.notify)
local vl_setCurrentGear_raw           = bind(vehlib.setCurrentGear)
local vl_setHandling                  = bind(vehlib.setHandling)
local vl_setMaxLaunchRevs             = bind(vehlib.setMaxLaunchRevs)
local vl_setMinTimeBetweenGearShifts  = bind(vehlib.setMinTimeBetweenGearShifts)
local vl_setRpmRaw_raw                = bind(vehlib.setRpmRaw)
-- Reduced-gear-ratio setter that also RECORDS the intended value on HK, so the watchdog (top of
-- Gearbox_Tick, after the suspend gate) can re-assert it if it drifts OFF when it should be ON.
-- Fix for "car won't move, revs ramp slow, then 500km/h in one tall gear" = reduced-ratio stuck
-- OFF (native tall gears) when the normal-learner + muscle-handbrake guard collide on the shared
-- gbSuspended flag and a resume is missed. Assigned to an EXISTING-style single local (no extra
-- local — main chunk is at Lua's 200-local limit); HK.reducedRatioWant = last value asked for.
local vl_setTransmissionReducedGearRatio
do
    local raw = bind(vehlib.setTransmissionReducedGearRatio)
    vl_setTransmissionReducedGearRatio = function(veh, on)
        if HK then HK.reducedRatioWant = on and true or false end
        raw(veh, on)
    end
end

-----------------------------------------------------------------
-- [F3] MUSCLE HANDBRAKE BUG GUARD (throttle-gated)
-- On muscle (class 4) the box can blow the car up (snap-to-0 + 180 flip) when the
-- handbrake is held in gear 1/2. You only grab the e-brake when OFF the gas, so the
-- danger is simply: class 4 + gear 1/2 + handbrake + throttle released. While that
-- holds we behave exactly like native [6] (proven immune); back on the gas resumes.
--
-- Two layers, both gated by gbSuspended:
--   1. engineWritesSuspended makes the per-frame vl_setCurrentGear / vl_setRpmRaw
--      calls no-ops (wrapped below — catches all ~30 call sites at once).
--   2. gbSuspended ALSO turns off the transmission enabler
--      (SetVehicleTransmissionReducedGearRatio false) once on entry and makes
--      Gearbox_Tick return early — i.e. the full [6] stand-down, not just the
--      writes. On resume we re-assert the mode's transmission state.
-- Transitions live in the guard block at the top of Gearbox_Tick.
-----------------------------------------------------------------
-- GEARBOX MODE helpers. Read Config.Gearbox.Mode at call time (live).
--   easy   = simple box, no RPM writes, no ratio/jim/expert cal
--   normal = full box + background 0-100 open-loop learner
--   expert = legacy SpeedCal / setspeed / accelcal / autocal system
local function gearboxMode()
    local m = Config.Gearbox and Config.Gearbox.Mode or 'normal'
    m = tostring(m):lower()
    if m ~= 'easy' and m ~= 'normal' and m ~= 'expert' then return 'normal' end
    return m
end
local function isEasy()   return gearboxMode() == 'easy'   end
local function isNormal() return gearboxMode() == 'normal' end
local function isExpert() return gearboxMode() == 'expert' end

local engineWritesSuspended = false        -- layer 1: per-write no-op (set by the guard)
local gbSuspended           = false        -- master: box is mimicking [6] right now
local function vl_setCurrentGear(veh, g)
    if engineWritesSuspended then return end
    return vl_setCurrentGear_raw(veh, g)
end
local function vl_setRpmRaw(veh, r)
    if engineWritesSuspended or isEasy() then return end
    return vl_setRpmRaw_raw(veh, r)
end

HK = HK or {}  -- ensure the table exists before we hang rampedDipMult on it (full init ~line 204)
-----------------------------------------------------------------
-- AREA-NEUTRAL RAMPED DIP (shared TC-feel shape). A flat torque dip
-- `HK.torqueMult *= flatPower` held for the whole window loses torque
-- proportional to (1 - flatPower) * window. This returns an INSTANTANEOUS
-- multiplier for a SMOOTH swell (1.0 -> floor -> 1.0) whose time-integral
-- over the window equals that same flat loss -- so net torque-over-time
-- (and therefore 0-100) is IDENTICAL, only the FEEL changes from a step to
-- a breathing swell. tau = elapsed/window in [0,1].
--   shape 'tri'    : triangular bump, average 0.5  -> floor deepened /0.5
--   shape 'smooth' : sin(pi*tau) bump, average 2/pi -> floor deepened /(2/pi)
-- The instantaneous depth is capped so the multiplier never goes below 0.
function HK.rampedDipMult(flatPower, tau, shape)
    if tau <= 0 or tau >= 1 then return 1.0 end
    local flatDepth = 1.0 - (flatPower or 1.0)
    if flatDepth <= 0 then return 1.0 end
    local bump, avg
    if shape == 'tri' then
        bump = 1.0 - math.abs(2.0 * tau - 1.0)   -- 0 ->1 ->0 linear
        avg  = 0.5
    else
        bump = math.sin(math.pi * tau)           -- 0 ->1 ->0 smooth (default)
        avg  = 0.6366197723675814                -- 2/pi
    end
    local depth = (flatDepth / avg) * bump       -- area-matched instantaneous depth
    local m = 1.0 - depth
    if m < 0.0 then m = 0.0 end
    return m
end

-----------------------------------------------------------------
-- [/setspeed] SPEED CALIBRATION — packed PER-GEAR torque curve.
-- The four packed slots are GEARS 1 / 2 / 3 / 4+ (NOT speed bands). The trim is
-- picked by the car's ACTUAL current gear, so each factor only ever acts inside
-- that gear's GTA ratio — no speed-band cross-talk, and a correction to one gear
-- can't disturb another. Packed into one BIGINT: leading-1 sentinel + 4x 4-digit
-- groups (factor*100). 0100 = x1.00 no-op. Pure torque (HK.torqueMult *= factor) —
-- never rpm/gear. Pack format is UNCHANGED from the old band scheme (no re-SQL).
local SPC_SENTINEL = 10000000000000000   -- 1e16: leading "1" so groups keep their zeros

-- Unpack a stored BIGINT into {g1,g2,g3,g4} (or nil if absent/invalid).
local function speedCalUnpack(packed)
    packed = math.tointeger(tonumber(packed or 0)) or 0
    if packed < SPC_SENTINEL then return nil end
    packed = packed - SPC_SENTINEL
    local g1 = (packed // 1000000000000) % 10000
    local g2 = (packed // 100000000) % 10000
    local g3 = (packed // 10000) % 10000
    local g4 = packed % 10000
    return { g1 / 100.0, g2 / 100.0, g3 / 100.0, g4 / 100.0 }
end

-- Pack {g1,g2,g3,g4} -> BIGINT (each factor clamped to 4 digits).
local function speedCalPack(f)
    local function g(x)
        local v = math.floor((x or 1.0) * 100 + 0.5)
        if v < 0 then v = 0 elseif v > 9999 then v = 9999 end
        return v
    end
    return SPC_SENTINEL + g(f[1]) * 1000000000000 + g(f[2]) * 100000000 + g(f[3]) * 10000 + g(f[4])
end

-- Per-gear factor: slot = current gear clamped to 1..4 (slot 4 = gear 4 and above).
-- This is the whole point of the per-gear model — the trim is anchored to the gear
-- GTA is actually in, so it follows the default gear ratios exactly.
local function speedCalFactorForGear(factors, gear)
    if not factors then return 1.0 end
    local g = gear or 1
    if g < 1 then g = 1 elseif g > 4 then g = 4 end
    return factors[g] or 1.0
end

-- Cumulative target time (seconds) to REACH speed v (km/h), interpolated from the
-- real-life target points {[kmh]=s} (0 km/h = 0 s implied). Piecewise-linear; clamps
-- below the lowest point, extrapolates past the highest at its last segment's rate.
-- Used by the per-gear convergence: a gear's expected time = targetTime(vOut) -
-- targetTime(vIn), so each gear is judged on the SAME speed range it actually covered.
local function speedCalTargetTimeAt(tgt, v)
    local pts = { { 0, 0.0 } }
    for k, t in pairs(tgt) do pts[#pts + 1] = { k, t } end
    if #pts < 2 then return nil end
    table.sort(pts, function(a, b) return a[1] < b[1] end)
    if v <= pts[1][1] then return pts[1][2] end
    for i = 2, #pts do
        if v <= pts[i][1] then
            local a, b = pts[i - 1], pts[i]
            local span = b[1] - a[1]
            if span <= 0 then return b[2] end
            return a[2] + (b[2] - a[2]) * ((v - a[1]) / span)
        end
    end
    local b, a = pts[#pts], pts[#pts - 1]
    local span = b[1] - a[1]
    if span <= 0 then return b[2] end
    return b[2] + (v - b[1]) * ((b[2] - a[2]) / span)
end

-- Expose pack/unpack + the target-time helper to the auto-cal module (autocal.lua)
-- without duplicating the math. These are stable, pure functions.
HK = HK or {}
HK.speedCalPack = speedCalPack
HK.speedCalUnpack = speedCalUnpack
HK.speedCalTargetTimeAt = speedCalTargetTimeAt

-- NOTE: the old OPEN-LOOP formula (speedCalEstNativeTime / speedCalCompute) was
-- REMOVED. It guessed a factor from handling.meta and pushed the wrong way on fast
-- cars (Chiron/R8 came out faster than real). The new model is NEUTRAL-SEED: /setspeed
-- stores only the TARGET, the factor starts NULL (= the tuner's handling.meta baseline),
-- and auto-cal (autocal.lua) / /accelcal LEARN the factor from real measured pulls.


-----------------------------------------------------------------
HK = HK or {}
HK.manualModels = HK.manualModels or {}   -- model hash -> {type, paddle, ratio}; DB preset list

-- LIVE REGEN SIGNAL for hk-speedo. `applyRegen` writes these each frame it acts; the
-- EV/hybrid tick zeroes `level` when regen is not applying. hk-speedo reads them via the
-- GetRegenLevel export (pull model, same as GetDisplayGear/GetGearboxMode) to drive the
-- regen side of its EV power meter. level 0..1 = intensity, holding = at the stop-hold.
HK.evRegen = HK.evRegen or { level = 0.0, mode = 'onepedal', holding = false, active = false }
HK.semiBoost = HK.semiBoost or 0.0   -- semi-hybrid live e-boost fraction 0..1 (speedo charge arc)
HK.speedoStyle = HK.speedoStyle or nil  -- resolved per-vehicle: 'full' | 'semi' — CLUSTER LOOK
                                        -- (decoupled from behaviour class; a class-1 PHEV can be 'semi')
HK.autoShiftDipStart = HK.autoShiftDipStart or 0  -- ms the current comfort shift dip began (area-neutral ramp)
HK.tcSlipCur = HK.tcSlipCur or 0.0           -- TC (mode 3) elastic rpm slip-flare, painted amount (0..1 rpm)
HK.dctKickStart = HK.dctKickStart or 0       -- post-upshift kick pulse start (GetGameTimer ms)
HK.dctKickUntil = HK.dctKickUntil or 0       -- post-upshift kick pulse end
HK.dctKickAmp = HK.dctKickAmp or 0.0         -- kick amplitude latched at the upshift (throttle-gated mode 3)
HK.dctKickMs = HK.dctKickMs or 80            -- kick pulse duration latched at the upshift
HK.coastUpSteps = HK.coastUpSteps or 0       -- gears climbed during the CURRENT lift-off (0 when on-throttle)
HK.gbAirSettleUntil = HK.gbAirSettleUntil or 0  -- ms after landing during which auto-upshift stays blocked
                                                -- (free-spun airborne rpm is stale until the wheels regrip)
HK.regenLightOn = HK.regenLightOn or false   -- regen brake-light hysteresis latch (see setRegenBrakeLight)
HK.regenRamp = HK.regenRamp or 0.0           -- 0..1 regen attack ramp (spools up on lift so decel eases in
                                             -- from 0 -> target; the light delay comes from this crossing OnMs2)
-- LAUNCH CONTROL shared state (read by hk-speedo / future status box via GetLaunchState +
-- the hk_drivestate bag). phase: 'off'|'staged'|'launched'; active = staged or launched.
HK.launch = HK.launch or { active = false, phase = 'off', rpm = 0.0 }
-- Clean per-frame signals for the hk-speedo LC pill's PRE-STAGE looks (grey idle / red-pulse
-- prep). inNeutral = launchStageTick ran this frame (car is in a launch-capable neutral, so
-- launch is possible right now); hb = handbrake held (the robust read). Both reset to false
-- at the top of every Gearbox_Tick so they're NEVER sticky (unlike the dbg* diagnostics).
HK.launch.inNeutral = false
HK.launch.hb = false
HK.launchStagedOnHb = HK.launchStagedOnHb or false  -- did the current stage arm on the handbrake
                                                    -- (vs footbrake)? Decides the manual fire rule.
-- PER-MODEL LEARNED LAUNCH-RPM TRIM (0..1 additive offset, keyed by modelKey). The gear-1-ratio
-- estimate in computeLaunchRpm can't know a car's GRIP or power delivery, so the same computed
-- rpm makes one car hook (P1) and another spin/bog (M4 G82) = LC slower than no-LC on some cars.
-- We close the loop with the telemetry harness already in place: after each measured pull we nudge
-- this trim from the peak wheel-slip vs TC.TargetSlip (spun past target -> lower rpm; never reached
-- it / TC never had to cut -> raise). Converges each model onto its own fastest hook. Session-only
-- (rebuilt from live measurement); persistence can layer on later via KVP if wanted.
HK.launchRpmTrim = HK.launchRpmTrim or {}

local applied        = false   -- reduced-gear-ratio + origins currently applied?
local toggled        = false   -- jim/command requested manual (the stateful trigger)
local gbLiveUpgrade  = false   -- set by onActivate: re-enable mid-session, skip neutral start
local flagged        = false   -- resolved as "process this car" (DB row / car-class default)
local processGearbox = false   -- final: are we running the box for this car?
local curVeh         = 0
local origins        = nil     -- vl_getDrivetrainOrigins snapshot (our own restore source)
local rhd            = false
local netEnt         = nil     -- Entity(veh) for statebag

-- Shift machine (step 4)
local started        = false   -- one-time gear-1 init done for this car
local enteredMoving  = false   -- car was already ROLLING (>6 km/h) when we entered (skip start-in-neutral)
local gearMode       = 1       -- 1 = manual w/ clutch, 2 = comfort automatic
local gearcount      = 1       -- GetVehicleHighGear (UNMODIFIED — keep upgrade's extra gear)
local targetGear     = 1       -- LOGICAL gear: -1=R, 0=N, 1..gearcount fwd
local shifting       = false   -- mid-shift window
local shiftEndAt     = 0       -- GetGameTimer() ms when the current shift completes
local shiftTimeUp    = 200     -- ms, derived from clutch rate at enable
local shiftTimeDown  = 200
local reqUp          = false   -- keybind set these (consumed by tick)
local reqDown        = false
local pendUpAt       = 0       -- GetGameTimer() ms a lone ShiftUp press is waiting out the chord window (0=none)
local pendDownAt     = 0       -- same for ShiftDown
local upTapAt        = 0       -- last ShiftUp press time; upTapPrev = the one before (for the x2 neutral gesture)
local upTapPrev      = 0
local downTapAt      = 0       -- last ShiftDown press time
local downTapPrev    = 0
local upHeld         = false   -- ShiftUp key physically held (persistent, for both-key neutral)
local downHeld       = false   -- ShiftDown key physically held
local bothHoldStart  = 0       -- GetGameTimer() ms both keys first became held (0 = not)
local reqNeutralTap  = false   -- set when BOTH shift keys are pressed SIMULTANEOUSLY (chord); the
                               -- AUTOMATIC branches consume it as a neutral TOGGLE. Manuals use hold-both.
local neutralGate    = false   -- after a both-hold neutral: block shifts until BOTH keys released
local manualNeutralHold = false -- manual: current neutral came from the temporary both-hold gesture
local preNeutralGear = 1       -- manual: gear to restore when leaving a temporary neutral
local clutchHeld     = false   -- clutch key currently held
local shiftPowerMult = 1.0     -- active post-shift power multiplier (boost/bog)
local shiftPowerUntil= 0       -- GetGameTimer() ms the multiplier holds until
local shiftWasClutchless = false -- the in-flight shift was started without the clutch (rev-match judged)
local missShiftUntil = 0       -- GetGameTimer() ms a FAILED clutchless shift sits in neutral before engaging
local missShiftGear  = 1       -- the gear to engage when the failed-shift neutral window ends
-- Mode 2 comfort-automatic state
local autoMinSet     = false   -- have we asserted the anti-hunt min-shift-time?
local autoNextShiftOk= 0       -- GetGameTimer() ms before the next early-upshift nudge
local autoShiftDipUntil = 0    -- GetGameTimer() ms the smooth-shift torque dip lasts
local autoLastGear   = -99     -- last seen gear (to detect GTA's own shifts)
-- HK.autoShiftDipStart: ms the current comfort dip BEGAN (area-neutral ramp). On HK.*
-- not a local — gearbox.lua is at the 200 main-chunk local ceiling.
local autoFastShift  = false   -- does this car shift fast enough to early-upshift?
local autoNeutral    = false   -- mode 0 / EV: hold-both momentary coast active (drive cut, free-rev)
local isEV           = false   -- resolved at Enable: single-gear electric (drive gears <= 1)
-- Pure-EV regen LEVEL (D1/D2/D3 ladder + Coast). 0 = Coast (glide, no regen), 1 = D1
-- (mild ~0.10g), 2 = D2 (~0.15g), 3 = D3 (strong one-pedal ~0.21g + stop-hold). LSHIFT
-- tap -> Coast (express reset); ShiftUp/Down (K/J) step the level. Set at Enable.
local evRegenLevel   = 3       -- default D3 (strongest); DefaultLevel config overrides at Enable
local evClutchPrev   = false   -- edge-detect for the LSHIFT->Coast reset key on a pure EV
local regenCornerMult = 1.0    -- smoothed cornering-reduction factor for regen (1=full, <1=faded in a turn)
local isHybrid       = false   -- resolved at Enable: PHEV with a full-electric mode (config model list)
local hybridEMode    = false   -- hybrid CURRENTLY in electric mode (auto-transitions to ICE past cap/kickdown)
local hybridEModePrev= false   -- last frame's hybridEMode (edge-detect the e-mode<->ICE handoff)
local eGearPinned    = false   -- e-mode single-gear pin (reduced-ratio ON + gear 1) currently engaged
local eReducedRatioOff = false -- latch: reduced-gear-ratio has been forced OFF for the current e-mode run
local hybridUserMode = 'ev'    -- driver-selected: 'ev'|'normal' (HOLD-G toggles). 'ev' prefers
                               -- electric + EV sound but still hands to ICE at the cap (SF90 handoff).
local hybridCap      = 130.0   -- resolved per-model e-mode cap (km/h) — set at Enable from ModelProfiles
local hybridPowerFrac= 0.25    -- resolved per-model e-mode power fraction — set at Enable
local evMass         = 1500.0  -- cached fMass for the regen decel-force calc (F = m·a); read at Enable
local gbRawShiftMs   = 200     -- handling.meta-derived up-shift time (computeShiftTimeMs); DCT absorbs this
local gbTopKmh       = 0       -- cached estimated top speed (km/h); lug-floor fade scales to this
local clutchReadyAt  = 0       -- GetGameTimer() ms; clutch sim gated until this (warmup)
local shiftFromGear  = 1       -- gear the in-flight shift started FROM (seq up/down rev-match split)
local shiftStartRpm  = 0       -- raw rpm captured at the instant the shift was requested (seq grading
                               -- uses THIS, not window-end rpm which the rev-drop assist pulls down)
local _ratioProbeAt  = 0       -- TEMP: throttle for the ratio-probe debug print
local _emodeDbgAt    = 0       -- TEMP: throttle for the e-mode debug print
-- Mode 3 DCT state
local dctManual      = false   -- DCT sub-mode: false = semi-auto, true = paddle-manual
local dctNeutral     = false   -- DCT paddle: currently in neutral (free-rev, no drive)
local dctNeutralHold = false   -- DCT neutral entered via HOLD-both (temporary; exits when keys released)
local dctHoldNArmed  = true    -- hold-both-N can arm only after BOTH keys have been released since
                               -- the last hold-N — stops a lingering-held key (after a shift out of N)
                               -- from instantly re-entering neutral (the 'N carries over after shift' bug)
local dctPreNeutGear = 1       -- DCT: gear to re-engage when a temporary hold-neutral releases
local dctNeutralFromAuto = false -- DCT hold-neutral was entered from AUTO sub-mode -> return to auto on release
local dctLatchedNeutral = false -- DELIBERATE neutral (double-tap gesture): STAYS until paddle/shift; throttle only revs, never auto-engages
local dctReverse     = false   -- DCT paddle: currently in reverse (native gear 0 + reverse input)
-- REVERSE GATE (EV + DCT-auto): brake to 0 -> NEUTRAL (free-roll), stays until you either
-- press throttle (-> forward) OR release-then-press the brake again (-> reverse). Prevents a
-- held brake at a stop from rolling straight into reverse. State: 'none'|'neutral'|'reverse'.
-- Full sequence (D = 'none' forward):
--   moving fwd + hold S -> stop -> NEUTRAL (free-roll) -> release S + press S -> REVERSE
--   REVERSE -> tap/hold W -> NEUTRAL -> W again (or held W after a dwell) -> D (gear 1)
local revGate         = 'none'
local revBrakeArmed   = false  -- brake released since entering neutral (so R needs a FRESH press)
local revThrArmed     = false  -- throttle released since a gate step (so each fwd step needs a fresh press,
                               -- EXCEPT a held W auto-walks R->N->D via revWalkAt)
local revWalkAt       = 0      -- GetGameTimer() ms: when a held-W auto-walk may take its next step
                               -- (gives the speedo a beat to show N between R and 1)
local revWasMoving    = false  -- have we been ABOVE the stop threshold since last in 'none'? Brake-to-
                               -- neutral only fires after real forward motion (not while parked holding
                               -- brake — else a tap-out-of-neutral would instantly snap back to N).
-- NOTE: dctNeutralRatioOff (reduced-ratio-off-in-neutral safety flag) lives on the HK table,
-- NOT a new top-level local — the main chunk is at Lua's 200-local limit.
local revNFromReverse = false  -- did we reach 'neutral' FROM reverse? If so, a throttle press needs the
                               -- release-then-press re-arm (R->N->D walk). If we reached N from a FORWARD
                               -- brake-stop, throttle drives off IMMEDIATELY (no re-arm) — else low-speed
                               -- stop-and-go creep sticks between N and 1 (the "stuck N<->1" bug).
local dctAutoNextOk  = 0       -- GetGameTimer() ms before the next AUTO-sub-mode shift (anti-hunt dwell)
local dctGear        = 1       -- player-selected gear in DCT manual sub-mode
local dctStarted     = false   -- DCT one-time init done
local dctLastGear    = -99     -- last seen gear (detect shifts for the smooth dip)
local dctShiftDipUntil = 0     -- smooth-shift torque dip window
local dctBoostUntil  = 0       -- redline-upshift boost window
-- TC slip-flare + post-upshift kick state live on HK.* (not file locals) — gearbox.lua
-- is AT the 200 local-variable ceiling, so new per-frame state goes on the HK table.
--   HK.tcSlipCur    TC (mode 3) elastic rpm slip-flare, current painted amount (0..1 rpm)
--   HK.dctKickStart / HK.dctKickUntil   post-upshift kick pulse window (GetGameTimer ms)
--   HK.dctKickAmp   amplitude latched at the upshift (throttle-gated for mode 3)
--   HK.dctKickMs    pulse duration latched at the upshift
local dctOverrevUntil= 0       -- over-rev penalty dip window
local dctOverrevReturn= 1      -- gear to snap back UP to after the penalty
local dctBeepAt      = 0       -- debounce for the double-beep
-- ECU LAUNCH CONTROL (DCT-auto / EV / hybrid-EV only). State machine that runs inside the
-- NEUTRAL state of those modes: neutral + handbrake + full throttle = STAGED (hold the
-- computed launch rpm); release handbrake (throttle still down) = LAUNCH (engage gear 1 +
-- brief fading torque surge). Manuals never use this (they get perfect-shift boosts).
local lcPhase        = 'off'   -- 'off' | 'staged' | 'launched'
-- WHEELSPIN-NEUTRAL LAUNCH (2026-08-14 v3): the launch fires through the normal launchStageTick path
-- for EVERY box now — AUTO, MANUAL and SEQUENTIAL all fire on a handbrake release with throttle floored
-- (manual/seq previously fired only on an upshift; that + the old bespoke fire block caused the auto
-- double-fire and the manual stuck-in-gear-1). No custom per-frame fire state here anymore.
local lcLaunchAt     = 0       -- GetGameTimer() ms the launch (release) fired — boost taper origin
local lcTargetRpm    = 0.9     -- computed per-car staged launch rpm (0..1), resolved at stage time
-- LAUNCH TELEMETRY (measurement harness — tune boost/grip/slip against REAL data, don't predict).
-- Captures the last launch's 0-100 km/h time, peak longitudinal g, and peak wheel-slip (m/s
-- gap between wheel & ground speed). lcTele.run tracks the in-progress launch; lcTele.last holds
-- the completed result for the HUD/export. Reset per launch fire; frozen when 100 km/h reached.
local lcTele = {
    active   = false,          -- a measured pull is in progress
    startMs  = 0,              -- GetGameTimer() at launch fire (t0 for 0-100)
    prevKmh  = 0.0,            -- last frame speed (for finite-diff accel)
    peakG    = 0.0,            -- peak longitudinal g seen this pull
    peakSlip = 0.0,            -- peak wheelspin worstDiff (m/s) this pull
    peakTcCut= 0.0,            -- peak TC torque-cut (0..1) this pull — how hard the slip governor had to work
    t100     = 0.0,            -- measured 0-100 km/h time (s); 0 until reached
    last     = nil,            -- { t100, peakG, peakSlip, profile } of the most recent completed pull
}
local lcBailSince = 0          -- GetGameTimer() the throttle first dipped below the bail point while
                               -- staged (0 = not dipping). Grace window so a momentary CONTROLLER
                               -- trigger wobble doesn't silently cancel a stage. Reset on stage exit.
-- LC traction-control smoothed torque CUT lives on the HK table (HK.lcTcCut), not a local —
-- gearbox.lua is at the Lua 200-local ceiling. 0 = no cut, 1 = full cut to MinTorque. Attack/
-- release-smoothed toward the raw slip demand each launch frame so power feathers on/off instead
-- of stuttering. Reset to 0 when a launch fires/ends. (Declared here for reference only.)
local gbRpmPerSpeed  = {}      -- learned rpm/speed per gear (shared manual+DCT; real gear-ratio)
local dctClutchPrev  = false   -- edge-detect for the clutch toggle key
local dctShiftEndAt  = 0       -- DCT manual: ms the decouple+rev-match window closes
local dctPendingGear = nil     -- DCT manual: gear to COMMIT when the window closes
local dctCommittedGear = 1     -- DCT manual: last gear actually written to the box
local gbLimiterOn    = false   -- rev-limiter hysteresis latch (shared manual+DCT)
-- NOTE: the "engaged via SPEED-CAP path" flag lives on HK.gbLimiterByCap (not a module local) — gearbox.lua
-- is at Lua's 200-local ceiling, and HK is the right home anyway (the overlay + reset already use it).
-- GEAR-RATIO MODE (PHASE 2). Per-vehicle, resolved at Enable from the DB row's
-- `ratio` field -> Config.Gearbox.RatioModes[n]. Holds MULTIPLIERS only; Config is
-- never mutated (B1 design: read baseline * gbRatio.X at each shift-point). Defaults
-- to the [0] no-op profile so a car with no ratio set behaves exactly as stock.
local gbRatio        = nil      -- the active RatioModes profile (set in Gearbox_Enable)
-- The drive force the tick should RE-ENGAGE to (decouple still drops to 0.0). This
-- is stock fInitialDriveForce, OR stock*(1+DriveForcePct) when RatioUseDriveForce is
-- on. Kept separate from `origins` so Disable always restores the true stock value
-- and the ratio bump is never baked into the snapshot.
local gbDriveForceLive = nil
-- ACCEL MATCH (speed-invariant guard). ACTIVE FLAG for this vehicle: 1 = trim this
-- car (its public type is in AccelMatch.Modes), 0 = don't. The curve itself (depth +
-- absolute-km/h smoothstep trapezoid) lives in the tick. Torque-only, always <=1.0.
local gbAccelTrim    = 0.0
local gbSpeedCal     = nil      -- {f1,f2,f3,f4} unpacked from the model's speedCalC (set in Enable)
local gbSpeedCalTargeted = false  -- true when this model has a valid baseline/target set
local gbSpeedCalSuspend = false -- TRUE during a calibration pull: forces the trim OFF so the
                                -- timer measures the TRUE NEUTRAL baseline (the factor is then
                                -- computed from that clean run, never from a factor-applied one).
HK = HK or {}
HK.speedCalSuspend = function(on) gbSpeedCalSuspend = on and true or false end
local spawnNameByHash = {}     -- model hash -> spawn id string (e.g. 'rs721'), built at startup
local _dbgClutchPrev = nil     -- debug: last clutchActive value (edge-print only)
local lastDriveForce = nil     -- last fInitialDriveForce value we WROTE (dedupe per-frame writes)
local driveForceCheckAt = 0    -- GetGameTimer() ms; throttle for the external-resync drift check

-- Write fInitialDriveForce only when it actually changes. The clutch sim sets it
-- every frame (0.0 while decoupled, origins value otherwise), but it spends long
-- stretches steady — so a per-frame native write + captureOriginal lookup is pure
-- waste. Same values land; we just skip the no-op writes. Reset lastDriveForce to
-- nil on enable/disable/reset so the first write for a new vehicle always applies.
local function setDriveForce(veh, value)
    if value == lastDriveForce then return end
    lastDriveForce = value
    vl_setHandling(veh, 'fInitialDriveForce', value)
end

-- EXTERNAL-RESYNC GUARD (fixes the "/admincustoms -> stuck at 0 velocity" bug + the
-- random-occasion variant). Our setDriveForce dedupe assumes WE are the only writer of
-- fInitialDriveForce — but jim's pushVehicle (SetEntityAsMissionEntity + network-control
-- request, fired the instant /admincustoms opens) and any entity-control migration make
-- the game RE-SYNC the vehicle's handling from the pool. If that snapshot lands on a
-- frame where we had drive force decoupled (0.0 during a shift/clutch/neutral), the car
-- gets 0 fInitialDriveForce baked in — and because lastDriveForce still says "0 is what
-- we wrote", the dedupe blocks the tick from ever re-writing it. Result: zero drive that
-- survives /fix (never touches handling floats) until a full respawn (/dv, garage).
--
-- FIX: periodically (throttled) read the LIVE handling value; if it diverges from what
-- we last wrote, an external writer touched it -> invalidate the dedupe mirror so the
-- next setDriveForce re-asserts our intended value. Cheap: one native read a few times a
-- second, not per frame. veh-guarded; no-op until we've actually written something.
local function driveForceResyncCheck(veh, now)
    if lastDriveForce == nil then return end
    if now < driveForceCheckAt then return end
    driveForceCheckAt = now + (Config.Gearbox.DriveForceResyncMs or 250)
    local live = GetVehicleHandlingFloat(veh, 'CHandlingData', 'fInitialDriveForce')
    if live and math.abs(live - lastDriveForce) > 0.0005 then
        -- The pool re-synced under us (jim pushVehicle / /admincustoms / hk-parking
        -- SetVehicleProperties / entity-control migration).
        --
        -- CRITICAL: lastDriveForce may be a TRANSIENT 0.0 — the box decouples drive to 0 during
        -- a shift window / neutral / launch stage. If we blindly RE-ASSERT lastDriveForce here and
        -- it's that transient 0, we PIN the car dead (the "parked car can't be driven" bug: parking
        -- resets the real force to meta, we clobber it back to 0, and since 0==mirror the tick's
        -- dedupe never re-writes = permanently undriveable). So:
        --   * lastDriveForce  > 0 -> re-assert it (a real drive force the pool clobbered; this
        --     fixes branches that don't re-write every frame — DCT cruise, hybrid 'none').
        --   * lastDriveForce == 0 (transient decouple) -> DON'T write; just NIL the mirror so the
        --     next tick's setDriveForce re-engages the correct live value (gbDriveForceLive/origins)
        --     once the shift/neutral ends. Never pin a 0.
        if math.abs(lastDriveForce) > 0.0005 then
            if Config.Gearbox.Debug then
                print(('[hk-gearbox] drive-force resync: live=%.4f expected=%.4f -> re-asserting')
                    :format(live, lastDriveForce))
            end
            SetVehicleHandlingFloat(veh, 'CHandlingData', 'fInitialDriveForce', lastDriveForce + 0.0)
            -- mirror stays == lastDriveForce (still accurate); next setDriveForce dedupes correctly.
        else
            if Config.Gearbox.Debug then
                print('[hk-gearbox] drive-force resync: mirror was transient 0 -> nil, tick re-engages')
            end
            lastDriveForce = nil    -- transient decouple: let the tick re-assert the real force
        end
    end
end

-- Translate LOGICAL gear to the native gear byte. GTA stores gear unsigned, so
-- -1 (reverse) wraps to 255 — never pass it. R(-1) maps to native 0,
-- disambiguated from a stop by drive-force + reverse input arbitration.
local function nativeGear(tg)
    if tg <= 0 then return 0 end
    return tg
end

local function dbg(...)
    if Config.Gearbox and Config.Gearbox.Debug then print('[hk-gearbox]', ...) end
end

-- Shared learned gear ratio (rpm-per-speed) — manual AND DCT both feed/read it.
-- Only learn when the drivetrain is genuinely COUPLED: a handbrake skid or a
-- spinning/locked wheel decouples engine rpm from road speed, so rps=rpm/speed
-- goes garbage and would poison the learned ratio (which feeds both the auto
-- shift-point projection AND the manual gear snap — the source of the 'wrong
-- gear after toggle' and the handbrake gear-runaway). Skip those frames.
local function learnGearRatio(state, gear)
    -- rpm > 0.22 gate: the engine RPM FLOOR is 0.200 (never drops below idle, even
    -- lugging in a tall gear while moving). The old 0.15 gate let floor-pinned
    -- lugging frames through (rpm=0.20, speed>12), which learned a garbage ratio
    -- and polluted rev-match + the per-gear limiter cap. 0.22 sits just above the
    -- floor so only genuinely-revving frames are learned.
    if gear and gear >= 1 and state.speedKmh > 12.0 and state.rpm > 0.22
       and not state.handbrake and state.onAllWheels ~= false then
        local rps  = state.rpm / state.speedKmh
        local prev = gbRpmPerSpeed[gear]
        gbRpmPerSpeed[gear] = prev and (prev * 0.9 + rps * 0.1) or rps
    end
end

-- Project the RPM a given gear WOULD produce at the current speed, from the learned
-- per-gear ratio (gbRpmPerSpeed). Module-level so BOTH the DCT branch and the
-- manual/sequential branch can use it (sequential ECU protection needs it). Returns
-- nil if that gear hasn't been learned yet (caller decides the fallback).
local function projectRpmFor(gear, state)
    local rps = gear and gbRpmPerSpeed[gear]
    if rps and (state.speedKmh or 0) > 0 then return rps * state.speedKmh end
    return nil
end

-- REV LIMITER (shared manual + DCT). Caps speed at each gear's ratio with a real
-- dip-then-bump: triggers on rpm redline OR the learned per-gear speed cap (rpm
-- can plateau below redline in a held gear, so the speed cap is what makes it
-- reliable). When limiting, KILL THE THROTTLE input (so rpm drops off 1.0 and GTA
-- never force-upshifts) + cut torque + a light brake to force the visible dip.
--
-- TOP-SPEED INVARIANT: in the HIGHEST gear there is no taller gear to protect, so
-- the learned speed-cap is disabled there — otherwise a slightly-low learned ratio
-- would brake the car short of its real handling top speed (fInitialDriveMaxFlatVel).
-- The car must always reach exactly its handling.meta top speed. The pure rpm-
-- redline trigger still applies (harmless: it can't fire below the spec top speed).
local function applyRevLimiter(state, gear, veh)
    local cfg = Config.Gearbox
    HK.gbLimiterOn = false   -- mirror to HK every frame; early-returns below leave it false (limiter off)
    HK.limiterBraking = false -- reset each frame; set true only in the active section when braking (so an
                              -- early-return frame can't leave it stale-true and block a legit upshift)
    -- HK.gbLimiterByCap: set true ONLY on a speed-cap engage frame below, cleared on release/early-return.
    -- The main loop also zeroes it pre-tick, so on a hysteresis-hold dip frame (engaged but not re-tripping)
    -- it reads false — harmless: the pinned-upshift only needs ONE cap-engage frame to fire, and AutoDwellMs
    -- covers the gap. This avoids force-shifting during the limiter's brief release-dip.
    if not cfg.RevLimiter then gbLimiterOn = false; HK.gbLimiterByCap = false; return end
    if (state.throttle or 0) < (cfg.RevLimiterMinThrottle or 0.5) then
        gbLimiterOn = false; HK.gbLimiterByCap = false; return
    end
    if gear and gear < (cfg.RevLimiterMinGear or 2) then gbLimiterOn = false; HK.gbLimiterByCap = false; return end

    -- AIRBORNE / UNLOADED-WHEEL GUARD: a driven wheel off the ground freewheels, so
    -- GetVehicleCurrentRpm (= wheelspeed*ratio) spikes to redline while ROAD speed is
    -- flat. Without this the rpm-redline fallback flutters the limiter (throttle-kill +
    -- brake pulse, 2-3x) until the car lands — the "stuck at gear N, revs bounce, then
    -- finally upshift" bug. The speed-cap path is road-based and wouldn't trigger while
    -- airborne anyway, so suspend the WHOLE limiter when not on all wheels. The auto
    -- upshift's own rpmGrounded guard already holds the gear until touchdown, so the
    -- shift still lands cleanly once the wheels regrip. Releases with no stuck throttle-
    -- disable (we return before DisableControlAction). Toggle via RevLimiterGroundOnly
    -- (default on even if the key is absent).
    if (cfg.RevLimiterGroundOnly ~= false) and state.onAllWheels == false then
        gbLimiterOn = false; HK.gbLimiterByCap = false; return
    end

    local rps     = gear and gbRpmPerSpeed[gear]
    -- Speed-cap only BELOW the top gear; top gear is bounded by handling top speed.
    local inTopGear = gear and gearcount and gear >= gearcount
    -- REDLINE THRESHOLD. Below top gear the normal redline (0.985) trips the upshift in time.
    -- TOP GEAR gets a HIGHER redline (2026-08-14 fix): the old shared 0.985 cut torque ~1.5% rpm
    -- short of true redline — and in a tall top gear that last rpm sliver is 15-25 km/h of real top
    -- speed, so our limiter was capping the car BELOW its native GTA/handling top. There's no upshift
    -- to time in top gear (GTA's own fInitialDriveMaxFlatVel terminal cap does the limiting), so let it
    -- pull essentially to true redline and only flutter right at the ceiling.
    local redline = cfg.RevLimiterRedline or 0.985
    if inTopGear then redline = cfg.RevLimiterTopGearRedline or 0.997 end
    -- MANUAL / SEQUENTIAL = PURE RPM FUEL-CUT (2026-08-14, user request). A real H-pattern or
    -- sequential box DOES have a redline cut (money-shift protection) — but it does NOT slow the car
    -- for you (no self-brake), and it never needs the SPEED-CAP dip (that path exists only so the
    -- AUTO box knows when to upshift — manual/seq never auto-shift, YOU hold the gear + shift). So on
    -- modes 1/6 we suppress the speed-cap (rpm-redline path only) AND the brake pulse below: the engine
    -- just bounces off redline until you grab the next gear, exactly like a real manual.
    local pureRpmCut = (gearMode == 1 or gearMode == 6)
    -- SPEED-CAP BASIS (2026-08-16 FIX): derive capKmh from the LIVE GEAR RATIO + mfv, NOT the learned
    -- rps. ROOT CAUSE of the "loses torque, coasts to 0, stuck at a random low speed" bug: the learner
    -- (learnGearRatio) computes rps = state.rpm/speed, but state.rpm is PAINTED (turbo whistle, high-
    -- hang, tc-feel, gear-sync all vl_setRpmRaw the needle up). A painted-high rpm inflates the learned
    -- rps ~1.5x (confirmed live: g1 rps=0.0196 vs true 0.0125). capKmh = redline/rps then comes out
    -- ~1.5x TOO LOW (g1 cap 50 vs real 79), so the rev-limiter speed-cap PINS the car at that false
    -- low speed — kills torque (RevLimiterCut=0), disables accel(71), self-brakes -> trapped, can't
    -- re-accelerate. The gear RATIO is ground truth (GetVehicleGearRatio, physics, un-paintable): the
    -- speed where gear g hits redline is redline * K * mfv / ratio (same basis as /gbstate topKmh).
    -- Fall back to the learned rps only if the ratio/mfv aren't available (should never happen live).
    -- MANUAL/SEQUENTIAL SPEED-BOUNCE (2026-08-14 — the "manual leaks past redline" fix). Manual is
    -- pureRpmCut: it relies ONLY on byRpm (state.rpm >= redline). But on modes 1/6 state.rpm is DE-BIASED
    -- (the paint de-bias above subtracts HK.rpmPaintBias), so the anchored physics rpm can sit just under
    -- redline while the gauge needle shows the cut — the rpm trip never fires and the car ACCELERATES
    -- past the gear's true ratio top (confirmed live on the Zonda F). Automatic never leaks because its
    -- SPEED-CAP (ground-truth ratio math, un-paintable) enforces the ceiling. So give manual the SAME
    -- ground-truth cap as a rev-bounce — but with NO self-brake (a real manual just bounces off the
    -- fuel-cut; the self-brake below already stays off for pureRpmCut). This makes the cap the ceiling on
    -- EVERY box; the rpm cut still fires first when it legitimately reaches redline (money-shift feel).
    -- Gated on RevLimiterManualSpeedBounce (default on) so it can be disabled without touching auto.
    local manualSpeedBounce = pureRpmCut and (cfg.RevLimiterManualSpeedBounce ~= false)
                              and cfg.RevLimiterUseSpeedCap and not inTopGear

    local capKmh
    if (not pureRpmCut or manualSpeedBounce) and cfg.RevLimiterUseSpeedCap and not inTopGear then
        local K = cfg.RatioSeedK or 1.199
        -- Basis = the LIVE mfv the car is actually holding (post-ceiling-clamp), NOT the stock floor.
        -- A chip-raised modded car rides above its stock floor; using the floor here would cap ~6%
        -- low and re-introduce the early-limiter / won't-upshift bog. Live mfv is the true top speed.
        local mfvBasis = (veh and GetVehicleHandlingFloat(veh, 'CHandlingData', 'fInitialDriveMaxFlatVel'))
        if not (mfvBasis and mfvBasis > 0) then
            mfvBasis = (HK.mfvFloor and HK.mfvFloor[HK.mfvFloorKey(veh)])
                or (origins and origins.fInitialDriveMaxFlatVel)
        end
        local ratio = veh and gear and GetVehicleGearRatio(veh, gear)
        if ratio and ratio > 0 and mfvBasis and mfvBasis > 0 then
            capKmh = redline * K * mfvBasis / ratio
        elseif rps and rps > 0 then
            capKmh = redline / rps                 -- legacy fallback (learned rps) if ratio unavailable
        end
    end
    -- WHEELIE SPEED-CAP RAISE (2026-08-14, user: "raise the speed cap during the wheelie action" so the
    -- held gear keeps accelerating at redline instead of pinning). wheelie.lua sets HK.wheelieSpeedCapBoost
    -- while the FRONT wheels are off; lift the cap by that factor so the car pulls further before it caps.
    if capKmh and HK.wheelieSpeedCapBoost and HK.wheelieSpeedCapBoost > 1.0 then
        capKmh = capKmh * HK.wheelieSpeedCapBoost
    end
    local dipKmh  = cfg.RevLimiterDipKmh or 9.0
    -- MANUAL = FAST FUEL-CUT FLUTTER (2026-08-14). A real manual has no ECU speed-governor: at redline
    -- it's a rapid fuel-cut "brraap" (~100-200ms cycle), NOT a lazy coast-down. The auto box's DipKmh
    -- (6-9 km/h) exists so the box can time an upshift — but manual never upshifts for you, so making it
    -- bleed 6 km/h on drag alone before re-engaging gave a slow ~800ms bounce. Use a TIGHT dip on manual
    -- (RevLimiterManualDipKmh, default ~1 km/h) so it re-engages almost immediately = the sharp redline
    -- flutter. Only applies to the manual speed-bounce path (autos keep their upshift-timing dip).
    if manualSpeedBounce then dipKmh = cfg.RevLimiterManualDipKmh or 1.0 end

    -- BRAKE PRIORITY AT THE LIMITER (2026-08-14 fix). Bug: at the rev limit in gear (throttle held),
    -- pressing the brake made the car SPEED UP (9x -> 10x km/h) instead of slowing. Cause: the limiter
    -- flutters — it CUTS torque to pin you at the cap, then RELEASES the cut the instant speed/rpm dips
    -- (releaseBySpeed/releaseByRpm below) so power can re-tick. A brake press IS a speed dip, so it
    -- tripped that release → torque snapped back to full 1.0 → the returning power surged the car past
    -- the pinned speed before the limiter re-engaged. So the brake was unlocking the throttle. Fix: when
    -- the player is genuinely braking, HOLD the cut (suppress the flutter-release) and force full torque
    -- cut so drive torque never fights the brakes — the brakes win, the car slows. effBrake is the
    -- modeled pedal (device-agnostic); fall back to raw. Gated by RevLimiterBrakePriority (default on).
    -- Physical S key (HK._pedalBrake, raw scan) is the most reliable brake signal — immune to any
    -- DisableControlAction on 72 and to the pedal model's mid-swap zeroing. Fall back to modeled/raw.
    local brakeSig = HK._pedalBrake or state.effBrake or state.brake or 0.0
    local braking  = (cfg.RevLimiterBrakePriority ~= false)
                     and (brakeSig >= (cfg.RevLimiterBrakePriorityMin or 0.15))
    HK.limiterBraking = braking   -- published so the DCT-auto upshift can hold the gear while braking
                                  -- (else the brake-tripped upshift into a taller gear = higher cap = the
                                  -- car "goes through" the limiter and speeds up instead of slowing).

    local byRpm  = state.rpm >= redline
    local byCap  = capKmh and state.speedKmh >= capKmh
    if byRpm or byCap then
        gbLimiterOn = true
        -- rpm-path takes precedence for the label: if rpm is at redline the normal upshift trip already
        -- fires, so this is NOT the stuck case. gbLimiterByCap = ONLY the pure speed-cap pin (rpm below
        -- redline) — the sole situation the pinned-upshift relaxation is for.
        HK.gbLimiterByCap = (byCap and not byRpm) or false
        HK.gbLimiterWhy = byRpm and 'rpm' or 'cap'   -- overlay: which path pinned (cap = the stuck-car culprit)
    elseif gbLimiterOn then
        local releaseBySpeed = capKmh and (state.speedKmh <= capKmh - dipKmh)
        -- Re-engage rpm: normal band below top gear; a TIGHT band in top gear so the terminal-speed
        -- flutter (0.997 -> reengage) doesn't bleed a chunk of top speed on every bounce.
        local reengageRpm = cfg.RevLimiterReengage or 0.965
        if inTopGear then reengageRpm = cfg.RevLimiterTopGearReengage or 0.99 end
        local releaseByRpm   = state.rpm < reengageRpm
        -- BRAKE PRIORITY: while braking, DON'T let the brake-induced dip release the cut (that release is
        -- what surged the car forward). Hold the limiter engaged so torque stays cut and the brakes win.
        if not braking and ((capKmh and releaseBySpeed) or (not capKmh and releaseByRpm)) then
            gbLimiterOn = false
            HK.gbLimiterByCap = false
        end
    end

    if gbLimiterOn then
        HK.gbLimiterOn = true                           -- tell ThrottleModel_Apply to HONOR the kill (don't re-pin 71)
        DisableControlAction(0, 71, true)               -- kill accel = no force-upshift
        -- TOP GEAR = REAL-CAR TERMINAL BOUNCE (user request 2026-08-14). In the final gear there is
        -- no gear above to upshift into, so the auto box's self-brake (which exists only to time an
        -- upshift by forcing a speed dip) is pointless and WRONG here — it drags the car back below
        -- its true terminal speed = the "bog at top speed" feel. A real car just bounces off the
        -- fuel-cut and coasts to where drag balances thrust. So in top gear: NO self-brake (like the
        -- manual/seq pureRpmCut path) and a SOFT partial cut (RevLimiterTopGearCut, default 0.15)
        -- instead of the hard full chop — a gentle limiter flutter, not a dead cut. Below top gear
        -- the full-cut + self-brake stays (it's how the auto box knows to grab the next gear).
        local cut = cfg.RevLimiterCut or 0.0
        if inTopGear then cut = cfg.RevLimiterTopGearCut or 0.15 end
        -- BRAKE PRIORITY: while braking, force the FULL cut even in top gear (where the cut is normally a
        -- soft 0.15 for the terminal bounce). Any residual drive torque here fights the brakes, which is
        -- how holding throttle+brake at the limiter still crept the car forward. Braking = brakes win.
        if braking then cut = 0.0 end
        -- DRIFT GEAR CEILING (symptom #5): we're HOLDING the gear for the fry, so rpm rides into the
        -- limiter. The normal below-top-gear behaviour here is a HARD chop + an auto-box SELF-BRAKE
        -- (both exist only to force a speed dip that times an upshift) — but we're deliberately NOT
        -- upshifting, so that chop kills the torque frying the tyres and the self-brake fights the
        -- forward drive (this is the old "rolling burnout caps at ~2 km/h" bog). Instead give the SAME
        -- terminal-bounce feel as top gear: a SOFT flutter cut (rpm still bounces high off the fuel-cut
        -- = the "rpm HIGH during wheelspin" the user wants) and NO self-brake. Brake-priority still wins.
        if (HK.driftHoldGear or HK.wheelieHoldGear) and not braking then cut = math.max(cut, cfg.RevLimiterTopGearCut or 0.15) end
        HK.torqueMult = HK.torqueMult * cut
        -- Self-brake ONLY on the auto boxes AND only below top gear. A real manual/sequential (or ANY
        -- box in its final gear) doesn't brake itself at the limiter — it just stops pulling + bounces.
        -- Suppressed during launch-drag (see above — it fights the drag we're intentionally producing).
        local bp = (pureRpmCut or inTopGear or HK.driftHoldGear or HK.wheelieHoldGear) and 0.0 or (cfg.RevLimiterBrake or 0.0)
        if bp > 0 and veh then
            local n = state.wheelCount or 4
            for i = 0, n - 1 do vl_brakeWheel(veh, i, bp) end
        end
    end
end

-- LUGGING FLOOR (shared). Keeps a ROLLING tall-gear cruise alive (fills the
-- dead zone) without launching the car from a standstill. Gated on moving +
-- throttle, tapered down for taller gears, gentle peak.
local function applyLugFloor(state, gear)
    local cfg = Config.Gearbox
    if (state.throttle or 0) < (cfg.LugMinThrottle or 0.5) then return end
    if gear < (cfg.StallMinGear or 2) then return end
    if (state.speedKmh or 0) < (cfg.LugMinSpeedKmh or 8.0) then return end  -- standstill in tall gear bogs (realistic)
    local maxRpm = cfg.LugBoostMaxRpm or 0.22
    if state.rpm >= maxRpm then return end
    -- SPEED TAPER, SCALED TO TOP SPEED (the curve). Full assist in a low band so a
    -- tall gear can get rolling, then a GRADUAL (eased) taper to zero so low-mid
    -- cruise accelerates slowly on natural pull (no over-acceleration). The band
    -- scales to the car's top speed: ~11%..~50% of top = 35..160 km/h on a 320 car,
    -- so it generalises across slow + fast cars. Falls back to fixed km/h if the
    -- estimated top speed is unknown.
    local spd = state.speedKmh or 0.0
    local fadeStart, fadeEnd
    if gbTopKmh and gbTopKmh > 0 then
        fadeStart = gbTopKmh * (cfg.LugFullFrac or 0.11)
        fadeEnd   = gbTopKmh * (cfg.LugFadeEndFrac or 0.50)
    else
        fadeStart = cfg.LugFadeStartKmh or 40.0
        fadeEnd   = cfg.LugFadeEndKmh or 90.0
    end
    local fade = 1.0
    if spd >= fadeEnd then
        return                                          -- fully faded out: no assist
    elseif spd > fadeStart then
        -- eased (squared) ramp so it lets go softly, not at a cliff
        local lin = 1.0 - (spd - fadeStart) / (fadeEnd - fadeStart)
        fade = lin * lin
    end
    local gearScale = 1.0 / (1.0 + (gear - (cfg.StallMinGear or 2)) * (cfg.LugGearFalloff or 0.5))
    local peak = 1.0 + ((cfg.LugBoost or 1.18) - 1.0) * gearScale * fade
    local t = state.rpm / maxRpm                        -- 0 at idle -> 1 at maxRpm
    HK.torqueMult = HK.torqueMult * (peak * (1.0 - t) + 1.0 * t)
end

-- ENGINE TORQUE-CURVE FEEL — two independent, separately-gated layers (see Config.Gearbox.
-- TorqueCurve). Smoothing accumulators live on HK.* (main chunk at the 200-local ceiling).
--   LAYER A (RpmCharacter): PERF-NEUTRAL needle/note shaping via vl_setRpmRaw only. Paints a
--     small rpm offset — needle lags a touch off-idle, hangs/rawrs near redline. Zero force, so
--     it runs for ALL boxes (comfort/paddle included). Skipped on coast/brake (true engine-brake).
--   LAYER B (PowerBand): PERF-RELEVANT rpm-shaped HK.torqueMult. AREA-NORMALISED to mean 1.0
--     (pure redistribution) then scaled by (1+NetGain). HARD-GATED to internal modes 4 & 5 — the
--     public Sport/Super DCT tiers that MAY gain time. NEVER runs on internal 2 (public 0 comfort)
--     or internal 3 (public 2 Automatic Paddle): those stay strictly performance-neutral.
HK.tcRpmOff = HK.tcRpmOff or 0.0     -- Layer A: smoothed painted rpm offset (signed, normalised)
HK.tcBand   = HK.tcBand   or 1.0     -- Layer B: smoothed torque-band multiplier
-- NET COSMETIC RPM PAINT (modes 1/6). SetVehicleCurrentRpm feeds back into GetVehicleCurrentRpm next
-- frame (documented in the Layer A note below — the Chiron mode-4 regression). Layer A + the turbo
-- whistle each paint on the rpm-owning boxes; the LAST writer (turbo, runs after Layer A) is what
-- feeds back. We record that committed offset here so Gearbox_Tick can subtract it from state.rpm
-- BEFORE the rev-limiter reads it — otherwise a +0.05 whistle lift trips the fuel-cut ~0.05 rpm early
-- (in top gear that pins revs at a false redline = "can't accelerate"). Same idea as the mode-3
-- HK.tcSlipCur de-bias. Set by the paint sites, consumed + cleared at the top of each Gearbox_Tick.
HK.rpmPaintBias = HK.rpmPaintBias or 0.0
-- Hung on HK.* (NOT a file local): the main chunk is at Lua's EXACT 200-local ceiling, so even one
-- more `local function` won't compile. The two curve helpers are nested closures inside.
function HK.TorqueCurve_Tick(veh, state, dt)
    local TC = Config.Gearbox.TorqueCurve
    if not TC or TC.Enabled == false then return end
    local r   = state.rpm or 0.0
    local thr = state.throttle or 0.0

    -- Piecewise curve mult at normalised rpm r: low@0 -> peak@PeakRpm -> redline@1, linear between.
    local function tcBandShape(rr, PB)
        local pr = PB.PeakRpm or 0.62
        if rr <= pr then
            local t = (pr > 0) and (rr / pr) or 1.0
            return (PB.LowMult or 0.9) + ((PB.PeakMult or 1.12) - (PB.LowMult or 0.9)) * t
        else
            local t = (pr < 1.0) and ((rr - pr) / (1.0 - pr)) or 1.0
            return (PB.PeakMult or 1.12) + ((PB.RedlineMult or 0.94) - (PB.PeakMult or 1.12)) * t
        end
    end
    -- Mean of the shape over [0,1] via the trapezoid of its 2 linear segments (peak splits it), so
    -- we can area-normalise to 1.0 (pure redistribution) before applying NetGain. Exact for a
    -- piecewise-linear curve; cheap enough to run per-frame.
    local function tcBandMean(PB)
        local lo, pk, rl, pr = PB.LowMult or 0.9, PB.PeakMult or 1.12, PB.RedlineMult or 0.94, PB.PeakRpm or 0.62
        local segA = ((lo + pk) * 0.5) * pr            -- avg of segment [0,PeakRpm] * width
        local segB = ((pk + rl) * 0.5) * (1.0 - pr)    -- avg of segment [PeakRpm,1] * width
        return segA + segB                             -- total area over width 1.0 = mean
    end

    -- ---- LAYER B: power band (perf-relevant; internal modes 4 & 5 ONLY) ----
    local PB = TC.PowerBand
    if PB and PB.Enabled ~= false and PB.Modes and PB.Modes[gearMode] then
        local target = 1.0
        if thr >= (PB.MinThrottle or 0.30) then
            local mean = tcBandMean(PB)
            local shape = tcBandShape(r, PB)
            -- area-normalise to mean 1.0 (redistribute, net-neutral) THEN add the net gain.
            local norm = (mean > 1e-4) and (shape / mean) or 1.0
            target = norm * (1.0 + (PB.NetGain or 0.0))
        end
        -- smooth so crossing an anchor doesn't step torque (exp-tau).
        local tau = PB.Tau or 0.08
        HK.tcBand = HK.tcBand + (target - HK.tcBand) * (1.0 - math.exp(-dt / math.max(tau, 1e-3)))
        HK.torqueMult = HK.torqueMult * HK.tcBand
    else
        HK.tcBand = 1.0   -- decay-free reset when not eligible (no leak into a non-band mode next frame)
    end

    -- ---- LAYER A: rpm-needle / note character (PERF-NEUTRAL; PLAYER-shifted boxes only) ----
    -- CRITICAL: Layer A writes the ACTUAL engine rpm (SetVehicleCurrentRpm), and that SAME value is
    -- what the auto-shift logic reads back as state.rpm (upshift trip + atLimiter/pinned). So on any
    -- AUTO box (3/4/5) the HighHang paint (+HighHang near redline) inflates the shift-decision rpm ->
    -- early upshift, and once it pushes state.rpm past OverrevRpm it trips atLimiter -> pinned, which
    -- FORCES an upshift and overrides the next-gear guard -> jump/skip a gear -> instant kickdown hunt
    -- -> "stuck". That was the Chiron (mode 4) regression. It ALSO changes mode-3 shift timing, which
    -- violates mode 3's perf-neutral guarantee. So Layer A now runs ONLY on PLAYER-shifted boxes:
    -- manual(1) + sequential(6). There the driver owns shift timing, so painting rpm is genuinely
    -- neutral (needle/note only). Comfort auto (mode 2) still never gets a write (GTA owns its rpm).
    -- EVs run their own instant-torque feel. Modes 3/4/5 get their character from Layer B (torque).
    local RC = TC.RpmCharacter
    local rpmOwned = (gearMode == 1 or gearMode == 6)
    if RC and RC.Enabled ~= false and rpmOwned and not isEV then
        local off = 0.0
        if thr >= (RC.MinThrottle or 0.15) then
            local loR, hiR = RC.LowRpm or 0.22, RC.HighRpm or 0.82
            if r < loR then
                -- soft low-end: needle sits slightly BELOW physics rpm, easing to 0 by loR.
                local w = (loR > 0) and (1.0 - r / loR) or 0.0
                off = -(RC.LowLag or 0.03) * w
            elseif r > hiR then
                -- high-rpm rawr: needle HANGS slightly above, ramping in past hiR.
                local w = (hiR < 1.0) and ((r - hiR) / (1.0 - hiR)) or 1.0
                off = (RC.HighHang or 0.04) * w
            end
        end
        local tau = RC.Tau or 0.12
        HK.tcRpmOff = HK.tcRpmOff + (off - HK.tcRpmOff) * (1.0 - math.exp(-dt / math.max(tau, 1e-3)))
        -- Paint ONLY when the offset is meaningful, and never let it fight a redline/limiter pin
        -- (the limiter owns rpm at the top). vl_setRpmRaw = zero drive force = perf-neutral.
        if not gbLimiterOn and math.abs(HK.tcRpmOff) > 0.002 then
            local painted = r + HK.tcRpmOff
            if painted < 0.0 then painted = 0.0 elseif painted > 1.0 then painted = 1.0 end
            vl_setRpmRaw(veh, painted)
            HK.rpmPaintBias = HK.tcRpmOff   -- record the committed offset (may be overwritten by the turbo whistle, which runs after)
        end
    else
        HK.tcRpmOff = 0.0   -- not an rpm-owning box (auto/EV/comfort): no stale offset leaks into the readout
    end

    -- diagnostics for /handlingdbg engine section.
    if HK.hdbgOn then
        HK.dbgTorqueCurve = HK.dbgTorqueCurve or {}
        local d = HK.dbgTorqueCurve
        d.band   = HK.tcBand
        d.rpmOff = HK.tcRpmOff
        d.bandOn = (PB and PB.Enabled ~= false and PB.Modes and PB.Modes[gearMode]) or false
        d.at     = GetGameTimer()
    end
end

-- ============================================================= TURBO
-- HK.Turbo_Tick — the turbo FEEL + flat power, gated on the native GTA turbo mod (type 18) that the
-- jim-mechanic performance upgrade installs. NO mod = full early-return = zero change (stock feel +
-- stock power, car stays at spec). TABLE-FIELD fn (not a local) + HK.* state to respect the 200-local
-- ceiling. Runs in the torque-trim zone AFTER TorqueCurve_Tick so its power layer composes on top of
-- Layer B. See [[antilag-ev-suppression]] for the NOS stand-down pattern the whistle mute mirrors.
function HK.Turbo_Tick(veh, state, dt)
    local TB = Config.Gearbox.Turbo
    if not TB or TB.Enabled == false then HK.turboSpool = 0.0; return end
    -- TWO independent triggers:
    --   modOn    = the jim-mechanic turbo UPGRADE (native mod 18) is installed. Adds POWER.
    --   byDesign = the car is turbo-by-design (roster / DB / /setturbo). FEEL only, default-on.
    -- FEEL (spool/whistle) runs if EITHER is true; POWER runs ONLY when modOn (equal for all cars,
    -- so an NA car with the upgrade also spools + gains). No trigger at all → full early-return =
    -- zero change (stock feel + stock power, car stays exactly at spec).
    local modOn    = IsToggleModOn(veh, TB.ModIndex or 18)
    local byDesign = HK.turboDefault == true
    if not modOn and not byDesign then
        HK.turboSpool = 0.0
        HK.turboNoteOff = 0.0
        HK.turboThrottleMult = 1.0     -- no turbo = pedal passes through untouched
        HK.turboActive = false         -- ALWAYS-ON gauge flag (not debug-gated): no turbo on this car
        HK.turboHit = 0.0
        if HK.hdbgOn then HK.dbgBoost = HK.dbgBoost or {}; HK.dbgBoost.on = false end
        return
    end
    HK.turboActive = true              -- turbo present (upgrade OR by-design) — speedo gauge may render

    -- EV-MODE SUPPRESSION (2026-08-14): a pure EV never reaches here (isEV forces byDesign=false at
    -- Enable), but a HYBRID currently running on electric (hybridEMode) still would — the ICE is off,
    -- so there's no boost. Stand the turbo fully down (no spool, no power, no whistle, gauge off) while
    -- in e-mode; it resumes the instant the car hands back to the ICE. Mirrors the antilag EV stand-down
    -- ([[antilag-ev-suppression]]). Gauge is told OFF too (HK.turboActive=false) so hk-speedo hides it.
    if isHybrid and hybridEMode then
        HK.turboSpool = 0.0
        HK.turboNoteOff = 0.0
        HK.turboThrottleMult = 1.0
        HK.turboActive = false
        HK.turboHit = 0.0
        if HK.hdbgOn then HK.dbgBoost = HK.dbgBoost or {}; HK.dbgBoost.on = false end
        return
    end

    local r   = state.rpm or 0.0
    -- Use the SYNTHESIZED device-agnostic pedal (effThrottle), NOT raw state.throttle. Raw is
    -- GetControlNormal(0,71), which this codebase documents as reading 0 on some input methods (see
    -- the AccelMatch onPower fallback below) — and when it reads 0, onThr never trips, spool never
    -- builds, and the turbo pedal-lag freezes at ThrottleFloor forever. effThrottle is the pedal every
    -- other throttle-graduated feature reads for exactly this reason. Fall back to raw then 0.
    local thr = state.effThrottle or state.throttle or 0.0

    -- ANTILAG: read the hk_antilag player statebag jim-mechanic's inCarLogic publishes (true = the
    -- antilag part is fitted). Antilag can't be installed without turbo mod 18, so it always implies
    -- modOn — but we still guard. Two effects: (B) HOLD spool on lift below, and (A) let antilag own
    -- the lift-off FX (mute our synthetic flutter). See [[antilag-ev-suppression]] for the module side.
    local alOn = false
    if TB.Antilag ~= false then
        local ok, v = pcall(function() return LocalPlayer.state.hk_antilag end)
        alOn = ok and v == true and modOn      -- require the mod too (defensive; install path guarantees it)
    end

    -- SPOOL MODEL: boost availability ramps with rpm (laggy off-idle, on-boost up top), and the spool
    -- accumulator LAGS the throttle (exp-tau, faster to bleed than to build = real turbo behaviour).
    local rpmAvail = 0.0
    local loR, hiR = TB.SpoolMinRpm or 0.34, TB.SpoolFullRpm or 0.72
    if r >= hiR then rpmAvail = 1.0
    elseif r > loR then
        rpmAvail = (r - loR) / math.max(1e-4, hiR - loR)
        -- ease-in exponent: >1 keeps availability LOW through the mid-revs then ramps hard near hiR,
        -- so boost "wakes up" high instead of fading in linearly = the peaky, laggy-then-rush feel.
        local cv = TB.SpoolCurve or 1.0
        if cv ~= 1.0 then rpmAvail = rpmAvail ^ cv end
    end
    local onThr  = (thr >= (TB.MinThrottle or 0.20))
    local target = (onThr and rpmAvail) or 0.0
    -- LOAD GATE (2026-08-14): a real turbo spools from EXHAUST MASS FLOW under LOAD — the engine has
    -- to be pulling against the drivetrain. Free-revving in neutral (or with the clutch in) makes almost
    -- no exhaust flow, so it barely spools. Our spool target above is rpm+throttle only, so a neutral
    -- blip would wrongly build full boost, light the gauge, and choke the pedal-lag as if under load.
    -- Kill the target whenever the box is logically DISENGAGED (neutral, or clutch held) so a neutral
    -- rev bleeds boost off (SpoolTauDown) instead of building it. gbInNeutral/gbClutchHeld are set fresh
    -- this frame in Gearbox_Tick, just above the Turbo_Tick call. Bleed (not hard-zero) so it decays
    -- naturally and re-spools the instant the clutch bites / a gear engages.
    if TB.LoadGate ~= false and (HK.gbInNeutral == true or HK.gbClutchHeld == true) then
        target = 0.0
    end
    -- (B) ANTILAG SPOOL HOLD — real antilag keeps the turbo lit on a lift so there's no lag on corner
    -- exit. While antilag is fitted and we're OFF-throttle but STILL at revs (a mid-corner lift, same
    -- rpm gate the module's backfire uses), hold the current spool instead of bleeding it. Falls back
    -- to normal bleed the moment revs actually drop (real slow-down / stop), so it never pins at idle.
    -- Perf-safe: spool only feeds POWER while ON-throttle in modes 4/5, so a held spool adds ZERO
    -- top speed — it only removes the re-spool delay when you get back on the throttle.
    if alOn and not onThr and r > loR then
        target = math.max(target, HK.turboSpool or 0.0)
    end
    local tau    = (target > (HK.turboSpool or 0.0)) and (TB.SpoolTauUp or 0.45) or (TB.SpoolTauDown or 0.22)
    local prevSpool = HK.turboSpool or 0.0
    HK.turboSpool = prevSpool + (target - prevSpool) * (1.0 - math.exp(-dt / math.max(tau, 1e-3)))
    local spool = HK.turboSpool
    -- spool RATE (per second, rising only) — drives the transient boost "hit" below. This is how fast
    -- boost is coming online right now; a big number = it's rushing on = punch. Clamped to >=0 so a
    -- bleed-down never fires the hit.
    local spoolRate = math.max(0.0, (spool - prevSpool) / math.max(dt, 1e-3))
    -- GAUGE PUNCH (always-on, cosmetic): how hard boost is slamming online right now, 0..1, weighted by
    -- spool so it only flashes as boost crosses onto the powerband (not down in the dead zone). Mirrors
    -- the power layer's hit shape but is NOT gated on modes 4/5 or the upgrade — the hk-speedo turbo
    -- gauge flashes on ANY turbo car's tip-in. Published on HK.* so the speedo reads it without the
    -- debug overlay being open (HK.dbgBoost.hitPct is hdbgOn-gated; this is the live-gauge feed).
    HK.turboHit = math.min(1.0, spoolRate / math.max(TB.HitRateFull or 2.2, 1e-3)) * spool

    -- ---- POWER LAYER (perf-relevant; UPGRADE ONLY; internal modes 4 & 5 ONLY) ----
    -- Gated on modOn: ONLY the jim-mechanic upgrade adds power. A turbo-by-design car WITHOUT the
    -- upgrade gets the feel below but ZERO power (stays at spec) — exactly the user's requirement.
    -- SHAPE (the lag→rush the driver feels): REAL turbo physics — off-boost the engine makes its full
    -- naturally-aspirated torque (mult 1.0, NO penalty), and boost ADDS on top as it spools, PEAKING at
    -- (1+FlatPowerGain) at full spool. mult = 1 + gain*spool. There is no below-baseline choke: a real
    -- turbo car isn't WEAKER off-boost, it just hasn't gained the boost yet. The lag→rush the driver
    -- feels comes from (a) the HitGain transient as boost crosses onto the powerband, and (b) the pedal
    -- ThrottleFloor for keyboard. Removing the old SpoolChoke also kills the downward-spiral runaway
    -- (off-boost torque < aero drag → decel → spool bleeds → deeper choke) that TurboMinMult existed to
    -- catch — with a 1.0 floor the loop can't start. Top speed = FlatPowerGain alone (peak unchanged).
    -- Composes on top of Layer B. Comfort(2)/paddle(3) never touched (perf-neutral). Same for every car.
    local turboMult = 1.0
    local hitMult   = 1.0
    if modOn and TB.Modes and TB.Modes[gearMode] and thr >= (TB.PowerMinThrottle or 0.30) then
        local gain  = TB.FlatPowerGain or 0.08
        turboMult = 1.0 + gain * spool   -- 1.0 off-boost (full NA), 1+gain at full spool. No below-baseline dip.
        -- BOOST HIT: transient surge ON TOP of the steady curve, proportional to how fast spool is
        -- rising right now. Fires only while boost is actively coming online (spoolRate>0); at steady
        -- WOT spoolRate→0 so the hit vanishes and we're back on the plain curve = PEAK unchanged = top
        -- speed at spec. This is the "slams on" punch that's felt on keyboard AND wheel (torque-side).
        local hitGain  = TB.HitGain or 0.0
        if hitGain > 0.0 then
            local rateFull = TB.HitRateFull or 2.2
            local hitAmt   = math.min(1.0, spoolRate / math.max(rateFull, 1e-3))
            -- weight by spool so the punch lands as boost CROSSES onto its powerband (spool ~mid/high),
            -- not down in the dead zone where there's nothing to hit with.
            hitMult = 1.0 + hitGain * hitAmt * spool
        end
        HK.torqueMult = HK.torqueMult * turboMult * hitMult
    end
    -- DECAY TRACER FEED: expose this frame's turbo decomposition so the once/sec [hk-DECAY] trace
    -- (below the stuck diagnostic) can show whether the turbo layer is what collapses under throttle.
    HK.dbgDecay = HK.dbgDecay or {}
    HK.dbgDecay.turboMult = turboMult
    HK.dbgDecay.hitMult   = hitMult
    HK.dbgDecay.spool     = spool
    HK.dbgDecay.moveGate  = moveGate

    -- ---- THROTTLE-LAG LAYER (the FELT engagement step — perf-neutral, ALL turbo modes) ----
    -- The torque shaping above changes force, but the THROTTLE PLATE still opens instantly, so there's
    -- no "dead pedal then wake up" at your foot. Real lag is felt at the pedal: you press and the intake
    -- is choked until boost arrives, THEN it rushes. We model that by scaling the pedal-model's injected
    -- throttle by spool: off-boost the effective pedal is held down to ThrottleFloor of what you press,
    -- easing to full (1.0) as spool fills. Published to HK.turboThrottleMult; the pedal-apply multiplies
    -- its injected value by it (see HK.ThrottleModel_Apply). PERF-NEUTRAL: at full spool it's 1.0, so you
    -- still reach 100% throttle — it only DELAYS the onset, exactly like the keyboard ramp. That means it
    -- can run on byDesign cars WITHOUT the upgrade too (the feel, not the power) and stay at-spec on the
    -- top end. Only meaningful when the pedal model owns throttle (keyboard); analog passes through.
    -- floor lifts toward 1.0 (no pedal-hold) at a standstill via a move-off gate — so keyboard players
    -- aren't held to a fraction of throttle trying to pull away from a stop. At speed the floor drops to
    -- its full ThrottleFloor value so the onset lag is felt accelerating through the revs.
    local mkLo, mkHi = TB.ChokeMinKmh or 3.0, TB.ChokeFullKmh or 18.0
    local kmhNow = (state.speedKmh or (GetEntitySpeed(veh) * 3.6)) or 0.0
    local moveGate = (kmhNow - mkLo) / math.max(1e-3, (mkHi - mkLo))
    if moveGate < 0.0 then moveGate = 0.0 elseif moveGate > 1.0 then moveGate = 1.0 end
    local tFloor = TB.ThrottleFloor or 0.55        -- how held-back the pedal feels off-boost (0.55 = 55% of press)
    tFloor = 1.0 - (1.0 - tFloor) * moveGate       -- moveGate 0 (stopped) → floor 1.0 (full pedal); 1 (rolling) → full hold
    local lagCv  = TB.ThrottleLagCurve or 1.0      -- >1 = pedal stays choked through mid-spool then rushes open (a felt STEP, not a fade)
    local pedalOpen = spool
    if lagCv ~= 1.0 then pedalOpen = spool ^ lagCv end
    HK.turboThrottleMult = tFloor + (1.0 - tFloor) * pedalOpen

    -- ---- FEEL LAYER (perf-neutral; ALL modes) — whistle rise + lift flutter via the rpm-note ----
    -- NOS STAND-DOWN: while nitrous is firing it owns the FX (whistle/screen/flame), so mute ours to
    -- avoid double-spool. Reads the hk_nosBoostLevel player statebag jim-mechanic publishes.
    local nosOn = false
    if TB.NosMute ~= false then
        local ok, lvl = pcall(function() return LocalPlayer.state.hk_nosBoostLevel end)
        nosOn = ok and lvl and lvl > 0
    end
    -- rpm-note target: a small needle LIFT proportional to spool (the whistle), plus a brief DIP when
    -- off-throttle while still spooled (the flutter "pshh"). Both perf-neutral (needle/note only).
    -- (A) ANTILAG FX OWNERSHIP: when antilag is fitted it fires real backfire pops + crackle on the
    -- SAME lift-off condition, so we suppress OUR synthetic flutter dip to avoid a muddy double lift
    -- sound — antilag owns the lift. The on-throttle whistle stays (antilag doesn't do that).
    local noteTarget = 0.0
    if not nosOn then
        if onThr then
            noteTarget = (TB.WhistleRpmOff or 0.02) * spool
        elseif not alOn and spool > 0.15 then
            noteTarget = -(TB.FlutterOff or 0.015) * spool     -- lift-off flutter dip (muted when antilag owns it)
        end
    end
    local ntau = TB.NoteTau or 0.10
    HK.turboNoteOff = (HK.turboNoteOff or 0.0) + (noteTarget - (HK.turboNoteOff or 0.0)) * (1.0 - math.exp(-dt / math.max(ntau, 1e-3)))
    -- Paint only when meaningful, never fight a limiter pin (limiter owns top rpm), and only on the
    -- rpm-owning boxes (writing rpm on an auto box corrupts its shift read — same rule as Layer A).
    local rpmOwned = (gearMode == 1 or gearMode == 6)
    if rpmOwned and not isEV and not gbLimiterOn and math.abs(HK.turboNoteOff) > 0.001 then
        local painted = r + HK.turboNoteOff
        if painted < 0.0 then painted = 0.0 elseif painted > 1.0 then painted = 1.0 end
        vl_setRpmRaw(veh, painted)
        HK.rpmPaintBias = HK.turboNoteOff   -- final rpm writer on modes 1/6 → this is the value that feeds back next frame
    end

    -- diagnostics for the /handlingdbg boost line.
    if HK.hdbgOn then
        HK.dbgBoost = HK.dbgBoost or {}
        local d = HK.dbgBoost
        d.on       = true
        d.bar      = spool * (TB.MaxBar or 1.0)                 -- display bar (cosmetic scale)
        d.powerPct = (modOn and TB.Modes and TB.Modes[gearMode]) and ((turboMult * hitMult - 1.0) * 100.0) or 0.0
        d.hitPct   = (modOn and TB.Modes and TB.Modes[gearMode]) and ((hitMult - 1.0) * 100.0) or 0.0  -- transient punch on top right now
        d.source   = modOn and (byDesign and 'design+upgrade' or 'upgrade') or 'design'
        d.nosMuted = nosOn
        d.antilag  = alOn                                       -- (A) FX owned by antilag, (B) spool held on lift
        d.alHold   = alOn and not onThr and r > loR             -- true while actively holding spool on a lift
        d.pedalPct = (HK.turboThrottleMult or 1.0) * 100.0      -- effective throttle plate (the felt lag): 100% = full plate
        d.at       = GetGameTimer()
    end
end

-- ============================================================= FLYWHEEL FREE-REV
-- HK.flywheelRev — the free-rev needle integrator (Phase A). Called from the DECOUPLED rev-feed sites
-- (manual neutral, DCT neutral, mid-shift) instead of a fixed-rate ramp. Models a real flywheel: the
-- engine chases where the throttle wants it (target), but its rate is set by the car's OWN flywheel
-- mass (HK.flyMass, auto-derived from fDriveInertia at Enable). ASYMMETRIC: rev-UP is quicker than
-- rev-DOWN (no load off-throttle = only pumping/friction slows a spinning flywheel), and BOTH scale
-- with mass — a heavy flywheel revs lazily AND hangs on the way down (the signature rev-hang), a light
-- race flywheel snaps up and drops fast. Returns the new painted rpm (0..1); caller writes it via
-- vl_setRpmRaw and records HK.rpmPaintBias so the limiter/shift gates read the TRUE physics rpm.
-- PERF-NEUTRAL: only paints the needle/note while drive is already cut — zero force. cur = current
-- painted rpm, tgt = where the throttle wants the engine, dt = frame time.
-- dnRatioOverride: optional rev-DOWN ratio just for THIS call (used by the NEUTRAL free-rev sites so
-- a neutral lift coasts down slower than a shift rev-match, without touching the shared DownRatio).
function HK.flywheelRev(cur, tgt, dt, dnRatioOverride)
    local FW = Config.Gearbox.Flywheel or {}
    local fm = HK.flyMass or 1.0
    -- base rates (per second, exp-ease). Divided by mass so heavy = slower. Rev-down is the up rate
    -- scaled by DownRatio (<1) so a lift always hangs longer than a blip climbs.
    local upBase = FW.RevUpRate or 9.0
    local dnBase = upBase * (dnRatioOverride or FW.DownRatio or 0.45)
    local rising = tgt >= cur
    local rate = (rising and upBase or dnBase) / math.max(fm, 0.05)
    local a = 1.0 - math.exp(-(dt or 0.016) * rate)
    local nr = cur + (tgt - cur) * a
    -- snap the last sliver so a blip reads crisp (no infinite asymptote crawl at the top)
    if rising and (tgt - nr) < 0.01 then nr = tgt end
    if nr < 0.0 then nr = 0.0 elseif nr > 1.0 then nr = 1.0 end
    return nr
end

-----------------------------------------------------------------
-- REV-AGAINST-THROTTLE (2026-08-15) — the three-state free-rev / soft limiter, ENGINE-SIDE.
-- Moved out of burnout.lua (it was never really a burnout thing — it's engine behavior). Runs
-- INSIDE Gearbox_Tick, so it reads the box's own locals directly (inNeutral, clutchHeld, gearMode)
-- with no cross-file signal plumbing. Paints the needle via flywheelRev and CUTS drive torque, so
-- it's perf-neutral (the car is planted on the footbrake / sitting in neutral). THREE states:
--   [free] decoupled + FOOTBRAKE + throttle -> HARD free-rev: fast slam to redline, sharp cut.
--   [soft] decoupled + throttle, NO brake   -> SOFT limiter: lazy blip to a LOWER ceiling.
--   [load] IN GEAR   + FOOTBRAKE + throttle -> LOADED limiter: heavier climb, lower ceiling than
--          [free], HARDER flutter than [soft] — the driveline is loaded so revs don't fly free.
-- "decoupled" = the engine can spin free of the wheels: NEUTRAL for any box, OR (manual only) the
-- CLUTCH held. A real manual can't free-rev in gear without declutching — so in-gear + no clutch
-- can only ever be the loaded state. Autos/DCT/seq have no clutch, so decoupled == neutral.
--
-- Args: veh, state, dt. The box state (neutral / clutch / gearMode) is read from the HK.gb*
-- signals the gearbox publishes each frame at the top of Gearbox_Tick — so this runs from main.lua's
-- post-gearbox slot (the SAME timing the old burnout free-rev used: last rpm writer of the frame),
-- with no need to touch the five per-mode neutral branches. Returns true when it OWNS the frame
-- (painted + cut torque). Sets HK.freeRevActive (mutual-excl with the drift-key wheelspin in
-- main.lua). Skips pure EVs (no ICE to scream).
-----------------------------------------------------------------
HK.revFlutterPhase = HK.revFlutterPhase or 0.0
HK.revBounceOn     = HK.revBounceOn or false
function HK.RevAgainstThrottle_Tick(veh, state, dt)
    HK.freeRevActive = false
    -- Restore the free-rev inertia boost (fDriveInertia) if one is latched. Called on EVERY exit path
    -- that isn't the free branch (base-gate bails, disabled, EV, mode switch) so the boost can never
    -- leak into normal driving. Idempotent — no-op when nothing is latched.
    local function frRestoreInertia()
        if HK.frInertiaSaved ~= nil then
            if veh and veh ~= 0 then vl_setHandling(veh, 'fDriveInertia', HK.frInertiaSaved) end
            HK.frInertiaSaved = nil
        end
        -- also clear the sustained-rev cutout state so a fresh gesture starts un-cut with a zero timer
        HK.frHoldMs      = 0
        HK.frCutActive   = false
        HK.frRevZoneHit  = false
    end
    local B  = Config.Burnout
    local fr = B and B.FreeRev
    if not B or B.Enabled == false or not fr or fr.Enabled == false then frRestoreInertia(); return false end
    if HK.gbIsEV == true then frRestoreInertia(); return false end   -- pure EV: no engine to rev
    local inNeutral = (HK.gbInNeutral == true)
    local clutchHeld = (HK.gbClutchHeld == true)
    local gearMode  = HK.gbGearMode

    -- Read HARDWARE pedals (immune to our DisableControlAction). THROTTLE = W (control 71, enabled
    -- + disabled since a forward-gear stop disables it). BRAKE = S from the PHYSICAL key: the
    -- reverse rework permanently disables control 72 at a stop, so control 72 reads 0 when S held.
    local thr = math.max(GetControlNormal(0, 71), GetDisabledControlNormal(0, 71))
    local brk = HK._pedalBrake or math.max(GetControlNormal(0, 72), GetDisabledControlNormal(0, 72))
    local kmh = state.speedKmh or 0.0

    -- STATE (computed BEFORE the lift-bail so the neutral no-brake DROP below can gate on it directly,
    -- with no cross-frame latch to desync).
    local braking    = brk >= (fr.BrakeGate or 0.5)
    local isManual   = (gearMode == 1)
    -- ENGINE FREE = decoupled from wheels: neutral (any box) OR clutch held (manual only).
    local engineFree = inNeutral or (isManual and clutchHeld == true)
    -- LAUNCH-CONTROL GUARD: LC stages with HANDBRAKE + throttle in neutral and owns its own staged
    -- rpm paint. Don't let the no-brake soft state fight a staging/launched car.
    local hb = (state.handbrake == true)
        or IsControlPressed(0, 76) or IsDisabledControlPressed(0, 76)
    local lcBusy = (HK.launch and HK.launch.active == true) or hb

    -- ============================================================ NEUTRAL NO-BRAKE REV DROP (2026-08-16)
    -- The dedicated, SELF-OWNING slow rev-fall the player wants: in NEUTRAL, NO brake, throttle just
    -- LIFTED — ease the needle DOWN slowly to idle instead of snapping. We OWN the frame the whole way
    -- (freeRevActive=true + paint via vl_setRpmRaw + GetFreeRevRpm returns HK.revPaint), so nothing
    -- (flywheelRev, native sag) can stomp it. Gated tight: only neutral + engine-free + NOT braking +
    -- NOT launch/handbrake + NOT drift + on the ground + slow. Free-rev (brake) and in-gear are excluded
    -- so their instant-snap behaviour is untouched. Decays HK.revPaint (seeded from the hold) toward a
    -- FIXED idle at NeutralDropRate; when it lands at idle we release (return false) and hand back native.
    if thr < (fr.MinThrottle or 0.5) then
        frRestoreInertia()
        local neutralNoBrake = engineFree and not braking and not lcBusy
                               and HK.driftMode ~= true
                               and kmh <= (fr.MaxKmh or 5.0)
                               and not IsEntityInAir(veh)
        if neutralNoBrake and HK.revPaint ~= nil then
            local idle = (Config.Gearbox.Flywheel and Config.Gearbox.Flywheel.IdleRpm) or 0.20
            local dropRate = fr.NeutralDropRate or 3.0            -- lower = slower fall (exp-ease per s)
            local a  = 1.0 - math.exp(-(dt or 0.016) * dropRate)
            local nr = HK.revPaint + (idle - HK.revPaint) * a
            if (nr - idle) < 0.01 then                            -- landed at idle: release, hand back native
                HK.revPaint, HK.freeRevActive, HK.revBounceOn = nil, false, false
                return false
            end
            HK.revPaint      = nr
            HK.freeRevActive = true                               -- KEEP owning so the speedo reads the fall
            HK.revBounceOn   = false
            vl_setRpmRaw(veh, nr)
            HK.dbgBurnout = HK.dbgBurnout or {}
            HK.dbgBurnout.frRpm  = nr
            HK.dbgBurnout.frMode = 'ndrop'
            return true
        end
        -- not a neutral-no-brake lift (brake held / in gear / airborne / no paint): clean bail.
        HK.revPaint = nil; return false
    end
    if HK.driftMode == true then HK.revPaint = nil; frRestoreInertia(); return false end  -- drift+W+S = Step-2 wheelspin
    if kmh > (fr.MaxKmh or 5.0) then HK.revPaint = nil; frRestoreInertia(); return false end
    if IsEntityInAir(veh) then HK.revPaint = nil; frRestoreInertia(); return false end

    -- STATE SELECT.
    -- LOAD gate accepts HANDBRAKE too (2026-08-16): the player wants the rev limiter while stationary
    -- in gear holding brake OR handbrake OR both. footbrake=braking; add hb here. Scoped to the LOAD
    -- (in-gear) branch ONLY — the free/soft branches stay footbrake-only so handbrake+throttle in
    -- NEUTRAL still belongs to launch control (LC stages exactly that way), never the free scream.
    local loadBraking = braking or hb
    local mode                                          -- 'free' | 'soft' | 'load' | nil
    if engineFree and braking then
        mode = 'free'                                   -- [2] decoupled + footbrake = hard scream
    elseif engineFree and not lcBusy then
        mode = 'soft'                                   -- [1] decoupled + throttle only = soft limit
    elseif (not engineFree) and loadBraking then
        mode = 'load'                                   -- [3] in gear + brake/handbrake = loaded limiter
    end                                                 -- else in-gear no-brake = launch; bail

    HK.dbgBurnout = HK.dbgBurnout or {}
    HK.dbgBurnout.frMode = mode or '-'
    HK.dbgBurnout.frThr  = thr
    HK.dbgBurnout.frBrk  = brk
    HK.dbgBurnout.frKmh  = kmh
    HK.dbgBurnout.frEng  = (mode ~= nil)

    -- RESTORE the inertia boost the moment we're NOT in free mode (switched to soft/load, or no mode).
    -- Puts the exact pre-boost value back so the normal flywheel/shift feel returns instantly.
    -- Also drop the "was free-revving" latch so the release-fall (below) only eases the needle down
    -- after a true brake-held scream, not after a soft/load blip.
    if mode ~= 'free' then frRestoreInertia() end

    if not mode then
        HK.revBounceOn = false
        HK.revPaint    = nil                            -- drop the accumulator; re-entry seeds fresh
        return false
    end

    -- Per-state ceiling / rate / flutter.
    local redline, reengage, rate, flutHz
    if mode == 'free' then
        redline, reengage = fr.Redline or 0.99, fr.ReengageRpm or 0.93
        rate,    flutHz   = fr.RevUpRate or 35.0, fr.FlutterHz or 18.0
    elseif mode == 'soft' then
        -- NEUTRAL NO-LOAD REV LIMIT: cap the free-rev ceiling to a real-rpm range (default 4200-4500),
        -- converted from the 0-8000 display scale to GTA's 0-1 rpm. Per-vehicle: pick a random cap in
        -- the range ONCE per vehicle (cached on HK.softCapVeh/HK.softCapNorm), so different cars cut at
        -- slightly different needles like real engines. Falls back to SoftRedline if the knobs are gone.
        local scale = fr.SoftRevScaleRpm or 8000
        if fr.SoftRevCapMinRpm and fr.SoftRevCapMaxRpm and scale > 0 then
            if HK.softCapVeh ~= veh or HK.softCapNorm == nil then
                local lo, hi = fr.SoftRevCapMinRpm, fr.SoftRevCapMaxRpm
                if hi < lo then lo, hi = hi, lo end
                local pick = (lo == hi) and lo or math.random(math.floor(lo), math.floor(hi))
                HK.softCapNorm = pick / scale
                HK.softCapVeh  = veh
            end
            redline = HK.softCapNorm
        else
            redline = fr.SoftRedline or 0.55
        end
        reengage = fr.SoftReengageRpm or (redline - 0.07)
        if reengage >= redline then reengage = redline - 0.05 end
        rate,    flutHz   = fr.SoftRevUpRate or 20.0, fr.SoftFlutterHz or 12.0
    else -- 'load'
        redline, reengage = fr.LoadRedline or 0.95, fr.LoadReengageRpm or 0.89
        rate,    flutHz   = fr.LoadRevUpRate or 22.0, fr.LoadFlutterHz or 22.0
    end

    HK.freeRevActive = true

    -- ============================================================ REAL GEAR 1 vs BRAKE (free mode)
    -- The painted/torque-cut approaches all felt suppressed because they FAKE the rev. The player's
    -- fix: while holding S (footbrake) in neutral, just BE a real native gear 1 with the brake held —
    -- the engine revs against the brake for real (instant, true redline, native limiter bounce), and
    -- the held brake keeps it planted. On release (brake OR throttle off) the mode drops out of 'free'
    -- and the gearbox takes back over to actual neutral (gear 0). So here we do the OPPOSITE of
    -- suppression: RESTORE full drive force + real torque + native rpm, and let GTA + the brake fight.
    --   * setDriveForce(real) -> genuine gear-1 drive (the gearbox zeroes it every neutral frame, so
    --     we must re-assert the real value AFTER it, every frame we own).
    --   * torqueMult stays 1.0 (NOT cut) -> full engine power = fast native rev.
    --   * force native gear 1 -> real rev model + loaded audio bank.
    --   * NO vl_setRpmRaw -> native rpm drives tach + audio coherently.
    -- Display still shows N (display path reads the neutral flags before the native gear).
    if mode == 'free' then
        if origins and origins.fInitialDriveForce then
            setDriveForce(veh, gbDriveForceLive or origins.fInitialDriveForce)       -- REAL drive force = true gear 1
        end
        if vl_getCurrentGear(veh) ~= 1 then vl_setCurrentGear(veh, 1) end            -- native gear 1
        HK.revPaint = nil                                                            -- native owns rpm; drop accumulator

        -- SUSTAINED-REV CUTOUT ("engine protection"). BUG FIX: the old version accumulated time only
        -- while rpm >= HoldCutRpm, but the native limiter BOUNCES rpm below that each cycle, and the
        -- else-branch reset the timer on every dip — so it never reached HoldCutSec. Count continuous
        -- THROTTLE-HELD time instead (thr is steady while W is down), gated on having actually climbed
        -- into the rev zone at least once (so a gentle part-throttle blip that never revs up won't trip).
        -- Once held past HoldCutSec, LATCH a protective fuel-cut. The latch is cleared only by lifting W,
        -- which exits free mode entirely and runs frRestoreInertia() (resets frHoldMs + frCutActive).
        local cutSec = fr.HoldCutSec or 0.0
        local rpmNow = state.rpm or 0.0
        if cutSec > 0.0 and not HK.frCutActive then
            if rpmNow >= (fr.HoldCutRpm or 0.93) then HK.frRevZoneHit = true end       -- armed once we hit the zone
            if HK.frRevZoneHit then
                HK.frHoldMs = (HK.frHoldMs or 0) + (dt or 0.016) * 1000.0
                if HK.frHoldMs >= cutSec * 1000.0 then HK.frCutActive = true end
            end
        end

        if HK.frCutActive then
            -- PROTECT: kill fuel — no throttle to the engine, no drive torque. The needle falls
            -- naturally (native engine braking) until it drops below HoldRearmRpm and re-arms.
            DisableControlAction(0, 71, true)
            HK.torqueMult = 0.0
        else
            EnableControlAction(0, 71, true)                                          -- let the game rev the engine
            -- INERTIA BOOST — the CORRECT lever for "rev to max faster". fDriveInertia is GTA's engine
            -- rotating-mass float: HIGHER = the engine spins up (and down) faster for the same torque.
            -- MULTIPLY the car's live inertia while free-revving, restore the exact prior value the frame
            -- the gesture ends (HK.frInertiaSaved = restore-once latch). Native + perf-neutral.
            local iBoost = fr.FreeRevInertiaBoost or 1.0
            if iBoost > 1.0 and origins and origins.fDriveInertia then
                if HK.frInertiaSaved == nil then
                    HK.frInertiaSaved = GetVehicleHandlingFloat(veh, 'CHandlingData', 'fDriveInertia')
                                        or origins.fDriveInertia
                end
                vl_setHandling(veh, 'fDriveInertia', HK.frInertiaSaved * iBoost)
            end
        end
        -- ---- HOLD THE NEEDLE (fix the "goes max then drops" sag) ----------------------------------
        -- GTA physics reality: in a REAL gear with the car not moving (brake held), the engine rpm is
        -- derived from wheelspeed x ratio. You floor it and the native engine flares UP fast (real
        -- torque + inertia boost = the good rev-up feel + loaded audio bank), but because wheelspeed
        -- stays ~0 the sim then DRAGS rpm back toward idle -> the sag the player sees. So we let the
        -- native engine do the fast climb, then PIN the needle at the top with vl_setRpmRaw + a limiter
        -- bounce so it holds at max (bouncing off the cut) for as long as W is held. The paint drives
        -- both tach + audio pitch, so it stays screaming; the native engine underneath keeps the loaded
        -- audio bank. No sag, no cut. (When HK.frCutActive is set we skip the pin so the cut can fall.)
        if not HK.frCutActive then
            local cur = HK.revPaint
            if cur == nil then cur = state.rpm or 0.0 end
            if cur >= redline then HK.revBounceOn = true
            elseif cur < reengage then HK.revBounceOn = false end
            local target
            if HK.revBounceOn then
                HK.revFlutterPhase = HK.revFlutterPhase + (dt or 0.016) * flutHz * 6.2831853
                if HK.revFlutterPhase > 6.2831853 then HK.revFlutterPhase = HK.revFlutterPhase - 6.2831853 end
                target = (math.sin(HK.revFlutterPhase) > 0.0) and redline or reengage
            else
                target = redline
            end
            local a  = 1.0 - math.exp(-(dt or 0.016) * rate)
            local nr = cur + (target - cur) * a
            if (target - nr) > 0.0 and (target - nr) < 0.01 then nr = target end
            if nr < 0.0 then nr = 0.0 elseif nr > 1.0 then nr = 1.0 end
            HK.revPaint = nr
            vl_setRpmRaw(veh, nr)                 -- PIN: keep GTA from dragging rpm to idle (no sag)
            HK.dbgBurnout.frRpm = nr
        else
            HK.dbgBurnout.frRpm = state.rpm or 0.0
        end
        HK.dbgBurnout.frBounce = true
        HK.dbgBurnout.frCut    = HK.frCutActive == true
        HK.dbgBurnout.frHoldMs = HK.frHoldMs or 0
        return true
    end

    -- ---- PAINTED PATH (soft / load) ----------------------------------------------------------------
    -- soft = neutral no-brake lazy blip; load = in a real gear already. These keep the integrator: soft
    -- is meant to be gentle, and load already sits in a real gear (native rpm would fight the shift).
    HK.torqueMult = 0.0                                     -- perf-neutral: paint only, no drive force

    -- PERSISTENT PAINTED ACCUMULATOR. CRITICAL: with torque cut to 0 the native engine gets no
    -- throttle, so GetVehicleCurrentRpm (state.rpm) keeps reading ~idle — reading it back as the
    -- integrator's "current" would reset the ramp to idle every frame (the "super slow raise" bug).
    -- Integrate our OWN value instead, seeded from the real needle only when we first take the frame.
    local cur = HK.revPaint
    if cur == nil then cur = state.rpm or 0.0 end

    -- REDLINE BOUNCE hysteresis: climb to redline, then flutter down to reengage and back (fuel-cut).
    if cur >= redline then HK.revBounceOn = true
    elseif cur < reengage then HK.revBounceOn = false end
    local target
    if HK.revBounceOn then
        HK.revFlutterPhase = HK.revFlutterPhase + (dt or 0.016) * flutHz * 6.2831853
        if HK.revFlutterPhase > 6.2831853 then HK.revFlutterPhase = HK.revFlutterPhase - 6.2831853 end
        target = (math.sin(HK.revFlutterPhase) > 0.0) and redline or reengage
    else
        target = redline
    end
    -- FAST RAISE: exp-ease at the per-state rate (well above the flywheel's normal RevUpRate).
    local a  = 1.0 - math.exp(-(dt or 0.016) * rate)
    local nr = cur + (target - cur) * a
    -- snap the last sliver so the scream reads crisp instead of asymptote-crawling at the top
    if (target - nr) > 0.0 and (target - nr) < 0.01 then nr = target end
    if nr < 0.0 then nr = 0.0 elseif nr > 1.0 then nr = 1.0 end
    HK.revPaint = nr
    vl_setRpmRaw(veh, nr)

    HK.dbgBurnout.frRpm    = nr
    HK.dbgBurnout.frBounce = HK.revBounceOn
    return true
end

-- COAST NEUTRAL (mode 0 comfort + EV) — the "hold both shift keys = momentary
-- neutral" gesture for the two GTA-owned-gear modes. Cuts drive so the car coasts
-- and free-revs, exactly like the DCT/manual hold-neutral, but WITHOUT any lasting
-- state: while held we force gear 0 + zero drive force + rate-limited rev-feed; the
-- CALLER restores drive + hands gears back to GTA the frame the keys release. Pure
-- coast button. Returns true while engaged (caller should `return` — skip its own
-- shaping this frame). `origins` drive force is the restore source (owned by us).
local function coastNeutralTick(veh, state, dt)
    -- Force neutral + decouple the wheels (same mechanism as DCT neutral).
    if origins and origins.fInitialDriveForce then setDriveForce(veh, 0.0) end
    HK.torqueMult = 0.0
    if vl_getCurrentGear(veh) ~= 0 then vl_setCurrentGear(veh, 0) end
    -- Flywheel free-rev from the THROTTLE INPUT (GetVehicleThrottleOffset reads ~0 unloaded, so revs
    -- would never climb) — mass-scaled blip up + rev-hang decay down, mirrors the DCT neutral feel.
    local t      = state.throttle or 0.0
    local revMax = (Config.Gearbox.NeutralRevMax or 1.0)
    if (state.speedKmh or 0) > (Config.Gearbox.NeutralRevCapKmh or 5.0) then
        revMax = Config.Gearbox.NeutralRevMaxMoving or 0.55
    end
    local idle   = Config.Gearbox.Flywheel and Config.Gearbox.Flywheel.IdleRpm or 0.20
    local target = idle + (revMax - idle) * t
    if target < idle then target = idle end
    local nr = HK.flywheelRev(state.rpm, target, dt, Config.Gearbox.Flywheel and Config.Gearbox.Flywheel.NeutralDownRatio)
    vl_setRpmRaw(veh, nr)
end

-- Restore drive force after a coast-neutral releases (hand gears back to GTA).
-- Idempotent via setDriveForce's dedupe, so safe to call every non-coast frame.
local function coastNeutralRelease(veh)
    if origins and origins.fInitialDriveForce then
        setDriveForce(veh, gbDriveForceLive or origins.fInitialDriveForce)
    end
end

-- REGEN BRAKING (one-pedal). Called on throttle LIFT for pure EVs (and, gently, for a
-- hybrid in e-mode). Two phases by speed:
--   * ABOVE holdKmh: rearward decel FORCE (feels like engine braking; F = m·a). Scales
--     with speed (ramps to full by ~25 km/h) AND with how far off-throttle
--     you are (feather = partial regen, full lift = full). Never pushes backward.
--   * BELOW holdKmh (still rolling FORWARD): a light all-wheel BRAKE hold so the car
--     parks at a stop instead of creeping — released instantly the moment throttle returns
--     (caller only invokes this while lifted). This is per-frame brake pressure, NOT a
--     handling write, so it can never stick like the drive-force dedupe bug.
-- decelG = target decel in g; hold = brake pressure 0..1 (0 disables the stop-hold).
-- Returns nothing; applies force/brake directly. Caller gates on "throttle lifted".
-- Publishes the live regen intensity to HK.evRegen (0..1) each frame for hk-speedo.
--
-- IMPLEMENTATION NOTE: regen decel is a VELOCITY BLEED (SetEntityVelocity), not a force
-- and not wheel-brake pressure. History: (1) ApplyForceToEntity blew up EVs — it scales
-- by mass internally, so F=m·a became m²·a = millions of N -> launched to 1000+ km/h.
-- (2) SetVehicleWheelBrakePressure is build-dependent/weak on 3570 (diff.lua flags this)
-- and "didn't feel much". A velocity bleed is mass-independent, frame-rate correct via dt,
-- ALWAYS felt, and physically exact (decel in m/s²). We scale the world velocity vector
-- toward zero by decel·dt each frame, preserving direction (so it slows, never redirects).
-- decelG = target deceleration in g. Brake lights + pressure are kept only as a visual/
-- assist. The stop-hold below still uses brake pressure (fine at ~walking speed).

-- REGEN BRAKE-LIGHT gate (real-EV behaviour): light regen coasts DARK; the lights turn on
-- only once regen decel is HARD (>= OnMs2) or the foot brake is pressed. Hysteresis (On/Off
-- m/s²) stops flicker at the threshold. `regenMs2` = the regen decel this frame (nil in the
-- stop-hold phase, which uses HoldLit instead). Lit state persists on HK.regenLightOn so the
-- hysteresis carries across frames. Falls back to always-on if the feature is disabled.
-- NOTE: on the HK table (not a `local function`) — the main chunk is at Lua's 200-local
-- ceiling, so a new top-level local throws "too many local variables". Same pattern as the
-- other HK.* state/helpers in this file.
HK.setRegenBrakeLight = function(veh, regenMs2, pedalBrake, isHold)
    local cfg = Config.Gearbox and Config.Gearbox.RegenBrakeLight
    if not cfg or cfg.Enabled == false then
        SetVehicleBrakeLights(veh, true)   -- legacy: any active regen lights up
        HK.regenLightOn = true
        return
    end
    -- Fresh-lift reset: applyRegen only runs while OFF the throttle, so between regen
    -- sessions (on-gas frames) this isn't called and the latch would go stale. If more
    -- than one frame elapsed since the last call, this is a NEW lift — clear the latch so
    -- the ON threshold (not the lower OFF one) gates the first frame.
    local fc = GetFrameCount()
    if not HK.regenLightFrame or (fc - HK.regenLightFrame) > 1 then HK.regenLightOn = false end
    HK.regenLightFrame = fc
    local lit = false
    -- 1) the real foot brake always lights them (never suppress a genuine pedal press).
    if cfg.PedalAlways ~= false and (pedalBrake or 0.0) > (cfg.PedalThreshold or 0.06) then
        lit = true
    elseif isHold then
        -- 2) stop-hold: a firm deliberate hold — light unless HoldLit is off.
        lit = cfg.HoldLit ~= false
    elseif regenMs2 then
        -- 3) rolling regen: hysteresis around the regulatory threshold.
        local on  = cfg.OnMs2  or 1.3
        local off = cfg.OffMs2 or 1.0
        if HK.regenLightOn then
            lit = regenMs2 >= off            -- already lit: stay lit until it drops below OFF
        else
            lit = regenMs2 >= on             -- dark: only light once it passes ON
        end
    end
    SetVehicleBrakeLights(veh, lit)
    HK.regenLightOn = lit
end

-- STANDSTILL BRAKE LIGHT (2026-08-14): near a stop in a forward gear we DisableControlAction(0,72) to
-- kill S-as-reverse-creep, but that also kills GTA's native brake lamp (it follows control 72). So a
-- held S at low speed showed no brake light. Drive the lamp directly off the physical S key here.
-- SetVehicleBrakeLights is a PER-FRAME override (not a latch) — it must be re-asserted every frame it's
-- called (same as the reverse-gear brake light), else it reverts to native-dark next frame. We only
-- get called inside the standstill window (forwardSpeed < 0.5); once the car rolls past it, control 72
-- goes live again and GTA's native brake-light logic takes back over on its own.
HK.setStandstillBrakeLight = function(veh, on)
    SetVehicleBrakeLights(veh, on and true or false)
end

-- SHARED STANDSTILL S-BRAKE GUARD. The EXACT block the manual/sequential modes use to make S a
-- PURE BRAKE at a standstill — extracted so the automatic modes (comfort auto, DCT-auto, pure EV,
-- hybrid e-mode) get the identical, proven behaviour instead of each re-solving it. In native gear
-- 0 (a stop in D/N) GTA reads control 72 (S) as the reverse-ACCELERATOR, so a held S crawls the car
-- backward / into native reverse — the "S still goes to reverse" bug the key-driven ladder alone
-- couldn't stop (the ladder owns OUR gear, but GTA's own auto box still ran native brake-to-reverse
-- in parallel). Kill native 72 at a stop so S can't select reverse; braking STRENGTH still flows
-- through fBrakeForce, and once rolling (forwardSpeed >= 0.5) 72 goes live so S brakes normally.
-- Also drive the brake lamp directly (disabling 72 kills GTA's native brake light). EXCEPTION: keep
-- 72 LIVE during a W+S burnout/free-rev gesture so the footbrake holds the car planted.
HK.autoStandstillBrake = HK.autoStandstillBrake or function(veh, state)
    -- ONLY the DRIFT-mode burnout (Step-2 wheelspin) needs control 72 LIVE (it uses the native
    -- power-brake to stay planted while frying). The Step-1 FREE-REV (W+S, no drift) plants via
    -- HK.torqueMult=0, so it does NOT need 72 — and leaving 72 live there let native gear 0 + a
    -- held S flash into REVERSE (the "hold S+W, release W -> R for a split then back" bug). So
    -- exempt ONLY the drift burnout; kill 72 for the free-rev gesture like any other stop.
    local burnoutNeeds72 = HK.driftMode and HK.burnoutGestureLive(state)
    if (state.forwardSpeed or 0.0) < 0.5 and not burnoutNeeds72 then
        DisableControlAction(0, 72, true)
        HK.setStandstillBrakeLight(veh, (HK._pedalBrake or 0.0) > 0.05)
    end
end

local function applyRegen(veh, state, decelG, holdKmh, holdPressure, forceScale, liftFrac, dt)
    local kmh = state.speedKmh or 0.0
    local fwd = state.forwardSpeed or 0.0
    if fwd <= 0.05 then return end          -- only when moving FORWARD (reverse untouched)

    local n = state.wheelCount or GetVehicleNumberOfWheels(veh)

    if kmh > (holdKmh or 8.0) then
        -- DECEL (rolling): bleed speed by a·dt. Real Tesla regen holds a STEADY ~0.2g from
        -- highway speed all the way down to ~15 km/h (the sustained "engine-brake" feel),
        -- then tapers into the friction-hold. So the force is CONSTANT across the band — it
        -- does NOT weaken as you slow (that was the old bug: it faded out and felt like
        -- nothing). Only liftFrac scales it (feather = partial). A short taper over the last
        -- few km/h before the hold avoids a hard jolt into the stop-hold.
        local taper = 1.0
        local tp = (holdKmh or 8.0) + 7.0            -- begin easing ~7 km/h above the hold speed
        if kmh < tp then taper = kmh / tp end        -- smooth handoff into the friction hold

        -- CORNERING REGEN REDUCTION. Real EVs ramp regen DOWN under lateral load so a
        -- lift-off mid-corner doesn't dump weight forward -> understeer/snap. Lateral accel
        -- = |yawRate * speed| (v·ω, m/s²), the physically-correct measure (robust to input
        -- method). Below LoG = full regen; between Lo and Hi = fade toward MinMult; above
        -- Hi = clamped at MinMult. Smoothed (regenCornerMult) with a short attack/release so
        -- entering/exiting a corner ramps over ~0.2-0.4s instead of snapping.
        -- Hybrids use their OWN cornering-regen profile (they keep more engine brake in corners);
        -- pure EVs use the EV profile.
        local CR = isHybrid and (Config.Gearbox.Hybrid and Config.Gearbox.Hybrid.CornerRegen)
                   or (Config.Gearbox.EV and Config.Gearbox.EV.CornerRegen)
        if CR and CR.Enabled ~= false then
            local latA   = math.abs((state.yawRate or 0.0) * (state.speed or 0.0))  -- m/s² lateral
            local loMs2  = (CR.LoG or 0.40) * 9.81
            local hiMs2  = (CR.HiG or 0.90) * 9.81
            local minM   = CR.MinMult or 0.35
            local targetM = 1.0
            if latA > hiMs2 then
                targetM = minM
            elseif latA > loMs2 then
                local t = (latA - loMs2) / math.max(hiMs2 - loMs2, 0.01)
                -- QUADRATIC fade (t^2): mild/moderate corners keep nearly full regen, the cut
                -- ramps in only as you approach the grip limit (feels much less 'coasty' than a
                -- flat linear fade that bled evenly across the whole band).
                targetM = 1.0 - (1.0 - minM) * (t * t)
            end
            -- smooth toward target (attack faster than release feels natural entering a bend)
            local tau = (targetM < regenCornerMult) and (CR.AttackTau or 0.15) or (CR.ReleaseTau or 0.30)
            local dd  = dt or GetFrameTime() or 0.016
            regenCornerMult = regenCornerMult + (targetM - regenCornerMult) * (1.0 - math.exp(-dd / tau))
        else
            regenCornerMult = 1.0
        end

        -- ATTACK RAMP: a real EV/hybrid SPOOLS regen up over a fraction of a second, it does not
        -- slam to full decel the instant you lift. Without this the decel hits its target (e.g.
        -- 0.22g*9.81 = 2.16 m/s²) on frame ONE — already past OnMs2 (1.3) — so the brake light
        -- gates ON with no delay (the "light comes up instantly" bug). Ramping w from 0->1 over
        -- RampUpMs means the decel (and thus the light-gate input `a`) climbs gradually, so the
        -- lamp stays dark until the ramp carries `a` across OnMs2 (~a few hundred ms), exactly
        -- like a real car. Self-resets between lifts: applyRegen only runs off-throttle, so if a
        -- frame was skipped (on-gas) we treat this as a fresh lift and restart the ramp at 0.
        local cfgRL = Config.Gearbox and Config.Gearbox.RegenBrakeLight
        local fcNow = GetFrameCount()
        if not HK.regenRampFrame or (fcNow - HK.regenRampFrame) > 1 then HK.regenRamp = 0.0 end
        HK.regenRampFrame = fcNow
        local rampMs = (cfgRL and cfgRL.RampUpMs) or 350
        local dRamp  = dt or GetFrameTime() or 0.016
        if rampMs and rampMs > 0 then
            HK.regenRamp = math.min(1.0, HK.regenRamp + dRamp * 1000.0 / rampMs)
        else
            HK.regenRamp = 1.0
        end

        -- POWER-LIMITED REGEN (speed-dependent decel, the real motor law): a motor/inverter can
        -- only pull so many kW, and Power = Torque × angular-speed. Below a BASE speed the motor
        -- makes its full torque (constant decel g — the strong city/one-pedal feel). ABOVE the base
        -- speed torque is power-capped, so it falls ~ base/v — the SAME lift makes MILDER decel on
        -- the highway than in town. This is exactly why a real EV's brake light comes on readily in
        -- the city but only with a hard lift (or not at all) at 120 km/h — the DECEL crossing the
        -- fixed 1.3 m/s² threshold is what's speed-dependent, not the threshold. Multiplies into w so
        -- both the felt decel AND the light-gate input scale together. Clamped to a floor so highway
        -- regen never vanishes entirely. Toggle via RegenBrakeLight.SpeedFalloff (Enabled/BaseKmh/
        -- MinMult); disabled = old flat constant-g at all speeds.
        local speedMult = 1.0
        if cfgRL and cfgRL.SpeedFalloff and cfgRL.SpeedFalloff.Enabled ~= false then
            local baseKmh = cfgRL.SpeedFalloff.BaseKmh or 50.0
            local minM    = cfgRL.SpeedFalloff.MinMult or 0.45
            if kmh > baseKmh and baseKmh > 0 then
                speedMult = baseKmh / kmh                 -- constant-POWER: torque ~ 1/v above base
                if speedMult < minM then speedMult = minM end
            end
        end

        local w  = (liftFrac or 1.0) * taper * regenCornerMult * HK.regenRamp * speedMult   -- steady, minus corner fade, spooled by ramp, power-limited by speed
        local a  = (decelG or 0.30) * 9.81 * w * (forceScale or 1.0)   -- m/s² this frame
        local d  = dt or GetFrameTime() or 0.016
        local spd = math.sqrt(state.velocity.x^2 + state.velocity.y^2 + state.velocity.z^2)
        if spd > 0.1 then
            local newSpd = spd - a * d
            if newSpd < 0.0 then newSpd = 0.0 end
            local k = newSpd / spd                                   -- scale factor (preserves direction)
            SetEntityVelocity(veh, state.velocity.x * k, state.velocity.y * k, state.velocity.z * k)
        end
        -- BRAKE-LIGHT GATING (real-EV behaviour): light regen coasts DARK; the lights only
        -- come on once the regen decel is genuinely HARD (>= OnMs2), or the driver presses
        -- the foot brake. `a` is the regen decel this frame (m/s²). Hysteresis (On/Off) so
        -- a steady lift right at the threshold doesn't flicker the lights. MUST run BEFORE the
        -- wheel-brake-pressure loop below — see next comment.
        HK.setRegenBrakeLight(veh, a, state.brake or 0.0, false)
        -- Brake lights only — a SMALL FIXED pressure so it doesn't stack extra decel on top
        -- of the velocity bleed (that made DecelG lie: 0.40 set -> ~0.78g actual). The bleed
        -- above is the sole decel actuator now, so DecelG maps honestly to felt slowdown.
        -- GATED on the light decision (HK.regenLightOn): applying ANY wheel brake pressure makes
        -- GTA light the brake lamps NATIVELY, independent of SetVehicleBrakeLights(false) — so
        -- this loop was defeating the whole soft-regen suppression (lamps lit instantly on any
        -- lift). Only apply it when the gate actually wants the lamps ON (hard regen / pedal);
        -- under light coast we apply NO pressure so the lamps stay dark. (The velocity bleed is
        -- the sole decel actuator regardless, so skipping this changes no felt slowdown.)
        if HK.regenLightOn then
            for i = 0, n - 1 do vl_brakeWheel(veh, i, 0.08 * w) end
        end
        if Config.Gearbox.Debug then
            print(('[hk-regen] kmh=%.0f w=%.2f corner=%.2f latG=%.2f decelG=%.2f a=%.1fm/s^2 spd=%.1f->%.1f')
                :format(kmh, w, regenCornerMult, math.abs((state.yawRate or 0)*(state.speed or 0))/9.81,
                        decelG or 0.30, a, spd, math.max(0, spd - a * d)))
        end
        -- SIGNAL: normalise intensity against a "full" reference (0.30g) so a light hybrid
        -- coast reads low and a strong one-pedal reads near 1.0 on the gauge.
        HK.evRegen.level   = math.min(1.0, ((decelG or 0.3) * w) / 0.30)
        HK.evRegen.holding = false
        HK.evRegen.active  = true
    elseif (holdPressure or 0) > 0 then
        -- STOP-HOLD PHASE: plant all wheels so the car parks (one-pedal hold).
        for i = 0, n - 1 do vl_brakeWheel(veh, i, holdPressure) end
        -- Stop-hold is a firm, deliberate hold (car actively kept stopped), so light the
        -- lights (HoldLit) — unless disabled — plus always for a real pedal press.
        HK.setRegenBrakeLight(veh, nil, state.brake or 0.0, true)
        HK.evRegen.level   = 1.0
        HK.evRegen.holding = true
        HK.evRegen.active  = true
    end
end

-- REVERSE GATE state machine (shared: EV + DCT-auto). Realistic modern-auto behaviour:
-- brake to a stop -> NEUTRAL (free-roll); it STAYS neutral until you either press throttle
-- (leave forward) or RELEASE-then-PRESS the brake again (engage reverse). A continuously
-- held brake never rolls into reverse on its own. Returns the resolved gate state
-- ('none'|'neutral'|'reverse'); caller acts on it per mode. Pure logic — no writes here.
--   veh/state = current; forward = are we (or were we) going forward.
-- Full R<->N<->D state machine. Returns 'none'(=forward/D) | 'neutral' | 'reverse'.
-- Edge-armed so a step needs a FRESH press (not a held input carrying through), EXCEPT a
-- held W in reverse auto-walks R->N->D on a short dwell so you can just pull away.
--   FWD:  hold S to a stop           -> NEUTRAL   (free-roll)
--   N:    release S, press S again   -> REVERSE
--   R:    press W                    -> NEUTRAL   (then, still holding W past revWalkAt -> D)
--   N(from R): press W               -> D (gear 1) — or the held-W auto-walk does it
--   any:  a fresh W from a standstill in N/none forward = normal drive
-- ROBUST handbrake read AT POINT OF USE. Don't trust state.handbrake alone: if the state
-- feed (or a resource that DisableControlAction's control 76) reports it false while the
-- player is holding space, launch staging / neutral hold breaks and the car drives off. OR
-- together every reliable signal: the cached state flag, the live pressed read (normal +
-- disabled), and the native vehicle handbrake. This makes launch staging independent of the
-- vehlib version loaded / its restart order.
local function hbHeld(state, veh)
    if state and state.handbrake == true then return true end
    if IsControlPressed(0, 76) or IsDisabledControlPressed(0, 76) then return true end
    if veh and veh ~= 0 and GetVehicleHandbrake(veh) then return true end
    return false
end

-- (DIRECT GEAR-1 ENGAGE helper removed 2026-08-14 v3 — it was only used by the deleted bespoke
-- wheelspin-neutral fire block. The wheelspin "pull away" launch now goes through launchStageTick's
-- normal handbrake-release fire, which engages 1st via each mode's own beginShift(1)/requestGear(1)
-- path, so no direct raw targetGear poke exists to desync the shift state machine.)

-- W+S GESTURE DETECT (live inputs) — shared by the reverse-gate and the two near-standstill
-- control-72 disable sites. burnout.lua runs AFTER the gearbox, so HK.freeRevActive /
-- HK.burnoutActive lag a frame; a fresh S press at a stop would (a) trip the reverse-gate to
-- NEUTRAL and (b) get its footbrake killed by DisableControlAction — before those flags flip.
-- Both W+S features NEED the brake live in gear: free-rev (no drift) holds the car planted while
-- it screams; wheelspin (drift) power-brakes while the rears fry. Detect BOTH from live inputs so
-- the guards never depend on the lagging flags. Returns true if EITHER gesture is currently held.
-- On HK.* (not a file local) — the main chunk is at Lua's 200-local ceiling.
HK.burnoutGestureLive = HK.burnoutGestureLive or function(state)
    if HK.burnoutActive == true or HK.freeRevActive == true then return true end
    local B = Config.Burnout
    if not B or B.Enabled == false then return false end
    -- Read the HARDWARE pedals. THROTTLE (W) via the disabled-control natives (a forward-gear stop
    -- disables 71). BRAKE (S) via the PHYSICAL key HK._pedalBrake, NOT control 72: the reverse rework
    -- now permanently DISABLES control 72 at a standstill (S = pure brake), so both control reads return
    -- 0 when S is held and the gesture could never arm (deadlock — the "slow rev, no piu-piu" bug). The
    -- pedal model sets HK._pedalBrake from the raw scan code every frame, immune to DisableControlAction.
    local thr = math.max(GetControlNormal(0, 71), GetDisabledControlNormal(0, 71))
    local brk = HK._pedalBrake or math.max(GetControlNormal(0, 72), GetDisabledControlNormal(0, 72))
    local kmh = state.speedKmh or 0.0
    local drift = HK.driftMode == true
    -- STEP-2 wheelspin (2026-08-16): drift + W, S OPTIONAL (planted modifier only). Guard matches the
    -- new trigger — brake no longer required to arm, so the control-72 guards hold whether or not S is
    -- down. Up to its sustain cap.
    local ws = B.Wheelspin
    if ws and ws.Enabled ~= false and drift
        and thr >= (ws.MinThrottle or 0.55)
        and kmh <= (ws.MaxSpeedKmh or 80.0) then
        return true
    end
    -- STEP-1 free-rev: NO drift + W + S, near standstill.
    local fr = B.FreeRev
    if fr and fr.Enabled ~= false and not drift
        and thr >= (fr.MinThrottle or 0.5)
        and brk >= (fr.BrakeGate or 0.5)
        and kmh <= (fr.MaxKmh or 5.0) then
        return true
    end
    return false
end

-- DOUBLE-TAP W DETECT (automatic modes) — a quick release+press+release+press of the THROTTLE
-- while in neutral is a "pull away" gesture: it re-engages gear 1, exactly like the UPSHIFT key.
-- Edge-tracked off the physical throttle pedal (HK._pedalThrottle, immune to DisableControlAction)
-- so it fires even while neutral has thrown control 71/72. Two RISING edges within DoubleTapMs =
-- the gesture. Call ONCE per frame per mode (it advances shared HK.* edge state). Returns true on
-- the frame the second tap lands. On HK.* — the main chunk is at Lua's 200-local ceiling.
HK.autoDoubleTapW = HK.autoDoubleTapW or function(winMs)
    local now = GetGameTimer()
    local thrOn = (HK._pedalThrottle or 0.0) > (Config.Gearbox.ThrottleTapPress or 0.5)
    local fired = false
    if thrOn and not HK.autoWThrPrev then           -- rising edge of W
        if HK.autoWTapAt and (now - HK.autoWTapAt) <= (winMs or 250) then
            fired = true                            -- second tap inside the window
            HK.autoWTapAt = nil                     -- consume so a third press doesn't re-fire
        else
            HK.autoWTapAt = now                     -- first tap; arm the window
        end
    end
    HK.autoWThrPrev = thrOn
    return fired
end

-- DOUBLE-TAP S DETECT (automatic modes) — mirror of autoDoubleTapW for the BRAKE pedal. A fresh
-- single S press while stopped used to drop straight into NEUTRAL, which tripped by accident on any
-- stop-and-hold / creep brake. Require TWO quick S taps instead (release+press+release+press within
-- NeutralBrakeDoubleTapMs) so neutral is a deliberate gesture. Edge-tracked off the PHYSICAL brake
-- pedal (HK._pedalBrake, immune to DisableControlAction) so it fires even while neutral throws the
-- brake control. Call ONCE per frame per mode (advances shared HK.* edge state); returns true on the
-- frame the second tap lands. On HK.* — the main chunk is at Lua's 200-local ceiling.
HK.autoDoubleTapS = HK.autoDoubleTapS or function(winMs)
    local now = GetGameTimer()
    local brkOn = (HK._pedalBrake or 0.0) > 0.5
    local fired = false
    if brkOn and not HK.autoSBrkPrev then           -- rising edge of S
        if HK.autoSTapAt and (now - HK.autoSTapAt) <= (winMs or 300) then
            fired = true                            -- second tap inside the window
            HK.autoSTapAt = nil                     -- consume so a third press doesn't re-fire
        else
            HK.autoSTapAt = now                     -- first tap; arm the window
        end
    end
    HK.autoSBrkPrev = brkOn
    return fired
end

local function updateReverseGate(state)
    if not (Config.Gearbox.ReverseGate and Config.Gearbox.ReverseGate.Enabled ~= false) then
        revGate, revBrakeArmed, revThrArmed = 'none', false, false
        return 'none'
    end
    local RG    = Config.Gearbox.ReverseGate
    local kmh   = state.speedKmh or 0.0
    local thr   = state.throttle or 0.0
    -- BURNOUT GUARD: the W+S wheelspin gesture is drift + throttle + BRAKE (S). But S is the footbrake,
    -- and at a stop a fresh S press would trip THIS gate to NEUTRAL (gear 0) — and the burnout needs
    -- gear >= 1, so it'd deadlock. We must detect the gesture from its LIVE inputs (not HK.burnoutActive,
    -- which lags a frame since burnout.lua runs AFTER the gearbox) and ignore brake so the box stays in
    -- gear. Gesture = drift mode + real throttle + brake held, at low speed (matches burnout.lua's gate).
    -- Both W+S gestures (Step-1 free-rev AND Step-2 wheelspin) need to STAY in gear, so ignore the
    -- brake for the gate while either is held. Detected from LIVE inputs (flags lag a frame).
    local burnoutIntent = HK.burnoutGestureLive(state)
    local brake = burnoutIntent and 0.0 or (state.brake or 0.0)
    local fwd   = state.forwardSpeed or 0.0
    local now   = GetGameTimer()
    local stopKmh   = RG.StopKmh or 2.0
    local brakeOn   = brake > (RG.BrakePress or 0.5)
    local thrOn     = thr   > (RG.ThrottleExit or 0.15)
    local walkMs    = RG.WalkStepMs or 220       -- dwell so the speedo shows N between R and D

    if revGate == 'none' then
        -- Track real forward motion so brake-to-N triggers after actually driving.
        if kmh > (stopKmh + 1.0) then revWasMoving = true end
        -- BRAKE RISING EDGE (off->on this frame). This is the precise "the driver just asked to
        -- stop/reverse" signal that revWasMoving was a crude proxy for. A HELD brake carrying over
        -- (e.g. right after a tap-out-of-neutral) is NOT an edge, so it can't snap back into N —
        -- which is exactly the re-entry that revWasMoving was added to block.
        local brakeEdge = brakeOn and not HK.revBrakePrev
        -- ENTER neutral when braked to a near-stop. Two admit paths:
        --   (a) revWasMoving  — the classic decel-to-stop (we were rolling, brake brought us in).
        --   (b) brakeEdge     — a FRESH brake press while already stopped in forward. This is the
        --       reverse-entry FIX: on a fresh entry / post-crash settle / just-dropped gear,
        --       revWasMoving is false (resetShiftState cleared it), so a standstill S-press never
        --       reached the gate and GTA's native brake-to-reverse fought our forward gear-1 logic
        --       = the "in gear 1 but limited reverse" misfire. An edge admits it cleanly.
        if brakeOn and kmh <= stopKmh and fwd > -0.5 and (revWasMoving or brakeEdge) then
            revGate = 'neutral'
            revBrakeArmed = false        -- must release brake before R can arm
            revThrArmed   = not thrOn    -- arm throttle only if not currently pressed
            revWasMoving  = false        -- consumed
            revNFromReverse = false      -- entered N from FORWARD -> throttle drives off immediately
        end
        -- else: driving forward, nothing to do (throttle drives normally).

    elseif revGate == 'neutral' then
        -- HANDBRAKE HELD = STAY IN NEUTRAL (never transition to R or D). This both holds a
        -- stable neutral for launch staging AND stops the 'throttle in neutral jumps to a gear'
        -- bug — while the e-brake is held you're parked/staging, so nothing exits neutral. Launch
        -- staging then runs off this stable neutral. (Was gated on throttle too, which let a
        -- frame slip through before staging; handbrake-only is the robust gate.)
        local staging = hbHeld(state, state.vehicle)
        if not staging then
            -- Free-roll neutral. Two exits: fresh brake -> R, fresh throttle -> D (forward).
            if not brakeOn then revBrakeArmed = true end
            if not thrOn  then revThrArmed  = true end
            if brakeOn and revBrakeArmed then
                revGate = 'reverse'
                revThrArmed = false          -- re-arm throttle for the R->N exit later
                revWalkAt = 0
                revNFromReverse = true       -- (about to be in R; next R->N sets this too)
            elseif thrOn and (revThrArmed or not revNFromReverse) then
                -- Throttle from neutral -> drive off forward. If we reached N from a FORWARD
                -- brake-stop (revNFromReverse false), a press drives off IMMEDIATELY — no
                -- release-then-press re-arm needed (that strict rule is only to stop a HELD W
                -- auto-walking R->N->D). Without this, low-speed stop-and-go creep (dip under
                -- StopKmh with throttle still feathered) dropped to latched-N and couldn't
                -- re-engage = the "stuck between N and 1" bug.
                revGate = 'none'
                revBrakeArmed, revThrArmed = false, false
            end
        else
            -- while staging, keep the arms fresh so a post-launch exit behaves cleanly
            revBrakeArmed, revThrArmed = false, false
        end

    elseif revGate == 'reverse' then
        -- Backing up. A throttle press steps R -> NEUTRAL; a HELD throttle then auto-walks
        -- N -> D after walkMs (so the speedo visibly passes through N). A fresh tap also works.
        if not thrOn then
            revThrArmed = true           -- released -> a fresh press will step
        elseif revThrArmed then
            revGate = 'neutral'
            revThrArmed = false          -- consumed this press
            revWalkAt = now + walkMs     -- if W stays held, walk N->D after the dwell
            revNFromReverse = true       -- came from R -> keep the strict re-arm (R->N->D walk)
        end
    end

    -- HELD-W AUTO-WALK: if we stepped R->N on a still-held throttle, continue N->D once the
    -- dwell elapses (no need to release+re-press to pull away). Only while W remains held.
    -- HANDBRAKE OVERRIDE: if the handbrake is grabbed mid-walk (e.g. to stage a launch), do NOT
    -- auto-walk into forward drive — that defeats the staging guard and drives off under the
    -- handbrake. Cancel the pending walk and hold neutral so staging can own it.
    if revGate == 'neutral' and thrOn and not revThrArmed and revWalkAt > 0 and now >= revWalkAt then
        if hbHeld(state, state.vehicle) then
            revWalkAt = 0            -- handbrake held -> cancel the walk, stay in neutral (staging owns it)
        else
            revGate = 'none'
            revBrakeArmed, revThrArmed, revWalkAt = false, false, 0
        end
    end

    -- Track brake state for next frame's rising-edge test (see the 'none' branch). Kept on HK.*
    -- (not a file local) — the main chunk is at Lua's 200-local ceiling.
    HK.revBrakePrev = brakeOn

    -- DEBUG: publish the live gate internals so /handlingdbg can show WHY a step did or didn't
    -- fire (the reverse-entry misfire after a gear-drop/fresh-entry/crash). Zero-cost when off.
    if HK.hdbgOn then
        local d = HK.dbgRevGate or {}
        HK.dbgRevGate = d
        d.state    = revGate
        d.brakeArm = revBrakeArmed
        d.thrArm   = revThrArmed
        d.wasMoving= revWasMoving
        d.nFromRev = revNFromReverse
        d.brakeOn  = brakeOn
        d.thrOn    = thrOn
        d.kmh      = kmh
        d.fwd      = fwd
        d.at       = now
    end

    return revGate
end

-- ── KEY-DRIVEN AUTO REVERSE (2026-08-14 rework #2) ──────────────────────────────────────
-- Shared by ALL automatic modes (comfort auto, DCT-auto, hybrid e-mode, pure EV). Replaces
-- the S-brake "brake-to-N -> press-S-again" gate: S is a PURE BRAKE now. Reverse is reached
-- by the DOWNSHIFT key (walk D->N->R) and left by the UPSHIFT key (walk R->N->D), EXACTLY
-- like the manual/sequential ladder. Once in reverse the car DRIVES by velocity via the same
-- HK.ReverseDrive_Tick the manuals use (W = accelerate backward, S = brake) — no native
-- brake-to-reverse anywhere. Two file-scope helpers on HK.* (the main chunk is at Lua's 200-
-- local ceiling, so shared state/functions live on the HK table):
--
--   HK.autoRevSel   'D' | 'N' | 'R'  — the key-driven selector for automatic modes. Distinct
--                   from the legacy revGate (kept for the launch-staging paths + display).
--   HK.autoReverseDrive(veh, state, dt)  — set up a velocity-driven reverse frame for an auto:
--                   pin native gear 0, restore drive force, disable controls 71/72 for the
--                   keyboard pedal model (so W/S go to ReverseDrive_Tick, not native reverse),
--                   paint the reverse rpm needle. Mode-agnostic; keys only off being "in R".
--   HK.autoRevLadder(state, up, down, nToRMaxKmh)  — advance HK.autoRevSel one step per fresh
--                   key press. up steps toward D, down steps toward R. Returns the new sel.
HK.autoRevSel = HK.autoRevSel or 'D'

-- Reset the auto reverse selector to Drive (called on enable / vehicle change / mode switch).
HK.autoRevReset = HK.autoRevReset or function()
    HK.autoRevSel = 'D'
end

-- Advance the D/N/R selector by fresh key presses. up = UPSHIFT tap (toward D), down = DOWNSHIFT
-- tap (toward R). N->R is speed-gated (like the manual realistic-reverse rule) so you can't slam
-- reverse at speed. Ladder: D <-(up)- N <-(up)- R and D -(down)-> N -(down)-> R.
HK.autoRevLadder = HK.autoRevLadder or function(state, up, down, nToRMaxKmh)
    local kmh = (state and state.speedKmh) or 0.0
    if down then
        if     HK.autoRevSel == 'D' then HK.autoRevSel = 'N'
        elseif HK.autoRevSel == 'N' then
            -- N -> R only when nearly stopped (safety). Otherwise stay in N.
            if kmh <= (nToRMaxKmh or 8.0) then HK.autoRevSel = 'R' end
        end
        -- already R: down does nothing (can't stack reverse)
    elseif up then
        if     HK.autoRevSel == 'R' then HK.autoRevSel = 'N'
        elseif HK.autoRevSel == 'N' then HK.autoRevSel = 'D'
        end
        -- already D: up does nothing
    end
    return HK.autoRevSel
end

-- Set up ONE velocity-driven reverse frame for an automatic mode. Mirrors the manual/seq
-- reverse-gear block: pin native 0, drive force live, disable 71/72 for the keyboard pedal
-- model (motion then comes from HK.ReverseDrive_Tick), paint the reverse rpm. For analog/off
-- input, block only forward throttle and let ReverseCap_Tick cap the native reverse. Caller
-- passes the resolved origins/gbDriveForceLive drive force. Returns nothing (side effects).
HK.autoReverseDrive = HK.autoReverseDrive or function(veh, state, dt, driveForce)
    HK.inReverseGear = true
    if vl_getCurrentGear(veh) ~= 0 then vl_setCurrentGear(veh, 0) end
    if driveForce then setDriveForce(veh, driveForce) end
    local injecting = HK.pedalModelOn and not HK._injAnalog and not HK.driftMode
    if injecting then
        -- Kill BOTH native throttle/brake/reverse; HK.ReverseDrive_Tick drives by velocity.
        DisableControlAction(0, 71, true)
        DisableControlAction(0, 72, true)
    elseif (state.forwardSpeed or 0.0) > -2.0 then
        DisableControlAction(0, 71, true)   -- analog/off: native S-reverse applies, block W-accel
    end
    -- REVERSE rev-feed (same as the manual/seq painted short-reverse gear): revs track the W
    -- throttle toward a modest ceiling. state.throttle = physical W (vehicle offset reads ~0
    -- while our injection drives the velocity). Idle when W released (engine-brake coast).
    local cfgR   = Config.Gearbox
    local t      = state.throttle or 0.0
    local idle   = (cfgR.Flywheel and cfgR.Flywheel.IdleRpm) or 0.20
    local revMax = cfgR.ReverseRevMax or 0.55
    local target = idle + (revMax - idle) * t
    if target < idle then target = idle end
    local cur    = state.rpm or idle
    local rising = target > cur
    local rate   = (rising and (cfgR.ReverseRevRaiseRate or 4.0)
                            or (cfgR.ReverseRevFallRate or 6.0)) * (dt or 0.016)
    if rate > 1.0 then rate = 1.0 end
    local nr = cur + (target - cur) * rate
    if nr < 0.0 then nr = 0.0 elseif nr > 1.0 then nr = 1.0 end
    vl_setRpmRaw(veh, nr)
end

-- LAUNCH PROFILE RESOLVER. The launch machinery reads its knobs from a single RESOLVED table
-- (HK.launchProfile), not straight from Config.Gearbox.Launch, so a launch can be tuned per
-- DRIVE CLASS (rwd/awd/fwd) and per MANUAL box without branching every read site. Merge order
-- (later wins): base Launch  ->  Launch.Drivetrain[class]  ->  Launch.Manual (if gearMode 1).
-- Nested TractionControl / GripAssist are shallow-merged the same way. Resolved ONCE at stage
-- time (cheap; class is static per car) and cached on HK.launchProfile. `launchCfg()` returns
-- it, falling back to the raw base table if a launch hasn't staged yet (e.g. computeLaunchRpm
-- called cold). Class read from HK.dbgDrive.class (published by drivetrain.lua each frame).
-- On HK.* (not a main-chunk local) — gearbox.lua's main function is at Lua's 200-local ceiling.
HK.launchCfg = HK.launchCfg or function()
    return HK.launchProfile or Config.Gearbox.Launch or {}
end

HK.resolveLaunchProfile = HK.resolveLaunchProfile or function()
    local base = Config.Gearbox.Launch or {}
    -- shallow copy of base scalars
    local p = {}
    for k, v in pairs(base) do
        if type(v) ~= 'table' then p[k] = v end
    end
    -- nested blocks start as copies of the base nested tables
    local function copyTbl(t) local o = {}; if type(t) == 'table' then for k, v in pairs(t) do o[k] = v end end; return o end
    p.TractionControl = copyTbl(base.TractionControl)
    p.GripAssist      = copyTbl(base.GripAssist)

    -- overlay a source block (drivetrain[class] or Manual) onto p
    local function overlay(src)
        if type(src) ~= 'table' then return end
        for k, v in pairs(src) do
            if k == 'TractionControl' or k == 'GripAssist' then
                if type(v) == 'table' then for kk, vv in pairs(v) do p[k][kk] = vv end end
            elseif type(v) ~= 'table' then
                p[k] = v
            end
        end
    end

    -- DRIVE-CLASS block
    local class = HK.dbgDrive and HK.dbgDrive.class    -- 'rwd' | 'awd' | 'fwd' | nil
    if class and base.Drivetrain and base.Drivetrain[class] then
        overlay(base.Drivetrain[class])
    end
    -- MANUAL block (gearMode 1 only) wins last so a manual override beats the class default
    if gearMode == 1 and base.Manual then
        overlay(base.Manual)
    end

    -- WHEELIE-RWD overlay (2026-08-14): if THIS car is a wheelie-flagged RWD, bias the launch
    -- toward a clean nose-lift (stage a hair lower, allow a bit more rear squat/slip) instead of a
    -- flat grip-max launch that fights the weight transfer. Overlaid LAST so it wins over the rwd
    -- class defaults. Wheelie is RWD-only, so gate on both the flag and class=='rwd'.
    -- curVeh (module local, updated on enter/leave) is the current vehicle; driverVeh() is declared
    -- LATER in the file so it's a nil global here and would silently no-op the overlay. resolveLaunchProfile
    -- only runs at stage time with a car present, so curVeh is valid.
    if curVeh ~= 0 and class == 'rwd' and base.Wheelie then
        local mk = GetEntityModel(curVeh) & 0xFFFFFFFF
        local wl = HK.manualModels and HK.manualModels[mk] and HK.manualModels[mk].wheelieLaunch
        if wl == 1 then
            overlay(base.Wheelie)
            p.dbgWheelieLaunch = true
        end
    end

    p.dbgClass  = class or 'n/a'
    p.dbgManual = (gearMode == 1)
    HK.launchProfile = p
    return p
end

-- Compute the per-car optimal LAUNCH RPM (0..1) — the highest staged rpm that hooks up
-- without frying the tyres. Derived from gear 1's learned ratio (gbRpmPerSpeed[1] = rpm per
-- km/h in 1st): a SHORT 1st gear (high rpm/kmh) multiplies torque hard at the wheel, so it
-- needs a LOWER launch rpm to avoid spin; a tall 1st can launch higher. We map that to a
-- band [LaunchRpmMin..LaunchRpmMax] and scale by TractionFactor (global aggression knob;
-- custom cars vary, so it's tunable). Falls back to a safe mid value if 1st isn't learned.
local function computeLaunchRpm(veh)
    local L = HK.launchCfg()
    local lo = L.LaunchRpmMin or 0.70
    local hi = L.LaunchRpmMax or 0.92
    local rps1 = gbRpmPerSpeed[1]
    local base
    if rps1 and rps1 > 0 then
        -- rps1 ~ 0.02 (very tall) .. 0.10 (very short) in normalised-rpm per km/h across the
        -- fleet. Higher rps1 (shorter gear = more wheel torque) -> lower launch rpm. Map the
        -- typical 0.03..0.09 span onto [hi..lo] (inverted), clamped.
        local t = (rps1 - 0.03) / (0.09 - 0.03)
        if t < 0 then t = 0 elseif t > 1 then t = 1 end
        base = hi - (hi - lo) * t
    else
        base = (lo + hi) * 0.5                    -- unlearned 1st -> safe middle
    end
    base = base * (L.TractionFactor or 1.0)
    -- With traction control catching spin, you can stage a touch below redline for a cleaner
    -- initial hook (optional; 0 by default keeps the near-redline stage that matches a manual launch).
    local TC = L.TractionControl
    if TC and TC.Enabled ~= false and (TC.LaunchRpmDrop or 0) > 0 then
        base = base - TC.LaunchRpmDrop
    end
    -- PER-MODEL LEARNED TRIM: the gear-1 estimate above is grip-blind; this additive offset (built
    -- from measured slip after each pull, see launchLearnTrim) corrects it toward the car's real
    -- fastest hook. Spin-prone cars accumulate a negative trim (launch lower), bog-prone a positive
    -- one (launch higher). Applied BEFORE the band clamp so it can't push outside [lo..hi].
    if veh and L.LearnRpm ~= false then
        -- inline model hash (modelKey is a local declared later in the file, not visible here)
        local mk   = GetEntityModel(veh) & 0xFFFFFFFF
        local trim = HK.launchRpmTrim and HK.launchRpmTrim[mk]
        if trim then base = base + trim end
    end
    if base < lo then base = lo elseif base > hi then base = hi end
    return base
end

-- Publish the launch state for HUDs (hk-speedo status box, etc.).
local function launchPublish()
    HK.launch.active = (lcPhase ~= 'off')
    HK.launch.phase  = lcPhase
    HK.launch.rpm    = (lcPhase == 'staged') and lcTargetRpm or 0.0
end

-- LC ENGAGE REAL GEAR 1 (2026-08-14 v6, user: "a launch control can be engaged from neutral, but to be
-- ready to actually launch it should be in gear 1 anyway ... after engage ready (red pill) it should
-- upshift to gear 1. have the launch control do the upshift for the player"). This AUTHORITATIVELY puts
-- the box in a REAL gear 1 per mode — NOT a display paint — so the speedo shows a genuine 1 while staged
-- and it never snaps back to N when you exit LC without launching. Direct set (no shift request / no
-- +/- ladder step) so the player's own shift state is untouched. Idempotent. On HK.* (file is at the
-- 200-local ceiling); closes over the file-local gear state as it's defined in the same chunk.
HK.lcEngageGear1 = function(veh)
    if not veh or veh == 0 then return end
    if gearMode == 1 or gearMode == 6 then
        -- MANUAL / SEQUENTIAL: NO-OP (2026-08-14 revert, user: "stay in neutral, I shift"). LC stages
        -- in NEUTRAL — the box shows N, the engine free-revs against the brake (capped at lcTargetRpm by
        -- the staged-hold), and YOU bang it into 1st to launch (upshift = the clutch-dump fire). The v6
        -- "LC does the upshift for you" auto-engage-gear-1 was the source of the weird manual gear
        -- changing; ditched. The neutral free-rev block already cuts drive + free-revs while targetGear==0,
        -- so nothing to do here. The launch-fire path engages 1st via beginShift(1). Bail leaves it in N.
        return
    elseif gearMode == 3 or gearMode == 4 or gearMode == 5 then
        -- DCT: clear the neutral/reverse flags, commit gear 1 (no requestGear window — instant, like
        -- the launch-fire path). dctCommittedGear drives the display, so it now reads a real 1.
        dctNeutral, dctNeutralHold, dctLatchedNeutral, dctReverse = false, false, false, false
        dctGear, dctCommittedGear, dctPendingGear = 1, 1, nil
        if vl_getCurrentGear(veh) ~= 1 then vl_setCurrentGear(veh, 1) end
        if netEnt then netEnt.state:set('sync_gear', 1, true) end
    else
        -- comfort auto / EV (mode 2): D/N/R selector + revGate own the display — flip to D, clear the
        -- neutral gate so GetDisplayGear reads the native forward gear (1) instead of N.
        HK.autoRevSel = 'D'
        if revGate == 'neutral' or revGate == 'reverse' then revGate = 'none' end
        if vl_getCurrentGear(veh) < 1 then vl_setCurrentGear(veh, 1) end
    end
    -- drive force LIVE (the handbrake holds the car; the engine loads for real against gear 1)
    if origins and origins.fInitialDriveForce then
        setDriveForce(veh, gbDriveForceLive or origins.fInitialDriveForce)
    end
end

-- LAUNCH STAGE (called from a qualifying mode's NEUTRAL state, while the car is stopped).
-- neutral + HANDBRAKE + FULL THROTTLE -> STAGED: hold the computed launch rpm (belt-and-
-- braces: the real launch-rev native AND a forced rpm feed, since the native is unproven on
-- addon cars). Release the handbrake while still on throttle -> LAUNCH (returns true so the
-- caller ENGAGES gear 1 and hands off to launchBoostApply). Returns 'staged'|'launch'|nil.
--   veh/state = current; requires state.handbrake, state.throttle, state.speedKmh.
-- manualMode = true for DCT-PADDLE-MANUAL: there, releasing the handbrake does NOT fire the
-- launch (you leave neutral by UPSHIFTING), so it stays staged until upshiftReq is passed true.
-- For autos (manualMode false/nil): handbrake release fires the launch.
-- Returns: 'staged' (owns the frame — caller sits in neutral, rpm/torque already set),
--          'launch' (caller must leave neutral + engage gear 1), or nil (not launching).
local function launchStageTick(veh, state, dt, manualMode, upshiftReq)
    -- Stage-DETECTION knobs come from base (they aren't per-class overridden); launch-CHARACTER
    -- knobs (rpm/TC/grip) come from the resolved profile, set at the off->staged transition below.
    local L = Config.Gearbox.Launch or {}
    if L.Enabled == false then
        if lcPhase == 'staged' then vl_setMaxLaunchRevs(veh, 1.0) end
        lcPhase = 'off'; launchPublish(); return nil
    end
    -- MANUAL-specific enable gate (Launch.Manual.Enabled=false -> manual reverts to no-LC).
    if manualMode and L.Manual and L.Manual.Enabled == false then
        if lcPhase == 'staged' then vl_setMaxLaunchRevs(veh, 1.0) end
        lcPhase = 'off'; launchPublish(); return nil
    end
    -- THROTTLE: the DEVICE-AGNOSTIC pedal, NOT raw state.throttle. GetControlNormal(0,71) reads
    -- 0 on some input methods (keyboard especially), which silently made the stage gate
    -- (thr >= StageThrottle) impossible to satisfy -> manual/seq NEVER staged -> HK.launching
    -- never fired -> wheelie stranded at 'wait-LC'. effThrottle is the synthesized pedal every
    -- other throttle-gated feature reads (see the turbo fix). Fall back to raw only if unset.
    local thr   = state.effThrottle or state.throttle or 0.0
    local hb    = hbHeld(state, veh)
    local brk   = state.effBrake or state.brake or 0.0
    local kmh   = state.speedKmh or 0.0
    local stThr = L.StageThrottle or 0.90
    -- HOW THE CAR IS HELD while staging. AUTO stages on the HANDBRAKE only (its fire is the
    -- handbrake release). MANUAL/SEQ is a BRAKE-TORQUE launch — you hold the car on the FOOTBRAKE
    -- (or handbrake), build revs, then drop the hold + bang 1st — so it stages on EITHER. Requiring
    -- the handbrake meant a player launching the natural (footbrake) way never even staged.
    local stBrk = (L.Manual and L.Manual.StageBrake) or 0.55
    -- HANDBRAKE-ONLY STAGING (2026-08-14, user intent): by default the launch stages on the
    -- HANDBRAKE only — holding throttle+FOOTBRAKE in neutral should just REV (bounce off the
    -- limiter), never arm/fire the launch. The old footbrake brake-torque staging is opt-in via
    -- Launch.Manual.StageOnFootbrake (kept reversible). Auto boxes were always handbrake-only.
    local footStage = manualMode and (L.Manual and L.Manual.StageOnFootbrake == true) and (brk >= stBrk)
    local held
    if manualMode then held = hb or footStage else held = hb end
    -- CLEAN per-frame signals for the speedo LC pill (reset at the top of Gearbox_Tick,
    -- set true here because reaching this fn means we're in a launch-capable neutral).
    -- Gate inNeutral on the stopped check so the pill only shows near a standstill (staging
    -- is only possible then); hb reflects the robust handbrake read.
    HK.launch.inNeutral = (kmh <= (L.StageMaxKmh or 4.0))
    HK.launch.hb = hb == true

    -- DBG: record that this ran + what it saw (read by GetLaunchState).
    HK.launch.dbgSeen = manualMode and 'manual' or 'auto'
    -- dbgHb = the ROBUST read the guard actually uses (hbHeld), NOT the raw state flag, so the
    -- overlay reflects the real staging decision. dbgHbRaw exposes the stale state.handbrake for
    -- comparison (if raw=false but dbgHb=true, the state feed was the stale culprit).
    HK.launch.dbgHb, HK.launch.dbgThr, HK.launch.dbgKmh = hb, thr, kmh
    HK.launch.dbgHbRaw = state.handbrake == true
    HK.launch.dbgBrk = brk                       -- footbrake the stage/fire logic sees (manual)
    HK.launch.dbgHeld = held == true             -- resolved "car is held" (hb OR footbrake for manual)

    local creepFire = false
    -- Only stage from a near standstill.
    if kmh > (L.StageMaxKmh or 4.0) then
        -- A staged car past StageMaxKmh while STILL at full throttle isn't a roll-away
        -- cancel — it's the launch happening. THE DRIFT-KEY CASE (2026-08-14 v6): holding
        -- the drift key disables the handbrake control (main.lua) and drift.lua drops the
        -- native handbrake, so gear-1 + WOT + live drive force has nothing physically
        -- holding it and the car creeps/wheelspins across the 4 km/h line — which used to
        -- strobe the LC pill staged->off->staged. FIRE the launch instead of bailing. If
        -- the throttle is NOT floored (or we weren't staged) it's a genuine roll-away ->
        -- cancel to off as before.
        if lcPhase == 'staged' and thr >= (L.StageBailThrottle or 0.5) then
            creepFire = true                     -- fall through to the staged fire below
        else
            if lcPhase == 'staged' then vl_setMaxLaunchRevs(veh, 1.0) end   -- release the rev cap
            if lcPhase ~= 'off' then lcPhase = 'off' end
            lcBailSince = 0
            launchPublish(); return nil
        end
    end

    if lcPhase == 'off' then
        -- STAGE: in neutral, car HELD (auto = handbrake; manual/seq = footbrake OR handbrake)
        -- + throttle floored. `held` already encodes the per-mode hold rule above.
        if held and thr >= stThr then
            lcPhase = 'staged'
            HK.launchStagedOnHb = hb == true     -- remember HOW we staged so the manual fire can tell
                                                 -- a footbrake-drop launch from an upshift launch
            HK.resolveLaunchProfile()            -- pick rwd/awd/fwd (+manual) launch character now
            lcTargetRpm = computeLaunchRpm(veh)  -- reads the resolved profile's rpm band
            -- LC DOES THE UPSHIFT (2026-08-14 v6, user): the instant we stage (red pill), engage a REAL
            -- gear 1. You arm LC from neutral, but to be launch-ready it must be in 1 — so LC upshifts for
            -- you. Real gear, not a paint (killed the fake-1 bug). Stays in 1 if you bail (see below).
            HK.lcEngageGear1(veh)
        end
    elseif lcPhase == 'staged' then
        -- BAIL (throttle dropped off = gave up) — WITH A GRACE WINDOW so a momentary CONTROLLER
        -- analog-trigger wobble below the bail point doesn't silently cancel the stage. The
        -- throttle must stay under StageBailThrottle for BailGraceMs continuously to cancel; any
        -- frame back above the point re-arms. Keyboard (binary W) never dips, so it's unaffected.
        -- NOTE: manual mode keeps staged through a handbrake release (you upshift to launch).
        if thr < (L.StageBailThrottle or 0.5) then
            local graceMs = L.BailGraceMs or 250
            if lcBailSince == 0 then lcBailSince = GetGameTimer() end
            if (GetGameTimer() - lcBailSince) >= graceMs then
                vl_setMaxLaunchRevs(veh, 1.0)
                lcPhase = 'off'; lcBailSince = 0; launchPublish(); return nil
            end
        else
            lcBailSince = 0                      -- back on throttle -> re-arm (dip was momentary)
        end
        local fire
        if manualMode then
            -- MANUAL/SEQ fires on EITHER of the two natural launch actions:
            --   (1) UPSHIFT into 1st — the H-pattern / sequential commit (upshiftReq), the
            --       classic "bang it into gear" launch. Works whether held on hand- or footbrake.
            --   (2) BRAKE-TORQUE DROP — staged ON THE FOOTBRAKE, then released the footbrake while
            --       the throttle stays floored (you built revs against the brake and side-stepped
            --       it). We're only here because lcPhase=='staged' (revs built, throttle was floored,
            --       car held) so a released brake IS a deliberate launch. The caller engages 1st on
            --       the fire. Handbrake-staged launches don't use this (their fire is the upshift;
            --       a handbrake release alone must not cancel — that's the existing manual rule).
            local dropFire = (not HK.launchStagedOnHb)
                             and brk < ((L.Manual and L.Manual.StageBrake or 0.55) * 0.5)
                             and thr >= (L.StageBailThrottle or 0.5)
            -- HANDBRAKE-RELEASE FIRE (2026-08-14 v3, user: "release fires the launch" + "sequential
            -- should have same engagement as manual"). A HANDBRAKE-staged manual/seq launch now fires
            -- the instant the handbrake drops with the throttle still floored — same trigger as AUTO —
            -- so the wheelspin "pull away" gesture launches naturally without the old bespoke fire block.
            -- The caller engages 1st through its normal beginShift(1) path on the 'launch' return, so the
            -- shift state machine stays consistent (no raw targetGear poke = no stuck-in-1 regression).
            -- Upshift + footbrake-drop still fire too (unchanged), so keying into gear also launches.
            local hbFire = HK.launchStagedOnHb and (not hb) and thr >= (L.StageBailThrottle or 0.5)
            fire = (upshiftReq == true) or dropFire or hbFire or creepFire
        else
            fire = (not hb) or creepFire          -- AUTO: handbrake release (or creep-over-line) fires it
        end
        if fire then
            vl_setMaxLaunchRevs(veh, 1.0)        -- release the cap so full power is available
            lcPhase = 'launched'
            lcLaunchAt = GetGameTimer()
            HK.launchT = 1.0
            lcBailSince = 0
            HK.lcTcCut = 0.0                      -- fresh launch -> start with no TC cut (full power off the line)
            -- START TELEMETRY (measurement harness) — inline (launchTeleStart is defined later;
            -- this only touches the lcTele table declared up top). Tick + finalize run on the
            -- drive frames via launchTeleTick. Profile label resolved from the active gbRatio.
            lcTele.active, lcTele.startMs = true, GetGameTimer()
            lcTele.prevKmh, lcTele.peakG, lcTele.peakSlip, lcTele.t100 = 0.0, 0.0, 0.0, 0.0
            lcTele.peakTcCut = 0.0
            lcTele.model   = GetEntityModel(veh) & 0xFFFFFFFF   -- key for the per-model rpm learner
            lcTele.profile = (gbRatio and gbRatio.Label) or 'default'
            launchPublish()
            return 'launch'
        end
        -- HOLD STAGED — the RIGHT way (matches a manual gear-1 + handbrake launch). We do NOT
        -- decouple + paint a fake rpm: SetVehicleCurrentRpm on a neutral/zero-drive-force engine
        -- only moves the GAUGE, the real engine sits near idle, so on release the car pays a spin-up
        -- it hadn't actually banked = LC measured SLOWER than manual. Instead we keep gear 1 ENGAGED
        -- + drive force LIVE and let the HANDBRAKE physically hold the car while GTA builds REAL
        -- loaded revs (same as the manual launch).
        --
        -- REV CAP AT THE LAUNCH TARGET: assert the game's launch rev limiter (setMaxLaunchRevs) at
        -- lcTargetRpm every staged frame. Without it, WOT + gear 1 + handbrake drives the loaded
        -- engine straight to the natural limiter (near redline) — no real launch control does that;
        -- it holds at a DESIRED rpm. The cap makes the real engine settle AT lcTargetRpm (a hard
        -- ceiling on launch revs), so what you see is what connects on release. The feed-up below
        -- only helps revs CLIMB to the target faster; the cap prevents any overshoot past it.
        vl_setMaxLaunchRevs(veh, lcTargetRpm)    -- hold the engine at the launch target, not redline
        local realRpm = state.rpm or 0.0
        if realRpm < lcTargetRpm then
            vl_setRpmRaw(veh, lcTargetRpm)       -- help revs climb to target; the cap holds them there
        end
        -- BRAKE LIGHT WHILE STAGED: light the lamps for the wound-up hold (arcade nod to the IRL
        -- two-foot brake-torque launch). Per-frame native, so leaving 'staged' drops it naturally.
        if L.BrakeLightWhenStaged ~= false then
            SetVehicleBrakeLights(veh, true)
        end
        -- NOTE: no HK.torqueMult=0 — the handbrake holds the car and the engine loads for real; the
        -- cap is released to 1.0 the instant the brake fires (below) so full power is available.
    end
    launchPublish()
    return (lcPhase == 'staged') and 'staged' or nil
end

-- LAUNCH BOOST (called on driving frames after a launch fired). A SMALL torque surge that
-- FADES over BoostMs — starts at BoostMult, tapers to 1.0. Ends on time / lift / speed. This
-- is the only >1.0 launch power, brief + opt-in (honours the accel-invariant, like perfect-shift).
local function launchBoostApply(state)
    if lcPhase ~= 'launched' then return end
    -- Use the RESOLVED launch profile (per-drivetrain + manual overlay) captured at stage,
    -- not the raw base — so TC/GripAssist/boost run the class-specific numbers this launch.
    local L = HK.launchCfg()
    local elapsed = GetGameTimer() - lcLaunchAt
    local dur = L.BoostMs or 1200
    local thr = state.throttle or 0.0
    if elapsed >= dur or thr < 0.5 or (state.speedKmh or 0) >= (L.EndSpeedKmh or 90.0) then
        lcPhase = 'off'; HK.launchT = 0.0; HK.launching = false
        HK.lcTcCut = 0.0; HK.launchTcCut = 0.0   -- launch window closed -> clear the TC cut
        if HK.lcGripOn then                       -- restore any active grip-assist bump
            if HK.gripRelease then HK.gripRelease('lc') end
            if not (Config.GripArbiter and Config.GripArbiter.Enabled ~= false) then
                vehlib.restoreField(nil, state.vehicle, 'fTractionCurveMax')
            end
            HK.lcGripOn = false
        end
        launchPublish(); return
    end
    local t = 1.0 - (elapsed / dur)              -- 1 at launch -> 0 at window end (fades OUT)
    HK.launchT = t
    HK.launching = true                          -- lets the headlift module lift the nose on launch
    local boost = 1.0 + ((L.BoostMult or 1.06) - 1.0) * t   -- small, tapering surge
    HK.torqueMult = HK.torqueMult * boost

    -- TRACTION CONTROL (slip governor) — the thing that makes LC actually quick. We stage near
    -- redline, so raw the tyres light up on release; spin WASTES grip (slower than a clean hook).
    -- Measure wheel-vs-ground slip and CUT torque to hold the tyres at their peak-grip slip band.
    -- Cut-only (never > 1.0 — honours the accel invariant). Attack/release-smoothed so power
    -- feathers instead of stuttering. Only runs in the launch window; normal driving untouched.
    local TC = L.TractionControl
    if TC and TC.Enabled ~= false then
        local veh = state.vehicle
        local dt  = GetFrameTime()
        if dt <= 0.0 then dt = 0.016 end
        -- worst driven-wheel slip in m/s (threshold 0 => always return the raw worst gap).
        local _, slip = vl_detectWheelspin(veh, 0.0)
        slip = slip or 0.0
        local target = (TC.TargetSlip or 2.2) + (TC.DeadBand or 0.8)   -- start cutting past target+deadband
        -- RAW cut demand this frame: 0 while under the band, ramping with excess slip * Gain, clamped 0..1.
        local demand = 0.0
        if slip > target then
            demand = (slip - target) * (TC.Gain or 0.55)
            if demand > 1.0 then demand = 1.0 end
        end
        -- SMOOTH toward the demand: fast attack (catch spin quickly), slower release (no snatch).
        local cur  = HK.lcTcCut or 0.0
        local rate = (demand > cur) and (TC.AttackPerSec or 6.0) or (TC.ReleasePerSec or 3.0)
        local step = rate * dt
        if demand > cur then
            cur = math.min(demand, cur + step)
        else
            cur = math.max(demand, cur - step)
        end
        HK.lcTcCut = cur
        -- Apply: 1.0 (no cut) down to MinTorque (full cut). Never bogs to zero — keeps it pulling.
        local minT = TC.MinTorque or 0.25
        local mult = 1.0 - cur * (1.0 - minT)
        HK.torqueMult = HK.torqueMult * mult
        HK.launchTcCut = cur                      -- expose for telemetry / GetLaunchState
        if cur > (lcTele.peakTcCut or 0.0) then lcTele.peakTcCut = cur end  -- for the rpm learner
    end

    -- GRIP ASSIST (initial-bite) — kills the BOG off the line. The slip governor above only ever
    -- CUTS power, so it can't help the car HOOK in the first instant; a low-grip launch still bogs
    -- before the tyres bite. Bump fTractionCurveMax (tyre grip) at the launch instant and FADE it
    -- out over GripAssist.Ms so there's no arcade feel + no snap when it ends — just a sharper hook.
    -- vehlib.scaleHandling auto-captures the REAL grip + always scales from it, so re-calling every
    -- frame with a fading multiplier is safe/idempotent (drift.lua uses the same field the same way;
    -- a standstill launch and a slide never overlap). Called inline (nil self, like bind) — the file
    -- is at Lua's 200-local ceiling so no new vl_ local. Restored via restoreField on window close.
    local GA = L.GripAssist
    if GA and GA.Enabled ~= false then
        local gaMs = GA.Ms or 700
        local arbiterOn = (Config.GripArbiter and Config.GripArbiter.Enabled ~= false)
        if elapsed < gaMs then
            local gt   = 1.0 - (elapsed / gaMs)                 -- 1 at launch -> 0 at fade end
            local mult = 1.0 + ((GA.Mult or 1.5) - 1.0) * gt    -- Mult at instant, easing to 1.0
            -- GRIP-FIELD ARBITER (2026-08-16): this bumps fTractionCurveMax UP (a bite assist — opposite to
            -- the wheelspin drops). CLAIM it so it can't race launch-traction on the same field at t=0; LC
            -- out-ranks launch (prio 70 vs 60) so a deliberate STAGED launch HOOKS instead of spinning.
            -- min/low left at 1.0 (native) — a launch shouldn't be dropping breakaway grip. Kill-switch →
            -- direct write. HK.gripClaim lives in main.lua (loaded first).
            if arbiterOn and HK.gripClaim then
                HK.gripClaim('lc', (HK.GRIP_PRIO and HK.GRIP_PRIO.lc) or 70, { max = mult })
            else
                vehlib.scaleHandling(nil, state.vehicle, 'fTractionCurveMax', mult)
            end
            HK.lcGripOn = true
        elseif HK.lcGripOn then
            if HK.gripRelease then HK.gripRelease('lc') end
            if not arbiterOn then
                vehlib.restoreField(nil, state.vehicle, 'fTractionCurveMax')  -- fade done -> back to real grip
            end
            HK.lcGripOn = false
        end
    end
    launchPublish()
end

-- LAUNCH TELEMETRY TICK — measurement harness. Called EVERY drive frame in the launch modes
-- (independent of the boost window, which ends at EndSpeedKmh ~90; we measure to 100). Records
-- peak longitudinal g (finite-diff of speed) + peak wheel-slip, and freezes 0-100 time on
-- reaching 100 km/h. Started on the launch fire edge (inline in launchStageTick). Pure
-- measurement — writes NOTHING to physics; safe to leave on. Read via GetLaunchState.
-- LAUNCH-RPM LEARNER lives on the HK table (HK.launchLearnTrim), NOT a new `local function` —
-- gearbox.lua is at Lua's 200-local ceiling. Closes the loop the telemetry harness opened: called
-- once per completed pull (at the 100 km/h freeze) with the model key + that pull's peak wheel-slip
-- and peak TC cut. Nudges HK.launchRpmTrim[model] toward the car's fastest hook using the SAME
-- peak-grip target the slip governor holds (TC.TargetSlip):
--   * peakSlip well ABOVE target -> the launch rpm lit the tyres up (spin wastes grip) -> LOWER rpm.
--   * peakSlip BELOW target AND the governor barely cut (peakTcCut low) -> grip to spare, the car
--     bogged / left pace on the line -> RAISE rpm.
--   * in-between (hooked near target, or TC was actively working) -> leave it; that's the sweet spot.
-- Small step per pull + a clamp so it converges over a few launches instead of swinging.
HK.launchLearnTrim = HK.launchLearnTrim or function(model, peakSlip, peakTcCut)
    if not model then return end
    local L  = Config.Gearbox.Launch or {}
    if L.LearnRpm == false then return end
    local TC   = L.TractionControl or {}
    local tgt  = TC.TargetSlip or 2.2
    local band = TC.DeadBand or 0.8
    local step = L.LearnStep or 0.02           -- rpm offset moved per pull
    local cap  = L.LearnMaxTrim or 0.15        -- |trim| ceiling so it can't run away
    local cur  = (HK.launchRpmTrim and HK.launchRpmTrim[model]) or 0.0
    peakSlip, peakTcCut = peakSlip or 0.0, peakTcCut or 0.0
    local dir = 0
    if peakSlip > tgt + band then
        dir = -1                                -- lit up past the grip band -> stage lower
    elseif peakSlip < tgt - band and peakTcCut < 0.10 then
        dir =  1                                -- never reached grip band + TC idle -> room to stage higher
    end
    if dir ~= 0 then
        local nv = cur + dir * step
        if nv >  cap then nv =  cap elseif nv < -cap then nv = -cap end
        HK.launchRpmTrim[model] = nv
        if nv ~= cur then
            print(('[hk-launch] rpm-learn model=%d trim %.3f -> %.3f (peakSlip=%.1f tgt=%.1f tcCut=%.2f)')
                :format(model, cur, nv, peakSlip, tgt, peakTcCut))
        end
    end
end

local function launchTeleTick(veh, state, dt)
    if not lcTele.active then return end
    if dt <= 0.0 then return end
    local kmh = state.speedKmh or 0.0
    -- longitudinal g from finite-diff of speed (m/s per s / 9.81). Uses forward speed delta.
    local dv  = (kmh - lcTele.prevKmh) / 3.6            -- m/s change this frame
    local g   = (dv / dt) / 9.81
    if g > lcTele.peakG then lcTele.peakG = g end
    lcTele.prevKmh = kmh
    -- ABORT if the handbrake is grabbed mid-pull — that's not a clean launch measurement, and the
    -- wheel lock-up would corrupt peakSlip with a huge false spike. Do this BEFORE reading slip.
    if hbHeld(state, veh) then lcTele.active = false; return end
    -- wheel slip: worst wheel-vs-ground gap (m/s). threshold 0 so it always returns the raw worst.
    local _, worst = vl_detectWheelspin(veh, 0.0)
    if worst and worst > lcTele.peakSlip then lcTele.peakSlip = worst end
    local elapsedMs = GetGameTimer() - lcTele.startMs
    -- FREEZE at 100 km/h: record the pull, stop measuring, AUTO-PRINT to F8 (measurement log —
    -- so we can tune boost/grip/slip against real numbers without any speedo-side readout).
    if kmh >= 100.0 then
        lcTele.t100   = elapsedMs / 1000.0
        lcTele.last   = { t100 = lcTele.t100, peakG = lcTele.peakG,
                          peakSlip = lcTele.peakSlip, profile = lcTele.profile }
        lcTele.active = false
        print(('[hk-launch] PULL [%s]  0-100: %.2fs  peakG: %.2f  peakSlip: %.1f m/s  tcCut: %.2f')
              :format(lcTele.profile or '?', lcTele.t100, lcTele.peakG, lcTele.peakSlip, lcTele.peakTcCut or 0.0))
        -- FEED THE RPM LEARNER: adjust this model's launch-rpm trim toward its fastest hook.
        HK.launchLearnTrim(lcTele.model, lcTele.peakSlip, lcTele.peakTcCut)
    -- ABORT if the pull dies (rolled to a near-stop without hitting 100 — bailed/crashed), OR
    -- a HARD TIMEOUT so a pull that stalls at any speed in [2,100) (traffic, hit a wall) can't
    -- leak lcTele.active forever + accumulate bogus peaks from non-launch driving.
    elseif (kmh < 2.0 and elapsedMs > 1500) or elapsedMs > 20000 then
        lcTele.active = false
    end
end

-- COLD-START SEED — populate gbRpmPerSpeed for EVERY forward gear at Enable, from
-- the car's real handling.meta, so rev-match / auto-shift projection / the per-gear
-- rev-limiter cap are accurate from lap one instead of blind until each gear has
-- been driven once. Live telemetry (probe runs across cars spanning ~2x top speed)
-- proved the law: for a given gear, rpmPerKmh = nativeRatio / (K * maxFlatVel), with
-- K*maxFlatVel landing on the same constant (~0.834) in EVERY gear and EVERY car.
-- That falls straight out of the engine model: fInitialDriveMaxFlatVel is the speed a
-- 1.0-ratio gear reaches redline, so normalised-rpm = ratio*speed/(k*maxFlatVel).
-- GetVehicleGearRatio + maxFlatVel is therefore sufficient — no wheel radius / final
-- drive needed (the ratio already bakes them in, the constant absorbs the unit). The
-- learner's 0.9/0.1 EMA then refines each gear from its first coupled frame, so this
-- only removes the cold-start error; steady-state behaviour is unchanged.
local function seedGearRatios(veh, maxFlatVel)
    if not (Config.Gearbox and Config.Gearbox.RatioSeedEnable) then return end
    if not maxFlatVel or maxFlatVel <= 0 then return end
    local K = Config.Gearbox.RatioSeedK or 1.199
    local denom = K * maxFlatVel
    if denom <= 0 then return end
    -- MONOTONICITY GUARD (2026-08-15 — the confirmed rps-poison fix). A forward gear ratio table is
    -- physically monotonic: each taller gear has a STRICTLY SMALLER ratio (revs lower per km/h). But
    -- GTA hands out a TRANSIENTLY FOLDED table right after a drivetrain mod / on the every-frame mfv
    -- clamp's forced recompute (the lambra-chip case: ratios read ...0.686, 0.749, 0.900 — the top
    -- gears climb back UP = folded/shorter). Seeding straight from that poisons gbRpmPerSpeed with
    -- INVERTED rps (rps rising up the gears), which makes the rev-limiter speed-cap (redline/rps) trip
    -- early in the top gears -> forced early upshift -> the 7>8>9 HUNT — even though the SETTLED ratio
    -- table is clean (proven live: g7=0.905,g8=0.839,g9=0.800, strictly decreasing). So we commit a
    -- gear's seed ONLY while the ratio keeps decreasing (a genuine taller gear). The first gear that
    -- reads folded (ratio >= the last good one) and everything above it are SKIPPED — left nil, so
    -- projectGearRpm falls back to its LIVE-ratio path (reads GetVehicleGearRatio directly, clean) and
    -- the limiter speed-cap goes inert for them (no early cap). A clean/settled read seeds every gear.
    local lastGood = math.huge
    local committed = 0
    local folded = false
    for g = 1, gearcount do
        local ratio = GetVehicleGearRatio(veh, g)
        -- forward gears are positive; a taller gear must be STRICTLY shorter-ratio than the last good.
        if not folded and ratio and ratio > 0 and ratio < lastGood then
            gbRpmPerSpeed[g] = ratio / denom
            lastGood = ratio
            committed = g
        else
            -- non-positive OR folded (ratio didn't decrease): stop committing AND CLEAR this gear's
            -- entry so a previously-poisoned value can't persist across reseeds. The tail then falls
            -- back to projectGearRpm's live-ratio path each frame (clean) until the learner fills it.
            folded = true
            gbRpmPerSpeed[g] = nil
        end
    end
    -- Report whether EVERY gear seeded cleanly. If a folded/transient read truncated it, the caller
    -- keeps reseeding periodically until GTA settles the table clean and all gears commit (then lock).
    HK.ratioSeedComplete = (committed >= gearcount)
    if Config.Gearbox.RatioSeedDebug then
        local parts = {}
        for g = 1, gearcount do
            parts[#parts+1] = ('g%d=%.4f'):format(g, gbRpmPerSpeed[g] or -1)
        end
        print(('[hk-ratioseed] maxFlatVel=%.2f K=%.3f seeded=%d/%d complete=%s | %s')
            :format(maxFlatVel, K, committed, gearcount, tostring(HK.ratioSeedComplete),
                    table.concat(parts, ' ')))
    end
end

-- ============================================================================================
-- AUTHORITATIVE BAND (Phase 1) — WE author the gear-ratio table; GTA's fold never reaches physics.
-- Gated on Config.Gearbox.AuthoritativeBand. See DESIGN_authoritative_gearbox.md + /gbgeartest.
-- All state on HK.* (file rides Lua's 200-local ceiling). Per-model cache keyed on
-- model+modFingerprint(+mfv sig) so a handling.meta edit or a mod change auto-busts it.
-- ============================================================================================
HK.cleanBandCache = HK.cleanBandCache or {}   -- [cacheKey] = { n=<count>, r={g1..gN}, mfv=, force= }
HK.cleanBand      = nil                        -- the band for the CURRENT vehicle (nil until captured)
HK.cleanBandKey   = nil                        -- cacheKey the current band belongs to

-- Cache key: model + drivetrain-mod fingerprint. A meta edit changes the raw stock ratios (folded
-- into the band values we store), and a mod change flips the fingerprint — either busts the entry.
-- HK.* (not a main-chunk local — file rides Lua's 200-local ceiling).
HK.authBandKey = function(veh)
    local fp = HK.modFingerprint
    if not fp or fp == '' then fp = (HK.computeModFingerprint and HK.computeModFingerprint(veh)) or '?' end
    return ('%d:%s'):format(GetEntityModel(veh) & 0xFFFFFFFF, fp)
end

-- Read the live ratio table at the live gear count; return {n, r={}} ONLY if strictly monotonic
-- (folds=0) — a folded/transient read is rejected (returns nil) so we never cache a bad band.
HK.readCleanBand = function(veh)
    local n = GetVehicleHighGear(veh) or 0
    if n < 2 then return nil end        -- EV / single-gear: nothing to author
    local r, last = {}, math.huge
    for g = 1, n do
        local ratio = GetVehicleGearRatio(veh, g)
        if not ratio or ratio <= 0 or ratio >= last then return nil end   -- non-positive or folded
        r[g] = ratio
        last = ratio
    end
    return { n = n, r = r }
end

-- Capture the clean band for the current vehicle into the per-model cache. Returns true when a band
-- is available (freshly captured OR already cached for this key). Idempotent + cheap when cached.
function HK.AuthBand_Capture(veh)
    if not (Config.Gearbox and Config.Gearbox.AuthoritativeBand) then return false end
    if not veh or veh == 0 or not DoesEntityExist(veh) then return false end
    local key = HK.authBandKey(veh)
    local cached = HK.cleanBandCache[key]
    if cached then
        HK.cleanBand, HK.cleanBandKey = cached, key
        return true
    end
    local band = HK.readCleanBand(veh)
    if not band then return false end   -- live table folded/transient right now; caller retries later
    -- anchor the top-speed/force basis from origins (the .meta truth) so the applier has targets.
    band.mfv   = (origins and origins.fInitialDriveMaxFlatVel)
                 or GetVehicleHandlingFloat(veh, 'CHandlingData', 'fInitialDriveMaxFlatVel')
    band.force = (origins and origins.fInitialDriveForce)
                 or GetVehicleHandlingFloat(veh, 'CHandlingData', 'fInitialDriveForce')
    HK.cleanBandCache[key] = band
    HK.cleanBand, HK.cleanBandKey = band, key
    if Config.Gearbox.AuthoritativeBandDebug then
        local parts = {}
        for g = 1, band.n do parts[#parts+1] = ('g%d=%.4f'):format(g, band.r[g]) end
        print(('[hk-authband] CAPTURED key=%s n=%d mfv=%.1f force=%.4f | %s')
            :format(key, band.n, band.mfv or -1, band.force or -1, table.concat(parts, ' ')))
    end
    return true
end

-- Apply targets in the PROVEN order (T3): handling floats -> ModifyVehicleTopSpeed (re-setup, re-folds)
-- -> re-write clean band (overwrite the fold). mfvTarget/forceTarget default to the captured band's
-- anchors (Phase 1 = stock); Phase 2 will pass mod-stacked targets. Call after a re-setup event and
-- as a cheap per-frame safety re-write (SetVehicleGearRatio is idempotent when the value is unchanged).
-- `resetup` = true forces the ModifyVehicleTopSpeed re-setup (entry / mod change); false = ratio-only
-- safety re-write (per frame) which does NOT re-fold, so it's the cheap steady-state path.
function HK.AuthBand_Apply(veh, mfvTarget, forceTarget, resetup)
    local band = HK.cleanBand
    if not band then return false end
    if not veh or veh == 0 then return false end
    if resetup then
        local mfv   = mfvTarget   or band.mfv
        local force = forceTarget or band.force
        if mfv   and mfv   > 0 then SetVehicleHandlingFloat(veh, 'CHandlingData', 'fInitialDriveMaxFlatVel', mfv + 0.0) end
        if force and force > 0 then SetVehicleHandlingFloat(veh, 'CHandlingData', 'fInitialDriveForce',      force + 0.0) end
        ModifyVehicleTopSpeed(veh, 0.0)   -- forces transmission re-setup so the floats apply (AND re-folds)
    end
    -- OVERWRITE the (possibly re-folded) table with our authored clean band. Guard the count in case a
    -- mod changed it since capture (trans-mod +1): if live N differs, the cache key changed too and a
    -- fresh capture should have happened — apply only up to the smaller count to avoid writing garbage.
    local liveN = GetVehicleHighGear(veh) or band.n
    local n = (liveN < band.n) and liveN or band.n
    for g = 1, n do
        SetVehicleGearRatio(veh, g, band.r[g])
    end
    if resetup and Config.Gearbox.AuthoritativeBandDebug then
        print(('[hk-authband] APPLIED resetup n=%d mfv=%.1f force=%.4f')
            :format(n, (mfvTarget or band.mfv) or -1, (forceTarget or band.force) or -1))
    end
    return true
end

-- ============================================================================================
-- TORQUE-DEATH AUTO-CAPTURE (diagnostic). The "loses torque, coasts to 0" bug only shows UNDER
-- throttle and can't be caught by hand-typing /gbwhy. This watches every frame and LATCHES the
-- richest snapshot at the WORST failure frame seen: throttle asked for (effThrottle high) but the
-- car is DECELERATING (speed falling) — i.e. we want power and aren't getting it. /gbcap dumps the
-- latched frame; /gbcapclear re-arms. Gated on HK.capArmed (armed by /gbcap-arm), zero cost off.
-- ============================================================================================
HK.capArmed = HK.capArmed ~= false   -- default ARMED so it works the moment the resource restarts
HK.capWorst = nil                    -- latched worst-failure snapshot
HK.capPrevKmh = nil
HK.capRun = 0                        -- consecutive decel-under-throttle frames (run-length confirm)
HK.capPrinted = false                -- auto-print fires ONCE per confirmed death
HK.capAutoPrint = false              -- OFF by default (no console spam) — detectors still latch silently.
                                     -- Toggle with /gbcapauto; dump manually with /gbcap after it happens.
-- Snapshot the current frame into HK.capWorst (rich state for /gbcap + auto-print).
function HK.capSnap(veh, state, gear, demand, dropKmh, kmh, rawCtrl)
    HK.capWorst = {
        at = GetGameTimer(),
        gear = gear, kmh = kmh, dropKmh = dropKmh, thr = demand,
        rpm = state.rpm, rawThr = state.throttle, effThr = state.effThrottle, rawCtrl = rawCtrl,
        torqueMult = HK.torqueMult, torqueApplied = HK.torqueMultApplied,
        limOn = HK.gbLimiterOn, limByCap = HK.gbLimiterByCap, limWhy = HK.gbLimiterWhy,
        driveForce = veh and GetVehicleHandlingFloat(veh, 'CHandlingData', 'fInitialDriveForce'),
        mfv = veh and GetVehicleHandlingFloat(veh, 'CHandlingData', 'fInitialDriveMaxFlatVel'),
        liveRatio = veh and gear and GetVehicleGearRatio(veh, gear),
        curGear = veh and GetVehicleCurrentGear(veh),
        gbSusp = gbSuspended, authReady = HK.authBandReady,
        -- drive-force restore chain: mirror (dedupe), our intended live value, origins base
        dfMirror = lastDriveForce, dfLive = gbDriveForceLive,
        dfOrigin = origins and origins.fInitialDriveForce,
        runFrames = HK.capRun,
        reEnCount = HK.reEnCount, reEnGapMs = HK.reEnLastGapMs,
        reEnAgoMs = HK.reEnLastAt and (GetGameTimer() - HK.reEnLastAt) or nil,
    }
end

function HK.TorqueCap_Watch(veh, state, gear)
    if not HK.capArmed then return end
    -- Gate on PLAYER INTENT, not processed throttle. If the failure path is the rev-limiter (or a
    -- throttle-model suppression) pinning control 71 to 0, state.throttle/effThrottle read ~0 during
    -- the death — the exact frames we need. So we also read the raw accelerate control: as long as
    -- the player is ASKING for power (key/pedal down) we treat it as a demand frame.
    local effThr  = state.effThrottle or state.throttle or 0.0
    local rawCtrl = GetControlNormal(0, 71) or 0.0           -- INPUT_VEH_ACCELERATE (player's pedal)
    local demand  = math.max(effThr, rawCtrl)
    local kmh  = state.speedKmh or ((GetEntitySpeed(veh) or 0) * 3.6)
    local prev = HK.capPrevKmh
    HK.capPrevKmh = kmh
    -- "Loses torque, coasts to 0" is a GENTLE drag decel (torque CUT, not braked): ~0.02-0.06
    -- km/h/frame, NOT the 0.3+ hard-braking value. So we detect SUSTAINED non-acceleration under
    -- demand: the player asking for power while the car is NOT gaining speed, for long enough
    -- (~400ms) that it can't be a normal shift-dip (which lasts <200ms). Run-length confirms it.
    -- RING BUFFER: record EVERY frame's trajectory (last ~90 frames ≈ 1.5s) regardless of state.
    -- On a confirmed death we dump this so we can SEE whether speed declined smoothly (drive fade)
    -- or slammed in one frame (collision), and what torque/force did as it happened. This is the
    -- signal the single "worst frame" snapshot loses (it grabbed a crash spike last time).
    HK.capRing = HK.capRing or {}
    HK.capRingI = ((HK.capRingI or 0) % 90) + 1
    HK.capRing[HK.capRingI] = {
        t = GetGameTimer(), kmh = kmh, thr = demand, eff = effThr, ctrl = rawCtrl,
        g = gear, cg = GetVehicleCurrentGear(veh), rpm = state.rpm,
        tq = HK.torqueMult, tqA = HK.torqueMultApplied,
        df = GetVehicleHandlingFloat(veh, 'CHandlingData', 'fInitialDriveForce'),
        lim = HK.gbLimiterOn, byCap = HK.gbLimiterByCap,
        -- CHIP-FIGHT fields: the levers the lambra chip is documented to move (topSpeed/acceleration).
        -- If mfv or the top-speed MODIFIER jumps around frame-to-frame while hk-handling holds steady,
        -- the chip is writing them from its escrowed client and the two resources are fighting.
        mfv = GetVehicleHandlingFloat(veh, 'CHandlingData', 'fInitialDriveMaxFlatVel'),
        tsMod = GetVehicleTopSpeedModifier and GetVehicleTopSpeedModifier(veh) or nil,
        pThr = HK._pedalThrottle, pPress = HK._pedalThrottlePressed, kb = HK._pedalInputKeyboard,
    }

    -- THROTTLE-DROPOUT DETECTOR (the real "coasts to a full stop" signature, stock cars included):
    -- physical pedal DOWN (raw key W / ctrl71 held) but the SYNTHESIZED effThrottle collapsed to ~0.
    -- That makes the gearbox think you lifted -> cuts drive -> car coasts to a stop under throttle.
    -- Auto-dump the ring the instant we see it held for a few frames (not a 1-frame blip).
    local pedalDown = (HK._pedalThrottlePressed == true) or (rawCtrl >= 0.9)
    if pedalDown and effThr < 0.15 and kmh >= 3.0 then
        HK.thrDropRun = (HK.thrDropRun or 0) + 1
        if HK.thrDropRun == 5 and not HK.thrDropPrinted and HK.capAutoPrint then
            HK.thrDropPrinted = true
            print('[hk-cap] *** THROTTLE DROPOUT: pedal DOWN but effThrottle~=0 (gearbox sees a lift) — auto-dump: ***')
            print(('[hk-cap]   pedalThr=%s pedalPressed=%s keyboard=%s rawHwThr=%s tmPos=%s tmAnalog=%s ctrl71=%.2f eff=%.2f')
                :format(tostring(HK._pedalThrottle), tostring(HK._pedalThrottlePressed),
                        tostring(HK._pedalInputKeyboard), tostring(state.rawHardwareThrottle),
                        tostring(HK.tmPedal and HK.tmPedal.pos), tostring(HK.tmPedal and HK.tmPedal.analog),
                        rawCtrl, effThr))
            HK.capDumpRing()
        end
    else
        if HK.thrDropRun and HK.thrDropRun > 0 then HK.thrDropPrinted = false end
        HK.thrDropRun = 0
    end

    local demanding = demand >= 0.5 and kmh >= 8.0 and prev ~= nil
    local dropKmh = prev and (prev - kmh) or 0.0
    -- Only count GENTLE decel as "the fade" — a big single-frame drop (>3 km/h) is a collision/curb,
    -- not a torque fade, so it must NOT confirm the death (that's what contaminated the last dump).
    local gentleFade = demanding and dropKmh > 0.01 and dropKmh < 3.0
    if dropKmh >= 3.0 then
        -- hard hit: abort this episode's run so a crash can't masquerade as the fade
        HK.capRun = 0
    elseif gentleFade then
        HK.capRun = (HK.capRun or 0) + 1
        if not HK.capWorst or (HK.capWorst.dropKmh or 0) < dropKmh then
            HK.capSnap(veh, state, gear, demand, dropKmh, kmh, rawCtrl)
        end
        -- CONFIRMED fade: sustained gentle decel under throttle, longer than any shift. Auto-dump ONCE
        -- (only if HK.capAutoPrint; otherwise stay silent and let the player dump manually via /gbcap).
        if HK.capRun == 30 and not HK.capPrinted and HK.capAutoPrint then
            HK.capPrinted = true
            print('[hk-cap] *** TORQUE-FADE CONFIRMED (30 frames gentle decel under throttle) — auto-dump: ***')
            HK.capDump()
            HK.capDumpRing()
        end
    else
        if HK.capRun and HK.capRun > 0 then HK.capPrinted = false end
        HK.capRun = 0
    end
end

-- Resolve the vehicle the player is driving (driver seat only), or 0.
local function driverVeh()
    local ped = PlayerPedId()
    if not IsPedInAnyVehicle(ped, false) then return 0 end
    local veh = GetVehiclePedIsIn(ped, false)
    if veh == 0 or GetPedInVehicleSeat(veh, -1) ~= ped then return 0 end
    return veh
end

-- Model hash as a clean unsigned 32-bit key (matches how it's stored/synced).
local function modelKey(veh)
    return GetEntityModel(veh) & 0xFFFFFFFF
end

-- maxFlatVel-FLOOR key = model hash + drivetrain-mod fingerprint. A legit engine/transmission
-- mod changes the fingerprint => it earns a SEPARATE, honest top-speed floor (so its taller
-- gears can pull to their designed speed). The lambra chip raises top speed WITHOUT touching a
-- mod slot => same fingerprint => its continuous raise still gets clamped to the current floor.
-- On the HK table (NOT a main-chunk local — that file rides Lua's 200-local ceiling) so both
-- Gearbox_Enable's capture and the per-frame clamp agree. modelKey is a plain local (available).
-- PERF: this runs per-frame from the tick's mfvFloor clamp. computeModFingerprint now calls
-- SetVehicleModKit (needed for valid GetVehicleMod reads) — too heavy 60x/sec — so we REUSE the
-- fingerprint Gearbox_Enable already cached in HK.modFingerprint instead of recomputing. The
-- fingerprint only changes on a real /maxmods (which triggers a re-Enable that refreshes the
-- cache), so the cached value is correct every frame in between. Fallback recompute only if the
-- cache is somehow empty (defensive; shouldn't happen while applied to a car).
HK.mfvFloorKey = function(veh)
    local fp = HK.modFingerprint
    if not fp or fp == '' then fp = HK.computeModFingerprint(veh) end
    return ('%d:%s'):format(GetEntityModel(veh) & 0xFFFFFFFF, fp)
end

-- DRIVETRAIN-MOD FINGERPRINT. /maxmods (qb-adminmenu) and /admincustoms (jim mechanic)
-- apply performance mods via SetVehicleMod(veh, 11/12/13/15/16) + turbo toggle (18). GTA
-- then RECOMPUTES the drivetrain from the modded base — fInitialDriveMaxFlatVel jumps (the
-- "300->617" we chased as an external corruptor was the mod-13 transmission recompute, not a
-- corruptor), gear ratios/high-gear change, drive force changes. But our `origins` snapshot,
-- the seeded gbRpmPerSpeed ratio table, gearcount and gbDriveForceLive were captured at Enable,
-- PRE-mod — so every guard then fights the modded car with a stale baseline and it won't move
-- until you park + re-enter (which re-snapshots). This fingerprint lets the entry-watcher notice
-- the mod change and re-snapshot in place instead. Returns a stable string; a change = re-snap.
-- (kept on the HK table, not a main-chunk local — the main function is at Lua's 200-local cap.)
HK = HK or {}

-- FOLD-DETECTING gear count. Walk the LIVE ratio table g1..highGear; a gear's top speed is
-- K*mfv/ratio (∝ 1/ratio). Keep every gear that extends top speed by >= eps over the best so
-- far; cut at the first REAL fold (a populated ratio whose top is lower). GTA populates the
-- table ASYNC — upper-gear ratios read 0 for a frame or two after entry / a drivetrain mod — so
-- a non-positive ratio is SKIPPED (not treated as a fold, which would wrongly cut clean gears);
-- we flag sawZero so the caller can re-verify once the table settles. Returns (count, sawZero).
HK.computeGearcount = function(veh, nativeHigh, mfv)
    local eps = (Config.Gearbox and Config.Gearbox.FoldGainEps) or 0.0
    local K   = (Config.Gearbox and Config.Gearbox.RatioSeedK) or 1.199
    if not (mfv and mfv > 0) or not (nativeHigh and nativeHigh >= 2) then
        return nativeHigh or 1, false
    end
    local usable, bestTop, sawZero = nativeHigh, -1, false
    for g = 1, nativeHigh do
        local r = GetVehicleGearRatio(veh, g)
        if not r or r <= 0 then
            sawZero = true                     -- not populated yet -> don't judge this gear
        else
            local top = K * mfv / r
            if g == 1 or top >= bestTop + eps then
                if top > bestTop then bestTop = top end
            else
                usable = g - 1                 -- REAL fold: this gear tops LOWER -> cut from here up
                break
            end
        end
    end
    if usable < 1 then usable = 1 end
    return usable, sawZero
end

-- LIVE upshift fold-guard. Returns true if shifting UP from `fromGear` would land in a gear that
-- tops out LOWER than the gear you're in now — a fold (upshifting makes you slower). Judged from the
-- CURRENT live ratio table each time, so it's immune to the transient/alternate tables GTA hands out
-- at Enable: whatever the table is at the instant of the shift, we only block a genuinely regressive
-- step. A taller gear has a SMALLER ratio, so higher-ratio-next = shorter = fold. eps guards against
-- a near-duplicate top gear (adds no usable speed). Reads are cheap natives. Never blocks gear 1->2
-- of a clean box (next ratio is always smaller there).
HK.upshiftIsFold = function(veh, fromGear)
    if not veh or veh == 0 or not fromGear or fromGear < 1 then return false end
    local rCur  = GetVehicleGearRatio(veh, fromGear)
    local rNext = GetVehicleGearRatio(veh, fromGear + 1)
    if not rCur or rCur <= 0 or not rNext or rNext <= 0 then return false end   -- unpopulated -> allow
    local eps = (Config.Gearbox and Config.Gearbox.FoldGainEps) or 0.0
    -- top speed ∝ 1/ratio; require the NEXT gear to be at least a hair TALLER (smaller ratio).
    -- Convert eps (kmh) to a ratio margin via the current mfv so the threshold is consistent.
    if eps > 0 then
        local K   = (Config.Gearbox and Config.Gearbox.RatioSeedK) or 1.199
        local mfv = GetVehicleHandlingFloat(veh, 'CHandlingData', 'fInitialDriveMaxFlatVel')
        if mfv and mfv > 0 then
            local topCur, topNext = K * mfv / rCur, K * mfv / rNext
            return topNext < topCur + eps
        end
    end
    return rNext >= rCur      -- next gear not taller (equal or shorter) => fold
end

HK.DRIVETRAIN_MODS = { 11, 12, 13, 15, 16 }   -- engine, brakes, transmission, suspension, armor
HK.computeModFingerprint = function(veh)
    if not veh or veh == 0 or not DoesEntityExist(veh) then return '' end
    -- NOTE: we deliberately do NOT call SetVehicleModKit here. Forcing the mod kit every poll
    -- triggers a GTA drivetrain RECOMPUTE (transient driveForce=0 + maxFlatVel reset to stock),
    -- which is exactly the poison it was meant to avoid — it made the loop WORSE. Instead we read
    -- the mods raw and let the stripped-read guard in the watcher ignore any all -1 garbage frame.
    local parts = {}
    for _, t in ipairs(HK.DRIVETRAIN_MODS) do
        local ok, idx = pcall(GetVehicleMod, veh, t)
        parts[#parts + 1] = (ok and idx) or -1
    end
    local okT, turbo = pcall(IsToggleModOn, veh, 18)
    parts[#parts + 1] = (okT and turbo) and 1 or 0
    return table.concat(parts, ':')
end

-- Look up a SPAWN-CODE-keyed config table (e.g. Hybrid.Models = {['20sf90']=...}) by the
-- vehicle's model HASH. Config authors write readable spawn codes; the runtime only has the
-- hash, so we hash each key once (memoized per table) and match. Returns the entry (truthy)
-- or nil. Also accepts a table already keyed by numeric hash (mixed authoring is fine).
local _spawnHashCache = setmetatable({}, { __mode = 'k' })   -- weak per-config-table cache
local function lookupBySpawn(tbl, hash)
    if not tbl or hash == nil then return nil end
    if tbl[hash] ~= nil then return tbl[hash] end            -- already hash-keyed
    local idx = _spawnHashCache[tbl]
    if not idx then
        idx = {}
        for k, v in pairs(tbl) do
            if type(k) == 'string' then idx[GetHashKey(k) & 0xFFFFFFFF] = v end
        end
        _spawnHashCache[tbl] = idx
    end
    return idx[hash & 0xFFFFFFFF]
end

-- Apply/restore the hybrid EV-mode engine SOUND. GTA can't runtime-set the electric FLAG,
-- but ForceVehicleEngineAudio swaps the engine sound to any audio bank. In 'ev' mode we force
-- the configured EV audio (default 'NEON' = GTA's electric-car sound, same as the Plaid); in
-- 'normal' we restore the car's own audio. Guarded — the native may not exist on all builds.
local lastDrivePubSig = nil        -- change-detect signature for the hk_drivestate bag publisher
local hybridAudioForced = false
local hybridAudioApplied = nil     -- the LAST audio name we actually forced on curVeh ('NEON'/'').
                                   -- Dedupe: re-forcing the SAME name re-triggers the sound from the
                                   -- start (the audible 'spawn NEON' spam + a stream hitch), so we only
                                   -- call ForceVehicleEngineAudio when the desired value CHANGES.
-- reassert = allow a re-apply attempt even if we think it's applied (used by the ONE post-
-- spawn confirm, since the very first force can no-op before the audio engine is ready). The
-- value-dedupe below still prevents re-forcing an already-correct sound, so reassert only
-- re-fires when it genuinely hasn't taken yet.
local function applyHybridAudio(veh, reassert)
    if not veh or veh == 0 or not DoesEntityExist(veh) then return end
    if not ForceVehicleEngineAudio then return end            -- native missing -> skip silently
    local HY = Config.Gearbox.Hybrid
    -- Swap to the EV sound whenever the car is ACTUALLY driving electric (hybridEMode), NOT
    -- merely when the user PREFERS ev — so the audio follows the real e<->ICE handoff (at the
    -- cap it flips to the engine note, dropping back to electric hum when e-mode resumes).
    --
    -- NETWORK SYNC: ForceVehicleEngineAudio is CLIENT-LOCAL — calling it here only changes the
    -- sound on the DRIVER's client, so passengers / other players still heard the stock engine.
    -- Fix: the driver PUBLISHES the desired audio name to a REPLICATED statebag on the vehicle
    -- (`hk_ev_audio`); every client runs a global AddStateBagChangeHandler (below) that applies
    -- ForceVehicleEngineAudio to that entity whenever the bag changes. So everyone near the car
    -- hears the electric hum / the engine wake, not just the driver. We still apply locally here
    -- for zero-latency on the driver's own client; the handler makes it a no-op re-apply for us.
    local want = (isHybrid and hybridEMode and (HY and HY.EVAudioEnabled ~= false))
                 and ((HY and HY.EVAudio) or 'NEON') or ''
    -- VALUE DEDUPE: only touch the native when the desired sound actually changes (or a
    -- reassert while it hasn't taken yet). This stops the repeated 'NEON restart' spam +
    -- stream hitch from calling it every retry/frame with the same value.
    if want ~= hybridAudioApplied or (reassert and want ~= '') then
        ForceVehicleEngineAudio(veh, want)
        hybridAudioApplied = want
        hybridAudioForced  = (want ~= '')
    end
    -- Publish to the replicated statebag (nil-safe; only the network owner can set it, which
    -- the driver is). '' = restore stock. Other clients pick this up via the handler.
    if netEnt then
        local ok, cur = pcall(function() return netEnt.state and netEnt.state.hk_ev_audio end)
        if not ok or cur ~= want then
            pcall(function() netEnt.state:set('hk_ev_audio', want, true) end)
        end
    end
end

-- Hybrid ENGINE START / STOP sound on the e-mode<->ICE handoff. To get the car's REAL
-- per-vehicle ignition/shutdown sound (not a generic clip), we briefly cycle the actual
-- engine state — BUT ONLY at low speed, where a momentary engine blip can't wreck control
-- (the reason we never do it while driving fast). Above the speed gate we skip it entirely
-- (the audio-bank swap already marks the transition; no risky cut at speed).
--   on=true  (ICE waking):   SetVehicleEngineOn(true, instantly=false) -> genuine startup crank.
--   on=false (going quiet):  SetVehicleEngineOn(false, instantly=false) -> genuine shutdown,
--                            then immediately restart NEXT tick so the car keeps driving
--                            electric (we're not really off — the shutdown is just the SOUND).
local function hybridEngineCue(veh, on)
    -- ENGINE ON/OFF CYCLING REMOVED. Cycling SetVehicleEngineOn to get the real per-car
    -- ignition sound proved unworkable: startup (instantly=false) has GTA's ~1s crank delay
    -- that desynced from the mode change, the shutdown briefly cut power/control, and near the
    -- cap it restart-spammed. The engine-AUDIO-BANK swap (applyHybridAudio: electric hum <->
    -- real engine note) already marks the transition cleanly with none of that grief, so that
    -- is now the sole audible cue. This function is kept as a no-op hook in case we later add
    -- a SAFE canned start/stop one-shot (a dedicated custom soundset), without the engine cycle.
    return
end

-- NOTE: a single-gear top-gear PIN was tried here and reverted — pinning GTA's top gear from
-- a standstill has almost no launch torque (tall ratio), so EVs couldn't pull away. EVs now
-- let GTA's box drive (pure-EV metas are already 1-gear; hybrid e-mode nudges an early upshift
-- to avoid lugging). Low-end feel is tuned via the torque boosts, not gear pinning.

-----------------------------------------------------------------
-- PUBLIC -> INTERNAL gearbox-number translation.
-- The DB / commands / labels use the PUBLIC scheme (hk_handling.manualType):
--   0 our-auto | 1 manual | 2 Automatic (Paddle) | 3 Sport DCT | 4 Super DCT | 5 sequential | 6 GTA-native
-- The engine internals (gearMode + all the tuned branches) use FROZEN numbers:
--   1 manual | 2 comfort-auto | 3 DCT | 4 supercar | 5 F1 | 6 sequential
-- This map is the ONLY place the two schemes meet. PUBLIC 6 (GTA native) maps to
-- nil = "do not process" (raw GTA). PUBLIC 0 (our auto) maps to internal 2.
local PUBLIC_TO_INTERNAL = {
    [0] = 2,    -- our automatic   -> comfort auto
    [1] = 1,    -- classic manual  -> manual
    [2] = 3,    -- Automatic (Paddle) -> DCT engine (TC feel, retuned; paddles need script-owned gears)
    [3] = 4,    -- Sport DCT       -> supercar DCT
    [4] = 5,    -- Super DCT       -> F1-DCT
    [5] = 6,    -- sequential      -> sequential dogbox
    [6] = nil,  -- GTA native      -> NOT PROCESSED (raw GTA, debug)
}

-- Is this a CAR-class vehicle (eligible for the no-row default-on rule)?
local function isCarClass(veh)
    local set = Config.Gearbox and Config.Gearbox.CarClasses
    if not set then return true end
    return set[GetVehicleClass(veh)] == true
end

-----------------------------------------------------------------
-- DETECTION — should this vehicle run our box, and in which mode?
-- Model (post-migration, PHASE 1.5 jim-upgrade layered on top):
--   * BASE resolution (no upgrade): a DB row's PUBLIC type is AUTHORITATIVE;
--     no row + car class -> default type 0 (our automatic); no row + non-car
--     -> nil (raw GTA native).
--   * JIM UPGRADE (Config.Gearbox.Jim): if the car has the jim gearbox upgrade
--     (jim per-vehicle status.manual==1, or the legacy vlad_gears:activate latch),
--     the BASE type is remapped through Config.Gearbox.Jim.UpgradeMap, which can
--     also GRANT a gear-ratio mode. A base type with no map entry (e.g. 6 GTA
--     native) is LOCKED — the upgrade does nothing. The upgrade only ever PROMOTES
--     an already-resolved car; it cannot create a box on a non-car/no-row vehicle
--     (jim is an extra trigger, never a dependency — the car-class default is the
--     law). See resolveEffective for the full type+ratio rule.
-----------------------------------------------------------------

-- BASE (pre-upgrade) public gearbox type for a vehicle: DB row if present, else
-- car-class default (0), else nil (non-car with no row -> raw GTA).
local function basePublicType(veh)
    local m = HK.manualModels and HK.manualModels[modelKey(veh)]
    if m and m.type ~= nil then return m.type end   -- DB row authoritative (incl. 0 and 6)
    if isCarClass(veh) then return 0 end             -- no row + car -> our automatic (default)
    return nil                                       -- no row + non-car -> raw GTA
end

-- BASE (pre-upgrade) admin-set gear-ratio mode for the model (0 if no row / unset).
local function baseRatioMode(veh)
    local m = HK.manualModels and HK.manualModels[modelKey(veh)]
    return (m and m.ratio) or 0
end

-- Is the jim gearbox upgrade active on THIS car? Gated on Jim.Enabled. Detected
-- from jim's per-vehicle status (authoritative + timing-independent) OR the legacy
-- vlad_gears:activate event latch (`toggled`, kept as a fallback for the bridge).
local function jimUpgradeActive(veh)
    if isEasy() then return false end
    local J = Config.Gearbox and Config.Gearbox.Jim
    if not (J and J.Enabled) then return false end
    if toggled then return true end
    return veh ~= 0 and vl_jimIsManual(veh) == true
end

-- EFFECTIVE resolution — the (publicType, ratioMode) the car ACTUALLY runs after
-- the jim-upgrade remap. SINGLE SOURCE OF TRUTH for both type and ratio.
--   * no upgrade            -> base type + base ratio, untouched.
--   * upgrade, no map entry -> base unchanged (locked, e.g. type 6).
--   * upgrade with entry    -> entry.type. The ratio depends on whether the entry
--     LISTS a ratio:
--       - entry has NO ratio (types 0,1): ratio is left COMPLETELY untouched (= base
--         ratio, whatever the admin set). The upgrade only changes the TYPE.
--       - entry HAS a ratio (types 2,3,4,5):
--           · base ratio == 0 (default): take entry.ratio (the granted ratio).
--           · base ratio ~= 0 (admin already tuned it): the ADMIN VALUE WINS, advanced
--             through UpgradeRatioProgression (Drag-tuned stays Drag, Sport steps up to
--             Hyper). entry.ratio is ignored in this case.
-- Returns (nil, ratio) for a non-car/no-row vehicle: the upgrade can't create a box.
local function resolveEffective(veh)
    local bt = basePublicType(veh)
    local br = baseRatioMode(veh)
    if bt == nil then return nil, br end
    if not jimUpgradeActive(veh) then return bt, br end
    local J = Config.Gearbox.Jim
    local entry = J and J.UpgradeMap and J.UpgradeMap[bt]
    if not entry then return bt, br end              -- locked base (no entry) -> unchanged
    local newType  = entry.type or bt
    local newRatio = br                              -- default: ratio UNTOUCHED
    if entry.ratio ~= nil then                       -- only entries that grant a ratio touch it
        if br ~= 0 then
            newRatio = (J.UpgradeRatioProgression and J.UpgradeRatioProgression[br]) or br
        else
            newRatio = entry.ratio
        end
    end
    return newType, newRatio
end

-- Resolve the EFFECTIVE PUBLIC gearbox type (0-6) or nil if it shouldn't be
-- processed. Thin wrapper over resolveEffective (type only).
local function resolvePublicType(veh)
    local pt = resolveEffective(veh)
    if isEasy() and pt and (pt == 3 or pt == 4 or pt == 5) then
        pt = 2   -- easy: clamp Sport/Super DCT + sequential tiers to Automatic (Paddle)
    end
    return pt
end

local function shouldProcess(veh)
    local pt = resolvePublicType(veh)
    if pt == nil then return false end
    return PUBLIC_TO_INTERNAL[pt] ~= nil    -- type 6 maps to nil -> not processed
end

-- Which INTERNAL gearbox MODE this car runs (frozen engine numbering).
-- Returns the internal mode, defaulting to comfort-auto(2) if something slips
-- through (shouldProcess already gates type 6 / non-cars out).
local function detectMode(veh)
    local pt = resolvePublicType(veh)
    return (pt ~= nil and PUBLIC_TO_INTERNAL[pt]) or 2
end

-- Optional class filter (nil = allow all).
local function classAllowed(veh)
    local allowed = Config.Gearbox.AllowedClasses
    if not allowed then return true end
    return allowed[GetVehicleClass(veh)] == true
end

-- Shared per-vehicle SHIFT-STATE reset — the block that Enable and Reset both
-- need. Kept in one place so the two can't drift out of lockstep (they have, in
-- past edits). Does NOT touch lifecycle flags (applied/curVeh/origins) or the
-- enable-vs-reset-specific bits (clutchReadyAt, autoFastShift) — callers set those.
local function resetShiftState()
    started    = false
    enteredMoving = false
    targetGear = 1
    shifting   = false
    shiftEndAt = 0
    reqUp, reqDown = false, false
    pendUpAt, pendDownAt = 0, 0
    upTapAt, upTapPrev, downTapAt, downTapPrev = 0, 0, 0, 0
    upHeld, downHeld, bothHoldStart, neutralGate = false, false, 0, false
    reqNeutralTap = false
    manualNeutralHold = false
    preNeutralGear = 1
    clutchHeld    = false
    shiftPowerMult, shiftPowerUntil = 1.0, 0
    shiftWasClutchless = false
    missShiftUntil, missShiftGear = 0, 1
    shiftFromGear = 1
    shiftStartRpm = 0
    autoMinSet, autoNextShiftOk, autoShiftDipUntil, autoLastGear = false, 0, 0, -99
    autoNeutral = false
    -- NOTE: isEV is NOT reset here — it's per-vehicle, resolved in Gearbox_Enable
    -- (like gbRatio), so clearing it here would wipe the fresh value every Enable.
    dctManual, dctGear, dctStarted, dctLastGear = false, 1, false, -99
    dctNeutral = false
    dctNeutralHold = false
    dctHoldNArmed = true
    dctNeutralFromAuto = false
    dctLatchedNeutral = false
    dctPreNeutGear = 1
    dctReverse = false
    revGate, revBrakeArmed, revThrArmed, revWalkAt, revWasMoving = 'none', false, false, 0, false
    revNFromReverse = false
    if HK.autoRevReset then HK.autoRevReset() end   -- key-driven auto reverse selector -> Drive
    HK.revBrakePrev = false        -- clear brake-edge memory so a car entered mid-brake still sees a fresh edge
    HK.autoRevBrakePrev = false    -- (legacy) auto S-retap edge memory
    HK.autoSBrkPrev, HK.autoSTapAt = false, nil   -- clear double-tap-S-to-N state (comfort/EV/DCT-auto)
    HK.tcRpmOff, HK.tcBand = 0.0, 1.0   -- clear torque-curve smoothing so it can't leak across cars
    HK.turboSpool, HK.turboNoteOff = 0.0, 0.0   -- clear turbo spool + note so it can't leak across cars
    HK.dctNeutralRatioOff = false
    HK.reducedRatioWantOn = nil    -- recomputed by the watchdog next tick from the fresh mode
    HK.maxFlatVelCheckAt = 0        -- re-check maxFlatVel promptly on the next car
    dctAutoNextOk = 0
    dctShiftDipUntil, dctBoostUntil, dctOverrevUntil, dctOverrevReturn, dctBeepAt = 0, 0, 0, 1, 0
    dctShiftEndAt, dctPendingGear, dctCommittedGear = 0, nil, 1
    HK.tcSlipCur = 0.0             -- clear TC slip-flare so de-bias can't over-subtract after a reset
    HK.dctKickStart, HK.dctKickUntil, HK.dctKickAmp = 0, 0, 0.0   -- clear any in-flight post-upshift kick
    HK.coastUpSteps = 0            -- clear the lift-off coast-up gear counter
    HK.gbAirSettleUntil = 0        -- clear the airborne-landing upshift-block window
    lcPhase, lcLaunchAt, lcBailSince = 'off', 0, 0
    HK.lcTcCut = 0.0               -- clear the LC traction-control cut
    -- restore any active launch grip-assist bump so a mid-launch car swap can't leak raised grip
    if HK.gripRelease then HK.gripRelease('lc') end
    if HK.lcGripOn and curVeh and curVeh ~= 0
       and not (Config.GripArbiter and Config.GripArbiter.Enabled ~= false) then
        vehlib.restoreField(nil, curVeh, 'fTractionCurveMax')
    end
    HK.lcGripOn = false
    lcTele.active = false          -- stop any in-progress measured pull (else it leaks across cars)
    -- E-MODE LATCHES — reset here (not only in Gearbox_Reset) so a DIRECT car->car warp (admin/
    -- trainer SetPedIntoVehicle, no on-foot frame -> only Gearbox_Enable runs, not Reset) can't
    -- carry a stale reduced-ratio-off / gear-pin latch into the next hybrid = "stuck reduced
    -- ratios / caps at 81 after a hybrid round-trip" bug. hybridUserMode is NOT reset here — Enable
    -- resolves it per-car (default mode) before this runs; clobbering it would drop that.
    eReducedRatioOff, eGearPinned, hybridEModePrev, regenCornerMult = false, false, false, 1.0
    if HK and HK.launch then HK.launch.active, HK.launch.phase, HK.launch.rpm = false, 'off', 0.0 end
    gbRpmPerSpeed = {}
    dctClutchPrev = false
    gbLimiterOn = false
    -- clear tip-in bog oscillation detector + auto-lift latch across cars/resets
    HK.tipInBogUntil, HK.tipInBogGear, HK.tipInBogLiftGear = 0, nil, nil
    HK.tipInBogCount, HK.tipInBogPeak, HK.tipInBogRising = 0, 0.0, false
    lastDriveForce = nil
    driveForceCheckAt = 0
    -- NOTE: gbRatio / gbDriveForceLive / gbAccelTrim are NOT reset here. resetShiftState
    -- is called by Gearbox_Enable AFTER it resolves them, so clearing them here would
    -- wipe the freshly-resolved per-vehicle values every Enable. They are per-vehicle
    -- lifecycle state, reset in Gearbox_Reset (the Disable path) instead.
end

-----------------------------------------------------------------
-- ENABLE — capture origins, toggle reduced-gear-ratio, set statebag.
-- (No tick yet — steps 4-5 add the per-frame machine.)
-----------------------------------------------------------------
function Gearbox_Enable(veh)
    local cfg = Config.Gearbox
    if not cfg or not cfg.Enabled then return end
    veh = veh ~= 0 and veh or driverVeh()
    if veh == 0 or not DoesEntityExist(veh) then return end
    if GetPedInVehicleSeat(veh, -1) ~= PlayerPedId() then return end
    if not classAllowed(veh) then dbg('class not allowed') return end
    if applied and curVeh == veh then return end               -- idempotent
    -- RE-ENABLE churn tracker (diagnostics). Count how often THIS vehicle re-enters Enable and
    -- how recently — a tight Disable->Enable loop (SettleVerify/fingerprint re-snapshot firing over
    -- and over) resets the box to neutral repeatedly = the "loses torque, coasts to 0" symptom.
    -- /gbcap reads these to distinguish a re-enable loop from a genuine torque-cut.
    do
        local tnow = GetGameTimer()
        if HK.reEnLastVeh == veh and HK.reEnLastAt and (tnow - HK.reEnLastAt) < 3000 then
            HK.reEnCount = (HK.reEnCount or 0) + 1
            HK.reEnLastGapMs = tnow - HK.reEnLastAt
        else
            HK.reEnCount = 0
            HK.reEnLastGapMs = nil
        end
        HK.reEnLastVeh, HK.reEnLastAt = veh, tnow
    end

    flagged = shouldProcess(veh)
    processGearbox = flagged
    if not processGearbox then
        -- Not a manual car: make sure the engine-side manual mode is OFF.
        vl_setTransmissionReducedGearRatio(veh, false)
        dbg('not manual, skipping veh', veh)
        return
    end

    curVeh  = veh
    applied = true
    gearMode = detectMode(veh)                                 -- 1=manual,2=comfort auto,3=DCT
    -- DEBUG: record the EFFECTIVE public type (0-6, post jim-upgrade/progression) + its label
    -- so /handlingdbg can show the player-facing gear TYPE alongside the internal engine mode.
    HK.dbgPublicType = resolvePublicType(veh)
    HK.dbgPublicLabel = (Config.Gearbox.ModeLabels and HK.dbgPublicType
        and Config.Gearbox.ModeLabels[HK.dbgPublicType]) or nil
    origins = vl_getDrivetrainOrigins(veh)                 -- our own restore source
    rhd     = vl_isRightHandDrive(veh)
    -- Record the drivetrain-mod fingerprint this snapshot was taken AGAINST. The entry-watcher
    -- compares against this each poll; a change (/maxmods, /admincustoms, jim mod install) means
    -- GTA recomputed the drivetrain and our origins/seeds are stale -> re-snapshot in place.
    HK.modFingerprint = HK.computeModFingerprint(veh)

    -- IMMUTABLE maxFlatVel FLOOR — the anchor the corruption guard clamps to.
    -- CRITICAL: origins.fInitialDriveMaxFlatVel CANNOT be the anchor on its own, because the
    -- mod-fingerprint RE-SNAPSHOT re-captures origins from LIVE — and if an external corruptor
    -- (observed: repeated x1.28 ModifyVehicleTopSpeed-style raises, 300->384->491) already bumped
    -- it, the re-snapshot banks the corrupted value as the new "origin" and the guard's anchor
    -- DRIFTS UPWARD, fighting a moving target (exactly what the F8 log showed). So we cache the
    -- LOWEST maxFlatVel ever seen and never let it rise. First clean capture wins; a later
    -- corrupted capture can't poison it (we only ever take the MIN). This is the true floor.
    --
    -- KEYED BY MODEL **+ MOD FINGERPRINT** (2026-08-14 fix — the "modded car jumps 6->7->8->9,
    -- speed drops in tall gears" bug). A TRANSMISSION/engine mod (SetVehicleMod 11/13) legitimately
    -- raises maxFlatVel AND adds gears geared for that HIGHER top speed. Flooring by model alone
    -- pinned the modded car back to its STOCK top speed (210 while geared for 256) — so gears 7/8/9
    -- had nothing to pull against and bogged. Keying the floor by fingerprint gives each mod
    -- configuration its OWN honest floor (stock=210 gets 210, trans-modded=256 gets 256), so the
    -- extra gears reach their designed speed. The lambra CHIP is still floored: it re-raises
    -- maxFlatVel CONTINUOUSLY without occupying a mod slot, so it NEVER changes the fingerprint —
    -- its raise lands on top of whatever honest floor the current mod set established and gets
    -- clamped straight back. Mod slot = new baseline; slotless continuous raise = corruption.
    -- FLOOR CAPTURE — FIRST-CLEAN-CAPTURE-WINS, then LOCK (2026-08-14 poison fix).
    -- The old rule took the MIN of every capture. That defeated the chip (which raises maxFlatVel
    -- ABOVE the honest value) but had a fatal hole: a GTA drivetrain-recompute transient during
    -- Enable briefly reads STOCK maxFlatVel (210 on the 911ts) — BELOW the honest modded value
    -- (256) — and MIN banked that stock value PERMANENTLY. Result: gears geared for 256 clamped to
    -- a 210 flat-vel => every gear tops out short (the "super short last gears" bug). The honest
    -- value sits BETWEEN the recompute-low (stock) and the chip-high, so MIN overshoots past it.
    --
    -- KEY INSIGHT: within ONE fingerprint the mods don't change, so the honest maxFlatVel is FIXED.
    -- Any later capture that differs is noise — LOWER = recompute poison, HIGHER = chip inflation.
    -- So: the FIRST capture for a fingerprint sets the floor, then we LOCK it (reject both lower and
    -- higher captures for that same fingerprint). Only a real fingerprint CHANGE (a new mod set)
    -- creates a fresh floor entry. The every-frame clamp below still holds the chip down to this
    -- locked floor. To recover a floor already poisoned in memory, use /gbfloorreset (re-captures).
    HK.mfvFloor = HK.mfvFloor or {}
    do
        local fk = HK.mfvFloorKey(veh)
        local live = origins and origins.fInitialDriveMaxFlatVel
        if live and live > 0 and HK.mfvFloor[fk] == nil then
            HK.mfvFloor[fk] = live      -- first capture for this fingerprint wins, then locked
        end
    end

    -- DRIVE-FORCE POISONED-CAPTURE GUARD (the "modded car stuck at kmh=0, torque fine, driveForce=0"
    -- bug — live-confirmed via /hkdecay: applied=1.19 but COUPLE{driveForce=0.0000}). getDrivetrainOrigins
    -- reads fInitialDriveForce LIVE, and the tick re-engages that captured value every frame (gbDriveForceLive
    -- = origins.fInitialDriveForce). If the snapshot — OR the mod-change re-snapshot on a freshly-modded car
    -- (jim gearbox + lambra chip) — happens on a frame where drive force is a TRANSIENT 0 (a shift/neutral
    -- window, or jim's pushVehicle zeroing it — the same transient-0 the driveForceResyncCheck already guards
    -- against), it banks 0 as the car's "stock" drive force and pins the car dead FOREVER (0 == mirror, so the
    -- tick's dedupe never re-writes). mfvFloor protects maxFlatVel from exactly this poisoned re-capture; drive
    -- force had no such guard. FIX: cache the last known-GOOD (nonzero) drive force per model; if a capture
    -- reads ~0, substitute the cache so we never bake a transient 0 as origin. Latest-good (not min/max) —
    -- a chip legitimately RAISES drive force, so a clean post-mod capture should update the cache upward.
    HK.driveForceGood = HK.driveForceGood or {}
    do
        local mk = modelKey(veh)
        local df = origins and origins.fInitialDriveForce
        if df and df > 0.01 then
            HK.driveForceGood[mk] = df                 -- real capture -> remember it
        elseif origins then
            local good = HK.driveForceGood[mk]
            if good and good > 0.01 then
                origins.fInitialDriveForce = good      -- transient-0 capture -> restore known-good
                print(('[hk-driveforce] POISONED CAPTURE caught: snapshot driveForce=%.4f (transient 0) -> restored known-good %.4f')
                    :format(df or -1, good))
            else
                -- No cached good yet AND this capture is 0. Two ways to get here: (a) first entry
                -- caught mid-shift (transient — a re-read a few frames later reads the real force),
                -- or (b) this vehicle instance has 0 baked into its handling (e.g. a prior bad write
                -- persisted on the entity; survives a resource restart, needs /dv + respawn). SELF-HEAL
                -- attempt: poll the LIVE handling float for up to ~1s; the instant it reads nonzero we
                -- adopt it (covers case a). If it never recovers it's case (b) — warn to respawn.
                print(('[hk-driveforce] capture driveForce=%.4f, no cache yet — polling live for recovery')
                    :format(df or -1))
                local vhandle = veh
                CreateThread(function()
                    for _ = 1, 20 do            -- 20 * 50ms = 1s
                        Wait(50)
                        if not DoesEntityExist(vhandle) then return end
                        local live = GetVehicleHandlingFloat(vhandle, 'CHandlingData', 'fInitialDriveForce')
                        if live and live > 0.01 then
                            local mk2 = GetEntityModel(vhandle) & 0xFFFFFFFF
                            HK.driveForceGood[mk2] = live
                            -- Only patch the ACTIVE box if we're still on this same car.
                            if curVeh == vhandle and origins then
                                origins.fInitialDriveForce = live
                                gbDriveForceLive = live
                                lastDriveForce = nil          -- clear dedupe so the tick re-writes it
                            end
                            print(('[hk-driveforce] recovered live drive force %.4f (self-heal)'):format(live))
                            return
                        end
                    end
                    print('[hk-driveforce] WARNING: drive force stayed 0 for ~1s — this vehicle instance '
                        .. 'has 0 baked into its handling. Do /dv and respawn it (a fresh spawn reads '
                        .. 'the clean meta drive force).')
                end)
            end
        end
    end

    -- GEAR-RATIO MODE (PHASE 2 + jim upgrade). Resolve the EFFECTIVE per-vehicle
    -- shift-feel profile. The ratio comes from resolveEffective (NOT the raw DB row):
    -- it is the admin-set ratio, OR — when the jim gearbox upgrade is active — the
    -- upgrade-granted / progression-advanced ratio (see resolveEffective). B1: we only
    -- POINT at the config profile (never mutate it); the tick reads baseline * gbRatio.X.
    -- ratio 0 -> the [0] no-op profile, so behaviour is byte-identical to stock.
    -- driveForce layer is gated on RatioUseDriveForce and applied below.
    do
        local rmodes = (cfg.RatioModes) or {}
        local _, rmode = resolveEffective(veh)
        rmode = rmode or 0
        gbRatio = rmodes[rmode] or rmodes[0] or {
            UpshiftRpmMult = 1.0, DownshiftRpmMult = 1.0, ShiftTimeMult = 1.0,
            LowGearTorque = 1.0, DriveForcePct = 0.0,
        }
        HK.dbgRatioMode = rmode                        -- DEBUG: active /gearratio mode index (0-3)
        HK.dbgRatioLabel = gbRatio.Label or '?'        -- DEBUG: DEFAULT/SPORT/DRAG/HYPERCAR
        if cfg.Debug then
            print(('[hk-gearbox] ratio mode %d (%s) | up=%.2f down=%.2f shift=%.2f lowT=%.2f inertia=%.2f ladder=%.2f df%%=%.2f useDF=%s')
                :format(rmode, gbRatio.Label or '?', gbRatio.UpshiftRpmMult or 1, gbRatio.DownshiftRpmMult or 1,
                        gbRatio.ShiftTimeMult or 1, gbRatio.LowGearTorque or 1, gbRatio.DriveInertiaMult or 1,
                        gbRatio.LadderUpBias or 0, gbRatio.DriveForcePct or 0,
                        tostring(cfg.RatioUseDriveForce)))
        end
    end

    -- SPEED CALIBRATION — mode-aware unpack. Easy = none. Normal = single scalar
    -- from speedCalC ({s,s,s,s}). Expert = per-gear from speedCalC (existing behavior).
    -- gbSpeedCalTargeted = model has a valid baseline/target (N: prefix in normal).
    gbSpeedCal = nil
    gbSpeedCalTargeted = false
    do
        local SC = cfg.SpeedCal
        local m = HK.manualModels and HK.manualModels[modelKey(veh)]
        if SC and SC.Enabled and m then
            if isNormal() then
                local hasNativeBaseline = type(m.speedCal) == 'string' and m.speedCal:sub(1, 2) == 'N:'
                gbSpeedCalTargeted = hasNativeBaseline
                if m.speedCalC then
                    local f = speedCalUnpack(m.speedCalC)
                    if f then
                        local s = f[1] or 1.0
                        gbSpeedCal = { s, s, s, s }
                        if SC.Debug then
                            print(('[hk-normallearn] learned scalar active x%.3f'):format(s))
                        end
                    end
                end
            elseif isExpert() then
                if m.speedCal and m.speedCal ~= '' then
                    gbSpeedCalTargeted = true
                end
                if m.speedCalC then
                    gbSpeedCal = speedCalUnpack(m.speedCalC)
                    if SC.Debug and gbSpeedCal then
                        print(('[hk-setspeed] ACTIVE %s | gears %.2f/%.2f/%.2f/%.2f')
                            :format(tostring(m.speedCalC), gbSpeedCal[1], gbSpeedCal[2], gbSpeedCal[3], gbSpeedCal[4]))
                    end
                end
            end
            -- easy: gbSpeedCal stays nil
        end
    end

    -- ACCEL MATCH — expert-only. Normal uses the learner; easy uses nothing.
    gbAccelTrim = 0.0
    if isExpert() and not gbSpeedCal then
        local AM = cfg.AccelMatch
        local ptype = resolvePublicType(veh)
        if AM and AM.Enabled and ptype and AM.Modes and AM.Modes[ptype] then
            gbAccelTrim = 1.0
            if AM.Debug then
                print(('[hk-accelmatch] ACTIVE type %s | depth=%.2f band %.0f-%.0f-%.0f-%.0f km/h')
                    :format(tostring(ptype), AM.CurveDepth or 0,
                            AM.FadeInLoKmh or 48, AM.FadeInHiKmh or 66,
                            AM.FadeOutLoKmh or 102, AM.FadeOutHiKmh or 150))
            end
        end
    elseif isExpert() and cfg.AccelMatch and cfg.AccelMatch.Debug then
        print('[hk-accelmatch] SKIPPED — car has /setspeed calibration (SpeedCal owns accel)')
    end

    -- Engine-side MANUAL enabler at Enable — ONLY for mode 1 (classic manual,
    -- always manual). Comfort auto (2) and ALL DCT tiers (3/4/5) START in auto and
    -- toggle reduced-gear-ratio dynamically in their own branch. (Even when a DCT
    -- model is DB-flagged paddle-only, the DCT branch handles that itself — Enable
    -- still treats it as an auto-capable tier here.)
    local autoMode = (gearMode == 2) or (gearMode == 3) or (gearMode == 4) or (gearMode == 5)

    if not autoMode and not isEasy() then
        vl_setTransmissionReducedGearRatio(veh, true)
    end

    -- GEAR-RATIO: OPTIONAL driveForce layer. Gated on the global RatioUseDriveForce
    -- toggle (default OFF = pure shift-feel, never touches power). When ON, each mode
    -- adds its own DriveForcePct on top of the car's stock fInitialDriveForce. We bake
    -- the result into gbDriveForceLive (the value the tick RE-ENGAGES to); `origins`
    -- stays the true stock value so Disable always restores it cleanly. Top speed
    -- (maxFlatVel) is untouched — this only changes low-end force.
    gbDriveForceLive = origins and origins.fInitialDriveForce
    if cfg.RatioUseDriveForce and gbRatio and (gbRatio.DriveForcePct or 0) ~= 0
       and origins and origins.fInitialDriveForce then
        gbDriveForceLive = origins.fInitialDriveForce * (1.0 + gbRatio.DriveForcePct)
        vl_setHandling(veh, 'fInitialDriveForce', gbDriveForceLive)
    end

    -- MODE 2 (comfort auto) — genuinely SLOW the mechanical gear change. GTA's
    -- shift speed comes from fClutchChangeRateScale*Shift (higher = faster); we
    -- scale BOTH down by Config.Gearbox.AutoShiftRateMult so the actual swap is
    -- slower/softer, not just the torque-dip feel. Restored from origins on Disable.
    -- Speed-invariant safe: clutch rate is shift timing only, not power/top speed.
    if gearMode == 2 then
        local sm = Config.Gearbox.AutoShiftRateMult or 0.6
        if origins.fClutchChangeRateScaleUpShift then
            vl_setHandling(veh, 'fClutchChangeRateScaleUpShift',   origins.fClutchChangeRateScaleUpShift   * sm)
        end
        if origins.fClutchChangeRateScaleDownShift then
            vl_setHandling(veh, 'fClutchChangeRateScaleDownShift', origins.fClutchChangeRateScaleDownShift * sm)
        end
    end

    -- DRIVE INERTIA — SNAPPIER REVS (faster needle => hits shift points sooner =>
    -- pulls harder between shifts) WITHOUT changing top speed. Two contributors,
    -- COMPOSED into one write so neither clobbers the other:
    --   * seq mode 6: a real dogbox has less rotating mass; ADAPTIVE mult (cars with
    --     already-high inertia get a lower mult so they don't become uncontrollable).
    --   * gear-ratio mode: gbRatio.DriveInertiaMult (sport/drag/hyper rev a bit faster).
    if origins and origins.fDriveInertia then
        local di = origins.fDriveInertia
        local mult = 1.0
        if gearMode == 6 then
            local SEQ = Config.Gearbox.Seq or {}
            local multMax = SEQ.DriveInertiaMult or 2.8
            local multMin = SEQ.DriveInertiaMultMin or 2.4
            local hiThresh = SEQ.DriveInertiaHighThreshold or 1.2
            local hiCap    = SEQ.DriveInertiaHighCap or 2.0
            local seqMult
            if di <= hiThresh then
                seqMult = multMax  -- average/low inertia car: full mult
            elseif di >= hiCap then
                seqMult = multMin  -- already very snappy: floor mult
            else
                local t = (di - hiThresh) / (hiCap - hiThresh)   -- linear blend max..min
                seqMult = multMax - (multMax - multMin) * t
            end
            mult = mult * seqMult
        end
        if gbRatio and gbRatio.DriveInertiaMult and gbRatio.DriveInertiaMult ~= 1.0 then
            mult = mult * gbRatio.DriveInertiaMult
        end
        if mult ~= 1.0 then
            vl_setHandling(veh, 'fDriveInertia', di * mult)
        end
        -- Record the APPLIED base inertia so the Phase-B engine-braking nudge (per-frame, in the tick)
        -- composes ON TOP of this steady-state value and restores back to it — never fighting the
        -- snappy-rev scaling above. Single-writer discipline: Enable owns the base, the tick owns the
        -- transient lift/brake nudge relative to it.
        HK.flyInertiaApplied = di * mult
    end

    -- Shift machine init (manual only — auto doesn't use shift windows).
    -- GEAR COUNT — keep EVERY gear GTA lays out and drop ONLY a true FOLD (a gear whose top speed is
    -- LOWER than the gear below it, i.e. upshifting makes you SLOWER). This is the correct model,
    -- proven by live data on the 911ts:
    --   · stock  = 8 gears, monotonic to 315 kmh (g8=0.800)   -> keep all 8
    --   · +trans = 9 gears, GTA lays a CLEAN 9-speed, ALSO to 315 (g9=0.800) -> keep all 9
    --   · +chip  = ratios re-fold so g8 tops LOWER than g6/g7  -> cut at the first fold
    -- The old meta-count cap (gearcount = nInitialDriveGears) was WRONG: it cut GTA's clean modded
    -- top gear, so a full-mod car TOPPED OUT SLOWER than stock (g9=315 dropped, g8=300 became the
    -- ceiling). The meta count is the DESIGN intent, not a runtime cap — GTA legitimately adds a real
    -- gear when you fit a transmission, and we must keep it as long as it's a genuine ratio (taller,
    -- not folded). We walk the live ratio table: top speed of gear g = K * mfv / ratio(g) (∝ 1/ratio,
    -- since a taller gear has a SMALLER ratio). Stop at the first gear that does NOT extend top speed
    -- by at least FoldGainEps (default 0) over the best gear so far — that gear and everything above
    -- it are folds/duplicates the box should never shift into. gearcount is the SINGLE shift ceiling
    -- every branch reads (manual ladder / DCT / bestGearForSpeed / snap clamps), so this one
    -- GEAR COUNT = GTA's physical highGear (stock 911ts = 8, +transmission mod = 9). We do NOT cut
    -- the count at Enable from a ratio read — that was WRONG in both directions:
    --   · GTA produces DIFFERENT ratio tables for the SAME modded car across entries/recomputes.
    --     Sometimes a CLEAN 9-speed (stock ratios +1 gear, g9=0.800 tops 315); sometimes a FOLDED
    --     one (taller gears, g8/g9 fold LOWER than g7). A single Enable-time read can't tell which,
    --     so cutting there either threw away a real top gear (cut the clean car's g9=315) or missed
    --     the fold entirely (kept g9 that tops 100 km/h slower than g7). Both happened live.
    -- The fold is real on the modded car but it's a property of the CURRENT live table, so we judge
    -- it LIVE at each upshift instead: HK.upshiftIsFold(veh, fromGear) blocks a shift into a gear
    -- that tops out lower than the gear you're in RIGHT NOW (see the DCT/manual upshift gates). That
    -- self-corrects if GTA swaps the table, and can never cut a genuinely-faster gear. So gearcount
    -- stays at the full physical count; the shift guard does the trimming dynamically.
    local metaGears  = origins and origins.driveGears
    local nativeHigh = origins.highGear or vl_getHighGear(veh)
    gearcount = nativeHigh
    HK.recheckGearcount = nil
    if Config.Gearbox and Config.Gearbox.DropFoldedGears == true and nativeHigh and nativeHigh >= 2 then
        -- Opt-in legacy STATIC cut (default false; superseded by the live upshift fold-guard). Kept
        -- only as an escape hatch. Reads potentially-transient ratios at Enable — not recommended.
        local mfv = origins and origins.fInitialDriveMaxFlatVel
        if not mfv or mfv <= 0 then mfv = GetVehicleHandlingFloat(veh, 'CHandlingData', 'fInitialDriveMaxFlatVel') end
        local count = HK.computeGearcount(veh, nativeHigh, mfv)
        gearcount = count
        if isExpert() and gearcount < nativeHigh then
            print(('[hk-gearcap] STATIC cut gearcount=%d of highGear=%d (meta=%s).')
                :format(gearcount, nativeHigh, tostring(metaGears)))
        end
    elseif isExpert() and metaGears and nativeHigh and nativeHigh ~= metaGears then
        print(('[hk-gearcap] gearcount=%d (GTA highGear; meta nInitialDriveGears=%d). Live fold-guard active.')
            :format(nativeHigh, metaGears))
    end

    -- EV DETECTION — a real electric vehicle runs ONE fixed reduction (no gearbox to
    -- shift). nInitialDriveGears is the .meta truth (origins.driveGears); GetVehicleHighGear
    -- is the runtime fallback. Either <= 1 => EV. An optional model allow/deny list handles
    -- the rare R* EV that carries fake extra gears in .meta, or a geared car we want treated
    -- as EV. EVs still RESOLVE to type 0 (car-class default) but the tick reroutes to the EV
    -- branch, which skips the ICE comfort shaping (shift dips, early-upshift, rpm-flare) that
    -- has nothing to act on with a single ratio. Gated on Config.Gearbox.EV.Enabled.
    do
        local mk = modelKey(veh)

        -- HYBRID first (a config-listed PHEV). A hybrid keeps its real gearbox for ICE
        -- mode, so it is NOT a pure EV — it gets the hybrid state machine instead. Takes
        -- precedence over EV detection so a geared hybrid can't be misread as single-gear.
        local HY = Config.Gearbox.Hybrid
        -- HYBRID CLASS (on HK table — file is at the 200-local ceiling):
        --   0 = none · 1 = FULL PHEV (standalone EV drive mode, isHybrid) · 2 = SEMI/KERS
        --   (ICE always runs, e-motor regen + always-on torque fill, no EV mode).
        -- DB row (per-model) is authoritative; the config Models list is the fallback default
        -- for cars with no DB row (so the existing PHEV list keeps working out of the box).
        local dbm0 = HK.manualModels and HK.manualModels[mk]
        local dbClass = dbm0 and dbm0.hybridClass
        local cfgSemiBoost = nil     -- per-car BoostMult from the SemiHybrid.Models config fallback
        if dbClass == nil then
            -- no DB row: config lists set the default. Full PHEV (Hybrid.Models) => class 1;
            -- else SEMI/KERS (SemiHybrid.Models, value = BoostMult) => class 2; else none.
            local SH0 = HY and HY.SemiHybrid
            if HY and HY.Enabled ~= false and lookupBySpawn(HY.Models, mk) then
                dbClass = 1
            elseif SH0 and SH0.Enabled ~= false and SH0.Models then
                local b = lookupBySpawn(SH0.Models, mk)
                if b then dbClass = 2; cfgSemiBoost = (type(b) == 'number') and b or nil
                else dbClass = 0 end
            else
                dbClass = 0
            end
        end
        HK.hybridClass = dbClass
        isHybrid = (dbClass == 1) and (HY and HY.Enabled ~= false)   -- isHybrid = FULL PHEV only
        HK.semiHybrid = (dbClass == 2)
        -- SEMI-HYBRID resolve: boost mult from DB evTorque (÷100) > config Models value > default.
        if HK.semiHybrid then
            local SH = HY and HY.SemiHybrid
            if SH and SH.Enabled == false then HK.semiHybrid = false; HK.hybridClass = 0 end
            local ev = dbm0 and dbm0.evTorque
            HK.semiBoostMult = (ev and ev / 100.0) or cfgSemiBoost or (SH and SH.BoostMult) or 1.18
        else
            HK.semiBoostMult = nil
        end
        -- SPEEDO LOOK resolve (decoupled from behaviour). DB speedoStyle (0=full,1=semi) wins;
        -- else config Hybrid.SpeedoStyle map ('full'/'semi'); else derive from class (1->full,
        -- 2->semi). Only class 1 can differ from its class default — a full PHEV shown as 'semi'
        -- still DRIVES as a PHEV (HOLD-G/cap/EV mode intact); only the cluster look changes.
        do
            local style
            local dbStyle = dbm0 and dbm0.speedoStyle
            if dbStyle == 0 then style = 'full'
            elseif dbStyle == 1 then style = 'semi'
            else
                local cfgStyle = HY and HY.SpeedoStyle and lookupBySpawn(HY.SpeedoStyle, mk)
                if cfgStyle == 'semi' or cfgStyle == 'full' then style = cfgStyle
                elseif isHybrid then style = 'full'
                elseif HK.semiHybrid then style = 'semi'
                else style = nil end
            end
            HK.speedoStyle = style
        end
        -- fresh full-PHEV hybrids start in e-mode (silent low-speed) until the ICE is triggered.
        hybridEMode = isHybrid
        -- Resolve per-model e-mode cap/power (DB overrides > ModelProfiles > global defaults).
        if isHybrid then
            local prof = lookupBySpawn(HY.ModelProfiles, mk)
            local dbCap   = dbm0 and dbm0.hybridCap
            local dbPower = dbm0 and dbm0.evTorque
            hybridCap       = dbCap or (prof and prof.CapKmh)    or HY.CapKmh    or 130.0
            hybridPowerFrac = (dbPower and dbPower / 100.0) or (prof and prof.PowerFrac) or HY.PowerFrac or 0.25
            hybridUserMode  = (HY.DefaultUserMode == 'normal') and 'normal' or 'ev'
            hybridAudioForced, hybridAudioApplied = false, nil   -- clear so the swap re-forces
            applyHybridAudio(veh)                     -- start in EV sound if default mode is 'ev'
            -- SPAWN CONFIRM (single): the audio engine may not be ready the instant we enter,
            -- so the first force can no-op. ONE delayed reassert at 600ms (audio bank loaded by
            -- then) is enough — the value-dedupe means it only re-fires if it truly hasn't taken,
            -- so no repeated 'NEON restart' spam. (Was a 4x 150/400/900/1500 loop = the spam.)
            local seedVeh = veh
            SetTimeout(600, function()
                if curVeh == seedVeh and applied and isHybrid and hybridEMode then
                    applyHybridAudio(seedVeh, true)   -- reassert once (dedupe guards the rest)
                end
            end)
        end

        -- PURE EV: single fixed reduction (no gearbox). Native flag OR drive-gear<=1,
        -- with model allow/deny overrides. A hybrid is never a pure EV.
        local EV = Config.Gearbox.EV
        isEV = false
        if not isHybrid and not HK.semiHybrid and EV and EV.Enabled ~= false then
            if lookupBySpawn(EV.ExcludeModels, mk) then
                isEV = false
            elseif lookupBySpawn(EV.Models, mk) then
                isEV = true
            else
                if EV.DetectByGears ~= false then
                    local dg = origins.driveGears
                    local g  = (dg and dg > 0) and dg or gearcount   -- .meta truth, runtime fallback
                    if (g or 2) <= 1 then isEV = true end
                end
                if not isEV and EV.DetectByNative ~= false then
                    -- GetIsVehicleElectric takes the MODEL hash (same call hk-speedo uses).
                    -- Returns the NUMBER 1 under CfxLua, so truthy-check (not `== true`).
                    local ok, elec = pcall(GetIsVehicleElectric, GetEntityModel(veh))
                    if ok and (elec == true or elec == 1) then isEV = true end
                end
            end
        end
        -- Mirror to an HK global so OTHER files (burnout.lua's free-rev) can suppress a fake ICE
        -- rev-scream on a pure EV without re-deriving it. Set here (once per car) at Enable.
        HK.gbIsEV = isEV

        -- TURBO-BY-DESIGN resolve (FEEL only — spool/whistle default-on, NO power, stays at spec).
        -- Resolved AFTER isEV so a pure EV can never be flagged turbo. DB turboDefault (0=NA/1=turbo)
        -- is authoritative; else the config Turbo.DefaultModels roster; else NA. The jim-mechanic
        -- upgrade (native mod 18) is the ONLY thing that adds POWER, applied equally to NA and turbo
        -- cars alike — see HK.Turbo_Tick. This flag ONLY default-enables the spool/whistle feel.
        do
            local TB = Config.Gearbox.Turbo
            local dbTurbo = dbm0 and dbm0.turboDefault
            local byDesign
            if dbTurbo == 1 then byDesign = true
            elseif dbTurbo == 0 then byDesign = false
            else
                byDesign = (TB and TB.Enabled ~= false and TB.DefaultModels
                            and lookupBySpawn(TB.DefaultModels, mk) and true) or false
            end
            if isEV then byDesign = false end       -- pure EV: no combustion turbo feel ever
            HK.turboDefault = byDesign
        end

        -- Seed the pure-EV regen LEVEL from config each Enable (0=Coast,1=D1,2=D2,3=D3).
        local R = EV and EV.Regen
        local dl = R and R.DefaultLevel or 3
        if type(dl) ~= 'number' or dl < 0 or dl > 3 then dl = 3 end
        evRegenLevel = math.floor(dl)
        evClutchPrev = false
        -- Cache mass for the regen decel force (F = m·a). fMass is a handling float.
        evMass = GetVehicleHandlingFloat(veh, 'CHandlingData', 'fMass') or 1500.0
        if evMass < 200.0 then evMass = 1500.0 end   -- guard bad/zero reads

        -- FLYWHEEL MASS AUTO-DETECT (2026-08-16, rev2). Derive a per-car flywheel factor so the free-rev
        -- feel + engine braking self-tune across the roster with ZERO new per-car flags.
        --   WHY NOT fDriveInertia: it's GTA's rotating-mass field but nobody populates it — 1.0 is the
        --   .meta default and the overwhelming majority of vanilla + add-on cars ship exactly 1.0, so it
        --   reads as a flat, useless signal (every car showed flyMass 1.00). Kept only as an OVERRIDE for
        --   the rare car that DID tune it (di far from 1.0 -> honour it directly).
        --   THE REAL SIGNAL: free-rev speed tracks the engine's SPECIFIC inertia ~ vehicleMass / power.
        --   A LIGHT, POWERFUL car (supercar: low fMass, high fInitialDriveForce) has a snappy, light-
        --   flywheel rev; a HEAVY, LOW-POWER car (truck/sedan) revs lazily and hangs. Both fields DO vary
        --   per car, so this produces a real per-car spread. specific = (mass/RefMass) / (force/RefForce);
        --   flyMass = specific ^ MassGamma, clamped MassMin..MassMax. specific>1 (heavy/weak) -> heavier
        --   flywheel; <1 (light/strong) -> lighter. Perf-neutral for the rev (Phase A); Phase B gated.
        do
            local FW = Config.Gearbox.Flywheel or {}
            local di    = (origins and origins.fDriveInertia) or 1.0
            local mass  = GetVehicleHandlingFloat(veh, 'CHandlingData', 'fMass') or 1500.0
            local force = (origins and origins.fInitialDriveForce) or 0.3
            if mass  < 200.0 then mass  = 1500.0 end   -- guard bad reads
            if force < 0.02  then force = 0.3 end
            local lo = FW.MassMin or 0.6
            local hi = FW.MassMax or 1.8
            local fm, src
            -- OVERRIDE: a car that actually tuned fDriveInertia away from the 1.0 default -> honour it
            -- (inverted: high di = light flywheel). Threshold keeps the 1.0-default herd on the mass path.
            if math.abs(di - 1.0) > (FW.InertiaOverrideEps or 0.15) and di > 0.05 then
                fm  = (FW.ReferenceInertia or 1.0) / di
                src = 'di-override'
            else
                local refMass  = FW.RefMass  or 1600.0     -- ~mid roster mass -> specific 1.0
                local refForce = FW.RefForce or 0.30       -- ~mid roster driveForce
                local specific = (mass / refMass) / (force / refForce)
                fm  = specific ^ (FW.MassGamma or 0.6)     -- gamma<1 compresses the spread so extremes stay sane
                src = 'mass/power'
            end
            if fm < lo then fm = lo elseif fm > hi then fm = hi end
            HK.flyMass = fm
            HK.flyInertiaBase = di                          -- honest base for Phase B restore
            if Config.Gearbox.Debug then
                print(('[hk-flywheel] mass=%.0f force=%.3f di=%.3f -> flyMass=%.3f (%s, %s)'):format(
                    mass, force, di, fm, src, fm < 0.95 and 'light' or (fm > 1.05 and 'heavy' or 'neutral')))
            end
        end

        if Config.Gearbox.Debug and (isEV or isHybrid) then
            print(('[hk-gearbox] %s detected (driveGears=%s highGear=%d mass=%.0f) -> %s branch')
                :format(isHybrid and 'HYBRID' or 'EV', tostring(origins.driveGears),
                        gearcount, evMass, isHybrid and 'hybrid' or 'EV'))
        end
    end

    -- TEMP PROBE: dump GetVehicleGearRatio per gear so we can see the real unit/scale
    -- before building the ratio-seed (kept for re-derivation). Also print maxFlatVel.
    if Config.Gearbox.RatioProbeDebug then
        local parts = {}
        for g = 0, gearcount do
            parts[#parts+1] = ('g%d=%.3f'):format(g, GetVehicleGearRatio(veh, g) or -1)
        end
        print(('[hk-ratioprobe] gearcount=%d maxFlatVel=%.2f driveInertia=%.2f | %s')
            :format(gearcount, origins.fInitialDriveMaxFlatVel or -1,
                    origins.fDriveInertia or -1, table.concat(parts, ' ')))
    end
    local mult    = Config.Gearbox.ShiftWithClutchMult or 0.62
    shiftTimeUp   = vl_computeShiftTimeMs(origins.fClutchChangeRateScaleUpShift)   * mult
    shiftTimeDown = vl_computeShiftTimeMs(origins.fClutchChangeRateScaleDownShift) * mult
    local modIdx = vl_getVehicleMod(veh, 13)
    if modIdx ~= -1 then
        local tv  = vl_getModModifier(veh, 13, modIdx) * 0.01
        local pct = 1.0 + tv * 4.0
        if pct > 1.0 then
            shiftTimeUp   = shiftTimeUp   - (shiftTimeUp   / pct)
            shiftTimeDown = shiftTimeDown - (shiftTimeDown / pct)
        end
    end
    -- GEAR-RATIO: scale manual/seq shift speed (DCT windows scaled in-tick). <1 =
    -- faster shifts (hyper), >1 = lazier. Applied before the floor so it can't
    -- produce an imperceptible shift.
    if gbRatio and gbRatio.ShiftTimeMult and gbRatio.ShiftTimeMult ~= 1.0 then
        shiftTimeUp   = shiftTimeUp   * gbRatio.ShiftTimeMult
        shiftTimeDown = shiftTimeDown * gbRatio.ShiftTimeMult
    end
    if shiftTimeUp   < 40 then shiftTimeUp   = 40 end   -- floor so a shift is felt
    if shiftTimeDown < 40 then shiftTimeDown = 40 end

    -- AUTO early-shift gating: only short-shift cars that actually shift FAST
    -- (small handling shift time). Slow/heavy cars stay native so we never
    -- speed their shifts up. Compare the RAW (pre-clutch-mult) up-shift time.
    local rawUpMs = vl_computeShiftTimeMs(origins.fClutchChangeRateScaleUpShift)
    autoFastShift = rawUpMs <= (Config.Gearbox.AutoEarlyShiftMaxShiftMs or 350)
    -- DCT absorbs the car's handling.meta gear-change rate: a short raw shift time
    -- (responsive car) gives a snappier DCT window; a long one a lazier window.
    -- Mapped per-mode in dctWindowMs() into each mode's own [min..max] (the gap).
    gbRawShiftMs  = (rawUpMs and rawUpMs > 0) and rawUpMs or 200.0
    -- Cache estimated top speed (km/h) once — the lug-floor fade scales its band
    -- to this so '35 km/h on a 320 car' generalises (a FRACTION of top speed,
    -- not a fixed km/h). GetVehicleEstimatedMaxSpeed returns m/s.
    local topMs = GetVehicleEstimatedMaxSpeed(veh) or 0.0
    gbTopKmh = (topMs > 0) and (topMs * 3.6) or 0.0
    HK.gbTopKmh = gbTopKmh   -- expose for downforce.lua's top-speed gravity release (per-car)
    resetShiftState()
    -- COLD-START: resetShiftState() just wiped gbRpmPerSpeed; seed it from the car's
    -- real .meta ratios so rev-match / auto-shift / rev-limiter work on lap one. MUST
    -- come AFTER resetShiftState (which clears the table) and after gearcount is set.
    seedGearRatios(veh, origins and origins.fInitialDriveMaxFlatVel)
    -- Start in NEUTRAL on entry unless the car is already ROLLING. The engine-on
    -- test is unreliable (the game auto-starts the driver's engine on entry, so it
    -- reads 'running' almost immediately). Speed is the robust signal: a stationary
    -- car begins in neutral (like keying on / sitting parked); only if you climb
    -- into a moving car (>~6 km/h) do we engage a speed-matched gear right away.
    enteredMoving = gbLiveUpgrade or (GetEntitySpeed(veh) * 3.6) > 6.0
    gbLiveUpgrade = false
    clutchReadyAt = GetGameTimer() + 500   -- warmup: don't cut drive the instant we enter

    -- MODDED-DRIVETRAIN SETTLE VERIFY (2026-08-15 — the confirmed root-cause fix for the modded
    -- 911ts "tops out at stock 315 / ratios oscillate / gears fold" mess). When you enter a car that
    -- was spawned WITH mods already fitted (from a garage), GTA applies the gear COUNT immediately
    -- (highGear jumps to 9) but the RATIO/maxFlatVel recompute LAGS a few frames. Gearbox_Enable runs
    -- on entry and snapshots `origins` (+ the mfvFloor, + the ratio seed) during that lag — capturing
    -- the STOCK table (mfv=210.1, stock 315 ratios) on a car that's really geared for ~256+. Nothing
    -- ever re-captures, because the fingerprint watcher only fires on a mod CHANGE and these mods were
    -- already on at spawn (fp never differs). So the stock-based floor pins the car to 315 forever and
    -- the live modded ratios fight it. FIX: arm a short verify window; the tick re-reads the live
    -- drivetrain and if it has DIVERGED from `origins` (mfv moved, or the ratio table changed) once it
    -- settles, we RE-SNAPSHOT in place (re-capture origins, re-key + re-floor, reseed). Self-clears
    -- once stable. Gated on Config.Gearbox.SettleVerify (default on).
    HK.settleVerifyUntil = (Config.Gearbox.SettleVerify ~= false)
        and (GetGameTimer() + (Config.Gearbox.SettleVerifyMs or 4000)) or nil
    HK.settleMfvSnap = origins and origins.fInitialDriveMaxFlatVel
    HK.settleHighSnap = origins and origins.highGear

    -- AUTHORITATIVE BAND (Phase 1): first capture attempt on entry. The live table may still be
    -- folded/transient this frame (spawn-with-mods recompute lag) — if so, HK.AuthBand_Capture
    -- returns false and the tick's retry (HK.authBandRetryUntil) keeps trying until it reads clean.
    HK.cleanBand, HK.cleanBandKey = nil, nil
    HK.authBandReady = false
    if Config.Gearbox and Config.Gearbox.AuthoritativeBand then
        HK.authBandReady = HK.AuthBand_Capture(veh)
        HK.authBandRetryUntil = HK.authBandReady and 0 or (GetGameTimer() + 4000)
        if HK.authBandReady then HK.AuthBand_Apply(veh, nil, nil, true) end   -- first authored write
    end

    -- Statebag so passengers / remote players can render the gear later.
    netEnt = Entity(veh)
    netEnt.state:set('sync_gear', vl_getCurrentGear(veh), true)

    HK.manualActive = true

    -- Show the absorbed speedo if configured to follow manual state.
    if Config.Speedo and Config.Speedo.AutoToggleWithManual and Speedo_SetVisible then
        Speedo_SetVisible(true)
    end

    dbg('ENABLED on veh', veh, 'rhd=', rhd, 'highGear=', origins and origins.highGear,
        'shiftUp=', math.floor(shiftTimeUp), 'shiftDown=', math.floor(shiftTimeDown))
end

-----------------------------------------------------------------
-- [F3] MUSCLE GUARD — SM helpers.
-- Re-assert the mode's engine-side transmission enabler. Mirrors Gearbox_Enable:
-- manual (1) and seq (6-internal) get reducedGearRatio ON at enable; comfort auto
-- (2) and the DCT tiers (3/4/5) START native-auto and toggle it in their own branch
-- (the DCT branch re-arms it via dctStarted=false below). So on RESUME we turn it
-- back on for the always-manual mode, and let the DCT branch re-init itself.
local function muscleGuardReassertTransmission(veh)
    local autoMode = (gearMode == 2) or (gearMode == 3) or (gearMode == 4) or (gearMode == 5)
    if not autoMode and not isEasy() then
        vl_setTransmissionReducedGearRatio(veh, true)
    end
    -- DCT tiers re-run their one-time init (which calls reducedGearRatio true + snaps
    -- to a speed-matched gear) on the next tick by clearing dctStarted.
    if gearMode == 3 or gearMode == 4 or gearMode == 5 then
        dctStarted = false
    end
end

-- NORMAL LEARNER native-baseline suspend. Reuses gbSuspended + engineWritesSuspended.
-- Called by client/normallearner.lua.
local function HK_NormalLearnerSetNativeSuspend(veh, on)
    if not veh or veh == 0 or not DoesEntityExist(veh) then return end
    if on then
        gbSuspended = true
        engineWritesSuspended = true
        HK.gbSuspendCoast = false        -- learner-reason suspend, not coast
        vl_setTransmissionReducedGearRatio(veh, false)
    else
        -- RESUME UNCONDITIONALLY — do NOT gate on `if gbSuspended`. gbSuspended is SHARED with the
        -- muscle-handbrake guard; if the guard cleared it between our suspend and resume, gating
        -- here would SKIP re-asserting reduced-ratio -> it stays OFF -> "won't move / 500km/h in a
        -- tall gear" bug. Always clear our suspend intent and re-assert the mode's correct
        -- transmission state (muscleGuardReassertTransmission is idempotent — safe if already ON).
        gbSuspended = false
        engineWritesSuspended = false
        HK.gbSuspendCoast = false
        muscleGuardReassertTransmission(veh)
    end
end
HK = HK or {}
HK.normalLearnerSetNativeSuspend = HK_NormalLearnerSetNativeSuspend

-----------------------------------------------------------------
-- TICK — clutch-gated manual shifting.
-- Core: clutchActive = (shifting OR clutchHeld). While active, drive force is
-- cut (car coasts/freewheels) and revs are fed from throttle so the engine
-- stays alive and re-engages smoothly. The native gear is written ONLY on
-- shift commit (gating this is what stops instant shifts). R(-1) maps to
-- native gear 0, disambiguated from a stop by reverse input arbitration.
-----------------------------------------------------------------
function Gearbox_Tick(veh, state, dt)
    if not processGearbox or not applied then HK.inReverseGear = false; return end
    local now = GetGameTimer()
    -- Default each frame; the per-mode reverse-arbitration blocks below set it true in a reverse gear.
    -- (Manual/seq set it from targetGear==-1; DCT/EV/comfort still use the S-gate until their phases.)
    HK.inReverseGear = false

    -- FREE-REV / LIMITER SIGNALS for burnout.lua (runs right after this tick). The three-state
    -- rev-against-throttle model needs to know, per frame: is the box logically in NEUTRAL, is the
    -- clutch held, and which mode. Defaulted here each frame; the per-mode neutral branches below
    -- set HK.gbInNeutral true. (HK.gbIsEV is set once at Enable.) On HK.* — 200-local ceiling.
    HK.gbInNeutral  = false
    HK.gbClutchHeld = clutchHeld == true
    HK.gbGearMode   = gearMode
    -- AUTO-class neutral (comfort/EV selector 'N', DCT/hybrid dctNeutral or the shared revGate) —
    -- the manual/seq branches set gbInNeutral from targetGear==0 further down. OR them all here.
    if HK.autoRevSel == 'N' or dctNeutral or revGate == 'neutral' then HK.gbInNeutral = true end

    -- WHEELSPIN-NEUTRAL LAUNCH — NO CUSTOM FIRE BLOCK (2026-08-14 v3, user: "the auto shift up thing we
    -- make is messing all this up ... overcomplicated"). The old bespoke fire block here was a SECOND
    -- launch-fire path that ran on every mode: on AUTO it raced the real launchStageTick fire on the same
    -- handbrake-release edge (double-fire -> stuck handbrake / kicked to neutral), and on MANUAL it set
    -- targetGear=1 RAW (bypassing beginShift), wedging every later up/down shift at gear 1. DELETED.
    -- The standard launchStageTick now owns staging AND firing for every box: AUTO fires on handbrake
    -- release; MANUAL + SEQUENTIAL now ALSO fire on handbrake release (added below in launchStageTick),
    -- engaging gear 1 through the normal beginShift(1) path so shifts stay clean afterward. The wheelie
    -- keys off HK.launching (set by launchBoostApply once launched) + drift + wheelspin, unchanged.

    -- TORQUE-DEATH auto-capture: latch the worst "throttle held but decelerating" frame for /gbcap.
    HK.TorqueCap_Watch(veh, state, GetVehicleCurrentGear(veh))

    -- MODDED-DRIVETRAIN SETTLE VERIFY (the root-cause fix). Enter a car spawned WITH mods and GTA
    -- applies the gear COUNT instantly but LAGS the ratio/maxFlatVel recompute by a few frames — so
    -- the origins/floor/seed captured at Enable are STOCK (mfv=210.1, stock 315 ratios) on a car
    -- really geared for ~256+, and nothing re-captures (the fingerprint watcher only fires on a mod
    -- CHANGE, but these mods were already on at spawn). Result: the stock floor pins the car to 315
    -- and the live modded ratios fight it (the oscillating/folded tables). Here we watch the live
    -- drivetrain during a short window after Enable; the instant it DIVERGES from the captured
    -- origins (maxFlatVel moved beyond noise, or highGear changed), the modded recompute has landed
    -- so we RE-SNAPSHOT in place — the same seamless gbLiveUpgrade Disable->Enable the mod-change
    -- watcher uses — which re-captures origins from the settled MODDED values, re-keys + re-floors
    -- the mfv, and reseeds the clean ratios. One-shot: the window clears on re-snapshot or timeout.
    if HK.settleVerifyUntil then
        if now >= HK.settleVerifyUntil then
            HK.settleVerifyUntil = nil                 -- window elapsed, no divergence -> accept as-is
        else
            local liveMfv  = GetVehicleHandlingFloat(veh, 'CHandlingData', 'fInitialDriveMaxFlatVel')
            local liveHigh = GetVehicleHighGear(veh)
            local snapMfv  = HK.settleMfvSnap or 0
            -- Divergence = the recompute landed AFTER our capture. Ignore the chip's tiny continuous
            -- raise (the mfv clamp handles that); require a real step (>3%) or a gear-count change.
            local mfvMoved  = (snapMfv > 0 and liveMfv and math.abs(liveMfv - snapMfv) > snapMfv * 0.03)
            local highMoved = (HK.settleHighSnap and liveHigh and liveHigh ~= HK.settleHighSnap)
            if mfvMoved or highMoved then
                if isExpert() then
                    print(('[hk-settle] modded drivetrain settled: mfv %.1f->%.1f highGear %s->%s — '
                        .. 're-snapshotting origins/floor/seed')
                        :format(snapMfv, liveMfv or -1, tostring(HK.settleHighSnap), tostring(liveHigh)))
                end
                HK.settleVerifyUntil = nil
                -- Clear the STOCK-captured floor for this fingerprint so the re-snapshot re-floors
                -- from the settled MODDED maxFlatVel (first-capture-wins would otherwise keep 210.1).
                local fk = HK.mfvFloorKey(veh)
                if HK.mfvFloor then HK.mfvFloor[fk] = nil end
                gbLiveUpgrade = true
                Gearbox_Disable(veh)
                Gearbox_Enable(veh)
                return   -- origins/seed just rebuilt; let the next tick run on the fresh snapshot
            end
        end
    end

    -- RPM PAINT DE-BIAS (modes 1 & 6 only). The cosmetic needle paints from last frame
    -- (Layer A HighHang + turbo whistle) set SetVehicleCurrentRpm, which feeds back into
    -- GetVehicleCurrentRpm → state.rpm this frame (see the Chiron regression note in
    -- TorqueCurve_Tick). HK.rpmPaintBias holds the committed offset; subtracting it before
    -- any rpm-based decision (rev limiter, shift guards) anchors those decisions to the true
    -- physics RPM. The needle still shows the lift — only the fuel-cut read is de-biased.
    -- Mirror of the mode-3 HK.tcSlipCur de-bias at the DCT branch entry.
    if (gearMode == 1 or gearMode == 6) and math.abs(HK.rpmPaintBias or 0.0) > 0.001 then
        state.rpm = math.max(0.0, (state.rpm or 0.0) - HK.rpmPaintBias)
    end
    HK.rpmPaintBias = 0.0   -- reset; paint sites below record what this frame actually commits

    -- CLUTCH ENGAGEMENT (manual modes 1 & 6 only) — a 0..1 feel value for the speedo gauge.
    -- 1.0 = clutch fully OUT (engaged, drive coupled); 0.0 = clutch fully IN (pressed, drive
    -- decoupled). The sim itself is binary (clutchActive cuts drive instantly), but a real pedal
    -- travels — so we EASE a display value toward the binary target: fast drop when the driver
    -- dips (they stab the clutch quickly) and a slightly slower rise as it "bites" back in. A
    -- mid-shift or neutral reads as clutch-in (decoupled). Cosmetic only — never touches physics.
    -- Published on HK.* so it dodges the 200-local ceiling and Gearbox_Disable can reset it.
    if gearMode == 1 or gearMode == 6 then
        local decoupled = shifting or clutchHeld or (targetGear == 0)
        local tgt = decoupled and 0.0 or 1.0
        local cur = HK.clutchEngage or 1.0
        -- ease-rate: pressing IN (toward 0) is quicker than the bite back OUT (toward 1).
        local tau = (tgt < cur) and (Config.Gearbox.ClutchGaugeTauIn or 0.045)
                                or  (Config.Gearbox.ClutchGaugeTauOut or 0.11)
        cur = cur + (tgt - cur) * (1.0 - math.exp(-(dt or 0.016) / math.max(tau, 1e-3)))
        if cur < 0.0 then cur = 0.0 elseif cur > 1.0 then cur = 1.0 end
        HK.clutchEngage = cur
        HK.clutchIsManual = true
    else
        HK.clutchEngage = 1.0     -- non-manual: fully engaged (gauge hidden anyway)
        HK.clutchIsManual = false
    end

    -- CANONICAL "player is in manual right now" flag for feature gates (wheelie [F1], etc.).
    -- Mirrors the exported GetGearboxMode() == "manual": true for a stick (modes 1/6) AND for
    -- a DCT tier (3/4/5) currently in its MANUAL sub-mode. Published on HK.* so module files
    -- (wheelie.lua) can read it without touching gearbox's local ceiling. Cleared on Disable.
    if applied then
        HK.gbManual = (gearMode == 1 or gearMode == 6)
            or ((gearMode == 3 or gearMode == 4 or gearMode == 5) and dctManual == true)
    else
        HK.gbManual = false
    end

    -- Reset the LC pre-stage signals each frame. launchStageTick sets them true when it runs
    -- (only from a launch-capable neutral), so if it DIDN'T run this frame they stay false —
    -- that's how the speedo knows launch isn't currently possible (pill hidden). Never sticky.
    HK.launch.inNeutral = false
    HK.launch.hb = false

    -- LAUNCH TELEMETRY (measurement harness): tick every frame while a measured pull is live.
    -- Self-gates on lcTele.active; runs regardless of mode branch or suspend state so a full
    -- 0-100 pull is captured even after the boost window closes. Pure measurement.
    launchTeleTick(veh, state, dt)

    -- STUCK AUTO-DIAGNOSTIC (the "won't move mid-drive after /maxmods" hunt). Every manual
    -- /gbstate is taken at idle (thr=0), which HIDES the failure: torqueMult=0.45 is normal at
    -- idle and only matters WITH throttle. So auto-capture the physical state the instant the
    -- real failure signature holds: near-full throttle + engine spun up, yet the car isn't moving.
    -- Prints ONCE per stuck episode (re-arms after the car actually moves), so it can't spam.
    do
        -- Gate on effThrottle (device-agnostic pedal) NOT raw state.throttle: GetControlNormal(71)
        -- reads 0 on wheel/controller, so the old raw gate NEVER fired for those inputs — the whole
        -- "won't move" hunt was blind on the exact rigs that reported it. effThrottle is the synthesized
        -- pedal every input method fills. Fall back to raw only if the model hasn't run.
        local thr = state.effThrottle or state.throttle or 0.0
        local kmh = state.speedKmh or (GetEntitySpeed(veh) * 3.6)
        local rpm = state.rpm or GetVehicleCurrentRpm(veh)
        -- EXCLUDE the launch-staging gesture (handbrake + full throttle in neutral holds the car on
        -- purpose — NOT a bug). Also exclude any neutral state. Only a genuine "in gear, flooring it,
        -- not held by the handbrake, yet not moving" is a real stuck we want to capture.
        local hbNow  = hbHeld(state, veh)
        local inN    = dctNeutral or revGate == 'neutral' or (GetVehicleCurrentGear(veh) or 0) < 1
        if kmh > 5.0 then HK.stuckArmed = true end          -- car moved -> re-arm for the next episode
        if thr >= 0.85 and rpm >= 0.45 and kmh < 1.5 and not hbNow and not inN then
            if HK.stuckArmed == nil then HK.stuckArmed = true end
            HK.stuckHoldSince = HK.stuckHoldSince or now
            -- Require the condition to persist ~600ms (not a 1-frame launch/shift blip) before dumping.
            if HK.stuckArmed and (now - HK.stuckHoldSince) >= 600 then
                HK.stuckArmed = false                       -- one dump per episode
                local tcMax  = GetVehicleHandlingFloat(veh, 'CHandlingData', 'fTractionCurveMax')
                local dForce = GetVehicleHandlingFloat(veh, 'CHandlingData', 'fInitialDriveForce')
                local mfv    = GetVehicleHandlingFloat(veh, 'CHandlingData', 'fInitialDriveMaxFlatVel')
                local ud = 'n/a'
                do local ok, r = pcall(function() return IsVehicleUndriveable and IsVehicleUndriveable(veh) end)
                   if ok then ud = tostring(r) end end
                -- torqueMultApplied = last frame's FINAL torque (HK.torqueMult resets to 1.0 at the
                -- top of each frame before the mode branch cuts it, so reading it here is stale).
                print(('[hk-STUCK] WON-T-MOVE @ thr=%.2f(raw=%.2f) rpm=%.2f kmh=%.1f | mode=%s nativeGear=%d '
                    .. 'dctGear=%d gbSuspended=%s ratioWant=%s | torqueApplied=%s driveForce=%.4f '
                    .. 'tractionMax=%.3f maxFlatVel=%.1f undriveable=%s handbrake=%s | '
                    .. 'turbo{mult=%.2f spool=%.2f thrLag=%.2f}')
                    :format(thr, state.throttle or 0.0, rpm, kmh, tostring(gearMode), GetVehicleCurrentGear(veh), dctGear,
                            tostring(gbSuspended), tostring(HK.reducedRatioWant),
                            tostring(HK.torqueMultApplied), dForce, tcMax, mfv, ud,
                            tostring(GetVehicleHandbrake(veh)),
                            (HK.dbgBoost and (1.0 + (HK.dbgBoost.powerPct or 0.0) / 100.0)) or 1.0,
                            HK.turboSpool or 0.0, HK.turboThrottleMult or 1.0))
            end
        else
            HK.stuckHoldSince = nil                          -- condition broke; reset the dwell timer
        end
    end

    -- DECAY TRACER (/hkdecay) — the "power fades to less and less under throttle" hunt. Prints the
    -- FULL decomposed torque chain once/sec while ON throttle and MOVING, so we can WATCH which term
    -- collapses over time (turbo choke? AccelMatch? mfv clamp stretching gears?) instead of guessing.
    -- Gated behind HK.decayTraceOn so it's silent unless armed. Reads effThrottle (device-agnostic).
    if HK.decayTraceOn then
        local thrD = state.effThrottle or state.throttle or 0.0
        local kmhD = state.speedKmh or (GetEntitySpeed(veh) * 3.6)
        -- Fire on ANY throttle, regardless of speed: we need the torque chain WHILE STUCK at a
        -- standstill (kmh=0) as much as while decaying at speed. The old kmh>6 gate hid the stuck case.
        if thrD >= 0.5 and now >= (HK.decayTraceAt or 0) then
            HK.decayTraceAt = now + 1000
            local dd = HK.dbgDecay or {}
            local mfvLive = GetVehicleHandlingFloat(veh, 'CHandlingData', 'fInitialDriveMaxFlatVel')
            local mfvFloor = (HK.mfvFloor and HK.mfvFloor[HK.mfvFloorKey(veh)]) or -1
            -- DRIVE-COUPLING fields: applied torque was fine (>1.0) while the car sat at kmh=0, so the
            -- fault is force DELIVERY, not torque. Dump the coupling state so we see WHICH link is broken.
            local dForce = GetVehicleHandlingFloat(veh, 'CHandlingData', 'fInitialDriveForce')
            local curG   = GetVehicleCurrentGear(veh)
            local gRatio = GetVehicleGearRatio(veh, curG) or -1
            local ud = 'n/a'
            do local ok, r = pcall(function() return IsVehicleUndriveable and IsVehicleUndriveable(veh) end)
               if ok then ud = tostring(r) end end
            print(('[hk-DECAY] kmh=%.1f thr=%.2f rpm=%.2f gear=%d | applied=%.3f = turbo=%.3f x hit=%.3f x accelMatch=%.3f | '
                .. 'COUPLE{driveForce=%.4f gearRatio=%.3f ratioWant=%s suspended=%s undriveable=%s hbrake=%s} | '
                .. 'spool=%.2f moveGate=%.2f | mfv live=%.1f floor=%.1f (x%.2f)')
                :format(kmhD, thrD, state.rpm or 0.0, curG,
                        HK.torqueMultApplied or 1.0, dd.turboMult or 1.0, dd.hitMult or 1.0, dd.accelMatch or 1.0,
                        dForce, gRatio, tostring(HK.reducedRatioWant), tostring(gbSuspended), ud,
                        tostring(GetVehicleHandbrake(veh)),
                        dd.spool or 0.0, dd.moveGate or 0.0,
                        mfvLive or -1, mfvFloor, (mfvFloor > 0 and mfvLive and mfvLive / mfvFloor) or 0.0))
        end
    end

    -- [F3] MUSCLE HANDBRAKE BUG GUARD — speed + throttle gated. Decides whether the
    -- box should mimic native [6] this tick (gbSuspended). Runs FIRST so the early
    -- return below skips all box logic while suspended. Danger = class 4 + gear 1/2 +
    -- handbrake held, in EITHER of two cases:
    --   (a) LOW SPEED (<= SuspendBelowKmh): the handbrake alone is enough — under this
    --       speed it dumps the whole velocity vector regardless of throttle, so the old
    --       "on the gas = safe" gate leaked the bug. Throttle is IGNORED here.
    --   (b) higher speed but OFF the throttle (<= ThrottleOff): the original launch case.
    -- Resume when the handbrake is released, OR we've climbed clear of the danger zone
    -- (above ResumeAboveKmh AND back on the gas). Hysteresis on both speed and throttle.
    do
        local wg = Config.WheelieGuard
        -- LAUNCH OVERRIDE: never suspend while a launch is STAGED/LIVE or being STAGED. A launch
        -- stage is LOGICAL neutral (targetGear==0) + handbrake + FULL throttle at a dead standstill
        -- — there's no velocity to dump (the flip the guard defends against needs momentum), and
        -- the launch system owns the engine/gear state throughout. The bug this caused: at WOT in
        -- neutral GTA's native box momentarily engages gear 1, so `state.gear` reads 1 and tripped
        -- `class4 + gear1 + handbrake + standstill` -> the guard suspended and the early
        -- `if gbSuspended then return` below skipped the ENTIRE seq branch incl. the launch stage,
        -- so launchStageTick never ran to advance lcPhase = the LC pill flickered up then died
        -- (MANUAL-SEQ muscle only; non-muscle test cars never hit the guard). We must detect the
        -- staging INTENT here (NOT lcPhase — the guard runs BEFORE the stage block, so keying on
        -- lcPhase deadlocks: it can never leave 'off' if the stage code is skipped). Use the
        -- LOGICAL gear (targetGear==0, a module upvalue — reliable, unlike native state.gear which
        -- reads 1 at WOT) + handbrake + WOT + genuinely stopped. The real flip is a MOVING car
        -- grabbing the handbrake, which this can't match (targetGear>=1 while moving).
        local L = Config.Gearbox.Launch or {}
        local eff = state.effThrottle or state.throttle or 0.0
        local staging = (targetGear == 0)
                        and state.handbrake
                        and eff >= (L.StageThrottle or 0.90)
                        and (state.speedKmh or 0.0) <= (L.StageMaxKmh or 4.0)
        local launchActive = (lcPhase == 'staged') or (lcPhase == 'launched') or staging
        local active = wg and wg.Enabled
                       and (not wg.OnlyMuscle or state.class == 4)   -- 100% only Muscle
                       and (state.gear or 0) >= 1
                       and (state.gear or 0) <= (wg.MaxGear or 2)
                       and not launchActive                          -- launch owns the engine; stand the guard down
        if launchActive and gbSuspended then
            -- Launch staging while the guard was mid-suspend: resume so the launch branch runs.
            gbSuspended = false
            engineWritesSuspended = false
            HK.gbSuspendCoast = false
            muscleGuardReassertTransmission(veh)
        end
        if active then
            local thr    = state.throttle or 0.0
            local kmh    = state.speedKmh or 0.0
            local noseOk = (not wg.RequireNoseUp) or (state.pitch or 0.0) >= (wg.NoseUpPitch or 3.0)
            if not gbSuspended then
                -- SUSPEND while handbraked when EITHER low-speed (any throttle) OR off the gas.
                local lowSpeed = kmh <= (wg.SuspendBelowKmh or 25.0)
                local offGas   = thr <= (wg.ThrottleOff or 0.15)
                if state.handbrake and (lowSpeed or offGas) and noseOk then
                    gbSuspended = true
                    engineWritesSuspended = true
                    HK.gbSuspendCoast = false        -- handbrake-reason suspend
                    -- Full [6] stand-down: also drop the transmission enabler (the
                    -- persistent state that plain write-suspension missed).
                    vl_setTransmissionReducedGearRatio(veh, false)
                elseif wg.CoastGuard and offGas and (kmh <= (wg.CoastBelowKmh or 22.0)) and noseOk then
                    -- COAST WINDOW (NO handbrake): the native velocity-dump snap on muscle
                    -- addon cars ALSO fires on a plain coast-to-idle (~15 km/h, gear 1/2,
                    -- off gas) — same rigid-body root as the handbrake flip, minus the
                    -- handbrake. Stand the box down to native [6] through the snap band so
                    -- the script stops forcing transmission/engine state (native [6] is
                    -- immune). No brake plant here — a coast must NOT gain braking.
                    gbSuspended = true
                    engineWritesSuspended = true
                    HK.gbSuspendCoast = true          -- coast-reason suspend (different resume)
                    vl_setTransmissionReducedGearRatio(veh, false)
                end
            else
                if HK.gbSuspendCoast then
                    -- COAST RESUME: no handbrake to release, so throttle is the trigger.
                    -- Resume the INSTANT you're back on the gas (any speed) so accelerating
                    -- away from low speed is never stuck in native — or once clear of the band.
                    local backOnGas = thr >= (wg.ThrottleOn or 0.35)
                    local cleared   = kmh >= (wg.CoastResumeKmh or 28.0)
                    if backOnGas or cleared then
                        gbSuspended = false
                        engineWritesSuspended = false
                        HK.gbSuspendCoast = false
                        muscleGuardReassertTransmission(veh)
                    end
                else
                    -- HANDBRAKE RESUME: handbrake released (bug window over), OR clearly out of
                    -- the danger zone = fast enough AND back on the gas. While slow + handbraked
                    -- we STAY suspended even on the gas (that's exactly case (a) above).
                    local clearOfZone = (kmh >= (wg.ResumeAboveKmh or 33.0))
                                        and (thr >= (wg.ThrottleOn or 0.35))
                    if (not state.handbrake) or clearOfZone then
                        gbSuspended = false
                        engineWritesSuspended = false
                        muscleGuardReassertTransmission(veh)
                    end
                end
            end
        else
            -- Out of scope (wrong class/gear/disabled): clear so it can't get stuck
            -- suspended across a gear/class change.
            if gbSuspended then
                gbSuspended = false
                engineWritesSuspended = false
                HK.gbSuspendCoast = false
                muscleGuardReassertTransmission(veh)
            end
        end
    end

    -- While suspended, behave EXACTLY like native [6]: run no box logic this tick.
    -- STALE-GEAR-DISPLAY FIX (2026-08-14): the early return below sits BEFORE the shift-input
    -- promotion (~line 4628) and the per-mode shift ladders — so on a class-4 muscle MANUAL/SEQ
    -- car, while the CoastGuard/WheelieGuard stood the box down (low-speed coast / handbrake),
    -- a gear change never registered: targetGear froze, and since GetDisplayGear returns targetGear
    -- the speedo showed the OLD gear until the player throttled and the guard resumed (the pending
    -- press then fired late). The physical stand-down must stay, but the LOGICAL gear selection is
    -- physically INERT while suspended — vl_setCurrentGear is no-op'd by engineWritesSuspended and
    -- we never re-enable ReducedGearRatio here — so we can safely advance targetGear for the display.
    -- Step it directly (no shift window: a suspended commit block would never run); on resume the
    -- box pins native to targetGear as normal. Mirrors the real ladder's R<->N<->1..gearcount rungs.
    -- Consume the pending press so the post-resume promotion can't double-fire the same shift.
    if gbSuspended then
        if (gearMode == 1 or gearMode == 6) and not (upHeld and downHeld) then
            local chordMs = (Config.Gearbox.NeutralChordMs or 40)
            local up = pendUpAt   > 0 and (now - pendUpAt)   >= chordMs
            local dn = pendDownAt > 0 and (now - pendDownAt) >= chordMs
            if up then
                pendUpAt = 0
                if     targetGear == -1 then preNeutralGear = 1; targetGear = 0
                elseif targetGear == 0  then
                    targetGear = (preNeutralGear and preNeutralGear >= 1 and preNeutralGear <= gearcount)
                                 and preNeutralGear or 1
                elseif targetGear >= 1 and targetGear < gearcount then targetGear = targetGear + 1 end
            elseif dn then
                pendDownAt = 0
                if     targetGear >= 2 then targetGear = targetGear - 1
                elseif targetGear == 1 then preNeutralGear = 1; targetGear = 0
                elseif targetGear == 0 then
                    -- N->R: match the live ladder — near-stop gate ONLY when RealisticReverseManual.
                    local okR = (not Config.Gearbox.RealisticReverseManual)
                                or (state.speedKmh or 0) < (Config.Gearbox.ReverseMaxKmh or 8.0)
                    if okR then targetGear = -1 end
                end
            end
        end
        return
    end

    -- ============================================================================
    -- /handlingdbg SNAPSHOT (mode-independent gear internals). Only builds when the
    -- overlay is on (HK.hdbgOn) so there's zero cost in normal play. Mode-specific
    -- live values (DCT shift window, target gear) are filled in inside the DCT branch.
    -- All values here are read straight from natives / module state = ground truth.
    if HK.hdbgOn then
        local d = HK.dbgGear or {}
        HK.dbgGear = d
        d.at         = now
        d.gearMode   = gearMode                                   -- INTERNAL engine (1/2/3/4/5/6)
        d.publicType = HK.dbgPublicType                           -- PUBLIC type (0-6), post-upgrade
        d.publicLabel= HK.dbgPublicLabel                          -- "Automatic (Paddle)" etc.
        d.nativeGear = GetVehicleCurrentGear(veh)                 -- GTA's own gear index
        d.targetGear = targetGear                                 -- OUR logical gear (-1 R / 0 N / 1..n)
        d.revGate    = revGate                                    -- reverse-gate state ('none'|'neutral'|'reverse')
        d.highGear   = gearcount                                  -- top gear (upgrade-aware)
        d.rpmNative  = GetVehicleCurrentRpm(veh)                  -- what GTA reports RIGHT NOW (incl. our paints)
        d.rpmState   = state.rpm or 0.0                           -- our per-frame snapshot (pre mode-branch)
        d.throttle   = state.throttle or 0.0
        d.speedKmh   = state.speedKmh or 0.0
        -- ratio MODE (mode switch) + its label
        d.ratioMode  = HK.dbgRatioMode
        d.ratioLabel = HK.dbgRatioLabel
        -- ACTUAL current native gear ratio (x.xx), plus our per-shift multipliers so you can
        -- see both "which mode" and "the x-times numbers" the mode applies.
        d.gearRatio  = (d.nativeGear and GetVehicleGearRatio(veh, d.nativeGear)) or 0.0
        if gbRatio then
            d.upMult   = gbRatio.UpshiftRpmMult or 1.0
            d.downMult = gbRatio.DownshiftRpmMult or 1.0
            d.shiftTMult = gbRatio.ShiftTimeMult or 1.0
            d.lowTMult = gbRatio.LowGearTorque or 1.0
            d.inertMult = gbRatio.DriveInertiaMult or 1.0
            d.dfPct    = gbRatio.DriveForcePct or 0.0
        end
        d.rawShiftMs = gbRawShiftMs                               -- handling.meta-derived shift time
        d.flyMass    = HK.flyMass                                 -- auto-detected flywheel factor (<1 light, >1 heavy)
        d.flyBase    = HK.flyInertiaBase                          -- the fDriveInertia it was derived from
        d.flyBrake   = HK.dbgFlyBrake                             -- Phase-B engine-braking nudge {nudge,eng,ni,base} or nil
        -- OUR calculated rpm for the CURRENT gear from the learned ratio (rps * speed) — this is
        -- the "script-computed" rpm the shift logic reasons about, vs the native reading above.
        d.rpmCalc    = projectRpmFor(d.nativeGear, state)         -- nil if gear ratio not learned yet
        -- clear DCT-only fields; the DCT branch refills them when active
        if gearMode ~= 3 and gearMode ~= 4 and gearMode ~= 5 then
            d.dctGear, d.dctCommitted, d.dctPending, d.dctWin, d.dctSub, d.dctNeutral = nil, nil, nil, nil, nil, nil
        end
    end

    -- ============================================================================
    -- REDUCED-GEAR-RATIO WATCHDOG — the fix for "car won't move, revs ramp slowly, then
    -- 500km/h in one tall gear" (reduced-ratio stuck OFF = GTA's native TALL gearing).
    -- ROOT CAUSE: the normal-learner and the muscle-handbrake guard BOTH suspend via the SHARED
    -- gbSuspended flag and toggle reduced-ratio; a colliding/missed resume (learner arms a native
    -- pull -> ratio OFF, muscle guard's resume clears gbSuspended, learner's later resume then
    -- sees gbSuspended==false and skips re-asserting) can leave reduced-ratio OFF with nobody
    -- re-enabling it -> GTA's native tall gears -> the bug.
    -- We reach here only when NOT gbSuspended, so reduced-ratio must match the MODE'S intent:
    --   * mode 1 (manual) / mode 6-internal (sequential) -> ON (script owns gears)
    --   * DCT tiers (3/4/5) once started (dctStarted) -> ON, EXCEPT the free-rev-neutral backstop
    --     (HK.dctNeutralRatioOff) which intentionally holds it OFF
    --   * comfort auto (mode 2) -> OFF (by design: GTA's own box drives) -> DON'T touch
    --   * isEV / hybrid e-mode -> OFF (want GTA full ratios) -> DON'T touch
    --   * isEasy() (expert/legacy) -> never touch the transmission
    -- Only ACTS when the mode wants ON but our tracked intent drifted OFF (the stuck case).
    -- THROTTLED part (4x/sec): decide whether this car's mode WANTS reduced-ratio ON, using a
    -- LIVE model electric-check (not the cached flags, which can go stale on a get-off/on). Cache
    -- the decision on HK.reducedRatioWantOn for the cheap every-frame re-assert below.
    if not isEasy() and applied and now >= (HK.reducedRatioCheckAt or 0) then
        HK.reducedRatioCheckAt = now + 250
        local modelIsElectric = false
        do
            -- GetIsVehicleElectric marshals as the NUMBER 1 (not boolean true) under CfxLua.
            -- `elec == true` was FALSE for 1 -> the self-heal below wrongly cleared isEV on a real
            -- EV (Plaid) -> downgraded to comfort-auto (dead regen, no drift, stuck D3). Truthy-check.
            local ok, elec = pcall(GetIsVehicleElectric, GetEntityModel(veh))
            if ok and (elec == true or elec == 1) then modelIsElectric = true end
        end
        -- Honor an EV/e-mode ratio-OFF skip ONLY if the model actually IS electric OR a config
        -- hybrid. A cached isEV/hybridEMode=true on a non-electric model = STALE -> ignore + clear.
        local reallyElectric = modelIsElectric or (isHybrid == true)
        local evLike = (isEV == true or hybridEMode == true) and reallyElectric
        local wantOn
        if evLike then
            wantOn = false
        elseif gearMode == 1 or gearMode == 6 then
            wantOn = true
        elseif gearMode == 3 or gearMode == 4 or gearMode == 5 then
            wantOn = (dctStarted == true) and (HK.dctNeutralRatioOff ~= true)
        else
            wantOn = false                       -- comfort auto (2) / anything else: leave native
        end
        HK.reducedRatioWantOn = wantOn
        -- STALE-FLAG SELF-HEAL: cached EV/eMode claims electric but the model isn't (and not a
        -- config hybrid) -> stale from a mispaired Enable; clear so the tick treats it correctly.
        if (isEV == true or hybridEMode == true) and not reallyElectric then
            if Config.Gearbox.Debug then
                print(('[hk-ratiowd] STALE EV/eMode flag on non-electric model -> clearing (mode=%s)')
                    :format(tostring(gearMode)))
            end
            isEV = false
            hybridEMode = false
            eReducedRatioOff = false
        end
    end

    -- AUTHORITATIVE BAND (Phase 1) — when ON, WE author the ratio table so the fold never reaches
    -- physics. This SUPERSEDES the reduced-ratio toggle + mfv clamp below (both skipped via authActive).
    -- Retry the capture if entry read a folded/transient table; once ready, cheap per-frame safety
    -- re-write of the clean band (ratio-only, no re-setup so no re-fold). Phase 1 passes stock anchors
    -- (nil => band.mfv/force); Phase 2 will pass mod-stacked targets here.
    local authActive = false
    if Config.Gearbox and Config.Gearbox.AuthoritativeBand and applied and not isEasy() and not HK.ratioProbeHold then
        if not HK.authBandReady and (HK.authBandRetryUntil or 0) > now then
            if HK.AuthBand_Capture(veh) then
                HK.authBandReady = true
                HK.AuthBand_Apply(veh, nil, nil, true)   -- re-setup + author once we finally read clean
            end
        end
        if HK.authBandReady then
            -- LIVE POWER DIAL (/gbpower). band.mfv/force are the stock (Phase-1) anchors; these mults
            -- scale them so you can dial modded power/top-speed LIVE and feel where the lugging stops.
            -- Default 1.0 = stock (no change). A mult CHANGE needs one resetup (ModifyVehicleTopSpeed)
            -- for the new mfv/force to apply; steady state stays ratio-only (cheap, no re-fold).
            local band = HK.cleanBand
            local fMult = HK.powerForceMult or 1.0
            local mMult = HK.powerMfvMult or 1.0
            local mfvT   = band and band.mfv   and (band.mfv   * mMult)
            local forceT = band and band.force and (band.force * fMult)
            local changed = (HK.powerMultLast ~= (fMult .. ':' .. mMult))
            if changed then
                HK.powerMultLast = fMult .. ':' .. mMult
                HK.AuthBand_Apply(veh, mfvT, forceT, true)    -- one resetup to apply new mfv/force
                if (fMult ~= 1.0 or mMult ~= 1.0) then
                    print(('[hk-power] applied forceMult=%.2f (%.4f) mfvMult=%.2f (%.1f)')
                        :format(fMult, forceT or -1, mMult, mfvT or -1))
                end
            else
                -- steady: ratio-only re-write, but keep force pinned to the dialed target every frame
                -- (the external-zero catcher pins to lastDriveForce; when dialed we want the boosted value).
                HK.AuthBand_Apply(veh, nil, nil, false)
                if forceT and forceT > 0 and (fMult ~= 1.0) then
                    lastDriveForce = forceT   -- so setDriveForce dedupe + zero-catcher use the boosted value
                    SetVehicleHandlingFloat(veh, 'CHandlingData', 'fInitialDriveForce', forceT + 0.0)
                end
            end
            authActive = true
        end
    end

    -- EVERY-FRAME re-assert (the actual fix). DIAGNOSED LIVE via /gbstate: mode=4 ratioWant=true
    -- gbSuspended=false isEV/isHybrid=false, yet the car was stuck on native TALL gears — meaning
    -- the NATIVE reduced-ratio flag was reset OFF by an external pool re-sync (parking's
    -- SetVehicleProperties, entity-control migration, mod menu, vehicle re-stream) while our mirror
    -- still said "true, already set" so nothing re-asserted. GTA exposes NO getter for the flag, so
    -- we can't detect the drift — we just re-assert ON every frame the mode wants it. The native
    -- (0x337EF33DA3DDB990) is an idempotent bool set; re-calling when already on is a no-op, so
    -- this is cheap and eliminates the up-to-250ms stuck window a throttled re-assert would leave.
    -- SKIPPED when authActive: the authored band owns the ratio table; the toggle would fight it.
    if not authActive and HK.reducedRatioWantOn == true and applied and not isEasy() and not HK.ratioProbeHold then
        vl_setTransmissionReducedGearRatio(veh, true)
    end

    -- MAX-FLAT-VEL GUARD — BACKSTOP for "won't move / tall gear / 500km/h". SOURCE IDENTIFIED:
    -- the "corruptor" that raised fInitialDriveMaxFlatVel 300.1 -> 617.7 (~2.06x) was NOT external
    -- — it was GTA recomputing the drivetrain after a TRANSMISSION/engine mod (/maxmods,
    -- /admincustoms apply SetVehicleMod 11/13 + turbo). The PRIMARY fix is now the drivetrain-mod
    -- fingerprint re-snapshot in the entry-watcher: when mods change, we Disable->Enable so
    -- `origins` re-captures the MODDED maxFlatVel (origin==live => this guard goes silent, no
    -- fight). This guard stays as a cheap backstop for the OTHER raise path — an entity re-stream/
    -- control migration that restores handling from a state snapshot on a frame where our origins
    -- is (briefly) the older baseline. It only ever RESTORES DOWN to origin (we never raise
    -- maxFlatVel), so with an accurate post-mod origin it can't clamp a legitimately-modded car.
    -- Throttled 4x/sec (cheap).
    -- Clamp to the IMMUTABLE FLOOR (HK.mfvFloor), NOT origins — origins can drift up
    -- when the re-snapshot re-captures an already-corrupted value (that was the guard's own bug:
    -- anchor climbed 300->384->491 with the corruptor). The floor only ever goes DOWN, so it's a
    -- stable anchor that can't be poisoned by a corrupt capture.
    -- EVERY-FRAME clamp (NOT throttled): lambra-tunerChipV2 (config topSpeed=28 => x1.28) re-raises
    -- fInitialDriveMaxFlatVel CONTINUOUSLY, so the old 4x/sec (250ms) clamp lost ~249ms of every
    -- 250ms to the raised value. A raised maxFlatVel stretches EVERY gear taller => the real
    -- engine revs LOW at any speed => state.rpm never reaches upRpm => the DCT-auto upshift never
    -- fires => "stuck in gear 1, won't upshift". Clamping every frame holds the honest gearing so
    -- the car revs out and shifts normally, AND enforces the top-speed HARD invariant against the
    -- chip (its accel/turbo boosts are separate fields, untouched).
    -- FLOOR IS FINGERPRINT-KEYED (2026-08-14): a transmission/engine mod earns its OWN higher floor
    -- (256 with 9 gears), so this clamp NO LONGER drags a legitimately trans-modded car back to its
    -- stock top speed (the 6->7->8->9 bog). The lambra chip shares the current fingerprint's floor
    -- (it holds no mod slot), so its continuous raise still clamps down. The READ is one cheap
    -- native/frame; the WRITE + reseed + print only happen while actually corrupted.
    -- SKIPPED when authActive: the authoritative writer owns mfv (it writes fInitialDriveMaxFlatVel
    -- itself before its ModifyVehicleTopSpeed re-setup), so the legacy floor/ceiling clamp must stand
    -- down or the two fight over the same field.
    local mfvAnchor = HK.mfvFloor and HK.mfvFloor[HK.mfvFloorKey(veh)]
    if not authActive and mfvAnchor and mfvAnchor > 0 and not HK.mfvClampOff then
        local liveMFV = GetVehicleHandlingFloat(veh, 'CHandlingData', 'fInitialDriveMaxFlatVel')
        -- CEILING CLAMP (2026-08-16 — replaces the stock-floor clamp; the real spawn-with-mods fix).
        -- OLD behaviour: force mfv down to the captured floor EVERY frame. But on a car spawned WITH
        -- mods the floor captures STOCK (210.1) — GTA lags the modded recompute past Gearbox_Enable —
        -- so the clamp dragged the modded car back to stock top speed, shortening every gear until the
        -- rev-limiter cap engaged early => won't upshift / bogs / loses torque (this whole session).
        -- KEY NUMBERS (live): the lambra chip raises mfv to floor*~1.06 (210.1->222.7, giving the clean
        -- 334 top the user wants; 222.7->236.1 when floor was already modded). It is NOT a runaway — it
        -- applies a fixed ratio over the base. The ONLY thing we must still block is the genuine
        -- CORRUPTOR (an entity-restream / control-migration that doubled mfv 300->617 = the "500km/h in
        -- one tall gear" bug). So: instead of clamping DOWN to the floor, allow mfv to RIDE UP to a
        -- ceiling = floor * MfvCeilingRatio (default 1.12, comfortably above the chip's ~1.06 but well
        -- under a 2x corruption). Below the ceiling we leave mfv ALONE (the car keeps the chip's honest
        -- top speed + tall gears); only ABOVE the ceiling do we clamp, and we clamp TO the ceiling (not
        -- the floor) so a legit chip is never punished. No adoption, no floor mutation => CANNOT ratchet
        -- (the SettleVerify failure mode). The ratio-based speed-cap + seed now ride the real live mfv.
        local ceilRatio = Config.Gearbox.MfvCeilingRatio or 1.12
        local ceiling   = mfvAnchor * ceilRatio
        if liveMFV and liveMFV > ceiling then
            -- Above the ceiling = corruption (not the chip). Clamp to the CEILING (keeps the chip's
            -- allowance) rather than the stock floor, so we kill runaway without nerfing the mod.
            vl_setHandling(veh, 'fInitialDriveMaxFlatVel', ceiling)
            -- Reseed the ratio basis + log the catch, THROTTLED to 1/sec. Seed to the CEILING (the value
            -- physics now holds) so gbRpmPerSpeed/projectGearRpm match the clamped top speed.
            if now >= (HK.maxFlatVelCheckAt or 0) then
                HK.maxFlatVelCheckAt = now + 1000
                print(('[hk-mfv] CORRUPTION CAUGHT (over ceiling) live=%.1f ceiling=%.1f floor=%.1f (x%.2f) '
                    .. '-> clamped to ceiling | mode=%s nativeGear=%d dctGear=%d kmh=%.0f')
                    :format(liveMFV, ceiling, mfvAnchor, liveMFV / mfvAnchor, tostring(gearMode),
                            GetVehicleCurrentGear(veh), dctGear, (GetEntitySpeed(veh) * 3.6)))
                seedGearRatios(veh, ceiling)
            end
        end
    end

    -- SEED SELF-HEAL. seedGearRatios only commits the monotonic PREFIX of the ratio table and clears
    -- any folded tail to nil (see its monotonicity guard). At Enable the table is often still in its
    -- transient FOLDED state, so the top gears (g8/g9 on the modded 911ts) get skipped and stay nil —
    -- and if mfv already sits at the floor, the corruption-catch reseed above never fires to fix them.
    -- So retry periodically until the SETTLED table seeds every gear cleanly, then lock. Cheap: a
    -- 1/sec re-seed that self-disables the instant HK.ratioSeedComplete flips true. Uses the mfv floor
    -- as the basis (same as the corruption path) so the seed matches the clamped physics.
    if HK.ratioSeedComplete == false and applied and now >= (HK.ratioSeedHealAt or 0) then
        HK.ratioSeedHealAt = now + 1000
        -- Basis = LIVE mfv (what physics holds after the ceiling clamp), so the seed matches the real
        -- top speed of a chip-raised modded car, not the stock floor. Falls back to floor/origins.
        local basis = (veh and GetVehicleHandlingFloat(veh, 'CHandlingData', 'fInitialDriveMaxFlatVel'))
        if not (basis and basis > 0) then
            basis = mfvAnchor or (origins and origins.fInitialDriveMaxFlatVel)
        end
        if basis and basis > 0 then seedGearRatios(veh, basis) end
    end

    -- EXTERNAL-RESYNC GUARD: detect when jim's pushVehicle (/admincustoms) or an
    -- entity-control migration re-synced fInitialDriveForce out from under our write-
    -- cache, and invalidate the dedupe mirror so the tick re-asserts. Fixes the stuck-
    -- at-0-velocity bug. Throttled internally; safe every frame. (Runs BEFORE the mode
    -- branches so whichever branch re-engages drive force this frame will actually write.)
    if Config.Gearbox.DriveForceResync ~= false then
        driveForceResyncCheck(veh, now)
    end

    -- PER-FRAME EXTERNAL-ZERO CATCHER (2026-08-15 — the confirmed "loses torque at speed" fix).
    -- Ring-buffer telemetry proved an external resource (escrowed lambra chip / jim turbo write on
    -- owned+modded cars) intermittently writes fInitialDriveForce=0 for ~150ms at a time, mid-gear,
    -- while WE intend drive live (torqueApplied stayed 1.1-1.2 the whole window = not a shift). The
    -- 250ms-throttled resync above only heals it on its next sweep, and the setDriveForce dedupe
    -- won't re-write because the mirror still reads our positive value. So: EVERY frame, if our
    -- mirror says drive should be LIVE (>0) but the live float has been zeroed out from under us,
    -- re-assert immediately. Only fires when actually clobbered (one native read/frame otherwise),
    -- and never fights a legitimate decouple (mirror==0 during a shift/neutral is skipped).
    if Config.Gearbox.DriveForceZeroCatch ~= false
       and lastDriveForce and lastDriveForce > 0.0005 then
        local liveDF = GetVehicleHandlingFloat(veh, 'CHandlingData', 'fInitialDriveForce')
        if liveDF and liveDF < 0.0005 then
            SetVehicleHandlingFloat(veh, 'CHandlingData', 'fInitialDriveForce', lastDriveForce + 0.0)
            HK.dfZeroCatchCount = (HK.dfZeroCatchCount or 0) + 1
            HK.dfZeroCatchLast = now
            if Config.Gearbox.Debug then
                print(('[hk-gearbox] external-zero caught: live=0 -> re-asserted %.4f (count=%d)')
                    :format(lastDriveForce, HK.dfZeroCatchCount))
            end
        end
    end

    -- NEUTRAL GESTURE — a SINGLE simultaneous press of BOTH shift keys (within
    -- NeutralChordMs). Sets reqNeutralTap, consumed by the AUTOMATIC branches below as a
    -- TOGGLE (tap -> N, tap again -> drive). MANUAL classes ignore reqNeutralTap and use
    -- HOLD-both instead (bothHeld). A lone press waits out the chord window before becoming
    -- a real shift, so the two keys of the chord don't each fire a stray shift first.
    -- (The old double-tap/quad-tap latched-neutral gesture was RETIRED — one gesture per
    -- class now: tap-both for autos, hold-both for manuals.)
    do
        local chordMs = (Config.Gearbox.NeutralChordMs or 40)
        -- CHORD: both keys became pending (pressed) within chordMs of each other = a
        -- simultaneous both-press. Fire reqNeutralTap once and consume the pending shifts.
        if pendUpAt > 0 and pendDownAt > 0 and math.abs(pendUpAt - pendDownAt) <= chordMs then
            reqNeutralTap = true
            pendUpAt, pendDownAt, reqUp, reqDown = 0, 0, false, false     -- cancel stray shifts
            upTapAt, upTapPrev, downTapAt, downTapPrev = 0, 0, 0, 0
        end
        -- Lone-press -> real shift once the small chord window passes without the other
        -- key joining (so it wasn't a both-press chord).
        if not reqNeutralTap then
            if pendUpAt > 0 and (now - pendUpAt) >= chordMs then
                reqUp = true; pendUpAt = 0
            end
            if pendDownAt > 0 and (now - pendDownAt) >= chordMs then
                reqDown = true; pendDownAt = 0
            end
        end
    end

    -- One-time start. If we entered a STATIONARY car, begin in NEUTRAL (like
    -- keying on / sitting parked). If we climbed into a moving car, engage 1st
    -- normally (no phantom neutral mid-drive). Runs once, regardless of engine
    -- state (the game auto-starts the driver's engine anyway).
    if not started then
        if enteredMoving then
            vl_setCurrentGear(veh, 1)
            targetGear = 1
        else
            vl_setCurrentGear(veh, 0)
            targetGear = 0                 -- neutral; coast handled via inNeutral
            preNeutralGear = 1             -- first shift out of neutral goes to 1st
        end
        started = true
        return
    end

    -- GEAR-RATIO: LOW-GEAR LAUNCH PUNCH (drag/hyper). A torque multiplier in gears
    -- 1-2 under throttle — the "short low gears pull hard" feel WITHOUT changing real
    -- top speed. Mode-agnostic (runs before any mode branch); gear 3+ unaffected, and
    -- the neutral/shift branches below hard-set torqueMult=0.0 so this never leaks
    -- into a decoupled frame. >1 = punch, 1.0 = no-op.
    if gbRatio and gbRatio.LowGearTorque and gbRatio.LowGearTorque ~= 1.0 then
        local g = state.gear or 0
        if g >= 1 and g <= 2 and (state.throttle or 0) > 0.5 then
            HK.torqueMult = HK.torqueMult * gbRatio.LowGearTorque
        end
    end

    -- SPEED CALIBRATION (/setspeed) — PER-GEAR torque trim that nudges the car onto
    -- its admin-set real-life 0-X figures. The factor is chosen by the car's ACTUAL
    -- current gear (slot = gear 1/2/3/4+), so it rides GTA's real gear ratios and a
    -- correction to one gear never disturbs another. Pure torque (never rpm/gear, so
    -- no bog/wheelie), bidirectional (a gear can pull harder OR softer). Throttle-gated:
    -- only shapes accel under power; coast/brake untouched. nil = no calibration = no-op.
    if gbSpeedCal and not gbSpeedCalSuspend and (state.throttle or 0) > 0.5 then
        local f = speedCalFactorForGear(gbSpeedCal, state.gear or 1)
        if f ~= 1.0 then HK.torqueMult = HK.torqueMult * f end
    end

    -- ACCEL MATCH (speed-invariant guard) — torque-only trim that claws back the
    -- ~0.3-0.8s our smarter box gains over GTA in the mid-speed bog band, so 0-100
    -- lands back near .meta. A smooth TRAPEZOID over ABSOLUTE km/h (the bog band is a
    -- fixed low-gear phenomenon at real road speed, so absolute km/h tracks it on both
    -- a Chiron and an M3 — a top-speed fraction does not). 1.0 below FadeInLo (launch
    -- safe), smoothstep up to full CurveDepth across the plateau, smoothstep back to
    -- 1.0 by FadeOutHi (top speed safe). Trim is always <=1.0 — can NEVER add power.
    if gbAccelTrim > 0.0 then
        local AM  = Config.Gearbox.AccelMatch
        local kmh = state.speedKmh or 0.0
        local thr = state.throttle or 0.0
        local inLo, inHi = AM.FadeInLoKmh or 48.0, AM.FadeInHiKmh or 66.0
        local outLo, outHi = AM.FadeOutLoKmh or 102.0, AM.FadeOutHiKmh or 150.0
        local w = 0.0                                   -- 0 = no trim, 1 = full depth
        if kmh > inLo and kmh < outHi then
            if kmh < inHi then
                local t = (kmh - inLo) / math.max(inHi - inLo, 1e-4)
                w = t * t * (3.0 - 2.0 * t)             -- smoothstep fade IN
            elseif kmh <= outLo then
                w = 1.0                                 -- plateau (full depth)
            else
                local t = (kmh - outLo) / math.max(outHi - outLo, 1e-4)
                w = 1.0 - (t * t * (3.0 - 2.0 * t))     -- smoothstep fade OUT
            end
        end
        -- THROTTLE GATE: only trim when actually accelerating (>~half throttle). But
        -- some input methods read 0 on GetControlNormal(71); if rpm is high AND we're
        -- climbing in the band, treat as on-power too. Coast/brake => no trim.
        local onPower = thr > 0.5 or (state.rpm or 0) > 0.55
        HK.dbgDecay = HK.dbgDecay or {}
        HK.dbgDecay.accelMatch = (w > 0.0 and onPower) and (1.0 - (AM.CurveDepth or 0.0) * w) or 1.0
        if w > 0.0 and onPower then
            HK.torqueMult = HK.torqueMult * (1.0 - (AM.CurveDepth or 0.0) * w)
            if AM.Debug then
                print(('[hk-accelmatch] kmh=%.0f thr=%.2f rpm=%.2f w=%.2f trim=%.2f torqueMult=%.2f'):format(
                    kmh, thr, state.rpm or 0, w, 1.0 - (AM.CurveDepth or 0.0) * w, HK.torqueMult))
            end
        end
    end

    -- ACCEL STRETCH — GLOBAL low-speed accel-time governor (ALL cars, all modes). GTA launches every
    -- car far too hard (Senna 0-100 ~1.78s in-game vs ~2.7s real); this is a game low-speed flaw, not
    -- our .meta, so it runs for everyone regardless of tune/expertise. A uniform cut-only torque trim
    -- across the 0->100 km/h band multiplies BOTH 0-60 and 0-100 TIME by ~1/(1-Depth). Composes on top
    -- of AccelMatch/SpeedCal above (all cut-only, so they only ever slow). Road-speed based + skipped
    -- when another system owns torque (launch/free-rev/drift) so it never starves those.
    do
        HK.accelStretchW, HK.accelStretchOnPower = 0.0, false
        local AS = Config.Gearbox.AccelStretch
        if AS and AS.Enabled and not HK.freeRevActive
           and not (HK.launch and HK.launch.active == true)
           and HK.driftMode ~= true and not HK.inReverseGear then
            local kmh = state.speedKmh or 0.0
            local inLo, inHi = AS.FadeInLoKmh or 2.0, AS.FadeInHiKmh or 8.0
            local fullTo, outHi = AS.FullToKmh or 100.0, AS.FadeOutHiKmh or 118.0
            local w = 0.0
            if kmh > inLo and kmh < outHi then
                if kmh < inHi then
                    local t = (kmh - inLo) / math.max(inHi - inLo, 1e-4)
                    w = t * t * (3.0 - 2.0 * t)         -- smoothstep fade IN
                elseif kmh <= fullTo then
                    w = 1.0                             -- full cut across the sprint
                else
                    local t = (kmh - fullTo) / math.max(outHi - fullTo, 1e-4)
                    w = 1.0 - (t * t * (3.0 - 2.0 * t)) -- smoothstep fade OUT (top speed safe)
                end
            end
            local thr = state.throttle or 0.0
            local onPower = thr > 0.5 or (state.rpm or 0) > 0.55
            -- POWER-SCALED depth: GTA over-launches by roughly how much power the car has (a 1000hp car
            -- that should shred its tyres just hooks up; a slow car is only mildly too fast). A FLAT depth
            -- therefore overshoots slow cars (~0.8s too long on the 0-100). Scale by HK.flyMass — the
            -- Enable-derived mass/power signal (fm<1 = light/powerful -> keep full stretch; fm>1 =
            -- heavy/weak -> less). This is the STOPGAP until the traction/wheelspin model (which self-
            -- scales by grip-breaking power) lands; DepthPowerScale=0 disables it (back to flat depth).
            local depth = AS.Depth or 0.0
            local dps = AS.DepthPowerScale or 0.0
            if dps > 0.0 then
                local fm = HK.flyMass or 1.0
                -- fm 1.0 -> 1.0 (full); heavier (fm>1) scales down toward DepthMinScale.
                local s = 1.0 - dps * math.max(0.0, fm - 1.0)
                local floor = AS.DepthMinScale or 0.35
                if s < floor then s = floor elseif s > 1.0 then s = 1.0 end
                depth = depth * s
            end
            local trim = (w > 0.0 and onPower) and (1.0 - depth * w) or 1.0
            -- Publish the band state so the flywheel-softening block (after EngineBraking below) can
            -- reuse the exact same fade window + on-power gate. It writes fDriveInertia; must run AFTER
            -- EngineBraking so it owns the field on-power (EngineBraking only writes on a lift).
            HK.accelStretchW       = (onPower and w) or 0.0
            HK.accelStretchOnPower = onPower
            HK.dbgDecay = HK.dbgDecay or {}
            HK.dbgDecay.accelStretch = trim
            if trim < 1.0 then
                HK.torqueMult = HK.torqueMult * trim
                if AS.Debug then
                    print(('[hk-accelstretch] kmh=%.0f thr=%.2f w=%.2f trim=%.3f torqueMult=%.3f'):format(
                        kmh, thr, w, trim, HK.torqueMult))
                end
            end
        end
    end

    -- ENGINE TORQUE-CURVE FEEL (Layer B power band + Layer A rpm character). Runs in the shared
    -- torque-trim zone so Layer B composes with the trims above (LowGearTorque/speedCal/AccelMatch)
    -- and the mode branches below (which hard-set torqueMult=0 in neutral/shift = correctly zeroes
    -- the band). Layer A paints rpm here; an active mode rpm event (bark/snap/flutter) overrides it
    -- for that frame (correct — that event IS the character), and it shows through on steady cruise.
    HK.TorqueCurve_Tick(veh, state, dt)

    -- TURBO (spool feel on all modes + flat power on 4/5) — gated on the native turbo mod (jim-mechanic
    -- upgrade). Runs AFTER the torque curve so its power layer composes on top of Layer B. No mod = noop.
    HK.Turbo_Tick(veh, state, dt)

    -- ============================================================= FLYWHEEL ENGINE BRAKING (Phase B)
    -- Live fDriveInertia nudge on a throttle-lift (and through the lift->brake handoff) so GTA's OWN
    -- engine braking scales with the auto-detected flywheel weight: a LIGHT flywheel (flyMass<1) slows
    -- the car MORE on a lift (race-car engine braking), a HEAVY one (>1) coasts further. Perf-adjacent:
    -- it affects DECEL only (never top speed / never adds power), and only while OFF-throttle. Restores
    -- to the Enable-applied base (HK.flyInertiaApplied) the moment you get back on the gas, so it never
    -- fights the snappy-rev scaling. Single-writer relative to that base. EV/hybrid regen will hook this
    -- same lift/brake seam later. Gated OFF by default (EngineBraking.Enabled) — test Phase A first.
    do
        local FWB = Config.Gearbox.Flywheel and Config.Gearbox.Flywheel.EngineBraking
        -- COUPLED test — must match the driveline reality: no engine braking while the clutch is in,
        -- mid-shift, or in neutral (drive is cut, so there's nothing to brake through). dctNeutral is
        -- the paddle-box free-rev state; targetGear==0 covers manual/auto neutral.
        local coupled = not (shifting or clutchHeld or dctNeutral or targetGear == 0)
        if FWB and FWB.Enabled and applied and not isEV and HK.flyInertiaApplied
           and origins and origins.fDriveInertia and coupled then
            local thr   = state.effThrottle or state.throttle or 0.0
            local brake = state.brake or 0.0
            local kmh   = state.speedKmh or ((GetEntitySpeed(veh) or 0) * 3.6)
            local lift  = thr < (FWB.LiftThrottle or 0.10)
            -- Only when moving under some speed AND coasting/braking (not launching).
            local engaged = lift and kmh > (FWB.MinKmh or 8.0)
            -- target nudge fraction: 0 when on-power, ramps to full over the lift. A LIGHT flywheel
            -- (flyMass<1) gets a POSITIVE inertia bump (GTA engine-braking is stronger at higher
            -- fDriveInertia); a heavy one gets a slight reduction (coasts further). Scaled by MaxNudge.
            local fm      = HK.flyMass or 1.0
            local weight  = (1.0 - fm)                    -- light (fm<1) -> +, heavy (fm>1) -> -
            -- brake blends in extra engine-braking commitment on the lift->brake handoff.
            local demand  = engaged and (1.0 + (FWB.BrakeBlend or 0.5) * math.min(1.0, brake)) or 0.0
            local target  = weight * (FWB.MaxNudge or 0.35) * demand
            -- ease the nudge in/out (RampMs) so decel never STEPS on lift or re-throttle.
            local tau  = math.max((FWB.RampMs or 250) / 1000.0, 1e-3)
            HK.flyBrakeNudge = (HK.flyBrakeNudge or 0.0)
                             + (target - (HK.flyBrakeNudge or 0.0)) * (1.0 - math.exp(-(dt or 0.016) / tau))
            -- Apply relative to the Enable base. Clamp the resulting inertia to a sane floor so we can't
            -- drive it to zero (which would make the engine feel dead/stalled).
            local base = HK.flyInertiaApplied
            local ni   = base * (1.0 + HK.flyBrakeNudge)
            if ni < base * 0.4 then ni = base * 0.4 end
            vl_setHandling(veh, 'fDriveInertia', ni)
            -- PHASE readout for /handlingdbg: what the flywheel is actually doing this frame.
            --   on-power = throttle applied (engine driving, no braking)
            --   braking  = lifted AND on the brake (lift->brake handoff, extra commitment)
            --   coasting = lifted, no brake, engine-braking through the flywheel
            --   idle     = below MinKmh (crawling/stopped, nudge suppressed)
            local phase
            if not lift then                         phase = 'on-power'
            elseif kmh <= (FWB.MinKmh or 8.0) then    phase = 'idle'
            elseif brake > 0.05 then                  phase = 'braking'
            else                                      phase = 'coasting' end
            HK.dbgFlyBrake = HK.hdbgOn and { nudge = HK.flyBrakeNudge, eng = engaged, ni = ni, base = base, phase = phase } or nil
        elseif HK.flyBrakeNudge and HK.flyBrakeNudge ~= 0.0 and HK.flyInertiaApplied
               and origins and origins.fDriveInertia then
            -- Not eligible this frame (on-power / neutral / clutch / disabled just now): bleed the nudge
            -- back out and restore the base, so we always hand fDriveInertia back cleanly.
            local tau = math.max(((FWB and FWB.RampMs) or 250) / 1000.0, 1e-3)
            HK.flyBrakeNudge = HK.flyBrakeNudge * math.exp(-(dt or 0.016) / tau)
            if math.abs(HK.flyBrakeNudge) < 0.003 then HK.flyBrakeNudge = 0.0 end
            vl_setHandling(veh, 'fDriveInertia', HK.flyInertiaApplied * (1.0 + HK.flyBrakeNudge))
            -- decoupled reason so the dbg line shows WHY it's off (clutch / shift / neutral / slow).
            HK.dbgFlyBrake = HK.hdbgOn and {
                nudge = HK.flyBrakeNudge, eng = false, ni = HK.flyInertiaApplied * (1.0 + HK.flyBrakeNudge),
                base = HK.flyInertiaApplied,
                phase = clutchHeld and 'clutch' or (shifting and 'shift'
                        or (dctNeutral or targetGear == 0) and 'neutral' or 'idle'),
            } or nil
        end
    end

    -- ============================================================= ACCEL-STRETCH FLYWHEEL SOFTEN
    -- The FEEL half of the 0->100 stretch (torque cut above owns the NUMBER). In the SAME road-speed
    -- band + on-power gate as AccelStretch, we drop fDriveInertia below the Enable base so the engine
    -- takes a beat longer to spin its rotating mass up under load — "building up to speed" instead of
    -- GTA's instant snap. HIGHER fDriveInertia = faster spin-up, so a <1.0 mult = laziest climb.
    -- Runs AFTER EngineBraking and gates on-power (AccelStretch's onPower), so the two never write the
    -- same frame: EngineBraking owns the LIFT, this owns POWER, both relative to HK.flyInertiaApplied.
    -- Latched: when it stops applying it hands the base back once (HK.accelFlyApplied) so it never leaks.
    do
        local AS  = Config.Gearbox.AccelStretch
        local fr  = AS and AS.FlyReduce or 0.0
        -- OWN fade (NOT the torque band's plateau-then-cliff). The torque cut holds full to 100 then
        -- drops over 100->118 — a step that lands right on the 2->3 shift and makes low gears feel long
        -- while 3+ snap back ("cut off, not stepped"). The flywheel instead RISES fast off the line then
        -- DECAYS smoothly to zero well before 3rd, so each gear gets slightly less laziness than the last
        -- (a natural progression) with no discontinuity at any shift point. Strongest at launch by design.
        local kmh    = state.speedKmh or 0.0
        local flyLo  = AS and AS.FlyFadeInLoKmh  or 2.0
        local flyHi  = AS and AS.FlyFadeInHiKmh  or 6.0
        local flyOut = AS and AS.FlyDecayToKmh   or 85.0
        local fw = 0.0
        if kmh > flyLo and kmh < flyOut then
            if kmh < flyHi then
                local t = (kmh - flyLo) / math.max(flyHi - flyLo, 1e-4)
                fw = t * t * (3.0 - 2.0 * t)              -- smoothstep rise off the line
            else
                local t = (kmh - flyHi) / math.max(flyOut - flyHi, 1e-4)
                fw = 1.0 - (t * t * (3.0 - 2.0 * t))      -- smoothstep decay to 0 (no cliff)
            end
        end
        local eligible = AS and AS.Enabled and fr > 0.0 and fw > 0.0
                         and HK.accelStretchOnPower and not isEV
                         and applied and HK.flyInertiaApplied
                         and origins and origins.fDriveInertia
                         and not (shifting or clutchHeld or dctNeutral or targetGear == 0)
        if eligible then
            local base = HK.flyInertiaApplied
            local mult = 1.0 - fr * fw                    -- fw faded 0..1 on its own gentle curve
            vl_setHandling(veh, 'fDriveInertia', base * mult)
            HK.accelFlyApplied = true
            if AS.Debug then
                print(('[hk-accelfly] kmh=%.0f fw=%.2f mult=%.3f di=%.3f (base %.3f)'):format(
                    kmh, fw, mult, base * mult, base))
            end
        elseif HK.accelFlyApplied then
            -- Left the band / on a lift now (EngineBraking takes over) / decoupled: restore the base
            -- once so we always hand fDriveInertia back cleanly and never fight the other writers.
            if HK.flyInertiaApplied and veh and veh ~= 0 then
                vl_setHandling(veh, 'fDriveInertia', HK.flyInertiaApplied)
            end
            HK.accelFlyApplied = false
        end
    end

    -- Block the game's auto up/down (363/364) only when WE own gear selection:
    -- mode 1 (manual) always; mode 3 (DCT) only in its manual sub-mode. Comfort
    -- auto (2) and DCT-auto never block — they want GTA to shift.
    local auto = (gearMode == 2)
    if gearMode == 1 or (gearMode == 3 and dctManual) then
        DisableControlAction(0, 363, true)
        DisableControlAction(0, 364, true)
    end

    -- DRIFT GEAR CEILING (symptom #5, reworked): while drift.lua is holding the gear
    -- (HK.driftHoldGear), the box must not auto-UPSHIFT — a low held gear keeps physics
    -- rpm + torque HIGH (fries the tyres, slides the car) and self-limits top speed at
    -- the gear's redline. DOWNSHIFT stays allowed (slowing / braking into a corner).
    -- The DCT paths (modes 3/4/5) hold themselves — their auto-upshift is gated by
    -- `not HK.driftHoldGear` below, so dctGear never climbs; downshift still runs. This
    -- block handles GTA-OWNED comfort auto (mode 2): capture the gear when the hold
    -- engages, then clamp native gear to that CEILING (force it back down if GTA crept
    -- it up), and let the ceiling RATCHET DOWN when the driver/GTA downshifts. EV /
    -- single-gear cars (gearcount <= 1) have nothing to hold — one fixed gear (correct).
    -- WHEELIE GEAR HOLD (2026-08-14 reramp) shares this comfort-auto ceiling: while the nose is up
    -- the box must hold its gear so the redline rpm-pin can't trip a native upshift. Same ratchet.
    local holdGear = HK.driftHoldGear or HK.wheelieHoldGear
    if holdGear and gearcount and gearcount > 1 and gearMode == 2 then
        local ng = vl_getCurrentGear(veh)
        if not HK.driftGearCeil then HK.driftGearCeil = ng end        -- capture ceiling on engage
        if ng and ng < HK.driftGearCeil then HK.driftGearCeil = ng end -- ratchet DOWN on a downshift
        DisableControlAction(0, 363, true)                            -- block native upshift only
        if ng and ng > HK.driftGearCeil then vl_setCurrentGear(veh, HK.driftGearCeil) end
    elseif HK.driftGearCeil then
        HK.driftGearCeil = nil                                        -- release ceiling when not holding
    end

    -----------------------------------------------------------------
    -- EV — SINGLE-GEAR ELECTRIC (its own mode). A real EV has one fixed reduction:
    -- nothing to shift, instant torque, no shift dips / early-upshift / rpm-flare (all
    -- of which the ICE comfort box applies to a gearbox that isn't there). So we DON'T
    -- run the comfort shaping — we leave GTA's single gear alone and only add:
    --   * the hold-both-keys COAST NEUTRAL (drive cut + free-rev while held),
    --   * an optional gentle off-the-line smoothing (config, default OFF — EVs are
    --     meant to feel instant).
    -- The speedCal / AccelMatch / low-gear-punch torque trims above already ran (they
    -- are pure torque and gear-agnostic), so an EV still honours a /setspeed target.
    -----------------------------------------------------------------
    -----------------------------------------------------------------
    -- HYBRID (PHEV with a full-electric mode) — AUTO e-mode <-> ICE transition.
    -- e-mode: capped power + capped top speed + gentle auto-coast on lift (no one-pedal
    -- toggle — real PHEVs don't offer it). ICE-mode: the ENGINE has woken, so we DON'T
    -- run any EV logic — we fall through to the car's normal gearbox branch (its real
    -- DCT/manual/comfort box) at full power. The transition is automatic, like a real
    -- hybrid: it never refuses, it wakes the ICE. Hysteresis stops boundary flip-flop.
    -----------------------------------------------------------------
    -----------------------------------------------------------------
    -- SEMI / KERS HYBRID (class 2): ICE ALWAYS RUNS — no standalone EV drive mode.
    -- The e-motor gives (a) regen-on-lift (recover energy, semi one-pedal) and (b) an
    -- ALWAYS-ON torque FILL blended into engine power while on the gas. Then FALL THROUGH
    -- to the car's real gearbox (comfort/DCT/manual — whatever its manualType is) at full
    -- power. 918 / P1 / LaFerrari / mild-hybrid Benz. Set via /sethybrid semi [boostMult].
    -- Runs BEFORE the full-PHEV block; the two are mutually exclusive (class 1 vs 2).
    if HK.semiHybrid then
        local HY  = Config.Gearbox.Hybrid or {}
        local SH  = HY.SemiHybrid or {}
        local kmh = state.speedKmh or 0.0
        local thr = state.throttle or 0.0
        -- Live regen signal (speedo reads it; 'hybrid' = single effect, not a D-level).
        HK.evRegen.level, HK.evRegen.holding, HK.evRegen.active = 0.0, false, false
        HK.evRegen.mode = 'hybrid'
        HK.semiBoost = 0.0            -- live e-BOOST fraction 0..1 (speedo charge arc, amber side)
        if thr <= (SH.RegenLift or 0.10) then
            -- REGEN on lift (reuses the shared actuator + Hybrid cornering-regen ease).
            applyRegen(veh, state, SH.RegenDecelG or 0.22, SH.RegenHoldKmh or 8.0,
                       SH.RegenHold or 0.50, 1.0, 1.0, dt)
        elseif thr > (SH.BoostThrottle or 0.05) then
            -- ALWAYS-ON TORQUE FILL (KERS): strongest low-down (electric instant torque),
            -- easing to 1.0 by BoostFadeFrac of top speed. Multiplies into HK.torqueMult so
            -- it compounds with the normal gearbox branch below (same as gbRatio.LowGearTorque).
            local mult = HK.semiBoostMult or SH.BoostMult or 1.18
            if mult > 1.0 then
                local topKmh = (gbTopKmh and gbTopKmh > 0) and gbTopKmh or 300.0
                local fade   = (SH.BoostFadeFrac or 0.60) * topKmh
                local ease   = (fade > 0) and (1.0 - (kmh / fade)) or 0.0   -- 1 at rest -> 0 at fade
                if ease < 0.0 then ease = 0.0 elseif ease > 1.0 then ease = 1.0 end
                -- throttle-scale so feathering doesn't dump full e-fill; full assist at WOT.
                local applied = 1.0 + (mult - 1.0) * ease * thr
                HK.torqueMult = HK.torqueMult * applied
                -- normalise to 0..1 of MAX possible boost (ease·thr, since applied grows
                -- linearly in both) so the speedo arc reads "how much e-assist right now".
                HK.semiBoost = ease * thr
            end
        end
        -- FALL THROUGH: the car's normal gearbox branch (isEV is false for a semi; the
        -- ICE box below drives). No return — regen/boost are additive to the real box.
    end

    if isHybrid then
        local HY  = Config.Gearbox.Hybrid or {}
        local kmh = state.speedKmh or 0.0
        local thr = state.throttle or 0.0
        local capK = hybridCap or HY.CapKmh or 130.0

        -- SEMI-LOOK charge arc feed (HK.speedoStyle=='semi', e.g. 918/P1): the speedo's thin arc
        -- reads HK.semiBoost (AMBER = electric DISCHARGE / power out) + regen (green, on lift, via
        -- applyRegen below). Purely a DISPLAY signal — adds no torque (the PHEV's own power law is
        -- unchanged). Meaning depends on drive mode:
        if HK.speedoStyle == 'semi' then
            if hybridEMode then
                -- E-MODE: ALL drive power is electric, so amber = e-motor OUTPUT. Show delivered
                -- power = throttle scaled by remaining headroom to the e-cap (strong low-down,
                -- tapering to 0 as you near the electric top speed — real e-motor feel). This is
                -- DISTINCT from the green throttle bar: the bar tracks raw pedal, the amber arc
                -- fades with speed, so the two aren't a duplicate readout.
                if thr > 0.05 then
                    local ease = 1.0 - (kmh / math.max(capK, 1.0))
                    if ease < 0.0 then ease = 0.0 elseif ease > 1.0 then ease = 1.0 end
                    HK.semiBoost = ease * thr
                else
                    HK.semiBoost = 0.0
                end
            else
                -- ICE MODE: e-assist fill (throttle-proportional display), as before.
                HK.semiBoost = (thr > 0.05) and math.min(1.0, thr) or 0.0
            end
        end

        -- DRIVER MODE (two modes):
        --   'ev'     = PREFER electric — resume eagerly, flooring alone stays electric; but
        --              the CAP still hands off to ICE (the SF90 feel: electric to the cap,
        --              then the engine wakes for full power).
        --   'normal' = the car decides (auto): cap OR kickdown wakes ICE; gentle hysteresis
        --              back to e-mode. This is the old 'auto' behaviour.
        -- AUTO-ICE transition (only when enabled). DISABLED for now -> the hybrid stays in
        -- whatever mode the driver set via HOLD-G; EV mode is hard-capped by torque (below) and
        -- never auto-wakes the ICE. This isolates the EV drivetrain for diagnosis.
        if HY.AutoICE == true then
            if hybridEMode then
                local nearCap    = kmh >= (capK - 4.0)
                local throttleUp = thr >= (HY.HandoffThr or 0.75)
                local kick       = (hybridUserMode ~= 'ev') and thr >= (HY.KickdownThr or 0.85)
                if kmh >= capK or (nearCap and throttleUp) or kick then
                    hybridEMode = false
                    if Config.Gearbox.Debug then print('[hk-hybrid] ICE engaged (auto handoff)') end
                end
            else
                local resumeKmh = math.min(HY.ResumeKmh or 110.0, capK - 20.0)
                local resumeThr = HY.ResumeThr or 0.50
                if kmh < resumeKmh and thr < resumeThr then
                    hybridEMode = true
                    if Config.Gearbox.Debug then print('[hk-hybrid] back to e-mode (auto)') end
                end
            end
        end

        -- HANDOFF EDGE: e-mode -> ICE this frame. Re-arm the DCT cleanly so it resumes in
        -- AUTO (not stuck in a stale manual sub-mode). While e-mode returns early each frame,
        -- the DCT branch's one-time init is skipped and dctManual/dctStarted go stale — so on
        -- the handoff we force a fresh init and clear manual. The DCT branch below re-inits
        -- On EITHER transition, ALWAYS reset the DCT to a clean AUTO state — a hybrid should
        -- never land in manual/a stuck gear when switching modes (user spec). Any shift-key
        -- taps from e-mode are dropped so they can't carry a manual sub-mode into ICE.
        if hybridEModePrev ~= hybridEMode then
            applyHybridAudio(veh)                       -- swap engine note <-> electric hum
            dctManual = false                           -- start auto on a mode switch (no stale manual)
            dctStarted = false                          -- clean DCT re-init (speed-matched pickup)
            dctNeutral, dctReverse, dctNeutralHold = false, false, false
            dctLatchedNeutral = false
            dctPendingGear = nil
            -- EV→ICE VOLUME RE-PRIME (2026-08-14, v2). Coming BACK to ICE, GTA's restored engine
            -- note is DIMMED until the next gear change. So on the e-mode->ICE edge ONLY, arm a
            -- ONE real single shift (up OR down, chosen by rpm below so it never bogs/over-revs) —
            -- a genuine gear event re-levels the audio and the box honours it (unlike a phantom
            -- bump). Only arm on the edge INTO ICE (not ICE->e-mode). Consumed in the DCT branch.
            if hybridEModePrev == true and hybridEMode == false then
                HK.evReprimeArm = true
            end
            -- NOTE: do NOT clear reqUp/reqDown here — that ate the very FIRST paddle tap after a
            -- switch, and if this ever ran per-frame it killed paddles entirely. A stray e-mode
            -- tap engaging manual one frame early in ICE is harmless (it's a real gear then).
        end
        hybridEModePrev = hybridEMode

        if hybridEMode then
            -- GEARBOX: let GTA's own auto-box SHIFT through the gears. Single-gear was PROVEN
            -- impossible for a real cap: pinning gear 1 hard-caps at gear-1's ceiling (~81 on
            -- the SF90 — reduced-gear-ratio shortens gears by design), and raising maxFlatVel
            -- does NOT lift a reduced-ratio gear's ceiling (debug: 605 raw still capped 81).
            -- So GTA shifts (reaches the real cap); we keep power high so it upshifts cleanly
            -- (no lug) and enforce the cap purely with the torque hard-cut below. The 'EV feel'
            -- (no visible gears) is handled on the hk-speedo side, not by pinning here.
            -- CRITICAL: force reduced-gear-ratio OFF in e-mode. A DCT/hybrid car (SF90 = type 4)
            -- runs its DCT branch in ICE mode, which turns reduced-ratio ON (shortens gears).
            -- Coming BACK to EV that flag lingered -> gear 1 short-capped at 81 again (the exact
            -- 'caps at 81 after a hybrid round-trip' bug). EV wants GTA's FULL ratios so it can
            -- shift to the real cap. Also mark the DCT to re-init (dctStarted=false) for a clean
            -- speed-matched pickup if we hand back to ICE later.
            if eReducedRatioOff ~= true then
                vl_setTransmissionReducedGearRatio(veh, false)
                dctStarted = false
                eReducedRatioOff = true
            end
            -- belt-and-braces: undo any stale maxFlatVel raise from an old build.
            if eGearPinned then
                eGearPinned = false
                if origins and origins.fInitialDriveMaxFlatVel then
                    vl_setHandling(veh, 'fInitialDriveMaxFlatVel', origins.fInitialDriveMaxFlatVel)
                end
            end
            if Config.Gearbox.Debug and now > (_emodeDbgAt or 0) then
                _emodeDbgAt = now + 1000
                print(('[hk-emode] gear=%d kmh=%.0f cap=%.0f (GTA shifting, torque-capped)')
                    :format(vl_getCurrentGear(veh), kmh, capK))
            end

            local RGh = Config.Gearbox.ReverseGate or {}
            -- NEUTRAL TAP-TOGGLE (hybrid e-mode = automatic class): TAP both keys to toggle N.
            -- KEY-DRIVEN also lets the DOWNSHIFT key walk none->N->R and UPSHIFT walk R->N->none
            -- (S is a pure brake). Hybrids KEEP neutral + launch control (only pure EVs drop them).
            if reqNeutralTap then
                reqNeutralTap = false
                reqUp, reqDown = false, false
                revGate = (revGate == 'neutral') and 'none' or 'neutral'
                if revGate == 'neutral' then
                    revBrakeArmed, revThrArmed, revWalkAt = false, false, 0
                else
                    revWasMoving = false     -- tapped OUT: don't let a held brake re-enter N this frame
                end
            end
            -- S-RETAP TO NEUTRAL (hybrid e-mode): S is a PURE BRAKE — braking to a stop STAYS in D.
            -- A FRESH S press (release, then press S again) while FULLY STOPPED selects NEUTRAL —
            -- mirrors comfort/DCT-auto. From N the DOWNSHIFT key (J) walks to REVERSE, or the
            -- handbrake+throttle stages launch control. DOUBLE-TAP W pulls away out of N (like the
            -- UPSHIFT key). Both edge off the physical pedals so a held decel-to-stop brake / a
            -- normal driving W-blip never trips them — only fresh taps while stopped in N.
            if RGh.KeyDriven then
                -- DOUBLE-TAP S -> NEUTRAL (2026-08-16): a single S press dropped to N too easily on any
                -- stop; require TWO quick S taps while stopped instead. Detector runs every frame.
                local dblTapS = HK.autoDoubleTapS(Config.Gearbox.NeutralBrakeDoubleTapMs)
                if dblTapS and revGate == 'none'
                   and (state.speedKmh or 0) <= (RGh.StopKmh or 2.0) then
                    revGate = 'neutral'
                    revBrakeArmed, revThrArmed, revWalkAt = false, false, 0
                end
                local dblTapW = HK.autoDoubleTapW(Config.Gearbox.NeutralDoubleTapMs)
                -- BRAKE-HELD REV LOCK: while S (footbrake) is held in neutral you're free-revving —
                -- tap W tap W tap W to blip the engine, NOT engage a gear. Only let the double-tap
                -- pull away into gear when the brake is RELEASED. (Detector still runs to consume taps.)
                if dblTapW and revGate == 'neutral' and lcPhase == 'off'
                   and (HK._pedalBrake or 0.0) <= 0.5 then
                    revGate = 'none'
                    revBrakeArmed, revThrArmed, revWalkAt = false, false, 0
                    revWasMoving = false
                    HK._neutralExitThrCut = true    -- swallow the held double-tap W so leaving N doesn't lurch
                end
            end
            if RGh.KeyDriven and (reqUp or reqDown) then
                local kmh = state.speedKmh or 0.0
                if reqDown then
                    if     revGate == 'none'    then revGate = 'neutral'
                    elseif revGate == 'neutral' and kmh <= (RGh.NToRMaxKmh or 8.0) then revGate = 'reverse' end
                elseif reqUp then
                    if     revGate == 'reverse' then revGate = 'neutral'
                    elseif revGate == 'neutral' then revGate = 'none' end
                end
                reqUp, reqDown = false, false
            end

            -- REVERSE GATE (hybrid e-mode). KEY-DRIVEN: the ladder above owns revGate; reverse
            -- drives by velocity (W = back, S = brake). NEUTRAL keeps launch staging. LEGACY:
            -- the S-brake R<->N<->D shuffle via updateReverseGate.
            do
                local g
                if RGh.KeyDriven then
                    g = revGate
                    if g == 'reverse' then
                        HK.autoReverseDrive(veh, state, dt,
                            gbDriveForceLive or (origins and origins.fInitialDriveForce))
                        HK.evRegen.level, HK.evRegen.holding, HK.evRegen.active = 0.0, false, false
                        HK.evRegen.mode = 'hybrid'
                        return
                    end
                else
                    g = updateReverseGate(state)
                end
                -- LAUNCH-FIRE GUARD (see the pure-EV path for the full rationale): releasing the
                -- handbrake with throttle floored flips the gate neutral->none on the fire frame,
                -- which would skip the launchStageTick call below and strand lcPhase at 'staged'.
                -- While STAGED, hold the gate on 'neutral' so the tick fires; it clears revGate itself.
                if lcPhase == 'staged' and g == 'none' then g = 'neutral' end
                if g == 'neutral' then
                    -- LAUNCH CONTROL (hybrid e-mode): stage in neutral, launch on handbrake release.
                    local lc = launchStageTick(veh, state, dt)
                    if lc == 'launch' then
                        revGate = 'none'
                        if origins and origins.fInitialDriveForce then
                            setDriveForce(veh, gbDriveForceLive or origins.fInitialDriveForce)
                        end
                        -- fall through to normal e-mode power (below) + boost applied there.
                    else
                        -- STAGED vs plain neutral. Staged keeps gear 1 + drive force LIVE so the
                        -- engine builds REAL loaded revs against the handbrake (same contract as
                        -- the DCT-auto staged path) — cutting drive here would make vl_setRpmRaw
                        -- only paint the gauge = the spin-up-on-release penalty the rewrite killed.
                        -- Plain neutral cuts drive + pins a forward gear + zeros torque as before.
                        if lc == 'staged' then
                            if vl_getCurrentGear(veh) ~= 1 then vl_setCurrentGear(veh, 1) end
                            if origins and origins.fInitialDriveForce then
                                setDriveForce(veh, gbDriveForceLive or origins.fInitialDriveForce)
                            end
                        else
                            if origins and origins.fInitialDriveForce then setDriveForce(veh, 0.0) end
                            if vl_getCurrentGear(veh) < 1 then vl_setCurrentGear(veh, 1) end
                            HK.torqueMult = 0.0
                        end
                        HK.evRegen.level, HK.evRegen.holding, HK.evRegen.active = 0.0, false, false
                        HK.evRegen.mode = 'hybrid'
                        return
                    end
                elseif g == 'reverse' then
                    if origins and origins.fInitialDriveForce then
                        setDriveForce(veh, gbDriveForceLive or origins.fInitialDriveForce)
                    end
                    HK.evRegen.level, HK.evRegen.holding, HK.evRegen.active = 0.0, false, false
                    HK.evRegen.mode = 'hybrid'
                    return   -- GTA brake-to-reverse owns this frame (no e-power cap needed at rev speeds)
                end
                -- 'none' -> fall through to normal e-mode power/regen below.
            end
            -- KEY-DRIVEN forward drive (hybrid e-mode): S is a pure brake — kill native S-reverse at
            -- a standstill so a held S can't drop into native reverse. Reverse is DOWN-key only.
            if RGh.KeyDriven then HK.autoStandstillBrake(veh, state) end

            -- EV POWER + HARD SPEED CAP. Strong flat-ish torque so it pulls cleanly to the cap,
            -- then a HARD CUT to 0 ABOVE the cap so it physically can't exceed it (torque is the
            -- ONLY thing that caps speed). No lugging bleed near the cap anymore.
            do
                local pf   = hybridPowerFrac or HY.PowerFrac or 0.35
                local peak = HY.EmodeLaunchMult or 2.2
                local frac = kmh / math.max(capK, 1.0)
                local boost = 1.0 + (peak - 1.0) * math.max(0.0, 1.0 - frac / 0.55)
                local m = pf * boost
                if m < (HY.EmodeMinMult or 0.9) then m = HY.EmodeMinMult or 0.9 end
                if kmh >= capK then
                    m = 0.0                         -- HARD CAP: no torque above the cap
                elseif kmh > capK - 4.0 then
                    m = m * ((capK - kmh) / 4.0)    -- short smooth ramp into the cap (no jerk)
                end
                HK.torqueMult = HK.torqueMult * m
            end

            launchBoostApply(state)         -- fading launch surge after a launch (no-op otherwise)

            -- Regen signal reset each frame (applyRegen re-sets it when it acts).
            HK.evRegen.level, HK.evRegen.holding, HK.evRegen.active = 0.0, false, false
            HK.evRegen.mode = 'hybrid'  -- single fixed regen (speedo shows the effect, not a D-level)
            -- HYBRID REGEN (single fixed level, semi one-pedal incl. stop-hold). Same in e-mode
            -- and ICE mode. Fires on lift.
            if thr <= (HY.RegenLift or 0.10) then
                applyRegen(veh, state, HY.RegenDecelG or 0.15, HY.RegenHoldKmh or 8.0,
                           HY.RegenHold or 0.55, 1.0, 1.0, dt)
            end
            return   -- e-mode owns this frame; no ICE gearbox logic
        else
            -- ICE mode: clear the e-mode latch so the NEXT return to EV re-forces reduced-ratio
            -- OFF (the ICE DCT branch below turns it ON; EV must undo that on re-entry).
            eReducedRatioOff = false
            -- belt-and-braces: undo any stale single-gear pin/maxFlatVel raise from an old build.
            if eGearPinned then
                eGearPinned = false
                vl_setTransmissionReducedGearRatio(veh, false)
                if origins and origins.fInitialDriveMaxFlatVel then
                    vl_setHandling(veh, 'fInitialDriveMaxFlatVel', origins.fInitialDriveMaxFlatVel)
                end
            end
            -- HYBRID REGEN in ICE mode too (the e-motors still regen on lift — blends with GTA's
            -- own engine braking). Same fixed level + stop-hold as e-mode. This runs BEFORE the
            -- DCT branch below (gear/torque), which it doesn't conflict with (regen = decel bleed
            -- + brake, independent of drive torque). Only on a real lift (throttle down).
            HK.evRegen.level, HK.evRegen.holding, HK.evRegen.active = 0.0, false, false
            HK.evRegen.mode = 'hybrid'
            if (state.throttle or 0.0) <= (HY.RegenLift or 0.10) then
                applyRegen(veh, state, HY.RegenDecelG or 0.15, HY.RegenHoldKmh or 8.0,
                           HY.RegenHold or 0.55, 1.0, 1.0, dt)
            end
        end
        -- ICE-mode: fall through to the normal gearbox branches below (full power, real box).
    end

    if isEV then
        local cfg = Config.Gearbox
        local EV  = cfg.EV or {}

        local R = EV.Regen or {}

        -- REGEN LEVEL CONTROL (D1/D2/D3 ladder + Coast). CLUTCH key (LSHIFT) = drop to
        -- COAST instantly (express reset). ShiftUp (K) = stronger regen, ShiftDown (J) =
        -- milder — stepping 0(Coast)/1/2/3. K/J here are FREE on an EV (no gears); the
        -- both-held coast-neutral gesture needs BOTH keys, so a lone tap can't trigger it.
        -- reqUp/reqDown are the edge-triggered taps (consumed here so no shift fires).
        if R.Enabled ~= false then
            local changed = nil
            if clutchHeld and not evClutchPrev then
                evRegenLevel = 0                            -- LSHIFT -> Coast, always
                changed = evRegenLevel
            end
            evClutchPrev = clutchHeld
            if reqUp then
                reqUp = false
                -- Up-step: from Coast(0) the first press jumps to D1; then D1->D2->D3.
                if evRegenLevel < 3 then evRegenLevel = evRegenLevel + 1 end
                changed = evRegenLevel
            end
            if reqDown then
                reqDown = false
                -- Down-step FLOORS at D1 (level 1) — J never reaches Coast. Only the
                -- CLUTCH key (LSHIFT) drops to Coast.
                if evRegenLevel > 1 then evRegenLevel = evRegenLevel - 1 end
                changed = evRegenLevel
            end
            if changed ~= nil then
                local label = (changed == 0) and 'Coast' or ('D' .. changed)
                vl_notify('Regen: ' .. label, 'inform')
                TriggerEvent('hk-speedo:regenMode', changed)   -- speedo shows level (safe no-op if unhandled)
            end
        end

        local RGev = cfg.ReverseGate or {}
        if RGev.KeyDriven then
            -- KEY-DRIVEN REVERSE (pure EV). Pure EVs have NO neutral and NO launch control: the
            -- J+K CHORD (both shift keys together = reqNeutralTap) TOGGLES D<->R, and single J/K
            -- stay as regen-level control (handled above). Reverse DRIVES by velocity via
            -- HK.ReverseDrive_Tick (W = back, S = brake). D<->R is speed-gated into R (safety).
            if reqNeutralTap then
                reqNeutralTap = false
                reqUp, reqDown = false, false
                if HK.autoRevSel == 'R' then
                    HK.autoRevSel = 'D'
                elseif (state.speedKmh or 0.0) <= (RGev.NToRMaxKmh or 8.0) then
                    HK.autoRevSel = 'R'      -- into reverse only when nearly stopped
                end
            end
            if HK.autoRevSel == 'R' then
                HK.autoReverseDrive(veh, state, dt,
                    gbDriveForceLive or (origins and origins.fInitialDriveForce))
                HK.evRegen.level, HK.evRegen.holding, HK.evRegen.active = 0.0, false, false
                HK.evRegen.mode = (evRegenLevel == 0) and 'coast' or ('D' .. evRegenLevel)
                return                        -- reverse owns the frame (velocity-driven)
            end
            -- 'D': restore drive, normal forward EV drive falls through below.
            if origins and origins.fInitialDriveForce then
                setDriveForce(veh, gbDriveForceLive or origins.fInitialDriveForce)
            end
            -- UN-PIN REVERSE: toggling D<-R leaves GTA in native gear 0 (from the velocity-reverse
            -- frame). GetDisplayGear falls back to the native gear in 'D' and native 0 reads as R,
            -- so the speedo STAYS on R after leaving reverse. Bump to native 1 once not rolling back.
            if vl_getCurrentGear(veh) < 1 and (state.forwardSpeed or 0.0) > -0.5 then
                vl_setCurrentGear(veh, 1)
            end
            HK.autoStandstillBrake(veh, state)   -- S is a pure brake — kill native S-reverse at a stop
            launchBoostApply(state)           -- no-op for pure EV (LC dropped) but harmless
        else
        -- NEUTRAL TAP-TOGGLE (automatic class, LEGACY): TAP both keys to enter neutral, tap again to
        -- drive off. Unified with the reverse gate — neutral IS revGate=='neutral', so tap-N and
        -- brake-to-N are the same state and throttle/brake walk out of both. (No more hold-both
        -- coast; automatics use a tap toggle, per spec.)
        if EV.NeutralGesture ~= false and reqNeutralTap then
            reqNeutralTap = false
            reqUp, reqDown = false, false
            revGate = (revGate == 'neutral') and 'none' or 'neutral'
            if revGate == 'neutral' then
                revBrakeArmed, revThrArmed, revWalkAt = false, false, 0
            else
                -- Tapped OUT of neutral: clear revWasMoving so updateReverseGate's brake-to-N
                -- ('none' branch) can't immediately re-enter neutral this same frame if the brake
                -- is still held (that latch is only consumed on a brake-entry, not a tap-exit).
                revWasMoving = false
            end
        end

        -- REVERSE GATE (LEGACY): brake to a stop -> NEUTRAL (free-roll); release-then-press brake
        -- -> REVERSE; throttle -> forward. In NEUTRAL we CUT drive force so GTA physically
        -- can't roll the car into reverse (free-roll), and block forward throttle isn't
        -- needed (throttle exits the gate). In REVERSE we RESTORE drive so GTA's native
        -- brake-to-reverse engages normally. Runs after coast-neutral so a held-both
        -- coast still wins.
        do
            local g = updateReverseGate(state)
            -- LAUNCH-FIRE GUARD: releasing the handbrake with throttle floored IS the launch-fire
            -- gesture, but that same frame flips the gate neutral->none (throttle held, not staging)
            -- so the launchStageTick call below (it lives INSIDE the g=='neutral' branch) is skipped,
            -- the launch never fires, and lcPhase strands at 'staged' (pill stuck red). While a launch
            -- is STAGED, keep the gate on 'neutral' so the tick runs and fires; it clears revGate
            -- itself on fire (and on bail lcPhase goes 'off', so this stops forcing next frame).
            if lcPhase == 'staged' and g == 'none' then g = 'neutral' end
            if g == 'neutral' then
                -- LAUNCH CONTROL: staged in neutral (handbrake + full throttle). If it fires a
                -- LAUNCH, drop out of neutral to drive off; otherwise it holds the staged rpm.
                local lc = launchStageTick(veh, state, dt)
                if lc == 'launch' then
                    revGate = 'none'
                    if origins and origins.fInitialDriveForce then
                        setDriveForce(veh, gbDriveForceLive or origins.fInitialDriveForce)
                    end
                    -- reset regen signal (this early return skips the per-frame reset below, so a
                    -- stale stop-hold from the previous frame would leak one frame to the speedo).
                    HK.evRegen.level, HK.evRegen.holding, HK.evRegen.active = 0.0, false, false
                    HK.evRegen.mode = (evRegenLevel == 0) and 'coast' or ('D' .. evRegenLevel)
                    launchBoostApply(state)          -- first boost frame
                    return
                end
                -- STAGED vs plain neutral. STAGED keeps gear 1 + drive force LIVE so the engine
                -- builds REAL loaded revs against the handbrake (matches the DCT-auto staged path);
                -- cutting drive here would make vl_setRpmRaw only paint the gauge = the spin-up-on-
                -- release penalty the launch rewrite eliminated. PLAIN NEUTRAL cuts drive + pins a
                -- forward gear so GTA can't drop into reverse on the held brake (the 'shows N but
                -- rolls backward' bug) + zeros torque.
                if lc == 'staged' then
                    if vl_getCurrentGear(veh) ~= 1 then vl_setCurrentGear(veh, 1) end
                    if origins and origins.fInitialDriveForce then
                        setDriveForce(veh, gbDriveForceLive or origins.fInitialDriveForce)
                    end
                else
                    if origins and origins.fInitialDriveForce then setDriveForce(veh, 0.0) end
                    if vl_getCurrentGear(veh) < 1 then vl_setCurrentGear(veh, 1) end
                    HK.torqueMult = 0.0
                end
                HK.evRegen.level, HK.evRegen.holding, HK.evRegen.active = 0.0, false, false
                HK.evRegen.mode = (evRegenLevel == 0) and 'coast' or ('D' .. evRegenLevel)
                return
            elseif g == 'reverse' then
                -- GTA brake-to-reverse: restore drive, GTA selects reverse.
                if origins and origins.fInitialDriveForce then
                    setDriveForce(veh, gbDriveForceLive or origins.fInitialDriveForce)
                end
            else
                -- 'none' = normal forward driving. Restore drive; GTA's box drives (a pure EV's
                -- meta is already 1-gear, so no lugging — no pin needed).
                if origins and origins.fInitialDriveForce then
                    setDriveForce(veh, gbDriveForceLive or origins.fInitialDriveForce)
                end
                launchBoostApply(state)              -- fading launch surge (no-op unless launched)
            end
        end
        end     -- close: if RGev.KeyDriven then ... else (legacy reverse gate)

        -- INSTANT LINEAR TORQUE — the EV "kick". A real EV makes peak torque from 0 rpm:
        -- a strong constant-force pull off the line that tapers as it nears top speed
        -- (constant-power region). GTA's stock delivery ramps up like an ICE, so an EV felt
        -- flat off the line. We add a throttle-gated torque BOOST that's strongest at low
        -- speed and eases to 1.0 (no boost) by the top-speed fraction, so it's punchy from a
        -- stop without changing terminal velocity (torque-only; never touches top-speed
        -- fields — honours the invariant). Boost scales with throttle so light pedal is calm.
        do
            local LT = EV.LinearTorque
            if (not LT or LT.Enabled ~= false) then
                local thr = state.throttle or 0.0
                if thr > 0.05 then
                    local peak    = (LT and LT.PeakMult)   or 1.6    -- low-speed torque mult at full throttle
                    local fadeEnd = (LT and LT.FadeFrac)   or 0.55   -- boost gone by this fraction of top speed
                    local topKmh  = (gbTopKmh and gbTopKmh > 0) and gbTopKmh or 200.0
                    local frac    = (state.speedKmh or 0.0) / topKmh
                    local ease    = 1.0 - (frac / fadeEnd)           -- 1 at rest -> 0 at fadeEnd
                    if ease < 0.0 then ease = 0.0 elseif ease > 1.0 then ease = 1.0 end
                    -- throttle-scaled so feathering doesn't launch; full boost only at WOT.
                    local boost = 1.0 + (peak - 1.0) * ease * thr
                    HK.torqueMult = HK.torqueMult * boost
                end
            end
        end

        -- Regen signal reset each frame + publish current level for hk-speedo
        -- (applyRegen re-sets level/holding/active below when it actually acts).
        HK.evRegen.level, HK.evRegen.holding, HK.evRegen.active = 0.0, false, false
        HK.evRegen.mode = (evRegenLevel == 0) and 'coast' or ('D' .. evRegenLevel)

        -- REGEN BRAKING (D1/D2/D3) — level 0 (Coast) does nothing (glides). Levels 1-3 apply
        -- regen when the throttle is LIFTED; DecelG comes from the level table. liftFrac scales
        -- by how far off-throttle you are. Only levels >= HoldAtStopLevel get the brake-hold at
        -- a stop (D3 by default = true one-pedal); milder levels fade to a roll (holdPressure 0).
        if R.Enabled ~= false and evRegenLevel > 0 then
            local levels = R.Levels or { [1]=0.10, [2]=0.15, [3]=0.21 }
            local decelG = levels[evRegenLevel] or 0.15
            local thr = state.throttle or 0.0
            if decelG > 0 and thr <= (R.LiftThrottle or 0.10) then
                local full = R.FullLiftAt or 0.02
                local band = (R.LiftThrottle or 0.10) - full
                local liftFrac = (band > 0) and (1.0 - math.max(0.0, (thr - full)) / band) or 1.0
                if liftFrac < 0.0 then liftFrac = 0.0 elseif liftFrac > 1.0 then liftFrac = 1.0 end
                local hold = (evRegenLevel >= (R.HoldAtStopLevel or 3)) and (R.HoldPressure or 0.6) or 0.0
                applyRegen(veh, state, decelG, R.HoldBelowKmh or 8.0,
                           hold, R.MaxForceScale or 1.0, liftFrac, dt)
            end
        end

        -- Optional gentle launch (default OFF — EV character is instant torque).
        if EV.LaunchSmooth then
            local lkmh = EV.LaunchKmh or 12.0
            if (state.speedKmh or 0) < lkmh and (state.throttle or 0) > 0.1 then
                local f  = 1.0 - ((state.speedKmh or 0) / lkmh)
                local lp = EV.LaunchPower or 0.88
                HK.torqueMult = HK.torqueMult * (lp + (1.0 - lp) * (1.0 - f))
            end
        end

        return  -- EV: no ICE shift logic
    end

    -----------------------------------------------------------------
    -- MODE 2 — COMFORT AUTOMATIC (early/lazy shifts + smooth + anti-hunt).
    -- Does NOT pin gears; lets GTA's auto box drive, just nudges it toward a
    -- relaxed, handling-focused feel. No clutch, no manual up/down keys.
    -- (Deliberately the 'lesser' box for now — DCT comes later as its own modes.)
    -----------------------------------------------------------------
    if auto then
        local cfg = Config.Gearbox
        local cur = vl_getCurrentGear(veh)

        local RG = cfg.ReverseGate or {}
        if RG.KeyDriven then
            -- KEY-DRIVEN REVERSE (comfort auto). S is a PURE BRAKE — braking to a stop STAYS in
            -- D (the box never drops to N on its own). N and R are reached ONLY by DOWNSHIFT-key
            -- TAPS: D -(tap)-> N -(tap)-> R (R speed-gated), exactly like the old tap-again gate.
            -- The UPSHIFT key ALWAYS returns to forward drive (R/N -> D). Reverse DRIVES by
            -- velocity via HK.ReverseDrive_Tick (W = back, S = brake), same as the manual box. The
            -- both-key chord is a convenience neutral toggle (D<->N; out of R it steps to N).
            local dodf = (origins and origins.fInitialDriveForce)
            -- S-RETAP TO NEUTRAL: S is a PURE BRAKE — braking to a stop STAYS in D. A FRESH S press
            -- (release, then press S again) while FULLY STOPPED in D selects NEUTRAL. This is the
            -- "tap S again for N" gate the driver expects: fully stop, tap S -> N. From N, the
            -- DOWNSHIFT key (J) steps to REVERSE (or stages launch control). Edge-detected off the
            -- physical brake pedal so a HELD brake (decel-to-stop) never trips it — only a fresh tap.
            -- DOUBLE-TAP S -> NEUTRAL (2026-08-16): two quick S taps while stopped, not one, so N is a
            -- deliberate gesture and a normal stop-and-hold never drops out of D. Detector every frame.
            local dblTapS = HK.autoDoubleTapS(Config.Gearbox.NeutralBrakeDoubleTapMs)
            if HK.autoRevSel == 'D' and dblTapS
               and (state.speedKmh or 0) <= (RG.StopKmh or 2.0) then
                HK.autoRevSel = 'N'
            end
            -- CHORD (both shift keys): convenience neutral toggle.
            if reqNeutralTap then
                reqNeutralTap = false
                reqUp, reqDown = false, false
                if HK.autoRevSel == 'R' then HK.autoRevSel = 'N'
                else HK.autoRevSel = (HK.autoRevSel == 'N') and 'D' or 'N' end
            end
            -- DOWNSHIFT key (J): from N -> R (R only at/below NToRMaxKmh; the box never selects R
            -- itself). Also steps D -> N as a fallback so J alone still walks the full down-ladder.
            if reqDown then
                reqDown = false
                if     HK.autoRevSel == 'D' then HK.autoRevSel = 'N'
                elseif HK.autoRevSel == 'N' and (state.speedKmh or 0) <= (RG.NToRMaxKmh or 8.0) then
                    HK.autoRevSel = 'R'
                end
            end
            -- UPSHIFT key: ALWAYS back to forward drive (R->D, N->D) — never stalls at N.
            -- DOUBLE-TAP W does the same (a "pull away" gesture out of neutral): re-engage D.
            -- Call the detector EVERY frame (advances shared edge state); only ACT while in N.
            local dblTapW = HK.autoDoubleTapW(Config.Gearbox.NeutralDoubleTapMs)
            -- BRAKE-HELD REV LOCK: while S (footbrake) is held in N you're free-revving — tap W to
            -- blip, not to engage. Only the double-tap with brake RELEASED pulls away into D. The
            -- UPSHIFT key (reqUp) still always engages (deliberate gesture, not the brake-rev blip).
            local brakeHeldRev = (HK._pedalBrake or 0.0) > 0.5
            if reqUp or (HK.autoRevSel == 'N' and dblTapW and not brakeHeldRev) then
                reqUp = false
                HK.autoRevSel = 'D'
            end
            -- NO AUTO-SETTLE: S is a PURE BRAKE — braking to a stop STAYS in D (or wherever). Neutral
            -- is reached ONLY by a DOWNSHIFT-key TAP (D->N), and reverse by a second TAP (N->R), like
            -- the old tap-again gate. Nothing drops into N or pulls away on its own.
            if HK.autoRevSel == 'R' then
                HK.autoReverseDrive(veh, state, dt, gbDriveForceLive or dodf)
                return                        -- reverse owns the frame (velocity-driven)
            elseif HK.autoRevSel == 'N' then
                -- TRUE NEUTRAL: cut drive + pin a forward gear so a held brake can't roll into
                -- native reverse. Brake still brakes; car free-rolls but is never powered.
                if dodf then setDriveForce(veh, 0.0) end
                if vl_getCurrentGear(veh) < 1 then vl_setCurrentGear(veh, 1) end
                HK.torqueMult = 0.0
                HK.autoStandstillBrake(veh, state)   -- S is a pure brake — kill native S-reverse at a stop
                -- FLYWHEEL FREE-REV PAINT (mirrors the manual neutral, gearbox.lua ~6761): actively
                -- OVERWRITE rpm every frame from the W THROTTLE only. Without this GTA's native engine
                -- rpm shows through and a held S (native control 72 = reverse-accel in gear 0) REVS the
                -- engine even though drive is cut — the "S gives rpm ramp in neutral" bug. Painting off
                -- state.throttle makes only W blip the revs; S stays at idle.
                do
                    local t      = state.throttle or 0.0
                    local revMax = (Config.Gearbox.NeutralRevMax or 1.0)
                    if (state.speedKmh or 0) > (Config.Gearbox.NeutralRevCapKmh or 5.0) then
                        revMax = Config.Gearbox.NeutralRevMaxMoving or 0.55
                    end
                    local idle   = Config.Gearbox.Flywheel and Config.Gearbox.Flywheel.IdleRpm or 0.20
                    local target = idle + (revMax - idle) * t
                    if target < idle then target = idle end
                    vl_setRpmRaw(veh, HK.flywheelRev(state.rpm, target, dt, Config.Gearbox.Flywheel and Config.Gearbox.Flywheel.NeutralDownRatio))
                end
                return                        -- free-roll N
            else
                -- D: restore drive, GTA's box drives forward.
                if dodf then setDriveForce(veh, gbDriveForceLive or dodf) end
                -- UN-PIN REVERSE: leaving R/N, GTA's box is still sitting in native gear 0 (from the
                -- velocity-driven reverse frame). GetDisplayGear falls back to the native gear in 'D',
                -- and native 0 reads as R -> the speedo STAYS on R after an upshift out of reverse.
                -- Bump native gear to 1 once we're not actually rolling backward so the box shows D.
                if vl_getCurrentGear(veh) < 1 and (state.forwardSpeed or 0.0) > -0.5 then
                    vl_setCurrentGear(veh, 1)
                end
                HK.autoStandstillBrake(veh, state)   -- S is a pure brake — kill native S-reverse at a stop
            end
        else
        -- NEUTRAL TAP-TOGGLE (comfort auto, LEGACY): TAP both keys to enter neutral, tap again to
        -- drive off. Unified with the reverse gate (neutral == revGate=='neutral'), so tap-N and
        -- brake-to-N are one state; throttle/brake walk out. (No more hold-both coast.)
        if cfg.AutoNeutralGesture ~= false and reqNeutralTap then
            reqNeutralTap = false
            reqUp, reqDown = false, false
            revGate = (revGate == 'neutral') and 'none' or 'neutral'
            if revGate == 'neutral' then
                revBrakeArmed, revThrArmed, revWalkAt = false, false, 0
            else
                revWasMoving = false     -- tapped OUT: don't let a held brake re-enter N this frame
            end
        end

        -- REVERSE GATE (comfort auto, LEGACY): brake to a stop -> NEUTRAL (free-roll), release+press
        -- S -> REVERSE, W walks R->N->D. NEUTRAL cuts drive so GTA can't roll into reverse on
        -- its own; REVERSE/none restore drive so GTA's box drives (fwd) or reverses. Speedo
        -- R/N comes from GetDisplayGear reading revGate. Only acts at low speed (gate self-gates).
        do
            local g = updateReverseGate(state)
            if g == 'neutral' then
                -- TRUE NEUTRAL: cut drive + PIN a forward gear so the held brake can't make GTA
                -- select reverse (the 'shows N but rolls backward' bug). Brake still brakes;
                -- car free-rolls but is never powered back. Reverse only via the gate.
                if origins and origins.fInitialDriveForce then setDriveForce(veh, 0.0) end
                if vl_getCurrentGear(veh) < 1 then vl_setCurrentGear(veh, 1) end
                HK.torqueMult = 0.0
                return                        -- free-roll N; GTA owns nothing this frame
            else
                -- reverse (GTA brake-to-reverse) OR none (forward): drive restored, GTA's box drives.
                if origins and origins.fInitialDriveForce then
                    setDriveForce(veh, gbDriveForceLive or origins.fInitialDriveForce)
                end
            end
        end
        end

        -- Seed gear tracking on first tick so we don't fire a phantom shift-dip
        -- on launch (autoLastGear starts -99 = "no shift yet").
        if autoLastGear == -99 then autoLastGear = cur end

        -- ANTI-HUNT: enforce a minimum dwell between shifts so the box can't
        -- oscillate on hills/load. Native handles it; just assert it once.
        if not autoMinSet then
            vl_setMinTimeBetweenGearShifts(veh, cfg.AutoMinShiftMs or 750)
            autoMinSet = true
        end

        -- EARLY/LAZY UPSHIFT — keep revs low and quiet by nudging GTA up a gear at
        -- light throttle. This is a ONE-SHOT nudge: GTA still owns the gear and can
        -- downshift freely (we never pin), so the box can't get stuck high. Applies
        -- to EVERY car when AutoEarlyShiftAllCars is set (the comfort point for slow
        -- work/entry vehicles); otherwise only to fast-shifting cars (legacy gate).
        if cfg.AutoEarlyShiftAllCars or autoFastShift then
            local thr = state.throttle or 0.0
            -- GEAR-RATIO: scale the comfort early-upshift point. >1 holds longer
            -- (sportier), <1 short-shifts even earlier (lazier/drag). Clamped under
            -- the limiter so a high mult can't disable the early shift entirely.
            local earlyRpm = cfg.AutoEarlyShiftRpm or 0.50
            if gbRatio and gbRatio.UpshiftRpmMult and gbRatio.UpshiftRpmMult ~= 1.0 then
                earlyRpm = earlyRpm * gbRatio.UpshiftRpmMult
                local cap = (cfg.RevLimiterRedline or 0.985) - 0.005
                if earlyRpm > cap then earlyRpm = cap end
            end
            if cur >= 1 and cur < gearcount
               and state.rpm > earlyRpm
               and thr < (cfg.AutoEarlyShiftMaxThrottle or 0.75)
               and now >= autoNextShiftOk then
                vl_setCurrentGear(veh, cur + 1)
                autoNextShiftOk = now + (cfg.AutoMinShiftMs or 750)
                HK.autoShiftDipStart = now
                autoShiftDipUntil = now + (cfg.AutoShiftDipMs or 160)
            end
        end

        -- SMOOTH SHIFT DIP: whenever the gear changes (ours or GTA's), apply a
        -- brief gentle torque dip so shifts feel smooth, not jerky. The dip is an
        -- AREA-NEUTRAL swell (TcFeel.RampedDip) — a breathing 1.0->floor->1.0 whose
        -- time-integral equals the old flat cut, so net accel (0-100) is UNCHANGED;
        -- only the feel softens from a step to a gentle "compressed" TC swell.
        if cur ~= autoLastGear then
            autoLastGear = cur
            HK.autoShiftDipStart = now
            autoShiftDipUntil = now + (cfg.AutoShiftDipMs or 160)
        end
        if now < autoShiftDipUntil then
            local flat = cfg.AutoShiftDipPower or 0.85
            local tf = Config.Gearbox.TcFeel
            if tf and tf.RampedDip then
                local win = (autoShiftDipUntil - HK.autoShiftDipStart)
                if win > 0 then
                    local tau = (now - HK.autoShiftDipStart) / win
                    HK.torqueMult = HK.torqueMult * HK.rampedDipMult(flat, tau, tf.DipShape)
                else
                    HK.torqueMult = HK.torqueMult * flat
                end
            else
                HK.torqueMult = HK.torqueMult * flat
            end
        end

        -- GENTLE LAUNCH: ease torque off the line so a standing start is smooth
        -- (comfort/family feel), fading back to full power by AutoLaunchKmh. Torque
        -- only — no RPM/gear writes. Only under throttle so it never holds the car.
        local lkmh = cfg.AutoLaunchKmh or 16.0
        if (state.speedKmh or 0) < lkmh and (state.throttle or 0) > 0.1 then
            local f = 1.0 - ((state.speedKmh or 0) / lkmh)        -- 1 at stop -> 0 at lkmh
            local lp = cfg.AutoLaunchPower or 0.82
            HK.torqueMult = HK.torqueMult * (lp + (1.0 - lp) * (1.0 - f))
        end

        -- THROTTLE DAMPING: soften a light/progressive press so comfort mode isn't
        -- jumpy. Full damping at the lightest throttle, easing to no damping by
        -- AutoThrottleDampMax. Torque-only; never cuts when you actually floor it.
        local thr = state.throttle or 0.0
        local dampMax = cfg.AutoThrottleDampMax or 0.60
        if thr > 0.0 and thr < dampMax then
            local damp = cfg.AutoThrottleDamp or 0.85
            local e = thr / dampMax                              -- 0 at no throttle -> 1 at dampMax
            HK.torqueMult = HK.torqueMult * (damp + (1.0 - damp) * e)
        end

        -- RPM-FLARE DAMP: keep revs steady/quiet at a relaxed cruise by gently
        -- trimming torque once past a comfortable rpm at light-to-mid throttle.
        -- (Flooring it past AutoRpmCalmThrottle releases this, so power is there
        -- when you ask.) Torque-only — does NOT write rpm (that broke audio before).
        if state.rpm > (cfg.AutoRpmCalm or 0.55)
           and thr < (cfg.AutoRpmCalmThrottle or 0.70) then
            HK.torqueMult = HK.torqueMult * (cfg.AutoRpmCalmPower or 0.90)
        end

        -- SOFT KICKDOWN: when the player floors it, allow a downshift but keep
        -- it gentle — bias one gear down rather than GTA's aggressive multi-drop.
        -- (Handled implicitly by min-shift-time + letting GTA pick; nothing to
        -- force here — flooring naturally raises revs and GTA downshifts once.)

        -- Reverse: leave entirely to GTA (automatic handles brake-to-reverse).
        return  -- auto mode does nothing further (no clutch / manual-shift logic)
    end

    -----------------------------------------------------------------
    -- MODE 3/4/5 — DCT (dual-clutch), GENUINE SCRIPT-DRIVEN.
    -- GTA's auto-shift is DISABLED for the whole DCT life (reduced-gear-ratio
    -- ON), so the SCRIPT owns every gear choice — no GTA-vs-script fight.
    --   AUTO sub-mode : the script auto-shifts (rpm thresholds from the profile).
    --   PADDLE (manual): K/J pick gears; over-rev downshift protection.
    --   Clutch key toggles auto<->manual; a paddle pull also engages manual.
    -- Both sub-modes feed ONE gear engine: a rev-matched shift WINDOW that
    -- decouples drive, lands RPM in the new ratio's band, then commits the gear
    -- once (never a per-frame slam — that was the no-torque/dead-zone bug).
    -- Per-mode behaviour from Config.Gearbox.DctProfiles[mode].
    -- paddleOnly (no auto sub-mode) comes from the model's DB flag (paddleOnly=1)
    -- OR a profile that sets P.PaddleOnly — letting ANY DCT tier be locked to
    -- paddle-only per model (e.g. F1 feel on a Chiron) without ditching its auto.
    -----------------------------------------------------------------
    if gearMode == 3 or gearMode == 4 or gearMode == 5 then
        local cfg = Config.Gearbox
        -- nil-safe: if DctProfiles is missing entirely, or lacks both this gearMode and the [3]
        -- fallback, `P` would be nil and the first P.* read crashes. Guard the whole chain.
        local P   = (cfg.DctProfiles and (cfg.DctProfiles[gearMode] or cfg.DctProfiles[3])) or {}
        local cur = vl_getCurrentGear(veh)

        -- TC SLIP-FLARE DE-BIAS (mode 3 only). Last frame we may have PAINTED the rpm
        -- needle slightly ahead of the true value (converter slip — see the tail of this
        -- branch). GetVehicleCurrentRpm now reports that painted value, so subtract it
        -- back off BEFORE any rpm-based decision (auto up/down-shift, limiter, guards)
        -- reads state.rpm — otherwise the flare would feed its own shift logic (the old
        -- audio/shift-hunt hazard) and could nudge shift points = a perf change. This
        -- keeps every DECISION anchored to the true rpm; only the NEEDLE+AUDIO flares.
        if gearMode == 3 and HK.tcSlipCur > 0.0 then
            state.rpm = (state.rpm or 0.0) - HK.tcSlipCur
            if state.rpm < 0.0 then state.rpm = 0.0 end
        end

        -- One-time init: disable GTA auto-shift, snap to a speed-matched gear.
        if not dctStarted then
            if not isEasy() then
                vl_setTransmissionReducedGearRatio(veh, true)
            end
            dctStarted = true
        end

        -- SAFETY RE-ARM: if we forced reduced-ratio OFF for a free-rev neutral (EV-ramp backstop)
        -- but we're NO LONGER in neutral (any exit path — throttle, gate, launch, paddle), make
        -- sure reduced-ratio is back ON so the script owns gears again. Catches any exit that
        -- didn't restore it explicitly. One-shot (dctNeutralRatioOff clears).
        if HK.dctNeutralRatioOff and not dctNeutral then
            if not isEasy() then vl_setTransmissionReducedGearRatio(veh, true) end
            HK.dctNeutralRatioOff = false
        end

        learnGearRatio(state, cur)   -- shared rpm-per-speed learner (gbRpmPerSpeed)

        -- Project the RPM a given gear WOULD produce at the current speed. Uses the
        -- shared module-level projectRpmFor, with a DCT-only proxy fallback (extrapolate
        -- from the current gear's ratio) when the target gear isn't learned yet.
        -- NOTE: local function inside the tick = one closure alloc per frame. LuaGLM
        -- (FiveM's Lua 5.4) reuses closure memory efficiently; moving to module scope
        -- would require passing 4 upvalues to 10+ call sites for negligible gain.
        local function projectGearRpm(g)
            local r = projectRpmFor(g, state)
            if r then return r end
            -- FALLBACK (target gear g not yet learned at this speed). rpm is PROPORTIONAL to
            -- gear ratio at a fixed road speed, and the game exposes the REAL per-gear ratios
            -- (GetVehicleGearRatio) — so scale the CURRENT gear's known rpm by the true ratio
            -- difference: rpm(g) = rpm(cur) * ratio[g] / ratio[cur]. This is EXACT (subject to
            -- ratio-read validity), unlike the old flat "+OverrevStep per gear" guess which
            -- badly UNDER-read a much-shorter low gear at high speed — e.g. gear 3 @ 234 km/h
            -- projected gear 2 at only ~0.84 (real 2nd is far past redline), so an illegal
            -- high-speed kickdown to 2nd passed the over-rev check, dropped, then instantly
            -- snapped back = the "2->3 bops to 2 and back" hunt. Real ratios kill that.
            local curRpmNow = state.rpm or GetVehicleCurrentRpm(veh)
            if curRpmNow and curRpmNow > 0.001 and veh and veh ~= 0 then
                local rCur = GetVehicleGearRatio(veh, cur)
                local rG   = GetVehicleGearRatio(veh, g)
                -- ratios are POSITIVE for forward gears; a bad/zero read => skip to the estimate
                if rCur and rG and rCur > 0.01 and rG > 0.01 then
                    return curRpmNow * (rG / rCur)
                end
            end
            -- LAST-RESORT estimate (no valid ratio read): the old per-gear step, but tell the
            -- truth that a LOWER gear revs HIGHER (multiply UP for g<cur), so it can't under-read.
            local curRps = gbRpmPerSpeed[cur]
            if curRps and state.speedKmh > 0 then
                local ratio = curRps * (1.0 + (cur - g) * (P.OverrevStep or 0.18))
                return ratio * state.speedKmh
            end
            return nil
        end

        -- Best forward gear for the current speed (RPM lands near EngageTargetRpm).
        local function bestGearForSpeed()
            local want = P.EngageTargetRpm or 0.55
            local best, bestErr
            for g = 1, gearcount do
                local r = projectGearRpm(g)
                if r then
                    local err = math.abs(r - want)
                    if not bestErr or err < bestErr then best, bestErr = g, err end
                end
            end
            return best
        end

        if dctLastGear == -99 then
            dctLastGear = cur
            if not enteredMoving and not dctManual and (cfg.DctAutoStartInNeutral ~= false) then
                -- FRESH start (engine was off when we got in): begin in NEUTRAL,
                -- like keying on a real DCT car. A paddle/auto-engage later picks a
                -- safe gear via bestGearForSpeed. (If we joined a running car, fall
                -- through and engage a speed-matched gear immediately.)
                -- GATED on Config.Gearbox.DctAutoStartInNeutral: when false, skip this
                -- and fall through to engage a safe gear right away (no spacebar to
                -- pull away). Manual sub-mode and the moving-entry case never start in N.
                dctNeutral = true
                dctPendingGear = nil
                dctGear, dctCommittedGear = 0, 0
                vl_setCurrentGear(veh, 0)
                if netEnt then netEnt.state:set('sync_gear', 0, true) end
            else
                -- Prefer the gear ACTUALLY engaged (reliable); fall back to the
                -- ratio-based best only if cur is invalid (e.g. neutral on spawn).
                local snap = (cur >= 1 and cur <= gearcount) and cur or (bestGearForSpeed() or 1)
                -- SPEED-SANITY (the "spawned in 7th, drops slowly" bug): if you HOLD accelerate
                -- while entering before our box takes over, GTA's native auto floats the car up
                -- to top gear, so `cur` reads e.g. 7 even at a crawl. A car at low speed cannot
                -- physically be in a high gear. Two independent clamps, both DOWN-only (never
                -- invent a taller gear), on this once-per-car init:
                --   1) ratio/learned best-for-speed (bestGearForSpeed) when it's available;
                --   2) a HARD low-speed floor that needs no learned data — under DctInitSlowKmh
                --      (default 30) the box MUST start in 1st, the only physically valid gear
                --      for a standing/creeping start. This catches the case where the ratio
                --      projection is itself unreliable at spawn (near-zero rpm).
                local bg = bestGearForSpeed()
                if bg and bg >= 1 and snap > bg then snap = bg end
                if (state.speedKmh or 0.0) < (cfg.DctInitSlowKmh or 30.0) and snap > 1 then
                    snap = 1
                end
                dctGear, dctCommittedGear, dctPendingGear = snap, snap, nil
            end
        end

        -- DCT shift-window duration, ABSORBED from the car's handling.meta gear-
        -- change rate (gbRawShiftMs). A responsive car (short raw time) gets a
        -- snappier window; a lazy one a longer window — but always clamped into
        -- THIS mode's own [ShiftMinMs..ShiftMaxMs] so the modes keep a fixed gap
        -- (basic > supercar > F1). Falls back to the flat ShiftDipMs if a profile
        -- doesn't define the range. Scaled by ShiftAbsorb (how much of the raw time
        -- carries through). Computed once per tick (cheap; gbRawShiftMs is static).
        local dctWin
        do
            local lo = P.ShiftMinMs
            local hi = P.ShiftMaxMs
            if lo and hi then
                local v = gbRawShiftMs * (P.ShiftAbsorb or 0.5)
                if v < lo then v = lo elseif v > hi then v = hi end
                dctWin = v
            else
                dctWin = P.ShiftDipMs or 90
            end
            -- GEAR-RATIO: scale DCT shift speed (mirror of the manual/seq shiftTime
            -- scaling done at Enable). <1 = faster shifts (hyper), >1 = lazier.
            -- Floored at 10ms so a shift is never instant/imperceptible.
            if gbRatio and gbRatio.ShiftTimeMult and gbRatio.ShiftTimeMult ~= 1.0 then
                dctWin = dctWin * gbRatio.ShiftTimeMult
                if dctWin < 10 then dctWin = 10 end
            end
            -- THROTTLE-GROUNDED WINDOW (mode 3 = Automatic-Paddle / TC only). A torque
            -- converter LOADS UP with throttle: firm, short "bang" at WOT (converter
            -- locked, ZF-8HP-in-sport feel); soft, long "slur" at cruise. PERF-NEUTRAL
            -- ANCHOR: at WOT the window stays EXACTLY the meta-absorbed dctWin (so 0-100
            -- is unchanged) — we only GROW it toward ShiftMaxMs as throttle eases. At
            -- very low speed we soften a touch more (a creeping TC is at its slushiest).
            -- DCT tiers 4/5 deliberately skip this — near-constant-firm at any throttle.
            if gearMode == 3 and P.ShiftMaxMs then
                local thr = state.throttle or 0.0
                if thr < 0 then thr = 0 elseif thr > 1 then thr = 1 end
                local firm = dctWin                       -- WOT baseline (absorbed + ratio-scaled) = unchanged
                local soft = P.ShiftMaxMs
                if gbRatio and gbRatio.ShiftTimeMult and gbRatio.ShiftTimeMult ~= 1.0 then
                    soft = soft * gbRatio.ShiftTimeMult   -- match dctWin's ratio scaling
                end
                if soft < firm then soft = firm end        -- never shorter than the firm anchor
                -- t: 1 at/above 0.9 throttle (firm anchor), 0 at closed throttle (full slur)
                local t = thr / 0.9
                if t > 1 then t = 1 end
                local w = soft + (firm - soft) * t         -- thr high -> firm; thr low -> soft
                -- very low speed: nudge further toward the soft end (slushiest creep)
                local kmh = state.speedKmh or 0.0
                if kmh < 20.0 then
                    local slow = 1.0 - (kmh / 20.0)        -- 1 at rest -> 0 by 20km/h
                    w = w + (soft - w) * 0.5 * slow        -- up to halfway further toward soft
                end
                if w < 10 then w = 10 end
                dctWin = w
            end
        end
        -- PADDLE (manual) shift window — deliberately slower/heavier than the auto
        -- window so manual paddle shifts feel less frantic. Per-profile P.PaddleShiftMs;
        -- falls back to the auto dctWin if a profile doesn't set it. (dctWin already
        -- carries the gear-ratio ShiftTimeMult; scale the explicit PaddleShiftMs too.)
        local paddleWin = P.PaddleShiftMs or dctWin
        if P.PaddleShiftMs and gbRatio and gbRatio.ShiftTimeMult and gbRatio.ShiftTimeMult ~= 1.0 then
            paddleWin = P.PaddleShiftMs * gbRatio.ShiftTimeMult
            if paddleWin < 10 then paddleWin = 10 end
        end

        -- /handlingdbg: stash the DCT live window + sub-mode + logical gears.
        if HK.hdbgOn and HK.dbgGear then
            local d = HK.dbgGear
            d.dctWin      = dctWin                          -- current AUTO shift-window (throttle-grounded on mode 3)
            d.dctPaddle   = paddleWin                       -- manual paddle window
            d.dctGear     = dctGear                         -- our logical/UI gear
            d.dctCommitted= dctCommittedGear                -- gear actually written to the box
            d.dctPending  = dctPendingGear                  -- gear mid-shift (nil = none)
            d.dctSub      = dctManual and 'paddle' or 'auto'
            d.dctNeutral  = dctNeutral
            d.profLabel   = P.Label                         -- DctProfile label (Automatic (Paddle)/Sport DCT/Super DCT)
        end

        -- Open a rev-matched shift window toward newTg (clamped to box range).
        -- winOverride lets PADDLE (manual) shifts use a slower, more deliberate
        -- window than the snappy auto shifts (P.PaddleShiftMs) — auto passes nil.
        local function requestGear(newTg, winOverride)
            if newTg < 1 or newTg > gearcount then return false end
            local w = winOverride or dctWin
            -- DOWNSHIFT gets a longer window so the rev-match blip clearly LEADS the
            -- gear engagement (blip, then slot ~DownshiftRevMatchMs later) instead of
            -- the two feeling simultaneous. Upshifts keep the snappy window.
            if newTg < dctCommittedGear then
                local dwn = Config.Gearbox.DownshiftRevMatchMs or 240
                if w < dwn then w = dwn end
            end
            if Config.Gearbox.Debug then
                print(('[hk-dct] shift %d->%d  window=%dms  mode=%d  (dctWin=%d paddleWin=%d gbRawShiftMs=%.0f)')
                    :format(dctCommittedGear, newTg, math.floor(w), gearMode,
                            math.floor(dctWin), math.floor(paddleWin), gbRawShiftMs))
            end
            dctPendingGear   = newTg
            dctShiftEndAt    = now + w
            dctGear          = newTg      -- logical/UI gear moves now
            dctShiftDipUntil = now + w
            return true
        end

        ------------------------------------------------------------------
        -- SUB-MODE SWITCH (auto <-> manual)
        -- DB paddleOnly flag (DCT only): 1 = force paddle-only (no auto sub-mode),
        -- 2 = force-AUTO (locked in auto, paddle inputs can't engage manual). On a
        -- non-DCT mode value 2 is simply ignored (this whole branch is DCT-only).
        local dbm = HK.manualModels and HK.manualModels[modelKey(veh)]
        local paddleOnly = (P.PaddleOnly == true) or (dbm ~= nil and dbm.paddle == 1)
        local forceAuto  = (dbm ~= nil and dbm.paddle == 2)
        local function setDctManual(on)
            if paddleOnly then on = true end          -- F1 tier: always manual
            if forceAuto  then on = false end         -- force-auto: never leave auto sub-mode
            if on == dctManual then return end
            dctManual = on
            dctNeutral = false                         -- any sub-mode switch leaves neutral
            dctNeutralHold = false
            dctLatchedNeutral = false                  -- a deliberate shift/mode-change leaves latched neutral
            dctReverse = false                         -- ...and leaves reverse
            -- ALSO clear the shared reverse gate — the DCT-auto tap-neutral drives revGate, and
            -- if we left it 'neutral' the reverse-gate mirror would re-set dctNeutral next frame
            -- (= stuck in N after clutch->auto). A sub-mode switch always means "engage a gear".
            revGate, revBrakeArmed, revThrArmed, revWalkAt = 'none', false, false, 0
            dctOverrevUntil, dctBoostUntil, dctShiftDipUntil = 0, 0, 0
            dctPendingGear = nil
            -- CANCEL any launch stage/measurement: a sub-mode switch leaves neutral, so neither
            -- launch block runs again to clear lcPhase — without this it strands at 'staged'
            -- (speedo LC pill stuck on + stale lcTargetRpm carried into the next real launch).
            if lcPhase ~= 'off' then
                if lcPhase == 'staged' then vl_setMaxLaunchRevs(veh, 1.0) end   -- release any rev cap
                lcPhase, lcLaunchAt = 'off', 0
                lcTele.active = false
                if HK and HK.launch then HK.launch.active, HK.launch.phase, HK.launch.rpm = false, 'off', 0.0 end
            end
            -- Sync to the gear ACTUALLY engaged so manual picks up exactly where
            -- the car is (already rev-matched). The old code snapped to a
            -- ratio-COMPUTED 'best' gear (bestGearForSpeed), which used stale/
            -- incomplete learned rpm-per-speed data and frequently landed on the
            -- WRONG gear after an auto<->manual toggle — that was the bug. cur is
            -- authoritative; only fall back to the estimate if cur is invalid.
            -- Per automanualdct.md: on RETURN TO AUTO the box STAYS in the current
            -- gear and the auto shift-map resumes from there (no forced step on the
            -- mode change itself). Same on ENTER MANUAL. So both directions keep cur.
            local snap = (cur >= 1 and cur <= gearcount) and cur or (bestGearForSpeed() or 1)
            -- LOW-SPEED FLOOR (the "comes out of reverse in 2nd/6th" bug): leaving reverse/neutral
            -- (cur < 1) the engine rpm is the PAINTED reverse/neutral free-rev (high), so
            -- bestGearForSpeed scales that across the ratios and picks a TALL gear. Nearly stopped,
            -- the only correct take-off gear is 1st. Same DOWN-only floor the DCT init uses.
            if cur < 1 and (state.speedKmh or 0.0) < (cfg.DctInitSlowKmh or 30.0) and snap > 1 then
                snap = 1
            end
            dctGear, dctCommittedGear = snap, snap
            -- If we were sitting in NEUTRAL/reverse (native gear < 1), actively ENGAGE the
            -- snapped gear so the car pulls away — just setting dctGear leaves the wheels
            -- decoupled. requestGear opens a rev-matched window and restores drive.
            if cur < 1 then requestGear(snap) end
            if cfg.DctNotify ~= false then
                local lbl = P.Label or 'DCT'
                if on then vl_notify('~b~' .. lbl .. ' ~w~Manual', 'primary')
                else       vl_notify('~g~' .. lbl .. ' ~w~Auto', 'success') end
            end
        end
        if paddleOnly and not dctManual then dctManual = true end

        -- EXTERNAL BOX SELECTOR (hk-wheel wheel module). An external consumer (steering-wheel
        -- 'box' button) requests an auto<->manual flip via HK.reqBoxMode: 'auto'|'manual'|'toggle'.
        -- Consumed here through the SAME setDctManual path a clutch/paddle uses, so it obeys
        -- paddleOnly/forceAuto and all the neutral/reverse cleanup. Additive: nothing sets
        -- HK.reqBoxMode inside hk-handling; it's purely an inbound request slot. Cleared on read.
        if HK.reqBoxMode and not paddleOnly and not forceAuto then
            local want = HK.reqBoxMode
            HK.reqBoxMode = nil
            if want == 'toggle' then setDctManual(not dctManual)
            elseif want == 'manual' then setDctManual(true)
            elseif want == 'auto' then setDctManual(false) end
        elseif HK.reqBoxMode then
            HK.reqBoxMode = nil                        -- paddleOnly/forceAuto tier: ignore + clear
        end

        -- Clutch key (edge) => back to AUTO (ignored on paddle-only tiers).
        if clutchHeld and not dctClutchPrev and not paddleOnly then
            setDctManual(false)
        end
        dctClutchPrev = clutchHeld

        -- EV→ICE VOLUME RE-PRIME (v2): the e-mode->ICE edge armed HK.evReprimeArm. Fire ONE real
        -- shift now so GTA re-levels the (otherwise dimmed) restored engine note. Direction picked
        -- by rpm so it NEVER bogs/over-revs: if we're already spinning above the engage-target band
        -- -> UPSHIFT one (drops rpm); if we're below it -> DOWNSHIFT one (raises rpm). We verify the
        -- destination gear's PROJECTED rpm stays inside a safe window before committing; if the only
        -- move would bog or over-rev (or we're at a gear limit), fall back to the other direction,
        -- and if neither is safe, skip (better no re-prime than a bad shift). Runs on the driver's
        -- client where requestGear is authoritative — the shift sticks and the audio re-levels.
        if HK.evReprimeArm then
            HK.evReprimeArm = false
            local HYr = Config.Gearbox.Hybrid
            if HYr and HYr.EVReprimeShift ~= false and not dctNeutral and not dctReverse then
                -- BASE ON A SPEED-MATCHED GEAR, not raw cur and not dctCommittedGear.
                --  * dctCommittedGear is FROZEN through e-mode (DCT branch early-returns every frame),
                --    so it's stale.
                --  * cur (vl_getCurrentGear) is ALSO unreliable here: through e-mode the ICE is off and
                --    the DCT branch never ran, so GTA's own auto box floats cur to the TOP gear (no rpm
                --    feedback holds it low). Trusting cur committed gear 7 at a standstill and the box
                --    then crawled it back down = the "doesn't start from N/1, starts on 7th and drops
                --    slowly" bug the reprime introduced.
                -- bestGearForSpeed() derives the gear from actual road speed (exactly what the DCT init
                -- would pick), so the reprime shift lands where the car SHOULD be. Fall back to cur only
                -- if the speed-match can't be computed yet (ratios unlearned), then to gear 1.
                local cg = bestGearForSpeed()
                if not cg or cg < 1 or cg > gearcount then
                    cg = (cur >= 1 and cur <= gearcount) and cur or 1
                end
                if cg and cg >= 1 then
                    dctGear, dctCommittedGear, dctPendingGear = cg, cg, nil
                    local target = P.EngageTargetRpm or 0.55
                    local loSafe = HYr.EVReprimeMinRpm or 0.30   -- below = bog risk
                    local hiSafe = HYr.EVReprimeMaxRpm or 0.90   -- above = over-rev risk
                    local rpmNow = state.rpm or GetVehicleCurrentRpm(veh) or target
                    -- Preferred direction from current rpm vs the target band.
                    local upFirst = (rpmNow >= target)
                    -- NEVER SKIP: we MUST fire one gear event or the audio stays dimmed (user:
                    -- "make it ALWAYS shift"). So score BOTH adjacent gears and always pick one —
                    -- the safe window [loSafe..hiSafe] is now a PREFERENCE, not a veto. A gear whose
                    -- projected rpm lands INSIDE the band scores 0 (perfect); outside scores its
                    -- distance beyond the nearest edge (the "least-bad" bog/over-rev). We fire the
                    -- lowest score; ties go to the rpm-preferred direction (upFirst). This kills the
                    -- old skip at the range edges (top gear at the cap = the COMMON handoff; gear 1
                    -- at crawl) where both directions failed the strict window and nothing fired.
                    local function scoreGear(g)
                        if g < 1 or g > gearcount then return nil end     -- no such gear (edge)
                        local pr = projectGearRpm(g)
                        if not pr then return 0.0 end                     -- ratio unlearned -> treat as ideal
                        if pr < loSafe then return (loSafe - pr) end       -- bog magnitude
                        if pr > hiSafe then return (pr - hiSafe) end       -- over-rev magnitude
                        return 0.0                                         -- inside the band = ideal
                    end
                    local upG, dnG   = cg + 1, cg - 1
                    local upS, dnS   = scoreGear(upG), scoreGear(dnG)
                    local chosen
                    if upS and dnS then
                        -- both gears exist: lower score wins; tie -> rpm-preferred direction
                        if upS < dnS then chosen = upG
                        elseif dnS < upS then chosen = dnG
                        else chosen = upFirst and upG or dnG end
                    elseif upS then chosen = upG      -- only an upshift exists (we're in gear 1)
                    elseif dnS then chosen = dnG      -- only a downshift exists (we're in top gear)
                    end
                    local done = chosen ~= nil and requestGear(chosen) or false
                    if Config.Gearbox.Debug then
                        print(('[hk-hybrid] EV->ICE reprime from gear %d rpm=%.2f upFirst=%s -> gear %s (upS=%s dnS=%s) done=%s')
                            :format(cg, rpmNow, tostring(upFirst), tostring(chosen),
                                    tostring(upS), tostring(dnS), tostring(done)))
                    end
                end
            end
        end

        ------------------------------------------------------------------
        -- GEAR REQUESTS
        ------------------------------------------------------------------
        local shiftWindowOpen = (now < dctShiftEndAt)

        -- NEUTRAL (DCT) — gesture depends on the SUB-MODE (user spec):
        --   PADDLE-MANUAL: HOLD both keys = temporary neutral (release re-engages).
        --   AUTO:          TAP both keys  = TOGGLE latched neutral (tap again = drive off).
        -- Gesture by SUB-MODE (user spec):
        --   PADDLE-MANUAL (dctManual): HOLD both keys = temporary neutral (release re-engages).
        --   AUTO (not dctManual):      TAP both keys = TOGGLE latched neutral (stays until you
        --                              tap again, or drive off / paddle).
        local dctBothHeld = upHeld and downHeld
        if dctManual and not forceAuto then
            -- MANUAL sub-mode: HOLD-both temporary neutral.
            -- CONSUME reqNeutralTap here so a stray both-tap in paddle-manual doesn't stay latched
            -- (nothing else reads it in this branch) and then fire a PHANTOM neutral the instant
            -- the driver drops to auto via clutch (setDctManual(false) -> the auto tap-toggle below
            -- would see the stale latch and flip revGate to 'neutral' on the transition).
            reqNeutralTap = false
            -- RE-ARM only when BOTH keys are fully up — so a key still held after a shift OUT
            -- of neutral can't instantly re-enter N ('N carries over after shift' bug).
            if not upHeld and not downHeld then dctHoldNArmed = true end
            if dctBothHeld and dctHoldNArmed then
                reqUp, reqDown = false, false
                if not dctNeutral then
                    dctPreNeutGear = (dctGear >= 1) and dctGear or (bestGearForSpeed() or 1)
                    dctNeutral = true
                    dctNeutralHold = true               -- temporary (exits on release)
                    dctReverse = false
                    dctPendingGear = nil
                    vl_setCurrentGear(veh, 0)
                    if netEnt then netEnt.state:set('sync_gear', 0, true) end
                end
            elseif dctNeutral and dctNeutralHold and not dctBothHeld and lcPhase == 'off'
                   and not state.handbrake then
                -- Not both held any more -> leave temporary neutral (release-one-tap-other = a
                -- shift out of N; disarm so the still-held key can't re-neutral). GUARDS:
                -- lcPhase=='off' (a staged launch owns the exit via upshift) AND not-handbrake
                -- (e-brake held = staging, keep neutral so launchStageTick can stage below).
                dctNeutral = false
                dctNeutralHold = false
                dctHoldNArmed = false
                local g = dctPreNeutGear
                if g < 1 then g = bestGearForSpeed() or 1 end
                dctGear, dctCommittedGear = g, g
                requestGear(g, paddleWin)
            elseif not dctNeutral and dctBothHeld and not dctHoldNArmed then
                -- Both re-held but NOT armed (a key lingered from the last N): swallow the
                -- shift inputs so a held-through key doesn't fire a stray shift, but do NOT
                -- re-enter N until a clean both-release re-arms it.
                reqUp, reqDown = false, false
            end
        elseif not forceAuto then
            -- AUTO sub-mode: TAP-both TOGGLES neutral. Drives the SHARED revGate (single source
            -- of truth) so it can't desync with the reverse-gate block below — that block mirrors
            -- revGate -> dctNeutral/dctReverse each frame. So here we ONLY flip revGate; the
            -- mirror does the rest.
            if reqNeutralTap then
                reqNeutralTap = false
                reqUp, reqDown = false, false
                revGate = (revGate == 'neutral') and 'none' or 'neutral'
                if revGate == 'neutral' then
                    revBrakeArmed, revThrArmed, revWalkAt = false, false, 0
                else
                    revWasMoving = false     -- tapped OUT: don't let a held brake re-enter N this frame
                end
            end
            -- S-RETAP TO NEUTRAL (DCT/TC AUTO): S is a PURE BRAKE — braking to a stop STAYS in gear.
            -- A FRESH S press (release, then press S again) while FULLY STOPPED in a forward gear
            -- selects NEUTRAL — mirrors comfort/EV. From N, the DOWNSHIFT key (J) walks to REVERSE
            -- (paddle down-ladder below) or the handbrake+throttle stages launch control. Edge off
            -- the physical pedal so a HELD decel-to-stop brake never trips it — only a fresh tap.
            if Config.Gearbox.ReverseGate and Config.Gearbox.ReverseGate.KeyDriven then
                local RGa       = Config.Gearbox.ReverseGate
                -- DOUBLE-TAP S -> NEUTRAL (2026-08-16): two quick S taps while stopped, not one fresh
                -- press, so a normal decel-to-stop never drops the box to N. Detector every frame.
                local dblTapS = HK.autoDoubleTapS(Config.Gearbox.NeutralBrakeDoubleTapMs)
                if dblTapS and revGate ~= 'neutral' and not dctReverse
                   and (state.speedKmh or 0) <= (RGa.StopKmh or 2.0) then
                    revGate = 'neutral'
                    revBrakeArmed, revThrArmed, revWalkAt = false, false, 0
                end
                -- DOUBLE-TAP W: "pull away" gesture out of neutral -> forward drive (same as UPSHIFT
                -- key). Call the detector EVERY frame (advances shared edge state); only ACT in N.
                -- Setting revGate 'none' lets the mirror below clear dctNeutral and the auto box
                -- re-engages a safe gear from throttle input.
                local dblTapW = HK.autoDoubleTapW(Config.Gearbox.NeutralDoubleTapMs)
                -- BRAKE-HELD REV LOCK: S held in neutral = free-rev; tap W to blip, not engage.
                -- Only pull away into gear on the double-tap once the brake is RELEASED.
                if dblTapW and revGate == 'neutral' and (HK._pedalBrake or 0.0) <= 0.5 then
                    revGate = 'none'
                    revBrakeArmed, revThrArmed, revWalkAt = false, false, 0
                    revWasMoving = false
                    dctNeutral, dctLatchedNeutral = false, false
                    HK._neutralExitThrCut = true    -- swallow the held double-tap W so leaving N doesn't lurch
                end
            end
        end

        -- LAUNCH CONTROL (DCT PADDLE-MANUAL). v6: LC stages from neutral but IMMEDIATELY engages a REAL
        -- gear 1 (lcEngageGear1 — clears dctNeutral, commits dctGear/dctCommittedGear=1) so the speedo
        -- shows a genuine 1, no fake paint. FIRE = handbrake release / upshift with throttle floored.
        -- Bail leaves the box IN GEAR 1. GATE widened to lcPhase active so the tick keeps running after
        -- the auto-upshift clears dctNeutral (was `dctManual and dctNeutral`, which stopped one frame in).
        if dctManual and (dctNeutral or lcPhase ~= 'off') and not dctPendingGear then
            local lc = launchStageTick(veh, state, dt, true, reqUp)
            if lc == 'staged' then
                reqUp, reqDown = false, false        -- staged: swallow paddle taps except the launch fire
                -- lcEngageGear1 already engaged REAL gear 1 + drive force; don't pin gear 0 anymore.
                return                               -- sit staged this frame
            elseif lc == 'launch' then
                reqUp = false                        -- consume the upshift that fired the launch (already in 1)
                dctNeutral, dctNeutralHold, dctLatchedNeutral = false, false, false
                dctGear, dctCommittedGear = 1, 1     -- already committed by lcEngageGear1; no requestGear (avoids coast dip)
                -- fall through: launchBoostApply runs on the drive frames.
            end
        end

        -- PADDLE UPSHIFT — engages manual, requests next gear.
        if reqUp and forceAuto then reqUp = false end       -- force-auto: paddles inert
        if reqUp then
            reqUp = false
            dctLatchedNeutral = false                       -- a paddle deliberately leaves latched neutral
            -- Capture neutral/reverse BEFORE setDctManual (which clears them + snaps
            -- a gear). Otherwise, exiting a double-tap neutral from AUTO sub-mode,
            -- setDctManual(true) would wipe dctNeutral first and we'd skip the
            -- speed-based safe-gear pick, landing on 1st.
            local wasReverse = dctReverse
            local wasNeutral = dctNeutral
            local keyDriven = Config.Gearbox.ReverseGate and Config.Gearbox.ReverseGate.KeyDriven
            setDctManual(true)
            if wasReverse and keyDriven then
                -- KEY-DRIVEN: an UPSHIFT out of reverse ALWAYS returns to FORWARD drive (R -> 1),
                -- never stalling at N. Near-stationary so 1st is always the safe re-engage gear.
                dctReverse = false
                dctNeutral = false
                dctPendingGear = nil
                dctGear, dctCommittedGear = 1, 1
                requestGear(1, paddleWin)
                if netEnt then netEnt.state:set('sync_gear', 1, true) end
            elseif wasReverse then
                -- LEGACY: R -> N (up out of reverse goes to neutral, mirroring the ladder)
                dctReverse = false
                dctNeutral = true
                dctPendingGear = nil
                dctGear, dctCommittedGear = 0, 0
                vl_setCurrentGear(veh, 0)
                if netEnt then netEnt.state:set('sync_gear', 0, true) end
            elseif wasNeutral then
                -- Leaving neutral. The safe gear depends on SPEED, not how long you
                -- coasted: near-stationary -> 1st; at any real speed -> the automatic
                -- safe-gear detection (bestGearForSpeed) so we never slam into a low
                -- gear at speed and over-rev. Stays in manual/paddle.
                dctNeutral = false
                dctNeutralHold = false
                local g
                if (state.speedKmh or 0) <= (Config.Gearbox.NeutralReengage1stKmh or 12.0) then
                    g = 1
                else
                    g = bestGearForSpeed() or 1
                end
                dctGear, dctCommittedGear = g, g
                requestGear(g, paddleWin)
            elseif not shiftWindowOpen and dctGear < gearcount then
                if state.rpm >= (P.BoostRpm or 0.80) then
                    dctBoostUntil = now + (P.BoostHoldMs or 600)
                end
                requestGear(dctGear + 1, paddleWin)
            end
        end

        -- PADDLE DOWNSHIFT — engages manual; over-rev protection.
        if reqDown and forceAuto then reqDown = false end   -- force-auto: paddles inert
        if reqDown then
            reqDown = false
            dctLatchedNeutral = false                       -- a paddle deliberately leaves latched neutral
            local wasReverse = dctReverse
            local wasNeutral = dctNeutral
            setDctManual(true)
            if wasReverse then
                -- already in reverse: down does nothing (real DCTs don't stack R)
            elseif wasNeutral then
                -- N -> R (down past neutral = reverse). SIMPLE (default): always.
                -- REALISTIC: only nearly stopped AND braking. DCT AUTO never gets
                -- here (it's not dctManual / uses GTA brake-to-reverse instead).
                local okR = true
                if cfg.ReverseGate and cfg.ReverseGate.KeyDriven then
                    -- KEY-DRIVEN: S is a pure brake, NOT a reverse-arm. The DOWN key alone
                    -- selects reverse; gate on speed only (nearly stopped), no brake required.
                    okR = (state.speedKmh or 0) <= (cfg.ReverseGate.NToRMaxKmh or 8.0)
                elseif cfg.RealisticReverseDct then
                    okR = (state.speedKmh or 0) < (cfg.ReverseMaxKmh or 8.0)
                          and (state.brake or 0) > 0.5
                end
                if okR then
                    dctNeutral = false
                    dctNeutralHold = false
                    dctReverse = true
                    dctOverrevUntil = 0           -- reverse clears any pending penalty
                    dctPendingGear = nil
                    dctGear, dctCommittedGear = 0, 0
                    vl_setCurrentGear(veh, 0)
                    if netEnt then netEnt.state:set('sync_gear', -1, true) end
                end
            elseif dctGear == 1 and not shiftWindowOpen and now >= dctOverrevUntil then
                -- rotate DOWN from 1st into NEUTRAL (ladder: 1 -> N -> (down) -> R).
                -- Gated on no active over-rev penalty so spamming downshift during a
                -- protection bounce can't drop us into a half-state neutral.
                dctNeutral = true
                dctOverrevUntil = 0            -- entering neutral clears any pending penalty
                dctPendingGear = nil
                dctGear, dctCommittedGear = 0, 0
                vl_setCurrentGear(veh, 0)
                if netEnt then netEnt.state:set('sync_gear', 0, true) end
            elseif not shiftWindowOpen and now >= dctOverrevUntil and dctGear >= 2 then
                local newTg = dctGear - 1
                local proj  = projectGearRpm(newTg)
                if proj and proj > (P.OverrevRpm or 0.95) then
                    -- ILLEGAL: beep + brief penalty dip to the lower gear (routed
                    -- through the same window so it rev-matches), then bounce back.
                    -- PlaySoundFrontend has no volume arg, so loudness = number of
                    -- STACKED simultaneous calls (they layer additively). Count is
                    -- config-driven (Config.Gearbox.DctBeepStack) — integer only, so
                    -- e.g. 4 ~= 2x the old 2-stack (a bit over the asked 1.75x).
                    if now >= dctBeepAt then
                        local stack = math.max(1, math.floor((Config.Gearbox.DctBeepStack or 4) + 0.5))
                        for _ = 1, stack do
                            PlaySoundFrontend(-1, 'CHECKPOINT_MISSED', 'HUD_MINI_GAME_SOUNDSET', true)
                        end
                        SetTimeout(80, function()
                            for _ = 1, stack do
                                PlaySoundFrontend(-1, 'CHECKPOINT_MISSED', 'HUD_MINI_GAME_SOUNDSET', true)
                            end
                        end)
                        dctBeepAt = now + 500
                    end
                    dctOverrevReturn = dctGear
                    dctOverrevUntil  = now + math.random(P.OverrevMinMs or 280, P.OverrevMaxMs or 480)
                    dctPendingGear, dctShiftEndAt, dctGear = newTg, now + paddleWin, newTg
                else
                    requestGear(newTg, paddleWin)
                end
            end
        end

        -- Over-rev penalty expiry => snap back UP to the protected gear (windowed).
        -- Never while in neutral/reverse (we left the gear ladder deliberately).
        if dctManual and dctOverrevUntil > 0 and now >= dctOverrevUntil
           and not dctNeutral and not dctReverse then
            dctOverrevUntil = 0
            dctPendingGear, dctShiftEndAt, dctGear = dctOverrevReturn, now + paddleWin, dctOverrevReturn
        elseif (dctNeutral or dctReverse) and dctOverrevUntil > 0 then
            dctOverrevUntil = 0                  -- in N/R: just drop the stale penalty
        end

        -- REVERSE GATE (DCT AUTO sub-mode). Two modes:
        --   KEY-DRIVEN (new): S is a PURE BRAKE — it NEVER selects reverse. Reverse is reached
        --     ONLY by the DOWNSHIFT key (which flips to paddle-manual and walks gear->N->R via
        --     the down-ladder below), and left by the UPSHIFT key. Here we ONLY honour the
        --     CHORD-set neutral (revGate=='neutral' from the tap-both toggle above) + the
        --     launch-staged guard; we do NOT run updateReverseGate (the S-brake machine).
        --   LEGACY: the S-brake machine — brake to a stop -> NEUTRAL, release+press S -> REVERSE.
        if not dctManual then
            if Config.Gearbox.ReverseGate and Config.Gearbox.ReverseGate.KeyDriven then
                if revGate == 'neutral' then
                    dctNeutral, dctReverse = true, false
                    dctLatchedNeutral = true
                elseif lcPhase == 'staged' then
                    dctNeutral = true             -- launch-fire guard (see legacy note below)
                else
                    -- NO AUTO-SETTLE: S is a PURE BRAKE — braking to a stop STAYS in gear (the box
                    -- does not drop to N on its own). Neutral is reached ONLY by the DOWNSHIFT-key
                    -- TAP (which flips to paddle-manual and walks gear->N->R), matching comfort/EV.
                    -- forward: clear only the CHORD neutral. dctReverse is owned by the paddle
                    -- ladder here (KeyDriven never sets it from a gate), so leave it alone.
                    if dctLatchedNeutral and not dctReverse then
                        dctNeutral, dctLatchedNeutral = false, false
                    end
                end
            else
            local g = updateReverseGate(state)
            if g == 'neutral' then
                dctNeutral, dctReverse = true, false
                dctLatchedNeutral = true          -- hold N until the gate moves us (not auto-engage)
            elseif g == 'reverse' then
                dctNeutral, dctReverse = false, true
                dctLatchedNeutral = false
            elseif lcPhase == 'staged' then
                -- LAUNCH-FIRE GUARD: releasing the handbrake with throttle still floored IS the
                -- launch-fire gesture, and it flips the gate neutral->none on that exact frame.
                -- If we cleared dctNeutral here, the launch block below (gated on dctNeutral) would
                -- be skipped, so launchStageTick never fires the launch and lcPhase strands at
                -- 'staged' (pill stuck red + reduced-ratio never restored = "handling adjusted").
                -- Keep dctNeutral WHILE STAGED so the launch block owns the exit; it clears
                -- dctNeutral + revGate itself on fire (below). This mirrors dctmanual, whose gate
                -- is skipped entirely (so it never had this bug — it fires via the paddle).
                dctNeutral = true
            else -- 'none' = forward: clear gate-driven N/R so the auto box drives normally
                if dctReverse or dctLatchedNeutral then
                    dctReverse, dctNeutral, dctLatchedNeutral = false, false, false
                end
            end
            end
        end

        -- AUTO sub-mode: the script picks gears (genuine automatic). Suppressed
        -- while in neutral (a fresh-start auto DCT sits in N until the player
        -- gives input — throttle press, paddle, etc. — which re-engages a safe gear).
        -- ANTI-HUNT DWELL (dctAutoNextOk): after any auto shift, wait AutoDwellMs
        -- before the next. Without it the auto re-fired a shift every tick before the
        -- previous shift's RPM drop landed -> a 1->2->3 'skip' flash. Real TCUs have
        -- exactly this hysteresis; one gear at a time, then a beat to let revs settle.
        if not dctManual and not dctNeutral and not shiftWindowOpen
           and dctOverrevUntil == 0 and now >= dctAutoNextOk then
            local thr = state.throttle or 0.0
            -- Upshift RPM threshold for a GIVEN gear g (the rpm at which g shifts to
            -- g+1). FACTORED OUT so the auto-upshift decision AND the downshift bounce-
            -- guard read the SAME per-gear value. Critical under LadderUpBias (HYPERCAR):
            -- each gear has a DIFFERENT shift point, so the guard MUST test the TARGET
            -- (lower) gear's own (lower) point. The old guard tested the CURRENT gear's
            -- HIGHER point, under-protecting so the box hunted 1<->2 (the "bog twice
            -- before 2nd": gear 1 short-shifted to 2, gear-2 rpm landed under kickdown,
            -- kickdown dropped back to 1, and the guard missed because gear 1's point <
            -- gear 2's point). Mirrors the old inline math: throttle base -> UpshiftRpmMult
            -- (flat) -> LadderUpBias (per-gear ramp) -> final-gear relaxation -> clamps.
            local function upshiftRpmFor(g)
                local cap = (cfg.RevLimiterRedline or 0.985) - 0.005
                local up  = (thr > 0.85) and (P.AutoUpRpmWOT or 0.92) or (P.AutoUpRpm or 0.78)
                -- GEAR-RATIO: hold gears later (>1, sport/hyper) or short-shift (<1, drag).
                if gbRatio and gbRatio.UpshiftRpmMult and gbRatio.UpshiftRpmMult ~= 1.0 then
                    up = up * gbRatio.UpshiftRpmMult
                    if up > cap then up = cap end
                end
                -- LADDER BIAS (hypercar "ratios scale up the ladder"): per-gear additive
                -- shift point. Gear 1 short-shifts (-bias), ramping linearly to +bias by
                -- the top gear, so low gears are short/hard and high gears hold longer.
                if gbRatio and (gbRatio.LadderUpBias or 0) ~= 0 and gearcount and gearcount > 1 then
                    local frac = (g - 1) / (gearcount - 1)             -- 0 at g1 .. 1 at top
                    up = up + gbRatio.LadderUpBias * (2.0 * frac - 1.0) -- -bias .. +bias
                    if up > cap then up = cap end
                    if up < 0.30 then up = 0.30 end                    -- never absurdly early
                end
                -- FINAL-GEAR RELAXATION: when g+1 IS the top gear, ignore the hold-longer
                -- mult and use the stock up-point so the top gear always engages cleanly
                -- (a high mult could pin the last upshift against the limiter -> stuck one
                -- gear short).
                if (g + 1) >= gearcount then
                    up = (thr > 0.85) and (P.AutoUpRpmWOT or 0.92) or (P.AutoUpRpm or 0.78)
                end
                return up
            end
            local upRpm = upshiftRpmFor(dctGear)
            -- DOWNSHIFT THRESHOLD for the CURRENT throttle (gear-independent — depends only on
            -- pedal + ratio mode). FACTORED OUT so the UPSHIFT guard and the downshift decision read
            -- the SAME value. Without this the upshift had no symmetric bounce guard: at WOT the
            -- upshift floor was AutoDownRpm(0.30) but the progressive downshift threshold is
            -- kickRpm(0.55), so a gear entered in the [0.30,0.55] dead band upshifted, then instantly
            -- kicked back down = 2<->3 hunt that never reached 4. Mirrors the math in the downshift
            -- branch below (keep the two in sync).
            local function downThresholdFor(thrV)
                local downRpm = P.AutoDownRpm or 0.30
                local kickRpm = P.AutoKickdownRpm or 0.55
                if gbRatio and gbRatio.DownshiftRpmMult and gbRatio.DownshiftRpmMult ~= 1.0 then
                    downRpm = downRpm * gbRatio.DownshiftRpmMult
                    kickRpm = kickRpm * gbRatio.DownshiftRpmMult
                end
                local loT = Config.Gearbox.DownProgLo or 0.15
                local hiT = Config.Gearbox.DownProgHi or 0.90
                local t = downRpm
                if thrV > loT and kickRpm > downRpm then
                    local band = hiT - loT
                    local f = (band > 0) and ((thrV - loT) / band) or 1.0
                    if f > 1.0 then f = 1.0 end
                    t = downRpm + (kickRpm - downRpm) * f
                end
                return t
            end
            -- GUARD against the handbrake/skid runaway: when the wheels are locked
            -- (handbrake) or the car is barely moving, engine rpm decouples from
            -- ROAD speed and pins high — without this the box would upshift every
            -- window (1->...->8) then cascade back down. Only upshift if the car is
            -- genuinely rolling AND the NEXT gear would still rev above an idle
            -- floor at the current speed (projected from learned ratio). At a
            -- standstill that projection is ~0, so the climb can't happen.
            -- FREE DRIFT EXCEPTION: in free drift mode the handbrake is used to ROTATE, not
            -- stop, so the engine should rev + upshift normally. Bypass the handbrake block.
            local hbBlocksUpshift = state.handbrake and not HK.freeDriftActive
            local moving   = (state.speedKmh or 0) > 5.0 and not hbBlocksUpshift
            -- AIRBORNE UPSHIFT BLOCK (2026-08-14 — user-reported "+1 gear on landing off a ramp").
            -- While airborne the driven wheels free-spin (no road load), so GetVehicleCurrentRpm
            -- climbs to the limiter and 'atLimiter' goes true — which BYPASSES nextOk + rpmGrounded
            -- (both intended to hold the gear on a spin) and fires a phantom upshift right around
            -- touchdown => you land one gear too tall. Suspend the auto UPSHIFT while not on all
            -- wheels, AND for a short settle window after landing (the free-spun rpm is stale for a
            -- few frames until the tyres regrip and rpm falls back to road speed). Downshifts are
            -- left alone (landing into a lower gear is fine + rare). Mirrors the rev-limiter's own
            -- airborne suspend (RevLimiterGroundOnly) + the drivetrain LandSettle windows.
            -- WHEELIE EXCEPTION (2026-08-14): a launch WHEELIE lifts the FRONT wheels, so onAllWheels
            -- goes false even though the car is NOT airborne (rear planted, driving hard). Treating that
            -- as "airborne" blocked the auto-upshift during the wheelie → the box held 1st and the car
            -- couldn't accelerate away. A GENUINE jump sets IsEntityInAir (whole car off ground); a wheelie
            -- does not. So only count it as air when the car is truly airborne AND not mid-wheelie. This
            -- mirrors main.lua's airborne-force-cutoff, which uses IsEntityInAir for the same reason.
            local trulyAirborne = (state.onAllWheels == false)
                and not (HK.wheelieActive == true)
                and IsEntityInAir(veh)
            if trulyAirborne then
                HK.gbAirSettleUntil = now + (Config.Gearbox.AirLandSettleMs or 260)
            end
            -- WHEELIE LANDING-SETTLE (2026-08-14, user: "auto upshift only when hitting the ground ~120ms
            -- later"). The old design UPSHIFTED during the wheelie — wrong. Now HK.wheelieHoldGear blocks
            -- the upshift the whole time the FRONT wheels are off (set in wheelie.lua on the real wheel
            -- state), and wheelie.lua stamps HK.wheelieUpshiftLandUntil when they touch back down so the
            -- box waits UpshiftLandMs more before grabbing the next gear (a real car settles, then shifts).
            local wheelieLandBlocked = (now < (HK.wheelieUpshiftLandUntil or 0))
            local airUpBlocked = trulyAirborne or (now < HK.gbAirSettleUntil) or wheelieLandBlocked
            local nextProj = projectGearRpm(dctGear + 1)
            -- UPSHIFT BOUNCE GUARD: the next gear must land clearly ABOVE the downshift threshold
            -- for the current throttle, or the box would upshift then instantly kick back down (the
            -- 2<->3 hunt "can't reach 4" the progressive downshift reintroduced). Use the SAME
            -- threshold fn as the downshift + a small margin so the two decisions can't overlap.
            -- Skip this at/above the top gear's own up-point handoff (final gear ignores hold-mult).
            -- nil projection (unlearned gear) => allow, so a cold gear can't get stuck one short.
            local dsThr    = downThresholdFor(thr)
            -- LIMITER OVERRIDE: if the current gear is pinned at/near the rev limiter, ALWAYS allow
            -- the upshift even if the next gear would land in the kickdown zone — sitting on the
            -- limiter is worse than a briefly-low next gear, and a real TCU always shifts up off the
            -- limiter. This prevents the guard from creating a NEW "stuck at limiter in gear N" on
            -- wide-ratio cars whose next gear lands below the (high, at-WOT) kickdown threshold.
            local atLimiter = state.rpm >= ((P.OverrevRpm or 0.97) - 0.01)
            -- GEARBOX-LIMITER PIN (2026-08-14 — the "infamous bop-back / won't-upshift" root fix):
            -- applyRevLimiter engages on rpm redline OR a learned SPEED CAP (redline/rps). On cars whose
            -- learned/seeded gbRpmPerSpeed ratio doesn't match GTA's ACTUAL reported rpm (modded cars +
            -- some vanilla), the SPEED-CAP path pins the limiter (cutting throttle+torque) while state.rpm
            -- reads BELOW upRpm — so the primary rpm trip (state.rpm>=upRpm) never fires and the box sits
            -- stuck ON the limiter. gbLimiterOn (set by applyRevLimiter) is the ground truth that we ARE
            -- pinned, by EITHER path. It relaxes ONLY the primary rpm trip below — NOT nextOk/rpmGrounded,
            -- which read the PROJECTED rpm (from the same ratio table) and so are already self-consistently
            -- satisfied when genuinely at the cap; leaving them active is what stops the pinned bypass from
            -- CASCADING into a 2-gear jump (a broken next-gear landing still gets blocked).
            -- TWO guards make this safe:
            --   (1) gbLimiterOn is read ~1 frame STALE (applyRevLimiter runs later this tick), so on a
            --       throttle LIFT the limiter releases this frame but the flag still reads true → would
            --       force a phantom upshift right as you lift (the OFF-mode "lift at the right timing"
            --       false trigger). Re-gate on CURRENT throttle >= the limiter's own MinThrottle so a lift
            --       instantly disqualifies, exactly mirroring applyRevLimiter's gate.
            -- pinned relaxes the rpm trip ONLY for the pure SPEED-CAP pin (gbLimiterByCap): that's the sole
            -- case where rpm sits below upRpm yet the limiter cuts. The rpm-redline path is EXCLUDED — there
            -- rpm is already >= redline > upRpm so the normal trip fires on its own, and forcing it via
            -- 'pinned' was double-firing into a 2-gear jump on cars that worked fine. Also require CURRENT
            -- throttle >= the limiter's own MinThrottle so a lift (which releases the limiter THIS frame,
            -- while the ~1-frame-stale flag still reads true) can't fire a phantom shift as you lift off.
            local limThr   = Config.Gearbox.RevLimiterMinThrottle or 0.5
            -- BRAKE PRIORITY (2026-08-14): while braking at the limiter, do NOT let the speed-cap pin
            -- force an upshift. Shifting into a taller gear raises the speed cap, so the limiter releases
            -- in the new gear and the car ACCELERATES through the old cap (the "brake makes it speed up /
            -- goes through the limiter" bug). Holding the gear lets the torque cut + brakes actually slow
            -- it. Only suppresses the CAP-pinned trip; a genuine rpm>=upRpm redline shift still fires.
            local pinned   = atLimiter or (HK.gbLimiterByCap == true and (state.throttle or 0) >= limThr
                                           and HK.limiterBraking ~= true)
            local nextOk   = (nextProj == nil) or atLimiter or (nextProj > dsThr + 0.06)
            -- WHEELSPIN GUARD (the cornering "bog at end of gear" fix): GTA fakes an
            -- open diff, so in a turn the unloaded inside driven wheel spins up and
            -- GetVehicleCurrentRpm follows it — engine rpm SPIKES past the upshift point
            -- while real ROAD speed lags. That fired a premature 1->2 upshift into a gear
            -- too tall for the actual speed = a bog (worst on basic DCT, whose 0.80
            -- part-throttle up-point is easiest for a spike to clear). Ground-truth it:
            -- only upshift if the CURRENT gear's ROAD-SPEED projection is also near the
            -- up-point. A spike with road speed still mid-gear -> curProj < upRpm -> blocked
            -- (engine just revs out the inside wheel; the upshift fires for real once the
            -- car straightens and road speed catches up). nil projection (unlearned) =>
            -- allow, so a cold gear can't get stuck. Tolerance absorbs ratio-estimate noise.
            local curProj    = projectGearRpm(dctGear)
            -- LIMITER BYPASS for rpmGrounded: the wheelspin guard was designed for cornering
            -- spin-up where road speed is FLAT while rpm spikes — in that case curProj is low
            -- and blocking the shift is correct. BUT under hard WOT acceleration the engine
            -- drives rpm ahead of road speed legitimately; if we're pinned AT the rev limiter
            -- that is definitively NOT a transient spike, and the wheelspin guard must not
            -- block the shift (it caused the "stuck near redline / bop back" bug: limiter kills
            -- throttle -> rpm drops below upRpm -> upshift condition also fails -> throttle
            -- returns -> same block -> endless flutter). atLimiter already overrides nextOk
            -- (line above); mirror it here so both guards are bypassed at the limiter.
            local rpmGrounded = (curProj == nil) or atLimiter or (curProj >= upRpm - 0.10)
            -- PRIMARY UPSHIFT: normally rpm must reach upRpm — BUT if the gearbox limiter is pinned
            -- (speed-cap path can cut torque so rpm never climbs to upRpm), 'pinned' satisfies the trip.
            -- 'pinned' relaxes ONLY this rpm trip; nextOk + rpmGrounded stay on their projected-rpm tests
            -- (2) so the NEXT gear must still land somewhere sane — that's the anti-cascade guard: after a
            -- pinned upshift, if the new gear would ALSO immediately be over its cap the projection blocks
            -- the follow-on shift, so it can't leap two gears. Still gated on 'moving'.
            -- LIFT-OFF COAST-UP GATE (2026-08-14 — the "4->6->7 on lift, snaps back on throttle"
            -- fix). When coasting (throttle below CoastLiftThr) the engine can still sit above
            -- upRpm in the CURRENT gear, so the box upshifts — and since nextOk evaluates the
            -- target at the ~0 CURRENT throttle (downshift threshold collapses to the idle floor),
            -- almost any gear passes => a multi-gear cascade that kicks straight back down the
            -- instant you squeeze the pedal (the target gear can't hold rpm under power). Two
            -- guards, coast-only (on-throttle behavior is UNCHANGED):
            --   (a) RESUME TEST: the target gear's projected rpm must clear the downshift
            --       threshold at a RESUME throttle (CoastResumeThr), not the current ~0 — i.e.
            --       "could I hold this gear when I get back on the power?". Blocks the overshoot.
            --   (b) STEP CAP: at most CoastUpMaxStep gears per lift (TC=1 gentle economy up-shift;
            --       DCT tiers 4/5 = CoastUpMaxStepDct, default 0 => HOLD the gear on lift for
            --       engine-braking, the sportier dual-clutch feel). Resets when back on throttle.
            local coasting  = (state.throttle or 0.0) < (Config.Gearbox.CoastLiftThr or 0.12)
            if not coasting then HK.coastUpSteps = 0 end          -- on power: clear the lift counter
            local coastAllowsUp = true
            if coasting then
                local maxStep = (gearMode >= 4) and (Config.Gearbox.CoastUpMaxStepDct or 0)
                                                 or (Config.Gearbox.CoastUpMaxStep or 1)
                if HK.coastUpSteps >= maxStep then
                    coastAllowsUp = false                          -- (b) already climbed the allowed gears
                else
                    -- (a) resume test: would the TARGET gear hold above its downshift threshold
                    -- when the driver gets back on the power? Uses the RESUME throttle, not ~0.
                    local resumeThr = Config.Gearbox.CoastResumeThr or 0.55
                    local tgtProj   = projectGearRpm(dctGear + 1)
                    if tgtProj and tgtProj < (downThresholdFor(resumeThr) + 0.02) then
                        coastAllowsUp = false                      -- too tall to hold on resume -> don't grab it
                    end
                end
            end
            -- DIAGNOSTIC: stash the upshift-decision terms so /gbwhy can name which one blocks a
            -- stuck-at-redline shift (the "won't upshift until I lift+reapply throttle" bug).
            HK.dbgUp = HK.dbgUp or {}
            HK.dbgUp.gear=dctGear; HK.dbgUp.gearcount=gearcount; HK.dbgUp.rpm=state.rpm
            HK.dbgUp.upRpm=upRpm; HK.dbgUp.pinned=pinned; HK.dbgUp.moving=moving
            HK.dbgUp.nextOk=nextOk; HK.dbgUp.rpmGrounded=rpmGrounded
            HK.dbgUp.coastAllowsUp=coastAllowsUp; HK.dbgUp.airUpBlocked=airUpBlocked
            HK.dbgUp.nextProj=nextProj; HK.dbgUp.curProj=curProj; HK.dbgUp.dsThr=dsThr
            HK.dbgUp.atLimiter=atLimiter; HK.dbgUp.at=now
            -- STALL-TIMEOUT UPSHIFT (2026-08-16 — the "hangs a few seconds in gears 5-8 before it'll
            -- shift" fix, confirmed live on the chipped 911ts: rpm=0.89 sat under upRpm=0.97 at WOT for
            -- seconds because the pull flattens near the top of a tall gear, so rpm crawls that last 7%
            -- painfully slowly and the pure rpm>=upRpm trip never fires). A real DCT never sits pinned
            -- mid-gear: if you're on the power (WOT), NOT the top gear, high in the band (near upRpm),
            -- and rpm has effectively STOPPED climbing for StallUpMs, take the shift. Gated tight so it
            -- can't fire on a normal quick pull (rpm reaches upRpm first) or at part-throttle (lugging
            -- is the downshift's job). nextOk/rpmGrounded still apply below = anti-cascade preserved.
            local stallUp = false
            local suCfg = Config.Gearbox.StallUpMs
            if suCfg and suCfg > 0 and dctGear < gearcount and moving
               and thr >= (Config.Gearbox.StallUpThr or 0.85)
               and state.rpm >= (upRpm - (Config.Gearbox.StallUpRpmBand or 0.10)) then
                -- track whether rpm is climbing; reset the timer whenever it makes real progress
                local climbed = (HK.stallUpLastRpm == nil) or (state.rpm > HK.stallUpLastRpm + 0.004)
                if climbed or HK.stallUpGear ~= dctGear then
                    HK.stallUpSince = now
                    HK.stallUpGear  = dctGear
                end
                HK.stallUpLastRpm = state.rpm
                if HK.stallUpSince and (now - HK.stallUpSince) >= suCfg then
                    stallUp = true
                end
            else
                HK.stallUpSince, HK.stallUpLastRpm = nil, nil
            end
            HK.dbgUp.stallUp = stallUp
            -- DRIFT GEAR CEILING (symptom #5, reworked): while drifting grounded +
            -- coupled, drift.lua sets HK.driftHoldGear — the box must NOT auto-upshift
            -- (an upshift drops rpm → drops torque → kills the slide and just gains
            -- speed). Blocking upshift here holds the gear so a low-gear pull keeps
            -- physics rpm + torque HIGH (fries the tyres, slides the car) AND naturally
            -- caps top speed at the held gear's redline. Downshift still runs below
            -- (slowing / braking into a corner). drift.lua clears the flag on exit.
            -- WHEELIE GEAR HOLD (2026-08-14 reramp): while the nose is genuinely up wheelie.lua pins
            -- the needle to redline ("MAX RPM WHEN LIFTED UP") and sets HK.wheelieHoldGear — block the
            -- auto-upshift here too so that painted rpm can't trip a phantom shift (the Chiron feedback
            -- trap), exactly like the drift ceiling. Downshift still runs. Cleared the instant the nose drops.
            if dctGear < gearcount and (state.rpm >= upRpm or pinned or stallUp) and moving and nextOk and rpmGrounded and coastAllowsUp and not airUpBlocked and not HK.driftHoldGear and not HK.wheelieHoldGear then
                requestGear(dctGear + 1)
                if coasting then HK.coastUpSteps = HK.coastUpSteps + 1 end
                dctAutoNextOk = now + (P.AutoDwellMs or 250)
                if HK.hdbgOn and HK.dbgGear then HK.dbgGear.coastUp = coasting end
            -- Downshift: rpm fell below the keep-alive point, or kickdown demand.
            elseif dctGear >= 2 then
                -- PROGRESSIVE DOWNSHIFT (real-auto feel, e.g. a 488 in D: the more pedal you ask
                -- for at a given speed, the higher the rpm at which it drops a gear). Replaces the
                -- old BINARY thr>0.9 kickdown (which never downshifted at part-throttle -> lugging in
                -- a tall gear on a 40-70% overtake). Threshold scales with throttle from the
                -- keep-alive floor (~idle) at light pedal to full kickdown rpm at WOT — computed by
                -- downThresholdFor (shared with the upshift bounce guard so the two can't overlap).
                local dsThreshold = downThresholdFor(thr)
                -- COAST DOWNSHIFT CHARACTER: while COASTING (zero/near-zero throttle) a TC auto and
                -- a DCT behave differently — TC holds the tall gear (lazy, glides), DCT drops sooner
                -- (eager, engine braking). Bias the coast downshift threshold by type: mode 3 (TC/
                -- Automatic Paddle) uses CoastDownBiasTc (negative = drop LATER); modes 4/5 (DCT) use
                -- CoastDownBiasDct (positive = drop SOONER, higher rpm). Only applied on a genuine
                -- coast; on-throttle behavior (kickdown) is UNCHANGED. Clamped so it can't invert.
                -- BRAKE-BASED DOWNSHIFT (2026-08-14): real autos/DCTs drop gears on the FOOT BRAKE
                -- for engine braking + a ready-to-launch gear. RAISE the downshift threshold with
                -- brake pressure (drop earlier the harder you brake), scaling from BrakeDownGate to
                -- full brake. TC gentle, DCT aggressive. NOT the handbrake (a real e-brake is
                -- decoupled from the box — commands no shift). This BEATS the coast bias when both
                -- apply (you can lift AND brake): braking is the stronger intent, so take the max
                -- upward push. Off-throttle only; on-throttle keeps the pure kickdown map above.
                local brakeAmt = (not state.handbrake) and (state.brake or 0.0) or 0.0
                local bdGate   = Config.Gearbox.BrakeDownGate or 0.15
                local brakeBias = 0.0
                if brakeAmt > bdGate then
                    local bf = (brakeAmt - bdGate) / (1.0 - bdGate)   -- 0 at gate -> 1 at full brake
                    if bf > 1.0 then bf = 1.0 end
                    local bMax = (gearMode >= 4) and (Config.Gearbox.BrakeDownBiasDct or 0.0)
                                                   or (Config.Gearbox.BrakeDownBiasTc or 0.0)
                    brakeBias = bMax * bf
                end
                local coastBias = 0.0
                if coasting then
                    coastBias = (gearMode >= 4) and (Config.Gearbox.CoastDownBiasDct or 0.0)
                                                 or (Config.Gearbox.CoastDownBiasTc or 0.0)
                end
                -- brake push wins over coast (max of the two upward biases; coast can be negative/lazy
                -- which we keep only when NOT braking). Braking never makes the box LAZIER.
                local bias = (brakeBias > 0.0) and (brakeBias > coastBias and brakeBias or coastBias) or coastBias
                if coasting or brakeBias > 0.0 then
                    dsThreshold = dsThreshold + bias
                    if dsThreshold < 0.05 then dsThreshold = 0.05 end
                    if dsThreshold > 0.90 then dsThreshold = 0.90 end
                    if HK.hdbgOn and HK.dbgGear then
                        HK.dbgGear.coastDownThr  = dsThreshold
                        HK.dbgGear.coastDownBias = coastBias
                        HK.dbgGear.brakeDownBias = brakeBias
                    end
                end
                if state.rpm < dsThreshold then
                    -- Stamp that the box WANTS a downshift this frame — the tip-in bog detector below
                    -- only arms while this is fresh, so an UPSHIFT-region rpm oscillation (limiter bounce
                    -- near an up-point) can't misfire the throttle lift. If the drop actually FIRES, the
                    -- gear changes and the detector resets anyway; a blocked drop is the true bog.
                    HK.dctDownWantAt = now
                    local newTg = dctGear - 1
                    local proj  = projectGearRpm(newTg)
                    -- BOUNCE GUARD: never drop into a gear whose revs at this speed would
                    -- already be AT/ABOVE THAT gear's OWN upshift point — it would re-upshift
                    -- next tick, so the box just hunts (1<->2 "stuck in 2" / "bog before 2nd").
                    -- Surfaces with short-shifting ratio modes (DRAG/HYPER short upRpm +
                    -- kickRpm bumped by DownshiftRpmMult) where gear N+1 is entered low; ratio
                    -- [0]'s high upRpm never trips it. MUST use the TARGET gear's threshold,
                    -- not the current gear's — under LadderUpBias they differ per gear, and
                    -- testing the current (higher) gear's point let the kickdown bounce through.
                    --
                    -- HYSTERESIS MARGIN: block the drop if the target gear would land AT/NEAR its
                    -- own upshift point — not just at/above it. The old guard used a ZERO-margin
                    -- test (proj >= upFor), so a target landing just BELOW (e.g. proj 0.86 vs
                    -- upFor 0.90) passed... then at WOT the rpm closed that 0.04 gap in a blink and
                    -- re-upshifted = the ~190-210 km/h 2<->3 "bop" hunt. Mirror the margin the
                    -- UPSHIFT guard already carries (nextProj > dsThr + 0.06): require the target
                    -- to sit a clear DownBounceMargin below its up-point, so a dropped gear has
                    -- real room to pull before it reaches the next upshift. Wide-ladder hypercars
                    -- (LadderUpBias) enter the next gear low, so this margin is what stops the hunt.
                    -- TIP-IN BOUNCE (2026-08-16 — the "coast to just-above-drop-rpm then throttle =
                    -- bog/bop stuck, but wait for rpm to fall a touch more and it drops clean" bug).
                    -- ON A THROTTLE TIP-IN the progressive threshold JUMPS up (light->part pedal moves
                    -- dsThreshold from ~idle floor toward kickdown), so a coasting rpm sitting just above
                    -- the old floor is suddenly BELOW the new threshold and fires a downshift. But under
                    -- that fresh throttle the engine rpm CLIMBS fast, so if the target gear lands even
                    -- moderately below its own up-point, rpm closes the gap in a blink and re-upshifts =
                    -- the bop-bog-bop hunt that settles back in the SAME gear. The base DownBounceMargin
                    -- (0.10) is tuned for the steady-state/coast drop; a tip-in needs a WIDER guard so a
                    -- marginal target is HELD (gear N just pulls up smoothly) instead of hunting. Detect
                    -- the tip-in = NOT coasting (throttle above CoastLiftThr) AND light-to-moderate pedal
                    -- (a genuine kickdown at heavy pedal SHOULD drop — you want the lower gear). Below
                    -- TipInThrMax we treat it as a lazy tip-in and demand the bigger margin.
                    -- TIP-IN MARGIN (2026-08-16 REWORK — the earlier WIDER-margin attempt was BACKWARDS
                    -- and CAUSED the bog). On a lazy tip-in the driver has asked to drop a gear at low
                    -- rpm; blocking that drop just lugs the tall gear = the "stuck in 4, bogs, then 3 then
                    -- 4" hunt. So on a tip-in we want to be EAGER to drop: use a NARROW margin (replace,
                    -- not max) so a marginal target still drops. A runaway hunt is already prevented by
                    -- (a) the hard over-rev guard below (proj <= OverrevRpm 0.97 — never drop into a gear
                    -- that would bang the limiter) and (b) the post-downshift dwell (dctAutoNextOk =
                    -- AutoDwellMs) which holds the new gear long enough for road speed to rise, so the
                    -- follow-up 3->4 is a clean natural upshift, not an instant bop. A HEAVY pedal
                    -- (>= TipInThrMax) is a real kickdown and keeps the base margin.
                    local bounceMargin = Config.Gearbox.DownBounceMargin or 0.10
                    if not coasting and thr < (Config.Gearbox.TipInThrMax or 0.80) then
                        bounceMargin = Config.Gearbox.TipInBounceMargin or 0.04   -- NARROW: allow the drop
                    end
                    local wouldBounce = proj and (proj >= upshiftRpmFor(newTg) - bounceMargin)
                    if (not proj or proj <= (P.OverrevRpm or 0.97)) and not wouldBounce then
                        requestGear(newTg)
                        -- RACE MULTI-DOWNSHIFT (DCT tiers 4/5): under HARD braking a race DCT
                        -- rips down through gears in rapid succession (PDK bam-bam-bam) instead
                        -- of pausing the full anti-hunt dwell between each. When braking hard,
                        -- collapse the dwell to P.MultiDownDwellMs so the NEXT auto-downshift can
                        -- fire almost immediately, cascading down the box as the car scrubs speed.
                        -- Gated on gearMode >= 4 (DCT only) so mode 3/2 keep their calm dwell; the
                        -- per-gear bounce/over-rev guards above still vet every step, so it can only
                        -- cascade through LEGAL gears (no runaway). Rev-bark makes each one crack.
                        local dwell = P.AutoDwellMs or 250
                        if gearMode >= 4 and P.MultiDownDwellMs and (state.brake or 0) > 0.6 then
                            dwell = P.MultiDownDwellMs
                            if HK.hdbgOn and HK.dbgGear then HK.dbgGear.multiDown = true end
                        elseif HK.hdbgOn and HK.dbgGear then
                            HK.dbgGear.multiDown = false
                        end
                        dctAutoNextOk = now + dwell
                    end
                end
            end
        end

        ------------------------------------------------------------------
        -- NEUTRAL (DCT): no drive, engine free-revs. Skip the shift window and the
        -- keep-alive pin entirely while neutral. AUTO sub-mode stays in neutral on
        -- entry until the driver presses the HANDBRAKE (like releasing park) — then
        -- it engages the safe speed-matched gear and normal auto driving resumes.
        -- PADDLE sub-mode waits for a paddle instead.
        ------------------------------------------------------------------
        -- LAUNCH CONTROL (DCT-auto). v6: LC stages from neutral but IMMEDIATELY engages a REAL gear 1
        -- (lcEngageGear1 — clears dctNeutral, commits dctCommittedGear=1) so the speedo reads a genuine
        -- 1 while staged. Handbrake release -> LAUNCH. Bail leaves the box IN GEAR 1 (never back to N).
        -- GATE widened to lcPhase active so the tick keeps running after the auto-upshift clears dctNeutral.
        if (dctNeutral or lcPhase ~= 'off') and not dctPendingGear and not dctManual then
            local lc = launchStageTick(veh, state, dt)
            if lc == 'staged' then
                -- lcEngageGear1 already put us in REAL gear 1 + drive force live (the handbrake holds
                -- the car; the engine builds REAL loaded revs against gear 1). Just restore reduced-ratio
                -- if it was off in neutral, then sit staged. launchStageTick holds the rev cap.
                if HK.dctNeutralRatioOff then
                    if not isEasy() then vl_setTransmissionReducedGearRatio(veh, true) end
                    HK.dctNeutralRatioOff = false
                end
                return                                   -- sit staged; skip throttle-re-engage
            elseif lc == 'launch' then
                dctNeutral, dctNeutralHold, dctLatchedNeutral = false, false, false
                revGate = 'none'
                if HK.dctNeutralRatioOff then                 -- restore reduced-ratio (was off in neutral)
                    if not isEasy() then vl_setTransmissionReducedGearRatio(veh, true) end
                    HK.dctNeutralRatioOff = false
                end
                -- ENGAGE GEAR 1 INSTANTLY — do NOT use requestGear() here. requestGear opens a
                -- DCT shift WINDOW (dctPendingGear + dctShiftEndAt), and the shift-window block
                -- below cuts HK.torqueMult to 0 ("coast through the shift") for that window — a
                -- dead spot at the exact launch instant that made LC SLOWER than a plain manual
                -- gear-1 handbrake launch. A standstill launch wants drive dumped immediately, no
                -- rev-match/coast. Set the gear directly + restore drive so power hits at once.
                dctGear, dctCommittedGear, dctPendingGear = 1, 1, nil
                dctShiftEndAt, dctShiftDipUntil = 0, 0
                if vl_getCurrentGear(veh) ~= 1 then vl_setCurrentGear(veh, 1) end
                if origins and origins.fInitialDriveForce then
                    setDriveForce(veh, gbDriveForceLive or origins.fInitialDriveForce)
                end
                -- fall through: gear 1 engaged, drive live; launchBoostApply runs on drive frames.
            end
        end

        if dctNeutral and not dctPendingGear then
            -- Throttle re-engages a gear ONLY from the transient fresh-start neutral — NOT from
            -- the deliberate double-tap LATCHED neutral (that STAYS until a paddle/shift; throttle
            -- there just revs the engine, like sitting in neutral in a real car).
            if not dctManual and not dctLatchedNeutral
               and not hbHeld(state, veh)                 -- HANDBRAKE HELD = stay in neutral (launch staging / holding)
               and (state.throttle or 0.0) > (cfg.DctReleaseThrottle or 0.15) then
                -- Auto DCT: pressing the GAS disengages the park-neutral -> engage a safe gear.
                dctNeutral = false
                dctNeutralHold = false
                if HK.dctNeutralRatioOff then                 -- restore reduced-ratio for gear management
                    if not isEasy() then vl_setTransmissionReducedGearRatio(veh, true) end
                    HK.dctNeutralRatioOff = false
                end
                local g = bestGearForSpeed() or 1
                -- LOW-SPEED FLOOR (the "starts at 7th" bug, g632019): leaving park-neutral at a
                -- standstill the engine is FREE-REVVING (neutral blip), so bestGearForSpeed scales
                -- that high rpm across the ratios and picks a TALL gear to bring rpm to target =
                -- 7th from a dead stop. A creeping/standing start can only be 1st. Same DOWN-only
                -- floor the DCT init uses (DctInitSlowKmh, default 30). Never invents a taller gear.
                if (state.speedKmh or 0.0) < (cfg.DctInitSlowKmh or 30.0) and g > 1 then g = 1 end
                dctGear, dctCommittedGear = g, g
                requestGear(g)
            else
                HK.torqueMult = 0.0
                if origins and origins.fInitialDriveForce then setDriveForce(veh, 0.0) end
                if vl_getCurrentGear(veh) ~= 0 then vl_setCurrentGear(veh, 0) end
                -- S IS A PURE BRAKE in DCT-auto neutral too: native gear 0 makes control 72 (S) the
                -- reverse-accelerator, so a held S would crawl the car backward / rev it. Kill 72 at a
                -- standstill (KeyDriven), same guard the manual neutral uses. rpm is painted below.
                if Config.Gearbox.ReverseGate and Config.Gearbox.ReverseGate.KeyDriven then
                    HK.autoStandstillBrake(veh, state)
                end
                -- SAFETY BACKSTOP against the "EV single-gear ramp" bug: while genuinely sitting
                -- in DCT free-rev neutral, turn reduced-gear-ratio OFF once. If anything jams the
                -- neutral exit, GTA's OWN auto box then drives as a safe fallback instead of the
                -- script's single tall reduced ratio ramping RPM up forever with no gear limit
                -- (which is what "normal car behaves like a 1-gear EV" was). Re-enabled the frame
                -- a gear re-engages (throttle-exit above, or launch). One-shot via dctNeutralRatioOff.
                if not HK.dctNeutralRatioOff then
                    vl_setTransmissionReducedGearRatio(veh, false)
                    HK.dctNeutralRatioOff = true
                end
                -- NEUTRAL rev-feed via the FLYWHEEL integrator: blip up + rev-hang decay down, both
                -- mass-scaled. Use state.throttle (the W INPUT), NOT GetVehicleThrottleOffset — the
                -- latter reads ~0 in neutral (engine unloaded) so revs never climbed. A DCT's ECU still
                -- spins the same physical flywheel, so the mass feel applies; the FlyDctRateMult knob
                -- lets the DCT sit a touch tighter than the raw manual blip if desired (default 1.0).
                local t = state.throttle or 0.0
                -- STATIONARY -> free-rev to redline (show off). MOVING -> capped
                -- (can't rev to max while coasting in neutral).
                local revMax = (Config.Gearbox.NeutralRevMax or 1.0)
                if (state.speedKmh or 0) > (Config.Gearbox.NeutralRevCapKmh or 5.0) then
                    revMax = Config.Gearbox.NeutralRevMaxMoving or 0.55
                end
                local idle   = Config.Gearbox.Flywheel and Config.Gearbox.Flywheel.IdleRpm or 0.20
                local target = idle + (revMax - idle) * t
                if target < idle then target = idle end
                local nr = HK.flywheelRev(state.rpm, target, dt, Config.Gearbox.Flywheel and Config.Gearbox.Flywheel.NeutralDownRatio)
                vl_setRpmRaw(veh, nr)
                return
            end
        end

        ------------------------------------------------------------------
        -- REVERSE (DCT paddle): native gear 0 with drive RESTORED so the car
        -- actually backs up. Reverse input arbitration (same as manual): block
        -- forward throttle until rolling backward, so brake/S drives reverse. This
        -- is what stops the old N->R->1 flicker — we no longer force-pin+cut here.
        ------------------------------------------------------------------
        if dctReverse and not dctPendingGear then
            if Config.Gearbox.ReverseGate and Config.Gearbox.ReverseGate.KeyDriven then
                -- KEY-DRIVEN: velocity-driven reverse (W = back, S = brake), same as the manual
                -- box. S is a pure brake — it never selects reverse; the UPSHIFT key leaves R.
                HK.autoReverseDrive(veh, state, dt,
                    gbDriveForceLive or (origins and origins.fInitialDriveForce))
                return
            end
            if origins and origins.fInitialDriveForce then setDriveForce(veh, gbDriveForceLive or origins.fInitialDriveForce) end
            if vl_getCurrentGear(veh) ~= 0 then vl_setCurrentGear(veh, 0) end
            -- Do NOT disable forward throttle when the REVERSE GATE is driving reverse: the gate
            -- reads the W press (state.throttle) to step R->N->D, and DisableControlAction(71)
            -- would zero that read next frame -> stuck in reverse. The gate itself prevents a
            -- forward lurch (it only leaves reverse to NEUTRAL first). Only block throttle for
            -- the legacy non-gate reverse (paddle down-past-1st), where W should be inert.
            local gateDriven = (Config.Gearbox.ReverseGate and Config.Gearbox.ReverseGate.Enabled ~= false)
            if not gateDriven and state.forwardSpeed > -2.0 then
                DisableControlAction(0, 71, true)   -- no forward throttle in R (legacy path)
            end
            return
        end

        -- FORWARD DRIVE (DCT-auto): neutral + reverse both returned above, so we're in a forward
        -- gear now. KEY-DRIVEN: S is a PURE BRAKE — kill native S-reverse at a standstill so a held
        -- S can't make GTA's own auto box drop to native gear 0 -> reverse (the "S still goes to
        -- reverse / gear 1 -> R directly, no N" bug). Reverse is reached ONLY by the DOWN key ladder.
        if Config.Gearbox.ReverseGate and Config.Gearbox.ReverseGate.KeyDriven then
            HK.autoStandstillBrake(veh, state)
        end

        ------------------------------------------------------------------
        -- SHIFT WINDOW: decouple drive + rev-match, commit gear at window end.
        ------------------------------------------------------------------
        if dctPendingGear and now < dctShiftEndAt then
            local isUpshiftNow = dctPendingGear > dctCommittedGear
            -- SEAMLESS TORQUE HANDOFF (DCT tiers 4/5, UPSHIFT only). A real dual-clutch
            -- pre-selects the next gear on the idle clutch, so an upshift is a HANDOFF
            -- between clutches — torque barely drops — not the full disconnect a single-
            -- clutch/TC makes. Instead of zeroing drive we RETAIN a throttle-scaled slice
            -- (clutch stays engaged): near-seamless at WOT, easing to a civil part cut at
            -- light pedal. That retained pull is what makes the DCT genuinely FASTER than
            -- the old full-cut shift (the 200-800ms/pull the user asked for is the sum of
            -- these retained slices across a gear-stack). DOWNSHIFTS still fully decouple
            -- (the rev-match blip needs the engine free to flare). Mode 3 (TC) and mode 2
            -- (comfort) NEVER enter this branch's retain path -> they keep the full cut,
            -- so both perf-neutral tiers are UNCHANGED. Retain is a MULTIPLY into the
            -- torque chain (composes with limiter/TC cuts via min-wins downstream) and we
            -- KEEP drive force live so the coupled clutch actually transmits it.
            local handoff = (gearMode >= 4) and P.HandoffRetain
            if handoff and isUpshiftNow then
                local thr = state.throttle or 0.0
                if thr < 0 then thr = 0 elseif thr > 1 then thr = 1 end
                -- WOT keeps the full HandoffRetain fraction; light pedal eases toward a
                -- gentler ~0.30 floor (still coupled, just softer) so cruising shifts stay
                -- civil. A small gear-ratio nudge: taller current ratio (bigger rpm step to
                -- bridge) keeps a hair more torque so the taller gear doesn't sag on pickup.
                local floorFrac = 0.30
                local retain = floorFrac + (handoff - floorFrac) * thr
                local rn = gbRatio and gbRatio.ShiftTimeMult
                if rn and rn > 1.0 then retain = retain + 0.05 * (rn - 1.0) end  -- lazier ratio -> a touch more
                if retain > handoff then retain = handoff end                    -- never above the WOT cap
                if retain < 0.0 then retain = 0.0 elseif retain > 1.0 then retain = 1.0 end
                HK.torqueMult = HK.torqueMult * retain    -- coupled handoff (NOT a full cut)
                -- drive force stays LIVE (do not zero it) — the engaged clutch transmits it.
                if origins and origins.fInitialDriveForce then
                    setDriveForce(veh, gbDriveForceLive or origins.fInitialDriveForce)
                end
                if HK.hdbgOn and HK.dbgGear then HK.dbgGear.handoffRetain = retain end
            else
                HK.torqueMult = 0.0                       -- coast through the shift (TC / downshift / comfort)
                if origins and origins.fInitialDriveForce then
                    setDriveForce(veh, 0.0)
                end
                if HK.hdbgOn and HK.dbgGear then HK.dbgGear.handoffRetain = 0.0 end
            end
            -- REV-MATCH — ONLY on a downshift (blip revs UP to the lower gear's
            -- higher band). On an UPSHIFT we must NOT feed RPM: the engine should
            -- drop naturally into the taller gear (real DCT/PDK rev-match only on
            -- downshifts; upshifts are just a torque cut). The old code fed toward
            -- projectGearRpm() OR, when that gear was unlearned (gears 4+ usually
            -- are), fell back to getThrottleOffset (~1.0 at WOT) — which PINNED rpm
            -- near redline on EVERY upshift. The auto-shift logic then read that
            -- pinned rpm and upshifted again instantly -> the 3->top gear runaway,
            -- and the inflated rpm also made downshift-protection reject legal
            -- downshifts. Gate the feed to downshifts + learned ratios only.
            local isDownshift = dctPendingGear < dctCommittedGear
            if isDownshift then
                local target = projectGearRpm(dctPendingGear)   -- learned ratio only; nil = skip
                if target then
                    -- BLIP OVERSHOOT: a real rev-match throttle-blip flares the engine
                    -- UP past the landing rpm so it's clearly audible/visible, then
                    -- settles as the gear commits. P.RevMatchBlip (>1) sets how much.
                    target = target * (P.RevMatchBlip or 1.0)
                    if target > 1.0 then target = 1.0 end
                    -- SHARPER DOWNSHIFT BARK (DCT tiers 4/5): a race DCT rev-matches with a
                    -- near-instant throttle CRACK, not the TC's swelling blip. When P.RevBark
                    -- is set, snap the needle straight to the flared target in one step (audio/
                    -- needle only — perf-safe, no drive force). Mode 3 keeps the gentle ramp.
                    if P.RevBark and gearMode >= 4 then
                        if state.rpm < target then vl_setRpmRaw(veh, target) end
                        if HK.hdbgOn and HK.dbgGear then HK.dbgGear.barkTgt = target end
                    else
                        local di   = (origins and origins.fDriveInertia) or 1.0
                        local rate = (Config.Gearbox.RevRaiseRate or 22.0) * di * dt * (P.RevFeedRate or 0.8)
                        if state.rpm < target then
                            local nr = state.rpm + (target - state.rpm) * rate
                            if target - nr < 0.02 then nr = target end   -- snap the last sliver for a crisp blip
                            vl_setRpmRaw(veh, nr)
                        end
                    end
                end
            end
        elseif dctPendingGear and now >= dctShiftEndAt then
            -- POST-UPSHIFT KICK latch: was this commit an UPSHIFT? (pending > committed)
            local wasUpshift = dctPendingGear > dctCommittedGear
            -- Commit the gear ONCE, restore drive coupling.
            vl_setCurrentGear(veh, dctPendingGear)
            dctCommittedGear = dctPendingGear
            dctPendingGear   = nil
            if origins and origins.fInitialDriveForce then
                setDriveForce(veh, gbDriveForceLive or origins.fInitialDriveForce)
            end
            if netEnt then netEnt.state:set('sync_gear', dctCommittedGear, true) end
            -- RIGID RPM SNAP (DCT tiers 4/5, UPSHIFT only). A dual-clutch drops the needle
            -- INSTANTLY to the new gear's rpm as the pre-selected clutch bites — no float,
            -- no slur (the exact opposite of the TC slip-flare). Snap the painted rpm to the
            -- learned new-gear projection in ONE step (audio/needle only — vl_setRpmRaw is
            -- zero drive force, perf-safe). Only when the projection is learned; nil = leave
            -- GTA's natural drop. Mode 3 (TC) skips this and keeps its elastic float.
            if wasUpshift and P.RpmSnap and gearMode >= 4 then
                local snapTo = projectGearRpm(dctCommittedGear)
                if snapTo then
                    if snapTo > 0.99 then snapTo = 0.99 end
                    vl_setRpmRaw(veh, snapTo)
                    if HK.hdbgOn and HK.dbgGear then HK.dbgGear.rpmSnapTo = snapTo end
                end
            end
            -- POST-UPSHIFT KICK (the "shove in the back"). DCT tiers 4/5 = CONSTANT amp on
            -- EVERY upshift at any throttle (rigid, always-there). TC mode 3 = THROTTLE-GATED
            -- (~0 light, full at WOT — matches the load-variable converter lockup). The pulse
            -- is applied below as 1 + amp*sin(2*pi*tau): a surge in the first half then an
            -- equal-area settle below baseline in the second, so its time-integral is ZERO
            -- by construction => net 0-100 is UNCHANGED (area-fair, no dip coordination).
            if wasUpshift and (P.KickAmp or 0) > 0 then
                local amp = P.KickAmp
                local gated = (gearMode == 3)
                local kThr = state.throttle or 0.0
                if gated then
                    if kThr < 0 then kThr = 0 elseif kThr > 1 then kThr = 1 end
                    amp = amp * kThr           -- TC: gated by throttle (converter load)
                end
                if amp > 0.0005 then
                    HK.dctKickAmp   = amp
                    HK.dctKickMs    = P.KickMs or 80
                    HK.dctKickStart = now
                    HK.dctKickUntil = now + HK.dctKickMs
                end
                -- /handlingdbg: latch the LAST upshift's kick so you can read it after the pulse
                -- fades — amp, whether it was throttle-gated (TC) or constant (DCT), throttle at commit.
                if HK.hdbgOn and HK.dbgGear then
                    HK.dbgGear.kickLast   = amp
                    HK.dbgGear.kickGated  = gated
                    HK.dbgGear.kickThr    = gated and kThr or nil
                    HK.dbgGear.kickAt     = now
                end
            end
        else
            -- No shift in flight: keep-alive pin only if GTA drifted off our gear.
            if dctCommittedGear >= 1 and cur ~= dctCommittedGear then
                vl_setCurrentGear(veh, dctCommittedGear)
            end
        end

        -- Smooth shift dip (gentle taper just after a commit).
        if now < dctShiftDipUntil and not (dctPendingGear and now < dctShiftEndAt) then
            HK.torqueMult = HK.torqueMult * (P.ShiftDipPower or 0.9)
        end

        -- Redline-upshift boost (the "nailed it" reward).
        if now < dctBoostUntil then
            HK.torqueMult = HK.torqueMult * (P.BoostMult or 1.1)
        end

        -- POST-UPSHIFT KICK pulse. 1 + amp*sin(2*pi*tau) over the pulse window: a torque
        -- SURGE in the first half then an equal settle below baseline in the second half.
        -- sin over a full period integrates to 0, so net torque-over-time is UNCHANGED
        -- (the 0-100 stays put) — it only redistributes into a felt "shove". DCT 4/5 fire
        -- it every upshift (constant amp); TC mode 3 gates amp by throttle (see the latch).
        if now < HK.dctKickUntil and HK.dctKickAmp > 0.0 and HK.dctKickMs > 0 then
            local tau = (now - HK.dctKickStart) / HK.dctKickMs
            if tau < 0 then tau = 0 elseif tau > 1 then tau = 1 end
            local m = 1.0 + HK.dctKickAmp * math.sin(2.0 * math.pi * tau)
            if m < 0.0 then m = 0.0 end
            HK.torqueMult = HK.torqueMult * m
            -- (5) UPSHIFT IGNITION-CUT FLUTTER (DCT tiers 4/5, WOT bang only). A real dual-
            -- clutch cracks the ignition on the shift — a fast micro-flutter on the needle at
            -- the upshift. Ride the kick window with a high-frequency rpm wobble (NEEDLE/AUDIO
            -- only via vl_setRpmRaw — zero drive force, perf-safe). Only at high throttle (the
            -- crackle is a WOT thing) and only DCT tiers; mode 3/2 never see it. The wobble is
            -- tiny + centred on the CURRENT painted rpm, so it can't trip a shift/limiter test
            -- (well below upRpm right after an upshift; dwell blocks a re-trip anyway).
            if gearMode >= 4 and (P.FlutterAmp or 0) > 0 and (state.throttle or 0) > 0.80 then
                local fw = math.sin(2.0 * math.pi * (P.FlutterCycles or 2.0) * tau)
                local base = state.rpm or 0.0
                local nr = base + (P.FlutterAmp or 0) * fw
                if nr < 0 then nr = 0 elseif nr > 0.99 then nr = 0.99 end
                vl_setRpmRaw(veh, nr)
                if HK.hdbgOn and HK.dbgGear then HK.dbgGear.flutter = P.FlutterAmp end
            end
        end

        -- Penalty torque cut (after the rev-match window, during the hold).
        if dctOverrevUntil > 0 and now >= dctShiftEndAt then
            local op = P.OverrevPower or 0.7
            if op < 1.0 then HK.torqueMult = HK.torqueMult * op end
        end

        -- Shared physics: lugging floor then the per-gear rev-limiter speed-cap.
        applyLugFloor(state, dctGear)
        applyRevLimiter(state, dctGear, veh)

        -- TIP-IN BOG DETECTOR + AUTO-LIFT (2026-08-16 — the user's spec). The bog is an rpm OSCILLATION:
        -- on a tip-in the box wants to drop but the target gear is blocked, so rpm climbs to a peak, the
        -- (blocked) drop attempt bleeds it back = a "bog-back", then it climbs again = a second bog-back —
        -- all while STUCK in the same gear. We don't reason about the shift math; we just WATCH the needle.
        -- Count peaks (rpm rises then falls back past a hysteresis band) while on-power in a FIXED gear.
        -- On the SECOND bog-back, LATCH a brief throttle release (TipInBogLiftMs). After it ends, if the
        -- player is still holding, input passes straight through again (no lingering cut). AUTOMATIC only.
        do
            local isAuto = (gearMode ~= 1 and gearMode ~= 6)   -- exclude manual (1) + sequential (6)
            local onPower = (state.throttle or 0.0) >= (Config.Gearbox.TipInBogThr or 0.30)
            -- DOWNSHIFT-ONLY GATE (2026-08-16): the bog we fix is a BLOCKED DOWNSHIFT — the box wants to
            -- drop but the target gear is bounce/over-rev guarded, so rpm oscillates STUCK in gear. An rpm
            -- oscillation up near an UPSHIFT point (WOT limiter bounce) is NOT that bog, but the raw peak/
            -- trough counter couldn't tell them apart and mis-lifted on upshifts. Only arm while the box has
            -- recently WANTED a downshift (HK.dctDownWantAt stamped in the downshift branch this/last frame).
            local downWant = HK.dctDownWantAt and (now - HK.dctDownWantAt) <= (Config.Gearbox.TipInBogDownWindowMs or 250)
            local r = state.rpm or 0.0
            local band = Config.Gearbox.TipInBogBand or 0.03   -- rpm must fall this far to count a bog-back
            -- reset the oscillation tracker whenever the gear changes, we lift, or we're not eligible
            if not isAuto or not onPower or not downWant or dctGear ~= (HK.tipInBogGear or dctGear) then
                HK.tipInBogCount, HK.tipInBogPeak, HK.tipInBogRising = 0, r, false
            else
                local peak = HK.tipInBogPeak or r
                if r >= peak then
                    HK.tipInBogPeak = r                        -- new high; we're climbing
                    HK.tipInBogRising = true
                elseif HK.tipInBogRising and (peak - r) >= band then
                    -- rpm fell back past the band after a climb = ONE bog-back
                    HK.tipInBogCount = (HK.tipInBogCount or 0) + 1
                    HK.tipInBogRising = false
                    HK.tipInBogPeak = r                        -- re-seat the peak at the trough
                    if HK.tipInBogCount >= (Config.Gearbox.TipInBogCount or 2) then
                        -- SECOND bog-back just ENDED → release throttle briefly so the drop can clear.
                        HK.tipInBogUntil    = now + (Config.Gearbox.TipInBogLiftMs or 220)
                        HK.tipInBogLiftGear = dctGear   -- remember the stuck gear; release ends when it changes
                        HK.tipInBogCount = 0
                    end
                end
            end
            HK.tipInBogGear = dctGear

            -- ENFORCE the release window: a PARTIAL throttle lift (not a full cut). The old full-0 kill
            -- (DisableControlAction 71 + torqueMult 0) dropped the engine dead — a very obvious sudden
            -- silence in the sound + a hard torque hole. Instead hold torque at TipInBogLiftFrac (0.22):
            -- enough of a lift to let rpm fall off the up-point so the downshift slots in, but the engine
            -- keeps pulling audibly and rpm doesn't rampthrough. Cancel the instant the gear changes (the
            -- downshift landed) so it never bleeds into the new gear.
            if HK.tipInBogUntil and now < HK.tipInBogUntil
               and dctGear == (HK.tipInBogLiftGear or dctGear) then
                HK.torqueMult = HK.torqueMult * (Config.Gearbox.TipInBogLiftFrac or 0.22)
            else
                HK.tipInBogUntil = 0
            end
        end
        launchBoostApply(state)         -- fading launch surge after a DCT-auto launch (no-op otherwise)

        -- F1 / RACE LOW-SPEED HARSHNESS (per-profile, opt-in). A race transmission
        -- has almost no creep and a sharp, direct low-speed feel — not made for
        -- traffic. When P.LowSpeedCut is set, bleed torque below P.LowSpeedKmh so
        -- crawling feels mechanical/harsh instead of smooth. Off (nil) for 3/4 so
        -- they keep civil low-speed manners. Only off-idle so it never stalls dead.
        if P.LowSpeedCut and (state.speedKmh or 0) < (P.LowSpeedKmh or 20.0)
           and (state.throttle or 0) < 0.85 then
            HK.torqueMult = HK.torqueMult * P.LowSpeedCut
        end

        -- (7) REDUCED CREEP (DCT tiers 4/5). A dual-clutch BITES off the line — it doesn't
        -- crawl smoothly like a torque converter. Trim creep torque at very low speed + light
        -- throttle so take-up feels direct/mechanical. Mild (never stalls). Skips at higher
        -- throttle (a real launch is unaffected) and above CreepKmh (only the crawl). DCT only.
        if gearMode >= 4 and (P.CreepMult or 1.0) < 1.0
           and (state.speedKmh or 0) < (P.CreepKmh or 6.0) and (state.throttle or 0) < 0.35 then
            HK.torqueMult = HK.torqueMult * P.CreepMult
        end

        -- (6) DRY-CLUTCH JUDDER (DCT tiers 4/5). A dry-clutch DCT shunts/grabs on low-speed
        -- creep (clutch take-up chatter) where a TC glides. Paint a small AREA-FAIR torque
        -- shudder (centred on 1.0 via sin => net-zero over time, 0-100 unaffected) below
        -- JudderKmh at part throttle. Off-throttle (coasting) and at speed it's silent. DCT
        -- only — mode 3/2 keep glassy-smooth creep. Uses wall-clock for a steady frequency.
        if gearMode >= 4 and (P.JudderAmp or 0) > 0
           and (state.speedKmh or 0) < (P.JudderKmh or 14.0)
           and (state.speedKmh or 0) > 1.0
           and (state.throttle or 0) > 0.03 and (state.throttle or 0) < 0.55 then
            local jw = math.sin(2.0 * math.pi * (P.JudderHz or 11.0) * (now / 1000.0))
            HK.torqueMult = HK.torqueMult * (1.0 + (P.JudderAmp or 0) * jw)
            if HK.hdbgOn and HK.dbgGear then HK.dbgGear.judder = P.JudderAmp end
        elseif HK.hdbgOn and HK.dbgGear then
            HK.dbgGear.judder = 0.0
        end

        -- TC ELASTIC SLIP-FLARE (mode 3 = Automatic-Paddle only; NEEDLE + AUDIO only).
        -- A torque converter lets the engine run a little AHEAD of the ratio-locked rpm
        -- under load ("slip"), then pulls into lockup as speed rises / throttle eases.
        -- We paint that as a small rpm offset via vl_setRpmRaw — ZERO drive force, and
        -- it was de-biased out at branch entry so it can NEVER feed a shift/limiter
        -- decision. Target slip builds with throttle, fades to 0 by SlipLockupKmh (locked)
        -- and below the throttle gate (coasting), and is capped below redline so it can't
        -- fake an over-rev wail. First-order lag (engage/release tau) makes it rubbery.
        do
            local tf = cfg.TcFeel
            if gearMode == 3 and tf and tf.SlipFlare and not (dctPendingGear and now < dctShiftEndAt) then
                local thr  = state.throttle or 0.0
                local kmh  = state.speedKmh or 0.0
                local gate = tf.SlipThrGate or 0.15
                local tgt  = 0.0
                local lock = 0.0
                local reason = nil
                if thr > gate then
                    local load = (thr - gate) / (1.0 - gate)          -- 0 at gate -> 1 at WOT
                    if load > 1.0 then load = 1.0 end
                    local lockKmh = tf.SlipLockupKmh or 70.0
                    lock = (lockKmh > 0) and (1.0 - kmh / lockKmh) or 0.0
                    if lock < 0.0 then lock = 0.0 elseif lock > 1.0 then lock = 1.0 end
                    tgt = (tf.SlipMax or 0.06) * load * lock
                    if lock <= 0.0 then reason = 'lockup' end          -- above SlipLockupKmh = converter locked
                else
                    reason = 'coast'                                   -- below throttle gate = no slip
                end
                -- first-order approach toward tgt (rise vs fall use different taus)
                local tau = (tgt > HK.tcSlipCur) and (tf.SlipEngageTau or 0.18) or (tf.SlipReleaseTau or 0.10)
                local a = (tau > 0) and (dt / (tau + dt)) or 1.0
                HK.tcSlipCur = HK.tcSlipCur + (tgt - HK.tcSlipCur) * a
                if HK.tcSlipCur < 0.0005 then HK.tcSlipCur = 0.0 end
                if HK.tcSlipCur > 0.0 then
                    local painted = (state.rpm or 0.0) + HK.tcSlipCur
                    local cap = tf.SlipRedlineCap or 0.97
                    if painted >= cap then reason = 'cap' end          -- clipped at the redline guard
                    if painted > cap then painted = cap end
                    vl_setRpmRaw(veh, painted)
                end
                -- /handlingdbg: expose WHY the flare is where it is, not just its value.
                if HK.hdbgOn and HK.dbgGear then
                    HK.dbgGear.slipTgt  = tgt          -- where the flare is heading (steady-state)
                    HK.dbgGear.slipLock = lock         -- 1 = fully unlocked (low speed), 0 = locked up (fast)
                    HK.dbgGear.slipWhy  = reason       -- nil = flaring; 'coast'/'lockup'/'cap' = why it's suppressed
                end
            elseif HK.tcSlipCur ~= 0.0 then
                HK.tcSlipCur = 0.0   -- not eligible this frame; clear so de-bias stays correct
            end
        end
        return
    end

    -- ============================================================= MODE 6
    -- MODE 6 — HYBRID SEQUENTIAL DOGBOX. FULLY STANDALONE (own complete branch;
    -- shares no code with mode 1). Dog engagement on UPSHIFTS (fast, clutchless-
    -- friendly, zone-graded: SLUG bog / ENGAGE / PERFECT bonus / BOUNCE reject —
    -- SLUG ENGAGES IMMEDIATELY, never neutral). Synchro double-clutch on DOWNSHIFTS.
    if gearMode == 6 then
    -- MANUAL CLASS ignores reqNeutralTap (uses HOLD-both instead). CLEAR it so a J+K chord can't
    -- latch it true forever — a stuck reqNeutralTap jams the input block (line ~1819 `if not
    -- reqNeutralTap`), which then NEVER promotes pending presses to reqUp/reqDown = no more gear
    -- changes until re-entering the car. THIS was the "stuck on the gear before neutral" regression.
    reqNeutralTap = false
    local SEQ  = Config.Gearbox.Seq or {}
    local canShift = (not Config.Gearbox.ClutchOnly) or clutchHeld
    local shiftTimeUp   = SEQ.ShiftUpMs   or shiftTimeUp
    local shiftTimeDown = SEQ.ShiftDownMs or shiftTimeDown

    -- Open a shift window toward newTg (seq copy). DURATION is clutch-independent;
    -- power/engagement feel is decided at COMMIT.
    local function beginShift(newTg, baseDur)
        shiftFromGear = targetGear   -- remember where we shifted FROM (up/down split)
        shiftStartRpm = state.rpm    -- capture rpm NOW (what the player saw when they hit shift),
                                     -- before the rev-drop assist pulls it down during the window
        targetGear = newTg
        shifting, shiftEndAt = true, now + baseDur
        shiftWasClutchless = not clutchHeld
        missShiftUntil = 0          -- a fresh shift overrides any pending failed-shift recovery
        if clutchHeld then
            shiftPowerMult = Config.Gearbox.ShiftClutchBoost or 1.1
            shiftPowerUntil = now + baseDur + (Config.Gearbox.ShiftPowerHoldMs or 350)
        else
            shiftPowerMult = 1.0
            shiftPowerUntil = now + baseDur
        end
    end

    -- (Double-tap latched-neutral gesture RETIRED — sequential is a MANUAL class, so neutral
    -- is HOLD-both, handled by the bothHeld block below.)

    -- NEUTRAL via BOTH shift keys held together (temporary; misinput-gated).
    local bothHeld = upHeld and downHeld
    if bothHeld then
        reqUp, reqDown = false, false
        if canShift and not shifting and targetGear ~= 0 then
            preNeutralGear = targetGear
            targetGear = 0
            neutralGate = true
            manualNeutralHold = true
        end
    else
        if targetGear == 0 and manualNeutralHold and not Config.Gearbox.ManualNeutralLatch
           and not shifting and (preNeutralGear ~= 0) then
            targetGear = preNeutralGear
            manualNeutralHold = false
        end
        if not upHeld and not downHeld then
            neutralGate = false
        end
    end

    -- LAUNCH CONTROL (SEQUENTIAL, gearMode 6) — mirror of the true-manual stage (mode 1). 2026-08-14
    -- revert: LC STAGES IN NEUTRAL (box shows N, engine free-revs against the brake capped at lcTargetRpm).
    -- YOU bang it into 1st to launch. FIRE = handbrake release / upshift / footbrake-drop with throttle
    -- floored → beginShift(1) engages 1st. This sets HK.launching (via launchBoostApply on the drive
    -- frames below), which the muscle-wheelie module keys off. Bail (throttle off) leaves the box IN
    -- NEUTRAL. GATE kept at lcPhase active so the tick keeps being serviced. Runs BEFORE the upshift ladder.
    if ((targetGear == 0) or (lcPhase ~= 'off')) and not shifting and missShiftUntil == 0 then
        local lc = launchStageTick(veh, state, dt, true, reqUp)
        if lc == 'staged' then
            reqUp, reqDown = false, false        -- staged: swallow shift taps except the launch fire
            neutralGate = false
            -- Staged in NEUTRAL: the neutral free-rev block above cuts drive + free-revs; launchStageTick
            -- holds the rev cap at lcTargetRpm on top. Nothing to pin here.
            return                               -- sit staged this frame (clutch/rev handled by stage)
        elseif lc == 'launch' then
            reqUp = false                        -- consume the upshift that fired the launch
            manualNeutralHold = false
            preNeutralGear = 1
            -- STAGED IN NEUTRAL now (2026-08-14 revert): engage 1st for real on the fire (was assuming
            -- lcEngageGear1 already put us in 1). beginShift(1) so the clutch-dump launch drops into gear.
            if targetGear ~= 1 then beginShift(1, shiftTimeUp) end
            -- fall through: launchBoostApply runs on the drive frames below.
        end
    end

    -- UPSHIFT ladder: R -> N -> [preNeutral] -> ... -> gearcount.
    if reqUp then
        reqUp = false
        if canShift and not neutralGate then
            if     targetGear == -1 then
                -- R -> N. Reset preNeutralGear to 1 so the NEXT upshift out of this neutral goes to
                -- 1st, not a stale higher gear left over from a prior hold-both-neutral (the "comes
                -- out of reverse in 2nd" bug). Reverse is always a from-standstill take-off.
                preNeutralGear = 1
                beginShift(0, shiftTimeUp)
            elseif targetGear == 0  then
                local g = (preNeutralGear and preNeutralGear >= 1 and preNeutralGear <= gearcount) and preNeutralGear or 1
                beginShift(g, shiftTimeUp)
            elseif targetGear >= 1 and targetGear < gearcount then beginShift(targetGear + 1, shiftTimeUp) end
        end
    end

    -- DOWNSHIFT ladder: gearcount..2 -> 1 -> N -> R.
    if reqDown then
        reqDown = false
        if canShift and not neutralGate then
            if     targetGear == 1 then preNeutralGear = 1; beginShift(0, shiftTimeDown)
            elseif targetGear == 0 then
                local cfg = Config.Gearbox
                local okR = true
                if cfg.RealisticReverseManual then
                    -- NEAR-STOP GATE ONLY (2026-08-14): sequential matches manual — a downshift from
                    -- N walks into R without a held brake, just the near-stop speed guard.
                    okR = (state.speedKmh or 0) < (cfg.ReverseMaxKmh or 8.0)
                end
                if okR then beginShift(-1, shiftTimeDown) end
            elseif targetGear >= 2 then beginShift(targetGear - 1, shiftTimeDown) end
        end
    end

    -- Shift window end -> commit (dog up / synchro down grading).
    if shifting and now >= shiftEndAt then
        shifting = false
        local failed = false
        if targetGear >= 1 then
            -- Shift classification:
            --   N->1 (and any N/R take-off) = LAUNCH boost only (never perfect/bog/bounce)
            --   1->2                         = LAUNCH window OR PERFECT window (both eligible),
            --                                  never bogs/bounces — the "pull away nicely" shift
            --   2->3, 3->4…                  = full dog grading (PERFECT/ENGAGE/SLUG/BOUNCE)
            local isDown   = (shiftFromGear >= 1) and (targetGear < shiftFromGear)
            local isUp     = (shiftFromGear >= 2) and (targetGear > shiftFromGear)
            local is1to2   = (shiftFromGear == 1) and (targetGear > shiftFromGear)
            local proj   = projectRpmFor(targetGear, state)
            if isUp then
                -- SEQUENTIAL UPSHIFT (dog engagement), zones as a fraction of redline.
                -- .META SCALING nudges the zones by the car's clutch-rate (±7% clamp):
                -- sporty = higher/tighter, lazy = lower/wider.
                local baseline   = SEQ.MetaClutchBaseline or 2.5
                local clutchRate = (origins and origins.fClutchChangeRateScaleUpShift) or baseline
                local maxDelta   = SEQ.MetaScaleMax or 0.07
                local metaScale  = 1.0 + ((clutchRate - baseline) / baseline) * (SEQ.MetaScaleStrength or 0.15)
                if metaScale < (1.0 - maxDelta) then metaScale = 1.0 - maxDelta end
                if metaScale > (1.0 + maxDelta) then metaScale = 1.0 + maxDelta end

                local engLo  = (SEQ.UpEngageLo or 0.78) * metaScale
                local engHi  = (SEQ.UpEngageHi or 0.91) * metaScale
                local perfLo = (SEQ.UpPerfectLo or 0.81) * metaScale
                local perfHi = (SEQ.UpPerfectHi or 0.87) * metaScale

                local rpm = shiftStartRpm    -- rpm at the instant shift was pressed (NOT window-end,
                                             -- which the rev-drop assist pulls down — that desynced
                                             -- the grade from what the player saw on the tacho)
                local result
                if rpm > engHi then
                    -- BOUNCE: too high (above UpEngageHi). Dogs clash, reject — stay in the
                    -- old gear. Only reached on a 2nd+ gear upshift (isUp already requires
                    -- shiftFromGear >= 2); launches into 1st/2nd never bounce.
                    result = 'BOUNCE'
                    targetGear      = shiftFromGear
                    shiftPowerMult  = SEQ.UpMissPenalty or 0.85
                    shiftPowerUntil = now + (SEQ.UpMissPenaltyMs or 120)
                elseif rpm >= perfLo and rpm <= perfHi then
                    -- PERFECT: nailed it. Bonus power + callout.
                    result = 'PERFECT'
                    TriggerEvent('hk-speedo:perfectShift')   -- speedo gauge shows it (toast removed)
                    shiftPowerMult  = SEQ.UpshiftBonus or 1.35
                    shiftPowerUntil = now + (SEQ.UpshiftBonusMs or 700)
                elseif rpm >= engLo then
                    -- ENGAGE: in the zone, not perfect. Clean, no bonus/penalty.
                    result = 'ENGAGE'
                    shiftPowerMult, shiftPowerUntil = 1.0, now
                else
                    -- SLUG: shifted too early. ENGAGES IMMEDIATELY (never neutral) but
                    -- bogs — an accel penalty for the hold window. The gear is in; you
                    -- just lugged it, so you pull away soft instead of dropping to N.
                    result = 'SLUG'
                    shiftPowerMult  = SEQ.UpSlugPenalty or 0.87
                    shiftPowerUntil = now + (SEQ.UpSlugPenaltyMs or 600)
                end

                if Config.Gearbox.Debug then
                    print(('[hk-seq] UPSHIFT rpm=%.3f(start) zone=[%.3f..%.3f] perf=[%.3f..%.3f] meta=%.2f -> %s')
                        :format(rpm, engLo, engHi, perfLo, perfHi, metaScale, result))
                end
            else
                -- DOWNSHIFT or LAUNCH. Downshift = synchro/double-clutch: clutch HELD =
                -- wide forgiving window; clutchless/bad-match = harsh dog clunk (brief
                -- torque penalty only, gear STILL engages — dogbox never falls to N).
                if isDown then
                    local win     = clutchHeld and (SEQ.DownSynchroWindow or 0.30) or (SEQ.DownRevMatchWindow or 0.12)
                    local matched = proj and (math.abs(state.rpm - proj) <= win)
                    if matched then
                        shiftPowerMult, shiftPowerUntil = 1.0, now
                        TriggerEvent('hk-speedo:perfectShift')
                    else
                        shiftPowerMult  = SEQ.DownNoClutchPenalty or 0.8
                        shiftPowerUntil = now + math.random(260, 340)
                    end
                elseif is1to2 then
                    -- 1->2: the "pull away nicely" shift. Eligible for BOTH the LAUNCH window
                    -- (wider/lower) AND the PERFECT window — whichever the rpm lands in gives
                    -- the boost. Never bogs, never bounces (this is still part of getting off
                    -- the line cleanly). A low-rev 1->2 just engages clean at 1.0.
                    local lbLo   = SEQ.LaunchBoostLo or 0.728
                    local lbHi   = SEQ.LaunchBoostHi or 0.856
                    local perfLo = SEQ.UpPerfectLo or 0.832
                    local perfHi = SEQ.UpPerfectHi or 0.928
                    local inLaunch  = shiftStartRpm >= lbLo and shiftStartRpm <= lbHi
                    local inPerfect = shiftStartRpm >= perfLo and shiftStartRpm <= perfHi
                    if inLaunch or inPerfect then
                        shiftPowerMult  = SEQ.UpshiftBonus or 1.8
                        shiftPowerUntil = now + (SEQ.UpshiftBonusMs or 700)
                        TriggerEvent('hk-speedo:perfectShift')   -- gauge shows it (toast removed)
                        if Config.Gearbox.Debug then
                            print(('[hk-seq] 1->2 BOOST rpm=%.3f launch=[%.3f..%.3f] perf=[%.3f..%.3f] -> %s')
                                :format(shiftStartRpm, lbLo, lbHi, perfLo, perfHi, inPerfect and 'PERFECT' or 'LAUNCH'))
                        end
                    else
                        shiftPowerMult, shiftPowerUntil = 1.0, now
                    end
                else
                    -- LAUNCH (N->1, or any N/R take-off). REWARD a revved manual launch: rpm in
                    -- the launch window (wider/lower than PERFECT) gives the UpshiftBonus torque
                    -- for a harder standing start. NEVER penalize — a low-rev / idle pull-away
                    -- just engages clean at 1.0 (no SLUG bog). Uses shiftStartRpm (what the
                    -- player saw when they pressed), not window-end rpm. No PERFECT here: a
                    -- standing launch into 1st only earns the launch boost, not perfect.
                    local lbLo = SEQ.LaunchBoostLo or 0.728   -- realrev 66%
                    local lbHi = SEQ.LaunchBoostHi or 0.856   -- realrev 82%
                    if shiftStartRpm >= lbLo and shiftStartRpm <= lbHi then
                        shiftPowerMult  = SEQ.UpshiftBonus or 1.8
                        shiftPowerUntil = now + (SEQ.UpshiftBonusMs or 700)
                        if Config.Gearbox.Debug then
                            print(('[hk-seq] LAUNCH BOOST rpm=%.3f win=[%.3f..%.3f]'):format(shiftStartRpm, lbLo, lbHi))
                        end
                    else
                        shiftPowerMult, shiftPowerUntil = 1.0, now
                    end
                end
            end
        end
        shiftWasClutchless = false

        if not failed then
            local ng = nativeGear(targetGear)
            if vl_getCurrentGear(veh) ~= ng then vl_setCurrentGear(veh, ng) end
            if netEnt then netEnt.state:set('sync_gear', ng, true) end
        else
            if vl_getCurrentGear(veh) ~= 0 then vl_setCurrentGear(veh, 0) end
            if netEnt then netEnt.state:set('sync_gear', 0, true) end
        end
    end

    -- FAILED-SHIFT RECOVERY (kept for parity; seq SLUG no longer triggers it).
    if missShiftUntil > 0 and now >= missShiftUntil then
        missShiftUntil = 0
        targetGear = missShiftGear
        local ng = nativeGear(targetGear)
        vl_setCurrentGear(veh, ng)
        if netEnt then netEnt.state:set('sync_gear', ng, true) end
    end

    -- CLUTCH SIM. clutchActive drives the drive cut + rev-feed. NEUTRAL decouples too.
    local inNeutral = (targetGear == 0)
    if inNeutral then HK.gbInNeutral = true end     -- free-rev signal (manual/seq neutral gear)
    local clutchActive = shifting or clutchHeld or inNeutral
    if now >= clutchReadyAt then
        local odf = origins and origins.fInitialDriveForce
        if clutchActive then
            HK.torqueMult = 0.0
            if odf then setDriveForce(veh, 0.0) end
            local di = (origins and origins.fDriveInertia) or 1.0
            if inNeutral then
                local t      = state.throttle or 0.0
                local revMax = (Config.Gearbox.NeutralRevMax or 1.0)
                if (state.speedKmh or 0) > (Config.Gearbox.NeutralRevCapKmh or 5.0) then
                    revMax = Config.Gearbox.NeutralRevMaxMoving or 0.55
                end
                -- FLYWHEEL FREE-REV: feed toward (idle + throttle span) in BOTH directions via the
                -- mass integrator — so a blip revs up at the flywheel's rate and a lift HANGS then
                -- decays (heavy = long hang, light = fast drop) instead of GTA snapping rpm down.
                -- Idle floor keeps a released engine at idle, not zero. Perf-neutral (drive already cut).
                local idle   = Config.Gearbox.Flywheel and Config.Gearbox.Flywheel.IdleRpm or 0.20
                local target = idle + (revMax - idle) * t
                if target < idle then target = idle end
                local nr = HK.flywheelRev(state.rpm, target, dt, Config.Gearbox.Flywheel and Config.Gearbox.Flywheel.NeutralDownRatio)
                vl_setRpmRaw(veh, nr)
            else
                -- Clutch-in / shifting rev-feed. UPSHIFT: ramp rpm DOWN to the new gear's
                -- target so it lands rev-matched. Real gear->gear upshift only.
                local isUpshift = shifting and shiftFromGear >= 1
                                  and (targetGear > shiftFromGear) and (targetGear >= 1)
                local upTarget  = isUpshift and Config.Gearbox.UpshiftRevDrop
                                  and projectRpmFor(targetGear, state) or nil
                if upTarget and state.rpm > upTarget then
                    -- SEQUENTIAL RPM PUSH: at/above UpPushThreshold, PUSH rpm UP toward
                    -- UpPushTarget (overshoots the perfect zone) instead of dropping —
                    -- you must TIME the shift, not just hold throttle and wait.
                    if state.rpm >= (SEQ.UpPushThreshold or 0.82) then
                        local pushTarget = SEQ.UpPushTarget or 0.87
                        local pushRate   = (SEQ.UpPushRate or 4.0) * dt
                        if state.rpm < pushTarget then
                            local nr = state.rpm + (pushTarget - state.rpm) * pushRate
                            if pushTarget - nr < 0.01 then nr = pushTarget end
                            vl_setRpmRaw(veh, nr)
                        end
                    else
                        local drop = (Config.Gearbox.UpshiftRevDropPerS or 6.0) * dt
                        local nr = state.rpm - drop
                        if nr < upTarget then nr = upTarget end
                        vl_setRpmRaw(veh, nr)
                    end
                else
                    -- keep engine alive at throttle while decoupled (downshift / clutch
                    -- hold / unlearned gear). SEQ-only rate (Seq.RevRaiseRate).
                    local t = vl_getThrottleOffset(veh)
                    local rate = (SEQ.RevRaiseRate or Config.Gearbox.RevRaiseRate or 22.0) * di * dt
                    if state.rpm < t then vl_setRpmRaw(veh, state.rpm + (t * rate)) end
                end
            end
        else
            if odf then setDriveForce(veh, gbDriveForceLive or odf) end
        end

        -- POST-SHIFT POWER MULTIPLIER (boost/bog), once torque isn't clutch-cut.
        if now < shiftPowerUntil then
            if not clutchActive then
                HK.torqueMult = HK.torqueMult * shiftPowerMult
            end
        else
            shiftPowerMult = 1.0
        end

        -- SOFT STALL — lugging (high gear, low rpm, off-clutch, not shifting) bleeds
        -- power hard but never kills the engine.
        if not clutchActive and not shifting then
            learnGearRatio(state, targetGear)
            if targetGear >= (Config.Gearbox.StallMinGear or 2)
               and state.rpm < (Config.Gearbox.StallThreshold or 0.18) then
                HK.torqueMult = HK.torqueMult * (Config.Gearbox.StallPowerMult or 0.25)
            end
            applyLugFloor(state, targetGear)
            applyRevLimiter(state, targetGear, veh)
        end

        if Config.Gearbox.Debug and clutchActive ~= _dbgClutchPrev then
            _dbgClutchPrev = clutchActive
            print(('[hk-seq] clutchActive=%s held=%s shifting=%s gear=%s torqueMult=%s')
                :format(tostring(clutchActive), tostring(clutchHeld), tostring(shifting),
                        tostring(targetGear), tostring(HK.torqueMult)))
        end
    end

    -- LAUNCH SURGE (sequential). Fading boost + traction-control + grip-assist after a seq launch
    -- fired (N -> 1 upshift out of the staged neutral). No-op unless lcPhase is 'launched', so it's
    -- safe every seq drive frame. This is where HK.launching is (re)asserted for the muscle wheelie.
    launchBoostApply(state)

    -- REVERSE / STANDSTILL input arbitration (2026-08-14 rework: W drives reverse, S always brakes).
    HK.inReverseGear = (targetGear == -1)
    if targetGear == -1 then
        local injecting = HK.pedalModelOn and not HK._injAnalog and not HK.driftMode
        if injecting then
            -- REVERSE GEAR, pedal model injecting. FINAL DESIGN: control 72 CANNOT be shared between our
            -- W-injection and suppressing physical S (SetControlNormal can't hold a control below a held
            -- key), so ANY control-based reverse leaks a key. Instead we DISABLE BOTH 71 and 72 (kill all
            -- native throttle/brake/reverse input) and drive reverse DIRECTLY by velocity in
            -- HK.ReverseDrive_Tick (W = accel backward, S = brake, neither = coast, all capped). No control
            -- writes, no wheelspin, no key leak. rpm is painted by the reverse rev-feed above.
            DisableControlAction(0, 71, true)
            DisableControlAction(0, 72, true)
        elseif state.forwardSpeed > -2.0 then
            DisableControlAction(0, 71, true)   -- analog/off: native S-reverse applies, just block W-accel
        end
    elseif targetGear >= 0 then
        -- FORWARD GEAR *or* NEUTRAL, near standstill: native control 72 (S) is the reverse-accelerator in
        -- native gear 0, so a held S REVS the engine / crawls backward (the "S revs in neutral" bug). S is
        -- a pure brake now, so kill native 72 at a stop — braking STRENGTH still flows through fBrakeForce,
        -- and once rolling (forwardSpeed >= 0.5) 72 goes live so S brakes normally. EXCEPTION: keep 72 LIVE
        -- during a W+S burnout/free-rev gesture so the footbrake holds the car planted while revving/frying.
        if state.forwardSpeed < 0.5 and not HK.burnoutGestureLive(state) then
            DisableControlAction(0, 72, true)
            -- BRAKE LIGHT near idle: disabling 72 also kills GTA's native brake lamp (it follows the brake
            -- control), so a held S at low speed showed NO brake light. Drive it directly off the physical
            -- S key here — ON while braking, OFF otherwise — mirroring the reverse-gear brake-light fix.
            HK.setStandstillBrakeLight(veh, (HK._pedalBrake or 0.0) > 0.05)
        end
    end

    -- Pin the selected gear every frame when not shifting.
    if not shifting then
        local ng = nativeGear(targetGear)
        if vl_getCurrentGear(veh) ~= ng then vl_setCurrentGear(veh, ng) end
    end

    return
    end  -- end MODE 6 (sequential)

    -- ============================================================= MODE 1
    -- MODE 1 — CLASSIC MANUAL (clutch + H-pattern feel). FULLY STANDALONE:
    -- the sequential dogbox (mode 6) has its own complete branch ABOVE this one,
    -- so nothing here is shared with seq anymore — either can be tuned in isolation.
    -- GUARDED on gearMode == 1 (was the implicit fall-through "else"): auto/DCT return
    -- earlier and seq returns above, so manual was the only mode that could reach here —
    -- but an explicit guard means a future/unmapped mode can't silently run manual logic.
    -- Matches the if-wrap on the other modes (flat-indented body, same as MODE 6).
    if gearMode == 1 then
    -- MANUAL CLASS ignores reqNeutralTap (uses HOLD-both instead). CLEAR it so a J+K chord can't
    -- latch it true forever + jam the input block (see the mode-6 note) = no more gear changes.
    reqNeutralTap = false
    local canShift = (not Config.Gearbox.ClutchOnly) or clutchHeld

    -- Open a shift window toward newTg. Clutch no longer changes the DURATION
    -- (no time penalty for clutchless — that's the skill path). Power feel is set
    -- at COMMIT: a clutched shift gets the steady boost; a CLUTCHLESS shift is
    -- judged on rev-match quality there (bonus / neutral / mild bog).
    local function beginShift(newTg, baseDur)
        shiftFromGear = targetGear   -- remember where we shifted FROM
        shiftStartRpm = state.rpm    -- rpm the player saw when they hit shift (perfect-shift grading)
        targetGear = newTg
        shifting, shiftEndAt = true, now + baseDur
        shiftWasClutchless = not clutchHeld
        missShiftUntil = 0          -- a fresh shift overrides any pending failed-shift recovery
        if clutchHeld then
            -- MODE-1 reward (Manual.ClutchBoost), falling back to the top-level key.
            local M = Config.Gearbox.Manual or {}
            shiftPowerMult = M.ClutchBoost or Config.Gearbox.ShiftClutchBoost or 1.1
            shiftPowerUntil = now + baseDur + (Config.Gearbox.ShiftPowerHoldMs or 350)
        else
            -- provisional; the real value is set at commit from rev-match quality.
            shiftPowerMult = 1.0
            shiftPowerUntil = now + baseDur
        end
    end

    -- (Double-tap latched-neutral gesture RETIRED — H-manual is a MANUAL class, so neutral is
    -- HOLD-both, handled by the bothHeld block below.)

    -- NEUTRAL (manual) via BOTH shift keys held together. No dedicated key.
    -- While both held: temporary neutral (gear 0, coasts/free-revs). On release:
    -- restore the gear we were in before (ManualNeutralLatch=false, default), or
    -- stay latched until the next shift (=true, paddle-style). MISINPUT GUARD:
    -- once a both-hold neutral happens, neutralGate blocks the next shift until
    -- BOTH keys are released — so J+K -> N -> tap K alone does NOT upshift; you
    -- must release both first. The +/- handlers suppress the latch while both are
    -- held; here we also clear any stray latch and manage entry/exit/gate.
    local bothHeld = upHeld and downHeld
    if bothHeld then
        reqUp, reqDown = false, false              -- never treat a both-hold as a shift
        if canShift and not shifting and targetGear ~= 0 then
            preNeutralGear = targetGear            -- remember where to return
            targetGear = 0
            neutralGate = true                     -- block shifts until both released
            manualNeutralHold = true               -- THIS neutral is the temporary gesture
        end
    else
        -- One or both keys up. Only restore on release if this neutral was the
        -- temporary both-hold gesture (manualNeutralHold). A neutral from STARTUP
        -- or rotating down the ladder is NOT temporary — it persists until a
        -- deliberate shift (so the car genuinely starts/sits in neutral).
        if targetGear == 0 and manualNeutralHold and not Config.Gearbox.ManualNeutralLatch
           and not shifting and (preNeutralGear ~= 0) then
            targetGear = preNeutralGear
            manualNeutralHold = false
        end
        if not upHeld and not downHeld then
            neutralGate = false                    -- both released -> shifts allowed again
        end
    end

    -- LAUNCH CONTROL (TRUE MANUAL, gearMode 1). 2026-08-14 revert (user: "stay in neutral, I shift"):
    -- LC STAGES IN NEUTRAL — the box shows N, the engine free-revs against the brake (capped at lcTargetRpm
    -- by the staged-hold). FIRE = handbrake release / upshift / footbrake-drop with throttle floored →
    -- beginShift(1) drops it into 1st (the clutch-dump launch). EXIT WITHOUT LAUNCH (throttle bail) leaves
    -- the box IN NEUTRAL. GATE: run while in neutral (to stage) OR while LC is active so the tick keeps
    -- being serviced. Not while shifting / in a penalty-neutral.
    if ((targetGear == 0) or (lcPhase ~= 'off')) and not shifting and missShiftUntil == 0 then
        local lc = launchStageTick(veh, state, dt, true, reqUp)
        if lc == 'staged' then
            reqUp, reqDown = false, false        -- staged: swallow shift taps except the launch fire
            neutralGate = false
            -- Staged in NEUTRAL: the neutral free-rev block above cuts drive + free-revs; launchStageTick
            -- holds the rev cap at lcTargetRpm on top. Nothing to pin here.
            return                               -- sit staged this frame (clutch/rev handled by stage)
        elseif lc == 'launch' then
            reqUp = false                        -- consume the upshift that fired the launch
            manualNeutralHold = false
            preNeutralGear = 1
            -- STAGED IN NEUTRAL now (2026-08-14 revert): the fire IS you banging it into 1st, so ENGAGE
            -- 1st for real. If we were still in N (footbrake-drop / handbrake-release fire), beginShift(1)
            -- so the clutch-dump launch actually drops into gear. If the fire WAS the upshift key, the
            -- ladder below would take N->1 anyway, but we do it here so every manual fire path lands in 1.
            if targetGear ~= 1 then beginShift(1, shiftTimeUp) end
        end
    end

    -- UPSHIFT: R -> 1 -> 2 ... up to gearcount  (N -> last gear). Gated by neutralGate
    -- so a leftover held key after a both-hold neutral can't shift until both released.
    if reqUp then
        reqUp = false
        if missShiftUntil > 0 then
            -- INVOLUNTARY PENALTY NEUTRAL: a botched clutchless shift dropped us to N with a gear
            -- recovery pending (missShiftGear). This N is NOT a deliberate ladder position, so DON'T
            -- run the N->preNeutral ladder off it — just RAISE the pending recovery target so the
            -- press carries intent and the box recovers into the higher gear. Mirror of the downshift
            -- guard below. (Clamped to gearcount; never touches R.)
            if missShiftGear and missShiftGear < gearcount then missShiftGear = missShiftGear + 1 end
        elseif canShift and not neutralGate then
            -- Ladder: R(-1) -> N(0) -> [last gear before neutral] -> ... up to gearcount.
            -- Leaving neutral upward re-engages the gear you were in before going to
            -- neutral (preNeutralGear) rather than always 1st, for both the hold and
            -- the double-tap gestures. Falls back to 1st if that's unknown/invalid.
            if     targetGear == -1 then
                -- R -> N. Reset preNeutralGear to 1 so the NEXT upshift out of this neutral goes to
                -- 1st, not a stale higher gear left over from a prior hold-both-neutral (the "comes
                -- out of reverse in 2nd" bug). Reverse is always a from-standstill take-off.
                preNeutralGear = 1
                beginShift(0, shiftTimeUp)
            elseif targetGear == 0  then
                local g = (preNeutralGear and preNeutralGear >= 1 and preNeutralGear <= gearcount) and preNeutralGear or 1
                beginShift(g, shiftTimeUp)
            elseif targetGear >= 1 and targetGear < gearcount then beginShift(targetGear + 1, shiftTimeUp) end
        end
    end

    -- DOWNSHIFT: top..2 -> 1 -> N -> R.  Neutral sits between 1st and reverse.
    if reqDown then
        reqDown = false
        if missShiftUntil > 0 then
            -- INVOLUNTARY PENALTY NEUTRAL (bog): a botched clutchless downshift dropped us to N with a
            -- gear recovery pending. THE BUG THIS FIXES: the ladder below reads targetGear==0 as a
            -- DELIBERATE neutral and steps N->R, so a fast second downshift during the penalty window
            -- slammed the car into REVERSE. The penalty N is not a real ladder rung — so instead LOWER
            -- the pending recovery target (carry the "keep downshifting" intent), never fall to R.
            -- Floor at 1 (a downshift never selects reverse OUT of a penalty; that needs a deliberate
            -- press from a settled neutral).
            if missShiftGear and missShiftGear > 1 then missShiftGear = missShiftGear - 1 end
        elseif canShift and not neutralGate then
            -- Ladder: gearcount..2 -> 1 -> N(0) -> R(-1)
            if     targetGear == 1 then preNeutralGear = 1; beginShift(0, shiftTimeDown)
            elseif targetGear == 0 then
                -- N -> R. SIMPLE (default): always. REALISTIC: only when nearly
                -- stopped AND braking (real-car-style reverse selection guard).
                local cfg = Config.Gearbox
                local okR = true
                if cfg.RealisticReverseManual then
                    -- NEAR-STOP GATE ONLY (2026-08-14, user: "ditch the hold-S-to-reverse"). A
                    -- downshift from N selects R exactly like any other ladder rung — no held brake
                    -- required — as long as we're basically stopped (can't slam reverse at speed).
                    okR = (state.speedKmh or 0) < (cfg.ReverseMaxKmh or 8.0)
                    if HK.hdbgOn and HK.dbgGear then
                        HK.dbgGear.revSelKmh = state.speedKmh or 0.0
                        HK.dbgGear.revSelOk  = okR
                    end
                end
                if okR then beginShift(-1, shiftTimeDown) end
            elseif targetGear >= 2 then beginShift(targetGear - 1, shiftTimeDown) end
        end
    end

    -- Shift window end -> commit the native gear (only now; this is the fix
    -- for instant shifts — gear is NOT written while shifting).
    if shifting and now >= shiftEndAt then
        shifting = false

        -- PERFECT SHIFT (manual, type 1) — mirrors the sequential dogbox reward.
        -- REQUIRES THE CLUTCH HELD (user spec: a real manual perfect shift needs the
        -- clutch, keeps it from being too easy) on an UPSHIFT, with the rpm the player
        -- saw when they hit shift (shiftStartRpm) inside the perfect window. Uses the
        -- SAME values as Config.Gearbox.Seq (window + bonus), fires the SAME gauge event
        -- (hk-speedo:perfectShift -> gold glow; GetGearboxMode returns 'manual' for type
        -- 1, so the gauge already lights) and the SAME callout pool. Clutched-but-outside
        -- the window keeps the steady ClutchBoost from beginShift (clean shift, no bonus).
        -- Only for real gear->gear upshifts (shiftFromGear>=1, target>from); launches and
        -- downshifts are unaffected. Clutchless shifts fall through to the block below.
        if Config.Gearbox.ManualPerfectShift ~= false
           and not shiftWasClutchless          -- latched at beginShift = clutch WAS held for this shift
           and targetGear >= 1 and shiftFromGear >= 1 and targetGear > shiftFromGear then
            local SEQ = Config.Gearbox.Seq or {}
            local perfLo = SEQ.UpPerfectLo or 0.832
            local perfHi = SEQ.UpPerfectHi or 0.928
            if shiftStartRpm >= perfLo and shiftStartRpm <= perfHi then
                shiftPowerMult  = SEQ.UpshiftBonus or 1.8
                shiftPowerUntil = now + (SEQ.UpshiftBonusMs or 700)
                TriggerEvent('hk-speedo:perfectShift')   -- gauge shows it (toast removed)
                if Config.Gearbox.Debug then
                    print(('[hk-manual] PERFECT upshift %d->%d rpm=%.3f perf=[%.3f..%.3f]')
                        :format(shiftFromGear, targetGear, shiftStartRpm, perfLo, perfHi))
                end
            end
        end

        -- CLUTCHLESS REV-MATCH judgement (at commit). A clutched shift skips this
        -- (keeps the steady ShiftClutchBoost from beginShift). Clutchless: grade
        -- engine RPM vs what the NEW gear wants at this speed (learned ratio).
        --   matched -> reward (bonus power, clean engage).
        --   MISSED  -> the gate doesn't catch: fall to NEUTRAL for RevMatchFailNeutralMs
        --             + fail beep, THEN engage the gear you were going for. (Plus the
        --             no-clutch bog power once it does engage.)
        local failed = false
        if shiftWasClutchless and Config.Gearbox.RevMatchEnable and targetGear >= 1 then
            local rps     = gbRpmPerSpeed[targetGear]
            local target  = (rps and state.speedKmh > 0) and (rps * state.speedKmh) or nil
            local matched = target and (math.abs(state.rpm - target) <= (Config.Gearbox.RevMatchWindow or 0.10))
            -- An UPSHIFT is rev-matched BY THE ASSIST (UpshiftRevDrop), not by player
            -- skill, so it must NOT pay the bonus — that would be a permanent non-opt-in
            -- accel boost above .meta (speed-invariant). Assisted upshift = clean 1.0.
            -- The DOWNSHIFT blip is still a genuine player skill -> keep its bonus.
            local isUp = (shiftFromGear >= 1) and (targetGear > shiftFromGear)
            if isUp then
                -- clean engage at .meta power; if it landed ABOVE the window (e.g. a
                -- redline bang the limited drop couldn't close) it simply engages honest.
                shiftPowerMult, shiftPowerUntil = 1.0, now
            elseif matched then
                -- MODE-1 reward/penalty (Manual.*), falling back to the top-level keys.
                local M = Config.Gearbox.Manual or {}
                shiftPowerMult  = M.RevMatchBonus or Config.Gearbox.RevMatchBonus or 1.18
                shiftPowerUntil = now + (M.RevMatchBonusMs or Config.Gearbox.RevMatchBonusMs or 700)
            else
                local M = Config.Gearbox.Manual or {}
                shiftPowerMult  = M.NoClutchPower or Config.Gearbox.ShiftNoClutchPower or 0.9
                shiftPowerUntil = now + (M.RevMatchBonusMs or Config.Gearbox.RevMatchBonusMs or 700)
                local failMs = M.NeutralFailMs or Config.Gearbox.RevMatchFailNeutralMs or 600
                if failMs > 0 then
                    -- MISSED: drop to neutral now, engage the target gear after failMs.
                    failed = true
                    missShiftGear  = targetGear
                    missShiftUntil = now + failMs
                    targetGear = 0                 -- coast/free-rev in neutral meanwhile
                    -- (no beep)
                end
            end
        end
        shiftWasClutchless = false

        if not failed then
            local ng = nativeGear(targetGear)
            if vl_getCurrentGear(veh) ~= ng then vl_setCurrentGear(veh, ng) end
            if netEnt then netEnt.state:set('sync_gear', ng, true) end
        else
            if vl_getCurrentGear(veh) ~= 0 then vl_setCurrentGear(veh, 0) end
            if netEnt then netEnt.state:set('sync_gear', 0, true) end
        end
    end

    -- FAILED-SHIFT RECOVERY: the missed clutchless shift sat in neutral; now engage
    -- the gear the player was going for.
    if missShiftUntil > 0 and now >= missShiftUntil then
        missShiftUntil = 0
        targetGear = missShiftGear
        local ng = nativeGear(targetGear)
        vl_setCurrentGear(veh, ng)
        if netEnt then netEnt.state:set('sync_gear', ng, true) end
    end

    -- CLUTCH SIM (manual only — auto mode returned above). clutchActive drives
    -- both the drive cut and the rev-feed. NEUTRAL (gear 0) is also decoupled:
    -- the box transmits no drive and the engine free-revs.
    local inNeutral = (targetGear == 0)
    if inNeutral then HK.gbInNeutral = true end     -- free-rev signal (sequential neutral gear)
    local clutchActive = shifting or clutchHeld or inNeutral
    if now >= clutchReadyAt then
        local odf = origins and origins.fInitialDriveForce
        if clutchActive then
            -- DECOUPLE the wheels. NOTE: fInitialDriveForce=0 alone does NOT stop
            -- wheel torque in real time on this build (confirmed: live value reads
            -- 0.0 yet car still accelerates). The reliable real-time lever is the
            -- engine torque multiplier -> 0, applied in main.lua's setTorque after
            -- this tick. We zero BOTH (drive force for engine-brake feel + torque
            -- mult for the actual cut).
            HK.torqueMult = 0.0
            if odf then setDriveForce(veh, 0.0) end
            local di = (origins and origins.fDriveInertia) or 1.0
            if inNeutral then
                -- NEUTRAL: no gear, revs chase throttle via the FLYWHEEL integrator (mass-scaled
                -- blip up + rev-hang decay down). Use state.throttle (W input) — the vehicle throttle
                -- offset reads ~0 in neutral so revs wouldn't climb.
                local t      = state.throttle or 0.0
                -- STATIONARY -> free-rev to redline (show off). MOVING -> capped.
                local revMax = (Config.Gearbox.NeutralRevMax or 1.0)
                if (state.speedKmh or 0) > (Config.Gearbox.NeutralRevCapKmh or 5.0) then
                    revMax = Config.Gearbox.NeutralRevMaxMoving or 0.55
                end
                local idle   = Config.Gearbox.Flywheel and Config.Gearbox.Flywheel.IdleRpm or 0.20
                local target = idle + (revMax - idle) * t
                if target < idle then target = idle end
                local nr = HK.flywheelRev(state.rpm, target, dt, Config.Gearbox.Flywheel and Config.Gearbox.Flywheel.NeutralDownRatio)
                vl_setRpmRaw(veh, nr)
            else
                -- Clutch-in / shifting rev-feed.
                -- UPSHIFT: ramp rpm DOWN to the new (taller) gear's target so it lands
                -- rev-matched instead of dropping into the gear off-rpm (the "no accel
                -- after shift" feel). The target is what the new gear wants at THIS
                -- speed, from the seeded/learned ratio (projectRpmFor). Drive is already
                -- cut here, so this is purely the engine-brake-on-upshift you'd feel for
                -- real. DOWNSHIFTS and pure clutch-holds keep the rev-UP keep-alive.
                -- real gear->gear upshift only (shiftFromGear >= 1): leaving neutral/
                -- reverse into 1st is a launch, not an upshift — never drag those revs down.
                local isUpshift = shifting and shiftFromGear >= 1
                                  and (targetGear > shiftFromGear) and (targetGear >= 1)
                local upTarget  = isUpshift and Config.Gearbox.UpshiftRevDrop
                                  and projectRpmFor(targetGear, state) or nil
                if upTarget and state.rpm > upTarget then
                    -- FIXED-RATE engine-brake assist: pull rpm down at a constant rate
                    -- (rpm units/sec), FLOORED at the target so it can't lug and never
                    -- snaps. (No seq RPM-push here — that lives in the mode-6 branch.)
                    local drop = (Config.Gearbox.UpshiftRevDropPerS or 6.0) * dt
                    local nr = state.rpm - drop
                    if nr < upTarget then nr = upTarget end
                    vl_setRpmRaw(veh, nr)
                else
                    -- keep engine alive at throttle while decoupled (downshift / clutch
                    -- hold / unlearned gear). RATE-based + dt-scaled.
                    -- MANUAL-ONLY rate (Manual.RevRaiseRate, halved from the shared 22.0)
                    -- so the downshift rev-match no longer feeds back too much rpm.
                    local M = Config.Gearbox.Manual or {}
                    local t = vl_getThrottleOffset(veh)
                    local rate = (M.RevRaiseRate or Config.Gearbox.RevRaiseRate or 22.0) * di * dt
                    if state.rpm < t then vl_setRpmRaw(veh, state.rpm + (t * rate)) end
                end
            end
        else
            if odf then setDriveForce(veh, gbDriveForceLive or odf) end
            -- REVERSE GEAR rev-feed (2026-08-14 rework). Reverse is coupled (not clutchActive), so it
            -- lands here — but the native rpm rides wheelspeed, which stays flat because ReverseCap holds
            -- the car slow. So PAINT rpm to track the W throttle: a short low reverse gear that revs
            -- SLOWLY toward a modest ceiling. Use state.throttle (physical W) — the vehicle throttle
            -- offset reads ~0 while our injection drives control 72. Idle when W released (engine-brake).
            if targetGear == -1 then
                local cfgR   = Config.Gearbox
                local t      = state.throttle or 0.0
                local idle   = (cfgR.Flywheel and cfgR.Flywheel.IdleRpm) or 0.20
                local revMax = cfgR.ReverseRevMax or 0.55
                local target = idle + (revMax - idle) * t
                if target < idle then target = idle end
                local rising = target > (state.rpm or idle)
                local rate   = (rising and (cfgR.ReverseRevRaiseRate or 4.0)
                                       or (cfgR.ReverseRevFallRate or 6.0)) * dt
                if rate > 1.0 then rate = 1.0 end
                local nr = (state.rpm or idle) + (target - (state.rpm or idle)) * rate
                if nr < 0.0 then nr = 0.0 elseif nr > 1.0 then nr = 1.0 end
                vl_setRpmRaw(veh, nr)
            end
        end

        -- POST-SHIFT POWER MULTIPLIER (boost/bog). Applies once torque is no
        -- longer cut by the clutch (i.e. after the gear commits), for the hold
        -- window. Multiplies HK.torqueMult so it composes with TC/ESC/etc.
        if now < shiftPowerUntil then
            if not clutchActive then
                HK.torqueMult = HK.torqueMult * shiftPowerMult
            end
        else
            shiftPowerMult = 1.0
        end

        -- SOFT STALL (manual only — auto returned above). Lugging the engine —
        -- too high a gear at too-low rpm, off-clutch, not shifting — bleeds power
        -- HARD but never kills the engine. Recovers as rpm climbs / clutch in.
        if not clutchActive and not shifting then
            learnGearRatio(state, targetGear)   -- feed the shared ratio table
            -- TEMP PROBE: correlate live rpm/speed + learned ratio with the native
            -- GetVehicleGearRatio (used to derive the ratio-seed K). Throttled.
            if Config.Gearbox.RatioProbeDebug and targetGear >= 1 and (state.speedKmh or 0) > 15.0
               and now > (_ratioProbeAt or 0) then
                _ratioProbeAt = now + 600
                print(('[hk-ratioprobe2] gear=%d rpm=%.3f spd=%.1f rpmPerKmh=%.4f learned=%.4f nativeRatio=%.3f')
                    :format(targetGear, state.rpm, state.speedKmh or 0,
                            (state.speedKmh > 0) and (state.rpm / state.speedKmh) or -1,
                            gbRpmPerSpeed[targetGear] or -1, GetVehicleGearRatio(veh, targetGear) or -1))
            end
            if targetGear >= (Config.Gearbox.StallMinGear or 2)
               and state.rpm < (Config.Gearbox.StallThreshold or 0.18) then
                HK.torqueMult = HK.torqueMult * (Config.Gearbox.StallPowerMult or 0.25)
            end
            -- Lugging floor (keep a little pull) then rev-limiter (cap top speed
            -- per gear). Skip while clutching so they don't fight the clutch.
            applyLugFloor(state, targetGear)
            applyRevLimiter(state, targetGear, veh)
        end

        -- DEBUG: print clutch state transitions so we can see the chain.
        if Config.Gearbox.Debug and clutchActive ~= _dbgClutchPrev then
            _dbgClutchPrev = clutchActive
            print(('[hk-gearbox] clutchActive=%s held=%s shifting=%s gear=%s torqueMult=%s')
                :format(tostring(clutchActive), tostring(clutchHeld), tostring(shifting),
                        tostring(targetGear), tostring(HK.torqueMult)))
        end
    end

    -- LAUNCH SURGE (true-manual). Fading boost + traction-control + grip-assist after a
    -- manual launch fired (N -> 1 upshift out of the staged neutral). No-op unless lcPhase
    -- is 'launched', so it's safe to call every manual drive frame. Mirrors the DCT-auto
    -- call site — composes with HK.torqueMult like the rest of the drive-frame power work.
    launchBoostApply(state)

    -- REVERSE / STANDSTILL input arbitration (2026-08-14 rework: W drives reverse, S always brakes).
    HK.inReverseGear = (targetGear == -1)
    if targetGear == -1 then
        local injecting = HK.pedalModelOn and not HK._injAnalog and not HK.driftMode
        if injecting then
            -- REVERSE GEAR, injecting. Control 72 can't be shared with physical S, so DISABLE BOTH 71 and
            -- 72 (no native throttle/brake/reverse) and drive reverse DIRECTLY by velocity in
            -- HK.ReverseDrive_Tick (W = accel backward, S = brake, neither = coast, capped). No control
            -- writes = no wheelspin, no key leak. rpm painted by the reverse rev-feed above.
            DisableControlAction(0, 71, true)
            DisableControlAction(0, 72, true)
        elseif state.forwardSpeed > -2.0 then
            DisableControlAction(0, 71, true)   -- analog/off: native S-reverse applies, just block W-accel
        end
    elseif targetGear >= 0 then
        -- FORWARD GEAR *or* NEUTRAL, near standstill: native control 72 (S) is the reverse-accelerator
        -- in native gear 0, so a held S REVS the engine / tries to crawl backward (the "S revs in
        -- neutral" bug). S is a pure brake now, so kill native 72 at a stop — braking STRENGTH still
        -- flows through fBrakeForce, and once rolling (forwardSpeed >= 0.5) 72 goes live again so S
        -- brakes normally. EXCEPTION: keep 72 LIVE ONLY for the DRIFT-mode burnout (Step-2 power-
        -- brake). The Step-1 free-rev plants via torqueMult=0, so it does NOT need 72 — leaving it
        -- live there let native gear 0 + held S flash to REVERSE on W-release (the N->R->1 / split-R
        -- bugs). So exempt only the drift burnout, matching HK.autoStandstillBrake.
        if state.forwardSpeed < 0.5 and not (HK.driftMode and HK.burnoutGestureLive(state)) then
            DisableControlAction(0, 72, true)
            -- BRAKE LIGHT near idle: disabling 72 kills GTA's native brake lamp (it follows the brake
            -- control), so a held S at low speed showed no brake light. Drive it directly off the physical
            -- S key here — ON while braking, OFF otherwise — mirroring the reverse-gear brake-light fix.
            HK.setStandstillBrakeLight(veh, (HK._pedalBrake or 0.0) > 0.05)
        end
    end

    -- Pin the selected gear every frame WHEN NOT shifting (auto-box guard).
    if not shifting then
        local ng = nativeGear(targetGear)
        if vl_getCurrentGear(veh) ~= ng then vl_setCurrentGear(veh, ng) end
    end
    return
    end  -- end MODE 1 (classic manual)
end




-----------------------------------------------------------------
-- DISABLE — undo everything, restore from our own origins snapshot.
-----------------------------------------------------------------
function Gearbox_Disable(veh)
    if not applied then
        -- still clear transient flags even if we never fully enabled
        toggled, flagged, processGearbox = false, false, false
        return
    end
    applied = false
    veh = (veh and veh ~= 0) and veh or curVeh

    -- Always clear reduced-gear-ratio even if the entity is gone — the flag
    -- persists on the model pool and would carry over to the next spawn.
    if veh and veh ~= 0 then
        vl_setTransmissionReducedGearRatio(veh, false)
    end

    -- ENGINE AUDIO ON EXIT. A hybrid left in EV mode should KEEP its electric hum when
    -- parked / unoccupied. Previously we ALWAYS restored the stock ICE bank + cleared the
    -- replicated hk_ev_audio bag on exit, so the car snapped back to the engine note the
    -- instant the driver left (and again after "engine always on") — the reported bug.
    -- Now: if we exited in EV mode (hybridAudioForced is true only when NEON was actively
    -- forced, i.e. isHybrid + hybridEMode + EVAudioEnabled), LEAVE the 'NEON' bag set so
    -- every client keeps the EV sound on the parked car. A future driver's applyHybridAudio
    -- re-resolves it (ICE / preference-off -> ''). Only restore stock audio when NOT in EV mode.
    local keepEvAudio = hybridAudioForced
    if (not keepEvAudio) and veh and veh ~= 0 and DoesEntityExist(veh) and ForceVehicleEngineAudio then
        ForceVehicleEngineAudio(veh, '')
    end
    hybridAudioForced  = false       -- this driver session ends; the replicated bag now owns the state
    hybridAudioApplied = nil         -- next car re-resolves its audio from scratch
    -- Clear the REPLICATED audio statebag too, so other clients restore the stock engine
    -- (else the forced EV sound would linger on everyone else's client after we leave the car)
    -- -- but ONLY when NOT keeping EV audio; a parked EV-mode hybrid intentionally retains 'NEON'.
    if veh and veh ~= 0 and DoesEntityExist(veh) then
        pcall(function()
            local st = Entity(veh).state
            if (not keepEvAudio) and st and st.hk_ev_audio and st.hk_ev_audio ~= '' then
                st:set('hk_ev_audio', '', true)
            end
            -- Clear the pushed drive-state bag too (this car no longer runs our box, so its
            -- EV/hybrid/regen state is stale — the speedo should fall back to plain readings).
            if st and st.hk_drivestate ~= nil then
                st:set('hk_drivestate', nil, true)
            end
            -- Clear the RPM-sync bag so remote clients STOP forcing our last painted rpm on a car
            -- we no longer drive (else a parked/empty car would hold a stale engine note). Setting
            -- nil trips the remote applier's clear path; its staleness timer is the belt-and-braces.
            if st and st.hk_gearsync_rpm ~= nil then
                st:set('hk_gearsync_rpm', nil, true)
            end
        end)
    end
    lastDrivePubSig = nil               -- force a fresh publish for the next car
    if HK.gearsyncPub then HK.gearsyncPub.last, HK.gearsyncPub.at, HK.gearsyncPub.gear = -1.0, 0, -99 end  -- fresh gear+rpm publish next car
    HK.clutchEngage = 1.0               -- reset the clutch gauge feel (fully engaged) for the next car
    HK.clutchIsManual = false
    HK.gbManual = false                 -- clear the manual-feature gate for the next car (wheelie [F1])
    -- Flywheel engine-braking (Phase B): drop the live nudge + its anchor so the transient can't carry
    -- into the next car. The fDriveInertia restore below (origins.fDriveInertia) already unwinds the
    -- physics write; these just clear our bookkeeping so the next Enable re-derives cleanly.
    HK.flyBrakeNudge     = 0.0
    HK.flyInertiaApplied = nil
    HK.dbgFlyBrake       = nil
    HK.accelFlyApplied   = false        -- clear the accel-stretch flywheel latch for the next car

    if veh and veh ~= 0 and DoesEntityExist(veh) then
        -- Restore drivetrain fields from OUR snapshot (not handling.lua's
        -- originals[]) so nothing else clobbers it mid-drive. Direct write (NOT
        -- setDriveForce) — this cleanup must always land, never be deduped away.
        if origins then
            vl_setHandling(veh, 'fInitialDriveForce', origins.fInitialDriveForce)
            -- Restore the clutch-change rates we lowered for mode-2 comfort shifts.
            if origins.fClutchChangeRateScaleUpShift then
                vl_setHandling(veh, 'fClutchChangeRateScaleUpShift', origins.fClutchChangeRateScaleUpShift)
            end
            if origins.fClutchChangeRateScaleDownShift then
                vl_setHandling(veh, 'fClutchChangeRateScaleDownShift', origins.fClutchChangeRateScaleDownShift)
            end
            -- Restore drive inertia (seq mode 6 may have scaled it up).
            if origins.fDriveInertia then
                vl_setHandling(veh, 'fDriveInertia', origins.fDriveInertia)
            end
            -- Restore real top-speed in case we exited during hybrid EV-mode (tall-gear-1 raised it).
            if origins.fInitialDriveMaxFlatVel then
                vl_setHandling(veh, 'fInitialDriveMaxFlatVel', origins.fInitialDriveMaxFlatVel)
            end
        end
        -- Auto mode set an anti-hunt min-shift-time; clear it so the native box
        -- returns to normal when we leave the car.
        if autoMinSet then
            vl_setMinTimeBetweenGearShifts(veh, 0)
        end
    end

    toggled, flagged, processGearbox = false, false, false
    curVeh, origins, netEnt = 0, nil, nil
    lastDriveForce = nil
    driveForceCheckAt = 0
    HK.manualActive = false

    if Config.Speedo and Config.Speedo.AutoToggleWithManual and Speedo_SetVisible then
        Speedo_SetVisible(false)
    end

    dbg('DISABLED')
end

-----------------------------------------------------------------
-- RESET — clear module state on vehicle change/exit (CRIT-3 pattern).
-----------------------------------------------------------------
function Gearbox_Reset()
    resetShiftState()                          -- shared per-vehicle shift state
    -- Lifecycle / reset-only extras not in resetShiftState:
    applied, toggled, flagged, processGearbox = false, false, false, false
    curVeh, origins, netEnt, rhd = 0, nil, nil, false
    gearcount, gearMode = 1, 1
    clutchReadyAt = 0
    autoFastShift = false
    _dbgClutchPrev = nil
    -- WHEELSPIN-NEUTRAL LAUNCH gesture state (on HK.* — file at local ceiling). Clear so a stale
    -- armed/held flag from the last car can't phantom-fire gear 1 on the first frame of the next.
    if HK then
        HK.spinLaunchPrev, HK.spinLaunchArmedPrev, HK.spinHbPrev = false, false, false
        HK.spinHbHeldSince, HK.spinLaunchCooldown = nil, 0
    end
    -- PHASE 2 per-vehicle state (resolved fresh in Enable; cleared on stand-down here,
    -- NOT in resetShiftState which Enable calls AFTER resolving them).
    gbRatio = nil
    gbDriveForceLive = nil
    gbAccelTrim = 0.0
    gbSpeedCal = nil
    gbSpeedCalTargeted = false
    isEV = false                               -- per-vehicle; re-resolved in Enable
    isHybrid, hybridEMode, hybridEModePrev = false, false, false  -- per-vehicle; re-resolved in Enable
    eGearPinned = false          -- e-mode gear pin (reduced-ratio cleared by Disable)
    eReducedRatioOff = false     -- e-mode reduced-ratio-off latch
    hybridUserMode = 'ev'
    hybridCap, hybridPowerFrac = 130.0, 0.25
    evRegenLevel, evClutchPrev = 3, false
    regenCornerMult = 1.0
    if HK and HK.evRegen then                  -- clear the speedo signal on stand-down
        HK.evRegen.level, HK.evRegen.holding, HK.evRegen.active = 0.0, false, false
    end
    engineWritesSuspended = false              -- [F3] clear the SM latch on stand-down
    gbSuspended = false
    if HK then HK.manualActive = false; HK.gbSuspendCoast = false end  -- [F3] clear coast flag too
end

-----------------------------------------------------------------
-- EVENT BRIDGE — jim-mechanic triggers these event names verbatim, so we
-- listen on them as-is (this is jim's external integration API, not our code)
-- plus our own aliases.
-----------------------------------------------------------------
local function onActivate()
    local veh = driverVeh()
    -- IDEMPOTENCY GUARD (2026-07-27): jim re-fires enableManualGears on entry and its logic can
    -- re-ping. A redundant activate on a car we're ALREADY running (toggled already true, same
    -- veh, applied) must be a NO-OP — the Disable->Enable churn re-seeds per-vehicle state
    -- (evRegenLevel etc). Only do the re-resolution churn on a REAL transition (toggled was false
    -- = an upgrade just got installed and we need to pick up the new effective type/ratio).
    if toggled and applied and veh ~= 0 and veh == curVeh then
        return
    end
    toggled = true
    -- The jim gearbox upgrade was just (un)installed LIVE while seated. Force a
    -- re-resolution: Gearbox_Enable is idempotent (returns early if already applied
    -- to this car), so without a Disable first the upgrade remap would never take on
    -- a car the entry-watcher already enabled at its base type. Disable->Enable re-runs
    -- resolveEffective and picks up the new effective type+ratio.
    if applied and curVeh == veh and veh ~= 0 then
        gbLiveUpgrade = true     -- tell Enable to skip the neutral start (we're mid-session)
        Gearbox_Disable(veh)
    end
    toggled = true                              -- Disable cleared it; re-assert before Enable
    Gearbox_Enable(veh)
end

local function onDeactivate()
    -- IDEMPOTENCY GUARD (2026-07-27): jim-mechanic fires disableManualGears on entry for any car
    -- it considers non-manual (e.g. an EV like the Plaid), and its entered-vehicle logic can
    -- re-fire — each call did a full Disable->Enable, which RE-SEEDS per-vehicle state (notably
    -- evRegenLevel back to D3) = "EV regen stuck at D3, can't change" bug. onDeactivate exists to
    -- re-resolve after a jim gearbox UPGRADE is REMOVED (toggled was true); a redundant disable on
    -- an already-correctly-applied car must be a NO-OP. If we weren't running an upgrade (toggled
    -- false) and we're already applied to this same car, do nothing.
    local veh = (curVeh ~= 0 and curVeh) or driverVeh()
    if not toggled and applied and veh ~= 0 and veh == curVeh then
        return                                   -- already applied at base type -> nothing to redo
    end
    toggled = false
    -- Upgrade removed LIVE: re-resolve back to the base type instead of fully standing
    -- down, so the car keeps running our box at its DB/car-class default (the upgrade
    -- was an ADD-ON, not the only reason the box was active). Disable then re-Enable.
    Gearbox_Disable(veh)
    toggled = false
    if veh ~= 0 then Gearbox_Enable(veh) end
end

local function onEntered()
    -- Re-evaluate detection for the car just entered (handles flagged/list cars
    -- even without a jim activate event).
    Gearbox_Enable(driverVeh())
end

local function onExited()
    Gearbox_Disable(curVeh ~= 0 and curVeh or driverVeh())
end

-- ============================================================================
-- >>> JIM-MECHANIC BRIDGE <<<  (the ONLY place jim's event names live)
-- ----------------------------------------------------------------------------
-- These are jim-mechanic's legacy event names. GATED on Config.Gearbox.Jim.Enabled
-- — with jim off, none of this registers and the box runs fully on the
-- hk_handling DB table + car-class default (jim is NEVER a dependency).
--
-- REALITY CHECK (verified against the installed jim-mechanic, shared/helpers.lua):
-- jim ALREADY prefers our exports. Helper.enableManualGears/disableManualGears
-- call exports['hk-handling']:EnableManualGears/DisableManualGears whenever
-- hk-handling is started, and ONLY fall back to TriggerEvent('vlad_gears:*') when
-- it is NOT started. So in normal operation these 5 lines are a DEAD fallback —
-- they fire only in the brief window before hk-handling boots (when Enable is a
-- no-op anyway). `exited_listener` and `enabled` aren't fired by jim at all, even
-- in the fallback path. The export path (incl. NotifyEntered/NotifyExited below)
-- fully covers every handler.
--
-- KEEP regardless: this is the zero-cost safety net for (a) the pre-boot window
-- and (b) any other resource still using the legacy names. Deleting it is safe
-- but buys nothing; leave it gated until the jim author ships a dedicated bridge
-- (then this block goes, the exports stay).
-- ============================================================================
if Config.Gearbox and Config.Gearbox.Jim and Config.Gearbox.Jim.Enabled then
    RegisterNetEvent('vlad_gears:activate',         onActivate)
    RegisterNetEvent('vlad_gears:deactivate',       onDeactivate)
    RegisterNetEvent('vlad_gears:entered_listener', onEntered)
    RegisterNetEvent('vlad_gears:exited_listener',  onExited)
    RegisterNetEvent('vlad_gears:enabled',          function() Gearbox_Enable(driverVeh()) end)
end
-- <<< END JIM-MECHANIC BRIDGE >>>

-- ============================================================================
-- BRAKE-FORCE BUFF (2026-08-14) — Config.BrakeBoost. Uses the unused fBrakeForce x1.00 headroom to REWARD
-- a built-up car with stronger brakes. Two additive layers, both deltas on the x1.00 base:
--   (A) ALL-TIME: lambra chip / antilag / gearbox type (DCT or manual-seq) / native brake mod level.
--   (B) SPEED CURVE: extra bite phased in from 185→500 km/h (heavier car needs more stopping force up top).
-- Computed here (where gearMode/HK.dbgPublicType/antilag are all in scope) into HK.brakeBuffMult (>= 1.0);
-- main.lua composes it onto HK.brakeForceMult and widens the apply gate to cover buffs > 1.0.
--
-- CHIP STATE: lives in player_vehicles.lambrachip (server DB). We can't read it client-side, so we ask the
-- server (hk-handling:brakebuff:chipQuery, un-gated single-column read) whenever the plate we're driving
-- changes, and cache the boolean reply. Self-triggering off plate-change means it doesn't depend on entry
-- events firing in a particular order.
HK.brakeChipHas   = false     -- lambra chip present on the CURRENT vehicle (cached from server reply)
HK.brakeChipPlate = nil       -- plate the cached answer is for (invalidates the cache on vehicle change)
RegisterNetEvent('hk-handling:brakebuff:chipReply', function(plate, has)
    plate = tostring(plate or '')
    HK.brakeChipPlate = plate
    HK.brakeChipHas   = has == true
end)

-- Wrapped in a do-block: keeps brakeChipAsked + brakeSpeedDelta out of the main-chunk local pool
-- (this file rides the Lua 200-local ceiling — see memory). HK.BrakeBuff_Tick is a field, so it escapes.
do
local brakeChipAsked = { plate = nil, at = 0 }   -- last plate we queried + when (client-side debounce)

-- (B) speed curve: piecewise SMOOTHSTEP interpolation across Config.BrakeBoost.SpeedCurve knots.
-- Below the first knot -> 0; above the last -> held at the last delta.
local function brakeSpeedDelta(kmh)
    local BB = Config.BrakeBoost
    local curve = BB and BB.SpeedCurve
    if not curve or #curve == 0 then return 0.0 end
    if kmh <= curve[1][1] then return curve[1][2] end
    local last = curve[#curve]
    if kmh >= last[1] then return last[2] end
    for i = 1, #curve - 1 do
        local a, b = curve[i], curve[i + 1]
        if kmh >= a[1] and kmh <= b[1] then
            local span = b[1] - a[1]
            local t = (span > 0.001) and ((kmh - a[1]) / span) or 0.0
            local s = t * t * (3.0 - 2.0 * t)          -- smoothstep for a soft shoulder at each knot
            return a[2] + (b[2] - a[2]) * s
        end
    end
    return 0.0
end

-- Called once/frame from main.lua BEFORE the brake apply gate. Sets HK.brakeBuffMult (>= 1.0).
function HK.BrakeBuff_Tick(veh, state)
    HK.brakeBuffMult = 1.0
    local BB = Config.BrakeBoost
    if not BB or BB.Enabled == false then HK.dbgBrakeBuff = nil; return end
    if not veh or veh == 0 or not DoesEntityExist(veh) then HK.dbgBrakeBuff = nil; return end

    -- Keep the chip cache fresh: if the plate changed (new car), (re)query the server. Debounced so a
    -- transient plate read can't spam. GetVehicleNumberPlateText is stable per vehicle.
    local plate = GetVehicleNumberPlateText(veh)
    if plate then plate = plate:gsub('%s+$', '') end
    if plate and plate ~= '' then
        if plate ~= HK.brakeChipPlate and plate ~= brakeChipAsked.plate then
            local now = GetGameTimer()
            if now - (brakeChipAsked.at or 0) > 1200 then
                brakeChipAsked.plate = plate
                brakeChipAsked.at    = now
                TriggerServerEvent('hk-handling:brakebuff:chipQuery', plate)
            end
        end
    end
    -- Only trust the cached chip answer if it's for the plate we're actually driving.
    local chipOn = (HK.brakeChipHas == true and HK.brakeChipPlate == plate)

    -- (A) ALL-TIME additive buffs -------------------------------------------------
    local add = 0.0
    if chipOn then add = add + (BB.Chip or 0.0) end

    -- antilag (jim-mechanic) fitted — same statebag Turbo_Tick reads
    local alOn = false
    do
        local ok, v = pcall(function() return LocalPlayer.state.hk_antilag end)
        alOn = ok and v == true
    end
    if alOn then add = add + (BB.Antilag or 0.0) end

    -- gearbox TYPE by EFFECTIVE public type (post-upgrade): 3/4 = DCT (both variants), 1/5 = manual/seq.
    -- HK.dbgPublicType is set in Gearbox_Enable; nil/stale for cars we don't process (bonus just won't apply).
    local pt = HK.dbgPublicType
    if pt == 3 or pt == 4 then
        add = add + (BB.DctBonus or 0.0)
    elseif pt == 1 or pt == 5 then
        add = add + (BB.ManualBonus or 0.0)
    end

    -- native in-game brake upgrade: GetVehicleMod(veh,12) -> -1 none / 0,1,2 = level 1,2,3
    local bmLvl = GetVehicleMod(veh, 12)
    if bmLvl ~= nil and bmLvl >= 0 then
        local tbl = BB.BrakeMod
        local d = tbl and tbl[bmLvl + 1]
        if d then add = add + d end
    end

    -- (B) SPEED curve --------------------------------------------------------------
    local kmh = (state and state.speedKmh) or 0.0
    local spdAdd = brakeSpeedDelta(kmh)
    add = add + spdAdd

    -- clamp the SUM, then express as a multiplier on the x1.00 base
    local maxAdd = BB.MaxTotal or 1.20
    if add > maxAdd then add = maxAdd end
    if add < 0.0 then add = 0.0 end
    HK.brakeBuffMult = 1.0 + add

    if HK.hdbgOn then
        HK.dbgBrakeBuff = {
            mult   = HK.brakeBuffMult,
            chip   = chipOn,
            antilag= alOn,
            pt     = pt,
            bmLvl  = bmLvl,
            spd    = spdAdd,
            kmh    = kmh,
        }
    end
end
end   -- close do-block (brakeChipAsked / brakeSpeedDelta scope)

-- our own aliases (future-proof; same handlers)
RegisterNetEvent('hk-handling:gearbox:activate',   onActivate)
RegisterNetEvent('hk-handling:gearbox:deactivate', onDeactivate)
RegisterNetEvent('hk-handling:gearbox:entered',    onEntered)
RegisterNetEvent('hk-handling:gearbox:exited',     onExited)

-- Clean exports for jim-mechanic / other resources to drive the gearbox
-- directly, without relying on the legacy event names.
-- Mirrors jim's Helper.enableManualGears / disableManualGears signature.
exports('EnableManualGears', function(veh, plate)
    onActivate()
    onEntered()
end)
exports('DisableManualGears', function(veh, plate)
    onDeactivate()
end)

-- Granular entry/exit hooks (mirror onEntered/onExited from the event bridge).
-- These close the EXIT-path gap: jim's disable goes through onDeactivate (which
-- also clears `toggled`), so without these there was NO export route to the
-- exit-only handler. Any resource can now drive all four handlers via exports,
-- making the vlad_gears:* event names fully redundant (see bridge note above).
exports('NotifyEntered', function(veh, plate) onEntered() end)
exports('NotifyExited',  function(veh, plate) onExited()  end)

-- Authoritative DISPLAY gear for HUDs (jim-mechanic odometer reads this first).
-- Returns the LOGICAL gear the box is actually in:
--   'R'  reverse
--   'N'  neutral
--   1..gearcount  forward gear
-- MODE-AWARE: each gearMode tracks its live gear in a different variable —
--   modes 1 & 6 (manual w/clutch, sequential dogbox): targetGear (-1=R / 0=N / 1..n)
--   modes 3/4/5 (DCT):         dctNeutral flag for N; otherwise native gear
--                              (DCT leaves reverse to GTA, so read it natively)
--   mode 2 (comfort auto):     GTA owns the box -> return nil (native fallback)
-- Returns nil when our gearbox is NOT active on this vehicle, so the caller
-- can fall back to the GTA native gear for non-manual cars.
exports('GetDisplayGear', function(veh)
    if not applied then return nil end
    if veh and veh ~= 0 and curVeh ~= 0 and veh ~= curVeh then return nil end
    veh = (veh and veh ~= 0) and veh or curVeh

    -- FAKE GEAR 1 OVER NEUTRAL — REMOVED (2026-08-14 v6). Launch Control now engages a REAL gear 1 on
    -- stage (see launchStageTick), so the box genuinely reads 1 while staged — no display override, no
    -- fakeSpin1 branch. Every neutral return below is plain 'N' again.

    -- KEY-DRIVEN AUTO REVERSE display (comfort auto + pure EV, both gearMode 2). The D/N/R
    -- selector owns the display; pure EVs have no N (D or R only). Takes precedence over the
    -- legacy revGate read below. DCT-auto/hybrid still use revGate/dctReverse (handled after).
    if Config.Gearbox.ReverseGate and Config.Gearbox.ReverseGate.KeyDriven
       and (gearMode == 2 or isEV) then
        if HK.autoRevSel == 'R' then return 'R' end
        if HK.autoRevSel == 'N' then return 'N' end
        -- 'D': autoRevSel is AUTHORITATIVE for these modes — return the native FORWARD gear
        -- directly. Do NOT fall through to the legacy revGate reverse/neutral checks below:
        -- revGate is a shared local that can be left stale at 'reverse'/'neutral' from a prior
        -- state or another mode, which made the speedo STICK on R after leaving reverse.
        local ng = (veh ~= 0) and GetVehicleCurrentGear(veh) or 0
        if ng and ng >= 1 then return ng end
        return 1                     -- native still 0 (just left reverse this frame) -> show D/1
    end

    -- REVERSE GATE display (EV + comfort auto + DCT-auto): the gate owns R/N at a standstill,
    -- so it takes precedence over the per-mode gear read below. 'reverse' -> R, 'neutral' -> N.
    -- (DCT-auto also mirrors the gate into dctNeutral/dctReverse, handled in its branch below,
    -- but reading revGate here covers EV + comfort which have no gear machine of their own.)
    if revGate == 'reverse' then return 'R' end
    if revGate == 'neutral' then return 'N' end

    if gearMode == 1 or gearMode == 6 then
        -- manual (1) AND sequential dogbox (6): both drive targetGear directly
        if targetGear == -1 then return 'R' end
        if targetGear == 0  then return 'N' end
        return targetGear
    elseif gearMode == 3 or gearMode == 4 or gearMode == 5 then
        -- DCT: neutral is a flag. Forward gear = dctCommittedGear (the script's
        -- own authoritative gear; native lags during a shift window). Reverse is
        -- the one case GTA still owns, so detect it from the native gear.
        if dctNeutral then return 'N' end
        local ng = veh ~= 0 and GetVehicleCurrentGear(veh) or 0
        -- SIGNED longitudinal velocity: +forward / -backward. GetEntitySpeed (unsigned) can't tell
        -- the two apart, so a car REVERSING (native gear 0 + speed > 0.5) used to satisfy the
        -- "moving + native 0 = mid-shift" guard below and show the committed FORWARD gear instead
        -- of R (the "brake-held in gear 1, rolling back, speedo won't say R" bug). Use the signed
        -- forward component so a mid-shift blip (moving FORWARD, native momentarily 0) still trusts
        -- the committed gear, but any actual backward motion falls straight through to R.
        local relY = 0.0
        if veh ~= 0 then local sv = GetEntitySpeedVector(veh, true); relY = sv and sv.y or 0.0 end
        if ng == 0 and relY > 0.5
           and dctCommittedGear and dctCommittedGear >= 1 then
            -- moving FORWARD, native shows 0 mid-shift -> trust the committed forward gear
            return dctCommittedGear
        end
        if ng == 0 then
            -- KEY-DRIVEN: reverse is EXPLICIT (revGate=='reverse' handled above, or dctReverse).
            -- A bare native 0 here is NOT reverse — it's a stop/spawn where the box never bumped
            -- native to 1 (hybrid e-mode skips the DCT gear init, so a fresh spawn sits at native
            -- 0 = "R on the speedo at spawn" bug). Only call it R when actually rolling BACKWARD;
            -- otherwise show the committed forward gear (or D/1). Legacy path keeps native-0 = R.
            if Config.Gearbox.ReverseGate and Config.Gearbox.ReverseGate.KeyDriven then
                if dctReverse or relY < -0.5 then return 'R' end
                return (dctCommittedGear and dctCommittedGear >= 1) and dctCommittedGear or 1
            end
            return 'R'                          -- genuine native reverse / stop (legacy)
        end
        return (dctCommittedGear and dctCommittedGear >= 1) and dctCommittedGear or ng
    end
    -- mode 2 (comfort auto) or anything else: let the caller use native gear
    return nil
end)

-- Gearbox MODE for HUDs. Returns a string describing the DRIVER-FACING box feel:
--   "manual"  mode 1 (clutch manual), 6 (sequential dogbox), OR a DCT (3/4/5)
--             currently in paddle-manual sub-mode (dctManual == true)
--   "auto"    mode 2 (comfort auto), OR a DCT currently in its auto sub-mode
--   nil       our gearbox not active on this vehicle (raw GTA native)
-- Consumers (hk-speedo): "manual" => sport theme + gold perfect-shift eligible;
-- "auto" => eco theme, blue-only shift glow. DCT flips live as paddles engage.
exports("GetGearboxMode", function(veh)
    if not applied then return nil end
    if veh and veh ~= 0 and curVeh ~= 0 and veh ~= curVeh then return nil end
    if gearMode == 1 or gearMode == 6 then return "manual" end
    if gearMode == 3 or gearMode == 4 or gearMode == 5 then
        return dctManual and "manual" or "auto"
    end
    if gearMode == 2 then return "auto" end
    return nil
end)

-- BOX SELECTOR (hk-wheel wheel module / any consumer). Request a DCT auto<->manual sub-mode
-- flip from outside via a small inbound flag the tick consumes (see the DCT SUB-MODE SWITCH
-- block). mode: 'toggle' | 'auto' | 'manual'. Only meaningful on DCT tiers (3/4/5); ignored on
-- paddle-only/force-auto tiers and non-DCT modes. Additive + isolated — the tick routes it
-- through the same setDctManual() a clutch/paddle uses, so all neutral/reverse cleanup applies.
-- Returns true if a DCT box is active to receive it (so the caller can no-op UI otherwise).
exports("SetBoxMode", function(mode)
    if not applied then return false end
    if not (gearMode == 3 or gearMode == 4 or gearMode == 5) then return false end
    HK.reqBoxMode = (mode == 'auto' or mode == 'manual') and mode or 'toggle'
    return true
end)

-- Is the current car our COMFORT AUTO (PUBLIC type 0 = internal gearMode 2) and NOT an EV?
-- Used to gate features off the basic daily box (e.g. drift mode is blocked on mode 0, but
-- still allowed on EVs/hybrids/geared boxes). EVs also resolve to gearMode 2, so isEV excludes
-- them explicitly. Returns false if our box isn't applied (raw GTA car -> not "mode 0").
exports("IsComfortAuto", function(veh)
    if not applied then return false end
    if veh and veh ~= 0 and curVeh ~= 0 and veh ~= curVeh then return false end
    return gearMode == 2 and not isEV
end)

-- LAUNCH CONTROL state for HUDs (hk-speedo status box, etc.). Returns { active, phase, rpm }:
--   phase 'off'|'staged'|'launched'; active = staged or launched; rpm = staged target (0..1).
exports("GetLaunchState", function()
    local L = HK and HK.launch
    if not applied or not L then
        return { active = false, phase = 'off', rpm = 0.0, applied = false,
                 gearMode = -1, isEV = false, isHybrid = false, hybridEMode = false,
                 dctNeutral = false, revGate = 'n/a', dctManual = false }
    end
    -- DIAGNOSTIC fields: launch only runs inside a mode's NEUTRAL state, so expose the mode +
    -- neutral flags to see WHY staging isn't reached (usually: not actually in neutral).
    return { active = L.active == true, phase = L.phase or 'off', rpm = L.rpm or 0.0,
             applied = true, gearMode = gearMode, isEV = isEV == true,
             isHybrid = isHybrid == true, hybridEMode = hybridEMode == true,
             dctNeutral = dctNeutral == true, revGate = revGate or 'none',
             dctManual = dctManual == true,
             -- CLEAN per-frame pre-stage signals for the speedo LC pill (idle/prep looks):
             inNeutral = L.inNeutral == true, hb = L.hb == true,
             -- did the launch STAGE BLOCK run last frame, and what did launchStageTick see?
             lcSeen = HK.launch.dbgSeen or 'never', lcHb = HK.launch.dbgHb,
             lcHbRaw = HK.launch.dbgHbRaw, lcThr = HK.launch.dbgThr or 0,
             lcKmh = HK.launch.dbgKmh or 0,
             lcBrk = HK.launch.dbgBrk or 0, lcHeld = HK.launch.dbgHeld == true,
             lcStagedOnHb = HK.launchStagedOnHb == true,
             -- LAUNCH TELEMETRY (measurement harness): live pull + last completed result.
             teleActive = lcTele.active == true,
             teleG      = lcTele.peakG or 0.0,          -- peak long-g SO FAR this pull
             teleSlip   = lcTele.peakSlip or 0.0,       -- peak wheel-slip (m/s) so far
             tcCut      = HK.launchTcCut or 0.0,        -- live TC torque cut (0=none .. 1=full) — tuning readout
             teleLast   = lcTele.last }                 -- { t100, peakG, peakSlip, profile } or nil
end)

-- /lctele — reprint the last measured launch pull to F8 (measurement harness readout, so we can
-- tune boost/grip/slip per profile against real numbers with no speedo-side dependency).
RegisterCommand('lctele', function()
    local r = lcTele.last
    if not r then
        print('[hk-launch] no pull recorded yet — stage a launch (handbrake + full throttle in N) and go to 100 km/h.')
        return
    end
    print(('[hk-launch] LAST PULL [%s]  0-100: %.2fs  peakG: %.2f  peakSlip: %.1f m/s')
          :format(r.profile or '?', r.t100 or 0.0, r.peakG or 0.0, r.peakSlip or 0.0))
end, false)

-- /gbstate — dump the current car's gearbox flag state to F8. Use this the INSTANT a car is
-- stuck (won't move / ramps to a tall gear) and paste the line — it tells us exactly WHY:
-- stale isEV/eMode, stuck gbSuspended, reduced-ratio intent, mode, etc. No global debug needed.
RegisterCommand('gbstate', function()
    local veh = GetVehiclePedIsIn(PlayerPedId(), false)
    local modelElec = 'n/a'
    if veh and veh ~= 0 then
        local ok, e = pcall(GetIsVehicleElectric, GetEntityModel(veh))
        modelElec = ok and tostring(e) or 'err'
    end
    -- PHYSICAL drivetrain truth (natives) — this is what actually matters, not just our flags.
    local nativeGear, highGear, curRatio, driveForce, maxFlatVel, rpm, kmh = -1, -1, -1, -1, -1, -1, -1
    if veh and veh ~= 0 then
        nativeGear = GetVehicleCurrentGear(veh)
        highGear   = GetVehicleHighGear(veh)
        curRatio   = GetVehicleGearRatio(veh, nativeGear) or -1
        driveForce = GetVehicleHandlingFloat(veh, 'CHandlingData', 'fInitialDriveForce')
        maxFlatVel = GetVehicleHandlingFloat(veh, 'CHandlingData', 'fInitialDriveMaxFlatVel')
        rpm        = GetVehicleCurrentRpm(veh)
        kmh        = GetEntitySpeed(veh) * 3.6
    end
    print(('[hk-gbstate] applied=%s mode=%s isEV=%s isHybrid=%s eMode=%s modelElec=%s | '
        .. 'gbSuspended=%s ratioWant=%s dctStarted=%s dctNeutral=%s dctNeutralRatioOff=%s '
        .. 'revGate=%s eReducedRatioOff=%s')
        :format(tostring(applied), tostring(gearMode), tostring(isEV), tostring(isHybrid),
                tostring(hybridEMode), modelElec, tostring(gbSuspended), tostring(HK.reducedRatioWant),
                tostring(dctStarted), tostring(dctNeutral), tostring(HK.dctNeutralRatioOff),
                tostring(revGate), tostring(eReducedRatioOff)))
    -- SECOND LINE = the physical truth. nativeGear vs highGear tells us if it's stuck in a HIGH
    -- gear; driveForce=0 = decoupled; maxFlatVel raised = top-speed uncapped; dctGear = our logical.
    print(('[hk-gbstate2] nativeGear=%d highGear=%d dctGear=%d dctCommitted=%d gearcount=%d | '
        .. 'gearRatio=%.3f driveForce=%.4f maxFlatVel=%.1f rpm=%.2f kmh=%.1f | torqueMult=%s')
        :format(nativeGear, highGear, dctGear, dctCommittedGear, gearcount,
                curRatio, driveForce, maxFlatVel, rpm, kmh, tostring(HK.torqueMult)))
    -- THIRD LINE = the IMMOBILIZATION truth. torqueMult=0.45 (mode-5 LowSpeedCut) + healthy
    -- drivetrain floats but "won't move" means the pin is a field the first two lines DON'T show:
    -- undriveable/frozen (a pool-resync or admin op can set these + never clear), handbrake actually
    -- ON, brake pressure pinned, traction curve zeroed, or engine off/dead. Read these before theorizing.
    if veh and veh ~= 0 then
        local undriveable = 'n/a'
        do local ok, r = pcall(function() return IsVehicleUndriveable and IsVehicleUndriveable(veh) end)
           if ok then undriveable = tostring(r) end end
        local frozen = 'n/a'
        do local ok, r = pcall(function() return IsEntityPositionFrozen and IsEntityPositionFrozen(veh) end)
           if ok then frozen = tostring(r) end end
        local hb      = tostring(GetVehicleHandbrake(veh))
        local engOn   = tostring(GetIsVehicleEngineRunning(veh))
        local engH    = GetVehicleEngineHealth(veh)
        local bodyH   = GetVehicleBodyHealth(veh)
        local tcMax   = GetVehicleHandlingFloat(veh, 'CHandlingData', 'fTractionCurveMax')
        local brakeF  = GetVehicleHandlingFloat(veh, 'CHandlingData', 'fBrakeForce')
        local mass    = GetVehicleHandlingFloat(veh, 'CHandlingData', 'fMass')
        local thr     = HK.state and HK.state.throttle or -1
        print(('[hk-gbstate3] undriveable=%s frozen=%s handbrake=%s engineOn=%s engH=%.0f bodyH=%.0f | '
            .. 'tractionMax=%.3f brakeForce=%.3f mass=%.0f thr=%.2f gbSuspended=%s')
            :format(undriveable, frozen, hb, engOn, engH, bodyH,
                    tcMax, brakeF, mass, thr, tostring(gbSuspended)))
        -- FOURTH LINE = the per-gear RATIO SPACING. For each forward gear we print the raw
        -- native ratio, the seeded rpmPerKmh (gbRpmPerSpeed), and the theoretical top speed of
        -- that gear at redline (topKmh = K*maxFlatVel/ratio). If gears 7/8/9 all top out at
        -- nearly the same kmh (or DROP), the transmission mod squeezed too many gears into the
        -- same speed band -> tall gears add revs but no road speed. This is the ground truth
        -- for the "7>8>9 no speed gain" bug -- read the spacing before touching any ratios.
        local K   = (Config.Gearbox and Config.Gearbox.RatioSeedK) or 1.199
        local mfv = GetVehicleHandlingFloat(veh, 'CHandlingData', 'fInitialDriveMaxFlatVel')
        local hg  = GetVehicleHighGear(veh)
        -- nInitialDriveGears = the .meta DESIGN gear count. If this reads 6 while highGear=9,
        -- the mod added 3 folded gears and the box should cap at 6 (our GearCountCap target).
        -- If it ALSO reads 9, the mod bumped the handling int too -> stock-cap can't fire and
        -- we fall back to the ratio-walk. gearcount = the CAP we actually applied this Enable.
        local ndg = GetVehicleHandlingInt(veh, 'CHandlingData', 'nInitialDriveGears')
        -- HEADER line, then ONE LINE PER GEAR so long consoles can't truncate the ratio spread.
        print(('[hk-gbstate4] K=%.3f mfv=%.1f highGear=%d nInitialDriveGears=%d cappedGearcount=%d')
            :format(K, mfv or -1, hg or -1, ndg or -1, gearcount or -1))
        -- Loop the FULL physical range (highGear) so the fold is still visible, but TAG each gear:
        -- [USED] = within gearcount (the box actually shifts here); [CUT] = trimmed by the useful-gear
        -- cap (crushed/folded — shown for diagnosis but never driven). This is why g7/g8/g9 appear.
        for g = 1, (hg or 0) do
            local r   = GetVehicleGearRatio(veh, g) or 0
            local rps = gbRpmPerSpeed[g] or -1
            local top = (r and r > 0 and mfv and mfv > 0) and (K * mfv / r) or -1
            local tag = (gearcount and g <= gearcount) and 'USED' or 'CUT '
            print(('[hk-gbstate4]   [%s] g%d ratio=%.3f rps=%.4f topKmh=%.0f'):format(tag, g, r, rps, top))
        end
    end
end, false)

-- /gbratioflip — DEFINITIVE probe for the "clean-when-stopped, folds-after-a-pull" bug on the
-- fully-modded 911ts. Same car showed TWO ratio tables at the same mfv/highGear: monotonic to 334
-- when just entered, folded (g7=389 peak, g8/g9 shorter) after a full-throttle pull. The ONLY thing
-- we touch every frame that affects ratios is SetVehicleTransmissionReducedGearRatio(veh,true). This
-- command dumps the LIVE table, forces reduced-ratio OFF, waits a few frames, dumps again, then
-- restores whatever the mode wanted. If the table snaps from FOLDED back to MONOTONIC when we turn
-- reduced-ratio OFF, that native is the folder and the fix is to stop forcing it on this car.
-- Run it WHILE the car is in the folded state (right after a top-speed pull), not from a standstill.
RegisterCommand('gbratioflip', function()
    local veh = GetVehiclePedIsIn(PlayerPedId(), false)
    if not veh or veh == 0 then print('[hk-ratioflip] not in a vehicle'); return end
    local K   = (Config.Gearbox and Config.Gearbox.RatioSeedK) or 1.199
    local hg  = GetVehicleHighGear(veh) or 0
    local function dumpTable(label)
        local mfv = GetVehicleHandlingFloat(veh, 'CHandlingData', 'fInitialDriveMaxFlatVel') or -1
        print(('[hk-ratioflip] --- %s (mfv=%.1f highGear=%d) ---'):format(label, mfv, hg))
        local last, folds = nil, 0
        for g = 1, hg do
            local r   = GetVehicleGearRatio(veh, g) or 0
            local top = (r > 0 and mfv > 0) and (K * mfv / r) or -1
            local fold = (last and r >= last) and ' <FOLD' or ''
            if last and r >= last then folds = folds + 1 end
            print(('[hk-ratioflip]   g%d ratio=%.4f topKmh=%.0f%s'):format(g, r, top, fold))
            last = r
        end
        print(('[hk-ratioflip]   folds=%d (0 = clean monotonic)'):format(folds))
    end
    dumpTable('BEFORE (live, reduced-ratio as-driven)')
    -- Force reduced-ratio OFF and hold it a few frames so GTA can re-lay the table. We must also
    -- suppress the every-frame re-assert while we look, so stamp the mirror OFF too.
    HK.reducedRatioWantOn = false
    HK.dctNeutralRatioOff = true      -- makes the every-frame gate compute wantOn=false for DCT modes
    for _ = 1, 8 do
        vl_setTransmissionReducedGearRatio(veh, false)
        Wait(0)
    end
    dumpTable('AFTER reduced-ratio=OFF')
    print('[hk-ratioflip] Compare the two tables + fold counts. If OFF is monotonic and BEFORE '
        .. 'folded, the reduced-ratio native is the folder. The mode will re-assert its intended '
        .. 'reduced-ratio state on the next tick automatically.')
end, false)

-- /gbwhy — dump the live TORQUE-DELIVERY state at the instant the car is stuck. The "loses torque,
-- coasts to 0, can't accelerate" bug has only a few possible causes and this names which: (1) drive
-- force actually 0 on the entity (torque source dead), (2) the rev-limiter SPEED-CAP pinned on with a
-- bad rps -> capKmh too low -> torque killed + throttle(71) disabled + self-brake (car can't escape),
-- (3) HK.torqueMult driven to 0 by some other layer. Run it WHILE stuck. Reads live natives, no writes.
RegisterCommand('gbwhy', function()
    local veh = GetVehiclePedIsIn(PlayerPedId(), false)
    if not veh or veh == 0 then print('[hk-why] not in a vehicle'); return end
    local g    = GetVehicleCurrentGear(veh)
    local liveDF = GetVehicleHandlingFloat(veh, 'CHandlingData', 'fInitialDriveForce')
    local rps  = gbRpmPerSpeed[g]
    local red  = (Config.Gearbox and Config.Gearbox.RevLimiterRedline) or 0.985
    local capKmh = (rps and rps > 0) and (red / rps) or -1
    local kmh  = GetEntitySpeed(veh) * 3.6
    local thr  = GetControlNormal(0, 71)
    print(('[hk-why] gear=%d kmh=%.0f | LIVE driveForce=%.4f (mirror lastDF=%s gbDriveForceLive=%s origins=%s)')
        :format(g, kmh, liveDF or -1, tostring(lastDriveForce),
                tostring(gbDriveForceLive), tostring(origins and origins.fInitialDriveForce)))
    print(('[hk-why] LIMITER on=%s why=%s byCap=%s | rps[g%d]=%s capKmh=%.0f (car stuck AT capKmh => bad rps) redline=%.3f')
        :format(tostring(HK.gbLimiterOn), tostring(HK.gbLimiterWhy), tostring(HK.gbLimiterByCap),
                g, tostring(rps), capKmh, red))
    print(('[hk-why] torqueMult=%s throttle(71)=%.2f | if LIM=cap + kmh~=capKmh, the '
        .. 'rev-limiter speed-cap is pinning it (bad rps from a folded-table seed).')
        :format(tostring(HK.torqueMult), thr))
    local u = HK.dbgUp
    if u then
        local age = GetGameTimer() - (u.at or 0)
        print(('[hk-why] UPSHIFT gate (age=%dms): gear=%s/%s | rpm=%.3f>=upRpm=%.3f? %s  pinned=%s  '
            .. 'moving=%s  nextOk=%s  rpmGrounded=%s  coastAllowsUp=%s  airUpBlocked=%s')
            :format(age, tostring(u.gear), tostring(u.gearcount), u.rpm or -1, u.upRpm or -1,
                    tostring((u.rpm or 0) >= (u.upRpm or 1)), tostring(u.pinned), tostring(u.moving),
                    tostring(u.nextOk), tostring(u.rpmGrounded), tostring(u.coastAllowsUp),
                    tostring(u.airUpBlocked)))
        print(('[hk-why]   detail: atLimiter=%s nextProj=%s curProj=%s dsThr=%s  '
            .. '(FALSE term(s) above = what blocks the upshift)')
            :format(tostring(u.atLimiter), tostring(u.nextProj), tostring(u.curProj), tostring(u.dsThr)))
    end
end, false)

-- /gbmfvclamp [on|off] — toggle the every-frame maxFlatVel clamp live. THEORY: the clamp's
-- SetVehicleHandlingFloat(fInitialDriveMaxFlatVel) write makes GTA recompute the drivetrain, which
-- resets reduced-gear-ratio to OFF (folded native table) + transiently zeros drive force = the
-- "loses torque a moment after moving, stuck at idle" bug on the lambra-chipped 911ts. Turn it OFF
-- and drive: if the torque-loss/fold STOPS, the clamp is the culprit. (Top speed may drift up a
-- little with the chip's raise ungoverned — that's expected and fine for the test.)
RegisterCommand('gbmfvclamp', function(_, a)
    local arg = (a and a[1]) or (HK.mfvClampOff and 'on' or 'off')
    HK.mfvClampOff = (arg == 'off')
    print(('[hk-mfvclamp] every-frame maxFlatVel clamp is now %s. Drive and watch for the torque-loss.')
        :format(HK.mfvClampOff and 'OFF (disabled)' or 'ON (enabled)'))
end, false)

-- /gbstockprobe — VERIFICATION for the "strip-to-stock + re-layer mods ourselves" architecture.
-- Records the CURRENT (modded) drivetrain, strips the drivetrain-affecting mods (engine slot 11 +
-- transmission slot 13), waits for GTA to FULLY settle (not 1 frame — the recompute lag we've been
-- fighting all session), and dumps the resulting table. What we're proving:
--   (1) stripped table is MONOTONIC (folds=0) — stock ratios never fold, unlike the modded table.
--   (2) stripped table is STABLE — the value stops changing once settled (deterministic basis).
--   (3) captures the exact stock mfv + per-gear ratios = the numbers the new baseline is built on.
-- Then it RESTORES the mods so nothing is left changed. This is LOCAL/cosmetic only (SetVehicleMod
-- client-side); the server's qb inventory is untouched, and re-entering the car re-syncs truth.
RegisterCommand('gbstockprobe', function()
    local veh = GetVehiclePedIsIn(PlayerPedId(), false)
    if not veh or veh == 0 then print('[hk-stock] not in a vehicle'); return end
    SetVehicleModKit(veh, 0)     -- REQUIRED before GetVehicleMod reads are valid
    local K  = (Config.Gearbox and Config.Gearbox.RatioSeedK) or 1.199
    local function dump(label)
        local hg  = GetVehicleHighGear(veh) or 0
        local mfv = GetVehicleHandlingFloat(veh, 'CHandlingData', 'fInitialDriveMaxFlatVel') or -1
        local ndg = GetVehicleHandlingInt(veh, 'CHandlingData', 'nInitialDriveGears') or -1
        local last, folds = nil, 0
        local parts = {}
        for g = 1, hg do
            local r = GetVehicleGearRatio(veh, g) or 0
            if last and r >= last then folds = folds + 1 end
            parts[#parts+1] = ('g%d=%.4f'):format(g, r)
            last = r
        end
        print(('[hk-stock] %s: mfv=%.1f highGear=%d nInitialDriveGears=%d folds=%d | %s')
            :format(label, mfv, hg, ndg, folds, table.concat(parts, ' ')))
        return mfv, hg
    end
    -- Snapshot what we're about to strip so we can put it back exactly.
    local eng   = GetVehicleMod(veh, 11)
    local trans = GetVehicleMod(veh, 13)
    local turbo = IsToggleModOn(veh, 18)
    print(('[hk-stock] captured mods: engine(11)=%d transmission(13)=%d turbo(18)=%s')
        :format(eng, trans, tostring(turbo)))
    dump('MODDED (before strip)')
    -- STRIP the drivetrain-affecting mods so GTA lays the STOCK table.
    RemoveVehicleMod(veh, 11)
    RemoveVehicleMod(veh, 13)
    ToggleVehicleMod(veh, 18, false)
    -- SETTLE WATCH: poll until the table stops changing (top-gear ratio stable across 3 reads) or ~1.5s.
    local prevTop, stableFor = nil, 0
    for i = 1, 30 do            -- 30 * 50ms = 1.5s max
        Wait(50)
        local hg = GetVehicleHighGear(veh) or 0
        local top = GetVehicleGearRatio(veh, hg) or 0
        if prevTop and math.abs(top - prevTop) < 0.0005 then
            stableFor = stableFor + 1
            if stableFor >= 3 then
                print(('[hk-stock] settled after %dms'):format(i * 50))
                break
            end
        else
            stableFor = 0
        end
        prevTop = top
    end
    dump('STOCK (stripped + settled)')
    -- RESTORE the mods exactly as they were.
    if eng   >= 0 then SetVehicleMod(veh, 11, eng, false) end
    if trans >= 0 then SetVehicleMod(veh, 13, trans, false) end
    if turbo then ToggleVehicleMod(veh, 18, true) end
    Wait(200)
    dump('RESTORED (mods back)')
    print('[hk-stock] DONE. Want: STOCK line folds=0 (clean) + its mfv/ratios are the deterministic '
        .. 'baseline. If STOCK is clean+stable, the strip-to-stock architecture is viable.')
end, false)

-- /gbgeartest — VERIFICATION for the AUTHORITATIVE-WRITER architecture. Proves whether we can DIRECTLY
-- author the gear count + ratio band with SET_VEHICLE_HIGH_GEAR (0x20B1B3E6) and SET_VEHICLE_GEAR_RATIO
-- (0x496EF2F2), instead of toggling reduced-ratio and accepting GTA's table. What each phase proves:
--   T1 WRITE+READBACK: does SetVehicleGearRatio actually take? (write a known clean band, read it back)
--   T2 HOLD:           do the values survive 3s of just sitting (no re-assert)? or does GTA overwrite?
--   T3 RESETUP CLOBBER: does ModifyVehicleTopSpeed (the transmission re-setup we MUST call for mfv/force
--                       to apply) wipe our ratios? This is the load-bearing question — if the recompute
--                       clobbers, we must re-write ratios AFTER every ModifyVehicleTopSpeed, per frame.
--   T4 HIGHGEAR:       does SetVehicleHighGear change the LIVE count (unlike baked nInitialDriveGears)?
-- Pure client/local, restores nothing destructive (re-entering the car re-syncs truth). Freezes the
-- tick reduced-ratio re-assert via HK.ratioProbeHold so it can't fight the probe.
RegisterCommand('gbgeartest', function()
    local veh = GetVehiclePedIsIn(PlayerPedId(), false)
    if not veh or veh == 0 then print('[hk-geartest] not in a vehicle'); return end
    SetVehicleModKit(veh, 0)
    HK.ratioProbeHold = true      -- stop the per-frame reduced-ratio re-assert during the probe
    local function snap(label)
        local hg  = GetVehicleHighGear(veh) or 0
        local last, folds, parts = nil, 0, {}
        for g = 1, hg do
            local r = GetVehicleGearRatio(veh, g) or 0
            if last and r >= last then folds = folds + 1 end
            parts[#parts+1] = ('g%d=%.4f'):format(g, r)
            last = r
        end
        print(('[hk-geartest] %s: highGear=%d folds=%d | %s'):format(label, hg, folds, table.concat(parts, ' ')))
        return hg
    end

    snap('BEFORE (live table)')
    local hg = GetVehicleHighGear(veh) or 0
    if hg < 2 then print('[hk-geartest] highGear<2 (EV/single-gear) — abort'); HK.ratioProbeHold = nil; return end

    -- T1: write a KNOWN clean monotonic band (3.5 -> 0.7 spread across gears) and read it straight back.
    print('[hk-geartest] T1: writing clean band via SetVehicleGearRatio...')
    local top, bottomR = 3.50, 0.70
    for g = 1, hg do
        local t = (hg > 1) and ((g - 1) / (hg - 1)) or 0.0
        SetVehicleGearRatio(veh, g, top + (bottomR - top) * t)
    end
    snap('T1 AFTER write (want: matches 3.50..0.70, folds=0)')

    -- T2: HOLD test — sit 3s doing nothing, see if GTA overwrites our band on its own.
    print('[hk-geartest] T2: holding 3s (no re-assert)...')
    CreateThread(function()
        Wait(3000)
        snap('T2 AFTER 3s idle (want: SAME as T1 = GTA did NOT clobber)')

        -- T3: force a transmission re-setup (required for mfv/driveForce writes). Does it wipe ratios?
        print('[hk-geartest] T3: ModifyVehicleTopSpeed(0.0) then re-read (does re-setup clobber our band?)...')
        ModifyVehicleTopSpeed(veh, 0.0)
        Wait(100)
        snap('T3 AFTER ModifyVehicleTopSpeed (if CHANGED = must re-write ratios after every re-setup)')

        -- T4: SetVehicleHighGear — does it change the LIVE count? (nInitialDriveGears can't, it's baked.)
        local ndg = GetVehicleHandlingInt(veh, 'CHandlingData', 'nInitialDriveGears') or -1
        print(('[hk-geartest] T4: nInitialDriveGears(meta)=%d, current highGear=%d — setting highGear=%d...')
            :format(ndg, GetVehicleHighGear(veh) or 0, hg))
        SetVehicleHighGear(veh, hg)
        Wait(100)
        print(('[hk-geartest] T4 AFTER SetVehicleHighGear: highGear=%d'):format(GetVehicleHighGear(veh) or 0))

        HK.ratioProbeHold = nil
        print('[hk-geartest] DONE. Re-enter the vehicle to restore GTA-native ratios. '
            .. 'KEY READS: T1 folds=0 & values match = write works. T2 same = holds without re-assert. '
            .. 'T3 changed = re-setup clobbers (write ratios AFTER ModifyVehicleTopSpeed). T4 = live count writable.')
    end)
end, false)

-- /gbauthband — Phase 1 authoritative-band status. Shows whether the flag is on, whether a clean band
-- was captured for THIS car, the cached band vs the LIVE ratio table (they should match when active),
-- and the mfv/force anchors. Use to confirm the authored table is holding against GTA's fold.
RegisterCommand('gbauthband', function()
    local on = Config.Gearbox and Config.Gearbox.AuthoritativeBand
    print(('[hk-authband] flag=%s ready=%s key=%s')
        :format(tostring(on), tostring(HK.authBandReady), tostring(HK.cleanBandKey)))
    local veh = GetVehiclePedIsIn(PlayerPedId(), false)
    if not veh or veh == 0 then print('[hk-authband] not in a vehicle'); return end
    local band = HK.cleanBand
    if band then
        local bp = {}
        for g = 1, band.n do bp[#bp+1] = ('g%d=%.4f'):format(g, band.r[g]) end
        print(('[hk-authband] CACHED band: n=%d mfv=%.1f force=%.4f | %s')
            :format(band.n, band.mfv or -1, band.force or -1, table.concat(bp, ' ')))
    else
        print('[hk-authband] no cached band for this car (flag off, EV/single-gear, or table still folded)')
    end
    -- LIVE table (what physics currently holds) + fold count.
    local hg, last, folds, lp = GetVehicleHighGear(veh) or 0, math.huge, 0, {}
    for g = 1, hg do
        local r = GetVehicleGearRatio(veh, g) or 0
        if g > 1 and r >= last then folds = folds + 1 end
        lp[#lp+1] = ('g%d=%.4f'):format(g, r); last = r
    end
    local liveMfv = GetVehicleHandlingFloat(veh, 'CHandlingData', 'fInitialDriveMaxFlatVel') or -1
    print(('[hk-authband] LIVE table: highGear=%d folds=%d mfv=%.1f | %s')
        :format(hg, folds, liveMfv, table.concat(lp, ' ')))
    print('[hk-authband] WANT (active): LIVE folds=0 AND LIVE matches CACHED = authored band is holding.')
end, false)

-- Shared dump of the latched worst torque-death frame. Called by /gbcap AND auto-printed by
-- TorqueCap_Watch the instant a sustained decel-under-throttle is confirmed (so the player never
-- has to type a command mid-throttle).
function HK.capDump()
    local w = HK.capWorst
    if not w then
        print('[hk-cap] no failure captured yet. Armed='..tostring(HK.capArmed)
            ..'. Drive until it loses torque (hold throttle, car stops gaining/coasts down).')
        return
    end
    print(('[hk-cap] WORST FRAME (%dms ago, run=%s frames): gear=%s curGear=%s kmh=%.0f drop=%.3fkm/h/frame thr=%.2f(raw=%.2f eff=%.2f ctrl71=%.2f) rpm=%.3f')
        :format(GetGameTimer() - (w.at or 0), tostring(w.runFrames), tostring(w.gear), tostring(w.curGear),
                w.kmh or -1, w.dropKmh or -1, w.thr or -1, w.rawThr or -1, w.effThr or -1,
                w.rawCtrl or -1, w.rpm or -1))
    print(('[hk-cap]   torqueMult=%s torqueApplied=%s | LIMITER on=%s byCap=%s why=%s')
        :format(tostring(w.torqueMult), tostring(w.torqueApplied),
                tostring(w.limOn), tostring(w.limByCap), tostring(w.limWhy)))
    print(('[hk-cap]   driveForce(LIVE)=%s mfv=%.1f liveRatio(g%s)=%s | gbSuspended=%s authReady=%s')
        :format(tostring(w.driveForce), w.mfv or -1, tostring(w.gear), tostring(w.liveRatio),
                tostring(w.gbSusp), tostring(w.authReady)))
    print(('[hk-cap]   DF restore chain: mirror(lastDF)=%s gbDriveForceLive=%s origins=%s')
        :format(tostring(w.dfMirror), tostring(w.dfLive), tostring(w.dfOrigin)))
    print(('[hk-cap]   external-zero catcher: hits=%s lastHitAgo=%sms (>0 hits = the chip/turbo IS zeroing df, and we caught it)')
        :format(tostring(HK.dfZeroCatchCount or 0),
                HK.dfZeroCatchLast and (GetGameTimer() - HK.dfZeroCatchLast) or 'never'))
    -- UPSHIFT DECISION terms (why the DCT is stuck in this gear). The gate requires ALL of:
    -- (rpm>=upRpm OR pinned) AND moving AND nextOk AND rpmGrounded AND coastAllowsUp AND not airBlocked.
    -- Whichever is false is why it won't shift up. If rpm<upRpm and the car can't rev higher = the
    -- "reaches top of gear but upRpm too high to trip" deadlock (upRpm inflated by ratio-profile mult).
    local u = HK.dbgUp
    if u then
        print(('[hk-cap]   UPSHIFT gate: gear=%s/%s rpm=%.3f upRpm=%.3f | rpm>=upRpm? %s pinned=%s moving=%s')
            :format(tostring(u.gear), tostring(u.gearcount), u.rpm or -1, u.upRpm or -1,
                    tostring((u.rpm or 0) >= (u.upRpm or 1)), tostring(u.pinned), tostring(u.moving)))
        print(('[hk-cap]     nextOk=%s rpmGrounded=%s coastAllowsUp=%s airBlocked=%s stallUp=%s | curProj=%s nextProj=%s dsThr=%s atLimiter=%s (%dms ago)')
            :format(tostring(u.nextOk), tostring(u.rpmGrounded), tostring(u.coastAllowsUp),
                    tostring(u.airUpBlocked), tostring(u.stallUp), tostring(u.curProj), tostring(u.nextProj),
                    tostring(u.dsThr), tostring(u.atLimiter), GetGameTimer() - (u.at or 0)))
    else
        print('[hk-cap]   UPSHIFT gate: no dbgUp yet (not a DCT/auto mode, or never evaluated)')
    end
    print(('[hk-cap]   RE-ENABLE churn @frame: count=%s lastGap=%sms lastEnableAgo=%sms')
        :format(tostring(w.reEnCount), tostring(w.reEnGapMs), tostring(w.reEnAgoMs)))
    print('[hk-cap] READ: torqueMult~=0 => something CUT torque. limByCap=true => rev-limiter speed-cap '
        .. 'pinned it. driveForce~=0 => drive decoupled (shift/neutral). reEnCount>0 & lastEnableAgo small '
        .. '=> Disable->Enable LOOP resetting the box (the real culprit). All fine => look elsewhere.')
    print(('[hk-cap]   LIVE re-enable now: count=%s lastVeh=%s lastGap=%s')
        :format(tostring(HK.reEnCount), tostring(HK.reEnLastVeh), tostring(HK.reEnLastGapMs)))
end

-- Dump the per-frame ring buffer in chronological order — the trajectory INTO the fade. Lets us
-- read a smooth decline (drive fade) vs a one-frame slam (collision) and watch df/tq/rpm live.
function HK.capDumpRing()
    local ring, n = HK.capRing, HK.capRingI
    if not ring or not n then print('[hk-cap] ring empty'); return end
    print('[hk-cap] --- trajectory (oldest->newest, kmh|eff/ctrl|pedal(pThr/press/kb)|g/cg rpm|tq/tqA|df) ---')
    -- walk oldest->newest starting just after the current write index
    for off = 1, 90 do
        local i = ((n + off - 1) % 90) + 1
        local f = ring[i]
        if f then
            print(('[hk-cap]  %5dms kmh=%3.0f e%.2f/c%.2f g%s/%s rpm=%.2f tq=%.2f/%.2f df=%.3f mfv=%.1f tsMod=%s%s')
                :format(f.t % 100000, f.kmh or -1, f.eff or -1, f.ctrl or -1,
                        tostring(f.g), tostring(f.cg), f.rpm or -1, f.tq or -1, f.tqA or -1,
                        f.df or -1, f.mfv or -1, tostring(f.tsMod), f.byCap and ' (cap)' or ''))
        end
    end
end

-- /gbcap — dump the auto-captured worst torque-death frame. It also AUTO-prints on detection,
-- so you normally don't need to type this. /gbcapclear re-arms for a fresh capture.
RegisterCommand('gbcap', function() HK.capDump(); HK.capDumpRing() end, false)

RegisterCommand('gbcapclear', function()
    HK.capWorst = nil; HK.capArmed = true; HK.capPrevKmh = nil
    HK.capRun = 0; HK.capPrinted = false
    HK.capRing = {}; HK.capRingI = 0
    HK.thrDropRun = 0; HK.thrDropPrinted = false
    print('[hk-cap] cleared + re-armed.')
end, false)

-- /gbcapauto — toggle the auto-print. OFF (default) = silent; you dump manually with /gbcap after
-- the car loses torque (the ring buffer holds ~1.5s of history, so a slightly-late /gbcap still
-- shows the lead-in). ON = it prints itself the instant it detects the fade (spammy).
RegisterCommand('gbcapauto', function()
    HK.capAutoPrint = not HK.capAutoPrint
    print('[hk-cap] auto-print = ' .. (HK.capAutoPrint and 'ON (will print on detection)'
        or 'OFF (silent — use /gbcap to dump after it happens)'))
end, false)

-- /gbpower <forceMult> [mfvMult] — LIVE power dial for the modded-car lugging test. Scales the
-- authored band's stock driveForce (pull/torque) and mfv (top speed) so you can FEEL where the
-- lugging stops without restart-guessing. e.g. /gbpower 1.6 1.5 = +60% drive force, +50% top speed.
-- /gbpower 1 1 (or /gbpower reset) = back to stock. Requires AuthoritativeBand active on the car.
RegisterCommand('gbpower', function(_, args)
    if not (Config.Gearbox and Config.Gearbox.AuthoritativeBand) then
        print('[hk-power] AuthoritativeBand is OFF — dial has nothing to scale.'); return
    end
    local a1 = args[1]
    if a1 == 'reset' or a1 == nil then
        HK.powerForceMult, HK.powerMfvMult = 1.0, 1.0
        print('[hk-power] reset to stock (forceMult=1.0 mfvMult=1.0). Change applies next frame.')
        return
    end
    local f = tonumber(a1)
    local m = tonumber(args[2])
    if not f then print('[hk-power] usage: /gbpower <forceMult> [mfvMult]  (e.g. /gbpower 1.6 1.5)'); return end
    HK.powerForceMult = f
    HK.powerMfvMult   = m or HK.powerMfvMult or 1.0
    print(('[hk-power] dialed forceMult=%.2f mfvMult=%.2f — floor it and feel gear 5+; /gbstate shows live mfv.')
        :format(HK.powerForceMult, HK.powerMfvMult))
end, false)

-- /gbratiotest — SET vs TOGGLE disambiguation for native 0x337EF33DA3DDB990. /gbratioflip proved
-- reduced-ratio ON = clean table (tops 315), OFF = folded native modded table. But we don't yet know
-- if the native is an ABSOLUTE SET (true always => clean) or a TOGGLE (each call flips, so our
-- every-frame true-assert would be flipping the table 60x/sec and IS the bug). This freezes the tick
-- re-assert (HK.ratioProbeHold) then calls the SAME argument twice in a row: if the table changes on
-- the 2nd identical call, it's a toggle. Runs the whole sequence so we see set/toggle unambiguously.
RegisterCommand('gbratiotest', function()
    local veh = GetVehiclePedIsIn(PlayerPedId(), false)
    if not veh or veh == 0 then print('[hk-ratiotest] not in a vehicle'); return end
    local K   = (Config.Gearbox and Config.Gearbox.RatioSeedK) or 1.199
    local hg  = GetVehicleHighGear(veh) or 0
    local function sig(label)
        local mfv = GetVehicleHandlingFloat(veh, 'CHandlingData', 'fInitialDriveMaxFlatVel') or -1
        local g6 = GetVehicleGearRatio(veh, 6) or 0
        local g9 = GetVehicleGearRatio(veh, hg) or 0
        local top = (g9 > 0 and mfv > 0) and (K * mfv / g9) or -1
        local kind = (g9 < g6) and 'MONOTONIC(clean)' or 'FOLDED(native)'
        print(('[hk-ratiotest] %-22s g6=%.4f gTop=%.4f top=%.0f -> %s'):format(label, g6, g9, top, kind))
    end
    HK.ratioProbeHold = true    -- stop the every-frame tick re-assert so our calls stand alone
    Wait(50)
    sig('start (held)')
    vl_setTransmissionReducedGearRatio(veh, false); Wait(30); sig('false #1')
    vl_setTransmissionReducedGearRatio(veh, false); Wait(30); sig('false #2 (same arg)')
    vl_setTransmissionReducedGearRatio(veh, true);  Wait(30); sig('true  #1')
    vl_setTransmissionReducedGearRatio(veh, true);  Wait(30); sig('true  #2 (same arg)')
    HK.ratioProbeHold = false   -- release; tick resumes asserting the mode's intended state
    print('[hk-ratiotest] READ: if #2 differs from #1 for the same arg => TOGGLE (our 60/sec assert '
        .. 'is the folder). If #2 == #1 => absolute SET (true=clean is correct; bug is a stray false).')
end, false)

-- /gbfloorreset — clear the poisoned mfvFloor for the car you're in and re-capture it on THIS
-- (clean) frame, then reseed the ratio basis. Recovers a floor that got banked LOW by a recompute
-- transient (the "super short last gears / mfv clamped to stock" bug) without needing /dv + respawn.
-- The floor is fingerprint-keyed and first-capture-wins-then-locked, so clearing the key lets the
-- next capture (this one) set the honest value. Reads the CURRENT live maxFlatVel as the new floor.
RegisterCommand('gbfloorreset', function()
    local veh = GetVehiclePedIsIn(PlayerPedId(), false)
    if not veh or veh == 0 then print('[hk-gbfloor] not in a vehicle'); return end
    local fk  = HK.mfvFloorKey(veh)
    local old = HK.mfvFloor and HK.mfvFloor[fk]
    -- Clearing the key stops the every-frame clamp (no anchor). We CANNOT just re-read live now —
    -- the clamp has been holding it at the poisoned floor, so it reads the poisoned value. Instead
    -- we clear the floor AND origins for this fingerprint, then force a clean Disable->Enable
    -- re-snapshot so origins + floor re-capture from the (now unclamped) live handling value. If the
    -- car's live maxFlatVel is still the honest modded value, first-capture-wins locks it correctly.
    if HK.mfvFloor then HK.mfvFloor[fk] = nil end
    gbLiveUpgrade = true
    Gearbox_Disable(veh)
    Gearbox_Enable(veh)
    local new = HK.mfvFloor and HK.mfvFloor[HK.mfvFloorKey(veh)]
    print(('[hk-gbfloor] reset key=%s | old floor=%s -> new floor=%s (re-snapshot). '
        .. 'If still short, the entity origins are poisoned — do /dv + respawn (a fresh spawn '
        .. 'captures cleanly now the re-Enable loop is dead). Re-run /gbstate to confirm.')
        :format(fk, tostring(old), tostring(new)))
end, false)

-- /gbtransmod [0-4|off] — LIVE, reversible probe: prove that the folded g7/g8 ratios come from the
-- GTA transmission mod (slot 13). GTA generates ratios from the .meta nInitialDriveGears at spawn,
-- then a transmission UPGRADE re-lays the whole ratio table (often FOLDING the top gears shorter).
-- There is NO runtime native to rewrite gear ratios, so the only way to get a clean table is to
-- change what GTA generates them FROM. This command flips slot 13 and dumps the ratio spread before
-- and after so we can SEE the regeneration. Pass 'off' (or -1) to remove the mod; 0-4 to set a level.
-- Nothing is persisted server-side — this is a client-local physics probe; re-enter the car or
-- respawn to restore the qb-inventory/vehiclemods truth. After proving it, the FIX lives in the
-- mod-application path (don't apply transmission, or strip it), not here.
RegisterCommand('gbtransmod', function(_, a)
    local veh = GetVehiclePedIsIn(PlayerPedId(), false)
    if not veh or veh == 0 then print('[hk-transmod] not in a vehicle'); return end
    local arg = (a and a[1]) or 'off'
    local level = (arg == 'off' or arg == '-1') and -1 or tonumber(arg)
    if level == nil or level < -1 or level > 4 then
        print('[hk-transmod] usage: /gbtransmod [off|0|1|2|3|4]'); return
    end
    local K   = (Config.Gearbox and Config.Gearbox.RatioSeedK) or 1.199
    local function dump(label)
        SetVehicleModKit(veh, 0)
        local hg  = GetVehicleHighGear(veh) or 0
        local ndg = GetVehicleHandlingInt(veh, 'CHandlingData', 'nInitialDriveGears')
        local mfv = GetVehicleHandlingFloat(veh, 'CHandlingData', 'fInitialDriveMaxFlatVel')
        local cur = GetVehicleMod(veh, 13)
        print(('[hk-transmod] %s: mod13=%d highGear=%d nInitialDriveGears=%d mfv=%.1f')
            :format(label, cur, hg, ndg or -1, mfv or -1))
        for g = 1, hg do
            local r   = GetVehicleGearRatio(veh, g) or 0
            local top = (r and r > 0 and mfv and mfv > 0) and (K * mfv / r) or -1
            print(('[hk-transmod]   g%d ratio=%.3f topKmh=%.0f'):format(g, r, top))
        end
    end
    dump('BEFORE')
    SetVehicleModKit(veh, 0)
    if level == -1 then RemoveVehicleMod(veh, 13) else SetVehicleMod(veh, 13, level, false) end
    Wait(0)   -- let GTA re-lay the drivetrain
    dump(('AFTER (set mod13=%d)'):format(level))
    -- The box captured its baseline PRE-flip; re-snapshot so it drives on the new ratios cleanly.
    gbLiveUpgrade = true
    Gearbox_Disable(veh); Gearbox_Enable(veh)
    print('[hk-transmod] re-snapshotted. NOTE: this is a client-local probe — re-enter/respawn to '
        .. 'restore the inventory-truth mod. Compare BEFORE/AFTER top gears: if AFTER is clean '
        .. '(monotonic topKmh, no fold) the transmission mod is the folder.')
end, false)

-- PARK BRAKE state for HUDs. Our box "starts parked": an auto-DCT that you enter
-- with the engine off begins in a held NEUTRAL (drive-force cut, gear 0) and waits
-- for a HANDBRAKE tap before engaging a gear — the "release park" feel (see the
-- DctAutoStartInNeutral logic + gearbox_Tick neutral branch). Because that neutral
-- is LOGICAL (we never call SetVehicleHandbrake), the native GetVehicleHandbrake
-- reads false, so a HUD polling the native can't light its handbrake/park lamp.
-- This export surfaces that state so the speedo can show the lamp until the driver
-- taps the handbrake to pull away. True only for the auto-DCT park neutral; the
-- both-key/manual neutrals are driver-chosen coasts, not a park brake.
exports("IsParkBraked", function(veh)
    if not applied then return false end
    if veh and veh ~= 0 and curVeh ~= 0 and veh ~= curVeh then return false end
    -- DCT tiers (3/4/5) in AUTO sub-mode, sitting in the start/park neutral.
    if (gearMode == 3 or gearMode == 4 or gearMode == 5) and dctNeutral and not dctManual then
        return true
    end
    return false
end)

-- REAL rev-limiter redline (normalised 0..1) for HUDs. This is the SAME value the
-- box actually limits at (Config.Gearbox.RevLimiterRedline), so the speedo's shift
-- lights / redline flicker line up with when the engine truly hits the limiter,
-- instead of a hardcoded guess. Returns nil if the box config isn't loaded, so the
-- caller can fall back to its own default.
exports("GetRevLimiterRedline", function()
    if Config.Gearbox and Config.Gearbox.RevLimiterRedline then
        return Config.Gearbox.RevLimiterRedline
    end
    return nil
end)

-- FREE-REV PAINTED RPM (pull model, called per frame by hk-speedo). PROBLEM this solves: during a
-- brake-held free-rev we sit in native gear 1 with the car stopped, and GTA's engine sim caps rpm at
-- the clutch-slip/stall equilibrium (~0.6) and RECOMPUTES it every physics frame — clawing our
-- SetVehicleCurrentRpm paint back down before hk-speedo reads GetVehicleCurrentRpm. So the audio (which
-- samples rpm the instant we set it) screams, but the SPEEDO needle only reaches ~0.6. Fix: expose our
-- OWN painted value here; the speedo prefers it while free-rev owns the frame, so the needle shows the
-- true limiter rpm (bouncing at redline). Returns nil when not free-revving -> speedo uses native rpm.
exports("GetFreeRevRpm", function()
    if HK.freeRevActive == true and HK.revPaint ~= nil then
        return HK.revPaint
    end
    return nil
end)

-- LIVE REGEN LEVEL for hk-speedo's EV power meter (pull model, called per frame).
-- Returns: level (0..1 regen intensity), mode ('onepedal'|'coast'), holding (bool =
-- at the stop-hold), active (bool = regen applying this frame). Only meaningful while
-- the box is applied to a pure EV or a hybrid in e-mode; returns a zeroed table
-- otherwise so the gauge cleanly shows "no regen". veh arg optional (ignored — the
-- signal is for the driven car the box is currently running).
exports("GetRegenLevel", function(veh)
    local r = HK and HK.evRegen
    if not applied or not r then
        return { level = 0.0, mode = 'coast', holding = false, active = false }
    end
    return { level = r.level or 0.0, mode = r.mode or 'coast',
             holding = r.holding == true, active = r.active == true }
end)

-- DRIVETRAIN LAYOUT for hk-speedo — classify from fDriveBiasFront (0 = all rear, 1 = all
-- front). Standard thresholds: <0.10 = RWD, >0.90 = FWD, else AWD. Reads the CAR'S NATIVE
-- bias (getDrivetrainOrigins snapshot when we own it, else the live handling float) so a
-- momentary AWD-assist shift doesn't flip the label. Pass a veh (defaults to the driven
-- one). Returns { layout = 'RWD'|'FWD'|'AWD', bias = 0..1 } or nil if no vehicle.
exports("GetDrivetrain", function(veh)
    veh = (veh and veh ~= 0) and veh or driverVeh()
    if not veh or veh == 0 or not DoesEntityExist(veh) then return nil end
    -- Category-A fact, computed by the shared vehlib helper (one implementation). We pass our
    -- captured ORIGIN bias when this is the car we're running, so a live fake-AWD-assist shift
    -- can't flip the label; otherwise the helper reads live.
    local originBias = (applied and curVeh == veh and origins) and origins.fDriveBiasFront or nil
    return vl_getDrivetrainLayout(veh, originBias)
end)

-- HYBRID DRIVE MODE — TOGGLE between two modes: 'ev' <-> 'normal' (called by the HOLD-G
-- handler in qb-vehiclekeys). No-op on non-hybrids. Applies/clears the EV engine audio.
-- NEVER touches engine on/off (that would drop the speedo + control). Returns the new mode.
exports("CycleHybridMode", function()
    if not applied or not isHybrid then return nil end
    hybridUserMode = (hybridUserMode == 'ev') and 'normal' or 'ev'
    if hybridUserMode == 'normal' then
        -- Force ICE now: engine note + full power, DCT resumes in AUTO (clear stale manual).
        hybridEMode = false
        dctManual = false
        dctStarted = false        -- force a clean DCT re-init on the next ICE frame
        -- RELEASE the e-mode single-gear setup immediately: reduced-ratio OFF + restore the
        -- real fInitialDriveMaxFlatVel (undo tall-gear-1) so ICE gets GTA's normal box + top speed.
        if eGearPinned and curVeh ~= 0 and DoesEntityExist(curVeh) then
            eGearPinned = false
            vl_setTransmissionReducedGearRatio(curVeh, false)
            if origins and origins.fInitialDriveMaxFlatVel then
                vl_setHandling(curVeh, 'fInitialDriveMaxFlatVel', origins.fInitialDriveMaxFlatVel)
            end
        end
    else
        -- Back to EV: engage electric immediately. Flip the DCT to AUTO + clean state FIRST so
        -- the box is script-controlled going in (no stale manual/gear), and so a later EV->ICE
        -- handoff starts clean too. (user: always auto on either ev<->hybrid switch.)
        hybridEMode = true
        dctManual = false
        dctStarted = false
        dctLatchedNeutral = false
        eReducedRatioOff = false     -- force the tick to re-clear reduced-ratio on EV entry
    end
    -- DIAGNOSTIC: time the audio swap vs the speedo event so we can see which one hitches
    -- (user reports a multi-second frame drop on the ev<->hybrid switch). Debug-gated.
    local _t0 = Config.Gearbox.Debug and GetGameTimer() or 0
    applyHybridAudio(curVeh)                                -- swap sound to match the new state
    if Config.Gearbox.Debug then
        print(('[hk-hybrid] switch: audio swap took %d ms'):format(GetGameTimer() - _t0))
    end
    vl_notify((hybridUserMode == 'ev') and 'EV Mode' or 'Hybrid', 'inform')
    TriggerEvent('hk-speedo:hybridMode', hybridUserMode)   -- speedo shows it (safe no-op)
    return hybridUserMode
end)

-- Is the current car a hybrid? (lets qb-vehiclekeys decide whether HOLD-G should cycle
-- modes vs. a normal-car tap just toggling the engine.)
exports("IsHybridVehicle", function()
    return applied and isHybrid == true
end)

-- ELECTRIC-MODE state for hk-speedo. GTA's GetIsVehicleElectric is model-level and false
-- for a hybrid (SF90 is a petrol model), so the speedo can't detect our SIMULATED e-mode
-- from the native. This is the authoritative signal: true when the car is CURRENTLY driving
-- electric — a pure EV, OR a hybrid whose e-mode is engaged. The speedo should treat this
-- like 'electric' (single 'D', EV power meter, coast regen) regardless of the native flag.
exports("IsElectricNow", function()
    if not applied then return false end
    if isEV then return true end
    if isHybrid and hybridEMode then return true end
    return false
end)

-- COMBINED DRIVE STATE for hk-speedo — one call/frame instead of 4. Bundles everything the
-- speedo needs to render an EV/hybrid, with the indicator + gear label PRE-COMPUTED so the
-- speedo doesn't re-derive our rules. Returns a table (never nil; fields safe when not applied).
--   isHybrid    : this car is a config/DB-flagged hybrid
--   isEV        : this car is a pure EV (single-gear electric)
--   electricNow : ACTUALLY electric right now (pure EV always; hybrid only in e-mode)
--   regen       : { level 0..1, mode, holding, active }  (same as GetRegenLevel)
--   gearboxMode : 'manual' | 'auto' | nil
--   indicator   : { icon = 'E' | 'BOLT', color = 'green' | 'gold' | nil }
--                   pure EV      -> E / green
--                   hybrid e-mode-> BOLT / green
--                   hybrid ICE   -> BOLT / gold
--                   neither      -> nil icon
--   gearLabel   : what to show in the gear readout:
--                   hybrid e-mode / pure EV -> 'D'  (single-gear feel, no number)
--                   hybrid ICE / normal     -> nil  (speedo shows its own gear number)
-- Build the CATEGORY-B drive-state blob (dynamic feature state this script owns). Shared by
-- the GetVehicleDriveState export (pull, kept as fallback) AND the statebag PUBLISHER below.
local function buildDriveState()
    local r = HK and HK.evRegen
    local regen = { level = 0.0, mode = 'coast', holding = false, active = false }
    if applied and r then
        regen.level, regen.mode = r.level or 0.0, r.mode or 'coast'
        regen.holding, regen.active = r.holding == true, r.active == true
    end
    -- BEHAVIOUR flags (what the car actually IS / does):
    local behHyb  = applied and isHybrid == true           -- full PHEV (EV mode, HOLD-G, cap)
    local behSemi = applied and HK.semiHybrid == true      -- KERS: ICE always runs
    local ev   = applied and isEV == true
    local enow = false
    if applied then enow = ev or (isHybrid and hybridEMode) end
    -- DISPLAY flags (how the CLUSTER should look — decoupled via HK.speedoStyle). A full PHEV
    -- with style='semi' (918/P1) reports to the speedo AS a semi (charge-arc on the normal tach)
    -- but still carries electricNow so its e-mode reads green 'D' + a green throttle bar. A true
    -- semi is always 'semi'. Everything else keeps its class-derived look.
    local style   = applied and HK.speedoStyle or nil
    local hyb     = behHyb and (style ~= 'semi')           -- full 3-ring look: PHEV NOT forced semi
    local semi    = behSemi or (behHyb and style == 'semi')-- charge-arc look
    -- EMODE-BAR: a semi-LOOK car that is actually in electric drive right now (only a semi-style
    -- PHEV can be — a true KERS semi has no e-mode). The tach then shows throttle+green, not revs.
    local emodeBar = semi and enow == true
    local semiBoost = (semi and HK.semiBoost) or 0.0    -- live e-assist fraction 0..1 (arc amber side)

    local gbMode
    if applied then
        if gearMode == 1 or gearMode == 6 then gbMode = 'manual'
        elseif gearMode == 3 or gearMode == 4 or gearMode == 5 then gbMode = dctManual and 'manual' or 'auto'
        elseif gearMode == 2 then gbMode = 'auto' end
    end

    -- SINGLE-GEAR AUTO: PUBLIC mode 0 = internal gearMode 2 (comfort auto). The user wants
    -- it to read like an EV — a single 'D' (blue), no A/M gearbox pill — since a full-auto
    -- box has no manual shifting to surface. NOT set for DCT autos (3/4/5, which still show
    -- real gears) nor for EV/hybrid (they have their own 'E'/⚡ treatment).
    -- singleGear keys off BEHAVIOUR (a PHEV is never comfort-auto regardless of its look).
    local singleGear = applied and gearMode == 2 and not ev and not behHyb

    local indicator, gearLabel = nil, nil
    if ev then
        indicator = { icon = 'E',    color = 'green' }
        gearLabel = 'D'
    elseif hyb then
        indicator = { icon = 'BOLT', color = enow and 'green' or 'gold' }  -- green e-mode / gold ICE
        if enow then gearLabel = 'D' end                                   -- e-mode: 'D'; ICE: real gear
    elseif behHyb and semi then
        -- SEMI-LOOK full PHEV: still has a real e-mode. In e-mode show the green 'E' + 'D' (drives
        -- like an EV); in ICE mode fall through to the car's normal gear number + gearbox pill.
        if enow then
            indicator = { icon = 'E', color = 'green' }
            gearLabel = 'D'
        end
    elseif singleGear then
        gearLabel = 'D'                                                    -- comfort auto: always 'D'
    end

    local L = HK and HK.launch
    return {
        isHybrid = hyb, isEV = ev, electricNow = enow, singleGear = singleGear,
        semiHybrid = semi, semiBoost = semiBoost,   -- KERS: charge arc on the normal tach
        emodeBar = emodeBar,                         -- semi-LOOK PHEV in e-mode: throttle+green tach
        -- CLUTCH gauge (manual modes only): engagement 0..1 (1=out/engaged, 0=in/pressed).
        -- clutchManual gates the gauge's visibility (auto/DCT/EV never show it).
        clutchManual = applied and HK.clutchIsManual == true,
        clutch       = (applied and HK.clutchIsManual) and (HK.clutchEngage or 1.0) or 1.0,
        -- TURBO gauge (driver-only, turbo cars only): turboActive gates the gauge's visibility;
        -- turboSpool 0..1 is the boost needle (laggy spool), turboHit 0..1 flashes on the punch as
        -- boost slams online. Driver-local like clutch (pulled via GetVehicleDriveState, no statebag).
        turboActive = applied and HK.turboActive == true,
        turboSpool  = (applied and HK.turboActive) and (HK.turboSpool or 0.0) or 0.0,
        turboHit    = (applied and HK.turboActive) and (HK.turboHit or 0.0) or 0.0,
        regen = regen, gearboxMode = gbMode,
        indicator = indicator, gearLabel = gearLabel,
        launchActive = (applied and L and L.active) == true,
        launchPhase  = (applied and L and L.phase) or 'off',
        -- pre-stage signals so a PASSENGER's LC pill gets the idle/prep looks too:
        launchNeutral = (applied and L and L.inNeutral) == true,
        launchHb      = (applied and L and L.hb) == true,
    }
end
exports("GetVehicleDriveState", buildDriveState)   -- pull path (kept as fallback / non-speedo consumers)


-----------------------------------------------------------------
-- DRIVE-STATE STATEBAG PUBLISHER (PUSH). hk-handling now OWNS pushing its category-B state
-- to the vehicle's replicated `hk_drivestate` bag — previously hk-speedo pulled per-frame
-- then republished. Publishing from the SOURCE means: the driver's own speedo just READS the
-- bag (same path passengers already used), no per-frame export round-trip, and any consumer
-- gets the state for free. Change-detected via a compact signature so we only .set on an
-- actual change (statebag sets replicate — never spam per frame). ~10 Hz is plenty; this is
-- slow status data (mode/regen/indicator), NOT the gauge needle.
local DRIVE_BAG = 'hk_drivestate'
local function publishDriveState()
    local veh = curVeh
    if not applied or not veh or veh == 0 or not DoesEntityExist(veh) then return end
    local ds = buildDriveState()
    local ind = ds.indicator
    local sig = table.concat({
        tostring(ds.isHybrid), tostring(ds.isEV), tostring(ds.electricNow),
        tostring(ds.singleGear),
        ind and ind.icon or '-', ind and ind.color or '-',
        ds.gearLabel or '-', ds.regen and ds.regen.mode or '-',
        ds.regen and (ds.regen.active and 1 or 0) or 0, ds.gearboxMode or '-',
        ds.launchPhase or '-',
        ds.launchNeutral and 'N' or '-', ds.launchHb and 'H' or '-',
        ds.semiHybrid and 'S' or '-',
        ds.emodeBar and 'B' or '-',                 -- semi-look PHEV e-mode tach flip (passenger sync)
        -- bucket the boost to 0.2 steps so the 10 Hz change-detect doesn't fire every frame
        -- on a continuously-varying value (passengers get a coarse arc; driver reads smooth).
        tostring(math.floor((ds.semiBoost or 0.0) * 5 + 0.5)),
    }, '|')
    if sig == lastDrivePubSig then return end
    lastDrivePubSig = sig
    local enow = ds.electricNow
    pcall(function()
        Entity(veh).state:set(DRIVE_BAG, {
            hybrid = ds.isHybrid, ev = ds.isEV, electricNow = enow,
            electric = ds.isEV or enow,                 -- 'currently electric' (pure EV or hybrid e-mode)
            singleGear = ds.singleGear == true,         -- comfort auto: show single 'D', no A/M pill
            icon = ind and ind.icon or false, color = ind and ind.color or false,
            gearLabel = ds.gearLabel or false,
            regenMode = ds.regen and ds.regen.mode or 'coast',
            regenActive = ds.regen and ds.regen.active == true or false,
            regenHolding = ds.regen and ds.regen.holding == true or false,
            gearboxMode = ds.gearboxMode or false,
            launchActive = ds.launchActive == true,     -- launch control staged/launched (status box)
            launchPhase  = ds.launchPhase or 'off',     -- 'off'|'staged'|'launched'
            launchNeutral = ds.launchNeutral == true,   -- in a launch-capable neutral (pill idle/prep)
            launchHb      = ds.launchHb == true,        -- handbrake held while staging (pill prep)
            semiHybrid = ds.semiHybrid == true,         -- KERS: charge arc on the normal tach
            semiBoost  = ds.semiBoost or 0.0,           -- live e-assist 0..1 (passenger charge arc, amber)
            emodeBar   = ds.emodeBar == true,           -- semi-look PHEV in e-mode: throttle+green tach
        }, true)
    end)
end
CreateThread(function()
    while true do
        Wait(100)                       -- 10 Hz status push (change-detected; cheap)
        if applied then publishDriveState() end
    end
end)

-----------------------------------------------------------------
-- GEAR + RPM PASSENGER / SPECTATOR SYNC — DRIVER PUBLISHER (PUSH).
-- Our gearbox tick runs DRIVER-LOCAL: it paints rpm AND owns the gear (incl. N/R via the reverse
-- gate) only on the driver's client. On a passenger/spectator's client the SAME car is still
-- running GTA's OWN local auto-box — which keeps its own (always-forward) gear and re-pitches the
-- engine note, FIGHTING a bare rpm write (why rpm "kinda" carried) and never producing free-rev
-- NEUTRAL or REVERSE. So we must stream the CRUCIAL driver values — the logical gear (R/N/1..n)
-- AND the painted rpm — and pin BOTH remotely each frame, mirroring the driver's own tick.
--
-- gear encoding (numeric, so it packs in the bag): -1 = R, 0 = N, 1..n = forward gear.
-- Mirrors the GetDisplayGear export's logic (revGate owns R/N; else per-mode gear).
-- Published as {g=gear, r=rpm} to a replicated bag; change-detected on gear-change OR an rpm
-- bucket move so we don't .set every frame. Publisher state on HK.* (NOT file locals) so
-- Gearbox_Disable — earlier in the file — can reset it, and to dodge the 200-local ceiling.
HK.gearsyncPub = HK.gearsyncPub or { last = -1.0, at = 0, gear = -99 }
CreateThread(function()
    local RPM_BAG = 'hk_gearsync_rpm'
    -- The engine NOTE is f(native gear, rpm). We stream the DRIVER'S native gear (GetVehicle-
    -- CurrentGear = what GTA uses for the driver's OWN sound, AFTER our vl_setCurrentGear writes)
    -- + the painted rpm. Forcing BOTH remotely reproduces the driver's exact note — including
    -- neutral (driver pins a fwd gear + free-revs) and reverse (native gear 0).
    -- REVERSE STANDSTILL FIX: GetVehicleCurrentGear only reads 0 while the car is ACTUALLY rolling
    -- backward — stopped-in-reverse it reports a forward gear, so the passenger snapped back to the
    -- NEUTRAL note the moment the car halted. The reverse GATE (revGate=='reverse') is the truth
    -- that HOLDS through a standstill (same signal GetDisplayGear trusts), so when the gate says
    -- reverse we force the streamed gear to 0 regardless of the transient native read.
    local function publishSync()
        local RS = Config.Gearbox.RpmSync
        if not RS or RS.Enabled == false then return end
        local veh = curVeh
        if not applied or not processGearbox or not veh or veh == 0 or not DoesEntityExist(veh) then return end
        if not netEnt then return end
        local rpm = GetVehicleCurrentRpm(veh)                 -- live value INCLUDING our paints
        if rpm ~= rpm then return end                         -- NaN guard
        local gear = GetVehicleCurrentGear(veh)               -- native gear GTA uses for the driver's audio
        if revGate == 'reverse' or dctReverse then gear = 0 end  -- hold reverse note through a standstill (gate + DCT paddle-R)
        local now = GetGameTimer()
        local bucket = RS.Bucket or 0.02
        local P = HK.gearsyncPub
        -- Publish on a GEAR CHANGE (always — shifts/N/R must land immediately), OR a meaningful rpm
        -- move, OR a ~500ms keep-alive (so a steady staged-launch rpm still refreshes the remote
        -- staleness timer). A gear change is the important edge, so it bypasses the rpm bucket.
        if gear == P.gear and math.abs(rpm - P.last) < bucket and (now - P.at) < 500 then return end
        P.last = rpm
        P.gear = gear
        P.at   = now
        pcall(function() netEnt.state:set(RPM_BAG, { g = gear, r = rpm }, true) end)
    end
    while true do
        local RS = Config.Gearbox.RpmSync
        local hz = (RS and RS.PublishHz) or 20
        Wait(math.floor(1000 / math.max(1, hz)))
        if applied then publishSync() end
    end
end)

-----------------------------------------------------------------
-- DB preset MODEL list (from server `hk_handling`; matched by model hash).
-- HK.manualModels[hash] = { type = 0-6 (PUBLIC), paddle = 0/1/2,
-- ratio = 0-3 }. type is the PUBLIC gearbox number (see PUBLIC_TO_INTERNAL);
-- type 6 = GTA-native (not processed). ratio = gearRatioMode (PHASE 2).
-----------------------------------------------------------------
HK.manualModels = HK.manualModels or {}

RegisterNetEvent('hk-handling:gearbox:syncModels', function(map)
    -- transport sends string keys; convert back to number hashes
    local out = {}
    if map then
        for k, v in pairs(map) do
            local h = math.tointeger(tonumber(k)) or tonumber(k)
            if h then out[h] = { type = v.type, paddle = v.paddle or 0, ratio = v.ratio or 0,
                                 speedCal = v.speedCal, speedCalC = v.speedCalC,
                                 -- keep nil UNSET so the Enable resolver uses the config
                                 -- Hybrid.Models fallback; only 0/1/2 are explicit classes.
                                 hybridClass = v.hybridClass, evTorque = v.evTorque,
                                 hybridCap = v.hybridCap, speedoStyle = v.speedoStyle,
                                 -- turboDefault: nil UNSET = fall back to Turbo.DefaultModels roster;
                                 -- only 0 (NA) / 1 (turbo) are explicit per-model overrides.
                                 turboDefault = v.turboDefault,
                                 -- wheelieLaunch: nil UNSET = fall back to the muscle class gate;
                                 -- only 0 (force off) / 1 (force on) are explicit overrides.
                                 wheelieLaunch = v.wheelieLaunch } end
        end
    end
    HK.manualModels = out
    if Config.Gearbox and Config.Gearbox.Debug then
        local n = 0 for _ in pairs(out) do n = n + 1 end
        print('[hk-gearbox] received ' .. n .. ' DB manual model(s)')
    end

    -- LIVE RE-ARM: if driving now, the just-synced flags may have made THIS model
    -- manual (or cleared it). Re-evaluate immediately — no exit/re-entry needed.
    local veh = driverVeh()
    if veh ~= 0 then
        if shouldProcess(veh) then
            if not applied or curVeh ~= veh then
                applied = false              -- clear stale guard so Enable re-runs
                Gearbox_Enable(veh)
            else
                -- Already applied to THIS car: Enable won't re-run, but the synced
                -- speedCalC may have changed (e.g. /accelcal or normallearner just wrote it).
                -- Refresh the live trim and AccelMatch so the correction takes effect now.
                local SC = Config.Gearbox and Config.Gearbox.SpeedCal
                local mm = HK.manualModels[GetEntityModel(veh) & 0xFFFFFFFF]
                gbSpeedCal = nil
                gbSpeedCalTargeted = false
                if SC and SC.Enabled and mm then
                    if isNormal() then
                        local hasNativeBaseline = type(mm.speedCal) == 'string' and mm.speedCal:sub(1, 2) == 'N:'
                        gbSpeedCalTargeted = hasNativeBaseline
                        if mm.speedCalC then
                            local f = speedCalUnpack(mm.speedCalC)
                            if f then local s = f[1] or 1.0; gbSpeedCal = { s, s, s, s } end
                        end
                    elseif isExpert() then
                        if mm.speedCal and mm.speedCal ~= '' then gbSpeedCalTargeted = true end
                        if mm.speedCalC then gbSpeedCal = speedCalUnpack(mm.speedCalC) end
                    end
                end
                -- AccelMatch: expert-only, disabled when SpeedCal active
                gbAccelTrim = 0.0
                if isExpert() and not gbSpeedCal then
                    local AM = Config.Gearbox and Config.Gearbox.AccelMatch
                    local ptype = resolvePublicType(veh)
                    if AM and AM.Enabled and ptype and AM.Modes and AM.Modes[ptype] then
                        gbAccelTrim = 1.0
                    end
                end
            end
        elseif applied and curVeh == veh then
            Gearbox_Disable(veh)             -- flag removed -> stand down live
        end
    end
end)

-- /setgear roundtrip: server asks for the model of the car we're in.
RegisterNetEvent('hk-handling:gearbox:requestModel', function(mtype, paddle)
    local veh = driverVeh()
    if veh == 0 then
        TriggerServerEvent('hk-handling:gearbox:setModel', nil, nil, nil, mtype, paddle)
        return
    end
    local hash = GetEntityModel(veh) & 0xFFFFFFFF   -- clean unsigned 32-bit
    local spawn = spawnNameByHash[hash] or ''        -- spawn id like 'rs721' (reverse-map)
    local name = GetLabelText(GetDisplayNameFromVehicleModel(GetEntityModel(veh)))
    if not name or name == '' or name == 'NULL' then
        name = GetDisplayNameFromVehicleModel(GetEntityModel(veh))   -- raw display name fallback
    end
    -- 'model' = spawn id (from the GetAllVehicleModels reverse-map; '' for addon
    -- models not in the list). 'name' = display name (readability). Match = hash.
    TriggerServerEvent('hk-handling:gearbox:setModel', hash, spawn, name, mtype, paddle)
end)

-- /sethybrid roundtrip: server asks for the model of the car we're in (mirror of
-- /setgear). class 0=none / 1=full PHEV / 2=semi(KERS). evTorque/capKmh may be nil.
RegisterNetEvent('hk-handling:gearbox:requestHybridModel', function(class, evTorque, capKmh, speedoStyle)
    local veh = driverVeh()
    if veh == 0 then
        TriggerServerEvent('hk-handling:gearbox:setHybridModel', nil, nil, nil, class, evTorque, capKmh, speedoStyle)
        return
    end
    local hash = GetEntityModel(veh) & 0xFFFFFFFF
    local spawn = spawnNameByHash[hash] or ''
    local name = GetLabelText(GetDisplayNameFromVehicleModel(GetEntityModel(veh)))
    if not name or name == '' or name == 'NULL' then
        name = GetDisplayNameFromVehicleModel(GetEntityModel(veh))
    end
    TriggerServerEvent('hk-handling:gearbox:setHybridModel', hash, spawn, name, class, evTorque, capKmh, speedoStyle)
end)

-- /setturbo roundtrip: server asks for the model of the car we're in (mirror of /sethybrid).
-- flag -1 = clear/unset (use roster), 0 = NA, 1 = turbo-by-design (FEEL default-on).
RegisterNetEvent('hk-handling:gearbox:requestTurboModel', function(flag)
    local veh = driverVeh()
    if veh == 0 then
        TriggerServerEvent('hk-handling:gearbox:setTurboModel', nil, nil, nil, flag)
        return
    end
    local hash = GetEntityModel(veh) & 0xFFFFFFFF
    local spawn = spawnNameByHash[hash] or ''
    local name = GetLabelText(GetDisplayNameFromVehicleModel(GetEntityModel(veh)))
    if not name or name == '' or name == 'NULL' then
        name = GetDisplayNameFromVehicleModel(GetEntityModel(veh))
    end
    TriggerServerEvent('hk-handling:gearbox:setTurboModel', hash, spawn, name, flag)
end)

-- /setwheelielaunch roundtrip: server asks for the model of the car we're in (mirror of /setturbo).
-- flag -1 = clear/unset (use the muscle class gate), 0 = force off, 1 = force on.
RegisterNetEvent('hk-handling:gearbox:requestWheelieLaunchModel', function(flag)
    local veh = driverVeh()
    if veh == 0 then
        TriggerServerEvent('hk-handling:gearbox:setWheelieLaunchModel', nil, nil, nil, flag)
        return
    end
    -- RWD-ONLY for a FORCE-ON (flag 1): only rear-drive cars can wheelie (see wheelie.lua's hard
    -- gate). Refuse the opt-in on AWD/FWD right here so it never even hits the DB — no point saving a
    -- flag the wheelie gate will always reject. flag 0 (force-off) and -1 (clear/unset) are always
    -- allowed so any car can be silenced/reset. Class from the live classifier (HK.dbgDrive.class).
    if flag == 1 then
        local driveClass = HK.dbgDrive and HK.dbgDrive.class
        if driveClass and driveClass ~= 'rwd' then
            TriggerEvent('QBCore:Notify', ('Only RWD cars can wheelie (this is %s). /setwheelie not saved.')
                :format(string.upper(driveClass)), 'error')
            return
        end
    end
    local hash = GetEntityModel(veh) & 0xFFFFFFFF
    local spawn = spawnNameByHash[hash] or ''
    local name = GetLabelText(GetDisplayNameFromVehicleModel(GetEntityModel(veh)))
    if not name or name == '' or name == 'NULL' then
        name = GetDisplayNameFromVehicleModel(GetEntityModel(veh))
    end
    TriggerServerEvent('hk-handling:gearbox:setWheelieLaunchModel', hash, spawn, name, flag)
end)

-- /gearratio roundtrip: server asks for the model of the car we're in (mirror of
-- the /setgear roundtrip above — same explicit-admin-action name read).
RegisterNetEvent('hk-handling:gearbox:requestRatioModel', function(ratio)
    local veh = driverVeh()
    if veh == 0 then
        TriggerServerEvent('hk-handling:gearbox:setRatioModel', nil, nil, nil, ratio)
        return
    end
    local hash = GetEntityModel(veh) & 0xFFFFFFFF   -- clean unsigned 32-bit
    local spawn = spawnNameByHash[hash] or ''        -- spawn id like 'rs721' (reverse-map)
    local name = GetLabelText(GetDisplayNameFromVehicleModel(GetEntityModel(veh)))
    if not name or name == '' or name == 'NULL' then
        name = GetDisplayNameFromVehicleModel(GetEntityModel(veh))   -- raw display name fallback
    end
    TriggerServerEvent('hk-handling:gearbox:setRatioModel', hash, spawn, name, ratio)
end)

-- /nlstatus roundtrip: server asks for the current vehicle hash + name.
RegisterNetEvent('hk-handling:gearbox:requestNlStatus', function()
    local veh = driverVeh()
    if veh == 0 then
        TriggerServerEvent('hk-handling:gearbox:nlStatusReply', nil, nil)
        return
    end
    local hash = GetEntityModel(veh) & 0xFFFFFFFF
    local name = GetLabelText(GetDisplayNameFromVehicleModel(GetEntityModel(veh)))
    if not name or name == '' or name == 'NULL' then
        name = GetDisplayNameFromVehicleModel(GetEntityModel(veh))
    end
    TriggerServerEvent('hk-handling:gearbox:nlStatusReply', hash, name)
end)

-- /setspeed roundtrip: server asks for the model of the car we're in (mirror of
-- the /setgear + /gearratio roundtrips). kmh == -1 is the CLEAR sentinel. The
-- CLIENT does the work here (handling.meta is client-only): merge the new point
-- into the raw target string, compute the packed per-band factor curve, send BOTH.
RegisterNetEvent('hk-handling:gearbox:requestSpeedModel', function(kmh, time)
    local veh = driverVeh()
    if veh == 0 then
        TriggerServerEvent('hk-handling:gearbox:setSpeedModel', nil, nil, nil, nil, nil)
        return
    end
    local hash = GetEntityModel(veh) & 0xFFFFFFFF   -- clean unsigned 32-bit
    local spawn = spawnNameByHash[hash] or ''
    local name = GetLabelText(GetDisplayNameFromVehicleModel(GetEntityModel(veh)))
    if not name or name == '' or name == 'NULL' then
        name = GetDisplayNameFromVehicleModel(GetEntityModel(veh))
    end

    -- CLEAR sentinel: wipe both columns.
    if kmh == -1 then
        TriggerServerEvent('hk-handling:gearbox:setSpeedModel', hash, spawn, name, nil, nil)
        return
    end

    -- Merge the new (kmh,time) target into this model's existing raw target string.
    local existing = (HK.manualModels[hash] and HK.manualModels[hash].speedCal)
    local pts = {}
    if existing then
        for k, t in tostring(existing):gmatch('(%d+%.?%d*)%s*,%s*(%d+%.?%d*)') do
            local kk = math.floor(tonumber(k) or 0)
            if kk > 0 then pts[kk] = tonumber(t) end
        end
    end
    kmh = math.floor(kmh)
    if time and time > 0 then pts[kmh] = time else pts[kmh] = nil end

    -- Rebuild the raw string (sorted by kmh).
    local keys = {}
    for k in pairs(pts) do keys[#keys + 1] = k end
    table.sort(keys)
    if #keys == 0 then
        TriggerServerEvent('hk-handling:gearbox:setSpeedModel', hash, spawn, name, nil, nil)
        return
    end
    local rawParts = {}
    for _, k in ipairs(keys) do rawParts[#rawParts + 1] = ('%d,%s'):format(k, tostring(pts[k])) end
    local rawCal = table.concat(rawParts, ';') .. ';'

    -- NEUTRAL SEED: store the TARGET only; leave the factor NULL so the car runs on the
    -- tuner's handling.meta baseline (the safest possible start — never worse than what
    -- the tuner intended). Auto-cal / /accelcal learn the factor from real driving. The
    -- old open-loop formula seed is GONE (it pushed the wrong way on fast cars).
    TriggerServerEvent('hk-handling:gearbox:setSpeedModel', hash, spawn, name, rawCal, nil)

    if Config.Gearbox and Config.Gearbox.SpeedCal and Config.Gearbox.SpeedCal.Debug then
        print(('[hk-setspeed] %s target=%s (neutral seed; auto-cal will learn)'):format(name or hash, rawCal))
    end
end)

-----------------------------------------------------------------
-- /setspeedbulk — BULK CALIBRATION from HK.SpeedCalData (Grok-sourced real figures).
-- For each spawn code with data: spawn the model OFFSCREEN, read its handling.meta,
-- compute the packed speedCalC + raw target string, write the DB row via the same
-- admin-gated setSpeedModel event, then delete the temp vehicle. Sequential with a
-- short wait so we never hold >1 temp car or thrash model streaming. The server
-- gates start on isAdmin (this only runs after the server fires :bulkStart).
-- Triggered by the server /setspeedbulk command (admin-checked there).
-----------------------------------------------------------------
local bulkRunning = false

-- Build a {[kmh]=time} target map from a SpeedCalData entry. New GPT format uses
-- t60/t100/t160/t200 (km/h split seconds); a missing field (GPT had no real figure)
-- is simply not added, so that band keeps its neutral seed. Falls back to the old
-- k100/k160 names so a pre-regen data file still works.
local function bulkTargetsFromEntry(e)
    local pts = {}
    local t60  = e.t60
    local t100 = e.t100 or e.k100
    local t160 = e.t160 or e.k160
    local t200 = e.t200
    if t60  and t60  > 0 then pts[60]  = t60  end
    if t100 and t100 > 0 then pts[100] = t100 end
    if t160 and t160 > 0 then pts[160] = t160 end
    if t200 and t200 > 0 then pts[200] = t200 end
    return pts
end

RegisterNetEvent('hk-handling:gearbox:bulkStart', function()
    if bulkRunning then
        vl_notify('~y~setspeedbulk already running', 'primary')
        return
    end
    if not (HK.SpeedCalData and Config.Gearbox and Config.Gearbox.SpeedCal and Config.Gearbox.SpeedCal.Enabled) then
        vl_notify('~r~SpeedCal data/config missing', 'error')
        return
    end
    bulkRunning = true

    CreateThread(function()
        -- stable ordered list of spawn codes
        local list = {}
        for spawn in pairs(HK.SpeedCalData) do list[#list + 1] = spawn end
        table.sort(list)

        local total, done, ok, skip = #list, 0, 0, 0
        vl_notify(('~b~setspeedbulk: %d models (neutral seed)...'):format(total), 'primary')
        print(('[hk-setspeedbulk] starting, %d models'):format(total))

        for _, spawn in ipairs(list) do
            local entry = HK.SpeedCalData[spawn]
            local hash = GetHashKey(spawn) & 0xFFFFFFFF
            local pts = bulkTargetsFromEntry(entry)

            -- NEUTRAL SEED: store the TARGET string only, factor NULL. No spawning / no
            -- handling.meta read needed (the old formula compute is gone) — so this is
            -- instant. Every car runs the tuner's meta baseline until auto-cal learns it.
            local keys = {}
            for k in pairs(pts) do keys[#keys + 1] = k end
            table.sort(keys)
            local rawParts = {}
            for _, k in ipairs(keys) do rawParts[#rawParts + 1] = ('%d,%s'):format(k, tostring(pts[k])) end
            local rawCal = (#rawParts > 0) and (table.concat(rawParts, ';') .. ';') or nil

            if rawCal then
                local spawnId = spawnNameByHash[hash] or spawn
                TriggerServerEvent('hk-handling:gearbox:setSpeedModel', hash, spawnId, entry.n or spawn, rawCal, nil)
                ok = ok + 1
            else
                skip = skip + 1
            end

            done = done + 1
            if done % 25 == 0 then
                print(('[hk-setspeedbulk] %d/%d (ok=%d skip=%d)'):format(done, total, ok, skip))
            end
            Wait(20)   -- light pace so we don't flood the server with writes at once
        end

        bulkRunning = false
        vl_notify(('~g~setspeedbulk done: %d ok, %d skipped'):format(ok, skip), 'success')
        print(('[hk-setspeedbulk] COMPLETE: %d ok, %d skipped, %d total'):format(ok, skip, total))
    end)
end)

-----------------------------------------------------------------
-- /accelcal — ONE-SHOT NEUTRAL CALIBRATION (no feedback loop).
-- The old version multiplied the CURRENT factor by measured/target, but the
-- measurement already INCLUDED that factor — so it fed on itself and ran away
-- (granvia drifted to the floor, 4x too slow). This version instead:
--   1. SUSPENDS the factor (gbSpeedCalSuspend) so the car runs at its TRUE NEUTRAL
--      baseline (= the tuner's handling.meta = "the original value").
--   2. Arms the timer; you floor it from a stop (a normal clean pull).
--   3. On completion computes, per gear, factor = neutralTime / targetTime  (time is
--      proportional to 1/torque, so this lands the target in ONE shot), stores it,
--      and re-enables the factor. No compounding — re-running just re-measures the
--      same neutral baseline and computes the same answer, so it can't run away.
-- A gear already within ConvergeTolSec of target is left at 1.00 (neutral = correct).
-----------------------------------------------------------------

-- Shared: compute per-gear factors from a NEUTRAL pull's gear segments vs targets.
-- Returns (factors{4}, report{}) or (nil, reason). Pure — no side effects.
local function speedCalComputeFromNeutral(tgt, gearSeg, opts)
    opts = opts or {}
    local fMin = opts.fMin or 0.40
    local fMax = opts.fMax or 1.40
    local tol  = opts.tol  or 0.40        -- gear within this many s of target => leave neutral
    local TT   = speedCalTargetTimeAt
    if not (gearSeg and next(gearSeg)) then return nil, 'no per-gear data' end
    local f, report, any = { 1.0, 1.0, 1.0, 1.0 }, {}, false
    for g = 1, 4 do
        local s = gearSeg[g]
        if s and s.vOut > s.vIn and s.tOut > s.tIn then
            local tIn, tOut = TT(tgt, s.vIn), TT(tgt, s.vOut)
            if tIn and tOut then
                local tSeg = tOut - tIn          -- target time for this gear's speed range
                local nSeg = s.tOut - s.tIn      -- NEUTRAL measured time for the same range
                if tSeg > 0 and nSeg > 0 then
                    any = true
                    if math.abs(nSeg - tSeg) <= tol then
                        report[#report+1] = ('g%d %.2f~%.2f ok'):format(g, nSeg, tSeg)
                    else
                        -- slower than target (nSeg>tSeg) => need MORE torque => factor>1
                        local fac = nSeg / tSeg
                        if fac < fMin then fac = fMin elseif fac > fMax then fac = fMax end
                        f[g] = fac
                        report[#report+1] = ('g%d[%.0f-%.0f] %.2f/%.2f =x%.2f')
                            :format(g, s.vIn, s.vOut, nSeg, tSeg, fac)
                    end
                end
            end
        end
    end
    if not any then return nil, 'no gear covered a target range' end
    return f, report
end
HK.speedCalComputeFromNeutral = speedCalComputeFromNeutral

-- accelcal phase machine: 'idle' | 'arming' (waiting for the baseline pull to finish).
local accelcalState = { phase = 'idle', hash = nil, name = nil, spawnId = nil }

-- /hybridspeedcap -> update the live GLOBAL hybrid e-mode profile (cap + power).
RegisterNetEvent('hk-handling:gearbox:setHybridCap', function(cap, power)
    local HY = Config.Gearbox and Config.Gearbox.Hybrid
    if not HY then return end
    cap = tonumber(cap)
    if cap and cap > 0 then HY.CapKmh = cap end
    power = tonumber(power)
    if power then HY.PowerFrac = power end
    -- keep the resume-speed hysteresis a sensible margin under the new cap.
    if HY.CapKmh then HY.ResumeKmh = math.max(10.0, HY.CapKmh - 20.0) end
    vl_notify(('Hybrid e-mode: cap %.0f km/h%s'):format(
        HY.CapKmh or 0, power and (', power %d%%'):format(math.floor(power * 100 + 0.5)) or ''), 'inform')
end)

RegisterNetEvent('hk-handling:gearbox:accelcalRun', function()
    local SC = Config.Gearbox and Config.Gearbox.SpeedCal
    if not (SC and SC.Enabled) then vl_notify('~r~SpeedCal disabled', 'error'); return end

    local veh = driverVeh()
    if veh == 0 then vl_notify('~r~Not in a vehicle', 'error'); return end
    local hash = GetEntityModel(veh) & 0xFFFFFFFF
    local m = HK.manualModels and HK.manualModels[hash]
    if not (m and m.speedCal) then
        vl_notify('~r~No /setspeed target on this car — set one first', 'error'); return
    end

    -- ARM a neutral baseline pull. Suspend the factor so the timing is the raw car,
    -- then arm the shared timer. The completion hook (below) does the one-shot compute.
    local name = GetLabelText(GetDisplayNameFromVehicleModel(GetEntityModel(veh)))
    if not name or name == '' or name == 'NULL' then name = GetDisplayNameFromVehicleModel(GetEntityModel(veh)) end
    accelcalState.phase  = 'arming'
    accelcalState.hash   = hash
    accelcalState.name   = name
    accelcalState.spawnId = spawnNameByHash[hash] or ''
    if HK.speedCalSuspend then HK.speedCalSuspend(true) end     -- factor OFF for the baseline run
    if HK.accelArmBaseline then HK.accelArmBaseline() end       -- arm the timer (acceltimer.lua)
    vl_notify('~b~accelcal: factor OFF — floor it from a stop (measuring baseline)', 'primary')
    print('[hk-accelcal] baseline pull armed (neutral). Floor it from a full stop.')

    -- WATCHDOG: if the baseline pull is never completed (player drives off / gives up),
    -- don't leave the factor suspended forever. Auto-cancel after the timeout.
    local armId = (accelcalState.armCount or 0) + 1
    accelcalState.armCount = armId
    CreateThread(function()
        Wait((SC.AccelCalArmTimeoutMs) or 90000)
        if accelcalState.phase == 'arming' and accelcalState.armCount == armId then
            accelcalState.phase = 'idle'
            if HK.speedCalSuspend then HK.speedCalSuspend(false) end
            if HK.accelCancel then HK.accelCancel() end
            vl_notify('~y~accelcal: timed out — factor restored', 'primary')
            print('[hk-accelcal] baseline pull timed out; factor re-enabled.')
        end
    end)
end)

-- Completion hook the timer calls when a baseline pull finishes (passes the per-gear
-- segments from the NEUTRAL run). Computes + stores the one-shot factor, re-enables.
HK.accelcalOnBaseline = function(gearSeg)
    if accelcalState.phase ~= 'arming' then
        if HK.speedCalSuspend then HK.speedCalSuspend(false) end
        return
    end
    accelcalState.phase = 'idle'
    if HK.speedCalSuspend then HK.speedCalSuspend(false) end    -- factor back ON for driving

    local SC = Config.Gearbox and Config.Gearbox.SpeedCal
    local hash = accelcalState.hash
    local m = HK.manualModels and HK.manualModels[hash]
    if not (SC and m and m.speedCal) then
        vl_notify('~r~accelcal: target vanished', 'error'); return
    end

    local tgt = {}
    for k, t in tostring(m.speedCal):gmatch('(%d+%.?%d*)%s*,%s*(%d+%.?%d*)') do
        local kk = math.floor(tonumber(k) or 0); if kk > 0 then tgt[kk] = tonumber(t) end
    end

    local f, report = speedCalComputeFromNeutral(tgt, gearSeg, {
        fMin = SC.FactorMin or 0.40, fMax = SC.FactorMax or 1.40,
        tol  = SC.ConvergeTolSec or 0.40,
    })
    if not f then
        vl_notify(('~y~accelcal: %s — pull again (clean WOT from a stop)'):format(report or 'no data'), 'primary')
        return
    end

    local packed = speedCalPack(f)
    TriggerServerEvent('hk-handling:gearbox:setSpeedModel', hash, accelcalState.spawnId, accelcalState.name, m.speedCal, packed)
    vl_notify(('~g~accelcal LOCKED: gears %.2f/%.2f/%.2f/%.2f'):format(f[1], f[2], f[3], f[4]), 'success')
    print('[hk-accelcal] ' .. table.concat(report, '  |  ') ..
          ('  -> %.2f/%.2f/%.2f/%.2f (one-shot from neutral)'):format(f[1], f[2], f[3], f[4]))
    print('[hk-accelcal] stored. /accel to verify (now WITH the factor applied).')
end


-- SEED-ON-SIT helper: ask the server to create a default row for a car-class
-- vehicle that has no row yet. Server gates on isAdmin + row-absence; we dedupe
-- per model per session so we don't re-ask every entry. No-op if a row exists.
-- Deliberately does NOT read the vehicle DISPLAY NAME here (that's cosmetic and
-- only safe/needed on an explicit admin /setgear) — seed sends hash + spawn
-- id only, so this broad per-entry path never touches the name API.
local seedAsked = {}
function maybeSeedModel(veh)
    if veh == 0 or not DoesEntityExist(veh) then return end
    if not isCarClass(veh) then return end
    local hash = GetEntityModel(veh) & 0xFFFFFFFF
    if seedAsked[hash] then return end
    if HK.manualModels and HK.manualModels[hash] then return end  -- already has a row
    seedAsked[hash] = true
    local spawn = spawnNameByHash[hash] or ''
    TriggerServerEvent('hk-handling:gearbox:seedModel', hash, spawn, spawn)
end

-- Build the hash -> spawn-id reverse map once (GetAllVehicleModels gives spawn
-- name strings; GetDisplayNameFromVehicleModel gives the DISPLAY label, not this).
CreateThread(function()
    local models = GetAllVehicleModels()
    if models then
        for i = 1, #models do
            local nm = models[i]
            if nm and nm ~= '' then
                spawnNameByHash[GetHashKey(nm) & 0xFFFFFFFF] = string.lower(nm)
            end
        end
        if Config.Gearbox and Config.Gearbox.Debug then
            local n = 0 for _ in pairs(spawnNameByHash) do n = n + 1 end
            print('[hk-gearbox] spawn-id map built: ' .. n .. ' models')
        end
    end
end)

-- Ask the server for the model list once we're loaded.
CreateThread(function()
    Wait(2000)  -- let player/session settle
    TriggerServerEvent('hk-handling:gearbox:requestModels')
end)

-----------------------------------------------------------------
-- SELF-CONTAINED ENTRY WATCHER
-- Don't rely on jim firing an event. Poll the driven vehicle; when it
-- changes, run our OWN resolution (DB row + car-class default). This is what
-- makes the box activate on entry regardless of jim's events.
--
-- NOTE: handling-flag detection (strHandlingFlags 0x1000000 / strAdvancedFlags
-- 0x400) has been REMOVED — it was unreliable and is no longer part of how a car
-- is resolved. detectBreakdown() now only reports jim + mod-13 for debug context.
-----------------------------------------------------------------
local function detectBreakdown(veh)
    -- returns trigger results for debug visibility only (NOT used for resolution)
    local jim  = vl_jimIsManual(veh)
    local mod  = (vl_getVehicleMod(veh, 13) ~= -1)
    return jim, mod
end

CreateThread(function()
    if Config.Gearbox and Config.Gearbox.Debug then
        print('[hk-gearbox] loaded; entry watcher running. Enabled=' .. tostring(Config.Gearbox and Config.Gearbox.Enabled))
    end
    local lastVeh = 0
    while true do
        Wait(500)
        if Config.Gearbox and Config.Gearbox.Enabled then
            local veh = driverVeh()

            if veh ~= 0 and veh ~= lastVeh then
                -- Entered a (new/different) vehicle as driver.
                print(('[hk-reenable] ENTRY Enable: veh=%s lastVeh=%s'):format(tostring(veh), tostring(lastVeh)))
                lastVeh = veh
                if Config.Gearbox.Debug then
                    local jim, mod = detectBreakdown(veh)
                    local dbm = HK.manualModels and HK.manualModels[modelKey(veh)]
                    local dbStr = dbm and ('type'..dbm.type..'/paddle'..(dbm.paddle or 0)..'/ratio'..(dbm.ratio or 0)) or 'no-row'
                    local pt = resolvePublicType(veh)
                    print(('[hk-gearbox] entered veh %s class=%s | jimManual=%s mod13=%s | dbModel=%s -> publicType=%s')
                        :format(veh, GetVehicleClass(veh), tostring(jim), tostring(mod), dbStr, tostring(pt)))
                end
                Gearbox_Enable(veh)

                -- SEED-ON-SIT (admin convenience): a car-class vehicle with NO DB
                -- row gets a default row created so the table is browsable/editable.
                -- Server gates on isAdmin (non-admins are silently ignored) and on
                -- the row not already existing; we just avoid spamming per session.
                maybeSeedModel(veh)

            elseif veh ~= 0 and veh == lastVeh then
                -- SAME vehicle, still driving. ACTIVE HEALTH CHECK: noclip and
                -- other teleports can drop us out and back into the same handle
                -- without a clean exit, leaving the box silently inactive while
                -- our flags think nothing changed. If this car SHOULD run the box
                -- but isn't applied, re-arm it. (Self-healing — fixes the
                -- "manual check disappears after noclip" issue.)
                if (not applied or curVeh ~= veh) and shouldProcess(veh) then
                    print(('[hk-reenable] DROPOUT re-arm: applied=%s curVeh=%s veh=%s')
                        :format(tostring(applied), tostring(curVeh), tostring(veh)))
                    applied = false        -- clear stale flag so Enable's idempotency guard can't block
                    Gearbox_Enable(veh)

                -- DRIVETRAIN-MOD RE-SNAPSHOT. Same car, still applied — but /maxmods or
                -- /admincustoms may have just applied performance mods (engine/transmission/turbo),
                -- making GTA recompute the drivetrain. Our origins/seeds/gearcount are now stale =
                -- car won't move (the "undriveable until parked + re-taken" bug). Detect via the
                -- mod fingerprint and re-snapshot in place: Disable restores our (stale) baseline,
                -- then Enable re-captures origins from the MODDED live values. gbLiveUpgrade skips
                -- the neutral-start reset so it's seamless mid-drive (same path as a jim upgrade).
                elseif applied and curVeh == veh then
                    -- DRIVETRAIN-MOD RE-SNAPSHOT with DEBOUNCE. GetVehicleMod without a set mod kit
                    -- (common on EVs / addon cars) returns UNSTABLE values that flip frame-to-frame,
                    -- so a raw fp != stored comparison false-positived every ~0.5s poll -> a
                    -- re-snapshot LOOP -> Gearbox_Enable re-seeded evRegenLevel every poll -> EV regen
                    -- stuck at D3, couldn't change (2026-07-27 bug). FIX: only re-snapshot when the
                    -- fingerprint is DIFFERENT from the baseline AND has been STABLE at that new value
                    -- across two consecutive polls (a real /maxmods,/admincustoms change persists; the
                    -- read-noise oscillation does not). HK.modFpPending tracks the candidate.
                    local fp = HK.computeModFingerprint(veh)
                    -- STRIPPED-READ GUARD: an all-slots-empty fingerprint (every drivetrain mod
                    -- reads -1) is almost never a real change on a car we already snapshotted with
                    -- mods — it's a transient bad read (mod kit not ready that frame). Treat it as
                    -- "no change" so it can't tear down a modded box. A genuine mod REMOVAL still
                    -- registers because at least one slot changes to a real lower index, not all -1
                    -- at once; and even a true full-strip just waits for a stable non-garbage read.
                    local stripped = fp:match('^%-1:%-1:%-1:%-1:%-1:') ~= nil
                    if HK.modFingerprint and fp ~= HK.modFingerprint then
                        -- DIAGNOSTIC (unconditional): show the fingerprint transition every time it
                        -- differs, so we can see whether it's oscillating and between WHICH values.
                        print(('[hk-fpwatch] baseline=%s live=%s stripped=%s pending=%s')
                            :format(tostring(HK.modFingerprint), tostring(fp),
                                    tostring(stripped), tostring(HK.modFpPending)))
                    end
                    if HK.modFingerprint and fp ~= HK.modFingerprint and not stripped then
                        if HK.modFpPending == fp then
                            -- Stable-different across two polls -> a genuine mod change. Re-snapshot.
                            print(('[hk-reenable] FINGERPRINT re-snapshot (%s -> %s)')
                                :format(tostring(HK.modFingerprint), tostring(fp)))
                            HK.modFpPending = nil
                            gbLiveUpgrade = true
                            Gearbox_Disable(veh)
                            Gearbox_Enable(veh)
                        else
                            HK.modFpPending = fp     -- first sighting; confirm on the next poll
                        end
                    else
                        HK.modFpPending = nil          -- matches baseline again -> not a real change
                    end
                end

            elseif veh == 0 and lastVeh ~= 0 then
                -- MAYBE left the driver seat — but driverVeh() returns 0 for a SINGLE poll on
                -- transient conditions that are NOT a real exit: a noclip toggle, a high-speed
                -- entity re-stream, or entity-control migration all make GetPedInVehicleSeat(veh,-1)
                -- momentarily read a different/null ped for a frame. Acting on that single 0 tore
                -- the box down mid-drive (Gearbox_Disable zeroes fInitialDriveForce + curVeh),
                -- then the next poll re-Enabled and captured a TRANSIENT driveForce=0 on the still-
                -- moving car -> no torque -> speed bleeds to 0 -> stuck -> cycle. (This is the
                -- "noclip on/off then random torque-drop to 0" bug.) DEBOUNCE: require TWO
                -- consecutive empty polls before believing it's a genuine exit. A real exit stays
                -- empty; a transient flicker is back in the seat by the next 500ms poll.
                if IsPedInAnyVehicle(PlayerPedId(), false) then
                    -- Still physically in a vehicle — the 0 was a seat-read flicker, not an exit.
                    -- Do NOT disable; leave lastVeh so the box keeps running on the same car.
                    HK.exitPollMisses = 0
                else
                    HK.exitPollMisses = (HK.exitPollMisses or 0) + 1
                    if HK.exitPollMisses >= 2 then
                        -- Confirmed out across two polls -> genuine exit.
                        HK.exitPollMisses = 0
                        lastVeh = 0
                        Gearbox_Disable(curVeh)
                    end
                    -- else: first confirmed-empty poll; wait one more before tearing down.
                end
            else
                HK.exitPollMisses = 0        -- any non-exit branch clears the debounce counter
            end
        end
    end
end)

-----------------------------------------------------------------
-- KEYBINDS — shift up / down / clutch. Only act while the box is running.
-----------------------------------------------------------------
-- Each shift key does THREE things on press: (1) sets a PENDING timestamp — a lone
-- press waits out a short chord window (NeutralChordMs) before the tick promotes it
-- to a real shift (reqUp/reqDown), so if the other key arrives inside that window
-- it's read as a CHORD (neutral), not two stray shifts; (2) sets a persistent HELD
-- flag (upHeld/downHeld) for the hold-both-to-neutral path; (3) records press
-- timestamps for the NEUTRAL gesture = BOTH keys pressed TWICE (up x2 + down x2)
-- within NeutralDoubleTapMs.
RegisterCommand('+hk_upshift', function()
    if processGearbox and applied then
        upHeld = true
        pendUpAt = GetGameTimer()
        upTapPrev, upTapAt = upTapAt, GetGameTimer()   -- shift press history (last two)
    end
end, false)
RegisterCommand('-hk_upshift', function() upHeld = false end, false)

RegisterCommand('+hk_downshift', function()
    if processGearbox and applied then
        downHeld = true
        pendDownAt = GetGameTimer()
        downTapPrev, downTapAt = downTapAt, GetGameTimer()
    end
end, false)
RegisterCommand('-hk_downshift', function() downHeld = false end, false)

-- ONE gear key (the FiveM-rebindable 'Gearbox: Clutch' bind). This handler ONLY
-- records the raw input state (clutchHeld). What it MEANS is decided per active
-- transmission, and the branches are mutually exclusive by gearMode so it can
-- never be interpreted two ways at once:
--   * mode 1 manual -> read as a HELD clutch (coast/shift gate)
--   * mode 3/4 DCT  -> read as an EDGE TOGGLE (auto <-> paddle), via dctClutchPrev
RegisterCommand('+hk_clutch', function()
    clutchHeld = true
    if Config.Gearbox.Debug then print('[hk-gearbox] gear-key down') end
end, false)
RegisterCommand('-hk_clutch', function()
    clutchHeld = false
    if Config.Gearbox.Debug then print('[hk-gearbox] gear-key up') end
end, false)

RegisterKeyMapping('+hk_upshift',   'Gearbox: Shift Up',   'keyboard', Config.Keys.ShiftUp)
RegisterKeyMapping('+hk_downshift', 'Gearbox: Shift Down', 'keyboard', Config.Keys.ShiftDown)
RegisterKeyMapping('+hk_clutch',    'Gearbox: Clutch',     'keyboard', Config.Keys.Clutch)

-----------------------------------------------------------------
-- NETWORKED EV/HYBRID ENGINE AUDIO — the fix for "passengers/other players hear the
-- stock engine, not the electric hum." ForceVehicleEngineAudio is CLIENT-LOCAL, so the
-- driver's swap never reached anyone else. The driver publishes the desired audio name to
-- the vehicle's REPLICATED `hk_ev_audio` statebag (see applyHybridAudio); this global
-- handler runs on EVERY client and applies the swap to that entity whenever the bag changes
-- — so all nearby players hear the EV sound / the engine wake. Value: audio-name string
-- ('NEON' etc.) = force that; '' or nil = restore the car's real engine.
--
-- Runs for ALL vehicles' bag changes (cheap: only fires on an actual change, and we no-op
-- unless the entity resolves locally). The driver's own client also gets this callback but
-- applyHybridAudio already applied it, so it's an idempotent re-apply.
if ForceVehicleEngineAudio then
    -- Per-entity dedupe: re-forcing the same audio name re-triggers the sound from the start
    -- (the 'NEON restart' spam + a stream hitch), so on OTHER clients too we only apply when
    -- the bag value actually changes for that entity. Weak-keyed so it GCs with the entity.
    local lastAudioByEnt = setmetatable({}, { __mode = 'k' })
    AddStateBagChangeHandler('hk_ev_audio', nil, function(bagName, _key, value, _reserved, _replicated)
        local ent = GetEntityFromStateBagName(bagName)
        if not ent or ent == 0 or not DoesEntityExist(ent) then return end
        local want = (type(value) == 'string' and value) or ''
        if lastAudioByEnt[ent] == want then return end   -- no change -> don't re-fire the sound
        lastAudioByEnt[ent] = want
        ForceVehicleEngineAudio(ent, want)               -- want='NEON' forces EV note; ''=restore stock
        -- NOTE: the EV→ICE "dimmed until next gear" re-prime is NOT done here anymore. A gear bump
        -- in this handler gets nullified by the driver's per-frame DCT gear write, and it couldn't
        -- pick a safe rpm target. It's now a REAL rpm-aware single shift driven inside the DCT
        -- branch on the handoff edge (see HK.evReprimeArm / requestGear). This handler stays audio-only.
    end)

    -- PRELOAD the EV engine audio ONCE per client at startup, so the FIRST time any hybrid
    -- swaps to it there's no first-use stream hitch (the sound bank is already resident). We
    -- prime it on the player's own vehicle if in one, else it warms on first real swap anyway;
    -- the cheap reliable primer is a single no-op force+restore on any existing vehicle. Guarded.
    CreateThread(function()
        Wait(2000)   -- let audio subsystem settle after resource start
        local evName = (Config.Gearbox and Config.Gearbox.Hybrid and Config.Gearbox.Hybrid.EVAudio) or 'NEON'
        -- Priming via a throwaway force on the player's current vehicle (if any); otherwise the
        -- first hybrid swap loads it. RequestScriptAudioBank needs a bank PATH we don't have for
        -- a game-object name, so a one-shot force is the practical primer.
        local ped = PlayerPedId()
        local v = ped and GetVehiclePedIsIn(ped, false) or 0
        if v ~= 0 and DoesEntityExist(v) then
            local ok = pcall(function()
                ForceVehicleEngineAudio(v, evName)   -- load NEON into memory
                ForceVehicleEngineAudio(v, '')       -- immediately restore (bank stays resident)
            end)
            if ok and Config.Gearbox and Config.Gearbox.Debug then
                print('[hk-hybrid] EV audio ('..evName..') preloaded')
            end
        end
    end)
end

-----------------------------------------------------------------
-- RPM PASSENGER / SPECTATOR SYNC — REMOTE APPLIER.
-- Mirror of the hk_ev_audio handler, but for the ICE engine NOTE. The driver publishes the live
-- painted rpm to the vehicle's replicated `hk_gearsync_rpm` bag (see publishSyncRpm). Here, on
-- EVERY client, we cache the latest value per entity and — for any car we're NOT the driver of —
-- feed it back into SetVehicleCurrentRpm every frame so the engine note matches the driver's
-- actual gear/shift/launch/neutral. Must re-apply per-frame (not just on bag change): the native
-- decays toward the physics rpm otherwise, so a one-shot set wouldn't hold the driver's value.
-- Feel-only; SetVehicleCurrentRpm drives AUDIO + tach, never force. No effect on the driver (they
-- own the paint) or on cars without an active hk-handling driver (bag absent/stale -> skipped).
-- Applier lives entirely inside CreateThread closures (the main chunk is at the 200-local limit,
-- so no new main-chunk local fits). The bag-change handler + per-frame applier share `syncByEnt`
-- via an upvalue captured inside this outer closure.
CreateThread(function()
    local RS = Config.Gearbox and Config.Gearbox.RpmSync
    if not RS or RS.Enabled == false then return end
    -- SET_VEHICLE_CURRENT_GEAR has no static hash / no bare Lua wrapper in this build (the driver
    -- side goes through vehlib's InvokeNative). Resolve the same runtime hash here for the applier.
    local HASH_SET_GEAR = GetHashKey('SET_VEHICLE_CURRENT_GEAR') & 0xFFFFFFFF
    -- Weak-keyed per-entity cache: { gear = native gear, rpm = painted rpm, at = ms received }.
    -- GCs with the entity. Value on the bag is { g = gear, r = rpm } (see publishSync).
    local syncByEnt = setmetatable({}, { __mode = 'k' })
    AddStateBagChangeHandler('hk_gearsync_rpm', nil, function(bagName, _key, value, _reserved, _replicated)
        local ent = GetEntityFromStateBagName(bagName)
        if not ent or ent == 0 then return end
        -- nil (driver left) OR malformed -> stop forcing this car.
        if type(value) ~= 'table' or type(value.r) ~= 'number' or value.r ~= value.r then
            syncByEnt[ent] = nil
            return
        end
        local rec = syncByEnt[ent]
        if rec then rec.gear, rec.rpm, rec.at = value.g or 1, value.r, GetGameTimer()
        else syncByEnt[ent] = { gear = value.g or 1, rpm = value.r, at = GetGameTimer() } end
    end)

    local rangeM = RS.ApplyRangeM or 120.0
    local range2 = rangeM * rangeM
    local staleMs = RS.StaleMs or 400
    while true do
        Wait(0)                              -- per-frame: the native decays + GTA's local box re-shifts, so re-assert each tick
        if next(syncByEnt) then
            local ped = PlayerPedId()
            local myVeh = GetVehiclePedIsIn(ped, false)
            local iAmDriver = (myVeh ~= 0 and GetPedInVehicleSeat(myVeh, -1) == ped)
            local px, py, pz = table.unpack(GetEntityCoords(ped))
            local now = GetGameTimer()
            for ent, rec in pairs(syncByEnt) do
                if not DoesEntityExist(ent) then
                    syncByEnt[ent] = nil
                elseif (now - rec.at) > staleMs then
                    syncByEnt[ent] = nil     -- driver stopped publishing (left / crash) -> release
                elseif not (iAmDriver and ent == myVeh) then
                    -- Not our own driven car -> apply if in audible range. (Passenger in the
                    -- SAME car OR a nearby spectator both hit this path; the driver's own
                    -- client skips its car since it already paints it.) Pin GEAR then RPM: the
                    -- gear stops GTA's LOCAL auto-box re-pitching the note (the "kinda carried"
                    -- bug), and reproduces free-rev N + reverse (gear 0); rpm sets the pitch.
                    local ex, ey, ez = table.unpack(GetEntityCoords(ent))
                    local dx, dy, dz = ex - px, ey - py, ez - pz
                    if (dx*dx + dy*dy + dz*dz) <= range2 then
                        Citizen.InvokeNative(HASH_SET_GEAR, ent, rec.gear)   -- pin native gear (note pitch base)
                        SetVehicleCurrentRpm(ent, rec.rpm)                   -- pin rpm (note pitch)
                    end
                end
            end
        end
    end
end)

