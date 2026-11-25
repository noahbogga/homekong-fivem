-- ═══════════════════════════════════════════════════════════════ --
--   HK-CHAT CONFIG (shared)                                           --
-- ═══════════════════════════════════════════════════════════════ --
Config = {}

-- Key that opens the chat panel. 245 = INPUT_MP_TEXT_CHAT_ALL (the stock "T").
Config.OpenControl = 245

-- How many recent messages the idle (top-left) feed shows before it fades.
Config.IdleMessages = 6
-- Milliseconds the idle feed stays visible after a new message, then fades.
Config.IdleFadeAfter = 12000

-- Chat history replay on join (per scope). PUBLIC = global/ooc/announce
-- (everyone). JOB = only your own job's recent lines. WHISPER = only whispers
-- you personally sent or received. No player ever sees another's DMs or another
-- job's chat — replay is scoped server-side by license / job room.
Config.HistoryReplay = 12          -- public lines
Config.JobHistoryReplay = 12       -- your job's lines
Config.WhisperHistoryReplay = 15   -- your own whispers
-- Total rows kept in the DB before oldest are pruned (rows are tiny).
Config.HistoryKeep = 1000

-- /911 rolling buffer: recent calls on-duty responders see (never persisted,
-- never shown to normal players). Count + max age (ms) before a call drops out.
Config.Recent911 = 10
Config.Recent911MaxAge = 900000    -- 15 minutes

-- ─── Send cooldown (anti-spam) ───────────────────────────────────── --
-- One SHARED 5s cooldown per player across all channels: any send (chat OR
-- command) greys out the whole input bar for this long. Server-enforced.
Config.SendCooldown = 5000          -- ms
-- Jobs exempt from the cooldown (fast emergency comms). Exact job names.
Config.CooldownExemptJobs = {
    'police', 'ambulance',
}
-- Job TYPES also exempt (leo covers police+fbi; use only 'ems'+... if you want
-- to exempt by type instead). Left EMPTY on purpose: you asked for police +
-- ambulance ONLY, and fbi is type 'leo' — so we exempt by NAME, not type.
Config.CooldownExemptJobTypes = {}

-- Max characters accepted for a single chat line (server-enforced too).
Config.MaxMessageLength = 256
-- Nickname constraints (server-enforced).
Config.NicknameMin = 2
Config.NicknameMax = 20

-- Placeholder / bucket name shared by every jobless player for the Job tab.
Config.UnemployedRoom = 'unemployed'

-- PHASE 2: player-made group chats. Left off until the core shell is proven.
Config.EnableGroups = false

-- /me floating 3D text: how long it stays over the head (ms) + view distance (m).
Config.EmoteDuration = 8000
Config.EmoteDistance = 20.0

-- Owner identifier fallback for admin (see core/framework/server.lua). Only
-- needed for someone who must be a chat admin WITHOUT being a server admin.
-- Same format as hk-scenario's allowlist. Server-side only, never downloaded.
Config.AdminAllowlist = {
    -- ['discord:YOUR_DISCORD_ID'] = true,  -- example
}

-- ─── Channels / Tabs ─────────────────────────────────────────────── --
-- order = Tab-key cycle order. `post`:
--   'all'   → anyone can type into it
--   'none'  → read-only (no free typing; still shows messages)
--   'admin' → only chat admins can post
-- `identity`: 'nick' shows [id] Nickname, 'char' shows the RP character name.
-- `aggregate = true` → this tab ALSO mirrors messages the viewer can see from
--   other channels (Global is the unified personal feed).
Config.Tabs = {
    { id = 'global',   label = 'GLOBAL',   zh = '公頻', post = 'all',  identity = 'nick', color = '#00c8ff', aggregate = true },
    { id = 'gameplay', label = 'GAMEPLAY', zh = '遊戲', post = 'none', identity = 'char', color = '#fbbf24' },
    { id = 'job',      label = 'JOB',      zh = '工作', post = 'all',  identity = 'char', color = '#34d399' },
    { id = 'whisper',  label = 'WHISPER',  zh = '密語', post = 'none', identity = 'nick', color = '#c084fc' },
    -- Phase 2 (hidden while EnableGroups = false):
    { id = 'groups',   label = 'GROUPS',   zh = '群組', post = 'all',  identity = 'nick', color = '#f472b6', phase2 = true },
}

-- Which channels also mirror into GLOBAL for the viewer. Whisper/job only for
-- players actually in them (server enforces recipients).
Config.GlobalAggregates = { 'gameplay', 'job', 'whisper' }

-- Commands ALWAYS hidden from the palette for normal players (seeds DB on first
-- boot; DB is the live source of truth after). Admins still see everything.
Config.DefaultHiddenCommands = {
    'quit', 'con_miniconChannels', 'strdbg', 'netgraph', 'profile_start',
    'profile_stop', 'svgfx', 'cl_drawperf', 'txaKickAll',
}

-- /911 emergency call. The GAMEPLAY echo is PRIVATE: only the caller and
-- players in one of EmergencyJobs see it — never normal players, never Global,
-- never saved to history. It still fires ps-dispatch normally.
Config.SystemEchoCommands = {
    ['911'] = { label = 'EMERGENCY', color = '#f87171' },
}

-- Who receives /911 calls (emergency responders). Two ways to match, either
-- one qualifies:
--   EmergencyJobs      — exact job names (from qb-core/shared/jobs.lua)
--   EmergencyJobTypes  — QBCore job `type` field (police/fbi = "leo",
--                        ambulance = "ems"). Future-proof: any new leo/ems
--                        job is covered automatically without editing this.
Config.EmergencyJobs = {
    'police', 'ambulance', 'fbi',
}
Config.EmergencyJobTypes = {
    'leo', 'ems',
}

-- Timestamp format shown on every line. Server stamps HH:MM (24h, server time).
Config.ShowTimestamps = true

-- ─── Content filter (server-side, admins exempt) ─────────────────── --
-- Blocks a message (and tells the sender) if it contains a link, an IP, or a
-- phrase from Blocklist. NOT a swear filter — targets links/IPs/scam phrases.
Config.ContentFilter = {
    enabled     = true,
    blockLinks  = true,   -- http(s)://, www., discord.gg, bare domains like x.com
    blockIPs    = true,   -- 1.2.3.4  and  1.2.3.4:30120
    -- Exact substrings to block (case-insensitive). Not regex — plain text.
    -- Use for competitor server names, known scam phrases, etc.
    Blocklist = {
        -- 'joinmyserver', 'free money', 'other-server-name',
    },
    -- Message shown to the sender when their line is blocked.
    Notice = 'Message blocked: links, IPs, and certain phrases are not allowed.',
}

-- ─── txAdmin notification integration ────────────────────────────── --
-- Render txAdmin's server events inside hk-chat instead of its own popups.
-- IMPORTANT: to actually REPLACE the stock popups you must tick the matching
-- "Hide X Notification" boxes in txAdmin → Settings → Game → Notifications.
-- If you DON'T tick them, you'll see BOTH txAdmin's popup and our chat line.
-- Each toggle below just controls whether hk-chat renders that event.
Config.TxAdmin = {
    announcements = true,   -- txAdmin:events:announcement  → GAMEPLAY (ANNOUNCE)
    dms           = true,   -- txAdmin:events:playerDirectMessage → whisper (from ADMIN)
    warnings      = true,   -- txAdmin:events:playerWarned  → GAMEPLAY (WARNING, private)
    restarts      = true,   -- txAdmin:events:scheduledRestart → GAMEPLAY (RESTART)
}
