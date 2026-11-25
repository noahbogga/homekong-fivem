--=====================================================================
-- ACCESS CONTROL — SERVER-SIDE ONLY. This file is a server_script and
-- NEVER downloads to any player, so the owner identifiers here cannot
-- leak through a client resource dump.
--
-- WHO CAN USE THE EDITOR:
--   PRIMARY: any server ADMIN. isAllowed() (server/main.lua) checks the
--   ACE principals god / admin / mod (QBCore group.god/admin/mod +
--   qbcore.god/admin/mod) and the txAdmin "command" grant. So every admin
--   tier — and any txAdmin admin — can open it automatically. Nothing to
--   configure per-admin.
--
--   FALLBACK: the explicit identifier list below. Only needed for someone
--   who must have access WITHOUT being a server admin, or if the ACE/
--   framework setup is ever unavailable.
--
-- HOW TO ADD A NON-ADMIN TO THE FALLBACK LIST:
--   1. Join the server, run  /myid  in chat (from hk-misc).
--   2. Read the identifiers printed to the SERVER console.
--   3. Add the discord: (and/or license2:/fivem:) line as a string key.
--
-- The clearing itself runs on every client (ambient entities are
-- client-owned) — that part is not gated.
--=====================================================================

Allowed = {
    ['discord:YOUR_DISCORD_ID']                          = true,  -- owner (primary)
    ['license2:YOUR_LICENSE2_ID']    = true,  -- fallback
    ['fivem:YOUR_FIVEM_ID']                                        = true,  -- fallback
}
