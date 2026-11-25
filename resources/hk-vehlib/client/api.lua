-----------------------------------------------------------------
-- hk-vehlib :: client/api.lua
-- Top-level convenience API + math utilities that consumer scripts
-- use constantly. Also handles the auto-restore lifecycle.
--
-- This file ties everything together and provides the "nice" API
-- that hk-racecam and hk-vehdynamic will actually call.
-----------------------------------------------------------------

VehLib = VehLib or {}

-----------------------------------------------------------------
-- MATH UTILITIES (exported for consumer scripts)
-----------------------------------------------------------------

--- Linear interpolation
function VehLib.lerp(a, b, t) return a + (b - a) * t end

--- Clamp a value between min and max
function VehLib.clamp(v, lo, hi)
    if v < lo then return lo elseif v > hi then return hi else return v end
end

--- Frame-rate independent exponential smoothing
--- @param current number current value
--- @param target number target value
--- @param tau number time constant in seconds (higher = slower)
--- @param dt number frame time (GetFrameTime())
--- @return number smoothed value
function VehLib.smooth(current, target, tau, dt)
    if tau <= 0 or dt <= 0 then return target end
    local alpha = 1.0 - math.exp(-dt / tau)
    return current + (target - current) * alpha
end

--- Smoothstep (cubic ease between 0 and 1)
--- @param edge0 number lower edge
--- @param edge1 number upper edge
--- @param x number input value
--- @return number 0.0 to 1.0
function VehLib.smoothstep(edge0, edge1, x)
    local t = VehLib.clamp((x - edge0) / (edge1 - edge0), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)
end

--- Map a value from one range to another
--- @param value number input
--- @param inMin number input range min
--- @param inMax number input range max
--- @param outMin number output range min
--- @param outMax number output range max
--- @return number mapped value (clamped to output range)
function VehLib.map(value, inMin, inMax, outMin, outMax)
    local t = VehLib.clamp((value - inMin) / (inMax - inMin), 0.0, 1.0)
    return outMin + t * (outMax - outMin)
end

--- Convert m/s to km/h
function VehLib.toKmh(ms) return ms * 3.6 end

--- Convert km/h to m/s
function VehLib.toMs(kmh) return kmh / 3.6 end

-----------------------------------------------------------------
-- LIFECYCLE MANAGEMENT
-----------------------------------------------------------------

-- Track the last vehicle we were in (for auto-restore on exit)
local lastTrackedVeh = 0

--- Call this every frame from consumer scripts (or let the library do it).
--- Handles auto-restore when player exits vehicle.
function VehLib.tick()
    local veh = VehLib.getDrivenVehicle()

    if veh then
        lastTrackedVeh = veh
    elseif lastTrackedVeh ~= 0 then
        -- Player just exited a vehicle — restore handling if configured
        if VehLib.Config.RestoreOnExit and VehLib.hasModifiedHandling(lastTrackedVeh) then
            VehLib.restoreHandling(lastTrackedVeh)
        end
        lastTrackedVeh = 0
    end
end

-- Auto-tick thread (keeps lifecycle running without consumer needing to call it)
CreateThread(function()
    while true do
        VehLib.tick()
        Wait(100) -- Check every 100ms (not per-frame, just for lifecycle)
    end
end)

-----------------------------------------------------------------
-- DEBUG
-----------------------------------------------------------------

--- Print a debug message (only when Config.Debug is true)
function VehLib.dbg(...)
    if VehLib.Config.Debug then
        print('[hk-vehlib]', ...)
    end
end

--- Notification — QBCore/qbx if present, GTA-native fallback. Centralised here
--- so every consumer (hk-handling, etc.) shows notifications consistently.
--- @param msg string   clean text (no GTA colour codes needed for QB path)
--- @param ntype string 'success' | 'error' | 'primary' (default 'primary')
-- ntype maps to ox_lib's type enum: 'primary' -> 'inform'. All hk vehicle notifs
-- (perfect-shift callouts, launch, calibration) route through here, so switching the
-- backend once migrates every consumer to ox_lib's top-right toast in one place.
function VehLib.notify(msg, ntype)
    ntype = ntype or 'primary'
    -- ox_lib (preferred): clean top-right toast. `lib` is the ox_lib global (loaded
    -- via '@ox_lib/init.lua' in the manifest). Guard so a missing ox_lib can't error.
    if lib and lib.notify then
        local oxType = (ntype == 'primary') and 'inform' or ntype   -- success/error pass through
        -- Strip GTA colour codes (~r~ ~g~ ~y~ ~b~ ~w~ ~o~ …): they render as literal
        -- text in ox_lib. Colour is conveyed by `type` instead. Callers can keep passing
        -- the old ~x~-prefixed strings unchanged.
        local clean = tostring(msg):gsub('~%w~', '')
        lib.notify({ description = clean, type = oxType, position = 'top-right' })
        return
    end
    -- Fallback 1: QBCore/qbx notify event (legacy).
    if GetResourceState('qb-core') == 'started' or GetResourceState('qbx_core') == 'started' then
        TriggerEvent('QBCore:Notify', msg, ntype)
        return
    end
    -- Fallback 2: GTA-native popup.
    local color = (ntype == 'success' and '~g~') or (ntype == 'error' and '~r~') or '~o~'
    SetNotificationTextEntry('STRING')
    AddTextComponentString(color .. msg)
    DrawNotification(false, false)
end

-- Exports
exports('lerp', VehLib.lerp)
exports('clamp', VehLib.clamp)
exports('smooth', VehLib.smooth)
exports('smoothstep', VehLib.smoothstep)
exports('map', VehLib.map)
exports('toKmh', VehLib.toKmh)
exports('toMs', VehLib.toMs)
exports('dbg', VehLib.dbg)
exports('notify', VehLib.notify)
