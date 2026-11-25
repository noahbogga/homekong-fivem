fx_version 'cerulean'
game 'gta5'

author 'HOMEKONG'
description 'HK Freecam — Admin cinematic camera'
version '1.0.0'

shared_scripts {
    '@ox_lib/init.lua',
}

client_scripts {
    'config.lua',
    'cl_freecam.lua',
}

server_scripts {
    'sv_freecam.lua',
}

lua54 'yes'
