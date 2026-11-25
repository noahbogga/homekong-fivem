-- hk-hub — server
-- Backs the Info panel: player identity (steam name via Steam Web API, discord,
-- rockstar licenses), real playtime + first-join date (read from txAdmin's
-- playersDB), and all currency balances (cash / bank / HOMECOIN). Identifiers
-- MUST be read server-side and the result is sent only to the requesting player.

local QBCore = exports['qb-core']:GetCoreObject()

-- Forward-declared: the avatar cache/loader are defined lower down but getInfo
-- (above them) needs to read the cached portrait URL.
local loadAvatar

-- ---- Identifier helpers ---------------------------------------------------

local function identifierMap(src)
    local map = {}
    for i = 0, GetNumPlayerIdentifiers(src) - 1 do
        local id = GetPlayerIdentifier(src, i)
        if id then
            local prefix, value = id:match('^([^:]+):(.+)$')
            if prefix then map[prefix] = value end
        end
    end
    return map
end

-- Rockstar license(s). Show both license: and license2: when the player has
-- them (labelled so it's clear which is which).
local function rockstarLicenses(ids)
    local out = {}
    if ids.license then out[#out + 1] = 'license: ' .. ids.license end
    if ids.license2 then out[#out + 1] = 'license2: ' .. ids.license2 end
    return out
end

-- ---- txAdmin playtime + first-join ----------------------------------------
-- txAdmin keeps a per-player record in playersDB.json (keyed by the license:
-- hex, no prefix): { playTime (MINUTES), tsJoined (unix), tsLastConnection }.
-- This is the authoritative "time on THIS server since first join". The server
-- cwd is the txAdmin server root, so the profile-relative path resolves; an
-- absolute path (override via convar hk_hub_txDataPath) is tried as a fallback.
-- Read + parse txAdmin's playersDB fresh each call (small; txAdmin rewrites it
-- live). DIAGNOSIS (2026-07-24): FiveM's Lua io.open is SANDBOXED to the
-- server-data tree, and txData lives OUTSIDE it — so io.open(absolute txData
-- path) always fails ("NOT FOUND" for every candidate, confirmed in journal).
-- FIX: a symlink `_txdata.json` inside the resource points at the real
-- playersDB.json, and LoadResourceFile (resource-relative, not sandboxed) reads
-- through it. io.open on candidate paths is kept only as a fallback.
local function readTxPlayers()
    local raw = LoadResourceFile(GetCurrentResourceName(), '_txdata.json')
    if raw and raw ~= '' then
        local ok, data = pcall(json.decode, raw)
        if ok and type(data) == 'table' and data.players then
            return data.players
        end
    end
    -- fallback: try io.open at a few absolute locations (works if not sandboxed)
    local TX_REL = 'txData/' .. GetConvar('serverProfile', 'default') .. '/data/playersDB.json'
    for _, path in ipairs({ GetConvar('hk_hub_txDataPath', ''), '/opt/fxserver/server/' .. TX_REL }) do
        if path ~= '' then
            local f = io.open(path, 'r')
            if f then
                local body = f:read('*a'); f:close()
                local ok, data = pcall(json.decode, body)
                if ok and type(data) == 'table' and data.players then return data.players end
            end
        end
    end
    return nil
end

-- Find a player's txAdmin record by license hex (the value after "license:").
local function txStatsFor(licenseHex)
    if not licenseHex then return nil end
    local players = readTxPlayers()
    if not players then return nil end
    for _, p in ipairs(players) do
        if p.license == licenseHex then
            return {
                playtimeMins = p.playTime or 0,   -- MINUTES
                tsJoined     = p.tsJoined,         -- unix seconds
            }
        end
    end
    return nil
end

-- ---- Steam persona name (Steam Web API) -----------------------------------
-- Requires `set steam_webApiKey "<key>"` in server.cfg. steamId is the hex
-- from the steam: identifier; the Web API wants the decimal steamID64.
local function steamName(steamHex, cb)
    if not steamHex then cb(nil) return end
    local key = GetConvar('steam_webApiKey', 'none')
    if key == 'none' or key == '' then cb(nil) return end
    local steamId64 = tostring(tonumber(steamHex, 16))
    local url = ('https://api.steampowered.com/ISteamUser/GetPlayerSummaries/v2/?key=%s&steamids=%s')
        :format(key, steamId64)
    PerformHttpRequest(url, function(status, body)
        if status ~= 200 or not body then cb(nil) return end
        local ok, data = pcall(json.decode, body)
        if ok and data and data.response and data.response.players
           and data.response.players[1] then
            cb(data.response.players[1].personaname)
        else
            cb(nil)
        end
    end, 'GET')
end

-- ---- HOMECOIN balance -----------------------------------------------------
-- Try the sky_coinsystem export first (counterpart to hk-race's usage), then
-- fall back to a direct coinsystem_users read keyed by license.
local function homecoinBalance(src, license, cb)
    if GetResourceState('sky_coinsystem') == 'started' then
        local ok, coins = pcall(function()
            return exports['sky_coinsystem']:getCoins(src)
        end)
        if ok and type(coins) == 'number' then cb(coins) return end
    end
    if not license then cb(nil) return end
    MySQL.query('SELECT coins FROM coinsystem_users WHERE identifier = ?', { license }, function(rows)
        if rows and rows[1] then cb(rows[1].coins or 0) else cb(0) end
    end)
end

-- ---- Info callback --------------------------------------------------------
QBCore.Functions.CreateCallback('hk-hub:server:getInfo', function(source, cb)
    local src = source
    local ids = identifierMap(src)
    local coinKey = ids.license2 or ids.license   -- coinsystem is keyed by either

    -- Character name + money + job from QBCore.
    local charName, money, jobStr = nil, {}, nil
    local Player = QBCore.Functions.GetPlayer(src)
    if Player then
        local pd = Player.PlayerData
        local ci = pd.charinfo or {}
        local fn, ln = ci.firstname, ci.lastname
        if fn or ln then
            charName = ((fn or '') .. ' ' .. (ln or '')):gsub('^%s+', ''):gsub('%s+$', '')
            if charName == '' then charName = nil end
        end
        money = pd.money or {}
        -- Job + grade: "Label — Grade Name" (falls back to raw name / level).
        if pd.job then
            local jobLabel = pd.job.label or pd.job.name
            local gradeName
            if type(pd.job.grade) == 'table' then
                gradeName = pd.job.grade.name or ('Grade ' .. tostring(pd.job.grade.level or 0))
            end
            if jobLabel then
                jobStr = gradeName and (jobLabel .. ' — ' .. gradeName) or jobLabel
            end
        end
    end

    -- Real playtime + first-join from txAdmin (keyed by the license: hex).
    local stats = txStatsFor(ids.license)

    -- Reply as soon as homecoin resolves. Steam name is fetched SEPARATELY and
    -- pushed later (hk-hub:client:steamName) — it must NEVER block this callback,
    -- because a hung Steam HTTP request used to make the whole panel (incl.
    -- playtime) silently fail.
    local replied = false
    local function finish(coins)
        if replied then return end
        replied = true
        local avCid = Player and Player.PlayerData and Player.PlayerData.citizenid
        local avatar = avCid and loadAvatar(avCid) or nil
        cb({
            charName     = charName,
            job          = jobStr,                     -- "Label — Grade"
            avatar       = avatar and avatar.url or nil,   -- cached ped-headshot URL (may be nil)
            serverId     = src,                        -- in-game server id
            fivemName    = GetPlayerName(src),         -- FiveM name (steam name arrives later)
            discordId    = ids.discord,
            steamId      = ids.steam,
            licenses     = rockstarLicenses(ids),      -- array of license strings
            tsJoined     = stats and stats.tsJoined or nil,       -- unix seconds
            playtimeMins = stats and stats.playtimeMins or nil,   -- minutes
            money = {
                cash     = money.cash or 0,
                bank     = money.bank or 0,
                homecoin = coins,
            },
        })
    end

    -- Safety net: if homecoin somehow never calls back, reply anyway after 1.5s.
    SetTimeout(1500, function() finish(nil) end)
    homecoinBalance(src, coinKey, function(coins) finish(coins) end)

    -- Fire-and-forget Steam name → pushed to the player when/if it returns.
    steamName(ids.steam, function(sName)
        if sName then
            TriggerClientEvent('hk-hub:client:steamName', src, sName)
        end
    end)
end)

-- ---- Mobile / web access key ----------------------------------------------
-- The web/PWA Steak mirror authenticates with an 8-char key the player manages
-- here. Key gen/regen + storage live in hk-sportsbetting (it owns the engine
-- link); we just proxy to its exports, guarding for the resource being stopped.
local function hkSportsReady()
    return GetResourceState('hk-sportsbetting') == 'started'
end

-- Fetch the current key (nil if never generated). Returns {loginId, key, ver}.
QBCore.Functions.CreateCallback('hk-hub:server:getMobileKey', function(source, cb)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then cb({ ok = false, err = 'no_player' }) return end
    if not hkSportsReady() then cb({ ok = false, err = 'unavailable' }) return end
    local cid = Player.PlayerData.citizenid
    local ok, row = pcall(function()
        return exports['hk-sportsbetting']:MobileGetKey(cid)
    end)
    if not ok then cb({ ok = false, err = 'error' }) return end
    cb({ ok = true, key = row or nil })
end)

-- Generate a new key (first-time gen or a leak-reset regenerate). Regenerating
-- invalidates all existing web sessions engine-side.
QBCore.Functions.CreateCallback('hk-hub:server:regenMobileKey', function(source, cb)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then cb({ ok = false, err = 'no_player' }) return end
    if not hkSportsReady() then cb({ ok = false, err = 'unavailable' }) return end
    local cid = Player.PlayerData.citizenid
    local ok, row = pcall(function()
        return exports['hk-sportsbetting']:MobileRegenKey(cid)
    end)
    if not ok or not row then cb({ ok = false, err = 'engine_unreachable' }) return end
    cb({ ok = true, key = row })
end)

-- ---- Character avatar -----------------------------------------------------
-- One ped-headshot portrait per character, hosted on Zipline via hk-debugtracker.
-- The client sends an appearance FINGERPRINT (model + components + props); we
-- only (re)capture when it differs from what's stored, so a capture happens on
-- first login and whenever the character's look actually changes.

local avatarCache = {}       -- [citizenid] = { url, fingerprint }
local avatarBusy  = {}       -- [citizenid] = true while a capture is in flight

function loadAvatar(cid)
    if not cid then return nil end
    if avatarCache[cid] ~= nil then return avatarCache[cid] end
    local rows = MySQL.query.await(
        'SELECT url, fingerprint FROM hk_player_avatars WHERE citizenid = ? LIMIT 1', { cid })
    local row = rows and rows[1]
    avatarCache[cid] = row and { url = row.url, fingerprint = row.fingerprint or '' } or false
    return avatarCache[cid]
end

-- Resource-global so server/squad.lua can attach portrait URLs to the roster.
-- (Files in a resource share globals, not locals — loadAvatar is file-local.)
function HKHubAvatarUrl(cid)
    local a = cid and loadAvatar(cid) or nil
    return (a and a.url) or nil
end

-- Ask the client to render an isolated ped-headshot portrait (transparent
-- background — see client/main.lua). The client rasterises it in NUI and sends
-- the base64 back via hk-hub:server:submitAvatar. No screenshot-basic here: a
-- full-screen capture would include the world behind the ped. Guarded so
-- concurrent requests don't double-fire.
local function captureAvatar(src, cid, fingerprint)
    if not src or not cid then return end
    if avatarBusy[cid] then return end
    if GetResourceState('hk-debugtracker') ~= 'started' then return end
    avatarBusy[cid] = true
    -- Safety valve: clear the in-flight latch if the client never submits.
    SetTimeout(15000, function() if avatarBusy[cid] then avatarBusy[cid] = nil end end)
    TriggerClientEvent('hk-hub:client:captureAvatar', src, tostring(fingerprint or ''))
end

-- Client returns the rasterised portrait (base64 PNG data URI). Upload to Zipline,
-- store URL + fingerprint, and push the new URL back to the NUI.
RegisterNetEvent('hk-hub:server:submitAvatar', function(dataUri, fingerprint)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    local cid = Player and Player.PlayerData and Player.PlayerData.citizenid
    if not cid then return end
    if type(dataUri) ~= 'string' or dataUri:sub(1, 5) ~= 'data:' or #dataUri > 4 * 1024 * 1024 then
        avatarBusy[cid] = nil
        return
    end
    if GetResourceState('hk-debugtracker') ~= 'started' then avatarBusy[cid] = nil return end

    exports['hk-debugtracker']:UploadImage(dataUri,
        { filename = ('avatar_%s'):format(cid) },
        function(url)
            avatarBusy[cid] = nil
            if not url or url == '' then return end
            MySQL.insert.await([[
                INSERT INTO hk_player_avatars (citizenid, url, fingerprint)
                VALUES (?, ?, ?)
                ON DUPLICATE KEY UPDATE url = VALUES(url), fingerprint = VALUES(fingerprint)
            ]], { cid, url:sub(1, 512), tostring(fingerprint or ''):sub(1, 128) })
            avatarCache[cid] = { url = url, fingerprint = tostring(fingerprint or '') }
            TriggerClientEvent('hk-hub:client:avatar', src, url)
        end)
end)

-- Client sends its current appearance fingerprint. Reply with the cached URL (if
-- any) and, when the fingerprint differs, kick off a fresh capture. The new URL
-- is pushed later via hk-hub:client:avatar.
QBCore.Functions.CreateCallback('hk-hub:server:checkAvatar', function(source, cb, fingerprint)
    local Player = QBCore.Functions.GetPlayer(source)
    local cid = Player and Player.PlayerData and Player.PlayerData.citizenid
    if not cid then cb({ url = nil }) return end
    fingerprint = tostring(fingerprint or '')

    local a = loadAvatar(cid)
    local haveUrl = a and a.url or nil
    cb({ url = haveUrl })

    -- Recapture if we have no portrait yet, or the look changed.
    if fingerprint ~= '' and (not a or a.fingerprint ~= fingerprint or not haveUrl) then
        captureAvatar(source, cid, fingerprint)
    end
end)

-- ---- Bug report / feedback ------------------------------------------------
-- Validates the submission (word counts, cooldown) SERVER-side (never trust the
-- NUI), builds a Discord embed from the player's text + client diagnostics, and
-- posts it to the configured webhook. Screenshots (if requested) are captured via
-- screenshot-basic and uploaded to Zipline (hk-debugtracker) — the returned https
-- URL is embedded in a plain JSON webhook. The webhook URL stays server-only.

local reportCooldown = {}   -- [license] = os.time() of last accepted report

-- Build the Discord embed table (array of one embed) from a validated report.
local function buildReportEmbed(src, message, steps, console, diag, playerName, ids)
    local d = diag or {}
    local fields = {
        { name = 'Player',    value = ('%s (id %s)'):format(playerName or '—', src), inline = true },
        { name = 'License',   value = ids.license and ('`%s`'):format(ids.license) or '—', inline = true },
        { name = 'Discord',   value = ids.discord and ('<@%s>'):format(ids.discord) or '—', inline = true },
        { name = 'Location',  value = ('`%s` (h %s)'):format(d.coords or '?', d.heading or '?'), inline = true },
        { name = 'Health/Armor', value = ('%s / %s'):format(d.health or '?', d.armor or '?'), inline = true },
        { name = 'FPS / Bucket', value = ('%s / %s'):format(d.fps or '?', d.bucket or 0), inline = true },
        { name = 'Build / Resources', value = ('%s · %s/%s started'):format(d.gameBuild or '?', d.resStarted or '?', d.resTotal or '?'), inline = true },
    }
    if type(d.vehicle) == 'table' then
        fields[#fields + 1] = {
            name = 'Vehicle',
            value = ('%s `%s` · eng %s · %skm/h'):format(
                d.vehicle.model or '?', d.vehicle.plate or '', d.vehicle.engine or '?', d.vehicle.speed or '?'),
            inline = false,
        }
    end
    fields[#fields + 1] = { name = 'Steps to reproduce', value = (steps ~= '' and steps or '—'):sub(1, 1024), inline = false }

    -- Player-pasted F8 console log → code block (Discord field cap is 1024, so
    -- keep the TAIL where the relevant errors usually are).
    if console and console ~= '' then
        local c = console
        if #c > 1000 then c = '…' .. c:sub(-999) end
        fields[#fields + 1] = { name = 'F8 console (pasted)', value = '```\n' .. c .. '\n```', inline = false }
    end

    -- Event breadcrumbs → a code block (trimmed to Discord's field limit).
    if type(d.logs) == 'table' and #d.logs > 0 then
        local joined = table.concat(d.logs, '\n')
        if #joined > 1000 then joined = joined:sub(-1000) end
        fields[#fields + 1] = { name = 'Event log', value = '```\n' .. joined .. '\n```', inline = false }
    end

    return { {
        title       = 'Player Feedback',
        description = message:sub(1, 4000),
        color       = (HubConfig.Report or {}).embedColor or 3447003,
        fields      = fields,
        footer      = { text = ('HOMEKONG · %s'):format(d.time or os.date('%Y-%m-%d %H:%M:%S')) },
    } }
end

-- Post an embed as JSON. `imageUrl` (optional) is an already-hosted https URL
-- (uploaded to Zipline via hk-debugtracker's relay) — Discord renders it inline.
-- Discord multipart attachments never landed on this box, so we NEVER send
-- binary; we host the image first and reference its URL. See hk-debugtracker.
local function postEmbedJson(url, embed, imageUrl)
    local r = HubConfig.Report or {}
    if imageUrl and imageUrl ~= '' then
        embed[1].image = { url = imageUrl }
    end
    PerformHttpRequest(url, function() end, 'POST', json.encode({
        username   = r.username or 'HOMEKONG Reports',
        avatar_url = (r.avatar ~= '' and r.avatar) or nil,
        embeds     = embed,
    }), { ['Content-Type'] = 'application/json' })
end

QBCore.Functions.CreateCallback('hk-hub:server:submitReport', function(source, cb, payload)
    local src = source
    local r = HubConfig.Report or {}
    if not r.enabled then cb({ ok = false, err = 'disabled' }) return end

    local url = r.webhook
    if not url or url == '' then cb({ ok = false, err = 'no_webhook' }) return end

    payload = payload or {}
    local message = type(payload.message) == 'string' and payload.message or ''
    local steps   = type(payload.steps) == 'string' and payload.steps or ''
    local console = type(payload.console) == 'string' and payload.console or ''

    -- Server-side validation by CHARACTER count (never trust the NUI). Trim so
    -- whitespace-only doesn't pass.
    if #(message:gsub('^%s+', ''):gsub('%s+$', '')) < (r.minChars or 20) then
        cb({ ok = false, err = 'too_short' }) return
    end
    if #(steps:gsub('^%s+', ''):gsub('%s+$', '')) < (r.minStepChars or 20) then
        cb({ ok = false, err = 'steps_short' }) return
    end

    -- Per-license cooldown.
    local ids = identifierMap(src)
    local key = ids.license or ('src:' .. src)
    local now = os.time()
    local last = reportCooldown[key]
    if last and (now - last) < (r.cooldown or 180) then
        cb({ ok = false, err = 'cooldown', wait = (r.cooldown or 180) - (now - last) })
        return
    end
    reportCooldown[key] = now

    local embed = buildReportEmbed(src, message, steps, console, payload.diagnostics, GetPlayerName(src), ids)

    -- Screenshot path: capture via screenshot-basic (server → client), then hand
    -- the data URI to hk-debugtracker's UploadImage export, which base64-relays
    -- it to Zipline and returns a public https URL. We embed that URL in a plain
    -- JSON webhook (multipart never worked here). Reply to the player immediately
    -- — don't make them wait on capture + upload.
    local wantShot = r.screenshot == true and payload.screenshot == true
        and GetResourceState('screenshot-basic') == 'started'
        and GetResourceState('hk-debugtracker') == 'started'
    if wantShot then
        local okReq = pcall(function()
            exports['screenshot-basic']:requestClientScreenshot(src, {
                encoding = 'jpg',
                quality  = r.screenshotQuality or 0.7,
            }, function(err, data)
                if err or type(data) ~= 'string' then
                    postEmbedJson(url, embed)   -- capture failed → send text only
                    return
                end
                -- Pass the full data URI straight to the relay uploader.
                exports['hk-debugtracker']:UploadImage(data,
                    { filename = ('hkhub_%s_%s'):format(src, os.time()) },
                    function(imageUrl)
                        postEmbedJson(url, embed, imageUrl)   -- imageUrl nil → text only
                    end)
            end)
        end)
        if not okReq then postEmbedJson(url, embed) end
    else
        postEmbedJson(url, embed)
    end

    cb({ ok = true })
end)

