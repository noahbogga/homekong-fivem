--=====================================================================
-- hk-scenario :: client/props.lua
--   Distance-gated LOCAL prop spawner. Each client spawns its own
--   (non-networked) copy of nearby saved props and despawns them when
--   far — same philosophy as the clear engine, no network ownership.
--   Handles the per-prop interaction (qb-target / polyzone / auto) and
--   exposes the live handles to other resources via exports.
--=====================================================================

ScnProps = {}                 -- synced list from server (also read by editor)
ScnIsAdmin = false            -- set by server; gates the admin edit target handle
local spawned = {}            -- [propId] = { entity, data, targetAdded, autoFired }
local qbTargetOn = GetResourceState('qb-target') == 'started'

-- Server pushes our admin status so the "Edit prop" target only shows to admins.
RegisterNetEvent('hk-scenario:setAdminFlag', function(isAdmin)
    ScnIsAdmin = isAdmin and true or false
end)
CreateThread(function()
    Wait(2000)
    TriggerServerEvent('hk-scenario:requestAdminFlag')
end)

-- A compact signature of a prop's spawn-relevant fields. If it changes, the
-- spawned entity must be rebuilt; if not, we leave it alone (no flicker, and
-- no despawning a prop you're mid-editing).
local function propSig(p)
    return table.concat({
        p.model or '', p.x or 0, p.y or 0, p.z or 0,
        p.heading or 0, p.z_offset or 0, p.frozen and 1 or 0,
        p.trigger or '', p.action or '', p.action_data or '',
        p.interact_label or '', p.interact_icon or '', p.interact_dist or 0,
    }, '|')
end

-- Forward decls so the sync handler can reconcile.
local despawnProp

RegisterNetEvent('hk-scenario:props:sync', function(list)
    ScnProps = list or {}
    if UpdateEditorProps then UpdateEditorProps(ScnProps) end

    -- Reconcile spawned entities against the new list:
    --  * prop removed from list  -> despawn it
    --  * prop's signature changed -> despawn (engine re-spawns fresh)
    --  * unchanged                -> leave as-is (no flicker)
    local byId = {}
    for _, p in ipairs(ScnProps) do byId[p.id] = p end
    for id, rec in pairs(spawned) do
        local np = byId[id]
        if not np or propSig(np) ~= propSig(rec.data) then
            despawnProp(id)
        else
            rec.data = np   -- keep entity, refresh data reference
        end
    end
    -- (the engine loop spawns any new/changed props that are in range)
end)

AddEventHandler('onClientResourceStart', function(res)
    if res ~= GetCurrentResourceName() then return end
    TriggerServerEvent('hk-scenario:props:requestSync')
end)

-- ── Model loading ───────────────────────────────────────────────────────────
local function loadModel(model)
    local hash = type(model) == 'number' and model or joaat(model)
    if not IsModelValid(hash) then return nil end
    RequestModel(hash)
    local tries = 0
    while not HasModelLoaded(hash) and tries < 100 do Wait(10); tries = tries + 1 end
    if not HasModelLoaded(hash) then return nil end
    return hash
end

-- ── Action runner (shared by all trigger types) ─────────────────────────────
local function runAction(p)
    if p.action == 'command' and p.action_data ~= '' then
        ExecuteCommand(p.action_data)
    elseif p.action == 'client' and p.action_data ~= '' then
        TriggerEvent(p.action_data, p.id)
    elseif p.action == 'server' and p.action_data ~= '' then
        TriggerServerEvent('hk-scenario:props:serverAction', p.id)
    end
end
-- expose so the editor can "test" an action
Scn_runPropAction = runAction

-- ── Spawn / despawn one prop ────────────────────────────────────────────────
local function spawnProp(p)
    if spawned[p.id] then return end
    local hash = loadModel(p.model) or loadModel(ScnCfg.Props.fallbackModel)
    if not hash then return end
    local zz = p.z + (p.z_offset or 0.0)
    local ent = CreateObject(hash, p.x, p.y, zz, false, false, false)  -- not networked
    if not ent or ent == 0 then SetModelAsNoLongerNeeded(hash); return end
    SetEntityHeading(ent, p.heading or 0.0)
    if p.frozen then
        FreezeEntityPosition(ent, true)
        SetEntityInvincible(ent, true)
    end
    SetModelAsNoLongerNeeded(hash)

    local rec = { entity = ent, data = p }
    spawned[p.id] = rec

    -- qb-target options: the player-facing interaction (if configured) plus an
    -- admin-only "Edit" handle that opens this prop in the editor.
    if qbTargetOn then
        local opts = {}
        if p.trigger == 'target' and p.action ~= 'none' then
            opts[#opts+1] = {
                label = p.interact_label or 'Interact',
                icon = p.interact_icon or 'fas fa-hand-pointer',
                action = function() runAction(p) end,
            }
        end
        -- admin edit handle — canInteract gates it to allowed admins only.
        opts[#opts+1] = {
            label = 'Edit prop (scenario)',
            icon = 'fas fa-screwdriver-wrench',
            canInteract = function() return ScnIsAdmin == true end,
            action = function() TriggerEvent('hk-scenario:editProp', p.id) end,
        }
        if #opts > 0 then
            exports['qb-target']:AddTargetEntity(ent, {
                options = opts,
                distance = math.max(p.interact_dist or ScnCfg.Props.defaultInteractDist, 2.5),
            })
            rec.targetAdded = true
        end
    end

    -- fire hook so other resources can grab the handle
    TriggerEvent('hk-scenario:propSpawned', p.id, ent, p)
end

-- assignment (not `local function`) so it binds to the forward-declared upvalue
-- the sync handler above closes over.
despawnProp = function(id)
    local rec = spawned[id]
    if not rec then return end
    if rec.targetAdded and qbTargetOn and rec.entity and DoesEntityExist(rec.entity) then
        pcall(function() exports['qb-target']:RemoveTargetEntity(rec.entity) end)
    end
    if rec.entity and DoesEntityExist(rec.entity) then DeleteObject(rec.entity) end
    TriggerEvent('hk-scenario:propDespawned', id)
    spawned[id] = nil
end

-- Is this entity one of our locally-spawned scenario props? The clear engine
-- (client/main.lua) checks this so a zone's "clear objects" pass never deletes
-- a prop we placed. Same-client global, so main.lua can call it directly.
function Scn_isScenarioProp(ent)
    if not ent or ent == 0 then return false end
    for _, rec in pairs(spawned) do
        if rec.entity == ent then return true end
    end
    return false
end

local function despawnAll()
    for id, _ in pairs(spawned) do despawnProp(id) end
end
AddEventHandler('onClientResourceStop', function(res)
    if res == GetCurrentResourceName() then despawnAll() end
end)
-- NOTE: the redundant "despawn everything on sync" handler was removed — the
-- sync handler above now reconciles precisely (no full flush, no flicker).

-- ── Engine: spawn nearby, despawn far, run zone interactions ────────────────
CreateThread(function()
    local rangeSq = ScnCfg.Props.spawnRange * ScnCfg.Props.spawnRange
    while true do
        local p = GetEntityCoords(PlayerPedId())
        local anyNear = false

        for _, prop in ipairs(ScnProps) do
            local dx, dy = p.x - prop.x, p.y - prop.y
            local near = (dx * dx + dy * dy) <= rangeSq
            if near then
                anyNear = true
                if not spawned[prop.id] then spawnProp(prop) end
            elseif spawned[prop.id] then
                despawnProp(prop.id)
            end
        end

        -- zone-based interactions (zonekey / zoneauto) for spawned props
        for id, rec in pairs(spawned) do
            local pr = rec.data
            if pr.trigger == 'zonekey' or pr.trigger == 'zoneauto' then
                local d = #(p - vector3(pr.x, pr.y, pr.z + (pr.z_offset or 0.0)))
                if d <= (pr.interact_dist or ScnCfg.Props.defaultInteractDist) then
                    if pr.trigger == 'zoneauto' then
                        if not rec.autoFired then rec.autoFired = true; runAction(pr) end
                    else -- zonekey
                        -- drawn hint + key check handled in a tight sub-loop below
                        rec.inRange = true
                    end
                else
                    rec.autoFired = false
                    rec.inRange = false
                end
            end
        end

        Wait(anyNear and 300 or ScnCfg.Props.scanInterval)
    end
end)

-- zonekey: while any spawned prop is in range, show a hint + listen for E (38)
CreateThread(function()
    while true do
        local acted = false
        for _, rec in pairs(spawned) do
            local pr = rec.data
            if pr.trigger == 'zonekey' and rec.inRange then
                acted = true
                lib.showTextUI(('[E] %s'):format(pr.interact_label or 'Interact'), { position = 'left-center' })
                if IsControlJustPressed(0, 38) then  -- E
                    runAction(pr)
                end
            end
        end
        if not acted then lib.hideTextUI() end
        Wait(acted and 0 or 400)
    end
end)

-- ── Exports for other resources ─────────────────────────────────────────────
-- Saved list (data only).
exports('GetProps', function() return ScnProps end)
-- Live spawned entity handle for a prop id (or nil if not currently spawned).
exports('GetPropEntity', function(id)
    local rec = spawned[tonumber(id)]
    return rec and rec.entity or nil
end)
-- Full spawned record { entity, data } for a prop id.
exports('GetSpawnedProp', function(id)
    local rec = spawned[tonumber(id)]
    if not rec then return nil end
    return { entity = rec.entity, data = rec.data }
end)
