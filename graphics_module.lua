-- Optional Mega Potato controls for PSX OG Slim Farm.
-- Loaded only after the user presses the button or changes the FPS limit.

local env = type(getgenv) == "function" and getgenv() or _G
local Lighting = game:GetService("Lighting")
local Terrain = workspace:FindFirstChildOfClass("Terrain")
local state

local function disconnect(target)
    if type(target) ~= "table" then return end
    target.Running = false
    for _, connection in ipairs(target.Connections or {}) do
        pcall(function() connection:Disconnect() end)
    end
    target.Connections = {}
end

local function protected(object)
    if object.Name == "_SELECTIONFX" or object.Name == "POS" then return true end
    local things = workspace:FindFirstChild("__THINGS")
    return things and (object == things or object:IsDescendantOf(things)) or false
end

local function optimizeRendering()
    pcall(function() settings().Rendering.QualityLevel = Enum.QualityLevel.Level01 end)
    pcall(function() settings().Rendering.MeshPartDetailLevel = Enum.MeshPartDetailLevel.Level01 end)
    pcall(function()
        Lighting.GlobalShadows = false
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

local function optimizeObject(object)
    pcall(function()
        if protected(object) then return end

        if object:IsA("ParticleEmitter") or object:IsA("Beam") or object:IsA("Trail")
            or object:IsA("Fire") or object:IsA("Smoke") or object:IsA("Sparkles")
            or object:IsA("PostEffect") or object:IsA("Highlight")
            or object:IsA("BillboardGui") or object:IsA("SurfaceGui")
            or object:IsA("PointLight") or object:IsA("SpotLight")
            or object:IsA("SurfaceLight") or object:IsA("Clouds")
        then
            object.Enabled = false
            return
        end

        if object:IsA("Decal") or object:IsA("Texture") or object:IsA("SurfaceAppearance") then
            object:Destroy()
            return
        end

        if object:IsA("Sky") then
            object.SkyboxBk, object.SkyboxDn, object.SkyboxFt = "", "", ""
            object.SkyboxLf, object.SkyboxRt, object.SkyboxUp = "", "", ""
            object.SunTextureId, object.MoonTextureId = "", ""
            object.StarCount = 0
            object.CelestialBodiesShown = false
            return
        end

        if object:IsA("Atmosphere") then
            object.Density, object.Haze, object.Glare = 0, 0, 0
            return
        end

        if object:IsA("SpecialMesh") then
            object.TextureId = ""
            return
        end

        if object:IsA("BasePart") then
            object.Material = Enum.Material.Plastic
            object.Reflectance = 0
            object.CastShadow = false
            if object:IsA("MeshPart") then pcall(function() object.TextureID = "" end) end
        end
    end)
end

local function startPotato()
    if state and state.Running then return true end
    local previous = env.PSX_POTATO_STATE
    if previous then disconnect(previous) end

    local active = { Running = true, Connections = {} }
    state = active
    env.PSX_POTATO_STATE = active
    optimizeRendering()

    table.insert(active.Connections, workspace.DescendantAdded:Connect(optimizeObject))
    table.insert(active.Connections, Lighting.DescendantAdded:Connect(optimizeObject))

    task.spawn(function()
        local descendants = workspace:GetDescendants()
        for index, object in ipairs(descendants) do
            if not active.Running or env.PSX_POTATO_STATE ~= active then return end
            optimizeObject(object)
            if index % 400 == 0 then task.wait() end
        end
        for _, object in ipairs(Lighting:GetDescendants()) do optimizeObject(object) end
        print("[PSX SLIM] mega potato | initial pass complete")
    end)

    task.spawn(function()
        while active.Running and env.PSX_POTATO_STATE == active do
            optimizeRendering()
            task.wait(2)
        end
    end)

    env.StopPSXPotatoMode = function()
        if env.PSX_POTATO_STATE == active then disconnect(active) end
    end
    print("[PSX SLIM] mega potato | enabled | FPS remains separately controlled")
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
