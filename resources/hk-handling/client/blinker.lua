-- ============================================================================================
-- AUTO-BLINKER (2026-08-14) — Assetto-Corsa-style steering-driven turn signals + reverse lights.
--
-- Toggle with Left-Alt. While ARMED, indicators follow the STEERING angle each frame:
--   steer LEFT  past OnPct  -> left blinker  (SetVehicleIndicatorLights index 1)
--   steer RIGHT past OnPct  -> right blinker (index 0)
--   |steer| <= OffPct       -> HAZARDS (both on) — near-center "presence" signal
-- Works the SAME in forward and reverse gears. LAlt is the SINGLE arm control — reverse does NOT
-- auto-arm. When DISARMED we touch nothing (native reverse lights + the manual -/=/backspace blinker
-- (wesley_els LVC) keep working). Default OFF.
--
-- Sign convention: state.steer is -1 (full LEFT) .. +1 (full RIGHT) — the value our steering model
-- owns. The model is the SINGLE writer of control 59 (main.lua); vehlib sets state.steer =
-- GetControlNormal(0, 59), so reading state.steer reads the model directly.
--
-- SetVehicleIndicatorLights(veh, index, on): index 1 = LEFT, 0 = RIGHT (GTA convention). The game
-- blinks them for us once set; we just hold the desired side on and clear the other. Publishes
-- hk_blinker { armed } for the hk-speedo pill.
-- ============================================================================================

HK = HK or {}

-- ARM state — seeded from config, toggled by LAlt. HK-namespaced so the debug screen / speedo read it.
HK.blinkerArmed = (Config.AutoBlinker and Config.AutoBlinker.EnabledByDefault) == true
HK.blinker = HK.blinker or { armed = false, side = 'off' }  -- side: 'off'|'left'|'right'|'both'

local curSide      = 'off'      -- what we last WROTE to the vehicle (so we only re-set on change)
local pendingSide  = 'off'      -- candidate side awaiting debounce
local pendingSince = 0          -- gameTimer when pendingSide first proposed
local lastVeh      = 0

-- DRIFT-HAZARD cadence (see Config.DriftHazard). The indicator native is ON/OFF only (no dim), so we
-- run a plain FAST even-duty blink ( . . . . . . ) — OnMs on, OffMs off, repeating, no pause. Faster
-- than the native turn-signal so it reads as a distinct drift hazard. driftHazPhase accumulates ms.
local driftHazPhase = 0.0       -- ms into the current on+off cycle
local driftHazActive = false    -- were we running the drift pattern last frame (so we clear on exit)

-- Returns true if the fast blink wants the lights ON this frame, given ms-into-cycle (0..OnMs+OffMs).
local function driftHazOn(ms, cfg)
    return ms < (cfg.OnMs or 90.0)                 -- ON for the first OnMs of each cycle, else OFF
end

-- Decide the target side from the steering value. Returns 'left'|'right'|'both'.
local function sideFromSteer(steer, onPct)
    if steer <= -onPct then return 'left'  end   -- steer negative = LEFT
    if steer >=  onPct then return 'right' end   -- steer positive = RIGHT
    return 'both'                                 -- near center = hazards (presence)
end

-- Push the desired side onto the vehicle indicators. REASSERTS EVERY FRAME (not just on change):
-- another resource on this server (the escrowed -/=/backspace blinker) actively RE-CLEARS the
-- indicators every frame, so a one-shot SetVehicleIndicatorLights gets clobbered on the next tick
-- (toggle notifies fire but no light shows). Writing every frame makes us win that fight; GTA still
-- renders the blink on its own regardless of how often we set the flag. curSide is kept only so the
-- debounce / speedo pill can see the last committed side. 'off' clears both.
local function applySide(veh, side)
    curSide = side
    local left  = (side == 'left'  or side == 'both')
    local right = (side == 'right' or side == 'both')
    SetVehicleIndicatorLights(veh, 1, left)    -- index 1 = LEFT
    SetVehicleIndicatorLights(veh, 0, right)   -- index 0 = RIGHT
end

-- Main tick — called from the main loop with the driven vehicle + state snapshot.
function HK.Blinker_Tick(veh, state, dt)
    local cfg = Config.AutoBlinker or {}
    if not veh or veh == 0 then return end
    -- Auto-blinker OFF but drift-hazards ON: skip the steering logic, but still run the drift pattern.
    -- Both features write indicators through this one tick, so neither can be starved by the other's flag.
    local autoOff = (Config.AutoBlinker == nil or Config.AutoBlinker.Enabled == false)

    -- Vehicle changed: clear our latch so the new car starts clean.
    if veh ~= lastVeh then
        lastVeh = veh
        curSide, pendingSide, pendingSince = 'off', 'off', 0
    end

    local now = state.gameTimer or GetGameTimer()

    -- DRIFT HAZARDS (2026-09-06): while drift mode is held, flash BOTH indicators on a FAST even blink
    -- ( . . . . . . , see Config.DriftHazard). Drift ALWAYS WINS — even with the auto-blinker armed and
    -- the player steering, the hazard shows for the whole drift (the steering turn-signal is suppressed).
    -- This module is the single per-frame indicator writer so there's no fight. Native is on/off only,
    -- so there's no dim — just a quick steady strobe faster than the turn-signal rate.
    local dcfg = Config.DriftHazard
    local driftWants = dcfg and dcfg.Enabled ~= false and HK.driftMode == true
    if driftWants and (dcfg.MinSpeedKmh or 0.0) > 0.0 and (state.speedKmh or 0.0) < dcfg.MinSpeedKmh then
        driftWants = false
    end
    if driftWants then
        if not driftHazActive then driftHazPhase = 0.0; driftHazActive = true end   -- start the cycle clean
        driftHazPhase = driftHazPhase + dt * 1000.0                                  -- advance (dt = seconds)
        local cycleLen = (dcfg.OnMs or 90.0) + (dcfg.OffMs or 90.0)
        if driftHazPhase >= cycleLen then driftHazPhase = driftHazPhase % cycleLen end
        local lit = driftHazOn(driftHazPhase, dcfg)
        applySide(veh, lit and 'both' or 'off')
        HK.blinker.side = lit and 'both' or 'off'
        -- Reset the auto-blinker's debounce/latch so that when drift ENDS it starts clean (no stale side
        -- resumes mid-slide). The steering logic below is skipped this frame via the return.
        pendingSide, pendingSince = 'off', 0
        return
    end
    -- Drift ENDED (or below MinSpeedKmh): the auto-blinker does NOT resume a stale signal — clear the
    -- indicators to OFF once on the handoff frame so exit overlaps into darkness, then hand control to
    -- the steering logic below (which, being freshly reset, will re-derive from live steering next frame).
    if driftHazActive then
        driftHazActive = false
        driftHazPhase  = 0.0
        applySide(veh, 'off')                 -- overlap exit: turn the blinker OFF regardless of arm state
        HK.blinker.side = 'off'
        pendingSide, pendingSince = 'off', 0  -- reset debounce so the auto-blinker re-derives clean next frame
        return                                -- guarantee one clean OFF frame; steering resumes next tick
    end

    -- AUTO-BLINKER DISABLED in config: nothing more to do (drift hazards, if any, ran above). Clear once
    -- if we were the last writer, then bail — the steering-driven logic below is auto-blinker territory.
    if autoOff then
        if curSide ~= 'off' then applySide(veh, 'off') end
        return
    end

    -- ARMED is controlled ONLY by the LAlt toggle. When ON, the steering-driven blinker runs the same
    -- in BOTH forward and reverse gears (steer left/right past OnPct -> that side; near-center = both).
    -- When OFF, we do nothing at all — reverse then just shows the native reverse-lights, no turn
    -- signals. (Reverse no longer force-arms the blinker; the toggle is the single source of truth.)
    if HK.blinkerArmed ~= true then
        -- DISARMED: leave the indicators ENTIRELY alone so the manual -/=/backspace blinker
        -- (wesley_els LVC) still works. We must NOT write 'off' here or we'd stomp a manual signal
        -- every frame. Only clear ONCE, on the frame we transition armed->disarmed (curSide latch),
        -- so turning our auto-blinker off cancels any signal WE were holding but nothing else.
        if curSide ~= 'off' then applySide(veh, 'off') end
        HK.blinker.armed = false
        HK.blinker.side  = 'off'
        pendingSide, pendingSince = 'off', 0
        if HK.PublishBlinker then HK.PublishBlinker() end   -- keep the pill in sync when disarmed
        return
    end

    -- Steering value, -1 (full LEFT) .. +1 (full RIGHT). This IS our steering model's output: the model
    -- is the single writer of control 59 (main.lua), vehlib sets state.steer = GetControlNormal(0, 59),
    -- so reading state.steer reads the model (keyboard-synth or native pad/wheel — both populate 59).
    local steer = state.steer or 0.0
    if steer < -1.0 then steer = -1.0 elseif steer > 1.0 then steer = 1.0 end

    local target = sideFromSteer(steer, cfg.OnPct or 0.15)

    -- DEBOUNCE: a new target must persist DebounceMs before we commit it (kills threshold flicker).
    -- 'both' (center) commits instantly so releasing the wheel drops to hazards without a lag.
    local commit = curSide
    if target == curSide then
        pendingSide, pendingSince = target, now
    else
        if target ~= pendingSide then
            pendingSide  = target
            pendingSince = now
        end
        local deb = (target == 'both') and 0.0 or (cfg.DebounceMs or 180.0)
        if (now - pendingSince) >= deb then
            commit = target
        end
    end

    applySide(veh, commit)
    HK.blinker.armed = true
    HK.blinker.side  = commit
    if HK.PublishBlinker then HK.PublishBlinker() end   -- change-detected: only .set when side flips
end

-- Reset on vehicle exit / disable — clear indicators + latch.
function HK.Blinker_Reset(veh)
    if veh and veh ~= 0 and DoesEntityExist(veh) then
        SetVehicleIndicatorLights(veh, 0, false)
        SetVehicleIndicatorLights(veh, 1, false)
    end
    curSide, pendingSide, pendingSince, lastVeh = 'off', 'off', 0, 0
    driftHazActive, driftHazPhase = false, 0.0
    HK.blinker.side = 'off'
end

-- Publish blinker status to a REPLICATED player statebag for hk-speedo's pill (same pattern as
-- hk_abs_off / hk_tc_off). Change-detected so we only .set on an actual change (bag sets replicate).
-- Payload: { armed = bool }. The pill just pulses when armed; it no longer shows which side.
local lastBlinkerSig = nil
function HK.PublishBlinker()
    local armed = HK.blinkerArmed == true
    local sig = armed and '1' or '0'
    if sig == lastBlinkerSig then return end
    lastBlinkerSig = sig
    pcall(function()
        LocalPlayer.state:set('hk_blinker', { armed = armed }, true)
    end)
end

-- TOGGLE command + keybind (Left-Alt). Tap = arm/disarm. When disarming, indicators clear next tick.
-- NO chat notify (per user) — the speedo pill is the sole feedback.
RegisterCommand('hk_blinker_toggle', function()
    HK.blinkerArmed = not HK.blinkerArmed
    HK.blinker.armed = HK.blinkerArmed
    if not HK.blinkerArmed then HK.blinker.side = 'off' end
    HK.PublishBlinker()
end, false)

-- Default bind = LEFT ALT. RegisterKeyMapping lets the player rebind in Settings > Key Bindings.
RegisterKeyMapping('hk_blinker_toggle', 'Auto-blinker toggle', 'keyboard', 'LMENU')

-- Chat/console fallback so the feature is reachable even if the LAlt mapping didn't take (new-file
-- keybinds need a reconnect to register). Type /blinker in F8 or chat.
RegisterCommand('blinker', function()
    ExecuteCommand('hk_blinker_toggle')
end, false)
