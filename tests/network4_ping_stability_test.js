const assert = require("assert");
const fs = require("fs");
const path = require("path");

const root = path.resolve(__dirname, "..");
const read = (file) => fs.readFileSync(path.join(root, file), "utf8");
const farm = read("slim_farm.lua");
const engine = read("pet_farm_lite_engine.lua");
const loot = read("loot_reactor.lua");
const transport = read("network4_transport_module.lua");
const manifest = JSON.parse(read("runtime_manifest.json"));

assert(manifest.suite.version.startsWith("1.4.1-candidate.54"));
assert.strictEqual(manifest.modules.networkTransport.version, "1.5.4");
assert.strictEqual(manifest.modules.petFarmEngine.version, "1.4.7");
assert.strictEqual(manifest.modules.lootReactor.version, "3.8.0");
assert.strictEqual(manifest.modules.requestInspector.version, "1.0.2");

// Current-session resolver: live maps first, current Network5 VLG hash,
// bounded NetworkHash attribute fallback, exact invalidation and no child index.
for (const marker of [
    "local function djb2Hash(message)",
    'add(routeHash(context, kind, commandName), "current Network5 VLG")',
    'add(djb2Hash(commandName), "legacy DJB2")',
    '"PSXOG:SECRET:NETWORK:VLG:12910259120591716249102"',
    'remote.GetAttribute, remote, "NetworkHash"',
    "pcall(storage.GetChildren, storage)",
    "cached.Generation == generation",
    "local function invalidate(context, kind, commandName, expected)",
    'if action == "stats" then return stats() end',
]) assert(transport.includes(marker), `transport misses ${marker}`);
assert(!transport.includes("GetChildren()[")
    && !transport.includes('"mmmmmmevilfanta54125612512416124/Network5/"')
    && !transport.includes('"duskissexyyyyy123iloveudUsk/Network4/"'));

// Completed Join Coin responses are not replayable. TTL records self-delete
// with both epoch and timestamp guards, and reset clears every map.
assert(engine.includes("local DEFAULT_DISPATCH_WIDTH = 16"));
assert(engine.includes("local MAX_QUEUED_JOBS = 32"));
assert(engine.includes("DispatchSpacing") && engine.includes("0.012"));
assert(engine.includes("run.NextLaunchAt = due + spacing"));
assert(engine.includes("local routedCommand = preferredCommand(context, command)"));
assert(engine.includes('"Library.Network.Invoke [" .. tostring(routedCommand)'));
assert(farm.includes("CommandRouteCandidates = function(commandName)"));
assert(engine.includes("while not inflight.done")
    && engine.includes("transportGate.InFlight[gateKey] = nil"));
assert(!engine.includes("transportGate.InvokeHistory[gateKey] ="));
assert(engine.includes("run.Epoch == epoch and map[key] == timestamp"));
for (const map of ["Fire", "Invoke", "InFlight", "InvokeHistory"]) {
    assert(engine.includes(`table.clear(transportGate.${map})`),
        `transport map is not cleared: ${map}`);
}

// Lease expiry is local bookkeeping only. Membership absence and Remove Coin
// remain authoritative release paths.
assert(!farm.includes("function petFarm:RunSignalCommits")
    && !farm.includes("function petFarm:SendCommittedFarmSignals"));
const lease = farm.slice(
    farm.indexOf("function petFarm:RunProgressLeases"),
    farm.indexOf("function petFarm:ScheduleProgressLease")
);
for (const command of ["Join Coin", "Leave Coin", "Change Pet Target", "Farm Coin"]) {
    assert(!lease.includes(command), `lease timeout sends ${command}`);
}
assert(farm.includes('["Get Coins"] = { "Get Coins Data", "Get The Coins", "Get Coins" }'));
assert(farm.includes("self.ProgressLeaseEvictions = self.ProgressLeaseEvictions + 1")
    && farm.includes("self:QueueFastDispatch()"));

// Orb Removed never authorizes retries of unrelated committed IDs.
assert(loot.includes("local ORB_MIN_BATCH = 8"));
assert(loot.includes("local ORB_FLUSH_INTERVAL = 0.65"));
assert(loot.includes("local ORB_BATCH_SIZE = 128"));
assert(loot.includes("run.PendingOrbCount >= ORB_MIN_BATCH"));
for (const forbidden of [
    "MAX_ORB_DELIVERY_ATTEMPTS", "OrbDeliveryAttempts", "OrbAckObserved", "OrbRetryArmed",
]) assert(!loot.includes(forbidden), `orb global retry state returned: ${forbidden}`);

// There is no cross-subsystem governor/shared network queue in the candidate.
for (const forbidden of ["RequestLaneGovernor", "GlobalNetworkQueue", "SharedNetworkQueue"]) {
    assert(!farm.includes(forbidden) && !engine.includes(forbidden) && !loot.includes(forbidden));
}

console.log("Network4 ping stability policy OK | lanes=16 | orb=one-shot | replay=off");
