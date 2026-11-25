-- hk-handling :: drop the legacy `defaultManual` table
-- Run ONLY after migrate_to_hk_handling.sql has been applied AND you have
-- verified hk_handling in-game (rows present, remap correct on a test car).
-- This is irreversible — the old table and its rows are gone. The migration
-- already copied everything into hk_handling, so nothing of value is lost.
--
-- VERIFY FIRST (run by hand, confirm counts match before dropping):
--   SELECT COUNT(*) FROM defaultManual;
--   SELECT COUNT(*) FROM hk_handling;

DROP TABLE IF EXISTS `defaultManual`;
