-- LowOnline equipped-pet enchant worker.
-- Uses the session-safe named Enchant Pet command and confirms every roll from Save.Pets.

local MODULE_VERSION = "1.0.0-lowonline"
local CHECK_DELAY = 0.15
local IDLE_DELAY = 1
local REJECT_DELAY = 5
local CONFIRM_TIMEOUT = 4
local UNCERTAIN_DELAY = 8

local activeState

local function normalize(value)
    value = string.lower(tostring(value or ""))
    value = string.gsub(value, "[%p_]+", " ")
    value = string.gsub(value, "%s+", " ")
    return string.match(value, "^%s*(.-)%s*$") or value
end

local function shortUID(uid)
    uid = tostring(uid or "?")
    return #uid > 12 and (string.sub(uid, 1, 8) .. "..." .. string.sub(uid, -4)) or uid
end

local function selectedSet(values)
    local result, labels = {}, {}
    for _, value in ipairs(type(values) == "table" and values or {}) do
        local label = type(value) == "table" and (value.Title or value.title or value.Name) or value
        local key = normalize(label)
        if key ~= "" and not result[key] then
            result[key] = true
            labels[#labels + 1] = tostring(label)
        end
    end
    table.sort(labels)
    return result, labels
end

local function powerTitle(context, power)
    if type(power) ~= "table" then return nil end
    local powerName = power[1] or power.name or power.Name or power.power or power.Power
    local tierIndex = tonumber(power[2] or power.tier or power.Tier or power.level or power.Level) or 1
    if powerName == nil then return nil end

    local directory = context.Library and context.Library.Directory
    local powers = directory and directory.Powers
    local definition = type(powers) == "table" and powers[powerName] or nil
    local tiers = type(definition) == "table" and (definition.tiers or definition.Tiers) or nil
    local tier = type(tiers) == "table" and tiers[tierIndex] or nil
    local title = type(tier) == "table" and (tier.title or tier.Title or tier.name or tier.Name) or nil
    return tostring(title or powerName)
end

local function powerSignature(context, pet)
    local parts = {}
    local powers = type(pet) == "table" and (pet.powers or pet.Powers) or nil
    for index, power in ipairs(type(powers) == "table" and powers or {}) do
        parts[index] = tostring(powerTitle(context, power) or "?") .. ":"
            .. tostring(type(power) == "table" and (power[2] or power.tier or power.level) or "")
    end
    return table.concat(parts, "|")
end

local function matchingPower(context, pet, targets)
    local powers = type(pet) == "table" and (pet.powers or pet.Powers) or nil
    for _, power in ipairs(type(powers) == "table" and powers or {}) do
        local title = powerTitle(context, power)
        if title and targets[normalize(title)] then return true, title end
    end
    return false, nil
end

local function inspectPets(context, snapshot, targets, uncertain, now)
    local result = {
        Equipped = 0,
        Eligible = 0,
        Satisfied = 0,
        Locked = 0,
        Uncertain = 0,
        Candidate = nil,
    }
    local candidates = {}
    for _, pet in ipairs(type(snapshot and snapshot.Pets) == "table" and snapshot.Pets or {}) do
        if type(pet) == "table" and pet.e == true then
            result.Equipped = result.Equipped + 1
            local uid = tostring(pet.uid or "")
            if pet.l == true or pet.locked == true then
                result.Locked = result.Locked + 1
            else
                result.Eligible = result.Eligible + 1
                local matched = matchingPower(context, pet, targets)
                if matched then
                    result.Satisfied = result.Satisfied + 1
                elseif uid ~= "" and (tonumber(uncertain[uid]) or 0) > now then
                    result.Uncertain = result.Uncertain + 1
                elseif uid ~= "" then
                    candidates[#candidates + 1] = pet
                end
            end
        end
    end
    table.sort(candidates, function(left, right)
        return tostring(left.uid or "") < tostring(right.uid or "")
    end)
    result.Candidate = candidates[1]
    return result
end

local function statusText(stats, targets, tail)
    return string.format(
        "targets: %s | equipped: %d | eligible: %d | satisfied: %d | locked: %d | awaiting late save: %d\n%s",
        #targets > 0 and table.concat(targets, ", ") or "none",
        stats.Equipped, stats.Eligible, stats.Satisfied, stats.Locked,
        stats.Uncertain, tostring(tail or "")
    )
end

local function release(state)
    if state.OperationOwned then
        state.OperationOwned = false
        pcall(state.Context.ReleaseOperation, state.Context.OperationOwner)
    end
end

local function clearPending(state)
    state.PendingUID = nil
    state.PendingSignature = nil
    state.PendingAt = 0
    release(state)
end

local function checkPending(state, context, targets, labels, now)
    if not state.PendingUID then return false end
    local snapshot = context.GetPetSnapshot(true)
    local pet = snapshot and snapshot.ByUID and snapshot.ByUID[state.PendingUID]
    local changed = type(pet) ~= "table"
        or pet.e ~= true
        or powerSignature(context, pet) ~= state.PendingSignature
    if changed then
        local uid = state.PendingUID
        local matched, title = matchingPower(context, pet, targets)
        clearPending(state)
        context.InvalidatePetSnapshot()
        state.Completed = state.Completed + 1
        context.SetStatus(statusText(
            inspectPets(context, snapshot, targets, state.Uncertain, now),
            labels,
            matched and ("confirmed " .. shortUID(uid) .. " -> " .. tostring(title))
                or ("confirmed reroll for " .. shortUID(uid) .. "; continuing")
        ))
        state.NextCheck = now + CHECK_DELAY
        return true
    end
    if now - state.PendingAt >= CONFIRM_TIMEOUT then
        local uid = state.PendingUID
        state.Uncertain[uid] = now + UNCERTAIN_DELAY
        clearPending(state)
        context.SetStatus(statusText(
            inspectPets(context, snapshot, targets, state.Uncertain, now),
            labels,
            "server accepted " .. shortUID(uid)
                .. ", but Save.Pets did not change in time; blind retry is suppressed"
        ))
        state.NextCheck = now + CHECK_DELAY
        return true
    end
    state.NextCheck = now + 0.1
    return true
end

local function runCheck(state, context)
    if state.Busy then return end
    state.Busy = true
    local now = os.clock()
    local targets, labels = selectedSet(context.Targets())

    for uid, expiresAt in pairs(state.Uncertain) do
        if expiresAt <= now then state.Uncertain[uid] = nil end
    end

    if next(targets) == nil then
        clearPending(state)
        context.SetStatus("Select at least one enchant. No Enchant Pet request is being sent.")
        state.NextCheck = now + IDLE_DELAY
        state.Busy = false
        return
    end
    if checkPending(state, context, targets, labels, now) then
        state.Busy = false
        return
    end

    local snapshot = context.GetPetSnapshot(false)
    local stats = inspectPets(context, snapshot, targets, state.Uncertain, now)
    local candidate = stats.Candidate
    if not candidate then
        local tail = stats.Eligible > 0 and stats.Satisfied == stats.Eligible
            and "all eligible equipped pets match an accepted enchant"
            or "waiting for an eligible equipped pet"
        context.SetStatus(statusText(stats, labels, tail))
        state.NextCheck = now + IDLE_DELAY
        state.Busy = false
        return
    end

    local acquired, owner = context.AcquireOperation(context.OperationOwner)
    if not acquired then
        context.SetStatus(statusText(stats, labels,
            "inventory mutation lane is owned by " .. tostring(owner)))
        state.NextCheck = now + 0.25
        state.Busy = false
        return
    end
    state.OperationOwned = true

    local fresh = context.GetPetSnapshot(true)
    local pet = fresh and fresh.ByUID and fresh.ByUID[tostring(candidate.uid)]
    local freshStats = inspectPets(context, fresh, targets, state.Uncertain, now)
    if type(pet) ~= "table" or pet.e ~= true or matchingPower(context, pet, targets)
        or pet.l == true or pet.locked == true then
        release(state)
        context.SetStatus(statusText(freshStats, labels,
            "fresh safety check changed the candidate; no request sent"))
        state.NextCheck = now + CHECK_DELAY
        state.Busy = false
        return
    end

    local uid = tostring(pet.uid)
    local before = powerSignature(context, pet)
    context.Trace("enchant dispatch", shortUID(uid) .. " | before=" .. (before ~= "" and before or "none"))
    local transportOk, accepted, serverMessage, sourceName, sessionIndex =
        context.InvokeCommand("Enchant Pet", uid)
    if not transportOk then
        release(state)
        context.InvalidateCommand("Enchant Pet")
        context.SetStatus(statusText(freshStats, labels,
            "transport error; no success assumed: " .. tostring(serverMessage)))
        state.NextCheck = now + REJECT_DELAY
    elseif not accepted then
        release(state)
        context.SetStatus(statusText(freshStats, labels,
            "server rejected via " .. context.RouteText(sourceName, sessionIndex)
                .. ": " .. tostring(serverMessage or "request rejected")))
        state.NextCheck = now + REJECT_DELAY
    else
        state.PendingUID = uid
        state.PendingSignature = before
        state.PendingAt = now
        context.InvalidatePetSnapshot()
        context.SetStatus(statusText(freshStats, labels,
            "accepted via " .. context.RouteText(sourceName, sessionIndex)
                .. "; waiting for authoritative powers change on " .. shortUID(uid)))
        state.NextCheck = now + 0.1
    end
    state.Busy = false
end

local function stop()
    if activeState then
        local state = activeState
        state.Running = false
        state.Busy = false
        clearPending(state)
        pcall(state.Context.CancelOperation, state.Context.OperationOwner)
        activeState = nil
    end
    return true
end

return function(action, context)
    if action == "version" then return MODULE_VERSION end
    if action == "evaluate" then
        if type(context) ~= "table" then return false, nil end
        local targets = selectedSet(context.Targets or {})
        return matchingPower(context, context.Pet, targets)
    end
    if action == "stop" then return stop() end
    if action ~= "start" then return false, "unknown action" end
    if activeState and activeState.Running then return true end
    if type(context) ~= "table" then return false, "module context is missing" end
    for _, key in ipairs({
        "Library", "Running", "Enabled", "Targets", "GetPetSnapshot",
        "InvalidatePetSnapshot", "InvalidateCommand", "InvokeCommand", "RouteText",
        "AcquireOperation", "ReleaseOperation", "CancelOperation", "OperationOwner",
        "SetStatus", "Trace",
    }) do
        if context[key] == nil then return false, "module context is missing " .. key end
    end

    local state = {
        Context = context,
        Running = true,
        Busy = false,
        OperationOwned = false,
        PendingUID = nil,
        PendingSignature = nil,
        PendingAt = 0,
        Uncertain = {},
        Completed = 0,
        NextCheck = 0,
    }
    activeState = state
    context.Trace("enchant module", "v" .. MODULE_VERSION
        .. " | equipped pets only | one request in flight | Save.Pets confirmation")
    task.spawn(function()
        while state.Running and activeState == state and context.Running() and context.Enabled() do
            if not state.Busy and os.clock() >= state.NextCheck then
                local ok, problem = pcall(runCheck, state, context)
                if not ok then
                    state.Busy = false
                    clearPending(state)
                    state.NextCheck = os.clock() + REJECT_DELAY
                    context.Trace("enchant worker", "recovered: " .. tostring(problem))
                    context.SetStatus("Enchant worker recovered from a local error: "
                        .. tostring(problem) .. "\nNo success was assumed; retry in 5 seconds.")
                end
            end
            if state.Running and activeState == state then
                local remaining = state.NextCheck - os.clock()
                task.wait(math.clamp(remaining > 0 and remaining or 0.05, 0.05, IDLE_DELAY))
            end
        end
        clearPending(state)
        if activeState == state then activeState = nil end
    end)
    return true
end
