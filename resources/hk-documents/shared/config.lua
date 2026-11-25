Config = {}

-- ── Core ────────────────────────────────────────────────────────────────
Config.Locale      = 'zh-hk'
Config.Command     = 'doc'          -- opens the document panel
Config.RegisterKey = false          -- e.g. 'F7' to bind a key, or false
Config.ItemName    = 'documents'    -- usable inventory item that opens it, or false
Config.Debug       = false

-- Paper prop + anim held while the panel is open (cosmetic).
Config.PaperProp = { model = 'p_ld_id_card_01', bone = 36029, xRot = 0.0, yRot = 0.0, zRot = 0.0 }

-- Proximity for show / give-copy to a nearby player.
Config.NearbyDistance = 2.5

-- ── Document types ────────────────────────────────────────────────────────
-- The engine ships three renderers. Templates pick one via `docType`.
Config.DocTypes = {
    license     = { label = 'License / ID Card', maxFields = 6,  hasPhoto = true,  hasExpiry = true },
    a4          = { label = 'A4 Document',       maxFields = 10, hasBody = true,   hasAttachments = true },
    certificate = { label = 'Certificate',       maxFields = 4,  hasSignature = true },
}

-- ── Per-job branding (LOCKED) ─────────────────────────────────────────────
-- Only jobs listed here can create/manage templates and issue documents. Each
-- job's logo, background and accent are LOCKED — players fill fields only, they
-- cannot change branding or the template title. `templateGrades` = grades
-- allowed to manage templates; `minGrade` = default min grade to issue.
--
-- logo/background accept: an https URL, an images.example.com/u/... URL, or a
-- local path under html/ (e.g. 'assets/police_logo.png'). Empty = default.
Config.DefaultLogo       = 'assets/hk_logo.png'
Config.DefaultBackground = ''      -- '' = the built-in paper texture
Config.DefaultAccent     = '#00c8ff'

Config.Jobs = {
    ['police'] = {
        label = '洛聖都警察局',
        logo = 'assets/police_logo.png', background = '', accent = '#3b6fd4',
        templateGrades = { 3, 4 },  minGrade = 0,
    },
    ['fbi'] = {
        label = '聯邦調查局',
        logo = 'assets/fbi_logo.png', background = '', accent = '#1f2d5a',
        templateGrades = { 4, 5, 6 }, minGrade = 0,
    },
    ['nia'] = {
        label = '國家情報局',
        logo = 'assets/nia_logo.png', background = '', accent = '#2b2b2b',
        templateGrades = { 4, 5, 6 }, minGrade = 0,
    },
    ['whitehouse'] = {
        label = '政府辦公室',
        logo = 'assets/gov_logo.png', background = '', accent = '#8a6d3b',
        templateGrades = { 3, 4 },  minGrade = 0,
    },
    ['ambulance'] = {
        label = 'Pillbox 醫院',
        logo = 'assets/ems_logo.png', background = '', accent = '#d43b3b',
        templateGrades = { 3, 4 },  minGrade = 0,
    },
    ['gundealer'] = {
        label = '持牌槍械商',
        logo = 'assets/gun_logo.png', background = '', accent = '#b8860b',
        templateGrades = { 4 },     minGrade = 0,
    },
    -- Branding for auto-issued weapon licenses (handed to the buyer, not the
    -- dealer). Not a real job — used only by hk-crafting's issueDocument call,
    -- so it needs no templateGrades/minGrade gating.
    ['firearms_license'] = {
        label = '槍械牌照',
        logo = 'assets/gun_logo.png', background = '', accent = '#b8860b',
        templateGrades = {},        minGrade = 0,
    },
}

-- Citizen templates (any player). Leave empty to disable citizen documents.
Config.AllowCitizenTemplates = false

-- ── Image attachments (Zipline) ───────────────────────────────────────────
-- The secret token lives in server/sv_config.lua (never sent to clients).
Config.Images = {
    enabled       = true,
    uploadEnabled = true,                              -- server-side direct upload
    portalEnabled = true,                              -- browser upload/paste portal
    publicBase    = 'https://images.example.com',       -- where uploads resolve
    maxUrlLength  = 512,
    -- Only allow attaching images from these hosts (anti-abuse). '*' = any https.
    allowedHosts  = { 'images.example.com', 'cdn.example.com' },
}
