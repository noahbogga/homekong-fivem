-- hk-documents :: client/main.lua
-- Opens the document panel, holds the paper prop while open, bridges every NUI
-- callback to the authoritative server. No trust decisions happen here.

local isOpen = false
local propObj = nil

local function L(key, ...)
    local s = (Locales[Config.Locale] or Locales['en'])[key] or key
    if select('#', ...) > 0 then return s:format(...) end
    return s
end

local function notify(msg, kind)
    lib.notify({ description = msg, type = kind or 'inform' })
end

-- ── Paper prop while the panel is open (cosmetic) ─────────────────────────
local function attachProp()
    local p = Config.PaperProp
    if not p or not p.model then return end

    local hash = joaat(p.model)
    -- Bail cleanly if the model isn't a valid, loadable prop (bad config, etc.)
    if not IsModelValid(hash) or not IsModelInCdimage(hash) then
        if Config.Debug then print('[hk-documents] invalid paper prop model:', p.model) end
        return
    end

    -- Wait for the model to actually stream in before creating the object.
    local ok = lib.requestModel(hash, 2000)
    if not ok and not HasModelLoaded(hash) then
        if Config.Debug then print('[hk-documents] paper prop failed to load:', p.model) end
        return
    end

    local ped = cache.ped
    local obj = CreateObject(hash, GetEntityCoords(ped), true, true, true)
    SetModelAsNoLongerNeeded(hash)
    if not obj or obj == 0 or not DoesEntityExist(obj) then return end
    propObj = obj

    local bone = GetPedBoneIndex(ped, p.bone or 18905)
    if bone == -1 then bone = GetPedBoneIndex(ped, 18905) end   -- fallback: right hand
    -- AttachEntityToEntity(entity, toEntity, boneIndex, x,y,z, xRot,yRot,zRot,
    --   p9, useSoftPinning, collision, isPed, vertexIndex, fixedRot)
    AttachEntityToEntity(propObj, ped, bone, 0.0, 0.0, 0.0,
        p.xRot or 0.0, p.yRot or 0.0, p.zRot or 0.0, false, false, false, true, 1, true)
end

local function removeProp()
    if propObj and DoesEntityExist(propObj) then DeleteEntity(propObj) end
    propObj = nil
end

-- ── Open / close ────────────────────────────────────────────────────────
local function openPanel()
    if isOpen then return end
    isOpen = true
    local branding = lib.callback.await('hk-documents:getJobBranding', false)
    SetNuiFocus(true, true)
    attachProp()
    SendNUIMessage({
        action    = 'open',
        branding  = branding,
        locales   = Locales[Config.Locale] or Locales['en'],
        images    = Config.Images,
    })
end

local function closePanel()
    if not isOpen then return end
    isOpen = false
    SetNuiFocus(false, false)
    removeProp()
    SendNUIMessage({ action = 'close' })
end

RegisterNetEvent('hk-documents:open', openPanel)
RegisterNetEvent('hk-documents:refresh', function()
    if isOpen then SendNUIMessage({ action = 'refresh' }) end
end)

RegisterCommand(Config.Command, openPanel, false)
if Config.RegisterKey then
    RegisterKeyMapping(Config.Command, L('open_documents_key') or '開啟文件', 'keyboard', Config.RegisterKey)
end

-- ── NUI callbacks → server ────────────────────────────────────────────────
RegisterNUICallback('close', function(_, cb) closePanel(); cb('ok') end)

RegisterNUICallback('getMyDocuments', function(_, cb)
    cb(lib.callback.await('hk-documents:getMyDocuments', false))
end)

RegisterNUICallback('getTemplates', function(_, cb)
    cb(lib.callback.await('hk-documents:getTemplates', false))
end)

RegisterNUICallback('saveTemplate', function(data, cb)
    cb(lib.callback.await('hk-documents:saveTemplate', false, data))
end)

RegisterNUICallback('deleteTemplate', function(data, cb)
    cb(lib.callback.await('hk-documents:deleteTemplate', false, data.id))
end)

RegisterNUICallback('createDocument', function(data, cb)
    cb(lib.callback.await('hk-documents:createDocument', false, data))
end)

RegisterNUICallback('deleteDocument', function(data, cb)
    cb(lib.callback.await('hk-documents:deleteDocument', false, data.id))
end)

-- Give a copy / show to nearby → NUI picker of nearby players (name + /id).
RegisterNUICallback('getNearby', function(_, cb)
    cb(lib.callback.await('hk-documents:getNearby', false) or {})
end)

RegisterNUICallback('giveCopy', function(data, cb)
    if data.targetSrc then
        TriggerServerEvent('hk-documents:giveCopy', data.id, data.targetSrc)
    end
    cb('ok')
end)

RegisterNUICallback('showToNearby', function(data, cb)
    if data.targetSrc then
        TriggerServerEvent('hk-documents:showTo', data.id, data.targetSrc)
    end
    cb('ok')
end)

-- ── Image: portal code flow ────────────────────────────────────────────────
RegisterNUICallback('newUploadCode', function(_, cb)
    cb(lib.callback.await('hk-documents:newUploadCode', false))
end)

RegisterNUICallback('claimUploadCode', function(data, cb)
    cb(lib.callback.await('hk-documents:claimUploadCode', false, data.code))
end)

RegisterNUICallback('validateImageUrl', function(data, cb)
    -- Mirror the SERVER allow-list (server/util.lua IsAllowedImage) so a pasted
    -- URL that the server would silently drop is rejected up front, instead of
    -- the player getting a false "success" with no image. Server re-validates.
    local url = data.url or ''
    local scheme, host = url:match('^(https?)://([^/]+)')
    local ok = false
    if host and scheme == 'https' and #url <= (Config.Images.maxUrlLength or 512) then
        for _, allowed in ipairs(Config.Images.allowedHosts or {}) do
            if allowed == '*' or host == allowed then ok = true; break end
        end
    end
    cb({ ok = ok })
end)

-- ── Received document overlay (show-to-player) ────────────────────────────
RegisterNetEvent('hk-documents:viewFromPlayer', function(doc)
    SetNuiFocus(true, true)
    -- Include locales: the receiver may never have opened their own panel this
    -- session, so the NUI's L table could be empty and the renderers would show
    -- raw i18n keys (label_issued, label_photo, ...). Seed it here.
    SendNUIMessage({
        action = 'viewFromPlayer',
        document = doc,
        locales = Locales[Config.Locale] or Locales['en'],
    })
end)

RegisterNUICallback('closeView', function(_, cb)
    SetNuiFocus(false, false)
    cb('ok')
end)

AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() then removeProp() end
end)
