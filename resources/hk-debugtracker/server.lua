-- hk-debugtracker 2.0 :: HOMEKONG performance/telemetry tracker
-- Registers passive handlers on sensitive server net events. FiveM invokes
-- every handler bound to an event name, so these run ALONGSIDE the real
-- resource handlers without replacing them. Per-source counters detect the
-- rapid-fire spam pattern seen on 2026-07-26.
-- (internal: forensic net-event logger + flood detector)

-- Lazy QBCore proxy: this resource is ensured EARLY (before qb-core) on purpose
-- so its watchers attach before players connect. Resolving the core object at
-- load time crashed the whole chunk ("No such export GetCoreObject in qb-core")
-- and silently killed the tracker. This proxy resolves it on first real use at
-- runtime, by which point qb-core is up.
local _qbcore
local QBCore = setmetatable({}, { __index = function(_, k)
    if not _qbcore then _qbcore = exports['qb-core']:GetCoreObject() end
    return _qbcore[k]
end })

-- ident cache: src -> "name | citizenid | license"
local function identOf(src)
    if not src or src == 0 then return 'server/console' end
    local ok, player = pcall(function() return QBCore.Functions.GetPlayer(src) end)
    local name = GetPlayerName(src) or '?'
    local cid, lic = 'n/a', 'n/a'
    if ok and player then
        cid = player.PlayerData.citizenid or 'n/a'
        lic = player.PlayerData.license or 'n/a'
    end
    return ('%s [src:%s cid:%s %s]'):format(name, src, cid, lic)
end

-- ---- flood detector state ----
local counters = {}   -- src -> { count, windowStart, lastAlert }

local function noteEvent(src)
    if not src or src == 0 then return end
    local now = GetGameTimer()
    local c = counters[src]
    if not c or (now - c.windowStart) > Config.Flood.Window then
        counters[src] = { count = 1, windowStart = now, lastAlert = c and c.lastAlert or 0 }
        return
    end
    c.count = c.count + 1
    if c.count > Config.Flood.Count and (now - c.lastAlert) > Config.Flood.Cooldown then
        c.lastAlert = now
        local who = identOf(src)
        local msg = ('[hk-perf][FLOOD] %s fired %d watched events in %dms')
            :format(who, c.count, now - c.windowStart)
        print('^1' .. msg .. '^7')
        floodAlert(who, c.count, now - c.windowStart)
    end
end

-- ---- DB sink (best-effort; table auto-created) ----
local dbReady = false
local function initDB()
    if not Config.LogToDatabase then return end
    exports.oxmysql:query([[
        CREATE TABLE IF NOT EXISTS hk_event_log (
            id BIGINT AUTO_INCREMENT PRIMARY KEY,
            event VARCHAR(96), src INT, citizenid VARCHAR(32),
            license VARCHAR(96), name VARCHAR(64), args LONGTEXT,
            created TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            INDEX idx_cid (citizenid), INDEX idx_event (event), INDEX idx_created (created)
        )]], {}, function() dbReady = true end)
end

local function persist(eventName, src, args)
    if not (Config.LogToDatabase and dbReady) then return end
    local cid, lic, nm = 'n/a', 'n/a', GetPlayerName(src) or '?'
    local ok, player = pcall(function() return QBCore.Functions.GetPlayer(src) end)
    if ok and player then cid = player.PlayerData.citizenid; lic = player.PlayerData.license end
    local encoded = ''
    pcall(function() encoded = json.encode(args) end)
    if #encoded > 8000 then encoded = encoded:sub(1, 8000) .. '...(truncated)' end
    exports.oxmysql:insert(
        'INSERT INTO hk_event_log (event, src, citizenid, license, name, args) VALUES (?, ?, ?, ?, ?, ?)',
        { eventName, src, cid, lic, nm, encoded })
end

-- ---- attach a watcher to each configured event ----
local function watch(eventName)
    RegisterNetEvent(eventName, function(...)
        local src = source
        noteEvent(src)
        if Config.LogToConsole then
            local args = { ... }
            local preview = ''
            pcall(function() preview = json.encode(args) end)
            if #preview > 300 then preview = preview:sub(1, 300) .. '...' end
            print(('[hk-perf] %s <- %s args=%s'):format(eventName, identOf(src), preview))
        end
        persist(eventName, src, { ... })
    end)
end

CreateThread(function()
    if not Config.Enabled then
        print('[hk-perf] disabled via config'); return
    end
    initDB()
    for _, ev in ipairs(Config.WatchedEvents) do watch(ev) end
    print(('[hk-perf] 2.0 online — watching %d sensitive events (flood>%d/%dms)')
        :format(#Config.WatchedEvents, Config.Flood.Count, Config.Flood.Window))
end)

-- clean up counters on disconnect
AddEventHandler('playerDropped', function()
    counters[source] = nil
end)

-- ============================================================
-- shared Discord webhook helper (embed)
-- ============================================================
-- format an integer with thousands separators: 1234567 -> "1,234,567"
function comma(n)
    n = math.floor(tonumber(n) or 0)
    local s, neg = tostring(math.abs(n)), n < 0
    while true do
        local x, k = s:gsub('^(%d+)(%d%d%d)', '%1,%2')
        if k == 0 then break end
        s = x
    end
    return (neg and '-' or '') .. s
end

function postEmbed(title, description, color)
    if not Config.FloodWebhook or Config.FloodWebhook == '' then return end
    PerformHttpRequest(Config.FloodWebhook, function() end, 'POST', json.encode({
        username = 'hk-debugtracker',
        embeds = { {
            title = title,
            description = description,
            color = color or 3447003,
            footer = { text = 'hk-debugtracker • ' .. os.date('!%Y-%m-%d %H:%M:%SZ') },
        } },
    }), { ['Content-Type'] = 'application/json' })
end

function floodAlert(who, count, ms)
    postEmbed('⚠️ Flood detected',
        ('**%s**\nfired **%d** watched events in **%dms**'):format(who, count, ms),
        15158332)
end

-- ============================================================
-- auto-prune: drop rows older than RetentionDays
-- ============================================================
local function pruneOnce()
    if not (Config.Prune.Enabled and Config.LogToDatabase) then return end
    exports.oxmysql:query(
        'DELETE FROM hk_event_log WHERE created < (NOW() - INTERVAL ? DAY)',
        { Config.Prune.RetentionDays },
        function(affected)
            local n = (type(affected) == 'table' and affected.affectedRows) or affected or 0
            if n and n > 0 then
                print(('[hk-perf] prune: removed %d rows older than %dd'):format(n, Config.Prune.RetentionDays))
            end
        end)
end

CreateThread(function()
    if not Config.Prune.Enabled then return end
    Wait(15000)                       -- let DB init settle
    pruneOnce()
    while true do
        Wait(Config.Prune.IntervalHours * 3600000)
        pruneOnce()
    end
end)

-- ============================================================
-- daily summary -> Discord webhook
-- ============================================================
local function postDailySummary()
    if not (Config.LogToDatabase) then return end
    exports.oxmysql:query([[
        SELECT name, citizenid, COUNT(*) n
        FROM hk_event_log
        WHERE created >= (NOW() - INTERVAL 1 DAY)
        GROUP BY citizenid, name ORDER BY n DESC LIMIT ?]],
        { Config.Summary.TopN },
        function(rows)
            exports.oxmysql:query('SELECT COUNT(*) total FROM hk_event_log WHERE created >= (NOW() - INTERVAL 1 DAY)', {},
            function(tot)
                local total = (tot and tot[1] and tot[1].total) or 0
                local lines = {}
                if rows and #rows > 0 then
                    for i, r in ipairs(rows) do
                        lines[#lines+1] = ('`%2d.` **%s** (%s) — %d'):format(i, r.name or '?', r.citizenid or '?', r.n)
                    end
                else
                    lines[1] = '_no events in the last 24h_'
                end
                postEmbed(('📊 Daily summary — %d events / 24h'):format(total),
                    table.concat(lines, '\n'), 3066993)
                if Config.Summary.Betting then postBettingSummary() end
            end)
        end)
end

-- hk-sportsbetting 24h money trace: stakes in vs payouts out (house P&L)
function postBettingSummary()
    -- payout stored is NET (after tax). tax (gov+fee) is skimmed from profit and
    -- routed to whitehouse/congress — a separate redistribution, not house income.
    -- We estimate tax as gross(potential_win) - net(payout) on won bets.
    exports.oxmysql:query([[
        SELECT
          COUNT(*) bets,
          COALESCE(SUM(stake),0) staked,
          COALESCE(SUM(CASE WHEN status IN ('won','lost') THEN stake ELSE 0 END),0) settled_stake,
          COALESCE(SUM(CASE WHEN status='won' THEN payout ELSE 0 END),0) paid,
          COALESCE(SUM(CASE WHEN status='won' THEN GREATEST(potential_win - payout,0) ELSE 0 END),0) tax,
          SUM(status='active') active,
          SUM(status='won')    won,
          SUM(status='lost')   lost,
          SUM(status='void')   voided
        FROM hk_sportsbets
        WHERE placed_at >= (NOW() - INTERVAL 1 DAY)]], {},
    function(s)
        s = s and s[1] or {}
        local staked, settled, paid, tax = s.staked or 0, s.settled_stake or 0, s.paid or 0, s.tax or 0
        -- house P&L on SETTLED bets only: stakes kept minus net payouts.
        -- active bets excluded (undecided); void bets are money-neutral (stake returned).
        local house = settled - paid
        local edge = (settled > 0) and (house / settled * 100) or 0
        local desc = ('**Bets:** %d  (✅ %d won / ❌ %d lost / ⏳ %d active / ↩️ %d void)\n')
            :format(s.bets or 0, s.won or 0, s.lost or 0, s.active or 0, s.voided or 0)
            .. ('**Total staked:** $%s\n**Settled stake:** $%s\n**Paid out (net):** $%s\n'):format(comma(staked), comma(settled), comma(paid))
            .. ('**Tax → gov/congress:** $%s\n**House P&L:** $%s  (edge %.1f%% on settled)')
            :format(comma(tax), comma(house), edge)
        postEmbed('🎲 Sportsbetting — 24h money trace', desc,
            house >= 0 and 3066993 or 15158332)
    end)
end

CreateThread(function()
    if not Config.Summary.Enabled then return end
    local lastDay = -1
    while true do
        local h = tonumber(os.date('!%H'))
        local yday = tonumber(os.date('!%j'))
        if h == Config.Summary.HourUTC and yday ~= lastDay then
            lastDay = yday
            postDailySummary()
        end
        Wait(300000)   -- check every 5 min
    end
end)

-- ============================================================
-- /hktrace <playerId|citizenid> [limit]  (ACE gated)
-- ============================================================
RegisterCommand(Config.Trace.Command, function(src, args)
    -- permission: console (src 0) always allowed; players need the ACE
    if src ~= 0 and not IsPlayerAceAllowed(src, Config.Trace.AcePerm) then
        TriggerClientEvent('chat:addMessage', src, { args = { 'hk-perf', 'no permission' } })
        return
    end
    local target = args[1]
    if not target then
        local reply = 'usage: /' .. Config.Trace.Command .. ' <playerId|citizenid> [limit]'
        if src == 0 then print(reply) else TriggerClientEvent('chat:addMessage', src, { args = { 'hk-perf', reply } }) end
        return
    end
    -- optional trailing 'all' = include the 60-day archive too
    local includeArchive = false
    for i = 2, #args do if tostring(args[i]):lower() == 'all' then includeArchive = true end end
    local limit = math.min(tonumber(args[2]) or Config.Trace.DefaultLimit, Config.Trace.MaxLimit)

    -- resolve a numeric player id to citizenid; otherwise treat as citizenid
    local cid = target
    if tostring(target):match('^%d+$') then
        local p = QBCore.Functions.GetPlayer(tonumber(target))
        if p then cid = p.PlayerData.citizenid end
    end

    -- primary source: rich hk_player_activity (the "what has this player done" log).
    -- with 'all', UNION the archive so history back to 60d shows too.
    local q
    if includeArchive then
        q = [[SELECT category, action, LEFT(detail,140) detail, created FROM (
                SELECT category, action, detail, created FROM hk_player_activity WHERE citizenid = ?
                UNION ALL
                SELECT category, action, detail, created FROM hk_player_activity_archive WHERE citizenid = ?
              ) t ORDER BY created DESC LIMIT ?]]
    else
        q = 'SELECT category, action, LEFT(detail,140) detail, created FROM hk_player_activity WHERE citizenid = ? ORDER BY id DESC LIMIT ?'
    end
    local params = includeArchive and { cid, cid, limit } or { cid, limit }

    exports.oxmysql:query(q, params, function(rows)
        local header = ('[hk-perf] trace %s%s — %d rows'):format(cid, includeArchive and ' (+archive)' or '', rows and #rows or 0)
        if src == 0 then
            print(header)
            for _, r in ipairs(rows or {}) do
                print(('  %s | %-10s %-16s | %s'):format(r.created, r.category or '?', r.action or '', r.detail or ''))
            end
        else
            TriggerClientEvent('chat:addMessage', src, { args = { 'hk-perf', header } })
            for _, r in ipairs(rows or {}) do
                TriggerClientEvent('chat:addMessage', src, { args = {
                    ('%s/%s'):format(r.category or '?', r.action or ''),
                    tostring(r.created) .. '  ' .. tostring(r.detail or '') } })
            end
        end
    end)
end, false)
