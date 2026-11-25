-- hk-documents :: server/util.lua
-- Shared server helpers: framework access, identity, authorization.

QBCore = exports['qb-core']:GetCoreObject()

function Dprint(...)
    if Config.Debug then print('[hk-documents]', ...) end
end

function L(key, ...)
    local s = (Locales[Config.Locale] or Locales['en'])[key] or key
    if select('#', ...) > 0 then return s:format(...) end
    return s
end

function Notify(src, msg, kind)
    TriggerClientEvent('ox_lib:notify', src, { description = msg, type = kind or 'inform' })
end

-- Resolve the calling player's identity + job in one place.
function GetIdentity(src)
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return nil end
    local pd = Player.PlayerData
    return {
        citizenid = pd.citizenid,
        firstname = pd.charinfo and pd.charinfo.firstname or '',
        lastname  = pd.charinfo and pd.charinfo.lastname or '',
        birthdate = pd.charinfo and pd.charinfo.birthdate or '',
        jobName   = pd.job and pd.job.name or nil,
        jobLabel  = pd.job and pd.job.label or nil,
        jobGrade  = pd.job and pd.job.grade and pd.job.grade.level or 0,
    }
end

-- Can this player MANAGE templates for their job? (job listed + grade allowed)
function CanManageTemplates(ident)
    if not ident or not ident.jobName then return false end
    local jobCfg = Config.Jobs[ident.jobName]
    if not jobCfg then return false end
    for _, g in ipairs(jobCfg.templateGrades or {}) do
        if ident.jobGrade >= g then return true end
    end
    return false
end

-- Can this player ISSUE from a given template? (owns the job + meets minGrade)
function CanIssue(ident, tmplJob, tmplMinGrade)
    if not ident then return false end
    -- citizen template
    if not tmplJob or tmplJob == '' then
        return Config.AllowCitizenTemplates == true
    end
    if ident.jobName ~= tmplJob then return false end
    -- Only jobs explicitly listed in Config.Jobs may issue. An unconfigured job
    -- (e.g. 'unemployed') must NOT be able to freeform-issue default-branded docs.
    local jobCfg = Config.Jobs[tmplJob]
    if not jobCfg then return false end
    local need = tmplMinGrade
    if need == nil then
        need = jobCfg.minGrade or 0
    end
    return ident.jobGrade >= (need or 0)
end

-- Validate an image URL against the allow-list (anti-abuse).
function IsAllowedImage(url)
    if type(url) ~= 'string' or url == '' then return false end
    if #url > (Config.Images.maxUrlLength or 512) then return false end
    -- https-only: parse scheme + host together so http:// never resolves a host.
    local scheme, host = url:match('^(https?)://([^/]+)')
    if not host or scheme ~= 'https' then return false end
    for _, allowed in ipairs(Config.Images.allowedHosts or {}) do
        if allowed == '*' then return true end   -- scheme already forced to https
        if host == allowed then return true end
    end
    return false
end
