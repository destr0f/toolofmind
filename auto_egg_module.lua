-- Lazy, protocol-aware egg hatch worker for PSX OG Nova develop.
-- Resolves named Network routes at runtime and never relies on session child indices.

local activeState
local MODULE_VERSION = "1.7.7"

local ARM_DELAY = 0.65
local LOCAL_RECHECK_DELAY = 0.18
local INITIAL_REQUEST_DELAY = 0.75
local MIN_REQUEST_DELAY = 0
local MAX_REQUEST_DELAY = 8
local HEADLESS_EVENT_TIMEOUT = 8
local HEADLESS_REPLICATION_TIMEOUT = 4
local HEADLESS_REPLICATION_POLL = 0.02
local NATIVE_EVENT_TIMEOUT = 20
local SUSPICIOUS_PAUSE = 60
local EGG_INTERACT_DISTANCE = 15
local AUTO_DELETE_SYNC_TIMEOUT = 2.5
local AUTO_DELETE_POLL = 0.05
local POST_PROCESS_TIMEOUT = 8
local NATIVE_SKIP_ARM_TIMEOUT = 8
local NATIVE_SKIP_CONNECTION_WINDOW = 0.35
local PHYSICAL_RESCAN_COOLDOWN = 2
local MAX_NETWORK_ATTEMPTS = 12
local NETWORK_RETRY_WINDOW = 600
local NETWORK_RETRY_DELAYS = { 1, 2, 5, 10, 20, 40, 70, 90, 110, 120, 120 }
local NETWORK_RETRY_BASE_DELAY = 0.6
local NETWORK_RETRY_MAX_DELAY = 4
local RESPONSE_WAIT_SLICE = 54
local MAX_RESPONSE_WAIT_SLICES = 12
local MAX_POST_PROCESS_ATTEMPTS = 12
local POST_PROCESS_RETRY_BASE_DELAY = 0.35
local POST_PROCESS_RETRY_MAX_DELAY = 3
local POST_PROCESS_WAIT_SLICE = 54
local MAX_POST_PROCESS_WAIT_SLICES = 12
local HEADLESS_EVENT_SETTLE_DELAY = 0.35
local HEADLESS_INVENTORY_FALLBACK = "exact inventory-delta compatibility fallback"
local HEADLESS_EVENT_GATE = "direct Open Egg RemoteEvent producer gate"
local HEADLESS_NATIVE_HOOK = "native openegggg OpenEgg closure gate"
-- The August Network4 build renamed the inbound hatch event while keeping the
-- purchase command unchanged. Resolve the live name first, then retain the old
-- name as a compatibility alias for older servers.
local OPEN_EGG_EVENT_NAMES = { "openegggg", "Open Egg" }
local physicalCache = {
    Root = nil,
    ById = {},
    Dirty = true,
    LastScanAt = -math.huge,
    Connections = {},
}

local responseHistory = { Limit = 64 }

local function timingOptions(context)
    local options = context.GetOptions()
    options = type(options) == "table" and options or {}
    options.DelayMode = options.DelayMode == "Manual" and "Manual" or "Adaptive"
    options.ManualDelay = math.clamp(tonumber(options.ManualDelay) or 0, 0, 10)
    return options
end

local function rememberResponse(state, pending)
    local duration = math.max((tonumber(pending.ResponseAt) or os.clock())
        - (tonumber(pending.StartedAt) or os.clock()), 0)
    local samples = state.ResponseSamples
    samples[#samples + 1] = duration
    if #samples > responseHistory.Limit then table.remove(samples, 1) end
    local sorted = table.clone(samples)
    table.sort(sorted)
    local function percentile(ratio)
        if #sorted == 0 then return 0 end
        return sorted[math.clamp(math.ceil(#sorted * ratio), 1, #sorted)]
    end
    state.ResponseP50 = percentile(0.5)
    state.ResponseP95 = percentile(0.95)
end

local function learnedDelayStore()
    local env = type(getgenv) == "function" and getgenv() or _G
    env.PSX_OG_EGG_DELAY_BY_JOB = type(env.PSX_OG_EGG_DELAY_BY_JOB) == "table"
        and env.PSX_OG_EGG_DELAY_BY_JOB or {}
    return env.PSX_OG_EGG_DELAY_BY_JOB, tostring(game.JobId or "local")
end

local function profileBegin(label)
    local callback = debug and debug.profilebegin
    if type(callback) ~= "function" then return false end
    return pcall(callback, label) == true
end

local function profileEnd(started)
    if not started then return end
    local callback = debug and debug.profileend
    if type(callback) == "function" then pcall(callback) end
end

local function clearPhysicalBindings(clearRoot)
    for index = 1, #physicalCache.Connections do
        local connection = physicalCache.Connections[index]
        if connection then pcall(function() connection:Disconnect() end) end
        physicalCache.Connections[index] = nil
    end
    physicalCache.Dirty = true
    physicalCache.ById = {}
    physicalCache.LastScanAt = -math.huge
    if clearRoot ~= false then physicalCache.Root = nil end
end

local function bindPhysicalRoot(root)
    if physicalCache.Root == root then return end
    clearPhysicalBindings(true)
    physicalCache.Root = root
    if not root then return end
    physicalCache.Connections[1] = root.DescendantAdded:Connect(function()
        physicalCache.Dirty = true
    end)
    physicalCache.Connections[2] = root.DescendantRemoving:Connect(function()
        physicalCache.Dirty = true
    end)
end

local function lower(value)
    return string.lower(tostring(value or ""))
end

local function normalizedEggName(value)
    return (lower(value):gsub("%s+", " "):match("^%s*(.-)%s*$"))
end

local function directoryFor(context)
    local directory = context.Library and context.Library.Directory and context.Library.Directory.Eggs
    return type(directory) == "table" and directory or nil
end

local function saveFor(context)
    local saveApi = context.Library and context.Library.Save
    if not saveApi or type(saveApi.Get) ~= "function" then return nil end
    local ok, save = pcall(saveApi.Get)
    return ok and type(save) == "table" and save or nil
end

local function hasGamepass(save, gamepassName)
    local gamepasses = type(save) == "table" and save.Gamepasses or nil
    if type(gamepasses) ~= "table" then return false end
    for key, value in pairs(gamepasses) do
        if value == gamepassName or (key == gamepassName and value == true) then return true end
        if type(value) == "table" and (value.Name == gamepassName or value.name == gamepassName) then
            return true
        end
    end
    return false
end

local function instanceEggId(object)
    if not object then return nil end
    local idObject = object:FindFirstChild("ID_Attr") or object:FindFirstChild("ID")
    if idObject then
        local ok, value = pcall(function() return idObject.Value end)
        if ok and value ~= nil then return tostring(value) end
    end
    local ok, value = pcall(function()
        return object:GetAttribute("ID") or object:GetAttribute("ID_Attr")
    end)
    return ok and value ~= nil and tostring(value) or nil
end

local function instancePosition(object)
    if not object or not object.Parent then return nil end
    local center = object:FindFirstChild("Center")
    if center then
        if center:IsA("BasePart") then return center.Position end
        if center:IsA("Attachment") then return center.WorldPosition end
        if center:IsA("Model") then
            local ok, pivot = pcall(center.GetPivot, center)
            if ok then return pivot.Position end
        end
        local part = center:FindFirstChildWhichIsA("BasePart", true)
        if part then return part.Position end
    end
    if object:IsA("BasePart") then return object.Position end
    if object:IsA("Model") then
        local ok, pivot = pcall(object.GetPivot, object)
        if ok then return pivot.Position end
    end
    local part = object:FindFirstChildWhichIsA("BasePart", true)
    return part and part.Position or nil
end

local function currentEggRoot()
    local cached = physicalCache.Root
    if cached and cached.Parent and cached:IsDescendantOf(workspace) then return cached end
    local map = workspace:FindFirstChild("__MAP")
    if not map then return nil end
    return map:FindFirstChild("Eggs") or map:FindFirstChild("Eggs", true)
end

local function scanPhysical(context, force)
    local root = currentEggRoot()
    bindPhysicalRoot(root)
    if not root then
        return physicalCache.ById
    end
    if not force and not physicalCache.Dirty then
        return physicalCache.ById
    end
    local now = os.clock()
    if not force and now - physicalCache.LastScanAt < PHYSICAL_RESCAN_COOLDOWN then
        return physicalCache.ById
    end

    local directory = directoryFor(context)
    local byId = {}
    for _, object in ipairs(root:GetDescendants()) do
        if (object:IsA("Model") or object:IsA("Folder")) and object:FindFirstChild("Center") then
            local eggId = instanceEggId(object)
            if eggId and (not directory or directory[eggId]) then
                byId[eggId] = byId[eggId] or {}
                byId[eggId][#byId[eggId] + 1] = object
            end
        end
    end
    physicalCache.ById = byId
    physicalCache.Dirty = false
    physicalCache.LastScanAt = now
    return byId
end

local function rootPosition(context)
    local player = context.Player or game:GetService("Players").LocalPlayer
    local character = player and player.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    return root and root.Position or nil
end

local function physicalEgg(context, eggId, force)
    local candidates = scanPhysical(context, force)[tostring(eggId)]
    if type(candidates) ~= "table" then return nil, nil end
    local playerPosition = rootPosition(context)
    local best, bestDistance, bestPosition
    for _, object in ipairs(candidates) do
        local position = instancePosition(object)
        if position then
            local distance = playerPosition and (position - playerPosition).Magnitude or math.huge
            if not bestDistance or distance < bestDistance then
                best, bestDistance, bestPosition = object, distance, position
            end
        end
    end
    return best and { Object = best, Position = bestPosition }, bestDistance
end

local function isHatchable(entry)
    return type(entry) == "table" and entry.disabled ~= true and entry.hatchable ~= false
end

local function unlocked(context, eggId, save, visiting)
    local directory = directoryFor(context)
    local entry = directory and directory[eggId]
    if not isHatchable(entry) then return false, "egg is disabled or not hatchable" end
    visiting = visiting or {}
    if visiting[eggId] then return false, "egg unlock chain contains a cycle" end
    visiting[eggId] = true

    if entry.areaRequired then
        local worldCommands = context.Library.WorldCmds
        if not worldCommands or type(worldCommands.HasArea) ~= "function" then
            visiting[eggId] = nil
            return false, "area unlock data is not ready"
        end
        local checked, ownsArea = pcall(worldCommands.HasArea, entry.area)
        if not checked or not ownsArea then
            visiting[eggId] = nil
            return false, "required area is locked: " .. tostring(entry.area or "unknown")
        end
    end

    local requiredEgg = tostring(entry.eggRequired or "")
    if requiredEgg ~= "" and requiredEgg ~= tostring(eggId) then
        local ownsRequirement, problem = unlocked(context, requiredEgg, save, visiting)
        if not ownsRequirement then
            visiting[eggId] = nil
            return false, "required egg is locked: " .. requiredEgg .. " (" .. tostring(problem) .. ")"
        end
    end
    local amount = tonumber(entry.eggRequiredOpenAmount) or 0
    if amount > 0 and requiredEgg ~= "" then
        local opened = type(save.EggsOpened) == "table" and tonumber(save.EggsOpened[requiredEgg]) or 0
        if (opened or 0) < amount then
            visiting[eggId] = nil
            return false, string.format("open %s %d more time(s)", requiredEgg, amount - (opened or 0))
        end
    end
    if tostring(eggId) == "Dominus Egg" and save.OwnsDominusGate ~= true then
        visiting[eggId] = nil
        return false, "Dominus Gate is locked"
    end
    visiting[eggId] = nil
    return true
end

local function inventoryCount(save)
    local pets = type(save) == "table" and save.Pets or nil
    if type(pets) ~= "table" then return nil end
    local count = #pets
    if count == 0 then for _ in pairs(pets) do count = count + 1 end end
    return count
end

local function inspectEgg(context)
    local eggId = tostring(context.Egg or "")
    local count = tonumber(context.Count) == 3 and 3 or 1
    local directory = directoryFor(context)
    local entry = directory and directory[eggId]
    if not isHatchable(entry) then return false, "Selected egg is not hatchable: " .. eggId end
    local save = saveFor(context)
    if not save then return false, "Player save is not ready" end
    local ownsEgg, unlockProblem = unlocked(context, eggId, save)
    if not ownsEgg then return false, "Selected egg is locked: " .. tostring(unlockProblem) end
    if count == 3 and not hasGamepass(save, "Triple Egg Open") then
        return false, "x3 requires the Triple Egg Open gamepass"
    end

    local physical, distance = physicalEgg(context, eggId, false)
    if not physical then return false, "Selected egg is not present in the current world: " .. eggId end
    if distance == nil or distance == math.huge then return false, "Character position is not ready" end
    if distance > EGG_INTERACT_DISTANCE then
        return false, string.format("Too far from %s: %.1f studs (maximum 15)", eggId, distance)
    end

    local used, maxSlots = inventoryCount(save), tonumber(save.MaxSlots)
    if used == nil or maxSlots == nil then return false, "Pet inventory limits are not ready" end
    local freeSlots = math.max(0, maxSlots - used)
    if freeSlots < count then
        return false, string.format("Not enough pet slots: need %d, free %d", count, freeSlots)
    end

    local cost, currency = tonumber(entry.cost), tostring(entry.currency or "")
    if cost == nil or currency == "" then return false, "Egg price data is unavailable" end
    local balance = context.GetCurrency(currency)
    local totalCost = cost * count
    if balance == nil then return false, "Balance is unavailable for " .. currency end
    if balance < totalCost then
        local format = context.FormatNumber or tostring
        return false, string.format("Not enough %s: need %s, balance %s",
            currency, format(totalCost), format(balance))
    end
    return true, {
        Egg = eggId, Config = entry, Physical = physical.Object, Distance = distance,
        Cost = totalCost, Currency = currency, Balance = balance, FreeSlots = freeSlots,
    }
end

local function buildCatalog(context)
    local directory = directoryFor(context)
    if not directory then
        return { "Egg catalog is loading..." }, nil, nil,
            "Library.Directory.Eggs is loading...", {}
    end
    scanPhysical(context, false)
    local entries, nearest, nearestDistance = {}, nil, math.huge
    local loadedCount, nearbyCount = 0, 0
    for rawId, entry in pairs(directory) do
        if isHatchable(entry) then
            local eggId = tostring(rawId)
            local physical, distance = physicalEgg(context, eggId, false)
            local loaded = physical ~= nil
            local nearby = loaded and distance and distance <= EGG_INTERACT_DISTANCE
            if loaded then loadedCount = loadedCount + 1 end
            if nearby then
                nearbyCount = nearbyCount + 1
                if distance < nearestDistance then nearest, nearestDistance = eggId, distance end
            end
            entries[#entries + 1] = {
                Id = eggId, Name = tostring(entry.displayName or entry.name or eggId),
                Nearby = nearby, Distance = distance,
            }
        end
    end
    table.sort(entries, function(left, right)
        local leftName, rightName = lower(left.Name), lower(right.Name)
        if leftName == rightName then return left.Id < right.Id end
        return leftName < rightName
    end)

    local selected = tostring(context.Selected or "")
    local selectedEntry
    for _, entry in ipairs(entries) do if entry.Id == selected then selectedEntry = entry; break end end
    if not selectedEntry then selected = nearest or (entries[1] and entries[1].Id or "") end
    if context.Scope == "Nearby Eggs" and not context.PreserveSelected then
        local selectedNearby = false
        for _, entry in ipairs(entries) do
            if entry.Id == selected and entry.Nearby then selectedNearby = true; break end
        end
        if not selectedNearby then selected = nearest or "" end
    end

    local options, labelToId, idToLabel, included = {}, {}, {}, {}
    local function include(entry)
        if included[entry.Id] then return end
        included[entry.Id] = true
        local label = entry.Name
        if entry.Id ~= entry.Name then label = label .. "  [" .. entry.Id .. "]" end
        options[#options + 1], labelToId[label], idToLabel[entry.Id] = label, entry.Id, label
    end
    for _, entry in ipairs(entries) do
        if context.Scope ~= "Nearby Eggs" or entry.Nearby then include(entry) end
    end
    if context.PreserveSelected and selected ~= "" then
        for _, entry in ipairs(entries) do if entry.Id == selected then include(entry); break end end
    end
    if #options == 0 then options[1] = "No hatchable eggs within 15 studs" end

    local selectedDistance
    if selected ~= "" then local _, distance = physicalEgg(context, selected, false); selectedDistance = distance end
    local selectedText = selected == "" and "No egg selected"
        or selectedDistance and string.format("%s is %.1f studs away (%s)", selected,
            selectedDistance, selectedDistance <= 15 and "in range" or "out of range")
        or (selected .. " is not loaded in this world")
    local summary = string.format(
        "Hatchable: %d | loaded in world: %d | within 15 studs: %d\n%s",
        #entries, loadedCount, nearbyCount, selectedText
    )
    return options, idToLabel[selected], selected, summary, labelToId
end

local function setStatus(state, context, text)
    local pending = state.Pending
    local openRoute = "native"
    if state.HeadlessModeSelected or (type(pending) == "table" and pending.Headless) then
        openRoute = state.OpenEggGateRoute == HEADLESS_INVENTORY_FALLBACK
            and "headless-fallback" or "headless-gated"
    end
    text = tostring(text or "") .. string.format(
        "\nRoutes: Open Eggs %s | Egg World %s | prevented open/world %d/%d",
        openRoute,
        tostring(state.EggWorldGateRoute or "visual"),
        tonumber(state.HeadlessVisualsSuppressed) or 0,
        tonumber(state.EggWorldVisualsSuppressed) or 0
    )
    if state.LastStatus == text then return end
    state.LastStatus = text
    context.SetStatus(text)
end

local function openingFlag(context)
    local variables = context.Library and context.Library.Variables
    return variables and variables.OpeningEgg == true
end

local function openEggScriptFor(context)
    local player = context.Player
    if not player then
        local players = game:GetService("Players")
        player = players and players.LocalPlayer
    end
    local playerScripts = player and player:FindFirstChild("PlayerScripts")
    local scripts = playerScripts and playerScripts:FindFirstChild("Scripts")
    local gameScripts = scripts and scripts:FindFirstChild("Game")
    local openEggScript = gameScripts and gameScripts:FindFirstChild("Open Eggs")
    if openEggScript and openEggScript:IsA("LocalScript") then return openEggScript end
    return nil
end

local function eggWorldScriptFor(context)
    local player = context.Player
    if not player then
        local players = game:GetService("Players")
        player = players and players.LocalPlayer
    end
    local playerScripts = player and player:FindFirstChild("PlayerScripts")
    local scripts = playerScripts and playerScripts:FindFirstChild("Scripts")
    local gameScripts = scripts and scripts:FindFirstChild("Game")
    local eggWorldScript = gameScripts and gameScripts:FindFirstChild("Eggs")
    if eggWorldScript and eggWorldScript:IsA("LocalScript") then return eggWorldScript end
    return nil
end

local function eggWorldGateWanted(state, context)
    local optionsOk, options = pcall(context.GetOptions)
    local headless = optionsOk and type(options) == "table"
        and options.Animation == "Headless (No Animation)"
    local potato = false
    if type(context.PotatoEnabled) == "function" then
        local potatoOk, enabled = pcall(context.PotatoEnabled)
        potato = potatoOk and enabled == true
    end
    state.HeadlessModeSelected = headless
    state.EggWorldGateWanted = headless or potato
    return state.EggWorldGateWanted
end

local function restoreEggWorldVisualGate(state, context, rebuildVisuals)
    if not state then return end
    local record = state.EggWorldGateRecord
    state.EggWorldGateRecord = nil
    state.EggWorldGateWanted = false
    state.EggWorldGateRoute = "visual"
    if type(record) ~= "table" then return end

    record.Active = false
    local environment = record.Environment
    if type(environment) == "table" then
        for name, wrapper in pairs(record.Wrappers or {}) do
            if environment[name] == wrapper then
                pcall(function() environment[name] = record.Originals[name] end)
            end
        end
    end

    local refresh = record.Originals and record.Originals.UpdateAllEggs
    record.Environment = nil
    record.Script = nil
    record.Setup = nil
    table.clear(record.Wrappers or {})
    table.clear(record.Originals or {})

    if rebuildVisuals and type(refresh) == "function" and state.Running then
        local generation = state.Generation
        task.defer(function()
            if state.Running and state.Generation == generation
                and context.Running() and context.Enabled() then
                pcall(refresh)
            end
        end)
    end
end

local function ensureEggWorldVisualGate(state, context)
    if not eggWorldGateWanted(state, context) then
        if state.EggWorldGateRecord then
            restoreEggWorldVisualGate(state, context, true)
        end
        return true, "visual"
    end

    local eggWorldScript = eggWorldScriptFor(context)
    if not eggWorldScript then
        state.EggWorldGateRoute = "unavailable"
        return false, "PlayerScripts/Scripts/Game/Eggs is unavailable"
    end
    if type(getsenv) ~= "function" then
        state.EggWorldGateRoute = "unavailable"
        return false, "getsenv is unavailable; the world egg renderer remains visual"
    end
    local environmentOk, environment = pcall(getsenv, eggWorldScript)
    if not environmentOk or type(environment) ~= "table" then
        state.EggWorldGateRoute = "unavailable"
        return false, "Game/Eggs environment is unavailable; the renderer remains visual"
    end

    local current = state.EggWorldGateRecord
    if type(current) == "table" and current.Active
        and current.Generation == state.Generation
        and current.Script == eggWorldScript
        and current.Environment == environment
        and environment.UpdateEgg == current.Wrappers.UpdateEgg
        and environment.UpdateAllEggs == current.Wrappers.UpdateAllEggs then
        state.EggWorldGateRoute = "gated"
        return true, "gated"
    end

    restoreEggWorldVisualGate(state, context, false)
    state.EggWorldGateWanted = true
    for _, name in ipairs({ "SetupEgg", "UpdateEgg", "UpdateAllEggs" }) do
        if type(environment[name]) ~= "function" then
            state.EggWorldGateRoute = "unavailable"
            return false, "Game/Eggs." .. name .. " is not a callable export; renderer remains visual"
        end
    end

    local record = {
        Active = true,
        Generation = state.Generation,
        Script = eggWorldScript,
        Environment = environment,
        Originals = {
            SetupEgg = environment.SetupEgg,
            UpdateEgg = environment.UpdateEgg,
            UpdateAllEggs = environment.UpdateAllEggs,
        },
        Wrappers = {},
        Setup = setmetatable({}, { __mode = "k" }),
    }

    local originalSetupEgg = record.Originals.SetupEgg
    local originalUpdateEgg = record.Originals.UpdateEgg
    local originalUpdateAllEggs = record.Originals.UpdateAllEggs
    record.Wrappers.UpdateEgg = function(egg, ...)
        if record.Active and record.Generation == state.Generation
            and state.Running and state.EggWorldGateWanted then
            local profiled = profileBegin("PSX_EggWorldGate")
            local setupOk = true
            if typeof(egg) == "Instance" and egg.Parent and not record.Setup[egg] then
                setupOk = pcall(originalSetupEgg, egg)
                if setupOk then record.Setup[egg] = true end
            end
            if setupOk then
                state.EggWorldVisualsSuppressed = state.EggWorldVisualsSuppressed + 1
                profileEnd(profiled)
                return nil
            end
            profileEnd(profiled)
            -- Event-level fail-open: if interaction setup cannot be preserved,
            -- let the game's original renderer handle this egg.
        end
        return originalUpdateEgg(egg, ...)
    end
    record.Wrappers.UpdateAllEggs = function(...)
        if record.Active and record.Generation == state.Generation
            and state.Running and state.EggWorldGateWanted then
            local profiled = profileBegin("PSX_EggWorldGate")
            -- The original enumerator calls the wrapped UpdateEgg global. It
            -- therefore initializes input once without allocating Egg models.
            local result = table.pack(pcall(originalUpdateAllEggs, ...))
            profileEnd(profiled)
            if result[1] then return table.unpack(result, 2, result.n) end
            -- A changed game implementation must remain functional.
            record.Active = false
            return originalUpdateAllEggs(...)
        end
        return originalUpdateAllEggs(...)
    end

    local installed, installProblem = pcall(function()
        environment.UpdateEgg = record.Wrappers.UpdateEgg
        environment.UpdateAllEggs = record.Wrappers.UpdateAllEggs
    end)
    local retained = installed
        and environment.UpdateEgg == record.Wrappers.UpdateEgg
        and environment.UpdateAllEggs == record.Wrappers.UpdateAllEggs
    if not retained then
        record.Active = false
        for name, wrapper in pairs(record.Wrappers) do
            if environment[name] == wrapper then
                pcall(function() environment[name] = record.Originals[name] end)
            end
        end
        state.EggWorldGateRoute = "unavailable"
        return false, "Game/Eggs visual gate assignment was not retained: "
            .. tostring(installProblem or "readback mismatch")
    end

    state.EggWorldGateRecord = record
    state.EggWorldGateRoute = "gated"
    pcall(originalUpdateAllEggs)
    return true, "gated"
end

local function reconcileEggWorldVisualGate(state, context, immediate)
    local now = os.clock()
    if not immediate and now < (tonumber(state.NextEggWorldGateCheck) or 0) then return end
    state.NextEggWorldGateCheck = now + 0.5
    local ready, problem = ensureEggWorldVisualGate(state, context)
    if ready then
        state.EggWorldGateProblem = nil
        return
    end
    local text = tostring(problem)
    local changed = state.EggWorldGateProblem ~= text
    state.EggWorldGateProblem = text
    if changed or now >= (tonumber(state.NextEggWorldGateTrace) or 0) then
        state.NextEggWorldGateTrace = now + 10
        context.Trace("auto egg world gate", text)
    end
end

local function connectionMethod(connection, methodName)
    if connection == nil then return nil end
    local ok, method = pcall(function() return connection[methodName] end)
    return ok and type(method) == "function" and method or nil
end

local function callConnectionMethod(connection, methodName)
    local method = connectionMethod(connection, methodName)
    if not method then return false, methodName .. " is unavailable" end
    local ok, problem = pcall(method, connection)
    return ok, ok and nil or tostring(problem)
end

local function connectionSource(connection)
    local ok, callback = pcall(function() return connection.Function end)
    if not ok or type(callback) ~= "function" or not debug or type(debug.info) ~= "function" then
        return ""
    end
    local sourceOk, source = pcall(debug.info, callback, "s")
    return sourceOk and lower(source) or ""
end

local function connectionCallback(connection)
    local ok, callback = pcall(function() return connection.Function end)
    return ok and type(callback) == "function" and callback or nil
end

local function functionScript(callback)
    if type(callback) ~= "function" or type(getfenv) ~= "function" then return nil end
    local ok, environment = pcall(getfenv, callback)
    if not ok or type(environment) ~= "table" then return nil end
    local scriptObject = rawget(environment, "script")
    if scriptObject == nil then
        local readOk, inherited = pcall(function() return environment.script end)
        if readOk then scriptObject = inherited end
    end
    return typeof(scriptObject) == "Instance" and scriptObject or nil
end

local function functionConstants(callback)
    local getter = type(getconstants) == "function" and getconstants
        or (debug and type(debug.getconstants) == "function" and debug.getconstants or nil)
    if not getter or type(callback) ~= "function" then return nil end
    local ok, constants = pcall(getter, callback)
    return ok and type(constants) == "table" and constants or nil
end

local function findNativeOpenEgg(callback, openEggScript)
    if type(callback) ~= "function" then return nil end
    local getter = type(getupvalues) == "function" and getupvalues
        or (debug and type(debug.getupvalues) == "function" and debug.getupvalues or nil)
    local values
    if getter then
        local ok, result = pcall(getter, callback)
        if ok and type(result) == "table" then values = result end
    end
    if not values and debug and type(debug.getupvalue) == "function" then
        values = {}
        for index = 1, 32 do
            local ok, name, value = pcall(debug.getupvalue, callback, index)
            if not ok or name == nil then break end
            values[name ~= "" and name or index] = value
        end
    end
    for name, value in pairs(values or {}) do
        if type(value) == "function" and functionScript(value) == openEggScript then
            local named = string.find(lower(name), "openegg", 1, true) ~= nil
            local renderer = false
            for _, constant in pairs(functionConstants(value) or {}) do
                if constant == "Done Opening Egg" then
                    renderer = true
                    break
                end
            end
            if named or renderer then return value end
        end
    end
    return nil
end

local function networkScriptFor(context)
    local network = context.Library and context.Library.Network
    if type(network) ~= "table" then return nil end
    for _, name in ipairs({ "Fired", "Fire", "Invoke" }) do
        local scriptObject = functionScript(network[name])
        if scriptObject and scriptObject:IsA("ModuleScript") then return scriptObject end
    end
    return nil
end

local function captureHeadlessEventGate(signal, eventRoute, context, openEggScript)
    if typeof(signal) ~= "RBXScriptSignal" then
        return nil, nil, nil,
            "Open Egg command signal is not an RBXScriptSignal: " .. tostring(eventRoute)
    end
    if type(getconnections) ~= "function" then
        return nil, nil, nil, "getconnections is unavailable"
    end

    -- Library.Network.Fired(name) returns either the hashed RemoteEvent signal
    -- or that command's private BindableEvent signal. Both are already scoped
    -- to openegggg/Open Egg, so either can safely gate only the native visual
    -- callback while our listener remains connected.
    local signals, signalLabels, seenSignals = {}, {}, {}
    local function addSignal(candidate, label)
        if typeof(candidate) ~= "RBXScriptSignal" or seenSignals[candidate] then return end
        seenSignals[candidate] = true
        signals[#signals + 1] = candidate
        signalLabels[candidate] = label
    end
    addSignal(signal, eventRoute)

    -- Network5 may have returned a RemoteEvent after the game Open Eggs script
    -- had already subscribed to the command's private BindableEvent stand-in.
    -- Inspect only the bounded children of the already-loaded Network module;
    -- this finds the original openegggg subscriber without getgc or polling.
    local network = context.Library and context.Library.Network
    if network and type(network.Fired) == "function" then
        for _, commandName in ipairs(OPEN_EGG_EVENT_NAMES) do
            local ok, candidate = pcall(network.Fired, commandName)
            if ok then addSignal(candidate, "Library.Network.Fired(" .. commandName .. ")") end
        end
    end
    local networkScript = networkScriptFor(context)
    if networkScript then
        for _, child in ipairs(networkScript:GetChildren()) do
            if child:IsA("BindableEvent") then
                addSignal(child.Event, "Network5 BindableEvent stand-in")
            end
        end
    end

    local candidates, openEggCandidates, networkCandidates = {}, {}, {}
    local exactSignal, nativeOpenEgg
    for _, candidateSignal in ipairs(signals) do
        local ok, connections = pcall(getconnections, candidateSignal)
        if ok and type(connections) == "table" then
            for _, connection in pairs(connections) do
                if connectionMethod(connection, "Disable") and connectionMethod(connection, "Enable") then
                    local callback = connectionCallback(connection)
                    local source = connectionSource(connection)
                    candidates[#candidates + 1] = connection
                    if callback and functionScript(callback) == openEggScript then
                        openEggCandidates[#openEggCandidates + 1] = connection
                        exactSignal = exactSignal or candidateSignal
                        nativeOpenEgg = nativeOpenEgg or findNativeOpenEgg(callback, openEggScript)
                    elseif string.find(source, "network", 1, true)
                        or string.find(source, "framework", 1, true) then
                        networkCandidates[#networkCandidates + 1] = connection
                    end
                end
            end
        end
    end

    -- When Open Eggs connected while the hashed RemoteEvent already existed,
    -- its callback is attached directly to OnClientEvent. Prefer that exact
    -- visual producer. Older sessions may route through Network's bridge, in
    -- which case disabling the unique bridge still leaves our direct listener.
    local selected = #openEggCandidates > 0 and openEggCandidates or {}
    if #selected == 0 then
        return nil, nil, nil, string.format(
            "Open Egg native dispatcher was not found (%d compatible, %d Open Eggs, %d network-labelled)",
            #candidates, #openEggCandidates, #networkCandidates
        )
    end

    -- Verify every command-scoped native callback before the first purchase.
    -- The snapshot is taken before our listener is connected, so pausing this
    -- bounded list cannot pause our acknowledgement path.
    for _, connection in ipairs(selected) do
        local restorable, restoreProblem = callConnectionMethod(connection, "Enable")
        if not restorable then
            return nil, nil, nil,
                "Open Egg native dispatcher cannot be restored: " .. tostring(restoreProblem)
        end
    end
    return selected, exactSignal, nativeOpenEgg,
        tostring(signalLabels[exactSignal] or "openegggg native signal")
end

local function installNativeOpenEggHook(state, context)
    local target = state.NativeOpenEggTarget
    if type(target) ~= "function" then return false, "native OpenEgg closure was not found" end
    if type(hookfunction) ~= "function" then return false, "hookfunction is unavailable" end

    local original
    local wrapper = function(eggName, pets)
        local pending = state.Pending
        if state.Running and state.GateOwned and pending and pending.Headless then
            local profiled = profileBegin("PSX_EggOpenGate")
            pending.VisualSuppressed = true
            pending.VisualSuppressedAt = os.clock()
            pending.NativeOpenEggSeen = true
            pending.ActualEgg = pending.ActualEgg or tostring(eggName)
            state.HeadlessVisualsSuppressed = state.HeadlessVisualsSuppressed + 1
            profileEnd(profiled)
            return nil
        end
        return original(eggName, pets)
    end
    local ok, previous = pcall(hookfunction, target, wrapper)
    if not ok or type(previous) ~= "function" then
        return false, "native OpenEgg hook was rejected: " .. tostring(previous)
    end
    original = previous
    state.NativeOpenEggOriginal = original
    state.NativeOpenEggWrapper = wrapper
    state.NativeOpenEggHooked = true
    state.OpenEggGateRoute = HEADLESS_NATIVE_HOOK
    context.Trace("auto egg headless gate",
        "captured the original openegggg stand-in and gated OpenEgg before visual allocation")
    return true
end

local function resolveOpenEggSignal(context)
    local replicatedStorage = game:GetService("ReplicatedStorage")
    local problems = {}

    local function directSignal(commandName)
        local resolved, remote, sourceName, sessionIndex, problem =
            pcall(context.GetEventRemote, commandName)
        if resolved and typeof(remote) == "Instance" and remote:IsA("RemoteEvent")
            and remote:IsDescendantOf(replicatedStorage) then
            return remote.OnClientEvent,
                tostring(sourceName or "dynamic RemoteEvent"),
                sessionIndex,
                nil
        end
        return nil, nil, nil, tostring(resolved and problem or remote)
    end

    for _, commandName in ipairs(OPEN_EGG_EVENT_NAMES) do
        local signal, sourceName, sessionIndex, problem = directSignal(commandName)
        if signal then
            return signal, sourceName, sessionIndex, commandName
        end
        problems[#problems + 1] = commandName .. ": " .. tostring(problem)
    end

    local network = context.Library and context.Library.Network
    if network and type(network.Fired) == "function" then
        for _, commandName in ipairs(OPEN_EGG_EVENT_NAMES) do
            local signalOk, fallbackSignal = pcall(network.Fired, commandName)
            if signalOk and fallbackSignal and type(fallbackSignal.Connect) == "function" then
                -- Network4 binds a per-session hashed RemoteEvent lazily inside
                -- Fired(). Retry the read-only resolver after that local bind;
                -- this performs no FireServer/InvokeServer call and lets us
                -- gate the visual producer before the first purchase.
                local direct, sourceName, sessionIndex = directSignal(commandName)
                if direct then
                    return direct,
                        tostring(sourceName) .. " after Library.Network.Fired binding",
                        sessionIndex,
                        commandName
                end
                return fallbackSignal,
                    "Library.Network.Fired fallback",
                    nil,
                    commandName
            end
            problems[#problems + 1] = commandName .. " fallback: " .. tostring(fallbackSignal)
        end
    else
        problems[#problems + 1] = "Library.Network.Fired unavailable"
    end

    return nil, nil, nil, nil, table.concat(problems, " | ")
end

local function restoreHeadlessEventGate(state)
    if not state or not state.EventGateDisabled then return true end
    local restored, problems = true, {}
    for _, connection in ipairs(state.EventGateConnections or {}) do
        local ok, problem = callConnectionMethod(connection, "Enable")
        if not ok then
            restored = false
            problems[#problems + 1] = tostring(problem)
        end
    end
    if restored then state.EventGateDisabled = false end
    return restored, #problems > 0 and table.concat(problems, " | ") or nil
end

local function disableHeadlessEventGate(state)
    if not state or state.OpenEggGateRoute ~= HEADLESS_EVENT_GATE then return true end
    if state.EventGateDisabled then return true end
    local disabled = {}
    for _, connection in ipairs(state.EventGateConnections or {}) do
        local ok, problem = callConnectionMethod(connection, "Disable")
        if not ok then
            for _, previous in ipairs(disabled) do callConnectionMethod(previous, "Enable") end
            return false, problem
        end
        disabled[#disabled + 1] = connection
    end
    if #disabled == 0 then return false, "no command-scoped native dispatcher was captured" end
    state.EventGateDisabled = true
    return true
end

local function restoreHeadlessProducerGate(state)
    if not state then return end
    restoreHeadlessEventGate(state)
    if state.NativeOpenEggHooked and type(hookfunction) == "function"
        and type(state.NativeOpenEggTarget) == "function"
        and type(state.NativeOpenEggOriginal) == "function" then
        pcall(hookfunction, state.NativeOpenEggTarget, state.NativeOpenEggOriginal)
    end
    state.NativeOpenEggHooked = false
    state.NativeOpenEggOriginal = nil
    state.NativeOpenEggWrapper = nil
    local scriptEnvironment = state.OpenEggEnvironment
    local wrapper = state.OpenEggWrapper
    local original = state.OpenEggOriginal
    if type(scriptEnvironment) == "table" and type(wrapper) == "function"
        and type(original) == "function" and scriptEnvironment.OpenEgg == wrapper then
        pcall(function() scriptEnvironment.OpenEgg = original end)
    end
    state.OpenEggEnvironment = nil
    state.OpenEggWrapper = nil
    state.OpenEggOriginal = nil
    state.OpenEggScript = nil
    state.OpenEggGateRoute = nil
end

local function useHeadlessInventoryFallback(state, context, openEggScript, reason)
    restoreHeadlessProducerGate(state)
    state.OpenEggScript = openEggScript
    state.OpenEggGateRoute = HEADLESS_INVENTORY_FALLBACK
    context.Trace("auto egg headless gate", tostring(reason)
        .. "; continuing with one in-flight purchase, exact inventory-delta acknowledgement and local skip")
    return true, state.OpenEggGateRoute
end

local function ensureHeadlessProducerGate(state, context)
    local openEggScript = openEggScriptFor(context)
    if not openEggScript then
        return false, "PlayerScripts/Scripts/Game/Open Eggs is unavailable"
    end

    -- The inbound command gate is stronger than replacing an exported
    -- getsenv function: newer Open Eggs builds keep the real renderer in a
    -- closed-over local and leave environment.OpenEgg as a compatibility
    -- export. Pausing the exact command dispatcher prevents that renderer
    -- before DepthOfField, models and GUI are allocated while this module's
    -- listener (connected after the captured dispatcher) still receives the
    -- authoritative payload.
    if state.NativeOpenEggHooked then
        state.OpenEggScript = openEggScript
        state.OpenEggGateRoute = HEADLESS_NATIVE_HOOK
        return true, state.OpenEggGateRoute
    end
    if type(state.EventGateConnections) == "table" and #state.EventGateConnections > 0 then
        restoreHeadlessProducerGate(state)
        state.OpenEggScript = openEggScript
        state.OpenEggGateRoute = HEADLESS_EVENT_GATE
        return true, state.OpenEggGateRoute
    end
    if type(getsenv) ~= "function" then
        return useHeadlessInventoryFallback(state, context, openEggScript,
            "getsenv is unavailable and the exact event producer gate was not captured")
    end

    local environmentOk, scriptEnvironment = pcall(getsenv, openEggScript)
    if not environmentOk or type(scriptEnvironment) ~= "table" then
        return useHeadlessInventoryFallback(state, context, openEggScript,
            "Open Eggs environment is unavailable: " .. tostring(scriptEnvironment))
    end
    if state.OpenEggScript == openEggScript
        and state.OpenEggEnvironment == scriptEnvironment
        and type(state.OpenEggWrapper) == "function"
        and scriptEnvironment.OpenEgg == state.OpenEggWrapper then
        return true, state.OpenEggGateRoute
    end

    restoreHeadlessProducerGate(state)
    local original = scriptEnvironment.OpenEgg
    if type(original) ~= "function" then
        return useHeadlessInventoryFallback(state, context, openEggScript,
            "Open Eggs.OpenEgg is not exported and the exact event producer gate is unavailable")
    end

    local wrapper
    wrapper = function(eggName, pets)
        local pending = state.Pending
        if state.Running and state.GateOwned and pending and pending.Headless then
            local profiled = profileBegin("PSX_EggOpenGate")
            pending.VisualSuppressed = true
            pending.VisualSuppressedAt = os.clock()
            pending.NativeOpenEggSeen = true
            pending.ActualEgg = pending.ActualEgg or tostring(eggName)
            state.HeadlessVisualsSuppressed = state.HeadlessVisualsSuppressed + 1
            profileEnd(profiled)
            return nil
        end
        return original(eggName, pets)
    end

    local writeOk, writeProblem = pcall(function()
        scriptEnvironment.OpenEgg = wrapper
    end)
    if not writeOk or scriptEnvironment.OpenEgg ~= wrapper then
        pcall(function()
            if scriptEnvironment.OpenEgg == wrapper then scriptEnvironment.OpenEgg = original end
        end)
        return false, "Open Eggs.OpenEgg producer gate could not be installed: "
            .. tostring(writeProblem or "assignment was not retained")
    end

    state.OpenEggScript = openEggScript
    state.OpenEggEnvironment = scriptEnvironment
    state.OpenEggOriginal = original
    state.OpenEggWrapper = wrapper
    state.OpenEggGateRoute = "getsenv(Open Eggs).OpenEgg"
    context.Trace("auto egg headless gate",
        "installed before native DepthOfField/model/GUI allocation via " .. state.OpenEggGateRoute)
    return true, state.OpenEggGateRoute
end

local function acquireHeadlessGate(state, context)
    local variables = context.Library and context.Library.Variables
    if not variables then return false, "Library.Variables is unavailable" end
    if variables.OpeningEgg == true and not state.GateOwned then
        return false, "another egg animation is still active"
    end
    local dispatcherDisabled, dispatcherProblem = disableHeadlessEventGate(state)
    if not dispatcherDisabled then
        return false, "Open Egg native dispatcher could not be paused: " .. tostring(dispatcherProblem)
    end
    local ok, problem = pcall(function() variables.OpeningEgg = true end)
    if not ok then
        restoreHeadlessEventGate(state)
        return false, tostring(problem)
    end
    state.GateOwned = true
    return true
end

local function releaseHeadlessGate(state, context)
    if not state.GateOwned and not state.EventGateDisabled then return end
    state.GateOwned = false
    local variables = context.Library and context.Library.Variables
    if variables then pcall(function() variables.OpeningEgg = false end) end
    local restored, problem = restoreHeadlessEventGate(state)
    if not restored and context and type(context.Trace) == "function" then
        context.Trace("auto egg headless gate", "failed to restore native Open Egg dispatcher: " .. tostring(problem))
    end
end

local function acquireInventoryOperation(state, context)
    if state.OperationOwned then return true end
    local ok, acquired, owner = pcall(context.AcquireOperation, context.OperationOwner)
    if not ok then return false, tostring(acquired) end
    if acquired ~= true then return false, tostring(owner or "another inventory worker") end
    state.OperationOwned = true
    return true
end

local function releaseInventoryOperation(state, context)
    if not state.OperationOwned then return end
    state.OperationOwned = false
    pcall(context.ReleaseOperation, context.OperationOwner)
end

local function ownedPetSnapshot(context)
    local save = saveFor(context)
    local pets = save and save.Pets
    if type(pets) ~= "table" then
        return nil, "Player pet inventory is unavailable"
    end

    local snapshot = {}
    for key, pet in pairs(pets) do
        if type(pet) == "table" then
            local uid = pet.uid or pet.UID
            if uid == nil and type(key) == "string" then uid = key end
            if uid ~= nil then snapshot[tostring(uid)] = true end
        end
    end
    return snapshot
end

local function petsAddedSince(context, snapshot, expected)
    local save = saveFor(context)
    local pets = save and save.Pets
    if type(pets) ~= "table" then
        return nil, 0, "Player pet inventory is unavailable"
    end

    local added = {}
    for key, pet in pairs(pets) do
        if type(pet) == "table" then
            local uid = pet.uid or pet.UID
            if uid == nil and type(key) == "string" then uid = key end
            if uid ~= nil and not snapshot[tostring(uid)] then
                if pet.uid ~= nil or pet.UID ~= nil then
                    added[#added + 1] = pet
                else
                    local copy = {}
                    for field, value in pairs(pet) do copy[field] = value end
                    copy.uid = tostring(uid)
                    added[#added + 1] = copy
                end
            end
        end
    end

    if #added > expected then
        return nil, #added, string.format(
            "Inventory delta is ambiguous: expected %d new pet(s), observed %d",
            expected, #added
        )
    end
    if #added < expected then return nil, #added, nil end
    return added, #added, nil
end

local function eventSignature(eggName, pets)
    local values = {}
    if type(pets) == "table" then
        local checked = 0
        for key, pet in pairs(pets) do
            checked = checked + 1
            local value = pet
            if type(pet) == "table" then
                value = pet.uid or pet.UID or pet.id or pet.ID or key
            end
            values[#values + 1] = tostring(value)
            if checked >= 8 then break end
        end
        table.sort(values)
    end
    if #values == 0 then values[1] = tostring(pets) end
    return tostring(eggName) .. "|" .. table.concat(values, ",")
end

local function cleanEventCache(state, now)
    for signature, timestamp in pairs(state.AcknowledgedEvents) do
        if now - timestamp > 20 then state.AcknowledgedEvents[signature] = nil end
    end
end

local function suspiciousReply(message)
    local text = lower(message)
    return string.find(text, "exploit", 1, true)
        or string.find(text, "too fast", 1, true)
        or string.find(text, "rate", 1, true)
        or string.find(text, "spam", 1, true)
end

local function requestLabel(pending)
    return tostring(pending.Egg) .. " " .. (pending.Triple and "x3" or "x1")
end

local function requestRetryKey(eggName, count, animation)
    return table.concat({
        normalizedEggName(eggName),
        tonumber(count) == 3 and "3" or "1",
        tostring(animation or ""),
    }, "|")
end

local function boundedRetryDelay(attempt, baseDelay, maxDelay)
    local exponent = math.max(0, (tonumber(attempt) or 1) - 2)
    return math.min(maxDelay, baseDelay * (1.55 ^ exponent))
end

local function cancelThread(thread)
    if not thread or thread == coroutine.running() or type(task.cancel) ~= "function" then return end
    pcall(task.cancel, thread)
end

local function clearPendingThreads(pending)
    if type(pending) ~= "table" then return end
    cancelThread(pending.RequestThread)
    cancelThread(pending.ReconcileThread)
    cancelThread(pending.PostProcessThread)
    pending.RequestThread = nil
    pending.ReconcileThread = nil
    pending.PostProcessThread = nil
    if type(pending.PostProcessQueue) == "table" then table.clear(pending.PostProcessQueue) end
    if type(pending.PostProcessSignatures) == "table" then table.clear(pending.PostProcessSignatures) end
end

local function resetNetworkRetry(state)
    state.NetworkAttempt = 1
    state.NetworkRetryKey = nil
    state.NetworkWindowStartedAt = 0
end

local function retryablePostProcessFailure(problem)
    local text = lower(problem)
    return string.find(text, "transport", 1, true)
        or string.find(text, "timed out", 1, true)
        or string.find(text, "replication", 1, true)
        or string.find(text, "unavailable", 1, true)
end

local function petDefinition(context, pet)
    if type(pet) ~= "table" then return nil end
    local directory = context.Library and context.Library.Directory
        and context.Library.Directory.Pets
    if type(directory) ~= "table" then return nil end
    local id = pet.id or pet.ID
    if id == nil then return nil end
    return directory[id] or directory[tostring(id)]
end

local function gameAllPetsSkipPolicy(context)
    local save = saveFor(context)
    if not save then return false, "Game Egg Skip: save is unavailable" end
    if not hasGamepass(save, "Skip Egg Open") then
        return false, "Game Egg Skip: Skip Egg Open gamepass is missing"
    end

    local settings = type(save.Settings) == "table" and save.Settings or {}
    local rawSetting = settings.EggSkip
    local setting = tonumber(rawSetting)
    if not setting and type(rawSetting) == "string" then
        setting = ({
            ["basic pets"] = 1,
            ["rare pets"] = 2,
            ["epic pets"] = 3,
            ["all pets"] = 4,
        })[lower(rawSetting)]
    end
    setting = setting or 1
    local settingNames = {
        [1] = "Basic Pets",
        [2] = "Rare Pets",
        [3] = "Epic Pets",
        [4] = "All Pets",
    }
    if setting == 4 then
        return true, "Game Egg Skip: All Pets | fast skip armed before purchase"
    end
    return false, "Game Egg Skip: " .. tostring(settingNames[setting] or rawSetting or setting)
        .. " | result-dependent native skip cannot be armed before the result"
end

local function inputConnectionSnapshot(context)
    if type(getconnections) ~= "function" then return nil end
    local userInput = context.Library and context.Library.UserInputService
    local signal = userInput and userInput.InputEnded
    if not signal then return nil end
    local ok, connections = pcall(getconnections, signal)
    if not ok or type(connections) ~= "table" then return nil end

    local snapshot = {}
    for _, connection in ipairs(connections) do
        local read, callback = pcall(function() return connection.Function end)
        if read and type(callback) == "function" then snapshot[callback] = true end
    end
    return snapshot
end

local function invokeNewEggSkipConnection(context, pending)
    local before = pending and pending.InputConnections
    if type(before) ~= "table" or type(getconnections) ~= "function" then return false end
    local userInput = context.Library and context.Library.UserInputService
    local signal = userInput and userInput.InputEnded
    if not signal then return false end
    local ok, connections = pcall(getconnections, signal)
    if not ok or type(connections) ~= "table" then return false end

    local newConnections, eggConnections = {}, {}
    for _, connection in ipairs(connections) do
        local read, callback = pcall(function() return connection.Function end)
        if read and type(callback) == "function" and not before[callback] then
            newConnections[#newConnections + 1] = connection
            local source = connectionSource(connection)
            if string.find(source, "open eggs", 1, true)
                or string.find(source, "openegg", 1, true) then
                eggConnections[#eggConnections + 1] = connection
            elseif type(getconstants) == "function" then
                -- Wave may hide debug.info for a RobloxScript closure. The
                -- native skip listener is still uniquely recognizable by the
                -- MouseButton1/Touch/ButtonX constants from Open Eggs.
                local constantsOk, constants = pcall(getconstants, callback)
                local mouse, touch, buttonX = false, false, false
                if constantsOk and type(constants) == "table" then
                    for _, value in ipairs(constants) do
                        local text = tostring(value)
                        mouse = mouse or text == "MouseButton1"
                        touch = touch or text == "Touch"
                        buttonX = buttonX or text == "ButtonX"
                    end
                end
                if mouse and touch and buttonX then
                    eggConnections[#eggConnections + 1] = connection
                end
            end
        end
    end

    local selected = #eggConnections > 0 and eggConnections
        or (#newConnections == 1 and newConnections or nil)
    if not selected then return false end
    for _, connection in ipairs(selected) do
        local read, callback = pcall(function() return connection.Function end)
        if read and type(callback) == "function" then
            local called = pcall(callback, {
                UserInputType = Enum.UserInputType.MouseButton1,
                KeyCode = Enum.KeyCode.Unknown,
            }, false)
            if called then return true end
        end
    end
    return false
end

local function emitLocalSkipInput(context, pending)
    if invokeNewEggSkipConnection(context, pending) then
        return true, "native Egg Skip callback"
    end

    local inputOk, inputManager = pcall(function()
        return game:GetService("VirtualInputManager")
    end)
    if inputOk and inputManager then
        local sent = pcall(function()
            inputManager:SendKeyEvent(true, Enum.KeyCode.ButtonX, false, game)
            task.wait()
            inputManager:SendKeyEvent(false, Enum.KeyCode.ButtonX, false, game)
        end)
        if sent then return true, "local ButtonX input" end

        sent = pcall(function()
            local viewport = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize
                or Vector2.new(800, 600)
            local x, y = math.floor(viewport.X * 0.5), math.floor(viewport.Y * 0.5)
            inputManager:SendMouseButtonEvent(x, y, 0, true, game, 0)
            task.wait()
            inputManager:SendMouseButtonEvent(x, y, 0, false, game, 0)
        end)
        if sent then return true, "local off-screen click" end
    end

    local userOk, virtualUser = pcall(function()
        return game:GetService("VirtualUser")
    end)
    if userOk and virtualUser then
        local sent = pcall(function()
            virtualUser:CaptureController()
            local camera = workspace.CurrentCamera
            local cameraFrame = camera and camera.CFrame or CFrame.new()
            local viewport = camera and camera.ViewportSize or Vector2.new(800, 600)
            local position = Vector2.new(viewport.X * 0.5, viewport.Y * 0.5)
            virtualUser:Button1Down(position, cameraFrame)
            task.wait()
            virtualUser:Button1Up(position, cameraFrame)
        end)
        if sent then return true, "local VirtualUser click" end
    end
    return false, "no supported local input injector"
end

local function sendNativeSkipOnce(state, context, pending, policy)
    if pending.SkipSent then return true, "already sent" end
    local sent, method = emitLocalSkipInput(context, pending)
    if sent then
        pending.SkipSent = true
        state.NativeSkips = state.NativeSkips + 1
        pending.SkipResult = tostring(policy) .. " | sent via " .. tostring(method)
        context.Trace("auto egg native skip", pending.SkipResult)
        return true, method
    end
    pending.SkipResult = tostring(policy) .. " | local skip failed: " .. tostring(method)
    return false, method
end

local function armNativeSkip(state, context, pending)
    local fallbackHeadless = pending.Headless
        and pending.ProducerGateRoute == HEADLESS_INVENTORY_FALLBACK
    if pending.SkipScheduled or (pending.Headless and not fallbackHeadless) then return end
    local allowed, policy = gameAllPetsSkipPolicy(context)
    if fallbackHeadless then
        -- The current Open Eggs script no longer exports OpenEgg. In this
        -- compatibility route the game owns Auto Delete and starts its native
        -- callback, so Headless must use the existing local skip callback to
        -- finish it. This sends no additional purchase or server request.
        allowed = true
        policy = tostring(policy) .. " | headless fallback local skip"
    end
    pending.SkipPolicy = policy
    pending.SkipScheduled = allowed
    if not allowed then return end

    task.spawn(function()
        local openingDeadline = pending.StartedAt + NATIVE_SKIP_ARM_TIMEOUT
        while state.Running and state.Pending == pending and os.clock() < openingDeadline do
            if openingFlag(context) then
                pending.NativeOpeningSeen = true
                pending.NativeOpeningAt = pending.NativeOpeningAt or os.clock()
                break
            end
            task.wait(0.01)
        end

        if not state.Running or state.Pending ~= pending then return end
        if not pending.NativeOpeningSeen then
            pending.SkipResult = policy .. " | native OpeningEgg transition was not observed"
            return
        end

        local sent, method = false, nil
        if type(pending.InputConnections) == "table" then
            local connectionDeadline = os.clock() + NATIVE_SKIP_CONNECTION_WINDOW
            repeat
                if invokeNewEggSkipConnection(context, pending) then
                    sent, method = true, "auto-detected native Egg Skip callback"
                    break
                end
                task.wait(0.01)
            until not state.Running or state.Pending ~= pending
                or not openingFlag(context) or os.clock() >= connectionDeadline
        end

        if sent then
            pending.SkipSent = true
            state.NativeSkips = state.NativeSkips + 1
            pending.SkipResult = policy .. " | sent via " .. tostring(method)
            context.Trace("auto egg native skip", pending.SkipResult)
        elseif state.Running and state.Pending == pending and openingFlag(context) then
            local forced, forcedMethod = sendNativeSkipOnce(state, context, pending, policy)
            if not forced then
                context.Trace("auto egg native skip", pending.SkipResult
                    .. " | " .. tostring(forcedMethod))
            end
        end
    end)
end

local function autoDeletePlan(context, pets)
    local variables = context.Library and context.Library.Variables
    if not variables or variables.AutoDeleteEnabled ~= true then
        return {}, "Game Auto Delete: disabled"
    end

    local save = saveFor(context)
    local autoDelete = save and save.AutoDelete
    if type(autoDelete) ~= "table" then
        return {}, "Game Auto Delete: no rarity settings enabled"
    end

    local selected = {}
    for rarity, enabled in pairs(autoDelete) do
        if enabled then selected[tostring(rarity)] = true end
    end
    if next(selected) == nil then
        return {}, "Game Auto Delete: no rarity settings enabled"
    end
    if type(pets) ~= "table" then
        return nil, "Game Auto Delete: hatch payload is not a table"
    end

    local candidates, seen, rarityCounts = {}, {}, {}
    local payloadCount = 0
    for _, pet in pairs(pets) do
        if type(pet) == "table" and (pet.id ~= nil or pet.ID ~= nil) then
            payloadCount = payloadCount + 1
            local uid = pet.uid or pet.UID
            local id = pet.id or pet.ID
            local definition = petDefinition(context, pet)
            local rarity = definition and tostring(definition.rarity or "") or ""
            if uid == nil or id == nil or rarity == "" then
                return nil, "Game Auto Delete: a hatched pet could not be verified"
            end
            uid = tostring(uid)
            if selected[rarity] and not seen[uid] then
                seen[uid] = true
                rarityCounts[rarity] = (rarityCounts[rarity] or 0) + 1
                candidates[#candidates + 1] = {
                    Uid = uid,
                    Id = tostring(id),
                    Rarity = rarity,
                }
            end
        end
    end
    if payloadCount == 0 then
        return nil, "Game Auto Delete: hatch payload contains no pets"
    end
    if #candidates == 0 then
        return {}, "Game Auto Delete: hatch rarities are not selected"
    end

    local labels = {}
    for rarity, count in pairs(rarityCounts) do
        labels[#labels + 1] = tostring(rarity) .. " x" .. tostring(count)
    end
    table.sort(labels)
    return candidates, table.concat(labels, ", ")
end

local function verifyOwnedPet(context, candidate)
    local petCommands = context.Library and context.Library.PetCmds
    local getPet = petCommands and petCommands.Get
    if type(getPet) ~= "function" then
        return false, "Library.PetCmds.Get is unavailable", true
    end
    local result = table.pack(pcall(getPet, candidate.Uid))
    if not result[1] then
        return false, "PetCmds.Get failed: " .. tostring(result[2]), true
    end
    local pet, owner = result[2], result[3]
    if not pet or owner == nil then return false, "waiting for local pet replication", false end

    local localPlayer = context.Library.LocalPlayer or context.Player
    if owner ~= localPlayer and owner ~= context.Player then
        return false, "hatched UID is not owned by LocalPlayer", true
    end
    local actualId = type(pet) == "table" and (pet.id or pet.ID) or nil
    if actualId ~= nil and tostring(actualId) ~= candidate.Id then
        return false, "hatched UID resolved to a different pet id", true
    end
    return true
end

local function allCandidateUidsAbsent(context, candidates)
    local save = saveFor(context)
    local pets = save and save.Pets
    if type(pets) ~= "table" then return false end

    local present = {}
    for key, pet in pairs(pets) do
        if type(pet) == "table" then
            local uid = pet.uid or pet.UID
            if uid == nil and type(key) == "string" then uid = key end
            if uid ~= nil then present[tostring(uid)] = true end
        end
    end
    for _, candidate in ipairs(candidates) do
        if present[candidate.Uid] then return false end
    end
    return true
end

local function waitForAutoDeleteOwnership(state, context, pending, candidates)
    local deadline = os.clock() + AUTO_DELETE_SYNC_TIMEOUT
    local lastProblem = "waiting for local pet replication"
    repeat
        if not state.Running or state.Pending ~= pending then
            return false, "auto hatch stopped before Auto Delete"
        end
        local allReady = true
        for _, candidate in ipairs(candidates) do
            local ready, problem, permanent = verifyOwnedPet(context, candidate)
            if not ready then
                if permanent then return false, problem end
                allReady, lastProblem = false, problem or lastProblem
                break
            end
        end
        if allReady then return true end
        task.wait(AUTO_DELETE_POLL)
    until os.clock() >= deadline
    return false, tostring(lastProblem) .. " timed out after "
        .. tostring(AUTO_DELETE_SYNC_TIMEOUT) .. "s"
end

local function runHeadlessAutoDelete(state, context, pending, pets)
    local candidates, plan = autoDeletePlan(context, pets)
    if not candidates then return false, plan end
    if #candidates == 0 then return true, plan end

    if pending.ProducerGateRoute == HEADLESS_INVENTORY_FALLBACK then
        return true, "Game Auto Delete: owned by the native Open Eggs callback (no duplicate request)"
    end

    local ready, syncProblem = waitForAutoDeleteOwnership(state, context, pending, candidates)
    if not ready then
        if allCandidateUidsAbsent(context, candidates) then
            state.AutoDeleted = state.AutoDeleted + #candidates
            return true, string.format(
                "Game Auto Delete: %d selected pet(s) were already absent; duplicate deletion skipped",
                #candidates
            )
        end
        return false, "Game Auto Delete: " .. tostring(syncProblem)
    end

    local uids = {}
    for _, candidate in ipairs(candidates) do uids[#uids + 1] = candidate.Uid end
    local result = table.pack(context.InvokeCommand("Delete Several Pets", uids))
    if not result[1] then
        if allCandidateUidsAbsent(context, candidates) then
            state.AutoDeleted = state.AutoDeleted + #uids
            return true, string.format(
                "Game Auto Delete: %d pet(s) were already removed after an uncertain transport reply",
                #uids
            )
        end
        return false, "Delete Several Pets transport failed: " .. tostring(result[3])
    end
    if not result[2] then
        if allCandidateUidsAbsent(context, candidates) then
            state.AutoDeleted = state.AutoDeleted + #uids
            return true, string.format(
                "Game Auto Delete: %d pet(s) were already removed; server rejection treated as idempotent success",
                #uids
            )
        end
        return false, "Delete Several Pets was rejected: " .. tostring(result[3] or "unknown reason")
    end

    state.AutoDeleted = state.AutoDeleted + #uids
    state.AutoDeleteBatches = state.AutoDeleteBatches + 1
    return true, string.format(
        "Game Auto Delete: removed %d (%s) via %s",
        #uids, tostring(plan), context.RouteText(result[4], result[5])
    )
end

local function queueHeadlessPostProcess(pending, eggName, pets)
    if type(pending) ~= "table" or type(pets) ~= "table" then return false end
    pending.LastHeadlessEventAt = os.clock()
    pending.PostProcessQueue = pending.PostProcessQueue or {}
    pending.PostProcessSignatures = pending.PostProcessSignatures or {}
    local signature = eventSignature(eggName, pets)
    if pending.PostProcessSignatures[signature] then return false end
    pending.PostProcessSignatures[signature] = true
    pending.PostProcessQueue[#pending.PostProcessQueue + 1] = {
        Egg = tostring(eggName or pending.Egg),
        Pets = pets,
        Signature = signature,
    }
    pending.PostProcessDone = false
    return true
end

local function startHeadlessPostProcess(state, context, pending)
    if pending.PostProcessStarted or not pending.Headless then return end
    if type(pending.PostProcessQueue) ~= "table" or #pending.PostProcessQueue == 0 then return end
    local now = os.clock()
    if now < (tonumber(pending.PostProcessRetryAt) or 0) then return end
    pending.PostProcessAttempt = (tonumber(pending.PostProcessAttempt) or 0) + 1
    pending.PostProcessWindowStartedAt = tonumber(pending.PostProcessWindowStartedAt) or now
    if pending.PostProcessWindowStartedAt <= 0 then pending.PostProcessWindowStartedAt = now end
    pending.PostProcessStarted = true
    pending.PostProcessStartedAt = now
    pending.PostProcessDeadlineAt = now + POST_PROCESS_TIMEOUT
    pending.PostProcessWaits = 0
    pending.PostProcessFailure = nil
    setStatus(state, context, string.format(
        "Auto Egg v%s | Game Auto Delete started for %s.\n"
            .. "Protected recovery window: up to %ds | no second egg request can overlap it",
        MODULE_VERSION, requestLabel(pending), NETWORK_RETRY_WINDOW
    ))
    pending.PostProcessThread = task.spawn(function()
        if not state.Running or state.Pending ~= pending then return end
        local failure
        local notes = {}
        while state.Running and state.Pending == pending do
            local batch = table.remove(pending.PostProcessQueue, 1)
            if not batch then break end
            local result = table.pack(pcall(runHeadlessAutoDelete, state, context, pending, batch.Pets))
            if not state.Running or state.Pending ~= pending then return end
            if not result[1] then
                failure = "Game Auto Delete bridge crashed locally: " .. tostring(result[2])
            elseif not result[2] then
                failure = tostring(result[3])
            else
                notes[#notes + 1] = tostring(result[3])
            end
            if failure then
                table.insert(pending.PostProcessQueue, 1, batch)
                break
            end
        end
        pending.PostProcessThread = nil
        if not failure then
            pending.PostProcessNote = table.concat(notes, " | ")
            pending.PostProcessStarted = false
            pending.PostProcessDone = true
            return
        end

        local elapsed = os.clock() - pending.PostProcessWindowStartedAt
        if retryablePostProcessFailure(failure)
            and pending.PostProcessAttempt < MAX_POST_PROCESS_ATTEMPTS
            and elapsed < NETWORK_RETRY_WINDOW then
            local delay = boundedRetryDelay(
                pending.PostProcessAttempt + 1,
                POST_PROCESS_RETRY_BASE_DELAY,
                POST_PROCESS_RETRY_MAX_DELAY
            )
            pending.PostProcessStarted = false
            pending.PostProcessRetryAt = os.clock() + delay
            pending.PostProcessLastProblem = failure
            state.PostProcessRetries = state.PostProcessRetries + 1
            setStatus(state, context, string.format(
                "Poor connection recovery: Game Auto Delete attempt %d/%d failed.\n"
                    .. "Retrying the same hatch post-processing in %.2fs; no new egg request is allowed.",
                pending.PostProcessAttempt, MAX_POST_PROCESS_ATTEMPTS, delay
            ))
            return
        end

        pending.PostProcessStarted = false
        pending.PostProcessFailure = failure
    end)
end

local function resolveOpeningEggAckRemote(state, context)
    local cached = state.OpeningEggAckRemote
    if typeof(cached) == "Instance" and cached:IsA("RemoteEvent")
        and cached:IsDescendantOf(game:GetService("ReplicatedStorage")) then
        return cached
    end
    state.OpeningEggAckRemote = nil

    local now = os.clock()
    if now < (tonumber(state.NextOpeningEggAckResolveAt) or 0) then return nil end
    state.NextOpeningEggAckResolveAt = now + 30

    local called, remote, sourceName, sessionIndex, problem =
        pcall(context.GetFireRemote, "Opening Egg")
    if called and typeof(remote) == "Instance" and remote:IsA("RemoteEvent")
        and remote:IsDescendantOf(game:GetService("ReplicatedStorage")) then
        state.OpeningEggAckRemote = remote
        state.OpeningEggAckRoute = context.RouteText(sourceName, sessionIndex)
        state.OpeningEggAckProblem = nil
        return remote
    end

    state.OpeningEggAckProblem = tostring(called and problem or remote)
    return nil
end

local function acknowledgeOpeningEgg(state, context, eggName, pets)
    local remote = resolveOpeningEggAckRemote(state, context)
    if remote then
        local sent, problem = pcall(function()
            remote:FireServer(eggName, pets)
        end)
        if sent then
            state.OpeningEggAcks = (tonumber(state.OpeningEggAcks) or 0) + 1
            return true, state.OpeningEggAckRoute
        end
        state.OpeningEggAckRemote = nil
        state.OpeningEggAckProblem = tostring(problem)
        state.NextOpeningEggAckResolveAt = os.clock() + 30
    end

    -- openegggg is the authoritative server hatch event and already carries
    -- the exact pets. Some Network4 sessions expose no separate Opening Egg
    -- RemoteEvent until the native RobloxScript callback runs. Calling the
    -- named Network.Fire fallback from an injected callback now raises
    -- "Cannot require a non-RobloxScript module from a RobloxScript". Do not
    -- call that fallback and do not stop a confirmed purchase because an
    -- optional client acknowledgement route is unavailable.
    state.OpeningEggAckBypassed = (tonumber(state.OpeningEggAckBypassed) or 0) + 1
    if not state.OpeningEggAckBypassTraced then
        state.OpeningEggAckBypassTraced = true
        context.Trace("auto egg Opening Egg ACK",
            "direct hashed RemoteEvent unavailable; server openegggg event is authoritative | "
                .. tostring(state.OpeningEggAckProblem or "route absent"))
    end
    return true, "server openegggg event (no named Network.Fire fallback)"
end

local function startHeadlessReconcile(state, context, pending)
    if pending.ReconcileStarted or not pending.Headless or pending.EventReceived then return end
    local now = os.clock()
    if now < (tonumber(pending.ReconcileRetryAt) or 0) then return end
    pending.ReconcileStarted = true
    pending.ReconcileDone = false
    pending.ReconcileAttempt = (tonumber(pending.ReconcileAttempt) or 0) + 1
    pending.ReconcileWindowStartedAt = tonumber(pending.ReconcileWindowStartedAt) or now
    if pending.ReconcileWindowStartedAt <= 0 then pending.ReconcileWindowStartedAt = now end
    pending.ReconcileStartedAt = now

    pending.ReconcileThread = task.spawn(function()
        local expected = pending.Triple and 3 or 1
        local deadline = os.clock() + HEADLESS_REPLICATION_TIMEOUT
        local lastObserved = 0

        repeat
            if not state.Running or state.Pending ~= pending or pending.EventReceived then return end

            local pets, observed, problem = petsAddedSince(context, pending.PetSnapshot, expected)
            lastObserved = tonumber(observed) or lastObserved
            pending.InventoryDeltaSeen = lastObserved
            if problem then
                pending.ReconcileFailure = problem
                pending.ReconcileDone = true
                return
            end
            if pets then
                pending.Pets = pets
                pending.EventReceived = true
                pending.EventAt = os.clock()
                pending.MatchMode = "inventory delta auto-detection"

                local acknowledged, ackProblem =
                    acknowledgeOpeningEgg(state, context, pending.Egg, pets)
                if not acknowledged then
                    pending.AckFailure = tostring(ackProblem)
                    pending.ReconcileDone = true
                    return
                end

                pending.Acknowledged = true
                pending.ReconcileDone = true
                pending.ReconcileThread = nil
                state.AcknowledgedEvents[eventSignature(pending.Egg, pets)] = os.clock()
                context.Trace("auto egg headless reconcile", string.format(
                    "%s | observed %d/%d new pet(s) | Opening Egg acknowledged from inventory delta",
                    requestLabel(pending), lastObserved, expected
                ))
                queueHeadlessPostProcess(pending, pending.Egg, pets)
                startHeadlessPostProcess(state, context, pending)
                return
            end
            task.wait(HEADLESS_REPLICATION_POLL)
        until os.clock() >= deadline

        if state.Running and state.Pending == pending and not pending.EventReceived then
            pending.ReconcileThread = nil
            local problem = string.format(
                "Server accepted %s, but only %d/%d new pet(s) appeared in the replicated inventory within %.1fs",
                requestLabel(pending), lastObserved, expected, HEADLESS_REPLICATION_TIMEOUT
            )
            pending.ReconcileDone = true
            pending.ReconcileStarted = false
            if not pending.ResponseDone then
                pending.ReconcileRetryAt = math.huge
                pending.ReconcileLastProblem = problem
                return
            end

            local elapsed = os.clock() - pending.ReconcileWindowStartedAt
            if pending.ReconcileAttempt < MAX_NETWORK_ATTEMPTS
                and elapsed < NETWORK_RETRY_WINDOW then
                local delay = boundedRetryDelay(
                    pending.ReconcileAttempt + 1,
                    NETWORK_RETRY_BASE_DELAY,
                    NETWORK_RETRY_MAX_DELAY
                )
                pending.ReconcileRetryAt = os.clock() + delay
                pending.ReconcileLastProblem = problem
                state.ReconcileRetries = state.ReconcileRetries + 1
                return
            end
            pending.ReconcileFailure = problem
        end
    end)
end

local function completionNote(pending)
    local notes = {}
    if pending.Route and pending.Route ~= "" then notes[#notes + 1] = pending.Route end
    if pending.Headless then
        notes[#notes + 1] = "Egg Skip: immediate headless acknowledgement"
        if pending.ProducerGateRoute == HEADLESS_INVENTORY_FALLBACK then
            notes[#notes + 1] = "Headless visuals: native OpenEgg was not exported; inventory-delta fallback used"
        else
            notes[#notes + 1] = pending.VisualSuppressed
                and "Headless visuals: OpenEgg producer suppressed"
                or "Headless visuals: producer gate armed; native callback was not observed"
        end
        if pending.MatchMode then notes[#notes + 1] = pending.MatchMode end
        if (tonumber(pending.OverlapEvents) or 0) > 0 then
            notes[#notes + 1] = string.format(
                "manual/overlap events serialized: %d",
                tonumber(pending.OverlapEvents) or 0
            )
        end
        if pending.PostProcessNote then notes[#notes + 1] = pending.PostProcessNote end
    else
        notes[#notes + 1] = pending.SkipResult or pending.SkipPolicy
            or "Game Egg Skip: not requested"
        notes[#notes + 1] = "Game Auto Delete: handled by the native egg callback"
    end
    return table.concat(notes, " | ")
end

local function finishSuccess(state, context, pending, note)
    if state.Pending ~= pending then return end
    clearPendingThreads(pending)
    releaseHeadlessGate(state, context)
    releaseInventoryOperation(state, context)
    state.Pending = nil
    state.Successes = state.Successes + 1
    rememberResponse(state, pending)
    if type(context.InventoryChanged) == "function" then
        pcall(context.InventoryChanged)
    end
    state.ConsecutiveFailures = 0
    local options = timingOptions(context)
    state.DelayMode = options.DelayMode
    state.ManualDelay = options.ManualDelay
    state.CleanSuccesses = state.CleanSuccesses + 1
    resetNetworkRetry(state)
    if state.DelayMode == "Manual" then
        state.RequestDelay = state.ManualDelay
        state.LastAdjustmentReason = "manual delay after completed hatch"
    elseif state.CleanSuccesses >= 8 then
        state.CleanSuccesses = 0
        state.RequestDelay = math.max(MIN_REQUEST_DELAY, state.RequestDelay - 0.025)
        state.LastAdjustmentReason = "clean streak reduced adaptive delay"
        local store, jobId = learnedDelayStore()
        store[jobId] = state.RequestDelay
    end
    local completedAt = os.clock()
    if state.DelayMode == "Manual" then
        -- Manual means an exact post-completion pause. Starting it at the
        -- request/ACK timestamp silently shortens the configured delay when
        -- native post-processing takes time.
        state.NextAction = completedAt + state.RequestDelay
    else
        local pacingAnchor = math.max(
            tonumber(pending.ResponseAt) or 0,
            tonumber(pending.EventAt) or 0,
            tonumber(pending.StartedAt) or 0
        )
        state.NextAction = math.max(completedAt, pacingAnchor + state.RequestDelay)
    end
    setStatus(state, context, string.format(
        "Hatched %s | completed: %d\n%s | %s delay: %.2fs | response p50/p95 %.2f/%.2fs | clean streak %d | %s",
        requestLabel(pending),
        state.Successes,
        tostring(note or pending.Route or "Open Egg event confirmed"),
        string.lower(state.DelayMode), state.RequestDelay,
        state.ResponseP50, state.ResponseP95, state.CleanSuccesses,
        state.LastAdjustmentReason
    ))
end

local function headlessEventsSettled(pending, now)
    local anchor = math.max(
        tonumber(pending.LastHeadlessEventAt) or 0,
        tonumber(pending.ResponseAt) or 0,
        tonumber(pending.EventAt) or 0
    )
    return anchor <= 0 or now - anchor >= HEADLESS_EVENT_SETTLE_DELAY
end

local function finishRejection(state, context, pending)
    if state.Pending ~= pending then return end
    clearPendingThreads(pending)
    releaseHeadlessGate(state, context)
    releaseInventoryOperation(state, context)
    state.Pending = nil
    state.Rejections = state.Rejections + 1
    state.ConsecutiveFailures = state.ConsecutiveFailures + 1
    state.CleanSuccesses = 0
    resetNetworkRetry(state)
    local options = timingOptions(context)
    state.DelayMode = options.DelayMode
    state.ManualDelay = options.ManualDelay
    if state.DelayMode == "Manual" then
        state.RequestDelay = state.ManualDelay
        state.LastAdjustmentReason = "server reject; manual delay retained"
    else
        state.RequestDelay = math.min(MAX_REQUEST_DELAY, math.max(0.25, state.RequestDelay * 1.65))
        state.LastAdjustmentReason = "server reject increased adaptive delay"
        local store, jobId = learnedDelayStore()
        store[jobId] = state.RequestDelay
    end
    local message = tostring(pending.Message or "server rejected the purchase")
    local suspicious = suspiciousReply(message)
    local pause = suspicious and SUSPICIOUS_PAUSE
        or (state.ConsecutiveFailures >= 3 and 15 or state.RequestDelay)
    state.SuspendedUntil = (suspicious or state.ConsecutiveFailures >= 3) and (os.clock() + pause) or 0
    state.NextAction = os.clock() + pause
    setStatus(state, context, string.format(
        "Server rejected %s: %s\nNo retry overlap | next local attempt in %.1fs | rejects: %d",
        requestLabel(pending), message, pause, state.Rejections
    ))
end

local function stopForSafety(state, context, pending, reason)
    if pending and state.Pending ~= pending then return end
    clearPendingThreads(pending)
    releaseHeadlessGate(state, context)
    releaseInventoryOperation(state, context)
    state.Pending = nil
    state.Running = false
    reason = tostring(reason or "auto egg safety stop")
    setStatus(state, context, reason)
    context.Trace("auto egg safety stop", reason)
    context.Disable(reason)
end

local function finishTransportFailure(state, context, pending)
    if state.Pending ~= pending then return end
    local now = os.clock()
    local attempt = tonumber(pending.Attempt) or tonumber(state.NetworkAttempt) or 1
    local startedAt = tonumber(state.NetworkWindowStartedAt) or pending.StartedAt or now
    local elapsed = now - startedAt
    local problem = tostring(pending.Message or "transport error")

    if attempt >= MAX_NETWORK_ATTEMPTS or elapsed >= NETWORK_RETRY_WINDOW then
        state.NetworkFailures = state.NetworkFailures + 1
        stopForSafety(state, context, pending, string.format(
            "Auto hatch stopped after %d/%d connection attempts for %s.\n"
                .. "Last transport error: %s | retry window: %.0fs",
            attempt, MAX_NETWORK_ATTEMPTS, requestLabel(pending), problem, elapsed
        ))
        return
    end

    clearPendingThreads(pending)
    releaseHeadlessGate(state, context)
    releaseInventoryOperation(state, context)
    state.Pending = nil
    state.NetworkAttempt = attempt + 1
    state.NetworkRetries = state.NetworkRetries + 1
    state.CleanSuccesses = 0
    local remaining = math.max(0, NETWORK_RETRY_WINDOW - elapsed)
    local delay = math.min(
        tonumber(NETWORK_RETRY_DELAYS[attempt]) or NETWORK_RETRY_MAX_DELAY,
        remaining
    )
    state.NextAction = now + delay
    setStatus(state, context, string.format(
        "Poor connection recovery: %s attempt %d/%d ended with a transport error.\n"
            .. "Retry %d/%d in %.2fs | one request in flight | no blind overlap\n%s",
        requestLabel(pending), attempt, MAX_NETWORK_ATTEMPTS,
        state.NetworkAttempt, MAX_NETWORK_ATTEMPTS, delay, problem
    ))
end

local function finishTimeout(state, context, pending)
    if state.Pending ~= pending then return end
    state.Timeouts = state.Timeouts + 1
    state.CleanSuccesses = 0

    if not pending.ResponseDone then
        local now = os.clock()
        pending.ResponseWaits = (tonumber(pending.ResponseWaits) or 0) + 1
        local elapsed = now - pending.StartedAt
        if pending.Headless and not pending.EventReceived and not pending.ReconcileStarted then
            pending.ReconcileRetryAt = now
            startHeadlessReconcile(state, context, pending)
        end
        if pending.ResponseWaits < MAX_RESPONSE_WAIT_SLICES
            and elapsed < NETWORK_RETRY_WINDOW then
            local remaining = NETWORK_RETRY_WINDOW - elapsed
            pending.ResponseDeadlineAt = now + math.min(RESPONSE_WAIT_SLICE, remaining)
            setStatus(state, context, string.format(
                "Poor connection recovery: Buy Egg Yay is still waiting for %s.\n"
                    .. "Response check %d/%d | elapsed %.1fs/%.0fs | no duplicate request sent",
                requestLabel(pending), pending.ResponseWaits, MAX_RESPONSE_WAIT_SLICES,
                elapsed, NETWORK_RETRY_WINDOW
            ))
            return
        end

        stopForSafety(state, context, pending, string.format(
            "Buy Egg Yay did not return after %d response checks (%.1fs) for %s.\n"
                .. "Auto hatch stopped after the bounded poor-connection window; no request overlapped it.",
            pending.ResponseWaits, elapsed, requestLabel(pending)
        ))
        return
    end

    local observations = string.format(
        "response accepted=%s | Open Egg events=%d | inventory delta=%d | native OpeningEgg seen=%s",
        tostring(pending.Accepted),
        tonumber(pending.OpenEventsSeen) or 0,
        tonumber(pending.InventoryDeltaSeen) or 0,
        tostring(pending.NativeOpeningSeen == true)
    )
    stopForSafety(state, context, pending,
        "Timed out after an accepted/unknown egg request: " .. requestLabel(pending)
        .. "\n" .. observations
        .. "\nAuto hatch stopped; the request will not be repeated blindly.")
end

local function handlePending(state, context, now)
    local pending = state.Pending
    if not pending then return false end

    local openingNow = openingFlag(context)
    if not pending.Headless and openingNow then
        pending.NativeOpeningSeen = true
        pending.NativeOpeningAt = pending.NativeOpeningAt or now
    end

    if pending.AckFailure then
        stopForSafety(state, context, pending,
            "Opening Egg acknowledgement failed; auto hatch stopped without sending a duplicate: "
            .. tostring(pending.AckFailure))
        return true
    end

    if pending.PostProcessFailure then
        stopForSafety(state, context, pending,
            "Auto hatch stopped because the game Auto Delete settings could not be applied safely: "
            .. tostring(pending.PostProcessFailure))
        return true
    end

    if pending.ReconcileFailure then
        stopForSafety(state, context, pending,
            "Headless hatch could not be confirmed safely: " .. tostring(pending.ReconcileFailure)
            .. "\nNo duplicate egg request was sent.")
        return true
    end

    if pending.Headless and pending.EventReceived and pending.Acknowledged and pending.Pets
        and not pending.PostProcessDone and not pending.PostProcessStarted
        and now >= (tonumber(pending.PostProcessRetryAt) or 0) then
        startHeadlessPostProcess(state, context, pending)
    end

    if pending.PostProcessStarted and not pending.PostProcessDone
        and now >= (tonumber(pending.PostProcessDeadlineAt)
            or ((tonumber(pending.PostProcessStartedAt) or now) + POST_PROCESS_TIMEOUT)) then
        pending.PostProcessWaits = (tonumber(pending.PostProcessWaits) or 0) + 1
        local elapsed = now - (tonumber(pending.PostProcessWindowStartedAt)
            or pending.PostProcessStartedAt or now)
        if pending.PostProcessWaits < MAX_POST_PROCESS_WAIT_SLICES
            and elapsed < NETWORK_RETRY_WINDOW then
            pending.PostProcessDeadlineAt = now
                + math.min(POST_PROCESS_WAIT_SLICE, NETWORK_RETRY_WINDOW - elapsed)
            setStatus(state, context, string.format(
                "Poor connection recovery: Game Auto Delete is still processing %s.\n"
                    .. "Post-process check %d/%d | attempt %d/%d | no new egg request sent",
                requestLabel(pending), pending.PostProcessWaits, MAX_POST_PROCESS_WAIT_SLICES,
                tonumber(pending.PostProcessAttempt) or 1, MAX_POST_PROCESS_ATTEMPTS
            ))
            return true
        end

        stopForSafety(state, context, pending, string.format(
            "Auto hatch stopped after %d bounded Game Auto Delete response checks for %s.\n"
                .. "The post-processing call remained in flight; no second egg request was sent.",
            pending.PostProcessWaits, requestLabel(pending)
        ))
        return true
    end

    if not pending.Headless and pending.NativeOpeningSeen and not openingNow then
        finishSuccess(state, context, pending, completionNote(pending))
        return true
    end

    if pending.Headless and pending.ResponseDone and pending.Accepted
        and not pending.EventReceived and not pending.ReconcileStarted
        and now >= (tonumber(pending.ReconcileRetryAt) or 0) then
        startHeadlessReconcile(state, context, pending)
    end

    if pending.EventReceived then
        if pending.Accepted or pending.Acknowledged or pending.NativeOpeningSeen
            or not pending.Headless then
            if pending.Headless then
                if pending.Acknowledged and not pending.PostProcessStarted and pending.Pets then
                    startHeadlessPostProcess(state, context, pending)
                end
                if pending.Acknowledged and pending.PostProcessDone then
                    if pending.ProducerGateRoute == HEADLESS_INVENTORY_FALLBACK and openingNow then
                        setStatus(state, context, "Native compatibility callback is finishing for "
                            .. requestLabel(pending)
                            .. "; acknowledgement and Auto Delete are not being duplicated...")
                    elseif not headlessEventsSettled(pending, now) then
                        setStatus(state, context, "Headless hatch completed for " .. requestLabel(pending)
                            .. "; holding the producer gate briefly for a manual/duplicate event...")
                    else
                        finishSuccess(state, context, pending, completionNote(pending))
                    end
                elseif pending.Acknowledged then
                    setStatus(state, context, "Headless hatch acknowledged for " .. requestLabel(pending)
                        .. "; applying the game's Auto Delete settings before the next purchase...")
                end
            elseif not openingNow then
                finishSuccess(state, context, pending, completionNote(pending))
            else
                setStatus(state, context, "Native animation is finishing for " .. requestLabel(pending)
                    .. "; the next purchase remains locked...\n"
                    .. tostring(pending.SkipResult or pending.SkipPolicy or "Reading the game Egg Skip setting..."))
            end
        else
            finishRejection(state, context, pending)
        end
        return true
    end

    if pending.ResponseDone and not pending.Accepted and not pending.EventReceived
        and not pending.NativeOpeningSeen then
        if pending.TransportOk == false then
            finishTransportFailure(state, context, pending)
        else
            finishRejection(state, context, pending)
        end
        return true
    end

    if now >= (tonumber(pending.ResponseDeadlineAt)
        or (pending.StartedAt + pending.TimeoutSeconds)) then
        finishTimeout(state, context, pending)
        return true
    end

    if not pending.Headless and pending.NativeOpeningSeen and openingNow then
        setStatus(state, context, "Native egg animation is active for " .. requestLabel(pending)
            .. "; completion is tracked by Library.Variables.OpeningEgg.\n"
            .. tostring(pending.SkipResult or pending.SkipPolicy or "Fast skip watcher is armed..."))
    elseif pending.EventReceived and not pending.ResponseDone then
        setStatus(state, context, "Open Egg received for " .. requestLabel(pending)
            .. "; waiting for the single Buy Egg Yay call to return...")
    elseif pending.Headless and pending.ResponseDone and pending.Accepted and not pending.EventReceived then
        local expected = pending.Triple and 3 or 1
        setStatus(state, context, string.format(
            "Headless purchase accepted for %s; confirming the replicated inventory delta...\n"
                .. "Observed: %d/%d new pet(s) | no duplicate request is allowed",
            requestLabel(pending), tonumber(pending.InventoryDeltaSeen) or 0, expected
        ))
    elseif pending.ResponseDone and pending.Accepted and not pending.EventReceived then
        setStatus(state, context, "Buy Egg Yay accepted for " .. requestLabel(pending)
            .. "; waiting for native OpeningEgg or its matching Open Egg event...\n"
            .. tostring(pending.SkipResult or pending.SkipPolicy or "Fast skip watcher is armed..."))
    end
    return true
end

local function beginRequest(state, context, options, inspection)
    -- The game has its own gamepass Auto Hatch (Library.Variables.AutoHatchEnabled,
    -- persisted via AutoHatchSettings.Enabled). While it is on, the game buys the
    -- same egg in parallel: the player sees duplicate UI opens and our purchase is
    -- server-rejected with "Something went wrong" (funds/overlap), which inflates
    -- the adaptive delay. Neutralize the native buyer before every purchase.
    local variables = context.Library and context.Library.Variables
    if variables and variables.AutoHatchEnabled == true then
        pcall(function() variables.AutoHatchEnabled = false end)
        if not state.NativeAutoHatchReported then
            state.NativeAutoHatchReported = true
            context.Trace("auto egg native autohatch",
                "game Auto Hatch was enabled; disabled to prevent duplicate purchases")
        end
    end
    -- The same Auto Hatch also exists server-side (save.AutoHatchSettings.Enabled)
    -- and is flipped through the "Toggle Auto Hatch Setting" command with a
    -- settings key. While enabled, the SERVER hatches on its own cadence and
    -- every manual Egg: Buy Egg fails with "Something went wrong": the client
    -- sees steady native opens plus periodic rejections. The command is a
    -- toggle, not a set, so fire only while the save still reports Enabled.
    local save = saveFor(context)
    local autoHatchSettings = type(save) == "table" and save.AutoHatchSettings or nil
    -- Diagnose every cycle in the status line: if the save never reports the
    -- setting, or the toggle route fails, the duplicate buyer keeps hatching
    -- and we need to see it instead of assuming the disable worked.
    if not state.ServerAutoHatchStateLogged then
        state.ServerAutoHatchStateLogged = true
        context.Trace("auto egg native autohatch", "save.AutoHatchSettings = "
            .. tostring(autoHatchSettings and autoHatchSettings.Enabled))
    end
    if type(autoHatchSettings) == "table" and autoHatchSettings.Enabled == true
        and type(context.FireCommand) == "function" then
        local now = os.clock()
        if now - (tonumber(state.ServerAutoHatchToggleAt) or 0) >= 30 then
            state.ServerAutoHatchToggleAt = now
            local called, accepted, problem = pcall(context.FireCommand, "Toggle Auto Hatch Setting", "Enabled")
            context.Trace("auto egg native autohatch",
                "server-side Auto Hatch is enabled; Toggle Auto Hatch Setting sent"
                    .. " | called=" .. tostring(called)
                    .. " | accepted=" .. tostring(accepted)
                    .. " | problem=" .. tostring(problem))
        end
    end
    local headless = options.Animation == "Headless (No Animation)"
    local retryKey = requestRetryKey(options.Egg, options.Count, options.Animation)
    if headless then
        reconcileEggWorldVisualGate(state, context, true)
        local producerReady, producerProblem = ensureHeadlessProducerGate(state, context)
        if not producerReady then
            state.NextAction = os.clock() + LOCAL_RECHECK_DELAY
            setStatus(state, context, "Headless preflight is waiting locally: "
                .. tostring(producerProblem) .. "\nNo purchase request was sent.")
            return
        end
    end
    local operationAcquired, operationOwner = acquireInventoryOperation(state, context)
    if not operationAcquired then
        state.NextAction = os.clock() + LOCAL_RECHECK_DELAY
        setStatus(state, context, "Ready, but the pet inventory is reserved by "
            .. tostring(operationOwner) .. ".\nNo egg request was sent.")
        return
    end

    local headlessSnapshot
    if headless then
        local snapshotProblem
        headlessSnapshot, snapshotProblem = ownedPetSnapshot(context)
        if not headlessSnapshot then
            releaseInventoryOperation(state, context)
            state.NextAction = os.clock() + LOCAL_RECHECK_DELAY
            setStatus(state, context, "Headless preflight is waiting locally: " .. tostring(snapshotProblem)
                .. "\nNo purchase request was sent.")
            return
        end
        local acquired, problem = acquireHeadlessGate(state, context)
        if not acquired then
            releaseInventoryOperation(state, context)
            state.NextAction = os.clock() + LOCAL_RECHECK_DELAY
            setStatus(state, context, "Ready, but waiting locally: " .. tostring(problem)
                .. "\nNo purchase request was sent.")
            return
        end
    elseif openingFlag(context) then
        releaseInventoryOperation(state, context)
        state.NextAction = os.clock() + LOCAL_RECHECK_DELAY
        setStatus(state, context, "Waiting for the current native egg animation to finish.\nNo purchase request was sent.")
        return
    end

    if not state.Running or not context.Running() or not context.Enabled() then
        releaseHeadlessGate(state, context)
        releaseInventoryOperation(state, context)
        return
    end

    if state.NetworkRetryKey ~= retryKey then
        resetNetworkRetry(state)
        state.NetworkRetryKey = retryKey
        state.NetworkWindowStartedAt = os.clock()
    elseif (tonumber(state.NetworkWindowStartedAt) or 0) <= 0 then
        state.NetworkWindowStartedAt = os.clock()
    end

    local pending = {
        Egg = options.Egg,
        Triple = options.Count == 3,
        Headless = headless,
        StartedAt = os.clock(),
        TimeoutSeconds = headless and HEADLESS_EVENT_TIMEOUT or NATIVE_EVENT_TIMEOUT,
        ResponseDeadlineAt = 0,
        ResponseWaits = 0,
        ResponseDone = false,
        Accepted = false,
        EventReceived = false,
        Acknowledged = false,
        Pets = nil,
        PostProcessStarted = false,
        PostProcessDone = not headless,
        PostProcessFailure = nil,
        SkipScheduled = false,
        SkipSent = false,
        NativeOpeningSeen = false,
        OpenEventsSeen = 0,
        PetSnapshot = headlessSnapshot,
        InventoryDeltaSeen = 0,
        ReconcileStarted = false,
        ReconcileDone = false,
        ReconcileFailure = nil,
        ReconcileAttempt = 0,
        ReconcileRetryAt = 0,
        ReconcileWindowStartedAt = 0,
        ReconcileThread = nil,
        PostProcessAttempt = 0,
        PostProcessRetryAt = 0,
        PostProcessWindowStartedAt = 0,
        PostProcessWaits = 0,
        PostProcessThread = nil,
        PostProcessQueue = {},
        PostProcessSignatures = {},
        OverlapEvents = 0,
        LastHeadlessEventAt = 0,
        RequestThread = nil,
        Attempt = tonumber(state.NetworkAttempt) or 1,
        InputConnections = (not headless
            or state.OpenEggGateRoute == HEADLESS_INVENTORY_FALLBACK)
            and inputConnectionSnapshot(context) or nil,
        Inspection = inspection,
        VisualSuppressed = false,
        NativeOpenEggSeen = false,
        ProducerGateRoute = headless and state.OpenEggGateRoute or nil,
    }
    pending.ResponseDeadlineAt = pending.StartedAt + pending.TimeoutSeconds
    state.Pending = pending
    state.Requests = state.Requests + 1
    if not headless or pending.ProducerGateRoute == HEADLESS_INVENTORY_FALLBACK then
        armNativeSkip(state, context, pending)
    end
    setStatus(state, context, string.format(
        "Sending Buy Egg Yay: %s | connection attempt %d/%d\n"
            .. "Distance: %.1f/15 | request #%d | one request in flight | dynamic Network route\n%s",
        requestLabel(pending), pending.Attempt, MAX_NETWORK_ATTEMPTS,
        tonumber(inspection.Distance) or 0, state.Requests,
        headless and ("Headless acknowledgement route: "
            .. tostring(pending.ProducerGateRoute or "exact inventory delta"))
            or tostring(pending.SkipPolicy or "Native skip watcher is preparing...")
    ))

    pending.RequestThread = task.spawn(function()
        if state.Pending ~= pending or not state.Running then return end
        local result = table.pack(context.InvokeCommand("Buy Egg Yay", pending.Egg, pending.Triple))
        if state.Pending ~= pending or not state.Running then return end
        pending.RequestThread = nil
        pending.ResponseDone = true
        pending.ResponseAt = os.clock()
        pending.TransportOk = result[1] == true
        pending.Accepted = pending.TransportOk and result[2] == true
        pending.Message = result[3]
        pending.Route = context.RouteText(result[4], result[5])
        if not pending.TransportOk then
            pending.Accepted = false
            pending.Message = "transport error: " .. tostring(result[3])
        end
        if pending.Headless and pending.Accepted and not pending.EventReceived
            and pending.ReconcileRetryAt == math.huge then
            -- The first inventory-delta pass may finish while InvokeServer is
            -- still yielding. Re-arm it as soon as that same request returns;
            -- this does not create another purchase.
            pending.ReconcileRetryAt = os.clock()
        end
    end)
end

local function runCycle(state, context)
    local now = os.clock()
    reconcileEggWorldVisualGate(state, context, false)
    if handlePending(state, context, now) then return end
    releaseHeadlessGate(state, context)
    releaseInventoryOperation(state, context)
    if now < state.NextAction then return end

    if state.SuspendedUntil > now then
        state.NextAction = state.SuspendedUntil
        setStatus(state, context, string.format(
            "Safety pause after a rate-limit style reply: %.0fs remaining.\nNo purchase requests are being sent.",
            state.SuspendedUntil - now
        ))
        return
    end
    state.SuspendedUntil = 0

    local options = timingOptions(context)
    if type(options) ~= "table" or type(options.Egg) ~= "string" or options.Egg == "" then
        state.NextAction = now + LOCAL_RECHECK_DELAY
        setStatus(state, context, "Select a hatchable egg. No purchase request was sent.")
        return
    end
    options.Count = tonumber(options.Count) == 3 and 3 or 1
    state.DelayMode = options.DelayMode
    state.ManualDelay = options.ManualDelay

    local ready, inspection = context.InspectEgg(options.Egg, options.Count)
    if not ready then
        state.NextAction = now + LOCAL_RECHECK_DELAY
        setStatus(state, context, tostring(inspection)
            .. "\nLocal preflight blocked Buy Egg Yay; zero requests sent.")
        return
    end
    beginRequest(state, context, options, inspection)
end

local function stopState(state, context)
    if not state then return true end
    state.Running = false
    state.Generation = (tonumber(state.Generation) or 0) + 1
    local pending = state.Pending
    state.Pending = nil
    if type(pending) == "table" then
        clearPendingThreads(pending)
        pending.PetSnapshot = nil
        pending.InputConnections = nil
        pending.Pets = nil
    end
    releaseHeadlessGate(state, context)
    releaseInventoryOperation(state, context)
    restoreHeadlessProducerGate(state)
    restoreEggWorldVisualGate(state, context, false)
    pcall(context.CancelOperation, context.OperationOwner)
    if state.Connection and type(state.Connection.Disconnect) == "function" then
        pcall(function() state.Connection:Disconnect() end)
    end
    state.Connection = nil
    table.clear(state.AcknowledgedEvents)
    clearPhysicalBindings(true)
    local worker = state.WorkerThread
    state.WorkerThread = nil
    if worker and worker ~= coroutine.running() and type(task.cancel) == "function" then
        pcall(task.cancel, worker)
    end
    if activeState == state then activeState = nil end
    local env = type(getgenv) == "function" and getgenv() or _G
    if env.PSX_OG_FastEggState == state then env.PSX_OG_FastEggState = nil end
    state.Stop = nil
    state.Context = nil
    return true
end

local function stop()
    if activeState then return stopState(activeState, activeState.Context) end
    clearPhysicalBindings(true)
    return true
end

local function workerDelay(state)
    if state.Pending then return 0.05 end
    local remaining = (tonumber(state.NextAction) or 0) - os.clock()
    if remaining <= 0 then return 0.05 end
    return math.clamp(remaining, 0.05, MAX_REQUEST_DELAY)
end

return function(action, context)
    if action == "stop" then return stop() end
    if action == "invalidate-catalog" then
        physicalCache.Dirty = true
        physicalCache.ById = {}
        physicalCache.LastScanAt = -math.huge
        return true
    end
    if action == "catalog" then
        if type(context) ~= "table" or not context.Library then
            return nil, nil, nil, "Egg catalog context is missing Library", {}
        end
        return buildCatalog(context)
    end
    if action == "inspect" then
        if type(context) ~= "table" or not context.Library or type(context.GetCurrency) ~= "function" then
            return false, "Egg inspection context is incomplete"
        end
        return inspectEgg(context)
    end
    if action ~= "start" then return false, "unknown action" end
    if activeState and activeState.Running then return true end
    if type(context) ~= "table" then return false, "module context is missing" end
    for _, key in ipairs({
        "Library", "Running", "Enabled", "GetOptions", "InspectEgg", "InvokeCommand",
        "GetEventRemote", "GetFireRemote",
        "RouteText", "AcquireOperation", "ReleaseOperation", "CancelOperation",
        "OperationOwner", "SetStatus", "Trace", "Disable",
    }) do
        if context[key] == nil then return false, "module context is missing " .. key end
    end

    if not context.Running() or not context.Enabled() then return true end
    local signal, eventRoute, eventIndex, eventCommand, eventProblem =
        resolveOpenEggSignal(context)
    if not signal then
        -- Do not block Buy Egg Yay merely because an executor cannot expose the
        -- inbound dispatcher. Headless still has the OpenEgg producer wrapper
        -- and exact inventory-delta acknowledgement as bounded fallbacks.
        eventRoute = "inventory/native-variable fallback"
        context.Trace("auto egg route",
            "inbound hatch event unavailable; purchase remains enabled: " .. tostring(eventProblem))
    end

    -- Capture the game's exact dispatcher before this module adds its own
    -- listener. When OpenEgg is not exported by getsenv, this lets Headless
    -- pause only the native visual producer for the duration of one purchase.
    local eventGateConnection, eventGateSignal, nativeOpenEggTarget, eventGateProblem
    if signal then
        eventGateConnection, eventGateSignal, nativeOpenEggTarget, eventGateProblem =
            captureHeadlessEventGate(signal, eventRoute, context, openEggScriptFor(context))
        if eventGateSignal then
            signal = eventGateSignal
            eventRoute = tostring(eventGateProblem or eventRoute)
            eventProblem = nil
        end
    else
        eventGateProblem = tostring(eventProblem or "inbound hatch signal unavailable")
    end

    local learnedStore, jobId = learnedDelayStore()
    local initialOptions = timingOptions(context)
    local userId = tonumber(context.UserId) or 0
    local startupPhase = (userId % 16) * 0.03
    local state = {
        Context = context,
        Running = true,
        Generation = 1,
        GateOwned = false,
        OperationOwned = false,
        Pending = nil,
        NextAction = os.clock() + ARM_DELAY + startupPhase,
        RequestDelay = initialOptions.DelayMode == "Manual" and initialOptions.ManualDelay
            or math.clamp(tonumber(learnedStore[jobId]) or INITIAL_REQUEST_DELAY,
                MIN_REQUEST_DELAY, MAX_REQUEST_DELAY),
        DelayMode = initialOptions.DelayMode,
        ManualDelay = initialOptions.ManualDelay,
        LastAdjustmentReason = learnedStore[jobId] and "restored for current JobId"
            or "initial delay",
        ResponseSamples = {}, ResponseP50 = 0, ResponseP95 = 0,
        SuspendedUntil = 0,
        AcknowledgedEvents = {},
        Requests = 0,
        Successes = 0,
        Rejections = 0,
        Timeouts = 0,
        NativeSkips = 0,
        AutoDeleted = 0,
        AutoDeleteBatches = 0,
        OpenEvents = 0,
        CleanSuccesses = 0,
        ConsecutiveFailures = 0,
        NetworkAttempt = 1,
        NetworkRetryKey = nil,
        NetworkWindowStartedAt = 0,
        NetworkRetries = 0,
        NetworkFailures = 0,
        ReconcileRetries = 0,
        PostProcessRetries = 0,
        EventRoute = eventRoute,
        EventCommand = eventCommand,
        EventIndex = eventIndex,
        WorkerThread = nil,
        OpenEggScript = nil,
        OpenEggEnvironment = nil,
        OpenEggOriginal = nil,
        OpenEggWrapper = nil,
        OpenEggGateRoute = nil,
        EventGateConnections = eventGateConnection,
        EventGateConnection = type(eventGateConnection) == "table" and eventGateConnection[1] or nil,
        EventGateProblem = eventGateProblem,
        EventGateDisabled = false,
        NativeOpenEggTarget = nativeOpenEggTarget,
        NativeOpenEggOriginal = nil,
        NativeOpenEggWrapper = nil,
        NativeOpenEggHooked = false,
        OpeningEggAckRemote = nil,
        OpeningEggAckRoute = nil,
        OpeningEggAckProblem = nil,
        OpeningEggAcks = 0,
        OpeningEggAckBypassed = 0,
        OpeningEggAckBypassTraced = false,
        NextOpeningEggAckResolveAt = 0,
        HeadlessVisualsSuppressed = 0,
        EggWorldVisualsSuppressed = 0,
        EggWorldGateRecord = nil,
        HeadlessModeSelected = false,
        EggWorldGateWanted = false,
        EggWorldGateRoute = "visual",
        EggWorldGateProblem = nil,
        NextEggWorldGateCheck = 0,
        NextEggWorldGateTrace = 0,
    }
    activeState = state

    if type(nativeOpenEggTarget) == "function" then
        local hooked, hookProblem = installNativeOpenEggHook(state, context)
        if hooked then
            -- Keep the game's command callback enabled: it still owns the
            -- exact Opening Egg acknowledgement. Only its closed-over visual
            -- renderer is gated, and our listener shares the same stand-in.
            state.EventGateConnections = {}
            state.EventGateConnection = nil
            state.EventGateProblem = nil
        else
            state.EventGateProblem = tostring(hookProblem)
        end
    end

    local connected, connection = true, nil
    if signal then
        connected, connection = pcall(function()
            return signal:Connect(function(eggName, pets)
            if not state.Running or activeState ~= state then return end
            local pending = state.Pending
            state.OpenEvents = state.OpenEvents + 1
            if pending then pending.OpenEventsSeen = pending.OpenEventsSeen + 1 end

            local exactMatch = pending and not pending.EventReceived
                and normalizedEggName(pending.Egg) == normalizedEggName(eggName)
            local matching = exactMatch == true
            local age = pending and (os.clock() - pending.StartedAt) or -1
            local payloadCount = 0
            if type(pets) == "table" then
                for _, pet in pairs(pets) do
                    if type(pet) == "table" and (pet.id ~= nil or pet.ID ~= nil) then
                        payloadCount = payloadCount + 1
                    end
                end
            end
            context.Trace("auto egg Open Egg", string.format(
                "event #%d | expected=%s | actual=%s | firstExactMatch=%s | pets=%d | age=%.2fs",
                state.OpenEvents,
                pending and tostring(pending.Egg) or "none",
                tostring(eggName),
                tostring(matching == true),
                payloadCount,
                age
            ))

            if state.GateOwned then
                local now = os.clock()
                cleanEventCache(state, now)
                local signature = eventSignature(eggName, pets)
                local ownsAcknowledgement = pending and pending.Headless
                    and pending.ProducerGateRoute == HEADLESS_EVENT_GATE
                if ownsAcknowledgement and not state.AcknowledgedEvents[signature] then
                    local ackOk, ackProblem = acknowledgeOpeningEgg(state, context, eggName, pets)
                    if ackOk then
                        state.AcknowledgedEvents[signature] = now
                        if matching then pending.Acknowledged = true end
                    elseif matching then
                        pending.AckFailure = tostring(ackProblem)
                    end
                elseif ownsAcknowledgement and matching then
                    pending.Acknowledged = true
                elseif matching then
                    -- The native callback owns this acknowledgement on the
                    -- getsenv wrapper and compatibility routes. Sending it a
                    -- second time races the game's Auto Delete pipeline.
                    pending.Acknowledged = true
                end
            end

            local queuedPostProcess = false
            if pending and pending.Headless and state.GateOwned and payloadCount > 0 then
                if matching or pending.ProducerGateRoute ~= HEADLESS_INVENTORY_FALLBACK then
                    queuedPostProcess = queueHeadlessPostProcess(pending, eggName, pets)
                    if queuedPostProcess and not matching then
                        pending.OverlapEvents = (tonumber(pending.OverlapEvents) or 0) + 1
                    end
                end
            end

            if matching then
                if pending.Headless
                    and pending.ProducerGateRoute == HEADLESS_INVENTORY_FALLBACK
                    and not pending.SkipSent and not pending.EventSkipQueued then
                    -- The server event can arrive before the worker observes
                    -- Variables.OpeningEgg. Kick the freshly-created native
                    -- InputEnded listener from this exact event edge instead
                    -- of waiting through the visible animation.
                    pending.EventSkipQueued = true
                    task.defer(function()
                        local deadline = os.clock() + NATIVE_SKIP_CONNECTION_WINDOW
                        repeat
                            if not state.Running or state.Pending ~= pending
                                or pending.SkipSent then return end
                            if openingFlag(context) then
                                local sent = sendNativeSkipOnce(
                                    state, context, pending,
                                    tostring(pending.SkipPolicy or "Headless event skip"))
                                if sent then return end
                            end
                            task.wait(0.01)
                        until os.clock() >= deadline
                    end)
                end
                pending.EventReceived = true
                pending.EventAt = os.clock()
                pending.Pets = pets
                if pending.Headless then
                    if pending.Acknowledged and not pending.AckFailure then
                        startHeadlessPostProcess(state, context, pending)
                    end
                end
            elseif state.GateOwned then
                context.Trace("auto egg", "ignored an unrelated/duplicate Open Egg without replacing pending: "
                    .. tostring(eggName))
            end
            if queuedPostProcess and not pending.PostProcessStarted then
                startHeadlessPostProcess(state, context, pending)
            end
            end)
        end)
    end
    if signal and (not connected or not connection) then
        activeState = nil
        return false, "Open Egg listener failed: " .. tostring(connection)
    end
    state.Connection = connection
    reconcileEggWorldVisualGate(state, context, true)

    local env = type(getgenv) == "function" and getgenv() or _G
    state.Stop = function() return stopState(state, context) end
    env.PSX_OG_FastEggState = state
    context.Trace("auto egg module",
        "v" .. MODULE_VERSION
        .. " | bounded poor-connection recovery " .. tostring(MAX_NETWORK_ATTEMPTS)
        .. " attempts/" .. tostring(NETWORK_RETRY_WINDOW)
        .. "s | Native OpeningEgg + producer-gated Headless acknowledgement | inbound hatch event: "
        .. tostring(eventCommand or "inventory fallback") .. " via " .. tostring(eventRoute)
        .. " [session index " .. tostring(eventIndex or "?") .. "]")
    setStatus(state, context,
        "Auto Egg v" .. MODULE_VERSION
        .. " armed. Game Egg Skip and Auto Delete settings are bridged without enabling native Auto Hatch.\n"
        .. "Waiting for a valid egg within 15 studs | poor-connection guard: "
        .. tostring(MAX_NETWORK_ATTEMPTS) .. " bounded attempts over "
        .. tostring(NETWORK_RETRY_WINDOW) .. "s | Egg World: "
        .. tostring(state.EggWorldGateRoute))

    state.WorkerThread = task.spawn(function()
        while state.Running and activeState == state and context.Running() and context.Enabled() do
            local ok, problem = pcall(runCycle, state, context)
            if not ok then
                releaseHeadlessGate(state, context)
                releaseInventoryOperation(state, context)
                state.NextAction = os.clock() + 2
                state.RequestDelay = math.min(MAX_REQUEST_DELAY, math.max(2, state.RequestDelay * 1.5))
                local status = "Auto egg worker recovered from a local error: " .. tostring(problem)
                context.Trace("auto egg", status)
                setStatus(state, context, status .. "\nNo immediate retry; waiting 2 seconds.")
            end
            if state.Running and activeState == state then
                task.wait(workerDelay(state))
            end
        end
        stopState(state, context)
    end)
    return true
end
