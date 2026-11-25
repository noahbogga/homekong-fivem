-- ═══════════════════════════════════════════════════════════ --
--   HK-GARAGE — Impound retrieval points                          --
--   • Mechanic depot pickup (state 4): owner presses E at a depot  --
--     take-point → menu of their depot cars → pay ImpoundPrice.    --
--   • Police impound (state 2): female officer NPC (qb-target,     --
--     Config.Impound.policeHours only) → menu of seized cars → pay ImpoundPrice.--
--   Both pools are shared across their two locations.              --
-- ═══════════════════════════════════════════════════════════ --

if not IsDuplicityVersion() then
    -- ══════════════ CLIENT ══════════════
    local QBCore = exports['qb-core']:GetCoreObject()

    -- Last impound spawn anchor (plain {x,y,z,w}), set at menu open. Used as a
    -- fallback if the NUI round-trips the spawn as nil/malformed.
    lastImpoundSpawn = nil

    local function helpText(text)
        SetTextComponentFormat('STRING'); AddTextComponentString(text)
        DisplayHelpTextFromStringLabel(0, 0, 1, -1)
    end

    -- Retrieval: open the SAME garage NUI (not a separate ox_lib menu), showing
    -- only this pool's cars, with a Retrieve action + preview. Reuses the garage
    -- server callback but flagged as an impound context (kind + spawn anchor).
    local function openImpoundMenu(kind, anchor)
        local pc = GetEntityCoords(PlayerPedId())
        QBCore.Functions.TriggerCallback('hk-garage:server:GetImpoundVehicles', function(list)
            if not list or #list == 0 then
                lib.notify({ title = 'HK Parking', description = '冇車喺度 · No vehicles here', type = 'error' })
                return
            end
            -- anchor is a vector4; convert to a PLAIN table so it survives the JSON
            -- round-trip through the NUI intact. A raw vector4 serializes inconsistently
            -- (often losing .w or arriving as an array with nil .x) -> the spawn point
            -- came back malformed, so the retrieved car spawned at a bad spot and the
            -- warp failed / retrieve errored. Also stash it client-side as a fallback.
            local sp = anchor and { x = anchor.x + 0.0, y = anchor.y + 0.0, z = anchor.z + 0.0, w = (anchor.w or anchor.h or 0.0) + 0.0 } or nil
            lastImpoundSpawn = sp
            SetNuiFocus(true, true)
            SendNUIMessage({
                action = 'VehicleList',
                garageLabel = (kind == 'police') and '警察扣車場 · Police Impound' or '維修廠扣車場 · Mechanic Depot',
                garageSub = (kind == 'police') and 'POLICE IMPOUND' or 'MECHANIC DEPOT',
                vehicles = list,
                impound = kind,                 -- flags NUI: show Retrieve, not Drive/Locate
                impoundSpawn = sp,              -- plain {x,y,z,w} table (JSON-safe)
            })
        end, kind, { x = pc.x, y = pc.y, z = pc.z })
    end

    -- ── Mechanic depot pickup zones (owner E-to-retrieve, state 4) ─────────
    CreateThread(function()
        for i, depot in ipairs(Config.Impound.depots) do
            if depot.blip then
                local b = AddBlipForCoord(depot.take.x, depot.take.y, depot.take.z)
                SetBlipSprite(b, 68); SetBlipColour(b, 3); SetBlipScale(b, 0.7); SetBlipAsShortRange(b, true)
                BeginTextCommandSetBlipName('STRING'); AddTextComponentSubstringPlayerName(depot.label); EndTextCommandSetBlipName(b)
            end
        end
        while true do
            local sleep = 1000
            local pc = GetEntityCoords(PlayerPedId())
            for _, depot in ipairs(Config.Impound.depots) do
                if #(pc - depot.take) < 12.0 then
                    sleep = 0
                    if #(pc - depot.take) < 2.0 and not IsPedInAnyVehicle(PlayerPedId(), false) then
                        helpText('~g~[E]~w~ 取返扣押車輛 · Retrieve vehicle')
                        if IsControlJustReleased(0, 38) then openImpoundMenu('depot', depot.spawn) end
                    end
                end
            end
            Wait(sleep)
        end
    end)

    -- ── Police impound NPC officers (spawned only during config hours) ────
    local policeNpcs = {}         -- [index] = ped (nil if that one failed to spawn)
    local policeBlips = {}        -- persistent, created ONCE (not per NPC)

    -- Resource-agnostic entity target (ox_target / qb-target / qtarget).
    local function addOfficerTarget(ped, pl)
        local opts = {{
            name = 'hk_police_impound',
            icon = 'fas fa-car-burst',
            label = '取返被扣車輛 · Retrieve Impounded',
            onSelect = function() openImpoundMenu('police', pl.spawn) end,
            action  = function() openImpoundMenu('police', pl.spawn) end,  -- qb-target
            distance = 2.5,
        }}
        if GetResourceState('ox_target') == 'started' then
            exports.ox_target:addLocalEntity(ped, opts)
        elseif GetResourceState('qb-target') == 'started' then
            exports['qb-target']:AddTargetEntity(ped, { options = opts, distance = 2.5 })
        elseif GetResourceState('qtarget') == 'started' then
            exports.qtarget:AddTargetEntity(ped, { options = opts, distance = 2.5 })
        end
    end

    local function removeOfficerTarget(ped)
        if GetResourceState('ox_target') == 'started' then
            exports.ox_target:removeLocalEntity(ped)
        elseif GetResourceState('qb-target') == 'started' then
            exports['qb-target']:RemoveTargetEntity(ped)
        elseif GetResourceState('qtarget') == 'started' then
            exports.qtarget:RemoveTargetEntity(ped)
        end
    end

    local function withinPoliceHours()
        -- HOMEKONG: police impound NPC is available 24/7 (time window removed). The
        -- policeHoursStart/End config keys are now unused; kept so old configs don't
        -- error. Return true unconditionally so the NPC always spawns/stays.
        return true
    end

    -- Persistent blips at each police lot — created once, always visible.
    CreateThread(function()
        for _, pl in ipairs(Config.Impound.police) do
            if pl.blip then
                local b = AddBlipForCoord(pl.npc.x, pl.npc.y, pl.npc.z)
                SetBlipSprite(b, 237); SetBlipColour(b, 38); SetBlipScale(b, 0.7); SetBlipAsShortRange(b, true)
                BeginTextCommandSetBlipName('STRING'); AddTextComponentSubstringPlayerName(pl.label); EndTextCommandSetBlipName(b)
                policeBlips[#policeBlips + 1] = b
            end
        end
    end)

    local function spawnPoliceNpc(pl)
        local model = GetHashKey(Config.Impound.policeNpcModel)
        RequestModel(model); local t = 0
        while not HasModelLoaded(model) and t < 100 do Wait(10); t = t + 1 end
        if not HasModelLoaded(model) then return nil end
        local ped = CreatePed(4, model, pl.npc.x, pl.npc.y, pl.npc.z - 1.0, pl.npc.w, false, false)
        SetEntityAsMissionEntity(ped, true, true)
        FreezeEntityPosition(ped, true)
        SetEntityInvincible(ped, true)
        SetBlockingOfNonTemporaryEvents(ped, true)
        SetModelAsNoLongerNeeded(model)
        addOfficerTarget(ped, pl)
        return ped
    end

    -- Spawn during the window, despawn outside it. Per-index tracking so a NPC
    -- that failed to spawn (model timeout) is RETRIED next tick instead of being
    -- permanently missing.
    local function refreshPoliceNpcs()
        local want = withinPoliceHours()
        if want then
            for i, pl in ipairs(Config.Impound.police) do
                if not (policeNpcs[i] and DoesEntityExist(policeNpcs[i])) then
                    policeNpcs[i] = spawnPoliceNpc(pl)   -- nil if it failed; retried next tick
                end
            end
        else
            for i, ped in pairs(policeNpcs) do
                if ped and DoesEntityExist(ped) then removeOfficerTarget(ped); DeleteEntity(ped) end
                policeNpcs[i] = nil
            end
        end
    end

    CreateThread(function()
        while true do
            refreshPoliceNpcs()
            Wait(30000) -- re-check the window (also retries any NPC that failed to spawn)
        end
    end)

    AddEventHandler('onResourceStop', function(res)
        if res ~= GetCurrentResourceName() then return end
        for i, ped in pairs(policeNpcs) do
            if ped and DoesEntityExist(ped) then removeOfficerTarget(ped); DeleteEntity(ped) end
            policeNpcs[i] = nil
        end
        for _, b in ipairs(policeBlips) do if DoesBlipExist(b) then RemoveBlip(b) end end
    end)
    return
end

-- ══════════════ SERVER ══════════════
local QBCore = exports['qb-core']:GetCoreObject()

-- (Removed dead callback hk-garage:server:getImpounded — superseded by
--  hk-garage:server:GetImpoundVehicles in garage/server.lua, which is what the
--  impound NUI actually calls.)

RegisterNetEvent('hk-garage:server:retrieveImpound', function(plate, kind, spawn)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    if not plate then return end
    plate = tostring(plate):gsub("^%s*(.-)%s*$", "%1"):upper()
    local st = (kind == 'police') and 2 or 4

    local row = MySQL.single.await('SELECT towedby, vehicle FROM player_vehicles WHERE plate = ? AND citizenid = ? AND state = ? LIMIT 1',
        { plate, Player.PlayerData.citizenid, st })
    if not row then
        TriggerClientEvent('ox_lib:notify', src, { title = 'HK Parking', description = '搵唔到架車 · Vehicle not found', type = 'error' })
        return
    end

    -- Affordability CHECK only (no deduction yet). Money + state change happen in
    -- confirmImpoundRetrieve, AFTER the client confirms the car actually spawned —
    -- so a failed/laggy spawn never charges the player or orphans the car at state 0.
    local price = SV_Config.ImpoundPrice
    local cash, bank = Player.PlayerData.money['cash'] or 0, Player.PlayerData.money['bank'] or 0
    if (cash + bank) < price then
        TriggerClientEvent('ox_lib:notify', src, { title = 'HK Parking', description = Lang:t('error.not_enough'), type = 'error' })
        return
    end
    -- Trigger the client spawn; it calls confirmImpoundRetrieve on success.
    TriggerClientEvent('hk-garage:client:takeOutGarage', src, {
        vehicle = row.vehicle, plate = plate,
        garage = { spawnPoint = { spawn } },
        stats = {}, type = 'impound',
        impoundConfirm = { plate = plate, kind = kind },   -- client echoes back on spawn
    })
end)

-- Fired by the client ONLY after the retrieved car actually spawned. Re-validates
-- ownership + impound state, charges the flat fee (+ mechanic cut), routes billing,
-- and releases the car to state 0. Idempotent-ish: if it's no longer impounded
-- (already confirmed) it no-ops, so a double-fire can't double-charge.
RegisterNetEvent('hk-garage:server:confirmImpoundRetrieve', function(plate, kind)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player or not plate then return end
    plate = tostring(plate):gsub("^%s*(.-)%s*$", "%1"):upper()
    local st = (kind == 'police') and 2 or 4
    local row = MySQL.single.await('SELECT towedby FROM player_vehicles WHERE plate = ? AND citizenid = ? AND '..sql.state..' = ? LIMIT 1',
        { plate, Player.PlayerData.citizenid, st })
    if not row then return end   -- not (still) impounded → already confirmed / invalid
    local price = SV_Config.ImpoundPrice
    local cash = Player.PlayerData.money['cash'] or 0
    if cash >= price then Player.Functions.RemoveMoney('cash', price, 'impound-retrieve')
    else Player.Functions.RemoveMoney('bank', price, 'impound-retrieve') end
    local cut = 0
    if st == 4 and row.towedby and row.towedby ~= '' then
        cut = math.floor(price * (SV_Config.Mechanic.retrievalCut or 0))
        if cut > 0 and PayTowMechanic then PayTowMechanic(row.towedby, cut, plate) end
    end
    local society = (st == 2) and (SV_Config.Billing.policeImpoundSociety or SV_Config.Billing.depotSociety) or SV_Config.Billing.depotSociety
    RouteFeeToBilling(Player.PlayerData.citizenid, price - cut, society, (st == 2) and 'Police Impound' or 'Depot Retrieval')
    MySQL.update('UPDATE player_vehicles SET '..sql.state..' = 0, towedby = NULL, depotprice = 0 WHERE plate = ?', { plate })
    TriggerClientEvent('ox_lib:notify', src, { title = 'HK Parking', description = ('已取返車輛 · Retrieved (-$%s)'):format(price), type = 'success' })
end)