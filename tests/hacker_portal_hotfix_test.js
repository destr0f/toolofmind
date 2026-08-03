const assert = require("assert");
const fs = require("fs");
const path = require("path");

const root = path.resolve(__dirname, "..");
const source = fs.readFileSync(path.join(root, "slim_farm.lua"), "utf8");

assert(source.includes('local VERSION = "1.4.1-dev.31"'));
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
