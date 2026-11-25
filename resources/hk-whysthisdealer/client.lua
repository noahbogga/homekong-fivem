-- hk-whysthisdealer client.
-- The bounce is VISUAL: every nearby client oscillates the vehicle's suspension
-- height on a sine wave locked to the shared network clock, so the body bobs in
-- time to the beat with the wheels planted (the bouncing-Yaris look). Because
-- it's visual-only and clock-driven, every client renders the same bob without
-- relying on physics net-sync, and there's no solver flood.

local beatMs      = (60000.0 / Config.BPM)
local playing     = {}   -- [vehNetId] = { startedAt }
local lastToggle  = 0
local myVehNetId  = nil  -- the vehicle *I* started bouncing (for exit auto-stop)
local TWO_PI      = math.pi * 2.0

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
local function notify(msg)
    BeginTextCommandThefeedPost('STRING')
    AddTextComponentSubstringPlayerName(msg)
    EndTextCommandThefeedPostTicker(false, true)
end

-- SET_VEHICLE_SUSPENSION_HEIGHT is visual only. Positive lowers, negative
-- raises; so "up" (a hop) is a NEGATIVE height. Reset to 0 on stop.
local function setBob(veh, height)
    if DoesEntityExist(veh) then
        SetVehicleSuspensionHeight(veh, height)
    end
end

-- Convert a beat phase (0..1) into a suspension height.
-- BallBounce off: smooth symmetric sine (floaty bop).
-- BallBounce on: parabolic hop — body gathers/squashes low, snaps up fast,
--                hangs at the peak, then falls back down. That's the hop feel.
local function bounceHeight(phase, amp)
    if not Config.BallBounce then
        return math.sin(phase * TWO_PI) * amp + Config.RideBias
    end

    -- parabola: 0 at the ground (phase 0/1), 1 at the top (phase 0.5)
    local arc    = 4.0 * phase * (1.0 - phase)
    -- flatten the top to add hang time (arc^k, k<1 pushes values toward 1)
    local hangK  = 1.0 - Config.HangTime
    if hangK < 0.05 then hangK = 0.05 end
    local raised = arc ^ hangK                      -- 0..1, how far UP the body is

    -- brief squash (body drops onto springs) at the very bottom of the cycle
    local squash = 0.0
    local edge   = 0.12
    if phase < edge then
        squash = ((edge - phase) / edge) * amp * 0.5
    elseif phase > (1.0 - edge) then
        squash = ((phase - (1.0 - edge)) / edge) * amp * 0.5
    end

    -- up is negative; peak hop ~= 2*amp above rest, squash pushes down
    return Config.RideBias - (raised * amp * 2.0) + squash
end

-- ---------------------------------------------------------------------------
-- Local start/stop
-- ---------------------------------------------------------------------------
local function startLocal(vehNetId, startedAt)
    playing[vehNetId] = { startedAt = startedAt }
    local off = (GetNetworkTime() - startedAt) / 1000.0
    if off < 0 then off = 0.0 end
    SendNUIMessage({ action = 'play', id = vehNetId, offset = off })
end

local function stopLocal(vehNetId)
    if not playing[vehNetId] then return end
    playing[vehNetId] = nil
    local veh = NetworkGetEntityFromNetworkId(vehNetId)
    setBob(veh, 0.0)  -- restore ride height
    SendNUIMessage({ action = 'stop', id = vehNetId })
end

-- ---------------------------------------------------------------------------
-- Bounce + audio loop (per-frame while anything is playing)
-- ---------------------------------------------------------------------------
CreateThread(function()
    while true do
        if next(playing) == nil then
            Wait(200)
        else
            local now     = GetNetworkTime()
            local ped     = PlayerPedId()
            local pcoords  = GetEntityCoords(ped)
            local amp     = Config.BounceHeight * Config.BounceGain

            for vehNetId, st in pairs(playing) do
                local veh     = NetworkGetEntityFromNetworkId(vehNetId)
                local elapsed = now - st.startedAt

                if elapsed >= (Config.ClipSeconds * 1000.0) then
                    stopLocal(vehNetId)
                elseif DoesEntityExist(veh) then
                    -- phase within the current bounce cycle, 0..1
                    local beats = (elapsed / beatMs) * Config.BobsPerBeat
                    local phase = beats - math.floor(beats)
                    setBob(veh, bounceHeight(phase, amp))

                    -- audio: volume by distance + live playback position from the
                    -- shared network clock, so every client stays in sync (and any
                    -- client whose autoplay was blocked keeps getting retried).
                    local dist = #(pcoords - GetEntityCoords(veh))
                    local vol  = 0.0
                    if dist <= Config.HearingRange then
                        vol = Config.MaxVolume * (1.0 - (dist / Config.HearingRange))
                    end
                    SendNUIMessage({
                        action = 'sync',
                        id     = vehNetId,
                        vol    = vol,
                        pos    = elapsed / 1000.0,  -- seconds into the clip, network-synced
                    })
                end
            end
            Wait(0)
        end
    end
end)

-- ---------------------------------------------------------------------------
-- Net events (server clock lives on startedAt = initiator's GetNetworkTime())
-- ---------------------------------------------------------------------------
RegisterNetEvent('hk-wtd:play', function(vehNetId, startedAt, _coords)
    startLocal(vehNetId, startedAt)
end)

RegisterNetEvent('hk-wtd:halt', function(vehNetId)
    if myVehNetId == vehNetId then myVehNetId = nil end
    stopLocal(vehNetId)
end)

-- Auto-stop when I leave the car I started (exit seat, ejected, car gone).
CreateThread(function()
    while true do
        if myVehNetId ~= nil then
            local ped   = PlayerPedId()
            local veh   = GetVehiclePedIsIn(ped, false)
            local mine  = veh ~= 0 and NetworkGetNetworkIdFromEntity(veh) == myVehNetId
            -- still the driver of that exact car?
            local stillDriving = mine and GetPedInVehicleSeat(veh, -1) == ped
            if not stillDriving then
                local stopId = myVehNetId
                myVehNetId = nil
                TriggerServerEvent('hk-wtd:stop', stopId)
            end
            Wait(250)
        else
            Wait(500)
        end
    end
end)

-- ---------------------------------------------------------------------------
-- Toggle command / keybind
-- ---------------------------------------------------------------------------
local function toggle()
    local now = GetGameTimer()
    if (now - lastToggle) < Config.CooldownMs then return end
    lastToggle = now

    local ped = PlayerPedId()
    local veh = GetVehiclePedIsIn(ped, false)
    if veh == 0 then
        notify("~y~Why's this dealer?~s~ Get in a car first.")
        return
    end
    if Config.DriverOnly and GetPedInVehicleSeat(veh, -1) ~= ped then
        notify("~y~Why's this dealer?~s~ Only the driver can do this.")
        return
    end

    if not NetworkGetEntityIsNetworked(veh) then NetworkRegisterEntityAsNetworked(veh) end
    local vehNetId = NetworkGetNetworkIdFromEntity(veh)

    if playing[vehNetId] then
        myVehNetId = nil
        TriggerServerEvent('hk-wtd:stop', vehNetId)
    else
        myVehNetId = vehNetId
        local c = GetEntityCoords(veh)
        TriggerServerEvent('hk-wtd:start', vehNetId, GetNetworkTime(), { x = c.x, y = c.y, z = c.z })
    end
end

RegisterCommand(Config.Command, toggle, false)
if Config.CommandAlias ~= '' then RegisterCommand(Config.CommandAlias, toggle, false) end
RegisterKeyMapping(Config.Command, "Why's This Dealer? (bounce)", 'keyboard', Config.DefaultKey)

-- Ask the server for anything already bouncing when we spawn in.
CreateThread(function()
    while not NetworkIsPlayerActive(PlayerId()) do Wait(500) end
    Wait(1500)
    TriggerServerEvent('hk-wtd:sync')
end)
