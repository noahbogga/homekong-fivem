-----------------------------------------------------------------
-- hk-handling :: client/traction.lua
-- [D1] Traction Control — detects wheelspin, cuts torque
-- [D2] ABS — detects locked wheels, pulses brake force
-----------------------------------------------------------------

local vehlib = exports['hk-vehlib']
local function bind(fn) return function(...) return fn(nil, ...) end end
-- Cache export refs once (avoids per-frame wrapper-closure GC churn; see gearbox.lua).
local vl_detectLockedWheels = bind(vehlib.detectLockedWheels)
local vl_detectWheelspin    = bind(vehlib.detectWheelspin)
local vl_scaleHandling      = bind(vehlib.scaleHandling)

-----------------------------------------------------------------
-- TRACTION CONTROL
-----------------------------------------------------------------

function TractionControl_Tick(veh, state, dt)
    local cfg = Config.TractionControl
    if state.speedKmh < cfg.MinSpeedKmh then
        HK.tcFactor = 0.0
        return
    end

    -- Get spin threshold and torque cut based on mode
    local threshold, torqueCut
    if HK.tcMode == 1 then
        threshold = cfg.SpinThresholdLow
        torqueCut = cfg.TorqueCutLow
    else -- mode 2 (High)
        threshold = cfg.SpinThresholdHigh
        torqueCut = cfg.TorqueCutHigh
    end

    -- Detect wheelspin
    local spinning, worstDiff = vl_detectWheelspin(veh, threshold)

    -- Smooth the intervention factor
    local target = spinning and 1.0 or 0.0
    local tau = spinning and cfg.AttackTau or cfg.ReleaseTau
    HK.tcFactor = HK.tcFactor + (target - HK.tcFactor) * (1.0 - math.exp(-dt / tau))

    -- Apply torque reduction (compounds with other systems via HK.torqueMult)
    if HK.tcFactor > 0.01 then
        local mult = 1.0 - (HK.tcFactor * (1.0 - torqueCut))
        HK.torqueMult = HK.torqueMult * mult
    end
end

-----------------------------------------------------------------
-- ABS SIMULATION
-----------------------------------------------------------------

local absPhase = 0.0  -- oscillator phase for pulse

function ABS_Tick(veh, state, dt)
    local cfg = Config.ABS
    if state.speed < cfg.MinSpeed then return end

    -- Only active when braking
    if state.brake < 0.1 then return end

    -- Detect locked wheels
    local anyLocked, _ = vl_detectLockedWheels(veh, cfg.MinSpeed)
    if not anyLocked then return end

    -- ABS pulse: oscillate brake force between full and reduced
    absPhase = absPhase + (dt * cfg.PulseRateHz * math.pi * 2.0)
    if absPhase > math.pi * 2.0 then absPhase = absPhase - math.pi * 2.0 end

    -- Sine wave between reduction and full (0.35 to 1.0)
    local pulse = cfg.BrakeReductionMult + (1.0 - cfg.BrakeReductionMult) * (0.5 + 0.5 * math.sin(absPhase))

    -- Compose the ABS pulse onto the shared brake-force multiplier (the brake model also contributes;
    -- main.lua applies the product to fBrakeForce ONCE). Writing fBrakeForce directly here would clobber
    -- the brake model's scale (scaleHandling sets from ORIGINAL each frame — last writer wins).
    HK.brakeForceMult = (HK.brakeForceMult or 1.0) * pulse
end
