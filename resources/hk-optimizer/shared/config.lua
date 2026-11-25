OptiCfg = {}

-- Admin command that opens the editor.
OptiCfg.Command = 'hkopti'

-- Admin-gate the editor. Server-side (can't be bypassed). Access model matches
-- hk-scenario: txAdmin admins, QBCore/ACE admin principals, or the fallback
-- owner list in server/allowlist.lua. Set false to open the editor to everyone.
OptiCfg.AdminOnly = true

-- The tunable modes. 'quality' is the baseline (full GTA defaults, NOT editable).
-- The other three are what an admin tunes in the editor and saves to MySQL.
-- Player selection between these is NOT in this resource — it will live in the
-- /hud (F5) settings page and call exports['hk-optimizer']:applyMode(name).
OptiCfg.Modes = {
    { name = 'quality', label = 'Quality (Default)',  editable = false },
    { name = 'balance', label = 'Balance',            editable = true  },
    { name = 'fps',     label = 'Enhanced FPS+',      editable = true  },
}

-- Editable setting schema. Drives both the editor UI and the SQL columns.
--   key    : field name (also the DB column)
--   label  : editor text
--   kind   : 'bool' | 'int' | 'float'
--   min/max/step : for numeric ranges
--   default: baseline value
--   desc   : help text
OptiCfg.Schema = {
    { key = 'sweep_peds',       kind = 'bool',  default = false, label = 'Hide off-screen peds',        desc = 'Fade NPCs that are not on screen' },
    { key = 'sweep_objects',    kind = 'bool',  default = false, label = 'Hide off-screen objects',     desc = 'Fade props that are not on screen' },
    { key = 'ped_alpha',        kind = 'int',   default = 255, min = 0,   max = 255, step = 5,   label = 'Visible ped alpha',    desc = '255 = fully opaque, lower = see-through NPCs' },
    { key = 'obj_alpha',        kind = 'int',   default = 255, min = 0,   max = 255, step = 5,   label = 'Visible object alpha', desc = '255 = fully opaque props' },
    { key = 'lod_scale',        kind = 'float', default = 1.0, min = 0.1, max = 1.0, step = 0.05, label = 'LOD scale',           desc = 'Lower = pop-in closer but faster. 1.0 = default' },
    { key = 'shadow_bounds',    kind = 'float', default = 5.0, min = 0.0, max = 5.0, step = 0.5, label = 'Shadow distance',     desc = 'Cascade shadow bounds. 0 = shortest, 5 = default' },
    { key = 'flashlight_fade',  kind = 'float', default = 10.0, min = 0.0, max = 10.0, step = 0.5, label = 'Flashlight distance', desc = 'Fade distance for flashlights' },
    { key = 'lights_cutoff',    kind = 'float', default = 10.0, min = 0.0, max = 10.0, step = 0.5, label = 'Lights cutoff',       desc = 'Distance world lights stop drawing' },
    { key = 'rope_shadows',     kind = 'bool',  default = true,  label = 'Rope shadows',                desc = 'Shadows cast by ropes' },
    { key = 'disable_decals',   kind = 'bool',  default = false, label = 'Disable decals',              desc = 'Skip decal rendering (bullet holes, etc.)' },
    { key = 'remove_particles', kind = 'bool',  default = false, label = 'Strip nearby particles',      desc = 'Remove particle FX within 10m' },
    { key = 'disable_occlusion',kind = 'bool',  default = false, label = 'Disable occlusion',           desc = 'Skip occlusion culling pass' },
    { key = 'clear_weather_fx', kind = 'bool',  default = false, label = 'Clear weather FX',            desc = 'Zero rain/wind, clear timecycle & screen effects' },
    { key = 'clear_interval',   kind = 'int',   default = 1000, min = 200, max = 3000, step = 100, label = 'Cleanup interval (ms)', desc = 'How often the cleanup pass runs' },
}

-- Convenience: default row for a freshly-created mode.
function OptiCfg.DefaultSettings()
    local t = {}
    for _, f in ipairs(OptiCfg.Schema) do t[f.key] = f.default end
    return t
end
