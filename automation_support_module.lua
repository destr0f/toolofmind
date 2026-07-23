-- Shared low-frequency coordinator for PSX OG Nova develop.
-- Nothing in this module invokes the server. Route checks only resolve named remotes locally.

local MODULE_VERSION = "1.1.2"

local gate = {
    Owner = nil,
    OwnerSince = 0,
    Waiters = {},
    Sequence = 0,
}

local catalogCache = {
    ExpiresAt = 0,
    Ids = {},
    Names = {},
    Summary = "not scanned",
}

local MACHINE_PET_NAMES = {
    ["galaxy fox"] = "Galaxy Fox",
    ["silver stag"] = "Silver Stag",
    ["silver dragon"] = "Silver Dragon",
    ["santa paws"] = "Santa Paws",
}

local MACHINE_PET_IDS = {
    ["263"] = "Santa Paws",
    ["264"] = "Silver Stag",
    ["265"] = "Silver Dragon",
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
    if rawId ~= nil and MACHINE_PET_IDS[tostring(rawId)] ~= nil then return true end
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
        gate.Owner = nil
        gate.OwnerSince = 0
    end
    for owner, waiter in pairs(gate.Waiters) do
        if now - (waiter.SeenAt or 0) > 2 then gate.Waiters[owner] = nil end
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

local function definitionAllowed(definition, rawId)
    -- Current event IDs are authoritative even when this place ships an older
    -- Directory.Pets table that has no definition for the new pets yet.
    if type(definition) ~= "table" then
        return explicitMachinePet(nil, rawId)
    end
    local rarity = normalize(definition.rarity or definition.Rarity)
    if definition.isPremium == true or definition.huge == true or definition.isHuge == true
        or definition.isExclusive == true or definition.isVanity == true
        or rarity == "exclusive" or rarity == "secret" then
        return false
    end
    if explicitMachinePet(definition, rawId) then return true end
    return rarity == "legendary" or rarity == "mythical"
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

    -- Do not make the current Christmas trio depend on the live egg/directory
    -- schema. Some worlds expose the pets in Save.Pets before Directory.Pets
    -- is updated, which previously reduced the catalog to Galaxy Fox only.
    for id in pairs(MACHINE_PET_IDS) do
        ids[id] = true
    end

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
        names[#names + 1] = tostring(definitionName(definition) or MACHINE_PET_IDS[id] or id)
    end
    table.sort(names)
    table.sort(eventEggs)
    local summary = string.format("%d eligible species from %d live event egg(s): %s",
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
        "Rewards: VIP=" .. invoke("Redeem VIP Rewards") .. " | Rank=" .. invoke("Redeem Rank Rewards"),
        "Pet catalog: " .. tostring(catalogSummary),
        "Inventory gate: " .. tostring(owner) .. " | waiting workers: " .. tostring(waiting),
        "Manual local preflight only; no server request was sent.",
    }, "\n")
end

local function reset()
    gate.Owner = nil
    gate.OwnerSince = 0
    table.clear(gate.Waiters)
    catalogCache.ExpiresAt = 0
    catalogCache.Ids = {}
    catalogCache.Names = {}
    catalogCache.Summary = "not scanned"
    return true
end

return function(action, context, value)
    if action == "acquire" then return acquire(context, value) end
    if action == "release" or action == "cancel" then return release(value) end
    if action == "status" then return gateStatus(context) end
    if action == "catalog" then return getCatalog(context, value == true) end
    if action == "route-health" then return routeHealth(context) end
    if action == "reset" then return reset() end
    if action == "version" then return MODULE_VERSION end
    return false, "unknown action"
end
