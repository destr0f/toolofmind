-- Runtime profiler and reproducible baseline recorder for PSX OG Nova.
-- This module observes existing work. It never changes automation flags,
-- request intervals, route selection or graphics settings.

local MODULE_VERSION = "1.0.0"
local activeProfiler

local SAMPLE_CAPACITY = 1024
local RATE_CAPACITY = 600
local FRAME_CAPACITY = 3600
local MEMORY_CAPACITY = 600
local TICK_INTERVAL = 0.25

local SCENARIO_ORDER = {
    "Loaded / Functions Off",
    "Farm",
    "Farm + Loot",
    "Farm + Eggs",
    "Farm + Eggs + Machines",
    "Full Profile",
    "Full + Potato",
    "Full + Multiplayer",
}

local SCENARIOS = {
    ["Loaded / Functions Off"] = {
        Exact = {
            Farm = false, Loot = false, Eggs = false, Machines = false,
            Boosts = false, Rewards = false, Potato = false,
        },
    },
    ["Farm"] = {
        Exact = {
            Farm = true, Loot = false, Eggs = false, Machines = false,
            Boosts = false, Rewards = false, Potato = false,
        },
    },
    ["Farm + Loot"] = {
        Exact = {
            Farm = true, Loot = true, Eggs = false, Machines = false,
            Boosts = false, Rewards = false, Potato = false,
        },
    },
    ["Farm + Eggs"] = {
        Exact = {
            Farm = true, Loot = false, Eggs = true, Machines = false,
            Boosts = false, Rewards = false, Potato = false,
        },
    },
    ["Farm + Eggs + Machines"] = {
        Exact = {
            Farm = true, Loot = false, Eggs = true, Machines = true,
            Boosts = false, Rewards = false, Potato = false,
        },
    },
    ["Full Profile"] = {
        Exact = {
            Farm = true, Loot = true, Eggs = true, Machines = true,
            Boosts = true, Rewards = true, Potato = false,
        },
    },
    ["Full + Potato"] = {
        Exact = {
            Farm = true, Loot = true, Eggs = true, Machines = true,
            Boosts = true, Rewards = true, Potato = true,
        },
    },
    ["Full + Multiplayer"] = {
        Exact = {
            Farm = true, Loot = true, Eggs = true, Machines = true,
            Boosts = true, Rewards = true, Potato = false,
        },
        MinimumPlayers = 2,
    },
}

local function newRing(capacity)
    return {
        Values = {},
        Capacity = capacity,
        Count = 0,
        Next = 1,
    }
end

local function ringPush(ring, value)
    if value == nil or value ~= value or value == math.huge or value == -math.huge then return end
    if ring.Count < ring.Capacity then
        ring.Count = ring.Count + 1
        ring.Values[ring.Count] = value
        return
    end
    ring.Values[ring.Next] = value
    ring.Next = ring.Next % ring.Capacity + 1
end

local function ringValues(ring)
    local values = {}
    for index = 1, ring.Count do values[index] = ring.Values[index] end
    return values
end

local function percentileFromSorted(values, percentile)
    local count = #values
    if count == 0 then return 0 end
    local index = math.clamp(math.ceil(count * percentile), 1, count)
    return values[index]
end

local function summarizeRing(ring)
    local values = ringValues(ring)
    table.sort(values)
    local total = 0
    for _, value in ipairs(values) do total = total + value end
    return {
        Samples = #values,
        Average = #values > 0 and total / #values or 0,
        P50 = percentileFromSorted(values, 0.50),
        P95 = percentileFromSorted(values, 0.95),
        Max = #values > 0 and values[#values] or 0,
    }
end

local function safeGcInfo()
    if type(gcinfo) ~= "function" then return nil end
    local ok, value = pcall(gcinfo)
    return ok and tonumber(value) or nil
end

local function cleanName(value)
    value = tostring(value or "unknown")
    value = string.gsub(value, "[^%w%._%-]+", "_")
    return string.sub(value, 1, 80)
end

local function copySerializable(value, depth, seen)
    depth = depth or 0
    seen = seen or {}
    local valueType = typeof(value)
    if valueType == "nil" or valueType == "boolean"
        or valueType == "number" or valueType == "string" then
        return value
    end
    if valueType ~= "table" or depth >= 8 or seen[value] then
        return tostring(value)
    end
    seen[value] = true
    local result = {}
    for key, item in pairs(value) do
        local keyType = type(key)
        local cleanKey = (keyType == "string" or keyType == "number")
            and key or tostring(key)
        result[cleanKey] = copySerializable(item, depth + 1, seen)
    end
    seen[value] = nil
    return result
end

local function validateScenario(name, snapshot)
    local definition = SCENARIOS[name] or SCENARIOS["Loaded / Functions Off"]
    snapshot = type(snapshot) == "table" and snapshot or {}
    local problems = {}
    for key, expected in pairs(definition.Exact or {}) do
        local actual = snapshot[key] == true
        if actual ~= expected then
            problems[#problems + 1] = key .. "=" .. tostring(actual)
                .. " (expected " .. tostring(expected) .. ")"
        end
    end
    local players = tonumber(snapshot.Players) or 0
    if definition.MinimumPlayers and players < definition.MinimumPlayers then
        problems[#problems + 1] = "Players=" .. tostring(players)
            .. " (expected >= " .. tostring(definition.MinimumPlayers) .. ")"
    end
    return #problems == 0, problems
end

local function create(context)
    if activeProfiler and type(activeProfiler.Destroy) == "function" then
        pcall(activeProfiler.Destroy)
    end
    if type(context) ~= "table" then return nil, "profiler context is missing" end
    for _, key in ipairs({
        "RunService", "Players", "Player", "HttpService", "Running", "Trace",
        "Version", "ManifestFingerprint", "GetConfigSnapshot", "GetEnvironment",
    }) do
        if context[key] == nil then return nil, "profiler context is missing " .. key end
    end
    local scheduler = context.Task or task
    if type(scheduler) ~= "table" or type(scheduler.spawn) ~= "function"
        or type(scheduler.delay) ~= "function" or type(scheduler.wait) ~= "function" then
        return nil, "profiler scheduler is unavailable"
    end

    local state = {
        Running = true,
        Active = false,
        Context = context,
        CaptureId = 0,
        Scenario = "Loaded / Functions Off",
        Duration = 60,
        StartedAt = 0,
        StopsAt = 0,
        Modules = {},
        FrameTimes = newRing(FRAME_CAPACITY),
        Memory = newRing(MEMORY_CAPACITY),
        LatestFrameMs = 0,
        WindowStartedAt = os.clock(),
        ObserverOverheadSeconds = 0,
        LastTickAt = 0,
        Connections = {},
        UI = {},
        LastReport = nil,
        LastExport = "No baseline captured yet.",
        PreloadState = "Runtime modules have not been preloaded by the profiler.",
    }

    local api = {}

    local function moduleRecord(moduleName)
        moduleName = tostring(moduleName or "unknown")
        local record = state.Modules[moduleName]
        if not record then
            record = {
                Name = moduleName,
                Series = {},
                Counters = {},
                Gauges = {},
            }
            state.Modules[moduleName] = record
        end
        return record
    end

    local function seriesRecord(moduleName, operation)
        local module = moduleRecord(moduleName)
        operation = tostring(operation or "cycle")
        local series = module.Series[operation]
        if not series then
            series = {
                Name = operation,
                Calls = 0,
                TotalMs = 0,
                LifetimeMaxMs = 0,
                WindowCalls = 0,
                Durations = newRing(SAMPLE_CAPACITY),
                Rates = newRing(RATE_CAPACITY),
            }
            module.Series[operation] = series
        end
        return series
    end

    local function counterRecord(moduleName, metric)
        local module = moduleRecord(moduleName)
        metric = tostring(metric or "events")
        local counter = module.Counters[metric]
        if not counter then
            counter = {
                Name = metric,
                Total = 0,
                Window = 0,
                Rates = newRing(RATE_CAPACITY),
            }
            module.Counters[metric] = counter
        end
        return counter
    end

    local function gaugeRecord(moduleName, metric)
        local module = moduleRecord(moduleName)
        metric = tostring(metric or "gauge")
        local gauge = module.Gauges[metric]
        if not gauge then
            gauge = {
                Name = metric,
                Current = 0,
                LifetimeMax = 0,
                Samples = newRing(RATE_CAPACITY),
            }
            module.Gauges[metric] = gauge
        end
        return gauge
    end

    local function resetMetrics()
        state.Modules = {}
        state.FrameTimes = newRing(FRAME_CAPACITY)
        state.Memory = newRing(MEMORY_CAPACITY)
        state.ObserverOverheadSeconds = 0
        state.WindowStartedAt = os.clock()
    end

    local function count(moduleName, metric, amount)
        local overheadAt = os.clock()
        if state.Active then
            local counter = counterRecord(moduleName, metric)
            amount = tonumber(amount) or 1
            counter.Total = counter.Total + amount
            counter.Window = counter.Window + amount
        end
        state.ObserverOverheadSeconds = state.ObserverOverheadSeconds
            + math.max(os.clock() - overheadAt, 0)
    end

    local function gauge(moduleName, metric, value)
        local overheadAt = os.clock()
        if state.Active then
            local record = gaugeRecord(moduleName, metric)
            value = tonumber(value) or 0
            record.Current = value
            record.LifetimeMax = math.max(record.LifetimeMax, value)
        end
        state.ObserverOverheadSeconds = state.ObserverOverheadSeconds
            + math.max(os.clock() - overheadAt, 0)
    end

    local function finish(moduleName, operation, startedAt)
        if startedAt == nil then return 0 end
        local elapsedMs = math.max(os.clock() - (tonumber(startedAt) or os.clock()), 0) * 1000
        local overheadAt = os.clock()
        if state.Active then
            local series = seriesRecord(moduleName, operation)
            series.Calls = series.Calls + 1
            series.WindowCalls = series.WindowCalls + 1
            series.TotalMs = series.TotalMs + elapsedMs
            series.LifetimeMaxMs = math.max(series.LifetimeMaxMs, elapsedMs)
            ringPush(series.Durations, elapsedMs)
        end
        state.ObserverOverheadSeconds = state.ObserverOverheadSeconds
            + math.max(os.clock() - overheadAt, 0)
        return elapsedMs
    end

    api.Begin = function()
        return state.Active and os.clock() or nil
    end
    api.Finish = finish
    api.Count = count
    api.Gauge = gauge
    api.Scanned = function(moduleName, amount)
        count(moduleName, "scanned_objects", amount)
    end
    api.Temporary = function(moduleName, amount)
        count(moduleName, "temporary_tables_tagged", amount)
    end
    api.InventoryScan = function(moduleName, objects)
        count(moduleName, "inventory_scans", 1)
        if objects ~= nil then count(moduleName, "inventory_objects_scanned", objects) end
    end
    api.UIUpdate = function(moduleName, amount)
        count(moduleName, "ui_updates", amount or 1)
    end
    api.NetworkCall = function(moduleName, kind, amount)
        count(moduleName, "network_calls", amount or 1)
        if kind then count(moduleName, "network_" .. cleanName(kind), amount or 1) end
    end

    local function finalizeWindow(now)
        local elapsed = math.max(now - state.WindowStartedAt, 0.001)
        for _, module in pairs(state.Modules) do
            for _, series in pairs(module.Series) do
                ringPush(series.Rates, series.WindowCalls / elapsed)
                series.WindowCalls = 0
            end
            for _, counter in pairs(module.Counters) do
                ringPush(counter.Rates, counter.Window / elapsed)
                counter.Window = 0
            end
            for _, currentGauge in pairs(module.Gauges) do
                ringPush(currentGauge.Samples, currentGauge.Current)
            end
        end
        local memory = safeGcInfo()
        if memory then ringPush(state.Memory, memory) end
        state.WindowStartedAt = now
    end

    local function operationReport(series)
        local durations = summarizeRing(series.Durations)
        local rates = summarizeRing(series.Rates)
        return {
            Operation = series.Name,
            Calls = series.Calls,
            CallsPerSecond = rates,
            TotalMs = series.TotalMs,
            AverageMs = series.Calls > 0 and series.TotalMs / series.Calls or 0,
            P50Ms = durations.P50,
            P95Ms = durations.P95,
            MaxMs = math.max(durations.Max, series.LifetimeMaxMs),
            DurationSamples = durations.Samples,
        }
    end

    local function counterReport(counter)
        local rates = summarizeRing(counter.Rates)
        return {
            Metric = counter.Name,
            Total = counter.Total,
            PerSecond = rates,
        }
    end

    local function gaugeReport(currentGauge)
        local samples = summarizeRing(currentGauge.Samples)
        return {
            Metric = currentGauge.Name,
            Current = currentGauge.Current,
            P50 = samples.P50,
            P95 = samples.P95,
            Max = math.max(samples.Max, currentGauge.LifetimeMax),
            Samples = samples.Samples,
        }
    end

    local function buildReport(reason)
        local now = os.clock()
        finalizeWindow(now)
        local modules = {}
        for _, module in pairs(state.Modules) do
            local operations, counters, gauges = {}, {}, {}
            local totalMs, calls = 0, 0
            for _, series in pairs(module.Series) do
                local report = operationReport(series)
                operations[#operations + 1] = report
                totalMs = totalMs + report.TotalMs
                calls = calls + report.Calls
            end
            for _, counter in pairs(module.Counters) do
                counters[#counters + 1] = counterReport(counter)
            end
            for _, currentGauge in pairs(module.Gauges) do
                gauges[#gauges + 1] = gaugeReport(currentGauge)
            end
            table.sort(operations, function(left, right) return left.TotalMs > right.TotalMs end)
            table.sort(counters, function(left, right) return left.Metric < right.Metric end)
            table.sort(gauges, function(left, right) return left.Metric < right.Metric end)
            modules[#modules + 1] = {
                Module = module.Name,
                Calls = calls,
                TotalMs = totalMs,
                Operations = operations,
                Counters = counters,
                Gauges = gauges,
            }
        end
        table.sort(modules, function(left, right)
            if left.TotalMs == right.TotalMs then return left.Module < right.Module end
            return left.TotalMs > right.TotalMs
        end)

        local frame = summarizeRing(state.FrameTimes)
        local memory = summarizeRing(state.Memory)
        local configEnd = context.GetConfigSnapshot()
        local conformsEnd, endProblems = validateScenario(state.Scenario, configEnd)
        local elapsed = math.max(now - state.StartedAt, 0)
        return {
            SchemaVersion = 1,
            ProfilerVersion = MODULE_VERSION,
            SuiteVersion = context.Version,
            ManifestFingerprint = context.ManifestFingerprint,
            PreloadState = state.PreloadState,
            Scenario = state.Scenario,
            CaptureId = state.CaptureId,
            Reason = tostring(reason or "manual"),
            RequestedDurationSeconds = state.Duration,
            ActualDurationSeconds = elapsed,
            StartedUnix = state.StartedUnix,
            FinishedUnix = os.time(),
            Configuration = {
                Start = state.ConfigStart,
                Finish = configEnd,
                ConformsAtStart = state.ConformsAtStart,
                ConformsAtFinish = conformsEnd,
                StartProblems = state.StartProblems,
                FinishProblems = endProblems,
            },
            Environment = {
                Start = state.EnvironmentStart,
                Finish = context.GetEnvironment(),
            },
            Frames = {
                Samples = frame.Samples,
                AverageMs = frame.Average,
                P50Ms = frame.P50,
                P95Ms = frame.P95,
                MaxMs = frame.Max,
                AverageFPS = frame.Average > 0 and 1000 / frame.Average or 0,
                P50FPS = frame.P50 > 0 and 1000 / frame.P50 or 0,
                P95FrameFPS = frame.P95 > 0 and 1000 / frame.P95 or 0,
            },
            LuaMemoryKB = memory,
            Observer = {
                MeasuredOverheadMs = state.ObserverOverheadSeconds * 1000,
                OverheadPerSecondMs = elapsed > 0
                    and state.ObserverOverheadSeconds * 1000 / elapsed or 0,
                TemporaryTableCoverage =
                    "Only explicitly tagged hot-path temporary tables; global VM table allocations are unavailable in Luau.",
                ObjectScanCoverage =
                    "Explicitly instrumented repository scans; engine-internal Roblox scans are not observable.",
            },
            Modules = modules,
        }
    end

    local function storeReport(report)
        state.LastReport = report
        local env = type(context.ReportEnvironment) == "table"
            and context.ReportEnvironment
            or (type(getgenv) == "function" and getgenv() or _G)
        local storedInEnvironment = pcall(function()
            env.PSX_OG_PROFILER_LAST_REPORT = report
            env.PSX_OG_PROFILER_REPORTS = type(env.PSX_OG_PROFILER_REPORTS) == "table"
                and env.PSX_OG_PROFILER_REPORTS or {}
            local reports = env.PSX_OG_PROFILER_REPORTS
            reports[#reports + 1] = report
            while #reports > 8 do table.remove(reports, 1) end
        end)

        local jsonOk, json = pcall(context.HttpService.JSONEncode, context.HttpService,
            copySerializable(report))
        if not jsonOk then
            state.LastExport = "Report stored in getgenv; JSONEncode failed: " .. tostring(json)
            return nil, state.LastExport
        end

        local writer = type(writefile) == "function" and writefile or nil
        if not writer then
            state.LastExport = storedInEnvironment
                and "Report stored in getgenv().PSX_OG_PROFILER_LAST_REPORT; writefile unavailable."
                or "Report retained in profiler memory; environment storage and writefile are unavailable."
            return nil, state.LastExport
        end
        local folder = "PSX_OG_Profiles"
        if type(makefolder) == "function" then
            pcall(makefolder, folder)
        end
        local filename = folder .. "/baseline_" .. cleanName(report.Scenario)
            .. "_" .. tostring(report.FinishedUnix) .. ".json"
        local written, problem = pcall(writer, filename, json)
        if written then
            state.LastExport = "Saved " .. filename
            return filename, nil
        end
        state.LastExport = "Report stored in getgenv; writefile failed: " .. tostring(problem)
        return nil, state.LastExport
    end

    function api.StopCapture(reason)
        if not state.Active then return state.LastReport, "no active capture" end
        state.Active = false
        local report = buildReport(reason or "manual")
        storeReport(report)
        context.Trace("profiler baseline",
            tostring(report.Scenario)
            .. " | duration=" .. string.format("%.1fs", report.ActualDurationSeconds)
            .. " | frames p50/p95/max="
            .. string.format("%.2f/%.2f/%.2fms",
                report.Frames.P50Ms, report.Frames.P95Ms, report.Frames.MaxMs)
            .. " | modules=" .. tostring(#report.Modules)
            .. " | " .. tostring(state.LastExport))
        return report
    end

    function api.StartCapture(scenario, duration)
        if state.Active then api.StopCapture("restarted") end
        scenario = SCENARIOS[scenario] and scenario or "Loaded / Functions Off"
        duration = math.clamp(tonumber(duration) or 60, 15, 600)
        resetMetrics()
        state.CaptureId = state.CaptureId + 1
        state.Scenario = scenario
        state.Duration = duration
        state.StartedAt = os.clock()
        state.StopsAt = state.StartedAt + duration
        state.StartedUnix = os.time()
        state.ConfigStart = copySerializable(context.GetConfigSnapshot())
        state.EnvironmentStart = copySerializable(context.GetEnvironment())
        for _, moduleName in ipairs(context.KnownModules or {}) do
            moduleRecord(moduleName)
        end
        for moduleName in pairs(
            type(state.EnvironmentStart.ModuleVersions) == "table"
                and state.EnvironmentStart.ModuleVersions or {}
        ) do
            moduleRecord(moduleName)
        end
        state.ConformsAtStart, state.StartProblems =
            validateScenario(scenario, state.ConfigStart)
        state.Active = true
        local captureId = state.CaptureId
        context.Trace("profiler baseline",
            "started " .. scenario .. " for " .. tostring(duration)
            .. "s | conforms=" .. tostring(state.ConformsAtStart)
            .. (#state.StartProblems > 0
                and (" | " .. table.concat(state.StartProblems, "; ")) or ""))
        scheduler.delay(duration, function()
            if state.Running and state.Active and state.CaptureId == captureId then
                api.StopCapture("duration complete")
            end
        end)
        return true, state.ConformsAtStart, state.StartProblems
    end

    function api.ImportDuration(moduleName, operation, seconds)
        if not state.Active then return end
        local startedAt = os.clock() - math.max(tonumber(seconds) or 0, 0)
        finish(moduleName, operation, startedAt)
    end

    function api.IsActive()
        return state.Active
    end

    function api.GetScenarioOrder()
        return SCENARIO_ORDER
    end

    local function topModules(limit)
        local list = {}
        for _, module in pairs(state.Modules) do
            local totalMs, calls = 0, 0
            for _, series in pairs(module.Series) do
                totalMs = totalMs + series.TotalMs
                calls = calls + series.Calls
            end
            if totalMs > 0 or calls > 0 then
                list[#list + 1] = { Name = module.Name, TotalMs = totalMs, Calls = calls }
            end
        end
        table.sort(list, function(left, right) return left.TotalMs > right.TotalMs end)
        local lines = {}
        for index = 1, math.min(#list, limit or 5) do
            local item = list[index]
            local elapsed = math.max(os.clock() - state.StartedAt, 0.001)
            lines[#lines + 1] = string.format(
                "%s: %.1fms total | %.1f calls/s",
                item.Name, item.TotalMs, item.Calls / elapsed)
        end
        return #lines > 0 and table.concat(lines, "\n") or "No timed module calls in this capture yet."
    end

    local function aggregateMetric(metric)
        local total, current, maximum = 0, 0, 0
        for _, module in pairs(state.Modules) do
            local counter = module.Counters[metric]
            if counter then
                total = total + counter.Total
                local rates = summarizeRing(counter.Rates)
                current = current + (counter.Window or 0)
                maximum = math.max(maximum, rates.Max)
            end
        end
        local elapsed = math.max(os.clock() - state.StartedAt, 0.001)
        return total, total / elapsed, maximum, current
    end

    local function aggregateGauge(metric)
        local current, maximum = 0, 0
        for _, module in pairs(state.Modules) do
            local record = module.Gauges[metric]
            if record then
                current = current + record.Current
                maximum = maximum + record.LifetimeMax
            end
        end
        return current, maximum
    end

    function api.LiveText()
        local frame = summarizeRing(state.FrameTimes)
        local scanned, scannedRate = aggregateMetric("scanned_objects")
        local temporary, temporaryRate = aggregateMetric("temporary_tables_tagged")
        local inventory, inventoryRate = aggregateMetric("inventory_scans")
        local uiUpdates, uiRate = aggregateMetric("ui_updates")
        local network, networkRate = aggregateMetric("network_calls")
        local networkQueued, networkQueueMax = aggregateGauge("network_queue")
        local lootQueued, lootQueueMax = aggregateGauge("loot_queue")
        local inventoryQueued, inventoryQueueMax = aggregateGauge("inventory_queue")
        local capture = state.Active
            and (state.Scenario .. " | " .. tostring(math.max(0,
                math.ceil(state.StopsAt - os.clock()))) .. "s remaining")
            or "Profiler idle; choose a scenario and start a baseline."
        return {
            Capture = capture,
            Frame = string.format(
                "FPS now: %.1f | frame p50/p95/max: %.2f / %.2f / %.2f ms\nSamples: %d | Lua memory: %.0f KB",
                state.LatestFrameMs > 0 and 1000 / state.LatestFrameMs or 0,
                frame.P50, frame.P95, frame.Max, frame.Samples,
                safeGcInfo() or 0
            ),
            Counters = string.format(
                "Scanned: %d (%.1f/s) | tagged temp tables: %d (%.1f/s)\nInventory scans: %d (%.2f/s) | UI updates: %d (%.2f/s)\nNetwork calls: %d (%.2f/s)\nQueues now/max: network %d/%d | loot %d/%d | inventory %d/%d",
                scanned, scannedRate, temporary, temporaryRate,
                inventory, inventoryRate, uiUpdates, uiRate, network, networkRate,
                networkQueued, networkQueueMax, lootQueued, lootQueueMax,
                inventoryQueued, inventoryQueueMax
            ),
            Modules = topModules(6),
            Export = state.LastExport .. "\n" .. state.PreloadState,
        }
    end

    function api.SetPreloadState(text)
        state.PreloadState = tostring(text)
    end

    function api.BuildUI(uiContext)
        if type(uiContext) ~= "table" or not uiContext.Tab then
            return false, "profiler UI context is incomplete"
        end
        local tab = uiContext.Tab
        local controls = {
            Scenario = "Loaded / Functions Off",
            Duration = 60,
        }
        local hero = tab:Section({ Title = "Reproducible Baseline", Box = true, Opened = true })
        hero:Paragraph({
            Title = "MEASURE, DO NOT TUNE",
            Desc = "The profiler preloads code, records the exact configuration and observes existing work. It never toggles automation or changes intervals.",
        })
        hero:Dropdown({
            Flag = "profiler_scenario",
            Title = "Scenario",
            Desc = "A non-conforming configuration is still captured, but the report records every mismatch",
            Values = SCENARIO_ORDER,
            Value = controls.Scenario,
            Multi = false,
            AllowNone = false,
            Callback = function(value) controls.Scenario = tostring(value) end,
        })
        hero:Slider({
            Flag = "profiler_duration",
            Title = "Duration",
            Desc = "Seconds per baseline; 60s is the recommended first pass",
            Step = 15,
            Value = { Min = 15, Max = 600, Default = 60 },
            Callback = function(value) controls.Duration = tonumber(value) or 60 end,
        })

        local captureView = hero:Paragraph({
            Title = "Capture State",
            Desc = "Profiler idle.",
        })
        hero:Button({
            Title = "PRELOAD ALL RUNTIME MODULES",
            Desc = "Downloads, verifies and compiles every manifest module without starting its feature",
            Icon = "download",
            Callback = function()
                scheduler.spawn(function()
                    api.SetPreloadState("Preloading every manifest module in the serial lane...")
                    local ok, summary = pcall(uiContext.PreloadAll)
                    api.SetPreloadState(ok and tostring(summary)
                        or ("Preload failed locally: " .. tostring(summary)))
                end)
            end,
        })
        hero:Button({
            Title = "START BASELINE",
            Desc = "Preloads modules first, then resets counters and starts the selected scenario",
            Icon = "play",
            Callback = function()
                scheduler.spawn(function()
                    api.SetPreloadState("Preloading every manifest module before capture...")
                    local ok, summary = pcall(uiContext.PreloadAll)
                    api.SetPreloadState(ok and tostring(summary)
                        or ("Preload failed locally: " .. tostring(summary)))
                    api.StartCapture(controls.Scenario, controls.Duration)
                end)
            end,
        })
        hero:Button({
            Title = "STOP AND EXPORT",
            Desc = "Finalizes p50/p95/max and stores JSON when writefile is available",
            Icon = "square",
            Callback = function() api.StopCapture("manual stop") end,
        })

        local live = tab:Section({ Title = "Live Measurement", Box = true, Opened = true })
        local frameView = live:Paragraph({ Title = "FPS / Frame Time", Desc = "Waiting for frame samples..." })
        local countersView = live:Paragraph({ Title = "Exact Counters", Desc = "Waiting for a capture..." })
        local modulesView = live:Paragraph({ Title = "Module CPU Time", Desc = "Waiting for timed calls..." })
        local exportView = live:Paragraph({ Title = "Report / Coverage", Desc = state.LastExport })
        live:Paragraph({
            Title = "Temporary Table Boundary",
            Desc = "temporary_tables_tagged counts explicit hot-path allocations in this repository. Luau exposes memory usage, but no exact VM-wide table-allocation hook; reports keep these measurements separate.",
        })

        state.UI = {
            Capture = captureView,
            Frame = frameView,
            Counters = countersView,
            Modules = modulesView,
            Export = exportView,
        }
        scheduler.spawn(function()
            while state.Running and context.Running() do
                local refreshAt = os.clock()
                local text = api.LiveText()
                for key, view in pairs(state.UI) do
                    local value = text[key]
                    if view and value then pcall(function() view:SetDesc(value) end) end
                end
                api.UIUpdate("profiler", 5)
                finish("profiler", "ui_refresh", refreshAt)
                scheduler.wait(1)
            end
        end)
        return true
    end

    function api.Destroy()
        if not state.Running then return end
        if state.Active then pcall(api.StopCapture, "script shutdown") end
        state.Running = false
        for _, connection in ipairs(state.Connections) do
            pcall(function() connection:Disconnect() end)
        end
        table.clear(state.Connections)
        if activeProfiler == api then activeProfiler = nil end
    end

    local frameSignal = context.RunService.RenderStepped or context.RunService.Heartbeat
    state.Connections[#state.Connections + 1] = frameSignal:Connect(function(delta)
        local frameMs = math.max(tonumber(delta) or 0, 0) * 1000
        state.LatestFrameMs = frameMs
        if state.Active then ringPush(state.FrameTimes, frameMs) end
    end)

    scheduler.spawn(function()
        while state.Running and context.Running() do
            local tickAt = os.clock()
            if state.Active and tickAt - state.WindowStartedAt >= 1 then
                finalizeWindow(tickAt)
            end
            state.LastTickAt = tickAt
            scheduler.wait(TICK_INTERVAL)
        end
        api.Destroy()
    end)

    activeProfiler = api
    context.Trace("profiler module",
        "v" .. MODULE_VERSION
        .. " | exact counters + sampled p50/p95/max + reproducible scenario reports")
    return api
end

return function(action, context)
    if action == "version" then return MODULE_VERSION end
    if action == "create" then return create(context) end
    if action == "stop" then
        if activeProfiler then activeProfiler.Destroy() end
        return true
    end
    return false, "unknown profiler action"
end
