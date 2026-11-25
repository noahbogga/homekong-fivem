fx_version 'cerulean'
game 'gta5'

name 'hk-handling'
description 'HOMEKONG Vehicle Dynamics — TC, ABS, drift mode, downforce, ESC, wheelie, launch control'
author 'HOMEKONG'
version '0.1.0'

dependency 'hk-vehlib'

client_scripts {
    'config.lua',
    'client/main.lua',
    'client/drift.lua',
    'client/traction.lua',
    'client/downforce.lua',
    'client/stability.lua',
    'client/launch.lua',
    'client/wheelie.lua',
    'client/burnout.lua',
    'client/launchtraction.lua',
    'client/blinker.lua',
    'client/wheelieguard.lua',
    'client/drivetrain.lua',
    'client/diff.lua',
    'client/speedcaldata.lua',
    'client/gearbox.lua',
    'client/normallearner.lua',
    'client/autocal.lua',
    'client/payload.lua',
    'client/rpmdebug.lua',
    'client/acceltimer.lua',
}

server_scripts {
    'config.lua',
    '@oxmysql/lib/MySQL.lua',
    'server/gearbox.lua',
}
