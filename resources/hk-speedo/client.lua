-----------------------------------------------------------------
-- hk-speedo :: client.lua
-- Vehicle telemetry → NUI gauge. Detects NOS, drift, handbrake,
-- bad gear changes. Integrates with hk-handling gearbox.
-----------------------------------------------------------------

-- Display mode: 'normal' | 'lite' | 'full' | 'minimal'. Per-player, saved to SQL (server.lua).
--   normal  = DEFAULT. full look with CHEAP glow halos (twin arcs, no per-frame blur) —
--             the glow follows the lit tip but is GPU-composited, so ~no FPS cost
--   lite    = rings + gear + speed + bars + indicators, but NO glow/vibration/backlight
--             (the expensive per-frame paint) — biggest FPS win short of minimal
--   full    = MAX quality: live per-arc drop-shadow blur filters (re-rasterized each
--             frame). Best-looking, most expensive — for high-end PCs
--   minimal = no rings; the small rectangle (speed + fill bar) like the passenger HUD
local speedoMode = 'normal'
local MODE_ORDER = { 'normal', 'lite', 'full', 'minimal' }
local QBCore = exports['qb-core'] and exports['qb-core']:GetCoreObject() or nil

local vehReady = false     -- STAGE 1: seated in the driver's seat (per-vehicle prep done)
local showing = false      -- STAGE 2: engine on -> speedo engaged/showing
local showReady = false    -- true once the show animation has actually fired
local engagePending = 0    -- token so a stall/quick-restart cancels a pending engage
local menuHidden = false   -- true while temporarily hidden by pause/map menu
local dbgHidden = false     -- true while hidden for hk-handling's /handlingdbg overlay
local lastGear = 0
local gearReady = false   -- false until the first gear read (avoids a false glow on entry)
local lastRpm = 0.0
-- Last values SENT to the NUI — used to skip per-frame 'tick' messages when nothing
-- moved (FiveM best practice: don't send NUI updates every tick). Deadbanded so tiny
-- idle jitter doesn't defeat the gate.
local sentSpeed = -1
local sentGear = -999
local sentLc = 'off'   -- last launch-control render state pushed to the NUI (change-detect)
local sentClutch = -1  -- last clutch engagement pushed (change-detect bucket, 0.05 steps)
local sentTurbo = -1   -- last turbo spool pushed (change-detect; streams while boost is live)
-- Keep sending ticks for a short window after the last real change, so the JS-side
-- easing (smoothSpeed) always finishes converging instead of freezing partway.
local tickSettle = 0
local TICK_SETTLE_FRAMES = 45   -- ~1.2s at 38fps — comfortably covers the JS ease to 0
local driftActive = false
local absOff = false            -- driver switched ABS off (hk_abs_off player statebag, from hk-handling)
local tcOff  = false            -- driver switched Traction Control off (hk_tc_off player statebag)
local blinkerArmed = false      -- auto-blinker armed (hk_blinker player statebag, from hk-handling)
local lastVehicle = 0
local useMetric = true
local handbrakeHeld = true
local revLimiting = false
local currentMaxSpeed = 360  -- dynamic per-vehicle, in display units (kmh or mph)
local currentRedline = 0.85  -- normalised rpm the shift-lights/redline glow arm at
local currentElectric = false -- "electric NOW": pure-EV, OR a hybrid currently in e-mode
local baseModelElectric = false -- static GetIsVehicleElectric(model), set on entry (pure EVs)
local isHybridVeh = false      -- car is a hybrid (has both e-mode + ICE, via hold-G)
local electricNow = false      -- hybrid live e-mode flag (pure EVs are always electric)

-- NOS state (updated via event from jim-mechanic)
local nosBoostActive = false
local nosLevel = 0
local nosHasNitro = false
-- Extended NOS state for the redesigned bar. Sourced from jim-mechanic (resource
-- folder = 'mechanic'):
--   nosAmount     0..100 remaining, from exports['mechanic']:GetNosLevel (also hasNos)
--   nosHasNos     true if the car actually has the NOS modifier fitted
--   nosPurgeMode  true while purging — from the hk_nosPurgeMode player statebag ([HK EDIT] in Jim)
--   nosBoostLevel 1/2/3 boost level  — from the hk_nosBoostLevel player statebag ([HK EDIT] in Jim)
--   nosColor      purge smoke colour 'r,g,b' from GlobalState.nosColour[plate]
local nosAmount    = 0
local nosHasNos    = false
local nosPurgeMode = false
local nosBoostLevel = 1
local nosColor     = nil
local nosOverheat  = false   -- NOS held too long (Jim damageTimer > 7) -> red glow behind bar

-- Seatbelt + harness state — polled authoritatively from jim-mechanic each tick.
local seatbeltOn = false
local harnessOn  = false

-- RPM smoothing
local smoothRpm = 0.0
-- EV regen display smoothing — hk-handling's raw regen level jitters per frame; EMA it
-- so the red/regen bar glides instead of bouncing (esp. in one-pedal mode).
local regenSmooth = 0.0
local REGEN_LERP = 0.15
-- SEMI/KERS hybrid charge-arc smoothing (its own EMAs — a semi keeps its normal tach,
-- so the thin arc rides ALONGSIDE the rpm ring, not the EV split-ring): charge = regen
-- on lift (green), boost = e-assist on throttle (amber). Two ends of one thin arc.
local semiChargeSmooth = 0.0
local semiBoostSmooth  = 0.0
local shiftCooldown = 0
local SHIFT_LERP_FRAMES = 12
local SHIFT_LERP_SLOW = 0.08
local SHIFT_LERP_FAST = 0.35

-- Slow-state throttle: the expensive cross-resource polls (seatbelt/harness/NOS/
-- handbrake/gearbox exports) + lights/lock/fuel run every STATE_TICK_EVERY frames
-- (~250ms at 60fps), not every frame — and only emit a NUI 'state' message when a
-- value actually changed. This is the main FPS fix.
local stateTick = 0
local STATE_TICK_EVERY = 15
local lastStateHash = nil

-- Detect unit preference
local function detectUnitPreference()
    if Config.SpeedUnit == 'kmh' then
        useMetric = true
    elseif Config.SpeedUnit == 'mph' then
        useMetric = false
    else
        local setting = GetProfileSetting(14)
        useMetric = (setting ~= 0)
    end
end

-- Top-speed baseline. Two sources, we take the LOWER (safer — neither can inflate):
--   1. native GetVehicleEstimatedMaxSpeed(veh): static estimate in m/s, INCLUDES mods.
--   2. handling fInitialDriveMaxFlatVel * 0.82 (mph): flat-out velocity basis.
-- Source 2 alone over-estimated badly on some cars (e.g. Lambo LP640 -> impossible
-- 440 km/h). The native estimate is more grounded; the min of both prevents either
-- outlier from blowing up the dial. If a car is genuinely faster than the baseline
-- (heavily modded/boosted), the live AUTO-EXTEND below grows the dial on the fly.
-- (Lesson from jg-handling: formulas mispredict; live measurement is truth.)
local FLATVEL_TO_MPH = 0.82

-- Real speedometers print a max WELL ABOVE the car's true top speed (Chiron prints
-- 500 but caps ~420). Rather than a precise fraction (both estimate sources are too
-- unreliable per-car — min under-shot the Chiron, the raw formula over-shot the LP640),
-- we add a generous FLAT headroom margin above the estimate and snap UP to a clean
-- cluster number. The true top then always sits comfortably below the dial max (never
-- pinned), and the live AUTO-EXTEND grows the dial for genuinely faster cars.
local HEADROOM_KMH = 90
local HEADROOM_MPH = 56

local GAUGE_FAMILY_KMH = { 120, 140, 160, 180, 200, 220, 240, 260, 280, 300, 320, 360, 400, 440, 500, 560 }
local GAUGE_FAMILY_MPH = {  80,  90, 100, 120, 140, 160, 180, 200, 220, 240, 260, 300, 340 }

-- Snap UP to the smallest family value >= target (so the dial always clears the top).
local function snapUpFamily(value, family)
    for _, v in ipairs(family) do
        if v >= value then return v end
    end
    return family[#family]
end

-- The estimated real top speed in DISPLAY units (kmh/mph) — the HIGHER of the two
-- sources so we never under-shoot (the min approach made the Chiron read too low).
local function estimateTopDisplay(veh)
    -- Source 1: native estimate (m/s, includes mods)
    local estMs = GetVehicleEstimatedMaxSpeed(veh) or 0.0
    local estMph = estMs * 2.236936

    -- Source 2: handling flat-out velocity
    local flatVel = GetVehicleHandlingFloat(veh, 'CHandlingData', 'fInitialDriveMaxFlatVel') or 0.0
    local flatMph = flatVel * FLATVEL_TO_MPH

    -- Take the HIGHER valid one (never under-shoot). Fall back to whichever is >0.
    local topMph = math.max(estMph, flatMph)
    if topMph <= 0 then return nil end

    return useMetric and (topMph * 1.609344) or topMph
end

-- Dial max = estimated top + a flat headroom margin, snapped up to a clean number.
-- Generous by design (a slightly oversized dial just seats the needle lower, which is
-- harmless), and auto-extend handles anything that still exceeds it.
local function calcGaugeMax(veh)
    local topDisplay = estimateTopDisplay(veh)
    if not topDisplay or topDisplay <= 0 then
        return useMetric and 300 or 180
    end

    local margin = useMetric and HEADROOM_KMH or HEADROOM_MPH
    local target = topDisplay + margin
    local family = useMetric and GAUGE_FAMILY_KMH or GAUGE_FAMILY_MPH
    -- snapUpFamily already guarantees gaugeMax >= target > topDisplay, so the dial
    -- always clears the true top — no extra safety clamp needed.
    return snapUpFamily(target, family)
end

-- AUTO-EXTEND: bump the dial one step up the family. Used live when a car is actually
-- faster than the baseline predicted (modded/boosted). Returns the same value if it's
-- already at the top of the family.
local function nextGaugeStep(current)
    local family = useMetric and GAUGE_FAMILY_KMH or GAUGE_FAMILY_MPH
    for _, v in ipairs(family) do
        if v > current then return v end
    end
    return current
end

-- Helpers
local function isInVehicle()
    local ped = PlayerPedId()
    return IsPedInAnyVehicle(ped, false) and GetPedInVehicleSeat(GetVehiclePedIsIn(ped, false), -1) == ped
end

local function getSpeed(veh)
    if useMetric then
        return GetEntitySpeed(veh) * 3.6
    else
        return GetEntitySpeed(veh) * 2.236936
    end
end

-----------------------------------------------------------------
-- NOS DETECTION
-- jim-mechanic fires a LOCAL event while boosting / on level change:
--   TriggerEvent("hud:client:UpdateNitrous", level, hasNitro, toggle)
--   toggle = true while actively firing NOS
-----------------------------------------------------------------
AddEventHandler('hud:client:UpdateNitrous', function(level, hasNitroOrToggle, toggleOrNil)
    if toggleOrNil ~= nil then
        nosLevel = level or 0
        nosHasNitro = hasNitroOrToggle or false
        nosBoostActive = toggleOrNil or false
    else
        nosLevel = level or 0
        nosBoostActive = hasNitroOrToggle or false
        nosHasNitro = true
    end
end)

-----------------------------------------------------------------
-- NOS BOOST-LEVEL + PURGE — read from jim-mechanic's player statebag.
-- Jim keeps boostLevel (1-3) and purgemode as resource-globals with no cross-resource
-- exposure, so we added a tiny [HK EDIT] in Jim's nitrous/_main.lua that publishes both
-- to the player statebag on every level/purge key press (KEYBIND-INDEPENDENT — it hooks
-- Jim's command handlers, not raw control ids, so player rebinds are respected):
--   LocalPlayer.state.hk_nosBoostLevel  (number 1-3)
--   LocalPlayer.state.hk_nosPurgeMode   (bool)
-- We read those here. If Jim is updated and the [HK EDIT] is lost, this simply falls
-- back to the defaults (level 1, purge off) — no errors.
-----------------------------------------------------------------
-- Only react to OUR OWN player bag (nil filter = all players; check inside). The
-- serverId is resolved per-event so it's always current, never a stale load-time value.
local function isMyPlayerBag(bagName)
    return bagName == ('player:%s'):format(GetPlayerServerId(PlayerId()))
end

AddStateBagChangeHandler('hk_nosBoostLevel', nil, function(bagName, _, value)
    if not isMyPlayerBag(bagName) then return end
    local lvl = math.floor(tonumber(value) or 1)
    if lvl >= 1 and lvl <= 3 then nosBoostLevel = lvl end
end)

AddStateBagChangeHandler('hk_nosPurgeMode', nil, function(bagName, _, value)
    if not isMyPlayerBag(bagName) then return end
    nosPurgeMode = value and true or false
end)

-- Overheat: true once NOS has been HELD too long (Jim's damageTimer > 7, the point
-- where the engine starts taking damage). Drives a red glow-bloom behind the NOS bar.
AddStateBagChangeHandler('hk_nosOverheat', nil, function(bagName, _, value)
    if not isMyPlayerBag(bagName) then return end
    nosOverheat = value and true or false
end)

-- ABS / TC driver-assist OFF state (hk-handling publishes these when the player toggles
-- via /abs /tc or the F1 radial menu). true = the assist is OFF -> the pill shows the
-- fading OFF look (else solid green ON). Player-scoped bags, same pattern as NOS above.
AddStateBagChangeHandler('hk_abs_off', nil, function(bagName, _, value)
    if not isMyPlayerBag(bagName) then return end
    absOff = value and true or false
end)
AddStateBagChangeHandler('hk_tc_off', nil, function(bagName, _, value)
    if not isMyPlayerBag(bagName) then return end
    tcOff = value and true or false
end)

-- AUTO-BLINKER pill (hk-handling publishes hk_blinker when the player toggles LAlt).
-- Payload { armed = bool }. Pill just pulses when armed. Player-scoped bag, same pattern as ABS/TC.
AddStateBagChangeHandler('hk_blinker', nil, function(bagName, _, value)
    if not isMyPlayerBag(bagName) then return end
    if type(value) == 'table' then
        blinkerArmed = value.armed and true or false
    else
        blinkerArmed = false
    end
end)

-- hk-handling's /handlingdbg overlay is native DrawText, which renders BEHIND this
-- NUI gauge. While it's on, hide the speedo so the debug columns are readable; the
-- main loop re-shows it (respecting showReady + pause/menu state) once it's off.
AddStateBagChangeHandler('hk_handlingdbg', nil, function(bagName, _, value)
    if not isMyPlayerBag(bagName) then return end
    dbgHidden = value and true or false
    if dbgHidden then
        SendNUIMessage({ type = 'hide' })
        SendNUIMessage({ type = 'revlimit', active = false })
    elseif showReady and not IsPauseMenuActive() then
        SendNUIMessage({ type = 'show' })
    end
end)

-----------------------------------------------------------------
-- SEATBELT + HARNESS DETECTION
-- Read jim-mechanic AUTHORITATIVELY, exactly like its own odometer does:
--   exports['mechanic']:seatBeltOn()  -> true when the seatbelt is buckled
--   exports['mechanic']:HasHarness()  -> true when a harness is worn
-- Both are valid because Jim's HarnessControl = true. This is keybind-independent
-- and never desyncs — unlike flipping a local bool on the toggle event (which drifts
-- if an event is missed or fires with an unexpected arg — that was the belt bug).
-- Polled every frame in the main tick; cheap boolean exports.
-----------------------------------------------------------------
local function detectSeatbelt()
    local ok, result = pcall(function()
        return exports['mechanic']:seatBeltOn()
    end)
    if ok and type(result) == 'boolean' then
        seatbeltOn = result
    end
    return seatbeltOn
end

local function detectHarness()
    local ok, result = pcall(function()
        return exports['mechanic']:HasHarness()
    end)
    if ok and type(result) == 'boolean' then
        return result
    end
    return false
end

-----------------------------------------------------------------
-- NOS STATE for NUI
-- Returns: 'off', 'purge', 'boost'
-- Detected via jim-mechanic's hud:client:UpdateNitrous event (toggle flag)
-----------------------------------------------------------------
local function getNOSState(veh)
    -- Event-based: jim fires UpdateNitrous with toggle=true while boosting
    if nosBoostActive then
        return 'boost'
    end
    -- If car has NOS installed, show "purge" (ready/pulsing) state
    if nosHasNitro and nosLevel > 0 then
        return 'purge'
    end
    return 'off'
end

-----------------------------------------------------------------
-- NOS INSTALL + REMAINING AMOUNT from jim-mechanic's GetNosLevel export
-- (resource folder = 'mechanic'). Returns level 0..100 and whether NOS is fitted.
-- This is the authoritative "does this car have NOS" + "how much is left" source;
-- purge/boostLevel come from the statebags above. Refreshed each tick (cheap).
-----------------------------------------------------------------
local function refreshNos(veh)
    local ok, level, hasnitro = pcall(function()
        return exports['mechanic']:GetNosLevel(veh)
    end)
    if ok and hasnitro ~= nil then
        nosHasNos = hasnitro and true or false
        nosAmount = tonumber(level) or 0
    else
        nosHasNos = false
        nosAmount = 0
    end
    if not nosHasNos then
        -- no NOS fitted -> clear derived state so the bar/button hide cleanly
        nosPurgeMode = false
        nosColor = nil
        return
    end
    -- Purge smoke colour for this plate (GlobalState.nosColour is keyed by trimmed
    -- plate and readable from any client). Format as an "r,g,b" string for the NUI.
    local col = nil
    local ok2, gs = pcall(function() return GlobalState.nosColour end)
    if ok2 and type(gs) == 'table' then
        local plate = GetVehicleNumberPlateText(veh)
        if plate then
            plate = plate:gsub('%s+', '')
            local c = gs[plate]
            if type(c) == 'table' and c[1] then
                col = ('%d,%d,%d'):format(c[1] or 255, c[2] or 255, c[3] or 255)
            end
        end
    end
    nosColor = col
end

-----------------------------------------------------------------
-- GEAR DETECTION
-- Priority: hk-handling export > native
-----------------------------------------------------------------
-- FREE-REV RPM OVERRIDE. During a brake-held free-rev (neutral + S + throttle), hk-handling sits the
-- car in native gear 1 stopped, and GTA's engine sim caps GetVehicleCurrentRpm at ~0.6 (clutch-slip
-- equilibrium) even though the true limiter rpm is ~1.0 (the audio screams from the painted value).
-- hk-handling exposes its OWN painted rpm via GetFreeRevRpm; prefer it so the needle + redline match
-- the audio. Returns nil when not free-revving -> caller keeps the native GetVehicleCurrentRpm.
local function getFreeRevRpm()
    local ok, result = pcall(function()
        return exports['hk-handling']:GetFreeRevRpm()
    end)
    if ok and type(result) == 'number' then return result end
    return nil
end

local function getDisplayGear(veh)
    -- Try hk-handling export first
    local ok, result = pcall(function()
        return exports['hk-handling']:GetDisplayGear(veh)
    end)
    if ok and result ~= nil then
        -- result can be 'R', 'N', or a number
        if result == 'R' then return -1 end
        if result == 'N' then return 0 end
        return tonumber(result) or 0
    end

    -- Fallback: native gear. GTA native gear 0 is BOTH reverse and neutral (there's no
    -- separate neutral gear), so we can't tell them apart from the gear number alone.
    -- Distinguish by RELATIVE velocity: GetEntitySpeedVector(veh, true).y is +forward /
    -- -backward. Gear 0 + moving backward past a small threshold = Reverse (-1); gear 0
    -- otherwise (stationary / rolling forward) = Neutral (0).
    local nativeGear = GetVehicleCurrentGear(veh)
    if nativeGear == 0 then
        local rel = GetEntitySpeedVector(veh, true)
        if rel and rel.y < -0.5 then
            return -1   -- actually reversing
        end
        return 0        -- neutral (stopped or not moving backward)
    end
    return nativeGear
end

-- Detect drift state
local function detectDrift(veh)
    local ok, result = pcall(GetDriftTyresEnabled, veh)
    if ok then return result end
    return false
end

-- Door lock: native GetVehicleDoorLockStatus — 2 = locked, 1 = unlocked (0 = none).
-- Keybind/resource independent (qb-vehiclekeys drives this native under the hood).
local function detectLocked(veh)
    return GetVehicleDoorLockStatus(veh) == 2
end

-- HEADLIGHTS: 0 = off, 1 = low beam on, 2 = high beam on. GetVehicleLightsState returns
-- (ok, lightsOn, highBeamsOn). High beam implies lights on, so it wins the 2 slot.
local function detectLights(veh)
    local ok, lightsOn, highOn = GetVehicleLightsState(veh)
    if not ok then return 0 end
    if highOn == 1 or highOn == true then return 2 end
    if lightsOn == 1 or lightsOn == true then return 1 end
    return 0
end

-- Hands up (qb-smallresources export). Only true while the player has hands raised.
local function detectHandsup()
    local ok, up = pcall(function()
        return exports['qb-smallresources']:getHandsup()
    end)
    return (ok and up) and true or false
end

-- NIGHT MODE + BACKLIGHT COLOUR.
-- Night = in-game hour >= 18 or < 6 (GetClockHours is 0..23). Backlight colour is the
-- car's underglow neon colour IF any neon side is on, else white. GTA stores ONE neon
-- colour per vehicle (the 4 sides are just on/off), so "colour" is that single RGB;
-- the visual blend between lit/unlit sides is handled purely in CSS. Returns:
--   night (bool), 'r,g,b' colour string.
local function detectNight(veh)
    local hour = GetClockHours()
    local night = (hour >= 18 or hour < 8)   -- 18:00 -> 08:00
    if not night then return false, nil end

    local anyNeon = IsVehicleNeonLightEnabled(veh, 0) or IsVehicleNeonLightEnabled(veh, 1)
        or IsVehicleNeonLightEnabled(veh, 2) or IsVehicleNeonLightEnabled(veh, 3)
    if anyNeon then
        local r, g, b = GetVehicleNeonLightsColour(veh)
        return true, ('%d,%d,%d'):format(r or 255, g or 255, b or 255)
    end
    return true, '170,170,170'    -- soft light-grey (#aaaaaa) backlight when no underglow
                                  -- (a dark grey like #424242 emits no visible glow —
                                  --  a backlight needs a LIGHT colour to read as a glow)
end

-- Detect handbrake. Two sources OR'd together:
--   1. the native e-brake (GetVehicleHandbrake) — normal pull.
--   2. hk-handling's PARK state — our box "starts parked" in a LOGICAL neutral that
--      the native handbrake flag doesn't reflect, so poll the export. The lamp then
--      lights on entry (car sat parked) until the driver taps handbrake to release.
local function detectHandbrake(veh)
    if GetVehicleHandbrake(veh) then return true end
    local ok, parked = pcall(function()
        return exports['hk-handling']:IsParkBraked(veh)
    end)
    if ok and parked then return true end
    return false
end

-----------------------------------------------------------------
-- GEARBOX MODE detection (manual vs auto/DCT)
-- 'manual' = clutch manual / sequential dogbox  -> full glow feedback
-- 'auto'   = comfort auto / any DCT variant      -> blue-only glow
-- nil      = raw GTA native (no hk-handling box)  -> treat as auto (blue only)
-----------------------------------------------------------------
local function getGearboxMode(veh)
    local ok, result = pcall(function()
        return exports['hk-handling']:GetGearboxMode(veh)
    end)
    if ok and result then return result end
    return nil  -- unknown / native -> caller treats as auto
end

-----------------------------------------------------------------
-- EV/HYBRID REGEN — live regenerative-braking signal from hk-handling. Pull model,
-- same convention as GetGearboxMode. Returns { level 0..1, mode, holding, active }.
-- Display-only: hk-handling owns all the physics; we just render regen as braking on
-- the EV power meter (motor braking on lift, no brake pedal needed). Safe zeroed
-- fallback when the export/car isn't an EV or hk-handling isn't applied.
-----------------------------------------------------------------
local REGEN_ZERO = { level = 0.0, mode = 'onepedal', holding = false, active = false }
local function getRegen()
    local ok, result = pcall(function()
        return exports['hk-handling']:GetRegenLevel()
    end)
    if ok and type(result) == 'table' then return result end
    return REGEN_ZERO
end

-----------------------------------------------------------------
-- DRIVETRAIN — the car's native layout (RWD/FWD/AWD) + power bias, from hk-handling.
-- Pull model, same convention. Returns { layout='RWD'|'FWD'|'AWD', bias=0..1 } or nil.
-- bias: 0 = fully rear, 1 = fully front. Stable (won't flip on momentary AWD-assist
-- bias shifts). nil -> unknown/not applied; we then show no drivetrain badge.
-----------------------------------------------------------------
local function getDrivetrain()
    -- Use GetDriveClass and read its ROUTING class (0.49/0.61 cut), not the true-layout label
    -- (0.10/0.90 cut). The pill must agree with what /handlingdbg shows and how the car actually
    -- DRIVES — e.g. redeye at fDriveBiasFront=0.10 routes RWD, but the strict <0.10 layout test
    -- mislabels it AWD. `class` is 'rwd'|'awd'|'fwd'; uppercase it into the pill's layout field.
    local ok, result = pcall(function()
        return exports['hk-handling']:GetDriveClass()
    end)
    if ok and type(result) == 'table' and result.class then
        return { layout = string.upper(result.class), bias = result.bias }
    end
    return nil
end

-----------------------------------------------------------------
-- DRIVE STATE (combined) — one bundled export from hk-handling with everything the
-- speedo needs for EV/hybrid rendering, so we make ONE call/frame instead of four.
-- Returns (never nil from hk-handling; we still guard for when it's not started):
--   { isHybrid, isEV, electricNow, regen={level,mode,holding,active},
--     gearboxMode='manual'|'auto'|nil, indicator={icon='E'|'BOLT',color=...}|nil,
--     gearLabel='D'|nil }
-- electricNow flips LIVE as a hybrid crosses e-mode<->ICE (hold-G), so poll per frame.
-----------------------------------------------------------------
local DS_ZERO = { isHybrid = false, isEV = false, electricNow = false,
                  regen = REGEN_ZERO, gearboxMode = nil, indicator = nil, gearLabel = nil }
local function getDriveState()
    local ok, result = pcall(function()
        return exports['hk-handling']:GetVehicleDriveState()
    end)
    if ok and type(result) == 'table' then return result end
    return DS_ZERO
end

-----------------------------------------------------------------
-- LAUNCH-CONTROL render state. Maps hk-handling's launch signal to the 5 pill looks the
-- speedo renders. hk-handling is the SINGLE SOURCE OF TRUTH — we only translate, never
-- compute launch logic here.
--   'off'   -> not launch-capable / nothing happening      (pill hidden)
--   'idle'  -> launch-capable neutral, ready, no input yet  (grey)
--   'prep'  -> handbrake held, staging (not yet armed)      (grey box + red pulse)
--   'armed' -> phase 'staged' (throttle held, about to fire)(solid red + red pulse)
--   'boost' -> phase 'launched' (boost window active)       (gold + gold pulse)
-- 'lc' fields: phase ('off'|'staged'|'launched'), plus the diagnostic lcSeen (in a
-- launch-capable neutral this frame) + lcHb (handbrake seen by the launch tick). Those
-- diagnostics are what let us show the pre-stage 'idle'/'prep' looks before 'staged'.
-- lc fields used: phase ('off'|'staged'|'launched'), plus the clean per-frame signals
-- inNeutral (in a launch-capable neutral THIS frame) + hb (handbrake held). The bag
-- variant names them launchNeutral/launchHb — normalize before calling this.
--
-- The pill only appears once the player is ACTUALLY STAGING — i.e. in a launch-capable
-- neutral WITH the handbrake held. Just sitting in neutral (no handbrake) shows nothing:
-- otherwise the LC pill popped up on EVERY stop-in-neutral, for every launch-capable car.
-- Flow: hidden -> (neutral + handbrake) grey box + red pulse -> (throttle) solid red ->
-- (launched) gold -> hidden when boost ends / handbrake released without launching.
local function resolveLaunchState(phase, inNeutral, hb)
    if phase == 'launched' then return 'boost' end       -- gold
    if phase == 'staged'   then return 'armed' end        -- solid red (throttle held)
    -- phase 'off': show ONLY while staging (neutral + handbrake). No bare-neutral 'idle'.
    if inNeutral and hb then return 'prep' end            -- grey box + red pulse
    return 'off'
end

local function getLaunchRender()
    if GetResourceState('hk-handling') ~= 'started' then return 'off' end
    local ok, lc = pcall(function() return exports['hk-handling']:GetLaunchState() end)
    if not ok or type(lc) ~= 'table' then return 'off' end
    return resolveLaunchState(lc.phase or 'off', lc.inNeutral == true, lc.hb == true)
end

-- DRIVE-STATE NETWORK BRIDGE (driver -> passengers) --------------------------------
-- hk-handling's GetVehicleDriveState reads DRIVER-LOCAL module state, so a passenger's
-- own client returns all-false for it (the gearbox is only "applied" on the driver's
-- client). To give passengers the real EV/hybrid readout, the DRIVER (the vehicle's
-- network owner) publishes a compact snapshot to a REPLICATED statebag on the vehicle;
-- passengers read it back. Only the fields the passenger panel renders are synced.
local DRIVE_BAG = 'hk_drivestate'

-- NOTE: publishDriveState() was REMOVED. hk-handling now publishes the `hk_drivestate` bag
-- from its own tick (the SOURCE owns the push), so the speedo no longer pulls-then-republishes.
-- The driver still reads its own live state via getDriveState() (local, instant); passengers
-- read the bag via readDriveStateBag() below — now written by hk-handling, same field shape.

-- Called by the PASSENGER loop: read the driver-published bag. Returns the snapshot
-- table, or nil if the driver isn't running hk-speedo / hasn't published yet.
local function readDriveStateBag(veh)
    if not veh or veh == 0 then return nil end
    local ent = Entity(veh)
    if not ent or not ent.state then return nil end
    local ok, v = pcall(function() return ent.state[DRIVE_BAG] end)
    if ok and type(v) == 'table' then return v end
    return nil
end

-----------------------------------------------------------------
-- REDLINE — the real rev-limiter point from hk-handling, so the shift-lights and
-- redline flicker arm exactly when the box limits (not a hardcoded 0.85). Resolved
-- once on vehicle entry/change and cached; falls back to Config or 0.85.
-----------------------------------------------------------------
local function resolveRedline()
    local ok, result = pcall(function()
        return exports['hk-handling']:GetRevLimiterRedline()
    end)
    if ok and type(result) == 'number' and result > 0 then
        return result
    end
    return Config.RedlineRPM or 0.85
end

-----------------------------------------------------------------
-- GEAR SHIFT GLOW
-- Every shift (up or down) flashes BLUE only. No green/red quality glow.
-- Gold "perfect shift" is handled separately and gated to manual mode.
-----------------------------------------------------------------
local function checkShiftQuality(veh, currentGear, currentRpm)
    -- Any gear change flashes blue — INCLUDING shifts into/out of neutral (0) and
    -- reverse (-1). gearReady gates only the very first read so entry doesn't false-fire.
    if gearReady and currentGear ~= lastGear then
        -- EVs are single-speed (shown as 'D'): suppress the glow for forward<->forward
        -- internal shifts (both gears >= 1), but STILL flash on R/N transitions
        -- (either side is <= 0, e.g. N->D, D->R, R->N).
        if currentElectric and currentGear >= 1 and lastGear >= 1 then
            return nil, 300
        end
        return 'blue', 300
    end
    return nil, 300
end

-----------------------------------------------------------------
-- PERFECT SHIFT EVENT (from hk-handling gearbox)
-- Only show the gold glow when the box is in MANUAL mode. Auto/DCT boxes
-- never get gold — the driver isn't timing the shift, so blue only.
-----------------------------------------------------------------
AddEventHandler('hk-speedo:perfectShift', function()
    local veh = GetVehiclePedIsIn(PlayerPedId(), false)
    if veh == 0 then return end
    if getGearboxMode(veh) == 'manual' then
        SendNUIMessage({ type = 'glow', glow = 'gold', duration = 600 })
    end
end)

-- Regen LEVEL change (Coast/D1/D2/D3) — fire-and-forget from hk-handling. `level` is an
-- integer 0..3 (0=Coast,1=D1,2=D2,3=D3). Flash the level indicator on the EV meter.
AddEventHandler('hk-speedo:regenMode', function(level)
    SendNUIMessage({ type = 'regenMode', level = level })
end)

-- Hybrid e-mode<->ICE toggle (hold-G) — fire-and-forget. `userMode` = 'ev'|'normal'.
-- The live state is already polled via ds.electricNow each frame; this just flashes the
-- mode indicator on the toggle so the switch reads instantly.
AddEventHandler('hk-speedo:hybridMode', function(userMode)
    SendNUIMessage({ type = 'hybridMode', mode = userMode })
end)

-----------------------------------------------------------------
-- DISPLAY MODE (full / lite / minimal) — per-player, saved to SQL via server.lua.
-- /speedo cycles the mode; the choice is pushed to the NUI (which drops glow/vibration
-- rendering + switches to the minimal rectangle as needed) and saved server-side.
-----------------------------------------------------------------
local function applyMode(mode, save)
    if mode ~= 'normal' and mode ~= 'lite' and mode ~= 'full' and mode ~= 'minimal' then
        mode = 'normal'
    end
    speedoMode = mode
    SendNUIMessage({ type = 'mode', mode = mode })
    if save then
        TriggerServerEvent('hk-speedo:saveMode', mode)
    end
end

-- Load the saved mode once the framework/player is ready.
CreateThread(function()
    while not Config do Wait(100) end
    Wait(1500)   -- let qb-core + player data settle before the callback
    QBCore = QBCore or (exports['qb-core'] and exports['qb-core']:GetCoreObject())
    if QBCore and QBCore.Functions and QBCore.Functions.TriggerCallback then
        QBCore.Functions.TriggerCallback('hk-speedo:getMode', function(mode)
            applyMode(mode or 'normal', false)
        end)
    end
end)

RegisterCommand('speedo', function()
    -- Cycle normal -> lite -> full -> minimal -> normal (MODE_ORDER)
    local idx = 1
    for i, m in ipairs(MODE_ORDER) do if m == speedoMode then idx = i break end end
    local nextMode = MODE_ORDER[(idx % #MODE_ORDER) + 1]
    applyMode(nextMode, true)
    local labels = {
        normal = 'NORMAL (recommended)',
        lite = 'LITE (best FPS)',
        full = 'FULL (max glow, heaviest)',
        minimal = 'MINIMAL',
    }
    QBCore = QBCore or (exports['qb-core'] and exports['qb-core']:GetCoreObject())
    if QBCore and QBCore.Functions and QBCore.Functions.Notify then
        QBCore.Functions.Notify('Speedo mode: ' .. (labels[nextMode] or nextMode), 'primary', 2500)
    else
        print('[hk-speedo] mode -> ' .. nextMode)
    end
end, false)

-- (No default keybind — the speedo mode toggle lives in the hk-hub settings page now.
--  The /speedo command stays registered so hk-hub / console can invoke it.)

-- Show /speedo in the hk-chat `/` autocomplete palette (player-facing, everyone).
CreateThread(function()
    Wait(1500)  -- let hk-chat come up first
    TriggerEvent('chat:addSuggestion', '/speedo',
        'Cycle speedo cluster style: normal -> lite -> full -> minimal', {})
end)

-----------------------------------------------------------------
-- MAIN TICK
-----------------------------------------------------------------
Citizen.CreateThread(function()
    while not Config do Citizen.Wait(100) end
    if not Config.Enabled then return end

    detectUnitPreference()

    while true do
        Citizen.Wait(Config.TickRate or 16)

        if isInVehicle() then
            local ped = PlayerPedId()
            local veh = GetVehiclePedIsIn(ped, false)

            -- STAGE 1 (READY): we're in the driver's seat. Prep per-vehicle values once,
            -- but DON'T show the speedo yet — it only engages when the engine is on.
            if not vehReady then
                vehReady = true
                revLimiting = false
                smoothRpm = 0.0
                gearReady = false   -- re-arm so entering in-gear doesn't false-flash
                currentMaxSpeed = calcGaugeMax(veh)
                currentRedline = resolveRedline()
                baseModelElectric = GetIsVehicleElectric(GetEntityModel(veh))
                currentElectric = baseModelElectric
                seatbeltOn = detectSeatbelt()
            end

            -- Recalculate if vehicle changed (e.g. swapped seats into a different car)
            if veh ~= lastVehicle and lastVehicle ~= 0 then
                currentMaxSpeed = calcGaugeMax(veh)
                currentRedline = resolveRedline()
                baseModelElectric = GetIsVehicleElectric(GetEntityModel(veh))
                currentElectric = baseModelElectric
                gearReady = false   -- new car: re-arm the shift-glow gate
            end
            lastVehicle = veh

            -- STAGE 2 (ENGAGE): the speedo powers up only when the engine is running,
            -- and powers down (but stays ready) when it's shut off while still seated.
            local engineOn = GetIsVehicleEngineRunning(veh)

            if engineOn and not showing then
                -- Engine just came on — engage after a short buffer (ignore flicker on
                -- quick restarts / stalls). The self-test sweep runs inside animateIn.
                showing = true
                engagePending = engagePending + 1
                local myEngage = engagePending
                Citizen.SetTimeout(600, function()
                    -- Still seated + still running + this is the latest engage request?
                    if myEngage == engagePending and isInVehicle()
                        and GetIsVehicleEngineRunning(GetVehiclePedIsIn(PlayerPedId(), false)) then
                        showReady = true
                        if not dbgHidden then SendNUIMessage({ type = 'show' }) end
                    else
                        showing = false
                        showReady = false
                    end
                end)
            elseif not engineOn and showing then
                -- Engine shut off while still in the car — power the gauge down but keep
                -- READY, so turning it back on re-engages with the power-up animation.
                showing = false
                showReady = false
                engagePending = engagePending + 1   -- cancel any pending engage
                revLimiting = false
                sentSpeed, sentGear, tickSettle = -1, -999, 0  -- force fresh tick on re-engage
                sentLc = 'off'                                 -- re-push launch pill state
                SendNUIMessage({ type = 'hide' })
                SendNUIMessage({ type = 'revlimit', active = false })
            end

            -- While the engine is off (ready but not engaged), skip the telemetry work.
            if not showReady then
                Citizen.Wait(120)
                goto continue
            end

            -- Pause menu / map is open: NUI would draw on top of it, so hide the
            -- speedo while it's up and restore it once the menu closes.
            if IsPauseMenuActive() then
                if showReady and not menuHidden then
                    menuHidden = true
                    SendNUIMessage({ type = 'hide' })
                    SendNUIMessage({ type = 'revlimit', active = false })
                end
                Citizen.Wait(150)
            elseif menuHidden then
                menuHidden = false
                if showReady and not dbgHidden then
                    SendNUIMessage({ type = 'show' })
                end
            else

            -- ===== FAST path (every frame) — ONLY what the eye tracks: speed, rpm,
            -- gear, redline flicker + shift glow. These are cheap natives + one gear
            -- export; NO per-frame Jim/NOS/light polling (that's the slow path below,
            -- which is what was costing the frametime). =====
            local speed = getSpeed(veh)
            local rpm = GetVehicleCurrentRpm(veh)
            -- FREE-REV OVERRIDE: while brake-held free-revving, GTA caps native rpm at ~0.6 in a
            -- stopped gear 1; use hk-handling's painted value so the needle reaches the real limiter.
            local frRpm = getFreeRevRpm()
            if frRpm then rpm = frRpm end
            local gear = getDisplayGear(veh)

            -- DRIVE STATE (per frame): one combined hk-handling call. A HYBRID flips
            -- e-mode<->ICE live via hold-G, so we can't cache electric at entry — poll it.
            --   currentElectric = "electric right now" = pure EV OR hybrid in e-mode
            --   (drives the EV meter look, D/gear label, no-redline, etc.)
            local ds = getDriveState()
            isHybridVeh = ds.isHybrid == true
            electricNow = ds.electricNow == true
            -- baseModelElectric = the static GetIsVehicleElectric set at entry (pure EVs).
            currentElectric = baseModelElectric or electricNow

            -- NOTE: the drive-state statebag (hk_drivestate) is now PUBLISHED BY hk-handling
            -- itself (from its own tick), so passengers already get the EV/hybrid readout with
            -- no work here. The speedo no longer republishes — that duplicate push was removed.

            -- AUTO-EXTEND (cheap per-frame compare; rebuild only on the rare crossing).
            -- If a car is actually faster than the baseline predicted (modded/boosted)
            -- and the needle nears the end of the dial (~92%), grow the dial one step so
            -- it never pins at max. Resets to the baseline on next vehicle entry (the
            -- 'not vehReady' block recomputes currentMaxSpeed), so no lasting cost.
            if speed > currentMaxSpeed * 0.92 then
                local grown = nextGaugeStep(currentMaxSpeed)
                if grown > currentMaxSpeed then
                    -- Picked up by the throttled 'state' message (its hash includes
                    -- currentMaxSpeed) within ~250ms; JS rebuilds the tick marks then.
                    currentMaxSpeed = grown
                end
            end

            -- Gear-based idle RPM (visual only): at idle the game reports a flat idle
            -- rpm regardless of gear, so the needle looks frozen. Add a small per-gear
            -- offset that ONLY applies while idling (low real rpm) and fades out as the
            -- engine revs, so switching gears at a stop visibly nudges the needle but it
            -- never affects real driving. Higher gear = slightly higher resting rpm.
            local rpmTarget = rpm
            if rpm < 0.40 then
                local g = gear
                if g < 0 then g = 1 end                  -- reverse ~ 1st for this purpose
                -- Bigger + wider-fading bias so shifting at a stop VISIBLY nudges the
                -- needle (the old 0.008 * heavy fade was ~27rpm — too small to see).
                local idleFactor = 1 - (rpm / 0.40)       -- 1 at true idle -> 0 by 0.40
                local gearBias = math.min(g, 6) * 0.022   -- ~0.022 normalised rpm per gear
                rpmTarget = rpm + gearBias * idleFactor
            end

            -- RPM smoothing
            if gear ~= lastGear and lastGear ~= 0 and gear ~= 0 then
                shiftCooldown = SHIFT_LERP_FRAMES
            end
            if shiftCooldown > 0 then
                shiftCooldown = shiftCooldown - 1
                smoothRpm = smoothRpm + (rpmTarget - smoothRpm) * SHIFT_LERP_SLOW
            else
                smoothRpm = smoothRpm + (rpmTarget - smoothRpm) * SHIFT_LERP_FAST
            end
            local rpmDisplay = smoothRpm * (Config.MaxRPM or 9000)

            -- Glow/redline effects run in the FANCY tier (NORMAL + FULL). Normal renders
            -- them cheaply (glow halos), full uses the heavy live blur — but both WANT the
            -- rev-limiter/redline logic. Lite/minimal skip it entirely for the FPS win.
            if speedoMode == 'normal' or speedoMode == 'full' then
                -- Rev limiter (trigger at the real limiter point from hk-handling).
                -- EVs (Tesla 'plaid', i-Miev, etc.) sit near max rpm constantly, which
                -- would false-trigger the redline flicker — so disable it for electric.
                local atLimiter = (not currentElectric) and rpm >= (currentRedline - 0.003)
                if atLimiter and not revLimiting then
                    revLimiting = true
                    SendNUIMessage({ type = 'revlimit', active = true })
                elseif not atLimiter and revLimiting then
                    revLimiting = false
                    SendNUIMessage({ type = 'revlimit', active = false })
                end

                -- Shift glow (blue on any gear change)
                local glowType, glowDur = checkShiftQuality(veh, gear, rpm)
                if glowType then
                    SendNUIMessage({ type = 'glow', glow = glowType, duration = glowDur })
                end
            end

            -- Per-frame render payload — sent while anything is still MOVING, silent
            -- once everything has settled. "Moving" = a raw input changed, OR the
            -- Lua-side rpm is still easing toward its target, OR we're inside the speed
            -- settle window (the JS eases speed on its side, so we can't see its
            -- convergence from here — a frame countdown covers it).
            --   * rpmEasing uses the ACTUAL eased distance (not a coarse rpm deadband),
            --     so slow small transitions — like the gear-based idle-rpm nudge — get
            --     a smooth stream of ticks instead of jumping in 8-rpm deadband steps
            --     (that was the snappy/laggy idle transition).
            --   * When fully settled, nothing sends -> no bridge traffic, no repaint.
            -- EV power meter — TESLA-STYLE 3 ZONES:
            --   RIGHT (teal)  = throttle / power used
            --   LEFT GREEN    = regen (accelerator lifted, motor braking; from hk-handling)
            --   LEFT GRAY     = friction brake (brake PEDAL pressed) — SUPPRESSES green,
            --                   because a real Tesla prioritises friction brakes for pedal
            --                   feel (you don't show strong regen while foot-braking).
            -- throttle + brake come from the single GetVehicleThrottleOffset axis (+thr/
            -- -brake); regen comes from hk-handling (EMA-smoothed to stop the bounce).
            local throttle       = 0.0   -- right zone (power)
            local regenMag       = 0.0   -- left GREEN magnitude
            local frictionMag    = 0.0   -- left GRAY magnitude
            local braking        = false -- brake pedal down -> gray, suppress green
            local regenMode, regenHolding = nil, false
            -- The regen meter (full EV split-ring) shows for pure EVs AND full-LOOK hybrids
            -- (they regen on lift even in ICE mode). A SEMI-LOOK car is EXCLUDED — it uses the
            -- thin charge arc on the normal tach instead, even a semi-style PHEV in e-mode (its
            -- e-mode shows a throttle-driven green bar via emodeBar, not the split-ring).
            local showRegenMeter = (currentElectric or isHybridVeh) and not (ds.semiHybrid == true)
            if showRegenMeter then
                -- THROTTLE (right zone) — use the PLAYER'S PEDAL INPUT (control 71), NOT
                -- GetVehicleThrottleOffset. The offset is DRIVE-derived, so it briefly DROPS
                -- during the gearbox's background shift windows (drive cut for the rev-match) —
                -- on a hybrid/EV that fakes gears 1->2->3 to reach speed, the bar visibly dipped
                -- at each shift, exposing the "fake gear change" the EV should hide. The pedal
                -- input reflects what the DRIVER is asking for and is immune to those dips, so
                -- the bar stays smooth through the invisible shifts. Fallback to rpm if unread.
                local pInput = GetControlNormal(0, 71)
                if type(pInput) == 'number' then
                    throttle = math.max(0.0, math.min(1.0, pInput))
                else
                    throttle = math.max(0.0, math.min(1.0, rpm))  -- fallback: rpm proxy
                end

                -- BRAKE PEDAL from the actual control input (INPUT_VEHICLE_BRAKE = 72), NOT
                -- from a negative throttle offset. GetVehicleThrottleOffset only goes
                -- negative once the car is actually accelerating in REVERSE, so it never
                -- caught a forward-motion brake (grey only showed in reverse). The control
                -- normal reads the pedal 0..1 whichever direction you're moving.
                local pedalBrake = GetControlNormal(0, 72) or 0.0
                if pedalBrake < 0 then pedalBrake = 0.0 end
                if pedalBrake > 1 then pedalBrake = 1.0 end

                -- Regen from the combined drive-state, EMA-smoothed to stop the bounce.
                local regen = ds.regen or REGEN_ZERO
                local rTarget = regen.active and (regen.level or 0.0) or 0.0
                regenSmooth = regenSmooth + (rTarget - regenSmooth) * REGEN_LERP
                if regenSmooth < 0.004 then regenSmooth = 0.0 end
                -- mode = selected level ('coast'/'D1'/'D2'/'D3' for pure EV, 'hybrid' for
                -- hybrids). Published steadily regardless of throttle (read ALWAYS — else
                -- the gear flickered D<->D1/2/3 on throttle).
                regenMode = regen.mode or 'coast'
                regenHolding = regen.active and regen.holding and true or false

                local inForward = (gear >= 1)
                local BRAKE_PEDAL_THRESHOLD = 0.06

                -- GREEN regen and GRAY friction are INDEPENDENT layers (grey overlays green,
                -- it does NOT replace it). Both can be non-zero at once:
                --   GREEN regen    -> motor braking, forward gears only (no regen in reverse)
                --   GRAY friction  -> the brake PEDAL, shown WHENEVER it's pressed (forward
                --                     braking AND reverse) — control 72 reads it either way.
                regenMag = inForward and regenSmooth or 0.0
                if pedalBrake > BRAKE_PEDAL_THRESHOLD then
                    braking     = true
                    frictionMag = pedalBrake
                end
            else
                regenSmooth = 0.0
            end

            -- SEMI / KERS HYBRID (918/P1/LaFerrari): NOT an EV — it keeps its real tach +
            -- gears, so it does NOT use the EV split-ring above (showRegenMeter stays false).
            -- Instead a thin arc hugging the rpm ring shows the e-motor's live energy flow:
            --   GREEN charge  = regen on lift (ds.regen.active/.level while off-throttle)
            --   AMBER boost   = e-assist under throttle (ds.semiBoost, 0..1)
            -- Both EMA-smoothed on their own so the arc glides. Only one is non-zero at a
            -- time (you're either lifting or on the gas), but we compute both defensively.
            local isSemiVeh   = ds.semiHybrid == true
            -- EMODE-BAR: a semi-LOOK full PHEV (918/P1) that is electric RIGHT NOW. Its tach
            -- flips to a throttle-driven GREEN bar (no revs in e-mode); ICE mode shows real rpm.
            -- Only a semi-style PHEV sets this (a true KERS semi never has an e-mode).
            local emodeBar    = ds.emodeBar == true
            local semiCharge  = 0.0    -- green side (regen intensity)
            local semiBoostV  = 0.0    -- amber side (e-assist intensity)
            if isSemiVeh then
                local regen = ds.regen or REGEN_ZERO
                local cTarget = (regen.active and (gear >= 1 or gear == 0)) and (regen.level or 0.0) or 0.0
                semiChargeSmooth = semiChargeSmooth + (cTarget - semiChargeSmooth) * REGEN_LERP
                if semiChargeSmooth < 0.004 then semiChargeSmooth = 0.0 end
                local bTarget = ds.semiBoost or 0.0
                if bTarget < 0 then bTarget = 0.0 elseif bTarget > 1 then bTarget = 1.0 end
                semiBoostSmooth = semiBoostSmooth + (bTarget - semiBoostSmooth) * REGEN_LERP
                if semiBoostSmooth < 0.004 then semiBoostSmooth = 0.0 end
                semiCharge = semiChargeSmooth
                semiBoostV = semiBoostSmooth
            else
                semiChargeSmooth, semiBoostSmooth = 0.0, 0.0
            end

            -- LAUNCH CONTROL: derive the pill render state from hk-handling. Launching
            -- happens while STATIONARY (speed ~0, gear fixed), so it wouldn't trip the
            -- speed/gear deadband below — include an lc-change in the send condition so the
            -- pill updates through staging/boost even when nothing else moves.
            local lcRender = getLaunchRender()
            local lcChanged = lcRender ~= sentLc

            -- CLUTCH gauge feed (manual only): the engagement value from hk-handling. It moves
            -- continuously while the driver feathers, so — like the semi arc — stream while it's
            -- mid-travel (not fully out) so the bar animates smoothly instead of stepping.
            local clutchManual = ds.clutchManual == true
            local clutchVal = clutchManual and (ds.clutch or 1.0) or 1.0
            local clutchLive = clutchManual and (clutchVal < 0.999 or (sentClutch >= 0 and sentClutch < 0.999))
            local clutchChanged = clutchManual and math.abs(clutchVal - sentClutch) > 0.02

            -- TURBO gauge feed (turbo cars only): boost spool eases continuously, so — like the clutch
            -- and semi arc — stream while it's live (spooled or bleeding) so the bar animates smoothly.
            local turboActive = ds.turboActive == true
            local turboSpoolV = turboActive and (ds.turboSpool or 0.0) or 0.0
            local turboHitV   = turboActive and (ds.turboHit or 0.0) or 0.0
            local turboLive   = turboActive and (turboSpoolV > 0.001 or (sentTurbo >= 0 and sentTurbo > 0.001))
            local turboChanged = turboActive and math.abs(turboSpoolV - sentTurbo) > 0.02

            local rpmEasing = math.abs(rpmTarget - smoothRpm) > 0.0004  -- ~3.6 rpm
            local rawChanged = math.abs(speed - sentSpeed) > 0.1
                or gear ~= sentGear
            if rawChanged then
                tickSettle = TICK_SETTLE_FRAMES   -- (re)arm for the JS-side speed ease
            end
            -- EVs/hybrids: send every frame while the regen meter is live (throttle/regen
            -- change constantly and aren't captured by the speed/gear deadband). A semi's
            -- charge arc animates the same way, so stream while it's active too.
            -- ...and in e-mode the throttle-driven green bar changes every frame too, so stream
            -- while emodeBar is live (else the bar would freeze between speed/gear changes).
            local semiArcLive = isSemiVeh and (semiCharge > 0.0 or semiBoostV > 0.0 or emodeBar)
            if rawChanged or rpmEasing or tickSettle > 0 or showRegenMeter or semiArcLive or lcChanged or clutchLive or clutchChanged or turboLive or turboChanged then
                sentClutch = clutchVal
                sentTurbo = turboSpoolV
                sentLc = lcRender
                if tickSettle > 0 then tickSettle = tickSettle - 1 end
                sentSpeed = speed
                sentGear = gear
                SendNUIMessage({
                    type  = 'tick',
                    speed = speed,
                    rpm   = rpmDisplay,
                    gear  = gear,
                    -- EMODE-BAR cars are electric-NOW but must NOT set `electric` — that flag
                    -- routes the NUI into the EV split-ring path (which hides the normal tach
                    -- + isn't fed for a semi). They stay on the normal-tach path (semi arc +
                    -- green throttle bar); emodeBar carries the "electric right now" signal.
                    electric   = currentElectric and not emodeBar,   -- EV split-ring look (not for semi-look PHEV)
                    hybrid     = isHybridVeh,        -- 3-ring hybrid layout
                    electricNow = electricNow,       -- hybrid live e-mode
                    -- regen meter zones (shown for EV or hybrid):
                    throttle = showRegenMeter and throttle or nil,     -- right (power) zone
                    regen    = showRegenMeter and regenMag or nil,     -- left GREEN magnitude
                    friction = showRegenMeter and frictionMag or nil,  -- left GRAY magnitude
                    braking  = showRegenMeter and braking or nil,      -- brake pedal down
                    regenMode    = showRegenMeter and regenMode or nil,
                    regenHolding = showRegenMeter and regenHolding or nil,
                    -- pre-resolved indicator + gear label from hk-handling:
                    indIcon  = ds.indicator and ds.indicator.icon or false,  -- 'E'|'BOLT'|false
                    indColor = ds.indicator and ds.indicator.color or false, -- 'green'|'gold'|false
                    gearLabel = ds.gearLabel or false,                       -- 'D' or false (ICE -> real gear)
                    singleGear = ds.singleGear == true,                      -- comfort auto: single 'D', no A/M pill
                    -- CLUTCH gauge (manual only): manual flag gates visibility, clutch = engagement
                    -- 0..1 (1=out/engaged, 0=in/pressed). Always a boolean so the JS hides it on autos.
                    clutchManual = clutchManual,
                    clutch       = clutchVal,
                    -- TURBO gauge (turbo cars only): turboActive gates visibility, turboSpool = boost
                    -- 0..1 (needle), turboHit = punch 0..1 (flash). Always booleans/numbers so the JS
                    -- hides the gauge on non-turbo cars.
                    turboActive  = turboActive,
                    turboSpool   = turboSpoolV,
                    turboHit     = turboHitV,
                    lc = lcRender,                                           -- launch pill: off|idle|prep|armed|boost
                    -- SEMI/KERS charge arc (rides the normal tach): green charge on lift,
                    -- amber boost on throttle. `semi` is ALWAYS a boolean (never nil) so the
                    -- JS clears the arc when you switch off a semi into a normal car.
                    semi        = isSemiVeh,
                    semiCharge  = isSemiVeh and semiCharge or 0.0,
                    semiBoost   = isSemiVeh and semiBoostV or 0.0,
                    -- SEMI-LOOK PHEV in e-mode: the tach shows a throttle-driven GREEN bar (no
                    -- revs). Pass the flag + the pedal input; JS themes the bar + swaps rpm->thr.
                    emodeBar    = emodeBar,
                    emodeThr    = emodeBar and math.max(0.0, math.min(1.0, GetControlNormal(0, 71) or 0.0)) or nil,
                })
            end

            lastRpm = rpm
            lastGear = gear
            gearReady = true   -- armed after the first gear read

            -- ===== SLOW path (~every 250ms) — all the expensive cross-resource polls
            -- (seatbelt/harness/NOS/handbrake/gearbox exports) + light/lock/fuel. These
            -- change slowly, so 4x/sec is plenty and it's sent ONLY when something
            -- actually changed (change-detected via a hash), keeping NUI traffic low. =====
            stateTick = stateTick + 1
            if stateTick >= STATE_TICK_EVERY then
                stateTick = 0

                detectSeatbelt()
                harnessOn = detectHarness()
                local nosState = getNOSState(veh)
                refreshNos(veh)
                driftActive = detectDrift(veh)
                local hb = detectHandbrake(veh)
                local locked = detectLocked(veh)
                local lights = detectLights(veh)
                local handsup = detectHandsup()
                local gbMode = getGearboxMode(veh)
                local theme = (gbMode == 'manual') and 'sport' or 'eco'
                -- Gearbox letter: PURE EV -> 'E'; everything else (incl. HYBRIDS) -> the
                -- real box, M (manual) or A (auto/DCT). Hybrids keep their A/M pill AND
                -- also get the separate ⚡ mode pill — the two coexist.
                local pureEV = baseModelElectric or (currentElectric and not isHybridVeh)
                local gearMode = pureEV and 'E' or ((gbMode == 'manual') and 'M' or 'A')
                local fuel = math.floor(GetVehicleFuelLevel(veh) + 0.5)
                local night, backlightCol = detectNight(veh)
                local dt = getDrivetrain()
                local drivetrain = dt and dt.layout or nil          -- 'RWD'|'FWD'|'AWD'|nil

                -- Cheap change hash: only send when a field flipped. Fuel bucketed to
                -- whole % so tiny drift doesn't spam. nosAmount likewise.
                local hash = table.concat({
                    nosState, tostring(nosHasNos), math.floor(nosAmount or 0),
                    nosBoostLevel or 0, tostring(nosPurgeMode), tostring(nosColor),
                    tostring(nosOverheat), tostring(driftActive), tostring(hb),
                    tostring(absOff), tostring(tcOff),
                    tostring(blinkerArmed),
                    tostring(seatbeltOn), tostring(harnessOn),
                    tostring(locked), lights, fuel, theme, currentMaxSpeed, currentRedline,
                    tostring(night), tostring(backlightCol), tostring(handsup),
                    tostring(currentElectric and not emodeBar), gearMode, tostring(drivetrain),
                }, '|')

                if hash ~= lastStateHash then
                    lastStateHash = hash
                    SendNUIMessage({
                        type      = 'state',
                        nosState  = nosState,
                        hasNos    = nosHasNos,
                        nosAmount = nosAmount,
                        nosBoostLevel = nosBoostLevel,
                        nosPurge  = nosPurgeMode,
                        nosColor  = nosColor,
                        nosOverheat = nosOverheat,
                        drift     = driftActive,
                        absOff    = absOff,
                        tcOff     = tcOff,
                        blinker   = blinkerArmed,
                        handbrake = hb,
                        launch    = false,
                        seatbelt  = seatbeltOn,
                        harness   = harnessOn,
                        locked    = locked,
                        lights    = lights,
                        handsup   = handsup,
                        gearMode  = gearMode,
                        -- Send explicit `false` (not nil) when there's no drivetrain: a nil table field
                        -- is OMITTED from the JSON, so the NUI's `data.drivetrain !== undefined` guard
                        -- would keep the STALE value (boat still showing RWD). false reaches the hide path.
                        drivetrain = drivetrain or false,
                        fuel      = fuel,
                        maxSpeed  = currentMaxSpeed,
                        maxRpm    = Config.MaxRPM or 9000,
                        unit      = useMetric and 'KM/H' or 'MPH',
                        theme     = theme,
                        redline   = currentRedline,
                        -- MUST match the fast tick's `electric` exactly. A semi-look PHEV in
                        -- e-mode is electric-NOW but sets emodeBar (not the EV split-ring), so
                        -- the tick sends `currentElectric and not emodeBar` = false. Sending a
                        -- bare currentElectric (=true) here diverged state.electric between the
                        -- two messages -> the state handler re-added `.ev` on every pill change,
                        -- flicking the ring/fuel a frame until the next tick cleared it.
                        electric  = currentElectric and not emodeBar,
                        night     = night,
                        backlight = backlightCol,
                    })
                end
            end
            end  -- end of "not paused" telemetry block

            ::continue::
        else
            -- LEFT THE CAR: full exit. Reset every stage flag. Only send hide/animate
            -- if the speedo was actually engaged (engine had been on).
            if vehReady then
                local wasShowing = showing
                vehReady = false
                showing = false
                showReady = false
                menuHidden = false
                nosBoostActive = false
                -- Belt-and-braces: clear the drive-state bag on exit too. hk-handling now
                -- owns publishing + clearing it (on Gearbox_Disable), but this covers the case
                -- where the driver ISN'T running hk-handling — no stale snapshot lingers.
                if lastVehicle ~= 0 then
                    local ent = Entity(lastVehicle)
                    if ent and ent.state then pcall(function() ent.state:set(DRIVE_BAG, nil, true) end) end
                end
                lastVehicle = 0
                engagePending = engagePending + 1   -- cancel any pending engage
                lastStateHash = nil                 -- fresh state push on next entry
                sentSpeed, sentGear, tickSettle = -1, -999, 0  -- force fresh tick on next entry
                sentLc = 'off'                                 -- re-push launch pill state
                if wasShowing then
                    SendNUIMessage({ type = 'hide' })
                    SendNUIMessage({ type = 'revlimit', active = false })
                end
            end
            Citizen.Wait(500)
        end
    end
end)

-----------------------------------------------------------------
-- PASSENGER MINI SPEEDO
-- A separate, dead-simple loop for when the player is a PASSENGER (in a vehicle but
-- NOT the driver seat). The main loop above ignores passengers (isInVehicle() requires
-- seat -1), so the full cluster never shows for them. This sends a tiny 'mini' message
-- with just speed + gear + max, only while a passenger and the engine is running, and
-- only when the value actually changed (deadbanded, like the main tick). NUI renders a
-- small rectangle bottom-right — no rings, near-zero cost.
-----------------------------------------------------------------
local function isPassenger()
    local ped = PlayerPedId()
    if not IsPedInAnyVehicle(ped, false) then return false end
    local veh = GetVehiclePedIsIn(ped, false)
    if veh == 0 then return false end
    -- In a vehicle but not the driver seat.
    return GetPedInVehicleSeat(veh, -1) ~= ped
end

-- The passenger reuses the MINIMAL PANEL (gear + RPM bar + fuel + NOS + status) rather
-- than a bespoke tiny box — same NUI, so passengers get the full compact readout for
-- free. It drives the same 'tick' (fast) + 'state' (slow) messages the driver uses,
-- and forces the NUI into minimal layout via a 'mode' message while riding shotgun.
-- Always minimal for passengers regardless of the player's saved /speedo mode.
Citizen.CreateThread(function()
    while not Config do Citizen.Wait(100) end
    if not Config.Enabled then return end

    local shown = false
    local pSpeed, pGear = -1, -999
    local pStateHash = nil
    local pStateTick = 0
    local pSentLc = 'off'   -- last launch pill state pushed (change-detect for the tick gate)

    while true do
        Citizen.Wait(Config.TickRate or 16)

        if isPassenger() and GetIsVehicleEngineRunning(GetVehiclePedIsIn(PlayerPedId(), false)) then
            local veh = GetVehiclePedIsIn(PlayerPedId(), false)

            if not shown then
                shown = true
                pSpeed, pGear, pStateHash, pSentLc = -1, -999, nil, 'off'   -- force fresh sends
                SendNUIMessage({ type = 'mode', mode = 'minimal' })  -- force minimal layout
                SendNUIMessage({ type = 'show' })
            end

            -- FAST: speed + gear + rpm (deadbanded) + full EV/hybrid render state so the
            -- passenger panel shows the same power/regen meter, e-mode, ⚡ and gear label
            -- the driver sees. We're not the driver, so pedal CONTROL inputs (71/72) don't
            -- apply — read throttle/brake from the VEHICLE's own axis instead (works from
            -- any seat). electricNow flips live on a hybrid, so poll per frame.
            local speed = getSpeed(veh)
            local gear = getDisplayGear(veh)
            local rpmDisplay = GetVehicleCurrentRpm(veh) * (Config.MaxRPM or 9000)

            -- Read the DRIVER-published drive state from the replicated bag (our own
            -- hk-handling can't see the driver's e-mode). Fall back to the model-electric
            -- native for pure EVs when the driver isn't publishing (e.g. no hk-speedo).
            local bag = readDriveStateBag(veh)
            local pBaseElec = GetIsVehicleElectric(GetEntityModel(veh))
            local pHybrid, pElecNow, pCurElec = false, false, pBaseElec
            local pIcon, pColor, pGearLabel = false, false, false
            local pSingleGear = false
            local pLc = 'off'
            local pRegenModeBag, pRegenActive, pRegenHoldingBag = 'coast', false, false
            if bag then
                pHybrid = bag.hybrid == true
                pElecNow = bag.electricNow == true
                pCurElec = bag.electric == true or pBaseElec
                pIcon = bag.icon or false
                pColor = bag.color or false
                pGearLabel = bag.gearLabel or false
                pSingleGear = bag.singleGear == true
                pRegenModeBag = bag.regenMode or 'coast'
                pRegenActive = bag.regenActive == true
                pRegenHoldingBag = bag.regenHolding == true
                -- Launch pill from the bag: phase + the pre-stage signals, so a passenger
                -- gets the same full idle/prep/armed/boost looks the driver sees.
                pLc = resolveLaunchState(bag.launchPhase or 'off',
                                         bag.launchNeutral == true, bag.launchHb == true)
            end
            local pSemi      = bag and bag.semiHybrid == true or false
            local pEmodeBar  = bag and bag.emodeBar == true or false
            -- EMODE-BAR (semi-look PHEV on electric): stays on the NORMAL-tach path (semi arc +
            -- green throttle bar), NOT the EV split-ring — so drop it out of the electric/regen
            -- routing the same way the driver path does. emodeBar carries "electric right now".
            local pShowRegen = (pCurElec or pHybrid) and not pEmodeBar

            local pThrottle, pRegenMag, pFrictionMag, pBraking = 0.0, 0.0, 0.0, false
            if pShowRegen then
                -- Vehicle-derived throttle/brake (GetVehicleThrottleOffset): +thr / -brake.
                -- Passengers can't read their own pedal inputs, and the vehicle axis reflects
                -- the actual drive state regardless of seat.
                local okT, t = pcall(GetVehicleThrottleOffset, veh)
                local pedalBrake = 0.0
                if okT and type(t) == 'number' then
                    if t >= 0 then pThrottle = math.min(1.0, t)
                    else pedalBrake = math.min(1.0, -t) end
                else
                    pThrottle = math.max(0.0, math.min(1.0, GetVehicleCurrentRpm(veh)))
                end

                -- Regen magnitude comes from the bag's active flag (level isn't synced; the
                -- passenger meter shows presence/coast, not the exact 0..1 the driver feels).
                local rTarget = pRegenActive and 0.5 or 0.0
                regenSmooth = regenSmooth + (rTarget - regenSmooth) * REGEN_LERP
                if regenSmooth < 0.004 then regenSmooth = 0.0 end

                local inForward = (gear >= 1)
                pRegenMag = inForward and regenSmooth or 0.0
                if pedalBrake > 0.06 then
                    pBraking = true
                    pFrictionMag = pedalBrake
                end
            else
                regenSmooth = 0.0
            end

            local pRegenMode = pShowRegen and pRegenModeBag or nil
            local pRegenHolding = pShowRegen and pRegenHoldingBag or nil

            -- SEMI charge arc for the passenger: charge from the bag's regen-active flag,
            -- boost from the synced (bucketed) semiBoost. Coarser than the driver's smooth
            -- read, but correct presence. Only meaningful in a full-gauge layout.
            local pSemiCharge, pSemiBoost = 0.0, 0.0
            if pSemi then
                local cTarget = (pRegenActive and gear >= 1) and 0.5 or 0.0
                semiChargeSmooth = semiChargeSmooth + (cTarget - semiChargeSmooth) * REGEN_LERP
                if semiChargeSmooth < 0.004 then semiChargeSmooth = 0.0 end
                local bTarget = (bag and bag.semiBoost) or 0.0
                if bTarget < 0 then bTarget = 0.0 elseif bTarget > 1 then bTarget = 1.0 end
                semiBoostSmooth = semiBoostSmooth + (bTarget - semiBoostSmooth) * REGEN_LERP
                if semiBoostSmooth < 0.004 then semiBoostSmooth = 0.0 end
                pSemiCharge, pSemiBoost = semiChargeSmooth, semiBoostSmooth
            else
                semiChargeSmooth, semiBoostSmooth = 0.0, 0.0
            end

            -- EMODE-BAR passenger throttle: a semi-look PHEV in e-mode isn't pShowRegen, so
            -- the throttle above wasn't read. Derive it from the vehicle throttle axis (the
            -- passenger can't read the driver's pedal, but the axis reflects it).
            local pEmodeThr = nil
            if pEmodeBar then
                local okE, te = pcall(GetVehicleThrottleOffset, veh)
                local tv = (okE and type(te) == 'number' and te > 0) and te or 0.0
                pEmodeThr = math.max(0.0, math.min(1.0, tv))
            end

            -- Launch is stationary (won't trip the speed/gear deadband), so force a send
            -- when the launch pill state changes too.
            local pLcChanged = pLc ~= pSentLc
            local pSemiLive = pSemi and (pSemiCharge > 0.0 or pSemiBoost > 0.0 or pEmodeBar)

            if math.abs(speed - pSpeed) > 0.3 or gear ~= pGear or pShowRegen or pSemiLive or pLcChanged then
                pSpeed, pGear = speed, gear
                pSentLc = pLc
                SendNUIMessage({
                    type  = 'tick',
                    speed = speed,
                    rpm   = rpmDisplay,
                    gear  = gear,
                    electric    = pCurElec and not pEmodeBar,   -- EV split-ring (not semi-look PHEV)
                    hybrid      = pHybrid,
                    electricNow = pElecNow,
                    singleGear  = pSingleGear,
                    throttle = pShowRegen and pThrottle or nil,
                    regen    = pShowRegen and pRegenMag or nil,
                    friction = pShowRegen and pFrictionMag or nil,
                    braking  = pShowRegen and pBraking or nil,
                    regenMode    = pRegenMode,
                    regenHolding = pRegenHolding,
                    indIcon  = pIcon,
                    indColor = pColor,
                    gearLabel = pGearLabel,
                    lc = pLc,                 -- launch pill: off|armed|boost (passenger)
                    semi        = pSemi,
                    semiCharge  = pSemi and pSemiCharge or 0.0,
                    semiBoost   = pSemi and pSemiBoost or 0.0,
                    emodeBar    = pEmodeBar,
                    emodeThr    = pEmodeThr,
                })
            end

            -- SLOW (~250ms): fuel + NOS + status, change-hashed like the driver path.
            pStateTick = pStateTick + 1
            if pStateTick >= STATE_TICK_EVERY then
                pStateTick = 0
                local nosState = getNOSState(veh)
                refreshNos(veh)
                local hb = detectHandbrake(veh)
                local locked = detectLocked(veh)
                local lights = detectLights(veh)
                local sb = detectSeatbelt()
                local hn = detectHarness()
                local fuel = math.floor(GetVehicleFuelLevel(veh) + 0.5)
                local maxS = calcGaugeMax(veh)

                -- EV/hybrid state for the STATUS side (gearbox pill + theme). Read from the
                -- driver-published bag (our local hk-handling exports are driver-only), so
                -- the passenger's E/A/M pill, drivetrain badge and eco/sport theme match.
                local sbag = readDriveStateBag(veh)
                local sBaseElec = GetIsVehicleElectric(GetEntityModel(veh))
                local sHybrid = sbag and sbag.hybrid == true or false
                local sElecNow = sbag and sbag.electricNow == true or false
                local sCurElec = (sbag and sbag.electric == true) or sBaseElec
                local sEmodeBar = sbag and sbag.emodeBar == true or false  -- semi-look PHEV in e-mode
                local sGbMode = sbag and sbag.gearboxMode or false      -- 'manual'|'auto'|false
                local theme = (sGbMode == 'manual') and 'sport' or 'eco'
                -- PURE EV -> 'E'; everything else (incl. hybrids) -> real box A/M. Hybrid
                -- e-mode surfaces 'E' via the JS side (electricNow), same as the driver.
                local pureEV = sBaseElec or (sCurElec and not sHybrid)
                local gearMode = pureEV and 'E' or ((sGbMode == 'manual') and 'M' or 'A')
                local drivetrain = false  -- passenger: no drivetrain source. `false` (not nil) so the
                                          -- field is SENT and the NUI actively hides the pill (a nil
                                          -- field is omitted from JSON → stale badge kept).

                local hash = table.concat({
                    nosState, tostring(nosHasNos), math.floor(nosAmount or 0),
                    nosBoostLevel or 0, tostring(nosPurgeMode), tostring(nosColor),
                    tostring(hb), tostring(locked), lights, tostring(sb), tostring(hn), fuel, maxS,
                    tostring(sCurElec and not sEmodeBar), gearMode, theme, tostring(drivetrain),
                }, '|')
                if hash ~= pStateHash then
                    pStateHash = hash
                    SendNUIMessage({
                        type      = 'state',
                        nosState  = nosState,
                        hasNos    = nosHasNos,
                        nosAmount = nosAmount,
                        nosBoostLevel = nosBoostLevel,
                        nosPurge  = nosPurgeMode,
                        nosColor  = nosColor,
                        nosOverheat = nosOverheat,
                        handbrake = hb,
                        seatbelt  = sb,
                        harness   = hn,
                        locked    = locked,
                        lights    = lights,
                        fuel      = fuel,
                        maxSpeed  = maxS,
                        -- match the passenger tick (electric = pCurElec and not pEmodeBar): a
                        -- semi-look PHEV in e-mode is electric-now but sets emodeBar, so it must
                        -- NOT flag `electric` here or the state handler flickers `.ev` on it.
                        electric  = sCurElec and not sEmodeBar,
                        gearMode  = gearMode,
                        theme     = theme,
                        drivetrain = drivetrain,
                        maxRpm    = Config.MaxRPM or 9000,
                        unit      = useMetric and 'KM/H' or 'MPH',
                    })
                end
            end
        else
            if shown then
                shown = false
                SendNUIMessage({ type = 'hide' })
                -- Restore the player's own saved mode for when they next drive.
                SendNUIMessage({ type = 'mode', mode = speedoMode })
            end
            Citizen.Wait(400)   -- not a passenger: idle slower
        end
    end
end)

-----------------------------------------------------------------
-- EXPORTS for hk-handling integration — ring glow colour scheme:
--   blue         normal gear change (checkShiftQuality, every shift)
--   green/gold   PERFECT / clean rev-matched shift (hk-speedo:perfectShift)
--   red          BAD shift / missed downshift  (these exports)
-- Redlining flashes red via the dedicated #redline-overlay (revlimit message).
-----------------------------------------------------------------
exports('badShift', function()
    SendNUIMessage({ type = 'glow', glow = 'red', duration = 450 })
end)

exports('badDownshift', function()
    SendNUIMessage({ type = 'glow', glow = 'red', duration = 450 })
end)

exports('revMatch', function()
    -- a good rev-matched blip: green confirmation flash
    SendNUIMessage({ type = 'glow', glow = 'green', duration = 400 })
end)

-- (Removed the temp /lcdebug on-screen launch-control readout — the proper LC status pill
--  in the gauge NUI replaced it. Launch state is read via GetLaunchState / the drive-state
--  bag and rendered as the #ind-launch pill; see resolveLaunchState + the tick payload.)


-- ============================================================================
-- [hk-hub] External mode setter. Lets hk-hub's settings panel set the speedo
-- display mode directly (not just cycle). Persists to SQL like /speedo does.
-- Backup of original: client.lua.hkhub-bak
-- ============================================================================
RegisterNetEvent('hk-speedo:setMode', function(mode)
    if mode ~= 'normal' and mode ~= 'lite' and mode ~= 'full' and mode ~= 'minimal' then
        return
    end
    applyMode(mode, true)
end)

-- Report the current mode back so hk-hub can show the active choice.
RegisterNetEvent('hk-speedo:requestMode', function()
    TriggerEvent('hk-speedo:currentMode', speedoMode)
end)
