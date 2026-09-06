Stream = {}

local cache = {}
local cacheLimit = 48
local cacheTtlMs = 5 * 3600 * 1000
local timeoutMs = 45000

local innertubeKey = 'AIzaSyA8eiZmM1FaDVZ0BvD4f-s5rb91eH1X9ZE'

local clients = {
    {
        clientName = 'ANDROID_TESTSUITE',
        clientVersion = '1.9',
        androidSdkVersion = 30,
        hl = 'en',
        gl = 'US',
    },
    {
        clientName = 'ANDROID',
        clientVersion = '20.10.38',
        androidSdkVersion = 30,
        hl = 'en',
        gl = 'US',
    },
    {
        clientName = 'IOS',
        clientVersion = '19.45.4',
        deviceModel = 'iPhone14,3',
        hl = 'en',
        gl = 'US',
    },
    {
        clientName = 'TVHTML5_SIMPLY_EMBEDDED_PLAYER',
        clientVersion = '2.0',
        hl = 'en',
        gl = 'US',
    },
}

local mimes = {
    ['audio/mp4'] = 'audio/mp4',
    ['audio/webm'] = 'audio/webm',
    ['audio/ogg'] = 'audio/ogg',
}

local function httpRequest(url, method, body, headers)
    local p = promise.new()
    local settled = false

    SetTimeout(timeoutMs, function()
        if settled then return end
        settled = true
        p:resolve({ status = 0, body = '', headers = {} })
    end)

    PerformHttpRequest(url, function(status, responseBody, responseHeaders)
        if settled then return end
        settled = true
        p:resolve({
            status = status,
            body = responseBody or '',
            headers = responseHeaders or {},
        })
    end, method, body or '', headers or {})

    return Citizen.Await(p)
end

local function formatUrl(format)
    if type(format) ~= 'table' then return nil end
    if type(format.url) == 'string' and format.url ~= '' then return format.url end
    return nil
end

local function pickFormat(formats)
    if type(formats) ~= 'table' then return nil end

    local best = nil
    local bestBitrate = -1

    for i = 1, #formats do
        local format = formats[i]
        local url = formatUrl(format)

        if url then
            local mime = type(format.mimeType) == 'string' and format.mimeType:match('^[^;]+') or ''
            if mime:find('^audio/') then
                local bitrate = tonumber(format.bitrate) or tonumber(format.averageBitrate) or 0
                if bitrate > bestBitrate then
                    bestBitrate = bitrate
                    best = format
                end
            end
        end
    end

    return best
end

local function remember(videoId, entry)
    cache[videoId] = entry

    local count = 0
    for _ in pairs(cache) do count = count + 1 end

    if count <= cacheLimit then return end

    local oldestId, oldestAt = nil, math.huge
    for id, held in pairs(cache) do
        if held.at < oldestAt then
            oldestAt = held.at
            oldestId = id
        end
    end

    if oldestId then cache[oldestId] = nil end
end

local function requestPlayer(videoId, client)
    local payload = json.encode({
        videoId = videoId,
        contentCheckOk = true,
        racyCheckOk = true,
        context = { client = client },
    })

    return httpRequest(
        ('https://www.youtube.com/youtubei/v1/player?key=%s'):format(innertubeKey),
        'POST',
        payload,
        {
            ['Content-Type'] = 'application/json',
            ['User-Agent'] = 'com.google.android.youtube/20.10.38 (Linux; U; Android 11) gzip',
        }
    )
end

function Stream.resolve(videoId)
    if type(videoId) ~= 'string' or #videoId ~= 11 or not videoId:match('^[%w_-]+$') then
        return nil
    end

    local now = GetGameTimer()
    local held = cache[videoId]
    if held and now - held.at < cacheTtlMs then
        return held.url, held.mime
    end

    local lastReason = 'no playable audio format'

    for i = 1, #clients do
        local response = requestPlayer(videoId, clients[i])

        if response.status == 200 then
            local ok, parsed = pcall(json.decode, response.body)

            if ok and type(parsed) == 'table' then
                local status = parsed.playabilityStatus and parsed.playabilityStatus.status

                if not status or status == 'OK' then
                    local streaming = parsed.streamingData

                    if type(streaming) == 'table' then
                        local format = pickFormat(streaming.adaptiveFormats) or pickFormat(streaming.formats)

                        if format then
                            local url = formatUrl(format)

                            if url then
                                local mime = type(format.mimeType) == 'string' and format.mimeType:match('^[^;]+') or 'audio/mp4'
                                remember(videoId, { url = url, mime = mimes[mime] or mime, at = now })
                                return url, mimes[mime] or mime
                            end

                            lastReason = 'stream url missing'
                        else
                            lastReason = 'no direct audio stream url'
                        end
                    else
                        lastReason = 'no streaming data'
                    end
                else
                    lastReason = parsed.playabilityStatus.reason or status
                end
            else
                lastReason = 'player response was not json'
            end
        else
            lastReason = ('player request returned %s'):format(tostring(response.status))
        end
    end

    return nil
end

function Stream.fetch(videoId, rangeHeader)
    local url, mime = Stream.resolve(videoId)
    if not url then return nil end

    local headers = {
        ['User-Agent'] = 'com.google.android.youtube/20.10.38 (Linux; U; Android 11) gzip',
    }

    if type(rangeHeader) == 'string' and rangeHeader ~= '' then
        headers['Range'] = rangeHeader
    end

    local response = httpRequest(url, 'GET', '', headers)
    if response.status ~= 200 and response.status ~= 206 then return nil end

    return {
        status = response.status,
        body = response.body,
        mime = mime,
        headers = response.headers,
    }
end

function Stream.prefetch(videoId)
    CreateThread(function()
        Stream.resolve(videoId)
    end)
end
