-- hk-handling :: drop the dead `forceManual` column from `hk_handling`
-- Run this ONLY if your live `hk_handling` table was created BEFORE this change
-- and still has a `forceManual` column. Fresh installs (current hk_handling.sql)
-- never have it, so they can skip this file.
--
-- WHY: `forceManual` was a vlad-era gate ("apply manualType only if jim manual
-- upgrade is installed"). Our box runs from the very first frame on the DB row +
-- car-class default, so a row ALWAYS applies regardless of force — the column
-- never did anything in this script. Jim-upgrade remapping (PHASE 1.5) is driven
-- by Config.Gearbox.Jim.UpgradeMap + the jim event, not this column.
--
-- This is safe and effectively irreversible (the column held no live meaning).

ALTER TABLE `hk_handling` DROP COLUMN `forceManual`;
