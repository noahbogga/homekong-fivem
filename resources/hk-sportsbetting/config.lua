Config = {}

Config.CacheTime = 600
Config.MaxBet = 10000000
Config.MinBet = 20
Config.MaxPayout = 20000000

Config.TrendingCacheHours = 6

Config.FetchInterval = {
    priority = 900,
    normal = 1800,
}

Config.SportCategories = {
    {
        id = "soccer",
        label = "Football",
        icon = "soccer",
        sports = {
            { key = "soccer_epl", label = "Premier League", sharp = {sport="soccer", league="england_-_premier_league"} },
            { key = "soccer_spain_la_liga", label = "La Liga", sharp = {sport="soccer", league="spain_-_la_liga"} },
            { key = "soccer_germany_bundesliga", label = "Bundesliga", sharp = {sport="soccer", league="1._bundesliga"} },
            { key = "soccer_italy_serie_a", label = "Serie A", sharp = {sport="soccer", league="italy_-_serie_a"} },
            { key = "soccer_france_ligue_one", label = "Ligue 1", sharp = {sport="soccer", league="france_-_ligue_1"} },
            { key = "soccer_efl_champ", label = "EFL Championship", sharp = {sport="soccer", league="england_-_championship"} },
            { key = "soccer_usa_mls", label = "MLS", sharp = {sport="soccer", league="usa_-_mls"} },
            { key = "soccer_brazil_campeonato", label = "Brasileirao", sharp = {sport="soccer", league="brazil_-_serie_a"} },
            { key = "soccer_korea_kleague1", label = "K-League", sharp = {sport="soccer", league="k_league_1"} },
            { key = "soccer_china_superleague", label = "Chinese Super League", sharp = {sport="soccer", league="china_-_super_league"} },
            -- ZQ-sourced leagues (bettable via the ZQ crawler; no SharpAPI fetch).
            -- Keys MUST match zqLeagues.js on the engine. zq=true marks them ZQ-fed.
            { key = "zq_norway_eliteserien", label = "Norwegian Eliteserien", zq = true },
            { key = "zq_argentina_primera", label = "Argentine Primera", zq = true },
            { key = "zq_copa_sudamericana", label = "Copa Sudamericana", zq = true },
            { key = "zq_copa_libertadores", label = "Copa Libertadores", zq = true },
            { key = "zq_finland_veikkausliiga", label = "Finnish Veikkausliiga", zq = true },
            { key = "zq_finland_ykkonen", label = "Finnish Ykkonen", zq = true },
            { key = "zq_brazil_serie_a", label = "Brazil Serie A", zq = true },
            { key = "zq_brazil_cup", label = "Brazil Cup", zq = true },
            { key = "zq_sweden_allsvenskan", label = "Swedish Allsvenskan", zq = true },
            { key = "zq_sweden_superettan", label = "Swedish Superettan", zq = true },
            { key = "zq_usa_mls", label = "MLS (ZQ)", zq = true },
            { key = "zq_norway_cup", label = "Norwegian Cup", zq = true },
            { key = "zq_japan_jleague", label = "J-League", zq = true },
            { key = "zq_japan_j2", label = "J2 League", zq = true },
            { key = "zq_korea_kleague", label = "K-League (ZQ)", zq = true },
            { key = "zq_europa_league", label = "Europa League", zq = true },
            { key = "zq_champions_league", label = "Champions League", zq = true },
            { key = "zq_conference_league", label = "Conference League", zq = true },
            { key = "zq_club_friendly", label = "Club Friendly", zq = true },
        }
    },
    {
        id = "basketball",
        label = "Basketball",
        icon = "basketball",
        sports = {
            { key = "basketball_wnba", label = "WNBA", sharp = {sport="basketball", league="wnba"} },
            { key = "basketball_nba_championship_winner", label = "NBA Futures", sharp = {sport="basketball", league="nba"} },
        }
    },
    {
        id = "ice_hockey",
        label = "Ice Hockey",
        icon = "hockey",
        sports = {
            { key = "icehockey_nhl", label = "NHL", sharp = {sport="hockey", league="nhl"} },
        }
    },
    -- "Other" split into 3 top-level sports so the sidebar shows them separately.
    {
        id = "mma",
        label = "UFC / MMA",
        icon = "mma",
        sports = {
            { key = "mma_mixed_martial_arts", label = "UFC / MMA", sharp = {sport="mma", league="ufc"} },
        }
    },
    {
        id = "boxing",
        label = "Boxing",
        icon = "boxing",
        sports = {
            { key = "boxing_boxing", label = "Boxing", sharp = {sport="boxing", league=""} },
        }
    },
    {
        id = "politics",
        label = "Politics",
        icon = "politics",
        sports = {
            { key = "politics_us_presidential_election_winner", label = "US Election", sharp = {sport="politics", league=""} },
        }
    },
}

Config.DefaultRegions = "us,uk,eu,au"
Config.DefaultMarkets = "h2h,spreads,totals"

Config.VIP = {
    levels = {
        { id = "bronze_3",  name = "Bronze III",    tier = "Bronze",   minXP = 0,            color = "#cd7f32", maxBet = 10000 },
        { id = "bronze_2",  name = "Bronze II",     tier = "Bronze",   minXP = 500000,       color = "#cd7f32", maxBet = 20000 },
        { id = "bronze_1",  name = "Bronze I",      tier = "Bronze",   minXP = 1500000,      color = "#cd7f32", maxBet = 35000 },
        { id = "silver",    name = "Silver",        tier = "Silver",   minXP = 5000000,      color = "#c0c0c0", maxBet = 75000 },
        { id = "gold",      name = "Gold",          tier = "Gold",     minXP = 15000000,     color = "#ffd700", maxBet = 200000 },
        { id = "plat_3",    name = "Platinum III",  tier = "Platinum", minXP = 50000000,     color = "#b0c4de", maxBet = 1500000 },
        { id = "plat_2",    name = "Platinum II",   tier = "Platinum", minXP = 100000000,    color = "#b0c4de", maxBet = 2500000 },
        { id = "plat_1",    name = "Platinum I",    tier = "Platinum", minXP = 200000000,    color = "#b0c4de", maxBet = 3500000 },
        { id = "diamond_3", name = "Diamond III",   tier = "Diamond",  minXP = 500000000,    color = "#b9f2ff", maxBet = 5000000 },
        { id = "diamond_2", name = "Diamond II",    tier = "Diamond",  minXP = 750000000,    color = "#b9f2ff", maxBet = 7500000 },
        { id = "diamond_1", name = "Diamond I",     tier = "Diamond",  minXP = 1000000000,   color = "#b9f2ff", maxBet = 10000000 },
        { id = "emerald_3", name = "Emerald III",   tier = "Emerald",  minXP = 1250000000,   color = "#50c878", maxBet = 12000000 },
        { id = "emerald_2", name = "Emerald II",    tier = "Emerald",  minXP = 1750000000,   color = "#50c878", maxBet = 13500000 },
        { id = "emerald_1", name = "Emerald I",     tier = "Emerald",  minXP = 2500000000,   color = "#50c878", maxBet = 15000000 },
    },
    xpMult = { sports = 2, casino = 1.2 },
    xpMultWeekend = { sports = 3, casino = 2 },
    taxRates = {
        Bronze   = { gov = 0.05, fee = 0.02 },
        Silver   = { gov = 0.05, fee = 0.02 },
        Gold     = { gov = 0.05, fee = 0.02 },
        Platinum = { gov = 0.03, fee = 0.02 },
        Diamond  = { gov = 0.02, fee = 0.02 },
        Emerald  = { gov = 0.02, fee = 0.01 },
    },
    taxThresholdMult = 1.5,
    taxWeekendDiscount = 0.01,
    rakeback = {
        Bronze = 0, Silver = 0.05, Gold = 0.10,
        Platinum = 0.15, Diamond = 0.20, Emerald = 0.30,
    },
    houseEdge = {
        dice = 0.01, plinko = 0.01, crash = 0.01,
        mines = 0.02, chicken = 0.02, sports = 0.05,
    },
    weeklyRewards = {
        Bronze = 0, Silver = 8000, Gold = 20000,
        Platinum = 45000, Diamond = 90000, Emerald = 180000,
    },
    dailyBonus = {
        Diamond = { cash = 5000, homecoin = 25 },
        Emerald = { cash = 12000, homecoin = 50 },
    },
    lossStreak = {
        threshold = 5,
        refund = { Gold = 0.05, Platinum = 0.08, Diamond = 0.12, Emerald = 0.15 },
    },
    levelUpRewards = {
        bronze_2  = { cash = 2000,   homecoin = 0 },
        bronze_1  = { cash = 5000,   homecoin = 0 },
        silver    = { cash = 5000,   homecoin = 50 },
        gold      = { cash = 15000,  homecoin = 150 },
        plat_3    = { cash = 40000,  homecoin = 400 },
        plat_2    = { cash = 20000,  homecoin = 150 },
        plat_1    = { cash = 35000,  homecoin = 250 },
        diamond_3 = { cash = 100000, homecoin = 1000 },
        diamond_2 = { cash = 50000,  homecoin = 500 },
        diamond_1 = { cash = 80000,  homecoin = 800 },
        emerald_3 = { cash = 300000, homecoin = 3000 },
        emerald_2 = { cash = 150000, homecoin = 1500 },
        emerald_1 = { cash = 250000, homecoin = 2500 },
    },
    referralKickback = 0.001,
    racePoolPercent = 0.001,
}

Config.Casino = {
    Dice = {
        enabled = true,
        houseEdge = 0.01,
        minBet = 20,
        maxBet = 10000000,
    },
    Mines = {
        enabled = true,
        houseEdge = 0.02,
        minBet = 20,
        maxBet = 10000000,
        gridSize = 25,
        minMines = 1,
        maxMines = 24,
    },
    Chicken = {
        enabled = true,
        houseEdge = 0.02,
        minBet = 20,
        maxBet = 10000000,
    },
    Crash = {
        enabled = true,
        houseEdge = 0.01,
        minBet = 20,
        maxBet = 10000000,
    },
    Plinko = {
        enabled = true,
        houseEdge = 0.01,
        minBet = 20,
        maxBet = 10000000,
        cooldownMs = 28,     -- min ms between drops (~35 balls/s). Stake-style rapid fire.
        maxInFlight = 120,   -- max balls mid-air awaiting their landing/claim
    },
}

-- Global big-win announcement: any payout >= MinPayout broadcasts a fanfare +
-- 20s banner to EVERY client (not just players inside the casino). The banner
-- background is themed to the winner's VIP tier.
Config.BigWinAnnounce = {
    enabled = true,
    minPayout = 300000,     -- flat trigger; high-limit players always show
    durationMs = 20000,     -- on-screen time (fade in/out handled NUI-side)
    -- Anti-spam: don't re-announce the same player more often than this (ms).
    perPlayerCooldownMs = 8000,
}

Config.Location = vector3(933.72, 40.94, 81.1)
Config.NpcHeading = 58.76
Config.NpcModel = "s_m_y_casino_01"
Config.InteractionDistance = 8.0

Config.Blip = {
    enabled = true,
    name = "Steak",
    sprite = 684,
    color = 5,
    scale = 0.8
}

-- Demo mode: fake balance, no DB writes (bets/leaderboard/VIP XP), no house routing
-- Add citizenids here to enable demo mode for those players
Config.DemoMode = {
    enabled = true,
    balance = 50000000, -- $50M fake balance for testing
    citizens = {
        -- Add your citizenid here, e.g. "ABC12345"
    },
}
