-- hk-handling :: hybrid class + EV-torque per-model persistence (2026-08-05)
-- Adds DB-persisted hybrid classification so admins can set a car's hybrid type
-- live via /sethybrid, instead of only the config Models list.
--
--   hybridClass : NULL = UNSET — fall back to the config Hybrid.Models list (so the
--                     built-in PHEV list keeps driving cars with no explicit /sethybrid).
--                     MUST be nullable + default NULL: a NOT NULL DEFAULT 0 makes every
--                     pre-existing row (they all have gear presets) read 0, which the
--                     client treats as "explicitly not a hybrid" and NEVER consults the
--                     config list -> the whole PHEV list silently dies. (Fixed 2026-08-05.)
--                 0 = NONE — explicitly forced plain ICE via `/sethybrid none` (overrides
--                     the config list; distinct from NULL/unset).
--                 1 = FULL PHEV  — has a standalone electric drive mode (HOLD-G
--                     toggles EV<->ICE), e-mode hard speed cap, regen. (SF90, 296,
--                     AMG ONE, Gemera, etc. — today's isHybrid.)
--                 2 = SEMI hybrid — ICE always runs, e-motor(s) give regen-on-lift
--                     + an always-on torque FILL to ICE power, but NO standalone EV
--                     drive mode. (918, P1, LaFerrari, mild-hybrid Benz, etc.)
--   evTorque    : EV torque value ×100 (int), interpreted per class:
--                   class 1 (full) -> e-mode PowerFrac (e.g. 28 = 0.28 power)
--                   class 2 (semi) -> always-on boost MULTIPLIER (e.g. 120 = ×1.20)
--                 NULL = use the config/global default for that class.
--   hybridCap   : full-PHEV e-mode top-speed cap in km/h (class 1 only).
--                 NULL = use the config ModelProfiles / global default.
ALTER TABLE `hk_handling`
  ADD COLUMN `hybridClass` TINYINT DEFAULT NULL,   -- NULL = unset (use config); 0/1/2 = explicit
  ADD COLUMN `evTorque`    SMALLINT DEFAULT NULL,
  ADD COLUMN `hybridCap`   SMALLINT DEFAULT NULL;

-- If this migration was previously applied as NOT NULL DEFAULT 0, run the corrective
-- step below once to un-break the config fallback (turns the mass-migrated 0s back into
-- "unset" while preserving any explicit /sethybrid classification):
--   ALTER TABLE `hk_handling` MODIFY `hybridClass` TINYINT NULL DEFAULT NULL;
--   UPDATE `hk_handling` SET `hybridClass` = NULL WHERE `hybridClass` = 0;
