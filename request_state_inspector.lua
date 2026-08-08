-- Passive request-state diagnostics for PSX OG Nova develop.
-- This module never invokes/fires a remote and never changes automation policy.

local MODULE_VERSION = "1.0.2"
local EVENT_CAPACITY = 48
local SNAPSHOT_CAPACITY = 4
local ACTIVE_CAPACITY = 48
local UPDATE_EXPANDED = 2
local UPDATE_MINIMIZED = 8
local PING_BASELINE_SAMPLE_LIMIT = 20
local PING_ABSOLUTE_WARNING = 900
local PING_RELATIVE_MULTIPLIER = 2.5
local HIGH_FREQUENCY_EVENT_INTERVAL = 2.5

local TERMINAL = {
    COALESCED_INTO = true,
    -- RemoteEvent calls have no protocol acknowledgement. Retain their event
    -- in the bounded history, but never keep them in the active registry.
    FIRE_LOCAL_SENT_UNACKED = true,
    SERVER_ACCEPTED = true,
    SERVER_REJECTED = true,
    TRANSPORT_FAILED = true,
    TIMED_OUT_LOCALLY_REMOTE_UNKNOWN = true,
    LOCAL_CANCELLED_REMOTE_UNKNOWN = true,
    COMPLETED = true,
    CANCELLED_BY_DISABLE = true,
    CANCELLED_BY_RELOAD = true,
    DROPPED_WITH_REASON = true,
}

local VALID_STATE = {
    IDLE = true,
    WAITING_READY = true,
    WAITING_GATE = true,
    QUEUED = true,
    COALESCED_INTO = true,
    INVOKE_IN_FLIGHT = true,
    FIRE_LOCAL_SENT_UNACKED = true,
    WAITING_GAME_ACK = true,
    WAITING_INVENTORY_DELTA = true,
    POST_PROCESSING = true,
    SERVER_ACCEPTED = true,
    SERVER_REJECTED = true,
    TRANSPORT_FAILED = true,
    TIMED_OUT_LOCALLY_REMOTE_UNKNOWN = true,
    LOCAL_CANCELLED_REMOTE_UNKNOWN = true,
    COMPLETED = true,
    CANCELLED_BY_DISABLE = true,
    CANCELLED_BY_RELOAD = true,
    DROPPED_WITH_REASON = true,
}

local INCIDENTS = {
    FARM_STUCK_INVOKE = {
        Subsystem = "Farm", Confidence = "high",
        Suggestion = "Observe the oldest Join Coin call and server RTT; do not add a duplicate request.",
    },
    FARM_REQUEST_BACKLOG = {
        Subsystem = "Farm", Confidence = "medium",
        Suggestion = "Compare queued jobs with completions and transport failures.",
    },
    EGG_WAITING_GAME_ACK = {
        Subsystem = "Egg", Confidence = "high",
        Suggestion = "Observe Open Egg and inventory-delta acknowledgement for the existing purchase.",
    },
    EGG_POSTPROCESS_HOLD = {
        Subsystem = "Egg", Confidence = "high",
        Suggestion = "Observe native auto-delete/post-processing; do not overlap another purchase.",
    },
    INVENTORY_GATE_STARVATION = {
        Subsystem = "Gate", Confidence = "medium",
        Suggestion = "Observe the current owner age and waiting workers without forcing release.",
    },
    ORB_FIRE_UNACKNOWLEDGED = {
        Subsystem = "Loot", Confidence = "medium",
        Suggestion = "Observe pending orb IDs and local FireServer throughput; RemoteEvent has no reply.",
    },
    LOOTBAG_RETIRED_WITHOUT_ACK = {
        Subsystem = "Loot", Confidence = "high",
        Suggestion = "Observe Remove Lootbag/folder-removal acknowledgement before changing retention.",
    },
    PRODUCER_COLD = {
        Subsystem = "Loot", Confidence = "medium",
        Suggestion = "Observe producer binding after world/player-script changes.",
    },
    ROUTE_UNRESOLVED = {
        Subsystem = "Routes", Confidence = "high",
        Suggestion = "Refresh only the named local resolver; no diagnostic server request is needed.",
    },
    STARTUP_REQUEST_BURST = {
        Subsystem = "Startup", Confidence = "medium",
        Suggestion = "Observe config auto-start ordering and operation-gate ownership.",
    },
    RELOAD_GHOST_GENERATION = {
        Subsystem = "Reload", Confidence = "high",
        Suggestion = "Observe old-generation operations; their remote outcome is unknown after local reload.",
    },
    CLIENT_SCHEDULER_STALL = {
        Subsystem = "Client", Confidence = "high",
        Suggestion = "Inspect client frame/scheduler pressure before attributing the delay to network.",
    },
    NETWORK_OR_EXECUTOR_UNKNOWN = {
        Subsystem = "Network", Confidence = "low",
        Suggestion = "Correlate ping, invoke age and scheduler delay; the inspector cannot identify the remote cause alone.",
    },
}

local INCIDENT_PRIORITY = {
    "RELOAD_GHOST_GENERATION",
    "CLIENT_SCHEDULER_STALL",
    "FARM_STUCK_INVOKE",
    "INVENTORY_GATE_STARVATION",
    "EGG_POSTPROCESS_HOLD",
    "EGG_WAITING_GAME_ACK",
    "FARM_REQUEST_BACKLOG",
    "LOOTBAG_RETIRED_WITHOUT_ACK",
    "ORB_FIRE_UNACKNOWLEDGED",
    "ROUTE_UNRESOLVED",
    "PRODUCER_COLD",
    "STARTUP_REQUEST_BURST",
    "NETWORK_OR_EXECUTOR_UNKNOWN",
}

local current

local function primitive(value)
    local kind = type(value)
    if kind == "string" then
        return #value > 240 and string.sub(value, 1, 237) .. "..." or value
    end
    if kind == "nil" or kind == "number" or kind == "boolean" then
        return value
    end
    if type(typeof) == "function" and typeof(value) == "Instance" then
        return value.ClassName .. ":" .. value.Name
    end
    return tostring(value)
end

local function detailField(detail, ...)
    if type(detail) ~= "table" then return nil end
    for index = 1, select("#", ...) do
        local value = detail[select(index, ...)]
        if value ~= nil then return primitive(value) end
    end
    return nil
end

local function compactDetail(value)
    if type(value) ~= "table" then
        local result = tostring(primitive(value) or "")
        return #result > 240 and string.sub(result, 1, 237) .. "..." or result
    end
    local parts, count = {}, 0
    for key, item in pairs(value) do
        count = count + 1
        if count > 10 then
            parts[#parts + 1] = "..."
            break
        end
        parts[#parts + 1] = tostring(primitive(key)) .. "=" .. tostring(primitive(item))
    end
    table.sort(parts)
    local result = table.concat(parts, ", ")
    return #result > 240 and string.sub(result, 1, 237) .. "..." or result
end

local function copyPrimitiveMap(source, depth)
    if type(source) ~= "table" then return primitive(source) end
    depth = tonumber(depth) or 0
    if depth >= 3 then return compactDetail(source) end
    local result, count = {}, 0
    for key, value in pairs(source) do
        count = count + 1
        if count > 48 then
            result.__truncated = true
            break
        end
        local safeKey = tostring(primitive(key))
        result[safeKey] = type(value) == "table" and copyPrimitiveMap(value, depth + 1) or primitive(value)
    end
    return result
end

local function safeCall(callback, ...)
    if type(callback) ~= "function" then return false end
    return pcall(callback, ...)
end

local function ringPush(state, listName, cursorName, countName, capacity, item)
    local cursor = state[cursorName]
    state[listName][cursor] = item
    state[cursorName] = cursor % capacity + 1
    state[countName] = math.min(state[countName] + 1, capacity)
end

local function ringValues(state, listName, cursorName, countName, capacity)
    local result, count = {}, state[countName]
    local first = (state[cursorName] - count - 1) % capacity + 1
    for offset = 0, count - 1 do
        local item = state[listName][(first + offset - 1) % capacity + 1]
        if item then result[#result + 1] = item end
    end
    return result
end

local function lane(state, subsystem)
    subsystem = tostring(subsystem or "Background")
    local value = state.Lanes[subsystem]
    if not value then
        value = {
            Active = 0, Total = 0, Completed = 0, Failed = 0,
            LastState = "IDLE", LastDetail = "", LastAt = os.clock(),
        }
        state.Lanes[subsystem] = value
    end
    return value, subsystem
end

local function recordEvent(state, subsystem, requestId, stateName, detailText, operation, now)
    state.Sequence = state.Sequence + 1
    ringPush(state, "Events", "EventCursor", "EventCount", EVENT_CAPACITY, {
        At = now,
        Sequence = state.Sequence,
        Generation = state.Generation,
        Subsystem = subsystem,
        Lane = subsystem,
        Request = requestId,
        OperationId = requestId,
        State = stateName,
        Detail = detailText,
        Command = operation and operation.Command or "unknown",
        RequestType = operation and operation.RequestType or "local",
        CreatedAt = operation and operation.CreatedAt or now,
        QueuedAt = operation and operation.QueuedAt or nil,
        SentAt = operation and operation.SentAt or nil,
        LocalReturnAt = operation and operation.LocalReturnAt or nil,
        AcknowledgedAt = operation and operation.AcknowledgedAt or nil,
        Result = operation and operation.Result or nil,
        WaitReason = operation and operation.WaitReason or nil,
        ParentOperationId = operation and operation.ParentOperationId or nil,
    })
end

local function updateOperationMetadata(operation, stateName, detail, now)
    if not operation then return end
    operation.Command = detailField(detail, "command", "Command") or operation.Command or "unknown"
    operation.RequestType = detailField(detail, "requestType", "RequestType", "type", "Type")
        or operation.RequestType or "local"
    operation.ParentOperationId = detailField(detail, "parentOperationId", "parentId", "ParentOperationId")
        or operation.ParentOperationId
    operation.Result = detailField(detail, "result", "Result", "outcome", "Outcome") or operation.Result
    local reason = detailField(detail, "waitReason", "reason", "Reason")
    if reason ~= nil then operation.WaitReason = reason end
    if stateName == "QUEUED" then operation.QueuedAt = operation.QueuedAt or now end
    if stateName == "INVOKE_IN_FLIGHT" or stateName == "FIRE_LOCAL_SENT_UNACKED" then
        operation.SentAt = operation.SentAt or now
    end
    if stateName == "SERVER_ACCEPTED" or stateName == "SERVER_REJECTED"
        or stateName == "TRANSPORT_FAILED" or stateName == "TIMED_OUT_LOCALLY_REMOTE_UNKNOWN"
        or stateName == "LOCAL_CANCELLED_REMOTE_UNKNOWN" then
        operation.LocalReturnAt = operation.LocalReturnAt or now
    end
    if stateName == "SERVER_ACCEPTED" or stateName == "SERVER_REJECTED" or stateName == "COMPLETED" then
        operation.AcknowledgedAt = operation.AcknowledgedAt or now
    end
end

local function gauge(state, subsystem, key, fallback)
    local group = state.Gauges[tostring(subsystem)]
    local value = group and group[tostring(key)]
    if value == nil then return fallback end
    return value
end

local function setGauge(state, subsystem, key, value)
    if not state.Alive then return false end
    subsystem, key = tostring(subsystem or "Background"), tostring(key or "value")
    local group = state.Gauges[subsystem]
    if not group then group = {}; state.Gauges[subsystem] = group end
    local safe = primitive(value)
    if group[key] == safe then return true end
    group[key] = safe
    return true
end

local function shouldRecordEvent(state, subsystem, stateName, operation, detailText, now)
    if subsystem ~= "Loot" then return true end
    if stateName ~= "WAITING_READY" and stateName ~= "FIRE_LOCAL_SENT_UNACKED" then return true end
    local command = operation and operation.Command or nil
    if command == nil or command == "" or command == "unknown" then
        command = string.match(tostring(detailText or ""), "command=([^,]+)") or "unknown"
    end
    command = tostring(command)
    if command ~= "Claim Orbs" and command ~= "Collect Lootbag" then return true end
    local key = subsystem .. ":" .. stateName .. ":" .. command
    local last = tonumber(state.EventThrottle[key]) or 0
    if now - last < HIGH_FREQUENCY_EVENT_INTERVAL then return false end
    state.EventThrottle[key] = now
    return true
end

local function removeOldestOperation(state, reason)
    local oldestKey, oldestAt
    for key, operation in pairs(state.Operations) do
        if oldestAt == nil or operation.At < oldestAt then
            oldestKey, oldestAt = key, operation.At
        end
    end
    if oldestKey then
        local operation = state.Operations[oldestKey]
        local group = lane(state, operation.Subsystem)
        if operation.State == "INVOKE_IN_FLIGHT" then
            state.ActiveInvokes = math.max(state.ActiveInvokes - 1, 0)
        elseif operation.State == "FIRE_LOCAL_SENT_UNACKED" then
            state.UnackedFires = math.max(state.UnackedFires - 1, 0)
        end
        local now = os.clock()
        operation.State = "DROPPED_WITH_REASON"
        operation.At = now
        operation.Result = "registry eviction"
        operation.WaitReason = tostring(reason or "bounded active registry capacity reached")
        operation.Detail = operation.WaitReason
        group.Total = group.Total + 1
        group.Completed = group.Completed + 1
        group.Failed = group.Failed + 1
        group.LastState = operation.State
        group.LastDetail = operation.Detail
        group.LastAt = now
        state.ExplicitDrops = state.ExplicitDrops + 1
        recordEvent(state, operation.Subsystem, operation.Request, operation.State,
            operation.Detail, operation, now)
        group.Active = math.max(group.Active - 1, 0)
        state.Operations[oldestKey] = nil
        state.OperationCount = math.max(state.OperationCount - 1, 0)
    end
end

local function transition(state, subsystem, requestId, stateName, detail)
    if not state.Alive then return false end
    local group
    group, subsystem = lane(state, subsystem)
    requestId = tostring(requestId or (subsystem .. "-" .. tostring(state.Sequence + 1)))
    stateName = tostring(stateName or "IDLE")
    if not VALID_STATE[stateName] then stateName = "DROPPED_WITH_REASON" end
    local now, key = os.clock(), subsystem .. ":" .. requestId
    local operation = state.Operations[key]
    local previousState = operation and operation.State or nil
    if not operation and not TERMINAL[stateName] then
        while state.OperationCount >= ACTIVE_CAPACITY do
            removeOldestOperation(state, "bounded active registry capacity reached before " .. requestId)
        end
        operation = {
            Generation = state.Generation,
            Subsystem = subsystem,
            Lane = subsystem,
            Request = requestId,
            OperationId = requestId,
            CreatedAt = tonumber(detailField(detail, "createdAt", "CreatedAt")) or now,
            StartedAt = now,
            At = now,
        }
        state.Operations[key] = operation
        state.OperationCount = state.OperationCount + 1
        group.Active = group.Active + 1
    end
    local detailText = compactDetail(detail)
    if operation then
        updateOperationMetadata(operation, stateName, detail, now)
        operation.State, operation.Detail, operation.At = stateName, detailText, now
    end
    group.Total = group.Total + 1
    group.LastState, group.LastDetail, group.LastAt = stateName, detailText, now
    if previousState == "INVOKE_IN_FLIGHT" and stateName ~= previousState then
        state.ActiveInvokes = math.max(state.ActiveInvokes - 1, 0)
    end
    if previousState == "FIRE_LOCAL_SENT_UNACKED" and stateName ~= previousState then
        state.UnackedFires = math.max(state.UnackedFires - 1, 0)
    end
    if stateName == "INVOKE_IN_FLIGHT" and previousState ~= stateName then
        state.ActiveInvokes = state.ActiveInvokes + 1
    end
    if stateName == "FIRE_LOCAL_SENT_UNACKED" and previousState ~= stateName
        and not TERMINAL[stateName] then
        state.UnackedFires = state.UnackedFires + 1
    end
    if (stateName == "INVOKE_IN_FLIGHT" or stateName == "FIRE_LOCAL_SENT_UNACKED")
        and now - state.StartedAt <= 5 then
        state.StartupRequests = state.StartupRequests + 1
        setGauge(state, "Startup", "requests5s", state.StartupRequests)
    end
    if TERMINAL[stateName] then
        group.Completed = group.Completed + 1
        if stateName == "SERVER_REJECTED" or stateName == "TRANSPORT_FAILED"
            or stateName == "TIMED_OUT_LOCALLY_REMOTE_UNKNOWN"
            or stateName == "DROPPED_WITH_REASON" then
            group.Failed = group.Failed + 1
        end
    end
    if shouldRecordEvent(state, subsystem, stateName, operation, detailText, now) then
        recordEvent(state, subsystem, requestId, stateName, detailText, operation, now)
    end
    if TERMINAL[stateName] and operation then
        state.Operations[key] = nil
        state.OperationCount = math.max(state.OperationCount - 1, 0)
        group.Active = math.max(group.Active - 1, 0)
    end
    if subsystem ~= "Startup" and subsystem ~= "Reload" then
        state.InstrumentedTransitions = state.InstrumentedTransitions + 1
    end
    return true
end

local function complete(state, subsystem, requestId, outcome, detail)
    outcome = tostring(outcome or "COMPLETED")
    if not TERMINAL[outcome] then outcome = "COMPLETED" end
    return transition(state, subsystem, requestId, outcome, detail)
end

local function findOperationSubsystem(state, requestId)
    requestId = tostring(requestId or "")
    if requestId == "" then return nil end
    for _, operation in pairs(state.Operations) do
        if operation.Request == requestId then return operation.Subsystem end
    end
    return nil
end

local function oldestAge(state, wantedState)
    local oldest
    local now = os.clock()
    for _, operation in pairs(state.Operations) do
        if not wantedState or operation.State == wantedState then
            local age = now - operation.At
            if oldest == nil or age > oldest then oldest = age end
        end
    end
    return oldest or 0
end

local function snapshot(state, reason)
    if not state.Alive then return nil end
    local now = os.clock()
    local events = ringValues(state, "Events", "EventCursor", "EventCount", EVENT_CAPACITY)
    local recentEvents = {}
    local first = math.max(#events - 23, 1)
    for index = first, #events do
        recentEvents[#recentEvents + 1] = copyPrimitiveMap(events[index])
    end
    local item = {
        At = now,
        Reason = tostring(reason or "manual"),
        Build = tostring(state.Build),
        Commit = tostring(state.Commit),
        Generation = state.Generation,
        Ping = tonumber(state.Ping) or 0,
        SchedulerDelay = tonumber(state.SchedulerDelay) or 0,
        ActiveInvokes = state.ActiveInvokes,
        UnackedFires = state.UnackedFires,
        ActiveOperations = state.OperationCount,
        GateOwner = tostring(gauge(state, "Gate", "owner", "idle")),
        GateOwnerAge = tonumber(gauge(state, "Gate", "ownerAge", 0)) or 0,
        Incident = tostring(state.PrimaryIncident or "none"),
        Health = tostring(state.Health or "UNKNOWN"),
        Counters = {
            Sequence = state.Sequence,
            ActiveInvokes = state.ActiveInvokes,
            SentUnacknowledgedFires = state.UnackedFires,
            ActiveOperations = state.OperationCount,
            StartupRequests = state.StartupRequests,
            ExplicitDrops = state.ExplicitDrops,
        },
        Lanes = copyPrimitiveMap(state.Lanes),
        Routes = copyPrimitiveMap(state.Gauges.Routes or {}),
        InventoryGate = copyPrimitiveMap(state.Gauges.Gate or {}),
        ModuleStartup = copyPrimitiveMap(state.Gauges.Startup or {}),
        Gauges = copyPrimitiveMap(state.Gauges),
        Incidents = copyPrimitiveMap(state.Incidents),
        LastTransitions = recentEvents,
    }
    ringPush(state, "Snapshots", "SnapshotCursor", "SnapshotCount", SNAPSHOT_CAPACITY, item)
    state.LastSnapshot = item
    return item
end

local function encodeSnapshot(item)
    if type(item) ~= "table" then return nil end
    local ok, service = pcall(game.GetService, game, "HttpService")
    if ok and service then
        local encodedOk, encoded = pcall(service.JSONEncode, service, item)
        if encodedOk and type(encoded) == "string" then return encoded end
    end
    return string.format(
        "PSX Request Inspector | build=%s commit=%s generation=%s health=%s ping=%.0fms incident=%s",
        tostring(item.Build), tostring(item.Commit), tostring(item.Generation),
        tostring(item.Health), tonumber(item.Ping) or 0, tostring(item.Incident))
end

local function traceIncident(state, phase, code, evidence)
    local trace = state.Context and state.Context.Trace
    safeCall(trace, "request inspector incident " .. phase,
        tostring(code) .. " | " .. tostring(evidence or ""))
end

local function setIncident(state, code, active, evidence)
    local now = os.clock()
    local item = state.Incidents[code]
    if active then
        if state.IncidentMuted[code] then return end
        if not item then
            local definition = INCIDENTS[code] or {
                Subsystem = "Unknown", Confidence = "low",
                Suggestion = "Observe the matching subsystem.",
            }
            item = {
                Code = code, FirstSeen = now, LastSeen = now,
                Evidence = tostring(evidence or ""),
                Subsystem = definition.Subsystem,
                Confidence = definition.Confidence,
                Suggestion = definition.Suggestion,
            }
            state.Incidents[code] = item
            traceIncident(state, "start", code, item.Evidence)
            snapshot(state, "incident:" .. code)
        else
            item.LastSeen, item.Evidence = now, tostring(evidence or item.Evidence)
        end
    else
        state.IncidentMuted[code] = nil
        if item then
            traceIncident(state, "end", code, item.Evidence)
            state.Incidents[code] = nil
        end
    end
end

local function clearIncident(state, reason)
    if not state.Alive then return false end
    local codes = {}
    for code in pairs(state.Incidents) do codes[#codes + 1] = code end
    for index = 1, #codes do
        local code = codes[index]
        local item = state.Incidents[code]
        state.IncidentMuted[code] = true
        traceIncident(state, "end", code, tostring(reason or (item and item.Evidence) or "manual"))
        state.Incidents[code] = nil
    end
    state.PrimaryIncident = "none"
    state.Health = os.clock() - state.StartedAt >= 1 and "HEALTHY" or "UNKNOWN"
    snapshot(state, "incident-cleared:" .. tostring(reason or "manual"))
    return true
end

local function classify(state)
    local now = os.clock()
    local ping = tonumber(state.Ping) or 0
    local baseline = tonumber(state.PingBaseline) or 0
    local schedulerDelay = tonumber(state.SchedulerDelay) or 0
    local invokeAge = math.max(oldestAge(state, "INVOKE_IN_FLIGHT"),
        tonumber(gauge(state, "Farm", "oldestInvokeAge", 0)) or 0)
    local farmQueue = tonumber(gauge(state, "Farm", "queued", 0)) or 0
    local farmNoCompletion = tonumber(gauge(state, "Farm", "noCompletionAge", 0)) or 0
    local eggAckAge = tonumber(gauge(state, "Egg", "waitingAckAge", 0)) or 0
    local eggPostAge = tonumber(gauge(state, "Egg", "postProcessAge", 0)) or 0
    local gateAge = tonumber(gauge(state, "Gate", "ownerAge", 0)) or 0
    local gateWaiters = tonumber(gauge(state, "Gate", "waiters", 0)) or 0
    local orbPending = tonumber(gauge(state, "Loot", "orbPending", 0)) or 0
    local bagRetired = tonumber(gauge(state, "Loot", "bagRetiredNoAck", 0)) or 0
    local producerCold = gauge(state, "Loot", "producerCold", false) == true
    local unresolved = tonumber(gauge(state, "Routes", "unresolved", 0)) or 0
    local startupBurst = tonumber(gauge(state, "Startup", "requests5s", 0)) or 0
    local ghost = tonumber(gauge(state, "Reload", "ghostOperations", 0)) or 0

    state.HighPingSamples = (ping > PING_ABSOLUTE_WARNING
        or (baseline > 0 and ping > baseline * PING_RELATIVE_MULTIPLIER))
        and (state.HighPingSamples + 1) or 0
    setIncident(state, "FARM_STUCK_INVOKE", invokeAge > 8,
        string.format("oldest invoke %.1fs", invokeAge))
    setIncident(state, "FARM_REQUEST_BACKLOG", farmQueue > 8 and farmNoCompletion > 8,
        string.format("queued=%d no-completion=%.1fs", farmQueue, farmNoCompletion))
    setIncident(state, "EGG_WAITING_GAME_ACK", eggAckAge > 8,
        string.format("ack age %.1fs", eggAckAge))
    setIncident(state, "EGG_POSTPROCESS_HOLD", eggPostAge > 8,
        string.format("post-process age %.1fs", eggPostAge))
    setIncident(state, "INVENTORY_GATE_STARVATION", gateAge > 45 or (gateWaiters > 0 and gateAge > 8),
        string.format("owner age %.1fs waiters=%d", gateAge, gateWaiters))
    setIncident(state, "ORB_FIRE_UNACKNOWLEDGED", orbPending > 4096,
        "pending orb IDs=" .. tostring(orbPending))
    setIncident(state, "LOOTBAG_RETIRED_WITHOUT_ACK", bagRetired > 0,
        "retired without ack=" .. tostring(bagRetired))
    setIncident(state, "PRODUCER_COLD", producerCold, "producer gate is not ready")
    setIncident(state, "ROUTE_UNRESOLVED", unresolved > 0, "unresolved routes=" .. tostring(unresolved))
    setIncident(state, "STARTUP_REQUEST_BURST", now - state.StartedAt <= 15 and startupBurst > 6,
        "requests in startup window=" .. tostring(startupBurst))
    setIncident(state, "RELOAD_GHOST_GENERATION", ghost > 0,
        "old-generation operations=" .. tostring(ghost))
    setIncident(state, "CLIENT_SCHEDULER_STALL", schedulerDelay > 2,
        string.format("scheduler delay %.2fs", schedulerDelay))
    local noLocalPressure = invokeAge <= 8 and farmQueue == 0 and gateWaiters == 0
        and schedulerDelay <= 2
    setIncident(state, "NETWORK_OR_EXECUTOR_UNKNOWN", state.HighPingSamples >= 3 and noLocalPressure,
        string.format("ping %.0fms baseline %.0fms", ping, baseline))

    local primary = "none"
    local health = "UNKNOWN"
    for _, code in ipairs(INCIDENT_PRIORITY) do
        local incident = state.Incidents[code]
        if incident then
            if primary == "none" then primary = code end
            if incident.Confidence == "high" then
                health = "FAULT"
                break
            elseif health ~= "FAULT" then
                health = "WARNING"
            end
        end
    end
    if primary == "none" and now - state.StartedAt >= 1 then health = "HEALTHY" end
    state.PrimaryIncident = primary
    state.Health = health
end

local function readPing(state)
    local stats = state.Stats
    if not stats then return end
    local ok, value = pcall(function()
        local network = stats.Network
        local server = network and network.ServerStatsItem
        local item = server and server["Data Ping"]
        return item and item:GetValue()
    end)
    value = ok and tonumber(value) or nil
    if not value then return end
    state.Ping = value
    if value < 2000 and state.PingBaselineSamples < PING_BASELINE_SAMPLE_LIMIT then
        state.PingBaseline = state.PingBaseline == 0 and value
            or state.PingBaseline * 0.92 + value * 0.08
        state.PingBaselineSamples = state.PingBaselineSamples + 1
    end
end

local function formatLane(state, name)
    local value = state.Lanes[name] or {}
    return string.format("active %d | total %d | done %d | failed %d\nlast %s | %s",
        tonumber(value.Active) or 0, tonumber(value.Total) or 0,
        tonumber(value.Completed) or 0, tonumber(value.Failed) or 0,
        tostring(value.LastState or "IDLE"), tostring(value.LastDetail or ""))
end

local function compactLane(state, name)
    local value = state.Lanes[name] or {}
    return string.format("%s %d/%d/%d", name,
        tonumber(value.Active) or 0,
        tonumber(value.Completed) or 0,
        tonumber(value.Failed) or 0)
end

local function incidentText(state)
    local now, lines = os.clock(), {}
    for code, item in pairs(state.Incidents) do
        lines[#lines + 1] = string.format("%s [%s] %.1fs\n%s\n%s",
            code, item.Confidence, now - item.FirstSeen,
            item.Evidence, item.Suggestion)
    end
    table.sort(lines)
    return #lines > 0 and table.concat(lines, "\n\n") or "No active incident."
end

local function setText(state, key, text)
    local label = state.UI.Labels[key]
    text = tostring(text or "")
    if not label or state.UI.Last[key] == text then return end
    state.UI.Last[key] = text
    label.Text = text
    local lines = select(2, string.gsub(text, "\n", "")) + 1
    label.Size = UDim2.new(1, -12, 0, math.max(38, lines * 15 + 12))
end

local function updateCanvas(state)
    local body = state.UI.Body
    local layout = state.UI.Layout
    if body and layout then body.CanvasSize = UDim2.fromOffset(0, layout.AbsoluteContentSize.Y + 8) end
end

local function updateUI(state)
    if not state.UI.Gui then return end
    local gateOwner = gauge(state, "Gate", "owner", "idle")
    local gateAge = tonumber(gauge(state, "Gate", "ownerAge", 0)) or 0
    local queue = tonumber(gauge(state, "Farm", "queued", 0)) or 0
    setText(state, "Top", string.format(
        "build %s | commit %s | gen %d\nping %.0fms (base %.0f) | scheduler +%.3fs\ninvokes %d | unacked fires %d | queue %d | gate %s %.1fs\nhealth %s | incident %s",
        state.Build, string.sub(state.Commit, 1, 10), state.Generation,
        state.Ping, state.PingBaseline, state.SchedulerDelay,
        state.ActiveInvokes, state.UnackedFires, queue, tostring(gateOwner), gateAge,
        state.Health, state.PrimaryIncident))
    setText(state, "Farm", formatLane(state, "Farm") .. string.format(
        "\nworkers %s/%s +%s | idle %s | targets %s/%s"
            .. "\nqueued %s | invoke %s oldest %.1fs | RTT %.0fms"
            .. "\nsignals target/farm/fail %s/%s/%s | transport/timeout %s/%s"
            .. "\naccepted/reject/stale %s/%s/%s | target cooldowns %s",
        tostring(gauge(state, "Farm", "working", 0)),
        tostring(gauge(state, "Farm", "equipped", 0)),
        tostring(gauge(state, "Farm", "joining", 0)),
        tostring(gauge(state, "Farm", "trueIdle", 0)),
        tostring(gauge(state, "Farm", "targets", 0)),
        tostring(gauge(state, "Farm", "targetWindow", 0)),
        tostring(queue), tostring(gauge(state, "Farm", "activeInvokeCount", 0)),
        tonumber(gauge(state, "Farm", "oldestInvokeAge", 0)) or 0,
        tonumber(gauge(state, "Farm", "averageRtt", 0)) or 0,
        tostring(gauge(state, "Farm", "targetSignals", 0)),
        tostring(gauge(state, "Farm", "farmSignals", 0)),
        tostring(gauge(state, "Farm", "signalFailures", 0)),
        tostring(gauge(state, "Farm", "transportFailures", 0)),
        tostring(gauge(state, "Farm", "localTimeouts", 0)),
        tostring(gauge(state, "Farm", "accepted", 0)),
        tostring(gauge(state, "Farm", "rejects", 0)),
        tostring(gauge(state, "Farm", "stale", 0)),
        tostring(gauge(state, "Farm", "targetCooldowns", 0))))
    setText(state, "Egg", formatLane(state, "Egg") .. string.format(
        "\n%s x%s | attempt %s | request/ack/post %.1f/%.1f/%.1fs"
            .. "\nrequest/success/reject/timeout %s/%s/%s/%s | retry %s/%s"
            .. "\nopen/delta %s/%s | response/post waits %s/%s | post attempt %s"
            .. "\ndelete pending %s | overlap %s | recovery %.0fs | route %s",
        tostring(gauge(state, "Egg", "selected", "idle")),
        tostring(gauge(state, "Egg", "count", 0)),
        tostring(gauge(state, "Egg", "attempt", 0)),
        tonumber(gauge(state, "Egg", "requestAge", 0)) or 0,
        tonumber(gauge(state, "Egg", "waitingAckAge", 0)) or 0,
        tonumber(gauge(state, "Egg", "postProcessAge", 0)) or 0,
        tostring(gauge(state, "Egg", "requests", 0)),
        tostring(gauge(state, "Egg", "successes", 0)),
        tostring(gauge(state, "Egg", "rejections", 0)),
        tostring(gauge(state, "Egg", "timeouts", 0)),
        tostring(gauge(state, "Egg", "networkRetries", 0)),
        tostring(gauge(state, "Egg", "postProcessRetries", 0)),
        tostring(gauge(state, "Egg", "openEvents", 0)),
        tostring(gauge(state, "Egg", "inventoryDelta", 0)),
        tostring(gauge(state, "Egg", "responseWaits", 0)),
        tostring(gauge(state, "Egg", "postProcessWaits", 0)),
        tostring(gauge(state, "Egg", "postProcessAttempt", 0)),
        tostring(gauge(state, "Egg", "autoDeletePending", 0)),
        tostring(gauge(state, "Egg", "manualOverlapSeen", false)),
        tonumber(gauge(state, "Egg", "recoveryWindowRemaining", 0)) or 0,
        tostring(gauge(state, "Egg", "eventRoute", "unresolved"))))
    setText(state, "Loot", formatLane(state, "Loot") .. string.format(
        "\norbs pending %s | batches/IDs/max %s/%s/%s | unacked %s"
            .. "\nrate IDs/batches %.1f/%.1f/s | avg %.1f | dedup %s"
            .. "\norb err/overflow/drop %s/%s/%s | route %s | ack remote-event unavailable"
            .. "\nbags waiting %s | sent/ack/no-ack/drop %s/%s/%s/%s"
            .. "\nbag object/net/retry/error/overflow %s/%s/%s/%s/%s | route %s"
            .. "\nproducer %s",
        tostring(gauge(state, "Loot", "orbPending", 0)),
        tostring(gauge(state, "Loot", "orbBatches", 0)),
        tostring(gauge(state, "Loot", "orbIdsSent", 0)),
        tostring(gauge(state, "Loot", "orbMaxBatch", 0)),
        tostring(gauge(state, "Loot", "orbLocalSentUnacked", 0)),
        tonumber(gauge(state, "Loot", "orbIdsPerSecond", 0)) or 0,
        tonumber(gauge(state, "Loot", "orbBatchesPerSecond", 0)) or 0,
        tonumber(gauge(state, "Loot", "orbAverageBatch", 0)) or 0,
        tostring(gauge(state, "Loot", "orbDeduplicated", 0)),
        tostring(gauge(state, "Loot", "orbErrors", 0)),
        tostring(gauge(state, "Loot", "orbOverflow", 0)),
        tostring(gauge(state, "Loot", "orbDropped", 0)),
        tostring(gauge(state, "Loot", "orbRoute", "unresolved")),
        tostring(gauge(state, "Loot", "bagsWaiting", 0)),
        tostring(gauge(state, "Loot", "bagSent", 0)),
        tostring(gauge(state, "Loot", "bagAcked", 0)),
        tostring(gauge(state, "Loot", "bagRetiredNoAck", 0)),
        tostring(gauge(state, "Loot", "bagTransportDropped", 0)),
        tostring(gauge(state, "Loot", "bagObjectAck", 0)),
        tostring(gauge(state, "Loot", "bagNetworkAck", 0)),
        tostring(gauge(state, "Loot", "bagRetries", 0)),
        tostring(gauge(state, "Loot", "bagErrors", 0)),
        tostring(gauge(state, "Loot", "bagOverflow", 0)),
        tostring(gauge(state, "Loot", "bagRoute", "unresolved")),
        tostring(gauge(state, "Loot", "producer",
            gauge(state, "Loot", "producerCold", false) and "cold" or "ready/unknown"))))
    setText(state, "Gate", formatLane(state, "Gate") .. string.format(
        "\nowner %s | gen %s | age %.1fs | waiters %s (oldest %.1fs)"
            .. "\nwaiter ages %s | expiry owner/waiter %.0f/%.0fs"
            .. "\nlast acquire/release: %s / %s"
            .. "\nlast expiry owner=%s (%.1fs) | waiters=%s (%.1fs)",
        tostring(gateOwner), tostring(gauge(state, "Gate", "ownerGeneration", 0)), gateAge,
        tostring(gauge(state, "Gate", "waiters", 0)),
        tonumber(gauge(state, "Gate", "oldestWaiterAge", 0)) or 0,
        tostring(gauge(state, "Gate", "waiterAges", "none")),
        tonumber(gauge(state, "Gate", "ownerExpiry", 45)) or 45,
        tonumber(gauge(state, "Gate", "waiterExpiry", 2)) or 2,
        tostring(gauge(state, "Gate", "lastAcquireReason", "none")),
        tostring(gauge(state, "Gate", "lastReleaseReason", "none")),
        tostring(gauge(state, "Gate", "lastOwnerExpiry", "none")),
        tonumber(gauge(state, "Gate", "lastOwnerExpiryAge", 0)) or 0,
        tostring(gauge(state, "Gate", "lastWaiterExpiryCount", 0)),
        tonumber(gauge(state, "Gate", "lastWaiterExpiryAge", 0)) or 0))
    setText(state, "Background", formatLane(state, "Background") .. "\n"
        .. compactLane(state, "Machines") .. " | " .. compactLane(state, "Enchant") .. "\n"
        .. compactLane(state, "Boosts") .. " | " .. compactLane(state, "Rewards")
        .. "\nmodule loader " .. tostring(gauge(state, "Background", "moduleLoaderOwner", "idle"))
        .. " | busy=" .. tostring(gauge(state, "Background", "moduleLoaderBusy", false)))
    setText(state, "Routes", formatLane(state, "Routes")
        .. "\nunresolved " .. tostring(gauge(state, "Routes", "unresolved", 0))
        .. "\nlast resolved " .. tostring(gauge(state, "Routes", "lastResolved", "none"))
        .. "\nlast unresolved " .. tostring(gauge(state, "Routes", "lastUnresolved", "none")))
    setText(state, "Startup", formatLane(state, "Startup") .. string.format(
        "\nnetwork requests/5s %s | module fetches/5s %s"
            .. "\nloader waiters %s | last %s (%s)"
            .. "\ndownload/verify/compile/total %.0f/%.0f/%.0f/%.0fms"
            .. "\nconfig %.0fms | enabled %s",
        tostring(gauge(state, "Startup", "requests5s", 0)),
        tostring(gauge(state, "Startup", "moduleRequests5s", 0)),
        tostring(gauge(state, "Startup", "moduleLoaderWaiters", 0)),
        tostring(gauge(state, "Startup", "lastModule", "none")),
        tostring(gauge(state, "Startup", "lastModuleState", "idle")),
        tonumber(gauge(state, "Startup", "lastDownloadMs", 0)) or 0,
        tonumber(gauge(state, "Startup", "lastVerifyMs", 0)) or 0,
        tonumber(gauge(state, "Startup", "lastCompileMs", 0)) or 0,
        tonumber(gauge(state, "Startup", "lastModuleLoadMs", 0)) or 0,
        tonumber(gauge(state, "Startup", "configLoadMs", 0)) or 0,
        tostring(gauge(state, "Startup", "enabledAutomation", "none"))))
    setText(state, "Reload", formatLane(state, "Reload") .. string.format(
        "\ngeneration %s <- %s | cleanup %s in %.1fms"
            .. "\ndisconnected %s | cancelled workers %s | legacy stops %s | stale UI %s"
            .. "\nworker starts %s | duplicate starts %s | ghost operations %s",
        tostring(gauge(state, "Reload", "generation", state.Generation)),
        tostring(gauge(state, "Reload", "previousGeneration", 0)),
        tostring(gauge(state, "Reload", "cleanupState", "unknown")),
        tonumber(gauge(state, "Reload", "cleanupDurationMs", 0)) or 0,
        tostring(gauge(state, "Reload", "disconnectedConnections", 0)),
        tostring(gauge(state, "Reload", "cancelledWorkers", 0)),
        tostring(gauge(state, "Reload", "stoppedLegacyStates", 0)),
        tostring(gauge(state, "Reload", "staleUIRemoved", 0)),
        tostring(gauge(state, "Reload", "workerStarts", 0)),
        tostring(gauge(state, "Reload", "duplicateWorkerStarts", 0)),
        tostring(gauge(state, "Reload", "ghostOperations", 0))))
    setText(state, "Incident", incidentText(state))
    updateCanvas(state)
end

local function connect(state, signal, callback)
    local ok, connection = pcall(function() return signal:Connect(callback) end)
    if ok and connection then state.Connections[#state.Connections + 1] = connection end
end

local function make(className, properties)
    local object = Instance.new(className)
    for key, value in pairs(properties or {}) do object[key] = value end
    return object
end

local function createUI(state)
    local parent
    if type(gethui) == "function" then
        local ok, value = pcall(gethui)
        if ok and typeof(value) == "Instance" then parent = value end
    end
    if not parent then
        local ok, value = pcall(game.GetService, game, "CoreGui")
        if ok then parent = value end
    end
    if not parent then
        local player = state.Context and state.Context.Player
        parent = player and player:FindFirstChildOfClass("PlayerGui")
    end
    if not parent then return false, "no supported UI parent" end

    local old = parent:FindFirstChild("PSX_OG_RequestInspector")
    if old then pcall(function() old:Destroy() end) end
    local gui = make("ScreenGui", {
        Name = "PSX_OG_RequestInspector", ResetOnSpawn = false,
        IgnoreGuiInset = true, DisplayOrder = 100000,
    })
    state.UI.Gui = gui
    local root = make("Frame", {
        Name = "Panel", Size = UDim2.fromOffset(470, 520),
        Position = UDim2.new(0, 22, 0.5, -260),
        BackgroundColor3 = Color3.fromRGB(8, 15, 28),
        BackgroundTransparency = 0.08, BorderSizePixel = 0,
        Active = true, Draggable = true,
    })
    make("UICorner", { CornerRadius = UDim.new(0, 10), Parent = root })
    local header = make("TextLabel", {
        Parent = root, Size = UDim2.new(1, -220, 0, 34),
        Position = UDim2.fromOffset(12, 0), BackgroundTransparency = 1,
        Text = "PSX REQUEST INSPECTOR  v" .. MODULE_VERSION,
        TextColor3 = Color3.fromRGB(226, 232, 240), TextSize = 14,
        Font = Enum.Font.GothamBold, TextXAlignment = Enum.TextXAlignment.Left,
    })
    local function button(text, x, width)
        width = width or 44
        return make("TextButton", {
            Parent = root, Size = UDim2.fromOffset(width, 24),
            Position = UDim2.new(1, x, 0, 5), BackgroundColor3 = Color3.fromRGB(20, 35, 57),
            BorderSizePixel = 0, Text = text, TextColor3 = Color3.fromRGB(94, 234, 212),
            TextSize = 12, Font = Enum.Font.GothamBold,
        })
    end
    local capture = button("Snap", -198, 48)
    local copy = button("Copy", -146, 48)
    local clear = button("Clear", -94, 48)
    local hide = button("-", -42, 36)
    local body = make("ScrollingFrame", {
        Parent = root, Position = UDim2.fromOffset(8, 36), Size = UDim2.new(1, -16, 1, -44),
        BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 4,
        ScrollBarImageColor3 = Color3.fromRGB(45, 212, 191), CanvasSize = UDim2.new(),
    })
    local layout = make("UIListLayout", {
        Parent = body, Padding = UDim.new(0, 5), SortOrder = Enum.SortOrder.LayoutOrder,
    })
    local categories = { "Top", "Farm", "Egg", "Loot", "Gate", "Background", "Routes", "Startup", "Reload", "Incident" }
    for order, name in ipairs(categories) do
        local section = make("Frame", {
            Parent = body, Size = UDim2.new(1, -6, 0, name == "Top" and 112 or 78),
            BackgroundColor3 = Color3.fromRGB(26, 36, 54), BackgroundTransparency = 0.08,
            BorderSizePixel = 0, LayoutOrder = order,
        })
        make("UICorner", { CornerRadius = UDim.new(0, 7), Parent = section })
        local title = make("TextButton", {
            Parent = section, Size = UDim2.new(1, -8, 0, 24), Position = UDim2.fromOffset(4, 2),
            BackgroundTransparency = 1, Text = string.upper(name),
            TextColor3 = Color3.fromRGB(94, 234, 212), TextSize = 12,
            Font = Enum.Font.GothamBold, TextXAlignment = Enum.TextXAlignment.Left,
        })
        local label = make("TextLabel", {
            Parent = section, Position = UDim2.fromOffset(6, 26), Size = UDim2.new(1, -12, 0, 48),
            BackgroundTransparency = 1, Text = "idle", TextWrapped = true,
            TextColor3 = Color3.fromRGB(203, 213, 225), TextSize = 11,
            Font = Enum.Font.Code, TextXAlignment = Enum.TextXAlignment.Left,
            TextYAlignment = Enum.TextYAlignment.Top,
        })
        state.UI.Labels[name] = label
        connect(state, title.MouseButton1Click, function()
            local collapsed = state.UI.Collapsed[name] == true
            state.UI.Collapsed[name] = not collapsed
            label.Visible = collapsed
            section.Size = UDim2.new(1, -6, 0, collapsed and (label.AbsoluteSize.Y + 32) or 28)
            updateCanvas(state)
        end)
        connect(state, label:GetPropertyChangedSignal("AbsoluteSize"), function()
            if state.UI.Collapsed[name] ~= true then
                section.Size = UDim2.new(1, -6, 0, label.AbsoluteSize.Y + 32)
                updateCanvas(state)
            end
        end)
    end
    local show = make("TextButton", {
        Parent = gui, Visible = false, Size = UDim2.fromOffset(42, 28),
        Position = UDim2.fromOffset(22, 60), BackgroundColor3 = Color3.fromRGB(8, 15, 28),
        BorderSizePixel = 0, Text = "RSI", TextColor3 = Color3.fromRGB(94, 234, 212),
        TextSize = 11, Font = Enum.Font.GothamBold,
    })
    connect(state, capture.MouseButton1Click, function() snapshot(state, "manual-ui") end)
    connect(state, copy.MouseButton1Click, function()
        local item = snapshot(state, "copy")
        local callback = setclipboard
        if type(callback) == "function" and item then
            safeCall(callback, encodeSnapshot(item))
        end
    end)
    connect(state, clear.MouseButton1Click, function() clearIncident(state, "manual-ui") end)
    connect(state, hide.MouseButton1Click, function()
        root.Visible, show.Visible, state.Minimized = false, true, true
    end)
    connect(state, show.MouseButton1Click, function()
        root.Visible, show.Visible, state.Minimized = true, false, false
    end)
    gui.Parent = parent
    root.Parent = gui
    root.Visible = false
    show.Visible = true
    state.Minimized = true
    state.UI.Root, state.UI.Body, state.UI.Layout = root, body, layout
    return true
end

local function updateLoop(state)
    if not state.Alive then return end
    local now = os.clock()
    if state.ExpectedAt then state.SchedulerDelay = math.max(now - state.ExpectedAt, 0) end
    readPing(state)
    classify(state)
    updateUI(state)
    local delay = state.Minimized and UPDATE_MINIMIZED or UPDATE_EXPANDED
    state.ExpectedAt = os.clock() + delay
    task.delay(delay, function() updateLoop(state) end)
end

local function destroy(state, reason)
    if not state or not state.Alive then return true end
    reason = tostring(reason or "destroy")
    local ghost = state.OperationCount
    local env = state.Context and state.Context.Env
    if type(env) == "table" then
        env.PSX_OG_REQUEST_INSPECTOR_HANDOFF = {
            Generation = state.Generation, At = os.clock(), GhostOperations = ghost,
            ActiveInvokes = state.ActiveInvokes, UnackedFires = state.UnackedFires,
            Reason = reason, Incident = state.PrimaryIncident,
        }
    end
    state.Alive = false
    for _, connection in ipairs(state.Connections) do
        pcall(function() connection:Disconnect() end)
    end
    table.clear(state.Connections)
    if state.UI.Gui then pcall(function() state.UI.Gui:Destroy() end) end
    state.UI.Gui = nil
    table.clear(state.Operations)
    state.OperationCount = 0
    if type(env) == "table" and env.PSX_OG_REQUEST_INSPECTOR == state.Controller then
        env.PSX_OG_REQUEST_INSPECTOR = nil
    end
    if current == state then current = nil end
    return true
end

local function start(context)
    if type(context) ~= "table" then return nil, "context table required" end
    if current then destroy(current, "superseded") end
    local stats
    pcall(function() stats = game:GetService("Stats") end)
    local state = {
        Context = context, Stats = stats, Alive = true, StartedAt = os.clock(),
        Build = tostring(context.Version or "unknown"),
        Commit = tostring(context.Commit or "unknown"),
        Generation = tonumber(context.Generation) or 0,
        Events = {}, EventCursor = 1, EventCount = 0,
        Snapshots = {}, SnapshotCursor = 1, SnapshotCount = 0,
        Operations = {}, OperationCount = 0, Lanes = {}, Gauges = {}, EventThrottle = {},
        Sequence = 0, ActiveInvokes = 0, UnackedFires = 0, StartupRequests = 0,
        ExplicitDrops = 0, InstrumentedTransitions = 0,
        Ping = 0, PingBaseline = 0, PingBaselineSamples = 0, HighPingSamples = 0,
        SchedulerDelay = 0, ExpectedAt = nil, PrimaryIncident = "none", Health = "UNKNOWN",
        Incidents = {}, IncidentMuted = {}, Connections = {}, Minimized = true,
        UI = { Gui = nil, Labels = {}, Last = {}, Collapsed = {} },
    }
    local controller = {}
    state.Controller = controller
    function controller:Transition(subsystem, requestId, stateName, detail)
        return transition(state, subsystem, requestId, stateName, detail)
    end
    function controller:SetGauge(subsystem, key, value)
        return setGauge(state, subsystem, key, value)
    end
    function controller:Complete(subsystem, requestId, outcome, detail)
        -- Both forms are supported:
        --   Complete(subsystem, requestId, outcome, detail)
        --   Complete(requestId, outcome, detail)
        -- The short form only resolves an operation that is already present in
        -- the bounded active set; it never guesses a subsystem or creates work.
        if detail == nil and findOperationSubsystem(state, subsystem) then
            detail = outcome
            outcome = requestId
            requestId = subsystem
            subsystem = findOperationSubsystem(state, requestId)
        end
        if subsystem == nil then return false end
        return complete(state, subsystem, requestId, outcome, detail)
    end
    function controller:Snapshot(reason) return snapshot(state, reason) end
    function controller:Events() return ringValues(state, "Events", "EventCursor", "EventCount", EVENT_CAPACITY) end
    function controller:Snapshots()
        return ringValues(state, "Snapshots", "SnapshotCursor", "SnapshotCount", SNAPSHOT_CAPACITY)
    end
    function controller:ClearIncident(reason)
        return clearIncident(state, reason or "manual-controller")
    end
    function controller:Clear()
        table.clear(state.Events); table.clear(state.Snapshots)
        state.EventCursor, state.EventCount = 1, 0
        state.SnapshotCursor, state.SnapshotCount = 1, 0
        return true
    end
    function controller:Destroy(reason) return destroy(state, reason) end
    function controller:State()
        return {
            Version = MODULE_VERSION, Alive = state.Alive, Generation = state.Generation,
            Ping = state.Ping, Baseline = state.PingBaseline,
            ActiveInvokes = state.ActiveInvokes, UnackedFires = state.UnackedFires,
            ActiveOperations = state.OperationCount, Incident = state.PrimaryIncident,
            Health = state.Health, ExplicitDrops = state.ExplicitDrops,
        }
    end
    local env = context.Env
    if type(env) == "table" then
        local boot = env.PSX_OG_REQUEST_INSPECTOR_BOOT
        if type(boot) == "table" then
            setGauge(state, "Reload", "generation", tonumber(boot.Generation) or state.Generation)
            setGauge(state, "Reload", "previousGeneration", tonumber(boot.PreviousGeneration) or 0)
            setGauge(state, "Reload", "cleanupState",
                (tonumber(boot.CleanupCompletedAt) or 0) > 0 and "completed" or "started")
            setGauge(state, "Reload", "cleanupDurationMs",
                (tonumber(boot.CleanupDuration) or 0) * 1000)
            setGauge(state, "Reload", "disconnectedConnections",
                tonumber(boot.DisconnectedConnections) or 0)
            setGauge(state, "Reload", "cancelledWorkers", tonumber(boot.CancelledWorkers) or 0)
            setGauge(state, "Reload", "stoppedLegacyStates", tonumber(boot.StoppedLegacyStates) or 0)
            setGauge(state, "Reload", "staleUIRemoved", tonumber(boot.StaleUIRemoved) or 0)
            transition(state, "Reload", "startup-cleanup:" .. tostring(state.Generation),
                "COMPLETED", {
                    previousGeneration = tonumber(boot.PreviousGeneration) or 0,
                    cleanupInvoked = boot.CleanupInvoked == true,
                    cleanupSucceeded = boot.CleanupSucceeded == true,
                    durationMs = (tonumber(boot.CleanupDuration) or 0) * 1000,
                })
        end
        env.PSX_OG_REQUEST_INSPECTOR_BOOT = nil
        local handoff = env.PSX_OG_REQUEST_INSPECTOR_HANDOFF
        if type(handoff) == "table" and tonumber(handoff.Generation) ~= state.Generation then
            setGauge(state, "Reload", "ghostOperations", tonumber(handoff.GhostOperations) or 0)
            transition(state, "Reload", "generation-handoff", "LOCAL_CANCELLED_REMOTE_UNKNOWN",
                "old generation=" .. tostring(handoff.Generation)
                    .. " active=" .. tostring(handoff.GhostOperations))
        end
        env.PSX_OG_REQUEST_INSPECTOR_HANDOFF = nil
        env.PSX_OG_REQUEST_INSPECTOR = controller
    end
    current = state
    transition(state, "Startup", "inspector", "COMPLETED", "passive collector ready")
    local uiOk, uiResult, uiReason = pcall(createUI, state)
    if not uiOk or uiResult ~= true then
        if state.UI.Gui then pcall(function() state.UI.Gui:Destroy() end) end
        state.UI.Gui = nil
        local reason = uiOk and tostring(uiReason or "UI initialization returned false")
            or tostring(uiResult)
        setGauge(state, "Startup", "inspectorUI", "instrumentation unavailable: " .. reason)
        transition(state, "Startup", "inspector-ui", "DROPPED_WITH_REASON", {
            reason = reason,
            requestType = "local",
            command = "create request inspector UI",
        })
        safeCall(context.Trace, "request inspector UI unavailable", reason)
    else
        setGauge(state, "Startup", "inspectorUI", "ready")
    end
    local initialDelay = state.Minimized and UPDATE_MINIMIZED or UPDATE_EXPANDED
    state.ExpectedAt = os.clock() + initialDelay
    task.delay(initialDelay, function() updateLoop(state) end)
    return controller
end

return function(action, context, value)
    if action == "version" then return MODULE_VERSION end
    if action == "start" then return start(context) end
    if action == "stop" or action == "destroy" then
        return destroy(current, value or action)
    end
    if action == "state" then
        return current and current.Controller:State() or nil
    end
    return false, "unknown action"
end
