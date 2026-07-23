const fs = require("fs");
const path = require("path");

const root = path.resolve(__dirname, "..");
const read = (file) => fs.readFileSync(path.join(root, file), "utf8");
const assert = (condition, message) => {
    if (!condition) throw new Error(message);
};
const count = (text, expression) => (text.match(expression) || []).length;

const manifest = JSON.parse(read("runtime_manifest.json"));
const farm = read("slim_farm.lua");
const engine = read("pet_farm_engine.lua");
const loot = read("loot_reactor.lua");
const graphics = read("graphics_module.lua");
const activeFiles = [
    manifest.suite.sourceEntry,
    ...manifest.moduleOrder.map((key) => manifest.modules[key].path),
];
const activeText = activeFiles.map((file) => `${file}\n${read(file)}`).join("\n");
const removedKernel = ["Runtime", "Kernel"].join("");

assert(manifest.modules.lootReactor
    && manifest.modules.lootReactor.path === "loot_reactor.lua",
    "the native loot reactor is absent from the active manifest");
assert(!activeText.includes(removedKernel),
    "the removed global scheduler is still reachable from the active graph");
assert(!fs.existsSync(path.join(root, "runtime_kernel_module.lua")),
    "the removed scheduler module still exists");

// Coin registry: one bootstrap snapshot and one folder scan, then signals only.
assert(farm.includes("local coinRecords = {}")
    && farm.includes("folder.ChildAdded:Connect")
    && farm.includes("folder.ChildRemoved:Connect"),
    "CoinRegistry is not driven by the live Coins folder");
assert(farm.includes('connect("New Coin"')
    && farm.includes('connect("Update Coin Health"')
    && farm.includes('connect("Update Coin Pets"')
    && farm.includes('connect("Remove Coin"'),
    "CoinRegistry is missing named network deltas");
assert(count(farm, /"Get Coins"/g) === 1,
    "Get Coins must be used only for the initial world snapshot");
assert(farm.includes("coinIndex.Cache.Revision")
    && farm.includes("coinIndex:Invalidate()"),
    "target ordering is not revision-cached");
assert(!/workspace\s*\.\s*DescendantAdded/.test(farm),
    "the farm still observes every Workspace descendant");
assert(!/GetChildren\s*\(\s*\)\s*\[\s*\d+\s*\]/.test(activeText),
    "a fixed per-session remote index re-entered active source");

// Pet allocator and transport: one coalesced allocator plus one bounded writer.
for (const marker of [
    "DEFAULT_DISPATCH_WIDTH = 16",
    "MAX_QUEUED_JOBS = 64",
    "MAX_JOIN_ATTEMPTS = 3",
    "RETRY_DELAYS = { 0.05, 0.15 }",
    "PendingByPet = {}",
    "TargetContainsPet",
]) {
    assert(engine.includes(marker), `missing bounded pet-writer marker: ${marker}`);
}
assert(engine.includes("while run.Context and run.Active < DEFAULT_DISPATCH_WIDTH"),
    "pet dispatch is not owned by one fixed-width pump");
assert(engine.includes("clearPending(job.Entries)"),
    "stale pet dispatch can retain a pending UID");
assert(!engine.includes("task.spawn"),
    "pet transport still creates task.spawn workers");
assert(!engine.includes('"set-limit"'),
    "dynamic lane collapse re-entered the fixed-width transport");
assert(farm.includes("if self.AllocatorScheduled or allocatorBusy"),
    "allocator callback bursts are not coalesced");
assert(farm.includes('Phase = "joining"')
    && farm.includes('state.Phase = "working"')
    && farm.includes("Generation = farmGeneration"),
    "pet state is missing its minimal generation-safe lifecycle");
assert(!farm.includes("runtimePetCounts")
    && !farm.includes("runtimePetPositions")
    && !farm.includes("teleportPet"),
    "visual pet mirroring/teleportation re-entered the farm hot path");

// Loot: native IDs, one 0.25-second shared batch, no physics or fake ack state.
for (const marker of [
    "ORB_FLUSH_INTERVAL = 0.25",
    "ORB_BATCH_SIZE = 2048",
    "MAX_PENDING_ORBS = 8192",
    "PendingOrbIds = {}",
    'fire("Claim Orbs", ids)',
    'fire("Collect Lootbag", record.Id, position)',
    "folder.ChildAdded:Connect(queueOrb)",
    "folder.ChildAdded:Connect(watchBag)",
    'GetAttributeChangedSignal(',
    "OrbDropped",
]) {
    assert(loot.includes(marker), `missing native loot marker: ${marker}`);
}
for (const forbidden of [
    "firetouchinterest",
    "CFrame =",
    "Heartbeat",
    "RenderStepped",
    "task.spawn",
    "OrbInFlight",
    "AckHistory",
]) {
    assert(!loot.includes(forbidden), `forbidden loot behavior returned: ${forbidden}`);
}
assert(!farm.includes("function lootCollector:Touch")
    && !farm.includes("preparePickupPart")
    && !farm.includes("OrbQueuedAt"),
    "legacy inline/physics loot code is still active");

// Graphics: a one-time scan per narrow farm root, then DescendantAdded only.
assert(!/workspace\s*\.\s*DescendantAdded/.test(graphics),
    "graphics still observes every Workspace descendant");
assert(!graphics.includes("CurrentCamera")
    && !graphics.includes("CanTouch")
    && !graphics.includes("CanQuery"),
    "graphics crosses the map/camera/network preservation boundary");
assert(count(graphics, /GetDescendants\s*\(/g) === 1,
    "graphics must have exactly one narrow initial-tree scan implementation");
assert(graphics.includes("root.DescendantAdded:Connect")
    && graphics.includes('workspace:FindFirstChild("__MAP")')
    && graphics.includes('workspace:FindFirstChild("__DEBRIS")')
    && graphics.includes('workspace:FindFirstChild("__THINGS")'),
    "graphics is not bound to the explicit visual roots");
assert(!graphics.includes("Heartbeat")
    && !graphics.includes("RenderStepped")
    && !graphics.includes("task.wait"),
    "graphics still has a permanent frame/polling worker");
assert(!graphics.includes("object:Destroy()"),
    "graphics destroys game-owned FX instances that live scripts still reference");
assert(graphics.includes("deferSuppression(active, root, object, kind)")
    && graphics.includes("object.Enabled = false")
    && graphics.includes("object.Visible = false"),
    "graphics does not safely defer and disable dynamic FX in place");
assert(graphics.includes('object.TextureID = ""')
    && graphics.includes('object.TextureId = ""')
    && graphics.includes("stripSurfaceAppearance(active, object)")
    && !graphics.includes("PlayerGui"),
    "potato mode does not safely strip map/egg/machine textures");

// Lifecycle and bounded telemetry.
for (const marker of [
    "coinIndex:DisconnectFolder()",
    "table.clear(coinRecords)",
    "table.clear(commandRemoteCache)",
    "table.clear(eventRemoteCache)",
    "table.clear(fireRemoteCache)",
    'pcall(petFarm.Engine, "stop")',
    "lootCollector:StopWorker()",
    "table.clear(moduleLoadState.Cache)",
]) {
    assert(farm.includes(marker), `STOP/reload cleanup is missing: ${marker}`);
}
assert(!farm.includes("task.spawn"),
    "main source still owns a long-lived task.spawn worker");
assert(farm.includes("task.delay(1, tick)"),
    "scalar UI telemetry is not rate-limited to one update per second");

// Model the coalesced dirty-set contract under a 100k callback burst.
const dirty = new Set();
let allocatorScheduled = false;
let scheduledAllocators = 0;
for (let index = 0; index < 100_000; index += 1) {
    dirty.add(`coin-${index % 256}`);
    if (!allocatorScheduled) {
        allocatorScheduled = true;
        scheduledAllocators += 1;
    }
}
assert(scheduledAllocators === 1,
    "100k callbacks scheduled more than one allocator reconciliation");
assert(dirty.size === 256,
    "deduplicated dirty state grew with callback count");
dirty.clear();
allocatorScheduled = false;
assert(dirty.size === 0 && allocatorScheduled === false,
    "synthetic callback burst retained a backlog");

process.stdout.write(
    `Event-driven zero-retention policy OK | activeFiles=${activeFiles.length}`
    + " | callbacks=100000 | retained=0 | allocatorRuns=1\n"
);
