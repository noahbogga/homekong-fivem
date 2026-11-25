**# Informal intro**

This is a pile of vibe-coded FiveM resources that used to run on **HOMEKONG**, a Hong Kong-themed GTA V roleplay server.

The server (and these scripts) have been shut down. Co-owner wasn’t cooperative and eventually forced me to quit cold-handed. After that there wasn’t much point in keeping the project going, so I pulled the plug and rather just dump these scripts out here than leave them sitting cold in storage forever.

Few of the scripts require your own hosting system, and another few script require to build an external backend system (hk-sportsbetting, hk-wheel etc)

**There will be no more updates from me.**  
No bug fixes, no new features, no compatibility patches for future game builds or QBCore versions. Consider this project frozen.

That said, it’s GPL-3.0. If you want to take any of this, fix it, improve it, or turn it into something else, you’re free to fork/branch it. Just keep the licence and credit where it’s due.

---

**# HOMEKONG FiveM Resources**

Custom FiveM resources originally written for **HOMEKONG**, a Hong Kong-themed GTA V roleplay server (QBCore framework, game build 3258+).

Shared by [**noahbogga**](https://github.com/noahbogga) under the GPL-3.0 licence.  
You’re free to use, modify, and share these as long as you credit **noahbogga** and keep your changes under GPL-3.0 as well (see [Licence](#licence)).

## Resources
| Resource | What it does |
|---|---|
| `hk-chat` | Tabbed chat in HOMEKONG style. Replaces the stock chat resource. |
| `hk-crafting` | Portable crafting tables: place a bench from an item, target it, craft from materials with optional blueprint gates, pick it back up. |
| `hk-debugtracker` | Server performance and telemetry tracker with anti-cheat checks, optional flood alerts to Discord, and screenshot upload to Zipline. |
| `hk-documents` | Document system (licences, A4 documents, certificates) with per-job branding, server-checked create/edit/delete, Zipline image attachments and a browser upload portal. |
| `hk-drugsell` | Drug selling to NPCs through a dialog, using qb-target. Optional AI-generated NPC lines. |
| `hk-emotemenu` | Emote menu forked from dpemotes. The playback engine and all `animations:client:*` events are unchanged so job integrations keep working; only the old NativeUI menu is replaced with an HTML NUI. |
| `hk-freecam` | Admin cinematic free camera. |
| `hk-handling` | Vehicle dynamics: traction control, ABS, drift mode, downforce, ESC, wheelie, launch control, and manual / sequential / DCT gearbox modes. Gearbox guides in English and Chinese. |
| `hk-hub` | Branded F5 hub that opens the server's systems (settings, squads, coins, links). |
| `hk-hud` | Player status HUD. Replaces ps-hud and keeps its event contract; the vehicle gauge is hk-speedo. |
| `hk-imagecreator` | Captures vehicle, item and photo images in game and uploads them to Zipline. |
| `hk-livery` | Custom vehicle livery editor. |
| `hk-loading` | Loading screen (images, music, tips). Based on lj-loading. |
| `hk-optimizer` | FPS optimizer: admins tune render modes (Quality / Balance / Enhanced FPS+) saved to MySQL; players pick one in the HUD settings. |
| `hk-parking` | Street parking and garages in one, with a live 3D vehicle preview and phone locating. Based on mh-parking and qb-garages. |
| `hk-race` | Admin-built street races: `/raceadmin` editor, `/racemenu` host picker, native checkpoints, cash rewards scaled by turnout, vehicle tiers from hk-handling. |
| `hk-racecam` | Dynamic race camera that engages when idle and frames each vehicle differently. |
| `hk-scenario` | In-game scenario builder: area cleaner, AI path blockers and placeable props with qb-target hooks. |
| `hk-speedo` | Racing speedometer: dual-ring SVG gauge with glow and a launch-control indicator. |
| `hk-sportsbetting` | "Steak", an in-game sportsbook and casino (React NUI). Needs a separate odds engine service, not included. |
| `hk-vehiclesales` | Used vehicle sales between players. |
| `hk-vehlib` | Shared vehicle utility layer that hk-handling, hk-speedo and the other vehicle scripts build on. |
| `hk-weathersystem` | Real Hong Kong weather in game: reads the Hong Kong Observatory's current report every 10 minutes and cycles matching GTA weather. |
| `hk-wheel` | (very unfinished) Steering-wheel bridge: takes input from a local DirectInput companion app over a localhost WebSocket into hk-handling and sends force-feedback data back. |
| `hk-whysthisdealer` | "Why's This Dealer?" meme: your car bounces to the beat, synced for nearby players. **Bring your own audio** (see its README). |

## Requirements
- QBCore (`qb-core`), `ox_lib`, `oxmysql`.
- Some resources also use `qb-target` or `qb-inventory`; each `fxmanifest.lua` lists its own dependencies.

## Install
1. Copy the folders from `resources/` into your server's `resources/[hk]/`.
2. Run the `.sql` files that ship with hk-documents, hk-emotemenu, hk-handling, hk-hub, hk-parking and hk-vehiclesales.
3. Add `exec resources/[hk]/resource.cfg` to `server.cfg`, or `ensure` the ones you want. Load order matters: `hk-vehlib` first, then the vehicle scripts.
4. Fill in the settings marked `YOUR_…`, `CHANGE_ME_…` or `example.com`. Each resource's README has a **Setup** section listing exactly what to set.

## Placeholders to replace
| Placeholder | Where | What to put |
|---|---|---|
| `YOUR_DISCORD_ID`, `YOUR_LICENSE2_ID`, `YOUR_FIVEM_ID` | staff allowlists in hk-chat, hk-debugtracker, hk-scenario, hk-optimizer | your staff identifiers |
| `YOUR_SERVICES_HOST`, `YOUR_ODDS_ENGINE_HOST` | hk-debugtracker, hk-documents, hk-drugsell, hk-sportsbetting | the host running your Zipline / NPC gateway / odds engine |
| `images.example.com`, `docs.example.com`, `games.example.com` | hk-documents, hk-imagecreator, hk-hub, hk-sportsbetting | your own domains |
| `CHANGE_ME_…` tokens and secrets | hk-documents, hk-drugsell, hk-sportsbetting | your own long random values |
| empty `webhook` / `UploadToken` | hk-debugtracker, hk-hub, hk-imagecreator | your Discord webhooks and Zipline token |
| `https://discord.gg/YOUR_INVITE` | hk-hub | your Discord invite |

## Licence
Copyright (C) 2026 **noahbogga** ([github.com/noahbogga](https://github.com/noahbogga)).

This project is licensed under the **GNU General Public License v3.0**; see [`LICENSE`](LICENSE). In short: you may use, modify and redistribute it, including commercially, as long as you **keep the credit to noahbogga** and the licence notice, and release your modified versions under GPL-3.0 with their source.

Credits for the code some resources build on:
- `hk-emotemenu`: [dpemotes](https://github.com/andristum/dpemotes) by andristum (GPL-3.0).
- `hk-parking`: [mh-parking](https://github.com/MaDHouSe79/mh-parking) by MaDHouSe79 (MIT) and [qb-garages](https://github.com/qbcore-framework/qb-garages) by the QBCore Framework team (GPL-3.0).
- `hk-hud`: keeps the event contract of [ps-hud](https://github.com/Project-Sloth/ps-hud) by Project Sloth (GPL-3.0).
- `hk-loading`: [lj-loading](https://github.com/loljoshie/lj-loading) by loljoshie.

## Security
No real credentials are in this repository or its history. If you find one, please open an issue.
