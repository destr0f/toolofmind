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
    "nativeState.target = target",
    "nativeState.farming = true",
    'farmRemote.FireServer, farmRemote, coinId, item.PetId',
    "item.NativeState.arrived == true",
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
assert(!handoff.includes('getFireRemote("Change Pet Target")'),
    "native handoff duplicates Game.Pets Change Pet Target NOW");
assert(handoff.indexOf("item.NativeState.arrived == true")
    < handoff.indexOf("farmRemote.FireServer"),
    "Farm Coin is no longer gated by native arrival");

console.log("native_farm_parity_test: ok");
