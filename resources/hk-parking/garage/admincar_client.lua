-- ═══════════════════════════════════════════════════════════ --
--   HK-PARKING — /car override (client side)                      --
--   Collision-gated admin vehicle spawn. Mirrors qb-core's        --
--   QBCore:Command:SpawnVehicle but forces the map collision to   --
--   load and settles the car on the ground BEFORE warping the     --
--   admin in, so the ped can't free-fall through the seat.        --
-- ═══════════════════════════════════════════════════════════ --

RegisterNetEvent('hk-parking:client:adminCar', function(vehName)
    if not vehName or vehName == '' then
        QBCore.Functions.Notify('Usage: /car <model>', 'error')
        return
    end
    local ped = PlayerPedId()
    local hash = joaat(vehName)
    if not IsModelInCdimage(hash) then
        QBCore.Functions.Notify('Invalid vehicle model', 'error')
        return
    end

    RequestModel(hash)
    local mt = GetGameTimer()
    while not HasModelLoaded(hash) do
        if GetGameTimer() - mt > 5000 then
            QBCore.Functions.Notify('Failed to load vehicle model', 'error')
            return
        end
        Wait(0)
    end

    -- Replace any car the admin is currently sitting in (same as qb-core).
    local cur = GetVehiclePedIsUsing(ped)
    if IsPedInAnyVehicle(ped, false) and cur ~= 0 then
        SetEntityAsMissionEntity(cur, true, true)
        DeleteVehicle(cur)
    end

    local coords = GetEntityCoords(ped)
    local heading = GetEntityHeading(ped)
    local veh = CreateVehicle(hash, coords.x, coords.y, coords.z, heading, true, false)

    -- Wait for the entity to actually exist before we touch it.
    local et = GetGameTimer()
    while not DoesEntityExist(veh) do
        if GetGameTimer() - et > 2000 then
            QBCore.Functions.Notify('Vehicle failed to spawn', 'error')
            return
        end
        Wait(0)
    end

    SetVehicleHasBeenOwnedByPlayer(veh, true)
    SetNetworkIdCanMigrate(NetworkGetNetworkIdFromEntity(veh), true)
    SetVehicleNeedsToBeHotwired(veh, false)
    SetVehRadioStation(veh, 'OFF')
    SetVehicleFuelLevel(veh, 100.0)
    SetVehicleDirtLevel(veh, 0.0)

    -- COLLISION GATE: force map collision under the spawn point to stream in, then
    -- settle the car on it. Without this, SetVehicleOnGroundProperly no-ops on a
    -- not-yet-loaded tile and the warped ped free-falls through the world. Freeze
    -- while we wait so a client-owned car can't drift. 2s cap = never hangs /car.
    FreezeEntityPosition(veh, true)
    RequestCollisionAtCoord(coords.x, coords.y, coords.z)
    local ct = GetGameTimer()
    while not HasCollisionLoadedAroundEntity(veh) do
        RequestCollisionAtCoord(coords.x, coords.y, coords.z)
        if GetGameTimer() - ct > 2000 then break end
        Wait(0)
    end
    SetVehicleOnGroundProperly(veh)
    FreezeEntityPosition(veh, false)

    TaskWarpPedIntoVehicle(ped, veh, -1)
    local wt = 0
    while not IsPedInVehicle(ped, veh, false) and wt < 10 do
        TaskWarpPedIntoVehicle(ped, veh, -1)
        Wait(50)
        wt = wt + 1
    end

    SetModelAsNoLongerNeeded(hash)
    TriggerEvent('vehiclekeys:client:SetOwner', QBCore.Functions.GetPlate(veh))
end)
