--=====================================================================
-- hk-scenario :: server/population.lua
--   Server-wide ambient POPULATION density control. Stores one set of
--   density multipliers (vehicle / parked / ped / scenario), persisted
--   in hk_scenario_meta, and broadcasts them to every client which then
--   applies them (via qb-smallresources' setter if present, else its
--   own per-frame loop — see client/population.lua).
--
--   OPT-IN: if no density has ever been saved, we broadcast nothing and
--   the game / qb-smallresources defaults are left completely alone.
--=====================================================================

local DEFAULTS = { vehicle = 1.0, parked = 1.0, peds = 1.0, scenario = 1.0 }
local density = nil   -- nil = no override set yet (don't touch anything)

local function clampMul(v, fallback)
    v = tonumber(v)
    if not v then return fallback end
    if v < 0.0 then v = 0.0 elseif v > 5.0 then v = 5.0 end
    return v + 0.0
end

local function sanitize(t)
    if type(t) ~= 'table' then return nil end
    return {
        vehicle  = clampMul(t.vehicle,  DEFAULTS.vehicle),
        parked   = clampMul(t.parked,   DEFAULTS.parked),
        peds     = clampMul(t.peds,     DEFAULTS.peds),
        scenario = clampMul(t.scenario, DEFAULTS.scenario),
    }
end

local function broadcast()
    -- nil payload => clients drop any override and hand control back to defaults.
    TriggerClientEvent('hk-scenario:pop:sync', -1, density)
end

-- Expose current density (or defaults for the editor to seed its sliders).
Scn_getDensity = function() return density or DEFAULTS end

-- ── Persistence (shares the hk_scenario_meta k/v table) ─────────────────────
MySQL.ready(function()
    MySQL.query([[
        CREATE TABLE IF NOT EXISTS hk_scenario_meta (
            k VARCHAR(64) PRIMARY KEY,
            v VARCHAR(255) NOT NULL DEFAULT ''
        )
    ]])
    local raw = MySQL.scalar.await('SELECT v FROM hk_scenario_meta WHERE k = ?', { 'density' })
    if raw and raw ~= '' then
        local ok, decoded = pcall(json.decode, raw)
        if ok and type(decoded) == 'table' then
            density = sanitize(decoded)
            print('[hk-scenario] loaded population density override.')
        end
    end
    -- push to anyone already connected (and it will re-send on join below)
    if density then broadcast() end
end)

-- ── Reads ────────────────────────────────────────────────────────────────────
lib.callback.register('hk-scenario:pop:get', function(source)
    if not Scn_isAllowed(source) then return nil end
    return density   -- nil if no override yet; editor falls back to defaults
end)

RegisterNetEvent('hk-scenario:pop:requestSync', function()
    TriggerClientEvent('hk-scenario:pop:sync', source, density)
end)

AddEventHandler('playerJoining', function()
    if density then TriggerClientEvent('hk-scenario:pop:sync', source, density) end
end)

-- ── Writes (admin-gated) ──────────────────────────────────────────────────────
lib.callback.register('hk-scenario:pop:save', function(source, t)
    if not Scn_isAllowed(source) then return false end
    local d = sanitize(t)
    if not d then return false end
    density = d
    MySQL.update.await([[
        INSERT INTO hk_scenario_meta (k, v) VALUES ('density', ?)
        ON DUPLICATE KEY UPDATE v = VALUES(v)
    ]], { json.encode(d) })
    Scn_audit(source, 'setDensity', json.encode(d))
    broadcast()
    return true
end)

-- Clear the override entirely: hands ambient population back to the game /
-- qb-smallresources defaults on every client.
lib.callback.register('hk-scenario:pop:clear', function(source)
    if not Scn_isAllowed(source) then return false end
    density = nil
    MySQL.update.await('DELETE FROM hk_scenario_meta WHERE k = ?', { 'density' })
    Scn_audit(source, 'clearDensity', '')
    broadcast()   -- nil payload -> clients release their override
    return true
end)
