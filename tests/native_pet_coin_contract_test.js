const fs = require("fs");
const path = require("path");

const root = path.resolve(__dirname, "..");
const source = fs.readFileSync(path.join(root, "loot_reactor.lua"), "utf8");

function assert(condition, message) {
    if (!condition) throw new Error(message);
}

for (const marker of [
    'local MODULE_VERSION = "3.4.3"',
    'local NATIVE_PET_COIN_SHELL_ATTRIBUTE = "PSXHeadlessTargetShell"',
    "local function ensureNativePetCoinTarget(record, rawId)",
    'local target = folder:FindFirstChild("Coin")',
    'local pos = folder:FindFirstChild("POS")',
    "local clone = pos:Clone()",
    'clone.Name = "Coin"',
    "clone.Size = Vector3.new(4, 4, 4)",
    "record.StructuralShells[id] = shell",
    'if producerName == "UpdateCoin" then',
    "structureReady = ensureNativePetCoinTarget(record, rawId)",
    "if not structureReady then shouldPrevent = false end",
    "restoreNativePetCoinTargets(record)",
    "record.StructureConnection = coins.ChildAdded:Connect",
    "record.StructureRemovalConnection = coins.DescendantRemoving:Connect",
    'if child.Name == "Coins" then scheduleProducerRebind("Coins added") end',
    'if child.Name == "Coins" then scheduleProducerRebind("Coins removed") end',
]) {
    assert(source.includes(marker), `missing native pet coin contract marker: ${marker}`);
}

assert(!source.includes('Instance.new("Part")'),
    "the compatibility path allocates a new physics part instead of cloning POS");
assert(!source.includes("clone.Size = Vector3.new(0.05, 0.05, 0.05)"),
    "the compatibility target is too small for Game.Pets arrival math");

console.log("Native pet coin contract OK | invisible POS shell prevents Game.Pets Tick nil Size errors");
