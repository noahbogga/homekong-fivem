-- hk-race :: client/editor.lua
-- MenuV arrow-key editor, GTA-Online-creator style. Built to the exact working
-- pattern of qb-adminmenu on this server:
--   * every menu created ONCE at file scope with a unique namespace,
--   * dynamic lists rebuilt with ClearItems() + AddButton() then OpenMenu(that menu),
--   * inline `select = function(btn) ... end` handlers, read btn.Value,
--   * MenuV owns its own NUI/focus — we never SetNuiFocus around it.
--
-- Workflow: drive (or noclip) to a spot, arrow to "Add Checkpoint", press Enter.
-- The menu stays open. Checkpoint list: browse buttons, select one for actions
-- (delete / teleport to / move to my pos / insert after).

local editing = false
local draft = nil          -- current track draft
local previewThread = false
local selectedCp = nil     -- index selected in the list submenu
local dirty = false        -- unsaved changes present?
local savedDraft = nil     -- preserved draft so closing the menu never loses work

-- Mark the draft as having unsaved edits (call after any change).
local function markDirty() dirty = true end

-- ── Menus (created ONCE at file scope) ──────────────────────────────────────
local mMain = MenuV:CreateMenu('Race Editor', 'Build a street race', 'topleft',
    255, 40, 40, 'size-125', 'none', 'menuv', 'hkrace_main')
local mList = MenuV:CreateMenu('Checkpoints', 'Select one to edit', 'topleft',
    255, 40, 40, 'size-125', 'none', 'menuv', 'hkrace_list')
local mCp = MenuV:CreateMenu('Checkpoint', '', 'topleft',
    255, 40, 40, 'size-125', 'none', 'menuv', 'hkrace_cp')

local suppressCloseHint = false   -- true during programmatic CloseAll (Exit/admin)

-- CloseAll without triggering the "press M to reopen" close hint.
local function closeAllSilent()
    suppressCloseHint = true
    MenuV:CloseAll(function() end)
    SetTimeout(200, function() suppressCloseHint = false end)
end

-- When the main menu is closed by B/Esc (not via Exit), remind the player their
-- work is safe and how to bring the menu back — nothing is lost.
mMain:On('close', function()
    if editing and not suppressCloseHint then
        RaceUtil.notify('Editor still open — press M to reopen. Your progress is kept.', 'inform')
    end
end)

local function newDraft()
    return {
        id = nil, name = 'New Race', listed = true,
        start = nil, checkpoints = {},
        rewards = { currency = 'cash', amounts = { 25000, 12000, 5000 } },
        -- Radius applied to NEW checkpoints as they're placed. Changing it never
        -- alters already-placed checkpoints (each keeps its own r). Per-checkpoint
        -- radius can still be tweaked in the checkpoint list.
        cpRadius = RaceConfig.Editor.defaultCheckpointRadius,
        startRadius = RaceConfig.Editor.defaultStartRadius,
        trackType = 'oneway',   -- 'oneway' | 'loop'
        loopLine = nil,         -- loop only: {x,y,z,radius} lap line (laps 1..N-1)
        finishLine = nil,       -- loop only: {x,y,z,radius} FINAL finish line (last lap)
        suggestedTier = 0,      -- admin's recommended class (0 = Any; 1..#tiers)
        legal = false,          -- false = illegal (police alerted); true = sanctioned/silent
        allowedTiers = {},      -- track lock: tiers permitted here (empty = all). Caps host.
    }
end

local function currentCoords()
    local ped = PlayerPedId()
    local ent = (IsPedInAnyVehicle(ped, false) and GetVehiclePedIsIn(ped, false)) or ped
    return GetEntityCoords(ent)
end

local function currentHeading()
    local ped = PlayerPedId()
    local ent = (IsPedInAnyVehicle(ped, false) and GetVehiclePedIsIn(ped, false)) or ped
    return GetEntityHeading(ent)
end

-- ── Live preview markers (editor only, local) ──────────────────────────────
local function startPreview()
    if previewThread then return end
    previewThread = true
    CreateThread(function()
        while editing do
            Wait(0)
            if draft and draft.start then
                local c = RaceConfig.Editor.startMarkerColor
                DrawMarker(1, draft.start.x, draft.start.y, draft.start.z - 1.0,
                    0,0,0, 0,0,0, draft.start.radius * 2.0, draft.start.radius * 2.0, 2.0,
                    c.r, c.g, c.b, c.a, false, false, 2, false, nil, nil, false)
            end
            if draft then
                for i, cp in ipairs(draft.checkpoints) do
                    local sel = (i == selectedCp)
                    local c = sel and RaceConfig.Editor.cpNextColor or RaceConfig.Editor.cpMarkerColor
                    DrawMarker(1, cp.x, cp.y, cp.z - 1.0, 0,0,0, 0,0,0,
                        cp.r * 2.0, cp.r * 2.0, 2.0, c.r, c.g, c.b, c.a,
                        false, false, 2, false, nil, nil, false)
                end
                -- Lap line preview (blue) — crossed each lap except the last.
                if draft.loopLine then
                    local ll = draft.loopLine
                    DrawMarker(1, ll.x, ll.y, ll.z - 1.0, 0,0,0, 0,0,0,
                        ll.radius * 2.0, ll.radius * 2.0, 3.0, 40, 130, 255, 150,
                        false, false, 2, false, nil, nil, false)
                end
                -- Final finish line preview (green) — crossed only on the last lap.
                if draft.finishLine then
                    local fl = draft.finishLine
                    DrawMarker(1, fl.x, fl.y, fl.z - 1.0, 0,0,0, 0,0,0,
                        fl.radius * 2.0, fl.radius * 2.0, 3.0, 40, 220, 90, 150,
                        false, false, 2, false, nil, nil, false)
                end
            end
        end
        previewThread = false
    end)
end

-- fwd decls
local buildMain, buildList, buildCp

-- ── Checkpoint actions submenu ──────────────────────────────────────────────
buildCp = function()
    mCp:ClearItems()
    local idx = selectedCp
    local cp = idx and draft.checkpoints[idx]
    if not cp then
        mCp:AddButton({ label = 'No checkpoint selected', description = 'Go back' })
        return
    end

    mCp:AddButton({ icon = '📍', label = ('Checkpoint %d / %d'):format(idx, #draft.checkpoints),
        description = ('%.1f, %.1f, %.1f (r=%.0f)'):format(cp.x, cp.y, cp.z, cp.r) })

    -- Teleport to it
    local tp = mCp:AddButton({ icon = '🎯', label = 'Teleport to it',
        description = 'Warp you (and vehicle) to this checkpoint' })
    tp:On('select', function()
        local ped = PlayerPedId()
        local ent = (IsPedInAnyVehicle(ped, false) and GetVehiclePedIsIn(ped, false)) or ped
        SetEntityCoords(ent, cp.x, cp.y, cp.z, false, false, false, false)
        RaceUtil.notify(('Teleported to checkpoint %d'):format(idx), 'success')
    end)

    -- Move to my position
    local mv = mCp:AddButton({ icon = '✏️', label = 'Move to my position',
        description = 'Overwrite this checkpoint with where you are now' })
    mv:On('select', function()
        local pos = currentCoords()
        cp.x, cp.y, cp.z = pos.x, pos.y, pos.z
        markDirty()
        RaceUtil.notify(('Checkpoint %d moved here'):format(idx), 'success')
    end)

    -- Radius of this checkpoint
    local r = mCp:AddRange({ icon = '🔘', label = 'Radius',
        min = math.floor(RaceConfig.Editor.minCheckpointRadius),
        max = math.floor(RaceConfig.Editor.maxCheckpointRadius),
        value = math.floor(cp.r or RaceConfig.Editor.defaultCheckpointRadius) })
    r:On('change', function(_, v) cp.r = v + 0.0; markDirty() end)

    -- Insert a new checkpoint right after this one (at my position)
    local ins = mCp:AddButton({ icon = '➕', label = 'Insert after (my position)',
        description = 'Adds a new checkpoint after this one, where you are' })
    ins:On('select', function()
        local pos = currentCoords()
        table.insert(draft.checkpoints, idx + 1,
            { x = pos.x, y = pos.y, z = pos.z, r = draft.cpRadius or RaceConfig.Editor.defaultCheckpointRadius })
        markDirty()
        RaceUtil.notify(('Inserted checkpoint %d'):format(idx + 1), 'success')
        -- Jump straight to the newly-inserted checkpoint's edit page.
        selectedCp = idx + 1
        buildList()   -- keep the list fresh underneath
        buildCp()     -- rebuild this page for the new checkpoint
        MenuV:OpenMenu(mCp)
    end)

    -- Delete this checkpoint (then pop back to the refreshed list)
    local del = mCp:AddConfirm({ icon = '🗑️', label = 'Delete this checkpoint', value = 'no' })
    del:On('confirm', function()
        table.remove(draft.checkpoints, idx)
        markDirty()
        RaceUtil.notify(('Deleted checkpoint %d'):format(idx), 'inform')
        selectedCp = nil
        buildList()
        MenuV:CloseMenu(mCp)  -- pop to list (already rebuilt)
    end)

    -- Back to list (pop one level; MenuV reopens the parent — no extra push)
    local back = mCp:AddButton({ icon = '↩️', label = 'Back to list' })
    back:On('select', function() buildList(); MenuV:CloseMenu(mCp) end)
end

-- ── Checkpoint list submenu (rebuilt each open, qb-adminmenu list pattern) ──
buildList = function()
    mList:ClearItems()
    if #draft.checkpoints == 0 then
        mList:AddButton({ icon = '📭', label = 'No checkpoints yet',
            description = 'Use "Add Checkpoint" on the main menu' })
    else
        for i, cp in ipairs(draft.checkpoints) do
            local btn = mList:AddButton({
                icon = (i == #draft.checkpoints) and '🏁' or '📍',
                label = ('Checkpoint %d / %d'):format(i, #draft.checkpoints),
                description = ('%.0f, %.0f, %.0f  ·  r=%.0f'):format(cp.x, cp.y, cp.z, cp.r),
                value = i,
                select = function(b)
                    selectedCp = b.Value
                    buildCp()
                    MenuV:OpenMenu(mCp)
                end,
            })
        end
    end
    local back = mList:AddButton({ icon = '↩️', label = 'Back' })
    back:On('select', function() MenuV:CloseMenu(mList) end)
end

-- ── Rename (typed input via ox_lib) ────────────────────────────────────────
-- These prompts fire from mMain (the root). We close MenuV first so ox_lib owns
-- NUI focus cleanly, then reopen the (rebuilt) main menu afterwards.
local function promptRename()
    closeAllSilent()
    local out = lib.inputDialog('Track Name', {
        { type = 'input', label = 'Name', default = draft.name, required = true,
          max = 64, description = 'Shown in /racemenu and the admin list' },
    })
    if out and out[1] and out[1] ~= '' then
        draft.name = tostring(out[1]):sub(1, 64)
        markDirty()
        RaceUtil.notify('Name set: ' .. draft.name, 'success')
    end
    buildMain()
    MenuV:OpenMenu(mMain)
end

local E = RaceConfig.Editor
local function clampNum(v, lo, hi, dflt)
    v = tonumber(v); if not v then return dflt end
    if v < lo then return lo elseif v > hi then return hi end
    return v
end

-- Start-zone radius (typed input — reliable, unlike the range slider).
local function promptStartRadius()
    closeAllSilent()
    local cur = (draft.start and draft.start.radius) or draft.startRadius or E.defaultStartRadius
    local out = lib.inputDialog('Start Radius', {
        { type = 'number', label = ('Radius in metres (%d–%d)'):format(E.minStartRadius, E.maxStartRadius),
          default = math.floor(cur), min = E.minStartRadius, max = E.maxStartRadius },
    })
    if out and out[1] ~= nil then
        local r = clampNum(out[1], E.minStartRadius, E.maxStartRadius, cur)
        draft.startRadius = r
        if draft.start then draft.start.radius = r end   -- resize an already-placed start
        markDirty()
        RaceUtil.notify(('Start radius: %.0fm'):format(r), 'success')
    end
    buildMain()
    MenuV:OpenMenu(mMain)
end

-- Checkpoint radius applied to NEWLY placed checkpoints. Does NOT touch existing
-- ones — each placed checkpoint keeps the radius it was created with.
local function promptCpRadius()
    closeAllSilent()
    local cur = draft.cpRadius or E.defaultCheckpointRadius
    local out = lib.inputDialog('Checkpoint Radius (new checkpoints)', {
        { type = 'number', label = ('Radius in metres (%d–%d)'):format(E.minCheckpointRadius, E.maxCheckpointRadius),
          default = math.floor(cur), min = E.minCheckpointRadius, max = E.maxCheckpointRadius,
          description = 'Applies to checkpoints placed from now on. Existing ones keep their size.' },
    })
    if out and out[1] ~= nil then
        draft.cpRadius = clampNum(out[1], E.minCheckpointRadius, E.maxCheckpointRadius, cur)
        markDirty()
        RaceUtil.notify(('New checkpoints: %.0fm radius'):format(draft.cpRadius), 'success')
    end
    buildMain()
    MenuV:OpenMenu(mMain)
end

-- Track tier lock — a checkbox per tier. Empty (all off) = all tiers allowed. This
-- HARD-CAPS the host: when hosting, they can only pick within these tiers.
local function promptAllowedTiers()
    MenuV:CloseAll(function() end)
    local set = {}
    for _, t in ipairs(draft.allowedTiers or {}) do set[t] = true end
    local rows = {}
    for i, nm in ipairs(RaceConfig.Tiers.names) do
        rows[i] = { type = 'checkbox', label = ('Class %s'):format(nm), checked = set[i] == true }
    end
    local out = lib.inputDialog('Allowed Tiers on this track', rows,
        { allowCancel = true })
    if out then
        local picked = {}
        for i = 1, #RaceConfig.Tiers.names do
            if out[i] then picked[#picked + 1] = i end
        end
        draft.allowedTiers = picked   -- empty = all allowed
        markDirty()
        RaceUtil.notify(#picked == 0 and 'Track: all tiers allowed'
            or ('Track locked to: ' .. tostring(#picked) .. ' tier(s)'), 'success')
    end
    buildMain()
    MenuV:OpenMenu(mMain)
end

-- ── Rewards (typed inputs via ox_lib) ──────────────────────────────────────
local function promptRewards()
    closeAllSilent()
    local capCash  = RaceConfig.Rewards.maxAmount.cash or 500000
    local capCoins = RaceConfig.Rewards.maxAmount.coins or 100000
    local cap = RaceConfig.Rewards.maxAmount[draft.rewards.currency] or capCash
    local a = draft.rewards.amounts or {}
    local out = lib.inputDialog('Rewards  (full pool needs 4+ racers; fewer = half)', {
        { type = 'select', label = 'Currency', default = draft.rewards.currency,
          required = true, options = {
            { value = 'cash',  label = 'Cash ($)' },
            { value = 'coins', label = 'HOMECOIN' },
          } },
        { type = 'number', label = '1st place payout', default = a[1] or 0, min = 0, max = cap, description = 'Type the exact amount' },
        { type = 'number', label = '2nd place payout', default = a[2] or 0, min = 0, max = cap },
        { type = 'number', label = '3rd place payout', default = a[3] or 0, min = 0, max = cap },
    })
    if out then
        draft.rewards.currency = out[1] or draft.rewards.currency
        -- Clamp to the chosen currency's cap (server clamps again for safety).
        local newCap = RaceConfig.Rewards.maxAmount[draft.rewards.currency] or capCash
        local function clampAmt(n) n = math.floor(tonumber(n) or 0); if n < 0 then n = 0 elseif n > newCap then n = newCap end; return n end
        draft.rewards.amounts = { clampAmt(out[2]), clampAmt(out[3]), clampAmt(out[4]) }
        markDirty()
        RaceUtil.notify('Rewards updated', 'success')
    end
    buildMain()
    MenuV:OpenMenu(mMain)
end

-- ── Main editor menu ────────────────────────────────────────────────────────
buildMain = function()
    mMain:ClearItems()

    -- Track name (typed input)
    local nameBtn = mMain:AddButton({ icon = '🏷️', label = 'Name: ' .. tostring(draft.name),
        description = 'Press to rename this track' })
    nameBtn:On('select', promptRename)

    -- Noclip (optional — for spots a car can't reach)
    local ncBox = mMain:AddCheckbox({ icon = '🕊️', label = L('editor_toggle_noclip'),
        description = 'Optional. WASD, SPACE up, CTRL down, SHIFT fast',
        value = RaceUtil.isNoclip() and true or false })
    ncBox:On('check', function() RaceUtil.setNoclip(true) end)
    ncBox:On('uncheck', function() RaceUtil.setNoclip(false) end)

    -- Set start at current position (uses the current start-radius setting)
    local startBtn = mMain:AddButton({ icon = '🚦', label = L('editor_set_start'),
        description = draft.start and 'Start is set — press to move it here' or 'Not set — press to place here' })
    startBtn:On('select', function()
        local pos = currentCoords()
        local radius = (draft.start and draft.start.radius) or draft.startRadius or RaceConfig.Editor.defaultStartRadius
        draft.start = { x = pos.x, y = pos.y, z = pos.z, radius = radius, h = currentHeading() }
        markDirty()
        RaceUtil.notify(('Start set here (%.0fm radius)'):format(radius), 'success')
    end)

    -- Start radius (typed input — the range slider was unreliable)
    local curStartR = math.floor((draft.start and draft.start.radius) or draft.startRadius or RaceConfig.Editor.defaultStartRadius)
    local sRadiusBtn = mMain:AddButton({ icon = '⭕',
        label = ('Start Radius: %dm'):format(curStartR),
        description = 'Press to type the start-zone radius' })
    sRadiusBtn:On('select', promptStartRadius)

    -- Checkpoint radius for NEW checkpoints (typed). Existing ones are untouched.
    local curCpR = math.floor(draft.cpRadius or RaceConfig.Editor.defaultCheckpointRadius)
    local cpRadiusBtn = mMain:AddButton({ icon = '🔘',
        label = ('New Checkpoint Radius: %dm'):format(curCpR),
        description = 'New checkpoints use this. Existing ones keep their own size.' })
    cpRadiusBtn:On('select', promptCpRadius)

    -- Add checkpoint at current position (menu stays open). Uses draft.cpRadius so
    -- widening the road later only affects checkpoints placed after the change.
    local addCp = mMain:AddButton({ icon = '📍', label = L('editor_add_cp'),
        description = 'Drops a checkpoint where you are. Drive on and press again.' })
    addCp:On('select', function()
        local pos = currentCoords()
        local r = draft.cpRadius or RaceConfig.Editor.defaultCheckpointRadius
        draft.checkpoints[#draft.checkpoints + 1] =
            { x = pos.x, y = pos.y, z = pos.z, r = r }
        markDirty()
        RaceUtil.notify(('Checkpoint %d added (%.0fm)'):format(#draft.checkpoints, r), 'success')
    end)

    -- Checkpoint list (browse + per-checkpoint actions).
    -- NOTE: no `value =` here — MenuV auto-opens a menu-valued button AND we also
    -- rebuild first, so we drive navigation ourselves via the select handler only.
    local listBtn = mMain:AddButton({ icon = '📋', label = 'Checkpoint List',
        description = 'Browse, delete, teleport, move, insert' })
    listBtn:On('select', function() selectedCp = nil; buildList(); MenuV:OpenMenu(mList) end)

    -- Suggested class (recommendation shown to players — does NOT restrict; the host
    -- still picks allowed tiers when hosting). Cycles Any → Street → Sport → Super.
    local sc = draft.suggestedTier or 0
    local scLabel = (sc == 0) and 'Any' or (RaceConfig.Tiers.names[sc] or 'Any')
    local scBtn = mMain:AddButton({ icon = '🏷️', label = 'Suggested Class: ' .. scLabel,
        description = 'Recommended vehicle class shown to players. A hint, not a limit.' })
    scBtn:On('select', function()
        draft.suggestedTier = (sc + 1) % (#RaceConfig.Tiers.names + 1)  -- 0..#tiers, wraps
        markDirty()
        buildMain(); MenuV:OpenMenu(mMain)
    end)

    -- Allowed Tiers LOCK (exclusive to this track). Caps what the host can pick.
    local at = draft.allowedTiers or {}
    local atLabel
    if #at == 0 then atLabel = 'All tiers'
    else
        local names = {}
        for _, t in ipairs(at) do names[#names + 1] = RaceConfig.Tiers.names[t] or ('T'..t) end
        atLabel = table.concat(names, ', ')
    end
    local atBtn = mMain:AddButton({ icon = '🔒', label = 'Allowed Tiers: ' .. atLabel,
        description = 'Lock which car tiers may race here. Hosts can only pick within this.' })
    atBtn:On('select', promptAllowedTiers)

    -- Race legality: illegal (police alerted, red circle) vs legal (sanctioned,
    -- silent, no police ever, blue circle).
    local legal = draft.legal and true or false
    local lgBtn = mMain:AddButton({ icon = legal and '✅' or '🚨',
        label = 'Legality: ' .. (legal and 'Legal (sanctioned)' or 'Illegal (police alerted)'),
        description = 'Legal = never triggers police, blue map circle. Illegal = alerts + red.' })
    lgBtn:On('select', function()
        draft.legal = not legal
        markDirty()
        buildMain(); MenuV:OpenMenu(mMain)
    end)

    -- Track type: One-way (A→B) or Loop (circuit; host picks laps at race time).
    local isLoop = (draft.trackType == 'loop')
    local ttBtn = mMain:AddButton({ icon = isLoop and '🔁' or '➡️',
        label = 'Track Type: ' .. (isLoop and 'Loop (circuit)' or 'One-way (A→B)'),
        description = 'Toggle. Loop adds a lap/finish line and host-chosen laps.' })
    ttBtn:On('select', function()
        draft.trackType = isLoop and 'oneway' or 'loop'
        if draft.trackType == 'oneway' then draft.loopLine = nil; draft.finishLine = nil end
        markDirty()
        RaceUtil.notify('Track type: ' .. draft.trackType, 'inform')
        buildMain(); MenuV:OpenMenu(mMain)
    end)

    -- Loop only: a lap line (crossed every lap 1..N-1) and a separate FINAL finish
    -- line (crossed only on the last lap). Both distinct from the gather start zone.
    if isLoop then
        local hasLoop = draft.loopLine ~= nil
        local llBtn = mMain:AddButton({ icon = '🔁',
            label = hasLoop and ('Lap Line: set (%.0fm)'):format(draft.loopLine.radius)
                             or 'Set Lap Line (here)',
            description = 'Crossed to complete each lap EXCEPT the last. Place on the circuit.' })
        llBtn:On('select', function()
            local pos = currentCoords()
            local r = (draft.loopLine and draft.loopLine.radius) or RaceConfig.Race.defaultLoopRadius
            draft.loopLine = { x = pos.x, y = pos.y, z = pos.z, radius = r }
            markDirty()
            RaceUtil.notify(('Lap line set (%.0fm)'):format(r), 'success')
            buildMain(); MenuV:OpenMenu(mMain)
        end)

        local hasFinish = draft.finishLine ~= nil
        local flBtn = mMain:AddButton({ icon = '🏁',
            label = hasFinish and ('Final Finish Line: set (%.0fm)'):format(draft.finishLine.radius)
                              or 'Set Final Finish Line (here)',
            description = 'Crossed only on the LAST lap to finish. Leave unset to finish at the lap line.' })
        flBtn:On('select', function()
            local pos = currentCoords()
            local r = (draft.finishLine and draft.finishLine.radius) or RaceConfig.Race.defaultLoopRadius
            draft.finishLine = { x = pos.x, y = pos.y, z = pos.z, radius = r }
            markDirty()
            RaceUtil.notify(('Final finish line set (%.0fm)'):format(r), 'success')
            buildMain(); MenuV:OpenMenu(mMain)
        end)
    end

    -- Rewards (typed input dialog). Label summarises current payouts.
    local a = draft.rewards.amounts or {}
    local sym = draft.rewards.currency == 'coins' and '' or '$'
    local suf = draft.rewards.currency == 'coins' and ' coins' or ''
    local rw = mMain:AddButton({ icon = '💰',
        label = ('Rewards: %s%s / %s%s / %s%s%s'):format(
            sym, a[1] or 0, sym, a[2] or 0, sym, a[3] or 0, suf),
        description = 'Press to type payouts + pick currency' })
    rw:On('select', promptRewards)

    -- Save (plain button, no yes/no). Visibility in /racemenu is managed from the
    -- /raceadmin list via the Show/Hide button, so no checkbox here.
    local saveBtn = mMain:AddButton({ icon = '💾', label = L('editor_save'),
        description = 'Save this track' })
    saveBtn:On('select', function()
        if not draft.start then RaceUtil.notify(L('editor_need_start'), 'error'); return end
        if #draft.checkpoints < 1 then RaceUtil.notify(L('editor_need_cp'), 'error'); return end
        if draft.trackType == 'loop' and not draft.loopLine then
            RaceUtil.notify('Loop track needs a finish line — set it first.', 'error'); return
        end
        lib.callback('hk-race:admin:saveTrack', false, function(res)
            if res and res.ok then
                draft.id = res.id
                dirty = false   -- saved: no unsaved changes
                RaceUtil.notify(L('editor_saved') .. ' (#' .. tostring(res.id) .. ')', 'success')
            else
                RaceUtil.notify('Save failed: ' .. tostring(res and res.error or '?'), 'error')
            end
        end, draft.id, draft)
    end)

    -- Exit (confirms if there are unsaved changes)
    local exitBtn = mMain:AddButton({ icon = '🚪', label = L('editor_exit') })
    exitBtn:On('select', function() RequestExit() end)
end

-- Normalise a freshly-loaded/new draft (editor-only fields, back-compat).
local function normaliseDraft(d)
    d.rewards = d.rewards or { currency = 'cash', amounts = {} }
    d.rewards.amounts = d.rewards.amounts or {}
    d.checkpoints = d.checkpoints or {}
    d.name = d.name or 'Race'
    d.startRadius = (d.start and d.start.radius) or RaceConfig.Editor.defaultStartRadius
    local lastCp = d.checkpoints[#d.checkpoints]
    d.cpRadius = (lastCp and lastCp.r) or RaceConfig.Editor.defaultCheckpointRadius
    d.trackType = d.trackType or 'oneway'
    d.suggestedTier = d.suggestedTier or 0
    d.legal = d.legal and true or false
    d.allowedTiers = d.allowedTiers or {}
end

-- ── Public entry / exit ────────────────────────────────────────────────────
-- existingTrack: table = edit that track; nil = new draft, BUT if a preserved
-- unsaved draft exists (savedDraft), resume it instead of discarding work.
function OpenEditor(existingTrack)
    if editing then
        -- Re-entry: force the menu back up regardless of MenuV's (possibly stale)
        -- CurrentMenu state — e.g. after the admin NUI stole focus.
        closeAllSilent()
        buildMain()
        MenuV:OpenMenu(mMain)
        return
    end
    editing = true
    selectedCp = nil

    if existingTrack then
        draft = existingTrack
        normaliseDraft(draft)
        dirty = false
        savedDraft = nil
    elseif savedDraft then
        -- Resume the preserved draft (from a previous close with unsaved work).
        draft = savedDraft
        savedDraft = nil
        -- dirty stays whatever it was (true if there were unsaved edits).
        RaceUtil.notify('Resumed your unsaved track.', 'inform')
    else
        draft = newDraft()
        dirty = false
    end

    buildMain()
    startPreview()
    MenuV:OpenMenu(mMain)

    -- Controller/keyboard reopen: press M (INPUT_INTERACTION_MENU, also mapped on
    -- controller) to bring the menu back after closing it with B/Esc while driving.
    CreateThread(function()
        while editing do
            Wait(0)
            if IsControlJustReleased(0, 244) and not MenuV.CurrentMenu then  -- M
                buildMain()
                MenuV:OpenMenu(mMain)
            end
        end
    end)
end

function IsEditing() return editing end

-- Actually tear down the editor and DISCARD the draft.
local function finalizeClose()
    editing = false
    if RaceUtil.isNoclip() then RaceUtil.setNoclip(false) end
    closeAllSilent()
    draft = nil
    savedDraft = nil
    dirty = false
    selectedCp = nil
    RaceUtil.notify('Editor closed', 'inform')
end

-- Exit requested from the menu. Confirm if there are unsaved changes.
function RequestExit()
    if not editing then return end
    if not dirty then finalizeClose(); return end
    closeAllSilent()
    local choice = lib.alertDialog({
        header = 'Unsaved changes',
        content = 'You have unsaved edits to this track.\n\nExit and discard them?',
        centered = true,
        cancel = true,
        labels = { confirm = 'Discard & Exit', cancel = 'Keep Editing' },
    })
    if choice == 'confirm' then
        finalizeClose()
    else
        -- Keep editing: reopen the menu where they left off.
        buildMain()
        MenuV:OpenMenu(mMain)
    end
end

-- CloseEditor: called by other systems (e.g. opening /raceadmin). PRESERVES the
-- draft if there are unsaved changes so work isn't lost — it can be resumed by
-- reopening the editor with "Create Track" (OpenEditor(nil)).
function CloseEditor()
    if not editing then return end
    editing = false
    if RaceUtil.isNoclip() then RaceUtil.setNoclip(false) end
    closeAllSilent()
    if dirty and draft then
        savedDraft = draft   -- preserve for resume
        RaceUtil.notify('Unsaved track kept — reopen the editor to continue.', 'inform')
    else
        savedDraft = nil
    end
    draft = nil
    selectedCp = nil
end

-- Launched from the admin NUI panel.
RegisterNetEvent('hk-race:client:launchEditor', function(trackId)
    if trackId then
        lib.callback('hk-race:admin:getTrack', false, function(track)
            if track then track.id = trackId end
            OpenEditor(track)
        end, trackId)
    else
        OpenEditor(nil)
    end
end)
