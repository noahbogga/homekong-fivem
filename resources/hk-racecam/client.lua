-----------------------------------------------------------------
-- hk-racecam :: client.lua
--
-- Motorfest-style dynamic vehicle camera with idle engagement.
--
-- DESIGN (the part that makes this not feel "bolted on"):
--  * One persistent DEFAULT_SCRIPTED_CAMERA, never destroyed/recreated
--    on every preset switch.
--  * "free" presets are positioned manually each frame from the
--    vehicle's forward vector + velocity, then LERPED toward. The lag
--    in that lerp is the weight/inertia the old race-cam repo lacked
--    (it did a raw SetCamRot copy with zero damping).
--  * Look input is never permanently stolen. We watch the disabled
--    look-control normals; idle -> ease in, any input -> ease out.
--
-- Natives + signatures verified against docs.fivem.net (citizenfx/natives).
-----------------------------------------------------------------

local STATE = {
    armed        = false,   -- race-cam MODE enabled (player opted in)
    engaged      = false,   -- cam currently rendering (idle long enough)
    cam          = nil,
    preset       = Config.DefaultPreset,
    lastLookMs   = 0,       -- GetGameTimer() of last detected look input
    curPos       = vector3(0.0, 0.0, 0.0),
    curFov       = 50.0,
    -- Intermediate (first-stage) smoothed targets, for the cascaded
    -- 2nd-order smoothing that removes jitter without adding raw lag.
    smPos        = nil,     -- smoothed target position (stage 1)
    smFov        = nil,     -- smoothed target fov (stage 1)
    smSf         = 0.0,     -- smoothed speed factor (kills per-frame speed jitter)
    vehParams    = nil,     -- cached adaptive sizing for current vehicle
    vehParamsFor = 0,       -- entity handle the cache belongs to
    attachedBone = nil,     -- bone index the cam is currently attached to (nil = detached/free)
    shakeActive  = false,   -- whether ShakeCam is currently running (so we modulate vs restart)
    prevGear     = -1,      -- last seen gear, for detecting shifts
    shiftAtMs    = 0,       -- GetGameTimer() when the last gear shift fired (drives the dip)
    shiftWasUp   = false,   -- true if last shift was an upshift
    prevHandbrake = false,  -- last seen handbrake state, for rising-edge detection
    handbrakeAtMs = 0,      -- GetGameTimer() when the handbrake punch fired (drives the dip)
    reversing    = false,   -- true while the car is actually moving backward
    lookBehind   = false,   -- true while C is held (look-behind control)
    -- Per-vehicle preset cache (triple cross-check: entity + preset name + model hash)
    resolvedPreset = nil,
    resolvedFor    = { veh = 0, preset = '', hash = 0 },
    motionLocked = false,   -- DEFAULT UNLOCKED: start with static framing (frozen sway/zoom).
                            -- F4 toggles to unlocked (full dynamic movement) and back.
    lockedDist   = nil,     -- distance/height/fov snapshot captured at lock time
    lockedHeight = nil,
    lockedFov    = nil,
    -- GTA follow-cam distance capture (the V-key view distance)
    baselineDist = nil,     -- captured distance at engage-time (medium view, mode 1)
    currentViewMode = 1,    -- last seen GetFollowVehicleCamViewMode() int
    lastThirdPersonMode = 1, -- last non-first-person mode (for restore on exit)
    -- Motion blur state (multi-mode). blurMode tracks the active mode so a
    -- mode switch tears down the previous one; the rest track per-mode effects.
    blurMode       = nil,    -- last applied Config.MotionBlur.Mode
    blurGlslOn     = false,  -- GLSL NUI overlay currently active
    blurGlslAmount = -1.0,   -- last amount sent to the NUI (-1 = none sent)
    blurFxActive   = false,  -- RaceTurbo screen effect currently playing
    blurForced     = false,  -- SetForceMotionblur(true) currently active ('native')
    -- G-force spring: smoothed local-frame acceleration estimate
    prevVel      = nil,     -- last frame's velocity vector (for accel delta)
    accelLong    = 0.0,     -- smoothed longitudinal accel (m/s^2, +fwd / -brake)
    accelLat     = 0.0,     -- smoothed lateral accel (m/s^2, +right / -left)
    -- Cornering dynamics: camera roll + rotational inertia
    currentRoll  = 0.0,     -- smoothed camera roll angle (degrees)
    currentYaw   = 0.0,     -- smoothed camera yaw angle (degrees, for rotational lag)
    rearSwingDeg = 0.0,     -- smoothed cornering rear-swing angle (degrees, Forza reframe)
    engageAtMs   = nil,     -- GetGameTimer() at engage; drives the slow-blend transition window
    corneringShakeActive = false,  -- cornering shake state
    wasReversing = false,   -- track reverse->forward transition to re-seed yaw/roll
    reverseTrueSinceMs = 0,  -- GetGameTimer() when raw reverse condition first went true (debounce)
    camPointing  = false,   -- true while PointCamAtCoord owns rotation (reverse cam); must
                            -- StopCamPointing before SetCamRot will take effect again
    yawTransitionFrames = 0,  -- frames since engage/transition; instant yaw for first few
    -- Airborne state: track wheels-off-ground for the Forza-style jump camera + landing shake
    wasAirborne  = false,   -- previous-frame airborne state, for landing-transition detection
    landingShakeUntil = 0,  -- GetGameTimer() the landing shake runs until
    airborneFactor = 0.0,   -- smoothed 0..1 airborne blend (eases the behavior in/out)
    -- Drag Launch Mode: staging camera for launch control / drag starts
    dragLaunchActive = false,
    dragLaunchStage  = "idle",  -- "idle", "staging", "launching"
    dragLaunchStartMs = 0,
    dragLaunchFiredMs = 0,
    dragAbortSinceMs = nil,
    originalFov      = 50.0,
    dragShakeActive  = false,
    dragDist         = nil,     -- working camera distance during drag mode (zooms in/out)
    dragDistLast     = nil,     -- last drag distance, to seed re-entry without a jump
    dragFovProgress  = 0.0,
    dragFovOffset   = 0.0,    -- LC FOV overlay (added to normal FOV)
    -- Drift cam overlay state
    driftActive     = false,  -- hk-handling drift mode held
    driftSlipDeg    = 0.0,    -- smoothed slip angle (degrees)
    driftFactor     = 0.0,    -- smoothed 0..1 drift strength
    driftYawOffset  = 0.0,    -- smoothed yaw blend offset (degrees)
    driftDistOffset = 0.0,    -- smoothed distance add
    driftHeightOffset = 0.0,  -- smoothed height add
    driftRollOffset = 0.0,    -- smoothed roll offset
    driftFovOffset  = 0.0,    -- smoothed FOV offset (slip-based + key-hold)
    driftLateralOffset = 0.0, -- smoothed lateral shift (NFS-style side pan)
    driftSmoothedDirX = nil,   -- smoothed orbit base direction (anti-snap on car straighten)
    driftSmoothedDirY = nil,
    driftLastPivot = 0.0,      -- last active pivot value (for smooth exit)
    orbitStrength  = 0.04,     -- smoothed unified orbit blend
    driftMix       = 0.0,      -- 0=pure chase orbit, 1=full drift orbit layer
    orbitPivot     = 0.0,      -- smoothed unified pivot
    driftLastOrbitX = nil,     -- last active orbit direction (for smooth exit)
    driftLastOrbitY = nil,
    driftGauge      = 0.0,  -- smooth accumulator for key hold (0..1)
    driftReleaseAt  = nil,  -- timestamp of last key release (hold timer)
    driftPressAt    = nil,  -- timestamp of key press (engage delay)
    dragDistOffset  = 0.0,    -- LC distance overlay
    dragHeightOffset = 0.0,   -- LC height overlay
    dragPitchOffset = 0.0,    -- LC pitch overlay (degrees)
    dragDistAtRelease = 0.0,
    dragHeightAtRelease = 0.0,
    dragPitchAtRelease = 0.0,     -- 0..1 progress of the FOV return (timed ease)
    -- Vehicle pitch following: smoothed vehicle nose angle for uphill/downhill feedback
    smoothedVehiclePitch = 0.0,
    -- Rotational-inertia leap delay: ring buffer of recent {ms, targetYaw} samples so the
    -- inertia can be driven by the heading from LeapTime ago (delayed onset of the effect).
    yawHist = {},
    appliedYawOffset = 0.0,
    -- Reverse drift-guard tracking: timestamps of the last throttle press and the
    -- last forward motion. A handbrake drift's brief backslide happens right after
    -- powering forward, so recent throttle + recent forward motion = drift, not reverse.
    lastThrottleMs = 0,
    lastForwardMs  = 0,
    -- Smoothed V-key mode scale for FrontChase transitions
    fcModeScale  = 1.0,
    -- Look-exit debounce: sustained mouse movement required to disengage
    lookStartMs  = 0,   -- when continuous looking started (0 = not looking)
    disengageAtMs = 0,  -- timestamp of last mouse-triggered disengage (cooldown)
    lastVehPos   = nil,  -- previous frame vehicle position (teleport detection)
    engageNextFrame = false, -- F7 requests engage on next main-loop frame
    -- Stabilizer state
    stabSmoothedZ = nil,    -- smoothed world Z for height damping
    stabPrevPitch = nil,    -- previous frame's pitch for rate limiter
}

-----------------------------------------------------------------
-- Small helpers
-----------------------------------------------------------------
local function lerp(a, b, t) return a + (b - a) * t end

local function lerpVec(a, b, t)
    return vector3(lerp(a.x, b.x, t), lerp(a.y, b.y, t), lerp(a.z, b.z, t))
end

local function clamp(v, lo, hi)
    if v < lo then return lo elseif v > hi then return hi else return v end
end

-- Airborne detection: returns true if the vehicle is genuinely airborne (all wheels
-- off ground AND significantly above the terrain). Using AND (not OR) so a muscle-car
-- drag wheelie (front lifts, rear still planted) doesn't falsely trigger airborne mode.
-- MUSCLE CAR FIX: muscle cars (class 4) have high torque that lifts the front under
-- accel/brake, making IsVehicleOnAllWheels false while the car is on the ground. For
-- these vehicles we ONLY use the height check (must be genuinely high off the ground).
local function isAirborne(veh)
    if not veh or veh == 0 then return false end
    local cfg = Config.Airborne
    if not cfg or not cfg.Enabled then return false end

    local height = GetEntityHeightAboveGround(veh)
    local threshold = cfg.HeightThreshold or 1.5

    -- For muscle cars (class 4) and SUVs (class 2) with high suspension travel,
    -- use a MUCH higher threshold so normal wheelies/body roll don't trigger it.
    local vehClass = GetVehicleClass(veh)
    if vehClass == 4 then  -- muscle
        threshold = cfg.MuscleHeightThreshold or 3.0  -- only true jumps, not wheelies
    end

    -- Must be above the height threshold (not just wheels-off from body roll/wheelie)
    if height <= threshold then return false end

    -- AND wheels must be off (double-check)
    return not IsVehicleOnAllWheels(veh)
end

-- Drag launch condition check: returns true if all conditions are met for
-- entering launch-control staging mode. Requires handbrake to be engaged
-- TWICE at complete static 0 km/h (arm sequence: hold handbrake, release,
-- hold again = "double-tap to arm"). Then throttle activates staging.
-- Brake held = NEVER triggers (real launch control uses clutch, not brake).
local dragHandbrakeCount = 0     -- how many times handbrake was engaged at static
local dragPrevHandbrake = false  -- previous frame handbrake state for rising-edge
local dragArmedAt = 0            -- GetGameTimer() when the second handbrake confirmed

local function shouldEnterDragLaunch(veh)
    if not Config.DragLaunch or not Config.DragLaunch.Enabled then return false end

    -- Read launch control state from hk-handling (authoritative source)
    local ok, lcState = pcall(function()
        return exports['hk-handling']:GetLaunchState()
    end)
    if not ok or not lcState then return false end

    -- hk-handling reports: phase = 'off' | 'staged' | 'launched'
    -- Enter drag launch cam when LC is staged (revving on the line)
    return lcState.phase == 'staged'
end

-- Also track hk-handling launch state for the launch phase detection
local function getHkLaunchPhase()
    local ok, lcState = pcall(function()
        return exports['hk-handling']:GetLaunchState()
    end)
    if ok and lcState then return lcState.phase end
    return 'off'
end



-- Frame-rate-independent smoothing factor. `tau` is a time constant in
-- seconds: how long it takes to close ~63% of the gap. Converts to a
-- per-frame lerp alpha using the real frame time, so the feel is the
-- same at 30fps or 165fps (a raw lerp(t) is NOT — that was the bug).
-- Smaller tau = snappier; larger tau = floatier.
local function smoothAlpha(tau, dt)
    if not tau or tau <= 0.0 then return 1.0 end
    return 1.0 - math.exp(-dt / tau)
end


local function lerpAngle(a, b, t)
    -- Angle-aware lerp: always takes the shortest rotational path.
    -- Handles ±180° wrapping (e.g. lerp from 179° to -179° goes via 180°, not 0°).
    local diff = ((b - a + 180) % 360) - 180
    return a + diff * t
end

local function speedKmh(veh) return GetEntitySpeed(veh) * 3.6 end

local function notify(msg)
    if not (Config.Notify and Config.Notify.Enabled) then return end

    -- Try QBCore notify first, fall back to GTA native if it fails
    local success = pcall(function()
        -- Strip GTA color codes (~g~, ~r~, ~y~, ~s~, etc.) for QBCore
        local cleanMsg = msg:gsub('~%w~', '')
        exports['qb-core']:Notify(cleanMsg, 'primary', Config.Notify.Duration or 1500)
    end)

    if not success then
        -- Fallback to GTA native notification (keeps color codes)
        BeginTextCommandThefeedPost('STRING')
        AddTextComponentSubstringPlayerName(msg)
        EndTextCommandThefeedPostTicker(false, true)
    end
end

local function dbg(...)
    if Config.Debug then print('[hk-racecam]', ...) end
end

-----------------------------------------------------------------
-- Vehicle gating
-----------------------------------------------------------------

-----------------------------------------------------------------
-- DRIFT CAMERA OVERLAY
-- Reads hk-handling drift mode + computes slip angle from velocity.
-- All offsets are additive on the normal chase pipeline.
-----------------------------------------------------------------
-- Drift mode detection: reads hk-handling's export directly.
local function getHkDriftMode()
    local ok, val = pcall(function()
        return exports['hk-handling']:GetDriftMode()
    end)
    return ok and val == true
end

local function updateDriftCam(veh, dt, flatForward, velocity, kmh)
    local cfg = Config.DriftCam
    if not cfg or not cfg.Enabled then return end

    local driftHeld = getHkDriftMode()

    -- GAUGE: smooth ramp-up/decay with hold timer.
    -- After key release, hold the gauge for 350ms before starting decay.
    -- Each new press resets the timer — spam keeps it alive without bouncing.
    local riseRate = cfg.GaugeRiseRate or 0.8   -- real value comes from config
    local decayRate = cfg.GaugeDecayRate or 0.4  -- real value comes from config
    local now = GetGameTimer()

    -- Hold timer: tracks when the key was last released
    -- Engage delay: key must be held 140ms before drift cam activates
    if driftHeld then
        STATE.driftReleaseAt = nil  -- key held: clear release timestamp
        if not STATE.driftPressAt then
            STATE.driftPressAt = now  -- key just pressed: start engage delay
        end
    else
        STATE.driftPressAt = nil  -- key released: reset engage delay
        if not STATE.driftReleaseAt then
            STATE.driftReleaseAt = now  -- start exit hold timer
        end
    end

    -- Engage delay: only count as "held" after 140ms of continuous hold.
    -- CONTINUATION BYPASS: the delay exists to reject stray taps from a cold
    -- start. If the gauge is still elevated we never actually left drift, so a
    -- re-press is a continuation, not a new engage — applying the delay there
    -- would blank driftActive for 140ms, run the exit path, then snap back on.
    local engageDelayMs = 140
    local stillEngaged = (STATE.driftGauge or 0.0) > 0.05
    local heldLongEnough = driftHeld and (stillEngaged
        or (STATE.driftPressAt and (now - STATE.driftPressAt) >= engageDelayMs))

    -- Effective hold: held 140ms+ OR within 1400ms grace after release
    local holdGraceMs = 1400
    local inGrace = (not driftHeld) and STATE.driftReleaseAt and (now - STATE.driftReleaseAt) < holdGraceMs
    local effectivelyHeld = heldLongEnough or inGrace
    STATE.driftActive = effectivelyHeld  -- uses both delays

    -- GRACE FREEZE: during the grace window (key released but timer not expired),
    -- skip ALL drift cam calculations this frame. Offsets stay frozen at their
    -- last values. Re-pressing within grace just resets the release timer (above),
    -- it does NOT recalculate targets from live slip (which bounces the camera).
    STATE.driftInGrace = inGrace
    if inGrace then
        return  -- hold everything frozen, do nothing
    end

    local gaugeTarget = effectivelyHeld and 1.0 or 0.0
    local curGauge = STATE.driftGauge or 0.0
    local maxSlew = (gaugeTarget > curGauge) and riseRate or decayRate
    local diff = gaugeTarget - curGauge
    local maxStep = maxSlew * dt
    if math.abs(diff) > maxStep then
        STATE.driftGauge = curGauge + maxStep * (diff > 0 and 1.0 or -1.0)
    else
        STATE.driftGauge = gaugeTarget
    end
    STATE.driftGauge = clamp(STATE.driftGauge, 0.0, 1.0)
    local gauge = STATE.driftGauge
    -- Deadband: snap individual offsets to 0 only when THEY are tiny.
    -- This lets the lerp do its job and only cleans up the residual.
    if not effectivelyHeld then
        if math.abs(STATE.driftFovOffset) < 0.01 then STATE.driftFovOffset = 0.0 end
        if math.abs(STATE.driftDistOffset) < 0.003 then STATE.driftDistOffset = 0.0 end
        if math.abs(STATE.driftHeightOffset) < 0.003 then STATE.driftHeightOffset = 0.0 end
        if math.abs(STATE.driftLateralOffset or 0) < 0.002 then STATE.driftLateralOffset = 0.0 end
        if math.abs(STATE.driftRollOffset) < 0.05 then STATE.driftRollOffset = 0.0 end
        if math.abs(STATE.driftYawOffset) < 0.02 then STATE.driftYawOffset = 0.0 end
        if STATE.driftFactor < 0.005 then STATE.driftFactor = 0.0 end
        if STATE.driftMix < 0.005 then STATE.driftMix = 0.0 end
    end


    -- Compute slip angle: angle between car heading and velocity direction
    local slipDeg = 0.0
    local slipSign = 1.0
    local velMag = math.sqrt(velocity.x * velocity.x + velocity.y * velocity.y)
    if velMag > 1.0 and kmh > (cfg.MinSpeedKmh or 25.0) then
        -- Normalize velocity (XY only)
        local velDir = vector3(velocity.x / velMag, velocity.y / velMag, 0.0)
        -- Dot product = cos(angle), cross Z = sin(angle)
        local dot = flatForward.x * velDir.x + flatForward.y * velDir.y
        local cross = flatForward.x * velDir.y - flatForward.y * velDir.x
        slipDeg = math.deg(math.acos(math.min(1.0, math.max(-1.0, dot))))
        slipSign = (cross >= 0.0) and 1.0 or -1.0
    end

    -- Target drift factor: smoothstep ramp from slip angle + speed.
    -- NOT gated by gauge — gauge multiplies the EFFECTS later, not the factor.
    -- This prevents snap when gauge crosses the threshold.
    local targetFactor = 0.0
    if slipDeg > (cfg.MinAngleDeg or 8.0) then
        local slipT = clamp(
            (slipDeg - (cfg.MinAngleDeg or 8.0)) / ((cfg.FullAngleDeg or 30.0) - (cfg.MinAngleDeg or 8.0)),
            0.0, 1.0)
        slipT = slipT * slipT * (3.0 - 2.0 * slipT)  -- smoothstep
        local speedT = clamp((kmh - (cfg.MinSpeedKmh or 5.0)) / (80.0 - (cfg.MinSpeedKmh or 5.0)), 0.0, 1.0)
        targetFactor = slipT * speedT
    end

    -- Smooth the factor (asymmetric + speed-dependent return)
    local baseTau = cfg.SmoothTau or 0.40
    -- EFFECTS alpha: always uses baseTau (never frozen). Controls FOV/dist/height/lateral/roll.
    local alpha = smoothAlpha(baseTau, dt)

    -- driftFactor: decays naturally with speed-dependent return.
    -- Gauge handles the smooth exit scaling; factor tracks the actual slip state.
    local factorTau = baseTau
    if targetFactor < (STATE.driftFactor or 0.0) then
        local returnSlowdown = lerp(3.0, 1.0, clamp((kmh - 5.0) / 75.0, 0.0, 1.0))
        factorTau = baseTau * returnSlowdown
    end
    local factorAlpha = smoothAlpha(factorTau, dt)
    STATE.driftFactor = lerp(STATE.driftFactor, targetFactor, factorAlpha)

    -- SIMPLE EXIT: when key NOT held, just lerp all offsets to 0 (no live recalculation).
    -- This avoids snaps from heading/slip jumps when drift tyres disengage.
    -- When key IS held, compute targets normally from slip + speed.
    -- Exit fade: speed-dependent. Low speed = holds longer (1.2s tau), high speed = faster (0.65s tau)
    local exitTau = lerp(1.2, 0.65, clamp((kmh - 20.0) / 100.0, 0.0, 1.0))
    local exitAlpha = smoothAlpha(exitTau, dt)
    if not driftHeld then
        -- PURE DECAY: everything goes to 0, no direction computation
        STATE.driftFovOffset = lerp(STATE.driftFovOffset, 0.0, exitAlpha)
        STATE.driftDistOffset = lerp(STATE.driftDistOffset, 0.0, exitAlpha)
        STATE.driftHeightOffset = lerp(STATE.driftHeightOffset, 0.0, exitAlpha)
        STATE.driftLateralOffset = lerp(STATE.driftLateralOffset or 0.0, 0.0, exitAlpha)
        STATE.driftRollOffset = lerp(STATE.driftRollOffset, 0.0, exitAlpha)
        STATE.driftYawOffset = lerp(STATE.driftYawOffset, 0.0, exitAlpha)
    else
        -- KEY HELD: compute live targets from slip angle
        local targetFov = gauge * ((cfg.KeyHoldFovBump or 1.5) + STATE.driftFactor * (cfg.FovAdd or 1.0))
        STATE.driftFovOffset = lerp(STATE.driftFovOffset, targetFov, alpha)

        local targetDist = STATE.driftFactor * (cfg.DistanceAdd or 0.35) * gauge
        local targetHeight = STATE.driftFactor * (cfg.HeightAdd or 0.20) * gauge
        local targetLateral = STATE.driftFactor * (cfg.LateralShift or 0.25) * -slipSign * gauge
        STATE.driftDistOffset = lerp(STATE.driftDistOffset, targetDist, alpha)
        STATE.driftHeightOffset = lerp(STATE.driftHeightOffset, targetHeight, alpha)

        -- Anti-flick lateral
        local curLat = STATE.driftLateralOffset or 0.0
        local latAlpha = alpha
        if curLat * targetLateral < 0.0 then
            targetLateral = 0.0
            latAlpha = latAlpha * 0.25
        end
        STATE.driftLateralOffset = lerp(curLat, targetLateral, latAlpha)

        -- Roll
        local rollSlipT = 0.0
        if slipDeg > (cfg.MinAngleDeg or 8.0) then
            rollSlipT = clamp(
                (slipDeg - (cfg.MinAngleDeg or 8.0)) / ((cfg.FullAngleDeg or 30.0) - (cfg.MinAngleDeg or 8.0)),
                0.0, 1.0)
            rollSlipT = rollSlipT * rollSlipT * (3.0 - 2.0 * rollSlipT)
        end
        local rollSpeedScale = lerp(1.0, 0.4, clamp((kmh - 30.0) / 100.0, 0.0, 1.0))
        local targetRoll = rollSlipT * rollSpeedScale * (cfg.RollDeg or 5.0) * slipSign * gauge
        STATE.driftRollOffset = lerp(STATE.driftRollOffset, targetRoll, alpha)

        -- Yaw
        local targetYawOff = 0.0
        if STATE.driftFactor > 0.01 then
            targetYawOff = slipDeg * slipSign * (cfg.YawBlend or 0.15) * STATE.driftFactor * gauge
        end
        STATE.driftYawOffset = lerp(STATE.driftYawOffset, targetYawOff, alpha)
    end
    -- Hard caps to prevent overshoot
    local maxLat = cfg.MaxLateral or 0.66
    local maxYaw = cfg.MaxYawDeg or 4.4
    STATE.driftLateralOffset = clamp(STATE.driftLateralOffset or 0.0, -maxLat, maxLat)
    STATE.driftYawOffset = clamp(STATE.driftYawOffset, -maxYaw, maxYaw)
end

local function getDrivenVehicle()
    local ped = PlayerPedId()
    if not IsPedInAnyVehicle(ped, false) then return nil end
    local veh = GetVehiclePedIsIn(ped, false)
    if not veh or veh == 0 or not DoesEntityExist(veh) then return nil end

    if Config.DriverOnly and GetPedInVehicleSeat(veh, -1) ~= ped then
        return nil  -- passenger; don't hijack their view
    end

    if Config.AllowedClasses then
        if not Config.AllowedClasses[GetVehicleClass(veh)] then return nil end
    end

    return veh
end

-----------------------------------------------------------------
-- Adaptive sizing from GetModelDimensions (runtime bounding box).
-- Works for every custom/addon vehicle without reading vehicle.meta.
-- Cached per entity so we don't recompute every frame.
-----------------------------------------------------------------
local function getVehParams(veh)
    if STATE.vehParams and STATE.vehParamsFor == veh then
        return STATE.vehParams
    end

    local p = { lengthFactor = 1.0, heightFactor = 1.0, length = 5.0, width = 2.0, height = 2.0, roofZ = 0.8 }

    if Config.Adaptive and Config.Adaptive.Enabled then
        local minDim, maxDim = GetModelDimensions(GetEntityModel(veh))
        local length = maxDim.y - minDim.y
        local width  = maxDim.x - minDim.x
        local height = maxDim.z - minDim.z

        -- Guard against zero/garbage if the model somehow isn't loaded.
        if length and length > 0.5 then
            local a = Config.Adaptive
            p.length = length
            p.width  = width
            p.height = height
            -- roofZ = height of the vehicle's HIGHEST point above its origin
            -- (GetEntityCoords sits near axle height). This is the anchor for the
            -- roof-relative camera/look heights so framing is consistent across
            -- a low sports car and a tall SUV.
            p.roofZ = maxDim.z
            p.lengthFactor = clamp(length / a.RefLength, a.LengthFactorMin, a.LengthFactorMax)
            p.heightFactor = clamp(height / a.RefHeight, a.HeightFactorMin, a.HeightFactorMax)
        end
    end

    STATE.vehParams = p
    STATE.vehParamsFor = veh
    dbg(('vehParams len=%.2f h=%.2f -> lf=%.2f hf=%.2f'):format(p.length, p.height, p.lengthFactor, p.heightFactor))
    return p
end

-----------------------------------------------------------------
-- PER-VEHICLE PRESET RESOLVER
-- Flow with explicit checkpoint cross-checks:
--   [1] GET ON CAR        -> we have a valid veh entity
--   [2] LOAD VEHICLE NAME -> resolve spawn name from model hash
--   [3] DETECT CUSTOM     -> look up Config.VehiclePresets[name]
--   [4] APPLY CUSTOM      -> deep-merge overrides over the base preset
-- Cached on a triple key (entity + preset name + model hash) so a
-- vehicle swap, preset switch, or model change all force a re-resolve.
-----------------------------------------------------------------

-- Shallow-merge `override` onto a COPY of `base` (one level deep is
-- enough; nested tables like fov/offset are replaced wholesale).
local function mergePreset(base, override)
    local out = {}
    for k, v in pairs(base) do out[k] = v end
    for k, v in pairs(override) do out[k] = v end
    return out
end

-- Normalise a model to its spawn name, lowercased. Returns name, hash.
local function vehicleKey(veh)
    local hash = GetEntityModel(veh)
    local name = GetDisplayNameFromVehicleModel(hash)  -- e.g. "ADDER"
    if not name or name == '' or name == 'CARNOTFOUND' then
        return nil, hash
    end
    return string.lower(name), hash
end

local function getResolvedPreset(veh)
    local presetName = STATE.preset
    local base = Config.Presets[presetName]

    -- [CHECKPOINT A] base preset must exist
    if not base then
        dbg('resolve: base preset missing for ' .. tostring(presetName))
        return Config.Presets[Config.DefaultPreset]
    end

    -- [CHECKPOINT B] cache hit only if entity + preset + model hash all match
    local rf = STATE.resolvedFor
    local curHash = GetEntityModel(veh)
    if STATE.resolvedPreset
       and rf.veh == veh
       and rf.preset == presetName
       and rf.hash == curHash then
        return STATE.resolvedPreset
    end

    -- [CHECKPOINT C] resolve spawn name from the model
    local name, hash = vehicleKey(veh)
    local resolved = base
    local source = 'base'

    -- [CHECKPOINT D] detect a custom entry for this vehicle
    if name and Config.VehiclePresets then
        local custom = Config.VehiclePresets[name]
        if custom then
            -- Two shapes supported:
            --  (1) per-preset:  { chase = {...}, hood = {...} }
            --  (2) global:      { baseDistance = .., baseHeight = .. }
            local perPreset = custom[presetName]
            if type(perPreset) == 'table' then
                resolved = mergePreset(base, perPreset)
                source = 'custom[' .. name .. '].' .. presetName
            elseif custom[presetName] == nil
                   and (custom.chase == nil and custom.bonnet == nil) then
                -- No per-preset keys at all -> treat whole table as global override
                resolved = mergePreset(base, custom)
                source = 'custom[' .. name .. '].global'
            end
        end
    end

    -- [CHECKPOINT E] cache the result on the triple key
    STATE.resolvedPreset = resolved
    STATE.resolvedFor = { veh = veh, preset = presetName, hash = hash }

    dbg(('resolve: veh=%s name=%s preset=%s -> %s'):format(
        tostring(veh), tostring(name), presetName, source))
    return resolved
end

-- Invalidate the resolved-preset cache (call whenever preset/vehicle changes).
local function invalidateResolved()
    STATE.resolvedPreset = nil
    STATE.resolvedFor = { veh = 0, preset = '', hash = 0 }
end

-----------------------------------------------------------------
-- VIEW MODE OVERRIDE APPLIER
-- Merge per-V-mode overrides on top of the resolved preset. Applied
-- per-frame (cheap shallow merge) so live V-key changes take effect
-- instantly without cache invalidation. The _base block merges first,
-- then the mode-specific block.
-----------------------------------------------------------------
local function applyViewModeOverrides(preset, viewMode)
    if not (Config.ViewModeOverrides and Config.ViewModeFollow and Config.ViewModeFollow.Enabled) then
        return preset
    end
    local out = {}
    for k, v in pairs(preset) do out[k] = v end

    -- Apply _base overrides first (shared across all modes).
    local base = Config.ViewModeOverrides._base
    if base then
        for k, v in pairs(base) do out[k] = v end
    end

    -- Apply mode-specific overrides.
    local modeOver = Config.ViewModeOverrides[viewMode]
    if modeOver then
        for k, v in pairs(modeOver) do out[k] = v end
    end

    return out
end

-----------------------------------------------------------------
-- LOOK DETECTION
-- A scripted cam + DisableControlAction zeroes GetControlNormal, so we
-- MUST read GetDisabledControlNormal to know the player's intent.
--  1/2   = mouse / keyboard look (LR / UD)
--  220/221 = controller right stick (script axes)
-- Returns true if the player is actively looking around.
-----------------------------------------------------------------
local function isPlayerLooking()
    local dz = Config.Engagement.LookDeadzone
    local lx = GetDisabledControlNormal(0, 1)
    local ly = GetDisabledControlNormal(0, 2)
    if math.abs(lx) > dz or math.abs(ly) > dz then return true end

    if Config.Engagement.CheckController then
        local rx = GetDisabledControlNormal(0, 220)
        local ry = GetDisabledControlNormal(0, 221)
        if math.abs(rx) > dz or math.abs(ry) > dz then return true end
    end
    return false
end

-----------------------------------------------------------------
-- GTA FOLLOW-CAM DISTANCE CAPTURE (once, at engage-time only)
-- Read where GTA's own gameplay camera sits relative to the car and
-- measure the horizontal distance. This is ONLY called at engage-time
-- (before RenderScriptCams takes over) when the read is guaranteed valid.
-- Returns a clamped distance, or nil if the read is implausible.
-----------------------------------------------------------------
local GTA_DIST_MIN, GTA_DIST_MAX = 1.5, 14.0
local function captureGtaFollowDistance(veh)
    local camPos = GetGameplayCamCoord()
    local vehPos = GetEntityCoords(veh)
    -- Horizontal (XY) distance only — vertical offset isn't "follow distance".
    local dx = camPos.x - vehPos.x
    local dy = camPos.y - vehPos.y
    local d = math.sqrt(dx * dx + dy * dy)
    if d < GTA_DIST_MIN or d > GTA_DIST_MAX then
        return nil  -- first-person / bonnet / wonky read -> use fallback
    end
    return d
end

-----------------------------------------------------------------
-- MOTION BLUR — dispatches to one of three modes (Config.MotionBlur.Mode):
--   'glsl'      true radial speed blur via the WebGL NUI overlay (blur.js).
--               Client sends a speed-driven 0..1 amount; the shader does the
--               radial blur (sharp center, blurred edges). Ignores the in-game
--               Motion Blur graphics setting.
--   'raceturbo' GTA's built-in RaceTurbo radial post-fx, switched on by speed
--               (with hysteresis). Cheap/stable; on-off, slight color shift.
--   'native'    SetCamMotionBlurStrength on the scripted cam (subtle, GATED by
--               the player's Graphics > Motion Blur Strength setting).
--   'off'       nothing.
-----------------------------------------------------------------
-- speed -> normalized 0..1 over a [start, max] km/h band
local function blurRamp(kmh, startKmh, maxKmh)
    local lo = startKmh or 0.0
    local hi = maxKmh or 200.0
    if hi <= lo then return kmh >= hi and 1.0 or 0.0 end
    return clamp((kmh - lo) / (hi - lo), 0.0, 1.0)
end

-- Push the GLSL tunables to the NUI overlay once per engage (or mode switch).
local function sendBlurConfig()
    local g = Config.MotionBlur and Config.MotionBlur.Glsl
    if not g then return end
    SendNUIMessage({
        action = 'blurConfig',
        cfg = {
            MaxRadius       = g.MaxRadius or 18.0,
            SharpRadius     = g.SharpRadius or 0.34,
            Feather         = g.Feather or 0.45,
            MaxBlurSamples  = g.MaxBlurSamples or 12,
            ResolutionScale = g.ResolutionScale or 0.5,
            Opacity         = g.Opacity or 1.0,
        },
    })
end

-- Tear every mode's effect down. Safe to call repeatedly / on disengage.
local function clearMotionBlur()
    -- GLSL overlay off. ALWAYS message blurOff (not gated on blurGlslOn) because
    -- the warm-up loop runs at amount 0 with blurGlslOn still false — if we only
    -- sent blurOff when blurGlslOn was true, that loop would never be told to
    -- stop and would keep doing per-frame GL work forever (a stutter leak).
    if STATE.blurMode == 'glsl' or STATE.blurGlslOn then
        SendNUIMessage({ action = 'blurOff' })
    end
    STATE.blurGlslOn = false
    STATE.blurGlslAmount = -1.0
    -- RaceTurbo off
    if STATE.blurFxActive then
        local rt = Config.MotionBlur and Config.MotionBlur.RaceTurbo
        AnimpostfxStop((rt and rt.Effect) or 'RaceTurbo')
        STATE.blurFxActive = false
    end
    -- Native force-pipeline off
    if STATE.blurForced then
        if SetForceMotionblur then SetForceMotionblur(false) end
        STATE.blurForced = false
    end
    -- Reset the active-mode marker so the next engage re-sends the GLSL config
    -- (which re-triggers the warm-up). Without this, re-engaging after a
    -- disengage would skip warm-up and catch the blue placeholder again.
    STATE.blurMode = nil
end

local function applyMotionBlur(cam, kmh)
    local mb = Config.MotionBlur
    if not (mb and mb.Enabled) or mb.Mode == 'off' then
        clearMotionBlur()
        return
    end

    local mode = mb.Mode or 'glsl'

    -- If the mode changed since last frame, tear down the others first.
    if STATE.blurMode ~= mode then
        clearMotionBlur()
        STATE.blurMode = mode
        if mode == 'glsl' then sendBlurConfig() end
    end

    if mode == 'glsl' then
        local g = mb.Glsl or {}
        local amount = blurRamp(kmh, g.StartKmh, g.MaxSpeedKmh)
        -- Only message the NUI when the amount moves enough (avoid bridge spam).
        local thresh = g.UpdateThreshold or 0.02
        if math.abs(amount - (STATE.blurGlslAmount or -1.0)) >= thresh
           or (amount <= 0.001 and STATE.blurGlslOn)
           or (amount > 0.001 and not STATE.blurGlslOn) then
            SendNUIMessage({ action = 'blur', amount = amount })
            STATE.blurGlslAmount = amount
            STATE.blurGlslOn = amount > 0.001
        end

    elseif mode == 'raceturbo' then
        local rt = mb.RaceTurbo or {}
        local effect = rt.Effect or 'RaceTurbo'
        local onKmh  = rt.StartKmh or 120.0
        local offKmh = onKmh - (rt.HysteresisKmh or 15.0)
        if not STATE.blurFxActive and kmh >= onKmh then
            -- AnimpostfxPlay(name, duration=0 (default length), looped=true)
            AnimpostfxPlay(effect, 0, true)
            STATE.blurFxActive = true
        elseif STATE.blurFxActive and kmh < offKmh then
            AnimpostfxStop(effect)
            STATE.blurFxActive = false
        end

    elseif mode == 'native' then
        local n = mb.Native or {}
        if n.ForcePipeline then
            if not STATE.blurForced and SetForceMotionblur then
                SetForceMotionblur(true)
                STATE.blurForced = true
            end
        elseif STATE.blurForced then
            if SetForceMotionblur then SetForceMotionblur(false) end
            STATE.blurForced = false
        end
        local t = blurRamp(kmh, n.StartKmh, n.MaxSpeedKmh)
        local s = lerp(n.StrengthAtIdle or 0.0, n.StrengthAtTopSpeed or 1.0, t)
        SetCamMotionBlurStrength(cam, s)
    end
end

-----------------------------------------------------------------
-- CAM LIFECYCLE
-----------------------------------------------------------------
local function ensureCam()
    if STATE.cam and DoesCamExist(STATE.cam) then return STATE.cam end
    STATE.cam = CreateCam('DEFAULT_SCRIPTED_CAMERA', false)
    return STATE.cam
end

-- Hard-snap the chase camera directly behind the vehicle, position AND rotation,
-- with NO lerp/smoothing. Used to force a clean reset when returning from reverse
-- cam (C-key) or any transition — eliminates the weightless drift caused by the
-- camera lerping from the front of the car through the look target.
local function snapChaseToVehicle(veh, preset)
    if not (STATE.cam and DoesCamExist(STATE.cam)) then return end
    local modeBaseDistances = { [0] = 3.0, [1] = 5.0, [2] = 7.0 }
    local vm = STATE.currentViewMode or 1
    local baseDist = (preset.baseDistance or modeBaseDistances[vm] or 5.0)
    baseDist = baseDist + (preset.distanceTrim or 0.0) + (preset.minExtraDistance or 0.0)

    local vehPos = GetEntityCoords(veh)
    local headingRad = math.rad(GetEntityHeading(veh))
    local flatForward = vector3(-math.sin(headingRad), math.cos(headingRad), 0.0)

    -- Roof anchoring (match updateFree): lift camera + look target together by how
    -- much taller this vehicle's roof is than a reference car, so the snap lands at
    -- the same pose the live loop holds (no one-frame height pop on tall vehicles).
    local params = getVehParams(veh)
    local refRoofZ = (Config.Adaptive and Config.Adaptive.RefRoofZ) or 0.75
    local roofShift = math.max(0.0, (params.roofZ or refRoofZ) - refRoofZ)

    local height = (preset.baseHeight or 3.0) + (preset.heightLift or 0.0) + roofShift

    -- Snap position directly behind car
    STATE.curPos = vehPos - (flatForward * baseDist) + vector3(0.0, 0.0, height)
    SetCamCoord(STATE.cam, STATE.curPos.x, STATE.curPos.y, STATE.curPos.z)

    -- Compute and snap rotation to aim at the car (no roll, no lag)
    local lookHeight = (preset.lookHeight or 1.3) + roofShift
    local lookAhead = preset.lookAheadBase or 1.0
    local lookPos = vehPos + (flatForward * lookAhead) + vector3(0.0, 0.0, lookHeight)
    local dir = lookPos - STATE.curPos
    local distXY = math.sqrt(dir.x * dir.x + dir.y * dir.y)
    local pitch = math.deg(math.atan(dir.z, distXY))
    local yaw = math.deg(math.atan(-dir.x, dir.y))
    STATE.currentYaw = yaw
    STATE.currentRoll = 0.0
    STATE.smoothedVehiclePitch = 0.0
    -- CRITICAL: the reverse cam used PointCamAtCoord, which leaves the camera in a
    -- PERSISTENT pointing mode that overrides SetCamRot until cancelled. Without
    -- this, the cam stays locked on the stale reverse look-point (= behind you as
    -- you drive off) and SetCamRot below is silently ignored → "looks backwards"
    -- + swoop. StopCamPointing hands rotation control back to SetCamRot.
    StopCamPointing(STATE.cam)
    STATE.camPointing = false
    SetCamRot(STATE.cam, pitch, 0.0, yaw, 2)
end

local function engage(veh)
    local cam = ensureCam()
    local preset = getResolvedPreset(veh)  -- [CHECKPOINT: resolve per-vehicle preset]
    STATE.currentViewMode = GetFollowVehicleCamViewMode()

    -- Reset g-force estimator so a stale delta doesn't punch the first frame.
    STATE.prevVel = GetEntityVelocity(veh)
    STATE.accelLong = 0.0
    STATE.accelLat = 0.0

    -- Seed position so the ease-in starts from a sensible place, not (0,0,0).
    -- REBUILT: Use per-mode base distance + minExtraDistance, matching the new
    -- distance model. No more baseline capture/scale confusion.
    local fwd = GetEntityForwardVector(veh)

    local vm = STATE.currentViewMode or 1
    local params = getVehParams(veh)
    local seedDist

    -- Seed from FrontChase breakpoints at current speed (matches what updateFree will compute)
    local fc = Config.FrontChase
    if fc and fc.Enabled and fc.Breakpoints then
        local kmh = GetEntitySpeed(veh) * 3.6
        local bps = fc.Breakpoints
        seedDist = bps[1][2]
        if #bps >= 2 then
            if kmh <= bps[1][1] then
                seedDist = bps[1][2]
            elseif kmh >= bps[#bps][1] then
                seedDist = bps[#bps][2]
            else
                for i = 1, #bps - 1 do
                    if kmh >= bps[i][1] and kmh <= bps[i+1][1] then
                        local s0, d0 = bps[i][1], bps[i][2]
                        local s1, d1 = bps[i+1][1], bps[i+1][2]
                        local t = (kmh - s0) / (s1 - s0)
                        t = t * t * (3.0 - 2.0 * t)
                        seedDist = d0 + (d1 - d0) * t
                        break
                    end
                end
            end
        end
        -- Apply V-key mode scale
        local scales = fc.ViewModeScales or { [0] = 0.88, [1] = 1.0, [2] = 1.14 }
        seedDist = seedDist * (scales[vm] or 1.0)
    else
        local modeBaseDistances = { [0] = 3.0, [1] = 5.0, [2] = 7.0 }
        local baseDist = (preset.baseDistance or modeBaseDistances[vm] or 5.0)
        baseDist = baseDist + (preset.distanceTrim or 0.0)
        seedDist = baseDist + (preset.minExtraDistance or 0.0)
    end

    -- SMOOTH ENGAGE: seed the scripted cam near the live gameplay follow-cam so the
    -- handoff is smooth, BUT clamp its horizontal distance so it never starts further
    -- back than the chase distance. CRITICAL: at speed the gameplay cam sits well
    -- BEHIND the chase distance, and the car keeps driving forward during the blend —
    -- so seeding the raw gameplay point makes the cam start too far back, "fall behind"
    -- the accelerating car, then race to catch up (the user's "falls back then goes
    -- back to the vehicle" report). Clamping the seed to the chase distance keeps the
    -- dolly short and forward-biased so the velocity-comp can hold pace.
    local gpCoord = GetGameplayCamCoord()
    local gpFov   = GetGameplayCamFov()
    local vp0     = GetEntityCoords(veh)
    local computedSeed = vp0 - (fwd * seedDist) + vector3(0.0, 0.0, preset.baseHeight or 3.0)
    if gpCoord and #(gpCoord - vp0) > 0.5 then
        -- Clamp the gameplay-cam offset's horizontal distance to seedDist (chase dist).
        local off = gpCoord - vp0
        local horiz = math.sqrt(off.x * off.x + off.y * off.y)
        if horiz > seedDist and horiz > 0.01 then
            local s = seedDist / horiz
            off = vector3(off.x * s, off.y * s, off.z)
        end
        STATE.curPos = vp0 + off
    else
        STATE.curPos = computedSeed
    end
    local chaseFov = (type(preset.fov) == 'table') and preset.fov.min or preset.fov
    STATE.curFov = (gpFov and gpFov > 1.0 and gpFov < 130.0) and gpFov or chaseFov
    -- Start the slow-blend transition window.
    STATE.engageAtMs = GetGameTimer()
    STATE.fcDist = seedDist  -- seed distance smoother so first frame doesn't snap

    -- Seed yaw/roll for the cornering system AND apply the correct camera rotation on
    -- frame 1. CRITICAL: with EaseInMs=0 the scripted cam activates instantly, so if we
    -- don't SetCamRot here the first rendered frame uses the camera handle's STALE
    -- rotation (0° or whatever it last held), then updateFree snaps it to the correct
    -- yaw on frame 2 — that stale→correct jump is the "flip in a circle once then snap
    -- to middle, inverted" bug. Computing the real pitch/yaw here (same math as
    -- snapChaseToVehicle) and calling SetCamRot BEFORE RenderScriptCams makes frame 1
    -- already correct, eliminating the flip entirely.
    STATE.currentRoll = 0.0

    local fwdSeed = GetEntityForwardVector(veh)
    local lookAheadSeed = preset.lookAheadBase or 1.0
    local lookHeightSeed = preset.lookHeight or 1.3
    local lookPosSeed = GetEntityCoords(veh) + (fwdSeed * lookAheadSeed) + vector3(0.0, 0.0, lookHeightSeed)
    local dirSeed = lookPosSeed - STATE.curPos
    local distXYSeed = math.sqrt(dirSeed.x * dirSeed.x + dirSeed.y * dirSeed.y)
    local pitchSeed = math.deg(math.atan(dirSeed.z, distXYSeed))
    local yawSeed = math.deg(math.atan(-dirSeed.x, dirSeed.y))  -- -180..180 (matches targetYaw)
    STATE.currentYaw = yawSeed  -- correct range, NOT GetEntityHeading's 0-360
    STATE.yawTransitionFrames = 8  -- instant yaw tracking for first 8 frames

    SetCamCoord(cam, STATE.curPos.x, STATE.curPos.y, STATE.curPos.z)
    SetCamFov(cam, STATE.curFov)
    -- Cancel any leftover PointCamAtCoord (reverse cam) so SetCamRot isn't silently ignored.
    if STATE.camPointing then StopCamPointing(cam); STATE.camPointing = false end
    SetCamRot(cam, pitchSeed, 0.0, yawSeed, 2)  -- frame-1 rotation correct (no flip)
    SetCamActive(cam, true)
    RenderScriptCams(true, true, Config.Engagement.EaseInMs, true, true)
    STATE.engaged = true
    dbg('engaged preset=' .. STATE.preset .. ' viewMode=' .. STATE.currentViewMode .. ' seedDist=' .. string.format("%.2f", seedDist))
end

local function disengage()
    if STATE.cam and DoesCamExist(STATE.cam) then
        -- Restore a third-person view mode so native cam doesn't land in first-person
        local restoreMode = STATE.lastThirdPersonMode or 1
        SetFollowVehicleCamViewMode(restoreMode)
        StopCamShaking(STATE.cam, true)
        SetCamActive(STATE.cam, false)
        RenderScriptCams(false, false, 0, true, true)  -- instant, no ease
        DestroyCam(STATE.cam, false)
        STATE.cam = nil
    end
    clearMotionBlur()
    STATE.engaged = false
    STATE.shakeActive = false
    STATE.corneringShakeActive = false  -- reset cornering shake state
    -- Clear the lock snapshot so it re-captures fresh values on next engage
    -- (the locked TOGGLE itself persists — only the captured frame resets).
    STATE.lockedDist = nil
    STATE.lockedHeight = nil
    STATE.lockedFov = nil
    -- Reset cornering dynamics state
    STATE.currentRoll = 0.0
    STATE.currentYaw = 0.0
    -- Reset ALL stale session state so leftovers don't leak into the next engage
    -- (e.g. wasReversing=true from disengaging during C-key would trigger spurious
    -- snapChaseToVehicle on the first frame of next engage; stale yawHist from a turn
    -- feeds ghost offsets into rotational inertia 0.35s later).
    STATE.wasReversing = false
    STATE.yawHist = {}
    STATE.laggedYaw = nil
    STATE.appliedYawOffset = 0.0
    STATE.prevTargetYaw = nil
    STATE.smoothedVehiclePitch = 0.0
    dbg('disengaged')
end

local function teardownCam()
    if STATE.cam then
        if DoesCamExist(STATE.cam) then
            StopCamShaking(STATE.cam, true)
            SetCamActive(STATE.cam, false)
            RenderScriptCams(false, false, 0, true, true)
            DestroyCam(STATE.cam, false)
        end
        STATE.cam = nil
    end
    clearMotionBlur()
    STATE.engaged = false
    STATE.attachedBone = nil
    STATE.shakeActive = false
    -- Reset stale session state (same as disengage)
    STATE.wasReversing = false
    STATE.yawHist = {}
end

-----------------------------------------------------------------
-- DRAG LAUNCH MODE (Launch Control / Drag Start Camera)
-- Special mode that activates during drag racing starts: handbrake + throttle
-- at low speed in low gear. Camera zooms in tight behind the car and raises FOV
-- with RPM (building tension), then smoothly releases back to normal chase
-- distance/FOV when the handbrake drops (the dramatic launch moment).
--
-- SELF-CONTAINED: positions the camera directly (a simplified, locked chase pose)
-- rather than feeding the normal pipeline — so it feels distinctly different and
-- doesn't fight the cornering/g-force/inertia systems. Returns true while active
-- (the caller skips normal chase logic for the frame).
-----------------------------------------------------------------
local function updateDragLaunch(cam, veh, preset, params, dt)
    -- LAUNCH CONTROL CAMERA: FOV + shake OVERLAY on top of normal chase cam.
    -- Does NOT override position/rotation — the chase pipeline handles that.
    -- This only widens FOV during staging and shakes with RPM.
    local cfg = Config.DragLaunch
    if not cfg or not cfg.Enabled then return end

    local kmh = speedKmh(veh)
    local rpm = GetVehicleCurrentRpm(veh)
    local now = GetGameTimer()

    -- Read hk-handling launch state
    local hkPhase = getHkLaunchPhase()

    -- === ENTER ===
    if not STATE.dragLaunchActive and hkPhase == 'staged' then
        STATE.dragLaunchActive = true
        STATE.dragLaunchStage = "staging"
        STATE.dragLaunchStartMs = now
        STATE.dragFovProgress = 0.0
        STATE.dragFovAtRelease = nil
        dbg("Drag Launch Mode: ENTERED (overlay)")
    end

    if not STATE.dragLaunchActive then return end

    -- === STAGING: widen FOV, add distance/height/pitch + shake ===
    if hkPhase == 'staged' and kmh <= 3.0 then
        STATE.dragLaunchStage = "staging"
        STATE.dragFovProgress = 0.0
        -- FOV boost proportional to RPM (smoothed so it eases in, not snaps)
        local stageTau = cfg.StageInTau or 0.45  -- ease-in speed (higher = slower)
        local stageAlpha = smoothAlpha(stageTau, dt)
        local fovTarget = rpm * (cfg.MaxFovIncrease or 8.8)
        STATE.dragFovOffset = lerp(STATE.dragFovOffset, fovTarget, stageAlpha)
        -- Distance/height/pitch offsets (ease in smoothly with RPM)
        local distTarget = rpm * (cfg.DistanceOffset or 0.8)
        local heightTarget = rpm * (cfg.HeightOffset or 0.6)
        local pitchTarget = rpm * (cfg.PitchOffset or -7.0)
        STATE.dragDistOffset = lerp(STATE.dragDistOffset, distTarget, stageAlpha)
        STATE.dragHeightOffset = lerp(STATE.dragHeightOffset, heightTarget, stageAlpha)
        STATE.dragPitchOffset = lerp(STATE.dragPitchOffset, pitchTarget, stageAlpha)
        -- RPM shake
        local shakeIntensity = rpm * (cfg.ShakeIntensity or 0.48)
        if not STATE.dragShakeActive then
            ShakeCam(cam, cfg.ShakeName or 'HAND_SHAKE', shakeIntensity)
            STATE.dragShakeActive = true
        else
            SetCamShakeAmplitude(cam, shakeIntensity)
        end

    -- === LAUNCH: car moving OR hk-handling says launched ===
    elseif STATE.dragLaunchStage == "launching" or hkPhase == 'launched' or (STATE.dragLaunchStage == "staging" and kmh > 3.0) then
        if STATE.dragLaunchStage == "staging" then
            STATE.dragLaunchStage = "launching"
            STATE.dragLaunchFiredMs = now
            STATE.dragFovAtRelease = STATE.dragFovOffset or 0.0
            STATE.dragDistAtRelease = STATE.dragDistOffset or 0.0
            STATE.dragHeightAtRelease = STATE.dragHeightOffset or 0.0
            STATE.dragPitchAtRelease = STATE.dragPitchOffset or 0.0
            dbg("Drag Launch Mode: LAUNCHING (overlay)")
        end
        -- Stop shake
        if STATE.dragShakeActive then
            StopCamShaking(cam, true)
            STATE.dragShakeActive = false
        end
        -- Smooth return: ease ALL offsets back to 0
        local minSec = cfg.FovReturnMinSec or 0.47
        local maxSec = cfg.FovReturnMaxSec or 0.93
        local refKmh = cfg.FovReturnVelRefKmh or 45.0
        local velFactor = math.min(1.0, kmh / refKmh)
        local duration = maxSec + (minSec - maxSec) * velFactor
        STATE.dragFovProgress = STATE.dragFovProgress + (dt / duration)
        local rawT = math.min(1.0, STATE.dragFovProgress)
        local fovT = rawT * rawT * (3.0 - 2.0 * rawT)  -- smoothstep
        STATE.dragFovOffset = lerp(STATE.dragFovAtRelease or 0.0, 0.0, fovT)
        STATE.dragDistOffset = lerp(STATE.dragDistAtRelease or 0.0, 0.0, fovT)
        STATE.dragHeightOffset = lerp(STATE.dragHeightAtRelease or 0.0, 0.0, fovT)
        STATE.dragPitchOffset = lerp(STATE.dragPitchAtRelease or 0.0, 0.0, fovT)

        -- EXIT when return complete
        if STATE.dragFovProgress >= 1.0 then
            STATE.dragLaunchActive = false
            STATE.dragLaunchStage = "idle"
            STATE.dragFovOffset = 0.0
            STATE.dragDistOffset = 0.0
            STATE.dragHeightOffset = 0.0
            STATE.dragPitchOffset = 0.0
            STATE.dragFovProgress = 0.0
            dbg("Drag Launch Mode: EXITED (overlay)")
        end
    else
        -- hk-handling went off while staging (aborted) — debounce 300ms
        if hkPhase == 'off' and STATE.dragLaunchStage == "staging" then
            if not STATE.dragAbortSinceMs then
                STATE.dragAbortSinceMs = now
            end
            if (now - STATE.dragAbortSinceMs) >= 200 then
                -- Snapshot offsets and switch to the RETURN stage so they ease
                -- back smoothly instead of snapping to zero.
                STATE.dragLaunchStage = "launching"
                STATE.dragLaunchFiredMs = now
                STATE.dragFovAtRelease = STATE.dragFovOffset or 0.0
                STATE.dragDistAtRelease = STATE.dragDistOffset or 0.0
                STATE.dragHeightAtRelease = STATE.dragHeightOffset or 0.0
                STATE.dragPitchAtRelease = STATE.dragPitchOffset or 0.0
                STATE.dragFovProgress = 0.0
                STATE.dragAbortSinceMs = nil
                if STATE.dragShakeActive then StopCamShaking(cam, true); STATE.dragShakeActive = false end
                dbg("Drag Launch Mode: ABORTED -> smooth return")
            end
        else
            STATE.dragAbortSinceMs = nil
        end
    end
end

-----------------------------------------------------------------
-- MUSCLE CAR DETECTION (for entity-transform-based camera positioning)
-- GTA engine limitation: RenderScriptCams + muscle car handling + handbrake
-- causes heading desync. Fix: use GetOffsetFromEntityInWorldCoords for
-- positioning (uses entity's own transform matrix = always synced) instead
-- of heading-based flatForward computation. Detection uses class 4 OR the
-- Config.MuscleCarModels name list for re-classed vehicles.
-----------------------------------------------------------------

-- Build a fast lookup set from the config list at resource start
local muscleModelLookup = {}
if Config.MuscleCarModels then
    for _, name in ipairs(Config.MuscleCarModels) do
        muscleModelLookup[string.upper(name)] = true
    end
end

local function isMuscleHandling(veh)
    -- Standard GTA class check (unmodified vehicles.meta muscle = class 4)
    if GetVehicleClass(veh) == 4 then return true end
    -- Model-name lookup for re-classed vehicles (muscle handling but sport/super class)
    local hash = GetEntityModel(veh)
    local name = GetDisplayNameFromVehicleModel(hash)
    if name and muscleModelLookup[string.upper(name)] then return true end
    return false
end

-----------------------------------------------------------------
-- MUSCLE CAR CAMERA SMOOTHING
-- Pitch rate limiter smooths camera response to violent pitch changes.
-----------------------------------------------------------------

local PHYS = {
    smoothedPitch = 0.0,
    lastPitchRaw  = 0.0,
}

-- Frame-rate-independent exponential smoothing
local function physSmooth(current, target, tau, dt)
    if tau <= 0 then return target end
    local alpha = 1.0 - math.exp(-dt / tau)
    return current + (target - current) * alpha
end

-- Get the rate-limited pitch for camera use (smooths violent pitch changes)
local function getMuscleSmoothedPitch(veh, dt)
    local cfg = Config.MusclePhysics
    if not cfg or not cfg.PitchRateLimit then
        return GetEntityRotation(veh, 2).x
    end

    local rawPitch = GetEntityRotation(veh, 2).x
    local maxRate = cfg.PitchRateLimit.MaxDegPerSec
    local delta = rawPitch - PHYS.lastPitchRaw
    PHYS.lastPitchRaw = rawPitch

    local maxDelta = maxRate * dt
    delta = clamp(delta, -maxDelta, maxDelta)

    local targetPitch = PHYS.smoothedPitch + delta
    PHYS.smoothedPitch = physSmooth(PHYS.smoothedPitch, targetPitch,
        cfg.PitchRateLimit.Smoothing, dt)

    return PHYS.smoothedPitch
end

-----------------------------------------------------------------
-- PER-FRAME: "free" preset (chase / cinematic)
-- Manual world positioning from forward vector + velocity, eased via
-- lerp. The lerp lag is the inertia. Lateral velocity swings the cam
-- to the outside of corners. FOV widens with speed. Subtle shake at
-- high speed adds the road vibration the old repo never had.
-----------------------------------------------------------------
local chaseAdj = {
    offsetY   = 0.0,   -- forward/backward (distance) nudge
    offsetZ   = 0.0,   -- height nudge
    tilt      = 0.0,   -- pitch nudge (degrees, CTRL+left/right)
    active    = false,
    lastVeh   = 0,
}

local savedChasePresets = {} -- [modelName] = { offsetY, offsetZ, tilt }

local function updateFree(cam, veh, preset, params)
    -- If we were in a bone preset, the cam is still attached and would
    -- ignore SetCamCoord. Detach before doing manual positioning.
    if STATE.attachedBone ~= nil then
        DetachCam(cam)
        STATE.attachedBone = nil
    end

    -- Apply per-V-mode overrides on top of the resolved preset (per-frame,
    -- so changing V view mode takes effect instantly).
    preset = applyViewModeOverrides(preset, STATE.currentViewMode or 1)

    local kmh = speedKmh(veh)
    local now = GetGameTimer()
    local dt = GetFrameTime()
    if dt <= 0.0 then dt = 0.016 end
    local vehPos   = GetEntityCoords(veh)
    local velocity = GetEntityVelocity(veh)

    -- ===== DRAG LAUNCH MODE CHECK =====
    -- If drag launch is active, it positions the camera itself (a simplified,
    -- locked chase pose with zoom + FOV tied to RPM/throttle state) and returns
    -- true to block the rest of the normal chase pipeline for this frame.
    -- Drag launch mode: FOV/shake overlay only (does NOT override camera position).
    -- Normal chase pipeline always runs — LC just widens FOV + adds shake on top.
    updateDragLaunch(cam, veh, preset, params, dt)

    -- Drift camera overlay (compute slip angle + offsets, applied below in the pipeline)
    -- Must be called AFTER flatForward is available (it's computed just below).
    -- We'll call it later, after flatForward is set.

    -- Flattened forward from HEADING only (yaw), ignoring body pitch/roll.
    -- Using the raw forward vector means braking nose-dive / accel squat
    -- tilts the whole rig — the cam rises while the look target drops, so
    -- you end up staring at the roof. Heading-based forward stays level and
    -- kills that entirely. Position + look both use this; rotation still
    -- follows the real car so it doesn't feel detached.
    local headingRad = math.rad(GetEntityHeading(veh))
    local flatForward = vector3(-math.sin(headingRad), math.cos(headingRad), 0.0)

    -- Drift camera overlay: compute slip-based offsets now that we have flatForward + velocity
    updateDriftCam(veh, dt, flatForward, velocity, kmh)

    -- Per-frame smoothing alphas (frame-rate independent).
    local posAlpha = smoothAlpha(preset.smoothness or 0.12, dt)
    local fovAlpha = smoothAlpha(preset.fovSmoothness or 0.12, dt)

    -- ENGAGE TRANSITION: for a window after engaging, drive the position dolly-in
    -- with an EASE-OUT profile — the cam rushes in fast at the start and settles
    -- slowly as it nears the chase pose (the user's "faster at the start, much
    -- slower when closer to vehicle" ask). We ramp the smoothing tau from a SMALL
    -- start value (snappy approach) UP to a LARGER end value (floaty settle); the
    -- growing tau compounds with the naturally shrinking gap for a pronounced
    -- deceleration into the pose. FOV is left on its normal (mellow) smoothing so
    -- the dolly doesn't cause a zoom pop.
    local actualTau = nil  -- if engage window active, this will hold the ramped tau
    if STATE.engageAtMs and Config.Engagement.SmoothEngage ~= false then
        local blendMs = Config.Engagement.EngageBlendMs or 900
        local elapsed = GetGameTimer() - STATE.engageAtMs
        if elapsed < blendMs then
            local t = elapsed / blendMs                   -- 0 -> 1 across the window
            local easeOut = 1.0 - (1.0 - t) * (1.0 - t)   -- decelerating curve
            local tauStart = Config.Engagement.EngageTauStart or 0.10
            local tauEnd   = Config.Engagement.EngageTauEnd
                or (Config.Engagement.EngageTau or 0.24)
            local posTau = lerp(tauStart, tauEnd, easeOut)
            posAlpha = smoothAlpha(posTau, dt)
            actualTau = posTau  -- capture the ramped tau for velocity-comp below
        else
            STATE.engageAtMs = nil  -- window done; normal smoothing resumes
        end
    end

    -- ===== TRUE REVERSE DETECTION =====
    -- Local forward velocity: negative = physically moving backward.
    -- This separates real reversing from braking-while-rolling-forward.
    -- ALSO: C-key (look behind) forces reverse view even when driving forward.
    local localVel = GetEntitySpeedVector(veh, true)
    local physicallyReversing = localVel.y < -(Config.Reverse.SpeedThreshold or 0.6)

    -- Track recent throttle + recent forward motion for the drift guard below.
    -- Control 71 = INPUT_VEH_ACCELERATE (W / RT). Forward motion = local +Y velocity.
    if IsControlPressed(0, 71) or IsDisabledControlPressed(0, 71) then
        STATE.lastThrottleMs = now
    end
    if localVel.y > (Config.Reverse.SpeedThreshold or 0.6) then
        STATE.lastForwardMs = now
    end

    -- HANDBRAKE-DRIFT GUARD: a handbrake turn / quick 180 makes the car slide
    -- backward briefly from grip loss, which would falsely trip physical-reverse
    -- and flip the cam mid-drift. Three layered checks suppress that false trigger:
    --   1. Handbrake currently held -> always a drift/skid, never a reverse.
    --   2. RECENT THROTTLE + RECENT FORWARD: if the throttle was pressed AND the car
    --      was moving forward within the last DriftGuardWindowMs (~2s), the backslide
    --      is drift recovery, not a deliberate reverse. A real reverse follows a stop
    --      + reverse key, with no recent throttle/forward motion.
    --   3. Fast sideways slide larger than the backward speed = drift, not reverse.
    -- Slow reverse-parking (stopped, near-straight, no recent throttle) is untouched,
    -- and the C-key look-behind path is unaffected (deliberate input).
    if physicallyReversing and (Config.Reverse.HandbrakeGuard ~= false) then
        local windowMs = Config.Reverse.DriftGuardWindowMs or 2000
        local recentThrottle = (now - STATE.lastThrottleMs) < windowMs
        local recentForward  = (now - STATE.lastForwardMs) < windowMs
        if GetVehicleHandbrake(veh) then
            physicallyReversing = false
        elseif recentThrottle and recentForward then
            physicallyReversing = false
        elseif kmh > (Config.Reverse.DriftGuardMinKmh or 15.0) then
            local lateralSlide = math.abs(localVel.x)
            local backSpeed = -localVel.y
            if lateralSlide > backSpeed * (Config.Reverse.DriftGuardLatRatio or 1.0) then
                physicallyReversing = false
            end
        end
        -- MUSCLE CAR SNAP GUARD: when the car has high angular velocity, the
        -- "backwards" state is from a grip-snap 180, NOT a real reverse.
        -- Block reverse detection entirely while spinning fast.
        -- angZ > 1.0 rad/s = car is still rotating from the snap event.
        if isMuscleHandling(veh) and physicallyReversing then
            local angVel = GetEntityRotationVelocity(veh)
            if math.abs(angVel.z) > 1.0 then
                physicallyReversing = false
            end
        end
    end

    -- LOOK-BEHIND (reverse view) INPUT — cross-device by default.
    -- Control 79 = INPUT_VEH_LOOK_BEHIND, which GTA binds to BOTH keyboard C
    -- and controller R3 (right-stick click) while driving, so that single ID
    -- already covers keyboard + gamepad (confirmed via Grok, live). Control 26
    -- = INPUT_LOOK_BEHIND (on-foot equivalent, same physical keys) is kept as a
    -- harmless fallback. IsDisabledControlPressed is used because controls may
    -- be disabled while the cam owns the view. The list is config-driven so the
    -- bindings can be changed without touching code.
    local lookBehindHeld = false
    if Config.Reverse.CKeyEnabled then
        local ids = Config.Reverse.LookBehindControls or { 79, 26 }
        for i = 1, #ids do
            if IsDisabledControlPressed(0, ids[i]) then
                lookBehindHeld = true
                break
            end
        end
    end
    local cKeyHeld = lookBehindHeld  -- alias kept for the debounce/state logic below

    -- REVERSE GEAR DETECTION: read from hk-handling's GetDisplayGear export.
    -- Returns 'R' for reverse, 'N' for neutral — no collision between the two.
    -- Only trigger reverse cam if in reverse gear AND car is NOT moving forward.
    local inReverseGear = false
    local okGear, displayGear = pcall(function()
        return exports['hk-handling']:GetDisplayGear(veh)
    end)
    if okGear and displayGear == 'R' and localVel.y <= 0.5 then
        inReverseGear = true
    end

    -- RAW reverse condition this frame (reverse gear OR physical backward motion OR C held).
    local rawReverse = Config.Reverse.Enabled and (inReverseGear or cKeyHeld)

    -- RISING-EDGE DEBOUNCE: the raw condition must hold CONTINUOUSLY for
    -- DebounceMs before we actually flip INTO reverse. This kills the "flops
    -- back to reverse" bug: after exiting, a momentary roll-back spike (car
    -- drifting on a slope) or a one-frame look-behind control flicker no longer
    -- re-triggers — only a sustained reverse / deliberate C-hold does.
    -- Exiting reverse stays INSTANT (no debounce on the falling edge).
    -- The C-key uses its OWN much shorter debounce (CKeyDebounceMs): it's a
    -- deliberate hold, so it doesn't need the slope/drift guard and can flip
    -- almost instantly. Physical reverse keeps the slower DebounceMs.
    local debounceMs = (Config.Reverse.DebounceMs or 400)
    if cKeyHeld then
        debounceMs = math.min(debounceMs, Config.Reverse.CKeyDebounceMs or 30)
    end
    -- Reverse GEAR = instant (no debounce needed — deliberate driver input)
    if inReverseGear then debounceMs = 0 end
    local now = GetGameTimer()
    if rawReverse then
        if STATE.reverseTrueSinceMs == 0 then STATE.reverseTrueSinceMs = now end
    else
        STATE.reverseTrueSinceMs = 0
    end
    local sustained = rawReverse and (now - STATE.reverseTrueSinceMs) >= debounceMs

    local prevReversing = STATE.reversing
    -- Once engaged in reverse, stay until raw goes false (instant exit). To
    -- ENTER, require the debounce to have elapsed.
    STATE.reversing = prevReversing and rawReverse or sustained

    if STATE.reversing then
        -- C-KEY / REVERSE: flip the camera to the OPPOSITE side of whatever the
        -- normal view is. When FrontChase is active (normal = in front looking back),
        -- reverse puts the cam BEHIND looking forward. When FrontChase is off
        -- (normal = behind looking forward), reverse puts cam in front looking back.
        local r = Config.Reverse
        local dist = (r.Distance or 4.5) * params.lengthFactor
        local h = (r.Height or 2.0) * params.heightFactor
        local frontChaseActive = Config.FrontChase and Config.FrontChase.Enabled
        local targetPos
        local lookPos
        -- C-key ALWAYS puts camera in front of car, looking BACK at the car
        -- (inverted/backward view). Same behavior regardless of FrontChase mode.
        targetPos = GetOffsetFromEntityInWorldCoords(veh, 0.0, dist, h)
        lookPos = GetOffsetFromEntityInWorldCoords(veh, 0.0, 0.0, r.lookHeight or 1.0)

        -- SMOOTH TRANSITION: sweep the camera AROUND the car (circular arc) from
        -- its current side (behind) to the front. Straight-line lerp goes OVER the
        -- car (god view at midpoint) — angular sweep stays at the same radius.
        if not STATE.reverseStartMs then
            STATE.reverseStartMs = now
        end
        local blendMs = Config.Reverse.TransitionMs or 300
        -- INSTANT above high speed: at 160+ km/h the sweep animation feels laggy
        -- (the car covers too much ground during the blend). Snap instead.
        if kmh > (Config.Reverse.InstantAboveKmh or 160.0) then
            blendMs = 0
        end
        local elapsed = now - STATE.reverseStartMs
        if elapsed < blendMs then
            -- Ease-out curve
            local t = elapsed / blendMs
            local eased = 1.0 - (1.0 - t) * (1.0 - t)
            -- Sweep in the VERTICAL plane (Y + Z) — no lateral movement.
            -- SHALLOW ARC: lerp Y from -dist to +dist with a gentle height bump.
            -- Keeps the camera low (no god-view feel at midpoint).
            local sweepY = lerp(-dist, dist, eased)
            local sweepZ = h + math.sin(eased * math.pi) * 0.12  -- very subtle height bump (0.12m peak)
            STATE.curPos = GetOffsetFromEntityInWorldCoords(veh, 0.0, sweepY, sweepZ)
        else
            STATE.curPos = targetPos
        end
        SetCamCoord(cam, STATE.curPos.x, STATE.curPos.y, STATE.curPos.z)

        PointCamAtCoord(cam, lookPos.x, lookPos.y, lookPos.z)
        STATE.camPointing = true  -- pointing mode now owns rotation until StopCamPointing

        STATE.curFov = lerp(STATE.curFov, math.min(r.Fov or 60.0, Config.Limits.MaxFov), fovAlpha)
        SetCamFov(cam, STATE.curFov)

        -- No shake while reversing
        if STATE.shakeActive then
            StopCamShaking(cam, true)
            STATE.shakeActive = false
        end

        -- ROOT-CAUSE FIX: the chase cam uses SetCamRot(STATE.currentYaw) for roll,
        -- but reverse uses PointCamAtCoord and never touches currentYaw — so on
        -- exit the chase resumed from a STALE backward yaw (the "still looks
        -- backward" bug, introduced when rolling-tilt added persistent yaw state).
        -- Keep currentYaw/curPos synced to where the FORWARD chase cam WOULD be,
        -- every reverse frame, so the transition back is already correct.
        do
            local chaseSeed = vehPos - (flatForward * dist) + vector3(0.0, 0.0, h)
            local lookFwd = vehPos + (flatForward * (preset.lookAheadBase or 1.0))
                          + vector3(0.0, 0.0, preset.lookHeight or 1.3)
            local fdir = lookFwd - chaseSeed
            STATE.currentYaw = math.deg(math.atan(-fdir.x, fdir.y))
            STATE.currentRoll = 0.0
        end

        STATE.wasReversing = true  -- mark that we were in reverse cam
        return
    end

    -- TRANSITION GUARD: we just exited reverse cam (C released / stopped reversing).
    -- Reverse positions the cam in FRONT of the car (PointCamAtCoord); chase sits
    -- BEHIND it (SetCamRot with persistent currentYaw). Bridging those by lerping —
    -- or by disengaging and re-engaging — either swoops through the car or leaves
    -- a visible gap AND can resume from a stale backward yaw (the "still looks
    -- backward" freeze in the logs). Instead, HARD-SNAP position+yaw to the correct
    -- forward-facing chase pose in a single frame, then run chase math next frame.
    if STATE.wasReversing then
        STATE.wasReversing = false
        STATE.reverseTrueSinceMs = 0   -- reset debounce so re-entry needs a fresh sustained hold
        STATE.reverseStartMs = nil     -- reset transition blend for next C-press
        -- SMOOTH EXIT: start a blend-back timer. The normal chase math will run,
        -- but curPos will lerp from the current (reverse) position toward the
        -- chase target over TransitionMs for a smooth sweep back.
        STATE.reverseExitMs = now
        STATE.reverseExitPos = vector3(STATE.curPos.x, STATE.curPos.y, STATE.curPos.z)
        -- Cancel PointCamAtCoord so SetCamRot can take over
        StopCamPointing(cam)
        STATE.camPointing = false
        STATE.yawTransitionFrames = 2
        STATE.prevVel = velocity
        -- DON'T return — let normal chase run this frame with the blend active
    end

    -- Speed feeding the secondary effects (accel-extra-distance + shake ramp)
    -- is capped so a 400km/h hypercar doesn't max everything instantly.
    local cappedKmh = math.min(kmh, Config.Limits.SpeedCapKmh or 220.0)
    local sfRaw = clamp(cappedKmh / (preset.maxSpeedKmh or 150.0), 0.0, 1.0)
    -- Smoothstep easing: gentle ramp-in and settle instead of a linear ramp.
    local sf = sfRaw * sfRaw * (3.0 - 2.0 * sfRaw)

    -- ===== G-FORCE ESTIMATE =====
    -- Acceleration from frame-to-frame velocity delta, projected onto the
    -- car's flat local axes, then smoothed (raw delta is far too spiky to
    -- drive a camera). accelLong: +forward (throttle) / -forward (braking).
    -- accelLat: +right / -left (cornering).
    local rightVec = vector3(flatForward.y, -flatForward.x, 0.0)
    if Config.GForce and Config.GForce.Enabled and STATE.prevVel then
        local dvx = (velocity.x - STATE.prevVel.x) / dt
        local dvy = (velocity.y - STATE.prevVel.y) / dt
        local rawLong = dvx * flatForward.x + dvy * flatForward.y
        local rawLat  = dvx * rightVec.x   + dvy * rightVec.y
        -- CRASH GUARD: clamp raw accel to a sane range. A hard collision spikes
        -- velocity-delta to thousands of m/s² in one frame, which blows up the
        -- pitch/roll and flips the camera. Real cars stay within ~±20 m/s².
        local accelCap = Config.GForce.MaxRawAccel or 20.0
        rawLong = clamp(rawLong, -accelCap, accelCap)
        rawLat  = clamp(rawLat,  -accelCap, accelCap)
        local gAlpha = smoothAlpha(Config.GForce.Smoothing or 0.12, dt)
        STATE.accelLong = lerp(STATE.accelLong, rawLong, gAlpha)
        STATE.accelLat  = lerp(STATE.accelLat,  rawLat,  gAlpha)
    end
    STATE.prevVel = velocity

    -- ===== PER-GEAR FOV (primary sense of speed) =====
    -- gearProgress sweeps 0->1 across the whole gearbox; RPM sweeps it up
    -- within each gear, so FOV widens through a gear, dips on the upshift,
    -- then climbs again. fov.min/max define the band (spread hard-clamped).
    -- FOV progression is CAPPED at FovCapKmh (default 100) so it stops widening
    -- at high speed — gear shifts can still dip it, but it won't keep climbing.
    local speedFovTarget = nil
    if Config.SpeedFov and Config.SpeedFov.Enabled and type(preset.fov) == 'table' then
        local highGear = GetVehicleHighGear(veh)
        if highGear and highGear > 0 then
            local gear = GetVehicleCurrentGear(veh)
            if gear < 1 then gear = 1 end          -- treat reverse/neutral as 1st
            if gear > highGear then gear = highGear end
            local rpm = GetVehicleCurrentRpm(veh)  -- 0..1
            -- Remap idle..redline so the bottom of each gear isn't dead zone.
            local rFloor = Config.SpeedFov.RpmFloor or 0.2
            local rCeil  = Config.SpeedFov.RpmCeil or 1.0
            local rpmN = clamp((rpm - rFloor) / math.max(0.01, rCeil - rFloor), 0.0, 1.0)
            local gearProgress = clamp(((gear - 1) + rpmN) / highGear, 0.0, 1.0)

            -- Speed ceiling: the FOV cannot progress past what it would be at
            -- FovCapKmh. We model the ceiling as (FovCapKmh / maxSpeedKmh), so
            -- above that speed the FOV plateaus instead of climbing to redline.
            local fovCapKmh = Config.SpeedFov.FovCapKmh or 180.0
            local maxSpeed  = preset.maxSpeedKmh or 150.0
            local progressCeiling = clamp(fovCapKmh / maxSpeed, 0.0, 1.0)
            gearProgress = math.min(gearProgress, progressCeiling)

            -- Clamp the band spread to MaxSpreadDeg.
            local fovLo = preset.fov.min
            local fovHi = preset.fov.max
            local maxSpread = Config.SpeedFov.MaxSpreadDeg or 10.0
            if (fovHi - fovLo) > maxSpread then fovHi = fovLo + maxSpread end
            speedFovTarget = lerp(fovLo, fovHi, gearProgress)

            -- PER-GEAR FOV STACKING: each gear adds a cumulative +0.2° FOV.
            -- Higher gear = wider base FOV. Scales for total gear count so a
            -- 6-speed and 10-speed both feel proportional.
            local gearFovStep = Config.SpeedFov.GearFovStep or 0.2
            speedFovTarget = speedFovTarget + (gear - 1) * gearFovStep
        end
    end

    -- ===== GEAR SHIFT "PUNCH" =====
    -- Detect a gear change, then apply a short eased dip to height/fov/dist.
    local gsHeightDip, gsFovDip, gsDistDip = 0.0, 0.0, 0.0
    if Config.GearShift and Config.GearShift.Enabled then
        -- Read gear from hk-handling statebag (sync_gear) if available,
        -- fall back to native GetVehicleCurrentGear. hk-handling overrides
        -- the gearbox so the native may not update on custom shifts.
        local gear
        local entState = Entity(veh).state
        local syncGear = entState and entState.sync_gear
        if syncGear and syncGear > 0 then
            gear = syncGear
        else
            gear = GetVehicleCurrentGear(veh)
        end
        if gear ~= STATE.prevGear and STATE.prevGear >= 0 and kmh > (Config.GearShift.MinSpeedKmh or 8.0) then
            STATE.shiftAtMs = now
            STATE.shiftWasUp = (gear > STATE.prevGear)  -- true = upshift
        end
        STATE.prevGear = gear

        local elapsed = now - STATE.shiftAtMs
        local dur = Config.GearShift.DurationMs or 320
        if elapsed < dur then
            -- Half-sine pulse: 0 -> peak -> 0 over the duration.
            local t = elapsed / dur
            local pulse = math.sin(t * math.pi)
            gsHeightDip = (Config.GearShift.HeightDip or 0.3) * pulse
            gsDistDip   = (Config.GearShift.DistanceDip or 0.3) * pulse
            -- FOV: upshift = brief WIDEN (bop out), downshift = narrow (dip in)
            if STATE.shiftWasUp then
                gsFovDip = -(Config.GearShift.FovBop or 1.2) * pulse  -- negative = widen
            else
                gsFovDip = (Config.GearShift.FovDip or 0.075) * pulse
            end
        end
    end

    -- ===== HANDBRAKE "PUNCH" =====
    -- A SHORT extra motion when the HANDBRAKE is yanked (not regular S braking) —
    -- an additional snappy dip on top of the normal brake lean. Triggered on the
    -- handbrake's rising edge, and its strength is scaled by how hard the car is
    -- actually decelerating (STATE.accelLong, negative = braking): a handbrake pull
    -- with NO speed drop (already stopped / on ice with no grip) produces no motion.
    -- Shorter duration than the gear punch so it reads as a quick snap, not a sway.
    if Config.Handbrake and Config.Handbrake.Enabled then
        local hb = GetVehicleHandbrake(veh)
        if hb and not STATE.prevHandbrake then
            -- Rising edge: only fire if we're carrying speed AND actually slowing.
            local decel = -math.min(0.0, STATE.accelLong)  -- m/s^2 of deceleration (>=0)
            if kmh > (Config.Handbrake.MinSpeedKmh or 15.0)
               and decel > (Config.Handbrake.MinDecel or 1.5) then
                STATE.handbrakeAtMs = now
                -- Stash the decel-scaled strength (0..1) so the pulse below can use it.
                STATE.handbrakeStrength = clamp(decel / (Config.Handbrake.FullDecel or 8.0), 0.0, 1.0)
            end
        end
        STATE.prevHandbrake = hb

        local hbElapsed = now - STATE.handbrakeAtMs
        local hbDur = Config.Handbrake.DurationMs or 180
        if hbElapsed < hbDur then
            local t = hbElapsed / hbDur
            local pulse = math.sin(t * math.pi) * (STATE.handbrakeStrength or 0.0)
            -- ADD onto the gear-shift dips so it's an EXTRA motion, not a replacement.
            gsHeightDip = gsHeightDip + (Config.Handbrake.HeightDip or 0.10) * pulse
            gsFovDip    = gsFovDip    + (Config.Handbrake.FovDip or 0.10) * pulse
            gsDistDip   = gsDistDip   + (Config.Handbrake.DistanceDip or 0.10) * pulse
        end
    end

    -- ===== AIRBORNE DETECTION & BEHAVIOR (Forza-style) =====
    -- When all wheels leave the ground, switch to a more locked, stable camera:
    -- disable rotational inertia + lateral sway (prevents flip-flop), boost pitch
    -- following (tracks the car's nose angle in the air), add extra height for
    -- framing, and fire a landing shake when the wheels touch back down.
    local airborne = false
    if Config.Airborne and Config.Airborne.Enabled and not STATE.motionLocked then
        airborne = isAirborne(veh)
        -- Smooth the factor in/out so the behavior doesn't snap on/off harshly.
        local targetFactor = airborne and 1.0 or 0.0
        STATE.airborneFactor = lerp(STATE.airborneFactor or 0.0, targetFactor, smoothAlpha(0.08, dt))

        -- LANDING DETECTION: transition from airborne -> grounded
        if STATE.wasAirborne and not airborne then
            if Config.Airborne.LandingShake then
                local intensity = Config.Airborne.LandingShakeIntensity or 0.7
                local shakeName = Config.Airborne.LandingShakeName or 'ROAD_VIBRATION_SHAKE'
                ShakeCam(cam, shakeName, intensity)
                STATE.landingShakeUntil = now + (Config.Airborne.LandingShakeDurationMs or 250)
            end
        end
        STATE.wasAirborne = airborne

        -- Stop landing shake if the duration has passed
        if STATE.landingShakeUntil > 0 and now >= STATE.landingShakeUntil then
            StopCamShaking(cam, false)
            STATE.landingShakeUntil = 0
        end
    else
        STATE.airborneFactor = 0.0
        STATE.wasAirborne = false
    end

    -- Flat "right" vector already computed above as rightVec.
    local right = rightVec

    -- ===== DISTANCE =====
    -- REBUILT: Direct per-V-mode target distances instead of captured baseline.
    -- Each V-mode (NEAR/MEDIUM/FAR) gets a fixed base distance, plus a speed
    -- ramp (minExtraDistance -> maxExtraDistance over 0-rampMaxSpeedKmh).
    -- This eliminates the baseline capture confusion and cap conflicts.

    local baseDist
    -- Per-mode base distances (overridden by preset if provided)
    local modeBaseDistances = {
        [0] = 3.0,   -- NEAR (V pos 2)
        [1] = 5.0,   -- MEDIUM (V pos 3)
        [2] = 7.0,   -- FAR (V pos 4)
    }
    local vm = STATE.currentViewMode or 1
    -- NOTE: baseDistance is now an EXPLICIT distance — NOT scaled by lengthFactor.
    -- Adaptive scaling fought the per-mode caps and made the gap depend on
    -- vehicle size (a long car got pushed way back regardless of the cap).
    baseDist = (preset.baseDistance or modeBaseDistances[vm] or 5.0)
    baseDist = baseDist + (preset.distanceTrim or 0.0)

    -- Speed-distance ramp: lerp(minExtraDistance, maxExtraDistance, speedFactor)
    -- where speedFactor is 0 at idle and 1 at rampMaxSpeedKmh. This ensures the
    -- cam starts further back at low speed and pulls even further at high speed.
    local extraDist = 0.0
    if Config.SpeedDistanceRamp and Config.SpeedDistanceRamp.Enabled then
        -- Per-mode rampMaxSpeedKmh (from merged preset) overrides the global default.
        local rampMax = preset.rampMaxSpeedKmh
            or (Config.SpeedDistanceRamp and Config.SpeedDistanceRamp.RampMaxSpeedKmh)
            or 100.0
        local speedFactor = clamp(kmh / rampMax, 0.0, 1.0)
        local minExtra = preset.minExtraDistance or 0.0
        local maxExtra = preset.maxExtraDistance or 0.0
        extraDist = lerp(minExtra, maxExtra, speedFactor)
    else
        -- Legacy: just use maxExtraDistance scaled by the capped speed factor sf
        extraDist = (preset.maxExtraDistance or 0.0) * sf
    end
    local distance = baseDist + extraDist - gsDistDip
    -- Hard cap on how far back the cam can sit (now actually useful for limiting max distance)
    if preset.maxBaseDistance then
        distance = math.min(distance, preset.maxBaseDistance)
    end

    -- DEBUG: print actual distance every 100 frames when moving fast
    if Config.Debug and STATE.debugFrameCount and STATE.debugFrameCount % 100 == 0 and kmh > 100 then
        print(('[RACECAM] Speed=%.0f km/h | baseDist=%.2f | extraDist=%.2f | gOffset=%.2f | FINAL distance=%.2f'):format(
            kmh, baseDist, extraDist, gOffset or 0, distance))
    end
    STATE.debugFrameCount = (STATE.debugFrameCount or 0) + 1
    local height   = ((preset.baseHeight or 3.0) * params.heightFactor)
                   + (preset.heightLift or 0.0)
                   - ((preset.heightDropAtSpeed or 0.0) * sf)
                   - gsHeightDip

    -- ROOF ANCHORING: shift the camera up by how much taller this vehicle's roof
    -- is than a reference car. Because the look target gets the SAME shift below,
    -- the viewing ANGLE stays identical across a low coupe and a tall SUV — the
    -- camera just rides higher to match the taller roof instead of staring down
    -- at it. roofShift = 0 for a normal car, grows for SUVs/trucks.
    local refRoofZ = (Config.Adaptive and Config.Adaptive.RefRoofZ) or 0.75
    local roofShift = math.max(0.0, (params.roofZ or refRoofZ) - refRoofZ)
    height = height + roofShift

    -- AIRBORNE: add extra height while in the air so the framing doesn't compress
    -- as the car rises (keeps the car in view during jumps).
    if STATE.airborneFactor > 0.0 then
        local extraHeight = (Config.Airborne.ExtraHeight or 0.3) * STATE.airborneFactor
        height = height + extraHeight
    end

    -- Floor on height so dips / drops never put the cam below the roofline
    -- (which is what made it stare down at the car's top).
    if preset.minHeight then
        height = math.max(height, preset.minHeight)
    end

    -- ===== G-FORCE LONGITUDINAL OFFSET =====
    -- Hard accel drifts the cam back (car pulls away); braking compresses it
    -- in (nose-dive feel). Pitch handled later via the look target height.
    local gOffset = 0.0
    if Config.GForce and Config.GForce.Enabled and not STATE.motionLocked then
        local a = STATE.accelLong
        -- Speed multiplier: pull-back effect scales UP with speed.
        -- At 60kmh = 1.0×, ramps to 2.5× at 250kmh (acceleration at high speed
        -- produces more camera drama even though the G-force is lower).
        local pullSpeedMult = 1.0 + clamp((kmh - 60.0) / 120.0, 0.0, 1.5)
        -- GEAR SHIFT BOOST: during an upshift, amplify the pull-back (car "pulls away"
        -- harder as it grabs the next gear). Half-sine pulse over the shift duration.
        local shiftElapsed = now - STATE.shiftAtMs
        local shiftDur = Config.GearShift and Config.GearShift.DurationMs or 650
        if STATE.shiftWasUp and shiftElapsed < shiftDur then
            local shiftT = shiftElapsed / shiftDur
            local shiftPulse = math.sin(shiftT * math.pi)  -- 0→1→0
            pullSpeedMult = pullSpeedMult * (1.0 + shiftPulse * 1.0)  -- 2× at shift peak
        end
        -- RPM-based continuous pull: as you climb through a gear, camera
        -- gradually drifts back. Scales with gear number so high gears (where
        -- RPM sits lower) still produce visible pull.
        local rpm = GetVehicleCurrentRpm(veh)
        local curGearPull = STATE.prevGear or 1
        local gearBoost = 1.0 + (curGearPull - 1) * 0.15  -- +15% per gear above 1st
        local rpmPull = rpm * rpm * 0.35 * gearBoost
        pullSpeedMult = pullSpeedMult + rpmPull
        if a >= 0.0 then
            gOffset = a * (Config.GForce.AccelPullBack or 0.06) * pullSpeedMult
        else
            gOffset = a * (Config.GForce.BrakePushIn or 0.10)  -- brake: no speed boost needed
        end
        local maxG = (Config.GForce.MaxLongOffset or 0.8) * pullSpeedMult
        gOffset = clamp(gOffset, -maxG, maxG)
    end
    distance = distance + gOffset

    -- ===== MOTION LOCK =====
    -- When locked, freeze distance/height/fov at the values from the moment
    -- of locking and drop the lateral sway. The cam still follows the car's
    -- position/heading, but stops the dynamic zoom/swing entirely.
    local lateral = 0.0
    if STATE.motionLocked then
        if not STATE.lockedDist then
            STATE.lockedDist   = distance
            STATE.lockedHeight = height
            STATE.lockedFov    = STATE.curFov
        end
        distance = STATE.lockedDist
        height   = STATE.lockedHeight
    else
        -- FORZA-STYLE LATERAL: dead zone below threshold, then slow ramp up.
        -- Zero sway below LatDeadZoneKmh, scales to full at LatFullSpeedKmh.
        local latDeadZone = (Config.GForce and Config.GForce.LatDeadZoneKmh) or 30.0
        local latFullSpeedKmh = (Config.GForce and Config.GForce.LatFullSpeedKmh) or 320.0
        local latOverallScale = (Config.GForce and Config.GForce.LatOverallScale) or 0.14
        local latSpeedScale = 0.0
        if kmh > latDeadZone then
            local t = clamp((kmh - latDeadZone) / (latFullSpeedKmh - latDeadZone), 0.0, 1.0)
            -- Smoothstep for gradual ramp (no pop)
            latSpeedScale = t * t * (3.0 - 2.0 * t) * latOverallScale
        end

        -- Lateral velocity component (slide direction)
        if preset.lateralFactor and preset.lateralFactor > 0.0 then
            local along = velocity.x * flatForward.x + velocity.y * flatForward.y
            local lateralVec = vector3(velocity.x - flatForward.x * along, velocity.y - flatForward.y * along, 0.0)
            local lateralVel = #lateralVec
            local sign = ((velocity.x * right.x + velocity.y * right.y) >= 0.0) and 1.0 or -1.0
            lateral = lateralVel * sign * preset.lateralFactor * 0.015 * latSpeedScale
        end
        -- G-force cornering: push cam toward outside of turn (speed-scaled)
        if Config.GForce and Config.GForce.Enabled then
            local latShift = -STATE.accelLat * (Config.GForce.LatShiftPerG or 0.026) * latSpeedScale
            local maxLat = (Config.GForce.MaxLatShift or 0.39) * latSpeedScale
            lateral = lateral + clamp(latShift, -maxLat, maxLat)
        end
        -- BASELINE STEERING SWAY (always-on, unlocked only): a small lateral offset
        -- driven by steering rather than lateral velocity. The velocity terms above
        -- are dead below LatDeadZoneKmh and near-zero in GTA grip corners, so without
        -- this the chase cam sits at exactly 0 lateral — and drift exit then has to
        -- land on 0, which reads as a tiny snap. A non-zero baseline removes that seam.
        -- Reuses STATE.smoothedSteer (slew-limited + 0.22s tau, computed in the orbit
        -- block below, so this is one frame stale — imperceptible at this magnitude).
        local baseSway = Config.FrontChase.ChaseSway or 0.06
        if baseSway > 0.0 then
            -- Track the effective max steering angle (GTA reduces it at speed).
            -- Use a fast-rise / slow-decay tracker so full lock always reads as 1.0.
            local absSteer = math.abs(STATE.smoothedSteer or 0.0)
            STATE.steerMaxTrack = STATE.steerMaxTrack or 40.0
            if absSteer > STATE.steerMaxTrack then
                STATE.steerMaxTrack = absSteer  -- instant rise to new peak
            else
                STATE.steerMaxTrack = lerp(STATE.steerMaxTrack, math.max(absSteer, 12.0), smoothAlpha(2.0, dt))
            end
            local steerDenom = math.max(STATE.steerMaxTrack, 12.0)  -- floor at 12° (never divide by tiny)
            local swayNorm = clamp((STATE.smoothedSteer or 0.0) / steerDenom, -1.0, 1.0)
            local swaySign = swayNorm >= 0 and 1.0 or -1.0
            local swayAbs = math.abs(swayNorm)
            -- Smoothstep, matching the orbit easing so the two move together
            local swayEased = swayAbs * swayAbs * (3.0 - 2.0 * swayAbs)
            -- CROSS-FADE vs drift: in a slide you counter-steer, so steering sway and
            -- driftLateralOffset point OPPOSITE ways and cancel/fight. Fade this out as
            -- driftMix rises so exactly one source owns lateral at any moment, and the
            -- handover is continuous in both directions (no step at either boundary).
            if Config.FrontChase.ChaseSwayDriftFade ~= false then
                swayEased = swayEased * (1.0 - clamp(STATE.driftMix or 0.0, 0.0, 1.0))
            end
            -- SPEED SCALE: full sway at idle, tapering to ChaseSwayMinScale at
            -- ChaseSwayFullKmh. Smoothstep so the mid-range values fall off evenly
            -- rather than lerping straight down.
            local swayFullKmh = Config.FrontChase.ChaseSwayFullKmh or 400.0
            local swayMinScale = Config.FrontChase.ChaseSwayMinScale or 0.02
            local swaySpeedT = clamp(kmh / swayFullKmh, 0.0, 1.0)
            swaySpeedT = swaySpeedT * swaySpeedT * (3.0 - 2.0 * swaySpeedT)  -- smoothstep
            local swaySpeedScale = lerp(1.0, swayMinScale, swaySpeedT)
            lateral = lateral + swaySign * swayEased * baseSway * swaySpeedScale
        end
        -- AIRBORNE: reduce lateral sway in the air
        if STATE.airborneFactor > 0.0 then
            local swayScale = lerp(1.0, Config.Airborne.LateralSwayScale or 0.1, STATE.airborneFactor)
            lateral = lateral * swayScale
        end
    end

    -- ===== CORNERING REAR-SWING (Forza-style) =====
    -- Rotate the camera's BEHIND-THE-CAR position around the car by a small angle
    -- toward the INSIDE of the turn. Because the cam moves off the car's centreline,
    -- you see the rear three-quarter — the bumper/spoiler swings into view, with a
    -- bit of the near door — instead of a flat tail-on shot. The aim math below
    -- still points back at the car, so it just reframes the rear corner.
    --
    -- The swing RAMPS with steering up to MaxSteerDeg (the "turn point" in the
    -- player's [——— ^^ ———] model): past that point it's capped and the camera
    -- behaves like a normal following cam that only tilts.
    local swungForward = flatForward
    if Config.Cornering and Config.Cornering.Enabled and Config.Cornering.RearSwing
       and Config.Cornering.RearSwing.Enabled and not STATE.motionLocked then
        local rs = Config.Cornering.RearSwing
        local targetSwingDeg = 0.0
        if kmh > (rs.MinSpeedKmh or 10.0) then
            local steer = GetVehicleSteeringAngle(veh)            -- + = left, - = right
            local steerMag = math.abs(steer)
            -- CAP & HOLD: ramp the swing in only up to HoldSteerDeg, then PIN it at
            -- the full angle and HOLD — past that steering point the swing no longer
            -- grows toward max wheel lock (the user's "hold on to that angle" ask).
            -- This makes the reframe reach its cap early in the turn and stay put,
            -- instead of tracking the wheels all the way to full lock.
            local holdDeg = rs.HoldSteerDeg or 8.0
            local t = clamp(steerMag / holdDeg, 0.0, 1.0)
            local eased = t * t * (3.0 - 2.0 * t)                 -- smoothstep ramp-in
            -- INVERT: rotate toward the OUTSIDE of the turn (away from steering), not
            -- the inside. Steer left (positive) → swing right (negative angle), and
            -- vice versa. This makes the vehicle's far-side rear quarter come into view.
            local sign = (steer >= 0.0) and -1.0 or 1.0
            targetSwingDeg = sign * eased * (rs.MaxAngleDeg or 14.0)
        end
        -- ASYMMETRIC SMOOTHING: ease IN at Smoothing, but RETURN faster
        -- (ReturnSmoothing, a smaller tau) when straightening so the swing decays
        -- back toward centre sooner — cuts the "latency at the end" the user flagged.
        local returning = math.abs(targetSwingDeg) < math.abs(STATE.rearSwingDeg or 0.0)
        local swingTau = returning
            and (rs.ReturnSmoothing or rs.Smoothing or 0.12)
            or  (rs.Smoothing or 0.12)
        local swingAlpha = smoothAlpha(swingTau, dt)
        STATE.rearSwingDeg = lerp(STATE.rearSwingDeg or 0.0, targetSwingDeg, swingAlpha)
        -- Rotate flatForward around Z by the swing angle (degrees -> rad).
        local a = math.rad(STATE.rearSwingDeg)
        local ca, sa = math.cos(a), math.sin(a)
        swungForward = vector3(
            flatForward.x * ca - flatForward.y * sa,
            flatForward.x * sa + flatForward.y * ca,
            0.0)
    end

    -- ===== FRONT-CHASE: camera in front, looking back =====
    -- When FrontChase is enabled, override distance/height with the front-facing
    -- curve and flip the camera to sit IN FRONT of the vehicle. All effects
    -- (G-force, lateral sway, cornering) still apply — only the base position flips.
    local frontChase = Config.FrontChase and Config.FrontChase.Enabled
    if frontChase then
        local fc = Config.FrontChase

        -- BREAKPOINT CURVE: piecewise interpolation with smoothstep between points.
        -- Gives full control over the pull-back shape at every speed range.
        local bps = fc.Breakpoints
        local rawDist = bps[1][2]  -- default to first point
        if bps and #bps >= 2 then
            if kmh <= bps[1][1] then
                rawDist = bps[1][2]
            elseif kmh >= bps[#bps][1] then
                rawDist = bps[#bps][2]
            else
                for i = 1, #bps - 1 do
                    if kmh >= bps[i][1] and kmh <= bps[i+1][1] then
                        local s0, d0 = bps[i][1], bps[i][2]
                        local s1, d1 = bps[i+1][1], bps[i+1][2]
                        local t = (kmh - s0) / (s1 - s0)
                        t = t * t * (3.0 - 2.0 * t)  -- smoothstep within segment
                        rawDist = d0 + (d1 - d0) * t
                        break
                    end
                end
            end
        end

        -- SMOOTH THE DISTANCE VALUE (not the world position). Position stays
        -- entity-locked so there is no chase lag at speed, but the zoom ramp is
        -- damped so per-frame speed jitter no longer judders the camera.
        local distTau = fc.DistanceSmoothing or 0.35
        local dAlpha = smoothAlpha(distTau, dt)
        STATE.fcDist = STATE.fcDist and lerp(STATE.fcDist, rawDist, dAlpha) or rawDist
        distance = STATE.fcDist - gsDistDip  -- apply gear-shift/handbrake punch

        height = (fc.Height or 2.0) * params.heightFactor
        -- Speed-based height ramp: 12% lower at 0 km/h, full height at 145 km/h.
        local heightRampKmh = fc.HeightFullSpeedKmh or 145.0
        local heightDip = fc.HeightLowSpeedDip or 0.02
        local heightScale = 1.0 - heightDip * (1.0 - clamp(kmh / heightRampKmh, 0.0, 1.0))
        height = height * heightScale
        -- SPEED SENSE: drop height at speed (camera closer to ground = faster feel)
        local dropAmount = fc.HeightDropAtSpeed or 0.14
        local dropFullKmh = fc.HeightDropFullKmh or 200.0
        local dropT = clamp(kmh / dropFullKmh, 0.0, 1.0)
        dropT = dropT * dropT  -- ease-in (barely drops at low speed, ramps at high)
        height = height - (dropAmount * dropT)

        -- V-KEY MODE SCALING for FrontChase (near/medium/far feel)
        -- Current values = medium (mode 1). Scale distance+height for other modes.
        -- Smoothed so V-key transitions ease in rather than snapping.
        local fcVm = STATE.currentViewMode or 1
        local fcModeScales = fc.ViewModeScales or { [0] = 0.88, [1] = 1.0, [2] = 1.14 }
        local fcTargetScale = fcModeScales[fcVm] or 1.0
        local fcSmoothTau = fc.ViewModeSmoothness or 0.30  -- seconds
        local fcAlpha = smoothAlpha(fcSmoothTau, dt)
        STATE.fcModeScale = lerp(STATE.fcModeScale, fcTargetScale, fcAlpha)
        distance = distance * STATE.fcModeScale + (STATE.dragDistOffset or 0.0) + (STATE.driftDistOffset or 0.0) + (chaseAdj.offsetY or 0.0) + ((savedChasePresets[vehicleKey(veh)] or {}).offsetY or 0.0)
        height = height * STATE.fcModeScale + (STATE.dragHeightOffset or 0.0) + (STATE.driftHeightOffset or 0.0) + (chaseAdj.offsetZ or 0.0) + ((savedChasePresets[vehicleKey(veh)] or {}).offsetZ or 0.0)
    end

    -- ===== MUSCLE CAR: ENTITY-TRANSFORM-BASED POSITIONING =====
    -- For muscle-handling vehicles, use GetOffsetFromEntityInWorldCoords instead of
    -- heading-based flatForward computation. This native uses the entity's own 4x4
    -- transform matrix, so the camera position is ALWAYS perfectly synced with the
    -- car's actual rotation — eliminates the internal heading desync that causes the
    -- phantom pivot under RenderScriptCams. All effects (FOV, shake, G-force, etc.)
    -- still apply on top; only the base position/rotation source changes.
    local muscleMode = isMuscleHandling(veh)
    local targetPos

    if frontChase then
        -- FRONT-CHASE: camera BEHIND vehicle, using FLATTENED heading + world-up.
        -- Uses heading-only basis so slope/pitch NEVER contaminates the offset.
        -- Height is pure world-Z (not rotated with car pitch). This gives
        -- instant no-lag positioning (recalculated from entity pos each frame)
        -- without the hill distortion of GetOffsetFromEntityInWorldCoords.
        local right2d = vector3(swungForward.y, -swungForward.x, 0.0)
        local totalLateral = lateral + (STATE.motionLocked and 0.0 or (STATE.driftLateralOffset or 0.0))
        -- DRIFT ORBIT: blend the camera's orbit direction between car heading
        -- and VELOCITY direction. This makes the camera stay behind where you're
        -- GOING, so the car appears sideways in frame (NFS side-panel reveal).
        -- SMOOTHED BASE: during drift exit (gauge decaying), smooth the base heading
        -- so the car straightening doesn't jerk the camera position.
        local baseDir = swungForward
        -- Smoothed orbit direction: stays active until fully converged to swungForward.
        -- This prevents the snap at the exact moment gauge reaches 0.
        local sdx = STATE.driftSmoothedDirX
        local sdy = STATE.driftSmoothedDirY
        local needSmoothing = (STATE.driftGauge or 0.0) > 0.0 or sdx ~= nil
        if needSmoothing then
            local dirTau = (not STATE.driftActive) and 0.35 or 0.08
            local dirAlpha = smoothAlpha(dirTau, dt)
            sdx = sdx or swungForward.x
            sdy = sdy or swungForward.y
            local dirTarget = STATE.driftActive and swungForward or flatForward
            sdx = lerp(sdx, dirTarget.x, dirAlpha)
            sdy = lerp(sdy, dirTarget.y, dirAlpha)
            local mag = math.sqrt(sdx * sdx + sdy * sdy)
            if mag > 0.01 then sdx, sdy = sdx / mag, sdy / mag end
            -- Check if converged (close enough to swungForward to stop smoothing)
            local diffX = math.abs(sdx - swungForward.x)
            local diffY = math.abs(sdy - swungForward.y)
            if diffX < 0.005 and diffY < 0.005 and (STATE.driftGauge or 0.0) <= 0.0 then
                -- Fully converged + gauge gone: stop smoothing
                STATE.driftSmoothedDirX = nil
                STATE.driftSmoothedDirY = nil
            else
                STATE.driftSmoothedDirX = sdx
                STATE.driftSmoothedDirY = sdy
                baseDir = vector3(sdx, sdy, 0.0)
            end
        end
        local orbitDir = baseDir

        -- UNIFIED ORBIT: one system, variable strength.
        -- Normal chase: subtle orbit (ChaseOrbitBlend ~0.04)
        -- Drift held: orbit extends to DriftCam.OrbitBlend (~0.38)
        -- Drift released: strength smoothly returns to chase level.
        -- ONE orbitDir, ONE pivot, ONE set of caps. No fighting.
        -- ORBIT: chase steering orbit is ALWAYS applied. Drift adds a velocity
        -- blend ON TOP, scaled by a smoothed mix factor. Both contributions are
        -- computed every frame — no branch switching, so no input-source snap
        -- when the drift key changes state.

        -- Chase strength: speed-scaled breakpoints
        -- 0-35kmh: 0.08 | 35-100kmh: 0.08->0.03 | 100-220kmh: 0.03->0.01 | 220+: 0.01
        local chaseStrength
        if kmh <= 35.0 then
            chaseStrength = 0.0035
        elseif kmh <= 100.0 then
            chaseStrength = lerp(0.0035, 0.0014, (kmh - 35.0) / 65.0)
        elseif kmh <= 180.0 then
            chaseStrength = lerp(0.0014, 0.0007, (kmh - 100.0) / 80.0)
        else
                        chaseStrength = 0.0007
        end

        -- Drift mix: 0 = pure chase, 1 = full drift contribution. Smoothed so the
        -- key press/release ramps instead of stepping.
        local dCfg = Config.DriftCam or {}
        local driftFact = STATE.driftFactor or 0.0
        local driftGauge = STATE.driftGauge or 0.0
        local orbitSpeedTaper = 1.0  -- speed-inverse: more range at low speed, less at high
        -- Custom breakpoint taper for drift left/right range:
        -- 25kmh=70%, 50kmh=25%, 215kmh+=10%
        if kmh <= 25.0 then
            orbitSpeedTaper = 0.70
        elseif kmh <= 50.0 then
            orbitSpeedTaper = lerp(0.70, 0.25, (kmh - 25.0) / 25.0)
        elseif kmh <= 215.0 then
            orbitSpeedTaper = lerp(0.25, 0.10, (kmh - 50.0) / 165.0)
        else
            orbitSpeedTaper = 0.10
        end

        local mixTarget = 0.0
        local pivotTarget = 0.0
        if STATE.driftActive then
            -- Locked mode: only 15% of drift orbit
            local driftScale = STATE.motionLocked and 0.0 or 0.0155
            mixTarget = driftFact * driftGauge * orbitSpeedTaper
            pivotTarget = driftFact * driftGauge * (dCfg.PivotForward or 1.2) * orbitSpeedTaper
        end
        STATE.driftMix = STATE.driftMix or 0.0
        STATE.orbitPivot = STATE.orbitPivot or 0.0
        -- Rise tau 0.5s (slow — spam doesn't bounce), decay 0.65-1.2s (speed-dependent)
        local mixTau = (mixTarget > STATE.driftMix) and 0.8
            or lerp(1.2, 0.65, clamp((kmh - 20.0) / 100.0, 0.0, 1.0))
        local mixAlpha = smoothAlpha(mixTau, dt)
        if not STATE.driftInGrace then
            STATE.driftMix = lerp(STATE.driftMix, mixTarget, mixAlpha)
            STATE.orbitPivot = lerp(STATE.orbitPivot, pivotTarget, mixAlpha)
        end
        STATE.orbitStrength = chaseStrength   -- exposed for debug/HUD

        local driftPivotFwd = STATE.orbitPivot

        if not STATE.motionLocked then
            -- 1) CHASE LAYER (always): rotate by SMOOTHED steering angle.
            --    Raw steering snaps to 0 on A/D release — smooth it so the orbit
            --    eases back to center instead of jumping.
            local rawSteer = GetVehicleSteeringAngle(veh)   -- + left, - right (degrees)
            STATE.smoothedSteer = STATE.smoothedSteer or 0.0
            -- SLEW-RATE LIMIT: cap how fast the smoothed steering can change per second.
            -- Prevents drift mode's instant angle inversion from snapping the orbit.
            local maxSteerRate = 15.0  -- degrees per second max change (smoother)
            local steerDelta = rawSteer - STATE.smoothedSteer
            local maxStep = maxSteerRate * dt
            if math.abs(steerDelta) > maxStep then
                STATE.smoothedSteer = STATE.smoothedSteer + maxStep * (steerDelta > 0 and 1.0 or -1.0)
            else
                -- Within slew limit: apply normal smoothing
                local steerTau = 0.50
                STATE.smoothedSteer = lerp(STATE.smoothedSteer, rawSteer, smoothAlpha(steerTau, dt))
            end
            -- DEADBAND: snap to 0 when very close to center (prevents shimmer/micro-snap)
            if math.abs(STATE.smoothedSteer) < 0.4 and math.abs(rawSteer) < 0.4 then
                STATE.smoothedSteer = 0.0
            end
            -- Apply smoothstep to the steering magnitude so the orbit eases in/out
            -- instead of linearly bopping with A/D taps.
            -- DEADZONE: ignore the first N% of steering travel so light corrections
            -- don't move the camera at all. Only meaningful steering registers.
            local steerDeadzone = Config.FrontChase.SteerDeadzone or 0.25
            local rawNorm = clamp(STATE.smoothedSteer / math.max(STATE.steerMaxTrack or 40.0, 12.0), -1.0, 1.0)
            local rawSign = rawNorm >= 0 and 1.0 or -1.0
            local rawAbs = math.abs(rawNorm)
            local steerNorm = 0.0
            if rawAbs > steerDeadzone then
                -- Renormalize the remainder above the deadzone to 0..1
                steerNorm = rawSign * ((rawAbs - steerDeadzone) / (1.0 - steerDeadzone))
            end
            local steerSign = steerNorm >= 0 and 1.0 or -1.0
            local steerAbs = math.abs(steerNorm)
            -- Smoothstep: ease in/out (kills the linear bop)
            local steerEased = steerAbs * steerAbs * (3.0 - 2.0 * steerAbs)
            local steerRad = math.rad(-steerSign * steerEased * 40.0 * chaseStrength * 0.21)
            local ca, sa = math.cos(steerRad), math.sin(steerRad)
            orbitDir = vector3(
                orbitDir.x * ca - orbitDir.y * sa,
                orbitDir.x * sa + orbitDir.y * ca,
                0.0)

            -- Orbit FOV dip: steering narrows FOV slightly (max 2° at 0.08, 0.6° at 0.01)
            local maxFovDip = lerp(0.6, 2.0, clamp((chaseStrength - 0.01) / 0.07, 0.0, 1.0))
            local steerMag = math.abs(STATE.smoothedSteer) / math.max(STATE.steerMaxTrack or 40.0, 12.0)
            STATE.orbitFovDip = lerp(STATE.orbitFovDip or 0.0, maxFovDip * clamp(steerMag, 0.0, 1.0), smoothAlpha(0.15, dt))

            -- 2) DRIFT LAYER (additive): blend the already-steered direction toward
            --    velocity. Fades with driftMix, so releasing the key leaves the chase
            --    steering orbit untouched underneath — nothing to snap back from.
            -- GRACE: skip live velocity blend during grace (camera holds position).
            if STATE.driftMix > 0.001 and not STATE.driftInGrace then
                local velMag2d = math.sqrt(velocity.x * velocity.x + velocity.y * velocity.y)
                if velMag2d > 1.0 then
                    local velDir = vector3(velocity.x / velMag2d, velocity.y / velMag2d, 0.0)
                    local blend = (dCfg.OrbitBlend or 0.07) * STATE.driftMix
                    orbitDir = vector3(
                        lerp(orbitDir.x, velDir.x, blend),
                        lerp(orbitDir.y, velDir.y, blend),
                        0.0)
                end
            end

            local mag = math.sqrt(orbitDir.x * orbitDir.x + orbitDir.y * orbitDir.y)
            if mag > 0.01 then orbitDir = vector3(orbitDir.x / mag, orbitDir.y / mag, 0.0) end

            -- HARD ANGLE CAP: clamp total orbit deviation from baseDir to a fixed
            -- degree limit. Steering and the drift velocity blend both push orbitDir,
            -- and in a full-lock ~270 slide they stack — this is the single ceiling
            -- that bounds the worst case regardless of how they combine.
            local capDeg = STATE.driftActive
                and (Config.FrontChase.DriftOrbitMaxDeg or 6.0)
                or (Config.FrontChase.ChaseOrbitMaxDeg or 4.0)
            -- Signed angle from baseDir to orbitDir (2D cross/dot -> atan2)
            local crossZ = baseDir.x * orbitDir.y - baseDir.y * orbitDir.x
            local dotB   = baseDir.x * orbitDir.x + baseDir.y * orbitDir.y
            local devDeg = math.deg(math.atan(crossZ, dotB))
            if math.abs(devDeg) > capDeg then
                -- Re-derive orbitDir at exactly the cap, preserving the turn side.
                local clampRad = math.rad(capDeg * (devDeg > 0 and 1.0 or -1.0))
                local cc, sc = math.cos(clampRad), math.sin(clampRad)
                orbitDir = vector3(
                    baseDir.x * cc - baseDir.y * sc,
                    baseDir.x * sc + baseDir.y * cc,
                    0.0)
            end
        end
        -- LOCKED: skip all orbit manipulation, use raw baseDir (no sway/drift/smoothing)
        if STATE.motionLocked then
            orbitDir = flatForward
            STATE.smoothedOrbitX = flatForward.x
            STATE.smoothedOrbitY = flatForward.y
        else
        -- FINAL ORBIT SMOOTHING + DRIFT HEADING LAG:
        -- Normal: camera tracks heading with standard smoothing (0.30s tau)
        -- Drift active: camera tracks heading with HEAVY lag (1.2s tau) so the
        -- car rotates in frame (NFS/Forza style — camera stays, car swings).
        -- This is what makes the side panel visible without moving the camera.
        STATE.smoothedOrbitX = STATE.smoothedOrbitX or orbitDir.x
        STATE.smoothedOrbitY = STATE.smoothedOrbitY or orbitDir.y
        local baseSmoothTau = 0.30
        local driftLagTau = 1.2  -- heavy lag during drift (car rotates, cam stays)
        local orbitSmoothTau = lerp(baseSmoothTau, driftLagTau, clamp((STATE.driftMix or 0.0), 0.0, 1.0))
        local orbitSmoothAlpha = smoothAlpha(orbitSmoothTau, dt)
        STATE.smoothedOrbitX = lerp(STATE.smoothedOrbitX, orbitDir.x, orbitSmoothAlpha)
        STATE.smoothedOrbitY = lerp(STATE.smoothedOrbitY, orbitDir.y, orbitSmoothAlpha)
        orbitDir = vector3(STATE.smoothedOrbitX, STATE.smoothedOrbitY, 0.0)
        local oMag = math.sqrt(orbitDir.x * orbitDir.x + orbitDir.y * orbitDir.y)
        if oMag > 0.01 then orbitDir = vector3(orbitDir.x / oMag, orbitDir.y / oMag, 0.0) end
        end

        local pivotPos = vehPos + (flatForward * driftPivotFwd)
        -- Camera behind the ORBIT direction (blended heading/velocity)
        local orbitRight = vector3(orbitDir.y, -orbitDir.x, 0.0)
        targetPos = pivotPos
            - (orbitDir * distance)
            + (orbitRight * totalLateral)
            + vector3(0.0, 0.0, height)
    elseif muscleMode then
        -- Muscle cars: same flattened basis (was entity-transform, same hill bug)
        local right2d = vector3(swungForward.y, -swungForward.x, 0.0)
        targetPos = vehPos
            - (swungForward * distance)
            + (right2d * lateral)
            + vector3(0.0, 0.0, height)
    else
        -- Normal: heading-based positioning (existing logic for all other vehicles)
        targetPos = vehPos
            - (swungForward * distance)
            + (right * lateral)
            + vector3(0.0, 0.0, height)
    end

    -- VELOCITY COMPENSATION: the exponential smoothing (lerp toward target)
    -- creates velocity-proportional lag — at high speed the cam trails the car
    -- by ~(velocity × tau) extra metres, making it drift way back. Compensate
    -- by offsetting the target forward along the velocity by that predicted lag,
    -- so the steady-state distance stays at `distance` regardless of speed.
    -- During the engage window, use the ramped actualTau (not the preset baseline)
    -- so the compensation matches the growing smoothing and the cam doesn't drift.
    -- CRITICAL FIX: only compensate XY (horizontal), NOT Z. On a descent velocity.z
    -- is negative (moving downward), so adding vel.z*tau PULLS THE CAM DOWN into the
    -- ground every frame (the "camera pulled straight DOWN" bug). Z should follow the
    -- height value, not the vehicle's vertical velocity.
    -- NOTE: For muscle cars, vel-comp is DISABLED (entity-transform already tracks perfectly).
    local tau = actualTau or (preset.smoothness or 0.12)
    if tau > 0.0 and not muscleMode and not frontChase then
        targetPos = targetPos + vector3(velocity.x * tau, velocity.y * tau, 0.0)  -- Z=0, no vertical comp
    end

    -- ===== CAMERA COLLISION =====
    -- Stop the cam clipping through walls / going underground (concrete barriers,
    -- tunnels, terrain) by raycasting from a point near the car out to the desired
    -- camera position. If world geometry is hit, pull the cam IN to just before the
    -- hit so it stays on the near side of the wall.
    if Config.Collision and Config.Collision.Enabled and not STATE.motionLocked then
        -- Anchor the ray at the car, near the look-target height (not the ground),
        -- so the probe travels through the same space the camera occupies.
        local anchor = vehPos + vector3(0.0, 0.0, (preset.lookHeight or 1.3) * 0.8)
        local toCam = targetPos - anchor
        local len = #toCam
        if len > 0.01 then
            local dir = toCam / len
            -- EARLY ENGAGE: cast the probe PAST the desired camera position by a
            -- lookahead margin, so a wall is detected before the cam actually
            -- reaches it and the pull-in starts a touch early instead of at the
            -- moment of contact (the user's "engage slightly earlier" ask).
            local lookahead = Config.Collision.Lookahead or 0.0
            local probeEnd = anchor + dir * (len + lookahead)
            -- Flags 1 (world) + 16 (objects); ignore the player vehicle itself.
            -- SYNCHRONOUS probe so the result is guaranteed ready THIS frame (the
            -- async StartShapeTestLosProbe can return "not ready" → missed hits).
            local flags = Config.Collision.Flags or (1 + 16)
            local handle = StartExpensiveSynchronousShapeTestLosProbe(
                anchor.x, anchor.y, anchor.z,
                probeEnd.x, probeEnd.y, probeEnd.z,
                flags, veh, 7)
            local _, hit, hitCoords = GetShapeTestResult(handle)
            if hit == 1 then
                -- Pull the cam to the hit point minus a small skin so it never
                -- pokes through, but never closer than MinDistance to the car.
                local skin = Config.Collision.Skin or 0.3
                local hitDist = #(hitCoords - anchor) - skin
                local minD = Config.Collision.MinDistance or 1.2
                hitDist = math.max(minD, hitDist)
                if hitDist < len then
                    targetPos = anchor + dir * hitDist
                end
            end
        end
    end

    -- The weight: lerp current toward target (frame-rate independent).
    -- FRONT-CHASE: direct snap (no lerp) — entity-relative positioning already
    -- tracks perfectly; lerp would cause the car to outrun the camera at speed.
    if frontChase then
        STATE.curPos = targetPos
    else
        STATE.curPos = lerpVec(STATE.curPos, targetPos, posAlpha)
    end

    -- Reverse exit: no blend, normal chase takes over immediately.
    if STATE.reverseExitMs then
        STATE.reverseExitMs = nil
        STATE.reverseExitPos = nil
    end

    -- ===== STABILIZER: HEIGHT DAMPING =====
    -- Smooth the Z component separately so bumps/terrain are absorbed
    -- while XY stays tight (entity-relative, no lateral lag).
    -- Clamped: camera can't deviate too far above/below the true target.
    if Config.Stabilizer and Config.Stabilizer.Enabled then
        local stabTau = Config.Stabilizer.HeightTau or 0.10
        if STATE.stabSmoothedZ == nil then
            STATE.stabSmoothedZ = STATE.curPos.z
        end
        local zAlpha = smoothAlpha(stabTau, dt)
        STATE.stabSmoothedZ = lerp(STATE.stabSmoothedZ, STATE.curPos.z, zAlpha)
        -- Clamp deviation: don't let stabilized Z drift too far from target
        local maxUp = Config.Stabilizer.MaxDeviationUp or 0.18
        local maxDown = Config.Stabilizer.MaxDeviationDown or 0.22
        local targetZ = STATE.curPos.z
        STATE.stabSmoothedZ = clamp(STATE.stabSmoothedZ, targetZ - maxDown, targetZ + maxUp)
        STATE.curPos = vector3(STATE.curPos.x, STATE.curPos.y, STATE.stabSmoothedZ)
    end

    SetCamCoord(cam, STATE.curPos.x, STATE.curPos.y, STATE.curPos.z)

    -- ===== CAMERA ROTATION: PITCH / YAW / ROLL =====
    -- Switch from PointCamAtCoord to SetCamRot to support camera ROLL (tilt into
    -- corners). Calculate pitch/yaw from the look-direction, add cornering roll.

    -- Look slightly ahead of the car, more so the faster you go.
    local lookAhead = (preset.lookAheadBase or 1.0) + (preset.lookAheadSpeed or 0.0) * sf
    -- ANTI-FLIP: keep aim point far enough ahead so pitch stays sane
    local AIM_FRONT_MARGIN = 1.5
    local minAhead = -distance + AIM_FRONT_MARGIN
    if lookAhead < minAhead then lookAhead = minAhead end

    -- FRONT-CHASE: camera is in front of the car, looking FORWARD (same direction
    -- the car is traveling). The look target is far AHEAD of the camera so the
    -- camera faces forward, showing the road. This gives the front-positioned
    -- dynamics while still seeing where you're going.
    if frontChase then
        lookAhead = distance + 10.0  -- look well ahead of the car (forward)
    end

    -- G-force PITCH: raise/lower the aim target height based on accel/brake
    local pitchOffset = 0.0
    if Config.GForce and Config.GForce.Enabled and not STATE.motionLocked then
        pitchOffset = STATE.accelLong * (Config.GForce.PitchPerG or 0.01)
        local maxP = Config.GForce.MaxPitchOffset or 0.125
        pitchOffset = clamp(pitchOffset, -maxP, maxP)
    end

    -- Calculate look target position.
    -- ROOF ANCHORING (matches the camera-height shift above): raise the aim point
    -- by the same roof-delta so the viewing ANGLE is identical on a low coupe and
    -- a tall SUV. Without this the camera rides up over a tall roof but keeps
    -- aiming low → the "staring down at the roof" angle.
    local refRoofZ = (Config.Adaptive and Config.Adaptive.RefRoofZ) or 0.75
    local roofShift = math.max(0.0, (params.roofZ or refRoofZ) - refRoofZ)
    local lookH = (preset.lookHeight or 1.3) + roofShift
    -- FRONT-CHASE: look at the car body using the FrontChase.LookHeight setting
    if frontChase then
        lookH = (Config.FrontChase.LookHeight or 1.0) + roofShift
        -- SPEED SENSE: tilt aim down at speed (more road in lower frame)
        local pitchDownDeg = Config.FrontChase.PitchDownAtSpeed or 1.5
        local pitchDownKmh = Config.FrontChase.PitchDownFullKmh or 220.0
        local pdT = clamp(kmh / pitchDownKmh, 0.0, 1.0)
        pdT = pdT * pdT  -- ease-in
        -- Convert degrees to height offset at the look distance (~6m ahead)
        -- tan(1.5°) * 6m ≈ 0.16m drop in look target per degree
        lookH = lookH - (math.tan(math.rad(pitchDownDeg * pdT)) * 6.0)
    end
    local lookPos
    if frontChase then
        -- Look target AHEAD of car using flattened heading + world-up height.
        -- No entity-transform so slope doesn't swing the aim point.
        lookPos = vehPos + (swungForward * 6.0)
                  + vector3(0.0, 0.0, lookH + pitchOffset)
    else
        lookPos = vehPos + (flatForward * lookAhead)
                  + vector3(0.0, 0.0, lookH + pitchOffset)
    end

    -- Direction from camera to look target
    local dir = lookPos - STATE.curPos
    local distXY = math.sqrt(dir.x * dir.x + dir.y * dir.y)

    -- Calculate pitch and yaw (GTA convention: X=pitch, Y=roll, Z=yaw)
    -- GTA heading: 0° = north (+Y), increases COUNTER-CLOCKWISE (90° = west = -X).
    -- So yaw uses -dir.x (NOT +dir.x — that flips the turn direction and the
    -- camera swings to look backward).
    local targetPitch = math.deg(math.atan(dir.z, distXY))
    -- Trim the resting (flat-ground) tilt. <1.0 = slightly less downward tilt so the
    -- camera looks a touch more level / shows more road ahead.
    targetPitch = targetPitch * (Config.Cornering and Config.Cornering.NormalPitchScale or 1.0)

    -- ===== VEHICLE PITCH FOLLOWING =====
    -- Blend the vehicle's actual nose angle (uphill/downhill/bumps) into the camera pitch
    -- for more terrain feedback. Smoothed to prevent jittery bumps from jarring the camera.
    if Config.Cornering and Config.Cornering.PitchFollow and Config.Cornering.PitchFollow.Enabled and not STATE.motionLocked then
        local vehRot = GetEntityRotation(veh, 2)  -- order 2 = XYZ Euler
        local vehPitch = vehRot.x  -- vehicle nose-up = positive pitch
        -- DEADZONE: ignore small nose movements (suspension jitter on flat roads) so
        -- the camera doesn't bob up/down on every tiny bump when cruising level. Only
        -- apply pitch-follow once the nose angle exceeds the deadzone threshold.
        local dz = Config.Cornering.PitchFollow.Deadzone or 0.0
        if math.abs(vehPitch) < dz then vehPitch = 0.0 end
        -- Clamp and smooth the vehicle pitch
        local maxP = Config.Cornering.PitchFollow.MaxDegrees or 20.0
        vehPitch = clamp(vehPitch, -maxP, maxP)
        local pitchAlpha = smoothAlpha(Config.Cornering.PitchFollow.Smoothing or 0.08, dt)
        local newSmoothed = lerp(STATE.smoothedVehiclePitch, vehPitch, pitchAlpha)
        -- SLEW-RATE LIMIT: cap how many degrees the smoothed pitch can move per second.
        -- A real hill builds gradually and still reaches full tilt over time; a curb
        -- or speed-bump spikes the nose angle near-instantly, and that sharp transient
        -- is what made the camera lurch up/down. Limiting the rate flattens the spike
        -- (the cam just can't follow a jolt that fast) while leaving genuine slopes
        -- unaffected. This is the real fix for the "shakey on bumps" problem — the
        -- deadzone + smoothing alone couldn't catch a sharp enough jolt.
        local maxRate = Config.Cornering.PitchFollow.MaxRateDegPerSec
        if maxRate and maxRate > 0.0 then
            local maxStep = maxRate * dt
            local delta = newSmoothed - STATE.smoothedVehiclePitch
            if delta > maxStep then delta = maxStep
            elseif delta < -maxStep then delta = -maxStep end
            STATE.smoothedVehiclePitch = STATE.smoothedVehiclePitch + delta
        else
            STATE.smoothedVehiclePitch = newSmoothed
        end
        -- Blend into target pitch. ASYMMETRIC: downhill (nose DOWN, negative) gets
        -- a stronger multiplier so the camera tilts down to reveal the descending
        -- road. UPHILL (nose UP, positive) gets a WEAKER multiplier so the camera
        -- doesn't tilt up with the nose and shove the car to the bottom of frame.
        -- SPEED SCALING: the pitch-follow effect ramps with speed for UPHILL (high-angle
        -- climbs at low speed don't block the view, so gate it), but DOWNHILL needs
        -- full correction even when slow (the road drops away regardless of speed).
        -- So we compute TWO separate speed scales: one for the nose-follow strength
        -- (applied to both directions), and one for clearance (uphill only).
        local pfSpeedScale = 1.0
        local pfFullKmh = Config.Cornering.PitchFollow.ClearanceFullSpeedKmh
        if pfFullKmh and pfFullKmh > 0.0 then
            pfSpeedScale = clamp(kmh / pfFullKmh, 0.0, 1.0)
        end
        local strength
        if STATE.smoothedVehiclePitch < 0.0 then
            strength = Config.Cornering.PitchFollow.StrengthDown or 0.65
        else
            strength = Config.Cornering.PitchFollow.StrengthUp
                or (Config.Cornering.PitchFollow.Strength or 0.22)
        end
        -- AIRBORNE: boost pitch following so the camera tracks the nose angle
        -- strongly in the air (makes flips/jumps feel visceral).
        if STATE.airborneFactor > 0.0 then
            local pitchMult = lerp(1.0, Config.Airborne.PitchFollowMultiplier or 1.8, STATE.airborneFactor)
            strength = strength * pitchMult
        end
        targetPitch = targetPitch + (STATE.smoothedVehiclePitch * strength * pfSpeedScale)

        -- SLOPE VIEW CLEARANCE: counteract the terrain tilt so the car body doesn't
        -- block the road ahead. Tilts the camera AGAINST the nose direction, scaled
        -- by slope steepness AND vehicle roof height (taller vehicles get more, since
        -- their body blocks more of the view).
        local pf = Config.Cornering.PitchFollow
        local slopeN = math.min(1.0, math.abs(STATE.smoothedVehiclePitch) / (pf.ClearanceFullDeg or 12.0))
        local refRoofZ = (Config.Adaptive and Config.Adaptive.RefRoofZ) or 0.75
        local tallExtra = math.max(0.0, (params.roofZ or refRoofZ) - refRoofZ) * (pf.ClearanceHeightGain or 6.0)
        -- Base clearance magnitude BEFORE speed scaling (speed applied per-direction below).
        local clearanceDeg = ((pf.ClearanceBaseDeg or 3.5) + tallExtra) * slopeN
        -- ASYMMETRIC SPEED GATING (the key downhill fix):
        --   DOWNHILL — the road drops away ahead. The look-at-car angle already points
        --     DOWN on a descent (car sits below cam), so the clearance must tilt the cam
        --     UP (+) to lift the view OFF the ground and onto the road ahead. Full
        --     strength regardless of speed (no gating) — you need it from the start.
        --   UPHILL — a high-angle climb doesn't block the view at low speed, so its
        --     clearance tilts DOWN (-) and still ramps in with speed (pfSpeedScale).
        if STATE.smoothedVehiclePitch < 0.0 then
            -- DOWNHILL: tilt UP, but HARD-CAPPED so it can never keep lifting toward the
            -- sky/ceiling on a steep crest (the user's "needs a cap or it just keeps
            -- tilting"). The clearance is clamped to DownhillMaxDeg before being applied.
            local downClear = clearanceDeg * (pf.DownhillClearanceScale or 1.0)
            local cap = pf.DownhillMaxDeg or 6.0
            downClear = math.min(downClear, cap)
            targetPitch = targetPitch + downClear
        else
            targetPitch = targetPitch - clearanceDeg * (pf.UphillClearanceScale or 1.0) * pfSpeedScale
        end
    end

    -- ===== STABILIZER: PITCH RATE LIMITER =====
    -- With the flattened position basis, the geometric slope error is gone.
    -- Only small residual pitch changes remain (from height damping lag and
    -- look-target geometry on undulating terrain). The rate limiter filters
    -- sharp bump spikes that pass through the height smoother.
    if Config.Stabilizer and Config.Stabilizer.Enabled then
        local maxRate = Config.Stabilizer.MaxPitchRate or 45.0
        if maxRate > 0 and STATE.stabPrevPitch then
            local deltaPitch = targetPitch - STATE.stabPrevPitch
            local maxDelta = maxRate * dt
            if math.abs(deltaPitch) > maxDelta then
                targetPitch = STATE.stabPrevPitch + clamp(deltaPitch, -maxDelta, maxDelta)
            end
        end
        STATE.stabPrevPitch = targetPitch
    end

    -- Launch control pitch overlay
    targetPitch = targetPitch + (STATE.dragPitchOffset or 0.0)
    -- Chase arrow-key tilt adjustment + saved preset tilt
    local chaseTiltAdj = (chaseAdj.tilt or 0.0) + ((savedChasePresets[vehicleKey(veh)] or {}).tilt or 0.0)
    targetPitch = targetPitch + chaseTiltAdj

    local targetYaw   = math.deg(math.atan(-dir.x, dir.y))

    -- DEBUG: print rotation values every 60 frames
    if Config.Debug and STATE.debugFrameCount and STATE.debugFrameCount % 60 == 0 then
        print(('[RACECAM] Pitch=%.2f° | Yaw=%.2f° | Roll=%.2f° | vehPitch=%.2f° | smoothPitch=%.2f°'):format(
            targetPitch, targetYaw, STATE.currentRoll or 0, GetEntityRotation(veh, 2).x, STATE.smoothedVehiclePitch or 0))
    end

    -- ===== CORNERING ROLL =====
    -- Tilt camera into corners based on steering angle + lateral G-force.
    -- Forza-style: middle ground between Motorsport (subtle) and Horizon (fun).
    -- CRASH GUARD: disable during crash/airborne/tumbling to prevent camera chaos.
    -- NOTE: removed IsVehicleOnAllWheels from this check — muscle cars lose wheel
    -- contact under torque/braking which caused roll to snap to 0 mid-drive (the
    -- sudden SetCamRot change is suspected of triggering the GTA heading-pivot bug).
    -- The airborne system already handles genuine air-time; upside-down is enough here.
    local vehStable = not IsEntityUpsidedown(veh) and STATE.airborneFactor < 0.5

    local targetRoll = 0.0
    if Config.Cornering and Config.Cornering.Enabled and Config.Cornering.Roll.Enabled and vehStable then
        local rollCfg = Config.Cornering.Roll
        local minSpeed = rollCfg.MinSpeedKmh or 15.0

        if kmh > minSpeed and not STATE.motionLocked then
            -- Steering angle contribution (anticipation)
            -- KEYBOARD FIX: clamp to ±35° before normalizing to prevent instant
            -- full-lock (keyboard A/D = 40° instantly) from causing roll singularities.
            local steeringAngle = GetVehicleSteeringAngle(veh)  -- degrees, +left / -right
            steeringAngle = clamp(steeringAngle, -35.0, 35.0)   -- cap before max lock
            local steerNorm = clamp(steeringAngle / 40.0, -1.0, 1.0)  -- normalize to ±1

            -- Lateral G-force contribution (realism)
            local gForceNorm = clamp(STATE.accelLat / 10.0, -1.0, 1.0)  -- ~10 m/s² = hard turn

            -- Weighted blend (steering 40%, G-force 60%)
            local steerWeight = rollCfg.SteeringWeight or 0.4
            local gWeight = rollCfg.GForceWeight or 0.6
            local rollInput = (steerNorm * steerWeight + gForceNorm * gWeight)

            -- Scale to max degrees and invert sign (roll INTO the turn, not away)
            targetRoll = -rollInput * (rollCfg.MaxDegrees or 1.25)
        end
    end

    -- Smooth roll with spring damping
    local rollAlpha = smoothAlpha(Config.Cornering and Config.Cornering.Roll.Smoothing or 0.15, dt)
    STATE.currentRoll = lerp(STATE.currentRoll, targetRoll + (STATE.motionLocked and 0.0 or (STATE.driftRollOffset or 0.0)), rollAlpha)

    -- ===== ROTATIONAL INERTIA =====
    -- Camera yaw offset from the car's heading so the car VISIBLY rotates in frame.
    -- TWO-STAGE smoothing:
    --   (1) a lagged tracker turns the car's heading change into a raw offset, which is
    --       Strength-scaled, velocity-scaled (low speed less / high speed more), capped.
    --   (2) the APPLIED offset eases toward that target with SEPARATE attack/release
    --       time constants — AttackTime (~0.6s) ramps the turn in so it never kicks in
    --       suddenly (keyboard steering is instant 100%), and ReleaseTime (~0.2-0.4s)
    --       curves it back to centre smoothly instead of snapping.
    -- Invert flips which way the car appears to rotate.
    -- TRANSITION GUARD: instant yaw for first few frames after engage/reverse exit.
    if STATE.yawTransitionFrames > 0 then
        STATE.currentYaw = targetYaw  -- instant tracking during transition
        STATE.laggedYaw = targetYaw   -- keep the lag tracker synced so no jump after
        STATE.prevTargetYaw = targetYaw
        STATE.appliedYawOffset = 0.0  -- reset the eased offset so no jump after transition
        STATE.yawTransitionFrames = STATE.yawTransitionFrames - 1
    elseif Config.Cornering and Config.Cornering.Enabled and Config.Cornering.RotationalInertia.Enabled then
        local ri = Config.Cornering.RotationalInertia
        STATE.prevTargetYaw = STATE.prevTargetYaw or targetYaw
        -- LEAP DELAY: record the current heading, then drive the inertia from the heading
        -- as it was LeapTime ms ago, so the effect kicks in a beat AFTER you start turning
        -- (the user's "wait ~0.1s for the effect to come in"). Ring buffer of {ms, yaw}.
        local leapMs = (ri.LeapTime or 0.0) * 1000.0
        local delayedTargetYaw = targetYaw
        if leapMs > 0.0 then
            local hist = STATE.yawHist
            hist[#hist + 1] = { ms = now, yaw = targetYaw }
            -- Find the most recent sample at least leapMs old; drop older ones.
            local cutoff = now - leapMs
            local idx = 1
            for i = 1, #hist do
                if hist[i].ms <= cutoff then idx = i else break end
            end
            delayedTargetYaw = hist[idx].yaw
            -- Trim everything before the one we used (keep the buffer small).
            if idx > 1 then
                local trimmed = {}
                for i = idx, #hist do trimmed[#trimmed + 1] = hist[i] end
                STATE.yawHist = trimmed
            end
        end
        -- Lagged tracker: build the raw offset from the (delayed) heading change.
        STATE.laggedYaw = lerpAngle(STATE.laggedYaw or delayedTargetYaw, delayedTargetYaw, smoothAlpha(ri.YawLag or 0.08, dt))
        STATE.prevTargetYaw = targetYaw
        local rawDelta = ((delayedTargetYaw - STATE.laggedYaw + 180) % 360) - 180
        -- VELOCITY PROGRESSION: low speed = less range, high speed = more, capped at 1.
        local velFull = ri.FullSpeedKmh or 120.0
        local velMin  = ri.MinScale or 0.0
        local velScale = velMin + (1.0 - velMin) * clamp(kmh / velFull, 0.0, 1.0)
        -- Target offset: strength + velocity scale, then HARD CAP.
        local targetOffset = rawDelta * (ri.Strength or 1.0) * velScale
        local cap = ri.MaxDeg or 8.0
        targetOffset = clamp(targetOffset, -cap, cap)
        -- STAGE 2 — ATTACK / RELEASE: ease the APPLIED offset toward the target with
        -- a slow attack (ramp the turn in over ~AttackTime, no sudden kick) and a
        -- separate release (curve back to centre over ~ReleaseTime, no snap). "Growing"
        -- = the offset magnitude is increasing (turning harder) -> attack; otherwise
        -- it's relaxing toward centre -> release.
        local prevApplied = STATE.appliedYawOffset or 0.0
        local growing = math.abs(targetOffset) > math.abs(prevApplied)
        local easeTau = growing and (ri.AttackTime or 0.6) or (ri.ReleaseTime or 0.3)
        -- PROGRESSIVE CENTER SHARPENING (release only): as the offset approaches centre,
        -- smoothly blend the release tau DOWN toward CenterSharpTime so the last bit of
        -- the return is much sharper — kills the loose float/bounce near the middle.
        -- A SMOOTH blend (not a hard threshold) is critical: a sudden tau switch creates
        -- a velocity discontinuity that itself reads as a bounce/hitch. nearness goes
        -- 0 (far) -> 1 (dead centre) across CenterSharpThreshold, eased for a gentle ramp.
        if not growing then
            local sharpThresh = ri.CenterSharpThreshold or 0.30
            local nearness = 1.0 - clamp(math.abs(prevApplied) / math.max(0.001, sharpThresh), 0.0, 1.0)
            nearness = nearness * nearness * (3.0 - 2.0 * nearness)  -- smoothstep
            easeTau = lerp(easeTau, ri.CenterSharpTime or 0.02, nearness)
        end
        STATE.appliedYawOffset = lerp(prevApplied, targetOffset, smoothAlpha(easeTau, dt))
        -- SNAP-TO-ZERO DEADBAND: once extremely close to centre, pin to exactly 0 so a
        -- tiny residual offset can't linger and shimmer (sub-visual flop).
        if not growing and math.abs(STATE.appliedYawOffset) < (ri.CenterDeadband or 0.02) then
            STATE.appliedYawOffset = 0.0
        end
        local offset = STATE.appliedYawOffset
        -- AIRBORNE: scale down (or zero) the yaw offset so the camera stays LOCKED
        -- behind the car in the air instead of lagging/leading as the car rotates —
        -- this is the core "no flip-flop mid-jump" fix.
        if STATE.airborneFactor > 0.0 then
            local inertiaScale = lerp(1.0, Config.Airborne.RotationalInertiaScale or 0.0, STATE.airborneFactor)
            offset = offset * inertiaScale
        end
        if ri.Invert then
            STATE.currentYaw = targetYaw + offset  -- LEAD (rotation flipped)
        else
            STATE.currentYaw = targetYaw - offset  -- LAG (trailing)
        end
        -- TURN FACTOR (0..1) for the cornering FOV dip below. Derived from the same
        -- attack/release-eased, velocity-scaled, capped applied offset, so the FOV
        -- narrowing inherits all of that smoothing for free and scales up progressively.
        STATE.turnFactor = math.min(1.0, math.abs(offset) / (ri.MaxDeg or 8.0))
    else
        STATE.currentYaw = targetYaw  -- instant follow (no lag)
        STATE.turnFactor = 0.0
    end

    -- BUG TEST COMPLETE: PointCamAtCoord didn't fix the pivot either — it's
    -- RenderScriptCams itself. Reverting to SetCamRot (needed for roll/tilt features).
    if STATE.camPointing then
        StopCamPointing(cam)
        STATE.camPointing = false
    end

    if muscleMode then
        -- MUSCLE CAR ROTATION: use the entity's actual rotation as the base, with heavy
        -- pitch dampening (muscle cars pitch aggressively under torque — 30% follow prevents
        -- camera chaos). Yaw is the entity's own heading (keeps SetCamRot perfectly synced
        -- with the entity → GTA's steering system sees no mismatch → no phantom pivot).
        -- PHYSICS LAYER INTEGRATION: use the rate-limited pitch from the physics management
        -- layer instead of raw entity pitch. This smooths the violent b1604 pitch snap into
        -- a cinematic arc the camera can follow without jitter.
        local entRot = GetEntityRotation(veh, 2)
        local musclePitchDamp = Config.MuscleCamera and Config.MuscleCamera.PitchDampen or 0.30
        local dt = GetFrameTime()
        local rawPitch = entRot.x
        local smoothedPitch = rawPitch
        if dt > 0 and Config.MusclePhysics and Config.MusclePhysics.PitchRateLimit then
            smoothedPitch = getMuscleSmoothedPitch(veh, dt)
        end
        local musclePitch = smoothedPitch * musclePitchDamp
        local muscleYaw = entRot.z  -- entity heading directly (0-360 → GTA handles it in order 2)
        -- Still apply roll from the cornering system (subtle lean)
        SetCamRot(cam, musclePitch, STATE.currentRoll, muscleYaw, 2)
        -- Keep STATE.currentYaw synced for other systems that read it
        STATE.currentYaw = muscleYaw

        -- DEBUG: print entity heading + angular velocity when handbrake pressed at speed
        if GetVehicleHandbrake(veh) and kmh > 15.0 then
            local angVel = GetEntityRotationVelocity(veh)
            local entHead = GetEntityHeading(veh)
            print(('[MUSCLE-DBG] head=%.1f yaw=%.1f angZ=%.2f spd=%.0f'):format(
                entHead, muscleYaw, angVel.z, kmh))
        end
    else
        SetCamRot(cam, targetPitch, STATE.currentRoll, STATE.currentYaw + (STATE.motionLocked and 0.0 or (STATE.driftYawOffset or 0.0)), 2)
    end

    -- FOV: PRIMARY sense of speed. Per-gear RPM target (widens with speed),
    -- minus the gear-shift dip. Hard-capped by Config.Limits.MaxFov.
    -- Launch control FOV overlay (added on top of whatever the normal FOV is)
    local lcFovOffset = (STATE.dragFovOffset or 0.0) + (STATE.driftFovOffset or 0.0) - (STATE.orbitFovDip or 0.0)
    local targetFov
    if STATE.motionLocked then
        targetFov = (STATE.lockedFov or STATE.curFov) + lcFovOffset
    elseif speedFovTarget then
        targetFov = speedFovTarget - gsFovDip + lcFovOffset
    else
        -- Fallback (SpeedFov disabled or non-table fov): raw-speed lerp / static.
        targetFov = (type(preset.fov) == 'table') and lerp(preset.fov.min, preset.fov.max, sf) or preset.fov
        targetFov = targetFov - gsFovDip
    end
    -- View-mode FOV offset: closer view modes narrow FOV to match tighter distance.
    if Config.ViewModeFollow and Config.ViewModeFollow.Enabled and Config.ViewModeFollow.ModeFovOffsets then
        local fovOffset = Config.ViewModeFollow.ModeFovOffsets[STATE.currentViewMode or 1] or 0.0
        targetFov = targetFov + fovOffset
    end

    -- ===== HIGH-SPEED ZOOM-IN =====
    -- Above ZoomInStartKmh, progressively NARROW the FOV (zoom in) for a
    -- tunnel-vision focus effect at extreme speed. Subtracts up to ZoomInMaxDeg
    -- degrees, reached at ZoomInFullKmh. Vehicles can hit 450+ km/h so the ramp
    -- is spread wide and the max reduction is kept modest.
    if Config.HighSpeedZoom and Config.HighSpeedZoom.Enabled then
        local startKmh = Config.HighSpeedZoom.StartKmh or 160.0
        if kmh > startKmh then
            local fullKmh = Config.HighSpeedZoom.FullKmh or 400.0
            local zoomFactor = clamp((kmh - startKmh) / math.max(1.0, fullKmh - startKmh), 0.0, 1.0)
            targetFov = targetFov - (Config.HighSpeedZoom.MaxDeg or 8.0) * zoomFactor
        end
    end

    -- ===== CORNERING FOV DIP =====
    -- Narrow the FOV slightly while turning (and return to the current state's FOV when
    -- straightening). Driven by STATE.turnFactor (0..1) — the same attack/release-eased,
    -- velocity-scaled turn magnitude used for the camera rotation — so it inherits all
    -- that smoothing and only kicks in once you're actually carrying speed into a turn.
    -- Squared for a progressive ramp (gentle at small steering, building into the corner).
    -- Capped at MaxFovDip so the narrowing never exceeds a subtle amount.
    if Config.Cornering and Config.Cornering.TurnFov and Config.Cornering.TurnFov.Enabled then
        local tf = STATE.turnFactor or 0.0
        local progressive = tf * tf  -- ease-in so it scales up progressively, not linearly
        local maxDip = Config.Cornering.TurnFov.MaxFovDip or 1.2
        targetFov = targetFov - (maxDip * progressive)
    end

    targetFov = math.min(targetFov, Config.Limits.MaxFov or 74.0)
    targetFov = math.max(targetFov, 20.0)  -- never zoom in past 20° (sanity floor)
    STATE.curFov = lerp(STATE.curFov, targetFov, fovAlpha)
    SetCamFov(cam, STATE.curFov)

    -- Road buzz: subtle vibration mimicking road surface texture.
    -- Starts very low at RoadBuzzStartKmh, ramps slowly to full at high speed.
    -- Uses GTA's built-in ShakeCam (micro-tremor only, no position/pitch change).
    local buzzStart = Config.RoadBuzz and Config.RoadBuzz.StartKmh or 20.0
    local buzzFullKmh = Config.RoadBuzz and Config.RoadBuzz.FullKmh or 260.0
    local buzzMax = Config.RoadBuzz and Config.RoadBuzz.MaxIntensity or 0.04
    local buzzEnabled = not Config.RoadBuzz or Config.RoadBuzz.Enabled ~= false
    if buzzEnabled and kmh > buzzStart then
        local buzzT = clamp((kmh - buzzStart) / (buzzFullKmh - buzzStart), 0.0, 1.0)
        -- Ease-in: barely there at low speed, builds gradually
        buzzT = buzzT * buzzT
        local intensity = buzzT * buzzMax
        if not STATE.shakeActive then
            ShakeCam(cam, 'ROAD_VIBRATION_SHAKE', intensity)
            STATE.shakeActive = true
        else
            SetCamShakeAmplitude(cam, intensity)
        end
    elseif STATE.shakeActive then
        StopCamShaking(cam, true)
        STATE.shakeActive = false
    end

    -- ===== CORNERING SHAKE =====
    -- Subtle shake when turning hard at high speed (Forza-style).
    -- Separate from speed-based shake — uses a different shake ID.
    if Config.Cornering and Config.Cornering.Enabled and Config.Cornering.Shake.Enabled then
        local shakeCfg = Config.Cornering.Shake
        local minSpeed = shakeCfg.MinSpeedKmh or 80.0
        local minSteer = shakeCfg.MinSteeringDeg or 15.0
        local steeringAngle = math.abs(GetVehicleSteeringAngle(veh))

        if kmh > minSpeed and steeringAngle > minSteer and not STATE.motionLocked then
            -- Intensity scales with both speed and steering angle
            local speedFactor = clamp((kmh - minSpeed) / 100.0, 0.0, 1.0)
            local steerFactor = clamp((steeringAngle - minSteer) / 25.0, 0.0, 1.0)
            local intensity = speedFactor * steerFactor * (shakeCfg.MaxIntensity or 0.30)

            if not STATE.corneringShakeActive then
                ShakeCam(cam, 'ROAD_VIBRATION_IN_CAR', intensity)
                STATE.corneringShakeActive = true
            else
                SetCamShakeAmplitude(cam, intensity)
            end
        elseif STATE.corneringShakeActive then
            StopCamShaking(cam, true)
            STATE.corneringShakeActive = false
        end
    end

    -- ===== MOTION BLUR (speed-scaled) =====
    applyMotionBlur(cam, kmh)
end

-----------------------------------------------------------------
-- PER-FRAME: "bone" preset (hood / bumper)
-- Attach to the first bone that exists on this (possibly custom)
-- vehicle, then force rotation each frame so pitch/roll follow cleanly
-- instead of lagging. Roll is optionally damped so kerbs don't nauseate.
-----------------------------------------------------------------
local function resolveBone(veh, bones)
    for _, name in ipairs(bones or {}) do
        local idx = GetEntityBoneIndexByName(veh, name)
        if idx and idx ~= -1 then return idx end
    end
    return 0  -- fall back to root
end

-- Per-player bonnet cam adjustment (resets on vehicle change / resource restart)
local bonnetAdj = {
    offsetX   = 0.0,   -- lateral nudge (CTRL+arrow, client-only, never saved)
    offsetY   = 0.0,   -- forward/backward nudge
    offsetZ   = 0.0,   -- height nudge
    tilt      = 0.0,   -- pitch nudge (degrees)
    active    = false,  -- true while adjusting (shows HUD hint)
    lastVeh   = 0,     -- entity handle for reset detection
}




-- Limits: prevent turning it into a noclip camera
local BONNET_ADJ_LIMITS = {
    minX   = -1.0,   -- max left from center (client-only)
    maxX   =  1.0,   -- max right from center (client-only)
    minY   = -2.0,   -- max backward from default
    maxY   =  3.0,   -- max forward from default
    minZ   = -0.8,   -- max lower from default
    maxZ   =  1.5,   -- max higher from default
    minTilt = -25.0,  -- max look-down from default
    maxTilt =  20.0,  -- max look-up from default
}

-- Step sizes per tick (held key repeats at ~60fps, so these are per-frame)
local BONNET_ADJ_STEP = {
    Y    = 0.006,   -- m per frame
    Z    = 0.0045,  -- m per frame
    tilt = 0.09,    -- degrees per frame
    X    = 0.005,   -- m per frame (lateral, CTRL+arrow)
}

-- Saved per-model bonnet presets (loaded from server on resource start)
local savedBonnetPresets = {}  -- [modelName] = { offsetY, offsetZ, tilt }

-- Apply bonnet adjustments to a preset's offset/rotOffset (returns modified vectors)
local function getAdjustedHoodOffset(preset)
    local off = preset.offset or vector3(0.0, 1.80, 0.65)
    local rot = preset.rotOffset or vector3(-8.0, 0.0, 0.0)

    -- Check if this vehicle has a saved preset
    local veh = getDrivenVehicle()
    local savedY, savedZ, savedTilt = 0.0, 0.0, 0.0
    if veh then
        local name = vehicleKey(veh)
        if name and savedBonnetPresets[name] then
            local sp = savedBonnetPresets[name]
            savedY = sp.offsetY or 0.0
            savedZ = sp.offsetZ or 0.0
            savedTilt = sp.tilt or 0.0
        end
    end

    local adjOff = vector3(
        off.x + bonnetAdj.offsetX,
        off.y + savedY + bonnetAdj.offsetY,
        off.z + savedZ + bonnetAdj.offsetZ
    )
    local adjRot = vector3(
        rot.x + savedTilt + bonnetAdj.tilt,
        rot.y,
        rot.z
    )
    return adjOff, adjRot
end


local function updateBone(cam, veh, preset, params)
    -- C-KEY REVERSE: when holding C in bonnet cam, switch to a chase-style
    -- reverse view (behind the car looking forward) at a static close distance.
    -- V-key only adjusts FOV in this mode (no distance change).
    local bonnetCKeyHeld = false
    if Config.Reverse and Config.Reverse.CKeyEnabled then
        local ids = Config.Reverse.LookBehindControls or { 79, 26 }
        for i = 1, #ids do
            if IsDisabledControlPressed(0, ids[i]) then
                bonnetCKeyHeld = true
                break
            end
        end
    end

    -- Hood FOV follows V-key view mode (near/medium/far)
    local bonnetViewMode = GetFollowVehicleCamViewMode()
    local bonnetFovTable = preset.fovByMode or { [0] = 68.0, [1] = 72.0, [2] = 78.0 }
    local bonnetFov = bonnetFovTable[bonnetViewMode] or preset.fov or 72.0

    if bonnetCKeyHeld then
        -- REVERSE VIEW: camera BEHIND the car (-Y), looking forward at the car.
        -- Static distance = Reverse.Distance - 2 (closer than chase near mode).
        local revDist = 2.0 * params.lengthFactor  -- bonnet cam reverse: static 2.0m
        local revHeight = (Config.Reverse.Height or 2.0) * params.heightFactor
        local revLookH = 1.5  -- raised ~12deg up from default 1.0

        -- Position behind the car
        local worldPos = GetOffsetFromEntityInWorldCoords(veh, 0.0, revDist, revHeight)
        SetCamCoord(cam, worldPos.x, worldPos.y, worldPos.z)

        -- Look at the car
        local lookPos = GetOffsetFromEntityInWorldCoords(veh, 0.0, 0.0, revLookH)
        if STATE.camPointing then
            StopCamPointing(cam)
            STATE.camPointing = false
        end
        PointCamAtCoord(cam, lookPos.x, lookPos.y, lookPos.z)
        STATE.camPointing = true

        -- V-key adjusts FOV only (reverse uses same fovByMode table)
        local revFovTable = preset.reverseFovByMode or { [0] = 62.0, [1] = 66.0, [2] = 72.0 }
        local revFov = revFovTable[bonnetViewMode] or 66.0
        SetCamFov(cam, revFov)
        return
    end

    -- === NORMAL BONNET CAM (forward-facing, bone-locked) ===

    -- Use GetOffsetFromEntityInWorldCoords for reliable positioning.
    -- Bone attachment has unpredictable local axes on custom vehicles
    -- which causes the "zooms inward" bug. Manual positioning from the
    -- vehicle's own matrix is always correct.
    local off, rot = getAdjustedHoodOffset(preset)

    -- Scale forward/up by vehicle size
    local scaledX = off.x
    local scaledY = off.y * params.lengthFactor
    local scaledZ = off.z * params.heightFactor

    -- GetOffsetFromEntityInWorldCoords uses the vehicle's orientation matrix:
    -- X = right, Y = forward, Z = up (relative to the vehicle)
    local worldPos = GetOffsetFromEntityInWorldCoords(veh, scaledX, scaledY, scaledZ)
    SetCamCoord(cam, worldPos.x, worldPos.y, worldPos.z)

    -- Force rotation follow
    local vRot = GetEntityRotation(veh, 2)
    local rollDamp = preset.followRoll and (preset.rollDamp or 1.0) or 0.0
    -- Cancel any leftover PointCamAtCoord (reverse cam) so SetCamRot takes effect
    if STATE.camPointing then
        StopCamPointing(cam)
        STATE.camPointing = false
    end
    SetCamRot(cam,
        vRot.x + rot.x,
        (vRot.y * rollDamp) + rot.y,
        vRot.z + rot.z,
        2)

    -- Gear shift FOV kick (detect gear changes + half-sine pulse)
    if Config.GearShift and Config.GearShift.Enabled then
        local gear
        local entState = Entity(veh).state
        local syncGear = entState and entState.sync_gear
        if syncGear and syncGear > 0 then
            gear = syncGear
        else
            gear = GetVehicleCurrentGear(veh)
        end
        local kmh = GetEntitySpeed(veh) * 3.6
        if gear ~= STATE.prevGear and STATE.prevGear >= 0 and kmh > (Config.GearShift.MinSpeedKmh or 8.0) then
            STATE.shiftAtMs = GetGameTimer()
        end
        STATE.prevGear = gear

        local elapsed = GetGameTimer() - STATE.shiftAtMs
        local dur = 150  -- bonnet cam: short + smooth
        if elapsed < dur then
            local t = elapsed / dur
            local pulse = math.sin(t * math.pi)
            bonnetFov = bonnetFov - (Config.GearShift.FovDip or 0.075) * 0.159 * pulse * bonnetFov
        end
    end

    SetCamFov(cam, bonnetFov)

    -- Hood is bone-locked; clear any pending chase-cam transition state so
    -- switching back to chase later starts clean.
    STATE.wasReversing = false

    -- Detach if previously attached (switching from old bone logic)
    if STATE.attachedBone ~= nil then
        DetachCam(cam)
        STATE.attachedBone = nil
    end
end

-----------------------------------------------------------------
-- MAIN THREAD
-- Runs only the cheap checks when disarmed/not in a vehicle; spins up
-- to Wait(0) only while actually driving an armed vehicle.
-----------------------------------------------------------------
CreateThread(function()
    STATE.lastLookMs = GetGameTimer()

    while true do
        local sleep = 250

        if STATE.armed then
            local veh = getDrivenVehicle()

            if veh then
                sleep = 0

                -- TELEPORT/NOCLIP DETECTION: if vehicle jumped >20m in one frame,
                -- hard-reset all smoothing state and re-seed camera position.
                -- Stay engaged (no disengage/re-engage cycle = no V-key flicker).
                local vehPos = GetEntityCoords(veh)
                if STATE.lastVehPos then
                    local dx = vehPos.x - STATE.lastVehPos.x
                    local dy = vehPos.y - STATE.lastVehPos.y
                    local dz = vehPos.z - STATE.lastVehPos.z
                    local jumpDist = dx*dx + dy*dy + dz*dz
                    if jumpDist > 400.0 then  -- 20m squared
                        -- Teleported — full teardown and re-engage for a clean slate.
                        -- This ensures the scripted cam object is valid and all smoothing
                        -- restarts from scratch at the new position.
                        if STATE.engaged then
                            disengage()
                        end
                        -- Reset ALL smoothing state
                        STATE.stabSmoothedZ = nil
                        STATE.stabPrevPitch = nil
                        STATE.curPos = vehPos
                        STATE.fcDist = nil
                        STATE.smPos = nil
                        STATE.smFov = nil
                        STATE.prevVel = nil
                        STATE.accelLong = 0.0
                        STATE.accelLat = 0.0
                        STATE.currentRoll = 0.0
                        STATE.currentYaw = math.deg(math.atan(0.0, 1.0))
                        STATE.rearSwingDeg = 0.0
                        STATE.yawHist = {}
                        STATE.appliedYawOffset = 0.0
                        STATE.vehParamsFor = 0
                        invalidateResolved()
                        -- Seed fcModeScale to the CURRENT V-key target (no snap)
                        local curMode = GetFollowVehicleCamViewMode()
                        if curMode == 4 then
                            SetFollowVehicleCamViewMode(STATE.lastThirdPersonMode or 1)
                            curMode = STATE.lastThirdPersonMode or 1
                        end
                        local fc = Config.FrontChase
                        local scales = fc and fc.ViewModeScales or { [0] = 0.88, [1] = 1.0, [2] = 1.14 }
                        STATE.fcModeScale = scales[curMode] or 1.0
                        -- Re-engage immediately with fresh cam
                        engage(veh)
                        STATE.disengageAtMs = 0
                        STATE.lookStartMs = 0
                    end
                end
                STATE.lastVehPos = vehPos

                local params = getVehParams(veh)
                local preset = getResolvedPreset(veh)  -- [CHECKPOINT: resolve per-vehicle preset]
                local now = GetGameTimer()

                -- Detect look intent every frame.
                local looking = isPlayerLooking()
                if looking then STATE.lastLookMs = now end
                local idleMs = now - STATE.lastLookMs

                local fastEnough = (Config.MinEngageSpeedKmh <= 0.0)
                    or (speedKmh(veh) >= Config.MinEngageSpeedKmh)

                -- Track V-key view mode every frame (even when not engaged, for
                -- the first-person blocking). Mode 4 = first-person.
                local currentViewMode = 1
                if Config.ViewModeFollow and Config.ViewModeFollow.Enabled then
                    currentViewMode = GetFollowVehicleCamViewMode()
                end

                -- ===== MUSCLE CAR DETECTION =====
                local isMuscle = isMuscleHandling(veh)

                -- ===== MUSCLE CAR HYBRID MODE (legacy fallback, disabled by default) =====
                -- For muscle cars (VC_MUSCLE / b1604 wheelie hardcode), NEVER use
                -- RenderScriptCams. Instead enhance the NATIVE gameplay camera directly.
                -- This keeps the native camera pipeline active (which handles muscle car
                -- physics correctly) while still providing FOV control for a cinematic feel.
                -- The scripted cam is never engaged for these vehicles.
                -- NOTE: Disabled by default. The 180-snap is a GTA engine bug (happens even
                -- on default cam). Our entity-transform camera + pitch rate limiter handles
                -- muscle cars smoothly without needing native-cam fallback.
                local muscleHybrid = isMuscle
                    and Config.MuscleCamera
                    and Config.MuscleCamera.UseHybridMode

                if muscleHybrid then
                    sleep = 0
                    -- If the scripted cam was engaged (switched vehicles?), disengage it
                    if STATE.engaged then disengage() end
                    -- Enhance the native follow-cam: force view mode + apply FOV
                    local mc = Config.MuscleCamera
                    if mc.HybridViewMode then
                        SetFollowVehicleCamViewMode(mc.HybridViewMode)
                    end
                    -- FOV control on the native cam (works without RenderScriptCams)
                    SetFollowVehicleCamZoomLevel(mc.HybridViewMode or 1)
                    -- Keep gameplay cam heading synced (native is handling it, just ensure it's 0)
                    SetGameplayCamRelativeHeading(0.0)
                    -- Motion blur still applies (screen-global timecycle/animpostfx
                    -- layers work without a scripted cam). CamBlur layer is off by
                    -- default, so the cam arg is unused here.
                    applyMotionBlur(STATE.cam, speedKmh(veh))

                elseif STATE.engaged then
                    -- SUPPRESS first-person: while racecam is engaged, V-key can't
                    -- enter first-person. Force it back to the last third-person mode.
                    if currentViewMode == 4 then
                        -- V-key hit first-person: wrap to near (mode 0) to complete cycle
                        SetFollowVehicleCamViewMode(0)
                        currentViewMode = 0
                    end
                    -- Track the last valid third-person mode for restore on disengage
                    if currentViewMode ~= 4 then
                        STATE.lastThirdPersonMode = currentViewMode
                    end
                    if false then  -- (placeholder to keep else structure)
                        -- noop
                    else
                        -- DISENGAGE DEBOUNCE: 350ms sustained look to exit.
                        -- Runs BEFORE the camera update so disengage can cut mid-frame.
                        local recentlyLooking = looking or (STATE.lookStartMs > 0 and idleMs < 150)
                        if recentlyLooking then
                            local cHeld = false
                            if Config.Reverse.CKeyEnabled then
                                local ids = Config.Reverse.LookBehindControls or { 79, 26 }
                                for i = 1, #ids do
                                    if IsDisabledControlPressed(0, ids[i]) then
                                        cHeld = true
                                        break
                                    end
                                end
                            end
                            if not cHeld then
                                if STATE.lookStartMs == 0 then
                                    STATE.lookStartMs = now
                                end
                                if (now - STATE.lookStartMs) >= 140 then
                                    STATE.lookStartMs = 0
                                    STATE.disengageAtMs = now
                                    disengage()
                                end
                            else
                                STATE.lookStartMs = 0
                            end
                        else
                            STATE.lookStartMs = 0
                        end

                        -- CAMERA UPDATE: always render while still engaged (keeps cam
                        -- following the car during the 350ms debounce window).
                        if STATE.engaged then
                            STATE.currentViewMode = currentViewMode
                            if Config.Engagement.DisableLookWhileActive then
                                DisableControlAction(0, 1, true)
                                DisableControlAction(0, 2, true)
                            end
                            local entRotZ = GetEntityRotation(veh, 2).z
                            local cam = STATE.cam
                            if cam and DoesCamExist(cam) then
                                if preset.type == 'bone' then
                                    SetGameplayCamRelativeHeading(0.0)
                                    updateBone(cam, veh, preset, params)
                                else
                                    local relH = STATE.currentYaw - entRotZ
                                    relH = ((relH + 180.0) % 360.0) - 180.0
                                    SetGameplayCamRelativeHeading(relH)
                                    updateFree(cam, veh, preset, params)
                                end
                                DisableControlAction(0, 106, true)
                            end
                        end
                    end
                else
                    -- Not engaged: ease in once idle long enough, moving, AND not
                    -- currently in first-person (blocks the re-engage flicker loop).
                    -- MUSCLE HYBRID: never engage scripted cam on muscle cars in hybrid mode.
                    local notInFirstPerson = not (Config.ViewModeFollow and Config.ViewModeFollow.DisengageOnFirstPerson and currentViewMode == 4)
                    -- Re-engage: either F7 flagged immediate engage, or mouse idle threshold met.
                    local cooldownOk = (now - STATE.disengageAtMs) >= 650
                    local f7Request = STATE.engageNextFrame == true
                    if f7Request or (not muscleHybrid and (not looking) and idleMs >= Config.Engagement.IdleThresholdMs and fastEnough and notInFirstPerson and cooldownOk) then
                        STATE.engageNextFrame = false
                        engage(veh)
                    end
                end
            else
                -- Left the vehicle / became passenger -> drop the cam.
                if STATE.engaged or (STATE.cam and DoesCamExist(STATE.cam)) then
                    teardownCam()
                end
                STATE.vehParams = nil
                STATE.vehParamsFor = 0
            end
        else
            if STATE.cam and DoesCamExist(STATE.cam) then teardownCam() end
        end

        Wait(sleep)
    end
end)

-----------------------------------------------------------------
-- DEBUG HUD
-----------------------------------------------------------------
if Config.Debug then
    CreateThread(function()
        while true do
            Wait(0)
            if STATE.armed then
                local idle = GetGameTimer() - STATE.lastLookMs
                local line = ('hk-racecam | armed=%s engaged=%s preset=%s idle=%dms'):format(
                    tostring(STATE.armed), tostring(STATE.engaged), STATE.preset, idle)
                SetTextFont(0); SetTextScale(0.34, 0.34); SetTextColour(255, 255, 255, 220)
                SetTextOutline(); SetTextEntry('STRING')
                AddTextComponentSubstringPlayerName(line)
                DrawText(0.015, 0.85)
            end
        end
    end)
end

-----------------------------------------------------------------
-- STATE TRANSITIONS (cycle through off/presets)
-----------------------------------------------------------------
local function cycleMode()
    -- Cycle: off -> chase -> hood -> off
    -- "off" means STATE.armed = false
    if not STATE.armed then
        -- Currently off, turn on with first preset
        STATE.armed = true
        STATE.preset = Config.PresetOrder[1]
        STATE.lastLookMs = GetGameTimer()
        -- Flag for the main loop to engage on next frame (same path as mouse re-engage)
        STATE.engageNextFrame = true
        if Config.Notify.OnArm then
            notify(('~g~Race cam:~s~ %s'):format(STATE.preset))
        end
        dbg('cycle -> armed: ' .. STATE.preset)
        return
    end

    -- Currently on, find next preset or turn off
    local order = Config.PresetOrder
    local idx = 1
    for i, name in ipairs(order) do
        if name == STATE.preset then idx = i break end
    end

    if idx >= #order then
        -- Last preset, cycle back to off
        STATE.armed = false
        teardownCam()
        if Config.Notify.OnArm then
            notify('~r~Race cam off')
        end
        dbg('cycle -> off')
    else
        -- Next preset
        STATE.preset = order[idx + 1]
        STATE.vehParamsFor = 0
        STATE.attachedBone = nil
        invalidateResolved()
        if STATE.engaged then
            local preset = Config.Presets[STATE.preset]
            if preset then
                STATE.curFov = (type(preset.fov) == 'table') and preset.fov.min or preset.fov
            end
        else
            STATE.engageNextFrame = true
        end
        if Config.Notify.OnPreset then
            notify(('~y~Race cam:~s~ %s'):format(STATE.preset))
        end
        dbg('cycle -> ' .. STATE.preset)
    end
end

local function toggleLock()
    if not STATE.armed then return end
    STATE.motionLocked = not STATE.motionLocked
    -- Clear the snapshot so it re-captures fresh values next time it locks.
    STATE.lockedDist   = nil
    STATE.lockedHeight = nil
    STATE.lockedFov    = nil
    notify(STATE.motionLocked and '~b~Race cam: motion LOCKED' or '~g~Race cam: motion unlocked')
    dbg('motionLocked -> ' .. tostring(STATE.motionLocked))
end

-----------------------------------------------------------------
-- INPUT
-- RegisterKeyMapping binds the keys (rebindable in Settings > Key
-- Bindings > FiveM). The matching RegisterCommands also let you bind
-- them yourself or trigger from console.
-----------------------------------------------------------------
RegisterCommand('racecam_cycle',  function() cycleMode() end, false)
RegisterCommand('racecam_lock',   function() toggleLock() end, false)

if Config.Controls.UseKeyMapping then
    RegisterKeyMapping('racecam_cycle',  'Race Cam: cycle mode (off/chase/bonnet)', 'keyboard', Config.Controls.CycleKey or 'F7')
    RegisterKeyMapping('racecam_lock',   'Race Cam: lock/unlock motion', 'keyboard', Config.Controls.LockKey or 'F4')
end

-- Chat command: /racecam (no args = cycle), /racecam <preset> (jump to preset), /racecam off
RegisterCommand('racecam', function(_, args)
    local p = args[1]
    if not p then
        -- No args: cycle mode
        cycleMode()
    elseif p == 'off' then
        STATE.armed = false
        teardownCam()
        if Config.Notify.OnArm then
            notify('~r~Race cam off')
        end
    elseif Config.Presets[p] then
        -- Jump to specific preset
        STATE.preset = p
        STATE.vehParamsFor = 0
        STATE.attachedBone = nil
        invalidateResolved()
        if not STATE.armed then
            STATE.armed = true
            STATE.lastLookMs = GetGameTimer()
        end
        if Config.Notify.OnPreset then
            notify(('~y~Race cam:~s~ %s'):format(p))
        end
    else
        notify('~r~Usage:~s~ /racecam [chase|bonnet|off]')
    end
end, false)

-----------------------------------------------------------------
-- EXPORTS (for radial menus / other resources)
-----------------------------------------------------------------
exports('SetArmed',    function(on) setArmed(on and true or false) end)
exports('ToggleArmed', toggleArmed)
exports('SetPreset',   function(p) if Config.Presets[p] then STATE.preset = p; STATE.vehParamsFor = 0; invalidateResolved() end end)
exports('IsArmed',     function() return STATE.armed end)
exports('IsEngaged',   function() return STATE.engaged end)
exports('GetPreset',   function() return STATE.preset end)

-----------------------------------------------------------------
-- DEBUG MENU (admin only)
-----------------------------------------------------------------

-----------------------------------------------------------------
-- DEBUG MENU (admin only)
-----------------------------------------------------------------
local debugMenuOpen = false

local function isAdmin()
    -- Client-side check: just QBCore (server will do full validation)
    local success, result = pcall(function()
        return exports['qb-core']:HasPermission('admin')
    end)
    return success and result
end

RegisterCommand('racecam_debug', function()
    -- Light client check, server enforces the real permission
    if isAdmin() then
        -- QBCore admin detected, open directly
        debugMenuOpen = not debugMenuOpen
        SetNuiFocus(debugMenuOpen, true)  -- focus ON, keyboard passthrough ON (mouse-only)

        if debugMenuOpen then
            local veh = getDrivenVehicle()
            local currentMode = STATE.currentViewMode or 1
            local resolvedChase = Config.Presets.chase
            if veh then
                resolvedChase = getResolvedPreset(veh)
                resolvedChase = applyViewModeOverrides(resolvedChase, currentMode)
            end
            SendNUIMessage({
                action = 'openMenu',
                presets = Config.Presets,
                currentViewMode = currentMode,
                resolvedChase = resolvedChase,  -- the merged values for the current V-mode
            })
        else
            SendNUIMessage({ action = 'closeMenu' })
        end
    else
        -- No QBCore, ask server to validate (CFX admin / Discord)
        TriggerServerEvent('hk-racecam:requestDebugAccess')
    end
end, false)

RegisterNetEvent('hk-racecam:openDebugMenu', function()
    debugMenuOpen = true
    SetNuiFocus(true, true)  -- focus ON, keyboard passthrough ON
    local veh = getDrivenVehicle()
    local currentMode = STATE.currentViewMode or 1
    local resolvedChase = Config.Presets.chase
    if veh then
        resolvedChase = getResolvedPreset(veh)
        resolvedChase = applyViewModeOverrides(resolvedChase, currentMode)
    end
    SendNUIMessage({
        action = 'openMenu',
        presets = Config.Presets,
        currentViewMode = currentMode,
        resolvedChase = resolvedChase,
    })
end)

RegisterNetEvent('hk-racecam:accessDenied', function()
    notify('~r~Access denied — admin only')
end)

-- NUI Callbacks
RegisterNUICallback('closeMenu', function(data, cb)
    debugMenuOpen = false
    SetNuiFocus(false, false)
    cb('ok')
end)

RegisterNUICallback('refreshCamera', function(data, cb)
    -- 1. Re-engage the camera to pick up new seed distance
    if STATE.engaged then
        local veh = getDrivenVehicle()
        if veh then
            disengage()
            Citizen.Wait(50)  -- brief pause so disengage completes
            engage(veh)
        end
    end
    -- 2. Invalidate caches so next frame uses fresh config
    STATE.vehParamsFor = 0
    STATE.attachedBone = nil
    invalidateResolved()

    notify('~b~Camera refreshed')
    cb('ok')
end)

RegisterNUICallback('applyChanges', function(data, cb)
    -- Apply changes to the per-V-mode override structure instead of directly
    -- to Config.Presets. The menu sends the current view mode; we write to
    -- Config.ViewModeOverrides[mode] or _base.
    local mode = data.currentViewMode or STATE.currentViewMode or 1

    if data.chase then
        -- Ensure the override blocks exist
        if not Config.ViewModeOverrides then Config.ViewModeOverrides = {} end
        if not Config.ViewModeOverrides._base then Config.ViewModeOverrides._base = {} end
        if not Config.ViewModeOverrides[mode] then Config.ViewModeOverrides[mode] = {} end

        local base = Config.ViewModeOverrides._base
        local modeBlock = Config.ViewModeOverrides[mode]

        -- Shared fields -> _base (affect all modes)
        base.smoothness = data.chase.smoothness
        base.fovSmoothness = data.chase.fovSmoothness
        if not base.fov then base.fov = {} end
        base.fov.min = data.chase.fovMin
        base.fov.max = data.chase.fovMax
        if data.chase.lookAheadBase ~= nil then
            base.lookAheadBase = data.chase.lookAheadBase
        end
        if data.chase.rampMaxSpeedKmh ~= nil then
            base.rampMaxSpeedKmh = data.chase.rampMaxSpeedKmh
        end

        -- Per-mode fields -> current mode's block
        modeBlock.baseDistance = data.chase.baseDistance
        modeBlock.maxBaseDistance = data.chase.maxBaseDistance
        modeBlock.minExtraDistance = data.chase.minExtraDistance
        modeBlock.maxExtraDistance = data.chase.maxExtraDistance
        if data.chase.distanceTrim ~= nil then
            modeBlock.distanceTrim = data.chase.distanceTrim
        end
        modeBlock.baseHeight = data.chase.baseHeight
        modeBlock.minHeight = data.chase.minHeight
        modeBlock.heightLift = data.chase.heightLift
    end

    if data.bonnet then
        Config.Presets.bonnet.offset = vector3(data.bonnet.offsetX, data.bonnet.offsetY, data.bonnet.offsetZ)
        Config.Presets.bonnet.rotOffset = vector3(data.bonnet.rotX, 0.0, 0.0)
        Config.Presets.bonnet.fov = data.bonnet.fov
        Config.Presets.bonnet.smoothness = data.bonnet.smoothness
    end

    -- Force re-seed on next frame
    STATE.vehParamsFor = 0
    STATE.attachedBone = nil
    invalidateResolved()

    notify('~g~Changes applied (live) — mode ' .. tostring(mode))
    cb('ok')
end)

RegisterNUICallback('broadcastChanges', function(data, cb)
    -- Send to server to broadcast to all players
    TriggerServerEvent('hk-racecam:broadcastConfig', data)
    notify('~b~Broadcasting to all players...')
    cb('ok')
end)

RegisterNUICallback('saveToConfig', function(data, cb)
    -- Trigger server-side config file write
    TriggerServerEvent('hk-racecam:saveConfig', data)
    notify('~g~Saved to config.lua')
    cb('ok')
end)

RegisterNUICallback('resetValues', function(data, cb)
    -- Reload config from server
    TriggerServerEvent('hk-racecam:requestConfig')
    notify('~y~Reset to saved values')
    cb('ok')
end)

RegisterNetEvent('hk-racecam:receiveConfig', function(presets)
    Config.Presets = presets
    STATE.vehParamsFor = 0
    STATE.attachedBone = nil
    invalidateResolved()

    if debugMenuOpen then
        SendNUIMessage({
            action = 'updateValues',
            presets = presets
        })
    end
end)

RegisterNetEvent('hk-racecam:updateConfig', function(presets)
    -- Broadcasted config update from admin
    Config.Presets = presets
    STATE.vehParamsFor = 0
    STATE.attachedBone = nil
    invalidateResolved()
    notify('~b~Camera config updated by admin')
end)

-----------------------------------------------------------------
-- BONNET CAM ARROW-KEY ADJUSTMENT
-- Lets any player fine-tune bonnet cam position with arrow keys.
-- Up/Down = height (Z), Left/Right = forward/back (Y),
-- PageUp/PageDown = tilt (rotOffset.x pitch).
-- /savehood (admin) persists the current offset for this vehicle model.
-----------------------------------------------------------------

-- Hood adjustment key state (set by +/- commands, read per-frame)
local bonnetKeys = {
    up = false, down = false, fwd = false, back = false,
    tiltUp = false, tiltDown = false,
    lateralLeft = false, lateralRight = false,
}

-- RegisterKeyMapping +/- commands for hold detection (works in all contexts including vehicles)
RegisterCommand('+bonnet_up',       function() bonnetKeys.up = true end, false)
RegisterCommand('-bonnet_up',       function() bonnetKeys.up = false end, false)
RegisterCommand('+bonnet_down',     function() bonnetKeys.down = true end, false)
RegisterCommand('-bonnet_down',     function() bonnetKeys.down = false end, false)
RegisterCommand('+bonnet_fwd',      function() bonnetKeys.fwd = true end, false)
RegisterCommand('-bonnet_fwd',      function() bonnetKeys.fwd = false end, false)
RegisterCommand('+bonnet_back',     function() bonnetKeys.back = true end, false)
RegisterCommand('-bonnet_back',     function() bonnetKeys.back = false end, false)
RegisterCommand('+bonnet_tiltup',   function() bonnetKeys.tiltUp = true end, false)
RegisterCommand('-bonnet_tiltup',   function() bonnetKeys.tiltUp = false end, false)
RegisterCommand('+bonnet_tiltdown', function() bonnetKeys.tiltDown = true end, false)
RegisterCommand('-bonnet_tiltdown', function() bonnetKeys.tiltDown = false end, false)
-- CTRL+Left/Right lateral: detected per-frame via IsDisabledControlPressed (CTRL = control 36)
-- No RegisterKeyMapping needed — we check CTRL held + existing left/right keys in the thread.

RegisterKeyMapping('+bonnet_up',       'Bonnet Cam: raise',        'keyboard', 'UP')
RegisterKeyMapping('+bonnet_down',     'Bonnet Cam: lower',        'keyboard', 'DOWN')
RegisterKeyMapping('+bonnet_fwd',      'Bonnet Cam: forward',      'keyboard', 'RIGHT')
RegisterKeyMapping('+bonnet_back',     'Bonnet Cam: backward',     'keyboard', 'LEFT')


-- Arrow key input thread (applies adjustments when bonnet cam is engaged)
CreateThread(function()
    while true do
        -- Only process if armed + engaged + bonnet preset
        if STATE.armed and STATE.engaged and (STATE.preset == 'bonnet' or STATE.preset == 'chase') then
            local veh = getDrivenVehicle()

            -- Reset adjustments on vehicle change
            if veh and veh ~= bonnetAdj.lastVeh then
                bonnetAdj.offsetX = 0.0
                bonnetAdj.offsetY = 0.0
                bonnetAdj.offsetZ = 0.0
                bonnetAdj.tilt = 0.0
                bonnetAdj.lastVeh = veh
                chaseAdj.offsetY = 0.0
                chaseAdj.offsetZ = 0.0
                chaseAdj.tilt = 0.0
                chaseAdj.lastVeh = veh
            end

            local adjusting = false
            local ctrlHeld = IsDisabledControlPressed(0, 36)  -- LCTRL

            if STATE.preset == 'bonnet' then
                -- BONNET CAM adjustments
                if bonnetKeys.up and not ctrlHeld then
                    bonnetAdj.offsetZ = math.min(bonnetAdj.offsetZ + BONNET_ADJ_STEP.Z, BONNET_ADJ_LIMITS.maxZ)
                    adjusting = true
                end
                if bonnetKeys.down and not ctrlHeld then
                    bonnetAdj.offsetZ = math.max(bonnetAdj.offsetZ - BONNET_ADJ_STEP.Z, BONNET_ADJ_LIMITS.minZ)
                    adjusting = true
                end
                if bonnetKeys.fwd and not ctrlHeld then
                    bonnetAdj.offsetY = math.min(bonnetAdj.offsetY + BONNET_ADJ_STEP.Y, BONNET_ADJ_LIMITS.maxY)
                    adjusting = true
                end
                if bonnetKeys.back and not ctrlHeld then
                    bonnetAdj.offsetY = math.max(bonnetAdj.offsetY - BONNET_ADJ_STEP.Y, BONNET_ADJ_LIMITS.minY)
                    adjusting = true
                end
                -- CTRL+Up = tilt up, CTRL+Down = tilt down
                if ctrlHeld and bonnetKeys.up then
                    bonnetAdj.tilt = math.min(bonnetAdj.tilt + BONNET_ADJ_STEP.tilt, BONNET_ADJ_LIMITS.maxTilt)
                    adjusting = true
                end
                if ctrlHeld and bonnetKeys.down then
                    bonnetAdj.tilt = math.max(bonnetAdj.tilt - BONNET_ADJ_STEP.tilt, BONNET_ADJ_LIMITS.minTilt)
                    adjusting = true
                end
                -- CTRL+Left/Right = lateral (hood only, client-only)
                if ctrlHeld and bonnetKeys.back then
                    bonnetAdj.offsetX = math.max(bonnetAdj.offsetX - BONNET_ADJ_STEP.X, BONNET_ADJ_LIMITS.minX)
                    adjusting = true
                end
                if ctrlHeld and bonnetKeys.fwd then
                    bonnetAdj.offsetX = math.min(bonnetAdj.offsetX + BONNET_ADJ_STEP.X, BONNET_ADJ_LIMITS.maxX)
                    adjusting = true
                end
            else
                -- CHASE CAM adjustments (Up/Down=height, Left/Right=distance, CTRL+L/R=tilt)
                if bonnetKeys.up and not ctrlHeld then
                    chaseAdj.offsetZ = math.min(chaseAdj.offsetZ + BONNET_ADJ_STEP.Z, BONNET_ADJ_LIMITS.maxZ)
                    adjusting = true
                end
                if bonnetKeys.down and not ctrlHeld then
                    chaseAdj.offsetZ = math.max(chaseAdj.offsetZ - BONNET_ADJ_STEP.Z, BONNET_ADJ_LIMITS.minZ)
                    adjusting = true
                end
                if bonnetKeys.fwd and not ctrlHeld then
                    chaseAdj.offsetY = math.min(chaseAdj.offsetY + BONNET_ADJ_STEP.Y, BONNET_ADJ_LIMITS.maxY)
                    adjusting = true
                end
                if bonnetKeys.back and not ctrlHeld then
                    chaseAdj.offsetY = math.max(chaseAdj.offsetY - BONNET_ADJ_STEP.Y, BONNET_ADJ_LIMITS.minY)
                    adjusting = true
                end
                -- CTRL+Up/Down = tilt for chase
                if ctrlHeld and bonnetKeys.up then
                    chaseAdj.tilt = math.min(chaseAdj.tilt + BONNET_ADJ_STEP.tilt, BONNET_ADJ_LIMITS.maxTilt)
                    adjusting = true
                end
                if ctrlHeld and bonnetKeys.down then
                    chaseAdj.tilt = math.max(chaseAdj.tilt - BONNET_ADJ_STEP.tilt, BONNET_ADJ_LIMITS.minTilt)
                    adjusting = true
                end

            end

            bonnetAdj.active = adjusting

            -- HUD hint while adjusting
            if adjusting then
                SetTextFont(4)
                SetTextScale(0.28, 0.28)
                SetTextColour(200, 230, 255, 200)
                SetTextOutline()
                SetTextEntry('STRING')
                if STATE.preset == 'bonnet' then
                    local xStr = (math.abs(bonnetAdj.offsetX) > 0.001) and (' X%.2f'):format(bonnetAdj.offsetX) or ''
                    AddTextComponentString(('~w~Bonnet: Y%.2f Z%.2f T%.1f%s'):format(
                        bonnetAdj.offsetY, bonnetAdj.offsetZ, bonnetAdj.tilt, xStr))
                else
                    AddTextComponentString(('~w~Chase: D%.2f H%.2f T%.1f'):format(
                        chaseAdj.offsetY, chaseAdj.offsetZ, chaseAdj.tilt))
                end
                DrawText(0.015, 0.92)
            end

            Wait(0)
        else
            Wait(200)  -- sleep when not in bonnet cam
        end
    end
end)

-- /setbonnet command (admin only — saves current hood offsets for this vehicle model)
RegisterCommand('setbonnet', function(_, args)
    local veh = getDrivenVehicle()
    if not veh then notify('~r~Must be driving a vehicle'); return end
    local name = vehicleKey(veh)
    if not name then notify('~r~Cannot detect vehicle model'); return end

    local existingY = (savedBonnetPresets[name] and savedBonnetPresets[name].offsetY) or 0.0
    local existingZ = (savedBonnetPresets[name] and savedBonnetPresets[name].offsetZ) or 0.0
    local existingTilt = (savedBonnetPresets[name] and savedBonnetPresets[name].tilt) or 0.0

    local totalY = existingY + bonnetAdj.offsetY
    local totalZ = existingZ + bonnetAdj.offsetZ
    local totalTilt = existingTilt + bonnetAdj.tilt

    TriggerServerEvent('hk-racecam:saveBonnetPreset', name, totalY, totalZ, totalTilt)
    savedBonnetPresets[name] = { offsetY = totalY, offsetZ = totalZ, tilt = totalTilt }
    bonnetAdj.offsetY = 0.0
    bonnetAdj.offsetZ = 0.0
    bonnetAdj.tilt = 0.0
    notify(('~g~Bonnet preset saved for ~w~%s'):format(name))
end, false)

-- /setchase command (admin only — saves current chase offsets for this vehicle model)
RegisterCommand('setchase', function(_, args)
    local veh = getDrivenVehicle()
    if not veh then notify('~r~Must be driving a vehicle'); return end
    local name = vehicleKey(veh)
    if not name then notify('~r~Cannot detect vehicle model'); return end

    local existingY = (savedChasePresets[name] and savedChasePresets[name].offsetY) or 0.0
    local existingZ = (savedChasePresets[name] and savedChasePresets[name].offsetZ) or 0.0
    local existingTilt = (savedChasePresets[name] and savedChasePresets[name].tilt) or 0.0

    local totalY = existingY + chaseAdj.offsetY
    local totalZ = existingZ + chaseAdj.offsetZ
    local totalTilt = existingTilt + chaseAdj.tilt

    TriggerServerEvent('hk-racecam:saveChasePreset', name, totalY, totalZ, totalTilt)
    savedChasePresets[name] = { offsetY = totalY, offsetZ = totalZ, tilt = totalTilt }
    chaseAdj.offsetY = 0.0
    chaseAdj.offsetZ = 0.0
    chaseAdj.tilt = 0.0
    notify(('~g~Chase preset saved for ~w~%s'):format(name))
end, false)

-- /resetcam command (player usable — resets arrow key adjustments back to saved/default)
RegisterCommand('resetcam', function()
    bonnetAdj.offsetX = 0.0
    bonnetAdj.offsetY = 0.0
    bonnetAdj.offsetZ = 0.0
    bonnetAdj.tilt = 0.0
    chaseAdj.offsetY = 0.0
    chaseAdj.offsetZ = 0.0
    chaseAdj.tilt = 0.0
    notify('~y~Camera adjustments reset')
end, false)

-- Helper: count table entries (may not exist yet in this scope)
local function tableLen(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

-- Receive saved bonnet presets from server on resource start
RegisterNetEvent('hk-racecam:receiveBonnetPresets', function(presets)
    savedBonnetPresets = presets or {}
    dbg(('Loaded %d bonnet presets from server'):format(tableLen(presets or {})))
end)

RegisterNetEvent('hk-racecam:receiveChasePresets', function(presets)
    savedChasePresets = presets or {}
    local n = 0
    for _ in pairs(savedChasePresets) do n = n + 1 end
    dbg(('Loaded %d chase presets from server'):format(n))
end)


-- Request bonnet presets from server on start
CreateThread(function()
    Wait(2000)  -- let server load first
    TriggerServerEvent('hk-racecam:requestBonnetPresets')
    TriggerServerEvent('hk-racecam:requestChasePresets')
end)


-----------------------------------------------------------------
-- CLEANUP
-----------------------------------------------------------------
AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() then
        teardownCam()
    end
end)
