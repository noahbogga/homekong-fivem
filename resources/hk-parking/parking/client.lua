-- ═══════════════════════════════════════════════════════════ --
--          HK-PARKING — HOMEKONG (based on mh-parking by MaDHouSe79, MIT)           --
-- ═══════════════════════════════════════════════════════════ --
local QBCore = exports['qb-core']:GetCoreObject()
-- Safely snapshot a vehicle's properties for the live-mods park payload. Uses the
-- qb-core built-in (the file-global GetVehicleProperties in core/functions/client.lua
-- references a QBCore that isn't in scope here and throws). Wrapped in pcall so a
-- properties failure can NEVER kill the autoPark trigger thread — worst case the
-- server just falls back to the DB mods. Returns a JSON string or ''.
local function SafeLiveMods(veh)
    local ok, props = pcall(function() return QBCore.Functions.GetVehicleProperties(veh) end)
    if not ok or type(props) ~= 'table' then return '' end
    local ok2, encoded = pcall(json.encode, props)
    if not ok2 or type(encoded) ~= 'string' then return '' end
    return encoded
end

local config = nil
local isLoggedIn = false
local parkedCache = {}
local blipCache = {}
local wasInVehicle = false
local currentVehicle = nil
local unparking = {}   -- [plate]=true while an unpark request is in flight (once-guard)
-- MANUAL PARK (F4). Auto-park was removed: the driver must stop, kill the engine,
-- sit still, then press F4. `parkReadyAt` is the game-time when the CURRENTLY-DRIVEN
-- car first became eligible (engine off + ~0 velocity); it must have been held for
-- PARK_DELAY_MS before F4 is accepted. Reset to 0 the instant a condition breaks.
local parkReadyAt = 0
local parkingInProgress = false
local PARK_DELAY_MS = 1000
-- FALL-THROUGH forensics: stamp the game-time whenever THIS client fires an autoPark
-- (any car, owned or not). The seat watchdog reads it so a drop can be correlated to a
-- park action within the last ~2s — this is what confirms the "park near me drops me"
-- link even when the parked car isn't the one I'm sitting in.
local lastParkFireAt = 0
local lastExitPressAt = 0 -- last time the player asked to exit (F) — suppresses re-seat
local hkFallDbg = false   -- /hkfalldbg toggles verbose console logging of catches
local hkReseat  = true    -- /hkreseat master kill-switch for the anti-fall re-seat

-- ── Parked health (double effective HP, damage carries over) ──────────────
-- Base (real) health is captured ONCE per park and stored in the entity's
-- statebag (state.hkBaseBody/hkBaseEngine) — NOT a client-local table — so it's
-- the single source of truth across every client and survives relogs. The
-- statebag is only written when it isn't already set (guards against a 2nd
-- client re-capturing the already-inflated value). While parked the car is
-- damageable at `mult`× health; on unpark we translate damage back to real scale.
function ApplyParkedHealth(vehicle)
    local mult = (config and config.ParkedHealthMultiplier) or 2.0
    if mult <= 0 then mult = 2.0 end
    local cap  = (config and config.MaxParkedHealth) or 2000.0
    local st = Entity(vehicle).state
    -- Only capture the base ONCE (first client to park it). If already set,
    -- another client/this client already inflated the health — don't re-read.
    if st.hkBaseBody == nil then
        local body   = GetVehicleBodyHealth(vehicle)
        local engine = GetVehicleEngineHealth(vehicle)
        st:set('hkBaseBody', body, true)
        st:set('hkBaseEngine', engine, true)
        SetEntityInvincible(vehicle, false)  -- damageable, not godmode
        SetVehicleBodyHealth(vehicle, math.min(body * mult, cap))
        SetVehicleEngineHealth(vehicle, math.min(engine * mult, cap))
    end
end

function RestoreParkedHealth(vehicle)
    local mult = (config and config.ParkedHealthMultiplier) or 2.0
    if mult <= 0 then mult = 2.0 end
    local cap  = (config and config.MaxParkedHealth) or 2000.0
    local st = Entity(vehicle).state
    local baseBody, baseEngine = st.hkBaseBody, st.hkBaseEngine
    if baseBody == nil then return end   -- wasn't tracked → nothing to restore
    -- Applied health = min(base*mult, cap). Fraction remaining = current/applied.
    -- newReal = base * fractionRemaining (so damage scales back proportionally and
    -- the cap can't silently eat health).
    local function restore(cur, base, setFn)
        local applied = math.min(base * mult, cap)
        if applied <= 0 then setFn(base); return end
        local frac = math.max(0, math.min(1, cur / applied))
        setFn(math.max(0, base * frac))
    end
    restore(GetVehicleBodyHealth(vehicle), baseBody, function(v) SetVehicleBodyHealth(vehicle, v) end)
    restore(GetVehicleEngineHealth(vehicle), baseEngine, function(v) SetVehicleEngineHealth(vehicle, v) end)
    st:set('hkBaseBody', nil, true)
    st:set('hkBaseEngine', nil, true)
end

local function SetVehicleWaypoit(coords)
    local playerCoords = GetEntityCoords(PlayerPedId())
    local distance = GetDistance(playerCoords, coords)
    if distance < 200 then
        Notify(Lang:t('info.no_waipoint', {distance = Round(distance, 2)}), "error", 5000)
    elseif distance > 200 then
        SetNewWaypoint(coords.x, coords.y)
    end
end

local function GetVehicleMenu()
    TriggerCallback("hk-parking:server:GetVehicles", function(result)
        if result.status then
            if result.data ~= nil then
                local num = 0
                local options = {}
                for k, v in pairs(result.data) do
                    if v.state == 3 then
                        num = num + 1
                        local coords = json.decode(v.location)
                        options[#options + 1] = {
                            id = num,
                            title = FirstToUpper(v.vehicle) .. " " .. v.plate .. " is parked",
                            icon = "fa-solid fa-square-parking",
                            description = Lang:t('info.street', {street = v.street}) .. '\n' .. Lang:t('info.fuel', {fuel = v.fuel}) .. '\n' .. Lang:t('info.engine', {engine = v.engine}) .. '\n' .. Lang:t('info.body', {body = v.body}) .. '\n' .. Lang:t('info.click_to_set_waypoint'),
                            arrow = false,
                            onSelect = function()
                                SetVehicleWaypoit(coords)
                            end
                        }
                    end
                end
                num = num + 1
                options[#options + 1] = {
                    id = num,
                    title = 'close',
                    icon = "fa-solid fa-stop",
                    description = '',
                    arrow = false,
                    onSelect = function()
                    end
                }
                lib.registerContext({id = 'parkMenu', title = "HK Parking", icon = "fa-solid fa-warehouse", options = options})
                lib.showContext('parkMenu')
            else
                Notify(Lang:t('info.no_vehicles_parked'), "error", 5000)
            end
        end
    end)
end

local function OpenInfoMenu(vehicle)
    if not vehicle or not DoesEntityExist(vehicle) then return end
    if config.Vehicles[GetEntityModel(vehicle)] then
        local model       = config.Vehicles[GetEntityModel(vehicle)].model
        local body        = math.floor(GetVehicleBodyHealth(vehicle))
        local engine      = math.floor(GetVehicleEngineHealth(vehicle))
        local tank        = math.floor(GetVehicleFuelLevel(vehicle))
        local oil         = math.floor(GetVehicleOilLevel(vehicle))
        local temp        = math.floor(GetVehicleEngineTemperature(vehicle))
        local plate       = GetPlate(vehicle)
        local modelHash   = GetEntityModel(vehicle)
        local displayName = GetDisplayNameFromVehicleModel(modelHash)
        local class       = GetVehicleClass(vehicle)
        local className   = GetLabelText("VEH_CLASS_"..class)
        local bodyColor   = body > 700 and 'green' or body > 400 and 'yellow' or 'red'
        local engineColor = engine > 700 and 'green' or engine > 400 and 'yellow' or 'red'
        local tankColor   = tank > 50 and 'green' or tank > 20 and 'yellow' or 'red'
        local tmpIcon     = temp > 90 and 'temperature-high' or 'temperature-half'
        local oilIcon     = oil > 5 and 'blue' or 'orange'
        local bodyIcon    = body > 700 and 'shield' or body > 400 and 'shield-halved' or 'shield-crack'
        local engineIcon  = engine > 700 and 'engine' or engine > 400 and 'engine-warning' or 'fire-flame-curved'
        local tankIcon    = tank > 50 and 'gas-pump' or tank > 20 and 'fill-drip' or 'fill'
        local tmpEngineIcon = temp > 95 and 'red' or temp > 80 and 'orange' or 'blue'
        local options = {}
        options[#options + 1] = {
            title = displayName:upper(),
            description = className .. ' • ' .. plate,
            icon = 'car',
            iconColor = '#ff4444',
            metadata = {
                {label = '💸 Price', value = config.Vehicles[modelHash].price and ('$%s'):format(config.Vehicles[modelHash].price:reverse():gsub('(...)', '%1.'):reverse()) or 'Unknown'},
                {label = '⚡ Class', value = className},
            }
        }
        local state = Entity(vehicle).state
        if GetIdentifier() == state.citizenid then
            options[#options + 1] = {title = Lang:t("vehicle.body_damage"),   description = body..'/1000',   progress = body/10,   icon = bodyIcon,   colorScheme = bodyColor}
            options[#options + 1] = {title = Lang:t("vehicle.engine_damage"), description = engine..'/1000', progress = engine/10, icon = engineIcon, colorScheme = engineColor}
            options[#options + 1] = {title = Lang:t("vehicle.fuel_level"),    description = tank..'%',       progress = tank,      icon = tankIcon,   colorScheme = tankColor}
            options[#options + 1] = {title = Lang:t("vehicle.oil_level"),     description = oil.."fL",       progress = oil,       icon = 'oil-can',  colorScheme = oilIcon}
            options[#options + 1] = {title = Lang:t("vehicle.engine_temp"),   description = temp..'°C',                            icon = tmpIcon,    colorScheme = tmpEngineIcon}            
        end
        lib.registerContext({id = 'mh_parkinfo_epic', title = "🚗 "..Lang:t("vehicle.info"), menu = 'mh_parkinfo_epic', canClose = true, options = options})
        lib.showContext('mh_parkinfo_epic')
    end
end

local function DeleteParkedBlip(plate)
    local entry = parkedCache[plate]
    if entry and entry.blip and DoesBlipExist(entry.blip) then
        RemoveBlip(entry.blip)
    end
end

local function DeleteParkedBlips()
    for k, blip in pairs(blipCache) do
        if DoesBlipExist(blip) then
            RemoveBlip(blip)
            blip = nil
        end
    end
    blipCache = {}
end

local function CreateParkedBlip(entity, data)
    if not config.Vehicles[data.hash] then return nil end
    local model = config.Vehicles[data.hash].model or "unknow"
    local brand = config.Vehicles[data.hash].brand or "unknow"
    local blip = AddBlipForCoord(data.coords.x, data.coords.y, data.coords.z)
    SetBlipSprite(blip, 545)
    SetBlipDisplay(blip, 4)
    SetBlipScale(blip, 0.6)
    SetBlipAsShortRange(blip, true)
    SetBlipColour(blip, 25)
    BeginTextCommandSetBlipName("STRING")
    AddTextComponentSubstringPlayerName(Lang:t('blip.label', {model = model, plate = data.plate}))
    EndTextCommandSetBlipName(blip)
    return blip
end

local function SyncParked(netId, isParked, pos, mods, steerangle, clamp_netid)
    while config == nil do Wait(10) end
    while not NetworkDoesNetworkIdExist(netId) do Wait(10) end
    local vehicle = NetworkGetEntityFromNetworkId(netId)
    if not vehicle or not DoesEntityExist(vehicle) then return end
    local plate = GetVehicleNumberPlateText(vehicle):gsub("^%s*(.-)%s*$", "%1"):upper()
    -- MODS: only (re)apply when this client does NOT already have the car rendered
    -- correctly. The player who JUST parked already sees the real car — re-running
    -- SetVehicleModKit + SetVehicleProperties on it (especially the instant they step
    -- out, while entity control is migrating away) resets it to the DEFAULT look = the
    -- "mods gone after parking" bug. So: if we currently hold control, the car is ours
    -- and already correct -> skip. Otherwise (a REMOTE parked car we're just seeing)
    -- take control, apply, and hand back. The scan thread covers late stream-ins too.
    -- OCCUPANT GUARD: never re-apply properties to a car the LOCAL player is sitting
    -- in. A passenger doesn't control the entity (the driver does), so on the park
    -- broadcast the passenger's client would otherwise take control + run
    -- SetVehicleProperties on the seat under them = physics reset = ped falls through
    -- the car ("passenger sinks, no warning" bug). An occupant already sees the car
    -- correctly, so there is nothing to fix here — skip.
    local localInVeh = IsPedInVehicle(PlayerPedId(), vehicle, false)
    if mods and next(mods) and isParked and not localInVeh and not NetworkHasControlOfEntity(vehicle) then
        SetNetworkIdCanMigrate(netId, true)      -- must be migratable to take control
        NetworkRequestControlOfEntity(vehicle)
        local ctl = 0
        while not NetworkHasControlOfEntity(vehicle) and ctl < 25 do
            NetworkRequestControlOfEntity(vehicle); Wait(10); ctl = ctl + 1
        end
        if NetworkHasControlOfEntity(vehicle) then
            local m = {}
            for k, v in pairs(mods) do m[k] = v end
            m.plate = nil                        -- never override the DB plate
            -- health owned by parked-health system, not the mod snapshot (see scan thread)
            m.bodyHealth, m.engineHealth, m.tankHealth = nil, nil, nil
            m.fuelLevel, m.dirtLevel = nil, nil
            SetVehicleModKit(vehicle, 0)
            SetVehicleProperties(vehicle, m)
        end
        Wait(0)
    end
    SetVehicleKeepEngineOnWhenAbandoned(vehicle, true)
    -- Only LOCK migration while the car is PARKED. Locking on every sync (incl. the
    -- unpark broadcast) re-froze the entity the entering driver had just taken control
    -- of -> engine on, won't move. isParked=false path re-enables it in the else below.
    SetNetworkIdCanMigrate(netId, isParked == true and false or true)
    SetNetworkIdExistsOnAllMachines(netId, true)
    local state = Entity(vehicle).state
    if netId >= 1 then
        if isParked then
            if not parkedCache[plate] then
                parkedCache[plate] = {vehicle = vehicle, pos = pos, plate = plate}
                if steerangle == nil or steerangle == false then steerangle = 0.0 end
                SetVehicleSteeringAngle(vehicle, steerangle + 0.0) 
                if GetIdentifier() == state.citizenid then
                    local data = {hash = GetEntityModel(vehicle), plate = plate, coords = pos}
                    parkedCache[plate].blip = CreateParkedBlip(vehicle, data)
                end
                SetVehicleEngineOn(vehicle, false, false, true)
                state.steerangle = steerangle
                state.isParked = true
                state.parkedPos = pos
                if state.isClamped == true then
                    local model = GetHashKey(config.ClampProp)
                    local clamp = CreateObject(model, 0.0, 0.0, 0.0, true, false, false)
                    while not DoesEntityExist(clamp) do Wait(0) end
                    local netId = ObjToNet(clamp)
                    SetNetworkIdCanMigrate(netId, false)
                    SetNetworkIdExistsOnAllMachines(netId, true)
                    state.clamp_netid = netId
                    parkedCache[plate].clamp_netid = netId
                    AttachEntityToEntity(clamp, vehicle, GetEntityBoneIndexByName(vehicle, 'wheel_lf'), config.ClampOffset.x, config.ClampOffset.y, config.ClampOffset.z, config.ClampOffset.rx, config.ClampOffset.ry, config.ClampOffset.rz, false, false, false, false, 0, true)
                    SetEntityAsMissionEntity(clamp, true, true)
                end
            end
        else
            if state.isClamped then return end
            state.steerangle = 0
            state.isParked = false
            state.parkedPos = nil
            DeleteParkedBlip(plate)
            parkedCache[plate] = nil
            -- Unparked: allow migration again so whoever gets in can simulate it. If
            -- WE are the one driving it, take control now so it moves immediately.
            SetNetworkIdCanMigrate(netId, true)
            if GetPedInVehicleSeat(vehicle, -1) == PlayerPedId() then
                SetEntityAsMissionEntity(vehicle, true, true)
                NetworkRequestControlOfEntity(vehicle)
            end
        end
        return
    else
        return
    end
end

local function LeaveVehicle(data)
    while not NetworkDoesNetworkIdExist(data.vehicleNetID) do Wait(10) end
    local vehicle = SafeNetId(data.vehicleNetID)
    if DoesEntityExist(vehicle) then TaskLeaveVehicle(PlayerPedId(), vehicle, 1) end
end

local function GetAllPlayersInVehicle(vehicle)
    local pedsincar = {}
    local numPas = GetVehicleModelNumberOfSeats(GetEntityModel(vehicle))
    for i = -1, numPas, 1 do
        if not IsVehicleSeatFree(vehicle, i) then
            local ped = GetPedInVehicleSeat(vehicle, i)
            if IsPedAPlayer(ped) then
                pedsincar[#pedsincar + 1] = {playerId = GetPlayerServerId(NetworkGetPlayerIndexFromPed(ped)), seat = i}
            end
        end
    end
    return pedsincar
end

local function AllPlayersLeaveVehicle(vehicle)
    if DoesEntityExist(vehicle) then
        local players = GetAllPlayersInVehicle(vehicle)
        if config.OnlyAutoParkWhenEngineIsOff then
            local engineIsOn = GetIsVehicleEngineRunning(vehicle)
            if not engineIsOn then TriggerServerEvent('hk-parking:server:AllPlayersLeaveVehicle', SafeNetId(vehicle), players) end
        else
            TriggerServerEvent('hk-parking:server:AllPlayersLeaveVehicle', SafeNetId(vehicle), players)
        end
    end
end

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    isLoggedIn = false
    DeleteParkedBlips()
end)

AddEventHandler('onResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    TriggerServerEvent('hk-parking:onjoin')
end)

RegisterNetEvent(OnPlayerUnload)
AddEventHandler(OnPlayerUnload, function()
    isLoggedIn = false
    DeleteParkedBlips()
end)

RegisterNetEvent(OnPlayerLoaded)
AddEventHandler(OnPlayerLoaded, function()
    TriggerServerEvent('hk-parking:onjoin')
end)

RegisterNetEvent('hk-parking:client:leaveVehicle', function(data)
    LeaveVehicle(data)
end)

RegisterNetEvent('hk-parking:openparkmenu', function()
    GetVehicleMenu()
end)

RegisterNetEvent('hk-parking:syncParked', function(netId, isParked, pos, mods, steerangle, clamp_netid)
    while config == nil do Wait(10) end
    while not NetworkDoesNetworkIdExist(netId) do Wait(10) end
    SyncParked(netId, isParked, pos, mods, steerangle, clamp_netid)
end)

RegisterNetEvent('hk-parking:syncWheelClamp', function(netId)
    while not NetworkDoesNetworkIdExist(netId) do Wait(0) end
    local vehicle = NetToVeh(netId)
    if DoesEntityExist(vehicle) then
        local plate = GetPlate(vehicle)
        if parkedCache[plate] then
            local state = Entity(vehicle).state
            if state.isClamped == true then
                local model = GetHashKey(config.ClampProp)
                local clamp = CreateObject(model, 0.0, 0.0, 0.0, true, false, false)
                while not DoesEntityExist(clamp) do Wait(0) end
                local netId = ObjToNet(clamp)
                SetNetworkIdCanMigrate(netId, false)
                SetNetworkIdExistsOnAllMachines(netId, true)
                parkedCache[plate].clamp_netid = netId
                AttachEntityToEntity(clamp, vehicle, GetEntityBoneIndexByName(vehicle, 'wheel_lf'), config.ClampOffset.x, config.ClampOffset.y, config.ClampOffset.z, config.ClampOffset.rx, config.ClampOffset.ry, config.ClampOffset.rz, false, false, false, false, 0, true)
                SetEntityAsMissionEntity(clamp, true, true)
                FreezeEntityPosition(vehicle, true)
                SetVehicleUndriveable(vehicle, true)  
            elseif state.isClamped == false then
                if parkedCache[plate].clamp_netid ~= nil then
                    while not NetworkDoesNetworkIdExist(parkedCache[plate].clamp_netid) do Wait(0) end
                    local clamp = NetToObj(parkedCache[plate].clamp_netid)
                    if DoesEntityExist(clamp) then DeleteObject(clamp); DeleteEntity(clamp) end
                    FreezeEntityPosition(vehicle, false)
                    SetVehicleUndriveable(vehicle, false)
                end
            end
        end
    end
end)

RegisterNetEvent('hk-parking:onjoin', function(data)
    if data and data.status == true then
        config = data.config
        isLoggedIn = true
    end
end)

RegisterNetEvent('hk-parking:infomenu', function()
    local closestVehicle, closestDistance = GetClosestVehicle(GetEntityCoords(PlayerPedId()))
    if closestVehicle ~= -1 and closestDistance ~= -1 and closestDistance < 3.0 then OpenInfoMenu(closestVehicle) end
end)

AddEventHandler('entityCreated', function(entity)
    if not DoesEntityExist(entity) then return end
    local entityType = GetEntityType(entity)
    if entityType == 2 then SetVehicleKeepEngineOnWhenAbandoned(entity, true) end
end)

CreateThread(function()
    local angle, speed = 0.0, 0.0
    while true do
        while config == nil do Wait(10) end
        local sleep = 1000
        if isLoggedIn then
            local ped = PlayerPedId()
            local veh = GetVehiclePedIsIn(ped, false)
            if DoesEntityExist(veh) and GetPedInVehicleSeat(veh, -1) == ped then
                local tangle = GetVehicleSteeringAngle(veh)
                if math.abs(tangle) > 10.0 then angle = tangle end
                speed = GetEntitySpeed(veh)
                if speed < 0.5 and not GetIsVehicleEngineRunning(veh) then
                    sleep = 0
                    SetVehicleSteeringAngle(veh, angle)
                else
                    sleep = 250
                end
            else
                sleep = 500
            end
        end
        Wait(sleep)
    end
end)

CreateThread(function()
    while true do
        Wait(200)
        while config == nil do Wait(10) end
        if isLoggedIn then
            local ped = PlayerPedId()
            -- Arm on the LAST vehicle the player drove, even after they've left it.
            -- GetVehiclePedIsIn(ped, true) returns the last vehicle when on foot.
            local inVeh = IsPedInAnyVehicle(ped, false)
            local veh = inVeh and GetVehiclePedIsIn(ped, false) or nil
            if inVeh and veh and GetPedInVehicleSeat(veh, -1) == ped then
                -- Player is the driver right now → remember this car so F4 can park it.
                -- (Auto-park on hop/walk-away removed — parking is now manual via F4.)
                if not wasInVehicle or currentVehicle ~= veh then
                    currentVehicle = veh
                    wasInVehicle = true
                    parkReadyAt = 0     -- new car: must re-satisfy the stop+engine-off hold
                    -- Report the car we're now driving so the server can send it to the
                    -- mechanic depot if we DISCONNECT while in it (car would otherwise go
                    -- stale at state 0 with no world entity after a restart).
                    local rp = GetVehicleNumberPlateText(veh):gsub("^%s*(.-)%s*$", "%1"):upper()
                    if rp ~= '' then TriggerServerEvent('hk-parking:driving', rp) end
                end
                -- PARK-READINESS: `parkReadyAt` = when the car last became "stopped".
                -- Base it ONLY on velocity (jitter-tolerant threshold) — a stopped car
                -- still reads tiny speeds and hk-rollcreep nudges it on slopes, so a
                -- tighter gate + engine-flicker reset made the timer never complete.
                -- Engine-off / not-towed are checked INSTANTLY at F4-press instead.
                if GetEntitySpeed(veh) < 0.5 then
                    if parkReadyAt == 0 then parkReadyAt = GetGameTimer() end
                else
                    parkReadyAt = 0     -- car is moving → restart the hold
                end
                local plate = GetVehicleNumberPlateText(veh):gsub("^%s*(.-)%s*$", "%1"):upper()
                -- Only fire the unpark ONCE per car — `unparking[plate]` guards the
                -- 200ms poll from spamming autoUnpark every tick until the server
                -- confirms (which clears parkedCache[plate]).
                if parkedCache[plate] and not unparking[plate] then
                    local state = Entity(veh).state
                    if state.isClamped then
                        -- Don't unpark a clamped car; DON'T `return` (that would kill
                        -- this whole polling thread and break parking session-wide).
                        Notify("This vehicle has a wheel clamp.", "error")
                    else
                        -- TAKE PHYSICS OWNERSHIP. Parked cars are spawned server-side
                        -- (CreateVehicleServerSetter) and LOCKED with SetNetworkIdCanMigrate(false)
                        -- so they hold position + survive as world objects. But a migration-locked
                        -- server-owned entity is never simulated by any client -> you get in, the
                        -- engine turns on, but it WON'T MOVE. Re-enable migration and request control
                        -- for THIS client (same handoff the garage path does) so physics runs locally.
                        local netId0 = SafeNetId(veh)
                        if netId0 and netId0 > 0 and NetworkDoesNetworkIdExist(netId0) then
                            SetNetworkIdCanMigrate(netId0, true)
                        end
                        SetEntityAsMissionEntity(veh, true, true)
                        NetworkRequestControlOfEntity(veh)
                        local ctl = 0
                        while not NetworkHasControlOfEntity(veh) and ctl < 20 do
                            NetworkRequestControlOfEntity(veh); Wait(10); ctl = ctl + 1
                        end
                        -- FALL-THROUGH DEFENSE: the parked car was frozen server-side.
                        -- The server unfreezes it when it processes autoUnpark below, but
                        -- that's a ~260-440ms cross-VM round-trip away — and sitting in a
                        -- frozen car for even that long drops the ped through the seat.
                        -- Now that we hold control, unfreeze locally IMMEDIATELY so the
                        -- occupant is never in a frozen entity. (Server freeze guard +
                        -- this = both the park-side and enter-side windows are closed.)
                        FreezeEntityPosition(veh, false)
                        -- Entering own parked car: translate parked-mode damage back
                        -- onto the real health scale BEFORE unparking, so it persists.
                        RestoreParkedHealth(veh)
                        unparking[plate] = true
                        local vehForNet = veh
                        CreateThread(function()
                            local netId = -1
                            local tries = 0
                            repeat
                                Wait(100)
                                netId = SafeNetId(vehForNet)
                                tries = tries + 1
                            until (netId and netId > 0 and netId < 65535 and NetworkDoesNetworkIdExist(netId)) or tries > 30
                            if netId and netId > 0 then
                                SetNetworkIdExistsOnAllMachines(netId, true)
                                TriggerServerEvent('hk-parking:autoUnpark', netId)
                            end
                            Wait(3000)            -- let the server confirm + clear cache
                            unparking[plate] = nil
                        end)
                    end
                end
            elseif not inVeh and wasInVehicle and currentVehicle then
                -- Left the car ON FOOT without pressing F4 → do NOT auto-park anymore.
                -- Just clear the driving state; the car stays a live world entity until
                -- the owner parks it manually (F4 while seated) or it despawns naturally.
                currentVehicle = nil
                wasInVehicle = false
                parkReadyAt = 0
                TriggerServerEvent('hk-parking:driving', nil)   -- clear drop-to-depot tracking
            end
        end
    end
end)

-- ═══════════════════════════════════════════════════════════ --
--  MANUAL PARK — press F4 while seated in your stopped, engine-off car.        --
--  Requirements (all must hold): you're the driver, engine OFF, ~0 velocity,   --
--  car stable for ≥1000ms, not attached to a tow. The server refuses to park   --
--  an OCCUPIED car (fall-through guard), so we eject the driver first, wait for --
--  the seat to clear, then fire the park with the live-mods snapshot.          --
-- ═══════════════════════════════════════════════════════════ --
local function DoManualPark()
    if parkingInProgress then return end
    local ped = PlayerPedId()
    if not IsPedInAnyVehicle(ped, false) then
        Notify("You need to be sitting in your vehicle to park it.", "error"); return
    end
    local veh = GetVehiclePedIsIn(ped, false)
    if not veh or veh == 0 or GetPedInVehicleSeat(veh, -1) ~= ped then
        Notify("Only the driver can park the vehicle.", "error"); return
    end
    local plate = GetVehicleNumberPlateText(veh):gsub("^%s*(.-)%s*$", "%1"):upper()
    if parkedCache[plate] then
        Notify("This vehicle is already parked.", "error"); return
    end
    if GetEntityAttachedTo(veh) ~= 0 then
        Notify("Can't park a vehicle that's being towed.", "error"); return
    end
    if GetIsVehicleEngineRunning(veh) then
        Notify("Turn the engine OFF before parking.", "error"); return
    end
    if GetEntitySpeed(veh) >= 0.5 then
        Notify("The vehicle must be completely stopped.", "error"); return
    end
    if parkReadyAt == 0 or (GetGameTimer() - parkReadyAt) < PARK_DELAY_MS then
        Notify("Come to a full stop for a moment, then try again.", "error"); return
    end

    parkingInProgress = true
    local netId = SafeNetId(veh)
    if not (netId and netId > 0 and netId < 65535 and NetworkDoesNetworkIdExist(netId)) then
        parkingInProgress = false
        Notify("Couldn't sync this vehicle — try again in a moment.", "error"); return
    end
    SetNetworkIdExistsOnAllMachines(netId, true)
    local steerangle = GetVehicleSteeringAngle(veh)
    local street = GetStreetName(GetEntityCoords(veh))
    local liveMods = SafeLiveMods(veh)
    BlinkVehiclelights(veh)
    SetVehicleEngineOn(veh, false, false, false)

    -- Server won't park an occupied car → get the driver out first, then wait for
    -- the seat to actually clear before firing (up to ~2s), so the park lands.
    lastExitPressAt = GetGameTimer()   -- suppress the anti-fall re-seat while we exit
    TaskLeaveVehicle(ped, veh, 0)
    CreateThread(function()
        local t0 = GetGameTimer()
        while IsPedInVehicle(ped, veh, false) and (GetGameTimer() - t0) < 2000 do
            Wait(50)
        end
        -- clear our tracking so the poll doesn't think we're still "driving" it
        if currentVehicle == veh then currentVehicle = nil; wasInVehicle = false end
        parkReadyAt = 0
        lastParkFireAt = GetGameTimer()
        TriggerServerEvent('hk-parking:driving', nil)
        TriggerServerEvent('hk-parking:autoPark', netId, steerangle, street, liveMods)
        Notify("Vehicle parked.", "success")
        Wait(1500)
        parkingInProgress = false
    end)
end

RegisterCommand('hkpark', function() DoManualPark() end, false)
-- Default F4; players can rebind under Settings ▸ Key Bindings ▸ FiveM.
RegisterKeyMapping('hkpark', 'Park your vehicle (HK)', 'keyboard', 'F4')

CreateThread(function()
    while true do
        Wait(5000)
        while config == nil do Wait(1000) end
        if isLoggedIn then
            local pedCoords = GetEntityCoords(PlayerPedId())
            local vehicles = GetGamePool('CVehicle')
            for _, vehicle in ipairs(vehicles) do
                if DoesEntityExist(vehicle) then
                    local dist = #(GetEntityCoords(vehicle) - pedCoords)
                    if dist < (config.distance or 500.0) then
                        local plate = GetVehicleNumberPlateText(vehicle):gsub("^%s*(.-)%s*$", "%1"):upper()
                        local state = Entity(vehicle).state
                        if state.isParked and state.parkedPos then
                            if not parkedCache[plate] then
                                parkedCache[plate] = {vehicle = vehicle, pos = state.parkedPos}
                                SetVehicleEngineOn(vehicle, false, false, true)
                                SetVehicleDoorsLocked(vehicle, 2)
                                -- Own car? drop the parked blip here (the parker no longer
                                -- receives the syncParked event, so the blip is created in
                                -- this scan pass instead).
                                if GetIdentifier and state.citizenid == GetIdentifier() then
                                    local d = {hash = GetEntityModel(vehicle), plate = plate, coords = state.parkedPos}
                                    parkedCache[plate].blip = CreateParkedBlip(vehicle, d)
                                end
                                -- HOMEKONG: NOT godmode. Parked cars are damageable but
                                -- get double effective health (see ApplyParkedHealth).
                                ApplyParkedHealth(vehicle)
                                -- RENDER MODS on first sight. The syncParked broadcast only
                                -- reached clients in scope at park/boot time; a player who
                                -- drives up LATER streams the car in with a DEFAULT look. Apply
                                -- the mods stashed in the replicated statebag now, under control,
                                -- so players can tell which car is theirs before getting in.
                                local mods = state.hkMods
                                if mods and next(mods) then
                                    CreateThread(function()
                                        local nId = SafeNetId(vehicle)
                                        if nId and nId > 0 then SetNetworkIdCanMigrate(nId, true) end
                                        NetworkRequestControlOfEntity(vehicle)
                                        local ctl = 0
                                        while not NetworkHasControlOfEntity(vehicle) and ctl < 50 do
                                            NetworkRequestControlOfEntity(vehicle); Wait(10); ctl = ctl + 1
                                        end
                                        if NetworkHasControlOfEntity(vehicle) then
                                            local m = {}
                                            for k, v in pairs(mods) do m[k] = v end
                                            m.plate = nil
                                            -- Strip HEALTH/fuel/dirt fields: qb mods carry bodyHealth/
                                            -- engineHealth/tankHealth, and re-applying them every scan
                                            -- pass FIGHTS ApplyParkedHealth (2x inflate) — the car's HP
                                            -- visibly ticks down as the two overwrite each other. Only
                                            -- re-apply the VISUAL mods here; health is owned by the
                                            -- parked-health system, not the mod snapshot.
                                            m.bodyHealth, m.engineHealth, m.tankHealth = nil, nil, nil
                                            m.fuelLevel, m.dirtLevel = nil, nil
                                            SetVehicleModKit(vehicle, 0)
                                            SetVehicleProperties(vehicle, m)
                                        end
                                        if nId and nId > 0 then SetNetworkIdCanMigrate(nId, false) end
                                    end)
                                end
                            end
                            -- A parked car only auto-impounds if genuinely DESTROYED
                            -- (blown up / engine dead) or submerged — not merely
                            -- beat-up (it's on 2× health while parked, so a low
                            -- reading is still a working car).
                            local wrecked = IsEntityDead(vehicle)
                                or GetVehicleEngineHealth(vehicle) <= 0.0
                                or (IsEntityInWater(vehicle) and GetEntitySubmergedLevel(vehicle) > 0.55)
                            if wrecked then
                                parkedCache[plate] = nil
                                TriggerServerEvent('hk-parking:server:wreckToImpound', plate)
                            end
                        elseif not state.isParked then
                            -- (do NOT `return` here — that would kill this scan thread)
                            if not state.isClamped then
                                if parkedCache[plate] then
                                    DeleteParkedBlip(plate)
                                    parkedCache[plate] = nil
                                end
                                SetVehicleUndriveable(vehicle, false)
                                SetEntityInvincible(vehicle, false)
                            end
                        end
                    end
                end
            end
            -- clear
            for plate, data in pairs(parkedCache) do
                if not DoesEntityExist(data.vehicle) then
                    DeleteParkedBlip(plate)
                    parkedCache[plate] = nil
                end
            end
        end
    end
end)

-- (/dv → depot is wired via a small patch in qb-core/client/events.lua that
--  reports the plate to hk-parking:server:dvToDepot before deleting the entity.)

-- ── Wreck watcher for DRIVEN / OUT cars ───────────────────────────────────
-- A car destroyed while being driven (exploded, or driven into water) → route
-- to the mechanic depot too, not just parked ones. Watches the vehicle the
-- player is in / last drove; the server verifies ownership before impounding.
CreateThread(function()
    local reported = {}   -- plate → true, so we only fire once per wreck
    while true do
        Wait(1000)
        while config == nil do Wait(500) end
        if isLoggedIn then
            local ped = PlayerPedId()
            local veh = GetVehiclePedIsIn(ped, false)
            if veh == 0 then veh = GetVehiclePedIsIn(ped, true) end   -- last vehicle when on foot
            if veh and veh ~= 0 and DoesEntityExist(veh) then
                local st = Entity(veh).state
                local model = GetEntityModel(veh)
                -- Only land vehicles (cars/bikes) — boats/planes/subs in water are
                -- normal, not wrecked. Skip parked (handled elsewhere) + clamped.
                local isLand = IsThisModelACar(model) or IsThisModelABike(model)
                if isLand and not (st and (st.isParked or st.isClamped)) then
                    local eng  = GetVehicleEngineHealth(veh)
                    local dead = IsEntityDead(veh) or eng <= 0.0
                    -- "In water" only counts as a wreck when the car is basically
                    -- submerged (drowning the engine), not merely splashing through.
                    local submerged = IsEntityInWater(veh) and GetEntitySubmergedLevel(veh) > 0.55
                    local plate = GetVehicleNumberPlateText(veh):gsub("^%s*(.-)%s*$", "%1"):upper()
                    if plate ~= '' then
                        if dead or submerged then
                            if not reported[plate] then
                                reported[plate] = true
                                TriggerServerEvent('hk-parking:server:wreckToImpound', plate)
                            end
                        else
                            -- car is fine again (repaired / driven out of water) →
                            -- clear the flag so a later wreck of the same plate fires.
                            reported[plate] = nil
                        end
                    end
                end
            end
        end
    end
end)

-- ============================================================================
-- FALL-THROUGH-THE-SEAT HARD BACKSTOP  v2  (client-authoritative, zero-lag)
-- ----------------------------------------------------------------------------
-- NEW EVIDENCE (2026-08-06): the drop happens to the car the player is SITTING
-- IN (car B) when a *different* nearby car (car A) parks — INCLUDING when car A
-- is NOT owned. That is decisive: server autoPark RETURNS on a non-owned car
-- BEFORE any FreezeEntityPosition (server.lua ~L306), so in that case NOTHING
-- froze car B. The disturbance is a client-side physics/ownership STUTTER on
-- car B, caused by the network churn of parking car A right next to it
-- (SetNetworkIdExistsOnAllMachines / control wrestling / engine toggles while
-- our client is mid-simulating car B). The ped's ragdoll detaches from the seat
-- and free-falls; the world LODs out at the ped's real (falling) Z.
--
-- Why v1 failed:
--   * v1 part-1 (unfreeze) was SCOPED to isParked/isClamped — car B has neither
--     flag, so it was skipped entirely.
--   * v1 part-2 waited for a 3.0m Z gap before re-seating — that plunge IS the
--     "I fell through" the player still reports; it corrected far too late.
--
-- v2 invariant (UNSCOPED, EARLY): a player who is logically seated must stay
-- planted. The instant the ped shows ANY sign of leaving its seat unbidden
-- (ragdoll, fall state, or even a small downward gap) while it did NOT ask to
-- exit, we re-plant it: take control, clear any freeze, re-warp into its seat.
-- Caught in the first few cm, this is invisible; caught late it's a small pop.
--
-- Carjack safety: qb-vehiclekeys freezes the VICTIM's occupied car during a
-- carjack (always paired with the 'mp_am_hold_up' holdup anim). We must NOT
-- fight that. So the unfreeze branch is skipped while the ped plays that anim,
-- and re-seat only fires on genuine detachment (a held-up victim isn't sinking
-- through their seat).
-- ============================================================================
local function hkPlayingHoldup(ped)
    return IsEntityPlayingAnim(ped, 'mp_am_hold_up', 'holdup_victim_20s', 3)
end

CreateThread(function()
    local reseatGuardUntil = 0    -- debounce: don't spam warps frame-after-frame
    while true do
        local ped = PlayerPedId()
        local veh = GetVehiclePedIsIn(ped, false)
        if isLoggedIn and veh and veh ~= 0 and DoesEntityExist(veh) and not hkPlayingHoldup(ped) then
            -- Which seat does the GAME still think we're in? (logical seat is intact
            -- for the whole fall — that's exactly why we can re-plant to it.)
            local seat = nil
            for s = -1, GetVehicleMaxNumberOfPassengers(veh) - 1 do
                if GetPedInVehicleSeat(veh, s) == ped then seat = s break end
            end
            if seat ~= nil then
                local st = Entity(veh).state
                local hkFrozen = st and (st.isParked == true or st.isClamped == true)

                -- (1) FROZEN-WHILE-OCCUPIED by HK park/clamp -> unfreeze immediately.
                --     Scoped to our own statebag so we never thaw a carjack victim
                --     (handled by the holdup-anim skip above too). We deliberately do
                --     NOT touch undriveable — a clamped car must stay immobile.
                if hkFrozen and IsEntityPositionFrozen(veh) then
                    if not NetworkHasControlOfEntity(veh) then NetworkRequestControlOfEntity(veh) end
                    FreezeEntityPosition(veh, false)
                    if hkFallDbg then print(('[hk-fall] unfroze occupied parked/clamped veh %s'):format(veh)) end
                end

                -- (2) DETACHMENT CATCH — TIGHTLY gated so it only ever fires on the
                --     actual bug and NEVER fights a normal/crash exit. v2 was too
                --     aggressive: it re-seated during the F-exit dip and crash ejects
                --     (ped still reads "in seat" mid-step-out). The real bug has a
                --     narrow signature we require ALL of:
                --       (a) a nearby autoPark fired in the last 2.5s (the trigger), AND
                --       (b) the player did NOT ask to exit (no F within 1.5s), AND
                --       (c) the ped is dropping STRAIGHT DOWN through the seat — i.e.
                --           still basically at the car's X/Y (horiz < 1.8m). A normal
                --           exit walks AWAY and a crash eject throws you SIDEWAYS, so
                --           both have large horizontal offset and are excluded. AND
                --       (d) it has actually sunk (>0.9m below) OR is ragdolling right
                --           at the seat. No plain "falling" flag alone (that's exit).
                local now       = GetGameTimer()
                -- Track the exit request (F = control 75 INPUT_VEHICLE_EXIT). Any
                -- press means the player WANTS out — suppress re-seat for 1.5s so we
                -- never fight the exit animation.
                if IsControlPressed(0, 75) or IsDisabledControlPressed(0, 75) then
                    lastExitPressAt = now
                end
                local parkedRecently = lastParkFireAt > 0 and (now - lastParkFireAt) < 2500
                -- BEING TOWED: our car is attached to another entity (flatbed/tow truck).
                -- qb-towjob now attaches an OCCUPIED car WITHOUT freezing it, so the seat
                -- bond usually holds — but network churn / tilt on the flatbed can still
                -- nudge the ped loose. This is a second, independent re-seat trigger.
                local beingTowed = GetEntityAttachedTo(veh) ~= 0
                local askedExit = (now - lastExitPressAt) < 1500
                local pz        = GetEntityCoords(ped)
                local vz        = GetEntityCoords(veh)
                local horiz     = #(vector2(pz.x, pz.y) - vector2(vz.x, vz.y))
                local straightDown = horiz < 1.8               -- through the floor, not walking/thrown out
                local sink      = (vz.z - pz.z) > 0.9
                local ragdollAtSeat = IsPedRagdoll(ped) and straightDown
                -- Towed car tilts on the flatbed, so allow a larger horizontal gap for
                -- that trigger; still require actual sink or ragdoll (not a clean exit).
                local towSlip   = beingTowed and horiz < 3.5 and (sink or IsPedRagdoll(ped))
                if hkReseat and now >= reseatGuardUntil and not askedExit
                   and ( (parkedRecently and straightDown and (sink or ragdollAtSeat)) or towSlip ) then
                    if not NetworkHasControlOfEntity(veh) then NetworkRequestControlOfEntity(veh) end
                    FreezeEntityPosition(veh, false)          -- ensure car itself is live
                    SetEntityCoords(ped, vz.x, vz.y, vz.z, false, false, false, false)  -- kill fall velocity first
                    ClearPedTasksImmediately(ped)             -- drop the ragdoll/fall task
                    TaskWarpPedIntoVehicle(ped, veh, seat)    -- re-plant, same seat
                    reseatGuardUntil = now + 400              -- 0.4s debounce
                    if hkFallDbg then
                        print(('[hk-fall] RE-SEAT veh %s seat %d | sink=%.2f horiz=%.2f ragdoll=%s | towed=%s parkFire=%dms ago')
                            :format(veh, seat, (vz.z - pz.z), horiz, tostring(IsPedRagdoll(ped)),
                                    tostring(beingTowed), now - lastParkFireAt))
                    end
                end
            end
            Wait(0)          -- frame-accurate while seated: beat the ragdoll detach
        else
            Wait(300)        -- idle on foot / during a carjack holdup: cheap
        end
    end
end)

-- Toggle verbose fall-through catch logging (console) to confirm the park↔drop
-- correlation live. Off by default (zero cost when off).
RegisterCommand('hkfalldbg', function()
    hkFallDbg = not hkFallDbg
    print(('[hk-fall] debug logging %s'):format(hkFallDbg and 'ON' or 'OFF'))
end, false)

-- Master kill-switch: if the anti-fall re-seat EVER misbehaves (traps you in a
-- car, fights an exit), type /hkreseat to turn it off instantly. No restart needed.
RegisterCommand('hkreseat', function()
    hkReseat = not hkReseat
    print(('[hk-fall] anti-fall re-seat %s'):format(hkReseat and 'ON' or 'OFF'))
end, false)
