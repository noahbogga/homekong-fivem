# hk-vehiclesales
HOMEKONG Used Vehicle Sales — player-to-player used car lot. :blue_car:

Originally based on a QB-Core used-car script, rebuilt and maintained in-house
for HOMEKONG. Notably **self-contained vehicle ownership checks** — it no longer
depends on a garage resource exposing `checkVehicleOwner`, which silently broke
selling on modern `qb-garages` builds. This fixed fork is HOMEKONG-only.

## Dependencies
- qb-core
- PolyZone (zones)
- qb-target (optional — set `UseTarget` convar to `true`)
- qb-menu (sell/sell-back menu)
- qb-phone (sale e-mail to the seller)
- qb-log (event logging)
- oxmysql

## Features
- Put your owned vehicle on sale for other players to buy
- Take your vehicle back if it has not sold yet
- Sell your vehicle directly to the dealer for a fixed payout
- Self-contained ownership + finance check (no external garage callback needed)

## Installation
- Place this folder in the `[qb]` resources directory (auto-started via `ensure [qb]`).
- Import `hk-vehiclesales.sql` into your database (creates `occasion_vehicles`).
- It also reads the standard `player_vehicles` / `players` tables.

## Configuration
Lot locations live in `config.lua` under `Config.Zones`. Each zone defines a
`BusinessName`, the `SellVehicle` / `BuyVehicle` points, a `PolyZone` boundary,
and the `VehicleSpots` where listed cars are displayed. Add more `VehicleSpots`
entries to expand display capacity, or add another keyed entry to `Config.Zones`
to run a second lot.

To adjust the tax cut, edit the `77` (percent paid out to the seller) in
`server/main.lua` (buyVehicle handler) and the matching display math in
`html/ui.js` `calculatePrice()`.
