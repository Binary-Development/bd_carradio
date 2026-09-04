config = {
    command = 'carradio',
    keybind = 'G',
    permission = '',
    passengersCanControl = true,

    hearingDistance = 24.0,
    outsideVolume = 0.7,

    maxSongMinutes = 15,
    queueSize = 25,
    searchResults = 24,
    maxPlaylistTracks = 50,

    blockedSongs = {},
    blockedWords = {},

    audioUrl = '',

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

        cacheMaxBytes = 8 * 1024 * 1024 * 1024,
        cacheDays = 14,

        transferBytesPerSecond = 2097152,
        parallelTransfers = 6,

        resolverTimeoutMs = 45000,
        parallelDownloads = 3,
        autoUpdateHours = 12,
    },
}
