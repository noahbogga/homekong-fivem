-- ═══════════════════════════════════════════════════════════ --
--          HK-PARKING — HOMEKONG (based on mh-parking by MaDHouSe79, MIT)           --
-- ═══════════════════════════════════════════════════════════ --
Database = {}

sql = {table = "player_vehicles", citizenid = "citizenid", state = "state"}
ply = {table = "players", citizenid = "citizenid"}

if GetResourceState('es_extended') == 'started' then
    sql = {table = "owned_vehicles", citizenid = "owner", state = "stored"}
    ply = {table = "users", citizenid = "identifier"}
elseif GetResourceState('qb-core') == 'started' then
    sql = {table = "player_vehicles", citizenid = "citizenid", state = "state"}
    ply = {table = "players", citizenid = "citizenid"}
end

MySQL.ready(function()
    MySQL.Async.execute('ALTER TABLE '..ply.table..' ADD COLUMN IF NOT EXISTS parkvip INT NULL DEFAULT 0')
    MySQL.Async.execute('ALTER TABLE '..ply.table..' ADD COLUMN IF NOT EXISTS parkmax INT NULL DEFAULT 0')
    MySQL.Async.execute('ALTER TABLE '..sql.table..' ADD COLUMN IF NOT EXISTS steerangle INT NULL DEFAULT 0')
    MySQL.Async.execute('ALTER TABLE '..sql.table..' ADD COLUMN IF NOT EXISTS street TEXT NULL DEFAULT NULL')
    MySQL.Async.execute('ALTER TABLE '..sql.table..' ADD COLUMN IF NOT EXISTS location TEXT NULL DEFAULT NULL')
    MySQL.Async.execute('ALTER TABLE '..sql.table..' ADD COLUMN IF NOT EXISTS parktime INT NULL DEFAULT 0')
    MySQL.Async.execute('ALTER TABLE '..sql.table..' ADD COLUMN IF NOT EXISTS time BIGINT NOT NULL DEFAULT 0')
    MySQL.Async.execute('ALTER TABLE '..sql.table..' ADD COLUMN IF NOT EXISTS isClamped INT NULL DEFAULT 0')
    -- HOMEKONG: citizenid of the mechanic who towed this car to impound (for the
    -- retrieval cut paid when the owner pays to get it back). NULL = not towed.
    MySQL.Async.execute('ALTER TABLE '..sql.table..' ADD COLUMN IF NOT EXISTS towedby VARCHAR(64) NULL DEFAULT NULL')
end)

function Database.ParkVehicle(plate, location, steerangle, street)
    MySQL.update('UPDATE '..sql.table..' SET '..sql.state..' = ?, location = ?, street = ?, steerangle = ? WHERE plate = ?', {3, json.encode(location), street, steerangle, plate})
end

-- HOMEKONG: persist a LIVE mods snapshot captured client-side at park time.
-- The mechanic (Jimathy) saves upgrades on a 5s deferred timer; auto-park fires
-- at 3s and used to read STALE mods from the DB, dropping a just-applied upgrade
-- from the parked look. Writing the live snapshot here makes the DB authoritative
-- regardless of the mechanic's timer. json string in, no-op on nil/empty.
--
-- ANTI-WIPE GUARD: if the incoming snapshot looks STOCK (all core upgrades = -1)
-- but the existing DB row already HAS upgrades, refuse the write. A distant/streamed
-- or freshly-respawned entity can report -1 for native mods; without this guard the
-- park capture would silently downgrade a modded car to stock. Legit mechanic mod
-- REMOVAL goes through Jimathy's own save path, not this one.
local function coreUpgradeMax(m)
    if type(m) ~= 'table' then return -1 end
    local hi = -1
    for _, k in ipairs({'modEngine','modBrakes','modTransmission','modSuspension','modArmor'}) do
        local v = tonumber(m[k])
        if v and v > hi then hi = v end
    end
    return hi
end

function Database.SaveMods(plate, modsJson)
    if not modsJson or modsJson == '' or modsJson == 'null' then return end
    local okIn, incoming = pcall(json.decode, modsJson)
    if not okIn or type(incoming) ~= 'table' then
        print(('^3[hk-parking:SaveMods]^0 %s: SKIP (undecodable payload)'):format(plate))
        return
    end
    local incMax = coreUpgradeMax(incoming)
    -- Compare against what's already stored.
    local existRow = MySQL.single.await('SELECT mods FROM '..sql.table..' WHERE plate = ? LIMIT 1', { plate })
    local existMax = -1
    if existRow and existRow.mods then
        local okEx, exist = pcall(json.decode, existRow.mods)
        if okEx then existMax = coreUpgradeMax(exist) end
    end
    if incMax < 0 and existMax >= 0 then
        print(('^3[hk-parking:SaveMods]^0 %s: SKIP wipe — incoming stock (max=%d) vs existing modded (max=%d)'):format(plate, incMax, existMax))
        return
    end
    print(('^2[hk-parking:SaveMods]^0 %s: WRITE (incoming upgrade max=%d, existing max=%d)'):format(plate, incMax, existMax))
    MySQL.update('UPDATE '..sql.table..' SET mods = ? WHERE plate = ?', { modsJson, plate })
end

function Database.UnparkVehicle(plate)
    -- NULLs written as SQL literals (not nil params) — a nil mid-array breaks the
    -- param count and can mis-bind the plate.
    MySQL.update('UPDATE '..sql.table..' SET '..sql.state..' = 0, location = NULL, street = NULL WHERE plate = ?', { plate })
end

function Database.GetVehicleData(plate)
    return MySQL.single.await("SELECT * FROM "..sql.table.." WHERE plate = ? LIMIT 1", {plate})
end

function Database.GetVehicles()
    return MySQL.query.await("SELECT * FROM "..sql.table.." WHERE "..sql.state.." = ?", {3})
end

function Database.IsOwned(plate)
    local result = MySQL.single.await("SELECT * FROM "..sql.table.." WHERE plate = ? LIMIT 1", {plate})
    if result ~= nil then return result.citizenid or result.owner end
    return false
end

function Database.GetVehiclesForCitizenid(citizenid)
    return citizenid ~= false and MySQL.query.await("SELECT * FROM "..sql.table.." WHERE "..sql.state.." = ? AND "..sql.citizenid.." = ? ", {3, citizenid})
end

function Database.GetPlayerData(citizenid)
    return MySQL.query.await("SELECT * FROM "..ply.table.." WHERE "..sql.citizenid.." = ?", {citizenid})[1]
end

function Database.UpdateWheelClamp(plate, state)
    return MySQL.Async.execute("UPDATE "..sql.table.." SET isClamped = ? WHERE plate = ?", {state, plate})
end

function Database.IsVehicleOwned(src, plate)
    local citizenid = GetIdentifier(src)
    return citizenid ~= false and MySQL.single.await("SELECT * FROM "..sql.table.." WHERE plate = ? AND "..sql.citizenid.." = ? LIMIT 1", {plate, citizenid})
end

function Database.GetPlayerVehicles(src)
    local citizenid = GetIdentifier(src)
    return citizenid ~= false and MySQL.Sync.fetchAll("SELECT * FROM "..sql.table.." WHERE "..sql.citizenid.." = ? AND "..sql.state.." = ?", {citizenid, 3})
end

function Database.GetMaxParking(src)
    local citizenid = GetIdentifier(src)
    local result = MySQL.single.await("SELECT * FROM "..sql.table.." WHERE "..sql.citizenid.." = ? LIMIT 1", {citizenid})
    if citizenid ~= false and result ~= nil and result.parkvip == 1 then return tonumber(result.parkmax) or SV_Config.DefaultMaxParking end
    return SV_Config.DefaultMaxParking
end

function Database.AddVip(src, amount)
    local citizenid = GetIdentifier(src)
    return citizenid ~= false and MySQL.Async.execute("UPDATE "..ply.table.." SET parkvip = ?, parkmax = ? WHERE "..ply.citizenid.." = ?", {1, amount, citizenid})
end

function Database.RemovedVip(src)
    local citizenid = GetIdentifier(src)
    return citizenid ~= false and MySQL.Async.execute("UPDATE "..ply.table.." SET parkvip = ?, parkmax = ? WHERE "..ply.citizenid.." = ?", {0, 0, citizenid})
end

function Database.IsPlayerAVip(src)
    local citizenid = GetIdentifier(src)
    local result = MySQL.single.await("SELECT * FROM "..ply.table.." WHERE "..ply.citizenid.." = ? LIMIT 1", {citizenid})
    if citizenid ~= false and result ~= nil and result.parkvip == 1 then return true end
    return false
end