-- hk-hud — client (Phase 1: player status icons)
-- Reads the same native/statebag sources ps-hud used and renders status icons
-- in our own NUI. Honors ps-hud's external event contract so ambulance job,
-- consumables, buffs, nitro, harness, etc. keep driving the HUD.

local QBCore = exports['qb-core']:GetCoreObject()

-- Master HUD render switch (F5 settings only). Persisted in KVP
-- 'hk-hud:hudEnabled'. When off, the whole status HUD + minimap are hidden.
local KVP_ENABLED = 'hk-hud:hudEnabled'
local hudEnabled = GetResourceKvpString(KVP_ENABLED) ~= 'off'  -- default ON

-- Cinematic black bars (top+bottom letterbox). Persisted in KVP
-- 'hk-hud:cinematic'. Default OFF. Set from F5 settings.
local KVP_CINEMATIC = 'hk-hud:cinematic'
local cinematicOn = GetResourceKvpString(KVP_CINEMATIC) == 'on'
local cinematicH = 0.0   -- animated bar height (0 → 0.1 target)

-- Minimap settings (Phase 2). Persisted in KVP 'hk-hud:minimap' as JSON.
local KVP_MINIMAP = 'hk-hud:minimap'
local mapCfg = {
    shape  = HKHudConfig.Minimap.shape,
    onFoot = HKHudConfig.Minimap.onFoot,
    notify = HKHudConfig.Minimap.notify,
}
do
    local raw = GetResourceKvpString(KVP_MINIMAP)
    if raw and raw ~= '' then
        local ok, t = pcall(json.decode, raw)
        if ok and type(t) == 'table' then
            for k, v in pairs(t) do mapCfg[k] = v end
        end
    end
end

-- Compass settings (Phase 2). Persisted in KVP 'hk-hud:compass' as JSON.
local KVP_COMPASS = 'hk-hud:compass'
local compassCfg = {
    show      = HKHudConfig.Compass.show,
    onFoot    = HKHudConfig.Compass.onFoot,
    follow    = HKHudConfig.Compass.follow,
    streets   = HKHudConfig.Compass.streets,
    pointer   = HKHudConfig.Compass.pointer,
    degrees   = HKHudConfig.Compass.degrees,
    optimized = HKHudConfig.Compass.optimized,
}
do
    local raw = GetResourceKvpString(KVP_COMPASS)
    if raw and raw ~= '' then
        local ok, t = pcall(json.decode, raw)
        if ok and type(t) == 'table' then
            for k, v in pairs(t) do compassCfg[k] = v end
        end
    end
end

-- ---- Live state (mirrors ps-hud's locals) ---------------------------------
local PlayerData = {}
local serverId = GetPlayerServerId(PlayerId())

local stress   = 0
local hunger   = 100
local thirst   = 100
local oxygen   = 100
local hp       = 0        -- engine health % (vehicle), via EngineHealth event
local nos      = 0
local nitroActive = 0
local nosPurge = false    -- NOS purging (hk_nosPurgeMode statebag, [HK EDIT] in Jim)
local harness  = 0
local seatbeltOn  = false
local cruiseOn    = false
local radioTalking = false
local showAltitude = false

-- ---- ps-hud EVENT CONTRACT (other resources fire these) -------------------
-- Keep these names identical to ps-hud so external callers keep working.

RegisterNetEvent('hud:client:UpdateStress', function(newStress) stress = newStress or 0 end)
RegisterNetEvent('hud:client:UpdateNeeds', function(newHunger, newThirst)
    hunger = newHunger or hunger
    thirst = newThirst or thirst
end)
-- jim-mechanic fires this with LEVEL FIRST (not hasNitro), in two shapes:
--   UpdateNitrous(level, toggle)                  -- when a qb-hud is present
--   UpdateNitrous(level, hasNitro, toggle)        -- otherwise
-- The old handler read level from arg #2, so NOS always showed 0/garbage.
-- Disambiguate the same way hk-speedo does (3rd arg present = long form).
RegisterNetEvent('hud:client:UpdateNitrous', function(level, hasNitroOrToggle, toggleOrNil)
    nos = level or 0
    if toggleOrNil ~= nil then
        nitroActive = toggleOrNil and 1 or 0
    else
        nitroActive = hasNitroOrToggle and 1 or 0
    end
end)
RegisterNetEvent('hud:client:UpdateHarness', function(harnessHp) harness = harnessHp or 0 end)
RegisterNetEvent('hud:client:EngineHealth', function(newEngine) hp = newEngine or hp end)
RegisterNetEvent('hud:client:ToggleShowSeatbelt', function() seatbeltOn = not seatbeltOn end)
RegisterNetEvent('hud:client:ToggleAirHud', function() showAltitude = not showAltitude end)
RegisterNetEvent('seatbelt:client:ToggleSeatbelt', function() seatbeltOn = not seatbeltOn end)
RegisterNetEvent('seatbelt:client:ToggleCruise', function() cruiseOn = not cruiseOn end)
AddEventHandler('pma-voice:radioActive', function(isRadioTalking) radioTalking = isRadioTalking end)

-- External buff / enhancement status icons (ps-hud contract). No resource on
-- this server currently fires these, but we keep the API alive: forward the
-- data to the NUI's external-status renderer (temporary buff/enhancement pills).
RegisterNetEvent('hud:client:BuffEffect', function(data)
    if type(data) ~= 'table' then return end
    SendNUIMessage({ action = 'externalstatus', topic = 'buff', data = data })
end)
RegisterNetEvent('hud:client:EnhancementEffect', function(data)
    if type(data) ~= 'table' then return end
    SendNUIMessage({ action = 'externalstatus', topic = 'enhancement', data = data })
end)

-- Statebag mirrors (qb-core writes these) — same as ps-hud.
AddStateBagChangeHandler('hunger', ('player:%s'):format(serverId), function(_, _, v) if v then hunger = v end end)
AddStateBagChangeHandler('thirst', ('player:%s'):format(serverId), function(_, _, v) if v then thirst = v end end)
AddStateBagChangeHandler('stress', ('player:%s'):format(serverId), function(_, _, v) if v then stress = v end end)
-- NOS purge mode ([HK EDIT] in jim-mechanic; same source hk-speedo reads). Bag
-- filter uses nil + a local-player check since serverId can change on reconnect.
AddStateBagChangeHandler('hk_nosPurgeMode', nil, function(bagName, _, value)
    if bagName ~= ('player:%s'):format(GetPlayerServerId(PlayerId())) then return end
    nosPurge = value and true or false
end)

-- hudActive gates ALL display: only true once a character is selected + spawned
-- (OnPlayerLoaded), so the map/status never show during loading or on the
-- qb-multicharacter selection screen. `isLoggedIn` alone flips too early.
local hudActive = false

-- dbgHidden: true while hk-handling's /handlingdbg native overlay is up. That
-- overlay is DrawText (renders BEHIND CEF/NUI), so we hide the HUD + minimap to
-- keep its bottom-left/right columns readable. Driven by the hk_handlingdbg bag.
local dbgHidden = false
AddStateBagChangeHandler('hk_handlingdbg', nil, function(bagName, _, value)
    if bagName ~= ('player:%s'):format(GetPlayerServerId(PlayerId())) then return end
    dbgHidden = value and true or false
end)

RegisterNetEvent('QBCore:Client:OnPlayerLoaded', function()
    PlayerData = QBCore.Functions.GetPlayerData()
    serverId = GetPlayerServerId(PlayerId())
    hudActive = true
end)

RegisterNetEvent('QBCore:Client:OnPlayerUnload', function()
    hudActive = false
end)
RegisterNetEvent('QBCore:Player:SetPlayerData', function(val) PlayerData = val end)

-- Script-restart recovery: OnPlayerLoaded only fires on spawn/join, NOT on a
-- resource restart. If the player is ALREADY logged in when hk-hud (re)starts,
-- activate immediately so restarting the script doesn't kill the HUD forever.
CreateThread(function()
    Wait(500)
    if LocalPlayer.state.isLoggedIn then
        PlayerData = QBCore.Functions.GetPlayerData()
        serverId = GetPlayerServerId(PlayerId())
        hudActive = true
    end
end)

-- /cash /bank popup (hud:client:ShowAccounts) — shows the current balance.
RegisterNetEvent('hud:client:ShowAccounts', function(kind, amount)
    SendNUIMessage({ action = 'money', kind = kind, amount = amount })
end)

-- Auto money-change popup: qb-core fires hud:client:OnMoneyChange on every
-- add/remove/set (payouts, purchases, transfers…). Show a +/- popup with the
-- new balance. NOTE: qb fires this BEFORE PlayerData re-syncs, so apply the
-- delta ourselves for an accurate balance (ps-hud does the same).
RegisterNetEvent('hud:client:OnMoneyChange', function(kind, amount, isMinus)
    -- always track the balance so the widget stays accurate…
    if PlayerData.money and PlayerData.money[kind] ~= nil then
        PlayerData.money[kind] = PlayerData.money[kind] + (isMinus and -amount or amount)
    end
    if not hudEnabled then return end     -- …but only pop up when the HUD is on
    if kind == 'cash' and amount == 0 then return end
    SendNUIMessage({
        action  = 'moneychange',
        kind    = kind,
        amount  = amount,
        minus   = isMinus and true or false,
        balance = (PlayerData.money and PlayerData.money[kind]) or nil,
    })
end)


-- ---- Hide native GTA HUD components ---------------------------------------
-- hk-hud renders its own health/armor, so hide GTA's native bars around the
-- minimap (ps-hud used to do this; it's now [unused]). Component IDs:
--   3 = HUD_HEALTH_BAR, 4 = HUD_ARMOUR_BAR. (Keep the rest — qb-smallresources
--   handles the wider set; we only guarantee OUR bars aren't duplicated.)
CreateThread(function()
    while true do
        HideHudComponentThisFrame(3)  -- health
        HideHudComponentThisFrame(4)  -- armor
        Wait(0)
    end
end)

-- ---- Minimap reshape (circle/square) — ported from ps-hud LoadMap ----------
-- Uses the streamed masks in stream/ (circlemap.ytd / squaremap.ytd). Reshapes
-- the native minimap + repositions its components. Call whenever shape changes.
local function loadMap()
    if not HKHudConfig.Minimap.enabled then return end
    Wait(50)
    local defaultAspect = 1920 / 1080
    local rx, ry = GetActiveScreenResolution()
    local aspect = rx / ry
    local off = 0
    if aspect > defaultAspect then off = ((defaultAspect - aspect) / 3.6) - 0.008 end

    if mapCfg.shape == 'square' then
        RequestStreamedTextureDict('squaremap', false)
        if not HasStreamedTextureDictLoaded('squaremap') then Wait(150) end
        SetMinimapClipType(0)
        AddReplaceTexture('platform:/textures/graphics', 'radarmasksm', 'squaremap', 'radarmasksm')
        AddReplaceTexture('platform:/textures/graphics', 'radarmask1g', 'squaremap', 'radarmasksm')
        SetMinimapComponentPosition('minimap', 'L', 'B', 0.0 + off, -0.047, 0.1638, 0.183)
        SetMinimapComponentPosition('minimap_mask', 'L', 'B', 0.0 + off, 0.0, 0.128, 0.20)
        SetMinimapComponentPosition('minimap_blur', 'L', 'B', -0.01 + off, 0.025, 0.262, 0.300)
        SetBlipAlpha(GetNorthRadarBlip(), 255)  -- keep the native N (north) marker visible
        SetRadarBigmapEnabled(true, false)
        SetMinimapClipType(0)
        Wait(50)
        SetRadarBigmapEnabled(false, false)
    else -- circle
        RequestStreamedTextureDict('circlemap', false)
        if not HasStreamedTextureDictLoaded('circlemap') then Wait(150) end
        SetMinimapClipType(1)
        AddReplaceTexture('platform:/textures/graphics', 'radarmasksm', 'circlemap', 'radarmasksm')
        AddReplaceTexture('platform:/textures/graphics', 'radarmask1g', 'circlemap', 'radarmasksm')
        SetMinimapComponentPosition('minimap', 'L', 'B', -0.0100 + off, -0.030, 0.180, 0.258)
        SetMinimapComponentPosition('minimap_mask', 'L', 'B', 0.200 + off, 0.0, 0.065, 0.20)
        SetMinimapComponentPosition('minimap_blur', 'L', 'B', -0.00 + off, 0.015, 0.252, 0.338)
        SetBlipAlpha(GetNorthRadarBlip(), 255)  -- keep the native N (north) marker visible
        SetMinimapClipType(1)
        SetRadarBigmapEnabled(true, false)
        Wait(50)
        SetRadarBigmapEnabled(false, false)
    end
end
RegisterNetEvent('hud:client:LoadMap', loadMap)   -- keep ps-hud contract name too

-- Radar control: hidden until spawned in + master switch on. On foot the map
-- shows only if mapCfg.onFoot; in a vehicle it always shows.
CreateThread(function()
    while true do
        local baseOn = hudActive and hudEnabled and HKHudConfig.Minimap.enabled and not dbgHidden
        local inVeh = baseOn and IsPedInAnyVehicle(PlayerPedId(), false)
        local visible = baseOn and (inVeh or mapCfg.onFoot)
        DisplayRadar(visible)
        -- Circle mode reads as too zoomed-in (bigger minimap component); pull the
        -- radar out. SetRadarZoom persists, so setting it each tick is enough.
        -- Higher = wider view. Only in circle; square keeps GTA's default zoom.
        if visible and mapCfg.shape == 'circle' then
            local z = HKHudConfig.Minimap.circleZoom or 0
            if z > 0 then SetRadarZoom(z) end
        end
        Wait(visible and 800 or 250)
    end
end)

-- Apply the map shape once we're spawned in (and on shape change).
CreateThread(function()
    while not hudActive do Wait(500) end
    Wait(1000)
    loadMap()
end)

-- Nudge the GTA native notification feed up off the minimap (config-gated, OFF by
-- default). THEFEED_SET_SCRIPTED_MENU_HEIGHT resets every frame, so re-apply in a
-- per-frame loop only while a value is set — otherwise sleep cheaply and touch nothing.
CreateThread(function()
    while true do
        local h = HKHudConfig.Minimap.feedHeight
        if h then
            -- pcall-guarded: wrapper name unverified, and this fires every frame.
            pcall(ThefeedSetScriptedMenuHeight, h + 0.0)
            Wait(0)
        else
            Wait(2000)
        end
    end
end)

-- ---- Compass (Phase 2) — top-centre heading bar ---------------------------
-- Sends heading (0..360) + current streets to the NUI, which pans a degree bar.
-- Ported from ps-hud: follow-cam vs ped heading, street crossroads cache.
local function round(n) return math.floor(n + 0.5) end
local crossCacheT, crossCache = 0, { '', '' }
local function getCrossroads(ped)
    local now = GetGameTimer()
    if now - crossCacheT > 3000 then
        local p = GetEntityCoords(ped)
        local s1, s2 = GetStreetNameAtCoord(p.x, p.y, p.z)
        crossCache = { GetStreetNameFromHashKey(s1), GetStreetNameFromHashKey(s2) }
        crossCacheT = now
    end
    return crossCache
end

CreateThread(function()
    local lastHeading, lastShown = nil, nil
    while true do
        local baseOn = hudActive and hudEnabled and HKHudConfig.Compass.enabled and compassCfg.show
        if not baseOn then
            if lastShown ~= false then
                SendNUIMessage({ action = 'compass', show = false })
                lastShown = false
            end
            Wait(300)
        else
            local ped = PlayerPedId()
            local inVeh = IsPedInAnyVehicle(ped, false)
            local visible = inVeh or compassCfg.onFoot
            if not visible then
                if lastShown ~= false then
                    SendNUIMessage({ action = 'compass', show = false })
                    lastShown = false
                end
                Wait(250)
            else
                local heading
                if compassCfg.follow then
                    local cam = GetGameplayCamRot(0)
                    heading = round(360.0 - ((cam.z + 360.0) % 360.0))
                else
                    heading = round(360.0 - GetEntityHeading(ped))
                end
                if heading >= 360 then heading = 0 end

                if heading ~= lastHeading or lastShown ~= true then
                    local cr = compassCfg.streets and getCrossroads(ped) or { '', '' }
                    SendNUIMessage({
                        action  = 'compass',
                        show    = true,
                        heading = heading,
                        street1 = cr[1] or '',
                        street2 = cr[2] or '',
                        streets = compassCfg.streets,
                        pointer = compassCfg.pointer,
                        degrees = compassCfg.degrees,
                        -- optimized = slow tick + CSS-tween smoothing (low FPS cost)
                        smooth  = compassCfg.optimized and true or false,
                    })
                    lastHeading, lastShown = heading, true
                end
                -- Optimized: slow tick (ps-hud style), NUI tweens between updates.
                -- Not optimized: fast tick for buttery-smooth (heavier).
                Wait(compassCfg.optimized and (HKHudConfig.Compass.tickSlow or 250)
                    or (HKHudConfig.Compass.tickFast or 40))
            end
        end
    end
end)

-- ---- Main tick ------------------------------------------------------------
-- Produces a flat status table each tick and sends it to the NUI. The NUI
-- decides per-icon visibility/theme from the player's saved settings; here we
-- only compute raw values + a `show`/`inVehicle` context.
CreateThread(function()
    while true do
        Wait(HKHudConfig.Tick or 250)
        if not hudActive or not hudEnabled or dbgHidden then
            -- hidden until spawned in AND the master switch is on. Also hidden while
            -- hk-handling's /handlingdbg native overlay is up (it renders behind NUI).
            SendNUIMessage({ action = 'hide' })
            goto continue
        end

        local ped      = PlayerPedId()
        local playerId = PlayerId()
        local inVeh    = IsPedInAnyVehicle(ped, false)
        local veh      = inVeh and GetVehiclePedIsIn(ped, false) or 0
        local realVeh  = inVeh and not IsThisModelABicycle(GetEntityModel(veh))

        -- Stamina / oxygen
        if IsEntityInWater(ped) then
            oxygen = math.floor(GetPlayerUnderwaterTimeRemaining(playerId) * 10)
        else
            oxygen = math.floor(100 - GetPlayerSprintStaminaRemaining(playerId))
        end
        if oxygen < 0 then oxygen = 0 elseif oxygen > 100 then oxygen = 100 end

        -- Voice + talking. pma-voice's `proximity` statebag has `index` (voice
        -- MODE: 1=whisper, 2=normal, 3=shout) and `distance` (metres, which vary
        -- with voice_useNativeAudio). We send the mode as a 0..100 ring fill
        -- (1→33, 2→66, 3→100) so it's independent of the raw distance values —
        -- ps-hud's ×16.6 on distance over-filled "normal" on native-audio configs.
        local talking = NetworkIsPlayerTalking(playerId)
        local prox = LocalPlayer.state['proximity']
        local voiceIdx = (prox and prox.index) or 2
        local voiceMax = 3
        local voicePct = math.floor((voiceIdx / voiceMax) * 100 + 0.5)
        local radioChannel = LocalPlayer.state['radioChannel'] or 0

        local dead = IsEntityDead(ped)
            or (PlayerData.metadata and (PlayerData.metadata['inlaststand'] or PlayerData.metadata['isdead']))
            or false
        local parachute = GetPedParachuteState(ped)  -- -1 none, 0 has, >0 deploying

        -- engine health % = GetVehicleEngineHealth/10 (ps-hud). -1 when on foot.
        local engine = realVeh and (GetVehicleEngineHealth(veh) / 10) or -1

        -- Send the SAME flat fields ps-hud's NUI consumes (1:1 with its contract).
        local payload = {
            action    = 'status',
            show      = not IsPauseMenuActive(),
            inVehicle = realVeh and true or false,
            debugAll  = HKHudConfig.DebugAllIcons and true or false,
            data = {
                health    = GetEntityHealth(ped) - 100,   -- 0..100 (qb offset)
                dead      = dead,
                armor     = GetPedArmour(ped),             -- 0..100
                hunger    = math.floor(hunger),
                thirst    = math.floor(thirst),
                stress    = math.floor(stress),
                oxygen    = oxygen,
                voice     = voicePct,                      -- 0..100 already (mode-based)
                radioChannel = radioChannel,
                talking   = talking,
                radioTalking = radioTalking,
                parachute = parachute,                     -- -1/0/1+
                -- vehicle-context (only meaningful in a real vehicle)
                engine    = engine,                        -- %/10, -1 on foot
                nos       = nos,                           -- nitro amount
                nitroActive = nitroActive,                 -- bool/int (boosting)
                nosPurge  = nosPurge,                      -- true while purging
                harness   = harness,                       -- truthy = worn
                cruise    = realVeh and cruiseOn or false,
                -- seatbelt field dropped from NUI (hk-speedo shows it); the
                -- Toggle* handlers stay for the ps-hud event contract.
            },
        }
        SendNUIMessage(payload)

        ::continue::
    end
end)

-- ---- Stress generation (ported from ps-hud, which is retired) -------------
-- Speeding: over the threshold in a stress-eligible vehicle class → GainStress.
CreateThread(function()
    local S = HKHudConfig.Stress
    if not (S and S.enabled) then return end
    local kmh = 3.6  -- GetEntitySpeed is m/s
    while true do
        Wait(10000)
        if hudActive then
            local ped = PlayerPedId()
            if IsPedInAnyVehicle(ped, false) then
                local veh = GetVehiclePedIsIn(ped, false)
                local speed = GetEntitySpeed(veh) * kmh
                local threshold = seatbeltOn and S.minSpeed or S.minSpeedUnbuckled
                local class = GetVehicleClass(veh)
                if S.vehClass[tostring(class)] and speed >= threshold then
                    -- driveStressMult chance-gates the fire so driving stress is reduced (0.5 = 50% less)
                    if math.random() < (S.driveStressMult or 1.0) then
                        TriggerServerEvent('hud:server:GainStress', math.random(1, 3))
                    end
                end
            end
        end
    end
end)

-- Shooting: chance to gain stress per shot.
CreateThread(function()
    local S = HKHudConfig.Stress
    if not (S and S.enabled) then return end
    while true do
        local ped = PlayerPedId()
        if hudActive and IsPedShooting(ped) then
            if math.random() < S.shootChance then
                TriggerServerEvent('hud:server:GainStress', math.random(1, 3))
            end
            Wait(150)
        else
            Wait(500)
        end
    end
end)

-- ---- Seatbelt alarm: intentionally NOT handled here -----------------------
-- jim-mechanic already plays its own belt sound and hk-speedo owns the seatbelt
-- indicator. A beep loop here beeped every ~1.5s forever because hk-hud never
-- gets the authoritative buckled state (that lives in mechanic/hk-speedo).

-- ---- Stress screen-blur effect (ps-hud style) -----------------------------
local function pickRange(tbl, v)
    for _, r in ipairs(tbl) do if v >= r.min and v <= r.max then return r.ms end end
    return nil
end
CreateThread(function()
    local S = HKHudConfig.Stress
    while true do
        local interval = 60000
        if hudActive and S and S.enabled then
            local st = stress or 0
            if st >= (S.effectMinStress or 50) then
                interval = pickRange(S.effectInterval, st) or 45000
                local blurMs = pickRange(S.blur, st) or 1500
                TriggerScreenblurFadeIn(1000.0)
                Wait(blurMs)
                TriggerScreenblurFadeOut(1000.0)
            end
        end
        Wait(interval)
    end
end)

-- ---- Per-player settings (KVP) --------------------------------------------
-- Stored: { theme = 'hk'|'legacy', icons = { [id] = {show=bool, color='#hex'} } }
local KVP_SETTINGS = 'hk-hud:settings'

local function readSettings()
    local raw = GetResourceKvpString(KVP_SETTINGS)
    if not raw or raw == '' then return {} end
    local ok, t = pcall(json.decode, raw)
    return (ok and type(t) == 'table') and t or {}
end

local function saveSettings(t)
    SetResourceKvp(KVP_SETTINGS, json.encode(t))
end

-- Build the config + saved-settings bundle the NUI needs to render + theme.
-- Merge saved crosshair overrides over the config defaults.
local function crosshairSettings(s)
    local d = {}
    for k, v in pairs(HKHudConfig.Crosshair.defaults) do d[k] = v end
    for k, v in pairs(s.crosshair or {}) do d[k] = v end
    if s.crosshairEnabled ~= nil then
        d.enabled = s.crosshairEnabled
    else
        d.enabled = HKHudConfig.Crosshair.enabled
    end
    return d
end

local function pushSettings()
    local s = readSettings()
    SendNUIMessage({
        action   = 'settings',
        icons    = HKHudConfig.Icons,
        themes   = HKHudConfig.Themes,
        warnBelow = HKHudConfig.WarnBelow,
        statusPos = HKHudConfig.StatusPos,
        theme    = s.theme or HKHudConfig.DefaultTheme,
        saved    = s.icons or {},
        -- crosshair config + current values
        crosshair = {
            styles   = HKHudConfig.Crosshair.styles,
            defaults = HKHudConfig.Crosshair.defaults,
            current  = crosshairSettings(s),
        },
    })
end

-- ---- Master HUD toggle (Settings-only, no keybind) ------------------------
local function setHudEnabled(on)
    hudEnabled = on and true or false
    SetResourceKvp(KVP_ENABLED, hudEnabled and 'on' or 'off')
    if not hudEnabled then SendNUIMessage({ action = 'hide' }) end
end

exports('setHudEnabled', function(on) setHudEnabled(on) end)
exports('isHudEnabled', function() return hudEnabled end)

-- ---- Cinematic black bars -------------------------------------------------
local function setCinematic(on)
    cinematicOn = on and true or false
    SetResourceKvp(KVP_CINEMATIC, cinematicOn and 'on' or 'off')
end
exports('setCinematic', function(on) setCinematic(on) end)
exports('isCinematic', function() return cinematicOn end)

-- ---- Minimap settings (F5 settings drives these) --------------------------
local function saveMap() SetResourceKvp(KVP_MINIMAP, json.encode(mapCfg)) end
exports('setMinimap', function(key, value)
    if key == 'shape' then
        mapCfg.shape = (value == 'square') and 'square' or 'circle'
        saveMap(); loadMap()
    elseif key == 'onFoot' then
        mapCfg.onFoot = value and true or false
        saveMap()   -- radar thread picks it up next tick
    end
end)
exports('getMinimapUI', function()
    return { shape = mapCfg.shape, onFoot = mapCfg.onFoot }
end)

-- ---- Compass settings (F5 settings drives these) --------------------------
local COMPASS_KEYS = { show=true, onFoot=true, follow=true, streets=true, pointer=true, degrees=true, optimized=true }
exports('setCompass', function(key, value)
    if COMPASS_KEYS[key] then
        compassCfg[key] = value and true or false
        SetResourceKvp(KVP_COMPASS, json.encode(compassCfg))
    end
end)
exports('getCompassUI', function()
    return {
        show = compassCfg.show, onFoot = compassCfg.onFoot, follow = compassCfg.follow,
        streets = compassCfg.streets, pointer = compassCfg.pointer, degrees = compassCfg.degrees,
        optimized = compassCfg.optimized,
    }
end)

-- Draw the letterbox bars every frame while on; height eases in/out.
CreateThread(function()
    local target = 0.10   -- bar height (fraction of screen) when active
    while true do
        local want = (cinematicOn and hudActive) and target or 0.0
        if cinematicH < want then cinematicH = math.min(want, cinematicH + 0.01)
        elseif cinematicH > want then cinematicH = math.max(want, cinematicH - 0.01) end
        if cinematicH > 0.001 then
            DrawRect(0.0, 0.0, 2.0, cinematicH, 0, 0, 0, 255)          -- top
            DrawRect(0.0, 1.0, 2.0, cinematicH, 0, 0, 0, 255)          -- bottom
            Wait(0)
        else
            Wait(200)
        end
    end
end)

-- exports for hk-hub's settings panel to drive us (Phase 3 wiring).
exports('getSettings', function() return readSettings() end)

exports('setTheme', function(theme)
    local s = readSettings()
    s.theme = theme
    saveSettings(s)
    pushSettings()
end)

exports('setIcon', function(id, opts)
    local s = readSettings()
    s.icons = s.icons or {}
    s.icons[id] = s.icons[id] or {}
    if opts.show ~= nil then s.icons[id].show = opts.show and true or false end
    if opts.color ~= nil then s.icons[id].color = opts.color end
    -- mode: 'always' | 'dynamic' | 'hidden' (ps-hud-style display mode)
    if opts.mode ~= nil then s.icons[id].mode = opts.mode end
    saveSettings(s)
    pushSettings()
end)

-- Reset ALL hk-hud per-player settings to defaults: icons/theme/crosshair,
-- minimap, compass, cinematic, and the master enable. Wipes every KVP key,
-- restores the in-memory tables, and re-applies live.
exports('resetSettings', function()
    SetResourceKvp(KVP_SETTINGS, '{}')
    SetResourceKvp(KVP_MINIMAP, '{}')
    SetResourceKvp(KVP_COMPASS, '{}')
    SetResourceKvp(KVP_CINEMATIC, 'off')
    SetResourceKvp(KVP_ENABLED, 'on')

    -- restore in-memory tables from config defaults
    hudEnabled  = true
    cinematicOn = false
    mapCfg.shape  = HKHudConfig.Minimap.shape
    mapCfg.onFoot = HKHudConfig.Minimap.onFoot
    for k, v in pairs({ show=HKHudConfig.Compass.show, onFoot=HKHudConfig.Compass.onFoot,
        follow=HKHudConfig.Compass.follow, streets=HKHudConfig.Compass.streets,
        pointer=HKHudConfig.Compass.pointer, degrees=HKHudConfig.Compass.degrees,
        optimized=HKHudConfig.Compass.optimized }) do compassCfg[k] = v end

    pushSettings()
    loadMap()   -- re-apply default minimap shape
end)

-- Bundle for hk-hub's HUD settings tab: icon list (with dynamic/modeDefault) +
-- the player's saved per-icon overrides (mode/color).
exports('getIconsUI', function()
    local s = readSettings()
    return {
        icons   = HKHudConfig.Icons,
        themes  = HKHudConfig.Themes,
        theme   = s.theme or HKHudConfig.DefaultTheme,
        saved   = s.icons or {},
        enabled = hudEnabled,
        cinematic = cinematicOn,
    }
end)

-- ---- Crosshair settings exports (hk-hub Settings tab drives these) --------
exports('setCrosshairEnabled', function(on)
    local s = readSettings()
    s.crosshairEnabled = on and true or false
    saveSettings(s)
    pushSettings()
end)

exports('setCrosshair', function(key, value)
    local s = readSettings()
    s.crosshair = s.crosshair or {}
    -- only accept known keys
    if HKHudConfig.Crosshair.defaults[key] ~= nil then
        s.crosshair[key] = value
        saveSettings(s)
        pushSettings()
    end
end)

-- Bundle for hk-hub's Settings tab: styles + current values + defaults.
exports('getCrosshairUI', function()
    return {
        styles   = HKHudConfig.Crosshair.styles,
        defaults = HKHudConfig.Crosshair.defaults,
        current  = crosshairSettings(readSettings()),
    }
end)

-- ---- Crosshair aim-watch loop ---------------------------------------------
-- Push crosshair state to the NUI: visible only while free-aiming a weapon
-- (hold RMB), and whether currently aimed at a ped (dynamic on-target shrink).
CreateThread(function()
    local pid = PlayerId()
    local lastAiming, lastOnTarget = nil, nil
    while true do
        local enabled = crosshairSettings(readSettings()).enabled
        if not enabled then
            if lastAiming ~= false then
                SendNUIMessage({ action = 'crosshair', show = false })
                lastAiming = false; lastOnTarget = nil
            end
            Wait(400)
        else
            pid = PlayerId()
            local aiming = IsPlayerFreeAiming(pid)
            if aiming then
                -- on-target: aiming at a ped/player entity
                local hit, entity = GetEntityPlayerIsFreeAimingAt(pid)
                local onTarget = hit and entity and entity ~= 0 and IsEntityAPed(entity) and not IsPedDeadOrDying(entity, true)
                if aiming ~= lastAiming or onTarget ~= lastOnTarget then
                    SendNUIMessage({ action = 'crosshair', show = true, onTarget = onTarget and true or false })
                    lastAiming = aiming; lastOnTarget = onTarget
                end
                Wait(0)   -- responsive while aiming
            else
                if lastAiming ~= false then
                    SendNUIMessage({ action = 'crosshair', show = false })
                    lastAiming = false; lastOnTarget = nil
                end
                Wait(150)
            end
        end
    end
end)

-- Push settings/theme to the NUI on load.
CreateThread(function()
    while not LocalPlayer.state.isLoggedIn do Wait(500) end
    Wait(500)
    pushSettings()
end)
AddEventHandler('onResourceStart', function(res)
    if res == GetCurrentResourceName() then Wait(500); pushSettings() end
end)


