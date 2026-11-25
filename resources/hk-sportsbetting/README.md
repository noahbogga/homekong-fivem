# hk-sportsbetting

"Steak", the in-game sportsbook and casino (React NUI). Odds come from a separate odds engine service (not included); bets also work from a web/PWA mirror with a per-player mobile key, which moves real in-game cash through a guarded callback.

## Setup
Fill in `server/secrets.lua`: `APIKeys` / `SharpAPIKeys` (your odds API keys), `Engine.url` + `authToken` (your odds engine), `MobileCash.secret` + `allowedIPs` (only if you run the web/PWA cash bridge), optional `BraveAPIKey`.
