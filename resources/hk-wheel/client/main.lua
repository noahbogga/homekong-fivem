-- hk-wheel :: client/main.lua
-- The glue. Each frame while the player drives AND a wheel is live:
--   1. apply the steering override (steer.lua)
--   2. feed control 59 with the same value so hk-handling's sim + GTA visuals agree
--   3. translate clutch / H-shifter into the inputs hk-handling ALREADY listens for
--   4. compute an FFB frame from vehicle state and publish it to the app
--
-- hk-handling & hk-vehlib are consumed via exports only — never edited. If the
-- wheel isn't connected, this resource is inert and the game behaves exactly as
-- before (keyboard/pad drive everything).

local vehlib = exports['hk-vehlib']

Shifter = Shifter or {}     -- shifter state (reverseSelected) shared within this resource

-- Control IDs (mirror hk-vehlib/input.lua).
local C_STEER     = 59   -- INPUT_VEH_MOVE_LR
local C_THROTTLE  = 71   -- INPUT_VEH_ACCELERATE
local C_BRAKE     = 72   -- INPUT_VEH_BRAKE
local C_HANDBRAKE = 76   -- INPUT_VEH_HANDBRAKE

-- ── WheelBridge.exe button translation ───────────────────────────────────────────
-- The exe sends frame.btns = array of CURRENTLY-PRESSED button indices (no named actions). We
-- turn that into the frame fields the rest of this file already consumes: frame.shift ('up'/
-- 'down', EDGE), frame.reverse (HELD bool), frame.actions{} (EDGE map), frame.hold{} (HELD map).
-- Edge detection is OURS (the exe reports level state each frame): fire an edge action only on
-- the press transition. Held actions pass through live. Uses Config.ButtonMap + Config.HeldActions.
local _btnPrev = {}     -- [index] = true if it was pressed last frame (for edge detection)
local function translateButtons(frame)
    if type(frame.btns) ~= 'table' then return end   -- not the exe format; leave frame as-is
    local map = Config.ButtonMap or {}
    local held = Config.HeldActions or {}

    -- Build a "pressed now" set from the index array.
    local pressed = {}
    for _, idx in ipairs(frame.btns) do pressed[idx] = true end

    local actions, hold = {}, {}
    for idx, action in pairs(map) do
        local now = pressed[idx] == true
        local was = _btnPrev[idx] == true
        if held[action] then
            -- HELD: reflect live state every frame.
            if action == 'reverse' then frame.reverse = now or frame.reverse
            else hold[action] = now or nil end
        else
            -- EDGE: fire once on the press transition (not while held, not on release).
            if now and not was then
                if action == 'shiftUp' then frame.shift = 'up'
                elseif action == 'shiftDown' then frame.shift = 'down'
                else actions[action] = true end
            end
        end
        _btnPrev[idx] = now
    end
    -- default reverse to false if a reverse button is mapped but not pressed (so it releases)
    for idx, action in pairs(map) do
        if action == 'reverse' and not pressed[idx] and frame.reverse == nil then frame.reverse = false end
    end

    if next(actions) then frame.actions = actions end
    if next(hold)    then frame.hold    = hold    end
end

-- ── FFB computation ────────────────────────────────────────────────────────────
-- Build a small FFB frame from the live vehicle state. The app owns the actual
-- DirectInput effect synthesis + device master gain; we just send normalized cues.
local ffbNextAt = 0
local function publishFFB(veh, state)
    if not Config.FFB.Enabled then return end
    local now = GetGameTimer()
    local interval = 1000.0 / (Config.FFB.UpdateHz or 60)
    if now < ffbNextAt then return end
    ffbNextAt = now + interval

    local F = Config.FFB
    local kmh = state.speedKmh or 0.0
    local steer = Steer.currentSteer()      -- -1..1 (what we're steering this frame)

    -- SELF-ALIGNING TORQUE: the wheel wants to return to center proportional to
    -- steering amount × speed (like real caster/pneumatic trail). Signed so the app
    -- pushes AGAINST the current steer direction.
    local speedNorm = math.min(1.0, kmh / 120.0)
    local align = -steer * speedNorm * F.SelfAlignGain
    if align > 1.0 then align = 1.0 elseif align < -1.0 then align = -1.0 end

    -- SLIP / UNDERSTEER: when the fronts wash out the wheel goes light. Use the sim's
    -- own slip sensor (worstDiff m/s) to fade the align force — the classic light-wheel
    -- understeer cue. detectWheelspin returns (spinning, worstDiff).
    local _, worst = vehlib:detectWheelspin(veh, 2.0)
    local slip = 0.0
    if worst and worst > 0 then
        slip = math.min(1.0, worst / 12.0) * F.SlipDropGain
    end

    -- SURFACE rumble: scale with speed + a touch of suspension compression proxy.
    local surface = 0.0
    if state.onAllWheels and kmh > 3.0 then
        surface = math.min(1.0, kmh / 200.0) * F.SurfaceGain
    end

    -- PARK SPRING: strong centering when nearly stopped so it feels like a real
    -- resting wheel rather than dead.
    local spring = 0.0
    if kmh < (F.ParkSpringBelowKmh or 8.0) then
        local t = 1.0 - (kmh / (F.ParkSpringBelowKmh or 8.0))
        spring = t * F.ParkSpringGain
    end

    Wheel.sendFFB({
        align   = align,
        slip    = slip,
        surface = surface,
        spring  = spring,
    })
end

-- ── Pedals → GTA controls (analog throttle/brake, with REAL-CAR reverse) ─────────
-- Feed the app's pedal axes into GTA's own controls so BOTH the engine and
-- hk-handling's sim (state.throttle/brake) see them. Do NOT rely on GTA reading the
-- wheel's pedals directly — split-pedal HIDs often aren't seen. Only write a control
-- when the app actually reports that pedal (nil = device lacks it, leave to kb/pad).
--
-- REVERSE = REAL-CAR THROTTLE-TO-REVERSE. In GTA, when the box is in reverse gear the
-- pedal controls SWAP: control 71 (accel) brakes, control 72 (brake) drives BACKWARD.
-- That's why a gamepad "brakes to reverse". On a wheel with a shifter you select R and
-- press the THROTTLE to go back, like a real car. So while R is selected we SWAP the
-- routing: throttle pedal -> 72 (reverse-go), brake pedal -> 71 (stop). Feeding 72 from
-- the throttle ALSO trips hk-handling's reverse gate into 'reverse' naturally (it reads
-- state.brake), so the speedo shows R with no extra command. hk-handling stays untouched.
local function feedPedals(frame, reverseActive)
    if not Config.Pedals.Enabled then return end
    local dz = Config.Pedals.Deadzone or 0.0
    local thr = (frame.throttle ~= nil and frame.throttle >= dz) and frame.throttle or 0.0
    local brk = (frame.brake    ~= nil and frame.brake    >= dz) and frame.brake    or 0.0

    if reverseActive then
        -- SWAPPED: throttle drives backward (72), brake stops (71). Matches GTA's own
        -- in-reverse control overload, so the physics + engine behave like a real R gear.
        if Config.Pedals.Throttle and frame.throttle ~= nil then SetControlNormal(0, C_BRAKE, thr) end
        if Config.Pedals.Brake    and frame.brake    ~= nil then SetControlNormal(0, C_THROTTLE, brk) end
    else
        if Config.Pedals.Throttle and frame.throttle ~= nil then SetControlNormal(0, C_THROTTLE, thr) end
        if Config.Pedals.Brake    and frame.brake    ~= nil then SetControlNormal(0, C_BRAKE, brk) end
    end
end

-- ── Handbrake (analog % → boolean + optional progressive rear pressure) ──────────
-- hk-handling expects a BOOLEAN handbrake (control 76). We hold 76 past Threshold so
-- ALL the box logic that keys off it (launch staging, reverse-gate neutral) fires
-- exactly as with the keyboard. Optionally also apply progressive rear brake pressure
-- for a drift-able analog feel (GTA has no analog e-brake native, so this approximates).
local hbHeld = false
local function feedHandbrake(veh, frame)
    if not Config.Handbrake.Enabled or frame.handbrake == nil then return end
    local hb = frame.handbrake
    local on = hb >= Config.Handbrake.Threshold
    if on then
        -- Hold the control every frame it's pulled (control state is per-frame).
        SetControlNormal(0, C_HANDBRAKE, 1.0)
    end
    hbHeld = on
    -- Progressive rear-axle brake pressure for drift feel (scaled past the threshold).
    if Config.Handbrake.Analog and veh ~= 0 then
        local t = 0.0
        if on then
            local span = 1.0 - Config.Handbrake.Threshold
            t = span > 0 and ((hb - Config.Handbrake.Threshold) / span) or 1.0
            if t > 1.0 then t = 1.0 end
            t = t * (Config.Handbrake.AnalogMaxPress or 1.0)
        end
        -- Rear wheels only (indices vary by model; SetVehicleBrakePressure hits all —
        -- we keep it light + only while pulled so normal braking is untouched).
        if t > 0.0 then SetVehicleHandbrake(veh, true) end
    end
end

-- ── Held button actions (per-frame, not edges) ──────────────────────────────────
-- Some buttons are HELD, not tapped: horn, look-behind/left/right, NOS boost-fire. The app
-- reports their live state in frame.hold each frame; we assert the matching input while held.
-- Edge (one-shot) actions live in buttons.lua (Buttons.handleEdges).
local C_LOOK_BEHIND = 79
local C_HORN        = 86    -- INPUT_VEH_HORN
local nosBoosting = false
local function feedHeldActions(frame)
    local h = frame.hold
    if type(h) ~= 'table' then
        -- nothing held; make sure a latched NOS boost is released
        if nosBoosting then nosBoosting = false; ExecuteCommand('-nosBoost') end
        return
    end
    -- Look controls (native): assert the control each frame it's held so the camera holds.
    if h.lookBehind then SetControlNormal(0, C_LOOK_BEHIND, 1.0) end
    if h.horn       then SetControlNormal(0, C_HORN, 1.0) end
    -- Look left/right: GTA has no single 'look side' control in-vehicle; nudge the free-look
    -- axes (1/2 = LOOK_LR/UD) so a hat/POV switch pans the camera.
    if h.lookLeft   then SetControlNormal(0, 1, 0.0) end   -- pan left  (LOOK_LR toward 0)
    if h.lookRight  then SetControlNormal(0, 1, 1.0) end   -- pan right (LOOK_LR toward 1)
    -- NOS boost fire (jim '+nosBoost'/'-nosBoost'): edge it on hold state change.
    local wantBoost = h.nosBoost == true
    if wantBoost ~= nosBoosting then
        nosBoosting = wantBoost
        ExecuteCommand(wantBoost and '+nosBoost' or '-nosBoost')
    end
end

-- ── Shifter: PADDLE-ONLY (+/-) → hk-handling ─────────────────────────────────────
-- SCOPE (user, 2026-07-27): paddle shift ONLY. No H-pattern, no sequential lever. The box
-- shifts via +hk_upshift / +hk_downshift and clutches via +hk_clutch (verified names).
--   frame.shift    == 'up' | 'down'  (ONE-SHOT edge; app sends once per paddle pull)
--   frame.reverse  == true/false     (HELD state of the dedicated REVERSE button)
-- REVERSE is REAL-CAR: while frame.reverse is held, feedPedals SWAPS the pedals so THROTTLE
-- drives you backward (GTA's in-reverse control overload). Feeding throttle into control 72
-- also trips hk-handling's reverse gate into 'reverse' (speedo shows R). NEUTRAL is its own
-- standalone button (Buttons 'neutral' action), NOT part of the shifter.
local clutchDown = false

-- Public shifter state read by the loop + feedPedals.
Shifter.reverseSelected = false   -- true while the REVERSE button is held (pedals swap)

local function feedClutch(frame)
    if not Config.Shifter.ClutchEnabled or frame.clutch == nil then return end
    -- Clutch pedal: floored (>= EngagePoint) = disengaged = hk-handling clutch key DOWN.
    local down = frame.clutch >= Config.Shifter.EngagePoint
    if down ~= clutchDown then
        clutchDown = down
        ExecuteCommand(down and '+hk_clutch' or '-hk_clutch')
    end
end

local function feedShifter(frame)
    if not Config.Shifter.Enabled then return end
    -- Paddle edges (one-shot). App must not repeat while held.
    local ev = frame.shift
    if ev == 'up' then
        ExecuteCommand('+hk_upshift'); ExecuteCommand('-hk_upshift')
    elseif ev == 'down' then
        ExecuteCommand('+hk_downshift'); ExecuteCommand('-hk_downshift')
    end
    -- Reverse = held button; pedal swap happens in feedPedals via Shifter.reverseSelected.
    Shifter.reverseSelected = (frame.reverse == true)
end

-- ── Main per-frame loop ─────────────────────────────────────────────────────────
CreateThread(function()
    if Config.Debug then print('[hk-wheel] main loop running') end
    while true do
        local frame = Wheel.getFrame()          -- nil unless a live wheel is connected
        if frame then translateButtons(frame) end   -- exe btns[] -> shift/reverse/actions/hold
        local ped = PlayerPedId()
        local veh = (frame or Steer.currentSteer() ~= 0)
                    and IsPedInAnyVehicle(ped, false)
                    and GetVehiclePedIsIn(ped, false) or 0

        if veh ~= 0 and GetPedInVehicleSeat(veh, -1) == ped then
            local dt  = GetFrameTime()
            local kmh = GetEntitySpeed(veh) * 3.6

            -- 1+2. Steering — SINGLE WRITER: control 59 only (no SetVehicleSteeringAngle; the two
            -- fight and cause the right-bias/bounce). Steer.apply returns the shaped -1..1 (soft-lock
            -- + speed ratio) or nil when we don't own steering (no wheel). Control 59 is a 0..1
            -- normalized where 0.5 = center, so map -1..1 -> 0..1. hk-handling reads state.steer
            -- (this same control), so sim + visuals + GTA all agree with one writer.
            local st = Steer.apply(veh, frame, kmh, dt)
            if st ~= nil then
                SetControlNormal(0, C_STEER, (st + 1.0) * 0.5)
            end

            if frame then
                -- 3. Shifter FIRST — resolves Shifter.reverseSelected for this frame so the
                --    pedal routing below knows whether to swap for real-car throttle-to-reverse.
                feedClutch(frame)
                feedShifter(frame)
                -- 4. Pedals (analog throttle/brake). Swapped while R is selected: throttle -> 72
                --    drives backward (matches GTA's in-reverse control overload), brake -> 71 stops.
                feedPedals(frame, Shifter.reverseSelected)
                -- 5. Handbrake (% -> boolean control 76 + optional progressive rear pressure).
                feedHandbrake(veh, frame)
                -- 6. Button box: one-shot edge actions (engine/hybrid/seatbelt/nos/neutral/lights)
                --    + per-frame HELD actions (horn/look/nos-boost).
                Buttons.handleEdges(frame)
                feedHeldActions(frame)
            end

            -- 7. FFB out.
            local state = vehlib:getState(veh)
            if state then publishFFB(veh, state) end

            Wait(0)                              -- run every frame while active
        else
            Wait(50)                             -- idle: cheap poll until we're driving
        end
    end
end)

-- Debug HUD: /wheelstate prints the live bridge + frame status to F8.
RegisterCommand('wheelstate', function()
    local f = Wheel.frame
    print(('[hk-wheel] bridge=%s device=%s active=%s | steerIn=%s thr=%s brk=%s clutch=%s hb=%s | steerOut=%.3f')
        :format(tostring(Wheel.bridgeUp), tostring(Wheel.deviceUp), tostring(Wheel.isActive()),
                f and string.format('%.3f', f.steer or 0) or 'nil',
                f and string.format('%.2f', f.throttle or 0) or 'nil',
                f and string.format('%.2f', f.brake or 0) or 'nil',
                f and string.format('%.2f', f.clutch or 0) or 'nil',
                f and string.format('%.2f', f.handbrake or 0) or 'nil',
                Steer.currentSteer()))
    -- Raw pressed-button indices from the exe — press a button, run this, note the number,
    -- then put it in Config.ButtonMap.
    print(('[hk-wheel] rawBtns=%s')
        :format(f and f.btns and table.concat(f.btns, ',') or 'none'))
    print(('[hk-wheel] paddle: shift=%s reverse=%s (rev-selected=%s) | boxMode=%s')
        :format(f and tostring(f.shift) or 'nil', f and tostring(f.reverse) or 'nil',
                tostring(Shifter.reverseSelected),
                (function() local ok, m = pcall(function() return exports['hk-handling']:GetGearboxMode() end); return ok and tostring(m) or '?' end)()))
    if Wheel.device then
        print(('[hk-wheel] device: %s range=%s ffb=%s clutch=%s h=%s')
            :format(tostring(Wheel.device.name), tostring(Wheel.device.rangeDeg),
                    tostring(Wheel.device.hasFFB), tostring(Wheel.device.hasClutch),
                    tostring(Wheel.device.hasH)))
    end
end, false)
