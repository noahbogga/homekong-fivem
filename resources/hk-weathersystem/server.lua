local FETCH_INTERVAL    = 10 * 60 * 1000   -- re-fetch HKO every 10 min
local CYCLE_TIME        =  4 * 60 * 1000   -- cycle to next icon every 4 min

-- when only light rain (HKO icon 61) is active with no heavier conditions,
-- this is the probability the queue escalates to a darker sequence
local DARK_RAIN_CHANCE        = 0.70   -- 70 % chance to go dark on light rain
local DARK_RAIN_THUNDER_CHANCE = 0.40  -- of those, 40 % chance to also include THUNDER

local HKO = {
    [50] = "EXTRASUNNY",
    [51] = "CLEAR",
    [52] = "CLOUDS",
    [53] = "CLOUDS",
    [54] = "OVERCAST",
    [60] = "FOGGY",
    [61] = "RAIN",
    [62] = "RAIN",
    [63] = "RAIN",
    [64] = "THUNDER",
    [65] = "THUNDER",
    [70] = "SNOWLIGHT",
    [71] = "SNOW",
    [72] = "BLIZZARD",
}

-- When HKO only has icon 61 (light rain / no heavier conditions), escalate the
-- weather queue toward darker GTA states so the city feels threatening, not just drizzly.
local function applyDarkRainBias(queue, rawIcons)
    local hasLight, hasHeavy = false, false
    for _, icon in ipairs(rawIcons) do
        if     icon == 61                              then hasLight = true
        elseif icon == 62 or icon == 63
            or icon == 64 or icon == 65                then hasHeavy = true end
    end
    -- only escalate when there is light rain and nothing heavier
    if not (hasLight and not hasHeavy) then return queue end
    if math.random() >= DARK_RAIN_CHANCE            then return queue end

    -- build: OVERCAST → existing entries → (maybe THUNDER)
    local out, seen = {}, {}
    local function add(w)
        if not seen[w] then seen[w] = true; out[#out + 1] = w end
    end
    add("OVERCAST")
    for _, w in ipairs(queue) do add(w) end
    if math.random() < DARK_RAIN_THUNDER_CHANCE then add("THUNDER") end

    print(("[hk-weathersystem] dark-rain bias applied → %s"):format(table.concat(out, " → ")))
    return out
end

local weatherQueue = {}   -- deduplicated GTA weather list from current HKO icons
local currentWind  = 0
local cycleIndex   = 1

local function pushWeather(target, transition)
    if #weatherQueue == 0 then return end
    local weather = weatherQueue[cycleIndex]
    TriggerClientEvent("hk-weathersystem:sync", target, weather, currentWind, transition or 45.0)
    print(("[hk-weathersystem] → %s  (%d/%d icons)  wind %.1f km/h"):format(weather, cycleIndex, #weatherQueue, currentWind))
end

local function fetch()
    PerformHttpRequest(
        "https://data.weather.gov.hk/weatherAPI/opendata/weather.php?dataType=rhrread&lang=en",
        function(code, body)
            if code ~= 200 then
                print("[hk-weathersystem] fetch failed: " .. code)
                return
            end

            local data = json.decode(body)
            if not data or not data.icon then
                print("[hk-weathersystem] unexpected response format")
                return
            end

            -- build deduplicated weather queue from all returned icons
            local seen, queue = {}, {}
            for _, icon in ipairs(data.icon) do
                local w = HKO[icon]
                if w and not seen[w] then
                    seen[w] = true
                    queue[#queue + 1] = w
                end
            end
            if #queue == 0 then queue = { "CLEAR" } end

            queue = applyDarkRainBias(queue, data.icon)

            -- wind: grab first station with data
            local wind = 0
            if data.WindSpeed and data.WindSpeed.data then
                for _, s in ipairs(data.WindSpeed.data) do
                    if s.windSpeed then
                        wind = tonumber(s.windSpeed) or 0
                        break
                    end
                end
            end

            weatherQueue = queue
            currentWind  = wind
            cycleIndex   = 1

            pushWeather(-1, 45.0)
        end,
    "GET")
end

-- fetch thread
Citizen.CreateThread(function()
    while true do
        fetch()
        Citizen.Wait(FETCH_INTERVAL)
    end
end)

-- cycle thread — only active when HKO returns multiple conditions
Citizen.CreateThread(function()
    while true do
        Citizen.Wait(CYCLE_TIME)
        if #weatherQueue > 1 then
            cycleIndex = (cycleIndex % #weatherQueue) + 1
            pushWeather(-1, 60.0)  -- slower transition for mid-cycle changes
        end
    end
end)

-- send current weather to players as they connect
RegisterNetEvent("hk-weathersystem:requestCurrent")
AddEventHandler("hk-weathersystem:requestCurrent", function()
    pushWeather(source, 10.0)  -- fast sync on join
end)
