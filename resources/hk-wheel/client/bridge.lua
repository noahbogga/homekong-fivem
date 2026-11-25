-- hk-wheel :: client/bridge.lua
-- The Lua half of the transport. Receives NUI callbacks from nui/bridge.js
-- (which owns the localhost WebSocket to the companion app), caches the latest
-- wheel frame, and pushes config/FFB frames back out via SendNUIMessage.
--
-- Nothing here touches hk-handling. This module ONLY manages the data pipe.

Wheel = Wheel or {}

-- Latest wheel input frame from the app. nil until first frame arrives.
-- Shape (all optional; app fills what the device has):
--   { steer=-1..1, throttle=0..1, brake=0..1, clutch=0..1,
--     gear=<int|R|N>, hpattern=bool, buttons={...}, rangeDeg=900, ts=<ms> }
Wheel.frame = nil
Wheel.frameAt = 0            -- GetGameTimer() of the last frame (staleness check)
Wheel.device = nil          -- last device report {name, rangeDeg, hasFFB, hasClutch, hasH}
Wheel.bridgeUp = false      -- NUI socket connected to the app?
Wheel.deviceUp = false      -- a wheel device actually present?

local STALE_MS = 250        -- a frame older than this = treat wheel as absent (safety)

-- ── Freshness / availability ──────────────────────────────────────────────────
-- The single source of truth other modules ask: "is the wheel live right now?"
function Wheel.isActive()
    if not Wheel.bridgeUp or not Wheel.deviceUp then return false end
    if not Wheel.frame then return false end
    return (GetGameTimer() - Wheel.frameAt) <= STALE_MS
end

function Wheel.getFrame()
    if not Wheel.isActive() then return nil end
    return Wheel.frame
end

-- ── NUI callbacks (from bridge.js) ─────────────────────────────────────────────

-- Highest-rate path: a wheel input snapshot. Keep this LEAN (fires ~100-250/s).
RegisterNUICallback('wheelFrame', function(data, cb)
    Wheel.frame   = data
    Wheel.frameAt = GetGameTimer()
    cb('ok')
end)

RegisterNUICallback('wheelDevice', function(data, cb)
    if data and data.connected == false then
        Wheel.deviceUp = false
        Wheel.device = nil
        if Config.Debug then print('[hk-wheel] device disconnected') end
    else
        Wheel.device = data
        Wheel.deviceUp = true
        if Config.Debug then
            print(('[hk-wheel] device: %s range=%s ffb=%s clutch=%s h=%s')
                :format(tostring(data and data.name), tostring(data and data.rangeDeg),
                        tostring(data and data.hasFFB), tostring(data and data.hasClutch),
                        tostring(data and data.hasH)))
        end
    end
    cb('ok')
end)

RegisterNUICallback('bridgeState', function(data, cb)
    Wheel.bridgeUp = data and data.connected == true
    if not Wheel.bridgeUp then
        Wheel.deviceUp = false      -- socket down => device is unreachable
        Wheel.frame = nil
    end
    if Config.Debug then print('[hk-wheel] bridge ' .. (Wheel.bridgeUp and 'UP' or 'DOWN')) end
    cb('ok')
end)

-- ── Outbound: config + FFB ─────────────────────────────────────────────────────

-- Kick the NUI socket open with our transport config. Called on resource start.
local function sendConfig()
    SendNUIMessage({
        type = 'config',
        host = Config.Host,
        port = Config.Port,
        reconnectMs = Config.ReconnectMs,
        debug = Config.Debug,
    })
end

-- Push one FFB frame to the app. `f` is a small table the app maps to DI effects:
--   { align = -1..1,   -- self-aligning torque (signed: matches steer direction)
--     slip  = 0..1,    -- front grip loss (app fades constant force)
--     surface = 0..1,  -- kerb/road rumble amplitude
--     spring = 0..1 }  -- centering spring (parking)
function Wheel.sendFFB(f)
    SendNUIMessage({ type = 'ffb', f = f })
end

-- Push runtime app config (device range, gains) — used if we change settings live.
function Wheel.sendAppConfig(c)
    SendNUIMessage({ type = 'appcfg', c = c })
end

AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() then
        SendNUIMessage({ type = 'disconnect' })
    end
end)

CreateThread(function()
    -- Give CEF a moment to load bridge.js, then hand it the config to connect.
    Wait(500)
    sendConfig()
    if Config.Debug then print('[hk-wheel] bridge config sent -> ' .. Config.Host .. ':' .. Config.Port) end
end)
