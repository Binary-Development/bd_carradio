local radios = {}
local levels = {}
local repeats = {}
local viewers = {}
local lastRequest = {}
local lastSearch = {}
local playing = 0
local globalSession = 0

local streamToken = ('%s-%d'):format(GetCurrentResourceName(), math.random(100000, 999999))

SetHttpHandler(function(request, response)
    if request.path == '/health' then
        response.writeHead(200, {
            ['Content-Type'] = 'text/plain',
            ['Access-Control-Allow-Origin'] = '*',
            ['Cache-Control'] = 'no-store',
        })

        response.send(streamToken)
        return
    end

    local id = request.path:match('^/stream/([%w_-]+)$')
    if not id or #id ~= 11 then
        response.writeHead(404, { ['Access-Control-Allow-Origin'] = '*' })
        response.send('')
        return
    end

    local range = request.headers and (request.headers.Range or request.headers.range)
    local fetched = Stream.fetch(id, range)

    if not fetched then
        response.writeHead(404, { ['Access-Control-Allow-Origin'] = '*' })
        response.send('')
        return
    end

    local headers = {
        ['Content-Type'] = fetched.mime or 'audio/mp4',
        ['Access-Control-Allow-Origin'] = '*',
        ['Accept-Ranges'] = 'bytes',
        ['Cache-Control'] = 'public, max-age=300',
    }

    if type(fetched.headers) == 'table' then
        local contentRange = fetched.headers['Content-Range'] or fetched.headers['content-range']
        local contentLength = fetched.headers['Content-Length'] or fetched.headers['content-length']
        if contentRange then headers['Content-Range'] = contentRange end
        if contentLength then headers['Content-Length'] = contentLength end
    end

    if not headers['Content-Length'] and fetched.body then
        headers['Content-Length'] = tostring(#fetched.body)
    end

    response.writeHead(fetched.status, headers)
    response.send(fetched.body)
end)

local function checkStreamUrl()
    if config.audioUrl == '' then
        Log.print('audiourl is empty - using ^6youtube^7 iframe playback')
        return
    end

    local base = config.audioUrl:gsub('/+$', '')

    if not base:match('^https://') then
        Log.print('audiourl must use ^6https^7 - check ^6shared/config.lua^7')
        return
    end

    PerformHttpRequest(base .. '/health', function(status, body)
        if status == 200 and body == streamToken then
            Log.print(('stream proxy connected at ^6%s^7'):format(base))
            return
        end

        Log.print(('stream proxy failed for ^6%s^7 (%s)'):format(base, tostring(status)))
    end, 'GET')
end

local function getVehicle(netId)
    if type(netId) ~= 'number' then return nil end

    local vehicle = NetworkGetEntityFromNetworkId(netId)
    if vehicle == 0 or not DoesEntityExist(vehicle) or GetEntityType(vehicle) ~= 2 then return nil end
    if NetworkGetNetworkIdFromEntity(vehicle) ~= netId then return nil end

    return vehicle
end

local function isOccupant(source, netId)
    local vehicle = getVehicle(netId)
    return vehicle ~= nil and GetVehiclePedIsIn(GetPlayerPed(source), false) == vehicle
end

local function canControl(source, netId)
    if config.permission ~= '' and not IsPlayerAceAllowed(source, config.permission) then
        return false, 'no permission'
    end

    local vehicle = getVehicle(netId)
    if not vehicle then return false, 'vehicle is gone' end

    local ped = GetPlayerPed(source)
    if GetVehiclePedIsIn(ped, false) ~= vehicle then return false, 'you are not in this vehicle' end

    if not config.passengersCanControl and GetPedInVehicleSeat(vehicle, -1) ~= ped then
        return false, 'only the driver can change the radio'
    end

    return true
end

local function isBlocked(track)
    for i = 1, #config.blockedSongs do
        if config.blockedSongs[i] == track.id then return true end
    end

    local haystack = (track.title .. ' ' .. track.author):lower()

    for i = 1, #config.blockedWords do
        if haystack:find(config.blockedWords[i], 1, true) then return true end
    end

    return false
end

local function throttled(source)
    local now = GetGameTimer()
    local last = lastRequest[source]
    if last and now - last < config.advanced.requestCooldownMs then return true end

    lastRequest[source] = now
    return false
end

local function searchThrottled(source)
    local now = GetGameTimer()
    local last = lastSearch[source]
    if last and now - last < config.advanced.searchCooldownMs then return true end

    lastSearch[source] = now
    return false
end

local function clock()
    return GetGameTimer() / 1000
end

local function elapsed(radio)
    if not radio.track then return 0 end
    if not radio.playing then return radio.offset end

    return math.min(radio.offset + (clock() - radio.stampedAt), radio.track.duration)
end

local function stamp(radio, offset)
    radio.offset = math.max(0, offset or elapsed(radio))
    radio.stampedAt = clock()
    radio.epoch = radio.epoch + 1
    radio.sequence = (radio.sequence or 0) + 1
end

local function snapshot(radio)
    if not radio or not radio.track then return false end

    return {
        id = radio.track.id,
        title = radio.track.title,
        author = radio.track.author,
        duration = radio.track.duration,
        thumb = radio.track.thumbnail,
        playing = radio.playing,
        loading = radio.arming ~= nil,
        volume = radio.volume,
        offset = radio.offset,
        age = radio.playing and math.max(clock() - radio.stampedAt, 0) or 0,
        epoch = radio.epoch,
        sequence = radio.sequence or 0,
        session = radio.session,
    }
end

local function publish(netId)
    local vehicle = getVehicle(netId)
    if not vehicle then return end

    local radio = radios[netId]
    local payload = snapshot(radio)

    Entity(vehicle).state:set('binaryRadio', payload, true)

    for source, watching in pairs(viewers) do
        if watching == netId then
            TriggerClientEvent('binary-radio:client:changedRadio', source, netId, payload)
        end
    end
end

local function reconcile(source, netId)
    if viewers[source] ~= netId then return end

    TriggerClientEvent('binary-radio:client:changedRadio', source, netId, snapshot(radios[netId]))
end

local volumeCoalesceMs = 250
local volumeThrottle = {}

local function flushVolume(netId)
    local held = volumeThrottle[netId]
    if not held then return end

    if not held.dirty then
        volumeThrottle[netId] = nil
        return
    end

    held.dirty = false
    publish(netId)
    SetTimeout(volumeCoalesceMs, function() flushVolume(netId) end)
end

local function publishVolume(netId)
    local held = volumeThrottle[netId]

    if held then
        held.dirty = true
        return
    end

    volumeThrottle[netId] = { dirty = false }
    publish(netId)
    SetTimeout(volumeCoalesceMs, function() flushVolume(netId) end)
end

local function pushRepeat(netId)
    local radio = radios[netId]
    if not radio then return end

    for source, watching in pairs(viewers) do
        if watching == netId then
            TriggerClientEvent('binary-radio:client:changedRepeat', source, netId, radio.repeatOn)
        end
    end
end

local function pushQueue(netId)
    local radio = radios[netId]
    local queue = radio and radio.queue or {}

    for source, watching in pairs(viewers) do
        if watching == netId then
            TriggerClientEvent('binary-radio:client:changedQueue', source, netId, queue)
        end
    end
end

local function stopRadio(netId)
    if not radios[netId] then return end

    local vehicle = getVehicle(netId)
    radios[netId] = nil
    playing = math.max(0, playing - 1)

    if vehicle then
        Entity(vehicle).state:set('binaryRadio', false, true)
    end

    for source, watching in pairs(viewers) do
        if watching == netId then
            TriggerClientEvent('binary-radio:client:changedRadio', source, netId, false)
        end
    end

    pushQueue(netId)
end

local function startRadio(netId, source)
    local radio = radios[netId]
    if radio then return radio end
    if playing >= config.advanced.maxRadiosPlaying then return nil end

    globalSession = globalSession + 1

    radio = {
        queue = {},
        volume = levels[netId] or 0.5,
        repeatOn = repeats[netId] or false,
        playing = false,
        offset = 0,
        stampedAt = clock(),
        epoch = 0,
        owner = source,
        session = globalSession,
    }

    radios[netId] = radio
    playing = playing + 1

    return radio
end

local armWindowMs = 120000

local function arm(radio, track)
    radio.track = track
    radio.playing = false
    radio.arming = GetGameTimer() + armWindowMs
    stamp(radio, 0)
    Stream.prefetch(track.id)
end

local function begin(netId)
    local radio = radios[netId]
    if not radio or not radio.arming then return end

    radio.arming = nil
    radio.playing = true
    stamp(radio, 0)
    publish(netId)
end

local function restart(netId)
    local radio = radios[netId]
    if not radio then return end

    stamp(radio, 0)
    publish(netId)
end

local function playNext(netId)
    local radio = radios[netId]
    if not radio then return end

    if radio.repeatOn and radio.track then
        restart(netId)
        return
    end

    local track = table.remove(radio.queue, 1)
    if not track then return stopRadio(netId) end

    arm(radio, track)
    publish(netId)
    pushQueue(netId)
end

Callback.register('binary-radio:opened', function(source, netId)
    if not isOccupant(source, netId) then
        viewers[source] = nil
        return { canControl = false, reason = 'you are not in this vehicle', queue = {}, volume = 0.5 }
    end

    local allowed, reason = canControl(source, netId)
    local radio = radios[netId]
    viewers[source] = netId

    return {
        canControl = allowed,
        reason = reason,
        queue = radio and radio.queue or {},
        volume = radio and radio.volume or 0.5,
        repeatOn = radio and radio.repeatOn or false,
    }
end)

Callback.register('binary-radio:searched', function(source, query)
    if searchThrottled(source) then return { ok = false, error = 'slow down' } end
    if type(query) ~= 'string' or #query < 2 or #query > 120 then
        return { ok = false, error = 'invalid search' }
    end

    return Youtube.search(query)
end)

local function applyTracks(radio, netId, tracks, mode)
    local accepted = {}

    for i = 1, #tracks do
        local track = tracks[i]
        if type(track) == 'table' and track.id and not isBlocked(track) then
            accepted[#accepted + 1] = track
        end
    end

    if #accepted == 0 then
        return false, 'every track in that playlist is blocked'
    end

    if mode == 'queue' and radio.track then
        for i = 1, #accepted do
            if #radio.queue >= config.queueSize then break end
            radio.queue[#radio.queue + 1] = accepted[i]
        end

        pushQueue(netId)
        return true, accepted[1], #accepted
    end

    arm(radio, accepted[1])

    for i = 2, #accepted do
        if #radio.queue >= config.queueSize then break end
        radio.queue[#radio.queue + 1] = accepted[i]
    end

    publish(netId)
    pushQueue(netId)

    return true, accepted[1], #accepted
end

Callback.register('binary-radio:requested', function(source, netId, query, mode)
    if type(netId) ~= 'number' then return { ok = false, error = 'invalid vehicle' } end
    if throttled(source) then return { ok = false, error = 'slow down' } end

    local allowed, reason = canControl(source, netId)
    if not allowed then return { ok = false, error = reason } end
    if type(query) ~= 'string' or #query < 2 or #query > 300 then
        return { ok = false, error = 'invalid link' }
    end

    local radio = startRadio(netId, source)
    if not radio then return { ok = false, error = 'too many radios playing right now' } end

    local queued = mode == 'queue'
    if queued and #radio.queue >= config.queueSize then
        return { ok = false, error = 'queue is full' }
    end

    local result = Youtube.resolve(query)
    local empty = not radio.track and #radio.queue == 0

    if not result.ok then
        if empty then stopRadio(netId) end
        return result
    end

    if type(result.tracks) == 'table' and result.playlist then
        local ok, track, count = applyTracks(radio, netId, result.tracks, mode)
        if not ok then
            if empty then stopRadio(netId) end
            return { ok = false, error = track or 'could not queue that playlist' }
        end

        return { ok = true, track = track, playlist = true, count = count, notice = result.notice }
    end

    if type(result.track) ~= 'table' then
        if empty then stopRadio(netId) end
        return { ok = false, error = 'could not read that link' }
    end

    if isBlocked(result.track) then
        if empty then stopRadio(netId) end
        return { ok = false, error = 'that track is blocked' }
    end

    if queued and radio.track then
        if #radio.queue >= config.queueSize then
            return { ok = false, error = 'queue is full' }
        end

        radio.queue[#radio.queue + 1] = result.track
        pushQueue(netId)
    else
        arm(radio, result.track)
        publish(netId)
    end

    return { ok = true, track = result.track }
end)

RegisterNetEvent('binary-radio:server:changedPlayback', function(netId, action, value)
    local source = source
    if type(netId) ~= 'number' or type(action) ~= 'string' then return end

    if not canControl(source, netId) then
        reconcile(source, netId)
        return
    end

    local radio = radios[netId]

    if not radio then
        reconcile(source, netId)
        return
    end

    if radio.arming and (action == 'playing' or action == 'seek' or action == 'nudge') then
        reconcile(source, netId)
        return
    end

    if action == 'playing' and type(value) == 'boolean' then
        if radio.playing == value then
            reconcile(source, netId)
            return
        end

        stamp(radio)
        radio.playing = value
    elseif action == 'seek' and type(value) == 'number' and radio.track then
        stamp(radio, math.min(math.max(value, 0), radio.track.duration))
    elseif action == 'nudge' and type(value) == 'number' and radio.track then
        stamp(radio, math.min(math.max(elapsed(radio) + value, 0), radio.track.duration))
    elseif action == 'volume' and type(value) == 'number' then
        radio.volume = math.min(math.max(value, 0), 1)
        levels[netId] = radio.volume
        publishVolume(netId)

        return
    elseif action == 'repeat' and type(value) == 'boolean' then
        radio.repeatOn = value
        repeats[netId] = value
        pushRepeat(netId)

        return
    elseif action == 'skip' and type(value) == 'number' then
        if value >= 0 then
            playNext(netId)
        else
            restart(netId)
        end

        return
    elseif action == 'stop' then
        return stopRadio(netId)
    else
        reconcile(source, netId)
        return
    end

    publish(netId)
end)

RegisterNetEvent('binary-radio:server:changedQueue', function(netId, action, index)
    local source = source
    if type(netId) ~= 'number' or type(action) ~= 'string' or type(index) ~= 'number' then return end
    if not canControl(source, netId) then return end

    local radio = radios[netId]
    if not radio then return end

    if action ~= 'play' and action ~= 'remove' then return end

    local track = radio.queue[index]
    if not track then return end

    table.remove(radio.queue, index)

    if action == 'play' then
        arm(radio, track)
        publish(netId)
    end

    pushQueue(netId)
end)

RegisterNetEvent('binary-radio:server:readiedTrack', function(netId, trackId)
    if type(netId) ~= 'number' or type(trackId) ~= 'string' then return end

    local radio = radios[netId]
    if not radio or not radio.arming or not radio.track then return end
    if radio.track.id ~= trackId then return end

    begin(netId)
end)

RegisterNetEvent('binary-radio:server:endedTrack', function(netId)
    if type(netId) ~= 'number' then return end

    local radio = radios[netId]
    if not radio or not radio.track or not radio.playing then return end
    if radio.track.duration - elapsed(radio) > 5 then return end

    playNext(netId)
end)

RegisterNetEvent('binary-radio:server:closedPanel', function()
    viewers[source] = nil
end)

AddEventHandler('playerDropped', function()
    local dropped = source
    lastRequest[dropped] = nil
    lastSearch[dropped] = nil
    viewers[dropped] = nil
end)

AddEventHandler('entityRemoved', function(entity)
    local netId = NetworkGetNetworkIdFromEntity(entity)
    if not netId or netId == 0 or not radios[netId] then return end

    stopRadio(netId)
end)

CreateThread(function()
    while true do
        Wait(2000)

        for netId, radio in pairs(radios) do
            if not getVehicle(netId) then
                stopRadio(netId)
            elseif radio.arming then
                if GetGameTimer() > radio.arming then begin(netId) end
            elseif radio.track and radio.playing and elapsed(radio) >= radio.track.duration then
                playNext(netId)
            end
        end
    end
end)

CreateThread(function()
    while true do
        Wait(60000)

        for netId in pairs(levels) do
            if not radios[netId] and not getVehicle(netId) then levels[netId] = nil end
        end

        for netId in pairs(repeats) do
            if not radios[netId] and not getVehicle(netId) then repeats[netId] = nil end
        end
    end
end)

AddEventHandler('onResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then return end

    Youtube.configure(config.youtubeApiKey, {
        maxDurationSeconds = config.maxSongMinutes * 60,
        searchResults = config.searchResults,
        playlistMaxTracks = config.maxPlaylistTracks,
        timeoutMs = config.advanced.apiTimeoutMs,
    })

    if config.youtubeApiKey == '' then
        Log.print('missing ^6youtube^7 api key - set ^6youtubeApiKey^7 in ^6shared/config.lua^7')
        return
    end

    local version = Version.current()
    Log.print(('loaded v%s'):format(version))
    SetTimeout(3000, checkStreamUrl)
    SetTimeout(5000, Version.check)
end)

exports('stressArm', function(netId, track)
    if type(netId) ~= 'number' or type(track) ~= 'table' then return false, 'invalid args' end
    if not getVehicle(netId) then return false, 'vehicle missing' end

    local radio = startRadio(netId, 0)
    if not radio then return false, 'radio cap reached' end

    arm(radio, {
        id = track.id,
        title = track.title or 'Stress Test',
        author = track.author or 'Benchmark',
        duration = tonumber(track.duration) or 180,
        thumbnail = track.thumbnail or track.thumb or '',
    })
    begin(netId)

    return true
end)

exports('stressStop', function(netId)
    if type(netId) ~= 'number' or not radios[netId] then return false end
    stopRadio(netId)
    return true
end)

exports('stressStopAll', function()
    for netId in pairs(radios) do
        stopRadio(netId)
    end
end)

exports('stressBumpAll', function()
    local started = GetGameTimer()

    for netId, radio in pairs(radios) do
        if radio.track then
            stamp(radio)
            publish(netId)
        end
    end

    return GetGameTimer() - started
end)

exports('stressStats', function()
    local active = 0
    for _ in pairs(radios) do active = active + 1 end

    return {
        active = active,
        cap = config.advanced.maxRadiosPlaying,
        playing = playing,
    }
end)
