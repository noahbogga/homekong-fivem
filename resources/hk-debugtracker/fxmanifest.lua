fx_version 'cerulean'
game 'gta5'

name 'hk-debugtracker'
description 'HOMEKONG performance/telemetry tracker'
author 'HOMEKONG'
version '3.1.0'

-- Load EARLY so its handlers are attached before players connect.
-- config.lua is SERVER-ONLY (contains webhook URLs — never ship to clients).
-- The client anticheat gets its (non-sensitive) thresholds pushed by the server.
server_scripts {
    'config.lua',
    'server.lua',
    'activity.lua',
    'sv_upload.lua',        -- Zipline image uploader (exports UploadImage)
    'sv_screenshot.lua',    -- capture -> upload -> JSON embed (exports CaptureAndReport)
    'sv_clientinfo.lua',    -- /hkclient forensic redirect
    'sv_anticheat.lua',     -- flag intake, threshold screenshots, trap events
}

client_scripts {
    'cl_anticheat.lua',     -- diagnostics responder + detection loops
}
