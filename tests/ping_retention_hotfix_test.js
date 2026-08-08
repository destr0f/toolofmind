const fs = require("fs");

const farm = fs.readFileSync("pet_farm_lite_engine.lua", "utf8");
const loot = fs.readFileSync("loot_reactor.lua", "utf8");
const inspector = fs.readFileSync("request_state_inspector.lua", "utf8");
const main = fs.readFileSync("slim_farm.lua", "utf8");
const egg = fs.readFileSync("auto_egg_module.lua", "utf8");
const automationUI = fs.readFileSync("automation_ui_module.lua", "utf8");
const goldMachine = fs.readFileSync("gold_machine_module.lua", "utf8");
const rainbowMachine = fs.readFileSync("rainbow_machine_module.lua", "utf8");
const darkMatter = fs.readFileSync("dark_matter_module.lua", "utf8");
const boost = fs.readFileSync("boost_module.lua", "utf8");

function requireText(source, needle, label) {
  if (!source.includes(needle)) throw new Error(`${label}: missing ${needle}`);
}

requireText(farm, "local function sweepTransportGate", "transport sweep");
requireText(farm, "transportGate.InvokeHistory[key] = nil", "invoke history pruning");
requireText(farm, "clearTransportGate()", "transport reset cleanup");
requireText(farm, "TransportCacheEntries", "transport retention gauge");
requireText(loot, "idleBurst and queuedNew and trafficStagger()", "idle orb staggering");
requireText(loot, "local function trafficStagger()", "multi-client traffic staggering");
requireText(loot, "local function lowTrafficActive()", "loot low traffic probe");
requireText(loot, "local function bagLaneLimit()", "adaptive lootbag lanes");
requireText(inspector, "PING_BASELINE_SAMPLE_LIMIT = 20", "lightweight ping baseline");
requireText(inspector, "invokeAge <= 8", "normal invoke does not hide network warning");
requireText(main, '["auto egg Open Egg"] = 2', "bounded hot trace");
requireText(main, "PSX_OG_TRAFFIC_DIET:CanRunMaintenance", "shared maintenance traffic gate");
requireText(main, "Maintenance = {", "fair maintenance token state");
requireText(main, "function env.PSX_OG_TRAFFIC_DIET:MaintenanceKey", "maintenance owner normalization");
requireText(main, "function env.PSX_OG_TRAFFIC_DIET:MarkMaintenanceRun", "maintenance grant marker");
requireText(main, "GrantedUntil = {}", "maintenance slot reservation");
requireText(main, 'return true, "quiet maintenance slot"', "quiet-window maintenance escape hatch");
requireText(main, 'return true, "forced background slot"', "bounded maintenance starvation escape hatch");
requireText(main, 'if tostring(owner) == "AutoEgg" then return true end', "auto egg never waits on maintenance");
requireText(main, "HotCommands = {", "hot request command map");
requireText(main, "function requestDiagnostics.VerboseCommand", "hot request diagnostic gate");
requireText(main, '["Claim Orbs"] = true', "orb fire is a hot request");
requireText(main, '["Collect Lootbag"] = true', "lootbag fire is a hot request");
if (main.includes('beginProfile("TOM:Invoke:" .. tostring(commandName))')
    || main.includes('beginProfile("TOM:Fire:" .. tostring(commandName))')) {
  throw new Error("per-request TOM network profiler marker returned to the hot path");
}
requireText(main, "function requestDiagnostics.UpdateTelemetry(detailMode)", "lazy telemetry detail flag");
requireText(main, "requestDiagnostics.UpdateTelemetry(monitorVisible)", "full telemetry detail is monitor-tab driven");
requireText(main, "requestDiagnostics.LastFullTelemetryAt", "bounded hidden telemetry");
requireText(main, "requestDiagnostics.LastLightTelemetryAt", "hidden telemetry has a cheap light cadence");
requireText(main, "requestDiagnostics.LastLootTrafficAt", "loot traffic stats are sampled instead of swept every UI tick");
requireText(main, "local hiddenFullInterval = trafficSnapshot.Active == true and 180 or 120", "hidden full telemetry is rare and traffic-aware");
requireText(main, "pcall(inspector.State, inspector)", "traffic diet inspector ping fallback");
requireText(main, "FarmStatsAt = 0", "traffic diet caches farm stats");
requireText(main, "local farmStatsTTL = self.State.Active == true and 4.0 or 2.0", "traffic diet does not refresh farm stats every low-traffic probe");
requireText(main, 'return true, "low-impact background slot"', "boosts and rewards cannot starve behind farm/loot telemetry");
requireText(main, 'requestDiagnostics.Gauge("Loot", "lowTraffic"', "loot low traffic telemetry");
requireText(main, 'requestDiagnostics.Gauge("Loot", "bagAckSilenced"', "silent lootbag ack path is visible in diagnostics");
requireText(main, "TrafficSensitivity", "traffic diet persisted config");
requireText(main, "sharedSaveCache", "shared Save.Get cache");
requireText(main, "state.Active == true and 15 or MACHINE_PET_SNAPSHOT_TTL", "traffic-aware machine snapshot TTL");
requireText(egg, "trafficEggDelay", "auto egg traffic pacing");
requireText(automationUI, "Traffic Diet / Multi Client", "traffic diet UI controls");
for (const [name, source] of [
  ["gold", goldMachine],
  ["rainbow", rainbowMachine],
  ["dark matter", darkMatter],
]) {
  requireText(source, "context.CanRunMaintenance", `${name} pre-scan maintenance gate`);
  requireText(source, "skipped this cycle before inventory scan or request", `${name} traffic hold does not scan inventory`);
}
requireText(boost, 'string.find(tostring(owner), "traffic diet", 1, true) and 6 or 0.25',
  "boost traffic hold backs off instead of 0.25s gate polling");

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
