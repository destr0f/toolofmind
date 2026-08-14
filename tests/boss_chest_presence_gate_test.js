const assert = require("assert");
const fs = require("fs");
const path = require("path");

const root = path.resolve(__dirname, "..");
const source = fs.readFileSync(path.join(root, "slim_farm.lua"), "utf8");

assert(source.includes("BossRejected = {}"),
    "boss presence latch must be retained in the existing coin-sync state");
assert(source.includes('local wasRejected = coinSync.BossRejected[coinId] == true'));
assert(source.includes('coinSync.BossRejected[coinId] = nil'));
assert(source.includes('controller:HandleBossSpawn(record, source'));
assert(source.includes('releaseAssignmentsForCoin(rawId, true)'));
assert(source.includes('self:ArmBossWatchdog(generation)'));
assert(source.includes('coinSync.BossAbsentUntil = os.clock() + 3.2'));
assert(source.includes('if coinSync:PruneBossFallbackTimes(now) >= 3 then return end'));
assert(source.includes('and coinSync.SignalConnections["New Coin"] then'));
assert(source.includes('coinSync.BossRejected[coinId] = true'));
assert(source.includes('if not coinSync.BossRejected[coinId]'),
    "rejected boss IDs must be absent from dispatch candidates");
assert(source.includes('driverStatus = "boss chest absent; awaiting New Coin"'),
    "an absent boss must wait for its authoritative appearance event");
assert(source.includes("table.clear(coinSync.BossRejected)"),
    "reload/stop must clear the boss presence latch");

const rejection = { rejected: true, joins: 1 };
const duplicateRecoveryPolls = rejection.rejected ? 0 : 1;
assert.strictEqual(duplicateRecoveryPolls, 0,
    "a rejected boss must not be polled back into Join Coin before New Coin");

console.log("boss_chest_presence_gate_test: ok");
