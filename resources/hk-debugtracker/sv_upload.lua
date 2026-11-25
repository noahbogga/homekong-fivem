-- hk-debugtracker :: sv_upload.lua
-- Server-side image upload to Zipline (images.example.com) via phone-upload relay.
--
-- FiveM's PerformHttpRequest truncates binary strings at null bytes (\0).
-- JPEG/PNG contain null bytes, so multipart uploads corrupt the body.
-- Fix: send base64 (ASCII-safe) as JSON to the phone-upload relay on .247:3090,
-- which decodes server-side and uploads proper multipart to Zipline.

local UP = Config.Screenshot or {}
local RELAY_URL = 'http://YOUR_SERVICES_HOST:3090/upload'

local function getToken()
    return GetConvar(UP.TokenConvar or 'hk_zipline_token', '')
end

-- UploadImage(rawBytesOrBase64, opts, cb)
--   rawBytesOrBase64 : DEPRECATED binary string, OR base64 string (preferred)
--   opts             : { filename?, base64? (bool - true if input is already base64) }
--   cb(url|nil, err)
function UploadImage(input, opts, cb)
    opts = opts or {}
    cb = cb or function() end
    local tok = getToken()
    if tok == '' then return cb(nil, 'no zipline token (set hk_zipline_token convar)') end
    if type(input) ~= 'string' or #input < 8 then return cb(nil, 'empty file') end

    -- Build the data URI for the relay
    local dataUri
    if opts.base64 then
        -- Already base64, just add prefix
        dataUri = 'data:image/jpeg;base64,' .. input
    elseif input:sub(1, 5) == 'data:' then
        -- Full data URI already
        dataUri = input
    else
        -- Legacy: raw binary bytes passed in. We need to base64-encode them.
        -- This still has the null-byte risk if the encoded result is huge,
        -- but the JSON body itself (base64) is ASCII-safe.
        local b64 = _base64Encode(input)
        if not b64 or #b64 < 10 then return cb(nil, 'base64 encode failed') end
        dataUri = 'data:image/jpeg;base64,' .. b64
    end

    local jsonBody = '{"file":"' .. dataUri .. '","token":"' .. tok .. '"}'
    print('[hk-debugtracker] UploadImage: sending ' .. #jsonBody .. ' bytes to relay')

    PerformHttpRequest(RELAY_URL, function(status, respText)
        if status == 200 and respText and respText ~= '' then
            local url = respText:match('"url"%s*:%s*"([^"]+)"')
            if not url then return cb(nil, 'no url in response') end
            url = url:gsub('^http://', 'https://')
            print('[hk-debugtracker] UploadImage: SUCCESS ' .. url)
            cb(url, nil)
        else
            print('[hk-debugtracker] UploadImage: FAILED status=' .. tostring(status))
            cb(nil, 'http ' .. tostring(status))
        end
    end, 'POST', jsonBody, {
        ['content-type'] = 'application/json',
    })
end

-- Simple base64 encoder for legacy callers that pass raw bytes
local B64C = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
function _base64Encode(data)
    if not data then return nil end
    local out = {}
    for i = 1, #data, 3 do
        local a = data:byte(i) or 0
        local b = data:byte(i + 1) or 0
        local c = data:byte(i + 2) or 0
        local n = a * 65536 + b * 256 + c
        out[#out + 1] = B64C:sub(math.floor(n / 262144) % 64 + 1, math.floor(n / 262144) % 64 + 1)
        out[#out + 1] = B64C:sub(math.floor(n / 4096) % 64 + 1, math.floor(n / 4096) % 64 + 1)
        if i + 1 <= #data then
            out[#out + 1] = B64C:sub(math.floor(n / 64) % 64 + 1, math.floor(n / 64) % 64 + 1)
        else
            out[#out + 1] = '='
        end
        if i + 2 <= #data then
            out[#out + 1] = B64C:sub(n % 64 + 1, n % 64 + 1)
        else
            out[#out + 1] = '='
        end
    end
    return table.concat(out)
end

-- expose for other resources (hk-misc, hk-hub, qb-phone anticheat hook)
exports('UploadImage', function(input, opts, cb) return UploadImage(input, opts, cb) end)
