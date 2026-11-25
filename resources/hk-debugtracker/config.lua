-- hk-debugtracker config
Config = {}

-- Master switch
Config.Enabled = true

-- Log every watched event to the server console (shows in fxserver.log)
Config.LogToConsole = true

-- Also persist watched events to MySQL table hk_event_log (auto-created).
Config.LogToDatabase = true

-- Optional Discord webhook for FLOOD ALERTS only (leave '' to disable).
Config.FloodWebhook = ''

-- Flood detection: if a single source fires more than <Count> watched
-- events within <Window> ms, raise one alert (then cool down).
Config.Flood = {
    Count      = 25,     -- events...
    Window     = 10000,  -- ...within this many ms from one source
    Cooldown   = 30000,  -- min ms between repeat alerts for the same source
}

-- Auto-prune: delete hk_event_log rows older than RetentionDays. Runs once
-- at startup and then every IntervalHours. Keeps the table from bloating.
Config.Prune = {
    Enabled       = true,
    RetentionDays = 14,
    IntervalHours = 24,
}

-- Daily summary: posts an embed to FloodWebhook with the day's top event
-- firers + totals. Fires when server clock passes HourUTC (once per day).
Config.Summary = {
    Enabled     = true,
    HourUTC     = 0,     -- 00:00 UTC (~08:00 HK time)
    TopN        = 10,    -- how many top firers to list
    Betting     = true,  -- also post a hk_sportsbets 24h P&L / house-edge block
    BettingTopN = 5,     -- top winners/losers to list in the betting block
}

-- Admin command /hktrace <playerId|citizenid> [limit] — dumps a player's
-- recent watched events to the caller's console. ACE-permission gated.
Config.Trace = {
    Command      = 'hktrace',
    AcePerm      = 'command.hktrace',  -- grant via: add_ace group.admin command.hktrace allow
    DefaultLimit = 25,
    MaxLimit     = 100,
}

-- ============================================================
-- ACTIVITY TRACKING (the "what has this player done" system)
-- Taps central buses instead of enumerating events:
--  - qb-log:server:CreateLog  (26 resources already funnel here)
--  - QBCore:Server:OnMoneyChange / OnJobUpdate / OnGangUpdate
--  - playerConnecting / OnPlayerUnload  (session join/leave)
-- Writes to hk_player_activity. Two-tier retention below.
-- ============================================================
Config.Activity = {
    Enabled       = true,
    HookCreateLog = true,   -- capture all qb-log CreateLog categories
    HookMoney     = true,   -- QBCore:Server:OnMoneyChange
    HookJobGang   = true,   -- OnJobUpdate / OnGangUpdate
    HookSession   = true,   -- connect / disconnect
    -- categories from CreateLog to IGNORE (too noisy / not player actions)
    IgnoreCategories = { 'testwebhook' },
}

-- Two-tier retention. Live table stays lean; archive is the safety net.
Config.Retention = {
    LiveDays    = 14,   -- rows older than this leave hk_player_activity...
    ArchiveDays = 60,   -- ...move to hk_player_activity_archive, kept this long
    IntervalHours = 24, -- how often the prune/archive sweep runs
}

-- Sensitive server net events to watch. These are the ones an exploiter
-- spams. Add/remove freely. The logger attaches a handler to each; FiveM
-- runs all handlers for an event, so this does not replace the real one.
Config.WatchedEvents = {
    -- inventory / items (the gb-cigarettes flood class)
    'cigarettes:server:RemoveCigarette',
    'gb-cigarettes:server:addCig',
    'qb-inventory:server:SetInventoryData',
    'qb-inventory:server:useItem',
    'qb-inventory:server:openVending',
    'qb-inventory:server:snowball',
    'QBCore:Server:SetMetaData',
    -- money / banking
    'qb-banking:server:transferMoney',
    'qb-banking:server:withdrawMoney',
    'qb-banking:server:depositMoney',
    -- common exploit targets
    'qb-shops:server:buyItem',
    'inventory:server:SetInventoryData',
    -- rental car (nc-rental) — outdated client-side spawn, investigating vehicle desync
    'nc-rental:attemptPurchase',
    'nc-rental:attemptvehiclespawn',
    'nc-rental:giverentalpaperServer',
    'nc-rental:server:payreturn',
    -- hk-sportsbetting — major money trace (stake/payout abuse + claim spam)
    'hk-sportsbetting:server:placeBet',
    'hk-sportsbetting:server:placeMultiBet',
    'hk-sportsbetting:server:claimVipWeekly',
    'hk-sportsbetting:server:claimVipDaily',
    'hk-sportsbetting:server:claimVipRakeback',
}

-- ============================================================
-- SCREENSHOT UPLOADER (Zipline -> images.example.com, origin-direct)
-- Screenshots are uploaded to Zipline and the returned https URL is embedded
-- in a normal JSON webhook. We do NOT use Discord multipart attachments (they
-- never land on this box). See sv_upload.lua / sv_screenshot.lua.
-- ============================================================
Config.Screenshot = {
    -- nginx origin for Zipline. Origin-direct to bypass the Cloudflare WAF that
    -- 403s the fxserver IP on the public host. (.247 = hk-services)
    UploadHost   = 'http://YOUR_SERVICES_HOST:8081',
    -- public host used in returned URLs (scheme stripped internally; https forced)
    ReturnDomain = 'images.example.com',
    -- server convar holding the ENCRYPTED Zipline access token (Zipline v4 form).
    -- Set in server.cfg: set hk_zipline_token "<token>"  (server-only)
    TokenConvar  = 'hk_zipline_token',
    -- jpg quality for captures (0..1)
    Quality      = 0.8,
}

-- ============================================================
-- CLIENT-INFO REDIRECT  (/hkclient <id>)
-- Full forensic dump (identifiers + HWID tokens + endpoint + live diag +
-- auto-screenshot) to a Discord webhook. ACE gated.
-- ============================================================
Config.ClientInfo = {
    Command = 'hkclient',
    AcePerm = 'command.hkclient',   -- grant: add_ace group.admin command.hkclient allow
    -- dedicated channel webhook; '' falls back to Config.FloodWebhook
    Webhook = '',
}

-- ============================================================
-- ANTICHEAT MEASUREMENT  (flag -> log -> auto-screenshot; MANUAL ban)
-- Client detection loops flag suspicious state; the server logs to
-- hk_event_log and, at a threshold, posts a screenshot + client-info to the
-- anticheat webhook. Nothing is auto-banned or auto-kicked.
-- ============================================================
Config.Anticheat = {
    Enabled = true,
    -- dedicated channel webhook for AC alerts; '' falls back to Config.FloodWebhook
    Webhook = '',
    -- how many flags before an auto-screenshot alert fires
    FlagsForScreenshot = 3,
    -- min seconds between auto-screenshots for the same player
    ScreenshotCooldown = 60,
    -- client-side per-kind debounce (ms) so one behaviour doesn't spam flags
    ClientDebounceMs = 8000,

    -- identifiers fully EXEMPT from detection (owner/staff). Keep in sync with
    -- hk-misc allowlist. These clients' detection loops stay silent.
    Exempt = {
        ['discord:YOUR_DISCORD_ID']                       = true,  -- owner (primary)
        ['license2:YOUR_LICENSE2_ID'] = true,  -- fallback
        ['fivem:YOUR_FIVEM_ID']                                     = true,  -- fallback
    },

    -- detection thresholds
    -- Detections that produce false positives from legit game systems (spawn
    -- protection, revives, cutscenes, interior transitions) are OFF by default.
    Detect = {
        Godmode  = false,   -- GetPlayerInvincible fires during spawn/revive/cutscene
        Invisible= false,   -- players are set invisible during spawn/cutscene/interior
    },

    Thresholds = {
        SuperJump     = 20.0,   -- metres of real airborne jump displacement
        MaxFootSpeed  = 13.0,   -- m/s on foot (sprint ~7, so 13 is well clear)
        FootSpeedCeil = 60.0,   -- readings above this are warp glitches, ignored
        SpeedSamples  = 4,      -- consecutive over-speed samples (~1.6s) before flag
        MaxTickMove   = 45.0,   -- metres/1s on foot to count toward noclip streak
        NoclipSamples = 3,      -- consecutive fast-move ticks (~3s) before flag
        -- any single-tick displacement >= this is treated as a TELEPORT (admin TP,
        -- apartment/garage/interior warp, spawn) -> muted, never flagged.
        TeleportFloor = 150.0,
    },

    -- spawned/blacklisted plates (menu-spawned cheat vehicles)
    BlacklistedPlates = {
        'BRUTAN',
    },

    -- curated TRAP events: admin/money/injector events a legit client never
    -- fires. Firing one raises a flag (NOT a ban). QB-relevant only — the old
    -- qb-anticheat ESX list was junk on this server.
    TrapEvents = {
        'AdminMenu:giveBank',
        'AdminMenu:giveCash',
        'AdminMenu:giveDirtyMoney',
        'adminmenu:allowall',
        'adminmenu:cashoutall',
        'adminmenu:setsalary',
        'esx:giveInventoryItem',
        'esx:removeInventoryItem',
        'esx:setJob',
        'police:cuffGranted',
        'CheckHandcuff',
        'mellotrainer:adminKick',
        'mellotrainer:adminTempBan',
        'mellotrainer:s_adminKill',
        'hentailover:xdlol',
        'HCheat:TempDisableDetection',
        'h:xd',
    },
}
