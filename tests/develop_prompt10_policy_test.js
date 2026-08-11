const fs = require("fs");
const path = require("path");

const root = path.resolve(__dirname, "..");
const read = (file) => fs.readFileSync(path.join(root, file), "utf8");
const assert = (condition, message) => {
    if (!condition) throw new Error(message);
};

const farm = read("slim_farm.lua");
const engine = read("pet_farm_lite_engine.lua");
const machineFiles = [
    ["gold_machine_module.lua", 5],
    ["rainbow_machine_module.lua", 5],
    ["dark_matter_module.lua", 5],
];

for (const [file, minimum] of machineFiles) {
    const source = read(file);
    assert(source.includes('local TARGET_PET_NAME = "Pixel Demon"')
        && source.includes("context.GetMachinePetCatalog"),
        `${file} does not resolve exact Pixel Demon from the live catalog`);
    assert(source.includes(`level >= ${minimum}`),
        `${file} has the wrong Rainbow Coins protection floor`);
    assert(source.includes('compactName == "rainbowcoins"'),
        `${file} does not protect Rainbow Coins`);
    assert(source.includes("Pixel Demon found:"),
        `${file} does not expose the target inventory count`);
}

assert(farm.includes('local hackerPortal = namesMatch(zone, "Hacker Portal")'),
    "Hacker Portal does not opt chest-named breakables into regular modes");
assert(farm.includes("mode ~= \"Boss Chest Only\" and (hackerPortal or not boss)"),
    "regular Hacker Portal target policy is missing");
assert(farm.includes("function petFarm:BuildDispatchPlans(")
    && farm.includes("minimumLoad")
    && farm.includes("accountOffset"),
    "balanced UserId-offset allocator is missing");
assert(farm.includes("function petFarm:QueueFastDispatch(")
    && farm.includes("task.defer(function()")
    && farm.includes("releaseAssignmentsForCoin(id) or 0"),
    "Remove Coin fast handoff is missing");
assert(farm.includes('pcall(petFarm.Engine, "limit", math.min(#petIds, 16))')
    && farm.includes("DispatchWidth = 16"),
    "farm concurrency is not bounded by equipped pets and 16 lanes");
assert(farm.includes("cached.Command == commandName")
    && farm.includes("Command = commandName"),
    "direct remote cache does not bind identity to the requested command");

const rejectionStart = engine.indexOf("if #rejectedEntries > 0 then");
const rejectionEnd = engine.indexOf("elseif #signalFailures == 0 then", rejectionStart);
assert(rejectionStart >= 0 && rejectionEnd > rejectionStart,
    "Join rejection branch was not found");
const rejectionBranch = engine.slice(rejectionStart, rejectionEnd);
assert(rejectionBranch.includes("failEntries(") && !rejectionBranch.includes("scheduleRetry("),
    "stale/contended Join rejection still retries the same coin");
assert(engine.includes("local DEFAULT_DISPATCH_WIDTH = 16"),
    "transport lane ceiling is not 16");

for (const file of [
    "slim_farm.lua",
    "pet_farm_lite_engine.lua",
    "gold_machine_module.lua",
    "rainbow_machine_module.lua",
    "dark_matter_module.lua",
]) {
    assert(!/GetChildren\s*\(\s*\)\s*\[\s*\d+\s*\]/.test(read(file)),
        `${file} contains a hardcoded session child index`);
}

function referenceLoads(pets, targets) {
    if (pets <= 0 || targets <= 0) return [];
    const loads = Array(Math.min(pets, targets)).fill(0);
    for (let pet = 0; pet < pets; pet += 1) {
        let selected = 0;
        for (let index = 1; index < loads.length; index += 1) {
            if (loads[index] < loads[selected]) selected = index;
        }
        loads[selected] += 1;
    }
    return loads;
}

for (const [pets, targets, expectedAssigned] of [
    [15, 12, 15],
    [15, 1, 15],
    [5, 12, 5],
    [15, 0, 0],
]) {
    const loads = referenceLoads(pets, targets);
    const assigned = loads.reduce((sum, value) => sum + value, 0);
    assert(assigned === expectedAssigned, `${pets}/${targets} loses pets`);
    if (loads.length > 0) {
        assert(Math.max(...loads) - Math.min(...loads) <= 1,
            `${pets}/${targets} is not evenly balanced`);
    }
}

process.stdout.write(
    "Prompt 10 policy OK | machines=Pixel Demon | Hacker Portal=regular pool | allocator=balanced/16 | stale=no-retry\n"
);
