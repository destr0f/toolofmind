const fs = require("fs");
const path = require("path");

const root = path.resolve(__dirname, "..");
const manifest = JSON.parse(fs.readFileSync(path.join(root, "runtime_manifest.json"), "utf8"));

function assert(condition, message) {
    if (!condition) throw new Error(message);
}

function read(file) {
    return fs.readFileSync(path.join(root, file), "utf8");
}

const activeFiles = [
    manifest.suite.sourceEntry,
    ...manifest.moduleOrder.map((key) => manifest.modules[key].path),
];
const uniqueActiveFiles = [...new Set(activeFiles)];

const forbiddenWorkers = [
    { expression: /\btask\s*\.\s*spawn\s*\(/g, label: "task.spawn" },
    { expression: /\btask\s*\.\s*delay\s*\(/g, label: "task.delay" },
    {
        expression: /\bwhile\b[^\n]*\btask\s*\.\s*wait\s*\(/g,
        label: "while task.wait",
    },
];

for (const file of uniqueActiveFiles) {
    const source = read(file);
    for (const rule of forbiddenWorkers) {
        assert(!rule.expression.test(source),
            `${file} bypasses RuntimeKernel with ${rule.label}`);
        rule.expression.lastIndex = 0;
    }
}

const kernelEntry = manifest.modules.runtimeKernel;
assert(kernelEntry, "runtimeKernel is absent from the runtime manifest");
assert(manifest.moduleOrder[0] === "runtimeKernel",
    "runtimeKernel must load before every dependent module");

const kernelSource = read(kernelEntry.path);
for (const priority of ["P0", "P1", "P2", "P3", "P4"]) {
    assert(kernelSource.includes(`${priority} =`),
        `RuntimeKernel does not declare priority ${priority}`);
}
for (const operation of [
    "Register", "Every", "After", "Emit", "Spawn", "Unregister", "GetConnection",
    "CancelOwner", "Connect", "OnStop", "Pulse", "Stats", "Stop",
]) {
    assert(kernelSource.includes(`function kernel:${operation}(`),
        `RuntimeKernel does not expose ${operation}`);
}

const directDriverConnections = uniqueActiveFiles.flatMap((file) => {
    const source = read(file);
    const matches = source.match(/\bdriver\s*:\s*Connect\s*\(/gi) || [];
    return matches.map(() => file);
});
assert(directDriverConnections.length === 1
    && directDriverConnections[0] === kernelEntry.path,
`heartbeat-like driver must have exactly one owner; got ${directDriverConnections.join(", ") || "none"}`);

const migratedModules = [
    "automationUI",
    "petFarmEngine",
    "autoEgg",
    "goldMachine",
    "rainbowMachine",
    "darkMatter",
    "boost",
    "graphics",
];
for (const key of migratedModules) {
    const source = read(manifest.modules[key].path);
    assert(/\bKernel\b/.test(source), `${key} is not wired to RuntimeKernel`);
}

const mainSource = read(manifest.suite.sourceEntry);
for (const priority of ["P0", "P1", "P2", "P3", "P4"]) {
    assert(mainSource.includes(`"${priority}"`),
        `main runtime has no ${priority} registration`);
}
assert(mainSource.includes('RuntimeKernel:Stop("script shutdown")'),
    "STOP does not shut down RuntimeKernel");

process.stdout.write(
    `Runtime scheduler migration OK | active=${uniqueActiveFiles.length}`
    + ` | migrated=${migratedModules.length} | priorities=P0-P4\n`
);
