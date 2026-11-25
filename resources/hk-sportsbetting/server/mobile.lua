-- mobile.lua — MONEY-AUTHORITY fulfillment for the web/PWA mirror.
--
-- The engine (.247) holds an escrow WALLET for web players and queues the only
-- two money-authority crossings: LOAD (game cash -> wallet) and CASHOUT
-- (wallet -> game cash). This relay is the ONLY thing that may touch the game
-- `players` table, so it polls /mobile/pending, moves game cash (online via
-- QBCore, offline via a guarded direct players-table write — the same offline
-- pattern processPendingPayouts uses), then acks the outcome.
--
-- SAFETY: for a LOAD we DEBIT first and only ack ok=true if the debit succeeded;
-- the engine credits the wallet only on ok=true. For a CASHOUT the engine has
-- already debited the wallet, so we CREDIT game cash and ack; on ok=false the
-- engine refunds the wallet. Every claimed move is acked exactly once.

local POLL_MS = 4000
local MOVE_CAP = 50000000

-- Debit game cash by `amount` for citizenid. Returns true only if the money was
-- actually removed (sufficient funds). Online -> QBCore RemoveMoney; offline ->
-- conditional UPDATE that only touches the row when cash >= amount.
local function debitGameCash(citizenid, amount, cb)
    local QBCore = exports['qb-core']:GetCoreObject()
    local Player = QBCore.Functions.GetPlayerByCitizenId(citizenid)
    if Player then
        local cash = Player.PlayerData.money.cash or 0
        if cash < amount then cb(false) return end
        local ok = Player.Functions.RemoveMoney('cash', amount, 'mobile-wallet-load')
        if ok ~= false then
            TriggerClientEvent('hk-sportsbetting:client:updateBalance', Player.PlayerData.source, Player.PlayerData.money.cash)
        end
        cb(ok ~= false)
        return
    end
    -- Offline: only debit if the stored cash covers it (atomic guard in SQL).
    MySQL.update(
        'UPDATE players SET money = JSON_SET(money, "$.cash", CAST(JSON_EXTRACT(money, "$.cash") AS SIGNED) - ?) WHERE citizenid = ? AND CAST(JSON_EXTRACT(money, "$.cash") AS SIGNED) >= ?',
        { amount, citizenid, amount },
        function(affected)
            cb((affected or 0) > 0)
        end)
end

-- Credit game cash by `amount`. Always succeeds (money owed to the player).
local function creditGameCash(citizenid, amount, cb)
    local QBCore = exports['qb-core']:GetCoreObject()
    local Player = QBCore.Functions.GetPlayerByCitizenId(citizenid)
    if Player then
        Player.Functions.AddMoney('cash', amount, 'mobile-wallet-cashout')
        TriggerClientEvent('hk-sportsbetting:client:updateBalance', Player.PlayerData.source, Player.PlayerData.money.cash)
        cb(true)
        return
    end
    MySQL.update(
        'UPDATE players SET money = JSON_SET(money, "$.cash", CAST(JSON_EXTRACT(money, "$.cash") AS UNSIGNED) + ?) WHERE citizenid = ?',
        { amount, citizenid },
        function(affected)
            cb((affected or 0) > 0)  -- false only if no such character row
        end)
end

-- Fulfill one claimed move, then ack the engine.
local function fulfill(move)
    local id = move.id
    local cid = move.identifier
    local amount = math.floor(tonumber(move.amount) or 0)
    if not id or not cid or amount <= 0 or amount > MOVE_CAP then
        _G.EngineSync('/mobile/ack', 'POST', { id = id, ok = false, reason = 'invalid_move' })
        return
    end

    if move.kind == 'load' then
        debitGameCash(cid, amount, function(ok)
            _G.EngineSync('/mobile/ack', 'POST', {
                id = id, ok = ok, reason = ok and 'loaded' or 'insufficient_cash' })
        end)
    elseif move.kind == 'cashout' then
        creditGameCash(cid, amount, function(ok)
            _G.EngineSync('/mobile/ack', 'POST', {
                id = id, ok = ok, reason = ok and 'cashed_out' or 'no_character' })
        end)
    else
        _G.EngineSync('/mobile/ack', 'POST', { id = id, ok = false, reason = 'unknown_kind' })
    end
end

-- Poll loop. /mobile/pending atomically flips pending->claimed engine-side and
-- returns only rows this poll won, so two servers/polls can't double-fulfill.
CreateThread(function()
    Wait(12000)  -- let QBCore + engine settle after boot
    while true do
        local ok, err = pcall(function()
            local res = _G.EngineSync('/mobile/pending', 'GET')
            if res and res.items and #res.items > 0 then
                for _, move in ipairs(res.items) do
                    fulfill(move)
                end
            end
        end)
        if not ok then print('[hk-sportsbetting] mobile poll error: ' .. tostring(err)) end
        Wait(POLL_MS)
    end
end)

print('[hk-sportsbetting] mobile wallet fulfillment loop started')

-- ═══════════════════════════════════════════════════════════════════
-- REAL-CASH MIRROR (Phase 1). Push the player's REAL in-game cash to the engine
-- so the web/PWA app shows one synced number. READ-ONLY reflection: this never
-- moves money, it only tells the engine what the current cash is. The engine may
-- never read the game `players` table itself, so the relay is the only source.
-- ═══════════════════════════════════════════════════════════════════

-- Fire-and-forget push (non-blocking): the mirror is display-only, so a dropped
-- push just gets corrected by the next money change or the periodic sweep.
local function pushMirror(citizenid, cash)
    if not citizenid then return end
    _G.EngineRequest('/mobile/mirror', function() end, 'POST', {
        identifier = citizenid,
        cash = math.floor(tonumber(cash) or 0),
    })
end

-- Push a live player's current cash by source.
local function pushMirrorForSource(src)
    if not src or src == 0 then return end
    local Player = exports['qb-core']:GetCoreObject().Functions.GetPlayer(src)
    if not Player then return end
    pushMirror(Player.PlayerData.citizenid, Player.PlayerData.money.cash or 0)
end

-- Initial push when a character loads in.
AddEventHandler('QBCore:Server:PlayerLoaded', function(Player)
    if Player and Player.PlayerData then
        pushMirror(Player.PlayerData.citizenid, Player.PlayerData.money.cash or 0)
    end
end)

-- Push on EVERY cash change, whatever the source (bet, store, salary, our own
-- load/cashout). moneytype 'cash' only — bank isn't the web-play balance.
AddEventHandler('QBCore:Server:OnMoneyChange', function(src, moneytype, amount, action, reason)
    if moneytype ~= 'cash' then return end
    -- defer a tick so PlayerData.money.cash reflects the completed change
    SetTimeout(0, function() pushMirrorForSource(src) end)
end)

-- Periodic sweep: refresh every online player's mirror so offline-edited or
-- missed changes converge. Cheap (reads in-memory PlayerData, no SQL).
CreateThread(function()
    Wait(15000)
    while true do
        local players = exports['qb-core']:GetCoreObject().Functions.GetQBPlayers()
        for _, Player in pairs(players or {}) do
            if Player and Player.PlayerData then
                pushMirror(Player.PlayerData.citizenid, Player.PlayerData.money.cash or 0)
            end
        end
        Wait(60000)
    end
end)

print('[hk-sportsbetting] real-cash mirror push active')

-- ═══════════════════════════════════════════════════════════════════
-- IN-GAME PRIORITY (inverts the old web-priority mutex). The in-game casino
-- client is the AUTHORITY: while it has the Steak UI open it publishes presence to
-- the engine, and the player's web/PWA session SUSPENDS until it closes. The
-- in-game client has reliable lifecycle events (open/close/disconnect); a phone tab
-- can sleep silently, so in-game wins. Only one client plays at a time.
--
-- Opening in-game WAITS if the phone has a LIVE round (option 1): the engine holds
-- crash/mines/chicken/blackjack/mahjong round state even when the phone app is
-- closed, so we ask /mobile/roundcheck first and defer the open until it clears.
-- ═══════════════════════════════════════════════════════════════════

-- Which citizenids currently have the casino open in-game (for the heartbeat).
local openCasino = {}

-- Publish in-game casino presence to the engine (active 1 on open, 0 on close).
-- Fire-and-forget; the engine refreshes ingame_seen_at and a stale timestamp
-- self-releases so a crash never traps the phone suspended.
local function pushIngamePresence(citizenid, active)
    if not citizenid then return end
    _G.EngineRequest('/mobile/ingame', function() end, 'POST',
        { identifier = citizenid, active = active and 1 or 0 })
end

-- Client requests to open the in-game casino. We resolve the caller's citizenid
-- server-side (a client can't open on another player's behalf), then ask the engine
-- whether they have a LIVE phone round. If so -> deny with the round kinds so the
-- client shows "finish your phone round first" and retries. Otherwise mark in-game
-- active (suspends the phone) and grant the open. Fail-OPEN: an engine hiccup grants
-- the open (better to let them play in-game than trap them out).
RegisterNetEvent('hk-sportsbetting:server:requestIngameCasino', function()
    local src = source
    local Player = exports['qb-core']:GetCoreObject().Functions.GetPlayer(src)
    local citizenid = Player and Player.PlayerData.citizenid or nil
    if not citizenid then
        TriggerClientEvent('hk-sportsbetting:client:ingameCasinoGrant', src, { granted = true })
        return
    end
    local rc = _G.EngineSync('/mobile/roundcheck?identifier=' .. citizenid, 'GET')
    if rc and rc.liveRound == true then
        TriggerClientEvent('hk-sportsbetting:client:ingameCasinoGrant', src,
            { granted = false, kinds = rc.kinds or {} })
        return
    end
    openCasino[citizenid] = true
    pushIngamePresence(citizenid, true)
    TriggerClientEvent('hk-sportsbetting:client:ingameCasinoGrant', src, { granted = true })
end)

-- Client closed the in-game casino UI -> release presence so the phone can resume.
RegisterNetEvent('hk-sportsbetting:server:ingameCasinoClosed', function()
    local src = source
    local Player = exports['qb-core']:GetCoreObject().Functions.GetPlayer(src)
    local citizenid = Player and Player.PlayerData.citizenid or nil
    if not citizenid then return end
    openCasino[citizenid] = nil
    pushIngamePresence(citizenid, false)
end)

-- Safety net: on disconnect, clear presence so a crash/quit never leaves the phone
-- stuck suspended (the engine's stale window would also catch it after ~30s).
AddEventHandler('playerDropped', function()
    local src = source
    local Player = exports['qb-core']:GetCoreObject().Functions.GetPlayer(src)
    local citizenid = Player and Player.PlayerData.citizenid or nil
    if not citizenid then return end
    if openCasino[citizenid] then
        openCasino[citizenid] = nil
        pushIngamePresence(citizenid, false)
    end
end)

-- Heartbeat: refresh ingame presence for everyone with the casino open, so the
-- engine's stale window doesn't expire mid-session (only a real crash/close clears).
CreateThread(function()
    while true do
        Wait(10000)
        for citizenid in pairs(openCasino) do
            pushIngamePresence(citizenid, true)
        end
    end
end)

print('[hk-sportsbetting] in-game priority (casino suspends web) active')

-- ═══════════════════════════════════════════════════════════════════
-- REAL-CASH WRITE PIPELINE (Phase 3). The engine calls applyCash to move REAL
-- game cash for web/PWA bets and settlements, and WAITS for confirm. This relay is
-- the ONLY thing that may touch the game `players` table. Guaranteed-sync +
-- exactly-once via an idempotency key logged on the GAME DB.
--
-- SECURITY: money-editing endpoint on the public FiveM port. Guarded by BOTH a
-- source-IP allowlist (engine host only) AND a shared secret (constant-time).
-- ═══════════════════════════════════════════════════════════════════

-- Idempotency + audit log on the GAME DB (same DB as players; the engine may never
-- touch it, so the ledger of real-cash edits lives here with the money).
CreateThread(function()
    MySQL.query([[
        CREATE TABLE IF NOT EXISTS hk_mobile_cash_log (
            idem_key     VARCHAR(80) PRIMARY KEY,
            citizenid    VARCHAR(64) NOT NULL,
            delta        BIGINT NOT NULL,
            reason       VARCHAR(64),
            ok           TINYINT NOT NULL DEFAULT 0,
            new_cash     BIGINT,
            created_at   TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            INDEX idx_cid (citizenid)
        ) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci
    ]], {})
end)

-- constant-time-ish string compare (avoid early-exit timing oracle on the secret)
local function secretEqual(a, b)
    if type(a) ~= 'string' or type(b) ~= 'string' then return false end
    if #a ~= #b then return false end
    local diff = 0
    for i = 1, #a do
        diff = diff | (string.byte(a, i) ~ string.byte(b, i))
    end
    return diff == 0
end

-- Read a player's current cash by citizenid (online PlayerData, else stored JSON).
local function readCash(citizenid, cb)
    local Player = exports['qb-core']:GetCoreObject().Functions.GetPlayerByCitizenId(citizenid)
    if Player then cb(Player.PlayerData.money.cash or 0) return end
    MySQL.scalar('SELECT CAST(JSON_EXTRACT(money, "$.cash") AS SIGNED) FROM players WHERE citizenid = ?',
        { citizenid }, function(v) cb(tonumber(v) or 0) end)
end

-- Apply a signed cash delta for citizenid. delta<0 debits (must have funds),
-- delta>0 credits. Returns cb(ok, newCash). Online -> QBCore; offline -> guarded SQL.
local function applyCashDelta(citizenid, delta, reason, cb)
    local QBCore = exports['qb-core']:GetCoreObject()
    local Player = QBCore.Functions.GetPlayerByCitizenId(citizenid)
    if delta < 0 then
        local need = -delta
        if Player then
            if (Player.PlayerData.money.cash or 0) < need then cb(false, Player.PlayerData.money.cash or 0) return end
            local ok = Player.Functions.RemoveMoney('cash', need, reason or 'mobile-bet')
            local nc = Player.PlayerData.money.cash or 0
            if ok ~= false then
                TriggerClientEvent('hk-sportsbetting:client:updateBalance', Player.PlayerData.source, nc)
            end
            cb(ok ~= false, nc)
            return
        end
        -- offline: atomic guard so an offline debit can never overdraw
        MySQL.update('UPDATE players SET money = JSON_SET(money, "$.cash", CAST(JSON_EXTRACT(money, "$.cash") AS SIGNED) - ?) WHERE citizenid = ? AND CAST(JSON_EXTRACT(money, "$.cash") AS SIGNED) >= ?',
            { need, citizenid, need },
            function(affected)
                if (affected or 0) > 0 then readCash(citizenid, function(nc) cb(true, nc) end)
                else readCash(citizenid, function(nc) cb(false, nc) end) end
            end)
    else
        if Player then
            Player.Functions.AddMoney('cash', delta, reason or 'mobile-win')
            local nc = Player.PlayerData.money.cash or 0
            TriggerClientEvent('hk-sportsbetting:client:updateBalance', Player.PlayerData.source, nc)
            cb(true, nc)
            return
        end
        MySQL.update('UPDATE players SET money = JSON_SET(money, "$.cash", CAST(JSON_EXTRACT(money, "$.cash") AS SIGNED) + ?) WHERE citizenid = ?',
            { delta, citizenid },
            function(affected)
                if (affected or 0) > 0 then readCash(citizenid, function(nc) cb(true, nc) end)
                else cb(false, 0) end  -- no such character row
            end)
    end
end

local function jsonResp(res, code, tbl)
    res.writeHead(code, { ['Content-Type'] = 'application/json' })
    res.send(json.encode(tbl))
end

SetHttpHandler(function(req, res)
    -- Two money-adjacent routes; everything else 404 (don't advertise surface).
    --   POST /applyCash    — move REAL game cash (the only money-authority write)
    --   POST /refreshCash  — READ-ONLY: re-read a player's real cash and push the
    --                        engine mirror. Fixes stale display when cash changed
    --                        out of band (e.g. an admin edits the DB directly) with
    --                        the player never connected to FiveM.
    local isApply = (req.path == '/applyCash' and req.method == 'POST')
    local isRefresh = (req.path == '/refreshCash' and req.method == 'POST')
    if not (isApply or isRefresh) then
        res.writeHead(404); res.send('not found'); return
    end
    -- source-IP allowlist. This is the real lock; secret is backup.
    -- Normalise: drop trailing :port, and an IPv4-mapped-IPv6 "::ffff:" prefix
    -- (FiveM's HTTP server sometimes reports peers in that form).
    local addr = tostring(req.address or ''):gsub(':%d+$', ''):gsub('^::ffff:', '')
    if not (ServerConfig.MobileCash and ServerConfig.MobileCash.allowedIPs[addr]) then
        jsonResp(res, 403, { ok = false, error = 'forbidden' }); return
    end
    if not secretEqual(req.headers['x-cash-secret'] or '', ServerConfig.MobileCash.secret or '') then
        jsonResp(res, 401, { ok = false, error = 'unauthorized' }); return
    end

    -- READ-ONLY refresh: read real cash (online PlayerData or offline players JSON)
    -- and reflect it into the engine mirror. Never moves money.
    if isRefresh then
        req.setDataHandler(function(body)
            local ok, b = pcall(json.decode, body)
            if not ok or type(b) ~= 'table' then jsonResp(res, 400, { ok = false, error = 'bad_body' }) return end
            local citizenid = tostring(b.identifier or '')
            if citizenid == '' then jsonResp(res, 400, { ok = false, error = 'bad_fields' }) return end
            readCash(citizenid, function(cash)
                pushMirror(citizenid, cash)
                jsonResp(res, 200, { ok = true, cash = math.floor(tonumber(cash) or 0) })
            end)
        end)
        return
    end

    req.setDataHandler(function(body)
        local ok, b = pcall(json.decode, body)
        if not ok or type(b) ~= 'table' then jsonResp(res, 400, { ok = false, error = 'bad_body' }) return end
        local citizenid = tostring(b.identifier or '')
        local delta = math.floor(tonumber(b.delta) or 0)
        local reason = b.reason and tostring(b.reason):sub(1, 64) or 'mobile'
        local idem = tostring(b.idempotencyKey or '')
        if citizenid == '' or idem == '' or delta == 0 then
            jsonResp(res, 400, { ok = false, error = 'bad_fields' }); return
        end
        if math.abs(delta) > MOVE_CAP then jsonResp(res, 400, { ok = false, error = 'over_cap' }) return end

        -- Idempotency: if we've already processed this key, replay the stored result.
        MySQL.query('SELECT ok, new_cash FROM hk_mobile_cash_log WHERE idem_key = ?', { idem }, function(rows)
            if rows and rows[1] then
                jsonResp(res, 200, { ok = rows[1].ok == 1, newCash = tonumber(rows[1].new_cash) or 0, replay = true })
                return
            end
            applyCashDelta(citizenid, delta, reason, function(applied, newCash)
                -- record outcome (best-effort; INSERT IGNORE guards a race on the key)
                MySQL.insert('INSERT IGNORE INTO hk_mobile_cash_log (idem_key, citizenid, delta, reason, ok, new_cash) VALUES (?, ?, ?, ?, ?, ?)',
                    { idem, citizenid, delta, reason, applied and 1 or 0, newCash })
                -- keep the engine mirror in step immediately
                if applied then pushMirror(citizenid, newCash) end
                jsonResp(res, 200, { ok = applied, newCash = newCash,
                    error = applied and nil or (delta < 0 and 'insufficient_cash' or 'no_character') })
            end)
        end)
    end)
end)

print('[hk-sportsbetting] real-cash write pipeline (applyCash) active')
