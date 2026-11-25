ScnCfg = {}

-- Command(s) an admin runs to open the scenario editor. First is primary,
-- the rest are aliases (all open the same editor).
ScnCfg.Command = 'hkscenario'
ScnCfg.CommandAliases = { 'hkscen', 'scenario' }

-- ── Clearing engine tuning ──────────────────────────────────────────────────
-- The clearing loop only *does work* when the player is near a zone. When far
-- from every zone, it idles cheaply. This is the core fix over uj_clearArea,
-- which swept every zone every 5ms regardless of where anyone was.
ScnCfg.Engine = {
    -- How often (ms) each client re-evaluates which zones it is inside/near.
    scanInterval   = 1000,
    -- Only zones within this many metres of the player are considered "active"
    -- and get their clearing pass. Keeps distant zones free.
    activateRange  = 150.0,
    -- Absolute floor on a zone's per-zone clear interval (ms), so a misconfigured
    -- zone can't spin the thread. Editor won't let you go below this.
    minZoneInterval = 100,
    -- Default per-zone clear interval when a new zone is created (ms).
    defaultInterval = 500,
}

-- ── Zone defaults / limits used by the editor ───────────────────────────────
ScnCfg.Zones = {
    defaultRadius   = 50.0,   -- circle zones
    minRadius       = 2.0,
    maxRadius       = 300.0,

    defaultBoxSize  = { length = 40.0, width = 40.0, height = 20.0 }, -- box zones
    minBoxSide      = 2.0,
    maxBoxSide      = 300.0,

    -- What a freshly-created zone clears by default.
    defaultFlags = {
        vehicles    = true,
        peds        = true,
        objects     = false,
        projectiles = false,
    },
}

-- ── Live editor marker colours ──────────────────────────────────────────────
ScnCfg.Markers = {
    normal   = { r = 0,   g = 150, b = 255, a = 90  }, -- zones in the world
    selected = { r = 255, g = 200, b = 0,   a = 120 }, -- the one you're editing
    height   = 3.0, -- marker draw height for cylinders
}

-- ── Prop system ─────────────────────────────────────────────────────────────
ScnCfg.Props = {
    -- Props within this range of the player spawn locally; beyond it they
    -- despawn. Same distance-gating philosophy as the clear engine.
    spawnRange   = 100.0,
    -- how often (ms) each client re-evaluates which props to spawn/despawn.
    scanInterval = 1000,
    -- z-offset limits for the height slider (metres, relative to ground/placed z)
    minZOffset   = -10.0,
    maxZOffset   = 10.0,
    -- default interaction distance for qb-target / polyzone interactions.
    defaultInteractDist = 2.5,
    -- model to fall back to if a saved model fails to load.
    fallbackModel = 'prop_barrier_work05',
}

-- Interaction trigger types (how the player engages a prop's action).
ScnCfg.Triggers = {
    none    = 'none',      -- passive: prop just exists, exposed to other scripts
    target  = 'target',    -- qb-target: look at prop, press interact key
    zonekey = 'zonekey',   -- polyzone-ish: in range + press key
    zoneauto= 'zoneauto',  -- in range: fire automatically (once per entry)
}

-- Interaction action types (what happens when engaged).
ScnCfg.Actions = {
    none    = 'none',
    command = 'command',   -- ExecuteCommand on the client
    client  = 'client',    -- TriggerEvent (client event)
    server  = 'server',    -- TriggerServerEvent
}

-- ── Traffic realism system (NO HESI / Wangan-style) ─────────────────────────
-- Two live layers on top of the boot-time overrides (data/gameconfig.xml pool
-- caps + data/ai_handling.meta AI profiles):
--   Layer 4  ambient NPC behaviour  — makes EXISTING traffic drive faster /
--            more aggressively, everywhere (stronger inside highway zones).
--   Layer 5  highway fast-spawner   — chunk-gated: only runs while a player is
--            inside a highway zone; streams networked fast cruisers, with an
--            occasional hkcarpack addon car mixed in (the "confuse police"
--            hook — rare, so streaming stays cheap).
--
-- All values are the DEFAULTS / hard limits. The live, admin-editable state
-- (enable flags, preset, spawner intensity, addon rate) is stored server-side
-- in hk_scenario_meta k='traffic' and synced to clients — see server/traffic.lua
-- + client/traffic.lua. If nothing has ever been saved, `enabled=false` and the
-- system does NOTHING (opt-in, same philosophy as the density module).
ScnCfg.Traffic = {
    -- Master default when no server override exists yet. Editor flips this live.
    defaultEnabled = false,

    -- How often (ms) the client re-scans the vehicle pool to tune NPC drivers.
    -- Throttled on purpose; NPC driving params are sticky once set.
    scanInterval = 750,

    -- Each ambient NPC driver is tuned once, then left alone for this long (ms)
    -- before we re-assert (covers drivers the engine re-tasks). Keeps us cheap.
    retuneAfter = 8000,

    -- Highway detection is MAP-AGNOSTIC (no hardcoded LS coords, so it also
    -- works on a future custom Wangan map): a spot counts as "highway" when
    -- moving on a road above this speed. NPCs already going this fast get the
    -- preset's highwayBonusKmh; the Layer-5 spawner only runs while the PLAYER
    -- is driving on a road above this speed.
    highwaySpeedKmh = 75,

    -- ── Driving-style bitflags (SetDriveTaskDrivingStyle) ──────────────────
    -- Documented here so the presets read clearly. The old 786469 let NPCs go
    -- the WRONG WAY and ignore other cars — that's the "weird/reckless swerve"
    -- feel. What we actually want for Wangan is FAST + SMOOTH: high speed but
    -- still avoiding collisions and taking the fast line. So:
    --   AvoidVehicles(4) + AvoidEmptyVehicles(8) + AvoidObjects(32)
    --   + StopBeforeVehicles(1) + TakeShortestPath(262144)  = 262189
    --   (NO wrong-way, NO ram — just fast flowing traffic)
    -- Surface-street style keeps traffic lights + ped avoidance (786603).
    Styles = {
        Street  = 786603,   -- normal: obey lights, avoid peds/cars (surface roads)
        Flow    = 262189,   -- fast highway flow: avoid collisions, shortest path
    },

    -- ── NPC behaviour presets (Layer 4) ────────────────────────────────────
    -- ability/aggression are 0..1 (SetDriverAbility / SetDriverAggressiveness).
    --   AGGRESSION IS DELIBERATELY MODEST: high aggression = constant reckless
    --   lane-swapping/overtaking (the "weird driving"). Speed comes from
    --   cruiseKmh + ability, NOT from aggression. Keep aggression ≤ ~0.45.
    -- cruiseKmh is the base cruise speed we push onto ambient drivers (m/s in
    --   code). GTA default cruise ≈ 20 m/s (~72 km/h) w/ absurdly-early braking.
    -- highwayBonusKmh is ADDED to cruiseKmh when the driver is already moving
    --   fast (highway), so surface streets stay sane while freeways get quick.
    -- style = one of Styles above.
    -- NOTE on collisions: HIGH ability = skilled driver = brakes in time and
    -- avoids crashes. HIGH aggression = shoves through gaps and clips cars. So
    -- for "fast but doesn't crash" we want ability HIGH and aggression LOW.
    -- Styles here all include StopForVehicles(1); 262317 = flow + StopAtLights,
    -- no wrong-way (the old 786603 secretly allowed wrong-way driving).
    -- BASE SPEED BUMP (2026-08-26): every preset's base cruise raised ~+22 km/h
    -- because ambient NPCs were driving too slowly on ordinary roads. The old
    -- values (65/90/120/150) crawled; these keep surface traffic moving at a
    -- realistic clip. Highway/open-road bonuses stack on top via biome below.
    -- Driving-style bitflags (SetDriveTaskDrivingStyle):
    --   StopForVehicles=1  StopForPeds=2  SwerveAroundVehicles=4
    --   SteerAroundStationary=8  SteerAroundPeds=16  SteerAroundObjects=32
    --   StopAtTrafficLights=128  UseBlinkers=262144
    -- The OLD ambient style 262317 included SwerveAroundVehicles(4) but NOT
    -- StopForPeds(2) — THAT combo is exactly the "squeeze 5-6 wide on a 2-lane
    -- like a drag start, pause then lunge into the gap, and mow down pedestrians"
    -- behaviour you saw. NEW normal style 262315 = StopForVehicles(1) +
    -- StopForPeds(2) + SteerAroundStationary(8) + SteerAroundObjects(32) +
    -- StopAtTrafficLights(128) + blinkers, and crucially NO SwerveAroundVehicles:
    -- they hold their lane, brake for peds, and queue instead of drag-racing.
    presets = {
        Calm       = { ability = 0.80, aggression = 0.03, cruiseKmh = 95,  style = 262315, highwayBonusKmh = 25 },
        Normal     = { ability = 0.85, aggression = 0.05, cruiseKmh = 120, style = 262315, highwayBonusKmh = 55 },
        Aggressive = { ability = 0.92, aggression = 0.12, cruiseKmh = 150, style = 262315, highwayBonusKmh = 80 },
        -- Wangan = arcade highway-runner: high ability so they hold the fast line
        -- cleanly, LOW aggression (fast, not swervy/crashy), big highway bonus.
        Wangan     = { ability = 1.0,  aggression = 0.15, cruiseKmh = 175, style = 262315, highwayBonusKmh = 110 },
    },
    defaultPreset = 'Normal',

    -- ── BIOME VARIATION (Layer 4.5) ─────────────────────────────────────────
    -- Traffic speed + population should FEEL different between regions, and the
    -- old highway detection was circular: a road only counted as "highway" once
    -- a car was ALREADY going fast, so open desert roads never sped up (nothing
    -- was fast there to trigger it). Biomes break that loop with a POSITION test
    -- (GetNameOfZone), so a road is "open/fast" because of WHERE it is, not how
    -- fast something already happens to be going on it.
    --
    -- Per zone-code profile:
    --   speedMult     multiplier on ambient cruise + spawner cruise in this zone
    --   densityMult   multiplier on vehicle/parked population in this zone
    --   openRoad      true => roads here ALWAYS get the highway bonus and let the
    --                 fast-spawner run (this is the circular-detection fix)
    --   spawnerMinKmh min player speed (km/h) for the fast-spawner to run here
    -- Any zone not listed uses `default` (ordinary city surface streets).
    Biomes = {
        enabled       = true,
        scanInterval  = 1500,   -- how often (ms) to re-read the player's zone
        -- Base density used to derive per-biome population when traffic is ON
        -- (pushed into qb-smallresources via the density module). Matches qb's
        -- own defaults so we don't shock the world when biome control kicks in.
        baseDensity   = { vehicle = 0.60, parked = 0.40, peds = 0.60, scenario = 0.30 },

        -- spawnerMinKmh LOWERED to 20 (2026-08-26): the spawner (the ONLY source
        -- of addon cars) is no longer a "highway-only" feature — the user wants
        -- exotics mixed into CITY / DOWNTOWN traffic too. 20 km/h means it fires
        -- during any normal driving (even slow downtown crawl), so addon cars
        -- show up everywhere, not just on open freeways.
        default = { speedMult = 1.00, densityMult = 1.00, openRoad = false, spawnerMinKmh = 20 },

        zones = {
            -- ── Open desert / rural north: FAST + SPARSE ────────────────────
            -- These are the "Sandy Shores highways before the entry" and the
            -- Route 68 open runs. Cars cruise quick, traffic thins out.
            SANDY   = { speedMult = 1.25, densityMult = 0.55, openRoad = true, spawnerMinKmh = 30 },
            DESRT   = { speedMult = 1.30, densityMult = 0.45, openRoad = true, spawnerMinKmh = 30 },
            GREATC  = { speedMult = 1.22, densityMult = 0.55, openRoad = true, spawnerMinKmh = 35 },
            GRAPES  = { speedMult = 1.15, densityMult = 0.60, openRoad = true, spawnerMinKmh = 35 },
            HARMO   = { speedMult = 1.20, densityMult = 0.55, openRoad = true, spawnerMinKmh = 35 },
            ALAMO   = { speedMult = 1.20, densityMult = 0.50, openRoad = true, spawnerMinKmh = 35 },
            CANNY   = { speedMult = 1.15, densityMult = 0.55, openRoad = true, spawnerMinKmh = 40 },
            MTCHIL  = { speedMult = 1.15, densityMult = 0.45, openRoad = true, spawnerMinKmh = 40 },
            MTGORDO = { speedMult = 1.15, densityMult = 0.45, openRoad = true, spawnerMinKmh = 40 },
            TATAMO  = { speedMult = 1.18, densityMult = 0.50, openRoad = true, spawnerMinKmh = 35 },
            CHU     = { speedMult = 1.15, densityMult = 0.55, openRoad = true, spawnerMinKmh = 40 },

            -- ── Fort Zancudo crossing (L→R past the air-force base) ─────────
            -- Route 68 runs straight across here. It was being treated as slow
            -- city road; now it's an open fast crossing like the rest of 68.
            ARMYB   = { speedMult = 1.30, densityMult = 0.45, openRoad = true, spawnerMinKmh = 30 },
            ZANCUDO = { speedMult = 1.30, densityMult = 0.45, openRoad = true, spawnerMinKmh = 30 },
            LAGO    = { speedMult = 1.20, densityMult = 0.50, openRoad = true, spawnerMinKmh = 35 },

            -- ── Paleto Bay small town: moderate ─────────────────────────────
            PALETO  = { speedMult = 1.05, densityMult = 0.70, openRoad = false, spawnerMinKmh = 35 },
        },
    },

    -- ── Highway fast-spawner (Layer 5) ──────────────────────────────────────
    spawner = {
        defaultOn      = false,   -- editor toggles live
        -- Max script-spawned highway cars alive PER CLIENT at once. Hard cap;
        -- the engine's own ambient traffic is separate and unaffected.
        -- Trimmed 12 -> 10 (2026-08-26) to shave the mild addon-streaming stutter.
        -- Trimmed 10 -> 5 (v2.4.60, user "5 max per real player so they STACK UP"):
        -- every client runs its OWN spawner and its cars are networked, so N players
        -- in one area used to pile ~10×N cars. A low PER-PLAYER cap means the fleets
        -- STACK to a sane total instead of a fuck-ton — 1 player ~5, 3 players ~15.
        -- NOTE effective cap = round(maxSpawned × intensity × fill), so at intensity
        -- 1.16 / fill 1.0 this is ~6; drop intensity to 1.0 for a hard 5.
        maxSpawned     = 5,
        -- Spawn cars OFF-SCREEN so there's no visible pop-in. Two modes, picked
        -- per spawn: BEHIND the player (they catch up and overtake — the classic
        -- NoHesi "fast car blows past you" feel; collision is already streamed
        -- there so it's the SAFE mode) or FAR AHEAD (beyond render distance).
        -- Behind-spawns are favoured because ahead-spawns can land on not-yet-
        -- streamed collision (the "frozen car in the lane" bug) — the spawner
        -- collision-gates ahead-spawns and aborts if collision won't load.
        -- Distances RETUNED 2026-08-26 for normal (non-freeway) driving. The old
        -- band (180-300 behind / 350-500 ahead) was sized for highway speeds — at
        -- city speed you'd never catch a car spawned 350m ahead, and behind-spawns
        -- at 150 km/h took forever to reach you, so you rarely SAW the addons. Now
        -- most spawn AHEAD at a distance you'll actually drive past.
        -- NOTE: both bands MUST start beyond noSpawnRadius (170) or the spawn is
        -- always rejected. Behind 190-260, ahead 195-330.
        spawnBehindMin = 190.0,   -- behind the player (well out of view frustum)
        spawnBehindMax = 260.0,
        -- AHEAD band now starts BEYOND visiblePopDist (270) so an ahead-on-your-
        -- road spawn isn't instantly rejected by the on-screen guard (that reject
        -- was killing every forward spawn on a straight highway, which is why cars
        -- only ever appeared behind / to the sides / on nearby roads). Widened the
        -- max too so there's a real forward band to populate the path you're
        -- driving toward. 275-430.
        spawnAheadMin  = 275.0,
        spawnAheadMax  = 430.0,
        behindChance   = 0.30,    -- 30% behind / 70% AHEAD (populate the path ahead)
        -- Lateral scatter (m) for AHEAD spawns — kept TIGHT so they stay on the
        -- road you're heading toward (a lane or two), not flung onto a parallel or
        -- opposite highway. Behind spawns use the wider spawnScatter below.
        spawnScatterAhead = 30.0,
        -- Hard reject if the chosen node is closer than this to the player OR
        -- currently on screen (belt-and-suspenders against pop-in).
        minSpawnDist   = 140.0,
        -- HARD no-spawn bubble: never create a car within this many metres of the
        -- player, on-screen OR off — fixes "car spawns directly in front of me
        -- like a witch" when you rotate right after a just-off-frustum spawn.
        noSpawnRadius  = 170.0,
        -- HARD no-cull bubble: never DELETE a spawned car within this many metres
        -- of the player (removing one this close is always visible — the "despawn
        -- in front of my face" bug). Stuck cars in here get re-kicked, not culled.
        noCullRadius   = 95.0,
        -- Despawn a script car once it falls this far behind / away (m). Beyond
        -- this we only cull when the car is OFF-screen.
        cullDistance   = 400.0,
        -- HARD cull distance (m): beyond this we delete the car REGARDLESS of
        -- on-screen state. Fixes "stops spawning after a few rounds / feels
        -- compressed": ahead-spawns that outran the player stayed permanently
        -- on-screen far down the road, never hit the off-screen cull, and pinned
        -- spawnedCount at the cap so no new cars could spawn. 550 > cullDistance
        -- so the normal off-screen cull still gets first crack.
        hardCullDistance = 550.0,
        -- Lateral spawn scatter (m): cars spawn up to ±this far perpendicular to
        -- the player's heading (plus a ±40 m forward jitter) instead of dead-center
        -- on the nearest road node. Fixes "spawns always line up in one train" —
        -- they used to snap to the same lane node and travel locked together. They
        -- still occasionally group up (which the user likes), just not always.
        spawnScatter    = 90.0,
        -- Per-car cruise speed variance (fraction, ±): each non-reckless car gets a
        -- random ±this% on its cruise target so packs spread out over time instead
        -- of moving as one locked train (identical targets never separated).
        speedVariance   = 0.12,
        -- STUCK WATCHDOG + RECOVERY: when a spawned car goes near-stationary
        -- (< ~1.5 m/s), first try to UN-STICK it by re-issuing its drive task,
        -- and only remove it if it stays wedged. Tunes the "addon driver stops /
        -- gets stuck in the middle of the road" fix.
        stuckRekickMs   = 800,    -- stationary this long → attempt a re-kick (v2.4.35: was
                                  -- 2000; user "rekick faster/earlier after a crash". This
                                  -- is BOTH the first-kick delay AND the interval between
                                  -- kicks, so a crashed car tries to recover ~2.5× sooner.)
        stuckMaxRekicks = 6,      -- re-issue the drive task up to this many times (v2.4.36:
                                  -- was 3; user "after 3 it won't try to find a new path").
                                  -- Higher + the reverse maneuver below = more attempts to
                                  -- back out and re-route before giving up.
        -- REVERSE GATE (v2.4.41 — user: "reverse ONLY after being CONTINUOUSLY
        -- stuck, N sec max per reverse"). Reverse is armed purely by continuous-
        -- stuck TIME: the car must be stuck (no GENUINE forward movement — our own
        -- reverse doesn't count) for reverseArmMs before it may reverse, then only
        -- for reverseMaxMs.
        stuckReverseEnable = true,
        -- (v2.4.43 — user: "reverse still happens when an NPC is waiting for a red
        -- light"). A pure TIME gate can't tell "stopped at a red" from "wedged
        -- against a wall", so a car at the front of a light armed the reverse and
        -- backed up. Fix: while the engine reports the car is STOPPED AT TRAFFIC
        -- LIGHTS we (a) never reverse and (b) hold the continuous-stuck timer at
        -- now, so red-light waiting never counts toward the arm. The instant the
        -- light greens, the timer starts fresh.
        reverseSkipAtLights = true,
        -- (v2.4.44 — user: "shorten the rekick to 6s + reverse to 1s max, then it
        -- needs to go FORWARD; but if going forward is blocked again it can INSTANTLY
        -- trigger another 1s reverse"). So: FIRST reverse of a stuck episode needs
        -- the full reverseArmMs (6s). After a reverse the car is forced to attempt
        -- FORWARD for reverseForwardTryMs; if it's STILL stuck after that (forward
        -- blocked — wall or traffic), it may reverse again INSTANTLY (no 6s wait).
        -- The moment it genuinely drives free, the episode ends → next reverse needs
        -- the full 6s again.
        reverseArmMs    = 6000,   -- continuously stuck this long before the FIRST reverse
        reverseMaxMs    = 1000,   -- max duration of a single reverse action
        reverseForwardTryMs = 1000, -- after a reverse, force a forward attempt this long
                                  -- before an instant re-reverse is allowed (v2.4.44)
        stuckGiveUpMs   = 16000,  -- (v2.4.41) continuous-stuck ceiling → delete. MUST be
                                  -- > reverseArmMs so a car earns its reverse attempt(s)
                                  -- before being deleted. Main watchdog (on-screen, 90-320m);
                                  -- off-screen cars are still fast-deleted at stuckOffscreenMs.
        blockAheadGraceMs = 1500, -- (v2.4.38) legacy; kept for compat (reverse now purely
                                  -- time-gated, this no longer gates it).
        stuckHardMs     = 8000,   -- still stuck this long → remove even ON-screen
        stuckTimeoutMs  = 6000,   -- (legacy key, kept for compat)
        -- Seconds between spawn attempts (per client). Lowered 1.5->1.0 so the
        -- fleet fills up faster (addons visible sooner).
        spawnCooldown  = 1.0,
        -- Cruise speed (km/h) tasked onto spawned highway cars. Raised 150->170
        -- so even a plain base spawn keeps pace on open roads.
        cruiseKmh      = 170,
        -- Lane-keeping style + LOW aggression. CHANGED 262189 -> 262315: the old
        -- style had SwerveAroundVehicles(4) but no StopForPeds(2), which is what
        -- made base cars drag-race 5-6 wide, lunge into gaps, and hit peds. 262315
        -- = StopForVehicles(1)+StopForPeds(2)+SteerAroundStationary(8)+
        -- SteerAroundObjects(32)+StopAtTrafficLights(128)+blinkers, NO swerve — so
        -- they hold their lane, brake for people, and queue instead of squeezing.
        style          = 262315,
        ability        = 1.0,      -- SKILLED: brake in time, clean lane changes
        aggression     = 0.05,     -- was 0.25 — no gap-shoving / drag-start squeeze

        -- Off-road / water spawn guards (fixes "cars on the beach / riverside"):
        maxNodeSnap    = 60.0,  -- reject if the snapped road node drifted >this (m) from where we aimed
        waterMargin    = 1.5,   -- reject node if water level is within this (m) of the ground
        minNodeDensity = 1,     -- reject near-dead nodes (lonely off-network tracks)
        -- SCENARIO ZONE RESPECT (v2.4.37 — user: "addon cars spawn in areas I
        -- painted to clear/block traffic; follow those"). Never spawn inside an
        -- ACTIVE zone flagged clr_vehicles / blk_roads / blk_navmesh, and delete
        -- our cars that wander into one. This margin (m) keeps spawns off the zone
        -- edge so a car doesn't pop right at the border and roll in.
        zoneSpawnMargin = 15.0,
        -- SPAWN DIVERSITY DECK (v2.4.42 — user: "same few cars every round; until
        -- the whole car list has been spawned through, each vehicle can only spawn
        -- twice per server uptime until the list finishes or I restart"). Each
        -- addon model may spawn at most this many times before the FULL roster has
        -- cycled; once every car hits the cap the deck resets for a fresh cycle
        -- (also resets on resource restart). 2 = the user's requested cap.
        deckMaxPerCar = 2,
        -- Absolute stuck timeout: any spawned car near-stationary longer than this
        -- (ms) is force-deleted regardless of distance/on-screen. 45s per user.
        stuckDeleteMs   = 45000,
        -- CONFINED-ZONE GHOST DESPAWN (v2.4.50 — user: "if a car has been stuck
        -- within a radius-6 zone for 45s, just ghost-mode despawn it quietly"). The
        -- speed-based stuckDeleteMs above misses cars that keep SOME speed while
        -- going nowhere — jittering, reversing back-and-forth, oscillating in place —
        -- so they never trip it yet never escape. This tracks a POSITION anchor: if
        -- the car never leaves a confineRadius sphere of where it was for
        -- confineDespawnMs, we fade it out (alpha ramp) and delete it silently. Any
        -- time it travels past the radius the anchor re-centres and the timer resets.
        confineDespawn    = true,
        confineRadius     = 6.0,     -- metres; leaving this sphere resets the anchor
        confineDespawnMs  = 45000,   -- confined this long → ghost despawn
        confineFadeMs     = 700,     -- alpha fade-out duration before the delete
        -- OFF-SCREEN FAST DELETE (v2.4.31 — user: "avoid too many spawned vehicles
        -- being retarded/crashed and jamming an area — do it when no player is
        -- looking"). A stuck/crashed car that is NOT on the local player's screen
        -- is deleted after this MUCH shorter timeout (vs the 45s absolute), so a
        -- pile-up clears itself the instant everyone looks away instead of festering
        -- into a roadblock. On-screen cars still get the full watchdog + 45s ceiling
        -- so nothing vanishes in your face.
        stuckOffscreenMs = 5000,
        -- FLIPPED / WRECKED: a car on its roof or side is never recovering. If it's
        -- upside-down (or badly tilted) AND off-screen, delete it fast (this window)
        -- rather than waiting for the stuck timer — flipped cars often still register
        -- tiny speed jitter that would otherwise keep resetting the frozen timer.
        flippedOffscreenMs = 2500,
        -- Adaptive spawn backoff (stops the "8000 attempts / 1700 ok" waste).
        -- v2.4.64 cadence (user spec): a successful spawn is a steady 8s drip, but
        -- a FAILED attempt (bailed on a gate) retries at 4s so the fleet still fills
        -- promptly; at cap we only re-check every 6s, and an AFK/parked player barely
        -- tops up at 20s. `spawnCooldown` above is now legacy (superseded by these).
        spawnOkCooldownMs   = 8000,   -- normal, a car spawned last try → wait 8s
        spawnFailCooldownMs = 4000,   -- normal, last try failed → retry in 4s
        capBackoffMs    = 6000,   -- when fleet is at cap, wait this long between attempts
        afkAfterMs      = 6000,   -- player barely moving this long → treat as AFK/idle
        afkBackoffMs    = 20000,  -- AFK attempt spacing (fleet near a parked player never drains)
        afkMoveThreshold = 4.0,   -- moved less than this (m) between ticks = "not moving"

        -- On-screen POP guard distance: an on-screen spawn is only rejected when
        -- CLOSER than this (m). Beyond it, a car appearing down the road just
        -- looks like normal distant traffic, so we allow it. Without this, a
        -- stationary player looking down a straight road rejected EVERY spawn
        -- (everything in the 195-330m band is technically on-screen) → the
        -- "says spawning, nothing appears, lastbail on-screen" bug.
        visiblePopDist  = 260.0,

        -- ── CITY / CROWDED-AREA SPAWNING (v2.4.75, user: "right now it's too hard
        -- to spawn especially in city or more crowded areas") ─────────────────
        -- The bands above (ahead 275-430m, no-spawn bubble 170m, pop-guard 260m)
        -- are sized for OPEN HIGHWAY. In a dense city grid those far nodes are the
        -- problem: at 275-430m the road has usually bent away so the snapped node
        -- DRIFTS past maxNodeSnap (bail 'node-drift'), or it lands on a cross-street
        -- that's occluded-but-technically-on-screen (bail 'on-screen'), or the far
        -- collision isn't streamed (bail 'no-ground'). Net: almost every city spawn
        -- bails and the fleet never fills. FIX: when the player is going SLOW (city
        -- speed), switch to a SHORT, CLOSE band with a smaller no-spawn bubble and
        -- WIDER scatter — buildings occlude the closer spawns so there's no pop-in,
        -- and short hops land on real, streamed, nearby grid nodes. Highway speed
        -- keeps the long band unchanged. Blend is by the player's current speed.
        cityAdaptive        = true,    -- master switch for the speed-adaptive band
        cityBandKmh         = 60.0,    -- at/below this speed use the CITY band; above → highway band (linear blend up to 1.5×)
        -- CITY band (short, close — used at low speed):
        cityBehindMin       = 70.0,
        cityBehindMax       = 130.0,
        cityAheadMin        = 90.0,    -- just past cityNoSpawnRadius; short forward hops onto grid nodes
        cityAheadMax        = 170.0,
        cityNoSpawnRadius   = 75.0,    -- smaller no-spawn bubble (city sightlines are short/occluded)
        cityVisiblePopDist  = 90.0,    -- only reject on-screen spawns very close (buildings hide the rest)
        cityMaxNodeSnap     = 90.0,    -- allow more snap drift (grid nodes are dense but rarely dead-ahead)
        cityScatterAhead    = 55.0,    -- wider ahead scatter → hit side streets / parallel roads, not one lane
        cityBehindChance    = 0.45,    -- more even behind/ahead in the city (both directions have road)
        -- ── PARKED-CAR REPLACEMENT (v2.4.52) ─────────────────────────────────
        -- The 2026-08-26 PARKED-addon *sprinkler* was removed because it CREATED
        -- new parked cars that snapped to road-center nodes and read as stuck. This
        -- is the OPPOSITE + safe approach the user asked for: don't create parked
        -- cars at all — instead HIJACK the game's OWN ambient parked cars (already
        -- correctly placed in real parking spots, always empty) and swap the model
        -- IN PLACE at the exact same coords/heading, off-screen, left parked (no
        -- driver, no drive task). So we replace random base parked cars with our
        -- curated hkcarpack fleet as scenery — no road-node snapping, no stuck cars.
        parkedSwap        = true,     -- master switch
        parkedSwapEveryMs = 1500,     -- how often the swap pass runs
        parkedSwapPerPass = 2,        -- max swaps per pass (keep it gentle)
        parkedNearMin     = 60.0,     -- never swap a parked car closer than this (m)
        parkedScanMax     = 240.0,    -- only consider parked cars within this of player (m)
        parkedSwapChance  = 0.5,      -- per eligible car, roll this to actually swap
        parkedMaxAlive    = 7,        -- cap on how many swapped parked cars we track (v2.4.61: 30→7, user "max 7 is fine")
        parkedMoveEps     = 0.35,     -- speed (m/s) under which a car counts as "parked"
        parkedGraceMs     = 6000,     -- match main.lua stream grace — don't swap fresh streams

        -- STUCK-CAR ROAD SWEEP (v2.4.60, user: "we still see random cars stuck in
        -- the middle of the road — use the clear-area function to remove no-NPC,
        -- non-moving vehicles"). Separate from the parked SWAP above: this DELETES
        -- (doesn't replace) genuinely wedged AMBIENT cars — empty, dead-stopped for
        -- a while, on a driving lane — that the engine abandoned mid-road. Reuses
        -- Scn_isTrafficProtected (never touches player cars / hk-parking / our
        -- spawns+swaps / trains / mission entities) + the v2.4.59 server-auth delete.
        stuckSweep        = true,     -- master switch
        stuckSweepEveryMs = 4000,     -- how often the sweep runs
        stuckSweepRadius  = 140.0,    -- only sweep cars within this of the player (m)
        stuckSweepNearMin = 25.0,     -- never sweep a car closer than this (avoid pop in your face)
        stuckMoveEps      = 0.30,     -- speed (m/s) under which a car counts as "stopped"
        stuckForMs        = 7000,     -- must be empty+stopped continuously this long to delete
        stuckSweepPerPass = 3,        -- max deletions per pass (keep it gentle)
        stuckRequireOffscreen = true, -- only delete when the car is off-screen (no visible vanish)
    },

    -- Driver ped pool for spawned cars — DIVERSE ambient civilians (was a single
    -- business-suit model, which is why every addon car had a suit driver). Kept
    -- to reliable base ambient models so they always stream.
    driverPeds = {
        'a_m_y_hipster_01', 'a_f_y_hipster_02', 'a_m_m_business_01',
        'a_f_y_business_02', 'a_m_y_downtown_01', 'a_f_y_fitness_01',
        'a_m_y_skater_01', 'a_f_m_bevhills_02', 'a_m_m_eastsa_01',
        'a_f_y_eastsa_02', 'a_m_y_genstreet_01', 'a_f_m_ktown_01',
        'a_m_y_latino_01', 'a_f_y_soucent_02', 'a_m_m_hasjew_01',
        'a_m_y_beach_02', 'a_f_y_tourist_01', 'a_m_y_stwhi_01',
    },

    -- ── Vehicle pool ────────────────────────────────────────────────────────
    -- Base GTA models the highway spawner picks from (spawn-safe, common-ish
    -- fast/every-day cars — NOT the timid compacts). Weighted by repetition.
    baseModels = {
        'sultan', 'kuruma', 'schafter2', 'oracle2', 'jackal', 'buffalo',
        'sentinel', 'felon', 'comet2', 'elegy2', 'furoregt', 'ruston',
        'zr380', 'dominator', 'gauntlet', 'schwarzer', 'tailgater', 'fugitive',
        'baller2', 'rocoto', 'coquette', 'feltzer2', 'massacro', 'rapidgt',
    },

    -- ── Fleet FILL (v2.4.57 — repurposed from the old "addonChance") ─────────
    -- HISTORY: this used to be "chance [0..1] a spawner car is a curated addon vs
    -- a base GTA model". Base spawning was ditched in v2.4.24 (baseMaxAlive 0) so
    -- that roll went DEAD — pickModel always picks an addon and never read this.
    -- NOW it means FLEET FILL: a 0..1 multiplier on the intensity-scaled cap.
    --   fill 1.0 → full cap (e.g. maxSpawned 12 × intensity 1.4 = 14 cars)
    --   fill 0.5 → half that many alive (7)
    --   fill 0.0 → spawner effectively off
    -- The LIVE value is the editor slider saved in hk_scenario_meta k='traffic'
    -- (S.addonChance), which OVERRIDES this default. Clamped 0..1. Debug HUD shows
    -- it as "fill %". Reckless racers still force an addon regardless.
    addonChance = 1.0,
    -- OPTIONAL addon ceiling. The spawner now derives the addon cap as
    -- (totalCap - baseMaxAlive), so ADDONS AUTOMATICALLY FILL whatever the total
    -- leaves after base — e.g. total 10 → 8 addons, total 14 (intensity 1.4) → 12
    -- addons. This fixes the old "spawned 10/14" mismatch (8+2 didn't add up to
    -- the intensity-scaled total). Set this to a NUMBER only if you want to CLAMP
    -- addons BELOW that remainder (e.g. to limit distinct-model streaming stutter);
    -- nil = no separate ceiling, addons fill the remainder.
    addonMaxAlive = nil,
    -- BASE (native GTA model) spawning was DITCHED in v2.4.24 (user: "ditch the
    -- base vehicle scripting, not much need"). pickModel now only ever spawns
    -- addons, so this is 0 → addons fill the ENTIRE fleet (addonCap = totalCap − 0).
    -- Ambient NATIVE traffic (the game's own cars we re-tune) is unaffected; this
    -- only governs OUR spawner. Set >0 only if you re-enable base spawning.
    baseMaxAlive = 0,
    -- NATIVE-SPEED TRIM: flat multiplier on the ambient driver cruise (Layer 4).
    -- IMPORTANT (2026-08-26 rework): tuneDriver now RE-ISSUES a scripted
    -- TaskVehicleDriveWander, so the commanded cruise is ACTUALLY HONOURED — the
    -- stock ambient wander task was ignoring SetDriveTaskCruiseSpeed entirely,
    -- which is why the old 2.4 "bump" did nothing (it multiplied a value the game
    -- threw away). Now the preset cruiseKmh values below ARE real km/h, so this is
    -- a global fine-trim, NOT a big bump. 0.55 => Normal city ~66 km/h / highway
    -- ~96 km/h (was stock-crawl ~35). Nudge up for faster world, down for calmer.
    nativeSpeedMult = 0.55,

    -- AMBIENT SPEED FLOOR (v2.4.40 — user: "make even the default GTA spawns drive
    -- 75-95 km/h too, they drive too slow"). After all the multipliers above, every
    -- tuned ambient (native, game-owned) driver is floored to a random cruise in
    -- this band so surrounding traffic always moves at a lively pace instead of the
    -- GTA crawl. Per-car random for variety. FLOOR only — highway/open-road cars
    -- already commanded faster keep their higher speed. Set min>=max to disable.
    -- NOTE: this is the AMBIENT game traffic; OUR spawned addon fleet is separate
    -- (it has the curve-bust + corner-governor bounce feel).
    ambientCruiseMinKmh = 75.0,
    ambientCruiseMaxKmh = 95.0,

    -- ── Tier weighting (uses hk-race B/A/S classification) ──────────────────
    -- At startup we ask hk-race to classify every addonModels entry into its
    -- performance tier (B=slow/common cars, A=mid, S=hypercars) via its
    -- classifyByHash export (real hk-handling speed data). The spawner then
    -- picks a TIER by these weights, then a random model within that tier:
    -- lots of B, a fair amount of A, rare S. Falls back to a flat pick if
    -- hk-race isn't started or has no data for a model.
    -- Rebalanced 2026-08-26: B and A BOTH common, S genuinely rare (a hypercar
    -- should be a treat, not routine). Was 70/25/5.
    -- Rebalanced 2026-08-26 (user wants MORE S): S is now the most common tier,
    -- A and B equal below it. Was 50/47/3.
    -- Rebalanced 2026-08-26 (too many S now): B and A both dominant, S back to a
    -- treat. Was 30/30/40.
    tierWeights = { B = 40, A = 40, S = 20 },   -- relative odds; need not sum to 100

    -- Per-tier TOP-SPEED CAP (km/h) for spawned addon cars. Raises the cruise
    -- ceiling so the fast tiers actually stretch out: A-class ~240, S-class ~370
    -- (S can hit it most of the time). The engine still clamps to each car's real
    -- top speed, so this only lets a capable car go fast — it can't overspeed a
    -- slow one. Reckless cars target their tier cap directly (full send).
    -- Raised per user "160-170 not enough": regular cars 265-320 max, S can push
    -- past 360. B (everyday) tops ~265, A (mid performance) ~320, S (hypercars)
    -- ~380. Engine still clamps to each car's real top speed, so a car only hits
    -- its cap if it genuinely can.
    tierSpeedCaps = { B = 265, A = 320, S = 380 },
    -- Floor cruise (km/h) for spawned cars so nobody trundles: even a slow base
    -- car in the city holds at least this. Consistent 65-75 per user.
    minCruiseKmh = 70,
    -- CRUISE CAP for BASE (native GTA) spawned cars (km/h). Base cars have NO tier,
    -- so tierSpeedCaps never applied to them — combined with nativeSpeedMult (2.4)
    -- stacking on the 170 spawner cruise AND the biome mult, a base sultan was being
    -- tasked at ~500+ km/h (the "sultan showing 518" bug). This caps them sanely.
    -- A base car shouldn't out-run the addon exotics anyway. Set high if you WANT
    -- fast base traffic, but 150 keeps them believable ambient cars.
    baseCruiseCap = 150,
    -- ABSOLUTE cruise ceiling (km/h) applied to EVERY spawned car after all mults,
    -- as a final backstop so no biome/variance/mult combo can ever task an insane
    -- speed again. Above the top tier (S=380) so it never clips a legit hypercar.
    maxCruiseKmh = 400,
    -- ADDON TOP-SPEED FLOOR (km/h): every ADDON car is guaranteed to be physically
    -- CAPABLE of at least this. At spawn we read the car's estimated max speed and,
    -- if it's below this, bump it via ModifyVehicleTopSpeed so a weak/economy addon
    -- can still reach it. This raises the CAPABILITY only — the tier cap + cruise
    -- target still govern how fast it actually drives (reckless addons target their
    -- tier cap, which is >=220). Base GTA cars are left stock. Per user: "every
    -- addon must AT LEAST be able to reach the MAX of 220 km/h".
    addonMinTopSpeedKmh = 220,
    -- Source the addon roster LIVE from qb-core QBShared.Vehicles (auto-follows
    -- the shop; covers ALL pack cars, not the stale 12-model list below). Set
    -- false to force the hardcoded addonModels list instead.
    useQbCoreRoster = true,
    -- Curated, SPAWN-SAFE hkcarpack model names. IMPORTANT: only whole vehicles
    -- here — NEVER bodykit fragments (e.g. x6mf16_cage_1, rx7_wing_2) which are
    -- not standalone spawnable. Validated with a load-timeout at spawn; on
    -- failure the spawner falls back to a base model, so a bad name is harmless.
    addonModels = {
        'rx7', 're_amemiya_rx73s', 'm3e92', 'gemera', 'gallardo07', 'na1',
        'continental17', 'f812c21', 'v877', 'mb300sl', 'soullfa', 'f812c21',
    },

    -- ── BLACKLIST (never spawn these, from ANY source) ──────────────────────
    -- Put any model name here you don't want on the road — checked against the
    -- qb-core roster, the addonModels fallback, AND the base GTA baseModels pick.
    -- Case-insensitive. Add spawn names exactly (the model, not the display name).
    blacklist = {
        -- e.g. 'zentorno', 'somebrokenaddon',
    },

    -- ── ANTI-RECKLESS model list ────────────────────────────────────────────
    -- Any model listed here will ALWAYS drive calm and law-abiding, exactly like
    -- a native normal NPC — it can never roll reckless, and if it's an addon it's
    -- forced onto the 'safe' profile (see addon.safe* below) instead of the
    -- aggressive normal/reckless ones. Use for cars you want on the road for
    -- flavour but NOT ripping around (limos, vans, a friend's cruiser, etc).
    -- Case-insensitive spawn-name match. e.g. 'stretch', 'my_cruiser',
    antiReckless = {
    },

    -- ── REAL-CUSTOM detection (fixes "ninef2 flagged as addon") ─────────────
    -- qb-core tags a lot of BASE GTA cars as category 'sports' (ninef2 = Obey 9F
    -- Cabrio, comet, etc). Those are NOT real custom addons, so the spawner
    -- treats any name in `stockModels` as base-game — it can still show up as
    -- ordinary traffic, it just won't count toward the "custom addon" roster /
    -- tier buckets. If we ever misjudge a genuinely-custom car as stock, list it
    -- in `customModels` to force it back into the addon roster (that list wins).
    -- This is the base-game 'sports'/'super'/'sportsclassic' name set that shows
    -- up in QBShared.Vehicles; extend it if a base car still slips through.
    customModels = {
        -- e.g. 'myrealaddonthatlookslikestock',
    },
    stockModels = {
        -- sports
        'alpha','banshee','bestiagts','blista2','buffalo','buffalo2','buffalo3',
        'carbonizzare','comet2','comet3','comet4','comet5','coquette','coquette4',
        'drafter','elegy','elegy2','feltzer2','flashgt','furoregt','fusilade',
        'futo','gb200','italigto','jester','jester2','jester3','khamelion','kuruma',
        'kuruma2','lynx','locust','massacro','massacro2','neon','ninef','ninef2',
        'omnis','pariah','penumbra','penumbra2','raiden','rapidgt','rapidgt2',
        'raptor','revolter','ruston','schafter3','schafter4','schafter5','schwarzer',
        'sentinel3','seven70','specter','specter2','streiter','sultan','sultan2',
        'sultanrs','surano','tampa2','tropos','verlierer2','vstr','zr380','zr3802',
        'zr3803','issi7','paragon','paragon2','italirsx','komoda','jugular','neo',
        'sugoi','imorgon','cypher','calico','euros','rt3000','remus','vectre',
        'zr350','futo2','warrener2','tenf','tenf2','coquette5','panthere','corsita',
        -- super
        'adder','autarch','banshee2','bullet','cheetah','cyclone','entityxf',
        'entity2','fmj','gp1','infernus','italigtb','italigtb2','le7b','nero',
        'nero2','osiris','penetrator','pfister811','prototipo','reaper','sc1',
        'sheava','sultanrs','t20','taipan','tempesta','tezeract','turismor',
        'tyrant','vacca','vagner','vigilante','visione','voltic','voltic2','xa21',
        'zentorno','zorrusso','deveste','emerus','krieger','s80','thrax','tigon',
        'furia','gp1','tempesta','ignus','zeno','virtue','entity3','vagner',
        -- sportsclassic
        'ardent','btype','btype2','btype3','casco','cheetah2','coquette2',
        'coquette3','deluxo','dynasty','feltzer3','gt500','infernus2','jb700',
        'jb7002','mamba','manana','manana2','monroe','nebula','peyote','peyote2',
        'peyote3','pigalle','rapidgt3','retinue','retinue2','savestra','stinger',
        'stingergt','stromberg','swinger','toreador','torero','tornado','tornado2',
        'tornado3','tornado4','tornado5','tornado6','turismo2','viseris','z190',
        'ztype','zion3','cheburek','michelli','fagaloa','stalion','stalion2',
        -- muscle / a few common ones that get mis-tagged
        'dominator','dominator2','dominator3','gauntlet','gauntlet2','sabregt',
        'vigero','buccaneer','buccaneer2','nightshade','ellie','yosemite',
    },

    -- ── Addon car PERSONALITIES ─────────────────────────────────────────────
    -- Each addon car rolls a personality so the exotics on the road read like
    -- real, different drivers — some full-send racers, some overly-cautious
    -- law-abiding cruisers, most just a bit quicker than base traffic.
    --
    -- Driving-style bitflags (SetDriveTaskDrivingStyle) used below:
    --   StopForVehicles=1  StopForPeds=2  SwerveAroundVehicles=4
    --   SteerAroundStationary=8  SteerAroundPeds=16  SteerAroundObjects=32
    --   StopAtTrafficLights=128  UseBlinkers=262144
    --   Cautious 262331 = StopForVehicles+StopForPeds+SteerAroundStationary
    --            +SteerAroundPeds+SteerAroundObjects+StopAtTrafficLights(128)
    --            +blinkers, NO wrong-way — the rigid law-abiding cruiser.
    --   NormalCity 262317 = flow style but WITH StopAtTrafficLights(128), so a
    --            normal addon car obeys red lights in the city (only reckless
    --            runs them). On highways there are no lights so it's just flow.
    --   Reckless 262180 = shortest-path + swerve/avoid but NO StopForVehicles
    --            and NO StopAtTrafficLights(128) => RUNS RED LIGHTS + overtakes.
    addon = {
        -- Chances are rolled in order: reckless first, then cautious, else normal.
        -- (recklessChance + cautiousChance should stay well under 1.0.)
        -- recklessChance = how OFTEN a car is the "fast + runs reds but still safe"
        -- driver. User: "reckless should only appear ONCE IN A WHILE" → 0.08 → 0.04.
        -- cautiousChance: cautious is now a FAST clean driver (not slow), so having
        -- more of them is good — they're the best-behaving cars. Normal is now the
        -- same clean style too, so the normal/cautious split barely matters visually.
        recklessChance = 0.04,   -- rare fast-red-runner (still never hits anyone)
        cautiousChance = 0.35,   -- fast + cleanest driving; the bulk of good traffic

        -- BRAKE FORCE multiplier applied per-vehicle to ADDON cars only (user
        -- "make them brake earlier / brake properly"). Multiplies the car's stock
        -- fBrakeForce via SetVehicleHandlingFloat (per-vehicle override — does NOT
        -- affect the model globally, so players in the same car are untouched).
        -- 1.6 = 60% stronger brakes so a fast addon can actually shed speed for
        -- traffic/corners instead of overshooting. Combined with driver ability
        -- 1.0 (braking anticipation) this makes them brake sooner AND harder.
        -- Set to 1.0 to disable. Fast addons doing sudden stops? lower toward 1.3.
        brakeForceMult = 1.6,

        -- ACCELERATION multiplier applied per-vehicle to ADDON cars only (user
        -- "NPCs go retarded — accel too rapid for the AI; cap it 35-45% slower").
        -- A hypercar's launch force is more than the GTA driver AI can modulate: it
        -- stabs the throttle, snaps sideways / fishtails / overshoots, then panic-
        -- brakes. Multiplies the car's stock fInitialDriveForce (the accel force)
        -- via SetVehicleHandlingFloat (per-vehicle override — does NOT affect the
        -- model globally, so players in the same car are untouched). 0.60 = 40%
        -- slower acceleration → gentler pickup the AI can actually control, and it
        -- pairs with the brake logic (less speed built up = less to shed). Applied
        -- AFTER the 220 floor so capability is preserved; tier cruise caps still let
        -- them reach real speed on the straight, they just get there calmer.
        -- accelMult (fInitialDriveForce cut) was REMOVED in v2.4.24 — it capped TOP
        -- SPEED (weak engine can't beat drag → cars plateaued ~219, the "74/237"
        -- bug). We control acceleration via the GOVERNOR below instead, which limits
        -- the accel RATE without touching engine force, so cars still pull to their
        -- real top speed. Drive force is now left 100% stock. (knob intentionally gone)

        -- ── HORN BOOST (user: "npc getting horned at will drive faster") ────────
        -- When a PLAYER honks near/behind an addon NPC, that NPC gets a temporary
        -- speed + acceleration boost (Wangan "move over / race me" feel). Boost
        -- refreshes on each honk and fades hornBoostMs after the last one.
        hornBoost      = true,
        hornBoostMs    = 3500,    -- boost lasts this long after the last honk (ms)
        hornBoostMult  = 1.30,    -- raise the NPC's cruise target by this while boosted
        hornBoostAccel = 7.0,     -- accel rate (m/s²) while boosted — snappy getaway
        hornRange      = 30.0,    -- how close the honking player must be (m)
        hornAheadDot   = 0.30,    -- only honk-tag cars within this forward-cone of the player (1=dead ahead, 0=beside)
        -- HORN YIELD (v2.4.72 — user: "honked car in front should accelerate a bit
        -- OR pull to the side for the player to overtake, if no car forward/side
        -- blocking"). The boost above = "accelerate a bit"; this = "pull aside". When
        -- honked and a side lane is clear, the NPC eases to the RIGHT/slow lane (so
        -- the player passes on the left), same lateral slide the overtake uses.
        hornYield         = true,
        hornYieldMinKmh   = 25.0,  -- only pull aside above this (below = it's basically stopped in traffic)
        hornYieldPullMs2  = 3.5,   -- sideways accel toward the free lane (m/s²)
        hornYieldPullMaxMs= 4.0,   -- cap on the lateral speed (m/s)
        hornYieldPullOffset = 3.2, -- stop pulling once this far off its line (m ≈ one lane)

        -- ── ACCELERATION GOVERNOR (the real throttle fix, v2.4.19) ─────────────
        -- accelMult above only weakens the engine; the AI still floors it, so a
        -- powerful car is STILL twitchy at every speed (90/120/180/240). This caps
        -- the acceleration RATE directly, independent of power: each tick the
        -- commanded cruise target is never allowed more than accelRateMs2·dt above
        -- the car's CURRENT speed, so it can only accelerate at ~accelRateMs2 no
        -- matter how much power it has. Re-derived from actual speed each tick, so
        -- it's self-correcting (gentle ramp back up after any slowdown).
        --   accelRateMs2 = max acceleration in m/s². Reference: 3.0 ≈ 0→100 km/h in
        --   ~9s (calm), 4.5 ≈ ~6s (brisk), 2.0 ≈ ~14s (very gentle). Lower = calmer.
        --   accelHeadroomMs = tiny cruise headroom (m/s) so it keeps climbing smoothly.
        -- Raised 3.0→4.5 (v2.4.24, user "haven't seen them accelerate fast anymore")
        -- — brisker pickup that still tames the hypercar launch snap. Headroom up a
        -- touch so they don't stall just short of target and plateau.
        accelRateMs2   = 4.5,
        -- LOW-SPEED ACCEL BOOST (v2.4.36 — user: "they accelerate way too slow below
        -- ~40 km/h"). The flat accelRate makes pulling away from a stop / low-speed
        -- crawl feel sluggish. Below lowSpeedKmh we multiply the allowed accel so the
        -- getaway is snappy, then it tapers back to accelRateMs2 at higher speed.
        lowSpeedKmh      = 40.0,
        lowSpeedAccelMult = 2.0,
        -- BRAKE CRAWL FLOOR (v2.4.36 — user: "slowing to 6 km/h for blocked traffic;
        -- 15 km/h is a fine cap"). When bleeding for a lead we won't drop the cruise
        -- TARGET below this — so a car easing past blocked traffic keeps rolling at
        -- ~15 instead of crawling to a near-stop. EXCEPTION: if the gap gets
        -- critically small (< brakeMinGap) we still allow a full stop so it doesn't
        -- rear-end a genuinely stopped car right in front of it.
        brakeCrawlKmh    = 15.0,
        -- OPPOSITE-ROAD FILTER (v2.4.36 — user: "they slow for blocked traffic even
        -- on the opposite road; they shouldn't"). Ignore a scanned lead whose FORWARD
        -- vector opposes ours (facing the other way = oncoming / other carriageway).
        -- dot(ourFwd, theirFwd) below this = skip. -0.5 ≈ facing >120° apart, so we
        -- only drop clearly-opposite cars and still brake for perpendicular/merging.
        oncomingDot      = -0.5,
        -- REVERSE CAP (v2.4.38 — user: "cap ALL npc reverse at max 38 km/h, they
        -- reverse so fast"). Any addon car moving backward faster than this has its
        -- velocity scaled back to the cap each tick. Catches the stuck-recovery
        -- reverse AND any AI-initiated backing up.
        reverseCapKmh    = 38.0,
        -- FORWARD-BLOCKER FLAG range (v2.4.38): a car within this many metres
        -- directly ahead (in-lane) stamps meta.blockedAheadTs so the stuck-watchdog
        -- knows this car is WAITING for traffic, not wedged, and won't reverse it
        -- into the queue ("reverse for no reason while waiting for traffic" fix).
        blockAheadDist   = 9.0,
        -- REAR-BLOCKER range (v2.4.47 — user: "car reversed full and REARENDED"). A
        -- vehicle within this many metres directly BEHIND (in-lane) stamps
        -- meta.blockedBehindTs so rekickDriver refuses to reverse into it. Slightly
        -- tighter than the forward range since a 1s reverse doesn't travel far.
        rearBlockDist    = 8.0,
        -- CORNER SPEED GOVERNOR (v2.4.39 — user: "reckless cars dive around corners
        -- too fast and lose control; make the steering smoother"). Ease the commanded
        -- cruise DOWN as the front-wheel steering angle grows, so a car arrives at a
        -- bend already at a speed it can hold instead of yanking the wheel mid-corner
        -- (which overspeeds the tyres → the slide). Smoothed with an EMA so the lift
        -- is gradual. cornerStartDeg = don't touch small lane-hold steers; ramps to
        -- the min-factor floor by cornerMaxDeg. Reckless keeps a higher floor (still
        -- fast, just not out of control). Tune cornerMinFactor DOWN for more caution.
        cornerGovernor   = true,
        cornerMinKmh     = 45.0,   -- below this speed: no corner cut (low-speed turns are fine)
        cornerStartDeg   = 6.0,    -- steering angle (deg) where easing begins
        cornerMaxDeg     = 22.0,   -- steering angle where the full cut is reached
        cornerMinFactor  = 0.55,   -- hardest cruise cut (×) at full lock — non-reckless
        cornerMinFactorReckless = 0.68,  -- reckless floor (carries more corner speed by character)
        cornerEmaAlpha   = 0.25,   -- steer-angle smoothing 0..1 (lower = smoother/slower response)
        -- TIER-AWARE START ANGLE (v2.4.40 — "keep the safe ~125↔140 bounce as the
        -- base feel, but let the fast tiers stretch toward their real caps on clear
        -- straights"). The bounce is highway lane-hold micro-steer (2-6°) tripping
        -- the governor. These ADD to cornerStartDeg per tier, so a fast car ignores
        -- that gentle straight wobble (climbs to ~A 240 / S 370) but still governs in
        -- a REAL corner (steer past the raised start). Base/normal get 0 = safe band.
        cornerStartBonus = { S = 10.0, A = 6.0, B = 2.0 },
        cornerStartBonusReckless = 3.0,   -- extra for reckless on top of its tier bonus
        accelHeadroomMs = 1.0,
        -- COUNTER-STEER YAW DAMPER (v2.4.69 — user: "since we can't adjust how much
        -- the AI steers, can't we apply a COUNTER-steer force to offset the weird
        -- always-oversteer"). We can't change the AI's steering INPUT, but oversteer =
        -- the car's YAW (rotation about z) outrunning the direction it's actually
        -- travelling. So we read the angular velocity + the slip (nose-vs-velocity) and,
        -- when the car is yawing INTO a slide, scale the z angular velocity down — a
        -- direct counter-yaw torque, the software-ESC analog. This is applied via
        -- SetEntityAngularVelocity (does NOT touch the drive task / steering / brake),
        -- so the AI keeps its line but stops snapping into the always-oversteer spin.
        -- Only kicks in above a slip threshold + min speed so normal cornering yaw is
        -- untouched; strength ramps with slip angle. Grounded-only (never mid-air).
        counterSteer        = true,
        counterSteerMinKmh  = 40.0,   -- below this speed: no damping (parking/low-speed turns fine)
        counterSteerSlipDeg = 6.0,    -- only damp yaw once slip angle exceeds this (deg)
        counterSteerMaxSlip = 30.0,   -- slip angle at which damping reaches full strength
        counterSteerGain    = 0.45,   -- max fraction of excess yaw removed per tick (0..1); higher = firmer
        counterSteerYawMin  = 0.15,   -- ignore tiny yaw rates (rad/s) so straight-line jitter isn't touched
        -- STEER VELOCITY SCRUB (v2.4.66 → REBUILT v2.4.67 — user: "the smooth velocity
        -- reduce didn't kick in. it should apply for cornering, TURNING and OVERTAKING
        -- too — in fact ANY steering input from the NPC should deduct VELOCITY, but
        -- must NOT use the brake; a direct entity velocity slowdown"). v2.4.66 gated
        -- this on the corner GOVERNOR's meta.cornering flag (high tier start-angles →
        -- rarely tripped) so it almost never fired. Now it reads the RAW steering angle
        -- every tick, independent of the governor: past cornerScrubStartDeg it derives
        -- a speed FACTOR (1.0 → cornerScrubMinFactor by cornerScrubMaxDeg) and eases the
        -- horizontal velocity toward spd×factor at cornerScrubRate m/s². Covers corners,
        -- turns AND overtake lane-changes (all steering). NO brake pulse — pure velocity
        -- bleed. Same grounded + near-flat + horizontal-only + never-airborne safety as
        -- the curve-bust. Replicated on a hkscn_scrub statebag for the debug overlay.
        cornerScrub          = true,
        -- v2.4.75 (user "the velocity decrease for every moment needs to be 25%
        -- stronger"): bled rate 12.0 → 15.0 (+25%). Applies to the corner/turn/
        -- overtake velocity scrub everywhere — cars shed speed for any steer input
        -- a quarter faster/harder now.
        cornerScrubRate      = 15.0,  -- how hard to bleed velocity for a steer (m/s²); higher = slows sooner/harder
        cornerScrubMinKmh    = 55.0,  -- only scrub above this speed (low-speed turns don't need it)
        cornerScrubStartDeg  = 4.0,   -- steering angle (deg) where the scrub begins (low = catches gentle turns)
        cornerScrubMaxDeg    = 22.0,  -- steering angle where the full cut is reached
        cornerScrubMinFactor = 0.45,  -- hardest velocity cut (× current speed) at full lock; lower = slows more
        cornerScrubEmaAlpha  = 0.35,  -- steer-angle smoothing 0..1 (higher = snappier response)

        -- ── CORNER-APPROACH SLOWDOWN (v2.4.75, user: "when an NPC wants to go into
        -- a corner make them slow too, if we aren't already") ──────────────────
        -- The corner GOVERNOR + SCRUB above are both REACTIVE — they only cut speed
        -- once the wheel is ALREADY turning, so a fast car still arrives at the bend
        -- too hot and yanks the wheel mid-corner. This is the missing ANTICIPATION
        -- layer: sample the ROAD AHEAD along the car's path and, if it bends, ease
        -- the cruise target DOWN before the car reaches it — like a real driver
        -- lifting off on corner approach. Uses GetVehicleNodeProperties heading at a
        -- speed-scaled lookahead point vs the car's current heading; the bigger the
        -- upcoming heading change, the more it pre-slows. Throttled (not every tick)
        -- since node queries aren't free. Feeds the SAME cruise-cap the governor
        -- uses, so the two compose (approach pre-slows, governor/scrub handle the
        -- apex). Set cornerApproach=false to disable.
        cornerApproach        = true,
        cornerApproachEveryMs = 250,   -- how often to sample the road ahead (ms); cheap-throttle node queries
        cornerApproachMinKmh  = 50.0,  -- below this speed, don't bother (city crawl handles itself)
        cornerApproachBaseM   = 22.0,  -- base lookahead distance (m) added to the speed-scaled part
        cornerApproachTimeS   = 1.6,   -- seconds-ahead: lookahead = base + speed × this (fast cars look further)
        cornerApproachStartDeg= 12.0,  -- upcoming heading change (deg) where pre-slow begins
        cornerApproachMaxDeg  = 70.0,  -- heading change where the full pre-slow floor is hit
        cornerApproachMinFactor = 0.55,-- hardest cruise pre-cut (×) for a sharp upcoming bend; lower = slower approach
        cornerApproachMinFactorReckless = 0.70,  -- reckless carries more speed into the approach (matches governor character)

        -- ── ACTIVE BRAKE ASSIST (addon cars brake for traffic ahead, NO SLIDE) ──
        -- v2.4.17 rewrite (user: "it brakes but SLIDES the car"). Root cause was a
        -- full foot-brake stamped inside a fixed 55 m window — way inside the real
        -- braking distance at 250 km/h (grows with v²) → wheels lock → slide. Now:
        --   1. SPEED-SCALED LOOKAHEAD: scan = v²/(2·decel) + reaction gap, so the
        --      car sees the obstacle far enough out to shed speed gently.
        --   2. BLEED SPEED FIRST: primary brake is a smooth cruise-cap reduction
        --      toward the lead car's speed — the drive task lifts throttle / brakes
        --      GENTLY on its own, car stays planted (no lock). This = "brake early".
        --   3. FOOT BRAKE = last resort, SHORT PULSES only (never held, never the
        --      handbrake) once genuinely inside stopping distance + still closing.
        brakeAssist    = true,    -- master switch (false = physics brakeForceMult only)
        brakeTickMs    = 140,     -- how often the drive tick runs (ms). PERF: higher = cheaper,
                                  --   lower = snappier braking. 120-160 is a good range.
        brakeDecel     = 6.5,     -- assumed comfortable decel (m/s²) for gap + lookahead math.
                                  --   LOWER = brakes earlier/gentler, higher = later/harder.
        brakeReactBuffer = 1.0,   -- extra seconds of following gap baked into the math.
        brakeMinGap    = 6.0,     -- always try to keep at least this gap to the lead car (m).
        brakeScanMax   = 220.0,   -- hard cap on how far ahead we scan (m) — covers ~250 km/h.
        -- DETECTION = FRONT NOSE ONLY (user: "detect actual front forward nose, not
        -- the side or behind"). Behind is already excluded (forward-dot > 0). This
        -- half-width decides how wide "in front of me" is: 3.2 counted adjacent
        -- lanes (braked for cars beside it). 1.6 ≈ one car width = only something
        -- directly ahead in MY lane. Lower = stricter nose-only.
        brakeLaneHalf  = 1.6,     -- count a car "ahead of my nose" within this half-width (m)
        -- ── BRAKE FEEL (user: "longer, slower, gentler at mid speed; stronger at
        -- high speed; the hard pulse comes too fast/short/strong") ────────────────
        -- The hard foot-brake pulse is what feels abrupt. We now ONLY use it above
        -- brakeHardMinKmh — below that it's pure smooth cruise-bleed (gentle, no
        -- stab). Pulse duration scales with speed (longer at high speed = the
        -- "stronger on higher speed" ask) and the bleed zone is wider so onset is
        -- earlier and more gradual.
        brakeHardMinKmh = 95.0,   -- below this speed: NEVER hard-pulse, only smooth bleed
        brakeBleedZone  = 3.0,    -- bleed starts at safeGap × this (bigger = earlier/gentler onset)
        brakePulseMinMs = 70,     -- hard-pulse duration at brakeHardMinKmh (short/light)
        brakePulseMaxMs = 260,    -- hard-pulse duration at very high speed (longer/stronger)
        brakePulseMaxAtKmh = 300.0, -- speed at which pulse reaches brakePulseMaxMs
        -- PERF: only run the (expensive) brake scan for addon cars within this range
        -- of the PLAYER. Farther cars still get the cheap accel governor so they stay
        -- sane, they just don't scan for traffic you can't see. Covers on-screen +
        -- the ahead-spawn zone. Lower = cheaper but cars pop in already-braking later.
        brakeActiveDist = 350.0,

        -- OVERTAKE-WHEN-STUCK: if a non-reckless addon car sits in the gap-hold
        -- brake state while crawling (< overtakeSlowKmh) for longer than
        -- overtakeStuckMs, it opens an overtake window (overtakeMs) where it swaps
        -- to the swim-through style + ignores the brake-hold so it pulls out and
        -- passes instead of getting stuck behind slow/stopped traffic. A per-car
        -- cooldown stops it chain-overtaking forever.
        overtakeWhenStuck = true,
        overtakeStuckMs   = 3500,    -- gap-held + crawling this long → overtake (fallback if range unset)
        -- RANDOM gap-hold threshold (v2.4.35 — user: "gap-held 3-6s random → overtake").
        -- Each time a car starts gap-holding, it rolls a fresh threshold in this range,
        -- so cars pull out staggered instead of all at once.
        overtakeStuckMinMs = 3000,
        overtakeStuckMaxMs = 6000,
        overtakeMs        = 5000,    -- how long the overtake burst lasts (user: 5s)
        overtakeSlowKmh   = 35.0,    -- "crawling" threshold — below this while held counts as stuck
        overtakeCooldownMs = 6000,   -- min gap between overtakes for the same car
        overtakeStyle     = 262206,  -- swim-through style used during the burst (= recklessStyle)

        -- FLICK → OVERTAKE (user: "when it's been flicking between driving and
        -- braking a few times (6-8), just go overtake mode for 5s"). The brake
        -- assist oscillates when a lead car sits just inside the bleed zone:
        -- brake → release → task steers at the gap → brake again. That rapid
        -- on/off IS the "spam braking" + the "slidy" steering. Instead of only
        -- the time-based trigger above, we COUNT brake rising-edges; once a car
        -- racks up overtakeFlickCount flicks within overtakeFlickWindowMs, we
        -- commit to a clean overtake window (same overtakeMs burst). Committing
        -- to ONE behaviour is what stops the oscillation.
        overtakeFlickCount     = 6,      -- brake on/off flicks before we force an overtake
        overtakeFlickWindowMs  = 4000,   -- flicks must happen within this window to count
        -- SIDE-LANE CLEARANCE (v2.4.68 — user: "when gap-hold flickers a few times, go
        -- overtake / to the side lane IF POSSIBLE"). Both overtake triggers (flick +
        -- time-based gap-hold) now only commit the pass when an adjacent lane is
        -- actually free — otherwise the car stays braking behind the lead and re-checks
        -- until a lane opens. A nearby car counts as blocking the side if it sits in the
        -- lateral band [otSideInner, otSideOuter] on that side AND longitudinally within
        -- otSideAhead ahead or otSideBehind behind (a car just behind can still catch
        -- up). LEFT is preferred (normal passing side), RIGHT is the fallback.
        overtakeSideInner   = 2.2,   -- inner edge of the adjacent lane (m from our centreline)
        overtakeSideOuter   = 6.5,   -- outer edge of the adjacent lane (m)
        overtakeSideAhead   = 28.0,  -- required clear distance ahead in the target lane (m)
        overtakeSideBehind  = 12.0,  -- required clear distance behind in the target lane (m)
        -- LATERAL PULL (v2.4.71 — user: "overtake shows OVERTAKE-L but the car never
        -- steered"). The stock swim-through style alone doesn't reliably move the car
        -- out, so we ADD a direct sideways velocity toward the chosen side (L/R from
        -- sideLaneClear) for the burst, exactly like the scrub/curve-bust do speed.
        -- Bounded to ~one lane so it eases over then holds, never drifts off-road.
        overtakePull        = true,  -- false = style-only (old behaviour)
        overtakePullMs2     = 3.5,   -- sideways accel added toward the target side (m/s²)
        overtakePullMaxMs   = 4.0,   -- cap on the lateral speed component (m/s ≈ how fast it slides over)
        overtakePullOffset  = 3.2,   -- stop pulling once this far off the original line (m ≈ one lane)
        -- STEERING TAME during overtake (user: "sliding/hard-steer with a car
        -- ahead"). The swim-through style yanks the wheel hard at speed = the
        -- slide/flip. During the burst we crank driver ABILITY to max (smooth,
        -- anticipatory steering) and drop aggression so it flows around the lead
        -- instead of snapping into it. Restored when the window ends.
        overtakeAbility        = 1.0,
        overtakeAggression     = 0.0,
        -- OVERTAKE SLIDE FIX (v2.4.32 — user: "the overtake works but many times it
        -- still slides, needs more assistance"). Root cause: during an overtake
        -- finalCruise = full accelCeil (we ignore the brake target so it commits to
        -- the pass), so a swim-through lane-change happens at 150-200+ km/h — and a
        -- hard swerve at that speed slides no matter the grip. Three aids:
        --   1. SPEED CAP: clamp the overtake cruise so the actual lane-change is at
        --      a controllable speed. It still passes (faster than the lead it's
        --      stuck behind), just not at full send.
        overtakeMaxKmh         = 110.0,  -- hard ceiling on commanded cruise while overtaking
        --   2. EXTRA GRIP: pile on more traction for the duration of the window,
        --      restored on exit. Multiplies the ALREADY-boosted spawn grip.
        overtakeGripBoost      = 1.30,   -- ×current traction while overtaking (on top of tcGripBoost)
        --   3. EARLIER TC CUT: while overtaking, trip the anti-spin throttle-cut at
        --      a smaller slip angle so it catches the slide before it develops.
        overtakeSlipDeg        = 14.0,   -- (vs the normal tcSlipDeg 22°) tighter while passing

        -- CURVE-BUST (v2.4.30 — the REAL fix for the hard ~125 cap): the AI angle
        -- →speed curve in data/ai_handling.meta NEVER loaded (the FIVEM_LOVES_YOU
        -- mounter does not override the stock CAIHandlingInfoMgr SPORTS_CAR curve,
        -- confirmed: an addon car caps at ~125 on an EMPTY DEAD-STRAIGHT road even
        -- after a full server restart). Stock curve pins ~35 m/s (126 km/h) the
        -- instant a driver micro-steers 2-6° for lane-hold, so no Lua cruise value
        -- can beat it via the drive task. Fix: when a car is on a CLEAR road (no
        -- lead in the brake scan), not braking/overtaking, and its governed target
        -- is above the cap but it's pinned near ~125 and not climbing, we nudge its
        -- forward speed directly with SetVehicleForwardSpeed toward the governed
        -- target. The accel GOVERNOR still owns the rate (we step by the same
        -- accelRate·dt), so this is smooth — it just routes around the engine's
        -- angle-curve ceiling instead of asking the drive task (which obeys it).
        curveBust        = true,
        curveBustAboveKmh = 118.0,   -- only kick in above here (the cap band)
        curveBustClearOnly = true,   -- require a clear road ahead (no lead car) to nudge
        -- CURVE-BUST RAMP RATE (v2.4.66 — user: "the acceleration rate is too rapid,
        -- tune it down"). The v2.4.65 ratchet climbed at the full accelRateMs2 (4.5)
        -- governor rate, which felt too aggressive up at high speed. This is a
        -- SEPARATE, gentler accel (m/s²) used ONLY by the curve-bust ratchet above the
        -- cap band, so the low-speed 0→118 pickup keeps its brisk 4.5 while the
        -- high-speed climb to the tier cap is a calmer stretch. Lower = gentler.
        curveBustAccelMs2 = 2.2,
        -- CURVE-BUST SAFETY (v2.4.34 — user: "the way we apply force still sends cars
        -- airborne / shooting up"). SetVehicleForwardSpeed pushes along the car's
        -- FORWARD vector — if the nose is pitched up (crest, bump, kerb, ramp) the
        -- push goes partly UP and the car launches. Fixes: (1) only nudge when the
        -- car is grounded on all wheels, (2) only when the nose is near-flat
        -- (|pitch| < curveBustMaxPitch), (3) apply the nudge HORIZONTALLY and keep
        -- the car's existing vertical velocity (gravity) untouched so we never add
        -- upward speed.
        curveBustGroundedOnly = true,
        curveBustMaxPitch = 12.0,    -- degrees; skip the nudge on steeper slopes
        -- RED-LIGHT / JUNCTION YIELD (v2.4.48 — user: "braking fast for a red light
        -- they mostly brake AFTER the line"). No native reads a light's phase, so we
        -- detect the NATIVE AI's own yield instead: on a CLEAR road (no lead car,
        -- not cornering/sliding/overtaking, near-flat ground) the car is slowing on
        -- its OWN while WE'RE still commanding more speed → it's yielding for a
        -- red/junction. We then stop pushing (kills the curve-bust + accel command)
        -- and shed the extra speed with a soft straight brake so the stop lands
        -- BEFORE the line. Set redLightYield=false to disable entirely.
        redLightYield    = true,
        redYieldMinKmh   = 30.0,     -- ignore below this (low-speed stops are fine)
        -- v2.4.63 CEILING: NEVER treat deceleration as a red-light yield above this
        -- speed. The bug (user "cars cap ~153, drive safe then suddenly fast, won't
        -- accelerate on clear road"): above curveBustAboveKmh (118) the curve-bust
        -- fights the stock AI angle-curve every tick — the curve dragging the car
        -- back READS as self-deceleration while we command MORE speed, so the yield
        -- detect false-tripped on open highway → killed the curve-bust + brake-pulsed
        -- → car slowed → signal cleared → curve-bust slammed it back up → oscillated
        -- around ~153. Real red-light approaches happen at MODERATE speed (you slow
        -- BEFORE the junction), so gate the whole detector below this. Must sit at/
        -- below curveBustAboveKmh so the two systems never overlap.
        redYieldMaxKmh   = 110.0,    -- above this speed: yield-detect OFF (open-road priority)
        redYieldDecelMs2 = 1.8,      -- native self-decel (m/s²) that counts as a yield (raised 1.2→1.8: firmer)
        redYieldTicks    = 3,        -- consecutive ticks required (raised 2→3: kills the curve-bust tug)
        redYieldMaxPitch = 12.0,     -- degrees; above this we assume it's an uphill, not a yield
        redYieldActiveBrake = true,  -- also fire a straight brake pulse (false = just stop pushing)
        -- SURFACE MAGNET (gentle!): a small downward pull while grounded + fast so
        -- addon cars settle onto the road instead of getting light/skippy at speed.
        -- Deliberately WEAK (user: "don't be harsh on stick-to-surface, it fucks
        -- up") — a gravity-only nudge, and it NEVER fires when airborne (that would
        -- slam the car down). Set stickForce 0 to disable.
        stickToSurface   = true,
        stickForce       = 2.5,      -- downward accel (m/s²) added while grounded+fast. Small!
        stickMinKmh      = 60.0,     -- only below-the-radar downforce above this speed

        -- ABS / TC HELPER (v2.4.31 — user: "NPC vehicles need even more ABS and TC
        -- help NOW, to avoid too many spawned cars being retarded/crashed"). NPC
        -- drivers get no stability aids, so addon hypercars at 150-250 km/h light up
        -- the rears / spin out / understeer into walls = the "retarded" pile-ups.
        -- Two cheap aids applied per addon car:
        --   1. GRIP FLOOR at spawn: bump fTractionCurveMax/Min a bit so the tyres
        --      hold at speed (a permanent per-vehicle handling tweak, reverted on
        --      hijack alongside brakeForce). This is the "TC" — power can't overwhelm
        --      grip as easily.
        --   2. ANTI-SPIN TC in the tick: if the car is sliding (its velocity vector
        --      diverges from where it's pointing by > tcSlipDeg) we briefly cut the
        --      commanded cruise (ease off throttle) so it hooks back up instead of
        --      spinning — mimics a traction-control throttle cut.
        --   3. ABS: the straight-line brake temp actions already give ABS-like
        --      non-locking braking; tcBrakeEase additionally trims brake target when
        --      sliding so a panic stop doesn't pitch it sideways.
        absAssist        = true,
        tcGripBoost      = 1.35,   -- ×fTractionCurveMax/Min at spawn (1.0 = stock). Higher = more grip.

        -- FORCE-AWD (v2.4.70): convert every spawned addon car to a balanced
        -- all-wheel-drive so the aid-less AI stops spinning the rears / over-
        -- rotating. Per-vehicle only (reverted to the real drivetrain on hijack).
        forceAwd         = true,   -- false = leave each car's stock drivetrain alone
        awdDriveBias     = 0.5,    -- fDriveBiasFront target: 0.5 = even AWD, >0.5 = more FWD-ish, <0.5 = more RWD-ish

        -- WINDOW TINT (v2.4.76 — user: "make every addon car always spawn with light
        -- smoke / dark smoke / pure-black window tint, always"). SetVehicleWindowTint
        -- enum: 0=None, 1=Pure Black, 2=Dark Smoke, 3=Light Smoke, 4=Stock/limo, etc.
        -- We pick one at random from windowTints on EVERY addon spawn (driving fleet
        -- AND parked-swap) so the whole curated fleet always reads as tinted. Set
        -- forceWindowTint=false to leave stock glass; edit windowTints to restrict the
        -- pool (e.g. { 1 } for pure black only).
        forceWindowTint  = true,
        windowTints      = { 1, 2, 3 },   -- pure black / dark smoke / light smoke

        tcSlipDeg        = 22.0,   -- slide angle (deg between heading & velocity) that triggers the throttle cut
        tcCutFactor      = 0.55,   -- multiply commanded cruise by this while sliding (throttle ease-off)
        tcMinSpeedKmh    = 45.0,   -- only run anti-spin above this speed (low-speed slides are harmless)

        -- NORMAL addon car: was "retarded" (style 262317 had SwerveAroundVehicles(4)
        -- = erratic lane-jinking AND lacked StopForPeds(2) = hit people). Switched to
        -- the SAME good style the cautious driver uses (262331: StopForVehicles(1) +
        -- StopForPeds(2) + SteerAroundPeds(16) + SteerAroundStationary(8) +
        -- SteerAroundObjects(32) + StopAtTrafficLights(128) + blinkers) — brakes for
        -- and actively STEERS AROUND cars/peds, no reckless swerve. Just faster than
        -- cautious in feel, but same clean, safe behaviour. Speed bumped a bit too.
        speedMult    = 1.15,
        normalStyle  = 262331,   -- calm+safe (steers around peds/cars), stops at lights

        -- CAUTIOUS addon car: user says this has the BEST driving style — make it
        -- FAST. Same clean style (262331: actively steers around peds/cars, stops at
        -- every light). Was 0.70 (crawled ~119 km/h — the "utopia capped at 13x"
        -- bug when a hypercar rolled cautious). Now cruises like a brisk normal car.
        cautiousSpeedMult  = 1.15,     -- was 0.70 (way too slow); now proper speed
        cautiousAggression = 0.05,
        cautiousStyle      = 262331,   -- stop+steer-around everything + lights, no swerve

        -- SAFE profile: applied to any model in the top-level `antiReckless` list.
        -- These cars ALWAYS drive like a calm native normal NPC — never reckless,
        -- never the aggressive addon profile, and not cautious-slow either. Normal
        -- speed, low aggression, full lane-keep + stop-for-everything style.
        safeSpeedMult  = 1.0,          -- 1.0 = same cruise as base traffic
        safeAggression = 0.05,
        safeStyle      = 262315,       -- StopForVehicles+Peds+lights, no swerve

        -- STRAIGHT-LINE BRAKE STYLE (v2.4.25, THE weave fix): user found the "slide"
        -- was actually the car STEERING while braking — the follow style has
        -- SteerAroundStationary(8)+SteerAroundObjects(32), so as it slows for the car
        -- ahead the AI tries to steer AROUND it → left-right weave at ALL speeds.
        -- While braking (non-reckless) we swap to THIS style: drops steer-around-
        -- vehicles/objects, so it brakes DEAD STRAIGHT and just queues behind.
        -- 262291 = 1(StopForVehicles)+2(StopForPeds)+16(SteerAroundPeds)+
        -- 128(StopAtTrafficLights)+262144(blinkers). Keeps ped safety (won't hit
        -- peds), removes the vehicle-jink. Reckless is EXEMPT (it's meant to weave).
        brakeStraightStyle = 262291,

        -- RECKLESS addon car: fast + runs reds, and NOW "swims through traffic"
        -- (user: "make reckless have swerving steer-around-cars so it can overtake
        -- and swim through traffic"). This is the ONE persona allowed the swerve.
        -- 262206 = 2(StopForPeds)+4(SwerveAroundVehicles)+8(SteerAroundStationary)+
        -- 16(SteerAroundPeds)+32(SteerAroundObjects)+262144(blinkers). NOTE: NO
        -- StopForVehicles(1) and NO StopAtTrafficLights(128) → it flows THROUGH
        -- traffic swerving around cars + runs reds, but StopForPeds+SteerAroundPeds
        -- stay so it still never hits a pedestrian. Not exempted from brake assist,
        -- but once it swerves the lead leaves its nose-cone so braking releases —
        -- brakes only if truly boxed in.
        recklessSpeeds     = { 220, 270, 320, 360 },   -- super fast (tier-cap + real top still gate)
        recklessAggression = 0.05,     -- CALM: swerves to pass, does not RAM
        recklessStyle      = 262206,   -- swim-through-traffic overtaker (see above)
    },

    -- Respect hk-optimizer "potato" modes: if a player picked the lowest FPS
    -- preset, skip the highway spawner (behaviour tuning still runs, it's cheap).
    honorOptimizer = true,
}
