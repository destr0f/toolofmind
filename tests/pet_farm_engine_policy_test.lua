local engine = require("../pet_farm_engine")

local pets = { "pet-a", "pet-b", "pet-c" }

local keyed = engine("classify", {
    ["pet-a"] = true,
    ["pet-b"] = false,
    ["pet-c"] = true,
}, pets)
assert(keyed["pet-a"] == true and keyed["pet-c"] == true)
assert(keyed["pet-b"] == nil, "explicit false must remain rejected")

local array = engine("classify", { "pet-b", "pet-c" }, pets)
assert(array["pet-a"] == nil)
assert(array["pet-b"] == true and array["pet-c"] == true,
    "array-shaped Join Coin replies must be recognized")

local nested = engine("classify", {
    accepted = {
        { uid = "pet-a" },
        { PetId = "pet-c" },
    },
}, pets)
assert(nested["pet-a"] == true and nested["pet-c"] == true)
assert(nested["pet-b"] == nil)

local all = engine("classify", true, pets)
assert(all["pet-a"] and all["pet-b"] and all["pet-c"])

local none = engine("classify", false, pets)
assert(next(none) == nil)

assert(math.abs(engine("retry-delay", 1) - 0.06) < 0.0001)
assert(math.abs(engine("retry-delay", 2) - 0.12) < 0.0001)
assert(math.abs(engine("retry-delay", 3) - 0.24) < 0.0001)
assert(math.abs(engine("retry-delay", 9) - 0.24) < 0.0001)

task = {
    spawn = function(callback) callback() end,
    delay = function(_, callback) callback() end,
}

local states = {}
local fireCalls = 0
local network = {
    Invoke = function(command, _, requested)
        assert(command == "Join Coin")
        return { requested[1] }
    end,
    Fire = function(command)
        assert(command == "Change Pet Target" or command == "Farm Coin")
        fireCalls = fireCalls + 1
    end,
}

local started, startProblem = engine("start", {
    Running = function() return true end,
    Enabled = function() return true end,
    Resetting = function() return false end,
    NetworkReady = function() return network end,
    RecordAlive = function(record) return record.Alive end,
    StateCurrent = function(petId, state) return states[petId] == state end,
    TargetContainsPet = function() return false end,
    OnAccepted = function(petId, state)
        assert(states[petId] == state, "accepted callback received a stale lock")
        state.Phase = "locked"
        return true
    end,
    OnFailed = function() error("15-pet acceptance test must not fail") end,
    MinLanes = 4,
    InitialLanes = 16,
    MaxLanes = 16,
})
assert(started == true, tostring(startProblem))

for index = 1, 15 do
    local petId = "bulk-" .. tostring(index)
    local state = { Phase = "pending" }
    states[petId] = state
    local queued, queueProblem = engine("dispatch", {
        CoinId = "coin-" .. tostring(index),
        Record = { Alive = true },
        Entries = { { PetId = petId, State = state } },
    })
    assert(queued == true, tostring(queueProblem))
end

local dispatchStats = engine("stats")
assert(dispatchStats.Accepted == 15, "all 15 explicit UIDs should be accepted")
assert(dispatchStats.Rejected == 0 and dispatchStats.Errors == 0)
assert(dispatchStats.Queued == 0 and dispatchStats.Active == 0)
assert(fireCalls == 30, "each accepted lock needs exactly target + farm signals")
for _, state in pairs(states) do assert(state.Phase == "locked") end

local beforeRejects = dispatchStats.Rejected
local beforeRetries = dispatchStats.Retries
local failedCount = 0
network.Invoke = function() return false end
local failedState = { Phase = "pending" }
states["bounded-failure"] = failedState

local restarted = engine("start", {
    Running = function() return true end,
    Enabled = function() return true end,
    Resetting = function() return false end,
    NetworkReady = function() return network end,
    RecordAlive = function(record) return record.Alive end,
    StateCurrent = function(petId, state) return states[petId] == state end,
    TargetContainsPet = function() return false end,
    OnRetry = function(_, state) state.Phase = "retry" end,
    OnFailed = function(petId, state)
        assert(states[petId] == state)
        states[petId] = nil
        failedCount = failedCount + 1
    end,
})
assert(restarted == true)
assert(engine("dispatch", {
    CoinId = "rejected-coin",
    Record = { Alive = true },
    Entries = { { PetId = "bounded-failure", State = failedState } },
}) == true)

local rejectedStats = engine("stats")
assert(rejectedStats.Rejected - beforeRejects == 3,
    "a rejected UID must stop after exactly three Join Coin attempts")
assert(rejectedStats.Retries - beforeRetries == 2,
    "three attempts require exactly two retries")
assert(failedCount == 1 and states["bounded-failure"] == nil)

local freshTargetFailures = 0
local noRetryState = { Phase = "pending" }
states["fresh-target"] = noRetryState
assert(engine("start", {
    Running = function() return true end,
    Enabled = function() return true end,
    Resetting = function() return false end,
    NetworkReady = function() return network end,
    RecordAlive = function(record) return record.Alive end,
    StateCurrent = function(petId, state) return states[petId] == state end,
    TargetContainsPet = function() return false end,
    ShouldRetry = function(_, reason)
        assert(string.find(reason, "rejected", 1, true))
        return false
    end,
    OnFailed = function(petId, state)
        assert(petId == "fresh-target" and state == noRetryState)
        states[petId] = nil
        freshTargetFailures = freshTargetFailures + 1
    end,
    MinLanes = 4,
    InitialLanes = 16,
    MaxLanes = 16,
}) == true)
local beforeFreshStats = engine("stats")
assert(engine("dispatch", {
    CoinId = "contended-coin",
    Record = { Alive = true },
    Entries = { { PetId = "fresh-target", State = noRetryState } },
}) == true)
local afterFreshStats = engine("stats")
assert(afterFreshStats.Rejected - beforeFreshStats.Rejected == 1)
assert(afterFreshStats.Retries == beforeFreshStats.Retries,
    "a contended different-target coin must immediately select a fresh target")
assert(freshTargetFailures == 1 and states["fresh-target"] == nil)
assert(afterFreshStats.Limit == 16,
    "application-level Join rejection must not collapse transport lanes")

network.Invoke = function() error("transient transport failure") end
local transportState = { Phase = "pending" }
states["transport-failure"] = transportState
assert(engine("start", {
    Running = function() return true end,
    Enabled = function() return true end,
    Resetting = function() return false end,
    NetworkReady = function() return network end,
    RecordAlive = function(record) return record.Alive end,
    StateCurrent = function(petId, state) return states[petId] == state end,
    ShouldRetry = function() return false end,
    OnFailed = function(petId, state)
        assert(petId == "transport-failure" and state == transportState)
        states[petId] = nil
    end,
    MinLanes = 4,
    InitialLanes = 16,
    MaxLanes = 16,
}) == true)
assert(engine("dispatch", {
    CoinId = "transport-coin",
    Record = { Alive = true },
    Entries = { { PetId = "transport-failure", State = transportState } },
}) == true)
local transportStats = engine("stats")
assert(transportStats.Limit == 15,
    "one transient transport failure must trim one lane instead of halving all lanes")
assert(transportStats.FailureStreak == 1)

assert(engine("set-limit", 8) == true)
local limitedStats = engine("stats")
assert(limitedStats.PolicyMaxLanes == 8 and limitedStats.Limit == 8)
assert(engine("set-limit", 16) == true)
local recoveringStats = engine("stats")
assert(recoveringStats.PolicyMaxLanes == 16 and recoveringStats.Limit == 9,
    "lifting backpressure should recover gradually instead of bursting")

print("PASS pet farm engine fills 15 UID locks and resists transient/rejection lane collapse")
