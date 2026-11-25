Config = Config or {}

Config.UseTarget = GetConvar('UseTarget', 'false') == 'true'

Config.Zones = {
    ["SandyOccasions"] = {
        BusinessName = "大昌行易手車",
        SellVehicle = vector4(815.09, -824.67, 25.83, 91.27),
        BuyVehicle = vector4(814.5, -820.82, 25.83, 92.41),

        PolyZone = {
            vector2(893.9, -684.11),
            vector2(714.46, -674.0),
            vector2(712.21, -863.08),
            vector2(934.56, -909.91),
        },
        MinZ = 20.0,
        MaxZ = 96.0,

        VehicleSpots = {
            vector4(804.4, -811.57, 25.74, 177.5),
            vector4(800.65, -811.49, 25.73, 178.6),
            vector4(796.43, -811.73, 25.75, 182.76),
            vector4(797.21, -825.42, 25.76, 23.45),
        }
    }
}