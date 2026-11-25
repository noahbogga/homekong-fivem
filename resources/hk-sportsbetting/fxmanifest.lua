fx_version 'cerulean'
game 'gta5'

author 'HOMEKONG'
description 'Steak — Sports & Casino'
version '3.0.0'

shared_scripts {
    'config.lua'
}

server_scripts {
    'server/secrets.lua',
    '@oxmysql/lib/MySQL.lua',
    'server/crypto.lua',
    'server/coins.lua',
    'server/vip.lua',
    'server/fair.lua',
    'server/trending.lua',
    'server/api.lua',
    'server/bets.lua',
    'server/casino.lua',
    'server/mobile.lua',
    'server/mobilekey.lua'
}

client_scripts {
    'client/main.lua',
    'client/nui.lua'
}

ui_page 'html/index.html'

files {
    'html/index.html',
    'html/assets/*.js',
    'html/assets/*.css',
    'html/images/*.png',
    'html/*.mp3'
}

lua54 'yes'
