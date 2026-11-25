-- hk-documents :: server/zipline.lua
-- Server-side image upload to Zipline (images.example.com) via phone-upload relay.
--
-- FiveM's PerformHttpRequest truncates binary strings at null bytes.
-- Fix: send base64 as JSON to the relay on .247:3090 which decodes + uploads.

local RELAY_URL = 'http://YOUR_SERVICES_HOST:3090/upload'

-- Simple base64 encoder for raw-byte callers
local B64C = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
local function base64Encode(data)
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

-- UploadImage(rawBytes, opts, cb)
--   rawBytes : binary image data (string) — will be base64-encoded for relay
--   opts     : { filename?, originalName? }
--   cb(url|nil, err)
function UploadImage(rawBytes, opts, cb)
    opts = opts or {}
    cb = cb or function() end
    if not Config.Images.enabled or not Config.Images.uploadEnabled then
        return cb(nil, 'uploads disabled')
    end
    if not ZiplineConfig.token or ZiplineConfig.token == '' then
        return cb(nil, 'no zipline token configured')
    end
    if type(rawBytes) ~= 'string' or #rawBytes < 8 then
        return cb(nil, 'empty file')
    end

    -- Encode raw binary to base64 (ASCII-safe for PerformHttpRequest)
    local b64 = base64Encode(rawBytes)
    if not b64 or #b64 < 10 then return cb(nil, 'base64 encode failed') end

    local dataUri = 'data:image/jpeg;base64,' .. b64
    local jsonBody = '{"file":"' .. dataUri .. '","token":"' .. ZiplineConfig.token .. '"}'

    Dprint('UploadImage: sending ' .. #jsonBody .. ' bytes to relay')

    PerformHttpRequest(RELAY_URL, function(status, respText)
        if status == 200 and respText and respText ~= '' then
            local url = respText:match('"url"%s*:%s*"([^"]+)"')
            if not url then return cb(nil, 'no url in response') end
            url = url:gsub('^http://', 'https://')
            Dprint('upload ok:', url)
            cb(url, nil)
        else
            Dprint('upload failed status', status, respText)
            cb(nil, 'http ' .. tostring(status))
        end
    end, 'POST', jsonBody, {
        ['content-type'] = 'application/json',
    })
end
