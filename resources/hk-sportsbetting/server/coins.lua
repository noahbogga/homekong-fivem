local function getIdentifier(src)
    local Player = exports['qb-core']:GetCoreObject().Functions.GetPlayer(src)
    if Player then
        return Player
    end
    return nil
end

function GetPlayerCash(src, cb)
    local Player = exports['qb-core']:GetCoreObject().Functions.GetPlayer(src)
    if not Player then
        cb(0)
        return
    end
    local cid = Player.PlayerData.citizenid
    if isDemoPlayer and isDemoPlayer(cid) then
        cb(demoGetBal and demoGetBal(cid) or 50000000)
        return
    end
    cb(Player.PlayerData.money.cash or 0)
end

function DeductCash(src, amount, cb)
    local Player = exports['qb-core']:GetCoreObject().Functions.GetPlayer(src)
    if not Player then
        cb(false)
        return
    end
    local cid = Player.PlayerData.citizenid
    if isDemoPlayer and isDemoPlayer(cid) then
        if demoGetBal and demoGetBal(cid) >= amount then
            demoRemove(cid, amount)
            cb(true)
        else
            cb(false)
        end
        return
    end
    if Player.PlayerData.money.cash < amount then
        cb(false)
        return
    end
    local ok = Player.Functions.RemoveMoney('cash', amount, 'sports-bet')
    cb(ok ~= false)
end

function AddCash(src, amount, cb)
    local Player = exports['qb-core']:GetCoreObject().Functions.GetPlayer(src)
    if not Player then
        cb(false)
        return
    end
    Player.Functions.AddMoney('cash', amount, 'sports-bet-win')
    cb(true)
end

exports('GetPlayerCash', GetPlayerCash)
exports('DeductCash', DeductCash)
exports('AddCash', AddCash)
