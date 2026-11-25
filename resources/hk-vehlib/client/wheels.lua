-----------------------------------------------------------------
-- hk-vehlib :: client/wheels.lua
-- Per-wheel utilities: speed reading, spin detection, brake
-- application for torque vectoring / LSD simulation.
--
-- Usage:
--   VehLib.getWheelSpeeds(veh) → {[0]=FL, [1]=FR, [2]=RL, [3]=RR}
--   VehLib.brakeWheel(veh, 2, 0.5) -- 50% brake on rear-left
--   VehLib.getSlipRatio(veh) → per-wheel slip ratios
-----------------------------------------------------------------

VehLib = VehLib or {}

local clamp = function(v, lo, hi)
    if v < lo then return lo elseif v > hi then return hi else return v end
end

-----------------------------------------------------------------
-- PUBLIC API
-----------------------------------------------------------------

--- Get per-wheel health values
--- @param veh number
--- @return table {[0]=FL, [1]=FR, [2]=RL, [3]=RR}
function VehLib.getWheelHealth(veh)
    local result = {}
    local count = GetVehicleNumberOfWheels(veh)
    for i = 0, count - 1 do
        result[i] = GetVehicleWheelHealth(veh, i)
    end
    return result
end

--- Set individual wheel health
--- @param veh number
--- @param wheel number (0=FL, 1=FR, 2=RL, 3=RR)
--- @param health number (0.0 = destroyed, 1000.0 = perfect)
function VehLib.setWheelHealth(veh, wheel, health)
    SetVehicleWheelHealth(veh, wheel, clamp(health, 0.0, 1000.0))
end

--- Get slip ratio per wheel (wheel speed vs ground speed).
--- >1.0 = spinning faster than ground (wheelspin)
--- <1.0 = spinning slower than ground (locked/dragging)
--- @param veh number
--- @return table {[0]=ratio, [1]=ratio, ...}
function VehLib.getSlipRatio(veh)
    local groundSpeed = math.max(GetEntitySpeed(veh), 0.1) -- avoid div/0
    local count = GetVehicleNumberOfWheels(veh)
    local result = {}
    for i = 0, count - 1 do
        local ws = math.abs(GetVehicleWheelSpeed(veh, i))
        result[i] = ws / groundSpeed
    end
    return result
end

--- Detect if specific wheels are locked (ABS detection).
--- A wheel is "locked" if the car is moving but the wheel isn't spinning.
--- @param veh number
--- @param speedThreshold number minimum vehicle speed to check (default 5 m/s)
--- @return boolean anyLocked, table lockedWheels {[wheelIndex] = true}
function VehLib.detectLockedWheels(veh, speedThreshold)
    speedThreshold = speedThreshold or 5.0
    local speed = GetEntitySpeed(veh)
    if speed < speedThreshold then return false, {} end

    local count = GetVehicleNumberOfWheels(veh)
    local locked = {}
    local anyLocked = false

    for i = 0, count - 1 do
        local ws = math.abs(GetVehicleWheelSpeed(veh, i))
        -- Wheel is locked if it's barely spinning while car moves
        if ws < (speed * 0.15) then
            locked[i] = true
            anyLocked = true
        end
    end

    return anyLocked, locked
end

--- Apply brake to a specific wheel (for torque vectoring / LSD sim).
--- NOTE: This uses SetVehicleWheelBrakePressure (FiveM CFX native).
--- @param veh number
--- @param wheel number (0-3)
--- @param pressure number (0.0 = no brake, 1.0 = full lock)
function VehLib.brakeWheel(veh, wheel, pressure)
    -- SetVehicleWheelBrakePressure is a CFX native (may not exist on all builds)
    -- Fallback: we can use SetVehicleWheelHealth to simulate drag (destructive)
    if SetVehicleWheelBrakePressure then
        SetVehicleWheelBrakePressure(veh, wheel, clamp(pressure, 0.0, 1.0))
    end
end

--- Get which wheels are driven (powered) based on drive bias.
--- @param veh number
--- @return table {front=bool, rear=bool}
function VehLib.getDrivenAxles(veh)
    local bias = GetVehicleHandlingFloat(veh, 'CHandlingData', 'fDriveBiasFront')
    return {
        front = bias > 0.0,
        rear = bias < 1.0,
    }
end

-----------------------------------------------------------------
-- CATEGORY-A VEHICLE FACTS — static, pure functions of the vehicle (no feature state).
-- Centralised HERE so every consumer (hk-handling, hk-speedo, hk-parking, hk-race) reads
-- ONE implementation instead of each recomputing the same thing. These never change while
-- you're in the car, so consumers pull them ONCE on entry and cache.
-----------------------------------------------------------------

--- Drivetrain layout from the drive-bias handling float (0 = all rear .. 1 = all front).
--- Standard thresholds: <0.10 RWD, >0.90 FWD, else AWD.
--- @param veh number
--- @param biasOverride number|nil pass a KNOWN-native bias (e.g. a captured origin) to avoid
---        a live read that a fake-AWD assist may have shifted; nil = read live.
--- @return table { layout = 'RWD'|'FWD'|'AWD', bias = number }
function VehLib.getDrivetrainLayout(veh, biasOverride)
    local bias = biasOverride
    if bias == nil then
        bias = GetVehicleHandlingFloat(veh, 'CHandlingData', 'fDriveBiasFront')
    end
    bias = bias or 0.5
    local layout = (bias < 0.10) and 'RWD' or (bias > 0.90) and 'FWD' or 'AWD'
    return { layout = layout, bias = bias }
end

--- Is this MODEL flagged electric in its metadata? (matches GetIsVehicleElectric semantics;
--- takes the model hash, not the entity). Pure BEV meta flag — NOT hybrid e-mode state.
--- @param veh number
--- @return boolean
function VehLib.isElectricModel(veh)
    local ok, elec = pcall(GetIsVehicleElectric, GetEntityModel(veh))
    return ok and elec == true
end

--- Vehicle mass (kg) from handling. Guarded against bad/zero reads.
--- @param veh number
--- @return number
function VehLib.getMass(veh)
    local m = GetVehicleHandlingFloat(veh, 'CHandlingData', 'fMass')
    if not m or m < 200.0 then return 1500.0 end
    return m
end

-- Exports
exports('getWheelHealth', VehLib.getWheelHealth)
exports('setWheelHealth', VehLib.setWheelHealth)
exports('getDrivetrainLayout', VehLib.getDrivetrainLayout)
exports('isElectricModel', VehLib.isElectricModel)
exports('getMass', VehLib.getMass)
exports('getSlipRatio', VehLib.getSlipRatio)
exports('detectLockedWheels', VehLib.detectLockedWheels)
exports('brakeWheel', VehLib.brakeWheel)
exports('getDrivenAxles', VehLib.getDrivenAxles)
