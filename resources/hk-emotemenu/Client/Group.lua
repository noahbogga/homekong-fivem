-- hk-emotemenu — Group Emotes (client)
-- The leader drives playback; every member plays the SAME emote/dance/prop/
-- walk/mood IN PLACE. No teleport-pairing (that's the dual/Shared system, which
-- is hidden while grouped). All exit paths restore the player's own walk & mood.

HKGroup = {}

local group = { active = false, leader = nil, isLeader = false, members = {} }

-- The player's own walk & mood, so we can restore them when leaving a group.
-- '__reset__' means "back to default". Updated whenever the player personally
-- sets a walk/mood (see HKGroup.RememberPersonal, called from the play path).
local personalWalk = '__reset__'
local personalMood = '__reset__'

local pendingInvite = nil   -- { leader = src, leaderName = name } while an invite is open

-- ---- small helpers ---------------------------------------------------------
local function notify(msg) if SimpleNotify then SimpleNotify(msg) else print(msg) end end

local function pushState(nearby)
    SendNUIMessage({
        action = 'group',
        state  = {
            active   = group.active,
            isLeader = group.isLeader,
            leader   = group.leader,
            members  = group.members,   -- [{ src, name, leader }]
            nearby   = nearby or nil,   -- [{ src, name, dist }] (leader-relevant)
        },
    })
end

-- ---- public queries used by the play path ---------------------------------
function HKGroup.IsActive()  return group.active end
function HKGroup.IsLeader()  return group.isLeader end
-- True while an invite prompt is on screen (used so the menu's Backspace-close
-- yields to Backspace-decline instead of both firing on the same press).
function HKGroup.HasPendingInvite() return pendingInvite ~= nil end

-- Remember the player's personal walk/mood so group exit can restore it.
function HKGroup.RememberPersonal(kind, id)
    if kind == 'walk' then personalWalk = id
    elseif kind == 'mood' then personalMood = id end
end

-- Restore the player's own walk + mood (used on any group-exit path).
local function restorePersonal()
    local ped = PlayerPedId()
    if personalWalk == '__reset__' then ResetPedMovementClipset(ped)
    else WalkMenuStart(personalWalk) end
    if personalMood == '__reset__' then ClearFacialIdleAnimOverride(ped)
    else EmoteMenuStart(personalMood, 'expression') end
end

-- ===========================================================================
-- Leader-driven playback: apply the SAME item locally, in place.
-- ===========================================================================
RegisterNetEvent('hk-emote:group:play', function(kind, id)
    if kind == 'emote' then      EmoteMenuStart(id, 'emotes')
    elseif kind == 'dance' then  EmoteMenuStart(id, 'dances')
    elseif kind == 'prop' then   EmoteMenuStart(id, 'props')
    elseif kind == 'walk' then
        if id == '__reset__' then ResetPedMovementClipset(PlayerPedId()) else WalkMenuStart(id) end
    elseif kind == 'mood' then
        if id == '__reset__' then ClearFacialIdleAnimOverride(PlayerPedId()) else EmoteMenuStart(id, 'expression') end
    elseif kind == 'cancel' then
        EmoteCancel(); DestroyAllProps()
    end
end)

-- ===========================================================================
-- Membership updates from the server.
-- ===========================================================================
RegisterNetEvent('hk-emote:group:update', function(data)
    group.active   = true
    group.leader   = data.leader
    group.members  = data.members or {}
    group.isLeader = (data.leader == GetPlayerServerId(PlayerId()))
    pushState()
end)

-- Group ended for this player (they left, were kicked, or leader/group gone).
RegisterNetEvent('hk-emote:group:ended', function(reason)
    group.active = false; group.leader = nil; group.isLeader = false; group.members = {}
    pendingInvite = nil
    -- Stop whatever group emote was playing (dances loop, props stay attached),
    -- THEN restore the player's own walk/mood. Without the cancel, members keep
    -- looping the leader's last emote forever after disband/kick/disconnect.
    EmoteCancel()
    DestroyAllProps()
    restorePersonal()
    local msgs = {
        left        = '你已離開表情群組 · Left the emote group',
        too_far     = '距離太遠，已離開群組 · Too far — removed from group',
        leader_left = '隊長已解散群組 · The leader disbanded the group',
        disconnect  = '群組已解散 · Group disbanded',
    }
    notify(msgs[reason] or msgs.left)
    pushState()
end)

-- Generic leader/inviter notifications.
RegisterNetEvent('hk-emote:group:notify', function(kind, extra)
    local msgs = {
        invite_sent     = '已發送邀請 · Invite sent',
        invite_expired  = '邀請已逾時 · Invite expired',
        declined        = (extra or 'Player') .. ' 拒絕咗邀請 · declined',
        not_leader      = '只有隊長先可以邀請 · Only the leader can invite',
        target_busy     = '對方已經喺其他群組 · Player already in a group',
        target_pending  = '對方已有待處理邀請 · Player already has a pending invite',
        group_gone      = '群組已唔存在 · That group no longer exists',
        invite_gone     = '邀請已失效 · Invite no longer valid',
        already_grouped = '你已經喺一個群組 · You are already in a group',
    }
    notify(msgs[kind] or kind)
end)

-- ===========================================================================
-- Incoming invite -> accept (Y) / decline (Backspace). Works with menu closed.
-- ===========================================================================
RegisterNetEvent('hk-emote:group:invited', function(data)
    pendingInvite = { leader = data.leader, leaderName = data.leaderName }
    PlaySound(-1, 'NAV', 'HUD_AMMO_SHOP_SOUNDSET', 0, 0, 1)
    notify(('%s 邀請你加入表情群組\n%s invites you to a group\n[Y] 接受 Accept   [Backspace] 拒絕 Decline')
        :format(data.leaderName or 'Someone', data.leaderName or 'Someone'))
end)

CreateThread(function()
    while true do
        Wait(0)
        if pendingInvite then
            -- Use the disabled-control check too: while the emote menu is open in
            -- keyboard mode it DISABLES the decline key (177) and remaps it to
            -- close, so a plain IsControlJustPressed would miss it. Reading both
            -- (pressed OR disabled-pressed) lets decline work with the menu open,
            -- and answering the invite here takes priority over the menu's own
            -- Backspace-to-close (this thread runs and clears pendingInvite; the
            -- menu loop only closes when no invite is pending — see EmoteMenu.lua).
            local accept  = IsControlJustPressed(0, Config.GroupAcceptControl)
                         or IsDisabledControlJustPressed(0, Config.GroupAcceptControl)
            local decline = IsControlJustPressed(0, Config.GroupDeclineControl)
                         or IsDisabledControlJustPressed(0, Config.GroupDeclineControl)
            if accept then
                TriggerServerEvent('hk-emote:group:accept')
                pendingInvite = nil
                -- No optimistic "joined" — the server confirms with group:update
                -- (success) or a notify (rejected), so we never falsely claim to
                -- have joined a group we didn't.
            elseif decline then
                TriggerServerEvent('hk-emote:group:decline')
                pendingInvite = nil
                notify('已拒絕邀請 · Invite declined')
            end
        else
            Wait(200)   -- idle when no invite pending
        end
    end
end)

-- ===========================================================================
-- Leader-side distance enforcement: kick members past GroupMaxDistance.
-- Only runs while we are the leader with >1 member.
-- ===========================================================================
CreateThread(function()
    while true do
        Wait(2000)
        if group.active and group.isLeader then
            local myPed = PlayerPedId()
            local myCoords = GetEntityCoords(myPed)
            local maxd = Config.GroupMaxDistance or 20.0
            for _, m in ipairs(group.members) do
                if not m.leader then
                    local plyIdx = GetPlayerFromServerId(m.src)
                    local far = true
                    if plyIdx ~= -1 then
                        local ped = GetPlayerPed(plyIdx)
                        if ped and ped ~= 0 then
                            local d = #(GetEntityCoords(ped) - myCoords)
                            if d <= maxd then far = false end
                        end
                    end
                    -- plyIdx == -1 (out of scope) counts as far -> kick.
                    if far then TriggerServerEvent('hk-emote:group:kick', m.src) end
                end
            end
        end
    end
end)

-- ===========================================================================
-- NUI callbacks — group panel actions.
-- ===========================================================================

-- Nearby invitable players within GroupInviteRadius (name + distance + serverId).
local function nearbyPlayers()
    local out = {}
    local myPed = PlayerPedId()
    local myCoords = GetEntityCoords(myPed)
    local radius = Config.GroupInviteRadius or 12.0
    local mySid = GetPlayerServerId(PlayerId())
    for _, ply in ipairs(GetActivePlayers()) do
        local ped = GetPlayerPed(ply)
        if ped and ped ~= myPed then
            local sid = GetPlayerServerId(ply)
            -- skip players already in this group
            local inGroup = false
            for _, m in ipairs(group.members) do if m.src == sid then inGroup = true break end end
            if sid ~= mySid and not inGroup then
                local d = #(GetEntityCoords(ped) - myCoords)
                if d <= radius then
                    out[#out + 1] = { src = sid, name = GetPlayerName(ply) or ('Player ' .. sid), dist = math.floor(d * 10) / 10 }
                end
            end
        end
    end
    table.sort(out, function(a, b) return a.dist < b.dist end)
    return out
end

RegisterNUICallback('groupNearby', function(_, cb)
    local canInvite = (not group.active) or group.isLeader
    pushState(canInvite and nearbyPlayers() or nil)
    cb('ok')
end)

RegisterNUICallback('groupInvite', function(data, cb)
    local sid = data and tonumber(data.src)
    if not sid then cb('bad') return end
    if not (Config.GroupEmotesEnabled) then cb('off') return end
    TriggerServerEvent('hk-emote:group:invite', sid)
    cb('ok')
end)

RegisterNUICallback('groupLeave', function(_, cb)
    -- Works for both "member leaves" and "leader disbands" — server routes it.
    if group.active then TriggerServerEvent('hk-emote:group:leave') end
    cb('ok')
end)

-- Called by the menu open path so the group tab reflects current state at once.
-- Only players who CAN invite (a leader, or someone not in a group) get the
-- nearby list; a plain member gets nil so the NUI shows no invite UI for them.
function HKGroup.SyncToNUI()
    local canInvite = (not group.active) or group.isLeader
    pushState(canInvite and nearbyPlayers() or nil)
end
