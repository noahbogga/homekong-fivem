local npcEntity = nil
local blip = nil
local isNearNpc = false

CreateThread(function()
    -- Load NPC model
    local model = GetHashKey(Config.NpcModel)
    RequestModel(model)
    while not HasModelLoaded(model) do
        Wait(100)
    end

    npcEntity = CreatePed(4, model, Config.Location.x, Config.Location.y, Config.Location.z - 1.25, Config.NpcHeading, false, true)
    SetEntityAsMissionEntity(npcEntity, true, true)
    SetPedFleeAttributes(npcEntity, 0, false)
    SetBlockingOfNonTemporaryEvents(npcEntity, true)
    SetEntityInvincible(npcEntity, true)
    FreezeEntityPosition(npcEntity, true)
    TaskStartScenarioInPlace(npcEntity, "WORLD_HUMAN_CLIPBOARD", 0, true)

    -- Blip
    if Config.Blip.enabled then
        blip = AddBlipForCoord(Config.Location.x, Config.Location.y, Config.Location.z)
        SetBlipSprite(blip, Config.Blip.sprite)
        SetBlipColour(blip, Config.Blip.color)
        SetBlipScale(blip, Config.Blip.scale)
        SetBlipAsShortRange(blip, true)
        BeginTextCommandSetBlipName("STRING")
        AddTextComponentSubstringPlayerName(Config.Blip.name)
        EndTextCommandSetBlipName(blip)
    end
end)

CreateThread(function()
    while true do
        local sleep = 1000
        local ped = PlayerPedId()
        local coords = GetEntityCoords(ped)
        local dist = #(coords - Config.Location)

        if dist < Config.InteractionDistance then
            sleep = 0
            isNearNpc = true
            DrawText3D(Config.Location.x, Config.Location.y, Config.Location.z + 1.0, "~y~[E]~w~ STEAK Casino")
            if IsControlJustPressed(0, 38) then -- E key
                OpenBettingUI()
            end
        else
            isNearNpc = false
        end

        Wait(sleep)
    end
end)

function DrawText3D(x, y, z, text)
    SetTextScale(0.35, 0.35)
    SetTextFont(4)
    SetTextProportional(true)
    SetTextColour(255, 255, 255, 215)
    SetTextEntry("STRING")
    SetTextCentre(true)
    AddTextComponentString(text)
    SetDrawOrigin(x, y, z, 0)
    DrawText(0.0, 0.0)
    ClearDrawOrigin()
end

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    SetNuiFocus(false, false)
    SendNUIMessage({action = "hide"})
    if npcEntity then DeleteEntity(npcEntity) end
    if blip then RemoveBlip(blip) end
end)
