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
assert(farm.includes('connect("Update Coin Pets", function(id, pets)')
    && farm.includes("controller:ConfirmCoinPets(id, pets)"),
    "Lite farm is missing its transition-only Join Coin membership acknowledgement");
const membershipStart = farm.indexOf("function petFarm:ConfirmCoinPets");
const membershipEnd = farm.indexOf("function petFarm:RefreshStats", membershipStart);
const membershipBody = farm.slice(membershipStart, membershipEnd);
assert(membershipBody.includes("if not interested then return end")
    && membershipBody.includes("table.clear(present)"),
    "Update Coin Pets is not bounded to pending local assignments");
for (const forbidden of ["requestAllocatorPulse", "applyCoinData", "record.Pets", "refreshWorkspaceCoins"]) {
    assert(!membershipBody.includes(forbidden),
        `Update Coin Pets became a retained reconciliation path: ${forbidden}`);
}
const snapshotStart = farm.indexOf("refreshCoinSnapshot = function()");
const snapshotEnd = farm.indexOf("local function connectCoinSignals", snapshotStart);
assert(snapshotStart >= 0 && snapshotEnd > snapshotStart,
    "Get Coins snapshot boundary is missing");
const outsideSnapshot = farm.slice(0, snapshotStart) + farm.slice(snapshotEnd);
assert(!outsideSnapshot.includes('network.Invoke("Get Coins"')
    && !outsideSnapshot.includes('getCommandRemote("Get Coins"')
    && !outsideSnapshot.includes('InvokeServer("Get Coins"'),
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

// Loot owns Orbs/Lootbags and gates game producers before Instance creation.
// The hot path is one deferred orb batch plus one scalar four-lane bag pump.
for (const marker of [
    'local MODULE_VERSION = "3.6.3"',
    "ORB_BATCH_SIZE = 512",
    "MAX_PENDING_ORBS = 8192",
    "ORB_FLUSH_INTERVAL = 0.25",
    "CLIENT_STAGGER_SLOTS = 16",
    "CLIENT_STAGGER_STEP = 0.01",
    "BAG_LANES = 4",
    "MAX_PENDING_BAGS = 4096",
    "BAG_TRANSPORT_RETRY_DELAY = 0.10",
    "MAX_BAG_TRANSPORT_ATTEMPTS = 2",
    "STATUS_INTERVAL = 1",
    "PendingOrbIds = {}",
    "OrbBatch = table.create(ORB_BATCH_SIZE)",
    "BagById = {}",
    "BagQueue = {}",
    "BagDelayed = {}",
    "BagPool = {}",
    'profileBegin("PSX_OrbFlush")',
    'profileBegin("PSX_LootbagFlush")',
    'fire("Claim Orbs", ids)',
    'fire("Collect Lootbag", record.Id, record.Position)',
    "task.delay(delaySeconds, function()",
    'networkSignal("Remove Lootbag")',
    "type(getsenv)",
    'findGameScript("Orbs")',
    'findGameScript("Lootbags")',
    'findGameScript("Coins")',
    "environment.AddOrb",
    '{ "Add", "ScanForCollection", "Remove" }',
    "record.Wrappers.ScanForCollection",
    "record.Wrappers.Remove",
    '"DamageAnimation", "PetDamageAnimation", "AddCoin", "UpdateCoin"',
    "restoreProducerRecord(run.OrbProducerRecord)",
    "restoreProducerRecord(run.BagProducerRecord)",
    "restoreProducerRecord(run.CoinProducerRecord)",
    "playerScripts.ChildAdded:Connect",
    "folder.ChildAdded:Connect(queueOrbFallback)",
    "folder.ChildAdded:Connect(watchBagFallback)",
    "record.Attempts < MAX_BAG_TRANSPORT_ATTEMPTS",
    "record.Retired = true",
    "OrbDropped",
    "BagOverflow",
]) {
    assert(loot.includes(marker), `missing native loot marker: ${marker}`);
}
assert(loot.includes("run.UnconfirmedOrbIds[orbId] = now")
    && loot.includes("run.OrbTransportCommitted = run.OrbTransportCommitted + 1")
    && loot.includes("run.OrbAckObserved and attempts < MAX_ORB_DELIVERY_ATTEMPTS")
    && loot.includes("run.OrbExpiredUnverified = run.OrbExpiredUnverified + 1"),
    "orb delivery is not retained and retried within a bounded ACK policy");
assert(loot.includes("record.State = \"committed\"")
    && loot.includes("run.BagSentUnverifiable = run.BagSentUnverifiable + 1")
    && loot.includes('closeBag(record, false, "transport committed")')
    && loot.includes("run.BagTransportCommitted = run.BagTransportCommitted + 1"),
    "successful bag sends are not closed after one native transport commit");
assert(loot.includes("record.Attempts < MAX_BAG_TRANSPORT_ATTEMPTS")
    && loot.includes("record.State = \"retry\"")
    && loot.includes("enqueueDelayedBag(record, now + BAG_TRANSPORT_RETRY_DELAY)"),
    "lootbags do not retry a genuine transport failure once");
assert(loot.includes("local earliest = (tonumber(run.OrbLastFlushAt) or 0) + interval")
    && loot.includes("delaySeconds = interval + clientStagger()")
    && !loot.includes("task.defer(function()\n        if generation ~= run.Generation or token ~= run.OrbToken then return end\n        flushOrbs()"),
    "orb callbacks can still create same-window microflushes");
assert(loot.includes("run.OrbAckAvailable")
    && loot.includes('networkSignal("Orb Removed")')
    && loot.includes("run.OrbAckObserved = true")
    && loot.includes("run.UnconfirmedOrbIds[id] = nil"),
    "Orb Removed does not acknowledge retained local sends");
assert(loot.includes("local function currentRTT()")
    && loot.includes("local function orbFlushInterval()")
    && loot.includes("context.GetPingSeconds")
    && loot.includes("local function orbConfirmationDelay()"),
    "orb pacing and bounded confirmation are not actual-ping aware");
assert(loot.includes('record.Object = typeof(sourceObject) == "Instance" and sourceObject or nil')
    && loot.includes("record.Position = objectPosition(liveObject) or record.Position"),
    "fallback lootbag retries do not refresh the live landed position");
assert(loot.includes("return originalAddOrb(id, payload, ...)")
    && loot.includes("return originalAdd(id, payload, ...)")
    && loot.includes("return originalScan(...)")
    && loot.includes("return originalRemove(id, ...)"),
    "producer gates are not fail-open on unsupported payloads/executors");
for (const forbidden of [
    "firetouchinterest",
    "CFrame =",
    "AssemblyLinearVelocity",
    "AssemblyAngularVelocity",
    "RunService.Heartbeat:Connect",
    "RunService.Stepped:Connect",
    "RenderStepped",
    "task.spawn",
    "GetDescendants",
    "DescendantAdded",
    "AckHistory",
    "getconnections",
    "record.Instance",
    ":Destroy()",
    "Parent = nil",
]) {
    assert(!loot.includes(forbidden), `forbidden loot behavior returned: ${forbidden}`);
}
const profileLabels = [...loot.matchAll(/profileBegin\("([^"]+)"\)/g)].map((match) => match[1]);
assert(profileLabels.length === 2
    && profileLabels.includes("PSX_OrbFlush")
    && profileLabels.includes("PSX_LootbagFlush"),
    `unexpected loot profiler labels: ${profileLabels.join(", ")}`);

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
    '"PSX_GraphicsQueue"',
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
    "table.clear(coinSync.RemoteCaches.Command)",
    "table.clear(coinSync.RemoteCaches.Event)",
    "table.clear(coinSync.RemoteCaches.Fire)",
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
