const fs = require("fs");
const path = require("path");

const root = path.resolve(__dirname, "..");
const source = fs.readFileSync(path.join(root, "slim_farm.lua"), "utf8");
const support = fs.readFileSync(path.join(root, "automation_support_module.lua"), "utf8");
const assert = (condition, message) => {
    if (!condition) throw new Error(message);
};

for (const marker of [
    "AutoFreeGifts = false",
    'Command = "Redeem Free Gift"',
    "FreeGiftsTime",
    "FreeGiftsRedeemed",
    "FreeGiftsResetTime",
    'invokeCommand(state.Command, state.Argument)',
    'for _, kind in ipairs({ "VIP", "Rank", "FreeGifts" })',
]) {
    assert(source.includes(marker), `Auto Gifts policy misses ${marker}`);
}

for (const marker of [
    "local DIAMOND_PACK_PRICE = 250e9",
    "local DIAMOND_PACK_RESERVE = 0.5e9",
    "local DIAMOND_PACK_MINIMUM = DIAMOND_PACK_PRICE + DIAMOND_PACK_RESERVE",
    'getCurrentCurrency("Rainbow Coins")',
    "below 250.5B Rainbow Coins",
]) {
    assert(source.includes(marker), `Rainbow pack policy misses ${marker}`);
}

assert(support.includes('invoke("Redeem Free Gift")'),
    "route diagnostics do not resolve Redeem Free Gift");
assert(!/GetChildren\s*\(\s*\)\s*\[\s*18\s*\]/.test(source + support),
    "Auto Gifts relies on the floating ReplicatedStorage child index 18");

const timingStart = source.indexOf("local function getRewardTiming(kind)");
const timingEnd = source.indexOf("local rankTimer = tonumber(save.RankTimer)", timingStart);
assert(timingStart >= 0 && timingEnd > timingStart, "reward timing block missing");
const timing = source.slice(timingStart, timingEnd);
assert(timing.indexOf('if kind == "FreeGifts" then') >= 0
    && timing.indexOf('if kind == "FreeGifts" then') < timing.indexOf("local serverTime, clockProblem = getRewardServerTime()"),
    "Free Gifts are still blocked by server clock/Get OSTime before local timer checks");

for (const marker of [
    "coinSync.NetworkTransport.RouteAliases",
    '"Join The Coin"',
    '"Farm The Coin"',
    '"Leave The Coin"',
    '"Change Pet Target NOW"',
    "CommandRouteCandidates(commandName)",
]) {
    assert(source.includes(marker), `route alias policy misses ${marker}`);
}

process.stdout.write("Auto Gifts + 250B Rainbow pack policy OK\n");
