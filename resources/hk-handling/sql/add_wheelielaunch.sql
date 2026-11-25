-- hk-handling :: launch-wheelie per-model opt-in persistence (2026-08-14)
-- Adds a DB-persisted per-model flag for the launch wheelie [F1], so admins can
-- enable/disable it live via /setwheelielaunch and have it survive restarts + apply
-- to every instance of the car (previously it was a client session-only table that
-- reset on resource restart, which is why a set never "stuck").
--
-- WHY it exists: giving a custom addon car the vc_muscle class makes GTA feed it
-- BUGGY handling flags (the whole reason for the muscle WheelieGuard). Marking such
-- a car vc_sport dodges those bugs but also loses GetVehicleClass==4, which is how
-- the wheelie normally arms. This flag re-enables (or force-disables) the launch
-- wheelie per-model independent of class.
--
--   wheelieLaunch : NULL = UNSET — fall back to the class gate (muscle class 4 gets
--                       it, everything else doesn't). MUST be nullable + DEFAULT NULL:
--                       a NOT NULL DEFAULT 0 would make every pre-existing row read 0 =
--                       "explicitly OFF", silently disabling the wheelie on real muscle
--                       cars. (Same trap as hybridClass/turboDefault — see add_turbo.sql.)
--                   1 = ON — force the launch wheelie on for this model even if it is
--                       NOT muscle class (a vc_sport-marked custom muscle car).
--                   0 = OFF — force it off even on a muscle-class car (silence a buggy one).
ALTER TABLE `hk_handling`
  ADD COLUMN `wheelieLaunch` TINYINT DEFAULT NULL;   -- NULL = class default; 0 = force off; 1 = force on

-- If this migration was ever applied as NOT NULL DEFAULT 0, run the corrective step
-- below once to un-break the class fallback (turns mass-migrated 0s back into "unset"
-- while preserving any explicit /setwheelielaunch classification):
--   ALTER TABLE `hk_handling` MODIFY `wheelieLaunch` TINYINT NULL DEFAULT NULL;
--   UPDATE `hk_handling` SET `wheelieLaunch` = NULL WHERE `wheelieLaunch` = 0;
