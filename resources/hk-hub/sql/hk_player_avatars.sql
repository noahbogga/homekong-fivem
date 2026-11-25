-- hk-hub :: character avatar cache
-- One ped-headshot portrait per character, hosted on Zipline. Refreshed only
-- when the client's appearance fingerprint changes (model + components + props),
-- so a capture happens on first login and whenever the character's look changes.
-- Shown on the F5 hub Info panel and (later) on squad member overlays.

CREATE TABLE IF NOT EXISTS `hk_player_avatars` (
  `citizenid`   VARCHAR(64)  NOT NULL,
  `url`         VARCHAR(512) NOT NULL,          -- public https Zipline URL
  `fingerprint` VARCHAR(128) NOT NULL DEFAULT '', -- appearance hash; recapture when it changes
  `updated_at`  TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`citizenid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
