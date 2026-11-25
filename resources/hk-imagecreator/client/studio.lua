local QBCore = exports['qb-core']:GetCoreObject()
local isInStudio = false
local isInPhotoMode = false
local originalCoords = nil
local originalVehicle = nil
local studioVehicle = nil
local studioCam = nil
local currentPresetIndex = 1
local greenScreenObj = nil

-- ============================================================
-- PERMISSION CHECK
-- ============================================================
local function HasPermission()
    if not Config.AdminOnly then return true end
    local PlayerData = QBCore.Functions.GetPlayerData()
    if not PlayerData or not PlayerData.job then return false end
    for _, group in ipairs(Config.AdminGroups) do
        if QBCore.Functions.HasPermission(group) then return true end
    end
    -- Also check god mode
    if PlayerData.metadata and PlayerData.metadata.isdead == false then
        -- Check via admin perms
        return exports['qb-admin'] and exports['qb-admin']:HasPermission()
    end
    return false
end

-- ============================================================
-- STUDIO MODE - TP to sky, green screen, vehicle capture
-- ============================================================
function EnterStudio(mode)
    if isInStudio then return end
    if not HasPermission() then
        lib.notify({ title = 'Image Creator', description = 'No permission', type = 'error' })
        return
    end

    isInStudio = true
    local ped = PlayerPedId()
    originalCoords = GetEntityCoords(ped)

    -- If in vehicle, store it
    local currentVeh = GetVehiclePedIsIn(ped, false)
    if currentVeh ~= 0 then
        originalVehicle = {
            model = GetEntityModel(currentVeh),
            mods = lib.getVehicleProperties(currentVeh),
        }
    end

    -- Freeze and hide player
    SetEntityVisible(ped, false, false)
    FreezeEntityPosition(ped, true)
    SetEntityCoords(ped, Config.Studio.coords.x, Config.Studio.coords.y, Config.Studio.coords.z, false, false, false, false)

    Wait(500)

    -- Create green screen platform
    CreateGreenScreen()

    -- Spawn vehicle in studio if we had one (or mode is 'vehicle')
    if mode == 'vehicle' and originalVehicle then
        SpawnStudioVehicle(originalVehicle.model, originalVehicle.mods)
    end

    -- Setup camera
    SetupStudioCam(1)

    -- Open NUI
    SendNUIMessage({ action = 'openStudio', presets = Config.Studio.presets, currentPreset = 1 })
    SetNuiFocus(true, true)

    lib.notify({ title = 'Image Creator', description = 'Studio mode active', type = 'success' })
end

function CreateGreenScreen()
    -- Use a large flat object as green screen background
    -- We'll just set the timecycle to make the sky a solid color
    SetTimecycleModifier('hud_def_blur')
    SetTimecycleModifierStrength(0.0)

    -- Clear weather and set time for consistent lighting
    NetworkOverrideClockTime(12, 0, 0)
    ClearOverrideWeather()
    ClearWeatherTypePersist()
    SetWeatherTypePersist('EXTRASUNNY')
    SetWeatherTypeNow('EXTRASUNNY')
    SetWeatherTypeNowPersist('EXTRASUNNY')

    -- Disable clouds
    SetCloudHatOpacity(0.0)
    HideHudAndRadarThisFrame()
end

function SpawnStudioVehicle(model, mods)
    lib.requestModel(model)
    local coords = Config.Studio.coords
    studioVehicle = CreateVehicle(model, coords.x, coords.y, coords.z - 0.5, 0.0, false, false)
    SetEntityHeading(studioVehicle, 0.0)
    FreezeEntityPosition(studioVehicle, true)
    SetVehicleOnGroundProperly(studioVehicle)
    SetModelAsNoLongerNeeded(model)

    if mods then
        lib.setVehicleProperties(studioVehicle, mods)
    end

    -- Good lighting on vehicle
    SetVehicleLights(studioVehicle, 0)
    SetVehicleEngineOn(studioVehicle, true, true, false)
end

function SetupStudioCam(presetIndex)
    currentPresetIndex = presetIndex
    local preset = Config.Studio.presets[presetIndex]
    if not preset then return end

    local target = Config.Studio.coords
    if studioVehicle and DoesEntityExist(studioVehicle) then
        target = GetEntityCoords(studioVehicle)
    end

    -- Calculate camera position from angle/pitch/distance
    local angleRad = math.rad(preset.angle)
    local pitchRad = math.rad(preset.pitch)
    local dist = preset.distance

    local camX = target.x + (dist * math.cos(pitchRad) * math.sin(angleRad))
    local camY = target.y + (dist * math.cos(pitchRad) * math.cos(angleRad))
    local camZ = target.z + (dist * math.sin(-pitchRad))

    if studioCam then
        DestroyCam(studioCam, false)
    end

    studioCam = CreateCam('DEFAULT_SCRIPTED_CAMERA', true)
    SetCamCoord(studioCam, camX, camY, camZ)
    PointCamAtCoord(studioCam, target.x, target.y, target.z)
    SetCamFov(studioCam, 40.0)
    SetCamActive(studioCam, true)
    RenderScriptCams(true, true, 500, true, false)
end

function ExitStudio()
    if not isInStudio then return end

    -- Cleanup
    SendNUIMessage({ action = 'close' })
    SetNuiFocus(false, false)

    if studioCam then
        RenderScriptCams(false, true, 500, true, false)
        DestroyCam(studioCam, false)
        studioCam = nil
    end

    if studioVehicle and DoesEntityExist(studioVehicle) then
        DeleteEntity(studioVehicle)
        studioVehicle = nil
    end

    -- Restore player
    local ped = PlayerPedId()
    SetEntityVisible(ped, true, false)
    FreezeEntityPosition(ped, false)

    if originalCoords then
        SetEntityCoords(ped, originalCoords.x, originalCoords.y, originalCoords.z, false, false, false, false)
    end

    -- Restore timecycle
    ClearTimecycleModifier()
    SetCloudHatOpacity(1.0)
    NetworkOverrideClockTime(0, 0, 0)
    ClearOverrideWeather()

    isInStudio = false
    originalCoords = nil
    originalVehicle = nil
    currentPresetIndex = 1

    lib.notify({ title = 'Image Creator', description = 'Studio closed', type = 'info' })
end

-- ============================================================
-- STUDIO SCREENSHOT (captures viewport, sends to server for upload)
-- ============================================================
function TakeStudioScreenshot()
    -- Hide all HUD
    HideHudAndRadarThisFrame()
    SendNUIMessage({ action = 'hideUI' })
    Wait(100)

    -- Use screenshot-basic export
    exports['screenshot-basic']:requestScreenshotUpload(
        Config.UploadURL,
        'file',
        {
            headers = {
                ['Authorization'] = Config.UploadToken,
                ['x-zipline-folder'] = Config.UploadFolder,
                ['x-zipline-format'] = 'uuid',
            },
            encoding = 'png',
        },
        function(data)
            -- Response from Zipline
            local resp = json.decode(data)
            if resp and resp.files and resp.files[1] then
                -- Replace internal URL with public URL
                local rawUrl = resp.files[1].url
                local filename = rawUrl:match('/u/(.+)$')
                local url = Config.PublicBaseURL .. '/u/' .. (filename or rawUrl)
                TriggerServerEvent('hk-imagecreator:server:screenshotDone', url, 'studio')
                SendNUIMessage({ action = 'showUI' })
                SendNUIMessage({ action = 'screenshotResult', url = url, success = true })
                lib.notify({ title = 'Image Creator', description = 'Captured! URL copied.', type = 'success' })
            else
                SendNUIMessage({ action = 'showUI' })
                SendNUIMessage({ action = 'screenshotResult', success = false, error = data })
                lib.notify({ title = 'Image Creator', description = 'Upload failed', type = 'error' })
            end
        end
    )
end
-- ============================================================
-- SPAWN ARBITRARY MODEL IN STUDIO (for items, props)
-- ============================================================
function SpawnStudioProp(model)
    if not isInStudio then return end

    -- Clear existing vehicle/prop
    if studioVehicle and DoesEntityExist(studioVehicle) then
        DeleteEntity(studioVehicle)
        studioVehicle = nil
    end

    local hash = type(model) == 'string' and joaat(model) or model
    lib.requestModel(hash)

    local coords = Config.Studio.coords
    studioVehicle = CreateObject(hash, coords.x, coords.y, coords.z - 0.5, false, false, false)
    FreezeEntityPosition(studioVehicle, true)
    SetModelAsNoLongerNeeded(hash)

    -- Reposition camera for prop (closer)
    local preset = Config.Studio.presets[currentPresetIndex]
    if preset then
        SetupStudioCam(currentPresetIndex)
    end
end

-- ============================================================
-- EXPORTS / EVENTS
-- ============================================================
exports('EnterStudio', EnterStudio)
exports('ExitStudio', ExitStudio)
exports('TakeStudioScreenshot', TakeStudioScreenshot)
exports('SpawnStudioProp', SpawnStudioProp)
