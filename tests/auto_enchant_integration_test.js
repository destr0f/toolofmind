const fs = require("fs");

const source = fs.readFileSync("slim_farm.lua", "utf8");
const moduleSource = fs.readFileSync("enchant_module.lua", "utf8");
const ui = fs.readFileSync("automation_ui_module.lua", "utf8");

function assert(value, message) {
    if (!value) throw new Error(message);
}

assert(moduleSource.includes('InvokeCommand, "Enchant Pet"'),
    "auto-enchant does not use the stable named Enchant Pet route");
assert(!moduleSource.includes("GetChildren()["),
    "auto-enchant contains a floating ReplicatedStorage child index");
assert(moduleSource.includes("CurrentUID") && moduleSource.includes("CONFIRM_POLL"),
    "auto-enchant does not retain and confirm one pet UID");
assert(moduleSource.includes("SUCCESS_MIN_DELAY") && moduleSource.includes("successfulRollDelay"),
    "auto-enchant does not pace confirmed rolls");
assert(moduleSource.includes("HIGH_PING_MS") && moduleSource.includes("FARM_QUEUE_DELAY"),
    "auto-enchant does not adapt to ping and farm queue pressure");
assert(moduleSource.includes("Library.Save.Get"),
    "auto-enchant does not confirm powers from the exact live save");
assert(ui.includes('Flag = "auto_enchant_targets"') && ui.includes("Multi = true"),
    "multi-enchant UI is missing");
assert(ui.includes('Flag = "auto_enchant_equipped"'),
    "auto-enchant equipped-pet toggle is missing");
assert(source.includes("enchantRuntime:Stop()") && source.includes("config.AutoEnchant = false"),
    "reload/STOP does not cancel auto-enchant");
assert(source.includes("GetNetworkPressure = function()") && source.includes('ServerStatsItem["Data Ping"]'),
    "auto-enchant context does not expose guarded live network pressure");

console.log("PASS auto-enchant named-route, serialization, UI and cleanup integration");
