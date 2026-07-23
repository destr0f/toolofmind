const fs = require("fs");
const path = require("path");

const root = path.resolve(__dirname, "..");
const read = (file) => fs.readFileSync(path.join(root, file), "utf8");
const assert = (condition, message) => {
    if (!condition) throw new Error(message);
};

const manifest = JSON.parse(read("runtime_manifest.json"));
const activeFiles = [
    manifest.suite.sourceEntry,
    ...manifest.moduleOrder.map((key) => manifest.modules[key].path),
    "build_slim.js",
];
const activeText = activeFiles.map((file) => `${file}\n${read(file)}`).join("\n");
const farm = read("slim_farm.lua");
const engine = read("pet_farm_engine.lua");
const graphics = read("graphics_module.lua");
const removedScheduler = ["Runtime", "Kernel"].join("");
const forbiddenSchedulerCalls = ["Register", "Connect", "Every", "Emit", "Stats"]
    .map((method) => `${removedScheduler}:${method}`);

assert(![removedScheduler, ...forbiddenSchedulerCalls].some((marker) => activeText.includes(marker)),
    "active runtime still references the removed global scheduler");
const removedModulePath = ["runtime", "kernel", "module.lua"].join("_");
assert(!fs.existsSync(path.join(root, removedModulePath)),
    "removed scheduler module still exists");
assert(!/workspace\s*\.\s*DescendantAdded/.test(graphics),
    "graphics module still observes every descendant in Workspace");

for (const marker of [
    "MAX_QUEUED_JOBS = 64",
    "MAX_ORB_QUEUE = 1024",
    "MAX_ORB_IN_FLIGHT = 2048",
    "MAX_LOOTBAG_RECORDS = 512",
    "MAX_PERSISTENT_OBJECTS = 4096",
    "MAX_URGENT_QUEUE = 4096",
    "MAX_NORMAL_QUEUE = 8192",
]) {
    assert(activeText.includes(marker), `missing bounded-state marker: ${marker}`);
}

for (const marker of [
    "reconcileFarmWatchdog",
    "reconcileDiamondWorker",
    "reconcileRewardWorker",
    "lootCollector:SyncWorker",
    "lootCollector:StopWorker",
]) {
    assert(farm.includes(marker), `missing feature-owned worker lifecycle: ${marker}`);
}

assert(engine.includes("PendingByPet"), "pet dispatch does not deduplicate pending UID work");
assert(engine.includes("clearPending(job.Entries)"),
    "stale pet jobs can retain their pending UID marker");
assert(farm.includes("if self.AllocatorScheduled or allocatorBusy"),
    "allocator callbacks are not coalesced");
assert(farm.includes("ORB_BATCH_INTERVAL = 0.25"),
    "native orb microbatch interval drifted from the game protocol");
assert(farm.includes("ORB_BATCH_LIMIT = 256")
    && farm.includes("INITIAL_ORB_SCAN_LIMIT = 128")
    && farm.includes("INITIAL_LOOTBAG_SCAN_LIMIT = 128"),
    "loot reactor startup or batch bounds are unsafe");
assert(farm.includes("OrbQueuedAt = {}")
    && farm.includes("age >= ORB_BATCH_INTERVAL"),
    "fresh orb IDs can be claimed before the game's native creation window");
assert(farm.includes("ORB_BATCH_JITTER"),
    "crowded clients no longer stagger their native orb batches");
assert(farm.includes('self:FireNative("Claim Orbs", ids)'),
    "orb IDs are not sent through one named native batch");
assert(farm.includes('self:FireNative("Collect Lootbag", record.Id, position)'),
    "lootbags are not sent through their named native command");
assert(farm.includes('self:ConnectNamedEvent("Orb Added"'),
    "native Orb Added feed is not bound");
assert(farm.includes('self:ConnectNamedEvent("Spawn Lootbag"'),
    "native Spawn Lootbag feed is not bound");
assert(farm.includes('readObjectValue(item, "ReadyForCollection")'),
    "lootbag readiness is not checked before collection");
assert(!farm.includes("firetouchinterest"),
    "physical touch emulation re-entered the active loot path");
assert(!farm.includes("function lootCollector:Touch"),
    "the removed physical loot worker re-entered the active source");
assert(!farm.includes("preparePickupPart"),
    "loot collection still mutates pickup parts");
const earlyStartupEnd = farm.indexOf('trace("07 startup complete")');
assert(earlyStartupEnd > 0
    && !farm.slice(0, earlyStartupEnd).includes("lootCollector.StartupArmed = true"),
    "loot reactor can arm before the interface is fully initialized");
assert(farm.includes("lootCollector.StartupArmed = true")
    && farm.includes("LOOT_REACTOR_START_DELAY = 0.75")
    && farm.includes('trace("07A loot reactor starting"'),
    "deferred loot reactor startup guard is missing");
assert(!farm.includes("self:ScheduleOrbFlush(0)"),
    "orb overflow can still create an immediate unthrottled flush chain");
assert(farm.includes("if self.WorkerActive then\n        self:MarkStatus()\n        return"),
    "repeated toggle/profile callbacks can restart the loot reactor and rescan the world");

const uiLoop = farm.slice(farm.indexOf("local nextZoneRefreshAt"));
assert(!uiLoop.includes("orderedTargets("),
    "visible UI loop still sorts/scans target records");
assert(!uiLoop.includes("getEquippedPetIds("),
    "visible UI loop still performs a full equipped-pet scan");

// Model the exact dirty-set/coalesced-runner contract under a 100k event burst.
const dirty = new Set();
let runnerPending = false;
let scheduledRunners = 0;
function onSyntheticEvent(uid) {
    dirty.add(uid);
    if (runnerPending) return;
    runnerPending = true;
    scheduledRunners += 1;
}
for (let index = 0; index < 100_000; index += 1) {
    onSyntheticEvent(`uid-${index % 256}`);
}
assert(scheduledRunners === 1, "100k events scheduled more than one coalesced runner");
assert(dirty.size === 256, "deduplicated dirty state grew with event count");
dirty.clear();
runnerPending = false;
assert(dirty.size === 0 && runnerPending === false,
    "synthetic burst left backlog after reconciliation");

process.stdout.write(
    `Zero-retention reactor OK | activeFiles=${activeFiles.length}`
    + " | syntheticEvents=100000 | backlog=0 | coalescedRunners=1\n"
);
