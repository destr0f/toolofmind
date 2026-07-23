-- PSX OG RuntimeKernel
-- One heartbeat-driven scheduler for recurring workers, priority events and lifecycle cleanup.

local MODULE_VERSION = "1.0.0"

local PRIORITY = {
    P0 = 0, -- destroyed coin / free pet
    P1 = 1, -- loot appeared
    P2 = 2, -- egg acknowledgement / inventory delta
    P3 = 3, -- machines / boosts / rewards
    P4 = 4, -- UI / diagnostics
}

local function normalizePriority(value)
    if type(value) == "string" then value = PRIORITY[value] end
    return math.clamp(math.floor(tonumber(value) or PRIORITY.P4), PRIORITY.P0, PRIORITY.P4)
end

local function newToken(parent)
    local token = {
        Cancelled = false,
        Reason = nil,
        Parent = parent,
    }

    function token:IsCancelled()
        return self.Cancelled == true
            or (self.Parent ~= nil and self.Parent:IsCancelled())
    end

    function token:Cancel(reason)
        if self.Cancelled then return false end
        self.Cancelled = true
        self.Reason = tostring(reason or "cancelled")
        return true
    end

    return token
end

local function nodeBefore(left, right)
    if left.Due ~= right.Due then return left.Due < right.Due end
    if left.Priority ~= right.Priority then return left.Priority < right.Priority end
    return left.Sequence < right.Sequence
end

local function heapPush(heap, node)
    local index = #heap + 1
    heap[index] = node
    while index > 1 do
        local parent = math.floor(index / 2)
        if nodeBefore(heap[parent], node) then break end
        heap[index], heap[parent] = heap[parent], heap[index]
        index = parent
    end
end

local function heapPop(heap)
    local count = #heap
    if count == 0 then return nil end
    local root = heap[1]
    local tail = heap[count]
    heap[count] = nil
    if count == 1 then return root end
    heap[1] = tail
    local index = 1
    while true do
        local left = index * 2
        if left > #heap then break end
        local right = left + 1
        local best = left
        if right <= #heap and nodeBefore(heap[right], heap[left]) then best = right end
        if nodeBefore(heap[index], heap[best]) then break end
        heap[index], heap[best] = heap[best], heap[index]
        index = best
    end
    return root
end

local function heapPeek(heap)
    return heap[1]
end

local function createKernel(context)
    context = type(context) == "table" and context or {}
    local clock = type(context.Clock) == "function" and context.Clock or os.clock
    local spawnTask = type(context.Spawn) == "function" and context.Spawn
        or (task and (task.defer or task.spawn))
    local cancelTask = type(context.Cancel) == "function" and context.Cancel
        or (task and task.cancel)
    local trace = type(context.Trace) == "function" and context.Trace or function() end
    local driver = context.Driver

    assert(type(spawnTask) == "function", "RuntimeKernel requires a task dispatcher")
    assert(driver and type(driver.Connect) == "function", "RuntimeKernel requires a heartbeat-like Driver")

    local rootToken = newToken(nil)
    local kernel = {
        Priority = PRIORITY,
        RootToken = rootToken,
        Jobs = {},
        Connections = {},
        StopHooks = {},
        Heap = {},
        Ready = {
            { Items = {}, Head = 1 },
            { Items = {}, Head = 1 },
            { Items = {}, Head = 1 },
            { Items = {}, Head = 1 },
            { Items = {}, Head = 1 },
        },
        Sequence = 0,
        Stopped = false,
        StopReason = nil,
        DriverConnection = nil,
        MaxLaunchesPerPulse = math.max(1, tonumber(context.MaxLaunchesPerPulse) or 64),
        PulseBudget = math.max(0.0001, tonumber(context.PulseBudget) or 0.003),
        Metrics = {
            Pulses = 0,
            Scheduled = 0,
            Executed = 0,
            Cancelled = 0,
            DuplicateStarts = 0,
            Errors = 0,
            LastError = "none",
        },
    }

    local function nextSequence()
        kernel.Sequence = kernel.Sequence + 1
        return kernel.Sequence
    end

    local function queueNode(job, due)
        if kernel.Stopped or not job.Active or job.Token:IsCancelled() then return false end
        if job.Queued or job.Ready then return true end
        job.Generation = job.Generation + 1
        job.Due = math.max(tonumber(due) or clock(), 0)
        job.Queued = true
        heapPush(kernel.Heap, {
            Due = job.Due,
            Priority = job.Priority,
            Sequence = nextSequence(),
            Key = job.Key,
            JobId = job.Id,
            Generation = job.Generation,
        })
        kernel.Metrics.Scheduled = kernel.Metrics.Scheduled + 1
        return true
    end

    local function intervalFor(job, now, override)
        if type(override) == "number" then return math.max(override, 0) end
        local interval = job.Interval
        if type(interval) == "function" then
            local ok, value = pcall(interval, job.Token, now, job)
            if ok then interval = value else
                kernel.Metrics.Errors = kernel.Metrics.Errors + 1
                kernel.Metrics.LastError = tostring(value)
                interval = 1
            end
        end
        return math.max(tonumber(interval) or 0, 0)
    end

    function kernel:IsRunning()
        return not self.Stopped and not self.RootToken:IsCancelled()
    end

    function kernel:CreateToken(parent)
        return newToken(parent or self.RootToken)
    end

    function kernel:GetJob(key)
        return self.Jobs[tostring(key)]
    end

    function kernel:GetConnection(key)
        local entry = self.Connections[tostring(key)]
        return entry and entry.Connection or nil
    end

    function kernel:Register(key, specification)
        key = tostring(key or "")
        specification = type(specification) == "table" and specification or {}
        if key == "" then return nil, false, "job key is empty" end
        if self.Stopped then return nil, false, "kernel is stopped" end

        local existing = self.Jobs[key]
        if existing and existing.Active then
            self.Metrics.DuplicateStarts = self.Metrics.DuplicateStarts + 1
            return existing, false, "job is already registered"
        end

        local callback = specification.Callback
        if type(callback) ~= "function" then return nil, false, "job callback is absent" end
        local priority = normalizePriority(specification.Priority)
        local job = {
            Id = nextSequence(),
            Key = key,
            Owner = tostring(specification.Owner or "global"),
            Priority = priority,
            Callback = callback,
            Interval = specification.Interval,
            Recurring = specification.Recurring == true,
            Enabled = specification.Enabled,
            Payload = specification.Payload,
            Pending = false,
            Queued = false,
            Ready = false,
            Running = false,
            Thread = nil,
            Generation = 0,
            Active = true,
            Token = newToken(specification.ParentToken or self.RootToken),
            Runs = 0,
            LastStartedAt = nil,
            LastFinishedAt = nil,
        }
        self.Jobs[key] = job
        local delay = tonumber(specification.Delay)
        if delay == nil then delay = specification.Immediate == false
            and intervalFor(job, clock()) or 0 end
        queueNode(job, clock() + math.max(delay, 0))
        return job, true
    end

    function kernel:Every(key, interval, priority, callback, options)
        options = type(options) == "table" and options or {}
        options.Callback = callback
        options.Interval = interval
        options.Priority = priority
        options.Recurring = true
        if options.Immediate == nil then options.Immediate = true end
        return self:Register(key, options)
    end

    function kernel:After(key, delay, priority, callback, options)
        options = type(options) == "table" and options or {}
        if options.Replace == true then self:Unregister(key, "replaced") end
        options.Callback = callback
        options.Priority = priority
        options.Recurring = false
        options.Delay = math.max(tonumber(delay) or 0, 0)
        return self:Register(key, options)
    end

    function kernel:Emit(key, priority, callback, payload, options)
        key = tostring(key or "")
        options = type(options) == "table" and options or {}
        local existing = self.Jobs[key]
        if existing and existing.Active then
            existing.Payload = payload
            if existing.Running then
                existing.Pending = true
                return existing, false, "event coalesced while running"
            end
            if options.ReplaceCallback == true and type(callback) == "function" then
                existing.Callback = callback
            end
            if options.Promote ~= false then
                existing.Priority = math.min(existing.Priority, normalizePriority(priority))
            end
            queueNode(existing, clock())
            return existing, false, "event coalesced"
        end
        options.Callback = callback
        options.Priority = priority
        options.Payload = payload
        options.Recurring = false
        options.Delay = 0
        return self:Register(key, options)
    end

    function kernel:Spawn(key, priority, callback, options)
        return self:Emit(key, priority, callback, nil, options)
    end

    function kernel:Unregister(key, reason)
        key = tostring(key or "")
        local job = self.Jobs[key]
        if not job then return false end
        self.Jobs[key] = nil
        job.Active = false
        job.Pending = false
        job.Queued = false
        job.Ready = false
        job.Token:Cancel(reason or "unregistered")
        local currentThread = coroutine.running()
        if job.Thread and job.Thread ~= currentThread and type(cancelTask) == "function" then
            pcall(cancelTask, job.Thread)
        end
        job.Thread = nil
        self.Metrics.Cancelled = self.Metrics.Cancelled + 1
        return true
    end

    function kernel:CancelOwner(owner, reason)
        owner = tostring(owner or "")
        local keys = {}
        for key, job in pairs(self.Jobs) do
            if job.Owner == owner then keys[#keys + 1] = key end
        end
        for _, key in ipairs(keys) do self:Unregister(key, reason or ("owner " .. owner .. " cancelled")) end

        local connectionKeys = {}
        for key, entry in pairs(self.Connections) do
            if entry.Owner == owner then connectionKeys[#connectionKeys + 1] = key end
        end
        for _, key in ipairs(connectionKeys) do self:UnregisterConnection(key) end
        return #keys, #connectionKeys
    end

    function kernel:TrackConnection(key, connection, owner)
        key = tostring(key or "")
        if key == "" or not connection or type(connection.Disconnect) ~= "function" then return nil end
        self:UnregisterConnection(key)
        self.Connections[key] = {
            Connection = connection,
            Owner = tostring(owner or "global"),
        }
        return connection
    end

    function kernel:UnregisterConnection(key)
        key = tostring(key or "")
        local entry = self.Connections[key]
        if not entry then return false end
        self.Connections[key] = nil
        pcall(function() entry.Connection:Disconnect() end)
        return true
    end

    function kernel:Connect(key, signal, priority, callback, options)
        options = type(options) == "table" and options or {}
        if not signal or type(signal.Connect) ~= "function" then return nil, "signal is invalid" end
        local eventSequence = 0
        local latestArguments = {}
        local connection = signal:Connect(function(...)
            if self.Stopped then return end
            local arguments = table.pack(...)
            local eventKey = "event:" .. tostring(key)
            if options.Coalesce == false then
                eventSequence = eventSequence + 1
                eventKey = eventKey .. ":" .. tostring(eventSequence)
                self:Emit(eventKey, priority, function(token)
                    if token:IsCancelled() then return end
                    return callback(table.unpack(arguments, 1, arguments.n))
                end, nil, {
                    Owner = options.Owner or "global",
                })
                return
            end
            if type(options.KeyBy) == "function" then
                local keyOk, suffix = pcall(options.KeyBy, table.unpack(arguments, 1, arguments.n))
                if keyOk and suffix ~= nil then eventKey = eventKey .. ":" .. tostring(suffix) end
            end
            latestArguments[eventKey] = arguments
            self:Emit(eventKey, priority, function(token)
                if token:IsCancelled() then return end
                local current = latestArguments[eventKey]
                latestArguments[eventKey] = nil
                if current then return callback(table.unpack(current, 1, current.n)) end
            end, nil, {
                Owner = options.Owner or "global",
            })
        end)
        self:TrackConnection("signal:" .. tostring(key), connection, options.Owner)
        return connection
    end

    function kernel:OnStop(key, callback)
        if type(callback) ~= "function" then return false end
        self.StopHooks[tostring(key)] = callback
        return true
    end

    local function launch(job)
        job.Ready = false
        if kernel.Stopped or not job.Active or job.Token:IsCancelled() or job.Running then return end
        if type(job.Enabled) == "function" then
            local enabledOk, enabled = pcall(job.Enabled)
            if not enabledOk or enabled ~= true then
                if job.Recurring and job.Active then
                    queueNode(job, clock() + intervalFor(job, clock()))
                else
                    kernel.Jobs[job.Key] = nil
                    job.Active = false
                end
                return
            end
        end

        job.Running = true
        job.LastStartedAt = clock()
        job.Runs = job.Runs + 1
        kernel.Metrics.Executed = kernel.Metrics.Executed + 1
        local payload = job.Payload
        job.Payload = nil

        local thread
        thread = spawnTask(function()
            local ok, result = xpcall(function()
                return job.Callback(job.Token, clock(), payload, job)
            end, debug and debug.traceback or tostring)
            job.Running = false
            job.Thread = nil
            job.LastFinishedAt = clock()

            if not ok then
                kernel.Metrics.Errors = kernel.Metrics.Errors + 1
                kernel.Metrics.LastError = tostring(result)
                pcall(trace, "runtime kernel error", job.Key .. " | " .. tostring(result))
            end
            if kernel.Stopped or not job.Active or job.Token:IsCancelled() then return end
            if result == false then
                kernel:Unregister(job.Key, "callback completed")
                return
            end
            if job.Pending then
                job.Pending = false
                queueNode(job, clock())
            elseif job.Recurring then
                queueNode(job, clock() + intervalFor(job, clock(), type(result) == "number" and result or nil))
            else
                kernel.Jobs[job.Key] = nil
                job.Active = false
            end
        end)
        job.Thread = thread
    end

    function kernel:Pulse(now)
        if self.Stopped then return false end
        now = tonumber(now) or clock()
        self.Metrics.Pulses = self.Metrics.Pulses + 1

        local startedAt = clock()
        local prepared = 0
        local prepareLimit = self.MaxLaunchesPerPulse * 2
        while prepared < prepareLimit and clock() - startedAt <= self.PulseBudget * 0.45 do
            local node = heapPeek(self.Heap)
            if not node or node.Due > now then break end
            heapPop(self.Heap)
            prepared = prepared + 1
            local job = self.Jobs[node.Key]
            if job and job.Active and job.Id == node.JobId and job.Generation == node.Generation
                and not job.Token:IsCancelled() then
                job.Queued = false
                job.Ready = true
                local queue = self.Ready[job.Priority + 1]
                queue.Items[#queue.Items + 1] = job
            end
        end

        local launched = 0
        for priority = PRIORITY.P0, PRIORITY.P4 do
            local queue = self.Ready[priority + 1]
            local items = queue.Items
            while queue.Head <= #items and launched < self.MaxLaunchesPerPulse
                and clock() - startedAt <= self.PulseBudget do
                local job = items[queue.Head]
                items[queue.Head] = false
                queue.Head = queue.Head + 1
                launch(job)
                launched = launched + 1
            end
            if queue.Head > #items then
                table.clear(items)
                queue.Head = 1
            elseif queue.Head > 64 and queue.Head > #items / 2 then
                local compacted = {}
                for index = queue.Head, #items do compacted[#compacted + 1] = items[index] end
                queue.Items = compacted
                queue.Head = 1
            end
        end
        return true
    end

    function kernel:Stats()
        local registered, running, pending = 0, 0, 0
        for _, job in pairs(self.Jobs) do
            registered = registered + 1
            if job.Running then running = running + 1 end
            if job.Pending or job.Queued or job.Ready then pending = pending + 1 end
        end
        local connections = 0
        for _ in pairs(self.Connections) do connections = connections + 1 end
        return {
            Registered = registered,
            Running = running,
            Pending = pending,
            Connections = connections,
            Pulses = self.Metrics.Pulses,
            Scheduled = self.Metrics.Scheduled,
            Executed = self.Metrics.Executed,
            Cancelled = self.Metrics.Cancelled,
            DuplicateStarts = self.Metrics.DuplicateStarts,
            Errors = self.Metrics.Errors,
            LastError = self.Metrics.LastError,
            Stopped = self.Stopped,
        }
    end

    function kernel:Stop(reason)
        if self.Stopped then return false end
        self.Stopped = true
        self.StopReason = tostring(reason or "stopped")
        self.RootToken:Cancel(self.StopReason)

        if self.DriverConnection then
            pcall(function() self.DriverConnection:Disconnect() end)
            self.DriverConnection = nil
        end

        local jobKeys = {}
        for key in pairs(self.Jobs) do jobKeys[#jobKeys + 1] = key end
        for _, key in ipairs(jobKeys) do self:Unregister(key, self.StopReason) end

        local connectionKeys = {}
        for key in pairs(self.Connections) do connectionKeys[#connectionKeys + 1] = key end
        for _, key in ipairs(connectionKeys) do self:UnregisterConnection(key) end

        table.clear(self.Heap)
        for _, queue in ipairs(self.Ready) do
            table.clear(queue.Items)
            queue.Head = 1
        end

        local hooks = self.StopHooks
        self.StopHooks = {}
        for key, callback in pairs(hooks) do
            local ok, problem = pcall(callback, self.StopReason)
            if not ok then pcall(trace, "runtime kernel stop hook", tostring(key) .. " | " .. tostring(problem)) end
        end
        return true
    end

    kernel.DriverConnection = driver:Connect(function()
        kernel:Pulse(clock())
    end)
    return kernel
end

return function(action, context)
    if action == "version" then return MODULE_VERSION end
    if action == "create" then return createKernel(context) end
    if action == "priorities" then return PRIORITY end
    return nil, "unsupported RuntimeKernel action: " .. tostring(action)
end
