-- ============================================================
-- NUI CALLBACKS
-- ============================================================

RegisterNUICallback('close', function(_, cb)
    if isInStudio then
        ExitStudio()
    elseif isInPhotoMode then
        ExitPhotoMode()
    end
    cb('ok')
end)

RegisterNUICallback('takeScreenshot', function(_, cb)
    if isInStudio then
        TakeStudioScreenshot()
    elseif isInPhotoMode then
        TakePhotoScreenshot()
    end
    cb('ok')
end)

RegisterNUICallback('changePreset', function(data, cb)
    if isInStudio then
        SetupStudioCam(data.index)
    end
    cb('ok')
end)

RegisterNUICallback('changeFov', function(data, cb)
    if photoCam then
        SetCamFov(photoCam, data.fov + 0.0)
    end
    cb('ok')
end)

RegisterNUICallback('rotateCam', function(data, cb)
    if isInStudio and studioCam then
        -- Adjust current preset angle
        local preset = Config.Studio.presets[currentPresetIndex]
        if preset then
            preset.angle = preset.angle + (data.deltaX or 0.0)
            preset.pitch = math.max(-89.0, math.min(89.0, preset.pitch + (data.deltaY or 0.0)))
            SetupStudioCam(currentPresetIndex)
        end
    end
    cb('ok')
end)

RegisterNUICallback('zoomCam', function(data, cb)
    if isInStudio then
        local preset = Config.Studio.presets[currentPresetIndex]
        if preset then
            preset.distance = math.max(2.0, math.min(20.0, preset.distance + (data.delta or 0.0)))
            SetupStudioCam(currentPresetIndex)
        end
    end
    cb('ok')
end)

RegisterNUICallback('spawnModel', function(data, cb)
    if isInStudio and data.model then
        SpawnStudioProp(data.model)
    end
    cb('ok')
end)

RegisterNUICallback('copyUrl', function(data, cb)
    -- Server handles clipboard notification
    if data.url then
        TriggerServerEvent('hk-imagecreator:server:logUrl', data.url)
    end
    cb('ok')
end)
