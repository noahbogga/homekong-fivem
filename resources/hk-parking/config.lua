Config = {}
Config.AutoRespawn = false          -- false == doesn't modify car states on restart (your old setting)
Config.VisuallyDamageCars = true   -- true == damage car on spawn | false == no damage on spawn
Config.SharedGarages = false       -- false == only take car from garage stored in (your old setting)
Config.ClassSystem = false         -- true == restrict vehicles by class | false == any vehicle class in any garage
Config.FuelResource = 'qb-fuel' -- supports any that has a GetFuel() and SetFuel() export
Config.Warp = true                 -- true == warp player into vehicle | false == vehicle spawns without warping

-- HK-Garage live 3D preview (turntable). The car is spawned as a LOCAL,
-- non-networked entity at a hidden high-altitude pad, so other players never
-- see it and nothing is written to the database.
Config.Preview = {
    enabled   = true,
    debug     = true,  -- TEMP: prints tier classification result to F8 console
    -- Camera pulled well back + near eye-level so the WHOLE vehicle is framed
    -- side-on (not staring down at the roof).
    camDist   = 4.97,  -- base camera distance (-8% from 5.4)
    camHeight = 0.9,   -- camera height above the vehicle base (low = see the side)
    camPitch  = -3.0,  -- almost level; slight downward tilt only
    camFov    = 40.0,  -- field of view
    sizePad   = 1.32,  -- distance multiplier based on the model's longest dimension (-8%)
    lateralShift = 0.020, -- push the car slightly left in frame
    autoSpin  = 14.0,  -- auto-rotation speed (deg/sec); 0 disables auto-spin
    allowDrag = true,  -- click-drag to rotate (in addition to auto-spin)
    dragSpeed = 0.5,
}

-- ── HOMEKONG impound / depot system ──────────────────────────────────────
-- Two independent pools, distinguished by player_vehicles.state:
--   state 2 = POLICE IMPOUND  (retrieved via NPC officer, in-game hours below)
--   state 4 = MECHANIC DEPOT  (mechanic-towed + wrecked cars)
-- Each pool has TWO locations that SHARE the pool (retrieve from either).
Config.Impound = {
    -- Mechanic depot: mechanic drops a towed car in the green ring (E, tow truck
    -- required); owner retrieves at the takeVehicle point (E).
    depots = {
        {   -- Depot B (Paleto Bay)
            label = '維修廠扣車場 A · Mechanic Depot A',
            drop = vector3(-414.8, -2179.05, 10.32),   -- mechanic drop-off ring
            take = vector3(105.22, 6613.65, 32.4),  -- owner pickup
            spawn = vector4(125.03, 6605.84, 31.32, 227.42),
            blip = true,
        },
        {   -- Depot B (Paleto Bay)
            label = '維修廠扣車場 B · Mechanic Depot B',
            drop = vector3(-275.09, -889.31, 31.08),    -- mechanic drop-off ring
            take = vector3(-280.92, -888.09, 31.32),      -- owner pickup
            spawn = vector4(-280.27, -904.22, 30.51, 339.95),
            blip = true,
        },
    },
    dropRadius = 5.0,     -- green ring radius for mechanic drop-off
    towTruckModels = { flatbed = true, flatbed3 = true, towtruck = true, towtruck2 = true, towtruck3 = true, towtruck4 = true, slamtruck = true, towrod = true },

    -- Police impound: qb-target an NPC officer, only during the window below.
    police = {
        {   -- Impound A (city center)
            label = '警察扣車場 A · Police Impound A',
            npc = vector4(474.01, -1019.42, 28.07, 203.57),
            spawn = vector4(479.81, -1019.88, 27.39, 271.67),
            blip = true,
        },
        {   -- Impound B (Sandy)
            label = '警察扣車場 B · Police Impound B',
            npc = vector4(1914.87, 3677.84, 32.87, 120.29),
            spawn = vector4(1902.93, 3676.63, 32.35, 207.78),
            blip = true,
        },
    },
    policeNpcModel = 's_f_y_cop_01',  -- female officer ped
    policeHoursStart = 8,             -- 08:00 in-game (GetClockHours world time)
    policeHoursEnd   = 11,            -- 11:00 in-game
}

-- https://docs.fivem.net/natives/?_0x29439776AAA00A62
Config.VehicleClass = {
    all = { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22 },
    car = { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 12, 13, 18, 22 },
    air = { 15, 16 },
    sea = { 14 },
    rig = { 10, 11, 17, 19, 20 }
}

Config.Garages = {
    motelgarage = {
        label = '國務院公用停車場 · Government Public Parking',
        takeVehicle = vector3(216.27, -356.89, 43.82),
        spawnPoint = {
            vector4(238.95, -347.07, 43.97, 339.26)
        },
        showBlip = true,
        blipName = '國務院公用停車場',
        blipNumber = 267,
        blipColor = 29,
        type = 'public',
        category = Config.VehicleClass['car']
    },
    sapcounsel = {
        label = 'San Andreas Parking',
        takeVehicle = vector3(-336.31, -774.93, 33.96),
        spawnPoint = {
            vector4(-334.44, -780.75, 33.96, 137.5)
        },
        showBlip = true,
        blipName = '公共停車場',
        blipNumber = 267,
        blipColor = 29,
        type = 'public',
        category = Config.VehicleClass['car']
    },
    spanishave = {
        label = 'Spanish Ave Parking',
        takeVehicle = vector3(-1147.58, -738.11, 19.31),
        spawnPoint = {
            vector4(-1163.88, -749.32, 18.42, 35.5)
        },
        showBlip = true,
        blipName = '公共停車場',
        blipNumber = 267,
        blipColor = 29,
        type = 'public',
        category = Config.VehicleClass['car']
    },
    caears24 = {
        label = 'Caears 24 Parking',
        takeVehicle = vector3(65.43, 21.19, 69.47),
        spawnPoint = {
            vector4(73.21, 10.72, 68.83, 163.5)
        },
        showBlip = true,
        blipName = '公共停車場',
        blipNumber = 267,
        blipColor = 29,
        type = 'public',
        category = Config.VehicleClass['car']
    },
    caears242 = {
        label = 'Caears 24 Parking',
        takeVehicle = vector3(-453.6, -817.08, 30.61),
        spawnPoint = {
            vector4(-472.03, -815.47, 30.5, 177.5)
        },
        showBlip = true,
        blipName = '公共停車場',
        blipNumber = 267,
        blipColor = 29,
        type = 'public',
        category = Config.VehicleClass['car']
    },
    lagunapi = {
        label = 'Laguna Parking',
        takeVehicle = vector3(363.04, 283.51, 103.38),
        spawnPoint = {
            vector4(367.49, 297.71, 103.43, 340.5)
        },
        showBlip = true,
        blipName = '公共停車場',
        blipNumber = 267,
        blipColor = 29,
        type = 'public',
        category = Config.VehicleClass['car']
    },
    airportp = {
        label = 'Airport Parking',
        takeVehicle = vector3(-804.84, -2023.21, 9.16),
        spawnPoint = {
            vector4(-800.41, -2016.53, 9.32, 48.5)
        },
        showBlip = true,
        blipName = '公共停車場',
        blipNumber = 267,
        blipColor = 29,
        type = 'public',
        category = Config.VehicleClass['car']
    },
    themotorhotel = {
        label = 'The Motor Hotel Parking',
        takeVehicle = vector3(1057.75, 2658.84, 38.94),
        spawnPoint = {
            vector4(1064.88, 2670.91, 38.93, 89.15)
        },
        showBlip = true,
        blipName = '公共停車場',
        blipNumber = 267,
        blipColor = 29,
        type = 'public',
        category = Config.VehicleClass['car']
    },
    liqourparking = {
        label = 'Liqour Parking',
        takeVehicle = vector3(1737.13, 3718.91, 34.04),
        spawnPoint = {
            vector4(1730.31, 3711.07, 34.2, 20.5)
        },
        showBlip = true,
        blipName = '公共停車場',
        blipNumber = 267,
        blipColor = 29,
        type = 'public',
        category = Config.VehicleClass['car']
    },
    shoreparking = {
        label = 'Shore Parking',
        takeVehicle = vector3(1699.41, 4802.66, 41.81),
        spawnPoint = {
            vector4(1691.32, 4788.08, 41.3, 89.46)
        },
        showBlip = true,
        blipName = '公共停車場',
        blipNumber = 267,
        blipColor = 29,
        type = 'public',
        category = Config.VehicleClass['car']
    },
    haanparking = {
        label = 'Bell Farms Parking',
        takeVehicle = vector3(85.3, 6427.52, 31.33),
        spawnPoint = {
            vector4(70.71, 6425.16, 30.92, 68.5)
        },
        showBlip = true,
        blipName = '公共停車場',
        blipNumber = 267,
        blipColor = 29,
        type = 'public',
        category = Config.VehicleClass['car']
    },
    dumbogarage = {
        label = 'Dumbo Private Parking',
        takeVehicle = vector3(165.32, -3230.00, 5.93),
        spawnPoint = {
            vector4(165.32, -3236.10, 5.93, 268.5)
        },
        showBlip = true,
        blipName = '公共停車場',
        blipNumber = 267,
        blipColor = 29,
        type = 'public',
        category = Config.VehicleClass['car']
    },
    pillboxgarage = {
        label = '有錢佬停車場 · Rich Folks Parking',
        takeVehicle = vector3(-1330.45, -19.91, 50.59),
        spawnPoint = {
            vector4(-1363.8, 11.05, 52.61, 241.98)
        },
        showBlip = true,
        blipName = '公共停車場',
        blipNumber = 267,
        blipColor = 29,
        type = 'public',
        category = Config.VehicleClass['car']
    },
    grapeseedgarage = {
        label = 'Grapeseed Parking',
        takeVehicle = vector3(2552.68, 4671.8, 33.95),
        spawnPoint = {
            vector4(2550.17, 4681.96, 33.81, 17.05)
        },
        showBlip = true,
        blipName = '公共停車場',
        blipNumber = 357,
        blipColor = 3,
        type = 'public',
        category = Config.VehicleClass['car']
    },
    impoundlot = {
        label = '車輛扣留中心 · Vehicle Impound Center',
        takeVehicle = vector3(-421.73, -2170.99, 11.34),
        spawnPoint = {
            vector4(-439.84, -2178.65, 9.7, 0.94)
        },
        showBlip = true,
        blipName = '車輛扣留中心',
        blipNumber = 68,
        blipColor = 3,
        type = 'depot',
        category = Config.VehicleClass['car']
    },
    police = {
        label = '警用停車場 · Police Parking',
        takeVehicle = vector3(452.12, -988.54, 25.7),
        spawnPoint = {
            vector4(431.17, -990.76, 25.7, 178.64)
        },
        showBlip = false,
        blipName = 'Police',
        blipNumber = 267,
        blipColor = 3,
        type = 'job',
        category = Config.VehicleClass['car'],
        job = 'police',
        jobType = 'leo'
    },
    police2 = {
        label = '警用停車場 · Police Parking',
        takeVehicle = vector3(1826.24, 3694.0, 33.97),
        spawnPoint = {
            vector4(1815.13, 3687.63, 33.97, 295.44)
        },
        showBlip = false,
        blipName = 'Police',
        blipNumber = 267,
        blipColor = 3,
        type = 'job',
        category = Config.VehicleClass['car'],
        job = 'police',
        jobType = 'leo'
    },
    ambulance = {
        label = '救護停車場 · Ambulance Parking',
        takeVehicle = vector3(-837.51, -1227.95, 6.93),
        spawnPoint = {
            vector4(-842.47, -1233.67, 6.93, 6.52)
        },
        showBlip = false,
        blipName = 'Ambulance',
        blipNumber = 267,
        blipColor = 3,
        type = 'job',
        category = Config.VehicleClass['car'],
        job = 'ambulance',
        jobType = 'ambulance'
    },
    ambulance2 = {
        label = '救護停車場 · Ambulance Parking',
        takeVehicle = vector3(1814.14, 3652.26, 34.22),
        spawnPoint = {
            vector4(1815.07, 3654.39, 34.22, 196.99)
        },
        showBlip = false,
        blipName = 'Ambulance',
        blipNumber = 267,
        blipColor = 3,
        type = 'job',
        category = Config.VehicleClass['car'],
        job = 'ambulance',
        jobType = 'ambulance'
    },
    intairport = {
        label = 'Airport Hangar',
        takeVehicle = vector3(-1003.38, -3008.87, 13.95),
        spawnPoint = {
            vector4(-979.2, -2995.51, 13.95, 52.19)
        },
        showBlip = false,
        blipName = '機庫',
        blipNumber = 360,
        blipColor = 3,
        type = 'public',
        category = Config.VehicleClass['air']
    },
    higginsheli = {
        label = 'Higgins Helitours',
        takeVehicle = vector3(-724.65, -1444.08, 5.0),
        spawnPoint = {
            vector4(-745.34, -1468.67, 5.0, 320.15)
        },
        showBlip = false,
        blipName = '機庫',
        blipNumber = 360,
        blipColor = 3,
        type = 'public',
        category = Config.VehicleClass['air']
    },
    airsshores = {
        label = 'Sandy Shores Hangar',
        takeVehicle = vector3(1740.4, 3283.92, 41.1),
        spawnPoint = {
            vector4(1740.98, 3279.08, 41.75, 106.77)
        },
        showBlip = false,
        blipName = '機庫',
        blipNumber = 360,
        blipColor = 3,
        type = 'public',
        category = Config.VehicleClass['air']
    },
    airzancudo = {
        label = 'Fort Zancudo Hangar',
        takeVehicle = vector3(-1828.25, 2975.44, 32.81),
        spawnPoint = {
            vector4(-1828.25, 2975.44, 32.81, 57.24)
        },
        showBlip = true,
        blipName = '機庫',
        blipNumber = 360,
        blipColor = 3,
        type = 'public',
        category = Config.VehicleClass['air']
    },
    airdepot = {
        label = 'Air Depot',
        takeVehicle = vector3(-1243.29, -3392.3, 13.94),
        spawnPoint = {
            vector4(-1269.67, -3377.74, 13.94, 327.88)
        },
        showBlip = false,
        blipName = 'Air Depot',
        blipNumber = 359,
        blipColor = 3,
        type = 'depot',
        category = Config.VehicleClass['air']
    },
    lsymc = {
        label = '香港遊艇會 · Hong Kong Yacht Club',
        takeVehicle = vector3(-793.58, -1501.4, 0.12),
        spawnPoint = {
            vector4(-793.58, -1501.4, 0.12, 111.5)
        },
        showBlip = true,
        blipName = '船屋',
        blipNumber = 356,
        blipColor = 3,
        type = 'public',
        category = Config.VehicleClass['sea']
    },
    paleto = {
        label = '北區船屋 · North Boathouse',
        takeVehicle = vector3(-289.2, 6637.96, 1.01),
        spawnPoint = {
            vector4(-289.2, 6637.96, 1.01, 45.5)
        },
        showBlip = true,
        blipName = '船屋',
        blipNumber = 356,
        blipColor = 3,
        type = 'public',
        category = Config.VehicleClass['sea']
    },
    millars = {
        label = '米蘭船屋 · Millars Boathouse',
        takeVehicle = vector3(1297.82, 4209.61, 30.12),
        spawnPoint = {
            vector4(1297.82, 4209.61, 30.12, 253.5)
        },
        showBlip = true,
        blipName = '船屋',
        blipNumber = 356,
        blipColor = 3,
        type = 'public',
        category = Config.VehicleClass['sea']
    },
    seadepot = {
        label = '船隻扣留中心 · Boat Impound Center',
        takeVehicle = vector3(-772.98, -1430.76, 1.59),
        spawnPoint = {
            vector4(-729.77, -1355.49, 1.19, 142.5)
        },
        showBlip = true,
        blipName = '船隻扣留中心',
        blipNumber = 356,
        blipColor = 3,
        type = 'depot',
        category = Config.VehicleClass['sea']
    },
    rigdepot = {
        label = '大貨車車場 · Truck Depot',
        takeVehicle = vector3(2334.42, 3118.62, 48.2),
        spawnPoint = {
            vector4(2324.57, 3117.79, 48.21, 4.05)
        },
        showBlip = true,
        blipName = '大貨車車場',
        blipNumber = 68,
        blipColor = 2,
        type = 'depot',
        category = Config.VehicleClass['rig']
    },
    dumborigparking = {
        label = 'Dumbo 大貨車停車場 · Dumbo Truck Parking',
        takeVehicle = vector3(161.23, -3188.73, 5.97),
        spawnPoint = {
            vector4(167.0, -3203.89, 5.94, 271.27)
        },
        showBlip = true,
        blipName = '大貨車停車場',
        blipNumber = 357,
        blipColor = 2,
        type = 'public',
        category = Config.VehicleClass['rig']
    },
    popsrigparking = {
        label = 'Pop 大貨車停車場 · Pops Truck Parking',
        takeVehicle = vector3(137.67, 6632.99, 31.67),
        spawnPoint = {
            vector4(127.69, 6605.84, 31.93, 223.67)
        },
        showBlip = true,
        blipName = '大貨車停車場',
        blipNumber = 357,
        blipColor = 2,
        type = 'public',
        category = Config.VehicleClass['rig']
    },
    ronsrigparking = {
        label = 'Ron 大貨車停車場 · Rons Truck Parking',
        takeVehicle = vector3(-2529.37, 2342.67, 33.06),
        spawnPoint = {
            vector4(-2521.61, 2326.45, 33.13, 88.7)
        },
        showBlip = true,
        blipName = '大貨車停車場',
        blipNumber = 357,
        blipColor = 2,
        type = 'public',
        category = Config.VehicleClass['rig']
    },
    ronsrigparking2 = {
        label = 'Ron 大貨車停車場 · Rons Truck Parking',
        takeVehicle = vector3(2561.67, 476.68, 108.49),
        spawnPoint = {
            vector4(2561.67, 476.68, 108.49, 177.86)
        },
        showBlip = true,
        blipName = '大貨車停車場',
        blipNumber = 357,
        blipColor = 2,
        type = 'public',
        category = Config.VehicleClass['rig']
    },
    ronsrigparking3 = {
        label = 'Ron 大貨車停車場 · Rons Truck Parking',
        takeVehicle = vector3(-41.24, -2550.63, 6.01),
        spawnPoint = {
            vector4(-39.39, -2527.81, 6.08, 326.18)
        },
        showBlip = true,
        blipName = '大貨車停車場',
        blipNumber = 357,
        blipColor = 2,
        type = 'public',
        category = Config.VehicleClass['rig']
    },
    logistics = {
        label = '貨運停車場 · Logistics Parking',
        takeVehicle = vector3(1189.99, -3293.85, 5.5),
        spawnPoint = {
            vector4(1190.12, -3318.5, 5.28, 180.03)
        },
        showBlip = false,
        blipName = 'logistics',
        blipNumber = 267,
        blipColor = 29,
        type = 'job',
        category = Config.VehicleClass['car'],
        job = 'logistics',
        jobType = 'logistics'
    },
    servant = {
        label = '軍情局停車場 · Intelligence Bureau Parking',
        takeVehicle = vector3(2562.58, -319.5, 92.57),
        spawnPoint = {
            vector4(2577.96, -304.25, 92.57, 269.45)
        },
        showBlip = false,
        blipName = '軍情局',
        blipNumber = 267,
        blipColor = 29,
        type = 'job',
        category = Config.VehicleClass['car'],
        job = 'servant',
        jobType = 'servant'
    },
}

Config.HouseGarages = {}