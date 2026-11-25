-- hk-documents :: server/sv_config.lua
-- SERVER-ONLY secrets. This file is in server_scripts and is NEVER sent to
-- clients. Do not move any of this into shared/ or client/.
--
-- ── SETUP (one-time) ──────────────────────────────────────────────────────
-- 1. In the Zipline dashboard (https://images.example.com) create a dedicated
--    user for this resource (e.g. "hk-documents") and generate its token.
-- 2. Zipline v4 does NOT accept the raw DB token directly — it must be the
--    AES-256-GCM encrypted header form. Two ways to get it:
--      a) Easiest: in the Zipline dashboard the token shown to a logged-in user
--         (Account > Manage Token) is already usable as the `authorization`
--         header. Paste that value below.
--      b) Or mint it from a raw token with CORE_SECRET (see docs/ZIPLINE.md).
-- 3. Add a Cloudflare WAF skip rule for the fxserver's public IP on
--    /api/upload, or set UploadHost below to the nginx origin.

ZiplineConfig = {
    -- The `authorization` header value (encrypted token). Leave '' to disable
    -- server-side upload (paste-URL + portal can still work if portal has its own).
    token = '',

    -- Where the server POSTs uploads. Public hostname by default; switch to the
    -- nginx origin (e.g. 'http://YOUR_SERVICES_HOST:8081') if Cloudflare WAF blocks
    -- the server IP on /api/*.
    uploadHost = 'https://images.example.com',

    -- Domain header so Zipline returns https URLs regardless of coreReturnHttpsUrls.
    returnDomain = 'https://images.example.com',

    -- Never expire uploaded document images.
    deletesAt = 'never',
}

-- Shared secret between the browser portal and this server for the code<->URL
-- exchange. The /portal-upload endpoint REQUIRES this value (body field
-- `secret`); requests without it are rejected 401. NOTE: the portal page is
-- served to a browser, so whoever loads the page can read the secret — it stops
-- unauthenticated scanners and off-origin tools, not someone who opened the
-- portal. It MUST match SECRET in html/portal/portal.js. Change BOTH together.
PortalConfig = {
    secret = 'CHANGE_ME_hk_documents_portal_' .. 'secret',
    codeTtlSeconds = 600,   -- how long an upload code stays claimable
    -- CORS Access-Control-Allow-Origin for the portal endpoints. Set to your
    -- portal's public origin (e.g. 'https://docs.example.com') to stop other
    -- web origins from scripting the endpoint. '*' allows any origin.
    allowOrigin = '*',
}
