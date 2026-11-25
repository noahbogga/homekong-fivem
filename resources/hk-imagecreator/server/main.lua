local QBCore = exports['qb-core']:GetCoreObject()

-- ============================================================
-- LOG SCREENSHOT COMPLETION
-- ============================================================
RegisterNetEvent('hk-imagecreator:server:screenshotDone', function(url, mode)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end

    local name = Player.PlayerData.charinfo.firstname .. ' ' .. Player.PlayerData.charinfo.lastname
    local cid = Player.PlayerData.citizenid

    print(('[hk-imagecreator] %s (%s) captured %s image: %s'):format(name, cid, mode, url))
end)

-- ============================================================
-- URL LOGGING (when player copies URL)
-- ============================================================
RegisterNetEvent('hk-imagecreator:server:logUrl', function(url)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    -- Just log it, nothing else needed server-side
    print(('[hk-imagecreator] URL copied by %s: %s'):format(Player.PlayerData.citizenid, url))
end)

-- ============================================================
-- ADMIN CHECK (server-authoritative)
-- ============================================================
lib.callback.register('hk-imagecreator:server:isAdmin', function(source)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then return false end

    -- Check QBCore admin perms
    if QBCore.Functions.HasPermission(source, 'admin') then return true end
    if QBCore.Functions.HasPermission(source, 'god') then return true end

    return false
end)
