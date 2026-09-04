local radios = {}
local levels = {}
local viewers = {}
local lastRequest = {}
local lastSearch = {}
local verifyRates = {}
local pending = {}
local sequence = 0
local revision = 0
local playing = 0

local verifyWindow = 10000
local verifyPerWindow = 40

local function askResolver(event, query)
    sequence = sequence + 1

    local id = sequence
    local p = promise.new()
    pending[id] = p

    SetTimeout(config.advanced.resolverTimeoutMs * 3 + 5000, function()
        if not pending[id] then return end
        pending[id] = nil
        p:resolve({ ok = false, error = 'the resolver did not answer' })
    end)

    TriggerEvent(event, id, query)
    return Citizen.Await(p)
end

local function fromSelf()
    local invoker = GetInvokingResource()
    return not invoker or invoker == GetCurrentResourceName()
end

local function settleResolver(id, payload)
    if not fromSelf() then return end

    local p = pending[id]
    if not p then return end

    pending[id] = nil

    local ok, decoded = pcall(json.decode, payload)
    p:resolve(ok and type(decoded) == 'table' and decoded or { ok = false, error = 'bad resolver reply' })
end

AddEventHandler('binary-radio:internal:resolved', settleResolver)
AddEventHandler('binary-radio:internal:searched', settleResolver)

local function prefetch(videoId)
    TriggerEvent('binary-radio:internal:prefetch', videoId)
end

local mimes = {
    ['.m4a'] = 'audio/mp4',
    ['.mp4'] = 'audio/mp4',
    ['.webm'] = 'audio/webm',
    ['.opus'] = 'audio/ogg',
    ['.ogg'] = 'audio/ogg',
    ['.mp3'] = 'audio/mpeg',
}

local extensions = { '.m4a', '.mp4', '.webm', '.opus', '.ogg', '.mp3' }
local memory = {}
local memoryOrder = {}
local memoryLimit = 6

local function readTrack(id)
    local held = memory[id]
    if held then return held.data, held.mime end

    for i = 1, #extensions do
        local extension = extensions[i]
        local data = LoadResourceFile(GetCurrentResourceName(), ('data/cache/%s%s'):format(id, extension))

        if data and #data > 0 then
            memory[id] = { data = data, mime = mimes[extension] }
            memoryOrder[#memoryOrder + 1] = id

            while #memoryOrder > memoryLimit do
                local oldest = table.remove(memoryOrder, 1)
                memory[oldest] = nil
            end

            return data, mimes[extension]
        end
    end
end

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

    local data, mime = readTrack(id)

    if not data then
        response.writeHead(404, { ['Access-Control-Allow-Origin'] = '*' })
        response.send('')
        return
    end

    local total = #data
    local range = request.headers and (request.headers.Range or request.headers.range)
    local first, last = nil, nil

    if range and not range:find(',', 1, true) then
        local from, to = range:match('^bytes=(%d*)%-(%d*)$')
        if from then
            first = from ~= '' and math.tointeger(tonumber(from)) or 0
            last = to ~= '' and math.tointeger(tonumber(to)) or total - 1

            if not first or not last or first >= total or last < first then
                first, last = nil, nil
            end
        end
    end

    if first then
        if last > total - 1 then last = total - 1 end

        response.writeHead(206, {
            ['Content-Type'] = mime,
            ['Content-Range'] = ('bytes %d-%d/%d'):format(first, last, total),
            ['Content-Length'] = tostring(last - first + 1),
            ['Accept-Ranges'] = 'bytes',
            ['Access-Control-Allow-Origin'] = '*',
            ['Cache-Control'] = 'public, max-age=86400',
        })

        response.send(data:sub(first + 1, last + 1))
        return
    end

    response.writeHead(200, {
        ['Content-Type'] = mime,
        ['Content-Length'] = tostring(total),
        ['Accept-Ranges'] = 'bytes',
        ['Access-Control-Allow-Origin'] = '*',
        ['Cache-Control'] = 'public, max-age=86400',
    })

    response.send(data)
end)

local encoded = {}
local encodedOrder = {}
local encodedLimit = 4
local readTimeoutMs = 90000
local sending = 0
local waiting = {}
local audioPending = {}

local function isPlayingAnywhere(id)
    for _, radio in pairs(radios) do
        if radio.track and radio.track.id == id then return true end
    end

    return false
end

local function readEncoded(id)
    local held = encoded[id]
    if held then return held.mime, held.data end

    sequence = sequence + 1

    local requestId = sequence
    local p = promise.new()
    audioPending[requestId] = p

    SetTimeout(readTimeoutMs, function()
        if not audioPending[requestId] then return end
        audioPending[requestId] = nil
        p:resolve({ '', '' })
    end)

    TriggerEvent('binary-radio:internal:read', requestId, id)

    local reply = Citizen.Await(p)
    local mime, data = reply[1], reply[2]
    if mime == '' or data == '' then return nil end

    encoded[id] = { mime = mime, data = data }
    encodedOrder[#encodedOrder + 1] = id

    while #encodedOrder > encodedLimit do
        local oldest = table.remove(encodedOrder, 1)
        encoded[oldest] = nil
    end

    return mime, data
end

AddEventHandler('binary-radio:internal:readAudio', function(requestId, mime, data)
    if not fromSelf() then return end

    local p = audioPending[requestId]
    if not p then return end

    audioPending[requestId] = nil
    p:resolve({ mime or '', data or '' })
end)

local function releaseSend()
    sending = math.max(0, sending - 1)

    local next = table.remove(waiting, 1)
    if next then next() end
end

local function sendAudio(source, id)
    local mime, data = readEncoded(id)

    if not mime then
        print(('[binary-radio] %s is not ready to send yet, the client will ask again'):format(id))
        releaseSend()
        return
    end

    TriggerLatentClientEvent('binary-radio:client:sentAudio', source, config.advanced.transferBytesPerSecond, id, mime, data)
    SetTimeout(#data / config.advanced.transferBytesPerSecond * 1000, releaseSend)
end

RegisterNetEvent('binary-radio:server:requestedAudio', function(id)
    local source = source
    if type(id) ~= 'string' or #id ~= 11 or not id:match('^[%w_-]+$') then return end
    if not isPlayingAnywhere(id) then return end

    if sending >= config.advanced.parallelTransfers then
        if #waiting >= 64 then return end
        waiting[#waiting + 1] = function() sendAudio(source, id) end
        return
    end

    sending = sending + 1
    sendAudio(source, id)
end)

local function getVehicle(netId)
    if type(netId) ~= 'number' then return nil end

    local vehicle = NetworkGetEntityFromNetworkId(netId)
    if vehicle == 0 or not DoesEntityExist(vehicle) then return nil end

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
    }
end

local function publish(netId)
    local vehicle = getVehicle(netId)
    if not vehicle then return end

    local radio = radios[netId]
    revision = revision + 1

    if not radio or not radio.track then
        Entity(vehicle).state:set('binaryRadio', false, true)
    else
        radio.sequence = revision
        Entity(vehicle).state:set('binaryRadio', revision, true)
    end

    local payload = snapshot(radio)

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

    radios[netId] = nil
    playing = math.max(0, playing - 1)
    publish(netId)
    pushQueue(netId)
end

local function startRadio(netId, source)
    local radio = radios[netId]
    if radio then return radio end
    if playing >= config.advanced.maxRadiosPlaying then return nil end

    radio = {
        queue = {},
        volume = levels[netId] or 0.5,
        playing = false,
        offset = 0,
        stampedAt = clock(),
        epoch = 0,
        owner = source,
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
end

local function begin(netId)
    local radio = radios[netId]
    if not radio or not radio.arming then return end

    radio.arming = nil
    radio.playing = true
    stamp(radio, 0)
    publish(netId)
end

local function playNext(netId)
    local radio = radios[netId]
    if not radio then return end

    local track = table.remove(radio.queue, 1)
    if not track then return stopRadio(netId) end

    arm(radio, track)
    publish(netId)
    pushQueue(netId)

    local upcoming = radio.queue[1]
    if upcoming then prefetch(upcoming.id) end
end

local function restart(netId)
    local radio = radios[netId]
    if not radio then return end

    stamp(radio, 0)
    publish(netId)
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
    }
end)

local function verifyFlooding(source)
    local now = GetGameTimer()
    local bucket = verifyRates[source]

    if not bucket or now - bucket.since > verifyWindow then
        verifyRates[source] = { since = now, count = 1 }
        return false
    end

    bucket.count = bucket.count + 1
    return bucket.count > verifyPerWindow
end

Callback.register('binary-radio:emitter', function(source, netId)
    if type(netId) ~= 'number' or verifyFlooding(source) then return false end

    return snapshot(radios[netId])
end)

Callback.register('binary-radio:searched', function(source, query)
    if searchThrottled(source) then return { ok = false, error = 'slow down' } end
    if type(query) ~= 'string' or #query < 2 or #query > 120 then
        return { ok = false, error = 'invalid search' }
    end

    return askResolver('binary-radio:internal:search', query)
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

    local upcoming = radio.queue[1]
    if upcoming then prefetch(upcoming.id) end

    return true, accepted[1], #accepted
end

Callback.register('binary-radio:requested', function(source, netId, query, mode)
    if type(netId) ~= 'number' then return { ok = false, error = 'invalid vehicle' } end
    if throttled(source) then return { ok = false, error = 'slow down' } end

    local allowed, reason = canControl(source, netId)
    if not allowed then return { ok = false, error = reason } end
    if type(query) ~= 'string' or #query < 5 or #query > 300 then
        return { ok = false, error = 'invalid link' }
    end

    local radio = startRadio(netId, source)
    if not radio then return { ok = false, error = 'too many radios playing right now' } end

    local queued = mode == 'queue'
    if queued and #radio.queue >= config.queueSize then
        return { ok = false, error = 'queue is full' }
    end

    local result = askResolver('binary-radio:internal:resolve', query)
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
    verifyRates[dropped] = nil
end)

CreateThread(function()
    while true do
        Wait(1000)

        for netId, radio in pairs(radios) do
            if not getVehicle(netId) then
                radios[netId] = nil
                levels[netId] = nil
                playing = math.max(0, playing - 1)
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
    end
end)

AddEventHandler('binary-radio:internal:unavailable', function(id)
    if not fromSelf() then return end
    if type(id) ~= 'string' then return end

    for netId, radio in pairs(radios) do
        if radio.track and radio.track.id == id then playNext(netId) end
    end
end)

local function checkStreamUrl()
    if config.audioUrl == '' then
        print('[binary-radio] audio rides the game connection; set config.audioUrl to move it onto https')
        return
    end

    local base = config.audioUrl:gsub('/+$', '')

    if not base:match('^https://') then
        print(('[binary-radio] config.audioUrl must be https, browsers refuse http audio inside the interface: %s'):format(base))
        return
    end

    PerformHttpRequest(base .. '/health', function(status, body)
        if status == 200 and body == streamToken then
            print(('[binary-radio] audio streaming is live at %s'):format(base))
            return
        end

        print(('[binary-radio] config.audioUrl (%s) did not answer as this resource [%s]; clients will fall back to the game connection'):format(base, tostring(status)))
    end, 'GET')
end

AddEventHandler('binary-radio:internal:ready', function()
    if not fromSelf() then return end
    print('[binary-radio] ready')
end)

AddEventHandler('onResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then return end

    TriggerEvent('binary-radio:internal:configure', json.encode({
        timeoutMs = config.advanced.resolverTimeoutMs,
        maxParallelDownloads = config.advanced.parallelDownloads,
        cookiesFile = GetConvar('binary_radio:cookies', ''),
        proxy = GetConvar('binary_radio:proxy', ''),
        autoUpdateHours = config.advanced.autoUpdateHours,
    
        maxBytes = config.advanced.cacheMaxBytes,
        ttlHours = (config.advanced.cacheDays * 24),
        searchResults = config.searchResults,
        maxDurationSeconds = (config.maxSongMinutes * 60),
        playlistMaxTracks = config.maxPlaylistTracks,
    }))

    SetTimeout(3000, checkStreamUrl)
end)
