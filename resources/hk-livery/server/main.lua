-- ─────────────────────────────────────────────
--  hk-livery · Server
--  Persistence + multiplayer livery sync
-- ─────────────────────────────────────────────

local QBCore = exports['qb-core']:GetCoreObject()

-- ─────────────────────────────
--  Database Setup
-- ─────────────────────────────

CreateThread(function()
    MySQL.query([[
        CREATE TABLE IF NOT EXISTS hk_liveries (
            id INT AUTO_INCREMENT PRIMARY KEY,
            citizenid VARCHAR(50) NOT NULL,
            plate VARCHAR(8) NOT NULL,
            model VARCHAR(64) NOT NULL,
            png_data LONGTEXT,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
            UNIQUE KEY idx_plate (plate),
            INDEX idx_citizen (citizenid)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
    ]])
    print('[hk-livery] Database table ready')
end)

-- ─────────────────────────────
--  Callbacks
-- ─────────────────────────────

--- Get livery for a plate
QBCore.Functions.CreateCallback('hk-livery:server:getLivery', function(source, cb, plate)
    if not plate or plate == '' then return cb(nil) end

    local result = MySQL.single.await('SELECT png_data, model FROM hk_liveries WHERE plate = ?', { plate })
    cb(result)
end)

-- ─────────────────────────────
--  Save / Delete
-- ─────────────────────────────

RegisterNetEvent('hk-livery:server:saveLivery', function(data)
    local src    = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end

    local citizenid = Player.PlayerData.citizenid
    local plate     = data.plate
    local model     = data.model
    local pngData   = data.png_data

    if not plate or not model or not pngData then return end

    -- Upsert: insert or update existing
    MySQL.insert.await([[
        INSERT INTO hk_liveries (citizenid, plate, model, png_data)
        VALUES (?, ?, ?, ?)
        ON DUPLICATE KEY UPDATE
            png_data   = VALUES(png_data),
            model      = VALUES(model),
            updated_at = CURRENT_TIMESTAMP
    ]], { citizenid, plate, model, pngData })

    -- Broadcast to nearby players so they see the new livery
    broadcastLivery(src, plate, model, pngData)
end)

RegisterNetEvent('hk-livery:server:deleteLivery', function(plate)
    local src    = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end

    local citizenid = Player.PlayerData.citizenid

    -- Only allow deleting own liveries
    MySQL.query.await('DELETE FROM hk_liveries WHERE plate = ? AND citizenid = ?', { plate, citizenid })

    -- Tell all clients to remove the texture
    TriggerClientEvent('hk-livery:client:removeLivery', -1, plate)
end)

-- ─────────────────────────────
--  Multiplayer Broadcast
-- ─────────────────────────────

--- Send livery data to all players except the source
function broadcastLivery(srcPlayer, plate, model, pngData)
    local players = QBCore.Functions.GetPlayers()
    for _, pid in ipairs(players) do
        if pid ~= srcPlayer then
            TriggerClientEvent('hk-livery:client:applyLivery', pid, plate, model, pngData)
        end
    end
end

-- ─────────────────────────────
--  Player scope: load liveries
--  for vehicles near a joining player
-- ─────────────────────────────

RegisterNetEvent('QBCore:Server:OnPlayerLoaded', function()
    local src = source
    -- Small delay to let client initialize
    SetTimeout(5000, function()
        sendAllLiveries(src)
    end)
end)

--- Send all saved liveries to a specific player
--- (They'll only apply ones for vehicles they can see)
function sendAllLiveries(targetPlayer)
    local results = MySQL.query.await('SELECT plate, model, png_data FROM hk_liveries')
    if not results then return end

    for _, row in ipairs(results) do
        TriggerClientEvent('hk-livery:client:applyLivery', targetPlayer, row.plate, row.model, row.png_data)
    end
end

-- ─────────────────────────────
--  Admin: clear livery
-- ─────────────────────────────

QBCore.Commands.Add('clearlivery', 'Clear a vehicle\'s custom livery (admin)', {
    { name = 'plate', help = 'Vehicle plate' },
}, false, function(source, args)
    local plate = args[1]
    if not plate then return end

    plate = string.upper(plate:gsub('%s+', ''))
    MySQL.query.await('DELETE FROM hk_liveries WHERE plate = ?', { plate })
    TriggerClientEvent('hk-livery:client:removeLivery', -1, plate)

    local Player = QBCore.Functions.GetPlayer(source)
    if Player then
        TriggerClientEvent('QBCore:Notify', source, 'Livery cleared for ' .. plate, 'success')
    end
end, 'admin')
