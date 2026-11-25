-- hk-race :: client/race.lua
-- Participant runtime. Native GTA checkpoints, auto-reroute waypoint on hit,
-- start-zone lobby, /quitrace. All visuals render ONLY on participant clients,
-- because the server only sends this data to participants.

local active = {
    raceId = nil,
    inLobby = false,
    started = false,
    isHost = false,
    start = nil,          -- {x,y,z,radius}
    blips = nil,
    checkpoints = nil,    -- full list {x,y,z,r}
    currentCp = 0,        -- next checkpoint index the player must reach (1-based)
    lastReported = 0,     -- highest CP index already reported to the server (anti-dupe)
    finishedLocal = false,-- client-side finish latch (server still authoritative for payout)
    startCpHandle = nil,  -- world checkpoint ring at the start zone (lobby only)
    cpBlips = {},         -- minimap blips on the next few checkpoints
    ghost = false,        -- ghost mode active (start of a busy race)
    slipstream = true,    -- slipstream allowed this race (host toggle)
}

-- ── Cleanup ────────────────────────────────────────────────────────────────
local function clearRaceVisuals()
    -- Checkpoints are DrawMarker (per-frame) now — stopping is just currentCp=0.
    active.currentCp = 0
    if active.startCpHandle then
        DeleteCheckpoint(active.startCpHandle)
        active.startCpHandle = nil
    end
    if active.cpBlips then
        for _, b in ipairs(active.cpBlips) do
            if DoesBlipExist(b) then RemoveBlip(b) end
        end
        active.cpBlips = {}
    end
    RaceUtil.removeBlips(active.blips)
    active.blips = nil
    SetWaypointOff()
end

-- Force-clear ghost state (player + current vehicle collision). Unconditional so a
-- quit mid-ghost can't leave the player intangible. Setting active.ghost=false also
-- stops the applyGhost render loop next frame.
local function clearGhost()
    active.ghost = false
    SetLocalPlayerAsGhost(false)
    local veh = GetVehiclePedIsIn(PlayerPedId(), false)
    if veh and veh ~= 0 then
        SetNetworkVehicleAsGhost(veh, false)
        SetEntityNoCollisionEntity(veh, PlayerPedId(), false)
    end
end

local function resetState()
    clearRaceVisuals()
    clearGhost()
    active.ghostMode = 'off'
    active.legal = false
    active.raceId = nil
    active.inLobby = false
    active.started = false
    active.isHost = false
    active.start = nil
    active.checkpoints = nil
    active.currentCp = 0
    active.lastReported = 0
    active.finishedLocal = false
    active.trackType = 'oneway'
    active.loopLine = nil
    active.finishLine = nil
    active.laps = 1
    active.lap = 1
    active.pos = 1
    active.total = 1
    active.lapStart = 0     -- GetGameTimer() at the start of the current lap/run
    active.bestLap = 0      -- best lap this session (ms) for the HUD
    active.timeAttack = false
end

-- Read-only race state for the HUD (client/hud.lua).
function RaceState()
    if not active.started then return nil end
    local total = active.checkpoints and #active.checkpoints or 0
    if active.trackType == 'loop' and active.loopLine then total = total + 1 end
    -- Live current-lap time so the HUD can tick; best lap for the record line.
    local liveLap = (active.lapStart > 0) and (GetGameTimer() - active.lapStart) or 0
    return {
        cp = active.currentCp, total = total,
        lap = active.lap, laps = active.laps,
        pos = active.pos, racers = active.total,
        isLoop = active.trackType == 'loop',
        name = active.trackName,
        finished = active.finishedLocal,
        bestLap = active.bestLap,
        liveLap = liveLap,
        legal = active.legal,
    }
end

-- True only if the local player is the DRIVER of a vehicle (seat -1). Passengers
-- don't race. Returns the vehicle too for convenience.
local function asDriver()
    local ped = PlayerPedId()
    local veh = GetVehiclePedIsIn(ped, false)
    if not veh or veh == 0 then return false end
    if GetPedInVehicleSeat(veh, -1) ~= ped then return false end   -- -1 = driver seat
    return true, veh
end

-- Called when a lap/run completes: measure, report to server, track local best.
local function recordLap()
    if active.lapStart <= 0 then return end
    local ms = GetGameTimer() - active.lapStart
    active.lapStart = GetGameTimer()   -- next lap starts now
    if ms > 0 then
        if active.bestLap == 0 or ms < active.bestLap then active.bestLap = ms end
        -- Vehicle label + spawn code + tier at the moment the lap completes.
        local vehicle, model, tier = '', '', 0
        local ped = PlayerPedId()
        if IsPedInAnyVehicle(ped, false) then
            local veh = GetVehiclePedIsIn(ped, false)
            local mdlHash = GetEntityModel(veh)
            -- Prefer the proper name from hk-handling's SpeedCalData (row.n, e.g.
            -- "Porsche 911 Targa GTS"). GetLabelText often returns an untranslated
            -- key/spawn code for addon vehicles, so try the cal name first.
            if GetResourceState('hk-handling') == 'started' then
                local hash = mdlHash & 0xFFFFFFFF
                local ok, row = pcall(function() return exports['hk-handling']:getSpeedCal(hash) end)
                if ok and type(row) == 'table' and row.n and row.n ~= '' then
                    vehicle = row.n
                end
            end
            if vehicle == '' then
                vehicle = GetLabelText(GetDisplayNameFromVehicleModel(mdlHash))
                if not vehicle or vehicle == '' or vehicle == 'NULL' then
                    vehicle = GetDisplayNameFromVehicleModel(mdlHash)
                end
            end
            model = tostring(GetDisplayNameFromVehicleModel(mdlHash)):lower()
            local t = (RaceTier and RaceTier.current and RaceTier.current()) or nil
            tier = (t and t.tier) or 0
        end
        TriggerServerEvent('hk-race:race:lapTime', active.raceId, ms, vehicle, model, tier)
    end
end

-- ── Native checkpoint + waypoint for a given checkpoint index ──────────────
-- The client is AUTHORITATIVE for visual progression: it spawns the next
-- checkpoint immediately on arrival, without waiting for a server round-trip.
-- The server still validates order + pays out (anti-cheat); its advance message
-- is just async confirmation. This kills the "checkpoint spawns late so I miss
-- it" bug on laggy clients.
-- Per-lap sequence length: one-way = #checkpoints; loop = #checkpoints + 1 (the
-- loop line is a virtual final target at index N+1).
local function seqLen()
    local n = active.checkpoints and #active.checkpoints or 0
    if active.trackType == 'loop' and active.loopLine then n = n + 1 end
    return n
end

-- The target {x,y,z,r} for a sequence index (a checkpoint, or the lap/finish line).
-- On a loop, the last index (N+1) is the LAP line on laps 1..N-1, and the FINAL
-- FINISH line on the last lap (falling back to the lap line if none was set).
local function targetAt(index)
    local cps = active.checkpoints
    if not cps then return nil end
    if cps[index] then return cps[index] end
    if active.trackType == 'loop' and active.loopLine and index == #cps + 1 then
        local finalLap = (active.lap or 1) >= (active.laps or 1)
        if finalLap and active.finishLine then return active.finishLine end
        return active.loopLine
    end
    return nil
end

-- Minimap blips on the next N checkpoints from `fromIndex`. Current target is
-- highlighted; upcoming ones dimmer. Finish/loop line get their own colour.
local function refreshCpBlips(fromIndex)
    -- Clear old blips.
    if active.cpBlips then
        for _, b in ipairs(active.cpBlips) do
            if DoesBlipExist(b) then RemoveBlip(b) end
        end
    end
    active.cpBlips = {}
    local n = RaceConfig.Race.minimapBlips or 0
    if n <= 0 then return end
    local total = seqLen()
    local finalLap = (active.lap or 1) >= (active.laps or 1)
    for i = fromIndex, math.min(fromIndex + n - 1, total) do
        local cp = targetAt(i)
        if cp then
            local blip = AddBlipForCoord(cp.x, cp.y, cp.z)
            SetBlipSprite(blip, RaceConfig.Race.blipSprite or 1)
            SetBlipScale(blip, i == fromIndex and 0.9 or 0.7)
            SetBlipAsShortRange(blip, false)
            local lastOfSeq = (i >= total)
            local color
            if lastOfSeq and finalLap then color = RaceConfig.Race.blipColorFinish
            elseif lastOfSeq then color = RaceConfig.Race.blipColorLoop
            elseif i == fromIndex then color = RaceConfig.Race.blipColorCurrent
            else color = RaceConfig.Race.blipColorUpcoming end
            SetBlipColour(blip, color)
            ShowNumberOnBlip(blip, i)   -- number = checkpoint index this lap
            BeginTextCommandSetBlipName('STRING')
            AddTextComponentSubstringPlayerName(('Checkpoint %d'):format(i))
            EndTextCommandSetBlipName(blip)
            active.cpBlips[#active.cpBlips + 1] = blip
        end
    end
end

-- Checkpoints are drawn with DrawMarker (per-frame, NO native checkpoint pool) so
-- there's no ~128 handle cap — works for any track length / lap count. setCheckpoint
-- just records which index is current; the render thread below draws it each frame.
local function setCheckpoint(index)
    if not targetAt(index) then
        active.currentCp = 0
        return
    end
    -- Auto-set the GPS waypoint to this target (route drawn on minimap).
    local cp = targetAt(index)
    SetNewWaypoint(cp.x, cp.y)
    -- Minimap blips on the next few checkpoints so the route reads ahead.
    refreshCpBlips(index)
    active.currentCp = index
end

-- Draw one checkpoint marker: a colored vertical cylinder (the ring) plus a symbol
-- on top — chevron-down for a normal checkpoint, checkered-flag for the finish/lap.
-- markerKind: 'cp' | 'finish' | 'loop' | 'next' | 'alt'
local function drawCpMarker(cp, kind)
    local col, ringType, topType
    if kind == 'finish' then col = RaceConfig.Race.checkpointFinishColor
    elseif kind == 'loop' then col = RaceConfig.Race.checkpointLoopColor
    elseif kind == 'next' then col = RaceConfig.Race.checkpointNextColor
    elseif kind == 'alt' then col = RaceConfig.Race.checkpointAltColor or { r = 255, g = 140, b = 20, a = 120 }
    else col = RaceConfig.Race.checkpointColor end
    local r = (cp.r or 8.0)
    local scale = (kind == 'next') and (RaceConfig.Race.checkpointNextScale or 0.7) or 1.0
    local dia = r * 2.0 * scale
    local h = RaceConfig.Race.checkpointHeight or 3.0
    -- Ring: vertical cylinder (marker type 1) on the ground.
    DrawMarker(1, cp.x, cp.y, cp.z - 1.0, 0,0,0, 0,0,0, dia, dia, h,
        col.r, col.g, col.b, col.a, false, false, 2, false, nil, nil, false)
    -- Floating indicator in the SKY pointing DOWN at the checkpoint. Type 0 =
    -- upside-down cone (points down). Kept transparent so it doesn't block the road.
    -- Finish/loop keep the checkered flag (type 4) instead, also floated + see-through.
    if kind ~= 'next' and kind ~= 'alt' then
        local floatH = RaceConfig.Race.checkpointArrowHeight or 6.0
        local sz = RaceConfig.Race.checkpointArrowSize or 2.5
        local aAlpha = RaceConfig.Race.checkpointArrowAlpha or 90
        if kind == 'finish' or kind == 'loop' then
            DrawMarker(4, cp.x, cp.y, cp.z + floatH, 0,0,0, 0,0,0, sz, sz, sz,
                col.r, col.g, col.b, aAlpha, true, false, 2, false, nil, nil, false)
        else
            -- bobbing upside-down cone hovering above, pointing at the ring.
            DrawMarker(0, cp.x, cp.y, cp.z + floatH, 0,0,0, 0,0,0, sz, sz, sz,
                col.r, col.g, col.b, aAlpha, true, true, 2, false, nil, nil, false)
        end
    end
end

-- Per-frame checkpoint render (only while racing). Draws current target (+ its
-- alts) and the dimmed next-target preview. No pool, no handles, no cap.
CreateThread(function()
    while true do
        local sleep = 500
        if active.started and active.currentCp and active.currentCp > 0 and not active.finishedLocal then
            sleep = 0
            local idx = active.currentCp
            local cp = targetAt(idx)
            if cp then
                local total = seqLen()
                local lastOfSeq = (idx >= total)
                local finalLap = (active.lap or 1) >= (active.laps or 1)
                local kind = 'cp'
                if lastOfSeq and finalLap then kind = 'finish'
                elseif lastOfSeq then kind = 'loop' end
                drawCpMarker(cp, kind)
                -- Alternate locations of this checkpoint (orange), if any.
                if cp.alts then
                    for _, a in ipairs(cp.alts) do drawCpMarker(a, 'alt') end
                end
                -- Dimmed preview of the next target.
                if RaceConfig.Race.showNext and kind == 'cp' then
                    local nextCp = targetAt(idx + 1)
                    if nextCp then drawCpMarker(nextCp, 'next') end
                end
            end
        end
        Wait(sleep)
    end
end)

-- ── Advertised lobbies (server sends these only to non-emergency players, only
-- after the host reaches the zone). Declared here so enterLobby can clear them. ──
local openLobbies = {}   -- [raceId] = { start, trackName, blips }

local function clearAdvertisedLobby(rid)
    local lob = openLobbies[rid]
    if lob and lob.blips then RaceUtil.removeBlips(lob.blips) end
    openLobbies[rid] = nil
end

-- ── Lobby: enter host/join start zone ──────────────────────────────────────
RegisterNetEvent('hk-race:client:enterLobby', function(data)
    resetState()
    active.raceId = data.raceId
    active.inLobby = true
    active.isHost = data.isHost
    active.start = data.start

    -- If we were showing this race as an advertised lobby blip, drop it (the
    -- participant blip below replaces it) to avoid a duplicate.
    clearAdvertisedLobby(data.raceId)

    active.blips = RaceUtil.createStartBlip(data.start, data.legal)
    SetNewWaypoint(data.start.x, data.start.y)  -- guide host/joiner to start

    -- World checkpoint ring at the start zone so you can see it in-world (not just
    -- the map). Blue for legal races, red for illegal. Cleared when the race begins.
    do
        local s = data.start
        local col = data.legal and { r = 40, g = 130, b = 255 } or { r = 255, g = 40, b = 40 }
        local h = 5.0   -- start ring: a touch taller than checkpoints (gathering zone), still see-through
        local handle = CreateCheckpoint(1, s.x, s.y, s.z - 1.0, s.x, s.y + 1.0, s.z,
            (s.radius or 15.0) * 2.0, col.r, col.g, col.b, 110, 0)
        SetCheckpointCylinderHeight(handle, h, h, (s.radius or 15.0) * 2.0)
        active.startCpHandle = handle
    end

    active.minPlayers = data.minPlayers or 1
    if data.isHost then
        RaceUtil.notify(L('race_hosting'), 'success')
        if (data.minPlayers or 1) > 1 then
            RaceUtil.notify(L('race_need_players', data.minPlayers), 'inform')
        end
        -- Watch for the host arriving inside their own start zone. Only then do we
        -- ask the server to advertise the lobby to other (non-police/ems) players.
        if data.watchArrival then
            CreateThread(function()
                local rid = data.raceId
                local s = data.start
                while active.raceId == rid and active.inLobby and not active.started do
                    local pos = GetEntityCoords(PlayerPedId())
                    -- Host must be the DRIVER inside the zone to open the lobby.
                    if asDriver() and #(pos - vector3(s.x, s.y, s.z)) <= s.radius then
                        TriggerServerEvent('hk-race:race:hostReachedZone', rid)
                        RaceUtil.notify(L('race_zone_open'), 'success')
                        break
                    end
                    Wait(750)
                end
            end)
        end
    else
        RaceUtil.notify(L('race_joined'), 'success')
    end
end)

RegisterNetEvent('hk-race:client:lobbyUpdate', function(data)
    if not active.inLobby then return end
    RaceUtil.notify(L('race_waiting_min', data.count or 0, data.min or active.minPlayers or 1), 'inform')
end)

-- Enough players gathered → grace countdown before the actual start.
RegisterNetEvent('hk-race:client:graceCountdown', function(data)
    RaceUtil.notify(L('race_grace', data.secs or 30), 'success')
end)

-- Server advertises an open lobby (only to non-emergency players, only after the
-- host reaches the zone). Show a start blip so they can navigate in to join.
RegisterNetEvent('hk-race:client:lobbyOpen', function(data)
    if openLobbies[data.raceId] then return end
    -- Already the host/participant of this race → track coords but no extra blip.
    if active.raceId == data.raceId then
        openLobbies[data.raceId] = { start = data.start, trackName = data.trackName }
        return
    end
    local blips = RaceUtil.createStartBlip(data.start, data.legal)
    openLobbies[data.raceId] = { start = data.start, trackName = data.trackName, blips = blips }
    RaceUtil.notify(L('race_nearby', data.trackName or 'A race'), 'inform')
end)

RegisterNetEvent('hk-race:client:lobbyClose', function(rid)
    clearAdvertisedLobby(rid)
end)

-- Tier-restricted race rejected our join (throttled so standing in the zone in a
-- wrong-tier car doesn't spam).
local lastTierBlockNotify = 0
RegisterNetEvent('hk-race:client:tierBlocked', function(data)
    local now = GetGameTimer()
    if now - lastTierBlockNotify < 5000 then return end
    lastTierBlockNotify = now
    local cls = data.yourTier and RaceConfig.Tiers.names[data.yourTier]
    local mine = cls and ('Class ' .. cls) or 'your vehicle'
    RaceUtil.notify(('%s can\'t join — allowed classes: %s. Swap cars and re-enter the zone.')
        :format(mine, tostring(data.allowed)), 'error')
end)

-- Watch open start zones: if this player (not already in a race) walks into one,
-- request to join. The server gates membership and authoritatively adds us.
CreateThread(function()
    while true do
        local sleep = 1000
        if not active.raceId and next(openLobbies) then
            local pos = GetEntityCoords(PlayerPedId())
            local driving = asDriver()
            for rid, lobby in pairs(openLobbies) do
                local s = lobby.start
                if driving and #(pos - vector3(s.x, s.y, s.z)) <= s.radius then
                    -- Only the DRIVER joins. Passengers in the zone are ignored.
                    local ti = (RaceTier and RaceTier.current and RaceTier.current()) or nil
                    TriggerServerEvent('hk-race:race:joinZone', rid, ti and ti.tier or nil)
                    sleep = 3000  -- debounce; server will move us into the lobby
                    break
                end
            end
            if sleep == 1000 then sleep = 750 end
        end
        Wait(sleep)
    end
end)

-- Ghost mode for the busy-race grid: no collision with other racers for the first
-- few seconds so the pack doesn't pile up. Uses SetLocalPlayerAsGhost + per-vehicle
-- network ghosting; auto-clears after ghostDurationMs.
-- mode: 'start' = ghost for ghostDurationMs from GO; 'full' = ghost the whole race.
local function applyGhost(mode)
    active.ghost = true
    local timed = (mode ~= 'full')
    local durMs = RaceConfig.Race.ghostDurationMs or 15000
    if timed then RaceUtil.notify(L('race_ghost_on', math.floor(durMs / 1000)), 'inform')
    else RaceUtil.notify(L('race_ghost_full'), 'inform') end
    CreateThread(function()
        local endAt = GetGameTimer() + durMs
        -- Also stop if we're no longer in a race at all (quit clears active.raceId).
        while active.raceId and active.started and active.ghost and (not timed or GetGameTimer() < endAt) do
            SetLocalPlayerAsGhost(true)
            local veh = GetVehiclePedIsIn(PlayerPedId(), false)
            if veh and veh ~= 0 then
                SetNetworkVehicleAsGhost(veh, true)
                SetEntityNoCollisionEntity(veh, PlayerPedId(), true)
            end
            Wait(0)
        end
        clearGhost()   -- unconditional reset (player + vehicle collision)
        if active.started and timed then RaceUtil.notify(L('race_ghost_off'), 'inform') end
    end)
end

-- Safety net: if we're NOT in a race but the game still has us ghosted (a stray
-- frame-order edge case on quit), force it off. Cheap 1s poll.
CreateThread(function()
    while true do
        Wait(1000)
        if not active.raceId then
            local ped = PlayerPedId()
            local veh = GetVehiclePedIsIn(ped, false)
            -- Only correct if something left us ghosted while not racing.
            if active.ghost then clearGhost() end
            SetLocalPlayerAsGhost(false)
            if veh and veh ~= 0 then SetNetworkVehicleAsGhost(veh, false) end
        end
    end
end)

-- ── Race begin: countdown, then activate checkpoints ────────────────────────
RegisterNetEvent('hk-race:client:raceBegin', function(data)
    if active.raceId ~= data.raceId then
        -- Late bind (e.g. joined via zone): accept server authority.
        active.raceId = data.raceId
    end
    active.inLobby = false
    active.checkpoints = data.checkpoints
    active.started = true
    active.lastReported = 0
    active.finishedLocal = false
    active.trackType = data.trackType or 'oneway'
    active.loopLine = data.loopLine
    active.finishLine = data.finishLine
    active.laps = data.laps or 1
    active.lap = 1
    active.total = data.total or 1
    active.pos = 1
    active.trackName = data.trackName or 'Race'
    active.ghostMode = data.ghostMode or 'start'      -- 'off' | 'start' | 'full'
    active.ghost = false
    active.slipstream = (data.slipstream ~= false)   -- host toggle; default on
    active.legal = data.legal and true or false
    active.timeAttack = data.timeAttack and true or false   -- solo run: perma-ghost + boosted repair, record-gated payout

    -- Countdown overlay.
    CreateThread(function()
        local n = data.countdown or 3
        while n > 0 do
            RaceUtil.notify(L('race_countdown', n), 'warning')
            PlaySoundFrontend(-1, 'MP_5_SECOND_TIMER', 'HUD_MINI_GAME_SOUNDSET', true)
            Wait(1000)
            n = n - 1
        end
        RaceUtil.notify(L('race_go'), 'success')
        PlaySoundFrontend(-1, 'GO', 'HUD_MINI_GAME_SOUNDSET', true)
        -- Remove start blips + start-zone ring, arm first checkpoint, start clock.
        RaceUtil.removeBlips(active.blips)
        active.blips = nil
        if active.startCpHandle then DeleteCheckpoint(active.startCpHandle); active.startCpHandle = nil end
        active.lapStart = GetGameTimer()
        setCheckpoint(1)
        RaceUtil.notify(L('race_next_cp', 1, #active.checkpoints), 'inform')
        if active.ghostMode == 'start' or active.ghostMode == 'full' then
            applyGhost(active.ghostMode)
        end
        if active.timeAttack then RaceUtil.notify(L('race_ta_on'), 'inform') end
    end)
end)

-- Server confirms advance. Two cases:
--  * Normal: safety re-sync — only snap forward if the client fell behind.
--  * Lap re-arm (data.lap set, next==1): a new lap began; reset local progress and
--    arm checkpoint 1 fresh.
RegisterNetEvent('hk-race:client:advanceCheckpoint', function(data)
    if active.finishedLocal then return end
    if data.lap then                      -- new lap: server authoritative reset
        active.lap = data.lap
        if data.laps then active.laps = data.laps end
        active.lastReported = 0
        setCheckpoint(1)
    elseif data.next and data.next > active.currentCp then
        setCheckpoint(data.next)
    end
end)

-- Lap counter update (HUD). Fires alongside the re-arm above.
RegisterNetEvent('hk-race:client:lapUpdate', function(data)
    active.lap = data.lap or active.lap
    active.laps = data.laps or active.laps
    RaceUtil.notify(L('race_lap', active.lap, active.laps), 'inform')
end)

-- Live standings (position / total) for the HUD.
RegisterNetEvent('hk-race:client:standings', function(data)
    active.pos = data.pos or active.pos
    active.total = data.total or active.total
end)

-- A new track record was set (by anyone in this race).
RegisterNetEvent('hk-race:client:newRecord', function(data)
    RaceUtil.notify(L('race_new_record', data.name or '?', fmtTime and fmtTime(data.ms) or tostring(data.ms)), 'success')
end)

RegisterNetEvent('hk-race:client:finished', function(data)
    clearRaceVisuals()
    active.started = false
    if data.timeAttack then
        if data.taRecord then
            RaceUtil.notify(L('race_ta_record', data.reward or L('race_finished_none', 1)), 'success')
            if (data.laps or 1) > 1 then RaceUtil.notify(L('race_lap_payout', data.laps), 'inform') end
            if data.copBonus then
                RaceUtil.notify(L('race_police_bonus', data.copBonus, data.copCount or 0), 'success')
            end
        elseif data.gateMs then
            RaceUtil.notify(L('race_ta_no_record', fmtTime and fmtTime(data.gateMs) or tostring(data.gateMs)), 'inform')
        else
            RaceUtil.notify(L('race_ta_no_record_nb'), 'inform')
        end
        SetTimeout(4000, resetState)
        return
    end
    if data.reward then
        if data.place == 1 then
            RaceUtil.notify(L('race_finished_win', data.reward), 'success')
        else
            RaceUtil.notify(L('race_finished_pos', data.place, data.reward), 'success')
        end
        if (data.laps or 1) > 1 then
            RaceUtil.notify(L('race_lap_payout', data.laps), 'inform')
        end
        if data.copBonus then
            RaceUtil.notify(L('race_police_bonus', data.copBonus, data.copCount or 0), 'success')
        end
        if data.reduced then
            -- Low turnout: prizes halved AND shifted down (awarded a lower prize slot).
            if data.prizeSlot and data.prizeSlot ~= data.place then
                RaceUtil.notify(L('race_reduced_slot', data.prizeSlot), 'inform')
            else
                RaceUtil.notify(L('race_reduced_payout'), 'inform')
            end
        end
    else
        RaceUtil.notify(L('race_finished_none', data.place), 'inform')
    end
    SetTimeout(4000, resetState)
end)

RegisterNetEvent('hk-race:client:raceEnded', function(data)
    if data and data.reason == 'quit' then
        RaceUtil.notify(L('race_quit'), 'inform')
    elseif data and data.reason == 'timeout' then
        RaceUtil.notify(L('race_timeout'), 'error')
    end
    resetState()
end)

-- Report a reached checkpoint to the server exactly once (server validates order,
-- pays out, and confirms finish). Client-side dedupe via lastReported.
local function reportCheckpoint(index)
    if index <= active.lastReported then return end
    active.lastReported = index
    TriggerServerEvent('hk-race:race:checkpoint', active.raceId, index)
end

-- Passing a checkpoint patches the car up (bigger boost the more damaged you are):
--   ≥85% → nothing        75-85% → +3%
--   65-75% → +5%          55-65% → +10%
--   <55%  → set to 60% (a proper bonus for a wreck)
-- Health scale is 0-1000; % = health/10.
local function repairAtCheckpoint()
    local ped = PlayerPedId()
    if not IsPedInAnyVehicle(ped, false) then return end
    local veh = GetVehiclePedIsIn(ped, false)
    if not veh or veh == 0 then return end
    -- Damage that actually affects DRIVING is engine + body health (0-1000 each),
    -- NOT entity health (which can read ~full while the engine is trashed). Use the
    -- WORSE of engine/body as the % so a blown engine is correctly seen as damaged.
    local eng = GetVehicleEngineHealth(veh)   -- 0..1000
    local body = GetVehicleBodyHealth(veh)    -- 0..1000
    local pct = math.min(eng, body) / 10.0    -- → 0..100
    -- Time Attack (solo) heals faster: the per-band GAIN is scaled up, and the
    -- wreck floor is lifted. There's no rival to out-repair, so a solo run is
    -- about the clean lap — a rough checkpoint shouldn't end the attempt.
    local boost = 1.0
    if active.timeAttack then
        local ta = RaceConfig.Race.timeAttack
        boost = (ta and ta.repairBoostMult) or 1.0
    end
    local newPct
    if pct >= 85.0 then return
    elseif pct >= 75.0 then newPct = pct + 3.0 * boost
    elseif pct >= 65.0 then newPct = pct + 5.0 * boost
    elseif pct >= 55.0 then newPct = pct + 10.0 * boost
    else newPct = (boost > 1.0) and (60.0 + (boost - 1.0) * 15.0) or 60.0 end
    if newPct > 100.0 then newPct = 100.0 end
    local target = newPct * 10.0   -- back to 0..1000
    -- Only raise (never lower) each component to the new floor.
    if eng < target then SetVehicleEngineHealth(veh, target) end
    if body < target then SetVehicleBodyHealth(veh, target) end
    -- Entity health too, scaled to its own max, so it's consistent.
    local maxHp = GetEntityMaxHealth(veh); if maxHp <= 0 then maxHp = 1000 end
    local newHp = math.floor(maxHp * (newPct / 100.0))
    if GetEntityHealth(veh) < newHp then SetEntityHealth(veh, newHp) end
    -- Also clear a stalled/on-fire engine if we pulled it up from a wreck.
    if pct < 55.0 then SetVehicleUndriveable(veh, false); SetVehicleEngineOn(veh, true, true, false) end
end

-- ── Checkpoint arrival detection ────────────────────────────────────────────
-- Client owns progression: on arrival we advance LOCALLY and immediately, and we
-- catch up through any targets already inside our radius (covers lag). On a loop,
-- reaching the last target (the loop line) mid-race hands off to the server, which
-- bumps the lap and re-arms checkpoint 1 (lapUpdate/advanceCheckpoint) — infrequent,
-- so the round-trip there is fine.
CreateThread(function()
    while true do
        local sleep = 500
        if active.started and active.checkpoints and active.currentCp > 0 and not active.finishedLocal then
            sleep = 0
            local total = seqLen()
            local finalLap = (active.lap or 1) >= (active.laps or 1)
            local pos = GetEntityCoords(PlayerPedId())
            local advanced = false
            while active.currentCp > 0 and active.currentCp <= total do
                local cp = targetAt(active.currentCp)
                if not cp then break end
                -- HORIZONTAL distance only (X/Y) so height doesn't matter — you can
                -- fly/jump/stunt over the checkpoint at any altitude and still hit it.
                -- A wide vertical window (below ground to well overhead) guards against
                -- passing under bridges / big jumps while still ignoring far-above.
                local dx, dy = pos.x - cp.x, pos.y - cp.y
                local d = math.sqrt(dx * dx + dy * dy)
                local dz = math.abs(pos.z - cp.z)
                if d <= (cp.r or 8.0) and dz <= (RaceConfig.Race.checkpointVertTol or 50.0) then
                    local reached = active.currentCp
                    -- On the end of a lap's sequence, report the LAP TIME *before* the
                    -- checkpoint event. The server gates the Time-Attack payout on beating
                    -- the per-tier record, so lapTime (which records the attempt + decides
                    -- the record) must land before checkpoint (which runs doFinish). Both
                    -- go out on the same reliable channel in this order.
                    if reached >= total then recordLap() end
                    reportCheckpoint(reached)
                    repairAtCheckpoint()   -- patch the car up on every checkpoint
                    advanced = true
                    if reached >= total then
                        if finalLap then
                            -- True finish: latch; server sends payout result.
                            active.finishedLocal = true
                            active.lapStart = 0
                            active.currentCp = 0   -- stops the DrawMarker render
                            PlaySoundFrontend(-1, 'CHECKPOINT_PERFECT', 'HUD_MINI_GAME_SOUNDSET', true)
                        else
                            -- Lap done: pause local detection until server re-arms CP1
                            -- (lapUpdate resets lastReported + advanceCheckpoint next=1).
                            active.currentCp = 0
                            PlaySoundFrontend(-1, 'CHECKPOINT_PERFECT', 'HUD_MINI_GAME_SOUNDSET', true)
                        end
                        break
                    else
                        setCheckpoint(reached + 1)   -- immediate, no server wait
                    end
                else
                    break
                end
            end
            if advanced and active.currentCp > 0 then
                PlaySoundFrontend(-1, 'CHECKPOINT_PERFECT', 'HUD_MINI_GAME_SOUNDSET', true)
            end
        end
        Wait(sleep)
    end
end)

-- /quitrace
-- True if the player is in a race or its lobby (used by /racemenu to show Leave).
function RaceActive() return active.raceId ~= nil end

-- Leave the current race/lobby (shared by /quitrace and the /racemenu Leave button).
function LeaveRace()
    if active.raceId then
        TriggerServerEvent('hk-race:race:quit')
        resetState()
        RaceUtil.notify(L('race_quit'), 'inform')
    end
end

RegisterCommand(RaceConfig.QuitCommand, function() LeaveRace() end, false)

-- On-foot guard: during an ACTIVE (started) race you must be driving a vehicle.
-- Being on foot / only a passenger past onFootGraceMs auto-removes you (changing
-- cars mid-race is fine while the gap stays under the grace).
CreateThread(function()
    local offSince = nil
    local warned = false
    while true do
        local sleep = 1000
        if active.raceId and active.started and not active.finishedLocal then
            if asDriver() then
                offSince = nil; warned = false
            else
                offSince = offSince or GetGameTimer()
                local elapsed = GetGameTimer() - offSince
                local grace = RaceConfig.Race.onFootGraceMs or 20000
                if not warned and elapsed > 3000 then
                    warned = true
                    RaceUtil.notify(L('race_get_in_car', math.floor(grace / 1000)), 'error')
                end
                if elapsed >= grace then
                    RaceUtil.notify(L('race_left_onfoot'), 'error')
                    LeaveRace()
                    offSince = nil; warned = false
                end
            end
        else
            offSince = nil; warned = false
            sleep = 1500
        end
        Wait(sleep)
    end
end)

-- /startrace — host starts immediately without waiting for the solo timer.
RegisterCommand('startrace', function()
    if not (active.raceId and active.isHost and active.inLobby and not active.started) then return end
    -- The host must be standing inside the start circle to force-start.
    local s = active.start
    if s then
        local pos = GetEntityCoords(PlayerPedId())
        if #(pos - vector3(s.x, s.y, s.z)) > (s.radius or 15.0) then
            RaceUtil.notify(L('race_start_need_zone'), 'error')
            return
        end
    end
    TriggerServerEvent('hk-race:race:forceStart', active.raceId)
end, false)

AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() then
        clearRaceVisuals()
        for rid in pairs(openLobbies) do clearAdvertisedLobby(rid) end
    end
end)

-- ── Slipstream / drafting (light, capped) ───────────────────────────────────
-- While racing in a vehicle, if you're tucked closely behind another car (moving,
-- roughly ahead), get a LIGHT power boost. Boost runs at most maxMs, then a forced
-- cooldownMs pause before it can build again. Detection is a cheap nearest-vehicle
-- + cone check; boost via SetVehicleCheatPowerIncrease (engine-native, no teleport).
CreateThread(function()
    local SS = RaceConfig.Race.slipstream
    local boosting = false
    local boostElapsed = 0     -- ms of boost used in the current window
    local cooldownUntil = 0
    local lastTick = GetGameTimer()

    local function setPower(veh, on)
        SetVehicleCheatPowerIncrease(veh, on and SS.mult or 1.0)
    end

    while true do
        local sleep = 500
        local active_ok = SS and SS.enabled and active.started and active.slipstream
            and not active.finishedLocal
        local ped = active_ok and PlayerPedId() or nil
        local veh = (ped and IsPedInAnyVehicle(ped, false)) and GetVehiclePedIsIn(ped, false) or nil

        if veh and veh ~= 0 then
            sleep = 100
            local now = GetGameTimer()
            local dt = now - lastTick; lastTick = now
            local mySpeed = GetEntitySpeed(veh) * 3.6   -- km/h

            -- Find a lead vehicle roughly ahead within range.
            local drafting = false
            if mySpeed >= SS.minSpeed then
                local pos = GetEntityCoords(veh)
                local fwd = GetEntityForwardVector(veh)
                local lead = nil
                -- Check vehicles in a forward probe (cheap: sample a point ahead + closest).
                local probe = pos + fwd * (SS.range * 0.6)
                local cand = GetClosestVehicle(probe.x, probe.y, probe.z, SS.range, 0, 70)
                if cand and cand ~= 0 and cand ~= veh then
                    local cpos = GetEntityCoords(cand)
                    local to = cpos - pos
                    local dist = #(to)
                    if dist >= SS.minRange and dist <= SS.range then
                        local dir = to / dist
                        local dot = fwd.x * dir.x + fwd.y * dir.y + fwd.z * dir.z
                        if dot >= SS.coneDot and GetEntitySpeed(cand) * 3.6 >= SS.minSpeed then
                            drafting = true
                        end
                    end
                end
            end

            -- Boost state machine: build while drafting, cap at maxMs, then cooldown.
            if now < cooldownUntil then
                drafting = false            -- forced pause
            end
            if drafting then
                boostElapsed = boostElapsed + dt
                if boostElapsed >= SS.maxMs then
                    -- Cap hit: stop and start cooldown.
                    if boosting then setPower(veh, false); boosting = false end
                    cooldownUntil = now + SS.cooldownMs
                    boostElapsed = 0
                    RaceUtil.notify(L('race_slip_cool'), 'inform')
                else
                    if not boosting then setPower(veh, true); boosting = true end
                end
            else
                if boosting then setPower(veh, false); boosting = false end
                -- Recover the boost budget while not drafting (once cooldown clears).
                if now >= cooldownUntil and boostElapsed > 0 then
                    boostElapsed = math.max(0, boostElapsed - dt)
                end
            end
        else
            -- Not in a vehicle / not racing: ensure power is normal.
            if boosting and veh and veh ~= 0 then setPower(veh, false) end
            boosting = false; boostElapsed = 0; cooldownUntil = 0
            lastTick = GetGameTimer()
        end
        Wait(sleep)
    end
end)

