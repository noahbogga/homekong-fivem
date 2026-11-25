local QBCore = exports['qb-core']:GetCoreObject()

local MAX_PAYOUT = 20000000 -- \$20M hard cap on any single casino payout

-- Blackjack is escrow-bounded (a player can only win as a function of what they
-- staked), unlike the runaway-multiplier games the global MAX_PAYOUT guards. Its
-- theoretical single-round max — every split hand doubled + insurance + all four
-- side bets hitting their top tier — is a known ceiling per room, so give it a
-- room-specific cap set ABOVE that max. This still defends against a payout-
-- inflation bug but never silently clips a legitimately-won hand. Any clip is
-- logged (see bjSettleRoom). Main Floor's true max is ~$1.5M; VIP's is ~$41M.
local BJ_ROOM_CAP = {
    bj_main = 5000000,    -- $5M (true max ~$1.5M — comfortable headroom)
    bj_vip  = 60000000,   -- $60M (true max ~$41M — comfortable headroom)
}
local settlingPlayers = {} -- cid → true while playerDropped is settling games

local lastPlinkoBet = {}
local plinkoPending = {}
local plinkoTimestamps = {}
local plinkoBlocked = {}
local lastPlinkoNotice = {}   -- src -> last GetGameTimer() a rejection toast was sent (throttle)

-- Rapid-fire support (plinko): cache maxBet per cid (short TTL) so we don't do an
-- HTTP round-trip for the bet ceiling on every single ball. The bet ceiling only
-- changes on tier-up / personal-max-bet change, so a 30s cache is safe.
local maxBetCache = {}          -- cid -> { value, at }
local MAXBET_TTL = 30000        -- 30s

local function getMaxBetCached(cid)
    local c = maxBetCache[cid]
    local now = GetGameTimer()
    if c and (now - c.at) < MAXBET_TTL then return c.value end
    local mb = GetPlayerMaxBet(cid)          -- nil on engine outage
    if mb == nil then return nil end
    maxBetCache[cid] = { value = mb, at = now }
    return mb
end
local nicknameCache = {}
local playerLock = {}
local crashBetSources = {} -- cid → src mapping for crash settlement
-- Current crash round state, shared across crashJoin (770), crashBet check (851),
-- and the poll loop (1039). MUST be declared here at module scope: it was
-- previously declared `local` down at the poll loop, so the earlier reads/writes
-- silently hit a nil global — making the bet check see nil ~= "waiting" and reject
-- every bet with "Round already in progress". Single module-level local fixes it.
local crashRoundState = "idle"
local cidCache = {} -- src → citizenid, survives QBCore player nil on disconnect
local dicePayouts = {} -- cid → { src, amount, at } pending until client animation ends
_G.nicknameCache = nicknameCache

-- Demo mode: fake balance, no DB/leaderboard/VIP trace
local demoBalances = {} -- cid → current fake balance
function isDemoPlayer(cid)
    if not Config.DemoMode or not Config.DemoMode.enabled then return false end
    for _, id in ipairs(Config.DemoMode.citizens) do
        if id == cid then return true end
    end
    return false
end
_G.isDemoPlayer = isDemoPlayer

local function getDemoBalance(cid)
    if not demoBalances[cid] then
        demoBalances[cid] = Config.DemoMode.balance or 50000000
    end
    return demoBalances[cid]
end

local function demoRemove(cid, amount)
    local bal = getDemoBalance(cid)
    if bal < amount then return false end
    demoBalances[cid] = bal - amount
    return true
end

local function demoAdd(cid, amount)
    demoBalances[cid] = getDemoBalance(cid) + amount
end

local function demoGetBal(cid)
    return demoBalances[cid] or getDemoBalance(cid)
end

_G.demoGetBal = demoGetBal
_G.demoAdd = demoAdd
_G.demoRemove = demoRemove

-- Admin command: /casinodemo — toggles demo mode for yourself
RegisterCommand('casinodemo', function(src)
    if src == 0 then return end
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    local cid = Player.PlayerData.citizenid
    if not Config.DemoMode then Config.DemoMode = { enabled = true, balance = 50000000, citizens = {} } end
    for i, id in ipairs(Config.DemoMode.citizens) do
        if id == cid then
            table.remove(Config.DemoMode.citizens, i)
            demoBalances[cid] = nil
            TriggerClientEvent('chat:addMessage', src, { args = { "^3[Casino]", "Demo mode OFF — real money active" } })
            TriggerClientEvent('hk-sportsbetting:client:updateBalance', src, Player.PlayerData.money.cash)
            return
        end
    end
    table.insert(Config.DemoMode.citizens, cid)
    demoBalances[cid] = Config.DemoMode.balance
    TriggerClientEvent('chat:addMessage', src, { args = { "^3[Casino]", "Demo mode ON — $" .. tostring(Config.DemoMode.balance) .. " fake balance, no leaderboard" } })
    TriggerClientEvent('hk-sportsbetting:client:updateBalance', src, demoBalances[cid])
end, true)

-- House profit routing: jockeyclub gets house take, forwards cuts to whitehouse/congress
local HOUSE_SPLIT = { whitehouse = 0.13, congress = 0.05 }
function routeHouseProfit(houseProfit)
    if houseProfit <= 0 then return end
    local whCut = math.floor(houseProfit * HOUSE_SPLIT.whitehouse)
    local congCut = math.floor(houseProfit * HOUSE_SPLIT.congress)
    local jockeyCut = houseProfit - whCut - congCut

    if jockeyCut > 0 then
        exports['qb-banking']:AddMoney('jockeyclub', jockeyCut, 'casino-house-take')
    end
    if whCut > 0 then
        exports['qb-banking']:AddMoney('whitehouse', whCut, 'casino-gov-cut')
    end
    if congCut > 0 then
        exports['qb-banking']:AddMoney('congress', congCut, 'casino-gov-cut')
    end
end

local function withLock(src, fn)
    if playerLock[src] then return end
    playerLock[src] = true
    local ok, err = pcall(fn)
    playerLock[src] = nil
    if not ok then
        print('^1[hk-sportsbetting] playerLock handler error: ' .. tostring(err) .. '^0')
    end
end

local function getPlayer(src)
    return QBCore.Functions.GetPlayer(src)
end

local function getCitizenId(src)
    if cidCache[src] then return cidCache[src] end
    local Player = getPlayer(src)
    if Player then
        cidCache[src] = Player.PlayerData.citizenid
        return Player.PlayerData.citizenid
    end
    return nil
end

local function getDisplayName(src)
    if nicknameCache[src] then return nicknameCache[src] end
    local cid = getCitizenId(src)
    if cid then
        local s = _G.SteakRequest('/vip/settings/' .. cid, 'GET')
        if s and s.nickname and s.showNickname then
            nicknameCache[src] = s.nickname
            return s.nickname
        end
        -- if engine unreachable (s == nil) fall through to Hidden without caching
        if s ~= nil then nicknameCache[src] = "Hidden" end
        return s ~= nil and "Hidden" or "Hidden"
    end
    nicknameCache[src] = "Hidden"
    return "Hidden"
end

-- Engine request helper (defined in api.lua, exposed via _G)
local function casinoRequest(endpoint, cb, method, body)
    _G.EngineRequest("/casino" .. endpoint, cb, method or "POST", body)
end

local function casinoRequestSync(endpoint, method, body)
    local result = nil
    local done = false
    casinoRequest(endpoint, function(data)
        result = data
        done = true
    end, method, body)
    local timeout = 0
    while not done and timeout < 5000 do
        Wait(50)
        timeout = timeout + 50
    end
    return result
end

-- Engine connectivity check — block games if backend is down
local engineOnline = false
CreateThread(function()
    Wait(6000)
    while true do
        local done = false
        _G.EngineRequest("/health", function(data)
            engineOnline = data ~= nil and data.status == 'ok'
            done = true
        end, "GET", nil)
        local t = 0
        while not done and t < 3000 do Wait(100) t = t + 100 end
        if not done then engineOnline = false end
        Wait(15000)
    end
end)

local function checkEngine(src)
    if not engineOnline then
        TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, {
            game = "system", success = false, message = "Casino engine offline — try again soon"
        })
        return false
    end
    return true
end

-- ═══════════════════════════════════════════════════════════════
-- DICE — relay to Docker engine
-- ═══════════════════════════════════════════════════════════════

RegisterNetEvent('hk-sportsbetting:server:diceBet', function(data)
    local src = source
    if not checkEngine(src) then return end
    if playerLock[src] then
        TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, {
            game = "dice", success = false, message = "Processing..."
        })
        return
    end

    local stake = tonumber(data.stake)
    local target = tonumber(data.target)
    local isOver = data.isOver == true

    if not stake or not target then return end
    stake = math.floor(stake)
    target = math.floor(target)
    if stake < 1 then return end
    if target < 2 or target > 98 then return end

    withLock(src, function()
        local Player = getPlayer(src)
        if not Player then return end
        local cid = getCitizenId(src)
        if not cid then return end
        local demo = isDemoPlayer(cid)

        local maxBet = GetPlayerMaxBet(cid)
        if stake < Config.Casino.Dice.minBet or stake > maxBet then
            TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, {
                game = "dice", success = false, message = "Invalid bet (max: $" .. tostring(maxBet) .. ")"
            })
            return
        end

        local playerCash = tonumber(demo and demoGetBal(cid) or Player.PlayerData.money.cash) or 0
        if playerCash < stake then
            TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, {
                game = "dice", success = false, message = "Insufficient cash"
            })
            return
        end

        local hash, nonce, seedHash, clientSeed = GenerateGameOutcomeSync(cid)

        if demo then
            demoRemove(cid, stake)
        else
            if not Player.Functions.RemoveMoney('cash', stake, 'casino-dice') then
                TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, {
                    game = "dice", success = false, message = "Insufficient cash"
                })
                return
            end
        end

        TriggerClientEvent('hk-sportsbetting:client:updateBalance', src, demo and demoGetBal(cid) or Player.PlayerData.money.cash)

        local result = casinoRequestSync("/dice/bet", "POST", {
            identifier = cid,
            stake = stake,
            target = target,
            isOver = isOver,
            serverSeed = hash,
            clientSeed = clientSeed,
            nonce = nonce,
        })

        if not result or not result.success then
            if demo then
                demoAdd(cid, stake)
            else
                Player.Functions.AddMoney('cash', stake, 'casino-dice-refund')
            end
            TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, {
                game = "dice", success = false, message = "Engine error"
            })
            return
        end

        local payout = tonumber(result.payout) or 0
        local cappedPayout = result.won and payout > 0 and math.min(payout, MAX_PAYOUT) or 0

        -- Store pending payout; client triggers collection after animation
        if cappedPayout > 0 then
            if demo then
                demoAdd(cid, cappedPayout)
            end
            dicePayouts[cid] = { src = src, amount = cappedPayout, at = os.time(), demo = demo }
        end

        TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, {
            game = "dice",
            success = true,
            won = result.won,
            roll = result.roll,
            target = target,
            isOver = isOver,
            multiplier = result.multiplier,
            stake = stake,
            payout = result.payout,
            balance = demo and demoGetBal(cid) or (Player.PlayerData.money.cash + cappedPayout),
            fairness = { nonce = nonce, seedHash = seedHash, clientSeed = clientSeed },
        })

        if not demo then
            _G.SteakPost('/casino/record', { identifier = cid, game = 'dice', stake = stake, multiplier = result.multiplier, payout = result.payout, won = result.won and 1 or 0, seed = result.hash, nonce = nonce })
            AddVipXP(cid, src, true, stake, result.won and result.payout or 0, 'dice')

            if not result.won then
                local refund = CheckLossStreakProtection(cid, stake)
                if refund > 0 then
                    Player.Functions.AddMoney('cash', refund, 'vip-loss-protection')
                    TriggerClientEvent('hk-sportsbetting:client:updateBalance', src, Player.PlayerData.money.cash)
                    TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, {
                        game = "vip", success = true, message = "Loss protection: +$" .. tostring(refund)
                    })
                end
            end
        end
    end)
end)

RegisterNetEvent('hk-sportsbetting:server:diceCollect', function()
    local src = source
    local cid = getCitizenId(src)
    if not cid then return end
    local pending = dicePayouts[cid]
    if not pending then return end
    dicePayouts[cid] = nil
    if pending.demo then return end -- demo already added to fake balance
    local Player = QBCore.Functions.GetPlayer(src)
    if Player then
        Player.Functions.AddMoney('cash', pending.amount, 'casino-dice-win')
    end
end)

-- Dice payout safety net: pay any uncollected wins after 30s
CreateThread(function()
    while true do
        Wait(10000)
        local now = os.time()
        for cid, pending in pairs(dicePayouts) do
            if now - pending.at > 30 then
                dicePayouts[cid] = nil
                local Player = QBCore.Functions.GetPlayerByCitizenId(cid)
                if Player then
                    Player.Functions.AddMoney('cash', pending.amount, 'casino-dice-win-fallback')
                else
                    MySQL.update('UPDATE players SET money = JSON_SET(money, "$.cash", JSON_EXTRACT(money, "$.cash") + ?) WHERE citizenid = ?',
                        {pending.amount, cid})
                end
            end
        end
    end
end)

-- ═══════════════════════════════════════════════════════════════
-- MINES — relay to Docker engine
-- ═══════════════════════════════════════════════════════════════

RegisterNetEvent('hk-sportsbetting:server:minesStart', function(data)
    local src = source
    if not checkEngine(src) then return end
    if playerLock[src] then
        TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, {
            game = "mines", success = false, action = "start", message = "Processing..."
        })
        return
    end
    local stake = tonumber(data.stake)
    local numMines = tonumber(data.mines)

    if not stake or not numMines then return end
    if numMines < 1 or numMines > 24 then return end
    stake = math.floor(stake)
    if stake <= 0 then return end

    withLock(src, function()
        local Player = getPlayer(src)
        if not Player then return end
        local cid = getCitizenId(src)
        if not cid then return end
        local demo = isDemoPlayer(cid)

        local maxBet = GetPlayerMaxBet(cid)
        if stake < Config.Casino.Mines.minBet or stake > maxBet then
            TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, {
                game = "mines", success = false, action = "start", message = "Invalid bet (max: $" .. tostring(maxBet) .. ")"
            })
            return
        end

        local playerCash = tonumber(demo and demoGetBal(cid) or Player.PlayerData.money.cash) or 0
        if playerCash < stake then
            TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, {
                game = "mines", success = false, action = "start", message = "Insufficient cash"
            })
            return
        end

        local hash, nonce, seedHash, clientSeed = GenerateGameOutcomeSync(cid)

        if demo then
            demoRemove(cid, stake)
        else
            if not Player.Functions.RemoveMoney('cash', stake, 'casino-mines') then
                TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, {
                    game = "mines", success = false, action = "start", message = "Insufficient cash"
                })
                return
            end
        end

        TriggerClientEvent('hk-sportsbetting:client:updateBalance', src, demo and demoGetBal(cid) or Player.PlayerData.money.cash)

        local result = casinoRequestSync("/mines/start", "POST", {
            identifier = cid,
            stake = stake,
            numMines = numMines,
            serverSeed = hash,
            clientSeed = clientSeed,
            nonce = nonce,
        })

        if not result or not result.success then
            if demo then demoAdd(cid, stake) else Player.Functions.AddMoney('cash', stake, 'casino-mines-refund') end
            TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, {
                game = "mines", success = false, action = "start", message = result and result.error or "Engine error"
            })
            return
        end

        TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, {
            game = "mines",
            success = true,
            action = "started",
            numMines = numMines,
            stake = stake,
            balance = demo and demoGetBal(cid) or Player.PlayerData.money.cash,
            fairness = { nonce = nonce, seedHash = seedHash, clientSeed = clientSeed },
        })
    end)
end)

RegisterNetEvent('hk-sportsbetting:server:minesReveal', function(data)
    local src = source
    if playerLock[src] then
        TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, {
            game = "mines", success = false, action = "reveal", message = "Processing..."
        })
        return
    end
    withLock(src, function()
        local tile = tonumber(data.tile)
        if not tile or tile < 0 or tile > 24 then return end

        local cid = getCitizenId(src)
        if not cid then return end

        local result = casinoRequestSync("/mines/reveal", "POST", {
            identifier = cid,
            tile = tile,
        })

        if not result or not result.success then
            TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, {
                game = "mines", success = false, message = result and result.error or "Connection error"
            })
            return
        end

        if result.hit then
            TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, {
                game = "mines", success = true, action = "exploded",
                tile = tile, mines = result.mines,
            })
            local demo = isDemoPlayer(cid)
            if not demo then
                _G.SteakPost('/casino/record', { identifier = cid, game = 'mines', stake = result.stake or 0, multiplier = 0, payout = 0, won = 0, seed = result.hash or "", nonce = result.nonce or 0 })
                AddVipXP(cid, src, true, result.stake or 0, 0, "mines")

                local refund = CheckLossStreakProtection(cid, result.stake or 0)
                if refund > 0 then
                    local Player = getPlayer(src)
                    if Player then
                        Player.Functions.AddMoney('cash', refund, 'vip-loss-protection')
                        TriggerClientEvent('hk-sportsbetting:client:updateBalance', src, Player.PlayerData.money.cash)
                        TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, {
                            game = "vip", success = true, message = "Loss protection: +$" .. tostring(refund)
                        })
                    end
                end
            end
        else
            TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, {
                game = "mines", success = true, action = "safe",
                tile = tile, revealCount = result.revealCount or 0,
                multiplier = result.multiplier, payout = result.payout,
            })
        end
    end)
end)

RegisterNetEvent('hk-sportsbetting:server:minesCashout', function()
    local src = source
    if playerLock[src] then
        TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, {
            game = "mines", success = false, action = "cashout", message = "Processing..."
        })
        return
    end
    withLock(src, function()
        local cid = getCitizenId(src)
        if not cid then return end

        local result = casinoRequestSync("/mines/cashout", "POST", {
            identifier = cid,
        })

        if not result or not result.success then
            TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, {
                game = "mines", success = false, message = result and result.error or "Connection error"
            })
            return
        end

        local payout = tonumber(result.payout) or 0
        local demo = isDemoPlayer(cid)
        local Player = getPlayer(src)
        if payout > 0 then
            if demo then
                demoAdd(cid, math.min(payout, MAX_PAYOUT))
            elseif Player then
                Player.Functions.AddMoney('cash', math.min(payout, MAX_PAYOUT), 'casino-mines-win')
            end
        end

        TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, {
            game = "mines", success = true, action = "cashout",
            payout = payout, multiplier = result.multiplier, mines = result.mines,
            balance = demo and demoGetBal(cid) or (Player and Player.PlayerData.money.cash or 0),
        })

        if not demo then
            _G.SteakPost('/casino/record', { identifier = cid, game = 'mines', stake = result.stake or 0, multiplier = result.multiplier, payout = result.payout, won = 1, seed = result.hash or "", nonce = result.nonce or 0 })
            AddVipXP(cid, src, true, result.stake or 0, result.payout, "mines")
        end
    end)
end)

-- ═══════════════════════════════════════════════════════════════
-- CHICKEN — relay to Docker engine
-- ═══════════════════════════════════════════════════════════════

RegisterNetEvent('hk-sportsbetting:server:chickenStart', function(data)
    local src = source
    if not checkEngine(src) then return end
    if playerLock[src] then
        TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, {
            game = "chicken", success = false, action = "start", message = "Processing..."
        })
        return
    end
    local stake = tonumber(data.stake)
    local cols = tonumber(data.cols) or 4
    if cols ~= 3 and cols ~= 4 and cols ~= 5 then cols = 4 end
    if not stake then return end
    stake = math.floor(stake)
    if stake <= 0 then return end

    withLock(src, function()
        local Player = getPlayer(src)
        if not Player then return end
        local cid = getCitizenId(src)
        if not cid then return end
        local demo = isDemoPlayer(cid)

        local maxBet = GetPlayerMaxBet(cid)
        if stake < Config.Casino.Chicken.minBet or stake > maxBet then
            TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, {
                game = "chicken", success = false, action = "start", message = "Invalid bet (max: $" .. tostring(maxBet) .. ")"
            })
            return
        end

        local playerCash = tonumber(demo and demoGetBal(cid) or Player.PlayerData.money.cash) or 0
        if playerCash < stake then
            TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, {
                game = "chicken", success = false, action = "start", message = "Insufficient cash"
            })
            return
        end

        local hash, nonce, seedHash, clientSeed = GenerateGameOutcomeSync(cid)

        if demo then
            demoRemove(cid, stake)
        else
            if not Player.Functions.RemoveMoney('cash', stake, 'casino-chicken') then
                TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, {
                    game = "chicken", success = false, action = "start", message = "Insufficient cash"
                })
                return
            end
        end

        TriggerClientEvent('hk-sportsbetting:client:updateBalance', src, demo and demoGetBal(cid) or Player.PlayerData.money.cash)

        local result = casinoRequestSync("/chicken/start", "POST", {
            identifier = cid,
            stake = stake,
            cols = cols,
            serverSeed = hash,
            clientSeed = clientSeed,
            nonce = nonce,
        })

        if not result or not result.success then
            if demo then demoAdd(cid, stake) else Player.Functions.AddMoney('cash', stake, 'casino-chicken-refund') end
            TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, {
                game = "chicken", success = false, action = "start", message = result and result.error or "Engine error"
            })
            return
        end

        TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, {
            game = "chicken", success = true, action = "started",
            cols = result.cols or cols, stake = stake,
            balance = demo and demoGetBal(cid) or Player.PlayerData.money.cash,
            fairness = { nonce = nonce, seedHash = seedHash, clientSeed = clientSeed },
        })
    end)
end)

RegisterNetEvent('hk-sportsbetting:server:chickenStep', function(data)
    local src = source
    if playerLock[src] then
        TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, {
            game = "chicken", success = false, action = "step", message = "Processing..."
        })
        return
    end
    withLock(src, function()
        local lane = tonumber(data.lane)
        if not lane or lane < 1 or lane > 6 then return end

        local cid = getCitizenId(src)
        if not cid then return end

        local result = casinoRequestSync("/chicken/step", "POST", {
            identifier = cid,
            lane = lane,
        })

        if not result or not result.success then
            TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, {
                game = "chicken", success = false, message = result and result.error or "Connection error"
            })
            return
        end

        if result.hit then
            TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, {
                game = "chicken", success = true, action = "dead",
                row = result.row, lane = lane,
                hazardPos = result.hazardPos, hazardType = result.hazardType,
                field = result.field,
            })
            local demo = isDemoPlayer(cid)
            if not demo then
                _G.SteakPost('/casino/record', { identifier = cid, game = 'chicken', stake = result.stake or 0, multiplier = 0, payout = 0, won = 0, seed = result.hash or "", nonce = result.nonce or 0 })
                AddVipXP(cid, src, true, result.stake or 0, 0, "chicken")

                local refund = CheckLossStreakProtection(cid, result.stake or 0)
                if refund > 0 then
                    local Player = getPlayer(src)
                    if Player then
                        Player.Functions.AddMoney('cash', refund, 'vip-loss-protection')
                        TriggerClientEvent('hk-sportsbetting:client:updateBalance', src, Player.PlayerData.money.cash)
                        TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, {
                            game = "vip", success = true, message = "Loss protection: +$" .. tostring(refund)
                        })
                    end
                end
            end
        else
            if result.gift then
                local giftAmount = math.min(result.gift.amount or 0, MAX_PAYOUT)
                if giftAmount > 0 then
                    local Player = getPlayer(src)
                    if Player then
                        if result.gift.type == 'cash' then
                            Player.Functions.AddMoney('cash', giftAmount, 'chicken-road-gift')
                        else
                            pcall(function()
                                exports['hk-homecoin']:AddCoins(src, giftAmount)
                            end)
                        end
                    end
                end
            end

            TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, {
                game = "chicken", success = true, action = "safe",
                row = result.row, lane = lane, currentRow = result.row,
                multiplier = result.multiplier, payout = result.payout,
                gift = result.gift, hazardType = result.hazardType,
            })
        end
    end)
end)

RegisterNetEvent('hk-sportsbetting:server:chickenCashout', function()
    local src = source
    if playerLock[src] then
        TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, {
            game = "chicken", success = false, action = "cashout", message = "Processing..."
        })
        return
    end
    withLock(src, function()
        local cid = getCitizenId(src)
        if not cid then return end

        local result = casinoRequestSync("/chicken/cashout", "POST", {
            identifier = cid,
        })

        if not result or not result.success then
            TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, {
                game = "chicken", success = false, message = result and result.error or "Connection error"
            })
            return
        end

        local payout = tonumber(result.payout) or 0
        local demo = isDemoPlayer(cid)
        local Player = getPlayer(src)
        if payout > 0 then
            if demo then
                demoAdd(cid, math.min(payout, MAX_PAYOUT))
            elseif Player then
                Player.Functions.AddMoney('cash', math.min(payout, MAX_PAYOUT), 'casino-chicken-win')
            end
        end

        TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, {
            game = "chicken", success = true, action = "cashout",
            payout = payout, multiplier = result.multiplier, field = result.field,
            balance = demo and demoGetBal(cid) or (Player and Player.PlayerData.money.cash or 0),
        })

        if not demo then
            _G.SteakPost('/casino/record', { identifier = cid, game = 'chicken', stake = result.stake or 0, multiplier = result.multiplier, payout = result.payout, won = 1, seed = result.hash or "", nonce = result.nonce or 0 })
            AddVipXP(cid, src, true, result.stake or 0, result.payout, "chicken")
        end
    end)
end)

-- ═══════════════════════════════════════════════════════════════
-- CRASH — Docker engine runs the round loop, FiveM polls + relays
-- ═══════════════════════════════════════════════════════════════

local crashWatchers = {}

RegisterNetEvent('hk-sportsbetting:server:crashJoin', function()
    local src = source
    crashWatchers[src] = true

    local cid = getCitizenId(src)
    if not cid then return end

    local displayName = getDisplayName(src)
    local result = casinoRequestSync("/crash/join", "POST", {
        identifier = cid,
        displayName = displayName,
    })

    if not result then return end

    crashRoundState = result.state

    TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, {
        game = "crash", action = "sync",
        state = result.state == "ended" and "crashed" or result.state,
        countdown = result.countdown or 0,
        crashPoint = result.state ~= "running" and result.crashPoint or nil,
        elapsed = result.elapsed or 0,
        betList = result.betList or {},
        hasBet = result.hasBet or false,
        cashedOut = result.cashedOut or false,
        cashoutMultiplier = result.cashoutMultiplier,
    })
end)

RegisterNetEvent('hk-sportsbetting:server:crashLeave', function()
    local src = source
    crashWatchers[src] = nil
    local cid = getCitizenId(src)
    if cid then
        casinoRequest("/crash/leave", function() end, "POST", { identifier = cid })
    end
end)

RegisterNetEvent('hk-sportsbetting:server:crashBet', function(data)
    local src = source
    if not checkEngine(src) then return end
    if playerLock[src] then
        TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, {
            game = "crash", success = false, message = "Processing..."
        })
        return
    end
    local stake = tonumber(data.stake)
    local autoCashout = tonumber(data.autoCashout)
    if autoCashout and autoCashout > 30 then autoCashout = 30 end
    if autoCashout and autoCashout < 1.10 then autoCashout = nil end
    if stake then stake = math.floor(stake) end

    if not stake or stake <= 0 or stake < Config.Casino.Crash.minBet then
        TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, {
            game = "crash", success = false, message = "Invalid bet"
        })
        return
    end

    withLock(src, function()
        local Player = getPlayer(src)
        if not Player then return end
        local cid = getCitizenId(src)
        if not cid then return end

        if crashBetSources[cid] then
            -- Clear stale entries (settlement failed or engine restarted)
            if crashBetSources[cid].placedAt and (os.time() - crashBetSources[cid].placedAt) > 300 then
                local staleStake = crashBetSources[cid].stake or 0
                crashBetSources[cid] = nil
                -- Verify with engine before refunding — bet may have been lost
                if staleStake > 0 then
                    local status = casinoRequestSync("/crash/betStatus", "POST", { identifier = cid })
                    if status and status.settled then
                        -- Engine confirms bet was settled (won/lost) — no refund
                        print("[crash] Stale entry for " .. cid .. " was already settled: " .. (status.result or "unknown"))
                    else
                        -- Engine has no record or confirms orphan — safe to refund
                        local RefundP = getPlayer(src)
                        if RefundP then
                            RefundP.Functions.AddMoney('cash', staleStake, 'crash-orphan-refund')
                        else
                            MySQL.update('UPDATE players SET money = JSON_SET(money, "$.cash", JSON_EXTRACT(money, "$.cash") + ?) WHERE citizenid = ?', {staleStake, cid})
                        end
                    end
                end
            else
                TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, {
                    game = "crash", success = false, message = "Already bet this round"
                })
                return
            end
        end

        -- Confirm against the ENGINE (authority) rather than the cached state, which
        -- can lag the 200ms poll. Prevents false "round in progress" rejections when
        -- betting is actually open. The engine's /crash/bet also guards this, but
        -- checking here lets us refund nothing (money not yet taken) on a clean reject.
        local liveState = casinoRequestSync("/crash/state", "GET", nil)
        if liveState and liveState.state then crashRoundState = liveState.state end
        if crashRoundState ~= "waiting" then
            TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, {
                game = "crash", success = false, message = "Round already in progress"
            })
            return
        end

        local maxBet = GetPlayerMaxBet(cid)
        if stake > maxBet then
            TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, {
                game = "crash", success = false, message = "Max bet for your tier: $" .. tostring(maxBet)
            })
            return
        end

        local demo = isDemoPlayer(cid)
        local playerCash = tonumber(demo and demoGetBal(cid) or Player.PlayerData.money.cash) or 0
        if playerCash < stake then
            TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, {
                game = "crash", success = false, message = "Insufficient cash"
            })
            return
        end

        if demo then
            demoRemove(cid, stake)
        else
            if not Player.Functions.RemoveMoney('cash', stake, 'casino-crash') then
                TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, {
                    game = "crash", success = false, message = "Insufficient cash"
                })
                return
            end
        end

        TriggerClientEvent('hk-sportsbetting:client:updateBalance', src, demo and demoGetBal(cid) or Player.PlayerData.money.cash)

        local displayName = getDisplayName(src)
        crashBetSources[cid] = { src = src, stake = stake, placedAt = os.time() }

        local result = casinoRequestSync("/crash/bet", "POST", {
            identifier = cid,
            stake = stake,
            autoCashout = autoCashout,
            displayName = displayName,
        })

        if not result or not result.success then
            crashBetSources[cid] = nil
            Player.Functions.AddMoney('cash', stake, 'casino-crash-refund')
            TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, {
                game = "crash", success = false, message = result and result.error or "Engine error"
            })
            return
        end

        TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, {
            game = "crash", action = "betPlaced",
            betList = result.betList or {},
            balance = Player.PlayerData.money.cash,
            isMine = true,
        })

        for watcherSrc, _ in pairs(crashWatchers) do
            if watcherSrc ~= src then
                TriggerClientEvent('hk-sportsbetting:client:casinoResult', watcherSrc, {
                    game = "crash", action = "betListUpdate",
                    betList = result.betList or {},
                })
            end
        end
    end)
end)

RegisterNetEvent('hk-sportsbetting:server:crashUpdateAuto', function(data)
    local src = source
    local cid = getCitizenId(src)
    if not cid then return end
    if not crashBetSources[cid] then return end
    -- Only allow autoCashout updates within 20s of placing the bet (waiting phase only)
    local entry = crashBetSources[cid]
    if entry.placedAt and (os.time() - entry.placedAt) > 20 then return end
    local autoCashout = tonumber(data.autoCashout)
    if autoCashout and autoCashout > 30 then autoCashout = 30 end
    if autoCashout and autoCashout < 1.10 then autoCashout = nil end
    casinoRequest("/crash/updateAuto", function() end, "POST", {
        identifier = cid,
        autoCashout = autoCashout,
    })
end)

RegisterNetEvent('hk-sportsbetting:server:crashCashout', function(data)
    local src = source
    if playerLock[src] then
        TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, {
            game = "crash", success = false, message = "Processing..."
        })
        return
    end
    local cid = getCitizenId(src)
    if not cid then return end
    if not crashBetSources[cid] then return end

    withLock(src, function()
        if not crashBetSources[cid] then return end

        local stakeSnapshot = crashBetSources[cid].stake

        local result = casinoRequestSync("/crash/cashout", "POST", {
            identifier = cid,
        })

        if not result or not result.success then
            return
        end

        crashBetSources[cid] = nil

        local stake = result.stake or stakeSnapshot
        local payout = tonumber(result.payout) or 0
        local demo = isDemoPlayer(cid)
        local Player = getPlayer(src)
        if payout > 0 then
            if demo then
                demoAdd(cid, math.min(payout, MAX_PAYOUT))
            elseif Player then
                Player.Functions.AddMoney('cash', math.min(payout, MAX_PAYOUT), 'casino-crash-win')
            end
        end

        TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, {
            game = "crash", action = "cashout",
            multiplier = result.multiplier, payout = payout,
            balance = demo and demoGetBal(cid) or (Player and Player.PlayerData.money.cash or 0),
        })

        for watcherSrc, _ in pairs(crashWatchers) do
            TriggerClientEvent('hk-sportsbetting:client:casinoResult', watcherSrc, {
                game = "crash", action = "playerCashout",
                betList = result.betList or {},
            })
        end

        if not demo then
            _G.SteakPost('/casino/record', { identifier = cid, game = 'crash', stake = stake, multiplier = result.multiplier, payout = result.payout, won = 1, seed = "", nonce = 0 })
            AddVipXP(cid, src, true, stake, result.payout, "crash")
        end
    end)
end)

-- Crash startup recovery: settle any orphaned bets from a previous resource session
CreateThread(function()
    Wait(3000)
    local settle = casinoRequestSync("/crash/settle", "GET", nil)
    if settle and settle.bets then
        for _, bet in ipairs(settle.bets) do
            local cappedPayout = math.min(bet.payout or 0, MAX_PAYOUT)
            if bet.cashedOut and cappedPayout > 0 then
                MySQL.update('UPDATE players SET money = JSON_SET(money, "$.cash", JSON_EXTRACT(money, "$.cash") + ?) WHERE citizenid = ?',
                    {cappedPayout, bet.identifier})
                _G.SteakPost('/casino/record', { identifier = bet.identifier, game = 'crash', stake = bet.stake, multiplier = bet.multiplier, payout = cappedPayout, won = 1, seed = "", nonce = 0 })
            elseif not bet.cashedOut then
                _G.SteakPost('/casino/record', { identifier = bet.identifier, game = 'crash', stake = bet.stake, multiplier = 0, payout = 0, won = 0, seed = "", nonce = 0 })
            end
        end
        if #settle.bets > 0 then
            print("[hk-sportsbetting] Crash startup: recovered " .. #settle.bets .. " orphaned bets")
        end
    end
end)

-- Crash broadcast loop: poll Docker engine for state changes, push to watchers
-- (crashRoundState is declared at module scope near the top — do NOT re-declare
-- it here as local, or the crashJoin/crashBet sites above would desync from it.)
CreateThread(function()
    Wait(5000)
    local lastState = "idle"
    local lastCrashPoint = nil
    local lastBetSig = nil

    while true do
        Wait(200)
        local hasWatchers = next(crashWatchers) ~= nil
        local hasBets = next(crashBetSources) ~= nil
        if hasWatchers or hasBets then
            local state = casinoRequestSync("/crash/state", "GET", nil)
            if state then
                crashRoundState = state.state

                -- Live bet-list sync for MOBILE actions. The relay only POLLS the
                -- engine; a mobile player's bet-place (waiting) or cashout (running)
                -- mutates shared engine state but fires NO relay event, so without
                -- this the PC watchers' bet list wouldn't refresh until a PC action or
                -- a state transition (PC->mobile already syncs via the mobile poll).
                -- We hash the whole list composition (who's in + stake + cashed-out)
                -- and rebroadcast only when it actually changes, so no per-tick flood.
                -- Runs in BOTH waiting and running so a mobile bet appears immediately.
                if (state.state == "waiting" or state.state == "running") and hasWatchers then
                    local sig = ""
                    for _, b in ipairs(state.betList or {}) do
                        sig = sig .. (b.name or "?") .. ":" .. tostring(b.stake or 0)
                            .. ":" .. (b.cashedOut and "1" or "0") .. "|"
                    end
                    if sig ~= lastBetSig then
                        lastBetSig = sig
                        for watcherSrc, _ in pairs(crashWatchers) do
                            TriggerClientEvent('hk-sportsbetting:client:casinoResult', watcherSrc, {
                                game = "crash", action = "betListUpdate",
                                betList = state.betList or {},
                            })
                        end
                    end
                else
                    lastBetSig = nil
                end
                -- Detect missed round (full cycle within one poll interval)
                local hasPendingBets = false
                if state.crashPoint == lastCrashPoint then
                    for _, info in pairs(crashBetSources) do
                        if os.time() - info.placedAt < 60 then hasPendingBets = true break end
                    end
                end
                if state.state == "waiting" and lastState == "waiting" and state.crashPoint and (state.crashPoint ~= lastCrashPoint or hasPendingBets) then
                    lastCrashPoint = state.crashPoint
                    for watcherSrc, _ in pairs(crashWatchers) do
                        TriggerClientEvent('hk-sportsbetting:client:casinoResult', watcherSrc, {
                            game = "crash", action = "busted",
                            crashPoint = state.crashPoint,
                            betList = state.betList or {},
                        })
                    end
                    local settle = casinoRequestSync("/crash/settle", "GET", nil)
                    if settle and settle.bets then
                        for _, bet in ipairs(settle.bets) do
                            local info = crashBetSources[bet.identifier]
                            if info then
                                local betDemo = isDemoPlayer(bet.identifier)
                                local Player = QBCore.Functions.GetPlayerByCitizenId(bet.identifier)
                                local activeSrc = Player and Player.PlayerData.source or nil
                                local cappedPayout = math.min(tonumber(bet.payout) or 0, MAX_PAYOUT)
                                if bet.cashedOut and cappedPayout > 0 then
                                    if betDemo then
                                        demoAdd(bet.identifier, cappedPayout)
                                    elseif Player then
                                        Player.Functions.AddMoney('cash', cappedPayout, 'casino-crash-autocashout')
                                        TriggerClientEvent('hk-sportsbetting:client:updateBalance', activeSrc, Player.PlayerData.money.cash)
                                    else
                                        MySQL.update('UPDATE players SET money = JSON_SET(money, "$.cash", JSON_EXTRACT(money, "$.cash") + ?) WHERE citizenid = ?',
                                            {cappedPayout, bet.identifier})
                                    end
                                    if not betDemo then
                                        _G.SteakPost('/casino/record', { identifier = bet.identifier, game = 'crash', stake = bet.stake, multiplier = bet.multiplier, payout = bet.payout, won = 1, seed = "", nonce = 0 })
                                        AddVipXP(bet.identifier, activeSrc, true, bet.stake, bet.payout, "crash")
                                    end
                                elseif not bet.cashedOut then
                                    if not betDemo then
                                        _G.SteakPost('/casino/record', { identifier = bet.identifier, game = 'crash', stake = bet.stake, multiplier = 0, payout = 0, won = 0, seed = "", nonce = 0 })
                                        AddVipXP(bet.identifier, activeSrc, true, bet.stake, 0, "crash")
                                    end
                                end
                                crashBetSources[bet.identifier] = nil
                            end
                        end
                    end
                    for watcherSrc, _ in pairs(crashWatchers) do
                        TriggerClientEvent('hk-sportsbetting:client:casinoResult', watcherSrc, {
                            game = "crash", action = "waiting",
                            countdown = state.countdown, betList = state.betList or {},
                        })
                    end
                elseif state.state ~= lastState then
                    if state.state == "waiting" then
                        for watcherSrc, _ in pairs(crashWatchers) do
                            TriggerClientEvent('hk-sportsbetting:client:casinoResult', watcherSrc, {
                                game = "crash", action = "waiting",
                                countdown = state.countdown, betList = state.betList or {},
                            })
                        end
                    elseif state.state == "running" and lastState == "waiting" then
                        for watcherSrc, _ in pairs(crashWatchers) do
                            TriggerClientEvent('hk-sportsbetting:client:casinoResult', watcherSrc, {
                                game = "crash", action = "started",
                                betList = state.betList or {},
                                elapsed = state.elapsed or 0,
                                growthRate = 0.08,
                            })
                        end
                    elseif state.state == "ended" then
                        lastCrashPoint = state.crashPoint
                        for watcherSrc, _ in pairs(crashWatchers) do
                            TriggerClientEvent('hk-sportsbetting:client:casinoResult', watcherSrc, {
                                game = "crash", action = "busted",
                                crashPoint = state.crashPoint,
                                betList = state.betList or {},
                            })
                        end
                        -- Settle all bets: pay auto-cashouts, record losses
                        local settle = casinoRequestSync("/crash/settle", "GET", nil)
                        if settle and settle.bets then
                            for _, bet in ipairs(settle.bets) do
                                local info = crashBetSources[bet.identifier]
                                if info then
                                    local betDemo = isDemoPlayer(bet.identifier)
                                    local Player = QBCore.Functions.GetPlayerByCitizenId(bet.identifier)
                                    local activeSrc = Player and Player.PlayerData.source or nil
                                    local cappedPayout = math.min(tonumber(bet.payout) or 0, MAX_PAYOUT)
                                    if bet.cashedOut and cappedPayout > 0 then
                                        if betDemo then
                                            demoAdd(bet.identifier, cappedPayout)
                                        elseif Player then
                                            Player.Functions.AddMoney('cash', cappedPayout, 'casino-crash-autocashout')
                                            TriggerClientEvent('hk-sportsbetting:client:casinoResult', activeSrc, {
                                                game = "crash", action = "cashout",
                                                multiplier = bet.multiplier, payout = cappedPayout,
                                                balance = Player.PlayerData.money.cash,
                                            })
                                        else
                                            MySQL.update('UPDATE players SET money = JSON_SET(money, "$.cash", JSON_EXTRACT(money, "$.cash") + ?) WHERE citizenid = ?',
                                                {cappedPayout, bet.identifier})
                                        end
                                        if not betDemo then
                                            _G.SteakPost('/casino/record', { identifier = bet.identifier, game = 'crash', stake = bet.stake, multiplier = bet.multiplier, payout = bet.payout, won = 1, seed = "", nonce = 0 })
                                            AddVipXP(bet.identifier, activeSrc, true, bet.stake, bet.payout, "crash")
                                        end
                                    elseif not bet.cashedOut then
                                        if not betDemo then
                                            _G.SteakPost('/casino/record', { identifier = bet.identifier, game = 'crash', stake = bet.stake, multiplier = 0, payout = 0, won = 0, seed = "", nonce = 0 })
                                            AddVipXP(bet.identifier, activeSrc, true, bet.stake, 0, "crash")

                                            if Player then
                                                local refund = CheckLossStreakProtection(bet.identifier, bet.stake)
                                                if refund > 0 then
                                                    Player.Functions.AddMoney('cash', refund, 'vip-loss-protection')
                                                    TriggerClientEvent('hk-sportsbetting:client:updateBalance', activeSrc, Player.PlayerData.money.cash)
                                                    TriggerClientEvent('hk-sportsbetting:client:casinoResult', activeSrc, {
                                                        game = "vip", success = true, message = "Loss protection: +$" .. tostring(refund)
                                                    })
                                                end
                                            end
                                        end
                                    end
                                    crashBetSources[bet.identifier] = nil
                                end
                            end
                        end
                    end
                    lastState = state.state
                end
            end
        else
            Wait(2000)
        end
    end
end)

-- ═══════════════════════════════════════════════════════════════
-- PLINKO — relay to Docker engine (keeps anti-macro on FiveM side)
-- ═══════════════════════════════════════════════════════════════

RegisterNetEvent('hk-sportsbetting:server:plinkoBet', function(data)
    local src = source
    if not checkEngine(src) then return end
    local stake = tonumber(data.stake)
    local risk = data.risk or "medium"
    local rows = tonumber(data.rows) or 12
    if not stake or stake <= 0 then return end
    stake = math.floor(stake)

    if risk ~= "low" and risk ~= "medium" and risk ~= "high" then risk = "medium" end
    if rows ~= 8 and rows ~= 12 and rows ~= 16 then rows = 12 end

    local cid = getCitizenId(src)
    if not cid then return end

    local maxBet = getMaxBetCached(cid)   -- cached; nil only if engine unreachable
    if maxBet == nil then
        TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, {
            game = "plinko", success = false, message = "Steak is under maintenance — try again shortly"
        })
        return
    end
    if stake < Config.Casino.Plinko.minBet or stake > maxBet then
        TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, {
            game = "plinko", success = false, message = "Invalid bet (max: $" .. tostring(maxBet) .. ")"
        })
        return
    end

    -- Macro block check
    local now = GetGameTimer()
    if plinkoBlocked[src] and now < plinkoBlocked[src] then
        local secsLeft = math.ceil((plinkoBlocked[src] - now) / 1000)
        TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, {
            game = "plinko", success = false, message = "Slow down! Blocked for " .. secsLeft .. "s"
        })
        return
    end

    -- Cooldown check — rapid-fire friendly (Stake-style hold/auto-bet is ~20-30/s).
    -- Persistence is off the game DB now + the engine call is 1 round-trip/ball, so
    -- ~28ms (≈35 balls/s ceiling) is safe. See Config.Casino.Plinko.cooldownMs.
    local cooldownMs = (Config.Casino.Plinko.cooldownMs) or 28
    if lastPlinkoBet[src] and (now - lastPlinkoBet[src]) < cooldownMs then
        -- SILENT drop. This branch trips on rapid-fire, exactly when the client is
        -- already spamming; replying with a reliable "Too fast!" per rejected ball only
        -- adds to the very command-queue backlog that causes the client timeout. The
        -- client gates its own drop rate, so a silently-swallowed over-rate ball is fine.
        return
    end
    lastPlinkoBet[src] = now

    -- Macro detection: track last 30 timestamps. Threshold relaxed so legit fast
    -- hold/auto-bet is fine; only inhuman perfectly-uniform sub-15ms spam trips it.
    if not plinkoTimestamps[src] then plinkoTimestamps[src] = {} end
    table.insert(plinkoTimestamps[src], now)
    if #plinkoTimestamps[src] > 30 then table.remove(plinkoTimestamps[src], 1) end

    if #plinkoTimestamps[src] >= 25 then
        local intervals = {}
        for i = 2, #plinkoTimestamps[src] do
            intervals[#intervals + 1] = plinkoTimestamps[src][i] - plinkoTimestamps[src][i - 1]
        end
        local sum = 0
        for _, v in ipairs(intervals) do sum = sum + v end
        local avg = sum / #intervals
        local variance = 0
        for _, v in ipairs(intervals) do variance = variance + (v - avg) ^ 2 end
        variance = variance / #intervals
        -- only flag inhuman machine-timing: very fast AND near-zero jitter
        if avg < 18 and variance < 6 then
            plinkoBlocked[src] = now + 3000
            plinkoTimestamps[src] = {}
            TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, {
                game = "plinko", success = false, message = "Slow down! Blocked for 3s"
            })
            return
        end
    end

    local Player = getPlayer(src)
    local demo = isDemoPlayer(cid)
    local playerCash = tonumber(demo and demoGetBal(cid) or (Player and Player.PlayerData.money.cash or 0)) or 0
    if not Player or playerCash < stake then
        TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, {
            game = "plinko", success = false, message = "Insufficient cash"
        })
        return
    end

    -- In-flight cap: how many balls can be mid-air awaiting their landing/claim.
    -- Raised for Stake-style rapid fire now that persistence is off the game DB.
    if not plinkoPending[src] then plinkoPending[src] = {} end
    local maxInFlight = (Config.Casino.Plinko.maxInFlight) or 120
    if #plinkoPending[src] >= maxInFlight then
        -- Throttle this toast to at most 1/sec. Without it, a held-drop against a full
        -- in-flight buffer emits one reliable event per attempt (~6/s), feeding the same
        -- command-queue backlog that times the client out.
        if not lastPlinkoNotice[src] or (now - lastPlinkoNotice[src]) >= 1000 then
            lastPlinkoNotice[src] = now
            TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, {
                game = "plinko", success = false, message = "Wait for balls to land"
            })
        end
        return
    end

    if demo then
        demoRemove(cid, stake)
    else
        if not Player.Functions.RemoveMoney('cash', stake, 'casino-plinko') then
            TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, {
                game = "plinko", success = false, message = "Insufficient cash"
            })
            return
        end
    end

    -- NOTE: we deliberately DO NOT push a pre-round-trip updateBalance here. It used to
    -- fire one reliable event PER BALL before the blocking ~5s engine round-trip; combined
    -- with the post-result casinoResult (which already carries `balance`), that doubled the
    -- reliable-event rate during held/auto-drop and overflowed the client command queue
    -- ("Server->client connection timed out. Pending commands: N"). The casinoResult below
    -- carries the authoritative post-settlement balance, so one event per ball is enough.

    -- betId is a local unique tag (engine now owns the fair nonce, returned below).
    local betId = ("%s_%d_%d"):format(cid, math.random(100000, 999999), GetGameTimer())

    -- Insert placeholder BEFORE the yield to prevent cap bypass
    if not plinkoPending[src] then plinkoPending[src] = {} end
    local pendingIdx = #plinkoPending[src] + 1
    plinkoPending[src][pendingIdx] = { betId = betId, placeholder = true, cid = cid, stake = stake }

    -- ONE engine round-trip per ball: autoSeed => engine generates the fair outcome
    -- itself (no separate /fair/outcome call), returns hash/nonce/clientSeed/seedHash.
    local result = casinoRequestSync("/plinko/bet", "POST", {
        identifier = cid,
        stake = stake,
        rows = rows,
        risk = risk,
        autoSeed = true,
    })
    local nonce = result and result.nonce or 0
    local seedHash = result and result.serverSeedHash or ""
    local clientSeed = result and result.clientSeed or ""

    if not result or not result.success then
        -- Remove placeholder and refund
        if plinkoPending[src] then
            for i, entry in ipairs(plinkoPending[src]) do
                if entry.betId == betId then
                    table.remove(plinkoPending[src], i)
                    break
                end
            end
        end
        if demo then
            demoAdd(cid, stake)
            TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, {
                game = "plinko", success = false, message = "Engine error"
            })
        else
            local RefundPlayer = getPlayer(src)
            if RefundPlayer then
                RefundPlayer.Functions.AddMoney('cash', stake, 'casino-plinko-refund')
                TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, {
                    game = "plinko", success = false, message = "Engine error"
                })
            else
                MySQL.update('UPDATE players SET money = JSON_SET(money, "$.cash", JSON_EXTRACT(money, "$.cash") + ?) WHERE citizenid = ?',
                    {stake, cid})
            end
        end
        return
    end

    -- Update placeholder with real data (or pay via DB if player disconnected during yield)
    if not plinkoPending[src] then
        local cappedPayout = math.min(result.payout or 0, MAX_PAYOUT)
        if demo then
            demoAdd(cid, cappedPayout)
        else
            if cappedPayout > 0 then
                MySQL.update('UPDATE players SET money = JSON_SET(money, "$.cash", JSON_EXTRACT(money, "$.cash") + ?) WHERE citizenid = ?',
                    {cappedPayout, cid})
            end
            _G.SteakPost('/casino/record', { identifier = cid, game = 'plinko', stake = stake, multiplier = result.multiplier, payout = cappedPayout, won = cappedPayout > stake and 1 or 0, seed = result.hash or "", nonce = nonce })
        end
        return
    end

    -- Find and update our placeholder
    for i, entry in ipairs(plinkoPending[src]) do
        if entry.betId == betId then
            plinkoPending[src][i] = {
                betId = betId,
                payout = result.payout,
                cid = cid,
                stake = stake,
                multiplier = result.multiplier,
                hash = result.hash or "",
                nonce = nonce,
            }
            break
        end
    end

    TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, {
        game = "plinko", success = true, action = "result",
        betId = betId,
        bucket = result.bucket,
        multiplier = result.multiplier,
        payout = result.payout,
        stake = stake,
        path = result.path,
        balance = Player.PlayerData.money.cash,
        fairness = { nonce = nonce, seedHash = seedHash, clientSeed = clientSeed },
    })
end)

RegisterNetEvent('hk-sportsbetting:server:plinkoClaim', function(data)
    local src = source
    if not plinkoPending[src] or #plinkoPending[src] == 0 then return end

    local betId = data and data.betId or nil
    local claim = nil
    local claimIdx = nil

    if betId then
        for i, entry in ipairs(plinkoPending[src]) do
            if entry.betId == betId and not entry.placeholder then
                claim = entry
                claimIdx = i
                break
            end
        end
    end
    if not claim then return end
    table.remove(plinkoPending[src], claimIdx)

    local Player = getPlayer(src)
    local demo = isDemoPlayer(claim.cid)
    local cappedPayout = math.min(tonumber(claim.payout) or 0, MAX_PAYOUT)
    if cappedPayout > 0 then
        if demo then
            demoAdd(claim.cid, cappedPayout)
        elseif Player then
            Player.Functions.AddMoney('cash', cappedPayout, 'casino-plinko-' .. (claim.payout > claim.stake and 'win' or 'return'))
        else
            MySQL.update('UPDATE players SET money = JSON_SET(money, "$.cash", JSON_EXTRACT(money, "$.cash") + ?) WHERE citizenid = ?',
                {cappedPayout, claim.cid})
        end
    end

    TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, {
        game = "plinko", action = "claimed",
        balance = demo and demoGetBal(claim.cid) or (Player and Player.PlayerData.money.cash or 0),
    })

    if not demo then
        _G.SteakPost('/casino/record', { identifier = claim.cid, game = 'plinko', stake = claim.stake, multiplier = claim.multiplier, payout = claim.payout, won = claim.payout > claim.stake and 1 or 0, seed = claim.hash, nonce = claim.nonce })
        AddVipXPAsync(claim.cid, src, true, claim.stake, claim.payout, "plinko")  -- non-blocking on hot path

        if claim.payout < claim.stake then
            local refund = CheckLossStreakProtection(claim.cid, claim.stake)
            if refund > 0 and Player then
                Player.Functions.AddMoney('cash', refund, 'vip-loss-protection')
                TriggerClientEvent('hk-sportsbetting:client:updateBalance', src, Player.PlayerData.money.cash)
                TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, {
                    game = "vip", success = true, message = "Loss protection: +$" .. tostring(refund)
                })
            end
        end
    end
end)

-- ═══════════════════════════════════════════════════════════════
-- CLEANUP + ACTIVE GAME QUERY + HOME DATA
-- ═══════════════════════════════════════════════════════════════

AddEventHandler('playerDropped', function()
    local src = source
    local cid = cidCache[src]

    -- Pay out pending plinko claims on disconnect (DB path since Player is nil)
    if plinkoPending[src] then
        for _, claim in ipairs(plinkoPending[src]) do
            if claim.placeholder then
                -- Still waiting on engine — the yielded coroutine will detect plinkoPending[src]=nil and pay via DB
            else
                local cappedPayout = math.min(claim.payout or 0, MAX_PAYOUT)
                if cappedPayout > 0 then
                    MySQL.update('UPDATE players SET money = JSON_SET(money, "$.cash", JSON_EXTRACT(money, "$.cash") + ?) WHERE citizenid = ?',
                        {cappedPayout, claim.cid})
                end
                _G.SteakPost('/casino/record', { identifier = claim.cid, game = 'plinko', stake = claim.stake, multiplier = claim.multiplier or 0, payout = cappedPayout, won = cappedPayout > claim.stake and 1 or 0, seed = claim.hash or "", nonce = claim.nonce or 0 })
                AddVipXP(claim.cid, src, true, claim.stake, cappedPayout, "plinko")
            end
        end
        plinkoPending[src] = nil
    end

    -- Auto-cashout in-progress mines/chicken before cleanup
    -- Only pay if player revealed at least 1 tile (multiplier > 1), otherwise forfeit the bet
    if cid then
        settlingPlayers[cid] = true

        local minesResult = casinoRequestSync("/mines/cashout", "POST", { identifier = cid })
        if minesResult and minesResult.success and minesResult.payout and tonumber(minesResult.payout) > 0 then
            if (tonumber(minesResult.multiplier) or 0) > 1 then
                local cappedMines = math.min(tonumber(minesResult.payout), MAX_PAYOUT)
                MySQL.update('UPDATE players SET money = JSON_SET(money, "$.cash", JSON_EXTRACT(money, "$.cash") + ?) WHERE citizenid = ?',
                    {cappedMines, cid})
                _G.SteakPost('/casino/record', { identifier = cid, game = 'mines', stake = minesResult.stake or 0, multiplier = minesResult.multiplier or 0, payout = cappedMines, won = 1, seed = minesResult.hash or "", nonce = minesResult.nonce or 0 })
                AddVipXP(cid, src, true, minesResult.stake or 0, cappedMines, "mines")
            else
                _G.SteakPost('/casino/record', { identifier = cid, game = 'mines', stake = minesResult.stake or 0, multiplier = 0, payout = 0, won = 0, seed = minesResult.hash or "", nonce = minesResult.nonce or 0 })
            end
        end

        local chickenResult = casinoRequestSync("/chicken/cashout", "POST", { identifier = cid })
        if chickenResult and chickenResult.success and chickenResult.payout and tonumber(chickenResult.payout) > 0 then
            if (tonumber(chickenResult.multiplier) or 0) > 1 then
                local cappedChicken = math.min(tonumber(chickenResult.payout), MAX_PAYOUT)
                MySQL.update('UPDATE players SET money = JSON_SET(money, "$.cash", JSON_EXTRACT(money, "$.cash") + ?) WHERE citizenid = ?',
                    {cappedChicken, cid})
                _G.SteakPost('/casino/record', { identifier = cid, game = 'chicken', stake = chickenResult.stake or 0, multiplier = chickenResult.multiplier or 0, payout = cappedChicken, won = 1, seed = chickenResult.hash or "", nonce = chickenResult.nonce or 0 })
                AddVipXP(cid, src, true, chickenResult.stake or 0, cappedChicken, "chicken")
            else
                _G.SteakPost('/casino/record', { identifier = cid, game = 'chicken', stake = chickenResult.stake or 0, multiplier = 0, payout = 0, won = 0, seed = chickenResult.hash or "", nonce = chickenResult.nonce or 0 })
            end
        end

        casinoRequest("/disconnect/" .. cid, function() end, "POST", {})
        settlingPlayers[cid] = nil
    end

    crashWatchers[src] = nil
    playerLock[src] = nil
    lastPlinkoBet[src] = nil
    plinkoTimestamps[src] = nil
    plinkoBlocked[src] = nil
    lastPlinkoNotice[src] = nil
    nicknameCache[src] = nil
    if cid and betLock then betLock[cid] = nil end
    if claimLock then claimLock[src] = nil end
    cidCache[src] = nil
end)

RegisterNetEvent('hk-sportsbetting:server:getActiveGame', function()
    local src = source
    local cid = getCitizenId(src)
    if not cid or settlingPlayers[cid] then
        TriggerClientEvent('hk-sportsbetting:client:activeGame', src, { active = false })
        return
    end

    local result = casinoRequestSync("/active/" .. cid, "GET", nil)

    if result and result.active then
        TriggerClientEvent('hk-sportsbetting:client:activeGame', src, { active = true, games = result.games })
    else
        TriggerClientEvent('hk-sportsbetting:client:activeGame', src, { active = false })
    end
end)

-- hk_casinobets schema is now owned by the engine (db.js schema-init on
-- zx_wxyz_stream). No local table creation here anymore.

RegisterNetEvent('hk-sportsbetting:server:getGameHistory', function(data)
    local src = source
    local Player = getPlayer(src)
    if not Player then return end
    local cid = getCitizenId(src)
    if not cid then return end

    local game = tostring(data.game or "")
    local page = math.max(1, tonumber(data.page) or 1)

    local res = _G.SteakRequest('/casino/history/' .. cid .. '?game=' .. game .. '&page=' .. page, 'GET')
    if not res then return end
    TriggerClientEvent('hk-sportsbetting:client:gameHistory', src, {
        game = game,
        bets = res.bets or {},
        page = res.page or page,
        totalPages = res.totalPages or 1,
        total = res.total or 0,
    })
end)

RegisterNetEvent('hk-sportsbetting:server:getHomeData', function()
    local src = source
    local Player = getPlayer(src)
    if not Player then return end
    local cid = getCitizenId(src)
    if not cid then return end

    local playerName = getDisplayName(src)

    local home = _G.SteakRequest('/casino/home/' .. cid, 'GET')
    local recentBets = home and home.recentBets or {}
    local lastGame = home and home.lastGame or nil

    local trendingMatches = GetTrendingMatches and GetTrendingMatches() or {}

    TriggerClientEvent('hk-sportsbetting:client:homeData', src, {
        recentBets = recentBets,
        lastGame = lastGame,
        playerName = playerName,
        featuredMatches = trendingMatches,
    })
end)

-- ═══════════════════════════════════════════════════════════════
-- BLACKJACK — live multiplayer tables. Engine (/blackjack/*) runs the shoe +
-- state machine; FiveM is the money authority (escrow on sit/double/split/
-- insure, pay on settle) and broadcasts engine state to watchers. Mirrors the
-- CRASH relay model. Engine is authority on room limits; we refund on reject.
-- ═══════════════════════════════════════════════════════════════

local BJ_ROOMS = { "bj_main", "bj_vip" }
local BJ_SALON_MIN_XP = 15000000            -- Gold+ to enter VIP Salon (mirrors Config.VIP gold minXP)
local bjWatchers = {}                        -- src -> room (which room they're viewing)
local bjBets = {}                            -- cid -> { src, room, seat, mainStake, escrowed, demo, isBehind }
local bjSettledRound = { bj_main = -1, bj_vip = -1 }
local bjKickNotified = {}                     -- room -> { [cid]=true } dedup for seat-kick notices

local function bjReq(endpoint, method, body)
    return _G.EngineSync('/blackjack' .. endpoint, method or 'POST', body)
end
local function bjReqAsync(endpoint, method, body)
    _G.EngineRequest('/blackjack' .. endpoint, function() end, method or 'POST', body)
end

-- Fetch player XP for the Salon rank gate. Returns 0 on engine outage (fails closed
-- for the gate: caller treats <min as denied).
local function bjPlayerXP(cid)
    local row = _G.SteakRequest('/vip/row/' .. cid, 'GET')
    return row and tonumber(row.xp) or 0
end

-- Join/refresh watcher on a room. Sends the current no-id view for initial paint.
RegisterNetEvent('hk-sportsbetting:server:bjJoin', function(data)
    local src = source
    local room = tostring(data and data.room or "")
    if room ~= "bj_main" and room ~= "bj_vip" then return end
    if not checkEngine(src) then return end
    local cid = getCitizenId(src)
    if not cid then return end
    bjWatchers[src] = room
    local view = bjReq('/join', 'POST', { identifier = cid, name = getDisplayName(src), room = room })
    if view then
        TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, {
            game = "blackjack", action = "sync", room = room, view = view,
        })
    end
end)

-- Lobby snapshot: room list + live seat counts for the picker (no seat/escrow).
RegisterNetEvent('hk-sportsbetting:server:bjLobby', function()
    local src = source
    if not checkEngine(src) then return end
    local data = bjReq('/rooms', 'GET')
    if data and data.rooms then
        TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, {
            game = "blackjack", action = "lobby", rooms = data.rooms,
        })
    end
end)

RegisterNetEvent('hk-sportsbetting:server:bjLeave', function()
    local src = source
    local room = bjWatchers[src]
    bjWatchers[src] = nil
    if not room then return end
    local cid = getCitizenId(src)
    if not cid then return end
    -- Engine frees the seat + reports refundable escrow (waiting phase only).
    local res = bjReq('/leave', 'POST', { identifier = cid, room = room })
    if res and tonumber(res.refund) and res.refund > 0 and bjBets[cid] then
        local refund = math.floor(res.refund)
        local Player = getPlayer(src)
        if bjBets[cid].demo then demoAdd(cid, refund)
        elseif Player then
            Player.Functions.AddMoney('cash', refund, 'casino-blackjack-leave-refund')
            TriggerClientEvent('hk-sportsbetting:client:updateBalance', src, Player.PlayerData.money.cash)
        end
        bjBets[cid] = nil
    end
end)

-- Sit + place main bet (+ optional side bets). Escrows total up front; engine
-- validates limits + seat availability and returns the exact escrow it expects.
RegisterNetEvent('hk-sportsbetting:server:bjSit', function(data)
    local src = source
    if not checkEngine(src) then return end
    if playerLock[src] then
        TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, { game = "blackjack", success = false, message = "Processing..." })
        return
    end
    local room = tostring(data and data.room or "")
    if room ~= "bj_main" and room ~= "bj_vip" then return end
    local seat = tonumber(data.seat)
    local stake = math.floor(tonumber(data.stake) or 0)
    local pairs = math.floor(tonumber(data.pairs) or 0)
    local p3 = math.floor(tonumber(data.p3) or 0)
    local bust = math.floor(tonumber(data.bust) or 0)
    local hot3 = math.floor(tonumber(data.hot3) or 0)
    if not seat or seat < 0 or seat > 7 or stake <= 0 then
        TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, { game = "blackjack", success = false, message = "Invalid bet" })
        return
    end
    if pairs < 0 or p3 < 0 or bust < 0 or hot3 < 0 then
        TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, { game = "blackjack", success = false, message = "Invalid side bet" })
        return
    end

    withLock(src, function()
        local Player = getPlayer(src)
        if not Player then return end
        local cid = getCitizenId(src)
        if not cid then return end
        if bjBets[cid] then
            TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, { game = "blackjack", success = false, message = "Already in this round" })
            return
        end
        local demo = isDemoPlayer(cid)

        -- VIP Salon rank gate.
        if room == "bj_vip" and bjPlayerXP(cid) < BJ_SALON_MIN_XP then
            TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, { game = "blackjack", success = false, message = "VIP Salon requires Gold rank+" })
            return
        end

        -- Personal/tier max-bet ceiling on the MAIN stake (side bets ride under it).
        local maxBet = GetPlayerMaxBet(cid)
        if maxBet == nil then
            TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, { game = "blackjack", success = false, message = "Casino engine offline" })
            return
        end
        if stake > maxBet then
            TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, { game = "blackjack", success = false, message = "Max bet for your tier: $" .. tostring(maxBet) })
            return
        end

        local total = stake + pairs + p3 + bust + hot3
        local playerCash = tonumber(demo and demoGetBal(cid) or Player.PlayerData.money.cash) or 0
        if playerCash < total then
            TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, { game = "blackjack", success = false, message = "Insufficient cash" })
            return
        end

        -- Escrow the full amount BEFORE the engine call (crash pattern).
        if demo then
            demoRemove(cid, total)
        else
            if not Player.Functions.RemoveMoney('cash', total, 'casino-blackjack') then
                TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, { game = "blackjack", success = false, message = "Insufficient cash" })
                return
            end
        end

        local res = bjReq('/sit', 'POST', {
            identifier = cid, name = getDisplayName(src), room = room, seat = seat,
            stake = stake, pairs = pairs, p3 = p3, bust = bust, hot3 = hot3,
        })

        if not res or not res.ok then
            -- Refund on any engine reject (seat taken, limits, closed window).
            if demo then demoAdd(cid, total)
            else Player.Functions.AddMoney('cash', total, 'casino-blackjack-refund') end
            TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, { game = "blackjack", success = false, message = res and res.error or "Bet rejected" })
            return
        end

        bjBets[cid] = { src = src, room = room, seat = seat, mainStake = stake, escrowed = total, demo = demo, isBehind = false }
        bjWatchers[src] = room
        TriggerClientEvent('hk-sportsbetting:client:updateBalance', src, demo and demoGetBal(cid) or Player.PlayerData.money.cash)
        TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, {
            game = "blackjack", action = "seated", room = room, seat = seat, view = res.view,
        })
    end)
end)

-- Bet-behind a seated player. Escrows up front; engine caps at seat's own bet.
RegisterNetEvent('hk-sportsbetting:server:bjBehind', function(data)
    local src = source
    if not checkEngine(src) then return end
    if playerLock[src] then return end
    local room = tostring(data and data.room or "")
    if room ~= "bj_main" and room ~= "bj_vip" then return end
    local seat = tonumber(data.seat)
    local stake = math.floor(tonumber(data.stake) or 0)
    local pairs = math.floor(tonumber(data.pairs) or 0)
    local p3 = math.floor(tonumber(data.p3) or 0)
    local bust = math.floor(tonumber(data.bust) or 0)
    local hot3 = math.floor(tonumber(data.hot3) or 0)
    if not seat or stake <= 0 then
        TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, { game = "blackjack", success = false, message = "Invalid bet" })
        return
    end
    if pairs < 0 or p3 < 0 or bust < 0 or hot3 < 0 then
        TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, { game = "blackjack", success = false, message = "Invalid side bet" })
        return
    end

    withLock(src, function()
        local Player = getPlayer(src)
        if not Player then return end
        local cid = getCitizenId(src)
        if not cid then return end
        if bjBets[cid] then
            TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, { game = "blackjack", success = false, message = "Already in this round" })
            return
        end
        local demo = isDemoPlayer(cid)
        if room == "bj_vip" and bjPlayerXP(cid) < BJ_SALON_MIN_XP then
            TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, { game = "blackjack", success = false, message = "VIP Salon requires Gold rank+" })
            return
        end
        local maxBet = GetPlayerMaxBet(cid)
        if maxBet == nil then return end
        if stake > maxBet then
            TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, { game = "blackjack", success = false, message = "Max bet for your tier: $" .. tostring(maxBet) })
            return
        end
        local total = stake + pairs + p3 + bust + hot3
        local playerCash = tonumber(demo and demoGetBal(cid) or Player.PlayerData.money.cash) or 0
        if playerCash < total then
            TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, { game = "blackjack", success = false, message = "Insufficient cash" })
            return
        end
        if demo then demoRemove(cid, total)
        else
            if not Player.Functions.RemoveMoney('cash', total, 'casino-blackjack-behind') then return end
        end
        local res = bjReq('/behind', 'POST', {
            identifier = cid, name = getDisplayName(src), room = room, seat = seat,
            stake = stake, pairs = pairs, p3 = p3, bust = bust, hot3 = hot3,
        })
        if not res or not res.ok then
            if demo then demoAdd(cid, total) else Player.Functions.AddMoney('cash', total, 'casino-blackjack-behind-refund') end
            TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, { game = "blackjack", success = false, message = res and res.error or "Bet rejected" })
            return
        end
        bjBets[cid] = { src = src, room = room, seat = seat, mainStake = stake, escrowed = total, demo = demo, isBehind = true }
        bjWatchers[src] = room
        TriggerClientEvent('hk-sportsbetting:client:updateBalance', src, demo and demoGetBal(cid) or Player.PlayerData.money.cash)
        TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, { game = "blackjack", action = "behindPlaced", room = room, seat = seat, view = res.view })
    end)
end)

-- Insurance during the insurance window. Escrows up to half the main bet.
RegisterNetEvent('hk-sportsbetting:server:bjInsure', function(data)
    local src = source
    if playerLock[src] then return end
    local stake = math.floor(tonumber(data and data.stake) or 0)
    if stake <= 0 then return end
    withLock(src, function()
        local Player = getPlayer(src)
        if not Player then return end
        local cid = getCitizenId(src)
        if not cid or not bjBets[cid] then return end
        local bet = bjBets[cid]
        if bet.isBehind then return end
        local demo = bet.demo
        local playerCash = tonumber(demo and demoGetBal(cid) or Player.PlayerData.money.cash) or 0
        if playerCash < stake then return end
        if demo then demoRemove(cid, stake)
        else if not Player.Functions.RemoveMoney('cash', stake, 'casino-blackjack-insurance') then return end end
        local res = bjReq('/insure', 'POST', { identifier = cid, room = bet.room, stake = stake })
        if not res or not res.ok then
            if demo then demoAdd(cid, stake) else Player.Functions.AddMoney('cash', stake, 'casino-blackjack-insurance-refund') end
            return
        end
        -- Engine may have capped the insurance below what we escrowed; refund the diff.
        local accepted = math.floor(tonumber(res.escrow) or stake)
        if accepted < stake then
            local back = stake - accepted
            if demo then demoAdd(cid, back) else Player.Functions.AddMoney('cash', back, 'casino-blackjack-insurance-cap-refund') end
        end
        bet.escrowed = bet.escrowed + accepted
        TriggerClientEvent('hk-sportsbetting:client:updateBalance', src, demo and demoGetBal(cid) or Player.PlayerData.money.cash)
        TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, { game = "blackjack", action = "insured", room = bet.room, view = res.view })
    end)
end)

-- Player action. hit/stand/surrender are free; double/split need extra escrow.
-- For double/split we escrow the matching stake FIRST (equal to main stake per
-- hand), then call the engine; refund if it rejects. Engine returns escrowDelta
-- as the authoritative amount — we reconcile against what we took.
RegisterNetEvent('hk-sportsbetting:server:bjAction', function(data)
    local src = source
    if playerLock[src] then
        TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, { game = "blackjack", success = false, message = "Processing..." })
        return
    end
    local action = tostring(data and data.action or "")
    if action ~= "hit" and action ~= "stand" and action ~= "double" and action ~= "split" and action ~= "surrender" then return end

    withLock(src, function()
        local Player = getPlayer(src)
        if not Player then return end
        local cid = getCitizenId(src)
        if not cid or not bjBets[cid] then return end
        local bet = bjBets[cid]
        if bet.isBehind then return end   -- bet-behind has no decisions
        local demo = bet.demo

        local needsEscrow = (action == "double" or action == "split")
        local extra = bet.mainStake       -- double/split cost = one matching main stake
        if needsEscrow then
            local playerCash = tonumber(demo and demoGetBal(cid) or Player.PlayerData.money.cash) or 0
            if playerCash < extra then
                TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, { game = "blackjack", success = false, message = "Insufficient cash to " .. action })
                return
            end
            if demo then demoRemove(cid, extra)
            else if not Player.Functions.RemoveMoney('cash', extra, 'casino-blackjack-' .. action) then return end end
        end

        local res = bjReq('/action', 'POST', { identifier = cid, room = bet.room, action = action })
        if not res or not res.ok then
            if needsEscrow then
                if demo then demoAdd(cid, extra) else Player.Functions.AddMoney('cash', extra, 'casino-blackjack-' .. action .. '-refund') end
            end
            TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, { game = "blackjack", success = false, message = res and res.error or "Action failed" })
            return
        end

        if needsEscrow then
            local delta = math.floor(tonumber(res.escrowDelta) or extra)
            -- Reconcile: refund if engine charged less than we took (shouldn't differ, but safe).
            if delta < extra then
                local back = extra - delta
                if demo then demoAdd(cid, back) else Player.Functions.AddMoney('cash', back, 'casino-blackjack-escrow-reconcile') end
            end
            bet.escrowed = bet.escrowed + delta
            TriggerClientEvent('hk-sportsbetting:client:updateBalance', src, demo and demoGetBal(cid) or Player.PlayerData.money.cash)
        end

        TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, {
            game = "blackjack", action = "acted", room = bet.room, view = res.view,
        })
    end)
end)

-- Settle one room's finished round: pay every player their total payout (capped),
-- record each result, award VIP XP, apply loss protection. Idempotent per roundId.
local function bjSettleRoom(room, result)
    if not result or not result.players then return end
    if bjSettledRound[room] == result.roundId then return end   -- already settled
    bjSettledRound[room] = result.roundId

    for _, p in ipairs(result.players) do
        local cid = p.identifier
        -- WEB players are settled by the engine itself (it took their cash, not us,
        -- and pays them back directly — see mobileBlackjack setWebBjSettleHandler).
        -- The shared result lists them so in-game clients render their seats, but we
        -- must NOT pay/record them here or their winnings would be paid twice.
        -- Mirrors the crash split. This is the ONLY gate needed for shared tables.
        if cid and not p.web then
            local bet = bjBets[cid]
            local staked = math.floor(tonumber(p.staked) or 0)
            local rawPayout = math.floor(tonumber(p.payout) or 0)
            -- Per-room ceiling (falls back to the global cap for an unknown room).
            local roomCap = BJ_ROOM_CAP[room] or MAX_PAYOUT
            local payout = math.min(rawPayout, roomCap)
            -- Never silently clip: if the room cap actually bit, the player earned
            -- more than we paid — log it loudly so it can be reconciled by hand.
            if rawPayout > payout then
                print(("[hk-sportsbetting] BLACKJACK PAYOUT CLIPPED: room=%s cid=%s earned=$%d paid=$%d (cap $%d, staked $%d) — reconcile manually")
                    :format(tostring(room), tostring(cid), rawPayout, payout, roomCap, staked))
            end
            local won = payout > staked
            local demo = bet and bet.demo or isDemoPlayer(cid)
            local Player = QBCore.Functions.GetPlayerByCitizenId(cid)
            local activeSrc = Player and Player.PlayerData.source or (bet and bet.src) or nil

            if payout > 0 then
                if demo then demoAdd(cid, payout)
                elseif Player then
                    Player.Functions.AddMoney('cash', payout, 'casino-blackjack-win')
                    if activeSrc then TriggerClientEvent('hk-sportsbetting:client:updateBalance', activeSrc, Player.PlayerData.money.cash) end
                else
                    MySQL.update('UPDATE players SET money = JSON_SET(money, "$.cash", JSON_EXTRACT(money, "$.cash") + ?) WHERE citizenid = ?', { payout, cid })
                end
            end

            if not demo then
                -- Record once per player with net figures; multiplier = payout/stake.
                local mult = staked > 0 and (payout / staked) or 0
                _G.SteakPost('/casino/record', { identifier = cid, game = 'blackjack', stake = staked, multiplier = mult, payout = payout, won = won and 1 or 0, seed = result.serverSeedHash or "", nonce = result.shoeNonce or 0 })
                AddVipXP(cid, activeSrc, true, staked, won and payout or 0, "blackjack")
                if not won and Player then
                    local refund = CheckLossStreakProtection(cid, staked)
                    if refund > 0 then
                        Player.Functions.AddMoney('cash', refund, 'vip-loss-protection')
                        if activeSrc then
                            TriggerClientEvent('hk-sportsbetting:client:updateBalance', activeSrc, Player.PlayerData.money.cash)
                            TriggerClientEvent('hk-sportsbetting:client:casinoResult', activeSrc, { game = "vip", success = true, message = "Loss protection: +$" .. tostring(refund) })
                        end
                    end
                end
                if won and payout >= 1000000 and activeSrc then
                    -- big-win discord handled engine-side via record; nothing extra here
                end
            end

            bjBets[cid] = nil
        end
    end
end

-- Broadcast loop: poll each room the watchers care about, push state to them,
-- and trigger settlement when a room enters payout. Only polls rooms with
-- watchers (idle tables cost nothing). ~350ms cadence — turn-based, no anim sync.
CreateThread(function()
    Wait(6000)
    local lastState = { bj_main = "idle", bj_vip = "idle" }
    while true do
        Wait(350)
        -- Which rooms have anyone watching? (bjWatchers is src -> room)
        local activeRooms = {}
        for _, room in pairs(bjWatchers) do activeRooms[room] = true end
        if next(activeRooms) == nil then
            Wait(1500)
        else
            for room, _ in pairs(activeRooms) do
                local state = bjReq('/state/' .. room, 'GET', nil)
                if state then
                    -- Seats freed at the last window close (no bet placed): tell
                    -- those clients they lost the seat so their UI resets to the
                    -- seat picker. Nothing to refund (bet was 0). The engine keeps
                    -- the kick list up for the whole round, so dedup per cid so we
                    -- notify each kicked player exactly once (not every poll tick).
                    local kicked = {}
                    if type(state.kicked) == "table" then
                        for _, kid in ipairs(state.kicked) do kicked[tostring(kid)] = true end
                    end
                    bjKickNotified[room] = bjKickNotified[room] or {}
                    -- Drop stale entries no longer in the engine's kick list.
                    for cid in pairs(bjKickNotified[room]) do
                        if not kicked[cid] then bjKickNotified[room][cid] = nil end
                    end
                    -- Broadcast a PERSONALIZED view per watcher. /state/:room?id=<cid>
                    -- scopes isMe onto that player's seat; the id-less `state` fetch
                    -- above has isMe=false everywhere. Without the scoped view a
                    -- player who closes + reopens the casino mid-round remounts the
                    -- UI with no seat, so the felt shows "your turn" but renders no
                    -- hit/stand controls (the restore bug). Cache per cid so we fetch
                    -- once per player per tick even if they watch twice. Spectators
                    -- (no cid) still get the shared id-less view.
                    local pviewCache = {}
                    for wsrc, wroom in pairs(bjWatchers) do
                        if wroom == room then
                            local wcid = getCitizenId(wsrc)
                            local pview = nil
                            if wcid then
                                if pviewCache[wcid] ~= nil then
                                    pview = pviewCache[wcid]
                                else
                                    pview = bjReq('/state/' .. room .. '?id=' .. wcid, 'GET', nil)
                                    if pview then pviewCache[wcid] = pview end
                                end
                            end
                            -- Never fall back to the id-less view for a seated player:
                            -- it would blank their own turn controls. If the scoped
                            -- fetch hiccups, skip them this tick (they keep their last
                            -- good view; the next 350ms poll refreshes).
                            if pview then
                                TriggerClientEvent('hk-sportsbetting:client:casinoResult', wsrc, {
                                    game = "blackjack", action = "state", room = room, view = pview,
                                })
                            elseif not wcid then
                                TriggerClientEvent('hk-sportsbetting:client:casinoResult', wsrc, {
                                    game = "blackjack", action = "state", room = room, view = state,
                                })
                            end
                            if next(kicked) ~= nil then
                                if wcid and kicked[tostring(wcid)] and not bjKickNotified[room][tostring(wcid)] then
                                    bjKickNotified[room][tostring(wcid)] = true
                                    TriggerClientEvent('hk-sportsbetting:client:casinoResult', wsrc, {
                                        game = "blackjack", action = "kicked", room = room,
                                        message = "Seat freed — no bet placed",
                                    })
                                    bjBets[wcid] = nil
                                end
                            end
                        end
                    end
                    -- On entering payout, CLAIM settlement once and pay out. The
                    -- engine gates the claim per-roundId (persistent across our
                    -- restarts), so a resource restart can never re-pay a round.
                    if state.state == "payout" and lastState[room] ~= "payout" then
                        local settle = bjReq('/settle/' .. room .. '/claim', 'POST', nil)
                        if settle and settle.result then
                            bjSettleRoom(room, settle.result)
                            for wsrc, wroom in pairs(bjWatchers) do
                                if wroom == room then
                                    TriggerClientEvent('hk-sportsbetting:client:casinoResult', wsrc, {
                                        game = "blackjack", action = "settled", room = room, result = settle.result,
                                    })
                                end
                            end
                        end
                    end
                    lastState[room] = state.state
                end
            end
        end
    end
end)

-- Recover orphaned blackjack bets on resource start (engine may hold a table
-- whose payout we genuinely missed during a restart). Uses the atomic CLAIM
-- endpoint so an already-paid round returns nothing — without this guard the
-- engine's persistent lastResult was re-paid on every single restart.
CreateThread(function()
    Wait(4000)
    for _, room in ipairs(BJ_ROOMS) do
        local settle = bjReq('/settle/' .. room .. '/claim', 'POST', nil)
        if settle and settle.result and settle.result.players and #settle.result.players > 0 then
            bjSettleRoom(room, settle.result)
        end
    end
end)

-- Disconnect cleanup for blackjack. Registered as its own handler; captures the
-- cid at the top before the primary playerDropped handler clears cidCache. Tells
-- the engine to free the seat (betting phase) or let it ride to settle (mid-round,
-- where the settle poll credits the DB even if the player is gone).
AddEventHandler('playerDropped', function()
    local src = source
    -- Capture cid immediately; the QBCore player may already be detaching, so fall
    -- back to any bet record we hold (keyed by cid, but we can find it by src).
    local cid = cidCache[src]
    if not cid then
        for c, b in pairs(bjBets) do if b.src == src then cid = c break end end
    end
    bjWatchers[src] = nil
    if not cid then return end
    local res = bjReq('/disconnect', 'POST', { identifier = cid })
    if res and tonumber(res.refund) and res.refund > 0 and bjBets[cid] then
        local refund = math.floor(res.refund)
        if bjBets[cid].demo then
            demoAdd(cid, refund)
        else
            MySQL.update('UPDATE players SET money = JSON_SET(money, "$.cash", JSON_EXTRACT(money, "$.cash") + ?) WHERE citizenid = ?', { refund, cid })
        end
        bjBets[cid] = nil
    end
end)

-- ═══════════════════════════════════════════════════════════════
-- MAHJONG — live multiplayer tables (HK Old Style, more styles later).
-- Engine (/mahjong/*) runs the wall, turn state machine + bots + scoring.
-- FiveM is the money authority, but this is a CHIP-STACK game: real cash moves
-- only at BUY-IN (escrow on join/create) and CASH-OUT (leave/disconnect). Per-
-- hand chip swings stay inside engine stacks; at settlement the relay only
-- routes the explicit 1% rake to the gov accounts. The bot-table house edge
-- (house funds the bot seats) accrues automatically through the escrow/cash-out
-- void, exactly like blackjack variance — no per-hand cash moves for it.
-- Money rules (per user spec): full-human table → 1% rake per payout; any bot
-- at the table → no rake (house is already the bot counterparty); Gold+ host →
-- rake-free hosting. All three are enforced ENGINE-side; relay just routes rake.
-- ═══════════════════════════════════════════════════════════════

local MJ_GOLD_MIN_XP = 15000000          -- Gold+ host → free (rake-free) hosting (mirrors BJ_SALON_MIN_XP)
local MJ_POLL_MS = 150                    -- tight enough that claim buttons (pung/chow/win) appear near-instantly
local mjWatchers = {}                     -- src -> lobbyId (which table they're viewing)
local mjSeated = {}                       -- cid -> { src, lobby, seat, buyIn, escrowed, demo }
local mjSettledHand = {}                  -- lobbyId -> last handNumber we settled (dedup)

local function mjReq(endpoint, method, body)
    return _G.EngineSync('/mahjong' .. endpoint, method or 'POST', body)
end

-- Fetch player XP for the free-hosting gate. Fails closed (0 = not Gold) on outage.
local function mjPlayerXP(cid)
    local row = _G.SteakRequest('/vip/row/' .. cid, 'GET')
    return row and tonumber(row.xp) or 0
end

-- Style list for the create form (variants + limits + buy-in units).
RegisterNetEvent('hk-sportsbetting:server:mjStyles', function()
    local src = source
    if not checkEngine(src) then return end
    local data = mjReq('/styles', 'GET')
    if data then
        TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, {
            game = "mahjong", action = "styles", styles = data.styles,
            baseBetMin = data.baseBetMin, baseBetMax = data.baseBetMax,
            buyInUnits = data.buyInUnits, maxLobbies = data.maxLobbies,
        })
    end
end)

-- Live lobby list for the browser (all public + joinable).
RegisterNetEvent('hk-sportsbetting:server:mjLobbies', function()
    local src = source
    if not checkEngine(src) then return end
    local data = mjReq('/lobbies', 'GET')
    if data and data.lobbies then
        TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, {
            game = "mahjong", action = "lobbies", lobbies = data.lobbies, max = data.max,
        })
    end
end)

-- Create a table + auto-seat the host in seat 0. Escrows the host's buy-in
-- (baseBet × BUYIN_UNITS) BEFORE the engine call; refunds on any reject.
RegisterNetEvent('hk-sportsbetting:server:mjCreate', function(data)
    local src = source
    if not checkEngine(src) then return end
    if playerLock[src] then
        TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, { game = "mahjong", success = false, message = "Processing..." })
        return
    end
    local style = tostring(data and data.style or "")
    local baseBet = math.floor(tonumber(data and data.baseBet) or 0)
    local lobbyName = data and data.name and tostring(data.name):sub(1, 40) or nil
    local password = data and data.password and tostring(data.password) or nil
    local fillBots = (data == nil) or (data.fillBots ~= false)   -- default: fill empty seats with bots
    if baseBet <= 0 then
        TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, { game = "mahjong", success = false, message = "Invalid bet amount" })
        return
    end
    if password ~= nil and password ~= "" and not password:match("^%d%d%d%d$") then
        TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, { game = "mahjong", success = false, message = "Password must be 4 digits" })
        return
    end

    withLock(src, function()
        local Player = getPlayer(src)
        if not Player then return end
        local cid = getCitizenId(src)
        if not cid then return end
        if mjSeated[cid] then
            TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, { game = "mahjong", success = false, message = "You are already at a table" })
            return
        end
        local demo = isDemoPlayer(cid)

        -- Base bet must sit within the host's tier max-bet ceiling.
        local maxBet = GetPlayerMaxBet(cid)
        if maxBet == nil then
            TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, { game = "mahjong", success = false, message = "Casino engine offline" })
            return
        end
        if baseBet > maxBet then
            TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, { game = "mahjong", success = false, message = "Max base bet for your tier: $" .. tostring(maxBet) })
            return
        end

        local buyIn = baseBet * 200   -- BUYIN_UNITS mirrors engine (baseBet × 200)
        local playerCash = tonumber(demo and demoGetBal(cid) or Player.PlayerData.money.cash) or 0
        if playerCash < buyIn then
            TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, { game = "mahjong", success = false, message = "Buy-in is $" .. tostring(buyIn) .. " (200× base bet)" })
            return
        end

        -- Gold+ hosts host rake-free (their created table waives the 1% rake).
        local noRake = (mjPlayerXP(cid) >= MJ_GOLD_MIN_XP)

        -- Escrow BEFORE the engine call.
        if demo then demoRemove(cid, buyIn)
        else
            if not Player.Functions.RemoveMoney('cash', buyIn, 'casino-mahjong-buyin') then
                TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, { game = "mahjong", success = false, message = "Insufficient cash" })
                return
            end
        end

        local res = mjReq('/create', 'POST', {
            identifier = cid, name = getDisplayName(src), style = style, baseBet = baseBet,
            password = (password ~= "" and password) or nil, fillBots = fillBots,
            noRake = noRake, rank = noRake and 1 or 0,
        })
        if not res or not res.ok then
            if demo then demoAdd(cid, buyIn) else Player.Functions.AddMoney('cash', buyIn, 'casino-mahjong-buyin-refund') end
            TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, { game = "mahjong", success = false, message = res and res.error or "Could not create table" })
            return
        end

        mjSeated[cid] = { src = src, lobby = res.id, seat = res.seat or 0, buyIn = buyIn, escrowed = buyIn, demo = demo }
        mjWatchers[src] = res.id
        TriggerClientEvent('hk-sportsbetting:client:updateBalance', src, demo and demoGetBal(cid) or Player.PlayerData.money.cash)
        TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, {
            game = "mahjong", action = "created", lobby = res.id, seat = res.seat or 0,
            buyIn = buyIn, noRake = noRake, view = res.view,
        })
    end)
end)

-- Join an existing table + take a seat. Escrows buy-in BEFORE the engine call;
-- refunds on reject (wrong password, table full, closed). A rejoin (already
-- seated) takes no money and just re-registers the watcher.
RegisterNetEvent('hk-sportsbetting:server:mjJoin', function(data)
    local src = source
    if not checkEngine(src) then return end
    if playerLock[src] then
        TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, { game = "mahjong", success = false, message = "Processing..." })
        return
    end
    local lobbyId = tostring(data and data.lobby or "")
    if lobbyId == "" then return end
    local password = data and data.password and tostring(data.password) or nil
    local seat = data and data.seat ~= nil and tonumber(data.seat) or nil

    withLock(src, function()
        local Player = getPlayer(src)
        if not Player then return end
        local cid = getCitizenId(src)
        if not cid then return end

        -- Already seated somewhere? Only allow a rejoin of the SAME table.
        if mjSeated[cid] then
            if mjSeated[cid].lobby == lobbyId then
                mjWatchers[src] = lobbyId
                local res = mjReq('/join', 'POST', { identifier = cid, id = lobbyId, name = getDisplayName(src), password = password })
                if res and res.ok then
                    TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, { game = "mahjong", action = "seated", lobby = lobbyId, seat = mjSeated[cid].seat, rejoined = true, view = res.view })
                end
            else
                TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, { game = "mahjong", success = false, message = "Leave your current table first" })
            end
            return
        end

        local demo = isDemoPlayer(cid)

        -- Need the table's base bet to know the buy-in. Peek the lobby list.
        local list = mjReq('/lobbies', 'GET')
        local target = nil
        if list and list.lobbies then
            for _, lb in ipairs(list.lobbies) do if lb.id == lobbyId then target = lb break end end
        end
        if not target then
            TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, { game = "mahjong", success = false, message = "Table no longer exists" })
            return
        end
        local buyIn = math.floor(tonumber(target.buyIn) or (tonumber(target.baseBet) * 200))
        local playerCash = tonumber(demo and demoGetBal(cid) or Player.PlayerData.money.cash) or 0
        if playerCash < buyIn then
            TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, { game = "mahjong", success = false, message = "Buy-in is $" .. tostring(buyIn) })
            return
        end

        -- Escrow BEFORE the engine call.
        if demo then demoRemove(cid, buyIn)
        else
            if not Player.Functions.RemoveMoney('cash', buyIn, 'casino-mahjong-buyin') then
                TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, { game = "mahjong", success = false, message = "Insufficient cash" })
                return
            end
        end

        local res = mjReq('/join', 'POST', {
            identifier = cid, id = lobbyId, name = getDisplayName(src),
            password = (password ~= "" and password) or nil, seat = seat, rank = 0,
        })
        if not res or not res.ok then
            if demo then demoAdd(cid, buyIn) else Player.Functions.AddMoney('cash', buyIn, 'casino-mahjong-buyin-refund') end
            TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, { game = "mahjong", success = false, message = res and res.error or "Could not join table" })
            return
        end

        -- Engine reports the exact escrow it booked; reconcile if it differs.
        local booked = math.floor(tonumber(res.escrow) or buyIn)
        if booked < buyIn then
            local back = buyIn - booked
            if demo then demoAdd(cid, back) else Player.Functions.AddMoney('cash', back, 'casino-mahjong-buyin-reconcile') end
        end

        mjSeated[cid] = { src = src, lobby = lobbyId, seat = res.seat or seat or 0, buyIn = booked, escrowed = booked, demo = demo }
        mjWatchers[src] = lobbyId
        TriggerClientEvent('hk-sportsbetting:client:updateBalance', src, demo and demoGetBal(cid) or Player.PlayerData.money.cash)
        TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, {
            game = "mahjong", action = "seated", lobby = lobbyId, seat = res.seat or seat or 0, view = res.view,
        })
    end)
end)

-- Spectate a table without sitting (watch the green felt). No money.
RegisterNetEvent('hk-sportsbetting:server:mjWatch', function(data)
    local src = source
    if not checkEngine(src) then return end
    local lobbyId = tostring(data and data.lobby or "")
    if lobbyId == "" then return end
    local cid = getCitizenId(src)
    if not cid then return end
    mjWatchers[src] = lobbyId
    local res = mjReq('/watch', 'POST', { identifier = cid, id = lobbyId })
    if res then
        TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, { game = "mahjong", action = "sync", lobby = lobbyId, view = res })
    end
end)

-- Leave / cash out. Credits the engine-reported chip stack back as real money.
RegisterNetEvent('hk-sportsbetting:server:mjLeave', function()
    local src = source
    local lobbyId = mjWatchers[src]
    mjWatchers[src] = nil
    local cid = getCitizenId(src)
    if not cid then return end
    local seat = mjSeated[cid]
    if not seat then return end   -- was only spectating
    local res = mjReq('/leave', 'POST', { identifier = cid, id = seat.lobby })
    local cashOut = math.floor(tonumber(res and res.cashOut) or 0)
    if cashOut > 0 then
        if seat.demo then demoAdd(cid, cashOut)
        else
            local Player = getPlayer(src)
            if Player then
                Player.Functions.AddMoney('cash', cashOut, 'casino-mahjong-cashout')
                TriggerClientEvent('hk-sportsbetting:client:updateBalance', src, Player.PlayerData.money.cash)
            else
                MySQL.update('UPDATE players SET money = JSON_SET(money, "$.cash", JSON_EXTRACT(money, "$.cash") + ?) WHERE citizenid = ?', { cashOut, cid })
            end
        end
    end
    -- Record the session's net result for stats/XP (chip-stack: stake = buy-in,
    -- payout = cash-out). skipHouseRoute: the 1% rake was already routed per-hand.
    if not seat.demo then
        AddVipXP(cid, src, true, seat.buyIn or 0, cashOut, "mahjong", true)
    end
    mjSeated[cid] = nil
    TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, { game = "mahjong", action = "left", cashOut = cashOut })
end)

-- Host starts the game (deal first hand). Engine gates host-only + min players.
RegisterNetEvent('hk-sportsbetting:server:mjStart', function()
    local src = source
    if not checkEngine(src) then return end
    local cid = getCitizenId(src)
    if not cid or not mjSeated[cid] then return end
    local res = mjReq('/start', 'POST', { identifier = cid, id = mjSeated[cid].lobby })
    if not res or not res.ok then
        TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, { game = "mahjong", success = false, message = res and res.error or "Could not start" })
        return
    end
    TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, { game = "mahjong", action = "started", lobby = mjSeated[cid].lobby, view = res.view })
end)

-- Player action: discard | win | kong | claim | pass. No money moves here (chip
-- stacks are internal); the engine validates turn/claim legality and returns the
-- fresh view. The poll loop broadcasts state + settles on payout.
RegisterNetEvent('hk-sportsbetting:server:mjAction', function(data)
    local src = source
    if playerLock[src] then return end
    local action = tostring(data and data.action or "")
    if action ~= "discard" and action ~= "win" and action ~= "kong"
       and action ~= "claim" and action ~= "pass" then return end
    withLock(src, function()
        local cid = getCitizenId(src)
        if not cid or not mjSeated[cid] then return end
        local body = { identifier = cid, id = mjSeated[cid].lobby, action = action }
        if data.tile ~= nil then body.tile = data.tile end
        if data.claim ~= nil then body.claim = data.claim end
        if data.meldTiles ~= nil then body.meldTiles = data.meldTiles end
        local res = mjReq('/action', 'POST', body)
        if not res or not res.ok then
            TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, { game = "mahjong", success = false, message = res and res.error or "Action rejected" })
            return
        end
        TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, { game = "mahjong", action = "acted", lobby = mjSeated[cid].lobby, view = res.view })
    end)
end)

-- Settle one finished hand: route the reported rake to the gov accounts. No
-- per-player cash moves (chip-stack game — swings live in engine stacks until
-- cash-out). Idempotent per (lobby, handNumber): the engine's /claim endpoint
-- gates the same handNumber persistently, and we dedup here too.
local function mjSettleHand(lobbyId, result)
    if not result then return end
    local hn = tonumber(result.handNumber) or -1
    if mjSettledHand[lobbyId] == hn then return end
    mjSettledHand[lobbyId] = hn

    -- A win routes rake. 跑馬仔 washouts move NO win money but DO settle kong
    -- income (開槓收錢 is independent of 和牌), so per-seat deltas can still be
    -- non-zero on a washout and must be recorded for stats. hk_old washouts
    -- carry empty deltas and fall through harmlessly.
    if result.kind == "win" then
        local rake = math.floor(tonumber(result.rake) or 0)
        if rake > 0 then
            routeHouseProfit(rake)   -- 82/13/5 jockeyclub/whitehouse/congress
        end
    end
    if result.kind == "win" or result.kind == "washout" then
        -- Record each HUMAN seat's per-hand swing for stats (seatIds maps seat->cid).
        local seatIds = result.seatIds or {}
        local deltas = result.deltas or {}
        for seatIdx, cid in pairs(seatIds) do
            local d = math.floor(tonumber(deltas[seatIdx] or deltas[tostring(seatIdx)]) or 0)
            if cid and not isDemoPlayer(cid) and d ~= 0 then
                local won = d > 0
                _G.SteakPost('/casino/record', {
                    identifier = cid, game = 'mahjong',
                    stake = math.abs(d), multiplier = won and 2 or 0,
                    payout = won and d or 0, won = won and 1 or 0,
                    seed = result.serverSeedHash or "", nonce = result.handNonce or 0,
                })
            end
        end
    end
end

-- Broadcast loop: poll each table that has watchers, push state to them, and
-- settle on the payout/washout transition. Only polls tables with watchers.
CreateThread(function()
    Wait(6000)
    local lastState = {}   -- lobbyId -> last seen state string
    while true do
        Wait(MJ_POLL_MS)
        local activeLobbies = {}
        for _, lobbyId in pairs(mjWatchers) do activeLobbies[lobbyId] = true end
        if next(activeLobbies) == nil then
            Wait(1500)
        else
            for lobbyId, _ in pairs(activeLobbies) do
                local state = mjReq('/state/' .. lobbyId, 'GET', nil)
                if state then
                    -- Broadcast a PERSONALIZED view per watcher. /state/:id?id=<cid>
                    -- scopes isMe + the concealed hand to that player; a shared
                    -- id-less fetch strips every hand (isMe=false everywhere),
                    -- which would blank out each seated player's own tiles.
                    -- Cache each cid's personalized view for this tick so we only
                    -- fetch once per player even if they somehow watch twice.
                    local pviewCache = {}
                    for wsrc, wlobby in pairs(mjWatchers) do
                        if wlobby == lobbyId then
                            local wcid = getCitizenId(wsrc)
                            local pview = nil
                            if wcid then
                                if pviewCache[wcid] ~= nil then
                                    pview = pviewCache[wcid]
                                else
                                    pview = mjReq('/state/' .. lobbyId .. '?id=' .. wcid, 'GET', nil)
                                    if pview then pviewCache[wcid] = pview end
                                end
                            end
                            -- CRITICAL: never fall back to the id-less `state` view here.
                            -- That view has actions=null and every hand hidden, so pushing
                            -- it would erase the player's OWN tiles AND their pung/kong/chow
                            -- buttons mid-claim-window (the "can't pung" bug). If the
                            -- personalized fetch hiccups, skip this watcher for this tick —
                            -- they keep their last good view and the next 150ms poll
                            -- refreshes them. Spectators (no cid) still get the shared view.
                            if pview then
                                TriggerClientEvent('hk-sportsbetting:client:casinoResult', wsrc, {
                                    game = "mahjong", action = "state", lobby = lobbyId, view = pview,
                                })
                            elseif not wcid then
                                TriggerClientEvent('hk-sportsbetting:client:casinoResult', wsrc, {
                                    game = "mahjong", action = "state", lobby = lobbyId, view = state,
                                })
                            end
                        end
                    end
                    -- On entering payout/washout, CLAIM settlement once and route rake.
                    local st = state.state
                    if (st == "payout" or st == "washout") and lastState[lobbyId] ~= st then
                        local settle = mjReq('/settle/' .. lobbyId .. '/claim', 'POST', nil)
                        if settle and settle.result then
                            mjSettleHand(lobbyId, settle.result)
                            for wsrc, wlobby in pairs(mjWatchers) do
                                if wlobby == lobbyId then
                                    TriggerClientEvent('hk-sportsbetting:client:casinoResult', wsrc, {
                                        game = "mahjong", action = "settled", lobby = lobbyId, result = settle.result,
                                    })
                                end
                            end
                        end
                    end
                    lastState[lobbyId] = st
                elseif lastState[lobbyId] ~= nil then
                    -- Table vanished (host left / closed): tell its watchers to bail.
                    for wsrc, wlobby in pairs(mjWatchers) do
                        if wlobby == lobbyId then
                            mjWatchers[wsrc] = nil
                            TriggerClientEvent('hk-sportsbetting:client:casinoResult', wsrc, {
                                game = "mahjong", action = "closed", lobby = lobbyId,
                            })
                        end
                    end
                    lastState[lobbyId] = nil
                    mjSettledHand[lobbyId] = nil
                end
            end
        end
    end
end)

-- Disconnect cleanup: cash the player out of any table (engine frees the seat +
-- hands it to a bot mid-hand). Credit the returned stack via DB (player is gone).
AddEventHandler('playerDropped', function()
    local src = source
    local cid = cidCache[src]
    if not cid then
        for c, b in pairs(mjSeated) do if b.src == src then cid = c break end end
    end
    mjWatchers[src] = nil
    if not cid then return end
    local seat = mjSeated[cid]
    if not seat then return end
    local res = mjReq('/disconnect', 'POST', { identifier = cid })
    local cashOut = math.floor(tonumber(res and res.cashOut) or 0)
    if cashOut > 0 then
        if seat.demo then demoAdd(cid, cashOut)
        else MySQL.update('UPDATE players SET money = JSON_SET(money, "$.cash", JSON_EXTRACT(money, "$.cash") + ?) WHERE citizenid = ?', { cashOut, cid }) end
    end
    mjSeated[cid] = nil
end)
