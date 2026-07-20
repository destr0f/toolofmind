-- Optional balanced potato controls for PSX OG Slim Farm.
-- Keeps the location and __THINGS visible while reducing expensive world visuals.

local env = type(getgenv) == "function" and getgenv() or _G
local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")
local Terrain = workspace:FindFirstChildOfClass("Terrain")
local state

local function disconnect(target)
    if type(target) ~= "table" then return end
    target.Running = false
    for _, connection in ipairs(target.Connections or {}) do
        pcall(function() connection:Disconnect() end)
    end
    target.Connections = {}
    target.Queue = {}
end

local function isProtectedTree(object)
    local current = object
    while current and current ~= workspace and current ~= Lighting do
        if current.Name == "_SELECTIONFX" or current.Name == "POS" then return true end
        current = current.Parent
    end
    return false
end

local function thingsPolicy(object)
    local things = workspace:FindFirstChild("__THINGS")
    if not things or (object ~= things and not object:IsDescendantOf(things)) then return false, false end
    local coins = things:FindFirstChild("Coins")
    local coinVisual = coins and (object == coins or object:IsDescendantOf(coins)) or false
    return true, coinVisual
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

local function optimizeObject(object, active)
    local insideThings, coinVisual = false, false
    if object then insideThings, coinVisual = thingsPolicy(object) end
    if not object or isProtectedTree(object) or (insideThings and not coinVisual) then
        if active then active.Protected = active.Protected + 1 end
        return
    end

    local ok = pcall(function()
        if object:IsA("ParticleEmitter") then
            object.Enabled = false
            object.Rate = 0
            pcall(function() object:Clear() end)
            active.Disabled = active.Disabled + 1
            return
        end
        if object:IsA("BillboardGui") or object:IsA("SurfaceGui") then
            if coinVisual then
                active.Protected = active.Protected + 1
            else
                object.Enabled = false
                active.Disabled = active.Disabled + 1
            end
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
            active.Disabled = active.Disabled + 1
            return
        end
        if object:IsA("Decal") or object:IsA("Texture") or object:IsA("SurfaceAppearance") then
            object:Destroy()
            active.Destroyed = active.Destroyed + 1
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
            object.TextureId = ""
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
            active.Disabled = active.Disabled + 1
            return
        end
        if object:IsA("BasePart") then
            object.Material = Enum.Material.Plastic
            object.MaterialVariant = ""
            object.Reflectance = 0
            object.CastShadow = false
            if object:IsA("MeshPart") then pcall(function() object.TextureID = "" end) end
            active.Stripped = active.Stripped + 1
        end
    end)
    if not ok then active.Errors = active.Errors + 1 end
end

local function enqueue(active, object)
    if not active.Running or not object or active.Seen[object] or active.Queued[object] then return end
    active.Queued[object] = true
    active.Queue[#active.Queue + 1] = object
end

local function processQueue(active)
    enqueue(active, workspace)
    enqueue(active, Lighting)
    while active.Running and env.PSX_POTATO_STATE == active do
        local processed = 0
        while processed < 240 and #active.Queue > 0 do
            local object = table.remove(active.Queue)
            active.Queued[object] = nil
            if object and not active.Seen[object] then
                active.Seen[object] = true
                if object ~= workspace and object ~= Lighting then optimizeObject(object, active) end
                local childrenOk, children = pcall(function() return object:GetChildren() end)
                if childrenOk then
                    for _, child in ipairs(children) do enqueue(active, child) end
                end
                processed = processed + 1
            end
        end
        if #active.Queue == 0 then
            if not active.InitialReported then
                active.InitialReported = true
                print(string.format(
                    "[PSX SLIM] balanced potato | initial pass complete | disabled=%d | stripped=%d | destroyed=%d | protected=%d | errors=%d",
                    active.Disabled, active.Stripped, active.Destroyed, active.Protected, active.Errors
                ))
            end
            task.wait(0.25)
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
        Queue = {},
        Seen = setmetatable({}, { __mode = "k" }),
        Queued = setmetatable({}, { __mode = "k" }),
        Disabled = 0,
        Stripped = 0,
        Destroyed = 0,
        Protected = 0,
        Errors = 0,
    }
    state = active
    env.PSX_POTATO_STATE = active
    optimizeRendering()

    active.Connections[#active.Connections + 1] = workspace.DescendantAdded:Connect(function(object)
        enqueue(active, object)
    end)
    active.Connections[#active.Connections + 1] = Lighting.DescendantAdded:Connect(function(object)
        enqueue(active, object)
    end)

    task.spawn(processQueue, active)
    task.spawn(function()
        while active.Running and env.PSX_POTATO_STATE == active do
            optimizeRendering()
            task.wait(5)
        end
    end)

    env.StopPSXPotatoMode = function()
        if env.PSX_POTATO_STATE == active then disconnect(active) end
    end
    print("[PSX SLIM] balanced potato | enabled | location, __THINGS and Network requests preserved")
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
        if value == false then disconnect(state); return true end
        return startPotato()
    end
    if action == "fps" then return setFPS(value) end
    if action == "stop" then disconnect(state); return true end
    return false, "unknown graphics action"
end
