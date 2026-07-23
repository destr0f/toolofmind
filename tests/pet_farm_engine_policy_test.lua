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

assert(math.abs(engine("retry-delay", 1) - 0.05) < 0.0001)
assert(math.abs(engine("retry-delay", 2) - 0.15) < 0.0001)
assert(math.abs(engine("retry-delay", 9) - 0.15) < 0.0001)

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

local function context(overrides)
    local value = {
        Running = function() return true end,
        Enabled = function() return true end,
        Resetting = function() return false end,
        NetworkReady = function() return network end,
        RecordAlive = function(record) return record.Alive end,
        StateCurrent = function(petId, state) return states[petId] == state end,
        TargetContainsPet = function() return false end,
        OnAccepted = function(petId, state)
            assert(states[petId] == state, "accepted callback received a stale lock")
            state.Phase = "working"
            return true
        end,
        OnFailed = function() error("acceptance test must not fail") end,
    }
    for key, item in pairs(overrides or {}) do value[key] = item end
    return value
end

assert(engine("start", context()) == true)
for index = 1, 15 do
    local petId = "bulk-" .. tostring(index)
    local state = { Phase = "joining" }
    states[petId] = state
    local queued, problem = engine("dispatch", {
        CoinId = "coin-" .. tostring(index),
        Record = { Alive = true },
        Entries = { { PetId = petId, State = state } },
    })
    assert(queued == true, tostring(problem))
end

local dispatchStats = engine("stats")
assert(dispatchStats.Accepted == 15, "all 15 explicit UIDs should be accepted")
assert(dispatchStats.Rejected == 0 and dispatchStats.Errors == 0)
assert(dispatchStats.Queued == 0 and dispatchStats.Active == 0)
assert(dispatchStats.Limit == 16 and dispatchStats.QueueCapacity == 64)
assert(fireCalls == 30, "each accepted lock needs target + farm signals")
for _, state in pairs(states) do assert(state.Phase == "working") end

-- A live target-pet set is authoritative and prevents a duplicate Join Coin.
local joinCalls = 0
network.Invoke = function()
    joinCalls = joinCalls + 1
    return false
end
local preflightState = { Phase = "joining" }
states.preflight = preflightState
assert(engine("start", context({
    TargetContainsPet = function(_, petId) return petId == "preflight" end,
})) == true)
assert(engine("dispatch", {
    CoinId = "already-attached",
    Record = { Alive = true },
    Entries = { { PetId = "preflight", State = preflightState } },
}) == true)
assert(joinCalls == 0, "live target preflight must suppress duplicate Join Coin")
assert(preflightState.Phase == "working")

-- Callers may stop a rejected target immediately; retry timing/caps are also
-- asserted above and by the static zero-retention policy test.
local failedCount = 0
network.Invoke = function() return false end
local failedState = { Phase = "joining" }
states.failure = failedState
assert(engine("start", context({
    ShouldRetry = function() return false end,
    OnFailed = function(petId, state)
        assert(petId == "failure" and states[petId] == state)
        states[petId] = nil
        failedCount = failedCount + 1
    end,
})) == true)
assert(engine("dispatch", {
    CoinId = "rejected-coin",
    Record = { Alive = true },
    Entries = { { PetId = "failure", State = failedState } },
}) == true)
local rejected = engine("stats")
assert(rejected.Rejected == 1,
    "caller-stopped rejection must make one attempt; got " .. tostring(rejected.Rejected))
assert(rejected.Retries == 0, "caller-stopped rejection must not enter retry state")
assert(rejected.Queued == 0 and failedCount == 1 and states.failure == nil)

-- Transport errors do not collapse the fixed writer width.
network.Invoke = function() error("transient transport failure") end
local transportState = { Phase = "joining" }
states.transport = transportState
assert(engine("start", context({
    ShouldRetry = function() return false end,
    OnFailed = function(petId)
        states[petId] = nil
    end,
})) == true)
assert(engine("dispatch", {
    CoinId = "transport-coin",
    Record = { Alive = true },
    Entries = { { PetId = "transport", State = transportState } },
}) == true)
local transport = engine("stats")
assert(transport.Errors == 1 and transport.Retries == 0)
assert(transport.Limit == 16 and transport.PolicyMaxLanes == 16,
    "transport failure must not collapse the fixed 16-lane writer")

print("PASS fixed 16-lane pet writer, live preflight and bounded retries")
