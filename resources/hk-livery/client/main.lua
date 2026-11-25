-- ─────────────────────────────────────────────
--  hk-livery · Client
--  3D direct painting: raycast → UV → canvas
-- ─────────────────────────────────────────────

local QBCore = exports['qb-core']:GetCoreObject()

-- ── State ──
local isOpen    = false
local editVeh   = nil
local editPlate = nil
local editModel = nil
local camHandle = nil

-- Camera orbit state
local camAngle  = 220.0   -- horizontal angle (degrees)
local camPitch  = 5.0     -- vertical angle (degrees)
local camDist   = 6.0     -- distance from vehicle center
local camTarget = nil     -- vec3 orbit center

-- Vehicle bounding box (cached on open)
local vehMin, vehMax = nil, nil
local vehLength, vehWidth, vehHeight = 0, 0, 0

-- DUI pool: plate → { dui, handle, txd, model }
local duiPool = {}

-- ─────────────────────────────
--  Utility
-- ─────────────────────────────

local function getPlate(vehicle)
    return string.gsub(GetVehicleNumberPlateText(vehicle), '%s+', '')
end

local function getModelName(vehicle)
    return string.lower(GetDisplayNameFromVehicleModel(GetEntityModel(vehicle)))
end

local function notify(msg, type)
    QBCore.Functions.Notify(msg, type or 'primary', 3000)
end

local rad = math.rad
local sin = math.sin
local cos = math.cos
local atan2 = math.atan
local abs = math.abs
local sqrt = math.sqrt
local clamp = function(v, lo, hi) return v < lo and lo or (v > hi and hi or v) end

-- ─────────────────────────────
--  Camera System
-- ─────────────────────────────

local function updateCam()
    if not camHandle or not camTarget then return end

    local h = rad(camAngle)
    local p = rad(camPitch)
    local d = camDist

    local camPos = vector3(
        camTarget.x + d * cos(p) * cos(h),
        camTarget.y + d * cos(p) * sin(h),
        camTarget.z + d * sin(p)
    )

    SetCamCoord(camHandle, camPos.x, camPos.y, camPos.z)
    PointCamAtCoord(camHandle, camTarget.x, camTarget.y, camTarget.z)
end

local function createCam()
    local pos = GetEntityCoords(editVeh)
    camTarget = pos + vector3(0, 0, 0.5) -- slightly above center

    camHandle = CreateCam('DEFAULT_SCRIPTED_CAMERA', true)
    SetCamFov(camHandle, Config.Camera.fov)
    updateCam()
    SetCamActive(camHandle, true)
    RenderScriptCams(true, true, 600, true, false)
end

local function destroyCam()
    if camHandle then
        RenderScriptCams(false, true, 600, true, false)
        DestroyCam(camHandle, false)
        camHandle = nil
    end
end

-- ─────────────────────────────
--  Screen → World Raycast
-- ─────────────────────────────

--- Cast a ray from camera through screen pixel, return hit info
---@param screenX number  pixel X
---@param screenY number  pixel Y
---@return boolean hit
---@return vector3 coords
---@return vector3 normal
local function screenRaycast(screenX, screenY)
    if not camHandle then return false, vector3(0,0,0), vector3(0,0,0) end

    local w, h = GetActiveScreenResolution()
    local scrX = screenX / w  -- normalize 0-1
    local scrY = screenY / h

    local camPos = GetCamCoord(camHandle)
    local camRot = GetCamRot(camHandle, 2)
    local fov    = GetCamFov(camHandle)
    local aspect = GetAspectRatio(false)

    -- Build camera basis vectors from rotation
    local rp = rad(camRot.x)  -- pitch
    local ry = rad(camRot.z)  -- yaw

    local forward = vector3(
        -sin(ry) * abs(cos(rp)),
         cos(ry) * abs(cos(rp)),
         sin(rp)
    )

    -- Right vector (perpendicular in XY plane)
    local right = vector3(cos(ry), sin(ry), 0.0)

    -- Up vector (cross of right and forward, simplified)
    local up = vector3(
        -sin(ry) * (-sin(rp)),
         cos(ry) * (-sin(rp)),
         cos(rp)
    )

    -- Screen offset scaled by FOV
    local halfFov = math.tan(rad(fov * 0.5))
    local offX = (scrX - 0.5) * 2.0 * halfFov * aspect
    local offY = (0.5 - scrY) * 2.0 * halfFov

    -- Ray direction
    local dir = forward + right * offX + up * offY
    local len = #dir
    dir = dir / len

    -- Cast ray (20m is plenty for a parked car)
    local endPos = camPos + dir * 20.0
    local handle = StartShapeTestLosProbe(
        camPos.x, camPos.y, camPos.z,
        endPos.x, endPos.y, endPos.z,
        2,                -- flags: vehicles only
        PlayerPedId(), 0  -- ignore player ped
    )

    local _, hit, hitCoord, surfNormal, entityHit = GetShapeTestResult(handle)

    -- Only accept hits on our edit vehicle
    if hit == 1 and entityHit == editVeh then
        return true, hitCoord, surfNormal
    end

    return false, vector3(0,0,0), vector3(0,0,0)
end

-- ─────────────────────────────
--  World Hit → UV Projection
-- ─────────────────────────────

--- Convert a world hit position + surface normal to UV texture coordinates.
--- Uses box projection: determines which face of the vehicle bounding box
--- the hit belongs to (based on surface normal), then does planar projection.
---
--- Texture layout (1024×1024):
---   Top half  (y 0-511):  LEFT side (u 0-0.5) | RIGHT side (u 0.5-1.0)
---   Bot half  (y 512-1023): divided into FRONT | TOP-DOWN | REAR
---
---@param hitWorld vector3  world-space hit position
---@param normal vector3    surface normal at hit
---@return number u  0-1
---@return number v  0-1
local function worldToUV(hitWorld, normal)
    -- Convert hit to vehicle-local space
    local vehPos = GetEntityCoords(editVeh)
    local heading = rad(GetEntityHeading(editVeh))

    local off = hitWorld - vehPos
    -- Rotate into vehicle local (undo heading around Z)
    local ch, sh = cos(-heading), sin(-heading)
    local localX = off.x * ch - off.y * sh    -- left(-) to right(+)
    local localY = off.x * sh + off.y * ch    -- rear(-) to front(+)
    local localZ = off.z

    -- Rotate normal into local space too
    local nX = normal.x * ch - normal.y * sh
    local nY = normal.x * sh + normal.y * ch
    local nZ = normal.z

    -- Normalize within vehicle bounds (0-1)
    local nx = clamp((localX - vehMin.x) / vehWidth,  0, 1)
    local ny = clamp((localY - vehMin.y) / vehLength, 0, 1)
    local nz = clamp((localZ - vehMin.z) / vehHeight, 0, 1)

    local u, v
    local absNX, absNY, absNZ = abs(nX), abs(nY), abs(nZ)

    if absNZ > absNX and absNZ > absNY then
        -- TOP / BOTTOM face → top-down planar projection
        -- Maps to bottom-center of texture (u 0.33-0.66, v 0.5-1.0)
        u = 0.333 + nx * 0.334
        v = 0.5 + (1.0 - ny) * 0.5
    elseif absNX > absNY then
        -- LEFT or RIGHT side
        if nX < 0 then
            -- LEFT side → top-left quadrant (u 0-0.5, v 0-0.5)
            u = ny * 0.5                  -- front→back maps to u
            v = (1.0 - nz) * 0.5         -- top→bottom maps to v
        else
            -- RIGHT side → top-right quadrant (u 0.5-1.0, v 0-0.5)
            u = 0.5 + (1.0 - ny) * 0.5   -- mirrored front→back
            v = (1.0 - nz) * 0.5
        end
    else
        -- FRONT or REAR face
        if nY > 0 then
            -- FRONT → bottom-left (u 0-0.33, v 0.5-1.0)
            u = nx * 0.333
            v = 0.5 + (1.0 - nz) * 0.5
        else
            -- REAR → bottom-right (u 0.66-1.0, v 0.5-1.0)
            u = 0.666 + nx * 0.334
            v = 0.5 + (1.0 - nz) * 0.5
        end
    end

    return clamp(u, 0, 1), clamp(v, 0, 1)
end

-- ─────────────────────────────
--  DUI Texture Engine
-- ─────────────────────────────

function removeDuiTexture(plate)
    local entry = duiPool[plate]
    if not entry then return end
    RemoveReplaceTexture(entry.model, entry.model .. '_sign_1')
    DestroyDui(entry.dui)
    duiPool[plate] = nil
end

local function applyDuiTexture(plate, model, pngDataUrl, vehicle)
    removeDuiTexture(plate)

    local txdName = 'hkl_' .. plate
    local txd     = CreateRuntimeTxd(txdName)
    local dui     = CreateDui(pngDataUrl, Config.CanvasSize, Config.CanvasSize)

    local timeout = 50
    while not IsDuiAvailable(dui) and timeout > 0 do
        Wait(100)
        timeout = timeout - 1
    end

    if timeout <= 0 then
        DestroyDui(dui)
        return nil
    end

    local handle = GetDuiHandle(dui)
    CreateRuntimeTextureFromDuiHandle(txd, 'livery', handle)
    AddReplaceTexture(model, model .. '_sign_1', txdName, 'livery')

    if vehicle and DoesEntityExist(vehicle) then
        SetVehicleLivery(vehicle, 0)
    end

    local entry = { dui = dui, handle = handle, txd = txdName, model = model, plate = plate }
    duiPool[plate] = entry
    return entry
end

local function evictDuiPool()
    local count = 0
    for _ in pairs(duiPool) do count = count + 1 end
    if count <= Config.MaxDuiPool then return end
    for plate in pairs(duiPool) do
        if plate ~= editPlate then
            removeDuiTexture(plate)
            count = count - 1
            if count <= Config.MaxDuiPool then break end
        end
    end
end

-- ─────────────────────────────
--  Editor Open / Close
-- ─────────────────────────────

local function openEditor()
    local ped = PlayerPedId()
    local vehicle = nil

    if IsPedInAnyVehicle(ped, false) then
        vehicle = GetVehiclePedIsIn(ped, false)
    else
        vehicle = QBCore.Functions.GetClosestVehicle()
        if vehicle and #(GetEntityCoords(ped) - GetEntityCoords(vehicle)) > Config.TargetDistance then
            vehicle = nil
        end
    end

    if not vehicle or not DoesEntityExist(vehicle) then
        return notify('No vehicle nearby', 'error')
    end

    editVeh   = vehicle
    editPlate = getPlate(vehicle)
    editModel = getModelName(vehicle)
    isOpen    = true

    -- Cache bounding box
    local model = GetEntityModel(vehicle)
    vehMin, vehMax = GetModelDimensions(model)
    vehLength = vehMax.y - vehMin.y
    vehWidth  = vehMax.x - vehMin.x
    vehHeight = vehMax.z - vehMin.z

    -- Exit vehicle if needed
    if IsPedInAnyVehicle(ped, false) then
        TaskLeaveVehicle(ped, vehicle, 0)
        Wait(1500)
    end

    -- Freeze
    FreezeEntityPosition(vehicle, true)
    FreezeEntityPosition(ped, true)
    SetEntityVisible(ped, false, false)

    -- Camera
    camAngle = GetEntityHeading(vehicle) + 220.0
    camPitch = 8.0
    camDist  = math.max(vehLength * 1.5, 5.0)
    createCam()

    -- Load existing livery
    QBCore.Functions.TriggerCallback('hk-livery:server:getLivery', function(data)
        local png = data and data.png_data or nil
        SendNUIMessage({ action = 'open', png = png })
        SetNuiFocus(true, true)
    end, editPlate)
end

local function closeEditor()
    if not isOpen then return end
    isOpen = false

    SetNuiFocus(false, false)
    SendNUIMessage({ action = 'close' })

    local ped = PlayerPedId()
    if editVeh and DoesEntityExist(editVeh) then
        FreezeEntityPosition(editVeh, false)
    end
    FreezeEntityPosition(ped, false)
    SetEntityVisible(ped, true, false)

    destroyCam()
    editVeh = nil
    editPlate = nil
    editModel = nil
end

-- ─────────────────────────────
--  NUI Callbacks
-- ─────────────────────────────

-- Paint: NUI sends screen coords → we raycast → return UV
RegisterNUICallback('paint', function(data, cb)
    if not isOpen or not editVeh then return cb('ok') end

    local hit, coord, normal = screenRaycast(data.sx, data.sy)
    if hit then
        local u, v = worldToUV(coord, normal)
        SendNUIMessage({ action = 'paintUV', u = u, v = v })
    else
        SendNUIMessage({ action = 'paintMiss' })
    end
    cb('ok')
end)

-- Camera orbit
RegisterNUICallback('orbit', function(data, cb)
    if not isOpen then return cb('ok') end
    camAngle = camAngle - data.dx * 0.3
    camPitch = clamp(camPitch + data.dy * 0.2, -20, 60)
    updateCam()
    cb('ok')
end)

-- Camera zoom
RegisterNUICallback('zoom', function(data, cb)
    if not isOpen then return cb('ok') end
    camDist = clamp(camDist + data.delta * 0.5, 2.5, 15.0)
    updateCam()
    cb('ok')
end)

-- Texture update from NUI canvas export
RegisterNUICallback('updateTexture', function(data, cb)
    if editVeh and data.png then
        applyDuiTexture(editPlate, editModel, data.png, editVeh)
    end
    cb('ok')
end)

-- Save
RegisterNUICallback('save', function(data, cb)
    if editVeh and data.png then
        applyDuiTexture(editPlate, editModel, data.png, editVeh)
        TriggerServerEvent('hk-livery:server:saveLivery', {
            plate    = editPlate,
            model    = editModel,
            png_data = data.png,
        })
        notify('Livery saved', 'success')
    end
    cb('ok')
end)

-- Close
RegisterNUICallback('close', function(_, cb)
    closeEditor()
    cb('ok')
end)

-- ─────────────────────────────
--  Command + Target
-- ─────────────────────────────

RegisterCommand(Config.Command, function()
    if isOpen then closeEditor() else openEditor() end
end, false)

if Config.UseTarget then
    exports['qb-target']:AddGlobalVehicle({
        options = {
            {
                icon  = 'fas fa-paint-roller',
                label = 'Custom Livery',
                action = function(entity)
                    editVeh   = entity
                    editPlate = getPlate(entity)
                    editModel = getModelName(entity)
                    openEditor()
                end,
            },
        },
        distance = Config.TargetDistance,
    })
end

-- ─────────────────────────────
--  Multiplayer Livery Sync
-- ─────────────────────────────

RegisterNetEvent('hk-livery:client:applyLivery', function(plate, model, pngDataUrl)
    local vehicle = findVehicleByPlate(plate)
    if not vehicle then return end
    evictDuiPool()
    applyDuiTexture(plate, model, pngDataUrl, vehicle)
end)

RegisterNetEvent('hk-livery:client:removeLivery', function(plate)
    removeDuiTexture(plate)
end)

function findVehicleByPlate(plate)
    local vehicles = GetGamePool('CVehicle')
    for _, veh in ipairs(vehicles) do
        if getPlate(veh) == plate then return veh end
    end
    return nil
end

-- ─────────────────────────────
--  Auto-load own vehicle livery
-- ─────────────────────────────

CreateThread(function()
    while true do
        Wait(1000)
        local ped = PlayerPedId()
        if IsPedInAnyVehicle(ped, false) and not isOpen then
            local veh   = GetVehiclePedIsIn(ped, false)
            local plate = getPlate(veh)
            if not duiPool[plate] then
                local model = getModelName(veh)
                QBCore.Functions.TriggerCallback('hk-livery:server:getLivery', function(data)
                    if data and data.png_data then
                        applyDuiTexture(plate, model, data.png_data, veh)
                    end
                end, plate)
            end
            Wait(5000)
        end
    end
end)

-- ─────────────────────────────
--  Cleanup
-- ─────────────────────────────

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    if isOpen then closeEditor() end
    for plate in pairs(duiPool) do
        removeDuiTexture(plate)
    end
end)
