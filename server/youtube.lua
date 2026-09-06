Youtube = {}

local apiKey = ''
local maxDuration = 900
local searchLimit = 24
local playlistLimit = 50
local timeoutMs = 30000

local videoIdPattern = '^[%w_-]+$'

local STOP_WORDS = {
    the = true,
    a = true,
    an = true,
    ['and'] = true,
    ['or'] = true,
    of = true,
    to = true,
    ['in'] = true,
    ['for'] = true,
    on = true,
    at = true,
    by = true,
}

local PENALTIES = {
    'karaoke', 'cover', 'covers', 'instrumental', 'tutorial', 'lesson', 'how to',
    '8d audio', 'bass boost', 'nightcore', 'sped up', 'slowed', '1 hour', '10 hours',
    'full album', 'lyrics video', 'lyric video',
}

function Youtube.configure(key, options)
    if type(key) == 'string' and key ~= '' then apiKey = key end
    if type(options) ~= 'table' then return end

    if options.maxDurationSeconds then maxDuration = options.maxDurationSeconds end
    if options.searchResults then searchLimit = options.searchResults end
    if options.playlistMaxTracks then playlistLimit = options.playlistMaxTracks end
    if options.timeoutMs then timeoutMs = options.timeoutMs end
end

local function httpGet(url)
    local p = promise.new()
    local settled = false

    SetTimeout(timeoutMs, function()
        if settled then return end
        settled = true
        p:resolve({ status = 0, body = '' })
    end)

    PerformHttpRequest(url, function(status, body)
        if settled then return end
        settled = true
        p:resolve({ status = status, body = body or '' })
    end, 'GET', '', { ['Content-Type'] = 'application/json' })

    return Citizen.Await(p)
end

local function urlEncode(value)
    return (tostring(value):gsub('[^%w%-%.%_%~]', function(char)
        return ('%%%02X'):format(string.byte(char))
    end))
end

local function apiUrl(path, params)
    local parts = { 'https://www.googleapis.com/youtube/v3/', path, '?key=', apiKey }

    for key, value in pairs(params) do
        parts[#parts + 1] = '&' .. key .. '=' .. urlEncode(value)
    end

    return table.concat(parts)
end

local function decode(body)
    local ok, parsed = pcall(json.decode, body)
    if not ok or type(parsed) ~= 'table' then return nil end
    return parsed
end

local function parseDuration(iso)
    if type(iso) ~= 'string' or iso == '' then return 0 end

    local hours = tonumber(iso:match('(%d+)H')) or 0
    local minutes = tonumber(iso:match('(%d+)M')) or 0
    local seconds = tonumber(iso:match('(%d+)S')) or 0

    return hours * 3600 + minutes * 60 + seconds
end

local function extractVideoId(input)
    if type(input) ~= 'string' then return nil end

    local trimmed = input:match('^%s*(.-)%s*$')
    if #trimmed == 11 and trimmed:match(videoIdPattern) then return trimmed end

    local patterns = {
        'youtube%.com/watch%?[^%s]*v=([%w_-]+)',
        'music%.youtube%.com/watch%?[^%s]*v=([%w_-]+)',
        'youtu%.be/([%w_-]+)',
        'youtube%.com/shorts/([%w_-]+)',
        'youtube%.com/embed/([%w_-]+)',
        'youtube%.com/live/([%w_-]+)',
    }

    for i = 1, #patterns do
        local id = trimmed:match(patterns[i])
        if id and #id == 11 then return id end
    end

    return nil
end

local function extractPlaylistId(input)
    if type(input) ~= 'string' then return nil end
    return input:match('[?&]list=([%w_-]+)')
end

local function playlistKind(listId)
    if not listId then return 'unknown' end
    if listId:sub(1, 2) == 'RD' then return 'mix' end
    if listId == 'WL' then return 'watchlater' end
    if listId:sub(1, 2) == 'LM' then return 'likes' end
    return 'playlist'
end

local function isPlaylistUrl(input)
    if type(input) ~= 'string' then return false end
    local listId = extractPlaylistId(input)
    if not listId then return false end
    return input:find('/playlist') or input:find('[?&]list=')
end

local function thumbnailFor(id, snippet)
    if type(snippet) == 'table' and type(snippet.thumbnails) == 'table' then
        local thumbs = snippet.thumbnails
        local pick = thumbs.medium or thumbs.high or thumbs.default
        if pick and pick.url then return pick.url:sub(1, 300) end
    end

    return ('https://i.ytimg.com/vi/%s/hqdefault.jpg'):format(id)
end

local function toTrack(id, snippet, duration)
    local title = 'Unknown'
    local author = 'Unknown'

    if type(snippet) == 'table' then
        if type(snippet.title) == 'string' then title = snippet.title:sub(1, 140) end

        local channel = snippet.channelTitle or snippet.videoOwnerChannelTitle
        if type(channel) == 'string' then author = channel:sub(1, 90) end
    end

    return {
        id = id,
        title = title,
        author = author,
        duration = math.max(0, math.floor(duration or 0)),
        thumbnail = thumbnailFor(id, snippet),
    }
end

local function acceptTrack(track)
    if track.duration <= 0 then
        return false, 'could not read the track length'
    end

    if track.duration > maxDuration then
        return false, ('longer than %d minutes'):format(math.floor(maxDuration / 60))
    end

    return true, track
end

local function tokenize(text)
    local terms = {}
    local lowered = tostring(text or ''):lower()

    for term in lowered:gmatch('[%w]+') do
        if #term > 1 and not STOP_WORDS[term] then
            terms[#terms + 1] = term
        end
    end

    return terms, lowered
end

local function rankTracks(query, tracks)
    local terms, lowered = tokenize(query)
    local scored = {}

    for i = 1, #tracks do
        local track = tracks[i]
        local title = (track.title or ''):lower()
        local author = (track.author or ''):lower()
        local blob = title .. ' ' .. author
        local score = 0

        if title == lowered then score = score + 30 end
        if title:sub(1, #lowered) == lowered then score = score + 14 end
        if blob:find(lowered, 1, true) then score = score + 8 end

        for j = 1, #terms do
            local term = terms[j]
            if title:find(term, 1, true) then score = score + 6 end
            if author:find(term, 1, true) then score = score + 3 end
            if blob:find(term, 1, true) then score = score + 2 end
        end

        for k = 1, #PENALTIES do
            if title:find(PENALTIES[k], 1, true) then score = score - 5 end
        end

        if track.duration > 0 then
            if track.duration <= 420 then score = score + 2 end
            if track.duration > 1200 then score = score - 4 end
        end

        if score > 0 then scored[#scored + 1] = { track = track, score = score } end
    end

    table.sort(scored, function(a, b) return a.score > b.score end)

    local output = {}
    for i = 1, #scored do output[i] = scored[i].track end
    return output
end

local function sourceFor(query)
    local trimmed = tostring(query):match('^%s*(.-)%s*$')

    if isPlaylistUrl(trimmed) then
        local listId = extractPlaylistId(trimmed)
        return {
            ok = true,
            kind = 'playlist',
            playlistKind = playlistKind(listId),
            id = listId,
        }
    end

    local videoId = extractVideoId(trimmed)
    if not videoId then return { ok = false, error = 'that is not a YouTube link' } end

    return { ok = true, kind = 'video', id = videoId }
end

local function fetchVideoDetails(ids)
    if #ids == 0 then return {} end

    local response = httpGet(apiUrl('videos', {
        part = 'contentDetails,snippet,liveStreamingDetails',
        id = table.concat(ids, ','),
    }))

    if response.status ~= 200 then return {} end

    local parsed = decode(response.body)
    if not parsed or type(parsed.items) ~= 'table' then return {} end

    local details = {}

    for i = 1, #parsed.items do
        local item = parsed.items[i]
        local id = item.id
        if type(id) == 'string' and #id == 11 then
            details[id] = item
        end
    end

    return details
end

local function trackFromDetails(id, details)
    local item = details[id]
    if not item then return nil end

    if item.liveStreamingDetails or (item.snippet and item.snippet.liveBroadcastContent == 'live') then
        return nil, 'live streams are not supported'
    end

    local duration = parseDuration(item.contentDetails and item.contentDetails.duration)
    local track = toTrack(id, item.snippet, duration)

    local ok, result = acceptTrack(track)
    if not ok then return nil, result end

    return track
end

function Youtube.search(query)
    if apiKey == '' then return { ok = false, error = 'YouTube API key is not configured' } end

    local limit = math.max(1, math.min(searchLimit, 30))
    local fetchLimit = math.min(math.max(limit * 3, 30), 50)

    local response = httpGet(apiUrl('search', {
        part = 'snippet',
        type = 'video',
        maxResults = tostring(fetchLimit),
        q = query,
    }))

    if response.status ~= 200 then
        return { ok = false, error = 'YouTube search failed' }
    end

    local parsed = decode(response.body)
    if not parsed or type(parsed.items) ~= 'table' then
        return { ok = false, error = 'could not read the search results' }
    end

    local ids = {}
    local snippets = {}

    for i = 1, #parsed.items do
        local item = parsed.items[i]
        local id = item.id and item.id.videoId
        if type(id) == 'string' and #id == 11 then
            ids[#ids + 1] = id
            snippets[id] = item.snippet
        end
    end

    local details = fetchVideoDetails(ids)
    local tracks = {}

    for i = 1, #ids do
        local id = ids[i]
        local item = details[id]

        if item then
            local live = item.liveStreamingDetails
                or (item.snippet and item.snippet.liveBroadcastContent == 'live')

            if not live then
                local duration = parseDuration(item.contentDetails and item.contentDetails.duration)
                if duration > 0 and duration <= maxDuration then
                    tracks[#tracks + 1] = toTrack(id, item.snippet or snippets[id], duration)
                end
            end
        end
    end

    local ranked = rankTracks(query, tracks)
    local output = #ranked > 0 and ranked or tracks

    if #output > limit then
        local trimmed = {}
        for i = 1, limit do trimmed[i] = output[i] end
        output = trimmed
    end

    if #output == 0 then return { ok = false, error = 'no results found' } end

    return { ok = true, tracks = output }
end

function Youtube.resolve(query)
    if apiKey == '' then return { ok = false, error = 'YouTube API key is not configured' } end

    local source = sourceFor(query)
    if not source.ok then return source end

    if source.kind == 'playlist' then
        return Youtube.loadPlaylist(source)
    end

    local details = fetchVideoDetails({ source.id })
    local track, err = trackFromDetails(source.id, details)

    if not track then return { ok = false, error = err or 'could not read that track' } end

    return { ok = true, track = track }
end

function Youtube.loadPlaylist(source)
    local limit = math.max(1, math.min(playlistLimit, 50))
    local kind = source.playlistKind or playlistKind(source.id)

    local response = httpGet(apiUrl('playlistItems', {
        part = 'snippet,contentDetails',
        playlistId = source.id,
        maxResults = tostring(limit),
    }))

    if response.status ~= 200 then
        return { ok = false, error = 'could not read that playlist' }
    end

    local parsed = decode(response.body)
    if not parsed or type(parsed.items) ~= 'table' then
        return { ok = false, error = 'could not read that playlist' }
    end

    local ids = {}
    local snippets = {}
    local seen = {}

    for i = 1, #parsed.items do
        local item = parsed.items[i]
        local id = item.contentDetails and item.contentDetails.videoId
        if type(id) == 'string' and #id == 11 and not seen[id] then
            seen[id] = true
            ids[#ids + 1] = id
            snippets[id] = item.snippet
        end
    end

    if #ids == 0 then return { ok = false, error = 'that playlist is empty' } end

    local details = fetchVideoDetails(ids)
    local tracks = {}

    for i = 1, #ids do
        local id = ids[i]
        local track = trackFromDetails(id, details)
        if track then tracks[#tracks + 1] = track end
    end

    if #tracks == 0 then return { ok = false, error = 'that playlist is empty' } end

    local result = {
        ok = true,
        playlist = true,
        mix = kind == 'mix',
        tracks = tracks,
        track = tracks[1],
    }

    if kind == 'mix' then
        result.notice =
            'that link is a YouTube mix, not a saved playlist. mixes are personalized per account and may not match what you see in the app'
    elseif kind == 'watchlater' or kind == 'likes' then
        result.notice = 'library lists need OAuth and are not supported through the API'
    end

    return result
end
