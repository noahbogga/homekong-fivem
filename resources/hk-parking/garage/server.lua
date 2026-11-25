local QBCore = exports['qb-core']:GetCoreObject()
local OutsideVehicles = {}

-- Handler

-- HOMEKONG: removed the legacy AutoRespawn/depot-on-start block. Cars only reach
-- depot/impound (state=2) via police impound or mechanic tow — never on restart.
-- Street-parked cars (state=3) are respawned in-world by the parking half.

-- Functions

local vehicleClasses = {
    compacts = 0,
    sedans = 1,
    suvs = 2,
    coupes = 3,
    muscle = 4,
    sportsclassics = 5,
    sports = 6,
    super = 7,
    motorcycles = 8,
    offroad = 9,
    industrial = 10,
    utility = 11,
    vans = 12,
    cycles = 13,
    boats = 14,
    helicopters = 15,
    planes = 16,
    service = 17,
    emergency = 18,
    military = 19,
    commercial = 20,
    trains = 21,
    openwheel = 22,
}

local function arrayToSet(array)
    local set = {}
    for _, item in ipairs(array) do
        set[item] = true
    end
    return set
end

local function filterVehiclesByCategory(vehicles, category)
    local filtered = {}
    local categorySet = arrayToSet(category)

    for _, vehicle in pairs(vehicles) do
        -- Only class-restrict the cars you'd actually TAKE OUT here (section 'here').
        -- Impound / depot / street / other-garage cars are locate/retrieve only and
        -- class-agnostic — never hide them (was making them vanish from the menu).
        if vehicle.hk_section and vehicle.hk_section ~= 'here' then
            filtered[#filtered + 1] = vehicle
        else
            local vehicleData = QBCore.Shared.Vehicles[vehicle.vehicle]
            local vehicleCategoryString = vehicleData and vehicleData.category or 'compacts'
            local vehicleCategoryNumber = vehicleClasses[vehicleCategoryString]
            if vehicleCategoryNumber and categorySet[vehicleCategoryNumber] then
                filtered[#filtered + 1] = vehicle
            end
        end
    end

    return filtered
end

-- Callbacks

QBCore.Functions.CreateCallback('hk-garage:server:getHouseGarage', function(_, cb, house)
    local houseInfo = MySQL.single.await('SELECT * FROM houselocations WHERE name = ?', { house })
    cb(houseInfo)
end)

-- ── Search metadata helpers (derivable WITHOUT spawning the car) ──────────
-- NOTE: tier is NOT computed server-side — hk-race's real classifier needs a
-- spawned entity (native top-speed fallback). It's classified client-side on the
-- previewed car via exports['hk-race']:getVehicleTier and sent with PreviewMods.

-- Primary/secondary colour name from the stored mods JSON (paint indices).
local PAINT_NAMES = {
    [0]='Black',[1]='Graphite',[3]='Silver',[4]='Silver',[5]='Chrome',[11]='Dark Red',
    [12]='Red',[27]='Pink',[38]='Orange',[46]='Purple',[49]='Dark Green',[52]='Green',
    [53]='Green',[64]='Dark Blue',[70]='Blue',[73]='Light Blue',[88]='Yellow',[89]='Yellow',
    [111]='White',[112]='White',[122]='Gold',[132]='Gold',
}
local function colourName(mods)
    if not mods then return nil end
    local ok, m = pcall(json.decode, mods)
    if not ok or type(m) ~= 'table' then return nil end
    local c1 = m.color1 or m.colorPrimary
    local c2 = m.color2 or m.colorSecondary
    local function nm(c)
        if type(c) == 'table' then return 'Custom' end
        return PAINT_NAMES[c]
    end
    local a, b = nm(c1), nm(c2)
    if a and b and a ~= b then return a .. ' / ' .. b end
    return a or b
end

QBCore.Functions.CreateCallback('hk-garage:server:GetGarageVehicles', function(source, cb, garage, type, category, pcoords)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then return end
    local citizenId = Player.PlayerData.citizenid
    pcoords = pcoords or { x = 0.0, y = 0.0, z = 0.0 }

    -- HOMEKONG: return ALL of the player's vehicles, tagged by section:
    --   here    → in THIS garage (full controls + preview)
    --   other   → in another garage (greyed, preview + locate only)
    --   impound → state 2, police/mechanic impounded (greyed, pay-to-retrieve)
    --   street  → state 3, parked in the world (greyed, preview + locate)
    local vehicles = MySQL.query.await('SELECT * FROM player_vehicles WHERE citizenid = ?', { citizenId })
    if not vehicles or #vehicles == 0 then
        cb(nil)
        return
    end

    local function dist2(a, b)
        if not a or not b then return math.huge end
        local dx, dy = (a.x - b.x), (a.y - b.y)
        return dx * dx + dy * dy
    end

    for _, v in ipairs(vehicles) do
        local section, wp = 'other', nil
        if v.state == 2 then
            -- POLICE IMPOUND — retrieved at an NPC officer. Waypoint = nearest police lot.
            section = 'police'
            local best, bd = nil, math.huge
            for _, pl in ipairs(Config.Impound.police) do
                local d = (pcoords.x - pl.npc.x)^2 + (pcoords.y - pl.npc.y)^2
                if d < bd then best, bd = pl, d end
            end
            if best then wp = { x = best.npc.x, y = best.npc.y } end
        elseif v.state == 4 then
            -- MECHANIC DEPOT — retrieved at a depot pickup point. Waypoint = nearest depot.
            section = 'depot'
            local best, bd = nil, math.huge
            for _, dp in ipairs(Config.Impound.depots) do
                local d = (pcoords.x - dp.take.x)^2 + (pcoords.y - dp.take.y)^2
                if d < bd then best, bd = dp, d end
            end
            if best then wp = { x = best.take.x, y = best.take.y } end
        elseif v.state == 3 then
            section = 'street'
            if v.location and v.location ~= '' then
                local ok, loc = pcall(json.decode, v.location)
                if ok and loc and loc.x then wp = { x = loc.x, y = loc.y } end
            end
        else
            if v.garage == garage then section = 'here' else section = 'other' end
            local g = Config.Garages[v.garage]
            if g and g.takeVehicle then wp = { x = g.takeVehicle.x, y = g.takeVehicle.y } end
        end
        v.hk_section = section
        v.hk_waypoint = wp
        -- "where" label: street-parked cars show the STREET they're on (the DB
        -- `garage` column is stale for them). Impound/depot show their pool name.
        -- Garaged cars show the garage label.
        if section == 'street' then
            v.hk_garagelabel = (v.street and v.street ~= '' and v.street) or '街上 Street'
        elseif section == 'police' then
            v.hk_garagelabel = '警察扣車場 Police Impound'
        elseif section == 'depot' then
            v.hk_garagelabel = '維修廠扣車場 Depot'
        else
            v.hk_garagelabel = (Config.Garages[v.garage] and Config.Garages[v.garage].label) or v.garage or 'Unknown'
        end
        -- distance from the player to this car's location (for sorting)
        v.hk_dist = math.floor(math.sqrt(dist2(pcoords, wp or pcoords)))
        -- Metadata derivable without spawning (tier is done client-side on preview):
        local hash = GetHashKey(v.vehicle)
        v.hk_colour = colourName(v.mods)
        -- pcall: if the hk-handling export errors for a model, don't let it crash
        -- the whole GetGarageVehicles callback (menu would never open).
        local gbType
        if GetResourceState('hk-handling') == 'started' then
            local ok, t = pcall(function()
                return exports['hk-handling']:getModelGearbox(hash < 0 and hash + 0x100000000 or hash)
            end)
            if ok then gbType = t end
        end
        -- hk-handling gearbox type (server/gearbox.lua enum): 0 comfort-auto, 1 manual,
        -- 2 auto+paddle, 3 Sport DCT, 4 Super DCT, 5 sequential, 6 GTA-native. Player-facing
        -- names collapse both DCT profiles to one label; paddle-auto = 'Automatic +/-'.
        v.hk_drivetrain = ({ [0]='Automatic',[1]='Manual',[2]='Automatic +/-',[3]='Dual Clutch Transmission',[4]='Dual Clutch Transmission',[5]='Sequential',[6]='Automatic' })[gbType]
    end

    if Config.ClassSystem then
        vehicles = filterVehiclesByCategory(vehicles, category)
    end

    -- Sort every list by distance to the player (closest first).
    table.sort(vehicles, function(a, b) return (a.hk_dist or 0) < (b.hk_dist or 0) end)

    cb(vehicles)
end)

-- ═══════════════════════════════════════════════════════════════════════ --
-- ADMIN PARKING — owner convenience. Returns ALL of the admin's OWN vehicles
-- regardless of state/location, every row tagged section='here' + admin=true so
-- the NUI shows a spawn button on each. Admin-gated (ace 'admin'/'command').
-- ═══════════════════════════════════════════════════════════════════════ --
local function hkIsAdmin(src)
    return IsPlayerAceAllowed(src, 'admin') or IsPlayerAceAllowed(src, 'command')
end

QBCore.Functions.CreateCallback('hk-garage:server:GetAdminVehicles', function(source, cb)
    if not hkIsAdmin(source) then cb(nil) return end
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then cb(nil) return end
    local citizenId = Player.PlayerData.citizenid
    local vehicles = MySQL.query.await('SELECT * FROM player_vehicles WHERE citizenid = ?', { citizenId })
    if not vehicles or #vehicles == 0 then cb(nil) return end
    for _, v in ipairs(vehicles) do
        -- Everything is takeable from anywhere in admin mode: tag as 'here'.
        v.hk_section = 'here'
        v.hk_waypoint = nil
        v.hk_garagelabel = (v.state == 3 and '街上 Street')
            or (v.state == 2 and '警察扣車場 Police')
            or (v.state == 4 and '維修廠 Depot')
            or (Config.Garages[v.garage] and Config.Garages[v.garage].label)
            or v.garage or 'Garage'
        v.hk_dist = 0
        local hash = GetHashKey(v.vehicle)
        v.hk_colour = colourName(v.mods)
        local gbType
        if GetResourceState('hk-handling') == 'started' then
            local ok, t = pcall(function()
                return exports['hk-handling']:getModelGearbox(hash < 0 and hash + 0x100000000 or hash)
            end)
            if ok then gbType = t end
        end
        v.hk_drivetrain = ({ [0]='Automatic',[1]='Manual',[2]='Automatic +/-',[3]='Dual Clutch Transmission',[4]='Dual Clutch Transmission',[5]='Sequential',[6]='Automatic' })[gbType]
    end
    cb(vehicles)
end)

-- ADMIN spawn: no fee, no location restriction (spawns at the admin's coords,
-- passed from the client), no dupe-block. Admin-gated. Returns the same shape as
-- the normal spawnvehicle callback so the client's spawn path is reused verbatim.
QBCore.Functions.CreateCallback('hk-garage:server:adminSpawnVehicle', function(source, cb, plate)
    if not hkIsAdmin(source) then cb(false, {}, plate, nil) return end
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then cb(false, {}, plate, nil) return end
    -- Admin may only pull their OWN cars (matches the list); flip to any-owner by
    -- dropping the citizenid check if you ever want a true all-players admin tool.
    local owned = MySQL.single.await(
        'SELECT vehicle FROM player_vehicles WHERE plate = ? AND citizenid = ? LIMIT 1',
        { plate, Player.PlayerData.citizenid })
    if not owned then cb(false, {}, plate, nil) return end
    local model = owned.vehicle
    local vehProps = {}
    local result = MySQL.query.await('SELECT mods FROM player_vehicles WHERE plate = ?', { plate })
    if result and result[1] and result[1].mods then
        local success, decoded = pcall(json.decode, result[1].mods)
        if success and decoded then vehProps = decoded end
    end
    cb(true, vehProps, plate, model)
end)

-- ADMIN delete: permanently removes one of the admin's OWN vehicle rows from
-- player_vehicles. Admin-gated + own-cars-only (matches the /adminparking list).
-- DESTRUCTIVE: the DB row is gone for good. If the car is currently spawned in
-- the world, we also despawn it so it can't linger keyless. Returns ok + plate.
QBCore.Functions.CreateCallback('hk-garage:server:adminDeleteVehicle', function(source, cb, plate)
    if not hkIsAdmin(source) then cb(false, plate) return end
    if type(plate) ~= 'string' or plate == '' then cb(false, plate) return end
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then cb(false, plate) return end
    -- Own-cars-only: confirm the row exists AND belongs to this admin before deleting.
    local owned = MySQL.single.await(
        'SELECT plate FROM player_vehicles WHERE plate = ? AND citizenid = ? LIMIT 1',
        { plate, Player.PlayerData.citizenid })
    if not owned then cb(false, plate) return end
    local affected = MySQL.update.await(
        'DELETE FROM player_vehicles WHERE plate = ? AND citizenid = ?',
        { plate, Player.PlayerData.citizenid })
    if not affected or affected == 0 then cb(false, plate) return end
    -- If the car is out in the world, tell clients to despawn it (best-effort).
    TriggerClientEvent('hk-garage:client:adminDespawnPlate', -1, plate)
    print(('^3[hk-parking:adminDelete]^0 %s deleted plate %s'):format(Player.PlayerData.citizenid, plate))
    cb(true, plate)
end)

-- Impound/depot pool for the retrieval NUI. kind: 'police' (state 2) | 'depot'
-- (state 4). Returns cars formatted the same way the garage list expects, tagged
-- with section = kind + hk_retrievePrice so the NUI shows a Retrieve button.
QBCore.Functions.CreateCallback('hk-garage:server:GetImpoundVehicles', function(source, cb, kind, pcoords)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then cb(nil) return end
    local st = (kind == 'police') and 2 or 4
    local rows = MySQL.query.await('SELECT * FROM player_vehicles WHERE citizenid = ? AND '..sql.state..' = ?',
        { Player.PlayerData.citizenid, st })
    if not rows or #rows == 0 then cb(nil) return end
    local out = {}
    for _, v in ipairs(rows) do
        local vd = QBCore.Shared.Vehicles[v.vehicle]
        out[#out + 1] = {
            vehicle = v.vehicle,
            vehicleLabel = (vd and vd.name) or v.vehicle,
            brand = (vd and vd.brand) or '',
            plate = v.plate,
            state = v.state,
            fuel = v.fuel,
            engine = math.floor(v.engine or 1000),
            body = math.floor(v.body or 1000),
            mods = v.mods,
            garage = { spawnPoint = {} },   -- spawn point comes from impoundSpawn (client)
            depotPrice = v.depotprice or SV_Config.ImpoundPrice,
            colour = colourName(v.mods),
            section = kind,                 -- 'police' | 'depot'
            garageLabelOf = (kind == 'police') and '警察扣車場 Police Impound' or '維修廠扣車場 Depot',
        }
    end
    cb(out)
end)

-- Backwards Compat
local vehicleTypes = { -- https://docs.fivem.net/natives/?_0xA273060E
    motorcycles = 'bike',
    boats = 'boat',
    helicopters = 'heli',
    planes = 'plane',
    submarines = 'submarine',
    trailer = 'trailer',
    train = 'train'
}

local function GetVehicleTypeByModel(model)
    local vehicleData = QBCore.Shared.Vehicles[model]
    if not vehicleData then return 'automobile' end
    local category = vehicleData.category
    local vehicleType = vehicleTypes[category]
    return vehicleType or 'automobile'
end
-- Backwards Compat

-- Garage storage fee for a stored car (by DB park time). $/hr, daily cap, hard max.
local function CalcGarageFee(row)
    if not SV_Config.GarageFee.enabled then return 0 end
    if not row or not row.time then return 0 end
    local t = tonumber(row.time)
    if not t or t == 0 then return 0 end               -- non-numeric/unset → no fee
    local secs = os.time() - t
    if secs <= 0 then return 0 end
    local hours = secs / 3600
    local days = math.floor(hours / 24)
    local remHours = hours - (days * 24)
    local fee = (days * SV_Config.GarageFee.dailyCap)
              + math.min(SV_Config.GarageFee.dailyCap, remHours * SV_Config.GarageFee.perHour)
    fee = math.floor(fee)
    if fee > SV_Config.GarageFee.hardMax then fee = SV_Config.GarageFee.hardMax end
    return fee
end

-- Spawns a vehicle and returns its network ID and properties.
-- CLIENT-SIDE SPAWN MODEL. This callback used to CreateVehicleServerSetter here,
-- but a server-created entity's OWNER bounces tick-to-tick on a populated server —
-- so the client warping in often doesn't own/simulate it yet -> no local collision
-- -> ped falls through the car + world unloads (the documented ServerSetter issue).
-- Fix: the server only VALIDATES ownership + charges the fee, then returns the
-- DB-verified model + props. The CLIENT does CreateVehicle locally (it's instantly
-- the owner, collision is loaded where it stands) and reports the netId back via
-- hk-garage:server:UpdateOutsideVehicle for tracking + the dupe guard.
QBCore.Functions.CreateCallback('hk-garage:server:spawnvehicle', function(source, cb, plate, vehicle, coords)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then cb(false, {}, plate, nil) return end
    local owned = MySQL.single.await(
        'SELECT vehicle, '..sql.state..' AS st FROM player_vehicles WHERE plate = ? AND citizenid = ? LIMIT 1',
        { plate, Player.PlayerData.citizenid })
    if not owned then cb(false, {}, plate, nil) return end     -- not your car
    -- Dupe guard: already out (state 0) AND its tracked netId still exists in world.
    if owned.st == 0 and OutsideVehicles[plate] and OutsideVehicles[plate].netID
       and NetworkGetEntityFromNetworkId(OutsideVehicles[plate].netID) ~= 0 then
        cb(false, {}, plate, nil) return                       -- already spawned
    end
    local model = owned.vehicle or vehicle                     -- DB model, not client's

    -- CHARGE the garage storage fee now (validated). Only garaged (state 1) cars;
    -- impound/depot (2/4) already paid their flat fee. Job-exempt pay nothing.
    if owned.st == 1 then
        local job = Player.PlayerData.job and Player.PlayerData.job.name
        if not (job and SV_Config.GarageFee.exemptJobs[job]) then
            local frow = MySQL.single.await('SELECT time FROM player_vehicles WHERE plate = ?', { plate })
            local fee = CalcGarageFee(frow)
            if fee > 0 then
                local cash = Player.PlayerData.money['cash'] or 0
                if cash >= fee then Player.Functions.RemoveMoney('cash', fee, 'garage-fee')
                else Player.Functions.RemoveMoney('bank', fee, 'garage-fee') end
                RouteFeeToBilling(Player.PlayerData.citizenid, fee, SV_Config.Billing.garageFeeSociety, 'Garage Fee')
                TriggerClientEvent('ox_lib:notify', source, { title = 'HK Parking', description = ('已付停車費 Garage fee: $%s'):format(fee), type = 'success' })
            end
        end
    end

    -- Fetch mods from DB
    local vehProps = {}
    local result = MySQL.query.await('SELECT mods FROM player_vehicles WHERE plate = ?', { plate })
    if result and result[1] and result[1].mods then
        local success, decoded = pcall(json.decode, result[1].mods)
        if success and decoded then vehProps = decoded
        else print('^3[hk-garage] Failed to decode mods for plate: ' .. plate .. '^0') end
    end

    -- ok=true, props, plate, and the DB-verified MODEL for the client to spawn.
    cb(true, vehProps, plate, model)
end)

-- HOMEKONG garage storage fee. Charged only when taking a car OUT of a garage
-- (state=1). $100/hr, capped $2400/day, hard max $33600. Fee-exempt jobs pay $0.
-- Street-parked (state=3) and out cars never reach this. Returns:
--   { ok=true }              → proceed (paid or exempt or $0)
--   { ok=false, fee=n }      → couldn't afford; blocked
-- chargeGarageFee is now a CHECK ONLY (affordability) — the actual money is
-- removed inside spawnvehicle AFTER the car is confirmed created, so a failed
-- spawn never charges the player (was: pay-then-fail = money lost, no car).
QBCore.Functions.CreateCallback('hk-garage:server:chargeGarageFee', function(source, cb, plate)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then cb({ ok = false }) return end
    local job = Player.PlayerData.job and Player.PlayerData.job.name
    if job and SV_Config.GarageFee.exemptJobs[job] then cb({ ok = true, fee = 0 }) return end
    local row = MySQL.single.await('SELECT time FROM player_vehicles WHERE plate = ? AND citizenid = ?', { plate, Player.PlayerData.citizenid })
    local fee = CalcGarageFee(row)
    if fee <= 0 then cb({ ok = true, fee = 0 }) return end
    local cash = (Player.PlayerData.money['cash'] or 0)
    local bank = (Player.PlayerData.money['bank'] or 0)
    if (cash + bank) < fee then
        TriggerClientEvent('ox_lib:notify', source, { title = 'HK Parking', description = ('停車費不足 Need $%s garage fee'):format(fee), type = 'error' })
        cb({ ok = false, fee = fee })
        return
    end
    cb({ ok = true, fee = fee })   -- affordable — NOT charged yet
end)

-- Checks if a vehicle can be spawned based on its type and location.
QBCore.Functions.CreateCallback('hk-garage:server:IsSpawnOk', function(_, cb, plate, type)
    -- netId-based existence check (client-spawn model: server has no entity handle).
    if OutsideVehicles[plate] and OutsideVehicles[plate].netID
       and NetworkGetEntityFromNetworkId(OutsideVehicles[plate].netID) ~= 0 then
        cb(false)
        return
    end
    cb(true)
end)

QBCore.Functions.CreateCallback('hk-garage:server:canDeposit', function(source, cb, plate, type, garage, state)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then 
        cb(false)
        return
    end
    
    local isOwned = MySQL.scalar.await('SELECT citizenid FROM player_vehicles WHERE plate = ? LIMIT 1', { plate })
    if isOwned ~= Player.PlayerData.citizenid then
        cb(false)
        return
    end
    
    if type == 'house' and not exports['qb-houses']:hasKey(Player.PlayerData.license, Player.PlayerData.citizenid, Config.Garages[garage].houseName) then
        cb(false)
        return
    end
    
    if state == 1 then
        MySQL.update('UPDATE player_vehicles SET state = ?, garage = ? WHERE plate = ?', { state, garage, plate })
        -- Clear from OutsideVehicles tracking
        if OutsideVehicles[plate] then
            OutsideVehicles[plate] = nil
        end
        cb(true)
    else
        cb(false)
    end
end)

-- Events

RegisterNetEvent('hk-garage:server:updateVehicleStats', function(plate, fuel, engine, body)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    MySQL.update('UPDATE player_vehicles SET fuel = ?, engine = ?, body = ? WHERE plate = ? AND citizenid = ?', { fuel, engine, body, plate, Player.PlayerData.citizenid })
end)

-- HK: save the FULL vehicle properties (mods/paint/wheels/plate) to OUR player_vehicles
-- on deposit. Previously the client fired qb-mechanicjob:server:SaveVehicleProps, but
-- qb-mechanicjob is in [unused] (not running), so mods were NEVER saved -> stored car
-- came back UNMODDED and fresh customizations were lost. Ownership-gated by plate+cid.
RegisterNetEvent('hk-garage:server:saveVehicleProps', function(props)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player or type(props) ~= 'table' or not props.plate then return end
    local plate = tostring(props.plate):gsub("^%s*(.-)%s*$", "%1"):upper()
    -- must own this plate
    local owned = MySQL.scalar.await('SELECT citizenid FROM player_vehicles WHERE plate = ? LIMIT 1', { plate })
    if owned ~= Player.PlayerData.citizenid then return end
    -- ANTI-WIPE GUARD + log: don't let a spuriously-stock deposit snapshot overwrite an
    -- already-modded row (mirrors Database.SaveMods). A car the player is sitting in
    -- should report its real mods, but streamed/desynced captures can read -1s.
    local function _coreMax(m)
        if type(m) ~= 'table' then return -1 end
        local hi = -1
        for _, k in ipairs({'modEngine','modBrakes','modTransmission','modSuspension','modArmor'}) do
            local v = tonumber(m[k]); if v and v > hi then hi = v end
        end
        return hi
    end
    local incMax = _coreMax(props)
    local existRow = MySQL.single.await('SELECT mods FROM player_vehicles WHERE plate = ? LIMIT 1', { plate })
    local existMax = -1
    if existRow and existRow.mods then
        local okEx, exist = pcall(json.decode, existRow.mods)
        if okEx then existMax = _coreMax(exist) end
    end
    if incMax < 0 and existMax >= 0 then
        print(('^3[hk-garage:deposit]^0 %s: SKIP wipe — incoming stock vs existing modded (max=%d)'):format(plate, existMax))
        return
    end
    print(('^2[hk-garage:deposit]^0 %s: WRITE mods (incoming max=%d, existing max=%d)'):format(plate, incMax, existMax))
    MySQL.update('UPDATE player_vehicles SET mods = ? WHERE plate = ? AND citizenid = ?',
        { json.encode(props), plate, Player.PlayerData.citizenid })
end)

RegisterNetEvent('hk-garage:server:updateVehicleState', function(state, plate)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    MySQL.update('UPDATE player_vehicles SET state = ?, depotprice = ? WHERE plate = ? AND citizenid = ?', { state, 0, plate, Player.PlayerData.citizenid })
end)

RegisterNetEvent('hk-garage:server:UpdateOutsideVehicle', function(plate, vehicleNetID)
    if vehicleNetID then
        -- Store the netId (client-spawn model: existence is checked via
        -- NetworkGetEntityFromNetworkId(netID) ~= 0, valid server-side under OneSync).
        OutsideVehicles[plate] = { netID = vehicleNetID }
    else
        OutsideVehicles[plate] = nil
    end
end)

RegisterNetEvent('hk-garage:server:trackVehicle', function(plate)
    local src = source
    -- 1) A car spawned in the world by the garage: track the live entity (resolve
    -- from the tracked netId — client-spawn model, no server-held entity handle).
    local vehicleData = OutsideVehicles[plate]
    local outEnt = vehicleData and vehicleData.netID and NetworkGetEntityFromNetworkId(vehicleData.netID)
    if outEnt and outEnt ~= 0 and DoesEntityExist(outEnt) then
        TriggerClientEvent('hk-garage:client:trackVehicle', src, GetEntityCoords(outEnt))
        TriggerClientEvent('ox_lib:notify', src, { title = 'HK Parking', description = Lang:t('success.vehicle_tracked'), type = 'success' })
        return
    end
    -- 2) A street-parked car (hk-parking, state 3): waypoint to its stored location.
    local Player = QBCore.Functions.GetPlayer(src)
    if Player then
        local row = MySQL.query.await(
            'SELECT location FROM player_vehicles WHERE plate = ? AND citizenid = ? AND state = 3 LIMIT 1',
            { plate, Player.PlayerData.citizenid }
        )
        if row and row[1] and row[1].location and row[1].location ~= '' then
            local ok, loc = pcall(json.decode, row[1].location)
            if ok and type(loc) == 'table' and loc.x then
                TriggerClientEvent('hk-garage:client:trackVehicle', src, { x = loc.x, y = loc.y, z = loc.z or 0.0 })
                TriggerClientEvent('ox_lib:notify', src, { title = 'HK Parking', description = Lang:t('success.vehicle_tracked'), type = 'success' })
                return
            end
        end
    end
    TriggerClientEvent('ox_lib:notify', src, { title = 'HK Parking', description = Lang:t('error.vehicle_not_tracked'), type = 'error' })
end)

RegisterNetEvent('hk-garage:server:PayDepotPrice', function(data)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    if not data or not data.plate then return end

    local cashBalance = Player.PlayerData.money['cash']
    local bankBalance = Player.PlayerData.money['bank']

    -- OWNERSHIP + impound-state gate: must be the caller's car AND actually
    -- impounded (state 2 police / 4 depot). Stops paying for others' cars or
    -- for a car that was never impounded.
    local row = MySQL.single.await(
        'SELECT towedby, '..sql.state..' AS st FROM player_vehicles WHERE plate = ? AND citizenid = ? LIMIT 1',
        { data.plate, Player.PlayerData.citizenid })
    if not row then
        TriggerClientEvent('ox_lib:notify', src, { title = 'HK Parking', description = '搵唔到架車 · Vehicle not found', type = 'error' })
        return
    end
    if row.st ~= 2 and row.st ~= 4 then
        TriggerClientEvent('ox_lib:notify', src, { title = 'HK Parking', description = '架車唔喺扣車場 · Not impounded', type = 'error' })
        return
    end
    data.type = 'impound'   -- so takeOutGarage skips the garage storage fee (no double-charge)
    -- HOMEKONG: flat impound/depot retrieval price.
    local depotPrice = SV_Config.ImpoundPrice or 12000

    local function afterPay()
        -- Pay the tow mechanic their retrieval cut (if any); the REMAINDER goes to
        -- the depot society. Clear the tow tag afterward.
        local cut = 0
        if row and row.towedby and row.towedby ~= '' then
            cut = math.floor(depotPrice * (SV_Config.Mechanic.retrievalCut or 0))
            if cut > 0 then PayTowMechanic(row.towedby, cut, data.plate) end
            MySQL.update('UPDATE player_vehicles SET towedby = NULL WHERE plate = ?', { data.plate })
        end
        -- society gets price minus the individual mechanic's personal cut. Route to
        -- the right pool: police impound → police society, mechanic depot → depot.
        local society = (row.st == 2) and (SV_Config.Billing.policeImpoundSociety or SV_Config.Billing.depotSociety) or SV_Config.Billing.depotSociety
        RouteFeeToBilling(Player.PlayerData.citizenid, depotPrice - cut, society, (row.st == 2) and 'Police Impound' or 'Depot Retrieval')
        -- Release from impound → state 0 (out) so it spawns/tracks correctly.
        MySQL.update('UPDATE player_vehicles SET '..sql.state..' = 0, depotprice = 0 WHERE plate = ?', { data.plate })
        TriggerClientEvent('hk-garage:client:takeOutGarage', src, data)
    end

    if cashBalance >= depotPrice then
        Player.Functions.RemoveMoney('cash', depotPrice, 'paid-depot')
        afterPay()
    elseif bankBalance >= depotPrice then
        Player.Functions.RemoveMoney('bank', depotPrice, 'paid-depot')
        afterPay()
    else
        TriggerClientEvent('ox_lib:notify', src, { title = 'HK Parking', description = Lang:t('error.not_enough'), type = 'error' })
    end
end)

-- House Garages

RegisterNetEvent('hk-garage:server:syncGarage', function(updatedGarages)
    Config.Garages = updatedGarages
end)

--Call from qb-phone

QBCore.Functions.CreateCallback('hk-garage:server:GetPlayerVehicles', function(source, cb)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then 
        cb(nil)
        return
    end
    
    local Vehicles = {}

    local result = MySQL.query.await('SELECT * FROM player_vehicles WHERE citizenid = ?', { Player.PlayerData.citizenid })
    if result and result[1] then
        for _, v in pairs(result) do
            local VehicleData = QBCore.Shared.Vehicles[v.vehicle]

            local VehicleGarage = Lang:t('error.no_garage')
            if v.garage ~= nil then
                if Config.Garages[v.garage] ~= nil then
                    VehicleGarage = Config.Garages[v.garage].label
                else
                    VehicleGarage = Lang:t('info.house')
                end
            end
            -- STREET-PARKED (state 3): the  column is STALE (still the last
            -- garage it lived in), so showing it reads as "in <garage>" when the car
            -- is actually sitting on the street. Override with the street name (or a
            -- generic Street label) — same rule the in-person garage menu uses.
            if v.state == 3 then
                VehicleGarage = (v.street and v.street ~= '' and v.street) or '街上 Street'
            elseif v.state == 2 then
                VehicleGarage = '警察扣車場 Police Impound'
            elseif v.state == 4 then
                VehicleGarage = '維修廠扣車場 Depot'
            end

            local stateTranslation
            if v.state == 0 then
                stateTranslation = Lang:t('status.out')
            elseif v.state == 1 then
                stateTranslation = Lang:t('status.garaged')
            elseif v.state == 2 then
                stateTranslation = Lang:t('status.impound')
            elseif v.state == 3 then
                -- hk-parking: state 3 = parked on the street (server-side spawn)
                stateTranslation = Lang:t('status.parked')
            end

            -- hk-parking integration: expose parked location + street so the phone
            -- garage app can drop a GPS waypoint on a street-parked vehicle.
            local parkedLocation, parkedStreet = nil, nil
            if v.state == 3 and v.location ~= nil and v.location ~= '' then
                local ok, decoded = pcall(json.decode, v.location)
                if ok and type(decoded) == 'table' and decoded.x then
                    parkedLocation = { x = decoded.x, y = decoded.y, z = decoded.z, h = decoded.h }
                end
                parkedStreet = v.street
            end

            local fullname
            if VehicleData and VehicleData['brand'] then
                fullname = VehicleData['brand'] .. ' ' .. VehicleData['name']
            else
                fullname = VehicleData and VehicleData['name'] or 'Unknown Vehicle'
            end

            Vehicles[#Vehicles + 1] = {
                fullname = fullname,
                brand = VehicleData and VehicleData['brand'] or '',
                model = VehicleData and VehicleData['name'] or '',
                plate = v.plate,
                garage = VehicleGarage,
                state = stateTranslation,
                fuel = v.fuel,
                engine = v.engine,
                body = v.body,
                -- hk-parking additions:
                location = parkedLocation,
                street = parkedStreet,
                -- HK phone garage revamp: raw state (0-4) for pill colour +
                -- vehicle category for the list badge (cheap, no spawn needed).
                stateRaw = v.state,
                category = VehicleData and VehicleData['category'] or ''
            }
        end
        cb(Vehicles)
    else
        cb(nil)
    end
end)

local function getAllGarages()
    local garages = {}
    for k, v in pairs(Config.Garages) do
        garages[#garages + 1] = {
            name = k,
            label = v.label,
            type = v.type,
            takeVehicle = v.takeVehicle,
            putVehicle = v.putVehicle,
            spawnPoint = v.spawnPoint,
            showBlip = v.showBlip,
            blipName = v.blipName,
            blipNumber = v.blipNumber,
            blipColor = v.blipColor,
            vehicle = v.vehicle
        }
    end
    return garages
end

exports('getAllGarages', getAllGarages)

-- HK-Garage: return a vehicle's stored mods for the live 3D preview.
-- Verifies the requesting player actually owns the plate before handing over data.
QBCore.Functions.CreateCallback('hk-garage:server:GetPreviewProps', function(source, cb, plate)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player or not plate then cb(nil) return end
    local result = MySQL.query.await(
        'SELECT mods FROM player_vehicles WHERE plate = ? AND citizenid = ?',
        { plate, Player.PlayerData.citizenid }
    )
    if result and result[1] and result[1].mods then
        local ok, decoded = pcall(json.decode, result[1].mods)
        if ok and decoded then cb(decoded) return end
    end
    cb({})
end)

-- Gearbox type label for the preview mods panel, from hk-handling's model preset.
-- getModelGearbox(hash) → type per hk-handling: 0 our automatic, 1 manual,
-- 2 basic DCT, 3 sport DCT, 4 super DCT, 5 sequential dogbox, 6 GTA native (auto).
QBCore.Functions.CreateCallback('hk-garage:server:GetGearboxType', function(source, cb, model)
    if not model then cb(nil) return end
    if GetResourceState('hk-handling') ~= 'started' then cb(nil) return end
    -- hk-handling's presetModels is keyed by UNSIGNED 32-bit hashes (from the DB),
    -- but GetHashKey returns a SIGNED int for hashes > 2^31 → lookup misses and
    -- everything falls back to Automatic. Convert to unsigned first.
    local hash = GetHashKey(model)
    if hash < 0 then hash = hash + 0x100000000 end
    local ok, t = pcall(function() return exports['hk-handling']:getModelGearbox(hash) end)
    if not ok or t == nil then cb(nil) return end
    -- Player-facing transmission names (hk-handling enum → display). Both DCT
    -- profiles (Sport/Super) collapse to one label; index 2 is the auto+paddle mode.
    local names = {
        [0] = 'Automatic',
        [1] = 'Manual',
        [2] = 'Automatic +/-',
        [3] = 'Dual Clutch Transmission',
        [4] = 'Dual Clutch Transmission',
        [5] = 'Sequential',
        [6] = 'Automatic',
    }
    cb(names[t] or 'Automatic')
end)