-- Lightweight, event-driven transport for PSX OG pet farming.
-- Target selection and lifetime locks belong to the caller. This module only
-- sends a bounded number of Join Coin requests and never polls game state.

local MODULE_VERSION = "1.0.0"
local DEFAULT_DISPATCH_WIDTH = 8
local MAX_QUEUED_JOBS = 32
local MAX_JOIN_ATTEMPTS = 2
local RETRY_DELAY = 0.25

local scheduler = task or {
    delay = function(_, callback)
        coroutine.wrap(callback)()
    end,
}

local run = {
    Context = nil,
    Epoch = 0,
    Queue = {},
    Head = 1,
    Delayed = {},
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
}

local pump

local function trace(stage, detail)
    local context = run.Context
    if context and type(context.Trace) == "function" then
        pcall(context.Trace, stage, detail)
    end
end

local function queueSize()
    return math.max(#run.Queue - run.Head + 1, 0)
end

local function compactQueue()
    if run.Head <= 16 or run.Head <= #run.Queue / 2 then return end
    local compacted = {}
    for index = run.Head, #run.Queue do
        local job = run.Queue[index]
        if job then compacted[#compacted + 1] = job end
    end
    run.Queue = compacted
    run.Head = 1
end

local function clearPending(entries)
    for _, entry in ipairs(entries or {}) do
        if run.PendingByPet[entry.PetId] == entry.State then
            run.PendingByPet[entry.PetId] = nil
        end
    end
end

local function resetQueue()
    run.Epoch = run.Epoch + 1
    run.Queue = {}
    run.Head = 1
    run.Delayed = {}
    run.RetryToken = run.RetryToken + 1
    run.RetryDue = nil
    table.clear(run.PendingByPet)
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
    return true
end

local function entryCurrent(entry)
    local context = run.Context
    return context and type(context.StateCurrent) == "function"
        and context.StateCurrent(entry.PetId, entry.State)
end

local function currentEntries(job)
    local entries, ids = {}, {}
    if not contextActive(job) then return entries, ids end
    for _, entry in ipairs(job.Entries or {}) do
        if entryCurrent(entry) then
            entries[#entries + 1] = entry
            ids[#ids + 1] = entry.PetId
        else
            clearPending({ entry })
        end
    end
    return entries, ids
end

local function callNamedInvoke(command, ...)
    local context = run.Context
    local arguments = table.pack(...)
    if context and type(context.GetCommandRemote) == "function" then
        local resolved, remote = pcall(context.GetCommandRemote, command)
        if resolved and typeof(remote) == "Instance" and remote:IsA("RemoteFunction") then
            local result = table.pack(pcall(function()
                return remote:InvokeServer(table.unpack(arguments, 1, arguments.n))
            end))
            if result[1] then return true, result[2], "direct named remote" end
            if type(context.InvalidateCommand) == "function" then
                pcall(context.InvalidateCommand, command, remote)
            end
        end
    end

    local network = context and type(context.NetworkReady) == "function"
        and context.NetworkReady() or nil
    if not network or type(network.Invoke) ~= "function" then
        return false, "Library.Network.Invoke unavailable", "none"
    end
    local result = table.pack(pcall(
        network.Invoke,
        command,
        table.unpack(arguments, 1, arguments.n)
    ))
    if not result[1] then return false, result[2], "Library.Network.Invoke" end
    return true, result[2], "Library.Network.Invoke"
end

local function callNamedFire(command, ...)
    local context = run.Context
    local arguments = table.pack(...)
    if context and type(context.GetFireRemote) == "function" then
        local resolved, remote = pcall(context.GetFireRemote, command)
        if resolved and typeof(remote) == "Instance" and remote:IsA("RemoteEvent") then
            local fired = pcall(function()
                remote:FireServer(table.unpack(arguments, 1, arguments.n))
            end)
            if fired then return true, "direct named remote" end
            if type(context.InvalidateFire) == "function" then
                pcall(context.InvalidateFire, command, remote)
            end
        end
    end

    local network = context and type(context.NetworkReady) == "function"
        and context.NetworkReady() or nil
    if not network or type(network.Fire) ~= "function" then
        return false, "Library.Network.Fire unavailable"
    end
    local fired, problem = pcall(
        network.Fire,
        command,
        table.unpack(arguments, 1, arguments.n)
    )
    return fired, fired and "Library.Network.Fire" or tostring(problem)
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

local function classifyResponse(response, petIds)
    local accepted = {}
    if response == true then
        for _, petId in ipairs(petIds or {}) do
            accepted[tostring(petId)] = true
        end
        return accepted
    end
    local wanted = {}
    for _, petId in ipairs(petIds or {}) do wanted[tostring(petId)] = true end
    collectAccepted(response, wanted, accepted, {}, 0)
    return accepted
end

local function leaveStale(job, entries)
    if #entries == 0 then return end
    local petIds = {}
    for _, entry in ipairs(entries) do petIds[#petIds + 1] = entry.PetId end
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
        local now, waiting = os.clock(), {}
        for _, job in ipairs(run.Delayed) do
            if job.Epoch ~= run.Epoch then
                clearPending(job.Entries)
            elseif job.Due <= now then
                job.Due = nil
                run.Queue[#run.Queue + 1] = job
            else
                waiting[#waiting + 1] = job
            end
        end
        run.Delayed = waiting
        pump()
        scheduleRetryTimer()
    end)
end

local function scheduleRetry(job, entries, reason, joined)
    if #entries == 0 then return end
    if not contextActive(job) then
        clearPending(entries)
        return
    end

    local current = {}
    for _, entry in ipairs(entries) do
        if entryCurrent(entry) then
            current[#current + 1] = entry
        else
            clearPending({ entry })
        end
    end
    entries = current
    if #entries == 0 then return end

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
            return
        end
    end
    if job.Attempt >= MAX_JOIN_ATTEMPTS then
        failEntries(job, entries, reason)
        return
    end
    if queueSize() + #run.Delayed >= MAX_QUEUED_JOBS then
        run.Dropped = run.Dropped + #entries
        failEntries(job, entries, "bounded retry queue is full")
        return
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
    run.Delayed[#run.Delayed + 1] = {
        Epoch = job.Epoch,
        Record = job.Record,
        CoinId = job.CoinId,
        Entries = entries,
        Attempt = nextAttempt,
        Joined = joined == true,
        Due = os.clock() + RETRY_DELAY,
    }
    scheduleRetryTimer()
end

local function signalEntries(job, entries, route)
    local failed = {}
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
                clearPending({ entry })
            else
                failed[#failed + 1] = entry
            end
        else
            clearPending({ entry })
        end
    end
    return failed
end

local function process(job)
    local entries, petIds = currentEntries(job)
    if #entries == 0 then
        clearPending(job.Entries)
        return
    end

    if job.Joined then
        local failures = signalEntries(job, entries, "accepted join retry")
        if #failures > 0 then
            run.Errors = run.Errors + #failures
            run.LastProblem = "post-join signal failure"
            scheduleRetry(job, failures, run.LastProblem, true)
        end
        return
    end

    local startedAt = os.clock()
    local invoked, response, route = callNamedInvoke("Join Coin", job.CoinId, petIds)
    local elapsed = math.max(os.clock() - startedAt, 0)
    run.LastRTT = elapsed
    run.AverageRTT = run.AverageRTT == 0 and elapsed
        or run.AverageRTT * 0.85 + elapsed * 0.15

    if not invoked then
        run.Errors = run.Errors + #entries
        run.LastProblem = "Join Coin transport error: " .. tostring(response)
        scheduleRetry(job, entries, run.LastProblem, false)
        return
    end

    local acceptedMap = classifyResponse(response, petIds)
    local acceptedEntries, rejectedEntries = {}, {}
    for _, entry in ipairs(entries) do
        if acceptedMap[entry.PetId] then
            acceptedEntries[#acceptedEntries + 1] = entry
        else
            rejectedEntries[#rejectedEntries + 1] = entry
        end
    end

    if not contextActive(job) then
        leaveStale(job, acceptedEntries)
        clearPending(entries)
        return
    end

    local signalFailures = signalEntries(job, acceptedEntries, route)
    if #signalFailures > 0 then
        run.Errors = run.Errors + #signalFailures
        run.LastProblem = "post-join signal failure"
        scheduleRetry(job, signalFailures, run.LastProblem, true)
    end
    if #rejectedEntries > 0 then
        run.Rejected = run.Rejected + #rejectedEntries
        run.LastProblem = "Join Coin rejected " .. tostring(#rejectedEntries) .. " pet(s)"
        scheduleRetry(job, rejectedEntries, run.LastProblem, false)
    elseif #signalFailures == 0 then
        run.LastProblem = "none"
    end
end

pump = function()
    compactQueue()
    while run.Context and run.Active < run.Limit and run.Head <= #run.Queue do
        local job = run.Queue[run.Head]
        run.Queue[run.Head] = false
        run.Head = run.Head + 1
        if contextActive(job) then
            run.Active = run.Active + 1
            local thread = coroutine.create(function()
                local handled, problem = pcall(process, job)
                if not handled then
                    run.Errors = run.Errors + 1
                    run.LastProblem = tostring(problem)
                    local current = currentEntries(job)
                    scheduleRetry(
                        job,
                        current,
                        "dispatch call failed: " .. tostring(problem),
                        job.Joined
                    )
                    trace("lite pet dispatch", tostring(problem))
                end
                run.Active = math.max(run.Active - 1, 0)
                pump()
            end)
            local resumed, problem = coroutine.resume(thread)
            if not resumed then
                run.Errors = run.Errors + 1
                run.LastProblem = tostring(problem)
                run.Active = math.max(run.Active - 1, 0)
                local current = currentEntries(job)
                scheduleRetry(
                    job,
                    current,
                    "dispatch coroutine failed: " .. tostring(problem),
                    job.Joined
                )
                trace("lite pet dispatch", tostring(problem))
                pump()
            end
        else
            clearPending(job and job.Entries)
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

local function dispatch(payload)
    if not run.Context then return false, "engine is not started" end
    if type(payload) ~= "table" or type(payload.Entries) ~= "table" then
        return false, "dispatch payload is invalid"
    end

    local entries = {}
    for _, entry in ipairs(payload.Entries) do
        if type(entry) == "table" and entry.PetId ~= nil and entry.State ~= nil then
            local petId = tostring(entry.PetId)
            local pending = run.PendingByPet[petId]
            if pending and not entryCurrent({ PetId = petId, State = pending }) then
                run.PendingByPet[petId] = nil
                pending = nil
            end
            if not pending then
                entries[#entries + 1] = {
                    PetId = petId,
                    State = entry.State,
                }
                run.PendingByPet[petId] = entry.State
            end
        end
    end
    if #entries == 0 then return false, "dispatch has no free current pets" end
    if queueSize() + #run.Delayed >= MAX_QUEUED_JOBS then
        run.Dropped = run.Dropped + #entries
        clearPending(entries)
        return false, "bounded dispatch queue is full"
    end

    run.Queue[#run.Queue + 1] = {
        Epoch = run.Epoch,
        Record = payload.Record,
        CoinId = tostring(payload.CoinId),
        Entries = entries,
        Attempt = 1,
        Joined = false,
    }
    pump()
    return true
end

local function stats()
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
        QueueCapacity = MAX_QUEUED_JOBS,
    }
end

return function(action, context, value)
    if action == "start" then return start(context) end
    if action == "dispatch" then return dispatch(value or context) end
    if action == "pump" then pump(); return true end
    if action == "reset" then resetQueue(); return true end
    if action == "stop" then resetQueue(); run.Context = nil; return true end
    if action == "stats" then return stats() end
    if action == "classify" then return classifyResponse(context, value) end
    if action == "retry-delay" then return RETRY_DELAY end
    if action == "version" then return MODULE_VERSION end
    return false, "unknown action"
end
