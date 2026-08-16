const assert = require("assert");
const fs = require("fs");
const path = require("path");

const root = path.resolve(__dirname, "..");
const source = fs.readFileSync(path.join(root, "slim_farm.lua"), "utf8");
const body = (startMarker, endMarker) => {
    const start = source.indexOf(startMarker);
    const end = source.indexOf(endMarker, start + startMarker.length);
    assert(start >= 0 && end > start, `missing block ${startMarker}`);
    return source.slice(start, end);
};

const dispatch = body(
    "function petFarm:DispatchBossRecord",
    "function petFarm:HandleBossSpawn"
);
assert(!dispatch.includes("allocatorBusy then return false"),
    "allocator bootstrap still rejects its own boss dispatch callback");
assert(dispatch.includes("if not self.Engine then return false end"));

const spawn = body(
    "function petFarm:HandleBossSpawn",
    "function coinSync:PruneBossFallbackTimes"
);
assert(spawn.includes("boss spawn pending; local dispatch re-arm queued"));
assert(spawn.includes("requestAllocatorPulse(true)"));
assert(spawn.includes("armFarmRecovery(1.05)"));
assert(!spawn.includes('coinSync.SignalConnections["New Coin"]'),
    "a locally live boss is still rejected merely because an authoritative listener exists");

const allocator = body("allocatorPass = function()", "requestAllocatorPulse = function");
assert(allocator.includes("refreshWorkspaceCoins()"));
assert(!allocator.includes("BossBootstrapDone"),
    "one-shot bootstrap state can still strand all pets after a missed lifecycle edge");

const fastDispatch = body("function petFarm:QueueFastDispatch", "function petFarm:PhaseCounts");
assert(!fastDispatch.includes("table.clear(self.FastPets)"),
    "boss mode still discards the C54.1 free-pet fast path");

const watchers = body(
    "local farmWatch =",
    "local lootCollector ="
);
assert(watchers.includes("LivenessToken = 0"));
assert(watchers.includes("local function checkBossLiveness()"));
assert(watchers.includes('config.Mode == "Boss Chest Only"'));
assert(watchers.includes("local idleBossLane = expected > 0 and assigned == 0"));
assert(watchers.includes("active == 0 and queued == 0 and invokes == 0"));
assert(watchers.includes("assignmentAge >= 3.5"));
assert(watchers.includes('bossState == "ACTIVE"'));
assert(watchers.includes('local indexedTargets = orderedTargets("Boss Chest Only")'));
assert(watchers.includes("and not coinSync.BossRejected[candidateId]"));
assert(watchers.includes("idleBossLane and indexedBoss == nil and not recordAlive(bossRecord)"));
assert(watchers.includes('petFarm:HandleBossRemoved(bossId, "local boss target vanished")'));
assert(watchers.includes('driverStatus = "boss lifecycle repaired; awaiting authoritative New Coin"'));
assert(watchers.includes('"idle indexed boss generation re-arm"'));
assert(watchers.includes('driverStatus = "indexed boss generation re-armed; pets dispatched"'));
assert(watchers.includes("requestAllocatorPulse(true)"));
assert(!watchers.includes("BossLivenessRescueUsed"),
    "one-shot record latch can still leave a live C54.1 target permanently idle");
assert(!watchers.includes("BossLivenessPoll"),
    "indexed boss recovery must remain transition-only, not a polling worker");
for (const forbidden of ["refreshCoinSnapshot", "refreshWorkspaceCoins", "getgc", "getconnections"]) {
    assert(!watchers.includes(forbidden), `liveness watcher gained forbidden work: ${forbidden}`);
}
assert(!watchers.includes('getCommandRemote("Get Coins")')
    && !watchers.includes('InvokeServer("Get Coins")'),
    "liveness watcher gained a Get Coins request");

assert((source.match(/farmWatch\.LivenessToken = farmWatch\.LivenessToken \+ 1/g) || []).length >= 2,
    "reload/disable cleanup does not invalidate the liveness callback");

console.log("boss_dispatch_liveness_test: ok");
