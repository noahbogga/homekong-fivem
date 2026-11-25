-- hk-race :: server/main.lua
-- Track CRUD, race lifecycle, per-position rewards, dispatch-mute registry.
-- (Laptop launcher removed; users open the picker with /racemenu.)

local QBCore = exports['qb-core']:GetCoreObject()

-- ── State ────────────────────────────────────────────────────────────────
local Tracks   = {}      -- [id] = track table (see schema below)
local Races    = {}      -- [raceId] = live race state
local muted    = {}      -- [src] = expiryGameTimerMs  (ps-dispatch blackout)
local TierOverrides = {} -- [hash] = tier (manual per-car reclassification)
-- Merged tier-cal map, sent to clients as [hash] = { t100=, top= }.
-- Priority when built (later overrides earlier): RaceCarData seed → DB speedCal
-- t100 parse → learned captures from hk_race_car_cal (live pulls / /racecalall).
local TierCal = {}       -- [hash] = { t100=?, top=? }
local LearnedCal = {}    -- [hash] = { t100=?, top=?, samples=n } (from hk_race_car_cal)
local TrackBusy = {}     -- [trackId] = true while a race is hosted+forming (not started)
local TrackCooldown = {} -- [trackId] = os.time() expiry; set when a race STARTS on it
local nextRaceId = 0

-- Pull the 0-100 time (s) out of an hk_handling.speedCal string.
-- Format is "60,2.3;100,5.5;160,...;" (km/h,seconds pairs). We want the 100 pair.
local function t100FromSpeedCal(s)
    if not s or s == '' then return nil end
    for kmh, secs in tostring(s):gmatch('(%d+%.?%d*)%s*,%s*(%d+%.?%d*)') do
        if math.floor(tonumber(kmh) or 0) == 100 then
            local t = tonumber(secs)
            if t and t > 0 then return t end
        end
    end
    return nil
end

-- Build TierCal from all sources in priority order (later wins). Called on init and
-- whenever a learned capture / bulk seed changes the data. `dbT100[hash]` = t100
-- parsed from hk_handling.speedCal (may be empty if hk-handling absent).
local function rebuildTierCal(dbT100)
    local map = {}
    -- 1) RaceCarData seed (hk-race owned). Key by hash via GetHashKey(spawncode).
    if RaceCarData then
        for spawn, d in pairs(RaceCarData) do
            local h = GetHashKey(spawn) & 0xFFFFFFFF
            map[h] = { t100 = d.t100, top = d.top }
        end
    end
    -- 2) DB speedCal t100 (fills accel for cars the seed missed; no top).
    if dbT100 then
        for h, t in pairs(dbT100) do
            local e = map[h] or {}
            e.t100 = t                       -- DB accel is fresher than a stale seed
            map[h] = e
        end
    end
    -- 3) Learned captures (live pulls / bulk) — highest priority, real measured.
    for h, d in pairs(LearnedCal) do
        local e = map[h] or {}
        if d.t100 then e.t100 = d.t100 end
        if d.top then e.top = d.top end
        map[h] = e
    end
    TierCal = map
end

-- Seconds of re-host cooldown left on a track (0 = none). Clears expired entries.
local function trackCooldownLeft(trackId)
    local exp = TrackCooldown[trackId]
    if not exp then return 0 end
    local left = exp - os.time()
    if left <= 0 then TrackCooldown[trackId] = nil; return 0 end
    return left
end

-- track schema:
-- { id, name, listed(bool), start={x,y,z,radius}, checkpoints={{x,y,z,r}...},
--   rewards={currency='cash'|'coins', amounts={p1,p2,p3}}, createdBy }

-- ── Helpers ────────────────────────────────────────────────────────────────
local function dprint(...)
    if RaceConfig.Debug then print('[hk-race]', ...) end
end

-- Count on-duty police (job.type in policeBonus.jobTypes, and on duty) currently online.
local function countOnDutyPolice()
    local jt = RaceConfig.Rewards.policeBonus and RaceConfig.Rewards.policeBonus.jobTypes or { 'leo' }
    local isPolice = {}
    for _, t in ipairs(jt) do isPolice[t] = true end
    local n = 0
    for _, pid in ipairs(GetPlayers()) do
        local Player = QBCore.Functions.GetPlayer(tonumber(pid))
        if Player and Player.PlayerData and Player.PlayerData.job then
            local job = Player.PlayerData.job
            if isPolice[job.type] and job.onduty then n = n + 1 end
        end
    end
    return n
end

-- Per-license race-hide flag (persisted): if set, the player shows as "Hidden".
local RaceHidden = {}   -- [license] = true

local function licenseOf(src)
    return GetPlayerIdentifierByType and GetPlayerIdentifierByType(src, 'license')
        or GetPlayerIdentifier(src, 0)
end

-- Display name for race records/standings. Uses the hk-chat /nick (read from
-- hk_chat_nicknames by license). Hidden (toggle) or no nick set → "Hidden".
local function displayName(src)
    local lic = licenseOf(src)
    if lic and RaceHidden[lic] then return 'Hidden' end
    -- Pull the player's chat nickname (hk-chat has no export; read its table).
    if lic then
        local ok, rows = pcall(function()
            return MySQL.query.await('SELECT nickname FROM hk_chat_nicknames WHERE license = ?', { lic })
        end)
        if ok and rows and rows[1] and rows[1].nickname and rows[1].nickname ~= '' then
            return tostring(rows[1].nickname):sub(1, 32)
        end
    end
    return 'Hidden'   -- no nick set → anonymous
end

local function isAdmin(src)
    for _, perm in ipairs(RaceConfig.AdminPermissions) do
        if QBCore.Functions.HasPermission(src, perm) then return true end
    end
    return false
end

local function clamp(v, lo, hi)
    if v < lo then return lo elseif v > hi then return hi end
    return v
end

-- ── Persistence ──────────────────────────────────────────────────────────
MySQL.ready(function()
    MySQL.query([[
        CREATE TABLE IF NOT EXISTS hk_race_tracks (
            id INT AUTO_INCREMENT PRIMARY KEY,
            name VARCHAR(64) NOT NULL,
            listed TINYINT(1) NOT NULL DEFAULT 1,
            data LONGTEXT NOT NULL,
            created_by VARCHAR(64) DEFAULT NULL,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            best_lap_ms INT DEFAULT NULL,
            best_lap_name VARCHAR(64) DEFAULT NULL
        )
    ]])
    -- Back-compat: add the record columns if the table pre-existed without them.
    MySQL.query('ALTER TABLE hk_race_tracks ADD COLUMN IF NOT EXISTS best_lap_ms INT DEFAULT NULL')
    MySQL.query('ALTER TABLE hk_race_tracks ADD COLUMN IF NOT EXISTS best_lap_name VARCHAR(64) DEFAULT NULL')
    -- Manual display order (admin-sortable). Lower shows first; ties fall back to id.
    MySQL.query.await('ALTER TABLE hk_race_tracks ADD COLUMN IF NOT EXISTS sort_order INT NOT NULL DEFAULT 0')
    -- Load tracks
    local rows = MySQL.query.await('SELECT * FROM hk_race_tracks') or {}
    for _, row in ipairs(rows) do
        local ok, data = pcall(json.decode, row.data)
        if ok and data then
            data.id = row.id
            data.name = row.name
            -- oxmysql may return TINYINT(1) as a boolean OR a number depending on
            -- its cast mode — accept both so `listed` survives a restart.
            data.listed = (row.listed == 1) or (row.listed == true)
            data.createdBy = row.created_by
            data.bestLapMs = row.best_lap_ms
            data.bestLapName = row.best_lap_name
            data.sortOrder = tonumber(row.sort_order) or 0
            Tracks[row.id] = data
        end
    end
    dprint(('loaded %d tracks'):format(#rows))
    -- Seed sort_order for any legacy rows still at 0 so they get a stable, unique
    -- order (by id) that up/down can then rearrange.
    do
        local seed = {}
        for _, t in pairs(Tracks) do seed[#seed + 1] = t end
        table.sort(seed, function(a, b) return a.id < b.id end)
        for i, t in ipairs(seed) do
            if (t.sortOrder or 0) == 0 then
                t.sortOrder = i
                MySQL.update('UPDATE hk_race_tracks SET sort_order=? WHERE id=?', { i, t.id })
            end
        end
    end

    -- Per-car tier overrides (override-only: new cars auto-tier; this holds exceptions).
    MySQL.query([[
        CREATE TABLE IF NOT EXISTS hk_race_car_tiers (
            hash INT UNSIGNED PRIMARY KEY,
            model VARCHAR(64) DEFAULT NULL,
            name VARCHAR(64) DEFAULT NULL,
            tier TINYINT NOT NULL,
            updated_by VARCHAR(64) DEFAULT NULL,
            updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )
    ]])
    local orows = MySQL.query.await('SELECT hash, tier FROM hk_race_car_tiers') or {}
    for _, r in ipairs(orows) do
        TierOverrides[math.floor(r.hash)] = r.tier
    end
    dprint(('loaded %d car-tier overrides'):format(#orows))

    -- Learned per-car calibration (live pulls + /racecalall). hk-race owned, so it
    -- survives hk-handling redeploys. samples = how many pulls have been folded in.
    MySQL.query([[
        CREATE TABLE IF NOT EXISTS hk_race_car_cal (
            hash INT UNSIGNED PRIMARY KEY,
            model VARCHAR(64) DEFAULT NULL,
            name VARCHAR(96) DEFAULT NULL,
            t100 FLOAT DEFAULT NULL,
            top FLOAT DEFAULT NULL,
            samples INT NOT NULL DEFAULT 0,
            updated_by VARCHAR(64) DEFAULT NULL,
            updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )
    ]])
    local lrows = MySQL.query.await('SELECT hash, t100, top, samples FROM hk_race_car_cal') or {}
    for _, r in ipairs(lrows) do
        LearnedCal[math.floor(r.hash)] = { t100 = r.t100, top = r.top, samples = r.samples or 0 }
    end
    dprint(('loaded %d learned car-cal rows'):format(#lrows))

    -- Parse hk_handling.speedCal → t100 per hash (accel for cars the seed missed).
    -- Optional: hk-handling may be absent — tiers still work off the seed + learned.
    local dbT100 = {}
    local okc, crows = pcall(function()
        return MySQL.query.await('SELECT hash, speedCal FROM hk_handling WHERE speedCal IS NOT NULL') or {}
    end)
    if okc and crows then
        for _, r in ipairs(crows) do
            local t = t100FromSpeedCal(r.speedCal)
            if t then dbT100[math.floor(r.hash)] = t end
        end
        dprint(('parsed %d DB speedCal t100 values'):format(#crows))
    end

    -- Merge all sources into the map clients read.
    rebuildTierCal(dbT100)
    _G.__hkDbT100 = dbT100   -- retained so /racecalall can re-seed without re-querying

    -- Per-track leaderboard: top-20 best attempts with time/name/vehicle/tier.
    MySQL.query([[
        CREATE TABLE IF NOT EXISTS hk_race_leaderboard (
            id INT AUTO_INCREMENT PRIMARY KEY,
            track_id INT NOT NULL,
            ms INT NOT NULL,
            name VARCHAR(64) DEFAULT NULL,
            vehicle VARCHAR(64) DEFAULT NULL,
            model VARCHAR(64) DEFAULT NULL,
            tier TINYINT DEFAULT 0,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            INDEX idx_track_ms (track_id, ms)
        )
    ]])

    -- Per-license race-hide preference (persisted).
    MySQL.query([[
        CREATE TABLE IF NOT EXISTS hk_race_hidden (
            license VARCHAR(60) NOT NULL PRIMARY KEY
        )
    ]])
    local hrows = MySQL.query.await('SELECT license FROM hk_race_hidden') or {}
    for _, r in ipairs(hrows) do RaceHidden[r.license] = true end
end)

-- Build the lightweight list clients need for the laptop picker.
-- Admin-defined manual order, ties broken by id (stable).
local function trackOrderLess(a, b)
    local ao, bo = a.sortOrder or 0, b.sortOrder or 0
    if ao ~= bo then return ao < bo end
    return a.id < b.id
end

local function buildListedTracks()
    local out = {}
    for _, t in pairs(Tracks) do
        if t.listed then
            out[#out + 1] = {
                id = t.id,
                name = t.name,
                checkpoints = #(t.checkpoints or {}),
                currency = t.rewards and t.rewards.currency or 'cash',
                p1 = t.rewards and t.rewards.amounts and t.rewards.amounts[1] or 0,
                trackType = t.trackType or 'oneway',
                bestLapMs = t.bestLapMs,
                bestLapName = t.bestLapName,
                suggestedTier = t.suggestedTier or 0,
                legal = t.legal and true or false,
                allowedTiers = t.allowedTiers or {},
                busy = TrackBusy[t.id] and true or false,   -- being hosted (forming)
                cooldown = trackCooldownLeft(t.id),         -- seconds of re-host cooldown left
                sortOrder = t.sortOrder or 0,
            }
        end
    end
    table.sort(out, trackOrderLess)
    return out
end

-- Full track catalogue for the admin panel.
local function buildAdminTracks()
    local out = {}
    for _, t in pairs(Tracks) do
        out[#out + 1] = {
            id = t.id, name = t.name, listed = t.listed,
            checkpoints = #(t.checkpoints or {}),
            currency = t.rewards and t.rewards.currency or 'cash',
            amounts = t.rewards and t.rewards.amounts or {},
            sortOrder = t.sortOrder or 0,
        }
    end
    table.sort(out, trackOrderLess)
    return out
end

-- ── Track sanitisation (never trust client) ────────────────────────────────
local function sanitizeTrack(raw)
    if type(raw) ~= 'table' then return nil, 'bad payload' end
    local name = tostring(raw.name or ''):sub(1, 64)
    if name == '' then name = 'Untitled Race' end

    local s = raw.start
    if type(s) ~= 'table' or not (s.x and s.y and s.z) then
        return nil, 'missing start'
    end
    local start = {
        x = tonumber(s.x) + 0.0, y = tonumber(s.y) + 0.0, z = tonumber(s.z) + 0.0,
        radius = clamp(tonumber(s.radius) or RaceConfig.Editor.defaultStartRadius,
                       RaceConfig.Editor.minStartRadius, RaceConfig.Editor.maxStartRadius),
    }

    local cps = {}
    if type(raw.checkpoints) ~= 'table' or #raw.checkpoints < 1 then
        return nil, 'no checkpoints'
    end
    for _, c in ipairs(raw.checkpoints) do
        if c.x and c.y and c.z then
            cps[#cps + 1] = {
                x = tonumber(c.x) + 0.0, y = tonumber(c.y) + 0.0, z = tonumber(c.z) + 0.0,
                r = clamp(tonumber(c.r) or RaceConfig.Editor.defaultCheckpointRadius,
                          RaceConfig.Editor.minCheckpointRadius, RaceConfig.Editor.maxCheckpointRadius),
            }
        end
    end
    if #cps < 1 then return nil, 'no valid checkpoints' end

    -- Rewards
    local currency = raw.rewards and raw.rewards.currency or 'cash'
    if currency ~= 'cash' and currency ~= 'coins' then currency = 'cash' end
    local cap = RaceConfig.Rewards.maxAmount[currency] or 0
    local amounts = {}
    local rawAmts = (raw.rewards and raw.rewards.amounts) or {}
    for i = 1, RaceConfig.Rewards.maxPositions do
        amounts[i] = clamp(math.floor(tonumber(rawAmts[i]) or 0), 0, cap)
    end

    -- Track type + loop lines. Helper to sanitise a {x,y,z,radius} line.
    local function sanitizeLine(ln)
        if type(ln) ~= 'table' or not (ln.x and ln.y and ln.z) then return nil end
        return {
            x = tonumber(ln.x) + 0.0, y = tonumber(ln.y) + 0.0, z = tonumber(ln.z) + 0.0,
            radius = clamp(tonumber(ln.radius) or RaceConfig.Race.defaultLoopRadius,
                           RaceConfig.Editor.minCheckpointRadius, RaceConfig.Editor.maxStartRadius),
        }
    end
    local trackType = (raw.trackType == 'loop') and 'loop' or 'oneway'
    local loopLine, finishLine = nil, nil
    if trackType == 'loop' then
        loopLine = sanitizeLine(raw.loopLine)
        if not loopLine then return nil, 'loop needs a lap line' end
        finishLine = sanitizeLine(raw.finishLine)   -- optional; nil = finish at lap line
    end

    -- Suggested class (0 = Any; 1..#tiers). A recommendation, not enforced.
    local suggestedTier = math.floor(tonumber(raw.suggestedTier) or 0)
    if suggestedTier < 0 or suggestedTier > #RaceConfig.Tiers.names then suggestedTier = 0 end

    -- Track tier lock (exclusive tiers). Empty = all allowed. Caps the host.
    local allowedTiers = {}
    if type(raw.allowedTiers) == 'table' then
        local seen = {}
        for _, v in ipairs(raw.allowedTiers) do
            v = math.floor(tonumber(v) or 0)
            if v >= 1 and v <= #RaceConfig.Tiers.names and not seen[v] then
                seen[v] = true; allowedTiers[#allowedTiers + 1] = v
            end
        end
    end

    return {
        name = name,
        listed = raw.listed ~= false,
        start = start,
        checkpoints = cps,
        rewards = { currency = currency, amounts = amounts },
        trackType = trackType,
        loopLine = loopLine,
        finishLine = finishLine,
        suggestedTier = suggestedTier,
        legal = raw.legal and true or false,
        allowedTiers = allowedTiers,
    }
end

-- ── Admin: CRUD callbacks ──────────────────────────────────────────────────
lib.callback.register('hk-race:admin:getData', function(src)
    if not isAdmin(src) then return { error = 'no_permission' } end
    return { tracks = buildAdminTracks() }
end)

-- Return one full track for the editor.
lib.callback.register('hk-race:admin:getTrack', function(src, id)
    if not isAdmin(src) then return nil end
    return Tracks[tonumber(id)]
end)

-- Create or update a track. If id is nil/0 -> insert.
lib.callback.register('hk-race:admin:saveTrack', function(src, id, payload)
    if not isAdmin(src) then return { error = 'no_permission' } end
    local track, err = sanitizeTrack(payload)
    if not track then return { error = err } end

    local blob = json.encode({
        start = track.start,
        checkpoints = track.checkpoints,
        rewards = track.rewards,
        trackType = track.trackType,
        loopLine = track.loopLine,
        finishLine = track.finishLine,
        suggestedTier = track.suggestedTier,
        legal = track.legal,
        allowedTiers = track.allowedTiers,
    })
    id = tonumber(id)
    if id and Tracks[id] then
        MySQL.update('UPDATE hk_race_tracks SET name=?, listed=?, data=? WHERE id=?',
            { track.name, track.listed and 1 or 0, blob, id })
    else
        id = MySQL.insert.await(
            'INSERT INTO hk_race_tracks (name, listed, data, created_by) VALUES (?,?,?,?)',
            { track.name, track.listed and 1 or 0, blob, (GetPlayerIdentifier(src, 0) or 'unknown') })
    end
    track.id = id
    track.createdBy = track.createdBy
    Tracks[id] = track
    return { ok = true, id = id }
end)

lib.callback.register('hk-race:admin:deleteTrack', function(src, id)
    if not isAdmin(src) then return { error = 'no_permission' } end
    id = tonumber(id)
    if not Tracks[id] then return { error = 'not_found' } end
    Tracks[id] = nil
    MySQL.update('DELETE FROM hk_race_tracks WHERE id=?', { id })
    return { ok = true }
end)

-- Toggle whether a track shows in /racemenu (quick, no editor needed).
lib.callback.register('hk-race:admin:toggleListed', function(src, id)
    if not isAdmin(src) then return { error = 'no_permission' } end
    id = tonumber(id)
    local t = Tracks[id]
    if not t then return { error = 'not_found' } end
    t.listed = not t.listed
    MySQL.update('UPDATE hk_race_tracks SET listed=? WHERE id=?', { t.listed and 1 or 0, id })
    return { ok = true, listed = t.listed }
end)

-- Reorder a track in the manual display order. dir = -1 (up) / +1 (down): swap
-- sort_order with the adjacent track in the current admin ordering. Persisted so
-- the new order survives restarts. Returns the refreshed admin list.
lib.callback.register('hk-race:admin:reorderTrack', function(src, id, dir)
    if not isAdmin(src) then return { error = 'no_permission' } end
    id = tonumber(id)
    dir = tonumber(dir)
    if not Tracks[id] or (dir ~= -1 and dir ~= 1) then return { error = 'bad_args' } end

    -- Ordered snapshot of all tracks (same order the admin panel shows).
    local ordered = {}
    for _, t in pairs(Tracks) do ordered[#ordered + 1] = t end
    table.sort(ordered, trackOrderLess)

    local pos
    for i, t in ipairs(ordered) do if t.id == id then pos = i break end end
    if not pos then return { error = 'not_found' } end
    local swapPos = pos + dir
    if swapPos < 1 or swapPos > #ordered then
        return { ok = true, tracks = buildAdminTracks() }   -- already at an edge, no-op
    end

    local a, b = ordered[pos], ordered[swapPos]
    -- Both may share sort_order 0 on legacy data; normalise to their list positions
    -- first so the swap is meaningful, then swap.
    local ao, bo = a.sortOrder or 0, b.sortOrder or 0
    if ao == bo then ao, bo = pos, swapPos end
    a.sortOrder, b.sortOrder = bo, ao
    MySQL.update('UPDATE hk_race_tracks SET sort_order=? WHERE id=?', { a.sortOrder, a.id })
    MySQL.update('UPDATE hk_race_tracks SET sort_order=? WHERE id=?', { b.sortOrder, b.id })
    return { ok = true, tracks = buildAdminTracks() }
end)

-- Clients ask for the listed tracks (for /racemenu).
lib.callback.register('hk-race:client:bootstrap', function(src)
    return { tracks = buildListedTracks(), tierOverrides = TierOverrides }
end)

-- Client tier module fetches the override map on load.
lib.callback.register('hk-race:tier:getOverrides', function(src)
    return TierOverrides
end)

-- Client tier module fetches the merged cal map on load: [hash] = { t100, top }.
lib.callback.register('hk-race:tier:getCalMap', function(src)
    return TierCal
end)

-- Absolute set (no best-merge) — used by /racecalall bulk seed. Persists + rebuilds
-- but does NOT broadcast per-row (caller broadcasts once at the end).
local function foldLearnedRaw(hash, model, name, t100, top)
    hash = math.floor(tonumber(hash) or 0) & 0xFFFFFFFF
    if hash == 0 then return end
    local e = LearnedCal[hash] or { samples = 0 }
    if t100 and t100 > 0 then e.t100 = t100 end
    if top and top > 0 then e.top = top end
    LearnedCal[hash] = e
    MySQL.query([[
        INSERT INTO hk_race_car_cal (hash, model, name, t100, top, samples)
        VALUES (?, ?, ?, ?, ?, ?)
        ON DUPLICATE KEY UPDATE t100 = VALUES(t100), top = VALUES(top),
            model = VALUES(model), name = VALUES(name), updated_at = NOW()
    ]], { hash, model, name, e.t100, e.top, e.samples or 0 })
end

-- Fold a learned capture into LearnedCal + DB, then rebuild and broadcast the map.
-- t100 keeps the BEST (fastest plausible) seen; top keeps the PEAK. Smooths noise
-- by favouring the min-time / max-top rather than averaging in bad runs.
local function foldLearned(hash, model, name, t100, top)
    hash = math.floor(tonumber(hash) or 0) & 0xFFFFFFFF
    if hash == 0 then return false end
    local e = LearnedCal[hash] or { samples = 0 }
    local changed = false
    if t100 and t100 > 0 then
        if not e.t100 or t100 < e.t100 then e.t100 = t100; changed = true end
    end
    if top and top > 0 then
        if not e.top or top > e.top then e.top = top; changed = true end
    end
    if not changed and e.samples and e.samples > 0 then
        e.samples = e.samples + 1   -- still count the run even if it wasn't a record
    else
        e.samples = (e.samples or 0) + 1
    end
    LearnedCal[hash] = e
    MySQL.query([[
        INSERT INTO hk_race_car_cal (hash, model, name, t100, top, samples)
        VALUES (?, ?, ?, ?, ?, ?)
        ON DUPLICATE KEY UPDATE t100 = VALUES(t100), top = VALUES(top),
            samples = VALUES(samples), model = VALUES(model), name = VALUES(name),
            updated_at = NOW()
    ]], { hash, model, name, e.t100, e.top, e.samples })
    rebuildTierCal(_G.__hkDbT100)
    TriggerClientEvent('hk-race:tier:syncCalMap', -1, TierCal)
    return true
end

-- Client reports a clean standing-start capture (natives-only, see client/carcal.lua).
-- Server validates ranges, keeps best, persists, and broadcasts the refreshed map.
RegisterNetEvent('hk-race:carcal:sample', function(payload)
    local src = source
    if type(payload) ~= 'table' then return end
    local hash = math.floor(tonumber(payload.hash) or 0)
    local t100 = tonumber(payload.t100)
    local top  = tonumber(payload.top)
    if hash == 0 then return end
    -- plausibility gates (mirror the client's, defence-in-depth)
    if t100 and (t100 < 1.2 or t100 > 40.0) then t100 = nil end
    if top and (top < 40.0 or top > 550.0) then top = nil end
    if not t100 and not top then return end
    foldLearned(hash, payload.model, payload.name, t100, top)
end)

-- ADMIN: /racecalall — bulk-seed every hk_handling car into hk_race_car_cal from
-- data we already have (DB speedCal t100 + RaceCarData seed top), so cars that can't
-- be bench-driven still get a real auto-tier immediately. Cars with NO data anywhere
-- are reported as awaiting a live pull. Does NOT overwrite a better learned value.
RegisterCommand('racecalall', function(src, _, _)
    if src ~= 0 and not isAdmin(src) then
        TriggerClientEvent('QBCore:Notify', src, '/racecalall is admin only', 'error'); return
    end
    local rows = MySQL.query.await('SELECT hash, model, name, speedCal FROM hk_handling') or {}
    local seeded, awaiting, skipped = 0, 0, 0
    for _, r in ipairs(rows) do
        local h = math.floor(r.hash) & 0xFFFFFFFF
        local t = t100FromSpeedCal(r.speedCal)
        local seed = RaceCarData and RaceCarData[(r.model or ''):lower()]
        local topv = seed and seed.top
        local tacc = t or (seed and seed.t100)
        local have = LearnedCal[h]
        if tacc or topv then
            -- only fill fields the learned row doesn't already have (best)
            local nt = (have and have.t100) or tacc
            local ntop = (have and have.top) or topv
            if not have or nt ~= have.t100 or ntop ~= have.top then
                foldLearnedRaw(h, r.model, r.name, nt, ntop)   -- raw = absolute set, not best-merge
                seeded = seeded + 1
            else
                skipped = skipped + 1
            end
        else
            awaiting = awaiting + 1
        end
    end
    rebuildTierCal(_G.__hkDbT100)
    TriggerClientEvent('hk-race:tier:syncCalMap', -1, TierCal)
    local msg = ('[racecalall] seeded %d · already-had %d · awaiting live pull %d (of %d cars)')
        :format(seeded, skipped, awaiting, #rows)
    if src == 0 then print(msg) else TriggerClientEvent('QBCore:Notify', src, msg, 'success') end
    print(msg)
end, true)

-- /racebench — spawn EVERY car model on the admin's client, read its native
-- top-speed estimate, and fold it in as a top-speed sample. This is what actually
-- gives cars with NO data anywhere (stock GTA cars) a real tier — /racecalall can
-- only copy numbers that already exist. Must be run by an in-game admin (needs a
-- client to spawn on); console can't spawn vehicles.
RegisterCommand('racebench', function(src, _, _)
    if src == 0 then
        print('[racebench] must be run by an in-game admin (needs a client to spawn cars)')
        return
    end
    if not isAdmin(src) then
        TriggerClientEvent('QBCore:Notify', src, '/racebench is admin only', 'error'); return
    end
    local rows = MySQL.query.await('SELECT hash FROM hk_handling') or {}
    local hashes = {}
    for _, r in ipairs(rows) do hashes[#hashes + 1] = math.floor(r.hash) & 0xFFFFFFFF end
    if #hashes == 0 then
        TriggerClientEvent('QBCore:Notify', src, 'No cars in hk_handling to bench', 'error'); return
    end
    TriggerClientEvent('hk-race:carcal:bench', src, hashes)
end, true)

-- Client finished a bench pass — rebuild + rebroadcast so tiers refresh for everyone.
RegisterNetEvent('hk-race:carcal:benchDone', function()
    rebuildTierCal(_G.__hkDbT100)
    TriggerClientEvent('hk-race:tier:syncCalMap', -1, TierCal)
    print(('[racebench] client %s finished — tier cal rebuilt & synced'):format(source))
end)

-- Admin sets a car's tier override (hash keyed). tier 0 = clear (revert to auto).
lib.callback.register('hk-race:admin:setCarTier', function(src, hash, tier, model, name)
    if not isAdmin(src) then return { error = 'no_permission' } end
    hash = math.floor(tonumber(hash) or 0)
    tier = math.floor(tonumber(tier) or 0)
    if hash == 0 then return { error = 'bad_hash' } end
    if tier <= 0 then
        -- Clear override → back to auto-tiering.
        TierOverrides[hash] = nil
        MySQL.update('DELETE FROM hk_race_car_tiers WHERE hash = ?', { hash })
    else
        if tier > #RaceConfig.Tiers.names then return { error = 'bad_tier' } end
        TierOverrides[hash] = tier
        MySQL.query([[
            INSERT INTO hk_race_car_tiers (hash, model, name, tier, updated_by)
            VALUES (?, ?, ?, ?, ?)
            ON DUPLICATE KEY UPDATE tier = VALUES(tier), model = VALUES(model),
                name = VALUES(name), updated_by = VALUES(updated_by), updated_at = NOW()
        ]], { hash, model, name, tier, displayName(src) })
    end
    -- Push the updated map to everyone so classification is consistent.
    TriggerClientEvent('hk-race:tier:syncOverrides', -1, TierOverrides)
    return { ok = true, tier = tier }
end)

-- Full car list for the admin NUI: live from hk_handling + current overrides.
lib.callback.register('hk-race:admin:getCarTiers', function(src)
    if not isAdmin(src) then return { error = 'no_permission' } end
    local cars = {}
    -- Read hk-handling's model table directly (no hk-handling edit). Guard if absent.
    local ok, rows = pcall(function()
        return MySQL.query.await('SELECT hash, model, name, manualType FROM hk_handling ORDER BY name') or {}
    end)
    if ok and rows then
        for _, r in ipairs(rows) do
            local h = math.floor(r.hash)
            local cal = TierCal[h]
            cars[#cars + 1] = {
                hash = h, model = r.model, name = r.name or r.model,
                override = TierOverrides[h] or 0,   -- 0 = auto
                manualType = r.manualType,          -- for client-side auto-tier nudge
                dbT100 = cal and cal.t100,          -- merged accel (seed/DB/learned)
                dbTop  = cal and cal.top,           -- merged top speed (seed/learned)
            }
        end
    end
    return { cars = cars, tierNames = RaceConfig.Tiers.names }
end)

-- ── Dispatch blackout registry ──────────────────────────────────────────
-- (Exports defined below, after playerRaceId, so they can inspect the race.)

local function muteDispatch(src)
    muted[src] = GetGameTimer() + RaceConfig.Race.dispatchMuteMs
end

-- ── Race lifecycle ─────────────────────────────────────────────────────────
-- race state:
-- { id, trackId, hostSrc, participants={[src]=true}, started(bool),
--   progress={[src]=cpIndexReached}, finishers={src...}, startedAt }

local function playerRaceId(src)
    for rid, race in pairs(Races) do
        if race.participants[src] then return rid, race end
    end
    return nil
end

-- ps-dispatch server hook calls this before broadcasting an alert. Returns true
-- while a racer is muted: the 30s start window (illegal races) OR the WHOLE race
-- (legal / sanctioned races never trigger police).
exports('IsDispatchMuted', function(playerSrc)
    local _, race = playerRaceId(playerSrc)
    if race and race.started and race.legal then return true end   -- legal: full-race mute
    local exp = muted[playerSrc]
    if not exp then return false end
    if GetGameTimer() >= exp then
        muted[playerSrc] = nil
        return false
    end
    return true
end)

-- ps-hud stress guard calls this — racers never gain stress (in lobby or racing).
exports('IsRacing', function(playerSrc)
    return playerRaceId(playerSrc) ~= nil
end)

local function participantCount(race)
    local n = 0
    for _ in pairs(race.participants) do n = n + 1 end
    return n
end

-- Is this player in a hidden (police/ambulance) job? They must never see the
-- start-zone blip or the race dispatch alert.
local function isHiddenJob(src)
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return false end
    local jt = Player.PlayerData and Player.PlayerData.job and Player.PlayerData.job.type
    if not jt then return false end
    for _, hidden in ipairs(RaceConfig.Dispatch.hiddenFromJobs) do
        if jt == hidden then return true end
    end
    return false
end

-- Fire a client event to every player EXCEPT hidden-job (police/ambulance) ones.
local function triggerNonEmergency(event, ...)
    for _, pid in ipairs(GetPlayers()) do
        local sid = tonumber(pid)
        if sid and not isHiddenJob(sid) then
            TriggerClientEvent(event, sid, ...)
        end
    end
end

local function sendToRace(race, event, ...)
    for psrc in pairs(race.participants) do
        TriggerClientEvent(event, psrc, ...)
    end
end

-- Announce to everyone EXCEPT hidden jobs (police/ambulance). fbi/cia/nia see it.
local function announceRace(race, track)
    local hostPed = GetPlayerPed(race.hostSrc)
    local coords = hostPed and GetEntityCoords(hostPed) or vector3(track.start.x, track.start.y, track.start.z)
    local data = {
        message = L('announce_started', 'the area'),
        codeName = 'hk_race_start',
        code = RaceConfig.Dispatch.announceCode,
        icon = RaceConfig.Dispatch.announceIcon,
        priority = RaceConfig.Dispatch.announcePriority,
        coords = coords,
        jobs = { 'fbi', 'cia', 'nia' },  -- ps-dispatch shows only to these jobs
        sound = RaceConfig.Dispatch.announceSound,
        sound2 = RaceConfig.Dispatch.announceSound2,
    }
    -- Route through ps-dispatch's server notify so it renders in their dispatch UI.
    -- Defer to a clean context so the current (possibly muted) player `source`
    -- does not cause our own announcement to be dropped by the mute guard.
    SetTimeout(0, function()
        TriggerEvent('ps-dispatch:server:notify', data)
    end)
end

local beginRace   -- forward declaration (maybeStartGrace + timers reference it)

-- Kick off the grace countdown once min players are gathered. Late-comers can still
-- join during grace; the actual start fires when it elapses. Idempotent (once only).
local function maybeStartGrace(rid)
    local race = Races[rid]
    if not race or race.started or race.grace then return end
    if participantCount(race) < (race.minPlayers or 1) then return end
    race.grace = true
    local secs = math.floor((RaceConfig.Race.graceCountdownMs or 30000) / 1000)
    sendToRace(race, 'hk-race:client:graceCountdown', { secs = secs })
    SetTimeout(RaceConfig.Race.graceCountdownMs, function()
        local r = Races[rid]
        if r and not r.started then beginRace(rid) end
    end)
end

beginRace = function(rid)
    local race = Races[rid]
    if not race or race.started then return end
    local track = Tracks[race.trackId]
    if not track then Races[rid] = nil; return end

    race.started = true
    race.startedAt = os.time()
    -- Circuit is no longer "forming"; start its re-host cooldown from NOW.
    TrackBusy[race.trackId] = nil
    TrackCooldown[race.trackId] = os.time() + math.floor((RaceConfig.Race.trackCooldownMs or 600000) / 1000)
    race.starterCount = participantCount(race)   -- locked at start; drives payout scaling
    -- Time Attack: a run that STARTS solo. Permanent ghost + boosted repair (client),
    -- and pays the full 1st prize only on a new per-tier record (checked in doFinish).
    local ta = RaceConfig.Race.timeAttack
    race.timeAttack = (ta and ta.enabled and race.starterCount == 1) and true or false
    if race.timeAttack then
        race.ghostMode = 'full'
        -- Freeze the per-tier record that STOOD before this run. The payout gate
        -- compares the player's laps against this baseline (not against the row we
        -- insert mid-run), so beating "the record you started against" is what pays.
        race.taGateMap = {}                 -- tier -> best ms at start (nil = none yet)
        race.taBeat = {}                    -- src -> best beating lap ms (set only if beaten)
        race.taGate = {}                    -- src -> the ms they had to beat (nil = none)
        local rows = MySQL.query.await(
            'SELECT tier, MIN(ms) AS best FROM hk_race_leaderboard WHERE track_id = ? GROUP BY tier',
            { race.trackId }) or {}
        for _, r in ipairs(rows) do
            race.taGateMap[math.floor(tonumber(r.tier) or 0)] = tonumber(r.best)
        end
    end
    -- Illegal-race police heat: lock the on-duty cop count at start (legal races = 0).
    local pb = RaceConfig.Rewards.policeBonus
    if pb and pb.enabled and not race.legal and pb.countedAtStart then
        race.copCount = countOnDutyPolice()   -- % cap handled by policeBonusPct
    end
    for psrc in pairs(race.participants) do
        race.progress[psrc] = 0
        race.lap[psrc] = 1
        muteDispatch(psrc)              -- 30s ps-dispatch blackout per racer
    end

    -- Lobby is closed once the race starts; stop advertising it.
    TriggerClientEvent('hk-race:client:lobbyClose', -1, rid)

    -- Announce to FIB/CIA/NIA (never PD/EMS). LEGAL races are silent — no alert.
    if not race.legal then
        announceRace(race, track)
    end

    -- Tell racers to start their runtime (native checkpoints render client-side only).
    sendToRace(race, 'hk-race:client:raceBegin', {
        raceId = rid,
        checkpoints = track.checkpoints,
        countdown = RaceConfig.Race.startCountdown,
        trackType = track.trackType or 'oneway',
        loopLine = track.loopLine,
        finishLine = track.finishLine,
        laps = race.laps or 1,
        trackName = track.name,
        total = participantCount(race),
        ghostMode = race.ghostMode or 'start',
        ghostDurationMs = RaceConfig.Race.ghostDurationMs,
        slipstream = race.slipstream ~= false,
        legal = race.legal and true or false,
        timeAttack = race.timeAttack and true or false,
    })
    dprint(('race %d begun: %d racers, %s, %d lap(s)')
        :format(rid, participantCount(race), track.trackType or 'oneway', race.laps or 1))
end

-- Host starts a race from the laptop.
-- allowedTiers: array of tier ints (1..4) the host permits, or nil = no restriction.
local function sanitizeTiers(t)
    if type(t) ~= 'table' then return nil end
    local set, any = {}, false
    for _, v in ipairs(t) do
        v = tonumber(v)
        if v and v >= 1 and v <= #RaceConfig.Tiers.names then set[v] = true; any = true end
    end
    return any and set or nil
end

local function activeRaceCount()
    local n = 0
    for _ in pairs(Races) do n = n + 1 end
    return n
end

lib.callback.register('hk-race:race:host', function(src, trackId, allowedTiers, hostTier, laps, slipstream, ghostMode, minPlayers)
    trackId = tonumber(trackId)
    local track = Tracks[trackId]
    if not track then return { error = 'not_found' } end
    if playerRaceId(src) then return { error = 'already_in_race' } end
    -- Server-wide cap on concurrent races.
    if activeRaceCount() >= (RaceConfig.Race.maxConcurrentRaces or 3) then
        return { error = 'too_many_races' }
    end
    -- This circuit is already being hosted (forming) — can't double-host it.
    if TrackBusy[trackId] then return { error = 'track_busy' } end
    -- This circuit is on its post-start re-host cooldown.
    local cd = trackCooldownLeft(trackId)
    if cd > 0 then return { error = 'track_cooldown', cooldown = cd } end

    local minP = clamp(math.floor(tonumber(minPlayers) or 1), 1, RaceConfig.Race.maxMinPlayers or 8)

    -- Laps only matter for loop tracks; one-way is always a single pass.
    local nLaps = 1
    if track.trackType == 'loop' then
        nLaps = clamp(math.floor(tonumber(laps) or RaceConfig.Race.defaultLaps), 1, RaceConfig.Race.maxLaps)
    end

    -- Tier gating: the TRACK lock is a hard cap. Host's pick narrows within it.
    --   trackLock empty → host's pick applies as-is (nil = all).
    --   host pick empty  → use the track lock.
    --   both set         → intersection (host ∩ track).
    local hostSet = sanitizeTiers(allowedTiers)   -- set{tier=true} or nil
    local trackLock = nil
    if type(track.allowedTiers) == 'table' and #track.allowedTiers > 0 then
        trackLock = {}
        for _, t in ipairs(track.allowedTiers) do trackLock[t] = true end
    end
    local finalTiers
    if trackLock and hostSet then
        finalTiers = {}
        local any = false
        for t in pairs(hostSet) do if trackLock[t] then finalTiers[t] = true; any = true end end
        if not any then finalTiers = trackLock end   -- host picked outside lock → fall back to lock
    else
        finalTiers = hostSet or trackLock             -- whichever exists (or nil = all)
    end

    nextRaceId = nextRaceId + 1
    local rid = nextRaceId
    Races[rid] = {
        id = rid, trackId = track.id, hostSrc = src,
        participants = { [src] = true }, started = false,
        progress = {}, finishers = {}, createdAt = GetGameTimer(),
        allowedTiers = finalTiers,                    -- nil = open to all
        tierOf = { [src] = tonumber(hostTier) },      -- host exempt from own restriction
        laps = nLaps,                                 -- total laps (1 for one-way)
        lap = {},                                     -- [src] = current lap (1-based)
        slipstream = (slipstream ~= false),           -- host toggle; default on
        ghostMode = (ghostMode == 'off' or ghostMode == 'full') and ghostMode or 'start',
        legal = track.legal and true or false,        -- from the track (admin-set)
        minPlayers = minP,                             -- required in-circle to start
        grace = false,                                 -- grace countdown running?
    }
    TrackBusy[track.id] = true   -- circuit is now forming; blocks a second host

    -- Host ALONE gets the start-zone waypoint + red radius blip. The lobby is NOT
    -- advertised to anyone else yet — only once the host actually reaches the zone.
    TriggerClientEvent('hk-race:client:enterLobby', src, {
        raceId = rid,
        isHost = true,
        start = track.start,
        trackName = track.name,
        minPlayers = minP,
        watchArrival = true,   -- host client pings hostReachedZone when inside radius
        legal = track.legal and true or false,
    })

    -- Lobby timeout: if minPlayers never gathered by lobbyTimeoutMs, CANCEL the race —
    -- UNLESS minPlayers is small (<= timeoutStartMaxMin), in which case start with
    -- whoever is present (so solo/duo races still run).
    SetTimeout(RaceConfig.Race.lobbyTimeoutMs, function()
        local r = Races[rid]
        if not r or r.started then return end
        if r.minPlayers <= (RaceConfig.Race.timeoutStartMaxMin or 2) then
            beginRace(rid)
        else
            -- Not enough players ever showed — cancel.
            sendToRace(r, 'hk-race:client:raceEnded', { reason = 'timeout' })
            TriggerClientEvent('hk-race:client:lobbyClose', -1, rid)
            TrackBusy[r.trackId] = nil   -- never started → free the circuit immediately
            Races[rid] = nil
        end
    end)

    return { ok = true, raceId = rid }
end)

-- Host has driven into their own start zone → NOW advertise the lobby so other
-- players can come join. Broadcast to everyone EXCEPT police/ambulance jobs.
RegisterNetEvent('hk-race:race:hostReachedZone', function(rid)
    local src = source
    local race = Races[rid]
    if not race or race.started then return end
    if race.hostSrc ~= src then return end     -- only the host triggers this
    if race.lobbyAdvertised then return end     -- once only
    race.lobbyAdvertised = true
    local track = Tracks[race.trackId]
    if not track then return end
    -- Advertise the lobby to EVERYONE — any job (incl. LEO/EMS) can RACE. The
    -- police/ambulance hiding only applies to the DISPATCH ALERT (announceRace),
    -- not to who's allowed to join a race.
    TriggerClientEvent('hk-race:client:lobbyOpen', -1, {
        raceId = rid, start = track.start, trackName = track.name,
        legal = track.legal and true or false,
    })
    -- Host is now in the zone; if min is 1 (or already met), begin the grace countdown.
    maybeStartGrace(rid)
end)

-- Is a given tier permitted in this race? (nil allowedTiers = open to all.)
local function tierAllowed(race, tier)
    if not race.allowedTiers then return true end
    if not tier then return false end   -- restricted race, unknown tier → block
    return race.allowedTiers[tier] == true
end

local function allowedTierLabel(race)
    if not race.allowedTiers then return 'any' end
    local parts = {}
    for i = 1, #RaceConfig.Tiers.names do
        if race.allowedTiers[i] then parts[#parts + 1] = RaceConfig.Tiers.names[i] end
    end
    return table.concat(parts, '/')
end

-- A player enters the host's start zone and is added as a participant.
-- `tier` is the joiner's client-computed vehicle tier (int 1..4, or nil on foot).
RegisterNetEvent('hk-race:race:joinZone', function(rid, tier)
    local src = source
    local race = Races[rid]
    if not race or race.started then return end
    if playerRaceId(src) then return end
    local track = Tracks[race.trackId]
    if not track then return end

    -- Authoritative driver check: only the DRIVER of a vehicle may join (no passengers).
    local ped = GetPlayerPed(src)
    if ped and ped ~= 0 then
        local veh = GetVehiclePedIsIn(ped, false)
        if not veh or veh == 0 or GetPedInVehicleSeat(veh, -1) ~= ped then
            return   -- on foot or a passenger → not eligible
        end
    end

    tier = tonumber(tier)
    if not tierAllowed(race, tier) then
        -- Tell the joiner why (throttled client-side so it won't spam).
        TriggerClientEvent('hk-race:client:tierBlocked', src, {
            yourTier = tier, allowed = allowedTierLabel(race),
        })
        return
    end

    race.participants[src] = true
    race.tierOf = race.tierOf or {}
    race.tierOf[src] = tier
    TriggerClientEvent('hk-race:client:enterLobby', src, {
        raceId = rid, isHost = false, start = track.start, trackName = track.name,
        soloDelay = 0, legal = track.legal and true or false,
    })
    sendToRace(race, 'hk-race:client:lobbyUpdate', {
        count = participantCount(race), min = race.minPlayers or 1,
    })
    -- Enough players in the circle? Begin the grace countdown (host can also /startrace).
    maybeStartGrace(rid)
end)

-- Host chooses to force-start from the lobby.
RegisterNetEvent('hk-race:race:forceStart', function(rid)
    local src = source
    local race = Races[rid]
    if not race or race.hostSrc ~= src or race.started then return end
    -- Authoritative check: the host must be inside the start circle to force-start.
    local track = Tracks[race.trackId]
    local ped = GetPlayerPed(src)
    if track and track.start and ped and ped ~= 0 then
        local p = GetEntityCoords(ped)
        local s = track.start
        local dx, dy, dz = p.x - s.x, p.y - s.y, p.z - s.z
        local dist = math.sqrt(dx*dx + dy*dy + dz*dz)
        if dist > (s.radius or 15.0) + 3.0 then   -- small tolerance for sync drift
            return
        end
    end
    beginRace(rid)
end)

-- ── Reward payout ────────────────────────────────────────────────────────
local function formatReward(currency, amount)
    if currency == 'coins' then
        return ('%d HOMECOIN'):format(amount)
    end
    return ('$%d'):format(amount)
end

local function grantCoins(src, amount)
    if GetResourceState('sky_coinsystem') ~= 'started' then return false end
    -- Preferred: the coinsystem export (counterpart to removeCoins/getCoins).
    local ok, res = pcall(function()
        return exports['sky_coinsystem']:addCoins(src, amount)
    end)
    if ok and res ~= nil then return true end
    -- Fallback: write directly to coinsystem_users by identifier (license).
    local ident = GetPlayerIdentifierByType(src, 'license') or GetPlayerIdentifier(src, 0)
    if not ident then return false end
    MySQL.update([[
        INSERT INTO coinsystem_users (identifier, coins) VALUES (?, ?)
        ON DUPLICATE KEY UPDATE coins = coins + ?
    ]], { ident, amount, amount })
    return true
end

local function payReward(src, currency, amount)
    if amount <= 0 then return false end
    if currency == 'coins' then
        return grantCoins(src, amount)
    end
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return false end
    Player.Functions.AddMoney('cash', amount, 'hk-race-reward')
    return true
end

-- Compute + broadcast live standings (position / total) to each racer. Ranking:
-- finishers first (in finish order), then by (lap desc, checkpoint desc). Cheap —
-- only called on a progress change.
local function pushStandings(race)
    local order = {}
    for psrc in pairs(race.participants) do order[#order + 1] = psrc end
    local finishRank = {}
    for i, fsrc in ipairs(race.finishers) do finishRank[fsrc] = i end
    table.sort(order, function(a, b)
        local fa, fb = finishRank[a], finishRank[b]
        if fa and fb then return fa < fb end
        if fa and not fb then return true end
        if fb and not fa then return false end
        local la, lb = race.lap[a] or 1, race.lap[b] or 1
        if la ~= lb then return la > lb end
        return (race.progress[a] or 0) > (race.progress[b] or 0)
    end)
    local total = #order
    for pos, psrc in ipairs(order) do
        TriggerClientEvent('hk-race:client:standings', psrc, { pos = pos, total = total })
    end
end

-- Player reports reaching checkpoint index n (validated server-side).
-- For loops, n counts within the current lap; reaching the last checkpoint then the
-- loop line completes a lap. We model the loop line as index (#checkpoints + 1).
RegisterNetEvent('hk-race:race:checkpoint', function(rid, cpIndex)
    local src = source
    local race = Races[rid]
    if not race or not race.started or not race.participants[src] then return end
    local track = Tracks[race.trackId]
    if not track then return end

    cpIndex = tonumber(cpIndex)
    local expected = (race.progress[src] or 0) + 1
    -- Anti-skip / anti-farm: only the next index in sequence. FiveM delivers one
    -- client's events in send order, and the client dedupes + reports ascending,
    -- so during lag catch-up they still arrive as prev+1, prev+2, … in order.
    if cpIndex ~= expected then return end
    race.progress[src] = cpIndex

    local nCps = #track.checkpoints
    local isLoop = (track.trackType == 'loop') and track.loopLine ~= nil
    -- Per-lap sequence length: one-way = nCps; loop = nCps + 1 (the loop line).
    local seqLen = isLoop and (nCps + 1) or nCps

    -- Standings refresh + race teardown once everyone's done. Shared by both the
    -- normal and Time-Attack finish paths.
    local function afterFinish()
        pushStandings(race)
        local allDone = true
        for psrc in pairs(race.participants) do
            if not race.finished[psrc] then allDone = false break end
        end
        if allDone then SetTimeout(3000, function() Races[rid] = nil end) end
    end

    local function doFinish()
        if race.finished and race.finished[src] then return end
        race.finished = race.finished or {}
        race.finished[src] = true
        race.finishers[#race.finishers + 1] = src
        local place = #race.finishers
        local currency = track.rewards.currency

        -- ── Time Attack (solo run) ───────────────────────────────────────────
        -- No rivals: pay the FULL 1st prize, but ONLY if this run beat the player's
        -- per-tier track record (decided in the lapTime handler, which lands first).
        if race.timeAttack then
            local beat = race.taBeat and race.taBeat[src]           -- best beating lap ms, or nil
            local gate = race.taGate and race.taGate[src]           -- record they had to beat, or nil = none yet
            if beat then
                local lapMult = RaceConfig.lapPayoutMult(race.laps or 1)
                local amount = math.floor((track.rewards.amounts[1] or 0) * lapMult)
                -- Illegal-race police heat still applies (winner share).
                local copBonus = 0
                local pb = RaceConfig.Rewards.policeBonus
                if pb and pb.enabled and (race.copCount or 0) > 0 then
                    local pct = RaceConfig.policeBonusPct(race.copCount)
                    copBonus = math.floor(amount * (pct / 100.0) * (pb.winnerShare or 1.0))
                end
                local total = amount + copBonus
                local rewardStr = nil
                if total > 0 and payReward(src, currency, total) then
                    rewardStr = formatReward(currency, total)
                end
                TriggerClientEvent('hk-race:client:finished', src, {
                    timeAttack = true, taRecord = true, place = 1,
                    reward = rewardStr, laps = race.laps or 1,
                    copBonus = (copBonus > 0) and formatReward(currency, copBonus) or nil,
                    copCount = race.copCount or 0,
                })
            else
                TriggerClientEvent('hk-race:client:finished', src, {
                    timeAttack = true, taRecord = false, place = 1,
                    gateMs = gate or nil,   -- record to beat next time (nil = you just set the first)
                })
            end
            afterFinish()
            return
        end

        local starters = race.starterCount or participantCount(race)
        local maxPos = RaceConfig.Rewards.maxPositions or 3

        -- Under a full field, prizes are HALVED and SHIFTED DOWN (less competition =
        -- lower prizes). Awarded prize slot = place + (maxPos - starters):
        --   1 starter → slot 3 only (3rd prize); 2 starters → slots 2 & 3;
        --   3 starters → 1/2/3; 4+ → full pool, full amount.
        local shift = (starters < maxPos) and (maxPos - starters) or 0
        local slot = place + shift
        local baseAmount = track.rewards.amounts[slot] or 0
        local mult = (starters >= RaceConfig.Rewards.fullPoolMinPlayers)
            and 1.0 or RaceConfig.Rewards.lowTurnoutMultiplier
        -- Loop races pay per lap (stacking, diminishing past the full-lap band).
        local lapMult = RaceConfig.lapPayoutMult(race.laps or 1)
        local amount = math.floor(baseAmount * mult * lapMult)

        -- Illegal-race POLICE HEAT bonus: a PERCENTAGE of the payout (capped 35%),
        -- scaled by on-duty cops at start, to ALL finishers — winner gets the full %,
        -- others a reduced share of it. (race.copCount is 0/nil for legal races.)
        local copBonus = 0
        local pb = RaceConfig.Rewards.policeBonus
        if pb and pb.enabled and (race.copCount or 0) > 0 then
            local pct = RaceConfig.policeBonusPct(race.copCount)
            local share = (place == 1) and (pb.winnerShare or 1.0) or (pb.otherShare or 0.5)
            copBonus = math.floor(amount * (pct / 100.0) * share)
        end
        local total = amount + copBonus
        local rewardStr = nil
        if total > 0 and payReward(src, currency, total) then
            rewardStr = formatReward(currency, total)
        end
        TriggerClientEvent('hk-race:client:finished', src, {
            place = place, reward = rewardStr, reduced = (mult < 1.0), starters = starters,
            prizeSlot = slot, laps = race.laps or 1,
            copBonus = (copBonus > 0) and formatReward(currency, copBonus) or nil,
            copCount = race.copCount or 0,
        })
        afterFinish()
    end

    if cpIndex >= seqLen then
        -- End of this lap's sequence.
        if isLoop then
            local curLap = race.lap[src] or 1
            if curLap >= (race.laps or 1) then
                doFinish()
            else
                -- Complete a lap: bump, reset progress, re-arm checkpoint 1.
                race.lap[src] = curLap + 1
                race.progress[src] = 0
                TriggerClientEvent('hk-race:client:lapUpdate', src,
                    { lap = race.lap[src], laps = race.laps or 1 })
                TriggerClientEvent('hk-race:client:advanceCheckpoint', src,
                    { next = 1, total = nCps, lap = race.lap[src], laps = race.laps or 1 })
                pushStandings(race)
            end
        else
            doFinish()
        end
    else
        -- Advance to the next index (may be the loop line at nCps+1 on a loop).
        TriggerClientEvent('hk-race:client:advanceCheckpoint', src,
            { next = cpIndex + 1, total = nCps })
        pushStandings(race)
    end
end)

-- Client reports a completed lap/run time (ms). We keep the track record (best
-- single lap for loops, best full run for one-way) + the holder's DISPLAY name.
RegisterNetEvent('hk-race:race:lapTime', function(rid, lapMs, vehicle, model, tier)
    local src = source
    local race = Races[rid]
    if not race or not race.participants[src] then return end
    lapMs = math.floor(tonumber(lapMs) or 0)
    if lapMs <= 0 or lapMs > 60 * 60 * 1000 then return end  -- sanity (<1h)
    local track = Tracks[race.trackId]
    if not track then return end

    local name = displayName(src)
    vehicle = tostring(vehicle or ''):sub(1, 64)
    model = tostring(model or ''):sub(1, 64)
    tier = math.floor(tonumber(tier) or 0)

    -- Time Attack gate: compare THIS lap to the per-tier record frozen at start
    -- (see beginRace). On a loop we keep the best beating lap; the payout in
    -- doFinish reads race.taBeat[src]. taGate[src] carries the record-to-beat for
    -- the "no payout" message. This runs BEFORE the insert so the frozen baseline
    -- is never polluted by this run's own rows.
    if race.timeAttack then
        local gate = race.taGateMap and race.taGateMap[tier]   -- nil = no record in this class yet
        race.taGate[src] = gate
        -- Payout requires BEATING an existing class record. The first run on a fresh
        -- class sets the record (recorded below) but banks nothing — there's no
        -- benchmark to beat, so a solo run on an unraced track can't mint free cash.
        if gate and lapMs < gate then
            if not race.taBeat[src] or lapMs < race.taBeat[src] then
                race.taBeat[src] = lapMs   -- keep the fastest beating lap (loops)
            end
        end
    end

    -- Record this attempt, then trim to the top-N PER TIER for this track (so a
    -- fast Super car can't crowd A/B off the board). Rank within a tier = how many
    -- same-tier rows are strictly faster (ties broken by id); keep rank < perTier.
    local perTier = (RaceConfig.Leaderboard and RaceConfig.Leaderboard.perTier) or 10
    MySQL.insert('INSERT INTO hk_race_leaderboard (track_id, ms, name, vehicle, model, tier) VALUES (?,?,?,?,?,?)',
        { track.id, lapMs, name, vehicle, model, tier }, function()
        MySQL.query([[
            DELETE FROM hk_race_leaderboard WHERE track_id = ? AND id NOT IN (
                SELECT id FROM (
                    SELECT lb.id FROM hk_race_leaderboard lb
                    WHERE lb.track_id = ? AND (
                        SELECT COUNT(*) FROM hk_race_leaderboard lb2
                        WHERE lb2.track_id = lb.track_id AND lb2.tier = lb.tier
                          AND (lb2.ms < lb.ms OR (lb2.ms = lb.ms AND lb2.id < lb.id))
                    ) < ?
                ) keep
            )
        ]], { track.id, track.id, perTier })
    end)

    -- Headline record (the #1 time) shown on the picker card.
    if not track.bestLapMs or lapMs < track.bestLapMs then
        track.bestLapMs = lapMs
        track.bestLapName = name
        MySQL.update('UPDATE hk_race_tracks SET best_lap_ms=?, best_lap_name=? WHERE id=?',
            { lapMs, name, track.id })
        sendToRace(race, 'hk-race:client:newRecord', { ms = lapMs, name = name })
    end
end)

-- Read-only: fetch a track's per-tier leaderboard for the picker. Ordered fastest
-- tier first (S→A→B), then by time. The client groups these into per-tier tables.
lib.callback.register('hk-race:lb:get', function(src, trackId)
    trackId = tonumber(trackId)
    local track = Tracks[trackId]
    local rows = MySQL.query.await(
        'SELECT ms, name, vehicle, model, tier FROM hk_race_leaderboard WHERE track_id = ? ORDER BY tier DESC, ms ASC',
        { trackId }) or {}
    return {
        trackName = track and track.name or 'Race',
        tierNames = RaceConfig.Tiers.names,
        rows = rows,
    }
end)

-- ── Admin leaderboard management ────────────────────────────────────────────
-- Admin variant of the LB fetch: includes each row's id (needed to edit/delete).
lib.callback.register('hk-race:admin:lbGet', function(src, trackId)
    if not isAdmin(src) then return { error = 'no_permission' } end
    trackId = tonumber(trackId)
    local track = Tracks[trackId]
    local rows = MySQL.query.await(
        'SELECT id, ms, name, vehicle, model, tier FROM hk_race_leaderboard WHERE track_id = ? ORDER BY tier DESC, ms ASC',
        { trackId }) or {}
    return {
        trackName = track and track.name or 'Race',
        tierNames = RaceConfig.Tiers.names,
        rows = rows,
    }
end)

-- Rename the racer on a leaderboard row. If this row is also the track's headline
-- record, keep best_lap_name in sync.
lib.callback.register('hk-race:admin:lbRename', function(src, rowId, newName)
    if not isAdmin(src) then return { error = 'no_permission' } end
    rowId = tonumber(rowId)
    newName = tostring(newName or ''):sub(1, 64)
    if not rowId or newName == '' then return { error = 'bad_args' } end
    MySQL.update('UPDATE hk_race_leaderboard SET name = ? WHERE id = ?', { newName, rowId })
    -- Sync the headline record name if this row is a track's current best.
    local row = MySQL.query.await('SELECT track_id, ms FROM hk_race_leaderboard WHERE id = ?', { rowId })
    row = row and row[1]
    if row then
        local track = Tracks[tonumber(row.track_id)]
        if track and track.bestLapMs and row.ms == track.bestLapMs then
            track.bestLapName = newName
            MySQL.update('UPDATE hk_race_tracks SET best_lap_name = ? WHERE id = ?', { newName, track.id })
        end
    end
    return { ok = true }
end)

-- Delete a leaderboard row. If it was the track's headline record, recompute the
-- headline from whatever's left (or clear it).
lib.callback.register('hk-race:admin:lbDelete', function(src, rowId)
    if not isAdmin(src) then return { error = 'no_permission' } end
    rowId = tonumber(rowId)
    if not rowId then return { error = 'bad_args' } end
    local row = MySQL.query.await('SELECT track_id, ms FROM hk_race_leaderboard WHERE id = ?', { rowId })
    row = row and row[1]
    MySQL.update('DELETE FROM hk_race_leaderboard WHERE id = ?', { rowId })
    if row then
        local tid = tonumber(row.track_id)
        local track = Tracks[tid]
        if track and track.bestLapMs and row.ms == track.bestLapMs then
            -- Recompute headline from the remaining fastest row.
            local best = MySQL.query.await(
                'SELECT ms, name FROM hk_race_leaderboard WHERE track_id = ? ORDER BY ms ASC LIMIT 1', { tid })
            best = best and best[1]
            if best then
                track.bestLapMs, track.bestLapName = best.ms, best.name
                MySQL.update('UPDATE hk_race_tracks SET best_lap_ms=?, best_lap_name=? WHERE id=?',
                    { best.ms, best.name, tid })
            else
                track.bestLapMs, track.bestLapName = nil, nil
                MySQL.update('UPDATE hk_race_tracks SET best_lap_ms=NULL, best_lap_name=NULL WHERE id=?', { tid })
            end
        end
    end
    return { ok = true }
end)

-- ── Quit / cleanup ─────────────────────────────────────────────────────────
local function removeFromRace(src, quitByPlayer)
    local rid, race = playerRaceId(src)
    if not race then return end
    race.participants[src] = nil
    if quitByPlayer then
        TriggerClientEvent('hk-race:client:raceEnded', src, { reason = 'quit' })
    end
    -- Host left: hand off or dissolve.
    if race.hostSrc == src then
        local nextHost = nil
        for psrc in pairs(race.participants) do nextHost = psrc break end
        if nextHost then
            race.hostSrc = nextHost
        elseif not race.started then
            if not race.started then TrackBusy[race.trackId] = nil end  -- forming → free circuit
            Races[rid] = nil
            TriggerClientEvent('hk-race:client:lobbyClose', -1, rid)
            return
        end
    end
    if participantCount(race) == 0 then
        if not race.started then TrackBusy[race.trackId] = nil end  -- forming → free circuit
        Races[rid] = nil
        TriggerClientEvent('hk-race:client:lobbyClose', -1, rid)
    else
        sendToRace(race, 'hk-race:client:lobbyUpdate', { count = participantCount(race) })
    end
end

RegisterNetEvent('hk-race:race:quit', function()
    removeFromRace(source, true)
end)

AddEventHandler('playerDropped', function()
    removeFromRace(source, false)
    muted[source] = nil
end)

-- /quitrace is registered client-side; it fires hk-race:race:quit which we handle above.

-- Admin command opens the NUI panel (client validates too).
RegisterCommand(RaceConfig.AdminCommand, function(src)
    if src == 0 then return end
    if not isAdmin(src) then
        TriggerClientEvent('QBCore:Notify', src, L('no_permission'), 'error')
        return
    end
    TriggerClientEvent('hk-race:client:openAdmin', src)
end, false)

-- /racehide — toggle whether your name shows on race leaderboards/standings.
RegisterCommand('racehide', function(src)
    if src == 0 then return end
    local lic = licenseOf(src)
    if not lic then return end
    if RaceHidden[lic] then
        RaceHidden[lic] = nil
        MySQL.update('DELETE FROM hk_race_hidden WHERE license = ?', { lic })
        TriggerClientEvent('QBCore:Notify', src, L('racehide_off'), 'success')
    else
        RaceHidden[lic] = true
        MySQL.update('INSERT IGNORE INTO hk_race_hidden (license) VALUES (?)', { lic })
        TriggerClientEvent('QBCore:Notify', src, L('racehide_on'), 'inform')
    end
end, false)



