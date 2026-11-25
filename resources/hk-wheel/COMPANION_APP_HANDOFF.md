# hk-wheel — Wheel Module for the HK Launcher

**Audience:** whoever adds wheel support to the **HK Launcher** (`LauncherHost`, net8.0-windows, WinForms + WebView2).
**This is NOT a separate app.** Wheel support is a MODULE inside the existing launcher — the launcher is already the local process running while the player games, so it hosts the wheel read + WebSocket. No extra download, no second exe, passive support.
**You do NOT need to read any FiveM Lua.** This doc is the complete contract.

---

## What you're building

A **wheel module inside `LauncherHost`** (add C# classes to `02-Source`, a settings view to the WebView2 UI). It:
1. Reads a **DirectInput steering wheel** (Logitech / Fanatec / Thrustmaster / Moza): axes (steer, throttle, brake, clutch, handbrake), **paddle shifters**, buttons, and the device's configured rotation range. (v1 scope: paddle shift only — no H-pattern / sequential lever.)
2. Hosts a **WebSocket server on `ws://127.0.0.1:24897`** (localhost only — never bind a public interface), started when the launcher starts.
3. Streams wheel **input frames** to the game, and applies **FFB frames** received back from the game to the device via DirectInput ForceFeedback effects.

The game side (`hk-wheel` resource, already built) connects to the launcher from inside FiveM's browser (CEF), which is allowed to reach localhost. **No injection, no ScriptHookV** — that's the whole point; it stays anti-cheat-safe.

```
  HK LAUNCHER (LauncherHost)  ⇄  ws://127.0.0.1:24897  ⇄  FiveM NUI (CEF)  ⇄  Lua  ⇄  hk-handling sim
  (DirectInput read + FFB)                                                          (steering + FFB)
```

---

## v1 scope — the MUST-HAVES (build exactly these)

Paddle-shift focused. **No H-pattern, no sequential lever** — deferred.

1. **Steering** (axis → `steer`, normalized across the device rotation range)
2. **Throttle / Brake / Clutch** pedals (axes → `throttle`/`brake`/`clutch`)
3. **Handbrake** (axis → `handbrake`, analog %)
4. **Paddle shifters +/−** (one-shot → `shift: up|down`)
5. **Neutral** standalone button (→ `neutral` action)
6. **Reverse** button, held (→ `reverse: true`, real-car throttle-to-reverse)
7. **Box selector** — DCT auto ↔ manual button (→ `box` action)
8. **Headlight beam** button (→ `headlight` action)
9. **Engine toggle** — on/off + EV/hybrid cycle (→ `engine` and `hybrid` actions)
10. **Steering rotation range** setting (270–1080°, → `rangeDeg`)
11. **FFB** (game sends force cues; module drives DirectInput effects) + master-gain setting
12. Nice-to-haves already supported if you want them: horn, look-behind, indicators/hazards, NOS (arm/level/boost).

Everything above maps to a real, verified in-game entrypoint — details in the protocol + button tables below.

---

## Where it lives (it's part of the launcher you already have)

The launcher is **net8.0-windows, WinForms, WebView2** (`LauncherHost.csproj`). The wheel module drops right in — same runtime, same process. Suggested shape:

- **`WheelInput.cs`** — enumerate + read the DirectInput device → normalized axes/buttons each poll.
- **`WheelBridge.cs`** — localhost WebSocket **server** (add the `Fleck` nuget — ~15 lines for a WS server, or `System.Net.WebSockets` + `HttpListener`). Sends `input` frames, receives `ffb` frames. Started from the launcher's startup path so it's always up while the launcher runs.
- **`WheelFFB.cs`** — DirectInput ForceFeedback effects (constant force = self-aligning, spring = centering) driven by incoming `ffb` frames.
- **Settings UI** — a **new view in the existing WebView2 launcher UI** (not a new window): device picker, rotation range, axis calibration, shifter style, FFB master gain, button bindings. Persist to the launcher's own settings/JSON.

**Stack:** C# / .NET 8 + **Vortice.DirectInput** (or SharpDX.DirectInput). DirectInput is the right API — FFB (constant force / spring / damper) is first-class and every wheel exposes it (same API ikt's GTAVManualTransmission used). No self-contained publish, no separate exe — it compiles into `LauncherHost` and ships with the launcher build you already produce.

---

## The WebSocket protocol (this is the contract)

All messages are **JSON**, one object per WS frame, each with a `t` (type) field.

### App → Game

**Device report** — send on connect and whenever the device / settings change:
```json
{ "t": "device", "name": "Logitech G29", "rangeDeg": 900,
  "hasFFB": true, "hasClutch": true, "hasHandbrake": false,
  "connected": true }
```
- `hasClutch` / `hasHandbrake` let the game know which inputs to expect (informational).
Send `{ "t": "device", "connected": false }` if the wheel unplugs.

**Input frame** — send at a **steady 100–250 Hz** while a wheel is present:
```json
{ "t": "input",
  "steer": -0.42,        // -1..1, ALREADY normalized across the device's full rangeDeg
  "throttle": 0.80,      // 0..1
  "brake": 0.00,         // 0..1
  "clutch": 0.35,        // 0..1  (0 = pedal up/engaged, 1 = floored/disengaged)
  "handbrake": 0.00,     // 0..1  (analog e-brake pull; omit if the device has none)

  // --- SHIFTING: PADDLE ONLY (no H-pattern / no sequential lever in v1) ---
  "shift": "up",         // "up" | "down"  ONE-SHOT edge — send ONCE per paddle pull. Omit the
                         //  key otherwise. If you send it every frame while held, it shifts repeatedly.
  "reverse": false,      // HELD state of the dedicated REVERSE button (true while held). NOT an
                         //  event — send current state each frame. See the reverse note below.

  // --- BUTTON BOX (see the button table below) ---
  "actions": {           // ONE-SHOT edge actions: include a key = true ONLY on the frame the
    "engine": true       // button is PRESSED. Omit it (or false) otherwise. Never repeat while
  },                     // held — each true fires the action once.
  "hold": {              // HELD actions: send the CURRENT state each frame (true while held).
    "lookBehind": false, // These are level-triggered (the game asserts the input while true).
    "horn": false
  },

  "rangeDeg": 900,       // optional echo of device range
  "ts": 172834 }         // optional ms timestamp (your clock)
```
- **`steer` normalization is YOUR job.** Read the raw axis (usually 0..65535), center it, divide by half-range so full left = -1, full right = +1, across the device's *configured* rotation (900°/1080°/etc.). The game maps -1..1 onto the car's soft lock.
- **PEDALS: always send them.** Do NOT assume GTA reads the wheel's pedals natively — many wheels split pedals onto a separate HID GTA ignores. The game feeds `throttle`/`brake` into GTA's own controls, so they must come from you. If the device lacks a pedal, **omit that key** (the game leaves it to keyboard/pad). `clutch` and `handbrake` likewise — omit if absent.
- Keep frames small and frequent. The game only ever uses the **latest** frame (no queue), so dropping an old one is fine.
- **`shift` is edge-only.** Emit `"shift":"up"` exactly once when a paddle is pulled, then send frames without the key. Repeating it every frame = repeated shifts.
- **Gear selection is the car's job.** In v1 there's no gear stick — the sim's DCT box handles gears. Paddles pull manual shifts; the **box selector button** (see button table) flips DCT auto↔manual; **neutral** and **reverse** are their own buttons. You don't report an absolute gear number.

### Reverse (REAL-CAR throttle-to-reverse — important)

Reverse is a **held button state**, NOT "brake to reverse." Report `"reverse": true` for as long as the dedicated reverse button is held, `false` otherwise. While it's held you drive backward with the **throttle pedal**, like a real car.

The game handles the rest: while reverse is held it **swaps the pedals** so your **throttle** pedal drives the car backward and your **brake** pedal stops it (this mirrors GTA's own control behavior in reverse gear, and trips the sim's reverse state so the HUD shows **R**). You do **not** send a special "go reverse" input — just keep sending your normal `throttle`/`brake` axes; the game routes them. Do **not** try to emulate brake-to-reverse yourself.

**Handshake reply** (optional): when you receive `{"t":"hello"}` from the game, reply with your `device` report immediately.

### Game → App

**Handshake** — the game sends this right after the socket opens:
```json
{ "t": "hello", "from": "hk-wheel", "v": 1 }
```

**FFB frame** — sent ~60 Hz while driving. Map each field to a DirectInput effect:
```json
{ "t": "ffb", "f": {
  "align":   -0.63,   // -1..1 SELF-ALIGNING TORQUE. Signed: negative = torque pushing
                      //   wheel left, positive = right. This is the main road feel.
                      //   → DirectInput CONSTANT FORCE, magnitude = align * masterGain.
  "slip":     0.20,   // 0..1 front grip loss (understeer). Wheel should go LIGHTER:
                      //   reduce the constant-force magnitude by (1 - slip*k), and/or
                      //   add a little noise. Classic "front washing out" cue.
  "surface":  0.15,   // 0..1 road/kerb rumble amplitude → small PERIODIC (sine) effect
                      //   or noise added on top of the constant force.
  "spring":   0.30    // 0..1 centering spring when nearly stopped (parking feel) →
                      //   DirectInput SPRING effect, or a center-seeking constant force.
} }
```
- You own a **master gain** slider (device-dependent; G29 vs a direct-drive base need very different scaling). The game sends normalized cues; you scale.
- Recommended effect setup: one persistent **ConstantForce** effect you update each frame with `align` (attenuated by `slip`), one **Spring** effect gated by `spring`, and optionally a **Periodic/Sine** for `surface`. Update magnitudes in place — don't recreate effects per frame.

**Runtime config push** (optional, ignore for v1):
```json
{ "t": "cfg", "c": { "wheelRangeDeg": 1080 } }
```

**Config from game on connect** — the game may also send `{"t":"cfg",...}`; safe to ignore for v1.

---

## Behavioral requirements

1. **Localhost only.** Bind `127.0.0.1:24897`. If you must change the port, it must match `Config.Port` in the resource's `config.lua`.
2. **Reconnect-friendly.** The game's NUI auto-reconnects every ~2s. Your server should accept a fresh client cleanly at any time (game restart, resource restart). Don't assume one connection for the process lifetime.
3. **Steady input rate.** A wheel feels laggy below ~100 Hz. Target 200 Hz if the device allows. Send even when values are unchanged (the game uses staleness > 250ms to decide the wheel is "gone").
4. **Graceful device loss.** If the wheel unplugs, stop input frames and send `{"t":"device","connected":false}` so the game fades steering back to keyboard/pad over ~250ms (no snap).
5. **FFB safety.** On disconnect / app exit, **stop and release all FFB effects** and set device autocenter back on, or the wheel can be left pulling. Wrap in try/finally.

---

## How the game uses each field (so your mapping matches intent)

| App field   | Game behavior |
|-------------|---------------|
| `steer`     | Mapped to the car's **soft lock** (per-class, e.g. Super = 36°, Muscle = 42°) with **speed-sensitive ratio** (calmer at 160 km/h+). Written via `SetVehicleSteeringAngle` for true 1:1, and also fed to the sim's steer input so physics + visuals agree. |
| `throttle`/`brake` | Fed into GTA's own controls (71/72) **from your frame** — this is what both the engine and the sim (`state.throttle`/`brake`) read. Fully analog. Omit a pedal key if the device lacks it. |
| `handbrake` | GTA has **no analog e-brake native**, so the game (a) holds the handbrake control past a threshold (drives launch-staging + reverse-gate-neutral logic that expects a boolean), and (b) optionally applies **progressive rear brake pressure** for a drift feel scaled by your 0..1 pull. Send the raw analog value; the game does both. |
| `clutch`    | Crossing the engage point (default 0.55 = floored) presses/releases `+hk_clutch`. Enables clutch launches / stall feel, and pressing the clutch drops a DCT back to auto. |
| `shift` (paddles) | One-shot `up`/`down` → `+hk_upshift`/`+hk_downshift`. Pulls a manual paddle shift. |
| `reverse` (held) | Real-car reverse: while held the game **swaps the pedals so throttle drives you backward** (see Reverse note). You never command "go reverse"; just keep sending pedal axes. |
| `box` button | Flips DCT **auto ↔ manual** (`hk-handling:SetBoxMode`). Gear stick is not used in v1 — this is how you choose auto vs paddle-manual. |

---

## Testing without the game

- **Loopback WS client:** write a 20-line test client that connects to your server, prints `input` frames, and periodically sends a fake `ffb` frame with `align` sweeping -1→1. Confirm the wheel pulls left/right and centers. This proves FFB before touching FiveM.
- **In-game check:** in FiveM, `/wheelstate` prints bridge/device/frame status and the live steering angle to F8. Use it to confirm frames are arriving and steering is being applied.
- **Config knobs** live in `[hk]/hk-wheel/config.lua` (soft-lock per class, speed reduction, FFB gains). Steering feel is tuned there; device master gain + axis calibration is tuned in the launcher's Wheel settings.
- **Note:** the `hk-wheel` resource currently sits in `[unused]/` on the server. To test in-game, move it to `[hk]/` and add `ensure hk-wheel` (after `hk-handling`) in `[hk]/resource.cfg`, then restart.

---

## Button box (map wheel buttons to these actions)

A wheel/rim has lots of buttons — let the user bind them on the settings page to the action
names below. Send **edge** actions in `frame.actions` (true only on the press frame) and
**held** actions in `frame.hold` (current state every frame). The game routes each to the
real in-game system (all verified against the live server).

**Edge actions** (`actions`, one-shot on press):

| action       | what it does in game |
|--------------|----------------------|
| `engine`     | Engine on/off (tap of the G-bind path — ownership/hotwire intact). |
| `hybrid`     | Cycle EV / Hybrid / Engine drive mode (only affects hybrid cars; calls `hk-handling:CycleHybridMode`). |
| `box`        | **Box selector** — flip DCT **auto ↔ manual** (calls `hk-handling:SetBoxMode('toggle')`; no-op on non-DCT). Use `boxAuto` / `boxManual` if you want two dedicated buttons instead of a toggle. |
| `neutral`    | Shift to/from **neutral** (emulates the box's both-paddle neutral chord). Standalone N button. |
| `seatbelt`   | Toggle seatbelt (fires `seatbelt:client:ToggleSeatbelt`). |
| `nosToggle`  | Arm / disarm NOS (jim `nosSwitch`). |
| `nosLevelUp` / `nosLevelDn` | NOS boost level up / down (jim `levelUP` / `levelDown`). |
| `headlight`  | Cycle headlights off/on (native). |
| `indLeft` / `indRight` / `hazards` | Turn indicators / hazards (native). |

**Held actions** (`hold`, state every frame while pressed):

| hold key    | what it does in game |
|-------------|----------------------|
| `lookBehind`| Look behind while held (native cam). |
| `lookLeft` / `lookRight` | Pan the in-car camera left/right (hat switch / POV). |
| `horn`      | Sound the horn while held. |
| `nosBoost`  | Fire NOS boost while held (jim `+nosBoost`/`-nosBoost`; the game edges it for you). |

Notes:
- **Edge vs held matters.** Put momentary "press to trigger" buttons in `actions` (engine,
  seatbelt, gear-adjacent). Put "do while pressed" in `hold` (horn, look, NOS fire). If you put
  a toggle in `hold` it'll fire every frame; if you put a look in `actions` it'll only blip once.
- Reverse is **not** here — it's part of the shifter (`gear:"R"` / `reverse:true`), see above.
- Clutch/throttle/brake/handbrake are **axes**, not buttons — see the input frame.
- Unknown action names are ignored by the game, so you can add bindings the app supports before
  the game maps them (they just no-op until wired). Ask before assuming a NEW action exists.

---

## Wheel settings (a view in the launcher's WebView2 UI)

Different people have different rigs, so add a **Wheel** view/tab to the existing launcher UI (WebView2) — not a separate window. Persist to the launcher's own settings store (its JSON config). Minimum controls:

**Device**
- Device picker (list DirectInput FFB devices; remember by product GUID).
- Wheel rotation range (deg): 270 / 360 / 540 / 720 / 900 / 1080 / custom. Report as `rangeDeg`.
- Per-axis calibration: assign which axis is steer/throttle/brake/clutch/handbrake, invert toggle, min/max range, deadzone. (Wheels vary wildly — combined-pedal, split-pedal, inverted brake, etc.)

**Shifting (v1: paddle only)**
- Bind the up/down **paddles** → one-shot `shift` (`up`/`down`).
- Bind a **reverse** button → held `reverse` bool.
- Bind a **box** button → DCT auto↔manual (the `box` action).
- Bind a **neutral** button → the `neutral` action.
- (No H-pattern / sequential-lever mapping in v1 — deferred.)

**Buttons** (bind rim/box buttons to actions)
- A binding list: for each physical button, pick an action from the Button Box tables
  (engine, hybrid, neutral, seatbelt, nosToggle, nosLevelUp/Dn, headlight, indLeft/Right,
  hazards) or a held action (lookBehind, lookLeft/Right, horn, nosBoost).
- Remember which are edge vs held (the tables say which) so you emit them in the right frame field.

**Force Feedback**
- Master gain (0–100%) — **critical**, a G29 and a direct-drive base need wildly different scaling.
- Optional per-cue trims (align / spring / surface) if you want them, but master gain is the must-have.
- "Stop FFB" panic button.

**Connection**
- Port (default 24897, must match the resource's `Config.Port`).
- Connection status indicator (connected to game / waiting).

Keep it simple — one launcher view with tabs (Device / Shifter / Buttons / FFB) is plenty. The game reads whatever you report; there's no in-game settings UI for device stuff (it all lives in the launcher).

---

## Anti-cheat note

This design is safe because the wheel module only does **HID read + localhost WebSocket** (it never touches the game process), and the only game-side code is a normal resource using **documented natives** (`SetVehicleSteeringAngle`, `SetControlNormal`) + NUI WebSocket to localhost. There is **no memory access, no injection, no ScriptHookV** — the launcher must never attach to or read the game's memory. Keep the wheel module a pure HID + WebSocket bridge.

---

## Deliverable checklist for the wheel module

- [ ] Enumerates DirectInput FFB devices; picks the wheel (config or first FFB device).
- [ ] Reports `device` (name, rangeDeg, capabilities) on connect + on change.
- [ ] Streams `input` frames at ≥100 Hz with correctly normalized `steer`.
- [ ] Sends `throttle`/`brake`/`clutch`/`handbrake` as 0..1 (omit any axis the device lacks).
- [ ] **Paddle shift:** one-shot `shift` (`up`/`down`), never repeated while held.
- [ ] **Reverse:** held `reverse` bool; the game swaps pedals so throttle reverses. Do NOT emulate brake-to-reverse.
- [ ] **Box selector** button → `box` action (DCT auto↔manual). **Neutral** button → `neutral` action.
- [ ] Button box: bindable buttons → `actions` (edge) + `hold` (held) per the Button Box tables (engine/hybrid/neutral/seatbelt/nos/lights/look/horn).
- [ ] Hosts `ws://127.0.0.1:24897`, reconnect-tolerant.
- [ ] Applies `ffb` frames: constant force (align, attenuated by slip), spring (spring), optional periodic (surface).
- [ ] Settings page: device picker, rotation range, per-axis calibration/invert/deadzone, shifter style, FFB master gain + panic-stop, port.
- [ ] Persists settings to a local JSON file.
- [ ] Releases FFB + restores autocenter on exit/disconnect.
- [ ] Compiles into `LauncherHost` (no separate exe); WS server starts with the launcher; settings live in a WebView2 view.
