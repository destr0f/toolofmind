const assert = require("assert");
const fs = require("fs");
const path = require("path");

const farm = fs.readFileSync(path.join(__dirname, "..", "slim_farm.lua"), "utf8");

assert(farm.includes("function petFarm:SetNativePetTargetPollSuppressed(enabled)"));
assert(farm.includes("setFunctionUpvalueAt(callback, index, math.huge)")
    || farm.includes("SetFunctionUpvalueAt(callback, index, math.huge)"));
assert(farm.includes("function petFarm:SyncNativePetTarget(record, rawPetIds)"));
assert(farm.includes("pcall(self.SyncNativePetTarget, self, record, petIds)"));

const lifecycleStart = farm.indexOf("local function connectPetLifecycleSignal");
const lifecycleEnd = farm.indexOf("local function bindPetLifecycleSignals", lifecycleStart);
assert(lifecycleStart >= 0 && lifecycleEnd > lifecycleStart);
const lifecycle = farm.slice(lifecycleStart, lifecycleEnd);
assert(!lifecycle.includes("petStates[petId] = nil"),
    "physical pet removal must not invalidate authoritative farm assignments");
assert(lifecycle.includes("token.SchedulePetMembershipReconcile(name)"));
assert(farm.includes('key == "PetsEquipped" or key == "HardcorePetsEquipped"'));

console.log("native pet target poll policy test passed");
