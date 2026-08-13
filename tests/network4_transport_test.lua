local transport = require("../network4_transport_module")

assert(transport("version") == "1.2.0")
assert(transport("sha256", "") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
assert(transport("sha256", "abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")

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
local remote = { ClassName = "RemoteFunction" }
remoteMaps[2][hash] = remote

local resolved, source, sessionIndex, problem = transport(
    "resolveFunction",
    context,
    "Buy Boost Bundle"
)
assert(resolved == remote, tostring(problem))
assert(string.find(source, "Network4 hashed RemoteFunction", 1, true))
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

print("PASS Network4/5 hash, generation cache, exact invalidation and bridge resolution")
