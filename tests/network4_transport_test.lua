local transport = require("../network4_transport_module")

assert(transport("version") == "1.0.0")
assert(transport("sha256", "") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
assert(transport("sha256", "abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")

local remoteMaps = { {}, {} }
local hashMaps = { {}, {} }
local function lookup() return remoteMaps end
local function hasher() return hashMaps end
local function accessor() return lookup, hasher end
local function validator() return true end
local function invoke() return validator, accessor end

local upvalues = {
    [invoke] = { validator, accessor },
    [accessor] = { lookup, hasher },
    [lookup] = { remoteMaps },
    [hasher] = { hashMaps },
}
local fakeGame = {
    GameId = 123,
    PlaceId = 456,
    PlaceVersion = 7,
    JobId = "job-test",
}
local context = {
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

print("PASS Network4 SHA-256 and read-only route resolution")
