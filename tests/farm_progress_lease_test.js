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
assert(send.includes('state.Phase = "working"'),
    "a successful named target/farm signal pair must commit the local lock");
assert(send.includes('fireFast("Change Pet Target", petId, "Coin", coinId)'));
assert(send.includes('fireFast("Farm Coin", coinId, petId)'));

const confirm = body(
    "function petFarm:ConfirmStateProgress",
    "function petFarm:ObserveCoinHealth"
);
assert(confirm.includes('state.Phase = "working"'));
assert(confirm.includes("state.ProgressConfirmed = true"));
assert(confirm.includes('self.ProgressAckMode = "available"'));
assert(!confirm.includes("self.ProgressLeases[petId] = nil"),
    "an optional acknowledgement must not disable the same-target watchdog");

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
assert(lease.includes("now >= (tonumber(state.ProgressDeadline) or now)"));
assert(lease.includes("self:SendCommittedFarmSignals(petId, state)"));
assert(lease.includes("self.ProgressLeaseRepairs = self.ProgressLeaseRepairs + 1"));
assert(lease.includes("petStates[petId] = nil"),
    "a genuinely removed coin must still free its pet");
assert(lease.includes("self.FastPets[petId] = true"));
assert(lease.includes("self:QueueFastDispatch()"));
assert(lease.includes('local maxRepairs = config.Mode == "Boss Chest Only" and 3 or 2'),
    "progress watchdog lost its bounded regular/boss repair policy");
assert(lease.includes("rejectedUntil[coinId] = now + 0.75 + stagger"),
    "an exhausted stale target is not cooled down before rerouting");
assert(lease.includes("self.ProgressLeaseEvictions = self.ProgressLeaseEvictions + 1"));
assert(lease.includes("self.FastReroutes = self.FastReroutes + released"));
assert(!lease.includes('self.ProgressAckMode = "fail-open"'),
    "a successful local Fire must not become permanent fake progress");
for (const forbidden of ["Get Coins", "refreshWorkspaceCoins", "getgc", "getconnections", "Update Coin Pets"]) {
    assert(!lease.includes(forbidden), `progress watchdog became a scan/hook path: ${forbidden}`);
}

const accepted = body("OnAccepted = function", "OnSignalsSent = function");
assert(accepted.includes('state.Phase = "working"'));
assert(accepted.includes("self.ProgressLeases[petId] = state"));
assert(accepted.includes("self.ProgressProbeAccepted = self.ProgressProbeAccepted + 1"));
assert(accepted.includes("self:ProgressLeaseSeconds()"));
assert(accepted.includes("self:ScheduleProgressLease(0.5)"));
assert(!accepted.includes("self.SignalCommits[petId] = state")
    && !accepted.includes("self:ScheduleSignalCommit("),
    "accepted assignments must not duplicate the signal pair already sent by the engine");

const membership = body(
    "function petFarm:ConfirmCoinPets",
    "local function resetSupportCoordinator"
);
assert(membership.includes('self:ConfirmStateProgress(state, "membership", now)'));
assert(membership.includes("local firstMembership = state.MembershipConfirmed ~= true"));
assert(membership.includes("self.MembershipConfirms = self.MembershipConfirms + 1"));
assert(!membership.includes("self.SignalCommits[tostring(petId)] = state")
    && !membership.includes("self:ScheduleSignalCommit("),
    "membership acknowledgement must not resend a committed signal pair");

assert((source.match(/ProgressLeaseToken = petFarm\.ProgressLeaseToken \+ 1/g) || []).length >= 3,
    "reload/reset cleanup does not invalidate every progress watchdog scheduler");
assert((source.match(/table\.clear\(petFarm\.ProgressLeases\)/g) || []).length >= 3,
    "reload/reset cleanup retains progress watchdog state");

console.log("farm_progress_lease_test: ok");
