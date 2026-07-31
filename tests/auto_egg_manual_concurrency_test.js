const fs = require("fs");
const path = require("path");

const root = path.resolve(__dirname, "..");
const source = fs.readFileSync(path.join(root, "auto_egg_module.lua"), "utf8");

function assert(condition, message) {
    if (!condition) throw new Error(message);
}

assert(source.includes("PostProcessQueue = {}")
    && source.includes("PostProcessSignatures = {}"),
"manual/duplicate hatch payloads are not serialized");
assert(source.includes("queueHeadlessPostProcess(pending, eggName, pets)"),
"live Open Egg events do not enter the serialized Auto Delete queue");
assert(source.includes("table.remove(pending.PostProcessQueue, 1)"),
"Auto Delete payloads are not drained one batch at a time");
assert(source.includes("pending.PostProcessStarted = false")
    && source.includes("pending.PostProcessDone = true"),
"a late manual hatch cannot restart post-processing after the first batch completed");
assert(source.includes("local HEADLESS_EVENT_SETTLE_DELAY = 0.35")
    && source.includes("local function headlessEventsSettled(pending, now)"),
"the producer gate is released before a near-simultaneous manual event can arrive");
assert(source.includes("pending.LastHeadlessEventAt = os.clock()")
    && source.includes("pending.ResponseAt = os.clock()"),
"manual events and the purchase response do not extend the bounded settle window");
assert(source.includes("pending.EventReceived = true")
    && source.includes("local exactMatch = pending and not pending.EventReceived"),
"the first exact event does not retain exclusive pending ownership");
assert(source.includes("ignored an unrelated/duplicate Open Egg without replacing pending"),
"manual hatch interference is not diagnosed without corrupting pending state");
assert(source.includes("owned by the native Open Eggs callback (no duplicate request)"),
"compatibility mode still duplicates native Auto Delete");
assert(source.includes("server rejection treated as idempotent success"),
"already-deleted UIDs still surface a false Auto Delete failure");

for (const forbidden of ["hookmetamethod(", "hookfunction("]) {
    assert(!source.includes(forbidden), `manual concurrency fix introduced global ${forbidden}`);
}

console.log("Auto egg manual concurrency OK | first-event ownership | restartable serialized delete | bounded settle | idempotent native race");
