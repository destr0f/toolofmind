const fs = require("fs");
const path = require("path");

const root = path.resolve(__dirname, "..");
const farm = fs.readFileSync(path.join(root, "slim_farm.lua"), "utf8");
const loot = fs.readFileSync(path.join(root, "loot_reactor.lua"), "utf8");
const assert = (condition, message) => {
    if (!condition) throw new Error(message);
};
const count = (source, expression) => (source.match(expression) || []).length;

// A world receives no more than three Get Coins attempts. There is no
// reconciliation poll: live named events and one Workspace seed keep serving
// the farm after the bounded snapshot path becomes fail-open.
for (const marker of [
    "MaxSnapshotAttempts = 3",
    "SnapshotBackoff = { 0.15, 0.45, 1.0 }",
    "SnapshotFailOpen = false",
    "EventConfirmed = false",
    "coinSync.SnapshotAttempts = coinSync.SnapshotAttempts + 1",
    'pcall(network.Invoke, "Get Coins")',
    'coinSync.LastProblem = coinSync.LastProblem .. "; event-driven fail-open"',
    "folder.ChildAdded:Connect",
    "folder.ChildRemoved:Connect",
]) {
    assert(farm.includes(marker), `missing bounded catalog marker: ${marker}`);
}
assert(count(farm, /pcall\(network\.Invoke, "Get Coins"\)/g) === 1,
    "Get Coins has more than one invocation site");
assert(farm.includes("coinSync.SnapshotAttempts >= coinSync.MaxSnapshotAttempts")
    && farm.includes("or coinSync.SnapshotFailOpen"),
    "snapshot retry gates are not bounded");

for (const name of ["New Coin", "Update Coin Health", "Remove Coin"]) {
    assert(farm.includes(`connect("${name}"`), `missing named coin delta: ${name}`);
    assert(farm.includes(`coinSync.SignalConnections["${name}"]`),
        `missing connection proof for ${name}`);
}
assert(!farm.includes('connect("Update Coin Pets"'),
    "high-frequency Update Coin Pets returned to the catalog");
assert(farm.includes("local function coinCatalogReady()")
    && farm.includes("coinSync.SignalsReady and coinSync.RecordCount > 0")
    && farm.includes("coinSync.EventConfirmed or coinSync.TargetsValidated"),
    "producer readiness is not tied to a live non-empty catalog");
assert(farm.includes("CoinCatalogReady = coinCatalogReady"),
    "loot reactor does not receive the catalog readiness guard");
assert(farm.includes("CoinRecordReady = function(rawId)")
    && farm.includes('typeof(record.Position) == "Vector3"')
    && farm.includes("RecoverCoinRecord = function(rawId)")
    && farm.includes('folder:FindFirstChild(tostring(rawId))')
    && farm.includes("coinIndex:IndexModel(model, true)"),
    "per-ID readiness/recovery is missing from the farm context");

// Empty/failed/raced responses never replace live state. A world transition
// clears old records and explicitly re-arms the bounded three-attempt probe.
assert(farm.includes('local responseAccepted = ok and type(response) == "table"')
    && farm.includes("and validCount > 0 and coinMutationSerial == serialAtStart"),
    "empty or raced snapshots can overwrite live state");
assert(farm.includes("coinSync.SnapshotPrimed = responseAccepted")
    && farm.includes("if not responseAccepted then"),
    "failed snapshots are incorrectly treated as primed");
assert(farm.includes('resetCoinSnapshot("world changed; awaiting fresh catalog")')
    && farm.includes("scheduleCoinSnapshotRetry(0.15, coinSync.LastProblem)"),
    "world transitions do not reset/re-arm the bounded snapshot path");

// Visual coin calls remain fail-open until the registry is usable; no landing
// tween/CFrame/physics fallback is introduced when producer interception fails.
assert(loot.includes('producerName == "DamageAnimation"')
    && loot.includes('or producerName == "PetDamageAnimation"')
    && loot.includes("data = coinDataFromProducer(record, rawId)")
    && loot.includes("CoinDataTables = readFunctionUpvalueTables(environment.AddCoin)")
    && loot.includes("shouldPrevent = coinCatalogReady() and coinRecordReady(rawId)")
    && loot.includes('if producerName == "AddCoin" then recoverCoinRecord(rawId) end')
    && loot.includes("return original(...)"),
    "coin producer does not separate harmless visual suppression from per-ID fail-open models");
assert(loot.includes("table.clear(record.CoinDataTables or {})"),
    "coin producer upvalue references are retained after cleanup");
assert(!loot.includes("shouldPrevent = coinCatalogReady()\n"),
    "catalog-wide readiness can still suppress an unknown coin ID");
for (const forbidden of [
    "instantLandCoin",
    "object.CFrame",
    "object.Anchored",
    "AssemblyLinearVelocity",
    "AssemblyAngularVelocity",
]) {
    assert(!loot.includes(forbidden), `coin fail-open mutates physics: ${forbidden}`);
}

process.stdout.write(
    "Coin catalog fail-open OK | max attempts=3 | deltas=3"
    + " | per-ID model recovery | no physics fallback\n"
);
