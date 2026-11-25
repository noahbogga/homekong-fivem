fx_version 'cerulean'
game 'gta5'

name 'hk-vehiclesales'
description 'HOMEKONG Used Vehicle Sales'
author 'HOMEKONG'
version '2.0.0'

ui_page 'html/ui.html'

shared_script 'config.lua'

client_scripts { 
	'@PolyZone/client.lua',
	'@PolyZone/BoxZone.lua',
	'@PolyZone/EntityZone.lua',
	'@PolyZone/CircleZone.lua',
	'@PolyZone/ComboZone.lua',
	'client/main.lua'
}

server_scripts {
	'@oxmysql/lib/MySQL.lua',
	'server/main.lua'
}

files {
	'html/reset.css',
	'html/new-sell-contract.png',
	'html/new-buy-contract.png',
	'html/ui.css',
	'html/ui.html',
	'html/ui.js',
}

lua54 'yes' 