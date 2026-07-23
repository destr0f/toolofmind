-- Lazy event-pet Dark Matter Machine worker for PSX OG Nova develop.
-- Queues verified rainbow pets and redeems completed queue slots serially.

local activeState
local MODULE_VERSION = "1.0.1"
local RETRY_DELAY = 10
local PENDING_TIMEOUT = 20

local ABBREVIATIONS = {
    ["Agility"] = "AG", ["Chest"] = "CH", ["Chests"] = "CH",
    ["Coins"] = "C", ["Diamonds"] = "D", ["Fantasy Coins"] = "FC",
    ["Glittering"] = "GL", ["Presents"] = "PR", ["Royalty"] = "ROY",
    ["Strength"] = "STR", ["Teamwork"] = "TW", ["Tech Coins"] = "TC",
}
local ROMAN_LEVELS = { I = 1, II = 2, III = 3, IV = 4, V = 5 }

local function readPower(power)
    if type(power) ~= "table" then return nil, nil end
    local name = power[1] or power.name or power.Name or power.power or power.Power
    local rawLevel = power[2] or power.level or power.Level or power.tier or power.Tier
    local level = tonumber(rawLevel)
    if level == nil and rawLevel ~= nil then
        level = ROMAN_LEVELS[string.upper(tostring(rawLevel))]
    end
    return name ~= nil and tostring(name) or nil, level
end

local function protectedTechCoins(pet)
    local powers = type(pet) == "table" and (pet.powers or pet.Powers) or nil
    if type(powers) ~= "table" then return false end
    for _, power in pairs(powers) do
        local name, level = readPower(power)
        if string.lower(tostring(name or "")) == "tech coins" and level and level >= 4 then
            return true, level
        end
    end
    return false
end

local function abbreviate(name)
    if ABBREVIATIONS[name] then return ABBREVIATIONS[name] end
    local initials = {}
    for word in string.gmatch(tostring(name or ""), "%a+") do
        initials[#initials + 1] = string.sub(string.upper(word), 1, 1)
    end
    if #initials >= 2 then return table.concat(initials) end
    return string.sub(string.upper(tostring(name or "?")), 1, 3)
end

local function shortUID(uid)
    uid = tostring(uid or "?")
    if #uid <= 16 then return uid end
    return string.sub(uid, 1, 10) .. ".." .. string.sub(uid, -4)
end

local function auditLabel(pet)
    local labels = {}
    local powers = type(pet) == "table" and (pet.powers or pet.Powers) or nil
    if type(powers) == "table" then
        for _, power in pairs(powers) do
            local name, level = readPower(power)
            if name then labels[#labels + 1] = abbreviate(name) .. tostring(level or "?") end
        end
    end
    table.sort(labels)
    return shortUID(type(pet) == "table" and pet.uid or nil)
        .. "{" .. (#labels > 0 and table.concat(labels, ",") or "none") .. "}"
end

local function definitionFor(context, pet)
    local directory = context.Library.Directory and context.Library.Directory.Pets
    if type(directory) ~= "table" or type(pet) ~= "table" then return nil end
    return directory[pet.id] or directory[tostring(pet.id)]
end

local function targetCatalog(context)
    local ids, names, summary = context.GetMachinePetCatalog()
    return type(ids) == "table" and ids or {}, type(names) == "table" and names or {},
        tostring(summary or "event pet catalog unavailable")
end

local function acquireOperation(state, context)
    if state.OperationOwned then return true end
    local ok, acquired, owner = pcall(context.AcquireOperation, context.OperationOwner)
    if not ok then return false, tostring(acquired) end
    if acquired ~= true then return false, tostring(owner or "another inventory worker") end
    state.OperationOwned = true
    return true
end

local function releaseOperation(state, context)
    if not state.OperationOwned then return end
    state.OperationOwned = false
    pcall(context.ReleaseOperation, context.OperationOwner)
end

local function dictionaryCount(value)
    local count = 0
    for _ in pairs(type(value) == "table" and value or {}) do count = count + 1 end
    return count
end

local function slotLimit(save, queueCount)
    local raw = save and save.DarkMatterSlots
    local slots
    if type(raw) == "number" then
        slots = math.floor(raw)
    elseif type(raw) == "table" then
        slots = dictionaryCount(raw)
    end
    return math.max(1, tonumber(slots) or 1, tonumber(queueCount) or 0)
end

local function formatDuration(seconds)
    seconds = math.max(0, math.floor(tonumber(seconds) or 0))
    local days = math.floor(seconds / 86400)
    local hours = math.floor(seconds % 86400 / 3600)
    local minutes = math.floor(seconds % 3600 / 60)
    if days > 0 then return string.format("%dd %02dh %02dm", days, hours, minutes) end
    return string.format("%dh %02dm", hours, minutes)
end

local function selectMachineTier(info, requestedCount, maxWaitSeconds)
    if type(info) ~= "table" or #info < 1 then
        return nil, nil, nil, "Dark Matter machine tiers are unavailable"
    end

    local maxBatch = #info
    local requested = math.clamp(math.floor(tonumber(requestedCount) or 6), 1, maxBatch)
    local target = tonumber(maxWaitSeconds)
    if target ~= nil and target <= 0 then target = nil end

    local selected = requested
    local targetMet = target == nil
    local fastestIndex, fastestWait = requested, nil
    if target ~= nil then
        for index = requested, maxBatch do
            local tier = type(info[index]) == "table" and info[index] or {}
            local waitTime = tonumber(tier.waitTime or tier.WaitTime)
            if waitTime ~= nil and (fastestWait == nil or waitTime < fastestWait) then
                fastestIndex, fastestWait = index, waitTime
            end
            if waitTime ~= nil and waitTime <= target then
                selected = index
                targetMet = true
                break
            end
        end
        if not targetMet then selected = fastestIndex end
    end

    local tier = type(info[selected]) == "table" and info[selected] or {}
    local waitTime = tonumber(tier.waitTime or tier.WaitTime)
    return selected, tier, {
        Requested = requested,
        Selected = selected,
        AddedPets = math.max(0, selected - requested),
        MaxWaitSeconds = target,
        WaitTime = waitTime,
        TargetMet = targetMet,
    }, nil
end

local function tierPolicyText(policy)
    if type(policy) ~= "table" then return "server tier unavailable" end
    local text = "requested " .. tostring(policy.Requested) .. " pet(s)"
    if policy.MaxWaitSeconds ~= nil then
        text = text .. " | maximum " .. formatDuration(policy.MaxWaitSeconds)
        if policy.AddedPets > 0 then
            text = text .. " | server tier adds " .. tostring(policy.AddedPets) .. " pet(s)"
        end
        text = text .. (policy.TargetMet and " | limit satisfied" or " | fastest tier still exceeds limit")
    else
        text = text .. " | exact-count mode"
    end
    if policy.WaitTime ~= nil then text = text .. " | actual " .. formatDuration(policy.WaitTime) end
    return text
end

local function statsText(stats)
    return string.format(
        "target pets: %d | rainbow: %d | eligible: %d | Tech Coins IV-V protected: %d | equipped skipped: %d | locked: %d | other forms: %d | pending: %d",
        stats.All, stats.Rainbow, stats.Eligible, stats.Protected,
        stats.Equipped, stats.Locked, stats.Other, stats.Pending
    )
end

local function setStatus(state, context, text)
    if text == state.LastStatus then return end
    state.LastStatus = text
    context.SetStatus(text)
end

local function clearPendingCreate(state, context)
    table.clear(state.PendingCreate)
    state.PendingCreateAt = 0
    state.PendingCreateAudit = nil
    if context then releaseOperation(state, context) end
end

local function refreshPendingCreate(state, context, save)
    if next(state.PendingCreate) == nil then return 0 end
    local stillPresent, count = {}, 0
    for _, pet in pairs((save and save.Pets) or {}) do
        local uid = type(pet) == "table" and pet.uid ~= nil and tostring(pet.uid) or nil
        if uid and state.PendingCreate[uid] then
            stillPresent[uid] = true
            count = count + 1
        end
    end
    if count == 0 then
        if state.PendingCreateAudit then
            state.LastQueuedAudit = state.PendingCreateAudit
            context.Trace("dark matter confirmed queued pets", state.PendingCreateAudit)
        end
        clearPendingCreate(state, context)
        return 0
    end
    state.PendingCreate = stillPresent
    if os.clock() - state.PendingCreateAt >= PENDING_TIMEOUT then
        context.Trace("dark matter", "Save.Pets timeout; releasing queued UID guard | "
            .. tostring(state.PendingCreateAudit or "unknown"))
        clearPendingCreate(state, context)
        return 0
    end
    return count
end

local function normalizedQueue(save)
    local result = {}
    for slotId, entry in pairs(type(save and save.DarkMatterQueue) == "table"
        and save.DarkMatterQueue or {}) do
        result[tostring(slotId)] = { Id = slotId, Entry = entry }
    end
    return result
end

local function refreshPendingClaims(state, context, queue)
    local released = false
    for key, pending in pairs(state.PendingClaims) do
        if queue[key] == nil then
            state.PendingClaims[key] = nil
            state.Claimed = state.Claimed + 1
            context.Trace("dark matter claim confirmed", "slot=" .. tostring(pending.Id))
            released = true
        elseif os.clock() - pending.At >= PENDING_TIMEOUT then
            state.PendingClaims[key] = nil
            context.Trace("dark matter", "claim refresh timeout; releasing slot guard "
                .. tostring(pending.Id))
            released = true
        end
    end
    if released and next(state.PendingClaims) == nil then releaseOperation(state, context) end
end

local function getServerTime(state, context)
    if state.ServerTime ~= nil and state.ServerClock ~= nil then
        return state.ServerTime + (os.clock() - state.ServerClock), nil
    end
    if os.clock() < state.ServerRetryAt then
        return nil, state.ServerProblem or "server clock retry pending"
    end
    local remote, sourceName, sessionIndex, problem = context.GetCommandRemote("Get OSTime")
    if not remote then
        state.ServerRetryAt = os.clock() + RETRY_DELAY
        state.ServerProblem = problem
        return nil, problem
    end
    local ok, raw = pcall(function() return remote:InvokeServer() end)
    local value = ok and tonumber(raw) or nil
    if value == nil then
        context.InvalidateCommand("Get OSTime")
        state.ServerRetryAt = os.clock() + RETRY_DELAY
        state.ServerProblem = ok and "Get OSTime returned a non-number"
            or ("Get OSTime transport error: " .. tostring(raw))
        return nil, state.ServerProblem
    end
    state.ServerTime = value
    state.ServerClock = os.clock()
    state.ServerProblem = nil
    context.Trace("dark matter clock", context.RouteText(sourceName, sessionIndex))
    return value, nil
end

local function resolveMachineInfo(state, context)
    if state.MachineInfo and state.MaxBatch then
        return state.MachineInfo, state.MaxBatch, nil
    end
    local remote, sourceName, sessionIndex, problem =
        context.GetCommandRemote("Get Dark Matter Machine Info")
    if not remote then return nil, nil, problem end
    local ok, info = pcall(function() return remote:InvokeServer() end)
    if not ok then
        context.InvalidateCommand("Get Dark Matter Machine Info")
        return nil, nil, "Get Dark Matter Machine Info transport error: " .. tostring(info)
    end
    if type(info) ~= "table" or #info < 1 then
        return nil, nil, "Get Dark Matter Machine Info returned no batch tiers"
    end
    state.MachineInfo = info
    state.MaxBatch = #info
    context.Trace("dark matter route", context.RouteText(sourceName, sessionIndex)
        .. " | max batch=" .. tostring(state.MaxBatch))
    return info, state.MaxBatch, nil
end

local function collectCandidates(state, context, save)
    local groups = {}
    local targetIds, _, catalogSummary = targetCatalog(context)
    local stats = {
        All = 0, Rainbow = 0, Eligible = 0, Protected = 0,
        Equipped = 0, Locked = 0, Other = 0, Pending = 0,
    }
    for _, pet in pairs((save and save.Pets) or {}) do
        if type(pet) == "table" then
            local definition = definitionFor(context, pet)
            local petId = tostring(pet.id or "")
            if targetIds[petId] then
                stats.All = stats.All + 1
                if not pet.r or pet.g or pet.dm then
                    stats.Other = stats.Other + 1
                else
                    stats.Rainbow = stats.Rainbow + 1
                    local uid = pet.uid ~= nil and tostring(pet.uid) or nil
                    local protected = protectedTechCoins(pet)
                    local equipped = pet.e == true
                    local locked = pet.l == true or pet.locked == true
                    if protected then stats.Protected = stats.Protected + 1 end
                    if equipped then stats.Equipped = stats.Equipped + 1 end
                    if locked then stats.Locked = stats.Locked + 1 end
                    local directoryBlocked = type(definition) == "table"
                        and (definition.isPremium or definition.rarity == "Exclusive")
                    if protected or equipped or locked or uid == nil or directoryBlocked then
                        -- Deliberately excluded.
                    elseif state.PendingCreate[uid] then
                        stats.Pending = stats.Pending + 1
                    else
                        stats.Eligible = stats.Eligible + 1
                        local id = petId
                        groups[id] = groups[id] or {}
                        groups[id][#groups[id] + 1] = {
                            Uid = uid,
                            Id = id,
                            Name = tostring(type(definition) == "table" and definition.name or id),
                        }
                    end
                end
            end
        end
    end
    local selected, selectedId = {}, nil
    local groupCounts = {}
    for id, group in pairs(groups) do
        table.sort(group, function(left, right) return left.Uid < right.Uid end)
        groupCounts[#groupCounts + 1] = tostring(group[1] and group[1].Name or id)
            .. "=" .. tostring(#group)
        if #group > #selected or (#group == #selected and (selectedId == nil or id < selectedId)) then
            selected, selectedId = group, id
        end
    end
    table.sort(groupCounts)
    return selected, stats, catalogSummary,
        #groupCounts > 0 and table.concat(groupCounts, ", ") or "none"
end

local function validateSelection(context, candidates)
    local save = context.GetSave()
    if not save then return false, nil, nil, "fresh Save.Pets is unavailable" end
    local targetIds = targetCatalog(context)
    local byUID = {}
    for _, pet in pairs(save.Pets or {}) do
        if type(pet) == "table" and pet.uid ~= nil then byUID[tostring(pet.uid)] = pet end
    end
    local selectedUIDs, labels, expectedId = {}, {}, nil
    for index, candidate in ipairs(candidates) do
        local uid = tostring(candidate.Uid)
        local pet = byUID[uid]
        if not pet then return false, nil, nil, shortUID(uid) .. " disappeared before dispatch" end
        local definition = definitionFor(context, pet)
        local petId = tostring(pet.id or "")
        if not targetIds[petId] then
            return false, nil, nil, shortUID(uid) .. " is no longer in the event-pet catalog"
        end
        if not pet.r or pet.g or pet.dm then
            return false, nil, nil, shortUID(uid) .. " is no longer an eligible rainbow pet"
        end
        local protected, level = protectedTechCoins(pet)
        if protected then
            return false, nil, nil, shortUID(uid) .. " has protected Tech Coins " .. tostring(level)
        end
        if pet.e == true then return false, nil, nil, shortUID(uid) .. " is equipped" end
        if pet.l == true or pet.locked == true then
            return false, nil, nil, shortUID(uid) .. " is locked"
        end
        if type(definition) == "table"
            and (definition.isPremium or definition.rarity == "Exclusive") then
            return false, nil, nil, shortUID(uid) .. " is not machine-eligible"
        end
        expectedId = expectedId or petId
        if petId ~= expectedId then
            return false, nil, nil, "selected pets no longer share the same directory id"
        end
        selectedUIDs[index] = uid
        labels[index] = auditLabel(pet)
    end
    return true, selectedUIDs, labels, nil
end

local function queueSnapshot(queue, serverTime)
    local ready, nearest = {}, nil
    for key, item in pairs(queue) do
        local entry = type(item.Entry) == "table" and item.Entry or {}
        local readyTime = tonumber(entry.readyTime or entry.ReadyTime)
        if serverTime ~= nil and readyTime ~= nil then
            local remaining = readyTime - serverTime
            if remaining <= 1 then
                ready[#ready + 1] = { Key = key, Id = item.Id }
            elseif nearest == nil or remaining < nearest then
                nearest = remaining
            end
        end
    end
    table.sort(ready, function(left, right) return left.Key < right.Key end)
    return ready, nearest
end

local function runCheck(state, context)
    if state.Busy then return end
    state.Busy = true
    local function finish(delay)
        state.NextCheck = os.clock() + (delay or 0.5)
        state.Busy = false
    end

    local save = context.GetSave()
    if not save then
        setStatus(state, context, "Player save is unavailable; no Dark Matter action was sent.")
        finish(2)
        return
    end

    local queue = normalizedQueue(save)
    local queueCount = dictionaryCount(queue)
    local slots = slotLimit(save, queueCount)
    refreshPendingClaims(state, context, queue)
    local pendingCreate = refreshPendingCreate(state, context, save)
    local candidates, stats, catalogSummary, groupSummary = collectCandidates(state, context, save)
    local serverTime, clockProblem = getServerTime(state, context)
    local ready, nearest = queueSnapshot(queue, serverTime)

    if pendingCreate > 0 then
        setStatus(state, context, "Previous Dark Matter batch accepted; waiting for Save.Pets ("
            .. tostring(pendingCreate) .. " UID remaining).\nPending: "
            .. tostring(state.PendingCreateAudit or "unknown") .. "\n" .. statsText(stats))
        finish(0.5)
        return
    end
    if next(state.PendingClaims) ~= nil then
        setStatus(state, context, "Dark Matter claim accepted; waiting for DarkMatterQueue confirmation.\n"
            .. "Queue: " .. tostring(queueCount) .. "/" .. tostring(slots)
            .. " | claimed this session: " .. tostring(state.Claimed))
        finish(0.5)
        return
    end

    if context.ClaimEnabled() and #ready > 0 then
        local claim
        for _, candidate in ipairs(ready) do
            if not state.PendingClaims[candidate.Key] then claim = candidate; break end
        end
        if claim then
            local acquired, owner = acquireOperation(state, context)
            if not acquired then
                setStatus(state, context, "A completed Dark Matter pet is ready, but pet inventory is reserved by "
                    .. tostring(owner) .. ". No claim sent.")
                finish(0.2)
                return
            end
            local transportOk, accepted, message, sourceName, sessionIndex =
                context.InvokeCommand("Redeem Dark Matter Pet", claim.Id)
            if not transportOk then
                releaseOperation(state, context)
                setStatus(state, context, "Dark Matter claim transport error: " .. tostring(message)
                    .. "\nQueue: " .. tostring(queueCount) .. "/" .. tostring(slots))
                finish(RETRY_DELAY)
            elseif not accepted then
                releaseOperation(state, context)
                local reason = message ~= nil and tostring(message) or "request rejected"
                setStatus(state, context, "Claim rejected via "
                    .. context.RouteText(sourceName, sessionIndex) .. ": " .. reason)
                finish(RETRY_DELAY)
            else
                state.PendingClaims[claim.Key] = { Id = claim.Id, At = os.clock() }
                setStatus(state, context, "Claim accepted via "
                    .. context.RouteText(sourceName, sessionIndex) .. " | slot=" .. tostring(claim.Id)
                    .. "\nWaiting for DarkMatterQueue confirmation.")
                context.Trace("dark matter claim", "accepted slot=" .. tostring(claim.Id))
                finish(0.5)
            end
            return
        end
    end

    if not context.CreateEnabled() then
        local timer = nearest and (" | next ready in " .. formatDuration(nearest)) or ""
        local clock = serverTime == nil and (" | clock: " .. tostring(clockProblem)) or ""
        setStatus(state, context, "Auto claim active | queue: " .. tostring(queueCount)
            .. "/" .. tostring(slots) .. timer .. clock
            .. "\nClaimed this session: " .. tostring(state.Claimed))
        finish(2)
        return
    end

    local info, _, infoProblem = resolveMachineInfo(state, context)
    if not info then
        setStatus(state, context, "Dark Matter route/info error; no pets were sent: "
            .. tostring(infoProblem) .. "\n" .. statsText(stats)
            .. "\nCatalog: " .. catalogSummary)
        finish(RETRY_DELAY)
        return
    end
    if queueCount >= slots then
        local timer = nearest and (" | next ready in " .. formatDuration(nearest)) or ""
        setStatus(state, context, "Dark Matter queue is full: " .. tostring(queueCount)
            .. "/" .. tostring(slots) .. timer .. "\n" .. statsText(stats))
        finish(2)
        return
    end
    if #candidates == 0 then
        setStatus(state, context, "No eligible rainbow target pets.\n"
            .. statsText(stats) .. "\nGroups: " .. groupSummary
            .. "\nCatalog: " .. catalogSummary .. "\nLast queued: " .. state.LastQueuedAudit)
        finish(2)
        return
    end

    local requested = math.floor(tonumber(context.BatchSize()) or 6)
    local maxWaitSeconds
    if type(context.MaxWaitSeconds) == "function" then
        local readOk, rawLimit = pcall(context.MaxWaitSeconds)
        if readOk then maxWaitSeconds = tonumber(rawLimit) end
    end
    local batchSize, tier, tierPolicy, tierProblem =
        selectMachineTier(info, requested, maxWaitSeconds)
    if not batchSize then
        setStatus(state, context, "Dark Matter tier policy error; no pets were sent: "
            .. tostring(tierProblem) .. "\n" .. statsText(stats))
        finish(RETRY_DELAY)
        return
    end
    local policySummary = tierPolicyText(tierPolicy)
    if #candidates < batchSize then
        setStatus(state, context, "Waiting for " .. tostring(batchSize)
            .. " matching rainbow pets; largest species group has " .. tostring(#candidates)
            .. ". No request sent.\nPolicy: " .. policySummary
            .. "\n" .. statsText(stats) .. "\nGroups: " .. groupSummary
            .. "\nCatalog: " .. catalogSummary)
        finish(2)
        return
    end
    local batchCost = tonumber(tier.cost or tier.Cost)
    local waitTime = tierPolicy.WaitTime
    local diamonds = context.GetCurrency("Diamonds")
    if batchCost and diamonds ~= nil and diamonds < batchCost then
        setStatus(state, context, "Not enough Diamonds for a " .. tostring(batchSize)
            .. "-pet Dark Matter batch: " .. context.FormatNumber(diamonds)
            .. "/" .. context.FormatNumber(batchCost) .. ". No request sent.\nPolicy: "
            .. policySummary .. "\n" .. statsText(stats))
        finish(RETRY_DELAY)
        return
    end

    local selected = {}
    for index = 1, batchSize do selected[index] = candidates[index] end
    local acquired, owner = acquireOperation(state, context)
    if not acquired then
        setStatus(state, context, "A " .. tostring(batchSize)
            .. "-pet Dark Matter batch is ready, but pet inventory is reserved by "
            .. tostring(owner) .. ". No request sent.\nPolicy: " .. policySummary
            .. "\n" .. statsText(stats))
        finish(0.2)
        return
    end
    local safe, selectedUIDs, labels, problem = validateSelection(context, selected)
    if not safe then
        releaseOperation(state, context)
        local status = "Dark Matter safety recheck blocked the batch: " .. tostring(problem)
        setStatus(state, context, status .. "\n" .. statsText(stats))
        context.Trace("dark matter safety", status)
        finish(0.5)
        return
    end
    if not state.Running or not context.Running() or not context.CreateEnabled() then
        releaseOperation(state, context)
        finish(0.5)
        return
    end

    local audit = table.concat(labels, " | ")
    context.Trace("dark matter validated pets", audit)
    local transportOk, accepted, message, sourceName, sessionIndex =
        context.InvokeCommand("Convert To Dark Matter", selectedUIDs)
    if not transportOk then
        releaseOperation(state, context)
        setStatus(state, context, "Dark Matter transport error; no queue confirmed: "
            .. tostring(message) .. "\nValidated but not confirmed: " .. audit)
        finish(RETRY_DELAY)
    elseif not accepted then
        releaseOperation(state, context)
        local reason = message ~= nil and tostring(message) or "request rejected"
        setStatus(state, context, "Server reached via "
            .. context.RouteText(sourceName, sessionIndex) .. ": " .. reason
            .. "\nRejected pets: " .. audit .. "\n" .. statsText(stats))
        context.Trace("dark matter", "request rejected: " .. reason .. " | " .. audit)
        finish(RETRY_DELAY)
    else
        clearPendingCreate(state)
        for _, uid in ipairs(selectedUIDs) do state.PendingCreate[uid] = true end
        state.PendingCreateAt = os.clock()
        state.PendingCreateAudit = audit
        state.QueuedBatches = state.QueuedBatches + 1
        local duration = waitTime and formatDuration(waitTime) or "server-defined"
        local status = "Dark Matter batch accepted via "
            .. context.RouteText(sourceName, sessionIndex) .. " | pets: "
            .. tostring(batchSize) .. " | timer: " .. duration
            .. " | queued batches: " .. tostring(state.QueuedBatches)
        setStatus(state, context, status .. "\nAccepted pets: " .. audit
            .. "\nPolicy: " .. policySummary
            .. "\nWaiting for Save.Pets and DarkMatterQueue confirmation.")
        context.Trace("dark matter accepted pets", audit)
        context.Trace("dark matter", status)
        finish(0.5)
    end
end

local function stop()
    if activeState then
        local state = activeState
        activeState.Running = false
        activeState.Busy = false
        clearPendingCreate(activeState, activeState.Context)
        table.clear(activeState.PendingClaims)
        pcall(activeState.Context.CancelOperation, activeState.Context.OperationOwner)
        if state.Context.Kernel then
            state.Context.Kernel:Unregister(state.JobKey, "dark matter machine disabled")
        end
        activeState = nil
    end
    return true
end

return function(action, context)
    if action == "version" then return MODULE_VERSION end
    if action == "select-tier" then
        context = type(context) == "table" and context or {}
        return selectMachineTier(context.Info, context.BatchSize, context.MaxWaitSeconds)
    end
    if action == "stop" then return stop() end
    if action ~= "start" then return false, "unknown action" end
    if activeState and activeState.Running then return true end
    if type(context) ~= "table" then return false, "module context is missing" end
    local required = {
        "Library", "Kernel", "Running", "Enabled", "CreateEnabled", "ClaimEnabled",
        "GetSave", "GetCurrency", "FormatNumber", "GetMachinePetCatalog", "BatchSize",
        "GetCommandRemote", "InvalidateCommand", "InvokeCommand", "RouteText",
        "AcquireOperation", "ReleaseOperation", "CancelOperation", "OperationOwner",
        "SetStatus", "Trace",
    }
    for _, key in ipairs(required) do
        if context[key] == nil then return false, "module context is missing " .. key end
    end
    local state = {
        Context = context, Running = true, Busy = false, OperationOwned = false, NextCheck = 0,
        PendingCreate = {}, PendingCreateAt = 0, PendingClaims = {},
        LastQueuedAudit = "none", QueuedBatches = 0, Claimed = 0,
        ServerRetryAt = 0,
        JobKey = "machine.dark-matter",
    }
    activeState = state
    context.Trace("dark matter module", "lazy create/claim worker started")
    local _, registered, registrationProblem = context.Kernel:Every(
        state.JobKey,
        0.5,
        "P3",
        function(cancelToken)
            if cancelToken:IsCancelled() or not state.Running or activeState ~= state
                or not context.Running() or not context.Enabled() then
                if activeState == state then activeState = nil end
                return false
            end
            if not state.Busy and os.clock() >= state.NextCheck then
                local ok, problem = pcall(runCheck, state, context)
                if not ok then
                    state.Busy = false
                    releaseOperation(state, context)
                    state.NextCheck = os.clock() + RETRY_DELAY
                    local status = "Dark Matter worker error; no action confirmed: " .. tostring(problem)
                    context.Trace("dark matter", status)
                    context.SetStatus(status .. "\nNext retry in 10 seconds.")
                end
            end
        end,
        { Owner = "machines" }
    )
    if registered == false then
        activeState = nil
        return false, "RuntimeKernel rejected dark matter worker: " .. tostring(registrationProblem)
    end
    return true
end
