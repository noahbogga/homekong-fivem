-- ═══════════════════════════════════════════════════════════ --
--   HK-PARKING — schema + one-time migration from legacy mh-parking
-- ═══════════════════════════════════════════════════════════ --
--
-- hk-parking (PRO engine) stores parked-vehicle location directly on
-- player_vehicles: state = 3, location = JSON {x,y,z,h}, steerangle, street.
-- These columns already exist on the HOMEKONG DB (added by an older mh SQL),
-- but hk-parking's core/database.lua also ADD COLUMN IF NOT EXISTS on boot,
-- so this file is only needed for the DATA MIGRATION of the 24 legacy cars.
--
-- The legacy `player_parking` table stored coords as {x,y,z,w} (w = heading)
-- and a separate steerangle/parking(street) per plate. This copies those into
-- player_vehicles so the existing parked cars survive the cutover and the
-- qb-phone garage app can locate them.
--
-- SAFE TO RE-RUN: it only fills rows that join to player_parking; deterministic.
-- Run backups (see migrate.sh) BEFORE executing.

-- 1) Ensure the columns hk-parking needs exist (idempotent; matches database.lua).
ALTER TABLE `player_vehicles` ADD COLUMN IF NOT EXISTS `steerangle` INT NULL DEFAULT 0;
ALTER TABLE `player_vehicles` ADD COLUMN IF NOT EXISTS `street` TEXT NULL DEFAULT NULL;
ALTER TABLE `player_vehicles` ADD COLUMN IF NOT EXISTS `location` TEXT NULL DEFAULT NULL;
ALTER TABLE `player_vehicles` ADD COLUMN IF NOT EXISTS `parktime` INT NULL DEFAULT 0;
ALTER TABLE `player_vehicles` ADD COLUMN IF NOT EXISTS `time` BIGINT NOT NULL DEFAULT 0;
ALTER TABLE `player_vehicles` ADD COLUMN IF NOT EXISTS `isClamped` INT NULL DEFAULT 0;
ALTER TABLE `players` ADD COLUMN IF NOT EXISTS `parkvip` INT NULL DEFAULT 0;
ALTER TABLE `players` ADD COLUMN IF NOT EXISTS `parkmax` INT NULL DEFAULT 0;

-- 2) Migrate legacy parked cars: player_parking -> player_vehicles.
--    Remap coords key w (heading) -> h, copy steerangle + street(parking name),
--    and make sure state is 3 (parked) so hk-parking respawns them on boot.
-- NOTE: player_vehicles.plate (utf8mb4_general_ci) and player_parking.plate
-- (utf8mb4_unicode_ci) use different collations, so the join needs an explicit
-- COLLATE or MySQL throws "Illegal mix of collations".
UPDATE `player_vehicles` pv
JOIN `player_parking` pp
    ON pp.`plate` COLLATE utf8mb4_general_ci = pv.`plate`
SET
    pv.`location` = JSON_OBJECT(
        'x', CAST(JSON_EXTRACT(pp.`coords`, '$.x') AS DOUBLE),
        'y', CAST(JSON_EXTRACT(pp.`coords`, '$.y') AS DOUBLE),
        'z', CAST(JSON_EXTRACT(pp.`coords`, '$.z') AS DOUBLE),
        'h', CAST(JSON_EXTRACT(pp.`coords`, '$.w') AS DOUBLE)
    ),
    pv.`steerangle` = COALESCE(pp.`steerangle`, 0),
    pv.`street`     = pp.`parking`,
    pv.`state`      = 3
WHERE pp.`coords` IS NOT NULL
  AND JSON_VALID(pp.`coords`) = 1;

-- 3) Report what was migrated (informational; SELECT is harmless).
SELECT COUNT(*) AS migrated_parked_cars
FROM `player_vehicles`
WHERE `state` = 3 AND `location` IS NOT NULL AND `location` <> '';
