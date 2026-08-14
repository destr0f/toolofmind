local engine = require("../pet_farm_lite_engine")

local states = {}
local joins = 0
local spawns = {}
local removed = {}
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
engine("stop")
print("PASS boss event lifecycle, duplicate suppression, and stale-generation guard")
