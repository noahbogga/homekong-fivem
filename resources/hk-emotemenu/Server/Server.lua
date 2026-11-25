local QBCore = exports['qb-core']:GetCoreObject()
-----------------------------------------------------------------------------------------------------
-- Shared Emotes Syncing  ---------------------------------------------------------------------------
-----------------------------------------------------------------------------------------------------

RegisterServerEvent("ServerEmoteRequest")
AddEventHandler("ServerEmoteRequest", function(target, emotename, etype)
	TriggerClientEvent("ClientEmoteRequestReceive", target, emotename, etype)
end)

RegisterServerEvent("ServerValidEmote")
AddEventHandler("ServerValidEmote", function(target, requestedemote, otheremote)
	TriggerClientEvent("SyncPlayEmote", source, otheremote, source)
	TriggerClientEvent("SyncPlayEmoteSource", target, requestedemote)
end)

-----------------------------------------------------------------------------------------------------
-- Group Emotes (authoritative) ---------------------------------------------------------------------
-- The server owns group membership. The leader drives playback; every member
-- plays the SAME emote in place (no teleport-pairing). All exit paths — leave,
-- disband, leader/member disconnect — clean up so players fall back to solo.
-----------------------------------------------------------------------------------------------------
local Groups   = {}   -- [leaderSrc] = { leader = src, members = { [src] = true } }  (members includes the leader)
local MemberOf = {}   -- [src] = leaderSrc                         (which group a player is in)
local Pending  = {}   -- [inviteeSrc] = { leader = src, token = n } (outstanding invite)
local InviteSeq = 0   -- monotonic token so a stale expire-timer can't nuke a re-issued invite

local function rosterOf(group)
	local out = {}
	for src in pairs(group.members) do
		out[#out + 1] = { src = src, name = GetPlayerName(src) or ('Player ' .. src), leader = (src == group.leader) }
	end
	return out
end

local function broadcastUpdate(group)
	local roster = rosterOf(group)
	for src in pairs(group.members) do
		TriggerClientEvent('hk-emote:group:update', src, { leader = group.leader, members = roster })
	end
end

-- Remove one player from whatever group they're in. If they're the leader, the
-- whole group disbands. Returns nothing; notifies everyone affected.
local function removePlayer(src, reason)
	local leaderSrc = MemberOf[src]
	if not leaderSrc then return end
	local group = Groups[leaderSrc]
	MemberOf[src] = nil
	if not group then return end

	if src == group.leader then
		-- leader leaving disbands the group for everyone
		for m in pairs(group.members) do
			if m ~= src then MemberOf[m] = nil end
			TriggerClientEvent('hk-emote:group:ended', m, reason or 'leader_left')
		end
		Groups[leaderSrc] = nil
		-- Clear any invites this leader still had outstanding, so those targets
		-- aren't stuck un-invitable (target_pending) until their timer expires.
		for invitee, p in pairs(Pending) do
			if p.leader == src then Pending[invitee] = nil end
		end
	else
		group.members[src] = nil
		TriggerClientEvent('hk-emote:group:ended', src, reason or 'left')   -- reset the one who left
		broadcastUpdate(group)                                             -- refresh the rest
	end
end

-- Leader invites a nearby player (client already checked the 12m radius).
RegisterServerEvent('hk-emote:group:invite')
AddEventHandler('hk-emote:group:invite', function(targetSrc)
	local src = source
	targetSrc = tonumber(targetSrc)
	if not targetSrc or targetSrc == src then return end
	if not GetPlayerName(targetSrc) then return end                       -- target offline

	-- Only a group leader (or someone not yet in a group) may invite.
	local myLeader = MemberOf[src]
	if myLeader and myLeader ~= src then
		TriggerClientEvent('hk-emote:group:notify', src, 'not_leader')
		return
	end

	-- Target must be free and not already invited.
	if MemberOf[targetSrc] then
		TriggerClientEvent('hk-emote:group:notify', src, 'target_busy')
		return
	end
	if Pending[targetSrc] then
		TriggerClientEvent('hk-emote:group:notify', src, 'target_pending')
		return
	end

	-- NOTE: the group is NOT created here. Creating it on invite left a phantom
	-- 1-person group behind whenever the invite was declined/expired (the common
	-- case), stranding the inviter as target_busy forever. Instead the group is
	-- created lazily on the first accept (see :accept). So a dangling invite
	-- leaks nothing but a Pending entry, which the token-timer always clears.
	InviteSeq = InviteSeq + 1
	local token = InviteSeq
	Pending[targetSrc] = { leader = src, token = token }
	TriggerClientEvent('hk-emote:group:invited', targetSrc, { leader = src, leaderName = GetPlayerName(src) })
	TriggerClientEvent('hk-emote:group:notify', src, 'invite_sent')

	-- Auto-expire after 20s. Match on TOKEN, not value, so this timer only
	-- clears the exact invite it was scheduled for — a re-issued invite to the
	-- same target has a new token and survives this timer.
	SetTimeout(20000, function()
		local p = Pending[targetSrc]
		if p and p.token == token then
			Pending[targetSrc] = nil
			if GetPlayerName(src) then
				TriggerClientEvent('hk-emote:group:notify', src, 'invite_expired')
			end
		end
	end)
end)

RegisterServerEvent('hk-emote:group:accept')
AddEventHandler('hk-emote:group:accept', function()
	local src = source
	local p = Pending[src]
	Pending[src] = nil
	-- Always answer the client so it never sits on an optimistic "joined": on any
	-- rejection we send a notify (the client shows it and stays solo).
	if not p then
		TriggerClientEvent('hk-emote:group:notify', src, 'invite_gone')
		return
	end
	local leaderSrc = p.leader
	if MemberOf[src] then                                                 -- already grouped elsewhere
		TriggerClientEvent('hk-emote:group:notify', src, 'already_grouped')
		return
	end
	-- Leader must still be around and not have joined someone else's group.
	if not GetPlayerName(leaderSrc) or (MemberOf[leaderSrc] and MemberOf[leaderSrc] ~= leaderSrc) then
		TriggerClientEvent('hk-emote:group:notify', src, 'group_gone')
		return
	end

	-- Lazy-create the group on the first accept.
	local group = Groups[leaderSrc]
	if not group then
		group = { leader = leaderSrc, members = { [leaderSrc] = true } }
		Groups[leaderSrc] = group
		MemberOf[leaderSrc] = leaderSrc
	end

	group.members[src] = true
	MemberOf[src] = leaderSrc
	broadcastUpdate(group)   -- sends group:update to all members incl. the leader
end)

RegisterServerEvent('hk-emote:group:decline')
AddEventHandler('hk-emote:group:decline', function()
	local src = source
	local p = Pending[src]
	Pending[src] = nil
	if p and GetPlayerName(p.leader) then
		TriggerClientEvent('hk-emote:group:notify', p.leader, 'declined', GetPlayerName(src))
	end
end)

-- Member leaves, or leader disbands (both routed here).
RegisterServerEvent('hk-emote:group:leave')
AddEventHandler('hk-emote:group:leave', function()
	removePlayer(source, 'left')
end)

-- Leader auto-removes a member who wandered past GroupMaxDistance (leader-side
-- distance check). Validated here so only the real leader can kick.
RegisterServerEvent('hk-emote:group:kick')
AddEventHandler('hk-emote:group:kick', function(targetSrc)
	local src = source
	targetSrc = tonumber(targetSrc)
	local group = Groups[src]
	if not group or group.leader ~= src then return end                   -- only leader kicks
	if targetSrc and group.members[targetSrc] and targetSrc ~= src then
		removePlayer(targetSrc, 'too_far')
	end
end)

-- Leader picks an emote -> broadcast to every member (including the leader so
-- the roster/play is consistent). Members playing is a no-op server-side.
RegisterServerEvent('hk-emote:group:play')
AddEventHandler('hk-emote:group:play', function(kind, id)
	local src = source
	local group = Groups[src]
	if not group or group.leader ~= src then return end                   -- only leader drives
	if type(kind) ~= 'string' or type(id) ~= 'string' then return end
	for m in pairs(group.members) do
		TriggerClientEvent('hk-emote:group:play', m, kind, id)
	end
end)

-- Clean up on disconnect: member drops -> leave; leader drops -> disband.
AddEventHandler('playerDropped', function()
	if MemberOf[source] then removePlayer(source, 'disconnect') end
	Pending[source] = nil
	-- also clear any invites this player had sent out
	for invitee, p in pairs(Pending) do
		if p.leader == source then Pending[invitee] = nil end
	end
end)

-----------------------------------------------------------------------------------------------------
-- Keybinding  --------------------------------------------------------------------------------------
-----------------------------------------------------------------------------------------------------

if Config.SqlKeybinding then
	RegisterServerEvent("dp:ServerKeybindExist")
	AddEventHandler('dp:ServerKeybindExist', function()
		local src = source local srcid = GetPlayerIdentifier(source)
		MySQL.Sync.fetchAll("SELECT * FROM dpkeybinds WHERE `id`=@id;", { ['@id'] = srcid }, function(dpkeybinds)
			if dpkeybinds[1] then
				TriggerClientEvent("dp:ClientKeybindExist", src, true)
			else
				TriggerClientEvent("dp:ClientKeybindExist", src, false)
			end
		end)
	end)

	--  This is my first time doing SQL stuff, and after i finished everything i realized i didnt have to store the keybinds in the database at all.
	--  But remaking it now is a little pointless since it does it job just fine!

	RegisterServerEvent("dp:ServerKeybindCreate")
	AddEventHandler("dp:ServerKeybindCreate", function()
		local src = source local srcid = GetPlayerIdentifier(source)
		MySQL.Async.insert("INSERT INTO dpkeybinds (`id`, `keybind1`, `emote1`, `keybind2`, `emote2`, `keybind3`, `emote3`, `keybind4`, `emote4`, `keybind5`, `emote5`, `keybind6`, `emote6`) VALUES (@id, @keybind1, @emote1, @keybind2, @emote2, @keybind3, @emote3, @keybind4, @emote4, @keybind5, @emote5, @keybind6, @emote6);", { id = srcid, keybind1 = "num4", emote1 = "", keybind2 = "num5", emote2 = "", keybind3 = "num6", emote3 = "", keybind4 = "num7", emote4 = "", keybind5 = "num8", emote5 = "", keybind6 = "num9", emote6 = ""}, function(created)
			print("[dp] ^2"..GetPlayerName(src).."^7 got created!")
			TriggerClientEvent("dp:ClientKeybindGet", src, "num4", "", "num5", "", "num6", "", "num7", "", "num8", "", "num8", "")
		end)
	end)

	RegisterServerEvent("dp:ServerKeybindGrab")
	AddEventHandler("dp:ServerKeybindGrab", function()
		local src = source local srcid = GetPlayerIdentifier(source)

		MySQL.Sync.fetchAll("SELECT keybind1, emote1, keybind2, emote2, keybind3, emote3, keybind4, emote4, keybind5, emote5, keybind6, emote6 FROM `dpkeybinds` WHERE `id` = @id", { ['@id'] = srcid }, function(kb)
			if kb[1].keybind1 ~= nil then
				TriggerClientEvent("dp:ClientKeybindGet", src, kb[1].keybind1, kb[1].emote1, kb[1].keybind2, kb[1].emote2, kb[1].keybind3, kb[1].emote3, kb[1].keybind4, kb[1].emote4, kb[1].keybind5, kb[1].emote5, kb[1].keybind6, kb[1].emote6)
			else
				TriggerClientEvent("dp:ClientKeybindGet", src, "num4", "", "num5", "", "num6", "", "num7", "", "num8", "", "num8", "")
			end
		end)
	end)

	RegisterServerEvent("dp:ServerKeybindUpdate")
	AddEventHandler("dp:ServerKeybindUpdate", function(key, emote)
		local src = source local myid = GetPlayerIdentifier(source)
		if key == "num4" then chosenk = "keybind1" elseif key == "num5" then chosenk = "keybind2" elseif key == "num6" then chosenk = "keybind3" elseif key == "num7" then chosenk = "keybind4" elseif key == "num8" then chosenk = "keybind5" elseif key == "num9" then chosenk = "keybind6" end
		if chosenk == "keybind1" then
			MySQL.Async.execute("UPDATE dpkeybinds SET emote1=@emote WHERE id=@id", { id = myid, emote = emote }, function()
				TriggerClientEvent("dp:ClientKeybindGetOne", src, key, emote)
			end)
		elseif chosenk == "keybind2" then
			MySQL.Async.execute("UPDATE dpkeybinds SET emote2=@emote WHERE id=@id", { id = myid, emote = emote }, function()
				TriggerClientEvent("dp:ClientKeybindGetOne", src, key, emote)
			end)
		elseif chosenk == "keybind3" then
			MySQL.Async.execute("UPDATE dpkeybinds SET emote3=@emote WHERE id=@id", { id = myid, emote = emote }, function()
				TriggerClientEvent("dp:ClientKeybindGetOne", src, key, emote)
			end)
		elseif chosenk == "keybind4" then
			MySQL.Async.execute("UPDATE dpkeybinds SET emote4=@emote WHERE id=@id", { id = myid, emote = emote }, function()
				TriggerClientEvent("dp:ClientKeybindGetOne", src, key, emote)
			end)
		elseif chosenk == "keybind5" then
			MySQL.Async.execute("UPDATE dpkeybinds SET emote5=@emote WHERE id=@id", { id = myid, emote = emote }, function()
				TriggerClientEvent("dp:ClientKeybindGetOne", src, key, emote)
			end)
		elseif chosenk == "keybind6" then
			MySQL.Async.execute("UPDATE dpkeybinds SET emote6=@emote WHERE id=@id", { id = myid, emote = emote }, function()
				TriggerClientEvent("dp:ClientKeybindGetOne", src, key, emote)
			end)
		end
	end)
else
	print("[dp] ^3Sql Keybinding^7 is turned ^1off^7, if you want to enable /emotebind, import dpkeybinding.sql and set ^3SqlKeybinding = ^2true^7 in config.lua.")
end

QBCore.Functions.CreateUseableItem("walkstick", function(source, item)
    TriggerClientEvent("dp:Client:UseWalkingStick", source)
end)

-----------------------------------------------------------------------------------------------------
-- Commands -------- --------------------------------------------------------------------------------
-----------------------------------------------------------------------------------------------------

QBCore.Commands.Add('e', '做出表情', {{ name="emotename", help="dance, camera, sit 或任可有效表情"}}, true, function(source, args)
    TriggerClientEvent('animations:client:PlayEmote', source, args)
end)

QBCore.Commands.Add('emote', '做出表情', {{ name="emotename", help="dance, camera, sit 或任可有效表情"}}, true, function(source, args)
    TriggerClientEvent('animations:client:PlayEmote', source, args)
end)

if Config.SqlKeybinding then
    QBCore.Commands.Add('emotebind', 'Bind an emote', {{ name="key", help="num4, num5, num6, num7. num8, num9. Numpad 4-9!"}, { name="emotename", help="dance, camera, sit or any valid emote."}}, true, function(source, args)
		TriggerClientEvent('animations:client:BindEmote', source, args)
    end)

    QBCore.Commands.Add('emotebinds', 'Check your currently bound emotes.', {}, false, function(source)
        TriggerClientEvent('animations:client:EmoteBinds', source)
    end)
end

QBCore.Commands.Add('emotemenu', '打開表情選單 (亦可從F1開啟)', {}, false, function(source)
	TriggerClientEvent('animations:client:EmoteMenu', source)
end)

QBCore.Commands.Add('em', '打開表情選單 (亦可從F1開啟)', {}, false, function(source)
    TriggerClientEvent('animations:client:EmoteMenu', source)
end)

QBCore.Commands.Add('emotes', '可用表情列表', {}, false, function(source)
	TriggerClientEvent('animations:client:ListEmotes', source)
end)

QBCore.Commands.Add('walk', '設置你的行路 Style', {{ name="style", help="/walks 可以有可用列表, /emotemenu 中可選"}}, true, function(source, args)
	TriggerClientEvent('animations:client:Walk', source, args)
end)

QBCore.Commands.Add('walks', '可用的行路 Style 列表', {}, false, function(source)
    TriggerClientEvent('animations:client:ListWalks', source)
end)

QBCore.Commands.Add('nearby', '與附近既人分享一個表情.', {{ name="emotename", help="hug, handshake, bro 或任可有效分享表情"}}, true, function(source, args)
	TriggerClientEvent('animations:client:Nearby', source, args)
end)