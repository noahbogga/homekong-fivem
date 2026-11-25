local betLock = {} -- citizenid → true while a bet is processing
_G.betLock = betLock

-- The engine sends commence times as UTC (ISO 8601 "...Z"). os.time{fields}
-- interprets its fields as the server's LOCAL time (this box is Asia/Hong_Kong,
-- UTC+8), so feeding UTC fields straight in produced an epoch 8h too early and
-- tripped the "match already started" guard for any kickoff <8h away. Add the
-- server's UTC offset back to recover the true epoch. Returns nil on no match.
local function parseCommenceToEpoch(str)
    if type(str) ~= "string" then return nil end
    -- Parse date + HH:MM first, then seconds OPTIONALLY — SharpAPI sends the
    -- no-seconds form ("2026-08-28T18:45Z") and a seconds-mandatory pattern would
    -- silently return nil, skipping the started-match guard for those events.
    local y, mo, d, h, mi = str:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+)")
    if not y then return nil end
    local s = str:match("T%d+:%d+:(%d+)") or 0
    local asLocal = os.time({ year = tonumber(y), month = tonumber(mo), day = tonumber(d),
                              hour = tonumber(h), min = tonumber(mi), sec = tonumber(s) })
    -- offset = how far the server's local clock is ahead of UTC (seconds)
    local offset = os.difftime(os.time(os.date("*t")), os.time(os.date("!*t")))
    return asLocal + offset
end

-- Acquire the per-player bet lock. Instead of rejecting a concurrent bet
-- (which dropped every-but-the-first when a betslip fires N singles at once),
-- we WAIT for the in-flight bet to finish, then take the lock. This keeps the
-- balance-check/deduct chain strictly serialized per player (no double-spend)
-- while letting a burst of singles all land. Bounded so a leaked lock can't
-- hang the handler forever.
local function acquireBetLock(citizenid)
    local waited = 0
    while betLock[citizenid] do
        Citizen.Wait(50)
        waited = waited + 50
        if waited >= 10000 then return false end -- 10s ceiling: give up
    end
    betLock[citizenid] = true
    return true
end


-- hk_sportsbets schema is now owned by the engine (db.js schema-init on
-- zx_wxyz_stream). No local table creation here anymore.

-- Validate client-sent odds against server cache (prevents inflated odds exploit)
local function validateOdds(eventId, market, selection, clientOdds)
    if not eventId or not market or not selection or not clientOdds then return false end
    local tolerance = 0.03 -- 3% tolerance for drift between cache updates
    local cache = GetOddsCache()

    -- Search all cached sports for this event
    for _, cat in ipairs(Config.SportCategories) do
        for _, sport in ipairs(cat.sports) do
            local cached = cache[sport.key]
            if cached then
                for _, ev in ipairs(cached) do
                    if ev.id == eventId then
                        local outcomes = ev.markets and ev.markets[market]
                        if not outcomes then return false end
                        for _, outcome in ipairs(outcomes) do
                            if outcome.name == selection then
                                local serverPrice = outcome.price
                                if not serverPrice or serverPrice <= 0 then return false end
                                local ratio = clientOdds / serverPrice
                                return ratio >= (1 - tolerance) and ratio <= (1 + tolerance), serverPrice
                            end
                        end
                        return false
                    end
                end
            end
        end
    end
    return false
end

RegisterNetEvent('hk-sportsbetting:server:placeBet', function(data)
    local src = source
    local stake = tonumber(data.stake) or tonumber(data.amount)
    local odds = tonumber(data.odds)

    local Player = exports['qb-core']:GetCoreObject().Functions.GetPlayer(src)
    local citizenid = Player and Player.PlayerData.citizenid or nil
    if not citizenid then return end

    -- Serialize concurrent bets from same player (betslip fires N singles at once)
    if not acquireBetLock(citizenid) then
        TriggerClientEvent('hk-sportsbetting:client:betResult', src, {
            success = false, message = "Bet already processing — try again"
        })
        return
    end

    local maxBet = GetPlayerMaxBet(citizenid)
    if not maxBet then
        betLock[citizenid] = nil
        TriggerClientEvent('hk-sportsbetting:client:betResult', src, {
            success = false, message = "Steak is under maintenance — try again shortly"
        })
        return
    end
    if not stake or not odds or stake < Config.MinBet or stake > maxBet then
        betLock[citizenid] = nil
        TriggerClientEvent('hk-sportsbetting:client:betResult', src, {
            success = false,
            message = "Invalid bet amount (min: $" .. Config.MinBet .. ", max: $" .. tostring(maxBet) .. ")"
        })
        return
    end

    stake = math.floor(stake)

    -- Validate odds against server cache
    local valid, serverPrice = validateOdds(data.eventId, data.market, data.selection, odds)
    if not valid then
        betLock[citizenid] = nil
        TriggerClientEvent('hk-sportsbetting:client:betResult', src, {
            success = false,
            message = "Odds have changed, please refresh"
        })
        return
    end
    -- Use server-verified price for payout calculation
    odds = serverPrice

    -- Reject bets on matches that have already started
    if data.commenceTime then
        local commence = nil
        if type(data.commenceTime) == "number" then
            commence = data.commenceTime
        else
            commence = parseCommenceToEpoch(data.commenceTime)
        end
        if commence and os.time() >= commence then
            betLock[citizenid] = nil
            TriggerClientEvent('hk-sportsbetting:client:betResult', src, {
                success = false, message = "Match has already started"
            })
            return
        end
    end

    local potentialWin = math.min(math.floor(stake * odds), 50000000)

    GetPlayerCash(src, function(balance)
        if balance < stake then
            betLock[citizenid] = nil
            TriggerClientEvent('hk-sportsbetting:client:betResult', src, {
                success = false,
                message = "Insufficient cash"
            })
            return
        end

        DeductCash(src, stake, function(success)
            if not success then
                betLock[citizenid] = nil
                TriggerClientEvent('hk-sportsbetting:client:betResult', src, {
                    success = false,
                    message = "Transaction failed"
                })
                return
            end

            local matchDesc = data.matchDesc or data.match or ""

            -- Persist the bet in the engine (zx_wxyz_stream). Money was already
            -- deducted above; if the engine write fails, REFUND to keep money safe.
            local resp = _G.EngineSync('/bets/place', 'POST', {
                identifier = citizenid, eventId = data.eventId, matchDesc = matchDesc,
                market = data.market, selection = data.selection, odds = odds,
                stake = stake, commenceTime = data.commenceTime or nil,
                -- ZQ-only fields for settlement matching (nil for SharpAPI bets)
                zqHomeCn = data.zqHomeCn, zqAwayCn = data.zqAwayCn,
                -- AH (ZQ), spreads (SharpAPI) and totals all carry a line in .point
                handicapLine = (data.market == 'ah' or data.market == 'spreads' or data.market == 'totals') and data.point or nil,
            })

            betLock[citizenid] = nil
            local QBCore = exports['qb-core']:GetCoreObject()
            local P = QBCore.Functions.GetPlayerByCitizenId(citizenid)
            local activeSrc = P and P.PlayerData.source or nil

            if not resp or not resp.success then
                -- refund — engine unreachable or insert failed
                if P then P.Functions.AddMoney('cash', stake, 'sports-bet-refund') end
                if activeSrc then
                    TriggerClientEvent('hk-sportsbetting:client:betResult', activeSrc, {
                        success = false, message = "Steak is under maintenance — bet refunded"
                    })
                    GetPlayerCash(activeSrc, function(newBalance)
                        TriggerClientEvent('hk-sportsbetting:client:updateBalance', activeSrc, newBalance)
                    end)
                end
                return
            end

            if activeSrc then
                TriggerClientEvent('hk-sportsbetting:client:betResult', activeSrc, {
                    success = true, message = "Bet placed!", betId = resp.betId,
                    stake = stake, potentialWin = potentialWin
                })
                GetPlayerCash(activeSrc, function(newBalance)
                    TriggerClientEvent('hk-sportsbetting:client:updateBalance', activeSrc, newBalance)
                end)
            end
            AddVipXP(citizenid, activeSrc, false, stake, 0)
        end)
    end)
end)

-- Multi bet (parlay) — legs from DIFFERENT matches, combined odds
RegisterNetEvent('hk-sportsbetting:server:placeMultiBet', function(data)
    local src = source
    local stake = tonumber(data.stake)
    local comboOdds = tonumber(data.comboOdds)
    local legs = data.legs

    if not stake or not comboOdds or not legs or #legs < 2 or #legs > 10 then
        TriggerClientEvent('hk-sportsbetting:client:betResult', src, {
            success = false, message = #legs > 10 and "Maximum 10 legs" or "Invalid multi bet"
        })
        return
    end

    local Player = exports['qb-core']:GetCoreObject().Functions.GetPlayer(src)
    local citizenid = Player and Player.PlayerData.citizenid or nil
    if not citizenid then return end

    -- Serialize concurrent bets from same player
    if not acquireBetLock(citizenid) then
        TriggerClientEvent('hk-sportsbetting:client:betResult', src, {
            success = false, message = "Bet already processing — try again"
        })
        return
    end

    stake = math.floor(stake)

    local maxBet = GetPlayerMaxBet(citizenid)
    if not maxBet then
        betLock[citizenid] = nil
        TriggerClientEvent('hk-sportsbetting:client:betResult', src, {
            success = false, message = "Steak is under maintenance — try again shortly"
        })
        return
    end
    if stake < Config.MinBet or stake > maxBet then
        betLock[citizenid] = nil
        TriggerClientEvent('hk-sportsbetting:client:betResult', src, {
            success = false, message = "Invalid bet amount (min: $" .. Config.MinBet .. ", max: $" .. tostring(maxBet) .. ")"
        })
        return
    end

    -- Validate: no duplicate event IDs (same match multi not allowed)
    local seenEvents = {}
    for _, leg in ipairs(legs) do
        if seenEvents[leg.eventId] then
            betLock[citizenid] = nil
            TriggerClientEvent('hk-sportsbetting:client:betResult', src, {
                success = false, message = "Cannot combine selections from the same match"
            })
            return
        end
        seenEvents[leg.eventId] = true
    end

    -- Recalculate combined odds server-side using VALIDATED prices
    local serverOdds = 1
    for _, leg in ipairs(legs) do
        local valid, serverPrice = validateOdds(leg.eventId, leg.market, leg.selection, tonumber(leg.odds))
        if not valid then
            betLock[citizenid] = nil
            TriggerClientEvent('hk-sportsbetting:client:betResult', src, {
                success = false, message = "Odds have changed, please refresh"
            })
            return
        end
        -- Reject if any leg's match already started
        if leg.commenceTime then
            local commence = nil
            if type(leg.commenceTime) == "number" then
                commence = leg.commenceTime
            else
                commence = parseCommenceToEpoch(leg.commenceTime)
            end
            if commence and os.time() >= commence then
                betLock[citizenid] = nil
                TriggerClientEvent('hk-sportsbetting:client:betResult', src, {
                    success = false, message = "One or more matches have already started"
                })
                return
            end
        end
        serverOdds = serverOdds * serverPrice
    end

    local potentialWin = math.min(math.floor(stake * serverOdds), 50000000)

    GetPlayerCash(src, function(balance)
        if balance < stake then
            betLock[citizenid] = nil
            TriggerClientEvent('hk-sportsbetting:client:betResult', src, {
                success = false, message = "Insufficient cash"
            })
            return
        end

        DeductCash(src, stake, function(success)
            if not success then
                betLock[citizenid] = nil
                TriggerClientEvent('hk-sportsbetting:client:betResult', src, {
                    success = false, message = "Transaction failed"
                })
                return
            end

            -- Build match description from all legs
            local descriptions = {}
            for _, leg in ipairs(legs) do
                table.insert(descriptions, leg.matchDesc .. " (" .. leg.selection .. ")")
            end
            local matchDesc = #legs .. "-Leg Multi: " .. table.concat(descriptions, " + ")
            if #matchDesc > 250 then matchDesc = matchDesc:sub(1, 247) .. "..." end

            -- Persist multi-bet in engine (zx). Refund on failure (money already taken).
            local resp = _G.EngineSync('/bets/place', 'POST', {
                identifier = citizenid, eventId = "multi_" .. os.time(), matchDesc = matchDesc,
                market = "multi", selection = #legs .. " legs", odds = serverOdds, stake = stake,
            })

            betLock[citizenid] = nil
            local QBCore = exports['qb-core']:GetCoreObject()
            local P = QBCore.Functions.GetPlayerByCitizenId(citizenid)
            local activeSrc = P and P.PlayerData.source or nil

            if not resp or not resp.success then
                if P then P.Functions.AddMoney('cash', stake, 'sports-multi-refund') end
                if activeSrc then
                    TriggerClientEvent('hk-sportsbetting:client:betResult', activeSrc, {
                        success = false, message = "Steak is under maintenance — bet refunded"
                    })
                    GetPlayerCash(activeSrc, function(newBalance)
                        TriggerClientEvent('hk-sportsbetting:client:updateBalance', activeSrc, newBalance)
                    end)
                end
                return
            end

            if activeSrc then
                TriggerClientEvent('hk-sportsbetting:client:betResult', activeSrc, {
                    success = true, message = "Multi bet placed!", betId = resp.betId,
                    stake = stake, potentialWin = potentialWin
                })
                GetPlayerCash(activeSrc, function(newBalance)
                    TriggerClientEvent('hk-sportsbetting:client:updateBalance', activeSrc, newBalance)
                end)
            end
            AddVipXP(citizenid, activeSrc, false, stake, 0)
        end)
    end)
end)

RegisterNetEvent('hk-sportsbetting:server:getBalance', function()
    local src = source
    GetPlayerCash(src, function(balance)
        TriggerClientEvent('hk-sportsbetting:client:updateBalance', src, balance)
    end)
end)

RegisterCommand('settlebet', function(src, args)
    if src ~= 0 then return end
    local betId = tonumber(args[1])
    local result = args[2]

    if not betId or not result then
        print("[hk-sportsbetting] Usage: settlebet <id> <won|lost|void>")
        return
    end

    -- Atomically settle in the engine (zx). Returns bet stake/potentialWin for tax calc.
    local settle = _G.EngineSync('/bets/settle', 'POST', { betId = betId, result = result })
    if not settle or not settle.success then
        print("[hk-sportsbetting] Bet not found, already settled, or engine unreachable")
        return
    end
    local bet = { identifier = settle.identifier, stake = settle.stake, potential_win = settle.potentialWin }

    if result == "won" then
        local QBCore = exports['qb-core']:GetCoreObject()
        local netPayout, govAmount, feeAmount = ApplyBetTax(bet.identifier, bet.stake, bet.potential_win)
        local cappedPayout = math.min(netPayout, 50000000)

        local Player = QBCore.Functions.GetPlayerByCitizenId(bet.identifier)
        if Player then
            Player.Functions.AddMoney('cash', cappedPayout, 'sports-bet-win')
            TriggerClientEvent('hk-sportsbetting:client:betSettled', Player.PlayerData.source, {
                betId = betId, result = "won", amount = cappedPayout, tax = govAmount + feeAmount
            })
        else
            MySQL.update('UPDATE players SET money = JSON_SET(money, "$.cash", JSON_EXTRACT(money, "$.cash") + ?) WHERE citizenid = ?', {cappedPayout, bet.identifier})
        end

        if govAmount > 0 then
            local whPlayer = QBCore.Functions.GetPlayerByJob('whitehouse')
            if whPlayer then
                whPlayer.Functions.AddMoney('bank', govAmount, 'sports-tax-gov')
            else
                exports['qb-banking']:AddMoney('whitehouse', govAmount, 'sports-tax-gov')
            end
        end
        if feeAmount > 0 then
            local congPlayer = QBCore.Functions.GetPlayerByJob('congress')
            if congPlayer then
                congPlayer.Functions.AddMoney('bank', feeAmount, 'sports-tax-fee')
            else
                exports['qb-banking']:AddMoney('congress', feeAmount, 'sports-tax-fee')
            end
        end

        _G.EngineSync('/bets/set-payout', 'POST', { betId = betId, payout = cappedPayout })
        -- stake=0 for XP (wager already recorded at placement); pass the real stake
        -- as announceStake so the big-win banner nets it out to true profit.
        AddVipXP(bet.identifier, Player and Player.PlayerData.source or nil, false, 0, cappedPayout, nil, nil, bet.stake)
    elseif result == "void" then
        local QBCore = exports['qb-core']:GetCoreObject()
        local Player = QBCore.Functions.GetPlayerByCitizenId(bet.identifier)
        if Player then
            Player.Functions.AddMoney('cash', bet.stake, 'sports-bet-void')
            TriggerClientEvent('hk-sportsbetting:client:betSettled', Player.PlayerData.source, {
                betId = betId, result = "void", amount = bet.stake
            })
        else
            MySQL.update('UPDATE players SET money = JSON_SET(money, "$.cash", JSON_EXTRACT(money, "$.cash") + ?) WHERE citizenid = ?', {bet.stake, bet.identifier})
        end
    elseif result == "lost" then
        local QBCore = exports['qb-core']:GetCoreObject()
        local Player = QBCore.Functions.GetPlayerByCitizenId(bet.identifier)
        if Player then
            TriggerClientEvent('hk-sportsbetting:client:betSettled', Player.PlayerData.source, {
                betId = betId, result = "lost", amount = 0
            })
        end
    end

    print("[hk-sportsbetting] Bet #" .. betId .. " settled as " .. result)
end, false)
