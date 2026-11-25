fx_version 'cerulean'
game 'gta5'

-- hk-emotemenu — HOMEKONG emote system.
-- Forked from dpemotes: playback engine + all animations:client:* events are
-- kept byte-for-byte so the ~134 job integrations that call EmoteCommandStart
-- etc. keep working. Only the old NativeUI menu is replaced by the HTML NUI
-- below (see Client/EmoteMenu.lua for the bridge).

ui_page 'html/index.html'

files {
	'html/index.html',
	'html/style.css',
	'html/app.js',
}

client_scripts {
	'Config.lua',
	'Categories.lua',
	'Client/*.lua'
}

server_scripts {
	'@oxmysql/lib/MySQL.lua',
	'Config.lua',
	'Server/*.lua'
}
