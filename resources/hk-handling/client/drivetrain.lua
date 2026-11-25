-----------------------------------------------------------------
-- hk-handling :: client/drivetrain.lua
-- Drivetrain-aware base handling (runs OUTSIDE drift mode).
--
-- Classifies each vehicle by fDriveBiasFront and routes to the right
-- handler. Detection ranges from [[fdrivebiasfront-drivetrain-thresholds]]:
--   RWD  : bias < 0.49   -> real oversteer model (progressive oversteer, counter-steer reward,
--                           lift-rotation, spin softener, corner-exit drive-out/throttle-steer)
--   AWD  : 0.49 .. 0.61  -> understeer on power, traction governor, torque vectoring, power-out save
--   FWD  : bias > 0.61   -> full hot-hatch model (power understeer, drive-out, lift-rotation +
--                           speed-scale + snap softener, torque steer, sport-diff, spin penalty,
--                           braking understeer)
--
-- Was client/awd.lua (RWD-only wheelspin assist). Renamed 2026-08-10 when
-- real AWD + FWD handling was folded in.
-----------------------------------------------------------------

local vehlib = exports['hk-vehlib']
local function bind(fn) return function(...) return fn(nil, ...) end end
-- Cache export refs once (avoids per-frame wrapper-closure GC churn; see gearbox.lua).
local vl_getHandling = bind(vehlib.getHandling)
local vl_setHandling = bind(vehlib.setHandling)
local vl_setTorque   = bind(vehlib.setTorque)
local vl_brakeWheel  = bind(vehlib.brakeWheel)   -- per-wheel brake pressure (torque vectoring)
local vl_scaleHandling = bind(vehlib.scaleHandling)  -- scale a field from its captured native (TC-off grip drop)
local vl_restoreField  = bind(vehlib.restoreField)   -- restore a scaled field to native

-- Wheel indices: 0=FL, 1=FR, 2=RL, 3=RR
local REAR_WHEELS = { 2, 3 }

-- Drivetrain classes
local CLASS_RWD = 'rwd'
local CLASS_AWD = 'awd'
local CLASS_FWD = 'fwd'

-- Per-vehicle capture (reset on vehicle change)
local trackedVeh        = 0
local driveClass        = nil   -- CLASS_RWD / CLASS_AWD / CLASS_FWD
local nativeFrontBias   = nil   -- native fDriveBiasFront
local nativeTractionBias = nil  -- native fTractionBiasFront
local nativeSteerLock   = nil   -- native fSteeringLock (FWD_BrakeUndersteer restore anchor)

-- THROTTLE MODEL state (2026-08-13). Device-agnostic effective throttle: keyboard W is binary, so we
-- synthesize analog "pedal travel" from time-pressed; controller/wheel analog passes through smoothed.
-- Detected per-session by watching for a raw value strictly between the epsilons (only analog hits it).
-- (Throttle model state MOVED to main.lua — HK.ThrottleModel_Tick is the single per-frame owner and
-- writes state.effThrottle + state.rpmFactor onto the snapshot. GRIP ASSISTS here intentionally read
-- RAW state.throttle, NOT effThrottle: they gate on player INTENT ("asking for power" — binary is fine
-- and works identically on controller), and coupling them to the modeled pedal made them starve when
-- effThrottle ramped/collapsed. effThrottle drives THROTTLE FEEL (main.lua injection); assists read raw.)

-- RWD wheelspin-assist state (LEGACY fake-AWD net — retired by default, see config RWD.LegacyAssist)
local awdFactor = 0.0           -- smoothed 0..1 (0 = native, 1 = max front shift)

-- RWD PROGRESSIVE POWER-OVERSTEER state (2026-08-13 — real RWD build #1). Feathers the yaw-accel
-- SPIKE that makes GTA's RWD snap (not the slide itself), so power-on oversteer is catchable.
local poPrevSlip = 0.0          -- last frame's rear-slip (m/s), to measure the RISE rate
local poFactor   = 0.0          -- smoothed 0..1 feather engagement

-- RWD COUNTER-STEER REWARD state (2026-08-13 — real RWD build #2). Helps a slide settle WHEN you
-- catch it with correct counter-lock. Skill in, stability out — does nothing if you don't catch it.
local csFactor = 0.0            -- smoothed 0..1 reward engagement

-- RWD LIFT-OFF / THROTTLE ROTATION state (2026-08-13 — real RWD build #3). Lift mid-corner → the
-- car rotates in (inner-rear brake vectoring, tail-happy). Non-latching brake → release each frame.
local lrFactor      = 0.0       -- smoothed 0..1 rotation engagement
local lrBrakedWheel = nil       -- which inner-rear wheel we braked last frame (to release it)

-- RWD SPIN SOFTENER state (2026-08-13). Slows the yaw RATE of a RWD spin so it's catchable (stronger
-- than AWD's; works on-power too since RWD power-on spin is the main event). Separate factor from AWD.
local rwdSpinFactor = 0.0       -- smoothed 0..1 softener engagement

-- RWD CORNER-EXIT DRIVE-OUT + THROTTLE-STEER state (2026-08-13 — real RWD build #4). Throttle as a
-- steering input: moderate gas plants (rear-grip squat), high gas rotates (throttle-steer vectoring).
local doPlantFactor  = 0.0      -- smoothed 0..1 squat/hook-up (traction-bias plant) engagement
local doPlantBiasOn  = false    -- did the plant shift fTractionBiasFront last frame? (so we can restore it)
local doRotFactor    = 0.0      -- smoothed 0..1 throttle-steer engagement
local doRotWheel     = nil      -- which inner-rear wheel throttle-steer braked last frame (to release it)
-- RWD WEIGHT-TRANSFER MIRRORS (2026-08-14 — first consumers of the HK.load spine). Two NEW rear-axle
-- tools mirroring the FWD front-axle ones, reading load.rear/load.long instead of re-deriving.
local rbrFactor      = 0.0      -- RWD_BrakeRotation: smoothed 0..1 trail-brake rotation engagement
local rbrWheel       = nil      -- inner-rear wheel brake-rotation vectored last frame (to release it)
local rpsFactor      = 0.0      -- RWD_PowerSpin: smoothed 0..1 inside-rear one-wheel-spin engagement
local rpsWheel       = nil      -- inner-rear wheel power-spin braked last frame (to release it)

-- HIGH-SPEED TRACTION-BIAS CENTERING (2026-08-14 — pairs with gravity downforce).
-- Extra gravity at speed amplifies any off-center fTractionBiasFront, worsening
-- understeer/oversteer. On straight-line high-speed cruise (no cornering tool
-- owning the field), pull the applied bias a hair toward 0.5 — 3rd-decimal only.
local biasCenterOn  = false     -- did centering shift fTractionBiasFront last frame? (so we restore it)
local biasCenterCur = nil       -- the last centered value we wrote (for smoothing)

-- FWD state (2026-08-14 — real front-wheel-drive character). Four tools mirroring AWD/RWD mechanisms.
local fwUnderBias   = nil       -- live fDriveBiasFront being applied for power understeer (nil = native)
local fwUnderSettle = 0         -- GetGameTimer() ms: hold bias native until here after a landing
local fwLiftFactor  = 0.0       -- smoothed 0..1 lift-off rotation engagement (inner-rear brake)
local fwLiftWheel   = nil       -- which inner-rear wheel lift-rotation braked last frame (to release it)
local fwPlantFactor = 0.0       -- smoothed 0..1 corner-exit drive-out engagement (traction-bias plant)
local fwPlantOn     = false     -- did the drive-out shift fTractionBiasFront last frame? (so we can restore it)
local fwTsFactor    = 0.0       -- smoothed 0..1 torque-steer tug engagement
local fwTsWheel     = nil       -- which front wheel the torque-steer pulse braked last frame (to release it)
-- FWD JDM pack (2026-08-14)
local fwSportDiff   = nil       -- cached true/false: is THIS car a sport-diff (LSD) car? (per-vehicle)
local fwSdFactor    = 0.0       -- smoothed 0..1 LSD hook-up engagement
local fwSdWheel     = nil       -- which inside-front wheel the LSD hook braked last frame (to release it)
local fwSpinCut     = 0.0       -- smoothed 0..1 front-wheelspin torque-penalty engagement
local fwBrakeUsFactor = 0.0     -- smoothed 0..1 braking-understeer (front-lock) engagement
local fwSpinSoft    = 0.0       -- smoothed 0..1 lift-snap yaw-rate softener engagement (catch safety)
local fwStraightFactor = 0.0    -- smoothed 0..1 braking-straighten engagement (front-load yaw damp, spine mirror of RWD_BrakeRotation)

-- TC-OFF proactive grip-drop state (2026-08-14). Three grip fields (Max/Min/LowSpeedLoss) shifted under
-- throttle while TC off, so switching TC off is FELT immediately (car wants to break loose) not just when
-- slip already exists. Same field trio drift.lua uses (safe: drift force-disables TC, never co-active).
local tcOffGripF   = 0.0        -- smoothed 0..1 grip-drop engagement
local tcOffGripOn  = false      -- did we scale the grip fields last frame? (so we restore to native once)

-- AWD understeer state
local awdUnderBias = nil        -- live fDriveBiasFront being applied for understeer
local awdBumpUntil = 0         -- GetGameTimer() ms: bump-suppression window (post-bump grip hold)
local awdBumpReactAt = 0       -- ms: when bump damping may START (after the reaction latency)
local awdLandCorrectAt = 0     -- ms: first GROUNDED frame of a correction (ease-in origin so the touchdown damp ramps, not yanks)
local awdWasAirborne = false   -- previous-frame airborne flag (to detect the land transition)
local awdPrevVelZ = 0.0        -- previous frame vertical velocity (for bump spike detection)
local awdPrevKmh = 0.0         -- previous frame speed (for longitudinal-accel detection)
local awdLandSettleUntil = 0   -- suspend understeer engage until this time after a landing
local awdSteerAngle = nil      -- rate-limited wheel angle we're driving (deg); nil = unsynced

-- AWD CORNER-EXIT TRACTION GOVERNOR state (2026-08-12 v7.20 — feature #1). Real AWD puts power down
-- early/hard without the rear breaking loose because torque routes to the axle WITH grip. On
-- throttle-induced rear wheelspin we (a) shift drive bias FORWARD to plant it (primary — a torque
-- TRANSFER, not a cut, so it drives out instead of bogging), and (b) trim torque only as a backstop
-- when slip is still excessive. tcGovFactor is the smoothed 0..1 engage; tcGovBiasAdd is the extra
-- front-bias we layered THIS frame (recomputed fresh each tick — never accumulates on the field).
local tcGovFactor  = 0.0       -- smoothed 0..1 governor engagement (0 = no spin, 1 = full intervene)
local tcGovBiasOn  = false     -- did the governor inflate fDriveBiasFront last frame? (so we can restore it)

-- AWD POWER-OUT SAVE state (2026-08-12 v7.21 — feature #1b). Lift-off oversteer recovery: off-gas
-- the rear steps out, getting back on the throttle routes torque to the front axle and drags the
-- nose straight (power out of it). THROTTLE-ONLY. Separate smoothed factor from the exit governor.
local pwrSaveFactor = 0.0      -- smoothed 0..1 save engagement
local pwrSaveBiasOn = false    -- did the save inflate fDriveBiasFront last frame? (so we can restore it)
local pwrSaveLastAdd = 0.0     -- the forward-bias amount the save added last frame (subtracted back off so it never accumulates)

-- EXTREME-SLIP SPIN SOFTENER state (2026-08-13). Slows the RATE of the final spin-out past the
-- furthest angle (real AWD resists the snap; GTA lets go instantly). Smoothed engage so it eases
-- in/out instead of snapping the yaw rate.
local spinSoftFactor = 0.0     -- smoothed 0..1 softener engagement

-- TORQUE VECTORING state (2026-08-13 — feature #2). Real AWD brakes the INNER-REAR wheel under
-- power mid-corner to rotate the car and tighten the line (the outer wheels keep pulling, so no
-- loss of drive). GTA lacks this. Non-latching brake native → must re-apply/release each frame.
-- tvBrakedWheel is SHARED with LiftBalance's tuck-in (both use the inner-rear brake) so the two can
-- never leave the same wheel dragged — whichever ran last owns the release.
local tvFactor    = 0.0        -- smoothed 0..1 vectoring engagement
local tvBrakedWheel = nil      -- which wheel we applied brake pressure to last frame (to release it)

-- OFF-THROTTLE BALANCE state (2026-08-13 — feature #3). Lift mid-corner → tuck the nose in (rotate)
-- when understeering, or calm the rear when it steps out. Regime-separated by slip so they don't fight.
local lbTuckFactor = 0.0       -- smoothed 0..1 tuck-in (rotation) engagement
local lbTuckWheel  = nil       -- which inner-rear wheel tuck-in braked last frame (shares tvBrakedWheel coordination)

-- REAR-WHEEL STEER (4WS) state (2026-08-11). Some cars (AMG ONE etc.) carry HF_STEER_ALL_WHEELS
-- (strHandlingFlags bit 0x80): rears steer IN-PHASE at the full front lock at ALL speeds. We gate
-- that bit by speed (see RearSteer_Tick). strHandlingFlags is an INT field — hk-vehlib only wraps
-- FLOAT fields, so vl_restoreHandling won't touch it; we capture/restore it ourselves here.
local REARSTEER_BIT   = 0x80   -- HF_STEER_ALL_WHEELS (confirmed vs DurtyFree flag dump, bit 7)
local rearSteerCapable = false -- this vehicle natively carries HF_STEER_ALL_WHEELS
local rearSteerNative  = nil   -- captured native strHandlingFlags (full int, bit still set)
local rearSteerOn      = nil   -- current bit state we've applied (true=set / false=cleared); nil=unset

-- AWD REACTION-DELAY state (2026-08-10). A real electronic AWD/torque-vectoring system SENSES
-- the road with a small, variable latency before it acts — it doesn't react on the same tick.
-- We simulate that: on a fresh understeer-demand edge, hold off engaging for a randomized
-- 20-80ms that scales with speed+steering (more urgency = quicker reaction). Makes the assist
-- feel like it's "reading" the road instead of snapping on robotically.
local awdReacting = false      -- true once a demand edge has armed a reaction
local awdReactUntil = 0        -- ms until the understeer engage is allowed to start ramping

-- AWD HANDBRAKE PIVOT+CATCH state (2026-08-12 v7.19). A real AWD on the handbrake pivots (rears
-- lock) then the still-gripping FRONT axle recovers the slide so it settles instead of spinning.
-- We model that: on a fresh handbrake pull, let the car rotate freely for a short window, then
-- ease in a front-axle "catch" (lateral-slide damp) so the tail comes back in. Released on let-go.
local awdHbActive   = false    -- handbrake currently held (edge tracking)
local awdHbStartAt  = 0        -- ms the current handbrake pull began (for the free-rotate window)

-- HANDBRAKE-RELEASE CUSHION state (2026-08-14, ALL drivetrains). See HandbrakeReleaseCushion_Tick.
-- On the instant the handbrake is let go, GTA re-grips the locked rears all at once — that
-- velocity discontinuity SNAPS the car's forward speed down too hard and turns any leftover lateral
-- slide into a yaw KICK ("spins weird"). Same native velocity-dump family as the airborne-landing and
-- downshift re-grip reports. We soften the release: cap the decel to a gentle rate + bleed the yaw/
-- lateral transient, fading out by the time speed has dropped to half the release speed.
local hbrPrevHeld    = false   -- last frame's handbrake state (release edge = was held, now not)
local hbrReleaseAt   = 0       -- ms the release fired (cushion-window origin)
local hbrReleaseKmh  = 0.0     -- speed at the instant of release (the "scale off by half of this")
local hbrPrevSpeed   = 0.0     -- last frame's m/s speed (for measuring the snap decel)

-- WEIGHT-TRANSFER SPINE (2026-08-14) — module state for the central load model. See WeightTransfer_Tick.
-- GTA has no weight transfer (rigid box, static per-axle grip); every drivetrain helper fakes ONE
-- consequence of it. This computes the load ONCE per frame so tools can read a single consistent
-- signal. Additive/read-only for now — nothing consumes it yet (Phase 2 of the plan).
local wtVeh          = 0        -- vehicle the accel tracker is synced to (reset dv/dt on a swap)
local wtPrevFwd      = 0.0      -- previous frame forwardSpeed (m/s) for the dv/dt accel estimate
local wtLongAccel    = 0.0      -- smoothed longitudinal accel estimate (m/s^2): + = speeding up, - = braking
local wtLong         = 0.0      -- smoothed longitudinal load -1..1 (-1 full brake / nose-down, +1 full accel / squat)
local wtLat          = 0.0      -- smoothed lateral load -1..1 (sign = turn dir like yawRate, mag = corner load)
local wtFront        = 0.5      -- effective front-axle load 0..1
local wtRear         = 0.5      -- effective rear-axle load 0..1
local wtSlipDeg      = 0.0      -- INSTANT slip angle (deg) — shared by every helper (de-dup, not smoothed)

-----------------------------------------------------------------
-- HELPERS
-----------------------------------------------------------------
local function lerpClamp(x, x0, x1, y0, y1)
    if x <= x0 then return y0 end
    if x >= x1 then return y1 end
    local t = (x - x0) / (x1 - x0)
    return y0 + (y1 - y0) * t
end

-- Detect rear-axle wheelspin (m/s of wheel over ground speed)
local function rearSlip(veh, groundSpeed)
    local worst = 0.0
    for _, w in ipairs(REAR_WHEELS) do
        local ws = math.abs(GetVehicleWheelSpeed(veh, w))
        local diff = ws - groundSpeed
        if diff > worst then worst = diff end
    end
    return worst
end

local function classify(bias)
    if bias < 0.49 then return CLASS_RWD
    elseif bias <= 0.61 then return CLASS_AWD
    else return CLASS_FWD end
end

-- REACTION LATENCY (2026-08-10): pick a randomized delay (ms) that scales with how urgent the
-- situation is — faster + more steering = the ECU reacts QUICKER (shorter delay); gentle low-
-- speed inputs get the longer end. Returns a value in [MinMs, MaxMs]. urgency is 0..1.
local function reactionDelayMs(urgency, dcfg)
    local minMs = dcfg.MinMs or 20.0
    local maxMs = dcfg.MaxMs or 80.0
    urgency = urgency or 0.0
    if urgency < 0.0 then urgency = 0.0 elseif urgency > 1.0 then urgency = 1.0 end
    -- high urgency -> near MinMs, low urgency -> near MaxMs
    local base = maxMs - (maxMs - minMs) * urgency
    -- ± jitter so it never feels metronomic (a real sensor/actuator isn't identical each time)
    local jitter = (dcfg.JitterMs or 12.0)
    local d = base + (math.random() * 2.0 - 1.0) * jitter
    if d < minMs then d = minMs elseif d > maxMs then d = maxMs end
    return d
end

-----------------------------------------------------------------
-- RWD BRANCH: wheelspin assist (fake AWD safety net)
-- Sends power/traction forward when the rear spins or the car rotates
-- hard, relaxing to native bias on a clean straight. Preserved from the
-- original awd.lua — this is the only branch that ran before 2026-08-10.
-----------------------------------------------------------------
local function RWD_WheelspinAssist(veh, state, dt, rcfg)
    -- Speed gate
    if state.speedKmh < rcfg.MinSpeedKmh then
        -- Relax toward native while crawling
        awdFactor = awdFactor + (0.0 - awdFactor) * (1.0 - math.exp(-dt / rcfg.ReleaseTau))
        if awdFactor < 0.01 then return end
    end

    -- Detect conditions that warrant sending power forward
    local slip = rearSlip(veh, state.speed)
    local yaw  = math.abs(state.yawRate)

    local slipping = slip > rcfg.SpinThreshold
    local rotating = yaw > rcfg.YawAssistThreshold
    local engage = (slipping or rotating) and state.speedKmh >= rcfg.MinSpeedKmh

    -- Smooth the transition
    local target = engage and 1.0 or 0.0
    local tau = engage and rcfg.EngageTau or rcfg.ReleaseTau
    awdFactor = awdFactor + (target - awdFactor) * (1.0 - math.exp(-dt / tau))

    if awdFactor < 0.01 then
        -- Fully relaxed: make sure we're on native bias
        vl_setHandling(veh, 'fDriveBiasFront', nativeFrontBias)
        vl_setHandling(veh, 'fTractionBiasFront', nativeTractionBias)
        return
    end

    -- Push drive bias toward the front, capped at MaxFrontBias
    local targetFront = nativeFrontBias + (rcfg.MaxFrontBias - nativeFrontBias) * awdFactor
    targetFront = math.min(targetFront, rcfg.MaxFrontBias)
    vl_setHandling(veh, 'fDriveBiasFront', targetFront)

    -- Nudge front traction bias so the front actually bites when powered
    local targetTraction = nativeTractionBias + rcfg.TractionBiasAssist * awdFactor
    vl_setHandling(veh, 'fTractionBiasFront', targetTraction)
end

-----------------------------------------------------------------
-- RWD PROGRESSIVE POWER-OVERSTEER (2026-08-13 — real RWD build #1)
-- The replacement for the retired fake-AWD net. GTA's RWD doesn't break traction too FAR, it breaks
-- too FAST: floor it and the tail snaps out on a yaw-acceleration spike that's near-impossible to
-- catch. Real RWD lets go PROGRESSIVELY — wheelspin builds, the rear steps out over a beat, and the
-- driver feathers/catches it. So we smooth the RATE of breakaway, never its magnitude: you can still
-- hang the tail fully out; it just won't snap. When rear wheelspin is RISING FAST (the spike), apply
-- a light, brief engine-torque trim (same HK.torqueMult re-apply path as the AWD governor — a torque
-- cut, no bog) to feather that spike. Steady-state slides have ~0 rise so they're untouched. It NEVER
-- adds grip or bias — it can't save you, only slow the snap so it's within a human's reaction window.
-----------------------------------------------------------------
local function RWD_ProgressiveOversteer(veh, state, dt, pcfg)
    if not pcfg or pcfg.Enabled == false then poPrevSlip = 0.0; poFactor = 0.0; return end

    local kmh = state.speedKmh or 0.0
    local thr = state.throttle or 0.0
    local airborne = (state.onAllWheels == false)

    -- Current rear wheelspin (m/s over ground) and its RISE rate vs last frame (m/s per second).
    local slip = rearSlip(veh, state.speed or 0.0)
    local rise = 0.0
    if dt > 0.0 then rise = (slip - poPrevSlip) / dt end
    poPrevSlip = slip

    -- Gate: real power, fast enough, planted. Off any gate → relax and bail (no lingering cut).
    local gated = (kmh >= (pcfg.MinSpeedKmh or 18.0))
        and (thr >= (pcfg.ThrottleGate or 0.55))
        and not airborne

    -- Demand = how fast the spin is SPIKING (rise past the gate). Only a rising spike feathers;
    -- a steady slide (rise ~0) or a settling one (rise < 0) demands nothing.
    local demand = 0.0
    if gated and rise > 0.0 then
        demand = lerpClamp(rise, pcfg.SlipRiseGate or 6.0, pcfg.SlipRiseFull or 22.0, 0.0, 1.0)
    end

    local tau = (demand > poFactor) and (pcfg.EngageTau or 0.05) or (pcfg.ReleaseTau or 0.14)
    poFactor = poFactor + (demand - poFactor) * (1.0 - math.exp(-dt / tau))
    if poFactor < 0.01 then poFactor = 0.0; return end

    -- TC-OFF STAND-DOWN: ProgressiveOversteer's torque-feather is a TC-like stability move (it bleeds
    -- the power spike so the snap is progressive). With TC switched off the player WANTS the rears to
    -- break loose, so reduce this cut by TCOff.StabilityStandDown — leave a sliver so a violent snap is
    -- still slightly feathered (arcade-catchable), but mostly get out of the way.
    local tcCutScale = 1.0
    do
        local to = HK.dtTCOff
        if to and to.on and to.rwdFree then tcCutScale = to.standDown end
    end

    -- TORQUE TRIM: feather the engine torque to bleed the power spike. Same re-apply path as the AWD
    -- governor — Drivetrain_Tick runs AFTER main.lua's vl_setTorque(HK.torqueMult), so multiply our
    -- cut onto the already-applied value and setTorque again (last write this frame wins), folding it
    -- back into HK.torqueMultApplied for diagnostics. A CUT only — never boosts torque or grip.
    local cut = 1.0 - (pcfg.MaxTorqueCut or 0.16) * poFactor * tcCutScale
    if cut < 0.999 and HK then
        local applied = (HK.torqueMultApplied or 1.0) * cut
        vl_setTorque(veh, applied)
        HK.torqueMultApplied = applied
    end
end

-----------------------------------------------------------------
-- RWD COUNTER-STEER REWARD (2026-08-13 — real RWD build #2)
-- Nothing currently rewards CATCHING a slide — you apply opposite lock and the car just does what
-- native physics says. In a real RWD, counter-steering points the fronts INTO the slide and the car
-- hooks back up as the rotation settles. SKILL IN, STABILITY OUT: when the rear is stepping out
-- (rotating past YawGate) AND you're steering to OPPOSE that rotation (correct counter-lock — the
-- same yaw-vs-steer sign test drift recovery uses: yaw +ve = rotating left, so correct lock is steer
-- to the right / negative), we help the slide settle via the only-ever-REDUCE lateral damp (can't
-- add slide or flip), scaled by rotation × how much correct counter-lock you're giving. No counter-
-- lock = no help, so a panic-spin (no correction, or steering the WRONG way) still spins out.
-- INDEPENDENT of throttle — you counter-steer on or off the gas.
-----------------------------------------------------------------
local function RWD_CounterSteerReward(veh, state, dt, ccfg)
    if not ccfg or ccfg.Enabled == false then csFactor = 0.0; return end

    local kmh   = state.speedKmh or 0.0
    local steer = state.steer or 0.0        -- -1..1
    local yaw   = state.yawRate or 0.0      -- rad/s (+ve = rotating left)
    local latS  = state.lateralSpeed or 0.0
    local fwd   = state.forwardSpeed or 0.0
    local airborne = (state.onAllWheels == false)
    local yawAbs = math.abs(yaw)

    -- SLIP ANGLE (heading vs velocity): the true "is the rear actually sliding" signal. Normal
    -- cornering keeps this small (a few deg); only genuine oversteer grows it. PRIMARY gate — without
    -- it the yaw+counter-lock test fires in normal hard cornering too (yaw is high there, and steer/
    -- yaw are opposite-signed there as well) and damps lateral every corner = a false AWD-grip buff.
    -- Shared slip from the spine (same frame, same math); inline fallback if the spine is disabled.
    local slipDeg = (HK.load and HK.load.slipDeg) or ((fwd > 1.0) and math.abs(math.deg(math.atan(latS / fwd))) or 0.0)

    -- Correct counter-lock = steering OPPOSITE to the rotation (same test as drift.lua recovery yield).
    local countering = (yaw > 0.0 and steer < 0.0) or (yaw < 0.0 and steer > 0.0)

    local active = (kmh >= (ccfg.MinSpeedKmh or 22.0))
        and (slipDeg >= (ccfg.SlipGateDeg or 12.0))    -- must be genuinely SLIDING, not just cornering
        and (yawAbs >= (ccfg.YawGate or 0.45))
        and countering
        and (math.abs(steer) >= (ccfg.SteerGate or 0.12))
        and (fwd > 1.0) and not airborne

    -- Demand = how hard the slide is (slip angle × yaw, both past their gates) × how much correct
    -- counter-lock you're giving. Slip is the dominant term — a car that isn't sliding earns nothing.
    local demand = 0.0
    if active then
        local slipF  = lerpClamp(slipDeg, ccfg.SlipGateDeg or 12.0, ccfg.SlipFullDeg or 32.0, 0.0, 1.0)
        local yawF   = lerpClamp(yawAbs, ccfg.YawGate or 0.45, ccfg.YawFull or 2.2, 0.0, 1.0)
        local steerF = math.min(math.abs(steer), 1.0)
        demand = slipF * yawF * steerF
    end

    local tau = (demand > csFactor) and (ccfg.EngageTau or 0.06) or (ccfg.ReleaseTau or 0.20)
    csFactor = csFactor + (demand - csFactor) * (1.0 - math.exp(-dt / tau))
    if csFactor < 0.01 then csFactor = 0.0; return end

    -- LATERAL-SLIDE DAMP: bleed the sideways slide so it settles as you hold the catch. Only ever
    -- REDUCES lateral velocity (same safe mechanism as BrakeStability) — can't add slide or flip.
    local damp = (ccfg.MaxLatDamp or 4.2) * csFactor
    if damp > 0.0 and math.abs(latS) > (ccfg.MinLatMs or 0.5) then
        local vel = state.velocity
        if vel then
            local k = math.exp(-damp * dt)
            local f2 = GetEntityForwardVector(veh)
            local rx, ry = f2.y, -f2.x
            local rmag = math.sqrt(rx*rx + ry*ry)
            if rmag > 0.001 then
                rx, ry = rx / rmag, ry / rmag
                local delta = latS * (k - 1.0)   -- negative = only ever shrinks |lat|
                SetEntityVelocity(veh, vel.x + rx * delta, vel.y + ry * delta, vel.z)
            end
        end
    end
end

-----------------------------------------------------------------
-- RWD LIFT-OFF / THROTTLE ROTATION (2026-08-13 — real RWD build #3)
-- The RWD signature GTA lacks: lift mid-corner → weight shifts forward, the rear goes light, and the
-- car ROTATES into the turn (tucks the nose in / trail-brake rotation). GTA's RWD tracks on rails
-- off-throttle. We add rotation with the PROVEN inner-rear brake vectoring (vl_brakeWheel — capped
-- below lockup, only ever ADDS to ONE wheel, can't flip), NOT a yaw-velocity servo. Tuned PLAYFUL:
-- a noticeable tuck that can step the rear out on a hard lift — #2 (counter-steer reward) is there to
-- catch it. FADES OUT as you get back on the power (that's #1's/#4's territory) so nothing fights.
-- Scaled by how hard you lifted (brake deepens it — trail-braking) × how loaded the corner is.
-- Inner rear: steer > 0 = turning RIGHT → RR (3); steer < 0 = LEFT → RL (2).
-----------------------------------------------------------------
local RWD_RR, RWD_RL = 3, 2   -- rear-right / rear-left wheel indices (0=FL 1=FR 2=RL 3=RR)
local function RWD_LiftRotation(veh, state, dt, lcfg)
    local function releaseLR()
        if lrBrakedWheel ~= nil then
            vl_brakeWheel(veh, lrBrakedWheel, 0.0)
            lrBrakedWheel = nil
        end
    end

    if not lcfg or lcfg.Enabled == false then lrFactor = 0.0; releaseLR(); return end

    local kmh   = state.speedKmh or 0.0
    local thr   = state.throttle or 0.0
    local brake = state.brake or 0.0
    local steer = state.steer or 0.0
    local latS  = state.lateralSpeed or 0.0
    local fwd   = state.forwardSpeed or 0.0
    local airborne = (state.onAllWheels == false)
    local wheelCount = state.wheelCount or GetVehicleNumberOfWheels(veh)

    -- AIRBORNE = INSTANT RELEASE (2026-08-14 fix): a per-wheel brake latched just before takeoff (entering
    -- a ramp in a slight slide) would otherwise keep acting through the ReleaseTau DECAY while the car is
    -- in the air — a braked rear wheel with no ground contact yaws the car hard to one side ("Dr Strange"
    -- sideways pull a moment after the rear steps out). The `not airborne` in `active` only stops NEW
    -- engagement; it does NOT drop the already-applied brake. So hard-release + zero the factor the instant
    -- we leave the ground — no decay in the air. Re-engages cleanly on touchdown.
    if airborne then lrFactor = 0.0; releaseLR(); return end

    -- Off-throttle cornering, planted, fast enough, 4-wheeled, moving forward.
    local active = (kmh >= (lcfg.MinSpeedKmh or 30.0))
        and (thr <= (lcfg.LiftGate or 0.25))
        and (math.abs(steer) >= (lcfg.SteerGate or 0.14))
        and (math.abs(latS) >= (lcfg.LatGateMs or 1.2))
        and (fwd > 1.0) and not airborne and wheelCount >= 4

    local demand = 0.0
    if active then
        -- Lift depth: full at zero throttle, fading to 0 by the gate (the more you lift, the more rotation).
        local liftF = lerpClamp(thr, 0.0, lcfg.LiftGate or 0.25, 1.0, 0.0)
        -- Corner load: how hard you're cornering (lateral speed past the gate).
        local latF  = lerpClamp(math.abs(latS), lcfg.LatGateMs or 1.2, lcfg.LatFullMs or 6.0, 0.0, 1.0)
        -- Trail-brake boost: braking shifts weight further forward = more rotation.
        local brakeBoost = 1.0 + (lcfg.BrakeBoost or 0.5) * math.min(brake, 1.0)
        demand = math.min(liftF * latF * brakeBoost, 1.0)
    end

    local tau = (demand > lrFactor) and (lcfg.EngageTau or 0.11) or (lcfg.ReleaseTau or 0.15)
    lrFactor = lrFactor + (demand - lrFactor) * (1.0 - math.exp(-dt / tau))
    if lrFactor < 0.01 then
        lrFactor = 0.0
        releaseLR()
        return
    end

    -- INNER rear = inside of the turn. steer > 0 = right → RR; left → RL.
    local inner = (steer >= 0.0) and RWD_RR or RWD_RL
    if lrBrakedWheel ~= nil and lrBrakedWheel ~= inner then
        vl_brakeWheel(veh, lrBrakedWheel, 0.0)   -- switched sides: release the old wheel
        lrBrakedWheel = nil
    end
    local pressure = (lcfg.MaxPressure or 0.20) * lrFactor
    vl_brakeWheel(veh, inner, pressure)
    lrBrakedWheel = inner
end

-----------------------------------------------------------------
-- RWD CORNER-EXIT DRIVE-OUT + THROTTLE-STEER (2026-08-13 — real RWD build #4)
-- The RWD "soul": the THROTTLE is a steering input. GTA models no weight transfer, so on exit a RWD
-- either grips on rails or spins — no satisfying "sit down and drive out," no rotating with the gas.
-- This makes the throttle a full expression range on corner exit, crossfaded by how much you feed:
--   PART A (moderate gas) → SQUAT / HOOK-UP: shift fTractionBiasFront REARWARD so the rear bites and
--     you drive out planted (weight-shift-rearward grip). Modest — plants, doesn't rail. Restores off-power.
--   PART B (high gas) → THROTTLE-STEER: plant fades, a gentle inner-rear brake vectors the car round —
--     hang the tail with your right foot (same vl_brakeWheel path as #3, capped below lockup, can't flip).
-- Both gated on real corner context (steering + lateral load) so straight-line / steady cornering stay
-- native (the #2 lesson). Too much gas → breaks loose, and #1 / spin softener / #2 handle the catch.
-----------------------------------------------------------------
local function RWD_DriveOut(veh, state, dt, dcfg)
    local function releaseRot()
        if doRotWheel ~= nil then
            vl_brakeWheel(veh, doRotWheel, 0.0)
            doRotWheel = nil
        end
    end
    local function restorePlant()
        if doPlantBiasOn then
            if nativeTractionBias ~= nil then
                vl_setHandling(veh, 'fTractionBiasFront', nativeTractionBias)
            end
            doPlantBiasOn = false
        end
    end

    if not dcfg or dcfg.Enabled == false then
        doPlantFactor = 0.0; doRotFactor = 0.0; releaseRot(); restorePlant(); return
    end

    local kmh   = state.speedKmh or 0.0
    local thr   = state.throttle or 0.0
    local steer = state.steer or 0.0
    local latS  = state.lateralSpeed or 0.0
    local airborne = (state.onAllWheels == false)
    local wheelCount = state.wheelCount or GetVehicleNumberOfWheels(veh)

    -- AIRBORNE = INSTANT RELEASE (see RWD_LiftRotation): drop BOTH the inner-rear brake AND the traction-
    -- bias plant the instant we leave the ground, so a latched vector can't yaw the car sideways mid-air.
    if airborne then
        doPlantFactor = 0.0; doRotFactor = 0.0; releaseRot(); restorePlant(); return
    end

    -- Corner context: cornering, planted, fast enough, 4-wheeled. Off it → relax both parts and bail.
    local cornering = (kmh >= (dcfg.MinSpeedKmh or 30.0))
        and (math.abs(steer) >= (dcfg.SteerGate or 0.14))
        and (math.abs(latS) >= (dcfg.LatGateMs or 1.5))
        and not airborne and wheelCount >= 4
    -- Corner-load scale (shared by both parts): more lateral load = more effect.
    local latF = cornering and lerpClamp(math.abs(latS), dcfg.LatGateMs or 1.5, dcfg.LatFullMs or 6.0, 0.0, 1.0) or 0.0

    -- ---- PART A: SQUAT / HOOK-UP (traction bias rearward) ----
    -- Throttle window: 0 at PlantThrGate, peak at PlantThrPeak, back to 0 by PlantThrFade (rotation
    -- takes over above that). Triangular so the plant lives in the mid-throttle drive-out band.
    local plantThrF = 0.0
    if cornering then
        local g, p, f = dcfg.PlantThrGate or 0.30, dcfg.PlantThrPeak or 0.65, dcfg.PlantThrFade or 0.85
        if thr > g and thr < f then
            if thr <= p then plantThrF = (thr - g) / math.max(p - g, 0.01)
            else plantThrF = (f - thr) / math.max(f - p, 0.01) end
        end
    end
    local plantDemand = plantThrF * latF
    local ptau = (plantDemand > doPlantFactor) and (dcfg.PlantEngageTau or 0.12) or (dcfg.PlantReleaseTau or 0.20)
    doPlantFactor = doPlantFactor + (plantDemand - doPlantFactor) * (1.0 - math.exp(-dt / ptau))
    if doPlantFactor < 0.01 then
        doPlantFactor = 0.0
        restorePlant()
    elseif nativeTractionBias ~= nil then
        -- Shift traction bias toward the REAR (lower fTractionBiasFront = more rear grip → hooks up).
        local target = nativeTractionBias - (dcfg.PlantBiasShift or 0.05) * doPlantFactor
        if target < 0.0 then target = 0.0 end
        vl_setHandling(veh, 'fTractionBiasFront', target)
        doPlantBiasOn = true
    end

    -- ---- PART B: THROTTLE-STEER (power-on inner-rear vectoring) ----
    local rotThrF = cornering and lerpClamp(thr, dcfg.RotThrGate or 0.70, dcfg.RotThrFull or 1.0, 0.0, 1.0) or 0.0
    local rotDemand = rotThrF * latF
    local rtau = (rotDemand > doRotFactor) and (dcfg.RotEngageTau or 0.10) or (dcfg.RotReleaseTau or 0.15)
    doRotFactor = doRotFactor + (rotDemand - doRotFactor) * (1.0 - math.exp(-dt / rtau))
    if doRotFactor < 0.01 then
        doRotFactor = 0.0
        releaseRot()
    else
        -- INNER rear = inside of the turn. steer > 0 = right → RR; left → RL.
        local inner = (steer >= 0.0) and RWD_RR or RWD_RL
        if doRotWheel ~= nil and doRotWheel ~= inner then
            vl_brakeWheel(veh, doRotWheel, 0.0)   -- switched sides: release old wheel
            doRotWheel = nil
        end
        local pressure = (dcfg.RotMaxPressure or 0.16) * doRotFactor
        vl_brakeWheel(veh, inner, pressure)
        doRotWheel = inner
    end
end

-----------------------------------------------------------------
-- RWD BRAKE-ROTATION (2026-08-14 — weight-transfer spine mirror #1, first HK.load consumer)
-- The MISSING RWD trait: hard TRAIL-BRAKING into a corner unloads the rear axle (weight pitches onto
-- the nose), and on a RWD that light rear steps OUT — you rotate the car with the brake. GTA models no
-- longitudinal transfer, so today ONLY a throttle lift rotates a RWD (RWD_LiftRotation); pure braking
-- just plows. This reads the spine's load.rear (how unloaded the rear is) × brake pressure × corner
-- load and vectors the inner-rear (same capped vl_brakeWheel path as LiftRotation/DriveOut — below
-- lockup, cannot flip). DISTINCT from LiftRotation: that fires on lift+coast (thr≤gate, no brake
-- needed); this needs real BRAKE and scales with rear-unload, so trail-braking rotates where a plain
-- lift wouldn't. Gated OFF by default until felt. Reads HK.load (spine runs first each frame).
-----------------------------------------------------------------
local function RWD_BrakeRotation(veh, state, dt, bcfg)
    local function releaseBR()
        if rbrWheel ~= nil then vl_brakeWheel(veh, rbrWheel, 0.0); rbrWheel = nil end
    end
    if not bcfg or bcfg.Enabled == false then rbrFactor = 0.0; releaseBR(); return end

    local kmh   = state.speedKmh or 0.0
    local brake = state.brake or 0.0
    local steer = state.steer or 0.0
    local latS  = state.lateralSpeed or 0.0
    local airborne = (state.onAllWheels == false)
    local wheelCount = state.wheelCount or GetVehicleNumberOfWheels(veh)
    local L = HK.load

    -- AIRBORNE = INSTANT RELEASE (see RWD_LiftRotation): don't let a latched inner-rear brake keep acting
    -- through the decay while airborne — that yaws the car sideways mid-air. Hard-release + zero now.
    if airborne then rbrFactor = 0.0; releaseBR(); return end

    -- Trail-brake into a corner: braking, steering, cornering, planted, fast enough, 4-wheeled.
    local active = L ~= nil
        and (kmh >= (bcfg.MinSpeedKmh or 30.0))
        and (brake >= (bcfg.BrakeGate or 0.25))
        and (math.abs(steer) >= (bcfg.SteerGate or 0.14))
        and (math.abs(latS) >= (bcfg.LatGateMs or 1.2))
        and not airborne and wheelCount >= 4

    local demand = 0.0
    if active then
        -- REAR-UNLOAD from the spine: static 0.5, drops toward ~0.15 under braking. Map that DROP
        -- below static into 0..1 — the lighter the rear, the more it wants to rotate. (load.rear < 0.5
        -- on brake; unload = how far below static.) This is the weight-transfer term LiftRotation lacks.
        local unload = lerpClamp(0.5 - (L.rear or 0.5), bcfg.UnloadGate or 0.05, bcfg.UnloadFull or 0.30, 0.0, 1.0)
        -- Corner load (shared gate shape with the other rear tools).
        local latF   = lerpClamp(math.abs(latS), bcfg.LatGateMs or 1.2, bcfg.LatFullMs or 6.0, 0.0, 1.0)
        -- Brake depth term so a harder trail-brake rotates more (past the gate → full by BrakeFull).
        local brakeF = lerpClamp(brake, bcfg.BrakeGate or 0.25, bcfg.BrakeFull or 0.80, 0.0, 1.0)
        demand = math.min(unload * latF * brakeF, 1.0)
    end

    local tau = (demand > rbrFactor) and (bcfg.EngageTau or 0.10) or (bcfg.ReleaseTau or 0.16)
    rbrFactor = rbrFactor + (demand - rbrFactor) * (1.0 - math.exp(-dt / tau))
    if rbrFactor < 0.01 then rbrFactor = 0.0; releaseBR(); return end

    -- INNER rear = inside of the turn. steer > 0 = right → RR; left → RL.
    local inner = (steer >= 0.0) and RWD_RR or RWD_RL
    if rbrWheel ~= nil and rbrWheel ~= inner then vl_brakeWheel(veh, rbrWheel, 0.0); rbrWheel = nil end
    vl_brakeWheel(veh, inner, (bcfg.MaxPressure or 0.18) * rbrFactor)
    rbrWheel = inner
    HK.dbgRwd = HK.dbgRwd or {}; HK.dbgRwd.brake = rbrFactor
end

-----------------------------------------------------------------
-- RWD POWER-SPIN / OPEN-DIFF INSIDE-WHEEL (2026-08-14 — weight-transfer spine mirror #2)
-- Rear-axle mirror of FWD_TorqueSteer. On a RWD open diff, hard power mid-corner spins up the lightly-
-- loaded INSIDE-rear wheel (load.rear shifted, inside unloaded by lateral transfer) — that wheel breaks
-- traction first and the car rotates. GTA's locked-feel rear just grips or snaps. Detect genuine REAR
-- wheelspin (GetVehicleWheelSpeed on RL/RR vs ground) under power in a corner, and pulse the inside-rear
-- brake a touch so the spin/rotation is deliberate + progressive rather than an all-or-nothing snap
-- (same capped path, below lockup). Reads load.rear only to GATE (don't spin-rotate when the rear is
-- planted/squatting hard under load). LIVE + confirmed 2026-08-14. Complements RWD_DriveOut PART B (that
-- vectors on throttle regardless of spin; this specifically rewards the open-diff inside-wheel break).
-----------------------------------------------------------------
local function RWD_PowerSpin(veh, state, dt, pcfg)
    local function release()
        if rpsWheel ~= nil then vl_brakeWheel(veh, rpsWheel, 0.0); rpsWheel = nil end
    end
    if not pcfg or pcfg.Enabled == false then rpsFactor = 0.0; release(); return end

    local kmh   = state.speedKmh or 0.0
    local thr   = state.throttle or 0.0
    local steer = state.steer or 0.0
    local latS  = state.lateralSpeed or 0.0
    local airborne = (state.onAllWheels == false)
    local wheelCount = state.wheelCount or GetVehicleNumberOfWheels(veh)
    -- AIRBORNE = INSTANT RELEASE (see RWD_LiftRotation): a spinning wheel in the air reads huge over-speed
    -- and would latch the inner-rear brake, yawing the car sideways mid-air. Hard-release + zero now.
    if airborne then rpsFactor = 0.0; release(); return end
    local ground = GetEntitySpeed(veh)
    -- Rear wheel over-speed (spin) vs ground, per side. RL=2, RR=3.
    local rlSpin = math.abs(GetVehicleWheelSpeed(veh, RWD_RL)) - ground
    local rrSpin = math.abs(GetVehicleWheelSpeed(veh, RWD_RR)) - ground
    local worst  = math.max(rlSpin, rrSpin)

    local active = (thr >= (pcfg.MinThrottle or 0.60))
        and (worst >= (pcfg.SpinThreshMs or 2.0))
        and (math.abs(steer) >= (pcfg.SteerGate or 0.12))
        and (math.abs(latS) >= (pcfg.LatGateMs or 1.0))
        and not airborne and wheelCount >= 4
        and (kmh < (pcfg.SpeedZeroKmh or 120.0))
    local demand = 0.0
    if active then
        local spinF = lerpClamp(worst, pcfg.SpinThreshMs or 2.0, (pcfg.SpinThreshMs or 2.0) + 4.0, 0.0, 1.0)
        local spdF  = lerpClamp(kmh, pcfg.SpeedLowKmh or 10.0, pcfg.SpeedZeroKmh or 120.0, 1.0, 0.0)
        local latF  = lerpClamp(math.abs(latS), pcfg.LatGateMs or 1.0, pcfg.LatFullMs or 6.0, 0.0, 1.0)
        demand = spinF * spdF * latF
    end
    local tau = (demand > rpsFactor) and (pcfg.EngageTau or 0.06) or (pcfg.ReleaseTau or 0.12)
    rpsFactor = rpsFactor + (demand - rpsFactor) * (1.0 - math.exp(-dt / tau))
    if rpsFactor < 0.01 then rpsFactor = 0.0; release(); return end

    -- Brake the INNER-rear (inside of the turn) so the open-diff sends torque to it and it breaks loose
    -- progressively, rotating the car. steer > 0 = right → RR; left → RL.
    local inner = (steer >= 0.0) and RWD_RR or RWD_RL
    if rpsWheel ~= nil and rpsWheel ~= inner then vl_brakeWheel(veh, rpsWheel, 0.0); rpsWheel = nil end
    -- TC-OFF CHARACTER BOOST: the inside-rear open-diff fry is the tell that the rears are loose. With
    -- TC off, sharpen it (CharacterBoost) so the loss of traction reads clearly. MaxPressure cap still
    -- bounds it (see release-clamp below); this only scales UP toward that cap, never past it.
    local charMul = 1.0
    do local to = HK.dtTCOff; if to and to.on then charMul = to.charBoost end end
    local capP = (pcfg.MaxPressure or 0.10)
    local pressP = math.min(capP * rpsFactor * charMul, capP * 1.5)  -- hard ceiling 1.5× cap even boosted
    vl_brakeWheel(veh, inner, pressP)
    rpsWheel = inner
    HK.dbgRwd = HK.dbgRwd or {}; HK.dbgRwd.pspin = rpsFactor
end

-----------------------------------------------------------------
-- AWD BRANCH: realistic understeer on power (Phase 1)
-- Real AWD cars (0.49-0.61 bias) should PUSH WIDE when you charge a
-- corner on power — the front pulls the nose straight (understeer),
-- while the rear stays planted (four contact patches + weight). This is
-- the opposite of RWD power-oversteer.
--
-- Mechanism: under throttle, shift fDriveBiasFront HIGHER (more front-
-- pull) so the nose resists rotation. Speed-scaled so it's most
-- noticeable in fast corners (where AWD understeer is real), gentle at
-- low speed (parking-lot maneuvering stays neutral). Smoothly returns to
-- native bias off-throttle so trail-braking/lift still rotates the car.
-----------------------------------------------------------------
local function AWD_Understeer(veh, state, dt, acfg)
    if not acfg.Understeer or not acfg.Understeer.Enabled then
        -- Understeer disabled: make sure bias is native, then bail
        if awdUnderBias and math.abs(awdUnderBias - nativeFrontBias) > 0.001 then
            vl_setHandling(veh, 'fDriveBiasFront', nativeFrontBias)
            awdUnderBias = nativeFrontBias
        end
        return
    end

    local u = acfg.Understeer
    local thr = state.throttle or 0.0
    local kmh = state.speedKmh or 0.0

    -- LANDING SETTLE (2026-08-10 v8): while airborne the wheels have no grip, so any front-bias
    -- shift we build is stale — and on touchdown the speed spike maxes the v7 accel-boost, snapping
    -- that bias in the instant the tyres bite. If the car lands even slightly yawed, that snap
    -- steps it out and the assist chases it (the "slide off on land + countersteer" report). Fix:
    -- while airborne, and for a short settle window after landing, hold bias at NATIVE and skip
    -- engage — let the suspension/tyres settle before the diff starts pulling again.
    do
        local nowL = GetGameTimer()
        local airborneNow = (state.onAllWheels == false)
        if airborneNow then
            awdLandSettleUntil = nowL + (u.LandSettleMs or 260)
        end
        if airborneNow or nowL < awdLandSettleUntil then
            -- Bleed bias back to native (don't snap) and reset accel tracking so touchdown's
            -- speed discontinuity can't spike the accel-boost.
            awdPrevKmh = kmh
            local cur = awdUnderBias or nativeFrontBias
            if math.abs(cur - nativeFrontBias) > 0.001 then
                local rel = 1.0 - math.exp(-dt / (u.ReleaseTau or 0.20))
                local nb = cur + (nativeFrontBias - cur) * rel
                vl_setHandling(veh, 'fDriveBiasFront', nb)
                awdUnderBias = nb
            end
            awdReacting = false   -- re-arm reaction latency for the next real turn-in
            return
        end
    end

    -- Throttle factor: how much gas drives the understeer help.
    -- 2026-08-10 v13: the old version dropped to 0 below the gate — an on/off CLIFF. On power the
    -- car was planted; the instant you lifted, ALL help vanished and it fell onto raw native physics
    -- and felt suddenly slide-y even while still turning. Real AWD lift-off DOES rotate more (weight
    -- shifts forward, rear lightens) but as a GRADIENT, not a switch. So keep a stability FLOOR while
    -- coasting: off-throttle you still get CoastFloor× the help (less than on-power, so lifting still
    -- rotates more — the realistic bit — but no cliff). Braking fades the floor out so trail-braking
    -- rotation is preserved for those who want to pitch the car in.
    local brake = state.brake or 0.0
    -- On-power component: 0 at the gate, ramping to 1 at full throttle.
    local thrOn = 0.0
    if thr >= (u.ThrottleGate or 0.35) then
        thrOn = lerpClamp(thr, u.ThrottleGate or 0.35, 1.0, 0.0, 1.0)
    end
    -- Coast floor, faded out as you brake (BrakeCut = brake level that fully removes the floor).
    -- lerpClamp gives 1.0 at zero brake ramping to 0.0 at BrakeCut (output is clamped to [0,1]).
    local coast = (u.CoastFloor or 0.40) * lerpClamp(brake, 0.0, u.BrakeCut or 0.6, 1.0, 0.0)
    -- Blend: off-throttle = coast; full throttle = 1.0; smooth in between (no cliff at the gate).
    local thrFactor = coast + (1.0 - coast) * thrOn

    -- Speed scale: understeer ramps up with speed (fast corners show it most)
    local spdFactor = lerpClamp(kmh,
        u.SpeedLowKmh or 50.0, u.SpeedHighKmh or 130.0,
        u.SpeedLowMult or 0.25, u.SpeedHighMult or 1.0)

    -- SUB-140 BOOST (2026-08-12): lift the under-SpeedHighKmh band a touch more, tapering to 1.0
    -- exactly at the top of the base ramp so the >140 high-speed extension (HiSpeedMult) is untouched
    -- and there's no kink at the handoff. Triangular: 1.0 at low-speed floor → SubBoostMult at the
    -- peak → back to 1.0 at SpeedHighKmh.
    if u.SubBoostEnabled and (u.SubBoostMult or 1.0) > 1.0 then
        local peak = u.SubBoostPeakKmh or 95.0
        local hi   = u.SpeedHighKmh or 140.0
        local lo   = u.SpeedLowKmh or 50.0
        local sub
        if kmh <= lo or kmh >= hi then
            sub = 0.0
        elseif kmh <= peak then
            sub = (kmh - lo) / math.max(peak - lo, 0.1)
        else
            sub = (hi - kmh) / math.max(hi - peak, 0.1)
        end
        if sub < 0.0 then sub = 0.0 elseif sub > 1.0 then sub = 1.0 end
        spdFactor = spdFactor * (1.0 + ((u.SubBoostMult or 1.06) - 1.0) * sub)
    end

    -- STEER SCALE (2026-08-10 v4): the onset felt abrupt near full lock — because the effect
    -- ignored steering angle and snapped on from throttle+speed alone. Ease it in with how far
    -- the wheel is turned: a little steering = a little understeer, ramping to full only as you
    -- approach hard lock. A squared curve makes small/mid steering keep MOST of the front bite
    -- and the push grow smoothly toward the apex instead of hitting all at once.
    local steerAbs = math.abs(state.steer or 0.0)   -- 0..1
    local steerFactor = lerpClamp(steerAbs,
        u.SteerLow or 0.15, u.SteerHigh or 0.85,
        u.SteerLowMult or 0.15, 1.0)
    steerFactor = steerFactor * steerFactor          -- squared = gentle low/mid, ramps late

    -- LOW-SPEED FADE (2026-08-10 v15): the inverse of the high-speed steer limit. Below ~70 km/h
    -- the understeer help (front-bias plow) has no grip demand to hide behind, so it just pushed the
    -- nose wide — worst while COASTING (front bias + no drive = plow). Fade the WHOLE effect out as
    -- speed drops: full at LowFadeFullKmh, zero by LowFadeZeroKmh, so slow corners go native/neutral.
    -- Above LowFadeFullKmh this is 1.0 → the tuned mid/high-speed behavior is completely unchanged.
    local lowFade = lerpClamp(kmh,
        u.LowFadeZeroKmh or 25.0, u.LowFadeFullKmh or 70.0, 0.0, 1.0)

    -- Combined understeer demand 0..1 (throttle × speed × steering × low-speed fade)
    local factor = thrFactor * spdFactor * steerFactor * lowFade

    -- REACTION LATENCY (2026-08-10 v5): a real AWD ECU senses the road with a small variable
    -- delay before it acts. On a FRESH demand edge (rising out of rest), arm a 20-80ms reaction
    -- timer scaled by urgency (speed+steering) — the assist won't start ramping until it elapses,
    -- so the onset feels like the diff "reading" the road, not an instant robotic snap. Once
    -- armed we keep engaging; the delay only gates the initial edge. Demand collapsing re-arms it.
    local now = GetGameTimer()
    local rcfg = u.Reaction
    local reactionHolding = false
    if rcfg and rcfg.Enabled ~= false then
        local demandOn = factor > (rcfg.DemandGate or 0.05)
        if demandOn and not awdReacting then
            -- fresh edge: urgency from speed + steering (either being high = quicker reaction)
            local spdU = lerpClamp(kmh, u.SpeedLowKmh or 50.0, u.SpeedHighKmh or 130.0, 0.0, 1.0)
            local urgency = math.max(spdU, steerAbs)
            awdReactUntil = now + reactionDelayMs(urgency, rcfg)
            awdReacting = true
        elseif not demandOn then
            awdReacting = false   -- demand dropped: reset so the next turn-in re-arms the delay
        end
        -- Still inside the reaction window: freeze — don't start ramping the bias up yet.
        if awdReacting and now < awdReactUntil then
            reactionHolding = true
        end
    end

    -- HIGH-SPEED EXTENSION (2026-08-10 v9): the base speed scale (spdFactor) clamps flat at 1.0
    -- above SpeedHighKmh, so 250 and 350 km/h felt identical — the nose resisted a left-right
    -- transition the same at both. In reality the faster you go the more the car should resist
    -- changing direction (slower, more stable weave). Keep climbing the front-bias ABOVE the base
    -- cap: a multiplier from 1.0 at HiSpeedLowKmh up to HiSpeedMult at HiSpeedFullKmh. Applied to
    -- the bias shift only, so mid-speed cornering (<~130) is unchanged and only top-end firms up.
    local hiMult = lerpClamp(kmh,
        u.HiSpeedLowKmh or 130.0, u.HiSpeedFullKmh or 340.0,
        1.0, u.HiSpeedMult or 1.6)

    -- Target bias: native + shift toward the front (more front pull = more understeer).
    -- During the reaction window, freeze at the current bias (the ECU hasn't "acted" yet).
    -- SPEED-GRADUATED WIDEN (2026-08-13): scale the whole cornering help up more at LOW speed than
    -- high — lower speeds get the bigger lift (they had the least help), high speeds a lighter touch
    -- (already firm from HiSpeedMult). A multiplier that lerps from WidenLoMult at WidenLoKmh down to
    -- WidenHiMult at WidenHiKmh. Applied to biasShift (the master), so it lifts base + high-speed
    -- extension together, proportionally.
    local widenMult = 1.0
    if u.WidenEnabled then
        widenMult = lerpClamp(kmh,
            u.WidenLoKmh or 40.0, u.WidenHiKmh or 200.0,
            u.WidenLoMult or 1.12, u.WidenHiMult or 1.06)
    end

    local targetBias
    if reactionHolding then
        targetBias = awdUnderBias or nativeFrontBias
    else
        local biasShift = (u.BiasShift or 0.12) * factor * hiMult * widenMult
        targetBias = math.min(nativeFrontBias + biasShift, u.MaxBias or 0.78)
    end

    -- ACCEL-AWARE ENGAGE (2026-08-10 v7): on monster-power AWD (Chiron etc.) the car accelerates
    -- through the speed band FASTER than the assist ramps in — so the understeer help is always
    -- chasing the power and feels late. Measure longitudinal acceleration (Δkmh/s) and, when it's
    -- high, shorten the effective engage tau so the front-bias shift snaps in fast enough to keep
    -- pace. Only speeds up the RISING (engage) edge; release is untouched.
    local accelKmhS = 0.0
    if dt > 0.0 then accelKmhS = (kmh - awdPrevKmh) / dt end
    awdPrevKmh = kmh

    -- Smooth transition (tau-based) — snap on quicker than release so power-on
    -- understeer feels responsive but lift-off rotation returns gracefully.
    local rising = (targetBias > (awdUnderBias or nativeFrontBias))
    local tau = rising and (u.EngageTau or 0.10) or (u.ReleaseTau or 0.20)
    if rising and (u.AccelBoostEnabled ~= false) and accelKmhS > 0.0 then
        -- Scale 0..1 by how hard we're accelerating, then pull tau toward AccelTauMin.
        local accelU = lerpClamp(accelKmhS, u.AccelKmhSLow or 15.0, u.AccelKmhSHigh or 45.0, 0.0, 1.0)
        tau = tau + (( u.AccelTauMin or 0.05) - tau) * accelU
    end
    local alpha = 1.0 - math.exp(-dt / tau)
    local current = awdUnderBias or nativeFrontBias
    local newBias = current + (targetBias - current) * alpha

    if math.abs(newBias - current) > 0.001 then
        vl_setHandling(veh, 'fDriveBiasFront', newBias)
        awdUnderBias = newBias
    end

    -- DEBUG EXPOSE (2026-08-12): publish the live understeer engagement so the on-screen overlay can
    -- show whether AWD help actually kicked in (factor 0..1, the applied front bias, and native for ref).
    HK.dbgAwd = HK.dbgAwd or {}
    HK.dbgAwd.active   = true
    HK.dbgAwd.factor   = factor
    HK.dbgAwd.bias     = newBias
    HK.dbgAwd.native   = nativeFrontBias
    HK.dbgAwd.thrFactor= thrFactor
    HK.dbgAwd.at       = GetGameTimer()

    -- BUMP-SLIDE SUPPRESSION (2026-08-10 v3): GTA's bad-mapping bumps briefly unload the tyres
    -- (lost wheel contact / vertical velocity spike). A real AWD car stays planted over a bump —
    -- it shouldn't suddenly slide. When we detect a bump, open a short window and DAMP the lateral
    -- (sideways) velocity the bump kicked in, so the car keeps tracking straight instead of
    -- stepping out. Only ever REDUCES lateral velocity (never adds), so it can't cause a slide or
    -- flip — it just cancels the unwanted sideways skip. Gated to AWD only (this function).
    local bcfg = acfg.BumpSuppress
    if bcfg and bcfg.Enabled ~= false then
        local now = GetGameTimer()
        local vel = state.velocity
        local velZ = vel and vel.z or 0.0

        -- Detect a bump: either not all wheels are on the ground, OR the vertical velocity
        -- jumped this frame (hit a lip / crest). Both are transient — arm a short window.
        local velZDelta = math.abs(velZ - awdPrevVelZ)
        awdPrevVelZ = velZ
        local airborne  = (state.onAllWheels == false)
        local vertSpike = velZDelta > (bcfg.VertSpikeMs2 or 0.9)
        if (airborne or vertSpike) and kmh >= (bcfg.MinSpeedKmh or 30.0) then
            awdBumpUntil = now + (bcfg.WindowMs or 250)
            -- REACTION LATENCY: the ECU takes a moment to sense the skip before it corrects.
            -- Arm a short delay (scaled by speed — faster = quicker sense) before damping starts,
            -- reusing the understeer Reaction config. Only set on a fresh bump (not every frame).
            if awdBumpReactAt < now then
                local rc = u.Reaction
                local spdU = lerpClamp(kmh, u.SpeedLowKmh or 50.0, u.SpeedHighKmh or 130.0, 0.0, 1.0)
                awdBumpReactAt = now + ((rc and rc.Enabled ~= false) and reactionDelayMs(spdU, rc) or 0.0)
            end
        end

        -- While the window is open (and past the reaction latency), bleed the lateral (sideways)
        -- component of velocity so a bump can't step the tail/nose out. We only reduce the
        -- sideways part — forward and vertical velocity are left untouched.
        --
        -- LANDING LAUNCH FIX (2026-08-14): this used to damp WHILE AIRBORNE too, which caused a
        -- "launch forward on touchdown" (the same class as the drift-exit launch). TWO reasons it must
        -- NOT run airborne: (1) airborne there's no grip — the sideways component is just the car's
        -- natural rotation/arc from being steered mid-air, NOT a skip to correct; killing it pre-rotates
        -- the landing AND concentrates the removed sideways energy into the forward vector = shoots
        -- forward. (2) GetEntityForwardVector includes PITCH when the car is nose-up/down in the air, so
        -- rx,ry = fwd.y,-fwd.x is NOT a valid horizontal right-vector then — the "lateral" removal bleeds
        -- into forward/vertical (the world-up-vs-entity-transform basis bug we hit in drift). So: only
        -- correct once the wheels are back DOWN (a real skip/step-out happens as grip returns on landing),
        -- and EASE the damp in over the settle so it can't yank the vector. state.lateralSpeed is the
        -- vehlib-provided horizontal lateral, so the basis issue only affected the SetEntityVelocity write.
        local grounded = (state.onAllWheels ~= false)
        -- Mark the touchdown moment (airborne→grounded transition) as the ease-in ORIGIN. awdBumpReactAt
        -- was armed back when the bump/airborne STARTED, so by landing 'now' is already well past it —
        -- measuring the ramp from there would jump straight to firm damp and re-introduce the yank. Anchor
        -- the ramp to the actual landing frame instead.
        if grounded and awdWasAirborne then awdLandCorrectAt = now end
        awdWasAirborne = not grounded
        if now < awdBumpUntil and now >= awdBumpReactAt and vel and grounded then
            local lat = state.lateralSpeed or 0.0
            if math.abs(lat) > (bcfg.MinLatMs or 0.5) then
                -- EASE-IN from the landing frame over BumpLandEaseMs so touchdown correction ramps instead
                -- of a hard one-frame kill (the launch felt like a yank because 9.0 removed ~14%/frame).
                local easeMs = bcfg.LandEaseMs or 180.0
                local prog   = (now - awdLandCorrectAt) / math.max(1.0, easeMs)
                if prog < 0.0 then prog = 0.0 elseif prog > 1.0 then prog = 1.0 end
                local ease   = prog * prog * (3.0 - 2.0 * prog)   -- smoothstep: gentle first, firm later
                local damp   = (bcfg.LatDamp or 6.0) * ease
                if damp > 0.0 then
                    local k = math.exp(-damp * dt)   -- <1, per-frame lateral retention
                    local fwd = GetEntityForwardVector(veh)
                    -- horizontal right vector (rotate fwd 90° in-plane). Valid now: grounded = ~flat, no pitch.
                    local rx, ry = fwd.y, -fwd.x
                    local rmag = math.sqrt(rx*rx + ry*ry)
                    if rmag > 0.001 then
                        rx, ry = rx / rmag, ry / rmag
                        -- delta along +right to shrink lateral toward lat*k (delta is negative
                        -- when it opposes the current sideways drift = only ever reduces |lat|).
                        local delta = lat * (k - 1.0)
                        SetEntityVelocity(veh, vel.x + rx * delta, vel.y + ry * delta, vel.z)
                    end
                end
            end
        end
    end

    -- BRAKE STABILITY (2026-08-10 v18, v19 model fix): the understeer helper only shifts DRIVE
    -- bias, which does nothing under braking (little drive torque to distribute) — so on the brakes
    -- the AWD assist had NO tool and the car fell onto raw native physics, stepping out on a short
    -- tap + steer. Give it a real tool that works while braking: damp the sideways (lateral) slide,
    -- same proven mechanism as bump-suppress (only ever REDUCES lateral velocity, never adds —
    -- can't cause a slide/flip). MODEL (v19): a modern AWD's FOOT brake runs through ABS + stability
    -- control — you can't brake-spin it with the pedal no matter how hard, it just stops planted. So
    -- foot braking keeps FULL correction at every level. The HANDBRAKE locks the rears mechanically
    -- (bypasses ESC) = the deliberate slide tool → correction fully releases under handbrake.
    local kcfg = acfg.BrakeStability
    if kcfg and kcfg.Enabled ~= false then
        local vel = state.velocity
        local hb  = (state.handbrake == true) or ((state.handbrake or 0) == 1)
        -- Full correction authority whenever the FOOT brake is applied (above the gate), not on
        -- handbrake, and above the speed floor. No fade — ESC clamps hardest under hard braking.
        -- GROUNDED-ONLY (2026-08-14): same launch/basis reason as BumpSuppress — braking mid-air while
        -- steered would strip the airborne arc's lateral through a pitch-skewed basis = forward launch on
        -- touchdown. ABS/ESC only act through the tyres anyway, so airborne there's nothing to correct.
        local grounded = (state.onAllWheels ~= false)
        local auth = 0.0
        if not hb and grounded and kmh >= (kcfg.MinSpeedKmh or 25.0) and brake >= (kcfg.BrakeGate or 0.12) then
            auth = 1.0
        end
        if auth > 0.0 and vel then
            local lat = state.lateralSpeed or 0.0
            if math.abs(lat) > (kcfg.MinLatMs or 0.4) then
                -- Effective damp scales with authority: strong at light brake, gone by hard brake.
                local damp = (kcfg.LatDamp or 5.0) * auth
                local k = math.exp(-damp * dt)
                local fwd = GetEntityForwardVector(veh)
                local rx, ry = fwd.y, -fwd.x
                local rmag = math.sqrt(rx*rx + ry*ry)
                if rmag > 0.001 then
                    rx, ry = rx / rmag, ry / rmag
                    local delta = lat * (k - 1.0)   -- negative = only ever shrinks |lat|
                    SetEntityVelocity(veh, vel.x + rx * delta, vel.y + ry * delta, vel.z)
                end
            end
        end
    end
end

-----------------------------------------------------------------
-- AWD CORNER-EXIT TRACTION GOVERNOR (2026-08-12 v7.20 — feature #1)
-- THE defining AWD trait GTA lacks: you can boot the throttle on corner exit and the car HOOKS UP
-- and drives out, instead of the driven wheels spinning and the tail stepping wide (or bogging).
-- Real AWD manages this by routing torque to the axle WITH grip. We model that in two layers:
--   (1) PRIMARY — bias TRANSFER: on throttle-induced REAR wheelspin, shift fDriveBiasFront forward
--       so torque goes to the (gripping) front axle. This plants the car and drives it OUT — a
--       transfer, not a power cut, so no bog. Layered ON TOP of AWD_Understeer's bias (runs after
--       it); recomputed fresh each frame so it never accumulates on the field.
--   (2) BACKSTOP — torque trim: if slip is STILL excessive after the transfer (genuinely low grip),
--       trim engine torque via the shared HK.torqueMult (same path as TractionControl). Gentle —
--       just enough to stop the spin running away; the transfer does the primary work.
-- Only fires ON THROTTLE (this is corner-EXIT drive-out, not lift/brake). Uses rearSlip() — the
-- same rear-wheel-vs-ground-speed detector the RWD assist uses. Skips airborne/landing (stale).
-----------------------------------------------------------------
local function AWD_TractionGovernor(veh, state, dt, gcfg, underBias)
    if not gcfg or gcfg.Enabled == false then return end
    local thr = state.throttle or 0.0
    local kmh = state.speedKmh or 0.0

    -- Gates: must be ON THE GAS (drive-out), moving, and grounded. Off-throttle / airborne / just
    -- after a landing = no governor (relax the smoothed factor toward 0 so re-engage is clean).
    local airborne = (state.onAllWheels == false)
    local engaged = (thr >= (gcfg.ThrottleGate or 0.25)) and (kmh >= (gcfg.MinSpeedKmh or 20.0)) and not airborne

    -- REAR-SLIP DETECT: how much faster the rear wheels spin than the car moves (m/s over ground).
    -- Only meaningful while engaged; when not, drive the smoothed factor to 0.
    local slip = engaged and rearSlip(veh, state.speed or (kmh / 3.6)) or 0.0
    local spinGate = gcfg.SpinThreshold or 2.2   -- m/s of rear overspeed that counts as wheelspin
    local spinFull = gcfg.SpinFull or 7.0        -- m/s where intervention is at full strength

    -- Demand 0..1 from how far past the spin gate we are (0 at gate, 1 at spinFull).
    local demand = 0.0
    if engaged and slip > spinGate then
        demand = (slip - spinGate) / math.max(spinFull - spinGate, 0.1)
        if demand > 1.0 then demand = 1.0 end
    end

    -- Smooth: engage FAST (catch the spin before it steps the tail out), release slower (don't
    -- yank torque/bias back the instant grip returns — that itself unsettles the car).
    local target = demand
    local tau = (target > tcGovFactor) and (gcfg.EngageTau or 0.06) or (gcfg.ReleaseTau or 0.22)
    tcGovFactor = tcGovFactor + (target - tcGovFactor) * (1.0 - math.exp(-dt / tau))
    if tcGovFactor < 0.01 then
        tcGovFactor = 0.0
        -- Disengaged. If we inflated the bias last frame, restore the understeer/native baseline ONCE
        -- so a stale governor bias can't stick — AWD_Understeer only rewrites fDriveBiasFront when ITS
        -- own target moves, so it won't necessarily clear our layer on its own.
        if tcGovBiasOn then
            vl_setHandling(veh, 'fDriveBiasFront', underBias or nativeFrontBias or 0.5)
            tcGovBiasOn = false
        end
        return
    end

    -- (1) PRIMARY — BIAS TRANSFER: layer an extra forward shift on top of the understeer bias so
    -- torque routes to the gripping front axle. Base is the understeer-managed value if present
    -- (so we build FROM it, not fight it), else native. Capped at MaxBias. Recomputed each frame
    -- (no accumulation): next tick AWD_Understeer rewrites the field from its own baseline, then we
    -- re-add this on top. A transfer, not a cut — the car keeps driving, just through the front.
    -- TC-OFF EASE: the governor is AWD's stability net (plant torque forward + trim spin). With TC off
    -- the driver wants the car to rotate + light up all four, so scale BOTH the forward-bias plant and
    -- the backstop cut down by AwdGovernorEase. AWD never goes fully loose (still 4wd), but this lets it
    -- step out and spin far more than TC-on. easeMul 1.0 = full governor (TC on / feature off).
    local easeMul = 1.0
    do local to = HK.dtTCOff; if to and to.on then easeMul = to.awdGovMul end end

    local base = underBias or nativeFrontBias or 0.5
    local biasAdd = (gcfg.BiasTransfer or 0.14) * tcGovFactor * easeMul
    local newBias = math.min(base + biasAdd, gcfg.MaxBias or 0.85)
    if newBias > base + 0.001 then
        vl_setHandling(veh, 'fDriveBiasFront', newBias)
        tcGovBiasOn = true
    elseif tcGovBiasOn then
        -- Engaged but adding ~nothing (already at MaxBias baseline, or biasAdd tiny): make sure the
        -- field sits at the understeer baseline and clear the flag so disengage doesn't double-restore.
        vl_setHandling(veh, 'fDriveBiasFront', base)
        tcGovBiasOn = false
    end

    -- (2) BACKSTOP — TORQUE TRIM: only if slip is STILL excessive (the transfer alone couldn't hook
    -- it up = genuinely low grip). Gentle cut, scaled by how far past the backstop slip we are. This
    -- just stops a spin running away; it never bogs a clean drive-out.
    -- ORDERING NOTE: Drivetrain_Tick runs in main.lua AFTER vl_setTorque(HK.torqueMult) has already
    -- applied this frame's combined multiplier (TC/ESC/limiter). So we can't just multiply HK.torqueMult
    -- (it's already been consumed and resets to 1.0 next frame). Instead we RE-APPLY: take the value
    -- main already set (HK.torqueMultApplied) and multiply our cut onto it, then setTorque again — the
    -- native multiplier is absolute per-frame, so the last write this frame wins. We also fold the cut
    -- back into HK.torqueMultApplied so diagnostics stay accurate.
    local backstopSlip = gcfg.BackstopSlip or spinFull   -- only trim once slip exceeds this
    if slip > backstopSlip then
        local over = (slip - backstopSlip) / math.max(spinFull, 0.1)
        if over > 1.0 then over = 1.0 end
        local minMult = gcfg.MinTorqueMult or 0.72       -- hardest cut floor (72% power) — gentle by design
        local cut = 1.0 - (1.0 - minMult) * over * tcGovFactor * easeMul
        if cut < 0.999 and HK then
            local applied = (HK.torqueMultApplied or 1.0) * cut
            vl_setTorque(veh, applied)
            HK.torqueMultApplied = applied
        end
    end
end

-----------------------------------------------------------------
-- AWD POWER-OUT SAVE (2026-08-12 v7.21 — feature #1b)
-- Lift-off oversteer recovery. Off the gas mid-corner the rear steps out (weight shifts forward,
-- rear goes light) — real lift-off oversteer. In a real AWD, getting BACK ON the throttle SAVES it:
-- torque routes to the still-gripping front axle, which bites and drags the nose back onto its
-- heading — you power OUT of the slide. GTA models none of this. THROTTLE-ONLY: off-throttle the
-- rear keeps sliding (lift-off oversteer stays real); the more gas you feed, the stronger the pull-
-- straight. Two tools, both scaled by throttle × slip: (1) big forward bias transfer (front bite),
-- (2) a gentle lateral-slide damp (same only-ever-REDUCE mechanism as BrakeStability — can't spin or
-- flip). Runs AFTER the exit governor and reads the LIVE fDriveBiasFront as its base, so it layers
-- cleanly on whatever understeer/governor already set this frame. Restores baseline on disengage.
-----------------------------------------------------------------
local function AWD_PowerSave(veh, state, dt, pcfg)
    if not pcfg or pcfg.Enabled == false then return end
    local thr = state.throttle or 0.0
    local kmh = state.speedKmh or 0.0
    local airborne = (state.onAllWheels == false)

    -- SLIP ANGLE: heading vs velocity (rear stepping out). atan(|lateral| / forward), in degrees.
    local fwd = state.forwardSpeed or 0.0
    local latS = state.lateralSpeed or 0.0
    local slipDeg = (HK.load and HK.load.slipDeg) or ((fwd > 1.0) and math.abs(math.deg(math.atan(latS / fwd))) or 0.0)

    -- Engaged = on the gas (this is the throttle-only save), sliding past the gate, fast enough,
    -- grounded, and actually moving forward (not reversing/parked).
    local engaged = (thr >= (pcfg.ThrottleGate or 0.15))
        and (slipDeg > (pcfg.SlipGateDeg or 8.0))
        and (kmh >= (pcfg.MinSpeedKmh or 25.0))
        and (fwd > 1.0) and not airborne

    -- Demand 0..1 = how far into the slide (slip past gate) × how much throttle you're feeding.
    -- Both matter: no gas = no save; barely sliding = barely any. Full when deep slide + full gas.
    local demand = 0.0
    if engaged then
        local slipF = (slipDeg - (pcfg.SlipGateDeg or 8.0)) / math.max((pcfg.SlipFullDeg or 26.0) - (pcfg.SlipGateDeg or 8.0), 0.1)
        if slipF > 1.0 then slipF = 1.0 end
        demand = slipF * thr
    end

    local tau = (demand > pwrSaveFactor) and (pcfg.EngageTau or 0.05) or (pcfg.ReleaseTau or 0.28)
    pwrSaveFactor = pwrSaveFactor + (demand - pwrSaveFactor) * (1.0 - math.exp(-dt / tau))
    if pwrSaveFactor < 0.01 then
        pwrSaveFactor = 0.0
        if pwrSaveBiasOn then
            -- Restore the true baseline: strip OUR last add off the live field (leaves whatever
            -- understeer/governor set) so our save layer clears without stealing their contribution.
            local restored = (vl_getHandling(veh, 'fDriveBiasFront') or nativeFrontBias or 0.5) - pwrSaveLastAdd
            vl_setHandling(veh, 'fDriveBiasFront', restored)
            pwrSaveBiasOn = false
        end
        pwrSaveLastAdd = 0.0
        return
    end

    -- (1) FRONT-BIAS TRANSFER: read the LIVE field (understeer + exit governor already wrote it this
    -- frame) and layer our save shift on top, capped. Front axle bites → drags the nose straight.
    -- ACCUMULATION GUARD: when the exit governor is DISENGAGED (common for lift-off oversteer — no
    -- wheelspin), nothing else resets the field, so the live value still carries OUR add from last
    -- frame. Subtract pwrSaveLastAdd first to recover the true base, then re-add fresh — so the shift
    -- never creeps up to MaxBias on its own.
    local base = (vl_getHandling(veh, 'fDriveBiasFront') or nativeFrontBias or 0.5) - pwrSaveLastAdd
    local biasAdd = (pcfg.BiasTransfer or 0.20) * pwrSaveFactor
    local newBias = math.min(base + biasAdd, pcfg.MaxBias or 0.88)
    if newBias > base + 0.001 then
        vl_setHandling(veh, 'fDriveBiasFront', newBias)
        pwrSaveBiasOn = true
        pwrSaveLastAdd = newBias - base
    else
        pwrSaveLastAdd = 0.0
    end

    -- (2) GENTLE LATERAL-SLIDE DAMP: bleed a little of the sideways step-out so the front's pull is
    -- helped along. Only ever REDUCES lateral velocity (same safe mechanism as BrakeStability) — it
    -- can't add slide or flip the car. Scaled by the save factor (throttle × slip).
    local damp = (pcfg.CatchDamp or 2.6) * pwrSaveFactor
    if damp > 0.0 then
        local vel = state.velocity
        if vel and math.abs(latS) > 0.4 then
            local k = math.exp(-damp * dt)
            local f2 = GetEntityForwardVector(veh)
            local rx, ry = f2.y, -f2.x
            local rmag = math.sqrt(rx*rx + ry*ry)
            if rmag > 0.001 then
                rx, ry = rx / rmag, ry / rmag
                local delta = latS * (k - 1.0)   -- negative = only ever shrinks |lat|
                SetEntityVelocity(veh, vel.x + rx * delta, vel.y + ry * delta, vel.z)
            end
        end
    end
end

-----------------------------------------------------------------
-- SHARED SAFE YAW-SCALE (2026-08-13) — used by both the AWD and RWD spin softeners.
-- Scaling angular velocity must NOT clobber the suspension's pitch/roll for the frame (that's the
-- drift bump bug). Read the LIVE local angular velocity, keep local pitch/roll untouched, scale ONLY
-- the local yaw (z) by `scale`, rotate the vector back into WORLD via the car's own basis, then Set.
-- Pitch/roll round-trip exactly (a no-op); only yaw changes. Near a flip, skip and let physics own it.
-----------------------------------------------------------------
local function applyYawScale(veh, scale)
    if scale >= 0.999 then return end
    local lav = GetEntityRotationVelocity(veh)   -- LOCAL: (pitchRate, rollRate, yawRate)
    local newYaw = lav.z * scale

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
    if math.abs(upV.z) < 0.35 then return end   -- near-flip: let physics own it

    -- world = rightV*pitch + forwardV*roll + upV*yaw  (local x/y/z along the car's own axes)
    local wx = rightV.x*lav.x + forwardV.x*lav.y + upV.x*newYaw
    local wy = rightV.y*lav.x + forwardV.y*lav.y + upV.y*newYaw
    local wz = rightV.z*lav.x + forwardV.z*lav.y + upV.z*newYaw
    SetEntityAngularVelocity(veh, wx, wy, wz)
end

-----------------------------------------------------------------
-- ABS-OFF RESPONSE (2026-08-14) — layout-agnostic. Runs in main.lua ONLY when the player has ABS
-- switched off (HK.absOff) and is braking. Simulates the three real consequences of locking wheels
-- with no ABS underneath. Uses ONLY the flip-proof applyYawScale (yaw-RATE reduce, never forces yaw —
-- constraint-safe) for the steering plow, and publishes HK.absOffBrakeMult for main.lua to compose the
-- stopping-distance penalty onto the shared brake-force mult. Rear-lock rotation is EMERGENT: the plow
-- is keyed to FRONT lock, and a rear-dominant lock cancels it so GTA's natural grip-less-rear tail-out
-- comes through instead of being straightened. All effects recover the instant a wheel unlocks.
-- Module-local smoothed factors (reset in Drivetrain_Reset).
-----------------------------------------------------------------
local absOffSteerF = 0.0   -- smoothed 0..1 front-lock steering-plow engagement
local absOffStopF  = 0.0   -- smoothed 0..1 lock stopping-penalty engagement
local function ABSOff_Tick(veh, state, dt)
    local cfg = Config.ABSOff
    if not cfg or not cfg.Enabled then absOffSteerF = 0.0; absOffStopF = 0.0; HK.absOffBrakeMult = 1.0; return end

    local kmh   = state.speedKmh or 0.0
    local brake = state.brake or 0.0
    local steer = state.steer or 0.0
    local ground = GetEntitySpeed(veh)
    local wheelCount = state.wheelCount or GetVehicleNumberOfWheels(veh)

    -- Off the gate (slow / not braking hard / airborne): relax all factors, no penalty.
    if kmh < (cfg.MinSpeedKmh or 12.0) or brake < (cfg.BrakeGate or 0.55)
       or (state.onAllWheels == false) or wheelCount < 4 or ground < 1.0 then
        local rel = 1.0 - math.exp(-dt / 0.10)
        absOffSteerF = absOffSteerF + (0.0 - absOffSteerF) * rel
        absOffStopF  = absOffStopF  + (0.0 - absOffStopF)  * rel
        if absOffSteerF < 0.01 then absOffSteerF = 0.0 end
        if absOffStopF  < 0.01 then absOffStopF  = 0.0 end
        HK.absOffBrakeMult = 1.0 - ((cfg.Stop and cfg.Stop.Penalty or 0.0) * absOffStopF)
        HK.dbgAbsOff = HK.dbgAbsOff or {}; local d = HK.dbgAbsOff
        d.on = false; d.steer = absOffSteerF; d.stop = absOffStopF; d.at = GetGameTimer()
        return
    end

    -- LOCK per axle pair: wheel "locked" when its spin << ground speed. 0/1 front, 2/3 rear.
    local lockThresh = ground * 0.15   -- same ratio the ABS detector uses
    local function lockAmt(i)
        local ws = math.abs(GetVehicleWheelSpeed(veh, i))
        -- 0 at threshold, 1 fully stopped (locked). Linear below the threshold speed.
        if ws >= lockThresh then return 0.0 end
        return lerpClamp(ws, 0.0, lockThresh, 1.0, 0.0)
    end
    local frontLock = math.max(lockAmt(0), lockAmt(1))
    local rearLock  = math.max(lockAmt(2), lockAmt(3))
    local anyLock   = math.max(frontLock, rearLock)

    ------------------------------------------------------------------
    -- (2) STOPPING-DISTANCE PENALTY — locked (sliding) rubber < threshold grip. Scales with worst lock.
    ------------------------------------------------------------------
    if cfg.Stop and cfg.Stop.Enabled then
        local target = anyLock
        local tau = (target > absOffStopF) and (cfg.Stop.EngageTau or 0.06) or (cfg.Stop.ReleaseTau or 0.10)
        absOffStopF = absOffStopF + (target - absOffStopF) * (1.0 - math.exp(-dt / tau))
        if absOffStopF < 0.01 then absOffStopF = 0.0 end
    else
        absOffStopF = 0.0
    end
    HK.absOffBrakeMult = 1.0 - ((cfg.Stop and cfg.Stop.Penalty or 0.0) * absOffStopF)

    ------------------------------------------------------------------
    -- (1)+(3) STEERING PLOW on FRONT lock — resisted yaw; a rear-dominant lock CANCELS it (emergent
    -- tail-out). Demand = front-lock × steer input × brake, minus how much the rears out-lock the fronts.
    ------------------------------------------------------------------
    local sc = cfg.Steer
    if sc and sc.Enabled then
        local steerMag = math.abs(steer)
        local demand = 0.0
        if steerMag >= (sc.SteerGate or 0.10) and frontLock > 0.0 then
            local steerF = lerpClamp(steerMag, sc.SteerGate or 0.10, 0.6, 0.0, 1.0)
            local brakeF = lerpClamp(brake, cfg.BrakeGate or 0.55, 1.0, 0.4, 1.0)
            demand = frontLock * steerF * brakeF
            -- REAR-DOMINANT CANCEL: if the rears are locking MORE than the fronts (trail-brake tail-out),
            -- back the plow off so the natural grip-less-rear rotation comes through instead.
            local rot = cfg.Rotate
            if rot and rot.Enabled and rearLock > frontLock then
                local rearDom = lerpClamp(rearLock - frontLock, 0.0, 0.5, 0.0, 1.0)
                demand = demand * (1.0 - (rot.RearBias or 1.0) * rearDom)
            end
        end
        local tau = (demand > absOffSteerF) and (sc.EngageTau or 0.05) or (sc.ReleaseTau or 0.08)
        absOffSteerF = absOffSteerF + (demand - absOffSteerF) * (1.0 - math.exp(-dt / tau))
        if absOffSteerF < 0.01 then absOffSteerF = 0.0 end
        if absOffSteerF > 0.0 then
            -- Resist yaw: scale the yaw RATE down by up to MaxYawResist. applyYawScale only ever REDUCES
            -- (flip-proof, pitch/roll preserved). The car keeps its current heading = plows straight.
            local reduce = (sc.MaxYawResist or 0.55) * absOffSteerF
            applyYawScale(veh, 1.0 - reduce)
        end
    else
        absOffSteerF = 0.0
    end

    HK.dbgAbsOff = HK.dbgAbsOff or {}; local d = HK.dbgAbsOff
    d.on = true; d.steer = absOffSteerF; d.stop = absOffStopF
    d.fl = frontLock; d.rl = rearLock; d.at = GetGameTimer()
end
_G.ABSOff_Tick = ABSOff_Tick

-----------------------------------------------------------------
-- AWD EXTREME-SLIP SPIN SOFTENER (2026-08-13)
-- GTA's native spin-happiness past the furthest angle is the RISK that keeps AWD from being
-- point-and-shoot OP — we keep it. But real AWD with both axles gripping resists the SNAP: the
-- rotation builds slower, giving a real driver a catchable window. GTA under-models this — at the
-- limit an AWD lets go about as instantly as a RWD, and that instant snap is what feels cheap.
-- This slows the RATE of the final spin, never prevents it: scale the YAW RATE down by a small
-- capped fraction once slip is extreme, so counter-steer / throttle-save / handbrake actually have
-- time to work. THROTTLE FADES IT OUT — on the gas it hands off to PowerSave (the real rescue);
-- off the gas (the "too easily spins" complaint) it just buys a beat. Do-nothing still spins out,
-- so skill and risk stay intact — no OP auto-rescue.
--
-- SAFE YAW WRITE: scaling angular velocity must NOT clobber the suspension's pitch/roll for the
-- frame (that's the drift bump bug). We read the LIVE local angular velocity, keep local pitch/roll
-- untouched, scale ONLY the local yaw (z) component, rotate the vector back into WORLD via the car's
-- own basis, then Set. Pitch/roll round-trip exactly (a no-op); only yaw changes. Near a flip we
-- skip entirely and let stock physics own it.
-----------------------------------------------------------------
local function AWD_SpinSoftener(veh, state, dt, scfg)
    if not scfg or scfg.Enabled == false then return end
    local kmh = state.speedKmh or 0.0
    local airborne = (state.onAllWheels == false)
    if kmh < (scfg.MinSpeedKmh or 30.0) or airborne then
        spinSoftFactor = 0.0
        return
    end

    -- SLIP ANGLE: heading vs velocity (how far sideways the car is pointing). atan(|lat|/fwd) in deg.
    local fwd  = state.forwardSpeed or 0.0
    local latS = state.lateralSpeed or 0.0
    local slipDeg = (HK.load and HK.load.slipDeg) or ((fwd > 1.0) and math.abs(math.deg(math.atan(latS / fwd))) or 0.0)

    -- THROTTLE FADE: 1.0 below FadeStart (full softener) → 0.0 above FadeEnd (PowerSave owns it).
    local thr = state.throttle or 0.0
    local fadeS = scfg.ThrottleFadeStart or 0.10
    local fadeE = scfg.ThrottleFadeEnd or 0.30
    local thrFade = 1.0 - lerpClamp(thr, fadeS, fadeE, 0.0, 1.0)

    -- SLIP DEMAND: 0 at the gate → 1 at full-slip (extreme, spin-out territory).
    local gate = scfg.SlipGateDeg or 32.0
    local full = scfg.SlipFullDeg or 50.0
    local slipF = lerpClamp(slipDeg, gate, full, 0.0, 1.0)

    -- Combined demand: only when past the gate AND off/light throttle.
    local demand = slipF * thrFade

    -- Smooth engage/release so the yaw scale eases in and out (no snap of its own).
    -- 2026-08-13: +20% engage time (0.10→0.12) — softener eases in slower alongside the other AWD help.
    spinSoftFactor = spinSoftFactor + (demand - spinSoftFactor) * (1.0 - math.exp(-dt / 0.12))
    if spinSoftFactor < 0.01 then spinSoftFactor = 0.0; return end

    -- Yaw scale: remove up to MaxYawReduction of the yaw rate at full engagement. NEVER zeroes it.
    local reduce = (scfg.MaxYawReduction or 0.25) * spinSoftFactor
    -- RECENTER TAPER: fade the reduction as the car nears straight (yaw rate leads, slip holds a
    -- floor) so it eases into center instead of snapping flat — same shared taper as drift recovery.
    if HK and HK.recenterTaper then
        reduce = reduce * HK.recenterTaper(state.yawRate, slipDeg)
    end
    applyYawScale(veh, 1.0 - reduce)   -- shared flip-proof yaw write
end

-----------------------------------------------------------------
-- RWD SPIN SOFTENER (2026-08-13 — real RWD build)
-- GTA's core RWD flaw: the rear doesn't step out too FAR, it steps out too FAST — gone before you can
-- react. Same tool as the AWD softener (scale the yaw RATE down a capped amount at real slip so the
-- spin builds slow enough to catch), tuned STRONGER for RWD and — crucially — with NO throttle fade:
-- RWD power-on spin is the main event, so this softens on-power too (#1 feathers the torque spike,
-- this feathers the resulting yaw). Slows the spin, NEVER stops it — do nothing and you still spin, so
-- it stays raw RWD. Slip-angle gated so normal cornering is native. Uses the shared flip-proof write.
-----------------------------------------------------------------
local function RWD_SpinSoftener(veh, state, dt, scfg)
    if not scfg or scfg.Enabled == false then rwdSpinFactor = 0.0; return end
    local kmh = state.speedKmh or 0.0
    local airborne = (state.onAllWheels == false)
    if kmh < (scfg.MinSpeedKmh or 25.0) or airborne then
        rwdSpinFactor = 0.0
        return
    end

    -- SLIP ANGLE: heading vs velocity — how far the rear is actually out. Normal cornering stays low.
    local fwd  = state.forwardSpeed or 0.0
    local latS = state.lateralSpeed or 0.0
    local slipDeg = (HK.load and HK.load.slipDeg) or ((fwd > 1.0) and math.abs(math.deg(math.atan(latS / fwd))) or 0.0)

    -- Demand: 0 at the gate → 1 at full slip. No throttle fade (RWD spins on-power — soften it there too).
    local demand = lerpClamp(slipDeg, scfg.SlipGateDeg or 22.0, scfg.SlipFullDeg or 45.0, 0.0, 1.0)

    rwdSpinFactor = rwdSpinFactor + (demand - rwdSpinFactor) * (1.0 - math.exp(-dt / (scfg.EngageTau or 0.10)))
    if rwdSpinFactor < 0.01 then rwdSpinFactor = 0.0; return end

    -- Scale the yaw rate down (never zero) so the spin builds slow enough to counter-steer.
    local reduce = (scfg.MaxYawReduction or 0.30) * rwdSpinFactor
    -- RECENTER TAPER: fade the reduction as the car nears straight so the settle eases into center.
    if HK and HK.recenterTaper then
        reduce = reduce * HK.recenterTaper(state.yawRate, slipDeg)
    end
    applyYawScale(veh, 1.0 - reduce)   -- shared flip-proof yaw write
end

-----------------------------------------------------------------
-- AWD TORQUE VECTORING (2026-08-13 — feature #2)
-- Real AWD brakes the INNER-REAR wheel under power mid-corner. That wheel dragging makes a yaw
-- moment that ROTATES the car toward the apex — tightening your line — while the outer rear keeps
-- driving, so forward thrust barely drops (it's rotation, not a brake). GTA has none of this; the
-- AWD just washes wide. We reproduce it with the ONE proven safe path: add brake pressure to a
-- SINGLE inner-rear wheel (vl_brakeWheel), capped well below lockup so it scrubs, never locks.
-- Never touches throttle or the other three wheels → can't kill drive or flip. Engages only when
-- cornering UNDER POWER (throttle + steering + lateral load) and the car's planted; scaled by
-- lateral speed (tighter/faster corner = more rotation). The native is non-latching so we release
-- the wheel the moment we disengage or switch sides.
-- INNER wheel: steer > 0 = turning RIGHT → inner rear = RR (3); steer < 0 = LEFT → inner rear = RL (2).
-----------------------------------------------------------------
local TV_RR, TV_RL = 3, 2
local function AWD_TorqueVector(veh, state, dt, vcfg)
    if not vcfg or vcfg.Enabled == false then return end

    local function releaseTV()
        if tvBrakedWheel ~= nil then
            vl_brakeWheel(veh, tvBrakedWheel, 0.0)
            tvBrakedWheel = nil
        end
    end

    -- AIRBORNE = INSTANT RELEASE (see RWD_LiftRotation): a latched inner-rear brake would yaw the car
    -- sideways mid-air. Hard-release + zero factor now instead of decaying over ReleaseTau.
    if state.onAllWheels == false then tvFactor = 0.0; releaseTV(); return end

    local kmh   = state.speedKmh or 0.0
    local thr   = state.throttle or 0.0
    local steer = state.steer or 0.0        -- -1..1 (+ = right)
    local latS  = state.lateralSpeed or 0.0 -- m/s sideways
    local airborne = (state.onAllWheels == false)
    local wheelCount = state.wheelCount or GetVehicleNumberOfWheels(veh)

    -- Gates: fast enough, on the gas, actually steering, real lateral load, planted, 4-wheeled.
    local engaged = (kmh >= (vcfg.MinSpeedKmh or 40.0))
        and (thr >= (vcfg.ThrottleGate or 0.30))
        and (math.abs(steer) >= (vcfg.SteerGate or 0.12))
        and (math.abs(latS) >= (vcfg.LatGateMs or 1.5))
        and not airborne and wheelCount >= 4

    -- Demand 0..1 = how loaded the corner is (lateral speed past the gate). Tighter/faster = more.
    local demand = 0.0
    if engaged then
        demand = lerpClamp(math.abs(latS), vcfg.LatGateMs or 1.5, vcfg.LatFullMs or 7.0, 0.0, 1.0)
    end

    local tau = (demand > tvFactor) and (vcfg.EngageTau or 0.10) or (vcfg.ReleaseTau or 0.16)
    tvFactor = tvFactor + (demand - tvFactor) * (1.0 - math.exp(-dt / tau))
    if tvFactor < 0.01 then
        tvFactor = 0.0
        releaseTV()
        return
    end

    -- INNER rear = the wheel on the inside of the turn. Steering right → RR; left → RL.
    local inner = (steer >= 0.0) and TV_RR or TV_RL
    -- Switched sides (flicked the other way): release the old wheel first so it doesn't stay dragged.
    if tvBrakedWheel ~= nil and tvBrakedWheel ~= inner then
        vl_brakeWheel(veh, tvBrakedWheel, 0.0)
        tvBrakedWheel = nil
    end

    local pressure = (vcfg.MaxPressure or 0.22) * tvFactor
    vl_brakeWheel(veh, inner, pressure)
    tvBrakedWheel = inner
end

-----------------------------------------------------------------
-- AWD OFF-THROTTLE BALANCE (2026-08-13 — feature #3)
-- The mirror of torque vectoring, for when you LIFT mid-corner. Real cars are throttle-adjustable:
-- lift and weight shifts forward, the front bites, the rear lightens, the car ROTATES more — you
-- tuck the nose in by lifting. GTA doesn't model it (AWD just keeps washing wide off-throttle).
-- BUT overdo it and lift-off oversteer gets nervous. So this does BOTH, split by SLIP ANGLE so they
-- hand off instead of cancelling:
--   * LOW slip (understeering, nose wide) → TUCK-IN: gentle inner-rear brake adds rotation, tightening
--     the line (same safe capped mechanism as TorqueVector, but off-throttle and softer).
--   * RISING slip (rear stepping out) → tuck fades, a CALMING lateral damp fades in (only-ever-reduce
--     sideways velocity, same as BrakeStability — can't add slide/flip) so lift-off stays composed.
-- Tuck-in stands down while TorqueVector still holds the inner-rear brake (throttle-release tail), so
-- the two never write the same wheel the same frame. Off-throttle only; fades at low speed.
-- Takes tvEngaged (TorqueVector's current factor) so tuck-in yields the wheel to it.
-----------------------------------------------------------------
local function AWD_LiftBalance(veh, state, dt, lcfg, tvEngaged)
    local function releaseTuck()
        if lbTuckWheel ~= nil then
            -- Only clear the wheel if TorqueVector isn't the one currently holding it (shared wheel).
            if tvBrakedWheel ~= lbTuckWheel then
                vl_brakeWheel(veh, lbTuckWheel, 0.0)
            end
            lbTuckWheel = nil
        end
    end

    if not lcfg or lcfg.Enabled == false then lbTuckFactor = 0.0; releaseTuck(); return end

    local kmh   = state.speedKmh or 0.0
    local thr   = state.throttle or 0.0
    local steer = state.steer or 0.0
    local latS  = state.lateralSpeed or 0.0
    local fwd   = state.forwardSpeed or 0.0
    local airborne = (state.onAllWheels == false)
    local wheelCount = state.wheelCount or GetVehicleNumberOfWheels(veh)

    -- Off-throttle cornering, planted, fast enough, 4-wheeled, moving forward.
    local active = (kmh >= (lcfg.MinSpeedKmh or 35.0))
        and (thr <= (lcfg.LiftGate or 0.15))
        and (math.abs(steer) >= (lcfg.SteerGate or 0.15))
        and (fwd > 1.0) and not airborne and wheelCount >= 4

    if not active then
        lbTuckFactor = 0.0
        releaseTuck()
        return
    end

    -- SLIP ANGLE: heading vs velocity. Low = understeering (nose wide); high = rear stepping out.
    -- (`active` above already guaranteed fwd>1.0, so the spine value matches the old inline math.)
    local slipDeg = (HK.load and HK.load.slipDeg) or math.abs(math.deg(math.atan(latS / fwd)))

    -- ---- TUCK-IN (understeer regime): full below TuckSlipMax, faded out by TuckSlipZero ----
    -- Also yield to TorqueVector: if TV is still braking the inner rear (throttle-release tail),
    -- demand 0 so we don't double up on the same wheel.
    local tuckDemand = 0.0
    if (tvEngaged or 0.0) < 0.05 then
        tuckDemand = lerpClamp(slipDeg, lcfg.TuckSlipMax or 5.0, lcfg.TuckSlipZero or 11.0, 1.0, 0.0)
    end
    local ttau = (tuckDemand > lbTuckFactor) and (lcfg.TuckEngageTau or 0.14) or (lcfg.TuckReleaseTau or 0.18)
    lbTuckFactor = lbTuckFactor + (tuckDemand - lbTuckFactor) * (1.0 - math.exp(-dt / ttau))

    if lbTuckFactor < 0.01 then
        lbTuckFactor = 0.0
        releaseTuck()
    else
        -- INNER rear = inside of the turn. steer > 0 = right → RR(3); left → RL(2).
        local inner = (steer >= 0.0) and TV_RR or TV_RL
        if lbTuckWheel ~= nil and lbTuckWheel ~= inner and tvBrakedWheel ~= lbTuckWheel then
            vl_brakeWheel(veh, lbTuckWheel, 0.0)  -- switched sides: release the old wheel
        end
        local pressure = (lcfg.TuckMaxPressure or 0.14) * lbTuckFactor
        vl_brakeWheel(veh, inner, pressure)
        lbTuckWheel = inner
    end

    -- ---- CALMING DAMP (oversteer regime): fades in as slip rises past DampSlipMin ----
    local dampF = lerpClamp(slipDeg, lcfg.DampSlipMin or 9.0, lcfg.DampSlipFull or 24.0, 0.0, 1.0)
    local damp = (lcfg.DampLat or 3.0) * dampF
    if damp > 0.0 and math.abs(latS) > (lcfg.MinLatMs or 0.4) then
        local vel = state.velocity
        if vel then
            local k = math.exp(-damp * dt)
            local f2 = GetEntityForwardVector(veh)
            local rx, ry = f2.y, -f2.x
            local rmag = math.sqrt(rx*rx + ry*ry)
            if rmag > 0.001 then
                rx, ry = rx / rmag, ry / rmag
                local delta = latS * (k - 1.0)   -- negative = only ever shrinks |lat|
                SetEntityVelocity(veh, vel.x + rx * delta, vel.y + ry * delta, vel.z)
            end
        end
    end
end

-- Real-life model: the handbrake locks the REAR wheels, so the tail breaks loose and the car
-- PIVOTS (rotation). But an AWD's FRONT axle still has grip and pulls the nose back toward its
-- heading, so the slide SETTLES instead of spinning out (catch). A RWD would keep spinning; the
-- front-axle recovery is exactly what makes an AWD feel planted on the handbrake. We reproduce the
-- SEQUENCE: a short free-rotate window right after the yank (full pivot, no interference), then a
-- front-axle catch that eases in — damping the sideways slide so the tail comes back. Uses the same
-- only-ever-REDUCE-lateral-velocity mechanism as BumpSuppress/BrakeStability (can't add slide or
-- flip). Runs ONLY while the handbrake is held; hands the car straight back to native on release.
-----------------------------------------------------------------
local function AWD_HandbrakeAssist(veh, state, dt, hcfg)
    if not hcfg or hcfg.Enabled == false then return end
    local now = GetGameTimer()
    local hb  = (state.handbrake == true) or ((state.handbrake or 0) == 1)

    -- EDGE: fresh pull → stamp the start time so the free-rotate window is measured from the yank.
    if hb and not awdHbActive then
        awdHbActive  = true
        awdHbStartAt = now
    elseif not hb then
        awdHbActive = false
        return   -- handbrake up: no assist, pure native (the release itself needs no ramp — we only
                 -- ever removed lateral velocity, so there's nothing to "restore")
    end

    if state.onAllWheels == false then return end        -- airborne: no lateral bleed mid-air

    local kmh = state.speedKmh or 0.0
    if kmh < (hcfg.MinSpeedKmh or 20.0) then return end   -- parking-speed handbrake = harmless, skip

    -- FREE-ROTATE WINDOW: for the first FreeRotateMs after the yank, do NOTHING — let the rears lock
    -- and the car pivot fully (that's the intentional rotation). The catch only begins after this.
    local held = now - awdHbStartAt
    local freeMs = hcfg.FreeRotateMs or 260.0
    if held < freeMs then return end

    -- CATCH: ease the front-axle recovery in over CatchEaseMs (smoothstep, gentle onset) so it
    -- doesn't snap the tail back the instant the free window ends — it builds like the front tyres
    -- progressively loading up. Fully in by held = freeMs + CatchEaseMs, then held at full strength.
    local easeMs = hcfg.CatchEaseMs or 300.0
    local te = easeMs > 0.0 and ((held - freeMs) / easeMs) or 1.0
    if te < 0 then te = 0 elseif te > 1 then te = 1 end
    local ease = te * te * (3.0 - 2.0 * te)               -- smoothstep 0..1

    -- Only catch once the car is ACTUALLY sliding sideways past a small deadzone — a straight-line
    -- handbrake stop (drag race / just scrubbing speed) has ~0 lateral and needs no catch.
    local vel = state.velocity
    if not vel then return end
    local lat = state.lateralSpeed or 0.0
    if math.abs(lat) < (hcfg.MinLatMs or 1.2) then return end

    -- SPEED SCALE: the front axle catches HARDER at higher speed (more grip demand / a fast slide
    -- would spin), gentler down low (keep the handbrake playful for tight low-speed rotations).
    local spdScale = lerpClamp(kmh, hcfg.SpeedLowKmh or 30.0, hcfg.SpeedHighKmh or 110.0,
        hcfg.SpeedLowMult or 0.55, 1.0)

    local damp = (hcfg.CatchDamp or 3.2) * ease * spdScale
    if damp <= 0.0 then return end
    local k = math.exp(-damp * dt)                        -- <1, per-frame lateral retention
    local fwd = GetEntityForwardVector(veh)
    local rx, ry = fwd.y, -fwd.x                          -- horizontal right vector (in-plane)
    local rmag = math.sqrt(rx*rx + ry*ry)
    if rmag <= 0.001 then return end
    rx, ry = rx / rmag, ry / rmag
    local delta = lat * (k - 1.0)                          -- negative = only ever shrinks |lat|
    SetEntityVelocity(veh, vel.x + rx * delta, vel.y + ry * delta, vel.z)
end

-----------------------------------------------------------------
-- AWD HIGH-SPEED STEER RATE LIMIT (2026-08-10 v17 — reworked mechanism)
-- Earlier this scaled the steering *angle* down (SetVehicleSteeringScale),
-- which built a wall you couldn't steer past at speed ("can't turn at 220").
-- Wrong tool. What we actually want: full lock is ALWAYS reachable at any
-- speed, but the wheel SWINGS more slowly the faster you go — so you can't
-- flick across 3 lanes in a second, yet holding A/D still brings the car all
-- the way around. That's a RATE limit on how fast the wheel angle may change
-- per second, scaled by speed. We drive the wheel angle ourselves toward the
-- player's demanded angle, capped at MaxRateDeg/s (which shrinks with speed).
-- Uses SetVehicleSteeringAngle — NEVER touches handling.meta.
-----------------------------------------------------------------
local function AWD_SteerLimit(veh, state, dt, scfg)
    if not scfg or scfg.Enabled == false then return end
    if dt <= 0.0 then return end
    local kmh = state.speedKmh or 0.0

    -- Below the start speed: hand control back to the game (don't drive the angle).
    if kmh < (scfg.StartKmh or 150.0) then
        awdSteerAngle = nil
        return
    end

    -- The player's demanded wheel angle right now (what the game WANTS the wheels at).
    local target = GetVehicleSteeringAngle(veh)

    -- HIGH-SPEED ANGLE TAPER (2026-08-11): on top of the rate limit, trim the MAX wheel angle
    -- slightly as speed climbs so the car's sideways sway gets tighter at speed. Proportional +
    -- smooth (NOT the v17 hard wall) — scales the demand from 1.0 at StartKmh down to MinAngleFrac
    -- at FullKmh, so at top speed full lock still reaches MinAngleFrac (e.g. 0.85 = 15% less) and
    -- you can always still turn. Rate limiter below then eases toward this tapered target.
    local angleFrac = lerpClamp(kmh,
        scfg.StartKmh or 150.0, scfg.FullKmh or 320.0,
        1.0, scfg.MinAngleFrac or 0.85)
    target = target * angleFrac

    -- Sync our tracked angle to the current wheel angle on the first limited frame,
    -- so we ramp from where the wheels actually are (no snap).
    if awdSteerAngle == nil then
        awdSteerAngle = target
    end

    -- Max angular rate (deg/s) the wheel may move this frame — full rate below StartKmh,
    -- shrinking to MinRateFrac of it by FullKmh (higher speed = slower, more deliberate swing).
    local baseRate = scfg.MaxRateDeg or 220.0
    local rateFrac = lerpClamp(kmh,
        scfg.StartKmh or 150.0, scfg.FullKmh or 320.0,
        1.0, scfg.MinRateFrac or 0.35)
    local maxStep = baseRate * rateFrac * dt   -- deg allowed this frame

    -- Move our angle toward the demand, clamped to maxStep. Target (full lock) is always
    -- reachable given enough time — we only limit how FAST we get there.
    local diff = target - awdSteerAngle
    if diff > maxStep then diff = maxStep elseif diff < -maxStep then diff = -maxStep end
    awdSteerAngle = awdSteerAngle + diff

    SetVehicleSteeringAngle(veh, awdSteerAngle)
end

-----------------------------------------------------------------
-- REAR-WHEEL STEER (4WS) SPEED GATE (2026-08-11)
-- Cars like the AMG ONE carry HF_STEER_ALL_WHEELS (strHandlingFlags bit
-- 0x80): the rears steer IN-PHASE at the SAME full front lock, at EVERY
-- speed. GTA can't do a partial or counter-phase rear angle (the bit is
-- on/off, tied to fSteeringLock) — so real speed-dependent 4WS isn't
-- reproducible. But the always-on version is wrong at LOW speed: real 4WS
-- counter-steers the rears low for agility; GTA steers them in-phase, so
-- the whole car translates sideways instead of rotating = turns wide / won't
-- rotate (the same low-speed wide signature the AWD low-speed fade fights).
--
-- Fix: gate the bit by speed. Below LowKmh clear it (rears straight → the
-- car rotates normally); above HighKmh set it (rears in-phase → the stable,
-- flat high-speed lane-change the flag is good for). A hysteresis band
-- between the two thresholds stops it chattering at the crossover.
--
-- strHandlingFlags is an INT field: SetVehicleHandlingInt, NOT vehlib (float
-- only). We capture the native int on first sight and restore it on reset —
-- NEVER touches handling.meta.
-----------------------------------------------------------------
local function RearSteer_Tick(veh, state, dt, rcfg)
    if not rcfg or rcfg.Enabled == false then return end
    if not rearSteerCapable then return end
    if rearSteerNative == nil then return end

    local kmh = state.speedKmh or 0.0
    local lowKmh  = rcfg.LowKmh  or 45.0    -- below → rears straight (rotate normally)
    local highKmh = rcfg.HighKmh or 70.0    -- above → rears in-phase (stable lane-change)

    -- Decide the target bit state with hysteresis (band between low/high avoids chatter):
    --   below lowKmh  → want OFF   |   above highKmh → want ON   |   between → hold current.
    local want
    if kmh <= lowKmh then
        want = false
    elseif kmh >= highKmh then
        want = true
    else
        want = rearSteerOn   -- inside the band: keep whatever we last applied (nil-safe below)
    end
    if want == nil then want = (kmh >= highKmh) end   -- first-frame inside band → speed decides

    if want ~= rearSteerOn then
        local flags = rearSteerNative
        if want then
            flags = flags | REARSTEER_BIT          -- restore the native-on rear steer
        else
            flags = flags & (~REARSTEER_BIT)       -- clear it: rears go straight
        end
        SetVehicleHandlingInt(veh, 'CHandlingData', 'strHandlingFlags', flags)
        rearSteerOn = want
    end
end

-----------------------------------------------------------------
-- FWD BRANCH (2026-08-14) — real front-wheel-drive character.
-- Four tools, all reusing the proven AWD/RWD mechanisms (bias shifts + inner-wheel brake vectoring),
-- grounded-gated + exp-tau smoothed, NEVER touching handling.meta:
--   (1) PowerUndersteer — on-power plow (fDriveBiasFront forward), the defining FWD trait.
--   (2) LiftRotation    — lift/trail-brake tail rotation (inner-rear brake), "touch of 2".
--   (4) DriveOut        — corner-exit planted pull-out (fTractionBiasFront forward).
--   (5) TorqueSteer     — hard-power front-spin tug (inner-front brake pulse), the authentic annoyance.
-- Wheel indices: 0=FL, 1=FR, 2=RL, 3=RR.
-----------------------------------------------------------------

-- (1) POWER UNDERSTEER — mirror of AWD_Understeer, pushed harder. Shifts fDriveBiasFront FORWARD on
-- power+steer+speed so the nose washes wide. Coast floor keeps a little off-throttle (no cliff), faded
-- by braking so trail-braking still rotates. Landing-settle holds native so a touchdown can't snap it.
local function FWD_PowerUndersteer(veh, state, dt, ucfg, plowDampen)
    plowDampen = plowDampen or 1.0
    if not ucfg or ucfg.Enabled == false then
        if fwUnderBias and nativeFrontBias and math.abs(fwUnderBias - nativeFrontBias) > 0.001 then
            vl_setHandling(veh, 'fDriveBiasFront', nativeFrontBias)
            fwUnderBias = nativeFrontBias
        end
        return
    end
    local base = nativeFrontBias or 0.7
    local kmh  = state.speedKmh or 0.0
    local thr  = state.throttle or 0.0
    local brake= state.brake or 0.0

    -- Landing settle: while airborne (and briefly after) bleed bias to native, skip engage.
    local now = GetGameTimer()
    if state.onAllWheels == false then fwUnderSettle = now + (ucfg.LandSettleMs or 260) end
    if state.onAllWheels == false or now < fwUnderSettle then
        local cur = fwUnderBias or base
        if math.abs(cur - base) > 0.001 then
            local nb = cur + (base - cur) * (1.0 - math.exp(-dt / (ucfg.ReleaseTau or 0.16)))
            vl_setHandling(veh, 'fDriveBiasFront', nb); fwUnderBias = nb
        end
        return
    end

    -- On-power component (0 at gate → 1 at full) + coast floor faded out by braking.
    local thrOn = (thr >= (ucfg.ThrottleGate or 0.30))
        and lerpClamp(thr, ucfg.ThrottleGate or 0.30, 1.0, 0.0, 1.0) or 0.0
    local coast = (ucfg.CoastFloor or 0.20) * lerpClamp(brake, 0.0, ucfg.BrakeCut or 0.50, 1.0, 0.0)
    local thrFactor = coast + (1.0 - coast) * thrOn
    -- Speed ramp × squared steer factor × low-speed fade (identical shaping to AWD_Understeer).
    local spdFactor = lerpClamp(kmh, ucfg.SpeedLowKmh or 45.0, ucfg.SpeedHighKmh or 120.0,
        ucfg.SpeedLowMult or 0.25, ucfg.SpeedHighMult or 1.0)
    local steerAbs = math.abs(state.steer or 0.0)
    local steerFactor = lerpClamp(steerAbs, ucfg.SteerLow or 0.15, ucfg.SteerHigh or 0.85, ucfg.SteerLowMult or 0.15, 1.0)
    steerFactor = steerFactor * steerFactor
    local lowFade = lerpClamp(kmh, ucfg.LowFadeZeroKmh or 22.0, ucfg.LowFadeFullKmh or 65.0, 0.0, 1.0)
    -- plowDampen (< 1.0) is fed by FWD_SportDiff: when the LSD hook is pulling the nose IN, back off the
    -- plow so the two don't cancel to mush (an LSD car should rotate on power, not wash).
    local demand = thrFactor * spdFactor * steerFactor * lowFade * plowDampen

    -- Target bias = native + demand×MaxAddFront, clamped to a sane ceiling (never fully lock fronts).
    local target = base + demand * (ucfg.MaxAddFront or 0.12)
    if target > 0.95 then target = 0.95 end
    local cur = fwUnderBias or base
    local tau = (target > cur) and (ucfg.EngageTau or 0.10) or (ucfg.ReleaseTau or 0.16)
    local nb  = cur + (target - cur) * (1.0 - math.exp(-dt / tau))
    vl_setHandling(veh, 'fDriveBiasFront', nb)
    fwUnderBias = nb
    HK.dbgFwd = HK.dbgFwd or {}
    HK.dbgFwd.under = demand
end
-- (2) LIFT-OFF ROTATION — inner-rear brake vectoring on lift/trail-brake (mirror of RWD_LiftRotation,
-- tuned a notch above balanced). Only ADDS pressure to ONE rear wheel (can't flip). Non-latching.
local function FWD_LiftRotation(veh, state, dt, lcfg, lsCfg)
    local function release()
        if fwLiftWheel ~= nil then vl_brakeWheel(veh, fwLiftWheel, 0.0); fwLiftWheel = nil end
    end
    if not lcfg or lcfg.Enabled == false then fwLiftFactor = 0.0; release(); return end
    -- AIRBORNE = INSTANT RELEASE (see RWD_LiftRotation): a latched inner-rear brake yaws the car
    -- sideways mid-air. Hard-release + zero factor now rather than decaying over ReleaseTau.
    if state.onAllWheels == false then fwLiftFactor = 0.0; release(); return end

    local kmh   = state.speedKmh or 0.0
    local thr   = state.throttle or 0.0
    local brake = state.brake or 0.0
    local steer = state.steer or 0.0
    local latS  = state.lateralSpeed or 0.0
    local fwd   = state.forwardSpeed or 0.0
    local airborne = (state.onAllWheels == false)
    local wheelCount = state.wheelCount or GetVehicleNumberOfWheels(veh)

    local active = (kmh >= (lcfg.MinSpeedKmh or 28.0))
        and (thr <= (lcfg.LiftGate or 0.25))
        and (math.abs(steer) >= (lcfg.SteerGate or 0.14))
        and (math.abs(latS) >= (lcfg.LatGateMs or 1.2))
        and (fwd > 1.0) and not airborne and wheelCount >= 4

    local demand = 0.0
    if active then
        local liftF = lerpClamp(thr, 0.0, lcfg.LiftGate or 0.25, 1.0, 0.0)
        local latF  = lerpClamp(math.abs(latS), lcfg.LatGateMs or 1.2, lcfg.LatFullMs or 6.0, 0.0, 1.0)
        local brakeBoost = 1.0 + (lcfg.BrakeBoost or 0.6) * math.min(brake, 1.0)
        demand = math.min(liftF * latF * brakeBoost, 1.0)
    end
    local tau = (demand > fwLiftFactor) and (lcfg.EngageTau or 0.10) or (lcfg.ReleaseTau or 0.15)
    fwLiftFactor = fwLiftFactor + (demand - fwLiftFactor) * (1.0 - math.exp(-dt / tau))
    if fwLiftFactor < 0.01 then fwLiftFactor = 0.0; release(); return end

    -- Speed-scaled lift-off oversteer: little rotation in slow corners, a lot in fast sweepers (that
    -- snap-lift-off tail JDM hot-hatches are infamous for). Multiplies the brake pressure by speed.
    local liftScale = 1.0
    if lsCfg and lsCfg.Enabled ~= false then
        liftScale = lerpClamp(kmh, lsCfg.LowKmh or 45.0, lsCfg.HighKmh or 120.0,
            lsCfg.LowMult or 0.55, lsCfg.HighMult or 1.35)
    end
    -- Inner rear: steer > 0 = turning RIGHT → RR(3); left → RL(2).
    local inner = (steer >= 0.0) and 3 or 2
    if fwLiftWheel ~= nil and fwLiftWheel ~= inner then
        vl_brakeWheel(veh, fwLiftWheel, 0.0); fwLiftWheel = nil
    end
    vl_brakeWheel(veh, inner, (lcfg.MaxPressure or 0.17) * fwLiftFactor * liftScale)
    fwLiftWheel = inner
    HK.dbgFwd = HK.dbgFwd or {}; HK.dbgFwd.lift = fwLiftFactor
end

-- (2b) LIFT-SNAP SPIN SOFTENER — the safety net behind FWD_LiftRotation's speed-scaled swing.
-- LiftSpeedScale deliberately AMPLIFIES the lift-off tail rotation up to ~1.35x in fast corners so a
-- FWD hot-hatch gets that infamous snap-oversteer on a mid-corner lift. But FWD, unlike RWD/AWD, had
-- NO yaw-rate softener behind it — so at high speed that snap could build faster than a human can
-- catch, turning a fun rotation into an uncatchable spin. This mirrors RWD_SpinSoftener: measure the
-- real slip angle (heading vs velocity) and, once the rear is genuinely stepping out, scale the yaw
-- RATE down (never zero) so the slide develops slow enough to counter-steer. It only reads yaw, never
-- touches throttle or a wheel, and can't flip. Because the FWD snap is a LIFT phenomenon we lean the
-- gate toward off-throttle (no throttle fade — the danger is precisely when you're OFF the gas).
local function FWD_SpinSoftener(veh, state, dt, scfg)
    if not scfg or scfg.Enabled == false then fwSpinSoft = 0.0; return end
    local kmh = state.speedKmh or 0.0
    local airborne = (state.onAllWheels == false)
    if kmh < (scfg.MinSpeedKmh or 55.0) or airborne then
        fwSpinSoft = 0.0
        return
    end

    -- SLIP ANGLE: heading vs velocity — how far the rear has actually stepped out. Normal FWD
    -- cornering (plow/understeer) stays LOW here; this only wakes up on a genuine lift-snap rotation.
    local fwd  = state.forwardSpeed or 0.0
    local latS = state.lateralSpeed or 0.0
    local slipDeg = (HK.load and HK.load.slipDeg) or ((fwd > 1.0) and math.abs(math.deg(math.atan(latS / fwd))) or 0.0)

    -- Demand: 0 at the gate → 1 at full slip. Gate a notch HIGHER than RWD (FWD shouldn't be sliding
    -- at all in normal driving, so we only intervene once it's clearly a snap, not a lazy drift).
    local demand = lerpClamp(slipDeg, scfg.SlipGateDeg or 26.0, scfg.SlipFullDeg or 48.0, 0.0, 1.0)

    fwSpinSoft = fwSpinSoft + (demand - fwSpinSoft) * (1.0 - math.exp(-dt / (scfg.EngageTau or 0.09)))
    if fwSpinSoft < 0.01 then fwSpinSoft = 0.0; return end

    -- Scale the yaw rate down (never zero) so the snap builds slow enough to counter-steer.
    local reduce = (scfg.MaxYawReduction or 0.32) * fwSpinSoft
    -- RECENTER TAPER: fade the reduction as the car nears straight so the settle eases into center.
    if HK and HK.recenterTaper then
        reduce = reduce * HK.recenterTaper(state.yawRate, slipDeg)
    end
    applyYawScale(veh, 1.0 - reduce)   -- shared flip-proof yaw write
    HK.dbgFwd = HK.dbgFwd or {}; HK.dbgFwd.spinsoft = fwSpinSoft
end
-- (4) CORNER-EXIT DRIVE-OUT — on power out of a corner (wheel unwinding), shift fTractionBiasFront
-- FORWARD so the fronts claw grip and pull the car straight out (planted). Restores native off-power.
local function FWD_DriveOut(veh, state, dt, dcfg)
    if not dcfg or dcfg.Enabled == false then
        if fwPlantOn and nativeTractionBias ~= nil then
            vl_setHandling(veh, 'fTractionBiasFront', nativeTractionBias); fwPlantOn = false
        end
        fwPlantFactor = 0.0
        return
    end
    local base = nativeTractionBias or 0.5
    local kmh  = state.speedKmh or 0.0
    local thr  = state.throttle or 0.0
    local steerAbs = math.abs(state.steer or 0.0)
    local fwd  = state.forwardSpeed or 0.0

    -- Active on power, moving forward, grounded, with the wheel UNWINDING (exit) not at full apex lock.
    local active = (kmh >= (dcfg.MinSpeedKmh or 30.0))
        and (thr >= (dcfg.ThrottleGate or 0.35))
        and (fwd > 1.0) and (state.onAllWheels ~= false)
    local demand = 0.0
    if active then
        local thrF   = lerpClamp(thr, dcfg.ThrottleGate or 0.35, 1.0, 0.0, 1.0)
        -- Exit factor: grows as steering unwinds below SteerRelease (1.0 straight, 0.0 at/above release).
        local exitF  = lerpClamp(steerAbs, 0.0, dcfg.SteerRelease or 0.55, 1.0, 0.0)
        demand = thrF * exitF
    end
    local tau = (demand > fwPlantFactor) and (dcfg.EngageTau or 0.09) or (dcfg.ReleaseTau or 0.18)
    fwPlantFactor = fwPlantFactor + (demand - fwPlantFactor) * (1.0 - math.exp(-dt / tau))
    if fwPlantFactor < 0.01 then
        fwPlantFactor = 0.0
        if fwPlantOn then vl_setHandling(veh, 'fTractionBiasFront', base); fwPlantOn = false end
        return
    end
    local target = base + fwPlantFactor * (dcfg.MaxAddFront or 0.10)
    if target > 0.95 then target = 0.95 end
    vl_setHandling(veh, 'fTractionBiasFront', target)
    fwPlantOn = true
    HK.dbgFwd = HK.dbgFwd or {}; HK.dbgFwd.plant = fwPlantFactor
end
-- (5) TORQUE STEER — the authentic tug. Under HARD power with FRONT wheelspin at low/mid speed, pulse
-- the LESS-loaded (more-spinning) front wheel's brake so the nose tugs toward that side, like an open
-- diff yanking under torque. Small, speed-faded, hard-power-only. Inner-front brake, non-latching.
local function FWD_TorqueSteer(veh, state, dt, tcfg)
    local function release()
        if fwTsWheel ~= nil then vl_brakeWheel(veh, fwTsWheel, 0.0); fwTsWheel = nil end
    end
    if not tcfg or tcfg.Enabled == false then fwTsFactor = 0.0; release(); return end
    -- AIRBORNE = INSTANT RELEASE (see RWD_LiftRotation): a spinning front in the air reads huge over-speed
    -- and would latch a front brake, yawing the car sideways mid-air. Hard-release + zero now, no decay.
    if state.onAllWheels == false then fwTsFactor = 0.0; release(); return end

    local kmh = state.speedKmh or 0.0
    local thr = state.throttle or 0.0
    local ground = GetEntitySpeed(veh)
    -- Front wheel over-speed (spin) vs ground, per side.
    local flSpin = math.abs(GetVehicleWheelSpeed(veh, 0)) - ground
    local frSpin = math.abs(GetVehicleWheelSpeed(veh, 1)) - ground
    local worst  = math.max(flSpin, frSpin)

    local active = (thr >= (tcfg.MinThrottle or 0.70))
        and (worst >= (tcfg.SpinThreshMs or 2.0))
        and (state.onAllWheels ~= false) and (kmh < (tcfg.SpeedZeroKmh or 90.0))
    local demand = 0.0
    if active then
        local spinF = lerpClamp(worst, tcfg.SpinThreshMs or 2.0, (tcfg.SpinThreshMs or 2.0) + 4.0, 0.0, 1.0)
        local spdF  = lerpClamp(kmh, tcfg.SpeedLowKmh or 8.0, tcfg.SpeedZeroKmh or 90.0, 1.0, 0.0)
        demand = spinF * spdF
    end
    local tau = (demand > fwTsFactor) and (tcfg.EngageTau or 0.05) or (tcfg.ReleaseTau or 0.12)
    fwTsFactor = fwTsFactor + (demand - fwTsFactor) * (1.0 - math.exp(-dt / tau))
    if fwTsFactor < 0.01 then fwTsFactor = 0.0; release(); return end

    -- Tug toward the MORE-spinning side: brake THAT front wheel (it's losing grip, braking plants it and
    -- yanks the nose that way — the real open-diff torque-steer feel). FL(0) spins more → pull left, etc.
    local wheel = (flSpin >= frSpin) and 0 or 1
    if fwTsWheel ~= nil and fwTsWheel ~= wheel then vl_brakeWheel(veh, fwTsWheel, 0.0); fwTsWheel = nil end
    -- TC-OFF CHARACTER BOOST: the nose-tug from front wheelspin is FWD's "TC off" tell. Sharpen it, but
    -- keep a hard ceiling above the configured cap so a boosted tug can't yank the car off-line.
    local charMul = 1.0
    do local to = HK.dtTCOff; if to and to.on then charMul = to.charBoost end end
    local capP = (tcfg.MaxPressure or 0.10)
    vl_brakeWheel(veh, wheel, math.min(capP * fwTsFactor * charMul, capP * 1.5))
    fwTsWheel = wheel
    HK.dbgFwd = HK.dbgFwd or {}; HK.dbgFwd.ts = fwTsFactor
end

-- Resolve whether the tracked car is a sport-diff (LSD) car — cached per vehicle. Follows the SAME
-- philosophy as the drivetrain classifier: it's the TUNED handling value that decides, never a car
-- name. Pure FWD tunes toward fDriveBiasFront = 1.0; we reserve the TOP of the FWD band for the
-- sporty LSD hatches (Type R / Megane RS class) and leave the lower FWD band as economy open-diff
-- plow. So: fDriveBiasFront >= SportDiffBias → LSD hook; below → open-diff understeer. The /sportdiff
-- override (HK.fwSportDiffOverride: true/false/nil) still wins for on-the-fly testing on any car.
local function resolveSportDiff(veh, scfg)
    if HK.fwSportDiffOverride ~= nil then return HK.fwSportDiffOverride == true end
    local threshold = (scfg and scfg.SportDiffBias) or 0.72
    return (nativeFrontBias or 0.0) >= threshold
end

-- (6) LSD / SPORT-DIFF HOOK-UP — brake the INSIDE-front so torque shoves to the loaded outside front,
-- pulling the nose INTO the corner on power (the Type-R hook). Only for sport-diff cars. Returns the
-- 0..1 engagement so PowerUndersteer can be dampened when the diff is winning (they oppose each other).
local function FWD_SportDiff(veh, state, dt, scfg)
    local function release()
        if fwSdWheel ~= nil then vl_brakeWheel(veh, fwSdWheel, 0.0); fwSdWheel = nil end
    end
    if not scfg or scfg.Enabled == false then fwSdFactor = 0.0; release(); return 0.0 end
    if fwSportDiff == nil then fwSportDiff = resolveSportDiff(veh, scfg) end
    if not fwSportDiff then fwSdFactor = 0.0; release(); return 0.0 end
    -- AIRBORNE = INSTANT RELEASE (see RWD_LiftRotation): a latched inside-front brake yaws the car
    -- sideways mid-air. Hard-release + zero factor now rather than decaying over ReleaseTau.
    if state.onAllWheels == false then fwSdFactor = 0.0; release(); return 0.0 end

    local kmh   = state.speedKmh or 0.0
    local thr   = state.throttle or 0.0
    local steer = state.steer or 0.0
    local latS  = state.lateralSpeed or 0.0
    local fwd   = state.forwardSpeed or 0.0
    local active = (kmh >= (scfg.MinSpeedKmh or 22.0))
        and (thr >= (scfg.ThrottleGate or 0.35))
        and (math.abs(steer) >= (scfg.SteerGate or 0.12))
        and (math.abs(latS) >= (scfg.LatGateMs or 1.5))
        and (fwd > 1.0) and (state.onAllWheels ~= false)
    local demand = 0.0
    if active then
        local thrF = lerpClamp(thr, scfg.ThrottleGate or 0.35, 1.0, 0.0, 1.0)
        local latF = lerpClamp(math.abs(latS), scfg.LatGateMs or 1.5, scfg.LatFullMs or 6.0, 0.0, 1.0)
        local spdF = lerpClamp(kmh, scfg.SpeedLowKmh or 30.0, scfg.SpeedHighKmh or 110.0,
            scfg.SpeedLowMult or 0.55, scfg.SpeedHighMult or 1.0)
        demand = thrF * latF * spdF
    end
    local tau = (demand > fwSdFactor) and (scfg.EngageTau or 0.08) or (scfg.ReleaseTau or 0.16)
    fwSdFactor = fwSdFactor + (demand - fwSdFactor) * (1.0 - math.exp(-dt / tau))
    if fwSdFactor < 0.01 then fwSdFactor = 0.0; release(); return 0.0 end

    -- INSIDE front = inside of the turn. steer > 0 = right → FR(1) is inside; left → FL(0).
    local inner = (steer >= 0.0) and 1 or 0
    if fwSdWheel ~= nil and fwSdWheel ~= inner then vl_brakeWheel(veh, fwSdWheel, 0.0); fwSdWheel = nil end
    vl_brakeWheel(veh, inner, (scfg.MaxPressure or 0.14) * fwSdFactor)
    fwSdWheel = inner
    HK.dbgFwd = HK.dbgFwd or {}; HK.dbgFwd.sd = fwSdFactor
    return fwSdFactor
end

-- (7) FRONT WHEELSPIN DRIVE PENALTY — spinning fronts waste torque (go nowhere). Cut engine torque while
-- the fronts over-speed the ground under power. Re-applies via vl_setTorque at the FWD tick tail because
-- the drivetrain tick runs AFTER main.lua's single vl_setTorque (HK.torqueMult is already spent).
local function FWD_SpinPenalty(veh, state, dt, pcfg)
    if not pcfg or pcfg.Enabled == false then fwSpinCut = 0.0; return end
    local kmh = state.speedKmh or 0.0
    local thr = state.throttle or 0.0
    local ground = GetEntitySpeed(veh)
    local worst = math.max(math.abs(GetVehicleWheelSpeed(veh, 0)) - ground,
                           math.abs(GetVehicleWheelSpeed(veh, 1)) - ground)
    local active = (thr >= (pcfg.MinThrottle or 0.55))
        and (worst >= (pcfg.SpinThreshMs or 2.5))
        and (state.onAllWheels ~= false) and (kmh < (pcfg.SpeedZeroKmh or 70.0))
    local demand = 0.0
    if active then
        local spinF = lerpClamp(worst, pcfg.SpinThreshMs or 2.5, pcfg.SpinFullMs or 7.0, 0.0, 1.0)
        local spdF  = lerpClamp(kmh, 0.0, pcfg.SpeedZeroKmh or 70.0, 1.0, 0.0)
        demand = spinF * spdF
    end
    local tau = (demand > fwSpinCut) and (pcfg.EngageTau or 0.06) or (pcfg.ReleaseTau or 0.14)
    fwSpinCut = fwSpinCut + (demand - fwSpinCut) * (1.0 - math.exp(-dt / tau))
    if fwSpinCut < 0.01 then fwSpinCut = 0.0; return end
    -- TC-OFF STAND-DOWN: this penalty is a TC-like torque cut (spinning fronts → trim power). With TC
    -- off the fronts are meant to scrabble freely, so reduce the cut by StabilityStandDown (leave a
    -- sliver so a hopeless spin still wastes a little torque, keeping it from going fully silly).
    local cutScale = 1.0
    do local to = HK.dtTCOff; if to and to.on and to.fwdSpinFree then cutScale = to.standDown end end
    -- Re-apply this frame's torque scaled down by the penalty (last vl_setTorque write of the frame wins).
    local applied = HK.torqueMultApplied or 1.0
    vl_setTorque(veh, applied * (1.0 - (pcfg.MaxCut or 0.35) * fwSpinCut * cutScale))
    HK.dbgFwd = HK.dbgFwd or {}; HK.dbgFwd.spincut = fwSpinCut
end

-- (9) BRAKING UNDERSTEER / FRONT-LOCK — hard braking + steering washes the nose wide (fronts locked,
-- no steering grip). Scale fSteeringLock down briefly so the car plows on the brakes. Restores on ease.
local function FWD_BrakeUndersteer(veh, state, dt, bcfg)
    if not bcfg or bcfg.Enabled == false then
        if fwBrakeUsFactor > 0.001 and nativeSteerLock ~= nil then
            vl_setHandling(veh, 'fSteeringLock', nativeSteerLock)
        end
        fwBrakeUsFactor = 0.0
        return
    end
    local kmh   = state.speedKmh or 0.0
    local brake = state.brake or 0.0
    local steerAbs = math.abs(state.steer or 0.0)
    local active = (brake >= (bcfg.BrakeGate or 0.75))
        and (steerAbs >= (bcfg.SteerGate or 0.15))
        and (kmh >= (bcfg.MinSpeedKmh or 40.0))
        and (state.onAllWheels ~= false)
    local demand = active and lerpClamp(brake, bcfg.BrakeGate or 0.75, 1.0, 0.0, 1.0) or 0.0
    local tau = (demand > fwBrakeUsFactor) and (bcfg.EngageTau or 0.07) or (bcfg.ReleaseTau or 0.13)
    fwBrakeUsFactor = fwBrakeUsFactor + (demand - fwBrakeUsFactor) * (1.0 - math.exp(-dt / tau))
    if nativeSteerLock == nil then nativeSteerLock = vl_getHandling(veh, 'fSteeringLock') end
    if fwBrakeUsFactor < 0.01 then
        fwBrakeUsFactor = 0.0
        if nativeSteerLock ~= nil then vl_setHandling(veh, 'fSteeringLock', nativeSteerLock) end
        return
    end
    if nativeSteerLock ~= nil then
        vl_setHandling(veh, 'fSteeringLock', nativeSteerLock * (1.0 - (bcfg.MaxLockCut or 0.22) * fwBrakeUsFactor))
    end
    HK.dbgFwd = HK.dbgFwd or {}; HK.dbgFwd.brakeus = fwBrakeUsFactor
end

-- (10) BRAKING-STRAIGHTEN — the weight-transfer spine mirror of RWD_BrakeRotation, opposite sign.
-- RWD_BrakeRotation reads load.rear: braking UNLOADS the rear → the tail steps out (rotation).
-- FWD is the mirror: under braking/lift the nose LOADS UP (load.front rises above static), and on a
-- front-drive car that loaded, driven, steering front axle drags the car STRAIGHT — like a cart towed
-- from the front. Real FWD engine-braking is stabilising, not rotating. So this is a STABILITY tool:
-- when the front is loaded and the car is going roughly straight, gently DAMP any developing yaw rate
-- (twitch/wander under braking) so the car tracks true. STRAIGHT-LINE ONLY — cornering is owned by
-- FWD_LiftRotation / FWD_BrakeUndersteer, so this bows out the moment there's real steering, and the
-- two never fight. Reads yaw only via the shared flip-proof applyYawScale (no wheel, no throttle, never
-- zeroes yaw) → can't flip, can't kill drive. Non-latching, exp-tau smoothed like every sibling.
local function FWD_BrakeStraighten(veh, state, dt, bcfg)
    if not bcfg or bcfg.Enabled == false then fwStraightFactor = 0.0; return end
    local L = HK.load
    if L == nil then fwStraightFactor = 0.0; return end

    local kmh   = state.speedKmh or 0.0
    local thr   = state.throttle or 0.0
    local brake = state.brake or 0.0
    local steerAbs = math.abs(state.steer or 0.0)
    local airborne = (state.onAllWheels == false)

    -- Active: decelerating (braking OR off-throttle), moving, planted, and roughly STRAIGHT. The steer
    -- gate is a CEILING here (unlike the cornering tools' floor) — real steering hands off to the
    -- rotation tools, so straighten fades out as you turn in.
    local decel = (brake >= (bcfg.BrakeGate or 0.15)) or (thr <= (bcfg.LiftGate or 0.10))
    local active = decel
        and (kmh >= (bcfg.MinSpeedKmh or 35.0))
        and (steerAbs <= (bcfg.SteerCeil or 0.30))
        and not airborne

    local demand = 0.0
    if active then
        -- FRONT-LOAD above static 0.5 (braking pushes load.front up toward ~0.85). The more the nose is
        -- loaded, the more straightening authority — a physically loaded front axle resists yaw.
        local loadF = lerpClamp((L.front or 0.5) - 0.5, bcfg.LoadGate or 0.05, bcfg.LoadFull or 0.30, 0.0, 1.0)
        -- Fade OUT as steering rises toward the ceiling (1.0 straight → 0.0 at SteerCeil) so turn-in is clean.
        local straightF = lerpClamp(steerAbs, 0.0, bcfg.SteerCeil or 0.30, 1.0, 0.0)
        -- Brake-depth term: a harder stop wants more composure (light lift barely straightens).
        local brakeF = lerpClamp(math.max(brake, (thr <= (bcfg.LiftGate or 0.10)) and (bcfg.LiftFloor or 0.30) or 0.0),
            bcfg.BrakeGate or 0.15, bcfg.BrakeFull or 0.85, 0.0, 1.0)
        demand = loadF * straightF * brakeF
    end

    local tau = (demand > fwStraightFactor) and (bcfg.EngageTau or 0.09) or (bcfg.ReleaseTau or 0.15)
    fwStraightFactor = fwStraightFactor + (demand - fwStraightFactor) * (1.0 - math.exp(-dt / tau))
    if fwStraightFactor < 0.01 then fwStraightFactor = 0.0; return end

    -- Damp the yaw RATE down (never zero) so braking twitch settles into a straight line. Same shared
    -- flip-proof yaw write + recenter taper as the spin softeners.
    local reduce = (bcfg.MaxYawReduction or 0.22) * fwStraightFactor
    if HK and HK.recenterTaper then
        local fwd  = state.forwardSpeed or 0.0
        local latS = state.lateralSpeed or 0.0
        local slipDeg = (HK.load and HK.load.slipDeg) or ((fwd > 1.0) and math.abs(math.deg(math.atan(latS / fwd))) or 0.0)
        reduce = reduce * HK.recenterTaper(state.yawRate, slipDeg)
    end
    applyYawScale(veh, 1.0 - reduce)
    HK.dbgFwd = HK.dbgFwd or {}; HK.dbgFwd.straight = fwStraightFactor
end

-- FWD DISPATCHER — bias tools first, then brake-vectoring, then the JDM pack. SportDiff runs BEFORE
-- PowerUndersteer's plow is finalized so its dampen can apply; simplest: SportDiff returns its factor
-- and we pass a plow-dampen into PowerUndersteer.
local function FWD_Handling(veh, state, dt, fcfg)
    -- Sport-diff hook first (needs its engagement to dampen the opposing plow on these cars).
    local sdFactor = FWD_SportDiff(veh, state, dt, fcfg.SportDiff)
    local plowDampen = 1.0
    if sdFactor > 0.0 and fcfg.SportDiff then
        plowDampen = 1.0 - (1.0 - (fcfg.SportDiff.UndersteerDampen or 0.45)) * sdFactor
    end
    FWD_PowerUndersteer(veh, state, dt, fcfg.PowerUndersteer, plowDampen)
    FWD_DriveOut(veh, state, dt, fcfg.DriveOut)
    FWD_LiftRotation(veh, state, dt, fcfg.LiftRotation, fcfg.LiftSpeedScale)
    -- Spin softener runs BEHIND the lift swing: slow the yaw rate of a real high-speed lift-snap so
    -- it's catchable (the safety net LiftSpeedScale's 1.35x amplification otherwise has none).
    FWD_SpinSoftener(veh, state, dt, fcfg.SpinSoftener)
    FWD_TorqueSteer(veh, state, dt, fcfg.TorqueSteer)
    FWD_SpinPenalty(veh, state, dt, fcfg.SpinPenalty)
    FWD_BrakeUndersteer(veh, state, dt, fcfg.BrakeUndersteer)
    -- Braking-straighten LAST (spine mirror of RWD_BrakeRotation): damps yaw when the front is loaded
    -- and the car's going straight. Runs after BrakeUndersteer so the straight-line stability read is
    -- the final word (it only acts below the steer ceiling, where the cornering tools are already idle).
    FWD_BrakeStraighten(veh, state, dt, fcfg.BrakeStraighten)
    HK.dbgFwd = HK.dbgFwd or {}; HK.dbgFwd.sportdiff = fwSportDiff == true; HK.dbgFwd.at = GetGameTimer()
end

-----------------------------------------------------------------
-- WEIGHT-TRANSFER SPINE (2026-08-14) — compute the central load ONCE per frame into HK.load.
-- Read-only/additive for now: publishes the signal + overlay, no tool consumes it yet (see plan).
-- Runs FIRST in the dispatcher (before any branch) so a consumer added later reads THIS frame's load.
-----------------------------------------------------------------
local function WeightTransfer_Tick(veh, state, dt, wcfg)
    if not wcfg or wcfg.Enabled == false then return end
    if dt <= 0.0 then return end

    -- Reset the accel tracker on a vehicle swap so a car change doesn't spike a huge fake dv/dt.
    if veh ~= wtVeh then
        wtVeh = veh
        wtPrevFwd = state.forwardSpeed or 0.0
        wtLongAccel = 0.0
        wtLong = 0.0; wtLat = 0.0; wtFront = 0.5; wtRear = 0.5; wtSlipDeg = 0.0
    end

    local fwd = state.forwardSpeed or 0.0

    -- 1) LONGITUDINAL ACCEL (ground truth of long weight transfer): smoothed dv/dt of forward speed.
    local rawAccel = (fwd - wtPrevFwd) / dt          -- m/s^2 (+ speeding up, - slowing/braking)
    wtPrevFwd = fwd
    local aTau = wcfg.AccelTau or 0.08
    wtLongAccel = wtLongAccel + (rawAccel - wtLongAccel) * (1.0 - math.exp(-dt / aTau))

    -- 2) LONGITUDINAL LOAD -1..1: blend PEDAL intent (instant) with MEASURED accel (anchored to reality —
    -- a pedal held against a wall makes no transfer). Pedal term = throttle - brake.
    local pedal = (state.throttle or 0.0) - (state.brake or 0.0)               -- -1..1
    local measured = wtLongAccel / math.max(0.1, (wcfg.AccelMaxMs2 or 12.0))    -- -~1..~1
    if measured < -1.0 then measured = -1.0 elseif measured > 1.0 then measured = 1.0 end
    local aw = wcfg.AccelWeight or 0.55
    local longTarget = pedal * (1.0 - aw) + measured * aw
    if longTarget < -1.0 then longTarget = -1.0 elseif longTarget > 1.0 then longTarget = 1.0 end
    local lTau = wcfg.LongTau or 0.10
    wtLong = wtLong + (longTarget - wtLong) * (1.0 - math.exp(-dt / lTau))

    -- 3) LATERAL LOAD -1..1: lateral speed (m/s sideways) normalized, sign follows the slide direction.
    -- (lateralSpeed sign: +X = sliding right. We keep that sign as the load direction.)
    local latTarget = (state.lateralSpeed or 0.0) / math.max(0.1, (wcfg.LatMaxMs or 8.0))
    if latTarget < -1.0 then latTarget = -1.0 elseif latTarget > 1.0 then latTarget = 1.0 end
    local latTau = wcfg.LatTau or 0.10
    wtLat = wtLat + (latTarget - wtLat) * (1.0 - math.exp(-dt / latTau))

    -- 3b) SLIP ANGLE (deg) — INSTANT geometric heading-vs-velocity, NOT smoothed (distinct from wtLat).
    -- Every drivetrain helper recomputed this identical `atan(|lat|/fwd)` inline; compute it once here
    -- (spine runs first each frame) and publish so they can share ONE definition. Raw/unsmoothed on
    -- purpose — the helpers gate on true instantaneous slip, so this is byte-equivalent to their inline
    -- math (guarded fwd>1.0 → 0). This is a de-dup only; it does NOT change any consumer's feel.
    wtSlipDeg = (fwd > 1.0) and math.abs(math.deg(math.atan((state.lateralSpeed or 0.0) / fwd))) or 0.0

    -- 4) AXLE-LOAD SPLIT 0..1: static 0.5 each; long load shifts it. Braking (long<0) loads the FRONT,
    -- accel (long>0) loads the REAR. Shift magnitude capped by AxleShiftMax.
    local shift = -wtLong * (wcfg.AxleShiftMax or 0.35)   -- long<0 (brake) → +shift onto front
    wtFront = 0.5 + shift
    wtRear  = 0.5 - shift
    if wtFront < 0.0 then wtFront = 0.0 elseif wtFront > 1.0 then wtFront = 1.0 end
    if wtRear  < 0.0 then wtRear  = 0.0 elseif wtRear  > 1.0 then wtRear  = 1.0 end

    -- PUBLISH: one shared table every tool can read (Phase 2 additive; nothing consumes it yet).
    HK.load = HK.load or {}
    local L = HK.load
    L.long  = wtLong
    L.lat   = wtLat
    L.front = wtFront
    L.rear  = wtRear
    L.accel = wtLongAccel
    L.slipDeg = wtSlipDeg
    L.at    = GetGameTimer()
end

-----------------------------------------------------------------
-- HIGH-SPEED TRACTION-BIAS CENTERING — pairs with the gravity downforce.
-- The forum warning: heavier gravity at speed AMPLIFIES any off-center
-- fTractionBiasFront, so an understeery/oversteery car gets worse the faster it
-- goes. Counter it by nudging the bias a hair toward 0.5 as speed rises — but
-- ONLY on straight-line cruise, and NEVER while a cornering tool owns the field
-- (drivetrain is the single writer of fTractionBiasFront — we must not fight the
-- AWD/RWD/FWD bias shifts). 3rd-decimal moves only (per the forum: 0.498..0.502).
-- Runs LAST in Drivetrain_Tick so it sees whether a tool claimed the field.
-----------------------------------------------------------------
local function HighSpeedBiasCenter(veh, state)
    local dcfg = Config.Downforce and Config.Downforce.BiasCenter
    -- Off, or we don't know the native bias yet → make sure any prior nudge is undone.
    if not dcfg or not dcfg.Enabled or nativeTractionBias == nil then
        if biasCenterOn and nativeTractionBias ~= nil and veh ~= 0 and DoesEntityExist(veh) then
            vl_setHandling(veh, 'fTractionBiasFront', nativeTractionBias)
        end
        biasCenterOn, biasCenterCur = false, nil
        if HK and HK.hdbgOn then HK.dbgBiasCenter = nil end
        return
    end

    local kmh = state.speedKmh or 0.0
    -- A cornering tool owns the field this frame if any bias flag is set OR AWD is
    -- running a non-native under-bias. Also stand down if actually cornering
    -- (steer / yaw / lateral) — centering is a straight-line-cruise-only tool.
    local toolOwns = doPlantBiasOn or fwPlantOn or tcGovBiasOn or pwrSaveBiasOn
        or (awdUnderBias ~= nil and math.abs((awdUnderBias or 0.0) - (nativeTractionBias or 0.0)) > 0.0005)
        or (fwUnderBias ~= nil)
    local steer   = math.abs(state.steer or 0.0)
    local yaw     = math.abs(state.yawRate or 0.0)
    local straight = steer < 0.06 and yaw < 0.15

    if toolOwns or not straight or kmh < (dcfg.SpeedLoKmh or 140.0) then
        -- Not our frame: restore native if we had shifted, and clear.
        if biasCenterOn and veh ~= 0 and DoesEntityExist(veh) then
            vl_setHandling(veh, 'fTractionBiasFront', nativeTractionBias)
        end
        biasCenterOn, biasCenterCur = false, nil
        if HK and HK.hdbgOn then HK.dbgBiasCenter = nil end
        return
    end

    -- Speed-scaled nudge toward 0.5. Only shift if the car is actually off-center.
    local frac  = lerpClamp(kmh, dcfg.SpeedLoKmh or 140.0, dcfg.SpeedFullKmh or 300.0, 0.0, 1.0)
    local maxN  = dcfg.MaxNudge or 0.003
    local off   = 0.5 - nativeTractionBias                 -- >0 = car is rear-biased, pull up toward 0.5
    local nudge = off
    if nudge >  maxN then nudge =  maxN elseif nudge < -maxN then nudge = -maxN end
    local target = nativeTractionBias + nudge * frac

    -- Smooth toward the target so the transition in/out of centering isn't a step.
    local cur = biasCenterCur or nativeTractionBias
    cur = cur + (target - cur) * 0.10
    biasCenterCur = cur
    vl_setHandling(veh, 'fTractionBiasFront', cur)
    biasCenterOn = true

    if HK and HK.hdbgOn then
        HK.dbgBiasCenter = { native = nativeTractionBias, applied = cur, frac = frac, at = GetGameTimer() }
    end
end

-----------------------------------------------------------------
-- TC-OFF PROACTIVE GRIP DROP — reduces peak driven-grip (fTractionCurveMax) under throttle while TC is
-- off, so the toggle is FELT the instant you plant the gas (car breaks loose / steps out on its own)
-- instead of only changing how the reactive tools respond to slip that may never occur. Always-present,
-- throttle- and speed-scaled, smooth in/out. SINGLE writer of fTractionCurveMax outside drift → restore
-- to native (restoreField) the moment TC goes back on / you lift / airborne. `on` = HK.dtTCOff.on.
-----------------------------------------------------------------
-- Restore the TC-off grip fields to native on a given vehicle. Exposed as _G.TCOff_GripRestore so
-- drift.lua can call it at drift ENTRY: GripDrop shares fTractionCurveMin/fLowSpeedTractionLossMult
-- with drift, and Drivetrain_Tick (where GripTick lives) is skipped during drift — so without this,
-- flicking into drift while grip was dropped would leave the fields scaled and drift would bank the
-- SCALED value as its entry baseline. Restoring first hands drift the true native.
function TCOff_GripRestore(veh)
    -- GRIP-FIELD ARBITER (2026-08-16): drop our claim (committer restores when no one claims). Only direct-
    -- restore if the arbiter is OFF (kill switch) and we actually wrote the fields ourselves.
    if HK and HK.gripRelease then HK.gripRelease('tcoff') end
    local arbiterOn = (Config.GripArbiter and Config.GripArbiter.Enabled ~= false)
    if tcOffGripOn and not arbiterOn and veh and veh ~= 0 and DoesEntityExist(veh) then
        vl_restoreField(veh, 'fTractionCurveMax')
        vl_restoreField(veh, 'fTractionCurveMin')
        vl_restoreField(veh, 'fLowSpeedTractionLossMult')
    end
    tcOffGripOn = false
    tcOffGripF  = 0.0
end
_G.TCOff_GripRestore = TCOff_GripRestore

function TCOff_GripTick(veh, state, dt, gcfg, on)
    local function restore() TCOff_GripRestore(veh) end
    if not on or not gcfg or gcfg.Enabled == false then restore(); return end
    -- HANDOFF: launch-traction owns the launch window (it scales the same three traction fields). While
    -- it's actively commanding spin, stand down so we don't double-scale native grip. It hands the frame
    -- back the moment its spin taper ends (grip has "returned"), and we take over for the rest of the run.
    if HK.launchTractionActive == true then restore(); return end

    local kmh = state.speedKmh or 0.0
    local thr = state.effThrottle or state.throttle or 0.0
    local airborne = (state.onAllWheels == false)

    -- Demand: throttle past the gate × speed fade. No throttle / airborne = relax to native. Speed no
    -- longer fades to ZERO — it tapers to HighSpeedFloor so a fast corner-exit stab still steps out.
    local demand = 0.0
    if not airborne and thr >= (gcfg.ThrottleGate or 0.30) then
        local thrF = lerpClamp(thr, gcfg.ThrottleGate or 0.30, gcfg.ThrottleFull or 0.80, 0.0, 1.0)
        local floor = gcfg.HighSpeedFloor or 0.45
        local spdF = lerpClamp(kmh, gcfg.SpeedLowKmh or 5.0, gcfg.SpeedHighKmh or 200.0, 1.0, floor)
        demand = thrF * spdF
    end

    local tau = (demand > tcOffGripF) and (gcfg.EngageTau or 0.09) or (gcfg.ReleaseTau or 0.13)
    tcOffGripF = tcOffGripF + (demand - tcOffGripF) * (1.0 - math.exp(-dt / tau))
    if tcOffGripF < 0.01 then restore(); return end

    -- Shift THREE grip fields from native (scaleHandling captures native once, always scales FROM it, so
    -- writing every frame is safe — no compounding). LOWER curve max/min = the driven axle breaks loose
    -- sooner; HIGHER low-speed-loss = the wheels fry off the line. Restored via restoreField above.
    local maxMult  = 1.0 - (gcfg.MaxReduction or 0.22) * tcOffGripF        -- peak grip down
    local minMult  = 1.0 - (gcfg.MinReduction or 0.34) * tcOffGripF        -- breakaway grip down (biggest tell)
    local spinMult = 1.0 + (gcfg.LowSpeedSpinAdd or 0.60) * tcOffGripF     -- launch/exit wheelspin up
    -- GRIP-FIELD ARBITER (2026-08-16): CLAIM (lowest wheelspin priority — launch/burnout out-rank it, which
    -- matches the old explicit handoff: this stood down while launch was active). Kill-switch → direct write.
    if Config.GripArbiter and Config.GripArbiter.Enabled ~= false and HK.gripClaim then
        HK.gripClaim('tcoff', (HK.GRIP_PRIO and HK.GRIP_PRIO.tcoff) or 20,
                     { max = maxMult, min = minMult, low = spinMult })
    else
        vl_scaleHandling(veh, 'fTractionCurveMax', maxMult)
        vl_scaleHandling(veh, 'fTractionCurveMin', minMult)
        vl_scaleHandling(veh, 'fLowSpeedTractionLossMult', spinMult)
    end
    tcOffGripOn = true
    HK.dbgTCOffGrip = { f = tcOffGripF, mx = maxMult, mn = minMult, sp = spinMult, at = GetGameTimer() }
end

-----------------------------------------------------------------
-- HANDBRAKE-RELEASE CUSHION (2026-08-14) — ALL DRIVETRAINS.
-- The moment the handbrake is released, GTA re-grips the (locked) rear wheels in a single frame.
-- That instantaneous re-grip is a velocity DISCONTINUITY: it dumps forward momentum (the car "snaps
-- to a stop too fast") and, if the tail was out at all, converts the leftover lateral velocity into a
-- YAW kick ("spins in a weird way"). This is the same native velocity-dump family as the airborne-
-- landing and hard-downshift re-grip the user has reported repeatedly.
--
-- FIX = for a short window after the release, SOFTEN the snap by:
--   (1) DECEL CAP — if the car is losing speed faster than MaxDecelMs2, ADD BACK the excess forward
--       speed the re-grip stole (blessed mass-independent SetEntityVelocity increment, horizontal-
--       projected so a pitched nose can't inject vertical velocity). This only ever RESTORES speed the
--       snap removed — it can never push the car FASTER than it was going, so it can't launch anything.
--   (2) YAW + LATERAL BLEED — scale down the leftover yaw rate and sideways velocity so the re-grip
--       can't whip the car into a spin. Sign-safe: both only ever SHRINK the existing transient.
-- The whole cushion FADES OUT as speed drops to HALF the release speed (user: "scale it off slower for
-- at least half the speed") and hard-ends by CushionMs. Skipped under foot brake (a real stop the
-- driver asked for) and while airborne (no grip to snap).
-----------------------------------------------------------------
local function HandbrakeReleaseCushion_Tick(veh, state, dt)
    local hcfg = Config.Drivetrain and Config.Drivetrain.HandbrakeRelease
    if not hcfg or hcfg.Enabled == false then hbrPrevHeld = state.handbrake == true; return end

    local now = GetGameTimer()
    local held = (state.handbrake == true) or ((state.handbrake or 0) == 1)
    local kmh  = state.speedKmh or 0.0
    local spd  = math.sqrt((state.velocity and state.velocity.x or 0.0)^2
                         + (state.velocity and state.velocity.y or 0.0)^2)

    -- RELEASE EDGE: was held last frame, not held now → open the cushion window, remember the speed.
    if hbrPrevHeld and not held then
        if kmh >= (hcfg.MinReleaseKmh or 15.0) and state.onAllWheels ~= false then
            hbrReleaseAt  = now
            hbrReleaseKmh = kmh
        end
    end
    hbrPrevHeld = held
    local prevSpeed = hbrPrevSpeed
    hbrPrevSpeed = spd

    -- Only run inside an open window, off the foot brake, grounded, still moving.
    if hbrReleaseAt == 0 then return end
    local elapsed = now - hbrReleaseAt
    if elapsed > (hcfg.CushionMs or 900) or held or (state.brake or 0.0) > (hcfg.BrakeCancel or 0.4)
       or state.onAllWheels == false or kmh < 1.0 then
        hbrReleaseAt = 0
        return
    end

    -- FADE: full at release → 0 once speed has fallen to half the release speed (or the window ends).
    -- halfKmh = releaseKmh/2; strength = (kmh-halfKmh)/(releaseKmh-halfKmh), clamped, so it eases off
    -- exactly across the top half of the speed the car had when you let go.
    local halfKmh = hbrReleaseKmh * (hcfg.FadeToFrac or 0.5)
    local span    = hbrReleaseKmh - halfKmh
    local strength = span > 0.001 and ((kmh - halfKmh) / span) or 0.0
    if strength < 0.0 then strength = 0.0 elseif strength > 1.0 then strength = 1.0 end
    -- also fade over the window itself so it never lingers if speed plateaus
    local tWin = 1.0 - (elapsed / (hcfg.CushionMs or 900))
    if tWin < 0.0 then tWin = 0.0 end
    strength = strength * tWin
    if strength <= 0.001 then return end

    -- (1) DECEL CAP — restore the excess forward speed the re-grip stole this frame.
    if dt > 0.0 and prevSpeed > 0.0 then
        local decel = (prevSpeed - spd) / dt                      -- m/s² this frame (positive = slowing)
        local maxDecel = (hcfg.MaxDecelMs2 or 7.0)
        if decel > maxDecel then
            local give = (decel - maxDecel) * dt * strength       -- m/s of speed to add back
            local fwd = GetEntityForwardVector(veh)
            local hmag = math.sqrt(fwd.x*fwd.x + fwd.y*fwd.y)
            if hmag >= 0.001 and give > 0.0 then
                local hx, hy = fwd.x / hmag, fwd.y / hmag
                local vel = state.velocity
                SetEntityVelocity(veh, vel.x + hx * give, vel.y + hy * give, vel.z)
                hbrPrevSpeed = spd + give                          -- reflect the add in next frame's baseline
            end
        end
    end

    -- (2) YAW + LATERAL BLEED — sign-safe scale-down of the spin/slide transient so the re-grip can't
    -- whip the car around. Yaw uses the flip-proof applyYawScale (local yaw-rate reduce only); lateral
    -- reuses the only-ever-shrink velocity trick. Damp scales with strength (eases off with the fade).
    local yawScale = 1.0 - (1.0 - (hcfg.YawDampScale or 0.85)) * strength
    applyYawScale(veh, yawScale)

    local lat = state.lateralSpeed or 0.0
    if math.abs(lat) > (hcfg.MinLatMs or 0.5) then
        local latScale = 1.0 - (1.0 - (hcfg.LatDampScale or 0.9)) * strength
        local fwd = GetEntityForwardVector(veh)
        local rx, ry = fwd.y, -fwd.x                              -- horizontal right vector
        local rmag = math.sqrt(rx*rx + ry*ry)
        if rmag > 0.001 then
            rx, ry = rx / rmag, ry / rmag
            local delta = lat * (latScale - 1.0)                  -- negative = only shrinks |lat|
            local vel = state.velocity
            SetEntityVelocity(veh, vel.x + rx * delta, vel.y + ry * delta, vel.z)
        end
    end
end

-----------------------------------------------------------------
-- MAIN DISPATCHER: classify once per vehicle, route to the right branch.
-- Called from main.lua every frame while NOT in drift mode.
-----------------------------------------------------------------
function Drivetrain_Tick(veh, state, dt)
    local cfg = Config.Drivetrain
    if not cfg or not cfg.Enabled then return end

    -- WEIGHT-TRANSFER SPINE: compute the shared load FIRST so any consumer (added later) reads THIS
    -- frame's value. Additive/read-only for now — publishes HK.load + overlay, no tool consumes it yet.
    WeightTransfer_Tick(veh, state, dt, cfg.WeightTransfer)

    -- HANDBRAKE-RELEASE CUSHION — class-agnostic, runs every frame for EVERY drivetrain. Softens the
    -- native re-grip snap when the handbrake is let go (over-fast decel + spin). Self-gates internally.
    HandbrakeReleaseCushion_Tick(veh, state, dt)

    -- TC-OFF SNAPSHOT: resolve the per-frame TC-off state ONCE into HK.dtTCOff so every drivetrain tool
    -- reads one consistent flag (instead of each re-reading HK.tcOff + the config). `.on` is true only
    -- when the feature is enabled AND the player has TC switched off AND TC is even armed (mode>0 /
    -- Config.TractionControl.Enabled) — if TC wasn't doing anything anyway, "off" changes nothing.
    do
        local tcfg = cfg.TCOff
        local tcArmed = Config.TractionControl and Config.TractionControl.Enabled and (HK.tcMode or 0) > 0
        local on = tcfg and tcfg.Enabled and HK.tcOff == true and tcArmed
        HK.dtTCOff = HK.dtTCOff or {}
        local to = HK.dtTCOff
        to.on        = on == true
        to.standDown = tcfg and tcfg.StabilityStandDown or 0.70
        to.charBoost = (on and tcfg and tcfg.CharacterBoost) or 1.0
        to.rwdFree   = tcfg and tcfg.RwdOversteerFree ~= false
        to.fwdSpinFree = tcfg and tcfg.FwdSpinFree ~= false
        to.awdGovMul = 1.0 - ((tcfg and tcfg.AwdGovernorEase or 0.0))
    end

    -- PROACTIVE TC-OFF GRIP DROP — always-present grip reduction under throttle while TC is off, so the
    -- toggle is FELT immediately (not just when slip already exists). Runs here (every frame, any class).
    TCOff_GripTick(veh, state, dt, cfg.TCOff and cfg.TCOff.GripDrop, HK.dtTCOff and HK.dtTCOff.on)

    -- Capture + classify once per vehicle
    if trackedVeh ~= veh then
        -- Restore the PREVIOUS vehicle's rear-steer flag before we retarget (main.lua only calls
        -- Drivetrain_Reset when leaving a vehicle entirely, not on a direct car→car swap; without
        -- this a low-speed swap would leave the old entity with the bit cleared).
        if rearSteerCapable and rearSteerNative ~= nil and trackedVeh ~= 0 and DoesEntityExist(trackedVeh) then
            SetVehicleHandlingInt(trackedVeh, 'CHandlingData', 'strHandlingFlags', rearSteerNative)
        end
        trackedVeh = veh
        nativeFrontBias = vl_getHandling(veh, 'fDriveBiasFront') or 0.0
        nativeTractionBias = vl_getHandling(veh, 'fTractionBiasFront') or 0.5
        nativeSteerLock = vl_getHandling(veh, 'fSteeringLock')
        driveClass = classify(nativeFrontBias)
        awdFactor = 0.0
        awdUnderBias = nativeFrontBias
        awdSteerAngle = nil      -- resync the rate-limited steer angle for the new vehicle
        fwSportDiff = nil        -- recompute LSD/sport-diff membership for the new car (lazy, on first FWD tick)

        -- REAR-STEER capture (2026-08-11): read the native strHandlingFlags (INT) and note whether
        -- this car carries HF_STEER_ALL_WHEELS. The first RearSteer_Tick then applies fresh from the
        -- current speed.
        rearSteerNative = GetVehicleHandlingInt(veh, 'CHandlingData', 'strHandlingFlags')
        rearSteerCapable = (rearSteerNative & REARSTEER_BIT) ~= 0
        rearSteerOn = rearSteerCapable and true or nil   -- native state = bit set (in-phase) when capable
    end

    -- DEBUG: publish the resolved class + native bias so the overlay shows what branch is even eligible
    -- (if a "GTR" classifies RWD, AWD_Understeer never runs — that alone would explain "AWD help gone").
    HK.dbgDrive = HK.dbgDrive or {}
    HK.dbgDrive.class = driveClass
    HK.dbgDrive.nativeBias = nativeFrontBias

    -- Rear-wheel-steer speed gate — runs for ANY car that carries the 4WS flag,
    -- independent of RWD/AWD/FWD classification (self-gates on rearSteerCapable).
    RearSteer_Tick(veh, state, dt, cfg.RearSteer)
    -- Publish 4WS state to the shared drive block (shown for every class since it's class-agnostic).
    HK.dbgDrive.rearSteerCapable = rearSteerCapable == true
    HK.dbgDrive.rearSteerOn = rearSteerOn == true

    if driveClass == CLASS_RWD then
        if cfg.RWD and cfg.RWD.Enabled then
            -- LEGACY fake-AWD assist — retired by default (see config LegacyAssist). Kept one toggle
            -- away in case a real build ever feels worse.
            if cfg.RWD.LegacyAssist then
                RWD_WheelspinAssist(veh, state, dt, cfg.RWD)
            end
            -- Real RWD model. #1: progressive power-oversteer (feather the snap, keep the slide).
            RWD_ProgressiveOversteer(veh, state, dt, cfg.RWD.ProgressiveOversteer)
            -- #2: counter-steer reward (catch a slide with correct lock → it hooks up; skill in).
            RWD_CounterSteerReward(veh, state, dt, cfg.RWD.CounterSteerReward)
            -- #3: lift-off / throttle rotation (lift mid-corner → the tail rotates in; tail-happy).
            RWD_LiftRotation(veh, state, dt, cfg.RWD.LiftRotation)
            -- Spin softener: slow the yaw RATE of a real slide so it's catchable (tames GTA's snap).
            RWD_SpinSoftener(veh, state, dt, cfg.RWD.SpinSoftener)
            -- #4: corner-exit drive-out + throttle-steer (moderate gas plants, high gas rotates) — the
            -- throttle-as-steering "soul". Throttle-exclusive with #3 (lift ≤0.25 vs power ≥0.30/0.70).
            RWD_DriveOut(veh, state, dt, cfg.RWD.DriveOut)
            -- WEIGHT-TRANSFER MIRRORS (2026-08-14, HK.load consumers, LIVE + confirmed):
            -- brake-rotation (trail-brake unloads the rear → the tail steps out — the missing partner to
            -- the lift rotation) then power-spin (open-diff inside-rear breaks loose under power). Run
            -- AFTER the tuned tools so they layer on top; both use the shared capped inner-rear brake path.
            RWD_BrakeRotation(veh, state, dt, cfg.RWD.BrakeRotation)
            RWD_PowerSpin(veh, state, dt, cfg.RWD.PowerSpin)
            -- Publish the live RWD engagement factors for /handlingdbg (all module-locals — one write).
            HK.dbgRwd = HK.dbgRwd or {}
            local r = HK.dbgRwd
            r.po = poFactor; r.cs = csFactor; r.lift = lrFactor; r.spin = rwdSpinFactor
            r.plant = doPlantFactor; r.rot = doRotFactor; r.legacy = awdFactor
            r.brake = rbrFactor; r.pspin = rpsFactor; r.at = GetGameTimer()
        end
    elseif driveClass == CLASS_AWD then
        if cfg.AWD then
            AWD_Understeer(veh, state, dt, cfg.AWD)
            -- Corner-exit traction governor runs AFTER understeer so it layers its forward bias
            -- shift on top of the understeer-managed value (awdUnderBias), rather than fighting it.
            AWD_TractionGovernor(veh, state, dt, cfg.AWD.TractionGovernor, awdUnderBias)
            -- Power-out save runs AFTER the governor and reads the live fDriveBiasFront as its base,
            -- so it layers cleanly on top of whatever understeer/governor set this frame.
            AWD_PowerSave(veh, state, dt, cfg.AWD.PowerSave)
            -- Extreme-slip spin softener: slows the RATE of the final spin past the furthest angle so
            -- there's a catchable window. Fades out with throttle (hands off to PowerSave above), so
            -- it only really acts off-gas. Runs after the bias tools since it's a yaw-rate write.
            AWD_SpinSoftener(veh, state, dt, cfg.AWD.SpinSoftener)
            -- Torque vectoring: brake the inner-rear under power to rotate the car toward the apex.
            -- Independent of the bias tools (it's a per-wheel brake, not a drive-bias write).
            AWD_TorqueVector(veh, state, dt, cfg.AWD.TorqueVector)
            -- Off-throttle balance: the lift-off mirror — tuck-in when understeering, calm when the
            -- rear steps out. Runs AFTER TorqueVector and takes its factor so tuck yields the shared
            -- inner-rear wheel while TV still holds it (throttle-release tail).
            AWD_LiftBalance(veh, state, dt, cfg.AWD.LiftBalance, tvFactor)
            AWD_HandbrakeAssist(veh, state, dt, cfg.AWD.HandbrakeAssist)
            AWD_SteerLimit(veh, state, dt, cfg.AWD.SteerLimit)
            -- Publish EVERY AWD sub-tool engagement for /handlingdbg (AWD_Understeer already writes
            -- HK.dbgAwd.{factor,bias,native} above; the rest of the arsenal is added here so the
            -- overlay can show each tool armed/waiting even when it isn't firing).
            HK.dbgAwd = HK.dbgAwd or {}
            HK.dbgAwd.tv       = tvFactor
            HK.dbgAwd.hb       = awdHbActive == true
            HK.dbgAwd.gov      = tcGovFactor
            HK.dbgAwd.save     = pwrSaveFactor
            HK.dbgAwd.spinsoft = spinSoftFactor
            HK.dbgAwd.lift     = lbTuckFactor
            HK.dbgAwd.steerlim = (awdSteerAngle ~= nil)
            HK.dbgAwd.at       = GetGameTimer()
        end
    elseif driveClass == CLASS_FWD then
        if cfg.FWD and cfg.FWD.Enabled then
            FWD_Handling(veh, state, dt, cfg.FWD)
        end
    end

    -- HIGH-SPEED BIAS CENTERING — runs LAST so it can see whether any branch tool
    -- claimed fTractionBiasFront this frame (it stands down if so). Pairs with the
    -- gravity downforce to stop heavier gravity amplifying understeer/oversteer.
    HighSpeedBiasCenter(veh, state)
end

-- Reset capture when vehicle changes (called from main on exit)
function Drivetrain_Reset()
    -- v17: rate limiter drives no persistent state to restore — just stop tracking the angle
    -- and the game resumes full control of steering immediately.
    awdSteerAngle = nil

    -- v7.19: clear the handbrake pivot+catch latch so a car/seat change doesn't carry a stale pull.
    awdHbActive  = false
    awdHbStartAt = 0

    -- 2026-08-14: clear the handbrake-release cushion window so a car/seat change can't carry a stale
    -- release (which would apply the decel/yaw cushion on the wrong car for the rest of the window).
    hbrPrevHeld   = false
    hbrReleaseAt  = 0
    hbrReleaseKmh = 0.0
    hbrPrevSpeed  = 0.0

    -- v7.20: clear the corner-exit traction governor so a car/seat change doesn't carry stale spin.
    tcGovFactor = 0.0
    tcGovBiasOn = false

    -- v7.21: clear the power-out save state too.
    pwrSaveFactor = 0.0
    pwrSaveBiasOn = false
    pwrSaveLastAdd = 0.0

    -- 2026-08-13: clear the extreme-slip spin softener.
    spinSoftFactor = 0.0

    -- 2026-08-14: clear ABS-off engagement so a car/seat change doesn't carry a stale plow/penalty.
    absOffSteerF = 0.0
    absOffStopF  = 0.0
    HK.absOffBrakeMult = 1.0

    -- 2026-08-14: restore the TC-off grip drop to native on the OLD vehicle before it's untracked, so a
    -- car swap while it was engaged doesn't leave the previous car with shifted grip fields.
    if tcOffGripOn and trackedVeh ~= 0 and DoesEntityExist(trackedVeh) then
        vl_restoreField(trackedVeh, 'fTractionCurveMax')
        vl_restoreField(trackedVeh, 'fTractionCurveMin')
        vl_restoreField(trackedVeh, 'fLowSpeedTractionLossMult')
    end
    tcOffGripOn = false
    tcOffGripF  = 0.0

    -- 2026-08-13: clear torque vectoring + lift-balance tuck-in. Release any braked wheel first
    -- (native self-clears if we stop applying, but be explicit on a car swap so nothing lingers).
    if trackedVeh ~= 0 and DoesEntityExist(trackedVeh) then
        if tvBrakedWheel ~= nil then vl_brakeWheel(trackedVeh, tvBrakedWheel, 0.0) end
        if lbTuckWheel ~= nil and lbTuckWheel ~= tvBrakedWheel then vl_brakeWheel(trackedVeh, lbTuckWheel, 0.0) end
    end
    tvBrakedWheel = nil
    tvFactor = 0.0
    lbTuckWheel = nil
    lbTuckFactor = 0.0

    -- WEIGHT-TRANSFER (2026-08-14): reset the load spine so a fresh entry doesn't spike a fake dv/dt
    -- accel from the last car's speed. Neutral rest state (0 long/lat, 0.5/0.5 axle split).
    wtVeh = 0
    wtPrevFwd = 0.0
    wtLongAccel = 0.0
    wtLong = 0.0; wtLat = 0.0; wtFront = 0.5; wtRear = 0.5; wtSlipDeg = 0.0
    if HK.load then
        HK.load.long = 0.0; HK.load.lat = 0.0; HK.load.front = 0.5; HK.load.rear = 0.5
        HK.load.accel = 0.0; HK.load.slipDeg = 0.0
    end

    -- REAR-STEER (2026-08-11): restore the native strHandlingFlags (INT) if we ever cleared the
    -- 4WS bit — hk-vehlib's float-only restore can't do this, so we own it. Guard the entity still
    -- exists (exit-on-despawn).
    if rearSteerCapable and rearSteerNative ~= nil and trackedVeh ~= 0 and DoesEntityExist(trackedVeh) then
        SetVehicleHandlingInt(trackedVeh, 'CHandlingData', 'strHandlingFlags', rearSteerNative)
    end
    rearSteerCapable = false
    rearSteerNative = nil
    rearSteerOn = nil

    -- #4 drive-out: restore traction bias if the plant left fTractionBiasFront shifted. MUST run
    -- BEFORE trackedVeh / nativeTractionBias are cleared below (else the guards fail). Brake pressure
    -- is non-latching so it self-clears — no explicit wheel release needed on swap.
    if doPlantBiasOn and nativeTractionBias ~= nil and trackedVeh ~= 0 and DoesEntityExist(trackedVeh) then
        vl_setHandling(trackedVeh, 'fTractionBiasFront', nativeTractionBias)
    end

    -- High-speed bias centering: restore native if we left it nudged (same guard timing).
    if biasCenterOn and nativeTractionBias ~= nil and trackedVeh ~= 0 and DoesEntityExist(trackedVeh) then
        vl_setHandling(trackedVeh, 'fTractionBiasFront', nativeTractionBias)
    end
    biasCenterOn, biasCenterCur = false, nil

    -- FWD (2026-08-14): restore both bias fields if our tools shifted them, and release any braked
    -- front/rear wheel. MUST run BEFORE trackedVeh / native* are cleared below (else the guards fail).
    if trackedVeh ~= 0 and DoesEntityExist(trackedVeh) then
        if fwUnderBias and nativeFrontBias ~= nil and math.abs(fwUnderBias - nativeFrontBias) > 0.001 then
            vl_setHandling(trackedVeh, 'fDriveBiasFront', nativeFrontBias)
        end
        if fwPlantOn and nativeTractionBias ~= nil then
            vl_setHandling(trackedVeh, 'fTractionBiasFront', nativeTractionBias)
        end
        if fwLiftWheel ~= nil then vl_brakeWheel(trackedVeh, fwLiftWheel, 0.0) end
        if fwTsWheel ~= nil then vl_brakeWheel(trackedVeh, fwTsWheel, 0.0) end
        -- JDM pack: release the sport-diff inside-front brake and restore the steering lock if
        -- FWD_BrakeUndersteer had it cut. (SpinPenalty is non-latching torque — self-clears.)
        if fwSdWheel ~= nil then vl_brakeWheel(trackedVeh, fwSdWheel, 0.0) end
        if fwBrakeUsFactor > 0.001 and nativeSteerLock ~= nil then
            vl_setHandling(trackedVeh, 'fSteeringLock', nativeSteerLock)
        end
    end
    fwUnderBias = nil; fwUnderSettle = 0
    fwLiftFactor = 0.0; fwLiftWheel = nil
    fwPlantFactor = 0.0; fwPlantOn = false
    fwTsFactor = 0.0; fwTsWheel = nil
    fwSportDiff = nil; fwSdFactor = 0.0; fwSdWheel = nil
    fwSpinCut = 0.0; fwBrakeUsFactor = 0.0
    fwSpinSoft = 0.0; fwStraightFactor = 0.0
    nativeSteerLock = nil

    trackedVeh = 0
    driveClass = nil
    nativeFrontBias = nil
    nativeTractionBias = nil
    awdFactor = 0.0
    awdUnderBias = nil
    awdBumpUntil = 0
    awdBumpReactAt = 0
    awdLandCorrectAt = 0
    awdWasAirborne = false

    -- 2026-08-13: clear RWD progressive-oversteer + counter-steer-reward + lift-rotation state.
    -- (Inner-rear brake pressure is non-latching — it self-clears once we stop applying — so no
    -- explicit wheel release is needed on a car swap; just zero the trackers.)
    poPrevSlip = 0.0
    poFactor = 0.0
    csFactor = 0.0
    lrBrakedWheel = nil
    lrFactor = 0.0
    rwdSpinFactor = 0.0

    -- #4 drive-out state clear (the bias restore already ran above, before trackedVeh was cleared).
    doRotWheel = nil
    doRotFactor = 0.0
    doPlantFactor = 0.0
    doPlantBiasOn = false

    -- RWD weight-transfer mirrors (2026-08-14): release any braked inner-rear + clear factors on swap.
    -- Explicit release (like TorqueVector above) so nothing lingers, though pressure is non-latching.
    if trackedVeh ~= 0 and DoesEntityExist(trackedVeh) then
        if rbrWheel ~= nil then vl_brakeWheel(trackedVeh, rbrWheel, 0.0) end
        if rpsWheel ~= nil and rpsWheel ~= rbrWheel then vl_brakeWheel(trackedVeh, rpsWheel, 0.0) end
    end
    rbrWheel = nil; rbrFactor = 0.0
    rpsWheel = nil; rpsFactor = 0.0
    awdPrevVelZ = 0.0
    awdPrevKmh = 0.0
    awdLandSettleUntil = 0
    awdReacting = false
    awdReactUntil = 0
end

-----------------------------------------------------------------
-- DRIVETRAIN DETECTION EXPORT (2026-08-14) — for hk-parking + future consumers.
-- Returns BOTH facts, because two different questions exist and they use different thresholds:
--   * layout  = the TRUE drivetrain label a human would say ('RWD'/'AWD'/'FWD'), 0.10/0.90 cut.
--   * class   = the HANDLING-ROUTING class hk-handling actually runs ('rwd'/'awd'/'fwd'), 0.49/0.61
--               cut — a bias-0.7 car reads layout=FWD AND class=fwd, but a 0.55 car is layout=AWD
--               while class=awd too; the bands only diverge in the 0.10-0.49 / 0.61-0.90 grey zones.
-- Reads the car's NATIVE bias (live handling float) so a momentary AWD-assist bias shift can't flip
-- the answer. Pass a veh handle; defaults to the local player's current vehicle. nil if no vehicle.
-- Example: exports['hk-handling']:GetDriveClass()  ->  { layout='FWD', class='fwd', bias=0.70 }
local function labelFromBias(bias)
    return (bias < 0.10) and 'RWD' or (bias > 0.90) and 'FWD' or 'AWD'
end
exports('GetDriveClass', function(veh)
    if not veh or veh == 0 then
        local ped = PlayerPedId()
        veh = GetVehiclePedIsIn(ped, false)
    end
    if not veh or veh == 0 or not DoesEntityExist(veh) then return nil end
    -- LAND VEHICLES ONLY: a drivetrain (RWD/AWD/FWD) is meaningless on a boat/heli/plane/train, so
    -- return nil for them — hk-speedo treats nil as "no drivetrain badge", so the pill stays hidden.
    -- Gate by EXCLUDING the non-land GetVehicleClass ids (14 boat, 15 heli, 16 plane, 21 train) rather
    -- than IsThisModelACar (which also drops bikes/quads — those ARE land vehicles and keep a pill).
    local vclass = GetVehicleClass(veh)
    if vclass == 14 or vclass == 15 or vclass == 16 or vclass == 21 then return nil end
    -- If it's the car we're actively running, we already captured native bias — use it (immune to
    -- our own live fDriveBiasFront shifts). Otherwise read the live handling float directly.
    local bias
    if veh == trackedVeh and nativeFrontBias ~= nil then
        bias = nativeFrontBias
    else
        bias = vl_getHandling(veh, 'fDriveBiasFront') or 0.5
    end
    return { layout = labelFromBias(bias), class = classify(bias), bias = bias }
end)

-- /sportdiff [on|off|auto] — force the LSD/sport-diff hook on the current car for testing. 'auto'
-- clears the override and falls back to the tuned fDriveBiasFront threshold (SportDiffBias).
RegisterCommand('sportdiff', function(_, args)
    local a = string.lower(args[1] or '')
    if a == 'on' or a == '1' or a == 'true' then
        HK.fwSportDiffOverride = true
    elseif a == 'off' or a == '0' or a == 'false' then
        HK.fwSportDiffOverride = false
    else
        HK.fwSportDiffOverride = nil
    end
    fwSportDiff = nil   -- force re-resolve on next FWD tick
    local msg = (HK.fwSportDiffOverride == nil) and 'auto (bias threshold)'
        or (HK.fwSportDiffOverride and 'FORCED ON' or 'FORCED OFF')
    TriggerEvent('chat:addMessage', { args = { '^3[hk-handling]', 'sport-diff = ' .. msg } })
end, false)
