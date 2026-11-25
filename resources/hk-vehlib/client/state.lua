-----------------------------------------------------------------
-- hk-vehlib :: client/state.lua
-- Per-vehicle state tracking. Reads vehicle telemetry every frame
-- and caches it so consumer scripts don't each call 10+ natives.
--
-- Usage: local s = VehLib.getState(veh)
--        s.rpm, s.gear, s.speed, s.throttle, etc.
-----------------------------------------------------------------

VehLib = VehLib or {}

-- Internal state cache (keyed by vehicle entity handle)
local stateCache = {}
local lastVeh = 0

-- Single-vehicle state snapshot
local function buildState(veh)
    local vel = GetEntityVelocity(veh)
    local localVel = GetEntitySpeedVector(veh, true)
    local angVel = GetEntityRotationVelocity(veh)
    local rot = GetEntityRotation(veh, 2)
    local speed = GetEntitySpeed(veh)

    return {
        -- Identity
        vehicle = veh,
        model = GetEntityModel(veh),
        class = GetVehicleClass(veh),

        -- Engine
        rpm = GetVehicleCurrentRpm(veh),
        gear = GetVehicleCurrentGear(veh),
        engineOn = GetIsVehicleEngineRunning(veh),
        engineHealth = GetVehicleEngineHealth(veh),

        -- Speed & velocity
        speed = speed,                          -- m/s
        speedKmh = speed * 3.6,                 -- km/h
        velocity = vel,                         -- world-space vector3
        localVelocity = localVel,               -- vehicle-space (Y=fwd, X=right, Z=up)
        forwardSpeed = localVel.y,              -- m/s forward (negative = reversing)
        lateralSpeed = localVel.x,              -- m/s sideways

        -- Rotation
        rotation = rot,                         -- pitch, roll, yaw (degrees)
        pitch = rot.x,
        roll = rot.y,
        yaw = rot.z,
        angularVelocity = angVel,               -- rad/s per axis
        yawRate = angVel.z,                     -- rad/s yaw (positive = turning left)

        -- Input
        throttle = GetControlNormal(0, 71),     -- 0-1 (W / RT)
        brake = GetControlNormal(0, 72),        -- 0-1 (S / LT)
        steer = GetControlNormal(0, 59),        -- -1 to 1 (A/D)
        -- ROBUST handbrake read. Plain IsControlPressed(0,76) returns FALSE whenever another
        -- resource DisableControlAction's control 76 that frame -> the gearbox's launch-staging /
        -- reverse-gate neutral guard (state.handbrake) would then read false and the car drives
        -- off out of neutral under handbrake+throttle. OR in the disabled read AND the native
        -- vehicle handbrake state (same hardening normallearner.lua:102 already uses).
        handbrake = IsControlPressed(0, 76) or IsDisabledControlPressed(0, 76)
                    or GetVehicleHandbrake(veh),   -- bool (space)

        -- Wheels
        wheelCount = GetVehicleNumberOfWheels(veh),
        onAllWheels = IsVehicleOnAllWheels(veh),
        inBurnout = IsVehicleInBurnout(veh),

        -- Misc
        heading = GetEntityHeading(veh),
        isUpsideDown = IsEntityUpsidedown(veh),
        pos = GetEntityCoords(veh),

        -- Timestamp
        frameTime = GetFrameTime(),
        gameTimer = GetGameTimer(),
    }
end

-- Get per-wheel speeds (separate call, slightly expensive)
local function getWheelSpeeds(veh, wheelCount)
    local speeds = {}
    for i = 0, (wheelCount or 4) - 1 do
        speeds[i] = GetVehicleWheelSpeed(veh, i)
    end
    return speeds
end

-----------------------------------------------------------------
-- PUBLIC API
-----------------------------------------------------------------

--- Get the full state snapshot for a vehicle (cached per frame)
--- @param veh number entity handle
--- @return table state snapshot
function VehLib.getState(veh)
    if not veh or veh == 0 then return nil end
    -- Rebuild every frame (frameTime changes)
    local s = buildState(veh)
    stateCache[veh] = s
    return s
end

--- Get individual wheel speeds (costs ~4 native calls)
--- @param veh number entity handle
--- @return table {[0]=FL, [1]=FR, [2]=RL, [3]=RR}
function VehLib.getWheelSpeeds(veh)
    local count = GetVehicleNumberOfWheels(veh)
    return getWheelSpeeds(veh, count)
end

--- Detect wheelspin: returns true if any driven wheel spins faster than ground speed
--- @param veh number
--- @param threshold number speed difference to count as spin (default 2.0 m/s)
--- @return boolean spinning, number worstDiff
function VehLib.detectWheelspin(veh, threshold)
    threshold = threshold or 2.0
    local groundSpeed = GetEntitySpeed(veh)
    local count = GetVehicleNumberOfWheels(veh)
    local worst = 0.0
    for i = 0, count - 1 do
        local ws = math.abs(GetVehicleWheelSpeed(veh, i))
        local diff = ws - groundSpeed
        if diff > worst then worst = diff end
    end
    return worst > threshold, worst
end

--- Check if vehicle is a muscle car (class 4 or in a custom list)
--- @param veh number
--- @return boolean
function VehLib.isMuscle(veh)
    return GetVehicleClass(veh) == 4
end

--- Get the driven vehicle (player must be driver), or nil
--- @return number|nil
function VehLib.getDrivenVehicle()
    local ped = PlayerPedId()
    if not IsPedInAnyVehicle(ped, false) then return nil end
    local veh = GetVehiclePedIsIn(ped, false)
    if GetPedInVehicleSeat(veh, -1) ~= ped then return nil end
    return veh
end

-- Export
exports('getState', VehLib.getState)
exports('getWheelSpeeds', VehLib.getWheelSpeeds)
exports('detectWheelspin', VehLib.detectWheelspin)
exports('isMuscle', VehLib.isMuscle)
exports('getDrivenVehicle', VehLib.getDrivenVehicle)
