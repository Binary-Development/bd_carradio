fx_version 'cerulean'
game 'gta5'
lua54 'yes'

author 'Binary Development'
description 'Vehicle radio streaming YouTube audio with true 3D positional sound via the YouTube API'
version '1.0.1'

ui_page 'web/dist/index.html'

shared_scripts {
    'shared/config.lua',
    'shared/log.lua',
    'shared/callback.lua',
}

client_scripts {
    'client/vehicle.lua',
    'client/emitters.lua',
    'client/main.lua',
    'client/nui.lua',
}

server_scripts {
    'server/youtube.lua',
    'server/stream.lua',
    'server/version.lua',
    'server/main.lua',
}

files {
    'web/dist/index.html',
    'web/dist/assets/*.js',
    'web/dist/assets/*.css',
    'web/dist/assets/*.woff2',
}
