-----------------------------------------------------------------
-- hk-handling :: client/autocal.lua
-- [AUTO-CAL] Passive background acceleration telemetry — ONE-SHOT from neutral.
--
-- Watches NORMAL driving. The FIRST time a player does a CLEAN standing-start
-- full-throttle pull in a model that has a /setspeed target but NO factor yet
-- (still neutral), the pull it sees IS a clean baseline — so it computes the
-- per-gear factor in ONE shot (factor = neutralTime / targetTime, via the shared
-- HK.speedCalComputeFromNeutral) and LOCKS it. A model that already has a factor
-- is never captured again, so there is no feedback loop and nothing can run away.
-- (The old version nudged measured/target every run, but the measurement already
--  included the factor, so it compounded on itself — that whole loop is gone.)
--
-- This writes a SHARED, per-MODEL DB row, so capture is PARANOID — any of these
-- abort the in-progress run (no write): not fully stock, handbrake, brake, hard
-- steering, wheels off ground, collision, throttle drop, or didn't start from rest.
--
-- Reuses the gearbox helpers via HK.speedCalPack / HK.speedCalComputeFromNeutral.
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
local function isExpert() return gearboxMode() == 'expert' end

-- capture state (single in-progress pull)
local cap = nil          -- { tStart, splits={[kmh]=sec}, hash } or nil
local lastWriteAt = 0    -- gametime of last accepted capture (MinRunGapMs cooldown)

local SPLITS = { 60, 100, 160, 200 }   -- checkpoints we capture (km/h)

-- Fully stock = no engine/brake/transmission mod fitted and no turbo toggle.
local function isStock(veh)
    if GetVehicleMod(veh, 11) >= 0 then return false end   -- engine
    if GetVehicleMod(veh, 12) >= 0 then return false end   -- brakes
    if GetVehicleMod(veh, 13) >= 0 then return false end   -- transmission
    if IsToggleModOn(veh, 18) then return false end        -- turbo
    return true
end

local function resetCap() cap = nil end
-- APPLY_PLACEHOLDER

-- ONE-SHOT from a NEUTRAL passive pull. Auto-cal ONLY captures a model whose factor
-- is still NEUTRAL (speedCalC unset) — so the pull it just watched WAS the true baseline
-- (no factor applied). It then computes factor = neutralTime/targetTime per gear in one
-- shot and LOCKS it. A model that already has a factor is skipped forever (the gate in
-- the watch loop), so there is no feedback loop and nothing can run away.
local function applyCapture(veh, hash, splits, gearSeg)
    if not isExpert() then return end
    local SC = Config.Gearbox and Config.Gearbox.SpeedCal
    local AC = SC and SC.AutoCal
    if not (SC and AC) then return end

    local m = HK.manualModels and HK.manualModels[hash]
    if not (m and m.speedCal) then return end   -- no target set -> nothing to compute toward
    if m.speedCalC then                          -- already learned -> never touch again
        if AC.Debug then print('[hk-autocal] model already has a factor — skip') end
        return
    end

    -- parse targets "kmh,s;" -> {[kmh]=s}
    local tgt = {}
    for k, t in tostring(m.speedCal):gmatch('(%d+%.?%d*)%s*,%s*(%d+%.?%d*)') do
        local kk = math.floor(tonumber(k) or 0); if kk > 0 then tgt[kk] = tonumber(t) end
    end

    if not HK.speedCalComputeFromNeutral then return end
    local f, report = HK.speedCalComputeFromNeutral(tgt, gearSeg, {
        fMin = SC.FactorMin or 0.40, fMax = SC.FactorMax or 1.40,
        tol  = AC.ConvergeTolSec or 0.40,
    })
    if not f then
        if AC.Debug then print('[hk-autocal] ' .. tostring(report) .. ' — discard') end
        return
    end

    local packed = HK.speedCalPack(f)
    local name = GetLabelText(GetDisplayNameFromVehicleModel(GetEntityModel(veh)))
    if not name or name == '' or name == 'NULL' then name = GetDisplayNameFromVehicleModel(GetEntityModel(veh)) end
    TriggerServerEvent('hk-handling:gearbox:setSpeedModel', hash, '', name, m.speedCal, packed)
    if AC.Debug then
        print(('[hk-autocal] %s LOCKED (one-shot neutral) -> gears %.2f/%.2f/%.2f/%.2f  [%s]')
            :format(name or hash, f[1], f[2], f[3], f[4], table.concat(report, ' ')))
    end
end


-----------------------------------------------------------------
-- WATCH LOOP — detect a clean standing-start WOT pull and capture its splits.
-----------------------------------------------------------------
CreateThread(function()
    while true do
        local sleep = 250
        local SC = Config.Gearbox and Config.Gearbox.SpeedCal
        local AC = SC and SC.AutoCal
        if SC and SC.Enabled and AC and AC.Enabled and isExpert() then
            local veh = vl_getDrivenVehicle()
            if veh then
                sleep = 0
                local hash = GetEntityModel(veh) & 0xFFFFFFFF
                local kmh  = GetEntitySpeed(veh) * 3.6
                local thr  = GetControlNormal(0, 71)
                local now  = GetGameTimer()

                -- abort conditions (kill any in-progress capture)
                local bad = IsControlPressed(0, 76)                       -- handbrake
                    or (GetControlNormal(0, 72) > 0.1)                    -- brake input
                    or (math.abs(GetControlNormal(0, 59) - 0.5) * 2 > (AC.MaxSteer or 0.35))  -- hard steer
                    or (not IsVehicleOnAllWheels(veh))                    -- airborne/wheelie
                    or HasEntityCollidedWithAnything(veh)                 -- hit something

                if cap and cap.hash ~= hash then resetCap() end           -- changed vehicle

                if not cap then
                    -- ARM a capture only from a near-dead stop, fully stock, cooldown elapsed,
                    -- AND only for a model that has a target but NO factor yet (still neutral —
                    -- so the pull we watch is a clean baseline). A learned model is left alone.
                    local m = HK.manualModels and HK.manualModels[hash]
                    local neutralUnlearned = m and m.speedCal and (not m.speedCalC)
                    if neutralUnlearned
                       and kmh <= (AC.StartKmh or 2.0) and thr >= (AC.MinThrottle or 0.90)
                       and (now - lastWriteAt) >= (AC.MinRunGapMs or 4000)
                       and (not AC.RequireStock or isStock(veh)) and not bad then
                        -- resolve the highest checkpoint this model actually has a target for
                        -- (slow cars top out below 200, so completing at 200 would never fire).
                        local topCp = 0
                        for k in tostring(m.speedCal):gmatch('(%d+)%s*,') do
                            local kk = tonumber(k) or 0
                            for _, s in ipairs(SPLITS) do if s == kk and kk > topCp then topCp = kk end end
                        end
                        if topCp == 0 then topCp = 200 end       -- no parseable target -> default
                        cap = { tStart = now, splits = {}, gearSeg = {}, hash = hash, topCp = topCp }
                    end
                else
                    -- in a capture: validate continuously
                    if bad or thr < (AC.MinThrottle or 0.90) then
                        resetCap()                                        -- not a clean WOT pull
                    else
                        local elapsed = (now - cap.tStart) / 1000.0
                        for _, target in ipairs(SPLITS) do
                            if not cap.splits[target] and kmh >= target then
                                cap.splits[target] = elapsed
                            end
                        end
                        -- PER-GEAR segment tracking (km/h + seconds covered in each gear).
                        local cg = GetVehicleCurrentGear(veh)
                        if cg < 1 then cg = 1 elseif cg > 4 then cg = 4 end
                        local sg = cap.gearSeg[cg]
                        if not sg then
                            cap.gearSeg[cg] = { vIn = kmh, vOut = kmh, tIn = elapsed, tOut = elapsed }
                        else
                            sg.vOut = kmh; sg.tOut = elapsed
                        end
                        -- complete once the model's HIGHEST target checkpoint is reached
                        -- (not hardcoded 200 — many cars can't physically get there).
                        if cap.splits[cap.topCp] then
                            applyCapture(veh, hash, cap.splits, cap.gearSeg)
                            lastWriteAt = now
                            resetCap()
                        end
                    end
                end
            else
                resetCap()
            end
        end
        Wait(sleep)
    end
end)

print('[hk-autocal] loaded — passive acceleration calibration watching for clean WOT pulls')
