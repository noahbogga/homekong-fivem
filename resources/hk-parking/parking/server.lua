-- ═══════════════════════════════════════════════════════════ --
--          HK-PARKING — HOMEKONG (based on mh-parking by MaDHouSe79, MIT)           --
-- ═══════════════════════════════════════════════════════════ --
local QBCore = exports['qb-core']:GetCoreObject()  -- used by wreck/dv/impound handlers
-- [plate] = entity handle when spawned (server-side entity from CreateVehicleServerSetter).
-- Stored as handle (not `true`) so the watchdog thread can call DoesEntityExist().
local parkedVehicles = {}
local hasSpawned = false
-- Per-plate spawn data needed for re-spawn if entity gets deleted mid-session.
-- [plate] = { vehicle=model, location={x,y,z,h}, mods=table|nil, citizenid=string }
local parkedSpawnData = {}

-- ── Protected-plate registry via GlobalState ──────────────────────────────
-- GlobalState replicates instantly + reliably to EVERY client (unlike per-entity
-- statebags, which race the clear pass). hk-scenario checks a vehicle's plate
-- against this set and skips clearing it. Keyed by clean UPPER plate.
local protectedPlates = {}
local function publishProtected()
    -- GlobalState only diffs on assignment, so rebuild + assign the whole table.
    local out = {}
    for plate in pairs(protectedPlates) do out[plate] = true end
    GlobalState.hkParkedPlates = out
end
local function protectPlate(plate)
    if not plate then return end
    protectedPlates[tostring(plate):gsub("^%s*(.-)%s*$", "%1"):upper()] = true
    publishProtected()
end

-- Is any player currently seated in this vehicle? (server-side)
-- CRITICAL for the fall-through bug: FreezeEntityPosition on an OCCUPIED vehicle
-- desyncs the seated ped's physics and drops them through the seat + the world
-- LODs out. autoPark can fire on an empty car, then the player sprints back and
-- re-enters during the ~260-440ms cross-VM round-trip, so by the time we freeze
-- here the car is occupied again. Always gate the freeze/park on this.
-- We walk the player list (GetVehiclePedIsIn is reliable server-side) rather than
-- seat natives, which are not all server-safe.
local function isVehicleOccupied(veh)
    if not veh or not DoesEntityExist(veh) then return false end
    for _, pid in ipairs(GetPlayers()) do
        local ped = GetPlayerPed(pid)
        if ped and ped ~= 0 then
            local pv = GetVehiclePedIsIn(ped, false)
            if pv and pv ~= 0 and pv == veh then
                return true
            end
        end
    end
    return false
end
local function unprotectPlate(plate)
    if not plate then return end
    protectedPlates[tostring(plate):gsub("^%s*(.-)%s*$", "%1"):upper()] = nil
    publishProtected()
end

-- Backfill the protected-plate registry from the DB on boot, so EXISTING parked
-- cars are shielded from clear-area immediately — no need for owners to re-park
-- (which would be impossible anyway once a clear zone is deleting them).
CreateThread(function()
    while GetResourceState('oxmysql') ~= 'started' do Wait(200) end
    Wait(500)
    local rows = MySQL.query.await('SELECT plate FROM '..sql.table..' WHERE '..sql.state..' = 3')
    if rows then
        for _, r in ipairs(rows) do
            if r.plate then protectedPlates[tostring(r.plate):gsub("^%s*(.-)%s*$", "%1"):upper()] = true end
        end
    end
    publishProtected()
    print(('[hk-parking] protected %d parked plate(s) from clear-area'):format(#(rows or {})))
end)

local function GiveKeysIfOwnerOnline(plate)
    if not plate then return end
    plate = plate:gsub("^%s*(.-)%s*$", "%1"):upper()
    local ownerCitizenId = nil
    local result = Database.GetVehicleData(plate)
    if not result then return end
    ownerCitizenId = result.citizenid or result.owner
    if not ownerCitizenId then return end
    local players = GetPlayers()
    for _, srcStr in pairs(players) do
        local src = tonumber(srcStr)
        local Player = nil
        if GetResourceState('qb-core') == 'started' or GetResourceState('qbx_core') == 'started' then
            Player = exports['qb-core']:GetPlayer(src) or exports.qbx_core.GetPlayer(src)
        elseif GetResourceState('es_extended') == 'started' then
            Player = exports['es_extended']:getSharedObject().GetPlayerFromId(src)
        end
        if Player then
            local playerId = Player.PlayerData.citizenid or Player.identifier or Player.PlayerData.identifier
            if playerId == ownerCitizenId then GiveKeys(src, plate, false) end
        end
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- vehicleKeys METADATA PRUNE (fixes the unbounded-growth DB/network bloat)
-- ---------------------------------------------------------------------------
-- qb-vehiclekeys persists a { [PLATE]=true } map in players.metadata.vehicleKeys
-- and NEVER removes entries (its RemoveKeys export exists but is called nowhere).
-- Temp/spawned vehicles (rentals, testdrives, job cars, admin spawns) each leave a
-- key behind forever. Worst account hit 2,116 keys / 34 KB, 97% pointing at plates
-- that exist in NO vehicle row. qb-core re-transmits the ENTIRE metadata table on
-- every field write (UpdatePlayerDataField), so a fat blob = a >20 KB reliable
-- event on every hunger/thirst tick → client command backlog → timeout drop.
--
-- Fix: on join, drop any key whose plate is absent from player_vehicles
-- SERVER-WIDE. Keeping the server-wide set (not just this player's cars) preserves
-- legit shared keys — a friend's car is still a real row, just owned by someone
-- else. Only true orphans (deleted/temp plates) are removed. Idempotent + cheap.
-- Lives in hk-parking (not qb-vehiclekeys) so a qb update can't clobber it.
-- ═══════════════════════════════════════════════════════════════════════════
local function PruneVehicleKeys(src)
    src = tonumber(src)
    if not src then return end
    local Player = exports['qb-core']:GetPlayer(src)
    if not Player then return end
    local keys = Player.PlayerData.metadata and Player.PlayerData.metadata["vehicleKeys"]
    if type(keys) ~= 'table' then return end

    -- Count current keys; bail early if trivially small (nothing to gain).
    local held = 0
    for _ in pairs(keys) do held = held + 1 end
    if held == 0 then return end

    -- Server-wide set of real plates (UPPER+trimmed to match key format).
    local rows = MySQL.query.await('SELECT UPPER(TRIM(plate)) AS p FROM '..sql.table) or {}
    local real = {}
    for _, r in ipairs(rows) do if r.p then real[r.p] = true end end
    -- Safety: if the vehicles table read failed/empty, do NOT prune (would nuke
    -- every key on a transient DB hiccup). Only proceed when we actually have data.
    if next(real) == nil then return end

    local pruned = {}
    local removed = 0
    for plate in pairs(keys) do
        local norm = tostring(plate):gsub("^%s*(.-)%s*$", "%1"):upper()
        if real[norm] then
            pruned[plate] = true          -- keep as-is (preserve original casing/key)
        else
            removed = removed + 1
        end
    end

    if removed > 0 then
        Player.Functions.SetMetaData("vehicleKeys", pruned)
        print(('[hk-parking] pruned %d orphan vehicleKeys for %s (%d kept)')
            :format(removed, Player.PlayerData.citizenid or src, held - removed))
    end
end

local function GetVehicleType(hash)
    local vehType = "automobile"
    if SV_Config.Vehicles[hash] and SV_Config.Vehicles[hash].type then vehType = SV_Config.Vehicles[hash].type end
    return vehType
end

local function SpawnVehicles(src)
    if hasSpawned then return end
    if src == nil then src = -1 end
    hasSpawned = true
    parkedVehicles = {}
    local vehicles = Database.GetVehicles()
    if #vehicles >= 1 then
        for _, vehicle in pairs(vehicles) do
            if vehicle.plate and not parkedVehicles[vehicle.plate] then
                -- Guard against bad/NULL rows (a state=3 row whose location was
                -- nulled) — decode safely and SKIP instead of crashing the loop.
                local okL, location = pcall(json.decode, vehicle.location or '')
                local okM, mods = pcall(json.decode, vehicle.mods or 'null')
                if not (okL and type(location) == 'table' and location.x) then
                    print(('[hk-parking] skip spawn %s: bad/empty location'):format(vehicle.plate))
                else
                if not okM then mods = nil end
                DeleteVehicleAtcoords(vector3(location.x, location.y, location.z))
                Wait(100)
                local hash = GetHashKey(vehicle.vehicle)
                local vehType = GetVehicleType(hash)
                local entity = CreateVehicleServerSetter(hash, vehType, location.x, location.y, location.z + 0.07, location.h)
                local tries = 0
                while not DoesEntityExist(entity) and tries < 100 do Wait(10); tries = tries + 1 end
                if not DoesEntityExist(entity) then
                    print(('[hk-parking] skip spawn %s: entity never created'):format(vehicle.plate))
                else
                -- CRITICAL: stamp the DB plate onto the entity. CreateVehicleServerSetter
                -- gives a RANDOM plate otherwise, so the clear-area plate guard (and
                -- key/ownership matching) would never match the registry → despawn.
                SetVehicleNumberPlateText(entity, vehicle.plate)
                -- HOMEKONG: freeze the entity so NPC traffic can't roll/damage/destroy it.
                -- Without this, an unfrozen parked car gets hit by NPCs, blows up or rolls
                -- away, GTA deletes the entity, and hk-parking has no way to re-spawn it
                -- this session (hasSpawned is true) → shows "parked outside" with no car.
                -- SetEntityDistanceCullingRadius(0) prevents OneSync from culling it when
                -- no client is nearby (parked cars in empty areas would vanish otherwise).
                FreezeEntityPosition(entity, true)
                SetEntityDistanceCullingRadius(entity, 0.0)
                -- Store the entity handle (not just `true`) so the watchdog can check it.
                parkedVehicles[vehicle.plate] = entity
                -- Cache spawn data so the watchdog can recreate the entity if it ever dies.
                parkedSpawnData[vehicle.plate] = {
                    vehicle = vehicle.vehicle,
                    location = location,
                    mods = mods,
                    citizenid = vehicle.citizenid,
                    isClamped = vehicle.isClamped,
                    steerangle = vehicle.steerangle,
                }
                local netid = SafeNetId(entity)
                local state = Entity(entity).state
                -- REPLICATED (3rd arg true) so every client sees isParked — hk-scenario's
                -- clear-area guard reads it to skip parked cars.
                state:set('isParked', true, true)
                state:set('citizenid', vehicle.citizenid, true)
                state:set('plate', vehicle.plate, true)
                state:set('isClamped', vehicle.isClamped == 1 and true or false, true)
                state:set('steerangle', tonumber(vehicle.steerangle), true)
                state:set('parkedPos', {x=location.x, y=location.y, z=location.z, h=location.h}, true)
                -- Stash mods in the REPLICATED statebag so ANY client that streams this
                -- car into scope can render its paint/wheels (the syncParked event only
                -- reaches clients in scope AT broadcast time; a player who drives up later
                -- would otherwise see a default-look car). The scan thread reads this.
                if mods then state:set('hkMods', mods, true) end
                protectPlate(vehicle.plate)
                TriggerClientEvent('hk-parking:syncParked', src, tonumber(netid), true, location, mods, tonumber(vehicle.steerangle))
                GiveKeysIfOwnerOnline(vehicle.plate)
                end -- entity created
                end -- valid location
            end -- plate + not already spawned
        end
    end
end

-- WATCHDOG: every 60s check that each parked entity still exists server-side.
-- A frozen entity with distance-culling disabled should never disappear, but:
--   • another script (hk-scenario, qb-adminmenu /dv, etc.) can call DeleteEntity
--   • server crashes / entity limit edge cases
-- If the handle is gone, re-spawn from cached parkedSpawnData so the car stays
-- physically in the world without needing a full server restart.
CreateThread(function()
    while true do
        Wait(60000) -- check every 60 seconds
        if not hasSpawned then goto continue end
        for plate, ent in pairs(parkedVehicles) do
            if not DoesEntityExist(ent) then
                local d = parkedSpawnData[plate]
                if not d then
                    -- No re-spawn data — remove stale entry; car is truly gone.
                    parkedVehicles[plate] = nil
                    goto nextplate
                end
                print(('[hk-parking] watchdog: re-spawning lost entity for %s'):format(plate))
                local hash = GetHashKey(d.vehicle)
                local loc = d.location
                local newEnt = CreateVehicleServerSetter(hash, GetVehicleType(hash), loc.x, loc.y, loc.z + 0.07, loc.h)
                local tries = 0
                while not DoesEntityExist(newEnt) and tries < 100 do Wait(10); tries = tries + 1 end
                if DoesEntityExist(newEnt) then
                    SetVehicleNumberPlateText(newEnt, plate)
                    -- Don't freeze if a player already got into the re-spawned car
                    -- (would drop them through the seat). Culling-off still protects it.
                    if not isVehicleOccupied(newEnt) then
                        FreezeEntityPosition(newEnt, true)
                    end
                    SetEntityDistanceCullingRadius(newEnt, 0.0)
                    parkedVehicles[plate] = newEnt
                    local state = Entity(newEnt).state
                    state:set('isParked', true, true)
                    state:set('citizenid', d.citizenid, true)
                    state:set('plate', plate, true)
                    state:set('isClamped', d.isClamped == 1 and true or false, true)
                    state:set('steerangle', tonumber(d.steerangle), true)
                    state:set('parkedPos', {x=loc.x, y=loc.y, z=loc.z, h=loc.h}, true)
                    if d.mods then state:set('hkMods', d.mods, true) end
                    local netid = SafeNetId(newEnt)
                    if netid then
                        TriggerClientEvent('hk-parking:syncParked', -1, tonumber(netid), true, loc, d.mods, tonumber(d.steerangle))
                    end
                else
                    print(('[hk-parking] watchdog: re-spawn failed for %s'):format(plate))
                    parkedVehicles[plate] = nil
                    parkedSpawnData[plate] = nil
                end
                ::nextplate::
            end
        end
        ::continue::
    end
end)

CreateCallback("hk-parking:server:GetVehicles", function(source, cb)
    local result = Database.GetPlayerVehicles(source)
    -- GetPlayerVehicles returns false if the caller isn't loaded → return empty
    -- (was indexing result.state on a boolean/list → crash).
    if type(result) ~= 'table' then cb({ status = false, data = {} }) return end
    cb({ status = true, data = result })
end)

-- Spawn all parked cars ONCE, on resource start — independent of player count.
-- (The old `#players == 1` gate meant a restart with 2+ players online left every
-- parked car un-spawned until the server drained to a single player.)
AddEventHandler('onResourceStart', function(res)
    if res ~= GetCurrentResourceName() then return end
    CreateThread(function()
        while GetResourceState('oxmysql') ~= 'started' do Wait(200) end
        Wait(1500)               -- let the DB + framework settle
        if not hasSpawned then SpawnVehicles() end
    end)
end)

RegisterNetEvent('hk-parking:onjoin', function()
    local src = source
    -- Fallback: if boot spawn hasn't run yet (fresh server, first joiner before
    -- onResourceStart finished), do it now. hasSpawned guards against dupes.
    if not hasSpawned then SpawnVehicles(src) end
    Wait(500)
    -- Prune orphaned vehicleKeys BEFORE re-granting owned ones, so the blob is
    -- clean and the owned-key re-add lands on the trimmed table (one write, no
    -- churn). Self-heals every player's accumulated bloat on their next join.
    PruneVehicleKeys(src)
    local citizenid = GetIdentifier(src)
    local vehicles = Database.GetVehiclesForCitizenid(citizenid)
    if #vehicles >= 1 then for _, vehicle in pairs(vehicles) do  GiveKeysIfOwnerOnline(vehicle.plate) end end
    Wait(1000)
    TriggerClientEvent('hk-parking:onjoin', src, {status = true}) -- config removed: SV_Config already loaded client-side via shared_scripts
end)

RegisterNetEvent('hk-parking:autoUnpark', function(netId)
    local src = source
    if not netId or netId <= 0 then return end
    local veh = NetworkGetEntityFromNetworkId(netId)
    if not veh or not DoesEntityExist(veh) or not NetworkGetEntityOwner(veh) then return end
    local plate = GetVehicleNumberPlateText(veh):gsub("^%s*(.-)%s*$", "%1"):upper()
    -- Silently ignore non-owned vehicles (no notify spam for taxis/others' cars).
    if not Database.IsVehicleOwned(src, plate) then return end
    local state = Entity(veh).state
    if state.isClamped == true then return end
    if state.isParked then
        Database.UnparkVehicle(plate)
        unprotectPlate(plate)
        -- Unfreeze — the car was frozen while parked so NPCs couldn't damage it.
        FreezeEntityPosition(veh, false)
        -- Remove from watchdog tracking; car is now the player's again.
        parkedVehicles[plate] = nil
        parkedSpawnData[plate] = nil
        state:set('isParked', false, true)
        state:set('parkedPos', nil, true)
        local data = Database.GetVehicleData(plate)
        if data ~= nil and data.mods ~= nil then
            local mods = json.decode(data.mods)
            TriggerClientEvent('hk-parking:syncParked', -1, netId, false, nil, mods)
            TriggerClientEvent('ox_lib:notify', src, { title = 'HK Parking', description = Lang:t('vehicle.unparked'), type = 'success' })
        end
    end
end)

RegisterNetEvent('hk-parking:autoPark', function(netId, steerangle, street, liveMods)
    local src = source
    if not netId or netId <= 0 then return end
    local veh = NetworkGetEntityFromNetworkId(netId)
    if not veh or not DoesEntityExist(veh) or not NetworkGetEntityOwner(veh) then return end
    local plate = GetVehicleNumberPlateText(veh):gsub("^%s*(.-)%s*$", "%1"):upper()
    -- Silently ignore non-owned vehicles (no "not yours" spam every time you
    -- step out of a taxi / someone else's car). No VIP, no limit — HOMEKONG
    -- street parking just keeps your owned car in the world.
    if not Database.IsVehicleOwned(src, plate) then return end
    -- FALL-THROUGH GUARD: refuse to park a car someone is sitting in. This event
    -- can arrive stale — the client fired it when the car was empty, but the player
    -- has since re-entered during the round-trip. Freezing now would drop the ped
    -- through the seat. Abort cleanly; the on-foot scan re-fires autoPark when they
    -- genuinely leave, so nothing is lost.
    if isVehicleOccupied(veh) then return end
    -- TOW GUARD: refuse to park a car that's attached to a tow truck (any attachment).
    -- Parking freezes it + registers a watchdog respawn, which fights the tow and can
    -- yank/despawn the car mid-haul. The on-foot scan re-fires autoPark once it's
    -- dropped off and detached, so nothing is lost.
    if GetEntityAttachedTo(veh) ~= 0 then return end
    local coords = GetEntityCoords(veh)
    local heading = GetEntityHeading(veh)
    local state = Entity(veh).state
    if not state.isParked then
        Database.ParkVehicle(plate, {x=coords.x, y=coords.y, z=coords.z, h=heading}, steerangle, street)
        -- LIVE MODS: the client captured the vehicle's actual properties the instant it
        -- parked. Persist them FIRST so the GetVehicleData read below (and every other
        -- client) sees a just-applied mechanic upgrade even if the mechanic's own 5s
        -- deferred save hasn't landed yet. Validate it's real JSON before writing so a
        -- malformed payload can't nuke the mods column.
        if liveMods and liveMods ~= '' then
            local okLM = pcall(json.decode, liveMods)
            if okLM then Database.SaveMods(plate, liveMods) end
        end
        local parkedPos = {x=coords.x, y=coords.y, z=coords.z, h=heading}
        protectPlate(plate)
        -- Freeze the car so NPC traffic can't damage/destroy it while parked.
        -- Also register with watchdog so it gets re-spawned if anything deletes it.
        FreezeEntityPosition(veh, true)
        parkedVehicles[plate] = veh
        state:set('isParked', true, true)          -- replicated for hk-scenario guard
        state:set('parkedPos', parkedPos, true)
        state:set('steerangle', tonumber(steerangle), true)
        local data = Database.GetVehicleData(plate)
        if data ~= nil then
            -- Register with watchdog so it can re-spawn this car if it dies mid-session.
            local mods = data.mods and json.decode(data.mods) or nil
            parkedSpawnData[plate] = {
                vehicle = data.vehicle,
                location = parkedPos,
                mods = mods,
                citizenid = data.citizenid,
                isClamped = data.isClamped,
                steerangle = steerangle,
            }
            if mods then
            state:set('hkMods', mods, true)   -- replicated: late-streaming clients can render it
            -- Broadcast the parked-sync to EVERYONE EXCEPT the driver who just parked.
            -- Their client already renders the real car; re-applying mods to it the moment
            -- they step out (control migrating away) reset it to default = "mods gone after
            -- parking". Other clients still get it so they see the correct look. The parker's
            -- own client just marks it parked below (state flags already replicated).
            for _, tgt in ipairs(GetPlayers()) do
                local t = tonumber(tgt)
                if t and t ~= src then
                    TriggerClientEvent('hk-parking:syncParked', t, netId, true, parkedPos, mods)
                end
            end
            end -- mods
        end
        TriggerClientEvent('ox_lib:notify', src, { title = 'HK Parking', description = Lang:t('vehicle.parked'), type = 'success' })
    end
end)

RegisterNetEvent('hk-parking:server:AllPlayersLeaveVehicle', function(vehicleNetID, players)
    if players ~= nil and #players >= 1 then
        local vehicle = NetworkGetEntityFromNetworkId(vehicleNetID)
        if DoesEntityExist(vehicle) then
            for i = 1, #players, 1 do
                TriggerClientEvent('hk-parking:client:leaveVehicle', players[i].playerId, {vehicleNetID = vehicleNetID, playerId = players[i].playerId})
            end
        end
    end
end)

RegisterNetEvent('hk-parking:server:toggleClamp', function(netid, state)
    local src = source
    -- POLICE ONLY — else any client could clamp/unclamp any vehicle by netId.
    local Player = QBCore.Functions.GetPlayer(src)
    local job = Player and Player.PlayerData.job and Player.PlayerData.job.name
    local allowed = false
    for _, j in ipairs(SV_Config.PoliceJobs or {}) do if j == job then allowed = true break end end
    if not allowed then return end
    if not netid or netid <= 0 then return end
    local veh = NetworkGetEntityFromNetworkId(netid)
    if DoesEntityExist(veh) and Entity(veh).state then
        local plate = GetVehicleNumberPlateText(veh):gsub("^%s*(.-)%s*$", "%1"):upper()
        if state then
            Entity(veh).state:set('isClamped', true, true)
            if Database.UpdateWheelClamp then Database.UpdateWheelClamp(plate, 1) end  -- persist
            TriggerClientEvent('ox_lib:notify', src, { title = 'HK Parking', description = Lang:t('info.wheel_clamp_added', {fine = SV_Config.ClampFine}), type = 'success' })
        else
            Entity(veh).state:set('isClamped', false, true)
            if Database.UpdateWheelClamp then Database.UpdateWheelClamp(plate, 0) end
            TriggerClientEvent('ox_lib:notify', src, { title = 'HK Parking', description = Lang:t('info.wheel_clamp_deleted'), type = 'success' })
        end
        Wait(100)
        TriggerClientEvent('hk-parking:syncWheelClamp', -1, netid)
    end
end)

-- When another script impounds a plate, clear its parked state + entity so it
-- doesn't respawn on next restart. Works with the server-side statebag model.
-- Despawn a parked car's world entity + clear its location, WITHOUT changing its
-- DB state (caller decides state: impound sets 2, wreck sets 2, etc.). Used by
-- police/mechanic impound and wreck-to-impound so the wreck/car leaves the world.
local function DespawnParked(plate)
    if not plate then return end
    plate = tostring(plate):gsub("^%s*(.-)%s*$", "%1"):upper()
    -- Use the stored entity handle — avoids iterating ALL world vehicles on every
    -- impound/wreck/dv call. Fall back to plate-scan if the handle is stale/gone.
    local knownEnt = parkedVehicles[plate]
    parkedVehicles[plate] = nil
    parkedSpawnData[plate] = nil
    unprotectPlate(plate)
    MySQL.update('UPDATE '..sql.table..' SET location = NULL, street = NULL WHERE plate = ?', { plate })
    if knownEnt and DoesEntityExist(knownEnt) then
        local netId = SafeNetId(knownEnt)
        if netId then TriggerClientEvent('hk-parking:syncParked', -1, netId, false, nil, nil) end
        DeleteEntity(knownEnt)
    else
        -- Fallback: scan by plate text (handles cases where entity was spawned before
        -- this session's parkedVehicles table was populated, e.g. resource hot-restart).
        for _, veh in ipairs(GetAllVehicles()) do
            if DoesEntityExist(veh) then
                local vp = GetVehicleNumberPlateText(veh):gsub("^%s*(.-)%s*$", "%1"):upper()
                if vp == plate then
                    local netId = SafeNetId(veh)
                    if netId then TriggerClientEvent('hk-parking:syncParked', -1, netId, false, nil, nil) end
                    DeleteEntity(veh)
                    break
                end
            end
        end
    end
end

-- SERVER-LOCAL only (AddEventHandler, NOT RegisterNetEvent) — triggered by
-- mechanic.lua via TriggerEvent. Clients cannot invoke it (was net-exposed =
-- any client could despawn any plate).
AddEventHandler('hk-parking:server:onImpound', function(plate)
    DespawnParked(plate)
end)

-- Wrecked parked car → impound (state 2). Flat retrieval price; no towedby (not
-- a mechanic tow, so no cut). Owner retrieves from an impound lot.
RegisterNetEvent('hk-parking:server:wreckToImpound', function(plate)
    local src = source
    if not plate then return end
    plate = tostring(plate):gsub("^%s*(.-)%s*$", "%1"):upper()
    -- Any owned player vehicle NOT already impounded (state 0 out / 3 parked).
    -- Must belong to the reporting player (anti-abuse). Ignore if already 2/4.
    local Player = QBCore.Functions.GetPlayer(src)
    local citizenid = Player and Player.PlayerData.citizenid
    if not citizenid then return end
    local row = MySQL.single.await(
        'SELECT '..sql.state..' AS st FROM '..sql.table..' WHERE plate = ? AND '..sql.citizenid..' = ? LIMIT 1',
        { plate, citizenid })
    if not row then return end
    if row.st == 2 or row.st == 4 then return end   -- already impounded
    -- Wrecked (parked OR driving) → MECHANIC DEPOT pool (state 4), no towedby (no cut).
    MySQL.update('UPDATE '..sql.table..' SET '..sql.state..' = 4, depotprice = ? WHERE plate = ?', { SV_Config.ImpoundPrice, plate })
    DespawnParked(plate)   -- clears any street-spawn entity; harmless if none
    TriggerEvent('hk-garage:server:UpdateOutsideVehicle', plate, nil)  -- clear stale out-tracking
end)

-- /dv (admin delete) → if the deleted car is an OWNED player vehicle (ANY owner,
-- not just the admin's), send it to the mechanic depot so the owner can recover
-- it. Non-owned/NPC/dupe cars aren't in player_vehicles → nothing happens here
-- (qb-core's /dv handler just deletes the entity). No mechanic cut.
RegisterNetEvent('hk-parking:server:dvToDepot', function(plate)
    local src = source
    -- /dv is an ADMIN command — only accept from players with admin/command ACE,
    -- else any client could depot any plate (grief). Matches qb-core /dv perms.
    if not (IsPlayerAceAllowed(src, 'command') or IsPlayerAceAllowed(src, 'admin')) then return end
    if not plate then return end
    plate = tostring(plate):gsub("^%s*(.-)%s*$", "%1"):upper()
    local row = MySQL.single.await('SELECT '..sql.state..' AS st FROM '..sql.table..' WHERE plate = ? LIMIT 1', { plate })
    if not row then return end                       -- not a player vehicle → ignore
    if row.st == 2 or row.st == 4 then return end    -- already impounded
    MySQL.update('UPDATE '..sql.table..' SET '..sql.state..' = 4, depotprice = ? WHERE plate = ?', { SV_Config.ImpoundPrice, plate })
    DespawnParked(plate)
    TriggerEvent('hk-garage:server:UpdateOutsideVehicle', plate, nil)  -- clear stale out-tracking
end)

-- DISCONNECT-WHILE-DRIVING → depot. The client reports the plate it's currently
-- driving (hk-parking:driving); on drop we send that owned car to the mechanic depot
-- (state 4) so it doesn't go stale at state 0 with no world entity after a restart.
-- Matches the /dv + wreck behaviour (owner pays to retrieve at a depot).
local drivingPlate = {}   -- [src] = { plate, cid } currently being driven
RegisterNetEvent('hk-parking:driving', function(plate)
    local src = source
    if plate == nil or plate == false then drivingPlate[src] = nil; return end
    -- Capture the citizenid NOW (player is present); on playerDropped the player
    -- object may already be gone, so we can't look it up there.
    local cid = GetIdentifier(src)
    if not cid then return end
    drivingPlate[src] = { plate = tostring(plate):gsub("^%s*(.-)%s*$", "%1"):upper(), cid = cid }
end)

AddEventHandler('playerDropped', function()
    local src = source
    local info = drivingPlate[src]
    drivingPlate[src] = nil
    if not info or not info.plate then return end
    -- Only depot a car the dropped player OWNS that's currently OUT (state 0).
    -- Parked (3) / garaged (1) / already-impounded (2/4) are left alone.
    local row = MySQL.single.await(
        'SELECT '..sql.state..' AS st FROM '..sql.table..' WHERE plate = ? AND '..sql.citizenid..' = ? LIMIT 1',
        { info.plate, info.cid })
    if not row or row.st ~= 0 then return end
    MySQL.update('UPDATE '..sql.table..' SET '..sql.state..' = 4, depotprice = ? WHERE plate = ?', { SV_Config.ImpoundPrice, info.plate })
    DespawnParked(info.plate)
    TriggerEvent('hk-garage:server:UpdateOutsideVehicle', info.plate, nil)  -- clear stale out-tracking
end)