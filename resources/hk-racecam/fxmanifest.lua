-----------------------------------------------------------------
-- hk-racecam - Motorfest-style dynamic vehicle camera (HOMEKONG)
-- Idle-aware: free mouse-look stays alive; cam eases in only when
-- the player stops looking around, and drops the instant they move.
-----------------------------------------------------------------

fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'hk-racecam'
description 'Dynamic race camera with idle-detected engagement and adaptive per-vehicle framing'
author 'HOMEKONG'
version '1.0.1'

shared_script 'config.lua'

client_script 'client.lua'
server_script 'server.lua'

ui_page 'html/index.html'

files {
    'html/index.html',
    'html/style.css',
    'html/script.js',
    'html/blur.js'      -- WebGL radial speed-blur overlay (external_texture hook)
}
