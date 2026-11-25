-- ═══════════════════════════════════════════════════════════════ --
--   HK-CHAT — server router                                          --
--   Server-authoritative: clients send raw input, the server decides  --
--   channel, visibility, recipients and timestamps. A tampered NUI    --
--   cannot post to Gameplay, spoof an id, or reveal hidden commands.  --
-- ═══════════════════════════════════════════════════════════════ --

local nicknames = {}   -- [license] = nickname            (persisted)
local nickBySrc = {}   -- [src]     = nickname            (live cache)
local cmdSettings = {} -- [command] = { noPreview, blockChat }  (persisted)
local recent911 = {}   -- rolling buffer of recent 911 calls (NOT persisted)
local lastSend = {}    -- [src] = os.clock ms of last send (shared cooldown)
local mutes = {}       -- [license] = true               (persisted admin mutes)
-- Message id counter, seeded from server time so ids don't collide across
-- restarts (a replayed history row keeps its old mid; new sends get fresh ones).
local midCounter = os.time() * 100
local function nextMid()
    midCounter = midCounter + 1
    return midCounter
end

-- Recent PUBLIC messages the admin panel can browse to remove. Ring buffer of
-- { mid, name, text, stamp } — public feed only (removing a private DM for
-- "everyone" is meaningless). Newest last.
local recentPublic = {}
local RECENT_PUBLIC_MAX = 40

-- ─── time helpers ────────────────────────────────────────────────── --
-- Server-stamped HH:MM (24h). One source of truth so every client agrees.
local function stamp()
    return os.date('%H:%M')
end

-- ─── DB bootstrap ────────────────────────────────────────────────── --
CreateThread(function()
    -- One-time cleanup: the v1 hidden-command table was replaced by
    -- hk_chat_cmd_settings (two-toggle model). Safe/idempotent to drop.
    MySQL.query('DROP TABLE IF EXISTS hk_chat_hidden_cmds')

    MySQL.query([[
        CREATE TABLE IF NOT EXISTS hk_chat_nicknames (
            license VARCHAR(60) NOT NULL,
            nickname VARCHAR(32) NOT NULL,
            updated TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
            PRIMARY KEY (license)
        )
    ]])
    -- Per-command controls: no_preview (hide from palette), block_chat (can't
    -- run via chat input). Replaces the old single hidden-list table.
    MySQL.query([[
        CREATE TABLE IF NOT EXISTS hk_chat_cmd_settings (
            command VARCHAR(64) NOT NULL,
            no_preview TINYINT(1) NOT NULL DEFAULT 0,
            block_chat TINYINT(1) NOT NULL DEFAULT 0,
            PRIMARY KEY (command)
        )
    ]])
    -- Admin mutes: one row per muted player (by license). Persists until untoggled.
    MySQL.query([[
        CREATE TABLE IF NOT EXISTS hk_chat_mutes (
            license VARCHAR(60) NOT NULL,
            name VARCHAR(64),
            muted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (license)
        )
    ]])
    -- Chat history for replay to joining players. `scope` gates who may see a
    -- row on replay: 'public' = everyone, 'job' = same job_room, 'whisper' =
    -- only from_lic/to_lic. This scoping is what keeps DMs/job chat private.
    -- v2 schema adds the scope columns; drop the old flat table if present.
    MySQL.query([[
        CREATE TABLE IF NOT EXISTS hk_chat_history (
            id INT AUTO_INCREMENT PRIMARY KEY,
            scope VARCHAR(12) NOT NULL DEFAULT 'public',
            tab VARCHAR(24) NOT NULL,
            author VARCHAR(64),
            body TEXT,
            color VARCHAR(24),
            tag VARCHAR(24),
            stamp VARCHAR(8),
            job_room VARCHAR(48),
            from_lic VARCHAR(60),
            to_lic VARCHAR(60),
            from_id INT,
            to_id INT,
            mid BIGINT,
            created TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )
    ]])
    -- Migrate: if an older flat table exists without the scope column, add it.
    MySQL.query([[
        ALTER TABLE hk_chat_history
        ADD COLUMN IF NOT EXISTS scope VARCHAR(12) NOT NULL DEFAULT 'public',
        ADD COLUMN IF NOT EXISTS mid BIGINT,
        ADD COLUMN IF NOT EXISTS job_room VARCHAR(48),
        ADD COLUMN IF NOT EXISTS from_lic VARCHAR(60),
        ADD COLUMN IF NOT EXISTS to_lic VARCHAR(60),
        ADD COLUMN IF NOT EXISTS from_id INT,
        ADD COLUMN IF NOT EXISTS to_id INT
    ]])

    Wait(500)

    -- Seed default no-preview commands (INSERT IGNORE keeps admin edits intact).
    for _, cmd in ipairs(Config.DefaultHiddenCommands or {}) do
        MySQL.insert('INSERT IGNORE INTO hk_chat_cmd_settings (command, no_preview) VALUES (?, 1)', { cmd })
    end

    Wait(300)

    local rows = MySQL.query.await('SELECT command, no_preview, block_chat FROM hk_chat_cmd_settings') or {}
    for _, r in ipairs(rows) do
        -- Normalise keys to lowercase (older rows may be mixed-case); the client
        -- lowercases its lookups too, so both sides must agree.
        cmdSettings[(r.command or ''):lower()] = {
            noPreview = (r.no_preview == 1),
            blockChat = (r.block_chat == 1),
        }
    end
    print(('[hk-chat] loaded %d command setting(s)'):format(#rows))

    local mrows = MySQL.query.await('SELECT license FROM hk_chat_mutes') or {}
    for _, r in ipairs(mrows) do mutes[r.license] = true end
    print(('[hk-chat] loaded %d mute(s)'):format(#mrows))
end)

-- ─── helpers ─────────────────────────────────────────────────────── --

-- Is this player muted by an admin? (checked on every send path)
local function isMuted(src)
    return mutes[GetChatLicense(src)] == true
end

-- Content filter: returns true if `text` should be BLOCKED (links/IPs/blocklist).
-- Admins are exempt (checked by the caller). Plain-Lua matching, no false-positive
-- on normal words. Case-insensitive.
local function contentBlocked(text)
    local cf = Config.ContentFilter
    if not cf or not cf.enabled then return false end
    local low = text:lower()

    if cf.blockIPs then
        -- IPv4, optionally with :port — four dot-separated 1-3 digit groups.
        if low:find('%d%d?%d?%.%d%d?%d?%.%d%d?%d?%.%d%d?%d?') then return true end
    end

    if cf.blockLinks then
        if low:find('https?://')        then return true end   -- http:// https://
        if low:find('www%.%w')          then return true end   -- www.something
        if low:find('discord%.gg/%w')   then return true end   -- discord invite
        if low:find('discord%.com/invite') then return true end
        -- bare domain: word + common TLD + boundary (e.g. "join x.com now").
        if low:find('%w[%w%-]*%.(%a%a+)') then
            local tld = low:match('%w[%w%-]*%.(%a%a+)')
            local common = { com=true, net=true, org=true, gg=true, io=true,
                xyz=true, tv=true, co=true, me=true, ru=true, cc=true, shop=true }
            if tld and common[tld] then return true end
        end
    end

    for _, phrase in ipairs(cf.Blocklist or {}) do
        if phrase ~= '' and low:find(phrase:lower(), 1, true) then return true end
    end

    return false
end


-- Has this player set a real nickname (required before Global chat)?
local function hasNickname(src)
    local n = nicknames[GetChatLicense(src)]
    return n ~= nil and n ~= ''
end

-- Sanitise a chat line: trim, clamp length, strip ^ colour codes and controls.
local function clean(text)
    if type(text) ~= 'string' then return '' end
    text = text:gsub('%^%d', ''):gsub('[%c]', ' '):gsub('%s+', ' '):gsub('^%s+', ''):gsub('%s+$', '')
    if #text > Config.MaxMessageLength then text = text:sub(1, Config.MaxMessageLength) end
    return text
end

-- Nickname for display: stored nick, else char first name, else player name.
local function displayNick(src)
    local lic = GetChatLicense(src)
    if nicknames[lic] and nicknames[lic] ~= '' then return nicknames[lic] end
    local Player = QBCore.Functions.GetPlayer(src)
    if Player and Player.PlayerData.charinfo and Player.PlayerData.charinfo.firstname then
        return Player.PlayerData.charinfo.firstname
    end
    return GetPlayerName(src) or ('Player %s'):format(src)
end

-- Push one line to a set of client ids (-1 = everyone). Stamps time + assigns a
-- unique mid here (unless the payload already has one, e.g. history replay).
local function send(targets, payload)
    if not payload.stamp then payload.stamp = stamp() end
    if not payload.mid then payload.mid = nextMid() end
    if targets == -1 then
        TriggerClientEvent('hk-chat:client:recv', -1, payload)
    else
        for _, id in ipairs(targets) do
            TriggerClientEvent('hk-chat:client:recv', id, payload)
        end
    end
end

-- Gate a message through the content filter. Returns true if OK to send; false
-- (and notifies the sender) if blocked. Admins bypass entirely. Defined AFTER
-- send() so it captures the local send upvalue correctly.
local function passContent(src, text, tab)
    if IsChatAdmin(src) then return true end
    if contentBlocked(text) then
        send({ src }, { tab = tab or 'global', system = true, color = '#f87171',
            text = (Config.ContentFilter and Config.ContentFilter.Notice)
                or 'Message blocked.' })
        return false
    end
    return true
end

-- Persist a chat line for replay, scoped so private lines stay private.
--   scope 'public'  → global/ooc/announce, everyone sees on join
--   scope 'job'     → only players whose job_room matches see on join
--   scope 'whisper' → only from_lic / to_lic see on join
-- `meta` carries { scope, jobRoom, fromLic, toLic, fromId, toId } as needed.
local function saveHistory(p, meta)
    meta = meta or {}
    MySQL.insert(
        [[INSERT INTO hk_chat_history
            (scope, tab, author, body, color, tag, stamp, job_room, from_lic, to_lic, from_id, to_id, mid)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)]],
        {
            meta.scope or 'public', p.tab, p.name or '', p.text or '',
            p.color or '', p.tag or '', p.stamp or stamp(),
            meta.jobRoom, meta.fromLic, meta.toLic, meta.fromId, meta.toId, p.mid,
        },
        function()
            -- Keep only the newest N rows overall (rows are tiny).
            MySQL.query([[
                DELETE FROM hk_chat_history WHERE id NOT IN (
                    SELECT id FROM (SELECT id FROM hk_chat_history ORDER BY id DESC LIMIT ?) t
                )
            ]], { Config.HistoryKeep })
        end
    )
end

-- Track a public message in the admin "recent" ring buffer for removal.
local function trackRecentPublic(p)
    recentPublic[#recentPublic + 1] = {
        mid = p.mid, name = p.name or '', text = p.text or '', stamp = p.stamp,
    }
    while #recentPublic > RECENT_PUBLIC_MAX do table.remove(recentPublic, 1) end
end

-- Everyone who currently shares a job room with `room`.
local function playersInJobRoom(room)
    local out = {}
    for _, id in ipairs(GetPlayers()) do
        id = tonumber(id)
        if GetJobRoomFor(id) == room then out[#out + 1] = id end
    end
    return out
end

-- ─── /911 emergency-responder helpers ────────────────────────────── --
local emergencyJobSet = {}   -- exact job names
local emergencyTypeSet = {}  -- job `type` values (leo/ems/…)
CreateThread(function()
    for _, j in ipairs(Config.EmergencyJobs or {}) do emergencyJobSet[j] = true end
    for _, t in ipairs(Config.EmergencyJobTypes or {}) do emergencyTypeSet[t] = true end
end)

-- A player is a responder if their job NAME is listed, OR their job TYPE
-- (police/fbi = "leo", ambulance = "ems") is listed. Reads the live job first,
-- falls back to QBShared.Jobs for the type.
local function isEmergencyResponder(src)
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return false end
    local job = Player.PlayerData.job
    if not job or not job.name then return false end
    if emergencyJobSet[job.name] then return true end
    local jtype = job.type or (QBCore.Shared.Jobs[job.name] and QBCore.Shared.Jobs[job.name].type)
    return jtype ~= nil and emergencyTypeSet[jtype] == true
end

-- On-duty responders who should receive a live 911 call.
local function responders()
    local out = {}
    for _, id in ipairs(GetPlayers()) do
        id = tonumber(id)
        if isEmergencyResponder(id) then out[#out + 1] = id end
    end
    return out
end

-- ─── shared send cooldown (anti-spam) ────────────────────────────── --
local cdExemptJobSet = {}
local cdExemptTypeSet = {}
CreateThread(function()
    for _, j in ipairs(Config.CooldownExemptJobs or {}) do cdExemptJobSet[j] = true end
    for _, t in ipairs(Config.CooldownExemptJobTypes or {}) do cdExemptTypeSet[t] = true end
end)

-- Police + ambulance (by config) skip the cooldown entirely.
local function isCooldownExempt(src)
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return false end
    local job = Player.PlayerData.job
    if not job or not job.name then return false end
    if cdExemptJobSet[job.name] then return true end
    local jtype = job.type or (QBCore.Shared.Jobs[job.name] and QBCore.Shared.Jobs[job.name].type)
    return jtype ~= nil and cdExemptTypeSet[jtype] == true
end

-- Gate a send. Returns true if allowed (and starts the cooldown + tells the
-- client to grey out); false if still cooling down (and re-notifies the client).
local function passCooldown(src)
    local cd = Config.SendCooldown or 0
    if cd <= 0 or isCooldownExempt(src) then return true end
    local now = GetGameTimer()
    local last = lastSend[src]
    if last and (now - last) < cd then
        -- Still cooling: resync the client's grey-out to the true remaining time.
        local remaining = cd - (now - last)
        TriggerClientEvent('hk-chat:client:cooldown', src, remaining)
        return false
    end
    lastSend[src] = now
    TriggerClientEvent('hk-chat:client:cooldown', src, cd)
    return true
end

-- Push the recent 911 rolling buffer to a player IF they're on duty. Called on
-- join and when a player goes on-duty (so responders see the last few calls).
function send911Recent(src)
    if not isEmergencyResponder(src) then return end
    local now = GetGameTimer()
    local maxAge = Config.Recent911MaxAge or 900000
    local batch = {}
    for _, c in ipairs(recent911) do
        if now - c.at <= maxAge then
            batch[#batch + 1] = {
                tab = 'gameplay', history = true, id = c.id, name = c.name,
                text = c.text, color = c.color, tag = c.tag, stamp = c.stamp,
                noMirror = true,
            }
        end
    end
    if #batch > 0 then TriggerClientEvent('hk-chat:client:history', src, batch) end
end

-- ─── Job roster: online players in the requester's job (id + real name) ─ --
-- Offline players are intentionally not listed. Uses in-game character name.
RegisterNetEvent('hk-chat:server:requestRoster', function()
    local src = source
    local room = GetJobRoomFor(src)
    local roster = {}
    for _, id in ipairs(playersInJobRoom(room)) do
        roster[#roster + 1] = { id = id, name = GetCharName(id), me = (id == src) }
    end
    table.sort(roster, function(a, b) return a.id < b.id end)
    TriggerClientEvent('hk-chat:client:roster', src, room, roster)
end)

-- ─── channel router ──────────────────────────────────────────────── --
-- Called when a player submits a plain (non-command) line on a tab. The
-- server re-derives everything; the tab is only a hint. The client mirrors
-- allowed channels into its own Global feed (see Config.GlobalAggregates).
RegisterNetEvent('hk-chat:server:say', function(tab, text)
    local src = source
    text = clean(text)
    if text == '' then return end
    if isMuted(src) then
        send({ src }, { tab = tab or 'global', system = true, color = '#f87171',
            text = 'You are muted and cannot send messages.' })
        return
    end

    if tab == 'global' then
        -- Global requires a nickname first (identity gate). Other channels are fine.
        if not hasNickname(src) then
            send({ src }, { tab = 'global', system = true, color = '#fbbf24',
                text = 'Set a nickname before using Global chat:  /nick [name]' })
            return
        end
        if not passContent(src, text, 'global') then return end
        if not passCooldown(src) then return end
        local p = { tab = 'global', id = src, name = displayNick(src), text = text, color = '#00c8ff' }
        send(-1, p)
        saveHistory(p, { scope = 'public' })
        trackRecentPublic(p)

    elseif tab == 'job' then
        if not passContent(src, text, 'job') then return end
        -- Job chat is cooled down too, EXCEPT for exempt jobs (police/ambulance).
        if not passCooldown(src) then return end
        local room = GetJobRoomFor(src)
        local p = {
            tab = 'job', id = src, name = GetCharName(src),
            room = room, text = text, color = '#34d399', tag = 'JOB',
        }
        send(playersInJobRoom(room), p)
        -- Saved with job scope: only players in this same job room replay it.
        saveHistory(p, { scope = 'job', jobRoom = room })

    else
        -- gameplay/whisper/anything else is not free-typeable; ignore.
        return
    end
end)

-- ─── /w whisper: global, always by server id, ID-ONLY (no names) ─── --
RegisterCommand('w', function(src, args)
    if src == 0 then return end
    if isMuted(src) then
        send({ src }, { tab = 'whisper', system = true, color = '#f87171',
            text = 'You are muted and cannot send messages.' })
        return
    end
    local target = tonumber(args[1])
    local msg = clean(table.concat(args, ' ', 2))
    if not target or msg == '' then
        send({ src }, { tab = 'whisper', system = true, color = '#f87171',
            text = 'Usage: /w [server id] [message]' })
        return
    end
    if not GetPlayerName(target) then
        send({ src }, { tab = 'whisper', system = true, color = '#f87171',
            text = ('No player online with id %d.'):format(target) })
        return
    end
    if target == src then
        send({ src }, { tab = 'whisper', system = true, color = '#f87171',
            text = 'You cannot whisper yourself.' })
        return
    end
    if not passContent(src, msg, 'whisper') then return end
    if not passCooldown(src) then return end
    -- Whisper is ID-only by design: no nickname, no char name — just the ids.
    local ts = stamp()
    send({ target }, { tab = 'whisper', dir = 'in', stamp = ts,
        id = src, toId = target, text = msg, color = '#c084fc' })
    send({ src }, { tab = 'whisper', dir = 'out', stamp = ts,
        id = src, toId = target, text = msg, color = '#c084fc' })
    -- Saved with whisper scope: ONLY these two licenses replay it on join.
    -- Stored once; the join-replay decides dir per viewer from from_lic/to_lic.
    saveHistory(
        { tab = 'whisper', stamp = ts, text = msg, color = '#c084fc' },
        { scope = 'whisper',
          fromLic = GetChatLicense(src), toLic = GetChatLicense(target),
          fromId = src, toId = target }
    )
end, false)

-- ─── /me emote: 3D floating text above the player's head (proximity) ─ --
-- No chat line at all — the client draws it over the ped for nearby players.
RegisterCommand('me', function(src, args)
    if src == 0 then return end
    if isMuted(src) then return end
    local msg = clean(table.concat(args, ' '))
    if msg == '' then return end
    -- Broadcast to everyone; each client range-checks and only draws if close.
    TriggerClientEvent('hk-chat:client:emote', -1, src, GetCharName(src), msg)
end, false)

-- ─── /ooc out-of-character chat → GAMEPLAY tab (real in-game name) ─ --
-- GAMEPLAY is the IC/functional feed, so it uses the character name (like
-- /911 and /announce), NOT the nickname. Nicknames are Global/Whisper only.
RegisterCommand('ooc', function(src, args)
    if src == 0 then return end
    if isMuted(src) then
        send({ src }, { tab = 'gameplay', system = true, color = '#f87171',
            text = 'You are muted and cannot send messages.' })
        return
    end
    local msg = clean(table.concat(args, ' '))
    if msg == '' then
        send({ src }, { tab = 'gameplay', system = true, color = '#f87171',
            text = 'Usage: /ooc [message]' })
        return
    end
    if not passContent(src, msg, 'gameplay') then return end
    if not passCooldown(src) then return end
    local p = { tab = 'gameplay', id = src, name = GetCharName(src),
        text = msg, color = '#8fb4c8', tag = 'OOC' }
    send(-1, p)
    saveHistory(p)
    trackRecentPublic(p)
end, false)

-- ─── /announce admin broadcast into GAMEPLAY (+ Global mirror) ───── --
RegisterCommand('announce', function(src, args)
    if not IsChatAdmin(src) then
        send({ src }, { tab = 'global', system = true, color = '#f87171',
            text = 'You do not have permission to announce.' })
        return
    end
    local msg = clean(table.concat(args, ' '))
    if msg == '' then
        send({ src }, { tab = 'gameplay', system = true, color = '#fbbf24',
            text = 'Usage: /announce [message]' })
        return
    end
    local p = { tab = 'gameplay', name = GetCharName(src), text = msg, color = '#fbbf24', tag = 'ANNOUNCE' }
    send(-1, p)
    saveHistory(p)
    trackRecentPublic(p)
end, false)

-- ─── /911 emergency: fires dispatch AND echoes into GAMEPLAY feed ── --
RegisterCommand('911', function(src, args)
    if src == 0 then return end
    if isMuted(src) then
        send({ src }, { tab = 'gameplay', system = true, color = '#f87171',
            text = 'You are muted and cannot send messages.' })
        return
    end
    local msg = clean(table.concat(args, ' '))
    if msg == '' then
        send({ src }, { tab = 'gameplay', system = true, color = '#f87171',
            text = 'Usage: /911 [what is your emergency]' })
        return
    end
    if not passCooldown(src) then return end
    local meta = Config.SystemEchoCommands['911'] or { label = 'EMERGENCY', color = '#f87171' }
    local ts = stamp()

    -- PRIVATE echo: caller + on-duty emergency responders only. Never everyone,
    -- never Global (noMirror), never persisted to DB. Normal players can't see it.
    local recipients = { src }               -- caller always sees their own call
    for _, id in ipairs(responders()) do
        if id ~= src then recipients[#recipients + 1] = id end
    end

    local p = {
        tab = 'gameplay', id = src, name = GetCharName(src), text = msg,
        color = meta.color, tag = meta.label, stamp = ts, noMirror = true,
    }
    send(recipients, p)

    -- Push into the rolling buffer so responders who come on duty / join shortly
    -- after can still see recent calls (in-memory only, auto-expires by age/count).
    recent911[#recent911 + 1] = {
        id = src, name = GetCharName(src), text = msg,
        color = meta.color, tag = meta.label, stamp = ts, at = GetGameTimer(),
    }
    while #recent911 > (Config.Recent911 or 10) do table.remove(recent911, 1) end

    -- Hand off to the real dispatch system (client export needs caller coords).
    TriggerClientEvent('hk-chat:client:dispatch911', src, msg)
    TriggerEvent('hk-chat:911', src, msg)
end, false)

-- ═══════════════════════════════════════════════════════════════ --
--   GAMEPLAY FEED BRIDGE (for other resources)                        --
--   Post a notification line into the GAMEPLAY tab from any script.   --
--   Examples:                                                         --
--     exports['hk-chat']:GameplayNotify({                             --
--         tag = 'CASE', color = '#c084fc',                            --
--         text = 'Steve opened a LEGENDARY: Karambit | Fade',         --
--     })                                                              --
--     exports['hk-chat']:GameplayNotify({ tag='CASINO', color='#fbbf24',
--         text='Lucky won $250,000 on Blackjack', target = -1 })      --
--   Or fire the event: TriggerEvent('hk-chat:notify', { ... })        --
--                                                                     --
--   Fields: text (required), tag, color, name (optional prefix),      --
--   target (server id or -1/all — default all), save (persist? def T).--
-- ═══════════════════════════════════════════════════════════════ --
local function gameplayNotify(data)
    if type(data) ~= 'table' then return end
    local text = clean(tostring(data.text or ''))
    if text == '' then return end
    local p = {
        tab   = 'gameplay',
        text  = text,
        tag   = data.tag,
        color = data.color or '#8fb4c8',
        name  = data.name,   -- optional (nil = no name prefix, just the line)
    }
    local target = data.target
    if target == nil or target == -1 or target == 'all' then
        send(-1, p)
        if data.save ~= false then saveHistory(p) end
    else
        target = tonumber(target)
        if target then send({ target }, p) end
        -- Targeted notifications are per-player, so not saved to shared history.
    end
end
exports('GameplayNotify', gameplayNotify)
-- Local (server-only) event — NOT a net event, so clients cannot trigger it.
-- Other server scripts use: TriggerEvent('hk-chat:notify', { text=..., tag=... })
AddEventHandler('hk-chat:notify', function(data)
    gameplayNotify(data)
end)

-- ═══════════════════════════════════════════════════════════════ --
--   txAdmin notification integration                                 --
--   These are SERVER events fired by txAdmin. We render them in chat  --
--   instead of txAdmin's own popup. To actually replace the popup you --
--   must tick the matching "Hide X" box in txAdmin → Notifications;   --
--   otherwise both show. Each handler is gated by Config.TxAdmin.     --
--   Payload fields are per the official txAdmin events doc.           --
-- ═══════════════════════════════════════════════════════════════ --
local TX = Config.TxAdmin or {}

-- Announcement → GAMEPLAY, broadcast + saved (so mid-cycle joiners see it).
AddEventHandler('txAdmin:events:announcement', function(data)
    if not TX.announcements or type(data) ~= 'table' then return end
    local author = tostring(data.author or 'txAdmin')
    local msg = clean(tostring(data.message or ''))
    if msg == '' then return end
    local p = { tab = 'gameplay', name = author, text = msg,
        color = '#fbbf24', tag = 'ANNOUNCE' }
    send(-1, p)
    saveHistory(p)
    trackRecentPublic(p)
end)

-- Direct message → the target player's WHISPER tab, styled as from ADMIN.
-- Private, not saved. `target` is a server id.
AddEventHandler('txAdmin:events:playerDirectMessage', function(data)
    if not TX.dms or type(data) ~= 'table' then return end
    local target = tonumber(data.target)
    if not target or not GetPlayerName(target) then return end
    local author = tostring(data.author or 'Admin')
    local msg = clean(tostring(data.message or ''))
    if msg == '' then return end
    send({ target }, {
        tab = 'whisper', dir = 'in', system = false,
        adminDm = true, fromName = author,
        text = msg, color = '#c084fc', tag = 'ADMIN',
    })
end)

-- Warning → the warned player only (targetNetId), GAMEPLAY, red, private, not saved.
AddEventHandler('txAdmin:events:playerWarned', function(data)
    if not TX.warnings or type(data) ~= 'table' then return end
    local target = tonumber(data.targetNetId)
    if not target or not GetPlayerName(target) then return end
    local author = tostring(data.author or 'Admin')
    local reason = clean(tostring(data.reason or ''))
    send({ target }, {
        tab = 'gameplay', name = author, tag = 'WARNING', color = '#f87171',
        text = ('Warning: %s'):format(reason ~= '' and reason or 'no reason given'),
    })
end)

-- Scheduled restart → GAMEPLAY, broadcast + saved. Uses txAdmin's translated
-- message; fires at 30/15/10/5/4/3/2/1 min marks automatically.
AddEventHandler('txAdmin:events:scheduledRestart', function(data)
    if not TX.restarts or type(data) ~= 'table' then return end
    local msg = clean(tostring(data.translatedMessage or ''))
    if msg == '' then
        local mins = math.floor((tonumber(data.secondsRemaining) or 0) / 60)
        msg = ('Scheduled restart in %d minute(s).'):format(mins)
    end
    local p = { tab = 'gameplay', text = msg, color = '#fbbf24', tag = 'RESTART' }
    send(-1, p)
    saveHistory(p)
    trackRecentPublic(p)
end)

-- ─── /nick set nickname (per player, by license, persisted) ──────── --
RegisterCommand('nick', function(src, args)
    if src == 0 then return end
    local nick = clean(table.concat(args, ' '))
    if #nick < Config.NicknameMin or #nick > Config.NicknameMax then
        send({ src }, { tab = 'global', system = true, color = '#f87171',
            text = ('Nickname must be %d–%d characters.'):format(Config.NicknameMin, Config.NicknameMax) })
        return
    end
    local lic = GetChatLicense(src)
    nicknames[lic] = nick
    nickBySrc[src] = nick
    MySQL.insert(
        'INSERT INTO hk_chat_nicknames (license, nickname) VALUES (?, ?) ON DUPLICATE KEY UPDATE nickname = ?',
        { lic, nick, nick }
    )
    TriggerClientEvent('hk-chat:client:nick', -1, src, nick)
    send({ src }, { tab = 'global', system = true, color = '#34d399',
        text = ('Nickname set to "%s".'):format(nick) })
end, false)

-- ── Scoped history replay to one player. Three independent queries, each
-- scoped so a player only ever gets lines they're allowed to see: public (all),
-- their job room, their own whispers. Used on join AND on resource restart.
function replayHistoryTo(src)
    local lic = GetChatLicense(src)
    local room = GetJobRoomFor(src)
    local out = {}

    -- Public (global / ooc / announce). `_seq` = DB row id, used only to merge
    -- the three scopes back into chronological order; it is not sent to the NUI.
    -- `mid` IS sent so an admin can still remove a replayed public line.
    local pub = MySQL.query.await(
        "SELECT id, mid, tab, author, body, color, tag, stamp FROM hk_chat_history " ..
        "WHERE scope = 'public' ORDER BY id DESC LIMIT ?", { Config.HistoryReplay }) or {}
    for _, h in ipairs(pub) do
        out[#out + 1] = {
            _seq = h.id, mid = h.mid, tab = h.tab, history = true, stamp = h.stamp,
            name = (h.author ~= '' and h.author or nil), text = h.body,
            color = (h.color ~= '' and h.color or nil),
            tag = (h.tag ~= '' and h.tag or nil),
        }
    end

    -- This player's job room.
    local job = MySQL.query.await(
        "SELECT id, tab, author, body, color, tag, stamp FROM hk_chat_history " ..
        "WHERE scope = 'job' AND job_room = ? ORDER BY id DESC LIMIT ?",
        { room, Config.JobHistoryReplay }) or {}
    for _, h in ipairs(job) do
        out[#out + 1] = {
            _seq = h.id, tab = h.tab, history = true, stamp = h.stamp,
            name = (h.author ~= '' and h.author or nil), text = h.body,
            color = (h.color ~= '' and h.color or nil),
            tag = (h.tag ~= '' and h.tag or nil),
        }
    end

    -- This player's own whispers (sent OR received). dir is decided per-viewer.
    local wh = MySQL.query.await(
        "SELECT id, body, color, stamp, from_id, to_id, from_lic, to_lic " ..
        "FROM hk_chat_history WHERE scope = 'whisper' AND (from_lic = ? OR to_lic = ?) " ..
        "ORDER BY id DESC LIMIT ?", { lic, lic, Config.WhisperHistoryReplay }) or {}
    for _, h in ipairs(wh) do
        local outgoing = (h.from_lic == lic)
        out[#out + 1] = {
            _seq = h.id, tab = 'whisper', history = true, stamp = h.stamp,
            text = h.body, color = (h.color ~= '' and h.color or nil),
            dir = outgoing and 'out' or 'in',
            id = h.from_id, toId = h.to_id,
        }
    end

    -- Merge chronologically by DB row id (oldest first) so tabs replay in order.
    table.sort(out, function(a, b) return (a._seq or 0) < (b._seq or 0) end)
    for _, m in ipairs(out) do m._seq = nil end  -- strip the internal sort key
    if #out > 0 then TriggerClientEvent('hk-chat:client:history', src, out) end

    -- Send any recent 911 calls if this player is an on-duty responder.
    send911Recent(src)
end

-- ─── join: warm the nickname cache only ──────────────────────────── --
-- We deliberately do NOT push the nick map or replay history here. The NUI's
-- `requestBootstrap` (fired the moment the UI is ready) is the SINGLE source of
-- both — doing it here too replayed all history twice on every join, and would
-- race the NUI (which may not exist yet at PlayerLoaded). We just prime the
-- cache so displayNick works immediately for this player as a sender.
AddEventHandler('QBCore:Server:PlayerLoaded', function(Player)
    local src = Player.PlayerData.source
    local lic = GetChatLicense(src)
    local row = MySQL.query.await('SELECT nickname FROM hk_chat_nicknames WHERE license = ?', { lic })
    if row and row[1] then
        nicknames[lic] = row[1].nickname
        nickBySrc[src] = row[1].nickname
    end
end)

-- NUI is ready (fires on first load AND on every resource restart). This is the
-- authoritative bootstrap: reload nickname, push the full nick map, replay
-- scoped history — so first join AND restart both restore chat + nicknames the
-- moment the NUI comes back, with no reliance on join events or startup timing.
RegisterNetEvent('hk-chat:server:requestBootstrap', function()
    local src = source
    local lic = GetChatLicense(src)

    local row = MySQL.query.await('SELECT nickname FROM hk_chat_nicknames WHERE license = ?', { lic })
    if row and row[1] then
        nicknames[lic] = row[1].nickname
        nickBySrc[src] = row[1].nickname
    end
    -- Give THIS client the full current nick map (targeted — no -1 broadcast,
    -- which on a restart would be N² since every client bootstraps at once).
    for _, id in ipairs(GetPlayers()) do
        id = tonumber(id)
        if nickBySrc[id] then TriggerClientEvent('hk-chat:client:nick', src, id, nickBySrc[id]) end
    end

    replayHistoryTo(src)
end)

AddEventHandler('playerDropped', function()
    nickBySrc[source] = nil
    lastSend[source] = nil
end)

-- ── On resource/server restart, rebuild state for everyone ALREADY connected.
-- QBCore:Server:PlayerLoaded does NOT re-fire for players who were online before
-- the restart, so without this their saved nickname stays in the DB but is
-- missing from memory (forcing a re-/nick), and their NUI reloads with an empty
-- chat. We reload nicknames AND replay scoped history so both survive a restart.
AddEventHandler('onResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    CreateThread(function()
        -- Wait so qb-core is ready to resolve identifiers/jobs after a restart,
        -- and the NUI has loaded and can receive the history replay.
        Wait(2000)
        -- Rebuild the nickname cache from DB for all online players.
        for _, id in ipairs(GetPlayers()) do
            id = tonumber(id)
            local lic = GetChatLicense(id)
            local row = MySQL.query.await('SELECT nickname FROM hk_chat_nicknames WHERE license = ?', { lic })
            if row and row[1] then
                nicknames[lic] = row[1].nickname
                nickBySrc[id] = row[1].nickname
            end
        end
        -- Rebroadcast the full nick map so every online client relabels players.
        for _, id in ipairs(GetPlayers()) do
            id = tonumber(id)
            if nickBySrc[id] then
                TriggerClientEvent('hk-chat:client:nick', -1, id, nickBySrc[id])
            end
        end
        -- NOTE: history replay is NOT done here — each client's NUI fires
        -- `hk-chat:server:requestBootstrap` on reload, which replays its own
        -- scoped history. Doing it here too would double up. This block only
        -- warms the nick cache so displayNick works for SENDERS immediately.
        print('[hk-chat] nickname cache rebuilt for online players after restart')
    end)
end)

-- When a player's job changes, if they just became an emergency responder push
-- them the recent 911 buffer (so going on duty shows the last few live calls).
RegisterNetEvent('QBCore:Server:OnJobUpdate', function(src, job)
    if not src or src == 0 then return end
    -- send911Recent self-guards with isEmergencyResponder, which re-reads the
    -- live job + type, so this correctly covers name- and type-matched jobs.
    send911Recent(src)
end)

-- ═══════════════════════════════════════════════════════════════ --
--   Command controls (/chatadmin)                                     --
--   Two independent per-command toggles:                              --
--     noPreview → hidden from the "/" palette for non-admins          --
--     blockChat → cannot be run via the chat input by non-admins      --
--   Admins bypass BOTH and see every command in the palette.          --
-- ═══════════════════════════════════════════════════════════════ --

-- Build the settings payload the client needs (list + this viewer's admin flag).
local function buildCmdPayload()
    local list = {}
    for cmd, s in pairs(cmdSettings) do
        list[#list + 1] = { command = cmd, noPreview = s.noPreview, blockChat = s.blockChat }
    end
    return list
end

local function pushCmdSettings(target)
    if target then
        TriggerClientEvent('hk-chat:client:cmdsettings', target, buildCmdPayload(), IsChatAdmin(target))
    else
        for _, id in ipairs(GetPlayers()) do
            id = tonumber(id)
            TriggerClientEvent('hk-chat:client:cmdsettings', id, buildCmdPayload(), IsChatAdmin(id))
        end
    end
end

-- Client asks for its palette/block state on NUI load.
RegisterNetEvent('hk-chat:server:requestSettings', function()
    pushCmdSettings(source)
end)

-- Admin status changed (txAdmin auth landed after the client's initial request,
-- or a global invalidation). Re-push the affected client's admin flag + palette
-- so /chatadmin access and see-all update live without a re-login. netid -1 =
-- refresh everyone.
AddEventHandler('hk-chat:internal:adminChanged', function(netid)
    if netid == -1 then
        pushCmdSettings()
    else
        netid = tonumber(netid)
        -- Only push to a real connected player (txAdmin auth can fire for a
        -- netid with no live in-game player, e.g. the "test account" flow).
        if netid and GetPlayerName(netid) then pushCmdSettings(netid) end
    end
end)

-- Persist one command's toggles (admin only), then push live to everyone.
local function setCmd(cmd, noPreview, blockChat)
    cmdSettings[cmd] = { noPreview = noPreview, blockChat = blockChat }
    MySQL.insert(
        'INSERT INTO hk_chat_cmd_settings (command, no_preview, block_chat) VALUES (?, ?, ?) ' ..
        'ON DUPLICATE KEY UPDATE no_preview = ?, block_chat = ?',
        { cmd, noPreview and 1 or 0, blockChat and 1 or 0, noPreview and 1 or 0, blockChat and 1 or 0 }
    )
    -- If both toggles are off, drop the row entirely (clean default state).
    if not noPreview and not blockChat then
        cmdSettings[cmd] = nil
        MySQL.query('DELETE FROM hk_chat_cmd_settings WHERE command = ?', { cmd })
    end
    pushCmdSettings()
end

-- NUI (admin settings panel) toggles a command. Re-checked server-side.
RegisterNetEvent('hk-chat:server:setCmd', function(cmd, noPreview, blockChat)
    local src = source
    if not IsChatAdmin(src) then return end
    -- Normalise to lowercase: FiveM commands are case-insensitive, and the
    -- client block check lowercases too, so both sides must agree.
    cmd = tostring(cmd or ''):gsub('^/', ''):lower()
    if cmd == '' then return end
    setCmd(cmd, noPreview and true or false, blockChat and true or false)
end)

-- NOTE: block-from-chat is enforced client-side in the `submit` NUI callback
-- (checked against the server-pushed cmdSettings before ExecuteCommand). That
-- is the only layer that can gate it — chat commands run on the client, so
-- there is no server hop to intercept. This is a chat-input restriction only,
-- NOT an anti-cheat: F8 console / other resources are out of scope by design.

-- ═══════════════════════════════════════════════════════════════ --
--   Admin moderation: mutes, clear-all, remove-message               --
-- ═══════════════════════════════════════════════════════════════ --

-- Build the PLAYERS payload: every online player + their mute state.
local function buildPlayersPayload()
    local out = {}
    for _, id in ipairs(GetPlayers()) do
        id = tonumber(id)
        out[#out + 1] = {
            id = id,
            name = GetCharName(id),
            nick = nickBySrc[id] or nil,
            muted = isMuted(id),
        }
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

-- Push the full moderation payload (players + recent public messages) to an admin.
local function pushModData(src)
    if not IsChatAdmin(src) then return end
    TriggerClientEvent('hk-chat:client:moddata', src, buildPlayersPayload(), recentPublic)
end

RegisterNetEvent('hk-chat:server:requestModData', function()
    pushModData(source)
end)

-- Toggle a player's mute (admin only). Persisted by license.
RegisterNetEvent('hk-chat:server:toggleMute', function(targetId)
    local src = source
    if not IsChatAdmin(src) then return end
    targetId = tonumber(targetId)
    if not targetId or not GetPlayerName(targetId) then return end
    local lic = GetChatLicense(targetId)
    if mutes[lic] then
        mutes[lic] = nil
        MySQL.query('DELETE FROM hk_chat_mutes WHERE license = ?', { lic })
        send({ targetId }, { tab = 'global', system = true, color = '#34d399',
            text = 'You have been unmuted.' })
    else
        mutes[lic] = true
        MySQL.insert('INSERT IGNORE INTO hk_chat_mutes (license, name) VALUES (?, ?)',
            { lic, GetCharName(targetId) })
        send({ targetId }, { tab = 'global', system = true, color = '#f87171',
            text = 'You have been muted by an admin.' })
    end
    pushModData(src)  -- refresh the admin's list
end)

-- Clear chat for EVERYONE + wipe stored public history (admin only).
RegisterNetEvent('hk-chat:server:clearAll', function()
    local src = source
    if not IsChatAdmin(src) then return end
    recentPublic = {}
    MySQL.query('DELETE FROM hk_chat_history')  -- wipe all stored history
    TriggerClientEvent('hk-chat:client:clearAll', -1)
    print(('[hk-chat] %s (%s) cleared all chat + history'):format(GetPlayerName(src) or '?', src))
end)

-- Remove ONE message everywhere by its mid (admin only). Deletes from the live
-- clients, the history table, and the recent-public buffer.
RegisterNetEvent('hk-chat:server:removeMsg', function(mid)
    local src = source
    if not IsChatAdmin(src) then return end
    mid = tonumber(mid)
    if not mid then return end
    MySQL.query('DELETE FROM hk_chat_history WHERE mid = ?', { mid })
    for i = #recentPublic, 1, -1 do
        if recentPublic[i].mid == mid then table.remove(recentPublic, i) end
    end
    TriggerClientEvent('hk-chat:client:removeMsg', -1, mid)
    pushModData(src)  -- refresh the admin's recent list
end)

-- /chatadmin — opens the keyboard-navigable settings panel (admin only).
RegisterCommand('chatadmin', function(src)
    if not IsChatAdmin(src) then
        send({ src }, { tab = 'global', system = true, color = '#f87171',
            text = 'You do not have permission to manage chat.' })
        return
    end
    pushCmdSettings(src)
    pushModData(src)
    TriggerClientEvent('hk-chat:client:openAdmin', src)
end, false)

-- Suggestion registration for our own commands (shows in the palette).
CreateThread(function()
    Wait(1000)
    local ours = {
        { name = '/w',         help = 'Whisper a player privately',   params = {{ name = 'id', help = 'server id' }, { name = 'message', help = '' }} },
        { name = '/me',        help = 'Emote above your head',         params = {{ name = 'action', help = '' }} },
        { name = '/ooc',       help = 'Out-of-character (Gameplay)',   params = {{ name = 'message', help = '' }} },
        { name = '/nick',      help = 'Set your chat nickname',        params = {{ name = 'nickname', help = '' }} },
        { name = '/911',       help = 'Contact emergency services',    params = {{ name = 'message', help = '' }} },
        { name = '/announce',  help = 'Admin: broadcast announcement', params = {{ name = 'message', help = '' }} },
        { name = '/chatadmin', help = 'Admin: chat settings',          params = {} },
    }
    TriggerClientEvent('chat:addSuggestions', -1, ours)
end)
