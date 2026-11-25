local QBCore = exports['qb-core']:GetCoreObject()
local Zone = nil
local TextShown = false
local AcitveZone = {}
local CurrentVehicle = {}
local SpawnZone = {}
local EntityZones = {}
local occasionVehicles = {}

-- Functions

local function spawnOccasionsVehicles(vehicles)
    if Zone then
        local oSlot = Config.Zones[Zone].VehicleSpots
        if not occasionVehicles[Zone] then occasionVehicles[Zone] = {} end
        if vehicles then
            for i = 1, #vehicles, 1 do
                local model = GetHashKey(vehicles[i].model)
                RequestModel(model)
                while not HasModelLoaded(model) do
                    Wait(0)
                end
                occasionVehicles[Zone][i] = { 
                    car   = CreateVehicle(model, oSlot[i].x, oSlot[i].y, oSlot[i].z, false, false),
                    loc   = vector3(oSlot[i].x, oSlot[i].y, oSlot[i].z),
                    price = vehicles[i].price,
                    owner = vehicles[i].seller,
                    model = vehicles[i].model,
                    plate = vehicles[i].plate,
                    oid   = vehicles[i].occasionid,
                    desc  = vehicles[i].description,
                    mods  = vehicles[i].mods
                }

                QBCore.Functions.SetVehicleProperties(occasionVehicles[Zone][i].car, json.decode(occasionVehicles[Zone][i].mods))

                SetModelAsNoLongerNeeded(model)
                SetVehicleOnGroundProperly(occasionVehicles[Zone][i].car)
                SetEntityInvincible(occasionVehicles[Zone][i].car, true)
                SetEntityHeading(occasionVehicles[Zone][i].car, oSlot[i].w)
                SetVehicleDoorsLocked(occasionVehicles[Zone][i].car, 3)
                SetVehicleNumberPlateText(occasionVehicles[Zone][i].car, occasionVehicles[Zone][i].oid)
                FreezeEntityPosition(occasionVehicles[Zone][i].car, true)
                if Config.UseTarget then
                    if not EntityZones then EntityZones = {} end
                    EntityZones[i] = exports['qb-target']:AddTargetEntity(occasionVehicles[Zone][i].car, {
                        options = {
                            {
                                type = 'client',
                                event = 'hk-vehiclesales:client:OpenContract',
                                icon = 'fas fa-car',
                                label = '檢視合約',
                                Contract = i
                            }
                        },
                        distance = 2.0
                    })
                end
            end
        end
    end
end

local function despawnOccasionsVehicles()
    if not Zone then return end
    local oSlot = Config.Zones[Zone].VehicleSpots
    for i = 1, #oSlot, 1 do
        local loc = oSlot[i]
        local oldVehicle = GetClosestVehicle(loc.x, loc.y, loc.z, 1.3, 0, 70)
        
        if oldVehicle then
            QBCore.Functions.DeleteVehicle(oldVehicle)
        end

        if EntityZones[i] and Config.UseTarget then
            exports['qb-target']:RemoveZone(EntityZones[i])
        end
    end
    EntityZones = {}
end

local function openSellContract(bool)
    local pData = QBCore.Functions.GetPlayerData()

    SetNuiFocus(bool, bool)
    SendNUIMessage({
        action = 'sellVehicle',
        showTakeBackOption = false,
        bizName = Config.Zones[Zone].BusinessName,
        sellerData = {
            firstname = pData.charinfo.firstname,
            lastname = pData.charinfo.lastname,
            account = pData.charinfo.account,
            phone = pData.charinfo.phone
        },
        plate = QBCore.Functions.GetPlate(GetVehiclePedIsUsing(PlayerPedId()))
    })
end

local function openBuyContract(sellerData, vehicleData)
    local pData = QBCore.Functions.GetPlayerData()
    SetNuiFocus(true, true)
    SendNUIMessage({
        action = 'buyVehicle',
        showTakeBackOption = sellerData.charinfo.firstname == pData.charinfo.firstname and sellerData.charinfo.lastname == pData.charinfo.lastname,
        bizName = Config.Zones[Zone].BusinessName,
        sellerData = {
            firstname = sellerData.charinfo.firstname,
            lastname = sellerData.charinfo.lastname,
            account = sellerData.charinfo.account,
            phone = sellerData.charinfo.phone
        },
        vehicleData = {
            desc = vehicleData.desc,
            price = vehicleData.price
        },
        plate = vehicleData.plate
    })
end

local function sellVehicleWait(price)
    DoScreenFadeOut(250)
    Wait(250)
    QBCore.Functions.DeleteVehicle(GetVehiclePedIsIn(PlayerPedId()))
    Wait(1500)
    DoScreenFadeIn(250)
    QBCore.Functions.Notify('你正在以 $'..price.. '拍賣出售你的載具', 'success')
    PlaySound(-1, 'SELECT', 'HUD_FRONTEND_DEFAULT_SOUNDSET', 0, 0, 1)
end

local function SellData(data, model)
    QBCore.Functions.TriggerCallback('hk-vehiclesales:server:CheckModelName', function(DataReturning) 
        local vehicleData = {}
        vehicleData.ent = GetVehiclePedIsUsing(PlayerPedId())
        vehicleData.model = DataReturning 
        vehicleData.plate = model
        vehicleData.mods = QBCore.Functions.GetVehicleProperties(vehicleData.ent)
        vehicleData.desc = data.desc
        TriggerServerEvent('hk-vehiclesales:server:sellVehicle', data.price, vehicleData)
        sellVehicleWait(data.price)
    end, model) --the older function GetDisplayNameFromVehicleModel doest like long names like Washington or Buccanner2
end

local listen = false
local function Listen4Control(spot) -- Uses this to listen for controls to open various menus.
    listen = true
    CreateThread(function()
        while listen do
            if IsControlJustReleased(0, 38) then -- E
                if spot then
                    local data = {Contract = spot}
                    TriggerEvent('hk-vehiclesales:client:OpenContract', data)
                else
                    if IsPedInAnyVehicle(PlayerPedId(), false) then
                        listen = false
                        TriggerEvent('hk-vehiclesales:client:MainMenu')
                        --TriggerEvent('hk-vehiclesales:client:SellVehicle')
                    else
                        QBCore.Functions.Notify('你並唔係載具入面!', 'error', 4500)
                    end
                end
            end
            Wait(0)
        end
    end)
end

---- ** Main Zone Functions ** ----

local function CreateZones()
    for k, v in pairs(Config.Zones) do
        local SellSpot = PolyZone:Create(v.PolyZone, {
            name = k,
            minZ = v.MinZ,
            maxZ = v.MaxZ,
            debugPoly = false
        })

        SellSpot:onPlayerInOut(function(isPointInside)
            if isPointInside and Zone ~= k then
                Zone = k
                QBCore.Functions.TriggerCallback('hk-vehiclesales:server:getVehicles', function(vehicles)
                    despawnOccasionsVehicles()
                    spawnOccasionsVehicles(vehicles)
                end)
            else
                despawnOccasionsVehicles()
                Zone = nil
            end
        end)
        AcitveZone[k] = SellSpot
    end
end

local function DeleteZones()
    for k in pairs(AcitveZone) do
        AcitveZone[k]:destroy()
    end
    AcitveZone = {}
end

local function IsCarSpawned(Car)
    local bool = false

    if occasionVehicles then
        for k in pairs(occasionVehicles[Zone]) do
            if k == Car then
                bool = true
                break
            end
        end
    end
    return bool
end

-- NUI Callbacks

RegisterNUICallback('sellVehicle', function(data, cb)
    local plate = QBCore.Functions.GetPlate(GetVehiclePedIsUsing(PlayerPedId())) --Getting the plate and sending to the function
    SellData(data, plate)
    cb('ok')
end)

RegisterNUICallback('close', function(_, cb)
    SetNuiFocus(false, false)
    cb('ok')
end)

RegisterNUICallback('buyVehicle', function(_, cb)
    TriggerServerEvent('hk-vehiclesales:server:buyVehicle', CurrentVehicle)
    cb('ok')
end)

RegisterNUICallback('takeVehicleBack', function(_, cb)
    TriggerServerEvent('hk-vehiclesales:server:ReturnVehicle', CurrentVehicle)
    cb('ok')
end)

-- Events

RegisterNetEvent('hk-vehiclesales:client:BuyFinished', function(vehdata)
    local vehmods = json.decode(vehdata.mods)

    DoScreenFadeOut(250)
    Wait(500)
    QBCore.Functions.TriggerCallback('QBCore:Server:SpawnVehicle', function(netId)
        local veh = NetToVeh(netId)
        SetEntityHeading(veh, Config.Zones[Zone].BuyVehicle.w)
        TaskWarpPedIntoVehicle(PlayerPedId(), veh, -1)
        SetVehicleFuelLevel(veh, 100)
        SetVehicleEngineOn(veh, true, true)
        -- APPLY MODS FIRST, then force the DB plate. qb mods carry a  field, so
        -- SetVehicleProperties RE-STAMPS the plate; running it AFTER SetOwner (as before)
        -- left the entity on the mods-plate while keys were granted for vehdata.plate =
        -- "not mine / can't lock" bug. Strip mods.plate and re-assert the canonical DB
        -- plate, THEN grant keys against it.
        if vehmods then vehmods.plate = nil end
        QBCore.Functions.SetVehicleProperties(veh, vehmods)
        Wait(300)
        SetVehicleNumberPlateText(veh, vehdata.plate)
        Wait(100)
        TriggerEvent('vehiclekeys:client:SetOwner', vehdata.plate)
        QBCore.Functions.Notify('已購買載具', 'success', 2500)
    end, vehdata.model, Config.Zones[Zone].BuyVehicle, true)
    Wait(500)
    DoScreenFadeIn(250)
    CurrentVehicle = {}
end)

RegisterNetEvent('hk-vehiclesales:client:SellBackCar', function()
    local ped = PlayerPedId()
    if IsPedInAnyVehicle(ped, false) then
        local vehicleData = {}
        local vehicle = GetVehiclePedIsIn(ped, false)
        vehicleData.model = GetEntityModel(vehicle)
        vehicleData.plate = QBCore.Functions.GetPlate(vehicle)
        for _, v in pairs(QBCore.Shared.Vehicles) do
            if v['hash'] == vehicleData.model then
                if v['homecoin'] then
                    QBCore.Functions.Notify('這載具不能出售', 'error', 3500)
                    return
                end
                break
            end
        end
        QBCore.Functions.TriggerCallback('hk-vehiclesales:server:checkVehicleOwner', function(owned, balance)
            if owned then
                if balance < 1 then
                    TriggerServerEvent('hk-vehiclesales:server:sellVehicleBack', vehicleData)
                    QBCore.Functions.DeleteVehicle(vehicle)
                else
                    QBCore.Functions.Notify('你要清左分期條數先可以賣..', 'error', 3500)
                end
            else
                QBCore.Functions.Notify('這不是你的載具..', 'error', 3500)
            end
        end, vehicleData.plate)
    else
        QBCore.Functions.Notify('你並唔係載具入面...', 'error', 4500)
    end
end)

RegisterNetEvent('hk-vehiclesales:client:ReturnOwnedVehicle', function(vehdata)
    local vehmods = json.decode(vehdata.mods)
    DoScreenFadeOut(250)
    Wait(500)
    QBCore.Functions.TriggerCallback('QBCore:Server:SpawnVehicle', function(netId)
        local veh = NetToVeh(netId)
        SetEntityHeading(veh, Config.Zones[Zone].BuyVehicle.w)
        TaskWarpPedIntoVehicle(PlayerPedId(), veh, -1)
        SetVehicleFuelLevel(veh, 100)
        SetVehicleEngineOn(veh, true, true)
        if vehmods then vehmods.plate = nil end
        QBCore.Functions.SetVehicleProperties(veh, vehmods)
        Wait(300)
        SetVehicleNumberPlateText(veh, vehdata.plate)
        Wait(100)
        TriggerEvent('vehiclekeys:client:SetOwner', vehdata.plate)
        QBCore.Functions.Notify('已退回載具')
    end, vehdata.model, Config.Zones[Zone].BuyVehicle, true)
    Wait(500)
    DoScreenFadeIn(250)
    CurrentVehicle = {}
end)

RegisterNetEvent('hk-vehiclesales:client:refreshVehicles', function()
    if Zone then
        QBCore.Functions.TriggerCallback('hk-vehiclesales:server:getVehicles', function(vehicles)
            despawnOccasionsVehicles()
            spawnOccasionsVehicles(vehicles)
        end)
    end
end)

RegisterNetEvent('hk-vehiclesales:client:SellVehicle', function()
    local vehicle = GetVehiclePedIsIn(PlayerPedId())
    local VehiclePlate = QBCore.Functions.GetPlate(vehicle)
    --[[local model = GetEntityModel(vehicle)
    for _, v in pairs(QBCore.Shared.Vehicles) do
        if v['hash'] == model then
            if v['homecoin'] then
                QBCore.Functions.Notify('這載具不能出售', 'error', 3500)
                return
            end
            break
        end
    end]]
    QBCore.Functions.TriggerCallback('hk-vehiclesales:server:checkVehicleOwner', function(owned, balance)
        if owned then
            if balance < 1 then
                QBCore.Functions.TriggerCallback('hk-vehiclesales:server:getVehicles', function(vehicles)
                    if vehicles == nil or #vehicles < #Config.Zones[Zone].VehicleSpots then
                        openSellContract(true)
                    else
                        QBCore.Functions.Notify('目前車場無位俾你賣車!', 'error', 3500)
                    end
                end)
            else
                QBCore.Functions.Notify('你要清左分期條數先可以賣..', 'error', 3500)
            end
        else
            QBCore.Functions.Notify('這不是你的載具', 'error', 3500)
        end
    end, VehiclePlate)
end)
            
RegisterNetEvent('hk-vehiclesales:client:OpenContract', function(data)
    CurrentVehicle = occasionVehicles[Zone][data.Contract]
    if CurrentVehicle then
        QBCore.Functions.TriggerCallback('hk-vehiclesales:server:getSellerInformation', function(info)
            if info then 
                info.charinfo = json.decode(info.charinfo)
            else
                info = {}
                info.charinfo = {
                    firstname = '未',
                    lastname = '知',
                    account = '未知戶口..',
                    phone = '未知電話號碼..'
                }
            end
                                        
            openBuyContract(info, CurrentVehicle)
        end, CurrentVehicle.owner)
    else
        QBCore.Functions.Notify('此載具為非賣品!', 'error', 7500)
    end
end)

RegisterNetEvent('hk-vehiclesales:client:MainMenu', function()
    local MainMenu = {
        {
            isMenuHeader = true,
            header = Config.Zones[Zone].BusinessName
        },
        {
            header = '放售載具',
            txt = '將此載具放售於車場, 給其他市民購買!',
            params = {
                event = 'hk-vehiclesales:client:SellVehicle',
            }
        },
        {
            header = '售賣給車場!',
            txt = '用一個較低的價錢直接出售你的車輛!',
            params = {
                event = 'hk-vehiclesales:client:SellBackCar',
            }
        }
    }

    exports['qb-menu']:openMenu(MainMenu)
end)

-- Threads

CreateThread(function()
    for _, cars in pairs(Config.Zones) do 
        local OccasionBlip = AddBlipForCoord(cars.SellVehicle.x, cars.SellVehicle.y, cars.SellVehicle.z)
        SetBlipSprite (OccasionBlip, 326)
        SetBlipDisplay(OccasionBlip, 4)
        SetBlipScale  (OccasionBlip, 0.75)
        SetBlipAsShortRange(OccasionBlip, true)
        SetBlipColour(OccasionBlip, 1)
        BeginTextCommandSetBlipName('STRING')
        AddTextComponentSubstringPlayerName('大昌行易手車')
        EndTextCommandSetBlipName(OccasionBlip)
    end
end)

CreateThread(function()
    for k, cars in pairs(Config.Zones) do
        SpawnZone[k] = CircleZone:Create(vector3(cars.SellVehicle.x, cars.SellVehicle.y, cars.SellVehicle.z), 3.0, {
            name='OCSell'..k,
            debugPoly = false,
        })

        SpawnZone[k]:onPlayerInOut(function(isPointInside)
            if isPointInside and IsPedInAnyVehicle(PlayerPedId(), false) then
                exports['qb-core']:DrawText('[E] 出售載具', 'left')
                TextShown = true
                Listen4Control()
            else
                listen = false
                if TextShown then
                    TextShown = false
                    exports['qb-core']:HideText()
                end
            end
        end)
        if not Config.UseTarget then
            for k2, v in pairs(Config.Zones[k].VehicleSpots) do
                local VehicleZones = BoxZone:Create(vector3(v.x, v.y, v.z), 4.3, 3.6, {
                    name='VehicleSpot'..k..k2,
                    debugPoly = false,
                    minZ = v.z-2, 
                    maxZ = v.z+2, 
                })
        
                VehicleZones:onPlayerInOut(function(isPointInside)
                    if isPointInside and IsCarSpawned(k2) then
                        exports['qb-core']:DrawText('[E] 檢視合約', 'left')
                        TextShown = true
                        Listen4Control(k2)
                    else
                        listen = false
                        if TextShown then
                            TextShown = false
                            exports['qb-core']:HideText()
                        end
                    end
                end)
            end
        end
    end
end)

---- ** Mostly just to ensure you can restart resources live without issues, also improves the code slightly. ** ----

RegisterNetEvent('QBCore:Client:OnPlayerLoaded', function()
    CreateZones()
end)

RegisterNetEvent('QBCore:Client:OnPlayerUnload', function()
    DeleteZones()
end)

AddEventHandler('onResourceStart', function(resourceName)
    if GetCurrentResourceName() == resourceName then
        CreateZones()
    end
end)

AddEventHandler('onResourceStop', function(resourceName)
    if GetCurrentResourceName() == resourceName then
        DeleteZones()
        despawnOccasionsVehicles()
    end
end)