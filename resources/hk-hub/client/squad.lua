-- hk-hub — squad (client)
-- Team system UI backing (the F5 → Tools → Squad panel). Handles:
--   • squad state sync from the server
--   • real GTA minimap + pause-map blips for online teammates (name + colour)
--   • over-head DUI tags (name + live distance) on nearby teammates
--   • pma-voice private squad radio (join/leave, PTT rides pma-voice's own bind)
--   • shared atlas map positions + "set GTA waypoint to member"
-- All NUI callbacks are namespaced squad* and relay to the server callbacks.

if not (HubConfig.Squad and HubConfig.Squad.enabled) then return end

local QBCore  = exports['qb-core']:GetCoreObject()
local CFG     = HubConfig.Squad

-- ---- Local squad state -----------------------------------------------------
local State = {
    squadID  = 0,
    isLeader = false,
    name     = '',
    code     = nil,       -- join code (leader shares this)
    radio    = nil,       -- assigned channel from the server
    radioOn  = false,     -- have we joined pma-voice on the squad channel?
}

local RESOURCE = GetCurrentResourceName()

-- ---- pma-voice radio -------------------------------------------------------

local function voiceReady()
    return GetResourceState('pma-voice') == 'started'
end

local function joinRadio()
    local r = CFG.radio or {}
    if not r.enabled or not voiceReady() then return end
    local ch = tonumber(State.radio)
    if not ch or ch <= 0 then return end
    pcall(function() exports['pma-voice']:setRadioChannel(ch) end)
    State.radioOn = true
end

local function leaveRadio()
    if not voiceReady() then State.radioOn = false return end
    pcall(function() exports['pma-voice']:setRadioChannel(0) end)
    State.radioOn = false
end

-- ---- Real minimap / pause-map blips ---------------------------------------
-- One blip per teammate. If their ped is streamed in we attach an ENTITY blip
-- (tracks them live for free); otherwise we place a COORD blip at the last known
-- position from the server relay and nudge it as fresh positions arrive.

local memberBlips = {}   -- [serverId] = { blip, entity = ped|0, name }
local lastPositions = {} -- [serverId] = { x, y, z, name, owner, role } from server

-- GTA blip index → RGB (for matching the 3D over-head tag to the blip colour).
-- Only SAFE blip IDs (no enemy/friendly flag variant) — see the server
-- ALLOWED_BLIP_COLORS note. RGBs are the ACTUAL in-game blip colours (from the
-- FiveM blips doc) so the over-head 3D tag / overlay ring matches the minimap
-- blip exactly. Do NOT approximate — a wrong value desyncs tag/ring from the blip.
local BLIP_RGB = {
    [0]  = { 254, 254, 254 }, [1]  = { 224, 50, 50 },   [8]  = { 254, 122, 195 },
    [11] = { 141, 206, 167 }, [17] = { 234, 142, 80 },  [25] = { 12, 123, 86 },
    [26] = { 122, 195, 254 }, [27] = { 171, 60, 230 },  [38] = { 44, 109, 184 },
    [40] = { 76, 76, 76 },    [46] = { 236, 240, 41 },  [47] = { 255, 154, 24 },
    [48] = { 246, 68, 165 },  [50] = { 138, 109, 227 },
}

-- Colour a teammate's blip: their own chosen colour wins; else leader gold or a
-- per-slot palette fallback.
local function blipColorFor(idx, isOwner, chosen)
    if chosen and BLIP_RGB[chosen] then return chosen end
    local b = CFG.blips or {}
    if isOwner then return b.leader or 46 end
    local pal = b.palette or { 38, 25, 48 }
    return pal[((idx - 1) % #pal) + 1] or 38
end

local function removeBlip(serverId)
    local e = memberBlips[serverId]
    if not e then return end
    if e.blip and DoesBlipExist(e.blip) then RemoveBlip(e.blip) end
    memberBlips[serverId] = nil
end

local function removeAllBlips()
    for id in pairs(memberBlips) do removeBlip(id) end
    memberBlips = {}
end

local function styleBlip(blip, name, color)
    local b = CFG.blips or {}
    SetBlipSprite(blip, b.sprite or 1)
    SetBlipScale(blip, b.scale or 0.85)
    SetBlipColour(blip, color)
    SetBlipCategory(blip, 7)   -- group under "Other Players" style heading
    if b.showNames ~= false and name and name ~= '' then
        BeginTextCommandSetBlipName('STRING')
        AddTextComponentSubstringPlayerName(name)
        EndTextCommandSetBlipName(blip)
    end
    ShowHeadingIndicatorOnBlip(blip, true)
end

-- Rebuild/refresh blips from lastPositions + streamed peds. Called on a timer
-- and whenever a fresh position batch arrives.
local function refreshBlips()
    local b = CFG.blips or {}
    if not b.enabled or State.squadID == 0 then removeAllBlips() return end

    local seen = {}
    local idx = 0
    for serverId, pos in pairs(lastPositions) do
        idx = idx + 1
        seen[serverId] = true
        local color = blipColorFor(idx, pos.owner, pos.blipColor)

        -- Prefer an entity blip when the teammate's ped is streamed locally.
        local plyIdx = GetPlayerFromServerId(serverId)
        local ped = (plyIdx ~= -1) and GetPlayerPed(plyIdx) or 0
        local streamed = ped and ped ~= 0 and DoesEntityExist(ped)

        local e = memberBlips[serverId]
        if streamed then
            -- (Re)make as an entity blip if we don't already have one on this ped.
            if not e or e.entity ~= ped or not (e.blip and DoesBlipExist(e.blip)) then
                removeBlip(serverId)
                local blip = AddBlipForEntity(ped)
                styleBlip(blip, pos.name, color)
                memberBlips[serverId] = { blip = blip, entity = ped, name = pos.name }
            else
                SetBlipColour(e.blip, color)
            end
        else
            -- Coord blip fallback; move it if it already exists.
            if not e or e.entity ~= 0 or not (e.blip and DoesBlipExist(e.blip)) then
                removeBlip(serverId)
                local blip = AddBlipForCoord(pos.x, pos.y, pos.z or 0.0)
                styleBlip(blip, pos.name, color)
                memberBlips[serverId] = { blip = blip, entity = 0, name = pos.name }
            else
                SetBlipCoords(e.blip, pos.x, pos.y, pos.z or 0.0)
                SetBlipColour(e.blip, color)
            end
        end
    end

    -- Drop blips for members no longer in the position set.
    for serverId in pairs(memberBlips) do
        if not seen[serverId] then removeBlip(serverId) end
    end
end

-- ---- Shared-waypoint minimap blips -----------------------------------------
-- Per-waypoint show state: 0=hidden, 1=shown, 2=flashing. This is now a SHARED,
-- server-authoritative status (map_mode on the row) so a toggle by any member
-- pings the spot on everyone's minimap. wpModes mirrors the last synced rows;
-- toggling round-trips to the server, which re-pushes to the whole squad.
local wpBlips = {}       -- [wpId] = { blip }
local wpModes = {}       -- [wpId] = 0|1|2   (mirror of server map_mode)
local wpCache = {}       -- [wpId] = { x, y, z, color, name }  latest coords/colour

-- Match a waypoint's hex colour to the nearest GTA blip-colour index.
-- Waypoint hex → nearest SAFE blip-colour index (no enemy/friendly flag).
-- Keys are the ACTUAL GTA blip hexes (match WP_COLORS in html/squad.js), each
-- pointing at the exact blip ID it renders as — so the minimap blip matches the
-- colour shown on the atlas canvas. Legacy hexes kept so pre-existing DB rows
-- still resolve to a sane blip.
local WP_HEX_TO_BLIP = {
    ['#7ac3fe'] = 26, ['#e03232'] = 1,  ['#ea8e50'] = 17, ['#ecf029'] = 46,
    ['#8dcea7'] = 11, ['#ab3ce6'] = 27, ['#fe7ac3'] = 8,  ['#fefefe'] = 0,
    -- legacy hexes from older waypoints
    ['#00c8ff'] = 26, ['#ff5252'] = 1,  ['#ffb454'] = 17, ['#ffe14d'] = 46,
    ['#5ee06b'] = 11, ['#a569ff'] = 27, ['#ff82dc'] = 8,  ['#ffffff'] = 0,
}
local function wpBlipColor(hex)
    return WP_HEX_TO_BLIP[string.lower(tostring(hex or ''))] or 26
end

local function removeWpBlip(wpId)
    local e = wpBlips[wpId]
    if e and e.blip and DoesBlipExist(e.blip) then RemoveBlip(e.blip) end
    wpBlips[wpId] = nil
end

local function removeAllWpBlips()
    for id in pairs(wpBlips) do removeWpBlip(id) end
    wpBlips = {}
end

-- (Re)apply the blip for one waypoint from its cached coords + current mode.
local function applyWpBlip(wpId)
    local mode = wpModes[wpId] or 0
    local c = wpCache[wpId]
    if mode == 0 or not c or c.x == nil then removeWpBlip(wpId) return end

    local cfg = (CFG or {}).waypointBlip or {}
    local e = wpBlips[wpId]
    if not e or not (e.blip and DoesBlipExist(e.blip)) then
        local blip = AddBlipForCoord(c.x + 0.0, c.y + 0.0, (c.z or 0.0) + 0.0)
        SetBlipSprite(blip, cfg.sprite or 1)
        SetBlipScale(blip, cfg.scale or 0.9)
        SetBlipAsShortRange(blip, cfg.shortRange == true)
        e = { blip = blip }
        wpBlips[wpId] = e
    else
        SetBlipCoords(e.blip, c.x + 0.0, c.y + 0.0, (c.z or 0.0) + 0.0)
    end
    SetBlipColour(e.blip, wpBlipColor(c.color))
    SetBlipFlashes(e.blip, mode == 2)
    if c.name and c.name ~= '' then
        BeginTextCommandSetBlipName('STRING')
        AddTextComponentSubstringPlayerName(c.name)
        EndTextCommandSetBlipName(e.blip)
    end
end

-- Refresh the cache of waypoint coords/colours (called when the roster of
-- waypoints changes) and re-apply every blip per its saved mode.
local function syncWpBlips(rows)
    local live = {}
    for _, w in ipairs(rows or {}) do
        local id = tostring(w.id)
        live[id] = true
        if w.wx ~= nil and w.wy ~= nil then
            wpCache[id] = { x = w.wx, y = w.wy, z = w.wz or 0.0, color = w.color, name = w.name }
        end
        -- Mode is server-authoritative now — mirror the row's shared map_mode.
        wpModes[id] = tonumber(w.mapMode) or 0
        applyWpBlip(id)
    end
    -- Drop blips/state for waypoints that no longer exist (fixes a deleted-but-
    -- still-shown blip lingering on the minimap).
    for id in pairs(wpModes) do
        if not live[id] then wpModes[id] = nil; wpCache[id] = nil; removeWpBlip(id) end
    end
    for id in pairs(wpCache) do
        if not live[id] then wpCache[id] = nil end
    end
    for id in pairs(wpBlips) do
        if not live[id] then removeWpBlip(id) end
    end
end

-- ---- Over-head teammate tags (native 3D text: name + live distance) --------
-- Ported from af-squad's DUI tags but drawn with native 3D text — reliable on
-- this CEF build, no runtime-txd/DUI plumbing, matches the HK group-HUD pattern.

local HEAD_BONE = 31086   -- SKEL_Head

local function drawTag3D(x, y, z, name, distTxt, r, g, b)
    SetDrawOrigin(x, y, z, 0)
    -- name
    SetTextScale(0.34, 0.34)
    SetTextFont(4)
    SetTextProportional(true)
    SetTextColour(r, g, b, 225)
    SetTextOutline()
    SetTextCentre(true)
    SetTextEntry('STRING')
    AddTextComponentSubstringPlayerName(name)
    DrawText(0.0, 0.0)
    -- distance (smaller, below)
    if distTxt and distTxt ~= '' then
        SetTextScale(0.26, 0.26)
        SetTextFont(4)
        SetTextColour(255, 255, 255, 180)
        SetTextOutline()
        SetTextCentre(true)
        SetTextEntry('STRING')
        AddTextComponentSubstringPlayerName(distTxt)
        DrawText(0.0, 0.028)
    end
    ClearDrawOrigin()
end

CreateThread(function()
    local t = CFG.tags or {}
    local maxDist = tonumber(t.maxDistance) or 250.0
    local maxSq   = maxDist * maxDist
    while true do
        if not t.enabled or State.squadID == 0 or IsPauseMenuActive() then
            Wait(400)
        else
            local myPed = PlayerPedId()
            local myCoords = GetEntityCoords(myPed)
            local drew = false
            for serverId in pairs(lastPositions) do
                local plyIdx = GetPlayerFromServerId(serverId)
                if plyIdx ~= -1 and NetworkIsPlayerActive(plyIdx) then
                    local ped = GetPlayerPed(plyIdx)
                    if ped and ped ~= 0 and DoesEntityExist(ped) and not IsEntityDead(ped) then
                        local head = GetPedBoneCoords(ped, HEAD_BONE, 0.0, 0.0, 0.0)
                        local tagZ = head.z + 0.30
                        local dx, dy, dz = head.x - myCoords.x, head.y - myCoords.y, tagZ - myCoords.z
                        local distSq = dx*dx + dy*dy + dz*dz
                        if distSq <= maxSq then
                            local dist = math.sqrt(distSq)
                            local pos = lastPositions[serverId] or {}
                            local firstName = (pos.name or 'Squad'):match('^%S+') or pos.name or 'Squad'
                            -- Match the tag to the teammate's chosen blip colour;
                            -- else cyan for members, softer gold for the leader.
                            local r, g, b = 0, 200, 255
                            if pos.blipColor and BLIP_RGB[pos.blipColor] then
                                r, g, b = table.unpack(BLIP_RGB[pos.blipColor])
                            elseif pos.owner then
                                r, g, b = 255, 210, 90
                            end
                            drawTag3D(head.x, head.y, tagZ, firstName, ('%dm'):format(math.floor(dist + 0.5)), r, g, b)
                            drew = true
                        end
                    end
                end
            end
            Wait(drew and 0 or 200)
        end
    end
end)

-- ---- Server → client state --------------------------------------------------

-- Forward-declared: applyState() calls it, but it's defined further down.
local fetchAndSyncWpBlips

local function applyState(data)
    data = data or {}
    local prevSquad = State.squadID
    local prevRadio = State.radio
    State.squadID  = tonumber(data.squadID) or 0
    State.isLeader = data.isLeader == true
    State.name     = data.name or ''
    State.code     = data.code
    State.radio    = tonumber(data.radio)

    if State.squadID == 0 then
        -- Left / disbanded / kicked: tear everything down.
        lastPositions = {}
        removeAllBlips()
        removeAllWpBlips()
        wpModes = {}
        wpCache = {}
        leaveRadio()
    else
        -- Auto-join the squad radio on (re)assignment if configured.
        local r = CFG.radio or {}
        if r.enabled and r.autoJoin ~= false then
            if not State.radioOn or prevRadio ~= State.radio then joinRadio() end
        end
        -- Refresh the waypoint coord cache so any re-toggled blips can re-apply.
        if prevSquad ~= State.squadID then fetchAndSyncWpBlips() end
    end

    -- Notify the NUI so an open panel refreshes its roster.
    SendNUIMessage({ action = 'squadState', state = {
        squadID = State.squadID, isLeader = State.isLeader,
        name = State.name, code = State.code, radio = State.radio, radioOn = State.radioOn,
    }})
end

RegisterNetEvent('hk-hub:squad:setCurrent', function(data) applyState(data) end)

RegisterNetEvent('hk-hub:squad:destroyed', function()
    applyState({ squadID = 0 })
    QBCore.Functions.Notify('你的小隊已解散。 Your squad was disbanded.', 'error')
end)

RegisterNetEvent('hk-hub:squad:kicked', function()
    applyState({ squadID = 0 })
    QBCore.Functions.Notify('你已被踢出小隊。 You were removed from the squad.', 'error')
end)

-- Pull the squad's waypoints and refresh the minimap blips (independent of the
-- panel being open, so toggled blips stay live with F5 closed).
function fetchAndSyncWpBlips()
    if State.squadID == 0 then removeAllWpBlips() return end
    QBCore.Functions.TriggerCallback('hk-hub:squad:getWaypoints', function(rows)
        syncWpBlips(rows or {})
    end, State.squadID)
end

RegisterNetEvent('hk-hub:squad:waypointsUpdated', function()
    SendNUIMessage({ action = 'squadWaypointsChanged' })
    fetchAndSyncWpBlips()   -- keep minimap blips in step with edits/removals
end)

-- Live squad-chat message pushed from the server → forward to the NUI panel.
RegisterNetEvent('hk-hub:squad:message', function(msg)
    if not msg then return end
    SendNUIMessage({ action = 'squadChatMessage', message = msg })
end)

-- Incoming invite → confirm prompt (native, no ox_lib). Responds to the server.
RegisterNetEvent('hk-hub:squad:invited', function(data)
    if not data or not data.squadID then return end
    SendNUIMessage({ action = 'squadInvite', invite = {
        squadID       = data.squadID,
        inviterSource = data.inviterSource,
        inviterName   = data.inviterName or ('ID ' .. tostring(data.inviterSource)),
        squadName     = data.squadName or ('Squad #' .. tostring(data.squadID)),
    }})
    QBCore.Functions.Notify(('%s 邀請你加入小隊 %s — 開啟 F5 → 小隊 接受。'):format(
        data.inviterName or '?', data.squadName or '?'), 'primary', 8000)
end)

-- ---- Live position polling -------------------------------------------------
-- Pull other members' world coords ~1.3Hz while in a squad; feeds both the real
-- minimap coord-blips and the atlas dots (relayed to the NUI when open).

CreateThread(function()
    while true do
        if State.squadID == 0 then
            Wait(1500)
        else
            QBCore.Functions.TriggerCallback('hk-hub:squad:getPositions', function(rows)
                local fresh = {}
                for _, row in ipairs(rows or {}) do
                    local id = tonumber(row.id) or 0
                    if id > 0 then
                        fresh[id] = { x = row.x, y = row.y, z = row.z, name = row.name, owner = row.owner, role = row.role, blipColor = tonumber(row.blipColor), avatar = row.avatar }
                    end
                end
                lastPositions = fresh
                refreshBlips()
                -- If the panel is open, forward positions for the atlas map.
                SendNUIMessage({ action = 'squadPositions', positions = rows or {} })
            end)
            Wait(1300)
        end
    end
end)

-- Keep entity/coord blips fresh between server batches (peds stream in/out).
CreateThread(function()
    while true do
        if State.squadID ~= 0 and (CFG.blips or {}).enabled then
            refreshBlips()
            Wait(1000)
        else
            Wait(1500)
        end
    end
end)

-- ---- Always-on member overlay (top-right HUD) ------------------------------
-- One card per ONLINE teammate: portrait + name + distance + mic ring. Both live
-- signals are client-LOCAL (no server round-trip): distance from the live ped
-- when streamed else the server-relayed coords in lastPositions; mic from
-- pma-voice's own MumbleIsPlayerTalking. Pushed to the NUI on a fast tick.
local overlayShown = false

-- Who's transmitting on the SQUAD RADIO right now. pma-voice broadcasts
-- setTalkingOnRadio(plySource, enabled) to everyone on the channel; plySource is
-- the talker's server id. We mirror it so the overlay mic reflects walkie-talkie
-- transmits (not proximity voice). Includes ourself when WE hold PTT.
local radioTalking = {}   -- [serverId] = true while transmitting
RegisterNetEvent('pma-voice:setTalkingOnRadio', function(plySource, enabled)
    if enabled then radioTalking[plySource] = true else radioTalking[plySource] = nil end
end)
RegisterNetEvent('pma-voice:radioActive', function(active)
    local me = GetPlayerServerId(PlayerId())
    if active then radioTalking[me] = true else radioTalking[me] = nil end
end)

CreateThread(function()
    local ov = CFG.overlay or {}
    local maxDist = tonumber(ov.maxDistance) or 8000.0
    while true do
        if not ov.enabled or State.squadID == 0 then
            if overlayShown then
                SendNUIMessage({ action = 'squadOverlay', show = false, members = {} })
                overlayShown = false
            end
            Wait(600)
        else
            local myPed = PlayerPedId()
            local myCoords = GetEntityCoords(myPed)
            local rows = {}
            for serverId, pos in pairs(lastPositions) do
                local plyIdx = GetPlayerFromServerId(serverId)
                local ped, active = nil, false
                if plyIdx ~= -1 and NetworkIsPlayerActive(plyIdx) then
                    ped = GetPlayerPed(plyIdx)
                    active = ped and ped ~= 0 and DoesEntityExist(ped)
                end
                -- Distance: prefer the live ped when streamed (smooth), else the
                -- server-relayed coords (works even when far / not streamed).
                local dist = nil
                local px, py, pz
                if active then
                    local pc = GetEntityCoords(ped)
                    px, py, pz = pc.x, pc.y, pc.z
                elseif pos.x then
                    px, py, pz = pos.x, pos.y, pos.z or myCoords.z
                end
                if px then
                    local dx, dy, dz = px - myCoords.x, py - myCoords.y, pz - myCoords.z
                    dist = math.floor(math.sqrt(dx*dx + dy*dy + dz*dz) + 0.5)
                    if dist > maxDist then dist = -1 end   -- -1 => "far" in NUI
                end
                rows[#rows + 1] = {
                    id       = serverId,
                    name     = pos.name or 'Squad',
                    avatar   = pos.avatar,
                    owner    = pos.owner == true,
                    blipColor = tonumber(pos.blipColor),
                    dist     = dist,                                   -- metres, -1 far, nil unknown
                    talking  = radioTalking[serverId] == true,         -- transmitting on squad radio
                }
            end
            -- Hide entirely if we're solo (no other online members).
            local show = not (ov.hideSolo ~= false and #rows == 0)
            SendNUIMessage({ action = 'squadOverlay', show = show, members = rows })
            overlayShown = show
            Wait(tonumber(ov.refreshMs) or 250)
        end
    end
end)

-- ---- NUI callbacks (panel → server) ---------------------------------------

-- Full snapshot for the panel when it opens (state + roster).
RegisterNUICallback('squadGetState', function(_, cb)
    QBCore.Functions.TriggerCallback('hk-hub:squad:getState', function(state)
        cb(state or { squadID = 0, limit = (CFG.limit or 4) })
    end)
end)

RegisterNUICallback('squadCreate', function(data, cb)
    QBCore.Functions.TriggerCallback('hk-hub:squad:create', function(res)
        cb(res or { ok = false })
    end, data and data.name)
end)

RegisterNUICallback('squadJoinByCode', function(data, cb)
    QBCore.Functions.TriggerCallback('hk-hub:squad:joinByCode', function(res)
        cb(res or { ok = false })
    end, data and data.code)
end)

RegisterNUICallback('squadInvite', function(data, cb)
    QBCore.Functions.TriggerCallback('hk-hub:squad:invite', function(res)
        cb(res or { ok = false })
    end, data and data.targetId)
end)

RegisterNUICallback('squadRespondInvite', function(data, cb)
    TriggerServerEvent('hk-hub:squad:respondInvite', {
        squadID       = data and data.squadID,
        inviterSource = data and data.inviterSource,
        accepted      = data and data.accepted == true,
    })
    cb('ok')
end)

RegisterNUICallback('squadLeave', function(_, cb)
    QBCore.Functions.TriggerCallback('hk-hub:squad:leave', function(res) cb(res or { ok = false }) end)
end)

-- Multi-squad: list my squads, switch active, deactivate (temp-leave).
RegisterNUICallback('squadMyList', function(_, cb)
    QBCore.Functions.TriggerCallback('hk-hub:squad:myList', function(res) cb(res or { squads = {} }) end)
end)

RegisterNUICallback('squadSetActive', function(data, cb)
    QBCore.Functions.TriggerCallback('hk-hub:squad:setActive', function(res) cb(res or { ok = false }) end, data)
end)

RegisterNUICallback('squadDeactivate', function(_, cb)
    QBCore.Functions.TriggerCallback('hk-hub:squad:deactivate', function(res) cb(res or { ok = false }) end)
end)

RegisterNUICallback('squadKick', function(data, cb)
    QBCore.Functions.TriggerCallback('hk-hub:squad:kick', function(res) cb(res or { ok = false }) end, data)
end)

RegisterNUICallback('squadPromote', function(data, cb)
    QBCore.Functions.TriggerCallback('hk-hub:squad:promote', function(res) cb(res or { ok = false }) end, data)
end)

RegisterNUICallback('squadPromoteOfficer', function(data, cb)
    QBCore.Functions.TriggerCallback('hk-hub:squad:promoteOfficer', function(res) cb(res or { ok = false }) end, data)
end)

RegisterNUICallback('squadDemote', function(data, cb)
    QBCore.Functions.TriggerCallback('hk-hub:squad:demote', function(res) cb(res or { ok = false }) end, data)
end)

RegisterNUICallback('squadGetWaypoints', function(data, cb)
    QBCore.Functions.TriggerCallback('hk-hub:squad:getWaypoints', function(rows) cb(rows or {}) end,
        data and data.squadID)
end)

RegisterNUICallback('squadAddWaypoint', function(data, cb)
    QBCore.Functions.TriggerCallback('hk-hub:squad:addWaypoint', function(res) cb(res or { ok = false }) end, data)
end)

RegisterNUICallback('squadRemoveWaypoint', function(data, cb)
    QBCore.Functions.TriggerCallback('hk-hub:squad:removeWaypoint', function(res) cb(res or { ok = false }) end, data)
end)

RegisterNUICallback('squadClearWaypoints', function(data, cb)
    QBCore.Functions.TriggerCallback('hk-hub:squad:clearWaypoints', function(res) cb(res or { ok = false }) end,
        data and data.squadID)
end)

-- Radio on/off toggle from the panel (lets an on-duty cop switch job↔squad radio).
RegisterNUICallback('squadRadio', function(data, cb)
    if data and data.on == true then joinRadio() else leaveRadio() end
    cb({ radioOn = State.radioOn })
end)

-- Player picks their own minimap blip / tag colour.
RegisterNUICallback('squadSetBlipColor', function(data, cb)
    QBCore.Functions.TriggerCallback('hk-hub:squad:setBlipColor', function(res)
        cb(res or { ok = false })
    end, { color = data and data.color })
end)

-- Player sets/clears their team-only nickname.
RegisterNUICallback('squadSetNickname', function(data, cb)
    QBCore.Functions.TriggerCallback('hk-hub:squad:setNickname', function(res)
        cb(res or { ok = false })
    end, { nickname = data and data.nickname })
end)

-- Leader renames the squad.
RegisterNUICallback('squadRename', function(data, cb)
    QBCore.Functions.TriggerCallback('hk-hub:squad:rename', function(res)
        cb(res or { ok = false })
    end, { name = data and data.name })
end)

-- Edit an existing waypoint's label/colour.
RegisterNUICallback('squadEditWaypoint', function(data, cb)
    QBCore.Functions.TriggerCallback('hk-hub:squad:editWaypoint', function(res)
        cb(res or { ok = false })
    end, data)
end)

-- Cycle a waypoint's minimap-blip mode: 0 hidden → 1 shown → 2 flashing → 0.
-- SHARED status: round-trips to the server, which persists it and re-pushes to
-- the whole squad (so everyone's minimap updates — a quick team "ping here").
RegisterNUICallback('squadCycleWaypointBlip', function(data, cb)
    local wpId = tostring(data and data.waypointId or '')
    if wpId == '' or State.squadID == 0 then cb({ ok = false }) return end
    -- Cache coords/colour from the panel payload up front (covers points added
    -- this session before any server round-trip refreshed the cache).
    if data.wx ~= nil and data.wy ~= nil then
        wpCache[wpId] = { x = data.wx, y = data.wy, z = data.wz or 0.0, color = data.color, name = data.name }
    end
    local nextMode = ((wpModes[wpId] or 0) + 1) % 3
    -- If we have no world coords we can't place a blip — skip the "shown" states.
    if not (wpCache[wpId] and wpCache[wpId].x) then nextMode = 0 end
    -- Advance our OWN state optimistically + apply the blip now, so repeat presses
    -- cycle correctly even before the server broadcast round-trips back to us
    -- (the broadcast still reconciles everyone, incl. us, right after). Without
    -- this, wpModes stayed stale between presses → "stuck on show, press once".
    wpModes[wpId] = nextMode
    applyWpBlip(wpId)
    QBCore.Functions.TriggerCallback('hk-hub:squad:setWaypointBlipMode', function(res)
        -- The server broadcast (waypointsUpdated → fetchAndSyncWpBlips) applies the
        -- blip for everyone incl. us; report the resolved mode (fall back to our
        -- optimistic nextMode if the server didn't echo one).
        if res and res.ok and res.mode == nil then res.mode = nextMode end
        cb(res or { ok = true, mode = nextMode })
    end, { squadID = State.squadID, waypointId = tonumber(wpId), mode = nextMode })
end)

-- Report current blip modes so the panel can render the right icon per row.
RegisterNUICallback('squadGetWaypointBlipModes', function(_, cb)
    cb(wpModes)
end)

-- Squad chat: fetch full backlog for the panel.
RegisterNUICallback('squadGetMessages', function(_, cb)
    QBCore.Functions.TriggerCallback('hk-hub:squad:getMessages', function(res)
        cb(res or { ok = false, messages = {} })
    end)
end)

-- Squad chat: send a message.
RegisterNUICallback('squadSendMessage', function(data, cb)
    QBCore.Functions.TriggerCallback('hk-hub:squad:sendMessage', function(res)
        cb(res or { ok = false })
    end, { body = data and data.body })
end)

-- Squad chat: fetch the player's phone gallery (for the image picker).
RegisterNUICallback('squadGetGallery', function(_, cb)
    QBCore.Functions.TriggerCallback('hk-hub:squad:getGallery', function(res)
        cb(res or { ok = false, images = {} })
    end)
end)

-- Squad chat: send a chosen gallery image into the room.
RegisterNUICallback('squadSendImage', function(data, cb)
    QBCore.Functions.TriggerCallback('hk-hub:squad:sendImage', function(res)
        cb(res or { ok = false })
    end, { url = data and data.url })
end)

-- Set the player's GTA map waypoint to a member's last known / live location.
-- Fast-travel a GTA route waypoint to a saved squad waypoint's world coords.
RegisterNUICallback('squadWaypointGoto', function(data, cb)
    local wx = tonumber(data and data.wx)
    local wy = tonumber(data and data.wy)
    if not wx or not wy then cb({ ok = false }) return end
    SetNewWaypoint(wx, wy)
    cb({ ok = true })
end)

RegisterNUICallback('squadWaypointToMember', function(data, cb)
    local memberId = tonumber(data and data.memberId)
    if not memberId or memberId <= 0 then cb({ ok = false }) return end
    local myServerId = GetPlayerServerId(PlayerId())
    if memberId == myServerId then
        local c = GetEntityCoords(PlayerPedId())
        SetNewWaypoint(c.x, c.y)
        cb({ ok = true })
        return
    end
    local pos = lastPositions[memberId]
    if not pos then cb({ ok = false }) return end
    SetNewWaypoint(pos.x, pos.y)
    cb({ ok = true })
end)

-- Set a shared waypoint to a member's location on the atlas (world coords).
RegisterNUICallback('squadGetAtlasCfg', function(_, cb)
    cb(CFG.atlas or {})
end)

-- My current world position (for "focus / add my location" on the atlas map).
RegisterNUICallback('squadMyPos', function(_, cb)
    local c = GetEntityCoords(PlayerPedId())
    cb({ x = c.x, y = c.y, z = c.z })
end)

-- ---- Cleanup ---------------------------------------------------------------

AddEventHandler('onResourceStop', function(res)
    if res ~= RESOURCE then return end
    removeAllBlips()
    removeAllWpBlips()
    if State.radioOn then leaveRadio() end
end)

-- Cold-start: ask the server whether we're already in a persisted squad.
CreateThread(function()
    while not NetworkIsSessionStarted() do Wait(500) end
    Wait(2000)
    QBCore.Functions.TriggerCallback('hk-hub:squad:getState', function(state)
        if state and (tonumber(state.squadID) or 0) > 0 then
            applyState(state)
        end
    end)
end)
