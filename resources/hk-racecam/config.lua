Config = {}

-----------------------------------------------------------------
-- ENGAGEMENT / IDLE DETECTION
-- The race cam is NOT a toggle you hold. You enable the *mode*,
-- then it watches your mouse/look. Stop looking around for
-- `IdleThresholdMs` and it eases in. Touch the look axis and it
-- instantly hands control back to the normal gameplay camera.
-----------------------------------------------------------------
Config.Engagement = {
    -- How long (ms) of no look input before the race cam eases in.
    IdleThresholdMs = 650,        -- 1.5s (was 2500)

    -- Look input below this magnitude counts as "not looking".
    -- GetDisabledControlNormal returns ~0 at rest, 1.0 at full deflection.
    LookDeadzone = 0.12,

    -- Also honour controller right-stick (220/221) so gamepad users
    -- get the same idle behaviour as mouse users.
    CheckController = true,

    -- Disable the look controls while the cam owns the view, so the
    -- game's own camera doesn't fight us. We still READ them via
    -- GetDisabledControlNormal to detect intent.
    DisableLookWhileActive = true,   -- Re-enabled (heading correction handles the pivot)

    -- Ease-in time (ms) when engaging, and ease-out when the player
    -- starts looking again. EaseIn is softened since the cam now seeds from the
    -- live gameplay-cam view and dollies in (see SmoothEngage below).
    EaseInMs = 150,   -- RenderScriptCams blend on engage. Restored to 150 (from 0) now that
                      -- engage() sets the correct rotation BEFORE activating — the blend just
                      -- softens the gameplay→scripted handoff, no longer fights a stale-rotation
                      -- first frame. The old "far first zoom" was the missing-SetCamRot bug, now fixed.
    EaseOutMs = 0,  -- instant snap back to native cam  -- reduced from 180 (faster exit blend)

    -- SMOOTH ENGAGE: seed the scripted cam between the chase pose and the live
    -- gameplay-cam view (SeedBias), then dolly into the chase pose using a slowed
    -- smoothing tau that ramps back to normal across EngageBlendMs. Softens the
    -- snap into chase without the long "hover then crawl back" delay.
    SmoothEngage  = true,
    SeedBias      = 0.0,    -- 0 = start at chase pose (closest to car), 1 = at gameplay cam.
                            -- Set to 0 so the dolly-in begins right at the chase distance.
    EngagePullback = 0.0,   -- DISABLED (reverted). The pullback dolly stacked on top of
                            -- RenderScriptCams' own blend, producing TWO separate zoom
                            -- movements that looked weird. Back to seeding at the chase pose.
    EngageBlendMs = 500,    -- duration of the slow-blend window (was 900 — shortened)
    -- PROGRESSIVE EASE-OUT: tau ramps from a SMALL start (snappy approach) to a
    -- LARGER end (floaty settle). The growing tau + shrinking gap compound for a
    -- fast-start / slow-arrival feel — the user's "faster at the start, much slower
    -- when closer to vehicle" ask. FOV stays on its normal smoothing (no zoom pop).
    EngageTauStart = 0.03,  -- starting tau (sec) — very snappy initial approach
    EngageTauEnd   = 0.24,  -- ending tau (sec) — floaty settle near the pose
}

-----------------------------------------------------------------
-- CAMERA COLLISION
-- Raycast from the car to the desired camera position; if it hits world geometry
-- (walls, barriers, terrain, tunnels) pull the camera in to the near side so it
-- doesn't clip through solids or sink underground.
-----------------------------------------------------------------
Config.Collision = {
    Enabled     = true,     -- Re-enabled (heading-snap correction now handles the pivot bug)
    Flags       = 1 + 16,   -- shapetest flags: 1 = world geometry, 16 = objects.
                            -- (Intentionally NOT including peds/vehicles = flag 2/4.)
    Skin        = 0.35,     -- pull in this many metres BEFORE the hit so the cam never
                            -- poked through the surface
    Lookahead   = 0.8,      -- cast the probe this many metres PAST the camera position so
                            -- a wall is detected (and the pull-in begins) before contact
    MinDistance = 1.2,      -- never pull closer than this to the car (avoids cam ending
                            -- up inside the vehicle on a tight wall)
}

-----------------------------------------------------------------
-- CONTROLS
-- Keys are bound via RegisterKeyMapping (rebindable in
-- Settings > Key Bindings > FiveM). Use FiveM key names, NOT control
-- IDs: https://docs.fivem.net/docs/game-references/input-mapper-parameter-ids/keyboard/
-- e.g. 'F7', 'F6', 'F5', 'HOME', 'NUMPAD0', 'B', etc.
-----------------------------------------------------------------
Config.Controls = {
    CycleKey     = 'F7',  -- cycle: off -> chase -> bonnet -> off
    LockKey      = 'F4',  -- lock/unlock the dynamic motion (freezes sway/zoom)
    UseKeyMapping = true, -- bind the keys above; false = command/export only
}

-----------------------------------------------------------------
-- GLOBAL CAMERA LIMITS
-- Hard ceilings applied to every free preset, regardless of per-preset
-- values or live debug-menu edits. Stops fast cars / extreme settings
-- from making the cam unusable.
-----------------------------------------------------------------
Config.Limits = {
    MaxFov         = 74.0,   -- FOV cap (raised to give speed-ramp headroom)
    SpeedCapKmh    = 220.0,  -- speed used for zoom logic is capped here; faster
                             -- vehicles stop pulling the cam back any further
}

-----------------------------------------------------------------
-- SPEED-DISTANCE RAMPING
-- Controls how the accel zoom-out (minExtraDistance -> maxExtraDistance)
-- ramps from idle to top speed. The distance pull-back is:
--   baseDist + lerp(minExtraDistance, maxExtraDistance, speedFactor)
-- where speedFactor = clamp(kmh / RampMaxSpeedKmh, 0, 1).
-----------------------------------------------------------------
Config.SpeedDistanceRamp = {
    Enabled         = true,
    RampMaxSpeedKmh = 120.0,   -- speed at which minExtra -> maxExtra blend completes
}

-- Order presets cycle through. Must match keys in Config.Presets.
-- The cycle includes "off" (disarmed) as the first state.
Config.PresetOrder = { 'chase', 'bonnet' }
Config.DefaultPreset = 'chase'

-- Only engage while actually driving (not as passenger), and only
-- in these vehicle classes. Set to nil to allow all classes.
-- Class list: https://docs.fivem.net/natives/?_0x29439776AAA00A62
Config.DriverOnly = true
Config.AllowedClasses = nil   -- e.g. { [0]=true,[1]=true,[2]=true,[7]=true } for cars/sports/SUV/super

-- Minimum speed (km/h) before the cam will engage. Stops the cam
-- snapping in while you're parked. Set 0 to always allow.
Config.MinEngageSpeedKmh = 5.0

-----------------------------------------------------------------
-- GEAR SHIFT "PUNCH"
-- On every gear change, briefly dip height/FOV/distance for a quick
-- mechanical kick, then ease back. Only applies to the free (chase)
-- presets. Values are the MAX amount subtracted at the peak of the dip.
-----------------------------------------------------------------
Config.GearShift = {
    Enabled      = true,
    DurationMs   = 650,   -- longer fade in/out (smoother, less snappy)
    HeightDip    = 0.038, -- -25% (was 0.10)
    FovDip       = 0.075, -- downshift FOV narrow
    FovBop       = 1.2,   -- upshift FOV widen (degrees, brief outward bop)  -- -25% (was 0.20)
    DistanceDip  = 0.045, -- -25% (was 0.30)
    MinSpeedKmh  = 15.0,  -- only at real driving speed
}

-----------------------------------------------------------------
-- HANDBRAKE "PUNCH"
-- A SHORT extra camera motion when the HANDBRAKE is yanked (separate from the
-- normal S-brake lean — this is an additional, snappier kick on top). Fires on
-- the handbrake's rising edge, and its strength scales with how hard the car is
-- actually decelerating: a handbrake pull with NO speed drop (already stopped, or
-- no grip) produces NO motion. Shorter than the gear punch so it reads as a snap.
-----------------------------------------------------------------
Config.Handbrake = {
    Enabled      = true,
    DurationMs   = 180,   -- SHORT — keep it snappy (raise if you want a longer dip)
    HeightDip    = 0.10,  -- max height drop at the pulse peak (at full decel)
    FovDip       = 0.10,  -- max FOV dip at the pulse peak
    DistanceDip  = 0.12,  -- max distance pull-in at the pulse peak
    MinSpeedKmh  = 15.0,  -- don't punch below this speed (no point when crawling)
    MinDecel     = 1.5,   -- m/s^2 of deceleration required to fire — if the handbrake
                          -- doesn't actually slow the car, no motion (the user's ask)
    FullDecel    = 8.0,   -- m/s^2 of deceleration that gives the FULL-strength punch;
                          -- between MinDecel and this the punch scales linearly
}

-----------------------------------------------------------------
-- REVERSE CAMERA
-- When the car is TRULY moving backward (not just braking), flip the
-- camera to look forward over the hood and LOCK distance/height/FOV
-- (no speed-based zoom while reversing — keeps it readable).
-- Detected via GetEntitySpeedVector(veh, true).y < -threshold.
--
-- C-KEY (look behind): While holding C (INPUT_VEH_LOOK_BEHIND, control 79),
-- the camera flips to reverse view (front of car looking back) even when
-- driving forward. Release to return to chase.
-----------------------------------------------------------------
Config.Reverse = {
    Enabled        = true,
    SpeedThreshold = 5.5,   -- requires ~20 km/h backward before flipping
                            -- to reverse cam — filters out tiny backslides after braking
    CKeyEnabled    = true,  -- C-key hold triggers reverse view (even when not reversing)
    -- Look-behind control IDs checked to trigger the reverse view. 79 =
    -- INPUT_VEH_LOOK_BEHIND (keyboard C AND controller R3 while driving — covers
    -- both devices on stock bindings); 26 = INPUT_LOOK_BEHIND (on-foot fallback).
    -- Any one pressed flips to reverse view. Rebind here if your keymap differs.
    LookBehindControls = { 79, 26 },
    DebounceMs     = 650,   -- 650ms sustained reverse before flipping. Prevents false flips on slides/crashes
                            -- on momentary physics backslide (brake overshoot, slope roll).
    TransitionMs   = 300,
    InstantAboveKmh = 80.0, -- above this speed, C-key reverse snaps instantly (no sweep)   -- smooth sweep duration when entering C-key reverse (ms).
                            -- 0 = instant snap, 300 = smooth sweep around the car.
    ExitTransitionMs = 120, -- sweep duration when RELEASING C (faster snap-back).
    CKeyDebounceMs = 30,    -- SEPARATE, much faster debounce for the look-behind key/button.
                            -- It's a deliberate hold so it doesn't need the slope/drift guard —
                            -- it snaps to reverse view almost instantly. Physical reverse keeps
                            -- the slower DebounceMs above.
    -- HANDBRAKE-DRIFT GUARD: stop a handbrake 180 / drift's brief backward slide
    -- from falsely flipping to the reverse cam. Handbrake held always suppresses;
    -- recent throttle + recent forward motion (within DriftGuardWindowMs) marks the
    -- backslide as drift recovery; and above DriftGuardMinKmh a sideways slide bigger
    -- than the backward speed (× DriftGuardLatRatio) is treated as a drift too.
    HandbrakeGuard     = true,
    DriftGuardWindowMs = 3000, -- if throttle was pressed AND car moved forward within this
                               -- many ms, a backslide is drift recovery, not a reverse
    DriftGuardMinKmh   = 15.0, -- below this, treat slow backward motion as genuine reverse
    DriftGuardLatRatio = 1.0,  -- lateral slide must exceed backSpeed × this to count as drift
    Distance       = 4.5,   -- locked distance in FRONT of the car
    Height         = 2.24,  -- locked height (+12%)
    Fov            = 60.0,  -- locked fov
    lookHeight     = 1.0,   -- where to look (on the car)
}

-----------------------------------------------------------------
-- CAMERA STABILIZER (terrain bump / hill smoothing)
-- Keeps the chase cam stable over bumps and elevation changes.
-- Two mechanisms:
--   1. Horizon Lock: camera pitch stays partially level (world horizon)
--      instead of following the car's nose angle on bumps.
--   2. Height Damping: Z-axis of camera position uses a heavier
--      smoothing tau than XY, so bumps are absorbed.
-- Speed-scaled: more stabilization at speed, less at crawl.
-- Applies to BOTH motion-locked and motion-unlocked modes.
-----------------------------------------------------------------
-----------------------------------------------------------------
-- DRIFT CAMERA (overlay — additive on chase cam)
-- Activates when hk-handling drift mode is held AND the car is
-- actually sliding (slip angle > deadzone). A small FOV bump
-- on key hold gives immediate feedback even before sliding.
-----------------------------------------------------------------
Config.DriftCam = {
    Enabled       = true,
    -- Immediate feedback on drift key hold (regardless of slip)
    KeyHoldFovBump = 1.5,   -- subtle FOV widen on key hold
    -- Slip-based effects (scale with how sideways the car is)
    MinAngleDeg   = 8.0,    -- deadzone
    FullAngleDeg  = 30.0,   -- reaches full at 30°
    YawBlend      = 0.026,   -- gentle velocity blend (capped low)
    DistanceAdd   = 0.35,    -- subtle pull-back
    LateralShift  = 0.008,    -- lateral pan (tamed)
    HeightAdd     = 0.10,   -- subtle height
    RollDeg       = 0.49,    -- NFS-style tilt (inverse-speed: stronger at low speed)    -- gentle lean
    FovAdd        = 1.0,    -- subtle FOV on top of key bump
    SmoothTau     = 0.70,   -- slower/smoother transitions
    MinSpeedKmh   = 5.0,    -- lowered so doughnuts/burnouts work
    -- GAUGE: smooth ramp-up/decay for key spam tolerance
    GaugeRiseRate = 0.8,    -- gauge fills per second (0→1 in 1.25s)
    GaugeDecayRate = 0.4,   -- gauge drains per second (1→0 in 2.5s)
    -- CAPS: hard limits so nothing overshoots
    MaxLateral    = 0.008,    -- max lateral shift (metres)
    MaxYawDeg     = 0.125,    -- max yaw offset (degrees)
    PivotForward  = 0.115,    -- orbit pivot shifts this far forward (metres) at full drift
    OrbitBlend    = 0.007,   -- blend camera POSITION toward velocity direction (0=heading, 1=velocity)
}

-----------------------------------------------------------------
-- ROAD BUZZ (subtle surface vibration)
-- Micro-tremor that mimics road texture. Does NOT move the camera
-- position, pitch, or rotation — only a built-in GTA shake overlay.
-- Starts very subtle at low speed, ramps gradually.
-----------------------------------------------------------------
Config.RoadBuzz = {
    Enabled      = true,
    StartKmh     = 20.0,    -- starts at this speed
    FullKmh      = 260.0,   -- reaches max intensity at this speed
    MaxIntensity = 0.04,    -- very subtle (0.01-0.10 range, higher = more)
}

Config.Stabilizer = {
    Enabled = true,
    -- Horizon lock: 0 = fully follow car pitch, 1 = fully level with world
    HorizonLock = 0.45,
    -- At low speed, less stabilization so hills still feel connected
    MinHorizonLock = 0.10,
    -- Speed at which stabilization reaches full HorizonLock value
    FullSpeedKmh = 100.0,
    -- Height (Z) smoothing: heavier tau absorbs vertical bumps.
    -- This is ADDITIONAL to whatever position smoothing already exists.
    -- The camera still follows XY instantly (entity-relative), but Z glides.
    HeightTau = 0.10,           -- sec (higher = floatier over bumps)
    MaxDeviationUp = 0.18,     -- max meters camera can float ABOVE target (uphill lag)
    MaxDeviationDown = 0.22,   -- max meters camera can sink BELOW target (downhill lag)
    -- Pitch rate limiter: max degrees per second the camera pitch can change.
    -- Filters out sharp bump spikes. 0 = disabled.
    MaxPitchRate = 45.0,        -- deg/sec (bumps spike 100+, roads are <30)
}

-----------------------------------------------------------------
-- FRONT-CHASE CAMERA (camera in front, looking back at car)
-- Makes the main chase cam sit IN FRONT of the vehicle facing backward
-- (the same angle as the C-key reverse view, but as the primary cam).
-- All dynamic effects (FOV, G-force, cornering, shake) still apply.
-- The speed-distance curve is COMPRESSED: the cam pulls back gently
-- with speed, capped well below the normal chase extremes.
-----------------------------------------------------------------
Config.FrontChase = {
    Enabled = true,          -- front-chase cam

    -- SPEED-DISTANCE CURVE (compressed):
    -- The camera starts at BaseDist at idle, pulls back to MaxDist at MaxSpeedKmh.
    -- Beyond MaxSpeedKmh the distance is CAPPED (no further pull-back).
    -- These replace the normal distance ramp when FrontChase is active.
    -- SPEED-DISTANCE BREAKPOINTS: piecewise curve with smoothstep between points.
    -- Each entry is {speed_kmh, distance_m}. Camera interpolates smoothly between them.
    -- Edit these directly to shape the pull-back feel at any speed range.
    Breakpoints = {
        {0,   5.02},   -- idle
        {40,  6.14},   -- steeper early ramp
        {80,  6.30},   -- steep ramp (the speed-feel zone)
        {120, 6.48},   -- moderate above 80
        {160, 6.68},   -- added
        {200, 6.93},   -- gradual
        {265, 7.32},   -- settling
        {360, 7.65},   -- settling
        {420, 7.96},   -- hard cap
    },
    DistanceSmoothing = 0.20,-- tau (sec) damping on the zoom ramp. Higher = smoother
                             -- / lazier zoom; lower = tighter tracking of speed.

    -- V-key mode scaling: multiplies distance+height per view mode.
    -- Mode 0=near (tighter), 1=medium (current feel), 2=far (pulled back).
    ViewModeScales = { [0] = 0.74, [1] = 0.90, [2] = 1.03 },

    -- Baseline steering sway (UNLOCKED only; locked mode stays frozen).
    -- The velocity/g-force sway terms are gated dead below GForce.LatDeadZoneKmh
    -- and are near-zero in GTA grip corners, so without this the chase cam sits at
    -- exactly 0 lateral — drift exit then lands on 0 and reads as a small snap.
    SteerDeadzone  = 0.25,   -- ignore first 25% of steering travel (no cam move)
    ChaseSway      = 0.0014,   -- metres of lateral offset at full steering lock (at idle)
    ChaseSwayFullKmh = 400.0,-- speed at which sway reaches its minimum scale
    ChaseSwayMinScale = 0.02,-- floor: 2% of ChaseSway at ChaseSwayFullKmh and above.
                             -- Non-zero on purpose — a hard 0 would give drift exit
                             -- nothing to land on, which is the snap this fixes.
    ChaseSwayDriftFade = true, -- cross-fade this out as the drift lateral fades in,
                             -- so counter-steer and slide don't pull opposite ways

    -- Height and look offsets for the front-facing view
    Height         = 1.83,    -- camera height at idle
    HeightDropAtSpeed = 0.14, -- height drops this much at full speed (closer to ground)
    HeightDropFullKmh = 200.0,-- speed at which full drop is reached
    LookHeight     = 1.0,    -- look-at point height on the car
    PitchDownAtSpeed = 1.5,  -- degrees to tilt aim DOWN at full speed (more road in frame)
    PitchDownFullKmh = 220.0,-- speed at which full pitch-down reached
}

-----------------------------------------------------------------
-- VIEW MODE FOLLOW (GTA's V-key distance)
-- Capture GTA's own follow-cam distance at engage-time (before the
-- scripted cam takes over), then track the V-key view mode (near/medium/far)
-- every frame and scale that baseline by the mode ratios. This uses the V
-- key fully (instant near/medium/far snap) without per-frame coord reads
-- that feedback-drift. First-person (mode 4) auto-disengages so you can
-- jump to FP and the cam hands control back cleanly.
-----------------------------------------------------------------
Config.ViewModeFollow = {
    Enabled             = true,
    -- Distance scale per GetFollowVehicleCamViewMode() int.
    -- V-key positions: [1] first-person = mode 4 (disengages),
    -- [2] near = mode 0, [3] medium = mode 1, [4] furthest = mode 2.
    ModeScales = {
        [0] = 0.50,   -- near    (V pos 2) — pulled in closer
        [1] = 0.72,   -- medium  (V pos 3) — pulled in closer
        [2] = 1.40,   -- far     (V pos 4) — left as-is
    },
    -- FOV offset per mode (added to the speed-driven FOV target). Closer
    -- view modes narrow FOV slightly so the sense of compression matches
    -- the tighter distance. Mode 4 (first-person) disengages, so unused.
    ModeFovOffsets = {
        [0] = -3.0,   -- near    (V pos 2) — narrower FOV for closer look
        [1] = -1.5,   -- medium  (V pos 3) — slight narrowing
        [2] =  0.0,   -- far     (V pos 4) — baseline FOV (no offset)
    },
    DisengageOnFirstPerson = true,  -- mode 4 -> disengage instantly (hands control back)
}

-----------------------------------------------------------------
-- VIEW MODE OVERRIDES (per-V-key position dedicated configs)
-- Each V-key position can override preset fields. These merge AFTER the
-- base preset + vehicle custom, so view-mode tweaks apply universally.
-- Mode ints: 0=near, 1=medium, 2=far, 4=first-person (disengages).
-- Only list fields you want to CHANGE for that mode; unlisted = inherit base.
-----------------------------------------------------------------
Config.ViewModeOverrides = {
    -- ALL MODES: shared feel knobs (per-mode blocks override fov/lookAheadBase)
    _base = {
        smoothness       = 0.16,     -- MOVE LAG — raised 0.04 -> 0.16 (much snappier left/right
                                     -- follow, less heavy lag). Applies to near+medium modes
                                     -- (they inherit _base); far mode + chase preset bumped to match.
        fovSmoothness    = 0.35,     -- ZOOM LAG — raised to SLOW the accel/decel FOV change
        lookAheadSpeed   = 0.2,      -- minimal forward-lead at speed (was 1.8) — see more of car
        lookHeight       = 0.75,     -- aim point on the car. Lowered further from 0.95 (raise
                                     -- the car HALF again of the last raise: 1.35→0.95 was 0.40,
                                     -- another 0.20 → 0.75). Lower = car higher in frame.
        lookAheadBase    = 0.60,     -- default idle look-ahead (mode 1 overrides)
        rampMaxSpeedKmh  = 10.0,     -- distance/FOV ramp completes at 10 km/h (was 30)
        fov = { min = 55.0, max = 65.0 },  -- fallback; each mode sets its own below
    },

    -- MODE 0: NEAR (V pos 2) — slightly closer than before (1/5 of the big pull-in)
    [0] = {
        baseDistance     = 6.44,    -- 1/5 of the way in from 7.0 toward 4.2
        distanceTrim     = 0.0,
        minExtraDistance = 0.0,
        maxExtraDistance = 0.0,     -- no distance extension at speed
        maxBaseDistance  = 6.44,    -- locked
        baseHeight       = 1.05,    -- lowered ~0.2 from 1.25 (still felt a bit high at start)
        heightLift       = 0.80,    -- 1/5 of the drop from 0.83
        fov = { min = 54.0, max = 60.0 },  -- 1/5 of the widen from 52..58
        lookAheadBase    = 0.28,
    },

    -- MODE 1: MEDIUM (V pos 3) — balanced
    [1] = {
        baseDistance     = 7.5,     -- increased from 5.5
        distanceTrim     = 0.0,
        minExtraDistance = 0.0,
        maxExtraDistance = 0.0,
        maxBaseDistance  = 7.5,     -- locked at 7.5
        baseHeight       = 1.23,    -- lowered ~0.2 from 1.43 (still felt a bit high at start)
        heightLift       = 1.00,    -- 1/3 of +1.8 added to 0.40 = 0.40 + 0.60 = 1.00
        fov = { min = 50.0, max = 56.0 },
        lookAheadBase    = 0.60,
    },

    -- MODE 2: FAR (V pos 4) — distant
    [2] = {
        baseDistance     = 8.0,     -- increased from 5.5
        distanceTrim     = 0.0,
        minExtraDistance = 0.0,
        maxExtraDistance = 0.0,
        maxBaseDistance  = 8.0,     -- locked at 8.0
        baseHeight       = 1.34,    -- lowered ~0.2 from 1.54 (still felt a bit high at start)
        minHeight        = 0.38,
        heightLift       = 0.80,    -- 1/3 of +1.2 added to 0.40 = 0.40 + 0.40 = 0.80
        fov = { min = 52.0, max = 58.0 },
        lookAheadBase    = 0.80,
        smoothness       = 0.16,     -- raised 0.08 -> 0.16 to match _base (snappier far-mode follow)
        fovSmoothness    = 0.26,
    },
}

-----------------------------------------------------------------
-- MOTION BLUR — three selectable modes (Config.MotionBlur.Mode)
--
--   'glsl'      (DEFAULT) — TRUE radial speed blur via a WebGL post-process
--                 shader on the NUI layer. Samples the live game image through
--                 FiveM's external_texture hook and applies a radial blur:
--                 SHARP CENTER (forward road stays clear), blurred edges
--                 (surroundings streak past), strength smoothly scaled by speed.
--                 This is the "GTA-style pull-back" look. Ignores the in-game
--                 Motion Blur graphics setting entirely. Cost: real GPU work —
--                 can hit perf / tear on low-end clients (tune ResolutionScale
--                 + MaxRadius). Mechanism verified from CitizenFX upstream +
--                 fivem-glsl source, cross-checked with Grok (live) — Jun 2026.
--
--   'raceturbo' — GTA's OWN built-in radial speed-blur post-fx
--                 (AnimpostfxPlay 'RaceTurbo'). Cheap, stable, zero perf cost,
--                 looks like the native turbo/nitro blur. Limits: essentially
--                 on/off (no smooth strength — switched in at a speed threshold
--                 with hysteresis) and carries a slight color/contrast shift.
--
--   'native'    — SET_CAM_MOTION_BLUR_STRENGTH on the scripted cam, speed-
--                 scaled. Real engine blur but SUBTLE and GATED by the player's
--                 Settings > Graphics > Motion Blur Strength (at 0 = nothing).
--
--   'off'       — no motion blur at all.
-----------------------------------------------------------------
Config.MotionBlur = {
    Enabled = true,
    Mode    = 'glsl',   -- 'glsl' | 'raceturbo' | 'native' | 'off'
                        -- Re-testing GLSL with BOTH fixes in: texParameterf (fixes
                        -- the blue placeholder / hook binding) + removed gl.finish()
                        -- and warm-up loop (fixes the jank). If blue still shows,
                        -- the hook doesn't work on this build -> use 'raceturbo'.

    -- ===== GLSL radial blur (mode 'glsl') =====
    -- Speed-scaled true radial blur rendered by html/blur/blur.html. The client
    -- pushes a 0..1 "amount" (speed ramp) to the shader; the shader blurs the
    -- screen edges by up to MaxRadius px, leaving a sharp center hole of radius
    -- SharpRadius (fraction of screen). Higher MaxBlurSamples = smoother but
    -- heavier. ResolutionScale renders the GL backbuffer below native res for
    -- performance (0.5 = half-res; the CSS still fills the screen).
    Glsl = {
        StartKmh        = 40.0,   -- blur starts showing at 40 km/h
        MaxSpeedKmh     = 288.0,  -- full blur reached here (10% lower than 320)
        Opacity         = 0.24,   -- overall blur opacity multiplier (1.0 = full). Lower =
                                  -- more see-through. Raise toward 1.0 for a heavier effect.
        MaxRadius       = 18.0,   -- max edge blur radius in px (at full speed)
        SharpRadius     = 0.28,   -- center sharp zone radius (0..1 of half-diagonal).
                                  -- Below this distance from center = no blur (road clear).
        Feather         = 0.95,   -- how far past SharpRadius the blur ramps to full (0..1).
                                  -- WIDE feather = no visible disc edge; the blur fades in
                                  -- gradually from center to corner instead of a hard ring.
        MaxBlurSamples  = 12,     -- gaussian taps per axis at full blur (perf knob)
        ResolutionScale = 0.5,    -- GL backbuffer scale (0.25..1.0). Lower = faster.
        UpdateThreshold = 0.02,   -- only message the NUI when amount changes by this much
                                  -- (avoids flooding the bridge every frame).
    },

    -- ===== RaceTurbo native post-fx (mode 'raceturbo') =====
    RaceTurbo = {
        Effect        = 'RaceTurbo',
        StartKmh      = 120.0,   -- switch the effect ON above this speed
        HysteresisKmh = 15.0,    -- must drop this far below StartKmh before switching OFF
    },

    -- ===== Native scripted-cam blur (mode 'native') =====
    -- Gated by the in-game Motion Blur Strength setting (0 = invisible).
    Native = {
        StrengthAtIdle     = 0.00,
        StrengthAtTopSpeed = 1.00,
        StartKmh           = 60.0,
        MaxSpeedKmh        = 200.0,
        ForcePipeline      = true,   -- SetForceMotionblur(true) while engaged
    },
}

-----------------------------------------------------------------
-- HIGH-SPEED ZOOM (tunnel vision at extreme speed)
-- FOV widens from 0-160 km/h (building speed feel), then above 160 km/h
-- it progressively NARROWS (zooms in) for a focused, tunnel-vision effect
-- at extreme speed. Vehicles can hit 450+ km/h, so the ramp is wide.
-----------------------------------------------------------------
Config.HighSpeedZoom = {
    Enabled  = true,
    StartKmh = 160.0,   -- begin zoom-in at 160 km/h
    FullKmh  = 400.0,   -- full zoom-in reached at 400 km/h (vehicles go to 450+)
    MaxDeg   = 8.0,     -- max FOV reduction in degrees (modest to avoid claustrophobia)
}

-----------------------------------------------------------------
-- SPEED FOV (per-gear, RPM-driven) — the PRIMARY sense-of-speed cue
-- Instead of pulling the camera back at speed (which always felt off),
-- we widen FOV. The widening is driven by gear PROGRESS, not raw km/h:
--   gearProgress = ((currentGear - 1) + rpm) / highGear   [0..1]
-- So RPM sweeps the FOV up within each gear, drops a touch on the
-- upshift, then climbs again — the repeated surge that sells speed.
-- The actual lo/hi FOV come from the preset's fov.min / fov.max.
-----------------------------------------------------------------
Config.SpeedFov = {
    Enabled       = true,
    MaxSpreadDeg  = 10.0,   -- hard clamp: (fov.max - fov.min) never exceeds this
    GearFovStep      = 0.2,     -- cumulative FOV widen per gear step
    FovCapKmh     = 160.0,  -- FOV stops widening at 160 km/h (high-speed zoom-in takes over)
    -- Within-gear RPM range that maps to the gear's FOV slice. Real engines
    -- idle ~0.2 and redline ~1.0; remap so the bottom of each gear isn't dead.
    RpmFloor      = 0.20,
    RpmCeil       = 1.00,
}

-----------------------------------------------------------------
-- G-FORCE SPRING — the Forza dynamics that sell CHANGES in velocity.
-- Computed from frame-to-frame velocity delta, projected onto the car's
-- local forward (longitudinal) and right (lateral) axes:
--   * Hard accel   -> camera eases BACK + slight pitch up (car pulls away)
--   * Hard braking -> camera compresses IN + nose-dive pitch down
--   * Cornering    -> lateral shift + roll toward the outside
-- All offsets are small and lerped, so it's a lean, not a lurch.
-----------------------------------------------------------------
Config.GForce = {
    Enabled        = true,
    -- Longitudinal (accel/brake). Units: metres of cam offset per (m/s^2).
    AccelPullBack  = 0.008,  -- boosted for acceleration pull-away feel  -- boosted for acceleration pull-away feel -- cut 50% (was 0.003)
    BrakePushIn    = 0.004,  -- DOUBLED back (was 0.003) — stronger brake pull-back shake
    MaxLongOffset  = 0.10,   -- more room for accel pull-back   -- more room for accel pull-back   -- raised back (was 0.02) so the stronger brake push has room
    -- Pitch: nose-dive under braking, slight lift under accel. Applied by
    -- nudging the LOOK-TARGET height (stays within the PointCamAtCoord model,
    -- so it can't trigger the look-flip). Units: metres of look-height per m/s^2.
    PitchPerG      = 0.0065,   -- cut 50% (was 0.02)
    MaxPitchOffset = 0.081,  -- cut 50% (was 0.25)
    -- Lateral (cornering): extra sideways shift toward the outside of the
    -- turn, on top of the velocity-based lateralFactor sway. Metres per m/s^2.
    LatShiftPerG   = 0.005,  -- added back half the gap to original (0.0225 -> halfway to 0.030)
    MaxLatShift    = 0.049,   -- clamp lateral g shift (m)
    LatFullSpeedKmh = 320.0, -- speed at which lateral sway reaches full strength (cap 30% higher)
    LatMinScale    = 0.0,    -- (unused, replaced by dead zone)
    LatDeadZoneKmh = 30.0,   -- no lateral sway below this speed
    LatOverallScale = 0.018,  -- global lateral strength multiplier (55% * 65% = 36%)   -- clamp lateral g shift (m). Cut ~35% (0.60 -> 0.39) to match
                             -- the shorter lateralFactor swing range.
    Smoothing      = 0.12,   -- tau (sec) for smoothing the accel estimate; kills spikes
    -- CRASH GUARD: clamp raw accel reading before smoothing. Hard collisions
    -- spike velocity-delta to thousands of m/s² in one frame, flipping the camera.
    MaxRawAccel    = 20.0,   -- cap at ±20 m/s² (real cars stay within this)
}

-----------------------------------------------------------------
-- AIRBORNE CAMERA (Forza-style jump behavior)
-- When all wheels leave the ground, the camera switches to a more
-- locked, stable mode: lateral sway + rotational inertia are reduced
-- or disabled (prevents mid-air flip-flop), pitch following is stronger
-- (tracks the car's nose angle in the air), and a landing shake fires
-- when the wheels touch back down. Keeps the camera focused forward
-- on the car instead of swinging wildly during jumps.
-----------------------------------------------------------------
Config.Airborne = {
    Enabled = true,

    -- Height threshold (metres above ground) to consider "airborne" if the
    -- wheels-on-ground check alone isn't enough (handles launch frames).
    -- RAISED to 1.5 from 0.5: muscle cars with tuned handling.meta do a drag
    -- wheelie (front lifts) at high RPM launch — IsVehicleOnAllWheels goes false
    -- but the car is NOT truly airborne. A higher threshold prevents the airborne
    -- mode from engaging on a partial front-wheel lift.
    HeightThreshold = 1.5,
    -- MUSCLE CAR OVERRIDE: muscle cars (vehicle class 4) have extreme torque that
    -- lifts the front under accel AND causes body pitch under hard braking, making
    -- IsVehicleOnAllWheels unreliable. Use a MUCH higher threshold (3.0m) so only
    -- real jumps trigger airborne, not wheelies or brake dive.
    MuscleHeightThreshold = 3.0,

    -- LATERAL SWAY: reduce the velocity-driven side-to-side camera swing
    -- while in the air so it doesn't drift off to the side mid-jump.
    -- 0 = completely disable, 1 = normal ground behavior.
    LateralSwayScale = 0.1,

    -- ROTATIONAL INERTIA: reduce or disable the yaw lag/lead effect while
    -- airborne so the camera stays locked behind the car instead of lagging
    -- as the car rotates in the air (the "flip flop" the user wants gone).
    -- 0 = disable inertia (locked), 1 = normal ground behavior.
    RotationalInertiaScale = 0.0,

    -- PITCH FOLLOWING: boost how much the camera follows the vehicle's nose
    -- angle (pitch) while airborne so flips/jumps feel visceral and you see
    -- the car rotate clearly. Multiplier on top of normal PitchFollow strength.
    PitchFollowMultiplier = 1.8,

    -- CAMERA HEIGHT: extra height added to the camera while airborne so the
    -- framing doesn't compress as the car rises (keeps the car in view).
    ExtraHeight = 0.3,

    -- LANDING IMPACT: shake + compression when the wheels touch back down.
    LandingShake = true,
    LandingShakeIntensity = 0.7,    -- shake strength
    LandingShakeDurationMs = 250,   -- how long the shake lasts
    LandingShakeName = 'ROAD_VIBRATION_SHAKE',  -- GTA shake type
}

-----------------------------------------------------------------
-- DRAG LAUNCH CAMERA (Launch Control / Drag Start)
-- Special camera mode that only activates during drag racing starts:
-- handbrake + throttle at low speed in low gear. Camera zooms in and
-- raises FOV with RPM (building tension), then smoothly releases back
-- to normal chase when handbrake drops (the dramatic launch moment).
-----------------------------------------------------------------
Config.DragLaunch = {
    Enabled = true,

    -- ENGAGEMENT CONDITIONS (all must be true, VERY STRICT):
    MaxSpeedKmh    = 0.5,    -- must be at complete stop
    MaxGearLow     = 2,      -- max gear if car has ≤6 gears
    MaxGearHigh    = 3,      -- max gear if car has ≥7 gears
    -- ARM SEQUENCE: handbrake must be engaged TWICE at static 0 km/h (double-tap).
    -- Hold handbrake → release → hold again = armed. Then throttle activates staging.
    -- Brake held at any point = reset (real LC doesn't use brake, just clutch).
    -- Timeout: 5s after arming without throttle = reset.

    -- STAGING PHASE (handbrake + throttle held, after double-tap arm):
    ZoomInDistance   = 6.4,    -- camera distance while staging (closer than normal chase).
    MaxFovIncrease   = 8.8,   -- bumped for more dramatic LC staging FOV    -- max FOV RAISE at redline RPM (effect at 40% of original).
    ShakeIntensity   = 0.48,   -- max shake strength (effect at 40% of original).
    ShakeName        = 'HAND_SHAKE',
    ZoomInTau        = 0.60,   -- tau for zoom-in easing. Faster start so it doesn't feel
                               -- "late" — still smooth but responds within ~0.5s of arming.
    FovInTau         = 0.45,   -- tau for FOV raise easing. Responds promptly to RPM.

    -- LAUNCH PHASE (handbrake released):
    ReturnSpeed      = 0.0125, -- base return for DISTANCE zoom-out. 60% slower (0.02 × 0.625).
    ReturnVelScale   = 2.0,    -- velocity multiplier on distance return.
    FovReturnMinSec  = 0.47,    -- FOV return duration at full speed. 60% slower (1.0 × 1.6).
    FovReturnMaxSec  = 0.93,   -- FOV return duration at zero speed. 60% slower (1.8 × 1.6).
    FovReturnVelRefKmh = 45.0, -- velocity at which the return hits the MIN (fastest) time.
    ExitSpeedKmh     = 40.0,   -- speed (km/h) the car must reach for the mode to exit after
                               -- the FOV return completes. If the launch is successful the car
                               -- hits this quickly; if it stalls, a 6s timeout exits anyway.
                               -- This ensures the smooth FOV transition plays out fully.
}

-----------------------------------------------------------------
-- CORNERING DYNAMICS (Forza-style camera behavior in turns)
-- Combines steering angle + lateral G-force to create camera roll (tilt into
-- corners) and rotational inertia (camera heading lags behind car). The
-- middle ground between Forza Motorsport (subtle/sim) and Forza Horizon
-- (moderate/fun). Requires SetCamRot instead of PointCamAtCoord for roll.
-----------------------------------------------------------------
Config.Cornering = {
    Enabled = true,  -- re-enabled (pitch/yaw math fixed)

    -- Resting (flat-ground) pitch trim. <1.0 = slightly less downward tilt so the
    -- camera sits a touch more level and shows more road ahead.
    NormalPitchScale = 0.90,  -- 10% less resting down-tilt

    -- Camera Roll: tilts/banks into corners like Forza
    Roll = {
        Enabled         = true,
        MaxDegrees      = 1.0,      -- raised from 0.125 (was almost invisible). Camera banks
                                    -- INTO the turn (opposite direction: turn left, roll right).
                                    -- User wants "vehicle tilt left/right more when it turn."
        SteeringWeight  = 0.4,      -- steering angle contributes 40% (anticipation)
        GForceWeight    = 0.6,      -- lateral G-force contributes 60% (realism)
        Smoothing       = 0.15,     -- tau (sec) for roll spring damping
        MinSpeedKmh     = 15.0,     -- no roll below this speed (parking lot turns)
    },

    -- Rotational Inertia: camera heading lags/leads the car heading so the car VISIBLY
    -- rotates in frame during turns. TWO-STAGE: a lagged tracker builds the raw offset
    -- (Strength-scaled, velocity-scaled, hard-capped), then the APPLIED offset eases in
    -- with a slow ATTACK (no sudden kick — keyboard steering is instant) and curves
    -- back to centre with a separate RELEASE (no snap). Separate from RearSwing.
    RotationalInertia = {
        Enabled    = true,   -- Re-enabled (heading-snap correction now handles the pivot bug)
                                 -- latency on the whole left/right feel.
        LeapTime   = 0.15,       -- LEAP DELAY (sec): effect kicks in this long AFTER you start
                                 -- turning. Lowered 0.35 -> 0.15 (much less "wait before it
                                 -- moves"). 0 = off (instant).
        AttackTime = 0.32,       -- tau (sec) to RAMP THE TURN IN. Cut from 0.6 — it was too
                                 -- slow / felt laggy. Still progressive (no instant kick) but
                                 -- responds much sooner.
        ReleaseTime = 0.22,      -- tau (sec) to CURVE BACK to centre. Lowered from 0.3 to match
                                 -- the snappier attack (still smooth, no sudden snap).
        Strength   = 0.13,       -- overall magnitude. Added back ~20% (0.11 -> 0.13) — slightly
                                 -- more responsive motion.
        MaxDeg     = 0.42,       -- HARD CAP (deg) on the inertia offset — the RANGE. Cut ~35%
                                 -- (0.65 -> 0.42) to match the shorter left/right swing.
        FullSpeedKmh = 120.0,    -- velocity progression: offset reaches full range at this speed.
        MinScale   = 0.15,       -- range scale at 0 km/h (low speed = less). 1.0 at FullSpeedKmh.
        Invert     = true,       -- flip rotation direction (camera LEADS instead of lags).
        -- PROGRESSIVE CENTER SHARPENING (release only): as the offset returns toward
        -- centre, the release tau smoothly blends DOWN to CenterSharpTime so the last
        -- stretch is much sharper — kills the loose float/bounce around the middle.
        -- Smooth blend (NOT a hard switch) so there's no velocity hitch. Acts across
        -- the whole CenterSharpThreshold range, not just at the very end.
        CenterSharpThreshold = 0.45, -- deg from centre over which the sharpening ramps in
        CenterSharpTime      = 0.015,-- tau (sec) at dead-centre — very sharp (smaller = sharper)
        CenterDeadband       = 0.02, -- snap offset to exactly 0 below this (deg) — kills shimmer
    },

    -- Cornering FOV Dip: narrow the FOV slightly while turning, returning to the current
    -- state's FOV (whatever the speed/gear/view-mode FOV is) when you straighten. Driven
    -- by the same eased + velocity-scaled turn magnitude as RotationalInertia, so it only
    -- engages when actually carrying speed into a corner and ramps up progressively.
    TurnFov = {
        Enabled   = true,
        MaxFovDip = 1.2,         -- max degrees of FOV narrowing at full turn (subtle). The
                                 -- dip is (MaxFovDip × turnFactor²) so it scales up smoothly.
    },

    -- Rear-Swing: rotate the camera's behind-the-car POSITION toward the inside of
    -- the turn so the rear three-quarter (bumper/spoiler + a bit of door) swings into
    -- view — the Forza cornering reframe. CAP & HOLD model: the swing ramps in only
    -- up to HoldSteerDeg of steering, then PINS at MaxAngleDeg and holds — it does
    -- NOT keep tracking the wheels toward full lock. Returns faster than it engages.
    RearSwing = {
        Enabled     = true,
        MaxAngleDeg = 0.042,    -- max camera swing around the car (deg). Cut ~35% (0.55 -> 0.36)
                               -- to match the shorter overall left/right swing range.
        HoldSteerDeg = 8.0,    -- steering angle (deg) at which the swing hits MaxAngleDeg and
                               -- HOLDS. Past this the angle is pinned (no tracking to max lock).
        Smoothing   = 0.16,    -- tau (sec) for easing the swing IN (kept slow — not rapid)
        ReturnSmoothing = 0.045,-- tau (sec) for easing the swing OUT. Lowered from 0.08 —
                               -- user wants it to return to the MIDDLE faster when straightening.
        MinSpeedKmh = 10.0,    -- no rear-swing below this speed (parking maneuvers)
    },

    -- Cornering Shake: subtle shake when turning hard at speed
    Shake = {
        Enabled         = true,
        MinSpeedKmh     = 80.0,     -- activate above this speed
        MinSteeringDeg  = 15.0,     -- activate above this steering angle
        MaxIntensity    = 0.30,     -- max shake strength (subtle)
    },

    -- Vehicle Pitch Following: camera pitch tracks vehicle nose angle
    -- (uphill/downhill/bumps) for more terrain feedback.
    PitchFollow = {
        Enabled     = false,  -- disabled: stabilizer handles terrain now
        Strength    = 0.22,         -- legacy fallback (used if StrengthUp absent)
        StrengthUp  = 0.05,         -- UPHILL multiplier (nose up): kept LOW so the camera
                                    -- doesn't tilt up with the nose and push the car to
                                    -- the bottom of the screen on climbs
        StrengthDown = 0.08,        -- DOWNHILL multiplier (nose down): reduced from 0.85.
                                    -- 0.85 was tilting the cam DOWN harder than clearance
                                    -- could correct — net result was camera looking at ground.
                                    -- Clearance (+tilt up) is now the dominant effect on descents.
        Smoothing   = 0.50,         -- tau (sec) for smoothing (bumpy road damping). Raised
                                    -- to 0.50 — the up/down tilt was still too sensitive; this
                                    -- makes it much more damped / less reactive
        MaxDegrees  = 30.0,         -- clamp pitch contribution (steep slopes)
        MaxRateDegPerSec = 10.0,    -- slew-rate limit: cap how fast smoothedPitch can move
                                    -- (deg/sec). Lowered to 10 so curb/bump jolts are
                                    -- flattened harder; real hills build slow so unaffected.
        Deadzone    = 1.5,          -- ignore nose angles below this (deg) — kills the
                                    -- flat-road bobbing from small suspension movements.
                                    -- Real hills exceed this; tiny bumps don't.
        -- SPEED SCALING: the whole pitch-follow tilt ramps IN with speed, reaching
        -- full effect at ClearanceFullSpeedKmh and capping there. At low speed it's
        -- near zero, so hitting a curb/bump while slow no longer lurches the camera.
        ClearanceFullSpeedKmh = 120.0,  -- tilt is full at 120 km/h, capped above (no more
                                        -- scaling past this — the "top speed value")
        -- SLOPE VIEW CLEARANCE: extra tilt AGAINST the slope so the car body doesn't
        -- block the road. Downhill -> tilt up; uphill -> tilt down. Scales with slope
        -- steepness and vehicle roof height.
        ClearanceBaseDeg   = 16.0,  -- base extra tilt (deg) at full slope. Raised from 8 —
                                    -- downhill was barely visible. This is the down-tilt
                                    -- magnitude reached at ClearanceFullDeg of slope.
        ClearanceHeightGain = 8.0,  -- extra tilt (deg) per metre of roof height above ref
                                    -- (raised from 6.0 so tall vehicles clear even more)
        ClearanceFullDeg   = 8.0,   -- slope angle (deg) at which the clearance is maxed.
                                    -- Lowered from 12.0 so even a gentle descent gets near
                                    -- full upward tilt (you need the view sooner, not only
                                    -- on steep drops)
        DownhillClearanceScale = 0.6, -- DOWNHILL look-angle (tilts UP to lift view onto road).
                                      -- Cut from 1.0 — the range was way too high (camera
                                      -- aimed at the sky/ceiling). Lower = less up-tilt.
        DownhillMaxDeg = 4.3,         -- HARD CAP (deg) on the downhill up-tilt. Reduced another
                                      -- 20% (5.4 -> 4.3) — less "highness" on descents.
        UphillClearanceScale = 0.25, -- HALVED from 0.5 to compensate for ClearanceBaseDeg
                                    -- doubling (8→16): keeps uphill's net tilt the same as
                                    -- before (which was good), while downhill gets the boost.
    },
}

-----------------------------------------------------------------
-- ADAPTIVE SIZING
-- We read the real bounding box at runtime with GetModelDimensions
-- (works for every custom/addon vehicle the server has, no need to
-- parse vehicle.meta). length = maxY-minY is the reliable axis.
-- Factors are clamped so giant addon trucks/buses don't break framing.
-----------------------------------------------------------------
Config.Adaptive = {
    Enabled = true,
    RefLength = 5.0,        -- a "normal" sports car is ~5m long; everything scales off this
    RefHeight = 2.3,        -- (legacy heightFactor ref) kept neutral; roof anchoring below
                            -- is what actually handles tall vehicles now
    LengthFactorMin = 0.70, -- clamp so a tiny car isn't on top of itself
    LengthFactorMax = 2.40, -- clamp so a bus/truck doesn't fly the cam to orbit
    HeightFactorMin = 0.85, -- PINNED at 0.85 (what normal cars already used) so the
    HeightFactorMax = 0.85, -- baseHeight framing is unchanged for normal cars. Tall
                            -- vehicles are handled by roof anchoring below, NOT by
                            -- scaling baseHeight (which caused the top-down stare).
    -- ROOF ANCHORING: the vehicle's roof height (maxDim.z) above which the camera
    -- AND the look target both rise together, keeping the viewing ANGLE identical
    -- across a low coupe and a tall SUV. RefRoofZ = roof height of a "normal" car
    -- (~0.75m above origin); taller roofs lift the framing, shorter ones don't drop it.
    RefRoofZ = 0.75,
}

-----------------------------------------------------------------
-- PRESETS
-- "free"  = manual per-frame positioning with lerp (the weighty,
--           reactive Motorfest feel). Used for chase & cinematic.
-- "bone"  = attached to a vehicle bone (bonnet/bumper) with forced
--           rotation follow each frame for a clean locked feel.
--
-- smoothness: lerp factor 0..1. LOWER = more inertia / lag / weight.
--             This is the single most important "feel" knob.
-----------------------------------------------------------------
Config.Presets = {
    chase = {
        type = 'free',
        -- DISTANCE: primarily captured from GTA's own follow-cam (the V-key
        -- view distance) at runtime so transitions back to gameplay are seamless.
        -- baseDistance/maxBaseDistance are only a FALLBACK when the read is
        -- implausible (first-person view, or out of the sane band).
        useGtaDistance   = true,
        distanceTrim     = 0.00,   -- small nudge added to the captured GTA distance
        baseDistance     = 4.80,   -- fallback only (used if GTA distance unreadable)
        maxExtraDistance = 0.00,   -- accel zoom-out OFF — FOV is the speed cue, not distance
        maxBaseDistance  = 5.50,   -- hard cap on final distance (after capture+trim+extra)
        baseHeight       = 1.64,   -- +0.5 from 1.14
        minHeight        = 0.56,   -- camera height never drops below this (stops "looking at roof")
        heightLift       = 0.68,
        heightDropAtSpeed = 0.4,
        lookHeight       = 1.0,
        lookAheadBase    = 1.20,   -- how far ahead of the car the cam aims at idle
        lookAheadSpeed   = 3.5,
        -- FOV is the PRIMARY sense-of-speed cue now, driven per-gear by RPM.
        -- min = idle/low-gear, max = top-gear redline. Spread is hard-clamped
        -- to <=10 deg in code. Widens with speed (Forza-style).
        fov = { min = 63.0, max = 68.0 },  -- narrower spread (was 55..63)
        maxSpeedKmh      = 155.0,   -- still used for accel-extra-distance + shake ramp
        smoothness       = 0.16,    -- raised 0.06 -> 0.16 (chase-preset fallback; matches _base)
        fovSmoothness    = 0.1,
        lateralFactor    = 0.063,   -- side-to-side sway RANGE. Cut ~35% (0.815 -> 0.53) for a
                                   -- shorter left/right movement range (less sideways swing).
        shakeAtSpeedKmh  = 120.0,  -- only shake at genuinely high speed (was 95)
        shakeMax         = 0.08,   -- much subtler shake (was 0.18)
        shakeName        = 'HAND_SHAKE',
    },
    bonnet = {
        type = 'bone',
        bones    = { 'bonnet', 'engine', 'chassis' },
        offset   = vector3(0.00, 1.80, 0.65),
        rotOffset = vector3(-8.0, 0.0, 0.0),
        fov = 72.0,  -- fallback if fovByMode missing
        fovByMode = { [0] = 68.0, [1] = 72.0, [2] = 78.0 },  -- V-key: near/medium/far
        reverseFovByMode = { [0] = 62.0, [1] = 66.0, [2] = 72.0 },  -- V-key FOV when C-key reverse
        smoothness = 0.180,
        followRoll = true,
        rollDamp = 0.85,
    },
}

-----------------------------------------------------------------
-- PER-VEHICLE CUSTOM PRESETS
-- For vehicles needing manual tuning (oddly-sized addons, bikes, trucks).
-- Keyed by spawn name, lowercase. Resolved at runtime against the model
-- hash. Only list the fields you want to change; they merge over the base
-- preset. Two shapes are supported (see README for full examples):
--   per-preset:  ['adder'] = { chase = {..}, bonnet = {..} }
--   global:      ['faggio'] = { baseDistance = 4.0, baseHeight = 1.5 }
-- Nested values (fov, offset) are replaced wholesale; give the full table.
-----------------------------------------------------------------
Config.VehiclePresets = {}  -- DISABLED for now (was causing distance issues)

-----------------------------------------------------------------
-- NOTIFICATIONS
-- Lightweight on-screen feedback. Set Enabled=false to silence.
-----------------------------------------------------------------
Config.Notify = {
    Enabled    = true,
    OnPreset   = true,    -- show preset name when you cycle
    OnArm      = true,    -- show "Race cam armed/disarmed"
    Duration   = 1500,
}

-----------------------------------------------------------------
-- DEBUG
-----------------------------------------------------------------
Config.Debug = false      -- prints idle/engage state + draws cam params on screen

-----------------------------------------------------------------
-- MUSCLE CAR CAMERA (entity-transform-based positioning)
-- For vehicles with muscle-type handling, the camera uses the entity's own
-- transform matrix for positioning (GetOffsetFromEntityInWorldCoords) instead
-- of heading-based computation. This keeps the cam perfectly synced with the
-- entity's actual rotation and eliminates the GTA engine bug where scripted
-- cams desync with muscle car steering under handbrake. All chase effects
-- (FOV, shake, inertia, etc.) still apply — only the position/rotation BASE
-- is different.
-----------------------------------------------------------------
Config.MuscleCamera = {
    PitchDampen = 0.30,     -- how much the camera follows the muscle car's nose pitch.
                            -- 0.3 = 30% follow (heavily dampened — muscle cars pitch
                            -- aggressively under torque, full follow = camera chaos).
                            -- 0 = completely level, 1 = full vehicle pitch follow.

    -- HYBRID MODE (recommended for muscle cars):
    -- Instead of using RenderScriptCams (which desynchronizes with the b1604 wheelie
    -- physics hardcode on VC_MUSCLE), enhance the NATIVE gameplay camera directly.
    -- The native cam pipeline was designed to handle muscle car physics; we just tweak
    -- its FOV and view mode for a more cinematic feel without the heading-snap bug.
    -- When true: muscle cars NEVER enter RenderScriptCams. Instead we manipulate
    -- the native follow-cam (FOV, view mode, relative heading) while it renders.
    UseHybridMode = false,   -- DISABLED: physics management layer handles muscle cars now
    HybridFov     = 60.0,   -- FOV override for the native cam in hybrid mode
    HybridViewMode = 1,     -- follow-cam view mode to force (0=near, 1=medium, 2=far)
}

-----------------------------------------------------------------
-- MUSCLE CAR MODEL LIST (for the handbrake-disengage workaround)
-- Spawn names of vehicles that have muscle-type handling.meta regardless of
-- their vehicles.meta <vehicleClass>. GetVehicleClass == 4 catches standard
-- muscle cars; this list catches yours that were re-classed to sport/super.
-- Case-insensitive. Add your custom muscle car spawn names here.
-----------------------------------------------------------------
Config.MuscleCarModels = {
    -- ===== YOUR CUSTOM MUSCLE CARS (re-classed to sport but still muscle handling) =====
    -- Add spawn names here, e.g.:
    -- 'hkinterceptor',
    -- 'yourmusclecar2',

    -- ===== ALL VANILLA GTA V MUSCLE CARS =====
    'blade', 'buccaneer', 'buccaneer2', 'chino', 'chino2',
    'clique', 'coquette3', 'deviant', 'dominator', 'dominator2',
    'dominator3', 'dominator4', 'dominator5', 'dominator6', 'dominator7',
    'dominator8', 'dukes', 'dukes2', 'dukes3', 'ellie',
    'faction', 'faction2', 'faction3', 'gauntlet', 'gauntlet2',
    'gauntlet3', 'gauntlet4', 'gauntlet5', 'hermes', 'hotknife',
    'hustler', 'impaler', 'impaler2', 'impaler3', 'impaler4',
    'imperator', 'imperator2', 'imperator3', 'lurcher', 'moonbeam',
    'moonbeam2', 'nightshade', 'peyote2', 'phoenix', 'picador',
    'ratloader', 'ratloader2', 'ruiner', 'ruiner2', 'ruiner3',
    'ruiner4', 'sabregt', 'sabregt2', 'slamvan', 'slamvan2',
    'slamvan3', 'slamvan4', 'slamvan5', 'slamvan6', 'stalion',
    'stalion2', 'stampede', 'tampa', 'tampa3', 'tulip',
    'tulip2', 'vamos', 'vigero', 'vigero2', 'virgo',
    'virgo2', 'virgo3', 'voodoo', 'voodoo2', 'yosemite',
    'yosemite2', 'yosemite3',
}

-----------------------------------------------------------------
-- MUSCLE CAR CAMERA SMOOTHING
-- Pitch rate limiter smooths camera response to violent pitch changes
-- on muscle cars. Camera-side only — no handling modification.
-----------------------------------------------------------------
Config.MusclePhysics = {
    Enabled = false,   -- handling caps DISABLED (issue was a custom vehicle's handling.meta)

    -- === PITCH RATE LIMITING (camera-side, smooths violent pitch spikes) ===
    PitchRateLimit = {
        MaxDegPerSec       = 45.0,
        Smoothing          = 0.12,
    },
}
