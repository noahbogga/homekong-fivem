local QBCore = exports['qb-core']:GetCoreObject()

local claimLock = {}
_G.claimLock = claimLock

-- All hk_steak_* tables now live in the engine's zx_wxyz_stream DB (schema owned by
-- engine db.js). No local table creation here anymore.

-- ═══════════════════════════════════════════════════════════════
-- HELPERS
-- ═══════════════════════════════════════════════════════════════

local function isWeekendBoost()
    local day = tonumber(os.date('%w'))
    return day == 0 or day == 5 or day == 6
end

local function getVipLevel(xp)
    local level = Config.VIP.levels[1]
    for _, l in ipairs(Config.VIP.levels) do
        if xp >= l.minXP then level = l end
    end
    return level
end

local function getVipLevelIndex(xp)
    local idx = 1
    for i, l in ipairs(Config.VIP.levels) do
        if xp >= l.minXP then idx = i end
    end
    return idx
end

local function getNextLevel(xp)
    for _, l in ipairs(Config.VIP.levels) do
        if xp < l.minXP then return l end
    end
    return nil
end

-- Fetch the full vip row from the engine (zx). Ensures the row + referral_code
-- exist server-side. Returns the row table, or nil if the engine is unreachable
-- (callers must treat nil as "under maintenance" and abort).
local function ensureVipRow(citizenid)
    return _G.SteakRequest('/vip/row/' .. citizenid, 'GET')
end

local function getWeekStart()
    local now = os.time()
    local wday = tonumber(os.date('%w', now))
    local daysSinceMonday = (wday == 0) and 6 or (wday - 1)
    local mondayMidnight = now - daysSinceMonday * 86400
    return os.date('%Y-%m-%d', mondayMidnight)
end

local function getMaxBetForTier(xp)
    local level = getVipLevel(xp)
    return level.maxBet or 10000
end

-- ═══════════════════════════════════════════════════════════════
-- GLOBAL BIG-WIN ANNOUNCEMENT
-- ═══════════════════════════════════════════════════════════════

-- Friendly source labels for the "won $X from <source>" line.
local BIGWIN_SOURCE_LABEL = {
    dice = "Dice", mines = "Mines", chicken = "Chicken Road", crash = "Crash",
    plinko = "Plinko", blackjack = "Blackjack", mahjong = "Mahjong",
}

local lastBigWinAt = {}  -- citizenid -> os.clock ms of last announcement (anti-spam)

-- Broadcast a global fanfare + banner for a qualifying win. `awardRes` is the
-- /vip/award response (carries tier + public nickname), so this costs no extra HTTP.
-- We announce PROFIT (payout − stake), not gross payback — the returned stake is
-- the player's own money, not winnings. For a game whose `payout` is the total
-- returned (stake + winnings, e.g. blackjack nets side bets/insurance), this is
-- the true net gain.
function AnnounceBigWin(citizenid, stake, payout, isCasino, game, awardRes)
    local cfg = Config.BigWinAnnounce
    if not cfg or not cfg.enabled then return end
    if not citizenid then return end

    payout = tonumber(payout) or 0
    stake = tonumber(stake) or 0
    local profit = payout - stake
    -- Genuine net win above the flat threshold. Refunds/void/break-even/loss
    -- (profit <= 0) never announce; the threshold is on PROFIT, not payback.
    if profit < (cfg.minPayout or 300000) then return end

    -- Per-player cooldown to avoid a rapid-fire game (plinko/crash) spamming.
    local nowMs = GetGameTimer()
    local coolMs = cfg.perPlayerCooldownMs or 0
    if coolMs > 0 and lastBigWinAt[citizenid] and (nowMs - lastBigWinAt[citizenid]) < coolMs then
        return
    end
    lastBigWinAt[citizenid] = nowMs

    -- Name: public nickname if the player opted to show one, else Anonymous Winner.
    local name = (awardRes and awardRes.displayName) or nil
    if not name or name == "" then name = "Anonymous Winner" end

    local source
    if isCasino then
        source = BIGWIN_SOURCE_LABEL[game] or "the Casino"
    else
        source = "Sports Betting"
    end

    TriggerClientEvent('hk-sportsbetting:client:bigWin', -1, {
        name = name,
        amount = math.floor(profit),
        source = source,
        tier = (awardRes and awardRes.tier) or "Bronze",
        tierId = (awardRes and awardRes.tierId) or "bronze_3",
        tierName = (awardRes and awardRes.tierName) or "Bronze III",
        tierColor = (awardRes and awardRes.tierColor) or "#cd7f32",
        durationMs = cfg.durationMs or 20000,
    })
end

-- ═══════════════════════════════════════════════════════════════
-- CORE: AddVipXP — called on every bet (casino + sports)
-- ═══════════════════════════════════════════════════════════════

-- announceStake: real stake to net against for the big-win banner, used only when
-- the XP `stake` is deliberately 0 (sports settle passes 0 so the engine doesn't
-- double-count the already-recorded wager). Defaults to `stake` when nil.
function AddVipXP(citizenid, src, isCasino, stake, payout, game, skipHouseRoute, announceStake)
    if isDemoPlayer and isDemoPlayer(citizenid) then return end
    if isCasino and not skipHouseRoute then
        -- Chip-stack games (mahjong) route the true per-hand house profit
        -- themselves (rake / bot P&L), so they pass skipHouseRoute=true to avoid
        -- double-counting here (stake/payout for those is per-player, not the take).
        local houseProfit = (stake or 0) - (payout or 0)
        if houseProfit > 0 then
            routeHouseProfit(houseProfit)  -- FiveM money routing stays local
        end
    end

    -- All the XP/rakeback/referral/race/bigwin/loss-streak/tier bookkeeping now
    -- happens atomically in the engine (zx). It returns any tier-up reward we must
    -- pay out here (money + homecoin + client toast stay FiveM-side).
    local res = _G.SteakRequest('/vip/award', 'POST', {
        identifier = citizenid, stake = stake, payout = payout,
        isCasino = isCasino and true or false, game = game, isWeekend = isWeekendBoost(),
    })
    if not res then return end  -- engine unreachable: skip bookkeeping (bet already handled)

    -- Global big-win announcement. Genuine net win only (payout > stake) above the
    -- flat threshold. res carries the winner's tier + public nickname from the same
    -- award call, so no extra HTTP is needed here.
    AnnounceBigWin(citizenid, announceStake or stake, payout, isCasino, game, res)

    if res.tierUp and res.reward then
        local reward = res.reward
        if src then
            local Player = QBCore.Functions.GetPlayer(src)
            if Player and (reward.cash or 0) > 0 then
                Player.Functions.AddMoney('cash', reward.cash, 'vip-tierup-' .. res.tierUp.id)
            end
            if (reward.homecoin or 0) > 0 then
                TriggerEvent('sky_coinsystem:server:addCoins', src, reward.homecoin)
            end
            TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, {
                game = "vip", success = true,
                message = "Tier Up! " .. res.tierUp.name .. " — +" .. tostring(reward.cash or 0) .. " cash +" .. tostring(reward.homecoin or 0) .. " HC"
            })
        else
            if (reward.cash or 0) > 0 then
                MySQL.update('UPDATE players SET money = JSON_SET(money, "$.cash", JSON_EXTRACT(money, "$.cash") + ?) WHERE citizenid = ?',
                    {reward.cash, citizenid})
            end
        end
    end
end

-- Non-blocking AddVipXP for hot casino paths (plinko rapid-fire): runs the award
-- in its own thread so the game result isn't delayed by the award HTTP round-trip.
-- The tier-up reward (if any) is still applied when the thread completes.
function AddVipXPAsync(citizenid, src, isCasino, stake, payout, game)
    CreateThread(function()
        AddVipXP(citizenid, src, isCasino, stake, payout, game)
    end)
end

-- ═══════════════════════════════════════════════════════════════
-- TAX: Apply on sports wins (returns net payout after tax)
-- ═══════════════════════════════════════════════════════════════

function ApplyBetTax(citizenid, stake, payout)
    -- Tax math + tier lookup now in the engine. On unreachable engine, fall back
    -- to no-tax (pay gross) rather than blocking a settlement — safer than denying
    -- a won bet's payout. Returns netPayout, govAmount, feeAmount.
    local res = _G.SteakRequest('/vip/tax', 'POST', {
        identifier = citizenid, stake = stake, payout = payout, isWeekend = isWeekendBoost(),
    })
    if not res then return payout, 0, 0 end
    return res.netPayout or payout, res.gov or 0, res.fee or 0
end

-- ═══════════════════════════════════════════════════════════════
-- VIP PAGE DATA
-- ═══════════════════════════════════════════════════════════════

RegisterNetEvent('hk-sportsbetting:server:getVipData', function()
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    local citizenid = Player.PlayerData.citizenid

    -- Engine computes level/xp/rakeback/claim-availability/referral in one call.
    local data = _G.SteakRequest('/vip/data/' .. citizenid, 'GET')
    if not data then return end -- engine unreachable: don't render stale data
    data.isWeekend = isWeekendBoost()
    TriggerClientEvent('hk-sportsbetting:client:vipData', src, data)
end)

-- ═══════════════════════════════════════════════════════════════
-- CLAIMS
-- ═══════════════════════════════════════════════════════════════

-- Shared claim flow: engine atomically checks eligibility + stamps the claim and
-- returns {success, cash, homecoin} (or {success=false, message}). Resource pays
-- cash/homecoin locally and refreshes the client's VIP panel from /vip/data.
local function doVipClaim(src, endpoint, reason)
    if claimLock[src] then return end
    claimLock[src] = true
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then claimLock[src] = nil return end
    local citizenid = Player.PlayerData.citizenid

    local res = _G.SteakRequest(endpoint, 'POST', { identifier = citizenid })
    if not res then
        TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, {
            game = "vip", success = false, message = "Steak is under maintenance — try again shortly"
        })
        claimLock[src] = nil
        return
    end
    if not res.success then
        TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, {
            game = "vip", success = false, message = res.message or "Nothing to claim"
        })
        claimLock[src] = nil
        return
    end

    local cash = tonumber(res.cash) or 0
    local hc = tonumber(res.homecoin) or 0
    if cash > 0 then Player.Functions.AddMoney('cash', cash, reason) end
    if hc > 0 then TriggerEvent('sky_coinsystem:server:addCoins', src, hc) end

    -- refresh panel from engine (authoritative availability + balances)
    local data = _G.SteakRequest('/vip/data/' .. citizenid, 'GET')
    if data then
        data.balance = (isDemoPlayer and isDemoPlayer(citizenid)) and (demoGetBal and demoGetBal(citizenid) or 50000000) or Player.PlayerData.money.cash
        TriggerClientEvent('hk-sportsbetting:client:vipClaimed', src, data)
    end

    local msg
    if endpoint == '/vip/claim/daily' then
        msg = "Daily bonus: $" .. cash .. " + " .. hc .. " HC"
    elseif endpoint == '/vip/claim/rakeback' then
        msg = "Claimed $" .. cash .. " in rewards"
    else
        msg = "Claimed weekly reward: $" .. cash
    end
    TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, { game = "vip", success = true, message = msg })
    claimLock[src] = nil
end

RegisterNetEvent('hk-sportsbetting:server:claimVipWeekly', function()
    doVipClaim(source, '/vip/claim/weekly', 'vip-weekly-reward')
end)

RegisterNetEvent('hk-sportsbetting:server:claimVipDaily', function()
    doVipClaim(source, '/vip/claim/daily', 'vip-daily-bonus')
end)

RegisterNetEvent('hk-sportsbetting:server:claimVipRakeback', function()
    doVipClaim(source, '/vip/claim/rakeback', 'vip-rakeback-claim')
end)

-- ═══════════════════════════════════════════════════════════════
-- LEADERBOARD (3 tabs: race, bigwins, alltime)
-- ═══════════════════════════════════════════════════════════════

RegisterNetEvent('hk-sportsbetting:server:getLeaderboard', function()
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    local citizenid = Player.PlayerData.citizenid
    -- Engine builds all three tabs (race/bigwins/alltime) + racePool with joins.
    local data = _G.SteakRequest('/leaderboard/' .. citizenid, 'GET')
    if not data then return end
    TriggerClientEvent('hk-sportsbetting:client:leaderboard', src, data)
end)

-- ═══════════════════════════════════════════════════════════════
-- MY STATS
-- ═══════════════════════════════════════════════════════════════

RegisterNetEvent('hk-sportsbetting:server:getMyStats', function()
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    local citizenid = Player.PlayerData.citizenid
    -- Engine returns vip{}+stats{}+recent sports/casino bets (incl computed maxBet).
    local data = _G.SteakRequest('/mystats/' .. citizenid, 'GET')
    if not data then return end
    TriggerClientEvent('hk-sportsbetting:client:receiveMyStats', src, data)
end)

RegisterNetEvent('hk-sportsbetting:server:clearStats', function()
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    local citizenid = Player.PlayerData.citizenid
    local res = _G.SteakRequest('/vip/clear-stats', 'POST', { identifier = citizenid })
    if res and res.success then
        TriggerClientEvent('hk-sportsbetting:client:statsCleared', src)
    end
end)

-- ═══════════════════════════════════════════════════════════════
-- SETTINGS
-- ═══════════════════════════════════════════════════════════════

RegisterNetEvent('hk-sportsbetting:server:getSettings', function()
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    local citizenid = Player.PlayerData.citizenid
    local data = _G.SteakRequest('/vip/settings/' .. citizenid, 'GET')
    if not data then return end
    TriggerClientEvent('hk-sportsbetting:client:settings', src, data)
end)

RegisterNetEvent('hk-sportsbetting:server:setNickname', function(data)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    local citizenid = Player.PlayerData.citizenid
    -- Client-input hygiene stays resource-side (zero-width / bidi-override stripping
    -- that the engine's basic sanitizer doesn't do). Engine enforces the cooldown.
    local nickname = tostring(data.nickname or ""):sub(1, 20)
    nickname = nickname:gsub("<[^>]*>", ""):gsub("[<>\"'`&;/\\%%]", "")
    nickname = nickname:gsub("[%z\1-\31\127]", ""):gsub("[\194-\244][\128-\191]+", function(c)
        local b = c:byte(1)
        if b == 0xE2 or b == 0xC2 then
            local b2 = c:byte(2) or 0
            local b3 = c:byte(3) or 0
            if b == 0xE2 and b2 == 0x80 and (b3 >= 0x8B and b3 <= 0x8F) then return "" end
            if b == 0xE2 and b2 == 0x80 and (b3 >= 0xAA and b3 <= 0xAE) then return "" end
            if b == 0xE2 and b2 == 0x81 and (b3 >= 0xA6 and b3 <= 0xA9) then return "" end
            if b == 0xC2 and b2 == 0xAD then return "" end
        end
        if b == 0xEF and c:byte(2) == 0xBB and c:byte(3) == 0xBF then return "" end
        return c
    end)

    if #nickname < 2 then
        TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, {
            game = "settings", success = false, message = "Nickname must be at least 2 characters"
        })
        return
    end

    local res = _G.SteakRequest('/vip/nickname', 'POST', { identifier = citizenid, nickname = nickname })
    if not res then
        TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, {
            game = "settings", success = false, message = "Steak is under maintenance — try again shortly"
        })
        return
    end
    if not res.success then
        TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, {
            game = "settings", success = false, message = res.message or "Could not update nickname"
        })
        return
    end
    if _G.nicknameCache then _G.nicknameCache[src] = res.nickname end
    TriggerClientEvent('hk-sportsbetting:client:settings', src, { nickname = res.nickname, showNickname = true, canChangeNick = false })
    TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, {
        game = "settings", success = true, message = "Nickname updated!"
    })
end)

RegisterNetEvent('hk-sportsbetting:server:setShowNickname', function(data)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    local citizenid = Player.PlayerData.citizenid
    local show = data.show and true or false
    local res = _G.SteakRequest('/vip/show-nickname', 'POST', { identifier = citizenid, show = show })
    if res and res.success then
        if _G.nicknameCache then _G.nicknameCache[src] = nil end
        TriggerClientEvent('hk-sportsbetting:client:settings', src, { showNickname = show })
    end
end)

RegisterNetEvent('hk-sportsbetting:server:setPersonalMaxBet', function(data)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    local citizenid = Player.PlayerData.citizenid
    local res = _G.SteakRequest('/vip/max-bet', 'POST', {
        identifier = citizenid, maxBet = tonumber(data.maxBet), minBet = Config.MinBet,
    })
    if res and res.success then
        TriggerClientEvent('hk-sportsbetting:client:settings', src, { personalMaxBet = res.personalMaxBet })
    end
end)

RegisterNetEvent('hk-sportsbetting:server:applyReferral', function(data)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    local citizenid = Player.PlayerData.citizenid
    local code = tostring(data.code or ""):upper():gsub("[^A-Z0-9]", ""):sub(1, 8)
    local res = _G.SteakRequest('/vip/referral', 'POST', { identifier = citizenid, code = code })
    if not res then
        TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, {
            game = "settings", success = false, message = "Steak is under maintenance — try again shortly"
        })
        return
    end
    if not res.success then
        TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, {
            game = "settings", success = false, message = res.message or "Could not apply referral"
        })
        return
    end
    TriggerClientEvent('hk-sportsbetting:client:referralApplied', src)
    TriggerClientEvent('hk-sportsbetting:client:casinoResult', src, {
        game = "settings", success = true, message = res.message or "Referral linked!"
    })
end)

-- ═══════════════════════════════════════════════════════════════
-- BET CEILING ENFORCEMENT (called before every bet)
-- ═══════════════════════════════════════════════════════════════

-- Returns the player's max bet, or nil if the engine is unreachable (callers
-- must treat nil as "under maintenance" and deny the bet).
function GetPlayerMaxBet(citizenid)
    local res = _G.SteakRequest('/vip/maxbet/' .. citizenid, 'GET')
    if not res then return nil end
    return tonumber(res.maxBet) or 10000
end

-- ═══════════════════════════════════════════════════════════════
-- LOSS STREAK CHECK (call after a loss to see if protection triggers)
-- ═══════════════════════════════════════════════════════════════

function CheckLossStreakProtection(citizenid, stake)
    local res = _G.SteakRequest('/vip/lossstreak-check', 'POST', { identifier = citizenid, stake = stake })
    if not res then return 0 end
    return tonumber(res.refund) or 0
end
