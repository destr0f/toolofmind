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

console.log("Pixel Vault minimal refresh OK | old farm retained | current routes resolved locally");
