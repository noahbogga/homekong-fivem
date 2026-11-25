-- hk-debugtracker :: cl_anticheat.lua  (CLIENT)
-- Two jobs:
--   1) Reply to server diagnostics requests (for /hkclient forensic dumps).
--   2) Anticheat MEASUREMENT: local detection loops that flag suspicious state
--      to the server. NO client-side punishment — the server logs + screenshots,
--      staff ban manually. Exempt (owner/staff) identifiers are told by the
--      server so the loops go quiet for them.

-- Client config is PUSHED by the server (config.lua is server-only so its
-- webhook URLs never reach clients). Sensible defaults until the push arrives.
local AC = {
    Enabled = false,        -- stays off until the server confirms settings
    ClientDebounceMs = 8000,
    Thresholds = { SuperJump = 20.0, MaxFootSpeed = 13.0, MaxTickMove = 60.0 },
    BlacklistedPlates = {},
}
local isExempt = false     -- set by server after load
local started = false      -- detection threads spun up only once
local flaggedRecently = {} -- kind -> GetGameTimer() of last send (client-side debounce)

-- ---------------------------------------------------------------------------
-- (1) DIAGNOSTICS RESPONDER
-- ---------------------------------------------------------------------------
local function vehDesc()
    local ped = PlayerPedId()
    if not IsPedInAnyVehicle(ped, false) then return nil end
    local v = GetVehiclePedIsIn(ped, false)
    if v == 0 then return nil end
    local model = GetEntityModel(v)
    local name = GetDisplayNameFromVehicleModel(model)
    local plate = GetVehicleNumberPlateText(v)
    return ('%s [%s]'):format(name or '?', (plate or ''):gsub('%s+$', ''))
end

local function weaponDesc()
    local ped = PlayerPedId()
    local w = GetSelectedPedWeapon(ped)
    if w == GetHashKey('WEAPON_UNARMED') then return 'unarmed' end
    return ('0x%08X'):format(w & 0xFFFFFFFF)
end

RegisterNetEvent('hk-debugtracker:client:getDiag', function()
    local ped = PlayerPedId()
    local c = GetEntityCoords(ped)
    TriggerServerEvent('hk-debugtracker:server:diagReply', {
        coords  = ('%.1f, %.1f, %.1f'):format(c.x, c.y, c.z),
        heading = ('%.0f'):format(GetEntityHeading(ped)),
        health  = GetEntityHealth(ped),
        armor   = GetPedArmour(ped),
        weapon  = weaponDesc(),
        vehicle = vehDesc(),
        fps     = math.floor(1.0 / (GetFrameTime() + 0.00001)),
    })
end)

-- server pushes exempt state + (non-sensitive) AC settings and starts loops
RegisterNetEvent('hk-debugtracker:client:acConfig', function(cfg, exempt)
    isExempt = exempt and true or false
    if type(cfg) == 'table' then
        AC.Enabled = cfg.Enabled and true or false
        AC.ClientDebounceMs = cfg.ClientDebounceMs or AC.ClientDebounceMs
        AC.Thresholds = cfg.Thresholds or AC.Thresholds
        AC.BlacklistedPlates = cfg.BlacklistedPlates or AC.BlacklistedPlates
    end
    startDetection()
end)

-- ask the server for our config on (re)start
CreateThread(function()
    Wait(1500)
    TriggerServerEvent('hk-debugtracker:server:acHello')
end)

-- ---------------------------------------------------------------------------
-- (2) DETECTION LOOPS  (measurement only)
-- ---------------------------------------------------------------------------
local function flag(kind, detail)
    if isExempt then return end
    local now = GetGameTimer()
    local last = flaggedRecently[kind]
    if last and (now - last) < (AC.ClientDebounceMs or 8000) then return end
    flaggedRecently[kind] = now
    TriggerServerEvent('hk-debugtracker:server:acFlag', kind, detail or '')
end

-- shared "a teleport just happened" suppressor. A teleport is a SINGLE huge
-- position spike (admin TP, apartment/garage/interior warp, spawn, respawn);
-- real noclip/speedhack is SUSTAINED. After any implausible jump we mute the
-- movement detections for a short settle window so warps never flag.
local teleportMuteUntil = 0
local function muteMovement(ms)
    local until_ = GetGameTimer() + (ms or 4000)
    if until_ > teleportMuteUntil then teleportMuteUntil = until_ end
end
local function movementMuted()
    return GetGameTimer() < teleportMuteUntil
end

function startDetection()
    if started or not AC.Enabled then return end
    started = true
    local th = AC.Thresholds or {}

    -- superjump: only real, airborne jumps. A jump that "moves" more than the
    -- teleport floor is a warp mid-jump, not a cheat — ignore it and mute.
    CreateThread(function()
        while true do
            Wait(500)
            local ped = PlayerPedId()
            if IsPedJumping(ped) and not movementMuted() then
                local a = GetEntityCoords(ped)
                local t0 = GetGameTimer()
                while IsPedJumping(ped) and (GetGameTimer() - t0) < 3000 do Wait(0) end
                local b = GetEntityCoords(ped)
                local d = #(a - b)
                if d >= (th.TeleportFloor or 150.0) then
                    muteMovement(4000)                       -- warp during a jump
                elseif d > (th.SuperJump or 20.0) then
                    flag('superjump', ('jump displacement %.1fm'):format(d))
                end
            end
        end
    end)

    -- on-foot speedhack: require the OVER-SPEED to PERSIST across consecutive
    -- samples. A single high reading is a warp/animation glitch; a cheat holds.
    CreateThread(function()
        local streak = 0
        while true do
            Wait(400)
            local ped = PlayerPedId()
            if movementMuted() then
                streak = 0
            elseif not IsPedInAnyVehicle(ped, false) and not IsPedRagdoll(ped)
               and not IsPedFalling(ped) and not IsPedJumping(ped)
               and not IsPedGettingUp(ped) then
                local spd = GetEntitySpeed(ped)
                if spd > (th.MaxFootSpeed or 13.0) and spd < (th.FootSpeedCeil or 60.0) then
                    streak = streak + 1
                    if streak >= (th.SpeedSamples or 4) then      -- ~1.6s sustained
                        flag('speedhack', ('on-foot %.1f m/s sustained x%d'):format(spd, streak))
                        streak = 0
                    end
                else
                    streak = 0
                end
            else
                streak = 0
            end
        end
    end)

    -- godmode + invisibility detections are DISABLED by default: GetPlayerInvincible
    -- and invisibility are set legitimately during spawn protection, revives,
    -- cutscenes and interior transitions, so they only produce false positives.
    -- Enable via Config.Anticheat.Detect.Godmode / .Invisible if ever needed.
    if AC.Detect and AC.Detect.Godmode then
        CreateThread(function()
            local streak = 0
            while true do
                Wait(3000)
                if not movementMuted() and GetPlayerInvincible(PlayerId()) then
                    streak = streak + 1
                    if streak >= 4 then flag('godmode', 'invincible sustained ~12s'); streak = 0 end
                else streak = 0 end
            end
        end)
    end

    -- night / thermal vision outside a heli (kept — genuinely cheat-only)
    CreateThread(function()
        while true do
            Wait(2500)
            local ped = PlayerPedId()
            if not IsPedInAnyHeli(ped) then
                if GetUsingnightvision and GetUsingnightvision(true) then flag('nightvision', 'nightvision active') end
                if GetUsingseethrough and GetUsingseethrough(true) then flag('thermal', 'thermal vision active') end
            end
        end
    end)

    -- noclip: the old version flagged ANY big per-tick jump, so every teleport
    -- (apartment/garage/interior warp, admin TP, spawn) tripped it. Real noclip
    -- is SUSTAINED movement through the air with no ground/vehicle. So:
    --   * a single spike >= TeleportFloor  -> it's a warp: mute + reset, no flag
    --   * otherwise require several CONSECUTIVE ticks of fast off-ground travel
    CreateThread(function()
        local prev = GetEntityCoords(PlayerPedId())
        local streak = 0
        while true do
            Wait(1000)
            local ped = PlayerPedId()
            local cur = GetEntityCoords(ped)
            local moved = #(cur - prev)
            prev = cur

            if moved >= (th.TeleportFloor or 150.0) then
                -- one huge jump = teleport. Mute, reset, never flag.
                muteMovement(4000)
                streak = 0
            elseif movementMuted() then
                streak = 0
            elseif not IsPedInAnyVehicle(ped, false) and not IsPedRagdoll(ped)
               and not IsPedFalling(ped) and not IsPedGettingUp(ped)
               and moved > (th.MaxTickMove or 45.0) then
                -- fast on-foot travel below the teleport floor, sustained: a human
                -- sprints ~7 m/s, so 45 m/s held for several seconds is not legit.
                streak = streak + 1
                if streak >= (th.NoclipSamples or 3) then       -- ~3s sustained
                    flag('noclip', ('sustained on-foot %.0fm/s x%d'):format(moved, streak))
                    streak = 0
                end
            else
                streak = 0
            end
        end
    end)

    -- blacklisted spawned plate (from Config.Anticheat.BlacklistedPlates)
    if AC.BlacklistedPlates and #AC.BlacklistedPlates > 0 then
        CreateThread(function()
            while true do
                Wait(2000)
                local ped = PlayerPedId()
                if IsPedInAnyVehicle(ped, false) then
                    local v = GetVehiclePedIsIn(ped, false)
                    if GetPedInVehicleSeat(v, -1) == ped then
                        local plate = (GetVehicleNumberPlateText(v) or ''):gsub('%s+$', '')
                        for _, bad in ipairs(AC.BlacklistedPlates) do
                            if plate == bad then flag('badplate', 'spawned plate ' .. bad) end
                        end
                    end
                end
            end
        end)
    end
end
