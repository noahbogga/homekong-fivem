-- hk-race :: server/h2h.lua
-- HEAD-TO-HEAD authority: invite validation, wager escrow, race resolution.
-- Native Lua reimplementation of the old (broken, DLL-based) ImpromptuRaces.
--
-- Money is authoritative here: on accept we REMOVE the stake from BOTH racers,
-- hold it as a pot, and pay the whole pot to the winner. Any void path refunds.

local QBCore = exports['qb-core']:GetCoreObject()
local CFG = function() return RaceConfig.H2H end

-- Pending invites keyed by TARGET src: { host, target, finish, stake, expireAt }.
local Invites = {}
-- Active H2H races keyed by id: { a, b, finish, stake, started, finished, aName, bName }.
local H2HRaces = {}
local nextId = 1
-- Per-host cooldown (server-side mirror of the client gate; authoritative).
local hostCooldown = {}

-- ── money helpers ────────────────────────────────────────────────────────────
local function getCash(src)
    local P = QBCore.Functions.GetPlayer(src)
    if not P then return 0 end
    return P.Functions.GetMoney('cash') or 0
end

local function removeCash(src, amount, reason)
    if amount <= 0 then return true end
    local P = QBCore.Functions.GetPlayer(src)
    if not P then return false end
    return P.Functions.RemoveMoney('cash', amount, reason or 'hk-race-h2h') and true or false
end

local function addCash(src, amount, reason)
    if amount <= 0 then return end
    local P = QBCore.Functions.GetPlayer(src)
    if not P then return end
    P.Functions.AddMoney('cash', amount, reason or 'hk-race-h2h')
end

local function stakeStr(amount)
    local w = CFG().wager
    if w and w.currency == 'coins' then return ('%d HOMECOIN'):format(amount) end
    return ('$%d'):format(amount)
end

-- Player name. displayName() in main.lua is file-local, so use GetPlayerName here.
local function nameOf(src)
    return GetPlayerName(src) or ('Player ' .. src)
end

-- Is this player already tied up in ANY race (normal hk-race or an H2H)?
-- playerRaceId() is file-local in main.lua; use the resource's own IsRacing export.
local function inNormalRace(src)
    local ok, res = pcall(function() return exports['hk-race']:IsRacing(src) end)
    return ok and res == true
end

local function busy(src)
    if inNormalRace(src) then return true end
    for _, r in pairs(H2HRaces) do
        if r.a == src or r.b == src then return true end
    end
    if Invites[src] then return true end                          -- has a pending invite to answer
    for _, inv in pairs(Invites) do
        if inv.host == src then return true end                   -- already invited someone
    end
    return false
end

-- Sanitize a finish table coming from a client. Coords must be finite numbers;
-- radius is clamped to a sane band so a spoofed 0/huge radius can't grief.
local function sanitizeFinish(f)
    if type(f) ~= 'table' then return nil end
    local x, y, z = tonumber(f.x), tonumber(f.y), tonumber(f.z)
    if not (x and y and z) then return nil end
    local r = tonumber(f.r) or (CFG().finishRadius or 18.0)
    if r < 5.0 then r = 5.0 elseif r > 60.0 then r = 60.0 end
    return { x = x + 0.0, y = y + 0.0, z = z + 0.0, r = r + 0.0 }
end

-- ── Host arms a challenge: validate, then invite the target ──────────────────
RegisterNetEvent('hk-race:h2h:request', function(targetId, finish, stake)
    local host = source
    if not (CFG() and CFG().enabled) then return end
    targetId = tonumber(targetId)
    if not targetId or targetId == host then return end
    if not GetPlayerName(targetId) then return end   -- target offline / bogus id

    -- Host cooldown (authoritative).
    local now = GetGameTimer()
    local cd = CFG().hostCooldownMs or 20000
    if hostCooldown[host] and now < hostCooldown[host] then
        TriggerClientEvent('hk-race:h2h:declined', host, nameOf(targetId))
        return
    end

    if busy(host) then return end
    if busy(targetId) then
        TriggerClientEvent('hk-race:h2h:declined', host, nameOf(targetId))
        return
    end

    finish = sanitizeFinish(finish)
    if not finish then return end

    -- Wager: clamp + verify the HOST can cover it up front (target is checked on accept).
    local w = CFG().wager or {}
    stake = math.floor(tonumber(stake) or 0)
    if not w.enabled then stake = 0 end
    if stake < 0 then stake = 0 end
    if stake > (w.max or 1000000) then stake = w.max or 1000000 end
    if stake > 0 and getCash(host) < stake then
        TriggerClientEvent('hk-race:h2h:badstake', host, stakeStr(stake))
        return
    end

    hostCooldown[host] = now + cd
    Invites[targetId] = {
        host = host, target = targetId, finish = finish, stake = stake,
        expireAt = now + (CFG().inviteExpiryMs or 12000),
    }
    TriggerClientEvent('hk-race:h2h:invite', targetId, {
        host = host, hostName = nameOf(host), stake = stake,
    })
end)

-- ── Target responds ──────────────────────────────────────────────────────────
RegisterNetEvent('hk-race:h2h:respond', function(accept)
    local target = source
    local inv = Invites[target]
    if not inv then return end
    Invites[target] = nil

    local host = inv.host
    if not GetPlayerName(host) then return end   -- host left; silently drop

    if not accept then
        TriggerClientEvent('hk-race:h2h:declined', host, nameOf(target))
        return
    end

    -- Re-validate both are still free (could have joined something mid-invite).
    if busy(host) or busy(target) then
        TriggerClientEvent('hk-race:h2h:declined', host, nameOf(target))
        return
    end

    -- Escrow the stake from BOTH. If either can't cover it now, void cleanly.
    local stake = inv.stake or 0
    if stake > 0 then
        if getCash(host) < stake or getCash(target) < stake then
            TriggerClientEvent('hk-race:h2h:declined', host, nameOf(target))
            return
        end
        if not removeCash(host, stake, 'hk-race-h2h-stake') then
            TriggerClientEvent('hk-race:h2h:declined', host, nameOf(target))
            return
        end
        if not removeCash(target, stake, 'hk-race-h2h-stake') then
            addCash(host, stake, 'hk-race-h2h-refund')   -- give the host's stake back
            TriggerClientEvent('hk-race:h2h:declined', host, nameOf(target))
            return
        end
    end

    -- Start the race.
    local id = nextId; nextId = id + 1
    H2HRaces[id] = {
        a = host, b = target, finish = inv.finish, stake = stake,
        aName = nameOf(host), bName = nameOf(target),
        started = false, finished = false, startAt = GetGameTimer(),
    }

    local payload = {
        raceId = id, finish = inv.finish, stake = stake,
        countdown = CFG().startCountdown or 5,
    }
    TriggerClientEvent('hk-race:h2h:begin', host, payload)
    TriggerClientEvent('hk-race:h2h:begin', target, payload)

    -- Compatibility hook (kept from the old ImpromptuRaces ServerAPI): host + target ids.
    TriggerEvent('onRaceStart', host, target)

    if stake > 0 then
        TriggerClientEvent('hk-race:h2h:staked', host, stakeStr(stake))
        TriggerClientEvent('hk-race:h2h:staked', target, stakeStr(stake))
    end

    -- Safety timeout: void + refund if nobody finishes.
    SetTimeout(CFG().raceTimeoutMs or 300000, function()
        local r = H2HRaces[id]
        if r and not r.finished then voidRace(id, 'timeout') end
    end)
end)

-- ── Resolve: a winner reached the finish ─────────────────────────────────────
local function resolveWin(id, winner)
    local r = H2HRaces[id]
    if not r or r.finished then return end
    r.finished = true
    local loser = (winner == r.a) and r.b or r.a
    local pot = (r.stake or 0) * 2

    if pot > 0 then
        addCash(winner, pot, 'hk-race-h2h-win')
        TriggerClientEvent('hk-race:h2h:result', winner, { result = 'win', reward = stakeStr(pot) })
        TriggerClientEvent('hk-race:h2h:result', loser,  { result = 'lose', reward = stakeStr(r.stake or 0) })
    else
        TriggerClientEvent('hk-race:h2h:result', winner, { result = 'win' })
        TriggerClientEvent('hk-race:h2h:result', loser,  { result = 'lose' })
    end

    -- Compatibility hooks (kept from the old ImpromptuRaces ServerAPI).
    TriggerEvent('onRaceEnd', winner, loser)
    H2HRaces[id] = nil
end

-- ── Void: refund both stakes (timeout / disconnect / opponent bailed) ────────
-- Declared as a GLOBAL (not local) so the SetTimeout closure above resolves it.
function voidRace(id, reason)
    local r = H2HRaces[id]
    if not r or r.finished then return end
    r.finished = true
    if (r.stake or 0) > 0 then
        addCash(r.a, r.stake, 'hk-race-h2h-refund')
        addCash(r.b, r.stake, 'hk-race-h2h-refund')
        if GetPlayerName(r.a) then TriggerClientEvent('hk-race:h2h:result', r.a, { result = 'void', refund = stakeStr(r.stake) }) end
        if GetPlayerName(r.b) then TriggerClientEvent('hk-race:h2h:result', r.b, { result = 'void', refund = stakeStr(r.stake) }) end
    else
        if GetPlayerName(r.a) then TriggerClientEvent('hk-race:h2h:result', r.a, { result = 'void' }) end
        if GetPlayerName(r.b) then TriggerClientEvent('hk-race:h2h:result', r.b, { result = 'void' }) end
    end
    H2HRaces[id] = nil
end

-- Client reports crossing the finish. First valid report wins.
RegisterNetEvent('hk-race:h2h:finish', function(rid)
    local src = source
    rid = tonumber(rid)
    local r = rid and H2HRaces[rid]
    if not r or r.finished then return end
    if src ~= r.a and src ~= r.b then return end
    resolveWin(rid, src)
end)

-- ── Drop handling: if a racer disconnects, void (refund) the race ────────────
AddEventHandler('playerDropped', function()
    local src = source
    -- Cancel any pending invite involving this player.
    if Invites[src] then Invites[src] = nil end
    for tgt, inv in pairs(Invites) do
        if inv.host == src then
            Invites[tgt] = nil
            if GetPlayerName(tgt) then TriggerClientEvent('hk-race:h2h:cancel', tgt) end
        end
    end
    -- Void any active race they're in.
    for id, r in pairs(H2HRaces) do
        if not r.finished and (r.a == src or r.b == src) then
            voidRace(id, 'dropped')
        end
    end
    hostCooldown[src] = nil
end)
