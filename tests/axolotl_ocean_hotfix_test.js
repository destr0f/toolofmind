const fs = require("fs");
const path = require("path");

const root = path.resolve(__dirname, "..");
const farm = fs.readFileSync(path.join(root, "slim_farm.lua"), "utf8");
const assert = (condition, message) => {
    if (!condition) throw new Error(message);
};

for (const marker of [
    '["Axolotl Ocean"] = {',
    '"Axolotl Ocean", "Axolotl Deep Ocean", "Axolotl Cave"',
    '["giant ocean chest"] = true',
    '["giant ocean chest"] = "Axolotl Cave"',
    '["ocean chest"] = "Axolotl Cave"',
    '["giant underwater chest"] = "Axolotl Cave"',
]) {
    assert(farm.includes(marker), `missing Axolotl Ocean marker: ${marker}`);
}

const workspaceInference = "local inferredArea = BossChestZones[normalize(record.Name)]";
const serverInference = "local inferredArea = BossChestZones[normalizedRecordName]";
assert(farm.includes(workspaceInference) && farm.includes(serverInference),
    "server and Workspace coin paths must both infer the canonical boss zone");
assert(farm.includes("if record.Area == nil then")
    && farm.includes("record.Area = inferredArea")
    && farm.includes("selectionChanged = true"),
    "compact New Coin payloads cannot restore a respawned chest to the target cache");
assert(!farm.includes("AxolotlRespawnPoll") && !farm.includes("while Axolotl"),
    "Axolotl hotfix introduced a polling worker");

process.stdout.write("Axolotl Ocean hotfix OK | Giant Ocean Chest -> Axolotl Cave | event-driven respawn\n");
