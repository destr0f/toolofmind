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
assert(watchers.includes("assigned == 0 and targetReady"));
assert(watchers.includes("active == 0 and queued == 0 and invokes == 0"));
assert(watchers.includes("assignmentAge >= 3.5"));
assert(watchers.includes('driverStatus = "boss target stalled; C54.1 allocator re-arm queued"'));
assert(watchers.includes("requestAllocatorPulse(true)"));
assert(!watchers.includes("BossLivenessRescueUsed"),
    "one-shot record latch can still leave a live C54.1 target permanently idle");
assert(!watchers.includes('"active boss liveness rescue"'),
    "liveness recovery still creates a synthetic boss generation");
for (const forbidden of ["refreshCoinSnapshot", "refreshWorkspaceCoins", "getgc", "getconnections"]) {
    assert(!watchers.includes(forbidden), `liveness watcher gained forbidden work: ${forbidden}`);
}
assert(!watchers.includes('getCommandRemote("Get Coins")')
    && !watchers.includes('InvokeServer("Get Coins")'),
    "liveness watcher gained a Get Coins request");

assert((source.match(/farmWatch\.LivenessToken = farmWatch\.LivenessToken \+ 1/g) || []).length >= 2,
    "reload/disable cleanup does not invalidate the liveness callback");

console.log("boss_dispatch_liveness_test: ok");
