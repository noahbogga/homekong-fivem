-----------------------------------------------------------------
-- hk-vehlib :: client/drivetrain.lua
-- Drivetrain / transmission primitives + pure helpers.
--
-- Stateless TOOLS only — no feature state lives here. The manual-gearbox
-- STATE MACHINE (target gear, clutch/stall timers) lives in the consumer
-- (hk-handling/client/gearbox.lua). This file provides the natives it
-- drives plus the pure helpers vlad_gears inlined that are reusable.
--
-- Native call conventions:
--   * build-3095 natives -> Citizen.InvokeNative by HASH (named globals
--     are not guaranteed generated on every build; same rule as drift).
--   * SET_VEHICLE_CURRENT_GEAR has NO static hash -> resolve at runtime via
--     GetHashKey (the approach vlad_gears uses; confirmed working on b3570).
--   * Older gear/engine/mod natives -> named CFX globals (exist on 3570).
-----------------------------------------------------------------

VehLib = VehLib or {}

-- Runtime-resolved hash for the gear setter (no static native hash exists).
local HASH_SET_CURRENT_GEAR = GetHashKey('SET_VEHICLE_CURRENT_GEAR') & 0xFFFFFFFF

-----------------------------------------------------------------
-- BUILD-3095 NATIVE WRAPPERS (by hash)
-----------------------------------------------------------------

--- Toggle R* reduced-gear-ratio = the engine-side manual-transmission enabler.
--- @param veh number
--- @param toggle boolean  true = manual mode on
function VehLib.setTransmissionReducedGearRatio(veh, toggle)
    Citizen.InvokeNative(0x337EF33DA3DDB990, veh, toggle)
end

--- Launch rev limiter ceiling (0.0 = idle floor .. 1.0 = redline).
--- @param veh number
--- @param modifier number
function VehLib.setMaxLaunchRevs(veh, modifier)
    Citizen.InvokeNative(0x5AE614ECA5FDD423, veh, modifier + 0.0)
end

--- The auto-box's next desired drive gear (read-only signal).
--- @param veh number
--- @return number
function VehLib.getDesiredDriveGear(veh)
    return Citizen.InvokeNative(0xFD8CE53356B5D745, veh, Citizen.ResultAsInteger())
end

--- Set the vehicle's current gear (hash resolved at load, vlad's approach).
--- @param veh number
--- @param gear number
function VehLib.setCurrentGear(veh, gear)
    Citizen.InvokeNative(HASH_SET_CURRENT_GEAR, veh, gear)
end

--- Minimum time (ms) the auto-box must wait between gear shifts. Used to stop
--- gear-hunting (anti-hunt) and to make scripted gear nudges stick. build 3095.
--- @param veh number
--- @param ms number
function VehLib.setMinTimeBetweenGearShifts(veh, ms)
    -- HK: nil-guard. A caller passing nil (a dropped/undefined config value) crashed here with
    -- "bad argument #1 to 'floor' (number expected, got nil)" spamming every frame. Default to 0
    -- (= no anti-hunt clamp) so a bad call degrades to native behaviour instead of a script error.
    Citizen.InvokeNative(0x16CFBC5E7EB32861, veh, math.floor(tonumber(ms) or 0))
end


-----------------------------------------------------------------
-- GEAR / ENGINE / MOD PRIMITIVES (named CFX globals)
-----------------------------------------------------------------

--- @param veh number @return number current gear
function VehLib.getCurrentGear(veh) return GetVehicleCurrentGear(veh) end

--- @param veh number @return number highest gear (total gear count)
function VehLib.getHighGear(veh) return GetVehicleHighGear(veh) end

--- Set highest gear. NOTE: gearbox must NEVER call this with high-1 —
--- the extra-gear-from-upgrade suppression is intentionally removed.
--- @param veh number @param gear number
function VehLib.setHighGear(veh, gear) SetVehicleHighGear(veh, gear) end

--- @param veh number @param on boolean @param instantly boolean @param noAutostart boolean
function VehLib.setEngineOn(veh, on, instantly, noAutostart)
    SetVehicleEngineOn(veh, on, instantly, noAutostart)
end

--- @param veh number @return boolean engine mid-start
function VehLib.isEngineStarting(veh) return IsVehicleEngineStarting(veh) end

--- Raw throttle input used for the clutch rev-feed (can exceed 1 / go negative).
--- @param veh number @return number
function VehLib.getThrottleOffset(veh) return GetVehicleThrottleOffset(veh) end

--- @param veh number @param modType number (13 = transmission) @return number mod index or -1
function VehLib.getVehicleMod(veh, modType) return GetVehicleMod(veh, modType) end

--- @param veh number @param modType number @param modIndex number @return number
function VehLib.getModModifier(veh, modType, modIndex)
    return GetVehicleModModifierValue(veh, modType, modIndex)
end

-----------------------------------------------------------------
-- PURE HELPERS (stateless — the reusable inlines vlad had)
-----------------------------------------------------------------

--- Shift duration in ms derived from a clutch-change rate handling value.
--- @param clutchRate number  fClutchChangeRateScaleUp/DownShift
--- @return number ms (0 if rate invalid, avoids div-by-zero on broken data)
function VehLib.computeShiftTimeMs(clutchRate)
    if not clutchRate or clutchRate <= 0.0 then return 0.0 end
    return (0.9 / clutchRate) * 1000.0
end

--- Is this vehicle a manual-transmission candidate? PURE query, no writes.
--- 3 triggers OR'd (the stateful jim-event "toggled" trigger is handled by
--- the consumer and short-circuits before this is called):
---   T1 strHandlingFlags bit 24 (0x1000000)   [cfg.UseHandlingFlagTrigger]
---   T2 cfg.DefaultManualModels has this model, or statebag hk_manual==true
---   T3 transmission mod present (slot 13)     [cfg.UseModTrigger]
--- @param veh number
--- @param cfg table  Config.Gearbox (kept config-agnostic — pass-through)
--- @return boolean
function VehLib.isManualVehicle(veh, cfg)
    cfg = cfg or {}

    -- T1: handling flag bit 24. No bit lib assumed -> integer arithmetic.
    if cfg.UseHandlingFlagTrigger ~= false then
        local flags = GetVehicleHandlingInt(veh, 'CHandlingData', 'strHandlingFlags') or 0
        if (math.floor(flags / 0x1000000) % 2) == 1 then return true end
    end

    -- T1b: CF_GEARBOX_MANUAL = strAdvancedFlags bit 0x400 in CCarHandlingData.
    -- OPT-IN ONLY (must be explicitly true): reading CCarHandlingData at runtime
    -- is unreliable — it errors "No such field strAdvancedFlags" on many addon
    -- cars. The model-based SQL list is the robust path. Default = off.
    if cfg.UseAdvancedFlagTrigger == true then
        local adv = GetVehicleHandlingInt(veh, 'CCarHandlingData', 'strAdvancedFlags') or 0
        if (math.floor(adv / 0x400) % 2) == 1 then return true end
    end

    -- T2: explicit model list or per-entity statebag override.
    local models = cfg.DefaultManualModels
    if models then
        local model = GetEntityModel(veh)
        for _, m in ipairs(models) do
            if m == model then return true end
        end
    end
    local ok, st = pcall(function() return Entity(veh).state end)
    if ok and st and st.hk_manual == true then return true end

    -- T3: transmission upgrade fitted (mod slot 13).
    if cfg.UseModTrigger ~= false then
        if GetVehicleMod(veh, 13) ~= -1 then return true end
    end

    return false
end

--- Read-only snapshot of the drivetrain handling values the gearbox needs
--- to restore itself. Does NOT register into handling.lua's originals[] —
--- the gearbox owns its own restore (so the main-loop restoreHandling
--- catch-all can't clobber clutch state mid-drive).
--- @param veh number
--- @return table
function VehLib.getDrivetrainOrigins(veh)
    local function hf(field) return GetVehicleHandlingFloat(veh, 'CHandlingData', field) end
    return {
        fInitialDriveForce              = hf('fInitialDriveForce'),
        fDriveInertia                   = hf('fDriveInertia'),
        fInitialDriveMaxFlatVel         = hf('fInitialDriveMaxFlatVel'),
        fClutchChangeRateScaleUpShift   = hf('fClutchChangeRateScaleUpShift'),
        fClutchChangeRateScaleDownShift = hf('fClutchChangeRateScaleDownShift'),
        fDriveBiasFront                 = hf('fDriveBiasFront'),   -- native drivetrain bias (drivetrain label)
        highGear                        = GetVehicleHighGear(veh),
        driveGears                      = GetVehicleHandlingInt(veh, 'CHandlingData', 'nInitialDriveGears'),
    }
end

--- Is the vehicle right-hand-drive? (steering-wheel bone offset test)
--- @param veh number
--- @return boolean
function VehLib.isRightHandDrive(veh)
    local bone = GetEntityBoneIndexByName(veh, 'steeringwheel')
    if bone == -1 then return false end
    local wp = GetWorldPositionOfEntityBone(veh, bone)
    local off = GetOffsetFromEntityGivenWorldCoords(veh, wp.x, wp.y, wp.z)
    return off.x > 0.0
end

-----------------------------------------------------------------
-- EXPORTS
-----------------------------------------------------------------
exports('setTransmissionReducedGearRatio', VehLib.setTransmissionReducedGearRatio)
exports('setMaxLaunchRevs', VehLib.setMaxLaunchRevs)
exports('getDesiredDriveGear', VehLib.getDesiredDriveGear)
exports('setCurrentGear', VehLib.setCurrentGear)
exports('setMinTimeBetweenGearShifts', VehLib.setMinTimeBetweenGearShifts)
exports('getCurrentGear', VehLib.getCurrentGear)
exports('getHighGear', VehLib.getHighGear)
exports('setHighGear', VehLib.setHighGear)
exports('setEngineOn', VehLib.setEngineOn)
exports('isEngineStarting', VehLib.isEngineStarting)
exports('getThrottleOffset', VehLib.getThrottleOffset)
exports('getVehicleMod', VehLib.getVehicleMod)
exports('getModModifier', VehLib.getModModifier)
exports('computeShiftTimeMs', VehLib.computeShiftTimeMs)
exports('isManualVehicle', VehLib.isManualVehicle)
exports('getDrivetrainOrigins', VehLib.getDrivetrainOrigins)
exports('isRightHandDrive', VehLib.isRightHandDrive)
