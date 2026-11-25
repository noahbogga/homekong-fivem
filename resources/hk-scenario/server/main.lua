--=====================================================================
-- hk-cleararea :: server
--   Authoritative store of clear-zones (MySQL), gated behind the
--   allowlist. Broadcasts the full zone list to every client so the
--   client-side engine can clear ambient entities near each zone.
--
--   AUTH: re-verify every mutation server-side. Opening the editor is
--   UX; this is the gate. Never trust the client.
--=====================================================================

--=====================================================================
-- WHO IS AN ADMIN — three independent sources, ANY one grants access:
--
--   A) txAdmin admins (panel login AND the in-game CFX-authenticated
--      menu). txAdmin does NOT use ACE for this — it fires the server
--      event `txAdmin:events:adminAuth` { netid, isAdmin } when a player
--      authenticates as / stops being an admin. We track those netids.
--
--   B) Framework / ACE admins (QBCore god/admin/mod, raw ACE groups,
--      or a superadmin "command" grant) via IsPlayerAceAllowed.
--
--   C) Fallback: the explicit owner identifier list in allowlist.lua
--      (works even if txAdmin + ACE are both somehow unavailable).
--=====================================================================

-- (A) live set of txAdmin-authenticated admins, keyed by netid.
local txAdmins = {}

AddEventHandler('txAdmin:events:adminAuth', function(data)
    if type(data) ~= 'table' or data.netid == nil then return end
    local netid = tonumber(data.netid)
    if not netid then return end
    if netid == -1 then
        -- broadcast invalidation: all admins must re-auth -> clear the set.
        txAdmins = {}
        return
    end
    if data.isAdmin then
        txAdmins[netid] = true
    else
        txAdmins[netid] = nil
    end
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

local function isAllowed(src)
    if not src or src == 0 then return false end

    -- (A) txAdmin admin?
    if txAdmins[tonumber(src)] then return true end

    -- (B) any admin ACE?
    for _, ace in ipairs(ADMIN_ACES) do
        if IsPlayerAceAllowed(src, ace) then return true end
    end

    -- (C) explicit owner identifier fallback.
    for i = 0, GetNumPlayerIdentifiers(src) - 1 do
        local id = GetPlayerIdentifier(src, i)
        if id and Allowed[id] then return true end
    end

    return false
end
-- Shared with server/props.lua (same admin gate).
Scn_isAllowed = isAllowed

-- Tell a client whether they're an admin (gates the prop "Edit" target handle).
RegisterNetEvent('hk-scenario:requestAdminFlag', function()
    TriggerClientEvent('hk-scenario:setAdminFlag', source, isAllowed(source))
end)

local function audit(src, action, detail)
    local name = GetPlayerName(src) or 'unknown'
    print(('[hk-scenario] %s (%s) -> %s %s'):format(name, src, action, detail or ''))
end
Scn_audit = audit

-- ── In-memory mirror of the DB, kept as the broadcast payload ───────────────
local zones = {}  -- array of zone rows (see rowToZone)

local function rowToZone(row)
    return {
        id        = row.id,
        label     = row.label,
        shape     = row.shape,                 -- 'circle' | 'box'
        x = row.x + 0.0, y = row.y + 0.0, z = row.z + 0.0,
        heading   = (row.heading or 0.0) + 0.0, -- box orientation
        radius    = (row.radius or 0.0) + 0.0,  -- circle
        length    = (row.length or 0.0) + 0.0,  -- box
        width     = (row.width  or 0.0) + 0.0,  -- box
        height    = (row.height or 0.0) + 0.0,  -- box
        interval  = math.max(ScnCfg.Engine.minZoneInterval, row.clear_interval or ScnCfg.Engine.defaultInterval),
        enabled   = (row.enabled == 1 or row.enabled == true),
        clr_vehicles    = (row.clr_vehicles == 1 or row.clr_vehicles == true),
        clr_peds        = (row.clr_peds == 1 or row.clr_peds == true),
        clr_objects     = (row.clr_objects == 1 or row.clr_objects == true),
        clr_projectiles = (row.clr_projectiles == 1 or row.clr_projectiles == true),
        -- hidden path blocking (steer ambient AI away)
        blk_roads       = (row.blk_roads == 1 or row.blk_roads == true),
        blk_peds        = (row.blk_peds == 1 or row.blk_peds == true),
        blk_navmesh     = (row.blk_navmesh == 1 or row.blk_navmesh == true),
    }
end

local function reload()
    local rows = MySQL.query.await('SELECT * FROM hk_cleararea_zones ORDER BY id') or {}
    zones = {}
    for _, r in ipairs(rows) do zones[#zones + 1] = rowToZone(r) end
end

local function broadcast()
    TriggerClientEvent('hk-scenario:zones:sync', -1, zones)
end

-- ── Schema + initial load ───────────────────────────────────────────────────
MySQL.ready(function()
    MySQL.query([[
        CREATE TABLE IF NOT EXISTS hk_cleararea_zones (
            id INT AUTO_INCREMENT PRIMARY KEY,
            label VARCHAR(64) NOT NULL DEFAULT 'Zone',
            shape VARCHAR(8) NOT NULL DEFAULT 'circle',
            x DOUBLE NOT NULL, y DOUBLE NOT NULL, z DOUBLE NOT NULL,
            heading DOUBLE NOT NULL DEFAULT 0,
            radius DOUBLE NOT NULL DEFAULT 0,
            length DOUBLE NOT NULL DEFAULT 0,
            width  DOUBLE NOT NULL DEFAULT 0,
            height DOUBLE NOT NULL DEFAULT 0,
            clear_interval INT NOT NULL DEFAULT 500,
            enabled TINYINT(1) NOT NULL DEFAULT 1,
            clr_vehicles    TINYINT(1) NOT NULL DEFAULT 1,
            clr_peds        TINYINT(1) NOT NULL DEFAULT 1,
            clr_objects     TINYINT(1) NOT NULL DEFAULT 0,
            clr_projectiles TINYINT(1) NOT NULL DEFAULT 0,
            blk_roads       TINYINT(1) NOT NULL DEFAULT 0,
            blk_peds        TINYINT(1) NOT NULL DEFAULT 0,
            blk_navmesh     TINYINT(1) NOT NULL DEFAULT 0
        )
    ]])

    -- Migrate older installs: add the block columns if the table predates them.
    for _, col in ipairs({ 'blk_roads', 'blk_peds', 'blk_navmesh' }) do
        MySQL.query(("ALTER TABLE hk_cleararea_zones ADD COLUMN IF NOT EXISTS %s TINYINT(1) NOT NULL DEFAULT 0"):format(col))
    end

    -- Tiny key/value table so we can remember one-time actions across restarts.
    MySQL.query([[
        CREATE TABLE IF NOT EXISTS hk_scenario_meta (
            k VARCHAR(64) PRIMARY KEY,
            v VARCHAR(255) NOT NULL DEFAULT ''
        )
    ]])

    -- The OLD seeder used to re-insert two legacy uj zones on every restart
    -- (gated only on "does a zone with this label exist?", which meant deleting
    -- them just made the next restart re-add them — the bug you hit). We now
    -- record a one-time 'seeded_uj' flag and NEVER auto-insert again. Whatever
    -- zones are in the DB right now are the source of truth; deletes stick.
    local alreadySeeded = MySQL.scalar.await('SELECT v FROM hk_scenario_meta WHERE k = ?', { 'seeded_uj' })
    if not alreadySeeded then
        MySQL.insert.await('INSERT INTO hk_scenario_meta (k, v) VALUES (?, ?)', { 'seeded_uj', os.date('%Y-%m-%d %H:%M:%S') })
        print('[hk-scenario] legacy uj auto-seed disabled — zones are now DB-driven only.')
    end

    reload()
    -- Same startup race as props: clients requestSync on resource start, which
    -- can arrive before MySQL.ready finishes. Broadcast the loaded list so zones
    -- are live immediately after a restart without needing a reconnect.
    broadcast()
end)

-- ── Reads (any allowed admin) ───────────────────────────────────────────────
lib.callback.register('hk-scenario:isAllowed', function(source)
    return isAllowed(source)
end)

lib.callback.register('hk-scenario:zones:list', function(source)
    if not isAllowed(source) then return {} end
    return zones
end)

-- New clients (and the editor) pull the current list on demand.
RegisterNetEvent('hk-scenario:zones:requestSync', function()
    TriggerClientEvent('hk-scenario:zones:sync', source, zones)
end)

AddEventHandler('playerJoining', function()
    TriggerClientEvent('hk-scenario:zones:sync', source, zones)
end)

-- ── Writes (allowlist-gated, validated) ─────────────────────────────────────
local function clampInterval(v)
    return math.max(ScnCfg.Engine.minZoneInterval, math.floor(tonumber(v) or ScnCfg.Engine.defaultInterval))
end

lib.callback.register('hk-scenario:zones:save', function(source, z)
    if not isAllowed(source) then return false end
    if type(z) ~= 'table' then return false end

    local shape = (z.shape == 'box') and 'box' or 'circle'
    local params = {
        tostring(z.label or 'Zone'):sub(1, 64),
        shape,
        (tonumber(z.x) or 0) + 0.0, (tonumber(z.y) or 0) + 0.0, (tonumber(z.z) or 0) + 0.0,
        (tonumber(z.heading) or 0) + 0.0,
        (tonumber(z.radius) or 0) + 0.0,
        (tonumber(z.length) or 0) + 0.0,
        (tonumber(z.width)  or 0) + 0.0,
        (tonumber(z.height) or 0) + 0.0,
        clampInterval(z.interval),
        z.enabled and 1 or 0,
        z.clr_vehicles and 1 or 0,
        z.clr_peds and 1 or 0,
        z.clr_objects and 1 or 0,
        z.clr_projectiles and 1 or 0,
        z.blk_roads and 1 or 0,
        z.blk_peds and 1 or 0,
        z.blk_navmesh and 1 or 0,
    }
    -- params now has 19 elements (16 original + 3 block flags).

    local newId
    if z.id then
        -- update existing.
        -- BUGFIX: `table.unpack(params)` mid-table-constructor is truncated to
        -- its FIRST value in Lua, so the UPDATE was silently getting 2 params
        -- for N placeholders and failing every time (this is why only CREATE
        -- ever persisted). Build the arg list explicitly so id is LAST.
        local uparams = {}
        for i = 1, #params do uparams[i] = params[i] end
        uparams[#uparams + 1] = tonumber(z.id)
        MySQL.update.await([[
            UPDATE hk_cleararea_zones SET
              label=?, shape=?, x=?, y=?, z=?, heading=?, radius=?, length=?, width=?, height=?,
              clear_interval=?, enabled=?, clr_vehicles=?, clr_peds=?, clr_objects=?, clr_projectiles=?,
              blk_roads=?, blk_peds=?, blk_navmesh=?
            WHERE id=?
        ]], uparams)
        newId = tonumber(z.id)
        audit(source, 'updateZone', ('#%s %s'):format(newId, params[1]))
    else
        newId = MySQL.insert.await([[
            INSERT INTO hk_cleararea_zones
              (label, shape, x, y, z, heading, radius, length, width, height,
               clear_interval, enabled, clr_vehicles, clr_peds, clr_objects, clr_projectiles,
               blk_roads, blk_peds, blk_navmesh)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ]], params)
        audit(source, 'createZone', ('#%s %s'):format(newId, params[1]))
    end

    reload()
    broadcast()
    return newId
end)

lib.callback.register('hk-scenario:zones:delete', function(source, zoneId)
    if not isAllowed(source) then return false end
    zoneId = tonumber(zoneId)
    if not zoneId then return false end
    MySQL.update.await('DELETE FROM hk_cleararea_zones WHERE id = ?', { zoneId })
    audit(source, 'deleteZone', '#' .. zoneId)
    reload()
    broadcast()
    return true
end)

lib.callback.register('hk-scenario:zones:toggle', function(source, zoneId, state)
    if not isAllowed(source) then return false end
    zoneId = tonumber(zoneId)
    if not zoneId then return false end
    MySQL.update.await('UPDATE hk_cleararea_zones SET enabled = ? WHERE id = ?', { state and 1 or 0, zoneId })
    audit(source, 'toggleZone', ('#%s=%s'):format(zoneId, tostring(state)))
    reload()
    broadcast()
    return true
end)
