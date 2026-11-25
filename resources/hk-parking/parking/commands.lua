-- HK-PARKING commands. VIP parking removed (HOMEKONG: everyone parks freely).

AddCommand("parkmenu", "Player park menu", {}, true, function(source, args)
    local src = source
    TriggerClientEvent('hk-parking:openparkmenu', src)
end)

-- ADMIN convenience: open a garage-style menu of ALL your own cars anywhere, and
-- spawn any of them at your feet for free. Admin-only (QBCore perm + server-side
-- ace re-check in the callbacks). Also fine to hook one-click elsewhere by firing
-- 'hk-garage:client:openAdminParking' on the client.
AddCommand("adminparking", "Admin: spawn any of your cars here", {}, true, function(source, args)
    local src = source
    if not (IsPlayerAceAllowed(src, 'admin') or IsPlayerAceAllowed(src, 'command')) then return end
    TriggerClientEvent('hk-garage:client:openAdminParking', src)
end)
