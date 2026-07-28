const fs = require("fs");
const path = require("path");

const root = path.join(__dirname, "..");
const source = fs.readFileSync(path.join(root, "slim_farm.lua"), "utf8");
const probe = fs.readFileSync(path.join(root, "lowonline_coin_probe.lua"), "utf8");

function check(condition, message) {
    if (!condition) throw new Error(`LowOnline adapter test failed: ${message}`);
}

check(
    source.includes('workspace:FindFirstChild("__ITEMS")')
        && source.includes('workspace:FindFirstChild("__THINGS")'),
    "the runtime must prefer the new __ITEMS root and retain __THINGS fallback"
);
check(
    source.includes('local folder = things and things:FindFirstChild("Coins") or nil'),
    "the workspace coin index must use the inlined register-safe root adapter"
);
check(
    !source.includes("local function getThingsRoot")
        && !source.includes("local function getCoinsFolder")
        && !source.includes("local function classifyCoin"),
    "the adapter must not spend additional top-level Luau registers"
);
check(
    source.includes('local WorldOrder = { "Spawn World", "Fantasy World" }'),
    "the world selector must stop at the first Fantasy World update"
);
check(
    source.includes('"Desert", "Volcano", "Cave"'),
    "the early progression catalog must end at Volcano/Cave"
);
check(
    source.includes('"Fantasy Shop", "Enchanted Forest", "Portals", "Ancient Island"')
        && source.includes('"Heaven Island", "Heaven\'s Gate"')
        && source.includes('["Fantasy World"] = "Fantasy Coins"'),
    "the first Fantasy World teleporter zones/currency are incomplete"
);
check(
    source.includes('["Enchanted Forest"] = "Spawn"')
        && source.includes('["Ancient Island"] = "Temple"')
        && source.includes('["Heaven Island"] = "Heaven"'),
    "Fantasy display zones must map to the compact live Areas"
);
check(
    source.includes('currentZone = "Player Radius"'),
    "Player Zone must have a bounded fallback when map areas are absent"
);
check(
    source.includes("if knownHealth == nil and not record.FromServer then"),
    "workspace records without replicated health must remain usable while alive"
);
check(
    source.includes("coinSync.SnapshotFailures >= 3")
        && source.includes("coinSync.SnapshotSuspended = true")
        && source.includes("suspended after %d attempts on %d workspace targets"),
    "a nil Get Coins response must settle into bounded workspace fail-open mode"
);
check(
    source.includes("record.MaxHealth = math.max(")
        && source.includes("tonumber(value) or 0"),
    "Update Coin Health must retain the largest observed health for strong-target ordering"
);
check(
    source.includes('Title = "LowOnline | Develop"')
        && source.includes('Folder = "LowOnline_Develop"')
        && source.includes('Config("lowonline-default-v1", false)'),
    "LowOnline must not reuse the PSX UI/profile identity"
);
check(
    source.includes('profile_namespace", "LowOnline/v2"')
        && source.includes('lowonline_autoload", true'),
    "LowOnline profile metadata must remain isolated from the main line"
);
const autoEgg = fs.readFileSync(path.join(root, "auto_egg_module.lua"), "utf8");
check(
    autoEgg.includes('local BUY_COMMAND = "Buy Egg"')
        && !autoEgg.includes('"Buy Egg Yay"'),
    "LowOnline auto egg must use the launch-build Buy Egg command"
);
check(
    !autoEgg.includes("EGG_INTERACT_DISTANCE")
        && !autoEgg.includes("maximum 15")
        && !autoEgg.includes("within 15 studs"),
    "LowOnline auto egg must not reject a loaded egg because of client distance"
);
check(
    autoEgg.includes("distance is informational")
        && autoEgg.includes("no client distance limit"),
    "LowOnline auto egg status must clearly expose the range-free policy"
);
check(
    autoEgg.includes('PaceMode = options.PaceMode == "Manual Delay"')
        && autoEgg.includes("ManualDelayMs")
        && autoEgg.includes("Adaptive (History)")
        && autoEgg.includes("suppressOpenEggConnections")
        && autoEgg.includes("restoreOpenEggConnections")
        && !autoEgg.includes('network.Fire("Opening Egg"'),
    "LowOnline headless hatch pacing/suppression contract is incomplete"
);

for (const forbidden of [
    "FireServer(",
    "InvokeServer(",
    "Library.Network.Fire(",
    "Library.Network.Invoke(",
    "hookmetamethod(",
    "hookfunction(",
]) {
    check(!probe.includes(forbidden), `read-only probe contains ${forbidden}`);
}
check(
    probe.includes("LOWONLINE_COIN_PROBE")
        && probe.includes("GetAttributes")
        && probe.includes("Library.Directory.Coins"),
    "probe must preserve its full report and inspect attributes/directory metadata"
);

process.stdout.write("LowOnline adapter test passed\n");
