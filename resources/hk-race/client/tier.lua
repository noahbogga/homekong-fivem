-- hk-race :: client/tier.lua
-- Classify the vehicle a player is driving into a performance tier (1..4).
-- Primary signal: real measured data from hk-handling SpeedCalData (0-100 + top
-- speed). Fallback: native GetVehicleEstimatedMaxSpeed + handling flat velocity.
-- A gearbox-class nudge (hk-handling manualType) breaks ties near boundaries.

RaceTier = {}

-- Per-car tier overrides (hash -> tier), synced from the server.
local overrides = {}
RegisterNetEvent('hk-race:tier:syncOverrides', function(map) overrides = map or {} end)
CreateThread(function()
    Wait(1500)   -- let ox_lib/callbacks come up
    local map = lib.callback.await('hk-race:tier:getOverrides', false)
    if type(map) == 'table' then overrides = map end
end)

-- Merged cal map (hash -> { t100, top }), built server-side from the hk-race seed
-- (shared/vehicledata.lua), DB speedCal parse, and learned live captures. Owned by
-- hk-race — independent of hk-handling. Keys may arrive as strings from JSON.
local calMap = {}
CreateThread(function()
    Wait(1500)
    local map = lib.callback.await('hk-race:tier:getCalMap', false)
    if type(map) == 'table' then calMap = map end
end)
-- Live refresh when a capture or /racecalall updates the map.
RegisterNetEvent('hk-race:tier:syncCalMap', function(map)
    if type(map) == 'table' then calMap = map end
end)
local function calFor(hash)
    return calMap[hash] or calMap[tostring(hash)]
end
local function dbT100(hash)
    local c = calFor(hash); return c and c.t100
end
local function calTop(hash)
    local c = calFor(hash); return c and c.top
end

local function clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi end return v end
local function map(v, inA, inB, outA, outB)
    if inB == inA then return outA end
    return outA + (outB - outA) * ((v - inA) / (inB - inA))
end

-- spawn-code (model name) for a vehicle, lowercased — the SpeedCalData key.
local function modelName(veh)
    local name = GetDisplayNameFromVehicleModel(GetEntityModel(veh))
    if not name or name == '' or name == 'NULL' then return nil end
    return tostring(name):lower()
end

-- Blend a 0-100 time (s) + top speed (km/h) into a 0-100 score.
local function blendScore(t100, topKmh)
    local T = RaceConfig.Tiers
    local accel = t100 and clamp(map(t100, T.accelFast, T.accelSlow, 100.0, 0.0), 0, 100) or nil
    local top   = topKmh and clamp(map(topKmh, T.topLow, T.topHigh, 0.0, 100.0), 0, 100) or nil
    if accel and top then
        return T.weightAccel * accel + T.weightTop * top
    end
    return accel or top   -- whichever we have
end

-- score → tier index (1..#names). Generic over any number of cut points.
local function scoreToTier(score)
    local cut = RaceConfig.Tiers.cut
    for i = 1, #cut do
        if score < cut[i] then return i end
    end
    return #cut + 1
end

-- Coarse gearbox signal for the boundary nudge. hk-handling's client
-- GetGearboxMode(veh) returns "manual"/"auto"/nil and only for the LOCAL current
-- vehicle — good enough as a tiebreaker: a manual/paddle car near a boundary leans
-- sportier (nudge up), an automatic leans softer (nudge down).
local function gearboxMode(veh)
    if GetResourceState('hk-handling') ~= 'started' then return nil end
    local ok, mode = pcall(function() return exports['hk-handling']:GetGearboxMode(veh) end)
    if ok and type(mode) == 'string' then return mode end
    return nil
end

-- If score sits just BELOW a cut, a manual/paddle car bumps up into the next tier.
-- If score sits just ABOVE a cut, an automatic car bumps down.
local function applyNudge(score, tier, veh)
    local T = RaceConfig.Tiers
    if not T.gearboxNudge then return tier end
    local mode = gearboxMode(veh)
    if not mode then return tier end
    local maxTier = #T.names
    for _, c in ipairs(T.cut) do
        if mode == 'manual' and tier < maxTier and score >= c - T.nudgeBand and score < c then
            return tier + 1
        elseif mode == 'auto' and tier > 1 and score >= c and score <= c + T.nudgeBand then
            return tier - 1
        end
    end
    return tier
end

-- Native fallback when there's no SpeedCalData row.
local function nativeScore(veh)
    local estMs = GetVehicleEstimatedMaxSpeed(veh) or 0.0        -- m/s, includes mods
    local topKmh = estMs * 3.6
    if topKmh <= 0 then
        local flat = GetVehicleHandlingFloat(veh, 'CHandlingData', 'fInitialDriveMaxFlatVel') or 0.0
        topKmh = flat * 0.82 * 1.60934   -- flatVel(mph basis)→km/h, matches hk-speedo approach
    end
    if topKmh <= 0 then return nil end
    -- No reliable accel from native alone; score from top speed only.
    return blendScore(nil, topKmh), topKmh
end

--- Classify a vehicle. Returns { tier, name, score, source, top, t100 } or nil.
function RaceTier.classify(veh)
    if not veh or veh == 0 or not DoesEntityExist(veh) then return nil end

    -- 0) Manual override wins outright (admin reclassification).
    local hash = GetEntityModel(veh) & 0xFFFFFFFF
    local ov = overrides[hash] or overrides[tostring(hash)]  -- keys may arrive as strings
    if ov and RaceConfig.Tiers.names[ov] then
        return { tier = ov, name = RaceConfig.Tiers.names[ov], score = -1, source = 'override' }
    end

    local score, source, top, t100

    -- 1) hk-race's OWN merged cal map (seed + DB speedCal + learned live captures).
    --    This is the primary source now — independent of hk-handling. When top is
    --    missing (accel-only seed/DB row), pair it with the native top estimate so
    --    the blend is complete for the live vehicle.
    local cal = calFor(hash)
    if cal and (cal.t100 or cal.top) then
        t100 = cal.t100
        top = cal.top
        if t100 and not top then
            local _, ntop = nativeScore(veh)
            top = ntop
        end
        score = blendScore(t100, top)
        source = cal.top and 'cal' or 'dbcal'
    end

    -- 1b) Optional last-ditch: hk-handling's export, ONLY if we still have nothing
    --     (kept for transition / belt-and-braces; safe if hk-handling is absent).
    if not score and GetResourceState('hk-handling') == 'started' then
        local ok, row = pcall(function() return exports['hk-handling']:getSpeedCal(hash) end)
        if ok and type(row) == 'table' then
            t100, top = row.t100, row.top
            score = blendScore(t100, top)
            source = 'hkcal'
        end
    end

    -- 2) Native fallback (top-speed estimate off the live entity).
    if not score then
        local ns, ntop = nativeScore(veh)
        if ns then score = ns; top = ntop; source = 'native' end
    end

    -- 3) Nothing at all → configured fallback tier.
    if not score then
        local ft = RaceConfig.Tiers.fallbackTier or 2
        return { tier = ft, name = RaceConfig.Tiers.names[ft], score = -1, source = 'none' }
    end

    local tier = applyNudge(score, scoreToTier(score), veh)
    return {
        tier = tier, name = RaceConfig.Tiers.names[tier],
        score = math.floor(score + 0.5), source = source, top = top, t100 = t100,
    }
end

-- Reproduce the gearbox nudge WITHOUT a spawned entity, using the DB's public
-- manualType (0 auto | 1 manual | 2 basic-DCT | 3 supercar | 4 F1 | 5 sequential |
-- 6 GTA-native). Live GetGearboxMode() collapses these to "manual"/"auto"; a DCT
-- (2/3/4/5) defaults to its auto sub-mode on spawn, so it reads "auto" here.
local function nudgeFromManualType(mt)
    if mt == 1 or mt == 5 then return 'manual' end   -- clutch manual / sequential dogbox
    if mt == 0 or mt == 2 or mt == 3 or mt == 4 then return 'auto' end   -- our-auto + DCTs (default sub-mode)
    return nil                                        -- 6 = raw GTA native → no signal
end

local function applyNudgeMode(score, tier, mode)
    local T = RaceConfig.Tiers
    if not T.gearboxNudge or not mode then return tier end
    local maxTier = #T.names
    for _, c in ipairs(T.cut) do
        if mode == 'manual' and tier < maxTier and score >= c - T.nudgeBand and score < c then
            return tier + 1
        elseif mode == 'auto' and tier > 1 and score >= c and score <= c + T.nudgeBand then
            return tier - 1
        end
    end
    return tier
end

--- Classify from a raw model hash (no spawned vehicle) — for the admin car list.
--- `manualType` = public gearbox type (boundary nudge). `dbT100Opt`/`dbTopOpt` come
--- from the getCarTiers payload (the server's merged cal), so the admin list shows a
--- real auto-tier for every car that has ANY data. Returns nil only when truly none.
function RaceTier.classifyByHash(hash, manualType, dbT100Opt, dbTopOpt)
    hash = math.floor(tonumber(hash) or 0) & 0xFFFFFFFF
    if hash == 0 then return nil end

    local score, source
    -- Primary: merged cal from the payload (or the synced map as a fallback).
    local cal = calFor(hash)
    local t100 = tonumber(dbT100Opt) or (cal and cal.t100)
    local top  = tonumber(dbTopOpt)  or (cal and cal.top)
    if t100 or top then
        score = blendScore(t100, top)
        source = top and 'cal' or 'dbcal'
    end

    -- Last-ditch: hk-handling export (transition safety).
    if not score and GetResourceState('hk-handling') == 'started' then
        local ok, row = pcall(function() return exports['hk-handling']:getSpeedCal(hash) end)
        if ok and type(row) == 'table' then
            score = blendScore(row.t100, row.top)
            source = 'hkcal'
        end
    end

    -- No data anywhere (no seed, no DB speedCal, no learned pull, no hk-handling
    -- row). We can't spawn the car to read GetVehicleEstimatedMaxSpeed from a hash,
    -- so fall back to the configured default tier instead of returning nil — that
    -- kept these cars blank on the /raceadmin page. They'll self-correct to a real
    -- tier once someone drives one (auto-cal) or an admin sets an override.
    if not score then
        local ft = RaceConfig.Tiers.fallbackTier or 2
        return {
            tier = ft, name = RaceConfig.Tiers.names[ft],
            score = -1, source = 'none',
        }
    end
    local tier = applyNudgeMode(score, scoreToTier(score), nudgeFromManualType(tonumber(manualType)))
    return {
        tier = tier, name = RaceConfig.Tiers.names[tier],
        score = math.floor(score + 0.5), source = source,
    }
end

-- Tier of the vehicle the player is currently in (or nil if on foot).
function RaceTier.current()
    local ped = PlayerPedId()
    if not IsPedInAnyVehicle(ped, false) then return nil end
    local veh = GetVehiclePedIsIn(ped, false)
    return RaceTier.classify(veh)
end

exports('getVehicleTier', function(veh) return RaceTier.classify(veh) end)
exports('getCurrentTier', function() return RaceTier.current() end)

-- Debug: /mytier prints how the current vehicle was classified.
RegisterCommand('mytier', function()
    local t = RaceTier.current()
    if not t then RaceUtil.notify('On foot — enter a vehicle.', 'inform'); return end
    RaceUtil.notify(('Class %s · score %s · via %s · t100=%s top=%s')
        :format(tostring(t.name), tostring(t.score), tostring(t.source),
                tostring(t.t100 or '?'), tostring(t.top or '?')), 'inform')
end, false)

-- Admin quick-set: sit in the car, /setcartier <1..N>. /clearcartier reverts to auto.
local function currentVehForTier()
    local ped = PlayerPedId()
    if not IsPedInAnyVehicle(ped, false) then return nil end
    return GetVehiclePedIsIn(ped, false)
end

RegisterCommand('setcartier', function(_, args)
    local veh = currentVehForTier()
    if not veh then RaceUtil.notify('Get in the vehicle first.', 'error'); return end
    local tier = tonumber(args[1])
    if not tier or tier < 1 or tier > #RaceConfig.Tiers.names then
        RaceUtil.notify(('Usage: /setcartier 1-%d'):format(#RaceConfig.Tiers.names), 'error'); return
    end
    local hash = GetEntityModel(veh) & 0xFFFFFFFF
    local model = modelName(veh) or ''
    local dispName = GetLabelText(GetDisplayNameFromVehicleModel(GetEntityModel(veh)))
    lib.callback('hk-race:admin:setCarTier', false, function(res)
        if res and res.ok then
            RaceUtil.notify(('Set %s → Tier %d (%s)'):format(model, tier, RaceConfig.Tiers.names[tier]), 'success')
        else
            RaceUtil.notify('Failed: ' .. tostring(res and res.error or '?'), 'error')
        end
    end, hash, tier, model, dispName)
end, false)

RegisterCommand('clearcartier', function()
    local veh = currentVehForTier()
    if not veh then RaceUtil.notify('Get in the vehicle first.', 'error'); return end
    local hash = GetEntityModel(veh) & 0xFFFFFFFF
    lib.callback('hk-race:admin:setCarTier', false, function(res)
        if res and res.ok then
            RaceUtil.notify('Cleared override — back to auto tier.', 'success')
        else
            RaceUtil.notify('Failed: ' .. tostring(res and res.error or '?'), 'error')
        end
    end, hash, 0)   -- tier 0 = clear
end, false)
