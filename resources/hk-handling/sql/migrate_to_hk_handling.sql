-- hk-handling :: migrate defaultManual -> hk_handling
-- Run ONCE on an existing DB that already has `defaultManual` rows. Safe to run
-- on a fresh DB too (copies zero rows). Does NOT drop defaultManual — keep it
-- until you've verified hk_handling in-game, then drop it manually (bottom).
--
-- REMAP of the gearbox number (old manualType -> new manualType):
--   old 1 manual   -> new 1 (manual)
--   old 2 comfort  -> new 0 (OUR automatic / default)
--   old 3 DCT      -> new 2 (basic DCT)
--   old 4 supercar -> new 3 (supercar DCT)
--   old 5 F1       -> new 4 (F1/hypercar DCT)
--   old 6 seq      -> new 5 (sequential)
--   (old 0 = no row; nothing to copy)
-- paddleOnly -> forcePaddle (verbatim 0/1/2). gearRatioMode defaults 0.
-- NOTE: the old `forceManual` column is DROPPED — it is no longer used (a row
-- always applies its manualType now), so it is not copied across.

-- 1) ensure the new table exists (mirror of hk_handling.sql)
CREATE TABLE IF NOT EXISTS `hk_handling` (
  `id`            INT AUTO_INCREMENT PRIMARY KEY,
  `model`         VARCHAR(64) DEFAULT NULL,
  `hash`          INT UNSIGNED NOT NULL,
  `name`          VARCHAR(64) DEFAULT NULL,
  `manualType`    TINYINT NOT NULL DEFAULT 0,
  `forcePaddle`   TINYINT NOT NULL DEFAULT 0,
  `gearRatioMode` TINYINT NOT NULL DEFAULT 0,
  UNIQUE KEY `hash` (`hash`)
);

-- 2) copy with remap (idempotent: ON DUPLICATE KEY refreshes the same hash)
INSERT INTO `hk_handling`
  (`model`, `hash`, `name`, `manualType`, `forcePaddle`, `gearRatioMode`)
SELECT
  `model`,
  `hash`,
  `name`,
  CASE `manualType`
    WHEN 1 THEN 1   -- manual   -> manual
    WHEN 2 THEN 0   -- comfort  -> our automatic (default)
    WHEN 3 THEN 2   -- DCT      -> basic DCT
    WHEN 4 THEN 3   -- supercar -> supercar DCT
    WHEN 5 THEN 4   -- F1       -> F1/hypercar DCT
    WHEN 6 THEN 5   -- seq      -> sequential
    ELSE `manualType`
  END AS `manualType`,
  COALESCE(`paddleOnly`, 0) AS `forcePaddle`,
  0 AS `gearRatioMode`
FROM `defaultManual`
ON DUPLICATE KEY UPDATE
  `model`         = VALUES(`model`),
  `name`          = VALUES(`name`),
  `manualType`    = VALUES(`manualType`),
  `forcePaddle`   = VALUES(`forcePaddle`);

-- 3) VERIFY before dropping (run these by hand, eyeball the remap):
--   SELECT hash, name, manualType, forcePaddle FROM hk_handling ORDER BY id;
--   SELECT COUNT(*) FROM defaultManual; SELECT COUNT(*) FROM hk_handling;
--
-- 4) ONLY after verifying, drop the old table:
--   DROP TABLE `defaultManual`;
