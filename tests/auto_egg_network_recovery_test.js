const fs = require("fs");
const path = require("path");

const root = path.resolve(__dirname, "..");
const source = fs.readFileSync(path.join(root, "auto_egg_module.lua"), "utf8");

function assert(condition, message) {
    if (!condition) throw new Error(`Auto Egg network recovery test failed: ${message}`);
}

assert(source.includes('local MODULE_VERSION = "1.8.0-lowonline"'),
    "the LowOnline Auto Egg version was not bumped");
assert(source.includes('local BUY_COMMAND = "Buy Egg"')
    && !source.includes('"Buy Egg Yay"'),
    "the LowOnline Buy Egg route changed");
assert(source.includes("local MAX_NETWORK_ATTEMPTS = 12")
    && source.includes("local NETWORK_RETRY_WINDOW = 600"),
    "12 attempts / 10 minute recovery contract is absent");
assert(source.includes("local MAX_RESPONSE_WAIT_SLICES = 12")
    && source.includes("local MAX_POST_PROCESS_ATTEMPTS = 12")
    && source.includes("local MAX_POST_PROCESS_WAIT_SLICES = 12"),
    "bounded response and post-process recovery is incomplete");
assert(source.includes("local function finishTransportFailure")
    && source.includes("if pending.TransportOk == false then")
    && source.includes("finishTransportFailure(state, context, pending)"),
    "transport failures are not separated from server rejections");
assert(source.includes("pending.RequestThread = task.spawn(function()")
    && source.includes("pending.ResponseDeadlineAt")
    && source.includes("no duplicate request sent"),
    "one-request-in-flight timeout protection is incomplete");
assert(source.includes("clearPendingThreads(pending)")
    && source.includes("cancelThread(pending.RequestThread)")
    && source.includes("cancelThread(pending.ReconcileThread)")
    && source.includes("cancelThread(pending.PostProcessThread)"),
    "reload/STOP does not clean every Auto Egg worker");
assert(source.includes("Protected recovery window: up to %ds")
    && source.includes("Poor-connection guard: ")
    && source.includes("bounded attempts over "),
    "the active recovery policy is not visible in status");
assert(!source.includes("Game Auto Delete post-processing exceeded "),
    "the old hard 8 second Auto Delete stop is still active");
assert(!source.includes("EGG_INTERACT_DISTANCE")
    && !source.includes("within 15 studs"),
    "the LowOnline no-distance policy regressed");

process.stdout.write(
    "Auto Egg network recovery OK | lowonline Buy Egg | attempts=12 | window=600s"
    + " | no overlap | cache-safe release expected\n"
);
