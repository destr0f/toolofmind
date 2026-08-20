-- Session-safe PSX Network4/Network5 resolver.
-- Reads the live network module's existing route tables without executing its internal
-- GetRemoteEvent/GetRemoteFunction accessors from the injected thread.

local MODULE_VERSION = "1.5.4"
local UINT32 = 4294967296
local NETWORK5_VLG_SECRET = "PSXOG:SECRET:NETWORK:VLG:12910259120591716249102"

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
local inboundCache = {}

local function generationOf(context)
    return type(context) == "table" and tonumber(context.Generation) or 0
end

local function cacheSize(cache)
    local count = 0
    for _ in pairs(cache) do count = count + 1 end
    return count
end

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

-- Some older PSX OG builds used a plain unsigned DJB2 command hash. Keep it as
-- a compatibility candidate after the current session-bound Network5 route.
local function djb2Hash(message)
    message = tostring(message or "")
    local value = 5381
    for index = 1, #message do
        value = (value * 33 + string.byte(message, index)) % UINT32
    end
    return tostring(value)
end

local function routeHash(context, kind, commandName)
    local gameObject = context.Game or game
    local jobId = tostring(gameObject.JobId or "")
    if jobId == "" then jobId = "00000000-0000-0000-0000-000000000000" end
    -- Current PSX OG Network5 VLG route captured on 2026-08-20. The physical
    -- hash remains session-bound and is never persisted between executions.
    local source = NETWORK5_VLG_SECRET .. "/Network5/"
        .. tostring(gameObject.GameId) .. "/"
        .. tostring(gameObject.PlaceId) .. "/"
        .. tostring(gameObject.PlaceVersion) .. "/"
        .. jobId .. "/" .. tostring(kind) .. "/" .. tostring(commandName)
    return string.sub(sha256(source), 5, 36)
end

local function routeHashes(context, kind, commandName, liveHash)
    local candidates, seen = {}, {}
    local function add(value, source)
        if type(value) ~= "string" or value == "" or seen[value] then return end
        seen[value] = true
        candidates[#candidates + 1] = { Value = value, Source = source }
    end
    add(liveHash, "live command map")
    add(routeHash(context, kind, commandName), "current Network5 VLG")
    add(djb2Hash(commandName), "legacy DJB2")
    return candidates
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

local function networkHashOf(context, remote)
    if type(context.RemoteNetworkHash) == "function" then
        local ok, value = pcall(context.RemoteNetworkHash, remote)
        if ok and type(value) == "string" and value ~= "" then return value end
    end
    if typeof(remote) ~= "Instance" then return nil end
    local ok, value = pcall(remote.GetAttribute, remote, "NetworkHash")
    if ok and type(value) == "string" and value ~= "" then return value end
    return nil
end

-- Network5 renames a materialised physical route to RemoteEvent/RemoteFunction
-- and preserves its original hash in the NetworkHash attribute. The live t4
-- map is authoritative; this one bounded direct-child pass is cold-path only.
local function findRemote(context, kind, className, remoteMaps, candidates)
    local map = type(remoteMaps) == "table" and remoteMaps[kind] or nil
    local storage = context.ReplicatedStorage
    for _, candidate in ipairs(candidates) do
        local found = type(map) == "table" and rawget(map, candidate.Value) or nil
        if not liveRemote(context, found, className) then
            found = storage and storage:FindFirstChild(candidate.Value) or nil
        end
        if liveRemote(context, found, className) then
            return found, candidate.Source
        end
    end

    if not storage or type(storage.GetChildren) ~= "function" then return nil end
    local wanted = {}
    for _, candidate in ipairs(candidates) do wanted[candidate.Value] = candidate.Source end
    local ok, children = pcall(storage.GetChildren, storage)
    if not ok or type(children) ~= "table" then return nil end
    for _, child in ipairs(children) do
        if liveRemote(context, child, className) then
            local hash = networkHashOf(context, child)
            local source = hash and wanted[hash] or nil
            if source then return child, source .. " via NetworkHash attribute" end
        end
    end
    return nil
end

local function readUpvalue(context, callback, index)
    if type(context.FunctionUpvalueAt) ~= "function" then return nil end
    local value = context.FunctionUpvalueAt(callback, index)
    return value
end

local function validPairMaps(value)
    return type(value) == "table"
        and type(value[1]) == "table"
        and type(value[2]) == "table"
end

local function validBridgeMaps(value)
    return validPairMaps(value)
        and type(value[3]) == "table"
        and type(value[4]) == "table"
end

local function networkTables(context, method)
    -- Current Network5 stores the command hasher, Remote maps and Bindable
    -- bridge maps directly in Network.Fire/Invoke upvalues 1, 2 and 6.
    -- Resolve this layout first; session hashes are still read from the live
    -- tables and are never persisted or hard-coded.
    local directHasher = readUpvalue(context, method, 1)
    local directRemoteMaps = readUpvalue(context, method, 2)
    local directBridgeMaps = readUpvalue(context, method, 6)
    local directHashMaps = type(directHasher) == "function"
        and readUpvalue(context, directHasher, 1) or nil

    local remoteMaps = validPairMaps(directRemoteMaps) and directRemoteMaps or nil
    local bridgeMaps = validBridgeMaps(directBridgeMaps) and directBridgeMaps or nil
    local hashMaps = validPairMaps(directHashMaps) and directHashMaps or nil
    local remoteAccessorIndex = remoteMaps and 2 or nil
    local bridgeAccessorIndex = bridgeMaps and 6 or nil

    -- Compatibility with the older nested accessor layout remains available
    -- for servers that have not moved to the direct Network5 upvalue layout.
    for accessorIndex = 1, 8 do
        local accessor = readUpvalue(context, method, accessorIndex)
        if type(accessor) == "function" then
            local lookup = readUpvalue(context, accessor, 1)
            local hasher = readUpvalue(context, accessor, 2)
            local candidateMaps = type(lookup) == "function"
                and readUpvalue(context, lookup, 1) or nil
            local candidateHashes = type(hasher) == "function"
                and readUpvalue(context, hasher, 1) or nil
            local validMaps = validPairMaps(candidateMaps)
            local validHashes = validPairMaps(candidateHashes)
            if validMaps and validHashes then
                hashMaps = hashMaps or candidateHashes
                if validBridgeMaps(candidateMaps) then
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
    return remoteMaps, bridgeMaps, hash, remoteIndex, bridgeIndex, nil
end

local function resolve(context, kind, commandName)
    if type(context) ~= "table" then return nil, "Network4", nil, "context is missing" end
    if kind ~= 1 and kind ~= 2 then return nil, "Network4", nil, "invalid network kind" end
    if type(commandName) ~= "string" or commandName == "" then
        return nil, "Network4", nil, "command name is invalid"
    end

    local className = kind == 1 and "RemoteEvent" or "RemoteFunction"
    local generation = generationOf(context)
    local cached = routeCache[kind][commandName]
    if type(cached) == "table" and cached.Generation == generation
        and liveRemote(context, cached.Remote, className) then
        return cached.Remote, cached.Source, cached.SessionIndex, nil
    end
    routeCache[kind][commandName] = nil

    local remoteMaps, _, liveHash, accessorIndex, _, stateProblem =
        routeState(context, kind, commandName)
    if stateProblem then return nil, "Network4", nil, stateProblem end

    local candidates = routeHashes(context, kind, commandName, liveHash)
    local remote, hashSource = findRemote(context, kind, className, remoteMaps, candidates)
    if not liveRemote(context, remote, className) then
        local detail = remoteMaps and "hashed route is not present in the live Network5 map"
            or "Network5 route tables are unavailable"
        return nil, "Network5 hashed " .. className, nil, detail
    end

    local source = "Network5 hashed " .. className .. " cache ["
        .. tostring(hashSource or "unknown hash") .. "]"
        .. (accessorIndex and (" via accessor #" .. tostring(accessorIndex)) or "")
    local sessionIndex = type(context.RemoteSessionIndex) == "function"
        and context.RemoteSessionIndex(remote) or nil
    routeCache[kind][commandName] = {
        Remote = remote,
        Source = source,
        SessionIndex = sessionIndex,
        Generation = generation,
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
    local generation = generationOf(context)
    local cached = bridgeCache[kind][commandName]
    if type(cached) == "table" and cached.Generation == generation
        and liveBridge(context, cached.Bridge, className) then
        return cached.Bridge, cached.Source, nil, nil
    end
    bridgeCache[kind][commandName] = nil

    local _, bridgeMaps, liveHash, _, accessorIndex, stateProblem =
        routeState(context, kind, commandName)
    if stateProblem then return nil, "Network4", nil, stateProblem end
    local bridgeKind = kind + 2
    local bridge, hashSource
    for _, candidate in ipairs(routeHashes(context, kind, commandName, liveHash)) do
        local found = type(bridgeMaps) == "table" and type(bridgeMaps[bridgeKind]) == "table"
            and rawget(bridgeMaps[bridgeKind], candidate.Value) or nil
        if liveBridge(context, found, className) then
            bridge = found
            hashSource = candidate.Source
            break
        end
    end
    if not liveBridge(context, bridge, className) then
        return nil, "Network4 native " .. className, nil,
            bridgeMaps and "native command bridge is absent"
                or "Network4 bridge tables are unavailable"
    end

    local source = "Network4 native " .. className .. " bridge ["
        .. tostring(hashSource or "unknown hash") .. "]"
        .. (accessorIndex and (" via accessor #" .. tostring(accessorIndex)) or "")
    bridgeCache[kind][commandName] = {
        Bridge = bridge,
        Source = source,
        Generation = generation,
    }
    return bridge, source, nil, nil
end

-- Inbound (server -> client) command signals. Prefer the current Network5
-- module's own Fired resolver: it returns the same t4[1][hash].OnClientEvent or
-- t2[1][hash].Event used by the game's LocalScripts and performs no outbound
-- request. Keep direct table discovery only as a compatibility fallback.
local function resolveInboundEvent(context, commandName)
    if type(context) ~= "table" then return nil, "Network4 inbound", nil, "context is missing" end
    if type(commandName) ~= "string" or commandName == "" then
        return nil, "Network4 inbound", nil, "command name is invalid"
    end

    local generation = generationOf(context)
    local cached = inboundCache[commandName]
    if type(cached) == "table" and cached.Generation == generation then
        local holderLive = cached.IsNative == true
            or (cached.IsRemote and liveRemote(context, cached.Holder, "RemoteEvent"))
            or (cached.IsRemote == false and liveBridge(context, cached.Holder, "BindableEvent"))
        if holderLive and cached.Signal and type(cached.Signal.Connect) == "function" then
            return cached.Signal, cached.Source, nil, nil
        end
    end
    inboundCache[commandName] = nil

    local network = context.Library and context.Library.Network
    local fired = network and network.Fired
    if type(fired) == "function" then
        local ok, signal = pcall(fired, commandName)
        if ok and signal and type(signal.Connect) == "function" then
            local source = "Network5 native Fired signal"
            inboundCache[commandName] = {
                Signal = signal,
                Holder = nil,
                IsNative = true,
                Source = source,
                Generation = generation,
            }
            return signal, source, nil, nil
        end
    end

    local remoteMaps, bridgeMaps, liveHash, remoteIndex, bridgeIndex, stateProblem =
        routeState(context, 1, commandName)
    if stateProblem then return nil, "Network4 inbound", nil, stateProblem end

    local candidates = routeHashes(context, 1, commandName, liveHash)
    local remote, remoteSource = findRemote(context, 1, "RemoteEvent", remoteMaps, candidates)
    if liveRemote(context, remote, "RemoteEvent") then
        local signal = remote.OnClientEvent
        local source = "Network5 inbound RemoteEvent [" .. tostring(remoteSource) .. "]"
            .. (remoteIndex and (" via accessor #" .. tostring(remoteIndex)) or "")
        inboundCache[commandName] = {
            Signal = signal,
            Holder = remote,
            IsRemote = true,
            Source = source,
            Generation = generation,
        }
        return signal, source, nil, nil
    end

    for _, candidate in ipairs(candidates) do
        local bridge = type(bridgeMaps) == "table" and type(bridgeMaps[1]) == "table"
            and rawget(bridgeMaps[1], candidate.Value) or nil
        if liveBridge(context, bridge, "BindableEvent") then
            local signal = bridge.Event
            local source = "Network4 inbound BindableEvent bridge [" .. tostring(candidate.Source) .. "]"
                .. (bridgeIndex and (" via accessor #" .. tostring(bridgeIndex)) or "")
            inboundCache[commandName] = {
                Signal = signal,
                Holder = bridge,
                IsRemote = false,
                Source = source,
                Generation = generation,
            }
            return signal, source, nil, nil
        end
    end

    return nil, "Network4 inbound", nil,
        "inbound route unavailable: no live t4 RemoteEvent and no exact t2[1] bridge"
end

local function invalidate(context, kind, commandName, expected)    if kind ~= 1 and kind ~= 2 then return false, "invalid network kind" end
    if type(commandName) ~= "string" or commandName == "" then
        return false, "command name is invalid"
    end
    local generation = generationOf(context)
    local inbound = inboundCache[commandName]
    if type(inbound) == "table" and inbound.Generation == generation
        and (expected == nil or inbound.Holder == expected) then
        inboundCache[commandName] = nil
    end
    local route = routeCache[kind][commandName]
    if type(route) == "table" and route.Generation == generation
        and (expected == nil or route.Remote == expected) then
        routeCache[kind][commandName] = nil
    end
    local bridge = bridgeCache[kind][commandName]
    if type(bridge) == "table" and bridge.Generation == generation
        and (expected == nil or bridge.Bridge == expected) then
        bridgeCache[kind][commandName] = nil
    end
    return true
end

local function stats()
    return {
        EventRoutes = cacheSize(routeCache[1]),
        FunctionRoutes = cacheSize(routeCache[2]),
        FireBridges = cacheSize(bridgeCache[1]),
        InvokeBridges = cacheSize(bridgeCache[2]),
        InboundSignals = cacheSize(inboundCache),
    }
end

return function(action, ...)
    if action == "version" then return MODULE_VERSION end
    if action == "sha256" then return sha256(...) end
    if action == "djb2Hash" then return djb2Hash(...) end
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
    if action == "resolveInboundEvent" then
        local context, commandName = ...
        return resolveInboundEvent(context, commandName)
    end
    if action == "invalidate" then
        local context, kind, commandName, expected = ...
        return invalidate(context, kind, commandName, expected)
    end
    if action == "stats" then return stats() end
    if action == "clear" then
        table.clear(routeCache[1])
        table.clear(routeCache[2])
        table.clear(bridgeCache[1])
        table.clear(bridgeCache[2])
        table.clear(inboundCache)
        return true
    end
    return nil, "unknown Network4 transport action: " .. tostring(action)
end
