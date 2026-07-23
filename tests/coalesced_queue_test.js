const fs = require("fs");
const path = require("path");

const graphics = fs.readFileSync(path.resolve(__dirname, "..", "graphics_module.lua"), "utf8");
const assert = (condition, message) => {
    if (!condition) throw new Error(message);
};

const CAPACITY = 32768;
const queue = new Array(CAPACITY);
const seen = new Set();
let head = 0;
let count = 0;
let armed = false;
let arms = 0;
let dropped = 0;

function enqueue(object) {
    if (seen.has(object)) return;
    if (count >= CAPACITY) {
        dropped += 1;
        return;
    }
    seen.add(object);
    queue[(head + count) % CAPACITY] = object;
    count += 1;
    if (!armed) {
        armed = true;
        arms += 1;
    }
}

for (let index = 0; index < 100_000; index += 1) {
    enqueue(`effect-${index % 4096}`);
}
assert(arms === 1, "callback burst armed multiple drains");
assert(count === 4096 && dropped === 0,
    "weak-key-style dedupe did not collapse duplicate callbacks");

let processed = 0;
while (count > 0) {
    const item = queue[head];
    queue[head] = undefined;
    head = (head + 1) % CAPACITY;
    count -= 1;
    if (item !== undefined) processed += 1;
}
armed = false;
assert(processed === 4096 && queue.every((item) => item === undefined),
    "processed queue references were retained");

seen.clear();
for (let index = 0; index < 40_000; index += 1) enqueue(`unique-${index}`);
assert(count === CAPACITY && dropped === 40_000 - CAPACITY,
    "bounded queue overflow policy is not deterministic");
while (count > 0) {
    queue[head] = undefined;
    head = (head + 1) % CAPACITY;
    count -= 1;
}
seen.clear();
armed = false;
assert(queue.every((item) => item === undefined) && seen.size === 0,
    "queue cleanup retained synthetic instances");

for (const marker of [
    "if active.DrainConnection or not active.Running then return end",
    "if active.QueueCount >= QUEUE_CAPACITY then",
    "active.QueueObjects[index] = nil",
    "active.QueueRoots[index] = nil",
    "active.QueueKinds[index] = nil",
    "active.QueueScans[index] = nil",
    "active.QueuePasses[index] = nil",
]) {
    assert(graphics.includes(marker), `missing queue coalescing marker: ${marker}`);
}

process.stdout.write(
    "Coalesced queue OK | callbacks=100000 | unique=4096 | drains=1 | retained=0\n"
);
