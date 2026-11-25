Config = {}

-- Upload settings (Zipline v4)
Config.UploadURL = 'https://images.example.com/api/upload'
Config.UploadToken = '' -- your Zipline v4 upload token
Config.UploadFolder = '' -- optional Zipline folder ID -- Zipline folder ID ('fivem')
Config.PublicBaseURL = 'https://images.example.com' -- Public URL prefix (replaces internal zipline URL in responses)

-- Permissions
Config.AdminOnly = true -- Set false to allow all players photo mode
Config.AdminGroups = { 'admin', 'god' } -- QBCore permission groups

-- Studio mode (transparent/crop captures)
Config.Studio = {
    -- TP coordinates (high in sky void)
    coords = vector3(0.0, 0.0, 1500.0),
    -- Green screen color (RGB 0-255)
    greenScreen = { r = 0, g = 177, b = 64 },
    -- Camera presets for studio
    presets = {
        { name = 'Front',       angle = 0.0,   pitch = 0.0,   distance = 6.0 },
        { name = 'Front-High',  angle = 0.0,   pitch = -15.0, distance = 7.0 },
        { name = '3/4 Front',   angle = 35.0,  pitch = -10.0, distance = 6.5 },
        { name = 'Side',        angle = 90.0,  pitch = 0.0,   distance = 6.0 },
        { name = 'Rear',        angle = 180.0, pitch = -5.0,  distance = 6.5 },
        { name = '3/4 Rear',    angle = 215.0, pitch = -10.0, distance = 6.5 },
        { name = 'Top-Down',    angle = 0.0,   pitch = -89.0, distance = 10.0 },
        { name = 'Low-Front',   angle = 10.0,  pitch = 10.0,  distance = 5.0 },
    },
}

-- Photo mode (in-world captures)
Config.Photo = {
    presets = {
        { name = 'Landscape',  fov = 50.0 },
        { name = 'Portrait',   fov = 35.0 },
        { name = 'Wide',       fov = 75.0 },
        { name = 'Close-up',   fov = 20.0 },
    },
    -- Allow free cam in photo mode
    freeCam = true,
    maxDistance = 20.0, -- max free cam distance from player
}

-- Screenshot settings
Config.Screenshot = {
    quality = 0.95,
    format = 'png', -- png for studio (transparency), jpg for photo
}
