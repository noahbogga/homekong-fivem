fx_version 'cerulean'
game 'gta5'

name 'hk-vehlib'
description 'HOMEKONG Vehicle Library — shared utility layer for vehicle enhancement scripts'
author 'HOMEKONG'
version '0.1.0'

dependency 'ox_lib'

shared_scripts {
    '@ox_lib/init.lua',   -- provides the `lib` global (lib.notify -> top-right toast)
}

client_scripts {
    'config.lua',
    'client/state.lua',
    'client/handling.lua',
    -- 'client/input.lua',   -- REMOVED from load: all 5 exports unused by any resource (dead). File kept on disk.
    'client/forces.lua',
    'client/wheels.lua',
    'client/drivetrain.lua',
    'client/compat.lua',
    'client/api.lua',
}

-- Exports available to other resources (hk-racecam, hk-vehdynamic, etc.)
-- Usage: exports['hk-vehlib']:functionName(args)
