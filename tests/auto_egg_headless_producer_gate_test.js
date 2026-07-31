const fs = require("fs");
const path = require("path");

const root = path.resolve(__dirname, "..");
const source = fs.readFileSync(path.join(root, "auto_egg_module.lua"), "utf8");

function requireText(fragment, message) {
    if (!source.includes(fragment)) throw new Error(message);
}

requireText('local MODULE_VERSION = "1.5.5"',
    "auto egg module version was not advanced");
requireText('FindFirstChild("Open Eggs")',
    "headless gate does not locate the live Open Eggs LocalScript");
requireText('if type(getsenv) ~= "function" then',
    "getsenv capability is not guarded");
requireText('scriptEnvironment.OpenEgg = wrapper',
    "native OpenEgg producer is not replaced");
requireText('state.Running and state.GateOwned and pending and pending.Headless',
    "producer wrapper is not scoped to an owned headless request");
requireText('return original(eggName, pets)',
    "native animation path is not preserved outside headless requests");
requireText('restoreHeadlessProducerGate(state)',
    "producer wrapper does not have a cleanup path");
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
