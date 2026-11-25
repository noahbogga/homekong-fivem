-- ═══════════════════════════════════════════════════════════════ --
--   HK-CHAT — framework wrapper (server)                              --
--   QBCore bridge + identity/permission helpers used by the router.   --
-- ═══════════════════════════════════════════════════════════════ --
QBCore = exports['qb-core']:GetCoreObject()

-- ═══════════════════════════════════════════════════════════════ --
--   ADMIN GATE — mirrors hk-scenario's three-source model.           --
--   ANY one of these grants admin (announcements, /chatadmin,         --
--   see-every-command, bypass command blocks):                       --
--     (A) txAdmin-authenticated admins (fired via txAdmin:events)     --
--     (B) ACE principals (QBCore god/admin/mod, group.*, command)     --
--     (C) explicit owner identifier fallback (Config.AdminAllowlist)  --
-- ═══════════════════════════════════════════════════════════════ --

-- (A) live set of txAdmin-authenticated admins, keyed by netid.
local txAdmins = {}

AddEventHandler('txAdmin:events:adminAuth', function(data)
    if type(data) ~= 'table' or data.netid == nil then return end
    local netid = tonumber(data.netid)
    if not netid then return end
    if netid == -1 then
        txAdmins = {}  -- broadcast invalidation: everyone must re-auth
        -- Everyone's admin status may have changed → refresh all clients.
        TriggerEvent('hk-chat:internal:adminChanged', -1)
        return
    end
    if data.isAdmin then txAdmins[netid] = true else txAdmins[netid] = nil end
    -- txAdmin auth landed (possibly AFTER this client asked for its admin flag,
    -- e.g. the checkIfAdmin nudge on NUI load) → re-push this player's flag so
    -- their /chatadmin access + see-all palette update live, no timing race.
    TriggerEvent('hk-chat:internal:adminChanged', netid)
end)

AddEventHandler('playerDropped', function()
    if source and source ~= 0 then txAdmins[source] = nil end
end)

-- (B) ACE principals that count as "an admin".
local ADMIN_ACES = {
    'qbcore.god', 'qbcore.admin', 'qbcore.mod',
    'group.god', 'group.superadmin', 'group.admin', 'group.mod',
    'command',   -- superadmin "allow all commands" grant
}

-- Is this source an admin for chat purposes?
function IsChatAdmin(src)
    if not src or src == 0 then return true end -- console/server is admin
    src = tonumber(src)
    if not src then return false end

    -- (A) txAdmin admin? (safe even if the netid isn't a connected player)
    if txAdmins[src] then return true end

    -- The remaining checks call player natives that THROW "Argument at index 0
    -- was null" if the netid isn't a currently-connected player (e.g. txAdmin's
    -- "test account" auth fires for a ref with no live in-game player). Bail out
    -- unless this src maps to a real connected player.
    if not GetPlayerName(src) then return false end

    -- (B) any admin ACE?
    for _, ace in ipairs(ADMIN_ACES) do
        if IsPlayerAceAllowed(src, ace) then return true end
    end

    -- (C) explicit owner identifier fallback.
    for i = 0, GetNumPlayerIdentifiers(src) - 1 do
        local id = GetPlayerIdentifier(src, i)
        if id and (Config.AdminAllowlist or {})[id] then return true end
    end

    return false
end

-- Stable per-player identifier for nickname storage. Prefer license.
function GetChatLicense(src)
    local ident = QBCore.Functions.GetIdentifier(src, 'license')
    if ident then return ident end
    -- Fallback: scan identifiers directly.
    for _, id in ipairs(GetPlayerIdentifiers(src) or {}) do
        if id:sub(1, 8) == 'license:' then return id end
    end
    return ('src:%s'):format(src)
end

-- RP character name ("First Last") for IC channels (job/system/whisper origin).
function GetCharName(src)
    local Player = QBCore.Functions.GetPlayer(src)
    if Player then
        local ci = Player.PlayerData.charinfo
        if ci and ci.firstname then
            return (('%s %s'):format(ci.firstname, ci.lastname or '')):gsub('%s+$', '')
        end
    end
    local n = GetPlayerName(src)
    return n or ('Player %s'):format(src)
end

-- Job name, or the shared unemployed bucket.
function GetJobRoomFor(src)
    local Player = QBCore.Functions.GetPlayer(src)
    if Player then
        local job = Player.PlayerData.job
        if job and job.name and job.name ~= '' then return job.name end
    end
    return Config.UnemployedRoom
end
