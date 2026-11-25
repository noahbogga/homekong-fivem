-- hk-wheel :: client/steer.lua
-- The steering-physics side. Converts the wheel's PHYSICAL angle into a car
-- steering angle and writes it every frame we own steering. This is the
-- ikt-style "soft lock + 1:1 ratio" — a 900° wheel uses its whole range instead
-- of the gamepad's snap-to-full-lock-in-40°.
--
-- STEERING AUTHORITY (fixed 2026-07-27): feed ONLY control 59 (INPUT_VEH_MOVE_LR). The
-- earlier build wrote BOTH SetVehicleSteeringAngle AND control 59 every frame — they FIGHT:
-- GTA's input system re-applies control 59's own steering (with its return-to-center + speed
-- scaling) while our angle write pulls the other way, so the wheels oscillate and bias to one
-- side (the "bounces / always goes right" bug). Control 59 is ALSO exactly what hk-handling
-- reads (state.steer), so feeding it keeps the sim, the visual wheels, and GTA all consistent
-- with ONE writer. The soft-lock + speed-ratio shaping still happens here (we scale the -1..1
-- we push into 59). SetVehicleSteeringAngle is left UNUSED (kept only as an optional future
-- direct-drive path, gated off) — do NOT write both at once.

Steer = Steer or {}

-- SetVehicleSteeringAngle takes DEGREES at the road wheels (roughly ±angle). The
-- car's real max is model-dependent (~35-50°); we clamp to the configured soft lock.
local SET_STEER_ANGLE = 0x6EABEBB03BD2352D  -- SET_VEHICLE_STEERING_ANGLE (fallback hash use)

-- Smoothed -1..1 steer we push into control 59 (eased so a reconnect / speed-ramp doesn't jump).
local curSteer = 0.0
local lastActive = false

-- Resolve the car's soft lock (max road-wheel degrees) for this vehicle.
local function lockDegFor(veh)
    local S = Config.Steer
    local byClass = S.LockByClass[GetVehicleClass(veh)]
    return byClass or S.LockDegDefault
end

-- Speed-sensitive ratio multiplier: full authority at low speed, reduced at speed.
local function speedRatio(kmh)
    local S = Config.Steer
    if kmh <= 0 then return 1.0 end
    local t = kmh / S.SpeedReductionKmh
    if t > 1.0 then t = 1.0 end
    -- Smoothstep from 1.0 down to SpeedReductionMin.
    local eased = t * t * (3.0 - 2.0 * t)
    return 1.0 - (1.0 - S.SpeedReductionMin) * eased
end

-- Shape the app's normalized steer (-1..1 across the DEVICE's physical range) into the -1..1
-- we push into control 59, applying the soft-lock RATIO + speed sensitivity. Soft lock here is
-- a RATIO: lockDeg/maxCarLock scales how much of full control-59 a given wheel angle produces,
-- so a 900° wheel uses its whole range instead of snapping to full lock in the first ~40°.
local MAX_CAR_LOCK = 40.0     -- reference full-lock (deg) the ratio is relative to
local function shapedSteer(norm, veh, kmh)
    local S = Config.Steer
    if math.abs(norm) < S.Deadzone then return 0.0 end
    local ratio = (lockDegFor(veh) / MAX_CAR_LOCK) * speedRatio(kmh)
    local out = norm * ratio
    if out > 1.0 then out = 1.0 elseif out < -1.0 then out = -1.0 end
    return out
end

-- Public: apply this frame. Returns the -1..1 steer we drove (or nil if we didn't own steering).
-- SINGLE WRITER: control 59 only (see header). main.lua does the actual SetControlNormal so the
-- value composes with the rest of the input frame; we just compute + smooth it here.
function Steer.apply(veh, frame, kmh, dt)
    if not (Config.Steer.Enabled and veh and veh ~= 0) then return nil end

    if frame == nil then
        -- Wheel gone: fade our steer back to 0 over ReturnToPadMs, then release to pad.
        if lastActive then
            curSteer = curSteer * math.max(0.0, 1.0 - dt * (1000.0 / Config.Steer.ReturnToPadMs))
            if math.abs(curSteer) < 0.01 then
                lastActive = false
                return nil
            end
            return curSteer
        end
        return nil
    end

    local target = shapedSteer(frame.steer or 0.0, veh, kmh)
    -- Light smoothing to swallow packet jitter without adding felt lag (direct device).
    local k = math.min(1.0, dt * 30.0)
    curSteer = curSteer + (target - curSteer) * k
    lastActive = true
    return curSteer
end

function Steer.currentSteer() return curSteer end
