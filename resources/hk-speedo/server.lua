-----------------------------------------------------------------
-- hk-speedo :: server.lua
-- Per-player speedo display mode ('normal' | 'lite' | 'full' | 'minimal'), persisted to
-- SQL keyed by QBCore citizenid. Client asks for its saved mode on load and pushes
-- changes when the player cycles with /speedo. 'normal' is the default (cheap glow halos).
-----------------------------------------------------------------
local QBCore = exports['qb-core']:GetCoreObject()

local VALID = { normal = true, lite = true, full = true, minimal = true }
local DEFAULT_MODE = 'normal'

-- Ensure the prefs table exists (id = citizenid).
CreateThread(function()
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS `hk_speedo_prefs` (
            `citizenid` VARCHAR(64) NOT NULL,
            `mode` VARCHAR(16) NOT NULL DEFAULT 'normal',
            PRIMARY KEY (`citizenid`)
        )
    ]])
end)

local function getCitizenId(src)
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return nil end
    return Player.PlayerData.citizenid
end

-- Client requests its saved mode (on resource start / player load).
QBCore.Functions.CreateCallback('hk-speedo:getMode', function(source, cb)
    local cid = getCitizenId(source)
    if not cid then cb(DEFAULT_MODE) return end
    local mode = MySQL.scalar.await('SELECT mode FROM hk_speedo_prefs WHERE citizenid = ?', { cid })
    cb((mode and VALID[mode]) and mode or DEFAULT_MODE)
end)

-- Client saves a new mode (after cycling with /speedo).
RegisterNetEvent('hk-speedo:saveMode', function(mode)
    local src = source
    if not VALID[mode] then return end
    local cid = getCitizenId(src)
    if not cid then return end
    MySQL.insert.await([[
        INSERT INTO hk_speedo_prefs (citizenid, mode) VALUES (?, ?)
        ON DUPLICATE KEY UPDATE mode = VALUES(mode)
    ]], { cid, mode })
end)
