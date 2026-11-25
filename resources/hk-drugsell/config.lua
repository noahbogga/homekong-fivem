Config = {}

-- ─── Framework ────────────────────────────────────────────────────────────────
Config.Framework = 'QBCore'
Config.Inventory = 'qb-inventory'

-- ─── Discord Webhook Logging ──────────────────────────────────────────────────
Config.DiscordWebhook = ''
Config.DiscordUsername = 'Drug Sell Log'
Config.DiscordAvatar   = 'https://i.imgur.com/8hMQBmx.png'

-- ─── Police Dispatch ──────────────────────────────────────────────────────────
Config.DispatchSystem = 'ps-dispatch'
Config.DispatchChance = 0.40

-- ─── Blacklisted Jobs ─────────────────────────────────────────────────────────
Config.BlacklistedPlayerJobs = {
    'whitehouse',
    'congress',
    'fbi',
    'police',
}

-- ─── Cop Detection ────────────────────────────────────────────────────────────
Config.CopWarningRadius = 20.0
Config.PoliceJobs = { 'police', 'fbi' }

Config.CopWarningMessages = {
    "此位置正進行大茶飯活動！",
}

-- ─── Interaction Settings ─────────────────────────────────────────────────────
-- Max distance for qb-target to show option on peds
Config.TargetDistance = 2.0

-- Chance (0.0 - 1.0) that NPC goes aggressive
Config.AggroChance = 0.20

-- Chance (0.0 - 1.0) that NPC calls police after rejecting a deal
-- Scaled by time: daytime x1.5, nighttime x0.4
Config.PoliceCallChance = 0.25

-- Chance (0.0 - 1.0) NPC goes aggro when price is WAY too high (deep red zone)
Config.PriceAggroChance = 0.30

-- Chance (0.0 - 1.0) NPC counter-offers instead of flat rejecting
Config.CounterOfferChance = 0.40

Config.AggroWeapons = {
    'WEAPON_UNARMED',
    'WEAPON_SWITCHBLADE',
    'WEAPON_PISTOL',
}

Config.AggroMessages = {
    "信唔信我打柒你？",
    "撞到個癲佬...",
    "條友好似痴咗線！",
}

-- Chance (0.0 - 1.0) NPC pays above happy threshold
Config.BonusPayChance = 0.35

-- ─── Sell to Drivers (vehicle window) ─────────────────────────────────────────
-- Lets you walk up to a stopped car and sell to the driver through the window.
-- Reuses the whole normal dialog/AI flow — the driver just doesn't get out.
Config.Vehicle = {
    enabled        = true,
    driverSeatOnly = true,   -- only the driver, never passengers
    targetDistance = 3.0,    -- you lean into the window, so a touch further
    maxSpeed       = 2.5,    -- m/s — car must be basically stopped to interact

    -- The yeet: at handover, small chance the driver just grabs the drugs and
    -- floors it without paying. You lose the product — unless you catch them.
    yeetChance      = 0.08,  -- of completed car deals, chance it's a robbery
    yeetShootChance = 0.40,  -- of yeets, chance they also shoot at you first
    yeetShots       = 3,     -- rough burst count before they peel off

    -- Recovery: kill the robber and search the body to get YOUR drugs back.
    -- The stolen stack is banked server-side against that robber (single-use,
    -- keyed to you) so there's no dupe — you recover exactly what was taken.
    recoverFromBody = true,
    recoverLabel    = '搜身攞返貨',
    recoverDistance = 1.8,
}

-- Cooldown (ms) per ped before you can sell to them again
Config.PedCooldown = 300000

-- ─── Blacklisted Ped Models ──────────────────────────────────────────────────
Config.BlacklistedModels = {
    `s_m_y_cop_01`, `s_m_y_sheriff_01`, `s_m_y_hwaycop_01`,
    `s_f_y_cop_01`, `s_m_y_swat_01`, `s_m_y_uscg_01`,
    `s_m_m_paramedic_01`, `s_f_y_paramedic_01`,
    `s_m_m_doctor_01`, `s_f_m_doctor_01`,
    `s_m_m_fiboffice_01`, `s_m_m_fiboffice_02`,
    `s_m_y_marine_01`, `s_m_y_marine_02`, `s_m_y_marine_03`,
    `s_m_m_marine_01`, `s_m_m_marine_02`,
    `u_m_y_missionrow_01`,
    `a_m_m_afriamer_01`,
}

-- ─── Valid Ped Gate (street pedestrians ONLY) ──────────────────────────────────
-- Prevents the "Sell Drugs" target from ever attaching to animals (dogs/cats),
-- companion/pet peds, or peds spawned by OTHER scripts (jobs, missions, MLO
-- staff, event NPCs, etc). Only ambient pedestrians the GTA engine spawned into
-- the world on its own can be sold to.
Config.OnlyAmbientPeds = true

-- Reject anything that isn't a human ped (blocks all animals outright).
Config.RequireHumanPed = true

-- Reject "mission entities" — peds flagged as owned by a script/resource.
-- Companion animals and keep-pets are mission entities, as are job/quest NPCs.
Config.RejectScriptedPeds = true

-- Allowed population types (from GetEntityPopulationType). These are the
-- ambient street-spawn buckets. Everything else — PERMANENT(0), MISSION(6),
-- TOOL/edit(7) — is rejected so we never collide with scripted peds.
--   1 = RANDOM_PERMANENT   (scenario/ambient regulars)
--   2 = RANDOM_PARKED      (peds tied to parked ambient vehicles)
--   3 = PATROL             (ambient patrol wanderers)
--   4 = SCENARIO           (ambient scenario peds — benches, smoking, etc)
--   5 = RANDOM_AMBIENT     (the standard wandering street crowd)
Config.AllowedPedPopulationTypes = {
    [1] = true,
    [2] = true,
    [3] = true,
    [4] = true,
    [5] = true,
}

-- ─── Drug Difficulty Modifiers ─────────────────────────────────────────────────
-- Each drug has a 'difficulty' (1-4). These modifiers scale per difficulty level:
--   aggroMult: multiplied with Config.PriceAggroChance (higher = more aggro)
--   counterMult: multiplied with Config.CounterOfferChance (lower = less counter-offers)
--   toleranceMult: multiplied with NPC tolerance (lower = NPCs pay less for it)
--   rejectChance: flat chance NPC just says "nah" and won't buy this drug at all
Config.DifficultyModifiers = {
    [1] = { aggroMult = 0.5, counterMult = 1.3, toleranceMult = 1.2, rejectChance = 0.05 },  -- Easy
    [2] = { aggroMult = 0.8, counterMult = 1.0, toleranceMult = 1.0, rejectChance = 0.10 },  -- Normal
    [3] = { aggroMult = 1.2, counterMult = 0.7, toleranceMult = 0.85, rejectChance = 0.20 }, -- Medium
    [4] = { aggroMult = 1.8, counterMult = 0.5, toleranceMult = 0.70, rejectChance = 0.35 }, -- Hard
}

-- ─── NPC Buy Quantity ──────────────────────────────────────────────────────────
-- How much the NPC wants to buy (random roll)
-- Format: { chance = 0.0-1.0, min = X, max = Y }
-- Chances should add up to 1.0
Config.BuyQuantity = {
    { chance = 0.70, min = 1, max = 3 },   -- Normal: 1-3 units
    { chance = 0.20, min = 4, max = 8 },   -- Medium buy: 4-8 units
    { chance = 0.10, min = 9, max = 15 },  -- Rare bulk: 9-15 units
}

-- ─── NPC Price Tolerance ──────────────────────────────────────────────────────
-- How willing the NPC is to pay high prices (random roll)
-- tolerance = how far up the price range they'll accept (0.0 = min only, 1.0 = pays max)
-- Format: { chance = 0.0-1.0, min = X, max = Y }
-- Chances should add up to 1.0
Config.NpcTolerance = {
    { chance = 0.10, min = 0.15, max = 0.30 },  -- Cheapskate: only low prices
    { chance = 0.55, min = 0.35, max = 0.60 },  -- Normal buyer
    { chance = 0.25, min = 0.60, max = 0.80 },  -- Generous: pays above average
    { chance = 0.10, min = 0.85, max = 1.00 },  -- Dumb ahh: pays almost anything
}

-- ─── Drugs ────────────────────────────────────────────────────────────────────
Config.Drugs = {
    {
        id         = 'bagged_weed',
        label      = '一包大麻',
        item       = 'bagged_weed',
        icon       = 'fa-leaf',
        color      = '#3ecf7c',
        difficulty = 1,
        minPrice   = 8000,
        maxPrice   = 17000,
        happyPrice = 8000,
        description = '唔好再食重慶貨喇！',
    },
    {
        id         = 'coke_action_figure',
        label      = '筋肉可卡因',
        item       = 'coke_action_figure',
        icon       = 'fa-snowflake',
        color      = '#e8eaf2',
        difficulty = 3,
        minPrice   = 20000,
        maxPrice   = 50000,
        happyPrice = 18000,
        description = '琛哥的可卡因！',
    },
    {
        id         = 'meth',
        label      = '一包冰毒',
        item       = 'meth',
        icon       = 'fa-flask',
        color      = '#5e7bf5',
        difficulty = 3,
        minPrice   = 30000,
        maxPrice   = 70000,
        happyPrice = 20000,
        description = '一包為你注入快樂強電！',
    },
    {
        id         = 'lsd_tablets',
        label      = 'LSD貼紙',
        item       = 'lsd_tablets',
        icon       = 'fa-stamp',
        color      = '#e643f5',
        difficulty = 2,
        minPrice   = 2000,
        maxPrice   = 5000,
        happyPrice = 1500,
        description = '世界變得更加有色彩！',
    },
}

-- ─── Dialog Lines ─────────────────────────────────────────────────────────────
Config.NPCGreetings = {
    "我想問有啲咩幫到你呀?",
    "係咪有啲咩開心事呀",
    "你有咩就講！",
    "請問有啲咩事?",
    "你有屁就放！我今日好趕時間！",
    "咩料?",
}

Config.SellOffers = {
    "我手頭上有啲正嘢啊喂！",
    "點稱呼呀?",
    "他手上疑似的是重慶貨...",
    "知唔知咩係靚貨！",
    "今日想唔想同我一齊上九重天？",
    "唔知呢個價錢啱唔啱你？",
    "我哋再次登月！",
}

Config.PriceTooHighReactions = {
    "你啲價錢實在太離譜喇!",
    "唔係你啲貨食唔起！係重慶貨更加有性價比!",
    "算喇！呢個唔係我想要嘅價錢！",
    "你唔好去搶？",
    "你仲好過去搶喎？",
    "咩價錢嚟㗎！你有冇離譜啲？",
}

Config.CounterOfferLines = {
    "我淨係畀到 $%s, 唔做就罷就！",
    "一口價 $%s, 最後讓步！",
    "我希望價錢可以好啲！ $%s 有冇得傾?",
    "$% ！唔再講價!",
}

Config.PriceAcceptedReactions = {
    "愉快嘅交易！",
    "唔該曬!",
    "正斗！",
    "下次再支持!",
    "生意興隆呀老友！",
}

-- ─── AI Dialog (hk-npc-gateway) ───────────────────────────────────────────────
-- When enabled, NPC spoken lines are generated live by the Cantonese AI model
-- (via the HOMEKONG gateway on .247). The Lua/NUI side still owns EVERY
-- mechanical decision (accept/reject/counter/aggro/price) — the AI only writes
-- the spoken line. If the gateway is slow, queued, or down, we instantly fall
-- back to the static Config lines above, so gameplay never blocks on the model.
Config.AI = {
    -- POSTPONED until player counts rise. With this false, aiLine() (client) and
    -- the server proxy both short-circuit and every dialog beat uses its static
    -- Config Cantonese line — zero gateway calls. Flip back to true to re-enable.
    enabled     = false,
    persona     = 'drugdealer_01',
    -- Gateway is server-side only (clients can't reach the .247 LAN host); the
    -- server proxies the call. These are read by server/main.lua.
    url         = 'http://YOUR_SERVICES_HOST:3089/npc',
    token       = 'CHANGE_ME_NPC_GATEWAY_TOKEN',
    timeoutMs   = 2500,   -- must be <= gateway timeout; fallback fires past this
    -- Only override the static line when the gateway actually produced a line
    -- from the model or cache. If the gateway itself fell back (source=fallback),
    -- keep our own beat-specific Cantonese line instead of a generic one.
    useOnlyLiveOrCache = true,
}
