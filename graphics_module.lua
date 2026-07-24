-- One-pass graphics reduction for crowded PSX OG farming zones.
-- High-rate Coins/Orbs producers are owned by loot_reactor.lua. This module
-- never destroys, reparents, teleports, anchors, or otherwise moves game data.

local MODULE_VERSION = "4.0.0"
local env = type(getgenv) == "function" and getgenv() or _G
local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")
local Terrain = workspace:FindFirstChildOfClass("Terrain")
local state

local QUEUE_CAPACITY = 16384
local MAX_PER_FRAME = 128
local FRAME_BUDGET_SECONDS = 0.0006

local LOW_RATE_ROOTS = {
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

local function clearConnections(collection)
    if type(collection) ~= "table" then return end
    for key, connection in pairs(collection) do
        disconnect(connection)
        collection[key] = nil
    end
end

local function beginProfile()
    local callback = debug and debug.profilebegin
    if type(callback) ~= "function" then return false end
    return pcall(callback, "PSX.GraphicsQueue") == true
end

local function endProfile(started)
    if not started then return end
    local callback = debug and debug.profileend
    if type(callback) == "function" then pcall(callback) end
end

local function stopActive(active)
    if type(active) ~= "table" then return end
    active.Running = false
    active.Generation = (active.Generation or 0) + 1
    disconnect(active.DrainConnection)
    active.DrainConnection = nil
    clearConnections(active.Connections)
    clearConnections(active.RootConnections)
    clearConnections(active.ThingsConnections)
    table.clear(active.Roots)
    table.clear(active.QueueObjects)
    table.clear(active.QueueRoots)
    table.clear(active.QueueKinds)
    table.clear(active.QueueScans)
    active.QueueHead = 1
    active.QueueCount = 0
    active.Seen = nil
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
    if not active.Running or not object or protected(active, object) then return end
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
                object.LocalTransparencyModifier = 1
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
end

local enqueue
local armDrain

local function popQueue(active)
    if active.QueueCount <= 0 then return nil end
    local index = active.QueueHead
    local object = active.QueueObjects[index]
    local root = active.QueueRoots[index]
    local kind = active.QueueKinds[index]
    local scan = active.QueueScans[index]
    active.QueueObjects[index] = nil
    active.QueueRoots[index] = nil
    active.QueueKinds[index] = nil
    active.QueueScans[index] = nil
    active.QueueHead = index % QUEUE_CAPACITY + 1
    active.QueueCount = active.QueueCount - 1
    return object, root, kind, scan
end

local function processQueue(active)
    if not active.Running then return end
    local profiled = beginProfile()
    local started = os.clock()
    local processed = 0
    local ok = pcall(function()
        while active.QueueCount > 0 and processed < MAX_PER_FRAME do
            if processed > 0 and os.clock() - started >= FRAME_BUDGET_SECONDS then break end
            local object, root, kind, scan = popQueue(active)
            processed = processed + 1
            if object and object.Parent
                and (not root or object == root or object:IsDescendantOf(root))
                and not protected(active, object) then
                suppress(active, object, kind)
                if scan then
                    local children = object:GetChildren()
                    for _, child in ipairs(children) do
                        enqueue(active, root or object, child, kind, true)
                    end
                end
            end
        end
    end)
    endProfile(profiled)
    if not ok then active.Errors = active.Errors + 1 end
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

enqueue = function(active, root, object, kind, scan)
    if not active.Running or not object or active.Seen[object] then return false end
    if active.QueueCount >= QUEUE_CAPACITY then
        active.QueueDropped = active.QueueDropped + 1
        return false
    end
    active.Seen[object] = true
    local tail = (active.QueueHead + active.QueueCount - 1) % QUEUE_CAPACITY + 1
    active.QueueObjects[tail] = object
    active.QueueRoots[tail] = root
    active.QueueKinds[tail] = kind
    active.QueueScans[tail] = scan == true
    active.QueueCount = active.QueueCount + 1
    armDrain(active)
    return true
end

local function queueTree(active, root, kind)
    if root then enqueue(active, root, root, kind, true) end
end

local function bindRoot(active, key, root, kind, watchTopLevel)
    if active.Roots[key] == root then return end
    disconnect(active.RootConnections[key])
    active.RootConnections[key] = nil
    active.Roots[key] = root
    if not root then return end
    queueTree(active, root, kind)
    if watchTopLevel then
        active.RootConnections[key] = root.ChildAdded:Connect(function(child)
            queueTree(active, child, kind)
        end)
    end
end

local function bindThings(active, things)
    if active.Things ~= things then
        clearConnections(active.ThingsConnections)
        for key in pairs(active.Roots) do
            if string.sub(key, 1, 7) == "things:" then
                disconnect(active.RootConnections[key])
                active.RootConnections[key] = nil
                active.Roots[key] = nil
            end
        end
        active.Things = things
        if things then
            active.ThingsConnections.Added = things.ChildAdded:Connect(function(child)
                local kind = LOW_RATE_ROOTS[child.Name]
                if kind then
                    bindRoot(active, "things:" .. child.Name, child, kind, true)
                elseif child.Name == "Coins" then
                    bindRoot(active, "things:Coins", child, "farm", false)
                end
            end)
            active.ThingsConnections.Removed = things.ChildRemoved:Connect(function(child)
                local key = "things:" .. child.Name
                if active.Roots[key] == child then
                    bindRoot(active, key, nil, LOW_RATE_ROOTS[child.Name] or "farm", false)
                end
            end)
        end
    end
    bindRoot(active, "things:Coins",
        things and things:FindFirstChild("Coins") or nil, "farm", false)
    for name, kind in pairs(LOW_RATE_ROOTS) do
        bindRoot(active, "things:" .. name,
            things and things:FindFirstChild(name) or nil, kind, true)
    end
end

local function refreshRoots(active)
    if not active.Running then return end
    bindRoot(active, "map", workspace:FindFirstChild("__MAP"), "world", false)
    bindRoot(active, "lighting", Lighting, "world", false)
    bindRoot(active, "debris", workspace:FindFirstChild("__DEBRIS"), "effects", false)
    bindThings(active, workspace:FindFirstChild("__THINGS"))
end

local function startPotato()
    if state and state.Running then return true end
    if env.PSX_POTATO_STATE then stopActive(env.PSX_POTATO_STATE) end

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
        QueueHead = 1,
        QueueCount = 0,
        DrainConnection = nil,
        Seen = setmetatable({}, { __mode = "k" }),
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
    }
    state = active
    env.PSX_POTATO_STATE = active
    optimizeRendering()

    active.Connections.Added = workspace.ChildAdded:Connect(function(object)
        if object.Name == "__MAP" or object.Name == "__THINGS"
            or object.Name == "__DEBRIS" then
            task.defer(function()
                if active.Running then refreshRoots(active) end
            end)
        end
    end)
    active.Connections.Removed = workspace.ChildRemoved:Connect(function(object)
        if object == active.Roots.map or object == active.Things
            or object == active.Roots.debris then
            task.defer(function()
                if active.Running then refreshRoots(active) end
            end)
        end
    end)

    refreshRoots(active)
    active.StopFunction = function()
        if env.PSX_POTATO_STATE == active then stopActive(active) end
    end
    env.StopPSXPotatoMode = active.StopFunction
    print("[PSX SLIM] potato | one-pass bounded graphics queue | producer gates own Coins/Orbs")
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

local function stats()
    local active = state
    if not active then return { Version = MODULE_VERSION, Running = false } end
    return {
        Version = MODULE_VERSION,
        Running = active.Running,
        Pending = active.QueueCount,
        Processed = active.Processed,
        Dropped = active.QueueDropped,
        Hidden = active.Hidden,
        Disabled = active.Disabled,
        Stripped = active.Stripped,
        Errors = active.Errors,
    }
end

return function(action, value)
    if action == "potato" then
        if value == false then stopActive(state); state = nil; return true end
        return startPotato()
    end
    if action == "fps" then return setFPS(value) end
    if action == "stats" then return stats() end
    if action == "stop" then stopActive(state); state = nil; return true end
    if action == "version" then return MODULE_VERSION end
    return false, "unknown graphics action"
end
