local delayed
local running = true
task = {
    delay = function(_, callback)
        delayed = callback
    end,
    spawn = function()
        -- Background/UI loops are intentionally not run in this deterministic unit test.
    end,
    wait = function() end,
}

local profilerModule = require("../profiler_module")

local frameCallback
local frameSignal = {
    Connect = function(_, callback)
        frameCallback = callback
        return {
            Disconnect = function() end,
        }
    end,
}

local traces = {}
local config = {
    Farm = false,
    Loot = false,
    Eggs = false,
    Machines = false,
    Boosts = false,
    Rewards = false,
    Potato = false,
    Players = 1,
}

local profiler, createProblem = profilerModule("create", {
    Task = task,
    ReportEnvironment = {},
    RunService = {
        RenderStepped = frameSignal,
        Heartbeat = frameSignal,
    },
    Players = {},
    Player = {},
    HttpService = {
        JSONEncode = function()
            return "{}"
        end,
    },
    Running = function()
        return running
    end,
    Trace = function(stage, detail)
        traces[#traces + 1] = tostring(stage) .. ":" .. tostring(detail)
    end,
    Version = "test-suite",
    ManifestFingerprint = "test-fingerprint",
    KnownModules = { "testModule", "idleModule" },
    GetConfigSnapshot = function()
        return config
    end,
    GetEnvironment = function()
        return {
            PlayerCount = 1,
            ModuleVersions = {
                testModule = "1.0.0",
                manifestOnlyModule = "2.0.0",
            },
        }
    end,
})
assert(type(profiler) == "table", tostring(createProblem))
assert(profilerModule("version") == "1.0.0")

local scenarios = profiler.GetScenarioOrder()
assert(#scenarios == 8, "the reproducible baseline must expose exactly eight scenarios")
assert(scenarios[1] == "Loaded / Functions Off")
assert(scenarios[8] == "Full + Multiplayer")

local controls = {}
local function newControl(definition)
    controls[#controls + 1] = definition
    return {
        SetDesc = function() end,
    }
end
local sectionMethods = {}
for _, method in ipairs({ "Paragraph", "Dropdown", "Slider", "Button" }) do
    sectionMethods[method] = function(_, definition)
        return newControl(definition)
    end
end
local tab = {
    Section = function(_, definition)
        newControl(definition)
        return setmetatable({}, { __index = sectionMethods })
    end,
}
assert(profiler.BuildUI({
    Tab = tab,
    PreloadAll = function()
        return "preloaded without starting features"
    end,
}) == true)
local scenarioControl
for _, definition in ipairs(controls) do
    if definition.Flag == "profiler_scenario" then scenarioControl = definition end
end
assert(scenarioControl and #scenarioControl.Values == 8,
    "profiler UI did not expose all reproducible scenarios")

local started, conforms, problems =
    profiler.StartCapture("Loaded / Functions Off", 15)
assert(started == true and conforms == true)
assert(type(problems) == "table" and #problems == 0)
assert(type(delayed) == "function", "duration stop callback was not scheduled")

profiler.ImportDuration("testModule", "cycle", 0.010)
profiler.ImportDuration("testModule", "cycle", 0.030)
profiler.Scanned("testModule", 120)
profiler.Temporary("testModule", 7)
profiler.InventoryScan("testModule", 42)
profiler.UIUpdate("testModule", 3)
profiler.NetworkCall("testModule", "invoke_probe", 2)
profiler.Gauge("testModule", "network_queue", 4)
profiler.Gauge("testModule", "network_queue", 1)
profiler.Gauge("testModule", "loot_queue", 9)
profiler.Gauge("testModule", "inventory_queue", 2)

frameCallback(1 / 60)
frameCallback(1 / 30)
frameCallback(1 / 20)

local report, stopProblem = profiler.StopCapture("unit test")
assert(type(report) == "table", tostring(stopProblem))
assert(report.SchemaVersion == 1 and report.ProfilerVersion == "1.0.0")
assert(report.Scenario == "Loaded / Functions Off")
assert(report.Configuration.ConformsAtStart == true)
assert(report.Configuration.ConformsAtFinish == true)
assert(report.Frames.Samples == 3)
assert(math.abs(report.Frames.P50Ms - (1000 / 30)) < 0.01)
assert(math.abs(report.Frames.P95Ms - 50) < 0.01)
assert(math.abs(report.Frames.MaxMs - 50) < 0.01)

local function findModule(name)
    for _, module in ipairs(report.Modules) do
        if module.Module == name then return module end
    end
end

local function findMetric(collection, key, name)
    for _, metric in ipairs(collection) do
        if metric[key] == name then return metric end
    end
end

local measured = assert(findModule("testModule"), "instrumented module is absent")
local idle = assert(findModule("idleModule"), "known idle module is absent")
local manifestOnly = assert(findModule("manifestOnlyModule"),
    "manifest-version module is absent")
assert(idle.TotalMs == 0 and manifestOnly.TotalMs == 0,
    "loaded but idle modules must remain visible with zero time")

local cycle = assert(findMetric(measured.Operations, "Operation", "cycle"))
assert(cycle.Calls == 2)
assert(cycle.P50Ms >= 9 and cycle.P50Ms <= 12)
assert(cycle.P95Ms >= 29 and cycle.MaxMs >= cycle.P95Ms)

local scanned = assert(findMetric(measured.Counters, "Metric", "scanned_objects"))
local temporary = assert(findMetric(measured.Counters, "Metric", "temporary_tables_tagged"))
local inventory = assert(findMetric(measured.Counters, "Metric", "inventory_scans"))
local ui = assert(findMetric(measured.Counters, "Metric", "ui_updates"))
local network = assert(findMetric(measured.Counters, "Metric", "network_calls"))
assert(scanned.Total == 120)
assert(temporary.Total == 7)
assert(inventory.Total == 1)
assert(ui.Total == 3)
assert(network.Total == 2)

local networkQueue = assert(findMetric(measured.Gauges, "Metric", "network_queue"))
local lootQueue = assert(findMetric(measured.Gauges, "Metric", "loot_queue"))
local inventoryQueue = assert(findMetric(measured.Gauges, "Metric", "inventory_queue"))
assert(networkQueue.Current == 1 and networkQueue.Max == 4)
assert(lootQueue.Current == 9 and lootQueue.Max == 9)
assert(inventoryQueue.Current == 2 and inventoryQueue.Max == 2)
assert(report.Observer.TemporaryTableCoverage ~= nil)
assert(#traces >= 2, "capture start/stop trace is missing")

running = false
profiler.Destroy()
print("PASS profiler records reproducible scenarios, module latency, rates, queues and frames")
