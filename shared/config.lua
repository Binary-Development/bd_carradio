config = {
    command = 'carradio',
    keybind = 'G',
    permission = '',
    passengersCanControl = true,

    -- credentials: https://console.cloud.google.com/apis/credentials
    -- enable the api: https://console.cloud.google.com/apis/library/youtube.googleapis.com
    youtubeApiKey = 'AIzaSyD2kqbWY7UzWWuJFWfWTfh43SQFmiusW88',

    -- public https url that reverse-proxies this resource's /stream endpoint (3d web audio)
    -- leave empty to use the youtube iframe player instead
    audioUrl = '',

    hearingDistance = 24.0,
    outsideVolume = 0.7,

    maxSongMinutes = 15,
    queueSize = 25,
    searchResults = 24,
    maxPlaylistTracks = 50,

    blockedSongs = {},
    blockedWords = {},

    advanced = {
        fullVolumeDistance = 3.0,
        falloff = 1.35,
        fadeMs = 90,

        sealedCutoff = 620.0,
        occludedCutoff = 1800.0,
        openCutoff = 20000.0,
        insideVolume = 1.0,
        doorAperture = 0.5,

        requestCooldownMs = 2500,
        searchCooldownMs = 600,

        maxRadiosPlaying = 64,
        maxRadiosHeard = 6,

        apiTimeoutMs = 30000,
    },
}
