fx_version 'cerulean'
game 'gta5'

name 'hk-speedo'
description 'HOMEKONG Racing Speedometer — dual-ring SVG gauge with glow effects'
author 'HOMEKONG'
version '1.1.0'

dependencies {
    'qb-core',
    'oxmysql',
}

client_scripts {
    'config.lua',
    'client.lua',
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server.lua',
}

ui_page 'html/index.html'

files {
    'html/index.html',
    'html/style.css',
    'html/app.js',
}
