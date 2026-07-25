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
const engine = read("pet_farm_lite_engine.lua");
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
for (const command of ["New Coin", "Update Coin Health", "Remove Coin"]) {
    assert(farm.includes(`connect("${command}"`), `missing coin delta ${command}`);
}
assert(!farm.includes('connect("Update Coin Pets"'),
    "Lite farm still subscribes to high-frequency pet-set reconciliation");
assert(count(farm, /"Get Coins"/g) === 1,
    "Get Coins must remain an initial-world snapshot only");
assert(!/workspace\s*\.\s*DescendantAdded/.test(farm),
    "the farm observes every Workspace descendant");
assert(!/GetChildren\s*\(\s*\)\s*\[\s*\d+\s*\]/.test(activeText),
    "a fixed per-session remote index re-entered active source");

for (const marker of [
    "DEFAULT_DISPATCH_WIDTH = 16",
    "MAX_QUEUED_JOBS = 32",
    "MAX_JOIN_ATTEMPTS = 2",
    "RETRY_DELAY = 0.25",
    "PendingByPet = {}",
]) {
    assert(engine.includes(marker), `missing Lite Reactor marker: ${marker}`);
}
assert(engine.includes("while run.Context and run.Active < run.Limit"),
    "pet dispatch is not owned by one fixed-width Lite pump");
assert(engine.includes("clearPending(job.Entries)"),
    "stale pet dispatch can retain a pending UID");
assert(!engine.includes("task.spawn"),
    "pet transport creates per-job task.spawn workers");
assert(farm.includes("if self.AllocatorScheduled or allocatorBusy"),
    "allocator callback bursts are not coalesced");
assert(farm.includes("if not force and expected > 0 and assignmentCount() >= expected then return end"),
    "coin callbacks still wake the allocator while every UID is locked");
assert(farm.includes('local JOIN_COIN_REJECT_PREFIX = "Join Coin rejected"')
    && farm.includes("ShouldRetry = function(_, reason)")
    && farm.includes("#JOIN_COIN_REJECT_PREFIX"),
    "confirmed Join Coin rejection is still delayed behind a same-target retry");
assert(farm.includes("local queueReleasedPetsForHandoff")
    && farm.includes("releaseAssignmentsForCoin(id) or nil")
    && farm.includes("queueReleasedPetsForHandoff(releasedPetIds) == true"),
    "Remove Coin does not pass released UIDs to the deferred handoff queue");
const removeCoinHandler = farm.slice(
    farm.indexOf("local function removeCoin"),
    farm.indexOf("function coinIndex:DisconnectFolder")
);
assert(!removeCoinHandler.includes("fastHandoffReleasedPets(releasedPetIds)"),
    "Remove Coin re-enters pet dispatch synchronously from the network callback");
for (const marker of [
    "MAX_PENDING_HANDOFF_PETS = 64",
    "pendingHandoffPets = {}",
    "handoffToken = 0",
    "task.defer(function()",
    "token ~= handoffToken",
    "fastHandoffReleasedPets(batch) ~= true",
    "clearPendingHandoffs()",
]) {
    assert(farm.includes(marker), `missing bounded deferred handoff marker: ${marker}`);
}
assert(farm.includes("local cache = coinIndex.Cache")
    && farm.includes("cache.Signature ~= farmSelectionSignature")
    && farm.includes("for _, record in ipairs(cache.Targets) do")
    && farm.includes("scheduleTargetCacheRefresh()"),
    "cached handoff no longer consumes the ready target order before refreshing it");
assert(farm.includes("fastRerouteCount = fastRerouteCount + 1")
    && farm.includes("slowRecoveryCount = slowRecoveryCount + 1")
    && farm.includes("Fast reroutes:")
    && farm.includes("Deferred handoffs:")
    && farm.includes("Slow recoveries:"),
    "fast reject reroutes and true slow recoveries are not separately observable");
assert(!farm.includes("RecordExternalPets")
    && !farm.includes("ContendedTargetOrder")
    && !farm.includes("TargetContainsPet"),
    "contention/live-pet reconciliation remains in the Lite hot path");
assert(farm.includes('Phase = "joining"')
    && farm.includes('state.Phase = "working"')
    && farm.includes("Generation = farmGeneration"),
    "pet state lost its generation-safe lifecycle");
assert(!farm.includes("runtimePetCounts")
    && !farm.includes("runtimePetPositions")
    && !farm.includes("teleportPet"),
    "visual pet mirroring returned to the farm hot path");

// Loot owns Orbs/Lootbags and gates the game producers before Instance creation.
for (const marker of [
    "ORB_FLUSH_INTERVAL = 0.25",
    "ORB_BATCH_SIZE = 2048",
    "MAX_PENDING_ORBS = 8192",
    "BAG_FIRST_ATTEMPT_DELAY = 0.08",
    "STATUS_INTERVAL = 1",
    "PendingOrbIds = {}",
    "DisabledBags = {}",
    'networkSignal("Spawn Lootbag")',
    'networkSignal("Remove Lootbag")',
    "type(getsenv)",
    'findGameScript("Orbs")',
    'findGameScript("Coins")',
    "environment.AddOrb",
    '"DamageAnimation", "PetDamageAnimation", "AddCoin", "UpdateCoin"',
    'profileBegin("PSX.ProducerGate")',
    'profileBegin("PSX.LootFallback")',
    "restoreProducerRecord(run.OrbProducerRecord)",
    "restoreProducerRecord(run.CoinProducerRecord)",
    "playerScripts.DescendantAdded:Connect",
    "playerScripts.DescendantRemoving:Connect",
    "disableScriptConnections(",
    "restoreDisabled(run.DisabledBags)",
    'fire("Claim Orbs", ids)',
    'fire("Collect Lootbag", record.Id, position)',
    "folder.ChildAdded:Connect(queueOrbFallback)",
    "folder.ChildAdded:Connect(watchBagFallback)",
    "OrbDropped",
]) {
    assert(loot.includes(marker), `missing native loot marker: ${marker}`);
}
for (const forbidden of [
    "firetouchinterest",
    "CFrame =",
    "RunService.Heartbeat:Connect",
    "RunService.Stepped:Connect",
    "RenderStepped",
    "task.spawn",
    "GetDescendants",
    "AckHistory",
    ":Destroy()",
    "Parent = nil",
]) {
    assert(!loot.includes(forbidden), `forbidden loot behavior returned: ${forbidden}`);
}
assert(loot.includes("if not run.OrbGate then")
    && loot.includes("if not run.BagGate then"),
    "workspace ChildAdded fallback is not gated behind capability detection");
const orbGate = loot.slice(
    loot.indexOf("local function bindOrbGate"),
    loot.indexOf("local function bindBagGate")
);
assert(!orbGate.includes("getconnections")
    && !orbGate.includes('networkSignal("Orb Added")'),
    "Orbs still enumerate or intercept the named event instead of gating AddOrb");
assert(!loot.includes("AssemblyLinearVelocity")
    && !loot.includes("AssemblyAngularVelocity")
    && !loot.includes("object.Anchored")
    && !loot.includes("object.CFrame"),
    "loot fallback mutates physics or transforms");
assert(loot.includes("record.Attempts >= 2")
    && loot.includes("BAG_ACK_TIMEOUT")
    && loot.includes("BAG_FINAL_ACK_TIMEOUT"),
    "direct lootbag collection lacks a bounded acknowledgement policy");

// Graphics uses one temporary one-pass drain and no high-rate descendants.
for (const marker of [
    "QUEUE_CAPACITY = 16384",
    "MAX_PER_FRAME = 128",
    "FRAME_BUDGET_SECONDS = 0.0006",
    "QueueHead = 1",
    'setmetatable({}, { __mode = "k" })',
    "root.ChildAdded:Connect",
    "object:GetChildren()",
    "active.QueueObjects[index] = nil",
    'debug.profilebegin',
    '"PSX.GraphicsQueue"',
]) {
    assert(graphics.includes(marker), `missing coalesced graphics marker: ${marker}`);
}
assert(count(graphics, /RunService\.Heartbeat:Connect/g) === 1,
    "graphics must own exactly one armed frame-budgeted drain");
assert(graphics.includes("if active.QueueCount <= 0 then")
    && graphics.includes("disconnect(active.DrainConnection)"),
    "graphics drain does not disconnect when the queue becomes empty");
assert(!graphics.includes("GetDescendants")
    && !graphics.includes("DescendantAdded")
    && !graphics.includes("SETTLE_DELAY")
    && !graphics.includes("SettleObjects")
    && !graphics.includes("task.spawn")
    && !graphics.includes(":Destroy()")
    && !graphics.includes("Parent = nil"),
    "graphics performs an unbounded scan/task/destructive mutation");
const thingRoots = graphics.slice(
    graphics.indexOf("local LOW_RATE_ROOTS"),
    graphics.indexOf("local EFFECT_CLASSES")
);
assert(thingRoots.includes("Pets") && thingRoots.includes("Eggs")
    && thingRoots.includes("Machines") && !thingRoots.includes("Coins")
    && !thingRoots.includes("Orbs") && !thingRoots.includes("Lootbags"),
    "graphics high-rate and loot root ownership overlap");
assert(graphics.includes('"things:Coins"')
    && graphics.includes('"farm", false'),
    "graphics lost its one-time existing Coins cleanup");
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
    + " | petTransport=lite-event-driven | graphicsDrain=1 | uiHz=1\n"
);
