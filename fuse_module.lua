-- LowOnline Samurai Egg fuse worker.
-- Resolves named Network routes at runtime and validates every UID immediately
-- before one Use Fuse Machine request.

local activeState
local MODULE_VERSION = "1.5.0-lowonline"

local TARGET_EGG = "Samurai Egg"
local IDLE_CHECK_DELAY = 3
local RETRY_DELAY = 8
local PENDING_TIMEOUT = 12

local MODE_POLICY = {
    ["11 Panda"] = {
        Count = 11,
        Names = { ["panda"] = true, ["basic panda"] = true },
    },
    ["10 Axolotl"] = {
        Count = 10,
        Names = { ["axolotl"] = true },
    },
    ["9 Tiger"] = {
        Count = 9,
        Names = { ["tiger"] = true, ["white tiger"] = true },
    },
    ["7 Any Rare"] = {
        Count = 7,
        Rarity = "rare",
    },
    ["4 Any Epic"] = {
        Count = 4,
        Rarity = "epic",
    },
}
local MODE_ORDER = {
    "11 Panda",
    "10 Axolotl",
    "9 Tiger",
    "7 Any Rare",
    "4 Any Epic",
}

local function normalize(value)
    value = string.lower(tostring(value or ""))
    value = string.gsub(value, "[%p_]+", " ")
    value = string.gsub(value, "%s+", " ")
    return string.match(value, "^%s*(.-)%s*$") or value
end

local function definitionName(definition)
    if type(definition) ~= "table" then return nil end
    return definition.name or definition.Name
        or definition.displayName or definition.DisplayName
        or definition.petName or definition.PetName
end

local function policyMatchesDefinition(policy, definition)
    if type(policy) ~= "table" or type(definition) ~= "table" then return false end
    if type(policy.Names) == "table" then
        return policy.Names[normalize(definitionName(definition))] == true
    end
    if policy.Rarity ~= nil then
        return normalize(definition.rarity or definition.Rarity) == normalize(policy.Rarity)
    end
    return false
end

local function shortUID(uid)
    uid = tostring(uid or "?")
    if #uid <= 16 then return uid end
    return string.sub(uid, 1, 10) .. ".." .. string.sub(uid, -4)
end

local function petDefinition(context, pet)
    local pets = context.Library.Directory and context.Library.Directory.Pets
    if type(pets) ~= "table" or type(pet) ~= "table" then return nil end
    return pets[pet.id] or pets[tostring(pet.id)]
end

local function resolveEggDrops(context)
    local eggs = context.Library.Directory and context.Library.Directory.Eggs
    if type(eggs) ~= "table" then return nil, "Directory.Eggs is unavailable" end
    local egg = eggs[TARGET_EGG]
    if type(egg) ~= "table" then return nil, TARGET_EGG .. " is unavailable" end
    local drops = egg.drops or egg.Drops
    local visited = {}
    while type(drops) == "string" do
        if visited[drops] then return nil, "egg drop alias cycle: " .. drops end
        visited[drops] = true
        local aliased = eggs[drops]
        if type(aliased) ~= "table" then
            return nil, "egg drop alias is unavailable: " .. drops
        end
        drops = aliased.drops or aliased.Drops
    end
    if type(drops) ~= "table" then return nil, TARGET_EGG .. " drops are unavailable" end

    local ids = {}
    for _, drop in pairs(drops) do
        local id
        if type(drop) == "table" then
            id = drop[1] or drop.id or drop.ID or drop.petId or drop.PetId
        elseif type(drop) == "string" or type(drop) == "number" then
            id = drop
        end
        if id ~= nil then ids[tostring(id)] = true end
    end
    if next(ids) == nil then return nil, TARGET_EGG .. " has no readable pet IDs" end
    return ids, nil
end

local function activeModes(context)
    local configured = context.Modes()
    local result = {}
    if type(configured) == "table" then
        for _, name in ipairs(MODE_ORDER) do
            if configured[name] == true then result[#result + 1] = name end
        end
        for _, rawName in ipairs(configured) do
            local name = tostring(rawName)
            if MODE_POLICY[name] and configured[name] ~= false
                and not table.find(result, name) then
                result[#result + 1] = name
            end
        end
    end
    return result
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

local function refreshPending(state, context, pets)
    if next(state.Pending) == nil then return 0 end
    local present, count = {}, 0
    for _, pet in pairs(pets or {}) do
        local uid = type(pet) == "table" and pet.uid or nil
        uid = uid ~= nil and tostring(uid) or nil
        if uid and state.Pending[uid] then
            present[uid] = true
            count = count + 1
        end
    end
    if count == 0 then
        if state.PendingAudit then
            state.LastConfirmedAudit = state.PendingAudit
            context.Trace("fuse confirmed pets", state.PendingAudit)
        end
        clearPending(state, context)
        return 0
    end
    state.Pending = present
    if os.clock() - state.PendingAt >= PENDING_TIMEOUT then
        context.Trace("fuse", "Save.Pets refresh timeout; releasing UID guard")
        clearPending(state, context)
        return 0
    end
    return count
end

local function readFuseInfo(state, context)
    if state.FuseInfo then return state.FuseInfo, nil end
    local remote, sourceName, sessionIndex, problem =
        context.GetCommandRemote("Get Fuse Pets Info")
    if not remote then return nil, problem end
    local result = table.pack(pcall(function() return remote:InvokeServer() end))
    if not result[1] then
        context.InvalidateCommand("Get Fuse Pets Info")
        return nil, "Get Fuse Pets Info transport error: " .. tostring(result[2])
    end
    local cost = tonumber(result[2])
    local maximum = tonumber(result[3])
    local minimum = tonumber(result[4])
    if maximum == nil or minimum == nil then
        return nil, "Get Fuse Pets Info returned invalid limits"
    end
    state.FuseInfo = {
        Cost = cost,
        Maximum = math.floor(maximum),
        Minimum = math.floor(minimum),
        Route = context.RouteText(sourceName, sessionIndex),
    }
    context.Trace("fuse route", state.FuseInfo.Route
        .. " | min=" .. tostring(state.FuseInfo.Minimum)
        .. " | max=" .. tostring(state.FuseInfo.Maximum)
        .. " | cost=" .. tostring(state.FuseInfo.Cost or "?"))
    return state.FuseInfo, nil
end

local function collectCandidateGroups(context, pets, targetIds, policy)
    local groups, stats = {}, {
        EggSpecies = 0,
        MatchingPolicy = 0,
        Eligible = 0,
        Equipped = 0,
        Locked = 0,
        WrongForm = 0,
        DirectoryBlocked = 0,
    }
    for _, pet in pairs(pets or {}) do
        if type(pet) == "table" and targetIds[tostring(pet.id or "")] then
            stats.EggSpecies = stats.EggSpecies + 1
            local definition = petDefinition(context, pet)
            local rarity = type(definition) == "table"
                and tostring(definition.rarity or definition.Rarity or "") or ""
            if policyMatchesDefinition(policy, definition) then
                stats.MatchingPolicy = stats.MatchingPolicy + 1
                local equipped = pet.e == true
                local locked = pet.l == true or pet.locked == true
                local wrongForm = pet.g == true or pet.r == true or pet.dm == true
                local blocked = type(definition) ~= "table"
                    or definition.isPremium == true or rarity == "Exclusive"
                if equipped then
                    stats.Equipped = stats.Equipped + 1
                elseif locked then
                    stats.Locked = stats.Locked + 1
                elseif wrongForm then
                    stats.WrongForm = stats.WrongForm + 1
                elseif blocked then
                    stats.DirectoryBlocked = stats.DirectoryBlocked + 1
                elseif pet.uid ~= nil then
                    stats.Eligible = stats.Eligible + 1
                    local petId = tostring(pet.id)
                    local group = groups[petId]
                    if not group then
                        group = {
                            Id = petId,
                            Name = tostring(definitionName(definition) or petId),
                            Required = policy.Count,
                            Candidates = {},
                        }
                        groups[petId] = group
                    end
                    group.Candidates[#group.Candidates + 1] = {
                        Uid = tostring(pet.uid),
                        Id = petId,
                        Strength = tonumber(pet.s) or 0,
                    }
                end
            end
        end
    end
    local ordered = {}
    for _, group in pairs(groups) do
        table.sort(group.Candidates, function(left, right)
            if left.Strength == right.Strength then return left.Uid < right.Uid end
            return left.Strength < right.Strength
        end)
        ordered[#ordered + 1] = group
    end
    table.sort(ordered, function(left, right) return left.Id < right.Id end)
    return ordered, stats
end

local function chooseCandidateGroup(state, modeName, groups, minimum, maximum)
    local ready = {}
    for _, group in ipairs(groups) do
        if group.Required >= minimum and group.Required <= maximum
            and #group.Candidates >= group.Required then
            ready[#ready + 1] = group
        end
    end
    if #ready == 0 then return nil end
    local previous = state.LastSpeciesByMode[modeName]
    for _, group in ipairs(ready) do
        if previous == nil or group.Id > previous then return group end
    end
    return ready[1]
end

local function statsText(stats)
    return string.format(
        "egg species: %d | matching mode: %d | eligible: %d | equipped: %d | locked: %d | wrong form: %d | blocked: %d",
        stats.EggSpecies, stats.MatchingPolicy, stats.Eligible, stats.Equipped,
        stats.Locked, stats.WrongForm, stats.DirectoryBlocked
    )
end

local function validateSelection(context, candidates, targetIds, policy, expectedId)
    local snapshot = context.GetPetSnapshot(true)
    local save = snapshot and snapshot.Save
    if not save then return false, nil, nil, "fresh Save.Pets is unavailable" end
    local byUID = snapshot.ByUID or {}
    local uids, audit = {}, {}
    for index, candidate in ipairs(candidates) do
        local uid = candidate.Uid
        local pet = byUID[uid]
        if type(pet) ~= "table" then
            return false, nil, nil, shortUID(uid) .. " disappeared before dispatch"
        end
        local definition = petDefinition(context, pet)
        local rarity = type(definition) == "table"
            and tostring(definition.rarity or definition.Rarity or "") or ""
        if not targetIds[tostring(pet.id or "")] then
            return false, nil, nil, shortUID(uid) .. " is no longer a " .. TARGET_EGG .. " pet"
        end
        if not policyMatchesDefinition(policy, definition) then
            return false, nil, nil, shortUID(uid) .. " no longer matches the selected mode"
        end
        if tostring(pet.id or "") ~= tostring(expectedId) then
            return false, nil, nil, shortUID(uid) .. " changed species before dispatch"
        end
        if pet.e == true then return false, nil, nil, shortUID(uid) .. " is equipped" end
        if pet.l == true or pet.locked == true then
            return false, nil, nil, shortUID(uid) .. " is locked"
        end
        if pet.g == true or pet.r == true or pet.dm == true then
            return false, nil, nil, shortUID(uid) .. " is not a plain normal pet"
        end
        if type(definition) ~= "table"
            or definition.isPremium == true or rarity == "Exclusive" then
            return false, nil, nil, shortUID(uid) .. " is not fuse-eligible"
        end
        uids[index] = uid
        audit[index] = shortUID(uid) .. "{" .. tostring(pet.id) .. "," .. rarity .. ",N}"
    end
    return true, uids, audit, nil
end

local function runCheck(state, context)
    if state.Busy then return end
    state.Busy = true
    local function finish(delay)
        state.NextCheck = os.clock() + (tonumber(delay) or 0.5)
        state.Busy = false
    end

    local enabledModes = activeModes(context)
    if #enabledModes == 0 then
        context.SetStatus("No Samurai Egg fuse mode is enabled; no request sent.")
        finish(RETRY_DELAY)
        return
    end
    local info, infoProblem = readFuseInfo(state, context)
    if not info then
        context.SetStatus("Fuse route/info error; no request sent: " .. tostring(infoProblem))
        finish(RETRY_DELAY)
        return
    end
    local targetIds, catalogProblem = resolveEggDrops(context)
    if not targetIds then
        context.SetStatus("Fuse catalog error; no request sent: " .. tostring(catalogProblem))
        finish(RETRY_DELAY)
        return
    end
    local snapshot = context.GetPetSnapshot(false)
    local save = snapshot and snapshot.Save
    if not save then
        context.SetStatus("Player Save.Pets is unavailable; no request sent.")
        finish(2)
        return
    end
    local pendingCount = refreshPending(state, context, snapshot.Pets)
    if pendingCount > 0 then
        context.SetStatus("Fuse accepted; waiting for Save.Pets to refresh ("
            .. tostring(pendingCount) .. " UID remaining).\nPending: "
            .. tostring(state.PendingAudit or "unknown"))
        finish(0.4)
        return
    end
    local modeName, policy, candidates, stats, batchSize, speciesId, speciesName
    local summaries = {}
    local startIndex = math.clamp(math.floor(tonumber(state.NextModeIndex) or 1), 1, #enabledModes)
    for offset = 0, #enabledModes - 1 do
        local index = ((startIndex + offset - 1) % #enabledModes) + 1
        local candidateMode = enabledModes[index]
        local candidatePolicy = MODE_POLICY[candidateMode]
        local groups, modeStats =
            collectCandidateGroups(context, snapshot.Pets, targetIds, candidatePolicy)
        local parts = {}
        for _, group in ipairs(groups) do
            parts[#parts + 1] = group.Name .. " "
                .. tostring(#group.Candidates) .. "/" .. tostring(group.Required)
        end
        summaries[#summaries + 1] = candidateMode .. " ["
            .. (#parts > 0 and table.concat(parts, ", ") or "none") .. "]"
        local group = chooseCandidateGroup(
            state, candidateMode, groups, info.Minimum, info.Maximum
        )
        if not modeName and group then
            modeName, policy, candidates, stats = candidateMode, candidatePolicy,
                group.Candidates, modeStats
            batchSize, speciesId, speciesName =
                group.Required, group.Id, group.Name
            state.NextModeIndex = (index % #enabledModes) + 1
        end
    end
    if not modeName then
        context.SetStatus("Waiting for any enabled " .. TARGET_EGG .. " fuse batch.\n"
            .. table.concat(summaries, " | ")
            .. "\nLast confirmed: " .. state.LastConfirmedAudit)
        finish(IDLE_CHECK_DELAY)
        return
    end
    local selected = {}
    for index = 1, batchSize do selected[index] = candidates[index] end
    local acquired, owner = acquireOperation(state, context)
    if not acquired then
        context.SetStatus("A " .. modeName .. " fuse is ready, but inventory is reserved by "
            .. tostring(owner) .. ". No request sent.")
        finish(0.2)
        return
    end
    local safe, uids, audit, validationProblem =
        validateSelection(context, selected, targetIds, policy, speciesId)
    if not safe then
        releaseOperation(state, context)
        context.SetStatus("Fuse safety recheck blocked the request: "
            .. tostring(validationProblem) .. "\n" .. statsText(stats))
        finish(0.5)
        return
    end
    if not state.Running or not context.Running() or not context.Enabled() then
        releaseOperation(state, context)
        finish(0.5)
        return
    end

    local auditText = table.concat(audit, " | ")
    context.Trace("fuse validated pets", auditText)
    local transportOk, accepted, serverMessage, sourceName, sessionIndex =
        context.InvokeCommand("Use Fuse Machine", uids)
    if not transportOk then
        releaseOperation(state, context)
        context.SetStatus("Fuse transport error; no success confirmed: "
            .. tostring(serverMessage) .. "\nValidated: " .. auditText)
        finish(RETRY_DELAY)
    elseif not accepted then
        releaseOperation(state, context)
        local reason = serverMessage ~= nil and tostring(serverMessage) or "request rejected"
        context.SetStatus("Fuse rejected via " .. context.RouteText(sourceName, sessionIndex)
            .. ": " .. reason .. "\nRejected: " .. auditText)
        finish(RETRY_DELAY)
    else
        context.InvalidatePetSnapshot()
        clearPending(state)
        for _, uid in ipairs(uids) do state.Pending[uid] = true end
        state.PendingAt = os.clock()
        state.PendingAudit = modeName .. " | " .. speciesName .. " x"
            .. tostring(batchSize) .. " | " .. auditText
        state.LastSpeciesByMode[modeName] = speciesId
        state.Completed = state.Completed + 1
        context.SetStatus("Fuse accepted via " .. context.RouteText(sourceName, sessionIndex)
            .. " | mode: " .. modeName .. " | completed: " .. tostring(state.Completed)
            .. "\nAccepted pets: " .. auditText)
        context.Trace("fuse accepted pets", state.PendingAudit)
        finish(0.4)
    end
end

local function stop()
    if activeState then
        local state = activeState
        local wasBusy = state.Busy == true
        state.Running = false
        state.Busy = false
        clearPending(state, state.Context)
        pcall(state.Context.CancelOperation, state.Context.OperationOwner)
        local worker = state.WorkerThread
        local workerTask = state.Task
        state.WorkerThread = nil
        if worker and not wasBusy and workerTask and type(workerTask.cancel) == "function" then
            pcall(workerTask.cancel, worker)
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
    for _, key in ipairs({
        "Library", "Running", "Enabled", "Modes", "GetPetSnapshot",
        "InvalidatePetSnapshot", "GetCommandRemote", "InvalidateCommand",
        "InvokeCommand", "RouteText", "AcquireOperation", "ReleaseOperation",
        "CancelOperation", "OperationOwner", "SetStatus", "Trace",
    }) do
        if context[key] == nil then return false, "module context is missing " .. key end
    end

    local state = {
        Context = context,
        Running = true,
        Busy = false,
        OperationOwned = false,
        NextCheck = 0,
        Pending = {},
        PendingAt = 0,
        PendingAudit = nil,
        LastConfirmedAudit = "none",
        FuseInfo = nil,
        Completed = 0,
        NextModeIndex = 1,
        LastSpeciesByMode = {},
        WorkerThread = nil,
        Task = context.Task or task,
    }
    activeState = state
    context.Trace("fuse module", "v" .. MODULE_VERSION
        .. " | target=" .. TARGET_EGG .. " | session-safe named routes")
    state.WorkerThread = state.Task.spawn(function()
        while state.Running and activeState == state and context.Running() and context.Enabled() do
            if not state.Busy and os.clock() >= state.NextCheck then
                local ok, problem = pcall(runCheck, state, context)
                if not ok then
                    state.Busy = false
                    releaseOperation(state, context)
                    state.NextCheck = os.clock() + RETRY_DELAY
                    local status = "Fuse worker recovered from a local error: " .. tostring(problem)
                    context.Trace("fuse", status)
                    context.SetStatus(status .. "\nNext retry in 8 seconds.")
                end
            end
            if state.Running and activeState == state then
                local remaining = state.NextCheck - os.clock()
                state.Task.wait(math.clamp(remaining > 0 and remaining or 0.05, 0.05, IDLE_CHECK_DELAY))
            end
        end
        state.WorkerThread = nil
        if activeState == state then activeState = nil end
    end)
    return true
end
