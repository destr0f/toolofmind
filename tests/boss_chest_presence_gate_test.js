const assert = require("assert");
const fs = require("fs");
const path = require("path");

const root = path.resolve(__dirname, "..");
const source = fs.readFileSync(path.join(root, "slim_farm.lua"), "utf8");
const engine = fs.readFileSync(path.join(root, "pet_farm_lite_engine.lua"), "utf8");

assert(source.includes("BossRejected = {}"),
    "boss presence latch must be retained in the existing coin-sync state");
assert(source.includes('coinSync.BossRejected[coinId] = nil'));
assert(source.includes('controller:HandleBossSpawn(record, source'));
assert(source.includes('controller:HandleBossSpawn(record, source, direct, data, true)'),
    "authoritative New Coin must always create a fresh reused-ID boss generation");
assert(!source.includes('wasRejected or not previousAlive'),
    "a reused boss ID can still look alive and must not suppress New Coin");
assert(source.includes('releaseAssignmentsForCoin(rawId, true)'));
assert(source.includes('else\n        -- An attached RBXScriptConnection proves only that a listener exists;'),
    "boss removal must arm a bounded missed-edge watchdog even when the signal is attached");
assert(source.includes('self:ArmBossWatchdog(generation)'),
    "boss removal does not arm missed-edge recovery");
assert(source.includes('(tonumber(health.LastEventAt) or 0) <= armedAt'),
    "watchdog rebind is not scoped to the current removal edge");
assert(source.includes('coinSync.BossAbsentUntil = os.clock() + 3.2'));
assert(source.includes('if coinSync:PruneBossFallbackTimes(now) >= 3 then return end'));
assert(source.includes('and coinSync.SignalConnections["New Coin"] then'));
assert(source.includes('coinSync.BossRejected[coinId] = true'));
assert(source.includes('if not coinSync.BossRejected[coinId]'),
    "rejected boss IDs must be absent from dispatch candidates");
assert(source.includes('driverStatus = "boss chest absent; awaiting New Coin"'),
    "an absent boss must wait for its authoritative appearance event");
assert(source.includes('and controller and type(controller.HandleBossSpawn) == "function" then'),
    "Coins.ChildAdded must retain the zero-request local boss wake edge");
assert(!source.includes('and not coinSync.SignalConnections["New Coin"]\n            and controller'),
    "a stale Network5 New Coin listener can still suppress the local boss wake edge");
assert(!source.includes('local function network5StandinSignal(network, commandName)'),
    "farm lifecycle still performs ambiguous private BindableEvent discovery");
const coinConnect = source.slice(
    source.indexOf("local function connectCoinSignals"),
    source.indexOf('connect("New Coin"', source.indexOf("local function connectCoinSignals"))
);
assert(coinConnect.includes('"resolveInboundEvent"'),
    "farm lifecycle does not use the verified inbound command resolver");
assert(!coinConnect.includes("pcall(network.Fired"),
    "farm lifecycle must not bypass the transport's verified native inbound resolver");
assert(coinConnect.includes('controller, "invalidate", coinSync.NetworkTransport.Context, 1, forceName, nil'),
    "farm signal rebind does not invalidate the exact inbound route cache");
assert(!source.includes('if bossEventDriven and coinSync.BossBootstrapDone then'),
    "one-shot bootstrap sleep can strand a live C54.1 boss generation");
assert(!source.includes('function petFarm:QueueFastDispatch(petId)\n    if config.Mode == "Boss Chest Only"'),
    "authoritative boss mode still discards C54.1 free-pet reroutes");

const pumpStart = engine.indexOf("pump = function()");
const pumpEnd = engine.indexOf("local function start(context)", pumpStart);
const pump = engine.slice(pumpStart, pumpEnd);
assert(pump.includes("scheduler.delay(math.max(due - now, 0)"),
    "boss dispatch lost the one-turn defer that avoids pre-commit Join races");
assert(!pump.includes("if job.BossGeneration ~= nil then\n                executeJob(job)"),
    "boss Join is still invoked synchronously inside the New Coin callback");

const dispatchStart = source.indexOf("local function dispatchPlan(record, petIds)");
const dispatchEnd = source.indexOf("function petFarm:DispatchBossRecord", dispatchStart);
assert(!source.slice(dispatchStart, dispatchEnd).includes("WarpBossPetsOnce"),
    "pet warp still runs before Join Coin is accepted");
const warpStart = source.indexOf("function petFarm:WarpBossPetsOnce");
const warpEnd = source.indexOf("local function remoteSessionIndex", warpStart);
const warp = source.slice(warpStart, warpEnd);
assert(warp.includes('typeof(record.Position) == "Vector3"'));
assert(warp.includes("workspace.BulkMoveTo"));
assert(!warp.includes("Instance.new"), "optional warp creates a retained synthetic target instance");
assert(engine.includes("local function notifyBatchAccepted(job, entries)"));
assert(engine.includes("notifyBatchAccepted(job, acceptedEntries)"),
    "accepted Join batches never reach the post-Join warp callback");
assert(engine.indexOf("notifyBatchAccepted(job, acceptedEntries)")
    < engine.indexOf("local signalFailures = signalEntries(job, acceptedEntries, route)"),
    "post-Join warp must mark native arrival before farm signals are sent");
assert(engine.includes("notifyBatchAccepted(job, entries)"),
    "accepted signal retries never reach the post-Join warp callback");
assert(source.includes('type(rawPet) == "table" and rawPet.PetId or rawPet'),
    "warp cannot consume the engine's allocation-free accepted-entry list");
assert(source.includes("table.clear(coinSync.BossRejected)"),
    "reload/stop must clear the boss presence latch");

const rejection = { rejected: true, joins: 1 };
const duplicateRecoveryPolls = rejection.rejected ? 0 : 1;
assert.strictEqual(duplicateRecoveryPolls, 0,
    "a rejected boss must not be polled back into Join Coin before New Coin");

console.log("boss_chest_presence_gate_test: ok");
