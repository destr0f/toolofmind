-- Producer-gated loot collection for PSX OG.
-- The preferred Orbs path replaces the game LocalScript's global AddOrb
-- before it can allocate any physical or visual Instances. Coins use the same
-- technique only while the suite's full headless/anti-lag mode is enabled.
-- Unsupported executors fall back to read-only ID observation.

local MODULE_VERSION = "3.6.7"
local ORB_BATCH_SIZE = 512
local MAX_PENDING_ORBS = 8192
local ORB_FLUSH_INTERVAL = 0.55
local MAX_ORB_DELIVERY_ATTEMPTS = 2
local ORB_CONFIRM_MIN_DELAY = 2.5
local ORB_CONFIRM_MAX_DELAY = 8
local CLIENT_STAGGER_SLOTS = 16
local CLIENT_STAGGER_STEP = 0.01
local TRAFFIC_STAGGER_SLOTS = 29
local TRAFFIC_STAGGER_STEP = 0.025
local BAG_LANES = 4
local MAX_PENDING_BAGS = 4096
local BAG_FIRST_ATTEMPT_DELAY = 0.05
local BAG_TRANSPORT_RETRY_DELAY = 0.10
local MAX_BAG_TRANSPORT_ATTEMPTS = 2
local BAG_CONFIRM_MIN_DELAY = 0.60
local BAG_CONFIRM_MAX_DELAY = 3.00
local MAX_BAG_POOL = 256
local STATUS_INTERVAL = 1
local NATIVE_PET_COIN_SHELL_ATTRIBUTE = "PSXHeadlessTargetShell"
local NATIVE_PET_COIN_STAGE = "__PSX_HEADLESS_TARGET__"

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

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
    ProducerConnections = {},
    PlayerScriptConnections = {},
    Things = nil,
    OrbFolder = nil,
    LootbagFolder = nil,
    OrbsOn = false,
    BagsOn = false,
    OrbGate = false,
    BagGate = false,
    OrbGateReason = "not armed",
    BagGateReason = "not armed",
    OrbsProducer = "unavailable",
    LootbagsProducer = "unavailable",
    CoinsProducer = "visual",
    CoinGateReason = "headless disabled",
    OrbProducerRecord = nil,
    BagProducerRecord = nil,
    CoinProducerRecord = nil,
    NativeLootbagCollect = nil,
    PlayerScripts = nil,
    ProducerRebindArmed = false,
    ProducerRebindSerial = 0,
    GateGeneration = 0,
    LastRebindReason = "startup",
    VisualInstancesPrevented = 0,
    OrbToken = 0,
    BagToken = 0,
    BagWakeSerial = 0,
    -- Pending contains unsent IDs. Unconfirmed retains only IDs whose
    -- FireServer call returned locally but have not produced Orb Removed yet.
    PendingOrbIds = {},
    UnconfirmedOrbIds = {},
    OrbDeliveryAttempts = {},
    OrbTransportFailures = {},
    PendingOrbCount = 0,
    UnconfirmedOrbCount = 0,
    OrbBatch = table.create(ORB_BATCH_SIZE),
    OrbFlushArmed = false,
    OrbConfirmArmed = false,
    OrbRetryArmed = false,
    OrbLastFlushAt = 0,
    OrbIdleBursts = 0,
    BagById = {},
    BagQueue = {},
    BagQueueHead = 1,
    BagDelayed = {},
    BagPool = {},
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
    OrbDeduplicated = 0,
    OrbMaxBatch = 0,
    OrbLocalSentUnacked = 0,
    OrbTransportCommitted = 0,
    OrbAckAvailable = false,
    OrbAckObserved = false,
    OrbAcked = 0,
    OrbRetried = 0,
    OrbExpiredUnverified = 0,
    BagEvents = 0,
    BagSent = 0,
    BagAcked = 0,
    BagRetried = 0,
    BagSkipped = 0,
    BagErrors = 0,
    BagOverflow = 0,
    BagRetiredNoAck = 0,
    BagSentUnverifiable = 0,
    BagObjectAcknowledged = 0,
    BagNetworkAcknowledged = 0,
    BagTransportCommitted = 0,
    BagTransportDropped = 0,
    BagAckAvailable = false,
    BagAckObserved = false,
    BagLocalDestroyed = 0,
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

local function coinsHeadlessEnabled()
    local context = run.Context
    if not contextRunning() or not context
        or type(context.HeadlessCoins) ~= "function" then
        return false
    end
    local ok, enabled = pcall(context.HeadlessCoins)
    return ok and enabled == true
end

local function coinCatalogReady()
    local context = run.Context
    if not contextRunning() or not context
        or type(context.CoinCatalogReady) ~= "function" then
        return false
    end
    local ok, ready = pcall(context.CoinCatalogReady)
    return ok and ready == true
end

local function coinRecordReady(rawId)
    local context = run.Context
    if rawId == nil or not contextRunning() or not context
        or type(context.CoinRecordReady) ~= "function" then
        return false
    end
    local ok, ready = pcall(context.CoinRecordReady, rawId)
    return ok and ready == true
end

local function recoverCoinRecord(rawId)
    local context = run.Context
    if rawId == nil or not contextRunning() or not context
        or type(context.RecoverCoinRecord) ~= "function" then
        return false
    end
    local ok, recovered = pcall(context.RecoverCoinRecord, rawId)
    return ok and recovered == true
end

local function readFunctionUpvalueTables(callback)
    local tables = {}
    if type(callback) ~= "function" then return tables end
    local reader = type(getupvalues) == "function" and getupvalues
        or (debug and type(debug.getupvalues) == "function" and debug.getupvalues)
    if type(reader) == "function" then
        local ok, values = pcall(reader, callback)
        if ok and type(values) == "table" then
            for _, value in pairs(values) do
                if type(value) == "table" then tables[#tables + 1] = value end
            end
        end
        return tables
    end
    local indexedReader = debug and debug.getupvalue
    if type(indexedReader) ~= "function" then return tables end
    for index = 1, 32 do
        local ok, first, second = pcall(indexedReader, callback, index)
        if not ok or first == nil then break end
        local value = second ~= nil and second or first
        if type(value) == "table" then tables[#tables + 1] = value end
    end
    return tables
end

local function coinDataFromProducer(record, rawId)
    if rawId == nil then return nil end
    local textId = tostring(rawId)
    local numericId = tonumber(rawId)
    for _, candidate in ipairs(record.CoinDataTables or {}) do
        local data = rawget(candidate, rawId) or rawget(candidate, textId)
        if data == nil and numericId ~= nil then data = rawget(candidate, numericId) end
        if type(data) == "table"
            and (data.p ~= nil or data.Position ~= nil or data.position ~= nil)
            and (data.n ~= nil or data.Name ~= nil or data.name ~= nil) then
            return data
        end
    end
    return nil
end

local function profileBegin(label)
    local begin = debug and debug.profilebegin
    if type(begin) ~= "function" then return false end
    local ok = pcall(begin, label)
    return ok == true
end

local function profileEnd(started)
    if not started then return end
    local finish = debug and debug.profileend
    if type(finish) == "function" then pcall(finish) end
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

local function clientStagger()
    local player = Players.LocalPlayer
    local userId = tonumber(player and player.UserId) or 0
    return (math.abs(userId) % CLIENT_STAGGER_SLOTS) * CLIENT_STAGGER_STEP
end

local function currentRTT()
    local context = run.Context
    if not context then return 0 end
    local rtt = 0
    if type(context.GetRTT) == "function" then
        local ok, value = pcall(context.GetRTT)
        if ok then rtt = math.max(tonumber(value) or 0, 0) end
    end
    if type(context.GetPingSeconds) == "function" then
        local ok, value = pcall(context.GetPingSeconds)
        if ok then rtt = math.max(rtt, tonumber(value) or 0) end
    end
    return rtt
end

local function lowTrafficActive()
    local context = run.Context
    if not context or type(context.LowTraffic) ~= "function" then return false end
    local ok, active = pcall(context.LowTraffic)
    return ok and active == true
end

local function trafficStagger()
    local player = Players.LocalPlayer
    local userId = math.abs(tonumber(player and player.UserId) or 0)
    local slot = (userId * 17 + 11) % TRAFFIC_STAGGER_SLOTS
    local spread = slot * TRAFFIC_STAGGER_STEP
    local rtt = currentRTT()
    if lowTrafficActive() then
        if rtt >= 1.00 then return 0.45 + spread end
        if rtt >= 0.70 then return 0.32 + spread end
        if rtt >= 0.45 then return 0.22 + spread end
        return 0.12 + spread * 0.75
    end
    if rtt >= 0.70 then return math.min(0.30 + spread * 0.35, 0.50) end
    if rtt >= 0.45 then return math.min(0.18 + spread * 0.25, 0.35) end
    return clientStagger()
end

local function orbFlushInterval()
    local rtt = currentRTT()
    if lowTrafficActive() then
        if rtt >= 1.00 then return 2.65 end
        if rtt >= 0.70 then return 2.10 end
        if rtt >= 0.45 then return 1.55 end
        return 1.25
    end
    if rtt >= 2.00 then return 1.50 end
    if rtt >= 1.25 then return 1.20 end
    if rtt >= 0.80 then return 1.00 end
    if rtt >= 0.50 then return 0.80 end
    if rtt >= 0.25 then return 0.65 end
    return ORB_FLUSH_INTERVAL
end

local function orbConfirmationDelay()
    return math.clamp(currentRTT() * 3, ORB_CONFIRM_MIN_DELAY, ORB_CONFIRM_MAX_DELAY)
end

local function bagConfirmationDelay()
    local multiplier = lowTrafficActive() and 2.75 or 2
    return math.clamp(currentRTT() * multiplier, BAG_CONFIRM_MIN_DELAY, BAG_CONFIRM_MAX_DELAY)
end

local function bagLaneLimit()
    if not lowTrafficActive() then return BAG_LANES end
    local rtt = currentRTT()
    if rtt >= 0.45 then return 1 end
    return 2
end

local function bagWakeDelay()
    if not lowTrafficActive() then return 0 end
    local rtt = currentRTT()
    if rtt >= 1.00 then return 0.55 end
    if rtt >= 0.70 then return 0.42 end
    if rtt >= 0.45 then return 0.30 end
    return 0.18
end

local function bagRetryDelay(record)
    local attempts = tonumber(record and record.Attempts) or 0
    local rtt = currentRTT()
    if lowTrafficActive() then
        return math.clamp(1.10 + rtt + trafficStagger() * 0.35 + attempts * 0.35, 1.10, 3.75)
    end
    return math.clamp(0.45 + rtt * 1.4 + attempts * 0.18, 0.45, 1.75)
end

local function statusText()
    return string.format(
        "Orbs producer: %s (%s) | Coins producer: %s (%s)\n"
            .. "Lootbags producer: %s (%s) | gate generation %d | last rebind: %s\n"
            .. "Native routes: Claim Orbs %s | Collect Lootbag %s\n"
            .. "Prevented visual calls: %d | Claim IDs sent: %d\n"
            .. "Orbs: pending/unconfirmed/ack %d/%d/%d | events/batches %d/%d | retry/expired/error/overflow/drop %d/%d/%d/%d/%d\n"
            .. "Lootbags: waiting %d/%d | lanes %d | events/sent/committed/ack/retry/skip/error/overflow %d/%d/%d/%d/%d/%d/%d/%d\n"
            .. "Retention: bounded Orb Removed and Remove Lootbag confirmation; native visual fallback stays live",
        run.OrbsProducer,
        run.OrbGateReason,
        run.CoinsProducer,
        run.CoinGateReason,
        run.LootbagsProducer,
        run.BagGateReason,
        run.GateGeneration,
        run.LastRebindReason,
        run.RouteOrbs,
        run.RouteLootbags,
        run.VisualInstancesPrevented,
        run.OrbIdsSent,
        run.PendingOrbCount,
        run.UnconfirmedOrbCount,
        run.OrbAcked,
        run.OrbEvents,
        run.OrbBatches,
        run.OrbRetried,
        run.OrbExpiredUnverified,
        run.OrbErrors,
        run.OrbOverflow,
        run.OrbDropped,
        run.WaitingBagCount,
        MAX_PENDING_BAGS,
        bagLaneLimit(),
        run.BagEvents,
        run.BagSent,
        run.BagTransportCommitted,
        run.BagAcked,
        run.BagRetried,
        run.BagSkipped,
        run.BagErrors,
        run.BagOverflow
    )
end

local function statusVisible()
    local context = run.Context
    if not context or type(context.StatusVisible) ~= "function" then return true end
    local ok, visible = pcall(context.StatusVisible)
    return ok and visible == true
end

local function armStatus()
    if run.StatusArmed or not statusVisible() then return end
    run.StatusArmed = true
    local generation = run.Generation
    task.delay(STATUS_INTERVAL, function()
        if generation ~= run.Generation then return end
        run.StatusArmed = false
        local context = run.Context
        if not statusVisible() then return end
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

local function networkSignal(name)
    local context = run.Context
    if context and type(context.GetEventRemote) == "function" then
        local resolved, remote, _, _, problem = pcall(context.GetEventRemote, name)
        if resolved and typeof(remote) == "Instance" and remote:IsA("RemoteEvent")
            and remote:IsDescendantOf(ReplicatedStorage) then
            return remote.OnClientEvent
        end
        if not resolved then problem = remote end
    end
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
local armOrbConfirmation
local payloadOwnerClass

local function reconcileUnconfirmedOrbs()
    run.OrbConfirmArmed = false
    if not orbsEnabled() or run.UnconfirmedOrbCount == 0 then return end
    local now = os.clock()
    local delay = orbConfirmationDelay()
    local nextAt
    for orbId, sentAt in pairs(run.UnconfirmedOrbIds) do
        local dueAt = (tonumber(sentAt) or now) + delay
        if now >= dueAt then
            run.UnconfirmedOrbIds[orbId] = nil
            run.UnconfirmedOrbCount = math.max(run.UnconfirmedOrbCount - 1, 0)
            local attempts = tonumber(run.OrbDeliveryAttempts[orbId]) or 1
            if run.OrbAckObserved and attempts < MAX_ORB_DELIVERY_ATTEMPTS then
                run.PendingOrbIds[orbId] = 0
                run.PendingOrbCount = run.PendingOrbCount + 1
                run.OrbRetried = run.OrbRetried + 1
            else
                run.OrbDeliveryAttempts[orbId] = nil
                run.OrbExpiredUnverified = run.OrbExpiredUnverified + 1
            end
        elseif not nextAt or dueAt < nextAt then
            nextAt = dueAt
        end
    end
    if run.PendingOrbCount > 0 then armOrbFlush(orbFlushInterval()) end
    if run.UnconfirmedOrbCount > 0 then
        armOrbConfirmation(math.max((nextAt or (now + delay)) - now, 0.05))
    end
    armStatus()
end

armOrbConfirmation = function(delaySeconds)
    if run.OrbConfirmArmed or not orbsEnabled() or run.UnconfirmedOrbCount == 0 then return end
    run.OrbConfirmArmed = true
    local generation = run.Generation
    local token = run.OrbToken
    task.delay(math.max(tonumber(delaySeconds) or orbConfirmationDelay(), 0.05), function()
        if generation ~= run.Generation or token ~= run.OrbToken then return end
        reconcileUnconfirmedOrbs()
    end)
end

local function flushOrbs()
    run.OrbFlushArmed = false
    if not orbsEnabled() or run.PendingOrbCount == 0 then return end
    local now = os.clock()
    run.OrbLastFlushAt = now
    local profiled = profileBegin("PSX_OrbFlush")
    local ids = run.OrbBatch
    table.clear(ids)
    for orbId in pairs(run.PendingOrbIds) do
        ids[#ids + 1] = orbId
        if #ids == ORB_BATCH_SIZE then break end
    end
    if #ids == 0 then
        profileEnd(profiled)
        return
    end

    local sent, _, route = fire("Claim Orbs", ids)
    run.RouteOrbs = route
    if sent then
        for index = 1, #ids do
            local orbId = ids[index]
            local state = run.PendingOrbIds[orbId]
            if state ~= nil then
                run.OrbTransportFailures[orbId] = nil
                run.PendingOrbIds[orbId] = nil
                run.PendingOrbCount = math.max(run.PendingOrbCount - 1, 0)
                run.OrbTransportCommitted = run.OrbTransportCommitted + 1
                local attempts = (tonumber(run.OrbDeliveryAttempts[orbId]) or 0) + 1
                run.OrbDeliveryAttempts[orbId] = attempts
                if run.OrbAckAvailable then
                    if run.UnconfirmedOrbIds[orbId] == nil then
                        run.UnconfirmedOrbIds[orbId] = now
                        run.UnconfirmedOrbCount = run.UnconfirmedOrbCount + 1
                    end
                else
                    run.OrbDeliveryAttempts[orbId] = nil
                end
            end
        end
        run.OrbBatches = run.OrbBatches + 1
        run.OrbIdsSent = run.OrbIdsSent + #ids
        run.OrbMaxBatch = math.max(run.OrbMaxBatch, #ids)
        if run.UnconfirmedOrbCount > 0 then armOrbConfirmation() end
    else
        run.OrbErrors = run.OrbErrors + 1
        for index = 1, #ids do
            local orbId = ids[index]
            if run.PendingOrbIds[orbId] ~= nil then
                local failures = (tonumber(run.OrbTransportFailures[orbId]) or 0) + 1
                if failures >= 2 then
                    run.PendingOrbIds[orbId] = nil
                    run.OrbTransportFailures[orbId] = nil
                    run.PendingOrbCount = math.max(run.PendingOrbCount - 1, 0)
                    run.OrbDropped = run.OrbDropped + 1
                else
                    run.OrbTransportFailures[orbId] = failures
                end
            end
        end
    end
    table.clear(ids)
    profileEnd(profiled)
    if run.PendingOrbCount > 0 then armOrbFlush(orbFlushInterval()) end
    armStatus()
end

armOrbFlush = function(minimumDelay)
    if run.OrbFlushArmed or not orbsEnabled() or run.PendingOrbCount == 0 then return end
    run.OrbFlushArmed = true
    local generation = run.Generation
    local token = run.OrbToken
    local now = os.clock()
    local interval = orbFlushInterval()
    local earliest = (tonumber(run.OrbLastFlushAt) or 0) + interval
    local delaySeconds = math.max(earliest - now, tonumber(minimumDelay) or 0)
    if run.OrbLastFlushAt == 0 then
        delaySeconds = interval + trafficStagger()
    end
    task.delay(delaySeconds, function()
        if generation ~= run.Generation or token ~= run.OrbToken then return end
        flushOrbs()
    end)
end

local function queueOrb(itemOrId, fromEvent, payload)
    if not orbsEnabled() then return false end
    local isObject = typeof(itemOrId) == "Instance"
    local orbId = isObject and objectId(itemOrId)
        or (itemOrId ~= nil and tostring(itemOrId) or nil)
    if not orbId or orbId == "" then return false end
    if payloadOwnerClass and payloadOwnerClass(payload) == "foreign" then
        run.OrbDropped = run.OrbDropped + 1
        armStatus()
        return true
    end

    local idleBurst = run.PendingOrbCount == 0 and not run.OrbFlushArmed
    local queuedNew = false
    if run.UnconfirmedOrbIds[orbId] ~= nil then
        run.OrbDeduplicated = run.OrbDeduplicated + 1
    elseif not run.PendingOrbIds[orbId] then
        if run.PendingOrbCount + run.UnconfirmedOrbCount >= MAX_PENDING_ORBS then
            run.OrbOverflow = run.OrbOverflow + 1
            armStatus()
            return false
        end
        run.PendingOrbIds[orbId] = 0
        run.PendingOrbCount = run.PendingOrbCount + 1
        queuedNew = true
    else
        run.OrbDeduplicated = run.OrbDeduplicated + 1
    end
    if fromEvent then run.OrbEvents = run.OrbEvents + 1 end
    if idleBurst and queuedNew then run.OrbIdleBursts = run.OrbIdleBursts + 1 end
    armOrbFlush(idleBurst and queuedNew and trafficStagger() or nil)
    armStatus()
    return true
end

local function removeQueuedOrb(id)
    id = id ~= nil and tostring(id) or nil
    if not id then return end
    local found = false
    if run.PendingOrbIds[id] ~= nil then
        run.PendingOrbIds[id] = nil
        run.PendingOrbCount = math.max(run.PendingOrbCount - 1, 0)
        found = true
    end
    if run.UnconfirmedOrbIds[id] ~= nil then
        run.UnconfirmedOrbIds[id] = nil
        run.UnconfirmedOrbCount = math.max(run.UnconfirmedOrbCount - 1, 0)
        found = true
    end
    run.OrbTransportFailures[id] = nil
    run.OrbDeliveryAttempts[id] = nil
    run.OrbAckObserved = true
    if found then run.OrbAcked = run.OrbAcked + 1 end
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

local BAG_OWNER_KEYS = { "OwnerUserId", "UserId", "Owner", "Player", "User" }

payloadOwnerClass = function(payload)
    if type(payload) ~= "table" then return "unknown" end
    local localPlayer = Players.LocalPlayer
    if not localPlayer then return "unknown" end
    for index = 1, #BAG_OWNER_KEYS do
        local key = BAG_OWNER_KEYS[index]
        local value = payload[key]
        if typeof(value) == "Instance" and value:IsA("Player") then
            return value == localPlayer and "local" or "foreign"
        end
        if type(value) == "number" and value > 0 then
            return value == localPlayer.UserId and "local" or "foreign"
        end
        if type(value) == "string" and value ~= "" then
            local numeric = tonumber(value)
            if numeric and numeric > 0 then
                return numeric == localPlayer.UserId and "local" or "foreign"
            end
            local lowered = string.lower(value)
            if lowered == string.lower(localPlayer.Name)
                or lowered == string.lower(localPlayer.DisplayName) then
                return "local"
            end
            local ownerPlayer = Players:FindFirstChild(value)
            if ownerPlayer then return ownerPlayer == localPlayer and "local" or "foreign" end
        end
    end
    return "unknown"
end

local function payloadOwnerAllowed(payload)
    return payloadOwnerClass(payload) ~= "foreign"
end

local processBagWake

local function acquireBagRecord()
    local pool = run.BagPool
    local record = pool[#pool]
    if record then
        pool[#pool] = nil
        return record
    end
    return {}
end

local function releaseBagRecord(record)
    record.Id = nil
    record.Position = nil
    record.Object = nil
    record.HadObject = nil
    record.Attempts = nil
    record.Due = nil
    record.State = nil
    record.Queued = nil
    record.Delayed = nil
    record.Retired = nil
    record.SentAt = nil
    record.CreatedAt = nil
    record.NativeCollected = nil
    if #run.BagPool < MAX_BAG_POOL then
        run.BagPool[#run.BagPool + 1] = record
    end
end

local function collectNativeBagObject(record, object)
    if typeof(object) ~= "Instance" or not object.Parent then return false end
    local collect = run.NativeLootbagCollect
    if type(collect) ~= "function" then return false end
    local ok = pcall(collect, object)
    if ok then
        record.Object = nil
        record.NativeCollected = true
        run.BagLocalDestroyed = run.BagLocalDestroyed + 1
    end
    return ok
end

local function closeBag(record, acknowledged, reason)
    if not record or run.BagById[record.Id] ~= record then return end
    run.BagById[record.Id] = nil
    run.WaitingBagCount = math.max(run.WaitingBagCount - 1, 0)
    if acknowledged then
        run.BagAcked = run.BagAcked + 1
    elseif reason == "transport committed" then
        run.BagTransportCommitted = run.BagTransportCommitted + 1
    elseif reason == "transport dropped" then
        run.BagTransportDropped = run.BagTransportDropped + 1
    end
    -- A queued/delayed array can still hold this record. Do not return it to
    -- the pool until that final scalar reference has been consumed; otherwise
    -- a newly spawned bag could reuse the same table and inherit stale work.
    record.Retired = true
    record.State = "retired"
    if not record.Queued and not record.Delayed then releaseBagRecord(record) end
end

local function compactBagQueue()
    local queue, head = run.BagQueue, run.BagQueueHead
    if head <= 64 and head <= (#queue / 2) then return end
    local write = 1
    for index = head, #queue do
        queue[write] = queue[index]
        if write ~= index then queue[index] = nil end
        write = write + 1
    end
    for index = write, #queue do queue[index] = nil end
    run.BagQueueHead = 1
end

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

local function enqueueReadyBag(record)
    if not record or record.Queued or run.BagById[record.Id] ~= record then return end
    record.Queued = true
    run.BagQueue[#run.BagQueue + 1] = record
    armBagWake(0)
end

local function bagRecordHasLiveObject(record)
    local object = record and record.Object
    return typeof(object) == "Instance" and object.Parent ~= nil
end

local function enqueueDelayedBag(record, due)
    if not record or run.BagById[record.Id] ~= record then return end
    record.Due = due
    if not record.Delayed then
        record.Delayed = true
        run.BagDelayed[#run.BagDelayed + 1] = record
    end
    armBagWake(math.max(due - os.clock(), 0))
end

local function processDelayedBags(now)
    local delayed = run.BagDelayed
    local write, nextAt = 1, nil
    for index = 1, #delayed do
        local record = delayed[index]
        if record and record.Delayed then
            local due = tonumber(record.Due) or now
            if run.BagById[record.Id] ~= record then
                record.Delayed = false
                if not record.Queued then releaseBagRecord(record) end
            elseif due <= now then
                record.Delayed = false
                enqueueReadyBag(record)
            else
                delayed[write] = record
                write = write + 1
                if not nextAt or due < nextAt then nextAt = due end
            end
        end
    end
    for index = write, #delayed do delayed[index] = nil end
    return nextAt
end

local function collectBag(record, now)
    local liveObject = record.Object
    local nativeCollected = false
    if typeof(liveObject) == "Instance" and liveObject.Parent then
        -- Collect Lootbag expects the bag's current landed position. The first
        -- fallback observation can happen while the object is still moving.
        record.Position = objectPosition(liveObject) or record.Position
        nativeCollected = collectNativeBagObject(record, liveObject)
        if run.BagById[record.Id] ~= record then return end
    end
    local sent, route
    if nativeCollected then
        sent, route = true, "native Collect"
    else
        local profiled = profileBegin("PSX_LootbagFlush")
        sent, _, route = fire("Collect Lootbag", record.Id, record.Position)
        profileEnd(profiled)
    end
    run.RouteLootbags = route or "unavailable"
    record.Attempts = (record.Attempts or 0) + 1
    if sent then
        run.BagSent = run.BagSent + 1
        record.State = "awaiting_ack"
        record.SentAt = now
        if typeof(liveObject) ~= "Instance" and record.Attempts == 1 then
            run.BagSentUnverifiable = run.BagSentUnverifiable + 1
        end
        if run.BagById[record.Id] ~= record then return end
        if run.BagAckAvailable and record.Attempts < MAX_BAG_TRANSPORT_ATTEMPTS then
            enqueueDelayedBag(record, now + bagRetryDelay(record))
        elseif run.BagAckAvailable then
            enqueueDelayedBag(record, now + bagConfirmationDelay())
        else
            closeBag(record, false, "transport committed")
        end
    elseif record.Attempts < MAX_BAG_TRANSPORT_ATTEMPTS then
        run.BagRetried = run.BagRetried + 1
        record.State = "retry"
        enqueueDelayedBag(record, now + BAG_TRANSPORT_RETRY_DELAY)
    else
        run.BagErrors = run.BagErrors + 1
        closeBag(record, false, "transport dropped")
    end
end

local function queueBagEvent(id, payload, explicitPosition, sourceObject)
    if not bagsEnabled() then return false end
    id = id ~= nil and tostring(id) or nil
    if not id or id == "" then return false end
    if run.BagById[id] then return true end
    if run.WaitingBagCount >= MAX_PENDING_BAGS then
        run.BagOverflow = run.BagOverflow + 1
        armStatus()
        return false
    end
    if not payloadWorldAllowed(payload) or not payloadOwnerAllowed(payload) then
        run.BagSkipped = run.BagSkipped + 1
        armStatus()
        return true
    end
    local position = normalizePosition(explicitPosition) or (type(payload) == "table"
        and normalizePosition(payload.position or payload.pos or payload.Position) or nil
    )
    if not position then
        run.BagErrors = run.BagErrors + 1
        armStatus()
        return false
    end

    local record = acquireBagRecord()
    record.Id = id
    record.Position = position
    record.Object = typeof(sourceObject) == "Instance" and sourceObject or nil
    record.HadObject = record.Object ~= nil
    record.Attempts = 0
    record.State = "queued"
    record.CreatedAt = os.clock()
    run.BagById[id] = record
    run.WaitingBagCount = run.WaitingBagCount + 1
    run.BagEvents = run.BagEvents + 1
    enqueueDelayedBag(record, os.clock() + BAG_FIRST_ATTEMPT_DELAY + trafficStagger())
    armStatus()
    return true
end

local function queueBagObject(item)
    if not bagsEnabled() or not item then return false end
    local context = run.Context
    if context and type(context.LocalLootOwner) == "function" then
        local checked, allowed, resolved = pcall(context.LocalLootOwner, item)
        if checked and resolved == true and allowed ~= true then
            run.BagSkipped = run.BagSkipped + 1
            armStatus()
            return true
        end
    end
    local id = objectId(item)
    local position = objectPosition(item)
    if not id or not position then return false end
    return queueBagEvent(id, nil, position, item)
end

local function acknowledgeBag(id, source)
    id = id ~= nil and tostring(id) or nil
    local record = id and run.BagById[id] or nil
    run.BagAckObserved = true
    if not record then return end
    if source == "object" then
        run.BagObjectAcknowledged = run.BagObjectAcknowledged + 1
    else
        run.BagNetworkAcknowledged = run.BagNetworkAcknowledged + 1
    end
    closeBag(record, true, source or "network")
    armStatus()
end

processBagWake = function()
    if not bagsEnabled() then return end
    local now = os.clock()
    local nextAt = processDelayedBags(now)
    local queue = run.BagQueue
    local processed = 0
    local laneLimit = bagLaneLimit()
    while processed < laneLimit and run.BagQueueHead <= #queue do
        local index = run.BagQueueHead
        local record = queue[index]
        queue[index] = false
        run.BagQueueHead = index + 1
        if record then record.Queued = false end
        if record and run.BagById[record.Id] == record and record.State ~= "sent" then
            if record.State == "awaiting_ack" then
                if record.Attempts < MAX_BAG_TRANSPORT_ATTEMPTS
                    and bagRecordHasLiveObject(record) then
                    collectBag(record, now)
                else
                    closeBag(record, false, "transport committed")
                end
            else
                collectBag(record, now)
            end
            processed = processed + 1
        elseif record and record.Retired and not record.Delayed then
            releaseBagRecord(record)
        end
    end
    compactBagQueue()
    if run.BagQueueHead <= #run.BagQueue then
        armBagWake(bagWakeDelay())
    elseif nextAt then
        armBagWake(math.max(nextAt - os.clock(), 0))
    end
    armStatus()
end

local function clearOrbBinding()
    run.OrbToken = run.OrbToken + 1
    clearConnections(run.OrbConnections)
    run.OrbFolder = nil
    table.clear(run.PendingOrbIds)
    table.clear(run.UnconfirmedOrbIds)
    table.clear(run.OrbDeliveryAttempts)
    table.clear(run.OrbTransportFailures)
    table.clear(run.OrbBatch)
    run.PendingOrbCount = 0
    run.UnconfirmedOrbCount = 0
    run.OrbFlushArmed = false
    run.OrbConfirmArmed = false
    run.OrbRetryArmed = false
    run.OrbLastFlushAt = 0
end

local function clearBagBinding()
    run.BagToken = run.BagToken + 1
    run.BagWakeSerial = run.BagWakeSerial + 1
    clearConnections(run.BagConnections)
    for _, record in pairs(run.BagById) do releaseBagRecord(record) end
    table.clear(run.BagById)
    table.clear(run.BagQueue)
    table.clear(run.BagDelayed)
    run.BagQueueHead = 1
    run.WaitingBagCount = 0
    run.BagWakeArmed = false
    run.BagWakeAt = nil
    run.LootbagFolder = nil
end

local function findGameScript(name)
    local player = Players.LocalPlayer
    local playerScripts = player and player:FindFirstChild("PlayerScripts")
    local scripts = playerScripts and playerScripts:FindFirstChild("Scripts")
    local gameScripts = scripts and scripts:FindFirstChild("Game")
    local scriptObject = gameScripts and gameScripts:FindFirstChild(name)
    if scriptObject and scriptObject:IsA("LocalScript") then return scriptObject end
    return nil
end

local function scriptEnvironment(scriptObject)
    if typeof(scriptObject) ~= "Instance" then
        return nil, "game LocalScript is unavailable"
    end
    if type(getsenv) ~= "function" then
        return nil, "getsenv is unavailable"
    end
    local ok, environment = pcall(getsenv, scriptObject)
    if not ok or type(environment) ~= "table" then
        return nil, "getsenv did not return a table"
    end
    return environment
end

local function liveCoinFolder(rawId)
    if rawId == nil then return nil end
    local things = workspace:FindFirstChild("__THINGS")
    local coins = things and things:FindFirstChild("Coins")
    return coins and coins:FindFirstChild(tostring(rawId)) or nil
end

-- Game.Pets.Tick follows the invisible POS part but reads the sibling Coin.Size
-- every render frame. Full headless mode may suppress the expensive Coin clone,
-- so retain one target-sized invisible POS clone only for folders that already
-- exist without that required sibling. This is structural compatibility, not
-- a visual model or moving physics assembly.
local function ensureNativePetCoinTarget(record, rawId)
    if type(record) ~= "table" or rawId == nil then return false end
    local id = tostring(rawId)
    local folder = liveCoinFolder(id)
    if not folder then return true end

    local target = folder:FindFirstChild("Coin")
    if target then
        if not target:IsA("BasePart") then return false end
        local marked = false
        pcall(function()
            marked = target:GetAttribute(NATIVE_PET_COIN_SHELL_ATTRIBUTE) == true
        end)
        if marked then record.StructuralShells[id] = target end
        return true
    end

    local pos = folder:FindFirstChild("POS")
    if not pos or not pos:IsA("BasePart") then return false end
    local created, shell = pcall(function()
        local clone = pos:Clone()
        clone.Name = "Coin"
        clone.Size = Vector3.new(4, 4, 4)
        clone.Transparency = 1
        clone.CastShadow = false
        clone.CanCollide = false
        clone.CanTouch = false
        clone.CanQuery = false
        clone:SetAttribute(NATIVE_PET_COIN_SHELL_ATTRIBUTE, true)
        folder:SetAttribute("ModelStage", NATIVE_PET_COIN_STAGE)
        clone.Parent = folder
        return clone
    end)
    if not created or not shell then return false end
    record.StructuralShells[id] = shell
    return true
end

local function restoreNativePetCoinTargets(record)
    disconnect(record and record.StructureConnection)
    disconnect(record and record.StructureRemovalConnection)
    if type(record) ~= "table" or type(record.StructuralShells) ~= "table" then return end
    if coinsHeadlessEnabled() then
        table.clear(record.StructuralShells)
        return
    end

    local originalUpdate = record.Originals and record.Originals.UpdateCoin
    for id, shell in pairs(record.StructuralShells) do
        local folder = typeof(shell) == "Instance" and shell.Parent or nil
        local owned = false
        if folder then
            pcall(function()
                owned = shell:GetAttribute(NATIVE_PET_COIN_SHELL_ATTRIBUTE) == true
            end)
        end
        if owned then
            pcall(function()
                folder:SetAttribute("ModelStage", NATIVE_PET_COIN_STAGE)
            end)
            if type(originalUpdate) == "function" then pcall(originalUpdate, id) end
        end
        record.StructuralShells[id] = nil
    end
end

local function restoreProducerRecord(record)
    if type(record) ~= "table" then return end
    record.Active = false
    local environment = record.Environment
    if type(environment) == "table" then
        for name, wrapper in pairs(record.Wrappers or {}) do
            if environment[name] == wrapper then
                pcall(function() environment[name] = record.Originals[name] end)
            end
        end
    end
    restoreNativePetCoinTargets(record)
    record.Environment = nil
    record.Script = nil
    table.clear(record.CoinDataTables or {})
    table.clear(record.Wrappers or {})
    table.clear(record.Originals or {})
end

local function coinProducerCall(record, original, producerName, ...)
    local shouldPrevent = false
    if record.Active and record.Generation == run.Generation and contextRunning() then
        local headless = coinsHeadlessEnabled()
        if headless then
            if producerName == "DamageAnimation"
                or producerName == "PetDamageAnimation" then
                shouldPrevent = true
            else
                local context = run.Context
                local rawId, data = ...
                if type(data) ~= "table" then
                    data = coinDataFromProducer(record, rawId)
                end
                if context and type(context.ObserveCoin) == "function"
                    and type(data) == "table" then
                    pcall(context.ObserveCoin, rawId, data)
                end
                local structureReady = true
                if producerName == "UpdateCoin" then
                    structureReady = ensureNativePetCoinTarget(record, rawId)
                end
                -- The catalog-wide guard is insufficient here: one stale or
                -- out-of-zone record must never suppress a newly spawned ID.
                -- Only gate the visual producer after this exact coin has a
                -- complete live registry record. Otherwise let the game's
                -- original producer create its tiny data folder, then recover
                -- that one ID without scanning Workspace.
                shouldPrevent = coinCatalogReady() and coinRecordReady(rawId)
                if not structureReady then shouldPrevent = false end
                if not shouldPrevent then
                    local results = table.pack(original(...))
                    if producerName == "AddCoin" then recoverCoinRecord(rawId) end
                    return table.unpack(results, 1, results.n)
                end
            end
        end
    end
    if shouldPrevent then
        run.VisualInstancesPrevented = run.VisualInstancesPrevented + 1
        return nil
    end
    return original(...)
end

local function installOrbProducer()
    restoreProducerRecord(run.OrbProducerRecord)
    run.OrbProducerRecord = nil
    run.OrbGate = false
    run.OrbsProducer = "fallback"

    if not orbsEnabled() then
        run.OrbsProducer = "disabled"
        run.OrbGateReason = "collection disabled"
        return false
    end

    local scriptObject = findGameScript("Orbs")
    local environment, problem = scriptEnvironment(scriptObject)
    if not environment then
        run.OrbGateReason = problem
        return false
    end
    if type(environment.AddOrb) ~= "function" then
        run.OrbGateReason = "Orbs.AddOrb is unavailable"
        return false
    end

    local record = {
        Active = true,
        Generation = run.Generation,
        Script = scriptObject,
        Environment = environment,
        Originals = {},
        Wrappers = {},
        CoinDataTables = readFunctionUpvalueTables(environment.AddCoin),
    }
    for _, name in ipairs({ "AddOrb", "OrbLoop", "PlaySounds" }) do
        if type(environment[name]) == "function" then
            record.Originals[name] = environment[name]
        end
    end

    local originalAddOrb = record.Originals.AddOrb
    record.Wrappers.AddOrb = function(id, payload, ...)
        if record.Active and record.Generation == run.Generation
            and orbsEnabled() then
            local queued, accepted = pcall(queueOrb, id, true, payload)
            if queued and accepted == true then
                run.VisualInstancesPrevented = run.VisualInstancesPrevented + 1
                return nil
            end
            run.OrbErrors = run.OrbErrors + 1
        end
        return originalAddOrb(id, payload, ...)
    end
    for _, name in ipairs({ "OrbLoop", "PlaySounds" }) do
        local original = record.Originals[name]
        if original then
            record.Wrappers[name] = (function(savedName, savedOriginal)
                return function(...)
                    if savedName == "PlaySounds" and record.Active
                        and record.Generation == run.Generation and orbsEnabled() then
                        return nil
                    end
                    return savedOriginal(...)
                end
            end)(name, original)
        end
    end

    local installed, installProblem = pcall(function()
        for name, wrapper in pairs(record.Wrappers) do
            environment[name] = wrapper
        end
        for name, wrapper in pairs(record.Wrappers) do
            if environment[name] ~= wrapper then
                error("Orbs." .. name .. " assignment was rejected")
            end
        end
    end)
    if not installed then
        restoreProducerRecord(record)
        run.OrbGateReason = "producer install failed: " .. tostring(installProblem)
        return false
    end

    run.OrbProducerRecord = record
    run.OrbGate = true
    run.OrbsProducer = "producer-gated"
    run.OrbGateReason = "getsenv AddOrb/loop/sound gate"

    local removedSignal = networkSignal("Orb Removed")
    if removedSignal then
        run.OrbAckAvailable = true
        run.OrbGateConnections[#run.OrbGateConnections + 1] =
            removedSignal:Connect(removeQueuedOrb)
    else
        run.OrbAckAvailable = false
    end
    return true
end

local function installCoinProducer()
    restoreProducerRecord(run.CoinProducerRecord)
    run.CoinProducerRecord = nil

    if not coinsHeadlessEnabled() then
        run.CoinsProducer = "visual"
        run.CoinGateReason = "headless disabled"
        return false
    end

    local scriptObject = findGameScript("Coins")
    local environment, problem = scriptEnvironment(scriptObject)
    if not environment then
        run.CoinsProducer = "fallback"
        run.CoinGateReason = problem
        return false
    end

    local names = { "DamageAnimation", "PetDamageAnimation", "AddCoin", "UpdateCoin" }
    for _, name in ipairs(names) do
        if type(environment[name]) ~= "function" then
            run.CoinsProducer = "fallback"
            run.CoinGateReason = "Coins." .. name .. " is unavailable"
            return false
        end
    end

    local record = {
        Active = true,
        Generation = run.Generation,
        Script = scriptObject,
        Environment = environment,
        Originals = {},
        Wrappers = {},
        CoinDataTables = readFunctionUpvalueTables(environment.AddCoin),
        StructuralShells = {},
        StructureConnection = nil,
        StructureRemovalConnection = nil,
    }
    for _, name in ipairs(names) do
        local original = environment[name]
        record.Originals[name] = original
        record.Wrappers[name] = (function(savedName, savedOriginal)
            return function(...)
                return coinProducerCall(record, savedOriginal, savedName, ...)
            end
        end)(name, original)
    end

    local installed, installProblem = pcall(function()
        for name, wrapper in pairs(record.Wrappers) do
            environment[name] = wrapper
        end
        for name, wrapper in pairs(record.Wrappers) do
            if environment[name] ~= wrapper then
                error("Coins." .. name .. " assignment was rejected")
            end
        end
    end)
    if not installed then
        restoreProducerRecord(record)
        run.CoinsProducer = "fallback"
        run.CoinGateReason = "producer install failed: " .. tostring(installProblem)
        return false
    end

    run.CoinProducerRecord = record
    local things = workspace:FindFirstChild("__THINGS")
    local coins = things and things:FindFirstChild("Coins")
    if coins then
        for _, folder in ipairs(coins:GetChildren()) do
            ensureNativePetCoinTarget(record, folder.Name)
        end
        record.StructureConnection = coins.ChildAdded:Connect(function(folder)
            task.defer(function()
                if record.Active and record.Generation == run.Generation then
                    ensureNativePetCoinTarget(record, folder.Name)
                end
            end)
        end)
        record.StructureRemovalConnection = coins.DescendantRemoving:Connect(function(descendant)
            local folder = descendant and descendant.Parent
            if descendant and descendant.Name == "Coin"
                and folder and folder.Parent == coins then
                local id = folder.Name
                record.StructuralShells[id] = nil
                task.defer(function()
                    if record.Active and record.Generation == run.Generation then
                        ensureNativePetCoinTarget(record, id)
                    end
                end)
            end
        end)
    end
    run.CoinsProducer = "producer-gated"
    run.CoinGateReason = "verified IDs gated; native pet target shells preserved"
    return true
end

local function installBagProducer()
    restoreProducerRecord(run.BagProducerRecord)
    run.BagProducerRecord = nil
    run.BagGate = false
    run.LootbagsProducer = "fallback"

    if not bagsEnabled() then
        run.LootbagsProducer = "disabled"
        run.BagGateReason = "collection disabled"
        return false
    end

    local scriptObject = findGameScript("Lootbags")
    local environment, problem = scriptEnvironment(scriptObject)
    if not environment then
        run.BagGateReason = problem
        return false
    end
    for _, name in ipairs({ "Add", "ScanForCollection", "Remove" }) do
        if type(environment[name]) ~= "function" then
            run.BagGateReason = "Lootbags." .. name .. " is unavailable"
            return false
        end
    end

    local record = {
        Active = true,
        FailOpen = false,
        Generation = run.Generation,
        Script = scriptObject,
        Environment = environment,
        Originals = {},
        Wrappers = {},
    }
    for _, name in ipairs({ "Add", "ScanForCollection", "Remove" }) do
        record.Originals[name] = environment[name]
    end
    if type(environment.Collect) == "function" then
        record.Originals.Collect = environment.Collect
        run.NativeLootbagCollect = environment.Collect
    else
        run.NativeLootbagCollect = nil
    end

    local originalAdd = record.Originals.Add
    record.Wrappers.Add = function(id, payload, ...)
        if record.Active and not record.FailOpen
            and record.Generation == run.Generation and bagsEnabled() then
            local ok, accepted = pcall(queueBagEvent, id, payload)
            if ok and accepted == true then
                run.VisualInstancesPrevented = run.VisualInstancesPrevented + 1
                return nil
            end
            record.FailOpen = true
            run.BagGate = false
            run.LootbagsProducer = "fallback"
            run.BagGateReason = ok and "loot payload was not claimable"
                or "producer callback failed: " .. tostring(accepted)
            if not ok then run.BagErrors = run.BagErrors + 1 end
            armStatus()
        end
        return originalAdd(id, payload, ...)
    end

    local originalScan = record.Originals.ScanForCollection
    record.Wrappers.ScanForCollection = function(...)
        return originalScan(...)
    end

    local originalRemove = record.Originals.Remove
    record.Wrappers.Remove = function(id, ...)
        if record.Active and record.Generation == run.Generation then
            pcall(acknowledgeBag, id, "game remove")
        end
        return originalRemove(id, ...)
    end

    local installed, installProblem = pcall(function()
        for name, wrapper in pairs(record.Wrappers) do
            environment[name] = wrapper
        end
        for name, wrapper in pairs(record.Wrappers) do
            if environment[name] ~= wrapper then
                error("Lootbags." .. name .. " assignment was rejected")
            end
        end
    end)
    if not installed then
        restoreProducerRecord(record)
        run.BagGateReason = "producer install failed: " .. tostring(installProblem)
        return false
    end

    run.BagProducerRecord = record
    run.BagGate = true
    run.LootbagsProducer = "producer-gated"
    run.BagGateReason = "getsenv Add/ScanForCollection/Remove gate"

    local removeSignal = networkSignal("Remove Lootbag")
    if removeSignal then
        run.BagAckAvailable = true
        run.BagGateConnections[#run.BagGateConnections + 1] =
            removeSignal:Connect(function(id) acknowledgeBag(id, "network") end)
    else
        run.BagAckAvailable = false
    end
    return true
end

local function restoreOrbGate()
    clearConnections(run.OrbGateConnections)
    restoreProducerRecord(run.OrbProducerRecord)
    run.OrbProducerRecord = nil
    run.OrbGate = false
    run.OrbAckAvailable = false
    run.OrbsProducer = run.OrbsOn and "fallback" or "disabled"
end

local function restoreCoinGate()
    restoreProducerRecord(run.CoinProducerRecord)
    run.CoinProducerRecord = nil
    run.CoinsProducer = coinsHeadlessEnabled() and "fallback" or "visual"
    run.CoinGateReason = coinsHeadlessEnabled()
        and "producer gate unavailable" or "headless disabled"
end

local function restoreBagGate()
    clearConnections(run.BagGateConnections)
    restoreProducerRecord(run.BagProducerRecord)
    run.BagProducerRecord = nil
    run.BagGate = false
    run.BagAckAvailable = false
    run.NativeLootbagCollect = nil
    run.LootbagsProducer = run.BagsOn and "fallback" or "disabled"
    run.BagGateReason = run.BagsOn
        and "producer gate unavailable" or "collection disabled"
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
    return installOrbProducer()
end

local function bindBagGate()
    restoreBagGate()
    return installBagProducer()
end

local bindRoots

local function reconcileProducerGates()
    if not contextRunning() then return end
    run.GateGeneration = run.GateGeneration + 1
    bindOrbGate()
    bindBagGate()
    restoreCoinGate()
    installCoinProducer()
end

local function scheduleProducerRebind(reason)
    if not contextRunning() then return end
    run.LastRebindReason = tostring(reason or "script change")
    run.ProducerRebindSerial = run.ProducerRebindSerial + 1
    local serial = run.ProducerRebindSerial
    if run.ProducerRebindArmed then return end
    run.ProducerRebindArmed = true
    local generation = run.Generation
    task.defer(function()
        if generation ~= run.Generation or not contextRunning() then return end
        run.ProducerRebindArmed = false
        if serial ~= run.ProducerRebindSerial then
            scheduleProducerRebind(run.LastRebindReason)
            return
        end
        reconcileProducerGates()
        bindRoots(false, true, true)
        armStatus()
    end)
end

local function bindPlayerScriptWatchers()
    clearConnections(run.ProducerConnections)
    clearConnections(run.PlayerScriptConnections)
    local player = Players.LocalPlayer
    local playerScripts = player and player:FindFirstChild("PlayerScripts")
    run.PlayerScripts = playerScripts

    if player then
        run.PlayerScriptConnections[#run.PlayerScriptConnections + 1] =
            player.ChildAdded:Connect(function(child)
                if child.Name == "PlayerScripts" then
                    bindPlayerScriptWatchers()
                    scheduleProducerRebind("PlayerScripts added")
                end
            end)
        run.PlayerScriptConnections[#run.PlayerScriptConnections + 1] =
            player.ChildRemoved:Connect(function(child)
                if child == run.PlayerScripts then
                    clearConnections(run.ProducerConnections)
                    run.PlayerScripts = nil
                    scheduleProducerRebind("PlayerScripts removed")
                end
            end)
    end
    if playerScripts then
        run.ProducerConnections[#run.ProducerConnections + 1] =
            playerScripts.ChildAdded:Connect(function(child)
                if child.Name == "Scripts" then
                    bindPlayerScriptWatchers()
                    scheduleProducerRebind("Scripts added")
                end
            end)
        run.ProducerConnections[#run.ProducerConnections + 1] =
            playerScripts.ChildRemoved:Connect(function(child)
                if child.Name == "Scripts" then
                    bindPlayerScriptWatchers()
                    scheduleProducerRebind("Scripts removed")
                end
            end)
    end

    local scripts = playerScripts and playerScripts:FindFirstChild("Scripts")
    if scripts then
        run.ProducerConnections[#run.ProducerConnections + 1] =
            scripts.ChildAdded:Connect(function(child)
                if child.Name == "Game" then
                    bindPlayerScriptWatchers()
                    scheduleProducerRebind("Game scripts added")
                end
            end)
        run.ProducerConnections[#run.ProducerConnections + 1] =
            scripts.ChildRemoved:Connect(function(child)
                if child.Name == "Game" then
                    bindPlayerScriptWatchers()
                    scheduleProducerRebind("Game scripts removed")
                end
            end)
    end

    local gameFolder = scripts and scripts:FindFirstChild("Game")
    if gameFolder then
        run.ProducerConnections[#run.ProducerConnections + 1] =
            gameFolder.ChildAdded:Connect(function(child)
                if child.Name == "Orbs" or child.Name == "Coins"
                    or child.Name == "Lootbags" then
                    scheduleProducerRebind(child.Name .. " added")
                end
            end)
        run.ProducerConnections[#run.ProducerConnections + 1] =
            gameFolder.ChildRemoved:Connect(function(child)
                if child.Name == "Orbs" or child.Name == "Coins"
                    or child.Name == "Lootbags" then
                    scheduleProducerRebind(child.Name .. " removed")
                end
            end)
    end
end

local function queueOrbFallback(item)
    local ok = pcall(queueOrb, item, false)
    if not ok then run.OrbErrors = run.OrbErrors + 1 end
end

local function watchBagFallback(item)
    local ok = pcall(queueBagObject, item)
    if not ok then run.BagErrors = run.BagErrors + 1 end
end

local function bindOrbFolder(folder)
    clearOrbBinding()
    run.OrbFolder = folder
    if not folder or not orbsEnabled() then return end
    if not run.OrbGate then
        run.OrbConnections[#run.OrbConnections + 1] =
            folder.ChildAdded:Connect(queueOrbFallback)
    end
    scanFolder(folder, run.OrbGate and queueOrb or queueOrbFallback)
end

local function bindLootbagFolder(folder)
    clearBagBinding()
    run.LootbagFolder = folder
    if not folder or not bagsEnabled() then return end
    if not run.BagGate then
        run.BagConnections[#run.BagConnections + 1] =
            folder.ChildAdded:Connect(watchBagFallback)
    end
    run.BagConnections[#run.BagConnections + 1] =
        folder.ChildRemoved:Connect(function(item)
            local id = objectId(item)
            if id then acknowledgeBag(id, "object") end
        end)
    scanFolder(folder, watchBagFallback)
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
    restoreCoinGate()
    installCoinProducer()
end

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
                    if child.Name == "Coins" then scheduleProducerRebind("Coins added") end
                end)
            run.ThingsConnections[#run.ThingsConnections + 1] =
                things.ChildRemoved:Connect(function(child)
                    if child == run.OrbFolder then bindOrbFolder(nil) end
                    if child == run.LootbagFolder then bindLootbagFolder(nil) end
                    if child.Name == "Coins" then scheduleProducerRebind("Coins removed") end
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
    run.OrbDeduplicated = 0
    run.OrbMaxBatch = 0
    run.OrbLocalSentUnacked = 0
    run.OrbTransportCommitted = 0
    run.OrbAckAvailable = false
    run.OrbAckObserved = false
    run.OrbAcked = 0
    run.OrbRetried = 0
    run.OrbExpiredUnverified = 0
    run.BagEvents = 0
    run.BagSent = 0
    run.BagAcked = 0
    run.BagRetried = 0
    run.BagSkipped = 0
    run.BagErrors = 0
    run.BagOverflow = 0
    run.BagRetiredNoAck = 0
    run.BagSentUnverifiable = 0
    run.BagObjectAcknowledged = 0
    run.BagNetworkAcknowledged = 0
    run.BagTransportCommitted = 0
    run.BagTransportDropped = 0
    run.BagAckAvailable = false
    run.BagAckObserved = false
    run.BagLocalDestroyed = 0
    run.VisualInstancesPrevented = 0
    run.GateGeneration = 0
    run.LastRebindReason = "startup"
    run.LastStatusText = nil
end

local function start(context)
    if type(context) ~= "table" then return false, "context table required" end
    run.Generation = run.Generation + 1
    run.Active = false
    clearConnections(run.Connections)
    clearConnections(run.ProducerConnections)
    clearConnections(run.PlayerScriptConnections)
    clearWorld()
    restoreOrbGate()
    restoreCoinGate()
    restoreBagGate()
    run.Context = context
    run.Active = true
    run.ProducerRebindArmed = false
    run.ProducerRebindSerial = 0
    run.StatusArmed = false
    run.OrbsOn, run.BagsOn = wantedFlags()
    resetStats()
    local generation = run.Generation

    bindPlayerScriptWatchers()
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
                scheduleProducerRebind("World Changed")
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
    local initialStatus = statusText()
    run.LastStatusText = initialStatus
    if type(context.Status) == "function" then pcall(context.Status, initialStatus) end
    return true
end

local function stop()
    run.Generation = run.Generation + 1
    run.Active = false
    run.ProducerRebindSerial = run.ProducerRebindSerial + 1
    run.ProducerRebindArmed = false
    clearConnections(run.Connections)
    clearConnections(run.ProducerConnections)
    clearConnections(run.PlayerScriptConnections)
    clearWorld()
    restoreOrbGate()
    restoreCoinGate()
    restoreBagGate()
    run.PlayerScripts = nil
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
    local headless = coinsHeadlessEnabled()
    if not orbs and not bags and not headless then return stop() end
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
        OrbsProducer = run.OrbsProducer,
        CoinsProducer = run.CoinsProducer,
        OrbGateReason = run.OrbGateReason,
        CoinGateReason = run.CoinGateReason,
        BagGateReason = run.BagGateReason,
        GateGeneration = run.GateGeneration,
        LastRebindReason = run.LastRebindReason,
        LowTrafficActive = lowTrafficActive(),
        OrbFlushInterval = orbFlushInterval(),
        BagLaneLimit = bagLaneLimit(),
        TrafficStagger = trafficStagger(),
        VisualInstancesPrevented = run.VisualInstancesPrevented,
        PendingOrbs = run.PendingOrbCount,
        UnconfirmedOrbs = run.UnconfirmedOrbCount,
        OrbAckAvailable = run.OrbAckAvailable,
        OrbAckObserved = run.OrbAckObserved,
        OrbAcked = run.OrbAcked,
        OrbRetried = run.OrbRetried,
        OrbExpiredUnverified = run.OrbExpiredUnverified,
        WaitingBags = run.WaitingBagCount,
        OrbEvents = run.OrbEvents,
        OrbBatches = run.OrbBatches,
        OrbIdleBursts = run.OrbIdleBursts,
        OrbIdsSent = run.OrbIdsSent,
        OrbErrors = run.OrbErrors,
        OrbOverflow = run.OrbOverflow,
        OrbDropped = run.OrbDropped,
        OrbDeduplicated = run.OrbDeduplicated,
        OrbMaxBatch = run.OrbMaxBatch,
        -- Compatibility field consumed by the passive request inspector.
        -- It must reflect the live bounded confirmation set instead of the
        -- obsolete monotonically-written counter.
        OrbLocalSentUnacked = run.UnconfirmedOrbCount,
        OrbTransportCommitted = run.OrbTransportCommitted,
        RouteOrbs = run.RouteOrbs,
        BagEvents = run.BagEvents,
        BagSent = run.BagSent,
        BagAcked = run.BagAcked,
        BagRetried = run.BagRetried,
        BagSkipped = run.BagSkipped,
        BagErrors = run.BagErrors,
        BagOverflow = run.BagOverflow,
        BagRetiredNoAck = run.BagRetiredNoAck,
        BagSentUnverifiable = run.BagSentUnverifiable,
        BagObjectAcknowledged = run.BagObjectAcknowledged,
        BagNetworkAcknowledged = run.BagNetworkAcknowledged,
        BagTransportCommitted = run.BagTransportCommitted,
        BagTransportDropped = run.BagTransportDropped,
        BagAckAvailable = run.BagAckAvailable,
        BagAckObserved = run.BagAckObserved,
        BagLocalDestroyed = run.BagLocalDestroyed,
        RouteLootbags = run.RouteLootbags,
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
