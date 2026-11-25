--=====================================================================
-- hk-cleararea :: client engine
--   Runs on EVERY client (ambient peds/vehicles are client-owned, so
--   each player must clear their own). Distance-gated: only zones near
--   the player get a clearing pass, and each zone clears on its own
--   interval. This is the efficiency fix over uj_clearArea's blanket
--   Wait(5) sweep of every zone forever.
--=====================================================================

Zones = {}                 -- synced from server (also read by editor.lua)
local lastClear = {}       -- [zoneId] = GetGameTimer() of last pass

RegisterNetEvent('hk-scenario:zones:sync', function(list)
    Zones = list or {}
    -- expose for the editor
    if UpdateEditorZones then UpdateEditorZones(Zones) end
end)

-- Ask for the current list on resource (re)start.
AddEventHandler('onClientResourceStart', function(res)
    if res ~= GetCurrentResourceName() then return end
    TriggerServerEvent('hk-scenario:zones:requestSync')
    -- Nudge txAdmin to (re)authenticate this client so the server's txAdmins
    -- set is populated even if we restarted AFTER they were already an admin.
    -- Harmless for non-admins (auth just fails silently).
    if GetResourceState('monitor') == 'started' then
        TriggerServerEvent('txsv:checkIfAdmin')
    end
end)

-- ── Geometry ────────────────────────────────────────────────────────────────
-- Is a world point (ex,ey,ez) inside zone z? Generous on Z so multi-floor MLOs
-- and slightly-off entity origins are still caught.
local function entIn(z, ex, ey, ez)
    if z.shape == 'box' then
        local dz = ez - z.z
        if math.abs(dz) > (z.height * 0.5 + 5.0) then return false end
        local rad = -math.rad(z.heading)
        local c, s = math.cos(rad), math.sin(rad)
        local dx, dy = ex - z.x, ey - z.y
        local lx = dx * c - dy * s
        local ly = dx * s + dy * c
        return math.abs(lx) <= (z.length * 0.5) and math.abs(ly) <= (z.width * 0.5)
    else
        if math.abs(ez - z.z) > (z.radius + 20.0) then return false end
        local dx, dy = ex - z.x, ey - z.y
        return (dx * dx + dy * dy) <= (z.radius * z.radius)
    end
end

-- ── Protection: never delete parked cars or our own placed props ────────────
-- hk-parking publishes GlobalState.hkParkedPlates (a set of protected plates)
-- and sets a replicated `isParked` statebag on each parked vehicle. We honour
-- both. Props we placed are excluded via Scn_isScenarioProp (client/props.lua).
local function plateKey(plate)
    if not plate then return nil end
    return tostring(plate):gsub("^%s*(.-)%s*$", "%1"):upper()
end

-- Explicit model backstop for the cfx-nteam-monorail rail stock, in case a
-- custom-flagged model isn't reported as a train by the class/native checks.
-- (map trains.xml carriages: metrotrain + the freight/tanker cars it runs.)
local NEVER_CLEAR_MODELS = {}
for _, m in ipairs({
    'metrotrain', 'freight', 'freightcar', 'freightcont1', 'freightcont2',
    'freightgrain', 'tankercar',
}) do NEVER_CLEAR_MODELS[joaat(m) & 0xFFFFFFFF] = true end

-- Does this vehicle currently have ANY player in it (any seat)? Player-occupied
-- cars must never be swept, no matter whose they are.
local function vehicleHasPlayer(veh)
    -- seats: -1 (driver) .. GetVehicleMaxNumberOfPassengers-1
    local maxSeats = GetVehicleMaxNumberOfPassengers(veh)
    for seat = -1, maxSeats - 1 do
        local ped = GetPedInVehicleSeat(veh, seat)
        if ped and ped ~= 0 and IsPedAPlayer(ped) then return true end
    end
    return false
end

-- Is this a "player vehicle" we must protect even when empty? Covers the car the
-- LOCAL player is in OR just got out of (GetVehiclePedIsIn(ped,true) = last
-- vehicle), so stepping out inside a zone doesn't nuke your ride. `mine` is
-- passed in from doClear (computed once per pass).
local function isPlayerVehicle(veh, mine)
    if mine and veh == mine then return true end
    return vehicleHasPlayer(veh)
end

-- Does this vehicle carry ANY hk-parking parking statebag? On stream-in the
-- individual replicated keys can arrive a frame or two apart, so we accept any
-- one of them as "this is a managed parked car" (not just isParked).
local function hasParkingState(st)
    if not st then return false end
    return st.isParked or st.hkNoClear or st.isClamped
        or st.parkedPos ~= nil or st.citizenid ~= nil
end

-- Stream-in grace: the first time we see a vehicle in the pool, note the time.
-- For the first STREAM_GRACE_MS we never delete it, because a parked car that
-- just re-streamed hasn't necessarily had its statebag/plate re-replicated yet —
-- deleting it in that window is exactly what made parked cars glitch (delete →
-- hk-parking respawns → repeat). Ambient cars just get a few extra seconds.
local STREAM_GRACE_MS = 6000
local firstSeen = {}   -- [entity] = GetGameTimer() first observed
local function withinStreamGrace(ent)
    local now = GetGameTimer()
    local t = firstSeen[ent]
    if not t then firstSeen[ent] = now; return true end
    return (now - t) < STREAM_GRACE_MS
end
-- prune stale handles occasionally so the table doesn't grow unbounded
CreateThread(function()
    while true do
        Wait(30000)
        for ent in pairs(firstSeen) do
            if not DoesEntityExist(ent) then firstSeen[ent] = nil end
        end
    end
end)

-- Should this entity NEVER be cleared? Single source of truth for both the
-- pool sweep and the native sweeps.
--   * our own placed scenario props (Scn_isScenarioProp, from client/props.lua)
--   * ANY player-occupied vehicle, and the local player's current/last vehicle
--     (so getting out inside a zone doesn't delete your car) — `mine` arg.
--   * hk-parking parked cars: any parking statebag OR the GlobalState plate
--     registry (the reliable one — replicates instantly, survives statebag
--     races) OR still inside the stream-in grace window.
--   * trains (the monorail map's rail stock).
--   * anything flagged as a mission entity (persistent/owned by another script).
local function isProtected(ent, mine)
    if not ent or ent == 0 then return false end
    if Scn_isScenarioProp and Scn_isScenarioProp(ent) then return true end
    local st = Entity(ent).state
    if hasParkingState(st) then return true end
    if IsEntityAVehicle(ent) then
        -- TRAINS: never clear. The cfx-nteam-monorail map runs a native train
        -- (model 'metrotrain') along fixed tracks — it's the map's rail system,
        -- not ambient traffic. IsEntityAMissionEntity misses it because the train
        -- script owns it on another client, so gate on the model class + type.
        if GetEntityType(ent) == 2 then  -- 2 = vehicle
            local model = GetEntityModel(ent) & 0xFFFFFFFF
            if NEVER_CLEAR_MODELS[model] then return true end
            if IsThisModelATrain(model) then return true end
            local vc = GetVehicleClass(ent)
            if vc == 21 then return true end  -- class 21 = Trains/trams
        end
        if isPlayerVehicle(ent, mine) then return true end
        -- persistent/scripted vehicles are flagged as mission entities; never
        -- delete those (personal/job/owned cars spawned by other resources).
        if IsEntityAMissionEntity(ent) then return true end
        -- plate registry: the reliable parked-car signal even when the per-entity
        -- statebag hasn't re-synced after a stream-in.
        local prot = GlobalState.hkParkedPlates
        if prot then
            local key = plateKey(GetVehicleNumberPlateText(ent))
            if key and prot[key] then return true end
        end
        -- stream-in grace: don't delete a vehicle we only just started seeing —
        -- give parked-car statebags/plate time to replicate first.
        if withinStreamGrace(ent) then return true end
    end
    return false
end

-- Expose the protection test so the traffic module (client/traffic.lua) never
-- tunes / spawns over player cars, hk-parking parked cars, our scenario props,
-- trains, or scripted mission vehicles. Same single-source-of-truth guard the
-- clear engine uses. (mine=false: we only care about the global protections.)
function Scn_isTrafficProtected(ent)
    return isProtected(ent, false)
end

-- Reliably delete an entity we may not own: take control, flag as mission
-- (so the engine lets go of it), then delete. This is what actually works —
-- the ClearAreaOf* natives alone miss most ambient peds/objects.
local function deleteEntitySafe(ent, mine)
    if not ent or ent == 0 or not DoesEntityExist(ent) then return end
    if isProtected(ent, mine) then return end   -- player cars, parked cars, our props
    if NetworkGetEntityIsNetworked(ent) then
        NetworkRequestControlOfEntity(ent)
    end
    SetEntityAsMissionEntity(ent, true, true)
    DeleteEntity(ent)
    if DoesEntityExist(ent) then
        -- last resort for stubborn map objects
        SetObjectAsNoLongerNeeded(ent)
        DeleteObject(ent)
    end
end

-- ── Per-zone clear pass ─────────────────────────────────────────────────────
local function doClear(z)
    local cx, cy, cz = z.x, z.y, z.z
    local radius = z.radius
    if z.shape == 'box' then
        radius = math.max(z.length, z.width) * 0.5 + 2.0
    end

    -- 1) Native area sweeps (cheap, catch a lot of ambient stuff at once).
    --    NOTE: ClearAreaOfVehicles AND ClearAreaOfObjects are DELIBERATELY NOT
    --    used — they're black-box natives that ignore our protection guard and
    --    would delete hk-parking's parked cars / our own placed scenario props.
    --    The guarded manual pool sweeps below handle vehicles and objects
    --    reliably AND skip protected entities. Peds/projectiles have nothing to
    --    protect, so their natives stay.
    if z.clr_peds        then ClearAreaOfPeds(cx, cy, cz, radius, 1) end
    if z.clr_projectiles then ClearAreaOfProjectiles(cx, cy, cz, radius, 0) end

    -- 2) Manual pool sweep — the reliable part. The natives above only touch
    --    entities the client owns; iterating the pools + force-deleting catches
    --    the rest (this is why peds/objects "didn't work" before).
    local myPed = PlayerPedId()
    -- `true` => returns the LAST vehicle even while on foot, so the car you just
    -- stepped out of inside a zone stays protected (was the reported bug).
    local myVeh = GetVehiclePedIsIn(myPed, true)

    if z.clr_peds then
        for _, ped in ipairs(GetGamePool('CPed')) do
            if ped ~= myPed and not IsPedAPlayer(ped) then
                -- don't delete a ped that's driving/riding (keeps player-driven
                -- and mission peds safe; ambient drivers die with their car below)
                if not IsPedInAnyVehicle(ped, false) or not vehicleHasPlayer(GetVehiclePedIsIn(ped, false)) then
                    local c = GetEntityCoords(ped)
                    if entIn(z, c.x, c.y, c.z) then deleteEntitySafe(ped, myVeh) end
                end
            end
        end
    end
    if z.clr_vehicles then
        for _, veh in ipairs(GetGamePool('CVehicle')) do
            local c = GetEntityCoords(veh)
            if entIn(z, c.x, c.y, c.z) then deleteEntitySafe(veh, myVeh) end
        end
    end
    if z.clr_objects then
        for _, obj in ipairs(GetGamePool('CObject')) do
            local c = GetEntityCoords(obj)
            if entIn(z, c.x, c.y, c.z) then deleteEntitySafe(obj, myVeh) end
        end
    end
end

-- Exposed so the editor's "Clear now" button can fire an immediate one-shot
-- clear on a specific zone regardless of its interval.
Scn_clearZoneNow = function(z)
    if z then doClear(z) end
end

-- Clear every enabled zone right now, regardless of interval/proximity. Returns
-- how many zones were swept. Used by the hub "CLEAR ALL NOW" button + command.
Scn_clearAllNow = function()
    local n = 0
    for _, z in ipairs(Zones) do
        if z.enabled then doClear(z); n = n + 1 end
    end
    return n
end

-- ── Path blocking (steer ambient AI away) ──────────────────────────────────
-- Roads/ped-node disabling is NOT persistent: the game re-enables nodes as the
-- world streams, so we re-assert every scan while the zone is active. We use
-- the AXIS-ALIGNED natives (SetRoadsInArea / SetPedPathsInArea) which have a
-- simple, well-defined signature — the previous angled version had the wrong
-- number of BOOL args and silently misfired.
--
-- Returns the axis-aligned bounding box (min/max corners) that fully contains
-- the zone (for a box, the rotated footprint's AABB).
local function zoneAABB(z)
    if z.shape == 'box' then
        local hr = math.rad(z.heading)
        local c, s = math.cos(hr), math.sin(hr)
        local hl, hw = z.length * 0.5, z.width * 0.5
        -- 4 rotated footprint corners; take min/max
        local minx, miny, maxx, maxy = math.huge, math.huge, -math.huge, -math.huge
        for _, o in ipairs({ {-hw,-hl}, {hw,-hl}, {hw,hl}, {-hw,hl} }) do
            local wx = z.x + (o[1] * c - o[2] * s)
            local wy = z.y + (o[1] * s + o[2] * c)
            if wx < minx then minx = wx end
            if wx > maxx then maxx = wx end
            if wy < miny then miny = wy end
            if wy > maxy then maxy = wy end
        end
        return minx, miny, z.z - z.height * 0.5 - 2.0, maxx, maxy, z.z + z.height * 0.5 + 2.0
    else
        local r = z.radius
        return z.x - r, z.y - r, z.z - r - 5.0, z.x + r, z.y + r, z.z + r + 5.0
    end
end

local function applyRoadPedBlocks(z)
    if not (z.blk_roads or z.blk_peds) then return end
    local x1, y1, z1, x2, y2, z2 = zoneAABB(z)
    if z.blk_roads then
        -- SET_ROADS_IN_AREA(x1,y1,z1, x2,y2,z2, nodeEnabled(bool), unknown(bool))
        -- nodeEnabled=false disables all vehicle road nodes in the box.
        SetRoadsInArea(x1, y1, z1, x2, y2, z2, false, false)
    end
    if z.blk_peds then
        -- SET_PED_PATHS_IN_AREA(x1,y1,z1, x2,y2,z2, enabled(bool), unknown(float))
        SetPedPathsInArea(x1, y1, z1, x2, y2, z2, false, 1.0)
    end
end

-- Navmesh blockers ARE persistent handles: create when a blk_navmesh zone goes
-- active, remove when it leaves active set. Keyed by zone id.
local navmeshHandles = {}  -- [zoneId] = handle

local function ensureNavmesh(z)
    if navmeshHandles[z.id] then return end
    local length = (z.shape == 'box') and z.length or (z.radius * 2.0)
    local width  = (z.shape == 'box') and z.width  or (z.radius * 2.0)
    -- ADD_NAVMESH_BLOCKING_OBJECT(x,y,z, sizeX,sizeY,sizeZ, headingRad, unk(bool), flags)
    -- flags 0 is the reliable value. NOTE: this only affects peds that pathfind
    -- via navmesh (scripted/fleeing peds) — ambient traffic is handled by the
    -- road-node block, wandering peds by the ped-path block.
    local h = AddNavmeshBlockingObject(z.x, z.y, z.z, length, width,
        math.max(z.height, 4.0), math.rad(z.heading), false, 0)
    navmeshHandles[z.id] = h
end

local function removeNavmesh(zoneId)
    local h = navmeshHandles[zoneId]
    if h then
        if RemoveNavmeshBlockingObject then RemoveNavmeshBlockingObject(h) end
        navmeshHandles[zoneId] = nil
    end
end

-- Drop all navmesh blockers on resource stop / resync so we never leak them.
local function clearAllNavmesh()
    for id, _ in pairs(navmeshHandles) do removeNavmesh(id) end
end
AddEventHandler('onClientResourceStop', function(res)
    if res == GetCurrentResourceName() then clearAllNavmesh() end
end)

-- ── Engine loop ─────────────────────────────────────────────────────────────
-- Two-tier: a cheap scan picks the active (nearby, enabled) zones; a fast
-- inner loop only runs while at least one zone is active, and each active
-- zone only fires when its own interval has elapsed.
CreateThread(function()
    local activeRangeSq = ScnCfg.Engine.activateRange * ScnCfg.Engine.activateRange
    while true do
        local ped = PlayerPedId()
        local p = GetEntityCoords(ped)
        local active = {}
        local activeById = {}

        for _, z in ipairs(Zones) do
            if z.enabled then
                local dx, dy = p.x - z.x, p.y - z.y
                if (dx * dx + dy * dy) <= activeRangeSq then
                    active[#active + 1] = z
                    activeById[z.id] = true
                    -- manage the persistent navmesh blocker
                    if z.blk_navmesh then ensureNavmesh(z) else removeNavmesh(z.id) end
                end
            end
        end

        -- Remove navmesh blockers for zones that are no longer active/enabled.
        for id, _ in pairs(navmeshHandles) do
            if not activeById[id] then removeNavmesh(id) end
        end

        if #active == 0 then
            -- Nothing near us: idle at the scan interval. Cheap.
            Wait(ScnCfg.Engine.scanInterval)
        else
            -- Something is near: run a tight loop for scanInterval ms, firing
            -- each active zone on its own cadence, then rescan.
            local deadline = GetGameTimer() + ScnCfg.Engine.scanInterval
            while GetGameTimer() < deadline do
                local now = GetGameTimer()
                for _, z in ipairs(active) do
                    -- road/ped blocks: re-assert every tick (they reset on stream)
                    applyRoadPedBlocks(z)
                    if (now - (lastClear[z.id] or 0)) >= z.interval then
                        doClear(z)
                        lastClear[z.id] = now
                    end
                end
                Wait(50)
            end
        end
    end
end)
