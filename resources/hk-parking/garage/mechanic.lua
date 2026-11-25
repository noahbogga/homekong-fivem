-- ═══════════════════════════════════════════════════════════ --
--   HK-GARAGE — Mechanic depot (tow → drop-off ring → impound)    --
--   A mechanic tows a player car, drives it into a depot drop     --
--   ring (green circle, mechanic-only) and presses E to impound    --
--   it (state 4). Requires being IN a tow truck. Mechanic earns a  --
--   flat fee now + a cut of the owner's retrieval fee later.       --
-- ═══════════════════════════════════════════════════════════ --

if not IsDuplicityVersion() then
    -- ══════════════ CLIENT ══════════════
    local QBCore = exports['qb-core']:GetCoreObject()

    local function isMechanic()
        local pd = QBCore.Functions.GetPlayerData()
        local job = pd and pd.job and pd.job.name
        return job and SV_Config.Mechanic.jobs[job] == true
    end

    local function inTowTruck()
        local ped = PlayerPedId()
        local veh = GetVehiclePedIsIn(ped, false)
        if veh == 0 then return false, nil end
        local model = GetEntityModel(veh)
        for name, on in pairs(Config.Impound.towTruckModels) do
            if on and GetHashKey(name) == model then return true, veh end
        end
        return false, veh
    end

    -- The car being towed = the closest vehicle to the tow truck that ISN'T the
    -- tow truck itself (i.e. the one loaded on the flatbed / attached behind).
    local function getTowedVehicle(towTruck)
        local coords = GetEntityCoords(towTruck)
        local best, bestDist = nil, 8.0
        for _, veh in ipairs(GetGamePool('CVehicle')) do
            if veh ~= towTruck and DoesEntityExist(veh) then
                local d = #(GetEntityCoords(veh) - coords)
                if d < bestDist then best, bestDist = veh, d end
            end
        end
        return best
    end

    -- FREE THE TOWED CAR. A parked car is migration-LOCKED + engine-off + (if clamped)
    -- frozen/undriveable — towing it that way makes the tow truck drag heavily and refuse
    -- to corner. While a mechanic sits in a tow truck, find the nearest parked car behind/
    -- on it and release those locks (migration on, undriveable off, unfreeze) so it tows
    -- like a normal vehicle. Cheap: only runs while actually in a tow truck.
    local towUnlocked = {}   -- netId -> true, so we only unlock each car once
    CreateThread(function()
        while true do
            local sleep = 1500
            if isMechanic() then
                local isTow, truck = inTowTruck()
                if isTow and truck then
                    sleep = 500
                    local towed = getTowedVehicle(truck)
                    if towed and DoesEntityExist(towed) then
                        local nId = NetworkGetNetworkIdFromEntity(towed)
                        if nId and nId ~= 0 and not towUnlocked[nId] then
                            local st = Entity(towed).state
                            if st and st.isParked and not st.isClamped then
                                SetNetworkIdCanMigrate(nId, true)
                                NetworkRequestControlOfEntity(towed)
                                SetVehicleUndriveable(towed, false)
                                FreezeEntityPosition(towed, false)
                                towUnlocked[nId] = true
                            end
                        end
                    end
                end
            end
            Wait(sleep)
        end
    end)

    -- Draw the green drop rings + handle E-to-drop, only for on-duty mechanics.
    CreateThread(function()
        while true do
            local sleep = 1000
            if isMechanic() then
                local pc = GetEntityCoords(PlayerPedId())
                for _, depot in ipairs(Config.Impound.depots) do
                    if #(pc - depot.drop) < 30.0 then
                        sleep = 0
                        DrawMarker(1, depot.drop.x, depot.drop.y, depot.drop.z - 1.0, 0,0,0, 0,0,0,
                            (Config.Impound.dropRadius*2), (Config.Impound.dropRadius*2), 1.5,
                            0, 220, 90, 120, false, false, 2, false)
                        if #(pc - depot.drop) < Config.Impound.dropRadius then
                            local isTow, truck = inTowTruck()
                            if isTow then
                                local towed = getTowedVehicle(truck)
                                if towed then
                                    HkHelpText('~g~[E]~w~ 卸下扣押車輛 · Drop off towed vehicle')
                                    if IsControlJustReleased(0, 38) then -- E
                                        local plate = QBCore.Functions.GetPlate(towed)
                                        local netId = NetworkGetNetworkIdFromEntity(towed)
                                        TriggerServerEvent('hk-garage:server:mechanicDropoff', plate, netId, depot.label)
                                    end
                                else
                                    HkHelpText('~y~附近冇拖住嘅車 · No towed vehicle nearby')
                                end
                            else
                                HkHelpText('~r~你要用拖車先得 · You must be in a tow truck')
                            end
                        end
                    end
                end
            end
            Wait(sleep)
        end
    end)

    function HkHelpText(text)
        SetTextComponentFormat('STRING')
        AddTextComponentString(text)
        DisplayHelpTextFromStringLabel(0, 0, 1, -1)
    end

    RegisterNetEvent('hk-garage:client:removeTowed', function(netId)
        local veh = NetworkGetEntityFromNetworkId(netId)
        if veh and DoesEntityExist(veh) then
            local tries = 0
            while NetworkGetEntityOwner(veh) ~= PlayerId() and tries < 20 do
                NetworkRequestControlOfEntity(veh); Wait(50); tries = tries + 1
            end
            QBCore.Functions.DeleteVehicle(veh)
        end
    end)
    return
end

-- ══════════════ SERVER ══════════════
local QBCore = exports['qb-core']:GetCoreObject()

-- Pay a tow mechanic by citizenid (flat fee on drop-off, and % cut on retrieval).
function PayTowMechanic(citizenid, amount, plate)
    if not citizenid or amount <= 0 then return end
    local target = QBCore.Functions.GetPlayerByCitizenId(citizenid)
    if target then
        target.Functions.AddMoney('bank', amount, 'hk-tow-payout')
        TriggerClientEvent('ox_lib:notify', target.PlayerData.source, { title = 'HK Parking', description = ('拖車分成 · Tow payout: $%s (%s)'):format(amount, plate or ''), type = 'success' })
    end
end

RegisterNetEvent('hk-garage:server:mechanicDropoff', function(plate, netId, depotLabel)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    local job = Player.PlayerData.job and Player.PlayerData.job.name
    if not (job and SV_Config.Mechanic.jobs[job]) then return end
    if not plate or not netId or netId <= 0 then return end
    plate = tostring(plate):gsub("^%s*(.-)%s*$", "%1"):upper()

    -- SERVER-SIDE validation (client-only checks are bypassable):
    -- 1) the netId entity must exist and its plate must MATCH the supplied plate
    --    (stops spoofing an arbitrary plate to impound a car you aren't towing).
    -- 2) the mechanic must be near a depot drop ring.
    -- 3) the mechanic must be in a tow truck near the towed car.
    local towed = NetworkGetEntityFromNetworkId(netId)
    if not towed or towed == 0 or not DoesEntityExist(towed) then return end
    local entPlate = GetVehicleNumberPlateText(towed):gsub("^%s*(.-)%s*$", "%1"):upper()
    if entPlate ~= plate then return end   -- entity/plate mismatch → reject

    local pcoords = GetEntityCoords(GetPlayerPed(src))
    -- near a depot drop ring?
    local nearDrop = false
    for _, dp in ipairs(Config.Impound.depots) do
        if #(pcoords - dp.drop) <= (Config.Impound.dropRadius or 5.0) + 3.0 then nearDrop = true break end
    end
    if not nearDrop then return end
    -- the towed car must actually be near the mechanic (on their truck)
    if #(pcoords - GetEntityCoords(towed)) > 12.0 then return end
    -- the mechanic must be in a tow truck
    local mVeh = GetVehiclePedIsIn(GetPlayerPed(src), false)
    local inTow = false
    if mVeh and mVeh ~= 0 then
        local m = GetEntityModel(mVeh)
        for name, on in pairs(SV_Config.Mechanic.towTrucks or Config.Impound.towTruckModels or {}) do
            if on and GetHashKey(name) == m then inTow = true break end
        end
    end
    if not inTow then
        TriggerClientEvent('ox_lib:notify', src, { title = 'HK Parking', description = '你要用拖車先得 · Need a tow truck', type = 'error' })
        return
    end

    -- Must be an owned player vehicle, and not already impounded.
    local owned = MySQL.single.await('SELECT plate, state FROM player_vehicles WHERE plate = ? LIMIT 1', { plate })
    if not owned then
        TriggerClientEvent('ox_lib:notify', src, { title = 'HK Parking', description = '呢架唔係玩家車 · Not a player vehicle', type = 'error' })
        return
    end
    if owned.state == 2 or owned.state == 4 then
        TriggerClientEvent('ox_lib:notify', src, { title = 'HK Parking', description = '架車已經扣咗 · Already impounded', type = 'error' })
        return
    end

    -- Impound to MECHANIC DEPOT (state 4) + record mechanic for the retrieval cut.
    MySQL.update('UPDATE player_vehicles SET state = 4, depotprice = ?, towedby = ? WHERE plate = ?',
        { SV_Config.ImpoundPrice, Player.PlayerData.citizenid, plate })

    -- Clear any street-parked spawn + delete the world entity.
    TriggerEvent('hk-parking:server:onImpound', plate)
    if netId and netId > 0 then TriggerClientEvent('hk-garage:client:removeTowed', src, netId) end

    local fee = SV_Config.Mechanic.towFee or 0
    if fee > 0 then Player.Functions.AddMoney('bank', fee, 'hk-tow-fee') end
    TriggerClientEvent('ox_lib:notify', src, { title = 'HK Parking', description = ('已卸入%s · Impounded %s (+$%s)'):format(depotLabel or '', plate, fee), type = 'success' })
end)
