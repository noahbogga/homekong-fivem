-- hk-race :: client/carcal.lua
-- Passive auto-calibration for the tier system. Two jobs, both natives-only (no
-- hk-handling / hk-vehlib dependency):
--   1) t100 capture — detect a clean standing-start full-throttle pull and time
--      0-100 km/h via interpolated threshold crossings (ported/slimmed from the old
--      hk-handling normallearner). Paranoid aborts keep the sample honest.
--   2) top-speed tracking — while driving any car, remember the peak speed seen and
--      report a new personal best for that model.
-- Learned values are sent to the server (hk-race:carcal:sample), which keeps the
-- best/peak, persists to hk_race_car_cal, and rebroadcasts the tier cal map.

local CFG = function() return RaceConfig.AutoCal end

-- The vehicle the player is DRIVING (seat -1), or nil.
local function drivenVeh()
    local ped = PlayerPedId()
    if not IsPedInAnyVehicle(ped, false) then return nil end
    local veh = GetVehiclePedIsIn(ped, false)
    if not veh or veh == 0 then return nil end
    if GetPedInVehicleSeat(veh, -1) ~= ped then return nil end
    return veh
end

-- Fully stock = no engine/brake/transmission mod fitted and no turbo toggle. A
-- modded car isn't a fair baseline for the model's tier, so we skip it.
local function isStock(veh)
    if GetVehicleMod(veh, 11) >= 0 then return false end   -- engine
    if GetVehicleMod(veh, 12) >= 0 then return false end   -- brakes
    if GetVehicleMod(veh, 13) >= 0 then return false end   -- transmission
    if IsToggleModOn(veh, 18) then return false end        -- turbo
    return true
end

-- Interpolate the exact time a speed threshold was crossed between two frames.
local function interpCrossTime(t0, v0, t1, v1, threshold)
    if v1 <= v0 then return t1 end
    local a = (threshold - v0) / (v1 - v0)
    if a < 0 then a = 0 elseif a > 1 then a = 1 end
    return t0 + (t1 - t0) * a
end

local function dbg(msg)
    if CFG() and CFG().debug then print('[hk-carcal] ' .. msg) end
end

local function modelOf(veh)
    local n = GetDisplayNameFromVehicleModel(GetEntityModel(veh))
    if not n or n == '' or n == 'NULL' then return '' end
    return tostring(n):lower()
end
local function nameOf(veh)
    local lbl = GetLabelText(GetDisplayNameFromVehicleModel(GetEntityModel(veh)))
    if not lbl or lbl == '' or lbl == 'NULL' then return modelOf(veh) end
    return lbl
end

-- Report a capture to the server (validates + persists there too).
local function report(veh, t100, top)
    TriggerServerEvent('hk-race:carcal:sample', {
        hash  = GetEntityModel(veh) & 0xFFFFFFFF,
        model = modelOf(veh),
        name  = nameOf(veh),
        t100  = t100,
        top   = top,
    })
end

-- ── Top-speed tracker ────────────────────────────────────────────────────────
-- While driving, track the peak speed for the current model and report a new best.
-- Best-effort: native top-speed estimate covers the gap until a car is driven fast.
local peakByHash = {}   -- [hash] = best km/h reported this session (avoid spam)
CreateThread(function()
    while true do
        local sleep = 1500
        local C = CFG()
        if C and C.enabled then
            local veh = drivenVeh()
            if veh then
                sleep = C.topSampleMs or 750
                local kmh = GetEntitySpeed(veh) * 3.6
                if kmh >= (C.topMinKmh or 40.0) then
                    local hash = GetEntityModel(veh) & 0xFFFFFFFF
                    local prev = peakByHash[hash] or 0
                    if kmh > prev + (C.reportTopMinDelta or 3.0) then
                        peakByHash[hash] = kmh
                        report(veh, nil, kmh)   -- top-only sample
                        dbg(('top %s = %.1f km/h'):format(modelOf(veh), kmh))
                    end
                end
            end
        end
        Wait(sleep)
    end
end)

-- ── t100 capture (clean standing-start WOT pull) ─────────────────────────────
local pull = nil            -- in-progress capture state
local lastSampleAt = 0      -- gametime of last accepted capture (cooldown)

local function abortPull(reason)
    if pull then dbg('abort: ' .. tostring(reason)) end
    pull = nil
end

CreateThread(function()
    while true do
        local sleep = 200
        local C = CFG()
        if C and C.enabled then
            local veh = drivenVeh()
            if not veh then
                if pull then abortPull('no_vehicle') end
            else
                sleep = 0
                local hash  = GetEntityModel(veh) & 0xFFFFFFFF
                local kmh   = GetEntitySpeed(veh) * 3.6
                local thr   = GetControlNormal(0, 71)
                local brake = GetControlNormal(0, 72)
                local hb    = IsControlPressed(0, 76) or GetVehicleHandbrake(veh)
                local now   = GetGameTimer() / 1000.0

                local bad = brake > 0.05 or hb
                    or IsEntityInAir(veh)
                    or HasEntityCollidedWithAnything(veh)

                if pull and pull.veh ~= veh then abortPull('vehicle_changed') end
                if pull and pull.timing then
                    local steer = math.abs(GetControlNormal(0, 59) - 0.5) * 2
                    if steer > (C.maxSteer or 0.35) then abortPull('hard_steer') end
                end
                if bad and pull then abortPull('bad_inputs') end

                if not pull then
                    -- Arm: near-stop, strong throttle, stock (if required), cooldown ok.
                    local gapOk = (GetGameTimer() - lastSampleAt) >= (C.minRunGapMs or 1500)
                    if gapOk and kmh <= (C.startKmh or 2.0) and thr >= (C.startThrottle or 0.95)
                       and not bad and (not C.requireStock or isStock(veh)) then
                        pull = {
                            veh = veh, hash = hash, timing = false, started = false,
                            startTime = nil, midTime = nil, endTime = nil,
                            startCoords = GetEntityCoords(veh),
                            liftMs = 0, lastT = now, lastV = kmh,
                        }
                        dbg('armed ' .. modelOf(veh))
                    end
                else
                    local dtMs = math.max(0, (now - pull.lastT) * 1000.0)
                    -- Throttle-lift tolerance
                    if thr < (C.minThrottle or 0.90) then
                        pull.liftMs = pull.liftMs + dtMs
                        if pull.liftMs > (C.maxLiftMs or 120) then abortPull('throttle_lift') end
                    else
                        pull.liftMs = 0
                    end

                    if pull then
                        local lastV, lastT = pull.lastV, pull.lastT
                        if not pull.started then
                            if lastV < (C.startKmh or 2.0) and kmh >= (C.startKmh or 2.0) then
                                pull.startTime = interpCrossTime(lastT, lastV, now, kmh, C.startKmh or 2.0)
                                pull.started, pull.timing = true, true
                            end
                        else
                            if not pull.midTime and lastV < (C.midKmh or 60.0) and kmh >= (C.midKmh or 60.0) then
                                pull.midTime = interpCrossTime(lastT, lastV, now, kmh, C.midKmh or 60.0)
                            end
                            if lastV < (C.endKmh or 100.0) and kmh >= (C.endKmh or 100.0) then
                                pull.endTime = interpCrossTime(lastT, lastV, now, kmh, C.endKmh or 100.0)
                                -- slope guard
                                local ec, sc = GetEntityCoords(veh), pull.startCoords
                                local dx, dy, dz = ec.x - sc.x, ec.y - sc.y, ec.z - sc.z
                                local dist2d = math.sqrt(dx * dx + dy * dy)
                                local grade = math.abs(dz) / math.max(dist2d, 1.0)
                                if grade > (C.maxGrade or 0.030) then
                                    abortPull('slope')
                                else
                                    local t100 = pull.endTime - pull.startTime
                                    if t100 < (C.minT100 or 1.2) or t100 > (C.maxT100 or 40.0) then
                                        abortPull('implausible_time')
                                    else
                                        dbg(('%s t100 = %.3fs'):format(modelOf(veh), t100))
                                        report(veh, t100, nil)
                                        lastSampleAt = GetGameTimer()
                                        pull = nil
                                    end
                                end
                            end
                        end
                        if pull then pull.lastT, pull.lastV = now, kmh end
                    end
                end
            end
        end
        Wait(sleep)
    end
end)

-- ── Admin bench (/racebench) ─────────────────────────────────────────────────
-- Spawns every car model briefly OFF-MAP, reads GetVehicleEstimatedMaxSpeed (the
-- handling-derived top speed — available the instant the model streams in, no
-- driving needed), and reports it as a top-speed sample. This gives a genuine
-- top-speed-based tier to cars that have NO data anywhere (stock GTA cars etc.),
-- so /racecalall's "awaiting live pull" list stops being blank. Accel (t100) still
-- only comes from a real driven pull — the bench can't fake a launch — but a real
-- top speed alone already yields a valid tier via blendScore(top-only).
local benchRunning = false

RegisterNetEvent('hk-race:carcal:bench', function(hashes)
    if benchRunning then
        TriggerEvent('chat:addMessage', { args = { '^3[racebench]', 'already running…' } })
        return
    end
    if type(hashes) ~= 'table' or #hashes == 0 then return end
    benchRunning = true

    CreateThread(function()
        local BENCH = vector3(1600.0, 6500.0, 800.0)   -- empty airspace, far from players
        local done, ok, fail = 0, 0, 0
        local total = #hashes

        TriggerEvent('chat:addMessage',
            { args = { '^5[racebench]', ('benching %d models — reading top speeds…'):format(total) } })

        for _, hash in ipairs(hashes) do
            hash = math.floor(tonumber(hash) or 0) & 0xFFFFFFFF
            if hash ~= 0 and IsModelInCdimage(hash) and IsModelAVehicle(hash) then
                RequestModel(hash)
                local t = 0
                while not HasModelLoaded(hash) and t < 3000 do Wait(50); t = t + 50 end
                if HasModelLoaded(hash) then
                    local veh = CreateVehicle(hash, BENCH.x, BENCH.y, BENCH.z, 0.0, false, false)
                    if veh and veh ~= 0 and DoesEntityExist(veh) then
                        SetEntityCoordsNoOffset(veh, BENCH.x, BENCH.y, BENCH.z, false, false, false)
                        FreezeEntityPosition(veh, true)
                        SetEntityCollision(veh, false, false)
                        SetEntityVisible(veh, false, false)
                        -- Let the handling settle a frame or two so the native reads true.
                        Wait(60)
                        local est = GetVehicleEstimatedMaxSpeed(veh) or 0.0   -- m/s
                        local kmh = est * 3.6
                        if kmh >= 40.0 and kmh <= 550.0 then
                            report(veh, nil, kmh)   -- top-only sample → server folds/persists
                            ok = ok + 1
                        else
                            fail = fail + 1
                        end
                        DeleteEntity(veh)
                    else
                        fail = fail + 1
                    end
                    SetModelAsNoLongerNeeded(hash)
                else
                    fail = fail + 1
                end
            else
                fail = fail + 1
            end
            done = done + 1
            if done % 20 == 0 then
                TriggerEvent('chat:addMessage',
                    { args = { '^5[racebench]', ('%d / %d…'):format(done, total) } })
            end
            Wait(30)   -- yield between cars; keeps the frame healthy
        end

        benchRunning = false
        local msg = ('done — %d top speeds captured, %d skipped (of %d). Tiers refreshed.')
            :format(ok, fail, total)
        TriggerEvent('chat:addMessage', { args = { '^2[racebench]', msg } })
        TriggerServerEvent('hk-race:carcal:benchDone')
    end)
end)

print('[hk-carcal] loaded — auto-calibration watching for clean standing-start pulls')
