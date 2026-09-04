-- Serialized equipped-pet enchant worker for PSX OG Nova develop.
-- One UID remains selected until any requested enchant is confirmed in Save.Pets.

local MODULE_VERSION = "1.1.0"
local activeState

local CONFIRM_POLL = 0.04
local CONFIRM_TIMEOUT = 8
local GATE_RETRY = 0.10
local REJECT_RETRY = 1.00
local IDLE_RECHECK = 1.00
local MAX_TRANSPORT_BACKOFF = 3.00
local SUCCESS_MIN_DELAY = 0.20
local SUCCESS_MAX_DELAY = 0.90
local SUCCESS_RTT_FACTOR = 0.75
local FARM_QUEUE_DELAY = 0.35
local HIGH_PING_MS = 350
local HIGH_PING_DELAY = 0.50

local ROMAN_LEVELS = { I = 1, II = 2, III = 3, IV = 4, V = 5 }
local LEVEL_ROMANS = { "I", "II", "III", "IV", "V" }

local function trim(value)
    return string.match(tostring(value or ""), "^%s*(.-)%s*$") or ""
end

local function normalize(value)
    return string.lower(trim(value)):gsub("%s+", " ")
end

local function readPower(power, key)
    local name, rawLevel
    if type(power) == "table" then
        name = power[1] or power.name or power.Name or power.power or power.Power
        rawLevel = power[2] or power.level or power.Level or power.tier or power.Tier
    elseif type(key) == "string" and (type(power) == "number" or type(power) == "string") then
        name, rawLevel = key, power
    elseif type(power) == "string" then
        local text = trim(power)
        local base, suffix = string.match(text, "^(.-)%s+([IVX]+)$")
        if not base then base, suffix = string.match(text, "^(.-)%s+(%d+)$") end
        name, rawLevel = base or text, suffix
    end
    if name == nil then return nil, nil end
    local level = tonumber(rawLevel)
    if level == nil and rawLevel ~= nil then
        level = ROMAN_LEVELS[string.upper(tostring(rawLevel))]
    end
    return tostring(name), level
end

local function powerDirectory(library, name)
    local powers = library and library.Directory and library.Directory.Powers
    if type(powers) ~= "table" then return nil end
    return powers[name] or powers[tostring(name)]
end

local function fallbackPowerTitle(name, level)
    if name == "Chests" or name == "Chest" then name = "Chest Breaker" end
    if name == "Presents" then name = "Gifts" end
    if name == "Teamwork" then
        if tonumber(level) == 2 then return "Super Teamwork" end
        return "Teamwork"
    end
    local roman = level and LEVEL_ROMANS[tonumber(level)] or nil
    return roman and (tostring(name) .. " " .. roman) or tostring(name)
end

local function powerTitle(library, name, level)
    if name == nil then return nil end
    local definition = powerDirectory(library, name)
    local tiers = type(definition) == "table" and (definition.tiers or definition.Tiers) or nil
    local tier = type(tiers) == "table" and level ~= nil and tiers[tonumber(level)] or nil
    local title = type(tier) == "table" and (tier.title or tier.Title or tier.name or tier.Name) or nil
    return trim(title ~= nil and title or fallbackPowerTitle(name, level))
end

local function eachPower(pet, callback)
    local powers = type(pet) == "table" and (pet.powers or pet.Powers) or nil
    if type(powers) ~= "table" then return end
    if powers.name or powers.Name or powers.power or powers.Power then
        callback(readPower(powers))
        return
    end
    for key, power in pairs(powers) do callback(readPower(power, key)) end
end

local function targetSet(values)
    local result, ordered = {}, {}
    if type(values) == "table" then
        for key, value in pairs(values) do
            local raw = type(key) == "string" and value == true and key or value
            local title = trim(raw)
            local normalized = normalize(title)
            if normalized ~= "" and not result[normalized] then
                result[normalized] = title
                ordered[#ordered + 1] = title
            end
        end
    elseif values ~= nil then
        local title = trim(values)
        if title ~= "" then
            result[normalize(title)] = title
            ordered[1] = title
        end
    end
    table.sort(ordered)
    return result, ordered
end

local function matchingEnchant(library, pet, targets)
    local matched
    eachPower(pet, function(name, level)
        if matched or name == nil then return end
        local title = powerTitle(library, name, level)
        if title and targets[normalize(title)] then matched = title end
    end)
    return matched
end

local function powerSignature(pet)
    local entries = {}
    eachPower(pet, function(name, level)
        if name ~= nil then
            entries[#entries + 1] = normalize(name) .. ":" .. tostring(level or "?")
        end
    end)
    table.sort(entries)
    return table.concat(entries, "|")
end

local function petDefinition(library, pet)
    local pets = library and library.Directory and library.Directory.Pets
    if type(pets) ~= "table" or type(pet) ~= "table" then return nil end
    return pets[pet.id] or pets[tostring(pet.id)] or pets[tonumber(pet.id)]
end

local function petName(library, pet)
    local definition = petDefinition(library, pet)
    return tostring(type(definition) == "table"
        and (definition.name or definition.Name or definition.displayName or definition.DisplayName)
        or (type(pet) == "table" and pet.id) or "Pet")
end

local function eligiblePet(library, pet, isEquipped)
    if type(pet) ~= "table" then return false, "invalid pet" end
    if isEquipped ~= true then return false, "not equipped" end
    if pet.uid == nil then return false, "missing UID" end
    local definition = petDefinition(library, pet)
    if type(definition) ~= "table" then return false, "directory definition unavailable" end
    local rarity = string.lower(tostring(definition.rarity or definition.Rarity or ""))
    if definition.isPremium == true or definition.IsPremium == true
        or rarity == "exclusive" then
        return false, "premium/exclusive pet"
    end
    return true
end

local function getSave(context)
    local save
    if context.Library and context.Library.Save and type(context.Library.Save.Get) == "function" then
        pcall(function() save = context.Library.Save.Get() end)
    end
    return type(save) == "table" and save or nil
end

local function authoritativeEquipped(context, save)
    local ok, equipped, ready, problem = pcall(context.GetEquippedPetSet, save)
    if not ok then return nil, "equipped map error: " .. tostring(equipped) end
    if ready ~= true or type(equipped) ~= "table" then
        return nil, tostring(problem or "authoritative equipped map is unavailable")
    end
    return equipped, nil
end

local function findPet(save, uid)
    uid = tostring(uid or "")
    for _, pet in pairs(type(save and save.Pets) == "table" and save.Pets or {}) do
        if type(pet) == "table" and tostring(pet.uid or "") == uid then return pet end
    end
    return nil
end

local function shortUID(uid)
    uid = tostring(uid or "?")
    if #uid <= 14 then return uid end
    return string.sub(uid, 1, 8) .. ".." .. string.sub(uid, -4)
end

local function stateActive(state)
    return activeState == state and state.Running == true
        and state.Context.Running() and state.Context.Enabled()
end

local function releaseOperation(state)
    if not state.OperationOwned then return end
    state.OperationOwned = false
    pcall(state.Context.ReleaseOperation, state.Context.OperationOwner)
end

local runStep

local function schedule(state, delay)
    if not stateActive(state) then return end
    state.ScheduleSerial = state.ScheduleSerial + 1
    local serial = state.ScheduleSerial
    local workerTask = state.Context.Task or task
    workerTask.delay(math.max(0, tonumber(delay) or 0), function()
        if not stateActive(state) or state.ScheduleSerial ~= serial then return end
        local ok, problem = pcall(runStep, state)
        if not ok and stateActive(state) then
            releaseOperation(state)
            state.Context.Trace("auto enchant", "worker error: " .. tostring(problem))
            state.Context.SetStatus("Worker recovered from an error; no overlapping request was sent: "
                .. tostring(problem))
            schedule(state, 1)
        end
    end)
end

local function setCurrent(state, pet)
    state.CurrentUID = tostring(pet.uid)
    state.CurrentName = petName(state.Context.Library, pet)
    state.CurrentSignature = powerSignature(pet)
    state.AttemptsOnCurrent = 0
end

local function clearCurrent(state)
    state.CurrentUID = nil
    state.CurrentName = nil
    state.CurrentSignature = nil
    state.AttemptsOnCurrent = 0
    state.Awaiting = nil
end

local function successfulRollDelay(state)
    local delay = SUCCESS_MIN_DELAY
    local reader = state.Context.GetNetworkPressure
    if type(reader) ~= "function" then
        state.LastPacingDelay = delay
        return delay
    end

    local ok, pingMs, farmRTT, farmActive, farmQueued = pcall(reader)
    if not ok then
        state.LastPacingDelay = delay
        return delay
    end

    pingMs = math.max(0, tonumber(pingMs) or 0)
    farmRTT = math.max(0, tonumber(farmRTT) or 0)
    farmActive = math.max(0, tonumber(farmActive) or 0)
    farmQueued = math.max(0, tonumber(farmQueued) or 0)

    local observedRTT = math.max(pingMs / 1000, farmRTT)
    if observedRTT > 0 then
        delay = math.max(delay, math.min(SUCCESS_MAX_DELAY, observedRTT * SUCCESS_RTT_FACTOR))
    end
    if farmQueued > 0 then
        delay = math.max(delay, FARM_QUEUE_DELAY)
    end
    if farmActive > 0 and pingMs >= HIGH_PING_MS then
        delay = math.max(delay, math.min(SUCCESS_MAX_DELAY, math.max(HIGH_PING_DELAY, pingMs / 1000)))
    end

    state.LastPacingDelay = delay
    state.LastPingMs = pingMs
    return delay
end

local function selectNext(state, save, equippedSet)
    local candidates = {}
    local equipped, alreadyReady, blocked = 0, 0, 0
    for _, pet in pairs(type(save and save.Pets) == "table" and save.Pets or {}) do
        local uid = type(pet) == "table" and pet.uid ~= nil and tostring(pet.uid) or nil
        if uid and equippedSet[uid] == true then
            equipped = equipped + 1
            local allowed = eligiblePet(state.Context.Library, pet, true)
            if allowed then
                if matchingEnchant(state.Context.Library, pet, state.Targets) then
                    alreadyReady = alreadyReady + 1
                else
                    candidates[#candidates + 1] = pet
                end
            else
                blocked = blocked + 1
            end
        end
    end
    table.sort(candidates, function(left, right)
        return tostring(left.uid) < tostring(right.uid)
    end)
    if candidates[1] then
        setCurrent(state, candidates[1])
        state.Context.SetStatus(string.format(
            "Locked %s [%s] until it rolls any selected enchant.\nEquipped: %d | already matched: %d | blocked: %d | remaining: %d",
            state.CurrentName, shortUID(state.CurrentUID), equipped, alreadyReady, blocked, #candidates
        ))
        return true
    end
    state.Context.SetStatus(string.format(
        "Complete: every eligible equipped pet has one selected enchant.\nEquipped: %d | matched: %d | blocked: %d | total rolls: %d",
        equipped, alreadyReady, blocked, state.TotalRolls
    ))
    return false
end

local function confirmRoll(state, save, pet)
    local awaiting = state.Awaiting
    if not awaiting then return false end
    local signature = powerSignature(pet)
    if signature ~= awaiting.Signature then
        state.Awaiting = nil
        state.CurrentSignature = signature
        state.TransportFailures = 0
        local matched = matchingEnchant(state.Context.Library, pet, state.Targets)
        if matched then
            state.CompletedPets = state.CompletedPets + 1
            state.Context.SetStatus(string.format(
                "%s [%s] completed with %s after %d roll(s). Moving immediately to the next equipped pet.\nCompleted pets: %d | total rolls: %d",
                state.CurrentName, shortUID(state.CurrentUID), matched,
                state.AttemptsOnCurrent, state.CompletedPets, state.TotalRolls
            ))
            clearCurrent(state)
        end
        schedule(state, successfulRollDelay(state))
        return true
    end
    if os.clock() >= awaiting.Deadline then
        state.Awaiting = nil
        state.Context.SetStatus(string.format(
            "Server accepted roll %d for %s [%s], but Save.Pets did not change within %ds.\nHolding the same UID; one guarded retry follows after a final local recheck.",
            state.AttemptsOnCurrent, state.CurrentName, shortUID(state.CurrentUID), CONFIRM_TIMEOUT
        ))
        schedule(state, 0.5)
        return true
    end
    schedule(state, CONFIRM_POLL)
    return true
end

local function requestRoll(state, pet)
    local acquired, owner = state.Context.AcquireOperation(state.Context.OperationOwner)
    if acquired ~= true then
        state.Context.SetStatus("Holding " .. tostring(state.CurrentName) .. " ["
            .. shortUID(state.CurrentUID) .. "]; inventory lane is currently used by "
            .. tostring(owner or "another worker") .. ".")
        schedule(state, GATE_RETRY)
        return
    end
    state.OperationOwned = true

    local save = getSave(state.Context)
    local equippedSet, equippedProblem = authoritativeEquipped(state.Context, save)
    if not equippedSet then
        releaseOperation(state)
        state.Context.SetStatus("Authoritative equipped map is unavailable; no enchant request was sent: "
            .. tostring(equippedProblem))
        schedule(state, 0.5)
        return
    end
    local exact = findPet(save, state.CurrentUID)
    local allowed = exact and eligiblePet(state.Context.Library, exact,
        equippedSet[state.CurrentUID] == true)
    local matched = exact and matchingEnchant(state.Context.Library, exact, state.Targets)
    if not exact or not allowed or matched then
        releaseOperation(state)
        if matched then state.CompletedPets = state.CompletedPets + 1 end
        clearCurrent(state)
        schedule(state, 0)
        return
    end

    local before = powerSignature(exact)
    local result = table.pack(pcall(state.Context.InvokeCommand, "Enchant Pet", state.CurrentUID))
    releaseOperation(state)
    if not stateActive(state) then return end

    local transportOk = result[1] and result[2] == true
    local accepted = transportOk and result[3] == true
    local serverMessage = result[1] and result[4] or result[2]
    local sourceName = result[5]
    local sessionIndex = result[6]
    if not transportOk then
        state.TransportFailures = state.TransportFailures + 1
        local delay = math.min(MAX_TRANSPORT_BACKOFF, 0.15 * (2 ^ (state.TransportFailures - 1)))
        state.Context.SetStatus(string.format(
            "Transport error while rolling %s [%s]: %s\nSame UID retained; bounded retry in %.2fs (%d consecutive transport failure(s)).",
            state.CurrentName, shortUID(state.CurrentUID), tostring(serverMessage), delay,
            state.TransportFailures
        ))
        schedule(state, delay)
        return
    end
    if not accepted then
        state.TransportFailures = 0
        state.Context.SetStatus("Enchant Pet reached the server via "
            .. state.Context.RouteText(sourceName, sessionIndex) .. " but was rejected: "
            .. tostring(serverMessage or "request rejected")
            .. "\nSame UID retained; no parallel request will be created.")
        schedule(state, REJECT_RETRY)
        return
    end

    state.TransportFailures = 0
    state.AttemptsOnCurrent = state.AttemptsOnCurrent + 1
    state.TotalRolls = state.TotalRolls + 1
    state.Awaiting = { Signature = before, Deadline = os.clock() + CONFIRM_TIMEOUT }
    state.Context.Trace("auto enchant roll", state.CurrentName .. " " .. shortUID(state.CurrentUID)
        .. " | attempt=" .. tostring(state.AttemptsOnCurrent)
        .. " | route=" .. state.Context.RouteText(sourceName, sessionIndex))
    schedule(state, CONFIRM_POLL)
end

runStep = function(state)
    if not stateActive(state) then return end
    local save = getSave(state.Context)
    if not save then
        state.Context.SetStatus("Player save is unavailable; no enchant request was sent.")
        schedule(state, 0.5)
        return
    end
    local equippedSet, equippedProblem = authoritativeEquipped(state.Context, save)
    if not equippedSet then
        state.Context.SetStatus("Authoritative equipped map is unavailable; no enchant request was sent: "
            .. tostring(equippedProblem))
        schedule(state, 0.5)
        return
    end
    if next(state.Targets) == nil then
        state.Context.SetStatus("Select at least one target enchant. No request is being sent.")
        schedule(state, IDLE_RECHECK)
        return
    end
    if not state.CurrentUID then
        if not selectNext(state, save, equippedSet) then schedule(state, IDLE_RECHECK) return end
    end

    local pet = findPet(save, state.CurrentUID)
    local allowed = pet and eligiblePet(state.Context.Library, pet,
        equippedSet[state.CurrentUID] == true)
    if not pet or not allowed then
        clearCurrent(state)
        schedule(state, 0)
        return
    end
    if matchingEnchant(state.Context.Library, pet, state.Targets) then
        state.CompletedPets = state.CompletedPets + 1
        clearCurrent(state)
        schedule(state, 0)
        return
    end
    if confirmRoll(state, save, pet) then return end
    requestRoll(state, pet)
end

local function stop()
    if activeState then
        local state = activeState
        state.Running = false
        state.ScheduleSerial = state.ScheduleSerial + 1
        releaseOperation(state)
        pcall(state.Context.CancelOperation, state.Context.OperationOwner)
        activeState = nil
    end
    return true
end

local function start(context)
    if activeState and activeState.Running then return true end
    if type(context) ~= "table" then return false, "module context is missing" end
    for _, key in ipairs({
        "Library", "Running", "Enabled", "GetTargets", "InvokeCommand", "RouteText",
        "AcquireOperation", "ReleaseOperation", "CancelOperation", "OperationOwner",
        "SetStatus", "Trace", "GetEquippedPetSet",
    }) do
        if context[key] == nil then return false, "module context is missing " .. key end
    end
    local targets, ordered = targetSet(context.GetTargets())
    local state = {
        Context = context,
        Running = true,
        ScheduleSerial = 0,
        OperationOwned = false,
        Targets = targets,
        TargetTitles = ordered,
        TotalRolls = 0,
        CompletedPets = 0,
        TransportFailures = 0,
    }
    activeState = state
    context.Trace("auto enchant module", "serialized worker started | targets="
        .. (#ordered > 0 and table.concat(ordered, ", ") or "none"))
    schedule(state, 0)
    return true
end

return function(action, context)
    if action == "version" then return MODULE_VERSION end
    if action == "stop" then return stop() end
    if action == "start" then return start(context) end
    if action == "power-title" then
        return powerTitle(context and context.Library, context and context.Name, context and context.Level)
    end
    if action == "matches" then
        local targets = targetSet(context and context.Targets)
        return matchingEnchant(context and context.Library, context and context.Pet, targets)
    end
    if action == "eligible" then
        return eligiblePet(context and context.Library, context and context.Pet,
            context and context.Equipped == true)
    end
    return false, "unknown action"
end
