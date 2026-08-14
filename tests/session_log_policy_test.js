const fs = require("fs");
const path = require("path");

const source = fs.readFileSync(path.resolve(__dirname, "..", "slim_farm.lua"), "utf8");

function requireText(text, message) {
  if (!source.includes(text)) throw new Error(message);
}

requireText('local VERSION = "1.4.1-candidate.57-boss-signal-diet-log"',
  "candidate build must advertise the signal-diet/logger version");
requireText('FlushInterval = 5',
  "session logging must coalesce disk writes over five seconds");
requireText('if #sessionLog.Buffer >= 120 then',
  "session logging must have a hard in-memory retention bound");
requireText('type(appendfile) == "function"',
  "session logging must fail open when appendfile is unavailable");
requireText('sessionLog.Push("sample"',
  "session logging must capture periodic aggregate diagnostics");
requireText('targetSignalsSkipped = tonumber(dispatchStats.TargetSignalsSkipped) or 0',
  "session logging must expose the boss request reduction counter");
requireText('PSX_OG_SESSION_LOG.Push("boss_spawn"',
  "session logging must capture exact boss lifecycle starts");
requireText('PSX_OG_SESSION_LOG.Push("boss_remove"',
  "session logging must capture exact boss lifecycle completion");
requireText('sessionLog.Flush(true)',
  "session logging must flush on startup/shutdown boundaries");

const newCoinStart = source.indexOf('connect("New Coin"');
const newCoinEnd = source.indexOf('connect("Update Coin Health"', newCoinStart);
if (newCoinStart < 0 || newCoinEnd < 0) throw new Error("New Coin callback not found");
const newCoinCallback = source.slice(newCoinStart, newCoinEnd);
if (newCoinCallback.includes("sessionLog.Flush")) {
  throw new Error("boss/coin hot callbacks must never perform disk I/O");
}

console.log("PASS buffered session log policy");
