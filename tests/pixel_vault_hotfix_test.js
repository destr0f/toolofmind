const assert = require("assert");
const fs = require("fs");
const path = require("path");

const root = path.resolve(__dirname, "..");
const source = fs.readFileSync(path.join(root, "slim_farm.lua"), "utf8");
const engine = fs.readFileSync(path.join(root, "pet_farm_lite_engine.lua"), "utf8");

for (const marker of [
    '["Pixel World"] = { "Pixel Forest", "Pixel Kyoto", "Pixel Alps", "Pixel Vault" }',
    '["Pixel Chest"] = "Pixel Vault"',
    '["Giant Pixel Chest"] = "Pixel Vault"',
    '["Pixel Vault Chest"] = "Pixel Vault"',
    '["Giant Pixel Vault Chest"] = "Pixel Vault"',
    '["pixel chest"] = true',
    '["pixel vault chest"] = true',
    '["giant pixel chest"] = true',
    '["giant pixel vault chest"] = true',
    '["pixel vault giant pixel chest"] = true',
    '["pixel chest"] = "Pixel Vault"',
    '["pixel vault chest"] = "Pixel Vault"',
    '["giant pixel chest"] = "Pixel Vault"',
    '["giant pixel vault chest"] = "Pixel Vault"',
    '["pixel vault giant pixel chest"] = "Pixel Vault"',
    'if namesMatch(zone, "Pixel Vault")',
    'and positionInsideNamedArea(record.Position, zone, 42) then',
    'local function allowPixelVaultJoinWithoutSignals(record, targetSent, farmSent)',
    'AcceptJoinWithoutSignals = function(record, targetSent, farmSent)',
    'return true, "Pixel Vault Join Coin fallback"',
]) {
    assert(source.includes(marker), `missing Pixel Vault farm marker: ${marker}`);
}

assert(engine.includes("context.AcceptJoinWithoutSignals"),
    "lite engine must expose the scoped Join Coin fallback hook");
assert(engine.includes("local accepted = targetSent and farmSent"),
    "strict target/farm fire commit must remain the default");
assert(engine.includes("local fallbackAccepted = false"));
assert(engine.includes("and not fallbackAccepted then"),
    "fallback assignments must not be reported as transport failures");
assert(engine.includes('"Join Coin accepted; optional farm fire routes unavailable"'));
assert(engine.includes("acceptedRoute"));

console.log("pixel_vault_hotfix_test: ok");
