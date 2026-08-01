const fs = require("fs");
const path = require("path");

const root = path.resolve(__dirname, "..");
const read = (name) => fs.readFileSync(path.join(root, name), "utf8");
const assert = (condition, message) => {
    if (!condition) throw new Error(message);
};

const farm = read("slim_farm.lua");
const engine = read("pet_farm_lite_engine.lua");
const loot = read("loot_reactor.lua");
const egg = read("auto_egg_module.lua");
const modules = [
    "auto_egg_module.lua",
    "automation_support_module.lua",
    "automation_ui_module.lua",
    "boost_module.lua",
    "dark_matter_module.lua",
    "gold_machine_module.lua",
    "graphics_module.lua",
    "loot_reactor.lua",
    "pet_farm_lite_engine.lua",
    "rainbow_machine_module.lua",
].map(read).join("\n");

for (const marker of [
    "networkGovernor = {",
    "Routes = {}",
    "Active = {}",
    "BackpressureUntil = 0",
    "local LATENCY_WINDOW = 32",
    "local SNAPSHOT_INTERVAL = 5",
    "CategoryCalls = { Farm = 0, Loot = 0, Egg = 0, Background = 0 }",
    "function networkGovernor:Begin",
    "function networkGovernor:Finish",
    "function networkGovernor:MarkStale",
    "function networkGovernor:SetLootStats",
    "function networkGovernor:Snapshot",
    "function networkGovernor:Stop",
    "env.PSX_OG_NETWORK_ROUTE_GOVERNOR = networkGovernor",
]) {
    assert(farm.includes(marker), `missing governor marker: ${marker}`);
}

const semanticStart = farm.indexOf("local function semanticKey");
const semanticEnd = farm.indexOf("local function routeFor", semanticStart);
const semantic = farm.slice(semanticStart, semanticEnd);
assert(semantic.includes('command == "Join Coin" or command == "Leave Coin"'),
    "Join/Leave semantic keys are not batch-specific");
assert(semantic.includes('command == "Change Pet Target"')
    && semantic.includes("compactValue(arguments[3])"),
    "Change Pet Target does not include coinID in its semantic key");
assert(semantic.includes('command == "Claim Orbs"')
    && semantic.includes("loot reactor owns per-orb deduplication"),
    "Claim Orbs does not delegate exact ID dedup to the one-inflight reactor");

const beginStart = farm.indexOf("function networkGovernor:Begin");
const beginEnd = farm.indexOf("function networkGovernor:Finish", beginStart);
const begin = farm.slice(beginStart, beginEnd);
assert(begin.indexOf("self.Active[key] = true") >= 0
    && begin.indexOf("self.Active[key] = true") < begin.indexOf("route.PhaseAt"),
    "semantic reservation occurs after background phase waits");
assert(begin.includes("if route.Priority >= 3 then")
    && begin.includes("os.clock() < self.BackpressureUntil"),
    "backpressure is not isolated to P3/P4 routes");
assert(!begin.includes("self.RecentP95 >= LOW_PRIORITY_P95_LIMIT"),
    "historical p95 can still latch backpressure forever");

const invokeServerCalls = (farm.match(/:InvokeServer\(/g) || []).length;
const fireServerCalls = (farm.match(/:FireServer\(/g) || []).length;
assert(invokeServerCalls === 1 && fireServerCalls === 1,
    `outgoing remote calls bypass wrappers: invoke=${invokeServerCalls}, fire=${fireServerCalls}`);
assert(!/Library\.Network\.(?:Invoke|Fire)\s*\(/.test(modules)
    && !/\bnetwork\.(?:Invoke|Fire)\s*\(/.test(modules),
    "an active module bypasses the central route governor");
assert(egg.includes("context.FireCommand,")
    && egg.includes('"Opening Egg"'),
    "Opening Egg does not use the governed Fire route");

assert(engine.includes('pcall(context.MarkStale, "Join Coin", #rejectedEntries)')
    && engine.includes("failEntries(job, rejectedEntries, run.LastProblem)"),
    "accepted-transport Join rejections are not marked stale and rerouted");
assert(engine.includes("return scheduleRetry(job, entries, run.LastProblem, false)")
    && !engine.slice(engine.indexOf("if #rejectedEntries > 0"),
        engine.indexOf("if #signalFailures > 0")).includes("scheduleRetry"),
    "server rejections can still enter the transport retry path");

for (const marker of [
    "ORB_MIN_FLUSH_INTERVAL = 0.10",
    "ORB_MAX_FLUSH_INTERVAL = 0.25",
    "if not orbsEnabled() or run.PendingOrbCount == 0 or run.OrbInFlight then return end",
    "run.OrbAwaitingIds[orbId] = sentAt",
    'record.State = "DISCOVERED"',
    'record.State = "QUEUED"',
    'record.State = "SENT"',
    'record.State = acknowledged and "CONFIRMED"',
    "WaitingBags = run.WaitingBagCount",
    "BagInFlight = run.BagInFlightCount",
]) {
    assert(loot.includes(marker), `missing bounded loot marker: ${marker}`);
}
for (const forbidden of [
    "firetouchinterest",
    "AssemblyLinearVelocity",
    "AssemblyAngularVelocity",
    "RunService.Heartbeat:Connect",
    "RenderStepped",
]) {
    assert(!loot.includes(forbidden), `loot hot path contains ${forbidden}`);
}

for (const marker of [
    "F/L/E/B %.1f/%.1f/%.1f/%.1f/s",
    "Top: %s",
    "O p/a/i %d/%d/%d | B p/i %d/%d",
    "coalesced/rejected/transport/timeout/stale",
    "Quick HUD: Network",
]) {
    assert(farm.includes(marker), `missing bounded network HUD marker: ${marker}`);
}
assert(farm.includes("networkGovernor:Stop()")
    && farm.includes("env.PSX_OG_NETWORK_ROUTE_GOVERNOR = nil"),
    "STOP/reload does not clear the route governor");

for (const forbidden of ["hookmetamethod(", "hookfunction(", "getgc("]) {
    assert(!farm.includes(forbidden), `governor installs forbidden ${forbidden}`);
}

process.stdout.write(
    "Network route governor policy OK"
    + " | wrappers=2 | semantic=exact | loot=one-inflight/FSM"
    + " | backpressure=P3/P4-windowed | HUD=5s\n"
);
