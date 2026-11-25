fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'hk-scenario'
author 'HOMEKONG'
description 'In-game scenario builder: area cleaner + AI path blockers + placeable props with qb-target/callout hooks. Successor to hk-cleararea.'
version '2.4.76'

-- Ambient population budget (merged from hk-population v2.0.0).
-- Native GAME_MAIN gameconfig override: raises engine population caps &
-- densities (see data/gameconfig.xml). hk-population is now retired.
data_file 'GAME_MAIN' 'data/gameconfig.xml'

-- Traffic realism (NO HESI / Wangan): AI handling profile override — flattens the
-- engine's steering-angle -> max-speed curve so ambient NPCs holding their lane
-- aren't clamped to ~126 km/h (see data/ai_handling.meta). Boot-time; applies on
-- reconnect. Paired with the live behaviour loop + highway spawner in traffic.lua.
--
-- CRITICAL (fixed v2.4.28): this is a CAIHandlingInfoMgr file and MUST be mounted
-- with the AI-handling mounter, NOT 'HANDLING_FILE' (that mounter is for regular
-- CHandlingData / handling.meta, so the file SILENTLY NEVER LOADED — the stock
-- 126 km/h AI curve was in force the whole time). 'FIVEM_LOVES_YOU_447B37BE29496FA0'
-- is the undocumented CExtraContentFileMounter the CFX community confirmed loads
-- vehicleaihandlinginfo.meta; it also requires the file listed in files{} below.
files {
    'data/ai_handling.meta',
}
data_file 'FIVEM_LOVES_YOU_447B37BE29496FA0' 'data/ai_handling.meta'

shared_scripts {
    '@ox_lib/init.lua',
    -- qb-core shared vehicle registry: gives us QBShared.Vehicles so the traffic
    -- spawner can source its addon roster LIVE from the shop list (auto-follows
    -- the pack; self-inits QBShared, safe to load standalone). See client/traffic.
    '@qb-core/shared/vehicles.lua',
    'shared/config.lua',
    'shared/props_catalog.lua',
}

client_scripts {
    '@menuv/menuv.lua',
    'client/main.lua',
    'client/props.lua',
    'client/population.lua',
    'client/traffic.lua',
    'client/editor.lua',
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/allowlist.lua',
    'server/main.lua',
    'server/props.lua',
    'server/population.lua',
    'server/traffic.lua',
}

dependencies {
    'ox_lib',
    'oxmysql',
    'menuv',
    'qb-core',
}

-- qb-target is a soft/optional integration (checked at runtime with
-- GetResourceState), so it is intentionally NOT a hard dependency.
