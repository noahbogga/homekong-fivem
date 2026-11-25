fx_version 'cerulean'
game 'gta5'

name 'hk-wheel'
description 'HOMEKONG steering-wheel bridge — feeds a local DirectInput companion app into the hk-handling sim (steering override + FFB telemetry). No injection; localhost WebSocket via NUI.'
author 'HOMEKONG'
version '0.1.0'

-- Runs alongside hk-handling / hk-vehlib but NEVER edits them. Pure consumer:
-- reads their exports + telemetry, owns only steering + wheel input state.
dependency 'hk-vehlib'

client_scripts {
    'config.lua',
    'client/bridge.lua',     -- NUI <-> Lua WebSocket bridge (transport)
    'client/steer.lua',      -- steering-angle override + soft lock (the physics side)
    'client/buttons.lua',    -- button-box action map (engine/hybrid/seatbelt/nos/neutral/lights)
    'client/main.lua',       -- glue: feed wheel state into the sim each frame, publish telemetry
}

ui_page 'nui/index.html'

files {
    'nui/index.html',
    'nui/bridge.js',
}
