-- ═══════════════════════════════════════════════════════════ --
--   HK-PARKING (all-in-one) — HOMEKONG                            --
--   Street parking (server-side spawns, statebags) + garage       --
--   (revamped qb-garages) with a live 3D in-world vehicle preview  --
--   and qb-phone "locate my car" integration.                     --
--   Parking engine based on mh-parking PRO (MaDHouSe79, MIT).      --
--   Garage based on qb-garages.                                    --
-- ═══════════════════════════════════════════════════════════ --
fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'hk-parking'
author 'HOMEKONG'
description 'HK-Parking - All-in-one street parking + garage (revamp of qb-garages) with live 3D vehicle preview and phone locating.'
version '1.0.0'

ui_page 'html/index.html'

shared_scripts {
    '@ox_lib/init.lua',
    'config.lua',                 -- garage global Config (Garages/VehicleClass/Preview)
    'core/sv_config.lua',         -- parking SV_Config + vehicle hash table
    'locales/locale.lua',
    'locales/en.lua',
    'locales/nl.lua',
    'locales/zh-hk.lua',
}

client_scripts {
    '@PolyZone/client.lua',
    '@PolyZone/CircleZone.lua',
    '@PolyZone/ComboZone.lua',
    'core/framework/client.lua',
    'core/functions/client.lua',
    'core/target/client.lua',
    'garage/preview.lua',
    'garage/client.lua',
    'garage/mechanic.lua',
    'garage/impound.lua',
    'parking/client.lua',
    'garage/admincar_client.lua',   -- /car override: collision-gated admin spawn
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'core/framework/server.lua',
    'core/database.lua',
    'core/functions/server.lua',
    'garage/mechanic.lua',
    'garage/impound.lua',
    'garage/server.lua',
    'parking/server.lua',
    'parking/commands.lua',
    'garage/admincar_server.lua',   -- /car override: re-registers command (loads after qb-core)
}

files {
    'html/index.html',
    'html/script.js',
    'html/style.css',
    'html/logo.png',
}
