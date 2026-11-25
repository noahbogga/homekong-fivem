local oddsCache = {}
local refreshCooldown = {}

local ENGINE_URL = ServerConfig.Engine.url
local ENGINE_AUTH = ServerConfig.Engine.authToken

-- Build whitelist of valid sport keys from config
local validSportKeys = {}
for _, cat in ipairs(Config.SportCategories) do
    for _, sport in ipairs(cat.sports) do
        validSportKeys[sport.key] = true
    end
end

local function engineRequest(endpoint, cb, method, body)
    method = method or "GET"
    local headers = {
        ["x-auth-token"] = ENGINE_AUTH,
        ["Content-Type"] = "application/json",
    }
    local payload = ""
    if body then payload = json.encode(body) end

    PerformHttpRequest(ENGINE_URL .. endpoint, function(status, respBody, respHeaders)
        if status >= 200 and status < 300 and respBody then
            local ok, data = pcall(json.decode, respBody)
            if ok then
                cb(data)
                return
            end
        end
        cb(nil)
    end, method, payload, headers)
end

-- Expose globally for other server scripts
_G.EngineRequest = engineRequest
_G.GetOddsCache = function() return oddsCache end

-- ── Betting-DB (zx_wxyz_stream) persistence API ───────────────────────────
-- All betting/casino/vip/fair PERSISTENCE now lives in the engine's zx_wxyz_stream
-- DB, reached via /steak/* endpoints. Money (players) is still written locally.
-- SteakRequest = synchronous call (safe inside already-async contexts). Returns
-- decoded body, or nil on any failure (timeout/non-2xx/parse) — callers MUST treat
-- nil as "engine unreachable" and DENY the action (no money moves).
-- Generic synchronous engine call (raw endpoint, no prefix). Returns decoded
-- body or nil on any failure. Safe inside already-async contexts.
local function engineSync(endpoint, method, body)
    local result, done = nil, false
    engineRequest(endpoint, function(data)
        result = data
        done = true
    end, method or "POST", body)
    local timeout = 0
    while not done and timeout < 5000 do
        Wait(50)
        timeout = timeout + 50
    end
    return result
end
_G.EngineSync = engineSync

-- Betting-DB persistence call — prefixes /steak. nil return = engine unreachable
-- (caller MUST deny the action; no money moves).
_G.SteakRequest = function(endpoint, method, body)
    return engineSync("/steak" .. endpoint, method, body)
end

-- Fire-and-forget /steak POST (non-blocking) — for after-the-fact bookkeeping
-- like recording a settled casino bet, where we don't need to wait for the write
-- and the money has already moved. Replaces the old fire-and-forget MySQL.insert.
_G.SteakPost = function(endpoint, body)
    engineRequest("/steak" .. endpoint, function() end, "POST", body)
end

-- Lightweight engine reachability flag, polled for the NUI maintenance overlay.
-- true = engine answered health-lite recently; false = DENY betting/casino and
-- show the "house is closed" overlay. On every state flip we broadcast to clients.
_G.EngineReachable = false
CreateThread(function()
    while true do
        engineRequest("/steak/health-lite", function(data)
            local ok = (data ~= nil and data.ok == true)
            if ok ~= _G.EngineReachable then
                _G.EngineReachable = ok
                -- flip: push maintenance overlay state to everyone (active = not reachable)
                TriggerClientEvent('hk-sportsbetting:client:maintenance', -1, not ok)
            end
            -- Admin clicked "Sync names" on the panel: engine flags it here, we backfill.
            if data and data.syncIdentities and _G.BackfillIdentities then
                print('[hk-sportsbetting] admin-requested identity sync — backfilling')
                pcall(_G.BackfillIdentities)
            end
        end)
        Wait(_G.EngineReachable and 15000 or 5000)
    end
end)

-- Per-client maintenance status request (on UI open)
RegisterNetEvent('hk-sportsbetting:server:getMaintenance', function()
    TriggerClientEvent('hk-sportsbetting:client:maintenance', source, not _G.EngineReachable)
end)

-- ── Identity push ──────────────────────────────────────────────────────────
-- The admin panel reads the isolated betting DB (zx_wxyz_stream), which has no
-- access to the game `players` table. Rather than give the engine game-DB creds,
-- we push each online player's identity (character name / job / cash-bank) from
-- live QBCore PlayerData to the engine's /steak/identity endpoint. Slow cadence —
-- these fields change rarely, so every ~6h (plus once shortly after boot) is plenty.
-- Fire-and-forget: if the engine is down we just skip; next cycle catches up.
local IDENTITY_PUSH_INTERVAL = 6 * 60 * 60 * 1000 -- 6 hours (online players)
local IDENTITY_BACKFILL_INTERVAL = 24 * 60 * 60 * 1000 -- 24 hours (everyone from DB)

local function pushIdentities()
    local QBCore = exports['qb-core']:GetCoreObject()
    local players = QBCore.Functions.GetQBPlayers()
    local batch = {}
    for _, Player in pairs(players) do
        local pd = Player and Player.PlayerData
        if pd and pd.citizenid then
            local ci = pd.charinfo or {}
            local nameParts = {}
            if ci.firstname then nameParts[#nameParts + 1] = ci.firstname end
            if ci.lastname then nameParts[#nameParts + 1] = ci.lastname end
            local charName = #nameParts > 0 and table.concat(nameParts, ' ') or nil
            local job = pd.job or {}
            local grade = job.grade or {}
            local money = pd.money or {}
            batch[#batch + 1] = {
                identifier = pd.citizenid,
                char_name  = charName,
                cid        = pd.cid and tostring(pd.cid) or nil,
                job        = job.label or job.name or nil,
                job_grade  = grade.name or nil,
                cash       = money.cash or nil,
                bank       = money.bank or nil,
            }
        end
    end
    if #batch > 0 then
        _G.SteakPost('/identity', { players = batch })
    end
end
_G.PushIdentities = pushIdentities

-- Backfill EVERY character (online or not) from the game `players` table so the
-- admin panel can name anyone who has ever wagered — not just whoever happens to
-- be connected. This resource lives on the game VM, so it CAN read `players`
-- (the engine cannot). Runs on demand and once after boot. Pushed in chunks to
-- avoid a giant single POST. charinfo is JSON in the players table.
local function backfillIdentities(cb)
    MySQL.query('SELECT citizenid, cid, charinfo, job FROM players', {}, function(rows)
        if not rows or #rows == 0 then
            if cb then cb(0) end
            return
        end
        local batch, sent = {}, 0
        local function flush()
            if #batch > 0 then
                _G.SteakPost('/identity', { players = batch })
                sent = sent + #batch
                batch = {}
            end
        end
        for _, row in ipairs(rows) do
            local ci = row.charinfo
            if type(ci) == 'string' then
                local ok, decoded = pcall(json.decode, ci)
                ci = ok and decoded or {}
            end
            ci = ci or {}
            local nameParts = {}
            if ci.firstname then nameParts[#nameParts + 1] = ci.firstname end
            if ci.lastname then nameParts[#nameParts + 1] = ci.lastname end
            local charName = #nameParts > 0 and table.concat(nameParts, ' ') or nil
            local jobData = row.job
            if type(jobData) == 'string' then
                local ok, decoded = pcall(json.decode, jobData)
                jobData = ok and decoded or {}
            end
            jobData = jobData or {}
            batch[#batch + 1] = {
                identifier = row.citizenid,
                char_name  = charName,
                cid        = row.cid and tostring(row.cid) or nil,
                job        = jobData.label or jobData.name or nil,
                job_grade  = jobData.grade and (jobData.grade.name or jobData.grade.label) or nil,
            }
            if #batch >= 100 then flush() end
        end
        flush()
        print(('[hk-sportsbetting] identity backfill pushed %d characters'):format(sent))
        if cb then cb(sent) end
    end)
end
_G.BackfillIdentities = backfillIdentities

CreateThread(function()
    -- Online players get fresh cash/bank every 6h.
    Wait(60000)
    while true do
        pcall(pushIdentities)
        Wait(IDENTITY_PUSH_INTERVAL)
    end
end)

CreateThread(function()
    -- Full DB backfill so EVERY character (incl. brand-new players who joined
    -- since boot) gets a name on the admin panel. Once ~90s after boot, then
    -- daily. Separate thread so its slow cadence doesn't gate the 6h online push.
    Wait(90000)
    while true do
        pcall(backfillIdentities)
        Wait(IDENTITY_BACKFILL_INTERVAL)
    end
end)

-- Console/admin on-demand push (server console: hk_pushidentity). Handy for the
-- panel admin to refresh names immediately instead of waiting for the 6h cycle.
-- Pushes online players (live cash/bank) then backfills everyone else from DB.
RegisterCommand('hk_pushidentity', function(source)
    if source ~= 0 then return end -- server console only
    pushIdentities()
    backfillIdentities()
    print('[hk-sportsbetting] identity push + backfill triggered')
end, true)

-- Fetch odds from Docker engine (which handles proxy + key rotation)
local function fetchSportFromEngine(sportKey)
    local done = false
    engineRequest("/odds/sports/" .. sportKey, function(data)
        if data then
            oddsCache[sportKey] = data
            print("[hk-sportsbetting] Cached " .. #data .. " events for " .. sportKey)
        end
        done = true
    end)

    local timeout = 0
    while not done and timeout < 15000 do
        Wait(100)
        timeout = timeout + 100
    end
    return oddsCache[sportKey] or {}
end

-- Get all sport keys grouped by priority
local function getAllSportKeys()
    local priority = {}
    local normal = {}
    for _, cat in ipairs(Config.SportCategories) do
        local isPriority = (cat.id == "soccer")
        for _, sport in ipairs(cat.sports) do
            if isPriority then
                table.insert(priority, sport.key)
            else
                table.insert(normal, sport.key)
            end
        end
    end
    return priority, normal
end

-- Server-side fetch loop — pulls from Docker engine cache
CreateThread(function()
    Wait(5000)
    print("[hk-sportsbetting] Starting odds fetch via engine...")

    local priorityKeys, normalKeys = getAllSportKeys()

    -- Initial fetch
    for _, key in ipairs(priorityKeys) do
        fetchSportFromEngine(key)
        Wait(1000)
    end
    for _, key in ipairs(normalKeys) do
        fetchSportFromEngine(key)
        Wait(1500)
    end

    print("[hk-sportsbetting] Initial fetch complete.")

    -- Ongoing: refresh from engine every 10min (engine handles external API timing)
    while true do
        Wait(Config.FetchInterval.priority * 1000)
        for _, key in ipairs(priorityKeys) do
            fetchSportFromEngine(key)
            Wait(1000)
        end
        for _, key in ipairs(normalKeys) do
            fetchSportFromEngine(key)
            Wait(1500)
        end
    end
end)

-- Deliver settled sports-bet payouts. Bets are now settled + stored in the engine
-- (zx); the engine returns pending (won/void, payout>0, paid_out=0). We atomically
-- CLAIM them engine-side (flips paid_out 0->1, returns only ids we won the race
-- for) and pay money locally ONLY for claimed ids — so no double-pay across polls.
local function processPendingPayouts(logPrefix)
    local pending = _G.EngineSync('/players/payouts/pending', 'GET')
    if not pending or #pending == 0 then
        if logPrefix then print(logPrefix .. " no pending payouts") end
        return
    end
    -- atomic claim
    local ids = {}
    for _, b in ipairs(pending) do ids[#ids + 1] = b.id end
    local claimRes = _G.EngineSync('/players/payouts/claim', 'POST', { betIds = ids })
    if not claimRes or not claimRes.claimed then return end
    local claimedSet = {}
    for _, id in ipairs(claimRes.claimed) do claimedSet[id] = true end

    local QBCore = exports['qb-core']:GetCoreObject()
    local paid = 0
    for _, bet in ipairs(pending) do
        if claimedSet[bet.id] then
            local cappedPayout = math.min(tonumber(bet.payout) or 0, 50000000)
            if cappedPayout > 0 then
                local Player = QBCore.Functions.GetPlayerByCitizenId(bet.identifier)
                if Player then
                    Player.Functions.AddMoney('cash', cappedPayout, 'sports-bet-' .. bet.status)
                    TriggerClientEvent('hk-sportsbetting:client:betSettled', Player.PlayerData.source, {
                        betId = bet.id, result = bet.status, amount = cappedPayout
                    })
                else
                    MySQL.update('UPDATE players SET money = JSON_SET(money, "$.cash", CAST(JSON_EXTRACT(money, "$.cash") AS UNSIGNED) + ?) WHERE citizenid = ?',
                        {cappedPayout, bet.identifier})
                end
                paid = paid + 1
            end
        end
    end
    if logPrefix then print(logPrefix .. " paid " .. paid .. " payouts") end
end

-- Check pending payouts on startup (for bets settled while FiveM was offline)
CreateThread(function()
    Wait(10000)
    processPendingPayouts("[hk-sportsbetting] startup payouts:")
end)

-- Periodic settlement poll (every 5 min) — catches bets settled while server runs
CreateThread(function()
    Wait(60000)
    while true do
        Wait(300000)
        processPendingPayouts(nil)
    end
end)

-- Client requests: serve from local cache
RegisterNetEvent('hk-sportsbetting:server:getSportOdds', function(sportKey)
    local src = source
    if not sportKey or type(sportKey) ~= "string" or not validSportKeys[sportKey] then return end
    local odds = oddsCache[sportKey] or {}
    TriggerClientEvent('hk-sportsbetting:client:receiveSportOdds', src, sportKey, odds)
end)

-- ── Sport-level aggregate: merge all leagues of a category, live-first sort ──
-- categoryId -> { leagueKey,... } from Config.SportCategories
local categoryLeagues = {}
local categoryValid = {}
for _, cat in ipairs(Config.SportCategories) do
    local keys = {}
    for _, sp in ipairs(cat.sports) do keys[#keys + 1] = sp.key end
    categoryLeagues[cat.id] = keys
    categoryValid[cat.id] = true
end

-- Derive an event's play state from its start time (odds feed has no in-play scores).
-- 'live'  = kickoff passed, within last 3h (likely in progress)
-- 'soon'  = starts within next 2h
-- 'upcoming' = further out
-- 'ended' = >3h after kickoff (dropped)
local function liveState(startTime, now)
    if not startTime then return 'upcoming', math.huge end
    -- Feed timestamps come in two shapes: "2026-08-28T19:00:00Z" (with seconds) and
    -- "2026-08-28T18:45Z" (no seconds). Parse date+HH:MM first, then OPTIONALLY the
    -- seconds — a seconds-mandatory pattern silently failed on the no-seconds form and
    -- returned 'upcoming'/math.huge forever, so those events never aged to 'ended' and
    -- stuck on the board as permanently "live/upcoming" long after kickoff.
    local y, mo, d, h, mi = tostring(startTime):match("(%d+)-(%d+)-(%d+)T(%d+):(%d+)")
    local s = tostring(startTime):match("T%d+:%d+:(%d+)") or 0
    if not y then
        -- No "T HH:MM" component (date-only like "2026-08-19Z"). The old code bailed
        -- to 'upcoming'/math.huge here, so date-only events NEVER aged to 'ended' and
        -- stuck on the board forever. Parse the bare date and treat it as end-of-day
        -- UTC so it still ages out ~24h after the listed day.
        y, mo, d = tostring(startTime):match("(%d+)-(%d+)-(%d+)")
        if not y then return 'upcoming', math.huge end
        h, mi, s = 23, 59, 0
    end
    -- treat feed timestamps as UTC
    local t = os.time({year=tonumber(y), month=tonumber(mo), day=tonumber(d), hour=tonumber(h), min=tonumber(mi), sec=tonumber(s)})
    -- os.time() treats the parsed feed fields as LOCAL time, but the feed is UTC.
    -- utcOffset = (UTC-as-local-epoch) - (local-as-local-epoch), which equals the
    -- NEGATIVE of the tz offset (e.g. -8h on a HKT+8 host). We must SUBTRACT it to add
    -- the tz offset back and land on the true UTC epoch. (On a UTC host offset=0, no-op.)
    local utcOffset = os.difftime(os.time(os.date("!*t", now)), os.time(os.date("*t", now)))
    t = t - utcOffset
    local diff = now - t  -- seconds since kickoff (negative = future)
    if diff >= 0 and diff <= 3*3600 then return 'live', diff end
    if diff < 0 and diff >= -2*3600 then return 'soon', diff end
    if diff < -2*3600 then return 'upcoming', diff end
    return 'ended', diff
end

-- Sort weight: live first (most-recently-started first), then soon, then upcoming (soonest first)
local function sortWeight(state, diff)
    if state == 'live' then return -1e12 + diff end       -- live cluster, earliest-started leads
    if state == 'soon' then return -diff end               -- closest to kickoff first (diff negative)
    return 1e9 - diff                                       -- upcoming: soonest (least-negative diff) first
end

RegisterNetEvent('hk-sportsbetting:server:getSportEvents', function(categoryId, leagueKey, limit)
    local src = source
    if not categoryId or not categoryValid[categoryId] then return end
    limit = tonumber(limit) or 30
    local now = os.time()
    local seen = {}
    local out = {}
    local leagueFilter = (leagueKey and leagueKey ~= "" and leagueKey ~= "all") and leagueKey or nil

    -- Cold-cache fill: if a needed league has never been fetched (server just started,
    -- 10-min loop not run yet), fetch it on-demand so we never return a false
    -- "no matches". Fire ALL missing leagues in PARALLEL and wait once on a shared
    -- deadline — sequential 15s-per-league blocking was the "All" page slow-load.
    local pending = 0
    for _, key in ipairs(categoryLeagues[categoryId]) do
        if (not leagueFilter or key == leagueFilter) and oddsCache[key] == nil then
            pending = pending + 1
            engineRequest('/odds/sports/' .. key, function(data)
                if data then oddsCache[key] = data end
                pending = pending - 1
            end)
        end
    end
    if pending > 0 then
        local waited = 0
        while pending > 0 and waited < 6000 do
            Wait(50)
            waited = waited + 50
        end
    end

    for _, key in ipairs(categoryLeagues[categoryId]) do
        if not leagueFilter or key == leagueFilter then
            for _, ev in ipairs(oddsCache[key] or {}) do
                local dedup = (ev.homeTeam or "") .. "|" .. (ev.awayTeam or "") .. "|" .. (ev.startTime or "")
                if not seen[dedup] then
                    seen[dedup] = true
                    local state, diff = liveState(ev.startTime, now)
                    if state ~= 'ended' then
                        -- shallow copy + attach derived fields (don't mutate cache)
                        -- form (last-5 W/D/L) and _lH/_lA (Poisson expected goals) power the
                        -- expandable match stats panel in the NUI; _aiTags surfaces AI notes.
                        local e = {
                            id = ev.id, sportKey = ev.sportKey, homeTeam = ev.homeTeam,
                            awayTeam = ev.awayTeam, startTime = ev.startTime, markets = ev.markets,
                            leagueKey = key, liveState = state, _w = sortWeight(state, diff),
                            form = ev.form, xgHome = ev._lH, xgAway = ev._lA, aiTags = ev._aiTags,
                        }
                        out[#out + 1] = e
                    end
                end
            end
        end
    end
    table.sort(out, function(a, b) return a._w < b._w end)
    -- trim to limit + strip the sort weight
    local res = {}
    for i = 1, math.min(#out, limit) do out[i]._w = nil; res[i] = out[i] end

    -- Per-league count of non-ended events across the WHOLE category (regardless of the
    -- current filter) so the NUI can hide empty leagues from the drawer. Cheap: cache is
    -- already in memory. Keyed by league key -> count.
    local leagueCounts = {}
    for _, key in ipairs(categoryLeagues[categoryId]) do
        local c = 0
        for _, ev in ipairs(oddsCache[key] or {}) do
            local st = liveState(ev.startTime, now)
            if st ~= 'ended' then c = c + 1 end
        end
        leagueCounts[key] = c
    end

    TriggerClientEvent('hk-sportsbetting:client:receiveSportEvents', src, categoryId, leagueFilter or "all", res, leagueCounts)
end)

-- Hot/featured matches: the engine curates these daily (prestige + competitiveness +
-- AI blurb). We just proxy its /featured payload straight to the NUI.
RegisterNetEvent('hk-sportsbetting:server:getFeatured', function(categoryId)
    local src = source
    local ep = '/featured'
    if categoryId and categoryId ~= "" then
        ep = ep .. '?category=' .. categoryId
    end
    engineRequest(ep, function(data)
        local featured = (data and data.featured) or {}
        TriggerClientEvent('hk-sportsbetting:client:receiveFeatured', src, featured)
    end)
end)

RegisterNetEvent('hk-sportsbetting:server:getCategories', function()
    local src = source
    local QBCore = exports['qb-core']:GetCoreObject()
    local Player = QBCore.Functions.GetPlayer(src)
    local citizenid = Player and Player.PlayerData.citizenid or nil
    if citizenid then
        _G.EngineRequest('/steak/casino/exclusion-status/' .. citizenid, function(data)
            if data and data.excluded then
                TriggerClientEvent('hk-sportsbetting:client:paused', src, {
                    reason = data.reason or 'Account paused',
                    expiresAt = data.expiresAt,
                    remainingMs = data.remainingMs,
                })
                return
            end
            TriggerClientEvent('hk-sportsbetting:client:receiveCategories', src, Config.SportCategories, Config.Casino)
        end)
    else
        TriggerClientEvent('hk-sportsbetting:client:receiveCategories', src, Config.SportCategories, Config.Casino)
    end
end)

-- Refresh: rate-limited, pulls fresh from engine
RegisterNetEvent('hk-sportsbetting:server:refreshSport', function(sportKey)
    local src = source
    if not sportKey or type(sportKey) ~= "string" or not validSportKeys[sportKey] then return end

    local now = os.time()
    if refreshCooldown[sportKey] and (now - refreshCooldown[sportKey]) < 60 then
        TriggerClientEvent('hk-sportsbetting:client:receiveSportOdds', src, sportKey, oddsCache[sportKey] or {})
        return
    end

    refreshCooldown[sportKey] = now
    fetchSportFromEngine(sportKey)
    TriggerClientEvent('hk-sportsbetting:client:receiveSportOdds', src, sportKey, oddsCache[sportKey] or {})
end)
