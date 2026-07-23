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
const egg = read("auto_egg_module.lua");
const gold = read("gold_machine_module.lua");
const rainbow = read("rainbow_machine_module.lua");
const darkMatter = read("dark_matter_module.lua");
const boost = read("boost_module.lua");
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

// Preserve the already validated event-driven coin registry and pet transport.
assert(farm.includes("local coinRecords = {}")
    && farm.includes("folder.ChildAdded:Connect")
    && farm.includes("folder.ChildRemoved:Connect"),
    "CoinRegistry is not driven by the live Coins folder");
for (const command of ["New Coin", "Update Coin Health", "Update Coin Pets", "Remove Coin"]) {
    assert(farm.includes(`connect("${command}"`), `missing coin delta ${command}`);
}
assert(count(farm, /"Get Coins"/g) === 1,
    "Get Coins must remain an initial-world snapshot only");
assert(!/workspace\s*\.\s*DescendantAdded/.test(farm),
    "the farm observes every Workspace descendant");
assert(!/GetChildren\s*\(\s*\)\s*\[\s*\d+\s*\]/.test(activeText),
    "a fixed per-session remote index re-entered active source");

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
    "pet transport creates per-job task.spawn workers");
assert(farm.includes("if self.AllocatorScheduled or allocatorBusy"),
    "allocator callback bursts are not coalesced");
assert(farm.includes('Phase = "joining"')
    && farm.includes('state.Phase = "working"')
    && farm.includes("Generation = farmGeneration"),
    "pet state lost its generation-safe lifecycle");
assert(!farm.includes("runtimePetCounts")
    && !farm.includes("runtimePetPositions")
    && !farm.includes("teleportPet"),
    "visual pet mirroring returned to the farm hot path");

// Loot owns Orbs/Lootbags and retains only unsent IDs/unready records.
for (const marker of [
    "ORB_FLUSH_INTERVAL = 0.25",
    "ORB_BATCH_SIZE = 2048",
    "MAX_PENDING_ORBS = 8192",
    "STATUS_INTERVAL = 1",
    "PendingOrbIds = {}",
    'fire("Claim Orbs", ids)',
    'fire("Collect Lootbag", record.Id, position)',
    "folder.ChildAdded:Connect(queueOrb)",
    "folder.ChildAdded:Connect(watchBag)",
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
    "GetDescendants",
    "AckHistory",
    ":Destroy()",
    "Parent = nil",
]) {
    assert(!loot.includes(forbidden), `forbidden loot behavior returned: ${forbidden}`);
}

// Graphics uses one temporary frame-budgeted drain, never one task per object.
for (const marker of [
    "QUEUE_CAPACITY = 32768",
    "SETTLE_CAPACITY = 8192",
    "MAX_PER_FRAME = 192",
    "FRAME_BUDGET_SECONDS = 0.00075",
    "QueueHead = 1",
    "SettleHead = 1",
    'setmetatable({}, { __mode = "k" })',
    "root.DescendantAdded:Connect",
    "object:GetChildren()",
    "active.QueueObjects[index] = nil",
    "active.SettleObjects[index] = nil",
]) {
    assert(graphics.includes(marker), `missing coalesced graphics marker: ${marker}`);
}
assert(count(graphics, /RunService\.Heartbeat:Connect/g) === 1,
    "graphics must own exactly one armed frame-budgeted drain");
assert(graphics.includes("if active.QueueCount <= 0 then")
    && graphics.includes("disconnect(active.DrainConnection)"),
    "graphics drain does not disconnect when the queue becomes empty");
assert(!graphics.includes("GetDescendants")
    && !graphics.includes("task.spawn")
    && !graphics.includes(":Destroy()")
    && !graphics.includes("Parent = nil"),
    "graphics performs an unbounded scan/task/destructive mutation");
const thingRoots = graphics.slice(
    graphics.indexOf("local THING_ROOTS"),
    graphics.indexOf("local EFFECT_CLASSES")
);
assert(thingRoots.includes("Coins") && thingRoots.includes("Pets")
    && thingRoots.includes("Eggs") && thingRoots.includes("Machines")
    && !thingRoots.includes("Orbs") && !thingRoots.includes("Lootbags"),
    "graphics and loot root ownership overlap");
assert(graphics.includes('object.TextureID = ""')
    && graphics.includes('object.TextureId = ""')
    && graphics.includes("stripSurfaceAppearance(active, object)")
    && graphics.includes("object.CastShadow = false")
    && !graphics.includes("object.RenderFidelity")
    && !graphics.includes("PlayerGui"),
    "potato mode lost safe map/egg/machine texture reduction");

// Hidden UI receives cached state at one hertz; catalogs are invalidation-driven.
for (const marker of [
    "statusSetters.Pending = {}",
    "statusSetters.Published = {}",
    "tab.Selected == true",
    "screenGui.Enabled == false",
    "Window.Closed == true",
    "statusSetters.Flush()",
    "task.delay(1, tick)",
    "zoneCatalogDirty",
    "eggCatalogDirty",
]) {
    assert(farm.includes(marker), `missing bounded UI marker: ${marker}`);
}
const windowForwardDeclaration = farm.indexOf("local Window");
const visibilityGuard = farm.indexOf("local function interfaceIsVisible()");
const windowCreation = farm.indexOf("Window = WindUI:CreateWindow({");
assert(windowForwardDeclaration >= 0
    && windowForwardDeclaration < visibilityGuard
    && visibilityGuard < windowCreation
    && !farm.includes("local Window = WindUI:CreateWindow({"),
    "interface visibility guard captures a late global/shadowed Window");
assert(!farm.includes("nextZoneRefreshAt")
    && !farm.includes("nextEggRefreshAt"),
    "catalogs still have periodic refresh clocks");

// Adaptive workers keep fast polling only while a request is pending.
assert(egg.includes("if state.Pending then return 0.05 end")
    && egg.includes("workerDelay(state)")
    && egg.includes("PHYSICAL_RESCAN_COOLDOWN = 2"),
    "auto egg is not deadline-driven/invalidation-bounded");
for (const [name, source] of [
    ["gold", gold],
    ["rainbow", rainbow],
    ["dark matter", darkMatter],
]) {
    assert(source.includes("NextCheck")
        && source.includes("workerDelay(state)")
        && source.includes("IDLE_CHECK_DELAY = 5"),
        `${name} machine still uses a fixed short idle loop`);
}
assert(boost.includes("IDLE_SAFETY_DELAY = 30")
    && boost.includes("state.NextWakeAt")
    && boost.includes("remaining - renewBefore"),
    "boost worker does not schedule the nearest renewal/retry");
assert(farm.includes("MACHINE_PET_SNAPSHOT_TTL = 5")
    && farm.includes("GetPetSnapshot = getMachinePetSnapshot")
    && farm.includes("InvalidatePetSnapshot = invalidateMachinePetSnapshot"),
    "machine workers do not share an invalidation-aware pet snapshot");

for (const marker of [
    "coinIndex:DisconnectFolder()",
    "table.clear(coinRecords)",
    "table.clear(commandRemoteCache)",
    "table.clear(eventRemoteCache)",
    "table.clear(fireRemoteCache)",
    'pcall(petFarm.Engine, "stop")',
    "lootCollector:StopWorker()",
    "table.clear(moduleLoadState.Cache)",
    "table.clear(statusSetters.Pending)",
    "table.clear(statusSetters.Published)",
]) {
    assert(farm.includes(marker), `STOP/reload cleanup is missing: ${marker}`);
}

process.stdout.write(
    `Single-client zero-retention policy OK | activeFiles=${activeFiles.length}`
    + " | petTransport=preserved | graphicsDrain=1 | uiHz=1\n"
);
