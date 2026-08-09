-- Session-safe PSX Network4 resolver.
-- Reads Network4's existing route tables without executing its internal
-- GetRemoteEvent/GetRemoteFunction accessors from the injected thread.

local MODULE_VERSION = "1.1.0"
local UINT32 = 4294967296

local SHA256_K = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
    0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
    0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
    0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
    0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
    0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

local routeCache = { [1] = {}, [2] = {} }
local bridgeCache = { [1] = {}, [2] = {} }

local function add32(...)
    local total = 0
    for index = 1, select("#", ...) do
        total = (total + select(index, ...)) % UINT32
    end
    return total
end

local function sha256(message)
    message = tostring(message or "")
    local bytes = { string.byte(message, 1, #message) }
    local bitLength = #bytes * 8
    bytes[#bytes + 1] = 0x80
    while #bytes % 64 ~= 56 do bytes[#bytes + 1] = 0 end

    local high = math.floor(bitLength / UINT32)
    local low = bitLength % UINT32
    for shift = 24, 0, -8 do bytes[#bytes + 1] = bit32.band(bit32.rshift(high, shift), 0xff) end
    for shift = 24, 0, -8 do bytes[#bytes + 1] = bit32.band(bit32.rshift(low, shift), 0xff) end

    local h0, h1, h2, h3 = 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a
    local h4, h5, h6, h7 = 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19

    for offset = 1, #bytes, 64 do
        local words = table.create(64, 0)
        for index = 0, 15 do
            local cursor = offset + index * 4
            words[index + 1] = bytes[cursor] * 0x1000000
                + bytes[cursor + 1] * 0x10000
                + bytes[cursor + 2] * 0x100
                + bytes[cursor + 3]
        end
        for index = 17, 64 do
            local x = words[index - 15]
            local y = words[index - 2]
            local s0 = bit32.bxor(bit32.rrotate(x, 7), bit32.rrotate(x, 18), bit32.rshift(x, 3))
            local s1 = bit32.bxor(bit32.rrotate(y, 17), bit32.rrotate(y, 19), bit32.rshift(y, 10))
            words[index] = add32(words[index - 16], s0, words[index - 7], s1)
        end

        local a, b, c, d = h0, h1, h2, h3
        local e, f, g, h = h4, h5, h6, h7
        for index = 1, 64 do
            local s1 = bit32.bxor(bit32.rrotate(e, 6), bit32.rrotate(e, 11), bit32.rrotate(e, 25))
            local choice = bit32.bxor(bit32.band(e, f), bit32.band(bit32.bnot(e), g))
            local temp1 = add32(h, s1, choice, SHA256_K[index], words[index])
            local s0 = bit32.bxor(bit32.rrotate(a, 2), bit32.rrotate(a, 13), bit32.rrotate(a, 22))
            local majority = bit32.bxor(bit32.band(a, b), bit32.band(a, c), bit32.band(b, c))
            local temp2 = add32(s0, majority)
            h, g, f, e, d, c, b, a = g, f, e, add32(d, temp1), c, b, a, add32(temp1, temp2)
        end

        h0, h1, h2, h3 = add32(h0, a), add32(h1, b), add32(h2, c), add32(h3, d)
        h4, h5, h6, h7 = add32(h4, e), add32(h5, f), add32(h6, g), add32(h7, h)
    end

    return string.format("%08x%08x%08x%08x%08x%08x%08x%08x", h0, h1, h2, h3, h4, h5, h6, h7)
end

local function routeHash(context, kind, commandName)
    local gameObject = context.Game or game
    local jobId = tostring(gameObject.JobId or "")
    if jobId == "" then jobId = "00000000-0000-0000-0000-000000000000" end
    local source = "duskissexyyyyy123iloveudUsk/Network4/"
        .. tostring(gameObject.GameId) .. "/"
        .. tostring(gameObject.PlaceId) .. "/"
        .. tostring(gameObject.PlaceVersion) .. "/"
        .. jobId .. "/" .. tostring(kind) .. "/" .. tostring(commandName)
    return string.sub(sha256(source), 5, 36)
end

local function liveRemote(context, remote, className)
    if type(context.IsRemote) == "function" then return context.IsRemote(remote, className) end
    local storage = context.ReplicatedStorage
    return typeof(remote) == "Instance" and remote:IsA(className)
        and (not storage or remote:IsDescendantOf(storage))
end

local function liveBridge(context, bridge, className)
    if type(context.IsBridge) == "function" then return context.IsBridge(bridge, className) end
    return typeof(bridge) == "Instance" and bridge:IsA(className) and bridge.Parent ~= nil
end

local function readUpvalue(context, callback, index)
    if type(context.FunctionUpvalueAt) ~= "function" then return nil end
    local value = context.FunctionUpvalueAt(callback, index)
    return value
end

local function networkTables(context, method)
    local remoteMaps, bridgeMaps, hashMaps
    local remoteAccessorIndex, bridgeAccessorIndex
    for accessorIndex = 1, 8 do
        local accessor = readUpvalue(context, method, accessorIndex)
        if type(accessor) == "function" then
            local lookup = readUpvalue(context, accessor, 1)
            local hasher = readUpvalue(context, accessor, 2)
            local candidateMaps = type(lookup) == "function"
                and readUpvalue(context, lookup, 1) or nil
            local candidateHashes = type(hasher) == "function"
                and readUpvalue(context, hasher, 1) or nil
            local validMaps = type(candidateMaps) == "table"
                and type(candidateMaps[1]) == "table"
                and type(candidateMaps[2]) == "table"
            local validHashes = type(candidateHashes) == "table"
                and type(candidateHashes[1]) == "table"
                and type(candidateHashes[2]) == "table"
            if validMaps and validHashes then
                hashMaps = hashMaps or candidateHashes
                if type(candidateMaps[3]) == "table" and type(candidateMaps[4]) == "table" then
                    bridgeMaps = bridgeMaps or candidateMaps
                    bridgeAccessorIndex = bridgeAccessorIndex or accessorIndex
                else
                    remoteMaps = remoteMaps or candidateMaps
                    remoteAccessorIndex = remoteAccessorIndex or accessorIndex
                end
            end
        end
    end
    return remoteMaps, bridgeMaps, hashMaps, remoteAccessorIndex, bridgeAccessorIndex
end

local function routeState(context, kind, commandName)
    local network = context.Library and context.Library.Network
    local method = network and (kind == 1 and network.Fire or network.Invoke)
    if type(method) ~= "function" then
        return nil, nil, nil, nil, nil, "Library.Network method is unavailable"
    end

    local remoteMaps, bridgeMaps, hashMaps, remoteIndex, bridgeIndex =
        networkTables(context, method)
    local hash = type(hashMaps) == "table" and type(hashMaps[kind]) == "table"
        and rawget(hashMaps[kind], commandName) or nil
    if type(hash) ~= "string" or hash == "" then hash = routeHash(context, kind, commandName) end
    return remoteMaps, bridgeMaps, hash, remoteIndex, bridgeIndex, nil
end

local function resolve(context, kind, commandName)
    if type(context) ~= "table" then return nil, "Network4", nil, "context is missing" end
    if kind ~= 1 and kind ~= 2 then return nil, "Network4", nil, "invalid network kind" end
    if type(commandName) ~= "string" or commandName == "" then
        return nil, "Network4", nil, "command name is invalid"
    end

    local className = kind == 1 and "RemoteEvent" or "RemoteFunction"
    local cached = routeCache[kind][commandName]
    if type(cached) == "table" and liveRemote(context, cached.Remote, className) then
        return cached.Remote, cached.Source, cached.SessionIndex, nil
    end
    routeCache[kind][commandName] = nil

    local remoteMaps, _, hash, accessorIndex, _, stateProblem =
        routeState(context, kind, commandName)
    if stateProblem then return nil, "Network4", nil, stateProblem end

    local remote = type(remoteMaps) == "table" and type(remoteMaps[kind]) == "table"
        and rawget(remoteMaps[kind], hash) or nil
    if not liveRemote(context, remote, className) then
        local storage = context.ReplicatedStorage
        remote = storage and storage:FindFirstChild(hash) or nil
    end
    if not liveRemote(context, remote, className) then
        local detail = remoteMaps and "hashed route is not present in the live Network4 map"
            or "Network4 route tables are unavailable"
        return nil, "Network4 hashed " .. className, nil, detail
    end

    local source = "Network4 hashed " .. className .. " cache"
        .. (accessorIndex and (" via accessor #" .. tostring(accessorIndex)) or "")
    local sessionIndex = type(context.RemoteSessionIndex) == "function"
        and context.RemoteSessionIndex(remote) or nil
    routeCache[kind][commandName] = {
        Remote = remote,
        Source = source,
        SessionIndex = sessionIndex,
    }
    return remote, source, sessionIndex, nil
end

local function resolveBridge(context, kind, commandName)
    if type(context) ~= "table" then return nil, "Network4", nil, "context is missing" end
    if kind ~= 1 and kind ~= 2 then return nil, "Network4", nil, "invalid network kind" end
    if type(commandName) ~= "string" or commandName == "" then
        return nil, "Network4", nil, "command name is invalid"
    end

    local className = kind == 1 and "BindableEvent" or "BindableFunction"
    local cached = bridgeCache[kind][commandName]
    if type(cached) == "table" and liveBridge(context, cached.Bridge, className) then
        return cached.Bridge, cached.Source, nil, nil
    end
    bridgeCache[kind][commandName] = nil

    local _, bridgeMaps, hash, _, accessorIndex, stateProblem =
        routeState(context, kind, commandName)
    if stateProblem then return nil, "Network4", nil, stateProblem end
    local bridgeKind = kind + 2
    local bridge = type(bridgeMaps) == "table" and type(bridgeMaps[bridgeKind]) == "table"
        and rawget(bridgeMaps[bridgeKind], hash) or nil
    if not liveBridge(context, bridge, className) then
        return nil, "Network4 native " .. className, nil,
            bridgeMaps and "native command bridge is absent"
                or "Network4 bridge tables are unavailable"
    end

    local source = "Network4 native " .. className .. " bridge"
        .. (accessorIndex and (" via accessor #" .. tostring(accessorIndex)) or "")
    bridgeCache[kind][commandName] = { Bridge = bridge, Source = source }
    return bridge, source, nil, nil
end

return function(action, ...)
    if action == "version" then return MODULE_VERSION end
    if action == "sha256" then return sha256(...) end
    if action == "routeHash" then return routeHash(...) end
    if action == "resolveEvent" then
        local context, commandName = ...
        return resolve(context, 1, commandName)
    end
    if action == "resolveFunction" then
        local context, commandName = ...
        return resolve(context, 2, commandName)
    end
    if action == "resolveFireBridge" then
        local context, commandName = ...
        return resolveBridge(context, 1, commandName)
    end
    if action == "resolveInvokeBridge" then
        local context, commandName = ...
        return resolveBridge(context, 2, commandName)
    end
    if action == "clear" then
        table.clear(routeCache[1])
        table.clear(routeCache[2])
        table.clear(bridgeCache[1])
        table.clear(bridgeCache[2])
        return true
    end
    return nil, "unknown Network4 transport action: " .. tostring(action)
end
