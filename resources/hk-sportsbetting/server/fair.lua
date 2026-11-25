-- Provably Fair System for hk-sportsbetting
-- Seeds now live in the engine (zx side, data/seeds.json), NOT the game DB.
-- Outcome = HMAC-SHA256(serverSeed, clientSeed:nonce:cursor), computed engine-side.
-- Players can verify after the server seed is rotated (revealed).
--
-- This file is now a thin bridge to the engine's /fair/* endpoints. The old
-- hk_fair_seeds DB table is retired.

local QBCore = exports['qb-core']:GetCoreObject()

-- Increment nonce + generate one game hash. Returns hash, nonce, serverSeedHash,
-- clientSeed — same contract as before, now from the engine. Returns nil on
-- engine outage (callers must abort the round / show maintenance).
function GenerateGameOutcomeSync(citizenid)
    local data = _G.EngineSync('/fair/outcome/' .. citizenid, 'POST', {})
    if not data or not data.hash then return nil end
    return data.hash, data.nonce, data.serverSeedHash, data.clientSeed
end

-- Async variant (kept for API compatibility). Runs the sync call in a thread.
function GenerateGameOutcome(citizenid, cb)
    CreateThread(function()
        local hash, nonce, ssh, cs = GenerateGameOutcomeSync(citizenid)
        cb(hash, nonce, ssh, cs)
    end)
end

-- NUI callbacks for fairness page
RegisterNetEvent('hk-sportsbetting:server:getFairness', function()
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    local citizenid = Player.PlayerData.citizenid

    local seed = _G.EngineSync('/fair/seed/' .. citizenid, 'GET')
    if not seed then return end
    TriggerClientEvent('hk-sportsbetting:client:fairnessData', src, {
        serverSeedHash = seed.serverSeedHash,
        clientSeed = seed.clientSeed,
        nonce = seed.nonce,
        history = seed.history or {},
    })
end)

RegisterNetEvent('hk-sportsbetting:server:rotateSeed', function()
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    local citizenid = Player.PlayerData.citizenid

    local res = _G.EngineSync('/fair/rotate/' .. citizenid, 'POST', {})
    if not res then return end
    if res.error then
        TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, {
            game = "fair", success = false, message = res.error
        })
        return
    end
    TriggerClientEvent('hk-sportsbetting:client:seedRotated', src, {
        revealedSeed = res.revealedSeed,
        newServerSeedHash = res.newHash,
    })
end)

RegisterNetEvent('hk-sportsbetting:server:setClientSeed', function(data)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    local citizenid = Player.PlayerData.citizenid
    local newSeed = tostring(data.seed or ""):sub(1, 64)
    if #newSeed < 1 then newSeed = "default" end

    local res = _G.EngineSync('/fair/client-seed/' .. citizenid, 'POST', { clientSeed = newSeed })
    if not res then return end
    if res.error then
        TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, {
            game = "fair", success = false, message = res.error
        })
        return
    end
    TriggerClientEvent('hk-sportsbetting:client:seedRotated', src, {
        revealedSeed = res.revealedSeed,
        newServerSeedHash = res.newServerSeedHash,
        clientSeed = res.clientSeed or newSeed,
    })
end)
