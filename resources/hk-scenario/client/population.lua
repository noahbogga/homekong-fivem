--=====================================================================
-- hk-scenario :: client/population.lua
--   Applies the server's population density override on this client.
--
--   COEXISTENCE: qb-smallresources already runs a per-frame density
--   setter (SetXDensityMultiplierThisFrame) driven by its own config +
--   its DecorSet export. Running a SECOND per-frame setter would race it
--   and flicker. So:
--     * if qb-smallresources is present, we push our values INTO it via
--       its DecorSet export (it stays the single per-frame authority);
--     * otherwise we run our own lightweight per-frame loop.
--
--   ScnDensity == nil  => no override; we do nothing and leave defaults /
--   qb-smallresources' own config untouched.
--=====================================================================

ScnDensity = nil   -- { vehicle, parked, peds, scenario } or nil

-- Set true once an admin has saved a MANUAL density override (via the density
-- editor -> hk-scenario:pop:sync). While true, the traffic biome system must NOT
-- fight it, so Scn_pushDensity (biome-driven) becomes a no-op. Cleared when the
-- manual override is cleared (pop:sync with nil).
local manualOverride = false

local qbSmall = GetResourceState('qb-smallresources') == 'started'

-- qb-smallresources maps: parked, vehicle, multiplier(random), peds, scenario.
-- We drive the four we expose; `multiplier` (random-vehicle) we tie to vehicle
-- so lowering traffic also thins random spawns.
local function pushToQbSmall(d)
    local ok = pcall(function()
        exports['qb-smallresources']:DecorSet('vehicle',    d.vehicle)
        exports['qb-smallresources']:DecorSet('parked',     d.parked)
        exports['qb-smallresources']:DecorSet('multiplier', d.vehicle)
        exports['qb-smallresources']:DecorSet('peds',       d.peds)
        exports['qb-smallresources']:DecorSet('scenario',   d.scenario)
    end)
    return ok
end

-- Biome-driven density push from client/traffic.lua (Layer 4.5). Runs the same
-- write path as a manual override, but defers to a manual override if one is
-- active (admin's explicit setting always wins over automatic biome variation).
function Scn_pushDensity(d)
    if manualOverride then return end
    if not d then return end
    ScnDensity = d
    if qbSmall then pushToQbSmall(d) end
end

RegisterNetEvent('hk-scenario:pop:sync', function(d)
    manualOverride = (d ~= nil)
    ScnDensity = d   -- may be nil (override cleared)
    if qbSmall and d then pushToQbSmall(d) end
    -- NOTE: if the override is cleared (d == nil) while qb-smallresources is
    -- active, we intentionally do NOT reset its values here — that's qb's own
    -- config domain. Clearing simply stops US from overriding. If you want the
    -- world fully back to qb defaults, restart qb-smallresources or set the
    -- sliders back to your baseline and save.
end)

AddEventHandler('onClientResourceStart', function(res)
    if res ~= GetCurrentResourceName() then return end
    TriggerServerEvent('hk-scenario:pop:requestSync')
end)

-- Fallback per-frame setter — ONLY runs when qb-smallresources is absent, so we
-- never double-drive the density natives.
if not qbSmall then
    CreateThread(function()
        while true do
            local d = ScnDensity
            if d then
                SetParkedVehicleDensityMultiplierThisFrame(d.parked)
                SetVehicleDensityMultiplierThisFrame(d.vehicle)
                SetRandomVehicleDensityMultiplierThisFrame(d.vehicle)
                SetPedDensityMultiplierThisFrame(d.peds)
                SetScenarioPedDensityMultiplierThisFrame(d.scenario, d.scenario)
                Wait(0)
            else
                Wait(1000)   -- idle cheaply while no override is set
            end
        end
    end)
end

-- Re-assert into qb-smallresources periodically in case something else calls
-- its DecorSet (last-writer-wins otherwise). Cheap: once a second, no-op if we
-- have no override.
if qbSmall then
    CreateThread(function()
        while true do
            Wait(1000)
            if ScnDensity then pushToQbSmall(ScnDensity) end
        end
    end)
end
