-- Merged locale for all-in-one hk-parking (English fallback).
local Translations = {
    -- ── Garage ─────────────────────────────────────────────────────────────
    error = {
        no_vehicles = 'There are no vehicles in this location!',
        not_depot = 'Your vehicle is not in depot',
        not_impound = 'Your vehicle is not in impound',
        not_owned = "This vehicle can't be stored",
        not_correct_type = "You can't store this type of vehicle here",
        not_enough = 'Not enough money',
        no_garage = 'None',
        vehicle_occupied = "You can't store this vehicle as it is not empty",
        vehicle_not_tracked = 'Could not track vehicle',
        no_spawn = 'Area too crowded',
    },
    success = {
        vehicle_parked = 'Vehicle Stored',
        vehicle_taken = 'Vehicle Retrieved Successfully',
        vehicle_tracked = 'Vehicle Tracked',
    },
    menu = {
        header = {
            house_car = 'House Garage %{value}', public_car = 'Public Garage %{value}',
            public_sea = 'Public Boathouse %{value}', public_air = 'Public Hangar %{value}',
            job_car = 'Job Garage %{value}', job_sea = 'Job Boathouse %{value}',
            job_air = 'Job Hangar %{value}', gang_car = 'Gang Garage %{value}',
            gang_sea = 'Gang Boathouse %{value}', gang_air = 'Gang Hangar %{value}',
            depot_car = 'Vehicle Depot %{value}', depot_sea = 'Boat Depot %{value}',
            depot_air = 'Air Depot %{value}', vehicles = 'Available Vehicles',
            depot = '%{value} [ $%{value2} ]', garage = '%{value} [ %{value2} ]',
        },
        leave = { car = '⬅ Leave Garage', sea = '⬅ Leave Boathouse', air = '⬅ Leave Hangar' },
        text = {
            vehicles = 'View stored vehicles!',
            depot = 'Plate: %{value}<br>Fuel: %{value2} | Engine: %{value3} | Body: %{value4}',
            garage = 'Status: %{value}<br>Fuel: %{value2} | Engine: %{value3} | Body: %{value4}',
        }
    },
    status = {
        out = 'Out', garaged = 'Garaged', impound = 'Impounded By Police',
        house = 'House', parked = 'Parked On Street',
    },
    info = {
        car_e = 'E - Garage', sea_e = 'E - Boathouse', air_e = 'E - Hangar',
        rig_e = 'E - Rig Lot', depot_e = 'E - Depot', park_e = 'E - Park',
        house_garage = 'E - House Garage', house = 'House',
        not_the_owner = "You are not the owner of this vehicle.",
        not_a_vip = "You are not a VIP member.",
        wheel_clamp = "Wheel clamp", wheel_clamp_add = "Place wheel clamp",
        no_cops = "No police on duty.",
        wheel_clamp_added = "Vehicle clamped! Fine: $%{fine}",
        wheel_clamp_deleted = "Wheel clamp removed.",
        street = "Street: %{street}", fuel = "Fuel: %{fuel}",
        engine = "Engine: %{engine}", body = "Body: %{body}",
        click_to_set_waypoint = "Click to set a GPS waypoint",
        no_waipoint = "You're only %{distance}m away, you don't need a waypoint.",
        no_vehicles_parked = "You have no vehicles parked on the street.",
        max_parked = "You have reached your street-parking limit.",
    },
    vehicle = {
        info = "Vehicle Information", body_damage = "Body Damage",
        engine_damage = "Engine Health", fuel_level = "Fuel Level",
        oil_level = "Oil Level", engine_temp = "Engine Temp",
        parked = "Vehicle parked.", unparked = "Vehicle unparked.",
    },
    blip = { label = "Parked: %{model} (%{plate})" }
}

if GetConvar('qb_locale', 'en') == 'en' then
    Lang = Locale:new({
        phrases = Translations,
        warnOnMissing = true,
        fallbackLang = Lang,
    })
end
