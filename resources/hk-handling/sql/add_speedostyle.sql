-- hk-handling :: per-model SPEEDO STYLE override (2026-08-05)
-- Decouples the SPEEDO LOOK from the drivetrain behaviour class. A full PHEV
-- (hybridClass=1) drives with its EV mode + HOLD-G + speed cap, but some real cars
-- (Porsche 918, McLaren P1) present the electric side as a KERS-style boost/charge
-- meter on the normal tach rather than a full Tesla-style EV cluster. This column
-- lets an admin pick that per model via `/sethybrid full <..> <..> <speedo 0/1>`.
--
--   speedoStyle : NULL = UNSET — derive the look from hybridClass (class 1 -> FULL
--                     EV/3-ring look, class 2 -> SEMI charge-arc look). Keeps every
--                     existing car behaving exactly as before.
--                 0 = FULL  — force the full EV/hybrid 3-ring split-ring cluster.
--                 1 = SEMI  — force the semi/KERS look (normal tach + thin charge arc),
--                     even for a full PHEV (class 1). In e-mode such a car still shows
--                     the green 'D' + green throttle-driven bar; ICE mode shows revs.
--   Only meaningful for class 1 (full PHEV) — class 2 is always semi, class 0 has no
--   e-display. Stored NULL for those.
ALTER TABLE `hk_handling`
  ADD COLUMN `speedoStyle` TINYINT DEFAULT NULL;   -- NULL = derive from class; 0 = full; 1 = semi
