-- Native zero-physics loot collection for PSX OG.
-- Retained state contains only unsent orb IDs and genuinely unready lootbags.

local MODULE_VERSION = "1.2.0"
local ORB_FLUSH_INTERVAL = 0.25
local ORB_BATCH_SIZE = 2048
local MAX_PENDING_ORBS = 8192
local BAG_RETRY_DELAY = 0.2
local STATUS_INTERVAL = 1

local run = {
    Context = nil,
    Generation = 0,
    Active = false,
    Connections = {},
    ThingsConnections = {},
    OrbConnections = {},
    BagConnections = {},
    RecordConnections = {},
    Things = nil,
    OrbFolder = nil,
    LootbagFolder = nil,
    OrbsOn = false,
    BagsOn = false,
    OrbToken = 0,
    BagToken = 0,
    PendingOrbIds = {},
    PendingOrbCount = 0,
    OrbFlushArmed = false,
    OrbRetrySpent = false,
    WaitingBags = {},
    WaitingBagCount = 0,
    RetryBags = {},
    RetryArmed = false,
    StatusArmed = false,
    LastStatusText = nil,
    RouteOrbs = "unavailable",
    RouteLootbags = "unavailable",
    OrbBatches = 0,
    OrbIdsSent = 0,
    OrbErrors = 0,
    OrbOverflow = 0,
    OrbDropped = 0,
    BagSent = 0,
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

local function objectPosition(object)
    if not object then return nil end
    if object:IsA("BasePart") then return object.Position end
    if object:IsA("Model") then
        local primary = object.PrimaryPart
        if primary then return primary.Position end
        local part = object:FindFirstChildWhichIsA("BasePart", true)
        if part then return part.Position end
    end
    local position = readValue(object, "Position") or readValue(object, "POS")
    if typeof(position) == "CFrame" then return position.Position end
    return typeof(position) == "Vector3" and position or nil
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
        "Native routes: Claim Orbs %s | Collect Lootbag %s\n"
            .. "Orbs: pending %d/%d | batches/IDs %d/%d | error/overflow/drop %d/%d/%d\n"
            .. "Lootbags: waiting %d | sent/retried/skipped/error %d/%d/%d/%d\n"
            .. "Retention: current ID set + unready bags only; no physics or ack history",
        run.RouteOrbs,
        run.RouteLootbags,
        run.PendingOrbCount,
        MAX_PENDING_ORBS,
        run.OrbBatches,
        run.OrbIdsSent,
        run.OrbErrors,
        run.OrbOverflow,
        run.OrbDropped,
        run.WaitingBagCount,
        run.BagSent,
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

local function queueOrb(itemOrId)
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
    if isObject then disableLocalPickup(itemOrId) end
    armOrbFlush()
    armStatus()
end

local function disconnectRecord(id)
    local list = run.RecordConnections[id]
    if list then clearConnections(list) end
    run.RecordConnections[id] = nil
end

local function closeBag(record)
    if not record or run.WaitingBags[record.Id] ~= record then return end
    disconnectRecord(record.Id)
    run.RetryBags[record.Id] = nil
    run.WaitingBags[record.Id] = nil
    run.WaitingBagCount = math.max(run.WaitingBagCount - 1, 0)
    record.Item = nil
end

local function bagReady(item)
    return readValue(item, "ReadyForCollection") == true
end

local tryCollectBag
local armBagRetry

tryCollectBag = function(record, retrying)
    if not record or run.WaitingBags[record.Id] ~= record or not bagsEnabled() then return end
    if record.RetryQueued and not retrying then return end
    local item = record.Item
    if not item or not item.Parent then
        closeBag(record)
        armStatus()
        return
    end
    if not bagReady(item) then return end

    record.RetryQueued = false
    local position = objectPosition(item)
    local sent, _, route
    if position then
        sent, _, route = fire("Collect Lootbag", record.Id, position)
    else
        sent, route = false, "unavailable"
    end
    run.RouteLootbags = route or "unavailable"
    if sent then
        run.BagSent = run.BagSent + 1
        disableLocalPickup(item)
        closeBag(record)
    elseif not retrying and record.RetryCount == 0 then
        record.RetryCount = 1
        record.RetryQueued = true
        run.RetryBags[record.Id] = record
        run.BagRetried = run.BagRetried + 1
        armBagRetry()
    else
        run.BagErrors = run.BagErrors + 1
        closeBag(record)
    end
    armStatus()
end

armBagRetry = function()
    if run.RetryArmed then return end
    run.RetryArmed = true
    local generation = run.Generation
    local token = run.BagToken
    task.delay(BAG_RETRY_DELAY, function()
        if generation ~= run.Generation or token ~= run.BagToken
            or not bagsEnabled() then return end
        run.RetryArmed = false
        local retry = run.RetryBags
        run.RetryBags = {}
        for _, record in pairs(retry) do
            tryCollectBag(record, true)
        end
    end)
end

local function watchReadyChild(record, child)
    if not child or (child.Name ~= "ReadyForCollection"
        and child.Name ~= "ReadyForCollection_Attr") then return end
    if child:IsA("ValueBase") then
        local list = run.RecordConnections[record.Id]
        if list then
            list[#list + 1] = child.Changed:Connect(function()
                tryCollectBag(record, false)
            end)
        end
    end
    tryCollectBag(record, false)
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
        RetryCount = 0,
        RetryQueued = false,
    }
    run.WaitingBags[id] = record
    run.WaitingBagCount = run.WaitingBagCount + 1

    if bagReady(item) then
        tryCollectBag(record, false)
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
                tryCollectBag(record, false)
            end)
        list[#list + 1] = item:GetAttributeChangedSignal(
            "ReadyForCollection_Attr"):Connect(function()
                tryCollectBag(record, false)
            end)
    end
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
    clearConnections(run.BagConnections)
    for _, list in pairs(run.RecordConnections) do clearConnections(list) end
    table.clear(run.RecordConnections)
    table.clear(run.WaitingBags)
    run.WaitingBagCount = 0
    table.clear(run.RetryBags)
    run.RetryArmed = false
    run.LootbagFolder = nil
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

local function bindOrbFolder(folder)
    clearOrbBinding()
    run.OrbFolder = folder
    if not folder or not orbsEnabled() then return end
    run.OrbConnections[#run.OrbConnections + 1] =
        folder.ChildAdded:Connect(queueOrb)
    scanFolder(folder, queueOrb)
end

local function bindLootbagFolder(folder)
    clearBagBinding()
    run.LootbagFolder = folder
    if not folder or not bagsEnabled() then return end
    run.BagConnections[#run.BagConnections + 1] =
        folder.ChildAdded:Connect(watchBag)
    run.BagConnections[#run.BagConnections + 1] =
        folder.ChildRemoved:Connect(function(item)
            local id = objectId(item)
            if id then closeBag(run.WaitingBags[id]) end
        end)
    scanFolder(folder, watchBag)
end

local function resolveThings()
    local context = run.Context
    local things = context and type(context.GetThings) == "function"
        and context.GetThings() or workspace:FindFirstChild("__THINGS")
    return typeof(things) == "Instance" and things or nil
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
    run.OrbErrors = 0
    run.OrbOverflow = 0
    run.OrbDropped = 0
    run.BagSent = 0
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
    run.Context = context
    run.Active = true
    run.StatusArmed = false
    run.OrbsOn, run.BagsOn = wantedFlags()
    resetStats()
    local generation = run.Generation

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
    if refreshOrbs or refreshBags or resolveThings() ~= run.Things then
        bindRoots(false, refreshOrbs, refreshBags)
    end
    return true
end

local function stats()
    return {
        Version = MODULE_VERSION,
        PendingOrbs = run.PendingOrbCount,
        WaitingBags = run.WaitingBagCount,
        OrbBatches = run.OrbBatches,
        OrbIdsSent = run.OrbIdsSent,
        OrbErrors = run.OrbErrors,
        OrbOverflow = run.OrbOverflow,
        OrbDropped = run.OrbDropped,
        BagSent = run.BagSent,
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
