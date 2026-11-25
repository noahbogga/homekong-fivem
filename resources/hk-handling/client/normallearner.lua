-----------------------------------------------------------------
-- hk-handling :: client/normallearner.lua
-- NORMAL mode background 0-100 open-loop learner.
--
-- Phase A (no N: baseline in DB):
--   Suspends the gearbox (reuses gbSuspended via HK.normalLearnerSetNativeSuspend),
--   lets GTA run natively. Measures T_native. Sends telemetry to server.
--   Server writes speedCal = 'N:60,T;100,T;'.
--
-- Phase B (N: baseline exists):
--   Runs with the box normally, reads fApplied from speedCalC (or 1.0).
--   Measures T_ours. Sends telemetry. Server computes f = fApplied * T_ours / T_native
--   open-loop (one absolute estimate per run, never compounds) and blends into speedCalC.
--
-- Client sends telemetry ONLY (t60, t100, fApplied, grade). Server computes trim.
-- Gates: isNormal() + NormalLearn.Enabled + isStock() + clean WOT + slope check.
-----------------------------------------------------------------

local vehlib = exports['hk-vehlib']
local function bind(fn) return function(...) return fn(nil, ...) end end
local vl_getDrivenVehicle = bind(vehlib.getDrivenVehicle)

local function gearboxMode()
    local m = Config.Gearbox and Config.Gearbox.Mode or 'normal'
    m = tostring(m):lower()
    if m ~= 'easy' and m ~= 'normal' and m ~= 'expert' then return 'normal' end
    return m
end
local function isNormal() return gearboxMode() == 'normal' end

local function cfg() return Config.Gearbox and Config.Gearbox.NormalLearn end

local function isStock(veh)
    if GetVehicleMod(veh, 11) >= 0 then return false end   -- engine
    if GetVehicleMod(veh, 12) >= 0 then return false end   -- brakes
    if GetVehicleMod(veh, 13) >= 0 then return false end   -- transmission
    if IsToggleModOn(veh, 18) then return false end        -- turbo
    return true
end

-- Interpolate the exact time we crossed a speed threshold between two frames.
local function interpCrossTime(t0, v0, t1, v1, threshold)
    if v1 == v0 then return t1 end
    local a = (threshold - v0) / (v1 - v0)
    a = math.max(0.0, math.min(1.0, a))
    return t0 + (t1 - t0) * a
end

-- Unpack the scalar from a speedCalC BIGINT (slot 1 only).
local SPC_SENTINEL = 10000000000000000
local function unpackScalar(packed)
    packed = math.tointeger(tonumber(packed or 0)) or 0
    if packed < SPC_SENTINEL then return nil end
    packed = packed - SPC_SENTINEL
    local g1 = (packed // 1000000000000) % 10000
    if g1 <= 0 then return nil end
    return g1 / 100.0
end

-----------------------------------------------------------------
-- State
-----------------------------------------------------------------
local pull = nil          -- active pull state or nil
local lastSampleAt = 0   -- GetGameTimer() of last submitted sample

local function abortPull(reason)
    local C = cfg()
    if pull and C and C.Debug then
        print(('[hk-normallearn] abort: %s'):format(reason or '?'))
    end
    if pull and pull.phase == 'native' and pull.veh and pull.veh ~= 0 then
        if HK and HK.normalLearnerSetNativeSuspend then
            HK.normalLearnerSetNativeSuspend(pull.veh, false)
        end
    end
    pull = nil
end

-----------------------------------------------------------------
-- MAIN LOOP
-----------------------------------------------------------------
CreateThread(function()
    while true do
        local sleep = 200

        local C = cfg()
        if isNormal() and C and C.Enabled then
            local veh = vl_getDrivenVehicle()

            if not veh then
                if pull then abortPull('no_vehicle') end
                goto continue
            end

            sleep = 0

            local ped   = PlayerPedId()
            local hash  = GetEntityModel(veh) & 0xFFFFFFFF
            local kmh   = GetEntitySpeed(veh) * 3.6
            local thr   = GetControlNormal(0, 71)
            local brake = GetControlNormal(0, 72)
            local hb    = IsControlPressed(0, 76) or GetVehicleHandbrake(veh)
            local now   = GetGameTimer() / 1000.0

            -- Universal abort conditions
            local bad = brake > (C.BrakeMax or 0.05)
                     or hb
                     or IsEntityInAir(veh)
                     or HasEntityCollidedWithAnything(veh)

            -- Vehicle changed mid-pull
            if pull and pull.veh ~= veh then abortPull('vehicle_changed') end

            -- Hard-steer abort only while timing
            if pull and pull.timing then
                local steer = math.abs(GetControlNormal(0, 59) - 0.5) * 2
                if steer > (C.MaxSteer or 0.35) then abortPull('hard_steer') end
            end

            if bad and pull then abortPull('bad_inputs') end

            if not pull then
                -- Cooldown
                local gapOk = (GetGameTimer() - lastSampleAt) >= (C.MinRunGapMs or 1500)
                if not gapOk then goto continue end

                -- Stock check
                if C.RequireStock and not isStock(veh) then goto continue end

                -- Determine phase from model data
                local m = HK and HK.manualModels and HK.manualModels[hash]
                local hasNative = m and type(m.speedCal) == 'string' and m.speedCal:sub(1, 2) == 'N:'
                local phase = hasNative and 'custom' or 'native'

                -- Arm on clean launch intent: near-stop + strong throttle
                if kmh <= (C.StartKmh or 2.0)
                   and thr >= (C.StartThrottle or 0.95)
                   and not bad then

                    local fApplied = 1.0
                    if phase == 'custom' and m and m.speedCalC then
                        fApplied = unpackScalar(m.speedCalC) or 1.0
                    end

                    if phase == 'native' then
                        if HK and HK.normalLearnerSetNativeSuspend then
                            HK.normalLearnerSetNativeSuspend(veh, true)
                        end
                        if C.Debug then print('[hk-normallearn] Phase A armed (native capture)') end
                    else
                        if C.Debug then
                            print(('[hk-normallearn] Phase B armed (custom, fApplied=%.3f)'):format(fApplied))
                        end
                    end

                    local coords = GetEntityCoords(veh)
                    pull = {
                        veh      = veh,
                        hash     = hash,
                        phase    = phase,
                        fApplied = fApplied,
                        timing   = false,
                        started  = false,
                        startTime= nil,
                        midTime  = nil,
                        endTime  = nil,
                        startCoords = coords,
                        liftMs   = 0,
                        lastT    = now,
                        lastV    = kmh,
                    }
                end
            else
                -- In a pull
                local dtMs = math.max(0, (now - pull.lastT) * 1000.0)

                -- Throttle lift tolerance
                if thr < (C.MinThrottle or 0.92) then
                    pull.liftMs = pull.liftMs + dtMs
                    if pull.liftMs > (C.MaxLiftMs or 100) then
                        abortPull('throttle_lift')
                        goto continue
                    end
                else
                    pull.liftMs = 0
                end

                local lastV = pull.lastV
                local lastT = pull.lastT

                -- START crossing (StartKmh threshold)
                if not pull.started then
                    if lastV < (C.StartKmh or 2.0) and kmh >= (C.StartKmh or 2.0) then
                        pull.startTime = interpCrossTime(lastT, lastV, now, kmh, C.StartKmh or 2.0)
                        pull.started = true
                        pull.timing  = true
                    end
                else
                    -- MID crossing (MidKmh = 60)
                    if not pull.midTime and lastV < (C.MidKmh or 60.0) and kmh >= (C.MidKmh or 60.0) then
                        pull.midTime = interpCrossTime(lastT, lastV, now, kmh, C.MidKmh or 60.0)
                    end

                    -- END crossing (EndKmh = 100)
                    if lastV < (C.EndKmh or 100.0) and kmh >= (C.EndKmh or 100.0) then
                        pull.endTime = interpCrossTime(lastT, lastV, now, kmh, C.EndKmh or 100.0)

                        local endCoords = GetEntityCoords(veh)
                        local sc = pull.startCoords
                        local dx = endCoords.x - sc.x
                        local dy = endCoords.y - sc.y
                        local dz = endCoords.z - sc.z
                        local dist2d = math.sqrt(dx * dx + dy * dy)
                        local grade  = math.abs(dz) / math.max(dist2d, 1.0)

                        if grade > (C.MaxGrade or 0.025) then
                            abortPull('slope')
                            goto continue
                        end

                        local t100 = pull.endTime - pull.startTime
                        local t60  = pull.midTime and (pull.midTime - pull.startTime) or nil

                        if t100 < (C.MinT100 or 1.2) or t100 > (C.MaxT100 or 40.0) then
                            abortPull('implausible_time')
                            goto continue
                        end

                        -- Release native suspend before sending
                        if pull.phase == 'native' and HK and HK.normalLearnerSetNativeSuspend then
                            HK.normalLearnerSetNativeSuspend(veh, false)
                        end

                        -- Collect display name for DB label
                        local spawnName = ''
                        local displayName = GetLabelText(GetDisplayNameFromVehicleModel(GetEntityModel(veh)))
                        if not displayName or displayName == '' or displayName == 'NULL' then
                            displayName = GetDisplayNameFromVehicleModel(GetEntityModel(veh))
                        end

                        if C.Debug then
                            print(('[hk-normallearn] %s complete | phase=%s t60=%s t100=%.3f grade=%.4f fApplied=%.3f')
                                :format(displayName, pull.phase,
                                        t60 and ('%.3f'):format(t60) or 'nil',
                                        t100, grade, pull.fApplied))
                        end

                        TriggerServerEvent('hk-handling:gearbox:normalLearnSample', {
                            hash     = hash,
                            model    = spawnName,
                            name     = displayName,
                            phase    = pull.phase,
                            t60      = t60,
                            t100     = t100,
                            fApplied = pull.fApplied,
                            grade    = grade,
                        })

                        lastSampleAt = GetGameTimer()
                        pull = nil
                        goto continue
                    end
                end

                pull.lastT = now
                pull.lastV = kmh
            end
        else
            if pull then abortPull('mode_changed') end
        end

        ::continue::
        Wait(sleep)
    end
end)

print('[hk-normallearn] loaded — NORMAL mode background 0-100 open-loop learner')
