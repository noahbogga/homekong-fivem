-- hk-wheel :: config
-- All tunables for the wheel bridge. The companion app has its OWN config (device
-- selection, axis mapping, FFB gains); THIS file is only the in-game/physics side.

Config = Config or {}

-- ── Transport ────────────────────────────────────────────────────────────────
-- The companion app hosts a WebSocket server on localhost; the NUI page connects
-- to it. Keep in sync with the app's --port. 127.0.0.1 only — never bind public.
Config.Host = '127.0.0.1'
Config.Port = 24897                 -- arbitrary high port; match the app
Config.ReconnectMs = 2000           -- NUI retries the socket this often when down

-- ── Button map (WheelBridge.exe format) ──────────────────────────────────────
-- WheelBridge.exe streams { steering, throttle, brake, buttons:[<pressed index>...] } — it does
-- NOT map buttons to named actions, it just sends which raw button INDICES are currently pressed.
-- So WE map index -> action here. To find an index: run the exe, watch its "Raw Buttons" readout
-- (or F8 /wheelstate), press a button, note the number, put it here.
--   ButtonMap[<index>] = '<action>'
-- Actions: 'shiftUp' 'shiftDown' (paddles, edge) · 'reverse' (HELD) · 'neutral' 'box' 'engine'
--   'hybrid' 'seatbelt' 'headlight' 'indLeft' 'indRight' 'hazards' 'nosToggle' 'nosLevelUp'
--   'nosLevelDn' (edge) · 'horn' 'lookBehind' 'lookLeft' 'lookRight' 'nosBoost' (HELD).
-- Leave as {} until you've noted your wheel's indices; steering + pedals work without it.
Config.ButtonMap = {
    -- EXAMPLE (Moza-ish — REPLACE with your real indices from the exe's Raw Buttons):
    -- [4]  = 'shiftUp',
    -- [5]  = 'shiftDown',
    -- [0]  = 'reverse',
    -- [1]  = 'neutral',
    -- [2]  = 'box',
}
-- Which actions are HELD (level-triggered) vs EDGE (fire once on press). Everything not listed
-- here is treated as EDGE. Matches the routing in client/main.lua + buttons.lua.
Config.HeldActions = {
    reverse = true, horn = true, lookBehind = true, lookLeft = true, lookRight = true, nosBoost = true,
}

-- ── Steering ─────────────────────────────────────────────────────────────────
Config.Steer = {
    Enabled       = true,
    -- Physical wheel range the DEVICE reports (degrees lock-to-lock). Logitech G29
    -- default 900, Fanatec often 1080, Thrustmaster 900/1080. The app reports the
    -- device's configured range; this is only the fallback if the app doesn't.
    WheelRangeDeg = 900.0,

    -- SOFT LOCK: the car's virtual steering lock. GTA steers ~±40° at the wheels but
    -- exposes it as a normalized ±1. We map the PHYSICAL wheel angle to the car's
    -- lock so a 900° wheel turns lock-to-lock across its full range (1:1-ish feel),
    -- instead of the car snapping full-lock in the first 40° like a gamepad.
    -- Per-class lock (steering "ratio") — sportier cars get a tighter ratio.
    LockDegDefault = 40.0,
    LockByClass = {
        [7]  = 36.0,   -- Super  (tighter, quicker)
        [6]  = 38.0,   -- Sports
        [4]  = 42.0,   -- Muscle (looser)
        [5]  = 40.0,   -- Sports Classics
        [2]  = 46.0,   -- SUV
        [1]  = 46.0,   -- Sedan
    },

    -- Speed-sensitive ratio: at high speed, reduce how much car-lock a given wheel
    -- angle produces (stability). 1.0 = no reduction; lower = calmer at speed.
    SpeedReductionKmh = 160.0,       -- reduction fully applied by this speed
    SpeedReductionMin = 0.55,        -- floor multiplier at/above SpeedReductionKmh

    -- Reassert the steering angle every frame we own it (GTA/sync fights back).
    -- We only override while a wheel is CONNECTED and the player is DRIVING.
    Deadzone      = 0.005,           -- normalized; ignore micro-jitter around center
    ReturnToPadMs = 250,             -- if the wheel drops out, fade back to pad over this
}

-- ── Force Feedback (values SENT to the app; the app owns the DI effects) ───────
Config.FFB = {
    Enabled           = true,
    UpdateHz          = 60,          -- how often Lua publishes an FFB frame to the app
    -- Self-aligning torque (the main "road feel"): scales with lateral load + speed.
    -- These are 0..1 gains the app multiplies by its own device master gain.
    SelfAlignGain     = 0.85,
    -- Extra kick when a tyre breaks traction (understeer light / oversteer).
    SlipDropGain      = 0.6,         -- FFB drops as the front washes out (understeer cue)
    -- Rumble on kerbs / surface (from wheel contact material + suspension compression).
    SurfaceGain       = 0.4,
    -- Centering spring when stopped / very low speed (parking feel).
    ParkSpringGain    = 0.25,
    ParkSpringBelowKmh= 8.0,
}

-- ── Pedals (throttle / brake) ──────────────────────────────────────────────────
-- IMPORTANT: do NOT assume GTA reads the wheel's pedals natively. Many wheels split
-- pedals onto a separate HID device GTA ignores, or don't enumerate as a standard
-- pad. So when a wheel is live we FEED throttle/brake into GTA's own controls (71/72)
-- from the app frame — that's the value hk-handling's sim reads (state.throttle/brake)
-- AND what GTA's engine uses. Fully analog. If the app reports nil for a pedal (device
-- lacks it), we DON'T write that control (keyboard/pad keeps it).
Config.Pedals = {
    Enabled   = true,
    Throttle  = true,               -- feed control 71 from frame.throttle
    Brake     = true,               -- feed control 72 from frame.brake
    Deadzone  = 0.02,               -- ignore pedal noise near rest
}

-- ── Handbrake (analog %) ───────────────────────────────────────────────────────
-- hk-handling reads handbrake as a BOOLEAN (control 76 / GetVehicleHandbrake) and it's
-- load-bearing: launch staging + the reverse-gate neutral both key off it. GTA has NO
-- analog e-brake native, so the wheel's 0..1 handbrake becomes: (a) a boolean press on
-- control 76 past Threshold (drives all the box logic that expects it), AND (b) an
-- OPTIONAL progressive rear brake-pressure for a drift feel via SetVehicleBrakePressure.
Config.Handbrake = {
    Enabled       = true,
    Threshold     = 0.15,           -- pull past this % = handbrake "on" (control 76 held)
    Analog        = true,           -- also apply progressive rear brake pressure 0..1
    AnalogMaxPress= 1.0,            -- rear brake pressure at full pull (drift feel)
}

-- ── Shifter: PADDLE-ONLY (+/-) ──────────────────────────────────────────────────
-- SCOPE (user, 2026-07-27): paddle shifters only. No H-pattern, no sequential lever.
--   frame.shift   == 'up' | 'down'   (ONE-SHOT edge per paddle pull)
--   frame.reverse == true/false      (HELD dedicated REVERSE button)
-- Clutch pedal still supported (for clutch launches / drop-to-auto). NEUTRAL is a standalone
-- button (Buttons 'neutral' action), NOT part of the shifter. Box auto<->manual is the
-- 'box' button (Buttons -> hk-handling SetBoxMode export).
--
-- REVERSE = REAL-CAR throttle-to-reverse (NOT gamepad brake-to-reverse). While the reverse
-- button is HELD, the pedals SWAP (throttle -> reverse-go, brake -> stop) — matching GTA's own
-- in-reverse control overload — which also trips hk-handling's reverse gate so the speedo shows R.
Config.Shifter = {
    Enabled       = true,
    ClutchEnabled = true,
    EngagePoint   = 0.55,            -- clutch pedal position (0=up/engaged .. 1=floored/disengaged)
}

Config.Debug = false                  -- F8 spam: connection state, angle, ffb frames
