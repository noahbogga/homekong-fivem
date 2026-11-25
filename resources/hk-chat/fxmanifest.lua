-- ═══════════════════════════════════════════════════════════════ --
--   HK-CHAT — HOMEKONG                                                --
--   Tabbed, low-resource chat NUI. Replaces stock `chat`.             --
--   Vanilla HTML/CSS/JS (no Vue). HOMEKONG design language.           --
--                                                                     --
--   Channels: Global (nickname), System (read-only feed + /911 echo   --
--   + admin announce), Job (auto-scoped, unemployed shared).          --
--   /nick, /me, /w whisper, /-command palette, /chatcmd admin hiding. --
--   Groups tab = Phase 2 (config-gated, not built yet).               --
-- ═══════════════════════════════════════════════════════════════ --
fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'hk-chat'
author 'HOMEKONG'
description 'HK-Chat — HOMEKONG-styled tabbed chat (replaces the stock chat resource).'
version '1.0.0'

-- IMPORTANT: this resource OWNS chat. Stop the stock `chat` resource in
-- server.cfg before ensuring hk-chat, or the two will fight over key 245.
ui_page 'html/index.html'

shared_scripts {
    'config.lua',
}

client_scripts {
    'core/framework/client.lua',
    'client/main.lua',
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'core/framework/server.lua',
    'server/main.lua',
}

files {
    'html/index.html',
    'html/style.css',
    'html/app.js',
}

dependencies {
    'qb-core',
    'oxmysql',
}
