const assert = require("assert");
const fs = require("fs");
const path = require("path");

const root = path.resolve(__dirname, "..");
const farm = fs.readFileSync(path.join(root, "slim_farm.lua"), "utf8");
const engine = fs.readFileSync(path.join(root, "pet_farm_lite_engine.lua"), "utf8");

for (const marker of [
    "function petFarm:AdoptNativeBossAssignments",
    "already-working native pet(s); zero farm requests",
    "function petFarm:PrepareNativeBossBatch",
    "paced direct Target/Farm sent for ",
    'targetRemote.FireServer',
    'farmRemote.FireServer',
    'task.wait(0.075)',
    'pcall(self.Engine, "boss-adopt"',
    "DuplicateBossEvents = self.NativeFarm.DuplicateBossEvents + 1",
]) assert(farm.includes(marker), `missing native farm parity marker: ${marker}`);

assert(engine.includes('local MODULE_VERSION = "1.4.9"'));
assert(engine.includes('targetRoute, farmRoute = "native Game.Pets", "native arrival gate"'));
assert(engine.includes('if action == "boss-adopt" then return bossAdopt(context) end'));
assert(engine.includes("run.NativeSignalHandoffs = run.NativeSignalHandoffs + 1"));

const handoff = farm.slice(
    farm.indexOf("function petFarm:PrepareNativeBossBatch"),
    farm.indexOf("function petFarm:AnchorCharacterToBoss")
);
assert(handoff.includes('getFireRemote("Change Pet Target")'));
assert(handoff.includes('getFireRemote("Farm Coin")'));
assert(handoff.indexOf("targetRemote.FireServer") < handoff.indexOf("farmRemote.FireServer"),
    "Target/Farm ordering changed");
assert(!handoff.includes("item.NativeState.arrived == true")
    && !handoff.includes("native arrival timed out"),
    "remote egg farming is still blocked by unreliable local arrival state");
assert(!handoff.includes("ResolveBossPetRuntime")
    && !handoff.includes("ResolveRecordTargetPart"),
    "accepted boss dispatch still scans or mutates the native pet runtime");
assert(handoff.includes("handoffs[petId] = true")
    && handoff.includes("if sentCount == 0 then return nil end"),
    "engine fallback is not retained for failed paced signals");
assert(!handoff.includes("((item.Order - 1) % 16) * 0.015"),
    "slots 17+ are still synchronized with the first 16 pets");
assert(farm.includes("HealthObserveNextAt") && farm.includes("now + 0.25"),
    "high-rate shared chest health progress is not coalesced");

console.log("native_farm_parity_test: ok");
