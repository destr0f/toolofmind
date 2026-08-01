-- Lightweight, event-driven transport for PSX OG pet farming.
-- Target selection and lifetime locks belong to the caller. This module only
-- sends a bounded number of Join Coin requests and never polls game state.

local MODULE_VERSION = "1.2.1"
local DEFAULT_DISPATCH_WIDTH = 16
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
    job.Due = nil
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
    for index = run.Head, #run.Queue do
        local job = run.Queue[index]
        if job then clearPending(job.Entries); releaseJob(job) end
    end
    for _, job in ipairs(run.Delayed) do
        clearPending(job.Entries)
        releaseJob(job)
    end
    table.clear(run.Queue)
    run.Head = 1
    table.clear(run.Delayed)
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

local function callNamedInvoke(command, ...)
    local context = run.Context
    if not context or type(context.InvokeCommand) ~= "function" then
        return false, "NetworkRouteGovernor invoke is unavailable", "none"
    end
    local transported, _, problem, sourceName, sessionIndex, _, raw =
        context.InvokeCommand(command, ...)
    local route = type(context.RouteText) == "function"
        and context.RouteText(sourceName, sessionIndex)
        or tostring(sourceName or "NetworkRouteGovernor")
    if transported ~= true then return false, problem, route end
    return true, raw, route
end

local function callNamedFire(command, ...)
    local context = run.Context
    if not context or type(context.FireCommand) ~= "function" then
        return false, "NetworkRouteGovernor fire is unavailable"
    end
    local fired, problem, sourceName, sessionIndex = context.FireCommand(command, ...)
    local route = type(context.RouteText) == "function"
        and context.RouteText(sourceName, sessionIndex)
        or tostring(sourceName or problem or "NetworkRouteGovernor")
    return fired == true, fired and route or tostring(problem)
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
                clearPendingEntry(entry)
            else
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
        clearPending(job.Entries)
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
    local invoked, response, route = callNamedInvoke("Join Coin", job.CoinId, petIds)
    local elapsed = math.max(os.clock() - startedAt, 0)
    run.LastRTT = elapsed
    run.AverageRTT = run.AverageRTT == 0 and elapsed
        or run.AverageRTT * 0.85 + elapsed * 0.15

    if not invoked then
        run.Errors = run.Errors + #entries
        run.LastProblem = "Join Coin transport error: " .. tostring(response)
        return scheduleRetry(job, entries, run.LastProblem, false)
    end

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

    if not contextActive(job) then
        leaveStale(job, acceptedEntries)
        clearPending(entries)
        return false
    end

    local signalFailures = signalEntries(job, acceptedEntries, route)
    if #signalFailures > 0 then
        run.Errors = run.Errors + #signalFailures
        run.LastProblem = "post-join signal failure"
    end
    if #rejectedEntries > 0 then
        run.Rejected = run.Rejected + #rejectedEntries
        run.LastProblem = "Join Coin rejected " .. tostring(#rejectedEntries) .. " pet(s)"
        -- A successful InvokeServer transport followed by a rejected UID means
        -- the coin is stale or contended. Retrying the same coin only burns one
        -- more RTT and lets the pet drift back toward the player.
        if context and type(context.MarkStale) == "function" then
            pcall(context.MarkStale, "Join Coin", #rejectedEntries)
        end
        failEntries(job, rejectedEntries, run.LastProblem)
    elseif #signalFailures == 0 then
        run.LastProblem = "none"
    end
    if #signalFailures > 0 then
        return scheduleRetry(job, signalFailures, run.LastProblem, true)
    end
    return false
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
                if not retained then releaseJob(job) end
                run.Active = math.max(run.Active - 1, 0)
                pump()
            end)
            local resumed, problem = coroutine.resume(thread)
            if not resumed then
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
                if not retained then releaseJob(job) end
                trace("lite pet dispatch", tostring(problem))
                pump()
            end
        else
            clearPending(job and job.Entries)
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
    run.Queue[#run.Queue + 1] = job
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
    if action == "limit" then return setLimit(context) end
    if action == "pump" then pump(); return true end
    if action == "reset" then resetQueue(); return true end
    if action == "stop" then resetQueue(); run.Context = nil; return true end
    if action == "stats" then return stats() end
    if action == "classify" then return classifyResponse(context, value) end
    if action == "retry-delay" then return RETRY_DELAY end
    if action == "version" then return MODULE_VERSION end
    return false, "unknown action"
end
