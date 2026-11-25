-- hk-handling :: hk_handling table  (NEW consolidated per-vehicle preset table)
-- Replaces `defaultManual`. Holds everything that PRE-SETS a vehicle for this
-- script. MODEL-based: flagging a model affects EVERY instance of that vehicle.
-- Matched at runtime ONLY by `hash` (and/or `model`). The `name` column is
-- cosmetic for human readability and is NEVER read by the script at runtime
-- (reading a vehicle's display name can error on some models).
--
-- NEW gearbox numbering (manualType) — PUBLIC scheme:
--   0 = OUR automatic  (THE DEFAULT; overrides GTA's native auto). No row on a
--       car-class vehicle also resolves to this.
--   1 = classic manual + clutch
--   2 = basic DCT            (was "normal DCT")
--   3 = supercar DCT
--   4 = F1 / hypercar DCT
--   5 = sequential dog box (manual)
--   6 = GTA-native automatic — DEBUG ONLY (script does NOT process the car;
--       no jim-upgrade path). This is the only way to get raw GTA behaviour.
--
--   forcePaddle   : DCT modes only (2/3/4). 0 = normal (auto + paddle sub-modes),
--                   1 = FORCE paddle-only (no auto sub-mode), 2 = FORCE-AUTO
--                   (locked automatic, paddle inputs inert). Ignored by non-DCT.
--                   (This is the old `paddleOnly` column, renamed.)
--   gearRatioMode : 0 = default, 1 = sport, 2 = drag, 3 = hypercar. Shift-feel
--                   profile (PHASE 2). 0 until PHASE 2 wires the feel logic.
--
-- Columns:
--   hash  = model hash, clean UNSIGNED 32-bit (e.g. 1989114523) — the ONLY
--           runtime match key.
--   model = spawn id (e.g. 'rx7'), auto-filled from the client reverse-map.
--   name  = display name (e.g. 'RX-7 FD3S 2000'). Cosmetic only, never matched.
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
