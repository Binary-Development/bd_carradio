Callback = {}

local handlers = {}

function Callback.register(name, fn)
    handlers[name] = fn
end

if IsDuplicityVersion() then
    local rates = {}
    local window = 10000
    local perWindow = 60

    local function flooding(source)
        local now = GetGameTimer()
        local bucket = rates[source]

        if not bucket or now - bucket.since > window then
            rates[source] = { since = now, count = 1 }
            return false
        end

        bucket.count = bucket.count + 1
        return bucket.count > perWindow
    end

    RegisterNetEvent('binary-radio:server:requestedCallback', function(name, id, ...)
        local source = source
        if type(name) ~= 'string' or type(id) ~= 'number' then return end

        local fn = handlers[name]
        if not fn or flooding(source) then return end

        TriggerClientEvent('binary-radio:client:resolvedCallback', source, id, fn(source, ...))
    end)

    AddEventHandler('playerDropped', function()
        rates[source] = nil
    end)

    return
end

local pending = {}
local sequence = 0
local timeout = 150000

RegisterNetEvent('binary-radio:client:resolvedCallback', function(id, value)
    local p = pending[id]
    if not p then return end

    pending[id] = nil
    p:resolve(value)
end)

function Callback.await(name, ...)
    sequence = sequence + 1

    local id = sequence
    local p = promise.new()
    pending[id] = p

    SetTimeout(timeout, function()
        if not pending[id] then return end
        pending[id] = nil
        p:resolve(nil)
    end)

    TriggerServerEvent('binary-radio:server:requestedCallback', name, id, ...)
    return Citizen.Await(p)
end
