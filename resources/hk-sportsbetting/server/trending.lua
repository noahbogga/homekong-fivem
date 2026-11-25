local trendingCache = {}
local lastFetchTime = 0

local function fetchTrendingMatches()
    local key = ServerConfig.BraveAPIKey
    if not key or key == "" then return end

    local now = os.time()
    local cacheSeconds = (Config.TrendingCacheHours or 6) * 3600
    if (now - lastFetchTime) < cacheSeconds and #trendingCache > 0 then return end

    local query = "top sports matches today betting odds"
    local url = "https://api.search.brave.com/res/v1/web/search?q=" .. query .. "&count=5&freshness=pd"

    PerformHttpRequest(url, function(status, body, headers)
        if status ~= 200 or not body then return end
        local ok, data = pcall(json.decode, body)
        if not ok or not data or not data.web or not data.web.results then return end

        local results = {}
        for i, r in ipairs(data.web.results) do
            if i > 3 then break end
            results[#results + 1] = {
                title = r.title or "Match",
                description = (r.description or ""):sub(1, 100),
                url = r.url,
            }
        end

        trendingCache = results
        lastFetchTime = now
    end, "GET", "", {
        ["Accept"] = "application/json",
        ["Accept-Encoding"] = "gzip",
        ["X-Subscription-Token"] = key,
    })
end

CreateThread(function()
    Wait(5000)
    fetchTrendingMatches()
    while true do
        Wait((Config.TrendingCacheHours or 6) * 3600 * 1000)
        fetchTrendingMatches()
    end
end)

function GetTrendingMatches()
    return trendingCache
end
