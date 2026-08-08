const fs = require("fs");
const path = require("path");

const root = path.resolve(__dirname, "..");
const source = fs.readFileSync(path.join(root, "auto_egg_module.lua"), "utf8");

function requireText(fragment, message) {
    if (!source.includes(fragment)) throw new Error(message);
}

requireText('local MODULE_VERSION = "1.6.4"',
    "auto egg module version was not advanced");
requireText('local OPEN_EGG_EVENT_NAMES = { "openegggg", "Open Egg" }',
    "the renamed live hatch event is not resolved before the legacy alias");
requireText('resolveOpenEggSignal(context)',
    "the hatch listener does not use the alias-aware resolver");
requireText('purchase remains enabled',
    "missing inbound acknowledgement still blocks Buy Egg Yay");
requireText('if signal and (not connected or not connection) then',
    "signal-less inventory fallback is still rejected as a listener failure");
requireText('"\\nRoutes: Open Eggs %s | Egg World %s | prevented open/world %d/%d"',
    "the hatch controller does not expose both visual gate routes and counters");
requireText('FindFirstChild("Open Eggs")',
    "headless gate does not locate the live Open Eggs LocalScript");
requireText('if type(getsenv) ~= "function" then',
    "getsenv capability is not guarded");
requireText('scriptEnvironment.OpenEgg = wrapper',
    "native OpenEgg producer is not replaced");
requireText('local HEADLESS_EVENT_GATE = "direct Open Egg RemoteEvent producer gate"',
    "missing OpenEgg exports do not have a direct RemoteEvent producer gate");
requireText('captureHeadlessEventGate(signal, eventRoute)',
    "native Open Egg dispatcher is not captured before the module listener");
requireText('callConnectionMethod(state.EventGateConnection, "Disable")',
    "direct headless route does not pause the native visual dispatcher");
requireText('callConnectionMethod(state.EventGateConnection, "Enable")',
    "direct headless route cannot restore the native visual dispatcher");
requireText('state.Running and state.GateOwned and pending and pending.Headless',
    "producer wrapper is not scoped to an owned headless request");
requireText('profileBegin("PSX_EggOpenGate")',
    "OpenEgg producer gate is missing its MicroProfiler marker");
requireText('return original(eggName, pets)',
    "native animation path is not preserved outside headless requests");
requireText('restoreHeadlessProducerGate(state)',
    "producer wrapper does not have a cleanup path");
requireText('restoreEggWorldVisualGate(state, context, false)',
    "world egg producer wrappers do not have a STOP cleanup path");
requireText('FindFirstChild("Eggs")',
    "world egg gate does not locate the separate Game/Eggs LocalScript");
requireText('environment.UpdateEgg = record.Wrappers.UpdateEgg',
    "world egg model producer is not gated before allocation");
requireText('environment.UpdateAllEggs = record.Wrappers.UpdateAllEggs',
    "world egg refresh producer is not coalesced behind the gate");
requireText('pcall(originalSetupEgg, egg)',
    "world egg gate does not preserve one-time manual input setup");
requireText('profileBegin("PSX_EggWorldGate")',
    "world egg gate is missing its MicroProfiler marker");
requireText('Game/Eggs visual gate assignment was not retained',
    "world egg gate does not fail open after assignment readback failure");
requireText('Headless refuses to fall back to visible animation',
    "unsupported executors do not fail closed");
requireText('local HEADLESS_INVENTORY_FALLBACK = "exact inventory-delta compatibility fallback"',
    "missing OpenEgg exports do not have a bounded compatibility route");
requireText('Open Eggs.OpenEgg is not exported as a callable function',
    "missing OpenEgg exports are not diagnosed");
requireText('return true, state.OpenEggGateRoute',
    "a missing OpenEgg export still blocks the exact inventory-delta fallback");
requireText('ProducerGateRoute = headless and state.OpenEggGateRoute or nil',
    "the selected headless acknowledgement route is not retained per request");
requireText('local exactMatch = pending and not pending.EventReceived',
    "a duplicate/manual event can still replace an owned pending payload");
requireText('pending.ProducerGateRoute == HEADLESS_EVENT_GATE',
    "acknowledgement ownership is not scoped to the direct producer gate");
requireText('allCandidateUidsAbsent(context, candidates)',
    "Auto Delete rejection is not idempotent after a native/manual delete race");

if (source.includes('local gateFallback =')) {
    throw new Error("broad owned-gate event matching can still steal a manual hatch");
}

const beginRequest = source.indexOf("local function beginRequest");
const producerPreflight = source.indexOf("ensureHeadlessProducerGate(state, context)", beginRequest);
const invoke = source.indexOf('context.InvokeCommand("Buy Egg Yay"', beginRequest);
if (beginRequest < 0 || producerPreflight < beginRequest || invoke < 0 || producerPreflight > invoke) {
    throw new Error("headless producer gate is not installed before Buy Egg Yay");
}

for (const forbidden of ["hookmetamethod(", "hookfunction("]) {
    if (source.includes(forbidden)) {
        throw new Error(`headless producer gate must not install global ${forbidden}`);
    }
}

console.log("Auto egg headless producer gate OK | native gate preferred | inventory-delta compatibility fallback bounded");
