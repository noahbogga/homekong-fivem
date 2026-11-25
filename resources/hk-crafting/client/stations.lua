-- hk-crafting :: client/stations.lua
-- Fixed world crafting benches (Config.Stations). Unlike portable tables these
-- can't be moved or picked up; they attach a qb-target CircleZone to a mapped
-- prop's location and open the same NUI panel.

local registered = {}   -- [zoneName] = true

local function zoneName(station)
    return ('hk-crafting:station:%s'):format(station.id)
end

local function registerStation(station)
    local cfg = Config.CraftingTables[station.uses]
    if not cfg then
        print(('[hk-crafting] station %s references unknown recipe set "%s"'):format(station.id, tostring(station.uses)))
        return
    end

    local name = zoneName(station)
    if registered[name] then return end

    exports['qb-target']:AddCircleZone(name, station.coords, station.radius or 1.5, {
        name         = name,
        debugPoly    = Config.Debug or false,
        useZ         = true,
    }, {
        options = {
            {
                icon   = Config.Target.OpenIcon,
                label  = station.label or Config.Target.OpenLabel,
                job    = station.job,   -- nil = anyone; { gundealer = 0 } = job-gated
                action = function()
                    OpenCraftingPanel({
                        station   = true,
                        recipeSet = station.uses,
                        name      = station.label or cfg.label,
                        coords    = station.coords,
                        heading   = station.heading or 0.0,
                    })
                end,
            },
        },
        distance = Config.Target.Distance,
    })

    registered[name] = true
end

local function registerAll()
    for _, station in ipairs(Config.Stations or {}) do
        registerStation(station)
    end
end

local function removeAll()
    for name in pairs(registered) do
        exports['qb-target']:RemoveZone(name)
    end
    registered = {}
end

AddEventHandler('QBCore:Client:OnPlayerLoaded', registerAll)

AddEventHandler('onResourceStart', function(res)
    if res ~= GetCurrentResourceName() then return end
    if LocalPlayer.state.isLoggedIn then registerAll() end
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    removeAll()
end)
