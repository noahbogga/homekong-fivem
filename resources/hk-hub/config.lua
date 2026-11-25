-- hk-hub — HOMEKONG branded launcher
-- One hub (F5) that redirects players to the various server systems so they
-- don't have to memorise commands. Encrypted [sky] scripts + hk-race are
-- launched by firing their existing client commands (ExecuteCommand).
--
-- NOTE: not named `Config` because MenuV-style clobbering isn't a factor here,
-- but we keep the HK convention of a namespaced global to be safe.
HubConfig = {}

-- Keybind (rebindable in Settings > Key Bindings > FiveM). Also /hub command.
HubConfig.OpenKey     = 'F5'
HubConfig.OpenCommand = 'hub'

-- Brand shown in the header.
HubConfig.Brand = {
    name    = 'HOMEKONG',        -- rendered HOME<accent>KONG</accent>
    tagline = '系統選單 · SYSTEMS',
}

-- Close the hub before firing the target command? (recommended: true — most
-- target UIs want NUI focus for themselves)
HubConfig.CloseOnLaunch = true

-- Small delay (ms) between closing the hub and firing the command, so the
-- target script gets a clean NUI focus handoff.
HubConfig.LaunchDelay = 120

-- Menu layout mode: 'normal' = centered card grid (default), 'minimal' = the
-- slim left-center icon rail that expands on hover. Player picks in Settings;
-- saved per-player via KVP. This is only the LAUNCHER's look — sub-views
-- (Settings/Laws/Info) always open as the full panel.
HubConfig.DefaultMenuMode = 'normal'

-- ===========================================================================
-- INFO PANEL
-- A gear button in the header opens an in-hub Info panel (no redirect). Shows
-- read-only player identity, account stats (playtime / days since joined), all
-- currency balances, plus per-user preferences. Prefs persist via FiveM KVP.
-- ===========================================================================
HubConfig.Settings = {
    enabled = true,
    label   = 'Info',
    zh      = '玩家資訊',

    -- Identity rows, in order. key must match a field the server returns
    -- (charName, steamName, fivemName, discordId, steamId, licenses).
    -- Rows with no value are shown as "—". Hidden entirely if the whole
    -- section is empty.
    identity = {
        { key = 'serverId',  label = 'Server ID',        zh = '伺服器 ID' },
        { key = 'charName',  label = 'Character',        zh = '角色名稱' },
        { key = 'job',       label = 'Job',              zh = '職業' },
        { key = 'steamName', label = 'Steam Name',       zh = 'Steam 名稱' },
        { key = 'discordId', label = 'Discord ID',       zh = 'Discord ID' },
        { key = 'steamId',   label = 'Steam ID',         zh = 'Steam ID' },
        { key = 'licenses',  label = 'Rockstar License', zh = '授權碼' },
    },

    -- Money rows (server returns money.cash / money.bank / money.homecoin).
    money = {
        { key = 'cash',     label = 'Cash',     zh = '現金',     icon = '💵', prefix = '$' },
        { key = 'bank',     label = 'Bank',     zh = '銀行',     icon = '🏦', prefix = '$' },
        { key = 'homecoin', label = 'HOMECOIN', zh = 'HOMECOIN', icon = '📀', prefix = '' },
    },

    -- hk-optimizer per-user performance mode picker. hk-optimizer exposes
    -- exports:applyMode(name)/getCurrentMode(); its editable modes are admin-
    -- tuned but every player picks one here (non-admin allowed). Choice is
    -- saved via KVP and re-applied on spawn.
    optimizer = {
        enabled = true,     -- auto-hidden if hk-optimizer isn't started
        label   = 'Performance Mode',
        zh      = '效能模式',
        desc    = 'Trade visual detail for FPS. Applies instantly.',
        -- name must match hk-optimizer OptiCfg.Modes. label/zh are display text.
        -- 'quality' is the baseline (full GTA defaults); balance = minor tweaks;
        -- fps = major tweaks.
        modes = {
            { name = 'quality', label = 'Quality',       zh = '畫質 · 預設', icon = '✨' },
            { name = 'balance', label = 'Balanced',      zh = '平衡',        icon = '⚖️' },
            { name = 'fps',     label = 'Enhanced FPS+',  zh = '高幀率',      icon = '🚀' },
        },
        default = 'quality',
    },

    -- hk-speedo display-mode picker (replaces the /speedo F6 cycle). hk-speedo
    -- owns SQL persistence; hk-hub just fires hk-speedo:setMode and reads the
    -- current mode via hk-speedo:requestMode → hk-speedo:currentMode.
    speedo = {
        enabled = true,     -- auto-hidden if hk-speedo isn't started
        label   = 'Speedometer',
        zh      = '車速錶',
        desc    = 'Display style. Lite = best FPS, Full = max glow.',
        modes = {
            { name = 'normal',  label = 'Normal',  zh = '標準 · 建議', icon = '🎯' },
            { name = 'lite',    label = 'Lite',    zh = '輕量 · 最省', icon = '🪶' },
            { name = 'full',    label = 'Full',    zh = '完整 · 最華麗', icon = '💎' },
            { name = 'minimal', label = 'Minimal', zh = '極簡',        icon = '▪️' },
        },
        default = 'normal',
    },

    -- Launch rows: open an external (encrypted/standalone) settings menu that
    -- can't be embedded, by firing its command. Shown as a button in Settings.
    --   command = client command to ExecuteCommand
    --   resource = optional; row auto-hides if that resource isn't started
    launchers = {
        { id = 'armenu', label = 'AR 導航設定', zh = '路線箭頭 · 轉向指示 · 羅盤',
          desc = 'GPS 路線 AR 導航系統設定', btn = '開啟',
          command = 'armenu', resource = 'frkn-waypoint' },
    },

    -- Placeholder prefs shown as "coming soon" (disabled) until their backing
    -- system ships. Remove/flip `soon` when ready.
    placeholders = {
        { id = 'speedo_color', label = 'Speedo Colour', zh = '車速錶顏色',
          desc = 'Personalise your speedometer accent.', soon = true },
    },
}

-- ===========================================================================
-- MENU ITEMS
-- Rendered in this exact array order. To add a system later, drop a new entry
-- in the right spot. Fields:
--   id       unique string
--   label    English title
--   zh       Traditional Chinese title (shown under the English one)
--   sub      short one-line description
--   icon     emoji glyph shown on the tile
--   accent   optional hex; tile hover glow (defaults to the theme accent)
--   command  client command to ExecuteCommand when the tile is chosen
--   event    (alt to command) a client event to TriggerEvent instead — use
--            when the target has no client command (e.g. server-registered).
--            eventArgs = optional table of args passed to the event.
--   view     (alt to command/event) opens an in-hub view instead of redirecting.
--            Supported: 'laws' (legal reader), 'keybinds' (hotkey reference),
--            'report' (feedback form), 'squad' (team panel).
--   link     (alt to command/event/view) an external URL. The NUI only sends the
--            tile id; Lua looks the URL up here and opens the browser (openUrl).
--            FiveM shows its own one-time "open link?" prompt — unavoidable.
--            Also reachable via /discord for the community-invite tile.
--   section  optional group heading (tiles with the same section are grouped)
--   gate     optional runtime visibility check (a named check in client/main.lua's
--            GATES table). The tile is only built/shown when the check returns true.
--            Currently: 'dispatch' → player's job may use ps-dispatch (job + on duty).
-- ===========================================================================
HubConfig.Items = {
    -- ---- Rewards & Shop (the [sky] suite) --------------------------------
    {
        id      = 'shop',
        label   = 'Coin Shop',
        zh      = 'HOMECOIN 商店',
        sub     = 'Cases · VIP · test drives',
        icon    = 'fa-cart-shopping',
        accent  = '#f5c518',
        command = 'vipshop',        -- sky_coinsystem
        section = '獎勵 · REWARDS',
    },
    {
        id      = 'battlepass',
        label   = 'Battle Pass',
        zh      = '戰鬥通行證',
        sub     = 'Seasonal free & premium tracks',
        icon    = 'fa-medal',
        accent  = '#b388ff',
        command = 'battlepass',     -- sky_battlepass
        section = '獎勵 · REWARDS',
    },
    {
        id      = 'daily',
        label   = 'Daily Rewards',
        zh      = '每日獎勵',
        sub     = '30-day login calendar',
        icon    = 'fa-calendar-day',
        accent  = '#34d399',
        command = 'dailyreward',    -- sky_dailyrewards
        section = '獎勵 · REWARDS',
    },

    -- ---- Tools -----------------------------------------------------------
    -- NOTE: HUD settings are no longer a tile — they live in the ⚙ settings
    -- panel (top-right) alongside player info + speedo settings.
    {
        id      = 'squad',
        label   = 'Squad',
        zh      = '小隊',
        sub     = 'Team up · blips · radio · waypoints',
        icon    = 'fa-users',
        accent  = '#00c8ff',
        view    = 'squad',          -- opens the in-hub squad panel
        section = '工具 · TOOLS',
    },
    {
        id      = 'race',
        label   = 'Street Races',
        zh      = '街頭賽車',
        sub     = 'Browse tracks · host a race',
        icon    = 'fa-flag-checkered',
        accent  = '#00c8ff',
        command = 'racemenu',       -- hk-race
        section = '工具 · TOOLS',
    },
    {
        id      = 'dispatch',
        label   = 'Dispatch',
        zh      = '勤務調度',
        sub     = 'Active calls · MDT alerts',
        icon    = 'fa-tower-broadcast',
        accent  = '#f87171',
        event   = 'hk-hub:client:openDispatch',  -- opens ps-dispatch via export (see client)
        gate    = 'dispatch',                     -- only shown to on-duty dispatch jobs
        section = '工具 · TOOLS',
    },
    {
        id      = 'billing',
        label   = 'Billing',
        zh      = '帳單系統',
        sub     = 'Create & send invoices',
        icon    = 'fa-file-invoice-dollar',
        accent  = '#00c8ff',
        command = 'billing',        -- hk-billing
        section = '工具 · TOOLS',
    },
    {
        id      = 'documents',
        label   = 'Documents',
        zh      = '證件文件',
        sub     = 'Licenses · certificates · docs',
        icon    = 'fa-id-card',
        accent  = '#34d399',
        command = 'doc',            -- hk-documents
        section = '工具 · TOOLS',
    },
    {
        id      = 'emotes',
        label   = 'Emotes',
        zh      = '表情動作',
        sub     = 'Emotes · dances · walk styles',
        icon    = 'fa-person-walking',
        accent  = '#f472b6',
        -- dpemotes registers /emotemenu server-side; fire its client event directly.
        event   = 'animations:client:EmoteMenu',
        section = '工具 · TOOLS',
    },

    -- ---- Info ------------------------------------------------------------
    {
        id      = 'laws',
        label   = 'Laws',
        zh      = '法律條文',
        sub     = 'Constitution · traffic · penalties',
        icon    = 'fa-scale-balanced',
        accent  = '#fbbf24',
        view    = 'laws',           -- opens the in-hub law reader
        section = '資訊 · INFO',
    },
    {
        id      = 'keybinds',
        label   = 'Keybinds',
        zh      = '按鍵綁定',
        sub     = 'Driving · tools · menu hotkeys',
        icon    = 'fa-keyboard',
        accent  = '#00c8ff',
        view    = 'keybinds',       -- opens the in-hub keybinds reference
        section = '資訊 · INFO',
    },
    {
        id      = 'discord',
        label   = 'Join Discord',
        zh      = '加入 Discord',
        sub     = 'Community · support · updates',
        icon    = 'fa-discord',      -- Font Awesome BRANDS icon (fa-brands)
        accent  = '#5865f2',         -- Discord blurple
        link    = 'https://discord.gg/YOUR_INVITE',  -- opened in the player's browser
        section = '資訊 · INFO',
    },
    {
        id      = 'report',
        label   = 'Feedback',
        zh      = '意見回饋',
        sub     = 'Report a bug · send feedback',
        icon    = 'fa-bug',
        accent  = '#f87171',
        view    = 'report',         -- opens the in-hub feedback form
        section = '資訊 · INFO',
    },
    {
        id      = 'referral',
        label   = 'Referrals',
        zh      = '推薦好友',
        sub     = 'Invite friends · earn rewards',
        icon    = 'fa-gift',
        accent  = '#40a3b9',
        command = 'referrals',      -- sky_referrals
        section = '資訊 · INFO',
    },
}

-- ===========================================================================
-- BUG REPORT / FEEDBACK  (button lives in the ⚙ Info tab)
-- Players describe an issue (min word count enforced client AND server side),
-- optionally attach a screenshot, and we auto-collect a diagnostic snapshot;
-- everything is posted to a Discord webhook. F8/console logs are NOT readable
-- by any resource (FiveM sandbox) — instead we send auto-collected telemetry
-- plus a rolling in-script event buffer other HK resources can push to via
-- TriggerEvent('hk-hub:client:log', tag, message).
-- ===========================================================================
HubConfig.Report = {
    enabled = true,

    -- SERVER-ONLY. Never sent to the NUI/client. Paste your Discord webhook URL.
    -- Leave as '' to disable posting (submissions will no-op with an error).
    webhook = '',

    username  = 'HOMEKONG Reports',
    avatar    = '',                 -- optional avatar_url for the webhook message

    minChars  = 20,                 -- min CHARACTERS in the "what happened" field
    minStepChars = 20,              -- min CHARACTERS in the "steps to reproduce" field
    cooldown  = 180,                -- seconds between reports per player (anti-spam)

    -- Screenshots now work via hk-debugtracker's UploadImage export: capture ->
    -- base64 -> phone-upload relay (.247:3090) -> Zipline https URL -> JSON embed.
    -- (Discord multipart attachments never landed on this box; the relay path
    -- sidesteps PerformHttpRequest's null-byte truncation. See hk-debugtracker.)
    screenshot        = true,       -- master switch for the whole screenshot feature
    screenshotDefault = true,       -- (if enabled) is the toggle on by default
    screenshotQuality = 0.7,        -- jpg quality 0..1

    embedColor = 3447003,           -- single embed colour for all feedback (blue)
}

-- ===========================================================================
-- KEYBINDS  (read-only reference view, opened from the ⚙ Info tab)
-- Mirrors the hotkey tips shown on the hk-loading screen so players can look
-- them up again in-game. Grouped; each row = { key, label, sub? }.
-- NOTE: keep in sync with hk-loading/html/app.js if those defaults change.
-- ===========================================================================
HubConfig.Keybinds = {
    enabled = true,
    groups = {
        {
            title = '駕駛 · DRIVING',
            keys = {
                { key = 'K / J',   label = '升 / 降檔',   sub = '油車換檔 · 電車回充 D1-D3' },
                { key = 'L·SHIFT', label = '離合 / 滑行', sub = 'Clutch · DCT→自動 · 電車→Coast' },
                { key = 'K + J',   label = '入空檔',       sub = 'Hold 兩鍵 · 連按=鎖定空檔' },
                { key = 'G',       label = '動力模式',     sub = '長按: 電動→混合→引擎 · 單按開關引擎' },
                { key = 'CAPS',    label = '甩尾模式',     sub = 'Hold — Drift Mode' },
            },
        },
        {
            title = '工具 · TOOLS',
            keys = {
                { key = 'F6', label = '切換車速錶', sub = '4 種模式循環 · /speedo' },
                { key = 'F7', label = '賽事鏡頭',   sub = '切換 追car / 引擎蓋 視角' },
                { key = 'F4', label = '鎖定鏡頭',   sub = 'Race Cam 鎖定/解鎖' },
                { key = 'Y',  label = '定速巡航',   sub = 'Cruise Control' },
                { key = 'B',  label = '安全帶',     sub = 'Seatbelt' },
            },
        },
        {
            title = '選單 · MENU',
            keys = {
                { key = 'F5',  label = '主選單',   sub = 'HK Hub 導航' },
                { key = 'M',   label = '電話',     sub = 'Phone' },
                { key = 'TAB', label = '物品庫',   sub = 'Inventory' },
                { key = 'F1',  label = '圓形選單', sub = 'Radial Menu' },
                { key = 'X',   label = '舉手',     sub = 'Hands Up' },
            },
        },
    },
    -- Footer note shown under the groups.
    note = '所有按鍵可於 FiveM 設定 → 按鍵綁定 中自訂。 All keys are rebindable in FiveM Settings → Key Bindings.',
}

-- ===========================================================================
-- SQUAD  (Tools tile → in-hub team panel)
-- Small 4-person crew system ported from af-squad but rebuilt for hk-hub:
-- QBCore callbacks (no ox_lib), HK design NUI, real GTA minimap/pause-map blips
-- with member names, over-head DUI name/distance tags, a shared pan/zoom atlas
-- map with waypoints, and a private pma-voice radio channel per squad.
-- Persisted in the hk_squad_* tables (see sql/hk_squad.sql).
-- ===========================================================================
HubConfig.Squad = {
    enabled = true,

    -- Total members INCLUDING the leader. Enforced on both invite and accept.
    limit = 6,

    -- Blips for squadmates on the real minimap + pause map (name + colour).
    blips = {
        enabled = true,
        sprite  = 1,       -- standard round blip
        scale   = 0.85,
        -- Colour cycle assigned per member slot (GTA blip colour IDs).
        -- ONLY "safe" IDs (no enemy/friendly flag variant — avoid 2,3,4,5,49,66,67,68,69
        -- which the game recolours red/blue via relationship flags).
        -- Colours are the ACTUAL GTA blip renders (see BLIP_RGB / picker):
        -- 46=gold, 38=blue, 11=light green, 0=white. Leader always gets `leader`.
        leader  = 46,      -- gold for the squad leader
        palette = { 38, 11, 0 },  -- blue / green / white for members
        showNames = true,        -- put the member's name on the blip
    },

    -- Shared-waypoint blips on the real minimap/pause map. Each member toggles
    -- these per-waypoint (hidden → shown → flashing) from the squad panel; the
    -- state is client-local so it persists on the minimap with the panel closed.
    waypointBlip = {
        sprite = 1,     -- standard round blip
        scale  = 0.9,
        shortRange = false,   -- keep visible on the full pause map, not just nearby
    },

    -- Over-head DUI tags (name + live distance) above teammates.
    tags = {
        enabled     = true,
        maxDistance = 250.0,   -- metres; tag hidden past this
    },

    -- Always-on member overlay (top-right HUD). One card per ONLINE teammate
    -- with portrait, health bar, distance, and a mic ring that lights while they
    -- talk. Client-local signals (health/distance/mic), refreshed on a fast tick.
    overlay = {
        enabled   = true,
        refreshMs = 250,       -- how often health/distance/mic recompute
        hideSolo  = true,      -- hide entirely when you're the only online member
        maxDistance = 8000.0,  -- metres; distance shown up to here (else "far")
    },

    -- pma-voice squad radio. Each squad is auto-assigned a private channel.
    -- pma-voice only allows ONE radio channel at a time, so an on-duty cop's job
    -- radio and the squad radio can't both be active — the panel has a toggle to
    -- switch. PTT uses pma-voice's own +radiotalk keybind (no new bind here).
    radio = {
        enabled   = true,      -- auto-disabled if pma-voice isn't started
        -- Squad channels live in a high band so they never collide with job
        -- radios (which use low channel numbers). channel = base + squadID.
        baseChannel = 900000,
        autoJoin  = true,      -- join the squad radio automatically on create/join
    },

    -- Vanilla pan/zoom atlas map inside the panel. Calibration ported from
    -- af-squad's client/groups.lua (atlas1.webp is 1920x2377). world→normalized.
    atlas = {
        enabled   = true,
        image     = 'html/atlas1.webp',   -- also listed in fxmanifest files{}
        widthPx   = 1920.0,
        heightPx  = 2377.0,
        zeroXPx   = 980.3,
        zeroYPx   = 1580.7,
        scaleX    = 0.1995,
        scaleY    = 0.1995,
        invertX   = false,
        invertY   = true,
    },
}
