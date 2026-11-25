-- ═══════════════════════════════════════════════════════════ --
--   HK-GARAGE — live 3D in-world vehicle preview (turntable)      --
--   Spawns the selected car as a LOCAL entity at a hidden pad,     --
--   orbits a camera around it, and lets the player rotate it.      --
--   Nothing is networked or written to the DB during preview.      --
-- ═══════════════════════════════════════════════════════════ --
local QBCore = exports['qb-core']:GetCoreObject()

Preview = Preview or {}

local previewEntity = nil
local previewEntities = {}   -- EVERY entity we've spawned (guards against lag leaks)
local previewGen = 0         -- bumped on every Start/Stop; aborts stale async spawns
local previewNuiToken = nil  -- token from the NUI selection; echoed in Preview* msgs
local previewCam = nil
local previewActive = false
local heading = 0.0
local dragging = false
local lastMouseX = 0.0

local function deleteEnt(ent)
    if ent and DoesEntityExist(ent) then
        SetEntityAsMissionEntity(ent, true, true)
        DeleteEntity(ent)
        if DoesEntityExist(ent) then DeleteVehicle(ent) end
    end
end

-- Fully tear down the preview: delete EVERY preview entity we made (not just the
-- current one — a laggy switch/close can leave earlier ones behind), destroy cam,
-- restore player.
function Preview.Stop()
    previewActive = false
    previewGen = previewGen + 1   -- invalidate any in-flight Start()
    dragging = false
    if previewCam then
        RenderScriptCams(false, false, 0, true, true)
        DestroyCam(previewCam, false)
        previewCam = nil
    end
    for i = #previewEntities, 1, -1 do
        deleteEnt(previewEntities[i])
        previewEntities[i] = nil
    end
    deleteEnt(previewEntity)
    previewEntity = nil
    local ped = PlayerPedId()
    SetEntityVisible(ped, true, false)
    FreezeEntityPosition(ped, false)
    SetEntityCollision(ped, true, true)
    DisplayRadar(true)
end

-- A short throttle "blip" — drives the engine RPM up then eases it back to idle
-- so the preview plays the real engine/exhaust note (a showy redline) instead of
-- the flat idle. Runs in its own thread; bails if the car is gone/superseded.
function Preview.RevBlip(veh)
    local myGen = previewGen
    CreateThread(function()
        if not veh or not DoesEntityExist(veh) then return end
        Wait(250)  -- let the engine-on settle first
        -- ramp UP to a high rev
        for i = 1, 10 do
            if myGen ~= previewGen or not DoesEntityExist(veh) then return end
            SetVehicleCurrentRpm(veh, 0.2 + (i / 10) * 0.75)  -- ~0.95 peak
            Wait(28)
        end
        Wait(140)  -- hold at redline briefly
        -- ease back DOWN to idle
        for i = 10, 0, -1 do
            if myGen ~= previewGen or not DoesEntityExist(veh) then return end
            SetVehicleCurrentRpm(veh, 0.2 + (i / 10) * 0.75)
            Wait(45)
        end
        if DoesEntityExist(veh) and myGen == previewGen then SetVehicleCurrentRpm(veh, 0.2) end
    end)
end

-- Collect performance stats from the car's handling data, normalised to 0-1 for
-- the NUI bars (no numbers shown). accel / top speed / braking / traction.
function Preview.CollectPerf(veh)
    local function hf(field) return GetVehicleHandlingFloat(veh, 'CHandlingData', field) end
    local accel    = hf('fInitialDriveForce')      -- ~0.1–0.45 typical
    local topKmh   = GetVehicleEstimatedMaxSpeed(veh) * 3.6  -- m/s → km/h
    local brakeF   = hf('fBrakeForce')             -- ~0.4–1.2 typical
    local traction = hf('fTractionCurveMax')       -- ~1.8–3.2 typical
    local function norm(v, lo, hi)
        if not v or v <= 0 then return 0 end
        local n = (v - lo) / (hi - lo)
        if n < 0.05 then n = 0.05 elseif n > 1 then n = 1 end
        return n
    end
    -- Braking: GTA's fBrakeForce alone is unreliable on custom-handling cars, so
    -- blend brake force with available grip. Bounds tuned so an average car reads
    -- mid-bar and a strong braker fills it (was capping ~half for everyone).
    local brakeScore = (brakeF * 0.7) + (traction * 0.15)  -- ~0.55–1.1 typical
    return {
        accel    = norm(accel, 0.10, 0.42),
        topspeed = norm(topKmh, 110.0, 320.0),   -- ~300km/h car ≈ full bar
        braking  = math.min(norm(brakeScore, 0.45, 0.95) * 2, 1),  -- ×2 visual boost, capped at full
        traction = norm(traction, 1.70, 2.90),
    }
end

-- Collect all mods on `veh`, grouped NFS-style by system. Returns an ordered
-- list of { title, items = {{label,value}} } sections; empty sections dropped.
function Preview.CollectMods(veh, gearboxType)
    local sections = {}
    local function section(title)
        local s = { title = title, items = {} }
        sections[#sections + 1] = s
        return s
    end
    local function put(s, label, value) s.items[#s.items + 1] = { label = label, value = value } end
    local function lvl(mod) local l = GetVehicleMod(veh, mod); return (l and l >= 0) and ('Lv' .. (l + 1)) or nil end

    -- jim-mechanic status blob (extra internal parts + toggles).
    local jim = nil
    if GetResourceState('mechanic') == 'started' then
        local ok, status = pcall(function() return exports['mechanic']:GetVehicleStatus(veh) end)
        if ok and type(status) == 'table' then jim = status end
    end
    local function jimOn(k) return jim and (jim[k] == 1 or jim[k] == true) end
    local function jimLv(k) return jim and type(jim[k]) == 'number' and jim[k] > 0 and ('Lv' .. jim[k]) or nil end
    -- Generic parts always shown: -1/level-0 (stock) reads "Stock", higher = Lv2+.
    local function lvlBase(mod)
        local l = GetVehicleMod(veh, mod)
        if not l or l < 0 then return 'Stock' end   -- -1 = no upgrade
        if l == 0 then return 'Stock' end           -- level 1 (index 0) = base = Stock
        return 'Lv' .. (l + 1)
    end

    -- ENGINE (core part always shown; jim internals only if fitted)
    local eng = section('引擎 · Engine')
    put(eng, 'Engine', lvlBase(11))
    if jimLv('cylinderlevel') then put(eng, 'Cylinder Head', jimLv('cylinderlevel')) end
    if jimLv('oillevel') then put(eng, 'Oil Pump', jimLv('oillevel')) end
    if jimLv('fuellevel') then put(eng, 'Fuel Box', jimLv('fuellevel')) end

    -- DRIVETRAIN
    local dt = section('傳動 · Drivetrain')
    put(dt, 'Transmission', lvlBase(13))
    put(dt, 'Gearbox', (gearboxType and gearboxType ~= '') and gearboxType or 'Automatic')
    if jimLv('shaftlevel') then put(dt, 'Drive Shaft', jimLv('shaftlevel')) end
    if jimLv('cablelevel') then put(dt, 'Battery Cable', jimLv('cablelevel')) end

    -- CHASSIS (brakes + handling + armor)
    local ch = section('底盤 · Chassis')
    put(ch, 'Brakes', lvlBase(12))
    put(ch, 'Suspension', lvlBase(15))
    if lvl(16) then put(ch, 'Armor', lvl(16)) end

    -- WHEELS
    local wh = section('輪圈 · Wheels')
    local wtype = GetVehicleWheelType(veh)
    local wnames = { [0]='Sport',[1]='Muscle',[2]='Lowrider',[3]='SUV',[4]='Offroad',[5]='Tuner',[6]='Bike',[7]='High End' }
    -- "Rims" only if a CUSTOM rim design is actually fitted (mod 23 >= 0 = chosen
    -- from the rim list; -1 = the vehicle's original rims). Rim Type (the wheel
    -- category) is always shown underneath.
    local frontW = GetVehicleMod(veh, 23)
    if frontW and frontW >= 0 then
        put(wh, 'Rims', '#' .. (frontW + 1))
    else
        put(wh, 'Rims', 'Stock')
    end
    put(wh, 'Rim Type', wnames[wtype] or 'Stock')

    -- POWER (forced induction + power adders)
    local pw = section('動力 · Power')
    if IsToggleModOn(veh, 18) then put(pw, 'Turbo', '✓') end
    if jimOn('antiLag') then put(pw, 'Anti-Lag', '✓') end
    if jimOn('hasnitro') then put(pw, 'Nitrous', '✓') end
    if jimOn('harness') then put(pw, 'Harness', '✓') end

    -- STYLE / ELECTRONICS
    local st = section('外觀 · Style')
    if IsToggleModOn(veh, 22) then put(st, 'Xenon', '✓') end
    if IsVehicleNeonLightEnabled(veh, 0) or IsVehicleNeonLightEnabled(veh, 1)
       or IsVehicleNeonLightEnabled(veh, 2) or IsVehicleNeonLightEnabled(veh, 3) then put(st, 'Neon', '✓') end
    if jimOn('underglow') then put(st, 'Underglow', '✓') end

    -- drop empty sections
    local final = {}
    for _, s in ipairs(sections) do if #s.items > 0 then final[#final + 1] = s end end
    return final
end

local function loadModel(hash)
    RequestModel(hash)
    local t = 0
    while not HasModelLoaded(hash) and t < 200 do Wait(10); t = t + 1 end
    return HasModelLoaded(hash)
end

local previewAnchor = nil  -- where the preview car is spawned

-- Spawn the preview car + camera. `data` = { vehicle, plate, garage, ... }.
-- The car spawns AT the player's own position — ground/collision are guaranteed
-- loaded there (the player is standing on it), so it always renders. Local,
-- non-networked entity = only this player can see it.
function Preview.Start(data)
    if not Config.Preview or not Config.Preview.enabled then return false end
    if previewActive then Preview.Stop() end
    previewGen = previewGen + 1
    local myGen = previewGen        -- this spawn's identity; if it changes, we abort
    previewNuiToken = data.token    -- echoed back in Preview* messages (stale-guard)
    local model = GetHashKey(data.vehicle)
    if not loadModel(model) then
        lib.notify({ title = 'HK Parking', description = Lang:t('error.no_vehicles'), type = 'error' })
        return false
    end

    local ped = PlayerPedId()
    local pc = GetEntityCoords(ped)
    local groundZ = pc.z
    local found, gz = GetGroundZFor_3dCoord(pc.x, pc.y, pc.z + 1.0, false)
    if found then groundZ = gz end
    local p = { x = pc.x + 0.0, y = pc.y + 0.0, z = groundZ + 0.0, w = 0.0 }
    previewAnchor = p

    -- Local, non-networked spawn so no one else sees it and no DB write happens.
    previewEntity = CreateVehicle(model, p.x, p.y, p.z, p.w, false, false)
    previewEntities[#previewEntities + 1] = previewEntity -- track for guaranteed cleanup
    local t = 0
    while not DoesEntityExist(previewEntity) and t < 100 do Wait(10); t = t + 1 end
    if not DoesEntityExist(previewEntity) then
        SetModelAsNoLongerNeeded(model)
        return false
    end
    -- If the menu was closed / another car selected while this laggy spawn was in
    -- flight, abort and delete it now so it can't linger in the world.
    if myGen ~= previewGen then
        deleteEnt(previewEntity)
        previewEntity = nil
        SetModelAsNoLongerNeeded(model)
        return false
    end

    SetEntityAsMissionEntity(previewEntity, true, true)
    -- Flag so hk-scenario (and any clear-area script) skips this entity.
    Entity(previewEntity).state.hkNoClear = true
    SetEntityCoordsNoOffset(previewEntity, p.x, p.y, p.z, false, false, false)
    SetVehicleOnGroundProperly(previewEntity)
    FreezeEntityPosition(previewEntity, true)
    SetEntityInvincible(previewEntity, true)
    SetEntityCollision(previewEntity, false, false)
    SetVehicleDoorsLocked(previewEntity, 2)
    SetVehicleNumberPlateText(previewEntity, data.plate or '')
    SetVehicleEngineOn(previewEntity, true, true, true) -- instant on, no starter anim
    SetVehicleLights(previewEntity, 2)
    SetModelAsNoLongerNeeded(model)

    -- Start facing the camera at a slight 3/4 (car's ~1 o'clock toward us). The
    -- camera sits at 35° off the car's -Y; face the front toward it + 30° bias.
    heading = (35.0 + 180.0 + 15.0) % 360.0  -- +15 bias
    SetEntityHeading(previewEntity, heading)

    -- A quick rev "blip" so it shows off the real engine/exhaust note (not the
    -- flat idle-from-startup sound). Drives the RPM up and eases it back to idle.
    Preview.RevBlip(previewEntity)

    -- Apply the real stored mods/colours so the preview matches the owned car.
    QBCore.Functions.TriggerCallback('hk-garage:server:GetPreviewProps', function(props)
        if props and next(props) and DoesEntityExist(previewEntity) then
            QBCore.Functions.SetVehicleProperties(previewEntity, props)
        end
        -- Read the native + jim-mechanic mod status off the applied car (plus the
        -- model's gearbox type) and push it to the NUI grouped by system.
        Wait(200)
        if DoesEntityExist(previewEntity) then
            -- Performance bars (accel / top speed / braking / traction) from the
            -- car's live handling stats, normalised to 0-1 for the NUI bars.
            SendNUIMessage({ action = 'PreviewPerf', perf = Preview.CollectPerf(previewEntity), token = previewNuiToken })
            -- Tier: use hk-race's REAL classifier on the spawned car. Retry a few
            -- times — the car needs a beat for speed/handling natives to be ready.
            if GetResourceState('hk-race') == 'started' then
                local myGen2 = previewGen
                CreateThread(function()
                    for _ = 1, 10 do
                        if myGen2 ~= previewGen or not DoesEntityExist(previewEntity) then return end
                        local ok, t = pcall(function() return exports['hk-race']:getVehicleTier(previewEntity) end)
                        if ok and type(t) == 'table' and t.name then
                            SendNUIMessage({ action = 'PreviewTier', tier = t.name, token = previewNuiToken })
                            if Config.Preview.debug then print(('[hk-parking] tier=%s src=%s'):format(t.name, tostring(t.source))) end
                            return
                        end
                        Wait(200)
                    end
                    if Config.Preview.debug then print('[hk-parking] tier: no result from hk-race') end
                end)
            elseif Config.Preview.debug then
                print('[hk-parking] hk-race not started')
            end
            -- Drive layout (FWD/AWD/RWD): hk-handling's own classifier — the SAME
            -- bucket its drivetrain handler routes the car into (rwd <0.49 / awd
            -- ≤0.61 / fwd). Distinct from the gearbox label. Retry: fDriveBiasFront
            -- needs a beat to be readable after the properties apply.
            if GetResourceState('hk-handling') == 'started' then
                local myGen3 = previewGen
                CreateThread(function()
                    for _ = 1, 10 do
                        if myGen3 ~= previewGen or not DoesEntityExist(previewEntity) then return end
                        local ok, info = pcall(function() return exports['hk-handling']:GetDriveClass(previewEntity) end)
                        if ok and type(info) == 'table' and info.class then
                            SendNUIMessage({ action = 'PreviewDrive', drive = string.upper(info.class), token = previewNuiToken })
                            if Config.Preview.debug then print(('[hk-parking] drive=%s bias=%.2f'):format(info.class, info.bias or -1)) end
                            return
                        end
                        Wait(200)
                    end
                    if Config.Preview.debug then print('[hk-parking] drive: no result from hk-handling') end
                end)
            elseif Config.Preview.debug then
                print('[hk-parking] hk-handling not started')
            end
            QBCore.Functions.TriggerCallback('hk-garage:server:GetGearboxType', function(gbType)
                if DoesEntityExist(previewEntity) then
                    SendNUIMessage({ action = 'PreviewMods', sections = Preview.CollectMods(previewEntity, gbType), token = previewNuiToken })
                end
            end, data.vehicle)
        end
    end, data.plate)

    Preview.SetupCamera()
    previewActive = true
    return true
end

local frame = nil   -- cached framing: { p, dist, dirX, dirY, midZ, shift, base_h }

-- Position the camera from the cached frame, aimed at the car's mid-height.
local function ApplyCam()
    if not previewCam or not frame then return end
    local p = frame.p
    local camZ = p.z + frame.base_h + frame.midZ
    local camX = p.x + frame.dist * frame.dirX
    local camY = p.y + frame.dist * frame.dirY
    SetCamCoord(previewCam, camX, camY, camZ)
    PointCamAtCoord(previewCam, p.x + frame.rightX * frame.shift,
                                 p.y + frame.rightY * frame.shift, p.z + frame.midZ)
end

-- Point a scripted camera at the vehicle. The CAR rotates (turntable) via drag/
-- auto-spin; the camera is static. Distance auto-scales to the model's size so
-- the WHOLE car is framed.
function Preview.SetupCamera()
    local p = previewAnchor
    local base = Config.Preview.camDist or 6.5
    local h = Config.Preview.camHeight or 1.4
    local fov = Config.Preview.camFov or 42.0

    -- Auto-fit distance + aim at mid-body height.
    local dist = base
    local midZ = 0.6
    if previewEntity and DoesEntityExist(previewEntity) then
        local mn, mx = GetModelDimensions(GetEntityModel(previewEntity))
        local len = math.max(mx.x - mn.x, mx.y - mn.y)
        dist = math.max(base, len * (Config.Preview.sizePad or 2.4))
        midZ = ((mx.z - mn.z) * 0.5) + 0.2
    end

    local ang = math.rad(35.0)
    local dirX, dirY = math.sin(ang), -math.cos(ang)     -- car→cam direction
    local shift = dist * (Config.Preview.lateralShift or 0.0)
    frame = {
        p = p, dist = dist, dirX = dirX, dirY = dirY, midZ = midZ,
        base_h = h, shift = shift, rightX = -dirY, rightY = dirX,
    }

    previewCam = CreateCamWithParams('DEFAULT_SCRIPTED_CAMERA',
        p.x + dist * dirX, p.y + dist * dirY, p.z + h + midZ, 0.0, 0.0, 0.0, fov, true, 0)
    SetCamActive(previewCam, true)
    RenderScriptCams(true, false, 0, true, true)
    ApplyCam()   -- position + aim

    -- Hide the player + radar during preview.
    local ped = PlayerPedId()
    SetEntityVisible(ped, false, false)
    FreezeEntityPosition(ped, true)
    SetEntityCollision(ped, false, false)
    DisplayRadar(false)
end

-- Apply a rotation delta from the NUI drag (degrees). Pauses auto-spin briefly.
function Preview.Rotate(delta)
    if not previewActive then return end
    heading = (heading + (delta or 0.0)) % 360.0
    dragging = true
    lastMouseX = GetGameTimer()  -- reused as "last manual rotate" timestamp
end

-- Rotation loop. Auto-spins unless the player recently dragged (NUI mousemove).
CreateThread(function()
    while true do
        if previewActive and previewEntity and DoesEntityExist(previewEntity) then
            -- resume auto-spin ~1s after the last manual drag
            if dragging and (GetGameTimer() - lastMouseX) > 1000 then dragging = false end
            if not dragging and (Config.Preview.autoSpin or 0) > 0 then
                heading = (heading + (Config.Preview.autoSpin * GetFrameTime())) % 360.0
            end
            SetEntityHeading(previewEntity, heading + 0.0)
            Wait(0)
        else
            -- Safety sweep: if the preview isn't active but tracked entities still
            -- exist (a lag leak slipped through), purge them.
            if not previewActive and #previewEntities > 0 then Preview.Stop() end
            Wait(250)
        end
    end
end)

AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() then Preview.Stop() end
end)
