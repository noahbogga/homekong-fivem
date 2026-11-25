-----------------------------------------------------------------
-- hk-handling :: client/stability.lua
-- [E1] ESC (Electronic Stability Control) — cuts torque + boosts
-- ARB when yaw rate exceeds the value expected for current speed/steer.
--
-- 2026-08-14 REBUILD (reconciled to the current architecture):
--   * ARB is a SHARED handling field — drift.lua also scales fAntiRollBarForce.
--     ESC now exposes _G.ESC_Restore(veh), called at drift-entry (drift.lua) BEFORE
--     drift captures its baseline, so drift never banks an ESC-boosted ARB as
--     "native" (the single-writer discipline every handling-field tool follows).
--   * ESC_Reset(veh) restores ARB + clears state on vehicle swap (wired in main.lua),
--     so a car we leave mid-intervention doesn't keep a boosted ARB, and the next
--     car starts clean.
--   * Torque cut is a MULTIPLY onto HK.torqueMult (main.lua zeroes it to 1.0 each
--     frame, then TC/GripDrop/limiter/ESC all multiply — min-of-cuts emerges), so
--     ESC composes with TC instead of fighting it.
--   * effThrottle-aware guard: ESC should not fight a deliberate power-on slide the
--     driver is feeding — only intervene on genuine over-rotation.
--   * Debug readout via HK.dbgESC (rpmdebug overlay).
-----------------------------------------------------------------

local vehlib = exports['hk-vehlib']
local function bind(fn) return function(...) return fn(nil, ...) end end
-- Cache export refs once (avoids per-frame wrapper-closure GC churn; see gearbox.lua).
local vl_restoreField  = bind(vehlib.restoreField)
local vl_scaleHandling = bind(vehlib.scaleHandling)

-- Module state
local escArbScaled = false   -- true while ESC is holding a boosted fAntiRollBarForce

-----------------------------------------------------------------
-- SHARED-FIELD RESTORE (mirrors _G.TCOff_GripRestore). Drift owns fAntiRollBarForce
-- while drifting; if ESC had it boosted when the player flicked into drift, restore
-- it to native FIRST so drift captures the TRUE baseline (not the boosted value).
-- Called from drift.lua at entry, and from ESC_Reset on veh-swap. Idempotent.
-----------------------------------------------------------------
local function escRestoreArb(veh)
    if escArbScaled and veh and veh ~= 0 then
        vl_restoreField(veh, 'fAntiRollBarForce')
        escArbScaled = false
    end
    HK.escActive = false
    HK.escFactor = 0.0
end
_G.ESC_Restore = escRestoreArb

-----------------------------------------------------------------
-- ESC TICK
-----------------------------------------------------------------
function ESC_Tick(veh, state, dt)
    local cfg = Config.ESC
    local kmh = state.speedKmh or 0.0
    local yawRate = math.abs(state.yawRate or 0.0)  -- rad/s

    -- Interpolate the yaw-rate threshold by speed (more permissive at low speed —
    -- tight low-speed turns are normal; high-speed yaw is where oversteer bites).
    local speedT = (kmh - cfg.LowSpeedKmh) / (cfg.HighSpeedKmh - cfg.LowSpeedKmh)
    if speedT < 0.0 then speedT = 0.0 elseif speedT > 1.0 then speedT = 1.0 end
    local threshold = cfg.YawRateThresholdLow
                      + (cfg.YawRateThresholdBase - cfg.YawRateThresholdLow) * speedT

    -- Steering tolerance: if the player is actively steering, allow more yaw before
    -- calling it oversteer (they asked the car to rotate). Scaled by SteerTolerance.
    local steerInput = math.abs(state.steer or 0.0)
    threshold = threshold + steerInput * (cfg.SteerTolerance or 1.5)

    -- Detect oversteer: yaw past threshold, above the min speed, AND on the ground
    -- (airborne yaw is freewheel noise — never intervene, mirrors the limiter guard).
    local grounded = (state.onAllWheels ~= false)
    local oversteering = grounded and yawRate > threshold and kmh > cfg.LowSpeedKmh

    -- Smooth intervention 0..1 (fast attack, slow release).
    local target = oversteering and 1.0 or 0.0
    local tau = oversteering and cfg.AttackTau or cfg.ReleaseTau
    HK.escFactor = HK.escFactor + (target - HK.escFactor) * (1.0 - math.exp(-dt / tau))

    if HK.escFactor > 0.01 then
        -- TORQUE CUT — multiply onto the shared HK.torqueMult (composes with TC/limiter;
        -- main.lua reset it to 1.0 this frame). At full intervention torque scales to
        -- TorqueCut (e.g. 0.4 = 40% power); eased by escFactor so it breathes in/out.
        local mult = 1.0 - (HK.escFactor * (1.0 - (cfg.TorqueCut or 0.4)))
        HK.torqueMult = HK.torqueMult * mult

        -- ARB BOOST — stiffen the anti-roll bar to resist further rotation. scaleHandling
        -- captures native on first touch (first-capture-wins) and scales from it, so this
        -- is safe per-frame; escArbScaled latches so we know to restore.
        vl_scaleHandling(veh, 'fAntiRollBarForce', 1.0 + ((cfg.ARBBoostMult or 2.0) - 1.0) * HK.escFactor)
        escArbScaled = true
        HK.escActive = true
    elseif escArbScaled then
        -- Intervention ended — hand the ARB back to native (byte-exact) and clear latch.
        vl_restoreField(veh, 'fAntiRollBarForce')
        escArbScaled = false
        HK.escActive = false
    else
        HK.escActive = false
    end

    -- DEBUG readout (rpmdebug overlay reads HK.dbgESC when HK.hdbgOn).
    if HK and HK.hdbgOn then
        HK.dbgESC = { on = HK.escActive, f = HK.escFactor, yaw = yawRate,
                      thr = threshold, cut = (HK.escFactor > 0.01)
                          and (1.0 - (HK.escFactor * (1.0 - (cfg.TorqueCut or 0.4)))) or 1.0 }
    end
end

-----------------------------------------------------------------
-- RESET (vehicle swap / exit) — called from main.lua. Restore ARB + clear state so
-- the car we leave is byte-exact native and the next car starts clean.
-----------------------------------------------------------------
function ESC_Reset(veh)
    escRestoreArb(veh)
    if HK then HK.dbgESC = nil end
end
