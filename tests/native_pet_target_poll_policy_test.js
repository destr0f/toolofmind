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
assert(farm.includes("SuppressNativeTargetPoll"));
assert(!farm.includes("SyncNativePetTarget"));
assert(farm.includes("SetFunctionUpvalueAt"));
assert(farm.includes("scriptEnv.NetworkUpdate"));
assert(farm.includes("functionUpvalueAt(callback, 1)"));
assert(farm.includes("functionUpvalueAt(callback, 2)"));
assert(farm.includes("functionUpvalueAt(callback, 3)"));
assert(farm.includes("token.SetFunctionUpvalueAt(callback, 3, math.huge)"));
assert(farm.includes("RestoreNativeTargetPoll"));
assert(!farm.includes("for candidateIndex = 1, 12"));
assert(!farm.includes("math.abs(now - candidate) <= 3"));

const dataStart = farm.indexOf("function token.ConnectPetDataSignal()");
const dataEnd = farm.indexOf("local function bindPetLifecycleSignals", dataStart);
assert(dataStart >= 0 && dataEnd > dataStart);
const dataSignal = farm.slice(dataStart, dataEnd);
assert(dataSignal.includes('local name = "Data Key Updated"'));
assert(dataSignal.includes("token.SchedulePetMembershipReconcile(key)"));

console.log("legacy equipped cache + exact native target poll suppression policy passed");
