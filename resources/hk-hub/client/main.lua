-- hk-hub — client
-- Branded launcher on F5. Opens a NUI grid of systems; picking one closes the
-- hub and fires that system's own command (ExecuteCommand), so the player never
-- has to type the command themselves.

local isOpen = false
local QBCore = nil

-- ---- Rolling event log (for bug reports) ----------------------------------
-- FiveM resources can't read the F8 console/game logs, so instead any HK
-- resource can push a short breadcrumb here via TriggerEvent('hk-hub:client:log',
-- tag, message). We keep the last N and attach them to a bug report.
local LOG_MAX = 40
local eventLog = {}   -- array of { t = uptime-ms, tag = str, msg = str }

local function pushLog(tag, msg)
    eventLog[#eventLog + 1] = {
        t = GetGameTimer(),
        tag = tostring(tag or '?'),
        msg = tostring(msg or ''),
    }
    -- Trim from the front once we exceed the cap.
    while #eventLog > LOG_MAX do table.remove(eventLog, 1) end
end

RegisterNetEvent('hk-hub:client:log', function(tag, msg) pushLog(tag, msg) end)

-- ---- Preferences (per-user, KVP-backed) -----------------------------------

local KVP_OPTI = 'hk-hub:optimizerMode'

local function optimizerReady()
    return GetResourceState('hk-optimizer') == 'started'
end

-- Read the saved optimizer mode (falls back to config default).
local function savedOptimizerMode()
    local s = HubConfig.Settings or {}
    local o = s.optimizer or {}
    return GetResourceKvpString(KVP_OPTI) or o.default or 'quality'
end

-- Apply a mode via hk-optimizer's export and persist the choice.
local function applyOptimizerMode(name)
    if not optimizerReady() then return nil end
    local applied = exports['hk-optimizer']:applyMode(name)
    SetResourceKvp(KVP_OPTI, applied or name)
    return applied or name
end

-- (Removed the ps-hud HUD bridge: KVP stores, psHudReady, applyMenu/applyIcons,
--  iconColorEffects/buildIconPayload, live-state listener. ps-hud is retired;
--  hk-hud owns the HUD and hk-hub drives it via the hk-hud exports.)

-- Runtime tile-visibility gates (config item field `gate` = a key here). Each
-- returns true if the tile should be shown for this player right now. Guard every
-- external call so a stopped/updated dependency just hides the tile, never errors.
local GATES = {
    -- Dispatch: only for players whose job may actually use ps-dispatch. We defer
    -- entirely to ps-dispatch's own gating (job list + on-duty) via its export.
    dispatch = function()
        if GetResourceState('ps-dispatch') ~= 'started' then return false end
        local ok, allowed = pcall(function() return exports['ps-dispatch']:canOpen() end)
        return ok and allowed == true
    end,
}

-- Strip Lua/hidden fields the NUI doesn't need; keep display + id only. Tiles
-- with a `gate` are dropped when the gate fails (rebuilt each open, so it tracks
-- job/duty changes). Output stays contiguous so the NUI array has no holes.
local function buildItems()
    local out = {}
    for _, it in ipairs(HubConfig.Items or {}) do
        local gate = it.gate and GATES[it.gate]
        if not gate or gate() then
            out[#out + 1] = {
                id      = it.id,
                label   = it.label,
                zh      = it.zh,
                sub     = it.sub,
                icon    = it.icon,
                accent  = it.accent,
                section = it.section,
                view    = it.view,      -- NUI renders view tiles without redirect
                isLink  = it.link ~= nil,  -- link tile: NUI sends id only, URL stays in Lua
            }
        end
    end
    return out
end

-- ---- Speedo (hk-speedo owns SQL persistence; we just set + read) ----------

local speedoCurrent = nil   -- cached current mode from hk-speedo

local function speedoReady()
    return GetResourceState('hk-speedo') == 'started'
end

-- hk-speedo replies to requestMode with this event.
AddEventHandler('hk-speedo:currentMode', function(mode)
    speedoCurrent = mode
end)

local function setSpeedoMode(mode)
    if not speedoReady() then return end
    speedoCurrent = mode
    TriggerEvent('hk-speedo:setMode', mode)
end

-- Build the Settings payload the NUI renders. Identity is fetched separately
-- (async server callback); this is the static structure + current pref values.
local function buildSettings()
    local s = HubConfig.Settings or {}
    if not s.enabled then return nil end

    local opti = nil
    if s.optimizer and s.optimizer.enabled and optimizerReady() then
        local cur = savedOptimizerMode()
        opti = {
            label   = s.optimizer.label,
            zh      = s.optimizer.zh,
            desc    = s.optimizer.desc,
            modes   = s.optimizer.modes,
            current = cur,
        }
    end

    -- Speedo picker (hk-speedo owns persistence; ask it for the current mode).
    local speedo = nil
    if s.speedo and s.speedo.enabled and speedoReady() then
        TriggerEvent('hk-speedo:requestMode')  -- refreshes speedoCurrent async
        speedo = {
            label   = s.speedo.label,
            zh      = s.speedo.zh,
            desc    = s.speedo.desc,
            modes   = s.speedo.modes,
            current = speedoCurrent or s.speedo.default,
        }
    end

    -- (The old ps-hud `hud` toggle payload was removed — ps-hud is retired and
    --  hk-hud now owns minimap/compass/icons via their own settings groups.)

    -- Launch rows: drop any whose backing resource isn't started.
    local launchers = {}
    for _, l in ipairs(s.launchers or {}) do
        if not l.resource or GetResourceState(l.resource) == 'started' then
            launchers[#launchers + 1] = {
                id = l.id, label = l.label, zh = l.zh, desc = l.desc, btn = l.btn,
            }
        end
    end

    -- Bug report / feedback config for the NUI (webhook is SERVER-ONLY — never
    -- included here). Only the display + validation hints the form needs.
    local report = nil
    local r = HubConfig.Report or {}
    if r.enabled then
        report = {
            minChars          = r.minChars or 20,
            minStepChars      = r.minStepChars or 20,
            screenshot        = r.screenshot == true,   -- feature master switch
            screenshotDefault = r.screenshotDefault == true,
        }
    end


    -- Crosshair + status-icon + minimap + compass settings pulled live from hk-hud.
    local crosshair, hkhud, minimap, compass = nil, nil, nil, nil
    if GetResourceState('hk-hud') == 'started' then
        local okc, cdata = pcall(function() return exports['hk-hud']:getCrosshairUI() end)
        if okc and type(cdata) == 'table' then crosshair = cdata end
        local oki, idata = pcall(function() return exports['hk-hud']:getIconsUI() end)
        if oki and type(idata) == 'table' then hkhud = idata end
        local okm, mdata = pcall(function() return exports['hk-hud']:getMinimapUI() end)
        if okm and type(mdata) == 'table' then minimap = mdata end
        local okp, pdata = pcall(function() return exports['hk-hud']:getCompassUI() end)
        if okp and type(pdata) == 'table' then compass = pdata end
    end

    return {
        label        = s.label,
        zh           = s.zh,
        identity     = s.identity,
        money        = s.money,
        optimizer    = opti,
        speedo       = speedo,
        crosshair    = crosshair,
        hkhud        = hkhud,
        minimap      = minimap,
        compass      = compass,
        launchers    = launchers,
        placeholders = s.placeholders,
        report       = report,
        menuMode     = GetResourceKvpString('hk-hub:menuMode') or HubConfig.DefaultMenuMode or 'normal',
    }
end

-- Fire a launcher's command by id (validated against config; NUI only sends id).
local function runLauncher(id)
    for _, l in ipairs((HubConfig.Settings or {}).launchers or {}) do
        if l.id == id and l.command then return l.command end
    end
    return nil
end

-- Minimal-mode input model: the rail must NOT take NUI focus (that would eat
-- WASD and every other gameplay key). Instead the NUI has no focus at all, the
-- game keeps all its input, and this thread forwards ONLY the nav keys to the
-- NUI while the rail is up. Windows virtual-key codes → NUI key names.
local hubMode = 'normal'      -- mode the hub opened in
local cursorOn = false        -- true only while a popup (Settings/Laws) is up
local railThreadActive = false
-- Read nav keys through the GTA CONTROL system (IsRawKeyJustPressed is not
-- available on this server build). The arrow keys map to the "cellphone" nav
-- controls on keyboard, Enter to FRONTEND_ACCEPT, Escape to the pause controls.
-- We DISABLE each so they only drive the rail (don't leak to phone/pause/etc.),
-- then read them as disabled-just-pressed. WASD and the rest stay untouched.
local RAIL_CONTROLS = {
    { ctrl = 172, key = 'ArrowUp' },     -- INPUT_CELLPHONE_UP
    { ctrl = 173, key = 'ArrowDown' },   -- INPUT_CELLPHONE_DOWN
    { ctrl = 174, key = 'ArrowLeft' },   -- INPUT_CELLPHONE_LEFT
    { ctrl = 175, key = 'ArrowRight' },  -- INPUT_CELLPHONE_RIGHT
    { ctrl = 201, key = 'Enter' },       -- INPUT_FRONTEND_ACCEPT
}

local function startRailKeyThread()
    if railThreadActive then return end
    railThreadActive = true
    CreateThread(function()
        while isOpen and hubMode == 'minimal' and not cursorOn do
            -- Suppress the pause menu (so ESC closes the rail) and our nav
            -- controls (so they don't trigger the phone etc.), then read them.
            DisableControlAction(0, 199, true)  -- INPUT_FRONTEND_PAUSE
            DisableControlAction(0, 200, true)  -- INPUT_FRONTEND_PAUSE_ALTERNATE
            DisableControlAction(0, 322, true)  -- INPUT_FRONTEND_ESCAPE
            for _, m in ipairs(RAIL_CONTROLS) do
                DisableControlAction(0, m.ctrl, true)
                if IsDisabledControlJustPressed(0, m.ctrl) then
                    SendNUIMessage({ action = 'key', key = m.key })
                end
            end
            if IsDisabledControlJustPressed(0, 200) or IsDisabledControlJustPressed(0, 322)
               or IsDisabledControlJustPressed(0, 199) then
                SendNUIMessage({ action = 'key', key = 'Escape' })
            end
            Wait(0)
        end
        railThreadActive = false
    end)
end

local function openHub()
    if isOpen then return end
    isOpen = true
    hubMode = GetResourceKvpString('hk-hub:menuMode') or HubConfig.DefaultMenuMode or 'normal'
    if hubMode == 'minimal' then
        -- Keyboard-only rail: NO focus (game keeps all input), Lua forwards nav keys.
        cursorOn = false
        SetNuiFocus(false, false)
        startRailKeyThread()
    else
        -- Normal mode is a full mouse+keyboard panel from the start.
        cursorOn = true
        SetNuiFocus(true, true)
    end
    -- Keybinds ride at the top level (not under settings) so the INFO tile works
    -- even if the ⚙ Settings panel is disabled.
    local kb = HubConfig.Keybinds or {}
    local keybinds = (kb.enabled and kb.groups) and { groups = kb.groups, note = kb.note } or nil

    SendNUIMessage({
        action   = 'open',
        brand    = HubConfig.Brand,
        items    = buildItems(),
        settings = buildSettings(),
        keybinds = keybinds,
        menuMode = hubMode,
    })
end

local function closeHub()
    if not isOpen then return end
    isOpen = false       -- also lets the rail key thread fall out of its loop
    cursorOn = false
    SetNuiFocus(false, false)
    SendNUIMessage({ action = 'close' })
end

-- Look up an item by id (command lives server-side of the NUI boundary so a
-- tampered NUI can't fire an arbitrary command).
local function findItem(id)
    for _, it in ipairs(HubConfig.Items or {}) do
        if it.id == id then return it end
    end
    return nil
end

-- ---- NUI callbacks --------------------------------------------------------

RegisterNUICallback('close', function(_, cb)
    closeHub()
    cb('ok')
end)

-- Switch the hub between its two input states while it stays open.
--   {on=true}  → a popup (Settings/Laws) is showing: take full keyboard+mouse
--                focus so the player can click/type in it.
--   {on=false} → back to the launcher. In minimal mode that's the keyboard-only
--                rail: drop ALL focus (game keeps WASD) and resume forwarding
--                nav keys. In normal mode the card grid still needs mouse+keys.
RegisterNUICallback('cursor', function(data, cb)
    if isOpen then
        local on = data and data.on == true
        cursorOn = on
        if on then
            SetNuiFocus(true, true)
        elseif hubMode == 'minimal' then
            SetNuiFocus(false, false)
            startRailKeyThread()
        else
            SetNuiFocus(true, true)   -- normal-mode grid: keep mouse+keyboard
        end
    end
    cb('ok')
end)

-- Open an external URL in the player's browser. The only way FiveM can open a
-- browser is the CEF `openUrl` native, so we send the URL (kept in Lua, never in
-- NUI config) to a tiny always-loaded NUI and have it invoke openUrl. FiveM shows
-- its own one-time "open this link?" confirmation — that's a client security
-- feature and cannot be bypassed by any resource.
local function openExternalUrl(url)
    if type(url) ~= 'string' or url == '' then return end
    SendNUIMessage({ action = 'openUrl', url = url })
end

-- Fire an item's action: a client event (it.event) if set, otherwise its
-- chat command (it.command). Event args are passed through as varargs.
local function runItem(it)
    if it.link then
        openExternalUrl(it.link)
    elseif it.event then
        TriggerEvent(it.event, table.unpack(it.eventArgs or {}))
    elseif it.command then
        ExecuteCommand(it.command)
    end
end

-- Dispatch tile → open ps-dispatch via its export (re-checks job+duty itself, so
-- a player who changed job/clocked off between opening the hub and clicking just
-- gets nothing rather than a menu they can't use).
RegisterNetEvent('hk-hub:client:openDispatch', function()
    if GetResourceState('ps-dispatch') ~= 'started' then return end
    pcall(function() exports['ps-dispatch']:open() end)
end)

RegisterNUICallback('launch', function(data, cb)
    local it = data and data.id and findItem(data.id)
    if not it or not (it.command or it.event or it.link) then
        cb('badid')
        return
    end

    if HubConfig.CloseOnLaunch then
        closeHub()
        SetTimeout(HubConfig.LaunchDelay or 0, function()
            runItem(it)
        end)
    else
        runItem(it)
    end
    cb('ok')
end)

-- Settings launch row (e.g. /armenu) — close hub, then fire the command.
RegisterNUICallback('launchSettingCmd', function(data, cb)
    local command = data and data.id and runLauncher(data.id)
    if not command then cb('badid') return end
    closeHub()
    SetTimeout(HubConfig.LaunchDelay or 0, function()
        ExecuteCommand(command)
    end)
    cb('ok')
end)

-- ---- Settings callbacks ---------------------------------------------------

-- ---- Bug report / feedback -------------------------------------------------

-- Snapshot of useful client-side context to attach to a report. This is the
-- honest substitute for "F8 logs": telemetry we CAN read + our event buffer.
local function collectDiagnostics()
    local ped = PlayerPedId()
    local x, y, z = table.unpack(GetEntityCoords(ped))
    local d = {
        -- NOTE: no `os` library client-side in FiveM — the server stamps the time
        -- on the embed footer instead.
        gameBuild = GetGameBuildNumber and GetGameBuildNumber() or 0,
        serverId  = GetPlayerServerId(PlayerId()),
        coords    = ('%.1f, %.1f, %.1f'):format(x, y, z),
        heading   = ('%.0f'):format(GetEntityHeading(ped)),
        health    = GetEntityHealth(ped),
        armor     = GetPedArmour(ped),
        fps       = (GetFrameTime() > 0) and math.floor(1.0 / GetFrameTime()) or 0,
        bucket    = GetPlayerRoutingBucket and GetPlayerRoutingBucket(PlayerId()) or 0,
    }

    -- Vehicle context (only if in one).
    if IsPedInAnyVehicle(ped, false) then
        local veh = GetVehiclePedIsIn(ped, false)
        d.vehicle = {
            model  = GetDisplayNameFromVehicleModel(GetEntityModel(veh)),
            plate  = (GetVehicleNumberPlateText(veh) or ''):gsub('%s+$', ''),
            engine = ('%.0f'):format(GetVehicleEngineHealth(veh)),
            speed  = ('%.0f'):format(GetEntitySpeed(veh) * 3.6),  -- km/h
        }
    end

    -- Started resources (count + list) — helps spot a stopped/crashed dependency.
    local started = {}
    local total = GetNumResources and GetNumResources() or 0
    for i = 0, total - 1 do
        local name = GetResourceByFindIndex(i)
        if name and GetResourceState(name) == 'started' then
            started[#started + 1] = name
        end
    end
    d.resStarted = #started
    d.resTotal   = total
    d.resList    = started

    -- Rolling event breadcrumbs (most recent last).
    local logs = {}
    for _, e in ipairs(eventLog) do
        logs[#logs + 1] = ('[%s] %s: %s'):format(tostring(e.t), e.tag, e.msg)
    end
    d.logs = logs

    return d
end

-- The NUI collects the player's text; the client adds diagnostics and relays to
-- the server (which validates + posts to Discord). Screenshot is handled server
-- side via screenshot-basic, so nothing sensitive (webhook) is on the client.
RegisterNUICallback('submitReport', function(data, cb)
    data = data or {}
    local payload = {
        message    = data.message,
        steps      = data.steps,
        console    = data.console,      -- player-pasted F8 console log (optional)
        screenshot = data.screenshot == true,
        diagnostics = collectDiagnostics(),
    }
    QBCore = QBCore or exports['qb-core']:GetCoreObject()
    QBCore.Functions.TriggerCallback('hk-hub:server:submitReport', function(res)
        SendNUIMessage({ action = 'reportResult', result = res or { ok = false, err = 'no_response' } })
    end, payload)
    cb('ok')
end)

-- Fetch the player's info from the server (identifiers/money can't be trusted
-- client-side). Result is pushed back to the NUI as a separate message.
RegisterNUICallback('getInfo', function(_, cb)
    QBCore = QBCore or exports['qb-core']:GetCoreObject()
    QBCore.Functions.TriggerCallback('hk-hub:server:getInfo', function(info)
        SendNUIMessage({ action = 'setInfo', info = info or {} })
    end)
    -- Also reconcile the avatar (recaptures only if the look changed).
    requestAvatarSync()
    cb('ok')
end)

-- ---- Character avatar ------------------------------------------------------
-- Fingerprint the player's ped appearance (model + all component
-- drawable/texture + props). Sent to the server, which recaptures the portrait
-- only when it differs from what's stored. Cheap to compute; changes exactly
-- when the character's visible look does.
local function appearanceFingerprint()
    local ped = PlayerPedId()
    if not ped or ped == 0 then return '' end
    local parts = { tostring(GetEntityModel(ped)) }
    for comp = 0, 11 do
        parts[#parts + 1] = ('%d.%d.%d'):format(comp,
            GetPedDrawableVariation(ped, comp), GetPedTextureVariation(ped, comp))
    end
    for prop = 0, 7 do
        parts[#parts + 1] = ('p%d.%d.%d'):format(prop,
            GetPedPropIndex(ped, prop), GetPedPropTextureIndex(ped, prop))
    end
    return table.concat(parts, '|')
end

-- Capture an ISOLATED ped portrait — no camera, no full-screen shot. This is the
-- MugShotBase64 / af-squad technique: RegisterPedheadshotTransparent renders the
-- head onto a runtime txd with a TRANSPARENT background, which the NUI reads via
-- the built-in `nui-img/{txd}/{txd}` scheme and converts to a base64 PNG on a
-- canvas. The txd must stay registered until the NUI has drawn it, so the handle
-- is held here and released in the `avatarData` callback.
local avatarHandle    = nil
local avatarBusy      = false
local avatarPendingFp = ''

local function releaseAvatarHandle()
    if avatarHandle then
        UnregisterPedheadshot(avatarHandle)
        avatarHandle = nil
    end
end

-- Server asks us to (re)capture because our look changed (or there's no portrait
-- yet). We register the transparent headshot, wait for the txd, then hand it to
-- the NUI to rasterise. `fingerprint` is echoed back to the server on submit.
RegisterNetEvent('hk-hub:client:captureAvatar', function(fingerprint)
    if avatarBusy then return end
    local ped = PlayerPedId()
    if not ped or ped == 0 then return end
    avatarBusy      = true
    avatarPendingFp = tostring(fingerprint or '')

    CreateThread(function()
        releaseAvatarHandle()
        local handle = RegisterPedheadshotTransparent(ped)
        avatarHandle = handle
        -- Bail if the headshot never becomes valid (timeout ~5s).
        local tries = 0
        while (not IsPedheadshotReady(handle) or not IsPedheadshotValid(handle)) and tries < 500 do
            Wait(10)
            tries = tries + 1
        end
        if not IsPedheadshotReady(handle) or not IsPedheadshotValid(handle) then
            releaseAvatarHandle()
            avatarBusy = false
            return
        end
        local txd = GetPedheadshotTxdString(handle)
        if not txd or txd == '' then
            releaseAvatarHandle()
            avatarBusy = false
            return
        end
        -- NUI rasterises `nui-img/{txd}/{txd}` -> base64 PNG, replies via avatarData.
        SendNUIMessage({ action = 'genAvatar', txd = txd })
    end)
end)

-- NUI returns the rasterised portrait (base64 PNG data URI). Forward it to the
-- server for upload; release the headshot txd now that it's been read.
RegisterNUICallback('avatarData', function(data, cb)
    releaseAvatarHandle()
    local uri = data and data.data
    if type(uri) == 'string' and #uri > 32 then
        TriggerServerEvent('hk-hub:server:submitAvatar', uri, avatarPendingFp)
    end
    avatarBusy = false
    cb('ok')
end)

-- New portrait URL pushed after a (re)capture uploads.
RegisterNetEvent('hk-hub:client:avatar', function(url)
    if url and url ~= '' then SendNUIMessage({ action = 'setAvatar', url = url }) end
end)

-- Send our current fingerprint; server replies with the cached URL and, if the
-- look changed, triggers a recapture (new URL arrives via hk-hub:client:avatar).
function requestAvatarSync()
    QBCore = QBCore or exports['qb-core']:GetCoreObject()
    local fp = appearanceFingerprint()
    if fp == '' then return end
    QBCore.Functions.TriggerCallback('hk-hub:server:checkAvatar', function(res)
        if res and res.url and res.url ~= '' then
            SendNUIMessage({ action = 'setAvatar', url = res.url })
        end
    end, fp)
end

-- Reconcile once shortly after the character loads (covers first-login capture
-- and any appearance change made while offline / in clothing shops).
RegisterNetEvent('QBCore:Client:OnPlayerLoaded', function()
    SetTimeout(4000, requestAvatarSync)
end)

-- Steam persona name arrives separately (never blocks the Info panel).
RegisterNetEvent('hk-hub:client:steamName', function(name)
    SendNUIMessage({ action = 'setSteamName', name = name })
end)

-- ---- Mobile / web access key ----------------------------------------------
-- Fetch the current key on demand (the panel only shows it after a press+confirm,
-- so we don't ship it with the initial Settings payload).
RegisterNUICallback('getMobileKey', function(_, cb)
    QBCore = QBCore or exports['qb-core']:GetCoreObject()
    QBCore.Functions.TriggerCallback('hk-hub:server:getMobileKey', function(res)
        cb(res or { ok = false, err = 'no_response' })
    end)
end)

-- Generate / regenerate the key. Regenerate resets all outside sessions.
RegisterNUICallback('regenMobileKey', function(_, cb)
    QBCore = QBCore or exports['qb-core']:GetCoreObject()
    QBCore.Functions.TriggerCallback('hk-hub:server:regenMobileKey', function(res)
        cb(res or { ok = false, err = 'no_response' })
    end)
end)

-- Player picks an optimizer mode. Validate against config, apply + persist.
RegisterNUICallback('setOptimizerMode', function(data, cb)
    local name = data and data.mode
    local s = HubConfig.Settings or {}
    local o = s.optimizer or {}
    local ok = false
    if name and o.modes then
        for _, m in ipairs(o.modes) do
            if m.name == name then ok = true break end
        end
    end
    if not ok then cb('badmode') return end
    local applied = applyOptimizerMode(name)
    cb({ mode = applied })
end)

-- Player picks a speedo mode. Validate against config, set via hk-speedo.
RegisterNUICallback('setSpeedoMode', function(data, cb)
    local name = data and data.mode
    local s = HubConfig.Settings or {}
    local sp = s.speedo or {}
    local ok = false
    if name and sp.modes then
        for _, m in ipairs(sp.modes) do
            if m.name == name then ok = true break end
        end
    end
    if not ok then cb('badmode') return end
    setSpeedoMode(name)
    cb({ mode = name })
end)

-- Menu layout mode (normal / minimal). Persist + tell NUI to re-apply live.
RegisterNUICallback('setMenuMode', function(data, cb)
    local mode = (data and data.mode == 'minimal') and 'minimal' or 'normal'
    SetResourceKvp('hk-hub:menuMode', mode)
    hubMode = mode   -- keep Lua's input model in sync; the NUI closes the picker
                     -- view next, whose 'cursor' callback then reconciles focus.
    SendNUIMessage({ action = 'setMenuMode', mode = mode })
    cb('ok')
end)

-- ---- Crosshair callbacks (relay to hk-hud exports) ------------------------
RegisterNUICallback('setCrosshairEnabled', function(data, cb)
    if GetResourceState('hk-hud') == 'started' then
        exports['hk-hud']:setCrosshairEnabled(data and data.on and true or false)
    end
    cb('ok')
end)

RegisterNUICallback('setCrosshair', function(data, cb)
    if data and data.key ~= nil and GetResourceState('hk-hud') == 'started' then
        exports['hk-hud']:setCrosshair(data.key, data.value)
    end
    cb('ok')
end)

-- Status-icon settings (mode/color) → hk-hud. `mode` = always|dynamic|hidden.
RegisterNUICallback('hkhudSetIcon', function(data, cb)
    if data and data.name and GetResourceState('hk-hud') == 'started' then
        local opts = {}
        if data.mode ~= nil then opts.mode = data.mode end
        if data.color ~= nil then opts.color = data.color end
        exports['hk-hud']:setIcon(data.name, opts)
    end
    cb('ok')
end)

RegisterNUICallback('hkhudSetTheme', function(data, cb)
    if data and data.theme and GetResourceState('hk-hud') == 'started' then
        exports['hk-hud']:setTheme(data.theme)
    end
    cb('ok')
end)

RegisterNUICallback('hkhudReset', function(_, cb)
    if GetResourceState('hk-hud') == 'started' then exports['hk-hud']:resetSettings() end
    cb('ok')
end)

RegisterNUICallback('hkhudSetEnabled', function(data, cb)
    if GetResourceState('hk-hud') == 'started' then
        exports['hk-hud']:setHudEnabled(data and data.on and true or false)
    end
    cb('ok')
end)

RegisterNUICallback('hkhudSetCinematic', function(data, cb)
    if GetResourceState('hk-hud') == 'started' then
        exports['hk-hud']:setCinematic(data and data.on and true or false)
    end
    cb('ok')
end)

RegisterNUICallback('hkhudSetMinimap', function(data, cb)
    if data and data.key ~= nil and GetResourceState('hk-hud') == 'started' then
        exports['hk-hud']:setMinimap(data.key, data.value)
    end
    cb('ok')
end)

RegisterNUICallback('hkhudSetCompass', function(data, cb)
    if data and data.key ~= nil and GetResourceState('hk-hud') == 'started' then
        exports['hk-hud']:setCompass(data.key, data.value)
    end
    cb('ok')
end)

-- (Removed the ps-hud HUD toggle/icon callbacks — hk-hud owns the HUD now,
--  driven via hkhudSetIcon/hkhudSetMinimap/hkhudSetCompass/etc.)

-- Reset ALL hk-hud per-player HUD settings to defaults (icons, theme, minimap,
-- compass, crosshair). Drives hk-hud's resetSettings export.
RegisterNUICallback('hkhudResetAll', function(_, cb)
    if GetResourceState('hk-hud') == 'started' then
        exports['hk-hud']:resetSettings()
    end
    cb('ok')
end)

-- ---- Open triggers --------------------------------------------------------

RegisterCommand(HubConfig.OpenCommand or 'hub', function()
    if isOpen then closeHub() else openHub() end
end, false)

-- F5 keybind (rebindable in Settings > Key Bindings > FiveM).
RegisterKeyMapping(HubConfig.OpenCommand or 'hub', 'Open HK Hub', 'keyboard', HubConfig.OpenKey or 'F5')

-- /discord — open the community Discord invite (same URL as the F5 Discord tile).
RegisterCommand('discord', function()
    local url
    for _, it in ipairs(HubConfig.Items or {}) do
        if it.id == 'discord' and it.link then url = it.link break end
    end
    if url then openExternalUrl(url) end
end, false)

-- Safety: drop NUI focus if the resource stops while open.
AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    if isOpen then SetNuiFocus(false, false) end
end)

-- Re-apply the saved optimizer mode on load (per-user persistence). hk-optimizer
-- syncs its mode data on player join, so wait for it to be ready first.
CreateThread(function()
    local s = HubConfig.Settings or {}
    if not (s.optimizer and s.optimizer.enabled) then return end
    -- Wait for the local player to be spawned + hk-optimizer started.
    while not NetworkIsSessionStarted() do Wait(500) end
    Wait(2000)  -- let hk-optimizer receive its server sync
    if not optimizerReady() then return end
    local mode = savedOptimizerMode()
    -- 'quality' is the baseline (GTA defaults) — no need to re-apply it.
    if mode and mode ~= 'quality' then
        exports['hk-optimizer']:applyMode(mode)
    end
end)

-- (Removed the ps-hud spawn re-apply threads — hk-hud persists + applies its
--  own settings on spawn now.)
