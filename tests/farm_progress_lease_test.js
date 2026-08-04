const assert = require("assert");
const fs = require("fs");
const path = require("path");

const root = path.resolve(__dirname, "..");
const source = fs.readFileSync(path.join(root, "slim_farm.lua"), "utf8");
const body = (startMarker, endMarker) => {
    const start = source.indexOf(startMarker);
    const end = source.indexOf(endMarker, start + startMarker.length);
    assert(start >= 0 && end > start, `missing block ${startMarker}`);
    return source.slice(start, end);
};

const send = body(
    "function petFarm:SendCommittedFarmSignals",
    "function petFarm:ConfirmStateProgress"
);
assert(!send.includes('state.Phase = "working"'),
    "a locally sent FireServer call must not prove that the pet is farming");

const confirm = body(
    "function petFarm:ConfirmStateProgress",
    "function petFarm:ObserveCoinHealth"
);
assert(confirm.includes('state.Phase = "working"'));
assert(confirm.includes("state.ProgressConfirmed = true"));
assert(confirm.includes("self.ProgressLeases[petId] = nil"));

const health = body(
    "function petFarm:ObserveCoinHealth",
    "function petFarm:RunProgressLeases"
);
assert(health.includes('self:ConfirmStateProgress(state, "health", now)'));
assert(source.includes("controller:ObserveCoinHealth(id, previous, value)"));

const lease = body(
    "function petFarm:RunProgressLeases",
    "function petFarm:ScheduleProgressLease"
);
assert(lease.includes("state.ProgressConfirmed == true"));
assert(lease.includes("now >= (tonumber(state.ProgressDeadline) or now)"));
assert(lease.includes("petStates[petId] = nil"));
assert(lease.includes("self.FastPets[petId] = true"));
assert(lease.includes("self:QueueFastDispatch()"));
for (const forbidden of ["Get Coins", "refreshWorkspaceCoins", "getgc", "getconnections", "Update Coin Pets"]) {
    assert(!lease.includes(forbidden), `progress lease became a scan/hook path: ${forbidden}`);
}

const accepted = body("OnAccepted = function", "OnSignalsSent = function");
assert(accepted.includes("self.ProgressLeases[petId] = state"));
assert(accepted.includes("state.ProgressDeadline = state.AcceptedAt + math.clamp"));
assert(accepted.includes("self:ScheduleProgressLease(0.1)"));

const membership = body(
    "function petFarm:ConfirmCoinPets",
    "local function resetSupportCoordinator"
);
assert(membership.includes('self:ConfirmStateProgress(state, "membership", now)'));

assert((source.match(/ProgressLeaseToken = petFarm\.ProgressLeaseToken \+ 1/g) || []).length >= 3,
    "reload/reset cleanup does not invalidate every progress lease scheduler");
assert((source.match(/table\.clear\(petFarm\.ProgressLeases\)/g) || []).length >= 3,
    "reload/reset cleanup retains progress lease state");

console.log("farm_progress_lease_test: ok");
