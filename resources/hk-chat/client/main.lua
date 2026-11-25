-- ═══════════════════════════════════════════════════════════════ --
--   HK-CHAT — client                                                 --
--   NUI bridge + activation. Disables native text chat, opens on the  --
--   stock chat control (T), KEYBOARD-ONLY focus (no mouse cursor),    --
--   and keeps the legacy chat:* event contract alive.                 --
-- ═══════════════════════════════════════════════════════════════ --

local chatInputActive = false
local chatActivating = false
local chatLoaded = false
local chatHidden = true

-- Command palette / control state (server-driven).
local suggestions = {}          -- [name] = { name, help, params }
local removedSuggestions = {}    -- names removed by resources
local cmdSettings = {}           -- [bareName] = { noPreview, blockChat }
local isAdmin = false            -- admins bypass noPreview + blockChat

-- ─── push the current, viewer-appropriate palette to the NUI ─────── --
local function pushPalette()
    local list = {}
    for name, s in pairs(suggestions) do
        if not removedSuggestions[name] then
            local bare = name:gsub('^/', ''):lower()   -- keys are stored lowercase
            local set = cmdSettings[bare]
            -- Non-admins never see no-preview commands; admins see everything.
            if isAdmin or not (set and set.noPreview) then
                list[#list + 1] = { name = s.name, help = s.help or '', params = s.params or {} }
            end
        end
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    SendNUIMessage({ type = 'PALETTE', commands = list })
end

-- Pull every ace-allowed registered command as a baseline suggestion.
local function refreshCommands()
    if not GetRegisteredCommands then return end
    for _, command in ipairs(GetRegisteredCommands()) do
        local name = '/' .. command.name
        if IsAceAllowed(('command.%s'):format(command.name)) and not suggestions[name] then
            suggestions[name] = { name = name, help = '', params = {} }
        end
    end
    pushPalette()
end

-- ─── legacy chat:* event contract (kept for third-party resources) ─ --
-- These are game/system notifications pushed by other resources (server状態
-- checks, script feedback, etc). We surface them into the GAMEPLAY tab with a
-- GAME pill so they read as system output, not player chat.
local GAME_TAG = 'GAME'
local GAME_COLOR = '#38bdf8'  -- sky blue: distinct from OOC/EMERGENCY/ANNOUNCE

-- These legacy lines arrive straight from other resources (no server stamp),
-- so we timestamp them client-side (HH:MM) — every chat line carries a time.
-- NOTE: `os` is NOT available in the FiveM client Lua sandbox, so we use the
-- game's local-time native instead of os.date.
local function nowStamp()
    local _, _, _, hour, minute = GetLocalTime()
    return ('%02d:%02d'):format(hour, minute)
end

RegisterNetEvent('chatMessage')
AddEventHandler('chatMessage', function(author, ctype, text)
    SendNUIMessage({ type = 'RECV', message = {
        tab = 'gameplay', tag = GAME_TAG, color = GAME_COLOR, stamp = nowStamp(),
        name = (author ~= '' and author or nil), text = tostring(text) } })
end)

RegisterNetEvent('chat:addMessage')
AddEventHandler('chat:addMessage', function(message)
    local args = message.args or {}
    local name, text
    if #args >= 2 then name, text = args[1], args[2] else text = args[1] or '' end
    SendNUIMessage({ type = 'RECV', message = {
        tab = 'gameplay', tag = GAME_TAG, color = GAME_COLOR, stamp = nowStamp(),
        name = name, text = tostring(text or '') } })
end)

RegisterNetEvent('chat:addSuggestion')
AddEventHandler('chat:addSuggestion', function(name, help, params)
    suggestions[name] = { name = name, help = help or '', params = params or {} }
    pushPalette()
end)

RegisterNetEvent('chat:addSuggestions')
AddEventHandler('chat:addSuggestions', function(list)
    for _, s in ipairs(list) do
        suggestions[s.name] = { name = s.name, help = s.help or '', params = s.params or {} }
    end
    pushPalette()
end)

RegisterNetEvent('chat:removeSuggestion')
AddEventHandler('chat:removeSuggestion', function(name)
    removedSuggestions[name] = true
    pushPalette()
end)

RegisterNetEvent('chat:clear')
AddEventHandler('chat:clear', function() SendNUIMessage({ type = 'CLEAR' }) end)

-- ─── hk-chat native intake (from the server router) ──────────────── --
RegisterNetEvent('hk-chat:client:recv', function(payload)
    SendNUIMessage({ type = 'RECV', message = payload })
end)

-- Batch of past public lines replayed on join.
RegisterNetEvent('hk-chat:client:history', function(list)
    SendNUIMessage({ type = 'HISTORY', messages = list })
end)

RegisterNetEvent('hk-chat:client:nick', function(id, nick)
    SendNUIMessage({ type = 'NICK', id = id, nick = nick })
end)

-- Online same-job roster (id + real name), for the Job tab header.
RegisterNetEvent('hk-chat:client:roster', function(room, roster)
    SendNUIMessage({ type = 'ROSTER', room = room, roster = roster })
end)

-- Server started/updated our send cooldown → grey out the bar for `ms`.
RegisterNetEvent('hk-chat:client:cooldown', function(ms)
    SendNUIMessage({ type = 'COOLDOWN', ms = ms })
end)

-- Server pushes per-command settings + our admin flag.
RegisterNetEvent('hk-chat:client:cmdsettings', function(list, admin)
    cmdSettings = {}
    for _, c in ipairs(list or {}) do
        cmdSettings[(c.command or ''):lower()] = { noPreview = c.noPreview, blockChat = c.blockChat }
    end
    isAdmin = admin and true or false
    pushPalette()
    -- Feed the admin settings panel too (it filters to admins client-side anyway).
    SendNUIMessage({ type = 'CMDSETTINGS', commands = allCommandsForAdmin(), isAdmin = isAdmin })
end)

-- Admin asked to open the settings panel.
RegisterNetEvent('hk-chat:client:openAdmin', function()
    SendNUIMessage({ type = 'CMDSETTINGS', commands = allCommandsForAdmin(), isAdmin = isAdmin })
    SendNUIMessage({ type = 'OPEN_ADMIN' })
    beginFocus()
end)

-- Moderation data (online players + recent public messages) for the admin panel.
RegisterNetEvent('hk-chat:client:moddata', function(players, recent)
    SendNUIMessage({ type = 'MODDATA', players = players, recent = recent })
end)

-- Remove one message everywhere (by mid).
RegisterNetEvent('hk-chat:client:removeMsg', function(mid)
    SendNUIMessage({ type = 'REMOVEMSG', mid = mid })
end)

-- Clear all chat for everyone.
RegisterNetEvent('hk-chat:client:clearAll', function()
    SendNUIMessage({ type = 'CLEAR' })
end)

-- /911 asked us to fire the real dispatch alert (needs our coords).
RegisterNetEvent('hk-chat:client:dispatch911', function(msg)
    if GetResourceState('ps-dispatch') ~= 'started' then return end
    -- Alert the configured emergency jobs (shared config, single source of truth
    -- — no stale hardcoded list). ps-dispatch expects real job NAMES here.
    exports['ps-dispatch']:CustomAlert({
        message = msg, dispatchCode = '911', code = '911', icon = 'fas fa-phone',
        priority = 1, radius = 0, sprite = 280, color = 1, scale = 0.7, length = 3,
        jobs = Config.EmergencyJobs or { 'police', 'ambulance' },
    })
end)

-- ─── /me floating 3D text above the emoting player's head ───────── --
-- Server broadcasts to everyone; we range-check and only draw if close.
local activeEmotes = {}  -- [serverId] = { name, text, until }

RegisterNetEvent('hk-chat:client:emote', function(fromSrc, name, text)
    local dur = Config.EmoteDuration or 8000
    activeEmotes[fromSrc] = { name = name, text = text, expires = GetGameTimer() + dur }
end)

-- Draw a 3D text marker at world coords (screen-projected).
local function draw3DText(x, y, z, name, text)
    local onScreen, sx, sy = World3dToScreen2d(x, y, z)
    if not onScreen then return end
    local cx, cy, cz = table.unpack(GetGameplayCamCoord())
    local dist = #(vector3(cx, cy, cz) - vector3(x, y, z))
    -- Clamp distance so YOUR OWN emote (camera ~0m from your head) doesn't make
    -- 1/dist explode into giant/off-screen text. Also cap the final scale.
    if dist < 2.0 then dist = 2.0 end
    local scale = (1.0 / dist) * 2.0 * (1.0 / GetGameplayCamFov()) * 100.0
    if scale > 0.9 then scale = 0.9 end
    -- name (accent) line
    SetTextScale(0.0, 0.34 * scale)
    SetTextFont(4)
    SetTextProportional(true)
    SetTextColour(0, 200, 255, 255)
    SetTextCentre(true)
    SetTextEntry('STRING')
    AddTextComponentString(name)
    DrawText(sx, sy - 0.02)
    -- action line
    SetTextScale(0.0, 0.36 * scale)
    SetTextFont(4)
    SetTextProportional(true)
    SetTextColour(233, 238, 243, 235)
    SetTextCentre(true)
    SetTextEntry('STRING')
    AddTextComponentString('* ' .. text)
    DrawText(sx, sy + 0.01)
end

CreateThread(function()
    local maxDist = Config.EmoteDistance or 20.0
    while true do
        local any = false
        local now = GetGameTimer()
        for srcId, e in pairs(activeEmotes) do
            if now > e.expires then
                activeEmotes[srcId] = nil
            else
                any = true
                local ply = GetPlayerFromServerId(srcId)
                if ply ~= -1 then
                    local ped = GetPlayerPed(ply)
                    if ped and ped ~= 0 and DoesEntityExist(ped) then
                        local pc = GetEntityCoords(PlayerPedId())
                        local tc = GetEntityCoords(ped)
                        if #(pc - tc) <= maxDist then
                            draw3DText(tc.x, tc.y, tc.z + 1.0, e.name, e.text)
                        end
                    end
                end
            end
        end
        Wait(any and 0 or 300)  -- only spin fast while something is showing
    end
end)

-- Full command list (with each command's toggles) for the admin panel.
function allCommandsForAdmin()
    local out = {}
    for name in pairs(suggestions) do
        local bare = name:gsub('^/', ''):lower()   -- keys are stored lowercase
        local set = cmdSettings[bare] or {}
        out[#out + 1] = { name = name, noPreview = set.noPreview or false, blockChat = set.blockChat or false }
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

-- ─── focus (KEYBOARD ONLY — second arg false = no mouse cursor) ──── --
function beginFocus()
    chatInputActive = true
    SetNuiFocusKeepInput(false)
    SetNuiFocus(true, false)  -- keyboard yes, cursor NO
end

local function endFocus()
    chatInputActive = false
    chatActivating = false
    SetNuiFocus(false, false)
end

-- Push our own server ID to the NUI (for the input-bar self-ID pill). The ID
-- can be -1 before the network session is up, so retry until it resolves.
function pushSelfId()
    CreateThread(function()
        local id = GetPlayerServerId(PlayerId())
        local tries = 0
        while (not id or id <= 0) and tries < 50 do
            Wait(200)
            id = GetPlayerServerId(PlayerId())
            tries = tries + 1
        end
        if id and id > 0 then
            SendNUIMessage({ type = 'SELFID', id = id })
        end
    end)
end

-- ─── NUI callbacks ───────────────────────────────────────────────── --
RegisterNUICallback('loaded', function(_, cb)
    chatLoaded = true
    SendNUIMessage({
        type = 'CONFIG',
        tabs = Config.Tabs,
        globalAggregates = Config.GlobalAggregates,
        enableGroups = Config.EnableGroups,
        idleMessages = Config.IdleMessages,
        idleFadeAfter = Config.IdleFadeAfter,
        maxLength = Config.MaxMessageLength,
        showTimestamps = Config.ShowTimestamps,
        sendCooldown = Config.SendCooldown,
        selfId = GetPlayerServerId(PlayerId()),  -- may be -1 pre-session; refreshed below
    })
    refreshCommands()
    pushSelfId()
    -- Nudge txAdmin to (re)auth this client so a txAdmin who logged in BEFORE
    -- hk-chat started is recognised by the server's admin gate (hk-scenario /
    -- hk-optimizer pattern). Harmless for non-admins (auth just fails silently).
    -- Do this before requesting settings so the admin flag is resolved correctly.
    TriggerServerEvent('txsv:checkIfAdmin')
    TriggerServerEvent('hk-chat:server:requestSettings')
    -- Ask the server for nick map + scoped history. This fires on FIRST join and
    -- again whenever the NUI reloads (resource restart), so chat + nicknames are
    -- restored after a restart without relying on join events or timing.
    TriggerServerEvent('hk-chat:server:requestBootstrap')
    cb('ok')
end)

-- Player submitted a line (or cancelled). Releases focus either way.
RegisterNUICallback('submit', function(data, cb)
    endFocus()
    if not data.canceled and data.message and data.message ~= '' then
        local msg = data.message
        local tab = data.tab or 'global'
        -- On the Whisper tab, a plain line IS a whisper: "12 hey" == "/w 12 hey".
        -- (Explicit /commands still run as commands, even here.)
        if tab == 'whisper' and msg:sub(1, 1) ~= '/' then
            msg = '/w ' .. msg
        end
        if msg:sub(1, 1) == '/' then
            -- Strip the slash, take the first word, lowercase it. FiveM commands
            -- are case-insensitive, so "/CAR" must match a block on "car".
            local bare = msg:sub(2):gsub('^%s+', ''):gsub('%s.*$', ''):lower()
            local set = cmdSettings[bare]
            -- Block-from-chat: non-admins can't run blocked commands via chat.
            if set and set.blockChat and not isAdmin then
                SendNUIMessage({ type = 'RECV', message = {
                    tab = 'global', system = true, color = '#f87171',
                    text = ('Command /%s is disabled in chat.'):format(bare) } })
            else
                ExecuteCommand(msg:sub(2))
            end
        else
            TriggerServerEvent('hk-chat:server:say', tab, msg)
        end
    end
    cb('ok')
end)

-- NUI requests the current job roster (on opening/switching to the Job tab).
RegisterNUICallback('requestRoster', function(_, cb)
    TriggerServerEvent('hk-chat:server:requestRoster')
    cb('ok')
end)

-- NUI released focus (Esc, or admin panel closed).
RegisterNUICallback('close', function(_, cb)
    endFocus()
    cb('ok')
end)

-- Admin toggled a command in the settings panel → tell the server.
RegisterNUICallback('setCmd', function(data, cb)
    if data and data.command then
        TriggerServerEvent('hk-chat:server:setCmd', data.command,
            data.noPreview and true or false, data.blockChat and true or false)
    end
    cb('ok')
end)

-- Admin moderation callbacks (all re-checked server-side).
RegisterNUICallback('requestModData', function(_, cb)
    TriggerServerEvent('hk-chat:server:requestModData')
    cb('ok')
end)

RegisterNUICallback('toggleMute', function(data, cb)
    if data and data.id then TriggerServerEvent('hk-chat:server:toggleMute', data.id) end
    cb('ok')
end)

RegisterNUICallback('clearAll', function(_, cb)
    TriggerServerEvent('hk-chat:server:clearAll')
    cb('ok')
end)

RegisterNUICallback('removeMsg', function(data, cb)
    if data and data.mid then TriggerServerEvent('hk-chat:server:removeMsg', data.mid) end
    cb('ok')
end)

-- ─── activation loop (control 245, keyboard-only focus) ──────────── --
CreateThread(function()
    SetTextChatEnabled(false)
    SetNuiFocus(false, false)

    while true do
        if not chatInputActive then
            if IsControlPressed(0, Config.OpenControl) then
                chatActivating = true
                chatInputActive = true
                SendNUIMessage({ type = 'OPEN' })
            end
            -- Poll fast only during the brief "activating" window (waiting for
            -- key release); otherwise idle at a light tick.
            Wait(chatActivating and 0 or 8)
        else
            if chatActivating then
                -- Grab focus once the open key is released, so it isn't typed in.
                if not IsControlPressed(0, Config.OpenControl) then
                    beginFocus()
                    chatActivating = false
                end
                Wait(0)  -- tight loop ONLY while waiting for the release
            else
                -- Panel is open and focused: nothing here needs per-frame work
                -- (the NUI owns input now). Idle slowly instead of Wait(0), which
                -- was burning a full poll every frame the whole time chat was open.
                Wait(200)
            end
        end
    end
end)

-- Hide the whole UI when faded out / pause menu up.
CreateThread(function()
    while true do
        Wait(200)
        if chatLoaded then
            local shouldHide = IsScreenFadedOut() or IsPauseMenuActive()
            if shouldHide ~= chatHidden then
                chatHidden = shouldHide
                SendNUIMessage({ type = 'SCREEN', hide = shouldHide })
            end
        end
    end
end)

-- Report current job room to the NUI so the Job tab labels correctly.
CreateThread(function()
    local last
    while true do
        Wait(2000)
        local room = GetJobRoom()
        if room ~= last then
            last = room
            SendNUIMessage({ type = 'JOBROOM', room = room })
        end
    end
end)

AddEventHandler('onClientResourceStart', function() Wait(500); refreshCommands() end)
AddEventHandler('onClientResourceStop',  function() Wait(500); refreshCommands() end)

AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() and chatInputActive then
        SetNuiFocus(false, false)
    end
end)
