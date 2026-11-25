local QBCore = exports['qb-core']:GetCoreObject()

-- Functions

local function generateOID()
    local num = math.random(1, 10) .. math.random(111, 999)

    return "OC" .. num
end

-- Callbacks

QBCore.Functions.CreateCallback('hk-vehiclesales:server:getVehicles', function(_, cb)
    local result = MySQL.query.await('SELECT * FROM occasion_vehicles', {})
    if result[1] then
        cb(result)
    else
        cb(nil)
    end
end)

QBCore.Functions.CreateCallback("hk-vehiclesales:server:getSellerInformation", function(_, cb, citizenid)
    MySQL.query('SELECT * FROM players WHERE citizenid = ?', {citizenid}, function(result)
        if result[1] then
            cb(result[1])
        else
            cb(nil)
        end
    end)
end)

QBCore.Functions.CreateCallback("hk-vehiclesales:server:CheckModelName", function(_, cb, plate)
    if plate then
        local ReturnData = MySQL.scalar.await("SELECT vehicle FROM player_vehicles WHERE plate = ?", {plate})
        cb(ReturnData)
    end
end)

-- Self-contained vehicle ownership check.
-- The original script relied on the old singular `qb-garage:server:checkVehicleOwner`
-- callback, which the installed `qb-garages` (plural) resource does not provide. With
-- no responder the callback hung silently and the sell contract never opened (no error
-- on client or server). Re-implemented here so vehiclesales no longer depends on it.
-- Returns: owned (bool), balance (number) -- balance > 0 means the car is still financed.
QBCore.Functions.CreateCallback('hk-vehiclesales:server:checkVehicleOwner', function(source, cb, plate)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then cb(false, 0) return end

    local result = MySQL.query.await('SELECT citizenid, balance FROM player_vehicles WHERE plate = ?', { plate })
    if result and result[1] and result[1].citizenid == Player.PlayerData.citizenid then
        cb(true, result[1].balance or 0)
    else
        cb(false, 0)
    end
end)

-- Events

RegisterNetEvent('hk-vehiclesales:server:ReturnVehicle', function(vehicleData)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    local result = MySQL.query.await('SELECT * FROM occasion_vehicles WHERE plate = ? AND occasionid = ?', {vehicleData['plate'], vehicleData["oid"]})
    if result[1] then
        if result[1].seller == Player.PlayerData.citizenid then
            MySQL.insert('INSERT INTO player_vehicles (license, citizenid, vehicle, hash, mods, plate, state) VALUES (?, ?, ?, ?, ?, ?, ?)', {Player.PlayerData.license, Player.PlayerData.citizenid, vehicleData["model"], joaat(vehicleData["model"]), vehicleData["mods"], vehicleData["plate"], 0})
            MySQL.query('DELETE FROM occasion_vehicles WHERE occasionid = ? AND plate = ?', {vehicleData["oid"], vehicleData['plate']})
            TriggerClientEvent("hk-vehiclesales:client:ReturnOwnedVehicle", src, result[1])
            TriggerClientEvent('hk-vehiclesales:client:refreshVehicles', -1)
        else
            TriggerClientEvent('QBCore:Notify', src, '此載具不屬於你', 'error', 3500)
        end
    else
        TriggerClientEvent('QBCore:Notify', src, '此載具不存在', 'error', 3500)
    end
end)

RegisterNetEvent('hk-vehiclesales:server:sellVehicle', function(vehiclePrice, vehicleData)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    MySQL.query('DELETE FROM player_vehicles WHERE plate = ? AND vehicle = ?',{vehicleData.plate, vehicleData.model})
    MySQL.insert('INSERT INTO occasion_vehicles (seller, price, description, plate, model, mods, occasionid) VALUES (?, ?, ?, ?, ?, ?, ?)',{Player.PlayerData.citizenid, vehiclePrice, vehicleData.desc, vehicleData.plate, vehicleData.model,json.encode(vehicleData.mods), generateOID()})
    TriggerEvent("qb-log:server:CreateLog", "vehicleshop", "放售二手車", "red", "**"..GetPlayerName(src) .. "** has a " .. vehicleData.model .. " priced at "..vehiclePrice)
    TriggerClientEvent('hk-vehiclesales:client:refreshVehicles', -1)
end)

RegisterNetEvent('hk-vehiclesales:server:sellVehicleBack', function(vehData)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    local price = 0
    local plate = vehData.plate
    for _, v in pairs(QBCore.Shared.Vehicles) do
        if v["hash"] == vehData.model then
            price = tonumber(v["price"])
            break
        end
    end
    local payout = math.floor(tonumber(price * 0.3)) -- This will give you half of the cars value
    Player.Functions.AddMoney('bank', payout, '出售汽車給二手車商')
    TriggerClientEvent('QBCore:Notify', src, '你已以 $'..payout.. '出售你的載具!', 'success', 5500)
    MySQL.query('DELETE FROM player_vehicles WHERE plate = ?', {plate})
end)

RegisterNetEvent('hk-vehiclesales:server:buyVehicle', function(vehicleData)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    local result = MySQL.query.await('SELECT * FROM occasion_vehicles WHERE plate = ? AND occasionid = ?',{vehicleData['plate'], vehicleData["oid"]})
    if result[1] and next(result[1]) then
        if Player.PlayerData.money.bank >= result[1].price then
            local SellerCitizenId = result[1].seller
            local SellerData = QBCore.Functions.GetPlayerByCitizenId(SellerCitizenId)
            -- New price calculation minus tax
            local NewPrice = math.ceil((result[1].price / 100) * 77)
            Player.Functions.RemoveMoney('bank', result[1].price, '購買二手車')
            -- Insert vehicle for buyer
            MySQL.insert(
                'INSERT INTO player_vehicles (license, citizenid, vehicle, hash, mods, plate, state) VALUES (?, ?, ?, ?, ?, ?, ?)', {
                    Player.PlayerData.license,
                    Player.PlayerData.citizenid, result[1]["model"],
                    GetHashKey(result[1]["model"]),
                    result[1]["mods"],
                    result[1]["plate"],
                    0
                })
            -- Handle money transfer
            if SellerData then
                -- Add money for online
                SellerData.Functions.AddMoney('bank', NewPrice, '成功放售汽車')
            else
                -- Add money for offline
                local BuyerData = MySQL.query.await('SELECT * FROM players WHERE citizenid = ?',{SellerCitizenId})
                if BuyerData[1] then
                    local BuyerMoney = json.decode(BuyerData[1].money)
                    BuyerMoney.bank = BuyerMoney.bank + NewPrice
                    MySQL.update('UPDATE players SET money = ? WHERE citizenid = ?', {json.encode(BuyerMoney), SellerCitizenId})
                end
            end
            TriggerEvent("qb-log:server:CreateLog", "vehicleshop", "買二手車", "green", "**"..GetPlayerName(src) .. "** has bought for "..result[1].price .. " (" .. result[1].plate .. ") from **"..SellerCitizenId.."**")
            TriggerClientEvent("hk-vehiclesales:client:BuyFinished", src, result[1])
            TriggerClientEvent('hk-vehiclesales:client:refreshVehicles', -1)
            -- Delete vehicle from Occasion
            MySQL.query('DELETE FROM occasion_vehicles WHERE plate = ? AND occasionid = ?',{result[1].plate, result[1].occasionid})
            -- Send selling mail to seller
            TriggerEvent('qb-phone:server:sendNewMailToOffline', SellerCitizenId, {
                sender = "大昌行",
                subject = "你的汽車已成功出售!",
                message = "你架 "..QBCore.Shared.Vehicles[result[1].model].name.." 已賣左 $"..NewPrice.."!"
            })
        else
            TriggerClientEvent('QBCore:Notify', src, '你沒有足夠金錢', 'error', 3500)
        end
    end
end)