Radio = {
    visible = false,
    netId = nil,
    canControl = false,
    repeatOn = false,
}

local function notify(message)
    BeginTextCommandThefeedPost('STRING')
    AddTextComponentSubstringPlayerName(message)
    EndTextCommandThefeedPostTicker(false, true)
end

local function currentVehicle()
    local ped = PlayerPedId()
    local vehicle = GetVehiclePedIsIn(ped, false)
    if vehicle == 0 or not DoesEntityExist(vehicle) then return nil end
    return vehicle
end

local function resolveStreamBase()
    if config.audioUrl == '' then return end

    local base = config.audioUrl:gsub('/+$', '')
    if not base:match('^https://') then return end

    Emitters.setStreamBase(base)
end

function Radio.push(info)
    if not Radio.visible or not Radio.netId then return end

    local data = Emitters.get(Radio.netId)

    SendNUIMessage({
        action = 'state',
        state = {
            label = 'Car Radio',
            sublabel = 'Play music through this vehicle',
            canControl = Radio.canControl,
            playing = data and data.playing or false,
            loading = data and data.loading or false,
            volume = data and data.volume or (info and info.volume) or 0.5,
            position = Emitters.position(Radio.netId),
            current = data and {
                id = data.id,
                title = data.title,
                author = data.author,
                duration = data.duration,
                thumbnail = data.thumb,
            } or false,
            queue = info and info.queue or nil,
            ['repeat'] = Radio.repeatOn,
            status = 'idle',
            statusMessage = '',
        },
    })
end

function Radio.hide()
    if not Radio.visible then return end
    Radio.visible = false
    Radio.netId = nil
    SetNuiFocus(false, false)
    SendNUIMessage({ action = 'visibility', open = false })
    TriggerServerEvent('binary-radio:server:closedPanel')
end

function Radio.show()
    if Radio.visible then return end

    local vehicle = currentVehicle()
    if not vehicle then
        notify('You need to be in a vehicle')
        return
    end

    local netId = VehToNet(vehicle)
    local info = Callback.await('binary-radio:opened', netId)
    if not info then return end

    Radio.visible = true
    Radio.netId = netId
    Radio.canControl = info.canControl
    Radio.repeatOn = info.repeatOn == true

    SetNuiFocus(true, true)
    SendNUIMessage({ action = 'visibility', open = true })
    SendNUIMessage({
        action = 'audioConfig',
        options = {
            refDistance = config.advanced.fullVolumeDistance,
            maxDistance = config.hearingDistance,
            rolloff = config.advanced.falloff,
            panningModel = 'HRTF',
            crossfadeMs = config.advanced.fadeMs,
            maxEmitters = config.advanced.maxRadiosHeard,
        },
    })

    Radio.push(info)
end

function Radio.toggle()
    if Radio.visible then
        Radio.hide()
        return
    end

    Radio.show()
end

AddEventHandler('binary-radio:client:changedEmitter', function(netId, data)
    if not Radio.visible or Radio.netId ~= netId then return end
    if not data then return Radio.hide() end
    Radio.push()
end)

RegisterNetEvent('binary-radio:client:changedRadio', function(netId, data)
    if type(netId) ~= 'number' then return end

    Emitters.set(netId, data)
    if Radio.visible and Radio.netId == netId then Radio.push() end
end)

RegisterNetEvent('binary-radio:client:changedQueue', function(netId, queue)
    if not Radio.visible or Radio.netId ~= netId then return end
    SendNUIMessage({ action = 'state', state = { queue = queue } })
end)

RegisterNetEvent('binary-radio:client:changedRepeat', function(netId, enabled)
    if type(netId) ~= 'number' or type(enabled) ~= 'boolean' then return end
    if not Radio.visible or Radio.netId ~= netId then return end

    Radio.repeatOn = enabled
    SendNUIMessage({ action = 'state', state = { ['repeat'] = enabled } })
end)

RegisterCommand('binaryRadioToggle', function()
    if Radio.visible then
        Radio.hide()
        return
    end

    if not currentVehicle() then return end
    Radio.show()
end, false)

RegisterKeyMapping('binaryRadioToggle', 'Open the vehicle radio', 'keyboard', config.keybind)

RegisterCommand(config.command, function()
    Radio.toggle()
end, false)

CreateThread(function()
    while not NetworkIsSessionStarted() do Wait(250) end
    resolveStreamBase()
end)

CreateThread(function()
    while true do
        Wait(500)

        if Radio.visible then
            local vehicle = currentVehicle()
            if not vehicle or VehToNet(vehicle) ~= Radio.netId then Radio.hide() end
        end
    end
end)

AddEventHandler('onResourceStop', function(name)
    if name ~= GetCurrentResourceName() then return end
    SetNuiFocus(false, false)
end)
