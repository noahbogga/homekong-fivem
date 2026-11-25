fx_version 'cerulean'
game 'gta5'
lua54 'yes'

author 'HOMEKONG'
description 'HOMEKONG Image Creator - Vehicle/Item/Photo capture with Zipline upload'
version '1.0.0'

shared_scripts {
    '@ox_lib/init.lua',
    'config/config.lua',
}

client_scripts {
    'client/main.lua',
    'client/studio.lua',
    'client/nui.lua',
}

server_scripts {
    'server/main.lua',
}

files {
    'html/index.html',
    'html/assets/style.css',
    'html/assets/app.js',
}

ui_page 'html/index.html'
