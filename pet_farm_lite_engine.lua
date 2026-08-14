-- Lightweight, event-driven transport for PSX OG pet farming.
-- Target selection and lifetime locks belong to the caller. This module only
-- sends a bounded number of Join Coin requests and never polls game state.

local MODULE_VERSION = "1.4.2"
local DEFAULT_DISPATCH_WIDTH = 16
local MAX_QUEUED_JOBS = 32
local MAX_JOIN_ATTEMPTS = 2
local RETRY_DELAY = 0.25

local scheduler = task or {
    delay = function(_, callback)
        coroutine.wrap(callback)()
    end,
}

local transportGate = {
    Fire = {},
    Invoke = {},
    InFlight = {},
    -- Kept as an explicit diagnostic map. Completed state-changing Invoke
    -- responses are never inserted or replayed.
    InvokeHistory = {},
}

local TRANSPORT_TTL = {
    ["Change Pet Target"] = 0.08,
    ["Farm Coin"] = 0.08,
    ["Join Coin"] = 0.15,
}

local function transportSerialize(value, depth)
    depth = depth or 0
    if depth > 3 then return "[depth]" end

    local valueType = type(value)
    if valueType == "string" or valueType == "number" or valueType == "boolean" or valueType == "nil" then
        return tostring(value)
    end
    if valueType == "Instance" then
        local className = pcall(function() return value.ClassName end) and value.ClassName or "Instance"
        local name = pcall(function() return value.Name end) and value.Name or ""
        return string.format("Instance:%s:%s", className, tostring(name))
    end
    if valueType == "table" then
        local list = {}
        for key, item in ipairs(value) do
            list[#list + 1] = transportSerialize(item, depth + 1)
        end
        if #list > 0 then
            table.sort(list)
            return "[" .. table.concat(list, ",") .. "]"
        end
        local ordered = {}
        for key, item in pairs(value) do
            ordered[#ordered + 1] = tostring(key) .. "=" .. transportSerialize(item, depth + 1)
        end
        table.sort(ordered)
        return "{" .. table.concat(ordered, ",") .. "}"
    end
    return valueType
end

local function transportKey(command, ...)
    local pieces = {tostring(command)}
    for index = 1, select("#", ...) do
        pieces[#pieces + 1] = transportSerialize(select(index, ...), 0)
    end
    return table.concat(pieces, "|")
end

local run = {
    Context = nil,
    Epoch = 0,
    Queue = {},
    Head = 1,
    Delayed = {},
    JobPool = {},
    RetryToken = 0,
    RetryDue = nil,
    PendingByPet = {},
    Active = 0,
    Limit = DEFAULT_DISPATCH_WIDTH,
    Accepted = 0,
    Rejected = 0,
    Errors = 0,
    Retries = 0,
    Stale = 0,
    Dropped = 0,
    AverageRTT = 0,
    LastRTT = 0,
    LastProblem = "none",
    DiagnosticSequence = 0,
    LastDispatchAt = 0,
    LastCompletionAt = 0,
    ActiveInvokes = {},
    TargetSignals = 0,
    FarmSignals = 0,
    SignalFailures = 0,
    TransportFailures = 0,
    JoinInvokes = 0,
    TransportSuppressed = 0,
    TransportCoalesced = 0,
    LocalTimeouts = 0,
    LastRoute = "unavailable",
    LastAssignmentAt = 0,
    LastTargetChangeAt = 0,
    NextLaunchAt = 0,
}

local boss = {
    State = "ABSENT",
    CoinId = nil,
    SpawnGeneration = 0,
    Current = nil,
    LastRemovedAt = 0,
    Ring = {},
    RingHead = 1,
    RingCount = 0,
    SpawnsSeen = 0,
    DirectSpawns = 0,
    FallbackSpawns = 0,
    DuplicateSpawns = 0,
    JoinsSent = 0,
    JoinsAccepted = 0,
    MissedBeforeDispatch = 0,
}

local function bossGenerationCurrent(coinId, generation)
    return boss.CoinId == tostring(coinId)
        and boss.SpawnGeneration == tonumber(generation)
        and boss.State ~= "DEAD" and boss.State ~= "ABSENT"
end

local function bossSample(current, removedAt, reason)
    if type(current) ~= "table" then return end
    current.RemovedAt = tonumber(removedAt) or os.clock()
    current.Reason = tostring(reason or "removed")
    current.Lifetime = math.max(current.RemovedAt - (tonumber(current.SpawnedAt) or current.RemovedAt), 0)
    local slot = boss.RingHead
    boss.Ring[slot] = current
    boss.RingHead = slot % 64 + 1
    boss.RingCount = math.min(boss.RingCount + 1, 64)
end

local function bossSpawn(info)
    if type(info) ~= "table" or info.CoinId == nil then return false, "boss spawn info is invalid" end
    local coinId = tostring(info.CoinId)
    local now = tonumber(info.ReceivedAt) or os.clock()
    if info.ForceNew ~= true and boss.CoinId == coinId
        and boss.State ~= "ABSENT" and boss.State ~= "DEAD" then
        boss.DuplicateSpawns = boss.DuplicateSpawns + 1
        local current = boss.Current
        if current then
            current.PayloadComplete = current.PayloadComplete or info.PayloadComplete == true
            current.LastDuplicateAt = now
        end
        return false, "duplicate", boss.SpawnGeneration
    end

    if info.ForceNew == true and boss.Current and boss.State ~= "ABSENT" and boss.State ~= "DEAD" then
        bossSample(boss.Current, now, "implicit respawn")
    end
    boss.SpawnGeneration = boss.SpawnGeneration + 1
    boss.CoinId = coinId
    boss.State = "SPAWN_SEEN"
    boss.SpawnsSeen = boss.SpawnsSeen + 1
    local direct = info.Direct == true
    if direct then boss.DirectSpawns = boss.DirectSpawns + 1
    else boss.FallbackSpawns = boss.FallbackSpawns + 1 end
    boss.Current = {
        CoinId = coinId,
        SpawnGeneration = boss.SpawnGeneration,
        SpawnedAt = now,
        SelectableAt = nil,
        JoinQueuedAt = nil,
        JoinSentAt = nil,
        JoinAcceptedAt = nil,
        RemovedAt = nil,
        Source = tostring(info.Source or "unknown"),
        Fallback = not direct,
        PayloadComplete = info.PayloadComplete == true,
        Dispatched = {},
    }

    local context = run.Context
    if context and type(context.OnBossSpawnReady) == "function" then
        local ok, accepted = pcall(context.OnBossSpawnReady, info, boss.SpawnGeneration)
        if not ok or accepted == false then
            boss.MissedBeforeDispatch = boss.MissedBeforeDispatch + 1
            return false, ok and "spawn not selectable" or tostring(accepted), boss.SpawnGeneration
        end
    end
    return true, nil, boss.SpawnGeneration
end

local function bossRemoved(rawCoinId, source)
    local coinId = tostring(rawCoinId)
    if boss.CoinId ~= coinId or boss.State == "ABSENT" or boss.State == "DEAD" then return false end
    local now = os.clock()
    boss.State = "DEAD"
    boss.LastRemovedAt = now
    bossSample(boss.Current, now, source)
    local generation = boss.SpawnGeneration
    local context = run.Context
    if context and type(context.OnBossRemoved) == "function" then
        pcall(context.OnBossRemoved, coinId, generation, source)
    end
    boss.State = "ABSENT"
    return true, generation
end

local function percentile(values, ratio)
    if #values == 0 then return 0 end
    table.sort(values)
    return values[math.max(1, math.min(#values, math.ceil(#values * ratio)))] or 0
end

local function bossStats()
    local selectable, queued, ack, respawn, lifetime = {}, {}, {}, {}, {}
    local previousRemovedAt
    for offset = 0, boss.RingCount - 1 do
        local index = ((boss.RingHead - boss.RingCount + offset - 1) % 64) + 1
        local item = boss.Ring[index]
        if item then
            local spawned = tonumber(item.SpawnedAt) or 0
            if item.SelectableAt then selectable[#selectable + 1] = math.max(item.SelectableAt - spawned, 0) end
            if item.JoinQueuedAt then queued[#queued + 1] = math.max(item.JoinQueuedAt - spawned, 0) end
            if item.JoinSentAt and item.JoinAcceptedAt then
                ack[#ack + 1] = math.max(item.JoinAcceptedAt - item.JoinSentAt, 0)
            end
            if item.Lifetime then lifetime[#lifetime + 1] = item.Lifetime end
            if previousRemovedAt and spawned >= previousRemovedAt then
                respawn[#respawn + 1] = spawned - previousRemovedAt
            end
            previousRemovedAt = tonumber(item.RemovedAt) or previousRemovedAt
        end
    end
    local first, last
    for _, item in pairs(boss.Ring) do
        if item and item.RemovedAt then
            first = math.min(first or item.RemovedAt, item.RemovedAt)
            last = math.max(last or item.RemovedAt, item.RemovedAt)
        end
    end
    local minutes = first and last and math.max((last - first) / 60, 1 / 60) or 0
    local function summary(values)
        return {
            P50 = percentile(table.clone(values), 0.50),
            P95 = percentile(table.clone(values), 0.95),
            Max = #values > 0 and math.max(table.unpack(values)) or 0,
        }
    end
    return {
        State = boss.State,
        CoinId = boss.CoinId,
        SpawnGeneration = boss.SpawnGeneration,
        SpawnsSeen = boss.SpawnsSeen,
        DirectSpawns = boss.DirectSpawns,
        FallbackSpawns = boss.FallbackSpawns,
        DuplicateSpawns = boss.DuplicateSpawns,
        JoinsSent = boss.JoinsSent,
        JoinsAccepted = boss.JoinsAccepted,
        MissedBeforeDispatch = boss.MissedBeforeDispatch,
        RingCount = boss.RingCount,
        CyclesPerMinute = minutes > 0 and boss.RingCount / minutes or 0,
        NewToSelectable = summary(selectable),
        NewToQueued = summary(queued),
        SendToAck = summary(ack),
        RemoveToNew = summary(respawn),
        Lifetime = summary(lifetime),
    }
end

local pump

local function trace(stage, detail)
    local context = run.Context
    if context and type(context.Trace) == "function" then
        pcall(context.Trace, stage, detail)
    end
end

local function inspectTransition(requestId, stateName, detail)
    local context = run.Context
    if context and type(context.InspectorTransition) == "function" then
        pcall(context.InspectorTransition, "Farm", requestId, stateName, detail)
    end
end

local function inspectComplete(requestId, outcome, detail)
    local context = run.Context
    if context and type(context.InspectorComplete) == "function" then
        pcall(context.InspectorComplete, "Farm", requestId, outcome, detail)
    end
end

local function queueSize()
    return math.max(#run.Queue - run.Head + 1, 0)
end

local function compactQueue()
    if run.Head <= 16 or run.Head <= #run.Queue / 2 then return end
    local write = 1
    local size = #run.Queue
    for index = run.Head, size do
        local job = run.Queue[index]
        if job then
            run.Queue[write] = job
            write = write + 1
        end
    end
    for index = size, write, -1 do run.Queue[index] = nil end
    run.Head = 1
end

local function clearTransportGate()
    table.clear(transportGate.Fire)
    table.clear(transportGate.Invoke)
    table.clear(transportGate.InFlight)
    table.clear(transportGate.InvokeHistory)
end

local function expiringMark(map, key, ttl)
    local timestamp = os.clock()
    map[key] = timestamp
    if ttl > 0 then
        local epoch = run.Epoch
        scheduler.delay(ttl, function()
            if run.Epoch == epoch and map[key] == timestamp then map[key] = nil end
        end)
    end
    return timestamp
end

local function clearPending(entries)
    for _, entry in ipairs(entries or {}) do
        if run.PendingByPet[entry.PetId] == entry.State then
            run.PendingByPet[entry.PetId] = nil
        end
    end
end

local function clearPendingEntry(entry)
    if not entry then return end
    if run.PendingByPet[entry.PetId] == entry.State then
        run.PendingByPet[entry.PetId] = nil
    end
end

local function acquireJob()
    local pool = run.JobPool
    local job = pool[#pool]
    if job then
        pool[#pool] = nil
    else
        job = {
            Entries = {},
            EntryPool = {},
            CurrentEntries = {},
            PetIds = {},
            Accepted = {},
            Rejected = {},
            SignalFailures = {},
            AcceptedMap = {},
            Wanted = {},
            Seen = {},
            StalePetIds = {},
        }
    end
    job.InUse = true
    return job
end

local function releaseJob(job)
    if type(job) ~= "table" or job.InUse ~= true then return end
    job.InUse = false
    job.Epoch = nil
    job.Record = nil
    job.CoinId = nil
    job.Attempt = nil
    job.Joined = nil
    job.BossGeneration = nil
    job.Due = nil
    job.DiagnosticId = nil
    job.QueuedAt = nil
    for _, entry in ipairs(job.EntryPool) do
        entry.PetId = nil
        entry.State = nil
    end
    for _, key in ipairs({
        "Entries", "CurrentEntries", "PetIds", "Accepted", "Rejected",
        "SignalFailures", "AcceptedMap", "Wanted", "Seen", "StalePetIds",
    }) do
        table.clear(job[key])
    end
    if #run.JobPool < 64 then run.JobPool[#run.JobPool + 1] = job end
end

local function resetQueue()
    run.Epoch = run.Epoch + 1
    boss.SpawnGeneration = boss.SpawnGeneration + 1
    boss.State = "ABSENT"
    boss.CoinId = nil
    boss.Current = nil
    for index = run.Head, #run.Queue do
        local job = run.Queue[index]
        if job then
            if job.DiagnosticId then
                inspectComplete(job.DiagnosticId, "CANCELLED_BY_DISABLE", "pet transport queue reset")
            end
            clearPending(job.Entries)
            releaseJob(job)
        end
    end
    for _, job in ipairs(run.Delayed) do
        if job.DiagnosticId then
            inspectComplete(job.DiagnosticId, "CANCELLED_BY_DISABLE", "pet transport retry reset")
        end
        clearPending(job.Entries)
        releaseJob(job)
    end
    table.clear(run.Queue)
    run.Head = 1
    table.clear(run.Delayed)
    run.RetryToken = run.RetryToken + 1
    run.RetryDue = nil
    table.clear(run.PendingByPet)
    table.clear(run.ActiveInvokes)
    run.NextLaunchAt = 0
    clearTransportGate()
end

local function clearBossHistory()
    boss.State = "ABSENT"
    boss.CoinId = nil
    boss.Current = nil
    boss.LastRemovedAt = 0
    boss.RingHead = 1
    boss.RingCount = 0
    boss.SpawnsSeen = 0
    boss.DirectSpawns = 0
    boss.FallbackSpawns = 0
    boss.DuplicateSpawns = 0
    boss.JoinsSent = 0
    boss.JoinsAccepted = 0
    boss.MissedBeforeDispatch = 0
    table.clear(boss.Ring)
end

local function resetStats()
    run.Accepted = 0
    run.Rejected = 0
    run.Errors = 0
    run.Retries = 0
    run.Stale = 0
    run.Dropped = 0
    run.AverageRTT = 0
    run.LastRTT = 0
    run.LastProblem = "none"
    run.TargetSignals = 0
    run.FarmSignals = 0
    run.SignalFailures = 0
    run.TransportFailures = 0
    run.JoinInvokes = 0
    run.TransportSuppressed = 0
    run.TransportCoalesced = 0
    run.LocalTimeouts = 0
    run.LastRoute = "unavailable"
    run.LastAssignmentAt = 0
    run.LastTargetChangeAt = 0
end

local function contextActive(job)
    local context = run.Context
    if not context or job.Epoch ~= run.Epoch then return false end
    if type(context.Running) == "function" and not context.Running() then return false end
    if type(context.Enabled) == "function" and not context.Enabled() then return false end
    if type(context.Resetting) == "function" and context.Resetting() then return false end
    if type(context.RecordAlive) == "function" and not context.RecordAlive(job.Record) then
        return false
    end
    if job.BossGeneration ~= nil
        and not bossGenerationCurrent(job.CoinId, job.BossGeneration) then
        return false
    end
    return true
end

local function entryCurrent(entry)
    local context = run.Context
    return context and type(context.StateCurrent) == "function"
        and context.StateCurrent(entry.PetId, entry.State)
end

local function currentEntries(job)
    local entries, ids = job.CurrentEntries, job.PetIds
    table.clear(entries)
    table.clear(ids)
    if not contextActive(job) then return entries, ids end
    for _, entry in ipairs(job.Entries or {}) do
        if entryCurrent(entry) then
            entries[#entries + 1] = entry
            ids[#ids + 1] = entry.PetId
        else
            clearPendingEntry(entry)
        end
    end
    return entries, ids
end

local function finishInvoke(gateKey, entry, success, payload, route)
    entry.done = true
    entry.success = success == true
    entry.response = payload
    entry.route = route
    if transportGate.InFlight[gateKey] == entry then
        transportGate.InFlight[gateKey] = nil
    end
    if transportGate.Invoke[gateKey] == entry.timestamp then
        transportGate.Invoke[gateKey] = nil
    end
end

local function preferredCommand(context, command)
    if context and type(context.CommandRouteCandidates) == "function" then
        local ok, candidates = pcall(context.CommandRouteCandidates, command)
        if ok and type(candidates) == "table"
            and type(candidates[1]) == "string" and candidates[1] ~= "" then
            return candidates[1]
        end
    end
    return command
end

local function transportInvokeCommand(command, ...)
    local gateKey = transportKey(command, ...)
    local ttl = tonumber(TRANSPORT_TTL[command]) or 0.15
    local inflight = transportGate.InFlight[gateKey]
    if inflight then
        run.TransportCoalesced = run.TransportCoalesced + 1
        while not inflight.done and os.clock() - inflight.start < 8 do
            task.wait(0.01)
        end
        if inflight.done then
            return inflight.success, inflight.response, inflight.route or "coalesced invoke"
        end
        return false, "identical invoke is still in flight", "coalesced in-flight"
    end

    local entry = {start = os.clock(), done = false}
    entry.timestamp = expiringMark(transportGate.Invoke, gateKey, math.max(ttl, 0.15))
    transportGate.InFlight[gateKey] = entry
    local context = run.Context
    if context and type(context.GetCommandRemote) == "function" then
        local resolved, remote = pcall(context.GetCommandRemote, command)
        if resolved and typeof(remote) == "Instance" and remote:IsA("RemoteFunction") then
            local invoked, payload = pcall(remote.InvokeServer, remote, ...)
            if invoked then
                finishInvoke(gateKey, entry, true, payload, "direct named remote")
                return true, payload, "direct named remote"
            end
            if type(context.InvalidateCommand) == "function" then
                pcall(context.InvalidateCommand, command, remote)
            end
        end
    end

    if context and type(context.GetCommandBridge) == "function" then
        local resolved, bridge = pcall(context.GetCommandBridge, command)
        if resolved and typeof(bridge) == "Instance" and bridge:IsA("BindableFunction") then
            local invoked, payload = pcall(bridge.Invoke, bridge, ...)
            if invoked then
                finishInvoke(gateKey, entry, true, payload, "native Network4 bridge")
                return true, payload, "native Network4 bridge"
            end
        end
    end

    if context and context.NoNamedFallback == true then
        finishInvoke(gateKey, entry, false, "native Network4 invoke route unavailable", "none")
        return false, "native Network4 invoke route unavailable", "none"
    end

    local network = context and type(context.NetworkReady) == "function"
        and context.NetworkReady() or nil
    if not network or type(network.Invoke) ~= "function" then
        finishInvoke(gateKey, entry, false, "Library.Network.Invoke unavailable", "none")
        return false, "Library.Network.Invoke unavailable", "none"
    end

    -- Direct hashed resolution is preferred. If it is unavailable, call the
    -- current game name first (for example Join The Coin), never the stale
    -- logical alias that can leave Library.Network.Invoke yielding forever.
    local routedCommand = preferredCommand(context, command)
    local fallbackRoute = "Library.Network.Invoke [" .. tostring(routedCommand) .. "]"
    local invoked, payload = pcall(network.Invoke, routedCommand, ...)
    if not invoked then
        finishInvoke(gateKey, entry, false, payload, fallbackRoute)
        return false, payload, fallbackRoute
    end
    finishInvoke(gateKey, entry, true, payload, fallbackRoute)
    return true, payload, fallbackRoute
end

local function transportFireCommand(command, ...)
    local gateKey = transportKey(command, ...)
    local now = os.clock()
    local ttl = tonumber(TRANSPORT_TTL[command]) or 0.08

    if ttl > 0 and transportGate.Fire[gateKey] and now - transportGate.Fire[gateKey] < ttl then
        run.TransportSuppressed = run.TransportSuppressed + 1
        return true, "coalesced"
    end

    local timestamp = expiringMark(transportGate.Fire, gateKey, ttl)
    local function failed(problem)
        if transportGate.Fire[gateKey] == timestamp then transportGate.Fire[gateKey] = nil end
        return false, problem
    end
    local context = run.Context
    if context and type(context.GetFireRemote) == "function" then
        local resolved, remote = pcall(context.GetFireRemote, command)
        if resolved and typeof(remote) == "Instance" and remote:IsA("RemoteEvent") then
            local fired = pcall(remote.FireServer, remote, ...)
            if fired then
                return true, "direct named remote"
            end
            if type(context.InvalidateFire) == "function" then
                pcall(context.InvalidateFire, command, remote)
            end
        end
    end

    if context and type(context.GetFireBridge) == "function" then
        local resolved, bridge = pcall(context.GetFireBridge, command)
        if resolved and typeof(bridge) == "Instance" and bridge:IsA("BindableEvent") then
            local fired = pcall(bridge.Fire, bridge, ...)
            if fired then return true, "native Network4 bridge" end
        end
    end

    if context and context.NoNamedFallback == true then
        return failed("native Network4 fire route unavailable")
    end

    local network = context and type(context.NetworkReady) == "function"
        and context.NetworkReady() or nil
    if not network or type(network.Fire) ~= "function" then
        return failed("Library.Network.Fire unavailable")
    end
    local routedCommand = preferredCommand(context, command)
    local fallbackRoute = "Library.Network.Fire [" .. tostring(routedCommand) .. "]"
    local fired, problem = pcall(network.Fire, routedCommand, ...)
    if not fired then return failed(tostring(problem)) end
    return true, fallbackRoute
end

local function callNamedInvoke(command, ...)
    local success, response, route = transportInvokeCommand(command, ...)
    return success, response, route
end

local function callNamedFire(command, ...)
    return transportFireCommand(command, ...)
end

local function normalizedPetId(value)
    if value == nil then return nil end
    if type(value) == "table" then
        value = value.uid or value.id or value.PetId or value.petId
    end
    return value ~= nil and tostring(value) or nil
end

local function collectAccepted(value, wanted, accepted, seen, depth)
    if type(value) ~= "table" or depth > 3 or seen[value] then return end
    seen[value] = true
    for key, item in pairs(value) do
        local keyId = tostring(key)
        if wanted[keyId] and item ~= false then accepted[keyId] = true end
        local itemId = normalizedPetId(item)
        if itemId and wanted[itemId] then accepted[itemId] = true end
        if type(item) == "table" then
            collectAccepted(item, wanted, accepted, seen, depth + 1)
        end
    end
end

local function classifyResponseInto(response, petIds, accepted, wanted, seen)
    table.clear(accepted)
    table.clear(wanted)
    table.clear(seen)
    if response == true then
        for _, petId in ipairs(petIds or {}) do
            accepted[tostring(petId)] = true
        end
        return accepted
    end
    for _, petId in ipairs(petIds or {}) do wanted[tostring(petId)] = true end
    collectAccepted(response, wanted, accepted, seen, 0)
    return accepted
end

local function classifyResponse(response, petIds)
    return classifyResponseInto(response, petIds, {}, {}, {})
end

local function leaveStale(job, entries)
    if #entries == 0 then return end
    local petIds = job.StalePetIds
    table.clear(petIds)
    for _, entry in ipairs(entries) do
        -- Never let an old completion detach a newer assignment that reused
        -- the same UID while this request was yielding.
        if entryCurrent(entry) then petIds[#petIds + 1] = entry.PetId end
    end
    if #petIds == 0 then return end
    run.Stale = run.Stale + #petIds
    local context = run.Context
    if context and type(context.OnStaleAccepted) == "function" then
        pcall(context.OnStaleAccepted, job.Record, petIds)
    else
        callNamedInvoke("Leave Coin", job.CoinId, petIds)
    end
end

local function failEntries(job, entries, reason)
    local context = run.Context
    for _, entry in ipairs(entries) do
        if entryCurrent(entry) and context and type(context.OnFailed) == "function" then
            pcall(
                context.OnFailed,
                entry.PetId,
                entry.State,
                job.Record,
                reason,
                job.Attempt
            )
        end
    end
    clearPending(entries)
end

local function scheduleRetryTimer()
    if #run.Delayed == 0 then
        run.RetryDue = nil
        return
    end
    local earliest = math.huge
    for _, job in ipairs(run.Delayed) do earliest = math.min(earliest, job.Due) end
    if run.RetryDue and run.RetryDue <= earliest then return end

    run.RetryDue = earliest
    run.RetryToken = run.RetryToken + 1
    local token, epoch = run.RetryToken, run.Epoch
    scheduler.delay(math.max(earliest - os.clock(), 0), function()
        if token ~= run.RetryToken or epoch ~= run.Epoch then return end
        run.RetryDue = nil
        local now = os.clock()
        local size, write = #run.Delayed, 1
        for read = 1, size do
            local job = run.Delayed[read]
            if job.Epoch ~= run.Epoch then
                clearPending(job.Entries)
                releaseJob(job)
            elseif job.Due <= now then
                job.Due = nil
                run.Queue[#run.Queue + 1] = job
            else
                run.Delayed[write] = job
                write = write + 1
            end
        end
        for index = size, write, -1 do run.Delayed[index] = nil end
        pump()
        scheduleRetryTimer()
    end)
end

local function scheduleRetry(job, entries, reason, joined)
    if #entries == 0 then return false end
    if not contextActive(job) then
        clearPending(entries)
        return false
    end

    local current = job.Entries
    table.clear(current)
    for _, entry in ipairs(entries) do
        if entryCurrent(entry) then
            current[#current + 1] = entry
        else
            clearPendingEntry(entry)
        end
    end
    entries = current
    if #entries == 0 then return false end

    local context = run.Context
    if context and type(context.ShouldRetry) == "function" then
        local checked, shouldRetry = pcall(
            context.ShouldRetry,
            job.Record,
            reason,
            job.Attempt,
            entries
        )
        if checked and shouldRetry == false then
            failEntries(job, entries, reason)
            return false
        end
    end
    if job.Attempt >= MAX_JOIN_ATTEMPTS then
        failEntries(job, entries, reason)
        return false
    end
    if queueSize() + #run.Delayed >= MAX_QUEUED_JOBS then
        run.Dropped = run.Dropped + #entries
        failEntries(job, entries, "bounded retry queue is full")
        return false
    end

    run.Retries = run.Retries + #entries
    local nextAttempt = job.Attempt + 1
    if context and type(context.OnRetry) == "function" then
        for _, entry in ipairs(entries) do
            pcall(
                context.OnRetry,
                entry.PetId,
                entry.State,
                job.Record,
                reason,
                nextAttempt
            )
        end
    end
    job.Attempt = nextAttempt
    job.Joined = joined == true
    job.Due = os.clock() + RETRY_DELAY
    inspectTransition(job.DiagnosticId, "QUEUED", {
        attempt = nextAttempt,
        reason = reason,
        delay = RETRY_DELAY,
    })
    run.Delayed[#run.Delayed + 1] = job
    scheduleRetryTimer()
    return true
end

local function signalEntries(job, entries, route)
    local failed = job.SignalFailures
    table.clear(failed)
    local context = run.Context
    for _, entry in ipairs(entries) do
        if entryCurrent(entry) then
            local targetSent, targetRoute = callNamedFire(
                "Change Pet Target",
                entry.PetId,
                "Coin",
                job.CoinId
            )
            local farmSent, farmRoute = callNamedFire(
                "Farm Coin",
                job.CoinId,
                entry.PetId
            )
            if targetSent then
                run.TargetSignals = run.TargetSignals + 1
                run.LastTargetChangeAt = os.clock()
            end
            if farmSent then run.FarmSignals = run.FarmSignals + 1 end
            if context and type(context.OnSignalsSent) == "function" then
                pcall(
                    context.OnSignalsSent,
                    entry.PetId,
                    entry.State,
                    job.Record,
                    targetSent,
                    farmSent,
                    targetRoute,
                    farmRoute
                )
            end
            local accepted = targetSent and farmSent
            if accepted and context and type(context.OnAccepted) == "function" then
                local called, result = pcall(
                    context.OnAccepted,
                    entry.PetId,
                    entry.State,
                    job.Record,
                    nil,
                    job.Attempt,
                    route
                )
                accepted = called and result ~= false
            end
            if accepted then
                run.Accepted = run.Accepted + 1
                run.LastAssignmentAt = os.clock()
                clearPendingEntry(entry)
            else
                run.SignalFailures = run.SignalFailures + 1
                failed[#failed + 1] = entry
            end
        else
            clearPendingEntry(entry)
        end
    end
    return failed
end

local function process(job)
    local entries, petIds = currentEntries(job)
    if #entries == 0 then
        failEntries(job, job.Entries, "target stale before Join Coin")
        return false
    end

    if job.Joined then
        local failures = signalEntries(job, entries, "accepted join retry")
        if #failures > 0 then
            run.Errors = run.Errors + #failures
            run.LastProblem = "post-join signal failure"
            return scheduleRetry(job, failures, run.LastProblem, true)
        end
        return false
    end

    local startedAt = os.clock()
    if job.BossGeneration ~= nil and bossGenerationCurrent(job.CoinId, job.BossGeneration) then
        boss.State = "JOINING"
        boss.JoinsSent = boss.JoinsSent + 1
        if boss.Current then boss.Current.JoinSentAt = startedAt end
    end
    run.LastDispatchAt = startedAt
    local attemptId = tostring(job.DiagnosticId) .. ":attempt:" .. tostring(job.Attempt)
    inspectTransition(attemptId, "INVOKE_IN_FLIGHT", {
        command = "Join Coin",
        coin = job.CoinId,
        pets = #petIds,
        queuedFor = math.max(startedAt - (tonumber(job.QueuedAt) or startedAt), 0),
    })
    run.ActiveInvokes[attemptId] = startedAt
    run.JoinInvokes = run.JoinInvokes + 1
    local invoked, response, route = callNamedInvoke("Join Coin", job.CoinId, petIds)
    run.ActiveInvokes[attemptId] = nil
    local elapsed = math.max(os.clock() - startedAt, 0)
    run.LastRTT = elapsed
    run.AverageRTT = run.AverageRTT == 0 and elapsed
        or run.AverageRTT * 0.85 + elapsed * 0.15
    run.LastRoute = tostring(route or "unavailable")

    if not invoked then
        inspectComplete(attemptId, "TRANSPORT_FAILED", tostring(response))
        run.TransportFailures = run.TransportFailures + 1
        run.Errors = run.Errors + #entries
        run.LastProblem = "Join Coin transport error: " .. tostring(response)
        return scheduleRetry(job, entries, run.LastProblem, false)
    end
    run.LastCompletionAt = os.clock()

    local acceptedMap = classifyResponseInto(
        response,
        petIds,
        job.AcceptedMap,
        job.Wanted,
        job.Seen
    )
    local acceptedEntries, rejectedEntries = job.Accepted, job.Rejected
    table.clear(acceptedEntries)
    table.clear(rejectedEntries)
    for _, entry in ipairs(entries) do
        if acceptedMap[entry.PetId] then
            acceptedEntries[#acceptedEntries + 1] = entry
        else
            rejectedEntries[#rejectedEntries + 1] = entry
        end
    end

    if #acceptedEntries == #entries then
        inspectComplete(attemptId, "SERVER_ACCEPTED", "accepted pets=" .. tostring(#acceptedEntries))
    elseif #acceptedEntries == 0 then
        inspectComplete(attemptId, "SERVER_REJECTED", "rejected pets=" .. tostring(#rejectedEntries))
    else
        inspectComplete(attemptId, "COMPLETED", "partial accepted=" .. tostring(#acceptedEntries)
            .. " rejected=" .. tostring(#rejectedEntries))
    end

    if #rejectedEntries > 0 then
        run.Rejected = run.Rejected + #rejectedEntries
        run.LastProblem = "Join Coin rejected " .. tostring(#rejectedEntries) .. " pet(s)"
        -- A server reject is terminal for this spawn generation. Release the
        -- caller's JOINING states before bossRemoved invalidates the job.
        -- There is no retry and no recovery request for the rejected target.
        failEntries(job, rejectedEntries, run.LastProblem)
    end

    if #acceptedEntries > 0 and job.BossGeneration ~= nil
        and bossGenerationCurrent(job.CoinId, job.BossGeneration) then
        boss.State = "ACTIVE"
        boss.JoinsAccepted = boss.JoinsAccepted + 1
        if boss.Current then boss.Current.JoinAcceptedAt = os.clock() end
    elseif #rejectedEntries > 0 and job.BossGeneration ~= nil
        and bossGenerationCurrent(job.CoinId, job.BossGeneration) then
        bossRemoved(job.CoinId, "server reject")
    end

    if not contextActive(job) then
        local context = run.Context
        local recordStillAlive = context and type(context.RecordAlive) == "function"
            and context.RecordAlive(job.Record)
        if recordStillAlive then leaveStale(job, acceptedEntries) end
        failEntries(job, acceptedEntries, "target stale after Join Coin")
        return false
    end

    local signalFailures = signalEntries(job, acceptedEntries, route)
    if #signalFailures > 0 then
        run.Errors = run.Errors + #signalFailures
        run.LastProblem = "post-join signal failure"
    end
    if #rejectedEntries == 0 and #signalFailures == 0 then
        run.LastProblem = "none"
    end
    if #signalFailures > 0 then
        return scheduleRetry(job, signalFailures, run.LastProblem, true)
    end
    return false
end

local function executeJob(job)
    if not contextActive(job) then
        failEntries(job, job.Entries, "target stale before dispatch")
        if job.DiagnosticId then
            inspectComplete(job.DiagnosticId, "LOCAL_CANCELLED_REMOTE_UNKNOWN",
                "target stale before dispatch; pet reservations released")
        end
        releaseJob(job)
        run.Active = math.max(run.Active - 1, 0)
        pump()
        return
    end
    local thread = coroutine.create(function()
        local handled, retained = pcall(process, job)
        if not handled then
            run.Errors = run.Errors + 1
            run.LastProblem = tostring(retained)
            local current = currentEntries(job)
            retained = scheduleRetry(
                job,
                current,
                "dispatch call failed: " .. tostring(run.LastProblem),
                job.Joined
            )
            trace("lite pet dispatch", tostring(run.LastProblem))
        end
        if not retained then
            inspectComplete(job.DiagnosticId,
                handled and "COMPLETED" or "DROPPED_WITH_REASON",
                handled and "pet transport cycle finished" or tostring(run.LastProblem))
            releaseJob(job)
        end
        run.Active = math.max(run.Active - 1, 0)
        pump()
    end)
    local resumed, problem = coroutine.resume(thread)
    if resumed then return end
    run.Errors = run.Errors + 1
    run.LastProblem = tostring(problem)
    run.Active = math.max(run.Active - 1, 0)
    local current = currentEntries(job)
    local retained = scheduleRetry(
        job,
        current,
        "dispatch coroutine failed: " .. tostring(problem),
        job.Joined
    )
    if not retained then
        inspectComplete(job.DiagnosticId, "DROPPED_WITH_REASON", tostring(problem))
        releaseJob(job)
    end
    trace("lite pet dispatch", tostring(problem))
    pump()
end

pump = function()
    compactQueue()
    while run.Context and run.Active < run.Limit and run.Head <= #run.Queue do
        local job = run.Queue[run.Head]
        run.Queue[run.Head] = false
        run.Head = run.Head + 1
        if contextActive(job) then
            run.Active = run.Active + 1
            if job.BossGeneration ~= nil then
                -- Boss jobs already represent one authoritative New Coin
                -- generation. Run immediately; do not add a retry timer or a
                -- second scheduler turn before the single grouped Join Coin.
                executeJob(job)
            else
                local now = os.clock()
                local context = run.Context
                local spacing = math.clamp(tonumber(context.DispatchSpacing) or 0.012, 0.01, 0.015)
                if run.NextLaunchAt <= now then
                    local phase = math.clamp(tonumber(context.DispatchPhaseOffset) or 0, 0, 0.015)
                    run.NextLaunchAt = now + phase
                end
                local due = run.NextLaunchAt
                run.NextLaunchAt = due + spacing
                scheduler.delay(math.max(due - now, 0), function()
                    executeJob(job)
                end)
            end
        else
            failEntries(job, job.Entries, "target stale in dispatch queue")
            if job.DiagnosticId then
                inspectComplete(job.DiagnosticId, "LOCAL_CANCELLED_REMOTE_UNKNOWN",
                    "target stale in dispatch queue; pet reservations released")
            end
            releaseJob(job)
        end
    end
    compactQueue()
end

local function start(context)
    if type(context) ~= "table" then return false, "context table required" end
    resetQueue()
    resetStats()
    run.Context = context
    local requested = math.floor(tonumber(context.DispatchWidth) or DEFAULT_DISPATCH_WIDTH)
    run.Limit = math.max(1, math.min(requested, DEFAULT_DISPATCH_WIDTH))
    return true
end

local function setLimit(value)
    local requested = math.floor(tonumber(value) or DEFAULT_DISPATCH_WIDTH)
    run.Limit = math.max(0, math.min(requested, DEFAULT_DISPATCH_WIDTH))
    pump()
    return run.Limit
end

local function dispatch(payload)
    if not run.Context then return false, "engine is not started" end
    if type(payload) ~= "table" or type(payload.Entries) ~= "table" then
        return false, "dispatch payload is invalid"
    end
    local requestedBossGeneration = tonumber(payload.BossGeneration)
    if requestedBossGeneration ~= nil
        and not bossGenerationCurrent(payload.CoinId, requestedBossGeneration) then
        return false, "stale boss generation"
    end

    local job = acquireJob()
    local entries = job.Entries
    local entryCount = 0
    for _, entry in ipairs(payload.Entries) do
        if type(entry) == "table" and entry.PetId ~= nil and entry.State ~= nil then
            local petId = tostring(entry.PetId)
            local pending = run.PendingByPet[petId]
            local context = run.Context
            if pending and context and type(context.StateCurrent) == "function"
                and not context.StateCurrent(petId, pending) then
                run.PendingByPet[petId] = nil
                pending = nil
            end
            if not pending then
                entryCount = entryCount + 1
                local queuedEntry = job.EntryPool[entryCount]
                if not queuedEntry then
                    queuedEntry = {}
                    job.EntryPool[entryCount] = queuedEntry
                end
                queuedEntry.PetId = petId
                queuedEntry.State = entry.State
                entries[entryCount] = queuedEntry
                run.PendingByPet[petId] = entry.State
            end
        end
    end
    if #entries == 0 then
        releaseJob(job)
        return false, "dispatch has no free current pets"
    end
    if queueSize() + #run.Delayed >= MAX_QUEUED_JOBS then
        run.Dropped = run.Dropped + #entries
        clearPending(entries)
        releaseJob(job)
        return false, "bounded dispatch queue is full"
    end

    job.Epoch = run.Epoch
    job.Record = payload.Record
    job.CoinId = tostring(payload.CoinId)
    job.Attempt = 1
    job.Joined = false
    job.BossGeneration = requestedBossGeneration
    run.DiagnosticSequence = run.DiagnosticSequence + 1
    job.DiagnosticId = "join:" .. tostring(run.Epoch) .. ":" .. tostring(run.DiagnosticSequence)
    job.QueuedAt = os.clock()
    if job.BossGeneration ~= nil and bossGenerationCurrent(job.CoinId, job.BossGeneration) then
        boss.State = "JOINING"
        if boss.Current then
            boss.Current.SelectableAt = tonumber(payload.SelectableAt) or job.QueuedAt
            boss.Current.JoinQueuedAt = job.QueuedAt
            for _, entry in ipairs(entries) do
                boss.Current.Dispatched[tostring(entry.PetId)] = true
            end
        end
    end
    inspectTransition(job.DiagnosticId, "QUEUED", {
        command = "Join Coin",
        coin = job.CoinId,
        pets = #entries,
    })
    run.Queue[#run.Queue + 1] = job
    pump()
    return true
end

local function stats()
    local now, activeInvokeCount, oldestInvokeAge = os.clock(), 0, 0
    for _, startedAt in pairs(run.ActiveInvokes) do
        activeInvokeCount = activeInvokeCount + 1
        oldestInvokeAge = math.max(oldestInvokeAge, now - (tonumber(startedAt) or now))
    end
    local function mapSize(map)
        local count = 0
        for _ in pairs(map) do count = count + 1 end
        return count
    end
    return {
        Version = MODULE_VERSION,
        Epoch = run.Epoch,
        Active = run.Active,
        Queued = queueSize() + #run.Delayed,
        Delayed = #run.Delayed,
        Limit = run.Limit,
        PolicyMaxLanes = DEFAULT_DISPATCH_WIDTH,
        Accepted = run.Accepted,
        Rejected = run.Rejected,
        Errors = run.Errors,
        Retries = run.Retries,
        Stale = run.Stale,
        Dropped = run.Dropped,
        AverageRTT = run.AverageRTT,
        LastRTT = run.LastRTT,
        LastProblem = run.LastProblem,
        LastDispatchAt = run.LastDispatchAt,
        LastCompletionAt = run.LastCompletionAt,
        ActiveInvokeCount = activeInvokeCount,
        OldestInvokeAge = oldestInvokeAge,
        TargetSignals = run.TargetSignals,
        FarmSignals = run.FarmSignals,
        SignalFailures = run.SignalFailures,
        TransportFailures = run.TransportFailures,
        JoinInvokes = run.JoinInvokes,
        TransportSuppressed = run.TransportSuppressed,
        TransportCoalesced = run.TransportCoalesced,
        LocalTimeouts = run.LocalTimeouts,
        LastRoute = run.LastRoute,
        LastAssignmentAt = run.LastAssignmentAt,
        LastTargetChangeAt = run.LastTargetChangeAt,
        QueueCapacity = MAX_QUEUED_JOBS,
        TransportFireCache = mapSize(transportGate.Fire),
        TransportInvokeCache = mapSize(transportGate.Invoke),
        TransportInFlightCache = mapSize(transportGate.InFlight),
        TransportInvokeHistoryCache = mapSize(transportGate.InvokeHistory),
    }
end

return function(action, context, value)
    if action == "start" then return start(context) end
    if action == "dispatch" then return dispatch(value or context) end
    if action == "limit" then return setLimit(context) end
    if action == "pump" then pump(); return true end
    if action == "reset" then resetQueue(); return true end
    if action == "stop" then resetQueue(); clearBossHistory(); run.Context = nil; return true end
    if action == "stats" then return stats() end
    if action == "boss-spawn" then return bossSpawn(context) end
    if action == "boss-remove" then return bossRemoved(context, value) end
    if action == "boss-current" then return bossGenerationCurrent(context, value) end
    if action == "boss-stats" then return bossStats() end
    if action == "classify" then return classifyResponse(context, value) end
    if action == "retry-delay" then return RETRY_DELAY end
    if action == "version" then return MODULE_VERSION end
    return false, "unknown action"
end
