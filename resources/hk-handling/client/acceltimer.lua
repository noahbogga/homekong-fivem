-----------------------------------------------------------------
-- hk-handling :: client/acceltimer.lua
-- 0-100 / 0-200 km/h acceleration timer + top-speed capture.
-- Pure stopwatch — no calibration wiring. Works in any gearbox mode.
--
-- HOW: /accel arms it. Come to a FULL STOP, then floor it. Timing starts
-- the frame you cross ~1 km/h and stops at each split (60/100/160/200).
-- Continues tracking past 200 until throttle lift; reports peak top speed.
-- Results print to F8 AND show on screen. /accel again re-arms.
-----------------------------------------------------------------

local armed   = false
local timing  = false
local tStart  = 0
local splits  = {}            -- [kmh] = ms
local peakKmh = 0.0
local seenStop = false        -- must see a full stop before timing arms
local liftAt  = 0             -- GetGameTimer() when throttle first dropped (0 = pedal down)
local prevKmh = 0.0           -- last frame's speed (to tell a shift-cut from a real lift)
local SPLIT_KMH = { 60, 100, 160, 200 }
-- A gearbox SHIFT briefly zeroes the throttle control (DisableControlAction for the rev-match
-- dip), so GetControlNormal(71) reads ~0 for a few frames mid-pull. A REAL lift is sustained
-- AND the car stops gaining speed. So only end on a lift that has lasted LIFT_CONFIRM_MS while
-- the car is NOT still accelerating — a shift-cut clears well before that and speed keeps rising.
local LIFT_CONFIRM_MS = 350
local lastShown = nil         -- frozen result table (most recent completed run)
local prevShown = nil         -- the run before lastShown (for +/- delta column)

local function drawText(x, y, text, scale, r, g, b)
    SetTextFont(4)
    SetTextScale(scale, scale)
    SetTextColour(r, g, b, 255)
    SetTextOutline()
    BeginTextCommandDisplayText('STRING')
    AddTextComponentSubstringPlayerName(text)
    EndTextCommandDisplayText(x, y)
end

local function resetRun()
    timing  = false
    tStart  = 0
    splits  = {}
    peakKmh = 0.0
    seenStop = false
    liftAt  = 0
    prevKmh = 0.0
end

CreateThread(function()
    while true do
        local sleep = 250
        if armed then
            sleep = 0
            local ped = PlayerPedId()
            local veh = GetVehiclePedIsIn(ped, false)
            if veh ~= 0 and GetPedInVehicleSeat(veh, -1) == ped then
                local kmh = GetEntitySpeed(veh) * 3.6
                local thr = GetControlNormal(0, 71)

                if not timing then
                    if kmh <= 1.0 then
                        seenStop = true
                    end
                    if seenStop and thr > 0.5 and kmh > 0.6 then
                        timing   = true
                        tStart   = GetGameTimer()
                        splits   = {}
                        peakKmh  = kmh
                        liftAt   = 0
                        prevKmh  = kmh
                    end
                else
                    local elapsed = GetGameTimer() - tStart

                    -- track splits
                    for _, target in ipairs(SPLIT_KMH) do
                        if not splits[target] and kmh >= target then
                            splits[target] = elapsed
                            print(('[hk-accel] 0-%d km/h: %.2fs'):format(target, elapsed / 1000.0))
                        end
                    end

                    -- track peak beyond splits
                    if kmh > peakKmh then peakKmh = kmh end

                    -- LIFT DETECTION (shift-cut immune). A gearbox shift briefly zeroes the
                    -- throttle control for the rev-match dip, so thr reads ~0 for a few frames
                    -- mid-pull — the old `thr < 0.5` ended the run right there (the "record
                    -- stops at a gear change" bug). A REAL lift is SUSTAINED and the car is no
                    -- longer gaining speed; a shift-cut is momentary and speed keeps climbing.
                    -- So: start a lift timer when the pedal drops, but only COUNT it as a lift
                    -- once it has persisted LIFT_CONFIRM_MS AND the car isn't still accelerating.
                    -- Any frame the pedal is back down (or the car is still pulling) clears it.
                    local accelerating = kmh > prevKmh + 0.05      -- still gaining speed this frame
                    if thr < 0.5 then
                        if liftAt == 0 then liftAt = GetGameTimer() end
                    else
                        liftAt = 0
                    end
                    -- a confirmed lift: pedal has been down long enough AND we've stopped pulling
                    local confirmedLift = (liftAt ~= 0)
                        and (GetGameTimer() - liftAt >= LIFT_CONFIRM_MS)
                        and (not accelerating)
                    prevKmh = kmh

                    -- completion: confirmed throttle lift OR come to a stop
                    local topHit = splits[SPLIT_KMH[#SPLIT_KMH]] ~= nil
                    local lifted = confirmedLift and (elapsed > 1000) and (splits[60] ~= nil)
                    local stopped = kmh <= 0.5 and elapsed > 1000

                    if lifted or stopped then
                        lastShown = { splits = splits, peakKmh = peakKmh }
                        resetRun()
                        armed = false
                        print(('[hk-accel] run complete — peak %.1f km/h | /accel to arm again'):format(peakKmh))
                    elseif kmh <= 0.5 and not topHit then
                        resetRun()   -- rolled back before 60: re-wait
                    end
                end
            end
        end

        -- DRAW. Force sleep=0 whenever there's anything to display so text stays visible.
        local showing = armed or (lastShown ~= nil)
        if showing then
            sleep = 0
            local y = 0.58
            local title
            if armed then
                title = timing and '~g~ACCEL TIMING...' or '~y~ACCEL ARMED — floor it from a stop'
            else
                title = '~b~ACCEL — LAST RESULT'
            end
            drawText(0.015, y, title, 0.5, 255, 255, 0)

            local src = (timing and splits) or (lastShown and lastShown.splits)
            if src then
                local i = 1
                for _, target in ipairs(SPLIT_KMH) do
                    local ms = src[target]
                    local line = ('0-%d: %s'):format(target, ms and ('%.2fs'):format(ms / 1000.0) or '--')
                    local r, g, b = 200, 200, 255
                    if (not timing) and prevShown and ms and prevShown.splits and prevShown.splits[target] then
                        local d = (ms - prevShown.splits[target]) / 1000.0
                        if math.abs(d) >= 0.005 then
                            local sign = (d > 0) and '+' or '-'
                            line = line .. ('   ~s~(%s%.2fs)'):format(sign, math.abs(d))
                            if d > 0 then r, g, b = 255, 120, 120
                            else           r, g, b = 120, 255, 120 end
                        else
                            line = line .. '   ~s~(=)'
                        end
                    end
                    drawText(0.015, y + 0.030 * i, line, 0.45, r, g, b)
                    i = i + 1
                end

                -- peak top speed footer (frozen result only)
                if not timing and lastShown and (lastShown.peakKmh or 0) > 0 then
                    drawText(0.015, y + 0.030 * i, ('TOP: %.1f km/h'):format(lastShown.peakKmh), 0.45, 160, 220, 160)
                    i = i + 1
                end

                if not timing then
                    drawText(0.015, y + 0.030 * i,
                        '~s~/accel to run again' .. (prevShown and '  ·  (+/- vs previous run)' or ''),
                        0.35, 160, 160, 160)
                end
            end
        end

        Wait(sleep)
    end
end)

RegisterCommand('accel', function()
    armed = true
    if lastShown then prevShown = lastShown end
    lastShown = nil
    resetRun()
    print('[hk-accel] ARMED — come to a full stop, then floor it. Splits: 60/100/160/200 km/h + top speed')
end, false)

print('[hk-accel] loaded. /accel to arm a 0-200 timer + top-speed capture (works in any mode incl. /setgear 6)')
