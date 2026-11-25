-- ═══════════════════════════════════════════════════════════ --
--          HK-PARKING — HOMEKONG (based on mh-parking by MaDHouSe79, MIT)           --
-- ═══════════════════════════════════════════════════════════ --

local Target = {}

if GetResourceState("ox_target") == "started" then
    Target.name = "ox_target"
    Target.addGlobalVehicle = function(options) exports.ox_target:addGlobalVehicle(options) end
elseif GetResourceState("qb-target") == "started" or GetResourceState("qtarget") == "started" then
    Target.name = GetResourceState("qb-target") == "started" and "qb-target" or "qtarget"
    local exportName = GetResourceState("qb-target") == "started" and "qb-target" or "qtarget"
    Target.addGlobalVehicle = function(options) exports[exportName]:AddGlobalVehicle({options = options, distance = 4.0}) end
end

local function getEntity(data)
    if type(data) == 'table' then return data.entity else return data end
end

local function createParkingOptions()
    return {
        {
            num         = 1,
            name        = "parking_info",
            icon        = "fas fa-circle-info",
            label       = "Vehicle Info",
            event       = "hk-parking:infomenu",
            type        = "client",
            distance    = 3.0,
            action = function(data)
                TriggerEvent("hk-parking:infomenu")
            end,
            canInteract = function(data)
                local entity = getEntity(data)
                return DoesEntityExist(entity) and IsEntityAVehicle(entity)
            end,
        },
        {
            num      = 2,
            name     = "clamp_wheel",
            icon     = "fas fa-lock",
            label    = "Add Wheelclamp (police)",
            event    = "hk-parking:clampWheel",
            type     = "client",
            job      = { ["police"] = 0 },
            distance = 3.0,
            action = function(data)
                local entity = getEntity(data)
                local vehicle = entity
                TriggerServerEvent("hk-parking:server:toggleClamp", SafeNetId(vehicle), true)
            end,
            canInteract = function(data)
                local entity = getEntity(data)
                local plate = GetPlate(entity)
                local state = Entity(entity).state
                return state and not state.isClamped and DoesEntityExist(entity)
            end,
        },
        {
            num      = 3,
            name     = "unclamp_wheel",
            icon     = "fas fa-lock-open",
            label    = "Remove Wheel Clamp (police)",
            event    = "hk-parking:unclampWheel",
            type     = "client",
            job      = { ["police"] = 0 },
            distance = 3.0,
            action = function(data)
                local entity = getEntity(data)
                local vehicle = entity
                TriggerServerEvent("hk-parking:server:toggleClamp", SafeNetId(vehicle), false)
            end,
            canInteract = function(data)
                local entity = getEntity(data)
                local state = Entity(entity).state
                return state and state.isClamped
            end,
        },
        -- (Removed the old "Impound vehicle (police)" target option — it fired a
        --  non-existent hk-parking:server:impound event and only showed a Dutch
        --  notify without actually impounding. Police impound is handled by the
        --  NPC-officer system in garage/impound.lua instead.)
    }
end

CreateThread(function()
    Wait(2000)
    if next(Target) then
        local options = createParkingOptions()
        for _, opt in ipairs(options) do if Target.name == "ox_target" then opt.onSelect = opt.action end end
        Target.addGlobalVehicle(options)
    end
end)