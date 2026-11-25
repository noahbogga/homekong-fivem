fx_version 'cerulean'
game 'gta5'
lua54 'yes'

author 'homekong'
description 'Drug selling system - NPC dialog with qb-target'
version '1.1.0-ai'

shared_scripts {
    '@ox_lib/init.lua',
    'config.lua',
}

client_scripts {
    'client/main.lua',
}

server_scripts {
    'server/main.lua',
}

ui_page 'ui/index.html'

files {
    'ui/index.html',
    'ui/style.css',
    'ui/script.js',
}

dependencies {
    'ox_lib',
    'qb-core',
    'qb-target',
}
