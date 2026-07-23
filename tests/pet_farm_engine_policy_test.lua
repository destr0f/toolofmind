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
    InitialLanes = 12,
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

print("PASS pet farm engine recognizes replies and fills 15 UID locks")
