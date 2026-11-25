fx_version 'cerulean'
game 'gta5'

-- hk-whysthisdealer — HOMEKONG "Why's This Dealer?" bouncing-Yaris meme.
-- Toggle: your current vehicle hops on its suspension in time to the beat,
-- synced with the meme audio for every nearby player.
-- Physics bounce = per-BEAT upward impulse (owner-only, net-synced), NOT
-- per-frame, so it won't flood the physics solver.
-- Standalone for now; the playback engine is written so it can be folded
-- into hk-emotemenu later as a "Vehicle Emote" section.

ui_page 'html/index.html'

files {
	'html/index.html',
	'html/style.css',
	'html/app.js',
	'html/whysthisdealer.mp3',
}

shared_script 'config.lua'
client_script 'client.lua'
server_script 'server.lua'
