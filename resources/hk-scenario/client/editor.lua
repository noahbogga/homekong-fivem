-- hk-cleararea :: client/editor.lua
-- MenuV arrow-key editor, qb-adminmenu / hk-race style. MenuV does NOT grab
-- movement focus, so you can walk, drive, and noclip while the menu is open —
-- unlike ox_lib context menus (the previous version) which froze the player.
--
-- Pattern (copied from hk-race editor, the known-good one on this server):
--   * every menu created ONCE at file scope with a unique namespace,
--   * dynamic lists rebuilt with ClearItems() + AddButton() then OpenMenu(that),
--   * AddRange :On('change') for live radius (arrow keys resize, live marker),
--   * typed input = MenuV:CloseAll() -> lib.inputDialog -> reopen (rebuilt) menu,
--   * navigation is EXPLICIT via goMain/goList/goZone (CloseAll + rebuild + open)
--     because MenuV:CloseAll wipes its internal parent stack, so CloseMenu-based
--     back navigation can't be relied on.
--
-- SAVE MODEL: every edit stages into the local `working` copy only. Nothing is
-- written to the DB until the "SAVE & CLOSE" button. (Create is the exception:
-- it inserts a row immediately so the id exists.)
--
-- The editor owns a single local WORKING COPY of the zone (`working`) and edits
-- THAT, then saves. It never re-reads the server-synced list for the thing it
-- is editing (that list arrives a round-trip late and would clobber edits).

local editorZones = {}   -- server-synced list, used for the LIST page only
local working = nil      -- the zone currently being edited/created
local editing = false
local previewThread = false

-- main.lua calls this on every server sync.
function UpdateEditorZones(list)
    editorZones = list or {}
end

local function notify(msg, kind)
    lib.notify({ title = 'Scenario', description = msg, type = kind or 'info' })
end

local function playerCoords() return GetEntityCoords(PlayerPedId()) end
local function playerHeading() return GetEntityHeading(PlayerPedId()) end

-- ── Menus (created ONCE at file scope) ──────────────────────────────────────
-- Top level -> section hubs -> pages. Each feature area (Clear Area, Props, and
-- future ones) is its own hub so the main menu stays a clean section list.
local mMain  = MenuV:CreateMenu('HK Scenario', 'Select a module', 'topleft',
    120, 200, 255, 'size-125', 'none', 'menuv', 'hkscn_main')

-- Clear Area module (blue)
local mClear = MenuV:CreateMenu('Clear Area', 'Zones: clear & block', 'topleft',
    0, 150, 255, 'size-125', 'none', 'menuv', 'hkscn_clear')
local mList  = MenuV:CreateMenu('Clear Zones', 'Select one to edit', 'topleft',
    0, 150, 255, 'size-125', 'none', 'menuv', 'hkscn_list')
local mZone  = MenuV:CreateMenu('Edit Zone', '', 'topleft',
    0, 150, 255, 'size-125', 'none', 'menuv', 'hkscn_zone')

-- Props module (orange)
local mProps = MenuV:CreateMenu('Props', 'Place & manage props', 'topleft',
    255, 150, 0, 'size-125', 'none', 'menuv', 'hkscn_props')
local mPList = MenuV:CreateMenu('Placed Props', 'Select one to edit', 'topleft',
    255, 150, 0, 'size-125', 'none', 'menuv', 'hkscn_plist')
local mProp  = MenuV:CreateMenu('Edit Prop', '', 'topleft',
    255, 150, 0, 'size-125', 'none', 'menuv', 'hkscn_prop')
local mCats  = MenuV:CreateMenu('Prop Catalog', 'Browse by category', 'topleft',
    255, 150, 0, 'size-125', 'none', 'menuv', 'hkscn_cats')
local mCat   = MenuV:CreateMenu('Category', '', 'topleft',
    255, 150, 0, 'size-125', 'none', 'menuv', 'hkscn_cat')
local mSearch= MenuV:CreateMenu('Prop Search', 'Results', 'topleft',
    255, 150, 0, 'size-125', 'none', 'menuv', 'hkscn_search')

-- World Population module (green)
local mPop = MenuV:CreateMenu('World Population', 'Ambient density (server-wide)', 'topleft',
    0, 200, 120, 'size-125', 'none', 'menuv', 'hkscn_pop')

-- Traffic realism module (red — NO HESI / Wangan)
local mTraffic = MenuV:CreateMenu('Traffic Realism', 'NPC speed & highway spawner', 'topleft',
    230, 60, 60, 'size-125', 'none', 'menuv', 'hkscn_traffic')

-- prop state (mirrors zone `working` model)
local editorProps = {}       -- server-synced prop list (list page only)
local wprop = nil            -- prop working copy being edited/created
function UpdateEditorProps(list) editorProps = list or {} end

-- Hold-to-repeat for the prop nudge bars. MenuV only fires 'change' on a fresh
-- key PRESS, so we run a background thread that, while a nudge bar is the
-- highlighted row, reads the raw LEFT/RIGHT keys every frame and auto-repeats
-- the nudge (with acceleration) as long as you HOLD the key.
local heldNudge = nil        -- { apply = fn, refresh = fn } for the focused bar
CreateThread(function()
    local held = 0.0
    while true do
        if heldNudge and MenuV.CurrentMenu == mProp then
            local left  = IsControlPressed(0, 174)   -- arrow left
            local right = IsControlPressed(0, 175)    -- arrow right
            if left or right then
                held = held + 0.05
                -- First ~200ms of a press belongs to MenuV's single-step
                -- 'change' (so a tap = exactly one step). Only once held past
                -- that do we auto-repeat here, with acceleration.
                if held > 0.2 then
                    local ramp = math.min(held - 0.2, 2.0)
                    local mult = 1 + math.floor(ramp * ramp * 8)
                    heldNudge.apply((right and 1 or -1) * mult)
                    heldNudge.refresh()
                end
                Wait(55)   -- repeat cadence while held
            else
                held = 0.0
                Wait(0)
            end
        else
            held = 0.0
            Wait(120)
        end
    end
end)

-- forward decls (mutual recursion between the pages)
local buildMain, buildList, buildZone, saveZone
local buildClearHub, goClearHub
local buildPropsHub, goPropsHub, buildPList, buildProp, saveProp, goPList, goProp
local buildCats, goCats, buildCat, goCat, buildSearch, goSearch
local spawnFromModel, ghostStart, ghostStop
local buildPop, goPop
local buildTraffic, goTraffic

-- ── Navigation helpers ──────────────────────────────────────────────────────
-- We do NOT rely on MenuV's internal parent-menu stack for Back navigation,
-- because MenuV:CloseAll() (used before every typed-input dialog) WIPES that
-- stack — after which CloseMenu(child) has no parent to restore and just closes
-- everything. Instead every page transition is explicit: CloseAll to a known
-- empty state, rebuild the target page, then OpenMenu it. Deterministic.
local function goMain()  MenuV:CloseAll(function() end); buildMain(); MenuV:OpenMenu(mMain) end
local function goList()  working = nil; MenuV:CloseAll(function() end); buildList(); MenuV:OpenMenu(mList) end
local function goZone()  MenuV:CloseAll(function() end); buildZone(); MenuV:OpenMenu(mZone) end
goClearHub = function() working = nil; MenuV:CloseAll(function() end); buildClearHub(); MenuV:OpenMenu(mClear) end
goPropsHub = function() wprop = nil; MenuV:CloseAll(function() end); buildPropsHub(); MenuV:OpenMenu(mProps) end
goPList = function() wprop = nil; MenuV:CloseAll(function() end); buildPList(); MenuV:OpenMenu(mPList) end
goProp  = function() MenuV:CloseAll(function() end); buildProp(); MenuV:OpenMenu(mProp) end
goCats  = function() MenuV:CloseAll(function() end); buildCats(); MenuV:OpenMenu(mCats) end
goCat   = function(catIdx) MenuV:CloseAll(function() end); buildCat(catIdx); MenuV:OpenMenu(mCat) end
goSearch= function(term) MenuV:CloseAll(function() end); buildSearch(term); MenuV:OpenMenu(mSearch) end
goPop   = function() MenuV:CloseAll(function() end); buildPop(); MenuV:OpenMenu(mPop) end
goTraffic = function() MenuV:CloseAll(function() end); buildTraffic(); MenuV:OpenMenu(mTraffic) end

-- ── Neon wireframe box (GTA-online-neon look via DrawLine) ──────────────────
-- DrawLine has no real glow, so we fake neon: a bright cyan core whose alpha
-- pulses over time. 8 corners -> 12 edges. Corners are the box footprint
-- rotated by heading, from ground (z - height/2) to top (z + height/2).
local function drawNeonBox(z)
    local hr = math.rad(z.heading)
    local cos, sin = math.cos(hr), math.sin(hr)
    local hl, hw = z.length * 0.5, z.width * 0.5
    local zb = z.z - (z.height * 0.5)
    local zt = z.z + (z.height * 0.5)

    -- local footprint offsets (length along local Y, width along local X)
    local off = {
        { -hw, -hl }, {  hw, -hl }, {  hw,  hl }, { -hw,  hl },
    }
    local function worldXY(ox, oy)
        return z.x + (ox * cos - oy * sin), z.y + (ox * sin + oy * cos)
    end
    -- build 8 corners: [1..4] bottom, [5..8] top
    local cn = {}
    for i = 1, 4 do
        local wx, wy = worldXY(off[i][1], off[i][2])
        cn[i]   = { wx, wy, zb }
        cn[i+4] = { wx, wy, zt }
    end

    -- pulsing neon alpha + colour (cyan/blue neon)
    local t = GetGameTimer() / 1000.0
    local pulse = 150 + math.floor(105 * (0.5 + 0.5 * math.sin(t * 4.0)))  -- 150..255
    local r, g, b = 0, 230, 255
    local function line(a, c2)
        DrawLine(a[1], a[2], a[3], c2[1], c2[2], c2[3], r, g, b, pulse)
    end
    -- bottom rectangle
    line(cn[1], cn[2]); line(cn[2], cn[3]); line(cn[3], cn[4]); line(cn[4], cn[1])
    -- top rectangle
    line(cn[5], cn[6]); line(cn[6], cn[7]); line(cn[7], cn[8]); line(cn[8], cn[5])
    -- vertical pillars
    line(cn[1], cn[5]); line(cn[2], cn[6]); line(cn[3], cn[7]); line(cn[4], cn[8])
end

-- ── Prop location markers (only while the editor is open) ───────────────────
-- Draws a ring + vertical beacon at every placed prop so an admin can SEE where
-- props are (and confirm they're loaded) without walking onto each one. The
-- prop currently being edited is highlighted orange; the rest are cyan. Only
-- props within this range of the camera are drawn (keeps it cheap + readable).
local PROP_MARK_RANGE   = 120.0
local PROP_MARK_RANGESQ = PROP_MARK_RANGE * PROP_MARK_RANGE
local function drawPropMarkers()
    local pc = GetEntityCoords(PlayerPedId())
    for _, p in ipairs(editorProps) do
        local dx, dy = pc.x - p.x, pc.y - p.y
        if (dx * dx + dy * dy) <= PROP_MARK_RANGESQ then
            local isWorking = wprop and wprop.id and p.id == wprop.id
            local r, g, b = 0, 230, 255
            if isWorking then r, g, b = 255, 165, 0 end
            local gz = p.z + (p.z_offset or 0.0)
            -- flat ground ring
            DrawMarker(1, p.x, p.y, gz - 1.0, 0, 0, 0, 0, 0, 0,
                1.6, 1.6, 1.0, r, g, b, 120, false, false, 2, false, nil, nil, false)
            -- vertical beacon (visible from a distance)
            DrawMarker(0, p.x, p.y, gz + 1.5, 0, 0, 0, 0, 0, 0,
                0.9, 0.9, 1.4, r, g, b, 150, false, true, 2, false, nil, nil, false)
        end
    end
end

-- ── Live preview marker: draws the working zone + all prop markers ──────────
local function startPreview()
    if previewThread then return end
    previewThread = true
    CreateThread(function()
        while editing do
            Wait(0)
            drawPropMarkers()
            local z = working
            if z then
                local c = ScnCfg.Markers.selected
                local gz = z.z - 1.0
                if z.shape == 'box' then
                    -- neon wireframe outline (lines, not a filled disc)
                    drawNeonBox(z)
                else
                    local d = z.radius * 2.0
                    -- flat footprint disc (ground)
                    DrawMarker(1, z.x, z.y, gz, 0, 0, 0, 0, 0, 0,
                        d, d, ScnCfg.Markers.height,
                        c.r, c.g, c.b, c.a, false, false, 2, false, nil, nil, false)
                    -- vertical cylinder wall so the boundary is visible from
                    -- INSIDE the zone (a flat disc alone is easy to miss when
                    -- you're standing in a 50m+ radius). Marker 28 = sphere-ish;
                    -- type 1 with tall height gives a translucent wall.
                    DrawMarker(1, z.x, z.y, z.z + 1.0, 0, 0, 0, 0, 0, 0,
                        d, d, 4.0,
                        c.r, c.g, c.b, 40, false, false, 2, false, nil, nil, false)
                end
            end
        end
        previewThread = false
    end)
end

-- ── Save the WORKING zone; adopt server id so next save is an UPDATE ────────
saveZone = function()
    if not working then return end
    local id = lib.callback.await('hk-scenario:zones:save', false, working)
    if id then
        working.id = id
        notify('Saved.', 'success')
    else
        notify('Save failed (not authorized?)', 'error')
    end
    return id
end

local function cloneZone(z)
    local c = {}
    for k, v in pairs(z) do c[k] = v end
    return c
end

-- ── Zone editor page (rebuilt each open) ────────────────────────────────────
buildZone = function()
    mZone:ClearItems()
    local z = working
    if not z then
        mZone:AddButton({ icon = '⚠️', label = 'No zone selected', description = 'Go back' })
        return
    end

    -- Header (info only)
    mZone:AddButton({ icon = '📍',
        label = ('%s (%s)'):format(z.label, z.id and ('#' .. z.id) or 'unsaved'),
        description = ('%s · %s · %.0f,%.0f,%.0f'):format(
            z.shape, z.enabled and 'ENABLED' or 'DISABLED', z.x, z.y, z.z) })

    -- NOTE: all edits below stage into the local `working` copy ONLY. Nothing
    -- hits the database until you press "SAVE & CLOSE" at the bottom. This is
    -- why edits are instant and predictable (no per-action round-trips).

    -- Rename (typed input)
    local nameBtn = mZone:AddButton({ icon = '🏷️', label = 'Rename',
        description = 'Current: ' .. z.label })
    nameBtn:On('select', function()
        MenuV:CloseAll(function() end)
        local out = lib.inputDialog('Rename Zone', {
            { type = 'input', label = 'Label', default = z.label, required = true, max = 64 },
        })
        if out and out[1] and out[1] ~= '' then z.label = tostring(out[1]):sub(1, 64) end
        goZone()
    end)

    -- Enable / disable (checkbox toggles, movement stays free)
    local enBox = mZone:AddCheckbox({ icon = '🔌', label = 'Zone enabled', value = z.enabled and true or false })
    enBox:On('check',   function() z.enabled = true  end)
    enBox:On('uncheck', function() z.enabled = false end)

    -- Clear-type flags
    local vBox = mZone:AddCheckbox({ icon = '🚗', label = 'Clear vehicles', value = z.clr_vehicles and true or false })
    vBox:On('check',   function() z.clr_vehicles = true  end)
    vBox:On('uncheck', function() z.clr_vehicles = false end)

    local pBox = mZone:AddCheckbox({ icon = '🚶', label = 'Clear peds (NPCs)', value = z.clr_peds and true or false })
    pBox:On('check',   function() z.clr_peds = true  end)
    pBox:On('uncheck', function() z.clr_peds = false end)

    local oBox = mZone:AddCheckbox({ icon = '📦', label = 'Clear objects/props', value = z.clr_objects and true or false })
    oBox:On('check',   function() z.clr_objects = true  end)
    oBox:On('uncheck', function() z.clr_objects = false end)

    local jBox = mZone:AddCheckbox({ icon = '💥', label = 'Clear projectiles', value = z.clr_projectiles and true or false })
    jBox:On('check',   function() z.clr_projectiles = true  end)
    jBox:On('uncheck', function() z.clr_projectiles = false end)

    -- ── Hidden path blocking (steer ambient AI away from this area) ──────────
    local brBox = mZone:AddCheckbox({ icon = '🚧', label = 'Block vehicle roads',
        value = z.blk_roads and true or false })
    brBox:On('check',   function() z.blk_roads = true  end)
    brBox:On('uncheck', function() z.blk_roads = false end)

    local bpBox = mZone:AddCheckbox({ icon = '🚷', label = 'Block ped paths',
        value = z.blk_peds and true or false })
    bpBox:On('check',   function() z.blk_peds = true  end)
    bpBox:On('uncheck', function() z.blk_peds = false end)

    local bnBox = mZone:AddCheckbox({ icon = '⛔', label = 'Block navmesh (hard, routes around)',
        value = z.blk_navmesh and true or false })
    bnBox:On('check',   function() z.blk_navmesh = true  end)
    bnBox:On('uncheck', function() z.blk_navmesh = false end)

    -- Debounce so a real ENTER on a bar (opens type-mode) is distinguished from
    -- a LEFT/RIGHT drag-tick (which, with saveOnUpdate, ALSO fires 'select'
    -- immediately after 'change'). If 'select' lands right after a 'change',
    -- it's a drag — ignore it. Otherwise it's a genuine Enter → type dialog.
    local lastBarChange = 0
    local function isDragTick() return (GetGameTimer() - lastBarChange) < 120 end

    if z.shape == 'circle' then
        -- Live radius bar: LEFT/RIGHT arrows resize (marker updates live, you can
        -- still move). ENTER on the row opens a type-exact popup.
        local rItem = mZone:AddRange({ icon = '⭕',
            label = ('Radius: %dm  (◄ ► drag · ⏎ type)'):format(math.floor(z.radius)),
            min = math.floor(ScnCfg.Zones.minRadius),
            max = math.floor(ScnCfg.Zones.maxRadius),
            value = math.floor(z.radius),
            saveOnUpdate = true })   -- REQUIRED: without it MenuV reverts the bar
        rItem:On('change', function(item, v)
            z.radius = v + 0.0
            lastBarChange = GetGameTimer()
            item.Label = ('Radius: %dm  (◄ ► drag · ⏎ type)'):format(v)
        end)
        rItem:On('select', function()
            if isDragTick() then return end   -- was an arrow tick, not Enter
            MenuV:CloseAll(function() end)
            local out = lib.inputDialog('Circle Radius', {
                { type = 'number', label = 'Radius (m)', default = math.floor(z.radius),
                  min = ScnCfg.Zones.minRadius, max = ScnCfg.Zones.maxRadius },
            })
            if out and out[1] then z.radius = math.floor(out[1]) + 0.0 end
            goZone()
        end)
    else
        -- Box bars: LEFT/RIGHT adjust the highlighted one; ENTER on any bar opens
        -- a type-all-four popup.
        local minS, maxS = math.floor(ScnCfg.Zones.minBoxSide), math.floor(ScnCfg.Zones.maxBoxSide)
        local function typeBox()
            if isDragTick() then return end
            MenuV:CloseAll(function() end)
            local out = lib.inputDialog('Box Dimensions', {
                { type = 'number', label = 'Length (X, m)', default = math.floor(z.length), min = ScnCfg.Zones.minBoxSide, max = ScnCfg.Zones.maxBoxSide },
                { type = 'number', label = 'Width (Y, m)',  default = math.floor(z.width),  min = ScnCfg.Zones.minBoxSide, max = ScnCfg.Zones.maxBoxSide },
                { type = 'number', label = 'Height (Z, m)', default = math.floor(z.height), min = ScnCfg.Zones.minBoxSide, max = ScnCfg.Zones.maxBoxSide },
                { type = 'number', label = 'Heading (deg)', default = math.floor(z.heading), min = 0, max = 360 },
            })
            if out then
                z.length  = (out[1] or z.length)  + 0.0
                z.width   = (out[2] or z.width)   + 0.0
                z.height  = (out[3] or z.height)  + 0.0
                z.heading = (out[4] or z.heading) + 0.0
            end
            goZone()
        end
        local lItem = mZone:AddRange({ icon = '↔️', label = ('Length: %dm  (◄ ► · ⏎)'):format(math.floor(z.length)),
            min = minS, max = maxS, value = math.floor(z.length), saveOnUpdate = true })
        lItem:On('change', function(item, v) z.length = v + 0.0; lastBarChange = GetGameTimer(); item.Label = ('Length: %dm  (◄ ► · ⏎)'):format(v) end)
        lItem:On('select', typeBox)
        local wItem = mZone:AddRange({ icon = '↕️', label = ('Width: %dm  (◄ ► · ⏎)'):format(math.floor(z.width)),
            min = minS, max = maxS, value = math.floor(z.width), saveOnUpdate = true })
        wItem:On('change', function(item, v) z.width = v + 0.0; lastBarChange = GetGameTimer(); item.Label = ('Width: %dm  (◄ ► · ⏎)'):format(v) end)
        wItem:On('select', typeBox)
        local hItem = mZone:AddRange({ icon = '⬆️', label = ('Height: %dm  (◄ ► · ⏎)'):format(math.floor(z.height)),
            min = minS, max = maxS, value = math.floor(z.height), saveOnUpdate = true })
        hItem:On('change', function(item, v) z.height = v + 0.0; lastBarChange = GetGameTimer(); item.Label = ('Height: %dm  (◄ ► · ⏎)'):format(v) end)
        hItem:On('select', typeBox)
        local aItem = mZone:AddRange({ icon = '🧭', label = ('Heading: %d°  (◄ ► · ⏎)'):format(math.floor(z.heading)),
            min = 0, max = 360, value = math.floor(z.heading), saveOnUpdate = true })
        aItem:On('change', function(item, v) z.heading = v + 0.0; lastBarChange = GetGameTimer(); item.Label = ('Heading: %d°  (◄ ► · ⏎)'):format(v) end)
        aItem:On('select', typeBox)
    end

    -- Clear NOW — immediate one-shot clear using the CURRENT (edited, unsaved)
    -- settings, so you can test flags/size before committing.
    local clearNowBtn = mZone:AddButton({ icon = '🧹', label = 'CLEAR NOW (this zone)',
        description = 'Run a clear pass immediately with the current flags/size' })
    clearNowBtn:On('select', function()
        if Scn_clearZoneNow then Scn_clearZoneNow(z) end
        notify('Cleared now.', 'success')
    end)

    -- Clear interval (typed input; rarely changed)
    local intBtn = mZone:AddButton({ icon = '⏱️', label = ('Interval: %dms'):format(z.interval),
        description = 'How often this zone clears while a player is near' })
    intBtn:On('select', function()
        MenuV:CloseAll(function() end)
        local out = lib.inputDialog('Clear Interval', {
            { type = 'number', label = 'Interval (ms)', default = z.interval,
              min = ScnCfg.Engine.minZoneInterval, max = 10000 },
        })
        if out and out[1] then z.interval = math.floor(out[1]) end
        goZone()
    end)

    -- Move here (stages new position into working; save with SAVE & CLOSE)
    local moveBtn = mZone:AddButton({ icon = '🎯', label = 'Move here',
        description = 'Recenter this zone on your position' })
    moveBtn:On('select', function()
        local p = playerCoords()
        z.x, z.y, z.z = p.x, p.y, p.z
        if z.shape == 'box' then z.heading = playerHeading() end
        notify('Moved here (not saved yet)', 'inform')
        goZone()
    end)

    -- Teleport to zone
    local tpBtn = mZone:AddButton({ icon = '🚀', label = 'Teleport to zone' })
    tpBtn:On('select', function()
        SetEntityCoords(PlayerPedId(), z.x, z.y, z.z, false, false, false, false)
        notify('Teleported to ' .. z.label, 'success')
    end)

    -- Delete (confirm yes/no)
    local delItem = mZone:AddConfirm({ icon = '🗑️', label = 'Delete this zone', value = 'no' })
    delItem:On('confirm', function()
        if z.id then lib.callback.await('hk-scenario:zones:delete', false, z.id) end
        notify('Deleted.', 'inform')
        goList()
    end)

    -- Discard & back (does NOT save)
    local back = mZone:AddButton({ icon = '↩️', label = 'Back (discard unsaved)' })
    back:On('select', function() goList() end)

    -- ── SAVE & CLOSE — the one commit point. Loud label since MenuV has no
    --    per-item colour; emoji + caps is the convention for emphasis. ────────
    local saveBtn = mZone:AddButton({ icon = '🔴', label = '🔴  SAVE & CLOSE  🔴',
        description = 'Write ALL changes to the database' })
    saveBtn:On('select', function()
        local id = saveZone()
        if id then goList() end   -- back to the (now refreshed) list on success
    end)
end

-- ── Zone list page ──────────────────────────────────────────────────────────
buildList = function()
    mList:ClearItems()
    if #editorZones == 0 then
        mList:AddButton({ icon = '📭', label = 'No zones yet',
            description = 'Use "Add zone" on the main menu' })
    else
        for _, z in ipairs(editorZones) do
            mList:AddButton({
                icon = z.enabled and '🟢' or '⚪',
                label = z.label,
                description = ('#%d · %s · %.0f,%.0f,%.0f'):format(z.id, z.shape, z.x, z.y, z.z),
                value = z.id,
                select = function()
                    working = cloneZone(z)   -- edit an independent copy
                    goZone()
                end,
            })
        end
    end
    local back = mList:AddButton({ icon = '↩️', label = 'Back to main' })
    back:On('select', function() goMain() end)
end

-- ── Main menu ───────────────────────────────────────────────────────────────
local function createZone(shape)
    local p = playerCoords()
    working = {
        id = nil,
        label = (shape == 'box') and 'New Box Zone' or 'New Circle Zone',
        shape = shape,
        x = p.x, y = p.y, z = p.z,
        heading = playerHeading(),
        radius = ScnCfg.Zones.defaultRadius,
        length = ScnCfg.Zones.defaultBoxSize.length,
        width  = ScnCfg.Zones.defaultBoxSize.width,
        height = ScnCfg.Zones.defaultBoxSize.height,
        interval = ScnCfg.Engine.defaultInterval,
        enabled = true,
        clr_vehicles    = ScnCfg.Zones.defaultFlags.vehicles,
        clr_peds        = ScnCfg.Zones.defaultFlags.peds,
        clr_objects     = ScnCfg.Zones.defaultFlags.objects,
        clr_projectiles = ScnCfg.Zones.defaultFlags.projectiles,
        blk_roads       = false,
        blk_peds        = false,
        blk_navmesh     = false,
    }
    saveZone()   -- persist immediately so the row + id exist
    notify('Zone created. Configure it, then SAVE & CLOSE.', 'success')
    goZone()
end

-- ── Top-level module selector ───────────────────────────────────────────────
buildMain = function()
    mMain:ClearItems()

    local clearBtn = mMain:AddButton({ icon = '🗺️', label = 'Clear Area',
        description = ('Zones that clear NPCs/vehicles and block AI paths (%d)'):format(#editorZones) })
    clearBtn:On('select', function() goClearHub() end)

    local propsBtn = mMain:AddButton({ icon = '📦', label = 'Props',
        description = ('Place, browse, and manage scenario props (%d placed)'):format(#editorProps) })
    propsBtn:On('select', function() goPropsHub() end)

    local popBtn = mMain:AddButton({ icon = '🌆', label = 'World Population',
        description = 'Ambient traffic / NPC density (server-wide, live)' })
    popBtn:On('select', function() goPop() end)

    local trafBtn = mMain:AddButton({ icon = '🚦', label = 'Traffic Realism',
        description = 'NPC driving speed/aggression + highway fast-spawner (NO HESI)' })
    trafBtn:On('select', function() goTraffic() end)

    -- (future modules add their section button here)

    local exitBtn = mMain:AddButton({ icon = '🚪', label = 'Exit' })
    exitBtn:On('select', function() CloseEditor() end)
end

-- ── Clear Area hub ───────────────────────────────────────────────────────────
buildClearHub = function()
    mClear:ClearItems()

    local addC = mClear:AddButton({ icon = '⭕', label = 'Add circle zone (here)',
        description = 'Create a radius zone centered on you' })
    addC:On('select', function() createZone('circle') end)

    local addB = mClear:AddButton({ icon = '⬛', label = 'Add box zone (here)',
        description = 'Oriented box aligned to your facing. Best for rectangular MLOs' })
    addB:On('select', function() createZone('box') end)

    local listBtn = mClear:AddButton({ icon = '📋', label = ('Manage zones (%d)'):format(#editorZones),
        description = 'Edit, toggle, resize, delete existing zones' })
    listBtn:On('select', function() goList() end)

    -- Clear ALL enabled zones right now (protects parked cars + placed props).
    local clearAllBtn = mClear:AddButton({ icon = '🧹', label = '🧹  CLEAR ALL ZONES NOW',
        description = 'Run every enabled zone once. Skips parked cars & scenario props.' })
    clearAllBtn:On('select', function()
        local n = Scn_clearAllNow and Scn_clearAllNow() or 0
        notify(('Cleared %d zone(s).'):format(n), 'success')
    end)

    local back = mClear:AddButton({ icon = '↩️', label = 'Back' })
    back:On('select', function() goMain() end)
end

-- ── Props hub ────────────────────────────────────────────────────────────────
buildPropsHub = function()
    mProps:ClearItems()

    local catBtn = mProps:AddButton({ icon = '🗂️', label = 'Prop catalog (browse categories)',
        description = 'Pick from curated categories, with search + live preview' })
    catBtn:On('select', function() goCats() end)

    local searchBtn = mProps:AddButton({ icon = '🔍', label = 'Search all props',
        description = 'Search the whole catalog by name or label' })
    searchBtn:On('select', function()
        MenuV:CloseAll(function() end)
        local o = lib.inputDialog('Search props', { { type = 'input', label = 'Search term', placeholder = 'cone, barrier, light...' } })
        goSearch(o and o[1] or '')
    end)

    local typeBtn = mProps:AddButton({ icon = '⌨️', label = 'Add prop (type exact model)',
        description = 'Spawn any model by name, then edit it' })
    typeBtn:On('select', function() createProp() end)

    local plistBtn = mProps:AddButton({ icon = '📋', label = ('Manage placed props (%d)'):format(#editorProps),
        description = 'Edit, move, retexture, set interaction, delete' })
    plistBtn:On('select', function() goPList() end)

    local back = mProps:AddButton({ icon = '↩️', label = 'Back' })
    back:On('select', function() goMain() end)
end

-- ═══════════════════════════════════════════════════════════════════════════
-- PROPS
-- ═══════════════════════════════════════════════════════════════════════════
local function clonePropRow(p)
    local c = {} ; for k, v in pairs(p) do c[k] = v end ; return c
end

saveProp = function()
    if not wprop then return end
    local id = lib.callback.await('hk-scenario:props:save', false, wprop)
    if id then wprop.id = id; notify('Prop saved.', 'success')
    else notify('Prop save failed.', 'error') end
    return id
end

-- ── Ghost preview: spawn a temp, non-solid prop in front of the player so you
--    SEE a highlighted catalog model before adding it. Cleared on leave. ──────
local ghostEntity = nil
local ghostModel = nil
local function ghostCoords()
    local ped = PlayerPedId()
    local fwd = GetEntityForwardVector(ped)
    local c = GetEntityCoords(ped)
    return c.x + fwd.x * 2.5, c.y + fwd.y * 2.5, c.z - 0.8, GetEntityHeading(ped)
end
ghostStop = function()
    if ghostEntity and DoesEntityExist(ghostEntity) then DeleteObject(ghostEntity) end
    ghostEntity = nil; ghostModel = nil
end
local ghostThread = false
ghostStart = function(model)
    if ghostModel == model and ghostEntity and DoesEntityExist(ghostEntity) then return end
    ghostStop()
    local hash = joaat(model)
    if not IsModelValid(hash) then return end
    RequestModel(hash)
    local tries = 0
    while not HasModelLoaded(hash) and tries < 60 do Wait(10); tries = tries + 1 end
    if not HasModelLoaded(hash) then return end
    local x, y, z, h = ghostCoords()
    ghostEntity = CreateObject(hash, x, y, z, false, false, false)
    SetEntityHeading(ghostEntity, h)
    FreezeEntityPosition(ghostEntity, true)
    SetEntityAlpha(ghostEntity, 180, false)          -- translucent = "ghost"
    SetEntityCollision(ghostEntity, false, false)    -- non-solid preview
    SetModelAsNoLongerNeeded(hash)
    ghostModel = model
    -- keep it floating in front of the player + slowly spin so you see all sides.
    -- Self-cleans if the browser menu is no longer open (e.g. player pressed ESC).
    if not ghostThread then
        ghostThread = true
        CreateThread(function()
            local spin = 0.0
            while ghostEntity and DoesEntityExist(ghostEntity) do
                local cur = MenuV.CurrentMenu
                local inBrowser = cur and (cur == mCats or cur == mCat or cur == mSearch)
                if not inBrowser then break end   -- left the catalog -> drop ghost
                local x2, y2, z2 = ghostCoords()
                spin = (spin + 1.0) % 360.0
                SetEntityCoordsNoOffset(ghostEntity, x2, y2, z2, false, false, false)
                SetEntityHeading(ghostEntity, spin)
                Wait(30)
            end
            ghostThread = false
            ghostStop()
        end)
    end
end

-- spawn a new placed prop directly from a catalog model (bypasses type dialog).
spawnFromModel = function(model, label)
    ghostStop()
    local ped = PlayerPedId()
    local fwd = GetEntityForwardVector(ped)
    local c = GetEntityCoords(ped)
    wprop = {
        id = nil, label = label or model, model = model,
        x = c.x + fwd.x * 2.0, y = c.y + fwd.y * 2.0, z = c.z - 1.0,
        heading = GetEntityHeading(ped), z_offset = 0.0, frozen = true,
        trigger = 'none', action = 'none', action_data = '',
        interact_label = 'Interact', interact_icon = 'fas fa-hand-pointer',
        interact_dist = ScnCfg.Props.defaultInteractDist,
    }
    saveProp()
    notify(('Placed %s. Configure it, then SAVE & CLOSE.'):format(label or model), 'success')
    goProp()
end

-- create a prop in front of the player from a typed model, then edit it.
function createProp()
    MenuV:CloseAll(function() end)
    local out = lib.inputDialog('Add Prop', {
        { type = 'input', label = 'Model name', placeholder = 'prop_barrier_work05', required = true },
    })
    if not (out and out[1]) then goPropsHub(); return end
    local model = tostring(out[1]):gsub('%s', '')
    local ped = PlayerPedId()
    local fwd = GetEntityForwardVector(ped)
    local c = GetEntityCoords(ped)
    wprop = {
        id = nil, label = model, model = model,
        x = c.x + fwd.x * 2.0, y = c.y + fwd.y * 2.0, z = c.z - 1.0,
        heading = GetEntityHeading(ped), z_offset = 0.0, frozen = true,
        trigger = 'none', action = 'none', action_data = '',
        interact_label = 'Interact', interact_icon = 'fas fa-hand-pointer',
        interact_dist = ScnCfg.Props.defaultInteractDist,
    }
    saveProp()   -- insert so it spawns + gets an id
    notify('Prop added. Configure it, then SAVE & CLOSE.', 'success')
    goProp()
end

-- helper: the live spawned entity for the working prop (if any)
local function wpropEntity()
    if not wprop or not wprop.id then return nil end
    return exports['hk-scenario']:GetPropEntity(wprop.id)
end

-- push live edits (heading/pos/z) onto the spawned entity so preview is instant
local function refreshPropEntity()
    local e = wpropEntity()
    if e and DoesEntityExist(e) then
        SetEntityCoordsNoOffset(e, wprop.x, wprop.y, wprop.z + (wprop.z_offset or 0.0), false, false, false)
        SetEntityHeading(e, wprop.heading or 0.0)
    end
end

-- ── Free-move mode ──────────────────────────────────────────────────────────
-- MenuV only fires a range 'change' on a fresh key PRESS (no hold-repeat), so
-- for smooth hold-to-move we take over input directly: hide the menu, run a
-- tight loop reading the arrow keys every frame with hold + acceleration, live
-- preview on the spawned entity. ENTER confirms, BACKSPACE cancels.
local freeMoveActive = false
local function freeMove()
    if freeMoveActive or not wprop then return end
    freeMoveActive = true
    local p = wprop
    MenuV:CloseAll(function() end)

    -- snapshot for cancel
    local orig = { x = p.x, y = p.y, z = p.z, z_offset = p.z_offset or 0.0, heading = p.heading }

    lib.showTextUI(
        'Arrows: X/Y  ·  Space/L-Ctrl: up/down  ·  [ / ]: rotate  ·  tap = 0.02m  ·  hold = slide  ·  ENTER save  ·  BACKSPACE cancel',
        { position = 'top-center', icon = 'up-down-left-right' })

    CreateThread(function()
        local TAP = 0.02          -- exact single-tap step (point-click fine move)
        local held = 0.0
        -- control ids
        local C = {
            up=172, down=173, left=174, right=175,   -- arrows = X/Y (camera-relative)
            zup=22, zdown=36,                         -- Space = up, Left-Ctrl = down
            accept=191, cancel=194, rotL=39, rotR=40, -- Enter / Backspace / [ / ]
        }
        while freeMoveActive do
            Wait(0)
            for _, c in pairs(C) do DisableControlAction(0, c, true) end

            -- hold ramp: SLOW. tap moves TAP (0.02m); holding eases from ~0.01 up
            -- to a gentle cap so it slides, not teleports.
            local moving = IsDisabledControlPressed(0, C.up) or IsDisabledControlPressed(0, C.down)
                or IsDisabledControlPressed(0, C.left) or IsDisabledControlPressed(0, C.right)
                or IsDisabledControlPressed(0, C.zup) or IsDisabledControlPressed(0, C.zdown)
            if moving then held = math.min(held + 0.02, 1.5) else held = 0.0 end
            local slide = 0.01 + (held * held) * 0.03    -- max ~0.077m/tick (~4.5 m/s)

            -- camera-relative axes so "up arrow" pushes away from you
            local camH = GetGameplayCamRelativeHeading() + GetEntityHeading(PlayerPedId())
            local hr = math.rad(camH)
            local fx, fy = -math.sin(hr), math.cos(hr)
            local rx, ry =  math.cos(hr), math.sin(hr)

            -- per-axis: a TAP moves exactly TAP; a HOLD slides at `slide`.
            local function amt(ctrl)
                if IsDisabledControlJustPressed(0, ctrl) then return TAP end
                if IsDisabledControlPressed(0, ctrl)     then return slide end
                return 0.0
            end
            local mUp, mDown  = amt(C.up),  amt(C.down)
            local mRight, mLeft = amt(C.right), amt(C.left)
            local mZu, mZd    = amt(C.zup), amt(C.zdown)

            if mUp   > 0 then p.x = p.x + fx*mUp;   p.y = p.y + fy*mUp   end
            if mDown > 0 then p.x = p.x - fx*mDown; p.y = p.y - fy*mDown end
            if mRight> 0 then p.x = p.x + rx*mRight;p.y = p.y + ry*mRight end
            if mLeft > 0 then p.x = p.x - rx*mLeft; p.y = p.y - ry*mLeft end
            if mZu   > 0 then p.z_offset = (p.z_offset or 0.0) + mZu end
            if mZd   > 0 then p.z_offset = (p.z_offset or 0.0) - mZd end
            if IsDisabledControlPressed(0, C.rotL) then p.heading = (p.heading + 1.0) % 360.0 end
            if IsDisabledControlPressed(0, C.rotR) then p.heading = (p.heading - 1.0) % 360.0 end

            refreshPropEntity()

            if IsDisabledControlJustPressed(0, C.accept) then
                freeMoveActive = false; lib.hideTextUI(); goProp(); return
            elseif IsDisabledControlJustPressed(0, C.cancel) then
                freeMoveActive = false; lib.hideTextUI()
                p.x, p.y, p.z, p.z_offset, p.heading = orig.x, orig.y, orig.z, orig.z_offset, orig.heading
                refreshPropEntity(); notify('Move cancelled', 'inform'); goProp(); return
            end
        end
    end)
end

buildProp = function()
    mProp:ClearItems()
    local p = wprop
    if not p then
        mProp:AddButton({ icon = '⚠️', label = 'No prop selected' })
        return
    end
    local trigLbl = { none='off', target='qb-target (E)', zonekey='in-range + key', zoneauto='auto in-range' }
    local actLbl  = { none='nothing', command='command', client='client event', server='server event' }

    mProp:AddButton({ icon = '📦', label = ('%s (%s)'):format(p.label, p.id and ('#'..p.id) or 'unsaved'),
        description = ('model: %s'):format(p.model) })

    -- Rename
    local nameB = mProp:AddButton({ icon = '🏷️', label = 'Rename' })
    nameB:On('select', function()
        MenuV:CloseAll(function() end)
        local o = lib.inputDialog('Rename Prop', { { type='input', label='Label', default=p.label, required=true, max=64 } })
        if o and o[1] then p.label = tostring(o[1]):sub(1,64) end
        goProp()
    end)

    -- Change model
    local modelB = mProp:AddButton({ icon = '🧱', label = 'Change model', description = 'Current: '..p.model })
    modelB:On('select', function()
        MenuV:CloseAll(function() end)
        local o = lib.inputDialog('Model', { { type='input', label='Model name', default=p.model, required=true } })
        if o and o[1] then
            p.model = tostring(o[1]):gsub('%s','')
            saveProp()   -- persist + respawn with new model on next sync
        end
        goProp()
    end)

    -- Heading (live bar) — 5° steps
    local hItem = mProp:AddRange({ icon='🧭', label=('Heading: %d°  (◄ ►)'):format(math.floor(p.heading)),
        min=0, max=360, value=math.floor(p.heading), saveOnUpdate=true })
    hItem:On('change', function(item, v) p.heading = v + 0.0; item.Label = ('Heading: %d°  (◄ ►)'):format(v); refreshPropEntity() end)

    -- Free-move mode: tap arrows for 0.02m, hold to slide slowly.
    local fmB = mProp:AddButton({ icon='🕹️', label='FREE-MOVE (tap or hold)',
        description='Hide menu & move. Arrows=X/Y, Space/Ctrl=up/down, [ ]=rotate. Tap=0.02m, hold=slide. ENTER save.' })
    fmB:On('select', function() freeMove() end)

    -- ── Fine move (per-press nudge) ──────────────────────────────────────────
    -- MenuV only fires 'change' on a fresh key PRESS (no hold-repeat), so these
    -- bars move one step per press. For hold-to-slide use FREE-MOVE above.
    -- Nudge is UNLIMITED — no clamp on x/y/z.
    p._step = p._step or 0.01     -- fine default
    local stepB = mProp:AddButton({ icon='📐', label=('Move step: %.2fm  (⏎ cycle)'):format(p._step),
        description='0.01 / 0.05 / 0.1 / 0.25 / 0.5 / 1 / 5 / 10 m' })
    stepB:On('select', function()
        local steps = { 0.01, 0.05, 0.1, 0.25, 0.5, 1.0, 5.0, 10.0 }
        local i = 1; for k,s in ipairs(steps) do if math.abs(s - p._step) < 0.0001 then i = k end end
        p._step = steps[(i % #steps) + 1]
        goProp()
    end)

    -- Nudge helper: a range with a HUGE span so it never hits a boundary. A
    -- single press moves one step (MenuV 'change'); HOLDING the key auto-repeats
    -- via the background heldNudge thread, which is armed on 'enter' (row
    -- highlighted) and disarmed on 'leave'.
    local BIG = 1000000
    local function nudgeBar(icon, axisLabel, apply)
        local lastV = 0
        local it = mProp:AddRange({ icon=icon, label=('%s  (◄ ► hold)  step %.2fm'):format(axisLabel, p._step),
            min=-BIG, max=BIG, value=0, saveOnUpdate=true })
        -- single-press path (MenuV change)
        it:On('change', function(item, v)
            local delta = v - lastV
            lastV = v
            if delta ~= 0 then
                apply(delta * p._step)
                refreshPropEntity()
            end
        end)
        -- hold-to-repeat: arm the bg thread while this row is highlighted.
        it:On('enter', function()
            heldNudge = {
                apply   = function(mult) apply(mult * p._step) end,
                refresh = function() refreshPropEntity() end,
            }
        end)
        it:On('leave', function() heldNudge = nil end)
    end
    nudgeBar('↔️', 'X (E/W)',    function(d) p.x = p.x + d end)
    nudgeBar('↕️', 'Y (N/S)',    function(d) p.y = p.y + d end)
    nudgeBar('⬆️', 'Z (up/down)',function(d) p.z_offset = (p.z_offset or 0.0) + d end)

    local zLbl = mProp:AddButton({ icon='📏',
        label=('Height offset: %.2fm'):format(p.z_offset or 0.0),
        description='Use the Z nudge bar above; ⏎ to type exact' })
    zLbl:On('select', function()
        MenuV:CloseAll(function() end)
        local o = lib.inputDialog('Height offset', { { type='number', label='Z offset (m)', default=p.z_offset or 0.0 } })
        if o and o[1] then p.z_offset = tonumber(o[1]) or p.z_offset; refreshPropEntity() end
        goProp()
    end)

    -- Move here
    local moveB = mProp:AddButton({ icon='🎯', label='Move here (my position)' })
    moveB:On('select', function()
        local c = GetEntityCoords(PlayerPedId())
        p.x, p.y, p.z = c.x, c.y, c.z - 1.0
        p.z_offset = 0.0
        p.heading = GetEntityHeading(PlayerPedId())
        refreshPropEntity(); notify('Moved here (not saved yet)', 'inform'); goProp()
    end)

    -- Teleport to prop
    local tpB = mProp:AddButton({ icon='🚀', label='Teleport to prop' })
    tpB:On('select', function()
        SetEntityCoords(PlayerPedId(), p.x, p.y, (p.z + (p.z_offset or 0.0)) + 1.0, false, false, false, false)
        notify('Teleported to '..p.label, 'success')
    end)

    -- Frozen toggle
    local frB = mProp:AddCheckbox({ icon='🧊', label='Frozen in place', value = p.frozen and true or false })
    frB:On('check',   function() p.frozen = true end)
    frB:On('uncheck', function() p.frozen = false end)

    -- ── Interaction ─────────────────────────────────────────────────────────
    mProp:AddButton({ icon='⚙️', label='— INTERACTION —', description='How players engage this prop' })

    -- Trigger cycle
    local trB = mProp:AddButton({ icon='🖲️', label=('Trigger: %s'):format(trigLbl[p.trigger] or p.trigger),
        description='none / qb-target / in-range+key / auto' })
    trB:On('select', function()
        local order = { 'none','target','zonekey','zoneauto' }
        local i = 1; for k,v in ipairs(order) do if v==p.trigger then i=k end end
        p.trigger = order[(i % #order) + 1]
        goProp()
    end)

    -- Action cycle
    local acB = mProp:AddButton({ icon='⚡', label=('Action: %s'):format(actLbl[p.action] or p.action),
        description='nothing / command / client event / server event' })
    acB:On('select', function()
        local order = { 'none','command','client','server' }
        local i = 1; for k,v in ipairs(order) do if v==p.action then i=k end end
        p.action = order[(i % #order) + 1]
        goProp()
    end)

    -- Action data (the command/event string)
    if p.action ~= 'none' then
        local adB = mProp:AddButton({ icon='⌨️', label='Set action text',
            description = p.action_data ~= '' and p.action_data or '(empty)' })
        adB:On('select', function()
            MenuV:CloseAll(function() end)
            local ph = p.action=='command' and '/wanted 5  (no slash)' or 'event:name'
            local o = lib.inputDialog('Action text', { { type='input', label=(p.action..' to run'), default=p.action_data, placeholder=ph } })
            if o then p.action_data = tostring(o[1] or '') end
            goProp()
        end)
        -- interact label + distance (only meaningful with a trigger)
        if p.trigger ~= 'none' then
            local ilB = mProp:AddButton({ icon='🔤', label='Interact label', description=p.interact_label })
            ilB:On('select', function()
                MenuV:CloseAll(function() end)
                local o = lib.inputDialog('Interact label', { { type='input', label='Shown to player', default=p.interact_label } })
                if o and o[1] then p.interact_label = tostring(o[1]):sub(1,64) end
                goProp()
            end)
            local idItem = mProp:AddRange({ icon='📏', label=('Interact dist: %dm  (◄ ►)'):format(math.floor(p.interact_dist)),
                min=1, max=15, value=math.floor(p.interact_dist), saveOnUpdate=true })
            idItem:On('change', function(item, v) p.interact_dist = v + 0.0; item.Label = ('Interact dist: %dm  (◄ ►)'):format(v) end)
        end
        -- test the action now
        local testB = mProp:AddButton({ icon='🧪', label='Test action now' })
        testB:On('select', function() Scn_runPropAction(p) end)
    end

    -- Delete
    local delB = mProp:AddConfirm({ icon='🗑️', label='Delete this prop', value='no' })
    delB:On('confirm', function()
        if p.id then lib.callback.await('hk-scenario:props:delete', false, p.id) end
        notify('Prop deleted.', 'inform'); goPList()
    end)

    -- Back (discard)
    local back = mProp:AddButton({ icon='↩️', label='Back (discard unsaved)' })
    back:On('select', function() goPList() end)

    -- SAVE & CLOSE
    local saveB = mProp:AddButton({ icon='🔴', label='🔴  SAVE & CLOSE  🔴', description='Write ALL changes to the database' })
    saveB:On('select', function() local id = saveProp(); if id then goPList() end end)
end

buildPList = function()
    mPList:ClearItems()
    if #editorProps == 0 then
        mPList:AddButton({ icon='📭', label='No props yet', description='Use "Add prop" on the main menu' })
    else
        for _, p in ipairs(editorProps) do
            mPList:AddButton({
                icon = (p.trigger ~= 'none') and '⚡' or '📦',
                label = p.label,
                description = ('#%d · %s · %.0f,%.0f,%.0f'):format(p.id, p.model, p.x, p.y, p.z),
                value = p.id,
                select = function() wprop = clonePropRow(p); goProp() end,
            })
        end
    end
    local back = mPList:AddButton({ icon='↩️', label='Back' })
    back:On('select', function() goPropsHub() end)
end

-- ── Catalog: category list ───────────────────────────────────────────────────
buildCats = function()
    mCats:ClearItems()
    for idx, cat in ipairs(ScnCatalog) do
        local b = mCats:AddButton({
            icon = cat.icon or '📦',
            label = cat.category,
            description = ('%d props'):format(#cat.props),
            value = idx,
            select = function() goCat(idx) end,
        })
    end
    local back = mCats:AddButton({ icon='↩️', label='Back' })
    back:On('select', function() ghostStop(); goPropsHub() end)
end

-- shared helper: add a list of {model,label} entries as buttons that ghost-
-- preview on highlight and place on select.
local function addPropButtons(menu, entries)
    for _, e in ipairs(entries) do
        local b = menu:AddButton({
            icon = '📦', label = e.label or e.model,
            description = e.model,
            select = function() spawnFromModel(e.model, e.label) end,
        })
        -- live ghost preview when this row is highlighted
        b:On('enter', function() ghostStart(e.model) end)
    end
end

-- ── Catalog: one category (with per-category search) ────────────────────────
buildCat = function(catIdx)
    mCat:ClearItems()
    local cat = ScnCatalog[catIdx]
    if not cat then goCats(); return end

    local searchBtn = mCat:AddButton({ icon='🔍', label='Search in this category' })
    searchBtn:On('select', function()
        MenuV:CloseAll(function() end)
        local o = lib.inputDialog('Search: '..cat.category, { { type='input', label='Search term' } })
        local term = (o and o[1] or ''):lower()
        mCat:ClearItems()
        mCat:AddButton({ icon='🔎', label=('Results for "%s"'):format(term) })
        local hits = {}
        for _, e in ipairs(cat.props) do
            if term == '' or (e.label or ''):lower():find(term, 1, true) or e.model:lower():find(term, 1, true) then
                hits[#hits+1] = e
            end
        end
        addPropButtons(mCat, hits)
        local back = mCat:AddButton({ icon='↩️', label='Back to category' })
        back:On('select', function() goCat(catIdx) end)
        MenuV:OpenMenu(mCat)
    end)

    addPropButtons(mCat, cat.props)

    local back = mCat:AddButton({ icon='↩️', label='Back to categories' })
    back:On('select', function() ghostStop(); goCats() end)
end

-- ── Catalog: global search across all categories ────────────────────────────
buildSearch = function(term)
    mSearch:ClearItems()
    term = (term or ''):lower()
    mSearch:AddButton({ icon='🔎', label=('Results for "%s"'):format(term ~= '' and term or 'all') })
    local hits = {}
    for _, cat in ipairs(ScnCatalog) do
        for _, e in ipairs(cat.props) do
            if term == '' or (e.label or ''):lower():find(term, 1, true) or e.model:lower():find(term, 1, true) then
                hits[#hits+1] = e
            end
        end
    end
    if #hits == 0 then
        mSearch:AddButton({ icon='🚫', label='No matches', description='Try a different term, or use "type exact model"' })
    else
        addPropButtons(mSearch, hits)
    end
    local back = mSearch:AddButton({ icon='↩️', label='Back' })
    back:On('select', function() ghostStop(); goPropsHub() end)
end

-- ═══════════════════════════════════════════════════════════════════════════
-- WORLD POPULATION (server-wide ambient density)
-- ═══════════════════════════════════════════════════════════════════════════
-- Working copy of the density multipliers, edited live then saved. Multipliers
-- are 0.00–5.00×; MenuV ranges are integer-only, so each bar is an integer
-- PERCENT (0–500) and we show it as a ×N.NN. 100% = 1.00× = game default.
local wpop = nil

buildPop = function()
    mPop:ClearItems()
    -- seed the working copy from the server's current values (or defaults).
    if not wpop then
        local cur = lib.callback.await('hk-scenario:pop:get', false)
        cur = cur or { vehicle = 1.0, parked = 1.0, peds = 1.0, scenario = 1.0 }
        wpop = {
            vehicle  = cur.vehicle  or 1.0,
            parked   = cur.parked   or 1.0,
            peds     = cur.peds     or 1.0,
            scenario = cur.scenario or 1.0,
        }
    end

    mPop:AddButton({ icon = '🌆', label = 'Ambient density',
        description = '1.00× = default · 0 = empty · applies to everyone, live' })

    -- one slider per multiplier (integer percent 0..500 => 0.00..5.00x)
    local function densBar(icon, label, key)
        local pct = math.floor((wpop[key] or 1.0) * 100 + 0.5)
        local it = mPop:AddRange({ icon = icon,
            label = ('%s: %.2fx  (◄ ►)'):format(label, wpop[key] or 1.0),
            min = 0, max = 500, value = pct, saveOnUpdate = true })
        it:On('change', function(item, v)
            wpop[key] = v / 100.0
            item.Label = ('%s: %.2fx  (◄ ►)'):format(label, wpop[key])
        end)
    end
    densBar('🚙', 'Vehicles',  'vehicle')
    densBar('🅿️', 'Parked',    'parked')
    densBar('🚶', 'Peds',      'peds')
    densBar('🎭', 'Scenarios', 'scenario')

    -- quick presets
    local presetB = mPop:AddButton({ icon = '🎚️', label = 'Preset',
        description = 'Cycle: Empty / Quiet / Default / Busy / Packed' })
    presetB:On('select', function()
        local presets = {
            { n='Empty',   v=0.0 }, { n='Quiet',  v=0.4 },
            { n='Default', v=1.0 }, { n='Busy',   v=1.6 }, { n='Packed', v=2.5 },
        }
        -- pick the next preset after whatever `vehicle` currently matches
        local i = 3
        for k, pr in ipairs(presets) do if math.abs(pr.v - (wpop.vehicle or 1.0)) < 0.001 then i = k end end
        local pick = presets[(i % #presets) + 1]
        wpop.vehicle, wpop.parked, wpop.peds, wpop.scenario = pick.v, pick.v, pick.v, pick.v
        notify('Preset: ' .. pick.n, 'inform')
        goPop()
    end)

    -- APPLY (save + broadcast to everyone)
    local applyB = mPop:AddButton({ icon = '💾', label = '💾  APPLY TO EVERYONE',
        description = 'Save + push these multipliers to all players now' })
    applyB:On('select', function()
        local ok = lib.callback.await('hk-scenario:pop:save', false, wpop)
        notify(ok and 'Population applied.' or 'Apply failed (not authorized?)', ok and 'success' or 'error')
    end)

    -- RESET override (hand back to game / qb-smallresources defaults)
    local clearB = mPop:AddConfirm({ icon = '♻️', label = 'Clear override (back to defaults)', value = 'no' })
    clearB:On('confirm', function()
        local ok = lib.callback.await('hk-scenario:pop:clear', false)
        if ok then wpop = nil; notify('Override cleared.', 'inform') end
        goPop()
    end)

    local back = mPop:AddButton({ icon = '↩️', label = 'Back' })
    back:On('select', function() wpop = nil; goMain() end)
end

-- ── Traffic Realism hub (NO HESI / Wangan) ──────────────────────────────────
-- Live, server-wide. Working copy `wtraf`, saved via traffic:save (broadcast).
local wtraf = nil
local TRAF_PRESETS = { 'Calm', 'Normal', 'Aggressive', 'Wangan' }

buildTraffic = function()
    mTraffic:ClearItems()
    if not wtraf then
        local cur = lib.callback.await('hk-scenario:traffic:get', false)
        cur = cur or {}
        wtraf = {
            enabled     = cur.enabled and true or false,
            preset      = cur.preset or 'Normal',
            spawnerOn   = cur.spawnerOn and true or false,
            intensity   = tonumber(cur.intensity) or 1.0,
            addonChance = tonumber(cur.addonChance) or 0.35,
        }
    end

    mTraffic:AddButton({ icon = '🚦', label = 'Traffic realism',
        description = 'Faster/aggressive NPCs + optional highway fast-spawner. Applies to everyone, live.' })

    -- Master enable
    local enBtn = mTraffic:AddButton({ icon = wtraf.enabled and '🟢' or '⚫',
        label = ('Master: %s'):format(wtraf.enabled and 'ON' or 'OFF'),
        description = 'Turn the whole traffic-realism system on/off' })
    enBtn:On('select', function() wtraf.enabled = not wtraf.enabled; goTraffic() end)

    -- NPC behaviour preset cycle
    local pBtn = mTraffic:AddButton({ icon = '🎚️',
        label = ('NPC preset: %s'):format(wtraf.preset),
        description = 'Calm / Normal / Aggressive / Wangan (speed + aggression)' })
    pBtn:On('select', function()
        local i = 2
        for k, n in ipairs(TRAF_PRESETS) do if n == wtraf.preset then i = k end end
        wtraf.preset = TRAF_PRESETS[(i % #TRAF_PRESETS) + 1]
        goTraffic()
    end)

    -- Highway spawner toggle
    local spBtn = mTraffic:AddButton({ icon = wtraf.spawnerOn and '🛣️' or '🚧',
        label = ('Highway spawner: %s'):format(wtraf.spawnerOn and 'ON' or 'OFF'),
        description = 'Stream extra fast cars while driving on highways (chunk-gated)' })
    spBtn:On('select', function() wtraf.spawnerOn = not wtraf.spawnerOn; goTraffic() end)

    -- Spawner intensity (25%..200% of the max-alive cap)
    local intPct = math.floor((wtraf.intensity or 1.0) * 100 + 0.5)
    local intBar = mTraffic:AddRange({ icon = '📈',
        label = ('Spawner intensity: %d%%  (◄ ►)'):format(intPct),
        min = 25, max = 200, value = intPct, saveOnUpdate = true })
    intBar:On('change', function(item, v)
        wtraf.intensity = v / 100.0
        item.Label = ('Spawner intensity: %d%%  (◄ ►)'):format(v)
    end)

    -- Addon car rate (0..70% — how often a spawned highway car is an hkcarpack addon)
    local acPct = math.floor((wtraf.addonChance or 0.35) * 100 + 0.5)
    local acBar = mTraffic:AddRange({ icon = '🏎️',
        label = ('Addon car rate: %d%%  (◄ ►)'):format(acPct),
        min = 0, max = 70, value = acPct, saveOnUpdate = true })
    acBar:On('change', function(item, v)
        wtraf.addonChance = v / 100.0
        item.Label = ('Addon car rate: %d%%  (◄ ►)'):format(v)
    end)

    -- APPLY (save + broadcast)
    local applyB = mTraffic:AddButton({ icon = '💾', label = '💾  APPLY TO EVERYONE',
        description = 'Save + push these traffic settings to all players now' })
    applyB:On('select', function()
        local ok = lib.callback.await('hk-scenario:traffic:save', false, wtraf)
        notify(ok and 'Traffic settings applied.' or 'Apply failed (not authorized?)',
            ok and 'success' or 'error')
    end)

    -- RESET to defaults (disables the system everywhere)
    local clearB = mTraffic:AddConfirm({ icon = '♻️',
        label = 'Reset to defaults (off)', value = 'no' })
    clearB:On('confirm', function()
        local ok = lib.callback.await('hk-scenario:traffic:clear', false)
        if ok then wtraf = nil; notify('Traffic settings reset.', 'inform') end
        goTraffic()
    end)

    local back = mTraffic:AddButton({ icon = '↩️', label = 'Back' })
    back:On('select', function() wtraf = nil; goMain() end)
end

-- ── Entry / exit ────────────────────────────────────────────────────────────
function OpenEditor()
    if editing then
        if not MenuV.CurrentMenu then buildMain(); MenuV:OpenMenu(mMain) end
        return
    end
    editing = true
    working = nil
    buildMain()
    startPreview()
    MenuV:OpenMenu(mMain)

    -- Press M to reopen the main menu after moving around (only if closed).
    CreateThread(function()
        while editing do
            Wait(0)
            if IsControlJustReleased(0, 244) and not MenuV.CurrentMenu then  -- M
                buildMain(); MenuV:OpenMenu(mMain)
            end
        end
    end)
end

function CloseEditor()
    if not editing then return end
    editing = false
    working = nil
    wprop = nil
    wpop = nil
    wtraf = nil
    freeMoveActive = false
    heldNudge = nil
    if ghostStop then ghostStop() end
    lib.hideTextUI()
    MenuV:CloseAll(function() end)
    notify('Editor closed', 'inform')
end

-- ── Command / entry point ───────────────────────────────────────────────────
local function openScenarioCmd()
    -- Make sure txAdmin auth is fresh before the permission check, so a txAdmin
    -- admin who authed before this resource loaded is still recognised. The
    -- server populates its txAdmins set from the resulting adminAuth event.
    if GetResourceState('monitor') == 'started' then
        TriggerServerEvent('txsv:checkIfAdmin')
        Wait(250)   -- let the auth round-trip land before we check
    end

    local allowed = lib.callback.await('hk-scenario:isAllowed', false)
    if not allowed then
        notify('You are not authorized to use the scenario editor.', 'error')
        return
    end
    TriggerServerEvent('hk-scenario:zones:requestSync')
    TriggerServerEvent('hk-scenario:props:requestSync')
    Wait(150)
    OpenEditor()
end

RegisterCommand(ScnCfg.Command, openScenarioCmd, false)
-- aliases (all open the same editor)
for _, alias in ipairs(ScnCfg.CommandAliases or {}) do
    if alias ~= ScnCfg.Command then RegisterCommand(alias, openScenarioCmd, false) end
end

-- Admin "Edit prop" target handle (from client/props.lua) opens that prop
-- directly in the editor.
RegisterNetEvent('hk-scenario:editProp', function(propId)
    local allowed = lib.callback.await('hk-scenario:isAllowed', false)
    if not allowed then return end
    -- make sure we have a fresh list, then find + edit the prop
    TriggerServerEvent('hk-scenario:props:requestSync')
    Wait(150)
    local target
    for _, p in ipairs(editorProps) do if p.id == propId then target = p end end
    if not target then notify('Prop not found', 'error'); return end
    if not editing then editing = true; startPreview() end
    wprop = {} ; for k, v in pairs(target) do wprop[k] = v end
    goProp()
end)
