-- hk-crafting :: client/main.lua
-- Spawns/tracks placed table props, wires qb-target onto them, keeps in sync
-- with the server. Placement lives in place.lua; the panel lives in craft.lua.

local QBCore = exports['qb-core']:GetCoreObject()

Points = {}            -- [id] = ox_lib point handle
SpawnedProps = {}      -- [id] = prop entity (exists only while player is nearby)
CurrentTable = nil     -- table the player is currently interacting with

function L(key, ...)
    local s = (Locales[Config.Locale] or Locales['en'])[key] or key
    if select('#', ...) > 0 then return s:format(...) end
    return s
end

function Notify(msg, kind)
    lib.notify({ description = msg, type = kind or 'inform' })
end

local function dprint(...)
    if Config.Debug then print('[hk-crafting]', ...) end
end

-- ── qb-target on a placed prop ────────────────────────────────────────────
local function addTarget(entity, tbl)
    exports['qb-target']:AddTargetEntity(entity, {
        options = {
            {
                icon   = Config.Target.OpenIcon,
                label  = Config.Target.OpenLabel,
                action = function() OpenCraftingPanel(tbl) end,
            },
            {
                icon   = Config.Target.PickupIcon,
                label  = Config.Target.PickupLabel,
                action = function() PickupTable(tbl) end,
            },
        },
        distance = Config.Target.Distance,
    })
end

-- ── ox_lib point lifecycle ────────────────────────────────────────────────
local function onEnter(self)
    local cfg = Config.CraftingTables[self.tableType]
    if not cfg then return end

    lib.requestModel(cfg.model)
    local c = self.tableCoords
    local prop = CreateObject(cfg.model, c.x, c.y, c.z, false, false, false)
    SetEntityHeading(prop, self.tableHeading)
    PlaceObjectOnGroundProperly(prop)
    FreezeEntityPosition(prop, true)
    SetModelAsNoLongerNeeded(cfg.model)

    SpawnedProps[self.tableId] = prop

    local tbl = {
        id      = self.tableId,
        type    = self.tableType,
        name    = self.tableName,
        coords  = self.tableCoords,
        heading = self.tableHeading,
        entity  = prop,
    }
    addTarget(prop, tbl)
    dprint('spawned prop for table', self.tableId)
end

local function onExit(self)
    local prop = SpawnedProps[self.tableId]
    if prop and DoesEntityExist(prop) then
        exports['qb-target']:RemoveTargetEntity(prop)
        DeleteEntity(prop)
    end
    SpawnedProps[self.tableId] = nil
    if CurrentTable and CurrentTable.id == self.tableId then
        CurrentTable = nil
    end
end

local function registerPoint(t)
    Points[t.id] = lib.points.new({
        coords       = vec3(t.coords.x, t.coords.y, t.coords.z),
        distance     = 25.0,
        tableId      = t.id,
        tableType    = t.type,
        tableName    = t.name,
        tableCoords  = vec3(t.coords.x, t.coords.y, t.coords.z),
        tableHeading = t.heading,
        onEnter      = onEnter,
        onExit       = onExit,
    })
end

local function removePoint(id)
    local p = Points[id]
    if p then
        if SpawnedProps[id] then onExit({ tableId = id }) end
        p:remove()
        Points[id] = nil
    end
end

-- ── Pickup flow (client side of the callback) ─────────────────────────────
function PickupTable(tbl)
    local ok = lib.progressBar({
        duration    = Config.Placement.PickupDuration,
        label       = L('picking_up_table'),
        useWhileDead = false,
        canCancel   = true,
        disable     = { car = true, move = true, combat = true },
        anim        = { dict = 'pickup_object', clip = 'pickup_low' },
    })
    if not ok then return end

    local success = lib.callback.await('hk-crafting:pickupTable', false, tbl.id)
    Notify(success and L('picked_up_table') or L('pickup_failed'), success and 'success' or 'error')
end

-- ── Sync from server ──────────────────────────────────────────────────────
RegisterNetEvent('hk-crafting:sync', function(action, payload)
    if action == 'create' then
        registerPoint(payload)
    elseif action == 'delete' then
        removePoint(payload)
    end
end)

-- ── Initial load ──────────────────────────────────────────────────────────
local function loadAll()
    for id in pairs(Points) do removePoint(id) end
    local tables = lib.callback.await('hk-crafting:loadTables', false) or {}
    for _, t in pairs(tables) do registerPoint(t) end
    dprint('loaded tables into world')
end

AddEventHandler('QBCore:Client:OnPlayerLoaded', loadAll)

AddEventHandler('onResourceStart', function(res)
    if res ~= GetCurrentResourceName() then return end
    if LocalPlayer.state.isLoggedIn then loadAll() end
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    for id in pairs(Points) do removePoint(id) end
end)
