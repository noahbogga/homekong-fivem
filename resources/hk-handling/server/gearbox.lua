-----------------------------------------------------------------
-- hk-handling :: server/gearbox.lua
-- Server side of the gearbox system. MODEL-based presets in the `hk_handling`
-- table; flagging a model affects EVERY instance of that vehicle. Keyed by
-- model hash (clean unsigned 32-bit). The `name` column is COSMETIC and is
-- never matched at runtime.
--
-- PUBLIC gearbox numbering (manualType), see sql/hk_handling.sql + gearratiomode.md:
--   0 our automatic (default) | 1 manual | 2 Automatic (Paddle) — torque-converter auto+paddle
--   3 Sport DCT | 4 Super DCT | 5 sequential | 6 GTA-native (debug, not processed)
--   forcePaddle : DCT only — 0 normal / 1 force-paddle / 2 force-auto
--   gearRatioMode : 0 default / 1 sport / 2 drag / 3 hypercar (PHASE 2 feel)
--
-- Loaded once on resource start; pushed to clients so they match locally by
-- GetEntityModel (no per-vehicle DB hits). NOTE: ALL rows are loaded now (type 0
-- "our automatic" is a real, meaningful preset — it forces our auto even where the
-- no-row default wouldn't, and type 6 overrides the car-class default to native).
-----------------------------------------------------------------

local QBCore = nil
pcall(function() QBCore = exports['qb-core']:GetCoreObject() end)

-- ADMIN-COMMAND NOTIFICATIONS. The gameplay gear-MODE toasts (the DCT auto<->manual popup
-- etc.) were removed on the client side, but ADMIN command feedback — /setgear /gearratio
-- /setspeed usage, errors, and success results — SHOULD still show (user request). This
-- shim keeps the old (event, src, msg, type) call signature but routes to ox_lib's
-- top-right toast (consistent with the rest of the notify migration), falling back to the
-- legacy QBCore event if ox_lib isn't present. So all 30+ call sites light up again with
-- one change here. type: 'error' | 'success' | 'primary' -> ox 'error'/'success'/'inform'.
local function adminNotify(_, src, msg, ntype)
    if not src or src == 0 or not msg then return end   -- console/no-target: F8 print already covers it
    local oxType = (ntype == 'error' and 'error') or (ntype == 'success' and 'success') or 'inform'
    if GetResourceState('ox_lib') == 'started' then
        TriggerClientEvent('ox_lib:notify', src, { title = 'Gearbox', description = tostring(msg), type = oxType, position = 'top-right' })
    else
        TriggerClientEvent('QBCore:Notify', src, msg, ntype or 'primary')
    end
end

-- hash (number) -> { type = int(0-6), paddle = 0/1/2, ratio = 0-3 }
local presetModels = {}
-- normal learner blend state: [hash] = { candidates = {} }
local normalLearnState = {}

-----------------------------------------------------------------
-- MODE HELPERS — read Config.Gearbox.Mode at call time.
local function gearboxMode()
    local m = Config.Gearbox and Config.Gearbox.Mode or 'normal'
    m = tostring(m):lower()
    if m ~= 'easy' and m ~= 'normal' and m ~= 'expert' then return 'normal' end
    return m
end
local function isEasy()   return gearboxMode() == 'easy'   end
local function isNormal() return gearboxMode() == 'normal' end
local function isExpert() return gearboxMode() == 'expert' end

-- Seed-on-sit dedupe: models we've already auto-rowed this session (admin convenience).
local seeded = {}

-----------------------------------------------------------------
-- DB LOAD
-----------------------------------------------------------------
local function loadPresetModels()
    local rows = MySQL.query.await(
        'SELECT hash, manualType, forcePaddle, gearRatioMode, speedCal, speedCalC, ' ..
        'hybridClass, evTorque, hybridCap, speedoStyle, turboDefault, wheelieLaunch FROM hk_handling')
    presetModels = {}
    if rows then
        for _, r in ipairs(rows) do
            local h = math.tointeger(r.hash) or tonumber(r.hash)
            if h then
                presetModels[h] = {
                    type  = r.manualType or 0,
                    paddle = r.forcePaddle or 0,
                    ratio = r.gearRatioMode or 0,
                    speedCal  = r.speedCal,            -- raw "kmh,s;" targets (re-edit source)
                    speedCalC = r.speedCalC,           -- packed per-band factor BIGINT (hot tick)
                    -- NULL/nil = UNSET -> the client falls back to the config Hybrid.Models
                    -- list (so the built-in PHEV list drives cars with no explicit /sethybrid).
                    -- Only 0/1/2 are explicit: 0 = /sethybrid none (force plain ICE), 1 = full
                    -- PHEV, 2 = semi/KERS. Do NOT coerce nil->0 here or the config list dies.
                    hybridClass = r.hybridClass,       -- nil | 0 none | 1 full PHEV | 2 semi (KERS)
                    evTorque    = r.evTorque,          -- ×100: class1=PowerFrac, class2=boost mult (nil=default)
                    hybridCap   = r.hybridCap,         -- full-PHEV e-mode cap km/h (nil=config default)
                    speedoStyle = r.speedoStyle,       -- nil = derive from class | 0 full | 1 semi (look override)
                    -- NULL/nil = UNSET -> client falls back to the config Turbo.DefaultModels roster.
                    -- Only 0 (NA) / 1 (turbo) are explicit /setturbo overrides. FEEL-only flag.
                    turboDefault = r.turboDefault,     -- nil = roster | 0 NA | 1 turbo-by-design
                    -- NULL/nil = UNSET -> client falls back to the muscle class gate for the launch
                    -- wheelie. Only 0 (force off) / 1 (force on) are explicit /setwheelielaunch overrides.
                    wheelieLaunch = r.wheelieLaunch,   -- nil = class default | 0 off | 1 on
                }
            end
        end
    end
    return presetModels
end

-- Broadcast the model map to all clients (or one). Keys are stringified for
-- transport safety (large/negative model hashes survive JSON as strings).
local function pushModels(target)
    local out = {}
    for h, v in pairs(presetModels) do
        out[tostring(h)] = { type = v.type, paddle = v.paddle or 0, ratio = v.ratio or 0,
                             speedCal = v.speedCal, speedCalC = v.speedCalC,
                             -- keep nil UNSET (config fallback); only 0/1/2 are explicit.
                             hybridClass = v.hybridClass, evTorque = v.evTorque,
                             hybridCap = v.hybridCap, speedoStyle = v.speedoStyle,
                             -- keep nil UNSET (roster fallback); only 0 (NA) / 1 (turbo) explicit.
                             turboDefault = v.turboDefault,
                             -- keep nil UNSET (class default); only 0 (off) / 1 (on) explicit.
                             wheelieLaunch = v.wheelieLaunch }
    end
    TriggerClientEvent('hk-handling:gearbox:syncModels', target or -1, out)
end

-----------------------------------------------------------------
-- PERMISSION — QBCore admin OR ACE-allowed (cfx server-account login = ACE).
-----------------------------------------------------------------
local function isAdmin(src)
    if src == 0 then return true end  -- server console
    if IsPlayerAceAllowed(src, 'hkgearbox.setmanual') or IsPlayerAceAllowed(src, 'command') then
        return true
    end
    if QBCore and QBCore.Functions and QBCore.Functions.HasPermission then
        if QBCore.Functions.HasPermission(src, 'admin')
        or QBCore.Functions.HasPermission(src, 'god') then
            return true
        end
    end
    return false
end

local USAGE = 'Usage: /setgear <type|remove> [forcePaddle 0/1/2] | types: ' ..
              '0=NEW-auto 1=manual 2=autoPaddle 3=sportDCT 4=superDCT 5=sequential 6=GTA-native(debug)'

-----------------------------------------------------------------
-- ADMIN COMMAND: /setgear <type|remove> [forcePaddle]
-- Flags the MODEL of the admin's current vehicle (all instances).
--   'remove' / 'clear' / 'none' -> delete the row (revert to default behaviour:
--       car classes fall back to our-auto, non-cars to GTA native).
-----------------------------------------------------------------
RegisterCommand('setgear', function(src, args)
    if not isAdmin(src) then
        adminNotify('QBCore:Notify', src, 'No permission', 'error')
        return
    end
    if not args[1] then
        adminNotify('QBCore:Notify', src, USAGE, 'error')
        return
    end

    -- removal keyword
    local a1 = tostring(args[1]):lower()
    if a1 == 'remove' or a1 == 'clear' or a1 == 'none' then
        TriggerClientEvent('hk-handling:gearbox:requestModel', src, -1, 0)  -- -1 = remove sentinel
        return
    end

    local mtype = tonumber(args[1])
    if not mtype then
        adminNotify('QBCore:Notify', src, 'Invalid type "' .. tostring(args[1]) .. '". ' .. USAGE, 'error')
        return
    end
    mtype = math.floor(mtype)
    -- Validate against known modes. 0-6 are all real now (0 = our auto, not "remove").
    local labels = (Config.Gearbox and Config.Gearbox.ModeLabels) or {}
    if labels[mtype] == nil then
        adminNotify('QBCore:Notify', src, 'Unknown gear type ' .. mtype .. '. ' .. USAGE, 'error')
        return
    end
    -- forcePaddle: 0 normal / 1 force-paddle / 2 force-auto (DCT only; ignored on non-DCT client-side)
    local paddle = math.floor(tonumber(args[2] or '0') or 0)
    if paddle < 0 or paddle > 2 then paddle = 0 end
    -- ask the admin's client for the model hash/name of the car they're in
    TriggerClientEvent('hk-handling:gearbox:requestModel', src, mtype, paddle)
end, false)

-- Client replies with the resolved model info + desired settings.
-- mtype == -1 is the REMOVE sentinel (delete the row).
RegisterNetEvent('hk-handling:gearbox:setModel', function(hash, model, name, mtype, paddle)
    local src = source
    if not isAdmin(src) then return end
    hash = math.tointeger(hash) or tonumber(hash)
    if not hash then
        adminNotify('QBCore:Notify', src, 'Not in a vehicle', 'error')
        return
    end
    hash = hash & 0xFFFFFFFF   -- clean unsigned 32-bit (no negatives in DB)
    mtype = math.floor(tonumber(mtype) or -99)

    if mtype == -1 then
        -- REMOVE the row entirely (revert to default behaviour).
        MySQL.update.await('DELETE FROM hk_handling WHERE hash = ?', { hash })
        presetModels[hash] = nil
        pushModels()
        adminNotify('QBCore:Notify', src, (name or model or hash) .. ' -> preset removed (default)', 'success')
        print(('[hk-gearbox] %s removed preset for model %s (%s)')
            :format(GetPlayerName(src) or src, name or model, hash))
        return
    end

    -- Validate type here too (defense in depth — this event is net-triggered).
    local labels = (Config.Gearbox and Config.Gearbox.ModeLabels) or {}
    if labels[mtype] == nil then
        adminNotify('QBCore:Notify', src, 'Invalid gear type', 'error')
        return
    end
    if isEasy() and mtype > 2 then
        adminNotify('QBCore:Notify', src, 'Easy mode only supports type 0/1/2', 'error')
        return
    end
    paddle = math.floor(tonumber(paddle) or 0)
    if paddle < 0 or paddle > 2 then paddle = 0 end

    -- preserve any existing gearRatioMode AND speedCal fields for this model
    local existingM = presetModels[hash]
    local ratio    = (existingM and existingM.ratio)    or 0
    local speedCal  = existingM and existingM.speedCal
    local speedCalC = existingM and existingM.speedCalC
    local turboDefault = existingM and existingM.turboDefault   -- keep turbo FEEL flag alive in the live map
    local wheelieLaunch = existingM and existingM.wheelieLaunch  -- keep wheelie-launch opt-in alive in the live map

    MySQL.update.await(
        'INSERT INTO hk_handling (model, hash, name, manualType, forcePaddle, gearRatioMode) ' ..
        'VALUES (?, ?, ?, ?, ?, ?) ' ..
        'ON DUPLICATE KEY UPDATE model=VALUES(model), name=VALUES(name), ' ..
        'manualType=VALUES(manualType), forcePaddle=VALUES(forcePaddle)',
        { model, hash, name, mtype, paddle, ratio })
    presetModels[hash] = { type = mtype, paddle = paddle, ratio = ratio,
                           speedCal = speedCal, speedCalC = speedCalC, turboDefault = turboDefault,
                           wheelieLaunch = wheelieLaunch }
    pushModels()  -- broadcast updated map to everyone

    local label = labels[mtype] or ('TYPE' .. mtype)
    local pLabel = (paddle == 1) and ', PADDLE-ONLY' or (paddle == 2) and ', FORCE-AUTO' or ''
    adminNotify('QBCore:Notify', src,
        ('%s -> %s%s'):format(name or model or hash, label, pLabel), 'success')
    print(('[hk-gearbox] %s set model %s (%s) -> type %s paddle %s')
        :format(GetPlayerName(src) or src, name or model, hash, mtype, paddle))
end)

-----------------------------------------------------------------
-- ADMIN COMMAND: /gearratio <0-6>
-- Sets the GEAR-RATIO (shift-feel) mode of the admin's current vehicle's MODEL,
-- independent of its gearbox TYPE. Mirrors /setgear: perm check -> ask the client
-- for the model -> write gearRatioMode -> push the map. Preserves the row's
-- existing manualType/forcePaddle (creates a default row if none exists).
--   0 = default (stock feel)  1 = sport  2 = drag  3 = hypercar
-----------------------------------------------------------------
local USAGE_RATIO = 'Usage: /gearratio <0-6> | 0=default 1=sport 2=drag 3=hypercar 4=LST 5=F1box 6=quadturbo'

RegisterCommand('gearratio', function(src, args)
    if not isAdmin(src) then
        adminNotify('QBCore:Notify', src, 'No permission', 'error')
        return
    end
    if isEasy() then
        adminNotify('QBCore:Notify', src, '/gearratio disabled in Easy mode', 'error')
        return
    end
    local ratio = tonumber(args[1])
    if not ratio then
        adminNotify('QBCore:Notify', src, USAGE_RATIO, 'error')
        return
    end
    ratio = math.floor(ratio)
    -- validate against the configured RatioModes (0-3)
    local modes = (Config.Gearbox and Config.Gearbox.RatioModes) or {}
    if modes[ratio] == nil then
        adminNotify('QBCore:Notify', src, 'Unknown ratio mode ' .. ratio .. '. ' .. USAGE_RATIO, 'error')
        return
    end
    -- ask the admin's client for the model hash/name of the car they're in
    TriggerClientEvent('hk-handling:gearbox:requestRatioModel', src, ratio)
end, false)

-- Client replies with the resolved model info + desired ratio mode.
RegisterNetEvent('hk-handling:gearbox:setRatioModel', function(hash, model, name, ratio)
    local src = source
    if not isAdmin(src) then return end
    hash = math.tointeger(hash) or tonumber(hash)
    if not hash then
        adminNotify('QBCore:Notify', src, 'Not in a vehicle', 'error')
        return
    end
    hash = hash & 0xFFFFFFFF   -- clean unsigned 32-bit
    ratio = math.floor(tonumber(ratio) or 0)
    local modes = (Config.Gearbox and Config.Gearbox.RatioModes) or {}
    if modes[ratio] == nil then
        adminNotify('QBCore:Notify', src, 'Invalid ratio mode', 'error')
        return
    end

    -- preserve this model's existing gearbox TYPE/paddle/speedCal (set via /setgear).
    -- No row yet? default to type 0 (our auto) / paddle 0 — same as a seed row.
    local existing = presetModels[hash]
    local mtype   = (existing and existing.type)     or 0
    local paddle  = (existing and existing.paddle)   or 0
    local speedCal  = existing and existing.speedCal
    local speedCalC = existing and existing.speedCalC
    local turboDefault = existing and existing.turboDefault   -- keep turbo FEEL flag alive in the live map
    local wheelieLaunch = existing and existing.wheelieLaunch  -- keep wheelie-launch opt-in alive in the live map

    -- TYPE 6 = GTA NATIVE (script does not process the car), so a gear-ratio (shift-
    -- feel) mode is meaningless there — the box never runs to apply it. Reject so the
    -- admin isn't misled. Change the type with /setgear first if you want ratio modes.
    if mtype == 6 then
        adminNotify('QBCore:Notify', src,
            (name or model or hash) .. ' is GTA-NATIVE (type 6) — gear-ratio modes do not apply. Set a gearbox type first.', 'error')
        return
    end

    MySQL.update.await(
        'INSERT INTO hk_handling (model, hash, name, manualType, forcePaddle, gearRatioMode) ' ..
        'VALUES (?, ?, ?, ?, ?, ?) ' ..
        'ON DUPLICATE KEY UPDATE model=VALUES(model), name=VALUES(name), ' ..
        'gearRatioMode=VALUES(gearRatioMode)',
        { model, hash, name, mtype, paddle, ratio })
    presetModels[hash] = { type = mtype, paddle = paddle, ratio = ratio,
                           speedCal = speedCal, speedCalC = speedCalC, turboDefault = turboDefault,
                           wheelieLaunch = wheelieLaunch }
    pushModels()  -- broadcast updated map to everyone

    local rmodes = (Config.Gearbox and Config.Gearbox.RatioModes) or {}
    local rLabel = (rmodes[ratio] and rmodes[ratio].Label) or ('RATIO' .. ratio)
    adminNotify('QBCore:Notify', src,
        ('%s -> ratio %s'):format(name or model or hash, rLabel), 'success')
    print(('[hk-gearbox] %s set model %s (%s) -> gearRatioMode %s (%s)')
        :format(GetPlayerName(src) or src, name or model, hash, ratio, rLabel))
end)

-----------------------------------------------------------------
-- ADMIN COMMAND: /setspeed <0-kmh> <time>  (or /setspeed clear)
-- Records a real-life acceleration TARGET for the admin's current model:
-- "0-<kmh> should take <time>s". The CLIENT (which can read handling.meta) merges
-- the point into the raw target string, computes a packed per-band torque factor
-- curve, and sends BOTH back. We are dumb storage: speedCal (raw "kmh,s;" targets,
-- for re-editing) + speedCalC (packed BIGINT the hot tick applies). Pure torque,
-- so it never touches rpm/gear (no bog/wheelie).
--   /setspeed 60 2.3     -> add/replace the 0-60 target
--   /setspeed 100 5.5    -> add/replace the 0-100 target
--   /setspeed clear      -> wipe all calibration for this model
-----------------------------------------------------------------
local USAGE_SPEED = 'Usage: /setspeed <kmh> <time> (e.g. /setspeed 100 5.5) | /setspeed clear'

RegisterCommand('setspeed', function(src, args)
    if not isAdmin(src) then
        adminNotify('QBCore:Notify', src, 'No permission', 'error')
        return
    end
    if not isExpert() then
        adminNotify('QBCore:Notify', src, '/setspeed is Expert mode only', 'error')
        return
    end
    local a1 = tostring(args[1] or ''):lower()
    if a1 == 'clear' or a1 == 'remove' or a1 == 'none' then
        TriggerClientEvent('hk-handling:gearbox:requestSpeedModel', src, -1, 0)  -- -1 kmh = clear sentinel
        return
    end
    local kmh  = tonumber(args[1])
    local time = tonumber(args[2])
    if not kmh or not time or kmh <= 0 or time <= 0 then
        adminNotify('QBCore:Notify', src, USAGE_SPEED, 'error')
        return
    end
    TriggerClientEvent('hk-handling:gearbox:requestSpeedModel', src, math.floor(kmh), time)
end, false)

-- Client replies with model + the merged raw string + the computed packed int.
-- raw == nil / packed == nil means CLEAR (wipe calibration for this model).
RegisterNetEvent('hk-handling:gearbox:setSpeedModel', function(hash, model, name, rawCal, packedCal)
    local src = source
    if not isAdmin(src) then return end
    hash = math.tointeger(hash) or tonumber(hash)
    if not hash then
        adminNotify('QBCore:Notify', src, 'Not in a vehicle', 'error')
        return
    end
    hash = hash & 0xFFFFFFFF

    local existing = presetModels[hash]
    local mtype  = (existing and existing.type)   or 0
    local paddle = (existing and existing.paddle) or 0
    local ratio  = (existing and existing.ratio)  or 0
    -- preserve hybrid + turbo FEEL flags in the live map (DB survives via limited ON DUPLICATE,
    -- but the in-memory rebuild + broadcast would otherwise transiently drop them until restart).
    local hybridClass = existing and existing.hybridClass
    local evTorque    = existing and existing.evTorque
    local hybridCap   = existing and existing.hybridCap
    local speedoStyle = existing and existing.speedoStyle
    local turboDefault = existing and existing.turboDefault
    local wheelieLaunch = existing and existing.wheelieLaunch

    -- speedCal (raw target) and speedCalC (learned factor) are now INDEPENDENT:
    --   * rawCal nil  => clear the TARGET (also clears the factor — no target, no cal).
    --   * rawCal set, packedCal nil => store target, factor stays NULL = NEUTRAL =
    --     the tuner's handling.meta baseline (auto-cal / /accelcal learns from there).
    --   * both set => target + a learned/explicit factor.
    packedCal = math.tointeger(tonumber(packedCal or 0)) or 0
    if packedCal <= 0 then packedCal = nil end
    if not rawCal then packedCal = nil end          -- no target -> no factor either

    MySQL.update.await(
        'INSERT INTO hk_handling (model, hash, name, manualType, forcePaddle, gearRatioMode, speedCal, speedCalC) ' ..
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?) ' ..
        'ON DUPLICATE KEY UPDATE model=VALUES(model), name=VALUES(name), ' ..
        'speedCal=VALUES(speedCal), speedCalC=VALUES(speedCalC)',
        { model, hash, name, mtype, paddle, ratio, rawCal, packedCal })
    presetModels[hash] = { type = mtype, paddle = paddle, ratio = ratio, speedCal = rawCal, speedCalC = packedCal,
                           hybridClass = hybridClass, evTorque = evTorque, hybridCap = hybridCap,
                           speedoStyle = speedoStyle, turboDefault = turboDefault, wheelieLaunch = wheelieLaunch }
    pushModels()

    local msg = packedCal and ('cal set (%s | %d)'):format(rawCal or '-', packedCal)
                or 'speed calibration cleared'
    adminNotify('QBCore:Notify', src, ('%s -> %s'):format(name or model or hash, msg), 'success')
    print(('[hk-gearbox] %s setspeed model %s (%s) -> %s')
        :format(GetPlayerName(src) or src, name or model, hash, tostring(packedCal or 'cleared')))
end)

-----------------------------------------------------------------
-- ADMIN COMMAND: /setspeedbulk
-- One-shot bulk calibration. Tells the admin's CLIENT to walk HK.SpeedCalData
-- (Grok-sourced real figures, baked into client/speedcaldata.lua), spawn each
-- model offscreen, read its handling.meta, compute the packed factor, and fire
-- the (admin-gated) setSpeedModel event per car. The heavy lifting is client-side
-- because handling.meta is client-only; this just authorises + kicks it off.
-----------------------------------------------------------------
RegisterCommand('setspeedbulk', function(src, args)
    if not isAdmin(src) then
        adminNotify('QBCore:Notify', src, 'No permission', 'error')
        return
    end
    if not isExpert() then
        adminNotify('QBCore:Notify', src, '/setspeedbulk is Expert mode only', 'error')
        return
    end
    TriggerClientEvent('hk-handling:gearbox:bulkStart', src)
    adminNotify('QBCore:Notify', src, 'Bulk speed calibration started (see F8)...', 'primary')
    print(('[hk-gearbox] %s started /setspeedbulk'):format(GetPlayerName(src) or src))
end, false)

-----------------------------------------------------------------
-- ADMIN COMMAND: /accelcal — measured feedback correction. After /accel on a
-- calibrated car, this tells the client to read the measured splits, correct the
-- stored band factors toward the /setspeed target by the measured ratio, and save.
-- Run /accel -> /accelcal a few times to converge onto the real figure.
-----------------------------------------------------------------
RegisterCommand('accelcal', function(src, args)
    if not isAdmin(src) then
        adminNotify('QBCore:Notify', src, 'No permission', 'error')
        return
    end
    if not isExpert() then
        adminNotify('QBCore:Notify', src, '/accelcal is Expert mode only', 'error')
        return
    end
    TriggerClientEvent('hk-handling:gearbox:accelcalRun', src)
end, false)

-----------------------------------------------------------------
-- ADMIN COMMAND: /hybridspeedcap [topspeed] [power]
-- Sets the GLOBAL hybrid e-mode profile live for everyone:
--   topspeed = e-mode top-speed cap in km/h (above it the ICE engages)
--   power    = e-mode acceleration strength as a fraction 0..1 (0.25 = ~25% power)
-- Broadcast to all clients, which update Config.Gearbox.Hybrid at runtime. No args =
-- print current usage. (Per-model persistence is a later step; this is the global tune.)
-----------------------------------------------------------------
RegisterCommand('hybridspeedcap', function(src, args)
    if not isAdmin(src) then return end
    local cap   = tonumber(args[1])
    local power = tonumber(args[2])
    if not cap or cap <= 0 then
        print('[hk-hybrid] usage: /hybridspeedcap <topKmh> <power 0..1>  (e.g. /hybridspeedcap 135 0.22)')
        return
    end
    -- power optional; clamp to a sane 0.05..1.0 if given.
    if power then
        if power < 0.05 then power = 0.05 elseif power > 1.0 then power = 1.0 end
    end
    TriggerClientEvent('hk-handling:gearbox:setHybridCap', -1, cap, power)
    print(('[hk-hybrid] %s set global e-mode cap=%.0f km/h power=%s')
        :format(GetPlayerName(src) or src, cap, power and ('%.2f'):format(power) or '(unchanged)'))
end, false)

-----------------------------------------------------------------
-- ADMIN COMMAND: /sethybrid <none|full|semi | 0|1|2> [evtorque] [capKmh] [speedo 0/1]
-- Class arg accepts words (none/full/semi + aliases) OR the raw number (0=none, 1=full, 2=semi).
-- speedo (arg4, full PHEV only): 0 = full EV cluster, 1 = semi/KERS look on the normal tach.
-- DB-PERSISTED per-model hybrid classification (all instances of the car):
--   both  = FULL PHEV — standalone EV drive mode (HOLD-G toggles EV<->ICE), e-mode
--           speed cap, regen. evtorque = e-mode power fraction (0.05..1.0, e.g. 0.28);
--           capKmh = e-mode top-speed cap (optional; falls back to config default).
--   semi  = SEMI/KERS hybrid — ICE ALWAYS runs, e-motor gives regen-on-lift + an
--           always-on torque FILL to ICE power. NO standalone EV mode. evtorque =
--           the always-on boost multiplier (1.0..2.0, e.g. 1.20 = +20%). capKmh ignored.
--   none  = clear the hybrid flag (revert to plain ICE / config default).
-- evtorque/capKmh optional -> stored NULL -> the class default is used.
-- Uses the same client-hash-resolve round-trip as /setgear (per current vehicle).
-----------------------------------------------------------------
local HYBRID_USAGE = 'Usage: /sethybrid <none|full|semi | 0|1|2> [evtorque] [capKmh] [speedo 0/1]  ' ..
                     '(1/full=PHEV w/ EV mode, evtorque=power 0.05-1.0; ' ..
                     '2/semi=KERS assist, evtorque=boost mult 1.0-2.0; 0/none=plain ICE. ' ..
                     'speedo: full PHEV only — 0=full EV cluster, 1=semi/KERS look)'

RegisterCommand('sethybrid', function(src, args)
    if not isAdmin(src) then
        adminNotify('QBCore:Notify', src, 'No permission', 'error')
        return
    end
    -- Class arg accepts WORDS (none/full/semi + aliases) OR the raw NUMBER (0=none, 1=full, 2=semi).
    local a1 = tostring(args[1] or ''):lower()
    local class
    if a1 == 'both' or a1 == 'full' or a1 == 'phev' or a1 == '1' then class = 1
    elseif a1 == 'semi' or a1 == 'kers' or a1 == 'mild' or a1 == '2' then class = 2
    elseif a1 == 'none' or a1 == 'remove' or a1 == 'clear' or a1 == 'off' or a1 == '0' then class = 0
    else
        adminNotify('QBCore:Notify', src, HYBRID_USAGE, 'error')
        return
    end
    -- evtorque -> ×100 int (nil = default). Range validated per class client-agnostic here.
    local evT = tonumber(args[2])
    local evTorque
    if evT then
        if class == 1 then                       -- full PHEV: power fraction 0.05..1.0
            if evT > 1.5 then evT = evT / 100.0 end   -- allow "28" as 0.28 convenience
            if evT < 0.05 then evT = 0.05 elseif evT > 1.0 then evT = 1.0 end
        elseif class == 2 then                   -- semi: boost multiplier 1.0..2.0
            if evT > 5.0 then evT = evT / 100.0 end   -- allow "120" as 1.20 convenience
            if evT < 1.0 then evT = 1.0 elseif evT > 2.0 then evT = 2.0 end
        end
        evTorque = math.floor(evT * 100 + 0.5)   -- persist ×100
    end
    -- capKmh (full PHEV only)
    local cap = tonumber(args[3])
    local capKmh
    if cap and class == 1 and cap > 0 then capKmh = math.floor(cap) end
    -- speedoStyle (arg4) — the SPEEDO LOOK override, full PHEV only (class 1). 0=full EV cluster,
    -- 1=semi/KERS look. Class 2 is always semi, class 0 has no e-display, so it's ignored/NULL there.
    local styleArg = tonumber(args[4])
    local speedoStyle
    if styleArg and class == 1 then
        speedoStyle = (styleArg >= 1) and 1 or 0
    end
    TriggerClientEvent('hk-handling:gearbox:requestHybridModel', src, class, evTorque, capKmh, speedoStyle)
end, false)

-- Client replies with the resolved model info. class 0 = clear the hybrid fields.
RegisterNetEvent('hk-handling:gearbox:setHybridModel', function(hash, model, name, class, evTorque, capKmh, speedoStyle)
    local src = source
    if not isAdmin(src) then return end
    hash = math.tointeger(hash) or tonumber(hash)
    if not hash then
        adminNotify('QBCore:Notify', src, 'Not in a vehicle', 'error')
        return
    end
    hash = hash & 0xFFFFFFFF
    class = math.floor(tonumber(class) or 0)
    if class < 0 or class > 2 then class = 0 end
    evTorque = evTorque and (math.tointeger(tonumber(evTorque)) or nil) or nil
    capKmh   = capKmh   and (math.tointeger(tonumber(capKmh))   or nil) or nil
    speedoStyle = speedoStyle and (math.tointeger(tonumber(speedoStyle)) or nil) or nil
    if speedoStyle ~= nil and (speedoStyle < 0 or speedoStyle > 1) then speedoStyle = nil end
    if class ~= 1 then speedoStyle = nil end             -- look override is full-PHEV only
    if class == 0 then evTorque, capKmh = nil, nil end   -- clearing: wipe the tune too

    -- preserve every OTHER preset field for this model (gear type/paddle/ratio/speedcal/turbo).
    local ex = presetModels[hash]
    local mtype  = (ex and ex.type)   or 0
    local paddle = (ex and ex.paddle) or 0
    local ratio  = (ex and ex.ratio)  or 0
    local speedCal  = ex and ex.speedCal
    local speedCalC = ex and ex.speedCalC
    local turboDefault = ex and ex.turboDefault   -- keep turbo FEEL flag alive in the live map
    local wheelieLaunch = ex and ex.wheelieLaunch  -- keep wheelie-launch opt-in alive in the live map

    MySQL.update.await(
        'INSERT INTO hk_handling (model, hash, name, manualType, forcePaddle, gearRatioMode, ' ..
        'hybridClass, evTorque, hybridCap, speedoStyle) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ' ..
        'ON DUPLICATE KEY UPDATE model=VALUES(model), name=VALUES(name), ' ..
        'hybridClass=VALUES(hybridClass), evTorque=VALUES(evTorque), hybridCap=VALUES(hybridCap), ' ..
        'speedoStyle=VALUES(speedoStyle)',
        { model, hash, name, mtype, paddle, ratio, class, evTorque, capKmh, speedoStyle })
    presetModels[hash] = { type = mtype, paddle = paddle, ratio = ratio,
                           speedCal = speedCal, speedCalC = speedCalC,
                           hybridClass = class, evTorque = evTorque, hybridCap = capKmh,
                           speedoStyle = speedoStyle, turboDefault = turboDefault,
                           wheelieLaunch = wheelieLaunch }
    pushModels()  -- broadcast updated map to everyone

    local clabel = (class == 1) and 'FULL PHEV (EV mode)' or (class == 2) and 'SEMI (KERS assist)' or 'none'
    local extra = ''
    if class == 1 then
        extra = evTorque and (', power %.2f'):format(evTorque / 100.0) or ', power default'
        if capKmh then extra = extra .. (', cap %d km/h'):format(capKmh) end
        if speedoStyle ~= nil then
            extra = extra .. (', speedo=%s'):format(speedoStyle == 1 and 'semi' or 'full')
        end
    elseif class == 2 then
        extra = evTorque and (', boost ×%.2f'):format(evTorque / 100.0) or ', boost default'
    end
    adminNotify('QBCore:Notify', src, ('%s -> hybrid: %s%s'):format(name or model or hash, clabel, extra), 'success')
    print(('[hk-hybrid] %s set model %s (%s) -> class=%d evTorque=%s cap=%s speedo=%s')
        :format(GetPlayerName(src) or src, name or model, hash, class,
                tostring(evTorque or 'default'), tostring(capKmh or 'default'),
                tostring(speedoStyle == nil and 'derive' or (speedoStyle == 1 and 'semi' or 'full'))))
end)

-----------------------------------------------------------------
-- ADMIN COMMAND: /setturbo <0|1|na|turbo|clear>
-- DB-PERSISTED per-model TURBO-BY-DESIGN flag (all instances of the car). FEEL ONLY —
-- spool/whistle/gearbox feel default-on; it does NOT add power and does NOT raise top
-- speed. Power comes exclusively from the jim-mechanic turbo UPGRADE (native mod 18),
-- applied equally to NA and turbo cars. So this only changes how the car SOUNDS/FEELS
-- out of the box; it's still stock-quick until the player installs the upgrade.
--   1 / turbo / on  = force turbo-by-design feel.
--   0 / na / off    = force naturally-aspirated (no default feel; overrides the roster).
--   clear / unset   = clear the flag -> fall back to the config Turbo.DefaultModels roster.
-- Uses the same client-hash-resolve round-trip as /sethybrid (per current vehicle).
-----------------------------------------------------------------
local TURBO_USAGE = 'Usage: /setturbo <0|1|clear>  (1/turbo=forced turbo FEEL default-on; ' ..
                    '0/na=forced naturally-aspirated; clear=use the built-in roster. ' ..
                    'FEEL only — power still needs the mechanic turbo upgrade)'

RegisterCommand('setturbo', function(src, args)
    if not isAdmin(src) then
        adminNotify('QBCore:Notify', src, 'No permission', 'error')
        return
    end
    local a1 = tostring(args[1] or ''):lower()
    local flag       -- 1 = turbo, 0 = NA, nil = clear/unset (fall back to roster)
    if a1 == '1' or a1 == 'turbo' or a1 == 'on' or a1 == 'yes' then flag = 1
    elseif a1 == '0' or a1 == 'na' or a1 == 'off' or a1 == 'no' then flag = 0
    elseif a1 == 'clear' or a1 == 'unset' or a1 == 'reset' or a1 == 'default' or a1 == '' then flag = nil
    else
        adminNotify('QBCore:Notify', src, TURBO_USAGE, 'error')
        return
    end
    -- Sentinel -1 over the wire = "clear" (nil can't survive the event boundary cleanly).
    TriggerClientEvent('hk-handling:gearbox:requestTurboModel', src, flag == nil and -1 or flag)
end, false)

-- Client replies with the resolved model info. flag -1 = clear (NULL the column).
RegisterNetEvent('hk-handling:gearbox:setTurboModel', function(hash, model, name, flag)
    local src = source
    if not isAdmin(src) then return end
    hash = math.tointeger(hash) or tonumber(hash)
    if not hash then
        adminNotify('QBCore:Notify', src, 'Not in a vehicle', 'error')
        return
    end
    hash = hash & 0xFFFFFFFF
    flag = math.floor(tonumber(flag) or -1)
    local turboDefault                    -- nil = clear/unset; 0 = NA; 1 = turbo
    if flag == 0 then turboDefault = 0
    elseif flag == 1 then turboDefault = 1
    else turboDefault = nil end

    -- preserve every OTHER preset field for this model (gear/paddle/ratio/hybrid/speedcal/speedo).
    local ex = presetModels[hash]
    local mtype   = (ex and ex.type)   or 0
    local paddle  = (ex and ex.paddle) or 0
    local ratio   = (ex and ex.ratio)  or 0
    local speedCal   = ex and ex.speedCal
    local speedCalC  = ex and ex.speedCalC
    local hybridClass = ex and ex.hybridClass
    local evTorque    = ex and ex.evTorque
    local hybridCap   = ex and ex.hybridCap
    local speedoStyle = ex and ex.speedoStyle
    local wheelieLaunch = ex and ex.wheelieLaunch  -- keep wheelie-launch opt-in alive in the live map

    MySQL.update.await(
        'INSERT INTO hk_handling (model, hash, name, manualType, forcePaddle, gearRatioMode, ' ..
        'hybridClass, evTorque, hybridCap, speedoStyle, turboDefault) ' ..
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ' ..
        'ON DUPLICATE KEY UPDATE model=VALUES(model), name=VALUES(name), turboDefault=VALUES(turboDefault)',
        { model, hash, name, mtype, paddle, ratio, hybridClass, evTorque, hybridCap, speedoStyle, turboDefault })
    presetModels[hash] = { type = mtype, paddle = paddle, ratio = ratio,
                           speedCal = speedCal, speedCalC = speedCalC,
                           hybridClass = hybridClass, evTorque = evTorque, hybridCap = hybridCap,
                           speedoStyle = speedoStyle, turboDefault = turboDefault,
                           wheelieLaunch = wheelieLaunch }
    pushModels()  -- broadcast updated map to everyone

    local tlabel = (turboDefault == 1) and 'TURBO (feel default-on)'
               or  (turboDefault == 0) and 'NA (naturally-aspirated)'
               or  'unset (config roster)'
    adminNotify('QBCore:Notify', src, ('%s -> turbo: %s'):format(name or model or hash, tlabel), 'success')
    print(('[hk-turbo] %s set model %s (%s) -> turboDefault=%s')
        :format(GetPlayerName(src) or src, name or model, hash, tostring(turboDefault == nil and 'unset' or turboDefault)))
end)

-----------------------------------------------------------------
-- ADMIN COMMAND: /setwheelie <0|1|clear>
-- DB-PERSISTED per-model launch-wheelie [F1] opt-in (all instances of the car).
--   1 / on    = force the launch wheelie ON for this model even if it's NOT muscle
--               class (a vc_sport-marked custom muscle car that dodges the addon
--               handling-flag bugs but still wants the wheelie).
--   0 / off   = force it OFF even on a muscle-class car (silence a buggy one).
--   clear     = clear the flag -> fall back to the class gate (muscle gets it).
-- Uses the same client-hash-resolve round-trip as /setturbo (per current vehicle).
-----------------------------------------------------------------
local WLAUNCH_USAGE = 'Usage: /setwheelie <0|1|clear>  (1/on=force launch wheelie on even off-' ..
                      'muscle; 0/off=force off even on muscle; clear=use the muscle class default)'

RegisterCommand('setwheelie', function(src, args)
    if not isAdmin(src) then
        adminNotify('QBCore:Notify', src, 'No permission', 'error')
        return
    end
    local a1 = tostring(args[1] or ''):lower()
    local flag       -- 1 = on, 0 = off, nil = clear/unset (fall back to class gate)
    -- BARE /setwheelie (no arg) = show usage, do NOT touch the DB. Previously '' fell into the
    -- clear branch, so a bare command silently NULLed the flag and reported "unset" — which read
    -- like the save had FAILED. Clearing now REQUIRES an explicit 'clear'/'unset'/'default'.
    if a1 == '' then
        adminNotify('QBCore:Notify', src, WLAUNCH_USAGE, 'inform')
        return
    end
    if a1 == '1' or a1 == 'on' or a1 == 'true' or a1 == 'yes' then flag = 1
    elseif a1 == '0' or a1 == 'off' or a1 == 'false' or a1 == 'no' then flag = 0
    elseif a1 == 'clear' or a1 == 'unset' or a1 == 'reset' or a1 == 'default' then flag = nil
    else
        adminNotify('QBCore:Notify', src, WLAUNCH_USAGE, 'error')
        return
    end
    -- Sentinel -1 over the wire = "clear" (nil can't survive the event boundary cleanly).
    TriggerClientEvent('hk-handling:gearbox:requestWheelieLaunchModel', src, flag == nil and -1 or flag)
end, false)

-- Client replies with the resolved model info. flag -1 = clear (NULL the column).
RegisterNetEvent('hk-handling:gearbox:setWheelieLaunchModel', function(hash, model, name, flag)
    local src = source
    if not isAdmin(src) then return end
    hash = math.tointeger(hash) or tonumber(hash)
    if not hash then
        adminNotify('QBCore:Notify', src, 'Not in a vehicle', 'error')
        return
    end
    hash = hash & 0xFFFFFFFF
    flag = math.floor(tonumber(flag) or -1)
    local wheelieLaunch                   -- nil = clear/unset; 0 = off; 1 = on
    if flag == 0 then wheelieLaunch = 0
    elseif flag == 1 then wheelieLaunch = 1
    else wheelieLaunch = nil end

    -- preserve every OTHER preset field for this model.
    local ex = presetModels[hash]
    local mtype   = (ex and ex.type)   or 0
    local paddle  = (ex and ex.paddle) or 0
    local ratio   = (ex and ex.ratio)  or 0
    local speedCal   = ex and ex.speedCal
    local speedCalC  = ex and ex.speedCalC
    local hybridClass = ex and ex.hybridClass
    local evTorque    = ex and ex.evTorque
    local hybridCap   = ex and ex.hybridCap
    local speedoStyle = ex and ex.speedoStyle
    local turboDefault = ex and ex.turboDefault

    MySQL.update.await(
        'INSERT INTO hk_handling (model, hash, name, manualType, forcePaddle, gearRatioMode, ' ..
        'hybridClass, evTorque, hybridCap, speedoStyle, turboDefault, wheelieLaunch) ' ..
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ' ..
        'ON DUPLICATE KEY UPDATE model=VALUES(model), name=VALUES(name), wheelieLaunch=VALUES(wheelieLaunch)',
        { model, hash, name, mtype, paddle, ratio, hybridClass, evTorque, hybridCap, speedoStyle,
          turboDefault, wheelieLaunch })
    presetModels[hash] = { type = mtype, paddle = paddle, ratio = ratio,
                           speedCal = speedCal, speedCalC = speedCalC,
                           hybridClass = hybridClass, evTorque = evTorque, hybridCap = hybridCap,
                           speedoStyle = speedoStyle, turboDefault = turboDefault,
                           wheelieLaunch = wheelieLaunch }
    pushModels()  -- broadcast updated map to everyone

    local wlabel = (wheelieLaunch == 1) and 'ON (forced)'
               or  (wheelieLaunch == 0) and 'OFF (forced)'
               or  'unset (muscle class default)'
    adminNotify('QBCore:Notify', src, ('%s -> launch wheelie: %s'):format(name or model or hash, wlabel), 'success')
    print(('[hk-wheelie] %s set model %s (%s) -> wheelieLaunch=%s')
        :format(GetPlayerName(src) or src, name or model, hash, tostring(wheelieLaunch == nil and 'unset' or wheelieLaunch)))
end)

-----------------------------------------------------------------
-- ADMIN COMMAND: /nlstatus [hash]
-- Prints the normal-learner state for the admin's current vehicle (or a
-- given hash). Shows: N: baseline, current speedCalC scalar, blend candidates.
-- Works in any mode — useful during playtest to verify learning is happening.
-----------------------------------------------------------------
local function nlstatusReport(src, hash, label)
    local m = presetModels[hash]
    if not m then
        local msg = ('nlstatus: %s (hash %d) — no DB row yet'):format(label or hash, hash)
        if src ~= 0 then adminNotify('QBCore:Notify', src, msg, 'error') end
        print('[hk-nlstatus] ' .. msg)
        return
    end

    local baseline = m.speedCal
    local hasNative = type(baseline) == 'string' and baseline:sub(1, 2) == 'N:'

    local scalarStr = 'none'
    if m.speedCalC then
        local packed = math.tointeger(tonumber(m.speedCalC or 0)) or 0
        local SV_SENT = 10000000000000000
        if packed >= SV_SENT then
            packed = packed - SV_SENT
            local g1 = (packed // 1000000000000) % 10000
            if g1 > 0 then scalarStr = ('x%.3f'):format(g1 / 100.0) end
        end
    end

    local st = normalLearnState[hash]
    local candStr = 'none'
    if st and #st.candidates > 0 then
        local parts = {}
        for _, c in ipairs(st.candidates) do parts[#parts+1] = ('%.3f'):format(c) end
        candStr = table.concat(parts, ', ')
    end

    local msg = ('nlstatus %s hash=%d | baseline=%s | scalar=%s | candidates=[%s]')
        :format(label or tostring(hash), hash,
                hasNative and baseline or (baseline and ('old:%s'):format(baseline) or 'none'),
                scalarStr, candStr)

    if src ~= 0 then adminNotify('QBCore:Notify', src, msg, 'primary') end
    print('[hk-nlstatus] ' .. msg)
end

RegisterCommand('nlstatus', function(src, args)
    if not isAdmin(src) then
        if src ~= 0 then adminNotify('QBCore:Notify', src, 'No permission', 'error') end
        print('[hk-nlstatus] permission denied for src=' .. tostring(src))
        return
    end

    -- Hash provided directly as arg
    if args[1] then
        local hash = math.tointeger(tonumber(args[1])) or tonumber(args[1])
        if not hash then
            if src ~= 0 then adminNotify('QBCore:Notify', src, 'nlstatus: invalid hash', 'error') end
            return
        end
        nlstatusReport(src, hash & 0xFFFFFFFF, nil)
        return
    end

    -- No arg: resolve the admin's current vehicle server-side (OneSync).
    if src == 0 then
        print('[hk-nlstatus] server console: provide a hash — /nlstatus <hash>')
        return
    end
    local ped = GetPlayerPed(src)
    local veh = ped and ped ~= 0 and GetVehiclePedIsIn(ped, false) or 0
    if veh == 0 then
        adminNotify('QBCore:Notify', src, 'nlstatus: not in a vehicle', 'error')
        return
    end
    local hash = GetEntityModel(veh) & 0xFFFFFFFF
    nlstatusReport(src, hash, tostring(hash))
end, false)


-- Client replies with current vehicle hash for /nlstatus (no-arg path).
RegisterNetEvent('hk-handling:gearbox:nlStatusReply', function(hash, name)
    local src = source
    if not isAdmin(src) then return end
    hash = math.tointeger(hash) or tonumber(hash)
    if not hash then
        adminNotify('QBCore:Notify', src, 'nlstatus: not in a vehicle', 'error')
        return
    end
    hash = hash & 0xFFFFFFFF

    local m = presetModels[hash]
    if not m then
        adminNotify('QBCore:Notify', src,
            ('nlstatus: %s (hash %d) — no DB row yet'):format(name or hash, hash), 'error')
        print(('[hk-nlstatus] %s hash=%d no DB row'):format(name or '?', hash))
        return
    end

    local baseline = m.speedCal
    local hasNative = type(baseline) == 'string' and baseline:sub(1, 2) == 'N:'

    local scalarStr = 'none'
    if m.speedCalC then
        local packed = math.tointeger(tonumber(m.speedCalC or 0)) or 0
        local SV_SENT = 10000000000000000
        if packed >= SV_SENT then
            packed = packed - SV_SENT
            local g1 = (packed // 1000000000000) % 10000
            if g1 > 0 then scalarStr = ('x%.3f'):format(g1 / 100.0) end
        end
    end

    local st = normalLearnState[hash]
    local candStr = 'none'
    if st and #st.candidates > 0 then
        local parts = {}
        for _, c in ipairs(st.candidates) do parts[#parts+1] = ('%.3f'):format(c) end
        candStr = table.concat(parts, ', ')
    end

    local msg = ('nlstatus %s hash=%d | baseline=%s | scalar=%s | candidates=[%s]')
        :format(name or tostring(hash), hash,
                hasNative and baseline or (baseline and ('old:%s'):format(baseline) or 'none'),
                scalarStr, candStr)

    adminNotify('QBCore:Notify', src, msg, 'primary')
    print('[hk-nlstatus] ' .. msg)
end)

-----------------------------------------------------------------
-- NORMAL LEARNER — server-side event.
-- Client sends telemetry only. Server computes the trim candidate.
-- Uses the N: prefix to distinguish native baselines from old expert rows.
-- Touches ONLY speedCal (Phase A) or speedCalC (Phase B).
-- Deliberately does NOT call setSpeedModel to avoid the line 316 wipe trap.
-----------------------------------------------------------------

local SPC_SENTINEL_SV = 10000000000000000

local function svClamp(x, lo, hi)
    if x < lo then return lo end
    if x > hi then return hi end
    return x
end

local function svPackScalar(f, cfg)
    local trimMin = (cfg and cfg.TrimMin) or 0.94
    local trimMax = (cfg and cfg.TrimMax) or 1.08
    f = svClamp(tonumber(f) or 1.0, trimMin, trimMax)
    local v = math.floor(f * 100 + 0.5)
    return SPC_SENTINEL_SV
        + v * 1000000000000
        + v * 100000000
        + v * 10000
        + v
end

local function svUnpackScalar(packed)
    packed = math.tointeger(tonumber(packed or 0)) or 0
    if packed < SPC_SENTINEL_SV then return nil end
    packed = packed - SPC_SENTINEL_SV
    local g1 = (packed // 1000000000000) % 10000
    if g1 <= 0 then return nil end
    return g1 / 100.0
end

local function svParseNativeBaseline(raw)
    if type(raw) ~= 'string' or raw:sub(1, 2) ~= 'N:' then return nil end
    local out = {}
    for k, t in raw:gmatch('(%d+%.?%d*)%s*,%s*(%d+%.?%d*)') do
        local kk = math.floor(tonumber(k) or 0)
        if kk > 0 then out[kk] = tonumber(t) end
    end
    if not out[100] then return nil end
    return out
end

-- Median of a number array.
local function svMedian(values)
    local t = {}
    for i = 1, #values do t[i] = values[i] end
    table.sort(t)
    local n = #t
    if n == 0 then return nil end
    if n % 2 == 1 then return t[(n + 1) // 2] end
    return (t[n // 2] + t[n // 2 + 1]) * 0.5
end

-- Log-space EMA blend with per-update movement cap.
local function svBlendTrim(hash, current, candidate, hasExisting, cfg)
    local trimMin     = (cfg and cfg.TrimMin)      or 0.94
    local trimMax     = (cfg and cfg.TrimMax)      or 1.08
    local window      = (cfg and cfg.MedianWindow) or 7
    local alpha       = hasExisting and ((cfg and cfg.NormalAlpha)   or 0.18)
                                     or ((cfg and cfg.FirstAlpha)    or 0.65)
    local maxStep     = hasExisting and ((cfg and cfg.NormalMaxStep) or 0.025)
                                     or ((cfg and cfg.FirstMaxStep)  or 0.08)
    local deadband    = (cfg and cfg.Deadband) or 0.004

    local st = normalLearnState[hash]
    if not st then st = { candidates = {} }; normalLearnState[hash] = st end

    table.insert(st.candidates, candidate)
    while #st.candidates > window do table.remove(st.candidates, 1) end

    local target = svMedian(st.candidates)
    if not target then return current end

    current = current or 1.0

    if math.abs((target / current) - 1.0) < deadband then return current end

    local nextF = math.exp(math.log(current) + alpha * (math.log(target) - math.log(current)))
    nextF = svClamp(nextF, current * (1.0 - maxStep), current * (1.0 + maxStep))
    nextF = svClamp(nextF, trimMin, trimMax)
    return nextF
end

-----------------------------------------------------------------
-- BRAKE-BUFF CHIP LOOKUP (2026-08-14) — the brake-force buff (client/main.lua apply gate) needs to know
-- whether THIS vehicle has a lambra tuner chip installed, which lives in player_vehicles.lambrachip. The
-- existing hk-misc:tunerchip:status callback is admin-gated (mod-menu only), so a normal driver can't use
-- it. This is a lightweight, un-gated read of a single boolean-ish column keyed by plate — same shape as
-- the nlStatus request/reply. Rate-limited per source so it can't be spammed into a DB hammer.
local brakeChipRate = {}
RegisterNetEvent('hk-handling:brakebuff:chipQuery', function(plate)
    local src = source
    if src == 0 then return end
    local now = GetGameTimer()
    local last = brakeChipRate[src] or 0
    if now - last < 1500 then return end          -- 1 query / 1.5s / player (entry-driven, not hot)
    brakeChipRate[src] = now

    plate = tostring(plate or ''):gsub('%s+$', '')
    local has = false
    if plate ~= '' then
        local row = MySQL.query.await('SELECT lambrachip FROM player_vehicles WHERE plate = ? LIMIT 1', { plate })
        local chip = row and row[1] and row[1].lambrachip or nil
        has = (chip ~= nil and tostring(chip) ~= '')
    end
    TriggerClientEvent('hk-handling:brakebuff:chipReply', src, plate, has)
end)

-- Rate limit: one sample per source per 30s.
local learnRate = {}

RegisterNetEvent('hk-handling:gearbox:normalLearnSample', function(sample)
    local src = source
    if not isNormal() then return end

    local now = GetGameTimer()
    local last = learnRate[src] or 0
    if now - last < 30000 then return end
    learnRate[src] = now

    if type(sample) ~= 'table' then return end

    local NL = Config.Gearbox and Config.Gearbox.NormalLearn

    local hash = math.tointeger(sample.hash) or tonumber(sample.hash)
    if not hash then return end
    hash = hash & 0xFFFFFFFF

    local t100     = tonumber(sample.t100)
    local t60      = tonumber(sample.t60)
    local fApplied = tonumber(sample.fApplied) or 1.0
    local grade    = tonumber(sample.grade)    or 0.0

    local minT = (NL and NL.MinT100) or 1.2
    local maxT = (NL and NL.MaxT100) or 40.0
    if not t100 or t100 < minT or t100 > maxT then return end
    if t60 and (t60 <= 0 or t60 >= t100) then return end
    if grade > ((NL and NL.MaxGrade) or 0.025) then return end

    local candRejectMin = (NL and NL.CandRejectMin) or 0.91
    local candRejectMax = (NL and NL.CandRejectMax) or 1.11
    if fApplied < candRejectMin or fApplied > candRejectMax then return end

    -- Optional OneSync vehicle hash sanity check.
    local ped = GetPlayerPed(src)
    if ped and ped ~= 0 then
        local veh = GetVehiclePedIsIn(ped, false)
        if veh and veh ~= 0 then
            local serverHash = GetEntityModel(veh) & 0xFFFFFFFF
            if serverHash ~= hash then return end
        end
    end

    local existing   = presetModels[hash]
    local mtype      = (existing and existing.type)   or 0
    local paddle     = (existing and existing.paddle) or 0
    local ratio      = (existing and existing.ratio)  or 0
    local baseline   = existing and svParseNativeBaseline(existing.speedCal)

    if not baseline then
        -- Phase A: store GTA-native baseline with N: prefix.
        local raw = ('N:60,%s;100,%s;'):format(
            t60 and ('%.3f'):format(t60) or '0',
            ('%.3f'):format(t100))

        MySQL.update.await(
            'INSERT INTO hk_handling (model, hash, name, manualType, forcePaddle, gearRatioMode, speedCal, speedCalC) ' ..
            'VALUES (?, ?, ?, ?, ?, ?, ?, NULL) ' ..
            'ON DUPLICATE KEY UPDATE model=VALUES(model), name=VALUES(name), speedCal=VALUES(speedCal)',
            { sample.model or '', hash, sample.name or sample.model or tostring(hash),
              mtype, paddle, ratio, raw })

        local prev = presetModels[hash] or {}
        presetModels[hash] = {
            type = mtype, paddle = paddle, ratio = ratio,
            speedCal = raw, speedCalC = prev.speedCalC,
            hybridClass = prev.hybridClass, evTorque = prev.evTorque, hybridCap = prev.hybridCap,
            speedoStyle = prev.speedoStyle, turboDefault = prev.turboDefault,
            wheelieLaunch = prev.wheelieLaunch,
        }
        pushModels()

        if NL and NL.Debug then
            print(('[hk-normallearn] %s stored native baseline hash=%d t60=%s t100=%.3f')
                :format(GetPlayerName(src) or tostring(src), hash,
                        t60 and ('%.3f'):format(t60) or 'nil', t100))
        end
        return
    end

    -- Phase B: compute absolute trim candidate.
    -- Blended from two windows: full 0-100 and the 60-100 segment.
    -- GTA's 0-30 ramp is inflated on all cars, so anchoring purely on 0-100
    -- over-corrects the launch. Weight the 60-100 segment heavier to favour
    -- top-end accuracy while still keeping some 0-100 influence.
    local tNative100 = baseline[100]
    local tNative60  = baseline[60]
    if not tNative100 or tNative100 < 1.0 then return end

    local cand100 = fApplied * (t100 / tNative100)

    local segWeight = (NL and NL.SegWeight) or 0.7   -- 0.7 = 70% from 60-100 segment
    local candidate
    if t60 and tNative60 and tNative60 > 0 then
        local tSeg        = t100 - t60
        local tNativeSeg  = tNative100 - tNative60
        if tSeg > 0.1 and tNativeSeg > 0.1 then
            local cand60_100 = fApplied * (tSeg / tNativeSeg)
            candidate = cand100 * (1.0 - segWeight) + cand60_100 * segWeight
        else
            candidate = cand100
        end
    else
        candidate = cand100
    end

    if candidate < candRejectMin or candidate > candRejectMax then return end
    candidate = svClamp(candidate, (NL and NL.TrimMin) or 0.94, (NL and NL.TrimMax) or 1.08)

    local hasExisting = existing and existing.speedCalC ~= nil
    local current     = hasExisting and svUnpackScalar(existing.speedCalC) or 1.0

    -- Reject if client's fApplied doesn't match server-known trim (spoof guard).
    if math.abs(fApplied - current) > 0.04 then return end

    local nextF  = svBlendTrim(hash, current, candidate, hasExisting, NL)
    local packed = svPackScalar(nextF, NL)

    MySQL.update.await(
        'UPDATE hk_handling SET speedCalC = ? WHERE hash = ?',
        { packed, hash })

    local prev = presetModels[hash] or {}
    presetModels[hash] = {
        type = mtype, paddle = paddle, ratio = ratio,
        speedCal = prev.speedCal, speedCalC = packed,
        hybridClass = prev.hybridClass, evTorque = prev.evTorque, hybridCap = prev.hybridCap,
        speedoStyle = prev.speedoStyle, turboDefault = prev.turboDefault,
        wheelieLaunch = prev.wheelieLaunch,
    }
    pushModels()

    if NL and NL.Debug then
        print(('[hk-normallearn] %s hash=%d native100=%.3f ours100=%.3f fApplied=%.3f cand=%.3f(w=%.1f) -> %.3f')
            :format(GetPlayerName(src) or tostring(src), hash,
                    tNative100, t100, fApplied, candidate, segWeight, nextF))
    end
end)

-----------------------------------------------------------------
-- only fires this for admins.
-----------------------------------------------------------------
RegisterNetEvent('hk-handling:gearbox:seedModel', function(hash, model, name)
    local src = source
    if not isAdmin(src) then return end
    hash = math.tointeger(hash) or tonumber(hash)
    if not hash then return end
    hash = hash & 0xFFFFFFFF
    if seeded[hash] or presetModels[hash] then return end  -- already exists / already seeded
    seeded[hash] = true
    MySQL.update.await(
        'INSERT INTO hk_handling (model, hash, name, manualType, forcePaddle, gearRatioMode) ' ..
        'VALUES (?, ?, ?, 0, 0, 0) ON DUPLICATE KEY UPDATE hash = hash',  -- no-op on conflict
        { model, hash, name })
    presetModels[hash] = { type = 0, paddle = 0, ratio = 0 }
    pushModels()
    if Config.Gearbox and Config.Gearbox.Debug then
        print(('[hk-gearbox] seeded default row for model %s (%s) by %s')
            :format(name or model, hash, GetPlayerName(src) or src))
    end
end)

-----------------------------------------------------------------
-- CHAT PALETTE SUGGESTIONS (admin only)
-- Registers our tuning commands in hk-chat's `/` autocomplete so the admin sees
-- the command name, one-line help, and per-argument hints as they type — instead
-- of only discovering usage via an oxlib/QB error notify. Sent client-side (the
-- chat:addSuggestions event is a CLIENT event) and only to the specific admin
-- source, so the hints never leak to regular players.
-----------------------------------------------------------------
local function pushGearboxSuggestions(target)
    if not target or target == 0 then return end
    TriggerClientEvent('chat:addSuggestions', target, {
        { name = '/setgear',   help = 'Set the current car MODEL gearbox type (all instances)',
          params = {
            { name = 'type|remove', help = '0=NEW-auto 1=manual 2=autoPaddle 3=sportDCT 4=superDCT 5=sequential 6=GTA-native | remove=revert' },
            { name = 'forcePaddle', help = '(optional) 0=normal 1=paddle-only 2=force-auto (DCT only)' },
        } },
        { name = '/gearratio',  help = 'Set MODEL gear-ratio (shift feel) — Standard/Expert mode',
          params = {
            { name = 'mode', help = '0=default 1=sport 2=drag 3=hypercar 4=LST 5=F1box 6=quadturbo' },
        } },
        { name = '/setspeed',   help = 'Calibrate MODEL top speed from a known point — Expert mode',
          params = {
            { name = 'kmh', help = 'measured speed in km/h, or "clear" to reset' },
            { name = 'time', help = 'seconds to reach it (e.g. /setspeed 100 5.5)' },
        } },
        { name = '/setspeedbulk', help = 'Start bulk speed calibration wizard (F8) — Expert mode',
          params = {} },
        { name = '/accelcal',   help = 'Correct band factors from the last /accel run — Expert mode',
          params = {} },
        { name = '/hybridspeedcap', help = 'Set the GLOBAL e-mode profile live for everyone',
          params = {
            { name = 'topKmh', help = 'e-mode top-speed cap in km/h (ICE engages above)' },
            { name = 'power', help = '(optional) e-mode accel strength 0.05-1.0 (e.g. 0.22)' },
        } },
        { name = '/sethybrid',  help = 'Set MODEL hybrid class (DB-persisted, all instances)',
          params = {
            { name = 'class', help = 'none/0 | full/1 (PHEV, EV mode) | semi/2 (KERS assist)' },
            { name = 'evtorque', help = '(optional) full: power 0.05-1.0 | semi: boost mult 1.0-2.0' },
            { name = 'capKmh', help = '(optional, full PHEV only) e-mode top-speed cap' },
            { name = 'speedo', help = '(optional, full PHEV only) 0=full EV cluster 1=semi/KERS look' },
        } },
        { name = '/setturbo',   help = 'Set MODEL turbo FEEL default (DB-persisted, all instances)',
          params = {
            { name = '0|1|clear', help = '1/on=turbo-by-design | 0/off=naturally-aspirated | clear=use config roster' },
        } },
        { name = '/setwheelie', help = 'Force MODEL launch-wheelie opt-in (DB-persisted, all instances)',
          params = {
            { name = '0|1|clear', help = '1/on=force on even off-muscle | 0/off=force off even on muscle | clear=muscle class default' },
        } },
        { name = '/nlstatus',   help = 'Report normal-learner status for a model',
          params = {
            { name = 'hash', help = '(optional) model hash; blank = your current vehicle' },
        } },
        { name = '/accel',      help = 'Arm a 0-200 km/h timer + top-speed capture (any gear mode)',
          params = {} },
        { name = '/gbstate',    help = 'Print a gearbox state snapshot to F8 (debug)',
          params = {} },
        { name = '/lctele',     help = 'Toggle launch-control telemetry print (debug)',
          params = {} },
        { name = '/rpmdebug',   help = 'Toggle on-screen RPM/gear debug overlay',
          params = {} },
        { name = '/handlingdbg', help = 'Toggle the full handling status overlay (throttle/drivetrain/wheelie)',
          params = {} },
        { name = '/throttledbg', help = 'Alias of /handlingdbg — toggle the handling status overlay',
          params = {} },
        { name = '/driftdbg',   help = 'Toggle/inspect a drift debug field',
          params = {
            { name = 'field', help = '(optional) servo|push|gov|flick|csteer|power|yawwrite; blank = report all' },
        } },
        { name = '/abs',        help = 'Toggle ABS off/on for your current car',
          params = {} },
        { name = '/tc',         help = 'Toggle traction control off/on for your current car',
          params = {} },
        { name = '/sportdiff',  help = 'Override the FWD sport-diff assist',
          params = {
            { name = 'on|off|clear', help = 'on=force | off=disable | clear=auto (drivetrain default)' },
        } },
        { name = '/pedalmodel', help = 'Toggle keyboard pedal model (analog throttle/brake synth)',
          params = {
            { name = 'on|off', help = '(optional) blank = toggle' },
        } },
        { name = '/steermodel', help = 'Toggle keyboard steering model (analog steer synth)',
          params = {
            { name = 'on|off', help = '(optional) blank = toggle' },
        } },
        { name = '/biastoggle', help = 'Toggle the drive-bias front/rear tweak (debug)',
          params = {} },
        { name = '/dftoggle',   help = 'Toggle the downforce anti-float model (debug)',
          params = {} },
        { name = '/hkdecay',    help = 'Toggle/inspect the RPM decay debug (debug)',
          params = {} },
        { name = '/gbstockprobe', help = 'Record modded vs stock drivetrain, strip mods, verify (debug)',
          params = {} },
        { name = '/gbtransmod', help = 'Force a transmission mod level for gear-ratio testing',
          params = {
            { name = 'off|0-4', help = 'off/-1 = clear | 0..4 = transmission mod level' },
        } },
        { name = '/gbmfvclamp', help = 'Toggle the per-frame maxFlatVel clamp (debug)',
          params = {
            { name = 'on|off', help = '(optional) blank = toggle' },
        } },
        { name = '/gbpower',    help = 'Scale AuthoritativeBand power for the current car (debug)',
          params = {
            { name = 'forceMult|reset', help = 'reset = stock | number = force/mfv power multiplier' },
        } },
        { name = '/gbauthband', help = 'Dump the AuthoritativeBand dial state (debug)',
          params = {} },
        { name = '/gbcap',      help = 'Dump the current speed-cap state + ring buffer (debug)',
          params = {} },
        { name = '/gbcapauto',  help = 'Toggle automatic speed-cap capture (debug)',
          params = {} },
        { name = '/gbcapclear', help = 'Clear the captured speed-cap for the current car (debug)',
          params = {} },
        { name = '/gbfloorreset', help = 'Reset the maxFlatVel floor for the current car (debug)',
          params = {} },
        { name = '/gbgeartest', help = 'Print a gear-ratio test snapshot (debug)',
          params = {} },
        { name = '/gbratioflip', help = 'Flip/probe the gear-ratio recompute (debug)',
          params = {} },
        { name = '/gbratiotest', help = 'Print a gear-ratio test dump (debug)',
          params = {} },
        { name = '/gbwhy',      help = 'Explain why the gearbox resolved as it did for this car (debug)',
          params = {} },
    })
end

-----------------------------------------------------------------
-- SYNC LIFECYCLE
-----------------------------------------------------------------
-- Client requests the model list on its load (run-through-SQL-on-join model).
RegisterNetEvent('hk-handling:gearbox:requestModels', function()
    pushModels(source)
    -- Push chat-palette suggestions for our admin tuning commands, but ONLY to
    -- admins — these are debug/tuning tools and are deliberately hidden from
    -- regular players (same policy as hk-misc / hk-chat command hiding). The
    -- client fires requestModels on load, so this reaches every admin on join
    -- and on live restart without needing a reconnect.
    if isAdmin(source) then
        pushGearboxSuggestions(source)
    end
end)

AddEventHandler('onResourceStart', function(res)
    if res ~= GetCurrentResourceName() then return end
    loadPresetModels()
    pushModels()  -- live restart with players online
    local n = 0 for _ in pairs(presetModels) do n = n + 1 end
    print(('[hk-gearbox] loaded %d preset model(s) from hk_handling'):format(n))
end)

-- Export for other server scripts to query a model hash.
-- Returns: type(0-6), paddle(0/1/2), ratio(0-3).
exports('getModelGearbox', function(hash)
    hash = math.tointeger(hash) or tonumber(hash)
    local v = hash and presetModels[hash]
    if v then return v.type, v.paddle or 0, v.ratio or 0 end
    return 0, 0, 0
end)
