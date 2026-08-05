const assert = require("assert");
const fs = require("fs");
const path = require("path");

const root = path.resolve(__dirname, "..");
const source = fs.readFileSync(path.join(root, "slim_farm.lua"), "utf8");
const functionStart = source.indexOf("local function getRewardServerTime()")
const timingStart = source.indexOf("local function getRewardTiming(kind)", functionStart)
assert(functionStart >= 0 && timingStart > functionStart, "reward clock function is missing");

const body = source.slice(functionStart, timingStart);
const nativeClock = body.indexOf("workspace:GetServerTimeNow()")
const namedFallback = body.indexOf('getCommandRemote("Get OSTime")')
assert(nativeClock >= 0, "reward clock does not use Roblox server-synchronised time");
assert(namedFallback > nativeClock, "Get OSTime must remain a fallback after the native clock");
assert(body.includes("clockValue ~= nil and clockValue > 0"), "native clock result is not validated");

console.log("Reward clock hotfix test passed");
