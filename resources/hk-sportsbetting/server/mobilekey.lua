-- mobilekey.lua — in-game management of the web/mobile access key.
--
-- The player sets an 8-char key in the hk-hub Settings panel; that key + a stable
-- loginId are how they authenticate the browser/PWA mirror. We store the RAW key
-- here on the GAME DB (so the panel can re-display it on demand) and push it ONCE
-- to the engine, which derives + stores only a scrypt hash (never the raw key).
--
-- Regenerating bumps key_ver on the engine, which drops every active web session
-- for this character — the "reset all outside services if the key leaked" button.
--
-- Exposed as server exports for hk-hub to call:
--   exports['hk-sportsbetting']:MobileGetKey(citizenid)      -> {loginId, key, ver} | nil
--   exports['hk-sportsbetting']:MobileRegenKey(citizenid)    -> {loginId, key, ver} | nil (also new login on first gen)

-- 8-char alphanumeric, no ambiguous chars (0/O/1/I/L) — easy to type, ~2.8e12 space.
local KEY_ALPHABET = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789'
local LOGIN_ALPHABET = 'abcdefghjkmnpqrstuvwxyz23456789'

local function randFrom(alphabet, n)
    -- Prefer crypto-quality bytes from /dev/urandom; fall back to math.random.
    local out = {}
    local f = io.open('/dev/urandom', 'rb')
    local bytes = f and f:read(n * 2) or nil
    if f then f:close() end
    for i = 1, n do
        local r
        if bytes and #bytes >= i then
            r = string.byte(bytes, i)
        else
            r = math.random(0, 255)
        end
        out[i] = alphabet:sub((r % #alphabet) + 1, (r % #alphabet) + 1)
    end
    return table.concat(out)
end

-- Ensure the game-DB table exists (owned here, on the .235 game DB — NOT the
-- engine's isolated betting DB). Stores raw key + loginId + version per character.
-- char_name is a cached label so the table is self-describing when read directly
-- in the DB (see the hk_mobile_keys_named VIEW below for always-fresh names).
CreateThread(function()
    MySQL.query([[
        CREATE TABLE IF NOT EXISTS hk_mobile_keys (
            citizenid VARCHAR(64) PRIMARY KEY,
            login_id  VARCHAR(32) NOT NULL,
            web_key   VARCHAR(16) NOT NULL,
            key_ver   INT NOT NULL DEFAULT 1,
            char_name VARCHAR(64) DEFAULT NULL,
            updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
            UNIQUE KEY uniq_login (login_id)
        ) ]], {})
    -- add char_name on pre-existing installs (idempotent)
    MySQL.query("ALTER TABLE hk_mobile_keys ADD COLUMN IF NOT EXISTS char_name VARCHAR(64) DEFAULT NULL", {})
    -- Self-describing view: whose code is what, with LIVE names from the players
    -- table (charinfo is JSON). Read this in the DB for handoff:
    --   SELECT * FROM hk_mobile_keys_named ORDER BY char_name;
    MySQL.query([[
        CREATE OR REPLACE VIEW hk_mobile_keys_named AS
        SELECT k.citizenid,
               TRIM(CONCAT(
                   COALESCE(JSON_UNQUOTE(JSON_EXTRACT(p.charinfo, '$.firstname')), ''), ' ',
                   COALESCE(JSON_UNQUOTE(JSON_EXTRACT(p.charinfo, '$.lastname')), '')
               )) AS player_name,
               k.login_id,
               k.web_key,
               k.key_ver,
               k.updated_at
        FROM hk_mobile_keys k
        LEFT JOIN players p
          ON p.citizenid COLLATE utf8mb4_unicode_ci = k.citizenid COLLATE utf8mb4_unicode_ci
    ]], {})
end)

-- Resolve a character's display name from the game `players` table (works for
-- OFFLINE players — that's the whole point of the handoff flow).
local function resolveName(citizenid)
    local rows = MySQL.query.await(
        'SELECT charinfo FROM players WHERE citizenid = ?', { citizenid })
    if not rows or not rows[1] then return nil end
    local ci = rows[1].charinfo
    if type(ci) == 'string' then
        local ok, decoded = pcall(json.decode, ci)
        ci = ok and decoded or {}
    end
    ci = ci or {}
    local parts = {}
    if ci.firstname then parts[#parts + 1] = ci.firstname end
    if ci.lastname then parts[#parts + 1] = ci.lastname end
    return #parts > 0 and table.concat(parts, ' ') or nil
end

-- Push the raw key to the engine (which hashes it). Returns true on 2xx.
local function pushKeyToEngine(citizenid, loginId, key, ver)
    local res = _G.EngineSync('/mobile/keypush', 'POST', {
        identifier = citizenid, loginId = loginId, key = key, keyVer = ver,
    })
    return res and res.success == true
end

-- Read the current key row for a character (nil if never generated).
local function getKeyRow(citizenid)
    local rows = MySQL.query.await(
        'SELECT login_id, web_key, key_ver FROM hk_mobile_keys WHERE citizenid = ?', { citizenid })
    if rows and rows[1] then
        return { loginId = rows[1].login_id, key = rows[1].web_key, ver = rows[1].key_ver }
    end
    return nil
end

-- Generate (first time) or regenerate the key. loginId is stable across regens
-- once assigned; only the key + version change so the player keeps one login name.
local function regenKey(citizenid)
    if not citizenid then return nil end
    local existing = getKeyRow(citizenid)
    local loginId = existing and existing.loginId or nil
    if not loginId then
        -- assign a fresh, unique login id (retry on the rare collision)
        for _ = 1, 5 do
            local cand = randFrom(LOGIN_ALPHABET, 10)
            local clash = MySQL.query.await('SELECT 1 FROM hk_mobile_keys WHERE login_id = ?', { cand })
            if not clash or not clash[1] then loginId = cand break end
        end
        if not loginId then return nil end
    end
    local newKey = randFrom(KEY_ALPHABET, 8)
    local newVer = (existing and existing.ver or 0) + 1

    -- Push to engine FIRST; only persist locally if the engine accepted it, so the
    -- displayed key always matches what the engine will authenticate.
    if not pushKeyToEngine(citizenid, loginId, newKey, newVer) then
        return nil
    end
    local charName = resolveName(citizenid)
    MySQL.insert.await([[
        INSERT INTO hk_mobile_keys (citizenid, login_id, web_key, key_ver, char_name)
        VALUES (?, ?, ?, ?, ?)
        ON DUPLICATE KEY UPDATE web_key = VALUES(web_key), key_ver = VALUES(key_ver),
                                char_name = VALUES(char_name)
    ]], { citizenid, loginId, newKey, newVer, charName })
    return { loginId = loginId, key = newKey, ver = newVer, name = charName }
end

-- ── exports for hk-hub ──
exports('MobileGetKey', function(citizenid)
    return getKeyRow(citizenid)
end)

exports('MobileRegenKey', function(citizenid)
    return regenKey(citizenid)
end)

-- Export the offline-handoff helper too, so the admin panel / other resources can
-- mint a key for a player who can't get in-game. get-or-create: returns the
-- existing key if one exists, else generates a first one.
exports('MobileGetOrCreateKey', function(citizenid)
    return getKeyRow(citizenid) or regenKey(citizenid)
end)

-- ═══════════════════════════════════════════════════════════════
-- ADMIN CONSOLE COMMANDS (server console only — source 0, matching hk_pushidentity)
-- For handing off web access to players who can't get online quickly.
-- ═══════════════════════════════════════════════════════════════

-- hk_mobilekeys — list every issued key WITH the player's name, so you can see at
-- a glance whose code is what. Reads the named view (live names from players).
RegisterCommand('hk_mobilekeys', function(source)
    if source ~= 0 then return end
    local rows = MySQL.query.await([[
        SELECT citizenid, player_name, login_id, web_key, key_ver, updated_at
        FROM hk_mobile_keys_named ORDER BY player_name IS NULL, player_name ]], {})
    if not rows or #rows == 0 then
        print('[hk-mobilekeys] no keys issued yet')
        return
    end
    print(('[hk-mobilekeys] %d issued:'):format(#rows))
    print(string.format('  %-20s | %-12s | %-8s | v%-3s | %s', 'NAME', 'LOGIN ID', 'KEY', '', 'CITIZENID'))
    for _, r in ipairs(rows) do
        print(string.format('  %-20s | %-12s | %-8s | v%-3s | %s',
            (r.player_name and r.player_name ~= '') and r.player_name or '(unknown)',
            r.login_id, r.web_key, tostring(r.key_ver), r.citizenid))
    end
end, true)

-- hk_mobilekey <citizenid> [regen] — get (or create) a key for one character and
-- print the login id + key to hand off. Add "regen" to force a NEW key (invalidates
-- their old sessions). Works for OFFLINE players.
RegisterCommand('hk_mobilekey', function(source, args)
    if source ~= 0 then return end
    local cid = args[1]
    if not cid then
        print('[hk-mobilekey] usage: hk_mobilekey <citizenid> [regen]')
        return
    end
    local force = args[2] == 'regen'
    local name = resolveName(cid)
    if name == nil then
        print(('[hk-mobilekey] warning: no character found for citizenid "%s" (issuing anyway)'):format(cid))
    end
    local row
    if force then
        row = regenKey(cid)
    else
        row = getKeyRow(cid) or regenKey(cid)
    end
    if not row then
        print('[hk-mobilekey] FAILED — engine keypush rejected (is hk-odds-engine up?)')
        return
    end
    print('[hk-mobilekey] ────────────────────────────────')
    print(('  Player : %s'):format(name or '(unknown)'))
    print(('  Cid    : %s'):format(cid))
    print(('  Login  : %s'):format(row.loginId))
    print(('  Key    : %s'):format(row.key))
    print(('  Version: %s%s'):format(row.ver, force and ' (regenerated — old sessions dropped)' or ''))
    print('  Site   : https://games.example.com/play/')
    print('[hk-mobilekey] ────────────────────────────────')
end, true)
