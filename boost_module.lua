-- Lazy boost and Boost Bundle worker for PSX OG Nova develop.
-- Named Library.Network routes are resolved locally; no session index is hard-coded.

local activeState
local MODULE_VERSION = "1.1.0"

local BUNDLE_COST = 270000
local ROUTE_REFRESH_INTERVAL = 8
local ACTIVATION_TIMEOUT = 5
local BUNDLE_CONFIRM_TIMEOUT = 10
local TRANSPORT_RETRY = 8
local REJECTED_RETRY = 30
local IDLE_SAFETY_DELAY = 30

local BOOSTS = {
    { Key = "Triple Coins", ConfigKey = "AutoTripleCoins", BundleCount = 5 },
    { Key = "Triple Damage", ConfigKey = "AutoTripleDamage", BundleCount = 5 },
    { Key = "Super Lucky", ConfigKey = "AutoSuperLucky", BundleCount = 7 },
    { Key = "Ultra Lucky", ConfigKey = "AutoUltraLucky", BundleCount = 3 },
}

local function normalize(value)
    return string.lower(tostring(value or "")):gsub("[%s_%-]", "")
end

local function saveTables(save)
    local active = type(save) == "table" and save.Boosts or nil
    local inventory = type(save) == "table" and save.BoostsInventory or nil
    return type(active) == "table" and active or {},
        type(inventory) == "table" and inventory or {}
end

local function boostSaveReady(save)
    return type(save) == "table" and type(save.Boosts) == "table"
        and type(save.BoostsInventory) == "table"
end

local function resolveName(definition, active, inventory)
    local aliases = definition.Aliases or { definition.Key }
    for _, alias in ipairs(aliases) do
        if active[alias] ~= nil or inventory[alias] ~= nil then return alias end
    end
    for key in pairs(inventory) do
        for _, alias in ipairs(aliases) do
            if normalize(key) == normalize(alias) then return key end
        end
    end
    for key in pairs(active) do
        for _, alias in ipairs(aliases) do
            if normalize(key) == normalize(alias) then return key end
        end
    end
    return aliases[1]
end

local function formatDuration(seconds)
    seconds = math.max(0, math.floor(tonumber(seconds) or 0))
    local hours = math.floor(seconds / 3600)
    local minutes = math.floor(seconds % 3600 / 60)
    local secs = seconds % 60
    if hours > 0 then return string.format("%dh %02dm %02ds", hours, minutes, secs) end
    return string.format("%dm %02ds", minutes, secs)
end

local function setStatus(state, context, text)
    text = tostring(text or "")
    if state.LastStatus == text then return end
    state.LastStatus = text
    context.SetStatus(text)
end

local function releaseOperation(state, context)
    if not state.OperationOwned then return end
    state.OperationOwned = false
    pcall(context.ReleaseOperation, context.OperationOwner)
end

local function acquireOperation(state, context)
    if state.OperationOwned then return true end
    local ok, acquired, owner = pcall(context.AcquireOperation, context.OperationOwner)
    if not ok then return false, tostring(acquired) end
    if acquired ~= true then return false, tostring(owner or "another inventory worker") end
    state.OperationOwned = true
    return true
end

local function inventorySnapshot(inventory)
    local snapshot = {}
    for _, definition in ipairs(BOOSTS) do
        local name = resolveName(definition, {}, inventory)
        snapshot[definition.Key] = tonumber(inventory[name]) or 0
    end
    return snapshot
end

local function refreshRoutes(state, context, force)
    local now = os.clock()
    if not force and now < state.NextRouteRefresh then return end
    state.NextRouteRefresh = now + ROUTE_REFRESH_INTERVAL

    local bundle, bundleSource, bundleIndex, bundleProblem =
        context.GetCommandRemote("Buy Boost Bundle")
    local activate, activateSource, activateIndex, activateProblem =
        context.GetFireRemote("Activate Boost")
    state.BundleRoute = bundle and context.RouteText(bundleSource, bundleIndex)
        or ("missing: " .. tostring(bundleProblem))
    state.ActivateRoute = activate and context.RouteText(activateSource, activateIndex)
        or ("missing: " .. tostring(activateProblem))
    state.BundleReady = bundle ~= nil
    state.ActivateReady = activate ~= nil
end

local function statusText(state, context, save, action)
    local active, inventory = saveTables(save)
    local options = context.GetOptions()
    local lines = {
        "Activate Boost: " .. tostring(state.ActivateReady and "ready" or state.ActivateRoute),
        "Buy Boost Bundle: " .. tostring(state.BundleReady and "ready" or state.BundleRoute),
    }
    for _, definition in ipairs(BOOSTS) do
        local name = resolveName(definition, active, inventory)
        local enabled = options[definition.ConfigKey] == true
        lines[#lines + 1] = string.format(
            "%s: %s | stock %d | %s",
            definition.Key,
            formatDuration(active[name]),
            tonumber(inventory[name]) or 0,
            enabled and "armed" or "disabled"
        )
    end
    local owner, waiting = context.OperationStatus()
    lines[#lines + 1] = string.format(
        "Bundle fallback: %s (270k Diamonds) | inventory gate: %s +%d waiting",
        options.AutoBoostBundle and "enabled" or "disabled",
        tostring(owner), tonumber(waiting) or 0
    )
    lines[#lines + 1] = "Action: " .. tostring(action or "monitoring live Save data")
    return table.concat(lines, "\n")
end

local function confirmPending(state, context, save, now)
    local active, inventory = saveTables(save)
    local activation = state.PendingActivation
    if activation then
        local currentInventory = tonumber(inventory[activation.Name]) or 0
        local currentTime = tonumber(active[activation.Name]) or 0
        if currentInventory < activation.InventoryBefore or currentTime > activation.ActiveBefore + 1 then
            state.PendingActivation = nil
            state.NextAttempt[activation.Key] = now + 0.2
            releaseOperation(state, context)
            context.Trace("auto boost confirmed", activation.Key .. " | " .. tostring(activation.Route))
            return "activation confirmed by Save: " .. activation.Key
        end
        if now - activation.SentAt >= ACTIVATION_TIMEOUT then
            state.PendingActivation = nil
            state.NextAttempt[activation.Key] = now + TRANSPORT_RETRY
            releaseOperation(state, context)
            context.Trace("auto boost timeout", activation.Key .. " was not confirmed by Save")
            return "activation was not confirmed; retry delayed for " .. tostring(TRANSPORT_RETRY) .. "s"
        end
        return "waiting for Save confirmation: " .. activation.Key
    end

    local bundle = state.PendingBundle
    if bundle then
        local current = inventorySnapshot(inventory)
        local increased = false
        for key, before in pairs(bundle.InventoryBefore) do
            if (tonumber(current[key]) or 0) > (tonumber(before) or 0) then
                increased = true
                break
            end
        end
        if increased then
            state.PendingBundle = nil
            state.NextBundleAttempt = now + 0.25
            releaseOperation(state, context)
            context.Trace("boost bundle confirmed", tostring(bundle.Route))
            return "Boost Bundle confirmed by BoostsInventory"
        end
        if now - bundle.SentAt >= BUNDLE_CONFIRM_TIMEOUT then
            state.PendingBundle = nil
            state.NextBundleAttempt = now + REJECTED_RETRY
            releaseOperation(state, context)
            context.Trace("boost bundle timeout", "accepted response was not confirmed by Save")
            return "bundle response was not confirmed; no blind repeat for "
                .. tostring(REJECTED_RETRY) .. "s"
        end
        return "waiting for Boost Bundle inventory confirmation"
    end
    return nil
end

local function enabledDefinitions(options)
    local result = {}
    for _, definition in ipairs(BOOSTS) do
        if options[definition.ConfigKey] == true then result[#result + 1] = definition end
    end
    return result
end

local function runCycle(state, context)
    local now = os.clock()
    state.NextWakeAt = now + IDLE_SAFETY_DELAY
    refreshRoutes(state, context, false)
    local save = context.GetSave()
    if not save then
        state.NextWakeAt = now + 2
        releaseOperation(state, context)
        setStatus(state, context, "Waiting for Library.Save; no boost request was sent.")
        return
    end
    if not boostSaveReady(save) then
        state.NextWakeAt = now + 2
        releaseOperation(state, context)
        setStatus(state, context,
            "Waiting for Save.Boosts and Save.BoostsInventory; no boost or bundle request was sent.")
        return
    end

    local pendingAction = confirmPending(state, context, save, now)
    if state.PendingActivation or state.PendingBundle then
        state.NextWakeAt = now + 0.25
        setStatus(state, context, statusText(state, context, save, pendingAction))
        return
    end

    local options = context.GetOptions()
    local selected = enabledDefinitions(options)
    if #selected == 0 then
        releaseOperation(state, context)
        setStatus(state, context, statusText(state, context, save,
            "no boost type is selected; no purchase is allowed"))
        return
    end
    if context.Library.Shared and context.Library.Shared.IsTradingPlaza == true then
        releaseOperation(state, context)
        setStatus(state, context, statusText(state, context, save,
            "paused in Trading Plaza"))
        return
    end

    local active, inventory = saveTables(save)
    local renewBefore = math.max(1, math.floor(tonumber(options.RenewBefore) or 5))
    local activationCandidate
    local missing = {}
    for _, definition in ipairs(selected) do
        local name = resolveName(definition, active, inventory)
        local remaining = tonumber(active[name]) or 0
        local stock = tonumber(inventory[name]) or 0
        if remaining <= renewBefore then
            local nextAttempt = state.NextAttempt[definition.Key] or 0
            if stock > 0 and now >= nextAttempt
                and not activationCandidate then
                activationCandidate = {
                    Definition = definition,
                    Name = name,
                    Remaining = remaining,
                    Stock = stock,
                }
            elseif stock > 0 and nextAttempt > now then
                state.NextWakeAt = math.min(state.NextWakeAt, nextAttempt)
            elseif stock <= 0 then
                missing[#missing + 1] = definition.Key
            end
        else
            state.NextWakeAt = math.min(state.NextWakeAt,
                now + math.max(remaining - renewBefore, 0.25))
        end
    end

    if activationCandidate then
        local acquired, owner = acquireOperation(state, context)
        if not acquired then
            state.NextWakeAt = now + 0.25
            setStatus(state, context, statusText(state, context, save,
                "ready to activate " .. activationCandidate.Definition.Key
                .. ", waiting for " .. tostring(owner)))
            return
        end

        local fresh = context.GetSave()
        if not boostSaveReady(fresh) then
            releaseOperation(state, context)
            setStatus(state, context,
                "Boost Save data changed during the safety recheck; no activation was sent.")
            return
        end
        local freshActive, freshInventory = saveTables(fresh)
        local freshName = resolveName(activationCandidate.Definition, freshActive, freshInventory)
        local stock = tonumber(freshInventory[freshName]) or 0
        local remaining = tonumber(freshActive[freshName]) or 0
        if stock <= 0 or remaining > renewBefore then
            releaseOperation(state, context)
            return
        end

        local sent, problem, sourceName, sessionIndex =
            context.FireCommand("Activate Boost", freshName)
        if not sent then
            releaseOperation(state, context)
            state.NextAttempt[activationCandidate.Definition.Key] = now + TRANSPORT_RETRY
            state.NextWakeAt = math.min(state.NextWakeAt,
                state.NextAttempt[activationCandidate.Definition.Key])
            setStatus(state, context, statusText(state, context, fresh,
                "Activate Boost transport error: " .. tostring(problem)))
            return
        end
        state.PendingActivation = {
            Key = activationCandidate.Definition.Key,
            Name = freshName,
            InventoryBefore = stock,
            ActiveBefore = remaining,
            SentAt = now,
            Route = context.RouteText(sourceName, sessionIndex),
        }
        state.NextWakeAt = now + 0.25
        setStatus(state, context, statusText(state, context, fresh,
            "sent Activate Boost for " .. activationCandidate.Definition.Key
            .. "; waiting for Save"))
        return
    end

    if #missing > 0 and options.AutoBoostBundle == true then
        if now < state.NextBundleAttempt then
            state.NextWakeAt = math.min(state.NextWakeAt, state.NextBundleAttempt)
            setStatus(state, context, statusText(state, context, save,
                "bundle retry cooldown; missing: " .. table.concat(missing, ", ")))
            return
        end
        local diamonds = context.GetCurrency("Diamonds")
        if diamonds == nil or diamonds < BUNDLE_COST then
            local balance = diamonds == nil and "unknown" or context.FormatNumber(diamonds)
            setStatus(state, context, statusText(state, context, save,
                "missing " .. table.concat(missing, ", ") .. "; Diamonds "
                .. balance .. "/" .. context.FormatNumber(BUNDLE_COST)
                .. "; no bundle request sent"))
            return
        end
        if not state.BundleReady then
            setStatus(state, context, statusText(state, context, save,
                "Buy Boost Bundle route is unavailable; no purchase sent"))
            return
        end

        local acquired, owner = acquireOperation(state, context)
        if not acquired then
            state.NextWakeAt = now + 0.25
            setStatus(state, context, statusText(state, context, save,
                "bundle is needed, waiting for " .. tostring(owner)))
            return
        end

        local fresh = context.GetSave()
        if not boostSaveReady(fresh) then
            releaseOperation(state, context)
            setStatus(state, context,
                "Boost Save data changed during the bundle safety recheck; no purchase was sent.")
            return
        end
        local freshActive, freshInventory = saveTables(fresh)
        local stillMissing = {}
        for _, definition in ipairs(selected) do
            local name = resolveName(definition, freshActive, freshInventory)
            local remaining = tonumber(freshActive[name]) or 0
            local stock = tonumber(freshInventory[name]) or 0
            if remaining <= renewBefore and stock <= 0 then
                stillMissing[#stillMissing + 1] = definition.Key
            end
        end
        local freshDiamonds = context.GetCurrency("Diamonds")
        if #stillMissing == 0 or freshDiamonds == nil or freshDiamonds < BUNDLE_COST then
            releaseOperation(state, context)
            local reason = #stillMissing == 0 and "the selected boost stock was refilled"
                or ("Diamonds changed to "
                    .. (freshDiamonds == nil and "unknown" or context.FormatNumber(freshDiamonds)))
            setStatus(state, context, statusText(state, context, fresh,
                "bundle safety recheck cancelled the purchase: " .. reason))
            return
        end
        local before = inventorySnapshot(freshInventory)
        local transportOk, accepted, message, sourceName, sessionIndex =
            context.InvokeCommand("Buy Boost Bundle")
        if not transportOk or not accepted then
            releaseOperation(state, context)
            state.NextBundleAttempt = now + (transportOk and REJECTED_RETRY or TRANSPORT_RETRY)
            state.NextWakeAt = math.min(state.NextWakeAt, state.NextBundleAttempt)
            local reason = transportOk and tostring(message or "request rejected")
                or ("transport error: " .. tostring(message))
            setStatus(state, context, statusText(state, context, fresh,
                "Boost Bundle not accepted: " .. reason))
            context.Trace("boost bundle", reason)
            return
        end
        state.PendingBundle = {
            InventoryBefore = before,
            SentAt = now,
            Route = context.RouteText(sourceName, sessionIndex),
        }
        state.NextWakeAt = now + 0.25
        setStatus(state, context, statusText(state, context, fresh,
            "Boost Bundle accepted; waiting for BoostsInventory"))
        return
    end

    releaseOperation(state, context)
    local action = #missing > 0
        and ("out of " .. table.concat(missing, ", ") .. "; bundle fallback is disabled")
        or (pendingAction or "all selected boosts are outside the renewal window")
    setStatus(state, context, statusText(state, context, save, action))
end

local function workerDelay(state)
    local remaining = (tonumber(state.NextWakeAt) or 0) - os.clock()
    if remaining <= 0 then return 0.05 end
    return math.clamp(remaining, 0.05, IDLE_SAFETY_DELAY)
end

local function stopState(state, context)
    if not state then return true end
    state.Running = false
    state.PendingActivation = nil
    state.PendingBundle = nil
    releaseOperation(state, context)
    pcall(context.CancelOperation, context.OperationOwner)
    table.clear(state.NextAttempt)
    local worker = state.WorkerThread
    state.WorkerThread = nil
    if worker and worker ~= coroutine.running() and type(task.cancel) == "function" then
        pcall(task.cancel, worker)
    end
    if activeState == state then activeState = nil end
    state.Context = nil
    return true
end

local function stop()
    if activeState then return stopState(activeState, activeState.Context) end
    return true
end

return function(action, context)
    if action == "stop" then return stop() end
    if action ~= "start" then return false, "unknown action" end
    if activeState and activeState.Running then return true end
    if type(context) ~= "table" then return false, "module context is missing" end
    for _, key in ipairs({
        "Library", "Running", "Enabled", "GetOptions", "GetSave", "GetCurrency",
        "FormatNumber", "GetCommandRemote", "GetFireRemote", "InvokeCommand",
        "FireCommand", "RouteText", "AcquireOperation", "ReleaseOperation",
        "CancelOperation", "OperationStatus", "OperationOwner", "SetStatus", "Trace",
    }) do
        if context[key] == nil then return false, "module context is missing " .. key end
    end

    local state = {
        Context = context,
        Running = true,
        OperationOwned = false,
        PendingActivation = nil,
        PendingBundle = nil,
        NextAttempt = {},
        NextBundleAttempt = 0,
        NextRouteRefresh = 0,
        NextWakeAt = 0,
        WorkerThread = nil,
    }
    activeState = state
    refreshRoutes(state, context, true)
    context.Trace("auto boost module", "v" .. MODULE_VERSION
        .. " | dynamic Activate Boost + Buy Boost Bundle routes")
    state.WorkerThread = task.spawn(function()
        while state.Running and activeState == state and context.Running() and context.Enabled() do
            local ok, problem = pcall(runCycle, state, context)
            if not ok then
                releaseOperation(state, context)
                state.NextBundleAttempt = os.clock() + TRANSPORT_RETRY
                local status = "Auto boost worker recovered from a local error: " .. tostring(problem)
                context.Trace("auto boost", status)
                setStatus(state, context, status .. "\nNo immediate request; retry delayed.")
            end
            if state.Running and activeState == state then
                task.wait(workerDelay(state))
            end
        end
        stopState(state, context)
    end)
    return true
end
