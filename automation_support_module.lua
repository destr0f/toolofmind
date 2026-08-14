-- Shared low-frequency coordinator for PSX OG Nova develop.
-- Nothing in this module invokes the server. Route checks only resolve named remotes locally.

local MODULE_VERSION = "1.5.0"

local gate = {
    Owner = nil,
    OwnerSince = 0,
    OwnerGeneration = 0,
    LastAcquireReason = "none",
    LastAcquireAt = 0,
    LastReleaseReason = "none",
    LastReleaseAt = 0,
    LastOwnerExpiry = "none",
    LastOwnerExpiryAt = 0,
}

local catalogCache = {
    ExpiresAt = 0,
    Ids = {},
    Names = {},
    Summary = "not scanned",
}

local ROMAN_LEVELS = { I = 1, II = 2, III = 3, IV = 4, V = 5 }
local matcherCache = { Values = {}, Order = {}, Limit = 2048 }

local function normalizeEnchant(value)
    value = string.lower(tostring(value or ""))
    value = string.gsub(value, "[_%-]+", " ")
    value = string.gsub(value, "%s+", " ")
    return string.match(value, "^%s*(.-)%s*$") or value
end

local function readEnchant(power, key)
    local name, rawLevel
    if type(power) == "table" then
        name = power[1] or power.name or power.Name or power.power or power.Power
        rawLevel = power[2] or power.level or power.Level or power.tier or power.Tier
    elseif type(key) == "string" and (type(power) == "number" or type(power) == "string") then
        name, rawLevel = key, power
    elseif type(power) == "string" then
        local text = string.match(power, "^%s*(.-)%s*$") or power
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

local function petEnchantMap(pet)
    if type(pet) ~= "table" then return nil, "pet unavailable" end
    local powers = pet.powers or pet.Powers
    if type(powers) ~= "table" then return nil, "powers unavailable" end
    local result, signature = {}, {}
    local function add(power, key)
        local name, level = readEnchant(power, key)
        local normalized = normalizeEnchant(name)
        if normalized == "" then return end
        local previous = result[normalized]
        if previous == nil or (level ~= nil and (previous.Level == nil or level > previous.Level)) then
            result[normalized] = { Name = tostring(name), Level = level }
        end
    end
    if powers.name or powers.Name or powers.power or powers.Power then add(powers) end
    for key, power in pairs(powers) do add(power, key) end
    for name, entry in pairs(result) do
        signature[#signature + 1] = name .. ":" .. tostring(entry.Level or "any")
    end
    table.sort(signature)
    return result, table.concat(signature, "|")
end

local function normalizedCondition(condition)
    if type(condition) ~= "table" then return nil end
    local enchant = tostring(condition.Enchant or condition.Name or "")
    if normalizeEnchant(enchant) == "" then return nil end
    local mode = tostring(condition.Mode or "Any")
    if mode ~= "Any" and mode ~= "Exact" and mode ~= "IV/V" and mode ~= "AtLeast" then
        mode = "Any"
    end
    return { Enchant = enchant, Mode = mode, Level = tonumber(condition.Level) }
end

local function normalizeProfile(profile)
    if type(profile) ~= "table" or type(profile.Rules) ~= "table" then
        return nil, "profile unavailable"
    end
    if profile.Enabled == false then return false, "profile disabled" end
    local result = { Revision = tonumber(profile.Revision) or 0, Rules = {} }
    for _, rule in ipairs(profile.Rules) do
        if type(rule) == "table" and rule.Enabled ~= false then
            local normalizedRule = { Enabled = true, Conditions = {} }
            if type(rule.Conditions) ~= "table" then
                return nil, "rule conditions unavailable"
            end
            for _, condition in ipairs(rule.Conditions) do
                local normalized = normalizedCondition(condition)
                if not normalized then return nil, "rule contains an incomplete condition" end
                normalizedRule.Conditions[#normalizedRule.Conditions + 1] = normalized
            end
            if #normalizedRule.Conditions == 0 then return nil, "rule has no conditions" end
            result.Rules[#result.Rules + 1] = normalizedRule
        end
    end
    if #result.Rules == 0 then return false, "profile has no enabled rules" end
    return result
end

local function conditionMatches(condition, powers)
    local normalizedName = normalizeEnchant(condition.Enchant)
    local found
    if normalizedName == "teamwork or super teamwork"
        or normalizedName == "teamwork/super teamwork"
        or normalizedName == "teamwork or stw" then
        found = powers["super teamwork"] or powers["teamwork"]
    else
        found = powers[normalizedName]
    end
    if not found then return false end
    local mode = condition.Mode
    if mode == "Any" then return true end
    local level = tonumber(found.Level)
    if level == nil then return false end
    if mode == "IV/V" then return level == 4 or level == 5 end
    local expected = tonumber(condition.Level)
    if expected == nil then return false end
    if mode == "Exact" then return level == expected end
    return level >= expected
end

local function profileFormula(profile)
    if type(profile) == "table" and profile.Enabled == false then
        return "PROFILE DISABLED (no enchant protection)"
    end
    local normalizedProfile, problem = normalizeProfile(profile)
    if normalizedProfile == false then return "NO RULES (no enchant protection)" end
    if not normalizedProfile then return "DEFER (" .. tostring(problem) .. ")" end
    local rules = {}
    for _, rule in ipairs(normalizedProfile.Rules) do
        local conditions = {}
        for _, condition in ipairs(rule.Conditions) do
            local suffix = condition.Mode == "Any" and ""
                or condition.Mode == "IV/V" and " IV/V"
                or (" " .. condition.Mode .. " " .. tostring(condition.Level or "?"))
            conditions[#conditions + 1] = "Has(" .. condition.Enchant .. suffix .. ")"
        end
        rules[#rules + 1] = #conditions > 1 and ("(" .. table.concat(conditions, " AND ") .. ")")
            or conditions[1]
    end
    local formula = table.concat(rules, " OR ")
    return type(profile) == "table" and profile.DryRun == true
        and ("DRY RUN: " .. formula) or formula
end

local function cacheStore(key, value)
    if matcherCache.Values[key] == nil then
        matcherCache.Order[#matcherCache.Order + 1] = key
        if #matcherCache.Order > matcherCache.Limit then
            local expired = table.remove(matcherCache.Order, 1)
            matcherCache.Values[expired] = nil
        end
    end
    matcherCache.Values[key] = value
end

local function matchProfile(profile, pet)
    local normalizedProfile, profileProblem = normalizeProfile(profile)
    if normalizedProfile == false then return "EMPTY", profileProblem end
    if not normalizedProfile then return "DEFER", profileProblem end
    local powers, signature = petEnchantMap(pet)
    if not powers then return "DEFER", signature end
    local uid = tostring(pet.uid or pet.UID or "anonymous")
    local form = type(pet) == "table" and (pet.dm and "dm" or pet.r and "rainbow" or pet.g and "gold" or "normal")
        or "unknown"
    local cacheKey = tostring(profile) .. "@" .. uid .. "@" .. form .. "@" .. tostring(pet.e == true)
        .. "@" .. tostring(pet.l == true or pet.locked == true)
        .. "@" .. tostring(normalizedProfile.Revision) .. "@" .. signature
    local cached = matcherCache.Values[cacheKey]
    if cached then return cached[1], cached[2] end
    for index, rule in ipairs(normalizedProfile.Rules) do
        local matched = true
        for _, condition in ipairs(rule.Conditions) do
            if not conditionMatches(condition, powers) then matched = false; break end
        end
        if matched then
            local value = { "MATCH", "rule " .. tostring(index) }
            cacheStore(cacheKey, value)
            return value[1], value[2]
        end
    end
    local value = { "NO_MATCH", "no protection rule matched" }
    cacheStore(cacheKey, value)
    return value[1], value[2]
end

local function enchantCatalog(context)
    local values, seen = {}, {}
    local powers = type(context) == "table" and context.Library
        and context.Library.Directory and context.Library.Directory.Powers or nil
    if type(powers) == "table" then
        for rawName, definition in pairs(powers) do
            local name = type(definition) == "table"
                and (definition.name or definition.Name or definition.title or definition.Title) or rawName
            name = tostring(name or rawName or "")
            local key = normalizeEnchant(name)
            if key ~= "" and not seen[key] then seen[key] = true; values[#values + 1] = name end
        end
    end
    for _, name in ipairs({
        "Agility", "Chest Breaker", "Charm", "Coins", "Diamonds", "Glittering",
        "Rainbow Coins", "Royalty", "Strength", "Teamwork", "Super Teamwork",
        "Teamwork or Super Teamwork",
    }) do
        local key = normalizeEnchant(name)
        if not seen[key] then seen[key] = true; values[#values + 1] = name end
    end
    table.sort(values)
    return values
end

local MACHINE_PET_NAMES = {
    ["pixel demon"] = "Pixel Demon",
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
end

local function explicitMachinePet(definition, rawId)
    local name = definitionName(definition)
    return name ~= nil and MACHINE_PET_NAMES[normalize(name)] ~= nil
end

local function trace(context, stage, detail)
    if type(context) == "table" and type(context.Trace) == "function" then
        pcall(context.Trace, stage, detail)
    end
end

local function cleanGate(context, now)
    now = now or os.clock()
    if gate.Owner and now - gate.OwnerSince > 45 then
        trace(context, "operation gate", "expired stale owner " .. tostring(gate.Owner))
        gate.LastOwnerExpiry = tostring(gate.Owner)
        gate.LastOwnerExpiryAt = now
        gate.Owner = nil
        gate.OwnerSince = 0
        gate.OwnerGeneration = 0
    end
end

local function acquire(context, rawOwner)
    local owner = tostring(rawOwner or "unknown")
    local now = os.clock()
    cleanGate(context, now)
    if gate.Owner == owner then return true, owner end

    if gate.Owner then return false, gate.Owner end
    gate.Owner = owner
    gate.OwnerSince = now
    gate.OwnerGeneration = tonumber(type(context) == "table" and context.Generation or nil) or 0
    gate.LastAcquireReason = "coalesced mutex acquired"
    gate.LastAcquireAt = now
    return true, owner
end

local function release(context, rawOwner, reason)
    local owner = tostring(rawOwner or "unknown")
    if gate.Owner == owner then
        gate.Owner = nil
        gate.OwnerSince = 0
        gate.OwnerGeneration = 0
        gate.LastReleaseReason = tostring(reason or "owner released")
        gate.LastReleaseAt = os.clock()
    end
    return true
end

local function gateStatus(context)
    cleanGate(context)
    return gate.Owner or "idle", 0
end

local function gateDiagnostics(context)
    local now = os.clock()
    cleanGate(context, now)
    return {
        Owner = gate.Owner or "idle",
        OwnerAge = gate.Owner and math.max(now - gate.OwnerSince, 0) or 0,
        OwnerGeneration = gate.OwnerGeneration,
        Waiters = 0,
        OldestWaiterAge = 0,
        WaiterAges = "",
        OwnerExpirySeconds = 45,
        WaiterExpirySeconds = 2,
        LastAcquireReason = gate.LastAcquireReason,
        LastAcquireAge = gate.LastAcquireAt > 0 and math.max(now - gate.LastAcquireAt, 0) or 0,
        LastReleaseReason = gate.LastReleaseReason,
        LastReleaseAge = gate.LastReleaseAt > 0 and math.max(now - gate.LastReleaseAt, 0) or 0,
        LastOwnerExpiry = gate.LastOwnerExpiry,
        LastOwnerExpiryAge = gate.LastOwnerExpiryAt > 0 and math.max(now - gate.LastOwnerExpiryAt, 0) or 0,
        LastWaiterExpiryCount = 0,
        LastWaiterExpiryAge = 0,
    }
end

local function definitionAllowed(definition, rawId)
    -- Machine pets are resolved by their exact live Directory.Pets name.
    -- No guessed or session-specific numeric ID is ever accepted.
    return explicitMachinePet(definition, rawId)
end

local function getCatalog(context, force)
    local now = os.clock()
    if not force and now < catalogCache.ExpiresAt then
        return catalogCache.Ids, catalogCache.Names, catalogCache.Summary
    end

    local library = type(context) == "table" and context.Library or nil
    local directory = library and library.Directory or {}
    local pets = type(directory.Pets) == "table" and directory.Pets or {}
    local eggs = type(directory.Eggs) == "table" and directory.Eggs or {}
    local ids, eventEggs = {}, {}

    local function petDefinition(rawId)
        if rawId == nil then return nil end
        return pets[rawId] or pets[tostring(rawId)] or pets[tonumber(rawId)]
    end

    local function addPet(rawId)
        if rawId == nil then return end
        local id = tostring(rawId)
        local definition = petDefinition(rawId)
        if definitionAllowed(definition, rawId) then ids[id] = true end
    end

    local function addEggDrops(rawEgg, visiting)
        local eggId = tostring(rawEgg or "")
        if eggId == "" then return end
        visiting = visiting or {}
        if visiting[eggId] then return end
        visiting[eggId] = true
        local entry = eggs[eggId]
        local drops = type(entry) == "table" and entry.drops or nil
        if type(drops) == "string" then
            addEggDrops(drops, visiting)
        elseif type(drops) == "table" then
            for dropKey, drop in pairs(drops) do
                local petId
                if type(drop) == "table" then
                    petId = drop[1] or drop.id or drop.ID or drop.petId or drop.PetId
                elseif petDefinition(drop) then
                    petId = drop
                elseif petDefinition(dropKey) then
                    -- Some Directory.Eggs revisions store drops as [petId] = chance.
                    petId = dropKey
                end
                addPet(petId)
            end
        end
        visiting[eggId] = nil
    end

    for eggId, entry in pairs(eggs) do
        if type(entry) == "table" then
            local marker = normalize(table.concat({
                tostring(eggId), tostring(entry.displayName or ""),
                tostring(entry.currency or ""), tostring(entry.area or ""),
                tostring(entry.event or entry.Event or entry.eventName or entry.EventName or ""),
            }, " "))
            if normalize(entry.currency) == "gingerbread"
                or string.find(marker, "christmas", 1, true)
                or string.find(marker, "holiday", 1, true)
                or string.find(marker, "new year", 1, true)
                or string.find(marker, "newyear", 1, true)
                or string.find(marker, "xmas", 1, true)
                or string.find(marker, "jolly", 1, true)
                or string.find(marker, "many gifts", 1, true) then
                eventEggs[#eventEggs + 1] = tostring(eggId)
                addEggDrops(eggId)
            end
        end
    end

    for id, definition in pairs(pets) do
        if explicitMachinePet(definition, id) then
            addPet(id)
        end
    end

    local names = {}
    for id in pairs(ids) do
        local definition = petDefinition(id)
        names[#names + 1] = tostring(definitionName(definition) or id)
    end
    table.sort(names)
    table.sort(eventEggs)
    local summary = string.format("%d exact Pixel Demon species from %d scanned event egg(s): %s",
        #names, #eventEggs, #names > 0 and table.concat(names, ", ") or "none")
    catalogCache = {
        ExpiresAt = now + 60,
        Ids = ids,
        Names = names,
        Summary = summary,
    }
    return ids, names, summary
end

local function routeState(resolver, command)
    if type(resolver) ~= "function" then return "resolver unavailable" end
    local called, remote, _, sessionIndex, problem = pcall(resolver, command)
    if not called then return "resolver error (" .. tostring(remote) .. ")" end
    return remote and ("ready #" .. tostring(sessionIndex or "?"))
        or ("missing (" .. tostring(problem) .. ")")
end

local function routeHealth(context)
    local invoke = function(command) return routeState(context.GetCommandRemote, command) end
    local fire = function(command) return routeState(context.GetFireRemote, command) end
    local _, _, catalogSummary = getCatalog(context, false)
    local owner, waiting = gateStatus(context)
    return table.concat({
        "Egg: Buy=" .. invoke("Buy Egg Yay") .. " | Open event resolves only when Auto Egg starts",
        "Gold: use=" .. invoke("Use Golden Machine") .. " | info=" .. invoke("Get Golden Machine Info"),
        "Rainbow: use=" .. invoke("Use Rainbow Machine") .. " | info=" .. invoke("Get Rainbow Machine Info"),
        "Dark Matter: create=" .. invoke("Convert To Dark Matter")
            .. " | claim=" .. invoke("Redeem Dark Matter Pet"),
        "Boosts: activate=" .. fire("Activate Boost") .. " | bundle=" .. invoke("Buy Boost Bundle"),
        "Rewards: VIP=" .. invoke("Redeem VIP Rewards") .. " | Rank=" .. invoke("Redeem Rank Rewards")
            .. " | Gifts=" .. invoke("Redeem Free Gift"),
        "Pet catalog: " .. tostring(catalogSummary),
        "Inventory gate: " .. tostring(owner) .. " | waiting workers: " .. tostring(waiting),
        "Manual local preflight only; no server request was sent.",
    }, "\n")
end

local function reset()
    gate.Owner = nil
    gate.OwnerSince = 0
    gate.OwnerGeneration = 0
    gate.LastAcquireReason = "none"
    gate.LastAcquireAt = 0
    gate.LastReleaseReason = "none"
    gate.LastReleaseAt = 0
    gate.LastOwnerExpiry = "none"
    gate.LastOwnerExpiryAt = 0
    catalogCache.ExpiresAt = 0
    catalogCache.Ids = {}
    catalogCache.Names = {}
    catalogCache.Summary = "not scanned"
    table.clear(matcherCache.Values)
    table.clear(matcherCache.Order)
    return true
end

return function(action, context, value)
    if action == "acquire" then return acquire(context, value) end
    if action == "release" then return release(context, value, "owner released") end
    if action == "cancel" then return release(context, value, "waiter cancelled") end
    if action == "status" then return gateStatus(context) end
    if action == "diagnostics" then return gateDiagnostics(context) end
    if action == "catalog" then return getCatalog(context, value == true) end
    if action == "enchant-catalog" then return enchantCatalog(context) end
    if action == "match-enchant-profile" then
        value = type(value) == "table" and value or {}
        return matchProfile(value.Profile, value.Pet)
    end
    if action == "enchant-profile-formula" then return profileFormula(value) end
    if action == "clear-enchant-cache" then
        table.clear(matcherCache.Values); table.clear(matcherCache.Order); return true
    end
    if action == "route-health" then return routeHealth(context) end
    if action == "reset" then return reset() end
    if action == "version" then return MODULE_VERSION end
    return false, "unknown action"
end
