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
  /if job\.BossGeneration ~= nil then[\s\S]{0,500}?executeJob\(job\)[\s\S]{0,200}?else[\s\S]{0,700}?scheduler\.delay/,
  "boss jobs must execute immediately while ordinary jobs remain spaced"
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
  farm,
  /local noAssignments = [^\n]*assignmentCount\(\) == 0[\s\S]{0,400}?ForceNew = forceNew == true or noAssignments/,
  "an idle farm must accept a reused boss coin id as a new lifecycle"
);
requirePattern(
  farm,
  /armFarmRecovery = function\(delaySeconds\)[\s\S]{0,1000}?armFarmRecovery\(1\.05\)/,
  "underassigned farm recovery must rearm itself"
);

console.log("PASS boss dispatch liveness policy");
