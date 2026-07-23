-- Event-driven graphics reduction for crowded PSX OG farming zones.
-- Farm visuals are hidden; map/egg/machine geometry is retained but stripped
-- of expensive textures and materials. UI and network containers stay intact.

local MODULE_VERSION = "2.1.0"
local env = type(getgenv) == "function" and getgenv() or _G
local Lighting = game:GetService("Lighting")
local Terrain = workspace:FindFirstChildOfClass("Terrain")
local state

local FARM_ROOTS = {
    Coins = true,
    Pets = true,
    Orbs = true,
    Lootbags = true,
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

local function disconnectAll(active)
    if type(active) ~= "table" then return end
    active.Running = false
    active.Generation = active.Generation + 1
    for _, connection in ipairs(active.Connections) do disconnect(connection) end
    for _, connection in pairs(active.RootConnections) do disconnect(connection) end
    for _, connection in ipairs(active.ThingsConnections) do disconnect(connection) end
    active.Connections = {}
    active.RootConnections = {}
    active.ThingsConnections = {}
    active.Roots = {}
    active.Things = nil
    active.InitialObjects = {}
    active.InitialKinds = {}
    active.InitialHead = 1
    active.InitialArmed = false
    if env.StopPSXPotatoMode == active.StopFunction then
        env.StopPSXPotatoMode = nil
    end
    if env.PSX_POTATO_STATE == active then env.PSX_POTATO_STATE = nil end
end

local function protected(object)
    local current = object
    local depth = 0
    while current and current ~= workspace and depth < 16 do
        if string.lower(tostring(current.Name)) == "_selectionfx" then return true end
        current = current.Parent
        depth = depth + 1
    end
    return false
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
    -- Game scripts retain and reuse these instances after parenting them. Removing
    -- one from DescendantAdded races the game's own parent assignment and also
    -- leaves scripts such as Coin Rewards HUD indexing a missing child.
    if class == "Explosion" then
        object.Visible = false
        object.BlastPressure = 0
        object.BlastRadius = 0
    else
        object.Enabled = false
        if class == "ParticleEmitter" then
            object.Rate = 0
            pcall(function() object:Clear() end)
        elseif class == "Trail" then
            pcall(function() object:Clear() end)
        end
    end
    active.Disabled = active.Disabled + 1
end

local function stripSurfaceAppearance(active, object)
    for _, property in ipairs({
        "ColorMap",
        "MetalnessMap",
        "NormalMap",
        "RoughnessMap",
    }) do
        pcall(function() object[property] = "" end)
    end
    active.Stripped = active.Stripped + 1
end

local function suppress(active, object, kind)
    if not active.Running or not object or protected(object) then
        active.Protected = active.Protected + 1
        return
    end
    local class = object.ClassName
    local visual = kind == "farm" or kind == "effects" or kind == "world"
    local ok = pcall(function()
        if EFFECT_CLASSES[class] then
            disableEffect(active, object, class)
            return
        end

        if object:IsA("Sky") then
            object.SkyboxBk, object.SkyboxDn, object.SkyboxFt = "", "", ""
            object.SkyboxLf, object.SkyboxRt, object.SkyboxUp = "", "", ""
            object.SunTextureId, object.MoonTextureId = "", ""
            object.StarCount = 0
            object.CelestialBodiesShown = false
            active.Stripped = active.Stripped + 1
            return
        end

        if object:IsA("Atmosphere") then
            object.Density = 0
            object.Haze = 0
            object.Glare = 0
            active.Disabled = active.Disabled + 1
            return
        end

        if object:IsA("Clouds") then
            object.Cover = 0
            object.Density = 0
            active.Disabled = active.Disabled + 1
            return
        end

        if object:IsA("Sound") then
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
            object.Material = Enum.Material.Plastic
            pcall(function() object.MaterialVariant = "" end)
            if (kind == "farm" or kind == "effects")
                and string.lower(tostring(object.Name)) ~= "pos" then
                object.Transparency = 1
                active.Hidden = active.Hidden + 1
            end
            if object:IsA("MeshPart") then
                object.TextureID = ""
                active.Stripped = active.Stripped + 1
            end
            return
        end

        if object:IsA("Decal") or object:IsA("Texture") then
            if visual then
                object.Transparency = 1
                active.Hidden = active.Hidden + 1
            end
            return
        end

        if object:IsA("SurfaceAppearance") then
            if visual then stripSurfaceAppearance(active, object) end
            return
        end

        if object:IsA("SpecialMesh") then
            if visual then
                object.TextureId = ""
                active.Stripped = active.Stripped + 1
            end
            return
        end

        if kind == "farm" and (object:IsA("BillboardGui")
            or object:IsA("SurfaceGui")) then
            object.Enabled = false
            active.Disabled = active.Disabled + 1
        end
    end)
    if not ok then active.Errors = active.Errors + 1 end
end

local function deferSuppression(active, root, object, kind)
    local generation = active.Generation
    task.defer(function()
        if not active.Running or active.Generation ~= generation then return end
        if not object or not object.Parent then return end
        if root and not object:IsDescendantOf(root) then return end
        suppress(active, object, kind)
    end)
end

local function processInitial(active)
    active.InitialArmed = false
    if not active.Running then return end
    local processed = 0
    while processed < 256 and active.InitialHead <= #active.InitialObjects do
        local object = active.InitialObjects[active.InitialHead]
        local kind = active.InitialKinds[active.InitialHead]
        active.InitialObjects[active.InitialHead] = false
        active.InitialKinds[active.InitialHead] = false
        active.InitialHead = active.InitialHead + 1
        processed = processed + 1
        if object and object.Parent then
            suppress(active, object, kind)
        end
    end
    if active.InitialHead <= #active.InitialObjects then
        active.InitialArmed = true
        task.defer(function() processInitial(active) end)
    else
        active.InitialObjects = {}
        active.InitialKinds = {}
        active.InitialHead = 1
    end
end

local function queueTree(active, root, kind)
    if not root then return end
    local index = #active.InitialObjects + 1
    active.InitialObjects[index] = root
    active.InitialKinds[index] = kind
    for _, object in ipairs(root:GetDescendants()) do
        index = index + 1
        active.InitialObjects[index] = object
        active.InitialKinds[index] = kind
    end
    if not active.InitialArmed then
        active.InitialArmed = true
        task.defer(function() processInitial(active) end)
    end
end

local function bindDynamicRoot(active, key, root, kind)
    if active.Roots[key] == root then return end
    disconnect(active.RootConnections[key])
    active.RootConnections[key] = nil
    active.Roots[key] = root
    if not root then return end
    queueTree(active, root, kind)
    active.RootConnections[key] =
        root.DescendantAdded:Connect(function(object)
            deferSuppression(active, root, object, kind)
        end)
end

local function bindThings(active, things)
    if active.Things ~= things then
        for _, connection in ipairs(active.ThingsConnections) do disconnect(connection) end
        active.ThingsConnections = {}
        active.Things = things
        if things then
            active.ThingsConnections[#active.ThingsConnections + 1] =
                things.ChildAdded:Connect(function(child)
                    if FARM_ROOTS[child.Name] then
                        bindDynamicRoot(active, "things:" .. child.Name, child, "farm")
                    end
                end)
            active.ThingsConnections[#active.ThingsConnections + 1] =
                things.ChildRemoved:Connect(function(child)
                    local key = "things:" .. child.Name
                    if FARM_ROOTS[child.Name] and active.Roots[key] == child then
                        bindDynamicRoot(active, key, nil, "farm")
                    end
                end)
        end
    end
    for name in pairs(FARM_ROOTS) do
        bindDynamicRoot(active, "things:" .. name,
            things and things:FindFirstChild(name) or nil, "farm")
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
        InitialObjects = {},
        InitialKinds = {},
        InitialHead = 1,
        InitialArmed = false,
        StopFunction = nil,
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

    active.Connections[#active.Connections + 1] = workspace.ChildAdded:Connect(function(object)
        if object.Name == "__MAP" or object.Name == "__THINGS"
            or object.Name == "__DEBRIS" then
            task.defer(function() refreshRoots(active) end)
        end
    end)
    active.Connections[#active.Connections + 1] = workspace.ChildRemoved:Connect(function(object)
        if object == active.Roots.map or object == active.Things
            or object == active.Roots.debris then
            task.defer(function() refreshRoots(active) end)
        end
    end)

    refreshRoots(active)
    active.StopFunction = function()
        if env.PSX_POTATO_STATE == active then disconnectAll(active) end
    end
    env.StopPSXPotatoMode = active.StopFunction
    print("[PSX SLIM] potato | event-driven map/egg/machine texture strip | no permanent rescan")
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
