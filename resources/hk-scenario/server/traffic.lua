--=====================================================================
-- hk-scenario :: server/traffic.lua
--   Server-wide TRAFFIC REALISM control (NO HESI / Wangan style).
--   Stores one settings blob (enabled / preset / spawner flags / addon
--   rate), persisted in hk_scenario_meta k='traffic', broadcast to every
--   client which then runs the behaviour loop + highway spawner
--   (see client/traffic.lua).
--
--   OPT-IN: if nothing has ever been saved we broadcast the config
--   default (enabled=false) and clients do nothing. Same philosophy as
--   the population density module (server/population.lua).
--=====================================================================

local T = ScnCfg.Traffic or {}

-- The live settings. nil until loaded/seeded from config defaults.
local settings = nil

local function defaults()
    return {
        enabled     = T.defaultEnabled and true or false,
        preset      = T.defaultPreset or 'Normal',
        spawnerOn   = (T.spawner and T.spawner.defaultOn) and true or false,
        -- intensity 0.25 .. 2.0 scales the spawner's live cap (maxSpawned).
        intensity   = 1.0,
        -- 0..1 chance a spawner car is an addon; seeded from config.
        addonChance = tonumber(T.addonChance) or 0.35,
    }
end

local VALID_PRESETS = T.presets or {}

local function sanitize(t)
    if type(t) ~= 'table' then return nil end
    local d = defaults()
    local preset = tostring(t.preset or d.preset)
    if not VALID_PRESETS[preset] then preset = d.preset end
    local intensity = tonumber(t.intensity) or d.intensity
    if intensity < 0.25 then intensity = 0.25 elseif intensity > 2.0 then intensity = 2.0 end
    local ac = tonumber(t.addonChance)
    if ac == nil then ac = d.addonChance end
    if ac < 0.0 then ac = 0.0 elseif ac > 1.0 then ac = 1.0 end
    return {
        enabled     = t.enabled and true or false,
        preset      = preset,
        spawnerOn   = t.spawnerOn and true or false,
        intensity   = intensity + 0.0,
        addonChance = ac + 0.0,
    }
end

local function broadcast()
    TriggerClientEvent('hk-scenario:traffic:sync', -1, settings)
end

-- Expose current settings (or defaults) for the editor / other modules.
Scn_getTraffic = function() return settings or defaults() end

-- ── Persistence (shares the hk_scenario_meta k/v table) ─────────────────────
MySQL.ready(function()
    -- table is created by server/population.lua's MySQL.ready as well; the
    -- IF NOT EXISTS makes this idempotent regardless of load order.
    MySQL.query([[
        CREATE TABLE IF NOT EXISTS hk_scenario_meta (
            k VARCHAR(64) PRIMARY KEY,
            v VARCHAR(255) NOT NULL DEFAULT ''
        )
    ]])
    local raw = MySQL.scalar.await('SELECT v FROM hk_scenario_meta WHERE k = ?', { 'traffic' })
    if raw and raw ~= '' then
        local ok, decoded = pcall(json.decode, raw)
        if ok and type(decoded) == 'table' then
            settings = sanitize(decoded)
            print(('[hk-scenario] loaded traffic settings (enabled=%s preset=%s spawner=%s).')
                :format(tostring(settings.enabled), settings.preset, tostring(settings.spawnerOn)))
        end
    end
    if not settings then settings = defaults() end
    broadcast()   -- push to anyone already connected
end)

-- ── Reads ────────────────────────────────────────────────────────────────────
lib.callback.register('hk-scenario:traffic:get', function(source)
    if not Scn_isAllowed(source) then return nil end
    return settings or defaults()
end)

RegisterNetEvent('hk-scenario:traffic:requestSync', function()
    local src = source
    TriggerClientEvent('hk-scenario:traffic:sync', src, settings or defaults())
end)

AddEventHandler('playerJoining', function()
    local src = source
    TriggerClientEvent('hk-scenario:traffic:sync', src, settings or defaults())
end)

-- ── Writes (admin-gated) ──────────────────────────────────────────────────────
lib.callback.register('hk-scenario:traffic:save', function(source, t)
    if not Scn_isAllowed(source) then return false end
    local s = sanitize(t)
    if not s then return false end
    settings = s
    MySQL.update.await([[
        INSERT INTO hk_scenario_meta (k, v) VALUES ('traffic', ?)
        ON DUPLICATE KEY UPDATE v = VALUES(v)
    ]], { json.encode(s) })
    Scn_audit(source, 'setTraffic', json.encode(s))
    broadcast()
    return true
end)

-- Reset to config defaults (enabled=false => system idles on every client).
lib.callback.register('hk-scenario:traffic:clear', function(source)
    if not Scn_isAllowed(source) then return false end
    settings = defaults()
    MySQL.update.await('DELETE FROM hk_scenario_meta WHERE k = ?', { 'traffic' })
    Scn_audit(source, 'clearTraffic', '')
    broadcast()
    return true
end)

-- ══════════════════════════════════════════════════════════════════════════
-- BIOME OVERRIDES — persisted per-zone tuning set live via /settraffic.
--   Stored as ONE json blob { ZONE = {speedMult=,densityMult=,openRoad=}, ... }
--   in hk_scenario_meta k='traffic_biomes'. Broadcast to all clients on save so
--   /settraffic changes apply server-wide AND survive restarts.
-- ══════════════════════════════════════════════════════════════════════════
local biomeOverrides = {}   -- ZONE(code) -> partial profile

-- sanitize one override entry (bounds-check the numbers, coerce the flag)
local function sanitizeOv(o)
    if type(o) ~= 'table' then return nil end
    local out = {}
    local sm = tonumber(o.speedMult)
    if sm then out.speedMult = math.max(0.1, math.min(5.0, sm)) + 0.0 end
    local dm = tonumber(o.densityMult)
    if dm then out.densityMult = math.max(0.0, math.min(5.0, dm)) + 0.0 end
    if o.openRoad ~= nil then out.openRoad = o.openRoad and true or false end
    if not next(out) then return nil end
    return out
end

local function sanitizeAllOv(t)
    if type(t) ~= 'table' then return {} end
    local out = {}
    for zone, o in pairs(t) do
        if type(zone) == 'string' then
            local s = sanitizeOv(o)
            if s then out[zone:upper()] = s end
        end
    end
    return out
end

local function persistBiomes()
    MySQL.update.await([[
        INSERT INTO hk_scenario_meta (k, v) VALUES ('traffic_biomes', ?)
        ON DUPLICATE KEY UPDATE v = VALUES(v)
    ]], { json.encode(biomeOverrides) })
end

local function broadcastBiomes()
    TriggerClientEvent('hk-scenario:traffic:biomeSync', -1, biomeOverrides)
end

MySQL.ready(function()
    -- widen v so multi-zone blobs fit (original schema was VARCHAR(255)).
    MySQL.query('ALTER TABLE hk_scenario_meta MODIFY v TEXT NOT NULL', {})
    local raw = MySQL.scalar.await('SELECT v FROM hk_scenario_meta WHERE k = ?', { 'traffic_biomes' })
    if raw and raw ~= '' then
        local ok, decoded = pcall(json.decode, raw)
        if ok and type(decoded) == 'table' then
            biomeOverrides = sanitizeAllOv(decoded)
            print(('[hk-scenario] loaded %d biome override(s).')
                :format((function() local n=0 for _ in pairs(biomeOverrides) do n=n+1 end return n end)()))
        end
    end
    broadcastBiomes()
end)

RegisterNetEvent('hk-scenario:traffic:requestBiomes', function()
    TriggerClientEvent('hk-scenario:traffic:biomeSync', source, biomeOverrides)
end)

-- Set/replace ONE zone's override (partial merge on top of existing).
lib.callback.register('hk-scenario:traffic:setBiome', function(source, zone, ov)
    if not Scn_isAllowed(source) then return false end
    if type(zone) ~= 'string' or zone == '' then return false end
    local s = sanitizeOv(ov)
    if not s then return false end
    zone = zone:upper()
    local cur = biomeOverrides[zone] or {}
    for k, v in pairs(s) do cur[k] = v end
    biomeOverrides[zone] = cur
    persistBiomes()
    Scn_audit(source, 'setBiome', zone .. ' ' .. json.encode(cur))
    broadcastBiomes()
    return true
end)

-- Clear one zone ('CODE') or everything ('all'/'').
lib.callback.register('hk-scenario:traffic:clearBiome', function(source, zone)
    if not Scn_isAllowed(source) then return false end
    if type(zone) ~= 'string' or zone == '' or zone:lower() == 'all' then
        biomeOverrides = {}
    else
        biomeOverrides[zone:upper()] = nil
    end
    persistBiomes()
    Scn_audit(source, 'clearBiome', tostring(zone))
    broadcastBiomes()
    return true
end)

-- ══════════════════════════════════════════════════════════════════════════
-- RUNTIME VEHICLE BLACKLIST (v2.4.54 — user: "/trafficblacklist to blacklist the
-- car I'm driving, or a model name I type"). The config T.blacklist is the static
-- baseline; this is a LIVE, admin-editable set on top of it, persisted in
-- hk_scenario_meta k='traffic_blacklist' (a JSON array of lowercased model names)
-- and broadcast to every client, which merges it into its isBlacklisted() check
-- so the spawner + parked-swap stop picking that model immediately — no restart,
-- no config edit. Survives restarts (reloaded on MySQL.ready).
-- ──────────────────────────────────────────────────────────────────────────
local trafficBlacklist = {}   -- [modelLower] = true

local function blacklistList()   -- → sorted array for the client / display
    local out = {}
    for m in pairs(trafficBlacklist) do out[#out + 1] = m end
    table.sort(out)
    return out
end

local function persistBlacklist()
    MySQL.update.await([[
        INSERT INTO hk_scenario_meta (k, v) VALUES ('traffic_blacklist', ?)
        ON DUPLICATE KEY UPDATE v = VALUES(v)
    ]], { json.encode(blacklistList()) })
end

local function broadcastBlacklist()
    TriggerClientEvent('hk-scenario:traffic:blacklistSync', -1, blacklistList())
end

-- normalise a model name: lowercase, trimmed, strip anything but the model chars.
local function cleanModel(name)
    if type(name) ~= 'string' then return nil end
    local m = name:gsub('%s+', ''):lower()
    m = m:gsub('[^%w_]', '')          -- model names are alphanumeric/underscore
    if m == '' then return nil end
    return m
end

MySQL.ready(function()
    local raw = MySQL.scalar.await('SELECT v FROM hk_scenario_meta WHERE k = ?', { 'traffic_blacklist' })
    if raw and raw ~= '' then
        local ok, decoded = pcall(json.decode, raw)
        if ok and type(decoded) == 'table' then
            for _, m in ipairs(decoded) do
                local c = cleanModel(m)
                if c then trafficBlacklist[c] = true end
            end
            print(('[hk-scenario] loaded %d runtime traffic blacklist entr(ies).')
                :format(#blacklistList()))
        end
    end
    broadcastBlacklist()
end)

RegisterNetEvent('hk-scenario:traffic:requestBlacklist', function()
    TriggerClientEvent('hk-scenario:traffic:blacklistSync', source, blacklistList())
end)

-- Add one or more models to the runtime blacklist. `models` is an array of names.
lib.callback.register('hk-scenario:traffic:addBlacklist', function(source, models)
    if not Scn_isAllowed(source) then return false end
    if type(models) ~= 'table' then models = { models } end
    local added = {}
    for _, name in ipairs(models) do
        local c = cleanModel(name)
        if c and not trafficBlacklist[c] then
            trafficBlacklist[c] = true
            added[#added + 1] = c
        end
    end
    if #added == 0 then return false end
    persistBlacklist()
    Scn_audit(source, 'addBlacklist', table.concat(added, ','))
    broadcastBlacklist()
    return added
end)

-- Remove one model ('name') or clear everything ('all'/'').
lib.callback.register('hk-scenario:traffic:removeBlacklist', function(source, name)
    if not Scn_isAllowed(source) then return false end
    if type(name) ~= 'string' or name == '' or name:lower() == 'all' then
        trafficBlacklist = {}
    else
        local c = cleanModel(name)
        if not c then return false end
        trafficBlacklist[c] = nil
    end
    persistBlacklist()
    Scn_audit(source, 'removeBlacklist', tostring(name))
    broadcastBlacklist()
    return true
end)

-- SERVER-AUTHORITATIVE DELETE of a swapped parked car (v2.4.59). A client that
-- created a networked parked-swap vehicle can't reliably delete it once ownership
-- migrates (onesync_forceMigration) or the creator streams out — client-side
-- DeleteVehicle silently no-ops and the car leaks. The server owns every net
-- entity, so the client hands us the netId and we delete it here where it always
-- lands. Not gated by Scn_isAllowed on purpose — this only ever removes OUR OWN
-- marked scenery (the client only sends netIds it created), and gating on admin
-- would leak every non-admin's swaps. We still sanity-check it resolves to a real
-- vehicle before deleting so a bad/stale netId can't nuke an unrelated entity.
RegisterNetEvent('hk-scenario:traffic:deleteNet', function(netId)
    if type(netId) ~= 'number' or netId == 0 then return end
    local ent = NetworkGetEntityFromNetworkId(netId)
    if ent and ent ~= 0 and DoesEntityExist(ent) and GetEntityType(ent) == 2 then  -- 2 = vehicle
        DeleteEntity(ent)
    end
end)

-- ORPHAN PURGE (v2.4.62): before v2.4.62 the CLIENT onResourceStop only tore down
-- the driving fleet, NOT the networked parked-swap cars — so every dev restart this
-- session left swapped cars alive as networked orphans (suspected cause of the 10fps
-- collapse). Server-side we can see EVERY networked vehicle via GetAllVehicles(), so
-- on resource start sweep any car still carrying our replicated `hkscn_parked` bag
-- and delete it. One-shot, runs after a short settle so stream state is populated.
-- Also exposed as a command so an admin can purge on demand without a restart.
-- Sweep every networked vehicle carrying one of OUR replicated markers and delete
-- it server-authoritatively (the server owns every net entity, so DeleteEntity here
-- always lands even after ownership migrated). Two markers:
--   hkscn_parked  — the parked-swap fleet (v2.4.58)
--   hkscn_veh     — the DRIVING NPC fleet (v2.4.73; before this only parked cars
--                   were swept, so a driving car orphaned by a crash/drop leaked).
-- `ownerlessOnly` (v2.4.73): when true, ONLY delete cars whose original owner is
-- gone (NetworkGetEntityOwner == -1) — used by the playerDropped sweep so we clean
-- a dropped player's orphans WITHOUT nuking cars that healthy clients still own. On
-- resource start/restart we pass false (purge everything ours — no client is
-- managing them across a restart boundary).
local function purgeOrphans(ownerlessOnly)
    local nVeh, nPark = 0, 0
    local ok, all = pcall(GetAllVehicles)
    if not ok or type(all) ~= 'table' then return 0, 0 end
    for _, ent in ipairs(all) do
        if DoesEntityExist(ent) and GetEntityType(ent) == 2 then
            local st = Entity(ent).state
            local isPark = st and st.hkscn_parked
            local isVeh  = st and st.hkscn_veh
            if isPark or isVeh then
                local drop = true
                if ownerlessOnly then
                    -- owner index -1 == no current owner (original owner disconnected
                    -- and the engine hasn't handed it to anyone still connected).
                    local owner = NetworkGetEntityOwner(ent)
                    drop = (owner == -1)
                end
                if drop then
                    DeleteEntity(ent)
                    if isPark then nPark = nPark + 1 else nVeh = nVeh + 1 end
                end
            end
        end
    end
    return nVeh, nPark
end

AddEventHandler('onResourceStart', function(res)
    if res ~= GetCurrentResourceName() then return end
    CreateThread(function()
        Wait(8000)   -- let networked entities + statebags settle after boot
        -- restart boundary: no client is managing any of our cars across it, so purge
        -- EVERYTHING ours (driving + parked), not just ownerless — this is the
        -- "restart leaves dead cars in the road" case the user called out.
        local nVeh, nPark = purgeOrphans(false)
        if nVeh + nPark > 0 then
            print(('[hk-scenario] purged %d driving + %d parked orphan car(s) on start')
                :format(nVeh, nPark))
        end
    end)
end)

-- LAYER 2 — DISCONNECT SWEEP (v2.4.73). SetEntityOrphanMode(1) on each car already
-- tells the engine to auto-delete on owner drop; this is the belt-and-suspenders
-- backup for any car that slipped the native (created just before it applied, or a
-- migration race). On a player drop, after a short settle for the engine to release
-- ownership, sweep any of OUR marked cars that are now OWNERLESS (owner == -1) and
-- delete them. ownerlessOnly=true so we never touch cars healthy clients still own.
AddEventHandler('playerDropped', function()
    CreateThread(function()
        Wait(5000)   -- let the engine mark the dropped client's entities ownerless
        local nVeh, nPark = purgeOrphans(true)
        if nVeh + nPark > 0 then
            print(('[hk-scenario] disconnect sweep: removed %d driving + %d parked orphan car(s)')
                :format(nVeh, nPark))
        end
    end)
end)

RegisterCommand('scnpurgeorphans', function(source)
    if source ~= 0 and Scn_isAllowed and not Scn_isAllowed(source) then return end
    local nVeh, nPark = purgeOrphans(false)
    print(('[hk-scenario] scnpurgeorphans: removed %d driving + %d parked orphan car(s)')
        :format(nVeh, nPark))
end, true)

-- LAYER 4 — DRIVERLESS SWEEP (v2.4.74). The gap the first three layers miss:
-- OneSync forceMigration hands a streamed-out creator's car to another nearby
-- player. That player is NOT running our enhanced addonDriveTick, and the driver
-- PED has a smaller relevancy radius than the car — so the ped culls while the car
-- lingers, leaving a driverless NPC car parked in the road (user report: plate
-- 86JH0305 sat empty mid-road). That car is neither ownerless (it has a NEW owner
-- post-migration, so Layer 2's owner==-1 skips it) nor tied to a drop/restart, so
-- Layers 1-3 never fire. The server always sees true occupancy, so periodically
-- delete any hkscn_veh car that has been EMPTY across two consecutive checks — a
-- real NPC car always has its driver ped, so a car empty for ~15s+ is a genuine
-- orphan. Two-strike (emptySeen) design also rides out the spawn race where the
-- car exists a beat before its ped is seated, and the client-side rebuild loop
-- that briefly swaps peds — neither stays empty across two sweeps.
local SWEEP_MS = 15000
local emptySeen = {}   -- [entity] = true if it was already seen empty last sweep

local function vehHasOccupant(ent)
    local d = GetPedInVehicleSeat(ent, -1)   -- driver seat
    if d and d ~= 0 and DoesEntityExist(d) then return true end
    -- guard the front passenger + rear seats too (an NPC car may carry peds)
    for seat = 0, 3 do
        local p = GetPedInVehicleSeat(ent, seat)
        if p and p ~= 0 and DoesEntityExist(p) then return true end
    end
    return false
end

CreateThread(function()
    -- first pass waits out the boot settle so onResourceStart's full purge and the
    -- initial spawn wave don't race this.
    Wait(20000)
    while true do
        local ok, all = pcall(GetAllVehicles)
        if ok and type(all) == 'table' then
            local nextEmpty, removed = {}, 0
            for _, ent in ipairs(all) do
                if DoesEntityExist(ent) and GetEntityType(ent) == 2 then
                    local st = Entity(ent).state
                    if st and st.hkscn_veh then
                        if not vehHasOccupant(ent) then
                            if emptySeen[ent] then
                                DeleteEntity(ent)   -- empty two sweeps running → orphan
                                removed = removed + 1
                            else
                                nextEmpty[ent] = true   -- first strike; watch next sweep
                            end
                        end
                        -- occupied cars: simply not carried into nextEmpty (strike reset)
                    end
                end
            end
            emptySeen = nextEmpty
            if removed > 0 then
                print(('[hk-scenario] driverless sweep: removed %d orphaned NPC car(s)')
                    :format(removed))
            end
        end
        Wait(SWEEP_MS)
    end
end)

-- ══════════════════════════════════════════════════════════════════════════
-- VEHICLE TIER MAP (v2.4.46) — READ STRAIGHT FROM hk-race's DB TABLES.
--   Previously (v2.4.42) the client fetched hk-race's tier via lib.callback
--   at runtime, which was fragile (callback timing / hk-race boot order). Per
--   user: hk-race persists everything to the DB anyway, and for NPC spawning we
--   don't need it fresh — so read the DB directly, server-side, ONCE, and hand
--   the client a finished `model -> 'B'|'A'|'S'` map.
--   Sources (both hk-race owned, homekong DB):
--     hk_race_car_cal   (model, t100, top)  — measured/seeded speed data
--     hk_race_car_tiers (model, tier)        — manual admin overrides (1..3)
--   Tier is computed with hk-race's OWN blend (mirror of RaceConfig.Tiers,
--   shared/config.lua ~220 — KEEP IN SYNC): cut{50,80}, wAccel .6/wTop .4,
--   accel 1.8..8.0s → 100..0, top 150..360km/h → 0..100. Override wins.
-- ══════════════════════════════════════════════════════════════════════════
local tierMap = {}   -- [modelLower] = 'B' | 'A' | 'S'

-- hk-race scoring constants (mirror RaceConfig.Tiers).
local RT_NAMES      = { 'B', 'A', 'S' }
local RT_CUT        = { 50.0, 80.0 }
local RT_WACCEL, RT_WTOP = 0.6, 0.4
local RT_ACCEL_FAST, RT_ACCEL_SLOW = 1.8, 8.0
local RT_TOP_LOW, RT_TOP_HIGH = 150.0, 360.0

local function rtClamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi end return v end
local function rtMap(v, inA, inB, outA, outB)
    if inB == inA then return outA end
    return outA + (outB - outA) * ((v - inA) / (inB - inA))
end
local function rtBlendScore(t100, top)
    local accel = t100 and rtClamp(rtMap(t100, RT_ACCEL_FAST, RT_ACCEL_SLOW, 100.0, 0.0), 0, 100) or nil
    local topS  = top  and rtClamp(rtMap(top,  RT_TOP_LOW,    RT_TOP_HIGH,  0.0, 100.0), 0, 100) or nil
    if accel and topS then return RT_WACCEL * accel + RT_WTOP * topS end
    return accel or topS
end
local function rtScoreToTier(score)
    for i = 1, #RT_CUT do if score < RT_CUT[i] then return i end end
    return #RT_CUT + 1
end

-- Build (or rebuild) tierMap from the DB. Safe if hk-race tables are absent
-- (IF NOT EXISTS guards + empty result) — tierMap just stays sparse and the
-- client falls back to its B/A spread for unknowns.
local function rebuildTierMap()
    local map = {}
    -- 1) measured/seeded cal → computed tier
    local calRows = MySQL.query.await(
        'SELECT model, t100, top FROM hk_race_car_cal WHERE model IS NOT NULL') or {}
    for _, r in ipairs(calRows) do
        local m = tostring(r.model):lower()
        local score = rtBlendScore(tonumber(r.t100), tonumber(r.top))
        if score then map[m] = RT_NAMES[rtScoreToTier(score)] end
    end
    -- 2) manual overrides win (tier is a 1..#names index)
    local ovRows = MySQL.query.await(
        'SELECT model, tier FROM hk_race_car_tiers WHERE model IS NOT NULL') or {}
    for _, r in ipairs(ovRows) do
        local idx = tonumber(r.tier)
        if r.model and idx and RT_NAMES[idx] then
            map[tostring(r.model):lower()] = RT_NAMES[idx]
        end
    end
    tierMap = map
    local n = 0; for _ in pairs(map) do n = n + 1 end
    print(('[hk-scenario] tier map: %d models classified from hk-race DB.'):format(n))
end

local function broadcastTierMap()
    TriggerClientEvent('hk-scenario:traffic:tierMap', -1, tierMap)
end

MySQL.ready(function()
    -- hk-race creates these tables; guard in case it hasn't run yet this boot.
    local ok = pcall(rebuildTierMap)
    if not ok then
        print('[hk-scenario] tier map: hk-race DB tables not ready — will retry.')
        SetTimeout(15000, function() pcall(rebuildTierMap); broadcastTierMap() end)
    end
    broadcastTierMap()
end)

-- client asks on (re)start; also re-read the DB so a live /racecalall over on
-- hk-race is picked up without an hk-scenario restart.
RegisterNetEvent('hk-scenario:traffic:requestTierMap', function()
    local src = source
    TriggerClientEvent('hk-scenario:traffic:tierMap', src, tierMap)
end)

AddEventHandler('playerJoining', function()
    TriggerClientEvent('hk-scenario:traffic:tierMap', source, tierMap)
end)

-- admin: force a re-read from the DB (after a big hk-race recal) + rebroadcast.
lib.callback.register('hk-scenario:traffic:refreshTierMap', function(source)
    if not Scn_isAllowed(source) then return false end
    local ok = pcall(rebuildTierMap)
    if ok then broadcastTierMap() end
    Scn_audit(source, 'refreshTierMap', ok and 'ok' or 'fail')
    return ok
end)
