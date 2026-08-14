const fs = require("fs");
const path = require("path");

const root = path.resolve(__dirname, "..");
const engine = fs.readFileSync(path.join(root, "pet_farm_lite_engine.lua"), "utf8");
const farm = fs.readFileSync(path.join(root, "slim_farm.lua"), "utf8");

function requirePattern(source, pattern, message) {
  if (!pattern.test(source)) throw new Error(message);
}

requirePattern(
  engine,
  /if job\.BossGeneration ~= nil then[\s\S]{0,700}?BossDispatchPhaseOffset[\s\S]{0,500}?scheduler\.delay\(phase[\s\S]{0,250}?executeJob\(job\)[\s\S]{0,250}?else[\s\S]{0,700}?DispatchSpacing/,
  "boss jobs must use the deterministic client phase while ordinary jobs remain spaced"
);
requirePattern(
  engine,
  /if not contextActive\(job\) then[\s\S]{0,250}?failEntries\(job, job and job\.Entries, "target stale before dispatch"\)/,
  "stale jobs must release caller joining state before dispatch"
);
requirePattern(
  engine,
  /if not contextActive\(job\) then[\s\S]{0,350}?failEntries\(job, entries, "target stale after Join Coin"\)/,
  "targets lost during Join Coin must release caller joining state"
);
requirePattern(
  engine,
  /local bossJoinAuthoritative = job\.BossGeneration ~= nil[\s\S]{0,120}?context\.BossJoinAuthoritative == true/,
  "boss dispatch must explicitly gate the Join-authoritative signal diet"
);
requirePattern(
  engine,
  /if bossJoinAuthoritative then[\s\S]{0,220}?TargetSignalsSkipped[\s\S]{0,280}?else[\s\S]{0,220}?"Change Pet Target"[\s\S]{0,450}?"Farm Coin"/,
  "boss jobs must omit duplicate target replication while ordinary jobs retain it"
);
if (engine.includes("SignalBatchSize") || engine.includes("SignalBatchDelay")
    || engine.includes("scheduler.wait(batchDelay)")) {
  throw new Error("the old micro-batch scheduler must not fragment RemoteEvents across frames");
}
requirePattern(
  farm,
  /BossDispatchPhaseOffset = \(math\.abs\(tonumber\(player\.UserId\) or 0\) % 12\) \* 0\.008[\s\S]{0,120}?BossJoinAuthoritative = true/,
  "farm context must spread clients and enable the captured Join-authoritative boss contract"
);
requirePattern(
  farm,
  /targetSignalsSkipped[\s\S]{0,120}?TargetSignalsSkipped/,
  "telemetry must expose every intentionally suppressed boss target signal"
);
requirePattern(
  farm,
  /ForceNew = forceNew == true,/,
  "only an authoritative boss lifecycle transition may force a reused id"
);
if (farm.includes("ForceNew = forceNew == true or noAssignments")) {
  throw new Error("idle allocator state must not manufacture a duplicate boss generation");
}
requirePattern(
  farm,
  /armFarmRecovery = function\(delaySeconds\)[\s\S]{0,1000}?if config\.Mode ~= "Boss Chest Only" then armFarmRecovery\(1\.05\) end/,
  "boss recovery must stay one-shot while ordinary modes retain their safety loop"
);

console.log("PASS boss dispatch liveness policy");
