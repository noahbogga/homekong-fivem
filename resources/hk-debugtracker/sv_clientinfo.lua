-- hk-debugtracker :: sv_clientinfo.lua
-- "Powerful client-info redirect" — /hkclient <id>
-- ACE-gated. Dumps a full forensic profile of a target player to a Discord
-- webhook: every identifier, every HWID/entitlement token, endpoint, ping,
-- playtime, plus live client diagnostics (coords/vehicle/weapon) and an
-- auto-screenshot (via CaptureAndReport). This is the staff "measure this
-- client" tool for anticheat review.

local CI = Config.ClientInfo or {}

-- ---- collect all server-visible identifiers, grouped by scheme ----
local function collectIdentifiers(src)
    local out = {}
    for i = 0, GetNumPlayerIdentifiers(src) - 1 do
        local id = GetPlayerIdentifier(src, i)
        if id then
            local scheme = id:match('^(%w+):') or 'other'
            out[scheme] = id
        end
    end
    return out
end

-- ---- collect HWID / entitlement tokens (the hardware-ban surface) ----
local function collectTokens(src)
    local out = {}
    local n = GetNumPlayerTokens(src)
    for i = 0, n - 1 do
        out[#out + 1] = GetPlayerToken(src, i)
    end
    return out, n
end

-- resolve a player id or citizenid to a live src
local function resolveSrc(target)
    if tostring(target):match('^%d+$') then
        local asId = tonumber(target)
        if GetPlayerName(asId) then return asId end
    end
    -- try citizenid
    local p = QBCore.Functions.GetPlayerByCitizenId and QBCore.Functions.GetPlayerByCitizenId(target)
    if p then return p.PlayerData.source end
    return nil
end

-- build + post the forensic embed (server facts + client diag), then screenshot
local function reportClient(callerSrc, dst)
    local webhook = (CI.Webhook ~= '' and CI.Webhook) or Config.FloodWebhook
    local name = GetPlayerName(dst) or '?'
    local ids = collectIdentifiers(dst)
    local tokens, tokCount = collectTokens(dst)
    local ping = GetPlayerPing(dst)
    local endpoint = GetPlayerEndpoint(dst) or '?'

    local player = QBCore.Functions.GetPlayer(dst)
    local cid = player and player.PlayerData.citizenid or 'n/a'
    local charName = player and player.PlayerData.charinfo and
        ((player.PlayerData.charinfo.firstname or '') .. ' ' .. (player.PlayerData.charinfo.lastname or '')) or 'n/a'

    -- request live client diagnostics with a short timeout
    local done = false
    local function build(clientDiag)
        if done then return end
        done = true
        clientDiag = clientDiag or {}
        local idLines = {}
        for _, scheme in ipairs({ 'license', 'license2', 'discord', 'steam', 'fivem', 'xbl', 'live', 'ip' }) do
            if ids[scheme] then idLines[#idLines + 1] = ('`%s`'):format(ids[scheme]) end
        end
        local tokLines = {}
        for i = 1, math.min(#tokens, 8) do tokLines[#tokLines + 1] = ('`%s`'):format(tokens[i]) end

        local fields = {
            { name = 'Player',   value = ('%s (id %s)'):format(name, dst), inline = true },
            { name = 'Character',value = ('%s\n`%s`'):format(charName, cid), inline = true },
            { name = 'Ping / Endpoint', value = ('%dms\n`%s`'):format(ping, endpoint), inline = true },
            { name = 'Identifiers', value = (#idLines > 0 and table.concat(idLines, '\n')) or '—', inline = false },
            { name = ('HWID tokens (%d)'):format(tokCount), value = (#tokLines > 0 and table.concat(tokLines, '\n')) or '—', inline = false },
        }
        if clientDiag.coords then
            fields[#fields + 1] = { name = 'Location', value = ('`%s` (h %s)'):format(clientDiag.coords, clientDiag.heading or '?'), inline = true }
        end
        if clientDiag.health then
            fields[#fields + 1] = { name = 'Health / Armor', value = ('%s / %s'):format(clientDiag.health, clientDiag.armor or '?'), inline = true }
        end
        if clientDiag.weapon then
            fields[#fields + 1] = { name = 'Weapon', value = tostring(clientDiag.weapon), inline = true }
        end
        if clientDiag.vehicle then
            fields[#fields + 1] = { name = 'Vehicle', value = tostring(clientDiag.vehicle), inline = true }
        end
        if clientDiag.fps then
            fields[#fields + 1] = { name = 'FPS / Bucket', value = ('%s / %s'):format(clientDiag.fps, GetPlayerRoutingBucket(dst) or 0), inline = true }
        end

        -- screenshot + upload; the embed's image becomes the https URL
        CaptureAndReport(dst, {
            webhook = webhook,
            title = '🔎 Client info — ' .. name,
            description = ('Requested by **%s** (id %s)'):format(GetPlayerName(callerSrc) or 'console', callerSrc),
            fields = fields,
            color = 3447003,
        })

        -- also log to hk_event_log for the paper trail (table is created by server.lua)
        pcall(function()
            exports.oxmysql:insert(
                'INSERT INTO hk_event_log (event, src, citizenid, license, name, args) VALUES (?, ?, ?, ?, ?, ?)',
                { 'clientinfo:hkclient', dst, cid, ids.license or 'n/a', name,
                  ('requested by %s (id %s)'):format(GetPlayerName(callerSrc) or 'console', callerSrc) })
        end)
    end

    -- ask the client for live diagnostics; fall back to server-only after timeout
    TriggerClientEvent('hk-debugtracker:client:getDiag', dst, callerSrc)
    pendingDiag[dst] = build
    SetTimeout(2500, function() build(nil) end)
end

-- client replies here with its diagnostics
pendingDiag = pendingDiag or {}
RegisterNetEvent('hk-debugtracker:server:diagReply', function(diag)
    local dst = source
    local cb = pendingDiag[dst]
    if cb then pendingDiag[dst] = nil; cb(diag) end
end)

-- /hkclient <playerId|citizenid>
RegisterCommand(CI.Command or 'hkclient', function(src, args)
    if src ~= 0 and not IsPlayerAceAllowed(src, CI.AcePerm or 'command.hkclient') then
        TriggerClientEvent('chat:addMessage', src, { args = { 'hk-perf', 'no permission' } })
        return
    end
    local target = args[1]
    if not target then
        local reply = 'usage: /' .. (CI.Command or 'hkclient') .. ' <playerId|citizenid>'
        if src == 0 then print(reply) else TriggerClientEvent('chat:addMessage', src, { args = { 'hk-perf', reply } }) end
        return
    end
    local dst = resolveSrc(target)
    if not dst then
        local reply = 'player not found / offline: ' .. tostring(target)
        if src == 0 then print(reply) else TriggerClientEvent('chat:addMessage', src, { args = { 'hk-perf', reply } }) end
        return
    end
    reportClient(src == 0 and 0 or src, dst)
    if src ~= 0 then
        TriggerClientEvent('chat:addMessage', src, { args = { 'hk-perf', ('client-info for id %s dispatched to webhook'):format(dst) } })
    else
        print(('[hk-perf] client-info for id %s dispatched'):format(dst))
    end
end, false)
