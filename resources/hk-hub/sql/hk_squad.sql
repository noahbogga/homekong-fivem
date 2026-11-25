-- hk-hub Squad system schema (namespaced hk_squad_* to avoid colliding with the
-- upstream af_squad tables this was ported from). Squads persist across restarts;
-- members auto-rejoin their squad on reconnect.
--
-- Import once:  mysql < hk_squad.sql   (or run through your DB admin tool)

CREATE TABLE IF NOT EXISTS `hk_squads` (
  `id`         INT UNSIGNED NOT NULL AUTO_INCREMENT,
  `name`       VARCHAR(64) NOT NULL,
  `join_code`  VARCHAR(12) NULL,              -- short code for join-by-code (nullable)
  `radio`      INT UNSIGNED NULL,             -- assigned pma-voice channel (nullable)
  `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  UNIQUE KEY `uniq_hk_squads_code` (`join_code`),
  KEY `idx_hk_squads_name` (`name`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `hk_squad_members` (
  `id`          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `squad_id`    INT UNSIGNED NOT NULL,
  `citizenid`   VARCHAR(64) NOT NULL,
  `player_name` VARCHAR(128) NULL,
  `is_owner`    TINYINT(1) NOT NULL DEFAULT 0,
  `role`        VARCHAR(32) NOT NULL DEFAULT 'member',   -- owner | officer | member
  `blip_color`  INT NULL,                                -- player-chosen GTA blip colour index (nullable = auto)
  `nickname`    VARCHAR(32) NULL,                         -- team-only nickname (cleared on leave — row is deleted)
  `joined_at`   TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  UNIQUE KEY `uniq_hk_squad_member` (`squad_id`, `citizenid`),
  KEY `idx_hk_squad_members_citizenid` (`citizenid`),
  CONSTRAINT `fk_hk_squad_members_squad`
    FOREIGN KEY (`squad_id`) REFERENCES `hk_squads` (`id`)
    ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `hk_squad_waypoints` (
  `id`         BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `squad_id`   INT UNSIGNED NOT NULL,
  `label`      VARCHAR(96) NOT NULL,
  `icon_key`   VARCHAR(32) NOT NULL DEFAULT 'danger',
  `color`      VARCHAR(16) NOT NULL DEFAULT '#00c8ff',
  `map_mode`   TINYINT NOT NULL DEFAULT 0,   -- shared minimap state: 0 hidden, 1 shown, 2 flashing
  `nx`         DECIMAL(8,6) NOT NULL,        -- normalized atlas X (0..1)
  `ny`         DECIMAL(8,6) NOT NULL,        -- normalized atlas Y (0..1)
  `wx`         DECIMAL(10,3) NULL,           -- world X (for real map waypoints)
  `wy`         DECIMAL(10,3) NULL,           -- world Y
  `created_by` VARCHAR(64) NULL,
  `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  KEY `idx_hk_squad_waypoints_squad` (`squad_id`),
  CONSTRAINT `fk_hk_squad_waypoints_squad`
    FOREIGN KEY (`squad_id`) REFERENCES `hk_squads` (`id`)
    ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Squad-only chat room. Separate from hk-chat. New members can read the full
-- backlog. Rows CASCADE-delete when the squad row is deleted (i.e. the last
-- member leaves → the whole room is purged automatically).
CREATE TABLE IF NOT EXISTS `hk_squad_messages` (
  `id`         BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `squad_id`   INT UNSIGNED NOT NULL,
  `citizenid`  VARCHAR(64) NULL,               -- author (nullable for system msgs)
  `author`     VARCHAR(64) NOT NULL,           -- display name at send time
  `body`       VARCHAR(512) NOT NULL,          -- chat text, OR JSON event for kind='system'
  `kind`       VARCHAR(16) NOT NULL DEFAULT 'chat',  -- 'chat' | 'system' (activity log)
  `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  KEY `idx_hk_squad_messages_squad` (`squad_id`, `id`),
  CONSTRAINT `fk_hk_squad_messages_squad`
    FOREIGN KEY (`squad_id`) REFERENCES `hk_squads` (`id`)
    ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
