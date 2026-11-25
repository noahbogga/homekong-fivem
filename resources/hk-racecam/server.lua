-----------------------------------------------------------------
-- hk-racecam :: server.lua
--
-- Handles admin permission checks and config file saving for the
-- debug menu.
-----------------------------------------------------------------

local function isAdmin(source)
    -- 1. Check QBCore admin permission
    local success, result = pcall(function()
        local Player = exports['qb-core']:GetPlayer(source)
        return Player and (Player.PlayerData.job.name == 'admin' or exports['qb-core']:HasPermission(source, 'admin'))
    end)
    if success and result then return true end

    -- 2. Check CFX built-in admin (server owner / console)
    if IsPlayerAceAllowed(source, 'command') then return true end
    -- 2b. txAdmin admin check
    if IsPlayerAceAllowed(source, "command.kick") then return true end

    -- 3. Check Discord roles (if badger_discord_api is present)
    local discordSuccess, discordRoles = pcall(function()
        return exports.badger_discord_api:GetDiscordRoles(source)
    end)
    if discordSuccess and discordRoles then
        -- Check for common admin role IDs (customize these for your server)
        local adminRoleIds = {
            -- Add your Discord admin role IDs here, e.g.:
            -- '1234567890123456789',  -- Admin role
            -- '9876543210987654321',  -- Moderator role
        }
        for _, roleId in ipairs(adminRoleIds) do
            for _, userRole in ipairs(discordRoles) do
                if tostring(userRole) == roleId then
                    return true
                end
            end
        end
    end

    return false
end

RegisterNetEvent('hk-racecam:requestDebugAccess', function()
    local src = source
    if isAdmin(src) then
        TriggerClientEvent('hk-racecam:openDebugMenu', src)
    else
        TriggerClientEvent('hk-racecam:accessDenied', src)
    end
end)

RegisterNetEvent('hk-racecam:saveConfig', function(data)
    local src = source
    if not isAdmin(src) then
        print(('[hk-racecam] Player %d attempted to save config without admin permission'):format(src))
        return
    end

    local configPath = GetResourcePath(GetCurrentResourceName()) .. '/config.lua'
    local file = io.open(configPath, 'r')
    if not file then
        print('[hk-racecam] ERROR: Could not open config.lua for reading')
        return
    end

    local content = file:read('*all')
    file:close()

    -- With per-V-mode overrides, we need to rebuild the ViewModeOverrides block
    -- instead of touching the base chase preset. The client sends currentViewMode
    -- and we write to Config.ViewModeOverrides structure.

    -- Build ViewModeOverrides block from the data. The client sends the current
    -- view mode + edited values; we merge those into the existing override structure.
    if data.chase and data.currentViewMode then
        local mode = data.currentViewMode

        -- Build the _base block (shared fields)
        local baseBlock = string.format([[    _base = {
        smoothness       = %.3f,
        fovSmoothness    = %.3f,
        lookAheadSpeed   = 1.8,
        lookHeight       = 1.35,
        lookAheadBase    = %.2f,
        rampMaxSpeedKmh  = %.1f,
        fov = { min = %.1f, max = %.1f },
    }]],
            data.chase.smoothness or 0.09,
            data.chase.fovSmoothness or 0.35,
            data.chase.lookAheadBase or 0.60,
            data.chase.rampMaxSpeedKmh or 120.0,
            data.chase.fovMin or 55.0,
            data.chase.fovMax or 65.0
        )

        -- Mode 0: use incoming data if mode==0, else preserve current server config
        local m0 = (mode == 0) and data.chase or (Config.ViewModeOverrides and Config.ViewModeOverrides[0])
        local m0FovMin = m0 and (m0.fovMin or (m0.fov and m0.fov.min)) or 54.0
        local m0FovMax = m0 and (m0.fovMax or (m0.fov and m0.fov.max)) or 56.0
        local mode0Block = string.format([[
    [0] = {
        distanceTrim     = %.2f,
        minExtraDistance = %.2f,
        maxExtraDistance = %.2f,
        maxBaseDistance  = %.2f,
        baseHeight       = %.2f,
        heightLift       = %.2f,
        fov = { min = %.1f, max = %.1f },
        lookAheadBase    = %.2f,
    }]],
            (m0 and m0.distanceTrim) or -0.50,
            (m0 and m0.minExtraDistance) or 8.00,
            (m0 and m0.maxExtraDistance) or 30.00,
            (m0 and m0.maxBaseDistance) or 4.00,
            (m0 and m0.baseHeight) or 1.26,
            (m0 and m0.heightLift) or 0.92,
            m0FovMin, m0FovMax,
            (m0 and m0.lookAheadBase) or 1.20
        )

        -- Mode 1: use incoming data if mode==1, else preserve current server config
        local m1 = (mode == 1) and data.chase or (Config.ViewModeOverrides and Config.ViewModeOverrides[1])
        local m1FovMin = m1 and (m1.fovMin or (m1.fov and m1.fov.min)) or 62.0
        local m1FovMax = m1 and (m1.fovMax or (m1.fov and m1.fov.max)) or 68.0
        local mode1Block = string.format([[
    [1] = {
        distanceTrim     = %.2f,
        baseDistance     = %.2f,
        minExtraDistance = %.2f,
        maxExtraDistance = %.2f,
        maxBaseDistance  = %.2f,
        baseHeight       = %.2f,
        minHeight        = %.2f,
        heightLift       = %.2f,
        fov = { min = %.1f, max = %.1f },
    }]],
            (m1 and m1.distanceTrim) or 1.75,
            (m1 and m1.baseDistance) or 7.00,
            (m1 and m1.minExtraDistance) or 0.00,
            (m1 and m1.maxExtraDistance) or 0.25,
            (m1 and m1.maxBaseDistance) or 4.10,
            (m1 and m1.baseHeight) or 0.90,
            (m1 and m1.minHeight) or 0.38,
            (m1 and m1.heightLift) or 1.20,
            m1FovMin, m1FovMax
        )

        -- Mode 2: use incoming data if mode==2, else preserve current server config
        local m2 = (mode == 2) and data.chase or (Config.ViewModeOverrides and Config.ViewModeOverrides[2])
        local m2FovMin = m2 and (m2.fovMin or (m2.fov and m2.fov.min)) or 52.5
        local m2FovMax = m2 and (m2.fovMax or (m2.fov and m2.fov.max)) or 56.5
        local mode2Block = string.format([[
    [2] = {
        distanceTrim     = %.2f,
        minExtraDistance = %.2f,
        maxExtraDistance = %.2f,
        maxBaseDistance  = %.2f,
        baseHeight       = %.2f,
        heightLift       = %.2f,
        fov = { min = %.1f, max = %.1f },
        smoothness       = %.3f,
        fovSmoothness    = %.3f,
    }]],
            (m2 and m2.distanceTrim) or -0.80,
            (m2 and m2.minExtraDistance) or 0.00,
            (m2 and m2.maxExtraDistance) or 0.00,
            (m2 and m2.maxBaseDistance) or 5.65,
            (m2 and m2.baseHeight) or 0.80,
            (m2 and m2.heightLift) or 1.10,
            m2FovMin, m2FovMax,
            (m2 and m2.smoothness) or 0.18,
            (m2 and m2.fovSmoothness) or 0.26
        )

        local fullOverridesBlock = string.format([[Config.ViewModeOverrides = {
    -- ALL MODES: shared baseline tweaks (applied to base preset first)
%s,

    -- MODE 0: NEAR (V pos 2)
%s,

    -- MODE 1: MEDIUM (V pos 3)
%s,

    -- MODE 2: FAR (V pos 4)
%s,
}]],
            baseBlock, mode0Block, mode1Block, mode2Block
        )

        -- Replace the entire Config.ViewModeOverrides block
        content = content:gsub('Config%.ViewModeOverrides = %b{}', fullOverridesBlock, 1)
    end

    -- Bonnet preset (unchanged, still a flat write)
    if data.bonnet then
        local bonnetBlock = string.format([[    bonnet = {
        type = 'bone',
        bones    = { 'bonnet', 'engine', 'chassis' },
        offset   = vector3(%.2f, %.2f, %.2f),
        rotOffset = vector3(%.1f, 0.0, 0.0),
        fov = %.1f,
        smoothness = %.3f,
        followRoll = true,
        rollDamp = 0.85,
    }]],
            data.bonnet.offsetX,
            data.bonnet.offsetY,
            data.bonnet.offsetZ,
            data.bonnet.rotX,
            data.bonnet.fov,
            data.bonnet.smoothness
        )
        content = content:gsub('    hood = %b{}', bonnetBlock, 1)
    end

    -- Write back to file
    file = io.open(configPath, 'w')
    if not file then
        print('[hk-racecam] ERROR: Could not open config.lua for writing')
        return
    end

    file:write(content)
    file:close()

    print(('[hk-racecam] Config saved by admin (player %d) — V-mode %d updated'):format(src, data.currentViewMode or -1))
end)

RegisterNetEvent('hk-racecam:broadcastConfig', function(data)
    local src = source
    if not isAdmin(src) then
        print(('[hk-racecam] Player %d attempted to broadcast config without admin permission'):format(src))
        return
    end

    -- Convert data to preset format
    local presets = {
        chase = {
            type = 'free',
            useGtaDistance = true,
            distanceTrim = data.chase.distanceTrim or 0.0,
            baseDistance = data.chase.baseDistance,
            maxExtraDistance = data.chase.maxExtraDistance,
            maxBaseDistance = data.chase.maxBaseDistance or 6.5,
            baseHeight = data.chase.baseHeight,
            minHeight = data.chase.minHeight or 0.56,
            heightLift = data.chase.heightLift or 0.0,
            heightDropAtSpeed = 0.4,
            lookHeight = 1.0,
            lookAheadBase = data.chase.lookAheadBase or 1.2,
            lookAheadSpeed = 3.5,
            fov = { min = data.chase.fovMin, max = data.chase.fovMax },
            maxSpeedKmh = 155.0,
            smoothness = data.chase.smoothness,
            fovSmoothness = data.chase.fovSmoothness,
            lateralFactor = 1.4,
            shakeAtSpeedKmh = 95.0,
            shakeMax = 0.18,
            shakeName = 'HAND_SHAKE',
        },
        bonnet = {
            type = 'bone',
            bones = { 'bonnet', 'engine', 'chassis' },
            offset = vector3(data.bonnet.offsetX, data.bonnet.offsetY, data.bonnet.offsetZ),
            rotOffset = vector3(data.bonnet.rotX, 0.0, 0.0),
            fov = data.bonnet.fov,
            smoothness = data.bonnet.smoothness,
            followRoll = true,
            rollDamp = 0.85,
        },
    }

    -- Broadcast to all players
    TriggerClientEvent('hk-racecam:updateConfig', -1, presets)
    print(('[hk-racecam] Config broadcasted to all players by admin (player %d)'):format(src))
end)

RegisterNetEvent('hk-racecam:requestConfig', function()
    local src = source
    if not isAdmin(src) then return end

    -- Send current config back to client
    TriggerClientEvent('hk-racecam:receiveConfig', src, Config.Presets)
end)

-----------------------------------------------------------------
-- HEADING-SNAP CORRECTION VALIDATION
-- The client detects impossible single-frame heading jumps (caused by the
-- GTA engine's scripted-cam steering bug) and corrects them with SetEntityHeading.
-- This handler logs + rate-limits to prevent abuse (someone spoofing corrections
-- to spin their car intentionally). Max 3 corrections per 5 seconds per player.
-----------------------------------------------------------------
local headingCorrectionLog = {}  -- [playerId] = { count, windowStart }

RegisterNetEvent('hk-racecam:headingCorrection', function(deltaDeg, correctedTo)
    local src = source
    local now = os.time()

    -- Rate limit: max 3 corrections per 5-second window
    if not headingCorrectionLog[src] then
        headingCorrectionLog[src] = { count = 0, windowStart = now }
    end
    local log = headingCorrectionLog[src]

    -- Reset window if expired
    if (now - log.windowStart) > 5 then
        log.count = 0
        log.windowStart = now
    end

    log.count = log.count + 1

    if log.count > 3 then
        -- Too many corrections — possible abuse. Log but don't kick (could be laggy player).
        print(('[hk-racecam] WARNING: Player %d exceeded heading-correction rate limit (%d in 5s) — possible abuse')
            :format(src, log.count))
        return
    end

    -- Valid correction — just log for monitoring
    if log.count == 1 then
        print(('[hk-racecam] Player %d: heading-snap corrected (%.1f° jump → restored to %.1f°)')
            :format(src, deltaDeg or 0, correctedTo or 0))
    end
end)

-- Clean up on player drop
AddEventHandler('playerDropped', function()
    headingCorrectionLog[source] = nil
end)

-----------------------------------------------------------------
-- BONNET CAM PRESETS (per-vehicle-model persistence)
-- Saved by admins via /savebonnet, loaded by all players on join.
-- Stored in bonnet_presets.json alongside the resource.
-----------------------------------------------------------------
local bonnetPresetsFile = GetResourcePath(GetCurrentResourceName()) .. "/bonnet_presets.json"
local bonnetPresets = {}  -- [modelName] = { offsetY, offsetZ, tilt }

-- Load on resource start
local function loadHoodPresets()
    local file = io.open(bonnetPresetsFile, "r")
    if file then
        local raw = file:read("*all")
        file:close()
        local decoded = json.decode(raw)
        if type(decoded) == "table" then
            bonnetPresets = decoded
            local count = 0
            for _ in pairs(bonnetPresets) do count = count + 1 end
            print(("[hk-racecam] Loaded %d bonnet presets from file"):format(count))
        end
    else
        print("[hk-racecam] No bonnet_presets.json found, starting fresh")
    end
end

local function saveBonnetPresets()
    local file = io.open(bonnetPresetsFile, "w")
    if not file then
        print("[hk-racecam] ERROR: Could not write bonnet_presets.json")
        return false
    end
    file:write(json.encode(bonnetPresets))
    file:close()
    return true
end

loadHoodPresets()

-- Admin saves a bonnet preset for a specific vehicle model
RegisterNetEvent("hk-racecam:saveBonnetPreset", function(modelName, offsetY, offsetZ, tilt)
    print(("[hk-racecam] saveBonnetPreset called by %d for %s"):format(source or -1, tostring(modelName)))
    local src = source
    if not isAdmin(src) then
        TriggerClientEvent("chat:addMessage", src, { args = { "^1[hk-racecam]", "Admin permission required for /savebonnet" } })
        return
    end

    if type(modelName) ~= "string" or modelName == "" then return end

    bonnetPresets[modelName] = {
        offsetY = tonumber(offsetY) or 0.0,
        offsetZ = tonumber(offsetZ) or 0.0,
        tilt    = tonumber(tilt) or 0.0,
    }

    if saveBonnetPresets() then
        -- Broadcast to all players so it takes effect immediately
        TriggerClientEvent("hk-racecam:receiveBonnetPresets", -1, bonnetPresets)
        print(("[hk-racecam] Bonnet preset saved for %s by player %d: Y=%.2f Z=%.2f T=%.1f"):format(
            modelName, src, offsetY or 0, offsetZ or 0, tilt or 0))
    end
end)

-- Player requests bonnet presets (on join / resource start)
RegisterNetEvent("hk-racecam:requestBonnetPresets", function()
    local src = source
    TriggerClientEvent("hk-racecam:receiveBonnetPresets", src, bonnetPresets)
end)

-- Chase cam presets (same pattern as bonnet presets)
local chasePresetsFile = GetResourcePath(GetCurrentResourceName()) .. "/chase_presets.json"
local chasePresets = {}

local function loadChasePresets()
    local file = io.open(chasePresetsFile, "r")
    if file then
        local raw = file:read("*all")
        file:close()
        local decoded = json.decode(raw)
        if type(decoded) == "table" then
            chasePresets = decoded
            local count = 0
            for _ in pairs(chasePresets) do count = count + 1 end
            print(("[hk-racecam] Loaded %d chase presets from file"):format(count))
        end
    end
end

local function saveChasePresets()
    local file = io.open(chasePresetsFile, "w")
    if not file then return false end
    file:write(json.encode(chasePresets))
    file:close()
    return true
end

loadChasePresets()

RegisterNetEvent("hk-racecam:saveChasePreset", function(modelName, offsetY, offsetZ, tilt)
    print(("[hk-racecam] saveChasePreset called by %d for %s"):format(source or -1, tostring(modelName)))
    local src = source
    if not isAdmin(src) then
        TriggerClientEvent("chat:addMessage", src, { args = { "^1[hk-racecam]", "Admin permission required for /setchase" } })
        return
    end
    if type(modelName) ~= "string" or modelName == "" then return end
    chasePresets[modelName] = {
        offsetY = tonumber(offsetY) or 0.0,
        offsetZ = tonumber(offsetZ) or 0.0,
        tilt    = tonumber(tilt) or 0.0,
    }
    if saveChasePresets() then
        TriggerClientEvent("hk-racecam:receiveChasePresets", -1, chasePresets)
        print(("[hk-racecam] Chase preset saved for '%s' by player %d"):format(modelName, src))
    end
end)

RegisterNetEvent("hk-racecam:requestChasePresets", function()
    local src = source
    TriggerClientEvent("hk-racecam:receiveChasePresets", src, chasePresets)
end)
