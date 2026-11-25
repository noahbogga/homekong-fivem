--=====================================================================
-- hk-scenario :: server/props.lua
--   Authoritative store of placeable props (MySQL), gated behind the
--   same admin check as zones. Broadcasts the full prop list to every
--   client; each client spawns local (non-networked) copies of nearby
--   props. Props carry an optional interaction (trigger + action) and
--   are exposed to other resources via exports.
--=====================================================================

local props = {}  -- in-memory mirror = broadcast payload

local function rowToProp(row)
    return {
        id       = row.id,
        label    = row.label,
        model    = row.model,
        x = row.x + 0.0, y = row.y + 0.0, z = row.z + 0.0,
        heading  = (row.heading or 0.0) + 0.0,
        z_offset = (row.z_offset or 0.0) + 0.0,
        frozen   = (row.frozen == 1 or row.frozen == true),
        -- interaction
        trigger      = row.trigger_type or 'none',   -- none|target|zonekey|zoneauto
        action       = row.action_type or 'none',    -- none|command|client|server
        action_data  = row.action_data or '',        -- command string / event name
        interact_label = row.interact_label or 'Interact',
        interact_icon  = row.interact_icon or 'fas fa-hand-pointer',
        interact_dist  = (row.interact_dist or 2.5) + 0.0,
    }
end

local function reload()
    local rows = MySQL.query.await('SELECT * FROM hk_scenario_props ORDER BY id') or {}
    props = {}
    for _, r in ipairs(rows) do props[#props + 1] = rowToProp(r) end
end

local function broadcast()
    TriggerClientEvent('hk-scenario:props:sync', -1, props)
end

-- Expose for the editor's list page + engine.
Scn_getProps = function() return props end

-- ── Schema ──────────────────────────────────────────────────────────────────
MySQL.ready(function()
    MySQL.query([[
        CREATE TABLE IF NOT EXISTS hk_scenario_props (
            id INT AUTO_INCREMENT PRIMARY KEY,
            label VARCHAR(64) NOT NULL DEFAULT 'Prop',
            model VARCHAR(64) NOT NULL DEFAULT 'prop_barrier_work05',
            x DOUBLE NOT NULL, y DOUBLE NOT NULL, z DOUBLE NOT NULL,
            heading DOUBLE NOT NULL DEFAULT 0,
            z_offset DOUBLE NOT NULL DEFAULT 0,
            frozen TINYINT(1) NOT NULL DEFAULT 1,
            trigger_type   VARCHAR(16) NOT NULL DEFAULT 'none',
            action_type    VARCHAR(16) NOT NULL DEFAULT 'none',
            action_data    VARCHAR(255) NOT NULL DEFAULT '',
            interact_label VARCHAR(64) NOT NULL DEFAULT 'Interact',
            interact_icon  VARCHAR(64) NOT NULL DEFAULT 'fas fa-hand-pointer',
            interact_dist  DOUBLE NOT NULL DEFAULT 2.5
        )
    ]])
    reload()
    -- Push the freshly-loaded list to everyone. Clients fire requestSync on
    -- resource start, but that can land BEFORE MySQL.ready finishes loading
    -- (the reply would be empty and never refreshed). Broadcasting here closes
    -- that race so props reliably spawn after a restart.
    broadcast()
end)

-- ── Reads ───────────────────────────────────────────────────────────────────
lib.callback.register('hk-scenario:props:list', function(source)
    if not Scn_isAllowed(source) then return {} end
    return props
end)

RegisterNetEvent('hk-scenario:props:requestSync', function()
    TriggerClientEvent('hk-scenario:props:sync', source, props)
end)

AddEventHandler('playerJoining', function()
    TriggerClientEvent('hk-scenario:props:sync', source, props)
end)

-- ── Writes (admin-gated, validated) ─────────────────────────────────────────
local VALID_TRIGGER = { none=true, target=true, zonekey=true, zoneauto=true }
local VALID_ACTION  = { none=true, command=true, client=true, server=true }

lib.callback.register('hk-scenario:props:save', function(source, p)
    if not Scn_isAllowed(source) then return false end
    if type(p) ~= 'table' then return false end

    local trigger = VALID_TRIGGER[p.trigger] and p.trigger or 'none'
    local action  = VALID_ACTION[p.action]  and p.action  or 'none'

    -- 13 columns, in this order for BOTH insert and update.
    local params = {
        tostring(p.label or 'Prop'):sub(1, 64),
        tostring(p.model or ScnCfg.Props.fallbackModel):sub(1, 64),
        (tonumber(p.x) or 0) + 0.0, (tonumber(p.y) or 0) + 0.0, (tonumber(p.z) or 0) + 0.0,
        (tonumber(p.heading) or 0) + 0.0,
        (tonumber(p.z_offset) or 0) + 0.0,
        p.frozen and 1 or 0,
        trigger,
        action,
        tostring(p.action_data or ''):sub(1, 255),
        tostring(p.interact_label or 'Interact'):sub(1, 64),
        tostring(p.interact_icon or 'fas fa-hand-pointer'):sub(1, 64),
        (tonumber(p.interact_dist) or ScnCfg.Props.defaultInteractDist) + 0.0,
    }
    -- params has 14 elements.

    local newId
    if p.id then
        local uparams = {}
        for i = 1, #params do uparams[i] = params[i] end
        uparams[#uparams + 1] = tonumber(p.id)   -- id LAST (never table.unpack mid-list)
        MySQL.update.await([[
            UPDATE hk_scenario_props SET
              label=?, model=?, x=?, y=?, z=?, heading=?, z_offset=?, frozen=?,
              trigger_type=?, action_type=?, action_data=?, interact_label=?, interact_icon=?, interact_dist=?
            WHERE id=?
        ]], uparams)
        newId = tonumber(p.id)
        Scn_audit(source, 'updateProp', ('#%s %s'):format(newId, params[1]))
    else
        newId = MySQL.insert.await([[
            INSERT INTO hk_scenario_props
              (label, model, x, y, z, heading, z_offset, frozen,
               trigger_type, action_type, action_data, interact_label, interact_icon, interact_dist)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ]], params)
        Scn_audit(source, 'createProp', ('#%s %s'):format(newId, params[1]))
    end

    reload()
    broadcast()
    return newId
end)

lib.callback.register('hk-scenario:props:delete', function(source, propId)
    if not Scn_isAllowed(source) then return false end
    propId = tonumber(propId)
    if not propId then return false end
    MySQL.update.await('DELETE FROM hk_scenario_props WHERE id = ?', { propId })
    Scn_audit(source, 'deleteProp', '#' .. propId)
    reload()
    broadcast()
    return true
end)

-- ── Server-side action relay (for action_type == 'server') ──────────────────
-- A prop interaction can fire a server event. We relay through here so the
-- action string is executed server-side. Any player may trigger (interactions
-- are meant to be player-facing); the configured event decides what happens.
RegisterNetEvent('hk-scenario:props:serverAction', function(propId)
    local src = source
    propId = tonumber(propId)
    if not propId then return end
    local prop
    for _, pr in ipairs(props) do if pr.id == propId then prop = pr break end end
    if not prop or prop.action ~= 'server' or prop.action_data == '' then return end
    -- fire the configured server event with the interacting player's src.
    TriggerEvent(prop.action_data, src, propId)
end)

