-- hk-crafting :: client/craft.lua
-- Opens the custom HK NUI crafting panel for a table, drives the zoom camera and
-- the spinning preview prop, and runs the authoritative craft callback.

local QBCore = exports['qb-core']:GetCoreObject()

local PanelOpen   = false
local TableCam    = nil
local PreviewProp = nil
local ActiveTable = nil

-- After a repair, qb-weapons needs the equipped weapon re-drawn to pick up the
-- new quality. If the player is holding the repaired weapon, holster + redraw.
RegisterNetEvent('hk-crafting:client:refreshWeapon', function(wpn)
    local ped = cache.ped
    if not wpn or not wpn.name then return end
    local held = GetSelectedPedWeapon(ped)
    if held == `WEAPON_UNARMED` or held ~= joaat(wpn.name) then return end  -- not holding it
    -- re-trigger qb-weapons' own equip flow so it re-caches CurrentWeaponData
    TriggerEvent('qb-weapons:client:UseWeapon', wpn, true)   -- holster
    Wait(150)
    TriggerEvent('qb-weapons:client:UseWeapon', wpn, true)   -- redraw with fresh quality
end)

-- ── Camera on the bench ────────────────────────────────────────────────────
-- Works for both portable tables (entity present) and fixed stations (coords
-- + heading only). The camera sits just behind the bench looking down at it.
local function startCam(tbl)
    local bx, by, bz = tbl.coords.x, tbl.coords.y, tbl.coords.z
    local heading = tbl.heading or 0.0
    if tbl.entity and DoesEntityExist(tbl.entity) then
        heading = GetEntityHeading(tbl.entity)
    end

    -- offset 0.9m "behind" the bench along its heading
    local rad = math.rad(heading + 180.0)
    local camX = bx + math.sin(-rad) * 0.9
    local camY = by + math.cos(-rad) * 0.9

    TableCam = CreateCam('DEFAULT_SCRIPTED_CAMERA', true)
    SetCamCoord(TableCam, camX, camY, bz + 1.1)
    SetCamRot(TableCam, -12.0, 0.0, heading + 180.0, 2)
    SetCamActive(TableCam, true)
    RenderScriptCams(true, true, 500, true, false)
    FreezeEntityPosition(cache.ped, true)
end

local function stopCam()
    RenderScriptCams(false, true, 400, true, false)
    if TableCam then DestroyCam(TableCam, false); TableCam = nil end
    FreezeEntityPosition(cache.ped, false)
end

-- ── Preview prop floating above the bench ──────────────────────────────────
local function clearPreview()
    if PreviewProp and DoesEntityExist(PreviewProp) then DeleteEntity(PreviewProp) end
    PreviewProp = nil
end

local PREVIEW_TARGET_SIZE = 0.55   -- desired longest-dimension of the preview (metres)

local function spawnPreview(model)
    clearPreview()
    if not model then return end
    local hash = type(model) == 'number' and model or joaat(model)
    if not IsModelValid(hash) then return end
    lib.requestModel(hash)
    local c = ActiveTable.coords
    PreviewProp = CreateObject(hash, c.x, c.y, c.z + 1.15, false, false, false)
    SetEntityCollision(PreviewProp, false, false)
    FreezeEntityPosition(PreviewProp, true)

    -- Normalise size: custom/addon weapon world models can be huge. Measure the
    -- model bounding box and scale so its longest side ≈ PREVIEW_TARGET_SIZE.
    local minDim, maxDim = GetModelDimensions(hash)
    local sx = (maxDim.x - minDim.x)
    local sy = (maxDim.y - minDim.y)
    local sz = (maxDim.z - minDim.z)
    local longest = math.max(sx, sy, sz)
    if longest and longest > 0.001 then
        local scale = PREVIEW_TARGET_SIZE / longest
        -- clamp so nothing becomes absurdly large or invisibly small
        if scale > 3.0 then scale = 3.0 elseif scale < 0.05 then scale = 0.05 end
        SetEntityScale(PreviewProp, scale, scale, scale)
    end
    SetModelAsNoLongerNeeded(hash)

    -- slow spin while the panel is open. Capture THIS prop so a superseded
    -- thread exits when PreviewProp is reassigned (no compounding/leaked threads).
    local mine = PreviewProp
    CreateThread(function()
        while mine == PreviewProp and DoesEntityExist(mine) and PanelOpen do
            SetEntityHeading(mine, (GetEntityHeading(mine) + 0.7) % 360.0)
            Wait(16)
        end
    end)
end

-- ── Build the item list the NUI expects (with owned material counts) ──────
-- Prefer the label from qb-core shared items so names match the inventory
-- (M9A3, M4A1, AK47, 防彈衣...) instead of a hand-written English rename.
local function itemLabel(itemName, fallback)
    local shared = QBCore.Shared and QBCore.Shared.Items and QBCore.Shared.Items[itemName]
    return (shared and shared.label) or fallback or itemName
end

local function buildCraftables(tabletype)
    local cfg = Config.CraftingTables[tabletype]
    local list = {}
    for itemName, recipe in pairs(cfg.craftables) do
        local mats = {}
        for _, m in ipairs(recipe.materials) do
            mats[#mats + 1] = {
                item  = m.item,
                label = itemLabel(m.item, m.label),
                need  = m.amount,
                have  = 0,   -- filled in by withCounts()
                icon  = Config.InventoryImagePath:format(m.item),
            }
        end
        local label = itemLabel(itemName, recipe.label)
        -- blueprint label = the blueprint item's own qb-core label (繁中)
        local bpLabel = ''
        if recipe.blueprint then
            bpLabel = itemLabel(recipe.blueprint, recipe.blueprintLabel or recipe.blueprint)
        end
        list[#list + 1] = {
            item        = itemName,
            label       = label,
            description = recipe.description or L('ui_craft_desc', label),
            amount      = recipe.amount or 1,
            icon        = Config.InventoryImagePath:format(itemName),
            materials   = mats,
            hasBlueprint = recipe.blueprint and true or false,
            blueprintLabel = bpLabel,
            category    = recipe.category or 'General',
            order       = recipe.order or 9999,
        }
    end
    -- keep the config's GUNS order (so e.g. Bullet Shells lists before the clips)
    table.sort(list, function(a, b) return a.order < b.order end)
    return list
end

-- Count owned items straight off the local player's inventory data.
local function ownedCount(item)
    local pd = QBCore.Functions.GetPlayerData()
    local items = pd and pd.items
    if not items then return 0 end
    local total = 0
    for _, slot in pairs(items) do
        if slot and slot.name == item then total = total + (slot.amount or slot.count or 0) end
    end
    return total
end

-- List the player's held weapons (for the repair selector), reading straight off
-- local inventory data. Each = { slot, item, label, serie, quality }.
local function listWeapons()
    local pd = QBCore.Functions.GetPlayerData()
    local items = pd and pd.items
    local out = {}
    if not items then return out end
    for _, slot in pairs(items) do
        if slot and type(slot.name) == 'string' and slot.name:match('^weapon_') then
            local info = slot.info or {}
            local shared = QBCore.Shared.Items[slot.name]
            out[#out + 1] = {
                slot    = slot.slot,
                item    = slot.name,
                label   = (shared and shared.label) or slot.name,
                serie   = info.serie or '',
                quality = math.floor(tonumber(info.quality) or 100),
                icon    = Config.InventoryImagePath:format(slot.name),
            }
        end
    end
    return out
end

-- Re-resolve material counts. `counter(item)` returns how many are available;
-- defaults to the player's pockets, but a stash-backed bench passes a stash
-- lookup so have/need reflects the job stash.
local function withCounts(list, counter)
    counter = counter or ownedCount
    for _, entry in ipairs(list) do
        for _, m in ipairs(entry.materials) do
            m.have = counter(m.item)
        end
    end
    return list
end

-- ── Open / close ────────────────────────────────────────────────────────
-- `tbl` is either a portable table { id, type, name, coords, heading, entity }
-- or a fixed station { station=true, recipeSet, name, coords, heading }.
function OpenCraftingPanel(tbl)
    if PanelOpen then return end
    ActiveTable = tbl
    PanelOpen = true

    -- recipeSet is the Config.CraftingTables key this bench draws from.
    local recipeSet = tbl.recipeSet or tbl.type
    ActiveTable.recipeSet = recipeSet

    startCam(tbl)

    local cfg = Config.CraftingTables[recipeSet]
    local list = buildCraftables(recipeSet)

    -- Material counts: from the job stash if this bench uses one, else pockets.
    -- Blueprints are always checked against personal inventory.
    local matCounter = ownedCount
    if cfg.materialStash then
        -- gather all material item names, query the stash once
        local wanted, seen = {}, {}
        for _, entry in ipairs(list) do
            for _, m in ipairs(entry.materials) do
                if not seen[m.item] then seen[m.item] = true; wanted[#wanted + 1] = m.item end
            end
        end
        local counts = lib.callback.await('hk-crafting:getStashCounts', false, recipeSet, wanted) or {}
        matCounter = function(item) return counts[item] or 0 end
    end
    withCounts(list, matCounter)

    for _, entry in ipairs(list) do
        local recipe = cfg.craftables[entry.item]
        entry.hasBlueprintItem = (not recipe.blueprint) or (ownedCount(recipe.blueprint) > 0)
    end

    -- Repair tab exposed only on the gundealer bench, with the player's grade so
    -- the UI can grey it out below MinGrade.
    local pd = QBCore.Functions.GetPlayerData()
    local jobGrade = (pd and pd.job and pd.job.grade and pd.job.grade.level) or 0
    local repairInfo = nil
    if Config.Repair and Config.Repair.enabled and recipeSet == 'gundealer' then
        repairInfo = {
            enabled  = true,
            minGrade = Config.Repair.MinGrade,
            grade    = jobGrade,
            costPer  = Config.Repair.CostPerPoint,
        }
    end

    SetNuiFocus(true, true)
    SendNUIMessage({
        action    = 'open',
        title     = tbl.name,
        tableLabel = cfg.label,
        accent    = Config.Placement.OutlineColor,
        craftables = list,
        repair    = repairInfo,
        locales   = {
            required    = L('craft_required'),
            craft       = L('craft_button'),
            have        = L('have_label'),
            selectHint  = L('ui_select_hint'),
            makes       = L('ui_makes'),
            blueprint   = L('ui_blueprint'),
            repairTab   = L('ui_repair_tab'),
            repairBtn   = L('ui_repair_btn'),
            repairTarget= L('ui_repair_target'),
            repairNoWeapons = L('ui_repair_none'),
            repairLocked = L('ui_repair_locked'),
        },
    })
end

local function closePanel()
    if not PanelOpen then return end
    PanelOpen = false
    SetNuiFocus(false, false)
    clearPreview()
    stopCam()
    ActiveTable = nil
    SendNUIMessage({ action = 'close' })
end

-- ── NUI callbacks ──────────────────────────────────────────────────────────
RegisterNUICallback('close', function(_, cb)
    closePanel()
    cb('ok')
end)

-- Repair: list the player's held weapons + current stock of repair materials
-- (from the gundealer job stash if set, else pockets), so the UI shows have/need.
RegisterNUICallback('getWeapons', function(_, cb)
    local stock = {}
    if Config.Repair and Config.Repair.CostPerPoint then
        local stashId = (Config.CraftingTables['gundealer'] or {}).materialStash
        if stashId then
            local wanted = {}
            for _, c in ipairs(Config.Repair.CostPerPoint) do wanted[#wanted + 1] = c.item end
            stock = lib.callback.await('hk-crafting:getStashCounts', false, 'gundealer', wanted) or {}
        else
            for _, c in ipairs(Config.Repair.CostPerPoint) do
                stock[c.item] = ownedCount(c.item)
            end
        end
    end
    cb({ weapons = listWeapons(), stock = stock })
end)

-- Repair: run the repair on the server (authoritative grade + ownership + cost).
RegisterNUICallback('repair', function(data, cb)
    if not data or not data.slot or not data.target then cb({ ok = false }); return end

    local ok = lib.progressBar({
        duration     = (Config.Repair and Config.Repair.Duration) or 8000,
        label        = L('crafting_progress', L('ui_repair_progress')),
        useWhileDead = false,
        canCancel    = true,
        disable      = { move = true, car = true, combat = true },
        anim         = { dict = 'amb@prop_human_bbq@male@base', clip = 'base' },
    })
    if not ok then cb({ ok = false, cancelled = true }); return end

    local result = lib.callback.await('hk-crafting:repairWeapon', false, data.slot, data.target)
    result = result or { ok = false }

    -- surface a real error instead of failing silently
    if result.ok then
        Notify(L('repair_ok', result.quality or 100), 'success')
    elseif result.reason == 'materials' then
        Notify(L('repair_no_materials'), 'error')
    elseif result.reason == 'grade' or result.reason == 'job' then
        Notify(L('repair_no_grade'), 'error')
    elseif result.reason == 'notfound' then
        Notify(L('not_found') ~= 'not_found' and L('not_found') or '找唔到武器', 'error')
    end
    cb(result)
end)

RegisterNUICallback('preview', function(data, cb)
    if PanelOpen and data and data.model ~= nil then
        local cfg = Config.CraftingTables[ActiveTable.recipeSet]
        local recipe = cfg and cfg.craftables[data.item]
        spawnPreview(recipe and recipe.model)
    end
    cb('ok')
end)

-- Remove the floating preview prop (called when leaving an item / switching tabs).
RegisterNUICallback('clearPreview', function(_, cb)
    clearPreview()
    cb('ok')
end)

RegisterNUICallback('craft', function(data, cb)
    if not PanelOpen or not ActiveTable or not data or not data.item then
        cb('ok'); return
    end

    local cfg = Config.CraftingTables[ActiveTable.recipeSet]
    local recipe = cfg and cfg.craftables[data.item]
    if not recipe then cb('ok'); return end

    -- Craft progress with the item preview still on the bench.
    local ok = lib.progressBar({
        duration     = recipe.duration or 5000,
        label        = L('crafting_progress', recipe.label),
        useWhileDead = false,
        canCancel    = true,
        disable      = { move = true, car = true, combat = true },
        anim         = { dict = 'amb@prop_human_bbq@male@base', clip = 'base' },
    })
    if not ok then
        Notify(L('craft_cancelled'), 'inform')
        SendNUIMessage({ action = 'reenable' })   -- un-disable the craft button
        cb('ok'); return
    end

    local result = lib.callback.await('hk-crafting:craft', false, ActiveTable.recipeSet, data.item)
    if result == 'job' then
        Notify(L('craft_no_job'), 'error')
    elseif result == 'blueprint' then
        Notify(L('craft_missing_bp', recipe.blueprintLabel or 'blueprint'), 'error')
    elseif result == 'materials' then
        Notify(L('craft_missing_items'), 'error')
    elseif result == 'full' then
        Notify(L('craft_inv_full'), 'error')
    elseif type(result) == 'table' then
        Notify(L('craft_success', result.amount, result.label), 'success')
    end

    -- Refresh material counts in the panel after crafting (stash-aware).
    if PanelOpen and ActiveTable then
        local list = buildCraftables(ActiveTable.recipeSet)
        local matCounter = ownedCount
        if cfg.materialStash then
            local wanted, seen = {}, {}
            for _, entry in ipairs(list) do
                for _, m in ipairs(entry.materials) do
                    if not seen[m.item] then seen[m.item] = true; wanted[#wanted + 1] = m.item end
                end
            end
            local counts = lib.callback.await('hk-crafting:getStashCounts', false, ActiveTable.recipeSet, wanted) or {}
            matCounter = function(item) return counts[item] or 0 end
        end
        withCounts(list, matCounter)
        for _, entry in ipairs(list) do
            local r = cfg.craftables[entry.item]
            entry.hasBlueprintItem = (not r.blueprint) or (ownedCount(r.blueprint) > 0)
        end
        SendNUIMessage({ action = 'refresh', craftables = list })
    end
    cb('ok')
end)

-- ESC closes even if focus edge-cases; also close if the player somehow leaves.
CreateThread(function()
    while true do
        if PanelOpen then
            if IsControlJustPressed(0, 322) then closePanel() end  -- ESC
            if ActiveTable and ActiveTable.entity and not DoesEntityExist(ActiveTable.entity) then
                closePanel()
            end
            -- death soft-lock guard: never leave the ped frozen + focus locked
            if IsEntityDead(cache.ped) then closePanel() end
            Wait(0)
        else
            Wait(300)
        end
    end
end)

AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() then closePanel() end
end)
