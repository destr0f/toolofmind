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
    source.includes('local WorldOrder = { "Spawn World" }'),
    "the world selector must be restricted to the launch world"
);
check(
    source.includes('"Desert", "Volcano", "Cave"'),
    "the early progression catalog must end at Volcano/Cave"
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
    source.includes('Title = "LowOnline | Develop"')
        && source.includes('Folder = "LowOnline_Develop"'),
    "LowOnline must not reuse the PSX UI/profile identity"
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
