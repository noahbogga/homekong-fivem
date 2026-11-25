--=====================================================================
-- hk-optimizer :: client engine
--   Applies a saved mode's render settings. Exposed via export so the
--   /hud (F5) settings page can drive player selection later:
--       exports['hk-optimizer']:applyMode('quality' | 'balance' | 'fps')
--       exports['hk-optimizer']:getCurrentMode()
--   Editing lives in client/editor.lua; this file only APPLIES.
--=====================================================================

QBCore = QBCore or exports['qb-core']:GetCoreObject()

-- Synced from server: { [mode] = { key = value, ... } }
ModeSettings = {}
local currentMode = 'quality'
local active = nil  -- resolved settings table (nil = quality baseline / GTA defaults)

RegisterNetEvent('hk-optimizer:sync', function(data)
    ModeSettings = data or {}
    -- If we're currently on an edited mode, refresh the live values.
    if currentMode ~= 'quality' and ModeSettings[currentMode] then
        active = ModeSettings[currentMode]
    end
end)

-- On start, pull the saved settings so a late joiner has them ready. This ONLY
-- populates ModeSettings — it does not apply a mode. Nothing changes for the
-- player until hk-hub calls exports['hk-optimizer']:applyMode(name).
CreateThread(function()
    QBCore.Functions.TriggerCallback('hk-optimizer:fetch', function(data)
        if data then ModeSettings = data end
    end)
end)

-- Fake surround/distant cop siren is useless on this server: force it OFF at
-- all times and keep re-asserting it (it can get re-enabled by other resources,
-- session changes, or the game itself). Runs regardless of the active mode.
CreateThread(function()
    while true do
        DistantCopCarSirens(false)
        Wait(2000)
    end
end)

-- Entity enumerators (needed for the off-screen ped/object sweeps).
local entityEnumerator = {
    __gc = function(enum)
        if enum.destructor and enum.handle then enum.destructor(enum.handle) end
        enum.destructor, enum.handle = nil, nil
    end
}
local function EnumerateEntities(initFunc, moveFunc, disposeFunc)
    return coroutine.wrap(function()
        local iter, id = initFunc()
        if not id or id == 0 then disposeFunc(iter) return end
        local enum = { handle = iter, destructor = disposeFunc }
        setmetatable(enum, entityEnumerator)
        local nextIter = true
        repeat
            coroutine.yield(id)
            nextIter, id = moveFunc(iter)
        until not nextIter
        enum.destructor, enum.handle = nil, nil
        disposeFunc(iter)
    end)
end
local function GetWorldObjects() return EnumerateEntities(FindFirstObject, FindNextObject, EndFindObject) end
local function GetWorldPeds()    return EnumerateEntities(FindFirstPed, FindNextPed, EndFindPed) end

-- One-shot native settings applied the moment a mode is selected.
local function applyOneShot(s)
    if not s then  -- quality baseline: restore full GTA defaults.
        RopeDrawShadowEnabled(true)
        CascadeShadowsSetAircraftMode(true)
        CascadeShadowsEnableEntityTracker(false)
        CascadeShadowsSetDynamicDepthMode(true)
        CascadeShadowsSetEntityTrackerScale(5.0)
        CascadeShadowsSetDynamicDepthValue(5.0)
        CascadeShadowsSetCascadeBoundsScale(5.0)
        SetFlashLightFadeDistance(10.0)
        SetLightsCutoffDistanceTweak(10.0)
        DistantCopCarSirens(false)  -- fake surround siren: always OFF, not tunable
        SetArtificialLightsState(false)
        return
    end

    RopeDrawShadowEnabled(s.rope_shadows and true or false)
    if s.shadow_bounds and s.shadow_bounds < 5.0 then
        CascadeShadowsClearShadowSampleType()
        CascadeShadowsSetAircraftMode(false)
        CascadeShadowsEnableEntityTracker(true)
        CascadeShadowsSetDynamicDepthMode(false)
    else
        CascadeShadowsSetAircraftMode(true)
        CascadeShadowsEnableEntityTracker(false)
        CascadeShadowsSetDynamicDepthMode(true)
    end
    CascadeShadowsSetEntityTrackerScale(s.shadow_bounds or 5.0)
    CascadeShadowsSetDynamicDepthValue(s.shadow_bounds or 5.0)
    CascadeShadowsSetCascadeBoundsScale(s.shadow_bounds or 5.0)
    SetFlashLightFadeDistance(s.flashlight_fade or 10.0)
    SetLightsCutoffDistanceTweak(s.lights_cutoff or 10.0)
    DistantCopCarSirens(false)  -- fake surround siren: always OFF, not tunable
end

local function sweepPeds(a)
    for ped in GetWorldPeds() do
        if not IsEntityOnScreen(ped) then
            SetEntityAlpha(ped, 0); SetEntityAsNoLongerNeeded(ped)
        else
            if GetEntityAlpha(ped) == 0 then SetEntityAlpha(ped, 255)
            elseif a < 255 and GetEntityAlpha(ped) ~= a then SetEntityAlpha(ped, a) end
        end
        SetPedAoBlobRendering(ped, false)
        Wait(1)
    end
end

local function sweepObjects(a)
    for obj in GetWorldObjects() do
        if not IsEntityOnScreen(obj) then
            SetEntityAlpha(obj, 0); SetEntityAsNoLongerNeeded(obj)
        else
            if GetEntityAlpha(obj) == 0 then SetEntityAlpha(obj, 255)
            elseif a < 255 and GetEntityAlpha(obj) ~= a then SetEntityAlpha(obj, a) end
        end
        Wait(1)
    end
end

-- Per-frame render thread.
CreateThread(function()
    while true do
        local s = active
        if s then
            if s.sweep_peds    then sweepPeds(s.ped_alpha or 255) end
            if s.sweep_objects then sweepObjects(s.obj_alpha or 255) end
            if s.disable_occlusion then DisableOcclusionThisFrame() end
            if s.disable_decals    then SetDisableDecalRenderingThisFrame() end
            if s.remove_particles  then RemoveParticleFxInRange(GetEntityCoords(PlayerPedId()), 10.0) end
            if s.lod_scale and s.lod_scale < 1.0 then OverrideLodscaleThisFrame(s.lod_scale + 0.0) end
            Wait(8)
        else
            Wait(500)
        end
    end
end)

-- Cleanup thread (weather / accumulated effects).
CreateThread(function()
    while true do
        local s = active
        if s and s.clear_weather_fx then
            ClearAllBrokenGlass(); ClearAllHelpMessages(); ClearBrief()
            ClearGpsFlags(); ClearPrints(); ClearSmallPrints()
            ClearFocus(); ClearHdArea()
            ClearPedBloodDamage(PlayerPedId()); ClearPedWetness(PlayerPedId())
            ClearPedEnvDirt(PlayerPedId()); ResetPedVisibleDamage(PlayerPedId())
            ClearExtraTimecycleModifier(); ClearTimecycleModifier()
            DisableScreenblurFade()
            SetRainLevel(0.0); SetWindSpeed(0.0)
            Wait(math.floor(s.clear_interval or 1000))
        else
            Wait(1500)
        end
    end
end)

-- Apply a mode by name. 'quality' (baseline) or unknown restores GTA defaults.
local function applyMode(name)
    local m = ModeSettings[name]
    if name == 'quality' or not m then
        currentMode = 'quality'
        active = nil
        applyOneShot(nil)
    else
        currentMode = name
        active = m
        applyOneShot(m)
    end
    return currentMode
end

exports('applyMode', function(name) return applyMode(name) end)
exports('getCurrentMode', function() return currentMode end)

-- Editor uses these to preview an unsaved settings table live.
function HkOpti_PreviewApply(s)  active = s; applyOneShot(s) end
function HkOpti_RestoreCurrent() applyMode(currentMode) end
