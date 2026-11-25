-----------------------------------------------------------------
-- hk-vehlib :: client/forces.lua
-- Safe physics force application. Wraps ApplyForceToEntity with
-- smoothing, rate limiting, and magnitude caps.
--
-- Usage:
--   VehLib.applyForce(veh, {x=0, y=0, z=5000}, {x=0, y=1.5, z=0})
--   VehLib.applyLift(veh, 8000, 1.5)  -- lift front axle
--   VehLib.applyDownforce(veh, speed)  -- speed-scaled push down
--   VehLib.setTorque(veh, 1.5)         -- 1.5x engine torque this frame
--   VehLib.setGravity(veh, 1.1)        -- slightly heavier
-----------------------------------------------------------------

VehLib = VehLib or {}

local clamp = function(v, lo, hi)
    if v < lo then return lo elseif v > hi then return hi else return v end
end

-----------------------------------------------------------------
-- PUBLIC API
-----------------------------------------------------------------

--- Apply a raw force to a vehicle at a local offset.
--- Force is capped by Config.MaxForceNewtons.
--- @param veh number entity handle
--- @param force table {x, y, z} force in Newtons (vehicle-local frame)
--- @param offset table {x, y, z} application point offset from center of mass
--- @param isWorldSpace boolean (default false = vehicle-local)
--- @param forceType number|nil ApplyForceToEntity type. DEFAULT 1 (impulse) for
---   backward-compat (drift's transient yaw couple relies on it). Pass 0 for a
---   CONTINUOUS force (APPLY_TYPE_FORCE) — the safe per-frame type for a sustained,
---   self-limiting effect (wheelie/headlift). CRITICAL enum note: the old comment here
---   claimed "1 = continuous force" — that is WRONG. GTA's enum is 0=FORCE (continuous),
---   1=IMPULSE (instant Δv, COMPOUNDS every frame — the downforce blow-up culprit),
---   2=EXT_FORCE, 3=EXT_IMPULSE, 4=TORQUE, 5=ANGULAR_IMPULSE.
function VehLib.applyForce(veh, force, offset, isWorldSpace, forceType)
    local maxF = VehLib.Config.MaxForceNewtons
    local fx = clamp(force.x or 0, -maxF, maxF)
    local fy = clamp(force.y or 0, -maxF, maxF)
    local fz = clamp(force.z or 0, -maxF, maxF)
    local ox = offset and offset.x or 0.0
    local oy = offset and offset.y or 0.0
    local oz = offset and offset.z or 0.0

    ApplyForceToEntity(veh,
        forceType or 1,             -- forceType (see @param): default 1 = impulse (legacy)
        fx, fy, fz,                 -- force vector
        ox, oy, oz,                 -- offset from CoM
        0,                          -- bone index (0 = root)
        not isWorldSpace,           -- isDirectionRel (true = local)
        true,                       -- ignoreUpVec
        true,                       -- isForceRel (offset is local)
        false,                      -- p12
        true                        -- p13
    )
end

--- Apply upward lift force at a forward offset (for wheelie/headlift).
--- @param veh number
--- @param forceZ number upward force in Newtons (positive = lift)
--- @param offsetY number forward offset from CoM (positive = front of car)
function VehLib.applyLift(veh, forceZ, offsetY)
    VehLib.applyForce(veh,
        { x = 0.0, y = 0.0, z = forceZ },
        { x = 0.0, y = offsetY or 1.5, z = 0.0 }
    )
end

--- Apply speed-dependent downforce (call every frame while driving).
--- @param veh number
--- @param speedKmh number current speed in km/h
--- @param config table|nil {minSpeed, maxSpeed, maxForce} (optional overrides)
function VehLib.applyDownforce(veh, speedKmh, config)
    local cfg = config or {}
    local minSpd = cfg.minSpeed or 60.0
    local maxSpd = cfg.maxSpeed or 220.0
    local maxForce = cfg.maxForce or 8000.0

    if speedKmh < minSpd then return end

    local t = clamp((speedKmh - minSpd) / (maxSpd - minSpd), 0.0, 1.0)
    -- Quadratic scaling (force ∝ speed²) for realistic aero feel
    local force = maxForce * t * t

    VehLib.applyForce(veh,
        { x = 0.0, y = 0.0, z = -force },
        { x = 0.0, y = 0.0, z = 0.0 }
    )
end

--- Set engine torque multiplier THIS FRAME. Must call every frame.
--- Capped by Config.MaxTorqueMultiplier.
--- @param veh number
--- @param multiplier number (1.0 = normal, 2.0 = double, 0.0 = cut)
function VehLib.setTorque(veh, multiplier)
    local capped = clamp(multiplier, 0.0, VehLib.Config.MaxTorqueMultiplier)
    SetVehicleEngineTorqueMultiplier(veh, capped)
end

--- Set vehicle gravity multiplier. Capped by Config.MaxGravityMult.
--- @param veh number
--- @param mult number (1.0 = normal, 1.15 = heavier, 0.8 = lighter)
function VehLib.setGravity(veh, mult)
    local capped = clamp(mult, 0.1, VehLib.Config.MaxGravityMult)
    SetVehicleGravityAmount(veh, capped)
end

--- Modify top speed temporarily (multiplier on max flat vel).
--- @param veh number
--- @param mult number (1.0 = normal, 1.3 = 30% faster)
function VehLib.modifyTopSpeed(veh, mult)
    ModifyVehicleTopSpeed(veh, mult)
end

--- Force RPM to a specific value (0.0 to 1.0).
--- @param veh number
--- @param rpm number (0.0 = idle, 1.0 = redline)
function VehLib.setRpm(veh, rpm)
    SetVehicleCurrentRpm(veh, clamp(rpm, 0.0, 1.0))
end

--- Force RPM with NO clamping. Needed for the gearbox neutral rev-feed, which
--- uses a transiently negative target. Use setRpm for normal 0-1 cases.
--- @param veh number
--- @param rpm number
function VehLib.setRpmRaw(veh, rpm)
    SetVehicleCurrentRpm(veh, rpm + 0.0)
end

--- Force burnout state (spinning wheels + smoke).
--- @param veh number
--- @param enabled boolean
function VehLib.setBurnout(veh, enabled)
    SetVehicleBurnout(veh, enabled)
end

--- Reduce all grip globally (blunt drift tool).
--- @param veh number
--- @param enabled boolean
function VehLib.setReduceGrip(veh, enabled)
    SetVehicleReduceGrip(veh, enabled)
end

-----------------------------------------------------------------
-- MODERN DRIFT NATIVES (game build >= 2372 / 3095). Server is 3570.
-- All client-only; the float-based ones may need re-applying per frame.
-----------------------------------------------------------------

--- R* drift-tyre mode (LS Tuners). The main native slide enabler.
--- Called by hash — the named global SetDriftTyres isn't generated on all builds.
--- @param veh number
--- @param enabled boolean
function VehLib.setDriftTyres(veh, enabled)
    Citizen.InvokeNative(0x5AC79C98C5C17F05, veh, enabled)
end

--- Whether drift tyres are currently set on the vehicle.
--- @param veh number
--- @return boolean
function VehLib.getDriftTyres(veh)
    return Citizen.InvokeNative(0x2F5A72430E78C8D3, veh, Citizen.ResultAsInteger()) ~= 0
end

--- Continuous traction-loss multiplier (1.0 = stock, higher = more slide).
--- Wraps _SET_OVERRIDE_TRACTION_LOSS_MULTIPLIER (0xAFD262ACCA64479A).
--- Re-apply per frame while active.
--- @param veh number
--- @param modifier number
function VehLib.setTractionLossMult(veh, modifier)
    Citizen.InvokeNative(0xAFD262ACCA64479A, veh, modifier + 0.0)
end

--- Drift slip-angle limits. durationScalar/amplitudeScalar = controller
--- rumble; slipAngleLimit = the slip threshold. Re-apply per frame.
--- Wraps _SET_DRIFT_SLIP_ANGLE_LIMITS (0xDAF4C98C18AC6F06).
--- @param veh number
--- @param durationScalar number
--- @param amplitudeScalar number
--- @param slipAngleLimit number
function VehLib.setDriftSlipAngleLimits(veh, durationScalar, amplitudeScalar, slipAngleLimit)
    Citizen.InvokeNative(0xDAF4C98C18AC6F06, veh,
        durationScalar + 0.0, amplitudeScalar + 0.0, slipAngleLimit + 0.0)
end

--- Lower the vehicle's stance. Requires strAdvancedFlags 0x8000 + 0x4000000
--- on the vehicle's handling.meta or it does nothing.
--- @param veh number
--- @param enabled boolean
function VehLib.setReducedSuspension(veh, enabled)
    Citizen.InvokeNative(0x3A375167F5782A65, veh, enabled)
end

--- Force the handbrake on/off (the real e-brake input). Used for a brief
--- auto-tap to kick the rear loose when initiating a drift.
--- @param veh number
--- @param enabled boolean
function VehLib.setHandbrake(veh, enabled)
    SetVehicleHandbrake(veh, enabled)
end

-- Exports
exports('applyForce', VehLib.applyForce)
exports('applyLift', VehLib.applyLift)
exports('applyDownforce', VehLib.applyDownforce)
exports('setTorque', VehLib.setTorque)
exports('setGravity', VehLib.setGravity)
exports('modifyTopSpeed', VehLib.modifyTopSpeed)
exports('setRpm', VehLib.setRpm)
exports('setRpmRaw', VehLib.setRpmRaw)
exports('setBurnout', VehLib.setBurnout)
exports('setReduceGrip', VehLib.setReduceGrip)
exports('setDriftTyres', VehLib.setDriftTyres)
exports('getDriftTyres', VehLib.getDriftTyres)
exports('setTractionLossMult', VehLib.setTractionLossMult)
exports('setDriftSlipAngleLimits', VehLib.setDriftSlipAngleLimits)
exports('setReducedSuspension', VehLib.setReducedSuspension)
exports('setHandbrake', VehLib.setHandbrake)
