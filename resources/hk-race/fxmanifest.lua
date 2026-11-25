fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'hk-race'
author 'HOMEKONG'
description 'Admin-built street race creator. /raceadmin editor + /racemenu host picker, native GTA checkpoints, auto-reroute waypoints, per-position cash/HOMECOIN rewards with turnout scaling, vehicle performance tiers (hk-handling data), 30s ps-dispatch blackout on start, alerts hidden from PD/EMS but visible to FIB/CIA/NIA.'
version '1.0.0'

shared_scripts {
    '@ox_lib/init.lua',
    'shared/config.lua',
    'shared/locales.lua',
    'shared/vehicledata.lua',
}

client_scripts {
    '@menuv/menuv.lua',
    'client/util.lua',
    'client/tier.lua',
    'client/race.lua',
    'client/hud.lua',
    'client/editor.lua',
    'client/nui.lua',
    'client/h2h.lua',
    'client/carcal.lua',
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/main.lua',
    'server/h2h.lua',
}

ui_page 'html/index.html'

files {
    'html/index.html',
    'html/css/style.css',
    'html/js/app.js',
}

dependencies {
    'qb-core',
    'ox_lib',
    'ps-dispatch',
    'menuv',
}
