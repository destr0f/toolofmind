const assert = require("assert");
const fs = require("fs");
const path = require("path");

const farm = fs.readFileSync(path.join(__dirname, "..", "slim_farm.lua"), "utf8");

assert(farm.includes("token.ReadAuthoritativeEquippedSet"));
assert(farm.includes("save.PetsEquipped"));
assert(farm.includes("save.HardcorePetsEquipped"));
assert(farm.includes('key == "PetsEquipped" or key == "HardcorePetsEquipped"'));
assert(!farm.includes('connectPetLifecycleSignal("Added Client Pet")'));
assert(!farm.includes('connectPetLifecycleSignal("Removed Client Pet")'));
assert(!farm.includes("SetNativePetTargetPollSuppressed"));
assert(!farm.includes("SyncNativePetTarget"));
assert(!farm.includes("SetFunctionUpvalueAt"));

const dataStart = farm.indexOf("function token.ConnectPetDataSignal()");
const dataEnd = farm.indexOf("local function bindPetLifecycleSignals", dataStart);
assert(dataStart >= 0 && dataEnd > dataStart);
const dataSignal = farm.slice(dataStart, dataEnd);
assert(dataSignal.includes('local name = "Data Key Updated"'));
assert(dataSignal.includes("token.SchedulePetMembershipReconcile(key)"));

console.log("legacy farm equipped cache policy test passed");
