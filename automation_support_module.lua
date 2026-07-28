-- Shared low-frequency coordinator for PSX OG Nova develop.
-- Nothing in this module invokes the server. Route checks only resolve named remotes locally.

local MODULE_VERSION = "1.5.0-lowonline"

local gate = {
    Owner = nil,
    OwnerSince = 0,
    Waiters = {},
    Sequence = 0,
}

local catalogCaches = {}

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

local function explicitMachinePet(definition, targetKey)
    local name = definitionName(definition)
    return name ~= nil and normalize(name) == targetKey
end

local function machineSafe(definition)
    if type(definition) ~= "table" then return false end
    local rarity = normalize(definition.rarity or definition.Rarity)
    return definition.isPremium ~= true
        and definition.huge ~= true
        and definition.isHuge ~= true
        and definition.isExclusive ~= true
        and definition.isVanity ~= true
        and rarity ~= "exclusive"
        and rarity ~= "secret"
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
        gate.Owner = nil
        gate.OwnerSince = 0
    end
    for owner, waiter in pairs(gate.Waiters) do
        if now - (waiter.SeenAt or 0) > 10 then gate.Waiters[owner] = nil end
    end
end

local function acquire(context, rawOwner)
    local owner = tostring(rawOwner or "unknown")
    local now = os.clock()
    cleanGate(context, now)
    if gate.Owner == owner then return true, owner end

    local waiter = gate.Waiters[owner]
    if not waiter then
        gate.Sequence = gate.Sequence + 1
        waiter = { Sequence = gate.Sequence, SeenAt = now }
        gate.Waiters[owner] = waiter
    else
        waiter.SeenAt = now
    end
    if gate.Owner then return false, gate.Owner end

    local nextOwner, nextSequence
    for candidate, item in pairs(gate.Waiters) do
        if nextSequence == nil or item.Sequence < nextSequence then
            nextOwner, nextSequence = candidate, item.Sequence
        end
    end
    if nextOwner ~= owner then return false, nextOwner end

    gate.Waiters[owner] = nil
    gate.Owner = owner
    gate.OwnerSince = now
    return true, owner
end

local function release(rawOwner)
    local owner = tostring(rawOwner or "unknown")
    gate.Waiters[owner] = nil
    if gate.Owner == owner then
        gate.Owner = nil
        gate.OwnerSince = 0
    end
    return true
end

local function gateStatus(context)
    cleanGate(context)
    local waiting = 0
    for _ in pairs(gate.Waiters) do waiting = waiting + 1 end
    return gate.Owner or "idle", waiting
end

local function definitionAllowed(definition, targetKey)
    return machineSafe(definition) and explicitMachinePet(definition, targetKey)
end

local function getCatalog(context, options)
    local force = options == true
    local targetName = "Samurai Dragon"
    if type(options) == "table" then
        force = options.Force == true or options.force == true
        targetName = options.TargetName or options.Target or options.targetName
            or options.target or targetName
    elseif type(options) == "string" and options ~= "" then
        targetName = options
    end
    targetName = tostring(targetName)
    local targetKey = normalize(targetName)
    local now = os.clock()
    local cached = catalogCaches[targetKey]
    if not force and cached and now < cached.ExpiresAt then
        return cached.Ids, cached.Names, cached.Summary
    end

    local library = type(context) == "table" and context.Library or nil
    local directory = library and library.Directory or {}
    local pets = type(directory.Pets) == "table" and directory.Pets or {}
    local ids = {}

    local function petDefinition(rawId)
        if rawId == nil then return nil end
        return pets[rawId] or pets[tostring(rawId)] or pets[tonumber(rawId)]
    end

    local function addPet(rawId)
        if rawId == nil then return end
        local id = tostring(rawId)
        local definition = petDefinition(rawId)
        if definitionAllowed(definition, targetKey) then ids[id] = true end
    end

    local function eggDropIds(rawEgg)
        local eggs = type(directory.Eggs) == "table" and directory.Eggs or {}
        local found, visiting = {}, {}
        local function scan(eggName)
            eggName = tostring(eggName or "")
            if eggName == "" or visiting[eggName] then return end
            visiting[eggName] = true
            local egg = eggs[eggName]
            local drops = type(egg) == "table" and (egg.drops or egg.Drops) or nil
            if type(drops) == "string" then
                scan(drops)
            elseif type(drops) == "table" then
                for key, drop in pairs(drops) do
                    local id
                    if type(drop) == "table" then
                        id = drop[1] or drop.id or drop.ID or drop.petId or drop.PetId
                    elseif petDefinition(drop) then
                        id = drop
                    elseif petDefinition(key) then
                        id = key
                    end
                    if id ~= nil then found[tostring(id)] = true end
                end
            end
            visiting[eggName] = nil
        end
        scan(rawEgg)
        return found
    end

    for id, definition in pairs(pets) do
        if explicitMachinePet(definition, targetKey) then
            addPet(id)
        end
    end

    -- Early LowOnline builds do not consistently expose a readable pet name.
    -- Samurai Dragon is the sole normal Mythical drop in Samurai Egg, so the
    -- live egg catalog is the authoritative fallback. No numeric ID is pinned.
    if targetKey == "samurai dragon" and next(ids) == nil then
        for id in pairs(eggDropIds("Samurai Egg")) do
            local definition = petDefinition(id)
            local rarity = type(definition) == "table"
                and normalize(definition.rarity or definition.Rarity) or ""
            if machineSafe(definition) and rarity == "mythical" then
                ids[id] = true
            end
        end
    end

    local names = {}
    local seenNames = {}
    for id in pairs(ids) do
        local definition = petDefinition(id)
        local name = tostring(definitionName(definition) or id)
        local key = normalize(name)
        if not seenNames[key] then
            seenNames[key] = true
            names[#names + 1] = name
        end
    end
    table.sort(names)
    local summary = string.format("LowOnline %s catalog: %d species (%s)", targetName,
        #names, #names > 0 and table.concat(names, ", ")
            or targetName .. " not found in Directory.Pets")
    cached = {
        ExpiresAt = now + 60,
        Ids = ids,
        Names = names,
        Summary = summary,
    }
    catalogCaches[targetKey] = cached
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
    local _, _, samuraiSummary = getCatalog(context, { TargetName = "Samurai Dragon" })
    local _, _, domortuusSummary = getCatalog(context, { TargetName = "Domortuus" })
    local owner, waiting = gateStatus(context)
    return table.concat({
        "Egg: Buy=" .. invoke("Buy Egg") .. " | Open event resolves only when Auto Egg starts",
        "Gold: use=" .. invoke("Use Golden Machine") .. " | info=" .. invoke("Get Golden Machine Info"),
        "Rainbow: use=" .. invoke("Use Rainbow Machine") .. " | info=" .. invoke("Get Rainbow Machine Info"),
        "Dark Matter: create=" .. invoke("Convert To Dark Matter")
            .. " | claim=" .. invoke("Redeem Dark Matter Pet"),
        "Fuse: use=" .. invoke("Use Fuse Machine") .. " | info=" .. invoke("Get Fuse Pets Info"),
        "Boosts: activate=" .. fire("Activate Boost") .. " | shop=" .. invoke("Purchase Boosts"),
        "Rewards: VIP=" .. invoke("Redeem VIP Rewards") .. " | Rank=" .. invoke("Redeem Rank Rewards"),
        "Gold/Rainbow catalog: " .. tostring(samuraiSummary),
        "Dark Matter catalog: " .. tostring(domortuusSummary),
        "Inventory gate: " .. tostring(owner) .. " | waiting workers: " .. tostring(waiting),
        "Manual local preflight only; no server request was sent.",
    }, "\n")
end

local function reset()
    gate.Owner = nil
    gate.OwnerSince = 0
    table.clear(gate.Waiters)
    table.clear(catalogCaches)
    return true
end

return function(action, context, value)
    if action == "acquire" then return acquire(context, value) end
    if action == "release" or action == "cancel" then return release(value) end
    if action == "status" then return gateStatus(context) end
    if action == "catalog" then return getCatalog(context, value) end
    if action == "route-health" then return routeHealth(context) end
    if action == "reset" then return reset() end
    if action == "version" then return MODULE_VERSION end
    return false, "unknown action"
end
