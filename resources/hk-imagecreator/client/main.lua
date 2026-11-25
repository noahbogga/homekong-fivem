local QBCore = exports['qb-core']:GetCoreObject()
local isInPhotoMode = false
local photoCam = nil
local photoFov = 50.0
local photoCoords = nil
local photoRot = nil

-- ============================================================
-- COMMANDS
-- ============================================================
RegisterCommand('imagecreator', function()
    OpenMainMenu()
end, false)

RegisterCommand('studio', function()
    EnterStudio('vehicle')
end, false)

RegisterCommand('photomode', function()
    EnterPhotoMode()
end, false)

-- ============================================================
-- MAIN MENU (ox_lib context menu)
-- ============================================================
function OpenMainMenu()
    local options = {
        {
            title = 'Studio Mode (Vehicle)',
            description = 'TP to sky void, capture current vehicle with green screen',
            icon = 'car',
            onSelect = function() EnterStudio('vehicle') end,
        },
        {
            title = 'Studio Mode (Prop/Item)',
            description = 'TP to sky void, spawn a model for capture',
            icon = 'cube',
            onSelect = function() OpenPropInput() end,
        },
        {
            title = 'Photo Mode',
            description = 'Take a photo of your current surroundings',
            icon = 'camera',
            onSelect = function() EnterPhotoMode() end,
        },
    }

    lib.registerContext({
        id = 'hk_imagecreator_menu',
        title = 'HOMEKONG Image Creator',
        options = options,
    })
    lib.showContext('hk_imagecreator_menu')
end

function OpenPropInput()
    local input = lib.inputDialog('Spawn Model', {
        { type = 'input', label = 'Model Name / Hash', placeholder = 'e.g. prop_weed_01' },
    })
    if input and input[1] then
        EnterStudio('prop')
        Wait(1000)
        SpawnStudioProp(input[1])
    end
end

-- ============================================================
-- PHOTO MODE - Free cam at current location
-- ============================================================
function EnterPhotoMode()
    if isInPhotoMode or isInStudio then return end
    isInPhotoMode = true

    local ped = PlayerPedId()
    photoCoords = GetEntityCoords(ped)
    photoRot = GetEntityHeading(ped)
    photoFov = Config.Photo.presets[1].fov

    -- Create free cam at player pos
    photoCam = CreateCam('DEFAULT_SCRIPTED_CAMERA', true)
    local fwd = GetEntityForwardVector(ped)
    SetCamCoord(photoCam, photoCoords.x + fwd.x * 2.0, photoCoords.y + fwd.y * 2.0, photoCoords.z + 0.5)
    PointCamAtCoord(photoCam, photoCoords.x + fwd.x * 10.0, photoCoords.y + fwd.y * 10.0, photoCoords.z + 0.5)
    SetCamFov(photoCam, photoFov)
    SetCamActive(photoCam, true)
    RenderScriptCams(true, true, 500, true, false)

    FreezeEntityPosition(ped, true)

    -- Show NUI controls
    SendNUIMessage({ action = 'openPhoto', presets = Config.Photo.presets })
    SetNuiFocus(true, true)

    lib.notify({ title = 'Photo Mode', description = 'Use mouse to look, scroll to zoom', type = 'info' })
end

function ExitPhotoMode()
    if not isInPhotoMode then return end

    SendNUIMessage({ action = 'close' })
    SetNuiFocus(false, false)

    if photoCam then
        RenderScriptCams(false, true, 500, true, false)
        DestroyCam(photoCam, false)
        photoCam = nil
    end

    local ped = PlayerPedId()
    FreezeEntityPosition(ped, false)

    isInPhotoMode = false
    lib.notify({ title = 'Photo Mode', description = 'Closed', type = 'info' })
end

function TakePhotoScreenshot()
    HideHudAndRadarThisFrame()
    SendNUIMessage({ action = 'hideUI' })
    Wait(100)

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
            local resp = json.decode(data)
            if resp and resp.files and resp.files[1] then
                local rawUrl = resp.files[1].url
                local filename = rawUrl:match('/u/(.+)$')
                local url = Config.PublicBaseURL .. '/u/' .. (filename or rawUrl)
                TriggerServerEvent('hk-imagecreator:server:screenshotDone', url, 'photo')
                SendNUIMessage({ action = 'showUI' })
                SendNUIMessage({ action = 'screenshotResult', url = url, success = true })
                lib.notify({ title = 'Photo Mode', description = 'Photo uploaded!', type = 'success' })
            else
                SendNUIMessage({ action = 'showUI' })
                SendNUIMessage({ action = 'screenshotResult', success = false })
                lib.notify({ title = 'Photo Mode', description = 'Upload failed', type = 'error' })
            end
        end
    )
end

-- ============================================================
-- KEYBINDS
-- ============================================================
CreateThread(function()
    while true do
        Wait(0)
        if isInStudio or isInPhotoMode then
            HideHudAndRadarThisFrame()
            DisableAllControlActions(0)
            -- Allow mouse
            EnableControlAction(0, 1, true) -- LookLR
            EnableControlAction(0, 2, true) -- LookUD
            EnableControlAction(0, 245, true) -- Chat
        end
    end
end)
