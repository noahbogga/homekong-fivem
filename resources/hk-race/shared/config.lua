RaceConfig = {}

-- ── Core ────────────────────────────────────────────────────────────────────
RaceConfig.Locale = 'en'                 -- see shared/locales.lua ('en', 'zh')
RaceConfig.Debug = false

-- Admin permission: any of these QBCore permission levels can create/manage.
RaceConfig.AdminPermissions = { 'admin', 'god' }

-- Commands
RaceConfig.AdminCommand = 'raceadmin'    -- opens the admin NUI panel (create/manage tracks)
RaceConfig.UserCommand  = 'racemenu'     -- opens the user track picker (host a race)
RaceConfig.QuitCommand  = 'quitrace'     -- leave an active race

-- ── Editor ────────────────────────────────────────────────────────────────
RaceConfig.Editor = {
    noclipSpeed = 1.0,               -- base noclip fly speed multiplier
    noclipFastMultiplier = 4.0,      -- hold shift
    noclipSlowMultiplier = 0.25,     -- hold alt
    defaultStartRadius = 15.0,       -- metres
    minStartRadius = 1.0,
    maxStartRadius = 150.0,
    defaultCheckpointRadius = 8.0,   -- metres (arrival tolerance)
    minCheckpointRadius = 3.0,
    maxCheckpointRadius = 30.0,
    -- Preview marker colours (editor only) — RGBA
    startMarkerColor = { r = 255, g = 40,  b = 40,  a = 140 },
    cpMarkerColor    = { r = 40,  g = 180, b = 255, a = 140 },
    cpNextColor      = { r = 255, g = 210, b = 40,  a = 160 },
}

-- ── Race behaviour ──────────────────────────────────────────────────────────
RaceConfig.Race = {
    -- Lobby fill: the race starts once `minPlayers` (host-chosen) are inside the
    -- start circle, after a short grace period for late-comers.
    graceCountdownMs = 30 * 1000,    -- grace once min players gathered, before GO
    lobbyTimeoutMs = 10 * 60 * 1000, -- if min never met, cancel at this mark…
    -- …UNLESS minPlayers <= this, in which case the timeout STARTS with whoever's there.
    timeoutStartMaxMin = 2,
    maxMinPlayers = 8,               -- cap on the host's min-players choice
    -- Per-track re-host cooldown: after a race STARTS on a circuit, that track can't be
    -- hosted again for this long (avoids overlapping matches glitching on one circuit).
    trackCooldownMs = 10 * 60 * 1000, -- 10 minutes from race start
    -- Countdown once start conditions are met (the 3-2-1-GO at the actual start).
    startCountdown = 5,              -- seconds (3-2-1-GO style)
    -- You must be driving a vehicle during the race. If you're on foot (or only a
    -- passenger) longer than this, you're auto-removed from the race. Changing cars
    -- mid-race is allowed as long as the gap stays under this.
    onFootGraceMs = 20 * 1000,       -- 20s off-vehicle grace before auto-quit
    -- ps-dispatch blackout window from race start, per racer.
    dispatchMuteMs = 30 * 1000,      -- 30 seconds
    -- Native checkpoint visuals.  GTA checkpoint type reference (verified in-game):
    --   0 = single arrow pointing DOWN (no number)   3 = cyclearrow "loop"/U-turn
    --   4 = checkered race FINISH flag                9 = plain cylinder
    --   42-46 = number-in-ring types (reserved param draws the number → shows "0")
    checkpointType = 0,              -- single down-arrow, no number on top
    checkpointColor = { r = 255, g = 190, b = 30, a = 70 },   -- amber (very see-through)
    checkpointHeight = 3.0,           -- short ring so it doesn't block cars/view
    -- Floating downward indicator hovering ABOVE the ring (points down at it).
    checkpointArrowHeight = 34.0,     -- how high above the ring it floats (was 40, -15%)
    checkpointArrowSize = 4.0,        -- size of the cone/flag (was 2.5, bumped for visibility)
    checkpointArrowAlpha = 90,        -- transparency (lower = more see-through)
    -- Arrival uses HORIZONTAL (X/Y) distance so height doesn't matter (stunts/jumps
    -- over the checkpoint still count). This is the max vertical gap allowed, so a
    -- huge ramp jump directly over the ring still registers.
    checkpointVertTol = 60.0,
    -- Loop LAP line (more laps still to go) AND the final finish line both use the
    -- same checkered race-flag checkpoint type (3 renders the flag correctly here).
    -- Only the colour differs: loop line = BLUE, final finish = GREEN.
    checkpointLoopType = 3,
    checkpointLoopColor = { r = 40, g = 130, b = 255, a = 80 },
    -- FINAL finish line: same flag type as the loop line, GREEN.
    checkpointFinishType = 3,
    checkpointFinishColor = { r = 40, g = 220, b = 90, a = 90 },
    -- Alternate-path ring colour (orange) — for checkpoints with multiple locations.
    checkpointAltColor = { r = 255, g = 140, b = 20, a = 120 },
    -- Upcoming (next) checkpoint preview — GTA-Online style: a dimmer arrow shown
    -- ahead so a sharp bend isn't a surprise. Set showNext=false to force pure
    -- memorization (one checkpoint at a time).
    showNext = true,
    checkpointNextType = 0,          -- same down-arrow, dimmed/smaller below
    checkpointNextColor = { r = 255, g = 190, b = 30, a = 70 },  -- lower alpha = ghosted
    checkpointNextScale = 0.7,       -- fraction of the real radius for the preview ring
    -- Minimap blips on the NEXT few checkpoints so you don't get lost. The current
    -- target is highlighted; upcoming ones are dimmer.
    minimapBlips = 3,                -- how many upcoming checkpoints to blip (0 = off)
    blipSprite = 1,                  -- standard round blip
    blipColorCurrent = 5,            -- yellow (current target)
    blipColorUpcoming = 3,           -- blue (upcoming)
    blipColorFinish = 2,             -- green (finish)
    blipColorLoop = 3,               -- blue (loop line)
    -- Ghost mode: no collision between racers. Chosen by the host per race
    -- (off / start / full). ghostDurationMs is how long 'start' mode lasts from GO.
    ghostDurationMs = 15 * 1000,     -- 'start' mode duration
    ghostDefault = 'start',          -- default host selection: 'off'|'start'|'full'
    -- ── Time Attack (solo run) ───────────────────────────────────────────────
    -- Any race that STARTS with exactly one racer becomes a Time Attack run:
    --   * permanent ghost vs all other players (no collisions the whole run),
    --   * a HIGHER checkpoint repair rate (see repairBoostMult),
    --   * pays the FULL 1st-place reward — but ONLY if the run beats the player's
    --     PER-TIER track record (fastest time in their vehicle class here).
    -- Not a new best → no payout (the run still records on the leaderboard as usual).
    timeAttack = {
        enabled = true,
        repairBoostMult = 2.0,       -- checkpoint repair gains multiplied by this
        fullReward = true,           -- pay the full (unshifted, unhalved) 1st prize
    },
    -- Slipstream / drafting: a LIGHT capped boost while tucked behind a car ahead.
    -- Default on; host can toggle per race. Boost lasts maxMs then forces cooldownMs.
    slipstream = {
        enabled = true,
        mult = 1.12,                 -- SetVehicleCheatPowerIncrease multiplier (light)
        maxMs = 3000,                -- max continuous boost time
        cooldownMs = 2000,           -- forced pause after maxMs before it can build again
        minSpeed = 40.0,             -- km/h; both cars must be moving faster than this
        range = 25.0,                -- metres: how far ahead the lead car can be
        minRange = 4.0,              -- metres: too close = no meaningful draft
        coneDot = 0.75,              -- how directly ahead (dot of forward vs to-target)
    },
    -- Server-wide cap on how many races can run at once.
    maxConcurrentRaces = 3,
    -- Loop/circuit: max laps the host may choose, and the default.
    maxLaps = 20,                    -- hard cap on laps per match
    defaultLaps = 2,
    -- Loop finish/lap line default radius (separate from the gather start zone).
    defaultLoopRadius = 12.0,
    -- Max time a racer can take before auto-DNF (0 = disabled).
    maxRaceTimeMs = 0,
    -- Start-zone map blip.
    startBlip = {
        sprite = 315,               -- race flag
        color = 1,                  -- red
        scale = 0.9,
        radiusAlpha = 128,          -- red radius fill alpha on map
    },
}

-- ── Rewards ──────────────────────────────────────────────────────────────
RaceConfig.Rewards = {
    -- Editor picks currency + per-position amounts per track. These are the
    -- hard ceilings the server clamps to (anti-abuse).
    currencies = { 'cash', 'coins' },   -- 'coins' = HOMECOIN via sky_coinsystem
    maxPositions = 3,                    -- 1st / 2nd / 3rd
    maxAmount = {
        cash = 500000,
        coins = 100000,
    },
    -- Fallback if a track has no rewards configured.
    default = { currency = 'cash', amounts = { 25000, 12000, 5000 } },

    -- Payout scaling by number of racers who START the race.
    -- Below `fullPoolMinPlayers`, every position payout is multiplied by
    -- `lowTurnoutMultiplier` (a solo run still earns, just halved). At or above
    -- that count, full prize pool.
    fullPoolMinPlayers = 4,
    lowTurnoutMultiplier = 0.5,

    -- ── Illegal-race "police heat" bonus ─────────────────────────────────────
    -- ILLEGAL races only: if on-duty cops (leo) are online while the race runs, add a
    -- PERCENTAGE bonus on the race payout, scaled by how many were on duty (capped at
    -- 35%). Paid to ALL finishers — winner full %, others a reduced share of it.
    -- Legal/sanctioned races never get this.
    policeBonus = {
        enabled = true,
        jobTypes = { 'leo' },        -- job.type(s) that count as police for heat
        countedAtStart = true,       -- lock the cop count at race start (not finish)
        winnerShare = 1.0,           -- winner gets the full % below
        otherShare = 0.5,            -- other finishers get this fraction of the %
        -- Bonus % by number of on-duty cops (uses the highest bracket ≤ copCount).
        -- Capped at 35%. Retune freely.
        pctByCops = {
            [1] = 5, [2] = 10, [3] = 15, [5] = 20, [6] = 25, [8] = 28, [9] = 32, [12] = 35,
        },
        maxPct = 35,                 -- hard ceiling
    },

    -- ── Loop-race lap payout scaling ─────────────────────────────────────────
    -- The position prize is multiplied by the SUM of per-lap weights, so more laps
    -- always pays more — but long grinds get diminishing returns. Weights by lap #:
    --   laps 1..lapFullUntil        → 100% each
    --   laps (…+1)..lapMidUntil     → lapMidWeight each   (your -35% → 0.65)
    --   laps beyond lapMidUntil     → lapHighWeight each   (steeper)
    -- e.g. defaults: 6 laps=6.0x, 8=7.3x, 10=8.35x, 15=10.35x. One-way = 1x.
    lapFullUntil = 6,        -- laps up to here pay full (1.0 each)
    lapMidUntil = 9,         -- laps up to here pay lapMidWeight
    lapMidWeight = 0.65,     -- -35% per lap for laps 7..9
    lapHighWeight = 0.40,    -- laps 10+ each add this much
}

-- Total lap-payout multiplier for an N-lap loop (sum of per-lap weights).
function RaceConfig.lapPayoutMult(laps)
    laps = math.max(1, math.floor(tonumber(laps) or 1))
    local R = RaceConfig.Rewards
    local m = 0.0
    for lap = 1, laps do
        if lap <= R.lapFullUntil then m = m + 1.0
        elseif lap <= R.lapMidUntil then m = m + R.lapMidWeight
        else m = m + R.lapHighWeight end
    end
    return m
end

-- Police-heat bonus PERCENT for a given on-duty cop count (highest bracket ≤ count,
-- clamped to maxPct). 0 if no cops / no bracket reached.
function RaceConfig.policeBonusPct(cops)
    cops = math.floor(tonumber(cops) or 0)
    local pb = RaceConfig.Rewards.policeBonus
    if not (pb and pb.enabled) or cops <= 0 then return 0 end
    local best = 0
    for threshold, pct in pairs(pb.pctByCops or {}) do
        if cops >= threshold and pct > best then best = pct end
    end
    return math.min(best, pb.maxPct or 35)
end

-- ── Vehicle performance tiers ───────────────────────────────────────────────
-- A vehicle is scored 0-100 from real measured data (hk-handling SpeedCalData:
-- 0-100 time + top speed), with a gearbox-class nudge near boundaries. The host
-- picks which tiers may join a race (multi-select, or no restriction).
RaceConfig.Tiers = {
    -- 3 tiers (was 4). Tiers 3/4 were too broad/unwieldy, so Super now covers the
    -- whole fast end. Any number of names works — cut has (#names - 1) points.
    -- Ordered slowest→fastest (index 1 = slowest). Class S = fastest, A = mid, B = slowest.
    names = { 'B', 'A', 'S' },
    -- Score cut points (upper-exclusive): <cut[1]=T1, <cut[2]=T2, else T3.
    -- Retuned 2026-08-28 from {45,72}: old cuts put 44% of cars in S (B36/A35/S56).
    -- {50,80} over the 127-car sample gives a proper pyramid B42/A54/S31.
    cut = { 50, 80 },
    -- Blended score weights.
    weightAccel = 0.6,
    weightTop   = 0.4,
    -- 0-100 km/h time (s) → accel score 100..0 (faster = higher).
    accelFast = 1.8,   -- ≤ this → 100
    accelSlow = 8.0,   -- ≥ this → 0
    -- Top speed (km/h) → top score 0..100.
    topLow  = 150.0,   -- ≤ this → 0
    topHigh = 360.0,   -- ≥ this → 100
    -- Gearbox nudge: within `nudgeBand` score points of a boundary, Super/Sequential
    -- (manualType 4/5) push UP one tier; auto/manual/basic (0/1/2) push DOWN.
    gearboxNudge = true,
    nudgeBand = 5.0,
    -- Fallback tier when a vehicle has no data at all (native estimate also failed).
    fallbackTier = 2,
}

-- ── Auto-calibration (client/carcal.lua) ────────────────────────────────────
-- Passively measures each car's real 0-100 (t100) from a clean standing-start
-- WOT pull, and tracks peak top speed while driving. Learned values are owned by
-- hk-race (hk_race_car_cal) and feed the tier map. New cars self-rate the first
-- time a player floors it cleanly; /racecalall bulk-seeds from existing data.
RaceConfig.AutoCal = {
    enabled       = true,
    requireStock  = true,     -- only capture unmodified cars (fair baseline)
    startKmh      = 2.0,      -- arm below this speed (near standstill)
    startThrottle = 0.95,     -- need near-full throttle to arm
    minThrottle   = 0.90,     -- lift below this (beyond graceMs) aborts the run
    maxLiftMs     = 120,      -- tolerated throttle-lift before abort
    midKmh        = 60.0,     -- intermediate split (informational)
    endKmh        = 100.0,    -- t100 target
    maxSteer      = 0.35,     -- hard steering aborts (not a straight pull)
    maxGrade      = 0.030,    -- slope guard: |dz|/dist2d over the run
    minT100       = 1.2,      -- plausibility floor (s)
    maxT100       = 40.0,     -- plausibility ceiling (s)
    minRunGapMs   = 1500,     -- cooldown between accepted captures
    -- Top-speed tracking: sample peak speed while driving (any car, any time).
    topSampleMs   = 750,      -- how often to check speed for a new peak
    topMinKmh     = 40.0,     -- ignore trivial speeds
    reportTopMinDelta = 3.0,  -- only report a new top if it beats stored by this
    debug         = false,
}

-- ── Leaderboard ─────────────────────────────────────────────────────────────
-- The board is split per tier (S / A / B) so fast Super cars don't crush the
-- slower classes out of the list. Keep this many best times per tier per track.
RaceConfig.Leaderboard = {
    perTier = 10,
}

-- ── Dispatch (who can/can't see the race announcement) ──────────────────────
-- ps-dispatch job "types": leo (police), ems (ambulance), fbi, cia, nia.
-- Announcement is shown to everyone EXCEPT these jobs:
RaceConfig.Dispatch = {
    hiddenFromJobs = { 'leo', 'ems' },      -- police + ambulance cannot see
    -- fbi / cia / nia are NOT in the list, so they still get the alert.
    announceCode = '10-80',
    announceIcon = 'fas fa-flag-checkered',
    announcePriority = 2,
    announceSound = 'Lose_1st',
    announceSound2 = 'GTAO_FM_Events_Soundset',
}

-- ── On-screen race HUD (NUI panel, top-right, hk-speedo minimal style) ──────
-- Position/colours live in html/css/style.css (#race-hud). Renders 中文 + emoji.
RaceConfig.Hud = {
    enabled = true,
}

-- ── Head-to-Head (H2H): horn-twice street challenge ─────────────────────────
-- Meet another driver on the street, tap the HORN TWICE, and challenge the
-- nearest driver in radius to a one-on-one sprint. Host picks the finish:
-- a dynamic point dashed ahead, OR the nearest fixed finish line. Full contact
-- (no ghosting). Optional wager: both stake the same amount, winner takes the
-- pot. Native Lua reimplementation of the old (broken, DLL-based) ImpromptuRaces.
RaceConfig.H2H = {
    enabled = true,

    -- Trigger: two horn taps within this window arms an invite.
    hornDoubleTapMs = 1500,          -- max gap between the two taps
    hornRearmMs     = 3000,          -- ignore further taps this long after arming (debounce)

    -- Who can be challenged: nearest driver within this radius (metres).
    inviteRadius    = 60.0,
    inviteExpiryMs  = 12 * 1000,     -- target has this long to accept/decline

    -- Per-host cooldown between issuing challenges (anti-spam).
    hostCooldownMs  = 20 * 1000,

    -- Accept / decline / finish-pick keys (control IDs, keyboard group 0).
    keyAccept   = 246,               -- Y (INPUT_MP_TEXT_CHAT_TEAM) — free-ish, rebindable feel
    keyDecline  = 249,               -- N (INPUT_PUSH_TO_TALK) — paired with accept
    keyFinishA  = 157,               -- "1" (INPUT_SELECT_WEAPON_UNARMED) — dynamic dash
    keyFinishB  = 158,               -- "2" (INPUT_SELECT_WEAPON_MELEE) — nearest fixed line
    finishPickMs = 8 * 1000,         -- host's window to pick a finish after arming

    -- Finish options.
    dashAheadDist   = 800.0,         -- 'dynamic dash': finish this far ahead of the host's heading
    fixedLineMaxDist = 1500.0,       -- only OFFER the nearest fixed line if within this range
    finishRadius    = 18.0,          -- arrival tolerance at the finish (metres, horizontal)
    finishVertTol   = 60.0,          -- vertical tolerance (matches Race.checkpointVertTol style)

    -- Countdown before GO (seconds).
    startCountdown  = 5,

    -- Safety timeout: if nobody finishes within this, the race is voided + refunded.
    raceTimeoutMs   = 5 * 60 * 1000,

    -- Wager: host sets the stake with /h2hbet <amount>. Both racers must have it;
    -- it's escrowed from both on accept; the winner takes the whole pot.
    wager = {
        enabled  = true,
        command  = 'h2hbet',
        currency = 'cash',           -- v1: cash only (HOMECOIN can come later)
        default  = 0,                -- 0 = bragging rights only
        max      = 1000000,          -- sanity cap on a single stake
    },

    -- Finish marker (reuses the checkpoint DrawMarker style — green, floating cone).
    finishRingType  = 3,
    finishRingColor = { r = 40, g = 220, b = 90, a = 90 },
    finishRingHeight = 3.0,
    finishArrowType = 4,
    finishArrowSize = 4.0,
    finishArrowHeight = 34.0,

    -- 23 fixed finish lines carried over from the old ImpromptuRaces finishlines.json
    -- (x, y, z, radius). Used for the 'nearest fixed line' finish option.
    fixedFinishLines = {
        { -3030.85, 199.16,  15.76,  15.0 },
        { -863.17,  132.29,  58.6,   10.0 },
        { 696.76,   11.71,   83.53,  20.0 },
        { -2719.25, 2286.19, 18.38,  25.0 },
        { 279.08,   3401.8,  37.08,  15.0 },
        { 1546.58,  3755.79, 33.91,  10.0 },
        { 316.47,   1004.05, 209.93, 15.0 },
        { -500.04,  -2134.43, 8.53,  10.0 },
        { 1167.94,  -3167.78, 5.19,  10.0 },
        { 518.74,   -2169.81, 5.38,  10.0 },
        { 1969.55,  -918.95, 78.56,  12.5 },
        { 2696.34,  3441.16, 55.22,  10.0 },
        { 287.64,   2635.83, 44.06,  15.0 },
        { -410.85,  1186.18, 324.93, 20.0 },
        { -2544.26, 1907.03, 168.47, 10.0 },
        { 3428.55,  4870.96, 34.42,  10.0 },
        { 3372.6,   3704.08, 36.12,  10.0 },
        { 1503.64,  6443.15, 21.97,  25.0 },
        { 2931.19,  4728.5,  49.51,  10.0 },
        { -1317.6,  2154.74, 58.83,  15.0 },
        { 816.32,   1275.04, 359.89, 10.0 },
        { 1035.37,  1501.69, 174.57, 10.0 },
        { -2235.59, 4282.46, 46.32,  30.0 },
    },
}
