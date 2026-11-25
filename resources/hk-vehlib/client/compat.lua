-----------------------------------------------------------------
-- hk-vehlib :: client/compat.lua
-- Framework / third-party compatibility bridge.
--
-- Thin, nil-safe wrappers around OTHER resources' exports so every hk
-- script can query them without repeating GetResourceState guards. If the
-- target resource isn't running, every call returns a safe default rather
-- than erroring. Today this covers Jim-Mechanic (manual-gearbox status,
-- nitrous, mileage, harness); extend as new integrations appear.
--
-- Design: NEVER hard-depend on these resources. All checks are runtime.
-----------------------------------------------------------------

VehLib = VehLib or {}

-- Resolve jim's resource name once (it registers as 'Jim-Mechanic').
local JIM = 'Jim-Mechanic'

--- Is a resource started right now?
--- @param name string
--- @return boolean
function VehLib.hasResource(name)
    return GetResourceState(name) == 'started'
end

-----------------------------------------------------------------
-- JIM-MECHANIC
-----------------------------------------------------------------

--- True if Jim-Mechanic is loaded.
function VehLib.hasJimMechanic()
    return VehLib.hasResource(JIM)
end

--- Jim's stored status table for a vehicle (damage parts, manual flag, etc.),
--- or nil if jim absent / no data.
--- @param veh number
--- @return table|nil
function VehLib.jimVehicleStatus(veh)
    if not VehLib.hasResource(JIM) then return nil end
    local ok, status = pcall(function() return exports[JIM]:GetVehicleStatus(veh) end)
    if ok then return status end
    return nil
end

--- Has Jim-Mechanic flagged this vehicle as manual-transmission?
--- (Jim sets status.manual == 1 when the manual upgrade is installed.)
--- This is the authoritative jim-side manual trigger — our gearbox uses it
--- so a jim manual install enables our box exactly like it did vlad's.
--- @param veh number
--- @return boolean
function VehLib.jimIsManual(veh)
    local status = VehLib.jimVehicleStatus(veh)
    return status ~= nil and status.manual == 1
end

--- Jim nitrous level for a vehicle (0 if jim absent / none).
--- @param veh number
--- @return number
function VehLib.jimNosLevel(veh)
    if not VehLib.hasResource(JIM) then return 0 end
    local ok, lvl = pcall(function() return exports[JIM]:GetNosLevel(veh) end)
    if ok and type(lvl) == 'number' then return lvl end
    return 0
end

--- Is the seatbelt harness on (jim), false if jim absent.
--- @return boolean
function VehLib.jimHasHarness()
    if not VehLib.hasResource(JIM) then return false end
    local ok, has = pcall(function() return exports[JIM]:HasHarness() end)
    return ok and has == true
end

-- Exports
exports('hasResource', VehLib.hasResource)
exports('hasJimMechanic', VehLib.hasJimMechanic)
exports('jimVehicleStatus', VehLib.jimVehicleStatus)
exports('jimIsManual', VehLib.jimIsManual)
exports('jimNosLevel', VehLib.jimNosLevel)
exports('jimHasHarness', VehLib.jimHasHarness)
