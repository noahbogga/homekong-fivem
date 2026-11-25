function Trim(value)
    if not value then return nil end
    return (string.gsub(value, '^%s*(.-)%s*$', '%1'))
end

-- ── hk-billing integration ────────────────────────────────────────────────
-- The player has ALREADY been debited by the caller. This credits the fee to a
-- society account and records it in the payer's billing history. Fully safe:
-- no-op if billing is disabled or hk-billing isn't running (never breaks parking).
--   citizenid : the payer (for the billing-history entry)
--   amount    : fee amount already taken
--   society   : society to credit (GOV -> whitehouse inside hk-billing)
--   reason    : shown on the billing entry
function RouteFeeToBilling(citizenid, amount, society, reason)
    if not SV_Config.Billing or not SV_Config.Billing.enabled then return end
    if not amount or amount <= 0 then return end
    if GetResourceState('hk-billing') ~= 'started' then return end
    local ok = pcall(function()
        -- credit the society (money was already removed from the player)
        if society and society ~= '' then
            exports['hk-billing']:CreditSociety({
                society = society, amount = amount,
                reason = reason, fromName = 'HK Parking', log = false,
            })
        end
        -- record it in the payer's billing history (no money movement)
        if citizenid and citizenid ~= '' then
            exports['hk-billing']:LogPayment({
                citizenid = citizenid, amount = amount,
                reason = reason, society = society, fromName = 'HK Parking',
            })
        end
    end)
    if not ok then
        print('^3[hk-parking]^7 RouteFeeToBilling failed (hk-billing export error) — fee still charged')
    end
end

function Round(value, numDecimalPlaces)
    if not numDecimalPlaces then return math.floor(value + 0.5) end
    local power = 10 ^ numDecimalPlaces
    return math.floor((value * power) + 0.5) / (power)
end

function SafeNetId(entity)
    if not entity or not DoesEntityExist(entity) then return nil end
    local netId = NetworkGetNetworkIdFromEntity(entity)
    return (netId > 0 and netId < 65535) and netId or nil
end

function Notify(src, msg, type)
    -- Server → client notify must go via the ox_lib event; lib.notify(src, …) is
    -- a CLIENT-only API and does not exist server-side.
    TriggerClientEvent('ox_lib:notify', src, { title = "HK Parking", description = msg, type = type or "inform" })
end

function GetPlate(vehicle)
    if vehicle == 0 then return end
    return Trim(GetVehicleNumberPlateText(vehicle))
end

function GetDistance(pos1, pos2)
    if pos1 ~= nil and pos2 ~= nil then
        return #(vector3(pos1.x, pos1.y, pos1.z) - vector3(pos2.x, pos2.y, pos2.z))
    end
end

function GetClosestVehicle(coords)
    local vehicles = GetGamePool('CVehicle')
    local closestDistance = -1
    local closestVehicle = -1
    for i = 1, #vehicles do
        local vehicleCoords = GetEntityCoords(vehicles[i])
        local distance = #(vehicleCoords - coords)
        if closestDistance == -1 or closestDistance > distance then
            closestVehicle = vehicles[i]
            closestDistance = distance
        end
    end
    return closestVehicle, closestDistance
end

function DeleteVehicleAtcoords(coords)
    local closestVehicle, closestDistance = GetClosestVehicle(coords)
    if closestVehicle ~= -1 and closestDistance <= 2.0 then
        DeleteEntity(closestVehicle)
        while DoesEntityExist(closestVehicle) do
            DeleteEntity(closestVehicle)
            Wait(0)
        end
    end
end

local function GetVehicleByPlate(plate)
    if not plate or plate == "" then return nil end
    plate = string.upper(tostring(plate)):gsub("^%s*(.-)%s*$", "%1")
    local vehicles = GetAllVehicles()
    for _, veh in ipairs(vehicles) do
        if DoesEntityExist(veh) then
            local vehPlate = GetVehicleNumberPlateText(veh)
            vehPlate = string.upper(tostring(vehPlate)):gsub("^%s*(.-)%s*$", "%1")
            if vehPlate == plate then return veh end
        end
    end
    return nil
end

function GiveKeys(src, plate)
    src = tonumber(src)
    if not src or not plate then return false end
    plate = string.upper(tostring(plate)):gsub("^%s*(.-)%s*$", "%1")
    local realVehicle = GetVehicleByPlate(plate)
    if realVehicle ~= nil then
        if GetResourceState('qbx_vehiclekeys') == 'started' then exports.qbx_vehiclekeys.GiveKeys(src, realVehicle, true)  end
        if GetResourceState('qs-vehiclekeys') == 'started' then exports['qs-vehiclekeys']:GiveKeys(plate, GetDisplayNameFromVehicleModel(GetEntityModel(realVehicle)), true)  end
        return true
    else
        if GetResourceState('qb-vehiclekeys') == 'started' then local Player = GetPlayer(src); local keys = Player.PlayerData.metadata["vehicleKeys"] or {}; keys[plate] = true; Player.Functions.SetMetaData("vehicleKeys", keys); return true end
        if GetResourceState('esx_vehiclekeys') == 'started' then TriggerEvent('esx_vehiclekeys:server:giveKey', plate, src); return true end
        if GetResourceState('qb-keys') == 'started' then exports['qb-keys']:GiveKey(src, plate); return true end
        if GetResourceState('Renewed-Vehiclekeys') == 'started' then exports['Renewed-Vehiclekeys']:addKey(plate); return true end
        if GetResourceState('vehicles_keys') == 'started' then exports["vehicles_keys"]:giveVehicleKeysToPlayerId(src, plate, "owned"); return true end
        if GetResourceState('wasabi_carlock') == 'started' then exports.wasabi_carlock:GiveKey(src, plate); return true end
    end
    return false
end

function PoliceImpound(plate, fullImpound, price, body, engine, fuel)
    TriggerEvent("police:server:Impound", plate, fullImpound, price, body, engine, fuel)
    -- if you have your own police script than add your impound trigger here.
end