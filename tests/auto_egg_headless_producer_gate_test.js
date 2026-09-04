const fs = require("fs");
const path = require("path");

const root = path.resolve(__dirname, "..");
const source = fs.readFileSync(path.join(root, "auto_egg_module.lua"), "utf8");

function requireText(fragment, message) {
    if (!source.includes(fragment)) throw new Error(message);
}

requireText('local MODULE_VERSION = "1.8.0"',
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
requireText('captureHeadlessEventGate(signal, eventRoute, context, openEggScript)',
    "native Open Egg dispatcher is not captured before the module listener");
requireText('local HEADLESS_NATIVE_HOOK = "native openegggg OpenEgg closure gate"',
    "headless does not identify the native OpenEgg closure gate");
requireText('addSignal(child.Event, "Network5 BindableEvent stand-in")',
    "headless does not inspect Network5's private openegggg stand-in");
requireText('local function findNativeOpenEgg(callback, openEggScript)',
    "headless cannot recover the closed-over native OpenEgg renderer");
requireText('local function installNativeOpenEggHook(state, context)',
    "headless does not install the scoped native OpenEgg renderer gate");
requireText('local ok, previous = pcall(hookfunction, target, wrapper)',
    "headless does not stop native allocation at the closed-over OpenEgg function");
requireText('state.EventGateConnections = {}',
    "native openegggg acknowledgement callback is still disabled after a successful renderer hook");
requireText('or that command\'s private BindableEvent signal',
    "Library.Network.Fired fallback is not accepted as a command-specific producer gate");
requireText('local direct, sourceName, sessionIndex = directSignal(commandName)',
    "Network4's lazy Fired binding is not followed by a direct RemoteEvent retry");
requireText('after Library.Network.Fired binding',
    "the direct post-bind route is not exposed in diagnostics");
requireText('local selected = #openEggCandidates > 0 and openEggCandidates',
    "all exact Open Eggs visual callbacks are not preferred over Network's bridge");
requireText('for _, connection in ipairs(state.EventGateConnections or {}) do',
    "direct headless route does not manage every captured native dispatcher");
requireText('callConnectionMethod(connection, "Disable")',
    "direct headless route does not pause captured native visual dispatchers");
requireText('callConnectionMethod(connection, "Enable")',
    "direct headless route cannot restore captured native visual dispatchers");
requireText('The inbound command gate is stronger than replacing an exported',
    "the exact inbound producer gate is not preferred over the weak getsenv export");
requireText('useHeadlessInventoryFallback(state, context, openEggScript',
    "missing producer exports still block the bounded inventory-delta hatch path");
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
requireText('Open Eggs.OpenEgg is not exported and the exact event producer gate is unavailable',
    "missing producer gates are not diagnosed before bounded fallback");
requireText('ProducerGateRoute = headless and state.OpenEggGateRoute or nil',
    "the selected headless acknowledgement route is not retained per request");
requireText('pending.ProducerGateRoute == HEADLESS_INVENTORY_FALLBACK',
    "the visible compatibility route cannot be isolated from true producer-gated Headless");
requireText('policy = tostring(policy) .. " | headless fallback local skip"',
    "the compatibility callback is left waiting on its native animation");
requireText('or state.OpenEggGateRoute == HEADLESS_INVENTORY_FALLBACK)',
    "headless fallback does not snapshot the game skip callback before purchase");
requireText('if not headless or pending.ProducerGateRoute == HEADLESS_INVENTORY_FALLBACK then',
    "headless fallback never arms the local animation skip");
requireText('mouse and touch and buttonX',
    "Wave-hidden Open Eggs skip callbacks are not recognized from their native input constants");
requireText('pending.EventSkipQueued = true',
    "the exact hatch event does not kick the native skip listener immediately");
requireText('sendNativeSkipOnce(',
    "native animation skip is not deduplicated per purchase");
requireText('local exactMatch = pending and not pending.EventReceived',
    "a duplicate/manual event can still replace an owned pending payload");
requireText('pending.ProducerGateRoute == HEADLESS_EVENT_GATE',
    "acknowledgement ownership is not scoped to the direct producer gate");
requireText('pcall(context.GetFireRemote, "Opening Egg")',
    "Opening Egg acknowledgement does not use the read-only hashed RemoteEvent resolver");
requireText('server openegggg event (no named Network.Fire fallback)',
    "a confirmed server hatch still fails when the optional Opening Egg ACK route is absent");
requireText('allCandidateUidsAbsent(context, candidates)',
    "Auto Delete rejection is not idempotent after a native/manual delete race");

if (source.includes('local gateFallback =')) {
    throw new Error("broad owned-gate event matching can still steal a manual hatch");
}
if (source.includes('string.find(route, "remoteevent", 1, true)')) {
    throw new Error("command-specific Library.Network.Fired signals are still rejected by their route label");
}
if (source.includes('pcall(context.FireCommand, "Opening Egg"')) {
    throw new Error("Opening Egg still falls back through the executor-incompatible named Network.Fire route");
}

const beginRequest = source.indexOf("local function beginRequest");
const producerPreflight = source.indexOf("ensureHeadlessProducerGate(state, context)", beginRequest);
const invoke = source.indexOf('"Buy Egg Yay", pending.Egg, pending.Triple, pending.Octuple', beginRequest);
if (beginRequest < 0 || producerPreflight < beginRequest || invoke < 0 || producerPreflight > invoke) {
    throw new Error("headless producer gate is not installed before Buy Egg Yay");
}

for (const forbidden of ["hookmetamethod("]) {
    if (source.includes(forbidden)) {
        throw new Error(`headless producer gate must not install global ${forbidden}`);
    }
}

console.log("Auto egg headless producer gate OK | native gate preferred | inventory-delta compatibility fallback bounded");
