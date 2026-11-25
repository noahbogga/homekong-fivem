-----------------------------------------------------------------
-- hk-handling :: client/rpmdebug.lua
-- On-screen RPM readout for tuning the 0-1 thresholds.
--
-- SELF-CONTAINED: reads the vehicle + rpm directly from natives, so it does
-- NOT depend on the main loop, Config.Enabled, or manual mode. Works in any
-- car you're driving.
--
-- GTA only gives us GetVehicleCurrentRpm() as a 0.00-1.00 float — there is
-- NO native that returns true engine RPM. So we show:
--   RAW   = the 0.00-1.00 value (this is what EVERY hk-handling threshold uses)
--   RPM   = RAW * Config.RpmDebug.Redline  (derived, cosmetic 4-5 digit number)
--   REV%  = (RAW - idle) / (1 - idle)      (approx real rev fraction; idle ~0.2)
--
-- Toggle in-game with /rpmdebug (Config.RpmDebug.Command).
-----------------------------------------------------------------

local cfg     = Config.RpmDebug or {}
local enabled = cfg.ShowByDefault ~= false   -- live show/hide state, seeded from config

local function drawText(x, y, text, scale, r, g, b)
    SetTextFont(4)
    SetTextScale(scale, scale)
    SetTextColour(r, g, b, 255)
    SetTextOutline()
    SetTextDropShadow(0, 0, 0, 0, 255)
    BeginTextCommandDisplayText('STRING')
    AddTextComponentSubstringPlayerName(text)
    EndTextCommandDisplayText(x, y)
end

CreateThread(function()
    if not cfg.Enabled then return end

    local redline = cfg.Redline or 8000
    local idle    = cfg.IdleApprox or 0.20
    local x       = cfg.PosX or 0.015
    local y       = cfg.PosY or 0.40
    local scale   = cfg.Scale or 0.45
    local lineH   = 0.028

    while true do
        if enabled then
            local ped = PlayerPedId()
            local veh = GetVehiclePedIsIn(ped, false)
            if veh ~= 0 and GetPedInVehicleSeat(veh, -1) == ped then
                local raw  = GetVehicleCurrentRpm(veh)
                local gear = GetVehicleCurrentGear(veh)
                local kmh  = GetEntitySpeed(veh) * 3.6
                local rpm  = math.floor(raw * redline + 0.5)
                local revPct = (raw - idle) / (1.0 - idle)
                if revPct < 0 then revPct = 0 end

                local r = math.floor(120 + raw * 135)
                local g = math.floor(255 - raw * 180)

                drawText(x, y,             '~y~RPM DEBUG',                          scale + 0.05, 255, 255, 0)
                drawText(x, y + lineH,     ('RAW (0-1): %.3f'):format(raw),         scale, r, g, 60)
                drawText(x, y + lineH * 2, ('ENGINE RPM: %d'):format(rpm),          scale, r, g, 60)
                drawText(x, y + lineH * 3, ('REAL REV%%: %d%%'):format(math.floor(revPct * 100 + 0.5)), scale, 200, 200, 255)
                drawText(x, y + lineH * 4, ('GEAR: %d   %d km/h'):format(gear, math.floor(kmh + 0.5)), scale, 200, 200, 200)
            end
        end
        Wait(0)
    end
end)

-- Toggle command: /rpmdebug
RegisterCommand(cfg.Command or 'rpmdebug', function()
    enabled = not enabled
    print(('[hk-rpmdebug] overlay %s'):format(enabled and 'ON' or 'OFF'))
end, false)

print(('[hk-rpmdebug] loaded. command=/%s  show=%s'):format(cfg.Command or 'rpmdebug', tostring(enabled)))

-----------------------------------------------------------------
-- THROTTLE MODEL OVERLAY (folded in here so it lives in an EXISTING client
-- file — a new file wouldn't reach already-connected clients without a full
-- resource re-download. This reloads on a plain `restart hk-handling`.)
--
-- Shows the device-agnostic effective-throttle model (HK.ThrottleModel_Tick):
--   RAW    = state.throttle     (keyboard W is only ever 0 or 1)
--   EFF    = state.effThrottle  (the synthesized/smoothed pedal features read)
--   RPMf   = state.rpmFactor    (low-rpm aggression scale)
--   DEVICE = KEYBOARD (synth) or ANALOG (passthrough)
-- Toggle with /throttledbg.
-----------------------------------------------------------------
-- Live show/hide. Persistent while on: every value section renders each frame (stale sections are
-- dimmed, not hidden — the user wants the numbers to stay on screen). /handlingdbg toggles it;
-- /throttledbg kept as an alias. Left + right columns only — center stays clear.
local hdbgOn = (Config.RpmDebug and Config.RpmDebug.HandlingDbgDefault) == true
HK = HK or {}
HK.hdbgOn = hdbgOn   -- mirror to HK so gearbox.lua can cheaply gate its per-frame debug snapshot
-- Seed the shared statebag so hk-speedo / hk-hud start in the right visibility state
-- even if HandlingDbgDefault is on at boot (deferred a frame so LocalPlayer.state exists).
CreateThread(function() LocalPlayer.state:set('hk_handlingdbg', hdbgOn, true) end)

local function tdbgBar(v, n)
    v = v or 0.0
    if v < 0 then v = 0 elseif v > 1 then v = 1 end
    local filled = math.floor(v * n + 0.5)
    return ('[%s%s]'):format(string.rep('|', filled), string.rep('.', n - filled))
end

-- Render a cell array into a bar string, coalescing same-colour runs into one tag (keeps the string
-- short enough for the text native). Tokens: '.'=dim dot, and coloured '|' markers r/w/g/b/o.
local BAR_COL = { ['.'] = '~c~', r = '~r~', w = '~w~', g = '~g~', b = '~b~', o = '~o~' }
local function renderCells(cells)
    local out, last = {}, nil
    for i = 1, #cells do
        local c = cells[i]
        if c ~= last then out[#out+1] = BAR_COL[c] or '~w~'; last = c end
        out[#out+1] = (c == '.') and '.' or '|'
    end
    out[#out+1] = '~s~'
    return table.concat(out)
end

-- CENTERED -1..1 bar for the steering OUTPUT. Fixed WHITE '|' in the middle (the zero reference).
-- Right deflection (v>0) fills BLUE '|' outward from the centre; left deflection (v<0) fills ORANGE.
-- As the wheel returns to centre the coloured fill shrinks back toward the middle '|' — so you can
-- watch it recentre. n = cells PER SIDE.
local function centerBar(v, n)
    v = v or 0.0
    if v < -1 then v = -1 elseif v > 1 then v = 1 end
    local filled = math.floor(math.abs(v) * n + 0.5)
    local cells = {}
    for i = 1, n do cells[i] = '.' end            -- left group: index 1 = outer edge .. n = near centre
    cells[n + 1] = 'w'                             -- centre marker
    for i = 1, n do cells[n + 1 + i] = '.' end     -- right group: index 1 = near centre .. n = outer edge
    if v >= 0 then
        for i = 1, filled do cells[n + 1 + i] = 'b' end        -- blue, centre -> right edge
    else
        for i = 1, filled do cells[n - i + 1] = 'o' end        -- orange, centre -> left edge
    end
    return '[' .. renderCells(cells) .. ']'
end

-- LOCK-ANGLE multiplier bar. Fixed RED '|' in the middle = native lock (1.0). ABOVE native (boost, up
-- to +0.25 at low speed) fills GREEN '|' OUTWARD from the centre. BELOW native (tighter lock, down to
-- ~0.60 at speed) fills WHITE '|' INWARD from BOTH outer edges. So a boosted parking-lot wheel spreads
-- green out of the middle; a tight high-speed wheel closes '|' in from the sides. n = cells PER SIDE.
local LOCK_BOOST_RANGE = 0.25    -- 1.0 .. 1.25 maps green 0 -> full
local LOCK_TIGHT_RANGE = 0.40    -- 1.0 .. 0.60 maps edge-close 0 -> full
local function lockBar(mult, n)
    mult = mult or 1.0
    local cells = {}
    for i = 1, n do cells[i] = '.' end
    cells[n + 1] = 'r'                             -- red centre = native
    for i = 1, n do cells[n + 1 + i] = '.' end
    if mult >= 1.0 then
        local g = math.floor(math.min((mult - 1.0) / LOCK_BOOST_RANGE, 1.0) * n + 0.5)
        for i = 1, g do
            cells[n - i + 1]     = 'g'             -- green out to the left of centre
            cells[n + 1 + i]     = 'g'             -- green out to the right of centre
        end
    else
        local t = math.floor(math.min((1.0 - mult) / LOCK_TIGHT_RANGE, 1.0) * n + 0.5)
        for i = 1, t do
            cells[i]                     = 'w'     -- white '|' closing in from the left edge
            cells[n + 1 + (n - i + 1)]   = 'w'     -- white '|' closing in from the right edge
        end
    end
    return '[' .. renderCells(cells) .. ']'
end

-- Colour tag for a 0..1 engagement factor: green when engaged, dim grey when idle.
local function fcol(v) return (v or 0.0) > 0.02 and '~g~' or '~c~' end
-- Freshness: a HK.dbg* table with an .at timestamp is "live" if written in the last 400 ms. Stale
-- sections still draw (persistence) but get a dim '~c~(stale)~s~' tag so you know the tick stopped.
local function fresh(tbl) return tbl and tbl.at and (GetGameTimer() - tbl.at) < 400 end
local function staleTag(tbl) return fresh(tbl) and '' or ' ~c~(stale)~s~' end

-- A drivetrain-tool token that ALWAYS shows, so you can see the whole arsenal at a glance:
--   config disabled  -> "~r~Name off~s~"      (the option exists but is turned OFF)
--   armed, not firing -> "~c~Name 0.00~s~"     (waiting — will engage when its gate trips)
--   firing            -> "~g~Name 0.42~s~"     (live engagement value)
-- `enabled` is the tool's config .Enabled flag (nil treated as ON — most default true).
local function tok(name, val, enabled)
    if enabled == false then return ('~r~%s off~s~'):format(name) end
    val = val or 0.0
    local col = (val > 0.02) and '~g~' or '~c~'
    return ('%s%s %.2f~s~'):format(col, name, val)
end
-- A boolean-state tool token (on/off tools with no 0..1 factor).
local function tokB(name, on, enabled)
    if enabled == false then return ('~r~%s off~s~'):format(name) end
    return on and ('~g~%s ON~s~'):format(name) or ('~c~%s --~s~'):format(name)
end
-- Safe config reach: Config.Drivetrain.<cls>.<tool>.Enabled (nil-safe → returns nil = treat as ON).
local function cfgEnabled(cls, tool)
    local c = Config and Config.Drivetrain
    c = c and c[cls]; c = c and c[tool]
    if c == nil then return nil end
    return c.Enabled
end

-- Layout constants + section renderers. Declared before the render thread so it can close over them.
local LX, RX = 0.008, 0.760
local sc      = 0.36
local lh      = 0.0225

-- forward declares (Lua upvalue capture for the thread + cross-references between sections)
local drawPedalSection, drawSteerSection, drawReverseSection
local drawDriveSection, drawGearSection, drawDriftSection, drawEngineSection

-- TC-feel diagnostics state (display-only, in this file):
--   tqEma     = rolling avg of HK.torqueMultApplied — the PERF-NEUTRALITY tell. The ramped dip
--               and the area-fair kick should average ~1.00 over time; a persistent < 1.00 while
--               cruising steady means feel-shaping is leaking real torque (perf NOT neutral).
--   kickHold* = latch the last upshift kick so it stays readable for ~1.2s after the pulse fades.
local tqEma = 1.0
local kickHoldUntil, kickHoldAmp, kickHoldGated, kickHoldThr = 0, 0.0, false, nil

-- ============ LEFT: PEDAL MODELS ============
drawPedalSection = function(x, y, s)
    local raw  = s.throttle or 0.0
    local eff  = s.effThrottle or 0.0
    local rpmf = s.rpmFactor or 1.0
    local analog = s.throttleIsAnalog == true
    local er = analog and 120 or math.floor(255 - eff * 120)
    local eg = math.floor(120 + eff * 135)
    local rev = s.throttleReversing == true
    local pmOn = HK.pedalModelOn and '~g~ON~s~' or '~r~OFF~s~'
    drawText(x, y, ('~b~PEDALS~s~  model %s  %s  %s'):format(pmOn,
        analog and '~g~ANALOG~s~' or '~y~KBD-synth~s~', rev and '~o~[REV]~s~' or ''), sc, 200, 200, 255)
    y = y + lh
    drawText(x, y, ('GAS raw %.2f %s'):format(raw, tdbgBar(raw, 16)), sc, 200, 200, 200); y = y + lh
    drawText(x, y, ('GAS eff %.2f %s'):format(eff, tdbgBar(eff, 16)), sc, er, eg, 60); y = y + lh
    drawText(x, y, ('RPMf    %.2f %s'):format(rpmf, tdbgBar(rpmf, 16)), sc, 200, 200, 255); y = y + lh
    local braw = s.brake or 0.0
    local beff = s.effBrake or 0.0
    local banalog = s.brakeIsAnalog == true
    local bfm = HK.brakeForceMult or 1.0
    drawText(x, y, ('BRK raw %.2f %s'):format(braw, tdbgBar(braw, 16)), sc, 200, 180, 180); y = y + lh
    drawText(x, y, ('BRK eff %.2f %s %s'):format(beff, tdbgBar(beff, 16), banalog and '~g~A~s~' or ''),
        sc, math.floor(255 - beff*80), math.floor(120 + beff*40), 120); y = y + lh
    drawText(x, y, ('BRKforce x%.2f   TAPhold %.2f'):format(bfm, HK.tmCadence or 0.0), sc, 200, 170, 160); y = y + lh
    -- BRAKE BUFF (Config.BrakeBoost): reward layer. Shows total mult + which parts contribute + speed curve.
    do
        local bb = HK.dbgBrakeBuff
        if bb then
            local ptTxt = (bb.pt == 3 or bb.pt == 4) and 'DCT' or ((bb.pt == 1 or bb.pt == 5) and 'MAN' or '-')
            local bmTxt = (bb.bmLvl ~= nil and bb.bmLvl >= 0) and ('L'..(bb.bmLvl + 1)) or '-'
            drawText(x, y, ('BUFF x%.2f  %s%s box:%s brk:%s  spd+%.2f@%dkmh'):format(
                bb.mult or 1.0,
                bb.chip and '~g~CHIP~s~ ' or '',
                bb.antilag and '~g~ALAG~s~ ' or '',
                ptTxt, bmTxt, bb.spd or 0.0, math.floor(bb.kmh or 0.0)),
                sc, 170, 210, 170); y = y + lh
        else
            drawText(x, y, 'BUFF x1.00 (off/none)', sc, 130, 140, 130); y = y + lh
        end
    end
    -- DOWNFORCE (Config.Downforce): high-speed plant. total force (N), front/rear split,
    -- anti-lift add, cornering load, tier. Only populated above MinSpeedKmh + out of drift.
    do
        local df = HK.dbgDownforce
        if df then
            local bc = HK.dbgBiasCenter
            local bcTxt = bc and (' ~c~bias %.3f→%.3f~s~'):format(bc.native or 0.0, bc.applied or 0.0) or ''
            local bumpTxt = df.bump and ' ~y~BUMP~s~' or ''
            drawText(x, y, ('DF grip x%.3f (aero %.2f)  grav x%.3f  t%.2f  tier x%.2f%s%s'):format(
                df.grip or 1.0, df.aero or 0.0, df.mult or 1.0, df.t or 0.0, df.tier or 0.0, bumpTxt, bcTxt),
                sc, 150, 200, 230); y = y + lh
        else
            drawText(x, y, 'DF (below speed / drift / airborne / off)', sc, 120, 140, 150); y = y + lh
        end
    end
    -- ESC (Config.ESC): stability control. Shows intervention factor, yaw vs threshold,
    -- and the live torque cut. Only lit when ESC is actually catching a slide.
    do
        local esc = HK.dbgESC
        if esc then
            if esc.on then
                drawText(x, y, ('ESC ~r~ON~s~ f%.2f  yaw %.2f/%.2f  cut x%.2f'):format(
                    esc.f or 0.0, esc.yaw or 0.0, esc.thr or 0.0, esc.cut or 1.0),
                    sc, 255, 120, 120); y = y + lh
            else
                drawText(x, y, ('ESC idle  yaw %.2f/%.2f'):format(esc.yaw or 0.0, esc.thr or 0.0),
                    sc, 120, 160, 140); y = y + lh
            end
        end
    end
    -- DRS / Active Aero (Config.DRS): open (low drag) / brake (aero-brake) / off.
    do
        local drs = HK.dbgDRS
        if drs then
            local m = drs.mode or 'off'
            if m == 'open' then
                drawText(x, y, ('DRS ~g~OPEN~s~  %.0fkm/h  steer %.1f°'):format(drs.kmh or 0.0, drs.steer or 0.0),
                    sc, 140, 230, 140); y = y + lh
            elseif m == 'brake' then
                drawText(x, y, ('DRS ~b~AERO-BRAKE~s~  %.0fkm/h'):format(drs.kmh or 0.0),
                    sc, 140, 180, 240); y = y + lh
            else
                drawText(x, y, ('DRS %s  %.0fkm/h'):format(m, drs.kmh or 0.0), sc, 130, 150, 160); y = y + lh
            end
        end
    end
    -- Wheelie [F1] (launch-driven pitch TORQUE, muscle only). Always shown on a muscle car:
    -- lit orange while lifting, dim grey while waiting — with the gate reason so you can see
    -- exactly what it's waiting for (not-muscle / wait-launch / wait-N->1 / no-lift).
    do
        local wl = HK.dbgWheelie
        if wl then
            local bounce = (wl.bMax and wl.bMax > 0) and (('  b%d/%d'):format(wl.bN or 0, wl.bMax or 0)) or ''
            -- FRONT-OFF tag (2026-08-14). It flashes by mid-launch, so PEAK-HOLD it: the moment the ACTUAL
            -- front wheels go up, latch the timer + the peak pitch reached, and keep showing it for 4s so
            -- you can read AFTER the launch whether the fronts actually lifted (green FRONT-OFF held) or
            -- never left the ground (grey grounded). live = up right now; held = went up in the last 4s.
            local nowt = GetGameTimer()
            if HK.wheelieFrontOff == true then
                HK.dbgFrontOffAt = nowt
                if (wl.pitch or 0.0) > (HK.dbgFrontOffPk or 0.0) then HK.dbgFrontOffPk = wl.pitch or 0.0 end
            end
            local foLive = (HK.wheelieFrontOff == true)
            local foHeld = HK.dbgFrontOffAt and (nowt - HK.dbgFrontOffAt) < 4000
            local foTag
            if foLive then
                foTag = '~g~FRONT-OFF live~s~'
            elseif foHeld then
                foTag = ('~y~front-off %.0f°(%.1fs)~s~'):format(HK.dbgFrontOffPk or 0.0, (nowt - HK.dbgFrontOffAt) / 1000.0)
            else
                foTag = '~c~grounded~s~'
            end
            if not foLive and (wl.f or 0.0) <= 0.01 then HK.dbgFrontOffPk = 0.0 end   -- rearm for next launch once settled
            if (wl.f or 0.0) > 0.01 then
                -- REAR-THRUST reramp line: thrust = torque×grip drives the lift; spin/grip show the rear
                -- hook; RPM shows the redline pin while lifted (PIN when held, else off).
                local rpmTag = (wl.spinRpm and wl.spinRpm > 0.01) and (('rpmPIN %.2f'):format(wl.spinRpm)) or 'rpm off'
                drawText(x, y, ('WHEELIE ~o~LIFT~s~ f%.2f  pitch %.1f°  shoot %.2f(x%.2f)  eng %.2f hook %.2f spin %.1f  %s  %s%s  %s'):format(
                    wl.f or 0.0, wl.pitch or 0.0, wl.shoot or 0.0, wl.tScale or 0.0,
                    wl.energy or 0.0, wl.hook or 0.0, wl.spin or 0.0, foTag, rpmTag,
                    bounce, wl.man and 'MAN' or 'AUTO'), sc, 255, 200, 120); y = y + lh
            else
                drawText(x, y, ('WHEELIE idle [%s]  pitch %.1f°  %s  shoot %.2f  eng %.2f spin %.1f  ws%s  trig %s%s  %s'):format(
                    wl.gate or '?', wl.pitch or 0.0, foTag, wl.shoot or 0.0, wl.energy or 0.0, wl.spin or 0.0,
                    wl.wsp and 'Y' or 'n', wl.trig and 'Y' or 'n', bounce,
                    wl.man == nil and '' or (wl.man and 'MAN' or 'AUTO')),
                    sc, 140, 140, 150); y = y + lh
                -- PATH B SPIN PROBE (2026-08-14 REBASE): Path B now fires off the REAL drift W+S
                -- wheelspin release, not a brake-load timer. spinAct = the W+S wheelspin owns the frame
                -- (green while you hold driftkey+W+S on an eligible car); relMs = ms since the spin ended
                -- (green when fresh = a Path B fire just triggered). src = which path armed the window.
                if wl.spinAct ~= nil or wl.spinRelMs ~= nil then
                    local actCol = wl.spinAct and '~g~Y~s~' or '~r~n~s~'
                    local relStr = wl.spinRelMs and (('%.0f'):format(wl.spinRelMs)) or '-'
                    local relCol = (wl.spinRelMs and wl.spinRelMs <= 120) and '~g~' or '~y~'
                    drawText(x, y, ('  PATHB  spin %s  relMs %s%s~s~  brk %s  src %s'):format(
                        actCol, relCol, relStr,
                        wl.brk and '~g~Y~s~' or '~r~n~s~', wl.src or '-'),
                        sc, 180, 180, 210); y = y + lh
                end
            end
            -- RAW FRONT-OFF PROBE (2026-08-14): the actual native returns while lifting, so we can see
            -- what "air" reads on the front wheels (fl/fr material) vs onAll/inAir. Read these mid-wheelie.
            local fo = HK.dbgFOraw
            if fo then
                drawText(x, y, ('  FOraw  onAll %s  inAir %s  fl %s  fr %s'):format(
                    fo.onAll and 'Y' or 'n', fo.inAir and 'Y' or 'n',
                    tostring(fo.fl), tostring(fo.fr)), sc, 150, 200, 200); y = y + lh
            end
        end
        local hl = HK.dbgHeadlift
        if hl then
            drawText(x, y, ('HEADLIFT f%.2f  pitch %.1f°  mag %.0fN%s'):format(hl.f or 0.0, hl.pitch or 0.0, hl.mag or 0.0,
                hl.launch and ' ~g~LAUNCH~s~' or ''), sc, 230, 190, 140); y = y + lh
        end
        -- ROTATION PROBE (2026-08-26 v2 — FROZEN PEAK). Shows the WORST rotation of the last launch,
        -- held 4s so it's readable. Names the axis in plain words + WHO was applying force at that peak.
        --   pitch+ = NOSE up (what we want) | pitch- = REAR up | roll = SIDEWAYS | yaw = FLAT SPIN (rear out)
        local H = HK.dbgRotHold
        if H and ((H.pPk or 0) > 0.05 or (H.rPk or 0) > 0.05 or (H.yPk or 0) > 0.05) then
            -- EACH axis peak shown INDEPENDENTLY so a small roll can't hide under a big nose-up pitch
            -- (the exact "ROT says nose-up but it lifts sideways" case). Roll is coloured RED when it's
            -- big enough to be the felt problem (>0.2 rad/s) so it jumps out.
            local prS, rrS, yrS = H.prS or 0.0, H.rrS or 0.0, H.yrS or 0.0
            local pitchWord = prS >= 0 and 'noseUP' or 'REARup'
            local rollBad = (H.rPk or 0) > 0.2
            drawText(x, y, ('ROT-PEAK  pitch %+.2f(%s)   roll %+.2f%s   yaw %+.2f'):format(
                prS, pitchWord,
                rrS, rollBad and ' ~r~<<SIDEWAYS~s~' or '',
                yrS), sc, 255, 210, 120); y = y + lh
            -- WHO was active at the ROLL peak — the sideways culprit line (roll is the reported bug).
            -- 2026-08-14: reads the FIXED snapshot. rwd = worst engagement across ALL RWD tools (who=which),
            -- spin = SpinSoftener specifically (only ungated straight-line yaw writer), lnch = launch active.
            drawText(x, y, ('  @roll-peak %.0fkmh %s: wheelie %.0fN·m  rwd %.2f(%s)  spin %.2f  awd %.2f  fwd %.2f  cut %s'):format(
                H.rKmh or 0.0, H.rLaunch and '~y~LNCH~s~' or 'coast',
                H.rWmag or 0.0, H.rRwd or 0.0, H.rRwdWho or '-', H.rSpin or 0.0,
                H.rAwd or 0.0, H.rFwd or 0.0, H.rCut and '~r~Y~s~' or 'n'),
                sc, 200, 200, 210); y = y + lh
        end
    end
    -- physical keys + limiter
    local rawW = IsRawKeyDown and IsRawKeyDown(87)
    local rawS = IsRawKeyDown and IsRawKeyDown(83)
    local lim = HK.gbLimiterOn and (' ~r~LIM:'..tostring(HK.gbLimiterWhy or '?')..'~s~') or ''
    if HK.burnoutLimiterOn then lim = lim .. ' ~r~G1LIM~s~' end
    drawText(x, y, ('keys W=%s S=%s%s'):format(tostring(rawW), tostring(rawS), lim), sc, 255, 200, 120); y = y + lh
    -- STAGE 1 DIAG: prove burnout.lua is loaded + why the gear-1 limiter isn't firing.
    -- loaded = the module set the flag this frame; g/rpm/thr/air are the exact gate inputs.
    do
        local bd = HK.dbgBurnout
        if bd then
            drawText(x, y, ('G1lim ld=%s g=%d rpm=%.3f thr=%.2f air=%s man=%s spin=%s(%.1f) on=%s'):format(
                tostring(bd.loaded), bd.g or -9, bd.rpm or 0.0, bd.thr or 0.0,
                tostring(bd.air), tostring(bd.man), tostring(bd.spin), bd.slip or 0.0, tostring(bd.on)), sc, 180, 220, 180)
        else
            drawText(x, y, 'G1lim ~r~module NOT loaded (reconnect needed)~s~', sc, 220, 160, 160)
        end
        y = y + lh
        -- REV DIAG: the three-state rev model (gearbox.lua RevAgainstThrottle_Tick). mode =
        -- free (N+brake hard scream) / soft (N no-brake) / load (in-gear+brake loaded) / '-'.
        if bd and bd.frEng ~= nil then
            local fr_g = bd.frEng and 230 or 150
            drawText(x, y, ('REV mode=%s W=%.2f S=%.2f kmh=%.1f rpm=%.3f bounce=%s'):format(
                tostring(bd.frMode or '-'), bd.frThr or 0.0, bd.frBrk or 0.0, bd.frKmh or 0.0,
                bd.frRpm or 0.0, tostring(bd.frBounce)), sc, 140, fr_g, 220)
            y = y + lh
        end
        -- STAGE 2 DIAG: manual wheelspin state machine (phaseN 0=off/1=active/2=slideout/3=converted).
        if bd and bd.boPhaseN ~= nil then
            local active = (bd.boPhaseN == 1 or bd.boPhaseN == 2)
            local col_r = active and 120 or 160
            local col_g = active and 230 or 160
            drawText(x, y, ('BURN phaseN=%s spin=%.2f chg=%.2f slip=%.1f'):format(
                tostring(bd.boPhaseN), bd.boSpin or 0.0, bd.boChg or 0.0, bd.boSlip or 0.0),
                sc, col_r, col_g, 140); y = y + lh
            drawText(x, y, ('  drift=%s W=%.2f kmh=%.1f phase=%s yaw=%.2f scrub=%.1f'):format(
                tostring(bd.boDrift), bd.boThr or 0.0, bd.boKmh or 0.0, tostring(bd.boPhase or '-'),
                bd.boYaw or 0.0, bd.boScrub or 0.0), sc, 200, 200, 140); y = y + lh
        end
    end

    -- LAUNCH TRACTION DIAG: the auto-wheelspin off the line (client/launchtraction.lua).
    do
        local lt = HK.dbgLaunchTr
        if lt then
            local on = (lt.spin or 0.0) > 0.001
            local col_r = on and 230 or 150
            local col_g = on and 200 or 150
            drawText(x, y, ('LAUNCH gate=%s %s%s g=%d kmh=%.1f grip=%.2f over=%.2f stab=%.2f'):format(
                tostring(lt.gate), string.upper(lt.cls or '?'), lt.tcOff and ' ~r~TC-OFF~s~' or '',
                lt.gear or -9, lt.kmh or 0.0, lt.gripThr or 0.0,
                lt.over or 0.0, lt.stab or 0.0), sc, col_r, col_g, 140); y = y + lh
            if on then
                drawText(x, y, ('  spin=%.2f (cmd=%.2f) slip=%.1f revFloor=%.2f'):format(
                    lt.spin or 0.0, lt.spinCmd or 0.0, lt.slip or 0.0, lt.revFloor or 0.0),
                    sc, 240, 190, 120); y = y + lh
            end
        end
        -- WHY line: the per-frame reason code. RED if the feature has ERRORED OFF (the mid-session fault),
        -- YELLOW if the player is ARMED but not firing (fell back to normal GTA), grey otherwise. This is
        -- the "why did the drag just go" answer — falsifiable, on screen every frame.
        local w = HK.dbgLaunchWhy
        local le = HK.dbgLaunchErr
        if HK._launchTrErr and le then
            drawText(x, y, ('  ~r~LAUNCH ERRORED OFF~s~ (x%d) %s'):format(le.n or 1, tostring(le.msg)),
                sc, 240, 90, 90); y = y + lh
        elseif w and w.why then
            local armedNow = w.armed == true
            local cr, cg, cb = 150, 150, 150
            if armedNow and not (w.why:find('FIRING') or w.why:find('gripped')) then cr, cg, cb = 240, 210, 90 end
            drawText(x, y, ('  why=%s%s'):format(w.why, armedNow and ' ~y~[ARMED]~s~' or ''),
                sc, cr, cg, cb); y = y + lh
        end
        -- GRIP-FIELD ARBITER: who currently OWNS the three shared traction-curve fields, and the mults being
        -- written. 'none' (grey) = handed back to native; an owner (green) = that feature won the frame.
        local g = HK.dbgGrip
        if g and g.owner then
            local owned = g.owner ~= 'none'
            drawText(x, y, ('  grip=%s%s p%d  mx=%.2f mn=%.2f lo=%.2f'):format(
                owned and '~g~' or '', g.owner, g.prio or 0,
                g.max or 1.0, g.min or 1.0, g.low or 1.0),
                sc, owned and 150 or 150, owned and 230 or 150, 150); y = y + lh
        end
    end
    return y
end

-- ============ LEFT: STEERING MODEL + RATES ============
drawSteerSection = function(x, y, s)
    local smOn = HK.steerModelOn and '~g~ON~s~' or '~r~OFF~s~'
    local act  = HK._steerModelActive and '~g~synth~s~' or '~y~native~s~'
    local rawA = IsRawKeyDown and IsRawKeyDown(65)
    local rawD = IsRawKeyDown and IsRawKeyDown(68)
    local dsm  = HK.dbgSteerModel
    drawText(x, y, ('~b~STEER~s~  model %s  %s  A=%s D=%s'):format(smOn, act,
        tostring(rawA), tostring(rawD)), sc, 200, 200, 255); y = y + lh
    if dsm then
        local out = dsm.out or 0.0
        drawText(x, y, ('out %s%+.2f~s~ %s'):format(
            (out >= 0) and '~b~' or '~o~', out, centerBar(out, 9)), sc, 200, 200, 255); y = y + lh
        drawText(x, y, ('tgt %+.2f  dir %d'):format(dsm.target or 0.0, math.floor(dsm.dir or 0)),
            sc, 180, 190, 220); y = y + lh
        -- RATE (the bit the user asked for): speed multiplier + effective sweep times AT THIS SPEED.
        local kmh = math.floor(s.speedKmh or 0.0)
        drawText(x, y, ('rate x%.2f @ %d km/h  cad %.2f'):format(dsm.spdMult or 1.0, kmh, dsm.cadence or 0.0),
            sc, 180, 220, 255); y = y + lh
        drawText(x, y, ('wind-in %d ms  recenter %d ms'):format(
            math.floor((dsm.inSweepMs or 0.0) + 0.5), math.floor((dsm.outSweepMs or 0.0) + 0.5)),
            sc, 180, 220, 255); y = y + lh
        drawText(x, y, ('~c~base in %d / out %d ms~s~'):format(
            math.floor((dsm.inMs or 0.0) + 0.5), math.floor((dsm.outMs or 0.0) + 0.5)),
            sc, 160, 180, 200); y = y + lh
        -- RWD SLIDE-CATCH: only meaningful on RWD; shows the slip-scaled countersteer rate bump.
        local ct = dsm.catchT or 0.0
        local ccol = (ct > 0.02) and '~g~' or '~c~'
        drawText(x, y, ('%sRWD catch %.2f~s~  in x%.2f  out x%.2f'):format(
            ccol, ct, dsm.catchIn or 1.0, dsm.catchOut or 1.0), sc, 180, 220, 255); y = y + lh
    end
    -- steering-lock multiplier (speed-graduated angle; separate system from the input model).
    -- Bar: red centre '|' = native; green spreads out = boost (>1); white closes in from edges = tighter (<1).
    local slm = HK.dbgSteerMult
    if slm then
        local col = slm > 1.001 and '~g~' or (slm < 0.999 and '~w~' or '~r~')
        drawText(x, y, ('lock x%s%.3f~s~ %s'):format(col, slm, lockBar(slm, 9)), sc, 200, 220, 255); y = y + lh
    end
    return y
end

-- ============ LEFT: REVERSE CAP ============
drawReverseSection = function(x, y)
    local rvc = HK.dbgRevCap
    drawText(x, y, '~b~REVERSE~s~', sc, 200, 200, 255); y = y + lh
    if rvc then
        local capping = (rvc.revKmh or 0.0) > (rvc.cap or 0.0) + 0.1
        drawText(x, y, ('%s spd %.0f  ceil %.0f / max %.0f km/h%s'):format(
            capping and '~r~CAPPING~s~' or '~g~ramping~s~', rvc.revKmh or 0.0, rvc.cap or 0.0,
            rvc.max or 0.0, staleTag(rvc)), sc, 255, 180, 120); y = y + lh
    else
        drawText(x, y, '~c~idle (not reversing)~s~', sc, 180, 160, 140); y = y + lh
    end

    -- REVERSE GATE state machine (R<->N<->D). Shows WHY a step did/didn't fire — the diagnostic
    -- for the intermittent reverse-entry misfire after a gear-drop / fresh-entry / crash. The
    -- 'arm' flags gate each step (a step needs its arm true); wasMoving/nFromRev pick the entry rule.
    local g = HK.dbgRevGate
    if g then
        local gcol = (g.state == 'reverse') and '~o~' or (g.state == 'neutral') and '~y~' or '~g~'
        drawText(x, y, ('gate %s%s~s~  %s  %s%s'):format(
            gcol, string.upper(tostring(g.state or '?')),
            g.brakeOn and '~o~BRK~s~' or '~c~brk~s~',
            g.thrOn and '~g~THR~s~' or '~c~thr~s~', staleTag(g)), sc, 220, 200, 160); y = y + lh
        drawText(x, y, ('  armB %s  armT %s  wasMov %s  nFromR %s'):format(
            g.brakeArm and '~g~y~s~' or '~r~n~s~',
            g.thrArm  and '~g~y~s~' or '~r~n~s~',
            g.wasMoving and '~g~y~s~' or '~c~n~s~',
            g.nFromRev and '~o~y~s~' or '~c~n~s~'), sc, 190, 175, 150); y = y + lh
    end
    return y
end

-- ============ RIGHT: DRIVETRAIN CLASS + RWD/AWD/FWD ENGAGEMENTS ============
drawDriveSection = function(x, y, s)
    local dv = HK.dbgDrive
    local class = dv and dv.class or '?'
    local classCol = (class == 'rwd') and '~o~' or (class == 'fwd') and '~b~' or (class == 'awd') and '~g~' or '~w~'
    drawText(x, y, ('class %s%s~s~  bias %.2f'):format(classCol, string.upper(tostring(class)),
        dv and dv.nativeBias or 0.0), sc, 200, 220, 255); y = y + lh

    -- 4WS (rear-steer) is class-AGNOSTIC (runs for any car carrying the flag) — show it on the class
    -- line so it's visible whatever drivetrain we're in. Only rendered if the car is actually capable.
    if dv and dv.rearSteerCapable then
        drawText(x, y, ('  4WS ~g~capable~s~  rears %s'):format(
            dv.rearSteerOn and '~g~in-phase~s~' or '~c~straight~s~'), sc, 200, 220, 255); y = y + lh
    end

    -- TC / ABS driver-aid state (class-agnostic). RED = switched OFF (aid gone, car on raw physics),
    -- green = ON. When OFF, show the live per-drivetrain engagement so you can see the effect biting:
    --   TCoff → the character-boost is active on the layout tools; ABSoff → front-lock plow + stop penalty.
    do
        local tcOff, absOff = HK.tcOff == true, HK.absOff == true
        drawText(x, y, ('  TC %s   ABS %s'):format(
            tcOff and '~r~OFF~s~' or '~g~ON~s~',
            absOff and '~r~OFF~s~' or '~g~ON~s~'), sc, 210, 210, 220); y = y + lh
        local ao = HK.dbgAbsOff
        if absOff and ao and ao.on then
            drawText(x, y, ('    ~o~plow %.2f~s~  stop-pen %.2f  FL %.2f RL %.2f'):format(
                ao.steer or 0.0, ao.stop or 0.0, ao.fl or 0.0, ao.rl or 0.0), sc, 230, 180, 150); y = y + lh
        end
    end

    -- WEIGHT-TRANSFER SPINE (class-agnostic central load) — shown above the per-class tools since every
    -- tool will eventually read it. long: - brake/nose-down .. + accel/squat; lat: sign = slide dir;
    -- front/rear = effective axle load 0..1 (braking loads front, accel loads rear).
    local L = HK.load
    if L then
        local lgcol = (L.long or 0) > 0.05 and '~g~' or ((L.long or 0) < -0.05 and '~o~' or '~c~')
        local ltcol = math.abs(L.lat or 0) > 0.05 and '~y~' or '~c~'
        drawText(x, y, ('~b~LOAD~s~ %slong %+.2f~s~  %slat %+.2f~s~  accel %+.1f%s'):format(
            lgcol, L.long or 0.0, ltcol, L.lat or 0.0, L.accel or 0.0, staleTag(L)), sc, 190, 210, 240); y = y + lh
        -- slip = shared INSTANT slip angle (deg) every helper reads (de-dup source). Yellow once it's
        -- past a typical cornering angle so you can eyeball when the slip-gated tools wake up.
        local slp = L.slipDeg or 0.0
        local spcol = slp > 12.0 and '~y~' or '~c~'
        drawText(x, y, ('  axle  front %.2f  rear %.2f  %sslip %.0f°~s~'):format(
            L.front or 0.5, L.rear or 0.5, spcol, slp), sc, 175, 195, 225); y = y + lh
    end

    if class == 'rwd' then
        local r = HK.dbgRwd or {}
        drawText(x, y, ('%s  %s  %s%s'):format(
            tok('PO', r.po, cfgEnabled('RWD','ProgressiveOversteer')),
            tok('CS', r.cs, cfgEnabled('RWD','CounterSteerReward')),
            tok('Lift', r.lift, cfgEnabled('RWD','LiftRotation')),
            staleTag(HK.dbgRwd)), sc, 200, 220, 255); y = y + lh
        drawText(x, y, ('%s  %s  %s'):format(
            tok('Spin', r.spin, cfgEnabled('RWD','SpinSoftener')),
            tok('Plant', r.plant, cfgEnabled('RWD','DriveOut')),
            tok('Rot', r.rot, cfgEnabled('RWD','DriveOut'))), sc, 200, 220, 255); y = y + lh
        -- Weight-transfer mirrors (2026-08-14): BrakeRot = trail-brake rotation, PSpin = open-diff inside-rear.
        drawText(x, y, ('%s  %s'):format(
            tok('BrakeRot', r.brake, cfgEnabled('RWD','BrakeRotation')),
            tok('PSpin', r.pspin, cfgEnabled('RWD','PowerSpin'))), sc, 200, 220, 255); y = y + lh
    elseif class == 'awd' then
        local aw = HK.dbgAwd or {}
        drawText(x, y, ('%s  bias %.3f (nat %.3f)%s'):format(
            tok('Under', aw.factor, (Config and Config.Drivetrain and Config.Drivetrain.AWD and Config.Drivetrain.AWD.Enabled)),
            aw.bias or 0.0, aw.native or 0.0, staleTag(HK.dbgAwd)), sc, 160, 255, 180); y = y + lh
        drawText(x, y, ('%s  %s  %s'):format(
            tok('Gov', aw.gov, cfgEnabled('AWD','TractionGovernor')),
            tok('Save', aw.save, cfgEnabled('AWD','PowerSave')),
            tok('SpinSoft', aw.spinsoft, cfgEnabled('AWD','SpinSoftener'))), sc, 160, 255, 180); y = y + lh
        drawText(x, y, ('%s  %s'):format(
            tok('TVec', aw.tv, cfgEnabled('AWD','TorqueVector')),
            tok('Lift', aw.lift, cfgEnabled('AWD','LiftBalance'))), sc, 160, 255, 180); y = y + lh
        drawText(x, y, ('%s  %s'):format(
            tokB('HB', aw.hb, cfgEnabled('AWD','HandbrakeAssist')),
            tokB('SteerLim', aw.steerlim, cfgEnabled('AWD','SteerLimit'))), sc, 160, 255, 180); y = y + lh
    elseif class == 'fwd' then
        local fw = HK.dbgFwd or {}
        drawText(x, y, ('%s  %s  %s%s'):format(
            tok('Under', fw.under, cfgEnabled('FWD','PowerUndersteer')),
            tok('Lift', fw.lift, cfgEnabled('FWD','LiftRotation')),
            tok('Plant', fw.plant, cfgEnabled('FWD','DriveOut')),
            staleTag(HK.dbgFwd)), sc, 180, 210, 255); y = y + lh
        drawText(x, y, ('%s  %s  diff %s'):format(
            tok('TSteer', fw.ts, cfgEnabled('FWD','TorqueSteer')),
            tok('LSD', fw.sd, cfgEnabled('FWD','SportDiff')),
            fw.sportdiff and '~g~YES~s~' or '~c~no~s~'), sc, 180, 210, 255); y = y + lh
        drawText(x, y, ('%s  %s  %s  %s'):format(
            tok('SpinCut', fw.spincut, cfgEnabled('FWD','SpinPenalty')),
            tok('BrakeUS', fw.brakeus, cfgEnabled('FWD','BrakeUndersteer')),
            tok('SpinSoft', fw.spinsoft, cfgEnabled('FWD','SpinSoftener')),
            tok('Straight', fw.straight, cfgEnabled('FWD','BrakeStraighten'))), sc, 180, 210, 255); y = y + lh
    else
        drawText(x, y, '~c~(no drivetrain class — not in a car / not classified)~s~', sc, 180, 180, 180); y = y + lh
    end
    return y
end

-- ============ RIGHT: ENGINE (real-number rpm + G-forces + torque-curve) ============
-- GTA has no real powertrain (the engine is a force coefficient), so power/torque are EMULATED from
-- physics: F=m·a using the MEASURED longitudinal accel from the weight-transfer spine (HK.load.accel),
-- P=F·v, τ=P/ω. That's the real power the car is putting down THIS instant at the wheels — labeled
-- "meas" so it reads honestly, not as a spec sheet. Boost is a stub until the turbo system lands.
drawEngineSection = function(x, y, s)
    y = y + lh * 0.3
    drawText(x, y, '~o~ENGINE~s~', sc, 255, 200, 120); y = y + lh
    local veh = s.vehicle

    -- REAL RPM: map raw (0..1, idle≈IdleApprox) onto a believable rev range.
    local raw   = GetVehicleCurrentRpm(veh)
    local idleR = cfg.EngineIdleRpm or 900
    local redR  = cfg.EngineRedlineRpm or 8000
    local idleRaw = cfg.IdleApprox or 0.20
    local rpm = idleR + (redR - idleR) * ((raw - idleRaw) / math.max(0.001, 1.0 - idleRaw))
    if rpm < 0 then rpm = 0 end
    local rr = math.floor(120 + raw * 135); local rg = math.floor(255 - raw * 180)
    drawText(x, y, ('rpm ~w~%d~s~ / %d   (raw %.3f)'):format(math.floor(rpm + 0.5), redR, raw),
        sc, rr, rg, 70); y = y + lh

    -- NO EMULATED HP/TORQUE (removed 2026-08-14). We tried both a MEASURED figure (mass·accel·v) and a
    -- CALCULATED one (from fInitialDriveForce·mass·topSpeed) and BOTH were fundamentally unreliable:
    -- handling.meta does NOT encode horsepower — you tune drive force / top speed / inertia by FEEL and
    -- lap the accel + top-end times until they're right, so any hp we back-derive from those fields is
    -- fiction and mis-ranks cars (GTR read higher than a Chiron/P1). The measured version also latched
    -- bumps/landings/collisions as fake megawatts. There's no honest number to show, so we show none.
    -- The G-forces below (measured accel, no unit-mapping fiction) are the trustworthy performance read.
    local vms   = s.speed or 0.0                                   -- m/s (used by G-force + drag lines)
    local accel = (HK.load and HK.load.accel) or 0.0               -- m/s^2 (measured dv/dt, smoothed)

    -- BOOST (turbo) — populated by HK.Turbo_Tick when the native turbo mod (jim-mechanic upgrade) is
    -- on. Shows spool bar + the flat power% (0 on comfort/paddle = feel-only there), and a NOS-muted tag.
    local boostOn = HK.dbgBoost and HK.dbgBoost.on
    if boostOn then
        local nosTag = HK.dbgBoost.nosMuted and '  ~o~(NOS)~s~' or ''
        -- antilag: green ~ALAG~ when the part is fitted; brighter ~ALAG*~ while it's actively HOLDING
        -- spool on a lift (effect B live). Antilag also owns the lift-off FX (effect A).
        local alTag = HK.dbgBoost.alHold and '  ~g~(ALAG*)~s~'
                   or (HK.dbgBoost.antilag and '  ~g~(ALAG)~s~' or '')
        -- source: 'design' = turbo-by-design FEEL only (no power, at-spec); 'upgrade'/'design+upgrade'
        -- = jim-mechanic mod 18 installed, so the flat power% applies. powerPct is 0 when feel-only.
        local src = HK.dbgBoost.source or 'upgrade'
        local srcTag = (src == 'design') and '  ~c~(feel/at-spec)~s~' or '  ~y~(upgrade)~s~'
        -- pwr now swings NEGATIVE off-boost (the choke/lag) and positive on-boost (the rush), so use a
        -- signed %+d and colour it: orange when choked (<0), green when boosting (>0), grey at neutral.
        local pwr = HK.dbgBoost.powerPct or 0.0
        local pwrCol = (pwr < -0.5) and '~o~' or (pwr > 0.5 and '~g~' or '~c~')
        -- HIT tag: the transient punch fired as boost slams online (hitPct = surge on top right now).
        -- Bright yellow ~HIT~ flashes while the surge is live (>1%), so you can see the moment it lands.
        local hit = HK.dbgBoost.hitPct or 0.0
        local hitTag = (hit > 1.0) and ('  ~y~HIT+%d%%~s~'):format(math.floor(hit + 0.5)) or ''
        drawText(x, y, ('boost ~g~%.2f bar~s~  %s%+d%%~s~ pwr%s%s%s%s'):format(
            HK.dbgBoost.bar or 0.0, pwrCol, math.floor(pwr + (pwr < 0 and -0.5 or 0.5)), hitTag, srcTag, alTag, nosTag),
            sc, 200, 220, 190); y = y + lh
        -- pedal-lag line: the FELT throttle choke. <100% = plate held down off-boost (the lag you feel),
        -- climbs to 100% as boost arrives. Orange while choked, green once the plate is fully open.
        local ped = HK.dbgBoost.pedalPct or 100.0
        if ped < 99.5 then
            drawText(x, y, ('  ~o~turbo-lag: pedal %d%%~s~ (choked off-boost)'):format(math.floor(ped + 0.5)),
                sc, 210, 170, 120); y = y + lh
        end
    else
        drawText(x, y, '~c~boost -- (NA, no turbo)~s~', sc, 170, 180, 170); y = y + lh
    end

    -- G-FORCES: drivetrain (longitudinal accel, measured) + air drag (estimate from dragCoeff×v²).
    local drivetrainG = accel / 9.81                              -- + accel / - braking, in g
    local dragCoeff   = GetVehicleHandlingFloat(veh, 'CHandlingData', 'fInitialDragCoeff') or 0.0
    local dragG       = dragCoeff * vms * vms * (cfg.DragGScale or 0.10) / 9.81   -- resistive, estimate
    local dgcol = drivetrainG > 0.02 and '~g~' or (drivetrainG < -0.02 and '~o~' or '~c~')
    drawText(x, y, ('%sdrivetrain %+.2fg~s~   ~c~air-drag %.2fg (est)~s~'):format(
        dgcol, drivetrainG, dragG), sc, 190, 205, 225); y = y + lh

    -- TORQUE CURVE: Layer A rpm-note offset (perf-neutral) + Layer B power band (perf, modes 4/5).
    local tc = HK.dbgTorqueCurve
    if tc then
        local bcol = tc.bandOn and (tc.band > 1.005 and '~g~' or (tc.band < 0.995 and '~o~' or '~c~')) or '~r~'
        drawText(x, y, ('curve  %sband %.3f%s~s~  ~c~note %+.3f~s~%s'):format(
            bcol, tc.band or 1.0, tc.bandOn and '' or ' off', tc.rpmOff or 0.0, staleTag(tc)),
            sc, 190, 205, 225); y = y + lh
    end
    return y
end

-- ============ RIGHT: GEAR / EV / LAUNCH (from the hk_drivestate bag) ============
drawGearSection = function(x, y, s)
    y = y + lh * 0.3
    drawText(x, y, '~o~GEAR / DRIVE STATE~s~', sc, 255, 200, 120); y = y + lh
    local veh = s.vehicle
    local ds
    local ok = pcall(function() ds = Entity(veh).state and Entity(veh).state.hk_drivestate end)
    if not ok or not ds then
        -- fall back to raw natives so gear always shows even without the bag
        local g = GetVehicleCurrentGear(veh)
        drawText(x, y, ('gear %d  (no drivestate bag — native GB off?)'):format(g), sc, 200, 180, 140); y = y + lh
        return y
    end
    local gl = ds.gearLabel or tostring(GetVehicleCurrentGear(veh))
    local mode = ds.gearboxMode or (ds.singleGear and 'single' or '-')
    drawText(x, y, ('gear %s~w~%s~s~   mode %s'):format('~g~', gl, tostring(mode)), sc, 220, 220, 200); y = y + lh

    -- ===== DEEP GEAR INTERNALS (from HK.dbgGear, refreshed by gearbox.lua while /handlingdbg on) =====
    local d = HK.dbgGear
    if d and (GetGameTimer() - (d.at or 0)) < 500 then
        -- TYPE line: player-facing PUBLIC type + label, and the INTERNAL engine mode it runs on.
        local ptype = (d.publicType ~= nil) and tostring(d.publicType) or '?'
        local plabel = d.publicLabel or '?'
        local prof = d.profLabel and (' ~w~['..d.profLabel..']~s~') or ''
        drawText(x, y, ('type ~y~%s~s~ %s~s~  int ~c~%s~s~%s'):format(
            ptype, plabel, tostring(d.gearMode), prof), sc, 210, 200, 170); y = y + lh

        -- GEARS line: native GTA gear, our logical DCT gear + committed/pending, top gear.
        local gearsTxt
        if d.dctGear ~= nil then
            local pend = d.dctPending and (' ~o~->%d~s~'):format(d.dctPending) or ''
            gearsTxt = ('nat ~w~%d~s~  ours ~g~%d~s~ (commit %d%s)  top %d'):format(
                d.nativeGear or -1, d.dctGear or -1, d.dctCommitted or -1, pend, d.highGear or -1)
        else
            gearsTxt = ('nat ~w~%d~s~  top %d'):format(d.nativeGear or -1, d.highGear or -1)
        end
        -- tgt = OUR logical gear (what GetDisplayGear returns for R/N/manual); gate = reverse-gate.
        -- If tgt shows 0 (N) but the speedo shows 1, the speedo is falling back to native gear
        -- (export returned nil). If tgt itself shows 1, the box hasn't logically gone to neutral.
        local tgtLbl = ({ ['-1'] = 'R', ['0'] = 'N' })[tostring(d.targetGear or 99)] or tostring(d.targetGear or -99)
        gearsTxt = gearsTxt .. ('  tgt ~y~%s~s~  gate ~c~%s~s~'):format(tgtLbl, d.revGate or '-')
        drawText(x, y, gearsTxt, sc, 200, 210, 200); y = y + lh

        -- REVERSE INJECTION diagnostic (2026-08-14 rework). Shows the live state of the W-drives-reverse
        -- swap so we can see EXACTLY where it breaks: inRev = gearbox says logical R; injRev = Tick latched
        -- the reverse ramp; pedal = master toggle on; analog = we're NOT injecting (wheel/pad or fault).
        -- If inRev=y but injRev=n → 1-frame lag / Tick not running. If inRev=n in reverse → box is in N.
        do
            local irCol = (HK.inReverseGear == true) and '~g~y~s~' or '~r~n~s~'
            local jrCol = (HK._injReversing == true) and '~g~y~s~' or '~r~n~s~'
            local pmCol = (HK.pedalModelOn == true) and '~g~y~s~' or '~o~n~s~'
            local anCol = (HK._injAnalog == true) and '~o~y~s~' or '~c~n~s~'
            drawText(x, y, ('  ~b~REV~s~ inRev %s  injRev %s  pedal %s  analog %s'):format(
                irCol, jrCol, pmCol, anCol), sc, 180, 200, 230); y = y + lh
            -- N->R selection gate: last time a downshift-from-N tried to select reverse, did the
            -- near-stop + brake gate pass? okR=n with brk<0.5 means "you weren't holding S".
            if d.revSelOk ~= nil then
                local okCol = d.revSelOk and '~g~PASS~s~' or '~r~BLOCK~s~'
                drawText(x, y, ('      selR %s  kmh %.1f  brk %.2f'):format(
                    okCol, d.revSelKmh or 0.0, d.revSelBrk or 0.0), sc, 180, 200, 230); y = y + lh
            end
        end

        -- RPM line: NATIVE (what GTA reports, incl. our rpm paints) vs our SCRIPT-CALCULATED
        -- rpm for this gear from the learned ratio. A gap = slip-flare / limiter / unlearned gear.
        local calc = d.rpmCalc and ('~b~%.3f~s~'):format(d.rpmCalc) or '~c~n/a~s~'
        drawText(x, y, ('rpm nat ~w~%.3f~s~  calc %s  st %.3f'):format(
            d.rpmNative or 0.0, calc, d.rpmState or 0.0), sc, 190, 210, 230); y = y + lh

        -- RATIO line: the /gearratio MODE (switch) + label, and the ACTUAL native x.xx gear ratio.
        drawText(x, y, ('ratio ~y~%s~s~ (%s)  actual ~w~x%.3f~s~'):format(
            (d.ratioMode ~= nil) and tostring(d.ratioMode) or '-', d.ratioLabel or '-',
            d.gearRatio or 0.0), sc, 210, 200, 170); y = y + lh

        -- FLYWHEEL line: the auto-detected per-car flywheel factor (from fDriveInertia) that drives the
        -- free-rev feel. <1 = light (snappy rev, fast drop), >1 = heavy (lazy rev, long rev-hang).
        if d.flyMass then
            local fcol = (d.flyMass < 0.95) and '~c~' or (d.flyMass > 1.05 and '~o~' or '~g~')
            local ftag = (d.flyMass < 0.95) and 'light' or (d.flyMass > 1.05 and 'heavy' or 'neutral')
            -- Phase-B engine-braking tail: shows the live fDriveInertia nudge (+ light flywheel brakes
            -- harder, - heavy coasts) and whether it's currently engaged (on a lift). Off => just the base.
            local ebtail = ''
            if d.flyBrake then
                local nb = d.flyBrake.nudge or 0.0
                local ncol = d.flyBrake.eng and '~g~' or '~w~'
                -- phase word: green when actively engine-braking (coasting/braking), grey otherwise.
                local ph  = d.flyBrake.phase or '?'
                local pcol = (ph == 'coasting' or ph == 'braking') and '~g~' or '~w~'
                ebtail = ('  ~s~eb %s%+.2f~s~ %sni %.2f~s~ %s%s~s~'):format(
                    (nb >= 0) and '~c~' or '~o~', nb, ncol, d.flyBrake.ni or 0.0, pcol, ph)
            end
            drawText(x, y, ('flywheel %s%.2f~s~ %s  ~w~(di %.2f)~s~%s'):format(
                fcol, d.flyMass, ftag, d.flyBase or -1, ebtail), sc, 195, 200, 185); y = y + lh
        end

        -- MULTS line: the x-times numbers the ratio mode applies (up/down shift-point, shift time,
        -- low-gear torque, drive inertia, drive-force %). Only shows when a non-default is active.
        if d.upMult then
            local dfTxt = ((d.dfPct or 0) ~= 0) and (' df %+.0f%%'):format((d.dfPct or 0)*100) or ''
            drawText(x, y, ('x up %.2f dn %.2f shf %.2f lowT %.2f inr %.2f%s'):format(
                d.upMult or 1, d.downMult or 1, d.shiftTMult or 1, d.lowTMult or 1,
                d.inertMult or 1, dfTxt), sc, 175, 190, 175); y = y + lh
        end

        -- WINDOW line (DCT family only): live AUTO shift window (throttle-grounded on the TC),
        -- the manual paddle window, and the raw handling.meta-derived shift time it absorbs from.
        if d.dctWin then
            drawText(x, y, ('win auto ~w~%dms~s~ paddle %dms  raw %dms  sub ~c~%s~s~%s'):format(
                math.floor(d.dctWin), math.floor(d.dctPaddle or d.dctWin), math.floor(d.rawShiftMs or 0),
                tostring(d.dctSub or '-'), d.dctNeutral and ' ~o~[N]~s~' or ''), sc, 200, 205, 215); y = y + lh
            -- COAST line: lift-off coast-up counter (the 4->6->7 fix). Shows gears climbed on the
            -- current lift; a lit [coast-up] means the last auto upshift was a lift-off one.
            local airBlk = (GetGameTimer() < (HK.gbAirSettleUntil or 0))
            drawText(x, y, ('coast steps ~w~%d~s~%s%s'):format(
                HK.coastUpSteps or 0, d.coastUp and ' ~y~[coast-up]~s~' or '',
                airBlk and ' ~o~[air-block]~s~' or ''), sc, 195, 200, 175); y = y + lh
            -- DOWN-BIAS line: the type-split downshift threshold + which bias is driving it
            -- (coast: TC lazy / DCT eager; brake: brake-based downshift push).
            if d.coastDownThr then
                local btxt = (d.coastDownBias or 0) > 0 and ('~o~coast+%.2f~s~'):format(d.coastDownBias)
                          or (d.coastDownBias or 0) < 0 and ('~c~coast%.2f~s~'):format(d.coastDownBias)
                          or 'coast 0'
                local brk = (d.brakeDownBias or 0) > 0.001 and ('  ~r~brake+%.2f~s~'):format(d.brakeDownBias) or ''
                drawText(x, y, ('down thr ~w~%.2f~s~  %s%s'):format(d.coastDownThr, btxt, brk), sc, 195, 200, 175); y = y + lh
            end
        end
    end

    -- CLUTCH GAUGE (manual modes 1 & 6 only) — live HK.clutchEngage ramp so the up/down easing is
    -- legible while tuning ClutchGaugeTauIn/Out. 1.00 = clutch OUT (engaged, drive coupled);
    -- 0.00 = clutch IN (pressed/decoupled: shift, neutral, or clutch-dip). Set every frame in
    -- Gearbox_Tick (not gated on the overlay), so it's always fresh here. Cosmetic — the hk-speedo
    -- gauge renders the same value. Shows the raw decoupled TARGET too so you can see lead/lag.
    if HK.clutchIsManual then
        local ce  = HK.clutchEngage or 1.0
        local col = (ce > 0.66) and '~g~' or (ce > 0.33) and '~y~' or '~r~'
        local st  = (ce > 0.95) and 'engaged' or (ce < 0.05) and 'pressed' or '~o~slipping~s~'
        drawText(x, y, ('clutch %s%.2f~s~ %s %s'):format(col, ce, tdbgBar(ce, 12), st),
            sc, 210, 210, 190); y = y + lh
    end

    -- EV / hybrid line
    local evTag = ds.electric and '~b~ELECTRIC~s~' or (ds.hybrid and '~y~hybrid-ICE~s~' or '~c~ICE~s~')
    drawText(x, y, ('%s  regen %s%s'):format(evTag, tostring(ds.regenMode or 'coast'),
        ds.regenActive and ' ~g~[active]~s~' or ''), sc, 200, 210, 220); y = y + lh
    if ds.semiHybrid then
        drawText(x, y, ('KERS boost %.2f %s'):format(ds.semiBoost or 0.0, tdbgBar(ds.semiBoost or 0.0, 12)),
            sc, 255, 200, 120); y = y + lh
    end
    -- launch control
    local lp = ds.launchPhase or 'off'
    if lp ~= 'off' or ds.launchNeutral or ds.launchActive then
        local lc = (lp == 'launched') and '~r~' or (lp == 'staged') and '~y~' or '~c~'
        -- Resolved per-drivetrain launch profile (set at stage): class + manual/auto lever set.
        local lprof = HK.launchProfile
        local profTag = ''
        if lprof then
            profTag = (' ~s~%s%s'):format(
                string.upper(lprof.dbgClass or 'n/a'),
                lprof.dbgManual and ' ~o~MAN~s~' or ' ~c~AUTO~s~')
        end
        drawText(x, y, ('LAUNCH %s%s~s~%s%s%s'):format(lc, string.upper(lp),
            ds.launchNeutral and ' ~c~[N]~s~' or '', ds.launchHb and ' ~c~[HB]~s~' or '',
            profTag), sc, 255, 190, 150); y = y + lh
    end
    -- ===== TC-FEEL DIAGNOSTICS (Automatic Paddle / mode 3) — what to eyeball on the new mode.
    -- Only shows for the TC (public type 2 / internal mode 3); DCT 3/4 don't run these mechanisms.
    if d and d.gearMode == 3 and (GetGameTimer() - (d.at or 0)) < 500 then
        local tnow = GetGameTimer()

        -- PERF-NEUTRALITY tell: rolling avg of the FINAL torque multiplier. Should hover ~1.00.
        -- A steady cruise reading well under 1.00 = feel-shaping is stealing real torque (BAD).
        local tq = HK.torqueMultApplied or 1.0
        tqEma = tqEma * 0.9 + tq * 0.1
        local tqCol = (math.abs(tqEma - 1.0) < 0.03) and '~g~' or (math.abs(tqEma - 1.0) < 0.08) and '~y~' or '~r~'
        drawText(x, y, ('torqueAvg %s%.3f~s~ (want ~g~1.00~s~)  now %.2f'):format(
            tqCol, tqEma, tq), sc, 190, 205, 200); y = y + lh

        -- SLIP-FLARE line: current painted slip, where it's HEADING (tgt), lockup fraction, and
        -- WHY it's suppressed when it is. reason nil = actively flaring (elastic rpm above ratio).
        local slip = HK.tcSlipCur or 0.0
        local why  = d.slipWhy
        local slipState
        if why == 'coast' then slipState = '~c~coast (thr<gate)~s~'
        elseif why == 'lockup' then slipState = '~b~LOCKED (v>lockup km/h)~s~'
        elseif why == 'cap' then slipState = '~o~redline-capped~s~'
        else slipState = '~g~flaring~s~' end
        drawText(x, y, ('slip ~w~%+.3f~s~ ->%.3f  lock %.2f  %s'):format(
            slip, d.slipTgt or 0.0, d.slipLock or 0.0, slipState), sc, 185, 205, 230); y = y + lh
        -- the nat-vs-calc gap is the visible proof: rpm needle should ride ABOVE calc while flaring.
        if slip > 0.0005 and d.rpmCalc then
            drawText(x, y, ('  needle +%.3f over calc %s'):format(
                (d.rpmNative or 0) - (d.rpmCalc or 0),
                ((d.rpmNative or 0) > (d.rpmCalc or 0)) and '~g~[ahead]~s~' or '~r~[behind?]~s~'),
                sc, 160, 190, 210); y = y + lh
        end

        -- KICK line: latch the last upshift kick for ~1.2s so it's readable after it fades.
        if (d.kickAt or 0) > 0 and (d.kickAt or 0) ~= kickHoldUntil then
            kickHoldUntil = d.kickAt
            kickHoldAmp, kickHoldGated, kickHoldThr = d.kickLast or 0.0, d.kickGated, d.kickThr
        end
        if (tnow - (kickHoldUntil or 0)) < 1200 and (kickHoldAmp or 0) > 0.0005 then
            local live = (HK.dctKickUntil or 0) > tnow
            local gateTxt = kickHoldGated
                and (('~y~gated~s~ thr %.2f'):format(kickHoldThr or 0.0))
                or '~o~constant~s~'
            drawText(x, y, ('KICK %s%.3f~s~ %s%s'):format(
                live and '~g~' or '~w~', kickHoldAmp, gateTxt, live and ' ~g~[firing]~s~' or ''),
                sc, 190, 215, 190); y = y + lh
        end
    end
    -- ===== DCT-FEEL DIAGNOSTICS (Sport/Super DCT — internal mode >= 4) — the four
    -- dual-clutch mechanisms. Verify each: HANDOFF should read a fraction (NOT 0) mid-
    -- upshift at throttle; RPMSNAP shows the last commit's snapped target; MULTI-DOWN
    -- lights under hard braking; BARK shows the last downshift crack target.
    if d and (d.gearMode or 0) >= 4 and (GetGameTimer() - (d.at or 0)) < 500 then
        local tnow = GetGameTimer()
        -- PERF tell (DCT is ALLOWED to gain, but a steady cruise should still sit ~1.00 —
        -- the handoff/kick only apply DURING a shift, not at cruise).
        local tq = HK.torqueMultApplied or 1.0
        tqEma = tqEma * 0.9 + tq * 0.1
        local tqCol = (math.abs(tqEma - 1.0) < 0.03) and '~g~' or (math.abs(tqEma - 1.0) < 0.08) and '~y~' or '~r~'
        drawText(x, y, ('torqueAvg %s%.3f~s~  now %.2f'):format(tqCol, tqEma, tq), sc, 190, 205, 200); y = y + lh
        -- HANDOFF: the seamless retain fraction. Live green while a shift window holds it;
        -- shows the last value otherwise. 0.00 = full cut (downshift/no-shift); >0 = coupled.
        local hr = d.handoffRetain
        if hr ~= nil then
            local hLive = (HK.dctKickUntil or 0) > 0 and (d.dctPending ~= nil)
            drawText(x, y, ('HANDOFF %s%.2f~s~ %s'):format(
                (hr > 0.01) and '~g~' or '~w~', hr,
                (hr > 0.01) and '~g~[coupled]~s~' or '~c~full-cut~s~'), sc, 185, 210, 235); y = y + lh
        end
        -- RPMSNAP: last upshift's snapped-to rpm (needle jumps here instantly on commit).
        if (d.rpmSnapTo or 0) > 0 then
            drawText(x, y, ('RPMSNAP ->%.2f ~g~[rigid]~s~'):format(d.rpmSnapTo), sc, 185, 210, 235); y = y + lh
        end
        -- MULTI-DOWN: lit while a hard-braking downshift cascade is active (dwell collapsed).
        local mdCol = d.multiDown and '~g~' or '~w~'
        drawText(x, y, ('MULTI-DOWN %s%s~s~ (brake>0.6)'):format(
            mdCol, d.multiDown and 'ACTIVE' or 'idle'), sc, 200, 205, 190); y = y + lh
        -- BARK: last downshift rev-match crack target (snapped, not swelled).
        if (d.barkTgt or 0) > 0 then
            drawText(x, y, ('BARK ->%.2f ~o~[crack]~s~'):format(d.barkTgt), sc, 210, 195, 185); y = y + lh
        end
        -- FLUTTER / JUDDER / CREEP: the three "what else" signatures. Show live state.
        if (d.flutter or 0) > 0 or (d.judder or 0) > 0 then
            drawText(x, y, ('FLUTTER %.3f  JUDDER %s%.3f~s~'):format(
                d.flutter or 0.0, (d.judder or 0) > 0 and '~g~' or '~w~', d.judder or 0.0),
                sc, 200, 200, 200); y = y + lh
        end
    end
    return y
end

-- ============ RIGHT: DRIFT MODE ============
drawDriftSection = function(x, y, s)
    y = y + lh * 0.3
    local on = HK.driftMode == true
    drawText(x, y, ('~o~DRIFT~s~  %s'):format(on and '~g~ENGAGED~s~' or '~c~grip mode~s~'), sc, 255, 200, 120); y = y + lh
    if on then
        -- live slide readout from the shared state snapshot (drift.lua owns the physics; these are the
        -- inputs it reacts to, always available on HK.state).
        local fwd  = s.forwardSpeed or 0.0
        local latS = s.lateralSpeed or 0.0
        local yaw  = s.yawRate or 0.0
        local slipDeg = (fwd > 1.0) and math.deg(math.atan(latS / fwd)) or 0.0
        drawText(x, y, ('slip %+.0f deg  yaw %+.2f rad/s'):format(slipDeg, yaw), sc, 255, 210, 170); y = y + lh
        drawText(x, y, ('lat %+.1f m/s  fwd %.0f m/s'):format(latS, fwd), sc, 255, 210, 170); y = y + lh
        -- LAUNCH EMPHASIS + GEAR CEILING (symptom #5, reworked): shows the low-speed
        -- launch emphasis (torque hold + rear fry), whether the box is holding the gear
        -- (block auto-upshift, allow downshift), + the live wheelspin magnitude.
        local dd = HK.dbgDrift
        if dd then
            local ld = dd.launch == true
            local hg = dd.holdGear == true
            drawText(x, y, ('launch %s  gear %s  spin %.1f m/s'):format(
                ld and '~g~EMPHASIS~s~' or '~c~off~s~',
                hg and '~g~HELD~s~' or '~c~free~s~', dd.spin or 0.0), sc,
                ld and 150 or 200, ld and 255 or 200, 150); y = y + lh
            -- BRAKE-TORQUE SPIN RPM PIN: peak captured under the brake load + the live pin
            -- (PIN when held on release, off otherwise). This is the "hold rpm on brake-lift".
            local pinning = (dd.spinRpm or 0.0) > 0.01
            drawText(x, y, ('spinRPM %s  peak %.2f'):format(
                pinning and ('~g~PIN %.2f~s~'):format(dd.spinRpm) or '~c~off~s~',
                dd.spinPeak or 0.0), sc,
                pinning and 150 or 200, pinning and 255 or 200, 150); y = y + lh
        end
    end
    return y
end

-----------------------------------------------------------------
-- /handlingdbg — the full HANDLING STATUS SCREEN. Persistent (stays on screen), two columns
-- hugging the left + right edges so the CENTRE stays clear for driving. Left column = inputs
-- (pedals, steering + rates, reverse). Right column = drivetrain (class, RWD/AWD/FWD engagements,
-- gear/EV/launch from the hk_drivestate bag, drift). Each section renders every frame; a tick that
-- stopped publishing shows '(stale)' rather than vanishing, so the numbers never disappear on you.
-----------------------------------------------------------------

-- Draw a section header + return the next line's y. Keeps the two columns' cursors independent.
local function header(x, y, label, r, g, b)
    drawText(x, y, label, sc + 0.03, r, g, b)
    return y + lh * 1.15
end

CreateThread(function()
    local topY = 0.150            -- start high; the two columns run down the screen edges
    while true do
        if hdbgOn then
            local s = HK and HK.state
            local driving = s and s.vehicle and s.vehicle ~= 0
            -- ================= LEFT COLUMN — INPUTS =================
            local ly = topY
            ly = header(LX, ly, '~b~== INPUTS ==', 120, 200, 255)
            if not driving then
                drawText(LX, ly, '~c~(not in a vehicle / not driver)~s~', sc, 180, 180, 180)
            else
                ly = drawPedalSection(LX, ly, s)
                ly = ly + lh * 0.4
                ly = drawSteerSection(LX, ly, s)
                ly = ly + lh * 0.4
                ly = drawReverseSection(LX, ly)
            end

            -- ================= RIGHT COLUMN — DRIVETRAIN / GEAR / DRIFT =================
            local ry = topY
            ry = header(RX, ry, '~o~== DRIVETRAIN ==', 255, 200, 120)
            if not driving then
                drawText(RX, ry, '~c~(no vehicle)~s~', sc, 180, 180, 180)
            else
                ry = drawDriveSection(RX, ry, s)
                ry = ry + lh * 0.4
                ry = drawEngineSection(RX, ry, s)
                ry = ry + lh * 0.4
                ry = drawGearSection(RX, ry, s)
                ry = ry + lh * 0.4
                ry = drawDriftSection(RX, ry, s)
            end
        end
        Wait(0)
    end
end)

-- Toggle helper. Publishes hk_handlingdbg on the LOCAL player so the NUI overlays
-- (hk-speedo, hk-hud) can hide themselves while the debug screen is up — native
-- DrawText always renders BEHIND CEF/NUI, so without this the columns get buried
-- under the speedo (bottom-right) and hud (bottom-left/right). Restored on toggle-off.
local function setHandlingDbg(on, via)
    hdbgOn = on
    HK.hdbgOn = hdbgOn
    LocalPlayer.state:set('hk_handlingdbg', hdbgOn, true)   -- replicated=true so it survives filters
    print(('[hk-handlingdbg] status screen %s%s'):format(hdbgOn and 'ON' or 'OFF', via or ''))
end

RegisterCommand('handlingdbg', function()
    setHandlingDbg(not hdbgOn)
end, false)
-- Legacy alias so muscle memory / old notes still work.
RegisterCommand('throttledbg', function()
    setHandlingDbg(not hdbgOn, ' (via /throttledbg alias)')
end, false)

-- BISECT TOGGLES — isolate the slow-motion cause live, without a restart per guess.
-- /dftoggle  : gravity downforce on/off (releases held gravity when turned off)
-- /biastoggle: high-speed traction-bias centering on/off
RegisterCommand('dftoggle', function()
    if not Config.Downforce then return end
    Config.Downforce.Enabled = not Config.Downforce.Enabled
    if not Config.Downforce.Enabled and Downforce_Reset then
        Downforce_Reset(HK and HK.vehicle)      -- give gravity straight back
    end
    print(('[hk-handling] DOWNFORCE (gravity) %s'):format(Config.Downforce.Enabled and 'ON' or 'OFF'))
end, false)

RegisterCommand('biastoggle', function()
    if not (Config.Downforce and Config.Downforce.BiasCenter) then return end
    Config.Downforce.BiasCenter.Enabled = not Config.Downforce.BiasCenter.Enabled
    print(('[hk-handling] BIAS-CENTERING %s'):format(Config.Downforce.BiasCenter.Enabled and 'ON' or 'OFF'))
end, false)

-- DRIVER ASSISTS — ABS + Traction Control simple on/off (NOT multi-stage — players don't
-- get to "twerk" a bunch of modes). Toggle via /abs /tc OR the F1 qb-radialmenu vehicle
-- options (which fire the net events below). State lives on HK.absOff/HK.tcOff (main loop
-- gates the ticks) AND is mirrored to a REPLICATED player statebag so hk-speedo lights the
-- TC/ABS pills as OFF — mirroring the hk_nosBoostLevel pattern (bag = single source of truth,
-- survives NUI resets). ON is the default; only OFF is a deliberate, visible choice.
local function setAbs(off)
    HK.absOff = off and true or false
    LocalPlayer.state:set('hk_abs_off', HK.absOff, true)   -- replicated so hk-speedo reads it
    print(('[hk-handling] ABS %s'):format(HK.absOff and 'OFF' or 'ON'))
end
local function setTc(off)
    HK.tcOff = off and true or false
    if HK.tcOff then HK.tcFactor = 0.0 end                 -- drop any in-flight cut immediately
    LocalPlayer.state:set('hk_tc_off', HK.tcOff, true)
    print(('[hk-handling] TC %s'):format(HK.tcOff and 'OFF' or 'ON'))
end

RegisterCommand('abs', function() setAbs(not HK.absOff) end, false)
RegisterCommand('tc',  function() setTc(not HK.tcOff)  end, false)

-- Fired by qb-radialmenu vehicle-options items (client events).
RegisterNetEvent('hk-handling:client:toggleABS', function() setAbs(not HK.absOff) end)
RegisterNetEvent('hk-handling:client:toggleTC',  function() setTc(not HK.tcOff)  end)

-- Seed the statebag once on load so a fresh join shows the correct (ON) pill state.
CreateThread(function()
    Wait(1500)
    LocalPlayer.state:set('hk_abs_off', HK.absOff or false, true)
    LocalPlayer.state:set('hk_tc_off',  HK.tcOff  or false, true)
end)

-- DECAY TRACER (/hkdecay) — the "power fades to less and less under throttle" hunt. Arms the once/sec
-- [hk-DECAY] console trace in gearbox.lua that prints the decomposed torque chain (turbo x hit x
-- accelMatch = applied) + spool + mfv clamp while driving, so we can SEE which term collapses.
RegisterCommand('hkdecay', function()
    HK.decayTraceOn = not HK.decayTraceOn
    print(('[hk-DECAY] torque-chain trace %s'):format(HK.decayTraceOn and 'ON (drive on throttle, watch F8)' or 'OFF'))
end, false)

-- WHEELIE TRIGGER TRACE (/wheelietrace) — auto-prints the trigger signals to F8 so the user
-- doesn't have to read a 60fps on-screen HUD. Toggle on, drive + do the gesture, toggle off,
-- copy the log block. Throttled to ~5/sec (every 200ms) AND only while in a vehicle, so the
-- console stays readable. Prints a header row whenever it (re)starts. Fields are the exact
-- signals the in-gear wheelie trigger has to key off: gear/speed, throttle/brake(raw pedal),
-- steer, painted rpm, native wheelspin (worstSpin now + session peak), driftMode, launching.
HK.wheelieTraceOn = false
RegisterCommand('wheelietrace', function()
    HK.wheelieTraceOn = not HK.wheelieTraceOn
    if HK.wheelieTraceOn then
        print('[hk-WT] wheelie trigger trace ON — drive + do the gesture, then /wheelietrace to stop & copy below')
        print('[hk-WT] t(ms) gear kmh thr brk steer rpm spin spinPk drift launch')
    else
        print('[hk-WT] wheelie trigger trace OFF')
    end
end, false)

CreateThread(function()
    local last = 0
    while true do
        if HK.wheelieTraceOn then
            local now = GetGameTimer()
            if now - last >= 200 then
                last = now
                local s  = HK and HK.state
                local dd = HK.dbgDrift or {}
                if s and s.vehicle and s.vehicle ~= 0 then
                    print(('[hk-WT] %d g%d %.0f thr%.2f brk%.2f str%+.2f rpm%.2f spin%.2f pk%.2f drift%s lch%s'):format(
                        now,
                        s.gear or 0,
                        s.speedKmh or 0.0,
                        s.effThrottle or s.throttle or 0.0,
                        HK._pedalBrake or s.effBrake or s.brake or 0.0,
                        s.steer or 0.0,
                        s.rpm or 0.0,
                        dd.spin or 0.0,
                        dd.spinPeak or 0.0,
                        (HK.driftMode == true) and 'Y' or 'n',
                        (HK.launching == true) and 'Y' or 'n'
                    ))
                end
            end
        end
        Wait(0)
    end
end)

print('[hk-handlingdbg] loaded (in rpmdebug.lua). command=/handlingdbg (alias /throttledbg). /wheelietrace = F8 trigger log')
