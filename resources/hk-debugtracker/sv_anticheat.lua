-- hk-debugtracker :: sv_anticheat.lua  (SERVER)
-- Receives client anticheat flags, logs them to hk_event_log, counts them per
-- player, and at a threshold auto-captures a screenshot + full client-info dump
-- to the anticheat webhook. NO auto-ban, NO auto-kick — measurement only.
-- Staff review the embed and ban manually.
--
-- Also classifies exempt (owner/staff) clients so their detection loops stay
-- quiet, and installs curated "trap event" handlers that flag (not ban) when a
-- non-authorized source fires an admin/money/injector event.

local AC = Config.Anticheat or {}

-- ---- exempt classification ----
-- Staff legitimately use noclip / godmode / teleport, so anyone with a staff
-- ACE is exempt automatically (this tracks anti.cfg's admin/superadmin
-- principals with zero drift). The explicit id list stays as a fallback.
local function isExempt(src)
    if not src or src == 0 then return true end
    -- ACE-based: any of these means staff. add/remove in Config.Anticheat.ExemptAces.
    for _, ace in ipairs(AC.ExemptAces or { 'group.admin', 'group.superadmin', 'qbadmin.join', 'command.hkclient' }) do
        if IsPlayerAceAllowed(src, ace) then return true end
    end
    -- explicit identifier fallback
    if AC.Exempt then
        for i = 0, GetNumPlayerIdentifiers(src) - 1 do
            local id = GetPlayerIdentifier(src, i)
            if id and AC.Exempt[id] then return true end
        end
    end
    return false
end

-- non-sensitive subset of the AC config pushed to clients (NO webhook URLs)
local function clientConfig()
    return {
        Enabled          = AC.Enabled and true or false,
        ClientDebounceMs = AC.ClientDebounceMs,
        Thresholds       = AC.Thresholds,
        BlacklistedPlates= AC.BlacklistedPlates,
    }
end

local function pushConfig(src)
    TriggerClientEvent('hk-debugtracker:client:acConfig', src, clientConfig(), isExempt(src))
end

-- client asks on (re)start
RegisterNetEvent('hk-debugtracker:server:acHello', function()
    pushConfig(source)
end)

-- also push proactively on load (belt and suspenders)
AddEventHandler('QBCore:Server:PlayerLoaded', function(player)
    local src = player and player.PlayerData and player.PlayerData.source
    if src then pushConfig(src) end
end)

-- ---- per-player flag counters ----
local flagCount = {}   -- src -> total flags this session
local lastShot  = {}   -- src -> os.time() of last auto-screenshot (cooldown)

local function acWebhook()
    return (AC.Webhook and AC.Webhook ~= '' and AC.Webhook) or Config.FloodWebhook
end

local function identLine(src)
    local name = GetPlayerName(src) or '?'
    local lic, disc = 'n/a', 'n/a'
    for i = 0, GetNumPlayerIdentifiers(src) - 1 do
        local id = GetPlayerIdentifier(src, i)
        if id and id:sub(1, 8) == 'license:' then lic = id end
        if id and id:sub(1, 8) == 'discord:' then disc = id end
    end
    return name, lic, disc
end

local function doFlag(src, kind, detail)
    if not src or src == 0 or isExempt(src) then return end
    kind = tostring(kind or 'unknown'):sub(1, 32)
    detail = tostring(detail or ''):sub(1, 200)

    flagCount[src] = (flagCount[src] or 0) + 1
    local n = flagCount[src]
    local name, lic, disc = identLine(src)

    -- persist to the existing forensic table
    pcall(function()
        exports.oxmysql:insert(
            'INSERT INTO hk_event_log (event, src, citizenid, license, name, args) VALUES (?, ?, ?, ?, ?, ?)',
            { 'anticheat:' .. kind, src, 'n/a', lic, name, ('flag %d | %s'):format(n, detail) })
    end)

    print(('^3[hk-perf][AC] %s (id %s) flag #%d: %s — %s^7'):format(name, src, n, kind, detail))

    -- at threshold: auto-screenshot + full client-info to the AC webhook (cooldowned)
    local threshold = AC.FlagsForScreenshot or 3
    local cd = AC.ScreenshotCooldown or 60
    if n >= threshold and (not lastShot[src] or (os.time() - lastShot[src]) >= cd) then
        lastShot[src] = os.time()
        local fields = {
            { name = 'Player', value = ('%s (id %s)'):format(name, src), inline = true },
            { name = 'Flags',  value = tostring(n), inline = true },
            { name = 'Latest', value = ('`%s` — %s'):format(kind, detail), inline = false },
            { name = 'License', value = ('`%s`'):format(lic), inline = false },
            { name = 'Discord', value = (disc ~= 'n/a' and ('<@%s>'):format(disc:sub(9)) or '—'), inline = true },
        }
        CaptureAndReport(src, {
            webhook = acWebhook(),
            title = '🚨 Anticheat flag — ' .. name,
            description = ('**%d** flags this session. Latest: **%s**.\nReview and ban manually if warranted.'):format(n, kind),
            fields = fields,
            color = 15158332,
        })
    else
        -- below threshold: cheap text embed so nothing is missed
        postShotEmbed(acWebhook(),
            '⚑ AC flag — ' .. name,
            ('id %s · flag #%d · `%s` — %s'):format(src, n, kind, detail),
            nil, nil, 16776960)
    end
end

RegisterNetEvent('hk-debugtracker:server:acFlag', function(kind, detail)
    doFlag(source, kind, detail)
end)

AddEventHandler('playerDropped', function()
    flagCount[source] = nil
    lastShot[source] = nil
end)

-- ---- curated TRAP events (flag, don't ban) ----
-- These are admin/money/injector events a legit client never fires. If a
-- non-authorized source triggers one, raise an anticheat flag. FiveM runs all
-- handlers for an event name, so registering here does not replace real ones.
if AC.TrapEvents then
    for _, ev in ipairs(AC.TrapEvents) do
        RegisterNetEvent(ev, function()
            local src = source
            if src == 0 or isExempt(src) then return end
            doFlag(src, 'trapevent', 'fired ' .. ev)
        end)
    end
end
