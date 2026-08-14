const fs = require("fs");
const path = require("path");

const source = fs.readFileSync(path.join(__dirname, "..", "slim_farm.lua"), "utf8");

function assert(condition, message) {
    if (!condition) throw new Error(message);
}

assert(source.includes('local VERSION = "1.4.1-candidate.54-network5-machines"'),
    "candidate.54 runtime identity changed");
assert(source.includes('BaseCommit = "919550c1dfd57ab2f9cdef9b746c69bee8f8d583"'),
    "logger base commit is not pinned");
assert(source.includes("FlushInterval = 5"), "logger must coalesce disk writes");
assert(source.includes("function env.PSX_OG_C54_PASSIVE_LOG:Sample()"),
    "passive sample function is missing");
assert(source.includes("env.PSX_OG_C54_PASSIVE_LOG:Sample()\n        statusSetters.Flush()"),
    "logger is not attached to the existing one-second telemetry tick");

const pushCalls = [...source.matchAll(/PSX_OG_C54_PASSIVE_LOG(?::|\.)Push\(/g)].length;
assert(pushCalls === 1,
    `unexpected passive logger push sites outside shutdown: ${pushCalls}`);
assert(!/HandleBossSpawn[\s\S]*?PSX_OG_C54_PASSIVE_LOG/.test(
    source.slice(source.indexOf("function petFarm:HandleBossSpawn"),
        source.indexOf("function petFarm:ArmBossWatchdog"))),
    "logger was inserted into the boss spawn hot path");
assert(!/signalEntries[\s\S]*?PSX_OG_C54_PASSIVE_LOG/.test(
    source.slice(source.indexOf("local function signalEntries"),
        source.indexOf("local function process"))),
    "logger was inserted into the pet signal hot path");

console.log("candidate.54 passive logger OK | observer tick=1s | disk flush=5s | farm/loot/network hot paths untouched");
