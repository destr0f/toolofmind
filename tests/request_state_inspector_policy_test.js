const fs = require("fs");
const path = require("path");

const root = path.resolve(__dirname, "..");
const read = (file) => fs.readFileSync(path.join(root, file), "utf8");
const assert = (condition, message) => {
    if (!condition) throw new Error(message);
};

const inspector = read("request_state_inspector.lua");
const farm = read("slim_farm.lua");
const engine = read("pet_farm_lite_engine.lua");
const loot = read("loot_reactor.lua");
const support = read("automation_support_module.lua");

// The inspector is an observer: it cannot send traffic, discover remotes by
// scanning the VM, or attach a frame-rate callback to the client hot path.
for (const forbidden of [
    "hookmetamethod",
    "hookfunction",
    "getgc",
    "getconnections",
    "RenderStepped",
    "Heartbeat",
    'WaitForChild("Main")',
]) {
    assert(!inspector.includes(forbidden),
        `passive inspector contains forbidden behavior: ${forbidden}`);
}
assert(!/[.:](?:InvokeServer|FireServer)\s*\(/.test(inspector),
    "passive inspector performs a direct remote call");

for (const marker of [
    'local MODULE_VERSION = "1.0.2"',
    "local EVENT_CAPACITY = 48",
    "local SNAPSHOT_CAPACITY = 4",
    "local ACTIVE_CAPACITY = 48",
    "local UPDATE_EXPANDED = 2",
    "local UPDATE_MINIMIZED = 8",
    "local HIGH_FREQUENCY_EVENT_INTERVAL = 2.5",
    'Name = "PSX_OG_RequestInspector"',
    'button("Snap"',
    'button("Copy"',
    'button("Clear"',
    '"Farm", "Egg", "Loot", "Gate", "Background", "Routes", "Startup", "Reload", "Incident"',
    "function controller:Transition(",
    "function controller:SetGauge(",
    "function controller:Complete(",
    "function controller:Snapshot(",
    "function controller:Destroy(",
    "task.delay(delay, function() updateLoop(state) end)",
    "local function shouldRecordEvent(",
    'root.Visible = false',
    'show.Visible = true',
]) {
    assert(inspector.includes(marker), `inspector contract misses ${marker}`);
}
const terminalStart = inspector.indexOf("local TERMINAL = {");
const validStart = inspector.indexOf("local VALID_STATE = {");
assert(terminalStart >= 0 && validStart > terminalStart
    && inspector.slice(terminalStart, validStart).includes("FIRE_LOCAL_SENT_UNACKED = true"),
    "unacknowledgeable Fire observations must not occupy the active registry");
assert(inspector.includes('and not TERMINAL[stateName] then'),
    "terminal Fire observations must not increment the active unacknowledged gauge");

for (const state of [
    "IDLE",
    "WAITING_READY",
    "WAITING_GATE",
    "QUEUED",
    "COALESCED_INTO",
    "INVOKE_IN_FLIGHT",
    "FIRE_LOCAL_SENT_UNACKED",
    "WAITING_GAME_ACK",
    "WAITING_INVENTORY_DELTA",
    "POST_PROCESSING",
    "SERVER_ACCEPTED",
    "SERVER_REJECTED",
    "TRANSPORT_FAILED",
    "TIMED_OUT_LOCALLY_REMOTE_UNKNOWN",
    "LOCAL_CANCELLED_REMOTE_UNKNOWN",
    "COMPLETED",
    "CANCELLED_BY_DISABLE",
    "CANCELLED_BY_RELOAD",
    "DROPPED_WITH_REASON",
]) {
    assert(inspector.includes(`${state} = true`), `missing request state ${state}`);
}

for (const incident of [
    "FARM_STUCK_INVOKE",
    "FARM_REQUEST_BACKLOG",
    "EGG_WAITING_GAME_ACK",
    "EGG_POSTPROCESS_HOLD",
    "INVENTORY_GATE_STARVATION",
    "ORB_FIRE_UNACKNOWLEDGED",
    "LOOTBAG_RETIRED_WITHOUT_ACK",
    "PRODUCER_COLD",
    "ROUTE_UNRESOLVED",
    "STARTUP_REQUEST_BURST",
    "RELOAD_GHOST_GENERATION",
    "CLIENT_SCHEDULER_STALL",
    "NETWORK_OR_EXECUTOR_UNKNOWN",
]) {
    assert(inspector.includes(`${incident} = {`), `missing incident classifier ${incident}`);
}

// Integration is attached only to existing request boundaries. A successful
// RemoteEvent call deliberately stays unacknowledged; it is not fabricated as
// a server acceptance or completion.
assert(farm.includes('"requestInspector"')
    && farm.includes("requestDiagnostics.Start()")
    && farm.includes("requestDiagnostics.UpdateTelemetry(monitorVisible)")
    && farm.includes("InspectorTransition = requestDiagnostics.Transition")
    && farm.includes("InspectorComplete = requestDiagnostics.Complete"),
    "main runtime does not bridge its existing boundaries into the inspector");
assert(farm.includes('requestDiagnostics.Transition(subsystem, diagnosticId, "FIRE_LOCAL_SENT_UNACKED"'),
    "successful Fire calls are not represented as local unacknowledged sends");
assert(!/FIRE_LOCAL_SENT_UNACKED[\s\S]{0,260}(SERVER_ACCEPTED|COMPLETED)/.test(
    farm.slice(farm.indexOf("local function networkFire"), farm.indexOf("local function gateAcquire"))
), "networkFire fabricates a server acknowledgement after FireServer returns locally");

for (const marker of [
    "env.PSX_OG_REQUEST_INSPECTOR_BOOT",
    "env.PSX_OG_REQUEST_INSPECTOR",
    "PSX_OG_REQUEST_INSPECTOR_HANDOFF",
    'pcall(requestDiagnostics.Controller.Snapshot, requestDiagnostics.Controller, "shutdown")',
    "pcall(requestDiagnostics.Controller.Destroy, requestDiagnostics.Controller",
]) {
    assert(farm.includes(marker) || inspector.includes(marker),
        `generation-safe inspector lifecycle misses ${marker}`);
}

// Hot automation policy must remain exactly at the pre-inspector values.
for (const marker of [
    "local DEFAULT_DISPATCH_WIDTH = 16",
    "local MAX_QUEUED_JOBS = 32",
    "local MAX_JOIN_ATTEMPTS = 2",
    "local RETRY_DELAY = 0.25",
]) {
    assert(engine.includes(marker), `farm hot policy changed: ${marker}`);
}
for (const marker of [
    "local ORB_BATCH_SIZE = 512",
    "local MAX_PENDING_ORBS = 8192",
    "local BAG_LANES = 4",
    "local MAX_PENDING_BAGS = 4096",
    "local BAG_TRANSPORT_RETRY_DELAY = 0.10",
    "local MAX_BAG_TRANSPORT_ATTEMPTS = 2",
    "local ORB_FLUSH_INTERVAL = 0.55",
]) {
    assert(loot.includes(marker), `loot hot policy changed: ${marker}`);
}
assert(support.includes("now - gate.OwnerSince > 45")
    && support.includes("now - (waiter.SeenAt or 0) > 2")
    && support.includes("OwnerExpirySeconds = 45")
    && support.includes("WaiterExpirySeconds = 2"),
    "inventory gate behavior constants changed while adding diagnostics");

process.stdout.write(
    "Passive request inspector policy OK | network=0 | hooks=0"
    + " | events=48 | snapshots=4 | active=48 | sampledLoot=on | hotPolicy=unchanged\n"
);
