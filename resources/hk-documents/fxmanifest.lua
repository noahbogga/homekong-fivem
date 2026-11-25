fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'hk-documents'
author 'HOMEKONG'
description 'HK-Documents - Custom document system (licenses, A4 docs, certificates) with per-job locked branding, server-authorized CRUD, Zipline image attachments + browser upload portal. Clean replacement for k5_documents.'
version '1.0.0'

shared_scripts {
    '@ox_lib/init.lua',
    'shared/config.lua',
    'shared/locales.lua',
}

client_scripts {
    'client/main.lua',
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/sv_config.lua',
    'server/util.lua',
    'server/zipline.lua',
    'server/portal.lua',
    'server/main.lua',
}

ui_page 'html/index.html'

files {
    'html/index.html',
    'html/css/style.css',
    'html/js/app.js',
    'html/portal/index.html',
    'html/portal/portal.css',
    'html/portal/portal.js',
}

dependencies {
    'qb-core',
    'ox_lib',
    'oxmysql',
}
