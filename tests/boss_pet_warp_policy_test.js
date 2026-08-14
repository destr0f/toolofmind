const assert = require("assert");
const fs = require("fs");
const path = require("path");

const root = path.resolve(__dirname, "..");
const source = fs.readFileSync(path.join(root, "slim_farm.lua"), "utf8");

function block(startMarker, endMarker) {
    const start = source.indexOf(startMarker);
    const end = source.indexOf(endMarker, start + startMarker.length);
    assert(start >= 0 && end > start, `missing block ${startMarker}`);
    return source.slice(start, end);
}

assert(source.includes('BossPetInstantArrival = false'),
    "experimental warp must remain disabled by default");
assert(source.includes('Flag = "boss_pet_instant_arrival"'),
    "boss warp toggle is missing");
assert(source.includes('farmController:ResetBossPetWarp("world changed")'),
    "world changes do not invalidate native pet references");
assert(source.includes('petFarm:ResetBossPetWarp("shutdown")'),
    "shutdown does not clear native pet references");

const resolver = block(
    "function petFarm:ResolveBossPetRuntime",
    "function petFarm:WarpBossPetsOnce"
);
assert(resolver.includes('type(getsenv) ~= "function"'),
    "getsenv capability is not guarded");
assert(resolver.includes('scriptEnv[name]'),
    "resolver does not inspect bounded Game.Pets callbacks");
assert(resolver.includes('for upvalueIndex = 1, 16 do'),
    "resolver does not bound upvalue inspection");
for (const forbidden of ["getgc", "getconnections", "getinstances", "getnilinstances"]) {
    assert(!resolver.includes(forbidden), `resolver gained global scan ${forbidden}`);
}

const warp = block(
    "function petFarm:WarpBossPetsOnce",
    "local function remoteSessionIndex"
);
assert(warp.includes('math.min(#petIds, 16)'), "warp is not bounded to the equipped batch");
assert(warp.includes('pcall(workspace.BulkMoveTo, workspace, parts, cframes)'),
    "warp does not use one guarded BulkMoveTo batch");
assert(warp.includes('record.Position'),
    "headless warp still requires the visual chest POS");
assert(warp.includes('anchor.Name = "__PSX_BOSS_WARP_ANCHOR"'),
    "headless warp has no bounded synthetic target anchor");
assert(warp.includes('state.networkTarget = targetAnchor'),
    "native NetworkUpdate can duplicate Change Pet Target after warp");
assert(warp.includes('state.arrived = true'),
    "native arrival state is not synchronized");
for (const forbidden of [
    "Network.Invoke", "Network.Fire", "InvokeServer", "FireServer",
    "Get Coins", "Group Select Coin", "RenderStepped", "Heartbeat", "task.", "while ",
]) {
    assert(!warp.includes(forbidden), `warp gained forbidden work: ${forbidden}`);
}
assert((warp.match(/BulkMoveTo/g) || []).length === 2,
    "warp should contain only the comment/name and one BulkMoveTo call");

const dispatch = block("local function dispatchPlan", "function petFarm:DispatchBossRecord");
assert(!dispatch.includes('WarpBossPetsOnce'),
    "warp still runs before Join Coin acceptance");
const accepted = block("OnAccepted = function", "OnSignalsSent = function");
assert(accepted.includes('pcall(self.WarpBossPetsOnce, self, record, self.LastEquippedIds or { petId })'),
    "accepted Join Coin does not trigger the fail-open local warp");
assert(accepted.indexOf('state.Phase = "working"') < accepted.indexOf("WarpBossPetsOnce"),
    "warp must run only after the UID is committed as working");

const finalize = block("function petFarm:FinalizeBossRemoval", "assignmentCount = function");
assert(finalize.includes('tostring(source) == "server reject"'),
    "server reject is not isolated from fallback polling");
assert(finalize.includes('coinSync.BossRejected[tostring(rawId)] = true'),
    "rejected generation is not quarantined until New Coin");

console.log("boss_pet_warp_policy_test: ok");
