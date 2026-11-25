-- hk-race :: client/h2h.lua
-- HEAD-TO-HEAD: horn-twice street challenge. Native Lua reimplementation of the
-- old (broken, DLL-based) ImpromptuRaces. Meet a driver, tap the HORN TWICE, pick
-- a finish (dash-ahead or nearest fixed line), challenge the nearest driver 1v1.
-- Full contact (no ghosting). Optional wager: both stake the same, winner takes all.
--
-- Flow: [horn x2] → arm → host picks finish [1]/[2] → server invites target →
-- target [Y]/[N] → server escrows stakes → both GO → first to finish wins.

local CFG = function() return RaceConfig.H2H end

local H = {
    stake        = 0,        -- host's chosen wager (local intent; server is authoritative)
    lastArmAt    = 0,        -- host cooldown gate
    -- arming (host side, after the double horn, before a finish is picked)
    armed        = false,
    armTarget    = nil,      -- server id of the nearest driver we'll challenge
    armTargetName = nil,
    armExpire    = 0,
    armFixed     = nil,      -- nearest fixed finish line {x,y,z,r} or nil if none near
    -- incoming invite (target side)
    incoming     = nil,      -- { host, hostName, stake, finish } while a prompt is shown
    incomingExpire = 0,
    -- active race (either side)
    inRace       = false,
    started      = false,    -- past the countdown (GO)
    finishedLocal = false,
    raceId       = nil,
    finish       = nil,      -- { x, y, z, r }
    finishBlip   = nil,
}

-- ── Small helpers ───────────────────────────────────────────────────────────
-- Stake display. v1 wager currency is cash; HOMECOIN would branch here later.
function formatStake(amount)
    local w = RaceConfig.H2H and RaceConfig.H2H.wager
    if w and w.currency == 'coins' then return ('%d HOMECOIN'):format(amount) end
    return ('$%d'):format(amount)
end

-- ── Per-player H2H enable (default OFF) ──────────────────────────────────────
-- Opt-in so honking in traffic never arms a challenge. Persisted via KVP and
-- toggled from the racemenu top bar. RaceConfig.H2H.enabled is the global
-- kill-switch; this is the player's personal switch on top of it.
local H2H_KVP = 'hk_race_h2h_on'
local h2hOn = false
CreateThread(function()
    h2hOn = GetResourceKvpInt(H2H_KVP) == 1
end)
local function h2hActive() return (CFG() and CFG().enabled) and h2hOn end
local function setH2hOn(v)
    h2hOn = v and true or false
    SetResourceKvpInt(H2H_KVP, h2hOn and 1 or 0)
end
-- expose current state to the NUI (picker reads this to render the toggle/bet)
exports('h2hGetState', function()
    return { on = h2hOn, stake = H.stake or 0,
             globalEnabled = (CFG() and CFG().enabled) and true or false }
end)

local function playerVeh()
    local ped = PlayerPedId()
    if not IsPedInAnyVehicle(ped, false) then return nil end
    local veh = GetVehiclePedIsIn(ped, false)
    if not veh or veh == 0 then return nil end
    -- Must be the DRIVER (seat -1), not a passenger.
    if GetPedInVehicleSeat(veh, -1) ~= ped then return nil end
    return veh
end

local function isBusy()
    if H.inRace or H.armed then return true end
    -- Also busy if in a normal hk-race (RaceActive is defined in client/race.lua).
    if RaceActive and RaceActive() then return true end
    return false
end

local function clearFinishVisual()
    if H.finishBlip and DoesBlipExist(H.finishBlip) then RemoveBlip(H.finishBlip) end
    H.finishBlip = nil
end

local function resetH2H()
    clearFinishVisual()
    H.armed, H.armTarget, H.armTargetName, H.armExpire, H.armFixed = false, nil, nil, 0, nil
    H.incoming, H.incomingExpire = nil, 0
    H.inRace, H.started, H.finishedLocal, H.raceId, H.finish = false, false, false, nil, nil
end

-- Nearest OTHER player who is driving, within inviteRadius. Returns serverId, name.
local function nearestDriver()
    local me = PlayerPedId()
    local myPos = GetEntityCoords(me)
    local radius = CFG().inviteRadius or 60.0
    local bestId, bestName, bestDist = nil, nil, radius + 1.0
    for _, pl in ipairs(GetActivePlayers()) do
        local ped = GetPlayerPed(pl)
        if ped ~= me and DoesEntityExist(ped) and IsPedInAnyVehicle(ped, false) then
            local veh = GetVehiclePedIsIn(ped, false)
            -- Only challenge a DRIVER (seat -1), not a passenger.
            if veh ~= 0 and GetPedInVehicleSeat(veh, -1) == ped then
                local d = #(myPos - GetEntityCoords(ped))
                if d <= radius and d < bestDist then
                    bestDist = d
                    bestId = GetPlayerServerId(pl)
                    bestName = GetPlayerName(pl)
                end
            end
        end
    end
    return bestId, bestName
end

-- Snap a world point to the nearest DRIVABLE ROAD node. Returns x,y,z (road's real
-- elevation, from the vehicle-node graph — no ground-probe guessing that lands
-- underground) + how far the snap moved. nil if no road node exists nearby.
-- nodeType 1 = roads incl. minor; we skip node 0 (off-road/dirt junk sometimes).
local function snapToRoad(x, y, z, maxSnap)
    maxSnap = maxSnap or 120.0
    -- GetClosestVehicleNodeWithHeading gives the on-graph road position + true Z.
    local ok, node = GetClosestVehicleNodeWithHeading(x, y, z, 1, 3.0, 0)
    if not ok or not node then
        -- retry unbiased (some map areas need node type flags relaxed)
        ok, node = GetClosestVehicleNode(x, y, z, 1, 3.0, 0)
    end
    if not ok or not node then return nil end
    local d = #(vector3(x, y, z) - vector3(node.x, node.y, node.z))
    if d > maxSnap then return nil end
    return node.x, node.y, node.z, d
end

-- Nearest of the fixed finish lines to a coord, if within fixedLineMaxDist.
-- Z is road-snapped so a stale hand-entered elevation can't put it underground.
local function nearestFixedLine(pos)
    local lines = CFG().fixedFinishLines or {}
    local maxD = CFG().fixedLineMaxDist or 1500.0
    local best, bestD = nil, maxD + 1.0
    for _, l in ipairs(lines) do
        local d = #(pos - vector3(l[1], l[2], l[3]))
        if d < bestD then
            bestD = d
            best = { x = l[1], y = l[2], z = l[3], r = l[4] or CFG().finishRadius or 18.0 }
        end
    end
    if best and bestD <= maxD then
        local rx, ry, rz = snapToRoad(best.x, best.y, best.z, 40.0)
        if rz then best.x, best.y, best.z = rx, ry, rz end  -- keep on road, real Z
        return best, bestD
    end
    return nil
end

-- A dynamic finish ~dashAheadDist ahead of the host's heading, SNAPPED TO A ROAD.
-- We project ahead, then find the nearest road node; if the projection landed off
-- the network (aimed at a house/hill/water), we walk the target back toward the
-- host in steps until a road node is found, so the finish is ALWAYS on tarmac.
local function dashAheadFinish(veh)
    local dist = CFG().dashAheadDist or 800.0
    local origin = GetEntityCoords(veh)
    for _, frac in ipairs({ 1.0, 0.8, 0.6, 0.45, 0.3 }) do
        local ahead = GetOffsetFromEntityInWorldCoords(veh, 0.0, dist * frac, 0.0)
        local rx, ry, rz, moved = snapToRoad(ahead.x, ahead.y, ahead.z, 150.0)
        -- Accept the snap if it's a real road node a sensible distance ahead of the
        -- host (avoid snapping back onto the host's own start spot).
        if rz and #(vector3(rx, ry, rz) - origin) > 60.0 then
            return { x = rx, y = ry, z = rz, r = CFG().finishRadius or 18.0 }
        end
    end
    -- Last resort: nearest fixed line (already road-snapped), else a ground-probed
    -- point ahead (best effort) so a challenge can still proceed.
    local fl = nearestFixedLine(origin)
    if fl then return fl end
    local ahead = GetOffsetFromEntityInWorldCoords(veh, 0.0, dist * 0.5, 0.0)
    local okG, gz = GetGroundZFor_3dCoord(ahead.x, ahead.y, ahead.z + 50.0, false)
    return { x = ahead.x, y = ahead.y, z = okG and gz or ahead.z, r = CFG().finishRadius or 18.0 }
end

-- ── Arm a challenge (after the double horn) ──────────────────────────────────
-- Finds the nearest driver, works out the finish options, and opens the host's
-- finish-pick window ([1] dash ahead / [2] nearest fixed line).
local function armChallenge()
    if not CFG().enabled then return end
    local veh = playerVeh()
    if not veh then RaceUtil.notify(L('h2h_need_vehicle'), 'error'); return end
    if isBusy() then RaceUtil.notify(L('h2h_busy'), 'error'); return end

    local now = GetGameTimer()
    local cd = CFG().hostCooldownMs or 20000
    if now - H.lastArmAt < cd then
        RaceUtil.notify(L('h2h_cooldown', math.ceil((cd - (now - H.lastArmAt)) / 1000)), 'error')
        return
    end

    local tId, tName = nearestDriver()
    if not tId then RaceUtil.notify(L('h2h_no_target'), 'error'); return end

    H.armed = true
    H.armTarget = tId
    H.armTargetName = tName or ('Player ' .. tId)
    H.armExpire = now + (CFG().finishPickMs or 8000)
    H.armFixed = nearestFixedLine(GetEntityCoords(veh))

    local dashM = math.floor(CFG().dashAheadDist or 800.0)
    if H.armFixed then
        local fd = math.floor(#(GetEntityCoords(veh) - vector3(H.armFixed.x, H.armFixed.y, H.armFixed.z)))
        RaceUtil.notify(L('h2h_pick_finish', H.armTargetName, dashM, fd .. 'm'), 'inform')
    else
        RaceUtil.notify(L('h2h_pick_finish_nofl', H.armTargetName, dashM), 'inform')
    end
end

-- Host confirms a finish choice ('dash' or 'fixed') → send the invite to server.
local function pickFinish(kind)
    if not H.armed then return end
    local veh = playerVeh()
    if not veh then H.armed = false; return end
    local finish
    if kind == 'fixed' and H.armFixed then
        finish = H.armFixed
    else
        finish = dashAheadFinish(veh)
    end
    H.armed = false
    H.lastArmAt = GetGameTimer()
    TriggerServerEvent('hk-race:h2h:request', H.armTarget, finish, H.stake)
    RaceUtil.notify(L('h2h_sent', H.armTargetName or '?'), 'inform')
end

-- Horn double-tap detector. IsHornActive is true while the horn sounds; we count
-- rising edges (press) and fire on the second within hornDoubleTapMs.
CreateThread(function()
    local hornWasOn = false
    local firstTapAt = 0
    while true do
        local sleep = 250
        if h2hActive() and not isBusy() then
            local veh = playerVeh()
            if veh then
                sleep = 0
                local on = IsHornActive(veh)
                if on and not hornWasOn then
                    -- rising edge = a tap
                    local now = GetGameTimer()
                    if firstTapAt > 0 and (now - firstTapAt) <= (CFG().hornDoubleTapMs or 1500) then
                        firstTapAt = 0
                        armChallenge()
                    else
                        firstTapAt = now
                    end
                end
                hornWasOn = on
                -- expire a stale first tap
                if firstTapAt > 0 and (GetGameTimer() - firstTapAt) > (CFG().hornDoubleTapMs or 1500) then
                    firstTapAt = 0
                end
            else
                hornWasOn = false
                firstTapAt = 0
            end
        end
        Wait(sleep)
    end
end)

-- Input thread: host's finish-pick keys while armed, and target's accept/decline
-- keys while an invite is incoming. Both windows are short-lived.
CreateThread(function()
    while true do
        local sleep = 500
        local now = GetGameTimer()

        -- Host: picking a finish. Suppress the picker keys' default actions
        -- (weapon-slot select) for the frame so tapping 1/2 doesn't swap weapons.
        if H.armed then
            sleep = 0
            local kA = CFG().keyFinishA or 157
            local kB = CFG().keyFinishB or 158
            DisableControlAction(0, kA, true)
            if H.armFixed then DisableControlAction(0, kB, true) end
            if now >= H.armExpire then
                H.armed = false
                RaceUtil.notify(L('h2h_pick_timeout'), 'inform')
            else
                if IsDisabledControlJustPressed(0, kA) then
                    pickFinish('dash')
                elseif H.armFixed and IsDisabledControlJustPressed(0, kB) then
                    pickFinish('fixed')
                end
            end
        end

        -- Target: responding to an invite. Suppress the accept/decline keys'
        -- default actions (team chat / push-to-talk) during the prompt.
        if H.incoming then
            sleep = 0
            local kY = CFG().keyAccept or 246
            local kN = CFG().keyDecline or 249
            DisableControlAction(0, kY, true)
            DisableControlAction(0, kN, true)
            if now >= H.incomingExpire then
                H.incoming = nil
                RaceUtil.notify(L('h2h_expired'), 'inform')
                TriggerServerEvent('hk-race:h2h:respond', false)
            else
                if IsDisabledControlJustPressed(0, kY) then
                    H.incoming = nil
                    TriggerServerEvent('hk-race:h2h:respond', true)
                elseif IsDisabledControlJustPressed(0, kN) then
                    H.incoming = nil
                    RaceUtil.notify(L('h2h_you_declined'), 'inform')
                    TriggerServerEvent('hk-race:h2h:respond', false)
                end
            end
        end

        Wait(sleep)
    end
end)

-- Clamp/normalise a requested stake against the wager config. Returns amount ≥ 0.
local function normaliseStake(raw)
    local w = CFG() and CFG().wager
    if not (w and w.enabled) then return 0 end
    local amt = math.floor(tonumber(raw or '') or -1)
    if amt < 0 then return nil end
    if amt > (w.max or 1000000) then amt = w.max or 1000000 end
    return amt
end

-- ── /h2hbet <amount> : set the stake for your next challenge ─────────────────
RegisterCommand(CFG() and CFG().wager and CFG().wager.command or 'h2hbet', function(_, args)
    local amt = normaliseStake(args[1])
    if amt == nil then RaceUtil.notify(L('h2h_bet_bad'), 'error'); return end
    H.stake = amt
    if amt == 0 then
        RaceUtil.notify(L('h2h_bet_off'), 'inform')
    else
        RaceUtil.notify(L('h2h_bet_set', formatStake(amt)), 'success')
    end
end, false)

-- ── NUI wiring for the racemenu top-bar H2H control ──────────────────────────
-- Toggle Head-2-Head on/off (persisted). Returns the new state to the NUI.
RegisterNUICallback('h2h:setEnabled', function(data, cb)
    setH2hOn(data and data.on and true or false)
    cb({ ok = true, on = h2hOn })
end)

-- Set the cash bet amount from the top-bar input (cash only for v1).
RegisterNUICallback('h2h:setBet', function(data, cb)
    local amt = normaliseStake(data and data.amount)
    if amt == nil then cb({ ok = false, error = 'bad_amount', stake = H.stake or 0 }); return end
    H.stake = amt
    cb({ ok = true, stake = H.stake })
end)

-- The picker asks for current H2H state when it opens.
RegisterNUICallback('h2h:getState', function(_, cb)
    cb({ on = h2hOn, stake = H.stake or 0,
         globalEnabled = (CFG() and CFG().enabled) and true or false,
         maxBet = (CFG() and CFG().wager and CFG().wager.max) or 1000000 })
end)

-- ── Server → target: an incoming challenge ───────────────────────────────────
RegisterNetEvent('hk-race:h2h:invite', function(data)
    -- data = { host, hostName, stake }
    if isBusy() then
        -- Can't take it — auto-decline so the host isn't left hanging.
        TriggerServerEvent('hk-race:h2h:respond', false)
        return
    end
    H.incoming = data
    H.incomingExpire = GetGameTimer() + (CFG().inviteExpiryMs or 12000)
    if (data.stake or 0) > 0 then
        RaceUtil.notify(L('h2h_incoming', data.hostName or '?', formatStake(data.stake)), 'warning')
    else
        RaceUtil.notify(L('h2h_incoming_free', data.hostName or '?'), 'warning')
    end
end)

-- Host: target declined / invite failed.
RegisterNetEvent('hk-race:h2h:declined', function(name)
    RaceUtil.notify(L('h2h_declined', name or '?'), 'inform')
end)

-- Host: you can't cover your own stake.
RegisterNetEvent('hk-race:h2h:badstake', function(amountStr)
    RaceUtil.notify(L('h2h_cant_afford_host', amountStr or '?'), 'error')
end)

-- Both: stakes escrowed, race is on.
RegisterNetEvent('hk-race:h2h:staked', function(amountStr)
    RaceUtil.notify(L('h2h_staked', amountStr or '?'), 'success')
end)

-- ── Server: race begins (both racers get this) ───────────────────────────────
RegisterNetEvent('hk-race:h2h:begin', function(data)
    -- data = { raceId, finish = {x,y,z,r}, stake, countdown }
    resetH2H()
    H.inRace = true
    H.raceId = data.raceId
    H.finish = data.finish

    -- Finish blip + route so both racers can see where to go.
    H.finishBlip = AddBlipForCoord(H.finish.x, H.finish.y, H.finish.z)
    SetBlipSprite(H.finishBlip, 38)          -- checkered flag
    SetBlipColour(H.finishBlip, 2)           -- green
    SetBlipRoute(H.finishBlip, true)
    SetBlipRouteColour(H.finishBlip, 2)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName('Head-to-Head Finish')
    EndTextCommandSetBlipName(H.finishBlip)

    -- Countdown, then GO.
    CreateThread(function()
        local n = data.countdown or CFG().startCountdown or 5
        while n > 0 do
            RaceUtil.notify(L('h2h_countdown', n), 'warning')
            PlaySoundFrontend(-1, 'MP_5_SECOND_TIMER', 'HUD_MINI_GAME_SOUNDSET', true)
            Wait(1000)
            n = n - 1
        end
        H.started = true
        RaceUtil.notify(L('h2h_go'), 'success')
        PlaySoundFrontend(-1, 'GO', 'HUD_MINI_GAME_SOUNDSET', true)
    end)
end)

-- Finish marker render (green ring + floating flag), only while racing.
CreateThread(function()
    while true do
        local sleep = 500
        if H.inRace and H.started and H.finish and not H.finishedLocal then
            sleep = 0
            local f = H.finish
            local col = CFG().finishRingColor or { r = 40, g = 220, b = 90, a = 90 }
            local dia = (f.r or 18.0) * 2.0
            local h = CFG().finishRingHeight or 3.0
            DrawMarker(1, f.x, f.y, f.z - 1.0, 0,0,0, 0,0,0, dia, dia, h,
                col.r, col.g, col.b, col.a, false, false, 2, false, nil, nil, false)
            local floatH = CFG().finishArrowHeight or 34.0
            local sz = CFG().finishArrowSize or 4.0
            DrawMarker(CFG().finishArrowType or 4, f.x, f.y, f.z + floatH, 0,0,0, 0,0,0, sz, sz, sz,
                col.r, col.g, col.b, 90, true, false, 2, false, nil, nil, false)
        end
        Wait(sleep)
    end
end)

-- Arrival detection: first to the finish radius reports it; server decides the winner.
CreateThread(function()
    while true do
        local sleep = 300
        if H.inRace and H.started and H.finish and not H.finishedLocal then
            sleep = 0
            local pos = GetEntityCoords(PlayerPedId())
            local f = H.finish
            local dx, dy = pos.x - f.x, pos.y - f.y
            local d = math.sqrt(dx * dx + dy * dy)
            local dz = math.abs(pos.z - f.z)
            if d <= (f.r or 18.0) and dz <= (CFG().finishVertTol or 60.0) then
                H.finishedLocal = true
                PlaySoundFrontend(-1, 'CHECKPOINT_PERFECT', 'HUD_MINI_GAME_SOUNDSET', true)
                TriggerServerEvent('hk-race:h2h:finish', H.raceId)
            end
        end
        Wait(sleep)
    end
end)

-- Server: the race resolved (win / lose / void). data = { result, reward, refund }
RegisterNetEvent('hk-race:h2h:result', function(data)
    clearFinishVisual()
    if data.result == 'win' then
        if data.reward then RaceUtil.notify(L('h2h_win', data.reward), 'success')
        else RaceUtil.notify(L('h2h_win_free'), 'success') end
    elseif data.result == 'lose' then
        if data.reward then RaceUtil.notify(L('h2h_lose', data.reward), 'error')
        else RaceUtil.notify(L('h2h_lose_free'), 'error') end
    elseif data.result == 'void' then
        if data.refund then RaceUtil.notify(L('h2h_refund', data.refund), 'inform')
        else RaceUtil.notify(L('h2h_opp_left'), 'inform') end
    end
    SetTimeout(4000, resetH2H)
end)

-- Server force-cancel (e.g. opponent dropped before GO).
RegisterNetEvent('hk-race:h2h:cancel', function()
    if H.inRace then RaceUtil.notify(L('h2h_opp_left'), 'inform') end
    resetH2H()
end)

-- Cleanup if the player fully leaves.
AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() then clearFinishVisual() end
end)
