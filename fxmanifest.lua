fx_version 'cerulean'
game 'gta5'
lua54 'yes'

author 'Binary Development'
description 'Vehicle radio streaming YouTube audio with true 3D positional sound, no YouTube API and no iframes'
version '1.0.0'

ui_page 'web/dist/index.html'

shared_scripts {
    'shared/config.lua',
    'shared/callback.lua',
}

client_scripts {
    'client/vehicle.lua',
    'client/emitters.lua',
    'client/main.lua',
    'client/nui.lua',
}

node_version '22'

server_scripts {
    'server/main.lua',
    'server/resolver.js',
}

files {
    'web/dist/index.html',
    'web/dist/assets/*.js',
    'web/dist/assets/*.css',
    'web/dist/assets/*.woff2',
}
