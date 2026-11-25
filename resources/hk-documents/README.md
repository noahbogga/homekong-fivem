# hk-documents

Document system (licences, A4 documents, certificates) with per-job branding, server-checked create/edit/delete, Zipline image attachments and a browser upload portal. Replaces k5_documents.

## Setup
Set your Zipline host and token in `server/sv_config.lua`, the allowed image hosts in `shared/config.lua`, and change the portal `secret` in both `server/sv_config.lua` and `html/portal/portal.js`.
