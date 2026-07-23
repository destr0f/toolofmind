const fs = require("fs");
const path = require("path");

const root = path.resolve(__dirname, "..");
const read = (file) => fs.readFileSync(path.join(root, file), "utf8");
const assert = (condition, message) => {
    if (!condition) throw new Error(message);
};

const farm = read("slim_farm.lua");
const loot = read("loot_reactor.lua");
const graphics = read("graphics_module.lua");
const egg = read("auto_egg_module.lua");
const boost = read("boost_module.lua");
const machines = [
    read("gold_machine_module.lua"),
    read("rainbow_machine_module.lua"),
    read("dark_matter_module.lua"),
];

let generation = 1;
let active = true;
let mutations = 0;
const callbacks = [];
for (let index = 0; index < 100_000; index += 1) {
    const captured = generation;
    callbacks.push(() => {
        if (!active || captured !== generation) return;
        mutations += 1;
    });
}
active = false;
generation += 1;
for (const callback of callbacks) callback();
callbacks.length = 0;
assert(mutations === 0 && callbacks.length === 0,
    "stale generation callbacks mutated the new run");

assert(loot.includes("run.Generation = run.Generation + 1")
    && loot.includes("if generation ~= run.Generation then return end")
    && loot.includes("clearConnections(run.Connections)")
    && loot.includes("clearWorld()")
    && loot.includes("run.Context = nil"),
    "loot lifecycle does not fully invalidate/disconnect/clear");
const statusCallback = loot.slice(
    loot.indexOf("task.delay(STATUS_INTERVAL"),
    loot.indexOf("local function fire")
);
assert(statusCallback.indexOf("if generation ~= run.Generation then return end")
    < statusCallback.indexOf("run.StatusArmed = false"),
    "a stale loot status callback can mutate the new generation");
const retryCallback = loot.slice(
    loot.indexOf("task.delay(BAG_RETRY_DELAY"),
    loot.indexOf("local function watchReadyChild")
);
assert(retryCallback.indexOf("if generation ~= run.Generation")
    < retryCallback.indexOf("run.RetryArmed = false"),
    "a stale loot retry callback can mutate the new generation");

for (const marker of [
    "active.Generation = (active.Generation or 0) + 1",
    "disconnect(active.DrainConnection)",
    "clearArray(active.QueueObjects)",
    "clearArray(active.SettleObjects)",
    "active.FirstSeen = nil",
    "active.SecondSeen = nil",
    "active.SettleSeen = nil",
    "active.Protection = nil",
]) {
    assert(graphics.includes(marker), `graphics STOP misses ${marker}`);
}

assert(egg.includes("if activeState and activeState.Running then return true end")
    && egg.includes("clearPhysicalBindings(true)")
    && egg.includes("state.Connection = nil")
    && egg.includes("state.WorkerThread = nil")
    && egg.includes("pcall(task.cancel, worker)")
    && egg.includes("if activeState == state then activeState = nil end"),
    "auto egg can retain a duplicate worker or physical bindings");
assert(boost.includes("if activeState and activeState.Running then return true end")
    && boost.includes("state.WorkerThread = nil")
    && boost.includes("pcall(task.cancel, worker)")
    && boost.includes("state.Context = nil"),
    "boost worker is not cancelled and released on STOP");
for (const [index, machine] of machines.entries()) {
    assert(machine.includes("if activeState and activeState.Running then return true end")
        && machine.includes("stopped.Running = false")
        && machine.includes("stopped.WorkerThread = nil")
        && machine.includes("pcall(task.cancel, worker)")
        && machine.includes("activeState = nil"),
        `machine ${index + 1} can retain a duplicate worker`);
}
for (const marker of [
    "diamondWorker.Generation = diamondWorker.Generation + 1",
    "rewardWorker.Generation = rewardWorker.Generation + 1",
    "cancelScheduledTask(diamondWorker.Thread)",
    "cancelScheduledTask(rewardWorker.Thread)",
    "petLifecycle.BindToken = petLifecycle.BindToken + 1",
    "farmWatch.RecoveryToken = farmWatch.RecoveryToken + 1",
    "farmWatch.ZoneToken = farmWatch.ZoneToken + 1",
    "disconnectPetLifecycleSignals()",
    "table.clear(petLifecycle.Signals)",
]) {
    assert(farm.includes(marker), `main STOP misses generation cleanup: ${marker}`);
}
const petLifecycleOwner = farm.slice(
    farm.indexOf("local function connectPetLifecycleSignal"),
    farm.indexOf("local function bindPetLifecycleSignals")
);
assert(!petLifecycleOwner.includes("track(connection)"),
    "pet lifecycle connection has both a local and global owner");

process.stdout.write(
    "Generation cleanup OK | staleCallbacks=100000 | mutations=0 | retained=0\n"
);
