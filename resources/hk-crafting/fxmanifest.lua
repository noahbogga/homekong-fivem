fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'hk-crafting'
author 'HOMEKONG'
description 'HK-Crafting - Portable crafting tables. Use a table item to ghost-place a bench, target it to open a custom HK crafting panel, craft items from materials with optional blueprint gates, pick the table back up. qb-core + qb-inventory + qb-target + ox_lib, custom NUI.'
version '1.0.0'

shared_scripts {
    '@ox_lib/init.lua',
    'shared/config.lua',
    'shared/locales.lua',
}

client_scripts {
    'client/main.lua',
    'client/place.lua',
    'client/craft.lua',
    'client/stations.lua',
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/main.lua',
}

ui_page 'html/index.html'

files {
    'html/index.html',
    'html/css/style.css',
    'html/js/app.js',
}

dependencies {
    'qb-core',
    'qb-inventory',
    'qb-target',
    'ox_lib',
    'oxmysql',
}
