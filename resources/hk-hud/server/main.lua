-- hk-hud — server
-- Stress server logic, ported from ps-hud (now retired/[unused]). Other
-- resources fire hud:server:GainStress/RelieveStress; we write qb metadata and
-- push hud:client:UpdateStress. GUARD: if ps-hud is somehow still started, we
-- skip registering so stress can't double-fire.
local QBCore = exports['qb-core']:GetCoreObject()

if GetResourceState('ps-hud') == 'started' then
    print('[hk-hud] ps-hud is started — NOT registering stress handlers (avoids double stress). Stop ps-hud.')
    return
end

local function clampStress(n)
    if n <= 0 then return 0 elseif n > 100 then return 100 end
    return n
end

RegisterNetEvent('hud:server:GainStress', function(amount)
    local src = source
    -- hk-race: racers never gain stress (hurts handling).
    if GetResourceState('hk-race') == 'started' and exports['hk-race']:IsRacing(src) then return end
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    if HKHudConfig.Stress.disablePoliceStress and Player.PlayerData.job.name == 'police' then return end
    local cur = Player.PlayerData.metadata['stress'] or 0
    local newStress = clampStress(cur + (amount or 0))
    Player.Functions.SetMetaData('stress', newStress)
    TriggerClientEvent('hud:client:UpdateStress', src, newStress)
end)

RegisterNetEvent('hud:server:RelieveStress', function(amount)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    local cur = Player.PlayerData.metadata['stress'] or 0
    local newStress = clampStress(cur - (amount or 0))
    Player.Functions.SetMetaData('stress', newStress)
    TriggerClientEvent('hud:client:UpdateStress', src, newStress)
end)

-- Push the saved stress to the client on load so the icon reflects reality.
RegisterNetEvent('QBCore:Server:PlayerLoaded', function(Player)
    local src = Player.PlayerData.source
    local stress = Player.PlayerData.metadata['stress'] or 0
    TriggerClientEvent('hud:client:UpdateStress', src, stress)
end)

-- /cash and /bank — show the money toast (ps-hud contract; hk-hud renders the
-- toast via hud:client:ShowAccounts). Registered here since ps-hud is retired.
QBCore.Commands.Add('cash', 'Check your cash balance', {}, false, function(source)
    local Player = QBCore.Functions.GetPlayer(source)
    if Player then TriggerClientEvent('hud:client:ShowAccounts', source, 'cash', Player.PlayerData.money.cash) end
end)
QBCore.Commands.Add('bank', 'Check your bank balance', {}, false, function(source)
    local Player = QBCore.Functions.GetPlayer(source)
    if Player then TriggerClientEvent('hud:client:ShowAccounts', source, 'bank', Player.PlayerData.money.bank) end
end)
