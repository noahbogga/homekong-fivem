local currentWeather = "CLEAR"
local currentWind    = 0.0

-- request current weather when this resource starts
AddEventHandler("onClientResourceStart", function(resourceName)
    if resourceName == GetCurrentResourceName() then
        TriggerServerEvent("hk-weathersystem:requestCurrent")
    end
end)

RegisterNetEvent("hk-weathersystem:sync")
AddEventHandler("hk-weathersystem:sync", function(weather, windKmh, transition)
    currentWeather = weather
    currentWind    = math.min((windKmh or 0) / 10.0, 12.0)

    -- force override any existing weather lock
    ClearOverrideWeather()
    ClearWeatherTypePersist()

    SetWeatherTypeNowPersist(currentWeather)
    SetWeatherTypeNow(currentWeather)
    SetWeatherTypePersist(currentWeather)
    SetWeatherTypeOvertimePersist(currentWeather, transition or 45.0)

    SetWindSpeed(currentWind)
    SetWindDirection(0.0)
end)

-- re-apply every second to fight the engine overriding it
Citizen.CreateThread(function()
    while true do
        Citizen.Wait(1000)
        if currentWeather ~= "CLEAR" then
            SetWeatherTypePersist(currentWeather)
            SetWindSpeed(currentWind)
        end
    end
end)
