local QBCore = exports['qb-core']:GetCoreObject()
local cooldowns = {}
local currentPed = nil
local isBusy = false
local vehicleSale = false   -- true when the current dialog is a window sale (driver in car)

-- ─── AI Dialog line (hk-npc-gateway, via server proxy) ─────────────────────────
-- Asks the Cantonese AI for this beat's spoken line. The server owns the actual
-- HTTP call (clients can't reach the LAN gateway). Returns `fallback` on any
-- failure/timeout so a slow model never blocks or blanks the dialog. The AI only
-- writes the line — every mechanical decision is already made here in Lua.
--   action: the Lua-decided outcome (greet/deal/refuse/haggle/threaten/flee).
--   The gateway pins the model to this action so the spoken line matches the
--   real outcome (accept vs reject vs counter) instead of the model guessing.
local function aiLine(action, message, context, fallback)
    if not (Config.AI and Config.AI.enabled) then return fallback end
    local ok, line = pcall(function()
        return lib.callback.await('hk-drugsell:server:aiLine', false, message, context, action)
    end)
    if ok and type(line) == 'string' and line ~= '' then
        return line
    end
    return fallback
end

-- ─── Utility ──────────────────────────────────────────────────────────────────

local function isBlacklistedModel(ped)
    local model = GetEntityModel(ped)
    for _, blacklisted in ipairs(Config.BlacklistedModels) do
        if model == blacklisted then
            return true
        end
    end
    return false
end

local function isPlayerPed(ped)
    -- Native check first (covers every connected player ped, cheaper than the loop)
    if IsPedAPlayer(ped) then return true end
    for _, id in ipairs(GetActivePlayers()) do
        if GetPlayerPed(id) == ped then
            return true
        end
    end
    return false
end

-- Only allow ped types the GTA engine spawned as ambient street pedestrians.
-- Blocks animals (dogs/cats), companion pets, and any ped created by another
-- script/resource (jobs, missions, MLO staff, event NPCs, keep-companions).
local function isAmbientStreetPed(ped)
    if not Config.OnlyAmbientPeds then return true end

    -- Must be a human — kills all animals (dogs, cats, etc) outright.
    if Config.RequireHumanPed and not IsPedHuman(ped) then
        return false
    end

    -- Mission entities are script-owned peds (companions, pets set to keep,
    -- job/quest NPCs). Ambient street peds are never mission entities.
    if Config.RejectScriptedPeds and IsEntityAMissionEntity(ped) then
        return false
    end

    -- Population type must be one of the ambient street-spawn buckets.
    -- PERMANENT(0)/MISSION(6)/TOOL(7) peds belong to scripts, not the street.
    local popType = GetEntityPopulationType(ped)
    if not Config.AllowedPedPopulationTypes[popType] then
        return false
    end

    return true
end

local function isOnCooldown(ped)
    local netId = PedToNet and NetworkGetEntityIsNetworked(ped) and NetworkGetNetworkIdFromEntity(ped)
    local key = netId or tostring(ped)
    if cooldowns[key] and (GetGameTimer() - cooldowns[key]) < Config.PedCooldown then
        return true
    end
    return false
end

local function setCooldown(ped)
    local netId = PedToNet and NetworkGetEntityIsNetworked(ped) and NetworkGetNetworkIdFromEntity(ped)
    local key = netId or tostring(ped)
    cooldowns[key] = GetGameTimer()
end

local function isPedScaredOrFleeing(ped)
    if IsPedFleeing(ped) then return true end
    if IsPedInCombat(ped, 0) then return true end
    if IsPedInMeleeCombat(ped) then return true end
    return false
end

local function isValidTarget(entity)
    if not DoesEntityExist(entity) then return false end
    if not IsEntityAPed(entity) then return false end
    if IsEntityDead(entity) then return false end
    if isPlayerPed(entity) then return false end
    if not isAmbientStreetPed(entity) then return false end
    if isBlacklistedModel(entity) then return false end
    if isOnCooldown(entity) then return false end
    if IsPedInAnyVehicle(entity, false) then return false end
    if isPedScaredOrFleeing(entity) then return false end
    return true
end

-- Valid target for a WINDOW sale. qb-target's AddGlobalVehicle raycast hits the
-- VEHICLE (not the seated ped), so `entity` here is the car. We resolve the
-- driver ourselves and validate that ped with the normal street-ped rules.
-- Returns the driver ped on success (truthy), or false. Callers that need the
-- ped use `resolveVehicleDriver` below; canInteract only cares about truthiness.
local function isValidVehicleTarget(entity)
    local V = Config.Vehicle
    if not (V and V.enabled) then return false end
    if not DoesEntityExist(entity) then return false end
    if not IsEntityAVehicle(entity) then return false end

    -- Car must be basically stopped so you can lean in and talk.
    if GetEntitySpeed(entity) > (V.maxSpeed or 2.5) then return false end

    -- Driver seat only (seat index -1 is the driver).
    local ped = GetPedInVehicleSeat(entity, -1)
    if not ped or ped == 0 or not DoesEntityExist(ped) then return false end

    if not IsEntityAPed(ped) then return false end
    if IsEntityDead(ped) then return false end
    if isPlayerPed(ped) then return false end
    if not isAmbientStreetPed(ped) then return false end
    if isBlacklistedModel(ped) then return false end
    if isOnCooldown(ped) then return false end
    if isPedScaredOrFleeing(ped) then return false end
    return ped
end

-- Given the vehicle qb-target handed us, return the driver ped (or nil).
local function resolveVehicleDriver(veh)
    if not veh or veh == 0 or not DoesEntityExist(veh) or not IsEntityAVehicle(veh) then
        return nil
    end
    local ped = GetPedInVehicleSeat(veh, -1)
    if ped and ped ~= 0 and DoesEntityExist(ped) then return ped end
    return nil
end

-- ─── Police Call (time-of-day scaled) ─────────────────────────────────────────

local function getPoliceCallChance()
    -- Game hours: 6-20 = daytime, 21-5 = nighttime
    local hour = GetClockHours()
    local baseChance = Config.PoliceCallChance or 0.25

    if hour >= 7 and hour <= 19 then
        -- Daytime: higher chance (x1.5)
        return baseChance * 1.5
    elseif hour >= 20 or hour <= 5 then
        -- Nighttime: lower chance (x0.4)
        return baseChance * 0.4
    else
        -- Dawn/dusk transitions
        return baseChance
    end
end

local function tryPoliceCall()
    local chance = getPoliceCallChance()
    if math.random() < chance then
        exports['ps-dispatch']:DrugSale()
        lib.notify({ title = '佢老母閪走去報警！', type = 'error', position = 'top', icon = 'phone' })
        return true
    end
    return false
end

-- ─── Cop Detection ────────────────────────────────────────────────────────────

local function isCopNearby()
    local playerCoords = GetEntityCoords(PlayerPedId())
    local players = QBCore.Functions.GetPlayers()
    for _, playerId in ipairs(players) do
        local targetPed = GetPlayerPed(playerId)
        if targetPed ~= PlayerPedId() then
            local dist = #(playerCoords - GetEntityCoords(targetPed))
            if dist <= Config.CopWarningRadius then
                local isCop = lib.callback.await('hk-drugsell:server:isPlayerCop', false, GetPlayerServerId(playerId))
                if isCop then
                    return true
                end
            end
        end
    end
    return false
end

-- ─── NPC Behavior ─────────────────────────────────────────────────────────────

local function makeNpcFacePlayer(ped)
    -- Lock the ped FIRST so ambient AI cant reclaim them
    SetBlockingOfNonTemporaryEvents(ped, true)
    SetPedKeepTask(ped, true)
    ClearPedTasksImmediately(ped)
    Wait(50)

    -- Turn to face the player
    local playerPed = PlayerPedId()
    TaskTurnPedToFaceEntity(ped, playerPed, 2000)
    Wait(1000)

    -- Now hold them looking + standing still
    TaskStandStill(ped, -1)
    TaskLookAtEntity(ped, playerPed, -1, 2048, 3)
end

local function releaseNpc(ped)
    if not DoesEntityExist(ped) then return end
    SetBlockingOfNonTemporaryEvents(ped, false)
    SetPedKeepTask(ped, false)
    ClearPedTasks(ped)
end

local function makeNpcAggro(ped)
    releaseNpc(ped)
    local weapon = Config.AggroWeapons[math.random(#Config.AggroWeapons)]
    GiveWeaponToPed(ped, GetHashKey(weapon), 100, false, true)
    SetPedCombatAttributes(ped, 5, true)
    SetPedCombatAttributes(ped, 46, true)
    TaskCombatPed(ped, PlayerPedId(), 0, 16)
    local msg = Config.AggroMessages[math.random(#Config.AggroMessages)]
    lib.notify({ title = msg, type = 'error', position = 'top' })
end

local function makeNpcWalkAway(ped)
    if not DoesEntityExist(ped) then return end
    releaseNpc(ped)
    local pedCoords = GetEntityCoords(ped)
    local heading = GetEntityHeading(ped) + 180.0
    local rad = heading * math.pi / 180.0
    local dest = vector3(pedCoords.x + math.sin(rad) * 20.0, pedCoords.y + math.cos(rad) * 20.0, pedCoords.z)
    TaskGoStraightToCoord(ped, dest.x, dest.y, dest.z, 1.0, 8000, heading, 0.0)
    SetPedKeepTask(ped, true)
    Wait(3000)
    if DoesEntityExist(ped) then
        SetPedKeepTask(ped, false)
        SetEntityAsNoLongerNeeded(ped)
    end
end

local function makeNpcFleeScared(ped)
    if not DoesEntityExist(ped) then return end
    releaseNpc(ped)
    -- NPC runs away scared (used when they call police)
    local playerCoords = GetEntityCoords(PlayerPedId())
    TaskSmartFleeCoord(ped, playerCoords.x, playerCoords.y, playerCoords.z, 80.0, 8000, true, true)
    SetEntityAsNoLongerNeeded(ped)
end

-- ─── Vehicle Yeet (drive-by drug-jack) ────────────────────────────────────────
-- The driver grabs the drugs and floors it. Sometimes they lean out and pop a
-- few rounds first, then peel off. The ped stays around long enough for the
-- player to gun them down and search the body (recovery is registered by the
-- caller). If they get away clean they eventually despawn and the drugs are lost.
local function vehicleYeetAndFlee(ped, shoot)
    if not DoesEntityExist(ped) then return end
    local veh = GetVehiclePedIsIn(ped, false)
    releaseNpc(ped)
    SetBlockingOfNonTemporaryEvents(ped, true)   -- keep ambient AI from reclaiming it

    if veh and veh ~= 0 and DoesEntityExist(veh) then
        SetVehicleEngineOn(veh, true, true, false)

        if shoot then
            local wname = Config.AggroWeapons[math.random(#Config.AggroWeapons)]
            local whash = GetHashKey(wname)
            GiveWeaponToPed(ped, whash, 250, false, true)
            SetCurrentPedWeapon(ped, whash, true)
            SetPedCombatAttributes(ped, 46, true)  -- always fight
            local tp = PlayerPedId()
            local tc = GetEntityCoords(tp)
            -- Drive-by at the player from the car.
            TaskDriveBy(ped, tp, 0, tc.x, tc.y, tc.z, 50.0, 100, true, GetHashKey('FIRING_PATTERN_FULL_AUTO'))
            Wait(((Config.Vehicle and Config.Vehicle.yeetShots) or 3) * 550)
            if DoesEntityExist(ped) then ClearPedTasks(ped) end
        end

        -- Peel out and wander off fast (rushed/aggressive driving style).
        if DoesEntityExist(ped) and not IsEntityDead(ped) then
            TaskVehicleDriveWander(ped, veh, 45.0, 1074528293)
            SetPedKeepTask(ped, true)
        end
    end

    -- Give the player a window to catch/kill them, then let the ped clean up.
    Wait(8000)
    if DoesEntityExist(ped) then
        SetPedKeepTask(ped, false)
        SetEntityAsNoLongerNeeded(ped)
    end
    if veh and veh ~= 0 and DoesEntityExist(veh) then
        SetEntityAsNoLongerNeeded(veh)
    end
end

-- Roll for a window-sale drug-jack at the moment of handover. On a hit the driver
-- steals the drugs (server takes them, no pay, banks them for recovery), taunts
-- via the AI, maybe shoots, then flees — and we register a body-search target so
-- killing them returns the exact stolen stack. Returns true if the yeet happened
-- (caller should abort the normal sale), false to fall through to a real sale.
local function tryVehicleYeet(ped, drugId, quantity)
    local V = Config.Vehicle
    if not (vehicleSale and V and V.enabled) then return false end
    if not (ped and DoesEntityExist(ped)) then return false end
    if math.random() >= (V.yeetChance or 0.08) then return false end

    -- Ensure a stable netId so the server bank key + body recovery agree.
    if not NetworkGetEntityIsNetworked(ped) then
        NetworkRegisterEntityAsNetworked(ped)
    end
    local robberNetId = NetworkGetNetworkIdFromEntity(ped)
    if not robberNetId or robberNetId == 0 then return false end

    -- Server takes the drugs (no pay) and banks them. If it can't, bail to a
    -- normal sale rather than eating the drugs for nothing.
    local ok = lib.callback.await('hk-drugsell:server:processSteal', false, drugId, quantity, robberNetId)
    if not ok then return false end

    -- The "deal" just became a robbery — kill the dialog.
    SetNuiFocus(false, false)
    SendNUIMessage({ action = 'closeDialog' })

    local taunt = aiLine('steal', '（你一手搶咗佢啲貨，唔俾錢，即刻踩油走）',
        'You are the driver. You just grabbed the dealer drugs without paying and are flooring it to escape. Taunt them.',
        '多謝曬喇笨柒，慢慢企喺度啦！')
    lib.notify({ title = taunt, type = 'error', position = 'top', duration = 6000 })

    -- Body recovery: gun them down, search the corpse, get the exact stack back.
    exports['qb-target']:AddTargetEntity(ped, {
        options = {
            {
                icon = 'fas fa-hand-holding-medical',
                label = V.recoverLabel or '搜身攞返貨',
                distance = V.recoverDistance or 1.8,
                canInteract = function(entity)
                    return entity and DoesEntityExist(entity) and IsEntityDead(entity)
                end,
                action = function()
                    local loot = lib.callback.await('hk-drugsell:server:recoverStolen', false, robberNetId)
                    if loot then
                        lib.notify({ title = string.format('搜返 %s x%d', loot.label, loot.quantity), type = 'success', position = 'top' })
                    else
                        lib.notify({ title = '搜極都冇貨', type = 'error', position = 'top' })
                    end
                end,
            },
        },
    })

    local shoot = math.random() < (V.yeetShootChance or 0.40)
    CreateThread(function() vehicleYeetAndFlee(ped, shoot) end)

    setCooldown(ped)
    return true
end

-- ─── Target Setup ─────────────────────────────────────────────────────────────

local function initTarget()
    local vcfg = Config.Vehicle or {}

    -- Foot sale: aim at the ped.
    exports['qb-target']:AddGlobalPed({
        options = {
            {
                icon = 'fas fa-pills',
                label = '大茶飯',
                canInteract = function(entity, distance)
                    if isBusy then return false end
                    if not isValidTarget(entity) then return false end
                    return true
                end,
                action = function(entity)
                    if isBusy then return end
                    TriggerEvent('hk-drugsell:client:startDialog', entity, false)
                end,
            },
        },
        distance = Config.TargetDistance,
    })

    -- Window sale: aim at the CAR (qb-target raycasts to the vehicle for a
    -- seated driver, not the ped), then we deal with whoever's driving.
    if vcfg.enabled then
        exports['qb-target']:AddGlobalVehicle({
            options = {
                {
                    icon = 'fas fa-car-side',
                    label = '車窗交易',
                    canInteract = function(entity, distance)
                        if isBusy then return false end
                        if not (Config.Vehicle and Config.Vehicle.enabled) then return false end
                        return isValidVehicleTarget(entity) and true or false
                    end,
                    action = function(entity)
                        if isBusy then return end
                        local ped = resolveVehicleDriver(entity)
                        if not ped then
                            lib.notify({ title = '車入面冇人揸車', type = 'error', position = 'top' })
                            return
                        end
                        TriggerEvent('hk-drugsell:client:startDialog', ped, true)
                    end,
                },
            },
            distance = math.max(Config.TargetDistance, vcfg.targetDistance or 0.0),
        })
    end
end

-- ─── Dialog Flow ──────────────────────────────────────────────────────────────

RegisterNetEvent('hk-drugsell:client:startDialog', function(ped, isVehicle)
    if isBusy then return end
    -- Window sales validate against the vehicle rules (via the driver's car);
    -- foot sales the normal way. Here `ped` is the driver in both branches.
    if isVehicle then
        local veh = ped and DoesEntityExist(ped) and GetVehiclePedIsIn(ped, false)
        if not veh or veh == 0 or not isValidVehicleTarget(veh) then
            lib.notify({ title = '條友話唔撚買你啲貨！', type = 'error', position = 'top' })
            return
        end
    elseif not isValidTarget(ped) then
        lib.notify({ title = '條友話唔撚買你啲貨！', type = 'error', position = 'top' })
        return
    end

    isBusy = true
    currentPed = ped
    vehicleSale = isVehicle == true

    -- Check blacklisted job
    local playerData = QBCore.Functions.GetPlayerData()
    for _, job in ipairs(Config.BlacklistedPlayerJobs) do
        if playerData.job and playerData.job.name == job then
            lib.notify({ title = '你份工冇得做大茶飯！', type = 'error', position = 'top' })
            isBusy = false
            currentPed = nil
            return
        end
    end

    -- Cop warning check
    if isCopNearby() then
        local warning = Config.CopWarningMessages[math.random(#Config.CopWarningMessages)]
        lib.notify({ title = warning, type = 'warning', position = 'top' })
    end

    -- Aggro roll (skip for window sales — the driver stays in their seat)
    if not vehicleSale and math.random() < Config.AggroChance then
        makeNpcAggro(ped)
        setCooldown(ped)
        isBusy = false
        currentPed = nil
        return
    end

    -- Make NPC stop and face the player. For a window sale we DON'T drag the
    -- driver out — just lock them still in the car looking at the player.
    if vehicleSale then
        SetBlockingOfNonTemporaryEvents(ped, true)
        SetPedKeepTask(ped, true)
        local veh = GetVehiclePedIsIn(ped, false)
        if veh and veh ~= 0 then BringVehicleToHalt(veh, 3.0, 2, false) end
        TaskLookAtEntity(ped, PlayerPedId(), -1, 2048, 3)
    else
        makeNpcFacePlayer(ped)
    end
    Wait(500)

    -- Get available drugs from inventory
    local availableDrugs = lib.callback.await('hk-drugsell:server:getAvailableDrugs', false)

    if not availableDrugs or #availableDrugs == 0 then
        lib.notify({ title = '你身上乜貨都冇！', type = 'error', position = 'top' })
        releaseNpc(ped)
        isBusy = false
        currentPed = nil
        return
    end

    -- Open NUI dialog
    local greeting = Config.NPCGreetings[math.random(#Config.NPCGreetings)]
    local offer = Config.SellOffers[math.random(#Config.SellOffers)]
    -- Let the AI voice the greeting (falls back to the static line on any delay).
    greeting = aiLine('greet', '（有拆家行埋嚟想兜你買貨）', 'A street dealer just walked up trying to sell you drugs. You are the customer.', greeting)

    SetNuiFocus(true, true)
    SendNUIMessage({
        action = 'openDialog',
        greeting = greeting,
        offer = offer,
        drugs = availableDrugs,
        buyQuantity = Config.BuyQuantity,
        npcTolerance = Config.NpcTolerance,
    })
end)

-- ─── NUI Callbacks ────────────────────────────────────────────────────────────

RegisterNUICallback('sellDrug', function(data, cb)
    cb('ok')
    local drugId = data.drugId
    local price = tonumber(data.price)
    local quantity = tonumber(data.quantity) or 1

    if not currentPed or not DoesEntityExist(currentPed) then
        SetNuiFocus(false, false)
        SendNUIMessage({ action = 'closeDialog' })
        isBusy = false
        currentPed = nil
        return
    end

    -- Find drug config
    local drugConfig = nil
    for _, drug in ipairs(Config.Drugs) do
        if drug.id == drugId then
            drugConfig = drug
            break
        end
    end

    if not drugConfig then
        isBusy = false
        return
    end

    -- NPC decides based on their tolerance + drug difficulty
    local npcTolerance = tonumber(data.npcTolerance) or 0.5
    local difficulty = drugConfig.difficulty or 2
    local diffMods = Config.DifficultyModifiers[difficulty] or Config.DifficultyModifiers[2]

    -- Apply difficulty tolerance multiplier
    local adjustedTolerance = math.min(npcTolerance * diffMods.toleranceMult, 1.0)

    local priceRange = drugConfig.maxPrice - drugConfig.minPrice
    local npcMaxPrice = drugConfig.minPrice + (priceRange * adjustedTolerance)

    -- How far over the NPC max are we?
    local overRatio = 0
    if price > npcMaxPrice then
        overRatio = (price - npcMaxPrice) / (drugConfig.maxPrice - npcMaxPrice + 1)
    end

    -- Flat reject: NPC just doesn't want this drug at all
    if math.random() < diffMods.rejectChance then
        local rejectLine = aiLine('refuse', '（我唔想幫襯買呢隻貨）', 'You do not want to buy this drug at all.', "我係良好市民，向毒品說不！")
        SendNUIMessage({ action = 'npcReaction', message = rejectLine, success = false })
        setCooldown(currentPed)
        Wait(2500)
        SetNuiFocus(false, false)
        SendNUIMessage({ action = 'closeDialog' })
        makeNpcWalkAway(currentPed)
        isBusy = false
        currentPed = nil
        return
    end

    local accepted = false
    if price <= npcMaxPrice then
        accepted = true
    elseif price <= npcMaxPrice * 1.1 then
        accepted = math.random() > 0.6
    else
        accepted = false
    end

    if accepted then
        -- Window sale: at the moment of handover the driver might just grab the
        -- drugs and floor it instead of paying.
        if tryVehicleYeet(currentPed, drugId, quantity) then
            isBusy = false
            currentPed = nil
            vehicleSale = false
            return
        end
        local success = lib.callback.await('hk-drugsell:server:processSale', false, drugId, price, quantity)
        if success then
            local reaction = Config.PriceAcceptedReactions[math.random(#Config.PriceAcceptedReactions)]
            reaction = aiLine('deal', '（個價啱數，我買咗，畀咗錢）', 'You paid the dealer and got your drugs.', reaction)
            SendNUIMessage({ action = 'npcReaction', message = reaction, success = true })
            setCooldown(currentPed)
            Wait(2500)
            SetNuiFocus(false, false)
            SendNUIMessage({ action = 'closeDialog' })
            makeNpcWalkAway(currentPed)
        else
            SendNUIMessage({ action = 'npcReaction', message = 'Something went wrong...', success = false })
            Wait(2000)
            SetNuiFocus(false, false)
            SendNUIMessage({ action = 'closeDialog' })
            releaseNpc(currentPed)
        end
    else
        -- Price too high — multiple outcomes based on how greedy the player was

        -- 1) If WAY over (>80% into red), chance NPC goes aggro
        if overRatio > 0.8 and math.random() < (Config.PriceAggroChance * diffMods.aggroMult) then
            SetNuiFocus(false, false)
            SendNUIMessage({ action = 'closeDialog' })
            makeNpcAggro(currentPed)
            setCooldown(currentPed)
            isBusy = false
            currentPed = nil
            return
        end

        -- 2) Counter-offer chance — NPC suggests a lower price
        if math.random() < (Config.CounterOfferChance * diffMods.counterMult) then
            -- NPC counters at a price they would accept (random between min and their max)
            local counterPrice = math.floor(drugConfig.minPrice + math.random() * (npcMaxPrice - drugConfig.minPrice))
            -- Static fallback keeps the price via $%s; the AI line drops the number
            -- (the price is shown on the NUI Accept button instead), so we ask the
            -- AI to haggle for a lower price generically.
            local fallbackMsg = string.format(Config.CounterOfferLines[math.random(#Config.CounterOfferLines)], counterPrice)
            local counterMsg = aiLine('haggle', '（個價太貴，我想還價，開個平啲嘅價）', 'The dealer priced too high. You are haggling the price down. Do NOT say any number — just ask for it cheaper.', fallbackMsg)
            SendNUIMessage({
                action = 'counterOffer',
                message = counterMsg,
                counterPrice = counterPrice,
                drugId = drugId,
                quantity = quantity,
                npcTolerance = npcTolerance,
            })
            -- Wait for player response (handled by acceptCounter / rejectCounter callbacks)
            return
        end

        -- 3) Standard rejection — walk away + possible police call
        local reaction = Config.PriceTooHighReactions[math.random(#Config.PriceTooHighReactions)]
        reaction = aiLine('refuse', '（拆家開價太貴，我唔買）', 'The dealer is charging way too much.', reaction)
        SendNUIMessage({ action = 'npcReaction', message = reaction, success = false })
        setCooldown(currentPed)
        Wait(2500)
        SetNuiFocus(false, false)
        SendNUIMessage({ action = 'closeDialog' })

        -- Police call roll (time-of-day scaled)
        local calledCops = tryPoliceCall()
        if calledCops then
            makeNpcFleeScared(currentPed)
        else
            makeNpcWalkAway(currentPed)
        end
    end

    isBusy = false
    currentPed = nil
end)

-- Accept the counter offer
RegisterNUICallback('acceptCounter', function(data, cb)
    cb('ok')
    local drugId = data.drugId
    local price = tonumber(data.counterPrice)
    local quantity = tonumber(data.quantity) or 1

    if not currentPed or not DoesEntityExist(currentPed) then
        SetNuiFocus(false, false)
        SendNUIMessage({ action = 'closeDialog' })
        isBusy = false
        currentPed = nil
        return
    end

    -- Window sale: the accepted counter can still turn into a drive-by grab.
    if tryVehicleYeet(currentPed, drugId, quantity) then
        isBusy = false
        currentPed = nil
        vehicleSale = false
        return
    end

    local success = lib.callback.await('hk-drugsell:server:processSale', false, drugId, price, quantity)
    if success then
        local reaction = Config.PriceAcceptedReactions[math.random(#Config.PriceAcceptedReactions)]
        reaction = aiLine('deal', '（拆家收咗我嘅還價，成交）', 'The dealer accepted the lower price you offered and the deal is done.', reaction)
        SendNUIMessage({ action = 'npcReaction', message = reaction, success = true })
        setCooldown(currentPed)
        Wait(2500)
        SetNuiFocus(false, false)
        SendNUIMessage({ action = 'closeDialog' })
        makeNpcWalkAway(currentPed)
    else
        SendNUIMessage({ action = 'npcReaction', message = 'Something went wrong...', success = false })
        Wait(2000)
        SetNuiFocus(false, false)
        SendNUIMessage({ action = 'closeDialog' })
        releaseNpc(currentPed)
    end

    isBusy = false
    currentPed = nil
end)

-- Reject the counter offer — NPC walks away, small chance calls cops
RegisterNUICallback('rejectCounter', function(data, cb)
    cb('ok')

    if not currentPed or not DoesEntityExist(currentPed) then
        SetNuiFocus(false, false)
        SendNUIMessage({ action = 'closeDialog' })
        isBusy = false
        currentPed = nil
        return
    end

    local reaction = Config.PriceTooHighReactions[math.random(#Config.PriceTooHighReactions)]
    reaction = aiLine('refuse', '（拆家唔肯收我開嘅價，走數）', 'The dealer refused the lower price you offered and the deal fell through.', reaction)
    SendNUIMessage({ action = 'npcReaction', message = reaction, success = false })
    setCooldown(currentPed)
    Wait(2500)
    SetNuiFocus(false, false)
    SendNUIMessage({ action = 'closeDialog' })

    -- Small chance calls cops when you reject their counter
    local calledCops = tryPoliceCall()
    if calledCops then
        makeNpcFleeScared(currentPed)
    else
        makeNpcWalkAway(currentPed)
    end

    isBusy = false
    currentPed = nil
end)

RegisterNUICallback('closeDialog', function(_, cb)
    cb('ok')
    SetNuiFocus(false, false)
    if currentPed and DoesEntityExist(currentPed) then
        releaseNpc(currentPed)
    end
    isBusy = false
    currentPed = nil
end)

-- ─── Init ─────────────────────────────────────────────────────────────────────

CreateThread(function()
    initTarget()
end)

-- Cleanup cooldowns periodically
CreateThread(function()
    while true do
        Wait(60000)
        local now = GetGameTimer()
        for k, v in pairs(cooldowns) do
            if (now - v) > Config.PedCooldown then
                cooldowns[k] = nil
            end
        end
    end
end)
