-- hk-crafting :: client/place.lua
-- Ghost-placement: raycast a translucent prop from the camera, scroll to rotate,
-- E to confirm, X to cancel. On confirm, asks the server to register the table.

local PLACING = false
local GhostObj = nil   -- module-level so onResourceStop can clean it up

local function outlineGhost(obj)
    local oc = Config.Placement.OutlineColor
    SetEntityAlpha(obj, Config.Placement.GhostAlpha, false)
    DisableCamCollisionForEntity(obj)
    SetEntityCollision(obj, false, false)
    SetEntityDrawOutlineColor(oc.r, oc.g, oc.b, 220)
    SetEntityDrawOutlineShader(0)
    SetEntityDrawOutline(obj, true)
end

local function placeLoop(tabletype)
    local cfg = Config.CraftingTables[tabletype]
    if not cfg then return end

    lib.requestModel(cfg.model)
    local _, _, endCoords = lib.raycast.cam(511, 4)
    if not endCoords then endCoords = GetEntityCoords(cache.ped) end

    local obj = CreateObject(cfg.model, endCoords.x, endCoords.y, endCoords.z, false, false, false)
    GhostObj = obj
    outlineGhost(obj)

    PLACING = true
    lib.showTextUI(L('place_instructions'))

    local heading = GetEntityHeading(cache.ped)
    local confirmed, cancelled = false, false

    while PLACING do
        local ped = cache.ped
        local pedCoords = GetEntityCoords(ped)
        local _, _, hit = lib.raycast.cam(511, 4)
        if hit then
            -- clamp distance so it can't be flung across the map
            if #(hit - pedCoords) > Config.Placement.MaxDistance then
                local dir = (hit - pedCoords)
                dir = dir / #dir
                hit = pedCoords + dir * Config.Placement.MaxDistance
            end
            SetEntityCoords(obj, hit.x, hit.y, hit.z, false, false, false, false)
        end

        -- scroll up / down to rotate
        if IsControlJustReleased(0, 241) then          -- scroll up
            heading = heading + Config.Placement.RotateStep
        elseif IsControlJustReleased(0, 242) then      -- scroll down
            heading = heading - Config.Placement.RotateStep
        end
        SetEntityHeading(obj, heading % 360.0)

        if IsControlJustPressed(0, 38) then            -- E confirm
            confirmed = true
            break
        elseif IsControlJustPressed(0, 73) then        -- X cancel
            cancelled = true
            break
        end

        Wait(0)
    end

    PLACING = false
    lib.hideTextUI()
    PlaceObjectOnGroundProperly(obj)
    local finalCoords = GetEntityCoords(obj)
    local finalHeading = GetEntityHeading(obj)
    DeleteEntity(obj)
    GhostObj = nil
    SetModelAsNoLongerNeeded(cfg.model)

    if cancelled or not confirmed then
        Notify(L('cancelled_placing'), 'inform')
        return
    end

    local ok = lib.progressBar({
        duration     = Config.Placement.PlaceDuration,
        label        = L('placing_table'),
        useWhileDead = false,
        canCancel    = false,
        disable      = { car = true, move = true, combat = true },
        anim         = { dict = 'pickup_object', clip = 'pickup_low' },
        prop         = {
            model = `prop_box_guncase_01a`,
            pos   = vec3(0.12, 0.0, 0.0),
            rot   = vec3(0.0, 0.0, 0.0),
            bone  = 57005,
        },
    })
    if not ok then return end

    local result = lib.callback.await('hk-crafting:placeTable', false, tabletype, finalCoords, finalHeading)
    if result then
        Notify(L('placed_table'), 'success')
    else
        Notify(L('pickup_failed'), 'error')  -- generic failure (no item / server refused)
    end
end

RegisterNetEvent('hk-crafting:startPlacing', function(tabletype)
    if PLACING then
        Notify(L('already_placing'), 'error')
        return
    end
    if IsPedInAnyVehicle(cache.ped, false) then
        Notify(L('no_place_in_vehicle'), 'error')
        return
    end
    placeLoop(tabletype)
end)

-- Clean up if the resource stops mid-placement: the ghost prop would linger and
-- the ox_lib TextUI (owned by a different resource) would stay stuck on screen.
AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    PLACING = false
    lib.hideTextUI()
    if GhostObj and DoesEntityExist(GhostObj) then DeleteEntity(GhostObj) end
    GhostObj = nil
end)
