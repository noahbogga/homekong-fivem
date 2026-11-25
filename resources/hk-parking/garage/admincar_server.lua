-- ═══════════════════════════════════════════════════════════ --
--   HK-PARKING — /car override (collision-gated admin spawn)      --
--                                                                 --
--   qb-core's built-in /car warps the admin into a freshly        --
--   CreateVehicle'd car with NO collision gate, so under stream   --
--   pressure the ped free-falls through the seat and the world    --
--   LODs out (the "sitting ped sinks / low-res" desync).          --
--                                                                 --
--   hk-parking loads AFTER qb-core (ensure order: qb-core @124,   --
--   [hk] @220 in server.cfg), so re-registering the command here  --
--   makes OUR handler win. We deliberately do NOT edit qb-core —  --
--   a qb-core update can't clobber this. If qb-core's /car ever    --
--   changes, ours still overrides it because we register later.   --
-- ═══════════════════════════════════════════════════════════ --

-- Same signature/permission ('admin') as qb-core's original so behaviour and
-- access are identical — only the client spawn path differs (adds the gate).
QBCore.Commands.Add('car', 'Spawn Vehicle (HK gated)', {
    { name = 'model', help = 'Vehicle model name' },
}, true, function(source, args)
    TriggerClientEvent('hk-parking:client:adminCar', source, args[1])
end, 'admin')
