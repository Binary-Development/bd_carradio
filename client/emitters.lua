Emitters = {}

local tracked = {}
local trackedCount = 0
local streamBase = ''
local audible = {}
local emit

local idleWait = 900
local activeWait = 100
local movingWait = 33
local movingSpeed = 4.0
local maxPitch = 85.0
local staleAfter = 60000

function Emitters.setStreamBase(base)
    streamBase = base
end

local function offsetOf(data)
    if not data.playing then return data.offset end
    return math.min(data.offset + (GetGameTimer() - data.anchoredAt) / 1000, data.duration)
end

local function anchor(data, age)
    if age and age > 0 then
        data.offset = math.min(math.max(data.offset + age, 0), data.duration)
    end

    data.anchoredAt = GetGameTimer()
end

function Emitters.get(netId)
    local entry = tracked[netId]
    return entry and entry.data or nil
end

function Emitters.position(netId)
    local entry = tracked[netId]
    if not entry then return 0 end
    return offsetOf(entry.data)
end

local function sanitise(value)
    if type(value) ~= 'table' then return nil end
    local id = type(value.id) == 'string' and value.id or ''
    if not id:match('^[%w_-]+$') or #id ~= 11 then return nil end

    local duration = tonumber(value.duration)
    local offset = tonumber(value.offset)
    if not duration or not offset then return nil end
    if duration <= 0 or duration > (config.maxSongMinutes * 60) then return nil end

    return {
        id = id,
        title = type(value.title) == 'string' and value.title:sub(1, 140) or 'Unknown',
        author = type(value.author) == 'string' and value.author:sub(1, 90) or 'Unknown',
        duration = duration,
        thumb = type(value.thumb) == 'string' and value.thumb:sub(1, 300) or '',
        playing = value.playing == true,
        loading = value.loading == true,
        volume = math.min(math.max(tonumber(value.volume) or 0.5, 0.0), 1.0),
        offset = math.min(math.max(offset, 0), duration),
        age = math.min(math.max(tonumber(value.age) or 0, 0), duration),
        epoch = tonumber(value.epoch) or 0,
        sequence = tonumber(value.sequence) or 0,
    }
end

local function forget(netId)
    if not tracked[netId] then return end

    tracked[netId] = nil
    trackedCount = trackedCount - 1
    TriggerEvent('binary-radio:client:changedEmitter', netId, nil)

    if trackedCount == 0 then emit() end
end

local predictionWindow = 2500
local predictionTolerance = 0.75
local volumeTolerance = 0.02

local function reconcileVolume(entry, data)
    local predicted = entry.predictedVolume
    if not predicted then return end

    if math.abs(data.volume - predicted.value) < volumeTolerance or GetGameTimer() > predicted.expires then
        entry.predictedVolume = nil
        return
    end

    data.volume = predicted.value
end

local function predict(entry, data)
    entry.predicted = {
        offset = data.offset,
        playing = data.playing,
        anchoredAt = data.anchoredAt,
        epoch = data.epoch,
        expires = GetGameTimer() + predictionWindow,
    }
end

local function reconcile(entry, data)
    local predicted = entry.predicted
    if not predicted then return data end

    local agrees = data.playing == predicted.playing
        and math.abs(data.offset - predicted.offset) < predictionTolerance

    if agrees or data.id ~= entry.data.id or GetGameTimer() > predicted.expires then
        entry.predicted = nil
        return data
    end

    data.offset = predicted.offset
    data.playing = predicted.playing
    data.anchoredAt = predicted.anchoredAt
    data.epoch = predicted.epoch

    return data
end

local function remember(netId, data)
    local entry = tracked[netId]
    local previous = entry and entry.data

    if entry and entry.sequence and data.sequence < entry.sequence then return end
    if entry then entry.sequence = data.sequence end

    if previous and previous.anchoredAt and data.epoch == previous.epoch and data.id == previous.id then
        data.offset = previous.offset
        data.anchoredAt = previous.anchoredAt
    else
        anchor(data, data.age)
    end

    if entry then
        reconcileVolume(entry, data)
        entry.data = reconcile(entry, data)
    else
        trackedCount = trackedCount + 1
        tracked[netId] = { data = data, sequence = data.sequence }
    end

    TriggerEvent('binary-radio:client:changedEmitter', netId, data)
end

function Emitters.set(netId, value)
    if not value then
        forget(netId)
        return
    end

    local data = sanitise(value)
    if data then remember(netId, data) end
end

function Emitters.setVolume(netId, volume)
    local entry = tracked[netId]
    if not entry then return end

    entry.data.volume = math.min(math.max(volume, 0.0), 1.0)
    entry.predictedVolume = {
        value = entry.data.volume,
        expires = GetGameTimer() + predictionWindow,
    }
end

function Emitters.setPlaying(netId, playing)
    local entry = tracked[netId]
    if not entry then return end

    local data = entry.data
    data.offset = offsetOf(data)
    anchor(data)
    data.playing = playing
    predict(entry, data)
end

function Emitters.setOffset(netId, offset)
    local entry = tracked[netId]
    if not entry then return end

    local data = entry.data
    data.offset = math.min(math.max(offset, 0), data.duration)
    anchor(data)
    data.epoch = data.epoch + 1
    predict(entry, data)
end

local verifyQueue = {}
local verifyQueueSize = 0
local verifyMeta = {}
local verifyCooldown = 3000
local rejectCooldown = 15000
local verifyQueueLimit = 24
local verifyGap = 120

local function enqueueVerify(netId)
    local meta = verifyMeta[netId]
    local now = GetGameTimer()

    if meta then
        if meta.queued then return end
        if meta.rejectedUntil and now < meta.rejectedUntil then return end

        if meta.lastAsked and now - meta.lastAsked < verifyCooldown then
            meta.dirty = true
            return
        end
    else
        meta = {}
        verifyMeta[netId] = meta
    end

    meta.dirty = nil

    if verifyQueueSize >= verifyQueueLimit then return end

    meta.queued = true
    verifyQueueSize = verifyQueueSize + 1
    verifyQueue[verifyQueueSize] = netId
end

AddStateBagChangeHandler('binaryRadio', nil, function(bagName)
    local netId = tonumber(bagName:match('entity:(%d+)'))
    if not netId then return end
    enqueueVerify(netId)
end)

CreateThread(function()
    while true do
        if verifyQueueSize == 0 then
            local now = GetGameTimer()

            for netId, meta in pairs(verifyMeta) do
                if meta.dirty and (not meta.lastAsked or now - meta.lastAsked >= verifyCooldown) then
                    enqueueVerify(netId)
                end
            end

            Wait(250)
            goto continue
        end

        do
            local netId = table.remove(verifyQueue, 1)
            verifyQueueSize = verifyQueueSize - 1

            local meta = verifyMeta[netId] or {}
            verifyMeta[netId] = meta
            meta.queued = nil
            meta.lastAsked = GetGameTimer()

            local payload = Callback.await('binary-radio:emitter', netId)
            local data = payload and sanitise(payload) or nil

            if data then
                meta.rejectedUntil = nil
                remember(netId, data)
            else
                meta.rejectedUntil = GetGameTimer() + rejectCooldown
                forget(netId)
            end
        end

        Wait(verifyGap)
        ::continue::
    end
end)

CreateThread(function()
    while true do
        Wait(60000)
        local now = GetGameTimer()
        for netId, meta in pairs(verifyMeta) do
            local settled = not meta.queued
            local coolerThanReject = not meta.rejectedUntil or now > meta.rejectedUntil + staleAfter
            local coolerThanAsk = not meta.lastAsked or now - meta.lastAsked > staleAfter
            if settled and coolerThanReject and coolerThanAsk and not tracked[netId] then
                verifyMeta[netId] = nil
            end
        end
    end
end)

local function cameraFrame()
    local coords = GetGameplayCamCoord()
    local rot = GetGameplayCamRot(2)
    local pitch = math.max(math.min(rot.x, maxPitch), -maxPitch)
    local rx, rz = math.rad(pitch), math.rad(rot.z)
    local cosRx = math.cos(rx)
    return coords, -math.sin(rz) * cosRx, math.cos(rz) * cosRx, math.sin(rx)
end

function emit()
    local playerPed = PlayerPedId()
    local playerVehicle = GetVehiclePedIsIn(playerPed, false)
    local camCoords, fx, fy, fz = cameraFrame()
    local maxDistance = config.hearingDistance
    local count = 0

    for index = 1, #audible do audible[index] = nil end

    local now = GetGameTimer()
    local fastest = 0.0

    for netId, entry in pairs(tracked) do
        local vehicle = NetworkDoesEntityExistWithNetworkId(netId) and NetworkGetEntityFromNetworkId(netId) or 0

        if vehicle == 0 or not DoesEntityExist(vehicle) then
            entry.missingSince = entry.missingSince or now
            if now - entry.missingSince > staleAfter then
                tracked[netId] = nil
                trackedCount = trackedCount - 1
                verifyMeta[netId] = nil
            end
        elseif entry.missingSince then
            entry.missingSince = nil
        end

        if vehicle ~= 0 and DoesEntityExist(vehicle) then
            local coords = GetEntityCoords(vehicle)
            local distance = #(camCoords - coords)

            if distance <= maxDistance then
                local inside = playerVehicle == vehicle
                local cutoff, gain

                if inside then
                    cutoff, gain = Cabin.insideAcoustics()
                else
                    cutoff, gain = Cabin.outsideAcoustics(vehicle)
                end

                local velocity = GetEntityVelocity(vehicle)
                local speed = #(velocity)
                if speed > fastest then fastest = speed end
                count = count + 1
                audible[count] = {
                    id = tostring(netId),
                    track = entry.data.id,
                    url = streamBase ~= '' and ('%s/stream/%s'):format(streamBase, entry.data.id) or '',
                    offset = offsetOf(entry.data),
                    paused = not entry.data.playing,
                    spatial = not inside,
                    stamp = entry.data.epoch,
                    vx = velocity.x,
                    vy = velocity.y,
                    vz = velocity.z,
                    volume = entry.data.volume or 0.5,
                    x = coords.x,
                    y = coords.y,
                    z = coords.z,
                    cutoff = cutoff,
                    gain = gain,
                    distance = distance,
                }
            end
        end
    end

    if count > 1 then
        table.sort(audible, function(a, b) return a.distance < b.distance end)
    end

    for index = count, config.advanced.maxRadiosHeard + 1, -1 do
        audible[index] = nil
    end

    SendNUIMessage({
        action = 'tick',
        emitters = audible,
        listener = {
            x = camCoords.x,
            y = camCoords.y,
            z = camCoords.z,
            fx = fx,
            fy = fy,
            fz = fz,
            ux = 0.0,
            uy = 0.0,
            uz = 1.0,
        },
    })

    return fastest > movingSpeed and movingWait or activeWait
end

function Emitters.wake()
    if trackedCount == 0 then return end
    emit()
end

CreateThread(function()
    while true do
        if trackedCount == 0 then
            Wait(idleWait)
        else
            Wait(emit())
        end
    end
end)

AddEventHandler('onResourceStop', function(name)
    if name ~= GetCurrentResourceName() then return end
    SendNUIMessage({ action = 'stopAll' })
end)
