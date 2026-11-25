-- hk-documents :: server/main.lua
-- Authoritative document + template CRUD. Every mutation is authorized here
-- server-side (k5's big footgun was client-only gating). The `data` JSON is
-- stored verbatim for rendering, but access is decided from the normalized
-- columns and the caller's real identity/job — never from client claims.

-- ── DB schema bootstrap ───────────────────────────────────────────────────
CreateThread(function()
    MySQL.query([[CREATE TABLE IF NOT EXISTS `hk_documents` (
        `id` INT(11) NOT NULL AUTO_INCREMENT, `data` LONGTEXT NOT NULL,
        `ownerId` VARCHAR(64) NOT NULL, `issuerId` VARCHAR(64) DEFAULT NULL,
        `job` VARCHAR(64) DEFAULT NULL, `docType` VARCHAR(32) NOT NULL DEFAULT 'a4',
        `isCopy` TINYINT(1) NOT NULL DEFAULT 0,
        `createdAt` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (`id`), KEY `idx_owner` (`ownerId`), KEY `idx_issuer` (`issuerId`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]])
    MySQL.query([[CREATE TABLE IF NOT EXISTS `hk_document_templates` (
        `id` INT(11) NOT NULL AUTO_INCREMENT, `data` LONGTEXT NOT NULL,
        `job` VARCHAR(64) NOT NULL, `docType` VARCHAR(32) NOT NULL DEFAULT 'a4',
        `minGrade` INT(11) DEFAULT NULL, `createdBy` VARCHAR(64) DEFAULT NULL,
        PRIMARY KEY (`id`), KEY `idx_job` (`job`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]])
end)

-- ── Helpers ────────────────────────────────────────────────────────────────
local function decodeRow(row)
    local doc = json.decode(row.data) or {}
    doc.id = row.id
    doc.isCopy = row.isCopy == 1
    doc.docType = row.docType
    doc.job = row.job
    doc.createdAt = tostring(row.createdAt)
    return doc
end

-- Sanitize a client-supplied document body down to known fields.
local function sanitizeDoc(input, docType)
    local dt = Config.DocTypes[docType] or Config.DocTypes.a4
    local out = {
        title       = tostring(input.title or ''):sub(1, 120),
        description = tostring(input.description or ''):sub(1, 500),
        infoName    = tostring(input.infoName or ''):sub(1, 60),
        infoValue   = tostring(input.infoValue or ''):sub(1, 2000),
        body        = dt.hasBody and tostring(input.body or ''):sub(1, 5000) or nil,
        expiry      = dt.hasExpiry and tostring(input.expiry or ''):sub(1, 40) or nil,
        fields      = {},
        images      = {},
    }
    -- fields (name/value pairs, capped)
    local maxF = dt.maxFields or 6
    if type(input.fields) == 'table' then
        for i = 1, math.min(#input.fields, maxF) do
            local f = input.fields[i]
            if type(f) == 'table' then
                out.fields[#out.fields + 1] = {
                    name  = tostring(f.name or ''):sub(1, 60),
                    value = tostring(f.value or ''):sub(1, 300),
                }
            end
        end
    end
    -- images: only allow-listed URLs survive
    if (dt.hasAttachments or dt.hasPhoto) and type(input.images) == 'table' then
        for i = 1, math.min(#input.images, 6) do
            local url = input.images[i]
            if IsAllowedImage(url) then out.images[#out.images + 1] = url end
        end
    end
    -- single photo for license/cert
    if dt.hasPhoto and IsAllowedImage(input.photo) then out.photo = input.photo end
    return out
end

-- ── Read callbacks ────────────────────────────────────────────────────────
lib.callback.register('hk-documents:getMyDocuments', function(src)
    local ident = GetIdentity(src)
    if not ident then return {} end
    local rows = MySQL.query.await(
        'SELECT * FROM `hk_documents` WHERE `ownerId` = ? ORDER BY `id` DESC', { ident.citizenid }) or {}
    local out = {}
    for _, r in ipairs(rows) do out[#out + 1] = decodeRow(r) end
    return out
end)

lib.callback.register('hk-documents:getTemplates', function(src)
    local ident = GetIdentity(src)
    if not ident then return {} end
    local list = {}
    if ident.jobName then
        local rows = MySQL.query.await(
            'SELECT * FROM `hk_document_templates` WHERE `job` = ? ORDER BY `id` DESC', { ident.jobName }) or {}
        for _, r in ipairs(rows) do
            -- only show templates this grade may actually issue
            if CanIssue(ident, r.job, r.minGrade) or CanManageTemplates(ident) then
                local t = json.decode(r.data) or {}
                t.id = r.id; t.job = r.job; t.docType = r.docType; t.minGrade = r.minGrade
                list[#list + 1] = t
            end
        end
    end
    if Config.AllowCitizenTemplates then
        local rows = MySQL.query.await(
            "SELECT * FROM `hk_document_templates` WHERE `job` = '' OR `job` IS NULL ORDER BY `id` DESC") or {}
        for _, r in ipairs(rows) do
            local t = json.decode(r.data) or {}
            t.id = r.id; t.job = ''; t.docType = r.docType; t.minGrade = r.minGrade
            list[#list + 1] = t
        end
    end
    return list
end)

lib.callback.register('hk-documents:getJobBranding', function(src)
    local ident = GetIdentity(src)
    local job = ident and ident.jobName
    local cfg = job and Config.Jobs[job]
    return {
        job        = job,
        canManage  = CanManageTemplates(ident),
        label      = cfg and cfg.label or nil,
        logo       = cfg and cfg.logo or Config.DefaultLogo,
        background = cfg and cfg.background or Config.DefaultBackground,
        accent     = cfg and cfg.accent or Config.DefaultAccent,
        docTypes   = Config.DocTypes,
        identity   = ident and { firstname = ident.firstname, lastname = ident.lastname,
                                 birthdate = ident.birthdate, jobLabel = ident.jobLabel } or nil,
    }
end)

-- ── Template CRUD (authorized) ────────────────────────────────────────────
lib.callback.register('hk-documents:saveTemplate', function(src, payload)
    local ident = GetIdentity(src)
    if not CanManageTemplates(ident) then Notify(src, L('no_permission'), 'error'); return false end
    if type(payload) ~= 'table' then return false end

    local docType = Config.DocTypes[payload.docType] and payload.docType or 'a4'
    local minGrade = tonumber(payload.minGrade)   -- nil allowed
    local data = {
        documentName = tostring(payload.documentName or ''):sub(1, 120),   -- blank OK; NUI localizes empty via t('untitled')
        description  = tostring(payload.description or ''):sub(1, 500),
        fields       = {},
        infoName     = tostring(payload.infoName or ''):sub(1, 60),
        infoTemplate = tostring(payload.infoTemplate or ''):sub(1, 2000),
    }
    local maxF = (Config.DocTypes[docType] or {}).maxFields or 6
    if type(payload.fields) == 'table' then
        for i = 1, math.min(#payload.fields, maxF) do
            local n = payload.fields[i]
            data.fields[#data.fields + 1] = tostring((type(n) == 'table' and n.name) or n or ''):sub(1, 60)
        end
    end

    if payload.id then
        -- edit: must be a template of the caller's own job
        local row = MySQL.single.await('SELECT job FROM `hk_document_templates` WHERE `id` = ?', { payload.id })
        if not row or row.job ~= ident.jobName then Notify(src, L('no_permission'), 'error'); return false end
        MySQL.update.await('UPDATE `hk_document_templates` SET `data` = ?, `docType` = ?, `minGrade` = ? WHERE `id` = ?',
            { json.encode(data), docType, minGrade, payload.id })
        Notify(src, L('template_saved'), 'success')
        return payload.id
    else
        local id = MySQL.insert.await(
            'INSERT INTO `hk_document_templates` (`data`,`job`,`docType`,`minGrade`,`createdBy`) VALUES (?,?,?,?,?)',
            { json.encode(data), ident.jobName, docType, minGrade, ident.citizenid })
        Notify(src, L('template_saved'), 'success')
        return id
    end
end)

lib.callback.register('hk-documents:deleteTemplate', function(src, id)
    local ident = GetIdentity(src)
    if not CanManageTemplates(ident) then Notify(src, L('no_permission'), 'error'); return false end
    local row = MySQL.single.await('SELECT job FROM `hk_document_templates` WHERE `id` = ?', { id })
    if not row or row.job ~= ident.jobName then Notify(src, L('no_permission'), 'error'); return false end
    MySQL.query.await('DELETE FROM `hk_document_templates` WHERE `id` = ?', { id })
    Notify(src, L('template_deleted'), 'success')
    return true
end)

-- ── Document create / delete (authorized) ─────────────────────────────────
-- Create issues a document. If targetId is given and caller may issue, it lands
-- in the target's inventory of documents; otherwise it goes to the caller.
lib.callback.register('hk-documents:createDocument', function(src, payload)
    local ident = GetIdentity(src)
    if not ident then return false end
    if type(payload) ~= 'table' then return false end

    -- Resolve template + authorization.
    local templateJob, templateMinGrade, docType = nil, nil, 'a4'
    if payload.templateId then
        local row = MySQL.single.await('SELECT * FROM `hk_document_templates` WHERE `id` = ?', { payload.templateId })
        if not row then Notify(src, L('not_found'), 'error'); return false end
        templateJob, templateMinGrade, docType = row.job, row.minGrade, row.docType
    else
        docType = Config.DocTypes[payload.docType] and payload.docType or 'a4'
        templateJob = ident.jobName   -- freeform doc under own job branding
    end

    if not CanIssue(ident, templateJob, templateMinGrade) then
        Notify(src, L('no_permission'), 'error'); return false
    end

    -- Branding is LOCKED to the issuing job (client cannot override).
    local jobCfg = templateJob and Config.Jobs[templateJob] or nil
    local body = sanitizeDoc(payload, docType)
    body.job        = templateJob
    body.jobLabel   = jobCfg and jobCfg.label or nil
    body.logo       = jobCfg and jobCfg.logo or Config.DefaultLogo
    body.background = jobCfg and jobCfg.background or Config.DefaultBackground
    body.accent     = jobCfg and jobCfg.accent or Config.DefaultAccent
    body.issuer     = { firstname = ident.firstname, lastname = ident.lastname,
                        jobLabel = ident.jobLabel }
    body.createdAt  = os.date('%Y-%m-%d %H:%M')

    -- Target: default self. Issuing to ANOTHER player requires that they be
    -- online AND physically nearby — validated SERVER-SIDE (a tampered client
    -- must not be able to plant docs into an arbitrary player across the map).
    local ownerCid = ident.citizenid
    local isCopy = 0
    local targetSrc = payload.targetSrc and tonumber(payload.targetSrc) or nil
    if targetSrc then
        local tIdent = GetIdentity(targetSrc)
        if not tIdent or not isNearby(src, targetSrc) then
            Notify(src, L('no_players_nearby'), 'error'); return false
        end
        ownerCid = tIdent.citizenid
    end

    local id = MySQL.insert.await(
        'INSERT INTO `hk_documents` (`data`,`ownerId`,`issuerId`,`job`,`docType`,`isCopy`) VALUES (?,?,?,?,?,?)',
        { json.encode(body), ownerCid, ident.citizenid, templateJob, docType, isCopy })

    Notify(src, L('doc_created'), 'success')
    if targetSrc then   -- validated above; safe to notify/refresh the recipient
        Notify(targetSrc, L('doc_received', body.title ~= '' and body.title or (jobCfg and jobCfg.label or L('generic_document'))), 'inform')
        TriggerClientEvent('hk-documents:refresh', targetSrc)
    end
    return id
end)

lib.callback.register('hk-documents:deleteDocument', function(src, id)
    local ident = GetIdentity(src)
    if not ident then return false end
    -- only the OWNER may delete their held document
    local row = MySQL.single.await('SELECT ownerId FROM `hk_documents` WHERE `id` = ?', { id })
    if not row or row.ownerId ~= ident.citizenid then Notify(src, L('no_permission'), 'error'); return false end
    MySQL.query.await('DELETE FROM `hk_documents` WHERE `id` = ?', { id })
    Notify(src, L('doc_deleted'), 'success')
    return true
end)

-- Server-authoritative nearby check (name + server id) for the picker AND for
-- createDocument's issue-to-another-player gate. GLOBAL (not local) so it is in
-- scope for createDocument above, which is defined earlier in the file — globals
-- resolve at call time, and the whole script loads before any player can call.
-- Distance is checked here so the client can't fabricate reach.
function isNearby(src, targetSrc)
    if src == targetSrc then return false end
    local a, b = GetPlayerPed(src), GetPlayerPed(targetSrc)
    if a == 0 or b == 0 then return false end
    return #(GetEntityCoords(a) - GetEntityCoords(b)) <= (Config.NearbyDistance or 2.5)
end

lib.callback.register('hk-documents:getNearby', function(src)
    local out = {}
    for _, pid in ipairs(GetPlayers()) do
        local tsrc = tonumber(pid)
        if isNearby(src, tsrc) then
            local tIdent = GetIdentity(tsrc)
            local name = tIdent and (tIdent.firstname .. ' ' .. tIdent.lastname) or GetPlayerName(tsrc)
            out[#out + 1] = { id = tsrc, name = name }
        end
    end
    return out
end)

-- Give a COPY of one of my documents to a nearby player (target picked from list).
RegisterNetEvent('hk-documents:giveCopy', function(docId, targetSrc)
    local src = source
    targetSrc = tonumber(targetSrc)
    local ident = GetIdentity(src)
    if not ident then return end
    if not targetSrc or not isNearby(src, targetSrc) then Notify(src, L('no_players_nearby'), 'error'); return end
    local row = MySQL.single.await('SELECT * FROM `hk_documents` WHERE `id` = ? AND `ownerId` = ?',
        { docId, ident.citizenid })
    if not row then Notify(src, L('not_found'), 'error'); return end
    local tIdent = GetIdentity(targetSrc)
    if not tIdent then Notify(src, L('no_players_nearby'), 'error'); return end

    MySQL.insert.await(
        'INSERT INTO `hk_documents` (`data`,`ownerId`,`issuerId`,`job`,`docType`,`isCopy`) VALUES (?,?,?,?,?,1)',
        { row.data, tIdent.citizenid, row.issuerId, row.job, row.docType })
    Notify(src, L('doc_given', (tIdent.firstname .. ' ' .. tIdent.lastname)), 'success')
    Notify(tonumber(targetSrc), L('doc_received', L('label_copy')), 'inform')
    TriggerClientEvent('hk-documents:refresh', tonumber(targetSrc))
end)

-- Show a document to a nearby player (transient fullscreen, not saved).
RegisterNetEvent('hk-documents:showTo', function(docId, targetSrc)
    local src = source
    targetSrc = tonumber(targetSrc)
    local ident = GetIdentity(src)
    if not ident then return end
    if not targetSrc or not isNearby(src, targetSrc) then Notify(src, L('no_players_nearby'), 'error'); return end
    local row = MySQL.single.await('SELECT * FROM `hk_documents` WHERE `id` = ? AND `ownerId` = ?',
        { docId, ident.citizenid })
    if not row then return end
    TriggerClientEvent('hk-documents:viewFromPlayer', targetSrc, decodeRow(row))
end)

-- ── Portal upload code flow ────────────────────────────────────────────────
lib.callback.register('hk-documents:newUploadCode', function(src)
    local ident = GetIdentity(src)
    if not ident then return nil end
    if not (Config.Images.enabled and Config.Images.portalEnabled) then return nil end
    return NewUploadCode(ident.citizenid)
end)

lib.callback.register('hk-documents:claimUploadCode', function(src, code)
    local ident = GetIdentity(src)
    if not ident then return nil end
    local url, err = ClaimUploadCode(ident.citizenid, code)
    if not url then return { ok = false, error = err } end
    return { ok = true, url = url }
end)

-- ── Public export for other resources (e.g. hk-crafting gundealer hook) ────
-- issueDocument(targetSrc, opts)
--   opts = { job, docType, title, fields={{name,value}}, infoName, infoValue,
--            expiry, images={}, photo }
-- Branding is forced from Config.Jobs[opts.job] (locked). Returns the new id.
local function issueDocument(targetSrc, opts)
    targetSrc = tonumber(targetSrc)
    local tIdent = GetIdentity(targetSrc)
    if not tIdent or type(opts) ~= 'table' then return nil end

    local docType = Config.DocTypes[opts.docType] and opts.docType or 'license'
    local jobCfg = opts.job and Config.Jobs[opts.job] or nil
    local body = sanitizeDoc(opts, docType)
    body.job        = opts.job
    body.jobLabel   = jobCfg and jobCfg.label or opts.jobLabel
    body.logo       = jobCfg and jobCfg.logo or Config.DefaultLogo
    body.background = jobCfg and jobCfg.background or Config.DefaultBackground
    body.accent     = jobCfg and jobCfg.accent or Config.DefaultAccent
    body.issuer     = opts.issuer or { firstname = jobCfg and jobCfg.label or '系統', lastname = '' }
    body.createdAt  = os.date('%Y-%m-%d %H:%M')
    body.title      = tostring(opts.title or (jobCfg and jobCfg.label) or L('generic_document')):sub(1, 120)

    local id = MySQL.insert.await(
        'INSERT INTO `hk_documents` (`data`,`ownerId`,`issuerId`,`job`,`docType`,`isCopy`) VALUES (?,?,?,?,?,0)',
        { json.encode(body), tIdent.citizenid, opts.issuerId or 'system', opts.job, docType })
    if id then
        Notify(targetSrc, L('doc_received', body.title), 'inform')
        TriggerClientEvent('hk-documents:refresh', targetSrc)
    end
    return id
end
exports('issueDocument', issueDocument)

-- ── Usable item + command bridge ──────────────────────────────────────────
CreateThread(function()
    if Config.ItemName then
        QBCore.Functions.CreateUseableItem(Config.ItemName, function(source)
            TriggerClientEvent('hk-documents:open', source)
        end)
    end
end)
