const fs = require("fs");
const path = require("path");

const root = path.resolve(__dirname, "..");
const read = (file) => fs.readFileSync(path.join(root, file), "utf8");
const assert = (condition, message) => {
    if (!condition) throw new Error(message);
};

const farm = read("slim_farm.lua");
const support = read("automation_support_module.lua");
const ui = read("automation_ui_module.lua");
const machines = [
    read("gold_machine_module.lua"),
    read("rainbow_machine_module.lua"),
    read("dark_matter_module.lua"),
];

assert(support.includes('["pixel demon"] = "Pixel Demon"'),
    "shared machine catalog does not select exact Pixel Demon");
for (const [index, machine] of machines.entries()) {
    assert(machine.includes('local TARGET_PET_NAME = "Pixel Demon"')
        && machine.includes("context.GetMachinePetCatalog")
        && !machine.includes("TARGET_PET_ID"),
        `machine ${index + 1} does not enforce the live exact-name catalog`);
}
assert(!ui.includes("Galaxy Fox + Silver Stag + Silver Dragon + Santa Paws"),
    "machine UI still advertises the legacy target catalog");

for (const marker of [
    "local DIAMOND_PACK_PRICE = 250e9",
    "local DIAMOND_PACK_RESERVE = 0.5e9",
    "local DIAMOND_PACK_MINIMUM = DIAMOND_PACK_PRICE + DIAMOND_PACK_RESERVE",
    'getCurrentCurrency("Rainbow Coins")',
    "below 250.5B",
    'Command = "Redeem Free Gift"',
    "FreeGiftsRedeemed",
]) {
    assert(farm.includes(marker), `diamond reserve policy misses ${marker}`);
}

for (const marker of [
    'gui.Name = "PSX_OG_QuickHUD"',
    "function hud:ApplyVisibility()",
    "function hud:Update(",
    "quick_hud_ping",
    "quick_hud_rate",
    "quick_hud_farm",
    "quick_hud_automation",
]) {
    assert(farm.includes(marker), `Quick HUD misses ${marker}`);
}
assert(!farm.includes("task.delay(1, function() quickHUD"),
    "Quick HUD introduced an independent one-second worker");

for (const marker of [
    "env.PSX_OG_RUNTIME_GENERATION",
    "env.PSX_OG_RunToken = nil",
    "env.PSX_OG_SLIM_TOKEN = nil",
    "_G.AutoPetCoins = false",
    '"PSX_OG_RUNTIME_KERNEL"',
    "env.StopPSXPotatoMode",
    "stopLegacyState",
    '"PSX_OG_NativeUI", "PSX_OG_QuickHUD"',
]) {
    assert(farm.includes(marker), `reload quiescence misses ${marker}`);
}

process.stdout.write(
    "Develop Pixel/HUD policy OK | machines=exact-name | pack=250B+0.5B | gifts=timer-gated | HUD=coalesced | reload=quiesced\n"
);
