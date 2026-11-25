--[[
    hk-freecam  —  HOMEKONG Admin Cinematic Camera
    Based on randol_freecam by Randolio (private use, not redistributed)
]]

local Config = lib.load('config')
local FREE_CAM
local offsetRotX, offsetRotY, offsetRotZ = 0.0, 0.0, 0.0
local offsetCoords = {x = 0.0, y = 0.0, z = 0.0}
local precision = 1.0
local speed = 1.0
local currFilter = 1
local camActive = false
local dofOn = false
local dofStrength = 0.5
local dofFar = 150.0
local dofNear = 0.10
local barsOn = false

--- Helpers ---------------------------------------------------------------

local function toggleMap()
    local isRadarVisible = not IsRadarHidden()
    DisplayRadar(not isRadarVisible)
end

local function toggleBars()
    barsOn = not barsOn
    if barsOn then
        while barsOn do
            DrawRect(1.0, 1.0, 2.0, 0.23, 0, 0, 0, 255)
            DrawRect(1.0, 0.0, 2.0, 0.23, 0, 0, 0, 255)
            Wait(0)
        end
    end
end

local function resetEverything()
    ClearFocus()
    SetCamUseShallowDofMode(FREE_CAM, false)
    RenderScriptCams(false, false, 0, true, false)
    DestroyCam(FREE_CAM, false)
    offsetRotX = 0.0
    offsetRotY = 0.0
    offsetRotZ = 0.0
    speed = 1.0
    precision = 1.0
    currFilter = 1
    ClearTimecycleModifier()
    FREE_CAM = nil
    dofStrength = 0.5
    dofFar = 150.0
    dofNear = 0.10
    dofOn = false
    barsOn = false
end

local function setNewFov(delta)
    if DoesCamExist(FREE_CAM) then
        local currFov = GetCamFov(FREE_CAM)
        local newFov = currFov + delta
        if newFov >= Config.MinFov and newFov <= Config.MaxFov then
            SetCamFov(FREE_CAM, newFov)
        end
    end
end

local function toggleDof()
    dofOn = not dofOn
    if dofOn then
        if DoesCamExist(FREE_CAM) then
            SetCamUseShallowDofMode(FREE_CAM, true)
            SetCamNearDof(FREE_CAM, dofNear)
            SetCamFarDof(FREE_CAM, dofFar)
            SetCamDofStrength(FREE_CAM, dofStrength)
        end
    else
        dofStrength = 0.5
        dofFar = 150.0
        dofNear = 0.10
        SetCamNearDof(FREE_CAM, dofNear)
        SetCamFarDof(FREE_CAM, dofFar)
        SetCamDofStrength(FREE_CAM, dofStrength)
        SetCamUseShallowDofMode(FREE_CAM, false)
        ClearFocus()
    end
end

--- Movement --------------------------------------------------------------

local function processNewPos(x, y, z)
    local newPos = {x = x, y = y, z = z}
    local moveSpeed = 0.1 * speed

    local function updatePosition(multX, multY, multZ, direction)
        newPos.x = newPos.x + direction * moveSpeed * multX
        newPos.y = newPos.y - direction * moveSpeed * multY
    end

    -- WASD
    if IsDisabledControlPressed(1, 32) then
        updatePosition(Sin(offsetRotZ), Cos(offsetRotZ), Sin(offsetRotX), -1)
    elseif IsDisabledControlPressed(1, 33) then
        updatePosition(Sin(offsetRotZ), Cos(offsetRotZ), Sin(offsetRotX), 1)
    end
    if IsDisabledControlPressed(1, 34) then
        updatePosition(Sin(offsetRotZ + 90.0), Cos(offsetRotZ + 90.0), Sin(offsetRotY), -1)
    elseif IsDisabledControlPressed(1, 35) then
        updatePosition(Sin(offsetRotZ + 90.0), Cos(offsetRotZ + 90.0), Sin(offsetRotY), 1)
    end
    -- Space / Z  (up / down)
    if IsDisabledControlPressed(1, 22) then
        newPos.z += moveSpeed
    elseif IsDisabledControlPressed(1, 20) then
        newPos.z -= moveSpeed
    end

    -- Shift+scroll = speed,  scroll = zoom
    if IsDisabledControlPressed(1, 21) then
        if IsDisabledControlPressed(1, 15) then
            speed = math.min(speed + 0.1, Config.MaxSpeed)
        elseif IsDisabledControlPressed(1, 14) then
            speed = math.max(speed - 0.1, Config.MinSpeed)
        end
    else
        if IsDisabledControlPressed(1, 15) then
            setNewFov(-1.0)
        elseif IsDisabledControlPressed(1, 14) then
            setNewFov(1.0)
        end
    end

    -- Mouse look
    offsetRotX = offsetRotX - (GetDisabledControlNormal(1, 2) * precision * 8.0)
    offsetRotZ = offsetRotZ - (GetDisabledControlNormal(1, 1) * precision * 8.0)

    -- Q / E  (roll)
    if IsDisabledControlPressed(1, 44) then
        offsetRotY = offsetRotY - precision
    elseif IsDisabledControlPressed(1, 38) then
        offsetRotY = offsetRotY + precision
    end

    offsetRotX = math.clamp(offsetRotX, -90.0, 90.0)
    offsetRotY = math.clamp(offsetRotY, -90.0, 90.0)
    offsetRotZ = offsetRotZ % 360.0

    return newPos
end

--- Camera loop -----------------------------------------------------------

local function processCamControls()
    DisableFirstPersonCamThisFrame()

    local camCoords = GetCamCoord(FREE_CAM)
    local newPos = processNewPos(camCoords.x, camCoords.y, camCoords.z)
    SetFocusArea(newPos.x, newPos.y, newPos.z, 0.0, 0.0, 0.0)
    SetCamCoord(FREE_CAM, newPos.x, newPos.y, newPos.z)
    SetCamRot(FREE_CAM, offsetRotX, offsetRotY, offsetRotZ, 2)

    for _, ctrl in pairs(Config.DisabledControls) do
        DisableControlAction(0, ctrl, true)
    end

    local currentPos = GetEntityCoords(cache.ped)
    if #(currentPos - vec3(newPos.x, newPos.y, newPos.z)) > Config.MaxDistance then
        if not IsEntityDead(cache.ped) then
            lib.notify({ type = 'error', description = 'Camera range limit reached.' })
        end
        camActive = false
        lib.hideMenu()
    end

    if dofOn then SetUseHiDof() end
end
local function toggleCam()
    camActive = not camActive
    if camActive then
        ClearFocus()
        FREE_CAM = CreateCamWithParams('DEFAULT_SCRIPTED_CAMERA',
            GetEntityCoords(cache.ped), 0, 0, 0, GetGameplayCamFov() * 1.0)
        SetCamActive(FREE_CAM, true)
        RenderScriptCams(true, false, 0, true, false)
        SetCamAffectsAiming(FREE_CAM, false)

        CreateThread(function()
            while camActive do
                processCamControls()
                Wait(0)
            end
            resetEverything()
        end)
    end
end

--- Admin gate (server round-trip, same pattern as hk-scenario) -----------

local adminChecked = false
local isAdmin = false

RegisterNetEvent('hk-freecam:adminResult', function(allowed)
    isAdmin = allowed
    adminChecked = true
end)

-- Ask on spawn so the result is cached before they ever type /hkcam.
AddEventHandler('onClientResourceStart', function(res)
    if res ~= GetCurrentResourceName() then return end
    TriggerServerEvent('hk-freecam:checkAdmin')
end)

--- Command + Menu --------------------------------------------------------

RegisterCommand(Config.CommandName, function()
    if not adminChecked then
        -- First use before the server replied — ask again and wait briefly.
        TriggerServerEvent('hk-freecam:checkAdmin')
        local deadline = GetGameTimer() + 2000
        while not adminChecked and GetGameTimer() < deadline do Wait(50) end
    end
    if not isAdmin then
        lib.notify({ type = 'error', description = 'No permission.' })
        return
    end

    lib.registerMenu({
        id = 'hk_freecam_menu',
        title = 'HK Freecam',
        position = 'top-right',
        onSideScroll = function(selected, scrollIndex, args)
            if selected == 2 then
                SetTimecycleModifier(Config.Filters[scrollIndex])
                currFilter = scrollIndex
            elseif selected == 6 then
                dofNear = tonumber(Config.NearDof[scrollIndex])
                SetCamNearDof(FREE_CAM, dofNear)
            elseif selected == 7 then
                dofFar = tonumber(Config.FarDof[scrollIndex])
                SetCamFarDof(FREE_CAM, dofFar)
            elseif selected == 8 then
                dofStrength = tonumber(Config.StrengthDof[scrollIndex])
                SetCamDofStrength(FREE_CAM, dofStrength)
            end
        end,
        onCheck = function(selected, checked, args)
            if selected == 1 then
                toggleCam()
            elseif selected == 3 then
                toggleDof()
            elseif selected == 4 then
                toggleBars()
            elseif selected == 5 then
                toggleMap()
            end
        end,
        options = {
            {label = 'Toggle Camera',           checked = camActive,            icon = 'camera'},
            {label = 'Camera Filters',          values = Config.Filters,        icon = 'camera',     defaultIndex = currFilter, description = 'Arrow keys to browse. Enter to reset.'},
            {label = 'Toggle Depth of Field',   checked = dofOn,                icon = 'eye',        description = 'Shallow depth-of-field effect.'},
            {label = 'Toggle Black Bars',       checked = barsOn,               icon = 'film',       description = 'Cinematic letterbox bars.'},
            {label = 'Toggle Minimap',          checked = not IsRadarHidden(),  icon = 'map',        description = 'Show / hide the minimap.'},
            {label = 'DoF Near',                values = Config.NearDof,        icon = 'left-right', description = 'Near focus distance.'},
            {label = 'DoF Far',                 values = Config.FarDof,         icon = 'left-right', description = 'Far focus distance.'},
            {label = 'DoF Strength',            values = Config.StrengthDof,    icon = 'left-right', description = 'Blur intensity.'},
        }
    }, function(selected, scrollIndex, args)
        if selected == 2 then
            ClearTimecycleModifier()
            currFilter = 1
        end
    end)
    lib.showMenu('hk_freecam_menu')
end)

--- Auto-kill on death ----------------------------------------------------

AddEventHandler('gameEventTriggered', function(event, data)
    if event ~= 'CEventNetworkEntityDamage' then return end
    local victim, victimDied = data[1], data[4]
    if not IsPedAPlayer(victim) then return end
    if victimDied
        and NetworkGetPlayerIndexFromPed(victim) == cache.playerId
        and (IsPedDeadOrDying(victim, true) or IsPedFatallyInjured(victim))
    then
        if DoesCamExist(FREE_CAM) then
            resetEverything()
        end
    end
end)

