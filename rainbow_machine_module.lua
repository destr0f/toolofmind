-- Lazy Galaxy Fox Rainbow Machine worker for PSX OG Slim Farm.
-- Converts only verified golden pets in a server-confirmed 100% tier.

local activeState
local PET_NAME = "Galaxy Fox"
local PET_RARITY = "Mythical"
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

local function protectedTechCoins(pet)
    local powers = type(pet) == "table" and (pet.powers or pet.Powers) or nil
    if type(powers) ~= "table" then return false end
    for _, power in pairs(powers) do
        local name, level = readPower(power)
        if string.lower(tostring(name or "")) == "tech coins" and level and level >= 3 then
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

local function clearPending(state)
    table.clear(state.Pending)
    state.PendingAt = 0
    state.PendingAudit = nil
end

local function refreshPending(state, context, save)
    if next(state.Pending) == nil then return 0 end
    local stillGolden, count = {}, 0
    for _, pet in pairs((save and save.Pets) or {}) do
        local uid = type(pet) == "table" and pet.uid ~= nil and tostring(pet.uid) or nil
        if uid and state.Pending[uid] and pet.g == true and not pet.r and not pet.dm then
            stillGolden[uid] = true
            count = count + 1
        end
    end
    if count == 0 then
        if state.PendingAudit then
            state.LastConfirmedAudit = state.PendingAudit
            context.Trace("rainbow machine confirmed pets", state.PendingAudit)
        end
        clearPending(state)
        return 0
    end
    state.Pending = stillGolden
    if os.clock() - state.PendingAt >= PENDING_TIMEOUT then
        context.Trace("rainbow machine", "save refresh timeout; releasing pending UID guard | "
            .. tostring(state.PendingAudit or "unknown batch"))
        clearPending(state)
        return 0
    end
    return count
end

local function statsText(stats)
    return string.format(
        "all Fox: %d | golden: %d | eligible: %d | Tech Coins III+ protected: %d | equipped skipped: %d | locked: %d | rainbow/DM: %d | normal: %d | pending: %d",
        stats.All, stats.Golden, stats.Eligible, stats.Protected, stats.Equipped,
        stats.Locked, stats.Upgraded, stats.Normal, stats.Pending
    )
end

local function collectCandidates(state, context, save)
    local candidates = {}
    local stats = {
        All = 0, Golden = 0, Eligible = 0, Protected = 0, Equipped = 0,
        Locked = 0, Upgraded = 0, Normal = 0, Pending = 0,
    }
    for _, pet in pairs((save and save.Pets) or {}) do
        if type(pet) == "table" then
            local definition = definitionFor(context, pet)
            if type(definition) == "table" and definition.name == PET_NAME
                and definition.rarity == PET_RARITY then
                stats.All = stats.All + 1
                if pet.r or pet.dm then
                    stats.Upgraded = stats.Upgraded + 1
                elseif pet.g ~= true then
                    stats.Normal = stats.Normal + 1
                else
                    stats.Golden = stats.Golden + 1
                    local uid = pet.uid ~= nil and tostring(pet.uid) or nil
                    local protected = protectedTechCoins(pet)
                    local equipped = pet.e == true
                    local locked = pet.l == true or pet.locked == true
                    if protected then stats.Protected = stats.Protected + 1 end
                    if equipped then stats.Equipped = stats.Equipped + 1 end
                    if locked then stats.Locked = stats.Locked + 1 end
                    if protected or equipped or locked or uid == nil
                        or definition.isPremium or definition.rarity == "Exclusive" then
                        -- Deliberately excluded.
                    elseif state.Pending[uid] then
                        stats.Pending = stats.Pending + 1
                    else
                        stats.Eligible = stats.Eligible + 1
                        candidates[#candidates + 1] = { Uid = uid }
                    end
                end
            end
        end
    end
    table.sort(candidates, function(left, right) return left.Uid < right.Uid end)
    return candidates, stats
end

local function reportInventory(state, context, stats)
    local signature = string.format("%d:%d:%d:%d:%d:%d:%d:%d:%d",
        stats.All, stats.Golden, stats.Eligible, stats.Protected, stats.Equipped,
        stats.Locked, stats.Upgraded, stats.Normal, stats.Pending)
    if signature ~= state.LastInventorySignature then
        state.LastInventorySignature = signature
        context.Trace("rainbow machine inventory", statsText(stats))
    end
end

local function validateSelection(context, selectedCandidates)
    local save = context.GetSave()
    if not save then return false, nil, nil, "fresh Save.Pets is unavailable" end
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
        if type(definition) ~= "table" or definition.name ~= PET_NAME
            or definition.rarity ~= PET_RARITY then
            return false, nil, nil, shortUID(uid) .. " is no longer a Mythical Galaxy Fox"
        end
        if pet.g ~= true or pet.r or pet.dm then
            return false, nil, nil, shortUID(uid) .. " is no longer an eligible golden pet"
        end
        local protected, level = protectedTechCoins(pet)
        if protected then
            return false, nil, nil, shortUID(uid) .. " has protected Tech Coins " .. tostring(level)
        end
        if pet.e == true then return false, nil, nil, shortUID(uid) .. " is equipped" end
        if pet.l == true or pet.locked == true then return false, nil, nil, shortUID(uid) .. " is locked" end
        if definition.isPremium or definition.rarity == "Exclusive" then
            return false, nil, nil, shortUID(uid) .. " is not machine-eligible"
        end
        local petId = tostring(pet.id)
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
    if state.BatchSize then return state.BatchSize, state.BatchCost, nil end
    local remote, sourceName, sessionIndex, problem = context.GetCommandRemote("Get Rainbow Machine Info")
    if not remote then return nil, nil, problem end
    local ok, info = pcall(function() return remote:InvokeServer() end)
    if not ok then
        context.InvalidateCommand("Get Rainbow Machine Info")
        return nil, nil, "Get Rainbow Machine Info transport error: " .. tostring(info)
    end
    if type(info) ~= "table" then return nil, nil, "Get Rainbow Machine Info returned " .. typeof(info) end
    for count, tier in ipairs(info) do
        local chance = type(tier) == "table" and tonumber(tier.chance or tier.Chance) or nil
        if chance and chance >= 100 then
            state.BatchSize = count
            state.BatchCost = tonumber(tier.cost or tier.Cost)
            context.Trace("rainbow machine route", context.RouteText(sourceName, sessionIndex)
                .. " | guaranteed batch=" .. tostring(count)
                .. " | cost=" .. tostring(state.BatchCost or "unknown"))
            return state.BatchSize, state.BatchCost, nil
        end
    end
    return nil, nil, "the server did not expose a 100% Rainbow Machine tier"
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
    local candidates, stats = collectCandidates(state, context, save)
    reportInventory(state, context, stats)
    local batchSize, batchCost, batchProblem = resolveBatch(state, context)
    if not batchSize then
        context.SetStatus("Inventory counted before routing. Route/info error; no pets were sent: "
            .. tostring(batchProblem) .. "\n" .. statsText(stats) .. "\nNext retry in 10 seconds.")
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
        context.SetStatus("Waiting for a guaranteed " .. tostring(batchSize) .. "/" .. tostring(batchSize)
            .. " golden batch; currently " .. tostring(#candidates) .. ". No request sent.\n"
            .. statsText(stats) .. "\nLast confirmed: " .. state.LastConfirmedAudit)
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
    local safe, selectedUIDs, selectedAudit, problem = validateSelection(context, selectedCandidates)
    if not safe then
        local status = "Safety recheck blocked the batch; no request sent: " .. tostring(problem)
        context.SetStatus(status .. "\n" .. statsText(stats))
        context.Trace("rainbow machine safety", status)
        finish(0.5)
        return
    end
    if not state.Running or not context.Running() or not context.Enabled() then finish(0.5); return end

    local auditText = table.concat(selectedAudit, " | ")
    context.Trace("rainbow machine validated pets", auditText)
    local transportOk, accepted, serverMessage, sourceName, sessionIndex, serverChance =
        context.InvokeCommand("Use Rainbow Machine", selectedUIDs)
    if not transportOk then
        context.SetStatus("Route/transport error; no conversion confirmed: " .. tostring(serverMessage)
            .. "\nValidated but not confirmed: " .. auditText .. "\n" .. statsText(stats))
        finish(RETRY_DELAY)
    elseif not accepted then
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
        local chance = tonumber(serverChance) or 100
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
        activeState.Running = false
        activeState.Busy = false
        clearPending(activeState)
        activeState = nil
    end
    return true
end

return function(action, context)
    if action == "stop" then return stop() end
    if action ~= "start" then return false, "unknown action" end
    if activeState and activeState.Running then return true end
    if type(context) ~= "table" then return false, "module context is missing" end
    local required = {
        "Library", "Running", "Enabled", "GetSave", "GetCurrency", "FormatNumber",
        "GetCommandRemote", "InvalidateCommand", "InvokeCommand", "RouteText", "SetStatus", "Trace",
    }
    for _, key in ipairs(required) do
        if context[key] == nil then return false, "module context is missing " .. key end
    end
    local state = {
        Running = true, Busy = false, NextCheck = 0, Pending = {}, PendingAt = 0,
        LastConfirmedAudit = "none", CompletedBatches = 0,
    }
    activeState = state
    context.Trace("rainbow machine module", "lazy worker started")
    task.spawn(function()
        while state.Running and activeState == state and context.Running() and context.Enabled() do
            if not state.Busy and os.clock() >= state.NextCheck then
                local ok, problem = pcall(runCheck, state, context)
                if not ok then
                    state.Busy = false
                    state.NextCheck = os.clock() + RETRY_DELAY
                    local status = "Worker error; no conversion confirmed: " .. tostring(problem)
                    context.Trace("rainbow machine", status)
                    context.SetStatus(status .. "\nNext retry in 10 seconds.")
                end
            end
            task.wait(0.5)
        end
        if activeState == state then activeState = nil end
    end)
    return true
end
