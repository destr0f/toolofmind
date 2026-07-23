-- Optional crowded-zone anti-lag controls for PSX OG Slim Farm.
-- Keeps the map and egg stands readable while removing farm-only rendering cost.

local env = type(getgenv) == "function" and getgenv() or _G
local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")
local Terrain = workspace:FindFirstChildOfClass("Terrain")
local state
local profiler
local MODULE_VERSION = "1.0.0"
local PROFILE_MODULE = "graphics"

local URGENT_OBJECT_LIMIT = 224
local NORMAL_OBJECT_LIMIT = 56
local FRAME_TIME_BUDGET = 0.002
local PERSISTENT_OBJECT_LIMIT = 28
local ROOT_REFRESH_INTERVAL = 0.75
local RENDER_REFRESH_INTERVAL = 5

local HIDDEN_THINGS = {
    coins = true,
    pets = true,
    orbs = true,
    lootbags = true,
}

local function profileBegin()
    return profiler and profiler.Begin() or nil
end

local function profileFinish(operation, startedAt)
    if profiler then profiler.Finish(PROFILE_MODULE, operation, startedAt) end
end

local function profileGauge(metric, value)
    if profiler then profiler.Gauge(PROFILE_MODULE, metric, value) end
end

local function profileScanned(amount)
    if profiler then profiler.Scanned(PROFILE_MODULE, amount) end
end

local function profileTemporary(amount)
    if profiler then profiler.Temporary(PROFILE_MODULE, amount) end
end

local function disconnectConnection(connection)
    if connection then pcall(function() connection:Disconnect() end) end
end

local function disconnect(target)
    if type(target) ~= "table" then return end
    target.Running = false
    for _, connection in ipairs(target.Connections or {}) do
        disconnectConnection(connection)
    end
    target.Connections = {}
    target.UrgentQueue = {}
    target.NormalQueue = {}
    target.PersistentSlots = {}
    target.PersistentKinds = {}
    target.PersistentFree = {}
end

local function lowerName(object)
    return string.lower(tostring(object and object.Name or ""))
end

local function inspectTree(object, active)
    local current = object
    local depth = 0
    local category
    local inMap = false
    local inDebris = false
    local eggVisual = false
    local protected = false

    while current and current ~= workspace and current ~= Lighting and depth < 24 do
        local name = lowerName(current)
        -- Keep the target part itself alive, but still suppress emitters parented
        -- under POS. _SELECTIONFX remains fully untouched because the game owns
        -- and reparents that complete subtree.
        if name == "_selectionfx" or (current == object and name == "pos") then protected = true end
        if string.find(name, "egg", 1, true) then eggVisual = true end
        if current == active.Map then inMap = true end
        if current == active.Debris then inDebris = true end
        if current.Parent == active.Things then category = name end
        current = current.Parent
        depth = depth + 1
    end

    return protected, category, inMap, inDebris, eggVisual
end

local function optimizeRendering()
    pcall(function() settings().Rendering.QualityLevel = Enum.QualityLevel.Level01 end)
    pcall(function() settings().Rendering.MeshPartDetailLevel = Enum.MeshPartDetailLevel.Level01 end)
    pcall(function()
        Lighting.GlobalShadows = false
        Lighting.FogStart = 0
        Lighting.FogEnd = 9e9
        Lighting.Brightness = 0
        Lighting.EnvironmentDiffuseScale = 0
        Lighting.EnvironmentSpecularScale = 0
        Lighting.Ambient = Color3.new(1, 1, 1)
        Lighting.OutdoorAmbient = Color3.new(1, 1, 1)
    end)
    if Terrain then
        pcall(function()
            Terrain.WaterWaveSize = 0
            Terrain.WaterWaveSpeed = 0
            Terrain.WaterReflectance = 0
            Terrain.WaterTransparency = 1
            Terrain.Decoration = false
        end)
    end
end

local function registerPersistent(active, object, kind)
    if not active or not active.Running or active.PersistentKinds[object] then return end
    local slot = table.remove(active.PersistentFree)
    if not slot then
        active.PersistentHighWater = active.PersistentHighWater + 1
        slot = active.PersistentHighWater
    end
    active.PersistentSlots[slot] = object
    active.PersistentKinds[object] = { Slot = slot, Kind = kind }
end

local function suppressParticle(object)
    object.Enabled = false
    object.Rate = 0
    object.Lifetime = NumberRange.new(0)
    object.Speed = NumberRange.new(0)
    object.Size = NumberSequence.new(0)
    object.Transparency = NumberSequence.new(1)
    object.LightEmission = 0
    object.LightInfluence = 0
    pcall(function() object:Clear() end)
end

local function suppressPersistent(object, kind)
    if kind == "particle" then
        suppressParticle(object)
    elseif kind == "effect" then
        object.Enabled = false
        if object:IsA("Trail") then pcall(function() object:Clear() end) end
        if object:IsA("Light") then pcall(function() object.Shadows = false end) end
    elseif kind == "gui" then
        object.Enabled = false
    end
end

local function hideVisualPart(object)
    object.LocalTransparencyModifier = 1
    object.CastShadow = false
    object.Reflectance = 0
    object.Material = Enum.Material.Plastic
    object.MaterialVariant = ""
end

local function optimizeObject(object, active)
    if not object then return end
    local protected, category, inMap, inDebris, eggVisual = inspectTree(object, active)
    if protected then
        active.Protected = active.Protected + 1
        return
    end

    local hidden = inDebris or HIDDEN_THINGS[category] == true
    local ok = pcall(function()
        if object:IsA("ParticleEmitter") then
            suppressParticle(object)
            registerPersistent(active, object, "particle")
            active.Effects = active.Effects + 1
            return
        end

        if object:IsA("Beam") or object:IsA("Trail") or object:IsA("Fire")
            or object:IsA("Smoke") or object:IsA("Sparkles") or object:IsA("PostEffect")
            or object:IsA("Highlight") or object:IsA("PointLight")
            or object:IsA("SpotLight") or object:IsA("SurfaceLight")
            or object:IsA("Clouds")
        then
            object.Enabled = false
            if object:IsA("Light") then pcall(function() object.Shadows = false end) end
            if object:IsA("Trail") then pcall(function() object:Clear() end) end
            registerPersistent(active, object, "effect")
            active.Effects = active.Effects + 1
            return
        end

        if object:IsA("BillboardGui") or object:IsA("SurfaceGui") then
            -- Coin health bars and pet labels are a major crowded-zone cost.
            -- Keep map/egg interfaces readable, but never render farm-only GUIs.
            if hidden then
                object.Enabled = false
                registerPersistent(active, object, "gui")
                active.Disabled = active.Disabled + 1
            end
            return
        end

        if object:IsA("PVAdornment") then
            object.Visible = false
            active.Disabled = active.Disabled + 1
            return
        end

        if object:IsA("Decal") or object:IsA("Texture") then
            if hidden then
                object.Transparency = 1
                active.Hidden = active.Hidden + 1
            elseif not eggVisual then
                object:Destroy()
                active.Destroyed = active.Destroyed + 1
            end
            return
        end

        if object:IsA("SurfaceAppearance") then
            if hidden or not eggVisual then
                object:Destroy()
                active.Destroyed = active.Destroyed + 1
            end
            return
        end

        if object:IsA("Sky") then
            object.SkyboxBk, object.SkyboxDn, object.SkyboxFt = "", "", ""
            object.SkyboxLf, object.SkyboxRt, object.SkyboxUp = "", "", ""
            object.SunTextureId, object.MoonTextureId = "", ""
            object.StarCount = 0
            object.CelestialBodiesShown = false
            active.Disabled = active.Disabled + 1
            return
        end

        if object:IsA("Atmosphere") then
            object.Density, object.Haze, object.Glare = 0, 0, 0
            active.Disabled = active.Disabled + 1
            return
        end

        if object:IsA("SpecialMesh") then
            if hidden or not eggVisual then object.TextureId = "" end
            active.Stripped = active.Stripped + 1
            return
        end

        if object:IsA("ForceField") then
            object.Visible = false
            active.Disabled = active.Disabled + 1
            return
        end

        if object:IsA("Explosion") then
            object.Visible = false
            object.BlastPressure = 0
            object.BlastRadius = 0
            active.Disabled = active.Disabled + 1
            return
        end

        if object:IsA("BasePart") then
            object.CastShadow = false
            object.Reflectance = 0
            if hidden then
                hideVisualPart(object)
                active.Hidden = active.Hidden + 1
            else
                object.Material = Enum.Material.Plastic
                object.MaterialVariant = ""
                if object:IsA("MeshPart") and not eggVisual then
                    pcall(function() object.TextureID = "" end)
                end
                active.Stripped = active.Stripped + 1
            end
        end
    end)
    if not ok then active.Errors = active.Errors + 1 end
end

local function enqueue(active, object, urgent)
    if not active.Running or not object or active.Queued[object] then return end
    active.Queued[object] = true
    local queue = urgent and active.UrgentQueue or active.NormalQueue
    queue[#queue + 1] = object
end

local function processObject(active, object, urgent)
    if not active.Running or not object then return end
    active.Queued[object] = nil
    optimizeObject(object, active)

    if active.Seen[object] then return end
    active.Seen[object] = true
    local childUrgent = urgent or object == active.Things or object == active.Debris
    local childrenOk, children = pcall(function() return object:GetChildren() end)
    if childrenOk then
        active.ProfileChildTables = (active.ProfileChildTables or 0) + 1
        for _, child in ipairs(children) do enqueue(active, child, childUrgent) end
    end
end

local function popQueue(queue)
    local count = #queue
    if count == 0 then return nil end
    local object = queue[count]
    queue[count] = nil
    return object
end

local function trackConnection(active, connection)
    if connection then active.Connections[#active.Connections + 1] = connection end
    return connection
end

local function bindRoot(active, key, root, urgent)
    if active[key] == root then return end
    disconnectConnection(active.RootConnections[key])
    active.RootConnections[key] = nil
    active[key] = root
    if not root then return end

    local connection = root.DescendantAdded:Connect(function(object)
        enqueue(active, object, urgent)
    end)
    active.RootConnections[key] = connection
    trackConnection(active, connection)
    enqueue(active, root, urgent)
end

local function refreshRoots(active)
    bindRoot(active, "Map", workspace:FindFirstChild("__MAP"), false)
    bindRoot(active, "Things", workspace:FindFirstChild("__THINGS"), true)
    bindRoot(active, "Debris", workspace:FindFirstChild("__DEBRIS"), true)
    bindRoot(active, "Camera", workspace.CurrentCamera, true)
end

local function processPersistent(active, deadline)
    local processed = 0
    local highWater = active.PersistentHighWater
    if highWater <= 0 then return 0 end

    while processed < PERSISTENT_OBJECT_LIMIT and os.clock() < deadline do
        local slot = active.PersistentCursor
        active.PersistentCursor = slot >= highWater and 1 or slot + 1
        local object = active.PersistentSlots[slot]
        if object then
            local metadata = active.PersistentKinds[object]
            local alive, parent = pcall(function() return object.Parent end)
            if not alive or parent == nil or not metadata then
                active.PersistentSlots[slot] = false
                active.PersistentKinds[object] = nil
                active.PersistentFree[#active.PersistentFree + 1] = slot
            else
                local ok = pcall(suppressPersistent, object, metadata.Kind)
                if not ok then active.Errors = active.Errors + 1 end
            end
        end
        processed = processed + 1
        if active.PersistentCursor == 1 then highWater = active.PersistentHighWater end
    end
    return processed
end

local function processQueue(active)
    refreshRoots(active)
    enqueue(active, Lighting, false)
    local nextRootRefresh = 0
    local nextRenderRefresh = 0

    while active.Running and env.PSX_POTATO_STATE == active do
        local profiledAt = profileBegin()
        local now = os.clock()
        if active.RootRefreshRequested or now >= nextRootRefresh then
            active.RootRefreshRequested = false
            nextRootRefresh = now + ROOT_REFRESH_INTERVAL
            refreshRoots(active)
        end
        if now >= nextRenderRefresh then
            nextRenderRefresh = now + RENDER_REFRESH_INTERVAL
            optimizeRendering()
        end

        local deadline = now + FRAME_TIME_BUDGET
        local urgentProcessed = 0
        while urgentProcessed < URGENT_OBJECT_LIMIT and os.clock() < deadline do
            local object = popQueue(active.UrgentQueue)
            if not object then break end
            processObject(active, object, true)
            urgentProcessed = urgentProcessed + 1
        end

        local normalProcessed = 0
        while normalProcessed < NORMAL_OBJECT_LIMIT and os.clock() < deadline do
            local object = popQueue(active.NormalQueue)
            if not object then break end
            processObject(active, object, false)
            normalProcessed = normalProcessed + 1
        end

        local persistentProcessed = processPersistent(active, deadline)
        local scanned = urgentProcessed + normalProcessed + persistentProcessed
        profileScanned(scanned)
        profileTemporary(active.ProfileChildTables or 0)
        active.ProfileChildTables = 0
        profileGauge("graphics_queue", #active.UrgentQueue + #active.NormalQueue)
        profileGauge("graphics_persistent", active.PersistentHighWater)
        profileFinish("queue_frame", profiledAt)

        if #active.UrgentQueue == 0 and #active.NormalQueue == 0 and not active.InitialReported then
            active.InitialReported = true
            print(string.format(
                "[PSX SLIM] farm anti-lag | ready | effects=%d | hidden=%d | stripped=%d | destroyed=%d | protected=%d | errors=%d",
                active.Effects, active.Hidden, active.Stripped, active.Destroyed,
                active.Protected, active.Errors
            ))
        end

        if #active.UrgentQueue == 0 and #active.NormalQueue == 0 then
            task.wait(0.05)
        else
            RunService.Heartbeat:Wait()
        end
    end
end

local function startPotato()
    if state and state.Running then return true end
    local previous = env.PSX_POTATO_STATE
    if previous then disconnect(previous) end

    local active = {
        Running = true,
        Connections = {},
        RootConnections = {},
        UrgentQueue = {},
        NormalQueue = {},
        Seen = setmetatable({}, { __mode = "k" }),
        Queued = setmetatable({}, { __mode = "k" }),
        PersistentKinds = setmetatable({}, { __mode = "k" }),
        PersistentSlots = {},
        PersistentFree = {},
        PersistentHighWater = 0,
        PersistentCursor = 1,
        ProfileChildTables = 0,
        Effects = 0,
        Hidden = 0,
        Disabled = 0,
        Stripped = 0,
        Destroyed = 0,
        Protected = 0,
        Errors = 0,
    }
    state = active
    env.PSX_POTATO_STATE = active
    optimizeRendering()

    -- Only watch the game-owned visual roots. A global Workspace.DescendantAdded
    -- listener needlessly wakes for every character/accessory in crowded servers.
    trackConnection(active, workspace.ChildAdded:Connect(function(object)
        local name = object.Name
        if name == "__MAP" or name == "__THINGS" or name == "__DEBRIS" then
            active.RootRefreshRequested = true
        end
    end))
    trackConnection(active, workspace.ChildRemoved:Connect(function(object)
        if object == active.Map or object == active.Things or object == active.Debris then
            active.RootRefreshRequested = true
        end
    end))
    trackConnection(active, workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
        active.RootRefreshRequested = true
    end))
    trackConnection(active, Lighting.DescendantAdded:Connect(function(object)
        enqueue(active, object, true)
    end))

    task.spawn(processQueue, active)

    env.StopPSXPotatoMode = function()
        if env.PSX_POTATO_STATE == active then disconnect(active) end
    end
    print("[PSX SLIM] farm anti-lag | enabled | map/eggs/network state preserved; farm effects hidden")
    return true
end

local function setFPS(choice)
    choice = tostring(choice or "Unchanged")
    if choice == "Unchanged" then return true end
    local setter = env.setfpscap or env.set_fps_cap
    if type(setter) ~= "function" then return false, "setfpscap is unavailable" end
    local cap = choice == "Unlimited" and 999 or tonumber(choice)
    if not cap then return false, "invalid FPS value" end
    local ok, problem = pcall(setter, cap)
    if ok then print("[PSX SLIM] fps cap | " .. choice) end
    return ok, problem
end

return function(action, value)
    if action == "version" then return MODULE_VERSION end
    if action == "set-profiler" then profiler = value; return true end
    if action == "potato" then
        if value == false then disconnect(state); return true end
        return startPotato()
    end
    if action == "fps" then return setFPS(value) end
    if action == "stop" then disconnect(state); return true end
    return false, "unknown graphics action"
end
