-- Event-first zero-physics loot collection for PSX OG.
-- The preferred path disables only the game's Orb Added / Spawn Lootbag
-- visual producers and consumes their named Network events directly.
-- A conservative workspace fallback remains available when connection
-- introspection is unavailable or the source script cannot be identified.

local MODULE_VERSION = "2.0.0"
local ORB_FLUSH_INTERVAL = 0.25
local ORB_BATCH_SIZE = 2048
local MAX_PENDING_ORBS = 8192
local BAG_FIRST_ATTEMPT_DELAY = 0.08
local BAG_ACK_TIMEOUT = 0.9
local BAG_FINAL_ACK_TIMEOUT = 1.5
local STATUS_INTERVAL = 1

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local run = {
    Context = nil,
    Generation = 0,
    Active = false,
    Connections = {},
    ThingsConnections = {},
    OrbConnections = {},
    BagConnections = {},
    OrbGateConnections = {},
    BagGateConnections = {},
    RecordConnections = {},
    DisabledOrbs = {},
    DisabledBags = {},
    Things = nil,
    OrbFolder = nil,
    LootbagFolder = nil,
    OrbsOn = false,
    BagsOn = false,
    OrbGate = false,
    BagGate = false,
    OrbGateReason = "not armed",
    BagGateReason = "not armed",
    OrbToken = 0,
    BagToken = 0,
    BagWakeSerial = 0,
    PendingOrbIds = {},
    PendingOrbCount = 0,
    OrbFlushArmed = false,
    OrbRetrySpent = false,
    WaitingBags = {},
    WaitingBagCount = 0,
    BagWakeArmed = false,
    BagWakeAt = nil,
    StatusArmed = false,
    LastStatusText = nil,
    RouteOrbs = "unavailable",
    RouteLootbags = "unavailable",
    OrbBatches = 0,
    OrbIdsSent = 0,
    OrbEvents = 0,
    OrbErrors = 0,
    OrbOverflow = 0,
    OrbDropped = 0,
    BagEvents = 0,
    BagSent = 0,
    BagAcked = 0,
    BagRetried = 0,
    BagSkipped = 0,
    BagErrors = 0,
}

local function disconnect(connection)
    if connection then pcall(function() connection:Disconnect() end) end
end

local function clearConnections(list)
    for index = 1, #list do
        disconnect(list[index])
        list[index] = nil
    end
end

local function contextRunning()
    local context = run.Context
    if not run.Active or not context then return false end
    return type(context.Running) ~= "function" or context.Running() == true
end

local function wantedFlags()
    local context = run.Context
    if not contextRunning() then return false, false end
    local orbs = type(context.EnabledOrbs) == "function"
        and context.EnabledOrbs() == true
    local bags = type(context.EnabledLootbags) == "function"
        and context.EnabledLootbags() == true
    return orbs, bags
end

local function orbsEnabled()
    return contextRunning() and run.OrbsOn
end

local function bagsEnabled()
    return contextRunning() and run.BagsOn
end

local function readValue(object, name)
    if not object then return nil end
    local child = object:FindFirstChild(name .. "_Attr") or object:FindFirstChild(name)
    if child and child:IsA("ValueBase") then return child.Value end
    local ok, value = pcall(function()
        local suffixed = object:GetAttribute(name .. "_Attr")
        return suffixed ~= nil and suffixed or object:GetAttribute(name)
    end)
    return ok and value or nil
end

local function objectId(object)
    if not object then return nil end
    local value = readValue(object, "ID")
    if value == nil then value = object.Name end
    value = value ~= nil and tostring(value) or ""
    return value ~= "" and value or nil
end

local function normalizePosition(value)
    if typeof(value) == "CFrame" then return value.Position end
    return typeof(value) == "Vector3" and value or nil
end

local function objectPosition(object)
    if not object then return nil end
    if object:IsA("BasePart") then return object.Position end
    if object:IsA("Model") then
        local primary = object.PrimaryPart
        if primary then return primary.Position end
        local part = object:FindFirstChildWhichIsA("BasePart", true)
        if part then return part.Position end
    end
    return normalizePosition(readValue(object, "Position") or readValue(object, "POS"))
end

local function suppressLocalInstance(object)
    if not object then return end
    pcall(function()
        if object:IsA("BasePart") then
            object.LocalTransparencyModifier = 1
            object.Anchored = true
            object.CanCollide = false
            object.CanTouch = false
            object.CanQuery = false
            object.AssemblyLinearVelocity = Vector3.zero
            object.AssemblyAngularVelocity = Vector3.zero
        end
        if object:IsA("BillboardGui") or object:IsA("SurfaceGui")
            or object:IsA("ParticleEmitter") or object:IsA("Trail")
            or object:IsA("Beam") or object:IsA("Smoke")
            or object:IsA("Fire") or object:IsA("Sparkles") then
            object.Enabled = false
        elseif object:IsA("BodyPosition") then
            object.MaxForce = Vector3.zero
            object.P = 0
            object.D = 0
        elseif object:IsA("BodyGyro") then
            object.MaxTorque = Vector3.zero
            object.P = 0
            object.D = 0
        end
    end)
end

local function disableLocalPickup(object)
    if not object then return end
    suppressLocalInstance(object)
    for _, child in ipairs(object:GetChildren()) do
        suppressLocalInstance(child)
    end
end

local function statusText()
    return string.format(
        "Event gate: Orbs %s (%s) | Lootbags %s (%s)\n"
            .. "Native routes: Claim Orbs %s | Collect Lootbag %s\n"
            .. "Orbs: pending %d/%d | events/batches/IDs %d/%d/%d | error/overflow/drop %d/%d/%d\n"
            .. "Lootbags: waiting %d | events/sent/ack/retry/skip/error %d/%d/%d/%d/%d/%d\n"
            .. "Retention: unsent orb IDs + unacknowledged bag IDs only",
        run.OrbGate and "direct" or "fallback",
        run.OrbGateReason,
        run.BagGate and "direct" or "fallback",
        run.BagGateReason,
        run.RouteOrbs,
        run.RouteLootbags,
        run.PendingOrbCount,
        MAX_PENDING_ORBS,
        run.OrbEvents,
        run.OrbBatches,
        run.OrbIdsSent,
        run.OrbErrors,
        run.OrbOverflow,
        run.OrbDropped,
        run.WaitingBagCount,
        run.BagEvents,
        run.BagSent,
        run.BagAcked,
        run.BagRetried,
        run.BagSkipped,
        run.BagErrors
    )
end

local function armStatus()
    if run.StatusArmed then return end
    run.StatusArmed = true
    local generation = run.Generation
    task.delay(STATUS_INTERVAL, function()
        if generation ~= run.Generation then return end
        run.StatusArmed = false
        local context = run.Context
        local text = statusText()
        if text ~= run.LastStatusText and context
            and type(context.Status) == "function" then
            run.LastStatusText = text
            pcall(context.Status, text)
        end
    end)
end

local function fire(command, ...)
    local context = run.Context
    if not context or type(context.Fire) ~= "function" then
        return false, "native fire route is unavailable", "unavailable"
    end
    local called, sent, problem, route = pcall(context.Fire, command, ...)
    if not called then return false, tostring(sent), "unavailable" end
    return sent == true, problem, tostring(route or "unavailable")
end

local function safeField(object, key)
    local ok, value = pcall(function() return object[key] end)
    return ok and value or nil
end

local function connectionFunction(connection)
    for _, key in ipairs({ "Function", "Callback" }) do
        local value = safeField(connection, key)
        if type(value) == "function" then return value end
    end
    return nil
end

local function functionEnvironment(func)
    local getter = type(getfenv) == "function" and getfenv
        or (debug and type(debug.getfenv) == "function" and debug.getfenv)
    if type(getter) ~= "function" then return nil end
    local ok, environment = pcall(getter, func)
    return ok and type(environment) == "table" and environment or nil
end

local function functionSource(func)
    if debug and type(debug.info) == "function" then
        local ok, source = pcall(debug.info, func, "s")
        if ok and type(source) == "string" then return source end
    end
    if debug and type(debug.getinfo) == "function" then
        local ok, info = pcall(debug.getinfo, func, "S")
        if ok and type(info) == "table" then
            return tostring(info.source or info.short_src or "")
        end
    end
    return ""
end

local function functionUpvalues(func)
    local getter = type(getupvalues) == "function" and getupvalues
        or (debug and type(debug.getupvalues) == "function" and debug.getupvalues)
    if type(getter) ~= "function" then return nil end
    local ok, values = pcall(getter, func)
    return ok and type(values) == "table" and values or nil
end

local function textMatchesScript(text, scriptName)
    text = string.lower(tostring(text or ""))
    local target = string.lower(tostring(scriptName or ""))
    if text == target then return true end
    return string.find(text, "scripts.game." .. target, 1, true) ~= nil
        or string.find(text, "/game/" .. target, 1, true) ~= nil
        or string.find(text, "\\game\\" .. target, 1, true) ~= nil
        or string.find(text, "." .. target, 1, true) ~= nil
end

local function functionBelongsToScript(func, scriptName, depth, seen)
    if type(func) ~= "function" then return false end
    depth = tonumber(depth) or 0
    seen = seen or {}
    if seen[func] then return false end
    seen[func] = true

    local environment = functionEnvironment(func)
    local sourceScript = environment and environment.script
    if typeof(sourceScript) == "Instance" then
        if sourceScript.Name == scriptName then return true end
        local ok, fullName = pcall(function() return sourceScript:GetFullName() end)
        if ok and textMatchesScript(fullName, scriptName) then return true end
    end
    if textMatchesScript(functionSource(func), scriptName) then return true end
    if depth >= 1 then return false end

    local upvalues = functionUpvalues(func)
    if upvalues then
        for _, value in pairs(upvalues) do
            if type(value) == "function"
                and functionBelongsToScript(value, scriptName, depth + 1, seen) then
                return true
            end
        end
    end
    return false
end

local function setConnectionEnabled(connection, enabled)
    local methodName = enabled and "Enable" or "Disable"
    local method = safeField(connection, methodName)
    if type(method) ~= "function" then return false end
    local ok = pcall(method, connection)
    return ok == true
end

local function connectionWasEnabled(connection)
    local enabled = safeField(connection, "Enabled")
    return enabled == nil or enabled == true
end

local function restoreDisabled(list)
    for index = #list, 1, -1 do
        local entry = list[index]
        list[index] = nil
        if entry and entry.Connection and entry.WasEnabled then
            setConnectionEnabled(entry.Connection, true)
        end
    end
end

local function disableScriptConnections(signal, scriptName, output)
    if not signal or type(getconnections) ~= "function" then
        return 0, "getconnections unavailable"
    end
    local ok, connections = pcall(getconnections, signal)
    if not ok or type(connections) ~= "table" then
        return 0, "connection enumeration failed"
    end
    local disabled = 0
    for _, connection in ipairs(connections) do
        local func = connectionFunction(connection)
        if func and functionBelongsToScript(func, scriptName) then
            local wasEnabled = connectionWasEnabled(connection)
            if wasEnabled and setConnectionEnabled(connection, false) then
                output[#output + 1] = {
                    Connection = connection,
                    WasEnabled = true,
                }
                disabled = disabled + 1
            end
        end
    end
    if disabled > 0 then return disabled, nil end
    return 0, "matching game callback not found"
end

local function networkSignal(name)
    local context = run.Context
    local network = context and context.Library and context.Library.Network
    if not network or type(network.Fired) ~= "function" then
        return nil, "Library.Network.Fired unavailable"
    end
    local ok, signal = pcall(network.Fired, name)
    if not ok or not signal or type(signal.Connect) ~= "function" then
        return nil, "named event unavailable: " .. tostring(name)
    end
    return signal
end

local armOrbFlush

local function flushOrbs()
    run.OrbFlushArmed = false
    if not orbsEnabled() or run.PendingOrbCount == 0 then return end

    local ids = {}
    for orbId in pairs(run.PendingOrbIds) do
        ids[#ids + 1] = orbId
        if #ids >= ORB_BATCH_SIZE then break end
    end
    if #ids == 0 then
        table.clear(run.PendingOrbIds)
        run.PendingOrbCount = 0
        return
    end

    local sent, _, route = fire("Claim Orbs", ids)
    run.RouteOrbs = route
    if sent then
        for _, orbId in ipairs(ids) do
            if run.PendingOrbIds[orbId] then
                run.PendingOrbIds[orbId] = nil
                run.PendingOrbCount = math.max(run.PendingOrbCount - 1, 0)
            end
        end
        run.OrbBatches = run.OrbBatches + 1
        run.OrbIdsSent = run.OrbIdsSent + #ids
        run.OrbRetrySpent = false
        if run.PendingOrbCount > 0 then armOrbFlush() end
    else
        run.OrbErrors = run.OrbErrors + 1
        if not run.OrbRetrySpent then
            run.OrbRetrySpent = true
            armOrbFlush()
        else
            for _, orbId in ipairs(ids) do
                if run.PendingOrbIds[orbId] then
                    run.PendingOrbIds[orbId] = nil
                    run.PendingOrbCount = math.max(run.PendingOrbCount - 1, 0)
                    run.OrbDropped = run.OrbDropped + 1
                end
            end
            run.OrbRetrySpent = false
            if run.PendingOrbCount > 0 then armOrbFlush() end
        end
    end
    armStatus()
end

armOrbFlush = function()
    if run.OrbFlushArmed or not orbsEnabled() or run.PendingOrbCount == 0 then return end
    run.OrbFlushArmed = true
    local generation = run.Generation
    local token = run.OrbToken
    task.delay(ORB_FLUSH_INTERVAL, function()
        if generation ~= run.Generation or token ~= run.OrbToken then return end
        flushOrbs()
    end)
end

local function queueOrb(itemOrId, fromEvent)
    if not orbsEnabled() then return end
    local isObject = typeof(itemOrId) == "Instance"
    local orbId = isObject and objectId(itemOrId)
        or (itemOrId ~= nil and tostring(itemOrId) or nil)
    if not orbId or orbId == "" then return end

    if not run.PendingOrbIds[orbId] then
        if run.PendingOrbCount >= MAX_PENDING_ORBS then
            run.OrbOverflow = run.OrbOverflow + 1
            armStatus()
            return
        end
        if run.PendingOrbCount == 0 then run.OrbRetrySpent = false end
        run.PendingOrbIds[orbId] = true
        run.PendingOrbCount = run.PendingOrbCount + 1
    end
    if fromEvent then run.OrbEvents = run.OrbEvents + 1 end
    if isObject then disableLocalPickup(itemOrId) end
    armOrbFlush()
    armStatus()
end

local function removeQueuedOrb(id)
    id = id ~= nil and tostring(id) or nil
    if id and run.PendingOrbIds[id] then
        run.PendingOrbIds[id] = nil
        run.PendingOrbCount = math.max(run.PendingOrbCount - 1, 0)
    end
end

local function disconnectRecord(id)
    local list = run.RecordConnections[id]
    if list then clearConnections(list) end
    run.RecordConnections[id] = nil
end

local function closeBag(record, acknowledged)
    if not record or run.WaitingBags[record.Id] ~= record then return end
    disconnectRecord(record.Id)
    run.WaitingBags[record.Id] = nil
    run.WaitingBagCount = math.max(run.WaitingBagCount - 1, 0)
    if acknowledged then run.BagAcked = run.BagAcked + 1 end
    record.Item = nil
end

local function bagReady(item)
    return readValue(item, "ReadyForCollection") == true
end

local function payloadWorldAllowed(payload)
    if type(payload) ~= "table" or payload.world == nil then return true end
    local context = run.Context
    local save = context and context.Library and context.Library.Save
    local ok, data = pcall(function()
        return save and type(save.Get) == "function" and save.Get() or nil
    end)
    return not ok or type(data) ~= "table"
        or data.World == nil or data.World == payload.world
end

local function payloadOwnerAllowed(payload)
    if type(payload) ~= "table" then return true end
    local localPlayer = Players.LocalPlayer
    if not localPlayer then return true end
    for _, key in ipairs({ "OwnerUserId", "UserId", "Owner", "Player", "User" }) do
        local value = payload[key]
        if typeof(value) == "Instance" and value:IsA("Player") then
            return value == localPlayer
        end
        if type(value) == "number" and value > 0 then
            return value == localPlayer.UserId
        end
        if type(value) == "string" and value ~= "" then
            local numeric = tonumber(value)
            if numeric and numeric > 0 then return numeric == localPlayer.UserId end
            local lowered = string.lower(value)
            if lowered == string.lower(localPlayer.Name)
                or lowered == string.lower(localPlayer.DisplayName) then
                return true
            end
            local ownerPlayer = Players:FindFirstChild(value)
            if ownerPlayer then return ownerPlayer == localPlayer end
        end
    end
    return true
end

local processBagWake

local function armBagWake(delaySeconds)
    if not bagsEnabled() or run.WaitingBagCount == 0 then return end
    local target = os.clock() + math.max(tonumber(delaySeconds) or 0, 0)
    if run.BagWakeArmed and run.BagWakeAt and run.BagWakeAt <= target then return end

    run.BagWakeSerial = run.BagWakeSerial + 1
    local serial = run.BagWakeSerial
    local generation = run.Generation
    local token = run.BagToken
    run.BagWakeArmed = true
    run.BagWakeAt = target
    task.delay(math.max(target - os.clock(), 0), function()
        if generation ~= run.Generation or token ~= run.BagToken
            or serial ~= run.BagWakeSerial then return end
        run.BagWakeArmed = false
        run.BagWakeAt = nil
        processBagWake()
    end)
end

local function tryCollectBag(record)
    if not record or run.WaitingBags[record.Id] ~= record or not bagsEnabled() then return end
    local now = os.clock()

    if record.EventOnly then
        if now < (record.NextAttempt or 0) then
            armBagWake(record.NextAttempt - now)
            return
        end
        if record.Attempts >= 2 then
            run.BagErrors = run.BagErrors + 1
            closeBag(record, false)
            armStatus()
            return
        end
    else
        local item = record.Item
        if not item or not item.Parent then
            closeBag(record, false)
            armStatus()
            return
        end
        if not bagReady(item) then return end
        record.Position = objectPosition(item)
    end

    local position = normalizePosition(record.Position)
    if not position then
        run.BagErrors = run.BagErrors + 1
        closeBag(record, false)
        armStatus()
        return
    end

    local sent, _, route = fire("Collect Lootbag", record.Id, position)
    run.RouteLootbags = route or "unavailable"
    record.Attempts = record.Attempts + 1
    if record.EventOnly and record.Attempts == 2 then
        run.BagRetried = run.BagRetried + 1
    end
    if sent then
        run.BagSent = run.BagSent + 1
        if record.EventOnly then
            record.NextAttempt = now + (record.Attempts == 1
                and BAG_ACK_TIMEOUT or BAG_FINAL_ACK_TIMEOUT)
            armBagWake(record.NextAttempt - now)
        else
            disableLocalPickup(record.Item)
            closeBag(record, false)
        end
    elseif record.EventOnly and record.Attempts < 2 then
        record.NextAttempt = now + 0.2
        armBagWake(0.2)
    else
        run.BagErrors = run.BagErrors + 1
        closeBag(record, false)
    end
    armStatus()
end

processBagWake = function()
    if not bagsEnabled() then return end
    local now = os.clock()
    local due = {}
    local nextAt
    for _, record in pairs(run.WaitingBags) do
        if record.EventOnly then
            local at = tonumber(record.NextAttempt) or now
            if at <= now then
                due[#due + 1] = record
            elseif not nextAt or at < nextAt then
                nextAt = at
            end
        end
    end
    for _, record in ipairs(due) do tryCollectBag(record) end
    if nextAt and run.WaitingBagCount > 0 then
        armBagWake(math.max(nextAt - os.clock(), 0))
    end
end

local function watchReadyChild(record, child)
    if not child or (child.Name ~= "ReadyForCollection"
        and child.Name ~= "ReadyForCollection_Attr") then return end
    if child:IsA("ValueBase") then
        local list = run.RecordConnections[record.Id]
        if list then
            list[#list + 1] = child.Changed:Connect(function()
                tryCollectBag(record)
            end)
        end
    end
    tryCollectBag(record)
end

local function watchBag(item)
    if not bagsEnabled() or not item then return end
    local context = run.Context
    if context and type(context.LocalLootOwner) == "function" then
        local checked, allowed, resolved = pcall(context.LocalLootOwner, item)
        if checked and resolved == true and allowed ~= true then
            run.BagSkipped = run.BagSkipped + 1
            armStatus()
            return
        end
    end

    local id = objectId(item)
    if not id or run.WaitingBags[id] then return end
    local record = {
        Id = id,
        Item = item,
        Position = objectPosition(item),
        EventOnly = false,
        Attempts = 0,
    }
    run.WaitingBags[id] = record
    run.WaitingBagCount = run.WaitingBagCount + 1

    if bagReady(item) then
        tryCollectBag(record)
        return
    end

    local list = {}
    run.RecordConnections[id] = list
    local readyValue = item:FindFirstChild("ReadyForCollection_Attr")
        or item:FindFirstChild("ReadyForCollection")
    if readyValue then
        watchReadyChild(record, readyValue)
    else
        list[#list + 1] = item.ChildAdded:Connect(function(child)
            watchReadyChild(record, child)
        end)
        list[#list + 1] = item:GetAttributeChangedSignal(
            "ReadyForCollection"):Connect(function()
                tryCollectBag(record)
            end)
        list[#list + 1] = item:GetAttributeChangedSignal(
            "ReadyForCollection_Attr"):Connect(function()
                tryCollectBag(record)
            end)
    end
    armStatus()
end

local function queueBagEvent(id, payload)
    if not bagsEnabled() then return end
    id = id ~= nil and tostring(id) or nil
    if not id or id == "" or run.WaitingBags[id] then return end
    if not payloadWorldAllowed(payload) or not payloadOwnerAllowed(payload) then
        run.BagSkipped = run.BagSkipped + 1
        armStatus()
        return
    end
    local position = type(payload) == "table"
        and normalizePosition(payload.position or payload.pos or payload.Position) or nil
    if not position then
        run.BagErrors = run.BagErrors + 1
        armStatus()
        return
    end

    local record = {
        Id = id,
        Position = position,
        EventOnly = true,
        Attempts = 0,
        NextAttempt = os.clock() + BAG_FIRST_ATTEMPT_DELAY,
    }
    run.WaitingBags[id] = record
    run.WaitingBagCount = run.WaitingBagCount + 1
    run.BagEvents = run.BagEvents + 1
    armBagWake(BAG_FIRST_ATTEMPT_DELAY)
    armStatus()
end

local function acknowledgeBag(id)
    id = id ~= nil and tostring(id) or nil
    if id then closeBag(run.WaitingBags[id], true) end
    armStatus()
end

local function clearOrbBinding()
    run.OrbToken = run.OrbToken + 1
    clearConnections(run.OrbConnections)
    run.OrbFolder = nil
    table.clear(run.PendingOrbIds)
    run.PendingOrbCount = 0
    run.OrbFlushArmed = false
    run.OrbRetrySpent = false
end

local function clearBagBinding()
    run.BagToken = run.BagToken + 1
    run.BagWakeSerial = run.BagWakeSerial + 1
    clearConnections(run.BagConnections)
    for _, list in pairs(run.RecordConnections) do clearConnections(list) end
    table.clear(run.RecordConnections)
    table.clear(run.WaitingBags)
    run.WaitingBagCount = 0
    run.BagWakeArmed = false
    run.BagWakeAt = nil
    run.LootbagFolder = nil
end

local function restoreOrbGate()
    clearConnections(run.OrbGateConnections)
    restoreDisabled(run.DisabledOrbs)
    run.OrbGate = false
end

local function restoreBagGate()
    clearConnections(run.BagGateConnections)
    restoreDisabled(run.DisabledBags)
    run.BagGate = false
end

local function clearWorld()
    clearConnections(run.ThingsConnections)
    clearOrbBinding()
    clearBagBinding()
    run.Things = nil
end

local function scanFolder(folder, callback)
    if not folder then return end
    for _, item in ipairs(folder:GetChildren()) do callback(item) end
end

local function bindOrbGate()
    restoreOrbGate()
    run.OrbGateReason = "disabled"
    if not orbsEnabled() then return false end

    local addedSignal, signalProblem = networkSignal("Orb Added")
    if not addedSignal then
        run.OrbGateReason = signalProblem
        return false
    end
    local removedSignal = networkSignal("Orb Removed")
    local disabled, disableProblem = disableScriptConnections(
        addedSignal, "Orbs", run.DisabledOrbs
    )
    if disabled == 0 then
        restoreDisabled(run.DisabledOrbs)
        run.OrbGateReason = disableProblem or "Orb Added callback not isolated"
        return false
    end

    local steppedDisabled = select(1, disableScriptConnections(
        RunService.Stepped, "Orbs", run.DisabledOrbs
    ))
    local heartbeatDisabled = select(1, disableScriptConnections(
        RunService.Heartbeat, "Orbs", run.DisabledOrbs
    ))
    run.OrbGateConnections[#run.OrbGateConnections + 1] =
        addedSignal:Connect(function(id)
            queueOrb(id, true)
        end)
    if removedSignal then
        run.OrbGateConnections[#run.OrbGateConnections + 1] =
            removedSignal:Connect(removeQueuedOrb)
    end
    run.OrbGate = true
    run.OrbGateReason = string.format(
        "%d producer + %d frame callbacks gated",
        disabled,
        steppedDisabled + heartbeatDisabled
    )
    return true
end

local function bindBagGate()
    restoreBagGate()
    run.BagGateReason = "disabled"
    if not bagsEnabled() then return false end

    local spawnSignal, signalProblem = networkSignal("Spawn Lootbag")
    if not spawnSignal then
        run.BagGateReason = signalProblem
        return false
    end
    local removeSignal = networkSignal("Remove Lootbag")
    local disabled, disableProblem = disableScriptConnections(
        spawnSignal, "Lootbags", run.DisabledBags
    )
    if disabled == 0 then
        restoreDisabled(run.DisabledBags)
        run.BagGateReason = disableProblem or "Spawn Lootbag callback not isolated"
        return false
    end

    run.BagGateConnections[#run.BagGateConnections + 1] =
        spawnSignal:Connect(queueBagEvent)
    if removeSignal then
        run.BagGateConnections[#run.BagGateConnections + 1] =
            removeSignal:Connect(acknowledgeBag)
    end
    run.BagGate = true
    run.BagGateReason = string.format("%d visual producer gated", disabled)
    return true
end

local function bindOrbFolder(folder)
    clearOrbBinding()
    run.OrbFolder = folder
    if not folder or not orbsEnabled() then return end
    if not run.OrbGate then
        run.OrbConnections[#run.OrbConnections + 1] =
            folder.ChildAdded:Connect(queueOrb)
    end
    scanFolder(folder, queueOrb)
end

local function bindLootbagFolder(folder)
    clearBagBinding()
    run.LootbagFolder = folder
    if not folder or not bagsEnabled() then return end
    if not run.BagGate then
        run.BagConnections[#run.BagConnections + 1] =
            folder.ChildAdded:Connect(watchBag)
    end
    run.BagConnections[#run.BagConnections + 1] =
        folder.ChildRemoved:Connect(function(item)
            local id = objectId(item)
            if id then acknowledgeBag(id) end
        end)
    scanFolder(folder, watchBag)
end

local function resolveThings()
    local context = run.Context
    local things = context and type(context.GetThings) == "function"
        and context.GetThings() or workspace:FindFirstChild("__THINGS")
    return typeof(things) == "Instance" and things or nil
end

local function reconcileGates(refreshOrbs, refreshBags)
    if refreshOrbs then
        if run.OrbsOn then bindOrbGate() else restoreOrbGate() end
    end
    if refreshBags then
        if run.BagsOn then bindBagGate() else restoreBagGate() end
    end
end

local bindRoots

bindRoots = function(resetAll, refreshOrbs, refreshBags)
    if not contextRunning() then return end
    local things = resolveThings()
    if resetAll or things ~= run.Things then
        clearWorld()
        run.Things = things
        refreshOrbs, refreshBags = true, true
        if things then
            run.ThingsConnections[#run.ThingsConnections + 1] =
                things.ChildAdded:Connect(function(child)
                    if child.Name == "Orbs" then bindOrbFolder(child) end
                    if child.Name == "Lootbags" then bindLootbagFolder(child) end
                end)
            run.ThingsConnections[#run.ThingsConnections + 1] =
                things.ChildRemoved:Connect(function(child)
                    if child == run.OrbFolder then bindOrbFolder(nil) end
                    if child == run.LootbagFolder then bindLootbagFolder(nil) end
                end)
        end
    end
    if not things then return end
    if refreshOrbs then bindOrbFolder(things:FindFirstChild("Orbs")) end
    if refreshBags then bindLootbagFolder(things:FindFirstChild("Lootbags")) end
    armStatus()
end

local function resetStats()
    run.RouteOrbs = "unavailable"
    run.RouteLootbags = "unavailable"
    run.OrbBatches = 0
    run.OrbIdsSent = 0
    run.OrbEvents = 0
    run.OrbErrors = 0
    run.OrbOverflow = 0
    run.OrbDropped = 0
    run.BagEvents = 0
    run.BagSent = 0
    run.BagAcked = 0
    run.BagRetried = 0
    run.BagSkipped = 0
    run.BagErrors = 0
    run.LastStatusText = nil
end

local function start(context)
    if type(context) ~= "table" then return false, "context table required" end
    run.Generation = run.Generation + 1
    clearConnections(run.Connections)
    clearWorld()
    restoreOrbGate()
    restoreBagGate()
    run.Context = context
    run.Active = true
    run.StatusArmed = false
    run.OrbsOn, run.BagsOn = wantedFlags()
    resetStats()
    local generation = run.Generation

    reconcileGates(true, true)
    run.Connections[#run.Connections + 1] = workspace.ChildAdded:Connect(function(child)
        if child.Name == "__THINGS" and generation == run.Generation then
            bindRoots(true, true, true)
        end
    end)
    local signal = context.Library and context.Library.Signal
    if signal and type(signal.Fired) == "function" then
        local ok, connection = pcall(function()
            return signal.Fired("World Changed"):Connect(function()
                if generation ~= run.Generation then return end
                task.defer(function()
                    if generation == run.Generation then
                        bindRoots(true, true, true)
                    end
                end)
            end)
        end)
        if ok and connection then
            run.Connections[#run.Connections + 1] = connection
        end
    end
    bindRoots(true, true, true)
    return true
end

local function stop()
    run.Generation = run.Generation + 1
    run.Active = false
    clearConnections(run.Connections)
    clearWorld()
    restoreOrbGate()
    restoreBagGate()
    run.Context = nil
    run.OrbsOn = false
    run.BagsOn = false
    run.StatusArmed = false
    run.LastStatusText = nil
    return true
end

local function sync()
    if not run.Context then return false, "reactor is not started" end
    local orbs, bags = wantedFlags()
    if not orbs and not bags then return stop() end
    local refreshOrbs = orbs ~= run.OrbsOn
    local refreshBags = bags ~= run.BagsOn
    run.OrbsOn, run.BagsOn = orbs, bags
    reconcileGates(refreshOrbs, refreshBags)
    if refreshOrbs or refreshBags or resolveThings() ~= run.Things then
        bindRoots(false, refreshOrbs, refreshBags)
    end
    armStatus()
    return true
end

local function stats()
    return {
        Version = MODULE_VERSION,
        OrbGate = run.OrbGate,
        BagGate = run.BagGate,
        OrbGateReason = run.OrbGateReason,
        BagGateReason = run.BagGateReason,
        PendingOrbs = run.PendingOrbCount,
        WaitingBags = run.WaitingBagCount,
        OrbEvents = run.OrbEvents,
        OrbBatches = run.OrbBatches,
        OrbIdsSent = run.OrbIdsSent,
        OrbErrors = run.OrbErrors,
        OrbOverflow = run.OrbOverflow,
        OrbDropped = run.OrbDropped,
        BagEvents = run.BagEvents,
        BagSent = run.BagSent,
        BagAcked = run.BagAcked,
        BagRetried = run.BagRetried,
        BagSkipped = run.BagSkipped,
        BagErrors = run.BagErrors,
    }
end

return function(action, context)
    if action == "start" then return start(context) end
    if action == "sync" then return sync() end
    if action == "stop" then return stop() end
    if action == "stats" then return stats() end
    if action == "version" then return MODULE_VERSION end
    return false, "unknown action"
end
