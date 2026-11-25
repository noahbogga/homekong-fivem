-- hk-handling :: add speed-calibration columns to hk_handling
--
-- speedCal  : RAW human targets set via /setspeed. Format "kmh,seconds;..."
--             e.g. "60,2.3;100,5.5;" — "0-<kmh> should take <seconds>".
--             Cosmetic/source-of-truth for re-editing; NOT read in the hot tick.
--
-- speedCalC : COMPUTED, script-ready packed factor curve (client computes it from
--             the targets + the car's handling.meta, clamps + packs it). One fixed-
--             width BIGINT: a leading "1" sentinel, then FOUR 4-digit groups, one per
--             speed band (0-60 / 60-100 / 100-160 / 160+). Each group = factor*100,
--             zero-padded (0100 = x1.00 no-op). e.g. [0.90,1.16,1.00,1.00] ->
--             1 0090 0116 0100 0100 -> 10090011601000100. NULL/0 = no calibration.
--             The sentinel preserves leading zeros that a plain integer would drop.
ALTER TABLE `hk_handling`
  ADD COLUMN `speedCal`  VARCHAR(128) DEFAULT NULL,
  ADD COLUMN `speedCalC` BIGINT       DEFAULT NULL;

