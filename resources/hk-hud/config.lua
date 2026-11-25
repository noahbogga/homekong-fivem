-- hk-hud — HOMEKONG player status HUD
-- Owns the player-status icons + (phase 2) minimap/compass. The vehicle gauge
-- (speed/fuel/gear/nos) is hk-speedo — hk-hud does NOT render vehicle stats.
-- Replaces ps-hud; keeps ps-hud's external event contract so other resources
-- (ambulance job, consumables, buffs, nitro, harness…) keep working.
HKHudConfig = {}

-- Master tick rate (ms) for reading native player state.
HKHudConfig.Tick = 250

-- DEBUG: force every icon visible (with dummy values) so all styles/positions
-- can be checked at once. TURN OFF for normal play.
HKHudConfig.DebugAllIcons = false

-- Stress generation (ported from ps-hud, which is retired). Driving over these
-- speeds accrues stress; shooting has a chance to. Server writes qb metadata.
HKHudConfig.Stress = {
    enabled              = true,
    minSpeedUnbuckled    = 80,    -- km/h over this w/o seatbelt → stress
    minSpeed             = 140,   -- km/h over this WITH seatbelt → stress
    shootChance          = 0.10,  -- per-shot stress chance
    driveStressMult      = 0.5,   -- multiplier on driving (speed) stress; 0.5 = 50% less
    disablePoliceStress  = false,
    -- vehicle classes that cause speed stress (GetVehicleClass → true/false)
    vehClass = {
        ['0']=true,['1']=true,['2']=true,['3']=true,['4']=true,['5']=true,
        ['6']=true,['7']=true,['8']=false,['9']=true,['10']=true,['11']=true,
        ['12']=true,['13']=false,['14']=false,['15']=false,['16']=false,
        ['17']=true,['18']=false,['19']=false,['20']=false,['21']=true,['22']=false,
    },
    -- Screen-blur effect at high stress (ps-hud style). Below minStress = none.
    effectMinStress = 50,   -- start blurring at/above this stress
    blur = {  -- stress range → blur hold (ms)
        { min = 50, max = 60,  ms = 1500 },
        { min = 60, max = 70,  ms = 2000 },
        { min = 70, max = 80,  ms = 2500 },
        { min = 80, max = 90,  ms = 2700 },
        { min = 90, max = 100, ms = 3000 },
    },
    -- how often the effect re-fires, by stress range (ms)
    effectInterval = {
        { min = 50, max = 60,  ms = 55000 },
        { min = 60, max = 70,  ms = 45000 },
        { min = 70, max = 80,  ms = 35000 },
        { min = 80, max = 90,  ms = 25000 },
        { min = 90, max = 100, ms = 18000 },
    },
}

-- (Seatbelt alarm removed: jim-mechanic plays its own belt sound; hk-speedo owns
-- the seatbelt indicator. hk-hud must NOT beep or it double-fires / beeps forever
-- since hk-hud never sees the authoritative buckled state.)

-- Themes the player can pick in settings. 'hk' = HOMEKONG dark-glass brand
-- (default), 'legacy' = the familiar ps-hud rings.
HKHudConfig.Themes = {
    { id = 'hk',     label = 'HOMEKONG', zh = '香港' },
    { id = 'legacy', label = 'Legacy',   zh = '經典' },
}
HKHudConfig.DefaultTheme = 'hk'

-- ===========================================================================
-- STATUS ICONS
-- Rendered in array order. Fields:
--   id       matches the data key the client tick produces
--   label/zh display
--   icon     Font Awesome-ish glyph name the NUI maps to an SVG/emoji
--   color    default accent (players can override in settings)
--   vehicle  true = only relevant inside a vehicle (engine, harness, nitro…)
--   dynamic  true = supports the ps-hud "Show Always vs Only-When-Relevant"
--            per-icon mode (armor/engine/health/hunger/nitro/oxygen/stress/
--            thirst). Others are pure event indicators (show/hide only).
--   modeDefault  'always' | 'dynamic' | 'hidden' — the default display mode.
-- ===========================================================================
-- `icon` = Font Awesome 6 free-solid class (same icons ps-hud used). FA is
-- loaded from CDN in index.html — CEF renders it fine (webfont, not oklch).
HKHudConfig.Icons = {
    { id = 'voice',     label = 'Voice',     zh = '語音',   icon = 'fa-microphone',        color = '#e9eef3', modeDefault = 'always'  },
    { id = 'health',    label = 'Health',    zh = '生命',   icon = 'fa-heart',             color = '#21ab61', dynamic = true, modeDefault = 'always'  },
    { id = 'armor',     label = 'Armor',     zh = '護甲',   icon = 'fa-shield-halved',     color = '#326dbf', dynamic = true, modeDefault = 'dynamic' },
    { id = 'hunger',    label = 'Hunger',    zh = '飢餓',   icon = 'fa-hamburger',         color = '#dd6e14', dynamic = true, modeDefault = 'always'  },
    { id = 'thirst',    label = 'Thirst',    zh = '口渴',   icon = 'fa-droplet',           color = '#1a7cad', dynamic = true, modeDefault = 'always'  },
    { id = 'stress',    label = 'Stress',    zh = '壓力',   icon = 'fa-brain',             color = '#dc0606', dynamic = true, modeDefault = 'dynamic' },
    { id = 'oxygen',    label = 'Oxygen',    zh = '氧氣',   icon = 'fa-lungs',             color = '#8aa8bd', dynamic = true, modeDefault = 'dynamic' },
    { id = 'parachute', label = 'Parachute', zh = '降落傘', icon = 'fa-parachute-box',     color = '#b9ff28', modeDefault = 'dynamic' },
    -- vehicle-context
    { id = 'engine',    label = 'Engine',    zh = '引擎',   icon = 'fa-oil-can',           color = '#3FA554', dynamic = true, modeDefault = 'dynamic', vehicle = true },
    { id = 'nitro',     label = 'Nitro',     zh = '氮氣',   icon = 'fa-meteor',            color = '#ffffff', dynamic = true, modeDefault = 'dynamic', vehicle = true },
    { id = 'harness',   label = 'Harness',   zh = '安全帶', icon = 'fa-user-slash',        color = '#b648ff', modeDefault = 'dynamic', vehicle = true },
    -- seatbelt icon removed: hk-speedo already shows the seatbelt indicator.
    { id = 'cruise',    label = 'Cruise',    zh = '定速',   icon = 'fa-gauge-high',        color = '#00c8ff', modeDefault = 'dynamic', vehicle = true },
}

-- Low-value warning threshold (icon pulses red under this %). Health/armor use
-- their own logic (dead/no-armor). 0 disables pulsing for that icon.
HKHudConfig.WarnBelow = {
    hunger = 20, thirst = 20, oxygen = 20,
}

-- Status-icon cluster position. Vertical column, anchored left-center.
HKHudConfig.StatusPos = 'left-center'  -- 'left-center' | 'bottom-left'

-- ===========================================================================
-- MINIMAP (Phase 2) — hk-hud reshapes the native minimap (circle/square) using
-- the streamed masks in stream/ (circlemap.ytd / squaremap.ytd / minimap.gfx).
-- Per-player settings saved in KVP under the main settings blob (map.*).
-- ===========================================================================
HKHudConfig.Minimap = {
    enabled   = true,
    shape     = 'circle',  -- default 'circle' | 'square'
    onFoot    = true,      -- show the minimap while on foot (not just in vehicle)
    notify    = false,     -- toast when the map shape (re)loads
    -- Circle mode is more zoomed-in than square (its minimap component is bigger),
    -- so pull the radar OUT in circle only. SetRadarZoom: higher = wider view /
    -- less zoomed (0 is fully zoomed in). ps-hud used 1000; 0 = leave GTA default.
    -- Applied only when shape == 'circle' so square keeps its native zoom.
    circleZoom = 1100,
    -- GTA native notification feed (paycheck/item/dispatch toasts) anchors to the
    -- top of the minimap and can feel cramped against it. THEFEED_SET_SCRIPTED_MENU_HEIGHT
    -- shifts the feed's vertical anchor (must be re-applied every frame; the game
    -- resets it). Value direction is UNVERIFIED — start ~0.15, then flip the sign
    -- if it goes the wrong way. Set to nil/false to disable entirely (default OFF —
    -- untested, wired for live tuning after boot).
    feedHeight = false,   -- e.g. 0.15 to nudge the feed; false = don't touch it
    -- No separate border layer: the streamed circle/square mask gives the map
    -- its own crisp edge (bound to the map render), so a CSS border would only
    -- ever drift. The mask IS the border.
}

-- ===========================================================================
-- COMPASS (Phase 2) — a top-centre heading bar (degrees + N/NE/E… bearings +
-- current street names + centre pointer). Ported from ps-hud. Per-player
-- toggles saved in KVP 'hk-hud:compass'.
-- ===========================================================================
HKHudConfig.Compass = {
    enabled  = true,
    -- defaults (players toggle these in F5 settings)
    show     = true,   -- master: show the compass at all
    onFoot   = false,  -- show while on foot (ps-hud default: vehicle-only)
    follow   = true,   -- follow camera heading (vs ped heading)
    streets  = true,   -- show current street names
    pointer  = true,   -- show the centre ˅ pointer
    degrees  = true,   -- show the numeric heading (e.g. 273°)
    -- Optimized FPS: update the compass on a slow tick (like ps-hud) and let the
    -- NUI CSS-tween smooth the motion, instead of updating every frame. Big FPS
    -- win, motion is slightly less instant. Default ON (the "lower resource style").
    optimized = true,
    tickFast  = 40,    -- ms per update when NOT optimized (smooth, heavier)
    tickSlow  = 250,   -- ms per update when optimized (ps-hud-style, light)
}

-- ===========================================================================
-- CROSSHAIR
-- Only shown while free-aiming a weapon (hold right-click). Per-player settings
-- (enable/style/color/size/thickness/opacity/mode) saved via KVP. Dynamic mode
-- shrinks the crosshair slightly when aimed at a ped/player (on-target cue).
-- ===========================================================================
HKHudConfig.Crosshair = {
    enabled = true,   -- master default (player can turn off in settings)

    -- Styles the NUI can draw. Player picks one; the separate "Center Dot"
    -- toggle adds a dot to ANY style (so no redundant "cross+dot" style).
    styles = {
        { id = 'cross',   label = 'Cross',  zh = '十字' },   -- 4 lines + gap
        { id = 'dot',     label = 'Dot',    zh = '圓點' },   -- center dot only
        { id = 'circle',  label = 'Circle', zh = '圓環' },
        { id = 't',       label = 'T-Style',zh = 'T 字' },   -- no top line
    },

    -- Defaults (players override per-key in settings).
    defaults = {
        style     = 'cross',
        color     = '#00ff88',
        size      = 10,     -- line length / radius (px)
        thickness = 2,      -- stroke px
        gap       = 4,      -- center gap (px)
        opacity   = 90,     -- 0-100
        dot       = false,  -- extra center dot
        mode      = 'dynamic', -- 'static' | 'dynamic'
        outline   = true,   -- thin black outline for visibility on any background
    },

    -- Dynamic mode: multiply size/gap by this when aimed at a ped (on target).
    onTargetScale = 0.7,
    -- Optional: tint the crosshair this colour while on target (nil = keep colour).
    onTargetColor = '#ff3b3b',
}
