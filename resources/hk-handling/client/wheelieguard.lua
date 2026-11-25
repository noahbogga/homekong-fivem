-----------------------------------------------------------------
-- hk-handling :: client/wheelieguard.lua
-- [F3] Wheelie / Handbrake "180-snap" guard — LOW-SPEED BRAKE PLANT.
--
-- The gearbox engine-write SUSPEND (gearbox.lua) defuses the trigger for most
-- cars but some muscle cars still snap/flip when the handbrake is grabbed at
-- very low speed. Root: at <~22 km/h the handbrake locks the rear so hard the
-- rigid-body solver dumps the velocity vector asymmetrically in one step.
--
-- THIS MODULE plants real brake pressure on EVERY wheel inside that window so
-- the four-wheel load stays SYMMETRIC — no asymmetric impulse for the solver to
-- discharge, so the car can't flip. It uses SetVehicleWheelBrakePressure
-- (vl_brakeWheel), the same path the rev limiter uses — NOT SetControlNormal(72),
-- which the game's input reader overrides (that's why the brake light never lit
-- in the earlier attempt). It also forces the brake lights so the assist shows.
--
-- SPEC (user 2026-06-13): whenever the car is slower than BrakeBelowKmh AND the
-- handbrake is held, wait BrakeDelayMs, then slam the brake. The short delay lets
-- a normal quick handbrake tap (parking, a flick) pass through untouched — only a
-- HELD handbrake at low speed (the bug input) trips the plant.
--
-- Runs every frame from main.lua AFTER the gearbox + headlift, so it sees the
-- final input state and stacks on top of the engine-write suspend.
-----------------------------------------------------------------

local vehlib = exports['hk-vehlib']
local function bind(fn) return function(...) return fn(nil, ...) end end
-- Cache export ref once (avoids per-frame wrapper-closure GC churn; see main.lua).
local vl_brakeWheel = bind(vehlib.brakeWheel)

-- Per-window timer: GetGameTimer() at which the held handbrake first entered the
-- low-speed window. Reset whenever the window breaks (handbrake up / too fast /
-- wrong gear/class), so the BrakeDelayMs must be satisfied by a CONTINUOUS hold.
local holdStartMs = nil

function WheelieGuard_Tick(veh, state, dt)
    local cfg = Config.WheelieGuard
    if not cfg or not cfg.Enabled then return end
    if not cfg.BrakePlant then holdStartMs = nil; return end  -- plant disabled

    -- WINDOW: class 4 (muscle) + gear 1/2 + handbrake held + below the speed cap.
    local inWindow =
        state.handbrake
        and (not cfg.OnlyMuscle or state.class == 4)
        and (state.gear or 0) >= 1
        and (state.gear or 0) <= (cfg.MaxGear or 2)
        and (state.speedKmh or 0.0) < (cfg.BrakeBelowKmh or 22.0)

    if not inWindow then
        holdStartMs = nil          -- window broken — a fresh hold must re-arm the delay
        return
    end

    -- Continuous-hold delay: only plant once the handbrake has been HELD in-window
    -- for BrakeDelayMs (lets a quick tap slip past; the bug needs a sustained hold).
    local now = GetGameTimer()
    if not holdStartMs then holdStartMs = now end
    if (now - holdStartMs) < (cfg.BrakeDelayMs or 80) then return end

    -- Plant every wheel with real brake pressure (NOT a control injection) to keep
    -- the four-wheel load symmetric. Bypasses the control/input system entirely.
    local pressure = cfg.BrakeLevel or 1.0
    local n = state.wheelCount or GetVehicleNumberOfWheels(veh)
    for i = 0, n - 1 do
        vl_brakeWheel(veh, i, pressure)
    end
    SetVehicleBrakeLights(veh, true)               -- make the assist visible
end
