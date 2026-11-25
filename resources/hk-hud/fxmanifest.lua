fx_version 'cerulean'
game 'gta5'

author 'HOMEKONG'
description 'hk-hud — HOMEKONG player status HUD (replaces ps-hud). Vehicle gauge is hk-speedo.'
version '0.1.0'

shared_scripts {
    'config.lua'
}

client_scripts {
    'client/main.lua'
}

server_scripts {
    'server/main.lua'
}

ui_page 'html/index.html'

files {
    'html/index.html',
    'html/style.css',
    'html/app.js'
}

dependencies {
    'qb-core'
}

lua54 'yes'
