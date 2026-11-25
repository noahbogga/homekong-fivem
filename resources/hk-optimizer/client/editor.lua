--=====================================================================
-- hk-optimizer :: client editor (MenuV, hk-scenario style)
--   /hkopti -> admin gate -> pick a mode -> tune settings live -> save.
--   'quality' is the baseline (not editable; restores full GTA defaults).
--=====================================================================

local mMain = MenuV:CreateMenu('HK Optimizer', 'Pick a mode to tune', 'topleft',
    255, 180, 60, 'size-125', 'none', 'menuv', 'hkopti_main')
local mEdit = MenuV:CreateMenu('Edit Mode', '', 'topleft',
    255, 180, 60, 'size-125', 'none', 'menuv', 'hkopti_edit')

local editing = nil    -- mode name being edited
local working = nil    -- working copy of that mode's settings

-- Forward decls
local goMain, goEdit

-- Look up a mode's label + editable flag from config.
local function modeMeta(name)
    for _, m in ipairs(OptiCfg.Modes) do
        if m.name == name then return m end
    end
end

--=====================================================================
-- Main menu: list the modes.
--=====================================================================
local function buildMain()
    mMain:ClearItems()
    for _, m in ipairs(OptiCfg.Modes) do
        if m.editable then
            local btn = mMain:AddButton({ icon = '🎚️', label = m.label,
                description = 'Tune and save this mode' })
            btn:On('select', function()
                editing = m.name
                -- deep-ish copy of the synced settings (or defaults)
                working = {}
                local src = ModeSettings[m.name] or OptiCfg.DefaultSettings()
                for _, f in ipairs(OptiCfg.Schema) do working[f.key] = src[f.key] end
                goEdit()
            end)
        else
            local btn = mMain:AddButton({ icon = '↩️', label = m.label,
                description = 'Baseline — full GTA defaults (not editable)' })
            btn:On('select', function()
                exports['hk-optimizer']:applyMode('quality')
            end)
        end
    end
end

--=====================================================================
-- Edit menu: one row per schema field, live preview on change.
--=====================================================================
local function preview()
    -- Push the working copy through the engine so the admin sees it live.
    HkOpti_PreviewApply(working)
end

local function numLabel(f)
    local v = working[f.key]
    if f.kind == 'float' then
        return ('%s: %.2f  (◄ ► · ⏎)'):format(f.label, v + 0.0)
    end
    return ('%s: %d  (◄ ► · ⏎)'):format(f.label, math.floor(v))
end

local function buildEdit()
    mEdit:ClearItems()
    local meta = modeMeta(editing)
    mEdit.Subtitle = meta and meta.label or editing

    -- MenuV fires 'change' on each arrow tick, and 'select' fires immediately
    -- after a 'change' when saveOnUpdate is set. If 'select' lands right after
    -- a 'change' it was an arrow tick (drag), not a real Enter — ignore it.
    -- Otherwise it's a genuine Enter press → open the type-a-value dialog.
    local lastBarChange = 0
    local function isDragTick() return (GetGameTimer() - lastBarChange) < 120 end

    for _, f in ipairs(OptiCfg.Schema) do
        if f.kind == 'bool' then
            local box = mEdit:AddCheckbox({ icon = '⚙️', label = f.label,
                description = f.desc, value = working[f.key] and true or false })
            box:On('check',   function() working[f.key] = true;  preview() end)
            box:On('uncheck', function() working[f.key] = false; preview() end)
        else
            local item = mEdit:AddRange({ icon = '🎚️',
                label = numLabel(f),
                description = f.desc,
                min = f.kind == 'float' and 0 or f.min,     -- MenuV ranges are int steps
                max = f.kind == 'float' and 100 or f.max,
                value = f.kind == 'float'
                    and math.floor(((working[f.key] - f.min) / (f.max - f.min)) * 100)
                    or math.floor(working[f.key]),
                saveOnUpdate = true })
            item:On('change', function(it, v)
                if f.kind == 'float' then
                    -- map 0..100 slider back to min..max, snap to step
                    local raw = f.min + (v / 100) * (f.max - f.min)
                    local snapped = math.floor(raw / f.step + 0.5) * f.step
                    working[f.key] = math.max(f.min, math.min(f.max, snapped))
                else
                    working[f.key] = math.max(f.min, math.min(f.max, v))
                end
                lastBarChange = GetGameTimer()
                it.Label = numLabel(f)
                preview()
            end)
            item:On('select', function()
                if isDragTick() then return end   -- arrow tick, not a real Enter
                MenuV:CloseAll(function() end)
                local step = f.kind == 'float' and f.step or 1
                local out = lib.inputDialog(f.label, {
                    { type = 'number', label = ('%s (%s–%s)'):format(f.label, f.min, f.max),
                      default = working[f.key], min = f.min, max = f.max, step = step, required = true },
                })
                if out and out[1] ~= nil then
                    local val = tonumber(out[1]) or working[f.key]
                    if f.kind == 'float' then val = val + 0.0 else val = math.floor(val) end
                    working[f.key] = math.max(f.min, math.min(f.max, val))
                    preview()
                end
                goEdit()  -- rebuild so the bar reflects the typed value
            end)
        end
    end

    local saveBtn = mEdit:AddButton({ icon = '💾', label = 'Save',
        description = 'Write this mode to the database' })
    saveBtn:On('select', function()
        QBCore.Functions.TriggerCallback('hk-optimizer:save', function(ok)
            if ok then
                QBCore.Functions.Notify('Saved ' .. (meta and meta.label or editing), 'success')
                goMain()
            else
                QBCore.Functions.Notify('Save failed (permission?)', 'error')
            end
        end, editing, working)
    end)

    local cancelBtn = mEdit:AddButton({ icon = '✖️', label = 'Cancel',
        description = 'Discard changes and restore current mode' })
    cancelBtn:On('select', function()
        HkOpti_RestoreCurrent()
        goMain()
    end)
end

--=====================================================================
-- Navigation
--=====================================================================
goMain = function() MenuV:CloseAll(function() end); buildMain(); MenuV:OpenMenu(mMain) end
goEdit = function() MenuV:CloseAll(function() end); buildEdit(); MenuV:OpenMenu(mEdit) end

--=====================================================================
-- Command + admin gate. Nudge txAdmin auth first so a txAdmin who authed
-- before this resource loaded is still recognised (hk-scenario pattern).
--=====================================================================
RegisterCommand(OptiCfg.Command, function()
    TriggerServerEvent('txsv:checkIfAdmin')
    QBCore.Functions.TriggerCallback('hk-optimizer:canOpen', function(allowed)
        if not allowed then
            QBCore.Functions.Notify('You do not have permission to use this.', 'error')
            return
        end
        goMain()
    end)
end, false)
