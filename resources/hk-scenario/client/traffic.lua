--=====================================================================
-- hk-scenario :: client/traffic.lua
--   NO HESI / Wangan-style traffic realism (live, server-driven).
--
--   Layer 4  AMBIENT BEHAVIOUR — tunes existing NPC drivers (ability,
--            aggression, driving style, cruise speed) so vanilla traffic
--            stops crawling. Stronger on highways.
--   Layer 5  HIGHWAY SPAWNER   — chunk-gated: only while the player is
--            driving on a highway, streams NETWORKED fast cruisers ahead
--            on road nodes, with an occasional curated hkcarpack addon
--            mixed in (rare, so police can't tell them from real players).
--
--   Boot-time companions (NOT here): data/gameconfig.xml raises engine
--   population caps; data/ai_handling.meta raises the AI handling profiles
--   so the engine ALLOWS these higher speeds. Both apply on spawn/reconnect.
--
--   Settings arrive via hk-scenario:traffic:sync (server/traffic.lua).
--   enabled=false => this whole file idles cheaply.
--=====================================================================

local T = ScnCfg.Traffic or {}
local B = T.Biomes or {}

-- Live settings (nil until first sync). See server/traffic.lua sanitize().
local S = nil

-- ── Biome state (Layer 4.5) ──────────────────────────────────────────────────
-- Current region profile, resolved from GetNameOfZone on a slow thread. This is
-- the POSITION-based fix for the old circular highway detection: a road is fast
-- because of WHERE it is (openRoad), not because a car already happens to be
-- going fast on it. curBiome is read by tuneDriver + the Layer-5 spawner gate.
local curBiome      = B.default or { speedMult = 1.0, openRoad = false, spawnerMinKmh = 75 }
local curBiomeName  = nil
local lastPushedBiome = nil   -- last zone we pushed density for (biome dedupe)

-- Runtime biome OVERRIDES set live via /settraffic. Keyed by zone code (upper),
-- each entry is a partial profile { speedMult=, densityMult=, openRoad= } that is
-- LAYERED on top of the config zone/default when resolving curBiome. Lets you tune
-- any region on the fly without editing config.lua + redeploy. Not persisted (a
-- resource restart reverts to config) — that's intentional for quick live tuning.
local biomeOverrides = {}
local biomeDirty = false   -- set true when an override changes → force re-resolve
-- resolve the effective profile for a zone code: config zone (or default) with
-- any live override merged over it.
local function resolveBiome(zone)
    local base = (B.zones and B.zones[zone]) or B.default
        or { speedMult = 1.0, openRoad = false, spawnerMinKmh = 75 }
    local ov = biomeOverrides[zone]
    if not ov then return base end
    local merged = {}
    for k, v in pairs(base) do merged[k] = v end
    for k, v in pairs(ov)   do merged[k] = v end
    return merged
end

-- Networked cars WE spawned (Layer 5). map: entity -> { addon=bool, born=ms }
local spawned = {}
local spawnedCount = 0
local addonAliveCount = 0
local baseAliveCount = 0
local lastSpawnAttempt = 0
local lastSpawnOk = false      -- (v2.4.64) did the previous spawn attempt succeed?
                               -- drives the normal-path 8s (ok) / 4s (fail) cadence.

-- COUNTER RECONCILE (v2.4.51 — user: "after a long AFK, OK froze at 270 and the
-- fleet stopped spawning; a restart fixed it"). The running spawnedCount tally can
-- DRIFT above the real live-car count over a long session (any path that drops a
-- car from `spawned` without hitting the shared decrement — stream-out races,
-- error mid-cull, an entity that vanished before we saw it). Once the phantom
-- surplus reaches the cap EVERY attempt bails 'cap' and the fleet is permanently
-- wedged until a restart zeroes the counters. Fix: make the counts AUTHORITATIVE
-- from the actual table instead of trusting the tally — recompute from `spawned`
-- (skipping dead entities) so the numbers self-heal every spawner tick. This is
-- the invisible "pool reset": it corrects bookkeeping only, never touches a real
-- car. Returns the surplus it corrected (for the debug overlay).
local function reconcileCounts()
    local total, addon, base = 0, 0, 0
    for veh, meta in pairs(spawned) do
        if DoesEntityExist(veh) then
            total = total + 1
            if meta.addon then addon = addon + 1 else base = base + 1 end
        end
    end
    local drift = spawnedCount - total
    spawnedCount, addonAliveCount, baseAliveCount = total, addon, base
    return drift
end

-- DEBUG: why did the last spawn attempts bail? counts per reason, shown in the
-- /hktraffic HUD so we can see WHICH gate is rejecting every spawn. Cheap.
local dbgBails = {}
local dbgLastBail = '-'
local dbgAttempts = 0
local dbgSpawnOk = 0
local dbgCountDrift = 0   -- (v2.4.51) surplus corrected by reconcileCounts() last tick
local function bail(reason)
    dbgBails[reason] = (dbgBails[reason] or 0) + 1
    dbgLastBail = reason
end

-- Per-NPC-driver "last tuned" timestamps so we don't re-task every scan.
-- keyed by ped handle; pruned opportunistically.
local tunedPeds = {}

local function nowMs() return GetGameTimer() end
local function kmhToMs(kmh) return (kmh or 0) * 0.27778 end

-- SIGNED ground speed along the car's heading (m/s). GetEntitySpeed is UNSIGNED,
-- so a car coasting BACKWARD after a reverse temp action still reads > 0 there —
-- the watchdog then mistook that backward roll for "recovered/moving", wiped the
-- stuck state, and left the car taskless still rolling back (user: "reverse text
-- gone but it's still going backwards"). This returns NEGATIVE while reversing so
-- the "moving forward" test is honest. (v2.4.49)
local function fwdSpeed(veh)
    local fv = GetEntityForwardVector(veh)
    local v  = GetEntityVelocity(veh)
    return v.x * fv.x + v.y * fv.y
end

-- SIDE-LANE CLEARANCE (v2.4.68 — user: "when gap-hold flickers a few times, go
-- overtake / to the side lane IF POSSIBLE"). Before committing a flick-triggered
-- overtake, check that an adjacent lane is actually free so the car doesn't pull
-- out into a car alongside/ahead-beside it. Reuses the tick's pre-built near-vehicle
-- arrays (no extra pool scan). Returns 'L', 'R', or nil (neither side clear):
--   • project each nearby car into the passing car's frame: `ahead` = forward dot,
--     `side` = right-vector dot (signed: +right / -left).
--   • a car occupies the side "pass box" if it's within a lateral band [inner,outer]
--     on that side AND longitudinally alongside-or-ahead within checkAhead / behind
--     within checkBehind (a car just behind in the target lane can still catch up).
--   • prefer LEFT (normal overtaking side); fall back to RIGHT if left is blocked.
local function sideLaneClear(veh, vc, fwd, nearVeh, nearCoord, nearN, cfg, preferRight)
    local right      = vector3(fwd.y, -fwd.x, 0.0)
    local innerBand  = cfg.overtakeSideInner or 2.2    -- start of the adjacent lane (m from centre)
    local outerBand  = cfg.overtakeSideOuter or 6.5    -- outer edge of the adjacent lane (m)
    local checkAhead = cfg.overtakeSideAhead or 28.0   -- clear this far ahead in the target lane
    local checkBehind= cfg.overtakeSideBehind or 12.0  -- and this far behind (car could catch up)
    local leftBlocked, rightBlocked = false, false
    for i = 1, nearN do
        local other = nearVeh[i]
        if other ~= veh then
            local to = nearCoord[i] - vc
            local ah = to.x * fwd.x + to.y * fwd.y            -- + = ahead
            local sd = to.x * right.x + to.y * right.y        -- + = to our right
            if ah < checkAhead and ah > -checkBehind then     -- longitudinally in the pass window
                local adist = math.abs(sd)
                if adist >= innerBand and adist <= outerBand then
                    if sd < 0.0 then leftBlocked = true else rightBlocked = true end
                end
            end
        end
    end
    -- a YIELDING car (honked at) should move to the RIGHT/slow lane to let the
    -- player pass on the left; an OVERTAKER prefers LEFT (the passing side).
    if preferRight then
        if not rightBlocked then return 'R' end
        if not leftBlocked then return 'L' end
        return nil
    end
    if not leftBlocked then return 'L' end
    if not rightBlocked then return 'R' end
    return nil
end

-- ── Sync ─────────────────────────────────────────────────────────────────────
RegisterNetEvent('hk-scenario:traffic:sync', function(s)
    S = s   -- may carry enabled=false (system idles)
    -- force the biome thread to re-resolve + re-push density next tick, so
    -- enabling traffic applies the current region's population without waiting
    -- for the player to cross a zone boundary.
    curBiomeName   = nil
    lastPushedBiome = nil
end)

AddEventHandler('onClientResourceStart', function(res)
    if res ~= GetCurrentResourceName() then return end
    TriggerServerEvent('hk-scenario:traffic:requestSync')
    TriggerServerEvent('hk-scenario:traffic:requestBiomes')
    TriggerServerEvent('hk-scenario:traffic:requestBlacklist')   -- v2.4.54
end)

-- Persisted biome overrides pushed from the server (set via /settraffic, saved
-- in hk_scenario_meta k='traffic_biomes'). Replaces the whole table + forces a
-- re-resolve so the change applies immediately server-wide.
RegisterNetEvent('hk-scenario:traffic:biomeSync', function(ov)
    biomeOverrides = (type(ov) == 'table') and ov or {}
    biomeDirty = true
end)

-- ── Layer 4.5: biome resolver ────────────────────────────────────────────────
-- Slow thread: reads the player's current zone code (GetNameOfZone) and looks up
-- its traffic profile. This drives BOTH the ambient speed multiplier and, when
-- traffic is enabled, the per-region population density (pushed into the density
-- module so qb-smallresources stays the single per-frame authority).
--
-- Density: we only push while traffic is enabled AND biomes are enabled. We
-- multiply the configured baseDensity by the biome's densityMult so deserts
-- thin out and towns stay fuller. When traffic is off we don't touch density
-- (leaves the density-editor / qb defaults alone).
local function pushBiomeDensity()
    if not (B.enabled and S and S.enabled) then return end
    local base = B.baseDensity or { vehicle = 0.60, parked = 0.40, peds = 0.60, scenario = 0.30 }
    local m = curBiome.densityMult or 1.0
    -- clamp so a mult can't drive anything absurd
    local function cl(v) return math.max(0.0, math.min(1.0, v)) end
    local d = {
        vehicle  = cl((base.vehicle  or 0.60) * m),
        parked   = cl((base.parked   or 0.40) * m),
        peds     = cl((base.peds     or 0.60) * m),
        scenario = cl((base.scenario or 0.30) * m),
    }
    -- Route through the density module (population.lua) so it stays the single
    -- writer AND enforces its manual-override guard (an admin's saved density
    -- setting wins over automatic biome variation). If the hook is missing we
    -- simply skip — biome SPEED still works without density control.
    if _G.Scn_pushDensity then _G.Scn_pushDensity(d) end
end

CreateThread(function()
    -- prime immediately so the first tune already knows the region
    while true do
        if B.enabled == false then
            Wait(5000)
        else
            local ped = PlayerPedId()
            local c = GetEntityCoords(ped)
            local zone = GetNameOfZone(c.x, c.y, c.z)   -- e.g. "SANDY", "ARMYB"
            if zone ~= curBiomeName or biomeDirty then
                biomeDirty = false
                curBiomeName = zone
                curBiome = resolveBiome(zone)
                if ScnCfg.Debug then
                    print(('[hk-scenario] biome -> %s (speedMult=%.2f open=%s)'):format(
                        tostring(zone), curBiome.speedMult or 1.0, tostring(curBiome.openRoad)))
                end
                if lastPushedBiome ~= zone then
                    lastPushedBiome = zone
                    pushBiomeDensity()
                end
                -- Force ambient drivers to re-tune under the new region's
                -- speedMult / open-road flag right away, instead of waiting out
                -- retuneAfter. tunedPeds is file-scoped (Layer 4 loop owns it).
                tunedPeds = {}
            end
            Wait(B.scanInterval or 1500)
        end
    end
end)

-- ── Addon tier buckets (via hk-race classification) ─────────────────────────
-- The addon roster is sourced LIVE from qb-core's QBShared.Vehicles (the shop
-- registry) so it ALWAYS follows whatever cars are actually in the pack — no
-- more hand-maintained 12-model list (which is why only nsx/rx7/m3 kept showing
-- up). Each model is bucketed into B / A / S from the SERVER-SENT tier map.
-- tierBuckets[tier] = { modelName, ... }.
--
-- v2.4.53 — deck-wedge fix + remove emergency prevention: the class-18 emergency
--   bail deleted the car WITHOUT counting the model, so an emergency-class roster
--   car stayed deckUse=0 forever → once every other car capped, the deck never
--   exhausted/reset and pickAddonByTier handed back the same un-spawnable model →
--   `ok` froze at ~270, lastbail stuck 'emergency'. Fix: (1) removed the runtime
--   emergency guards (roster blacklist + name filter already exclude cop cars);
--   (2) NEW deckFail/deckBurn — post-pick spawn FAILURES count toward the per-car
--   deck cap too (deckCount = spawns+fails), so no un-spawnable model can wedge the
--   deck/cap; failures clear on deck reset. History:
-- v2.4.52 — PARKED-CAR REPLACEMENT: hijack the game's OWN ambient EMPTY parked
--   cars (real parking spots, correctly placed) and swap the model IN PLACE
--   off-screen — same coords/heading, left parked (local veh, frozen, no driver).
--   Curated hkcarpack fleet as scenery, no road-node snapping / no stuck cars
--   (the safe opposite of the 2026-08-26 sprinkler that CREATED parked cars).
-- v2.4.51 — self-healing fleet counts: reconcileCounts() re-derives spawnedCount/
--   addonAliveCount/baseAliveCount from the live `spawned` table each spawner tick,
--   so a drifted tally (that froze OK at the cap after long AFK and needed a manual
--   restart) can never permanently wedge the cap again. Invisible — bookkeeping
--   only, never touches a real car. Debug overlay gains a `drift` field. History:
-- v2.4.50 — confined-zone ghost despawn: a car anchored within confineRadius (6m)
--   for confineDespawnMs (45s) — jittering/reverse-oscillating in place, so the
--   speed-based stuckDeleteMs never trips — fades out (alpha ramp) + deletes quietly.
-- v2.4.49 — reverse "stuck going backwards" fix: (1) watchdog "moving" test now
--   uses SIGNED forward speed (fwdSpeed) not unsigned GetEntitySpeed, so a backward
--   coast no longer reads as recovery; (2) reverse falling-edge re-issues a forward
--   drive task + kills residual backward roll the instant the 1s reverse expires
--   (temp actions don't auto-restore → car was coasting back taskless). History:
-- v2.4.48 — red-light/junction yield-detect: on clear road a car slowing on its
--   own while we command MORE speed = a native red-light stop; we stop pushing
--   (kills curve-bust) + soft straight-brake so it stops BEFORE the line. History:
-- v2.4.46 — tier detection reads hk-race's DB directly (server-side). History:
-- v2.4.42 tried hk-race's runtime lib.callback (getCalMap/getOverrides), but
-- callback timing / hk-race boot order made the roster unreliable. Since hk-race
-- persists everything to the DB (hk_race_car_cal + hk_race_car_tiers) and NPC
-- spawning doesn't need it fresh, hk-scenario's SERVER now reads those tables,
-- computes each model's tier with hk-race's own scoring, and pushes a finished
-- `modelLower -> 'B'|'A'|'S'` table via hk-scenario:traffic:tierMap. The client
-- just looks up — see tierMapFromServer below. (Predecessor of that: the old
-- exports['hk-race']:classifyByHash call, which was never a real export.)
local tierBuckets = { B = {}, A = {}, S = {} }
local tierReady = false

-- Vehicle tier map, computed SERVER-SIDE straight from hk-race's DB tables and
-- pushed here (v2.4.46). Replaces the v2.4.42 runtime lib.callback dance, which
-- was fragile (callback timing / hk-race boot order). The server reads
-- hk_race_car_cal + hk_race_car_tiers, applies hk-race's own scoring, and sends
-- a finished `modelLower -> 'B'|'A'|'S'` table. We just look up. For NPC spawning
-- staleness is fine — it re-reads the DB on request/join and on /scntiers.
local tierMapFromServer = {}   -- [modelLower] = 'B' | 'A' | 'S'
local RT_NAMES = { 'B', 'A', 'S' }   -- tier names (also iterated by the deck below)

RegisterNetEvent('hk-scenario:traffic:tierMap', function(map)
    if type(map) == 'table' then
        tierMapFromServer = map
        tierReady = false      -- reclassify buckets on the next cycle
    end
end)

-- ── Spawn diversity deck (v2.4.42) ───────────────────────────────────────────
-- User: "the spawn list is not diverse enough — same few cars every round. Until
-- the whole car list has been spawned through, each vehicle can only spawn twice
-- per server uptime, until the list finishes or I restart."
-- deckUse[model] = how many times it has spawned this cycle. A model is picked
-- only while deckUse < deckMax; once EVERY roster car hits the cap the deck
-- resets (a fresh cycle). Reset also happens implicitly on resource restart
-- (this local starts empty). Increment happens at ACTUAL spawn success, so a
-- pick that later fails a spawn gate doesn't burn one of the car's two slots.
local deckUse = {}
-- v2.4.53 — DECK-WEDGE FIX: a model that gets PICKED but then fails to spawn (it
-- was deleted at a post-pick gate: create-fail, no-ground, no-driver, or — before
-- v2.4.53 — the emergency class bail) never called deckNote, so it stayed at
-- deckUse=0 forever = permanently "available". Once every OTHER car hit the cap,
-- the only models left in deckAvail were these un-spawnable ones, deckExhausted()
-- could never be true (they're stuck below cap), the deck NEVER reset, and
-- pickAddonByTier handed back the same failing model every time → `ok` froze
-- (the 270 wedge, lastbail stuck on 'emergency'). Fix: count FAILURES too. The
-- deck's "effective" use for a model = spawns + fails, so a model that can't
-- spawn still climbs to the cap and stops being picked / lets the cycle finish.
local deckFail = {}
local function deckMax() return (T.spawner and T.spawner.deckMaxPerCar) or 2 end
-- effective deck count = real spawns + failed attempts (both count toward the cap)
local function deckCount(model) return (deckUse[model] or 0) + (deckFail[model] or 0) end
-- filter a model list to those still under the per-car cap
local function deckAvail(list)
    local m, out = deckMax(), {}
    for i = 1, #list do
        if deckCount(list[i]) < m then out[#out + 1] = list[i] end
    end
    return out
end
-- true when every model across all tier buckets is at the cap → cycle done
local function deckExhausted()
    local m = deckMax()
    for _, tier in ipairs(RT_NAMES) do
        local b = tierBuckets[tier]
        if b then
            for i = 1, #b do
                if deckCount(b[i]) < m then return false end
            end
        end
    end
    return true
end
local function deckReset()
    deckUse = {}
    deckFail = {}
    if ScnCfg.Debug then print('[hk-scenario] spawn deck exhausted → reset (new cycle)') end
end
-- record an actual spawn against the deck (called at spawn-success)
local function deckNote(model)
    if not model then return end
    deckUse[model] = (deckUse[model] or 0) + 1
end
-- record a FAILED spawn against the deck (called at any post-pick bail) so a
-- model that can't spawn can't wedge the deck / cap. Clears on the next reset.
local function deckBurn(model)
    if not model then return end
    deckFail[model] = (deckFail[model] or 0) + 1
end

-- categories in QBShared.Vehicles that are NOT street cars we want in traffic.
local NON_STREET_CATS = {
    boats = true, boat = true, jetski = true, sail = true,
    cycles = true, police = true, medic = true, emergency = true,
}
-- shops that only sell service/emergency vehicles — skip wholesale.
local NON_STREET_SHOPS = {
    police = true, pd = true, ems = true, emergency = true, gov = true,
}
-- model-name substrings that mark an emergency/service vehicle even if it got
-- mis-categorised as "sports". Belt-and-suspenders so a cop car NEVER shows up
-- in ambient traffic (they'd blow the "confuse police" illusion instantly).
local EMERGENCY_NAME_PAT = {
    'police', 'sheriff', 'fbi', 'swat', 'ambulance', 'medic', 'ems',
    'firetruk', 'fire', 'lguard', 'ranger', 'pbus', 'riot', 'undercover',
    'cop', 'patrol', 'unmarked',
}
local function looksEmergency(model)
    for _, p in ipairs(EMERGENCY_NAME_PAT) do
        if model:find(p, 1, true) then return true end
    end
    return false
end

-- ── Blacklist + stock-vs-custom addon detection ─────────────────────────────
-- Built once from config into hash-keyed lookup sets (fast membership tests).
-- BLACKLIST: models the user never wants to see spawn at all (any source).
-- STOCK set: base-GTA / built-in vehicle names. qb-core's QBShared.Vehicles is
-- full of base game cars tagged 'sports' (e.g. ninef2 = the Obey 9F Cabrio) —
-- those are NOT real custom addons, so we exclude them from the ADDON roster
-- (they can still appear as ordinary base traffic). "Real custom cars only".
local blacklistSet, stockSet, antiRecklessSet
local function rebuildLookups()
    blacklistSet, stockSet, antiRecklessSet = {}, {}, {}
    for _, name in ipairs(T.blacklist or {}) do
        blacklistSet[tostring(name):lower()] = true
    end
    for _, name in ipairs(T.stockModels or {}) do
        stockSet[tostring(name):lower()] = true
    end
    -- models that must ALWAYS drive calm/law-abiding like a native normal NPC
    -- (never reckless, never the aggressive addon profile). User-editable.
    for _, name in ipairs(T.antiReckless or {}) do
        antiRecklessSet[tostring(name):lower()] = true
    end
end
rebuildLookups()

-- RUNTIME BLACKLIST (v2.4.54): admin-added models via /trafficblacklist, pushed
-- from the server (persisted in hk_scenario_meta). Merged on top of the config
-- blacklist so a car banned at runtime stops spawning immediately, server-wide,
-- and the ban survives restarts. Kept in sync by the blacklistSync handler below.
local runtimeBlacklist = {}   -- [modelLower] = true

local function isBlacklisted(model)
    if not blacklistSet then rebuildLookups() end
    local m = tostring(model):lower()
    return blacklistSet[m] == true or runtimeBlacklist[m] == true
end

-- Server pushes the full runtime blacklist (array of lowercased model names) on
-- boot, on change, and on request. Replace the whole set. If a currently-tracked
-- car matches a newly-blacklisted model, drop it so it disappears next cull —
-- but only when off-screen (never vanish one in the player's face).
RegisterNetEvent('hk-scenario:traffic:blacklistSync', function(list)
    local set = {}
    if type(list) == 'table' then
        for _, m in ipairs(list) do set[tostring(m):lower()] = true end
    end
    runtimeBlacklist = set
end)

-- true when the model is pinned to safe/native-normal driving (config antiReckless)
local function isAntiReckless(model)
    if not antiRecklessSet then rebuildLookups() end
    return antiRecklessSet[tostring(model):lower()] == true
end

-- A model counts as a REAL custom addon only if it's NOT in the stock set.
-- (Config drives this so the user can correct any mislabelled car by editing
-- the stockModels / customModels lists — no code change needed.)
local function isRealAddon(model)
    if not stockSet then rebuildLookups() end
    local m = tostring(model):lower()
    -- explicit custom override always wins (force-treat a name as custom)
    if T.customModels then
        for _, n in ipairs(T.customModels) do
            if tostring(n):lower() == m then return true end
        end
    end
    return stockSet[m] ~= true
end

-- Pull the candidate addon model list. Prefer qb-core's shared registry (the
-- authoritative, auto-updating source); fall back to the config allowlist only
-- if qb-core isn't available or is empty.
local function collectAddonModels()
    local out, seen = {}, {}
    local useQb = (T.useQbCoreRoster ~= false)
    if useQb and QBShared and type(QBShared.Vehicles) == 'table' then
        for model, v in pairs(QBShared.Vehicles) do
            local cat  = tostring(v and v.category or ''):lower()
            local vt   = tostring(v and v.type or 'automobile'):lower()
            local shop = tostring(v and v.shop or ''):lower()
            local m    = tostring(model):lower()
            -- ALLOWLIST: sports automobiles ONLY. We deliberately do not accept
            -- any other category (sedans/suvs/muscle/vans/etc) — the Wangan feel
            -- wants performance cars only. Shop + name guards still exclude any
            -- cop/emergency unit that got mis-tagged 'sports'.
            if cat == 'sports' and vt == 'automobile'
                and not NON_STREET_SHOPS[shop] and not looksEmergency(m)
                and not isBlacklisted(m)
                -- REAL CUSTOM CARS ONLY: skip base-GTA models qb-core tags as
                -- 'sports' (ninef2, comet, etc). They still show as base traffic;
                -- they just don't count toward the "custom addon" roster.
                and isRealAddon(m) then
                if not seen[m] then
                    local hash = joaat(m)
                    -- must be a real, registerable vehicle model
                    if IsModelValid(hash) and IsModelAVehicle(hash) then
                        seen[m] = true
                        out[#out + 1] = m
                    end
                end
            end
        end
    end
    if #out == 0 then
        -- fallback: hardcoded curated list from config (still blacklist-filtered)
        for _, name in ipairs(T.addonModels or {}) do
            local m = tostring(name):lower()
            if not seen[m] and not isBlacklisted(m) then
                seen[m] = true; out[#out + 1] = m
            end
        end
    end
    return out
end

-- Fetch hk-race's tier data over its real callbacks. Returns true once we have
-- Bucket the roster by tier using the SERVER-SENT map (v2.4.46). No hashing, no
-- callbacks, no hk-race-started gate — the server already did the DB read and
-- scoring; we just look up `model -> tier`. Unknowns (not in the map yet) are
-- spread across B/A so common traffic still skews slower and S stays rare.
local function buildTierBuckets()
    local models = collectAddonModels()
    if #models == 0 then return end
    -- nothing from the server yet → stay not-ready so pickAddonByTier uses the
    -- flat roster; the tierMap net-event flips tierReady=false to reclassify.
    if not next(tierMapFromServer) then tierReady = false; return end
    local buckets = { B = {}, A = {}, S = {} }
    local classified, unknown = 0, 0
    for _, name in ipairs(models) do
        local tname = tierMapFromServer[tostring(name):lower()]
        if tname == 'B' or tname == 'A' or tname == 'S' then
            buckets[tname][#buckets[tname] + 1] = name
            classified = classified + 1
        else
            unknown = unknown + 1
            local b = (unknown % 3 == 0) and 'A' or 'B'
            buckets[b][#buckets[b] + 1] = name
        end
    end
    tierBuckets = buckets
    tierReady = true
    if ScnCfg.Debug then
        print(('[hk-scenario] addon roster: %d cars (B=%d A=%d S=%d) classified=%d unknown=%d src=db-tiermap'):format(
            #models, #buckets.B, #buckets.A, #buckets.S, classified, unknown))
    end
end

CreateThread(function()
    -- ask the server for the tier map, then bucket once it arrives. Retry until
    -- the map lands (server reads it from the DB on MySQL.ready) or we give up
    -- and run flat. The tierMap net-event also re-triggers classification.
    TriggerServerEvent('hk-scenario:traffic:requestTierMap')
    for _ = 1, 20 do
        Wait(2000)
        if not tierReady then
            if not next(tierMapFromServer) then
                TriggerServerEvent('hk-scenario:traffic:requestTierMap')
            end
            buildTierBuckets()
        end
        if tierReady then break end
    end
end)

-- Pick an addon model name weighted by tier (B common, A moderate, S rare).
-- Returns (modelName, tierName) so callers can apply a per-tier speed cap.
local function pickAddonByTier()
    if not tierReady then
        local list = T.addonModels or {}
        if #list == 0 then return nil, nil end
        return list[math.random(#list)], nil
    end
    -- DECK (v2.4.42): if every roster car has hit its per-cycle cap, reset so the
    -- whole list can spawn again. Then only consider cars still under the cap, so
    -- no model repeats a 3rd time until the entire roster has been through twice.
    if deckExhausted() then deckReset() end
    local w = T.tierWeights or { B = 70, A = 25, S = 5 }
    -- only weight tiers that STILL HAVE available (under-cap) models
    local avail = { B = deckAvail(tierBuckets.B), A = deckAvail(tierBuckets.A), S = deckAvail(tierBuckets.S) }
    local pool, total = {}, 0
    for _, tier in ipairs({ 'B', 'A', 'S' }) do
        if #avail[tier] > 0 and (w[tier] or 0) > 0 then
            total = total + w[tier]
            pool[#pool + 1] = { tier = tier, upto = total }
        end
    end
    if total == 0 then
        -- weighted tiers all capped out this instant (e.g. only S left but S
        -- weight 0) → fall back to ANY available car across buckets, else flat.
        for _, tier in ipairs({ 'B', 'A', 'S' }) do
            local a = avail[tier]
            if #a > 0 then return a[math.random(#a)], tier end
        end
        local list = T.addonModels or {}
        return (#list > 0 and list[math.random(#list)] or nil), nil
    end
    local roll = math.random() * total
    local chosen = pool[#pool].tier
    for _, e in ipairs(pool) do
        if roll <= e.upto then chosen = e.tier; break end
    end
    local bucket = avail[chosen]
    return bucket[math.random(#bucket)], chosen
end

-- ── Helpers ────────────────────────────────────────────────────────────────
-- Reuse the protection logic from client/main.lua so we NEVER touch player
-- cars, hk-parking parked cars, or our own scenario props. isProtected is a
-- local there; expose-safe fallbacks keep this resilient if it's ever missing.
local function protectedVeh(veh)
    -- our own spawned traffic is handled separately (addonDriveTick owns it) —
    -- SKIP it in the ambient loop, otherwise the native re-tune (which now
    -- re-issues a wander task) would fight addonDriveTick's cruise/style/brake
    -- every 8s. protectedVeh==true means "ambient loop leaves this car alone".
    if spawned[veh] then return true end
    if Scn_isTrafficProtected then return Scn_isTrafficProtected(veh) end
    -- fallback: skip player-driven + mission entities
    local drv = GetPedInVehicleSeat(veh, -1)
    if drv == PlayerPedId() then return true end
    if IsPedAPlayer(drv) then return true end
    return false
end

-- SCENARIO ZONE BLOCK (v2.4.37): the scenario builder lets the user paint zones
-- that clear/block ambient traffic (client/main.lua's `Zones`, a resource global).
-- Our own highway spawner was ignoring them, so addon cars kept popping inside
-- areas the user explicitly zoned as no-traffic. Honour any ACTIVE zone that
-- clears vehicles or blocks the road/navmesh: never spawn a car inside its
-- footprint (+ a margin so it doesn't spawn on the edge and roll in). Mirrors
-- main.lua's entIn() geometry (that helper is file-local, so we replicate it).
local function pointInScnZone(z, ex, ey, ez, margin)
    margin = margin or 0.0
    if z.shape == 'box' then
        local dz = ez - z.z
        if math.abs(dz) > (z.height * 0.5 + 5.0 + margin) then return false end
        local rad = -math.rad(z.heading or 0.0)
        local c, s = math.cos(rad), math.sin(rad)
        local dx, dy = ex - z.x, ey - z.y
        local lx = dx * c - dy * s
        local ly = dx * s + dy * c
        return math.abs(lx) <= (z.length * 0.5 + margin)
           and math.abs(ly) <= (z.width  * 0.5 + margin)
    else
        local r = (z.radius or 0.0) + margin
        if math.abs(ez - z.z) > (z.radius + 20.0) then return false end
        local dx, dy = ex - z.x, ey - z.y
        return (dx * dx + dy * dy) <= (r * r)
    end
end

-- true if (x,y,z) sits inside any ACTIVE traffic-blocking scenario zone.
-- margin defaults to the spawn margin (keep cars OUT of the edge); pass 0 for the
-- cull check (only remove cars actually inside the footprint).
local function inBlockedScnZone(x, y, z, margin)
    local zs = Zones          -- resource global from client/main.lua
    if type(zs) ~= 'table' then return false end
    local sp = T.spawner or {}
    if margin == nil then margin = sp.zoneSpawnMargin or 15.0 end
    for i = 1, #zs do
        local zn = zs[i]
        if zn and zn.enabled
           and (zn.clr_vehicles or zn.blk_roads or zn.blk_navmesh)
           and pointInScnZone(zn, x, y, z, margin) then
            return true
        end
    end
    return false
end

-- hk-optimizer "potato" check (soft): skip the spawner on the lowest presets.
local function optimizerBlocksSpawner()
    if not (T.honorOptimizer) then return false end
    if GetResourceState('hk-optimizer') ~= 'started' then return false end
    local ok, mode = pcall(function()
        return exports['hk-optimizer']:GetActiveMode()
    end)
    if ok and type(mode) == 'string' then
        local m = mode:lower()
        if m:find('potato') or m:find('min') or m:find('low') then return true end
    end
    return false
end

-- current player driving speed in km/h (0 if on foot / passenger)
local function playerDriveKmh()
    local ped = PlayerPedId()
    local veh = GetVehiclePedIsIn(ped, false)
    if veh == 0 or GetPedInVehicleSeat(veh, -1) ~= ped then return 0.0, 0 end
    return GetEntitySpeed(veh) * 3.6, veh
end

-- Apply a preset's driving params to one NPC driver + its vehicle.
local function tuneDriver(veh, driver, preset, onHighway)
    if not DoesEntityExist(veh) or not DoesEntityExist(driver) then return end
    SetDriverAbility(driver, preset.ability or 0.7)
    SetDriverAggressiveness(driver, preset.aggression or 0.3)
    SetDriveTaskDrivingStyle(driver, preset.style or 262317)
    -- Stop the vanilla "NPC deliberately swerves into the player at speed"
    -- behaviour: make ambient drivers actively steer AROUND traffic. The real
    -- close passes then come from aggression, not scripted ramming.
    SetPedSteersAroundVehicles(driver, true)
    SetPedSteersAroundPeds(driver, true)
    SetPedSteersAroundObjects(driver, true)
    -- Let the car actually use its power (engine on, not speed-limited down).
    SetVehicleEngineOn(veh, true, true, false)
    SetEntityMaxSpeed(veh, 999.0)   -- clear any lingering engine speed clamp
    -- BIOME (Layer 4.5): open-road biomes (desert, Route 68, Fort Zancudo
    -- crossing) ALWAYS grant the highway bonus regardless of current speed —
    -- this breaks the old circular "must already be fast to count as highway"
    -- detection. Then the whole cruise is scaled by the region's speedMult.
    local openBonus = onHighway or (curBiome and curBiome.openRoad)
    local kmh = (preset.cruiseKmh or 85) + (openBonus and (preset.highwayBonusKmh or 0) or 0)
    kmh = kmh * ((curBiome and curBiome.speedMult) or 1.0)
    -- NATIVE-SPEED BUMP (per user "native NPCs drive way too slow"): a flat
    -- multiplier on ambient driver cruise, ON TOP of preset + biome. GTA's own
    -- ambient cruise is punishingly slow; this makes surrounding traffic actually
    -- move. Applies to EVERY tuned ambient driver (not our spawned cars).
    kmh = kmh * (T.nativeSpeedMult or 1.0)
    -- AMBIENT SPEED FLOOR (v2.4.40 — user: "make even the default GTA spawns drive
    -- 75-95 km/h, they drive too slow"). GTA's ambient cruise (even after the
    -- multipliers above) still crawls in the city. Floor every tuned ambient driver
    -- at a random speed in [ambientCruiseMinKmh, ambientCruiseMaxKmh] so surrounding
    -- traffic always moves at a lively pace, with per-car variety so they're not all
    -- locked to one speed. Only a FLOOR — a car already commanded faster (highway +
    -- open-road biome) keeps its higher speed.
    local aMin = T.ambientCruiseMinKmh or 75.0
    local aMax = T.ambientCruiseMaxKmh or 95.0
    if aMax > aMin then
        local floorKmh = aMin + math.random() * (aMax - aMin)
        if kmh < floorKmh then kmh = floorKmh end
    end
    local ms = kmhToMs(kmh)
    -- WHY THE OLD BUMP DID NOTHING: GTA's *stock ambient wander task* IGNORES
    -- SetDriveTaskCruiseSpeed — ambient peds cruise on the game's internal
    -- population speed model, not the value you command. So nativeSpeedMult was
    -- multiplying a number the game threw away (Normal already commanded
    -- 120*mult and they still crawled). The fix is to REPLACE their stock task
    -- with a SCRIPT-issued wander task via TaskVehicleDriveWander — a scripted
    -- drive task DOES honour the commanded speed. We re-issue it once per
    -- retune window (8s); wander re-paths from the car's current spot so this
    -- doesn't teleport or fight the road network, it just hands them a faster
    -- brain. After the task is script-owned, the SetDriveTask* calls below stick.
    local style = preset.style or 262315
    TaskVehicleDriveWander(driver, veh, ms, style)
    SetDriveTaskCruiseSpeed(driver, ms)
    SetDriveTaskMaxCruiseSpeed(driver, ms)
end

-- ── Layer 4: ambient behaviour loop ─────────────────────────────────────────
CreateThread(function()
    while true do
        local interval = T.scanInterval or 750
        if not (S and S.enabled) then
            tunedPeds = {}
            Wait(1500)
        else
            local preset = (T.presets or {})[S.preset] or (T.presets or {}).Normal or {}
            local hwKmh = T.highwaySpeedKmh or 75
            local pool = GetGamePool('CVehicle')
            local t = nowMs()
            local retune = T.retuneAfter or 8000
            for i = 1, #pool do
                local veh = pool[i]
                if DoesEntityExist(veh) and not protectedVeh(veh) then
                    local driver = GetPedInVehicleSeat(veh, -1)
                    if driver ~= 0 and DoesEntityExist(driver)
                        and not IsPedAPlayer(driver) and GetPedType(driver) ~= 28 then
                        local last = tunedPeds[driver]
                        if not last or (t - last) > retune then
                            -- highway if already moving fast OR the region is an
                            -- open-road biome (tuneDriver also checks openRoad;
                            -- kept here so speed-based highways still register).
                            local onHwy = (GetEntitySpeed(veh) * 3.6) >= hwKmh
                            tuneDriver(veh, driver, preset, onHwy)
                            tunedPeds[driver] = t
                        end
                    end
                end
            end
            -- prune dead ped keys occasionally
            for ped, _ in pairs(tunedPeds) do
                if not DoesEntityExist(ped) then tunedPeds[ped] = nil end
            end
            Wait(interval)
        end
    end
end)

-- ── Layer 5: highway fast-spawner (chunk-gated + networked) ─────────────────
local function loadModel(name)
    local hash = type(name) == 'number' and name or joaat(name)
    if not IsModelValid(hash) or not IsModelAVehicle(hash) then return nil end
    RequestModel(hash)
    local t = 0
    while not HasModelLoaded(hash) do
        Wait(15); t = t + 15
        if t > 4000 then return nil end
    end
    return hash
end

-- ── Fleet caps (single source of truth) ────────────────────────────────────
-- The TOTAL cap scales with the live intensity slider: round(maxSpawned*intensity).
-- The old bug: addonMaxAlive(8)+baseMaxAlive(2) summed to LESS than the total
-- (e.g. intensity 1.4 → total 14), so the fleet stalled at 10 and spawnedCount
-- never reached `cap` → the "spawned 10/14" mismatch + the backoff never firing.
-- FIX: base is a hard low cap; ADDONS FILL THE REMAINDER of the total. So a total
-- of 14 with baseMaxAlive 2 means up to 12 addons — exactly the "12 addon + 2 base"
-- you'd expect. addonMaxAlive is now an OPTIONAL ceiling (only clamps if you set
-- it BELOW the remainder, e.g. to limit distinct-model streaming stutter).
-- FLEET FILL (v2.4.57) — the live slider formerly called "addonChance"/"rate".
-- Base spawning is gone (baseMaxAlive 0) so the old "chance a car is an addon vs
-- base" roll was DEAD — pickModel always picks an addon and never consulted it.
-- Repurposed: it now scales HOW FULL the addon fleet gets. fill 1.0 = the full
-- intensity-scaled cap; fill 0.5 = half that many cars; fill 0 = none. Reads the
-- live server slider (S.addonChance, persisted in hk_scenario_meta), clamped 0..1,
-- default 1.0. Renamed everywhere in the UI to "fill".
local function fleetFill()
    local f = (S and S.addonChance) or T.addonChance or 1.0
    if f < 0.0 then return 0.0 elseif f > 1.0 then return 1.0 end
    return f
end
local function fleetTotalCap()
    local sp = T.spawner or {}
    local base = (sp.maxSpawned or 12) * ((S and S.intensity) or 1.0)
    return math.floor(base * fleetFill() + 0.5)
end
local function baseCap()   return (T.baseMaxAlive or 4) end
local function addonCap()
    local remainder = fleetTotalCap() - baseCap()
    local ceil = T.addonMaxAlive        -- optional; nil = no separate ceiling
    if ceil and ceil < remainder then return ceil end
    return math.max(0, remainder)
end

-- returns (hash, isAddon, tierName, modelName)
-- ADDON-ONLY (v2.4.24, user: "ditch the base vehicle scripting"): we no longer
-- spawn native GTA base cars — the fleet is purely curated addon exotics. Base
-- cars were slow, couldn't tier, and added little. Ambient NATIVE traffic (Layer
-- 4, the game's own cars we just re-tune) is untouched — this only stops OUR
-- spawner from creating base-model cars. If addons are capped or none load, we
-- simply skip the spawn.
local function pickModel(sp)
    if addonAliveCount >= addonCap() then return nil, false, nil, nil end
    local name, tier = pickAddonByTier()
    if not name then return nil, false, nil, nil end
    local hash = loadModel(name)
    if not hash then return nil, false, nil, nil end
    return hash, true, tier, name
end

-- spawn one networked highway car ahead of the player on a road node
local function trySpawnHighwayCar(sp, playerVeh)
    dbgAttempts = dbgAttempts + 1
    local cap = fleetTotalCap()
    if spawnedCount >= cap then bail('cap'); return end

    local ped = PlayerPedId()
    local pc = GetEntityCoords(playerVeh)

    -- CITY-ADAPTIVE BAND (v2.4.75 — user: "too hard to spawn in city / crowded
    -- areas"). The default highway band (ahead 275-430m, bubble 170m, pop 260m)
    -- fails in a dense grid: far nodes drift past the road bend, land occluded-
    -- but-on-screen, or on un-streamed collision → almost every city attempt bails.
    -- When the player is going SLOW (city speed) swap to a short, close, wider-
    -- scatter band with a smaller no-spawn bubble + shorter pop-guard — buildings
    -- hide the closer spawns, and short hops land on real nearby grid nodes.
    -- These locals SHADOW the sp.* reads for the rest of the function so the
    -- existing gate logic below picks up the city values transparently.
    local behindMin, behindMax   = sp.spawnBehindMin or 190.0, sp.spawnBehindMax or 260.0
    local aheadMin, aheadMax     = sp.spawnAheadMin or 275.0,  sp.spawnAheadMax or 430.0
    local scatterAhead           = sp.spawnScatterAhead or 30.0
    local scatterWide            = sp.spawnScatter or 90.0
    local noSpawnR               = sp.noSpawnRadius or sp.minSpawnDist or 160.0
    local popDistCfg             = sp.visiblePopDist or 260.0
    local nodeSnapMax            = sp.maxNodeSnap or 60.0
    local behindChanceCfg        = sp.behindChance or 0.65
    if sp.cityAdaptive ~= false then
        local kmh = GetEntitySpeed(playerVeh) * 3.6
        local bandKmh = sp.cityBandKmh or 60.0
        -- fully CITY at/below bandKmh, fully HIGHWAY at 1.5× bandKmh, linear between.
        local hiKmh = bandKmh * 1.5
        local hwFrac = (kmh - bandKmh) / math.max(1.0, (hiKmh - bandKmh))
        if hwFrac < 0.0 then hwFrac = 0.0 elseif hwFrac > 1.0 then hwFrac = 1.0 end
        if hwFrac < 1.0 then
            local cf = 1.0 - hwFrac   -- city weight
            local function mix(city, hw) return city * cf + hw * hwFrac end
            behindMin    = mix(sp.cityBehindMin or 70.0,  behindMin)
            behindMax    = mix(sp.cityBehindMax or 130.0, behindMax)
            aheadMin     = mix(sp.cityAheadMin or 90.0,   aheadMin)
            aheadMax     = mix(sp.cityAheadMax or 170.0,  aheadMax)
            scatterAhead = mix(sp.cityScatterAhead or 55.0, scatterAhead)
            noSpawnR     = mix(sp.cityNoSpawnRadius or 75.0, noSpawnR)
            popDistCfg   = mix(sp.cityVisiblePopDist or 90.0, popDistCfg)
            nodeSnapMax  = mix(sp.cityMaxNodeSnap or 90.0, nodeSnapMax)
            behindChanceCfg = mix(sp.cityBehindChance or 0.45, behindChanceCfg)
        end
    end

    -- Spawn OFF-SCREEN: either well behind (car catches up + overtakes — the
    -- NoHesi "blows past you" feel) or far ahead beyond render distance. Both
    -- avoid the visible pop-in the first version had (90-180m was in view).
    local fwd = GetEntityForwardVector(playerVeh)
    local behind = math.random() < behindChanceCfg
    local dist, dir
    if behind then
        dist = math.random(math.floor(behindMin), math.floor(behindMax))
        dir = -1.0
    else
        dist = math.random(math.floor(aheadMin), math.floor(aheadMax))
        dir = 1.0
    end
    -- LATERAL + FORWARD SCATTER (fixes "spawns always line up / bunch together"):
    -- without this, every ahead-spawn lands on the nearest node on the player's
    -- exact forward axis = the same road, same spot, so cars stack into one train.
    -- We push the target sideways (perpendicular to forward) by a random offset
    -- AND jitter the forward distance, so GetClosestVehicleNodeWithHeading resolves
    -- to different roads/lanes/cross-streets. Occasional bunching still happens
    -- (they group up sometimes, which you like) but it's no longer the norm.
    local right = vector3(fwd.y, -fwd.x, 0.0)   -- perpendicular in the ground plane
    -- DIRECTION-AWARE SCATTER: AHEAD spawns keep a TIGHT lateral offset so they
    -- land ON the road you're driving toward (a lane or two wide) instead of being
    -- flung 90m sideways onto a parallel/opposite highway — that wide fling is why
    -- addon cars showed up all around you (behind, opposite lane, nearby highway)
    -- but never up your own forward path. BEHIND spawns keep the wide scatter for
    -- the "surround" ambiance (variety back there is good, and you can't see it).
    local scatterMax = behind and scatterWide or scatterAhead
    local side  = (math.random() * 2.0 - 1.0) * scatterMax
    dist = dist + math.random(-40, 40)
    local target = pc + (fwd * (dist * dir)) + (right * side)
    -- snap to a real road node so the car spawns ON the highway, facing traffic.
    local ok, nodePos, nodeHeading = GetClosestVehicleNodeWithHeading(
        target.x, target.y, target.z, 1, 3.0, 0)
    if not ok then bail('no-node'); return end
    -- OFF-ROAD / WATER GUARD (fixes "cars spawn on the beach / riverside"):
    -- GetClosestVehicleNodeWithHeading will happily return the nearest node even
    -- when it's far from `target` (a dirt track by the river, a beach access
    -- road), and boat/water nodes can slip through too. Three cheap rejects:
    --  (1) the snapped node drifted too far from where we aimed → it grabbed some
    --      distant lonely track instead of a road near us.
    --  (2) there's WATER at/above the node's ground → beach/river/pier edge.
    --  (3) GetVehicleNodeProperties flags it as a non-road / switched-off node.
    local snapDrift = #(nodePos - target)
    if snapDrift > nodeSnapMax then bail('node-drift'); return end
    local wOk, wZ = GetWaterHeight(nodePos.x, nodePos.y, nodePos.z)
    if wOk and wZ and wZ >= (nodePos.z - (sp.waterMargin or 1.5)) then
        bail('water'); return
    end
    local pOk, density, nflags = GetVehicleNodeProperties(nodePos.x, nodePos.y, nodePos.z)
    if pOk then
        -- density 0 = essentially dead/unused node; very low density nodes are the
        -- lonely off-network tracks that put cars in weird places. Require a
        -- minimum so we stick to real, used roads.
        if (density or 0) < (sp.minNodeDensity or 1) then bail('dead-node'); return end
    end
    -- SCENARIO NO-TRAFFIC ZONE (v2.4.37): never spawn inside a user-painted zone
    -- that clears vehicles / blocks roads. The user zones these to KEEP traffic
    -- out; our spawner has to respect them like the ambient clear engine does.
    if inBlockedScnZone(nodePos.x, nodePos.y, nodePos.z) then bail('scn-zone'); return end
    -- ANTI-"spawn in front of my face like a witch": two guards.
    -- (1) HARD no-spawn radius — never create a car within this distance of the
    --     player, on-screen OR off (covers the case where you turn/rotate right
    --     after a just-off-frustum spawn and it pops into view).
    -- (2) frustum test — but ONLY reject on-screen spawns that are close enough to
    --     read as pop-in. When you're STATIONARY looking down a straight road,
    --     everything in the 195-330m band is technically "on screen", so the old
    --     unconditional reject killed every single spawn (the "says spawning,
    --     nothing appears, lastbail on-screen" bug). A car appearing 300m down the
    --     road just looks like distant traffic, not a witch. So: on-screen is only
    --     rejected within `visiblePopDist` (default 260m); beyond that it's fine.
    local distToNode = #(nodePos - pc)
    if distToNode < noSpawnR then bail('too-close'); return end
    local popDist = popDistCfg
    if distToNode < popDist and IsSphereVisible(nodePos.x, nodePos.y, nodePos.z, 6.0) then
        bail('on-screen'); return
    end

    -- COLLISION GATE (fixes "car frozen in the middle of the lane"): if the map
    -- collision isn't streamed at the node, the car spawns with no road under it
    -- and just sits there until you drive up. Behind-spawns are almost always
    -- fine (the player was just there). For ahead-spawns, request + wait; if it
    -- won't load in time, abort and try again next cycle rather than spawn a
    -- frozen car. Mirrors the hk-parking fall-through collision fix.
    -- v2.4.56 — the old loop only waited while the node was within 180m of the
    -- player, but cars spawn 195-500m AHEAD, so that test was ALREADY false on the
    -- first check for almost every spawn → the loop never actually waited →
    -- SetVehicleOnGroundProperly ran against un-streamed collision → the 'no-ground'
    -- streak. There is NO reliable "collision loaded at arbitrary coord" native
    -- (HasCollisionLoadedAroundEntity is player-centric and useless 300m out;
    -- HasCollisionLoadedAtCoord does NOT exist — calling it crashed the spawner
    -- thread in v2.4.55, freezing attempts at 1). So just PRIME the stream with
    -- REQUEST_ADDITIONAL_COLLISION_AT_COORD + RequestCollisionAtCoord and a small
    -- fixed wait; the real verification is the post-create ground RETRY loop below
    -- (which re-tests SetVehicleOnGroundProperly + lift-and-settle and only bails
    -- 'no-ground' if it STILL can't find ground).
    RequestAdditionalCollisionAtCoord(nodePos.x, nodePos.y, nodePos.z)
    RequestCollisionAtCoord(nodePos.x, nodePos.y, nodePos.z)
    Wait(150)

    -- ── Model + reckless decision ────────────────────────────────────────────
    -- Pick the model FIRST via the normal addon-lottery vs base-GTA path, THEN
    -- roll reckless INDEPENDENTLY on whatever we got. Per user: reckless/aggressive
    -- driving now applies to BOTH native and addon cars (it used to force an addon
    -- — a base GTA sedan can be a maniac too). Reckless is purely a driving
    -- personality now, decoupled from which model spawned.
    local acfg = T.addon or {}
    local hash, isAddon, tier, modelName = pickModel(sp)
    if not hash then bail('no-model'); return end
    -- ANTI-RECKLESS override (config list): these models are pinned to calm,
    -- law-abiding driving like a native normal NPC — never roll reckless, and
    -- later we also force them off the aggressive addon profile onto 'normal'.
    local forceSafe = isAntiReckless(modelName)
    local wantReckless = (not forceSafe)
        and (math.random() < ((S and S.recklessChance) or acfg.recklessChance or 0.15))

    -- driver ped FIRST (random from the diverse pool) so the car never spawns
    -- driverless. Fall back silently if a ped model won't load.
    local pedList = T.driverPeds or { 'a_m_y_hipster_01' }
    local pedName = pedList[math.random(#pedList)]
    local pedHash = joaat(pedName)
    RequestModel(pedHash)
    local tt = 0
    while not HasModelLoaded(pedHash) do Wait(15); tt = tt + 15; if tt > 3000 then break end end
    if not HasModelLoaded(pedHash) then
        pedHash = joaat('a_m_y_hipster_01')
        RequestModel(pedHash)
        tt = 0
        while not HasModelLoaded(pedHash) do Wait(15); tt = tt + 15; if tt > 2000 then break end end
    end

    -- NETWORKED so other players + police see these cars (the whole point of
    -- the addon "confuse police" hook under onesync_population).
    local veh = CreateVehicle(hash, nodePos.x, nodePos.y, nodePos.z, nodeHeading, true, false)
    if veh == 0 or not DoesEntityExist(veh) then
        bail('create-fail'); deckBurn(modelName)
        SetModelAsNoLongerNeeded(hash); SetModelAsNoLongerNeeded(pedHash); return
    end
    -- v2.4.53 — EMERGENCY-CLASS BAIL REMOVED (per user): it deleted the car + bailed
    -- WITHOUT counting the model, so an emergency-class roster car stayed at deckUse=0
    -- forever = permanently "available" → once every other car capped, the deck could
    -- never exhaust/reset and pickAddonByTier handed back the same un-spawnable model
    -- every attempt → `ok` froze (the 270 wedge, lastbail stuck on 'emergency'). The
    -- config BLACKLIST + the sports-only qb roster + the EMERGENCY_NAME_PAT name filter
    -- already keep cop/emergency models out of the roster, so this runtime class guard
    -- is redundant. If a stray emergency model ever slips through, deckBurn (below, on
    -- the real gates) still stops it wedging the deck.
    SetEntityAsMissionEntity(veh, true, true)
    -- record collisions so HasEntityCollidedWithAnything is reliable (v2.4.47) —
    -- the reverse gate uses it to tell "genuinely wedged/rearended" from "just lost
    -- the path on a clear road" (only the former justifies backing up).
    SetEntityRecordsCollisions(veh, true)
    -- GROUND/COLLISION VERIFY (fixes "car frozen in the median"): the earlier
    -- collision gate only tested collision AROUND THE PLAYER, which is useless
    -- for a node 350-500m ahead (collision never streams that far out), so those
    -- cars spawned onto nothing and sat still. SetVehicleOnGroundProperly returns
    -- FALSE when there's no ground/collision under the car — if so, this spawn is
    -- bad: delete it and bail rather than leave a frozen car in the road.
    -- v2.4.55 — RETRY + LIFT-AND-SETTLE instead of deleting on the first false.
    -- SetVehicleOnGroundProperly returns false when collision hasn't finished
    -- streaming under the node yet — but that often resolves in a few frames. So:
    -- keep requesting collision AT THE NODE, nudge the car up ~0.5m so it can drop
    -- onto the mesh as it loads, and re-test up to a short budget. Only bail if it
    -- STILL can't find ground after that (genuinely no road there).
    local grounded = SetVehicleOnGroundProperly(veh)
    if not grounded then
        local gwait = 0
        while not grounded and gwait < 500 do
            RequestCollisionAtCoord(nodePos.x, nodePos.y, nodePos.z)
            local gc = GetEntityCoords(veh)
            SetEntityCoordsNoOffset(veh, gc.x, gc.y, gc.z + 0.5, false, false, false)
            Wait(50); gwait = gwait + 50
            grounded = SetVehicleOnGroundProperly(veh)
        end
    end
    if not grounded then
        bail('no-ground'); deckBurn(modelName)
        SetEntityAsMissionEntity(veh, true, true); DeleteVehicle(veh)
        SetModelAsNoLongerNeeded(hash); SetModelAsNoLongerNeeded(pedHash); return
    end
    SetVehicleEngineOn(veh, true, true, false)
    SetVehicleDirtLevel(veh, math.random(0, 12) * 0.1)
    -- WINDOW TINT (v2.4.76): every addon car spawns tinted (pure black / dark /
    -- light smoke, random from config). isAddon is always true here (addon-only
    -- fleet since v2.4.24) but guard anyway so a future base car stays stock.
    if isAddon and (T.addon or {}).forceWindowTint ~= false then
        local tints = (T.addon or {}).windowTints or { 1, 2, 3 }
        if #tints > 0 then SetVehicleWindowTint(veh, tints[math.random(#tints)]) end
    end
    -- give it some starting speed so it's already rolling when you see it
    SetVehicleForwardSpeed(veh, kmhToMs((sp.cruiseKmh or 150) * 0.6))
    -- Plate MUST match the real qb-core generated format exactly, else the 6-char
    -- plates gave our NPCs away as fake. qb format = RandomInt(1)+RandomStr(2)+
    -- RandomInt(3)+RandomStr(2) = 8 chars, e.g. 4XV718AB (v2.4.37).
    SetVehicleNumberPlateText(veh, ('%d%s%03d%s'):format(
        math.random(0, 9),
        string.char(math.random(65, 90), math.random(65, 90)),
        math.random(0, 999),
        string.char(math.random(65, 90), math.random(65, 90))))

    local driver = CreatePedInsideVehicle(veh, 26, pedHash, -1, true, false)
    if not driver or driver == 0 then
        -- couldn't seat a driver -> don't leave a driverless car sitting there.
        bail('no-driver'); deckBurn(modelName)
        SetEntityAsMissionEntity(veh, true, true); DeleteVehicle(veh)
        SetModelAsNoLongerNeeded(pedHash); SetModelAsNoLongerNeeded(hash); return
    end
    SetPedRandomComponentVariation(driver, 0)
    SetPedRandomProps(driver)

    -- ── Per-car speed profile ────────────────────────────────────────────────
    -- base spawner speed/aggression/style, then per-personality addon overrides.
    local ac = T.addon or {}
    local cruiseKmh  = sp.cruiseKmh or 150
    local aggression = sp.aggression or 0.4
    local style      = sp.style or 262189
    local reckless   = false
    local persona    = 'base'
    -- NATIVE-SPEED BUMP for OUR spawned base (native GTA model) cars: same knob as
    -- the ambient Layer-4 bump. A plain base sedan cruising at ~150 gets lifted so
    -- surrounding traffic we spawn actually moves (engine still clamps to the car's
    -- real top speed). Addon/reckless/cautious cars have their own profiles below
    -- and are NOT touched by this — only the untouched base persona.
    if not isAddon then
        cruiseKmh = cruiseKmh * (T.nativeSpeedMult or 1.0)
    end
    if wantReckless then
        -- RECKLESS: full-send racer — native OR addon (per user, both allowed).
        -- reckless style omits StopAtTrafficLights so these run reds + overtake.
        persona = 'reckless'
        reckless = true
        local speeds = ac.recklessSpeeds or { 140, 180, 240, 280 }
        cruiseKmh  = speeds[math.random(#speeds)]
        aggression = ac.recklessAggression or 0.60
        style      = ac.recklessStyle or 262181
    elseif isAddon then
        if forceSafe then
            -- ANTI-RECKLESS pin: drive like a calm native NPC — modest speed, low
            -- aggression, full lane-keep + stop-for-everything style (262315). No
            -- overtaking, no aggressive addon profile, no cautious-slow either.
            persona = 'safe'
            cruiseKmh  = cruiseKmh * (ac.safeSpeedMult or 1.0)
            aggression = ac.safeAggression or 0.05
            style      = ac.safeStyle or 262315
        else
            -- non-reckless addon: roll cautious vs normal.
            local roll = math.random()
            if roll < (ac.cautiousChance or 0.15) then
                -- CAUTIOUS: weirdly slow, rigidly law-abiding (stops at every light).
                persona = 'cautious'
                cruiseKmh  = cruiseKmh * (ac.cautiousSpeedMult or 0.70)
                aggression = ac.cautiousAggression or 0.05
                style      = ac.cautiousStyle or 262331
            else
                -- ordinary addon car: +10% over base + overtake, but stops at reds.
                persona = 'normal'
                cruiseKmh = cruiseKmh * (ac.speedMult or 1.10)
                style     = ac.normalStyle or 262317
            end
        end
    end

    -- BIOME (Layer 4.5): scale the spawned car's cruise by the region speedMult
    -- too, so a hypercar screaming across the open desert really moves, while
    -- city spawns stay at base. Cautious cars keep their own slower character
    -- but still shift with the region (mult is applied uniformly).
    cruiseKmh = cruiseKmh * ((curBiome and curBiome.speedMult) or 1.0)

    -- PER-TIER SPEED CAP: A-class tops out ~240 km/h, S-class ~370 km/h (they
    -- can genuinely reach it most of the time), B-class stays sensible. The
    -- engine still clamps to each car's real top speed, so a slow B addon won't
    -- magically hit its cap — this just RAISES the ceiling so the fast tiers
    -- actually stretch their legs instead of being pinned to the base cruise.
    -- Reckless cars already pick a high target; we lift their cap to the tier's.
    local caps = T.tierSpeedCaps or {}
    local tierCap = tier and caps[tier] or nil
    if tierCap then
        if reckless then
            -- reckless = full send: target the tier ceiling directly, so an A
            -- reckless car aims for ~240 and an S reckless car aims for ~370
            -- (never the other way — a reckless A won't overshoot to 280).
            cruiseKmh = tierCap
        else
            cruiseKmh = math.min(cruiseKmh, tierCap)   -- normal: don't exceed cap
        end
    elseif not isAddon then
        -- BASE (native GTA) cars have NO tier, so the tier cap above never bounds
        -- them. Without this, nativeSpeedMult (2.4) × spawner cruise (170) × biome
        -- mult stacked into ~500+ km/h (the "base sultan showing 518" bug). Cap
        -- base cars to a believable ambient speed — they aren't meant to out-run
        -- the addon exotics. Reckless base cars keep their picked target (already
        -- bounded by recklessSpeeds), so only cap the non-reckless ones.
        if not reckless then
            cruiseKmh = math.min(cruiseKmh, (T.baseCruiseCap or 150))
        end
    end

    -- PER-CAR SPEED VARIANCE (fixes "spawns all line up"): give each car a small
    -- random ±% on its cruise so a pack naturally spreads out over time instead of
    -- travelling as one locked-together train (they all had identical targets, so
    -- they never separated). ±12% by default. Reckless cars keep their picked
    -- target (they're meant to be flat-out).
    if not reckless then
        local v = (sp.speedVariance or 0.12)
        cruiseKmh = cruiseKmh * (1.0 + (math.random() * 2.0 - 1.0) * v)
    end

    -- FLOOR: never task a car below the minimum cruise (per user "consistent
    -- 65-75") — except deliberately-slow CAUTIOUS cars, which are meant to
    -- trundle. Keeps base city traffic from crawling.
    if persona ~= 'cautious' then
        cruiseKmh = math.max(cruiseKmh, (T.minCruiseKmh or 70))
    end

    -- ABSOLUTE CEILING (final backstop): after every mult/variance/floor, clamp so
    -- no combination can ever task an insane speed again (the 518 km/h bug). Sits
    -- above the top tier so it never clips a legit S-class hypercar.
    cruiseKmh = math.min(cruiseKmh, (T.maxCruiseKmh or 400))

    -- NOTE: do NOT FreezeEntityPosition / SetEntityInvincible the driver — that
    -- freezes the ped so the drive task never starts (the "idle NPC" bug). We
    -- WANT them reacting: fleeing, braking, honking — like native ambient drivers.
    SetDriverAbility(driver, sp.ability or 1.0)
    SetDriverAggressiveness(driver, aggression)
    -- Anti-"NPC swerves into you on purpose": make the driver actively steer
    -- around vehicles/peds/objects instead of the vanilla ram-the-player-at-
    -- speed behaviour. Aggression handles the occasional real close pass.
    SetPedSteersAroundVehicles(driver, true)
    SetPedSteersAroundPeds(driver, true)
    SetPedSteersAroundObjects(driver, true)
    -- React like a normal ambient civ (flee/panic when rammed or shot at).
    SetPedFleeAttributes(driver, 0, false)
    SetPedCombatAttributes(driver, 46, true)   -- can flee / always flee
    SetEntityMaxSpeed(veh, 999.0)
    -- ORIGINAL handling values (captured before we override them) so that if a
    -- player HIJACKS this car we can revert it to stock — otherwise a jacked car
    -- stays gimped (accel cut, brakes boosted) forever. nil = not overridden.
    local origBrakeForce, origDriveForce, origTractionMax, origTractionMin, origDriveBias
    -- TOP-SPEED FLOOR for ADDON cars (per user "every addon must AT LEAST be able
    -- to reach 220 km/h"): a weak/economy addon car's real engine top speed can be
    -- well under 220, so it'd never touch the tier cap no matter how high we set
    -- the cruise. GetVehicleEstimatedMaxSpeed returns the car's STATIC max in m/s
    -- (mods included). If it's below the floor, bump it with ModifyVehicleTopSpeed
    -- by exactly the percent needed to lift it to the floor. This raises the
    -- CAPABILITY (physical top speed) only — the drive task's cruise/tier cap still
    -- decides how fast it actually goes. Base GTA cars are left stock.
    if isAddon then
        local floorKmh = (T.addonMinTopSpeedKmh or 220)
        local est = GetVehicleEstimatedMaxSpeed(veh)          -- m/s (0 if unknown)
        local estKmh = (est or 0.0) * 3.6
        if estKmh > 5.0 and estKmh < floorKmh then
            -- percent lift needed (native takes a % from 0..100+, it can exceed 100)
            local pct = (floorKmh / estKmh - 1.0) * 100.0
            if pct > 0.0 then ModifyVehicleTopSpeed(veh, pct) end
        end
        -- STRONGER BRAKES for addon cars (per user "make them brake earlier /
        -- brake properly"): a fast addon car with a stock brake force can't shed
        -- speed in time and rear-ends traffic or overshoots corners. We multiply
        -- THIS vehicle's fBrakeForce (per-vehicle override — does NOT touch the
        -- model globally, so players driving the same car elsewhere are unaffected)
        -- so it can physically stop harder. Combined with high SetDriverAbility
        -- below (the AI's braking ANTICIPATION) this makes them brake sooner AND
        -- stronger. CHandlingData/fBrakeForce natives verified per-vehicle (CFX).
        local bMul = (T.addon and T.addon.brakeForceMult) or 1.6
        if bMul and bMul ~= 1.0 then
            local bf = GetVehicleHandlingFloat(veh, 'CHandlingData', 'fBrakeForce')
            if bf and bf > 0.0 then
                origBrakeForce = bf   -- save ORIGINAL so we can revert on hijack
                SetVehicleHandlingFloat(veh, 'CHandlingData', 'fBrakeForce', bf * bMul)
            end
        end
        -- TC/GRIP FLOOR (v2.4.31 — user: "need even more ABS/TC help to stop cars
        -- being retarded/crashed"). Bump this car's traction curve so its tyres
        -- hold at speed and the AI (which gets NO stability aids) stops lighting up
        -- the rears / understeering into walls. Per-vehicle override, reverted on
        -- hijack like fBrakeForce. fTractionCurveMax = peak lateral grip,
        -- fTractionCurveMin = grip past the peak (slide resistance).
        local gBoost = (T.addon and T.addon.tcGripBoost) or 1.0
        if (T.addon and T.addon.absAssist ~= false) and gBoost and gBoost ~= 1.0 then
            local tmax = GetVehicleHandlingFloat(veh, 'CHandlingData', 'fTractionCurveMax')
            local tmin = GetVehicleHandlingFloat(veh, 'CHandlingData', 'fTractionCurveMin')
            if tmax and tmax > 0.0 then
                origTractionMax = tmax
                SetVehicleHandlingFloat(veh, 'CHandlingData', 'fTractionCurveMax', tmax * gBoost)
            end
            if tmin and tmin > 0.0 then
                origTractionMin = tmin
                SetVehicleHandlingFloat(veh, 'CHandlingData', 'fTractionCurveMin', tmin * gBoost)
            end
        end
        -- FORCE-AWD for addon cars (v2.4.70 — user: "make every NPC drive any addon
        -- car like an AWD so they control even better"). The stock AI gets NO
        -- stability aids, so a powerful RWD exotic lights up the rears and
        -- over-rotates (the chronic oversteer the counter-steer damper fights). The
        -- cleanest fix is to give the CAR a drivetrain the AI can actually manage:
        -- push fDriveBiasFront toward an even 0.5 split so torque goes to all four
        -- wheels, killing power-oversteer at the source. Per-vehicle override
        -- (reverted on hijack, exactly like fBrakeForce) so a player driving the
        -- same model elsewhere keeps the real RWD/FWD car. fDriveBiasFront is the
        -- CFX drivetrain axis: 0.0 = pure RWD, 1.0 = pure FWD, ~0.5 = balanced AWD
        -- (see the drivetrain thresholds note: AWD 0.5-0.6). We ONLY convert cars
        -- that are meaningfully rear/front biased — a car already near 0.5 is left
        -- alone so we don't disturb a hand-tuned AWD.
        if (T.addon and T.addon.forceAwd ~= false) then
            local awdBias = (T.addon and T.addon.awdDriveBias) or 0.5
            local db = GetVehicleHandlingFloat(veh, 'CHandlingData', 'fDriveBiasFront')
            -- stock GTA encodes bias in a folded range; only touch a real, sane
            -- value and only when it's off the AWD band by more than a hair.
            if db and db > 0.0 and db < 1.0 and math.abs(db - awdBias) > 0.05 then
                origDriveBias = db
                SetVehicleHandlingFloat(veh, 'CHandlingData', 'fDriveBiasFront', awdBias)
            end
        end
        -- NOTE (v2.4.24): the old fInitialDriveForce cut (accelMult) was REMOVED.
        -- It weakened the engine to tame launches, but that ALSO capped top speed —
        -- a weak engine can't overcome drag at high speed, so cars plateaued far
        -- below their real top (the "74/237, caps at 219" bug). Per user: we only
        -- want to control ACCELERATION, not the TOP SPEED reachable. The accel
        -- GOVERNOR (addonDriveTick) already limits the acceleration RATE directly
        -- by capping how fast the commanded cruise may climb — that tames launches
        -- WITHOUT touching engine force, so the car still pulls all the way to its
        -- real top speed given road. So drive force is now left 100% stock.
    end
    -- Drive along the road network at cruise speed; wander keeps them flowing
    -- on highways. Style = fast-flow (avoid collisions, no wrong-way / no ram).
    TaskVehicleDriveWander(driver, veh, kmhToMs(cruiseKmh), style)
    SetDriveTaskDrivingStyle(driver, style)
    SetDriveTaskCruiseSpeed(driver, kmhToMs(cruiseKmh))
    -- CRITICAL (the "capped at 125 even though debug shows higher" bug):
    -- TaskVehicleDriveWander's internal MAX cruise defaults to ~34 m/s (~122
    -- km/h). SetDriveTaskCruiseSpeed only sets the TARGET; the task still clamps
    -- it to that hidden max, so ANY cruise above ~125 was silently thrown away
    -- (that's why the debug target read high but the car pinned at 125, and why
    -- horn-boost did nothing). We MUST also raise the max cruise to the target
    -- (with headroom) so the commanded speed is actually honoured. kept slightly
    -- above so brake/governor tweaks near the target aren't re-clamped.
    SetDriveTaskMaxCruiseSpeed(driver, kmhToMs(cruiseKmh) + 5.0)
    SetModelAsNoLongerNeeded(pedHash)
    SetModelAsNoLongerNeeded(hash)

    -- ORPHAN CLEANUP (v2.4.73 — user: "if a player crashes/drops, their client
    -- script never runs its cleanup, so the car it spawned just stops dead in the
    -- middle of the road → chaos piles up"). These cars are client-created networked
    -- entities; on an UNEXPECTED exit (crash/timeout/Alt-F4) no onResourceStop fires,
    -- so the car falls to the default orphan mode (DeleteWhenNotRelevant) which does
    -- NOT delete a car other players are near — it lingers driverless. FIX: tell the
    -- SERVER to delete it the moment its ORIGINAL OWNER disconnects. SetEntityOrphanMode
    -- mode 1 = DeleteOnOwnerDisconnect; it keys on the FIRST owner so it survives
    -- OneSync ownership migration (forceMigration). Applied to BOTH the car and its
    -- ped so neither is left behind. Native-guarded (a nil native call would silently
    -- kill this whole spawner thread — the v2.4.55 lesson) so an older server artifact
    -- degrades gracefully to the statebag sweep (Layer 2) instead of bricking spawns.
    if SetEntityOrphanMode then
        SetEntityOrphanMode(veh, 1)          -- 1 = DeleteOnOwnerDisconnect
        if driver and DoesEntityExist(driver) then SetEntityOrphanMode(driver, 1) end
    end
    -- REPLICATED OWNER MARKER (v2.4.73): tag every driving car with hkscn_veh so the
    -- SERVER can identify + sweep our orphans (on playerDropped AND on resource
    -- start/restart) even for cars it never owned — mirrors the hkscn_parked marker
    -- the parked-swap fleet already carries. Belt-and-suspenders backup to orphan
    -- mode: if a car ever slips the native (created before it applied, or a race on
    -- migration), the server-side sweep still catches it by this bag.
    Entity(veh).state:set('hkscn_veh', true, true)

    -- track the driver too, so culling deletes BOTH (deleting the vehicle alone
    -- leaves the ped standing on the road — the "lone ped, no car" bug).
    -- cruiseMs/style stored so the re-assert loop can keep fast cars fast (the
    -- engine periodically resets drive tasks back to a default cruise).
    spawned[veh] = {
        addon = isAddon, born = nowMs(), driver = driver,
        netId = NetworkGetNetworkIdFromEntity(veh),   -- for server-authoritative delete
        reckless = reckless, cruiseMs = kmhToMs(cruiseKmh), style = style,
        -- base driver tuning saved so the overtake steering-tame can RESTORE it
        -- when the overtake window ends (else the car keeps max-ability forever).
        baseAbility = sp.ability or 1.0, baseAggr = aggression,
        -- debug/telemetry (surfaced by the /hktraffic debug overlay):
        model = modelName or 'base', tier = tier, persona = persona,
        cruiseKmh = math.floor(cruiseKmh + 0.5),
        -- ORIGINAL handling (nil if not overridden) for revert-on-hijack:
        origBrakeForce = origBrakeForce, origDriveForce = origDriveForce,
        origTractionMax = origTractionMax, origTractionMin = origTractionMin,
        origDriveBias = origDriveBias,
    }
    spawnedCount = spawnedCount + 1
    dbgSpawnOk = dbgSpawnOk + 1
    if isAddon then
        addonAliveCount = addonAliveCount + 1
        -- DECK (v2.4.42): record this model's spawn ONLY on real success, so a pick
        -- that aborted at a spawn gate never burns one of the car's two slots.
        deckNote(modelName)
    else baseAliveCount = baseAliveCount + 1 end
    return true   -- (v2.4.64) cadence: signal a REAL spawn so the loop uses the
                  -- longer success cooldown; every bail above returns nil (falsy).
end

-- NOTE: the PARKED addon spawner was REMOVED (2026-08-26). Empty parked cars
-- snapped to road-center nodes and read as "stuck cars in the middle of the
-- road". We'll revisit roadside parking separately once the DRIVING spawner is
-- dialled in. (The `parked` meta flag / cull guard were removed with it.)

-- delete a spawned car AND its driver ped (deleting the vehicle alone leaves
-- the ped standing on the highway — the "lone ped, no car" bug).
local function destroySpawned(veh, meta)
    if meta and meta.driver and DoesEntityExist(meta.driver) then
        SetEntityAsMissionEntity(meta.driver, true, true)
        DeletePed(meta.driver)
    end
    if DoesEntityExist(veh) then
        SetEntityAsMissionEntity(veh, true, true)
        DeleteVehicle(veh)
    end
end

-- HAND A HIJACKED CAR BACK TO THE PLAYER (per user: "after the car gets hijacked
-- it still flags as an NPC car and the handling stays gimped"). When a player
-- takes the driver's seat we must (1) REVERT the per-vehicle handling overrides
-- (accel cut, brake boost) to stock so it drives like the real car, and (2) STOP
-- tracking/tasking it as ours (no more cruise/brake commands, no culling, no
-- mission-entity flag, drop the debug blip) so it becomes an ordinary player car.
-- We deliberately do NOT delete the NPC driver here — the takeover flow (jack)
-- makes the ped bail on its own; we just release our claim.
local function releaseSpawned(veh, meta)
    if DoesEntityExist(veh) then
        -- revert handling to the ORIGINAL values we captured at spawn
        if meta.origBrakeForce then
            SetVehicleHandlingFloat(veh, 'CHandlingData', 'fBrakeForce', meta.origBrakeForce)
        end
        if meta.origDriveForce then
            SetVehicleHandlingFloat(veh, 'CHandlingData', 'fInitialDriveForce', meta.origDriveForce)
        end
        -- revert the TC/grip floor so the player gets the real car's handling back
        if meta.origTractionMax then
            SetVehicleHandlingFloat(veh, 'CHandlingData', 'fTractionCurveMax', meta.origTractionMax)
        end
        if meta.origTractionMin then
            SetVehicleHandlingFloat(veh, 'CHandlingData', 'fTractionCurveMin', meta.origTractionMin)
        end
        -- revert the force-AWD drive bias so the player gets the real drivetrain back
        if meta.origDriveBias then
            SetVehicleHandlingFloat(veh, 'CHandlingData', 'fDriveBiasFront', meta.origDriveBias)
        end
        -- un-flag as OUR mission entity so the engine treats it as a normal car
        -- (it can now stream/persist under the player, not be force-managed by us).
        SetEntityAsMissionEntity(veh, false, false)
        SetVehicleHasBeenOwnedByPlayer(veh, true)
    end
end

-- Re-issue a stuck car's drive task. NORMAL rekicks just re-wander (harmless — it
-- re-paths from the current spot). REVERSE is strictly gated (v2.4.41, user: "they
-- ALL go reverse after a bit wait — reverse only after 12s+ continuously stuck, 2s
-- max, re-reverse only if still stuck, else reset the 12s timer"): fires ONLY when
-- meta.stuckContinuousSince (set by the watchdog, cleared only on GENUINE forward
-- movement — NOT during our own reverse) has been running >= reverseArmMs, and only
-- for reverseMaxMs at a time. While a reverse action is still running we never
-- re-fire. If the car is still stuck after the 2s the continuous timer is untouched
-- (car never moved) so it re-arms immediately; the moment it actually drives free
-- the watchdog clears the timer → it must wait the full 12s again next time.
local function rekickDriver(veh, meta)
    local sp   = T.spawner or {}
    local cms  = meta.cruiseMs or kmhToMs(120)
    local st   = meta.style or 262189
    local now  = nowMs()
    local revOn    = sp.stuckReverseEnable ~= false
    local armMs    = sp.reverseArmMs or 6000
    local revMs    = sp.reverseMaxMs or 1000
    local fwdTryMs = sp.reverseForwardTryMs or 1000

    -- reverse still running → let it finish, don't re-issue anything this tick.
    if meta.reversingUntil and now < meta.reversingUntil then return end

    -- RED-LIGHT GUARD (v2.4.43): a car legitimately stopped at a light is NOT
    -- wedged — never reverse it. The watchdog also freezes the continuous timer
    -- while at a light, so this is belt-and-suspenders.
    local atLights   = (sp.reverseSkipAtLights ~= false) and IsVehicleStoppedAtTrafficLights(veh)
    local continuous = meta.stuckContinuousSince and (now - meta.stuckContinuousSince) or 0
    -- FORCED-FORWARD window (v2.4.44 — user: "after a reverse it needs to go FORWARD;
    -- but if forward is blocked again it can INSTANTLY re-reverse"). Right after a
    -- reverse we require a forward attempt for fwdTryMs before another reverse. Being
    -- called here at all means the car is STILL stuck (the watchdog only rekicks stuck
    -- cars), so once this window elapses and it hasn't moved, forward IS blocked →
    -- reverse again immediately, no 6s wait.
    local forwardTry = meta.forwardTryUntil and now < meta.forwardTryUntil

    -- GENUINELY-WEDGED GATE (v2.4.47 — user: "car was on an EMPTY road ahead, crawled
    -- at 6 km/h, then reversed full and REARENDED, THEN re-pathed"). A car that just
    -- lost its path on a clear road is NOT wedged — it should re-path FORWARD, never
    -- reverse. Reverse is only justified when the car is actually boxed in: it has
    -- physically COLLIDED with something (wall / car it drove into) OR a vehicle sits
    -- directly ahead in-lane. On an open road with no contact, none of these hold →
    -- we fall through to a plain re-wander (find a new path going forward).
    local grace   = sp.blockAheadGraceMs or 1500
    local blockedAhead  = meta.blockedAheadTs  and (now - meta.blockedAheadTs)  < grace
    local collided      = HasEntityCollidedWithAnything(veh)
    local wedged        = collided or blockedAhead
    -- REAR-CLEAR GATE (v2.4.47): never reverse into a car behind us (the rearend the
    -- user saw). If a vehicle was just detected close behind, suppress reverse.
    local rearBlocked   = meta.blockedBehindTs and (now - meta.blockedBehindTs) < grace

    local mayReverse
    if not revOn or atLights or rearBlocked or not wedged
       or not (meta.driver and DoesEntityExist(meta.driver)) then
        mayReverse = false
    elseif meta.reverseEpisode then
        -- already reversed this episode → instant re-reverse once the forced-forward
        -- window is over (and it's still wedged with clear rear, checked above).
        mayReverse = not forwardTry
    else
        -- FIRST reverse of an episode → full continuous-stuck arm (6s) AND wedged.
        mayReverse = continuous >= armMs
    end

    if mayReverse then
        -- TASK_CAR_TEMP_ACTION id 3 = reverse-straight, bounded to revMs (1s). Speed
        -- while reversing is still clamped by the v2.4.38 reverse cap (38 km/h).
        TaskVehicleTempAction(meta.driver, veh, 3, revMs)
        meta.reversingUntil  = now + revMs
        meta.stuckSince      = now + revMs            -- no re-wander mid-reverse
        meta.reverseEpisode  = true                    -- in a reverse episode now
        meta.forwardTryUntil = now + revMs + fwdTryMs  -- force forward after reverse
    else
        TaskVehicleDriveWander(meta.driver, veh, cms, st)
        SetDriveTaskDrivingStyle(meta.driver, st)
        SetDriveTaskCruiseSpeed(meta.driver, cms)
        SetDriveTaskMaxCruiseSpeed(meta.driver, cms + 5.0)
        meta.stuckSince = nowMs()
    end
end

-- cull our spawned cars that are far away / behind / gone
local function cullSpawned(sp)
    local pc = GetEntityCoords(PlayerPedId())
    for veh, meta in pairs(spawned) do
        local drop = false
        if not DoesEntityExist(veh) then
            -- vehicle gone (streamed out / merged away) — clean up any orphan ped
            if meta.driver and DoesEntityExist(meta.driver) then
                SetEntityAsMissionEntity(meta.driver, true, true)
                DeletePed(meta.driver)
            end
            drop = true
        else
            -- HIJACK CHECK (per user: "after the car gets hijacked it still flags
            -- as an NPC car + handling stays gimped"). If a real PLAYER (local or
            -- remote) is in the driver's seat, this is no longer our car: revert its
            -- handling to stock and RELEASE it (stop tracking → the drive tick stops
            -- tasking it, culling stops managing it, blip drops). Checked here rather
            -- than in the 140ms tick because a jack isn't time-critical to catch.
            local seatPed = GetPedInVehicleSeat(veh, -1)
            if seatPed and seatPed ~= 0 and seatPed ~= meta.driver
                and IsPedAPlayer(seatPed) then
                releaseSpawned(veh, meta)
                drop = true          -- shared cleanup below drops blip + untracks
                goto cleanup
            end
            local vpos = GetEntityCoords(veh)
            local d = #(vpos - pc)
            -- CONFINED-ZONE GHOST DESPAWN (v2.4.50 — user: "if the car has been stuck
            -- within a radius-6 zone for 45s, just ghost-mode despawn it quietly").
            -- Unlike the speed-based stuckDeleteMs, this catches a car that keeps
            -- MOVING but never GOES anywhere (jitter, reverse-oscillation, spinning in
            -- place): we anchor its position and time how long it stays inside a small
            -- sphere. Leaving the sphere re-centres the anchor + resets the timer. When
            -- the confinement time is exceeded we FADE it out then delete quietly — no
            -- blink, works on-screen too (a car boxed in one spot for 45s isn't coming
            -- back and a soft fade is the least jarring way to remove it).
            if sp.confineDespawn ~= false then
                local cr = sp.confineRadius or 6.0
                if not meta.confineAnchor or #(vpos - meta.confineAnchor) > cr then
                    meta.confineAnchor = vpos       -- moved out of the zone → re-anchor
                    meta.confineSince  = nowMs()
                    if meta.confineFading then      -- escaped mid-fade → restore alpha
                        ResetEntityAlpha(veh)
                        meta.confineFading = nil
                    end
                else
                    local confinedMs = nowMs() - (meta.confineSince or nowMs())
                    local fadeMs     = sp.confineFadeMs or 700
                    local despawnMs  = sp.confineDespawnMs or 45000
                    if confinedMs > despawnMs then
                        destroySpawned(veh, meta)
                        drop = true
                        goto cleanup
                    elseif confinedMs > (despawnMs - fadeMs) then
                        -- final stretch → ramp alpha 255→0 so it ghosts out smoothly.
                        local t = (confinedMs - (despawnMs - fadeMs)) / fadeMs
                        if t < 0.0 then t = 0.0 elseif t > 1.0 then t = 1.0 end
                        local a = math.floor(255 * (1.0 - t))
                        SetEntityAlpha(veh, a, false)
                        meta.confineFading = true
                    end
                end
            end
            -- WANDERED INTO A NO-TRAFFIC ZONE (v2.4.37): a car can DRIVE into a
            -- user-painted clear/block zone after spawning (we exempt our cars
            -- from the ambient clear engine, so nothing else removes them). If it
            -- ends up inside one, delete it — off-screen preferred, but if it's
            -- sitting well inside the zone we remove it anyway (that's the whole
            -- point of the zone). margin=0 so only cars actually INSIDE go.
            if inBlockedScnZone(vpos.x, vpos.y, vpos.z, 0.0) then
                if not IsEntityOnScreen(veh) or d > (sp.noCullRadius or 90.0) then
                    destroySpawned(veh, meta)
                    drop = true
                    goto cleanup
                end
            end
            local noCull = (sp.noCullRadius or 90.0)
            -- ABSOLUTE STUCK TIMEOUT (per user "stuck > 45s = just delete it"):
            -- track how long a car has been near-stationary anywhere. Past this
            -- ceiling we delete it REGARDLESS of distance, on-screen state, or the
            -- no-cull bubble — a car wedged for 45s is never coming back, and a
            -- brief blink-out is better than a permanent roadblock. Cars that keep
            -- moving reset the timer (handled in the branches below), so a car
            -- legitimately waiting at a long red doesn't get nuked (that gap is the
            -- one you saw — the M5 waiting for the light, which is fine).
            if GetEntitySpeed(veh) <= 1.5 then
                meta.frozenSince = meta.frozenSince or nowMs()
                local frozenMs = nowMs() - meta.frozenSince
                -- OFF-SCREEN FAST DELETE (v2.4.31 — user: "avoid too many spawned
                -- cars being retarded/crashed and jamming an area — when no player
                -- is looking"). A stuck car the LOCAL player can't see is deleted on
                -- a MUCH shorter timeout so a pile-up clears itself the moment
                -- everyone looks away, instead of festering for the full 45s. NOTE:
                -- IsEntityOnScreen is LOCAL-only — with other players around a car
                -- off YOUR screen might be on theirs. That's acceptable here: the
                -- jam you see clears for you, and networked cars off everyone's
                -- screen get cleaned by whoever's client owns them.
                local offscreen = not IsEntityOnScreen(veh)
                if offscreen and frozenMs > (sp.stuckOffscreenMs or 5000) then
                    destroySpawned(veh, meta)
                    drop = true
                elseif frozenMs > (sp.stuckDeleteMs or 45000) then
                    -- absolute ceiling: gone regardless of visibility
                    destroySpawned(veh, meta)
                    drop = true
                end
            else
                -- FLIPPED / WRECKED: an upside-down car still jitters tiny speeds
                -- that would keep resetting frozenSince, so it never hits the stuck
                -- path. Catch it explicitly: if it's rolled onto roof/side AND
                -- off-screen, delete fast (it's never recovering). IsEntityUpsidedown
                -- catches full roll; the up-vector z check catches on-its-side.
                local up = GetEntityRotation(veh)   -- (pitch, roll, yaw) degrees
                local flipped = IsEntityUpsidedown(veh)
                    or math.abs(up.x) > 60.0 or math.abs(up.y) > 60.0
                if flipped and not IsEntityOnScreen(veh) then
                    meta.flippedSince = meta.flippedSince or nowMs()
                    if (nowMs() - meta.flippedSince) > (sp.flippedOffscreenMs or 2500) then
                        destroySpawned(veh, meta)
                        drop = true
                    end
                else
                    meta.flippedSince = nil
                end
                meta.frozenSince = nil
            end
            if drop then
                -- fall through to the shared drop cleanup below
            elseif d > (sp.hardCullDistance or 550.0) then
                -- HARD distance cull: past this range a car is a distant dot, so
                -- deleting it is invisible even if technically "on screen" down a
                -- long straight road. THIS FIXES "stops spawning after a few rounds
                -- / cars all bunched far away": ahead-spawns that outran the player
                -- stayed on-screen forever, were never culled, and pinned
                -- spawnedCount at the cap so no fresh nearby cars could spawn.
                destroySpawned(veh, meta)
                drop = true
            elseif d > (sp.cullDistance or 320.0) then
                -- normal cull: delete when far AND the engine isn't rendering it —
                -- never vanish a car the player can clearly see ("despawn in front
                -- of my face"). Between cullDistance and hardCullDistance we wait
                -- for it to go off-screen.
                if not IsEntityOnScreen(veh) then
                    destroySpawned(veh, meta)
                    drop = true
                end
            elseif d < noCull then
                -- HARD no-cull bubble around the player: whatever else is true
                -- (stuck, on-screen, whatever) we do NOT delete a car this close,
                -- because removing it is guaranteed to be visible. Stuck recovery
                -- below still RE-KICKS it; it just won't be deleted in the bubble.
                -- GENUINE forward movement resets everything. A car that's moving
                -- while OUR reverse action is active does NOT count (else the 12s
                -- continuous-stuck timer would reset every reverse). v2.4.41.
                local reversing = meta.reversingUntil and nowMs() < meta.reversingUntil
                -- RED-LIGHT GUARD (v2.4.43): waiting at a light is NOT being stuck —
                -- hold the continuous-stuck timer at now so red-light time never
                -- accumulates toward the 12s reverse arm. When it greens, the timer
                -- starts fresh from here.
                local atLights = (sp.reverseSkipAtLights ~= false) and IsVehicleStoppedAtTrafficLights(veh)
                -- FORWARD speed only (v2.4.49): a car coasting backward after a
                -- reverse must NOT count as "moving/recovered" — else we'd clear the
                -- stuck state and leave it taskless still rolling back.
                if (fwdSpeed(veh) > 1.5 and not reversing) or atLights then
                    meta.stuckSince = nil; meta.rekicks = 0
                    meta.stuckContinuousSince = nil
                    -- drove free → end the reverse episode; next reverse needs the
                    -- full arm (6s) again, not an instant re-reverse. (v2.4.44)
                    meta.reverseEpisode = nil; meta.forwardTryUntil = nil
                else
                    -- still try to un-stick, but suppress removal inside the bubble.
                    -- No rekick CAP here (we never delete a car this close, so the
                    -- give-up counter is meaningless) — keep re-issuing so the
                    -- time-gated reverse (12s+) can eventually fire. v2.4.41.
                    meta.stuckSince = meta.stuckSince or nowMs()
                    meta.stuckContinuousSince = meta.stuckContinuousSince or nowMs()
                    if (nowMs() - meta.stuckSince) > (sp.stuckRekickMs or 2000)
                        and meta.driver and DoesEntityExist(meta.driver) then
                        meta.rekicks = (meta.rekicks or 0) + 1
                        SetVehicleOnGroundProperly(veh)
                        rekickDriver(veh, meta)
                    end
                end
            else
                -- STUCK WATCHDOG + RECOVERY (fixes "addon driver stops/gets stuck
                -- in the middle of the road"). Root cause: a spawned car's drive
                -- task can complete or wedge (boxed in by traffic, confused node,
                -- red-light logic) and then it just sits there — the old speed
                -- re-assert deliberately SKIPPED stopped cars, so nothing ever
                -- restarted them. Now: when a car goes near-stationary, first try
                -- to UN-STICK it by re-issuing its drive task a few times; only if
                -- it stays wedged after that do we remove it (works on-screen too,
                -- since a car blocking the road in front of you is the whole
                -- complaint).
                -- GENUINE forward movement resets everything. Movement DURING our own
                -- reverse action doesn't count, so the 12s continuous-stuck timer
                -- keeps running across a reverse attempt (v2.4.41).
                local reversing = meta.reversingUntil and nowMs() < meta.reversingUntil
                -- RED-LIGHT GUARD (v2.4.43): treat "stopped at a light" like genuine
                -- movement for the stuck timers — a car waiting at a red is not
                -- wedged, so its wait must never accumulate toward the reverse arm
                -- (that was the "reverses while waiting for a red light" bug).
                local atLights = (sp.reverseSkipAtLights ~= false) and IsVehicleStoppedAtTrafficLights(veh)
                -- FORWARD speed only (v2.4.49): backward coast after a reverse is
                -- NOT recovery — see fwdSpeed(). Fixes "reverse text gone but still
                -- going backwards" (the watchdog cleared stuck state on the backward
                -- roll and never re-issued a forward drive task).
                local moving = (fwdSpeed(veh) > 1.5 and not reversing) or atLights
                if moving then
                    meta.stuckSince = nil
                    meta.rekicks = 0
                    meta.stuckContinuousSince = nil
                    -- drove free → end the reverse episode; next reverse needs the
                    -- full arm (6s) again, not an instant re-reverse. (v2.4.44)
                    meta.reverseEpisode = nil; meta.forwardTryUntil = nil
                else
                    meta.stuckSince = meta.stuckSince or nowMs()
                    meta.stuckContinuousSince = meta.stuckContinuousSince or nowMs()
                    local stuckMs = nowMs() - meta.stuckSince
                    -- GIVE-UP is now TIME-based (v2.4.41), not rekick-count: a car
                    -- must survive long enough to earn its 12s reverse attempt(s)
                    -- before we delete it. stuckGiveUpMs must exceed reverseArmMs so
                    -- reverse actually gets a chance. Continuous-stuck time (not
                    -- stuckSince, which is pushed forward during a reverse).
                    local contMs = nowMs() - meta.stuckContinuousSince
                    if stuckMs > (sp.stuckRekickMs or 2000) then
                        if contMs < (sp.stuckGiveUpMs or 16000)
                            and meta.driver and DoesEntityExist(meta.driver) then
                            -- nudge free + re-issue the drive task. rekickDriver
                            -- time-gates the reverse itself (12s+ continuous stuck).
                            meta.rekicks = (meta.rekicks or 0) + 1
                            SetVehicleOnGroundProperly(veh)
                            rekickDriver(veh, meta)
                        else
                            -- stuck past the give-up ceiling (16s+ continuous, reverse
                            -- attempts spent) → genuinely wedged. Remove it — it's been
                            -- blocking the road too long, delete even on-screen.
                            destroySpawned(veh, meta)
                            drop = true
                        end
                    end
                end
            end
        end
        ::cleanup::
        if drop then
            -- drop any debug blip attached to this car (raw native: removeBlip()
            -- is declared later as a local so it's not in scope here).
            if meta.blip and DoesBlipExist(meta.blip) then RemoveBlip(meta.blip) end
            spawned[veh] = nil
            spawnedCount = math.max(0, spawnedCount - 1)
            if meta.addon then addonAliveCount = math.max(0, addonAliveCount - 1)
            else baseAliveCount = math.max(0, baseAliveCount - 1) end
        end
    end
end

-- Re-assert cruise speed on our fast cars. The engine periodically resets a
-- ped's TaskVehicleDriveWander cruise back toward a default, so a reckless 280km/h
-- car would quietly slow down. We only re-push the ones whose current speed has
-- drifted well below their target (cheap: no re-task, just lift the cruise again).
-- NOTE: ADDON cars are NOT touched here — they're governed every tick by
-- addonDriveTick (accel governor + brake assist), which OWNS their cruise command.
-- Re-lifting an addon to full cruise here would defeat the accel governor between
-- ticks. This loop only keeps BASE (native GTA) spawned cars up to speed.
local function reassertSpeeds()
    for veh, meta in pairs(spawned) do
        if not meta.addon and meta.driver and DoesEntityExist(veh)
            and DoesEntityExist(meta.driver) and meta.cruiseMs then
            local cur = GetEntitySpeed(veh)
            -- only bother if it's actually moving and has fallen short of target
            if cur > 2.0 and cur < (meta.cruiseMs * 0.85) then
                SetDriveTaskCruiseSpeed(meta.driver, meta.cruiseMs)
                SetDriveTaskMaxCruiseSpeed(meta.driver, meta.cruiseMs + 5.0)
                if meta.style then SetDriveTaskDrivingStyle(meta.driver, meta.style) end
            end
        end
    end
end

-- ── ACTIVE BRAKE ASSIST (per user: "make addon NPCs ACTUALLY brake, but it
--    SLIDES the car") ─────────────────────────────────────────────────────────
-- The GTA drive task brakes too late at high speed → fast addons rear-end slower
-- traffic. v2.4.15 fixed the "doesn't brake" half by stamping TA_STRONG_BRAKE, but
-- that SLID the car: a full foot-brake from ~250 km/h inside a fixed 55 m window is
-- well inside the real braking distance (which grows with v²), so the wheels lock
-- and the tail steps out. This rewrite fixes the physics:
--
--   1. SPEED-SCALED LOOKAHEAD. We scan as far ahead as the car actually needs to
--      stop: d = v²/(2a) + reaction gap. At 250 km/h that's ~200 m, not 55 m — so
--      the car "sees" the obstacle in time to shed speed gently instead of slamming.
--   2. BLEED SPEED FIRST (no slide). The PRIMARY brake is a smooth cruise-cap
--      reduction toward the lead car's speed via SetDriveTaskCruiseSpeed. The drive
--      task lifts throttle and brakes GENTLY on its own — the car stays planted,
--      exactly how native traffic queues up. This is what makes them brake EARLY.
--   3. FOOT BRAKE = LAST RESORT, PULSED. Only when we're genuinely inside the
--      required stopping distance AND still closing hard do we add TA_STRONG_BRAKE,
--      and only in SHORT pulses (~90 ms at speed) so it scrubs speed without
--      locking/holding. Never the handbrake (TA_HANDBRAKE_* slides — the user's
--      exact worry). By the time we ever reach this stage we've already bled a lot
--      of speed via step 2, so the pulse brakes from a lower, grippier speed.
--
-- Detection is a PROXIMITY scan (GetGamePool), not a raycast — FiveM vehicle rays
-- cap ~30 m, useless at speed. Keep vehicles that are ahead (forward dot) and
-- roughly in-lane (small lateral offset). Cheap dot-product math, no range limit.
-- ── ACCELERATION GOVERNOR (per user: "accel too fast for the AI even at 90/120/
--    180/240 — NPCs go retarded") ─────────────────────────────────────────────
-- Cutting fInitialDriveForce (v2.4.18) wasn't enough: the drive task still commands
-- FULL throttle, so a powerful car just reaches its (still huge) acceleration a bit
-- later — and it's twitchy at EVERY speed. The proper fix is to limit the
-- acceleration RATE directly (m/s²), independent of engine power. We do that by
-- never letting the commanded cruise target sit more than a small step above the
-- car's CURRENT speed: cruiseCmd = min(fullCruise, curSpeed + accelRate·dt +
-- headroom). The AI can only ever chase a ceiling that's just ahead of it, so it
-- accelerates at ~accelRate no matter how much power the car has. Re-derived from
-- ACTUAL speed each tick (stateless, self-correcting): after a slowdown it ramps
-- back up gently instead of flooring it. The brake assist below composes with this
-- (it can only ever LOWER the target), and it runs in the SAME tick.
local TA_STRONG_BRAKE = 19
-- STRAIGHT-LINE brake temp actions (TASK_CAR_TEMP_ACTION ids). Unlike a drive
-- style, a temp action OVERRIDES the ped's steering for its duration — the wheels
-- are held STRAIGHT, so the car cannot weave/sway while braking (the user's key
-- complaint: "when they brake they still steer and go left/right"). 1 = slow down
-- softly (gentle, straight), 6 = slow down hard (strong, straight). We pick between
-- them by speed so it's gentle at mid speed and strong at high speed.
local TA_BRAKE_SOFT_STRAIGHT = 1
local TA_BRAKE_HARD_STRAIGHT = 6
local function addonDriveTick(dtSec)
    local ac = T.addon or {}
    local accelRate = ac.accelRateMs2 or 3.0        -- max accel the AI may use (m/s²)
    local headroom  = ac.accelHeadroomMs or 0.6     -- small cruise headroom (m/s) so it keeps climbing
    local baOn      = ac.brakeAssist ~= false
    local laneHalf    = ac.brakeLaneHalf or 3.2       -- in-lane half-width (m)
    local decel       = ac.brakeDecel or 6.5          -- assumed comfy decel (m/s²)
    local reactBuffer = ac.brakeReactBuffer or 1.0    -- extra seconds of reaction gap
    local minGap      = ac.brakeMinGap or 6.0         -- always keep >= this gap (m)
    local scanMax     = ac.brakeScanMax or 220.0      -- hard cap on scan distance (m)
    local activeDist  = ac.brakeActiveDist or 350.0   -- only run the brake scan within this of player
    -- brake FEEL knobs (v2.4.23): gentler mid-speed, stronger high-speed
    local hardMinMs2  = kmhToMs(ac.brakeHardMinKmh or 95.0)   -- below this: no hard pulse, bleed only
    local bleedZone   = ac.brakeBleedZone or 3.0             -- bleed starts at safeGap × this
    local pulseMinMs  = ac.brakePulseMinMs or 70
    local pulseMaxMs  = ac.brakePulseMaxMs or 260
    local pulseMaxAt  = kmhToMs(ac.brakePulseMaxAtKmh or 300.0)
    -- OVERTAKE-WHEN-STUCK (per user: "when blocked/stuck/gap-held too long, allow
    -- an overtake for 3-5s so they don't get stuck"). If a car sits in the gap-hold
    -- brake state while crawling for longer than overtakeStuckMs, it opens an
    -- overtake WINDOW (overtakeMs) where it swaps to the swim-through style (swerve
    -- around vehicles) + ignores the brake-hold so it can pull out and pass.
    local otOn        = ac.overtakeWhenStuck ~= false
    local otStuckMs   = ac.overtakeStuckMs or 3500        -- gap-held+slow this long → overtake
    local otStuckMin  = ac.overtakeStuckMinMs or 3000     -- RANDOM range (v2.4.35): lower bound
    local otStuckMax  = ac.overtakeStuckMaxMs or 6000     -- upper bound (user: "3-6s random")
    local otMs        = ac.overtakeMs or 4000             -- how long the overtake window lasts
    local otSlowMs2   = kmhToMs(ac.overtakeSlowKmh or 35.0) -- "crawling" threshold (m/s)
    local otCooldownMs= ac.overtakeCooldownMs or 6000     -- min gap between overtakes per car
    local otStyle     = ac.overtakeStyle or (ac.recklessStyle or 262206)
    -- FLICK → OVERTAKE: count brake on/off flicks; N flicks in a window forces a
    -- clean overtake so the car stops oscillating (brake↔drive spam = the slide).
    local otFlickN    = ac.overtakeFlickCount or 6
    local otFlickWin  = ac.overtakeFlickWindowMs or 4000
    local otAbility   = ac.overtakeAbility or 1.0
    local otAggr      = ac.overtakeAggression or 0.0
    -- LATERAL PULL (v2.4.71): physically slide the car toward the clear side during
    -- the burst — the style swap alone didn't move it out (the "OVERTAKE-L but never
    -- steered" bug). overtakeSide (L/R from sideLaneClear) picks the direction.
    local otPullOn    = ac.overtakePull ~= false
    local otPullMs2   = ac.overtakePullMs2 or 3.5
    local otPullMaxMs = ac.overtakePullMaxMs or 4.0
    local otPullOff   = ac.overtakePullOffset or 3.2
    -- OVERTAKE SLIDE aids (v2.4.32): cap pass speed + extra grip + earlier TC cut.
    local otMaxMs     = kmhToMs(ac.overtakeMaxKmh or 110.0)
    local otGripBoost = ac.overtakeGripBoost or 1.30
    local otSlipCos   = math.cos(math.rad(ac.overtakeSlipDeg or 14.0))
    -- CURVE-BUST: route around the stock AI angle-curve ~125 cap in pure Lua.
    local cbOn        = ac.curveBust ~= false
    local cbAboveMs   = kmhToMs(ac.curveBustAboveKmh or 118.0)
    local cbClearOnly = ac.curveBustClearOnly ~= false
    local cbGrounded  = ac.curveBustGroundedOnly ~= false
    local cbMaxPitch  = ac.curveBustMaxPitch or 12.0
    local cbAccelMs   = ac.curveBustAccelMs2 or (ac.accelRateMs2 or 3.0)  -- v2.4.66: gentler high-speed ramp
    -- STEER VELOCITY SCRUB (v2.4.67 — rebuilt): direct smooth speed bleed on ANY
    -- steering input (corner / turn / overtake lane-change), NOT gated on the corner
    -- governor's meta.cornering flag (which rarely tripped due to tier start-angles).
    -- Reads the raw steering angle every tick and eases HORIZONTAL velocity down —
    -- never a brake pulse. See the block below for the full rationale.
    local cScrubOn    = ac.cornerScrub ~= false
    local cScrubRate  = ac.cornerScrubRate or 12.0
    local cScrubMinMs = kmhToMs(ac.cornerScrubMinKmh or 55.0)
    local cScrubStart = ac.cornerScrubStartDeg or 4.0    -- steer angle (deg) where scrub begins
    local cScrubMaxD  = ac.cornerScrubMaxDeg or 22.0     -- steer angle for the full cut
    local cScrubMinF  = ac.cornerScrubMinFactor or 0.45  -- hardest velocity cut (×) at full lock
    local cScrubEma   = ac.cornerScrubEmaAlpha or 0.35   -- steer-angle smoothing (higher = snappier)
    -- SURFACE MAGNET (gentle downforce so cars don't get light/skippy at speed).
    local stickOn     = ac.stickToSurface ~= false
    local stickAccel  = ac.stickForce or 2.5
    local stickMinMs  = kmhToMs(ac.stickMinKmh or 60.0)
    local lowSpeedMs  = kmhToMs(ac.lowSpeedKmh or 40.0)        -- below this: boost accel
    local lowSpeedAccelMult = ac.lowSpeedAccelMult or 2.0
    local crawlFloorMs = kmhToMs(ac.brakeCrawlKmh or 15.0)    -- bleed target floor
    local oncomingDot = ac.oncomingDot or -0.5                -- lead-facing dot cutoff
    local revCapMs    = kmhToMs(ac.reverseCapKmh or 38.0)     -- max NPC reverse speed
    local blockAheadDist = ac.blockAheadDist or 9.0           -- car-just-ahead flag range (m)
    -- CORNER SPEED GOVERNOR (v2.4.39): ease cruise down as steering angle grows.
    local cornerOn    = ac.cornerGovernor ~= false
    local cornerMinMs = kmhToMs(ac.cornerMinKmh or 45.0)      -- below this: no corner cut
    local cornerDeg   = ac.cornerStartDeg or 6.0              -- start easing past this steer angle
    local cornerMaxDeg = ac.cornerMaxDeg or 22.0             -- full cut reached here
    local cornerMinFactor = ac.cornerMinFactor or 0.55       -- hardest cut floor (non-reckless)
    local cornerMinFactorReckless = ac.cornerMinFactorReckless or 0.68  -- reckless carries a bit more
    local cornerEmaAlpha = ac.cornerEmaAlpha or 0.25         -- steer-angle smoothing (0..1, lower=smoother)
    -- per-tier additive start-angle bonus: higher = ignores more lane-hold wobble =
    -- climbs toward its tier cap on straights instead of bouncing at the base band.
    local cornerStartBonus = ac.cornerStartBonus or { S = 10.0, A = 6.0, B = 2.0 }
    local cornerStartBonusReckless = ac.cornerStartBonusReckless or 3.0
    -- CORNER-APPROACH SLOWDOWN (v2.4.75): the ANTICIPATION layer the governor+scrub
    -- lack — both only cut once the wheel is ALREADY turning. This samples the road
    -- heading ahead (speed-scaled lookahead) and pre-slows the cruise BEFORE the
    -- bend, like a driver lifting off on approach. Throttled per caEveryMs.
    local caOn        = ac.cornerApproach ~= false
    local caEveryMs   = ac.cornerApproachEveryMs or 250
    local caMinMs     = kmhToMs(ac.cornerApproachMinKmh or 50.0)
    local caBaseM     = ac.cornerApproachBaseM or 22.0
    local caTimeS     = ac.cornerApproachTimeS or 1.6
    local caStartDeg  = ac.cornerApproachStartDeg or 12.0
    local caMaxDeg    = ac.cornerApproachMaxDeg or 70.0
    local caMinFac    = ac.cornerApproachMinFactor or 0.55
    local caMinFacReck = ac.cornerApproachMinFactorReckless or 0.70
    -- COUNTER-STEER YAW DAMPER (v2.4.69): offset the AI's always-oversteer by damping
    -- excess yaw (rotation outrunning travel direction) — a direct counter-yaw, no
    -- touch to the drive task / steering input.
    local csOn        = ac.counterSteer ~= false
    local csMinMs     = kmhToMs(ac.counterSteerMinKmh or 40.0)
    local csSlipCos   = math.cos(math.rad(ac.counterSteerSlipDeg or 6.0))   -- slip must exceed this angle
    local csMaxSlip   = ac.counterSteerMaxSlip or 30.0
    local csSlipStart = ac.counterSteerSlipDeg or 6.0
    local csGain      = ac.counterSteerGain or 0.45
    local csYawMin    = ac.counterSteerYawMin or 0.15
    -- ABS/TC anti-spin: throttle-cut when the car is sliding (heading vs velocity
    -- angle > tcSlipDeg) so it hooks back up instead of spinning into a wreck.
    local tcOn        = ac.absAssist ~= false
    local tcSlipCos   = math.cos(math.rad(ac.tcSlipDeg or 22.0))  -- compare dot >= cos(angle)
    local tcCut       = ac.tcCutFactor or 0.55
    local tcMinMs     = kmhToMs(ac.tcMinSpeedKmh or 45.0)

    -- PERF: snapshot the vehicle pool ONCE per tick (was: GetGamePool per addon car
    -- per tick = ~N fetches + N×M coord reads). We fetch the pool once, cache each
    -- vehicle's coords + velocity once, and pre-filter to vehicles within brake
    -- range of the PLAYER so the per-car inner loop is tiny. Every addon reuses this.
    local ppos = GetEntityCoords(PlayerPedId())
    local nearVeh, nearCoord, nearVel, nearFwd, nearN = {}, {}, {}, {}, 0
    if baOn then
        local pool = GetGamePool('CVehicle')
        local gate = activeDist + scanMax   -- a lead car can sit up to scanMax ahead
        for i = 1, #pool do
            local other = pool[i]
            if other and DoesEntityExist(other) then
                local oc = GetEntityCoords(other)
                if #(oc - ppos) < gate then
                    nearN = nearN + 1
                    nearVeh[nearN]   = other
                    nearCoord[nearN] = oc
                    nearVel[nearN]   = GetEntityVelocity(other)
                    -- forward vector (not velocity): lets us reject oncoming/opposite
                    -- -road cars even when they're stopped (velocity ~0). v2.4.36
                    nearFwd[nearN]   = GetEntityForwardVector(other)
                end
            end
        end
    end

    local now = nowMs()
    local hornMult = ac.hornBoostMult or 1.30
    local hornAccel = ac.hornBoostAccel or 7.0
    -- HORN YIELD (v2.4.72): the "pull to the side when honked" half of horn boost.
    local hornYieldOn  = ac.hornYield ~= false
    local hornYieldMinMs = kmhToMs(ac.hornYieldMinKmh or 25.0)
    local hornYieldMs2   = ac.hornYieldPullMs2 or 3.5
    local hornYieldMaxMs = ac.hornYieldPullMaxMs or 4.0
    local hornYieldOff   = ac.hornYieldPullOffset or 3.2
    for veh, meta in pairs(spawned) do
        -- addon cars only, alive, we own the driver
        if meta.addon and meta.driver and DoesEntityExist(veh) and DoesEntityExist(meta.driver) then
            local spd = GetEntitySpeed(veh)   -- m/s (unsigned)

            -- REVERSE CAP (v2.4.38 — user: "cap ALL npc reverse at max 38 km/h;
            -- they reverse so fast"). GetEntitySpeed is unsigned, so detect reverse
            -- via the velocity's dot with the car's forward vector: negative = going
            -- backward. This catches EVERY reverse source (the stuck-recovery temp
            -- action 3, and the AI backing up on its own). If it's reversing faster
            -- than revCapMs, scale the horizontal velocity back to the cap (keep z so
            -- we never fight gravity). Runs before anything else touches speed.
            do
                local fv = GetEntityForwardVector(veh)
                local v  = GetEntityVelocity(veh)
                local along = v.x * fv.x + v.y * fv.y   -- signed ground speed along heading
                if along < -revCapMs then
                    local hmag = math.sqrt(v.x * v.x + v.y * v.y)
                    if hmag > 0.01 then
                        local s = revCapMs / hmag       -- shrink to the cap magnitude
                        SetEntityVelocity(veh, v.x * s, v.y * s, v.z)
                        spd = GetEntitySpeed(veh)
                    end
                end

                -- REVERSE FALLING EDGE (v2.4.49 — user: "even after the reverse text
                -- is gone it's still going backwards"). TaskVehicleTempAction (id 3)
                -- REPLACES the drive task for its duration and does NOT auto-restore,
                -- so the instant the 1s reverse expires the ped is TASKLESS and the
                -- car keeps coasting BACKWARD on momentum until the ~2s watchdog
                -- rekick catches it. Detect the edge (reversingUntil set but now past)
                -- and immediately: (1) kill the residual backward roll, (2) re-issue a
                -- forward drive task so it drives off at once instead of drifting back.
                if meta.reversingUntil and now >= meta.reversingUntil then
                    meta.reversingUntil = nil
                    if along < 0.0 then                 -- still rolling backward → stop it
                        SetEntityVelocity(veh, 0.0, 0.0, v.z)
                        spd = GetEntitySpeed(veh)
                    end
                    local cms = meta.cruiseMs or kmhToMs(120)
                    local st  = meta.style or 262189
                    TaskVehicleDriveWander(meta.driver, veh, cms, st)
                    SetDriveTaskDrivingStyle(meta.driver, st)
                    SetDriveTaskCruiseSpeed(meta.driver, cms)
                    SetDriveTaskMaxCruiseSpeed(meta.driver, cms + 5.0)
                end
            end

            local fullCruise = meta.cruiseMs or spd

            -- HORN BOOST: a player honked near this NPC → temporarily raise its
            -- cruise target AND its accel rate (snappy getaway) until the boost
            -- expires. Wangan "move over / let's go" feel.
            local boosted = meta.hornBoostUntil and now < meta.hornBoostUntil
            local carAccel = accelRate
            if boosted then
                fullCruise = fullCruise * hornMult
                carAccel = hornAccel
            end
            -- LOW-SPEED ACCEL BOOST (v2.4.36): pulling away from a stop / low crawl
            -- felt sluggish under the flat accelRate. Below lowSpeedMs we scale the
            -- allowed accel up (lerped from lowSpeedAccelMult at 0 → 1.0 at lowSpeedMs)
            -- so the getaway is snappy, then it's back to normal above that speed.
            if not boosted and spd < lowSpeedMs then
                local f = spd / lowSpeedMs                 -- 0 at stop → 1 at lowSpeedMs
                local mult = lowSpeedAccelMult + (1.0 - lowSpeedAccelMult) * f
                carAccel = carAccel * mult
            end

            -- 1) ACCEL GOVERNOR ceiling — the throttle limiter. Never command more
            --    than a small step above current speed, so accel is capped at
            --    ~accelRate regardless of the car's power. (Runs for EVERY addon,
            --    even far ones — else a distant car rockets to full cruise.)
            local accelCeil = math.min(fullCruise, spd + carAccel * dtSec + headroom)

            -- 2) BRAKE ASSIST — may only LOWER the target (never raises it). Skipped
            --    for cars far from the player (you can't see them; the accel governor
            --    already keeps them sane) — that's the brakeActiveDist gate.
            local brakeTarget = fullCruise
            local held        = false
            local wantBrake   = false   -- hard foot-brake pulse this tick?
            local hasLead     = false   -- a lead car was found in the brake scan (hoisted
                                        -- to tick scope so the curve-bust below can gate on it;
                                        -- nearestGap itself is local to the baOn block)
            -- OVERTAKE WINDOW: are we currently inside an active overtake burst?
            -- (set below once gap-hold has lasted too long). While overtaking we
            -- suppress the brake-hold and swap to the swim-through style so the car
            -- pulls out and passes instead of sitting stuck behind slow traffic.
            local overtaking = otOn and meta.overtakeUntil and now < meta.overtakeUntil
            local vc  = GetEntityCoords(veh)
            -- ALWAYS-ON FORWARD-BLOCKER FLAG (v2.4.38): the braking scan below is
            -- gated on spd>8, so once a car fully STOPS behind a queue we lose the
            -- "traffic ahead" knowledge and the stuck-watchdog mistook a car that's
            -- legitimately WAITING for one that's wedged — then reversed it into the
            -- queue for no reason. This cheap short-range check runs at ANY speed and
            -- stamps meta.blockedAheadTs so the watchdog reverses ONLY when the path
            -- ahead is actually clear (genuinely stuck), never while waiting.
            if baOn then
                local fwdb = GetEntityForwardVector(veh)
                for i = 1, nearN do
                    local other = nearVeh[i]
                    if other ~= veh then
                        local to = nearCoord[i] - vc
                        local ah = to.x * fwdb.x + to.y * fwdb.y
                        if ah > 1.0 and ah < blockAheadDist then
                            local lt = math.abs(to.x * fwdb.y - to.y * fwdb.x)
                            if lt < laneHalf then meta.blockedAheadTs = now; break end
                        end
                    end
                end
                -- REAR-BLOCKER FLAG (v2.4.47 — user: "car reversed full and REARENDED
                -- something behind it"). Mirror the forward scan looking BACKWARDS so
                -- rekickDriver refuses to reverse when a car sits behind us. `ah < -1.0`
                -- = behind; within rearBlockDist and in-lane → stamp blockedBehindTs.
                for i = 1, nearN do
                    local other = nearVeh[i]
                    if other ~= veh then
                        local to = nearCoord[i] - vc
                        local ah = to.x * fwdb.x + to.y * fwdb.y
                        if ah < -1.0 and ah > -(ac.rearBlockDist or 8.0) then
                            local lt = math.abs(to.x * fwdb.y - to.y * fwdb.x)
                            if lt < laneHalf then meta.blockedBehindTs = now; break end
                        end
                    end
                end
            end
            if baOn and spd > 8.0 and #(vc - ppos) < activeDist then
                local fwd = GetEntityForwardVector(veh)
                -- speed-scaled scan: full physical braking distance + reaction gap.
                local brakeDist = (spd * spd) / (2.0 * decel)
                local scanAhead = math.min(scanMax, brakeDist + spd * reactBuffer + 12.0)
                local nearestGap, nearestLeadSpd = nil, 0.0
                for i = 1, nearN do
                    local other = nearVeh[i]
                    if other ~= veh then
                        local oc = nearCoord[i]
                        local to = oc - vc
                        local ahead = to.x * fwd.x + to.y * fwd.y   -- forward dot
                        if ahead > 2.0 and ahead < scanAhead then
                            local lat = math.abs(to.x * fwd.y - to.y * fwd.x)
                            if lat < laneHalf then
                                -- OPPOSITE-ROAD FILTER (v2.4.36): ignore cars facing
                                -- back at us (oncoming / other carriageway). Their
                                -- forward vector points against ours (dot < oncomingDot)
                                -- so we don't brake to a crawl for traffic we'll never
                                -- actually reach. user: "even on an opposite road they
                                -- slow to 6kmh... they shouldn't."
                                local ofwd = nearFwd[i]
                                local facing = ofwd.x * fwd.x + ofwd.y * fwd.y
                                if facing >= oncomingDot then
                                    local gap = ahead - 5.0   -- minus ~a car length
                                    if not nearestGap or gap < nearestGap then
                                        local ov = nearVel[i]
                                        nearestGap = gap
                                        nearestLeadSpd = ov.x * fwd.x + ov.y * fwd.y
                                    end
                                end
                            end
                        end
                    end
                end
                if nearestGap then
                    hasLead = true
                    local closing = spd - nearestLeadSpd            -- + = we're gaining
                    local reqDist = 0.0
                    if closing > 0.0 then
                        reqDist = (closing * closing) / (2.0 * decel) + spd * reactBuffer
                    end
                    local safeGap = math.max(minGap, reqDist)
                    -- Enter the bleed zone → we need to slow for the lead car. Also
                    -- lower the cruise TARGET toward the lead's speed (so when the
                    -- brake temp action expires the drive task doesn't immediately
                    -- floor it again), but the ACTUAL slowing is done by a
                    -- straight-line temp action below — NOT by the drive task.
                    if nearestGap < safeGap * bleedZone then
                        local t = (safeGap * bleedZone - nearestGap) / math.max(0.1, safeGap * (bleedZone - 1.0))
                        if t < 0.0 then t = 0.0 elseif t > 1.0 then t = 1.0 end
                        local leadTarget = math.max(0.0, nearestLeadSpd)
                        brakeTarget = fullCruise + (leadTarget - fullCruise) * t
                        if brakeTarget < 0.0 then brakeTarget = 0.0 end
                        -- CRAWL FLOOR (v2.4.36): don't bleed all the way to a near-stop
                        -- for ordinary slow traffic — floor the target at crawlFloorMs
                        -- (~15 km/h) so cars keep rolling instead of freezing at 6 km/h.
                        -- EXCEPTION: if the gap is critically small (< minGap) we still
                        -- allow a genuine stop so they don't rear-end the lead.
                        if nearestGap > minGap and brakeTarget < crawlFloorMs then
                            brakeTarget = crawlFloorMs
                        end
                        held = true
                    end
                    -- OVERTAKE-WHEN-STUCK bookkeeping: accumulate how long we've been
                    -- gap-held AND crawling behind this lead. Reckless cars already
                    -- swim through so they never build stuck-time.
                    if otOn and not meta.reckless then
                        if held and spd < otSlowMs2 then
                            if not meta.gapHoldSince then
                                meta.gapHoldSince = now
                                -- RANDOM gap-hold threshold per attempt (v2.4.35 —
                                -- user: "if gap-held for 3-6s (random), start the
                                -- overtake"). Roll a fresh threshold each time the
                                -- gap-hold begins so cars don't all pull out in
                                -- lockstep — staggered, more natural traffic.
                                meta.gapHoldNeed = math.random(otStuckMin, otStuckMax)
                            end
                            -- stuck behind slow traffic too long → open an overtake
                            -- window (respecting a per-car cooldown so it doesn't
                            -- chain-overtake forever). During the window `overtaking`
                            -- is true → brake-hold suppressed + swim-through style.
            if not overtaking
                                and (now - meta.gapHoldSince) > (meta.gapHoldNeed or otStuckMs)
                                and (not meta.overtakeCooldownUntil or now > meta.overtakeCooldownUntil) then
                                -- SIDE-LANE CHECK (v2.4.68): same "if possible" gate as
                                -- the flick path — only pull out when a lane is free.
                                local side = sideLaneClear(veh, vc, fwd, nearVeh, nearCoord, nearN, ac)
                                if side then
                                    meta.overtakeUntil = now + otMs
                                    meta.overtakeCooldownUntil = now + otMs + otCooldownMs
                                    meta.overtakeSide = side
                                    meta.gapHoldSince = nil
                                    meta.gapHoldNeed = nil
                                    overtaking = true
                                end
                                -- if no side is clear we simply stay gap-held; the timer
                                -- keeps ticking so it fires the instant a lane opens.
                            end
                        else
                            meta.gapHoldSince = nil   -- moving again → reset the timer
                            meta.gapHoldNeed = nil
                        end
                        -- FLICK → OVERTAKE (user: "6-8 flicks then overtake 5s"). A
                        -- flick = a brake rising-edge (was NOT held last tick, IS held
                        -- now) while there's still a lead car. Count them inside a
                        -- sliding window; enough flicks means the car is oscillating
                        -- (brake↔drive spam = the slide) so we commit to one overtake.
                        if held and not meta.heldPrev then
                            -- reset the counter if the last flick was too long ago
                            if not meta.flickAt or (now - meta.flickAt) > otFlickWin then
                                meta.flickCount = 0
                            end
                            meta.flickCount = (meta.flickCount or 0) + 1
                            meta.flickAt = now
                            -- SPEED GATE (v2.4.33): only commit to the pass once the
                            -- car is at/below the safe swerve speed. If it's still
                            -- fast, we DON'T overtake yet — it keeps straight-line
                            -- braking behind the lead (which coasts it down straight)
                            -- until it's slow enough, THEN passes clean. This is what
                            -- stops the brake+steer-at-once swerve: we never swim-
                            -- through while still going too fast to hold the swerve.
                            if not overtaking
                                and meta.flickCount >= otFlickN
                                and spd <= otMaxMs + kmhToMs(10.0)
                                and (not meta.overtakeCooldownUntil or now > meta.overtakeCooldownUntil) then
                                -- SIDE-LANE CHECK (v2.4.68 — user: "go to the side lane
                                -- IF POSSIBLE"). Only commit the pass when an adjacent
                                -- lane is actually clear (no car alongside / just ahead
                                -- beside / catching up behind). If BOTH sides are blocked
                                -- we DON'T pull out — keep straight-line braking behind
                                -- the lead and hold the flick count pinned at the
                                -- threshold so it re-checks every flick until a lane opens.
                                local side = sideLaneClear(veh, vc, fwd, nearVeh, nearCoord, nearN, ac)
                                if side then
                                    meta.overtakeUntil = now + otMs
                                    meta.overtakeCooldownUntil = now + otMs + otCooldownMs
                                    meta.overtakeSide = side       -- 'L'/'R' for the steer bias
                                    meta.flickCount = 0
                                    meta.gapHoldSince = nil
                                    overtaking = true
                                else
                                    -- no lane free: don't spam-increment forever; keep it
                                    -- ready to fire the instant a side clears.
                                    meta.flickCount = otFlickN
                                end
                            end
                        end
                        meta.heldPrev = held
                    end
                    -- STRAIGHT-LINE BRAKING (v2.4.26 — the definitive sway fix): the
                    -- old approach only LOWERED the cruise and let the drive task
                    -- brake itself, which meant the AI kept STEERING while braking →
                    -- the left/right weave the user kept seeing. A TEMP ACTION, by
                    -- contrast, OVERRIDES steering: the wheels are held DEAD STRAIGHT
                    -- for its whole duration, so the car physically cannot sway. So
                    -- whenever a NON-RECKLESS car needs to slow for traffic we brake
                    -- with a straight-line temp action instead. Soft (id 1) at mid
                    -- speed for a gentle straight coast-down; hard (id 6) at high
                    -- speed / when closing fast. Reckless cars are exempt — they're
                    -- MEANT to swerve/swim through, so they keep the cruise-bleed.
                    if overtaking then
                        -- OVERTAKING: don't brake-hold. Let the swim-through style
                        -- (applied below) steer the car out and around the lead. The
                        -- old soft-stab here fired a straight-line temp action that
                        -- SNAPPED the wheels straight mid-lane-change → fought the
                        -- steer (part of the v2.4.32 swerve). Now we only stab as a
                        -- true last-resort anti-ram: right on the bumper AND still
                        -- closing HARD (it shouldn't be, since we hold speed not
                        -- accelerate). Tighter gate so it almost never interrupts the
                        -- steer, and only a very short pulse when it must.
                        if nearestGap < minGap * 0.6 and closing > 8.0 then
                            wantBrake = true
                            TaskVehicleTempAction(meta.driver, veh, TA_BRAKE_SOFT_STRAIGHT, pulseMinMs)
                        end
                    elseif held and not meta.reckless then
                        wantBrake = true
                        local hard = spd > hardMinMs2 or closing > 6.0
                        local act  = hard and TA_BRAKE_HARD_STRAIGHT or TA_BRAKE_SOFT_STRAIGHT
                        -- duration scales UP with speed: short scrub at mid speed,
                        -- longer hold at high speed (user: "gentler mid, stronger
                        -- high"). One tick's worth (+margin) so it re-fires smoothly
                        -- each brakeTick without ever locking for a long stretch.
                        local f = (spd - hardMinMs2) / math.max(0.1, (pulseMaxAt - hardMinMs2))
                        if f < 0.0 then f = 0.0 elseif f > 1.0 then f = 1.0 end
                        local ms = math.floor(pulseMinMs + (pulseMaxMs - pulseMinMs) * f)
                        TaskVehicleTempAction(meta.driver, veh, act, ms)
                    elseif spd > hardMinMs2 and closing > 3.0 and nearestGap < safeGap * 1.05 then
                        -- RECKLESS fallback: still avoid rear-ending — a short hard
                        -- straight stab (they can resume swerving right after).
                        wantBrake = true
                        local f = (spd - hardMinMs2) / math.max(0.1, (pulseMaxAt - hardMinMs2))
                        if f < 0.0 then f = 0.0 elseif f > 1.0 then f = 1.0 end
                        local ms = math.floor(pulseMinMs + (pulseMaxMs - pulseMinMs) * f)
                        TaskVehicleTempAction(meta.driver, veh, TA_STRONG_BRAKE, ms)
                    end
                end
            end

            -- 3) FINAL commanded cruise = the lower of the accel ceiling and the
            --    brake target. Accel governor caps how fast it speeds UP; brake
            --    caps how fast it may go when closing on traffic. Only push it when
            --    NOT mid foot-brake-pulse (the temp action owns the task then).
            --    While OVERTAKING we ignore brakeTarget (the whole point is to NOT
            --    slow to the lead's speed) and just let the accel governor pull it
            --    up to full cruise so it actually gets past.
            local finalCruise = overtaking and accelCeil or math.min(accelCeil, brakeTarget)
            if finalCruise < 0.0 then finalCruise = 0.0 end
            -- OVERTAKE SPEED (v2.4.33): do NOT clamp down to a cap here — commanding
            -- a cruise BELOW current speed makes the drive task BRAKE, so the car was
            -- braking + steering + accelerating all at once during the pass (the
            -- swerve-behind-the-native the user reported). Instead we GATE the
            -- overtake trigger on speed (below), so a car only commits to the pass
            -- once it's already slow enough to swerve cleanly. During the window we
            -- just hold its current speed (no brake, no big accel) so it steers out
            -- smooth: cap the target at whatever it entered the pass at, never below.
            if overtaking then
                local hold = math.min(spd, otMaxMs)          -- never command a slowdown
                if finalCruise > hold then finalCruise = hold end
                if finalCruise < spd then finalCruise = spd end  -- never below current = no brake
            end

            -- ABS/TC ANTI-SPIN (v2.4.31): if the car is SLIDING — its velocity
            -- vector has diverged from where the nose points by more than tcSlipDeg —
            -- ease off the throttle (cut the commanded cruise) so grip recovers
            -- instead of the slide blowing out into a spin/wreck (the "retarded"
            -- pile-ups). Only above tcMinMs (low-speed slides are harmless) and only
            -- while actually moving. Cheap: one forward-vector + one velocity read,
            -- normalised dot = cos(slip angle). meta.tcSliding surfaces to debug.
            -- While OVERTAKING we use a TIGHTER slip threshold (otSlipCos) so the cut
            -- trips earlier and catches the pass-swerve before it breaks away.
            if tcOn and spd > tcMinMs then
                local slipCos = overtaking and otSlipCos or tcSlipCos
                local fv = GetEntityForwardVector(veh)
                local vv = GetEntityVelocity(veh)
                local vmag = math.sqrt(vv.x*vv.x + vv.y*vv.y + vv.z*vv.z)
                if vmag > 0.5 then
                    local dot = (fv.x*vv.x + fv.y*vv.y + fv.z*vv.z) / vmag
                    if dot < slipCos then
                        finalCruise = finalCruise * tcCut   -- throttle cut → regain traction
                        meta.tcSliding = true
                    else
                        meta.tcSliding = false
                    end
                end
            end

            -- COUNTER-STEER YAW DAMPER (v2.4.69 — user: "since we can't adjust how much
            -- the AI steers, can't we apply a COUNTER-steer force to offset the weird
            -- always-oversteer"). Oversteer = the car's YAW (spin about z) outrunning
            -- the direction it's actually travelling. We can't change the AI steering
            -- INPUT, but we CAN cancel the excess yaw directly: measure the slip angle
            -- (nose vs velocity) and, when the car is yawing INTO that slide past a
            -- threshold, scale down the z component of its angular velocity — a
            -- software counter-yaw / ESC. Uses SetEntityAngularVelocity ONLY (no drive
            -- task, no steering, no brake — the car keeps its intended line, it just
            -- can't over-rotate). Strength ramps with slip angle up to csGain. Grounded
            -- + above csMinMs only (normal low-speed / mid-corner yaw is left alone).
            if csOn and spd > csMinMs and not IsEntityInAir(veh)
               and (HasEntityCollidedWithAnything(veh) or IsVehicleOnAllWheels(veh)) then
                local fv = GetEntityForwardVector(veh)
                local vv = GetEntityVelocity(veh)
                local vmag = math.sqrt(vv.x*vv.x + vv.y*vv.y)   -- horizontal only
                if vmag > 0.5 then
                    -- slip angle between nose and horizontal travel direction (deg)
                    local dot = (fv.x*vv.x + fv.y*vv.y) / vmag
                    if dot > 1.0 then dot = 1.0 elseif dot < -1.0 then dot = -1.0 end
                    local slipDeg = math.deg(math.acos(dot))
                    if slipDeg > csSlipStart then
                        local av = GetEntityRotationVelocity(veh)   -- rad/s (pitch,roll,yaw=z)
                        if math.abs(av.z) > csYawMin then
                            -- sign check: only damp when the YAW is in the SAME rotational
                            -- sense as the slide (car spinning further into the slip), not
                            -- when it's already recovering. cross(fwd, vel).z < 0 ↔ nose is
                            -- to the LEFT of travel (car rotating right/CW = negative yaw);
                            -- damp only if av.z matches that sense.
                            local crossZ = fv.x*vv.y - fv.y*vv.x
                            local sameSense = (av.z * crossZ) < 0.0
                            if sameSense then
                                -- ramp 0 at csSlipStart → csGain at csMaxSlip
                                local f = (slipDeg - csSlipStart) / math.max(0.1, (csMaxSlip - csSlipStart))
                                if f > 1.0 then f = 1.0 end
                                local cut = csGain * f
                                SetEntityAngularVelocity(veh, av.x, av.y, av.z * (1.0 - cut))
                                meta.counterSteering = cut       -- debug tag (fraction removed)
                            else
                                meta.counterSteering = nil
                            end
                        else
                            meta.counterSteering = nil
                        end
                    else
                        meta.counterSteering = nil
                    end
                end
            else
                meta.counterSteering = nil
            end

            -- CORNER SPEED GOVERNOR (v2.4.39 — user: "reckless cars dive around a
            -- corner too fast and lose control; smooth the steering"). A real driver
            -- LIFTS before a bend; the AI just holds cruise and then has to yank the
            -- wheel mid-corner, which overspeeds the tyres and breaks away. We read
            -- the front-wheel steering angle (degrees; works for AI drivers), smooth
            -- it with a per-car EMA so the response is gradual not jerky, and ease
            -- the commanded cruise DOWN as the turn tightens: no cut below cornerDeg,
            -- ramping to a cornerMinFactor floor by cornerMaxDeg. Result: the car
            -- arrives at the corner already at a speed it can actually hold, so it
            -- doesn't need a violent steering correction = visibly smoother line.
            -- CORNER-APPROACH PRE-SLOW (v2.4.75 — user: "when an NPC wants to go into
            -- a corner make them slow too"). ANTICIPATION, not reaction: sample the
            -- road AHEAD and, if it bends, ease finalCruise down BEFORE the car gets
            -- there. Method: take a speed-scaled lookahead point along the car's
            -- CURRENT heading, ask GetVehicleNodeProperties for the road heading at
            -- that point, and compare to the car's heading — the delta is roughly how
            -- much the upcoming road turns. Throttled (node queries aren't free): we
            -- recompute the factor every caEveryMs and STORE it in meta.caFactor, then
            -- apply that stored factor to finalCruise EVERY tick so the pre-slow is
            -- smooth between samples. This runs BEFORE the reactive governor so the
            -- two compose: approach lifts off early, governor/scrub handle the apex.
            if caOn and spd > caMinMs then
                local tnow = nowMs()
                if not meta.caNext or tnow >= meta.caNext then
                    meta.caNext = tnow + caEveryMs
                    -- lookahead point: base + seconds-ahead × speed, along the FLAT
                    -- forward vector (ignore pitch so a crest doesn't skew the point).
                    local fv = GetEntityForwardVector(veh)
                    local flen = math.sqrt(fv.x*fv.x + fv.y*fv.y)
                    local caFac = 1.0
                    if flen > 0.01 then
                        local cpos = GetEntityCoords(veh)   -- recompute locally (scope-safe)
                        local look = caBaseM + spd * caTimeS
                        local lp = vector3(cpos.x + (fv.x/flen)*look,
                                           cpos.y + (fv.y/flen)*look, cpos.z)
                        -- 3rd return of GetVehicleNodeProperties is heading (deg) at node.
                        local nOk, _, nHeadingOrFlags = GetClosestVehicleNodeWithHeading(
                            lp.x, lp.y, lp.z, 1, 3.0, 0)
                        if nOk then
                            -- car heading (deg, 0..360) vs the node's road heading; take
                            -- the smallest signed difference (0..180).
                            local carH = GetEntityHeading(veh)
                            local roadH = nHeadingOrFlags or carH
                            local d = math.abs((carH - roadH + 180.0) % 360.0 - 180.0)
                            if d > caStartDeg then
                                local f = (d - caStartDeg) / math.max(0.1, (caMaxDeg - caStartDeg))
                                if f > 1.0 then f = 1.0 end
                                local floorFac = meta.reckless and caMinFacReck or caMinFac
                                caFac = 1.0 - (1.0 - floorFac) * f
                            end
                        end
                    end
                    meta.caFactor = caFac
                end
                -- apply the (possibly stale-by-<caEveryMs) approach factor every tick.
                if meta.caFactor and meta.caFactor < 1.0 then
                    finalCruise = finalCruise * meta.caFactor
                    meta.cornerApproaching = true
                else
                    meta.cornerApproaching = false
                end
            elseif meta.cornerApproaching then
                meta.cornerApproaching = false
                meta.caFactor = 1.0
            end

            if cornerOn and spd > cornerMinMs then
                local sa = math.abs(GetVehicleSteeringAngle(veh))   -- deg, unsigned
                -- EMA smoothing: blend toward the new reading so a single jittery
                -- frame doesn't spike the cut (and the release is gentle too).
                local prev = meta.steerEma or sa
                local ema  = prev + (sa - prev) * cornerEmaAlpha
                meta.steerEma = ema
                -- TIER-AWARE START ANGLE (v2.4.40 — "keep the safe bounce as the base
                -- feel, but let A/S/reckless stretch higher on clear straights"). The
                -- ~125↔140 bounce comes from highway lane-hold micro-steer (2-6°)
                -- tripping the governor. Give the FAST tiers a higher start angle so
                -- that gentle straight-line wobble no longer cuts them — they climb
                -- toward their real tier cap on clear road — while REAL corners (steer
                -- past their raised start) still govern them. Normal/base keep the low
                -- start = the loved safe band. cornerStartBonus[tier] is additive deg.
                local startDeg = cornerDeg + (cornerStartBonus[meta.tier or ''] or 0.0)
                if meta.reckless then startDeg = startDeg + cornerStartBonusReckless end
                if ema > startDeg then
                    local f = (ema - startDeg) / math.max(0.1, (cornerMaxDeg - startDeg))
                    if f > 1.0 then f = 1.0 end
                    -- reckless can carry a touch more (that's their character) but
                    -- still gets governed; everyone else eases harder.
                    local floorFac = meta.reckless and cornerMinFactorReckless or cornerMinFactor
                    local fac = 1.0 - (1.0 - floorFac) * f
                    finalCruise = finalCruise * fac
                    meta.cornering = true
                else
                    meta.cornering = false
                end
            elseif meta.steerEma then
                -- decay the smoothed angle toward 0 when the governor is idle so it
                -- doesn't re-engage stale on the next corner.
                meta.steerEma = meta.steerEma * (1.0 - cornerEmaAlpha)
                meta.cornering = false
            end

            -- RED-LIGHT / JUNCTION YIELD DETECT (v2.4.48 — user: "when they brake
            -- fast for a red light they mostly brake AFTER the line"). There's no
            -- cheap native to read a light's phase, but we don't need one: the
            -- native AI (non-reckless styles keep StopAtTrafficLights) already PLANS
            -- a stop for reds/junctions and eases off early. The bug was that our
            -- CURVE-BUST (SetEntityVelocity back up to finalCruise every tick) +
            -- elevated max-cruise kept SHOVING the car forward through that plan, so
            -- the stop only landed past the line. Tell-tale of a native yield on
            -- CLEAR road: the car is DECELERATING on its own while WE'RE commanding
            -- MORE speed, with no lead car, not cornering/sliding/overtaking, on
            -- near-flat ground (the pitch check drops uphill/crest speed loss). When
            -- we see it we STAND DOWN — clamp the target to current speed (kills the
            -- push + curve-bust) and shed the extra speed we made it carry with a
            -- soft straight-line brake so the native stop lands BEFORE the line.
            local yielding = false
            if ac.redLightYield ~= false and not hasLead and not overtaking
               and not meta.cornering and not meta.tcSliding
               and spd > kmhToMs(ac.redYieldMinKmh or 30.0)
               and spd < kmhToMs(ac.redYieldMaxKmh or 110.0) then  -- v2.4.63: OFF above the open-road band
                local prev = meta.prevSpd or spd
                local decelMs2 = (prev - spd) / math.max(0.001, dtSec)   -- + = slowing
                local commandingUp = finalCruise > spd + 0.5
                local rot = GetEntityRotation(veh)
                local flat = math.abs(rot.x) <= (ac.redYieldMaxPitch or cbMaxPitch)
                if commandingUp and flat and decelMs2 > (ac.redYieldDecelMs2 or 1.2) then
                    meta.yieldTicks = (meta.yieldTicks or 0) + 1
                else
                    meta.yieldTicks = 0
                end
                -- sustained a couple ticks so one crest bump doesn't trip it
                if (meta.yieldTicks or 0) >= (ac.redYieldTicks or 2) then
                    yielding = true
                end
            else
                meta.yieldTicks = 0
            end
            meta.prevSpd = spd          -- always fresh (even when the gate is closed)
            meta.yielding = yielding    -- surface to the /hktraffic overlay
            if yielding then
                if finalCruise > spd then finalCruise = spd end   -- stop pushing
                -- ACTIVE ASSIST (optional): a soft/hard STRAIGHT brake pulse so it
                -- sheds the extra speed the curve-bust made it carry, dead-straight
                -- (no swerve at the light). Same soft/hard-by-speed feel as the
                -- lead-car brake. Config-gated so it can be turned off independently.
                if ac.redYieldActiveBrake ~= false then
                    wantBrake = true
                    local act = (spd > hardMinMs2) and TA_BRAKE_HARD_STRAIGHT or TA_BRAKE_SOFT_STRAIGHT
                    local f = (spd - hardMinMs2) / math.max(0.1, (pulseMaxAt - hardMinMs2))
                    if f < 0.0 then f = 0.0 elseif f > 1.0 then f = 1.0 end
                    local ms = math.floor(pulseMinMs + (pulseMaxMs - pulseMinMs) * f)
                    TaskVehicleTempAction(meta.driver, veh, act, ms)
                end
            end

            -- STYLE: while OVERTAKING, use the swim-through style (swerve around
            -- vehicles) so the car pulls out and passes. Otherwise the v2.4.25 weave
            -- fix: a NON-RECKLESS car slowing for traffic (held or pulsing) uses the
            -- STRAIGHT-LINE brake style so it brakes dead straight instead of
            -- steering around the lead. Reckless keeps its swim-through style.
            local braking = held or wantBrake
            local wantStyle = meta.style or 262189
            if overtaking then
                wantStyle = otStyle
            elseif braking and not meta.reckless then
                wantStyle = (T.addon and T.addon.brakeStraightStyle) or 262291
            end

            -- STEERING TAME (user: "slidy/hard-steer with a car ahead"): the
            -- swim-through style yanks the wheel hard at speed = the slide. On the
            -- EDGE into an overtake, crank driver ability to max + aggression to 0
            -- so it steers smooth and anticipatory around the lead; restore on the
            -- edge back out. Edge-triggered (not every tick) so it's cheap.
            if overtaking and not meta.otTamed then
                SetDriverAbility(meta.driver, otAbility)
                SetDriverAggressiveness(meta.driver, otAggr)
                -- EXTRA GRIP for the pass (v2.4.32): temporarily pile more traction
                -- on top of the spawn grip floor so the lane-change swerve holds.
                -- Snapshot the pre-overtake values so exit restores exactly (these
                -- are already the boosted spawn values, not necessarily stock).
                if otGripBoost and otGripBoost ~= 1.0 then
                    local tmax = GetVehicleHandlingFloat(veh, 'CHandlingData', 'fTractionCurveMax')
                    local tmin = GetVehicleHandlingFloat(veh, 'CHandlingData', 'fTractionCurveMin')
                    meta.preOtTractionMax = tmax
                    meta.preOtTractionMin = tmin
                    if tmax and tmax > 0.0 then
                        SetVehicleHandlingFloat(veh, 'CHandlingData', 'fTractionCurveMax', tmax * otGripBoost)
                    end
                    if tmin and tmin > 0.0 then
                        SetVehicleHandlingFloat(veh, 'CHandlingData', 'fTractionCurveMin', tmin * otGripBoost)
                    end
                end
                meta.otTamed = true
            elseif not overtaking and meta.otTamed then
                SetDriverAbility(meta.driver, meta.baseAbility or 0.85)
                SetDriverAggressiveness(meta.driver, meta.baseAggr or 0.05)
                -- restore the pre-overtake grip (back to the spawn floor)
                if meta.preOtTractionMax then
                    SetVehicleHandlingFloat(veh, 'CHandlingData', 'fTractionCurveMax', meta.preOtTractionMax)
                    meta.preOtTractionMax = nil
                end
                if meta.preOtTractionMin then
                    SetVehicleHandlingFloat(veh, 'CHandlingData', 'fTractionCurveMin', meta.preOtTractionMin)
                    meta.preOtTractionMin = nil
                end
                meta.otTamed = false
            end

            local cbFired = false   -- (v2.4.64) did the curve-bust ratchet run this tick?
            if not wantBrake then
                SetDriveTaskCruiseSpeed(meta.driver, finalCruise)
                -- MAX cruise MUST track the target too, or the drive task's hidden
                -- ~34 m/s (~125 km/h) default clamps everything above it (the
                -- "capped at 125 even though debug shows higher" bug — and why
                -- horn-boost looked dead: the boosted target got re-clamped to 125).
                SetDriveTaskMaxCruiseSpeed(meta.driver, finalCruise + 5.0)
                SetDriveTaskDrivingStyle(meta.driver, wantStyle)

                -- CURVE-BUST (v2.4.30): the stock AI angle-curve pins the car at
                -- ~125 km/h the instant it micro-steers to hold its lane, and no
                -- cruise value beats that through the drive task (confirmed: caps at
                -- ~125 on an empty straight even after a full restart; the meta curve
                -- never loads). So on a CLEAR road, when the governed target is above
                -- the cap band but the car is pinned there and not climbing, nudge
                -- forward speed DIRECTLY toward the target. The accel governor still
                -- owns the rate (finalCruise already stepped by accelRate·dt), so
                -- this is smooth — it just routes around the engine ceiling. Only
                -- when NOT braking, NOT overtaking, and (if cbClearOnly) no lead car.
                if cbOn and not braking and not overtaking and not yielding
                   and finalCruise > cbAboveMs and spd > cbAboveMs
                   and (not cbClearOnly or not hasLead)
                   and spd < finalCruise - 0.5 then
                    -- SAFETY (v2.4.34): the old SetVehicleForwardSpeed pushed along
                    -- the car's forward vector, so a pitched-up nose (crest/bump/kerb)
                    -- sent the push UPWARD → the car launched. Now: only nudge when
                    -- grounded on all wheels and near-flat, and apply the speed-up in
                    -- the HORIZONTAL PLANE only, preserving the car's existing vertical
                    -- velocity (gravity) so we can never add upward speed.
                    local rot = GetEntityRotation(veh)   -- (pitch, roll, yaw) deg
                    local flatEnough = math.abs(rot.x) <= cbMaxPitch
                    local ok = flatEnough
                    if ok and cbGrounded and not IsEntityInAir(veh) then
                        ok = HasEntityCollidedWithAnything(veh) or IsVehicleOnAllWheels(veh)
                    elseif cbGrounded then
                        ok = false  -- airborne → never nudge
                    end
                    if ok then
                        local v = GetEntityVelocity(veh)
                        local hmag = math.sqrt(v.x*v.x + v.y*v.y)
                        if hmag > 0.5 then
                            -- RATCHETING TARGET (v2.4.64 — fixes "curated fleet won't
                            -- exceed ~150-160"). The OLD code set velocity to finalCruise,
                            -- which on a clear road is just (MEASURED spd + one accel
                            -- step). But the stock angle-curve drags ~that same amount
                            -- back out every 140ms tick, so target = dragged_spd + step
                            -- never advanced past its own drag → a tug-of-war plateau at
                            -- ~150. FIX: integrate the target from its OWN previous value
                            -- (meta.cbTarget), not from the dragged speed, so it climbs a
                            -- clean accelRate·dt EVERY tick regardless of drag; follow the
                            -- engine if it's genuinely faster; clamp to the tier cruise.
                            -- Then hard-SET velocity to it — the set forcibly overrides
                            -- the between-tick drag sag, so the car actually reaches its
                            -- real tier speed (265/320/380) instead of stalling at 150.
                            -- step = the CURVE-BUST rate (cbAccelMs·dt), NOT the full
                            -- accel governor rate. v2.4.66 (user: "accel rate too rapid")
                            -- — the high-speed ratchet now climbs on its own gentler knob
                            -- (curveBustAccelMs2 2.2) while the low-speed 0→118 pickup
                            -- keeps the brisk 4.5. Do NOT add `headroom` here — in the old
                            -- "measured spd + step" formula headroom was a one-shot buffer
                            -- that reset each tick, but in this ratchet it would ACCUMULATE
                            -- every tick and rocket the car.
                            local step  = cbAccelMs * dtSec
                            local prevT = meta.cbTarget or spd
                            if prevT < spd then prevT = spd end   -- engine already faster → follow it
                            local tgt = prevT + step
                            if tgt > fullCruise then tgt = fullCruise end
                            meta.cbTarget = tgt
                            local s = tgt / hmag
                            SetEntityVelocity(veh, v.x * s, v.y * s, v.z)
                            cbFired = true
                            meta.cbActive = true   -- surface to the /hktraffic 3D tag
                        end
                    end
                end
            end
            -- Not curve-busting this tick (braking, cornering, lead car, below the
            -- band, or wantBrake skipped the whole block): drop the ratchet so the
            -- NEXT engage starts fresh from the car's REAL speed — never a jump back
            -- up to a stale high target after a brake (that was the "suddenly fast").
            if not cbFired then meta.cbTarget = nil; meta.cbActive = false end

            -- STEER VELOCITY SCRUB (v2.4.67 — user: "the smooth velocity reduce didn't
            -- kick in. it should apply for cornering, TURNING and OVERTAKING too — in
            -- fact ANY steering input from the NPC should deduct VELOCITY, but must NOT
            -- use the brake; it needs to be a direct entity velocity slowdown").
            --
            -- v2.4.66 gated this on meta.cornering (set only by the corner GOVERNOR,
            -- which has high tier start-angles S+10/A+6 so it rarely tripped) AND on
            -- finalCruise<spd (only true when the governor itself cut) — so it almost
            -- never fired. REBUILT: read the RAW steering angle every tick, independent
            -- of the governor, and derive a target speed FACTOR straight from it —
            -- gentle past cScrubStart(4°), ramping to the cScrubMinF(0.45) floor by
            -- cScrubMaxD(22°). Then ease HORIZONTAL velocity toward spd×factor at
            -- cScrubRate m/s². This covers corners, plain turns, AND overtake lane-
            -- changes (all are steering input) with ZERO brake — pure velocity bleed.
            -- SAME safety as the curve-bust: grounded + near-flat + horizontal-only
            -- (keep z / gravity) + never airborne, so it can't slam down or launch.
            -- Gate the scrub OFF on any tick the curve-bust ratcheted (cbFired): that
            -- means we're on a CLEAR straight accelerating up and the only steering is
            -- lane-hold micro-steer — scrubbing there would fight the curve-bust and
            -- reintroduce the ~150 plateau. In a REAL corner the governor drops
            -- finalCruise below spd so curve-bust is already off (its gate needs
            -- spd<finalCruise), and during an overtake curve-bust is off too (its gate
            -- needs `not overtaking`) — so this gate never blocks a genuine steer.
            local scrubbing = false
            if cScrubOn and not cbFired and spd > cScrubMinMs and not IsEntityInAir(veh) then
                local sa = math.abs(GetVehicleSteeringAngle(veh))   -- deg, unsigned
                -- EMA smooth so a single jittery frame doesn't spike/drop the scrub.
                local prevE = meta.scrubEma or sa
                local ema   = prevE + (sa - prevE) * cScrubEma
                meta.scrubEma = ema
                if ema > cScrubStart then
                    local rot = GetEntityRotation(veh)
                    if math.abs(rot.x) <= cbMaxPitch
                       and (HasEntityCollidedWithAnything(veh) or IsVehicleOnAllWheels(veh)) then
                        -- 0 at cScrubStart → 1 at cScrubMaxD (clamped)
                        local f = (ema - cScrubStart) / math.max(0.1, (cScrubMaxD - cScrubStart))
                        if f > 1.0 then f = 1.0 end
                        local factor = 1.0 - (1.0 - cScrubMinF) * f   -- 1.0 → cScrubMinF
                        local v = GetEntityVelocity(veh)
                        local hmag = math.sqrt(v.x*v.x + v.y*v.y)
                        local targetH = hmag * factor
                        if hmag > 0.5 and hmag > targetH + 0.3 then
                            -- ease down toward targetH by at most cScrubRate·dt (never
                            -- below the target, never a hard snap).
                            local newH = hmag - cScrubRate * dtSec
                            if newH < targetH then newH = targetH end
                            local s = newH / hmag
                            SetEntityVelocity(veh, v.x * s, v.y * s, v.z)
                            scrubbing = true
                        end
                    end
                end
            elseif meta.scrubEma then
                meta.scrubEma = meta.scrubEma * (1.0 - cScrubEma)   -- decay when idle
            end
            meta.cornerScrubbing = scrubbing   -- /hktraffic tag + statebag below
            -- STATEBAG (user: "add a statebag to show on the debug"): replicate the
            -- live scrub state on the entity so the debug overlay (and any other
            -- client) can read whether this car is actively bleeding speed for a steer.
            if Entity(veh).state.hkscn_scrub ~= scrubbing then
                Entity(veh).state:set('hkscn_scrub', scrubbing, true)
            end

            -- OVERTAKE LATERAL PULL (v2.4.71 — user: "overtake shows OVERTAKE-L but the
            -- car never steered"). The pass used to only swap the AI driving STYLE and
            -- hope the swim-through wander drifted over — it didn't, and meta.overtakeSide
            -- was cosmetic (only fed the debug tag). Now we physically slide the car
            -- toward the clear side, the SAME way scrub/curve-bust drive speed: add a
            -- sideways velocity component along the car's RIGHT vector (signed by side),
            -- capped at otPullMaxMs, and STOP once we've eased ~one lane (otPullOff) off
            -- the line we started the burst on — so it moves out cleanly then holds,
            -- never drifts off the road. Same safety as the other velocity writes:
            -- grounded + near-flat + horizontal-only + never airborne.
            if otPullOn and overtaking and meta.overtakeSide and not IsEntityInAir(veh) then
                -- capture the origin line the first tick of a burst so we can measure
                -- how far we've slid (reset when the burst ends, below).
                if not meta.otPullStart then meta.otPullStart = vc end
                -- fwd is LOCAL to the brake-scan block above (out of scope here), so
                -- recompute it — reading the nil global would nil-crash the tick.
                local ofwd = GetEntityForwardVector(veh)
                local right = vector3(ofwd.y, -ofwd.x, 0.0)
                local d = vc - meta.otPullStart
                local slid = d.x * right.x + d.y * right.y          -- signed +R / -L (m)
                local dir  = (meta.overtakeSide == 'R') and 1.0 or -1.0
                -- how far we've moved in the DESIRED direction (dir·slid); pull until it
                -- reaches otPullOff. slid*dir < off → still need to move out.
                if slid * dir < otPullOff then
                    local rot = GetEntityRotation(veh)
                    if math.abs(rot.x) <= cbMaxPitch
                       and (HasEntityCollidedWithAnything(veh) or IsVehicleOnAllWheels(veh)) then
                        local v = GetEntityVelocity(veh)
                        -- current lateral speed along right (signed); add toward dir,
                        -- clamped so the slide stays smooth (never a teleport-yank).
                        local latV = v.x * right.x + v.y * right.y
                        local want = latV + dir * otPullMs2 * dtSec
                        if want >  otPullMaxMs then want =  otPullMaxMs end
                        if want < -otPullMaxMs then want = -otPullMaxMs end
                        local dLat = want - latV
                        SetEntityVelocity(veh, v.x + right.x * dLat, v.y + right.y * dLat, v.z)
                        meta.otPulling = true
                    else meta.otPulling = false end
                else meta.otPulling = false end
            else
                meta.otPullStart = nil
                meta.otPulling = false
            end

            -- HORN YIELD (v2.4.72 — user: "when I keep honking, the addon car in
            -- front doesn't accelerate a bit OR pull to the side for the player to
            -- overtake — should, if no car forward / side blocking"). The horn BOOST
            -- above already handles "accelerate a bit" (raises cruise+accel while the
            -- road ahead is clear). This adds the "pull to the side" half: while the
            -- NPC is horn-boosted AND NOT itself overtaking, if a side lane is clear
            -- (preferRight — vacate the fast/left lane so the player passes on the
            -- left), ease the car to that side with the SAME lateral pull the overtake
            -- uses. Bounded to ~one lane so it moves over then holds. If BOTH sides are
            -- blocked it just keeps the speed boost (nothing else it can safely do).
            local horning = hornYieldOn and boosted and not overtaking
                            and spd > hornYieldMinMs and not IsEntityInAir(veh)
            if horning then
                -- pick/refresh the yield side while honked (re-eval so it re-routes if
                -- a lane opens/closes mid-yield). preferRight = move to the slow lane.
                local yfwd = GetEntityForwardVector(veh)
                local yside = sideLaneClear(veh, vc, yfwd, nearVeh, nearCoord, nearN, ac, true)
                meta.hornYieldSide = yside
                if yside then
                    if not meta.hyPullStart then meta.hyPullStart = vc end
                    local right = vector3(yfwd.y, -yfwd.x, 0.0)
                    local d = vc - meta.hyPullStart
                    local slid = d.x * right.x + d.y * right.y
                    local dir  = (yside == 'R') and 1.0 or -1.0
                    if slid * dir < hornYieldOff then
                        local rot = GetEntityRotation(veh)
                        if math.abs(rot.x) <= cbMaxPitch
                           and (HasEntityCollidedWithAnything(veh) or IsVehicleOnAllWheels(veh)) then
                            local v = GetEntityVelocity(veh)
                            local latV = v.x * right.x + v.y * right.y
                            local want = latV + dir * hornYieldMs2 * dtSec
                            if want >  hornYieldMaxMs then want =  hornYieldMaxMs end
                            if want < -hornYieldMaxMs then want = -hornYieldMaxMs end
                            local dLat = want - latV
                            SetEntityVelocity(veh, v.x + right.x * dLat, v.y + right.y * dLat, v.z)
                            meta.hornYielding = true
                        else meta.hornYielding = false end
                    else meta.hornYielding = false end
                else meta.hornYielding = false end
            else
                meta.hyPullStart = nil
                meta.hornYielding = false
                meta.hornYieldSide = nil
            end

            -- SURFACE MAGNET (v2.4.34): a gentle downward pull so fast addon cars
            -- settle onto the road instead of getting light/skippy over crests. Kept
            -- DELIBERATELY WEAK (user: "don't be harsh on stick-to-surface, it fucks
            -- up") and NEVER applied airborne (that would slam it down) — we only
            -- bias the vertical velocity slightly negative while it's grounded+fast.
            if stickOn and stickAccel > 0.0 and spd > stickMinMs
               and not IsEntityInAir(veh)
               and (HasEntityCollidedWithAnything(veh) or IsVehicleOnAllWheels(veh)) then
                local v = GetEntityVelocity(veh)
                SetEntityVelocity(veh, v.x, v.y, v.z - stickAccel * dtSec)
            end

            -- FALLING EDGE for the foot-brake temp action: TaskVehicleTempAction
            -- REPLACES the wander task for its duration and does NOT auto-restore,
            -- so the frame we stop pulsing we must re-issue the drive task at the
            -- current governed target (else it coasts taskless ~2s).
            if meta.braking and not wantBrake then
                TaskVehicleDriveWander(meta.driver, veh, finalCruise, wantStyle)
                SetDriveTaskDrivingStyle(meta.driver, wantStyle)
                SetDriveTaskCruiseSpeed(meta.driver, finalCruise)
                SetDriveTaskMaxCruiseSpeed(meta.driver, finalCruise + 5.0)
            end
            meta.braking = wantBrake
            meta.brakeCruiseHeld = held
            meta.heldCruiseMs = held and brakeTarget or nil
        end
    end
end

-- dedicated addon-drive loop (accel governor + brake assist). Needs to be more
-- responsive than the 2-3s spawn loop. Cheap: only iterates our own spawned addon
-- set, and only while traffic + spawner are on. Runs the accel governor even if
-- brake assist is disabled (the governor is the throttle limiter, separate switch).
CreateThread(function()
    local tickMs = (T.addon or {}).brakeTickMs or 120
    local dtSec = tickMs / 1000.0
    while true do
        if S and S.enabled and S.spawnerOn then
            addonDriveTick(dtSec)
            Wait(tickMs)
        else
            Wait(1000)
        end
    end
end)

-- ── HORN BOOST (per user: "npc getting horned at will drive faster") ────────
-- When the local player honks while in a vehicle, any of OUR spawned addon NPCs
-- within hornRange gets its hornBoostUntil stamped — the drive tick then raises
-- that NPC's cruise target + accel until the stamp expires (Wangan "move over /
-- race me" feel). Cheap: only polls while the player is honking, only tags our
-- own tracked set (no pool scan). Uses the pre-filtered nothing — just iterates
-- `spawned` (small). IsHornActive(ped) is the standard CFX native.
CreateThread(function()
    while true do
        local ac = T.addon or {}
        if S and S.enabled and S.spawnerOn and ac.hornBoost ~= false then
            local ped = PlayerPedId()
            local veh = GetVehiclePedIsIn(ped, false)
            -- IsHornActive takes a VEHICLE handle, NOT a ped (was passing the ped —
            -- one reason horn-boost never fired). The other reason was the max-cruise
            -- clamp: the boosted target got re-clamped to ~125; fixed in addonDriveTick.
            if veh ~= 0 and IsHornActive(veh) then
                local pc   = GetEntityCoords(veh)
                local pfwd = GetEntityForwardVector(veh)
                local range = ac.hornRange or 30.0
                -- only honk-tag the car(s) DIRECTLY AHEAD of the player (the one
                -- being honked at), NOT every car in range. v2.4.72 — the old code
                -- boosted side/behind cars too, and only ever sped them up (never
                -- moved them aside). We stamp hornBoostUntil + the player's line so
                -- the drive tick can decide: accelerate if the road ahead is clear,
                -- else pull to a free side lane so the player gets past.
                local aheadMin = ac.hornAheadDot or 0.30   -- min forward-dot to count as "in front"
                local until_ = nowMs() + (ac.hornBoostMs or 3500)
                for sveh, meta in pairs(spawned) do
                    if meta.addon and DoesEntityExist(sveh) and sveh ~= veh then
                        local to = GetEntityCoords(sveh) - pc
                        local dist = #(to)
                        if dist < range and dist > 0.1 then
                            local dot = (to.x * pfwd.x + to.y * pfwd.y) / dist  -- +1 = straight ahead
                            if dot >= aheadMin then
                                meta.hornBoostUntil = until_
                                meta.hornedByPos = pc      -- player line for the yield decision
                                meta.hornedByFwd = pfwd
                            end
                        end
                    end
                end
                Wait(200)   -- while honking, re-stamp a few times/sec
            else
                Wait(250)
            end
        else
            Wait(1000)
        end
    end
end)

local lastPlayerPos = nil
local afkSince = 0
CreateThread(function()
    while true do
        local sp = T.spawner or {}
        if not (S and S.enabled and S.spawnerOn) then
            Wait(2000)
        elseif optimizerBlocksSpawner() then
            Wait(3000)
        else
            -- RECONCILE first (v2.4.51): re-derive the live counts from the actual
            -- `spawned` table so a drifted tally can never wedge the cap. Cheap (one
            -- pass over our own small fleet) and self-healing — no restart needed.
            dbgCountDrift = reconcileCounts()
            -- culling ALWAYS runs (so the fleet can drain as cars move off), but
            -- spawn ATTEMPTS are gated with adaptive backoff below.
            cullSpawned(sp)
            reassertSpeeds()

            local ped = PlayerPedId()
            local pv  = GetVehiclePedIsIn(ped, false)
            local refEnt = (pv ~= 0) and pv or ped
            local t = nowMs()
            local pc = GetEntityCoords(ped)

            -- AFK / idle detection: if the player barely moves, there's no point
            -- attempting a spawn every second — the fleet near a stationary player
            -- stays put (nothing drives off to be culled), so every attempt just
            -- bails 'cap'. That's exactly the "8000 attempts / 1700 ok" waste you
            -- saw while AFK. When idle, we throttle attempts HARD; the moment you
            -- start moving again it snaps back to normal cadence.
            local moved = lastPlayerPos and #(pc - lastPlayerPos) or 999.0
            lastPlayerPos = pc
            if moved < (sp.afkMoveThreshold or 4.0) then
                if afkSince == 0 then afkSince = t end
            else
                afkSince = 0
            end
            local idleMs = afkSince > 0 and (t - afkSince) or 0
            local afk = idleMs > (sp.afkAfterMs or 6000)

            -- Effective cooldown between attempts (v2.4.64 — user cadence spec):
            --  • capped fleet → capBackoffMs (6s: fleet full, just re-check slowly)
            --  • AFK          → afkBackoffMs (20s: player parked, barely top up)
            --  • normal + a car SPAWNED last try → spawnOkCooldownMs (8s: steady drip)
            --  • normal + last try FAILED to spawn → spawnFailCooldownMs (4s: retry sooner)
            -- `lastSpawnOk` carries the previous attempt's outcome across loop turns.
            local cap = fleetTotalCap()
            local cd
            if spawnedCount >= cap then
                cd = (sp.capBackoffMs or 6000)
            elseif afk then
                cd = (sp.afkBackoffMs or 20000)
            elseif lastSpawnOk then
                cd = (sp.spawnOkCooldownMs or 8000)
            else
                cd = (sp.spawnFailCooldownMs or 4000)
            end

            if (t - lastSpawnAttempt) >= cd then
                lastSpawnAttempt = t
                -- skip the attempt entirely when already capped — cull already ran
                -- this loop, so this just avoids a guaranteed 'cap' bail + its work.
                if spawnedCount < cap then
                    -- true only when a car was actually created + seated + tracked;
                    -- any bail returns nil → next normal wait is the shorter retry.
                    lastSpawnOk = trySpawnHighwayCar(sp, refEnt) == true
                end
            end
            -- loop faster when active (responsive top-ups), slower when idle.
            Wait(afk and 1000 or 500)
        end
    end
end)

-- ══════════════════════════════════════════════════════════════════════════
-- PARKED-CAR REPLACEMENT (v2.4.52 — user: "detect the QB/base parked vehicles
-- and, when no player's looking or too near, replace them with addon vehicles").
-- ──────────────────────────────────────────────────────────────────────────
-- The 2026-08-26 removal killed the approach that CREATED parked cars (they
-- snapped to road-center nodes → read as stuck). This does the SAFE opposite:
-- the game already spawns ambient parked cars in REAL parking spots (kerbs,
-- driveways, lots) — always empty, correctly placed. We just swap the MODEL in
-- place: same coords, same heading, off-screen, left PARKED (no driver, no drive
-- task). No node snapping, no stuck cars — our curated fleet becomes the scenery.
--
-- Swapped cars are tracked in `parkedSwapped` (separate from `spawned`, which is
-- the DRIVING fleet — these never get the drive tick / brake / cull-for-stuck).
local parkedSwapped = {}      -- [entity] = { born, model, tier }
local parkedSwapCount = 0
local parkedTried = {}        -- [entity] = true  (don't reconsider a car we skipped)
local dbgParkedSwaps = 0      -- surfaced on the /hktraffic overlay

-- Is this ambient vehicle a genuine EMPTY PARKED car we may replace? Rejects:
--   protected (player/hk-parking/train/mission/scenario prop — via main.lua),
--   our own spawned driving car or an already-swapped one, anything with a ped
--   in ANY seat, anything actually moving, and cop/emergency class.
local function isSwappableParked(veh, sp)
    if not DoesEntityExist(veh) then return false end
    if spawned[veh] or parkedSwapped[veh] or parkedTried[veh] then return false end
    -- v2.4.58 — REPLICATED marker: a car ANOTHER client already swapped carries the
    -- statebag `hkscn_parked` (set replicated at creation). Without this, every other
    -- client sees our networked, driverless, stationary replacement as a fresh
    -- swappable parked car and re-swaps it forever. Skip anything already ours.
    local st = Entity(veh).state
    if st and st.hkscn_parked then return false end
    -- honour the SAME single-source protection the clear engine uses (hk-parking
    -- parked cars, player cars, trains, mission entities, our props, stream grace).
    if Scn_isTrafficProtected and Scn_isTrafficProtected(veh) then return false end
    if IsEntityAMissionEntity(veh) then return false end       -- owned by another script
    if GetVehicleClass(veh) == 18 then return false end        -- emergency
    if GetVehicleClass(veh) == 21 then return false end        -- trains/trams
    -- must be EMPTY — any occupant (driver or passenger, player or ped) → skip.
    local maxSeats = GetVehicleMaxNumberOfPassengers(veh)
    for seat = -1, maxSeats - 1 do
        if GetPedInVehicleSeat(veh, seat) ~= 0 then return false end
    end
    -- must be stationary (a genuinely parked car), not one rolling/being driven.
    if GetEntitySpeed(veh) > (sp.parkedMoveEps or 0.35) then return false end
    return true
end

-- Do the in-place swap: capture the parked car's transform, delete it, and drop
-- our addon model onto the exact spot facing the same way — stationary, doors
-- shut, engine off, no driver. Returns true on a successful swap.
local function swapParkedCar(veh, sp)
    local pos     = GetEntityCoords(veh)
    local heading = GetEntityHeading(veh)

    -- v2.4.58 — NETWORK-CONTROL MUTEX. The original ambient car is a networked
    -- OneSync entity shared by all clients. Before we delete it we must OWN it, and
    -- winning control also serves as the race guard: if two nearby clients both try
    -- to swap the same car, only the one that gets control proceeds — the other's
    -- request fails and it bails (no double-create). Give up quickly if we can't get
    -- control (someone else is mid-swap or owns it) and just skip this car.
    if NetworkGetEntityIsNetworked(veh) then
        local tries = 0
        while not NetworkHasControlOfEntity(veh) and tries < 12 do
            NetworkRequestControlOfEntity(veh)
            Wait(15); tries = tries + 1
        end
        if not NetworkHasControlOfEntity(veh) then
            parkedTried[veh] = true   -- don't hammer a car we can't control
            return false
        end
    end

    -- pick a curated addon model (tier deck), same source the driving fleet uses.
    local modelName, tier = pickAddonByTier()
    if not modelName then return false end
    local hash = loadModel(modelName)
    if not hash then return false end

    -- remove the original ambient parked car (we now have control + mission-flag so
    -- the engine lets go, mirroring deleteEntitySafe in main.lua).
    SetEntityAsMissionEntity(veh, true, true)
    DeleteVehicle(veh)

    -- NETWORKED (isNetwork=true) so EVERY player sees the SAME replacement car at
    -- this spot (v2.4.58 fix for the parked-swap desync: the old isNetwork=false
    -- made a client-local car only the swapper could see, so others still saw their
    -- own ambient car / nothing → hard desync). mission-flagged so the population
    -- manager won't cull it out from under us.
    local nv = CreateVehicle(hash, pos.x, pos.y, pos.z, heading, true, false)
    SetModelAsNoLongerNeeded(hash)
    if nv == 0 or not DoesEntityExist(nv) then deckBurn(modelName); return false end
    -- v2.4.53 — emergency class guard removed here too (roster blacklist + name
    -- filter already exclude cop/emergency models); deckBurn on the create-fail
    -- path keeps a bad model from wedging the deck.
    SetEntityAsMissionEntity(nv, true, true)
    -- REPLICATED marker so all other clients recognise this as OUR swapped parked
    -- car and never re-swap it (see isSwappableParked). Replicated = the bag rides
    -- the entity to everyone, not just us.
    Entity(nv).state:set('hkscn_parked', true, true)
    -- PARKED PRESENTATION: sit it exactly on the ground at the captured spot,
    -- engine off, brake on, no task — it must stay put like a real parked car.
    SetVehicleOnGroundProperly(nv)
    SetEntityHeading(nv, heading)
    SetVehicleEngineOn(nv, false, true, true)
    SetVehicleHandbrake(nv, true)
    SetVehicleDoorsShut(nv, true)
    FreezeEntityPosition(nv, true)          -- rock-solid parked; unfrozen if jacked
    SetVehicleDirtLevel(nv, math.random(2, 15) * 0.1)
    -- WINDOW TINT (v2.4.76): parked-swap addon cars get the same tint treatment as
    -- the driving fleet so the whole curated fleet reads consistently tinted.
    if (T.addon or {}).forceWindowTint ~= false then
        local tints = (T.addon or {}).windowTints or { 1, 2, 3 }
        if #tints > 0 then SetVehicleWindowTint(nv, tints[math.random(#tints)]) end
    end
    -- qb-format plate so it reads like a real car (same gen as the driving fleet).
    SetVehicleNumberPlateText(nv, ('%d%s%03d%s'):format(
        math.random(0, 9),
        string.char(math.random(65, 90), math.random(65, 90)),
        math.random(0, 999),
        string.char(math.random(65, 90), math.random(65, 90))))

    -- v2.4.59 — capture the NETWORK ID so deletion can go SERVER-AUTHORITATIVE.
    -- A client-created networked vehicle CANNOT be reliably deleted client-side once
    -- ownership migrates (forceMigration) or the creator streams out — DeleteVehicle
    -- silently no-ops on an entity we don't control and the car leaks forever (the
    -- "swapped vehicle doesn't get deleted" bug). The server owns every net entity,
    -- so we hand it the netId and let the server delete it authoritatively.
    local netId = NetworkGetNetworkIdFromEntity(nv)
    parkedSwapped[nv] = { born = nowMs(), model = modelName, tier = tier, netId = netId }
    parkedSwapCount = parkedSwapCount + 1
    dbgParkedSwaps = dbgParkedSwaps + 1
    deckNote(modelName)                     -- count it toward the spawn-diversity deck
    return true
end

-- any PLAYER in any seat (parked cars start empty, so this is only true once
-- someone climbs in — our cue to unfreeze + release the car back to normal).
local function vehicleHasPlayerLocal(veh)
    local maxSeats = GetVehicleMaxNumberOfPassengers(veh)
    for seat = -1, maxSeats - 1 do
        local ped = GetPedInVehicleSeat(veh, seat)
        if ped ~= 0 and IsPedAPlayer(ped) then return true end
    end
    return false
end

-- Cull swapped parked cars that drifted far / got jacked (a player took the seat),
-- and reconcile the count from the live table (same self-heal idea as v2.4.51).
local function cullParkedSwapped(sp)
    local pc = GetEntityCoords(PlayerPedId())
    local live = 0
    for veh, meta in pairs(parkedSwapped) do
        local drop = false
        if not DoesEntityExist(veh) then
            drop = true
        else
            -- a player got in → hand it over: unfreeze, release our claim, untrack.
            if vehicleHasPlayerLocal(veh) then
                FreezeEntityPosition(veh, false)
                SetEntityAsMissionEntity(veh, false, false)
                SetVehicleHasBeenOwnedByPlayer(veh, true)
                drop = true
            elseif #(GetEntityCoords(veh) - pc) > (sp.hardCullDistance or 550.0)
                   and not IsEntityOnScreen(veh) then
                -- far away + unseen → delete so the pool can recycle it.
                -- v2.4.59 — SERVER-AUTHORITATIVE delete. Client-side DeleteVehicle
                -- on a networked car we no longer control (forceMigration moved it,
                -- or we streamed out) silently no-ops → the car leaked forever. So:
                -- try the local fast-path IF we still control it, otherwise hand the
                -- netId to the server which owns every net entity and can always
                -- delete it. We keep the car TRACKED until DoesEntityExist reports
                -- gone (next cull pass) so a failed delete never orphans an untracked
                -- car — no more phantom leaks.
                local gone = false
                if NetworkGetEntityIsNetworked(veh) then
                    if NetworkHasControlOfEntity(veh) then
                        SetEntityAsMissionEntity(veh, true, true)
                        DeleteVehicle(veh)
                        gone = not DoesEntityExist(veh)
                    end
                    if not gone then
                        local netId = meta.netId or NetworkGetNetworkIdFromEntity(veh)
                        if netId and netId ~= 0 then
                            TriggerServerEvent('hk-scenario:traffic:deleteNet', netId)
                        end
                        -- leave tracked; it'll DoesEntityExist=false on a later pass.
                    end
                else
                    -- non-networked (shouldn't happen post-v2.4.58) → local delete.
                    SetEntityAsMissionEntity(veh, true, true)
                    DeleteVehicle(veh)
                    gone = not DoesEntityExist(veh)
                end
                if gone then drop = true end
            end
        end
        if drop then
            parkedSwapped[veh] = nil
        else
            live = live + 1
        end
    end
    parkedSwapCount = live
end

CreateThread(function()
    while true do
        local sp = T.spawner or {}
        if not (S and S.enabled and S.spawnerOn) or sp.parkedSwap == false then
            Wait(2500)
        elseif optimizerBlocksSpawner() then
            Wait(3000)
        else
            cullParkedSwapped(sp)
            local pc = GetEntityCoords(PlayerPedId())
            local nearMin = sp.parkedNearMin or 60.0
            local scanMax = sp.parkedScanMax or 240.0
            local capAlive = sp.parkedMaxAlive or 30
            local perPass = sp.parkedSwapPerPass or 2
            local chance = sp.parkedSwapChance or 0.5
            if parkedSwapCount < capAlive then
                local pool = GetGamePool('CVehicle')
                local done = 0
                for i = 1, #pool do
                    if done >= perPass then break end
                    local veh = pool[i]
                    if isSwappableParked(veh, sp) then
                        local vpos = GetEntityCoords(veh)
                        local d = #(vpos - pc)
                        -- eligibility: within scan range, past the near bubble, and
                        -- OFF-SCREEN (or far enough that the swap can't be seen) so
                        -- the model never visibly pops. In a scenario no-traffic zone
                        -- we skip (leave the pool to the clear engine).
                        if d > nearMin and d < scanMax
                           and not IsEntityOnScreen(veh)
                           and not inBlockedScnZone(vpos.x, vpos.y, vpos.z, 0.0) then
                            if math.random() < chance then
                                if swapParkedCar(veh, sp) then done = done + 1 end
                            else
                                parkedTried[veh] = true   -- don't re-roll it constantly
                            end
                        end
                    end
                end
            end
            -- prune stale parkedTried handles so it can't grow unbounded
            for ent in pairs(parkedTried) do
                if not DoesEntityExist(ent) then parkedTried[ent] = nil end
            end
            Wait(sp.parkedSwapEveryMs or 1500)
        end
    end
end)

-- ══════════════════════════════════════════════════════════════════════════
-- STUCK-CAR ROAD SWEEP (v2.4.60) — delete genuinely wedged AMBIENT cars that the
-- engine abandoned in the middle of a driving lane (empty, dead-stopped, no zone
-- needed). This is the "random car stuck in the road" cleanup the user asked for,
-- reusing the same protection guard + server-authoritative delete as everything
-- else so it NEVER nukes player cars, hk-parking cars, our spawns/swaps, trains,
-- or mission entities.
-- ──────────────────────────────────────────────────────────────────────────
local stuckSince = {}        -- [entity] = first time we saw it empty+stopped
local dbgStuckSwept = 0

-- server-authoritative delete of any ambient car by netId (mirrors the parked-swap
-- cull path): try local delete if we control it, else hand the netId to the server.
local function deleteAmbientSafe(veh)
    if NetworkGetEntityIsNetworked(veh) then
        if NetworkHasControlOfEntity(veh) then
            SetEntityAsMissionEntity(veh, true, true)
            DeleteVehicle(veh)
        end
        if DoesEntityExist(veh) then
            local netId = NetworkGetNetworkIdFromEntity(veh)
            if netId and netId ~= 0 then
                TriggerServerEvent('hk-scenario:traffic:deleteNet', netId)
            end
        end
    else
        SetEntityAsMissionEntity(veh, true, true)
        DeleteVehicle(veh)
    end
end

local function stuckSweepPass(sp)
    local pc = GetEntityCoords(PlayerPedId())
    local radius  = sp.stuckSweepRadius or 140.0
    local nearMin = sp.stuckSweepNearMin or 25.0
    local moveEps = sp.stuckMoveEps or 0.30
    local forMs   = sp.stuckForMs or 7000
    local perPass = sp.stuckSweepPerPass or 3
    local needOff = sp.stuckRequireOffscreen ~= false
    local now = nowMs()
    local pool = GetGamePool('CVehicle')
    local done = 0
    for i = 1, #pool do
        local veh = pool[i]
        local track = false
        local st = DoesEntityExist(veh) and Entity(veh).state or nil
        if DoesEntityExist(veh)
           and not spawned[veh] and not parkedSwapped[veh]
           and not (st and st.hkscn_parked)             -- v2.4.62: never sweep ANOTHER client's swapped car
           -- must be EMPTY (any occupant → it's someone's active car, leave it)
           and not vehicleHasPlayerLocal(veh)
           and GetPedInVehicleSeat(veh, -1) == 0        -- no driver at all (ambient wedge)
           and not protectedVeh(veh)                    -- player/parking/our-fleet/train/mission
           and GetEntitySpeed(veh) <= moveEps then
            local vpos = GetEntityCoords(veh)
            local d = #(vpos - pc)
            if d > nearMin and d <= radius then
                track = true
                -- accumulate stuck time; delete once it's been wedged long enough.
                local since = stuckSince[veh]
                if not since then
                    stuckSince[veh] = now
                elseif (now - since) >= forMs then
                    if (not needOff or not IsEntityOnScreen(veh)) and done < perPass then
                        deleteAmbientSafe(veh)
                        stuckSince[veh] = nil
                        dbgStuckSwept = dbgStuckSwept + 1
                        done = done + 1
                    end
                end
            end
        end
        -- any car that moved / got occupied / left range → forget its stuck timer
        if not track and stuckSince[veh] then stuckSince[veh] = nil end
    end
    -- prune dead handles
    for ent in pairs(stuckSince) do
        if not DoesEntityExist(ent) then stuckSince[ent] = nil end
    end
end

CreateThread(function()
    while true do
        local sp = T.spawner or {}
        if not (S and S.enabled) or sp.stuckSweep == false then
            Wait(3000)
        elseif optimizerBlocksSpawner() then
            Wait(3000)
        else
            stuckSweepPass(sp)
            Wait(sp.stuckSweepEveryMs or 4000)
        end
    end
end)

-- ══════════════════════════════════════════════════════════════════════════
-- DEBUG OVERLAY — /hktraffic  (see where our cars are + full live status)
-- ──────────────────────────────────────────────────────────────────────────
-- Purpose: the spawner is invisible by design (cars spawn off-screen), so it's
-- impossible to tell if it's working or WHAT it put where. This overlay makes
-- everything the module tracks visible on demand:
--   • MAP BLIPS on every car WE spawned, coloured by tier (S=gold, A=red,
--     B=green, base=grey), reckless = flashing. So you can open the map and
--     see the whole spawned fleet + drive to any of them.
--   • 3D FLOATING TAGS above each spawned car within range: model name, tier,
--     persona, target vs actual km/h, and status (OK / STUCK / re-kicking).
--   • HUD PANEL top-left: preset, biome, spawner gate, live counts (total /
--     addons / cap), per-tier alive tally, addonChance, and the current
--     player speed vs the spawn threshold (so you know why it is / isn't
--     spawning right now).
-- Toggle: /hktraffic  (also /trafficdbg). Purely local & cosmetic — no effect
-- on the sim; safe to leave off. Blips self-clean when a car is culled.
local dbgOn = false
local tierBlipColor = { S = 46, A = 1, B = 25 }   -- gold / red / green (GTA blip palette)

local function tierLabel(meta)
    if not meta.addon then return 'BASE' end
    return (meta.tier or '?') .. (meta.reckless and ' ‼' or '')
end

-- attach a map blip to a spawned car (called lazily while debug is on)
local function ensureBlip(veh, meta)
    if meta.blip and DoesBlipExist(meta.blip) then return end
    local b = AddBlipForEntity(veh)
    SetBlipSprite(b, meta.addon and 225 or 1)   -- 225 = "personal vehicle" car icon
    SetBlipScale(b, meta.addon and 0.85 or 0.6)
    SetBlipColour(b, meta.addon and (tierBlipColor[meta.tier] or 4) or 40)  -- grey for base
    SetBlipAsShortRange(b, true)
    if meta.reckless then SetBlipFlashes(b, true) end
    local nm = ('%s [%s]'):format(meta.model or '?', tierLabel(meta))
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName(nm)
    EndTextCommandSetBlipName(b)
    meta.blip = b
end

local function removeBlip(meta)
    if meta and meta.blip and DoesBlipExist(meta.blip) then RemoveBlip(meta.blip) end
    if meta then meta.blip = nil end
end

RegisterCommand('hktraffic', function()
    dbgOn = not dbgOn
    if not dbgOn then
        for _, meta in pairs(spawned) do removeBlip(meta) end
    end
    local msg = dbgOn and '~g~ON~s~ — blips, 3D tags & status panel active'
                       or  '~r~OFF~s~'
    BeginTextCommandThefeedPost('STRING')
    AddTextComponentSubstringPlayerName('[hk-traffic] debug overlay ' .. msg)
    EndTextCommandThefeedPostTicker(false, true)
end, false)
RegisterCommand('trafficdbg', function() ExecuteCommand('hktraffic') end, false)

-- ── /settraffic — live per-biome tuning ─────────────────────────────────────
-- Set the speed multiplier / density / open-road flag for a region on the fly,
-- no config edit or redeploy. Applies to the zone you're STANDING IN by default,
-- or a named zone code.  Usage:
--   /settraffic <speedMult> [densityMult] [open|closed]   → current zone
--   /settraffic zone <CODE> <speedMult> [densityMult] [open|closed]
--   /settraffic show                → print current zone's effective profile
--   /settraffic clear [CODE|all]    → drop override(s), revert to config
-- e.g.  /settraffic 1.6 1.0 open     (make here fast + open-road)
--       /settraffic zone SANDY 1.8
local function notify(msg)
    BeginTextCommandThefeedPost('STRING')
    AddTextComponentSubstringPlayerName('[hk-traffic] ' .. msg)
    EndTextCommandThefeedPostTicker(false, true)
end

-- ── /settraffic — dead-simple per-biome speed rate ──────────────────────────
-- Applies to the zone you're STANDING IN. Only knob is the speed multiplier.
--   /settraffic          → show the current biome + its rate
--   /settraffic 1.5      → set THIS biome to 1.5×, saved to DB, live for everyone
--   /settraffic clear    → remove this biome's override (back to config default)
--   /settraffic list     → list every saved biome override (from the synced table)
RegisterCommand('settraffic', function(_, args)
    local hc = GetEntityCoords(PlayerPedId())
    local zone = (curBiomeName or GetNameOfZone(hc.x, hc.y, hc.z) or ''):upper()
    local a1 = (args[1] or ''):lower()

    -- no arg → show current biome + rate
    if a1 == '' then
        local p = curBiome or {}
        local overridden = biomeOverrides[zone] and ' ~o~(override)~s~' or ''
        notify(('biome ~b~%s~s~ — rate ~y~%.2fx~s~%s'):format(
            zone ~= '' and zone or '?', p.speedMult or 1.0, overridden))
        notify('~y~/settraffic 1.5~s~ set  ~y~/settraffic clear~s~ reset  ~y~/settraffic list~s~ show all')
        return
    end

    -- list every saved override (biomeOverrides is kept in sync by biomeSync)
    if a1 == 'list' then
        local rows = {}
        for z, ov in pairs(biomeOverrides) do
            rows[#rows + 1] = { z = z, sm = ov.speedMult or 1.0 }
        end
        if #rows == 0 then
            notify('~o~no biome overrides saved~s~ (all zones on config default)')
            return
        end
        table.sort(rows, function(a, b) return a.z < b.z end)
        notify(('~b~── %d biome override(s) ──'):format(#rows))
        for _, r in ipairs(rows) do
            local hereTag = (r.z == zone) and ' ~g~◄ here' or ''
            notify(('~b~%s~s~  ~y~%.2fx~s~%s'):format(r.z, r.sm, hereTag))
        end
        return
    end

    -- clear this biome's override
    if a1 == 'clear' then
        lib.callback('hk-scenario:traffic:clearBiome', false, function(ok)
            notify(ok and (('~g~cleared ~b~%s~s~ (back to config default)'):format(zone))
                       or  '~r~not allowed / failed')
        end, zone)
        return
    end

    -- otherwise: set the rate
    local sm = tonumber(a1)
    if not sm then notify('~r~usage: /settraffic 1.5   (or just /settraffic to view)'); return end
    sm = math.max(0.1, math.min(5.0, sm))
    -- server persists + broadcasts back (biomeSync updates our table + re-resolves)
    lib.callback('hk-scenario:traffic:setBiome', false, function(ok)
        notify(ok and (('~g~saved ~b~%s~s~ → rate ~y~%.2fx'):format(zone, sm))
                   or  '~r~not allowed / failed to save (are you admin?)')
    end, zone, { speedMult = sm })
end, false)

-- ── /trafficblacklist — ban a car model from ever spawning as NPC traffic ────
-- Server-persisted (hk_scenario_meta) + broadcast to everyone, survives restart.
--   /trafficblacklist               → blacklist the car you're currently driving
--   /trafficblacklist adder         → blacklist model 'adder' by name
--   /trafficblacklist list          → show the runtime blacklist
--   /trafficblacklist remove adder  → un-blacklist 'adder'
--   /trafficblacklist clear         → wipe the whole runtime blacklist

-- Resolve a vehicle model hash back to its spawn-name string. Prefer the
-- qb-core roster (authoritative for addons); fall back to the game's own
-- display name (correct for base GTA models).
local function modelNameFromHash(hash)
    if QBShared and type(QBShared.Vehicles) == 'table' then
        for model in pairs(QBShared.Vehicles) do
            if joaat(model) == hash then return tostring(model):lower() end
        end
    end
    local dn = GetDisplayNameFromVehicleModel(hash)
    if dn and dn ~= '' and dn:upper() ~= 'CARNOTFOUND' and dn:upper() ~= 'NULL' then
        return tostring(dn):lower()
    end
    return nil
end

RegisterCommand('trafficblacklist', function(_, args)
    local a1 = (args[1] or ''):lower()

    -- list the current runtime blacklist (synced from server)
    if a1 == 'list' then
        local rows = {}
        for m in pairs(runtimeBlacklist) do rows[#rows + 1] = m end
        if #rows == 0 then
            notify('~o~runtime blacklist empty~s~ (only config blacklist active)')
            return
        end
        table.sort(rows)
        notify(('~b~── %d blacklisted model(s) ──'):format(#rows))
        for _, m in ipairs(rows) do notify(('~r~%s'):format(m)) end
        return
    end

    -- clear everything
    if a1 == 'clear' then
        lib.callback('hk-scenario:traffic:removeBlacklist', false, function(ok)
            notify(ok and '~g~runtime blacklist cleared' or '~r~not allowed / failed')
        end, 'all')
        return
    end

    -- remove one model: /trafficblacklist remove <name>
    if a1 == 'remove' then
        local m = (args[2] or ''):lower()
        if m == '' then notify('~r~usage: /trafficblacklist remove <model>'); return end
        lib.callback('hk-scenario:traffic:removeBlacklist', false, function(ok)
            notify(ok and (('~g~un-blacklisted ~b~%s'):format(m))
                       or  '~r~not allowed / failed')
        end, m)
        return
    end

    -- resolve the target model: typed arg wins, else the car we're driving
    local model
    if a1 ~= '' then
        model = a1
    else
        local veh = GetVehiclePedIsIn(PlayerPedId(), false)
        if veh == 0 then
            notify('~r~get in a car first, or pass a model name: ~y~/trafficblacklist adder')
            return
        end
        model = modelNameFromHash(GetEntityModel(veh))
        if not model then
            notify('~r~could not resolve this vehicle\'s model — pass the name: ~y~/trafficblacklist <model>')
            return
        end
    end

    -- TOGGLE (v2.4.55): running it again on a model that's ALREADY runtime-blacklisted
    -- UN-bans it (per user "if the same car is used on again, disable the blacklist").
    -- Only toggles the RUNTIME list — config-blacklisted models can't be un-banned here.
    if runtimeBlacklist[model] then
        lib.callback('hk-scenario:traffic:removeBlacklist', false, function(ok)
            notify(ok and (('~g~un-blacklisted ~b~%s~s~ — it can spawn as traffic again'):format(model))
                       or  '~r~not allowed / failed')
        end, model)
        return
    end

    lib.callback('hk-scenario:traffic:addBlacklist', false, function(res)
        if type(res) == 'table' and #res > 0 then
            notify(('~g~blacklisted ~r~%s~s~ — it won\'t spawn as traffic anymore~n~~y~run it again on this car to un-ban'):format(
                table.concat(res, ', ')))
        else
            notify(('~o~%s~s~ was already blacklisted (or not allowed)'):format(model))
        end
    end, { model })
end, false)

-- small helper: draw text at a world position (3D tag above a car)
local function draw3dText(x, y, z, text, scale)
    local onScreen, sx, sy = World3dToScreen2d(x, y, z)
    if not onScreen then return end
    SetTextScale(0.0, scale or 0.32)
    SetTextFont(4)
    SetTextProportional(true)
    SetTextColour(255, 255, 255, 215)
    SetTextDropshadow(0, 0, 0, 0, 255)
    SetTextEdge(1, 0, 0, 0, 255)
    SetTextDropShadow()
    SetTextOutline()
    SetTextCentre(true)
    SetTextEntry('STRING')
    AddTextComponentSubstringPlayerName(text)
    DrawText(sx, sy)
end

local function draw2dText(x, y, text, scale, r, g, b)
    SetTextFont(4)
    SetTextScale(0.0, scale or 0.34)
    SetTextColour(r or 255, g or 255, b or 255, 235)
    SetTextDropshadow(0, 0, 0, 0, 255)
    SetTextEdge(1, 0, 0, 0, 255)
    SetTextDropShadow()
    SetTextOutline()
    SetTextEntry('STRING')
    AddTextComponentSubstringPlayerName(text)
    DrawText(x, y)
end

-- DEBUG RENDER THREAD — only spins hot while dbgOn; idles cheap otherwise.
CreateThread(function()
    while true do
        if not dbgOn then
            Wait(500)
        else
            local ped = PlayerPedId()
            local pc  = GetEntityCoords(ped)
            local nB, nA, nS, nBase = 0, 0, 0, 0

            local nBraking, nHolding, nScrub, nCB, nCS = 0, 0, 0, 0, 0
            for veh, meta in pairs(spawned) do
                if DoesEntityExist(veh) then
                    -- tier tally
                    if not meta.addon then nBase = nBase + 1
                    elseif meta.tier == 'S' then nS = nS + 1
                    elseif meta.tier == 'A' then nA = nA + 1
                    else nB = nB + 1 end
                    if meta.braking then nBraking = nBraking + 1 end
                    if meta.brakeCruiseHeld then nHolding = nHolding + 1 end
                    if meta.cornerScrubbing then nScrub = nScrub + 1 end
                    if meta.cbActive then nCB = nCB + 1 end
                    if meta.counterSteering then nCS = nCS + 1 end

                    ensureBlip(veh, meta)

                    -- 3D tag (only nearby to keep it readable + cheap)
                    local vc = GetEntityCoords(veh)
                    local d  = #(vc - pc)
                    if d < 220.0 then
                        local actual = math.floor(GetEntitySpeed(veh) * 3.6 + 0.5)
                        local moving = GetEntitySpeed(veh)
                        local status
                        if meta.overtakeUntil and nowMs() < meta.overtakeUntil then
                            -- arrow shows the pull is PHYSICALLY sliding the car now
                            -- (vs. burst active but done/blocked) — verifies real steer.
                            local arrow = meta.otPulling
                                and ((meta.overtakeSide == 'R') and '»' or '«') or ''
                            status = ('~g~OVERTAKE-%s%s'):format(meta.overtakeSide or '?', arrow)
                        elseif meta.hornBoostUntil and nowMs() < meta.hornBoostUntil then
                            -- honked at: BOOST (accelerate) and/or YIELD (pull aside).
                            -- arrow shows it's physically sliding to a free lane now.
                            local arrow = meta.hornYielding
                                and ((meta.hornYieldSide == 'R') and '»' or '«') or ''
                            status = ('~c~HORN%s'):format(arrow)
                        elseif meta.braking then
                            status = '~r~BRAKING'
                        elseif meta.brakeCruiseHeld then
                            status = '~o~GAP-HOLD'
                        elseif meta.reversingUntil and nowMs() < meta.reversingUntil then
                            status = '~p~REVERSE'
                        elseif moving < 1.5 and (
                                IsVehicleStoppedAtTrafficLights(veh)
                                or (meta.blockedAheadTs and (nowMs() - meta.blockedAheadTs) < 1500)) then
                            -- LEGITIMATELY WAITING, not wedged (v2.4.45): at a red light
                            -- (native flags only the LEAD car) OR a car directly ahead
                            -- in-lane (blockedAheadTs — the queued-behind case). Show
                            -- WAITING so a normal light/traffic stop doesn't read STUCK.
                            status = '~o~WAITING'
                        elseif (meta.rekicks or 0) > 0 and moving < 2.0 then
                            status = '~o~RE-KICK ' .. meta.rekicks
                        elseif moving < 1.5 then
                            status = '~r~STUCK'
                        elseif meta.yielding then
                            status = '~r~YIELD'
                        elseif meta.cornering then
                            status = '~b~CORNER'
                        elseif meta.cornerApproaching then
                            status = '~b~APPROACH'
                        elseif meta.tcSliding then
                            status = '~o~SLIP'
                        else
                            status = '~g~OK'
                        end
                        local col = meta.addon and '~y~' or '~w~'
                        local line1 = ('%s%s ~s~[%s] ~b~%s'):format(
                            col, meta.model or '?', tierLabel(meta), meta.persona or '?')
                        local cbTag = meta.cbActive and ' ~g~CB' or ''   -- curve-bust ratchet live
                        -- SCRUB: read the replicated statebag (v2.4.67) so it shows even
                        -- for cars this client doesn't own the drive tick for; falls back
                        -- to the local meta flag. Appends the smoothed steer angle.
                        if Entity(veh).state.hkscn_scrub or meta.cornerScrubbing then
                            cbTag = cbTag .. (' ~b~SCRUB%d°'):format(math.floor((meta.scrubEma or 0) + 0.5))
                        end
                        -- CS: counter-steer yaw damper active (v2.4.69) — shows the
                        -- fraction of excess yaw being bled off this frame.
                        if meta.counterSteering then
                            cbTag = cbTag .. (' ~y~CS%d%%'):format(math.floor(meta.counterSteering * 100 + 0.5))
                        end
                        local line2 = ('~s~%d / %d km/h  %s%s'):format(
                            actual, meta.cruiseKmh or 0, status, cbTag)
                        -- floated ~2.5× higher so the tag clears the roof instead
                        -- of blocking the windshield (user request v2.4.37).
                        draw3dText(vc.x, vc.y, vc.z + 3.5, line1, 0.34)
                        draw3dText(vc.x, vc.y, vc.z + 3.2, line2, 0.30)
                    end
                end
            end

            -- ── HUD PANEL (top-left) ──────────────────────────────────────────
            local cap = fleetTotalCap()
            local kmh = playerDriveKmh()
            local chance = fleetFill()   -- v2.4.57: slider now = fleet FILL, not addon-vs-base
            local enabled = S and S.enabled
            local spawnerOn = S and S.spawnerOn
            local x = 0.015
            local y = 0.30
            local lh = 0.022

            draw2dText(x, y, '~b~── HK TRAFFIC DEBUG ──', 0.40, 120, 200, 255); y = y + lh + 0.004
            draw2dText(x, y, ('preset ~y~%s~s~   traffic %s   spawner %s'):format(
                (S and S.preset) or '?',
                enabled and '~g~ON' or '~r~OFF',
                spawnerOn and '~g~ON' or '~r~OFF'), 0.33); y = y + lh
            draw2dText(x, y, ('biome ~y~%s~s~ (x%.2f spd%s)  nativeMult ~y~x%.1f'):format(
                curBiomeName or '?', (curBiome and curBiome.speedMult) or 1.0,
                (curBiome and curBiome.openRoad) and ' ~g~OPEN' or '',
                (T.nativeSpeedMult or 1.0)), 0.33); y = y + lh
            -- AFK/backoff state (mirrors the spawner loop's own reasoning)
            local afkTag = afkSince ~= 0 and (nowMs() - afkSince) > ((T.spawner or {}).afkAfterMs or 6000)
                and ' ~o~AFK-backoff' or ''
            draw2dText(x, y, ('speed ~y~%d~s~ km/h%s'):format(
                math.floor(kmh + 0.5), afkTag), 0.33); y = y + lh
            -- fleet counts with the DERIVED caps (addons fill total minus base),
            -- so the sub-caps always add up to the total shown (no more "10/14").
            draw2dText(x, y, ('spawned ~y~%d/%d~s~  addon ~y~%d/%d~s~  fill %d%%'):format(
                spawnedCount, cap,
                addonAliveCount, addonCap(),
                math.floor(chance * 100 + 0.5)), 0.33); y = y + lh
            draw2dText(x, y, ('tiers  ~y~S %d~s~  ~r~A %d~s~  ~g~B %d~s~  base %d'):format(
                nS, nA, nB, nBase), 0.33); y = y + lh
            draw2dText(x, y, ('parked-swap  live ~y~%d/%d~s~  total ~g~%d~s~  stuck-swept ~r~%d'):format(
                parkedSwapCount, (T.spawner or {}).parkedMaxAlive or 30, dbgParkedSwaps,
                dbgStuckSwept),
                0.32); y = y + lh
            -- speed/brake tuning knobs currently in effect
            local ac = T.addon or {}
            local caps = T.tierSpeedCaps or {}
            draw2dText(x, y, ('caps B%d/A%d/S%d  minTop ~y~%d~s~  brakeMul ~y~x%.1f'):format(
                caps.B or 0, caps.A or 0, caps.S or 0,
                (T.addonMinTopSpeedKmh or 0), (ac.brakeForceMult or 1.0)), 0.30); y = y + lh
            draw2dText(x, y, ('brakeAssist %s~s~  hardBrake ~r~%d~s~  gapHold ~o~%d~s~  antiReck ~y~%d'):format(
                (ac.brakeAssist ~= false) and '~g~ON' or '~r~OFF', nBraking, nHolding,
                #(T.antiReckless or {})), 0.30); y = y + lh
            draw2dText(x, y, ('scrub %s~s~ (rate %.0f min%.0f%%)  ~b~SCRUB %d~s~  ~g~CB %d'):format(
                (ac.cornerScrub ~= false) and '~g~ON' or '~r~OFF',
                (ac.cornerScrubRate or 12.0), (ac.cornerScrubMinFactor or 0.45) * 100,
                nScrub, nCB), 0.30); y = y + lh
            draw2dText(x, y, ('counterSteer %s~s~ (gain %.2f slip%.0f°+)  ~y~CS %d'):format(
                (ac.counterSteer ~= false) and '~g~ON' or '~r~OFF',
                (ac.counterSteerGain or 0.45), (ac.counterSteerSlipDeg or 6.0),
                nCS), 0.30); y = y + lh

            -- WHY-NO-SPAWN diagnostics: attempts, successes, and the tally of
            -- bail reasons so we can see WHICH gate is rejecting every spawn.
            draw2dText(x, y, ('~b~attempts ~y~%d~s~  ok ~g~%d~s~  lastbail ~o~%s~s~  drift ~y~%d'):format(
                dbgAttempts, dbgSpawnOk, dbgLastBail, dbgCountDrift), 0.32); y = y + lh
            local parts = {}
            for reason, n in pairs(dbgBails) do parts[#parts + 1] = reason .. ':' .. n end
            table.sort(parts)
            local bailStr = (#parts > 0) and table.concat(parts, '  ') or '(none)'
            draw2dText(x, y, '~s~bails  ' .. bailStr, 0.30); y = y + lh
            local rq = tierReady and '~g~yes' or '~r~no'
            draw2dText(x, y, ('roster ready %s~s~ (B%d A%d S%d)  hk-race %s'):format(
                rq, #tierBuckets.B, #tierBuckets.A, #tierBuckets.S,
                (GetResourceState('hk-race') == 'started') and '~g~up' or '~r~down'), 0.30); y = y + lh

            -- CRITICAL: yield every frame. DrawText/3D tags must be re-issued each
            -- frame anyway, and without this Wait(0) the loop never hands control
            -- back to the game → instant freeze/crash the moment debug turns on.
            Wait(0)
        end
    end
end)

-- ── Cleanup: delete our spawned cars (and their drivers) on resource stop ───
AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    for veh, meta in pairs(spawned) do
        removeBlip(meta)
        destroySpawned(veh, meta)
    end
    spawned = {}; spawnedCount = 0; addonAliveCount = 0; baseAliveCount = 0
    -- v2.4.62 — CRITICAL LEAK FIX: also tear down the NETWORKED parked-swap fleet.
    -- Before this, stopping/restarting the resource left every swapped car alive as
    -- a networked orphan (v2.4.58 made them networked). Across a dev session of
    -- restarts these piled up server-wide → networked-entity sync cost → the 10fps
    -- collapse that cleared the instant the resource stopped (FiveM GC'd this
    -- client's owned entities on stop). Delete ours explicitly on the way out.
    for veh, meta in pairs(parkedSwapped) do
        if DoesEntityExist(veh) then
            if NetworkGetEntityIsNetworked(veh) and not NetworkHasControlOfEntity(veh) then
                NetworkRequestControlOfEntity(veh)
            end
            SetEntityAsMissionEntity(veh, true, true)
            DeleteVehicle(veh)
        end
    end
    parkedSwapped = {}; parkedSwapCount = 0
end)
