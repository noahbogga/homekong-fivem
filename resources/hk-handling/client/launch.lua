-----------------------------------------------------------------
-- hk-handling :: client/launch.lua
-- [A3] Launch Control — stage with throttle+brake, boost off the line
-- [A4] Rev Limiter — hard-cut bounce at redline + neutral rev hold
-----------------------------------------------------------------

local vehlib = exports['hk-vehlib']
local function bind(fn) return function(...) return fn(nil, ...) end end
-- Cache export refs once (avoids per-frame wrapper-closure GC churn; see gearbox.lua).
local vl_setRpm = bind(vehlib.setRpm)

-----------------------------------------------------------------
-- [A3] LAUNCH CONTROL
-- State machine: idle -> staged -> launching -> idle
-----------------------------------------------------------------

-- Launch phases
local PHASE_IDLE   = 0
local PHASE_STAGED = 1
local PHASE_LAUNCH = 2

local phase = PHASE_IDLE
local launchStart = 0       -- gameTimer when launch began
local stagedNotified = false

local function notify(msg)
    SetNotificationTextEntry('STRING')
    AddTextComponentString(msg)
    DrawNotification(false, false)
end

function LaunchControl_Tick(veh, state, dt)
    local cfg = Config.LaunchControl

    -- Conditions for being able to stage
    local stopped     = state.speedKmh <= cfg.StageMaxSpeedKmh
    local onThrottle  = state.throttle >= cfg.StageMinThrottle
    local onBrake     = state.brake >= cfg.StageMinBrake

    if phase == PHASE_IDLE then
        -- Arm staging when stopped, both pedals pressed
        if stopped and onThrottle and onBrake then
            phase = PHASE_STAGED
            if cfg.NotifyOnStage and not stagedNotified then
                notify('~y~LAUNCH CONTROL ~g~STAGED')
                stagedNotified = true
            end
        end

    elseif phase == PHASE_STAGED then
        -- Bail if player lifts throttle entirely or starts rolling fast
        if state.throttle < 0.2 or state.speedKmh > cfg.StageMaxSpeedKmh + 4.0 then
            phase = PHASE_IDLE
            stagedNotified = false
            return
        end

        -- Hold revs at the staged target for that "wound-up" feel
        vl_setRpm(veh, cfg.StagedRpm)

        -- Cap torque so the car doesn't just sit there in a burnout
        HK.torqueMult = HK.torqueMult * cfg.StagedTorqueMult

        -- LAUNCH: brake released while throttle still held
        if state.brake < cfg.StageMinBrake * 0.5 and onThrottle then
            phase = PHASE_LAUNCH
            launchStart = state.gameTimer
            HK.launching = true
        end

    elseif phase == PHASE_LAUNCH then
        local elapsed = state.gameTimer - launchStart

        -- End conditions: time elapsed, lifted throttle, or up to speed
        if elapsed >= cfg.LaunchDurationMs
            or state.throttle < 0.3
            or state.speedKmh >= cfg.LaunchEndSpeedKmh then
            phase = PHASE_IDLE
            stagedNotified = false
            HK.launching = false
            return
        end

        -- Boost tapers over the launch window (1.0 at end -> LaunchBoostMult start)
        local timeT  = 1.0 - (elapsed / cfg.LaunchDurationMs)
        local speedT = 1.0 - math.min(state.speedKmh / cfg.LaunchEndSpeedKmh, 1.0)
        local t = math.min(timeT, speedT)  -- whichever fades first
        local boost = 1.0 + (cfg.LaunchBoostMult - 1.0) * t

        HK.torqueMult = HK.torqueMult * boost
        HK.launching = true
        HK.launchT = t   -- expose ramp value for headlift
    end
end

-----------------------------------------------------------------
-- [A4] REV LIMITER
-----------------------------------------------------------------

local limiterEngaged = false
local flutterPhase = 0.0

function RevLimiter_Tick(veh, state, dt)
    local cfg = Config.RevLimiter
    local rpm = state.rpm
    local gear = state.gear

    -- Neutral rev hold: cap revs when revving in place
    if gear == 0 then
        if cfg.LimitInNeutral and rpm > cfg.NeutralRevCap then
            vl_setRpm(veh, cfg.NeutralRevCap)
        end
        limiterEngaged = false
        return
    end

    -- Only fight the engine under throttle
    if state.throttle < cfg.MinThrottle then
        limiterEngaged = false
        return
    end

    -- Hysteresis: engage at redline, release once dropped below ReengageRpm
    if rpm >= cfg.Redline then
        limiterEngaged = true
    elseif rpm < cfg.ReengageRpm then
        limiterEngaged = false
    end

    if limiterEngaged then
        -- Flutter the cut so it bounces audibly off the limiter
        flutterPhase = flutterPhase + (dt * cfg.FlutterHz * math.pi * 2.0)
        if flutterPhase > math.pi * 2.0 then flutterPhase = flutterPhase - math.pi * 2.0 end

        -- Oscillate between full cut and partial power for the bounce
        local bounce = (math.sin(flutterPhase) > 0.0) and cfg.CutMult or 1.0
        HK.torqueMult = HK.torqueMult * bounce
    end
end
