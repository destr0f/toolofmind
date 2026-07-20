-- Optional graphics controls for PSX OG Slim Farm.
-- Loaded only after the user changes Potato Mode or the FPS limit.

local RunService = game:GetService("RunService")
local saved = setmetatable({}, { __mode = "k" })
local enabled = false
local generation = 0
local mapConnection
local worldConnection

local function write(instance, property, value)
    local readable, old = pcall(function() return instance[property] end)
    if not readable or old == value then return end
    local properties = saved[instance]
    if not properties then properties = {}; saved[instance] = properties end
    if properties[property] == nil then properties[property] = old end
    pcall(function() instance[property] = value end)
end

local function simplify(instance)
    if instance:IsA("BasePart") then
        write(instance, "CastShadow", false)
        write(instance, "Material", Enum.Material.SmoothPlastic)
    elseif instance:IsA("ParticleEmitter") or instance:IsA("Trail") or instance:IsA("Beam")
        or instance:IsA("Smoke") or instance:IsA("Fire") or instance:IsA("Sparkles")
        or instance:IsA("PointLight") or instance:IsA("SpotLight") or instance:IsA("SurfaceLight")
    then
        write(instance, "Enabled", false)
    end
end

local function applyMap(map)
    local current = generation
    task.spawn(function()
        local lighting = game:GetService("Lighting")
        write(lighting, "GlobalShadows", false)
        write(lighting, "EnvironmentDiffuseScale", 0)
        write(lighting, "EnvironmentSpecularScale", 0)
        for _, effect in ipairs(lighting:GetChildren()) do
            if effect:IsA("BloomEffect") or effect:IsA("BlurEffect")
                or effect:IsA("DepthOfFieldEffect") or effect:IsA("SunRaysEffect")
            then
                write(effect, "Enabled", false)
            end
        end

        local terrain = workspace:FindFirstChildOfClass("Terrain")
        if terrain then write(terrain, "Decoration", false) end

        local descendants = map and map:GetDescendants() or {}
        for index, instance in ipairs(descendants) do
            if current ~= generation or not enabled then return end
            simplify(instance)
            if index % 240 == 0 then RunService.Heartbeat:Wait() end
        end
        print("[PSX SLIM] potato mode | ready | static map only")
    end)
end

local function bindMap(map)
    if mapConnection then pcall(function() mapConnection:Disconnect() end) end
    mapConnection = nil
    if not map then return end
    mapConnection = map.DescendantAdded:Connect(function(instance)
        if enabled then simplify(instance) end
    end)
    if enabled then
        generation = generation + 1
        applyMap(map)
    end
end

local function restore()
    local current = generation
    task.spawn(function()
        local count = 0
        for instance, properties in pairs(saved) do
            if current ~= generation or enabled then return end
            for property, old in pairs(properties) do
                pcall(function() instance[property] = old end)
            end
            saved[instance] = nil
            count = count + 1
            if count % 240 == 0 then RunService.Heartbeat:Wait() end
        end
        print("[PSX SLIM] potato mode | restored")
    end)
end

local function setPotato(value)
    value = value == true
    if enabled == value then return end
    enabled = value
    generation = generation + 1
    if enabled then
        if not worldConnection then
            worldConnection = workspace.ChildAdded:Connect(function(child)
                if child.Name == "__MAP" then bindMap(child) end
            end)
        end
        bindMap(workspace:FindFirstChild("__MAP"))
    else
        restore()
    end
end

local function setFPS(choice)
    choice = tostring(choice or "Unchanged")
    if choice == "Unchanged" then return true end
    local env = type(getgenv) == "function" and getgenv() or _G
    local setter = env.setfpscap or env.set_fps_cap
    if type(setter) ~= "function" then return false, "setfpscap is unavailable" end
    local cap = choice == "Unlimited" and 999 or tonumber(choice)
    if not cap then return false, "invalid FPS value" end
    local ok, problem = pcall(setter, cap)
    if ok then print("[PSX SLIM] fps cap | " .. choice) end
    return ok, problem
end

local function stop()
    if enabled then setPotato(false) end
    if mapConnection then pcall(function() mapConnection:Disconnect() end) end
    if worldConnection then pcall(function() worldConnection:Disconnect() end) end
    mapConnection, worldConnection = nil, nil
end

return function(action, value)
    if action == "potato" then setPotato(value); return true end
    if action == "fps" then return setFPS(value) end
    if action == "stop" then stop(); return true end
    return false, "unknown graphics action"
end
