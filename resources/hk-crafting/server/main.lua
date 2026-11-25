-- hk-crafting :: server/main.lua
-- Table persistence + authoritative craft/place/pickup. All item mutation and
-- material validation happens here; the client is never trusted with amounts.

local QBCore = exports['qb-core']:GetCoreObject()

local TABLES = {}   -- [id] = { id, type, owner, name, coords={x,y,z}, heading }

local function dprint(...)
    if Config.Debug then print('[hk-crafting]', ...) end
end

local function L(key, ...)
    local s = (Locales[Config.Locale] or Locales['en'])[key] or key
    if select('#', ...) > 0 then return s:format(...) end
    return s
end

local function notify(src, msg, kind)
    TriggerClientEvent('ox_lib:notify', src, { description = msg, type = kind or 'inform' })
end

-- ── Inventory helpers (qb-inventory exports) ─────────────────────────────
local function countItem(src, item)
    local data = exports['qb-inventory']:GetItemByName(src, item)
    return (data and data.amount) or 0
end

local function giveItem(src, item, amount, info)
    return exports['qb-inventory']:AddItem(src, item, amount, false, info, 'hk-crafting')
end

local function takeItem(src, item, amount)
    return exports['qb-inventory']:RemoveItem(src, item, amount, false, 'hk-crafting')
end

-- ── Job-stash material helpers ────────────────────────────────────────────
-- Crafting materials are drawn from the job stash (e.g. 'gundealer_stash'), not
-- the crafter's pockets. Blueprints stay personal. We read/write the shared
-- stash inventory directly and persist it, so any worker crafts from the boss's
-- stocked stash without needing to open it.
-- GetInventory returns qb-inventory's LIVE table, so our slot mutation is
-- already shared with it. We only need to persist to DB when nobody has the
-- stash open — if it IS open, qb-inventory writes the same row on close, and a
-- competing raw write here would race/clobber it. When closed, qb-inventory
-- won't save it, so we must.
local function persistStash(stashId, inv)
    if inv.isOpen then return end   -- open: qb-inventory owns the save
    MySQL.prepare(
        'INSERT INTO inventories (identifier, items) VALUES (?, ?) ON DUPLICATE KEY UPDATE items = ?',
        { stashId, json.encode(inv.items), json.encode(inv.items) })
end

-- total count of an item across every slot in the stash
local function stashCount(stashId, item)
    local inv = exports['qb-inventory']:GetInventory(stashId)
    if not inv or not inv.items then return 0 end
    local total = 0
    for _, slot in pairs(inv.items) do
        if slot and slot.name == item then total = total + (slot.amount or 0) end
    end
    return total
end

-- remove `amount` of an item across slots; returns true only if fully removed.
local function stashTake(stashId, item, amount)
    local inv = exports['qb-inventory']:GetInventory(stashId)
    if not inv or not inv.items then return false end
    if stashCount(stashId, item) < amount then return false end
    local remaining = amount
    for key, slot in pairs(inv.items) do
        if remaining <= 0 then break end
        if slot and slot.name == item then
            local take = math.min(slot.amount or 0, remaining)
            slot.amount = (slot.amount or 0) - take
            remaining = remaining - take
            if slot.amount <= 0 then inv.items[key] = nil end
        end
    end
    persistStash(stashId, inv)
    return remaining <= 0
end

-- Serial in qb-inventory's own format (int/str mix), so crafted weapons look
-- identical to shop-bought ones and the license serial matches the weapon.
function genWeaponSerial()
    return tostring(
        QBCore.Shared.RandomInt(2) .. QBCore.Shared.RandomStr(3) ..
        QBCore.Shared.RandomInt(1) .. QBCore.Shared.RandomStr(2) ..
        QBCore.Shared.RandomInt(3) .. QBCore.Shared.RandomStr(4)
    )
end

-- Issue a weapon license via hk-documents (safe no-op if that resource is off).
function issueWeaponLicense(src, itemName, weaponLabel, serie)
    local wl = Config.WeaponLicense
    if not (wl and wl.enabled) then return end
    if GetResourceState('hk-documents') ~= 'started' then
        dprint('hk-documents not started; skipping weapon license')
        return
    end

    local ok, err = pcall(function()
        exports['hk-documents']:issueDocument(src, {
            job     = wl.job,
            docType = wl.docType or 'license',
            title   = wl.title or 'Firearm Registration',
            issuerId = 'hk-crafting',
            issuer  = { firstname = 'Firearms', lastname = 'Registry', jobLabel = 'Firearms License' },
            fields  = {
                { name = 'Owner',       value = '' },              -- left blank
                { name = 'Weapon',      value = weaponLabel or itemName },
                { name = 'Model',       value = itemName },
                { name = 'Serial No.',  value = serie },
            },
            expiry  = '',                                          -- left blank
        })
    end)
    if not ok then dprint('issueWeaponLicense failed:', err) end
end

-- ── Persistence ──────────────────────────────────────────────────────────
local function saveTable(t)
    if not Config.SaveToDatabase then return end
    MySQL.query(
        'REPLACE INTO `hk_crafting_tables` (tableid, tabletype, owner, name, coords, heading) VALUES (?, ?, ?, ?, ?, ?)',
        { t.id, t.type, t.owner, t.name, json.encode(t.coords), t.heading }
    )
end

local function deleteTable(id)
    if not Config.SaveToDatabase then return end
    MySQL.query('DELETE FROM `hk_crafting_tables` WHERE tableid = ?', { id })
end

local function newTableId()
    local id
    repeat id = math.random(100000, 999999) until not TABLES[id]
    return id
end

-- Server-side proximity check: is `src` within `maxDist` of a coord/table? Used
-- to reject remote (crafted-client) calls that skip the bench entirely.
local PROX_MAX = 6.0   -- generous: covers target distance + a little slack

local function distTo(src, coords)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return math.huge end
    local pc = GetEntityCoords(ped)
    local dx, dy, dz = pc.x - coords.x, pc.y - coords.y, pc.z - coords.z
    return math.sqrt(dx*dx + dy*dy + dz*dz)
end

-- True if the player is near ANY placed table of `tabletype`, OR any fixed
-- station whose recipe set is `tabletype`.
local function nearBench(src, tabletype)
    for _, t in pairs(TABLES) do
        if t.type == tabletype and distTo(src, t.coords) <= PROX_MAX then return true end
    end
    for _, st in ipairs(Config.Stations or {}) do
        if st.uses == tabletype and st.coords and distTo(src, st.coords) <= PROX_MAX then return true end
    end
    return false
end

-- ── Callbacks ──────────────────────────────────────────────────────────────
lib.callback.register('hk-crafting:loadTables', function()
    return TABLES
end)

-- Return current stash counts for a set of item names (for accurate have/need).
-- The stash is derived server-side from the bench the player is actually at —
-- the client cannot name an arbitrary stash to snoop its contents.
lib.callback.register('hk-crafting:getStashCounts', function(src, tabletype, items)
    local out = {}
    local cfg = Config.CraftingTables[tabletype]
    if not cfg or not cfg.materialStash or type(items) ~= 'table' then return out end

    -- gate: must be at the bench, and (if the set is job-locked) hold the job
    if not nearBench(src, tabletype) then return out end
    if cfg.jobLock then
        local Player = QBCore.Functions.GetPlayer(src)
        local job = Player and Player.PlayerData.job
        if not job or job.name ~= cfg.jobLock then return out end
    end

    for _, item in ipairs(items) do
        out[item] = stashCount(cfg.materialStash, item)
    end
    return out
end)

lib.callback.register('hk-crafting:placeTable', function(src, tabletype, coords, heading)
    local cfg = Config.CraftingTables[tabletype]
    if not cfg then return false end

    -- Player must actually hold the table item.
    if countItem(src, tabletype) < 1 then return false end
    if not takeItem(src, tabletype, 1) then return false end

    local name = GetPlayerName(src) or ('Player ' .. src)
    local t = {
        id      = newTableId(),
        type    = tabletype,
        owner   = GetPlayerIdentifierByType(src, 'license') or GetPlayerIdentifier(src, 0),
        name    = L('table_name', tostring(name):sub(1, 32)),
        coords  = { x = coords.x + 0.0, y = coords.y + 0.0, z = coords.z + 0.0 },
        heading = heading + 0.0,
    }

    TABLES[t.id] = t
    saveTable(t)
    TriggerClientEvent('hk-crafting:sync', -1, 'create', t)
    dprint('placed table', t.id, t.type, 'by', t.owner)
    return t
end)

lib.callback.register('hk-crafting:pickupTable', function(src, id)
    id = tonumber(id)   -- TABLES is keyed by numeric id; client may send a string
    local t = id and TABLES[id]
    if not t then return false end

    -- Must actually be standing at the table (blocks remote ID-enumeration theft).
    if distTo(src, t.coords) > PROX_MAX then return false end

    if Config.Target.OwnerOnlyPickup then
        local ident = GetPlayerIdentifierByType(src, 'license') or GetPlayerIdentifier(src, 0)
        if ident ~= t.owner then
            notify(src, L('pickup_not_owner'), 'error')
            return false
        end
    end

    if not giveItem(src, t.type, 1) then return false end

    TABLES[id] = nil
    deleteTable(id)
    TriggerClientEvent('hk-crafting:sync', -1, 'delete', id)
    dprint('picked up table', id)
    return true
end)

-- Returns: false = bad request, 'blueprint' = missing bp, 'materials' = missing mats,
--          or a table { label, amount } on success.
lib.callback.register('hk-crafting:craft', function(src, tabletype, itemName)
    local cfg = Config.CraftingTables[tabletype]
    if not cfg then return false end
    local recipe = cfg.craftables[itemName]
    if not recipe then return false end

    -- Must be at a matching bench/station (blocks remote crafting).
    if not nearBench(src, tabletype) then return false end

    -- Job gate (authoritative — client target gating can be bypassed).
    if cfg.jobLock then
        local Player = QBCore.Functions.GetPlayer(src)
        if not Player then return false end
        local job = Player.PlayerData.job
        if not job or job.name ~= cfg.jobLock then
            return 'job'
        end
        if cfg.minGrade and (job.grade and job.grade.level or 0) < cfg.minGrade then
            return 'job'
        end
    end

    -- Blueprint gate — blueprints stay PERSONAL (boss hands them to the worker).
    if recipe.blueprint then
        if countItem(src, recipe.blueprint) < 1 then
            return 'blueprint'
        end
    end

    -- Materials come from the job stash if the table defines one, else pockets.
    local stashId = cfg.materialStash
    local haveMat = function(item) return stashId and stashCount(stashId, item) or countItem(src, item) end
    local takeMat = function(item, amt) return stashId and stashTake(stashId, item, amt) or takeItem(src, item, amt) end

    -- Verify every material BEFORE removing anything (no partial consumption).
    for _, mat in ipairs(recipe.materials) do
        if haveMat(mat.item) < mat.amount then
            return 'materials'
        end
    end

    -- Make sure the finished item will fit BEFORE consuming anything, so a full
    -- inventory can't eat the materials and drop the result.
    local outAmount = recipe.amount or 1
    if not exports['qb-inventory']:CanAddItem(src, itemName, outAmount) then
        return 'full'
    end

    -- Consume.
    for _, mat in ipairs(recipe.materials) do
        if not takeMat(mat.item, mat.amount) then
            -- Shouldn't happen after the check above; bail without granting.
            return 'materials'
        end
    end

    if recipe.blueprint and recipe.consumeBlueprint then
        takeItem(src, recipe.blueprint, 1)   -- always personal
    end

    -- Weapon-license hook: for gundealer weapon crafts, mint a serial, attach it
    -- to the weapon, and issue a matching license document (owner/expiry blank).
    local wl = Config.WeaponLicense
    local isLicensedWeapon = wl and wl.enabled
        and tabletype == wl.recipeSet
        and itemName:match(wl.itemPattern) ~= nil

    local granted
    if isLicensedWeapon then
        local serie = genWeaponSerial()
        -- use the qb-core shared label so the license matches the inventory name
        local shared = QBCore.Shared.Items[itemName]
        local weaponLabel = (shared and shared.label) or recipe.label
        -- attach the serial to the weapon instance so item + license match
        granted = giveItem(src, itemName, 1, { serie = serie, quality = 100 })
        -- only mint the license if the weapon actually landed (no phantom license)
        if granted then issueWeaponLicense(src, itemName, weaponLabel, serie) end
    else
        granted = giveItem(src, itemName, outAmount)
    end

    -- If the grant somehow failed after the CanAddItem check, refund materials so
    -- nothing is silently eaten.
    if not granted then
        for _, mat in ipairs(recipe.materials) do
            if stashId then
                local inv = exports['qb-inventory']:GetInventory(stashId)
                if inv then exports['qb-inventory']:AddItem(stashId, mat.item, mat.amount, false, nil, 'hk-crafting-refund') end
            else
                giveItem(src, mat.item, mat.amount)
            end
        end
        if recipe.blueprint and recipe.consumeBlueprint then
            giveItem(src, recipe.blueprint, 1)
        end
        return 'full'
    end

    dprint('crafted', outAmount, itemName, 'for', src)
    return { label = recipe.label, amount = outAmount }
end)

-- ── Weapon repair (authoritative) ─────────────────────────────────────────
-- Cost scales with points restored; gundealer picks the target quality client-
-- side, server recomputes and enforces grade + ownership + materials.
local function repairCost(points)
    local list = {}
    for _, c in ipairs(Config.Repair.CostPerPoint) do
        local amt = math.ceil(points * c.per)
        if amt > 0 then list[#list + 1] = { item = c.item, label = c.label, amount = amt } end
    end
    return list
end

lib.callback.register('hk-crafting:repairWeapon', function(src, slot, target)
    if not (Config.Repair and Config.Repair.enabled) then return { ok = false } end

    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return { ok = false } end

    -- must be at the gundealer bench/station
    if not nearBench(src, 'gundealer') then return { ok = false, reason = 'far' } end

    -- job + grade gate (authoritative)
    local job = Player.PlayerData.job
    if not job or job.name ~= 'gundealer' then return { ok = false, reason = 'job' } end
    if (job.grade and job.grade.level or 0) < Config.Repair.MinGrade then
        return { ok = false, reason = 'grade' }
    end

    -- the weapon must exist in that exact slot and be a weapon.
    -- items is keyed by NUMERIC slot; the slot can arrive as a string, so coerce.
    slot = tonumber(slot)
    local wpn = slot and Player.PlayerData.items[slot]
    if not wpn or type(wpn.name) ~= 'string' or not wpn.name:match('^weapon_') then
        return { ok = false, reason = 'notfound' }
    end

    local current = math.floor(tonumber(wpn.info and wpn.info.quality) or 100)
    target = math.floor(tonumber(target) or 0)
    if target < 1 then target = 1 elseif target > 100 then target = 100 end
    if target <= current then return { ok = false, reason = 'nogain' } end

    local points = target - current
    local cost = repairCost(points)

    -- repair materials come from the gundealer job stash (same as crafting)
    local stashId = (Config.CraftingTables['gundealer'] or {}).materialStash
    local haveMat = function(item) return stashId and stashCount(stashId, item) or countItem(src, item) end
    local takeMat = function(item, amt) return stashId and stashTake(stashId, item, amt) or takeItem(src, item, amt) end

    -- verify then consume materials (no partial consumption)
    for _, c in ipairs(cost) do
        if haveMat(c.item) < c.amount then return { ok = false, reason = 'materials', cost = cost } end
    end
    for _, c in ipairs(cost) do
        if not takeMat(c.item, c.amount) then return { ok = false, reason = 'materials' } end
    end

    -- apply
    wpn.info = wpn.info or {}
    wpn.info.quality = target
    Player.PlayerData.items[slot] = wpn
    Player.Functions.SetInventory(Player.PlayerData.items, true)

    -- qb-weapons caches the equipped weapon's durability at draw time and never
    -- re-reads it, so an in-hand repair looks like it "did nothing" until the
    -- weapon is holstered/redrawn. Force a re-equip so the fix is live now.
    TriggerClientEvent('hk-crafting:client:refreshWeapon', src, wpn)

    dprint('repaired', wpn.name, 'slot', slot, current .. '->' .. target, 'for', src)
    return { ok = true, quality = target }
end)

-- ── Boot: schema + load + register usable table items ────────────────────
CreateThread(function()
    if Config.SaveToDatabase then
        MySQL.query([[CREATE TABLE IF NOT EXISTS `hk_crafting_tables` (
            `tableid`   INT NOT NULL,
            `tabletype` VARCHAR(64) NOT NULL,
            `owner`     VARCHAR(64) NOT NULL,
            `name`      VARCHAR(64) NOT NULL,
            `coords`    TEXT NOT NULL,
            `heading`   FLOAT NOT NULL DEFAULT 0,
            PRIMARY KEY (`tableid`)
        )]])

        local rows = MySQL.query.await('SELECT * FROM `hk_crafting_tables`') or {}
        for _, row in ipairs(rows) do
            local c = json.decode(row.coords)
            TABLES[row.tableid] = {
                id      = row.tableid,
                type    = row.tabletype,
                owner   = row.owner,
                name    = row.name,
                coords  = { x = c.x, y = c.y, z = c.z },
                heading = tonumber(row.heading) or 0.0,
            }
        end
        dprint('loaded', #rows, 'tables from db')
    end

    -- Register each PLACEABLE table item as usable so "using" it triggers
    -- placement. Skip fixed-station recipe sets (jobLock/materialStash) like
    -- 'gundealer' — those aren't inventory items, so registering them is dead.
    for tabletype, cfg in pairs(Config.CraftingTables) do
        if not cfg.jobLock and not cfg.materialStash then
            QBCore.Functions.CreateUseableItem(tabletype, function(source)
                TriggerClientEvent('hk-crafting:startPlacing', source, tabletype)
            end)
        end
    end
end)
