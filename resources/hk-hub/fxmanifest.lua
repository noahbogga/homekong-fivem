fx_version 'cerulean'
game 'gta5'

author 'HOMEKONG'
description 'HK Hub — branded launcher that redirects to server systems (F5)'
version '1.0.0'

shared_scripts {
    'config.lua'
}

client_scripts {
    'client/main.lua',
    'client/squad.lua'
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/main.lua',
    'server/squad.lua'
}

-- qb-core: required for the Settings identity callback.
-- hk-optimizer: OPTIONAL soft dep (guarded at runtime) — the performance-mode
-- picker just hides itself if hk-optimizer isn't started.
-- screenshot-basic: OPTIONAL soft dep (guarded) — bug-report screenshots need it;
-- if it isn't started, reports still send as text + diagnostics only.
-- ps-dispatch: OPTIONAL soft dep (guarded) — the Dispatch tile hides if absent.
-- pma-voice: OPTIONAL soft dep (guarded) — the Squad radio just hides/no-ops if
--   pma-voice isn't started; everything else in Squad still works.
-- SQL: import sql/hk_squad.sql once for the Squad system's persistence tables.
dependencies {
    'qb-core',
    'oxmysql'
}

ui_page 'html/index.html'

files {
    'html/index.html',
    'html/style.css',
    'html/app.js',
    'html/squad.js',
    'html/laws.json',
    'html/atlas1.webp'
}

lua54 'yes'
