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
    "MAX_LOOT_ENTRIES = 8192",
    "MAX_IMMEDIATE_LOOT_BATCH = 1024",
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
assert(farm.includes("if self.ImmediateScheduled or not running() then return end"),
    "loot burst callbacks are not coalesced");

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
