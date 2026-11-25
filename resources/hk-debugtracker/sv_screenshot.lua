-- hk-debugtracker :: sv_screenshot.lua
-- Central capture -> upload -> Discord (JSON embed with an https image URL).
--
-- This deliberately AVOIDS Discord multipart attachments (which never land on
-- this box). Flow: screenshot-basic captures a data URI -> UploadImage sends base64
-- to the phone-upload relay -> Zipline returns a public https URL -> we post a
-- normal JSON embed whose image.url IS that https URL. JSON webhooks work fine.
-- base64 decode removed: UploadImage now accepts data URIs directly via relay

-- post a JSON embed (optionally with an image url + extra fields) to a webhook.
-- GLOBAL: server_scripts in one resource share Lua state, so sv_anticheat.lua
-- and sv_clientinfo.lua call this directly.
function postShotEmbed(webhook, title, description, imageUrl, fields, color)
    if not webhook or webhook == '' then return end
    local embed = {
        title = title,
        description = description,
        color = color or 3447003,
        fields = fields or nil,
        footer = { text = 'hk-debugtracker • ' .. os.date('!%Y-%m-%d %H:%M:%SZ') },
    }
    if imageUrl then embed.image = { url = imageUrl } end
    PerformHttpRequest(webhook, function() end, 'POST', json.encode({
        username = 'hk-debugtracker',
        embeds = { embed },
    }), { ['Content-Type'] = 'application/json' })
end

-- CaptureAndReport(targetSrc, opts)
--   opts = {
--     webhook   = url,            -- where to post (falls back to Config.FloodWebhook)
--     title     = string,         -- embed title
--     description = string,       -- embed description
--     fields    = { {name,value,inline}, ... },  -- extra embed fields
--     quality   = 0..1,           -- jpg quality (default Config.Screenshot.Quality)
--     color     = int,
--     onDone    = function(url|nil, err) end,     -- optional callback
--   }
function CaptureAndReport(targetSrc, opts)
    opts = opts or {}
    local dst = tonumber(targetSrc)
    local webhook = opts.webhook
    if (not webhook or webhook == '') then webhook = Config.FloodWebhook end
    local title = opts.title or ('Screenshot of ' .. (GetPlayerName(dst) or dst))
    local onDone = opts.onDone or function() end

    if not dst or not GetPlayerName(dst) then
        onDone(nil, 'target offline'); return
    end
    if GetResourceState('screenshot-basic') ~= 'started' then
        postShotEmbed(webhook, title, (opts.description or '') .. '\n⚠️ screenshot-basic not running — text only',
            nil, opts.fields, opts.color)
        onDone(nil, 'screenshot-basic not started'); return
    end

    local q = opts.quality or (Config.Screenshot and Config.Screenshot.Quality) or 0.8
    local ok = pcall(function()
        exports['screenshot-basic']:requestClientScreenshot(dst, { encoding = 'jpg', quality = q },
            function(err, data)
                if err or type(data) ~= 'string' then
                    postShotEmbed(webhook, title, (opts.description or '') .. '\n⚠️ capture failed — text only',
                        nil, opts.fields, opts.color)
                    onDone(nil, 'capture failed'); return
                end
                -- Pass the full data URI (or raw base64) directly to UploadImage
                -- No decode needed — relay handles it
                UploadImage(data, { filename = ('hk_%s_%s'):format(dst, os.time()) }, function(url, uerr)
                    if url then
                        postShotEmbed(webhook, title, opts.description, url, opts.fields, opts.color)
                        onDone(url, nil)
                    else
                        postShotEmbed(webhook, title, (opts.description or '') .. '\n⚠️ upload failed ('
                            .. tostring(uerr) .. ') — text only', nil, opts.fields, opts.color)
                        onDone(nil, uerr)
                    end
                end)
            end)
    end)
    if not ok then
        postShotEmbed(webhook, title, (opts.description or '') .. '\n⚠️ capture threw — text only',
            nil, opts.fields, opts.color)
        onDone(nil, 'capture threw')
    end
end

exports('CaptureAndReport', function(src, opts) return CaptureAndReport(src, opts) end)
exports('PostShotEmbed', function(webhook, title, desc, img, fields, color)
    return postShotEmbed(webhook, title, desc, img, fields, color)
end)
