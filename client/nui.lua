local function status(state, message)
    SendNUIMessage({ action = 'state', state = { status = state, statusMessage = message or '' } })
end

local function requireControl()
    return Radio.visible and Radio.netId and Radio.canControl
end

RegisterNUICallback('close', function(_, cb)
    Radio.hide()
    cb(1)
end)

RegisterNUICallback('search', function(data, cb)
    cb(1)
    if not Radio.visible then return end

    local query = type(data) == 'table' and data.query or nil
    if type(query) ~= 'string' then return end

    query = query:gsub('^%s+', ''):gsub('%s+$', ''):gsub('%s+', ' ')
    if #query < 2 then
        SendNUIMessage({ action = 'results', query = query, results = {} })
        return
    end

    SendNUIMessage({ action = 'searching', query = query })

    local result = Callback.await('binary-radio:searched', query)
    if not result or not result.ok then
        SendNUIMessage({ action = 'results', query = query, results = {} })
        status('error', result and result.error or 'the server took too long')
        return
    end

    SendNUIMessage({ action = 'results', query = query, results = result.tracks })
    status('idle')
end)

RegisterNUICallback('request', function(data, cb)
    cb(1)
    if not requireControl() then return end

    local query = type(data) == 'table' and data.query or nil
    if type(query) ~= 'string' then return end

    local mode = data.mode == 'queue' and 'queue' or 'play'
    status('resolving')

    local result = Callback.await('binary-radio:requested', Radio.netId, query, mode)
    if not result or not result.ok then
        status('error', result and result.error or 'the server took too long')
        return
    end

    if result and result.ok and result.playlist and type(result.count) == 'number' then
        local message = ('queued %d tracks from playlist'):format(result.count)
        if type(result.notice) == 'string' and result.notice ~= '' then
            message = ('%s. %s'):format(message, result.notice)
        end
        status('idle', message)
    else
        status('idle')
    end

    Radio.push()
end)

local function refresh()
    Emitters.wake()
    Radio.push()
end

RegisterNUICallback('togglePlay', function(_, cb)
    cb(1)
    if not requireControl() then return end

    local data = Emitters.get(Radio.netId)
    if not data then return end

    local playing = not data.playing

    Emitters.setPlaying(Radio.netId, playing)
    refresh()
    TriggerServerEvent('binary-radio:server:changedPlayback', Radio.netId, 'playing', playing)
end)

RegisterNUICallback('seek', function(data, cb)
    cb(1)
    if not requireControl() then return end
    local position = type(data) == 'table' and tonumber(data.position) or nil
    if not position then return end

    Emitters.setOffset(Radio.netId, position)
    refresh()
    TriggerServerEvent('binary-radio:server:changedPlayback', Radio.netId, 'seek', position)
end)

RegisterNUICallback('nudge', function(data, cb)
    cb(1)
    if not requireControl() then return end
    local delta = type(data) == 'table' and tonumber(data.delta) or nil
    if not delta then return end

    Emitters.setOffset(Radio.netId, Emitters.position(Radio.netId) + delta)
    refresh()
    TriggerServerEvent('binary-radio:server:changedPlayback', Radio.netId, 'nudge', delta)
end)

RegisterNUICallback('stop', function(_, cb)
    cb(1)
    if not requireControl() then return end
    TriggerServerEvent('binary-radio:server:changedPlayback', Radio.netId, 'stop')
end)

RegisterNUICallback('skip', function(data, cb)
    cb(1)
    if not requireControl() then return end
    local direction = type(data) == 'table' and tonumber(data.direction) or nil
    if not direction then return end
    TriggerServerEvent('binary-radio:server:changedPlayback', Radio.netId, 'skip', direction)
end)

RegisterNUICallback('volume', function(data, cb)
    cb(1)
    if not requireControl() then return end
    local volume = type(data) == 'table' and tonumber(data.volume) or nil
    if not volume then return end

    Emitters.setVolume(Radio.netId, volume)
    Emitters.wake()
    TriggerServerEvent('binary-radio:server:changedPlayback', Radio.netId, 'volume', volume)
end)

RegisterNUICallback('repeat', function(data, cb)
    cb(1)
    if not requireControl() then return end

    local enabled = type(data) == 'table' and data.enabled == true
    Radio.repeatOn = enabled
    Radio.push()
    TriggerServerEvent('binary-radio:server:changedPlayback', Radio.netId, 'repeat', enabled)
end)

RegisterNUICallback('queuePlay', function(data, cb)
    cb(1)
    if not requireControl() then return end
    local index = type(data) == 'table' and tonumber(data.index) or nil
    if not index then return end
    TriggerServerEvent('binary-radio:server:changedQueue', Radio.netId, 'play', index + 1)
end)

RegisterNUICallback('queueRemove', function(data, cb)
    cb(1)
    if not requireControl() then return end
    local index = type(data) == 'table' and tonumber(data.index) or nil
    if not index then return end
    TriggerServerEvent('binary-radio:server:changedQueue', Radio.netId, 'remove', index + 1)
end)

RegisterNUICallback('trackReady', function(data, cb)
    cb(1)

    local emitterId = type(data) == 'table' and data.id or nil
    local track = type(data) == 'table' and data.track or nil
    if type(emitterId) ~= 'string' or type(track) ~= 'string' then return end

    local netId = tonumber(emitterId:match('^(%d+):'))
    if not netId then return end

    TriggerServerEvent('binary-radio:server:readiedTrack', netId, track)
end)

RegisterNUICallback('trackEnded', function(data, cb)
    cb(1)

    local emitterId = type(data) == 'table' and data.id or nil
    if type(emitterId) ~= 'string' then return end

    local netId = tonumber(emitterId:match('^(%d+):'))
    if not netId then return end

    TriggerServerEvent('binary-radio:server:endedTrack', netId)
end)

RegisterNUICallback('audioError', function(_, cb)
    cb(1)
end)
