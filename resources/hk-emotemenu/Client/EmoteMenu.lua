-- hk-emotemenu — NUI bridge (replaces the old NativeUI menu)
-- Builds the emote catalog from DP.* + Categories.lua and hands it to the HTML
-- NUI. All playback still goes through the untouched engine functions
-- (EmoteMenuStart / WalkMenuStart / EmoteCancel / shared-emote flow), so every
-- animations:client:* integration keeps working exactly as before.

TriggerServerEvent("dp:CheckVersion")

PlayerData = QBCore.Functions.GetPlayerData()
isLoggedIn = false
lang = Config.MenuLanguage

local menuOpen   = false
local mouseMode  = false            -- false = keyboard-drive (ped free to move); true = cursor
local FavoriteEmote = ""            -- quick-fav for the hold keybind (favorites[1])

-- Control IDs polled while the menu is open in keyboard mode (see
-- docs.fivem.net/game-references/controls). Arrow keys live in the CELLPHONE
-- group, so polling them does NOT disturb WASD movement — the player keeps
-- walking while browsing. Each maps to a nav action the NUI understands.
local NAV = {
    { ctrl = 172, act = 'up'    },  -- INPUT_CELLPHONE_UP      (Arrow Up)
    { ctrl = 173, act = 'down'  },  -- INPUT_CELLPHONE_DOWN    (Arrow Down)
    { ctrl = 174, act = 'left'  },  -- INPUT_CELLPHONE_LEFT    (Arrow Left)
    { ctrl = 175, act = 'right' },  -- INPUT_CELLPHONE_RIGHT   (Arrow Right)
    { ctrl = 176, act = 'enter' },  -- INPUT_CELLPHONE_SELECT  (Enter)
}

-- ---- per-player persistence (KVP) -----------------------------------------
local KVP_FAV    = 'hk-emotemenu:favorites'
local KVP_RECENT = 'hk-emotemenu:recent'

local function readList(key)
    local raw = GetResourceKvpString(key)
    if not raw or raw == '' then return {} end
    local ok, t = pcall(json.decode, raw)
    return (ok and type(t) == 'table') and t or {}
end

local function writeList(key, t)
    SetResourceKvp(key, json.encode(t))
end

local function indexOf(t, v) for i, x in ipairs(t) do if x == v then return i end end return nil end

-- ---- QBCore player data ----------------------------------------------------
RegisterNetEvent('QBCore:Client:OnPlayerLoaded', function()
    PlayerData = QBCore.Functions.GetPlayerData()
    isLoggedIn = true
end)
RegisterNetEvent('QBCore:Client:OnPlayerUnload', function()
    PlayerData = {}
    isLoggedIn = false
end)
RegisterNetEvent('QBCore:Player:SetPlayerData', function(val)
    PlayerData = val
end)

function ShowNotification(text)
    SetNotificationTextEntry("STRING")
    AddTextComponentString(text)
    DrawNotification(false, false)
end

function firstToUpper(str)
    return (str:gsub("^%l", string.upper))
end

-- Hold-key quick favorite (kept from dpemotes; now backed by the favorites list)
Citizen.CreateThread(function()
    while true do
        if Config.FavKeybindEnabled and PlayerData.metadata and not PlayerData.metadata['inlaststand'] and not PlayerData.metadata['isdead'] then
            if IsControlPressed(0, Config.FavKeybind) and not IsPedSittingInAnyVehicle(PlayerPedId()) then
                local favs = readList(KVP_FAV)
                FavoriteEmote = favs[1] or FavoriteEmote
                if FavoriteEmote ~= "" then
                    EmoteCommandStart(nil, { FavoriteEmote, 0 })
                    Wait(3000)
                end
            end
        end
        Citizen.Wait(1)
    end
end)

-- ===========================================================================
-- Catalog builder — turns the DP.* tables into a NUI-friendly payload once.
-- Entry shape from AnimationList: { dict, anim, "Display Name", AnimationOptions=... }
-- so the display label is element [3]; the key is the table key.
-- ===========================================================================
local catalog = nil   -- cached after first build

local function labelOf(entry, key)
    local disp = entry[3]
    if type(disp) == 'string' and disp ~= '' then return disp end
    return firstToUpper(key)
end

local function collect(tbl)
    local out = {}
    for key, entry in pairs(tbl) do
        out[#out + 1] = { id = key, label = labelOf(entry, key) }
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

-- Emotes get sub-categorised via HKEmote.CategoryOf; everything else is flat.
local function collectEmotes()
    local byCat = {}
    for key, entry in pairs(DP.Emotes) do
        local cat = HKEmote.CategoryOf(key)
        if cat == 'adult' and not Config.AdultEmotesEnabled then goto continue end
        byCat[cat] = byCat[cat] or {}
        byCat[cat][#byCat[cat] + 1] = { id = key, label = labelOf(entry, key) }
        ::continue::
    end
    -- emit in CategoryOrder, dropping empty groups
    local groups = {}
    for _, cat in ipairs(HKEmote.CategoryOrder) do
        local items = byCat[cat.id]
        if items and #items > 0 then
            table.sort(items, function(a, b) return a.id < b.id end)
            groups[#groups + 1] = { id = cat.id, en = cat.en, zh = cat.zh, icon = cat.icon, items = items }
        end
    end
    return groups
end

-- Walks: DP.Walks maps a display key -> { clipset }. The NUI sends back the
-- clipset (what WalkMenuStart wants); we add Normal + Injured like the old menu.
local function collectWalks()
    local out = {
        { id = '__reset__',      label = '正常 Normal (Reset)' },
        { id = 'move_m@injured', label = '受傷 Injured' },
    }
    for key, entry in pairs(DP.Walks) do
        out[#out + 1] = { id = entry[1], label = key }
    end
    table.sort(out, function(a, b) return a.label < b.label end)
    return out
end

-- Moods/expressions: DP.Expressions maps display key -> {"Expression", name}.
-- EmoteMenuStart(expression) expects the DP.Expressions *key*, so send the key.
local function collectMoods()
    local out = { { id = '__reset__', label = '正常 Normal (Reset)' } }
    for key in pairs(DP.Expressions) do
        out[#out + 1] = { id = key, label = key }
    end
    table.sort(out, function(a, b) return a.label < b.label end)
    return out
end

local function buildCatalog()
    if catalog then return catalog end
    catalog = {
        emotes = collectEmotes(),          -- grouped [{id,en,zh,icon,items[]}]
        dances = collect(DP.Dances),       -- flat [{id,label}]
        props  = collect(DP.PropEmotes),
        shared = collect(DP.Shared),
        walks  = collectWalks(),
        moods  = collectMoods(),
        config = {
            walks   = Config.WalkingStylesEnabled and true or false,
            moods   = Config.ExpressionsEnabled and true or false,
            shared  = Config.SharedEmotesEnabled and true or false,
            adult   = Config.AdultEmotesEnabled and true or false,
            group   = Config.GroupEmotesEnabled and true or false,
        },
    }
    return catalog
end

-- ===========================================================================
-- Open / close
-- ===========================================================================
-- Apply the current input mode's NUI focus:
--   mouseMode = false -> no focus at all: cursor hidden, ALL game input still
--                        goes to the player, so they can walk while browsing.
--                        Arrow-key nav is polled in Lua (see the thread below).
--   mouseMode = true  -> full focus: cursor shown, clicking works, ped locked.
local function applyFocus()
    if mouseMode then
        SetNuiFocus(true, true)
        SetNuiFocusKeepInput(false)
    else
        SetNuiFocus(false, false)
    end
    SendNUIMessage({ action = 'mode', mouse = mouseMode })
end

function OpenEmoteMenu()
    if menuOpen then return end
    menuOpen  = true
    mouseMode = false            -- always open in keyboard mode (ped free)
    SendNUIMessage({
        action    = 'open',
        catalog   = buildCatalog(),
        favorites = readList(KVP_FAV),
        recent    = readList(KVP_RECENT),
        mouse     = false,
    })
    applyFocus()
    if HKGroup then HKGroup.SyncToNUI() end   -- populate the Group tab immediately
    -- Keyboard-drive loop: poll nav keys + the `~` toggle while open. Runs only
    -- for the lifetime of this open session.
    Citizen.CreateThread(function()
        while menuOpen do
            -- `~`/backtick (INPUT_REPLAY_START_STOP_RECORDING = 243) toggles mouse mode
            if IsControlJustPressed(0, 243) then
                mouseMode = not mouseMode
                applyFocus()
            end

            if not mouseMode then
                -- Disable the keys we consume so they don't leak to other
                -- resources (e.g. Enter opening chat), then read them via the
                -- disabled-control check. Movement keys are NOT disabled, so the
                -- player keeps walking/driving while the menu is open.
                DisableControlAction(0, 172, true)  -- arrow up
                DisableControlAction(0, 173, true)  -- arrow down
                DisableControlAction(0, 174, true)  -- arrow left
                DisableControlAction(0, 175, true)  -- arrow right
                DisableControlAction(0, 176, true)  -- enter
                DisableControlAction(0, 177, true)  -- backspace
                -- NOTE: favorite (F) is NOT bound in keyboard mode — F is
                -- INPUT_ENTER (vehicle-enter); disabling it would block getting
                -- into cars while browsing. Favorite via mouse mode instead.

                for _, n in ipairs(NAV) do
                    if IsDisabledControlJustPressed(0, n.ctrl) then
                        SendNUIMessage({ action = 'nav', key = n.act })
                    end
                end
                -- X (control 73) = Stop Emote in keyboard mode. The global
                -- X-to-cancel (Client/Emote.lua) already stops the player's own
                -- emote; here we additionally broadcast so a LEADER's X stops the
                -- whole group. (Not disabled — X on foot is harmless to leave live.)
                if IsControlJustPressed(0, 73) then
                    if HKGroup and HKGroup.IsActive() and HKGroup.IsLeader() then
                        TriggerServerEvent('hk-emote:group:play', 'cancel', 'c')
                    else
                        EmoteCancel()
                        DestroyAllProps()
                    end
                end
                -- Backspace closes. ESC isn't trapped here (NUI has no focus in
                -- keyboard mode) to avoid eating the pause menu, so Backspace is
                -- the keyboard-mode close key; ESC works after toggling to mouse.
                -- BUT if an invite prompt is up, Backspace means "decline" (handled
                -- in Group.lua) — don't also close the menu on the same press.
                if IsDisabledControlJustPressed(0, 177) then   -- INPUT_CELLPHONE_CANCEL
                    if not (HKGroup and HKGroup.HasPendingInvite()) then
                        closeMenu()
                    end
                end
            end
            Citizen.Wait(0)
        end
    end)
end

function closeMenu()
    if not menuOpen then return end
    menuOpen  = false
    mouseMode = false
    SetNuiFocus(false, false)
    SendNUIMessage({ action = 'close' })
end

-- ---- recent tracking -------------------------------------------------------
local function pushRecent(key)
    local rec = readList(KVP_RECENT)
    local at = indexOf(rec, key)
    if at then table.remove(rec, at) end
    table.insert(rec, 1, key)
    local max = Config.RecentCount or 12
    while #rec > max do table.remove(rec) end
    writeList(KVP_RECENT, rec)
end

-- ===========================================================================
-- NUI callbacks — all playback routes through the existing engine functions.
-- ===========================================================================
RegisterNUICallback('close', function(_, cb)
    closeMenu()
    cb('ok')
end)

-- Toggle input mode from the NUI side. Needed for the mouse->keyboard direction:
-- while in mouse mode the NUI owns the keyboard, so Lua can't see the `~` press;
-- the JS backtick handler posts here instead. (keyboard->mouse is polled in Lua.)
RegisterNUICallback('toggleMode', function(_, cb)
    if menuOpen then
        mouseMode = not mouseMode
        applyFocus()
    end
    cb('ok')
end)

-- Play any catalog item. `kind` selects the engine path; matches the old menu.
-- Group behaviour: while in a group, only the LEADER may drive playback — the
-- pick is broadcast so every member plays the same thing in place. Members get
-- a "leader controls" toast and nothing plays. Cancel is always allowed locally.
RegisterNUICallback('play', function(data, cb)
    local kind = data and data.kind
    local id   = data and data.id
    if not kind or not id then cb('bad') return end

    if HKGroup and HKGroup.IsActive() then
        if HKGroup.IsLeader() then
            -- Leader drives the group: broadcast the pick (incl. cancel) to all.
            if kind ~= 'cancel' then HKGroup.RememberPersonal(kind, id) end
            TriggerServerEvent('hk-emote:group:play', kind, id)
            if kind == 'emote' or kind == 'dance' or kind == 'prop' then pushRecent(id) end
            cb('ok')
            return
        elseif kind == 'cancel' then
            -- A member can always stop their OWN body, without affecting others.
            EmoteCancel()
            DestroyAllProps()
            cb('ok')
            return
        else
            SimpleNotify('隊長控制緊表情 · The leader controls the group')
            cb('member')
            return
        end
    end

    -- Solo (not grouped): remember personal walk/mood for later group-exit restore.
    if kind == 'walk' or kind == 'mood' then
        if HKGroup then HKGroup.RememberPersonal(kind, id) end
    end

    if kind == 'emote' then
        EmoteMenuStart(id, 'emotes')
        pushRecent(id)
    elseif kind == 'dance' then
        EmoteMenuStart(id, 'dances')
        pushRecent(id)
    elseif kind == 'prop' then
        EmoteMenuStart(id, 'props')
        pushRecent(id)
    elseif kind == 'walk' then
        if id == '__reset__' then
            ResetPedMovementClipset(PlayerPedId())
        else
            WalkMenuStart(id)
        end
    elseif kind == 'mood' then
        if id == '__reset__' then
            ClearFacialIdleAnimOverride(PlayerPedId())
        else
            EmoteMenuStart(id, 'expression')
        end
    elseif kind == 'cancel' then
        EmoteCancel()
        DestroyAllProps()
    end
    cb('ok')
end)

-- Shared emote: invite the closest player (mirrors the old sharemenu flow).
RegisterNUICallback('share', function(data, cb)
    if not Config.SharedEmotesEnabled then cb('off') return end
    local id = data and data.id
    if not id or DP.Shared[id] == nil then cb('bad') return end
    local target, distance = GetClosestPlayer()
    if distance ~= -1 and distance < 3 then
        TriggerServerEvent("ServerEmoteRequest", GetPlayerServerId(target), id)
        SimpleNotify(Config.Languages[lang]['sentrequestto'] .. GetPlayerName(target))
    else
        SimpleNotify(Config.Languages[lang]['nobodyclose'])
    end
    cb('ok')
end)

-- Toggle a favorite. Favorites[1] doubles as the hold-key quick emote.
RegisterNUICallback('favorite', function(data, cb)
    local id = data and data.id
    if not id then cb('bad') return end
    local favs = readList(KVP_FAV)
    local at = indexOf(favs, id)
    if at then table.remove(favs, at) else table.insert(favs, id) end
    writeList(KVP_FAV, favs)
    FavoriteEmote = favs[1] or ""
    cb({ favorites = favs })
end)

-- ===========================================================================
-- Events / integration (names preserved from dpemotes)
-- ===========================================================================
RegisterNetEvent('animations:client:EmoteMenu', function()
    if PlayerData.metadata and (PlayerData.metadata['inlaststand'] or PlayerData.metadata['isdead']) then return end
    OpenEmoteMenu()
end)

RegisterNetEvent("dp:RecieveMenu", function()   -- open from another resource
    OpenEmoteMenu()
end)

-- Version banner state kept as a no-op hook so Server/Updates.lua stays happy.
RegisterNetEvent("dp:Update", function(state)
    UpdateAvailable = state
end)

-- Safety: never leave NUI focus stuck if the resource stops while open.
AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() and menuOpen then
        SetNuiFocus(false, false)
    end
end)

-- Re-fetch player data on restart without a re-login (kept from dpemotes).
AddEventHandler('onResourceStart', function(resource)
    if resource == GetCurrentResourceName() then
        Wait(200)
        PlayerData = QBCore.Functions.GetPlayerData()
        isLoggedIn = true
    end
end)
