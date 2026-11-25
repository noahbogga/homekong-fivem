--=====================================================================
-- hk-optimizer :: server
--   Authoritative store of the tunable optimizer modes (MySQL), gated
--   behind the admin allowlist. Broadcasts saved settings to clients so
--   the client engine can apply a mode. Editing is admin-only; applying
--   is not (players will pick a mode later from the /hud F5 menu).
--
--   AUTH: re-verify every mutation server-side. Opening the editor is UX;
--   the callback gate is the real control. Never trust the client.
--=====================================================================

-- (A) live set of txAdmin-authenticated admins, keyed by netid.
local txAdmins = {}

AddEventHandler('txAdmin:events:adminAuth', function(data)
    if type(data) ~= 'table' or data.netid == nil then return end
    local netid = tonumber(data.netid)
    if not netid then return end
    if netid == -1 then txAdmins = {} return end
    if data.isAdmin then txAdmins[netid] = true else txAdmins[netid] = nil end
end)

AddEventHandler('playerDropped', function()
    if source and source ~= 0 then txAdmins[source] = nil end
end)

-- (B) ACE principals that count as "an admin".
local ADMIN_ACES = {
    'qbcore.god', 'qbcore.admin', 'qbcore.mod',
    'group.god', 'group.superadmin', 'group.admin', 'group.mod',
    'command',
}

local function isAllowed(src)
    if not OptiCfg.AdminOnly then return true end
    if not src or src == 0 then return false end
    if txAdmins[tonumber(src)] then return true end
    for _, ace in ipairs(ADMIN_ACES) do
        if IsPlayerAceAllowed(src, ace) then return true end
    end
    for i = 0, GetNumPlayerIdentifiers(src) - 1 do
        local id = GetPlayerIdentifier(src, i)
        if id and Allowed[id] then return true end
    end
    return false
end

local function audit(src, action, detail)
    local name = GetPlayerName(src) or 'unknown'
    print(('[hk-optimizer] %s (%s) -> %s %s'):format(name, src, action, detail or ''))
end

--=====================================================================
-- SQL — one row per editable mode. Columns are derived from OptiCfg.Schema
-- so the table always matches the config (missing columns are auto-added).
--=====================================================================
local function sqlType(kind)
    if kind == 'bool'  then return 'TINYINT(1)' end
    if kind == 'int'   then return 'INT' end
    return 'FLOAT'  -- float
end

local function sqlDefault(f)
    if f.kind == 'bool' then return f.default and 1 or 0 end
    return f.default
end

-- In-memory mirror, broadcast to clients: { [mode] = { key = value, ... } }
local modes = {}

local function rowToSettings(row)
    local s = {}
    for _, f in ipairs(OptiCfg.Schema) do
        local v = row[f.key]
        if f.kind == 'bool' then
            s[f.key] = (v == 1 or v == true)
        elseif f.kind == 'int' then
            s[f.key] = math.floor(tonumber(v) or f.default)
        else
            s[f.key] = (tonumber(v) or f.default) + 0.0
        end
    end
    return s
end

local function loadAll()
    local rows = MySQL.query.await('SELECT * FROM hk_optimizer_modes') or {}
    local byName = {}
    for _, r in ipairs(rows) do byName[r.mode] = r end

    modes = {}
    for _, m in ipairs(OptiCfg.Modes) do
        if m.editable then
            if byName[m.name] then
                modes[m.name] = rowToSettings(byName[m.name])
            else
                modes[m.name] = OptiCfg.DefaultSettings()
            end
        end
    end
    TriggerClientEvent('hk-optimizer:sync', -1, modes)
end

MySQL.ready(function()
    -- Base table (just the key). Setting columns are added below.
    MySQL.query([[
        CREATE TABLE IF NOT EXISTS hk_optimizer_modes (
            mode VARCHAR(32) NOT NULL PRIMARY KEY
        )
    ]])

    for _, f in ipairs(OptiCfg.Schema) do
        MySQL.query(("ALTER TABLE hk_optimizer_modes ADD COLUMN IF NOT EXISTS %s %s NOT NULL DEFAULT %s")
            :format(f.key, sqlType(f.kind), sqlDefault(f)))
    end

    -- Seed a row for each editable mode if absent.
    for _, m in ipairs(OptiCfg.Modes) do
        if m.editable then
            MySQL.insert.await('INSERT IGNORE INTO hk_optimizer_modes (mode) VALUES (?)', { m.name })
        end
    end

    loadAll()
end)

--=====================================================================
-- Callbacks
--=====================================================================
QBCore = QBCore or exports['qb-core']:GetCoreObject()

-- Editor open gate.
QBCore.Functions.CreateCallback('hk-optimizer:canOpen', function(source, cb)
    cb(isAllowed(source))
end)

-- Return current saved settings for all modes (admin only, drives the editor).
QBCore.Functions.CreateCallback('hk-optimizer:getModes', function(source, cb)
    if not isAllowed(source) then cb(nil) return end
    cb(modes)
end)

-- Ungated: any client can pull the saved mode data so a LATE JOINER (who
-- missed the boot/save broadcast) has values ready. This only delivers data
-- for hk-hub to use later — it does NOT apply anything on its own.
QBCore.Functions.CreateCallback('hk-optimizer:fetch', function(source, cb)
    cb(modes)
end)

-- Save one mode's settings (admin only). Validates every field against the
-- schema before writing, so a tampered client can't inject junk.
QBCore.Functions.CreateCallback('hk-optimizer:save', function(source, cb, mode, incoming)
    if not isAllowed(source) then cb(false) return end
    if type(mode) ~= 'string' or type(incoming) ~= 'table' then cb(false) return end

    -- mode must be an editable, known mode.
    local ok = false
    for _, m in ipairs(OptiCfg.Modes) do
        if m.editable and m.name == mode then ok = true break end
    end
    if not ok then cb(false) return end

    local cols, vals = {}, {}
    for _, f in ipairs(OptiCfg.Schema) do
        local v = incoming[f.key]
        if f.kind == 'bool' then
            v = (v == true or v == 1) and 1 or 0
        elseif f.kind == 'int' then
            v = math.floor(tonumber(v) or f.default)
            if f.min then v = math.max(f.min, math.min(f.max, v)) end
        else
            v = (tonumber(v) or f.default) + 0.0
            if f.min then v = math.max(f.min, math.min(f.max, v)) end
        end
        cols[#cols + 1] = f.key .. ' = ?'
        vals[#vals + 1] = v
    end
    vals[#vals + 1] = mode

    MySQL.update.await(
        ('UPDATE hk_optimizer_modes SET %s WHERE mode = ?'):format(table.concat(cols, ', ')),
        vals
    )
    audit(source, 'save', mode)
    loadAll()  -- re-broadcast so every client (and the editor) has fresh data
    cb(true)
end)

