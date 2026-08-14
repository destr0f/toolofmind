local engine = require("../pet_farm_lite_engine")

local states = {}
local joins = 0
local spawns = {}
local removed = {}
local acceptedBatches = 0
local network = {
    Invoke = function(_, coinId, requested)
        joins = joins + 1
        local accepted = {}
        for _, uid in ipairs(requested) do accepted[uid] = true end
        return accepted
    end,
    Fire = function() end,
}

assert(engine("start", {
    Running = function() return true end,
    Enabled = function() return true end,
    Resetting = function() return false end,
    NetworkReady = function() return network end,
    CommandRouteCandidates = function(command) return { command } end,
    RecordAlive = function(record) return record.Alive end,
    StateCurrent = function(uid, state) return states[uid] == state end,
    OnAccepted = function() return true end,
    OnBatchAccepted = function(_, petIds, generation)
        acceptedBatches = acceptedBatches + 1
        assert(#petIds == 1 and petIds[1] == "pet")
        assert(generation ~= nil)
    end,
    OnFailed = function() end,
    OnBossSpawnReady = function(info, generation)
        spawns[#spawns + 1] = { id = info.CoinId, generation = generation }
        return true
    end,
    OnBossRemoved = function(id, generation)
        removed[#removed + 1] = { id = id, generation = generation }
    end,
    DispatchWidth = 16,
}) == true)

local ok, _, generation1 = engine("boss-spawn", {
    CoinId = "boss-reused-id", Direct = true, ReceivedAt = os.clock(), PayloadComplete = true,
})
assert(ok == true and generation1 ~= nil and #spawns == 1)
local duplicate, reason, duplicateGeneration = engine("boss-spawn", {
    CoinId = "boss-reused-id", Direct = true, ReceivedAt = os.clock(), PayloadComplete = true,
})
assert(duplicate == false and reason == "duplicate" and duplicateGeneration == generation1)

local state1 = { Phase = "joining" }
states.pet = state1
assert(engine("dispatch", {
    CoinId = "boss-reused-id",
    BossGeneration = generation1,
    Record = { Alive = true },
    Entries = { { PetId = "pet", State = state1 } },
}) == true)
assert(joins == 1)
assert(acceptedBatches == 1,
    "one accepted boss Join must produce exactly one post-Join batch callback")
assert(engine("boss-remove", "boss-reused-id", "test remove") == true)
assert(#removed == 1)

local ok2, _, generation2 = engine("boss-spawn", {
    CoinId = "boss-reused-id", Direct = true, ReceivedAt = os.clock(), PayloadComplete = true,
})
assert(ok2 == true and generation2 > generation1 and #spawns == 2,
    "a reused coin ID must receive a fresh spawn generation")

local stale = { Phase = "joining" }
states.stale = stale
local staleQueued = engine("dispatch", {
    CoinId = "boss-reused-id",
    BossGeneration = generation1,
    Record = { Alive = true },
    Entries = { { PetId = "stale", State = stale } },
})
assert(staleQueued == false, "a stale generation must not dispatch")
assert(joins == 1)

local stats = engine("boss-stats")
assert(stats.SpawnsSeen == 2 and stats.DuplicateSpawns == 1)
assert(stats.RingCount == 1 and stats.JoinsSent == 1 and stats.JoinsAccepted == 1)

-- A grouped server reject releases all reservations before the boss lifecycle
-- becomes ABSENT, and never retries the rejected generation.
local rejectedStates = {}
local rejectedFailures = 0
local removedAfterFailures = false
network.Invoke = function()
    joins = joins + 1
    return false
end
assert(engine("start", {
    Running = function() return true end,
    Enabled = function() return true end,
    Resetting = function() return false end,
    NetworkReady = function() return network end,
    CommandRouteCandidates = function(command) return { command } end,
    RecordAlive = function(record) return record.Alive end,
    StateCurrent = function(uid, state) return rejectedStates[uid] == state end,
    OnAccepted = function() return true end,
    OnFailed = function(uid, state)
        assert(rejectedStates[uid] == state)
        rejectedStates[uid] = nil
        rejectedFailures = rejectedFailures + 1
    end,
    OnBossSpawnReady = function() return true end,
    OnBossRemoved = function(_, _, source)
        assert(source == "server reject")
        assert(rejectedFailures == 16,
            "boss removal ran before every rejected UID was released")
        removedAfterFailures = true
    end,
    DispatchWidth = 16,
}) == true)
local rejectSpawn, _, rejectGeneration = engine("boss-spawn", {
    CoinId = "boss-rejected", Direct = true, ReceivedAt = os.clock(), PayloadComplete = true,
})
assert(rejectSpawn == true)
local rejectedEntries = {}
for index = 1, 16 do
    local uid = "reject-" .. tostring(index)
    local state = { Phase = "joining" }
    rejectedStates[uid] = state
    rejectedEntries[index] = { PetId = uid, State = state }
end
assert(engine("dispatch", {
    CoinId = "boss-rejected",
    BossGeneration = rejectGeneration,
    Record = { Alive = true },
    Entries = rejectedEntries,
}) == true)
local rejectStats = engine("stats")
assert(rejectedFailures == 16 and removedAfterFailures == true)
assert(rejectStats.Rejected == 16 and rejectStats.Retries == 0)
engine("stop")
print("PASS boss event lifecycle, duplicate suppression, and stale-generation guard")
