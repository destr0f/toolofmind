-- Lazy event-pet Rainbow Machine worker for PSX OG Nova develop.
-- Converts verified golden pets through a user-selected server tier.

local activeState
local MODULE_VERSION = "1.0.0"
local RETRY_DELAY = 10
local PENDING_TIMEOUT = 15

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
    if level == nil and rawLevel ~= nil then level = ROMAN_LEVELS[string.upper(tostring(rawLevel))] end
    return name ~= nil and tostring(name) or nil, level
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

local function clearPending(state, context)
    table.clear(state.Pending)
    state.PendingAt = 0
    state.PendingAudit = nil
    if context then releaseOperation(state, context) end
end

local function refreshPending(state, context, save)
    if next(state.Pending) == nil then return 0 end
    local stillGolden, count = {}, 0
    for _, pet in pairs((save and save.Pets) or {}) do
        local uid = type(pet) == "table" and pet.uid ~= nil and tostring(pet.uid) or nil
        if uid and state.Pending[uid] and pet.g and not pet.r and not pet.dm then
            stillGolden[uid] = true
            count = count + 1
        end
    end
    if count == 0 then
        if state.PendingAudit then
            state.LastConfirmedAudit = state.PendingAudit
            context.Trace("rainbow machine confirmed pets", state.PendingAudit)
        end
        clearPending(state, context)
        return 0
    end
    state.Pending = stillGolden
    if os.clock() - state.PendingAt >= PENDING_TIMEOUT then
        context.Trace("rainbow machine", "save refresh timeout; releasing pending UID guard | "
            .. tostring(state.PendingAudit or "unknown batch"))
        clearPending(state, context)
        return 0
    end
    return count
end

local function statsText(stats)
    return string.format(
        "target pets: %d | golden: %d | eligible: %d | equipped skipped: %d | locked: %d | rainbow/DM: %d | normal: %d | pending: %d",
        stats.All, stats.Golden, stats.Eligible, stats.Equipped,
        stats.Locked, stats.Upgraded, stats.Normal, stats.Pending
    )
end

local function collectCandidates(state, context, save)
    local groups = {}
    local targetIds, _, catalogSummary = targetCatalog(context)
    local stats = {
        All = 0, Golden = 0, Eligible = 0, Equipped = 0,
        Locked = 0, Upgraded = 0, Normal = 0, Pending = 0,
    }
    for _, pet in pairs((save and save.Pets) or {}) do
        if type(pet) == "table" then
            local definition = definitionFor(context, pet)
            local petId = tostring(pet.id or "")
            if type(definition) == "table" and targetIds[petId] then
                stats.All = stats.All + 1
                if pet.r or pet.dm then
                    stats.Upgraded = stats.Upgraded + 1
                elseif not pet.g then
                    stats.Normal = stats.Normal + 1
                else
                    stats.Golden = stats.Golden + 1
                    local uid = pet.uid ~= nil and tostring(pet.uid) or nil
                    local equipped = pet.e == true
                    local locked = pet.l == true or pet.locked == true
                    if equipped then stats.Equipped = stats.Equipped + 1 end
                    if locked then stats.Locked = stats.Locked + 1 end
                    if equipped or locked or uid == nil
                        or definition.isPremium or definition.rarity == "Exclusive" then
                        -- Deliberately excluded.
                    elseif state.Pending[uid] then
                        stats.Pending = stats.Pending + 1
                    else
                        stats.Eligible = stats.Eligible + 1
                        groups[petId] = groups[petId] or {}
                        groups[petId][#groups[petId] + 1] = {
                            Uid = uid,
                            Id = petId,
                            Name = tostring(definition.name or petId),
                        }
                    end
                end
            end
        end
    end
    local candidates, selectedId = {}, nil
    local groupCounts = {}
    for id, group in pairs(groups) do
        table.sort(group, function(left, right) return left.Uid < right.Uid end)
        groupCounts[#groupCounts + 1] = tostring(group[1] and group[1].Name or id)
            .. "=" .. tostring(#group)
        if #group > #candidates or (#group == #candidates and (selectedId == nil or id < selectedId)) then
            candidates, selectedId = group, id
        end
    end
    table.sort(groupCounts)
    return candidates, stats, catalogSummary,
        #groupCounts > 0 and table.concat(groupCounts, ", ") or "none"
end

local function reportInventory(state, context, stats)
    local signature = string.format("%d:%d:%d:%d:%d:%d:%d:%d",
        stats.All, stats.Golden, stats.Eligible, stats.Equipped,
        stats.Locked, stats.Upgraded, stats.Normal, stats.Pending)
    if signature ~= state.LastInventorySignature then
        state.LastInventorySignature = signature
        context.Trace("rainbow machine inventory", statsText(stats))
    end
end

local function validateSelection(context, selectedCandidates)
    local save = context.GetSave()
    if not save then return false, nil, nil, "fresh Save.Pets is unavailable" end
    local targetIds = targetCatalog(context)
    local byUID = {}
    for _, pet in pairs(save.Pets or {}) do
        if type(pet) == "table" and pet.uid ~= nil then byUID[tostring(pet.uid)] = pet end
    end
    local selectedUIDs, auditLabels, expectedId = {}, {}, nil
    for index, candidate in ipairs(selectedCandidates) do
        local uid = tostring(candidate.Uid)
        local pet = byUID[uid]
        if not pet then return false, nil, nil, shortUID(uid) .. " disappeared before dispatch" end
        local definition = definitionFor(context, pet)
        local petId = tostring(pet.id or "")
        if type(definition) ~= "table" or not targetIds[petId] then
            return false, nil, nil, shortUID(uid) .. " is no longer in the event-pet catalog"
        end
        if not pet.g or pet.r or pet.dm then
            return false, nil, nil, shortUID(uid) .. " is no longer an eligible golden pet"
        end
        if pet.e == true then return false, nil, nil, shortUID(uid) .. " is equipped" end
        if pet.l == true or pet.locked == true then return false, nil, nil, shortUID(uid) .. " is locked" end
        if definition.isPremium or definition.rarity == "Exclusive" then
            return false, nil, nil, shortUID(uid) .. " is not machine-eligible"
        end
        expectedId = expectedId or petId
        if petId ~= expectedId then
            return false, nil, nil, "selected pets no longer share the same directory id"
        end
        selectedUIDs[index] = uid
        auditLabels[index] = auditLabel(pet)
    end
    return true, selectedUIDs, auditLabels, nil
end

local function resolveBatch(state, context)
    if not state.MachineInfo then
        local remote, sourceName, sessionIndex, problem =
            context.GetCommandRemote("Get Rainbow Machine Info")
        if not remote then return nil, nil, nil, problem end
        local ok, info = pcall(function() return remote:InvokeServer() end)
        if not ok then
            context.InvalidateCommand("Get Rainbow Machine Info")
            return nil, nil, nil, "Get Rainbow Machine Info transport error: " .. tostring(info)
        end
        if type(info) ~= "table" or #info < 1 then
            return nil, nil, nil, "Get Rainbow Machine Info returned no batch tiers"
        end
        state.MachineInfo = info
        context.Trace("rainbow machine route", context.RouteText(sourceName, sessionIndex)
            .. " | server batch tiers=" .. tostring(#info))
    end
    local requested = math.floor(tonumber(context.BatchSize()) or 6)
    local batchSize = math.clamp(requested, 1, #state.MachineInfo)
    local tier = type(state.MachineInfo[batchSize]) == "table" and state.MachineInfo[batchSize] or {}
    return batchSize, tonumber(tier.cost or tier.Cost),
        tonumber(tier.chance or tier.Chance), nil
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
        context.SetStatus("Player save is unavailable; no pets were sent.")
        finish(2)
        return
    end
    local pendingCount = refreshPending(state, context, save)
    local candidates, stats, catalogSummary, groupSummary = collectCandidates(state, context, save)
    reportInventory(state, context, stats)
    local batchSize, batchCost, tierChance, batchProblem = resolveBatch(state, context)
    if not batchSize then
        context.SetStatus("Inventory counted before routing. Route/info error; no pets were sent: "
            .. tostring(batchProblem) .. "\n" .. statsText(stats)
            .. "\nCatalog: " .. catalogSummary .. "\nNext retry in 10 seconds.")
        finish(RETRY_DELAY)
        return
    end
    if pendingCount > 0 then
        context.SetStatus("Previous batch accepted; waiting for Save.Pets ("
            .. tostring(pendingCount) .. " golden UID remaining).\nPending: "
            .. tostring(state.PendingAudit or "unknown") .. "\n" .. statsText(stats))
        finish(0.5)
        return
    end
    if #candidates < batchSize then
        context.SetStatus("Waiting for " .. tostring(batchSize) .. " matching golden pets; largest species group has "
            .. tostring(#candidates) .. ". No request sent.\n"
            .. statsText(stats) .. "\nGroups: " .. groupSummary
            .. "\nCatalog: " .. catalogSummary .. "\nLast confirmed: " .. state.LastConfirmedAudit)
        finish(2)
        return
    end
    local diamonds = context.GetCurrency("Diamonds")
    if batchCost and diamonds ~= nil and diamonds < batchCost then
        context.SetStatus("Not enough Diamonds: " .. context.FormatNumber(diamonds)
            .. "/" .. context.FormatNumber(batchCost) .. ". No request sent.\n" .. statsText(stats))
        finish(RETRY_DELAY)
        return
    end

    local selectedCandidates = {}
    for index = 1, batchSize do selectedCandidates[index] = candidates[index] end
    local acquired, owner = acquireOperation(state, context)
    if not acquired then
        context.SetStatus("A " .. tostring(batchSize) .. "-pet Rainbow batch is ready, but pet inventory is reserved by "
            .. tostring(owner) .. ". No request sent.\n" .. statsText(stats))
        finish(0.2)
        return
    end
    local safe, selectedUIDs, selectedAudit, problem = validateSelection(context, selectedCandidates)
    if not safe then
        releaseOperation(state, context)
        local status = "Safety recheck blocked the batch; no request sent: " .. tostring(problem)
        context.SetStatus(status .. "\n" .. statsText(stats))
        context.Trace("rainbow machine safety", status)
        finish(0.5)
        return
    end
    if not state.Running or not context.Running() or not context.Enabled() then
        releaseOperation(state, context)
        finish(0.5)
        return
    end

    local auditText = table.concat(selectedAudit, " | ")
    context.Trace("rainbow machine validated pets", auditText)
    local transportOk, accepted, serverMessage, sourceName, sessionIndex, serverChance =
        context.InvokeCommand("Use Rainbow Machine", selectedUIDs)
    if not transportOk then
        releaseOperation(state, context)
        context.SetStatus("Route/transport error; no conversion confirmed: " .. tostring(serverMessage)
            .. "\nValidated but not confirmed: " .. auditText .. "\n" .. statsText(stats))
        finish(RETRY_DELAY)
    elseif not accepted then
        releaseOperation(state, context)
        local reason = serverMessage ~= nil and tostring(serverMessage) or "request rejected"
        context.SetStatus("Server reached via " .. context.RouteText(sourceName, sessionIndex) .. ": " .. reason
            .. "\nRejected batch: " .. auditText .. "\n" .. statsText(stats))
        context.Trace("rainbow machine", "request rejected: " .. reason .. " | " .. auditText)
        finish(RETRY_DELAY)
    else
        clearPending(state)
        for _, uid in ipairs(selectedUIDs) do state.Pending[uid] = true end
        state.PendingAt = os.clock()
        state.PendingAudit = auditText
        state.CompletedBatches = state.CompletedBatches + 1
        local chance = tonumber(serverChance) or tonumber(tierChance) or 0
        local status = "Batch accepted via " .. context.RouteText(sourceName, sessionIndex)
            .. " | golden pets: " .. tostring(batchSize) .. " | chance: " .. tostring(chance)
            .. "% | completed batches: " .. tostring(state.CompletedBatches)
        context.SetStatus(status .. "\nAccepted pets: " .. auditText
            .. "\nWaiting for Save.Pets before selecting the next batch.")
        context.Trace("rainbow machine accepted pets", auditText)
        context.Trace("rainbow machine", status)
        finish(0.5)
    end
end

local function stop()
    if activeState then
        local state = activeState
        activeState.Running = false
        activeState.Busy = false
        clearPending(activeState, activeState.Context)
        pcall(activeState.Context.CancelOperation, activeState.Context.OperationOwner)
        if state.Context.Kernel then
            state.Context.Kernel:Unregister(state.JobKey, "rainbow machine disabled")
        end
        activeState = nil
    end
    return true
end

return function(action, context)
    if action == "version" then return MODULE_VERSION end
    if action == "stop" then return stop() end
    if action ~= "start" then return false, "unknown action" end
    if activeState and activeState.Running then return true end
    if type(context) ~= "table" then return false, "module context is missing" end
    local required = {
        "Library", "Kernel", "Running", "Enabled", "GetSave", "GetCurrency", "FormatNumber",
        "GetMachinePetCatalog", "BatchSize", "GetCommandRemote", "InvalidateCommand",
        "InvokeCommand", "RouteText", "AcquireOperation", "ReleaseOperation",
        "CancelOperation", "OperationOwner", "SetStatus", "Trace",
    }
    for _, key in ipairs(required) do
        if context[key] == nil then return false, "module context is missing " .. key end
    end
    local state = {
        Context = context, Running = true, Busy = false, OperationOwned = false,
        NextCheck = 0, Pending = {}, PendingAt = 0,
        LastConfirmedAudit = "none", CompletedBatches = 0, JobKey = "machine.rainbow",
    }
    activeState = state
    context.Trace("rainbow machine module", "lazy worker started")
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
                    local status = "Worker error; no conversion confirmed: " .. tostring(problem)
                    context.Trace("rainbow machine", status)
                    context.SetStatus(status .. "\nNext retry in 10 seconds.")
                end
            end
        end,
        { Owner = "machines" }
    )
    if registered == false then
        activeState = nil
        return false, "RuntimeKernel rejected rainbow worker: " .. tostring(registrationProblem)
    end
    return true
end
