-- hk-race :: client/util.lua
-- Shared client helpers: notifications, blips, noclip camera, job lookup.

RaceUtil = {}

local QBCore = exports['qb-core']:GetCoreObject()

function RaceUtil.notify(msg, kind)
    -- Prefer ox_lib notify (server uses QBCore:Notify too; both are fine).
    lib.notify({ description = msg, type = kind or 'inform', position = 'top' })
end

-- ── Player job type (for reference; announcement visibility is server/dispatch side) ──
function RaceUtil.getJobType()
    local data = QBCore.Functions.GetPlayerData()
    if data and data.job then return data.job.type, data.job.name end
    return nil, nil
end

-- ── Start-zone blip + radius. `legal` true = BLUE circle (sanctioned), else RED.
function RaceUtil.createStartBlip(start, legal)
    local blip = AddBlipForCoord(start.x, start.y, start.z)
    SetBlipSprite(blip, RaceConfig.Race.startBlip.sprite)
    SetBlipColour(blip, RaceConfig.Race.startBlip.color)
    SetBlipScale(blip, RaceConfig.Race.startBlip.scale)
    SetBlipAsShortRange(blip, false)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName(legal and 'Race Start (Legal)' or 'Race Start')
    EndTextCommandSetBlipName(blip)

    -- Radius fill: blue (38) for legal/sanctioned, red (1) for illegal.
    local radiusBlip = AddBlipForRadius(start.x, start.y, start.z, start.radius + 0.0)
    SetBlipColour(radiusBlip, legal and 38 or 1)
    SetBlipAlpha(radiusBlip, RaceConfig.Race.startBlip.radiusAlpha)
    SetBlipHiddenOnLegend(radiusBlip, true)

    return { point = blip, radius = radiusBlip }
end

function RaceUtil.removeBlips(blips)
    if not blips then return end
    if blips.point and DoesBlipExist(blips.point) then RemoveBlip(blips.point) end
    if blips.radius and DoesBlipExist(blips.radius) then RemoveBlip(blips.radius) end
end

-- ── Noclip (editor free-cam through the world) ────────────────────────────
local noclipActive = false
local noclipEntity = nil

function RaceUtil.isNoclip() return noclipActive end

function RaceUtil.setNoclip(state)
    local ped = PlayerPedId()
    noclipEntity = (IsPedInAnyVehicle(ped, false) and GetVehiclePedIsIn(ped, false)) or ped
    noclipActive = state

    if state then
        SetEntityInvincible(noclipEntity, true)
        FreezeEntityPosition(noclipEntity, true)
        SetEntityCollision(noclipEntity, false, false)
        SetEntityVisible(noclipEntity, noclipEntity ~= ped, false) -- keep vehicle visible, hide ped? keep both visible
        SetEntityVisible(noclipEntity, true, false)
        CreateThread(function()
            local speedBase = RaceConfig.Editor.noclipSpeed
            while noclipActive do
                Wait(0)
                local ent = noclipEntity
                if not ent or not DoesEntityExist(ent) then break end

                local mult = speedBase
                if IsControlPressed(0, 21) then mult = mult * RaceConfig.Editor.noclipFastMultiplier end -- LSHIFT
                if IsControlPressed(0, 19) then mult = mult * RaceConfig.Editor.noclipSlowMultiplier end -- LALT

                local dx, dy, dz = 0.0, 0.0, 0.0
                if IsControlPressed(0, 32) then dy = dy + 1.0 end  -- W
                if IsControlPressed(0, 33) then dy = dy - 1.0 end  -- S
                if IsControlPressed(0, 34) then dx = dx - 1.0 end  -- A
                if IsControlPressed(0, 35) then dx = dx + 1.0 end  -- D
                if IsControlPressed(0, 22) then dz = dz + 1.0 end  -- SPACE up
                if IsControlPressed(0, 36) then dz = dz - 1.0 end  -- LCTRL down

                -- Rotate movement by camera heading.
                local rot = GetGameplayCamRot(2)
                local heading = math.rad(rot.z)
                local pitch = math.rad(rot.x)
                local fwd = vector3(-math.sin(heading) * math.cos(pitch),
                                     math.cos(heading) * math.cos(pitch),
                                     math.sin(pitch))
                local right = vector3(math.cos(heading), math.sin(heading), 0.0)

                local pos = GetEntityCoords(ent)
                local move = (fwd * dy + right * dx) * (mult * 1.5)
                local newPos = vector3(pos.x + move.x, pos.y + move.y, pos.z + move.z + dz * mult)

                SetEntityCoordsNoOffset(ent, newPos.x, newPos.y, newPos.z, false, false, false)
                SetEntityHeading(ent, math.deg(-heading) % 360.0)
                SetEntityRotation(ent, 0.0, 0.0, math.deg(-heading) % 360.0, 2, true)
            end
        end)
    else
        if noclipEntity and DoesEntityExist(noclipEntity) then
            FreezeEntityPosition(noclipEntity, false)
            SetEntityCollision(noclipEntity, true, true)
            SetEntityInvincible(noclipEntity, false)
            SetEntityVisible(noclipEntity, true, false)
            local pos = GetEntityCoords(noclipEntity)
            local groundOk, groundZ = GetGroundZFor_3dCoord(pos.x, pos.y, pos.z, false)
            if groundOk then
                SetEntityCoordsNoOffset(noclipEntity, pos.x, pos.y, groundZ, false, false, false)
            end
        end
        noclipEntity = nil
    end
end
