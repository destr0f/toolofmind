-- Event-driven bounded transport for PSX OG pet farming.
-- The caller owns target selection and lock state. This module owns one queue,
-- one retry timer and a fixed number of concurrent yielding Network invokes.

local MODULE_VERSION = "3.0.0"
local DEFAULT_DISPATCH_WIDTH = 16
local MAX_QUEUED_JOBS = 64
local MAX_JOIN_ATTEMPTS = 3
local RETRY_DELAYS = { 0.05, 0.15 }
local scheduler = task or {
    delay = function(_, callback) coroutine.wrap(callback)() end,
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
    if run.Head <= 32 or run.Head <= #run.Queue / 2 then return end
    local compacted = {}
    for index = run.Head, #run.Queue do
        local job = run.Queue[index]
        if job then compacted[#compacted + 1] = job end
    end
    run.Queue = compacted
    run.Head = 1
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

local function clearPending(entries)
    for _, entry in ipairs(entries or {}) do
        if run.PendingByPet[entry.PetId] == entry.State then
            run.PendingByPet[entry.PetId] = nil
        end
    end
end

local function normalizedPetId(value)
    if value == nil then return nil end
    if type(value) == "table" then
        value = value.uid or value.id or value.PetId or value.petId
    end
    return value ~= nil and tostring(value) or nil
end

local function responseContainsPet(response, wanted, seen, depth)
    if response == true then return true end
    if type(response) ~= "table" then return tostring(response) == wanted end
    depth = depth or 0
    if depth > 3 then return false end
    seen = seen or {}
    if seen[response] then return false end
    seen[response] = true

    local direct = rawget(response, wanted)
    if direct ~= nil then return direct ~= false end
    local numeric = tonumber(wanted)
    if numeric ~= nil then
        direct = rawget(response, numeric)
        if direct ~= nil then return direct ~= false end
    end

    for key, value in pairs(response) do
        if tostring(key) == wanted then return value ~= false end
        if normalizedPetId(value) == wanted then return true end
        if type(value) == "table" and responseContainsPet(value, wanted, seen, depth + 1) then
            return true
        end
    end
    return false
end

local function classifyResponse(response, petIds)
    local accepted = {}
    if response == true then
        for _, petId in ipairs(petIds or {}) do accepted[tostring(petId)] = true end
        return accepted
    end
    for _, petId in ipairs(petIds or {}) do
        petId = tostring(petId)
        if responseContainsPet(response, petId) then accepted[petId] = true end
    end
    return accepted
end

local function retryDelay(attempt)
    attempt = math.max(1, tonumber(attempt) or 1)
    return RETRY_DELAYS[attempt] or RETRY_DELAYS[#RETRY_DELAYS]
end

local function contextActive(job)
    local context = run.Context
    if not context or job.Epoch ~= run.Epoch then return false end
    if type(context.Running) == "function" and not context.Running() then return false end
    if type(context.Enabled) == "function" and not context.Enabled() then return false end
    if type(context.Resetting) == "function" and context.Resetting() then return false end
    if type(context.RecordAlive) == "function" and not context.RecordAlive(job.Record) then return false end
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
    local result = table.pack(pcall(network.Invoke, command,
        table.unpack(arguments, 1, arguments.n)))
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
    local fired, problem = pcall(network.Fire, command,
        table.unpack(arguments, 1, arguments.n))
    return fired, fired and "Library.Network.Fire" or tostring(problem)
end

local function leaveStale(job, petIds)
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
            pcall(context.OnFailed, entry.PetId, entry.State, job.Record,
                reason, job.Attempt)
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
    for _, job in ipairs(run.Delayed) do
        earliest = math.min(earliest, job.Due)
    end
    if run.RetryDue and run.RetryDue <= earliest then return end

    run.RetryDue = earliest
    run.RetryToken = run.RetryToken + 1
    local token = run.RetryToken
    local epoch = run.Epoch
    scheduler.delay(math.max(earliest - os.clock(), 0), function()
        if token ~= run.RetryToken or epoch ~= run.Epoch then return end
        run.RetryDue = nil
        local now = os.clock()
        local waiting = {}
        for _, job in ipairs(run.Delayed) do
            if job.Epoch == run.Epoch and job.Due <= now then
                job.Due = nil
                run.Queue[#run.Queue + 1] = job
            elseif job.Epoch == run.Epoch then
                waiting[#waiting + 1] = job
            else
                clearPending(job.Entries)
            end
        end
        run.Delayed = waiting
        pump()
        scheduleRetryTimer()
    end)
end

local function scheduleRetry(job, entries, reason)
    if #entries == 0 then return end
    local context = run.Context
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

    if context and type(context.ShouldRetry) == "function" then
        local checked, shouldRetry = pcall(context.ShouldRetry,
            job.Record, reason, job.Attempt, entries)
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

    local nextAttempt = job.Attempt + 1
    run.Retries = run.Retries + #entries
    for _, entry in ipairs(entries) do
        if entryCurrent(entry) and context and type(context.OnRetry) == "function" then
            pcall(context.OnRetry, entry.PetId, entry.State,
                job.Record, reason, nextAttempt)
        end
    end
    run.Delayed[#run.Delayed + 1] = {
        Epoch = job.Epoch,
        Record = job.Record,
        CoinId = job.CoinId,
        Entries = entries,
        Attempt = nextAttempt,
        Due = os.clock() + retryDelay(job.Attempt),
    }
    scheduleRetryTimer()
end

local function targetContains(job, entry)
    local context = run.Context
    if not context or type(context.TargetContainsPet) ~= "function" then return false end
    local checked, present = pcall(context.TargetContainsPet,
        job.Record, entry.PetId)
    return checked and present == true
end

local function signalAccepted(job, entries, route)
    local failures = {}
    local context = run.Context
    for _, entry in ipairs(entries) do
        if entryCurrent(entry) then
            local targetSent, targetRoute = callNamedFire(
                "Change Pet Target", entry.PetId, "Coin", job.CoinId)
            local farmSent, farmRoute = callNamedFire(
                "Farm Coin", job.CoinId, entry.PetId)
            if context and type(context.OnSignalsSent) == "function" then
                pcall(context.OnSignalsSent, entry.PetId, entry.State, job.Record,
                    targetSent, farmSent, targetRoute, farmRoute)
            end

            local accepted = targetSent and farmSent
            if accepted and context and type(context.OnAccepted) == "function" then
                local called, result = pcall(context.OnAccepted,
                    entry.PetId, entry.State, job.Record, nil,
                    job.Attempt, route)
                accepted = called and result ~= false
            end
            if accepted then
                run.Accepted = run.Accepted + 1
                if run.PendingByPet[entry.PetId] == entry.State then
                    run.PendingByPet[entry.PetId] = nil
                end
            else
                failures[#failures + 1] = entry
            end
        else
            clearPending({ entry })
        end
    end
    return failures
end

local function process(job)
    local entries = currentEntries(job)
    if #entries == 0 then
        clearPending(job.Entries)
        return
    end

    -- A yielded InvokeServer can return no useful payload even though the game
    -- has already attached the pet. On retry, trust the live coin pet set
    -- before issuing another Join Coin request.
    local alreadyPresent, joinEntries, petIds = {}, {}, {}
    for _, entry in ipairs(entries) do
        if targetContains(job, entry) then
            alreadyPresent[#alreadyPresent + 1] = entry
        else
            joinEntries[#joinEntries + 1] = entry
            petIds[#petIds + 1] = entry.PetId
        end
    end

    if #alreadyPresent > 0 then
        local failures = signalAccepted(job, alreadyPresent, "live target state")
        if #failures > 0 then
            run.Errors = run.Errors + #failures
            run.LastProblem = "existing-target signal failure"
            scheduleRetry(job, failures, run.LastProblem)
        end
    end
    if #joinEntries == 0 then return end

    local startedAt = os.clock()
    local invoked, response, route = callNamedInvoke("Join Coin", job.CoinId, petIds)
    local elapsed = math.max(os.clock() - startedAt, 0)
    run.LastRTT = elapsed
    run.AverageRTT = run.AverageRTT == 0 and elapsed
        or run.AverageRTT * 0.85 + elapsed * 0.15

    if not invoked then
        run.Errors = run.Errors + #joinEntries
        run.LastProblem = "Join Coin transport error: " .. tostring(response)
        scheduleRetry(job, joinEntries, run.LastProblem)
        return
    end

    local acceptedMap = classifyResponse(response, petIds)
    local acceptedEntries, rejectedEntries = {}, {}
    for _, entry in ipairs(joinEntries) do
        local accepted = acceptedMap[entry.PetId] == true
            or targetContains(job, entry)
        if accepted then
            acceptedEntries[#acceptedEntries + 1] = entry
        else
            rejectedEntries[#rejectedEntries + 1] = entry
        end
    end

    if not contextActive(job) then
        local staleIds = {}
        for _, entry in ipairs(acceptedEntries) do
            staleIds[#staleIds + 1] = entry.PetId
        end
        leaveStale(job, staleIds)
        clearPending(joinEntries)
        return
    end

    local signalFailures = signalAccepted(job, acceptedEntries, route)

    run.Rejected = run.Rejected + #rejectedEntries
    if #signalFailures > 0 then
        run.Errors = run.Errors + #signalFailures
        run.LastProblem = "post-join signal failure"
        scheduleRetry(job, signalFailures, run.LastProblem)
    end
    if #rejectedEntries > 0 then
        run.LastProblem = "Join Coin rejected "
            .. tostring(#rejectedEntries) .. " pet(s)"
        scheduleRetry(job, rejectedEntries, run.LastProblem)
    elseif #signalFailures == 0 then
        run.LastProblem = "none"
    end
end

pump = function()
    compactQueue()
    while run.Context and run.Active < DEFAULT_DISPATCH_WIDTH
        and run.Head <= #run.Queue do
        local job = run.Queue[run.Head]
        run.Queue[run.Head] = false
        run.Head = run.Head + 1
        if contextActive(job) then
            run.Active = run.Active + 1
            -- InvokeServer yields. These short-lived coroutines are owned by one
            -- fixed-width pump and never become persistent per-pet workers.
            local thread = coroutine.create(function()
                local handled, problem = pcall(process, job)
                if not handled then
                    run.Errors = run.Errors + 1
                    run.LastProblem = tostring(problem)
                    local current = currentEntries(job)
                    scheduleRetry(job, current,
                        "dispatch call failed: " .. tostring(problem))
                    trace("pet dispatch", tostring(problem))
                end
                run.Active = math.max(run.Active - 1, 0)
                pump()
                local context = run.Context
                if context and type(context.Pulse) == "function" then
                    pcall(context.Pulse)
                end
            end)
            local resumed, problem = coroutine.resume(thread)
            if not resumed then
                run.Errors = run.Errors + 1
                run.LastProblem = tostring(problem)
                run.Active = math.max(run.Active - 1, 0)
                local current = currentEntries(job)
                scheduleRetry(job, current,
                    "dispatch coroutine failed: " .. tostring(problem))
                trace("pet dispatch", tostring(problem))
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
    run.Limit = DEFAULT_DISPATCH_WIDTH
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
        PolicyMaxLanes = run.Limit,
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
    if action == "retry-delay" then return retryDelay(context) end
    if action == "version" then return MODULE_VERSION end
    return false, "unknown action"
end
