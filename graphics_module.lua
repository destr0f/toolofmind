-- Coalesced graphics reduction for crowded PSX OG farming zones.
-- Game-owned instances are never destroyed or reparented. One bounded queue
-- suppresses visual work while Loot Reactor exclusively owns Orbs/Lootbags.

local MODULE_VERSION = "3.0.0"
local env = type(getgenv) == "function" and getgenv() or _G
local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")
local Terrain = workspace:FindFirstChildOfClass("Terrain")
local state

local QUEUE_CAPACITY = 32768
local SETTLE_CAPACITY = 8192
local MAX_PER_FRAME = 192
local FRAME_BUDGET_SECONDS = 0.00075
local SETTLE_DELAY = 0.05

local THING_ROOTS = {
    Coins = "farm",
    Pets = "farm",
    Eggs = "world",
    Machines = "world",
}

local EFFECT_CLASSES = {
    ParticleEmitter = true,
    Trail = true,
    Beam = true,
    Fire = true,
    Smoke = true,
    Sparkles = true,
    Explosion = true,
    Highlight = true,
    PointLight = true,
    SpotLight = true,
    SurfaceLight = true,
    BloomEffect = true,
    BlurEffect = true,
    ColorCorrectionEffect = true,
    DepthOfFieldEffect = true,
    SunRaysEffect = true,
}

local function disconnect(connection)
    if connection then pcall(function() connection:Disconnect() end) end
end

local function clearArray(array)
    if type(array) == "table" then table.clear(array) end
end

local function disconnectAll(active)
    if type(active) ~= "table" then return end
    active.Running = false
    active.Generation = (active.Generation or 0) + 1
    disconnect(active.DrainConnection)
    active.DrainConnection = nil
    for _, connection in ipairs(active.Connections or {}) do disconnect(connection) end
    for _, connection in pairs(active.RootConnections or {}) do disconnect(connection) end
    for _, connection in ipairs(active.ThingsConnections or {}) do disconnect(connection) end
    clearArray(active.Connections)
    clearArray(active.RootConnections)
    clearArray(active.ThingsConnections)
    clearArray(active.Roots)
    clearArray(active.QueueObjects)
    clearArray(active.QueueRoots)
    clearArray(active.QueueKinds)
    clearArray(active.QueueScans)
    clearArray(active.QueuePasses)
    clearArray(active.SettleObjects)
    clearArray(active.SettleRoots)
    clearArray(active.SettleKinds)
    active.QueueHead = 1
    active.QueueCount = 0
    active.SettleHead = 1
    active.SettleCount = 0
    active.SettleArmed = false
    active.RootRefreshArmed = false
    active.FirstSeen = nil
    active.SecondSeen = nil
    active.SettleSeen = nil
    active.Protection = nil
    active.Things = nil
    if env.StopPSXPotatoMode == active.StopFunction then
        env.StopPSXPotatoMode = nil
    end
    if env.PSX_POTATO_STATE == active then env.PSX_POTATO_STATE = nil end
end

local function protected(active, object)
    if not object then return false end
    local cached = active.Protection[object]
    if cached ~= nil then return cached end
    local result = string.lower(tostring(object.Name)) == "_selectionfx"
    if not result then
        local parent = object.Parent
        if parent and parent ~= workspace and parent ~= game then
            result = protected(active, parent)
        end
    end
    active.Protection[object] = result
    return result
end

local function optimizeRendering()
    pcall(function() settings().Rendering.QualityLevel = Enum.QualityLevel.Level01 end)
    pcall(function() settings().Rendering.MeshPartDetailLevel = Enum.MeshPartDetailLevel.Level01 end)
    pcall(function()
        Lighting.GlobalShadows = false
        Lighting.EnvironmentDiffuseScale = 0
        Lighting.EnvironmentSpecularScale = 0
        Lighting.Brightness = 1
    end)
    if Terrain then
        pcall(function()
            Terrain.Decoration = false
            Terrain.WaterWaveSize = 0
            Terrain.WaterWaveSpeed = 0
            Terrain.WaterReflectance = 0
            Terrain.WaterTransparency = 1
        end)
    end
end

local function disableEffect(active, object, class)
    if class == "Explosion" then
        object.BlastPressure = 0
        object.BlastRadius = 0
        pcall(function() object.DestroyJointRadiusPercent = 0 end)
    else
        object.Enabled = false
        if class == "ParticleEmitter" then
            object.Rate = 0
            pcall(function() object.TimeScale = 0 end)
            pcall(function() object:Clear() end)
        elseif class == "Trail" then
            pcall(function() object:Clear() end)
        end
    end
    active.Disabled = active.Disabled + 1
end

local function stripSurfaceAppearance(active, object)
    pcall(function() object.ColorMap = "" end)
    pcall(function() object.MetalnessMap = "" end)
    pcall(function() object.NormalMap = "" end)
    pcall(function() object.RoughnessMap = "" end)
    active.Stripped = active.Stripped + 1
end

local function suppress(active, object, kind)
    if not active.Running or not object then return false end
    if protected(active, object) then
        active.Protected = active.Protected + 1
        return false
    end
    local class = object.ClassName
    local visual = kind == "farm" or kind == "effects" or kind == "world"
    local ok = pcall(function()
        if EFFECT_CLASSES[class] then
            disableEffect(active, object, class)
            return
        end
        if class == "Sky" then
            object.SkyboxBk, object.SkyboxDn, object.SkyboxFt = "", "", ""
            object.SkyboxLf, object.SkyboxRt, object.SkyboxUp = "", "", ""
            object.SunTextureId, object.MoonTextureId = "", ""
            object.StarCount = 0
            object.CelestialBodiesShown = false
            active.Stripped = active.Stripped + 1
            return
        end
        if class == "Atmosphere" then
            object.Density = 0
            object.Haze = 0
            object.Glare = 0
            active.Disabled = active.Disabled + 1
            return
        end
        if class == "Clouds" then
            object.Cover = 0
            object.Density = 0
            active.Disabled = active.Disabled + 1
            return
        end
        if class == "Sound" then
            if visual then
                object.Volume = 0
                object.Playing = false
                active.Disabled = active.Disabled + 1
            end
            return
        end
        if object:IsA("BasePart") then
            object.CastShadow = false
            object.Reflectance = 0
            pcall(function() object.MaterialVariant = "" end)
            if (kind == "farm" or kind == "effects")
                and string.lower(tostring(object.Name)) ~= "pos" then
                pcall(function() object.LocalTransparencyModifier = 1 end)
                active.Hidden = active.Hidden + 1
            end
            if class == "MeshPart" then
                object.TextureID = ""
                active.Stripped = active.Stripped + 1
            end
            return
        end
        if class == "Decal" or class == "Texture" then
            if visual then
                object.Transparency = 1
                active.Hidden = active.Hidden + 1
            end
            return
        end
        if class == "SurfaceAppearance" then
            if visual then stripSurfaceAppearance(active, object) end
            return
        end
        if class == "SpecialMesh" then
            if visual then
                object.TextureId = ""
                active.Stripped = active.Stripped + 1
            end
            return
        end
        if kind == "farm" and (class == "BillboardGui" or class == "SurfaceGui") then
            object.Enabled = false
            active.Disabled = active.Disabled + 1
        end
    end)
    if not ok then active.Errors = active.Errors + 1 end
    return ok and EFFECT_CLASSES[class] == true
end

local enqueue
local armDrain
local armSettle

local function popQueue(active)
    if active.QueueCount <= 0 then return nil end
    local index = active.QueueHead
    local object = active.QueueObjects[index]
    local root = active.QueueRoots[index]
    local kind = active.QueueKinds[index]
    local scan = active.QueueScans[index]
    local pass = active.QueuePasses[index]
    active.QueueObjects[index] = nil
    active.QueueRoots[index] = nil
    active.QueueKinds[index] = nil
    active.QueueScans[index] = nil
    active.QueuePasses[index] = nil
    active.QueueHead = index % QUEUE_CAPACITY + 1
    active.QueueCount = active.QueueCount - 1
    return object, root, kind, scan, pass
end

local function scheduleSettle(active, root, object, kind)
    if active.SettleSeen[object] then return end
    if active.SettleCount >= SETTLE_CAPACITY then
        active.SettleDropped = active.SettleDropped + 1
        return
    end
    active.SettleSeen[object] = true
    local tail = (active.SettleHead + active.SettleCount - 1) % SETTLE_CAPACITY + 1
    active.SettleObjects[tail] = object
    active.SettleRoots[tail] = root
    active.SettleKinds[tail] = kind
    active.SettleCount = active.SettleCount + 1
    armSettle(active)
end

local function processQueue(active)
    if not active.Running then return end
    local started = os.clock()
    local processed = 0
    while active.QueueCount > 0 and processed < MAX_PER_FRAME do
        if processed > 0 and os.clock() - started >= FRAME_BUDGET_SECONDS then break end
        local object, root, kind, scan, pass = popQueue(active)
        processed = processed + 1
        if object and object.Parent
            and (not root or object == root or object:IsDescendantOf(root))
            and not protected(active, object) then
            local needsSettle = suppress(active, object, kind)
            if scan then
                local ok, children = pcall(function() return object:GetChildren() end)
                if ok then
                    for _, child in ipairs(children) do
                        enqueue(active, root or object, child, kind, true, 1)
                    end
                else
                    active.Errors = active.Errors + 1
                end
            end
            if pass == 1 and needsSettle then
                scheduleSettle(active, root, object, kind)
            end
        end
    end
    active.Processed = active.Processed + processed
end

armDrain = function(active)
    if active.DrainConnection or not active.Running then return end
    local generation = active.Generation
    active.DrainConnection = RunService.Heartbeat:Connect(function()
        if not active.Running or active.Generation ~= generation then
            disconnect(active.DrainConnection)
            active.DrainConnection = nil
            return
        end
        processQueue(active)
        if active.QueueCount <= 0 then
            disconnect(active.DrainConnection)
            active.DrainConnection = nil
        end
    end)
end

enqueue = function(active, root, object, kind, scan, pass)
    if not active.Running or not object then return false end
    pass = pass == 2 and 2 or 1
    local seen = pass == 2 and active.SecondSeen or active.FirstSeen
    if seen[object] then return false end
    if active.QueueCount >= QUEUE_CAPACITY then
        active.QueueDropped = active.QueueDropped + 1
        return false
    end
    seen[object] = true
    local tail = (active.QueueHead + active.QueueCount - 1) % QUEUE_CAPACITY + 1
    active.QueueObjects[tail] = object
    active.QueueRoots[tail] = root
    active.QueueKinds[tail] = kind
    active.QueueScans[tail] = scan == true
    active.QueuePasses[tail] = pass
    active.QueueCount = active.QueueCount + 1
    armDrain(active)
    return true
end

armSettle = function(active)
    if active.SettleArmed or not active.Running then return end
    active.SettleArmed = true
    local generation = active.Generation
    task.delay(SETTLE_DELAY, function()
        if not active.Running or active.Generation ~= generation then return end
        active.SettleArmed = false
        local count = active.SettleCount
        for _ = 1, count do
            local index = active.SettleHead
            local object = active.SettleObjects[index]
            local root = active.SettleRoots[index]
            local kind = active.SettleKinds[index]
            active.SettleObjects[index] = nil
            active.SettleRoots[index] = nil
            active.SettleKinds[index] = nil
            active.SettleHead = index % SETTLE_CAPACITY + 1
            active.SettleCount = active.SettleCount - 1
            if object and object.Parent then
                enqueue(active, root, object, kind, false, 2)
            end
        end
        if active.SettleCount > 0 then armSettle(active) end
    end)
end

local function queueTree(active, root, kind)
    if root then enqueue(active, root, root, kind, true, 1) end
end

local function bindDynamicRoot(active, key, root, kind)
    if active.Roots[key] == root then return end
    disconnect(active.RootConnections[key])
    active.RootConnections[key] = nil
    active.Roots[key] = root
    if not root then return end
    queueTree(active, root, kind)
    active.RootConnections[key] = root.DescendantAdded:Connect(function(object)
        enqueue(active, root, object, kind, true, 1)
    end)
end

local function bindThings(active, things)
    if active.Things ~= things then
        for _, connection in ipairs(active.ThingsConnections) do disconnect(connection) end
        table.clear(active.ThingsConnections)
        active.Things = things
        if things then
            active.ThingsConnections[#active.ThingsConnections + 1] =
                things.ChildAdded:Connect(function(child)
                    local kind = THING_ROOTS[child.Name]
                    if kind then
                        bindDynamicRoot(active, "things:" .. child.Name, child, kind)
                    end
                end)
            active.ThingsConnections[#active.ThingsConnections + 1] =
                things.ChildRemoved:Connect(function(child)
                    local key = "things:" .. child.Name
                    if THING_ROOTS[child.Name] and active.Roots[key] == child then
                        bindDynamicRoot(active, key, nil, THING_ROOTS[child.Name])
                    end
                end)
        end
    end
    for name, kind in pairs(THING_ROOTS) do
        bindDynamicRoot(active, "things:" .. name,
            things and things:FindFirstChild(name) or nil, kind)
    end
end

local function refreshRoots(active)
    if not active.Running then return end
    local map = workspace:FindFirstChild("__MAP")
    local things = workspace:FindFirstChild("__THINGS")
    local debris = workspace:FindFirstChild("__DEBRIS")
    bindDynamicRoot(active, "map", map, "world")
    bindDynamicRoot(active, "lighting", Lighting, "world")
    bindDynamicRoot(active, "debris", debris, "effects")
    bindThings(active, things)
end

local function armRootRefresh(active)
    if active.RootRefreshArmed or not active.Running then return end
    active.RootRefreshArmed = true
    local generation = active.Generation
    task.defer(function()
        if not active.Running or active.Generation ~= generation then return end
        active.RootRefreshArmed = false
        refreshRoots(active)
    end)
end

local function startPotato()
    if state and state.Running then return true end
    if env.PSX_POTATO_STATE then disconnectAll(env.PSX_POTATO_STATE) end

    local active = {
        Running = true,
        Generation = 1,
        Connections = {},
        RootConnections = {},
        ThingsConnections = {},
        Roots = {},
        Things = nil,
        QueueObjects = {},
        QueueRoots = {},
        QueueKinds = {},
        QueueScans = {},
        QueuePasses = {},
        QueueHead = 1,
        QueueCount = 0,
        SettleObjects = {},
        SettleRoots = {},
        SettleKinds = {},
        SettleHead = 1,
        SettleCount = 0,
        SettleArmed = false,
        DrainConnection = nil,
        RootRefreshArmed = false,
        FirstSeen = setmetatable({}, { __mode = "k" }),
        SecondSeen = setmetatable({}, { __mode = "k" }),
        SettleSeen = setmetatable({}, { __mode = "k" }),
        Protection = setmetatable({}, { __mode = "k" }),
        StopFunction = nil,
        Hidden = 0,
        Disabled = 0,
        Stripped = 0,
        Destroyed = 0,
        Protected = 0,
        Errors = 0,
        Processed = 0,
        QueueDropped = 0,
        SettleDropped = 0,
    }
    state = active
    env.PSX_POTATO_STATE = active
    optimizeRendering()

    active.Connections[#active.Connections + 1] = workspace.ChildAdded:Connect(function(object)
        if object.Name == "__MAP" or object.Name == "__THINGS"
            or object.Name == "__DEBRIS" then
            armRootRefresh(active)
        end
    end)
    active.Connections[#active.Connections + 1] = workspace.ChildRemoved:Connect(function(object)
        if object == active.Roots.map or object == active.Things
            or object == active.Roots.debris then
            armRootRefresh(active)
        end
    end)

    refreshRoots(active)
    active.StopFunction = function()
        if env.PSX_POTATO_STATE == active then disconnectAll(active) end
    end
    env.StopPSXPotatoMode = active.StopFunction
    print("[PSX SLIM] potato | coalesced bounded visual reactor | loot roots excluded")
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
    if action == "potato" then
        if value == false then disconnectAll(state); state = nil; return true end
        return startPotato()
    end
    if action == "fps" then return setFPS(value) end
    if action == "stop" then disconnectAll(state); state = nil; return true end
    if action == "version" then return MODULE_VERSION end
    return false, "unknown graphics action"
end
