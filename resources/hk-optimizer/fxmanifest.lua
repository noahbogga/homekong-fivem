fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'hk-optimizer'
author 'HOMEKONG'
description 'FPS optimizer: admin editor tunes render modes (Quality/Balance/Enhanced FPS+) saved to MySQL. Player selection lives in /hud (F5).'
version '2.0.0'

shared_scripts {
    '@ox_lib/init.lua',
    'shared/config.lua',
}

client_scripts {
    '@menuv/menuv.lua',
    'client/engine.lua',
    'client/editor.lua',
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/allowlist.lua',
    'server/main.lua',
}

dependencies {
    'qb-core',
    'oxmysql',
    'menuv',
    'ox_lib',
}
