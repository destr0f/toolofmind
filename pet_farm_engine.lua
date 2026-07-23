-- High-throughput explicit-UID transport for PSX OG pet farming.
-- The caller owns target selection and lock state. This module only schedules
-- named Network calls, classifies Join Coin replies and reports outcomes.

local MODULE_VERSION = "2.3.0"
local DEFAULT_MIN_LANES = 4
local DEFAULT_MAX_LANES = 16
local DEFAULT_INITIAL_LANES = 12
local MAX_JOIN_ATTEMPTS = 3
local MAX_QUEUED_JOBS = 64
local scheduler = task or {
    spawn = function(callback) coroutine.wrap(callback)() end,
    delay = function(_, callback) coroutine.wrap(callback)() end,
}

local run = {
    Context = nil,
    Epoch = 0,
    Queue = {},
    Head = 1,
    Active = 0,
    Limit = DEFAULT_INITIAL_LANES,
    MinLanes = DEFAULT_MIN_LANES,
    MaxLanes = DEFAULT_MAX_LANES,
    PolicyMaxLanes = DEFAULT_MAX_LANES,
    Accepted = 0,
    Rejected = 0,
    Errors = 0,
    Retries = 0,
    Stale = 0,
    CompletedJobs = 0,
    CleanStreak = 0,
    FailureStreak = 0,
    AverageRTT = 0,
    LastRTT = 0,
    LastProblem = "none",
    PendingByPet = {},
    PeakQueued = 0,
    Dropped = 0,
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
    if run.Head <= 64 or run.Head <= #run.Queue / 2 then return end
    local compacted = {}
    for index = run.Head, #run.Queue do compacted[#compacted + 1] = run.Queue[index] end
    run.Queue = compacted
    run.Head = 1
end

local function resetQueue()
    run.Epoch = run.Epoch + 1
    run.Queue = {}
    run.Head = 1
    table.clear(run.PendingByPet)
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
    return math.min(0.06 * (2 ^ (attempt - 1)), 0.24)
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
    for _, entry in ipairs(job.Entries) do
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
        end
    end

    local network = context and type(context.NetworkReady) == "function" and context.NetworkReady() or nil
    if not network or type(network.Invoke) ~= "function" then
        return false, "Library.Network.Invoke unavailable", "none"
    end
    local result = table.pack(pcall(network.Invoke, command, table.unpack(arguments, 1, arguments.n)))
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
        end
    end

    local network = context and type(context.NetworkReady) == "function" and context.NetworkReady() or nil
    if not network or type(network.Fire) ~= "function" then
        return false, "Library.Network.Fire unavailable"
    end
    local fired, problem = pcall(network.Fire, command, table.unpack(arguments, 1, arguments.n))
    return fired, fired and "Library.Network.Fire" or tostring(problem)
end

local function leaveStale(job, petIds)
    if #petIds == 0 then return end
    run.Stale = run.Stale + #petIds
    local context = run.Context
    if context and type(context.OnStaleAccepted) == "function" then
        pcall(context.OnStaleAccepted, job.Record, petIds)
        return
    end
    callNamedInvoke("Leave Coin", job.CoinId, petIds)
end

local function adjustLanes(acceptedCount, rejectedCount, invokeFailed, elapsed)
    if invokeFailed then
        run.CleanStreak = 0
        run.FailureStreak = run.FailureStreak + 1
        -- One transient executor/transport failure must not turn 16 active
        -- UID lanes into 8. Sustained RTT is handled by the caller's EWMA
        -- policy; this local guard only trims repeated hard failures.
        local penalty = math.min(run.FailureStreak, 3)
        run.Limit = math.max(run.MinLanes, run.Limit - penalty)
    elseif rejectedCount > 0 then
        -- A false Join Coin result normally means that this particular coin was
        -- destroyed or won by another client. It is not transport congestion,
        -- so reducing every UID lane here creates the familiar 15 -> 8 collapse.
        run.FailureStreak = 0
        run.CleanStreak = 0
    elseif acceptedCount > 0 then
        run.FailureStreak = 0
        run.CleanStreak = run.CleanStreak + acceptedCount
        if run.CleanStreak >= math.max(run.Limit, 4) then
            run.CleanStreak = 0
            run.Limit = math.min(run.PolicyMaxLanes, run.Limit + 1)
        end
    end
    run.Limit = math.min(run.Limit, run.PolicyMaxLanes)
end

local function scheduleRetry(job, entries, reason)
    if #entries == 0 then return end
    local context = run.Context
    if context and type(context.ShouldRetry) == "function" then
        local checked, shouldRetry = pcall(context.ShouldRetry,
            job.Record, reason, job.Attempt, entries)
        if checked and shouldRetry == false then
            for _, entry in ipairs(entries) do
                if entryCurrent(entry) and type(context.OnFailed) == "function" then
                    pcall(context.OnFailed,
                        entry.PetId, entry.State, job.Record, reason, job.Attempt)
                end
            end
            clearPending(entries)
            return
        end
    end
    if job.Attempt >= MAX_JOIN_ATTEMPTS then
        for _, entry in ipairs(entries) do
            if entryCurrent(entry) and context and type(context.OnFailed) == "function" then
                pcall(context.OnFailed, entry.PetId, entry.State, job.Record, reason, job.Attempt)
            end
        end
        clearPending(entries)
        return
    end

    local nextAttempt = job.Attempt + 1
    run.Retries = run.Retries + #entries
    for _, entry in ipairs(entries) do
        if entryCurrent(entry) and context and type(context.OnRetry) == "function" then
            pcall(context.OnRetry, entry.PetId, entry.State, job.Record, reason, nextAttempt)
        end
    end
    local epoch = job.Epoch
    local jitter = 0
    if context and type(context.RetryJitter) == "function" then
        local jittered, value = pcall(context.RetryJitter, job.Record, job.Attempt)
        if jittered then jitter = math.clamp(tonumber(value) or 0, 0, 0.08) end
    end
    scheduler.delay(retryDelay(job.Attempt) + jitter, function()
        if epoch ~= run.Epoch then return end
        local retryEntries = {}
        for _, entry in ipairs(entries) do
            if entryCurrent(entry) then retryEntries[#retryEntries + 1] = entry end
        end
        if #retryEntries == 0 or not contextActive(job) then
            clearPending(entries)
            return
        end
        if queueSize() >= MAX_QUEUED_JOBS then
            run.Dropped = run.Dropped + #retryEntries
            run.LastProblem = "bounded retry queue is full"
            clearPending(retryEntries)
            for _, entry in ipairs(retryEntries) do
                if entryCurrent(entry) and context and type(context.OnFailed) == "function" then
                    pcall(context.OnFailed, entry.PetId, entry.State, job.Record,
                        run.LastProblem, nextAttempt)
                end
            end
            return
        end
        run.Queue[#run.Queue + 1] = {
            Epoch = epoch,
            Record = job.Record,
            Model = job.Model,
            CoinId = job.CoinId,
            Entries = retryEntries,
            Attempt = nextAttempt,
        }
        run.PeakQueued = math.max(run.PeakQueued, queueSize())
        pump()
    end)
end

local function process(job)
    local entries, petIds = currentEntries(job)
    if #entries == 0 then
        clearPending(job.Entries)
        return
    end

    local startedAt = os.clock()
    local invoked, response, route = callNamedInvoke("Join Coin", job.CoinId, petIds)
    local elapsed = math.max(os.clock() - startedAt, 0)
    run.LastRTT = elapsed
    run.AverageRTT = run.AverageRTT == 0 and elapsed or run.AverageRTT * 0.8 + elapsed * 0.2

    if not invoked then
        run.Errors = run.Errors + #entries
        run.LastProblem = tostring(response)
        adjustLanes(0, 0, true, elapsed)
        scheduleRetry(job, entries, "Join Coin transport error: " .. tostring(response))
        return
    end

    local acceptedMap = classifyResponse(response, petIds)
    local acceptedEntries, rejectedEntries = {}, {}
    local context = run.Context
    for _, entry in ipairs(entries) do
        local accepted = acceptedMap[entry.PetId] == true
        if not accepted and context and type(context.TargetContainsPet) == "function" then
            local checked, present = pcall(context.TargetContainsPet, job.Record, entry.PetId)
            accepted = checked and present == true
        end
        if accepted then
            acceptedEntries[#acceptedEntries + 1] = entry
        else
            rejectedEntries[#rejectedEntries + 1] = entry
        end
    end

    if job.Epoch ~= run.Epoch or not contextActive(job) then
        local staleIds = {}
        for _, entry in ipairs(acceptedEntries) do staleIds[#staleIds + 1] = entry.PetId end
        leaveStale(job, staleIds)
        clearPending(entries)
        return
    end

    run.Accepted = run.Accepted + #acceptedEntries
    run.Rejected = run.Rejected + #rejectedEntries
    run.CompletedJobs = run.CompletedJobs + 1
    adjustLanes(#acceptedEntries, #rejectedEntries, false, elapsed)

    for _, entry in ipairs(acceptedEntries) do
        if entryCurrent(entry) then
            local accepted = true
            if context and type(context.OnAccepted) == "function" then
                local called, result = pcall(context.OnAccepted,
                    entry.PetId, entry.State, job.Record, job.Model, job.Attempt, route)
                accepted = called and result ~= false
            end
            if accepted and entryCurrent(entry) then
                local targetSent, targetRoute = callNamedFire(
                    "Change Pet Target", entry.PetId, "Coin", job.CoinId)
                local farmSent, farmRoute = callNamedFire("Farm Coin", job.CoinId, entry.PetId)
                if context and type(context.OnSignalsSent) == "function" then
                    pcall(context.OnSignalsSent, entry.PetId, entry.State, job.Record,
                        targetSent, farmSent, targetRoute, farmRoute)
                end
                if not targetSent or not farmSent then
                    run.Errors = run.Errors + 1
                    run.LastProblem = "post-join signal failure"
                end
            end
        end
    end
    clearPending(acceptedEntries)

    if #rejectedEntries > 0 then
        run.LastProblem = "Join Coin rejected " .. tostring(#rejectedEntries) .. " pet(s)"
        scheduleRetry(job, rejectedEntries, run.LastProblem)
    else
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
            scheduler.spawn(function()
                local handled, problem = pcall(process, job)
                if not handled then
                    run.Errors = run.Errors + 1
                    run.LastProblem = tostring(problem)
                    adjustLanes(0, 0, true)
                    local entries = currentEntries(job)
                    scheduleRetry(job, entries, "dispatch worker error: " .. tostring(problem))
                    trace("pet dispatch worker", tostring(problem))
                end
                run.Active = math.max(run.Active - 1, 0)
                pump()
                local context = run.Context
                if context and type(context.Pulse) == "function" then pcall(context.Pulse) end
            end)
        else
            clearPending(job.Entries)
        end
    end
    compactQueue()
end

local function start(context)
    if type(context) ~= "table" then return false, "context table required" end
    resetQueue()
    run.Context = context
    run.MinLanes = math.max(1, tonumber(context.MinLanes) or DEFAULT_MIN_LANES)
    run.MaxLanes = math.max(run.MinLanes, tonumber(context.MaxLanes) or DEFAULT_MAX_LANES)
    run.PolicyMaxLanes = run.MaxLanes
    run.Limit = math.clamp(tonumber(context.InitialLanes) or DEFAULT_INITIAL_LANES,
        run.MinLanes, run.PolicyMaxLanes)
    run.CleanStreak = 0
    run.FailureStreak = 0
    run.LastProblem = "none"
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
            if run.PendingByPet[petId] ~= entry.State then
                entries[#entries + 1] = {
                    PetId = petId,
                    State = entry.State,
                }
                run.PendingByPet[petId] = entry.State
            end
        end
    end
    if #entries == 0 then return false, "dispatch has no current pets" end
    if queueSize() >= MAX_QUEUED_JOBS then
        run.Dropped = run.Dropped + #entries
        clearPending(entries)
        return false, "bounded dispatch queue is full"
    end
    run.Queue[#run.Queue + 1] = {
        Epoch = run.Epoch,
        Record = payload.Record,
        Model = payload.Model,
        CoinId = tostring(payload.CoinId),
        Entries = entries,
        Attempt = math.max(1, tonumber(payload.Attempt) or 1),
    }
    run.PeakQueued = math.max(run.PeakQueued, queueSize())
    pump()
    return true
end

local function stats()
    return {
        Version = MODULE_VERSION,
        Epoch = run.Epoch,
        Active = run.Active,
        Queued = queueSize(),
        Limit = run.Limit,
        PolicyMaxLanes = run.PolicyMaxLanes,
        Accepted = run.Accepted,
        Rejected = run.Rejected,
        Errors = run.Errors,
        Retries = run.Retries,
        Stale = run.Stale,
        CompletedJobs = run.CompletedJobs,
        FailureStreak = run.FailureStreak,
        AverageRTT = run.AverageRTT,
        LastRTT = run.LastRTT,
        LastProblem = run.LastProblem,
        PeakQueued = run.PeakQueued,
        Dropped = run.Dropped,
        QueueCapacity = MAX_QUEUED_JOBS,
    }
end

local function setLimit(value)
    if not run.Context then return false, "engine is not started" end
    local desired = math.clamp(math.floor(tonumber(value) or run.MaxLanes),
        run.MinLanes, run.MaxLanes)
    local previous = run.PolicyMaxLanes
    run.PolicyMaxLanes = desired
    if run.Limit > desired then
        run.Limit = desired
    elseif desired > previous and run.Limit < desired then
        -- Restore one lane immediately; subsequent clean accepts continue the
        -- additive ramp without producing a new burst.
        run.Limit = math.min(desired, run.Limit + 1)
    end
    pump()
    return true, desired
end

return function(action, context, value)
    if action == "start" then return start(context) end
    if action == "dispatch" then return dispatch(value or context) end
    if action == "pump" then pump(); return true end
    if action == "reset" then resetQueue(); return true end
    if action == "stop" then resetQueue(); run.Context = nil; return true end
    if action == "stats" then return stats() end
    if action == "set-limit" then return setLimit(context) end
    if action == "classify" then return classifyResponse(context, value) end
    if action == "retry-delay" then return retryDelay(context) end
    if action == "version" then return MODULE_VERSION end
    return false, "unknown action"
end
