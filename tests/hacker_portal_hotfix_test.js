const assert = require("assert");
const fs = require("fs");
const path = require("path");

const root = path.resolve(__dirname, "..");
const source = fs.readFileSync(path.join(root, "slim_farm.lua"), "utf8");

assert(source.includes('local VERSION = "1.4.1-dev.40"'));
assert(source.includes('["hacker portal chest"] = true'));
assert(source.includes('["giant hacker portal chest"] = "Hacker Portal"'));
assert(source.includes('["Hacker Portals"] = "Hacker Portal"'));
assert(source.includes("local function positionInsideNamedArea(position, zone, horizontalMargin)"));
assert(source.includes("record.DetectedAreaRevision ~= areaRevision"));
assert(source.includes("tostring(areaCatalog.Revision)"));
assert(source.includes('if detected ~= nil and namesMatch(detected, zone) then return true end'));
assert(source.includes('and positionInsideNamedArea(record.Position, zone, 36) then'));
assert(source.includes('if namesMatch(zone, "Hacker Portal") then return nearAnchor end'));
assert(source.includes('return detected == nil and nearAnchor'));
assert(!source.includes('LivenessDeadline'));
assert(!source.includes('NoteCoinProgress'));
assert(!source.includes('no Update Coin Health progress'));
assert(!source.includes('"rearm",'));

const acceptedStart = source.indexOf("OnAccepted = function");
const signalsStart = source.indexOf("OnSignalsSent = function", acceptedStart);
assert(acceptedStart >= 0 && signalsStart > acceptedStart);
assert(source.slice(acceptedStart, signalsStart).includes('state.Phase = "working"'),
    "accepted target/farm signals must commit the lock without an unavailable progress ACK");
assert(!source.slice(acceptedStart, signalsStart).includes("self.SignalCommits[petId] = state")
    && !source.slice(acceptedStart, signalsStart).includes("self:ScheduleSignalCommit("),
    "accepted Join Coin duplicates the signal pair already sent by the engine");
assert(source.includes('connect("Update Coin Pets", function(id, pets)'),
    "the authoritative server membership acknowledgement is not connected");
assert(source.includes("function petFarm:ConfirmCoinPets(rawCoinId, payload)"));
assert(source.includes('fireFast("Change Pet Target", petId, "Coin", coinId)'));
assert(source.includes('fireFast("Farm Coin", coinId, petId)'));
assert(source.includes("attempt == 0 and age >= 0.22"));
assert(source.includes("attempt == 1 and age >= 0.55"));
const commitStart = source.indexOf("function petFarm:RunSignalCommits");
const commitEnd = source.indexOf("function petFarm:ScheduleSignalCommit", commitStart);
assert(commitStart >= 0 && commitEnd > commitStart);
const commitBody = source.slice(commitStart, commitEnd);
assert(!commitBody.includes('"Join Coin"'), "commit worker must never repeat Join Coin");
assert(!commitBody.includes('"Leave Coin"'), "commit worker must never detach a live assignment");
assert(!source.slice(signalsStart, source.indexOf("OnRetry = function", signalsStart))
    .includes('FIRE_LOCAL_SENT_UNACKED'),
    "successful per-pet fire signals must stay on aggregate counters instead of the inspector hot path");

function recordInZoneDecision(zone, detected, nearAnchor) {
    if (detected === zone) return true;
    if (zone === "Hacker Portal") return nearAnchor;
    return detected == null && nearAnchor;
}

assert.strictEqual(recordInZoneDecision("Hacker Portal", "Glitch", true), true);
assert.strictEqual(recordInZoneDecision("Hacker Portal", "Glitch", false), false);
assert.strictEqual(recordInZoneDecision("Hacker Portal", "Hacker Portal", false), true);
assert.strictEqual(recordInZoneDecision("Alien Forest", "Alien Lab", true), false);
assert.strictEqual(recordInZoneDecision("Alien Forest", null, true), true);

console.log("hacker_portal_hotfix_test: ok");
