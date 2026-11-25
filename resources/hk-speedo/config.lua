-----------------------------------------------------------------
-- hk-speedo :: config.lua
-----------------------------------------------------------------

Config = {}

Config.Enabled = true

-- Position: 'bottomright', 'bottomleft', 'bottomcenter'
Config.Position = 'bottomright'

-- Units: auto-detected from player's GTA settings (Settings > Display > Measurement System)
-- Override: 'auto' (default), 'kmh', or 'mph'
Config.SpeedUnit = 'auto'

-- Max speed shown on gauge (visual only, arc clamps at this)
Config.MaxSpeed = 360

-- Max RPM (1.0 = redline in GTA terms, we display 0-9000 visually)
Config.MaxRPM = 9000

-- Show/hide individual indicators
Config.Indicators = {
    NOS       = true,   -- nitrous active glow
    Drift     = true,   -- drift state indicator
    Handbrake = true,   -- handbrake light
    Launch    = true,   -- launch control / rev-match green flash
    BadShift  = true,   -- bad gear change red flash (manual)
    BadDown   = true,   -- bad downshift yellow flash
}

-- Glow durations (ms)
Config.GlowDuration = {
    Launch   = 600,
    BadShift = 400,
    BadDown  = 400,
}

-- Integration: detect NOS from popular resources
Config.NOSResource = 'auto'  -- 'auto' tries common exports, or set resource name

-- Update rate (ms) — 16 = ~60fps, 33 = ~30fps
Config.TickRate = 26   -- ~38fps render tick (1000/38). Lighter still; needle smoothing
                       -- + vibration interpolate so motion stays fluid at this rate.

-- Hide when on foot
Config.HideOnFoot = true

-- Opacity when idle (not moving) — 0.0 to 1.0
Config.IdleOpacity = 0.6
