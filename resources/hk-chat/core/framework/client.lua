-- ═══════════════════════════════════════════════════════════════ --
--   HK-CHAT — framework wrapper (client)                              --
--   Thin QBCore bridge so the rest of the client code stays clean.    --
-- ═══════════════════════════════════════════════════════════════ --
QBCore = nil
PlayerData = {}

CreateThread(function()
    while QBCore == nil do
        QBCore = exports['qb-core']:GetCoreObject()
        Wait(200)
    end
    PlayerData = QBCore.Functions.GetPlayerData() or {}
end)

RegisterNetEvent('QBCore:Client:OnPlayerLoaded', function()
    PlayerData = QBCore.Functions.GetPlayerData() or {}
end)

RegisterNetEvent('QBCore:Client:OnJobUpdate', function(job)
    PlayerData.job = job
end)

RegisterNetEvent('QBCore:Client:OnPlayerUnload', function()
    PlayerData = {}
end)

-- Current job name, or the shared unemployed bucket when jobless.
function GetJobRoom()
    local job = PlayerData and PlayerData.job
    if job and job.name and job.name ~= '' then
        return job.name
    end
    return Config.UnemployedRoom
end
