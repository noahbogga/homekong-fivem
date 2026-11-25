--=====================================================================
-- ACCESS CONTROL — SERVER-SIDE ONLY. This file is a server_script and
-- NEVER downloads to any player, so the owner identifiers here cannot
-- leak through a client resource dump.
--
-- WHO CAN OPEN THE EDITOR (mirrors hk-scenario):
--   PRIMARY: any server ADMIN — txAdmin admins, or ACE principals
--   (QBCore group.god/admin/mod + qbcore.god/admin/mod + command).
--   FALLBACK: the explicit identifier list below, for someone who must
--   have editor access WITHOUT being a server admin.
--
-- HOW TO ADD A NON-ADMIN:
--   1. Join, run /myid (hk-misc), read identifiers from server console.
--   2. Add the discord:/license2:/fivem: line as a string key.
--=====================================================================

Allowed = {
    -- ['discord:000000000000000000'] = true,  -- example fallback (add real IDs)
}
