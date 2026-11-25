local isOpen = false
local awaitingGrant = false   -- true while we've asked the server to open and are waiting

-- IN-GAME PRIORITY: opening the in-game casino asks the server for a grant first.
-- The server denies (and we retry) if the phone has a LIVE round in progress
-- (option 1: in-game waits). On grant, the phone suspends for as long as we're open.
function OpenBettingUI()
    if isOpen or awaitingGrant then return end
    awaitingGrant = true
    TriggerServerEvent('hk-sportsbetting:server:requestIngameCasino')
end

-- Actually show the UI once the server granted the open.
local function doOpen()
    if isOpen then return end
    isOpen = true
    awaitingGrant = false
    SetNuiFocus(true, true)
    SendNUIMessage({action = "show"})
    TriggerServerEvent('hk-sportsbetting:server:getCategories')
    TriggerServerEvent('hk-sportsbetting:server:getBalance')
    TriggerServerEvent('hk-sportsbetting:server:getActiveGame')
end

-- Server answered our open request. granted -> show; denied -> a live phone round
-- is in progress, so notify and retry shortly (in-game waits for it to finish).
RegisterNetEvent('hk-sportsbetting:client:ingameCasinoGrant', function(data)
    if data and data.granted then
        doOpen()
    else
        awaitingGrant = false
        local kinds = (data and data.kinds and #data.kinds > 0) and (' (' .. table.concat(data.kinds, ', ') .. ')') or ''
        SendNUIMessage({ action = "toast", message = "Finish your phone round first" .. kinds, type = "info" })
        -- retry the open in a few seconds; the round should resolve server-side
        SetTimeout(4000, function()
            if not isOpen then OpenBettingUI() end
        end)
    end
end)

function CloseBettingUI()
    if not isOpen then return end
    isOpen = false
    awaitingGrant = false
    SetNuiFocus(false, false)
    SendNUIMessage({action = "hide"})
    -- release in-game presence so the phone can resume
    TriggerServerEvent('hk-sportsbetting:server:ingameCasinoClosed')
    TriggerServerEvent('hk-sportsbetting:server:crashLeave')
    TriggerServerEvent('hk-sportsbetting:server:bjLeave')
    TriggerServerEvent('hk-sportsbetting:server:mjLeave')
end

RegisterNUICallback('closeUI', function(_, cb)
    CloseBettingUI()
    cb('ok')
end)

RegisterNUICallback('getCategories', function(_, cb)
    TriggerServerEvent('hk-sportsbetting:server:getCategories')
    cb('ok')
end)

RegisterNUICallback('getBalance', function(_, cb)
    TriggerServerEvent('hk-sportsbetting:server:getBalance')
    cb('ok')
end)

RegisterNUICallback('getMaintenance', function(_, cb)
    TriggerServerEvent('hk-sportsbetting:server:getMaintenance')
    cb('ok')
end)

RegisterNUICallback('getSportEvents', function(data, cb)
    TriggerServerEvent('hk-sportsbetting:server:getSportEvents', data.categoryId, data.leagueKey, data.limit)
    cb('ok')
end)

RegisterNUICallback('getFeatured', function(data, cb)
    TriggerServerEvent('hk-sportsbetting:server:getFeatured', data and data.categoryId)
    cb('ok')
end)

RegisterNUICallback('getSportOdds', function(data, cb)
    TriggerServerEvent('hk-sportsbetting:server:getSportOdds', data.sportKey)
    cb('ok')
end)

RegisterNUICallback('refreshSport', function(data, cb)
    TriggerServerEvent('hk-sportsbetting:server:refreshSport', data.sportKey)
    cb('ok')
end)

RegisterNUICallback('placeBet', function(data, cb)
    if data.type == 'multi' then
        TriggerServerEvent('hk-sportsbetting:server:placeMultiBet', data)
    else
        TriggerServerEvent('hk-sportsbetting:server:placeBet', data)
    end
    cb('ok')
end)

RegisterNUICallback('getMyStats', function(_, cb)
    TriggerServerEvent('hk-sportsbetting:server:getMyStats')
    cb('ok')
end)

RegisterNUICallback('clearStats', function(_, cb)
    TriggerServerEvent('hk-sportsbetting:server:clearStats')
    cb('ok')
end)

RegisterNUICallback('getActiveGame', function(_, cb)
    TriggerServerEvent('hk-sportsbetting:server:getActiveGame')
    cb('ok')
end)

RegisterNUICallback('diceCollect', function(_, cb)
    TriggerServerEvent('hk-sportsbetting:server:diceCollect')
    cb('ok')
end)

RegisterNUICallback('getFairness', function(_, cb)
    TriggerServerEvent('hk-sportsbetting:server:getFairness')
    cb('ok')
end)

RegisterNUICallback('rotateSeed', function(_, cb)
    TriggerServerEvent('hk-sportsbetting:server:rotateSeed')
    cb('ok')
end)

RegisterNUICallback('setClientSeed', function(data, cb)
    TriggerServerEvent('hk-sportsbetting:server:setClientSeed', data)
    cb('ok')
end)

RegisterNUICallback('getLeaderboard', function(_, cb)
    TriggerServerEvent('hk-sportsbetting:server:getLeaderboard')
    cb('ok')
end)

RegisterNUICallback('getHomeData', function(_, cb)
    TriggerServerEvent('hk-sportsbetting:server:getHomeData')
    cb('ok')
end)

RegisterNUICallback('getGameHistory', function(data, cb)
    TriggerServerEvent('hk-sportsbetting:server:getGameHistory', data)
    cb('ok')
end)

RegisterNUICallback('getSettings', function(_, cb)
    TriggerServerEvent('hk-sportsbetting:server:getSettings')
    cb('ok')
end)

RegisterNUICallback('setNickname', function(data, cb)
    TriggerServerEvent('hk-sportsbetting:server:setNickname', data)
    cb('ok')
end)

RegisterNUICallback('setShowNickname', function(data, cb)
    TriggerServerEvent('hk-sportsbetting:server:setShowNickname', data)
    cb('ok')
end)

RegisterNUICallback('setPersonalMaxBet', function(data, cb)
    TriggerServerEvent('hk-sportsbetting:server:setPersonalMaxBet', data)
    cb('ok')
end)

RegisterNUICallback('applyReferral', function(data, cb)
    TriggerServerEvent('hk-sportsbetting:server:applyReferral', data)
    cb('ok')
end)

-- VIP page callbacks
RegisterNUICallback('getVipData', function(_, cb)
    TriggerServerEvent('hk-sportsbetting:server:getVipData')
    cb('ok')
end)

RegisterNUICallback('claimVipWeekly', function(_, cb)
    TriggerServerEvent('hk-sportsbetting:server:claimVipWeekly')
    cb('ok')
end)

RegisterNUICallback('claimVipDaily', function(_, cb)
    TriggerServerEvent('hk-sportsbetting:server:claimVipDaily')
    cb('ok')
end)

RegisterNUICallback('claimVipRakeback', function(_, cb)
    TriggerServerEvent('hk-sportsbetting:server:claimVipRakeback')
    cb('ok')
end)

-- Unified casino bet callback — routes to correct server event
RegisterNUICallback('casinoBet', function(data, cb)
    local game = data.game
    local action = data.action

    if game == 'dice' then
        TriggerServerEvent('hk-sportsbetting:server:diceBet', {
            stake = data.amount,
            target = data.target,
            isOver = data.mode == 'over',
        })
    elseif game == 'mines' then
        if action == 'start' then
            TriggerServerEvent('hk-sportsbetting:server:minesStart', {
                stake = data.amount,
                mines = data.mines,
            })
        elseif action == 'reveal' then
            TriggerServerEvent('hk-sportsbetting:server:minesReveal', { tile = data.index })
        elseif action == 'cashout' then
            TriggerServerEvent('hk-sportsbetting:server:minesCashout')
        end
    elseif game == 'chicken' then
        if action == 'start' then
            TriggerServerEvent('hk-sportsbetting:server:chickenStart', { stake = data.amount, cols = data.cols or 4 })
        elseif action == 'pick' then
            TriggerServerEvent('hk-sportsbetting:server:chickenStep', { lane = data.col + 1 })
        elseif action == 'cashout' then
            TriggerServerEvent('hk-sportsbetting:server:chickenCashout')
        end
    elseif game == 'blackjack' then
        if action == 'lobby' then
            TriggerServerEvent('hk-sportsbetting:server:bjLobby')
        elseif action == 'join' then
            TriggerServerEvent('hk-sportsbetting:server:bjJoin', { room = data.room })
        elseif action == 'leave' then
            TriggerServerEvent('hk-sportsbetting:server:bjLeave')
        elseif action == 'sit' then
            TriggerServerEvent('hk-sportsbetting:server:bjSit', {
                room = data.room, seat = data.seat, stake = data.stake or data.amount,
                pairs = data.pairs, p3 = data.p3, bust = data.bust, hot3 = data.hot3,
            })
        elseif action == 'behind' then
            TriggerServerEvent('hk-sportsbetting:server:bjBehind', {
                room = data.room, seat = data.seat, stake = data.stake or data.amount,
                pairs = data.pairs, p3 = data.p3, bust = data.bust, hot3 = data.hot3,
            })
        elseif action == 'insure' then
            TriggerServerEvent('hk-sportsbetting:server:bjInsure', { stake = data.stake or data.amount })
        elseif action == 'act' then
            TriggerServerEvent('hk-sportsbetting:server:bjAction', { action = data.move })
        end
    elseif game == 'crash' then
        if action == 'join' then
            TriggerServerEvent('hk-sportsbetting:server:crashJoin')
        elseif action == 'leave' then
            TriggerServerEvent('hk-sportsbetting:server:crashLeave')
        elseif action == 'bet' then
            TriggerServerEvent('hk-sportsbetting:server:crashBet', {
                stake = data.amount,
                autoCashout = data.autoCashout,
            })
        elseif action == 'cashout' then
            TriggerServerEvent('hk-sportsbetting:server:crashCashout', { multiplier = data.multiplier })
        elseif action == 'updateAuto' then
            TriggerServerEvent('hk-sportsbetting:server:crashUpdateAuto', { autoCashout = data.autoCashout })
        end
    elseif game == 'plinko' then
        TriggerServerEvent('hk-sportsbetting:server:plinkoBet', {
            stake = data.amount,
            risk = data.risk,
            rows = data.rows or 12,
        })
    elseif game == 'plinkoClaim' then
        TriggerServerEvent('hk-sportsbetting:server:plinkoClaim', { betId = data.betId })
    elseif game == 'mahjong' then
        if action == 'styles' then
            TriggerServerEvent('hk-sportsbetting:server:mjStyles')
        elseif action == 'lobbies' then
            TriggerServerEvent('hk-sportsbetting:server:mjLobbies')
        elseif action == 'create' then
            TriggerServerEvent('hk-sportsbetting:server:mjCreate', {
                style = data.style, baseBet = data.baseBet, name = data.name,
                password = data.password, fillBots = data.fillBots,
            })
        elseif action == 'join' then
            TriggerServerEvent('hk-sportsbetting:server:mjJoin', {
                lobby = data.lobby, password = data.password, seat = data.seat,
            })
        elseif action == 'watch' then
            TriggerServerEvent('hk-sportsbetting:server:mjWatch', { lobby = data.lobby })
        elseif action == 'leave' then
            TriggerServerEvent('hk-sportsbetting:server:mjLeave')
        elseif action == 'start' then
            TriggerServerEvent('hk-sportsbetting:server:mjStart')
        elseif action == 'act' then
            TriggerServerEvent('hk-sportsbetting:server:mjAction', {
                action = data.move, tile = data.tile, claim = data.claim, meldTiles = data.meldTiles,
            })
        end
    end

    cb('ok')
end)

-- Server → Client → NUI events
RegisterNetEvent('hk-sportsbetting:client:maintenance', function(active)
    SendNUIMessage({action = "maintenance", active = active and true or false})
end)

-- Global big-win announcement. Fired to ALL clients (-1). The NUI overlay is
-- always mounted (independent of the casino being open), so this shows for every
-- player regardless of whether they're at the casino. Audio + 20s themed banner.
RegisterNetEvent('hk-sportsbetting:client:bigWin', function(data)
    SendNUIMessage({
        action = "bigWin",
        name = data.name,
        amount = data.amount,
        source = data.source,
        tier = data.tier,
        tierId = data.tierId,
        tierName = data.tierName,
        tierColor = data.tierColor,
        durationMs = data.durationMs,
    })
end)

RegisterNetEvent('hk-sportsbetting:client:paused', function(data)
    SendNUIMessage({action = "paused", reason = data.reason, expiresAt = data.expiresAt, remainingMs = data.remainingMs})
end)

RegisterNetEvent('hk-sportsbetting:client:receiveCategories', function(categories, casinoConfig)
    SendNUIMessage({action = "categories", categories = categories, casino = casinoConfig})
end)

RegisterNetEvent('hk-sportsbetting:client:receiveSportEvents', function(categoryId, leagueKey, events, leagueCounts)
    SendNUIMessage({action = "sportEvents", categoryId = categoryId, leagueKey = leagueKey, events = events, leagueCounts = leagueCounts})
end)

RegisterNetEvent('hk-sportsbetting:client:receiveFeatured', function(featured)
    SendNUIMessage({action = "featured", featured = featured})
end)

RegisterNetEvent('hk-sportsbetting:client:receiveSportOdds', function(sportKey, odds)
    SendNUIMessage({action = "sportOdds", sportKey = sportKey, events = odds})
end)

RegisterNetEvent('hk-sportsbetting:client:updateBalance', function(balance)
    SendNUIMessage({action = "balance", balance = balance})
end)

RegisterNetEvent('hk-sportsbetting:client:receiveMyStats', function(data)
    local s = data.stats or {}
    local totalWagered = (s.totalWageredSports or 0) + (s.totalWageredCasino or 0)
    local totalWon = (s.totalWonSports or 0) + (s.totalWonCasino or 0)
    local totalBets = (s.sportsBetsCount or 0) + (s.casinoBetsCount or 0)

    -- Calculate actual win counts from bet history
    local sportsWins = 0
    for _, b in ipairs(data.sportsBets or {}) do
        if b.status == 'won' then sportsWins = sportsWins + 1 end
    end
    local casinoWins = 0
    local bestMultiplier = 0
    local totalCasinoStake = 0
    for _, b in ipairs(data.casinoBets or {}) do
        local isWin = b.won == 1 or b.won == true or tonumber(b.won) == 1
        if isWin then casinoWins = casinoWins + 1 end
        if tonumber(b.multiplier or 0) > bestMultiplier then bestMultiplier = tonumber(b.multiplier) end
        totalCasinoStake = totalCasinoStake + (tonumber(b.stake) or 0)
    end
    local totalWins = sportsWins + casinoWins
    local winRate = totalBets > 0 and math.floor((totalWins / totalBets) * 100) or 0
    local avgBet = totalBets > 0 and math.floor(totalWagered / totalBets) or 0
    local totalLosses = math.max(0, totalBets - totalWins)

    -- Current win streak: walk newest-first through combined recent history and
    -- count consecutive wins from the top. Honest (derived from real bets), and
    -- gives players a positive momentum figure instead of a loss tally.
    local recent = {}
    for _, b in ipairs(data.casinoBets or {}) do
        recent[#recent + 1] = { won = (b.won == 1 or b.won == true or tonumber(b.won) == 1), t = tonumber(b.played_at) or 0 }
    end
    for _, b in ipairs(data.sportsBets or {}) do
        if b.status == 'won' or b.status == 'lost' then
            recent[#recent + 1] = { won = (b.status == 'won'), t = tonumber(b.placed_at) or 0 }
        end
    end
    table.sort(recent, function(a, c) return a.t > c.t end)
    local winStreak = 0
    for _, r in ipairs(recent) do
        if r.won then winStreak = winStreak + 1 else break end
    end

    local sportsBets = {}
    for _, b in ipairs(data.sportsBets or {}) do
        sportsBets[#sportsBets + 1] = {
            match = b.match_desc,
            selection = b.selection,
            odds = b.odds,
            amount = b.stake,
            status = b.status,
            date = b.placed_at,
            commenceTime = b.commence_time,
            payout = b.payout or 0,
        }
    end

    local casinoBets = {}
    for _, b in ipairs(data.casinoBets or {}) do
        local isWin = b.won == 1 or b.won == true or tonumber(b.won) == 1
        casinoBets[#casinoBets + 1] = {
            game = b.game:sub(1,1):upper() .. b.game:sub(2),
            amount = b.stake,
            payout = b.payout,
            won = isWin,
            multiplier = b.multiplier,
            date = b.played_at,
        }
    end

    SendNUIMessage({
        action = "myStats",
        vip = data.vip,
        -- Headline stats (no profit/net figure by design)
        totalBets = totalBets,
        totalWins = totalWins,
        totalLosses = totalLosses,
        totalWagered = totalWagered,
        -- Positive framing
        xp = (data.vip and data.vip.xp) or s.xp or 0,
        rakebackEarned = s.rakebackBalance or 0,
        referralEarned = s.referralEarned or 0,
        biggestWin = s.biggestWin or 0,
        bestMultiplier = bestMultiplier,
        winStreak = winStreak,
        -- Retained for the bet lists / secondary display
        winRate = tostring(winRate),
        avgBet = avgBet,
        sportsBetCount = s.sportsBetsCount or 0,
        casinoBetCount = s.casinoBetsCount or 0,
        sportsBets = sportsBets,
        casinoBets = casinoBets,
    })
end)

RegisterNetEvent('hk-sportsbetting:client:statsCleared', function()
    TriggerServerEvent('hk-sportsbetting:server:getMyStats')
end)

RegisterNetEvent('hk-sportsbetting:client:betResult', function(result)
    SendNUIMessage({action = "betResult", success = result.success, message = result.message, betId = result.betId, stake = result.stake, potentialWin = result.potentialWin, balance = result.balance})
    TriggerServerEvent('hk-sportsbetting:server:getBalance')
end)

RegisterNetEvent('hk-sportsbetting:client:betSettled', function(data)
    SendNUIMessage({action = "betSettled", result = data.result, amount = data.amount, betId = data.betId, tax = data.tax})
    TriggerServerEvent('hk-sportsbetting:server:getBalance')
end)

RegisterNetEvent('hk-sportsbetting:client:activeGame', function(data)
    SendNUIMessage({action = "activeGame", data = data})
end)

RegisterNetEvent('hk-sportsbetting:client:fairnessData', function(data)
    SendNUIMessage({action = "fairnessData", data = data})
end)

RegisterNetEvent('hk-sportsbetting:client:seedRotated', function(data)
    SendNUIMessage({action = "seedRotated", data = data})
end)

RegisterNetEvent('hk-sportsbetting:client:gameHistory', function(data)
    SendNUIMessage({action = "gameHistory", data = data})
end)

RegisterNetEvent('hk-sportsbetting:client:homeData', function(data)
    SendNUIMessage({action = "homeData", data = data})
end)

RegisterNetEvent('hk-sportsbetting:client:leaderboard', function(data)
    SendNUIMessage({action = "leaderboard", data = data})
end)

RegisterNetEvent('hk-sportsbetting:client:settings', function(data)
    SendNUIMessage({action = "settings", data = data})
end)

RegisterNetEvent('hk-sportsbetting:client:referralApplied', function()
    SendNUIMessage({action = "referralApplied"})
end)

RegisterNetEvent('hk-sportsbetting:client:vipData', function(data)
    SendNUIMessage({action = "vipData", data = data})
end)

RegisterNetEvent('hk-sportsbetting:client:vipClaimed', function(data)
    SendNUIMessage({action = "vipData", data = data})
    if data.balance then SendNUIMessage({action = "balance", balance = data.balance}) end
end)

RegisterNetEvent('hk-sportsbetting:client:casinoResult', function(data)
    local game = data.game
    if game == 'dice' then
        if data.success == false then
            SendNUIMessage({action = "diceResult", won = false, roll = nil, payout = 0, balance = data.balance})
        else
            SendNUIMessage({action = "diceResult", won = data.won, roll = data.roll, payout = data.payout, balance = data.balance})
        end
    elseif game == 'mines' then
        if not data.success and data.success ~= nil and data.message then
            SendNUIMessage({action = "toast", message = data.message, type = "error"})
            if data.action == 'start' then
                SendNUIMessage({action = "minesStartFailed"})
            end
        elseif data.action == 'started' then
            SendNUIMessage({action = "minesStarted"})
            SendNUIMessage({action = "balance", balance = data.balance})
        elseif data.action == 'exploded' then
            SendNUIMessage({action = "minesResult", hit = true, index = data.tile, mines = data.mines})
        elseif data.action == 'safe' then
            SendNUIMessage({action = "minesResult", hit = false, index = data.tile, multiplier = data.multiplier})
        elseif data.action == 'cashout' then
            SendNUIMessage({action = "minesCashout", mines = data.mines, payout = data.payout, balance = data.balance})
        end
    elseif game == 'chicken' then
        if not data.success and data.success ~= nil and data.message then
            SendNUIMessage({action = "toast", message = data.message, type = "error"})
            if data.action == 'start' then
                SendNUIMessage({action = "chickenStartFailed"})
            end
        elseif data.action == 'started' then
            SendNUIMessage({action = "balance", balance = data.balance})
            SendNUIMessage({action = "chickenStarted", cols = data.cols or 4})
        elseif data.action == 'dead' then
            local hazards0 = {}
            if data.field then
                for k, v in pairs(data.field) do
                    if type(v) == 'table' then
                        hazards0[k - 1] = { pos = v.pos - 1, type = v.type or 'bone' }
                    else
                        hazards0[k - 1] = { pos = v - 1, type = 'bone' }
                    end
                end
            end
            SendNUIMessage({action = "chickenResult", hit = true, row = data.row - 1, col = data.lane - 1, hazardPos = (data.hazardPos or data.bonePos or 1) - 1, hazardType = data.hazardType or 'bone', hazards = hazards0})
        elseif data.action == 'safe' then
            SendNUIMessage({action = "chickenResult", hit = false, row = data.row - 1, col = data.lane - 1, multiplier = data.multiplier, gift = data.gift, hazardType = data.hazardType or 'bone'})
        elseif data.action == 'cashout' then
            local hazards0 = {}
            if data.field then
                for k, v in pairs(data.field) do
                    if type(v) == 'table' then
                        hazards0[k - 1] = { pos = v.pos - 1, type = v.type or 'bone' }
                    else
                        hazards0[k - 1] = { pos = v - 1, type = 'bone' }
                    end
                end
            end
            SendNUIMessage({action = "chickenCashout", hazards = hazards0, payout = data.payout, balance = data.balance})
        end
    elseif game == 'crash' then
        if data.action == 'sync' then
            SendNUIMessage({action = "crashSync", state = data.state, countdown = data.countdown, crashPoint = data.crashPoint, elapsed = data.elapsed, betList = data.betList, hasBet = data.hasBet, cashedOut = data.cashedOut, cashoutMultiplier = data.cashoutMultiplier})
        elseif data.action == 'waiting' then
            SendNUIMessage({action = "crashWaiting", countdown = data.countdown, betList = data.betList})
        elseif data.action == 'started' then
            SendNUIMessage({action = "crashStart", crashPoint = data.crashPoint, betList = data.betList, elapsed = data.elapsed or 0})
        elseif data.action == 'betPlaced' then
            SendNUIMessage({action = "crashBetPlaced", betList = data.betList, isMine = data.isMine})
            if data.balance then SendNUIMessage({action = "balance", balance = data.balance}) end
        elseif data.action == 'betListUpdate' then
            SendNUIMessage({action = "crashBetListUpdate", betList = data.betList})
        elseif data.action == 'cashout' then
            SendNUIMessage({action = "crashCashout", multiplier = data.multiplier, payout = data.payout})
            if data.balance then SendNUIMessage({action = "balance", balance = data.balance}) end
        elseif data.action == 'playerCashout' then
            SendNUIMessage({action = "crashPlayerCashout", betList = data.betList})
        elseif data.action == 'busted' then
            SendNUIMessage({action = "crashBusted", crashPoint = data.crashPoint, betList = data.betList})
        end
    elseif game == 'blackjack' then
        -- Lobby snapshot (room list + live seat counts) for the picker.
        if data.action == 'lobby' then
            SendNUIMessage({ action = "blackjack", bjAction = "lobby", rooms = data.rooms })
            return
        end
        -- The engine view/result objects pass straight through; the React table
        -- reads them directly. action names: sync/state/seated/behindPlaced/
        -- insured/acted/settled. Errors fall through to the toast net below.
        if data.action then
            SendNUIMessage({
                action = "blackjack",
                bjAction = data.action,
                room = data.room,
                seat = data.seat,
                view = data.view,
                result = data.result,
                message = data.message,
            })
            -- Seat freed for not betting: surface a heads-up toast too.
            if data.action == 'kicked' and data.message then
                SendNUIMessage({action = "toast", message = data.message, type = "info"})
            end
        end
    elseif game == 'plinko' then
        if data.action == 'claimed' then
            SendNUIMessage({action = "balance", balance = data.balance})
        elseif data.success == false then
            -- Error (macro, insufficient cash, etc.) — don't spawn a ball
        else
            SendNUIMessage({action = "plinkoResult", betId = data.betId, bucket = data.bucket, multiplier = data.multiplier, payout = data.payout, path = data.path, stake = data.stake})
            if data.balance then SendNUIMessage({action = "balance", balance = data.balance}) end
        end
    elseif game == 'mahjong' then
        -- Style list + lobby list are their own action payloads; the rest are
        -- view/result pass-throughs the React table reads directly. action names:
        -- styles/lobbies/created/seated/sync/state/started/acted/settled/left/closed.
        if data.action then
            SendNUIMessage({
                action = "mahjong",
                mjAction = data.action,
                lobby = data.lobby,
                seat = data.seat,
                view = data.view,
                result = data.result,
                styles = data.styles,
                lobbies = data.lobbies,
                baseBetMin = data.baseBetMin,
                baseBetMax = data.baseBetMax,
                buyInUnits = data.buyInUnits,
                maxLobbies = data.maxLobbies,
                max = data.max,
                buyIn = data.buyIn,
                noRake = data.noRake,
                cashOut = data.cashOut,
                message = data.message,
            })
        end
    end

    if not data.success and data.message and game ~= 'mines' and game ~= 'chicken' then
        SendNUIMessage({action = "toast", message = data.message, type = "error"})
        TriggerServerEvent('hk-sportsbetting:server:getBalance')
    elseif not data.success and data.message and (game == 'mines' or game == 'chicken') then
        TriggerServerEvent('hk-sportsbetting:server:getBalance')
        TriggerServerEvent('hk-sportsbetting:server:getActiveGame')
    end

    -- Safety-net: refresh balance from server after any win/payout event
    if data.action == 'cashout' or data.action == 'claimed' or (game == 'dice' and data.won) or (game == 'crash' and data.action == 'cashout') then
        SetTimeout(500, function()
            TriggerServerEvent('hk-sportsbetting:server:getBalance')
        end)
    end
end)
