-- hk-race :: client/nui.lua
-- Two NUI surfaces sharing the hk-waypoint visual template:
--   1) Admin panel (/raceadmin) — manage tracks, launch editor.
--   2) User track picker (/racemenu) — pick a track and host a race.

local adminOpen = false
local pickerOpen = false

local function focus(state)
    SetNuiFocus(state, state)
    SetNuiFocusKeepInput(false)
end

-- ── User track picker ──────────────────────────────────────────────────────
function OpenTrackPicker(tracks)
    if pickerOpen or adminOpen then return end
    pickerOpen = true
    focus(true)
    -- Defensive: RaceTier is defined in client/tier.lua (loads before this). Guard
    -- so a load hiccup can't break the picker.
    local myTier = (RaceTier and RaceTier.current and RaceTier.current()) or nil
    SendNUIMessage({
        action = 'openPicker',
        tracks = tracks or {},
        tierNames = RaceConfig.Tiers.names,
        myTier = myTier,                 -- {tier,name,score,...} or nil
        inRace = (RaceActive and RaceActive()) or false,   -- show Leave button instead
        locales = {
            title = L('laptop_title'),
            subtitle = L('laptop_subtitle'),
            empty = L('laptop_no_tracks'),
            start = L('laptop_start'),
        },
    })
end

-- User clicked "Leave Current Race" in the picker.
RegisterNUICallback('picker:leave', function(_, cb)
    pickerOpen = false
    focus(false)
    SendNUIMessage({ action = 'close' })
    if LeaveRace then LeaveRace() end
    cb('ok')
end)

-- Player clicked a track's record → fetch + show its full leaderboard.
RegisterNUICallback('picker:leaderboard', function(data, cb)
    lib.callback('hk-race:lb:get', false, function(res)
        SendNUIMessage({ action = 'leaderboard', data = res or {} })
    end, tonumber(data.trackId))
    cb('ok')
end)

-- /racemenu — user opens the track picker (fetches the listed tracks fresh).
RegisterCommand(RaceConfig.UserCommand, function()
    if pickerOpen or adminOpen then return end
    lib.callback('hk-race:client:bootstrap', false, function(data)
        OpenTrackPicker((data and data.tracks) or {})
    end)
end, false)

-- Chat autocomplete hints so hk-race commands show up when you type "/".
-- These are cosmetic (client-side) and work even for server-registered commands
-- like /racecalall. Fires once on resource start.
CreateThread(function()
    local function suggest(cmd, help, params)
        TriggerEvent('chat:addSuggestion', '/' .. cmd, help, params or {})
    end
    suggest(RaceConfig.UserCommand,  'Open the street-race track picker')
    suggest(RaceConfig.AdminCommand, 'Open the race admin panel (create/manage tracks)')
    suggest(RaceConfig.QuitCommand,  'Leave the race you are currently in')
    suggest('mytier',       'Show your current vehicle tier (B/A/S)')
    suggest('racecalall',   'ADMIN: seed tier calibration for every car from existing data')
    suggest('racebench',    'ADMIN: spawn every car & measure top speed (fills cars with no data)')
    suggest('setcartier',   'ADMIN: override a car tier', {
        { name = 'tier', help = '1=B, 2=A, 3=S (0 clears the override)' },
    })
    suggest('clearcartier', 'ADMIN: clear the tier override on the car you are in')
    local h2hCmd = (RaceConfig.H2H and RaceConfig.H2H.wager and RaceConfig.H2H.wager.command) or 'h2hbet'
    suggest(h2hCmd, 'Set your head-to-head cash bet amount', {
        { name = 'amount', help = 'cash to stake on a head-to-head challenge' },
    })
end)

-- data.trackId, data.allowedTiers (array of 1..4, or empty/nil = no restriction)
RegisterNUICallback('picker:host', function(data, cb)
    pickerOpen = false
    focus(false)
    SendNUIMessage({ action = 'close' })
    if data and data.trackId then
        local tiers = data.allowedTiers
        if type(tiers) ~= 'table' or #tiers == 0 then tiers = nil end
        local myTi = (RaceTier and RaceTier.current and RaceTier.current()) or nil
        lib.callback('hk-race:race:host', false, function(res)
            if res and res.ok then
                -- enterLobby event will fire from server.
            else
                local key = res and res.error
                if key == 'track_cooldown' then
                    local m = math.ceil((res.cooldown or 0) / 60)
                    RaceUtil.notify(('This circuit was just raced — try again in ~%d min.'):format(m), 'error')
                elseif key == 'track_busy' then
                    RaceUtil.notify('This circuit is already being set up by someone.', 'error')
                else
                    local errs = {
                        too_many_races = 'Too many races in progress — try again shortly.',
                        already_in_race = 'You are already in a race.',
                        not_found = 'That track no longer exists.',
                    }
                    RaceUtil.notify(errs[key] or ('Cannot host: ' .. tostring(key or '?')), 'error')
                end
            end
        end, tonumber(data.trackId), tiers, myTi and myTi.tier or nil, tonumber(data.laps),
            data.slipstream ~= false, data.ghostMode, tonumber(data.minPlayers))
    end
    cb('ok')
end)

RegisterNUICallback('picker:close', function(_, cb)
    pickerOpen = false
    focus(false)
    cb('ok')
end)

-- ── Admin panel ──────────────────────────────────────────────────────────
RegisterNetEvent('hk-race:client:openAdmin', function()
    if adminOpen or pickerOpen then return end
    -- The admin NUI and the MenuV editor can't share NUI focus. If the editor is
    -- open, close it cleanly first so we don't leave an orphaned, unreachable menu.
    if IsEditing and IsEditing() then CloseEditor() end
    lib.callback('hk-race:admin:getData', false, function(data)
        if not data or data.error then
            RaceUtil.notify(L('no_permission'), 'error')
            return
        end
        adminOpen = true
        focus(true)
        SendNUIMessage({
            action = 'openAdmin',
            tracks = data.tracks or {},
            locales = {
                title = L('admin_title'),
                tracks = L('admin_tracks'),
                newTrack = L('admin_new_track'),
                edit = L('admin_edit'),
                del = L('admin_delete'),
            },
        })
    end)
end)

local function refreshAdmin()
    lib.callback('hk-race:admin:getData', false, function(data)
        if data and not data.error then
            SendNUIMessage({ action = 'refreshAdmin', tracks = data.tracks or {} })
        end
    end)
end

RegisterNUICallback('admin:close', function(_, cb)
    adminOpen = false
    focus(false)
    cb('ok')
end)

RegisterNUICallback('admin:newTrack', function(_, cb)
    adminOpen = false
    focus(false)
    SendNUIMessage({ action = 'close' })
    TriggerEvent('hk-race:client:launchEditor', nil)
    cb('ok')
end)

RegisterNUICallback('admin:editTrack', function(data, cb)
    adminOpen = false
    focus(false)
    SendNUIMessage({ action = 'close' })
    TriggerEvent('hk-race:client:launchEditor', tonumber(data.id))
    cb('ok')
end)

RegisterNUICallback('admin:deleteTrack', function(data, cb)
    lib.callback('hk-race:admin:deleteTrack', false, function(res)
        if res and res.ok then refreshAdmin() end
        cb(res or {})
    end, tonumber(data.id))
end)

RegisterNUICallback('admin:toggleListed', function(data, cb)
    lib.callback('hk-race:admin:toggleListed', false, function(res)
        if res and res.ok then refreshAdmin() end
        cb(res or {})
    end, tonumber(data.id))
end)

-- Move a track up/down in the manual display order (dir = -1 up, +1 down).
RegisterNUICallback('admin:reorderTrack', function(data, cb)
    lib.callback('hk-race:admin:reorderTrack', false, function(res)
        if res and res.ok and res.tracks then
            SendNUIMessage({ action = 'refreshAdmin', tracks = res.tracks })
        end
        cb(res or {})
    end, tonumber(data.id), tonumber(data.dir))
end)

-- Leaderboard management: fetch (with row ids), rename a racer, delete a record.
RegisterNUICallback('admin:lbGet', function(data, cb)
    lib.callback('hk-race:admin:lbGet', false, function(res)
        cb(res or {})
    end, tonumber(data.trackId))
end)

RegisterNUICallback('admin:lbRename', function(data, cb)
    lib.callback('hk-race:admin:lbRename', false, function(res)
        cb(res or {})
    end, tonumber(data.rowId), data.name)
end)

RegisterNUICallback('admin:lbDelete', function(data, cb)
    lib.callback('hk-race:admin:lbDelete', false, function(res)
        cb(res or {})
    end, tonumber(data.rowId))
end)

-- Car Tiers: load the full car list (live from hk_handling + current overrides).
RegisterNUICallback('admin:getCarTiers', function(_, cb)
    lib.callback('hk-race:admin:getCarTiers', false, function(data)
        -- Enrich each car with its AUTO-detected tier (the tier it would get with
        -- no override), computed here since classification needs hk-handling's
        -- client-side SpeedCalData (top speed) which the server DB doesn't hold.
        if data and data.cars and RaceTier and RaceTier.classifyByHash then
            for _, c in ipairs(data.cars) do
                -- c.dbT100/c.dbTop = server's merged cal (seed + DB speedCal + learned)
                -- so every car with any data shows a real auto-tier here, not blank.
                local t = RaceTier.classifyByHash(c.hash, c.manualType, c.dbT100, c.dbTop)
                if t then
                    c.autoTier, c.autoName = t.tier, t.name
                    -- source='none' = no data anywhere, just the default-tier guess.
                    -- Flag it so the panel can mark it as provisional (needs a drive).
                    c.autoProvisional = (t.source == 'none')
                end
            end
        end
        cb(data or {})
    end)
end)

-- Set/clear a car's tier override (tier 0 = clear/auto).
RegisterNUICallback('admin:setCarTier', function(data, cb)
    lib.callback('hk-race:admin:setCarTier', false, function(res)
        cb(res or {})
    end, tonumber(data.hash), tonumber(data.tier), data.model, data.name)
end)

-- Surface NUI-side (JS) errors, which are otherwise completely silent.
RegisterNUICallback('nuiError', function(data, cb)
    print(('[hk-race] NUI JS ERROR in %s: %s'):format(tostring(data and data.where), tostring(data and data.msg)))
    cb('ok')
end)

-- Global ESC handling handled in JS via fetch close.
