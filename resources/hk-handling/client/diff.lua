-----------------------------------------------------------------
-- hk-handling :: client/diff.lua
-- [X6] Differential Simulation — brake-based torque vectoring.
--
-- GTA fakes an OPEN diff: under power the unloaded/inner driven wheel
-- spins free and steals torque from the gripping wheel. Real cars run an
-- LSD/locked diff so both driven wheels turn together. We approximate a
-- locked diff by braking the FASTER wheel of a driven axle in proportion
-- to its overspeed vs its pair — pulling the pair back together.
--
-- Detect: left-vs-right wheel-speed delta WITHIN the driven axle.
--   (NOT vs ground speed — that's TC's job and would fight power-on drift.)
-- Act:    SetVehicleWheelBrakePressure on the faster wheel (via vehlib).
-- Gate:   under power only (the native is unreliable off-throttle), above
--         a min speed, and (config) not while the player is braking.
--
-- Runs on whichever axle(s) getDrivenAxles reports as driven, so it works
-- for RWD (rear), FWD (front), and AWD (both) without hardcoding {2,3}.
--
-- VALIDATION GATE: SetVehicleWheelBrakePressure is build-dependent. If the
-- diff feels draggy (energy loss) rather than tightening (torque transfer),
-- lower LockGain. If it does nothing, the native isn't applying on this
-- build — disable Config.Diff and report.
-----------------------------------------------------------------

local vehlib = exports['hk-vehlib']
local function bind(fn) return function(...) return fn(nil, ...) end end
-- Cache export refs once (avoids per-frame wrapper-closure GC churn; see gearbox.lua).
local vl_brakeWheel     = bind(vehlib.brakeWheel)
local vl_getDrivenAxles = bind(vehlib.getDrivenAxles)

-- Wheel indices: 0=FL, 1=FR (front axle) | 2=RL, 3=RR (rear axle)
local FRONT_AXLE = { 0, 1 }
local REAR_AXLE  = { 2, 3 }

local clamp = function(v, lo, hi)
    if v < lo then return lo elseif v > hi then return hi else return v end
end

-- Track which wheels we braked last frame so we can release them when the
-- delta closes (the native does not latch, but being explicit avoids a wheel
-- staying dragged if conditions flip mid-frame).
local brakedWheels = {}

-- Apply the locking brake to one driven axle pair.
local function lockAxle(veh, a, b, preset)
    local wa = math.abs(GetVehicleWheelSpeed(veh, a))
    local wb = math.abs(GetVehicleWheelSpeed(veh, b))
    local delta = wa - wb
    local spd = math.abs(delta)

    if spd <= preset.Deadband then
        -- Pair is together: make sure neither wheel is left braked.
        if brakedWheels[a] then vl_brakeWheel(veh, a, 0.0); brakedWheels[a] = nil end
        if brakedWheels[b] then vl_brakeWheel(veh, b, 0.0); brakedWheels[b] = nil end
        return
    end

    local fast = (delta > 0) and a or b
    local slow = (delta > 0) and b or a
    local pressure = clamp(preset.LockGain * (spd - preset.Deadband), 0.0, preset.MaxPressure)

    vl_brakeWheel(veh, fast, pressure)
    brakedWheels[fast] = true
    -- Release the slower wheel if it was braked on a previous frame
    if brakedWheels[slow] then vl_brakeWheel(veh, slow, 0.0); brakedWheels[slow] = nil end
end

-----------------------------------------------------------------
-- TICK
-----------------------------------------------------------------
function Diff_Tick(veh, state, dt)
    local cfg = Config.Diff

    -- Decide whether the diff should run at all this frame.
    -- Locked preset auto-engages in drift mode; otherwise gentle LSD only
    -- if AlwaysOnLSD is enabled.
    local inDrift = HK.driftMode == true
    if not inDrift and not cfg.AlwaysOnLSD then
        Diff_Release(veh)
        return
    end

    -- Gates
    if state.speedKmh < cfg.MinSpeedKmh or (state.effThrottle or state.throttle) < cfg.MinThrottle then
        Diff_Release(veh)
        return
    end
    if cfg.SkipUnderBraking and state.brake > 0.1 then
        Diff_Release(veh)
        return
    end

    local preset = inDrift and cfg.Locked or cfg.LSD

    -- Run on whichever axle(s) are driven. getDrivenAxles reads
    -- fDriveBiasFront: front=bias>0, rear=bias<1 (AWD = both true).
    local driven = vl_getDrivenAxles(veh)
    local wheelCount = state.wheelCount or GetVehicleNumberOfWheels(veh)
    if wheelCount < 4 then return end  -- bikes / odd layouts: skip

    if driven.rear then
        lockAxle(veh, REAR_AXLE[1], REAR_AXLE[2], preset)
    end
    if driven.front then
        lockAxle(veh, FRONT_AXLE[1], FRONT_AXLE[2], preset)
    end
end

-----------------------------------------------------------------
-- RELEASE: clear any brake pressure we applied (call when diff inactive)
-----------------------------------------------------------------
function Diff_Release(veh)
    if not next(brakedWheels) then return end
    if veh and veh ~= 0 and DoesEntityExist(veh) then
        for wheel, _ in pairs(brakedWheels) do
            vl_brakeWheel(veh, wheel, 0.0)
        end
    end
    brakedWheels = {}
end

-----------------------------------------------------------------
-- RESET: clear module state on vehicle change/exit (CRIT-3 pattern)
-----------------------------------------------------------------
function Diff_Reset()
    brakedWheels = {}
end
