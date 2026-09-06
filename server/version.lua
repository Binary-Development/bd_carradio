Version = {}

local resource = GetCurrentResourceName()
local repository = 'Binary-Development/bd_carradio'
local branch = 'main'

local function parse(value)
    local major, minor, patch = value:match('^(%d+)%.(%d+)%.(%d+)')
    if not major then return nil end
    return tonumber(major), tonumber(minor), tonumber(patch)
end

local function isNewer(remote, current)
    local rMajor, rMinor, rPatch = parse(remote)
    local cMajor, cMinor, cPatch = parse(current)
    if not rMajor or not cMajor then return false end

    if rMajor ~= cMajor then return rMajor > cMajor end
    if rMinor ~= cMinor then return rMinor > cMinor end
    return rPatch > cPatch
end

function Version.current()
    return GetResourceMetadata(resource, 'version', 0) or '0.0.0'
end

function Version.check()
    local current = Version.current()
    local url = ('https://raw.githubusercontent.com/%s/%s/version'):format(repository, branch)

    PerformHttpRequest(url, function(status, body)
        if status ~= 200 or type(body) ~= 'string' then return end

        local remote = body:match('[%d%.]+')
        if not remote or not isNewer(remote, current) then return end

        Log.print(('update available - v%s is on ^6github^7 (running v%s)'):format(remote, current))
    end, 'GET')
end
