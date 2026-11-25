-- hk-documents :: server/portal.lua
-- Browser upload portal backend. Realizes the "clipboard paste / browser upload"
-- flow that in-game CEF can't do reliably:
--
--   1. Player requests a code in-game            -> NewUploadCode()
--   2. Player opens the portal page in a browser, types the code, picks/pastes
--      an image. The page POSTs {code, image(base64)} to /hk-documents/portal-upload
--   3. Server validates the code, uploads bytes to Zipline, stores the URL
--   4. In-game the player claims the URL by code  -> ClaimUploadCode()
--
-- Codes are short, single-use, and expire (PortalConfig.codeTtlSeconds).

local CODES = {}   -- [code] = { owner=citizenid, url=nil, createdAt=os.time(), used=false }

local function genCode()
    local chars = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789'  -- no ambiguous 0/O/1/I/L
    local code
    repeat
        local t = {}
        for _ = 1, 6 do
            local i = math.random(1, #chars)
            t[#t + 1] = chars:sub(i, i)
        end
        code = table.concat(t)
    until not CODES[code]
    return code
end

local function purgeExpired()
    local ttl = PortalConfig.codeTtlSeconds or 600
    local now = os.time()
    for code, rec in pairs(CODES) do
        if now - rec.createdAt > ttl then CODES[code] = nil end
    end
end

-- Called by main.lua when a player asks for an upload code.
function NewUploadCode(citizenid)
    purgeExpired()
    local code = genCode()
    CODES[code] = { owner = citizenid, url = nil, createdAt = os.time(), used = false }
    return code
end

-- Called by main.lua when the player claims the resulting URL in-game.
function ClaimUploadCode(citizenid, code)
    purgeExpired()
    local rec = CODES[tostring(code or ''):upper()]
    if not rec then return nil, 'not_found' end
    if rec.owner ~= citizenid then return nil, 'wrong_owner' end
    if not rec.url then return nil, 'pending' end
    CODES[tostring(code):upper()] = nil   -- single use
    return rec.url, nil
end

-- ── HTTP endpoints for the portal browser page ────────────────────────────
local function sendJson(res, status, tbl)
    res.writeHead(status, {
        ['Content-Type'] = 'application/json',
        ['Access-Control-Allow-Origin'] = (PortalConfig and PortalConfig.allowOrigin) or '*',
        ['Access-Control-Allow-Headers'] = 'Content-Type',
        ['Access-Control-Allow-Methods'] = 'POST, GET, OPTIONS',
    })
    res.send(json.encode(tbl))
end

SetHttpHandler(function(req, res)
    local path = req.path or '/'

    -- CORS preflight
    if req.method == 'OPTIONS' then
        return sendJson(res, 204, {})
    end

    -- Portal i18n: serve the active locale's pp_* strings so the browser page
    -- follows Config.Locale instead of being hardcoded to one language.
    if path:match('^/portal%-i18n') then
        local loc = Locales[Config.Locale] or Locales['en'] or {}
        local out = {}
        for k, v in pairs(loc) do
            if type(k) == 'string' and k:match('^pp_') then out[k] = v end
        end
        return sendJson(res, 200, { ok = true, locale = Config.Locale, strings = out })
    end

    -- Portal check: does this code exist and is it still pending? (page polls)
    -- De-leaked: always return a uniform shape so an unauthenticated caller can't
    -- probe which codes exist (both missing and pending look identical; only a
    -- completed, still-live code reports done=true).
    if path:match('^/portal%-status') then
        local code = (req.path:match('[?&]code=([A-Za-z0-9]+)') or ''):upper()
        local rec = CODES[code]
        return sendJson(res, 200, { ok = true, done = (rec and rec.url ~= nil) or false })
    end

    -- Upload: portal page POSTs { code, image (base64 data URL or raw b64) }
    if path:match('^/portal%-upload') and req.method == 'POST' then
        req.setDataHandler(function(bodyStr)
            local body = nil
            pcall(function() body = json.decode(bodyStr) end)
            if not body or not body.code or not body.image then
                return sendJson(res, 400, { ok = false, error = 'bad_request' })
            end

            -- Require the shared secret (defense-in-depth: blocks unauthenticated
            -- scanners / off-origin tools). Must match SECRET in portal.js.
            local want = PortalConfig and PortalConfig.secret
            if want and want ~= '' and body.secret ~= want then
                return sendJson(res, 401, { ok = false, error = 'unauthorized' })
            end

            local code = tostring(body.code):upper()
            local rec = CODES[code]
            if not rec then return sendJson(res, 404, { ok = false, error = 'invalid_code' }) end
            if rec.url then return sendJson(res, 409, { ok = false, error = 'already_uploaded' }) end

            -- strip data URL prefix if present
            local b64 = body.image:gsub('^data:[^,]+,', '')
            local raw = nil
            pcall(function() raw = FromBase64(b64) end)
            if not raw or #raw < 8 then
                return sendJson(res, 400, { ok = false, error = 'bad_image' })
            end

            UploadImage(raw, { filename = 'portal_' .. code }, function(url, err)
                if url then
                    rec.url = url
                    sendJson(res, 200, { ok = true, url = url })
                else
                    sendJson(res, 502, { ok = false, error = err or 'upload_failed' })
                end
            end)
        end)
        return
    end

    -- Anything else: not handled here (NUI files are served by ui_page/files).
    res.writeHead(404)
    res.send('not found')
end)

-- Minimal base64 decoder (FiveM has no built-in in all builds).
local b64chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
function FromBase64(data)
    data = data:gsub('[^' .. b64chars .. '=]', '')
    local map = {}
    for i = 1, #b64chars do map[b64chars:sub(i, i)] = i - 1 end
    local out = {}
    local bits, nbits = 0, 0
    for i = 1, #data do
        local c = data:sub(i, i)
        if c == '=' then break end
        bits = bits * 64 + map[c]
        nbits = nbits + 6
        if nbits >= 8 then
            nbits = nbits - 8
            local byte = math.floor(bits / (2 ^ nbits)) % 256
            out[#out + 1] = string.char(byte)
        end
    end
    return table.concat(out)
end
