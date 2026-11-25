-- hk-whysthisdealer server relay.
-- Clients report their vehicle net id + a shared start clock; the server
-- rebroadcasts to everyone so audio and bounce start together. We trust the
-- caller only to (de)activate their OWN vehicle; the beat runs client-side.

local active = {}  -- [vehNetId] = { src = playerId, startedAt = ms }

RegisterNetEvent('hk-wtd:start', function(vehNetId, startedAt, coords)
    local src = source
    if type(vehNetId) ~= 'number' or type(startedAt) ~= 'number' then return end

    -- startedAt is the initiator's GetNetworkTime() — synchronized across all
    -- clients, so every client can align its beat phase to the same origin.
    active[vehNetId] = { src = src, startedAt = startedAt }

    TriggerClientEvent('hk-wtd:play', -1, vehNetId, startedAt, coords)
end)

RegisterNetEvent('hk-wtd:stop', function(vehNetId)
    local src = source
    local entry = active[vehNetId]
    if not entry or entry.src ~= src then return end  -- only owner can stop
    active[vehNetId] = nil
    TriggerClientEvent('hk-wtd:halt', -1, vehNetId)
end)

-- Late joiners: hand them whatever is currently bouncing so they see/hear it.
RegisterNetEvent('hk-wtd:sync', function()
    local src = source
    for vehNetId, entry in pairs(active) do
        TriggerClientEvent('hk-wtd:play', src, vehNetId, entry.startedAt, nil)
    end
end)

-- Clean up if the owner drops.
AddEventHandler('playerDropped', function()
    local src = source
    for vehNetId, entry in pairs(active) do
        if entry.src == src then
            active[vehNetId] = nil
            TriggerClientEvent('hk-wtd:halt', -1, vehNetId)
        end
    end
end)
