-----------------------------------------------------------------
-- hk-handling :: client/payload.lua
-- [W1] Passenger Weight — acceleration debuff scaled by passenger count.
--
-- Each occupied NON-DRIVER seat bleeds a little acceleration via the engine
-- torque multiplier (HK.torqueMult). We use the torque mult — NOT mass, NOT
-- fInitialDriveForce — specifically so TOP SPEED is untouched: the car still
-- reaches its handling.meta top speed, just accelerates there a touch slower.
-- The debuff also FADES to zero near top speed so it's mathematically zero at
-- terminal velocity (honours the hk-handling speed invariant).
--
-- Default (no passengers) = no debuff = stock "level 1". Each passenger adds a
-- level: -5% / -10% / -15% (capped). NPC passengers count (weight is weight).
--
-- Cost: seat counting is polled at Config.Payload.PollMs (not per-frame); the
-- per-frame tick is just a cached-value multiply + a cheap speed-fade.
-----------------------------------------------------------------

-- Cached, recomputed every PollMs (passenger count rarely changes per frame).
local lastPoll     = 0
local debuffAtFull = 0.0   -- the debuff fraction at full strength (0..MaxDebuff), pre-fade
local maxVel       = 0.0   -- car's fInitialDriveMaxFlatVel (m/s) for the high-speed fade
local pollVeh      = 0     -- vehicle the cache was computed for (invalidate on change)

-- Count occupied non-driver seats. Driver = seat -1; passenger seats = 0..max-1.
local function countPassengers(veh, countNpcs)
    local maxSeats = GetVehicleMaxNumberOfPassengers(veh)  -- excludes driver
    if not maxSeats or maxSeats < 1 then return 0 end
    local n = 0
    for seat = 0, maxSeats - 1 do
        if not IsVehicleSeatFree(veh, seat) then
            local ped = GetPedInVehicleSeat(veh, seat)
            if ped and ped ~= 0 then
                if countNpcs or IsPedAPlayer(ped) then
                    n = n + 1
                end
            end
        end
    end
    return n
end

function Payload_Tick(veh, state, dt)
    local cfg = Config.Payload
    if not cfg or not cfg.Enabled then return end
    local now = state.gameTimer or GetGameTimer()

    -- Re-poll the (rarely-changing) passenger count + top-speed reference at a low
    -- cadence, or immediately if we switched vehicles.
    if veh ~= pollVeh or now - lastPoll >= (cfg.PollMs or 500) then
        lastPoll = now
        pollVeh  = veh
        local pax = countPassengers(veh, cfg.CountNpcs ~= false)
        debuffAtFull = math.min(pax * (cfg.PerPassenger or 0.05), cfg.MaxDebuff or 0.15)
        maxVel = GetVehicleHandlingFloat(veh, 'CHandlingData', 'fInitialDriveMaxFlatVel') or 0.0
    end

    if debuffAtFull <= 0.0 then return end   -- no passengers (level 1) = nothing to do

    -- HIGH-SPEED FADE: full debuff while accelerating; ramp to zero over the top
    -- fraction of the car's speed range so top speed is never reduced. speed is
    -- m/s (state.speed); maxVel is m/s. If maxVel is unknown, no fade (safe).
    local debuff = debuffAtFull
    if maxVel > 0.0 then
        local frac  = (state.speed or 0.0) / maxVel        -- 0 at rest -> ~1 near top speed
        local fs    = cfg.FadeStartFrac or 0.80
        local fe    = cfg.FadeEndFrac or 0.97
        if frac >= fe then
            return                                          -- at/near top speed: no debuff at all
        elseif frac > fs then
            local t = (frac - fs) / (fe - fs)               -- 0 at fs -> 1 at fe
            debuff = debuffAtFull * (1.0 - t)               -- fade the debuff out
        end
    end

    HK.torqueMult = HK.torqueMult * (1.0 - debuff)
end

-- CRIT-3: clear cached state on vehicle change/exit.
function Payload_Reset()
    lastPoll, debuffAtFull, maxVel, pollVeh = 0, 0.0, 0.0, 0
end
