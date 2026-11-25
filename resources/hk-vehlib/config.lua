-----------------------------------------------------------------
-- hk-vehlib :: config.lua
-- Library configuration. Consumer scripts can override these
-- via their own configs — these are just sensible defaults.
-----------------------------------------------------------------

VehLib = VehLib or {}

VehLib.Config = {
    -- How often the state tracker updates (0 = every frame)
    StateTickMs = 0,

    -- Smoothing defaults for force application
    DefaultForceTau = 0.15,     -- seconds, exponential smoothing

    -- Safety limits
    MaxTorqueMultiplier = 5.0,  -- never apply more than 5x torque
    MaxForceNewtons = 50000.0,  -- cap on ApplyForceToEntity magnitude
    MaxGravityMult = 2.0,       -- cap on gravity manipulation

    -- Handling restore behavior
    RestoreOnExit = true,       -- always restore when leaving vehicle
    RestoreOnResourceStop = true,

    -- Debug
    Debug = false,
}
