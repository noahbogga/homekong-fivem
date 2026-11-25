-- hk-hub — squad (server)
-- Ported from af-squad, rebuilt on QBCore callbacks (no ox_lib) + oxmysql.
-- Owns squad state: create / invite / accept / leave / kick / promote / demote,
-- shared waypoints, live member positions, and per-squad pma-voice radio channel.
-- Squads persist in hk_squad_* tables and are cached in memory for fast reads.

if not (HubConfig.Squad and HubConfig.Squad.enabled) then return end

local QBCore = exports['qb-core']:GetCoreObject()
local CFG    = HubConfig.Squad
local LIMIT  = tonumber(CFG.limit) or 4

-- Allowed player blip-colour choices (GTA SetBlipColour indices). The NUI picker
-- offers the matching swatches; we validate any incoming choice against this set.
-- IMPORTANT: only "safe" blip colour IDs — never any ID that has an (enemy) or
-- (friendly) variant in the FiveM blip table (2,3,4,5,49,66,67,68,69). Those get
-- recoloured red/blue by SET_BLIP_AS_FRIENDLY relationship flags and can flip
-- unexpectedly. See docs.fivem.net/docs/game-references/blips.
-- Safe blip IDs (no enemy/friendly flag variant). Includes the current picker set
-- (0,1,8,11,17,26,27,38,46) plus legacy IDs kept so pre-existing DB rows validate.
local ALLOWED_BLIP_COLORS = { [0]=true, [1]=true, [8]=true, [11]=true, [17]=true,
    [25]=true, [26]=true, [27]=true, [38]=true, [40]=true, [46]=true, [47]=true,
    [48]=true, [50]=true }

-- ---- In-memory cache (mirrors the DB; DB is source of truth on write) ------
local Cache = {
    squads       = {},   -- [squadID] = { id, name, radio, code, members={[cid]=m}, waypoints={[id]=w} }
    -- A player may belong to up to 3 squads but only ONE is "active" at a time.
    -- activeSquad = the squad they're currently in (blips/positions/radio/roster-
    -- online all key off THIS). memberSquads = every squad they hold a row in.
    activeSquad  = {},   -- [citizenid] = squadID   (their one active squad; nil = none active)
    memberSquads = {},   -- [citizenid] = { [squadID] = true, ... }  (all memberships, ≤3)
}
local MAX_SQUADS = 3
local PendingInvites = {}   -- [targetSrc] = { squadID, inviterSource }

-- ---- Bridge helpers (QBCore) ----------------------------------------------

local function getIdentifier(src)
    local p = QBCore.Functions.GetPlayer(src)
    return p and p.PlayerData.citizenid or nil
end

local function getCharName(src)
    local p = QBCore.Functions.GetPlayer(src)
    if not p then return 'Unknown' end
    local c = p.PlayerData.charinfo
    if c and c.firstname and c.lastname then
        return c.firstname .. ' ' .. c.lastname
    end
    return 'Unknown'
end

local function notify(src, msg, kind)
    TriggerClientEvent('QBCore:Notify', src, msg, kind or 'primary')
end

-- Display name shown to teammates: the team-only nickname if set, else the
-- registered character firstname + lastname.
local function displayName(m, src)
    if m and m.nickname and m.nickname ~= '' then return m.nickname end
    if src then return getCharName(src) end
    return (m and m.player_name) or 'Unknown'
end

local function isOwnerFlag(v)
    return v == true or tonumber(v) == 1
end

-- Map of citizenid → online server id (rebuilt on demand; player counts are small).
local function onlineIndex()
    local index = {}
    for _, src in ipairs(QBCore.Functions.GetPlayers()) do
        local id = getIdentifier(src)
        if id then index[tostring(id)] = src end
    end
    return index
end

-- Squad radio channel: high band so it never collides with job radios.
local function radioChannelFor(squadID)
    local r = CFG.radio or {}
    return (tonumber(r.baseChannel) or 900000) + (tonumber(squadID) or 0)
end

-- Forward decls (defined after the cache helpers) used by the radio gate.
local isMemberOf
local isActiveIn  -- active-squad test (radio + visibility)
local logSystem   -- activity-log writer (defined in the chat section, used above)

-- PRIVACY: gate each squad radio channel through pma-voice so only actual squad
-- members can tune in. Without this, anyone could `/radio 900001` and listen in.
-- pma-voice calls the check with the joining player's source; return false to
-- bounce them straight back off the channel.
local armedChannels = {}
local function armRadioCheck(squadID)
    if GetResourceState('pma-voice') ~= 'started' then return end
    local ch = radioChannelFor(squadID)
    if armedChannels[ch] then return end
    local ok = pcall(function()
        exports['pma-voice']:addChannelCheck(ch, function(src)
            local cid = getIdentifier(src)
            -- Only your ACTIVE squad's radio is joinable — deactivated members are
            -- bounced (they've temporarily left this squad for another).
            return cid ~= nil and isActiveIn and isActiveIn(squadID, cid) == true
        end)
    end)
    if ok then armedChannels[ch] = true end
end

-- Force a player OFF the squad radio, server-side. The channel join-check already
-- blocks non-members from tuning in, but that check only runs at join time — a
-- member who is already listening and then gets kicked/leaves/disbanded would
-- keep hearing traffic until they re-tune. We don't trust the client to drop the
-- channel, so we clear it authoritatively via pma-voice. No-op if pma-voice is
-- down or the player is offline.
local function forceRadioOff(src)
    if not src then return end
    if GetResourceState('pma-voice') ~= 'started' then return end
    pcall(function() exports['pma-voice']:setPlayerRadio(src, 0) end)
end

local function memberCount(squad)
    local n = 0
    if squad then for _ in pairs(squad.members) do n = n + 1 end end
    return n
end

-- ---- Cache mutation --------------------------------------------------------

local function ensureSquad(squadID, name, radio, code)
    local id = tonumber(squadID) or 0
    if id <= 0 then return nil end
    if not Cache.squads[id] then
        Cache.squads[id] = {
            id = id, name = tostring(name or ('Squad ' .. id)),
            radio = radio, code = code, members = {}, waypoints = {},
        }
    else
        if name and name ~= '' then Cache.squads[id].name = tostring(name) end
        if radio then Cache.squads[id].radio = radio end
        if code then Cache.squads[id].code = code end
    end
    return Cache.squads[id]
end

local function putMember(squadID, m)
    local squad = ensureSquad(squadID)
    if not squad or not m or not m.citizenid then return end
    local cid = tostring(m.citizenid)
    squad.members[cid] = {
        citizenid   = cid,
        player_name = m.player_name or 'Unknown',
        role        = m.role or 'member',
        is_owner    = isOwnerFlag(m.is_owner),
        blip_color  = tonumber(m.blip_color),
        nickname    = (m.nickname ~= nil and m.nickname ~= '') and tostring(m.nickname) or nil,
    }
    -- Track the membership. Does NOT change which squad is active — that's set
    -- explicitly (create/join auto-activate; switching is a separate action).
    Cache.memberSquads[cid] = Cache.memberSquads[cid] or {}
    Cache.memberSquads[cid][squad.id] = true
end

local function dropMember(squadID, cid)
    local squad = Cache.squads[tonumber(squadID) or 0]
    if not squad or not cid then return end
    cid = tostring(cid)
    squad.members[cid] = nil
    if Cache.memberSquads[cid] then
        Cache.memberSquads[cid][squad.id] = nil
        if next(Cache.memberSquads[cid]) == nil then Cache.memberSquads[cid] = nil end
    end
    -- If this was their active squad, they're no longer active anywhere.
    if Cache.activeSquad[cid] == squad.id then Cache.activeSquad[cid] = nil end
end

-- How many squads a player currently belongs to (for the 3-squad cap).
local function memberSquadCount(cid)
    local t = Cache.memberSquads[tostring(cid or '')]
    if not t then return 0 end
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

local function deleteSquad(squadID)
    local id = tonumber(squadID) or 0
    local squad = Cache.squads[id]
    if not squad then return end
    for cid in pairs(squad.members) do
        if Cache.memberSquads[cid] then
            Cache.memberSquads[cid][id] = nil
            if next(Cache.memberSquads[cid]) == nil then Cache.memberSquads[cid] = nil end
        end
        if Cache.activeSquad[cid] == id then Cache.activeSquad[cid] = nil end
    end
    Cache.squads[id] = nil
end

local function putWaypoint(squadID, w)
    local squad = ensureSquad(squadID)
    if not squad or not w or not w.id then return end
    squad.waypoints[tonumber(w.id)] = w
end

-- The player's ACTIVE squad (the one they're currently in). Most call sites that
-- ask "what squad is this player in" mean the active one.
local function squadOf(cid)
    if not cid then return nil end
    local id = Cache.activeSquad[tostring(cid)]
    if not id then return nil end
    return Cache.squads[id]
end

local function findSquadIdByMember(src)
    local squad = squadOf(getIdentifier(src))
    return squad and squad.id or 0
end

-- Persist a player's active squad (nil squadID = no active squad).
local function persistActive(cid, squadID)
    cid = tostring(cid or '')
    if cid == '' then return end
    if squadID then
        MySQL.insert.await(
            'INSERT INTO hk_squad_active (citizenid, squad_id) VALUES (?, ?) ON DUPLICATE KEY UPDATE squad_id = VALUES(squad_id)',
            { cid, tonumber(squadID) })
    else
        MySQL.update.await('UPDATE hk_squad_active SET squad_id = NULL WHERE citizenid = ?', { cid })
    end
end

-- assigns to the forward-declared upvalue (see radio gate above)
-- MEMBERSHIP test: does this player hold a row in the squad? (Used to gate
-- add/edit/ping — actions you can take on any squad you belong to.)
function isMemberOf(squadID, cid)
    local squad = Cache.squads[tonumber(squadID) or 0]
    return squad ~= nil and cid ~= nil and squad.members[tostring(cid)] ~= nil
end

-- ACTIVE test: is this squad the player's currently-active one? Drives visibility
-- (blips, live positions, radio, roster-online). A member who's active elsewhere
-- is hidden/offline here. (Assigns the forward-declared upvalue used by the radio gate.)
function isActiveIn(squadID, cid)
    return cid ~= nil and Cache.activeSquad[tostring(cid)] == (tonumber(squadID) or 0)
end

-- Role rank for sorting/gating: leader (owner) = 0, vice = 1, member = 2.
local function roleRank(m)
    if not m then return 3 end
    if isOwnerFlag(m.is_owner) then return 0 end
    if m.role == 'vice' then return 1 end
    return 2
end

-- Shared-state gate: only the leader or a vice may manage waypoints/blips.
-- Members are view-only for the shared map now.
local function canEditWaypoints(squadID, cid)
    local squad = Cache.squads[tonumber(squadID) or 0]
    local m = squad and cid and squad.members[tostring(cid)]
    if not m then return false end
    return isOwnerFlag(m.is_owner) or m.role == 'vice'
end

local function generateCode()
    local chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'
    for _ = 1, 8 do
        local code = ''
        for _ = 1, 5 do
            local i = math.random(#chars)
            code = code .. chars:sub(i, i)
        end
        -- reject collisions with an in-memory squad
        local taken = false
        for _, s in pairs(Cache.squads) do
            if s.code == code then taken = true break end
        end
        if not taken then return code end
    end
    return nil
end

-- ---- DB load (persistence) -------------------------------------------------

local function loadFromDatabase()
    Cache.squads = {}
    Cache.activeSquad = {}
    Cache.memberSquads = {}

    local squads = MySQL.query.await('SELECT id, name, radio, join_code FROM hk_squads') or {}
    for _, row in ipairs(squads) do
        ensureSquad(tonumber(row.id) or 0, row.name, row.radio, row.join_code)
    end

    local members = MySQL.query.await(
        'SELECT squad_id, citizenid, player_name, role, is_owner, blip_color, nickname FROM hk_squad_members') or {}
    for _, row in ipairs(members) do
        putMember(tonumber(row.squad_id) or 0, {
            citizenid = row.citizenid, player_name = row.player_name,
            role = row.role, is_owner = row.is_owner, blip_color = row.blip_color,
            nickname = row.nickname,
        })
    end

    local wps = MySQL.query.await(
        'SELECT id, squad_id, label, icon_key, color, map_mode, nx, ny, wx, wy FROM hk_squad_waypoints') or {}
    for _, row in ipairs(wps) do
        putWaypoint(tonumber(row.squad_id) or 0, {
            id = tonumber(row.id), label = row.label,
            icon_key = row.icon_key or 'danger', color = row.color or '#00c8ff',
            map_mode = tonumber(row.map_mode) or 0,
            nx = tonumber(row.nx) or 0, ny = tonumber(row.ny) or 0,
            wx = tonumber(row.wx), wy = tonumber(row.wy),
        })
    end

    -- Active-squad pointer per player (which of their memberships is live). Only
    -- honour it if they still hold a row in that squad; else leave them inactive.
    local actives = MySQL.query.await('SELECT citizenid, squad_id FROM hk_squad_active') or {}
    for _, row in ipairs(actives) do
        local cid = tostring(row.citizenid)
        local sid = tonumber(row.squad_id)
        if sid and Cache.memberSquads[cid] and Cache.memberSquads[cid][sid] then
            Cache.activeSquad[cid] = sid
        end
    end
end

CreateThread(function()
    -- oxmysql is a hard dep; give it a beat then hydrate the cache.
    Wait(500)
    loadFromDatabase()
    -- pma-voice may start after us; wait until it's up, then gate every channel.
    while GetResourceState('pma-voice') ~= 'started' do Wait(1000) end
    for id in pairs(Cache.squads) do armRadioCheck(id) end
end)

-- ---- Online-members + roster payload --------------------------------------

-- Members who are online AND currently ACTIVE in this squad. This is the choke
-- point for every squad broadcast (state sync, waypoint pushes, live positions,
-- chat, radio arming), so a member who's active in a DIFFERENT squad is simply
-- absent here → no blips/positions/radio and shows offline. That's how
-- "deactivated = hidden/offline to this squad" is enforced in one place.
local function onlineMembers(squadID)
    local out = {}
    local id = tonumber(squadID) or 0
    local squad = Cache.squads[id]
    if not squad then return out end
    local idx = onlineIndex()
    for cid in pairs(squad.members) do
        local src = idx[tostring(cid)]
        if src and Cache.activeSquad[tostring(cid)] == id then out[#out + 1] = src end
    end
    return out
end

-- Roster the NUI renders (sorted owner-first). Includes online flag + server id.
local function rosterFor(squadID, viewerSrc)
    local squad = Cache.squads[tonumber(squadID) or 0]
    if not squad then return {} end
    local viewerCid = viewerSrc and getIdentifier(viewerSrc) or nil
    local idx = onlineIndex()

    local sid = tonumber(squadID) or 0
    -- "online" in THIS squad = connected AND active here. A member connected but
    -- active in another squad is shown offline/away in this roster.
    local function activeOnline(cid)
        return idx[tostring(cid)] ~= nil and Cache.activeSquad[tostring(cid)] == sid
    end

    local rows = {}
    for _, m in pairs(squad.members) do rows[#rows + 1] = m end
    -- Sort: online first, then Leader > Vice > Member, then citizenid.
    table.sort(rows, function(a, b)
        local aOn = activeOnline(a.citizenid) and 1 or 0
        local bOn = activeOnline(b.citizenid) and 1 or 0
        if aOn ~= bOn then return aOn > bOn end
        local ar, br = roleRank(a), roleRank(b)
        if ar ~= br then return ar < br end
        return tostring(a.citizenid) < tostring(b.citizenid)
    end)

    local out = {}
    for _, m in ipairs(rows) do
        local src = idx[tostring(m.citizenid)]
        local realName = src and getCharName(src) or (m.player_name or 'Unknown')
        out[#out + 1] = {
            id        = src or 0,
            citizenid = m.citizenid,
            name      = displayName(m, src),      -- nickname if set, else char name
            realName  = realName,                 -- registered firstname + lastname
            nickname  = m.nickname,
            role      = m.role or 'member',
            isOwner   = isOwnerFlag(m.is_owner),
            online    = activeOnline(m.citizenid),
            isSelf    = viewerCid ~= nil and tostring(m.citizenid) == tostring(viewerCid),
            blipColor = tonumber(m.blip_color),
            avatar    = HKHubAvatarUrl(m.citizenid),   -- portrait URL (may be nil)
        }
    end
    return out
end

-- Push fresh squad state to every online member (roster + current-squad flag).
local function syncSquad(squadID)
    for _, src in ipairs(onlineMembers(squadID)) do
        local isLeader = false
        local squad = Cache.squads[tonumber(squadID) or 0]
        local cid = getIdentifier(src)
        if squad and cid and squad.members[tostring(cid)] then
            isLeader = isOwnerFlag(squad.members[tostring(cid)].is_owner)
        end
        local squadObj = Cache.squads[tonumber(squadID) or 0]
        TriggerClientEvent('hk-hub:squad:setCurrent', src, {
            squadID  = squadID,
            isLeader = isLeader,
            name     = squadObj and squadObj.name or '',
            code     = squadObj and squadObj.code or nil,
            radio    = squadObj and squadObj.radio or nil,
        })
    end
end

-- Tell one client they have NO active squad (back to the hub). They may still be
-- a member of squads — this just clears the live/active one.
local function pushNoActive(src)
    TriggerClientEvent('hk-hub:squad:setCurrent', src, { squadID = 0, isLeader = false })
end

-- Set (or clear) a player's ACTIVE squad. Handles radio hand-off + re-syncing
-- both the old and new squad rosters so online/offline flips correctly, and
-- persists the choice. squadID = nil → deactivate (no active squad).
--   src      : player server id (may be offline → we still update cache + DB)
--   cid      : their citizenid
--   squadID  : squad to activate, or nil to deactivate
-- Returns true on success. Assumes membership already validated by the caller.
local function setActiveSquad(src, cid, squadID)
    cid = tostring(cid or '')
    if cid == '' then return false end
    local prev = Cache.activeSquad[cid]
    local nextId = squadID and tonumber(squadID) or nil
    if prev == nextId then return true end   -- no-op

    Cache.activeSquad[cid] = nextId
    persistActive(cid, nextId)

    if src then
        forceRadioOff(src)   -- always drop the old channel first
    end

    -- Refresh the squad they LEFT so its roster shows them offline now.
    if prev then syncSquad(prev) end

    if nextId then
        armRadioCheck(nextId)
        syncSquad(nextId)    -- new squad gets fresh state (incl. this player online)
        -- syncSquad only reaches ACTIVE members; this player just became active so
        -- it covers them — but push explicitly in case they aren't online-indexed yet.
    elseif src then
        pushNoActive(src)
    end
    return true
end

-- ---- Exports (for other resources / future qb-phone walkie plugin) --------

exports('SquadFindByMember', findSquadIdByMember)
exports('SquadMembers', function(squadID) return onlineMembers(squadID) end)
exports('SquadName', function(squadID)
    local s = Cache.squads[tonumber(squadID) or 0]; return s and s.name or nil
end)
exports('SquadIsLeader', function(src, squadID)
    local squad = Cache.squads[tonumber(squadID) or 0]
    local cid = getIdentifier(src)
    local m = squad and cid and squad.members[tostring(cid)]
    return m ~= nil and isOwnerFlag(m.is_owner)
end)
exports('SquadRadioChannel', function(squadID)
    local s = Cache.squads[tonumber(squadID) or 0]
    return s and s.radio or radioChannelFor(squadID)
end)

-- Fire an event to all online squad members (like af-squad's SquadEvent).
exports('SquadEvent', function(squadID, event, args)
    if not squadID or not event then return end
    for _, src in ipairs(onlineMembers(squadID)) do
        if args ~= nil then
            TriggerClientEvent(event, src, table.unpack(args))
        else
            TriggerClientEvent(event, src)
        end
    end
end)

-- ---- Callbacks: read ------------------------------------------------------

-- Everything the panel needs in one round-trip: your squad id/role, the roster,
-- the radio channel, and the limit.
QBCore.Functions.CreateCallback('hk-hub:squad:getState', function(source, cb)
    local cid = getIdentifier(source)
    local squad = squadOf(cid)
    -- How many squads they belong to (drives the switcher affordance + cap hints).
    local squadCount = memberSquadCount(cid)
    if not squad then
        cb({ squadID = 0, isLeader = false, limit = LIMIT, squadCount = squadCount, maxSquads = MAX_SQUADS })
        return
    end
    local m = squad.members[tostring(cid)]
    cb({
        squadID   = squad.id,
        name      = squad.name,
        code      = squad.code,
        isLeader  = m ~= nil and isOwnerFlag(m.is_owner),
        myRole    = m and (isOwnerFlag(m.is_owner) and 'owner' or (m.role or 'member')) or 'member',
        radio     = squad.radio,
        limit     = LIMIT,
        squadCount = squadCount,
        maxSquads = MAX_SQUADS,
        members   = rosterFor(squad.id, source),
    })
end)

-- Live world positions of the OTHER online members (for atlas dots + real
-- coord-blip fallback). Only returned to actual squad members.
QBCore.Functions.CreateCallback('hk-hub:squad:getPositions', function(source, cb)
    local cid = getIdentifier(source)
    local squad = squadOf(cid)
    if not squad then cb({}) return end

    local idx = onlineIndex()
    local out = {}
    for mcid, m in pairs(squad.members) do
        local src = idx[tostring(mcid)]
        -- Only members whose ACTIVE squad is THIS one broadcast their position.
        -- A member who swapped/exited stays in the DB roster but must go dark here
        -- (no blip / 3D tag / atlas dot / overlay card) — same gate as onlineMembers.
        if src and src ~= source and Cache.activeSquad[tostring(mcid)] == squad.id then
            local ped = GetPlayerPed(src)
            if ped and ped ~= 0 then
                local c = GetEntityCoords(ped)
                out[#out + 1] = {
                    id   = src,
                    name = displayName(m, src),
                    x    = c.x, y = c.y, z = c.z,
                    role = m.role or 'member',
                    owner = isOwnerFlag(m.is_owner),
                    blipColor = tonumber(m.blip_color),
                    avatar = HKHubAvatarUrl(m.citizenid),   -- portrait URL (may be nil)
                }
            end
        end
    end
    cb(out)
end)

QBCore.Functions.CreateCallback('hk-hub:squad:getWaypoints', function(source, cb, squadID)
    local cid = getIdentifier(source)
    if not isMemberOf(squadID, cid) then cb({}) return end
    local squad = Cache.squads[tonumber(squadID) or 0]
    if not squad then cb({}) return end
    local out = {}
    for _, w in pairs(squad.waypoints) do
        out[#out + 1] = {
            id = tostring(w.id), name = w.label,
            iconKey = w.icon_key or 'danger', color = w.color or '#00c8ff',
            mapMode = tonumber(w.map_mode) or 0,
            nx = tonumber(w.nx) or 0, ny = tonumber(w.ny) or 0,
            wx = w.wx, wy = w.wy,
        }
    end
    table.sort(out, function(a, b) return tonumber(a.id) < tonumber(b.id) end)
    cb(out)
end)

-- ---- Callbacks: create / join --------------------------------------------

QBCore.Functions.CreateCallback('hk-hub:squad:create', function(source, cb, name)
    local cid = getIdentifier(source)
    if not cid then cb({ ok = false, err = 'no_char' }) return end
    -- Cap: a player may belong to at most MAX_SQUADS squads.
    if memberSquadCount(cid) >= MAX_SQUADS then cb({ ok = false, err = 'max_squads' }) return end

    name = tostring(name or ''):gsub('^%s+', ''):gsub('%s+$', '')
    if name == '' then name = getCharName(source) .. "'s Squad" end
    name = name:sub(1, 64)

    local code  = generateCode()
    local squadID = MySQL.insert.await(
        'INSERT INTO hk_squads (name, join_code) VALUES (?, ?)', { name, code })
    if not squadID then cb({ ok = false, err = 'db' }) return end

    local radio = radioChannelFor(squadID)
    MySQL.update.await('UPDATE hk_squads SET radio = ? WHERE id = ?', { radio, squadID })
    MySQL.insert.await([[
        INSERT INTO hk_squad_members (squad_id, citizenid, player_name, is_owner, role)
        VALUES (?, ?, ?, 1, 'owner')
    ]], { squadID, cid, getCharName(source) })

    ensureSquad(squadID, name, radio, code)
    putMember(squadID, { citizenid = cid, player_name = getCharName(source), is_owner = true, role = 'owner' })

    armRadioCheck(squadID)
    -- Creating a squad makes it your active one (deactivating any prior active).
    setActiveSquad(source, cid, squadID)
    logSystem(squadID, { verb = 'create', actor = getCharName(source), name = name })
    cb({ ok = true, squadID = squadID, name = name, code = code, radio = radio })
end)

QBCore.Functions.CreateCallback('hk-hub:squad:joinByCode', function(source, cb, code)
    local cid = getIdentifier(source)
    if not cid then cb({ ok = false, err = 'no_char' }) return end

    code = tostring(code or ''):gsub('%s+', ''):upper()
    if code == '' then cb({ ok = false, err = 'bad_code' }) return end

    local squad
    for _, s in pairs(Cache.squads) do if s.code == code then squad = s break end end
    if not squad then cb({ ok = false, err = 'not_found' }) return end
    -- Already a member of THIS squad? Just make it active instead of erroring.
    if isMemberOf(squad.id, cid) then
        setActiveSquad(source, cid, squad.id)
        cb({ ok = true, squadID = squad.id, name = squad.name, radio = squad.radio })
        return
    end
    if memberSquadCount(cid) >= MAX_SQUADS then cb({ ok = false, err = 'max_squads' }) return end
    if memberCount(squad) >= LIMIT then cb({ ok = false, err = 'full' }) return end

    MySQL.insert.await([[
        INSERT INTO hk_squad_members (squad_id, citizenid, player_name, is_owner, role)
        VALUES (?, ?, ?, 0, 'member')
    ]], { squad.id, cid, getCharName(source) })
    putMember(squad.id, { citizenid = cid, player_name = getCharName(source), is_owner = false, role = 'member' })

    -- Joining a new squad makes it your active one.
    setActiveSquad(source, cid, squad.id)
    logSystem(squad.id, { verb = 'join', actor = getCharName(source), via = 'code' })
    cb({ ok = true, squadID = squad.id, name = squad.name, radio = squad.radio })
end)

-- Invite by server ID (leader only). Target gets a client prompt.
QBCore.Functions.CreateCallback('hk-hub:squad:invite', function(source, cb, targetId)
    targetId = tonumber(targetId)
    if not targetId or targetId <= 0 then cb({ ok = false, err = 'bad_id' }) return end
    if targetId == source then cb({ ok = false, err = 'self' }) return end

    local squadID = findSquadIdByMember(source)
    if squadID <= 0 then cb({ ok = false, err = 'no_squad' }) return end

    local squad = Cache.squads[squadID]
    local srcCid = getIdentifier(source)
    local me = squad and srcCid and squad.members[tostring(srcCid)]
    if not me or not isOwnerFlag(me.is_owner) then cb({ ok = false, err = 'not_leader' }) return end

    local targetCid = getIdentifier(targetId)
    if not targetCid then cb({ ok = false, err = 'offline' }) return end
    -- A player can belong to multiple squads now, so only block if they're already
    -- in THIS squad or already at their squad cap.
    if isMemberOf(squadID, targetCid) then cb({ ok = false, err = 'target_in_squad' }) return end
    if memberSquadCount(targetCid) >= MAX_SQUADS then cb({ ok = false, err = 'target_max_squads' }) return end
    if memberCount(squad) >= LIMIT then cb({ ok = false, err = 'full' }) return end

    PendingInvites[targetId] = { squadID = squadID, inviterSource = source }
    TriggerClientEvent('hk-hub:squad:invited', targetId, {
        squadID     = squadID,
        inviterSource = source,
        inviterName = getCharName(source),
        squadName   = squad.name,
    })
    cb({ ok = true })
end)

RegisterNetEvent('hk-hub:squad:respondInvite', function(data)
    local src = source
    local invite = PendingInvites[src]
    if not invite or not data then return end
    if invite.squadID ~= tonumber(data.squadID) or invite.inviterSource ~= tonumber(data.inviterSource) then return end
    PendingInvites[src] = nil

    if not data.accepted then
        notify(invite.inviterSource, getCharName(src) .. ' declined your squad invite.', 'error')
        return
    end

    local cid = getIdentifier(src)
    if not cid then return end

    local squad = Cache.squads[tonumber(invite.squadID) or 0]
    if not squad then notify(src, 'That squad no longer exists.', 'error') return end
    if isMemberOf(invite.squadID, cid) then notify(src, 'You are already in that squad.', 'error') return end
    if memberSquadCount(cid) >= MAX_SQUADS then notify(src, ('You can only be in %d squads.'):format(MAX_SQUADS), 'error') return end
    if memberCount(squad) >= LIMIT then notify(src, 'Squad is full.', 'error') return end

    MySQL.insert.await([[
        INSERT INTO hk_squad_members (squad_id, citizenid, player_name, is_owner, role)
        VALUES (?, ?, ?, 0, 'member')
    ]], { invite.squadID, cid, getCharName(src) })
    putMember(invite.squadID, { citizenid = cid, player_name = getCharName(src), is_owner = false, role = 'member' })

    -- Accepting an invite makes that squad your active one.
    setActiveSquad(src, cid, invite.squadID)
    logSystem(invite.squadID, {
        verb = 'join', actor = getCharName(src), via = 'invite',
        by = getCharName(invite.inviterSource),
    })
    notify(src, ('You joined %s.'):format(squad.name), 'success')
    notify(invite.inviterSource, ('%s accepted your squad invite.'):format(getCharName(src)), 'success')
end)

-- ---- Callbacks: manage ----------------------------------------------------

-- All squads this player belongs to (up to MAX_SQUADS), for the hub/switcher page.
-- Marks which is currently active. Includes offline players (cache-driven).
QBCore.Functions.CreateCallback('hk-hub:squad:myList', function(source, cb)
    local cid = getIdentifier(source)
    if not cid then cb({ squads = {}, max = MAX_SQUADS }) return end
    local active = Cache.activeSquad[tostring(cid)]
    local out = {}
    local mine = Cache.memberSquads[tostring(cid)] or {}
    for sid in pairs(mine) do
        local squad = Cache.squads[sid]
        if squad then
            local m = squad.members[tostring(cid)]
            out[#out + 1] = {
                squadID = sid,
                name    = squad.name,
                code    = squad.code,
                members = memberCount(squad),
                limit   = LIMIT,
                role    = m and (isOwnerFlag(m.is_owner) and 'owner' or (m.role or 'member')) or 'member',
                isActive = (active == sid),
            }
        end
    end
    table.sort(out, function(a, b) return a.squadID < b.squadID end)
    cb({ squads = out, max = MAX_SQUADS, active = active or 0 })
end)

-- Switch the ACTIVE squad to another one the player already belongs to.
QBCore.Functions.CreateCallback('hk-hub:squad:setActive', function(source, cb, data)
    local cid = getIdentifier(source)
    local squadID = tonumber(data and data.squadID)
    if not cid or not squadID then cb({ ok = false }) return end
    if not isMemberOf(squadID, cid) then cb({ ok = false, err = 'not_member' }) return end
    setActiveSquad(source, cid, squadID)
    local squad = Cache.squads[squadID]
    cb({ ok = true, squadID = squadID, name = squad and squad.name or '', radio = squad and squad.radio or nil })
end)

-- Deactivate: temporarily leave the active squad WITHOUT giving up membership.
-- You become hidden/offline to that squad (no blip/position/radio) until you
-- re-activate it. Membership row is untouched.
QBCore.Functions.CreateCallback('hk-hub:squad:deactivate', function(source, cb)
    local cid = getIdentifier(source)
    if not cid then cb({ ok = false }) return end
    setActiveSquad(source, cid, nil)
    cb({ ok = true })
end)

-- Leave. If the owner leaves, ownership passes to a vice (else oldest member);
-- if they were the last member, the squad is deleted.
QBCore.Functions.CreateCallback('hk-hub:squad:leave', function(source, cb)
    local cid = getIdentifier(source)
    -- Operates on the ACTIVE squad. (From the hub you activate a squad to enter
    -- it, then leave/disband from inside.)
    local squad = squadOf(cid)
    if not squad then cb({ ok = false, err = 'no_squad' }) return end
    local me = squad.members[tostring(cid)]
    if not me then cb({ ok = false, err = 'no_squad' }) return end
    local squadID = squad.id
    local leaverName = displayName(me, source)

    if isOwnerFlag(me.is_owner) then
        -- Pick a successor: prefer a vice, otherwise the lowest citizenid.
        local successor = nil
        for mcid, mrow in pairs(squad.members) do
            if mcid ~= tostring(cid) then
                if not successor then
                    successor = mcid
                elseif mrow.role == 'vice' and squad.members[successor].role ~= 'vice' then
                    successor = mcid
                elseif mrow.role == squad.members[successor].role and mcid < successor then
                    successor = mcid
                end
            end
        end

        if successor then
            MySQL.update.await('DELETE FROM hk_squad_members WHERE squad_id = ? AND citizenid = ?', { squadID, cid })
            MySQL.update.await(
                "UPDATE hk_squad_members SET is_owner = 1, role = 'owner' WHERE squad_id = ? AND citizenid = ?",
                { squadID, successor })
            dropMember(squadID, cid)
            local succRow = squad.members[successor]
            putMember(squadID, {
                citizenid = successor, player_name = succRow.player_name,
                is_owner = true, role = 'owner',
            })
            syncSquad(squadID)
            logSystem(squadID, { verb = 'leave', actor = leaverName })
            logSystem(squadID, { verb = 'transfer', actor = leaverName, target = displayName(succRow, onlineIndex()[tostring(successor)]) })
        else
            local members = onlineMembers(squadID)
            MySQL.update.await('DELETE FROM hk_squads WHERE id = ?', { squadID })
            deleteSquad(squadID)
            for _, src in ipairs(members) do
                forceRadioOff(src)   -- channel is gone; drop everyone off it
                if src ~= source then TriggerClientEvent('hk-hub:squad:destroyed', src) end
            end
        end
    else
        MySQL.update.await('DELETE FROM hk_squad_members WHERE squad_id = ? AND citizenid = ?', { squadID, cid })
        dropMember(squadID, cid)
        syncSquad(squadID)
        logSystem(squadID, { verb = 'leave', actor = leaverName })
    end

    forceRadioOff(source)   -- the leaver drops the squad channel server-side
    TriggerClientEvent('hk-hub:squad:setCurrent', source, { squadID = 0, isLeader = false })
    cb({ ok = true })
end)

-- Resolve a management target from either a citizenid or a server id in payload.
local function targetCidFrom(data)
    if data and data.memberCitizenId and data.memberCitizenId ~= '' then
        return tostring(data.memberCitizenId)
    end
    local mid = tonumber(data and data.memberId)
    if not mid or mid <= 0 then return nil end
    return getIdentifier(mid)
end

QBCore.Functions.CreateCallback('hk-hub:squad:kick', function(source, cb, data)
    local squadID = tonumber(data and data.squadID)
    local srcCid  = getIdentifier(source)
    local tgtCid  = targetCidFrom(data)
    if not squadID or not srcCid or not tgtCid or srcCid == tgtCid then cb({ ok = false }) return end

    local squad = Cache.squads[squadID]
    local me    = squad and squad.members[tostring(srcCid)]
    local tgt   = squad and squad.members[tostring(tgtCid)]
    if not me or not tgt or not isOwnerFlag(me.is_owner) or isOwnerFlag(tgt.is_owner) then cb({ ok = false }) return end

    local tgtName = displayName(tgt, onlineIndex()[tostring(tgtCid)])
    local affected = MySQL.update.await(
        'DELETE FROM hk_squad_members WHERE squad_id = ? AND citizenid = ? AND is_owner = 0', { squadID, tgtCid })
    if not affected or affected < 1 then cb({ ok = false }) return end
    dropMember(squadID, tgtCid)

    local kickedSrc = onlineIndex()[tostring(tgtCid)]
    if kickedSrc then
        forceRadioOff(kickedSrc)   -- drop them off the channel server-side
        TriggerClientEvent('hk-hub:squad:kicked', kickedSrc)
    end
    syncSquad(squadID)
    logSystem(squadID, { verb = 'kick', actor = displayName(me, source), target = tgtName })
    cb({ ok = true })
end)

-- Manual promotion to VICE (leader only). Members do not become vice
-- automatically anywhere — this is the only path up. Target must be a plain
-- member of the squad (not the leader, not already a vice).
QBCore.Functions.CreateCallback('hk-hub:squad:promoteOfficer', function(source, cb, data)
    local squadID = tonumber(data and data.squadID)
    local srcCid  = getIdentifier(source)
    local tgtCid  = targetCidFrom(data)
    if not squadID or not srcCid or not tgtCid or srcCid == tgtCid then cb({ ok = false }) return end

    local squad = Cache.squads[squadID]
    local me    = squad and squad.members[tostring(srcCid)]
    local tgt   = squad and squad.members[tostring(tgtCid)]
    if not me or not tgt or not isOwnerFlag(me.is_owner) then cb({ ok = false }) return end
    if isOwnerFlag(tgt.is_owner) or tgt.role == 'vice' then cb({ ok = false }) return end

    local affected = MySQL.update.await(
        "UPDATE hk_squad_members SET role = 'vice' WHERE squad_id = ? AND citizenid = ? AND is_owner = 0", { squadID, tgtCid })
    if not affected or affected < 1 then cb({ ok = false }) return end
    putMember(squadID, { citizenid = tgtCid, player_name = tgt.player_name, is_owner = false, role = 'vice' })

    syncSquad(squadID)
    logSystem(squadID, {
        verb = 'promote_officer', actor = displayName(me, source),
        target = displayName(tgt, onlineIndex()[tostring(tgtCid)]),
    })
    cb({ ok = true })
end)

-- Transfer leadership (crown). The outgoing leader steps down to a plain MEMBER
-- (not auto-officer) — the new leader can re-promote them manually if desired.
QBCore.Functions.CreateCallback('hk-hub:squad:promote', function(source, cb, data)
    local squadID = tonumber(data and data.squadID)
    local srcCid  = getIdentifier(source)
    local tgtCid  = targetCidFrom(data)
    if not squadID or not srcCid or not tgtCid or srcCid == tgtCid then cb({ ok = false }) return end

    local squad = Cache.squads[squadID]
    local me    = squad and squad.members[tostring(srcCid)]
    local tgt   = squad and squad.members[tostring(tgtCid)]
    if not me or not tgt or not isOwnerFlag(me.is_owner) then cb({ ok = false }) return end

    -- Hand over ownership: current owner → member, target → owner.
    MySQL.update.await("UPDATE hk_squad_members SET is_owner = 0, role = 'member' WHERE squad_id = ? AND citizenid = ?", { squadID, srcCid })
    MySQL.update.await("UPDATE hk_squad_members SET is_owner = 1, role = 'owner' WHERE squad_id = ? AND citizenid = ?", { squadID, tgtCid })
    putMember(squadID, { citizenid = srcCid, player_name = me.player_name, is_owner = false, role = 'member' })
    putMember(squadID, { citizenid = tgtCid, player_name = tgt.player_name, is_owner = true, role = 'owner' })

    syncSquad(squadID)
    logSystem(squadID, {
        verb = 'transfer', actor = displayName(me, source),
        target = displayName(tgt, onlineIndex()[tostring(tgtCid)]),
    })
    cb({ ok = true })
end)

QBCore.Functions.CreateCallback('hk-hub:squad:demote', function(source, cb, data)
    local squadID = tonumber(data and data.squadID)
    local srcCid  = getIdentifier(source)
    local tgtCid  = targetCidFrom(data)
    if not squadID or not srcCid or not tgtCid then cb({ ok = false }) return end

    local squad = Cache.squads[squadID]
    local me    = squad and squad.members[tostring(srcCid)]
    local tgt   = squad and squad.members[tostring(tgtCid)]
    if not me or not tgt or not isOwnerFlag(me.is_owner) or isOwnerFlag(tgt.is_owner) then cb({ ok = false }) return end

    local affected = MySQL.update.await(
        "UPDATE hk_squad_members SET role = 'member' WHERE squad_id = ? AND citizenid = ? AND is_owner = 0", { squadID, tgtCid })
    if not affected or affected < 1 then cb({ ok = false }) return end
    putMember(squadID, { citizenid = tgtCid, player_name = tgt.player_name, is_owner = false, role = 'member' })

    syncSquad(squadID)
    logSystem(squadID, {
        verb = 'demote', actor = displayName(me, source),
        target = displayName(tgt, onlineIndex()[tostring(tgtCid)]),
    })
    cb({ ok = true })
end)

-- ---- Callbacks: waypoints -------------------------------------------------

local function pushWaypointsUpdated(squadID)
    for _, src in ipairs(onlineMembers(squadID)) do
        TriggerClientEvent('hk-hub:squad:waypointsUpdated', src, squadID)
    end
end

QBCore.Functions.CreateCallback('hk-hub:squad:addWaypoint', function(source, cb, data)
    local squadID = tonumber(data and data.squadID)
    local cid = getIdentifier(source)
    if not squadID or not isMemberOf(squadID, cid) then cb({ ok = false }) return end
    if not canEditWaypoints(squadID, cid) then cb({ ok = false, err = 'not_officer' }) return end

    local label = tostring((data and data.name) or ''):sub(1, 96)
    if label == '' then cb({ ok = false }) return end
    local iconKey = tostring((data and data.iconKey) or 'danger'):sub(1, 32)
    local color   = tostring((data and data.color) or '#00c8ff'):sub(1, 16)
    local nx = tonumber(data and data.nx)
    local ny = tonumber(data and data.ny)
    if not nx or not ny then cb({ ok = false }) return end
    nx = math.max(0.0, math.min(1.0, nx))
    ny = math.max(0.0, math.min(1.0, ny))
    local wx = tonumber(data and data.wx)
    local wy = tonumber(data and data.wy)

    local id = MySQL.insert.await([[
        INSERT INTO hk_squad_waypoints (squad_id, label, icon_key, color, nx, ny, wx, wy, created_by)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    ]], { squadID, label, iconKey, color, nx, ny, wx, wy, cid })
    if not id then cb({ ok = false }) return end
    putWaypoint(squadID, { id = id, label = label, icon_key = iconKey, color = color, nx = nx, ny = ny, wx = wx, wy = wy })

    pushWaypointsUpdated(squadID)
    local sq = Cache.squads[squadID]
    logSystem(squadID, {
        verb = 'wp_add', name = label, color = color,
        actor = displayName(sq and sq.members[tostring(cid)], source),
    })
    cb({ ok = true, id = id })
end)

QBCore.Functions.CreateCallback('hk-hub:squad:removeWaypoint', function(source, cb, data)
    local squadID = tonumber(data and data.squadID)
    local wpID    = tonumber(data and data.waypointId)
    local cid = getIdentifier(source)
    if not squadID or not wpID or not isMemberOf(squadID, cid) then cb({ ok = false }) return end
    if not canEditWaypoints(squadID, cid) then cb({ ok = false, err = 'not_officer' }) return end

    local squad = Cache.squads[squadID]
    local gone = squad and squad.waypoints and squad.waypoints[wpID]
    local goneLabel = gone and gone.label or nil
    local goneColor = gone and gone.color or nil

    local affected = MySQL.update.await('DELETE FROM hk_squad_waypoints WHERE id = ? AND squad_id = ?', { wpID, squadID })
    if not affected or affected < 1 then cb({ ok = false }) return end
    if squad then squad.waypoints[wpID] = nil end

    pushWaypointsUpdated(squadID)
    logSystem(squadID, {
        verb = 'wp_remove', name = goneLabel, color = goneColor,
        actor = displayName(squad and squad.members[tostring(cid)], source),
    })
    cb({ ok = true })
end)

-- Edit an existing waypoint's label and/or colour (any member). Coords are left
-- untouched — this is a rename/recolour, not a move.
QBCore.Functions.CreateCallback('hk-hub:squad:editWaypoint', function(source, cb, data)
    local squadID = tonumber(data and data.squadID)
    local wpID    = tonumber(data and data.waypointId)
    local cid = getIdentifier(source)
    if not squadID or not wpID or not isMemberOf(squadID, cid) then cb({ ok = false }) return end
    if not canEditWaypoints(squadID, cid) then cb({ ok = false, err = 'not_officer' }) return end

    local squad = Cache.squads[squadID]
    local wp = squad and squad.waypoints and squad.waypoints[wpID]
    if not wp then cb({ ok = false }) return end

    local oldLabel = wp.label
    local oldColor = wp.color
    local label = tostring((data and data.name) or ''):gsub('^%s+', ''):gsub('%s+$', ''):sub(1, 96)
    if label == '' then label = wp.label end
    local color = tostring((data and data.color) or wp.color or '#00c8ff'):sub(1, 16)

    MySQL.update.await('UPDATE hk_squad_waypoints SET label = ?, color = ? WHERE id = ? AND squad_id = ?',
        { label, color, wpID, squadID })
    wp.label = label
    wp.color = color

    pushWaypointsUpdated(squadID)
    local actorName = displayName(squad.members[tostring(cid)], source)
    if label ~= oldLabel then
        logSystem(squadID, { verb = 'wp_rename', actor = actorName, old = oldLabel, name = label, color = color })
    elseif color ~= oldColor then
        logSystem(squadID, { verb = 'wp_recolor', actor = actorName, name = label, color = color })
    end
    cb({ ok = true })
end)

-- Shared minimap-blip mode for a waypoint: 0 hidden → 1 shown → 2 flashing. ANY
-- member can toggle — it's a squad-wide "ping this spot" for the whole team, NOT
-- an edit (add/edit/delete are vice+leader only). Persist it and re-push so
-- every client's minimap matches.
QBCore.Functions.CreateCallback('hk-hub:squad:setWaypointBlipMode', function(source, cb, data)
    local squadID = tonumber(data and data.squadID)
    local wpID    = tonumber(data and data.waypointId)
    local cid = getIdentifier(source)
    if not squadID or not wpID or not isMemberOf(squadID, cid) then cb({ ok = false }) return end

    local squad = Cache.squads[squadID]
    local wp = squad and squad.waypoints and squad.waypoints[wpID]
    if not wp then cb({ ok = false }) return end

    local mode = tonumber(data and data.mode)
    if mode == nil then mode = ((tonumber(wp.map_mode) or 0) + 1) % 3 end   -- cycle if not given
    mode = math.floor(mode) % 3
    if mode < 0 then mode = 0 end

    MySQL.update.await('UPDATE hk_squad_waypoints SET map_mode = ? WHERE id = ? AND squad_id = ?',
        { mode, wpID, squadID })
    wp.map_mode = mode

    pushWaypointsUpdated(squadID)   -- every member re-syncs blips + panel icon
    cb({ ok = true, mode = mode })
end)

QBCore.Functions.CreateCallback('hk-hub:squad:clearWaypoints', function(source, cb, squadID)
    squadID = tonumber(squadID)
    local cid = getIdentifier(source)
    if not squadID or not isMemberOf(squadID, cid) then cb({ ok = false }) return end
    if not canEditWaypoints(squadID, cid) then cb({ ok = false, err = 'not_officer' }) return end
    MySQL.update.await('DELETE FROM hk_squad_waypoints WHERE squad_id = ?', { squadID })
    local squad = Cache.squads[squadID]
    if squad then squad.waypoints = {} end
    pushWaypointsUpdated(squadID)
    cb({ ok = true })
end)

-- Player picks their own minimap blip / 3D-tag colour (GTA blip index). Persists
-- and re-syncs the squad so teammates immediately see the new colour.
QBCore.Functions.CreateCallback('hk-hub:squad:setBlipColor', function(source, cb, data)
    local cid = getIdentifier(source)
    local squad = squadOf(cid)
    if not squad then cb({ ok = false, err = 'no_squad' }) return end
    local color = tonumber(data and data.color)
    if color == nil or not ALLOWED_BLIP_COLORS[color] then cb({ ok = false, err = 'bad_color' }) return end

    MySQL.update.await('UPDATE hk_squad_members SET blip_color = ? WHERE squad_id = ? AND citizenid = ?',
        { color, squad.id, cid })
    local m = squad.members[tostring(cid)]
    if m then m.blip_color = color end

    syncSquad(squad.id)   -- refresh everyone's roster (colour swatch)
    cb({ ok = true, color = color })
end)

-- Set a team-only nickname (or clear it → falls back to registered char name).
-- Cleared automatically on leave/kick since the member row is deleted.
QBCore.Functions.CreateCallback('hk-hub:squad:setNickname', function(source, cb, data)
    local cid = getIdentifier(source)
    local squad = squadOf(cid)
    if not squad then cb({ ok = false, err = 'no_squad' }) return end

    local nick = tostring((data and data.nickname) or ''):gsub('^%s+', ''):gsub('%s+$', ''):sub(1, 32)
    local store = (nick ~= '') and nick or nil

    MySQL.update.await('UPDATE hk_squad_members SET nickname = ? WHERE squad_id = ? AND citizenid = ?',
        { store, squad.id, cid })
    local m = squad.members[tostring(cid)]
    if m then m.nickname = store end

    syncSquad(squad.id)   -- refresh everyone's roster + blip/tag names
    cb({ ok = true, nickname = store })
end)

-- Leader-only: rename the squad. Persists + re-syncs so every member's header
-- and the 3D/blip labels update immediately.
QBCore.Functions.CreateCallback('hk-hub:squad:rename', function(source, cb, data)
    local cid = getIdentifier(source)
    local squad = squadOf(cid)
    if not squad then cb({ ok = false, err = 'no_squad' }) return end
    local m = squad.members[tostring(cid)]
    if not m or not isOwnerFlag(m.is_owner) then cb({ ok = false, err = 'not_leader' }) return end

    local name = tostring((data and data.name) or ''):gsub('^%s+', ''):gsub('%s+$', ''):sub(1, 64)
    if name == '' then cb({ ok = false, err = 'empty' }) return end
    local oldName = squad.name

    MySQL.update.await('UPDATE hk_squads SET name = ? WHERE id = ?', { name, squad.id })
    squad.name = name

    syncSquad(squad.id)
    if name ~= oldName then
        logSystem(squad.id, { verb = 'rename', actor = displayName(m, source), old = oldName, name = name })
    end
    cb({ ok = true, name = name })
end)

-- ---- Squad chat -----------------------------------------------------------
-- Squad-only room, separate from hk-chat. Full backlog readable by any member
-- (incl. newly-joined). Purged automatically via FK CASCADE when the squad is
-- deleted (last member leaves).

local CHAT_HISTORY_LIMIT = 100

-- Activity log: persist a 'system' message (event JSON in body) and push it live
-- to every online member, threaded into the same chat stream as normal messages
-- so it purges with the squad (FK CASCADE) and shows inline like a date divider.
--   verb  = machine key the NUI maps to an icon + bilingual template
--   actor = who did it (display name); extra fields (target/name/old) as needed
function logSystem(squadID, event)
    squadID = tonumber(squadID)
    if not squadID or type(event) ~= 'table' or not event.verb then return end
    local body = json.encode(event)
    local id = MySQL.insert.await(
        'INSERT INTO hk_squad_messages (squad_id, citizenid, author, body, kind) VALUES (?, NULL, ?, ?, ?)',
        { squadID, (event.actor or 'System'):sub(1, 64), body:sub(1, 512), 'system' })
    if not id then return end
    local now = os.time()
    for _, src in ipairs(onlineMembers(squadID)) do
        TriggerClientEvent('hk-hub:squad:message', src, {
            id = tostring(id), kind = 'system', event = event, ts = now,
        })
    end
end

-- Full backlog for the member's squad (oldest→newest). Chat + activity events.
QBCore.Functions.CreateCallback('hk-hub:squad:getMessages', function(source, cb)
    local cid = getIdentifier(source)
    local squad = squadOf(cid)
    if not squad then cb({ ok = false, err = 'no_squad', messages = {} }) return end

    local rows = MySQL.query.await([[
        SELECT id, citizenid, author, body, kind, UNIX_TIMESTAMP(created_at) AS ts
        FROM hk_squad_messages WHERE squad_id = ? ORDER BY id ASC LIMIT ?
    ]], { squad.id, CHAT_HISTORY_LIMIT }) or {}
    local out = {}
    for _, r in ipairs(rows) do
        if r.kind == 'system' then
            local ok, event = pcall(json.decode, r.body)
            out[#out + 1] = {
                id = tostring(r.id), kind = 'system',
                event = (ok and type(event) == 'table') and event or { verb = 'unknown', actor = r.author },
                ts = tonumber(r.ts) or 0,
            }
        elseif r.kind == 'image' then
            out[#out + 1] = {
                id = tostring(r.id), kind = 'image', author = r.author, url = r.body,
                ts = tonumber(r.ts) or 0,
                isSelf = tostring(r.citizenid) == tostring(cid),
            }
        else
            out[#out + 1] = {
                id = tostring(r.id), kind = 'chat', author = r.author, body = r.body,
                ts = tonumber(r.ts) or 0,
                isSelf = tostring(r.citizenid) == tostring(cid),
            }
        end
    end
    cb({ ok = true, messages = out })
end)

-- Send a message → persist, then push to every ONLINE member (incl. sender).
QBCore.Functions.CreateCallback('hk-hub:squad:sendMessage', function(source, cb, data)
    local cid = getIdentifier(source)
    local squad = squadOf(cid)
    if not squad then cb({ ok = false, err = 'no_squad' }) return end

    local body = tostring((data and data.body) or ''):gsub('^%s+', ''):gsub('%s+$', ''):sub(1, 512)
    if body == '' then cb({ ok = false, err = 'empty' }) return end

    local m = squad.members[tostring(cid)]
    local author = displayName(m, source)

    local id = MySQL.insert.await(
        'INSERT INTO hk_squad_messages (squad_id, citizenid, author, body) VALUES (?, ?, ?, ?)',
        { squad.id, cid, author, body })
    if not id then cb({ ok = false, err = 'db' }) return end

    local now = os.time()
    for _, src in ipairs(onlineMembers(squad.id)) do
        -- isSelf resolved per-recipient here so the NUI doesn't need its own cid.
        TriggerClientEvent('hk-hub:squad:message', src, {
            id = tostring(id), kind = 'chat', author = author, body = body, ts = now,
            isSelf = tostring(getIdentifier(src)) == tostring(cid),
        })
    end
    cb({ ok = true, id = tostring(id) })
end)

-- Return the player's own qb-phone gallery (phone_gallery) so the panel can show
-- a picker. URLs only — nothing sensitive; scoped strictly to the caller's cid.
QBCore.Functions.CreateCallback('hk-hub:squad:getGallery', function(source, cb)
    local cid = getIdentifier(source)
    if not cid then cb({ ok = false, images = {} }) return end
    local rows = MySQL.query.await(
        'SELECT image, UNIX_TIMESTAMP(`date`) AS ts FROM phone_gallery WHERE citizenid = ? ORDER BY `date` DESC LIMIT 60',
        { cid }) or {}
    local out = {}
    for _, r in ipairs(rows) do
        if type(r.image) == 'string' and r.image ~= '' then
            out[#out + 1] = { url = r.image, ts = tonumber(r.ts) or 0 }
        end
    end
    cb({ ok = true, images = out })
end)

-- Send a gallery image into squad chat. The chosen URL MUST belong to the
-- caller's own gallery (server re-checks phone_gallery) so nobody can inject an
-- arbitrary URL. Stored as kind='image', body = URL; broadcast like a message.
QBCore.Functions.CreateCallback('hk-hub:squad:sendImage', function(source, cb, data)
    local cid = getIdentifier(source)
    local squad = squadOf(cid)
    if not squad then cb({ ok = false, err = 'no_squad' }) return end

    local url = tostring((data and data.url) or ''):sub(1, 512)
    if url == '' then cb({ ok = false, err = 'empty' }) return end

    -- Ownership check: the URL has to be one of THIS player's gallery photos.
    local owned = MySQL.query.await(
        'SELECT 1 FROM phone_gallery WHERE citizenid = ? AND image = ? LIMIT 1', { cid, url })
    if not owned or #owned == 0 then cb({ ok = false, err = 'not_owned' }) return end

    local m = squad.members[tostring(cid)]
    local author = displayName(m, source)

    local id = MySQL.insert.await(
        'INSERT INTO hk_squad_messages (squad_id, citizenid, author, body, kind) VALUES (?, ?, ?, ?, ?)',
        { squad.id, cid, author, url, 'image' })
    if not id then cb({ ok = false, err = 'db' }) return end

    local now = os.time()
    for _, src in ipairs(onlineMembers(squad.id)) do
        TriggerClientEvent('hk-hub:squad:message', src, {
            id = tostring(id), kind = 'image', author = author, url = url, ts = now,
            isSelf = tostring(getIdentifier(src)) == tostring(cid),
        })
    end
    cb({ ok = true, id = tostring(id) })
end)

-- ---- Lifecycle ------------------------------------------------------------

-- On (re)connect, if the player belongs to a persisted squad, push it so their
-- client rebinds blips/tags/radio without any manual re-join.
RegisterNetEvent('QBCore:Server:PlayerLoaded', function(player)
    local src = (player and player.PlayerData and player.PlayerData.source) or source
    if not src then return end
    SetTimeout(1500, function()
        local squad = squadOf(getIdentifier(src))
        if not squad then return end
        local m = squad.members[tostring(getIdentifier(src))]
        TriggerClientEvent('hk-hub:squad:setCurrent', src, {
            squadID  = squad.id,
            isLeader = m ~= nil and isOwnerFlag(m.is_owner),
            name     = squad.name,
            code     = squad.code,
            radio    = squad.radio,
        })
        syncSquad(squad.id)
    end)
end)

-- On drop, refresh remaining members so blips/roster reflect the departure.
-- (Membership persists in the DB — dropping is not leaving.)
AddEventHandler('playerDropped', function()
    local src = source
    PendingInvites[src] = nil
    for tgt, inv in pairs(PendingInvites) do
        if inv and inv.inviterSource == src then PendingInvites[tgt] = nil end
    end
    local squadID = findSquadIdByMember(src)
    if squadID > 0 then
        SetTimeout(250, function() syncSquad(squadID) end)
    end
end)
