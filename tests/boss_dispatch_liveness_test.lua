local scheduled = {}

task = {
    delay = function(delaySeconds, callback)
        scheduled[#scheduled + 1] = {
            Delay = delaySeconds,
            Callback = callback,
        }
    end,
    wait = function() end,
}

local engine = require("../pet_farm_lite_engine")

local states = {}
local failed = 0
local joins = 0
local fires = {}
local mutateRecordDuringJoin = false
local network = {
    Invoke = function(_, _, requested)
        joins = joins + 1
        if mutateRecordDuringJoin then mutateRecordDuringJoin.Alive = false end
        local accepted = {}
        for _, uid in ipairs(requested) do accepted[uid] = true end
        return accepted
    end,
    Fire = function(command)
        fires[command] = (fires[command] or 0) + 1
    end,
}

local function startEngine()
    return engine("start", {
        Running = function() return true end,
        Enabled = function() return true end,
        Resetting = function() return false end,
        NetworkReady = function() return network end,
        CommandRouteCandidates = function(command) return { command } end,
        RecordAlive = function(record) return record.Alive end,
        StateCurrent = function(uid, state) return states[uid] == state end,
        OnAccepted = function(_, state)
            state.Phase = "working"
            return true
        end,
        OnFailed = function(uid, state)
            if states[uid] == state then states[uid] = nil end
            failed = failed + 1
        end,
        OnBossSpawnReady = function() return true end,
        OnBossRemoved = function() end,
        DispatchWidth = 16,
        DispatchPhaseOffset = 0,
        BossDispatchPhaseOffset = 0,
        BossJoinAuthoritative = true,
    })
end

assert(startEngine() == true)
local spawned, _, generation = engine("boss-spawn", {
    CoinId = "boss",
    Direct = true,
    ForceNew = true,
    ReceivedAt = os.clock(),
    PayloadComplete = true,
})
assert(spawned == true)

local bossRecord = { Alive = true }
local bossState = { Phase = "joining" }
states.bossPet = bossState
assert(engine("dispatch", {
    CoinId = "boss",
    BossGeneration = generation,
    Record = bossRecord,
    Entries = { { PetId = "bossPet", State = bossState } },
}) == true)
assert(joins == 1, "boss dispatch must begin before a deferred scheduler turn")
assert(bossState.Phase == "working")
assert((fires["Change Pet Target"] or 0) == 0,
    "authoritative boss Join must suppress duplicate target replication")
assert((fires["Farm Coin"] or 0) == 1,
    "authoritative boss Join must retain the required farm signal")
local bossDispatchStats = engine("stats")
assert(bossDispatchStats.TargetSignalsSkipped == 1
    and bossDispatchStats.TargetSignals == 0
    and bossDispatchStats.FarmSignals == 1,
    "boss signal-diet counters must match the actual wire calls")

engine("stop")
table.clear(states)
table.clear(scheduled)
failed, joins = 0, 0
table.clear(fires)
assert(startEngine() == true)
local spawned2, _, generation2 = engine("boss-spawn", {
    CoinId = "boss-race",
    Direct = true,
    ForceNew = true,
    ReceivedAt = os.clock(),
    PayloadComplete = true,
})
assert(spawned2 == true)

local raceRecord = { Alive = true }
local raceState = { Phase = "joining" }
states.racePet = raceState
mutateRecordDuringJoin = raceRecord
assert(engine("dispatch", {
    CoinId = "boss-race",
    BossGeneration = generation2,
    Record = raceRecord,
    Entries = { { PetId = "racePet", State = raceState } },
}) == true)
mutateRecordDuringJoin = false
assert(joins == 1)
assert(failed == 1 and states.racePet == nil,
    "a target that dies during Join Coin must release its caller reservation")

engine("stop")
print("PASS immediate test path and stale joining-state release")
