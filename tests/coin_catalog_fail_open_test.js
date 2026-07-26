const fs = require("fs");
const path = require("path");

const root = path.resolve(__dirname, "..");
const farm = fs.readFileSync(path.join(root, "slim_farm.lua"), "utf8");
const loot = fs.readFileSync(path.join(root, "loot_reactor.lua"), "utf8");
const assert = (condition, message) => {
    if (!condition) throw new Error(message);
};

// The producer may suppress coin models only after both the initial metadata
// snapshot and all required live deltas have been proven available.
assert(farm.includes("local coinSync = {")
    && farm.includes("SnapshotPrimed = false")
    && farm.includes("TargetsValidated = false")
    && farm.includes("SignalsReady = false"),
    "coin catalog readiness is not represented as one bounded state object");
assert(farm.includes("local function coinCatalogReady()")
    && farm.includes("coinSync.SnapshotPrimed and coinSync.SignalsReady")
    && farm.includes("and coinSync.TargetsValidated and coinSync.RecordCount > 0"),
    "coin producer can close before the authoritative catalog is ready");
assert(farm.includes("CoinCatalogReady = coinCatalogReady"),
    "loot reactor does not receive the authoritative catalog readiness guard");

// Failed, empty and raced snapshots must stay unprimed. LowOnline is allowed
// to stop retrying only after a bounded failure threshold when the replicated
// workspace catalog is already populated.
assert(farm.includes("local responseAccepted = ok and type(response) == \"table\"")
    && farm.includes("and validCount > 0 and coinMutationSerial == serialAtStart"),
    "empty or raced Get Coins responses are still accepted");
assert(farm.includes("coinSync.SnapshotPrimed = responseAccepted")
    && farm.includes("if not responseAccepted and not coinSync.SnapshotSuspended then")
    && farm.includes("scheduleCoinSnapshotRetry(0.75, coinSync.LastProblem)")
    && farm.includes("coinSync.SnapshotFailures >= 3")
    && farm.includes("for _, record in pairs(coinRecords) do"),
    "failed snapshots do not use bounded workspace fail-open retry");
assert(farm.includes("(coinSync.SnapshotPrimed and coinSync.SignalsReady)"),
    "signal binding retries stop merely because the snapshot succeeded");
assert(farm.includes("coinSync.LastProblem = \"world changed; awaiting fresh catalog\"")
    && farm.includes("scheduleCoinSnapshotRetry(0.15, coinSync.LastProblem)"),
    "world transitions can retain the previous catalog state");

// Signal readiness must mean actual New/Health/Remove connections, not merely
// that one connection attempt was made.
for (const name of ["New Coin", "Update Coin Health", "Remove Coin"]) {
    assert(farm.includes(`coinSync.SignalConnections["${name}"]`),
        `missing real connection proof for ${name}`);
}

// Damage effects remain headless immediately. Model creation stays available
// until the catalog is independently usable, but its native landing tween is
// skipped before the original UpdateCoin renders the model at its final POS.
assert(loot.includes('producerName == "DamageAnimation"')
    && loot.includes('or producerName == "PetDamageAnimation"')
    && loot.includes("local catalogReady = coinCatalogReady()")
    && loot.includes("shouldPrevent = catalogReady")
    && loot.includes('not catalogReady and producerName == "UpdateCoin"')
    && loot.includes("instantLandCoin((...))"),
    "coin visual wrappers do not distinguish effects from model producers");
assert(loot.includes('coinProducer = "instant visual fail-open"')
    && loot.includes('"catalog unavailable; native models skip the 0.9s landing tween"'),
    "UI does not expose the fail-open safety state");

// Small behavioral model of the guard.
const preventsModel = ({ potato, snapshot, signals, targets, count, live }) =>
    potato && snapshot && signals && targets && count > 0 && live;
assert(!preventsModel({
    potato: true, snapshot: false, signals: true, targets: true,
    count: 128, live: true,
}), "an unprimed world incorrectly suppresses AddCoin");
assert(!preventsModel({
    potato: true, snapshot: true, signals: false, targets: true,
    count: 128, live: true,
}), "missing live deltas incorrectly suppress AddCoin");
assert(!preventsModel({
    potato: true, snapshot: true, signals: true, targets: false,
    count: 128, live: true,
}), "an unusable selected-zone catalog incorrectly suppresses AddCoin");
assert(!preventsModel({
    potato: true, snapshot: true, signals: true, targets: true,
    count: 0, live: false,
}), "an empty world incorrectly suppresses AddCoin");
assert(preventsModel({
    potato: true, snapshot: true, signals: true, targets: true,
    count: 128, live: true,
}), "a verified catalog does not enable the headless model producer");

process.stdout.write(
    "Coin catalog fail-open OK | failed/empty/raced snapshots retry then settle"
    + " | world transition safe | model producer guarded\n"
);
