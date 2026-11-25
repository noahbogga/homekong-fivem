-----------------------------------------------------------------
-- hk-vehlib :: client/input.lua
-- Clean input reading utilities. Wraps control natives into a
-- single call that consumer scripts can use without memorizing
-- control IDs.
--
-- Usage: local inp = VehLib.getInput()
--        inp.throttle, inp.brake, inp.steer, inp.handbrake, etc.
-----------------------------------------------------------------

VehLib = VehLib or {}

-- Control ID reference (GTA V / FiveM):
-- 71 = INPUT_VEH_ACCELERATE (W / RT)
-- 72 = INPUT_VEH_BRAKE (S / LT)
-- 59 = INPUT_VEH_MOVE_LR (A/D / Left Stick X)
-- 76 = INPUT_VEH_HANDBRAKE (Space / A button)
-- 74 = INPUT_VEH_HEADLIGHT (H)
-- 73 = INPUT_VEH_DUCK (X)
-- 75 = INPUT_VEH_HORN (E / L3)
-- 80 = INPUT_VEH_CIN_CAM (R / Back)
-- 79 = INPUT_VEH_LOOK_BEHIND (C)

-----------------------------------------------------------------
-- PUBLIC API
-----------------------------------------------------------------

--- Get all vehicle inputs as a clean table
--- @return table {throttle, brake, steer, handbrake, ...}
function VehLib.getInput()
    return {
        throttle   = GetControlNormal(0, 71),          -- 0.0 to 1.0
        brake      = GetControlNormal(0, 72),          -- 0.0 to 1.0
        steer      = GetControlNormal(0, 59),          -- -1.0 to 1.0
        handbrake  = IsControlPressed(0, 76),          -- bool
        horn       = IsControlPressed(0, 75),          -- bool
        headlight  = IsControlJustPressed(0, 74),      -- bool (rising edge)
        duck       = IsControlPressed(0, 73),          -- bool
        lookBehind = IsControlPressed(0, 79),          -- bool
    }
end

--- Check if throttle is above a threshold
--- @param threshold number (default 0.1)
--- @return boolean
function VehLib.isThrottleOn(threshold)
    return GetControlNormal(0, 71) >= (threshold or 0.1)
end

--- Check if brake is above a threshold
--- @param threshold number (default 0.1)
--- @return boolean
function VehLib.isBraking(threshold)
    return GetControlNormal(0, 72) >= (threshold or 0.1)
end

--- Check if handbrake is currently held
--- @return boolean
function VehLib.isHandbrake()
    return IsControlPressed(0, 76)
end

--- Check if steering input is significant
--- @param deadzone number (default 0.1)
--- @return boolean steering, number direction (-1 left, +1 right)
function VehLib.isSteering(deadzone)
    deadzone = deadzone or 0.1
    local s = GetControlNormal(0, 59)
    if math.abs(s) > deadzone then
        return true, s
    end
    return false, 0.0
end

-- Exports
exports('getInput', VehLib.getInput)
exports('isThrottleOn', VehLib.isThrottleOn)
exports('isBraking', VehLib.isBraking)
exports('isHandbrake', VehLib.isHandbrake)
exports('isSteering', VehLib.isSteering)
