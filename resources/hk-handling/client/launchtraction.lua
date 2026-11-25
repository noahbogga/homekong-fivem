-----------------------------------------------------------------
-- LAUNCH TRACTION (2026-08-16) — auto-wheelspin off the line.
--
-- Real-car launch: from a standstill in gear 1-2 the tyres can only accept so much torque. Stab more
-- than that (or jab the pedal violently) and the wheels BREAK LOOSE — the engine RAWRs, the car only
-- creeps, and you go nowhere fast. Feather the throttle, or TAP-TAP-TAP W, to stay under the grip limit
-- and the car hooks up and launches hard. No drift key involved — the car "springs out" itself from too
-- much / too rapid throttle. This is the traction/wheelspin model the AccelStretch stopgap was waiting on
-- (see gearbox.lua ~4636): it self-limits powerful cars by GRIP, so slow cars (which don't break loose)
-- stop being over-slowed by the global AccelStretch cut.
--
-- TWO triggers (user chose BOTH):
--   A) LEVEL  — grip budget rises with speed; throttle ABOVE it breaks traction ("hold full = spin").
--   B) RATE   — a violent throttle STAB momentarily lowers the budget ("jab it = spin harder").
-- Tapping wins because it keeps average throttle under the budget AND avoids one big stab.
--
-- Runs in main.lua's [B*] region: AFTER Gearbox_Tick (so gbInNeutral/gbClutchHeld/inReverseGear +
-- effThrottle are fresh) and BEFORE vl_setTorque (so the torque bog applies this frame). pcall-guarded.
-- Mutually exclusive with drift, Launch Control (HK.launch), free-rev and the manual burnout wheelspin.
-----------------------------------------------------------------

local vehlib = exports['hk-vehlib']
local function bind(fn) return function(...) return fn(nil, ...) end end
local vl_detectWheelspin = bind(vehlib.detectWheelspin)   -- (veh,thresh) -> spinning, worstSlip(m/s)
local vl_scaleHandling   = bind(vehlib.scaleHandling)     -- (veh, field, mult) — native * mult
local vl_restoreField    = bind(vehlib.restoreField)      -- (veh, field) — back to cached native

-- STATE
local prevThr    = 0.0     -- last frame's effThrottle (for the stab/rate term)
local stab       = 0.0     -- decaying throttle-stab penalty (0..StabMax)
local gripOwned  = false   -- did we drop the traction curves this launch? (restore-once latch)

local function releaseGrip(veh)
    -- Arbiter path: just drop our claim (the committer restores when nobody claims). gripOwned is only
    -- true if we wrote the fields DIRECTLY (arbiter off) — then we still own the direct restore.
    if HK.gripRelease then HK.gripRelease('launch') end
    if gripOwned and veh and veh ~= 0 and DoesEntityExist(veh) then
        vl_restoreField(veh, 'fTractionCurveMax')
        vl_restoreField(veh, 'fTractionCurveMin')
        vl_restoreField(veh, 'fLowSpeedTractionLossMult')
    end
    gripOwned = false
end

-- Reset on vehicle swap / disable so a new car starts clean.
function LaunchTraction_Reset()
    if HK and HK.vehicle and HK.vehicle ~= 0 and DoesEntityExist(HK.vehicle) then
        releaseGrip(HK.vehicle)
    end
    prevThr, stab, gripOwned = 0.0, 0.0, false
    if HK then HK.launchTractionActive = false end
end

function LaunchTraction_Tick(veh, state, dt)
    local cfg = Config.LaunchTraction
    HK.launchTractionActive = false
    -- REASON CODE (2026-08-16 diagnostic): every exit path stamps HK.dbgLaunchWhy with WHY it did/didn't
    -- fire the drag this frame, so "it just went" becomes a readable state on /handlingdbg instead of a
    -- guess. `why` is the current reason; `armed` = the player is doing a floor-it-from-low-speed launch
    -- (a drag SHOULD be happening) so we can spot "armed but not firing because X".
    HK.dbgLaunchWhy = HK.dbgLaunchWhy or {}
    local W = HK.dbgLaunchWhy
    local function why(reason) W.why = reason; W.at = GetGameTimer() end
    if not cfg or cfg.Enabled == false then
        if gripOwned then releaseGrip(veh) end
        why('cfg-disabled'); return
    end
    -- TRANSIENT-INVALIDITY GUARD: a player encounter (another vehicle streaming in, a collision, being
    -- pulled from the seat) can leave veh/state momentarily invalid for a frame. Without this the first
    -- native call throws, main.lua latches HK._launchTrErr = true, and the feature stays DEAD for the rest
    -- of the session (that was "the drag disappears after a while and never comes back"). Bail cleanly on a
    -- bad frame instead — next good frame just resumes. Never let a stale grip drop linger either.
    if not veh or veh == 0 or not DoesEntityExist(veh) or not state then
        if gripOwned then releaseGrip(veh) end
        why('invalid-veh-or-state'); return
    end
    if dt <= 0.0 then dt = 0.016 end

    HK.launchRevFloor = 0.0   -- reset each frame; re-published below only while actively spinning

    local kmh = state.speedKmh or 0.0
    -- LOGICAL gear. state.gear is unreliable at a dead stop (reads 0), so treat "coupled + very low speed"
    -- as a gear-1 launch even when native gear reads 0 (same lesson as burnout/gearbox ~4120).
    local gear = state.gear or 0

    -- COUPLED: a launch needs a real forward gear. Block neutral/clutch/reverse.
    local coupled = not ((HK.gbInNeutral == true) or (HK.gbClutchHeld == true) or HK.inReverseGear == true)
    -- MUTUAL EXCLUSION: hand the frame to any gesture that owns torque/grip so we never fight them.
    local busy = (HK.driftMode == true)
               or (HK.launch and HK.launch.active == true)   -- Launch Control staged/fire owns launches
               or (HK.freeRevActive == true)
               or (HK.burnoutActive == true)                 -- manual drift-key wheelspin owns the frame

    -- THROTTLE: raw physical W too (a forward-gear stop fires DisableControlAction(71) so effThrottle can
    -- read ~0 at idle — the launch is exactly that case). Same robust read the burnout gate uses.
    local thrRaw = math.max(GetControlNormal(0, 71), GetDisabledControlNormal(0, 71))
    local thr    = math.max(thrRaw, state.effThrottle or 0.0, state.throttle or 0.0)

    -- STAB term (Behavior B): positive throttle rate above StabThresh adds a decaying penalty. Update it
    -- every frame regardless of gate so it's warm when the launch window opens, but only PENALISES below.
    local dThrDt = (thr - prevThr) / dt
    prevThr = thr
    local decay = math.exp(-dt / math.max((cfg.StabDecayMs or 200) / 1000.0, 1e-3))
    stab = stab * decay
    if dThrDt > (cfg.StabThresh or 2.5) then
        stab = math.min((cfg.StabMax or 0.6), stab + (dThrDt - (cfg.StabThresh or 2.5)) * (cfg.StabGain or 0.15))
    end

    -- GATE: gears 1-2, low speed (per-gear ceiling), coupled, grounded, not busy. The gear-scope + speed
    -- ceiling is what keeps this a LAUNCH feature (not a mid-corner grip cut).
    local perGear = cfg.PerGearMaxKmh or { 55.0, 90.0 }
    -- effective gear for the ceiling: at a standstill (gear 0) treat as gear 1.
    local effGear = (gear <= 0) and 1 or gear
    local gearOk  = (effGear == 1) or (effGear == 2)
    local maxKmh  = perGear[effGear] or perGear[1] or 55.0
    local grounded = not IsEntityInAir(veh)

    -- ARMED = the player is doing a real floor-it launch (near stop, throttle down) — the exact case a
    -- drag SHOULD happen. If we're armed but the gate fails, the reason tells us why the drag "went".
    local armed = (kmh <= maxKmh) and (thr >= 0.5)
    W.armed = armed
    W.gearOk, W.coupled, W.grounded, W.busy = gearOk, coupled, grounded, busy

    HK.dbgLaunchTr = HK.dbgLaunchTr or {}
    if not (gearOk and coupled and grounded and not busy and kmh <= maxKmh) then
        if gripOwned then releaseGrip(veh) end
        HK.dbgLaunchTr.gate = false
        HK.dbgLaunchTr.spin = 0.0
        -- Stamp the SPECIFIC gate failure (first that trips), so we see e.g. "armed but busy=drift" or
        -- "armed but not coupled" — the concrete reason a launch fell back to normal GTA behaviour.
        local r = 'over-speed'
        if not gearOk then r = 'gear-not-1-2'
        elseif not coupled then r = 'not-coupled(N/clutch/rev)'
        elseif not grounded then r = 'airborne'
        elseif busy then
            r = 'busy:'
                .. ((HK.driftMode == true) and 'drift'
                or (HK.launch and HK.launch.active == true) and 'launchctrl'
                or (HK.freeRevActive == true) and 'freerev'
                or (HK.burnoutActive == true) and 'burnout' or '?')
        end
        why(armed and ('ARMED-gated:' .. r) or ('idle:' .. r))
        return
    end
    HK.dbgLaunchTr.gate = true

    -- GRIP BUDGET (Behavior A): the throttle fraction the tyres can accept right now.
    --   rises with speed: low at 0 km/h, approaching ~1 by GripFullKmh.
    --   powerful cars get LESS budget (break loose easier) via HK.flyMass (fm<1 = light/powerful).
    --   drivetrain: RWD loosest, AWD grippiest, FWD mid.
    local g0 = cfg.Grip0 or 0.35
    local g1 = cfg.Grip1 or 1.05
    local sp = math.min(1.0, kmh / math.max(cfg.GripFullKmh or 45.0, 1e-3))
    local gripThr = g0 + (g1 - g0) * sp

    local fm = HK.flyMass or 1.0
    -- fm 1.0 -> x1.0; light/powerful (fm<1) lowers budget, heavy/weak (fm>1) raises it.
    local fms = cfg.FlyMassGripScale or 0.5
    gripThr = gripThr * (1.0 + fms * (fm - 1.0))

    -- PER-CLASS CHARACTER + TC-OFF CLAWBACK. Each drivetrain has its own launch feel; turning /tc off
    -- claws the grip bonus back toward RWD so AWD/FWD break traction on launch too (not just RWD).
    local cls = (HK.dbgDrive and HK.dbgDrive.class) or 'rwd'
    local classTbl = cfg.Class or {}
    local ch = classTbl[cls] or classTbl.rwd or { grip = 1.0, torqueCut = 1.0, spinShow = 1.0, revFlare = 1.0, torqueSteer = 0.0 }
    local tcOffOn = (HK.dtTCOff and HK.dtTCOff.on == true) and (cfg.TCOff and cfg.TCOff.Enabled ~= false)
    local classGrip = ch.grip or 1.0
    if tcOffOn then
        local cb = (cfg.TCOff.GripClawback and cfg.TCOff.GripClawback[cls]) or 1.0
        classGrip = classGrip * cb
    end
    gripThr = gripThr * classGrip
    if gripThr < 0.05 then gripThr = 0.05 end

    -- OVERSHOOT -> commanded spin. How far throttle (+ stab) exceeds the grip budget.
    local over = (thr + stab) - gripThr
    if over < 0.0 then over = 0.0 end
    local spinCmd = over * (cfg.OverGain or 1.6)
    if spinCmd > 1.0 then spinCmd = 1.0 end

    -- CONFIRM with the real slip sensor: only fully commit the bog when the wheels are actually loose.
    -- Belt-and-suspenders so an AWD car that hooks up despite a stab doesn't get falsely bogged. Blend so
    -- commanded-but-not-yet-slipping still gives a small bog (the tyres are ABOUT to break) via MinCommit.
    local _, slipMs = vl_detectWheelspin(veh, 0.0)
    local slipConf = math.min(1.0, (slipMs or 0.0) / math.max(cfg.SlipRef or 3.0, 1e-3))
    local minCommit = cfg.MinCommit or 0.4
    local spin = spinCmd * (minCommit + (1.0 - minCommit) * slipConf)
    if spin < 0.0 then spin = 0.0 elseif spin > 1.0 then spin = 1.0 end

    HK.dbgLaunchTr.gripThr  = gripThr
    HK.dbgLaunchTr.over     = over
    HK.dbgLaunchTr.stab     = stab
    HK.dbgLaunchTr.slip     = slipMs
    HK.dbgLaunchTr.spinCmd  = spinCmd
    HK.dbgLaunchTr.spin     = spin
    HK.dbgLaunchTr.gear     = effGear
    HK.dbgLaunchTr.kmh      = kmh
    HK.dbgLaunchTr.cls      = cls
    HK.dbgLaunchTr.tcOff    = tcOffOn == true

    if spin <= 0.001 then
        -- Under the grip limit: clean launch. Hand any dropped grip back and get out of the way.
        if gripOwned then releaseGrip(veh) end
        HK.launchTractionActive = false
        -- Armed but under the grip budget = the tyres are hooking up (feathered / not enough torque to
        -- break loose). This is CORRECT no-drag, but stamp it so "no drag" reads as "hooked up" not "broke".
        why(armed and 'gripped:under-budget' or 'idle:no-throttle')
        return
    end
    HK.launchTractionActive = true
    why('FIRING:drag')

    -- Per-class effect scalars, boosted when TC is off (louder bog/smoke/flare with no traction control).
    local tcut  = cfg.TCOff or {}
    local scTorque = (ch.torqueCut or 1.0) * (tcOffOn and (tcut.TorqueCutBoost or 1.0) or 1.0)
    local scSpin   = (ch.spinShow or 1.0)  * (tcOffOn and (tcut.SpinShowBoost or 1.0) or 1.0)
    local scFlare  = (ch.revFlare or 1.0)  * (tcOffOn and (tcut.RevFlareBoost or 1.0) or 1.0)

    -- UPHILL RELIEF: on a climb the tyres load heavily and read as slip, so launch-traction would bog the
    -- torque (up to 90%) exactly when you need drive to CLIMB — the "full throttle can't move on a steep
    -- hill" bug. Fade the bog out as the uphill grade rises: full bog on the flat, ZERO by HillReliefGrade.
    -- Forward vector's z: nose-UP (climbing) = f.z>0. Only relieves uphill; downhill launches bog normally.
    local fv = GetEntityForwardVector(veh)
    local upGrade = (fv and fv.z > 0.0) and fv.z or 0.0                 -- 0..~1, sin(pitch) uphill
    local reliefAt = cfg.HillReliefGrade or 0.30                        -- grade where bog is fully lifted
    local hillRelief = 1.0 - math.min(1.0, upGrade / math.max(reliefAt, 1e-3))

    -- 1) TORQUE BOG — the "creeps only a bit". Cut forward drive so the wheels spin but the car barely
    -- moves. Never to zero (still a creep). This is what makes flooring-it SLOWER than feathering.
    -- AWD bogs less (torqueCut<1: it hooks + squats), RWD full. TC off cuts harder. Faded by uphill relief.
    local cut = (cfg.LaunchTorqueCut or 0.6) * spin * scTorque * hillRelief
    if cut > 0.9 then cut = 0.9 end
    HK.torqueMult = (HK.torqueMult or 1.0) * (1.0 - cut)
    HK.dbgLaunchTr.hillRelief = hillRelief

    -- 2) VISIBLE SPIN + SMOKE — reuse the wheelspin grip-curve drop (native * mult; vehlib caches the
    -- true original so spin->0 lands on native and restoreField hands it back cleanly). Scaled by spin ×
    -- per-class spinShow (AWD shows least — four-wheel bite). TC off shows more.
    local showSpin = spin * scSpin
    if showSpin > 1.0 then showSpin = 1.0 end
    local mxMult = 1.0 - (cfg.GripMaxReduction or 0.25) * showSpin
    local mnMult = 1.0 - (cfg.GripMinReduction or 0.40) * showSpin
    local spMult = 1.0 + (cfg.GripLowSpeedSpinAdd or 0.70) * showSpin
    -- GRIP-FIELD ARBITER (2026-08-16): CLAIM the shared grip fields instead of writing them directly, so
    -- the burnout / TC-off GripDrop / LC bump can't race our restore (the "drag disappears" bug). The
    -- committer in main.lua resolves the highest-priority claim and writes once. Fall back to a direct
    -- write when the arbiter is off (kill switch) — identical behaviour to before.
    if Config.GripArbiter and Config.GripArbiter.Enabled ~= false and HK.gripClaim then
        HK.gripClaim('launch', (HK.GRIP_PRIO and HK.GRIP_PRIO.launch) or 60,
                     { max = mxMult, min = mnMult, low = spMult })
        gripOwned = false          -- arbiter owns the fields; we hold no direct capture to restore
    else
        vl_scaleHandling(veh, 'fTractionCurveMax', mxMult)
        vl_scaleHandling(veh, 'fTractionCurveMin', mnMult)
        vl_scaleHandling(veh, 'fLowSpeedTractionLossMult', spMult)
        gripOwned = true
    end

    -- 2b) FWD TORQUE STEER — the driven front axle tugs the nose to one side under launch spin. FWD-only
    -- (torqueSteer>0). A gentle yaw nudge scaled by spin; a fixed lean so it feels like the car pulling,
    -- not random. Tiny — this is a wander, not a swerve. Skipped for RWD/AWD (torqueSteer 0).
    local ts = ch.torqueSteer or 0.0
    if ts > 0.001 and veh and veh ~= 0 then
        -- ADD to the existing angular velocity (never overwrite — that would stomp the player's steer).
        local av = GetEntityAngularVelocity(veh)
        local nudge = ts * spin * 0.10   -- small rad/s tug; a wander, not a swerve
        SetEntityAngularVelocity(veh, av.x, av.y, av.z + nudge)
    end

    -- 3) REV FLARE — the "engine RAWRs". CONSERVATIVE + gated: the gearbox owns the rpm needle (Layer A/B,
    -- turbo), so we only nudge a FLOOR up when spin is high and no gearbox gesture is painting. We publish
    -- a requested floor; the gearbox rev model can honor it if wired, else this is a no-op on the gauge
    -- (the torque bog + curve drop already make the wheels visibly spin). Kept as data, not a direct
    -- SetVehicleCurrentRpm, to avoid fighting the gearbox's final rpm writer this frame.
    if (cfg.RevFlare ~= false) then
        local target = (cfg.RevFlareTarget or 0.85) * scFlare
        if target > 1.0 then target = 1.0 end
        HK.launchRevFloor = math.max(HK.launchRevFloor or 0.0, target * spin)
        HK.dbgLaunchTr.revFloor = HK.launchRevFloor
    end
end
