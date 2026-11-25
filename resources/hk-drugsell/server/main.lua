local QBCore = exports['qb-core']:GetCoreObject()

-- ─── Helpers ──────────────────────────────────────────────────────────────────

local function getPlayerItems(source)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then return {} end
    return Player.PlayerData.items or {}
end

local function getItemCount(source, itemName)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then return 0 end
    local item = Player.Functions.GetItemByName(itemName)
    return item and item.amount or 0
end

local function removeItem(source, itemName, amount)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then return false end
    if getItemCount(source, itemName) < amount then return false end
    Player.Functions.RemoveItem(itemName, amount)
    TriggerClientEvent('inventory:client:ItemBox', source, QBCore.Shared.Items[itemName], 'remove', amount)
    return true
end

local function addMoney(source, amount)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then return false end
    Player.Functions.AddMoney('cash', amount, 'drug-sale')
    return true
end

-- ─── Discord Logging ──────────────────────────────────────────────────────────

local function logToDiscord(title, message, color)
    if Config.DiscordWebhook == '' then return end
    local embed = {
        {
            title = title,
            description = message,
            color = color or 16753920,
            footer = { text = os.date('%Y-%m-%d %H:%M:%S') },
        }
    }
    PerformHttpRequest(Config.DiscordWebhook, function() end, 'POST', json.encode({
        username = Config.DiscordUsername,
        avatar_url = Config.DiscordAvatar,
        embeds = embed,
    }), { ['Content-Type'] = 'application/json' })
end

-- ─── Callbacks ────────────────────────────────────────────────────────────────

lib.callback.register('hk-drugsell:server:getAvailableDrugs', function(source)
    local available = {}
    for _, drug in ipairs(Config.Drugs) do
        local count = getItemCount(source, drug.item)
        if count > 0 then
            table.insert(available, {
                id = drug.id,
                label = drug.label,
                item = drug.item,
                icon = drug.icon,
                color = drug.color,
                minPrice = drug.minPrice,
                maxPrice = drug.maxPrice,
                happyPrice = drug.happyPrice,
                description = drug.description,
                count = count,
            })
        end
    end
    return available
end)

lib.callback.register('hk-drugsell:server:processSale', function(source, drugId, price, quantity)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then return false end

    -- Find drug config
    local drugConfig = nil
    for _, drug in ipairs(Config.Drugs) do
        if drug.id == drugId then
            drugConfig = drug
            break
        end
    end
    if not drugConfig then return false end

    -- Validate price bounds
    if price < drugConfig.minPrice or price > drugConfig.maxPrice then return false end
    if quantity < 1 then return false end

    -- Check and remove item
    local currentCount = getItemCount(source, drugConfig.item)
    if currentCount < quantity then return false end

    local removed = removeItem(source, drugConfig.item, quantity)
    if not removed then return false end

    -- Pay player
    local totalPay = price * quantity

    -- Bonus pay chance
    if math.random() < Config.BonusPayChance then
        local bonus = math.floor(totalPay * (math.random(10, 25) / 100))
        totalPay = totalPay + bonus
    end

    addMoney(source, totalPay)

    -- Dispatch
    if Config.DispatchSystem ~= 'none' and math.random() < Config.DispatchChance then
        -- Trigger dispatch here if you add one later
    end

    -- Log
    local playerName = Player.PlayerData.charinfo.firstname .. ' ' .. Player.PlayerData.charinfo.lastname
    local citizenId = Player.PlayerData.citizenid
    logToDiscord('Drug Sale', string.format(
        '**Player:** %s (%s)\n**Drug:** %s x%d\n**Price:** $%s\n**Total Earned:** $%s',
        playerName, citizenId, drugConfig.label, quantity, price, totalPay
    ), 3066993)

    return true
end)

-- ─── Yeet / drive-by drug-jack + recovery ─────────────────────────────────────
-- The driver grabs your drugs without paying and floors it. We remove the item
-- (no pay) and BANK it server-side against that specific robber ped, keyed to
-- the victim's citizenid. Killing the robber + searching the body returns the
-- exact banked stack — single use, so there's no dupe. Item moves are all
-- server-authoritative; the client only reports which drug/qty/robber.
--   robberKey = victim citizenid .. '|' .. robber netId (netId from client)
local stolenBank = {}  -- [robberKey] = { item, label, quantity, victim, t }

lib.callback.register('hk-drugsell:server:processSteal', function(source, drugId, quantity, robberNetId)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then return false end
    if not robberNetId then return false end

    local drugConfig = nil
    for _, drug in ipairs(Config.Drugs) do
        if drug.id == drugId then drugConfig = drug; break end
    end
    if not drugConfig then return false end
    if quantity < 1 then return false end

    -- Take the drugs (no payment) — must actually have them.
    local currentCount = getItemCount(source, drugConfig.item)
    if currentCount < quantity then return false end
    if not removeItem(source, drugConfig.item, quantity) then return false end

    -- Bank the stolen stack against this robber for later recovery.
    local cid = Player.PlayerData.citizenid
    local key = cid .. '|' .. tostring(robberNetId)
    stolenBank[key] = {
        item = drugConfig.item, label = drugConfig.label,
        quantity = quantity, victim = cid, t = os.time(),
    }

    logToDiscord('Drug Jacked', string.format(
        '**Victim:** %s\n**Lost:** %s x%d\n**Robber netId:** %s',
        cid, drugConfig.label, quantity, tostring(robberNetId)
    ), 15158332)

    return true
end)

-- Search the dead robber's body. Returns the banked stack if this player is the
-- victim and the token exists; burns the token so it can only be recovered once.
lib.callback.register('hk-drugsell:server:recoverStolen', function(source, robberNetId)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player or not robberNetId then return false end
    local cid = Player.PlayerData.citizenid
    local key = cid .. '|' .. tostring(robberNetId)

    local loot = stolenBank[key]
    if not loot then return false end       -- not the victim, or already looted
    stolenBank[key] = nil                   -- burn token FIRST (no double-loot)

    Player.Functions.AddItem(loot.item, loot.quantity)
    TriggerClientEvent('inventory:client:ItemBox', source, QBCore.Shared.Items[loot.item], 'add', loot.quantity)

    logToDiscord('Drugs Recovered', string.format(
        '**Player:** %s\n**Recovered:** %s x%d', cid, loot.label, loot.quantity
    ), 3066993)

    return { item = loot.item, label = loot.label, quantity = loot.quantity }
end)

-- Prune stale banked stacks (robber despawned / never killed) after 30 min.
CreateThread(function()
    while true do
        Wait(300000)
        local now = os.time()
        for k, v in pairs(stolenBank) do
            if now - v.t > 1800 then stolenBank[k] = nil end
        end
    end
end)

-- ─── AI Dialog Proxy (hk-npc-gateway) ─────────────────────────────────────────
-- Clients can't reach the .247 LAN gateway, so the server proxies the call.
-- Returns nil on any failure/timeout → client uses its static Cantonese line.
lib.callback.register('hk-drugsell:server:aiLine', function(source, message, context, action)
    if not Config.AI or not Config.AI.enabled then return nil end

    local p = promise.new()
    local done = false
    local function finish(val)
        if done then return end
        done = true
        p:resolve(val)
    end

    local body = json.encode({
        persona = Config.AI.persona,
        message = tostring(message or ''):sub(1, 500),
        context = tostring(context or ''):sub(1, 400),
        -- Lua-decided outcome; gateway pins the model to it so the spoken line
        -- matches the real accept/reject/counter result.
        action  = action and tostring(action) or nil,
    })

    PerformHttpRequest(Config.AI.url, function(status, resp, _headers)
        if status ~= 200 or not resp then return finish(nil) end
        local ok, decoded = pcall(json.decode, resp)
        if not ok or type(decoded) ~= 'table' or not decoded.dialog then
            return finish(nil)
        end
        -- Honour brain/body split: only take the spoken line. If the gateway
        -- itself fell back (no live model output) keep our own beat line.
        if Config.AI.useOnlyLiveOrCache
           and decoded.source ~= 'live' and decoded.source ~= 'cache' then
            return finish(nil)
        end
        finish(decoded.dialog)
    end, 'POST', body, {
        ['Content-Type']  = 'application/json',
        ['Authorization'] = 'Bearer ' .. (Config.AI.token or ''),
    })

    -- Safety timeout so a wedged HTTP call never hangs the callback.
    SetTimeout((Config.AI.timeoutMs or 2500) + 300, function() finish(nil) end)

    return Citizen.Await(p)
end)

lib.callback.register('hk-drugsell:server:isPlayerCop', function(source, targetServerId)
    local TargetPlayer = QBCore.Functions.GetPlayer(targetServerId)
    if not TargetPlayer then return false end
    local job = TargetPlayer.PlayerData.job
    if not job then return false end
    for _, policeJob in ipairs(Config.PoliceJobs) do
        if job.name == policeJob then
            return true
        end
    end
    return false
end)
