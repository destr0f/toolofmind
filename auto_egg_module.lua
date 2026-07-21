-- Lazy, protocol-aware egg hatch worker for PSX OG Nova develop.
-- Resolves named Network routes at runtime and never relies on session child indices.

local activeState

local ARM_DELAY = 0.35
local LOCAL_RECHECK_DELAY = 0.18
local INITIAL_REQUEST_DELAY = 0.75
local MIN_REQUEST_DELAY = 0.55
local MAX_REQUEST_DELAY = 8
local EVENT_TIMEOUT = 6
local SUSPICIOUS_PAUSE = 60
local EGG_INTERACT_DISTANCE = 15
local EGG_SCAN_INTERVAL = 0.75
local physicalCache = { Root = nil, ById = {}, ScannedAt = 0 }

local function lower(value)
    return string.lower(tostring(value or ""))
end

local function directoryFor(context)
    local directory = context.Library and context.Library.Directory and context.Library.Directory.Eggs
    return type(directory) == "table" and directory or nil
end

local function saveFor(context)
    local saveApi = context.Library and context.Library.Save
    if not saveApi or type(saveApi.Get) ~= "function" then return nil end
    local ok, save = pcall(saveApi.Get)
    return ok and type(save) == "table" and save or nil
end

local function hasGamepass(save, gamepassName)
    local gamepasses = type(save) == "table" and save.Gamepasses or nil
    if type(gamepasses) ~= "table" then return false end
    for key, value in pairs(gamepasses) do
        if value == gamepassName or (key == gamepassName and value == true) then return true end
        if type(value) == "table" and (value.Name == gamepassName or value.name == gamepassName) then
            return true
        end
    end
    return false
end

local function instanceEggId(object)
    if not object then return nil end
    local idObject = object:FindFirstChild("ID_Attr") or object:FindFirstChild("ID")
    if idObject then
        local ok, value = pcall(function() return idObject.Value end)
        if ok and value ~= nil then return tostring(value) end
    end
    local ok, value = pcall(function()
        return object:GetAttribute("ID") or object:GetAttribute("ID_Attr")
    end)
    return ok and value ~= nil and tostring(value) or nil
end

local function instancePosition(object)
    if not object or not object.Parent then return nil end
    local center = object:FindFirstChild("Center")
    if center then
        if center:IsA("BasePart") then return center.Position end
        if center:IsA("Attachment") then return center.WorldPosition end
        if center:IsA("Model") then
            local ok, pivot = pcall(center.GetPivot, center)
            if ok then return pivot.Position end
        end
        local part = center:FindFirstChildWhichIsA("BasePart", true)
        if part then return part.Position end
    end
    if object:IsA("BasePart") then return object.Position end
    if object:IsA("Model") then
        local ok, pivot = pcall(object.GetPivot, object)
        if ok then return pivot.Position end
    end
    local part = object:FindFirstChildWhichIsA("BasePart", true)
    return part and part.Position or nil
end

local function currentEggRoot()
    local map = workspace:FindFirstChild("__MAP")
    if not map then return nil end
    return map:FindFirstChild("Eggs") or map:FindFirstChild("Eggs", true)
end

local function scanPhysical(context, force)
    local now = os.clock()
    local root = currentEggRoot()
    if not root then
        if physicalCache.Root ~= nil then
            physicalCache.Root, physicalCache.ById = nil, {}
        end
        physicalCache.ScannedAt = now
        return physicalCache.ById
    end
    if not force and root == physicalCache.Root
        and now - physicalCache.ScannedAt < EGG_SCAN_INTERVAL then
        return physicalCache.ById
    end

    local directory = directoryFor(context)
    local byId = {}
    for _, object in ipairs(root:GetDescendants()) do
        if (object:IsA("Model") or object:IsA("Folder")) and object:FindFirstChild("Center") then
            local eggId = instanceEggId(object)
            if eggId and (not directory or directory[eggId]) then
                byId[eggId] = byId[eggId] or {}
                byId[eggId][#byId[eggId] + 1] = object
            end
        end
    end
    physicalCache.Root, physicalCache.ById, physicalCache.ScannedAt = root, byId, now
    return byId
end

local function rootPosition(context)
    local player = context.Player or game:GetService("Players").LocalPlayer
    local character = player and player.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    return root and root.Position or nil
end

local function physicalEgg(context, eggId, force)
    local candidates = scanPhysical(context, force)[tostring(eggId)]
    if type(candidates) ~= "table" then return nil, nil end
    local playerPosition = rootPosition(context)
    local best, bestDistance, bestPosition
    for _, object in ipairs(candidates) do
        local position = instancePosition(object)
        if position then
            local distance = playerPosition and (position - playerPosition).Magnitude or math.huge
            if not bestDistance or distance < bestDistance then
                best, bestDistance, bestPosition = object, distance, position
            end
        end
    end
    return best and { Object = best, Position = bestPosition }, bestDistance
end

local function isHatchable(entry)
    return type(entry) == "table" and entry.disabled ~= true and entry.hatchable ~= false
end

local function unlocked(context, eggId, save, visiting)
    local directory = directoryFor(context)
    local entry = directory and directory[eggId]
    if not isHatchable(entry) then return false, "egg is disabled or not hatchable" end
    visiting = visiting or {}
    if visiting[eggId] then return false, "egg unlock chain contains a cycle" end
    visiting[eggId] = true

    if entry.areaRequired then
        local worldCommands = context.Library.WorldCmds
        if not worldCommands or type(worldCommands.HasArea) ~= "function" then
            visiting[eggId] = nil
            return false, "area unlock data is not ready"
        end
        local checked, ownsArea = pcall(worldCommands.HasArea, entry.area)
        if not checked or not ownsArea then
            visiting[eggId] = nil
            return false, "required area is locked: " .. tostring(entry.area or "unknown")
        end
    end

    local requiredEgg = tostring(entry.eggRequired or "")
    if requiredEgg ~= "" and requiredEgg ~= tostring(eggId) then
        local ownsRequirement, problem = unlocked(context, requiredEgg, save, visiting)
        if not ownsRequirement then
            visiting[eggId] = nil
            return false, "required egg is locked: " .. requiredEgg .. " (" .. tostring(problem) .. ")"
        end
    end
    local amount = tonumber(entry.eggRequiredOpenAmount) or 0
    if amount > 0 and requiredEgg ~= "" then
        local opened = type(save.EggsOpened) == "table" and tonumber(save.EggsOpened[requiredEgg]) or 0
        if (opened or 0) < amount then
            visiting[eggId] = nil
            return false, string.format("open %s %d more time(s)", requiredEgg, amount - (opened or 0))
        end
    end
    if tostring(eggId) == "Dominus Egg" and save.OwnsDominusGate ~= true then
        visiting[eggId] = nil
        return false, "Dominus Gate is locked"
    end
    visiting[eggId] = nil
    return true
end

local function inventoryCount(save)
    local pets = type(save) == "table" and save.Pets or nil
    if type(pets) ~= "table" then return nil end
    local count = #pets
    if count == 0 then for _ in pairs(pets) do count = count + 1 end end
    return count
end

local function inspectEgg(context)
    local eggId = tostring(context.Egg or "")
    local count = tonumber(context.Count) == 3 and 3 or 1
    local directory = directoryFor(context)
    local entry = directory and directory[eggId]
    if not isHatchable(entry) then return false, "Selected egg is not hatchable: " .. eggId end
    local save = saveFor(context)
    if not save then return false, "Player save is not ready" end
    local ownsEgg, unlockProblem = unlocked(context, eggId, save)
    if not ownsEgg then return false, "Selected egg is locked: " .. tostring(unlockProblem) end
    if count == 3 and not hasGamepass(save, "Triple Egg Open") then
        return false, "x3 requires the Triple Egg Open gamepass"
    end

    local physical, distance = physicalEgg(context, eggId, false)
    if not physical then return false, "Selected egg is not present in the current world: " .. eggId end
    if distance == nil or distance == math.huge then return false, "Character position is not ready" end
    if distance > EGG_INTERACT_DISTANCE then
        return false, string.format("Too far from %s: %.1f studs (maximum 15)", eggId, distance)
    end

    local used, maxSlots = inventoryCount(save), tonumber(save.MaxSlots)
    if used == nil or maxSlots == nil then return false, "Pet inventory limits are not ready" end
    local freeSlots = math.max(0, maxSlots - used)
    if freeSlots < count then
        return false, string.format("Not enough pet slots: need %d, free %d", count, freeSlots)
    end

    local cost, currency = tonumber(entry.cost), tostring(entry.currency or "")
    if cost == nil or currency == "" then return false, "Egg price data is unavailable" end
    local balance = context.GetCurrency(currency)
    local totalCost = cost * count
    if balance == nil then return false, "Balance is unavailable for " .. currency end
    if balance < totalCost then
        local format = context.FormatNumber or tostring
        return false, string.format("Not enough %s: need %s, balance %s",
            currency, format(totalCost), format(balance))
    end
    return true, {
        Egg = eggId, Config = entry, Physical = physical.Object, Distance = distance,
        Cost = totalCost, Currency = currency, Balance = balance, FreeSlots = freeSlots,
    }
end

local function buildCatalog(context)
    local directory = directoryFor(context)
    if not directory then
        return { "Egg catalog is loading..." }, nil, nil,
            "Library.Directory.Eggs is loading...", {}
    end
    scanPhysical(context, false)
    local entries, nearest, nearestDistance = {}, nil, math.huge
    local loadedCount, nearbyCount = 0, 0
    for rawId, entry in pairs(directory) do
        if isHatchable(entry) then
            local eggId = tostring(rawId)
            local physical, distance = physicalEgg(context, eggId, false)
            local loaded = physical ~= nil
            local nearby = loaded and distance and distance <= EGG_INTERACT_DISTANCE
            if loaded then loadedCount = loadedCount + 1 end
            if nearby then
                nearbyCount = nearbyCount + 1
                if distance < nearestDistance then nearest, nearestDistance = eggId, distance end
            end
            entries[#entries + 1] = {
                Id = eggId, Name = tostring(entry.displayName or entry.name or eggId),
                Nearby = nearby, Distance = distance,
            }
        end
    end
    table.sort(entries, function(left, right)
        local leftName, rightName = lower(left.Name), lower(right.Name)
        if leftName == rightName then return left.Id < right.Id end
        return leftName < rightName
    end)

    local selected = tostring(context.Selected or "")
    local selectedEntry
    for _, entry in ipairs(entries) do if entry.Id == selected then selectedEntry = entry; break end end
    if not selectedEntry then selected = nearest or (entries[1] and entries[1].Id or "") end
    if context.Scope == "Nearby Eggs" and not context.PreserveSelected then
        local selectedNearby = false
        for _, entry in ipairs(entries) do
            if entry.Id == selected and entry.Nearby then selectedNearby = true; break end
        end
        if not selectedNearby then selected = nearest or "" end
    end

    local options, labelToId, idToLabel, included = {}, {}, {}, {}
    local function include(entry)
        if included[entry.Id] then return end
        included[entry.Id] = true
        local label = entry.Name
        if entry.Id ~= entry.Name then label = label .. "  [" .. entry.Id .. "]" end
        options[#options + 1], labelToId[label], idToLabel[entry.Id] = label, entry.Id, label
    end
    for _, entry in ipairs(entries) do
        if context.Scope ~= "Nearby Eggs" or entry.Nearby then include(entry) end
    end
    if context.PreserveSelected and selected ~= "" then
        for _, entry in ipairs(entries) do if entry.Id == selected then include(entry); break end end
    end
    if #options == 0 then options[1] = "No hatchable eggs within 15 studs" end

    local selectedDistance
    if selected ~= "" then local _, distance = physicalEgg(context, selected, false); selectedDistance = distance end
    local selectedText = selected == "" and "No egg selected"
        or selectedDistance and string.format("%s is %.1f studs away (%s)", selected,
            selectedDistance, selectedDistance <= 15 and "in range" or "out of range")
        or (selected .. " is not loaded in this world")
    local summary = string.format(
        "Hatchable: %d | loaded in world: %d | within 15 studs: %d\n%s",
        #entries, loadedCount, nearbyCount, selectedText
    )
    return options, idToLabel[selected], selected, summary, labelToId
end

local function setStatus(state, context, text)
    text = tostring(text or "")
    if state.LastStatus == text then return end
    state.LastStatus = text
    context.SetStatus(text)
end

local function openingFlag(context)
    local variables = context.Library and context.Library.Variables
    return variables and variables.OpeningEgg == true
end

local function acquireHeadlessGate(state, context)
    local variables = context.Library and context.Library.Variables
    if not variables then return false, "Library.Variables is unavailable" end
    if variables.OpeningEgg == true and not state.GateOwned then
        return false, "another egg animation is still active"
    end
    local ok, problem = pcall(function() variables.OpeningEgg = true end)
    if not ok then return false, tostring(problem) end
    state.GateOwned = true
    return true
end

local function releaseHeadlessGate(state, context)
    if not state.GateOwned then return end
    state.GateOwned = false
    local variables = context.Library and context.Library.Variables
    if variables then pcall(function() variables.OpeningEgg = false end) end
end

local function eventSignature(eggName, pets)
    local values = {}
    if type(pets) == "table" then
        local checked = 0
        for key, pet in pairs(pets) do
            checked = checked + 1
            local value = pet
            if type(pet) == "table" then
                value = pet.uid or pet.UID or pet.id or pet.ID or key
            end
            values[#values + 1] = tostring(value)
            if checked >= 8 then break end
        end
        table.sort(values)
    end
    if #values == 0 then values[1] = tostring(pets) end
    return tostring(eggName) .. "|" .. table.concat(values, ",")
end

local function cleanEventCache(state, now)
    for signature, timestamp in pairs(state.AcknowledgedEvents) do
        if now - timestamp > 20 then state.AcknowledgedEvents[signature] = nil end
    end
end

local function suspiciousReply(message)
    local text = lower(message)
    return string.find(text, "exploit", 1, true)
        or string.find(text, "too fast", 1, true)
        or string.find(text, "rate", 1, true)
        or string.find(text, "spam", 1, true)
end

local function requestLabel(pending)
    return tostring(pending.Egg) .. " " .. (pending.Triple and "x3" or "x1")
end

local function finishSuccess(state, context, pending, note)
    if state.Pending ~= pending then return end
    releaseHeadlessGate(state, context)
    state.Pending = nil
    state.Successes = state.Successes + 1
    state.ConsecutiveFailures = 0
    state.CleanSuccesses = state.CleanSuccesses + 1
    if state.CleanSuccesses >= 8 then
        state.CleanSuccesses = 0
        state.RequestDelay = math.max(MIN_REQUEST_DELAY, state.RequestDelay - 0.025)
    end
    state.NextAction = os.clock() + state.RequestDelay
    setStatus(state, context, string.format(
        "Hatched %s | completed: %d\n%s | adaptive delay: %.2fs | one request in flight",
        requestLabel(pending),
        state.Successes,
        tostring(note or pending.Route or "Open Egg event confirmed"),
        state.RequestDelay
    ))
end

local function finishRejection(state, context, pending)
    if state.Pending ~= pending then return end
    releaseHeadlessGate(state, context)
    state.Pending = nil
    state.Rejections = state.Rejections + 1
    state.ConsecutiveFailures = state.ConsecutiveFailures + 1
    state.CleanSuccesses = 0
    state.RequestDelay = math.min(MAX_REQUEST_DELAY, math.max(1, state.RequestDelay * 1.65))
    local message = tostring(pending.Message or "server rejected the purchase")
    local pause = suspiciousReply(message) and SUSPICIOUS_PAUSE or state.RequestDelay
    state.SuspendedUntil = suspiciousReply(message) and (os.clock() + pause) or 0
    state.NextAction = os.clock() + pause
    setStatus(state, context, string.format(
        "Server rejected %s: %s\nNo retry overlap | next local attempt in %.1fs | rejects: %d",
        requestLabel(pending), message, pause, state.Rejections
    ))
end

local function finishTimeout(state, context, pending)
    if state.Pending ~= pending then return end
    releaseHeadlessGate(state, context)
    state.Timeouts = state.Timeouts + 1
    state.CleanSuccesses = 0
    state.ConsecutiveFailures = state.ConsecutiveFailures + 1
    state.RequestDelay = math.min(MAX_REQUEST_DELAY, math.max(2, state.RequestDelay * 2))

    if not pending.ResponseDone then
        state.Pending = nil
        state.Running = false
        local reason = "Buy Egg Yay did not return in " .. tostring(EVENT_TIMEOUT)
            .. "s; auto hatch stopped so a second request cannot overlap it"
        setStatus(state, context, reason)
        context.Trace("auto egg safety stop", reason)
        context.Disable(reason)
        return
    end

    state.Pending = nil
    state.NextAction = os.clock() + state.RequestDelay
    setStatus(state, context, string.format(
        "Timed out waiting for matching Open Egg: %s\nNo duplicate was sent | adaptive delay: %.1fs",
        requestLabel(pending), state.RequestDelay
    ))
end

local function handlePending(state, context, now)
    local pending = state.Pending
    if not pending then return false end

    if pending.ResponseDone and pending.EventReceived then
        if pending.Accepted or pending.Acknowledged then
            if pending.Headless then
                if pending.Acknowledged then
                    finishSuccess(state, context, pending, pending.Route)
                end
            elseif not openingFlag(context) then
                finishSuccess(state, context, pending, pending.Route)
            end
        else
            finishRejection(state, context, pending)
        end
        return true
    end

    if pending.ResponseDone and not pending.Accepted and not pending.EventReceived then
        finishRejection(state, context, pending)
        return true
    end

    if now - pending.StartedAt >= EVENT_TIMEOUT then
        finishTimeout(state, context, pending)
        return true
    end

    if pending.EventReceived and not pending.ResponseDone then
        setStatus(state, context, "Open Egg received for " .. requestLabel(pending)
            .. "; waiting for the single Buy Egg Yay call to return...")
    elseif pending.ResponseDone and pending.Accepted and not pending.EventReceived then
        setStatus(state, context, "Buy Egg Yay accepted for " .. requestLabel(pending)
            .. "; waiting for its matching Open Egg event...")
    elseif pending.EventReceived and not pending.Headless and openingFlag(context) then
        setStatus(state, context, "Native animation is finishing for " .. requestLabel(pending)
            .. "; the next purchase remains locked...")
    end
    return true
end

local function beginRequest(state, context, options, inspection)
    local headless = options.Animation == "Headless (No Animation)"
    if headless then
        local acquired, problem = acquireHeadlessGate(state, context)
        if not acquired then
            state.NextAction = os.clock() + LOCAL_RECHECK_DELAY
            setStatus(state, context, "Ready, but waiting locally: " .. tostring(problem)
                .. "\nNo purchase request was sent.")
            return
        end
    elseif openingFlag(context) then
        state.NextAction = os.clock() + LOCAL_RECHECK_DELAY
        setStatus(state, context, "Waiting for the current native egg animation to finish.\nNo purchase request was sent.")
        return
    end

    if not state.Running or not context.Running() or not context.Enabled() then
        releaseHeadlessGate(state, context)
        return
    end

    local pending = {
        Egg = options.Egg,
        Triple = options.Count == 3,
        Headless = headless,
        StartedAt = os.clock(),
        ResponseDone = false,
        Accepted = false,
        EventReceived = false,
        Acknowledged = false,
        Inspection = inspection,
    }
    state.Pending = pending
    state.Requests = state.Requests + 1
    setStatus(state, context, string.format(
        "Sending one Buy Egg Yay request: %s\nDistance: %.1f/15 | request #%d | dynamic Network route",
        requestLabel(pending), tonumber(inspection.Distance) or 0, state.Requests
    ))

    task.spawn(function()
        local result = table.pack(context.InvokeCommand("Buy Egg Yay", pending.Egg, pending.Triple))
        if state.Pending ~= pending or not state.Running then return end
        pending.ResponseDone = true
        pending.TransportOk = result[1] == true
        pending.Accepted = pending.TransportOk and result[2] == true
        pending.Message = result[3]
        pending.Route = context.RouteText(result[4], result[5])
        if not pending.TransportOk then
            pending.Accepted = false
            pending.Message = "transport error: " .. tostring(result[3])
        end
    end)
end

local function runCycle(state, context)
    local now = os.clock()
    if handlePending(state, context, now) then return end
    releaseHeadlessGate(state, context)
    if now < state.NextAction then return end

    if state.SuspendedUntil > now then
        state.NextAction = math.min(state.SuspendedUntil, now + 1)
        setStatus(state, context, string.format(
            "Safety pause after a rate-limit style reply: %.0fs remaining.\nNo purchase requests are being sent.",
            state.SuspendedUntil - now
        ))
        return
    end
    state.SuspendedUntil = 0

    local options = context.GetOptions()
    if type(options) ~= "table" or type(options.Egg) ~= "string" or options.Egg == "" then
        state.NextAction = now + LOCAL_RECHECK_DELAY
        setStatus(state, context, "Select a hatchable egg. No purchase request was sent.")
        return
    end
    options.Count = tonumber(options.Count) == 3 and 3 or 1

    local ready, inspection = context.InspectEgg(options.Egg, options.Count)
    if not ready then
        state.NextAction = now + LOCAL_RECHECK_DELAY
        setStatus(state, context, tostring(inspection)
            .. "\nLocal preflight blocked Buy Egg Yay; zero requests sent.")
        return
    end
    beginRequest(state, context, options, inspection)
end

local function stopState(state, context)
    if not state then return true end
    state.Running = false
    releaseHeadlessGate(state, context)
    if state.Connection and type(state.Connection.Disconnect) == "function" then
        pcall(function() state.Connection:Disconnect() end)
    end
    state.Connection = nil
    if activeState == state then activeState = nil end
    local env = type(getgenv) == "function" and getgenv() or _G
    if env.PSX_OG_FastEggState == state then env.PSX_OG_FastEggState = nil end
    return true
end

local function stop()
    if activeState then return stopState(activeState, activeState.Context) end
    return true
end

return function(action, context)
    if action == "stop" then return stop() end
    if action == "invalidate-catalog" then
        physicalCache.Root, physicalCache.ById, physicalCache.ScannedAt = nil, {}, 0
        return true
    end
    if action == "catalog" then
        if type(context) ~= "table" or not context.Library then
            return nil, nil, nil, "Egg catalog context is missing Library", {}
        end
        return buildCatalog(context)
    end
    if action == "inspect" then
        if type(context) ~= "table" or not context.Library or type(context.GetCurrency) ~= "function" then
            return false, "Egg inspection context is incomplete"
        end
        return inspectEgg(context)
    end
    if action ~= "start" then return false, "unknown action" end
    if activeState and activeState.Running then return true end
    if type(context) ~= "table" then return false, "module context is missing" end
    for _, key in ipairs({
        "Library", "Running", "Enabled", "GetOptions", "InspectEgg", "InvokeCommand",
        "RouteText", "SetStatus", "Trace", "Disable",
    }) do
        if context[key] == nil then return false, "module context is missing " .. key end
    end

    local network = context.Library and context.Library.Network
    if not network or type(network.Fired) ~= "function" or type(network.Fire) ~= "function" then
        return false, "Library.Network Fired/Fire is unavailable"
    end
    local signalOk, signal = pcall(network.Fired, "Open Egg")
    if not signalOk or not signal or type(signal.Connect) ~= "function" then
        return false, "Open Egg event could not be resolved by Library.Network.Fired"
    end

    local state = {
        Context = context,
        Running = true,
        GateOwned = false,
        Pending = nil,
        NextAction = os.clock() + ARM_DELAY,
        RequestDelay = INITIAL_REQUEST_DELAY,
        SuspendedUntil = 0,
        AcknowledgedEvents = {},
        Requests = 0,
        Successes = 0,
        Rejections = 0,
        Timeouts = 0,
        CleanSuccesses = 0,
        ConsecutiveFailures = 0,
    }
    activeState = state

    local connected, connection = pcall(function()
        return signal:Connect(function(eggName, pets)
            if not state.Running or activeState ~= state then return end
            local pending = state.Pending
            local matching = pending and tostring(pending.Egg) == tostring(eggName)

            if state.GateOwned then
                local now = os.clock()
                cleanEventCache(state, now)
                local signature = eventSignature(eggName, pets)
                if not state.AcknowledgedEvents[signature] then
                    local ackOk, ackProblem = pcall(network.Fire, "Opening Egg", eggName, pets)
                    if ackOk then
                        state.AcknowledgedEvents[signature] = now
                        if matching then pending.Acknowledged = true end
                    elseif matching then
                        pending.Message = "Opening Egg acknowledgement failed: " .. tostring(ackProblem)
                    end
                elseif matching then
                    pending.Acknowledged = true
                end
            end

            if matching then
                pending.EventReceived = true
                pending.EventAt = os.clock()
            elseif state.GateOwned then
                context.Trace("auto egg", "acknowledged an unexpected Open Egg while the headless gate was owned: "
                    .. tostring(eggName))
            end
        end)
    end)
    if not connected or not connection then
        activeState = nil
        return false, "Open Egg listener failed: " .. tostring(connection)
    end
    state.Connection = connection

    local env = type(getgenv) == "function" and getgenv() or _G
    state.Stop = function() return stopState(state, context) end
    env.PSX_OG_FastEggState = state
    context.Trace("auto egg module", "started with dynamic Buy Egg Yay/Open Egg/Opening Egg routes")
    setStatus(state, context,
        "Auto hatch armed. Catalog and distance checks are local; no probe purchase was sent.\n"
        .. "Waiting for a valid egg within 15 studs...")

    task.spawn(function()
        while state.Running and activeState == state and context.Running() and context.Enabled() do
            local ok, problem = pcall(runCycle, state, context)
            if not ok then
                releaseHeadlessGate(state, context)
                state.NextAction = os.clock() + 2
                state.RequestDelay = math.min(MAX_REQUEST_DELAY, math.max(2, state.RequestDelay * 1.5))
                local status = "Auto egg worker recovered from a local error: " .. tostring(problem)
                context.Trace("auto egg", status)
                setStatus(state, context, status .. "\nNo immediate retry; waiting 2 seconds.")
            end
            task.wait(0.05)
        end
        stopState(state, context)
    end)
    return true
end
