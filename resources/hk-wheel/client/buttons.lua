-- hk-wheel :: client/buttons.lua
-- Button-box actions. The app reports named button EDGES (pressed/released this frame)
-- via frame.actions; we translate each to the REAL entrypoint that system already
-- exposes (verified command/event/export names — see the map below). hk-handling and
-- every other resource stay UNTOUCHED; we only drive their existing inputs.
--
-- The app sends actions as one-shot edges so we don't repeat-fire while held:
--   frame.actions = { engine=true, nos=true, ... }   -- only keys that FIRED this frame
-- (held-state buttons like look-behind are handled separately — see main.lua, which
--  reads frame.hold = { lookBehind=true, ... } every frame.)

Buttons = Buttons or {}

-- Verified entrypoints (searched the live resources 2026-07-27):
--   engine toggle / hybrid cycle : qb-vehiclekeys '+engine'/'-engine' (tap=engine,
--        hold>=300ms=hybrid). Hybrid also has a DIRECT export: hk-handling:CycleHybridMode().
--   seatbelt : NET EVENT 'seatbelt:client:ToggleSeatbelt' (hk-hud listens).
--   NOS      : jim mechanic commands 'nosSwitch' (arm/disarm), '+nosBoost'/'-nosBoost'
--        (fire), 'levelUP'/'levelDown' (boost level).
--   neutral  : hk-handling has NO neutral command — the AUTOMATIC neutral toggle is the
--        reqNeutralTap chord (both shift keys at once). We emulate it by firing +hk_upshift
--        and +hk_downshift within the chord window (NeutralChordMs) so the box reads a chord.
--   look     : native GTA controls (LOOK_BEHIND 79, plus we drive look-left/right in main.lua).

-- Fire the engine TAP (quick +/- pair; held < 300ms = ToggleEngine, never hybrid).
local function engineTap()
    ExecuteCommand('+engine')
    -- release next tick so held-duration reads as a tap; ExecuteCommand is synchronous so
    -- a tiny SetTimeout keeps it under hkHoldMs(300) without blocking.
    SetTimeout(0, function() ExecuteCommand('-engine') end)
end

-- Cycle hybrid drive mode. Prefer the DIRECT export (clean, no timing games); fall back
-- to a long +engine/-engine hold if the export is missing.
local function hybridCycle()
    local ok = pcall(function() return exports['hk-handling']:IsHybridVehicle() end)
    if ok then
        pcall(function() exports['hk-handling']:CycleHybridMode() end)
    else
        ExecuteCommand('+engine')
        SetTimeout(350, function() ExecuteCommand('-engine') end)   -- >300ms = hybrid path
    end
end

-- NEUTRAL (automatic modes): emulate the both-shift-keys chord the box uses for its
-- neutral TOGGLE. Fire up+down inside NeutralChordMs so the tick reads a simultaneous chord.
local function neutralToggle()
    ExecuteCommand('+hk_upshift')
    ExecuteCommand('+hk_downshift')
    SetTimeout(0, function()
        ExecuteCommand('-hk_upshift')
        ExecuteCommand('-hk_downshift')
    end)
end

-- The edge-action dispatch table. Key = action name from frame.actions; value = fn.
local ACTIONS = {
    engine     = engineTap,
    hybrid     = hybridCycle,
    neutral    = neutralToggle,
    -- BOX SELECTOR: flip DCT auto<->manual via hk-handling's SetBoxMode export (added for this).
    -- 'toggle' flips; the export no-ops on non-DCT / paddle-only tiers.
    box        = function() pcall(function() exports['hk-handling']:SetBoxMode('toggle') end) end,
    boxAuto    = function() pcall(function() exports['hk-handling']:SetBoxMode('auto') end) end,
    boxManual  = function() pcall(function() exports['hk-handling']:SetBoxMode('manual') end) end,
    seatbelt   = function() TriggerEvent('seatbelt:client:ToggleSeatbelt') end,
    -- NOS (jim): arm/disarm toggle, fire (momentary — see hold handling in main.lua for the
    -- press/release pair), and level up/down.
    nosToggle  = function() ExecuteCommand('nosSwitch') end,
    nosLevelUp = function() ExecuteCommand('levelUP') end,
    nosLevelDn = function() ExecuteCommand('levelDown') end,
    -- Headlights: native cycle (off/low/high). GTA control is edge-y, so nudge the native.
    headlight  = function()
        local veh = GetVehiclePedIsIn(PlayerPedId(), false)
        if veh ~= 0 then
            local _, cur = GetVehicleLightsState(veh)   -- 0 off,1 on; we cycle via SetVehicleLights
            SetVehicleLights(veh, (cur == 1) and 0 or 2)
        end
    end,
    -- Indicators (native).
    indLeft    = function()
        local veh = GetVehiclePedIsIn(PlayerPedId(), false)
        if veh ~= 0 then Buttons._indL = not Buttons._indL; SetVehicleIndicatorLights(veh, 1, Buttons._indL) end
    end,
    indRight   = function()
        local veh = GetVehiclePedIsIn(PlayerPedId(), false)
        if veh ~= 0 then Buttons._indR = not Buttons._indR; SetVehicleIndicatorLights(veh, 0, Buttons._indR) end
    end,
    hazards    = function()
        local veh = GetVehiclePedIsIn(PlayerPedId(), false)
        if veh ~= 0 then
            Buttons._haz = not Buttons._haz
            SetVehicleIndicatorLights(veh, 0, Buttons._haz)
            SetVehicleIndicatorLights(veh, 1, Buttons._haz)
        end
    end,
    horn       = function() end,   -- horn is a HELD action; handled in main.lua via frame.hold
}

-- Process the one-shot edge actions in a frame.
function Buttons.handleEdges(frame)
    local a = frame.actions
    if type(a) ~= 'table' then return end
    for name, fired in pairs(a) do
        if fired and ACTIONS[name] then
            ACTIONS[name]()
            if Config.Debug then print('[hk-wheel] button action: ' .. name) end
        end
    end
end

-- List the actions we support (for the handoff / debug).
function Buttons.supported()
    local t = {}
    for k in pairs(ACTIONS) do t[#t + 1] = k end
    table.sort(t)
    return t
end
