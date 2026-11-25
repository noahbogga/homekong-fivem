--[[
    hk-freecam  —  server-side admin gate
    Same auth pattern as hk-scenario: txAdmin event + ACE + identifier fallback.
]]

-- (A) txAdmin authenticated admins (CFX login)
local txAdmins = {}

AddEventHandler('txAdmin:events:adminAuth', function(data)
    if type(data) ~= 'table' or data.netid == nil then return end
    local netid = tonumber(data.netid)
    if not netid then return end
    if netid == -1 then txAdmins = {}; return end
    if data.isAdmin then txAdmins[netid] = true else txAdmins[netid] = nil end
end)

AddEventHandler('playerDropped', function()
    if source and source ~= 0 then txAdmins[source] = nil end
end)

-- (B) ACE principals
local ADMIN_ACES = {
    'qbcore.god', 'qbcore.admin', 'qbcore.mod',
    'group.god', 'group.superadmin', 'group.admin', 'group.mod',
    'command',
}

local function isAdmin(src)
    if not src or src == 0 then return false end
    if txAdmins[tonumber(src)] then return true end
    for _, ace in ipairs(ADMIN_ACES) do
        if IsPlayerAceAllowed(src, ace) then return true end
    end
    return false
end

RegisterNetEvent('hk-freecam:checkAdmin', function()
    local src = source
    TriggerClientEvent('hk-freecam:adminResult', src, isAdmin(src))
end)
