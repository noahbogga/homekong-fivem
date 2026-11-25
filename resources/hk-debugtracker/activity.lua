-- hk-debugtracker :: activity.lua
-- The "what has this player done" system. Taps central QBCore/qb-log buses so
-- we capture actions from ALL resources without enumerating each event.
-- Writes rich rows to hk_player_activity; two-tier retention (live 14d -> archive 60d).

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
local activityReady = false

-- ---- schema ----
local function initActivitySchema()
    if not Config.Activity.Enabled then return end
    exports.oxmysql:query([[
        CREATE TABLE IF NOT EXISTS hk_player_activity (
            id BIGINT AUTO_INCREMENT PRIMARY KEY,
            citizenid VARCHAR(32),
            name      VARCHAR(64),
            src       INT,
            category  VARCHAR(40),
            action    VARCHAR(64),
            detail    LONGTEXT,
            created   TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            INDEX idx_cid (citizenid), INDEX idx_cat (category), INDEX idx_created (created)
        )]], {})
    exports.oxmysql:query([[
        CREATE TABLE IF NOT EXISTS hk_player_activity_archive (
            id BIGINT PRIMARY KEY,
            citizenid VARCHAR(32),
            name      VARCHAR(64),
            src       INT,
            category  VARCHAR(40),
            action    VARCHAR(64),
            detail    LONGTEXT,
            created   TIMESTAMP,
            archived  TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            INDEX idx_cid (citizenid), INDEX idx_created (created)
        )]], {}, function() activityReady = true end)
end

-- ---- core writer ----
local function record(citizenid, name, src, category, action, detail)
    if not (Config.Activity.Enabled and activityReady) then return end
    if type(detail) ~= 'string' then
        local ok, enc = pcall(json.encode, detail); detail = ok and enc or tostring(detail)
    end
    if detail and #detail > 8000 then detail = detail:sub(1, 8000) .. '...(truncated)' end
    exports.oxmysql:insert(
        'INSERT INTO hk_player_activity (citizenid, name, src, category, action, detail) VALUES (?, ?, ?, ?, ?, ?)',
        { citizenid or 'n/a', name or '?', src or 0, category or 'misc', action or '', detail or '' })
end
_G.hkRecordActivity = record   -- expose for other files / manual use

-- helper: resolve src -> citizenid + name
local function who(src)
    if not src or src == 0 then return 'server', 'console' end
    local ok, p = pcall(function() return QBCore.Functions.GetPlayer(src) end)
    if ok and p then return p.PlayerData.citizenid, (GetPlayerName(src) or '?') end
    return 'n/a', (GetPlayerName(src) or '?')
end

-- ---- hook 1: qb-log:server:CreateLog (the big one — 26 resources funnel here) ----
-- signature: (name/category, title/action, color, message, tagEveryone)
-- The message text embeds "citizenid: XXX | id: N" — we parse it out.
local function shouldIgnore(cat)
    for _, c in ipairs(Config.Activity.IgnoreCategories or {}) do
        if c == cat then return true end
    end
    return false
end

if Config.Activity.HookCreateLog then
    AddEventHandler('qb-log:server:CreateLog', function(category, action, _color, message)
        if shouldIgnore(category) then return end
        local cid = message and message:match('citizenid:%s*([%w]+)') or 'n/a'
        local sid = message and tonumber(message:match('id:%s*(%d+)')) or 0
        local nm  = (sid ~= 0 and GetPlayerName(sid)) or '?'
        record(cid, nm, sid, category, action, message)
    end)
end

-- ---- hook 2: money changes (core-level, every player) ----
if Config.Activity.HookMoney then
    AddEventHandler('QBCore:Server:OnMoneyChange', function(src, moneytype, amount, action, reason)
        local cid, nm = who(src)
        record(cid, nm, src, 'money', action .. '-' .. tostring(moneytype),
            ('%s $%s (%s) reason: %s'):format(action, tostring(amount), tostring(moneytype), tostring(reason)))
    end)
end

-- ---- hook 3: job / gang changes ----
if Config.Activity.HookJobGang then
    AddEventHandler('QBCore:Server:OnJobUpdate', function(src, job)
        local cid, nm = who(src)
        record(cid, nm, src, 'job', 'setJob',
            ('%s grade %s (%s)'):format(job and job.name or '?', job and job.grade and job.grade.level or '?', job and job.onduty and 'on-duty' or 'off-duty'))
    end)
    AddEventHandler('QBCore:Server:OnGangUpdate', function(src, gang)
        local cid, nm = who(src)
        record(cid, nm, src, 'gang', 'setGang', gang and gang.name or '?')
    end)
end

-- ---- hook 4: session join / leave ----
if Config.Activity.HookSession then
    AddEventHandler('playerConnecting', function(name, _setKickReason, _deferrals)
        local src = source
        local ids = {}
        for _, id in ipairs(GetPlayerIdentifiers(src) or {}) do ids[#ids+1] = id end
        record('n/a', name, src, 'session', 'connecting', table.concat(ids, ', '))
    end)
    AddEventHandler('QBCore:Server:OnPlayerUnload', function(src)
        local cid, nm = who(src)
        record(cid, nm, src, 'session', 'unload', 'player unloaded')
    end)
    AddEventHandler('playerDropped', function(reason)
        local cid, nm = who(source)
        record(cid, nm, source, 'session', 'dropped', tostring(reason))
    end)
end

-- ---- two-tier retention: archive then prune ----
local function sweepRetention()
    if not (Config.Activity.Enabled and activityReady) then return end
    -- 1) copy live rows older than LiveDays into archive (ignore dups on id)
    exports.oxmysql:query([[
        INSERT IGNORE INTO hk_player_activity_archive
            (id, citizenid, name, src, category, action, detail, created)
        SELECT id, citizenid, name, src, category, action, detail, created
        FROM hk_player_activity
        WHERE created < (NOW() - INTERVAL ? DAY)]], { Config.Retention.LiveDays },
    function()
        -- 2) delete those from live
        exports.oxmysql:query('DELETE FROM hk_player_activity WHERE created < (NOW() - INTERVAL ? DAY)',
            { Config.Retention.LiveDays }, function(a)
                local n = (type(a)=='table' and a.affectedRows) or a or 0
                if n and n > 0 then print(('[hk-perf] activity: archived+pruned %d rows (>%dd)'):format(n, Config.Retention.LiveDays)) end
            end)
        -- 3) purge archive rows older than ArchiveDays
        exports.oxmysql:query('DELETE FROM hk_player_activity_archive WHERE created < (NOW() - INTERVAL ? DAY)',
            { Config.Retention.ArchiveDays }, function(a)
                local n = (type(a)=='table' and a.affectedRows) or a or 0
                if n and n > 0 then print(('[hk-perf] activity: purged %d archive rows (>%dd)'):format(n, Config.Retention.ArchiveDays)) end
            end)
    end)
end

CreateThread(function()
    if not Config.Activity.Enabled then return end
    initActivitySchema()
    Wait(20000)
    sweepRetention()
    while true do
        Wait(Config.Retention.IntervalHours * 3600000)
        sweepRetention()
    end
end)
