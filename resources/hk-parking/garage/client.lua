local QBCore = exports['qb-core']:GetCoreObject()
local PlayerData = {}
local PlayerGang = {}
local PlayerJob = {}
local garageZones = {}
local listenForKey = false
-- HOMEKONG: re-entrancy guard for OpenGarageMenu. GetGarageVehicles is a network
-- round-trip (MariaDB lives on another VM, ~260-440ms). Without this, pressing [E]
-- again during that window queues a SECOND (and third) identical
-- "SELECT * FROM player_vehicles WHERE citizenid" -> stacked slow queries that
-- back up oxmysql's pool and stall the server. Latched true while a request is
-- in flight / the menu is open; cleared on open, error, or any close path.
local garageMenuBusy = false

-- Functions

local function CheckPlayers(vehicle)
    for i = -1, 5, 1 do
        local ped = GetPedInVehicleSeat(vehicle, i)
        -- GetPedInVehicleSeat returns 0 for an empty seat, and 0 is truthy in Lua —
        -- guard with DoesEntityExist so we only task-leave actual peds.
        if ped and ped ~= 0 and DoesEntityExist(ped) then
            TaskLeaveVehicle(ped, vehicle, 0)
        end
    end
    Wait(1500)
    QBCore.Functions.DeleteVehicle(vehicle)
end

local function OpenGarageMenu(data)
    -- Drop duplicate opens while a request is in flight or the menu is already up.
    if garageMenuBusy then return end
    garageMenuBusy = true
    local pc = GetEntityCoords(PlayerPedId())
    QBCore.Functions.TriggerCallback('hk-garage:server:GetGarageVehicles', function(result)
        if result == nil then
            garageMenuBusy = false
            return lib.notify({ title = 'HK Parking', description = Lang:t('error.no_vehicles'), type = 'error' })
        end
        local formattedVehicles = {}
        for _, v in pairs(result) do
            local enginePercent = QBCore.Shared.Round(v.engine, 0)
            local bodyPercent = QBCore.Shared.Round(v.body, 0)
            local vname, vbrand = nil, nil
            pcall(function()
                local vd = QBCore.Shared.Vehicles[v.vehicle]
                vname = vd and vd.name
                vbrand = vd and vd.brand
            end)
            -- AVAILABILITY: is this model still in the game (streamed/base)? If a
            -- car pack was removed, the model no longer exists -> IsModelInCdimage
            -- is false. We DON'T hide the row (owner keeps it in case we re-add the
            -- pack); the NUI greys it out and blocks take-out instead.
            local mhash = GetHashKey(v.vehicle)
            local available = IsModelInCdimage(mhash) and IsModelValid(mhash)
            formattedVehicles[#formattedVehicles + 1] = {
                vehicle = v.vehicle,
                vehicleLabel = vname or v.vehicle,
                available = available and true or false,
                brand = vbrand or '',
                plate = v.plate,
                state = v.state,
                fuel = v.fuel,
                engine = enginePercent,
                body = bodyPercent,
                distance = v.hk_dist or 0,
                garage = Config.Garages[data.indexgarage],
                type = data.type,
                index = data.indexgarage,
                depotPrice = v.depotprice or 0,
                balance = v.balance or 0,
                mods = v.mods,                     -- raw mods json (for the Installed Mods panel)
                -- HOMEKONG sectioning:
                section = v.hk_section,            -- 'here' | 'other' | 'impound' | 'street'
                waypoint = v.hk_waypoint,          -- {x,y} for locate button
                garageLabelOf = v.hk_garagelabel,  -- where the car actually is
                -- metadata (tier is classified client-side on the preview car):
                colour = v.hk_colour,
                drivetrain = v.hk_drivetrain,
            }
        end
        local subByType = { public = 'PUBLIC GARAGE', job = 'JOB GARAGE', gang = 'GANG GARAGE', depot = 'IMPOUND LOT', house = 'HOUSE GARAGE' }
        SetNuiFocus(true, true)
        SendNUIMessage({
            action = 'VehicleList',
            garageLabel = Config.Garages[data.indexgarage].label,
            garageSub = subByType[data.type] or 'HOMEKONG',
            vehicles = formattedVehicles,
        })
        -- Menu is up and NUI now owns input, so the [E] listener can no longer
        -- reach us. Safe to release the guard here; this also prevents it from
        -- latching stuck if the player later closes via ESC without a callback.
        garageMenuBusy = false
    end, data.indexgarage, data.type, data.category, { x = pc.x, y = pc.y, z = pc.z })
end

-- ADMIN PARKING: open the SAME garage NUI, populated with ALL of the admin's own
-- vehicles (any state/location). Sends admin=true so the NUI shows a spawn button
-- on every row and titles it accordingly. Take-out spawns at the admin's feet, free.
RegisterNetEvent('hk-garage:client:openAdminParking', function()
    if garageMenuBusy then return end
    garageMenuBusy = true
    QBCore.Functions.TriggerCallback('hk-garage:server:GetAdminVehicles', function(result)
        if result == nil then
            garageMenuBusy = false
            return lib.notify({ title = 'Admin Parking', description = 'No vehicles found (or not permitted).', type = 'error' })
        end
        local formattedVehicles = {}
        for _, v in pairs(result) do
            local vname, vbrand = nil, nil
            pcall(function()
                local vd = QBCore.Shared.Vehicles[v.vehicle]
                vname = vd and vd.name
                vbrand = vd and vd.brand
            end)
            local mhash = GetHashKey(v.vehicle)
            local available = IsModelInCdimage(mhash) and IsModelValid(mhash)
            formattedVehicles[#formattedVehicles + 1] = {
                vehicle = v.vehicle,
                vehicleLabel = vname or v.vehicle,
                available = available and true or false,
                brand = vbrand or '',
                plate = v.plate,
                state = v.state,
                fuel = v.fuel,
                engine = QBCore.Shared.Round(v.engine, 0),
                body = QBCore.Shared.Round(v.body, 0),
                distance = 0,
                garage = nil,                      -- admin spawns at player coords, no garage
                type = 'admin',
                index = nil,
                depotPrice = 0,
                balance = 0,
                mods = v.mods,
                section = 'here',                  -- everything takeable
                waypoint = nil,
                garageLabelOf = v.hk_garagelabel,  -- where it currently sits (info line)
                colour = v.hk_colour,
                drivetrain = v.hk_drivetrain,
            }
        end
        SetNuiFocus(true, true)
        SendNUIMessage({
            action = 'VehicleList',
            garageLabel = '管理員停車 · ADMIN PARKING',
            garageSub = 'ALL YOUR VEHICLES · SPAWN HERE FREE',
            admin = true,
            vehicles = formattedVehicles,
        })
        garageMenuBusy = false
    end)
end)

local function DepositVehicle(veh, data)
    local plate = QBCore.Functions.GetPlate(veh)
    QBCore.Functions.TriggerCallback('hk-garage:server:canDeposit', function(canDeposit)
        if canDeposit then
            local bodyDamage = math.ceil(GetVehicleBodyHealth(veh))
            local engineDamage = math.ceil(GetVehicleEngineHealth(veh))
            local totalFuel = exports[Config.FuelResource]:GetFuel(veh)
            -- Save FULL props to OUR table (qb-mechanicjob is unused/not running, so its
            -- SaveVehicleProps went nowhere -> mods were lost on store). This persists the
            -- current mods/paint/wheels so takeout spawns the correctly-modded car.
            TriggerServerEvent('hk-garage:server:saveVehicleProps', QBCore.Functions.GetVehicleProperties(veh))
            TriggerServerEvent('hk-garage:server:updateVehicleStats', plate, totalFuel, engineDamage, bodyDamage)
            CheckPlayers(veh)
            if plate then TriggerServerEvent('hk-garage:server:UpdateOutsideVehicle', plate, nil) end
            lib.notify({ title = 'HK Parking', description = Lang:t('success.vehicle_parked'), type = 'primary' })
        else
            lib.notify({ title = 'HK Parking', description = Lang:t('error.not_owned'), type = 'error' })
        end
    end, plate, data.type, data.indexgarage, 1)
end

local function IsVehicleAllowed(classList, vehicle)
    if not Config.ClassSystem then return true end
    for _, class in ipairs(classList) do
        if GetVehicleClass(vehicle) == class then
            return true
        end
    end
    return false
end

local function CreateBlips(setloc)
    local Garage = AddBlipForCoord(setloc.takeVehicle.x, setloc.takeVehicle.y, setloc.takeVehicle.z)
    SetBlipSprite(Garage, setloc.blipNumber)
    SetBlipDisplay(Garage, 4)
    SetBlipScale(Garage, 0.60)
    SetBlipAsShortRange(Garage, true)
    SetBlipColour(Garage, setloc.blipColor)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName(setloc.blipName)
    EndTextCommandSetBlipName(Garage)
end

local function CreateZone(index, garage, zoneType)
    local zone = CircleZone:Create(garage.takeVehicle, 10.0, {
        name = zoneType .. '_' .. index,
        debugPoly = false,
        useZ = true,
        data = {
            indexgarage = index,
            type = garage.type,
            category = garage.category
        }
    })

    return zone
end

local function CreateBlipsZones()
    PlayerData = QBCore.Functions.GetPlayerData()
    PlayerGang = PlayerData.gang
    PlayerJob = PlayerData.job

    for index, garage in pairs(Config.Garages) do
        local zone
        if garage.showBlip then
            CreateBlips(garage)
        end
        if garage.type == 'job' and (PlayerJob.name == garage.job or PlayerJob.type == garage.jobType) then
            zone = CreateZone(index, garage, 'job')
        elseif garage.type == 'gang' and PlayerGang.name == garage.job then
            zone = CreateZone(index, garage, 'gang')
        -- NOTE: 'depot' type garages are intentionally NOT zoned here — the new
        -- impound system (Config.Impound.depots in garage/impound.lua) owns depot
        -- pickups. Leaving these would create a 2nd competing [E] prompt at the
        -- same coords (impoundlot vs Depot A collision).
        elseif garage.type == 'public' then
            zone = CreateZone(index, garage, 'public')
        end

        if zone then
            garageZones[#garageZones + 1] = zone
        end
    end

    local comboZone = ComboZone:Create(garageZones, { name = 'garageCombo', debugPoly = false })

    comboZone:onPlayerInOut(function(isPointInside, _, zone)
        if isPointInside then
            listenForKey = true
            CreateThread(function()
                while listenForKey do
                    Wait(0)
                    if IsControlJustReleased(0, 38) then
                        if GetVehiclePedIsUsing(PlayerPedId()) ~= 0 then
                            if zone.data.type == 'depot' then return end
                            local currentVehicle = GetVehiclePedIsUsing(PlayerPedId())
                            if not IsVehicleAllowed(zone.data.category, currentVehicle) then
                                lib.notify({ title = 'HK Parking', description = Lang:t('error.not_correct_type'), type = 'error' })
                                return
                            end
                            DepositVehicle(currentVehicle, zone.data)
                        else
                            OpenGarageMenu(zone.data)
                        end
                    end
                end
            end)

            local displayText = Lang:t('info.car_e')
            if zone.data.vehicle == 'sea' then
                displayText = Lang:t('info.sea_e')
            elseif zone.data.vehicle == 'air' then
                displayText = Lang:t('info.air_e')
            elseif zone.data.vehicle == 'rig' then
                displayText = Lang:t('info.rig_e')
            elseif zone.data.type == 'depot' then
                displayText = Lang:t('info.depot_e')
            end
            exports['qb-core']:DrawText(displayText, 'left')
        else
            listenForKey = false
            exports['qb-core']:HideText()
        end
    end)
end

local function doCarDamage(currentVehicle, stats, props)
    stats = stats or {}
    -- Default to full health when stats are absent (impound/depot retrieval passes
    -- stats = {}). Missing engine/body were crashing here with "arithmetic on nil",
    -- which aborted the whole spawn thread -> the warp never ran.
    local engine = (stats.engine or 1000.0) + 0.0
    local body = (stats.body or 1000.0) + 0.0
    SetVehicleEngineHealth(currentVehicle, engine)
    SetVehicleBodyHealth(currentVehicle, body)
    if not props or not next(props) then return end
    if props.doorStatus then
        for k, v in pairs(props.doorStatus) do
            if v then SetVehicleDoorBroken(currentVehicle, tonumber(k), true) end
        end
    end
    if props.tireBurstState then
        for k, v in pairs(props.tireBurstState) do
            if v then SetVehicleTyreBurst(currentVehicle, tonumber(k), true) end
        end
    end
    if props.windowStatus then
        for k, v in pairs(props.windowStatus) do
            if not v then SmashVehicleWindow(currentVehicle, tonumber(k)) end
        end
    end
end

function GetSpawnPoint(garage)
    local location = nil
    -- Guard: a garage/house/impound config missing spawnPoint would crash on #nil.
    if not garage or type(garage.spawnPoint) ~= 'table' then
        lib.notify({ title = 'HK Parking', description = Lang:t('error.vehicle_occupied'), type = 'error' })
        return nil
    end
    if #garage.spawnPoint > 1 then
        local maxTries = #garage.spawnPoint
        for _ = 1, maxTries do
            local randomIndex = math.random(1, #garage.spawnPoint)
            local chosenSpawnPoint = garage.spawnPoint[randomIndex]
            local isOccupied = IsPositionOccupied(
                chosenSpawnPoint.x,
                chosenSpawnPoint.y,
                chosenSpawnPoint.z,
                5.0,   -- range
                false,
                true,  -- checkVehicles
                false, -- checkPeds
                false,
                false,
                0,
                false
            )
            if not isOccupied then
                location = chosenSpawnPoint
                break
            end
        end
    elseif #garage.spawnPoint == 1 then
        location = garage.spawnPoint[1]
    end
    if not location then
        lib.notify({ title = 'HK Parking', description = Lang:t('error.vehicle_occupied'), type = 'error' })
    end
    return location
end

-- NUI Callbacks

RegisterNUICallback('closeGarage', function(_, cb)
    if Preview then Preview.Stop() end
    SetNuiFocus(false, false)
    garageMenuBusy = false
    cb('ok')
end)

RegisterNUICallback('takeOutVehicle', function(data, cb)
    if Preview then Preview.Stop() end
    SetNuiFocus(false, false)
    garageMenuBusy = false
    TriggerEvent('hk-garage:client:takeOutGarage', data)
    cb('ok')
end)

RegisterNUICallback('trackVehicle', function(plate, cb)
    TriggerServerEvent('hk-garage:server:trackVehicle', plate)
    cb('ok')
end)

-- HOMEKONG: set a GPS waypoint straight to a car's garage / street location and
-- fully close the menu (release focus + stop preview). Fixes the hung-cursor bug
-- where the panel hid but NUI focus stayed captured.
RegisterNUICallback('locateVehicle', function(data, cb)
    if Preview then Preview.Stop() end
    SetNuiFocus(false, false)
    garageMenuBusy = false
    if data and data.waypoint and data.waypoint.x then
        SetNewWaypoint(data.waypoint.x + 0.0, data.waypoint.y + 0.0)
        lib.notify({ title = 'HK Parking', description = Lang:t('success.vehicle_tracked'), type = 'success' })
    else
        lib.notify({ title = 'HK Parking', description = Lang:t('error.vehicle_not_tracked'), type = 'error' })
    end
    cb('ok')
end)

-- HK-Garage: live 3D preview. NUI keeps focus so the overlay (Drive/Back +
-- rotate hint) stays interactive; the car spins on a hidden pad behind it.
RegisterNUICallback('previewVehicle', function(data, cb)
    if Preview and Preview.Start(data) then
        cb('ok')
    else
        cb('error')
    end
end)

RegisterNUICallback('closePreview', function(_, cb)
    if Preview then Preview.Stop() end
    cb('ok')
end)

-- NUI drag → rotate the preview turntable by a degree delta.
RegisterNUICallback('previewRotate', function(data, cb)
    if Preview and data and data.delta then Preview.Rotate(data.delta + 0.0) end
    cb('ok')
end)

-- Retrieve an impound/depot car → pay + spawn at the pickup point + warp in.
RegisterNUICallback('retrieveImpound', function(data, cb)
    if Preview then Preview.Stop() end
    SetNuiFocus(false, false)
    garageMenuBusy = false
    -- Fall back to the client-side stashed spawn if the NUI didn't round-trip it
    -- cleanly (spawn is a coords table; a bad one = car spawns at 0,0,0 / warp fails).
    local spawn = data.spawn
    if type(spawn) ~= 'table' or spawn.x == nil then spawn = lastImpoundSpawn end
    TriggerServerEvent('hk-garage:server:retrieveImpound', data.plate, data.kind, spawn)
    cb('ok')
end)


RegisterNUICallback('drivePreview', function(data, cb)
    if Preview then Preview.Stop() end
    SetNuiFocus(false, false)
    garageMenuBusy = false
    TriggerEvent('hk-garage:client:takeOutGarage', data)
    cb('ok')
end)

-- ADMIN: permanently delete one of your own cars from the /adminparking menu.
-- The NUI already confirmed (two-step button). We ask the server (admin-gated,
-- own-cars-only) to drop the row, then re-open the admin menu so the list refreshes.
RegisterNUICallback('adminDeleteVehicle', function(data, cb)
    local plate = data and data.plate
    if not plate then cb('ok') return end
    QBCore.Functions.TriggerCallback('hk-garage:server:adminDeleteVehicle', function(ok)
        if ok then
            lib.notify({ title = 'Admin Parking', description = ('已刪除 · Deleted %s'):format(plate), type = 'success' })
            -- Refresh the menu in place so the deleted car drops out of the list.
            garageMenuBusy = false
            TriggerEvent('hk-garage:client:openAdminParking')
        else
            lib.notify({ title = 'Admin Parking', description = '刪除失敗 · Delete failed', type = 'error' })
        end
    end, plate)
    cb('ok')
end)

-- ADMIN: despawn a car by plate if it's currently streamed on this client (so a
-- deleted-from-DB car doesn't linger keyless in the world). Best-effort scan.
RegisterNetEvent('hk-garage:client:adminDespawnPlate', function(plate)
    if type(plate) ~= 'string' or plate == '' then return end
    local target = plate:gsub('%s+', ''):upper()
    for _, veh in ipairs(GetGamePool('CVehicle')) do
        if DoesEntityExist(veh) then
            local p = GetVehicleNumberPlateText(veh)
            if p and p:gsub('%s+', ''):upper() == target then
                SetEntityAsMissionEntity(veh, true, true)
                DeleteVehicle(veh)
            end
        end
    end
end)

RegisterNUICallback('takeOutDepo', function(data, cb)
    if Preview then Preview.Stop() end
    SetNuiFocus(false, false)
    garageMenuBusy = false
    local depotPrice = data.depotPrice
    if depotPrice ~= 0 then
        TriggerServerEvent('hk-garage:server:PayDepotPrice', data)
    else
        TriggerEvent('hk-garage:client:takeOutGarage', data)
    end
    cb('ok')
end)

-- Events

RegisterNetEvent('hk-garage:client:trackVehicle', function(coords)
    SetNewWaypoint(coords.x, coords.y)
end)

local function CheckPlate(vehicle, plateToSet)
    local vehiclePlate = promise.new()
    CreateThread(function()
        SetVehicleNumberPlateText(vehicle, plateToSet)
        Wait(100) -- Single short wait
        
        local attempts = 0
        while attempts < 5 do -- Only 5 attempts (500ms total)
            if GetVehicleNumberPlateText(vehicle) == plateToSet then
                vehiclePlate:resolve(true)
                return
            end
            Wait(100)
            attempts = attempts + 1
        end
        -- Force accept and continue (plate will sync eventually)
        vehiclePlate:resolve(true)
    end)
    return vehiclePlate
end

RegisterNetEvent('hk-garage:client:takeOutGarage', function(data)
  -- UNAVAILABLE MODEL GUARD: if this car's model was removed from the server
  -- (e.g. a car pack pulled), don't attempt the spawn — it would just spin the
  -- model-load timeout then fail confusingly. Tell the player it's temporarily
  -- unavailable; the row stays in their garage for when we re-add the pack.
  if data.vehicle then
    local h = GetHashKey(data.vehicle)
    if not (IsModelInCdimage(h) and IsModelValid(h)) then
        lib.notify({ title = 'HK Parking', description = '此車輛暫時無法使用 · This vehicle is currently unavailable', type = 'error' })
        return
    end
  end
  -- Impound/depot retrieval already charged the flat fee in retrieveImpound —
  -- skip the garage storage fee (would double-charge / block the spawn).
  local isAdmin  = (data.type == 'admin')
  local skipFee  = (data.type == 'impound') or isAdmin
  local isImpound = (data.type == 'impound')

  -- The actual spawn. Called directly for impound/depot (already validated by
  -- retrieveImpound), or behind IsSpawnOk for a normal garage take-out.
  local function doSpawn()
            -- Admin: spawn at the player's feet (a bit ahead), not a fixed garage pad.
            local location
            if isAdmin then
                local ped = PlayerPedId()
                local fwd = GetEntityForwardVector(ped)
                local pc  = GetEntityCoords(ped)
                location = { x = pc.x + fwd.x * 3.0, y = pc.y + fwd.y * 3.0, z = pc.z, w = GetEntityHeading(ped) }
            else
                location = GetSpawnPoint(data.garage)
            end
            if not location then return end

            -- (Model loading happens inside the callback below, against the DB-verified
            -- model — including RequestCollisionAtCoord so the ground is present.)
            -- Server VALIDATES ownership + charges the fee, then returns the DB model
            -- + props. We spawn CLIENT-SIDE (CreateVehicle) so THIS client is instantly
            -- the entity owner with collision loaded where it stands — no ServerSetter
            -- owner-bounce, no fall-through. netId is reported back for tracking.
            -- Admin take-out uses a separate server callback that skips fees/ownership
            -- fee logic and only needs the plate; normal take-out passes plate+vehicle+coords.
            local spawnCbName = isAdmin and 'hk-garage:server:adminSpawnVehicle' or 'hk-garage:server:spawnvehicle'
            local function onSpawnCb(ok, properties, vehPlate, model)
                if not ok then
                    lib.notify({ title = 'HK Parking', description = 'Failed to spawn vehicle', type = 'error' })
                    return
                end

                local spawnModel = GetHashKey(model or data.vehicle)
                -- Request collision at the spawn point + the model, so the ground is
                -- physically present the instant the car appears (no fall-through).
                RequestModel(spawnModel)
                RequestCollisionAtCoord(location.x, location.y, location.z)
                local mt = 0
                while not HasModelLoaded(spawnModel) and mt < 1500 do
                    RequestModel(spawnModel); Wait(10); mt = mt + 1
                end
                if not HasModelLoaded(spawnModel) then
                    lib.notify({ title = 'HK Parking', description = '車輛模型載入超時，請重試 · Model load timed out, try again', type = 'error' })
                    return
                end

                -- CLIENT-SIDE spawn: this client owns it immediately.
                local veh = CreateVehicle(spawnModel, location.x, location.y, location.z, location.w or 0.0, true, false)
                local t0 = 0
                while not DoesEntityExist(veh) and t0 < 100 do Wait(10); t0 = t0 + 1 end
                if not DoesEntityExist(veh) then
                    lib.notify({ title = 'HK Parking', description = 'Vehicle entity failed to exist', type = 'error' })
                    return
                end

                local netId = NetworkGetNetworkIdFromEntity(veh)
                SetNetworkIdExistsOnAllMachines(netId, true)
                SetNetworkIdCanMigrate(netId, true)
                SetEntityAsMissionEntity(veh, true, true)

                -- COLLISION GATE: SetVehicleOnGroundProperly silently no-ops if the
                -- map collision under the spawn point hasn't streamed yet, so the car
                -- (and any ped we warp in) can free-fall through the world = the
                -- "sitting ped sinks / surroundings go low-res" desync. Freeze the car,
                -- force the collision to load, THEN settle it. 2s hard cap so a truly
                -- un-streamable spot never hangs the take-out.
                FreezeEntityPosition(veh, true)
                RequestCollisionAtCoord(location.x, location.y, location.z)
                local colT = GetGameTimer()
                while not HasCollisionLoadedAroundEntity(veh) do
                    RequestCollisionAtCoord(location.x, location.y, location.z)
                    if GetGameTimer() - colT > 2000 then break end
                    Wait(0)
                end
                SetVehicleOnGroundProperly(veh)
                FreezeEntityPosition(veh, false)

                -- Plate
                SetVehicleNumberPlateText(veh, vehPlate)
                Citizen.Await(CheckPlate(veh, vehPlate))

                -- Properties (strip stored health — DB body/engine columns own health,
                -- applied by doCarDamage below).
                if properties and next(properties) then
                    properties.bodyHealth, properties.engineHealth, properties.tankHealth = nil, nil, nil
                    QBCore.Functions.SetVehicleProperties(veh, properties)
                    Wait(50)
                    -- re-assert the DB plate after props (props may restamp it)
                    SetVehicleNumberPlateText(veh, vehPlate)
                    Citizen.Await(CheckPlate(veh, vehPlate))
                end

                if data.stats and data.stats.fuel then
                    exports[Config.FuelResource]:SetFuel(veh, data.stats.fuel)
                end
                if Config.VisuallyDamageCars and data.stats then
                    doCarDamage(veh, data.stats, properties)
                end
                SetVehicleEngineOn(veh, true, true, false)

                -- GHOST MODE (spawn-point clearance). Client-owned + collision-loaded now,
                -- so no fall-through — this is purely to avoid stacking on a car already
                -- parked on the pad. Translucent + pass-through-vehicles + invincible, held
                -- while within the spawn radius, dropped 3s after driving clear.
                local ghostVeh = veh
                local ghostCoords = location
                local function applyGhost()
                    if not DoesEntityExist(ghostVeh) then return end
                    for _, other in ipairs(GetGamePool('CVehicle')) do
                        if other ~= ghostVeh and DoesEntityExist(other) then
                            SetEntityNoCollisionEntity(ghostVeh, other, true)
                        end
                    end
                end
                SetEntityInvincible(ghostVeh, true)
                SetEntityAlpha(ghostVeh, 150, false)
                applyGhost()
                CreateThread(function()
                    local RADIUS = 6.0
                    local clearedAt = 0
                    local hardCap = GetGameTimer() + 15000
                    while DoesEntityExist(ghostVeh) do
                        applyGhost()
                        local vc = GetEntityCoords(ghostVeh)
                        local inside = ghostCoords and #(vc - vector3(ghostCoords.x, ghostCoords.y, ghostCoords.z)) < RADIUS
                        if inside then clearedAt = 0
                        else
                            if clearedAt == 0 then clearedAt = GetGameTimer() end
                            if GetGameTimer() - clearedAt >= 3000 then break end
                        end
                        if GetGameTimer() > hardCap then break end
                        if clearedAt == 0 then Wait(0) else Wait(150) end
                    end
                    if DoesEntityExist(ghostVeh) then
                        SetEntityInvincible(ghostVeh, false)
                        ResetEntityAlpha(ghostVeh)
                        for _, other in ipairs(GetGamePool('CVehicle')) do
                            if other ~= ghostVeh and DoesEntityExist(other) then
                                SetEntityNoCollisionEntity(ghostVeh, other, false)
                            end
                        end
                    end
                end)

                -- Warp — safe now (client owns the car, collision loaded, on ground).
                if Config.Warp then
                    TaskWarpPedIntoVehicle(PlayerPedId(), veh, -1)
                    local warpAttempts = 0
                    while not IsPedInVehicle(PlayerPedId(), veh, false) and warpAttempts < 10 do
                        TaskWarpPedIntoVehicle(PlayerPedId(), veh, -1)
                        Wait(50)
                        warpAttempts = warpAttempts + 1
                    end
                end

                -- DB state + tracking + keys.
                if data.impoundConfirm then
                    TriggerServerEvent('hk-garage:server:confirmImpoundRetrieve', data.impoundConfirm.plate, data.impoundConfirm.kind)
                else
                    TriggerServerEvent('hk-garage:server:updateVehicleState', 0, vehPlate)
                end
                TriggerServerEvent('hk-garage:server:UpdateOutsideVehicle', vehPlate, netId)
                TriggerEvent('vehiclekeys:client:SetOwner', vehPlate)

                SetModelAsNoLongerNeeded(spawnModel)
                lib.notify({ title = 'HK Parking', description = 'Vehicle taken out successfully', type = 'success' })
            end
            if isAdmin then
                -- adminSpawnVehicle signature: (source, cb, plate) — no fee, own cars only
                QBCore.Functions.TriggerCallback(spawnCbName, onSpawnCb, data.plate)
            else
                QBCore.Functions.TriggerCallback(spawnCbName, onSpawnCb, data.plate, data.vehicle, location, true)
            end
  end -- doSpawn()

  local function proceed()
    -- Impound/depot: already validated by retrieveImpound (state 2/4), and the
    -- car is NOT "out" — so DON'T gate on IsSpawnOk (its stale OutsideVehicles
    -- entry from before the car wrecked would wrongly reject the retrieval). Spawn
    -- directly. Normal garage take-out still gets the already-out dupe guard.
    if isImpound or isAdmin then
        doSpawn()
        return
    end
    QBCore.Functions.TriggerCallback('hk-garage:server:IsSpawnOk', function(spawn)
        if spawn then
            doSpawn()
        else
            lib.notify({ title = 'HK Parking', description = Lang:t('error.not_depot'), type = 'error' })
        end
    end, data.plate, data.type)
  end -- proceed()

  if skipFee then
    proceed()
  else
    -- Normal garage take-out: charge the storage fee first; abort if unpaid.
    QBCore.Functions.TriggerCallback('hk-garage:server:chargeGarageFee', function(feeRes)
        if not feeRes or not feeRes.ok then return end
        proceed()
    end, data.plate)
  end
end)

-- Housing calls

local houseGarageZones = {}
local listenForKeyHouse = false
local houseComboZones = nil

local function CreateHouseZone(index, garage, zoneType)
    local houseZone = CircleZone:Create(garage.takeVehicle, 5.0, {
        name = zoneType .. '_' .. index,
        debugPoly = false,
        useZ = true,
        data = {
            indexgarage = index,
            type = zoneType,
            category = garage.category
        }
    })

    if houseZone then
        houseGarageZones[#houseGarageZones + 1] = houseZone

        if not houseComboZones then
            houseComboZones = ComboZone:Create(houseGarageZones, { name = 'houseComboZones', debugPoly = false })
        else
            houseComboZones:AddZone(houseZone)
        end
    end

    houseComboZones:onPlayerInOut(function(isPointInside, _, zone)
        if isPointInside then
            listenForKeyHouse = true
            CreateThread(function()
                while listenForKeyHouse do
                    Wait(0)
                    if IsControlJustReleased(0, 38) then
                        if GetVehiclePedIsUsing(PlayerPedId()) ~= 0 then
                            local currentVehicle = GetVehiclePedIsUsing(PlayerPedId())
                            DepositVehicle(currentVehicle, zone.data)
                        else
                            OpenGarageMenu(zone.data)
                        end
                    end
                end
            end)
            exports['qb-core']:DrawText(Lang:t('info.house_garage'), 'left')
        else
            listenForKeyHouse = false
            exports['qb-core']:HideText()
        end
    end)
end

local function ZoneExists(zoneName)
    for _, zone in ipairs(houseGarageZones) do
        if zone.name == zoneName then
            return true
        end
    end
    return false
end

local function RemoveHouseZone(zoneName)
    local removedZone = houseComboZones:RemoveZone(zoneName)
    if removedZone then
        removedZone:destroy()
    end
    for index, zone in ipairs(houseGarageZones) do
        if zone.name == zoneName then
            table.remove(houseGarageZones, index)
            break
        end
    end
end

RegisterNetEvent('hk-garage:client:setHouseGarage', function(house, hasKey)
    if not house then return end
    local formattedHouseName = string.gsub(string.lower(house), ' ', '')
    local zoneName = 'house_' .. formattedHouseName
    if Config.Garages[formattedHouseName] then
        if hasKey and not ZoneExists(zoneName) then
            CreateHouseZone(formattedHouseName, Config.Garages[formattedHouseName], 'house')
        elseif not hasKey and ZoneExists(zoneName) then
            RemoveHouseZone(zoneName)
        end
    else
        QBCore.Functions.TriggerCallback('hk-garage:server:getHouseGarage', function(garageInfo)
            if not garageInfo.garage then return end
            local garageCoords = json.decode(garageInfo.garage)
            Config.Garages[formattedHouseName] = {
                houseName = house,
                takeVehicle = vector3(garageCoords.x, garageCoords.y, garageCoords.z),
                spawnPoint = {
                    vector4(garageCoords.x, garageCoords.y, garageCoords.z, garageCoords.w or garageCoords.h)
                },
                label = garageInfo.label,
                type = 'house',
                category = Config.VehicleClass['all']
            }
            TriggerServerEvent('hk-garage:server:syncGarage', Config.Garages)
        end, house)
    end
end)

RegisterNetEvent('hk-garage:client:houseGarageConfig', function(houseGarages)
    for houseName, garageConfig in pairs(houseGarages) do
        local formattedHouseName = string.gsub(string.lower(garageConfig.label), ' ', '')
        if garageConfig.takeVehicle and garageConfig.takeVehicle.x and garageConfig.takeVehicle.y and garageConfig.takeVehicle.z and garageConfig.takeVehicle.w then
            Config.Garages[formattedHouseName] = {
                houseName = houseName,
                takeVehicle = vector3(garageConfig.takeVehicle.x, garageConfig.takeVehicle.y, garageConfig.takeVehicle.z),
                spawnPoint = {
                    vector4(garageConfig.takeVehicle.x, garageConfig.takeVehicle.y, garageConfig.takeVehicle.z, garageConfig.takeVehicle.w)
                },
                label = garageConfig.label,
                type = 'house',
                category = Config.VehicleClass['all']
            }
        end
    end
    TriggerServerEvent('hk-garage:server:syncGarage', Config.Garages)
end)

RegisterNetEvent('hk-garage:client:addHouseGarage', function(house, garageInfo)
    local formattedHouseName = string.gsub(string.lower(house), ' ', '')
    Config.Garages[formattedHouseName] = {
        houseName = house,
        takeVehicle = vector3(garageInfo.takeVehicle.x, garageInfo.takeVehicle.y, garageInfo.takeVehicle.z),
        spawnPoint = {
            vector4(garageInfo.takeVehicle.x, garageInfo.takeVehicle.y, garageInfo.takeVehicle.z, garageInfo.takeVehicle.w)
        },
        label = garageInfo.label,
        type = 'house',
        category = Config.VehicleClass['all']
    }
    TriggerServerEvent('hk-garage:server:syncGarage', Config.Garages)
end)

-- Handlers

AddEventHandler('QBCore:Client:OnPlayerLoaded', function()
    CreateBlipsZones()
end)

AddEventHandler('onResourceStart', function(res)
    if res ~= GetCurrentResourceName() then return end
    CreateBlipsZones()
end)

-- Safety: never leave a preview entity/camera behind on resource stop.
AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    if Preview then Preview.Stop() end
end)

RegisterNetEvent('QBCore:Client:OnGangUpdate', function(gang)
    PlayerGang = gang
end)

RegisterNetEvent('QBCore:Client:OnJobUpdate', function(job)
    PlayerJob = job
end)