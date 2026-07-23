local controller = require("../runtime_kernel_module")

assert(controller("version") == "1.0.0", "RuntimeKernel version mismatch")

local now = 0
local driverCallback
local driverDisconnected = false
local driver = {
    Connect = function(_, callback)
        driverCallback = callback
        return {
            Disconnect = function()
                driverDisconnected = true
                driverCallback = nil
            end,
        }
    end,
}

local spawned = {}
local cancelled = {}
local function spawn(callback)
    local thread = { Callback = callback }
    spawned[#spawned + 1] = thread
    return thread
end

local kernel = assert(controller("create", {
    Driver = driver,
    Clock = function() return now end,
    Spawn = spawn,
    Cancel = function(thread) cancelled[thread] = true end,
    PulseBudget = 1,
}))

local function drainSpawned()
    while #spawned > 0 do
        local pending = spawned
        spawned = {}
        for _, thread in ipairs(pending) do
            if not cancelled[thread] then thread.Callback() end
        end
    end
end

local order = {}
kernel:After("ui", 0, "P4", function() order[#order + 1] = "P4" end)
kernel:After("loot", 0, "P1", function() order[#order + 1] = "P1" end)
kernel:After("pet", 0, "P0", function() order[#order + 1] = "P0" end)
driverCallback()
drainSpawned()
assert(table.concat(order, ",") == "P0,P1,P4", "priority order is incorrect")

local runs = 0
local first, created = kernel:Every("single-worker", 1, "P3", function()
    runs = runs + 1
end, { Immediate = false, Owner = "machines" })
assert(first and created == true, "recurring worker was not registered")
local duplicate, duplicateCreated = kernel:Every("single-worker", 1, "P3", function() end)
assert(duplicate == first and duplicateCreated == false, "duplicate worker was not rejected")

now = 1
driverCallback()
drainSpawned()
assert(runs == 1, "recurring worker did not run")
now = 2
driverCallback()
drainSpawned()
assert(runs == 2, "recurring worker did not reschedule through the heap")

local coalescedRuns = 0
kernel:Emit("coalesced", "P0", function()
    coalescedRuns = coalescedRuns + 1
    kernel:Emit("coalesced", "P0", function() end)
end)
driverCallback()
drainSpawned()
driverCallback()
drainSpawned()
assert(coalescedRuns == 2, "event emitted while running was not replayed once")

local signalCallback
local signalDisconnected = false
local signal = {
    Connect = function(_, callback)
        signalCallback = callback
        return {
            Disconnect = function()
                signalDisconnected = true
                signalCallback = nil
            end,
        }
    end,
}
local signalValue
kernel:Connect("inventory", signal, "P2", function(value)
    signalValue = value
end, { Owner = "eggs" })
signalCallback("delta")
driverCallback()
drainSpawned()
assert(signalValue == "delta", "signal payload was not routed through the scheduler")
kernel:CancelOwner("eggs", "disabled")
assert(signalDisconnected, "owner cancellation did not unregister its signal")

local keyedCallback
local keyedSignal = {
    Connect = function(_, callback)
        keyedCallback = callback
        return { Disconnect = function() keyedCallback = nil end }
    end,
}
local keyedValues, keyedRuns = {}, 0
kernel:Connect("coin-health", keyedSignal, "P0", function(id, value)
    keyedRuns = keyedRuns + 1
    keyedValues[id] = value
end, {
    Owner = "farm",
    KeyBy = function(id) return id end,
})
keyedCallback("coin-a", 1)
keyedCallback("coin-b", 2)
keyedCallback("coin-a", 3)
driverCallback()
drainSpawned()
assert(keyedRuns == 2 and keyedValues["coin-a"] == 3 and keyedValues["coin-b"] == 2,
    "keyed coalescing dropped an object or did not keep its latest payload")

local reusedRuns = 0
kernel:After("reused-key", 10, "P4", function() reusedRuns = reusedRuns + 100 end)
kernel:Unregister("reused-key", "replace test")
kernel:After("reused-key", 0, "P0", function() reusedRuns = reusedRuns + 1 end)
driverCallback()
drainSpawned()
assert(reusedRuns == 1, "a stale heap node captured a re-registered job key")

local token = kernel:CreateToken()
assert(not token:IsCancelled(), "fresh cancellation token is cancelled")
token:Cancel("test")
assert(token:IsCancelled(), "cancellation token did not cancel")

local statsBeforeStop = kernel:Stats()
assert(statsBeforeStop.DuplicateStarts == 1, "duplicate worker metric is incorrect")
assert(statsBeforeStop.Registered >= 1, "kernel unexpectedly lost registered workers")

assert(kernel:Stop("test complete") == true, "kernel did not stop")
assert(driverDisconnected, "kernel driver remained connected")
local statsAfterStop = kernel:Stats()
assert(statsAfterStop.Stopped and statsAfterStop.Registered == 0
    and statsAfterStop.Connections == 0 and statsAfterStop.Pending == 0,
    "kernel stop did not fully clean runtime state")
assert(kernel:Stop("again") == false, "kernel stop is not idempotent")

print("PASS RuntimeKernel priority heap, duplicate guard, cancellation and STOP cleanup")
