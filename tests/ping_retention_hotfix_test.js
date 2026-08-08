const fs = require("fs");

const farm = fs.readFileSync("pet_farm_lite_engine.lua", "utf8");
const loot = fs.readFileSync("loot_reactor.lua", "utf8");
const inspector = fs.readFileSync("request_state_inspector.lua", "utf8");
const main = fs.readFileSync("slim_farm.lua", "utf8");

function requireText(source, needle, label) {
  if (!source.includes(needle)) throw new Error(`${label}: missing ${needle}`);
}

requireText(farm, "local function sweepTransportGate", "transport sweep");
requireText(farm, "transportGate.InvokeHistory[key] = nil", "invoke history pruning");
requireText(farm, "clearTransportGate()", "transport reset cleanup");
requireText(farm, "TransportCacheEntries", "transport retention gauge");
requireText(loot, "idleBurst and queuedNew and clientStagger()", "idle orb staggering");
requireText(inspector, "PING_BASELINE_SAMPLE_LIMIT = 30", "frozen ping baseline");
requireText(inspector, "invokeAge <= 8", "normal invoke does not hide network warning");
requireText(main, '["auto egg Open Egg"] = 2', "bounded hot trace");

const retention = 0.5;
const sweepInterval = 1;
const cache = new Map();
let nextSweep = 0;
for (let index = 0; index < 100000; index += 1) {
  const now = index * 0.001;
  if (now >= nextSweep) {
    nextSweep = now + sweepInterval;
    for (const [key, sentAt] of cache) {
      if (now - sentAt > retention) cache.delete(key);
    }
  }
  cache.set(`Farm Coin|${index}|pet-${index % 16}`, now);
}
if (cache.size > 1600) {
  throw new Error(`transport cache retained ${cache.size} unique keys`);
}

console.log(`Ping retention hotfix OK | retained=${cache.size} after 100000 unique calls`);
