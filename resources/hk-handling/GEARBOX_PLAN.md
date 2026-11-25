# hk-handling — Gearbox + Speedometer Absorption Plan

Build an in-resource manual transmission/clutch module + absorb the speedometer,
so both external Jimathy resources can be retired.

## Confirmed facts (verified this session)
- Natives exist in local DB, build 3095 (server is 3570, OK):
  - `_SET_TRANSMISSION_REDUCED_GEAR_RATIO` 0x337EF33DA3DDB990 — **(veh, BOOL toggle)**, not a ratio float. The core manual enabler.
  - `_SET_VEHICLE_MAX_LAUNCH_ENGINE_REVS` 0x5AE614ECA5FDD423 — (veh, float 0..1).
  - bonus: `_GET_VEHICLE_DESIRED_DRIVE_GEAR` 0xFD8CE53356B5D745 may simplify auto-gear logic.
- The legacy gearbox is original HOMEKONG work — written from scratch against stock GTA natives.
- The speedometer is absorbed into hk-handling, reading our own gear exports.
- jim bridge (mechanic/shared/helpers.lua:197-211): `enableManualGears`→TriggerEvent("vlad_gears:activate"); disable→"vlad_gears:deactivate"; both then "vlad_gears:entered_listener". (These are jim's event-name protocol — we listen on them, jim needs no edits.)
- speedometer reads gear via our `ReportDisplayGearInteger(veh)` export; returns 'not_manual' when off.

## Decisions locked (this session)
1. Manual detection = THREE triggers OR'd: (a) jim events, (b) our config/state-bag default-manual list, (c) strHandlingFlags bit-24 (0x1000000) check too.
2. Extra-gear-from-upgrade: REMOVE the suppress toggle entirely. ALWAYS keep the extra gear when GetVehicleMod(veh,13) ~= -1 (the suppress trigger was bugged). i.e. never do SetVehicleHighGear-1.
3. Rollout: build ours behind Enabled=false; once signed off, retire the external gearbox + speedometer resources (don't delete). Repoint jim helper events to ours.
4. Speedometer: ABSORB fully into hk-handling.

## Behavioral spec
- Keybinds: ShiftUp(K), ShiftDown(J), Clutch(LSHIFT) — defaults, configurable.
- Enable: capture origins (fInitialDriveForce, fDriveInertia, fInitialDriveMaxFlatVel,
  fClutchChangeRateScaleUp/DownShift, GetVehicleHighGear). Call REDUCED_GEAR_RATIO(veh,true).
  Compute shift_time_up/down = (0.9/clutchRate)*1000 ms. Read mod-13 upgrade.
- Tick (while active, manual veh):
  - track target_gear; force via SetVehicleCurrentGear; neutral(0) during shift window.
  - Clutch held: SetVehicleHandlingFloat fInitialDriveForce=0 + feed SetVehicleCurrentRpm from
    GetVehicleThrottleOffset (revs w/o drive); released: restore fInitialDriveForce.
  - Shift timing from clutchRate; no-clutch penalty mult; mod-13 shortens time.
  - Rev limiter: rpm>=1.0 → DisableControlAction 71 (or 72 in reverse) until rpm<returnThreshold.
  - Stall: rpm<threshold for X ms in gear>=2 → SetVehicleEngineOn(false); restart on 1st.
  - State bag `sync_gear` for passengers/remote.
  - Last-gear top-speed fix via fInitialDriveMaxFlatVel.
- Exports (speedo needs these names): ReportDisplayGear, ReportDisplayGearInteger (+ ReportCurrentGear etc).

## THE KEY RISK: drift↔gearbox field-write conflict
Drift was deliberately built with NO rpm/torque writes (rpm/torque contention caused a gear-1 bug).
Now both live in hk-handling and write overlapping fields. Conflict surface:
- `fInitialDriveForce` — gearbox zeroes on clutch; nothing in drift touches it. OK if gearbox owns it exclusively.
- RPM (SetVehicleCurrentRpm) — gearbox only. Drift must keep its no-RPM rule. OK.
- HK.torqueMult / setTorque — gearbox does NOT use it (uses fInitialDriveForce + RPM). Drift doesn't either. OK.
- Control disables (71/72) — gearbox rev-limiter/reverse. No drift overlap.
Resolution: **gearbox owns fInitialDriveForce + RPM + controls; drift owns grip/suspension fields.**
Disjoint field sets = no stomp. Tick ORDER: run Gearbox_Tick AFTER drift tick but the sets don't
overlap so order is non-critical; place it right after DriftMode_Tick for clarity. Add HK.manualActive
flag so future modules can see gearbox state.

## Files to create/modify
NEW:
- `client/gearbox.lua` — Gearbox_Enable/Tick/Disable/Reset + exports. Manual detection (3 triggers).
- `client/speedo.lua` (+ stream/skins) — absorbed speedometer,
  repointed to our gear exports.
- hk-vehlib: add native wrappers setTransmissionReducedGearRatio, setMaxLaunchRevs, +
  get/set gear helpers (SetVehicleCurrentGear/HighGear/EngineOn, GetVehicleThrottleOffset)
  via Citizen.InvokeNative by hash (named globals may be nil, as with drift tyres).

### LIBRARY FACTORING (decision: "primitives + pure helpers" into vehlib)
Since we're rewriting fresh, push reusable, STATELESS pieces down to hk-vehlib so gearbox
(and launch/rev-limiter) share them. The line: vehlib = tools (no feature state);
hk-handling = stateful policy (timers, target_gear, the machine).

INTO hk-vehlib (new file `client/drivetrain.lua` or extend forces/state):
- Native wrappers: setTransmissionReducedGearRatio(0x337EF33DA3DDB990, BOOL),
  setMaxLaunchRevs(0x5AE614ECA5FDD423), getDesiredDriveGear(0xFD8CE53356B5D745).
- Gear/engine primitives: setCurrentGear, getHighGear, setHighGear, setEngineOn,
  getThrottleOffset, getVehicleMod / getModModifier (mod-13 gearbox-upgrade read).
- PURE helpers (genuinely reusable, stateless):
  - computeShiftTimeMs(clutchRate) -> (0.9/rate)*1000
  - isManualVehicle(veh, cfg) -> 3-trigger detection (strHandlingFlags bit24 0x1000000
    OR mod-13 present OR config/state-bag list) as a PURE query
  - getDrivetrainOrigins(veh) -> snapshot {fInitialDriveForce, fDriveInertia,
    fInitialDriveMaxFlatVel, fClutchChangeRateScaleUp/DownShift} (mirrors capture pattern)
  - isRightHandDrive(veh) -> steeringwheel-bone offset test (pure+reusable)
- Extend getState if useful: desiredGear, highGear (already has rpm/gear/throttle/brake).
These also de-dupe for launch-control + rev-limiter (setEngineOn, getThrottleOffset,
drivetrain origins, isManualVehicle) — not speculative, real cross-module reuse.

STAYS IN hk-handling/client/gearbox.lua (stateful policy — NOT in vehlib):
- shift state machine (target_gear, currently_shifting, shift windows),
  clutch_timer / clutch_ready, stall_timer, rev-limiter latch, statebag sync decisions,
  keybinds, difficulty config, tick orchestration.
MODIFY:
- `config.lua` — Config.Gearbox{} block (keys, difficulty, detection list, rev-limiter, stall),
  Config.Speedo{} block. Add shift/clutch keys to Config.Keys.
- `client/main.lua` — dispatch Gearbox_Tick + HK.manualActive; add gearbox to CRIT-3 reset/cleanup;
  keybind registration for shift/clutch.
- `fxmanifest.lua` — add client/gearbox.lua, client/speedo.lua, speedo stream files, exports{} block
  for ReportDisplayGear/Integer.
- `mechanic/shared/helpers.lua` — repoint enableManualGears/disableManualGears to our event names
  (or keep jim's existing event names and have our module listen to them — cleaner, no jim edit needed).
EVENT BRIDGE: our gearbox listens on the SAME event names jim already triggers
  (`vlad_gears:activate/deactivate/entered_listener`, jim's own protocol) → zero jim-mechanic edits needed. Plus our own
  `hk-handling:gearbox:*` aliases.
RETIRE (after sign-off): move the external [Jimathy] gearbox + speedometer to [unused].

## Build order (one-at-a-time, matches project rule)
1. hk-vehlib drivetrain primitives + PURE helpers (computeShiftTimeMs, isManualVehicle,
   getDrivetrainOrigins, isRightHandDrive, gear/engine wrappers) + exports. Restart vehlib first.
2. config.lua Gearbox block + keys.
3. client/gearbox.lua — detection (via vehlib isManualVehicle) + enable/disable + statebag,
   NO tick yet. Verify activation via jim event.
4. Gearbox_Tick: gear shifting only. Test up/down shift on a manual car.
5. Add clutch sim, then rev-limiter, then stall — each tested before next.
6. main.lua dispatch + CRIT-3 reset + keybinds.
7. Speedometer absorption (client/speedo.lua + stream), repoint gear export. Test readout.
8. Sign-off -> retire the external gearbox + speedometer resources to [unused].

## Pending before native commit
Grok native-verification (in flight) for 0x337EF33DA3DDB990 / 0x5AE614ECA5FDD423 behavior on
build 3570 + any ChopShop-era manual-gearbox native that beats reduced-gear-ratio. Confirm before step 1.
Drift baseline default_1 is SIGNED OFF — do not retune.
