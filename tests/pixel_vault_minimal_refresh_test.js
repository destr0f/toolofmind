const assert = require("assert");
const fs = require("fs");
const path = require("path");

const root = path.resolve(__dirname, "..");
const source = fs.readFileSync(path.join(root, "slim_farm.lua"), "utf8");

for (const marker of [
    '["Pixel World"] = { "Pixel Forest", "Pixel Kyoto", "Pixel Alps", "Pixel Vault" }',
    '["Pixel Chest"] = "Pixel Vault"',
    '["Giant Pixel Chest"] = "Pixel Vault"',
    '["pixel chest"] = true',
    '["giant pixel chest"] = "Pixel Vault"',
    'if namesMatch(zone, "Pixel Vault")',
    'and positionInsideNamedArea(record.Position, zone, 42) then',
    '["Change Pet Target"] = { "Change Pet Target NOW", "Change Pet Target" }',
    '["Join Coin"] = { "Join The Coin", "Join Coin" }',
    '["Farm Coin"] = { "Farm The Coin", "Farm Coin" }',
    '["Leave Coin"] = { "Leave The Coin", "Leave Coin" }',
]) {
    assert(source.includes(marker), `minimal Pixel refresh misses ${marker}`);
}

assert(!source.includes("AcceptJoinWithoutSignals"),
    "minimal refresh unexpectedly imported the later Join-only fallback");

const farmContextStart = source.indexOf(
    "local context = {\n        Running = running,\n        Enabled = function() return config.PetFarm end"
);
assert(farmContextStart >= 0, "pet farm Lite context was not found");
const farmContextEnd = source.indexOf("DispatchWidth = 16,", farmContextStart);
assert(farmContextEnd > farmContextStart, "pet farm Lite context end was not found");
const farmContext = source.slice(farmContextStart, farmContextEnd);
for (const forbidden of ["GetCommandBridge", "GetFireBridge"]) {
    assert(!farmContext.includes(forbidden),
        `pet farm must not use Network4 native bridge path: ${forbidden}`);
}
assert(farmContext.includes("NoNamedFallback = true"),
    "pet farm must prefer a bounded transport retry over the blocked named fallback");
assert(farmContext.includes("NetworkReady = networkReady"),
    "pet farm must keep the network readiness probe");

console.log("Pixel Vault minimal refresh OK | old farm retained | current routes resolved locally");
