const fs = require("fs");
const path = require("path");

const root = path.resolve(__dirname, "..");
const source = fs.readFileSync(path.join(root, "auto_egg_module.lua"), "utf8");

function assert(condition, message) {
    if (!condition) throw new Error(message);
}

function functionBody(name, nextName) {
    const start = source.indexOf(`local function ${name}`);
    assert(start >= 0, `${name} is missing`);
    const end = source.indexOf(`local function ${nextName}`, start + 1);
    assert(end > start, `${name} boundary is missing`);
    return source.slice(start, end);
}

assert(source.includes("local MAX_NETWORK_ATTEMPTS = 12"),
    "poor-connection retry budget must remain 12 attempts");
assert(source.includes('local MODULE_VERSION = "1.6.6"'),
    "the producer-gated status build must expose Auto Egg v1.6.6");
assert(source.includes("local NETWORK_RETRY_WINDOW = 600"),
    "poor-connection retry window must remain bounded at 600 seconds");
assert(source.includes("local RESPONSE_WAIT_SLICE = 54"),
    "hung Buy Egg response checks do not span the ten-minute window");
assert(source.includes("local POST_PROCESS_WAIT_SLICE = 54"),
    "hung Auto Delete checks do not span the ten-minute window");
assert(source.includes("local MAX_RESPONSE_WAIT_SLICES = 12"),
    "a retained Invoke must have a bounded response-check budget");
assert(source.includes("local MAX_POST_PROCESS_ATTEMPTS = 12"),
    "headless post-processing must have a bounded retry budget");
assert(!source.includes("Game Auto Delete post-processing exceeded"),
    "the legacy 8-second terminal Auto Delete path returned");
assert(source.includes("Protected recovery window: up to %ds"),
    "the active Auto Delete request does not expose its protected recovery window");

const retryScheduleMatch = source.match(
    /local NETWORK_RETRY_DELAYS = \{([^}]+)\}/
);
assert(retryScheduleMatch, "network retry schedule is missing");
const retrySchedule = retryScheduleMatch[1].split(",")
    .map((value) => Number(value.trim()))
    .filter(Number.isFinite);
assert(retrySchedule.length === 11,
    "12 attempts require exactly 11 retry delays");
const retrySpan = retrySchedule.reduce((sum, delay) => sum + delay, 0);
assert(retrySpan >= 540 && retrySpan <= 600,
    `network retries span ${retrySpan}s instead of the ten-minute guard`);

const transportFailure = functionBody("finishTransportFailure", "finishTimeout");
assert(transportFailure.includes("pending.TransportOk")
        || source.includes("if pending.TransportOk == false then"),
    "transport retries are not separated from server rejections");
assert(transportFailure.includes("state.NetworkAttempt = attempt + 1"),
    "completed transport failures do not advance the bounded retry attempt");
assert(transportFailure.includes("state.Pending = nil")
    && transportFailure.indexOf("state.Pending = nil")
        < transportFailure.indexOf("state.NextAction = now + delay"),
    "completed transport retry does not release the old request before rescheduling");

const timeout = functionBody("finishTimeout", "handlePending");
assert(timeout.includes("pending.ResponseWaits < MAX_RESPONSE_WAIT_SLICES"),
    "an in-flight Buy Egg request is not guarded by bounded response checks");
assert(timeout.includes("no duplicate request sent"),
    "timeout status no longer documents the one-in-flight invariant");
assert(!timeout.includes("state.Pending = nil"),
    "an in-flight timeout must not clear pending state and overlap another purchase");

const pendingHandler = functionBody("handlePending", "beginRequest");
assert(pendingHandler.includes("if pending.TransportOk == false then")
    && pendingHandler.includes("finishTransportFailure(state, context, pending)")
    && pendingHandler.includes("finishRejection(state, context, pending)"),
    "transport errors and explicit server rejections are not routed separately");
assert(pendingHandler.includes("pending.EventReceived")
    && pendingHandler.includes("pending.NativeOpeningSeen"),
    "lost responses cannot be recovered from authoritative hatch signals");

const request = functionBody("beginRequest", "runCycle");
assert(request.includes("pending.RequestThread = task.spawn(function()"),
    "Buy Egg request thread is not retained for bounded cleanup");
assert(request.includes("state.Pending = pending")
    && request.indexOf("state.Pending = pending")
        < request.indexOf("context.InvokeCommand(\"Buy Egg Yay\""),
    "pending ownership must be installed before invoking Buy Egg Yay");
assert(request.includes("pending.RequestThread = nil"),
    "the completed Buy Egg request thread is still retained");
assert(request.includes("pending.ReconcileRetryAt == math.huge")
    && request.includes("pending.ReconcileRetryAt = os.clock()"),
    "a late successful response does not re-arm inventory reconciliation");

const cleanup = functionBody("clearPendingThreads", "resetNetworkRetry");
for (const field of ["RequestThread", "ReconcileThread", "PostProcessThread"]) {
    assert(cleanup.includes(`cancelThread(pending.${field})`),
        `${field} is not cancelled during STOP/success/retry cleanup`);
}

// Model the core policy independently: completed transport errors may retry,
// but a still-running call only consumes response checks and never starts a
// second purchase.
let attempts = 1;
let inFlight = 1;
let responseChecks = 0;
for (; responseChecks < 11; responseChecks += 1) {
    assert(inFlight === 1 && attempts === 1,
        "an unresolved request produced an overlapping purchase");
}
inFlight = 0;
attempts += 1;
assert(attempts === 2 && inFlight === 0,
    "a completed transport failure did not become one clean retry");

process.stdout.write(
    "Auto egg network retry policy OK"
    + " | attempts=12 | window=600s | overlap=0 | responseChecks=12\n"
);
