-- Server-only secrets — NOT sent to clients
-- This file is loaded as a server_script only

ServerConfig = {}

ServerConfig.APIKeys = {
    "YOUR_ODDS_API_KEY",
}

ServerConfig.SharpAPIKeys = {
    "YOUR_SHARPAPI_KEY",
}

ServerConfig.Engine = {
    url = "http://YOUR_ODDS_ENGINE_HOST:4200",
    authToken = "CHANGE_ME_ENGINE_TOKEN",
}

-- Phase 3 real-cash pipeline: the engine (.247) calls our inbound applyCash HTTP
-- handler to move REAL game cash for web/PWA bets, and WAITS for confirm. This is
-- a money-editing endpoint on the public FiveM port (30120), so it is guarded by
-- BOTH a source-IP allowlist AND this shared secret (separate from the engine
-- token above). The engine sends it as the x-cash-secret header.
ServerConfig.MobileCash = {
    secret = "CHANGE_ME_LONG_RANDOM_SECRET",
    -- Only these source IPs may call applyCash. The engine host (.247) only.
    allowedIPs = {
        ["YOUR_ODDS_ENGINE_IP"] = true,
        ["127.0.0.1"] = true, -- local loopback (same-box testing)
    },
}

ServerConfig.BraveAPIKey = ""
