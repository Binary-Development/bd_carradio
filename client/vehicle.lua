Cabin = {}

local doors = { 0, 1, 2, 3 }
local windows = { 0, 1, 2, 3 }
local samples = {}
local sampleLifetime = 250
local sweepEvery = 30000
local lastSweep = 0

local function hasOpenWindow(vehicle)
    for i = 1, #windows do
        if not IsVehicleWindowIntact(vehicle, windows[i]) then return true end
    end

    return false
end

local function hasOpenRoof(vehicle)
    local state = GetConvertibleRoofState(vehicle)
    return state == 1 or state == 2
end

local function measure(vehicle)
    if hasOpenRoof(vehicle) or hasOpenWindow(vehicle) then return -1.0 end

    local widest = 0.0

    for i = 1, #doors do
        local ratio = GetVehicleDoorAngleRatio(vehicle, doors[i])
        if ratio > widest then widest = ratio end
    end

    if widest <= 0.05 then return 0.0 end

    return math.min(widest, 1.0) * config.advanced.doorAperture
end

---@param vehicle number
---@return number aperture 0 when sealed, 1 when open to the air, -1 when breached
local function apertureOf(vehicle)
    local now = GetGameTimer()
    local sample = samples[vehicle]

    if sample and now - sample.at < sampleLifetime then return sample.value end

    if now - lastSweep > sweepEvery then
        lastSweep = now

        for handle, held in pairs(samples) do
            if now - held.at > sweepEvery then samples[handle] = nil end
        end
    end

    local value = measure(vehicle)

    if sample then
        sample.at = now
        sample.value = value
    else
        samples[vehicle] = { at = now, value = value }
    end

    return value
end

function Cabin.insideAcoustics()
    return config.advanced.openCutoff, config.advanced.insideVolume
end

function Cabin.outsideAcoustics(vehicle)
    if not DoesEntityExist(vehicle) then return config.advanced.openCutoff, config.outsideVolume end

    local aperture = apertureOf(vehicle)
    if aperture < 0 then return config.advanced.occludedCutoff, config.outsideVolume end

    local sealed = config.advanced.sealedCutoff

    return sealed * (config.advanced.openCutoff / sealed) ^ aperture, config.outsideVolume
end
