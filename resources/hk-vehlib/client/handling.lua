-----------------------------------------------------------------
-- hk-vehlib :: client/handling.lua
-- Safe handling value manipulation with automatic capture/restore.
--
-- Usage:
--   VehLib.setHandling(veh, 'fTractionCurveLateral', 15.0)
--   VehLib.scaleHandling(veh, 'fHandBrakeForce', 0.5)  -- 50% of original
--   VehLib.restoreHandling(veh)  -- restore ALL fields to original
--   VehLib.restoreField(veh, 'fTractionCurveLateral')  -- restore one field
-----------------------------------------------------------------

VehLib = VehLib or {}

-- Storage: originals[veh][field] = captured original value
local originals = {}

-- Capture the original value of a field (once per vehicle per field)
local function captureOriginal(veh, field)
    if not originals[veh] then originals[veh] = {} end
    if originals[veh][field] == nil then
        originals[veh][field] = GetVehicleHandlingFloat(veh, 'CHandlingData', field)
    end
    return originals[veh][field]
end

-----------------------------------------------------------------
-- PUBLIC API
-----------------------------------------------------------------

--- Set a handling float to an absolute value. Captures original automatically.
--- @param veh number entity handle
--- @param field string CHandlingData field name (e.g. 'fTractionCurveLateral')
--- @param value number the value to set
function VehLib.setHandling(veh, field, value)
    captureOriginal(veh, field)
    SetVehicleHandlingFloat(veh, 'CHandlingData', field, value + 0.0)
end

--- Scale a handling float relative to its original value.
--- @param veh number
--- @param field string
--- @param multiplier number (1.0 = no change, 0.5 = half, 2.0 = double)
function VehLib.scaleHandling(veh, field, multiplier)
    local orig = captureOriginal(veh, field)
    if orig then
        SetVehicleHandlingFloat(veh, 'CHandlingData', field, orig * multiplier)
    end
end

--- Get the captured original value of a field (before any modification).
--- @param veh number
--- @param field string
--- @return number|nil original value, or nil if never captured
function VehLib.getOriginalHandling(veh, field)
    if originals[veh] then return originals[veh][field] end
    return nil
end

--- Get the current live value of a handling field.
--- @param veh number
--- @param field string
--- @return number
function VehLib.getHandling(veh, field)
    return GetVehicleHandlingFloat(veh, 'CHandlingData', field)
end

--- Restore a single field to its original value.
--- @param veh number
--- @param field string
function VehLib.restoreField(veh, field)
    if originals[veh] and originals[veh][field] ~= nil then
        SetVehicleHandlingFloat(veh, 'CHandlingData', field, originals[veh][field])
        originals[veh][field] = nil
    end
end

--- Restore ALL modified fields on a vehicle to their originals.
--- @param veh number
function VehLib.restoreHandling(veh)
    if not originals[veh] then return end
    if not DoesEntityExist(veh) then
        originals[veh] = nil
        return
    end
    for field, orig in pairs(originals[veh]) do
        SetVehicleHandlingFloat(veh, 'CHandlingData', field, orig)
    end
    originals[veh] = nil
end

--- Restore all tracked vehicles (called on resource stop / cleanup)
function VehLib.restoreAll()
    for veh, _ in pairs(originals) do
        if DoesEntityExist(veh) then
            VehLib.restoreHandling(veh)
        end
    end
    originals = {}
end

--- Check if a vehicle has any modified handling fields
--- @param veh number
--- @return boolean
function VehLib.hasModifiedHandling(veh)
    return originals[veh] ~= nil and next(originals[veh]) ~= nil
end

-----------------------------------------------------------------
-- SAFETY: auto-restore on resource stop
-----------------------------------------------------------------
AddEventHandler('onResourceStop', function(resName)
    if resName == GetCurrentResourceName() then
        VehLib.restoreAll()
    end
end)

-- Exports
exports('setHandling', VehLib.setHandling)
exports('scaleHandling', VehLib.scaleHandling)
exports('getOriginalHandling', VehLib.getOriginalHandling)
exports('getHandling', VehLib.getHandling)
exports('restoreField', VehLib.restoreField)
exports('restoreHandling', VehLib.restoreHandling)
exports('restoreAll', VehLib.restoreAll)
exports('hasModifiedHandling', VehLib.hasModifiedHandling)
