local transport = require("../network4_transport_module")

assert(transport("version") == "1.5.4")
assert(transport("sha256", "") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
assert(transport("sha256", "abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
assert(transport("djb2Hash", "Get The Coins") == "2442970594")
assert(transport("djb2Hash", "Use Golden Machine") == "1951370400")

local remoteMaps = { {}, {} }
local bridgeMaps = { {}, {}, {}, {} }
local hashMaps = { {}, {} }
local function lookup() return remoteMaps end
local function bridgeLookup() return bridgeMaps end
local function hasher() return hashMaps end
local function accessor() return lookup, hasher end
local function bridgeAccessor() return bridgeLookup, hasher end
local function validator() return true end
local function invoke() return validator, accessor, bridgeAccessor end

local upvalues = {
    [invoke] = { validator, accessor, bridgeAccessor },
    [accessor] = { lookup, hasher },
    [bridgeAccessor] = { bridgeLookup, hasher },
    [lookup] = { remoteMaps },
    [bridgeLookup] = { bridgeMaps },
    [hasher] = { hashMaps },
}
local fakeGame = {
    GameId = 123,
    PlaceId = 456,
    PlaceVersion = 7,
    JobId = "job-test",
}
local context = {
    Generation = 1,
    Game = fakeGame,
    Library = { Network = { Invoke = invoke } },
    ReplicatedStorage = { FindFirstChild = function() return nil end },
    FunctionUpvalueAt = function(callback, index)
        local values = upvalues[callback]
        return values and values[index] or nil
    end,
    IsRemote = function(remote, className)
        return type(remote) == "table" and remote.ClassName == className
    end,
    IsBridge = function(bridge, className)
        return type(bridge) == "table" and bridge.ClassName == className
    end,
    RemoteSessionIndex = function() return 99 end,
}

local hash = transport("routeHash", context, 2, "Buy Boost Bundle")
assert(type(hash) == "string" and #hash == 32)
assert(hash == "67d7e0fc5eb9dd69b8e377a665b12760")
local remote = { ClassName = "RemoteFunction" }
remoteMaps[2][hash] = remote

local resolved, source, sessionIndex, problem = transport(
    "resolveFunction",
    context,
    "Buy Boost Bundle"
)
assert(resolved == remote, tostring(problem))
assert(string.find(source, "Network5 hashed RemoteFunction", 1, true))
assert(sessionIndex == 99)

local bridge = { ClassName = "BindableFunction" }
bridgeMaps[4][hash] = bridge
local resolvedBridge, bridgeSource, _, bridgeProblem = transport(
    "resolveInvokeBridge",
    context,
    "Buy Boost Bundle"
)
assert(resolvedBridge == bridge, tostring(bridgeProblem))
assert(string.find(bridgeSource, "Network4 native BindableFunction bridge", 1, true))

local stats = transport("stats")
assert(stats.FunctionRoutes == 1 and stats.InvokeBridges == 1)

-- Exact invalidation removes only one command and never keeps a stale remote
-- after the live Network map is rebound.
local secondHash = transport("routeHash", context, 2, "Get OSTime")
local secondRemote = { ClassName = "RemoteFunction" }
remoteMaps[2][secondHash] = secondRemote
assert(transport("resolveFunction", context, "Get OSTime") == secondRemote)
assert(transport("stats").FunctionRoutes == 2)

local replacement = { ClassName = "RemoteFunction" }
remoteMaps[2][hash] = replacement
assert(transport("invalidate", context, 2, "Buy Boost Bundle", remote) == true)
assert(transport("resolveFunction", context, "Buy Boost Bundle") == replacement)
assert(transport("resolveFunction", context, "Get OSTime") == secondRemote,
    "exact invalidation evicted an unrelated route")

-- A generation change invalidates cached session objects without a global
-- clear and resolves against the current map.
context.Generation = 2
local generationRemote = { ClassName = "RemoteFunction" }
remoteMaps[2][secondHash] = generationRemote
assert(transport("resolveFunction", context, "Get OSTime") == generationRemote)

transport("clear")
local empty = transport("stats")
assert(empty.EventRoutes == 0 and empty.FunctionRoutes == 0
    and empty.FireBridges == 0 and empty.InvokeBridges == 0)

-- Current Network5 layout: hasher, remote maps and bridge maps are direct
-- method upvalues 1, 2 and 6 instead of nested accessor callbacks.
local directHashMaps = { {}, {} }
local directRemoteMaps = { {}, {} }
local directBridgeMaps = { {}, {}, {}, {} }
local function directHasher() return directHashMaps end
local function directInvoke() return true end
local directUpvalues = {
    [directInvoke] = {
        directHasher,
        directRemoteMaps,
        {},
        { "RemoteEvent", "RemoteFunction" },
        {},
        directBridgeMaps,
        { "BindableEvent", "BindableFunction" },
    },
    [directHasher] = { directHashMaps },
}
local directContext = {
    Generation = 3,
    Game = fakeGame,
    Library = { Network = { Invoke = directInvoke } },
    ReplicatedStorage = { FindFirstChild = function() return nil end },
    FunctionUpvalueAt = function(callback, index)
        local values = directUpvalues[callback]
        return values and values[index] or nil
    end,
    IsRemote = context.IsRemote,
    IsBridge = context.IsBridge,
    RemoteSessionIndex = function() return 123 end,
}
local directCommand = "Get Golden Machine Info"
local directHash = transport("routeHash", directContext, 2, directCommand)
directHashMaps[2][directCommand] = directHash
local directRemote = { ClassName = "RemoteFunction" }
local directBridge = { ClassName = "BindableFunction" }
directRemoteMaps[2][directHash] = directRemote
directBridgeMaps[4][directHash] = directBridge

local directResolved, directSource, directSession, directProblem = transport(
    "resolveFunction", directContext, directCommand
)
assert(directResolved == directRemote, tostring(directProblem))
assert(string.find(directSource, "accessor #2", 1, true))
assert(directSession == 123)
local directBridgeResolved, directBridgeSource, _, directBridgeProblem = transport(
    "resolveInvokeBridge", directContext, directCommand
)
assert(directBridgeResolved == directBridge, tostring(directBridgeProblem))
assert(string.find(directBridgeSource, "accessor #6", 1, true))

-- Current Network5 VLG layout can expose a command before its native command
-- map is warm. The resolver derives the exact current-session hash locally.
transport("clear")
local coldCommand = "Get Dark Matter Machine Info"
local coldHash = transport("routeHash", context, 2, coldCommand)
local coldRemote = { ClassName = "RemoteFunction" }
local coldContext = {
    Generation = 4,
    Game = fakeGame,
    Library = { Network = { Invoke = invoke } },
    ReplicatedStorage = {
        FindFirstChild = function(_, name)
            return name == coldHash and coldRemote or nil
        end,
    },
    FunctionUpvalueAt = context.FunctionUpvalueAt,
    IsRemote = context.IsRemote,
    IsBridge = context.IsBridge,
    RemoteSessionIndex = function() return "RemoteFunction" end,
}
local coldResolved, coldSource, coldSession, coldProblem = transport(
    "resolveFunction", coldContext, coldCommand
)
assert(coldResolved == coldRemote, tostring(coldProblem))
assert(string.find(coldSource, "current Network5 VLG", 1, true))
assert(coldSession == "RemoteFunction")

transport("clear")

-- Once the game materialises a route it renames the instance to its generic
-- class and preserves the original hash in the NetworkHash attribute. A single
-- bounded direct-child scan recovers that route without invoking game accessors.
local attributeCommand = "Buy Egg Yay"
local attributeHash = transport("routeHash", context, 2, attributeCommand)
local attributeRemote = { ClassName = "RemoteFunction", NetworkHash = attributeHash }
local attributeContext = {
    Generation = 5,
    Game = fakeGame,
    Library = { Network = { Invoke = invoke } },
    ReplicatedStorage = {
        FindFirstChild = function() return nil end,
        GetChildren = function() return { attributeRemote } end,
    },
    FunctionUpvalueAt = context.FunctionUpvalueAt,
    IsRemote = context.IsRemote,
    IsBridge = context.IsBridge,
    RemoteNetworkHash = function(remoteValue) return remoteValue.NetworkHash end,
    RemoteSessionIndex = function() return attributeHash end,
}
local attributeResolved, attributeSource, attributeSession, attributeProblem = transport(
    "resolveFunction", attributeContext, attributeCommand
)
assert(attributeResolved == attributeRemote, tostring(attributeProblem))
assert(string.find(attributeSource, "NetworkHash attribute", 1, true))
assert(attributeSession == attributeHash)

transport("clear")

-- Inbound coin feed: prefer the game's own Network.Fired resolver. Current
-- Network5 returns the shared t4[1]/t2[1] signal and performs no outbound call.
local nativeSignal = { fake = "network-fired", Connect = function() end }
local nativeCalls = 0
local nativeContext = {
    Generation = 5,
    Library = { Network = { Fired = function(commandName)
        nativeCalls = nativeCalls + 1
        assert(commandName == "New Coin")
        return nativeSignal
    end } },
}
local nativeResolved, nativeSource, _, nativeProblem = transport(
    "resolveInboundEvent", nativeContext, "New Coin"
)
assert(nativeResolved == nativeSignal, tostring(nativeProblem))
assert(nativeCalls == 1)
assert(string.find(nativeSource, "native Fired signal", 1, true))

-- Without Network.Fired, take the game's own t4[1] RemoteEvent OnClientEvent,
-- then the exact t2[1] inbound BindableEvent bridge, and never fabricate a
-- stand-in when both are absent.
local inboundContext = {
    Generation = 6,
    Game = fakeGame,
    Library = { Network = { Fire = invoke } },
    ReplicatedStorage = { FindFirstChild = function() return nil end },
    FunctionUpvalueAt = context.FunctionUpvalueAt,
    IsRemote = context.IsRemote,
    IsBridge = context.IsBridge,
}
local inboundHash = "djb2-new-coin"
hashMaps[1]["New Coin"] = inboundHash
local inboundSignal = { fake = "on-client-event" }
local inboundRemote = { ClassName = "RemoteEvent", OnClientEvent = inboundSignal }
remoteMaps[1][inboundHash] = inboundRemote

local feedSignal, feedSource, _, feedProblem = transport(
    "resolveInboundEvent", inboundContext, "New Coin"
)
assert(feedSignal == inboundSignal, tostring(feedProblem))
assert(string.find(feedSource, "inbound RemoteEvent", 1, true))

-- Remote lost: only the exact t2[1] inbound bridge may replace it.
remoteMaps[1][inboundHash] = nil
inboundContext.Generation = 7
local bridgeSignal = { fake = "inbound-bridge-event" }
bridgeMaps[1][inboundHash] = { ClassName = "BindableEvent", Event = bridgeSignal }
local feedSignal2, feedSource2, _, feedProblem2 = transport(
    "resolveInboundEvent", inboundContext, "New Coin"
)
assert(feedSignal2 == bridgeSignal, tostring(feedProblem2))
assert(string.find(feedSource2, "inbound BindableEvent bridge", 1, true))

-- Neither t4 nor t2[1]: the resolver reports FEED_UNAVAILABLE instead of
-- returning an orphaned bindable that would fake a live feed.
bridgeMaps[1][inboundHash] = nil
inboundContext.Generation = 8
local deadSignal, _, _, deadProblem = transport(
    "resolveInboundEvent", inboundContext, "New Coin"
)
assert(deadSignal == nil)
assert(string.find(tostring(deadProblem), "inbound route unavailable", 1, true))

transport("clear")
print("PASS current Network5 VLG direct/nested maps, cold hash/attribute lookup, generation cache, invalidation, bridges and inbound feed")
