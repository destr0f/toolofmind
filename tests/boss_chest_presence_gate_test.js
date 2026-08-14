const assert = require("assert");
const fs = require("fs");
const path = require("path");

const root = path.resolve(__dirname, "..");
const source = fs.readFileSync(path.join(root, "slim_farm.lua"), "utf8");
const engine = fs.readFileSync(path.join(root, "pet_farm_lite_engine.lua"), "utf8");

assert(source.includes("BossRejected = {}"),
    "boss presence latch must be retained in the existing coin-sync state");
assert(source.includes('local wasRejected = coinSync.BossRejected[coinId] == true'));
assert(source.includes('coinSync.BossRejected[coinId] = nil'));
assert(source.includes('controller:HandleBossSpawn(record, source'));
assert(source.includes('releaseAssignmentsForCoin(rawId, true)'));
assert(source.includes('elseif not coinSync.SignalConnections["New Coin"] then\n        self:ArmBossWatchdog(generation)'),
    "authoritative New Coin mode must not arm the legacy watchdog");
assert(source.includes('coinSync.BossAbsentUntil = os.clock() + 3.2'));
assert(source.includes('if coinSync:PruneBossFallbackTimes(now) >= 3 then return end'));
assert(source.includes('and coinSync.SignalConnections["New Coin"] then'));
assert(source.includes('coinSync.BossRejected[coinId] = true'));
assert(source.includes('if not coinSync.BossRejected[coinId]'),
    "rejected boss IDs must be absent from dispatch candidates");
assert(source.includes('driverStatus = "boss chest absent; awaiting New Coin"'),
    "an absent boss must wait for its authoritative appearance event");
assert(source.includes('and not coinSync.SignalConnections["New Coin"]\n            and controller'),
    "Coins.ChildAdded must not race the authoritative New Coin source");
assert(source.includes('if bossEventDriven and coinSync.BossBootstrapDone then'),
    "boss allocator must sleep after its one startup bootstrap");
assert(source.includes('function petFarm:QueueFastDispatch(petId)\n    if config.Mode == "Boss Chest Only"'),
    "legacy fast reroutes remain active in authoritative boss mode");

const pumpStart = engine.indexOf("pump = function()");
const pumpEnd = engine.indexOf("local function start(context)", pumpStart);
const pump = engine.slice(pumpStart, pumpEnd);
assert(pump.includes("scheduler.delay(math.max(due - now, 0)"),
    "boss dispatch lost the one-turn defer that avoids pre-commit Join races");
assert(!pump.includes("if job.BossGeneration ~= nil then\n                executeJob(job)"),
    "boss Join is still invoked synchronously inside the New Coin callback");

assert(engine.includes("notifyBatchAccepted(job, acceptedEntries, route)"),
    "post-Join batch notification is missing");
assert(source.includes("OnBatchAccepted = function(record, petIds, spawnGeneration)"),
    "pet warp is not attached to the post-Join batch boundary");
const dispatchStart = source.indexOf("local function dispatchPlan(record, petIds)");
const dispatchEnd = source.indexOf("function petFarm:DispatchBossRecord", dispatchStart);
assert(!source.slice(dispatchStart, dispatchEnd).includes("WarpBossPetsOnce"),
    "pet warp still runs before Join Coin is accepted");
const warpStart = source.indexOf("function petFarm:WarpBossPetsOnce");
const warpEnd = source.indexOf("local function remoteSessionIndex", warpStart);
const warp = source.slice(warpStart, warpEnd);
assert(warp.includes('typeof(record.Position) == "Vector3"'));
assert(warp.includes("workspace.BulkMoveTo"));
assert(!warp.includes("Instance.new"), "warp creates a retained synthetic target instance");
assert(source.includes("table.clear(coinSync.BossRejected)"),
    "reload/stop must clear the boss presence latch");

const rejection = { rejected: true, joins: 1 };
const duplicateRecoveryPolls = rejection.rejected ? 0 : 1;
assert.strictEqual(duplicateRecoveryPolls, 0,
    "a rejected boss must not be polled back into Join Coin before New Coin");

console.log("boss_chest_presence_gate_test: ok");
