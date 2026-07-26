-- Lazy LowOnline boost and potion-shop worker.
-- Named Library.Network routes are resolved locally; no session index is hard-coded.

local activeState
local MODULE_VERSION = "2.0.0-lowonline"

local ROUTE_REFRESH_INTERVAL = 8
local ACTIVATION_TIMEOUT = 5
local PURCHASE_CONFIRM_TIMEOUT = 10
local TRANSPORT_RETRY = 8
local REJECTED_RETRY = 30
local IDLE_SAFETY_DELAY = 30

local BOOSTS = {
    { Key = "Triple Coins", ConfigKey = "AutoTripleCoins" },
    { Key = "Triple Damage", ConfigKey = "AutoTripleDamage" },
    { Key = "Super Lucky", ConfigKey = "AutoSuperLucky" },
    { Key = "Ultra Lucky", ConfigKey = "AutoUltraLucky" },
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

local function refreshRoutes(state, context, force)
    local now = os.clock()
    if not force and now < state.NextRouteRefresh then return end
    state.NextRouteRefresh = now + ROUTE_REFRESH_INTERVAL

    local purchase, purchaseSource, purchaseIndex, purchaseProblem =
        context.GetCommandRemote("Purchase Boosts")
    local activate, activateSource, activateIndex, activateProblem =
        context.GetFireRemote("Activate Boost")
    state.PurchaseRoute = purchase and context.RouteText(purchaseSource, purchaseIndex)
        or ("missing: " .. tostring(purchaseProblem))
    state.ActivateRoute = activate and context.RouteText(activateSource, activateIndex)
        or ("missing: " .. tostring(activateProblem))
    state.PurchaseReady = purchase ~= nil
    state.ActivateReady = activate ~= nil
end

local function statusText(state, context, save, action)
    local active, inventory = saveTables(save)
    local options = context.GetOptions()
    local lines = {
        "Activate Boost: " .. tostring(state.ActivateReady and "ready" or state.ActivateRoute),
        "Purchase Boosts: " .. tostring(state.PurchaseReady and "ready" or state.PurchaseRoute),
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
        "Auto-buy missing potions: %s | purchase lead: %ds | inventory gate: %s +%d waiting",
        options.AutoBuyPotions and "enabled" or "disabled",
        math.max(1, math.floor(tonumber(options.PurchaseLead) or 30)),
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

    local purchase = state.PendingPurchase
    if purchase then
        local current = tonumber(inventory[purchase.Name]) or 0
        if current > purchase.InventoryBefore then
            state.PendingPurchase = nil
            state.NextPurchaseAttempt[purchase.Key] = now + 0.25
            releaseOperation(state, context)
            context.Trace("boost potion confirmed", purchase.Key .. " | " .. tostring(purchase.Route))
            return "potion purchase confirmed by BoostsInventory: " .. purchase.Key
        end
        if now - purchase.SentAt >= PURCHASE_CONFIRM_TIMEOUT then
            state.PendingPurchase = nil
            state.NextPurchaseAttempt[purchase.Key] = now + REJECTED_RETRY
            releaseOperation(state, context)
            context.Trace("boost potion timeout",
                purchase.Key .. " accepted response was not confirmed by Save")
            return "potion response was not confirmed; no blind repeat for "
                .. tostring(REJECTED_RETRY) .. "s"
        end
        return "waiting for potion inventory confirmation: " .. purchase.Key
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
    if state.PendingActivation or state.PendingPurchase then
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
    local purchaseLead = math.max(renewBefore,
        math.floor(tonumber(options.PurchaseLead) or 30))
    local activationCandidate
    local purchaseCandidate
    local missing = {}
    for _, definition in ipairs(selected) do
        local name = resolveName(definition, active, inventory)
        local remaining = tonumber(active[name]) or 0
        local stock = tonumber(inventory[name]) or 0
        local nextPurchase = state.NextPurchaseAttempt[definition.Key] or 0
        if stock <= 0 and remaining <= purchaseLead then
            missing[#missing + 1] = definition.Key
            if options.AutoBuyPotions == true and now >= nextPurchase
                and not purchaseCandidate then
                purchaseCandidate = {
                    Definition = definition,
                    Name = name,
                    Remaining = remaining,
                    Stock = stock,
                }
            elseif nextPurchase > now then
                state.NextWakeAt = math.min(state.NextWakeAt, nextPurchase)
            end
        elseif stock <= 0 and remaining > purchaseLead then
            state.NextWakeAt = math.min(state.NextWakeAt,
                now + math.max(remaining - purchaseLead, 0.25))
        end
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
            end
        else
            state.NextWakeAt = math.min(state.NextWakeAt,
                now + math.max(remaining - renewBefore, 0.25))
        end
    end

    if purchaseCandidate then
        if not state.PurchaseReady then
            setStatus(state, context, statusText(state, context, save,
                "Purchase Boosts route is unavailable; no purchase sent"))
            return
        end
        local acquired, owner = acquireOperation(state, context)
        if not acquired then
            state.NextWakeAt = now + 0.25
            setStatus(state, context, statusText(state, context, save,
                "ready to buy " .. purchaseCandidate.Definition.Key
                .. ", waiting for " .. tostring(owner)))
            return
        end
        local fresh = context.GetSave()
        if not boostSaveReady(fresh) then
            releaseOperation(state, context)
            setStatus(state, context,
                "Boost Save data changed during potion safety recheck; no purchase was sent.")
            return
        end
        local freshActive, freshInventory = saveTables(fresh)
        local freshName = resolveName(purchaseCandidate.Definition, freshActive, freshInventory)
        local freshStock = tonumber(freshInventory[freshName]) or 0
        local freshRemaining = tonumber(freshActive[freshName]) or 0
        local freshOptions = context.GetOptions()
        if freshStock > 0 or freshRemaining > purchaseLead
            or type(freshOptions) ~= "table" or freshOptions.AutoBuyPotions ~= true then
            releaseOperation(state, context)
            return
        end
        local transportOk, accepted, message, sourceName, sessionIndex =
            context.InvokeCommand("Purchase Boosts", freshName, false)
        if not transportOk or not accepted then
            releaseOperation(state, context)
            local retry = transportOk and REJECTED_RETRY or TRANSPORT_RETRY
            state.NextPurchaseAttempt[purchaseCandidate.Definition.Key] = now + retry
            state.NextWakeAt = math.min(state.NextWakeAt,
                state.NextPurchaseAttempt[purchaseCandidate.Definition.Key])
            local reason = transportOk and tostring(message or "request rejected")
                or ("transport error: " .. tostring(message))
            setStatus(state, context, statusText(state, context, fresh,
                "Purchase Boosts not accepted for "
                .. purchaseCandidate.Definition.Key .. ": " .. reason))
            context.Trace("boost potion", purchaseCandidate.Definition.Key .. " | " .. reason)
            return
        end
        state.PendingPurchase = {
            Key = purchaseCandidate.Definition.Key,
            Name = freshName,
            InventoryBefore = freshStock,
            SentAt = now,
            Route = context.RouteText(sourceName, sessionIndex),
        }
        state.NextWakeAt = now + 0.25
        setStatus(state, context, statusText(state, context, fresh,
            "Purchase Boosts accepted for " .. purchaseCandidate.Definition.Key
            .. "; waiting for BoostsInventory"))
        return
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

    releaseOperation(state, context)
    local action = #missing > 0
        and ("out of " .. table.concat(missing, ", ")
            .. "; potion auto-buy is " .. (options.AutoBuyPotions and "cooling down" or "disabled"))
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
    state.PendingPurchase = nil
    releaseOperation(state, context)
    pcall(context.CancelOperation, context.OperationOwner)
    table.clear(state.NextAttempt)
    table.clear(state.NextPurchaseAttempt)
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
        "Library", "Running", "Enabled", "GetOptions", "GetSave",
        "GetCommandRemote", "GetFireRemote", "InvokeCommand",
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
        PendingPurchase = nil,
        NextAttempt = {},
        NextPurchaseAttempt = {},
        NextRouteRefresh = 0,
        NextWakeAt = 0,
        WorkerThread = nil,
    }
    activeState = state
    refreshRoutes(state, context, true)
    context.Trace("auto boost module", "v" .. MODULE_VERSION
        .. " | dynamic Activate Boost + Purchase Boosts routes")
    state.WorkerThread = task.spawn(function()
        while state.Running and activeState == state and context.Running() and context.Enabled() do
            local ok, problem = pcall(runCycle, state, context)
            if not ok then
                releaseOperation(state, context)
                for _, definition in ipairs(BOOSTS) do
                    state.NextPurchaseAttempt[definition.Key] = os.clock() + TRANSPORT_RETRY
                end
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
