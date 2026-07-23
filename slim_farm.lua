-- PSX OG Slim Farm
-- Pet farming, auto hatch, conversion machines, boosts, loot and timer-gated automation.

local VERSION = "1.4.1-dev.6"
local env = type(getgenv) == "function" and getgenv() or _G

local function trace(stage, detail)
    print("[PSX SLIM] " .. tostring(stage) .. (detail and (" | " .. tostring(detail)) or ""))
end

trace("00 entered", "version=" .. VERSION)

if type(env.PSX_OG_SLIM_CLEANUP) == "function" then
    pcall(env.PSX_OG_SLIM_CLEANUP)
end
if type(env.PSX_OG_MENU_TEST_CLEANUP) == "function" then
    pcall(env.PSX_OG_MENU_TEST_CLEANUP)
    env.PSX_OG_MENU_TEST_CLEANUP = nil
end
env.PSX_OG_RunToken = nil
env.PSX_OG_Running = false
if type(env.PSX_OG_LOADER_STATE) == "table" then
    env.PSX_OG_LOADER_STATE.Running = false
    env.PSX_OG_LOADER_STATE.Superseded = true
end
if type(env.PSX_OG_FastEggState) == "table" then
    local state = env.PSX_OG_FastEggState
    if type(state.Stop) == "function" then
        pcall(state.Stop)
    else
        local connection = state.Connection
        if connection and type(connection.Disconnect) == "function" then
            pcall(function() connection:Disconnect() end)
        end
    end
    env.PSX_OG_FastEggState = nil
end
for _, key in ipairs({
    "PSX_OG_RewardInvokeCaptureState",
    "PSX_OG_BoostRemoteCaptureState",
    "PSX_OG_DiamondInvokeCaptureState",
    "PSX_OG_DiamondMethodCaptureState",
}) do
    local state = env[key]
    if type(state) == "table" then
        state.active = false
        state.remote = nil
    end
end
if type(env.PSX_OG_UI_CLEANUP) == "function" then
    pcall(env.PSX_OG_UI_CLEANUP)
    env.PSX_OG_UI_CLEANUP = nil
end
if type(env.PSX_OG_RunConnections) == "table" then
    for _, connection in ipairs(env.PSX_OG_RunConnections) do
        pcall(function() connection:Disconnect() end)
    end
    env.PSX_OG_RunConnections = {}
end

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local VirtualUser = game:GetService("VirtualUser")
local player = Players.LocalPlayer
local camera = workspace.CurrentCamera

local token = {}
local connections = {}
local config = {
    PetFarm = false,
    Mode = "Different Strongest",
    World = "Current World",
    Zone = "Player Zone",
    TrackedCurrency = "Active Balances",
    Orbs = false,
    Lootbags = false,
    AntiAFK = true,
    PotatoMode = false,
    FPSLimit = "Unchanged",
    AutoTechDiamondPack = false,
    AutoVIPRewards = false,
    AutoRankRewards = false,
    AutoGoldenGalaxyFox = false,
    AutoRainbowGalaxyFox = false,
    AutoDarkMatterGalaxyFox = false,
    AutoClaimDarkMatter = false,
    MachineBatchSize = 6,
    DarkMatterBatchSize = 6,
    DarkMatterMaxWaitHours = 0,
    AutoBoostBundle = false,
    BoostRenewBefore = 5,
    AutoTripleCoins = false,
    AutoTripleDamage = false,
    AutoSuperLucky = false,
    AutoUltraLucky = false,
    AutoEgg = false,
    EggScope = "Nearby Eggs",
    EggName = nil,
    EggCount = 1,
    EggAnimation = "Headless (No Animation)",
}

local MODULE_REVISION = "5f1e2bf832e8e2bc17fa1cb7cfa92768dc86e3d8"
local RAW_MODULE_BASE = "https://raw.githubusercontent.com/destr0f/toolofmind/"
    .. MODULE_REVISION .. "/"
local SUPPORT_MODULE_URL = RAW_MODULE_BASE .. "automation_support_module.lua"
local AUTOMATION_UI_MODULE_URL = RAW_MODULE_BASE .. "automation_ui_module.lua"
local PET_FARM_ENGINE_URL = RAW_MODULE_BASE .. "pet_farm_engine.lua"

local DIAMOND_PACK_TIER = 4
local DIAMOND_PACK_MINIMUM = 1e12
local DIAMOND_PACK_INTERVAL = 180
local diamondPackNextCheck = 0
local diamondPackBusy = false
local VIP_REWARD_COOLDOWN = 14400
local REWARD_RETRY_DELAY = 60
local rewardServerTime
local rewardClockStarted
local rewardStates = {
    VIP = {
        Label = "VIP",
        Command = "Redeem VIP Rewards",
        ConfigKey = "AutoVIPRewards",
        NextAttempt = 0,
    },
    Rank = {
        Label = "Rank",
        Command = "Redeem Rank Rewards",
        ConfigKey = "AutoRankRewards",
        NextAttempt = 0,
    },
}

env.PSX_OG_SLIM_TOKEN = token

local function running()
    return env.PSX_OG_SLIM_TOKEN == token
end

local function track(connection)
    table.insert(connections, connection)
    return connection
end

local function disconnectAll()
    for _, connection in ipairs(connections) do
        pcall(function() connection:Disconnect() end)
    end
    table.clear(connections)
end

trace("01 loading Library")
local Library = require(ReplicatedStorage:WaitForChild("Framework"):WaitForChild("Library"))
trace("02 Library required")

local WindUI
do
    trace("03 WindUI download")
    local windSource = game:HttpGet("https://github.com/Footagesus/WindUI/releases/download/1.6.64-fix/main.lua")
    trace("04 WindUI received", #windSource)

    local function replacePlain(source, needle, replacement)
        local startAt, replacements = 1, 0
        while true do
            local first, last = string.find(source, needle, startAt, true)
            if not first then break end
            source = string.sub(source, 1, first - 1) .. replacement .. string.sub(source, last + 1)
            startAt = first + #replacement
            replacements = replacements + 1
        end
        return source, replacements
    end

    local resizePatchCount = 0
    local patchedCount
    windSource, patchedCount = replacePlain(
        windSource,
        'an(ax.ImageLabel,0.1,{ImageTransparency=0.35}):Play()',
        'do local resizeIcon=ax:FindFirstChildWhichIsA("ImageLabel");if resizeIcon then an(resizeIcon,0.1,{ImageTransparency=0.35}):Play()end end'
    )
    resizePatchCount = resizePatchCount + patchedCount
    windSource, patchedCount = replacePlain(
        windSource,
        'an(ax.ImageLabel,0.17,{ImageTransparency=0.8}):Play()',
        'do local resizeIcon=ax:FindFirstChildWhichIsA("ImageLabel");if resizeIcon then an(resizeIcon,0.17,{ImageTransparency=0.8}):Play()end end'
    )
    resizePatchCount = resizePatchCount + patchedCount
    trace("04 WindUI resize guard", resizePatchCount)

    local windChunk, windError = loadstring(windSource)
    windSource = nil
    if not windChunk then error("WindUI compile failed: " .. tostring(windError), 0) end
    trace("05 WindUI compiled")
    local initialized
    initialized, WindUI = pcall(windChunk)
    windChunk = nil
    if not initialized then error("WindUI initialization failed: " .. tostring(WindUI), 0) end
    trace("06 WindUI initialized")
end

local function networkReady()
    local network = Library and Library.Network
    if not network or type(network.Fire) ~= "function" or type(network.Invoke) ~= "function" then
        return nil
    end
    if Library.Loaded ~= nil and Library.Loaded ~= true then return nil end
    return network
end

-- Executors are much less stable when several large loadstring calls compile in
-- parallel during profile auto-load. Every optional module now uses this one lane.
local moduleLoadState = { Busy = false, Owner = nil, NextAt = 0, Cache = {} }

local function loadRemoteController(url, label, statusCallback)
    local cached = moduleLoadState.Cache[url]
    if type(cached) == "function" then return cached, nil end

    local deadline = os.clock() + 45
    while running() and (moduleLoadState.Busy or os.clock() < moduleLoadState.NextAt)
        and os.clock() < deadline do
        task.wait(0.05)
    end
    if not running() then return nil, "script stopped before module load" end
    if moduleLoadState.Busy then
        return nil, "module loader timed out behind " .. tostring(moduleLoadState.Owner)
    end
    cached = moduleLoadState.Cache[url]
    if type(cached) == "function" then return cached, nil end

    moduleLoadState.Busy = true
    moduleLoadState.Owner = tostring(label or "optional module")
    if type(statusCallback) == "function" then
        pcall(statusCallback, "Loading " .. moduleLoadState.Owner .. " in the serial module lane...")
    end

    local loaded, controllerOrProblem = pcall(function()
        local source = game:HttpGet(url)
        if type(source) ~= "string" or source == "" then
            error("download returned an empty payload", 0)
        end
        local chunk, compileProblem = loadstring(source)
        source = nil
        if not chunk then error("compile failed: " .. tostring(compileProblem), 0) end
        local controller = chunk()
        chunk = nil
        if type(controller) ~= "function" then
            error("module entrypoint is not a function", 0)
        end
        return controller
    end)

    moduleLoadState.Busy = false
    moduleLoadState.Owner = nil
    moduleLoadState.NextAt = os.clock() + 0.25
    if not loaded then
        trace("module loader", tostring(label) .. " failed: " .. tostring(controllerOrProblem))
        return nil, tostring(controllerOrProblem)
    end
    moduleLoadState.Cache[url] = controllerOrProblem
    trace("module loader", tostring(label) .. " ready")
    return controllerOrProblem, nil
end

local function normalize(value)
    value = string.lower(tostring(value or ""))
    value = string.gsub(value, "[%p_]+", " ")
    value = string.gsub(value, "%s+", " ")
    return string.match(value, "^%s*(.-)%s*$") or value
end

local GRAPHICS_MODULE_URL = "https://raw.githubusercontent.com/destr0f/toolofmind/640ac3ed2edf68868b439b639bb31b3d617d5f43/graphics_module.lua"
local graphicsController

local function graphicsAction(action, value)
    if not graphicsController then
        local controller, problem = loadRemoteController(GRAPHICS_MODULE_URL, "graphics module")
        if not controller then warn("[PSX SLIM] graphics load: " .. tostring(problem)); return false end
        graphicsController = controller
    end

    local called, accepted, problem = pcall(graphicsController, action, value)
    if not called then warn("[PSX SLIM] graphics action: " .. tostring(accepted)); return false end
    if accepted == false then warn("[PSX SLIM] graphics action: " .. tostring(problem)); return false end
    return true
end

local function setPotatoMode(enabled)
    enabled = enabled == true
    if config.PotatoMode == enabled then return end
    config.PotatoMode = enabled
    if not graphicsAction("potato", enabled) then config.PotatoMode = false end
end

local function applyFPSLimit(choice)
    choice = tostring(choice or "Unchanged")
    config.FPSLimit = choice
    if choice ~= "Unchanged" then graphicsAction("fps", choice) end
end

local function stopGraphics()
    if graphicsController then pcall(graphicsController, "stop") end
    graphicsController = nil
end

local function namesMatch(left, right)
    local a, b = normalize(left), normalize(right)
    if a == b then return true end
    if #a < 4 or #b < 4 then return false end
    return string.find(a, b, 1, true) ~= nil or string.find(b, a, 1, true) ~= nil
end

local function formatRateNumber(amount)
    amount = tonumber(amount) or 0
    if amount ~= amount or amount == math.huge or amount == -math.huge then return "0" end
    local suffixes = {
        { 1e33, "Dc" }, { 1e30, "No" }, { 1e27, "Oc" }, { 1e24, "Sp" },
        { 1e21, "Sx" }, { 1e18, "Qi" }, { 1e15, "Qa" }, { 1e12, "T" },
        { 1e9, "B" }, { 1e6, "M" }, { 1e3, "K" },
    }
    for _, suffix in ipairs(suffixes) do
        if math.abs(amount) >= suffix[1] then
            local scaled = amount / suffix[1]
            local pattern = math.abs(scaled) >= 100 and "%.0f%s"
                or math.abs(scaled) >= 10 and "%.1f%s" or "%.2f%s"
            return string.format(pattern, scaled, suffix[2])
        end
    end
    return tostring(math.floor(amount + 0.5))
end

local function normalizeCurrencyName(name)
    local normalized = string.lower(tostring(name or ""))
    normalized = string.gsub(normalized, "[%s_%-]", "")
    return normalized
end

local function readCurrencyNumber(value)
    if type(value) == "number" then return value end
    if type(value) == "string" then return tonumber(value) end
    if type(value) == "table" then
        for _, key in ipairs({ "Value", "value", "Amount", "amount" }) do
            local nested = value[key]
            if type(nested) == "number" then return nested end
            if type(nested) == "string" and tonumber(nested) then return tonumber(nested) end
        end
    end
    if typeof(value) == "Instance" and (value:IsA("IntValue") or value:IsA("NumberValue")) then
        return value.Value
    end
    return nil
end

local function readCurrencyFromTable(container, currencyName)
    if type(container) ~= "table" then return nil end
    local wanted = normalizeCurrencyName(currencyName)
    for key, value in pairs(container) do
        if normalizeCurrencyName(key) == wanted then
            local amount = readCurrencyNumber(value)
            if amount ~= nil then return amount end
        end
    end
    return nil
end

local function getCurrentCurrency(currencyName)
    local save
    if Library.Save and type(Library.Save.Get) == "function" then
        pcall(function() save = Library.Save.Get() end)
    end
    if type(save) == "table" then
        local amount = readCurrencyFromTable(save, currencyName)
            or readCurrencyFromTable(save.Currency, currencyName)
            or readCurrencyFromTable(save.Currencies, currencyName)
        if amount ~= nil then return amount end
    end

    local wanted = normalizeCurrencyName(currencyName)
    local attributesOk, attributes = pcall(function() return player:GetAttributes() end)
    if attributesOk then
        for key, value in pairs(attributes) do
            if normalizeCurrencyName(key) == wanted then
                local amount = readCurrencyNumber(value)
                if amount ~= nil then return amount end
            end
        end
    end
    for _, object in ipairs(player:GetDescendants()) do
        if normalizeCurrencyName(object.Name) == wanted then
            local amount = readCurrencyNumber(object)
            if amount ~= nil then return amount end
        end
    end
    return nil
end

local eggLabelToId = {}
local eggIdToLabel = {}

local WorldOrder = {
    "Spawn World", "Fantasy World", "Tech World", "Axolotl Ocean",
    "Pixel World", "Cat World", "The Void", "Doodle World",
    "Kawaii World", "Dog World", "Diamond Mine", "Christmas Event", "Trading Plaza",
}

local CurrencyChoices = {
    "Active Balances", "Auto", "Coins", "Diamonds", "Fantasy Coins", "Tech Coins",
    "Rainbow Coins", "Cartoon Coins", "Gingerbread",
}

local CurrencyByWorld = {
    ["Spawn World"] = "Coins",
    ["Fantasy World"] = "Fantasy Coins",
    ["Tech World"] = "Tech Coins",
    ["Axolotl Ocean"] = "Rainbow Coins",
    ["Pixel World"] = "Rainbow Coins",
    ["Cat World"] = "Rainbow Coins",
    ["The Void"] = "Rainbow Coins",
    ["Doodle World"] = "Cartoon Coins",
    ["Kawaii World"] = "Cartoon Coins",
    ["Dog World"] = "Cartoon Coins",
    ["Diamond Mine"] = "Diamonds",
    ["Christmas Event"] = "Gingerbread",
    ["Trading Plaza"] = "Coins",
}

local WorldZones = {
    ["Spawn World"] = {
        "Shop", "Town", "Forest", "Beach", "Mine", "Winter", "Glacier",
        "Desert", "Volcano", "Cave", "VIP", "Tech Entry",
    },
    ["Fantasy World"] = {
        "Fantasy Shop", "Enchanted Forest", "Portals", "Ancient Island", "Samurai Island",
        "Candy Island", "Haunted Island", "Hell Island", "Heaven Island", "Heaven's Gate",
    },
    ["Tech World"] = {
        "Tech Shop", "Tech City", "Dark Tech", "Steampunk", "Steampunk Chest",
        "Alien Lab", "Alien Forest", "Giant Alien Chest", "Glitch", "Hacker Portal",
    },
    ["Axolotl Ocean"] = { "Axolotl Ocean", "Axolotl Deep Ocean", "Axolotl Cave" },
    ["Pixel World"] = { "Pixel Forest", "Pixel Kyoto", "Pixel Alps", "Pixel Vault" },
    ["Cat World"] = { "Cat Paradise", "Cat Backyard", "Cat Taiga", "Cat Kingdom", "Cat Throne Room" },
    ["The Void"] = { "The Void" },
    ["Doodle World"] = {
        "Doodle Shop", "Doodle Meadow", "Doodle Peaks", "Doodle Farm", "Doodle Barn",
        "Doodle Oasis", "Doodle Woodlands", "Doodle Safari", "Doodle Fairyland", "Doodle Cave",
    },
    ["Kawaii World"] = { "Kawaii Tokyo", "Kawaii Village", "Kawaii Candyland", "Kawaii Temple", "Kawaii Dojo" },
    ["Dog World"] = { "Dog Park", "Dog City", "Dog Firehouse", "Dog Mansion", "Dog Club" },
    ["Diamond Mine"] = { "Paradise Cave", "Cyber Cavern", "Mystic Mine" },
    ["Christmas Event"] = { "Christmas Event" },
    ["Trading Plaza"] = { "Trading Plaza" },
}

local ZoneAliases = {
    ["Fantasy Shop"] = "Shop",
    ["Tech Shop"] = "Shop",
    ["Doodle Shop"] = "Shop",
    ["Steampunk Chest Area"] = "Steampunk Chest",
}

local WorldAliases = {
    ["spawn"] = "Spawn World",
    ["spawn world"] = "Spawn World",
    ["fantasy"] = "Fantasy World",
    ["fantasy world"] = "Fantasy World",
    ["tech"] = "Tech World",
    ["tech world"] = "Tech World",
    ["axolotl"] = "Axolotl Ocean",
    ["axolotl ocean"] = "Axolotl Ocean",
    ["pixel"] = "Pixel World",
    ["pixel world"] = "Pixel World",
    ["cat"] = "Cat World",
    ["cat world"] = "Cat World",
    ["void"] = "The Void",
    ["the void"] = "The Void",
    ["doodle"] = "Doodle World",
    ["doodle world"] = "Doodle World",
    ["kawaii"] = "Kawaii World",
    ["kawaii world"] = "Kawaii World",
    ["dog"] = "Dog World",
    ["dog world"] = "Dog World",
    ["diamond mine"] = "Diamond Mine",
    ["christmas"] = "Christmas Event",
    ["christmas event"] = "Christmas Event",
    ["trading plaza"] = "Trading Plaza",
}

local function readObjectValue(object, name)
    if not object then return nil end
    local child = object:FindFirstChild(name .. "_Attr") or object:FindFirstChild(name)
    if child then
        local ok, value = pcall(function() return child.Value end)
        if ok and value ~= nil then return value end
    end
    local ok, value = pcall(function()
        return object:GetAttribute(name .. "_Attr") or object:GetAttribute(name)
    end)
    return ok and value or nil
end

local function getInstancePosition(object)
    if not object then return nil end
    local pos = object:FindFirstChild("POS") or object:FindFirstChild("Coin")
    if pos then
        if pos:IsA("BasePart") then return pos.Position end
        local part = pos:FindFirstChildWhichIsA("BasePart", true)
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

local boundsCache = setmetatable({}, { __mode = "k" })

local function getBounds(area)
    local cached = boundsCache[area]
    if cached then return cached.CFrame, cached.Size end

    local cf, size
    if area:IsA("BasePart") then
        cf, size = area.CFrame, area.Size
    elseif area:IsA("Model") then
        pcall(function() cf, size = area:GetBoundingBox() end)
    end
    if not cf then
        local low, high
        for _, item in ipairs(area:GetDescendants()) do
            if item:IsA("BasePart") then
                local half = item.Size / 2
                local itemLow, itemHigh = item.Position - half, item.Position + half
                low = low and Vector3.new(
                    math.min(low.X, itemLow.X), math.min(low.Y, itemLow.Y), math.min(low.Z, itemLow.Z)
                ) or itemLow
                high = high and Vector3.new(
                    math.max(high.X, itemHigh.X), math.max(high.Y, itemHigh.Y), math.max(high.Z, itemHigh.Z)
                ) or itemHigh
            end
        end
        if low and high then cf, size = CFrame.new((low + high) / 2), high - low end
    end

    if cf and size then boundsCache[area] = { CFrame = cf, Size = size } end
    return cf, size
end

local function areaForPosition(position)
    if typeof(position) ~= "Vector3" then return nil end
    local map = workspace:FindFirstChild("__MAP")
    local areas = map and map:FindFirstChild("Areas")
    if not areas then return nil end

    local insideName, insideVolume = nil, math.huge
    local nearestName, nearestDistance = nil, math.huge
    for _, area in ipairs(areas:GetChildren()) do
        local cf, size = getBounds(area)
        if cf and size then
            local point = cf:PointToObjectSpace(position)
            local half = size / 2 + Vector3.new(8, 25, 8)
            if math.abs(point.X) <= half.X
                and math.abs(point.Y) <= half.Y
                and math.abs(point.Z) <= half.Z then
                local volume = math.max(size.X, 1) * math.max(size.Z, 1)
                if volume < insideVolume then
                    insideName, insideVolume = area.Name, volume
                end
            end
            local distance = (cf.Position - position).Magnitude
            if distance < nearestDistance then
                nearestName, nearestDistance = area.Name, distance
            end
        end
    end
    return insideName or nearestName
end

local currentZone, currentZoneAnchor, nextZoneCheck = nil, nil, 0
local BossChestZones
local coinRecords = {}
local requestAllocatorPulse
local releaseAssignmentsForCoin
local requestFarmReset

local function getPlayerZone()
    if os.clock() < nextZoneCheck then return currentZone end
    nextZoneCheck = os.clock() + 0.1
    local character = player.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    currentZone = root and areaForPosition(root.Position) or nil
    currentZoneAnchor = nil
    if root and BossChestZones then
        local nearestZone, nearestAnchor, nearestDistance = nil, nil, math.huge
        for _, record in pairs(coinRecords) do
            local bossZone = BossChestZones[normalize(record.Name)]
            if bossZone and typeof(record.Position) == "Vector3" then
                local distance = (record.Position - root.Position).Magnitude
                if distance < nearestDistance then
                    nearestZone, nearestAnchor, nearestDistance = bossZone, record.Position, distance
                end
            end
        end
        if nearestZone and nearestDistance <= 180 then
            currentZone = nearestZone
            currentZoneAnchor = nearestAnchor
        end
    end
    return currentZone
end

local BossChestNames = {
    ["magma chest"] = true,
    ["volcano magma chest"] = true,
    ["giant tech chest"] = true,
    ["tech entry giant tech chest"] = true,
    ["ancient chest"] = true,
    ["ancient huge chest"] = true,
    ["haunted chest"] = true,
    ["huge haunted chest"] = true,
    ["hell chest"] = true,
    ["huge hell chest"] = true,
    ["huge heaven chest"] = true,
    ["giant heaven chest"] = true,
    ["grand heaven chest"] = true,
    ["heavens gate grand heaven chest"] = true,
    ["giant steampunk chest"] = true,
    ["giant alien chest"] = true,
    ["hacker chest"] = true,
    ["giant hacker chest"] = true,
    ["giant ocean chest"] = true,
    ["ocean chest"] = true,
    ["giant underwater chest"] = true,
    ["giant pixel chest"] = true,
    ["giant cat chest"] = true,
    ["giant throne chest"] = true,
    ["giant doodle oasis chest"] = true,
    ["giant doodle barn chest"] = true,
    ["giant doodle chest"] = true,
    ["giant doodle cave chest"] = true,
    ["kawaii temple chest"] = true,
    ["giant kawaii temple chest"] = true,
    ["dojo chest"] = true,
    ["kawaii dojo chest"] = true,
    ["kawaii alley chest"] = true,
    ["giant kawaii alley chest"] = true,
    ["giant dog chest"] = true,
    ["giant disco chest"] = true,
    ["afk chest"] = true,
    ["giant afk chest"] = true,
}

BossChestZones = {
    ["magma chest"] = "Volcano",
    ["volcano magma chest"] = "Volcano",
    ["giant tech chest"] = "Tech Entry",
    ["tech entry giant tech chest"] = "Tech Entry",
    ["grand heaven chest"] = "Heaven's Gate",
    ["heavens gate grand heaven chest"] = "Heaven's Gate",
    ["giant steampunk chest"] = "Steampunk Chest",
    ["giant alien chest"] = "Giant Alien Chest",
    ["hacker chest"] = "Hacker Portal",
    ["giant hacker chest"] = "Hacker Portal",
}

local cachedWorld, nextWorldCheck = nil, 0

local function resolveWorldName(rawWorld)
    if rawWorld == nil then return nil end
    local alias = WorldAliases[normalize(rawWorld)]
    if alias then return alias end
    for _, worldName in ipairs(WorldOrder) do
        if namesMatch(rawWorld, worldName) then return worldName end
    end
    return tostring(rawWorld)
end

local function getLiveAreaNames()
    local names = {}
    local map = workspace:FindFirstChild("__MAP")
    local areas = map and map:FindFirstChild("Areas")
    if areas then
        for _, area in ipairs(areas:GetChildren()) do table.insert(names, area.Name) end
        table.sort(names)
    end
    return names
end

local function getCurrentWorld()
    if os.clock() < nextWorldCheck and cachedWorld then return cachedWorld end
    nextWorldCheck = os.clock() + 0.25

    local worldCmds = Library and Library.WorldCmds
    if worldCmds and type(worldCmds.Get) == "function" then
        local ok, rawWorld = pcall(worldCmds.Get)
        if ok and rawWorld then
            cachedWorld = resolveWorldName(rawWorld)
            return cachedWorld
        end
    end

    local counts = {}
    for _, record in pairs(coinRecords) do
        local worldName = resolveWorldName(record.World)
        if worldName then counts[worldName] = (counts[worldName] or 0) + 1 end
    end
    local bestWorld, bestCount = nil, 0
    for worldName, count in pairs(counts) do
        if count > bestCount then bestWorld, bestCount = worldName, count end
    end

    if not bestWorld then
        local liveAreas = getLiveAreaNames()
        for worldName, zones in pairs(WorldZones) do
            local score = 0
            for _, areaName in ipairs(liveAreas) do
                for _, zoneName in ipairs(zones) do
                    if namesMatch(areaName, ZoneAliases[zoneName] or zoneName) then
                        score = score + 1
                        break
                    end
                end
            end
            if score > bestCount then bestWorld, bestCount = worldName, score end
        end
    end

    cachedWorld = bestWorld or "Unknown World"
    return cachedWorld
end

local function worldMatches(rawWorld, displayWorld)
    if rawWorld == nil or rawWorld == "" then return true end
    return namesMatch(resolveWorldName(rawWorld), displayWorld)
end

local function getSelectedWorld()
    return config.World == "Current World" and getCurrentWorld() or config.World
end

local function getTrackedCurrencyName()
    if config.TrackedCurrency == "Active Balances" then return nil end
    if config.TrackedCurrency ~= "Auto" then return config.TrackedCurrency end
    return CurrencyByWorld[getSelectedWorld()] or "Coins"
end

local currencyMonitor = {
    Samples = {},
    Names = {
        "Coins", "Diamonds", "Fantasy Coins", "Tech Coins",
        "Rainbow Coins", "Cartoon Coins", "Gingerbread",
    },
}

function currencyMonitor:Reset()
    table.clear(self.Samples)
    self.StartedAt = os.clock()
end

function currencyMonitor:TrackedNames()
    if config.TrackedCurrency == "Active Balances" then return self.Names end
    local selected = getTrackedCurrencyName()
    return selected and { selected } or {}
end

function currencyMonitor:GetBalances(currencyNames)
    local balances = {}
    local save
    if Library.Save and type(Library.Save.Get) == "function" then
        pcall(function() save = Library.Save.Get() end)
    end
    for _, currencyName in ipairs(currencyNames) do
        local amount
        if type(save) == "table" then
            amount = readCurrencyFromTable(save, currencyName)
                or readCurrencyFromTable(save.Currency, currencyName)
                or readCurrencyFromTable(save.Currencies, currencyName)
        end
        if amount == nil then amount = getCurrentCurrency(currencyName) end
        if amount ~= nil then balances[currencyName] = amount end
    end
    return balances
end

function currencyMonitor:Update(currencyName, currentAmount, now)
    local sample = self.Samples[currencyName]
    if type(sample) ~= "table" then
        sample = {
            StartedAt = now,
            FirstBalance = currentAmount,
            LastBalance = currentAmount,
            TotalEarned = 0,
            TotalSpent = 0,
            History = { { Time = now, Earned = 0 } },
        }
        self.Samples[currencyName] = sample
        return sample
    end

    local delta = currentAmount - sample.LastBalance
    if delta > 0 then
        sample.TotalEarned = sample.TotalEarned + delta
        sample.LastGainAt = now
        sample.LastGain = delta
    elseif delta < 0 then
        sample.TotalSpent = sample.TotalSpent - delta
        sample.LastSpendAt = now
    end
    sample.LastBalance = currentAmount

    local history = sample.History
    history[#history + 1] = { Time = now, Earned = sample.TotalEarned }
    while #history > 2 and history[2].Time <= now - 60 do table.remove(history, 1) end
    local base = history[1]
    sample.WindowSeconds = math.max(0, now - base.Time)
    sample.WindowEarned = math.max(0, sample.TotalEarned - base.Earned)
    sample.SessionSeconds = math.max(0, now - sample.StartedAt)
    sample.PerMinute = sample.SessionSeconds > 0
        and sample.TotalEarned * 60 / sample.SessionSeconds or 0
    return sample
end

function currencyMonitor:RateLine(currencyName, sample, now)
    local inactiveFor = sample.LastGainAt and math.max(0, now - sample.LastGainAt) or nil
    local idleText = inactiveFor and (" | last gain " .. tostring(math.floor(inactiveFor + 0.5)) .. "s ago") or ""
    return string.format(
        "%s: %s/min session avg | last 60s +%s | total +%s | balance %s%s",
        currencyName,
        formatRateNumber(sample.PerMinute or 0),
        formatRateNumber(sample.WindowEarned or 0),
        formatRateNumber(sample.TotalEarned or 0),
        formatRateNumber(sample.LastBalance or 0),
        idleText
    )
end

local function getSelectedZone()
    if config.Zone == "Player Zone" then return getPlayerZone() end
    return ZoneAliases[config.Zone] or config.Zone
end

local function getZoneOptions(worldChoice)
    local options, seen = {}, {}
    local resolvedWorld = worldChoice == "Current World" and getCurrentWorld() or worldChoice
    local function add(zoneName)
        local key = normalize(zoneName)
        if key ~= "" and not seen[key] then
            seen[key] = true
            table.insert(options, tostring(zoneName))
        end
    end

    if worldChoice == "Current World" then add("Player Zone") end
    for _, zoneName in ipairs(WorldZones[resolvedWorld] or {}) do add(zoneName) end
    if worldChoice == "Current World" then
        for _, zoneName in ipairs(getLiveAreaNames()) do add(zoneName) end
    end
    for _, record in pairs(coinRecords) do
        if worldMatches(record.World, resolvedWorld) then
            add(BossChestZones[normalize(record.Name)] or record.Area)
        end
    end
    return options, resolvedWorld
end

local peakHealth = {}
local snapshotBusy = false
local nextSnapshotAt = 0
local coinSignalsReady = false
local coinGeneration = 0
local coinEventRevision = 0
local removalRevisions = {}
local removedUntil = {}
local coinIndex = {
    Revision = 0,
    Models = {},
    IdByModel = setmetatable({}, { __mode = "k" }),
    Folder = nil,
    Connections = {},
    Cache = {
        Signature = nil,
        Revision = -1,
        Targets = {},
        World = nil,
        Zone = nil,
    },
}

function coinIndex:Invalidate()
    self.Revision = self.Revision + 1
    self.Cache.Revision = -1
end

local function normalizePetSet(rawPets)
    local result = {}
    if type(rawPets) ~= "table" then return result end
    for key, value in pairs(rawPets) do
        local petId
        if type(key) == "number" then
            petId = type(value) == "table" and (value.uid or value.id) or value
        elseif value == true then
            petId = key
        elseif type(value) == "table" then
            petId = value.uid or value.id or key
        elseif type(value) == "string" then
            petId = value
        elseif value ~= nil and value ~= false then
            petId = key
        end
        if petId ~= nil then result[tostring(petId)] = true end
    end
    return result
end

local function applyCoinData(rawId, data, fromEvent)
    if rawId == nil or type(data) ~= "table" then return nil end
    local id = tostring(rawId)
    local created = coinRecords[id] == nil
    local record = coinRecords[id] or { Id = id, Pets = {} }
    coinRecords[id] = record
    local selectionChanged = created
    local previousHealth = tonumber(record.Health)

    local health = tonumber(data.h or data.Health or data.health)
    local maxHealth = tonumber(data.mh or data.MaxHealth or data.maxHealth)
    local position = data.p or data.Position or data.position
    local world = data.w or data.World or data.world
    if typeof(position) == "CFrame" then position = position.Position end

    if data.a ~= nil or data.Area ~= nil or data.area ~= nil then
        local value = tostring(data.a or data.Area or data.area)
        if record.Area ~= value then record.Area = value; selectionChanged = true end
    end
    if data.n ~= nil or data.Name ~= nil or data.name ~= nil then
        local value = tostring(data.n or data.Name or data.name)
        if record.Name ~= value then record.Name = value; selectionChanged = true end
    end
    if world ~= nil then
        local value = tostring(world)
        if record.World ~= value then record.World = value; selectionChanged = true end
    end
    if typeof(position) == "Vector3" and record.Position ~= position then
        record.Position = position
        record.DetectedArea = nil
        record.DetectedPosition = nil
        selectionChanged = true
    end
    if health ~= nil then record.Health = health end
    if maxHealth ~= nil and tonumber(record.MaxHealth) ~= maxHealth then
        record.MaxHealth = maxHealth
        selectionChanged = true
    end
    record.Health = tonumber(record.Health) or 0
    if previousHealth ~= nil and ((previousHealth > 0) ~= (record.Health > 0)) then
        selectionChanged = true
    end
    local previousPeak = peakHealth[id] or 0
    local previousMax = tonumber(record.MaxHealth) or 0
    peakHealth[id] = math.max(peakHealth[id] or 0, record.Health, tonumber(record.MaxHealth) or 0)
    record.MaxHealth = math.max(tonumber(record.MaxHealth) or 0, peakHealth[id], record.Health)
    if peakHealth[id] ~= previousPeak or record.MaxHealth ~= previousMax then selectionChanged = true end
    record.Removed = false
    record.FromServer = true
    if fromEvent then
        coinEventRevision = coinEventRevision + 1
        record.EventRevision = coinEventRevision
        removalRevisions[id] = nil
        removedUntil[id] = nil
    end

    local pets = data.pets or data.Pets
    if pets ~= nil then record.Pets = normalizePetSet(pets) end
    local farmingPets = data.petsFarming or data.PetsFarming
    if farmingPets ~= nil then record.PetsFarming = normalizePetSet(farmingPets) end
    if selectionChanged then coinIndex:Invalidate() end
    if fromEvent and type(requestAllocatorPulse) == "function" then requestAllocatorPulse() end
    return record
end

local function removeCoin(rawId, fromEvent)
    local id = tostring(rawId)
    if fromEvent then
        coinEventRevision = coinEventRevision + 1
        removalRevisions[id] = coinEventRevision
    end
    local record = coinRecords[id]
    if record then
        record.Health = 0
        record.Removed = true
        record.Pets = {}
        record.PetsFarming = {}
    end
    coinRecords[id] = nil
    peakHealth[id] = nil
    local model = coinIndex.Models[id]
    if model then coinIndex.IdByModel[model] = nil end
    coinIndex.Models[id] = nil
    removedUntil[id] = os.clock() + 0.75
    coinIndex:Invalidate()
    if type(releaseAssignmentsForCoin) == "function" then releaseAssignmentsForCoin(id) end
    if type(requestAllocatorPulse) == "function" then requestAllocatorPulse() end
end

local nextWorkspaceScanAt = 0
function coinIndex:DisconnectFolder()
    for _, connection in ipairs(self.Connections) do
        pcall(function() connection:Disconnect() end)
    end
    table.clear(self.Connections)
    self.Folder = nil
end

function coinIndex:IndexModel(model, refreshHealth)
    if not model then return nil end
    local id = tostring(readObjectValue(model, "ID") or model.Name)
    if removedUntil[id] ~= nil then return nil end

    local record = coinRecords[id] or { Id = id, Pets = {} }
    local created = coinRecords[id] == nil
    local modelChanged = record.Model ~= model
    local selectionChanged = created or modelChanged
    coinRecords[id] = record
    self.Models[id] = model
    self.IdByModel[model] = id
    record.Model = model
    record.NextModelLookupAt = nil

    if modelChanged or not record.WorkspaceIndexed then
        local position = getInstancePosition(model)
        local area = readObjectValue(model, "Area")
        local name = readObjectValue(model, "Name") or model.Name
        local world = readObjectValue(model, "World")
        if position and record.Position ~= position then
            record.Position = position
            record.DetectedArea = nil
            record.DetectedPosition = nil
            selectionChanged = true
        end
        if area ~= nil and record.Area ~= area then record.Area = area; selectionChanged = true end
        if name ~= nil and record.Name ~= name then record.Name = name; selectionChanged = true end
        if world ~= nil and record.World ~= world then record.World = world; selectionChanged = true end
        record.WorkspaceIndexed = true
    end

    -- Live Network health/removal events are authoritative. Reading all 128+
    -- workspace Health attributes is only a fallback for records that have not
    -- appeared in the server snapshot yet.
    if refreshHealth and not record.FromServer then
        local previousHealth = tonumber(record.Health)
        local health = tonumber(readObjectValue(model, "Health"))
        if health ~= nil then
            if record.FromServer and tonumber(record.Health) ~= nil then
                record.Health = math.min(tonumber(record.Health), health)
            else
                record.Health = health
            end
            local previousPeak = peakHealth[id] or 0
            local previousMax = tonumber(record.MaxHealth) or 0
            peakHealth[id] = math.max(previousPeak, health)
            record.MaxHealth = math.max(previousMax, peakHealth[id])
            if peakHealth[id] ~= previousPeak or record.MaxHealth ~= previousMax then
                selectionChanged = true
            end
            if previousHealth ~= nil and ((previousHealth > 0) ~= (record.Health > 0)) then
                selectionChanged = true
            end
        end
    end
    record.Removed = false
    if selectionChanged then self:Invalidate() end
    return id, record
end

function coinIndex:WatchFolder(folder)
    if self.Folder == folder then return end
    self:DisconnectFolder()
    self.Folder = folder
    if not folder then return end

    self.Connections[#self.Connections + 1] = folder.ChildAdded:Connect(function(model)
        task.defer(function()
            if not running() or model.Parent ~= folder then return end
            self:IndexModel(model, true)
            if type(requestAllocatorPulse) == "function" then requestAllocatorPulse() end
        end)
    end)
    self.Connections[#self.Connections + 1] = folder.ChildRemoved:Connect(function(model)
        local id = self.IdByModel[model]
        if not id then return end
        self.IdByModel[model] = nil
        if self.Models[id] == model then self.Models[id] = nil end
        local record = coinRecords[id]
        if record and record.Model == model then
            record.Model = nil
            record.WorkspaceIndexed = nil
            record.NextModelLookupAt = nil
            if not record.FromServer then removeCoin(id, false) end
        end
    end)
end

local function refreshWorkspaceCoins(force)
    if not force and os.clock() < nextWorkspaceScanAt then return end
    nextWorkspaceScanAt = os.clock() + 1.25
    local things = workspace:FindFirstChild("__THINGS")
    local folder = things and things:FindFirstChild("Coins")
    coinIndex:WatchFolder(folder)
    if not folder then return end

    local now = os.clock()
    for id, expiresAt in pairs(removedUntil) do
        if now >= expiresAt then removedUntil[id] = nil end
    end
    local seen = {}
    for _, model in ipairs(folder:GetChildren()) do
        local id = coinIndex:IndexModel(model, true)
        if id then seen[id] = true end
    end

    local staleIds = {}
    for id, record in pairs(coinRecords) do
        if record.Model and not seen[id] and not record.FromServer then
            table.insert(staleIds, id)
        end
    end
    for _, id in ipairs(staleIds) do removeCoin(id) end
end

local function refreshCoinSnapshot()
    if snapshotBusy then return end
    local network = networkReady()
    if not network then return end
    snapshotBusy = true
    local generation = coinGeneration
    local revisionAtStart = coinEventRevision
    local ok, response = pcall(network.Invoke, "Get Coins")
    if generation ~= coinGeneration then
        snapshotBusy = false
        nextSnapshotAt = 0
        return
    end
    if ok and type(response) == "table" then
        local seen = {}
        for id, data in pairs(response) do
            if type(data) == "table" then
                id = tostring(id)
                local removalRevision = removalRevisions[id] or 0
                local record = coinRecords[id]
                local recordRevision = record and (record.EventRevision or 0) or 0
                if removalRevision <= revisionAtStart then
                    seen[id] = true
                    removalRevisions[id] = nil
                    if recordRevision <= revisionAtStart then applyCoinData(id, data, false) end
                end
            end
        end
        for id, record in pairs(coinRecords) do
            if record.FromServer and not seen[id] and (record.EventRevision or 0) <= revisionAtStart then
                removeCoin(id, false)
            end
        end
        nextSnapshotAt = os.clock() + 3
    else
        nextSnapshotAt = os.clock() + 0.5
    end
    snapshotBusy = false
end

local function connectCoinSignals()
    if coinSignalsReady then return end
    local network = networkReady()
    if not network or type(network.Fired) ~= "function" then return end

    local function connect(name, callback)
        local ok, signal = pcall(network.Fired, name)
        if ok and signal and type(signal.Connect) == "function" then
            local connected, connection = pcall(function()
                return signal:Connect(function(...)
                    local handled, problem = pcall(callback, ...)
                    if not handled then warn("[PSX SLIM] " .. name .. ": " .. tostring(problem)) end
                end)
            end)
            if connected and connection then track(connection) end
        end
    end

    connect("New Coin", function(id, data) applyCoinData(id, data, true) end)
    connect("Update Coin Health", function(id, health)
        local record = coinRecords[tostring(id)]
        if record then
            local value = tonumber(health) or record.Health
            if (value or 0) <= 0 then
                removeCoin(id, true)
            else
                coinEventRevision = coinEventRevision + 1
                record.Health = value
                record.EventRevision = coinEventRevision
            end
        else
            nextSnapshotAt = 0
        end
    end)
    connect("Update Coin Pets", function(id, pets)
        local record = coinRecords[tostring(id)]
        if record then
            coinEventRevision = coinEventRevision + 1
            record.Pets = normalizePetSet(pets)
            record.EventRevision = coinEventRevision
            if type(requestAllocatorPulse) == "function" then requestAllocatorPulse() end
        else
            nextSnapshotAt = 0
        end
    end)
    connect("Remove Coin", function(id) removeCoin(id, true) end)

    local signal = Library.Signal
    if signal and type(signal.Fired) == "function" then
        pcall(function()
            local worldChanged = signal.Fired("World Changed")
            track(worldChanged:Connect(function()
                coinGeneration = coinGeneration + 1
                coinEventRevision = 0
                table.clear(coinRecords)
                table.clear(peakHealth)
                table.clear(removalRevisions)
                table.clear(removedUntil)
                table.clear(coinIndex.Models)
                table.clear(coinIndex.IdByModel)
                table.clear(boundsCache)
                coinIndex:DisconnectFolder()
                coinIndex:Invalidate()
                if type(releaseAssignmentsForCoin) == "function" then releaseAssignmentsForCoin(nil) end
                currentZone = nil
                currentZoneAnchor = nil
                nextZoneCheck = 0
                cachedWorld = nil
                nextWorldCheck = 0
                nextWorkspaceScanAt = 0
                nextSnapshotAt = 0
                if config.PetFarm and type(requestFarmReset) == "function" then
                    requestFarmReset("world changed")
                end
            end))
        end)
    end
    coinSignalsReady = true
end

local cachedPetIds = {}
local nextPetScanAt = 0
local function getEquippedPetIds()
    if os.clock() < nextPetScanAt then return cachedPetIds end
    nextPetScanAt = os.clock() + 0.1
    local save
    if Library.Save and type(Library.Save.Get) == "function" then
        pcall(function() save = Library.Save.Get() end)
    end
    local ids = {}
    for _, pet in pairs((save and save.Pets) or {}) do
        if type(pet) == "table" and pet.e and pet.uid then
            table.insert(ids, tostring(pet.uid))
        end
    end
    table.sort(ids)
    cachedPetIds = ids
    return cachedPetIds
end

local function recordAlive(record)
    if not record or record.Removed or (tonumber(record.Health) or 0) <= 0 then return false end
    if os.clock() < (removedUntil[tostring(record.Id)] or 0) then return false end
    -- Animated/potato-mode models can be replaced locally while the server coin
    -- is still alive. Keep the authoritative record and reacquire its model.
    if record.Model and record.Model.Parent == nil then
        if record.FromServer then record.Model = nil else return false end
    end
    return true
end

local function isBossChest(record)
    return BossChestNames[normalize(record and record.Name)] == true
end

local function findZoneAnchor(zone)
    if currentZoneAnchor and namesMatch(zone, currentZone) then return currentZoneAnchor end
    for _, record in pairs(coinRecords) do
        local bossZone = BossChestZones[normalize(record.Name)]
        if bossZone and namesMatch(bossZone, zone) and typeof(record.Position) == "Vector3" then
            return record.Position
        end
    end
    local map = workspace:FindFirstChild("__MAP")
    local areas = map and map:FindFirstChild("Areas")
    if areas then
        for _, area in ipairs(areas:GetChildren()) do
            if namesMatch(area.Name, zone) then
                local cf = getBounds(area)
                if cf then return cf.Position end
            end
        end
    end
    return nil
end

local function recordInZone(record, zone, zoneAnchor)
    if not recordAlive(record) or not zone then return false end
    local normalizedName = normalize(record.Name)
    local bossZone = BossChestZones[normalizedName]
    if bossZone and namesMatch(bossZone, zone) then return true end
    if record.Area and namesMatch(record.Area, zone) then return true end
    if record.Name and namesMatch(record.Name, zone) then return true end
    if record.Position and record.DetectedPosition ~= record.Position then
        record.DetectedPosition = record.Position
        record.DetectedArea = areaForPosition(record.Position)
    end
    local detected = record.DetectedArea
    if detected ~= nil then return namesMatch(detected, zone) end
    return zoneAnchor ~= nil and record.Position ~= nil
        and (record.Position - zoneAnchor).Magnitude <= 240
end

local function orderedTargets(mode)
    refreshWorkspaceCoins()
    local world = getSelectedWorld()
    local zone = getSelectedZone()
    local signature = table.concat({ tostring(mode), tostring(world), tostring(zone) }, "|")
    local cache = coinIndex.Cache
    if cache.Revision == coinIndex.Revision and cache.Signature == signature then
        return cache.Targets, cache.World, cache.Zone
    end
    local zoneAnchor = findZoneAnchor(zone)
    local targets = {}
    for _, record in pairs(coinRecords) do
        local boss = isBossChest(record)
        local allowed = mode == "Boss Chest Only" and boss or mode ~= "Boss Chest Only" and not boss
        if allowed and worldMatches(record.World, world) and recordInZone(record, zone, zoneAnchor) then
            table.insert(targets, record)
        end
    end

    local strongest = mode ~= "Different Weakest"
    table.sort(targets, function(left, right)
        local leftMax = tonumber(left.MaxHealth) or tonumber(left.Health) or 0
        local rightMax = tonumber(right.MaxHealth) or tonumber(right.Health) or 0
        if leftMax ~= rightMax then
            if strongest then return leftMax > rightMax end
            return leftMax < rightMax
        end
        local leftHealth = tonumber(left.Health) or 0
        local rightHealth = tonumber(right.Health) or 0
        if leftHealth ~= rightHealth then
            if strongest then return leftHealth > rightHealth end
            return leftHealth < rightHealth
        end
        return left.Id < right.Id
    end)
    cache.Signature = signature
    cache.Revision = coinIndex.Revision
    cache.Targets = targets
    cache.World = world
    cache.Zone = zone
    return targets, world, zone
end

local petStates = {}
local rejectedUntil = {}
local releaseWait = {}
local farmResetRunning = false
local farmResetRequested = false
local farmResetReason = "startup"
local farmSelectionSignature = nil
local allocatorBusy = false
local allocatorRequested = false
local driverStatus = "waiting for first target"
local idleRecoveryCount = 0
local lastRecovery = "none"
local controllerHandlers = {}
local nextControllerLookup = {}
local petRuntime = nil
local runtimeDriverReady = false
local petFarm = {
    Engine = nil,
    Loading = false,
    Problem = nil,
    AllocatorScheduled = false,
    RouteSummary = "resolving 0/4",
    StatsCache = {
        Version = "loading",
        Active = 0,
        Queued = 0,
        Limit = 0,
        Accepted = 0,
        Rejected = 0,
        Errors = 0,
        Retries = 0,
        AverageRTT = 0,
        LastProblem = "none",
    },
}

local function queuePetRelease(petId, now)
    petStates[petId] = nil
    releaseWait[petId] = {
        ReadyAt = now,
        ForceAt = now,
    }
end

releaseAssignmentsForCoin = function(rawId)
    if rawId == nil then
        if petFarm.Engine then pcall(petFarm.Engine, "reset") end
        table.clear(petStates)
        table.clear(rejectedUntil)
        table.clear(releaseWait)
        return
    end

    local coinId = tostring(rawId)
    local now = os.clock()
    for petId, state in pairs(petStates) do
        if tostring(state.CoinId) == coinId then
            queuePetRelease(petId, now)
        end
    end
    rejectedUntil[coinId] = nil
end

local function functionUpvalues(callback)
    local values = {}
    if type(callback) ~= "function" then return values end

    local seenValues = {}
    local seenReaders = {}
    local bulkReaders = {
        type(getupvalues) == "function" and getupvalues or nil,
        debug and type(debug.getupvalues) == "function" and debug.getupvalues or nil,
    }
    for _, reader in next, bulkReaders do
        if type(reader) == "function" and not seenReaders[reader] then
            seenReaders[reader] = true
            local ok, result = pcall(reader, callback)
            if ok and type(result) == "table" then
                for _, value in next, result do
                    if value ~= nil and not seenValues[value] then
                        seenValues[value] = true
                        table.insert(values, value)
                    end
                end
            end
        end
    end
    if #values > 0 then return values end

    local singleReaders = {
        type(getupvalue) == "function" and getupvalue or nil,
        debug and type(debug.getupvalue) == "function" and debug.getupvalue or nil,
    }
    table.clear(seenReaders)
    for _, reader in next, singleReaders do
        if type(reader) == "function" and not seenReaders[reader] then
            seenReaders[reader] = true
            for index = 1, 64 do
                local ok, first, second = pcall(reader, callback, index)
                if not ok or (first == nil and second == nil) then break end
                local value
                if second ~= nil then value = second else value = first end
                if value ~= nil and not seenValues[value] then
                    seenValues[value] = true
                    table.insert(values, value)
                end
            end
        end
    end
    return values
end

local function functionUpvalueAt(callback, index)
    if type(callback) ~= "function" then return nil, "callback is not a function" end

    local seenReaders = {}
    local singleReaders = {
        debug and type(debug.getupvalue) == "function" and debug.getupvalue or nil,
        type(getupvalue) == "function" and getupvalue or nil,
    }
    for _, reader in next, singleReaders do
        if type(reader) == "function" and not seenReaders[reader] then
            seenReaders[reader] = true
            local ok, first, second = pcall(reader, callback, index)
            if ok then
                if second ~= nil then
                    return second, "single reader #" .. tostring(index)
                end
                -- Executor debug APIs commonly return only the value. Standard Lua
                -- returns an upvalue name first, so do not mistake that name for data.
                if first ~= nil and type(first) ~= "string" then
                    return first, "single reader #" .. tostring(index)
                end
            end
        end
    end

    local bulkReaders = {
        type(getupvalues) == "function" and getupvalues or nil,
        debug and type(debug.getupvalues) == "function" and debug.getupvalues or nil,
    }
    for _, reader in next, bulkReaders do
        if type(reader) == "function" and not seenReaders[reader] then
            seenReaders[reader] = true
            local ok, values = pcall(reader, callback)
            if ok and type(values) == "table" then
                local value = rawget(values, index)
                if value == nil and index == 2 then
                    value = rawget(values, "u18") or rawget(values, "GetRemoteFunction")
                end
                if value ~= nil then
                    return value, "bulk reader #" .. tostring(index)
                end
            end
        end
    end
    return nil, "upvalue #" .. tostring(index) .. " is unavailable"
end

local commandRemoteCache = {}
local commandRemoteSource = "Network.Invoke GetRemoteFunction upvalue #2"

local function remoteSessionIndex(remote)
    if typeof(remote) ~= "Instance" then return nil end
    return table.find(ReplicatedStorage:GetChildren(), remote)
end

local function getCommandRemote(commandName)
    local cached = commandRemoteCache[commandName]
    if typeof(cached) == "Instance" and cached:IsA("RemoteFunction")
        and cached:IsDescendantOf(ReplicatedStorage) then
        return cached, commandRemoteSource, remoteSessionIndex(cached), nil
    end
    commandRemoteCache[commandName] = nil

    local network = networkReady()
    if not network or type(network.Invoke) ~= "function" then
        return nil, commandRemoteSource, nil, "Library.Network.Invoke is unavailable"
    end

    local accessor, reader = functionUpvalueAt(network.Invoke, 2)
    if type(accessor) ~= "function" then
        return nil, commandRemoteSource, nil,
            "GetRemoteFunction accessor is unavailable (" .. tostring(reader) .. ")"
    end

    local ok, first, second, third = pcall(accessor, commandName)
    if not ok then
        return nil, commandRemoteSource, nil,
            "GetRemoteFunction failed: " .. tostring(first)
    end

    local values = { first, second, third }
    for index = 1, 3 do
        local remote = values[index]
        if typeof(remote) == "Instance" and remote:IsA("RemoteFunction")
            and remote:IsDescendantOf(ReplicatedStorage) then
            commandRemoteCache[commandName] = remote
            local sourceName = commandRemoteSource .. " (" .. tostring(reader) .. ")"
            return remote, sourceName, remoteSessionIndex(remote), nil
        end
    end

    return nil, commandRemoteSource, nil,
        tostring(commandName) .. " did not resolve to a live RemoteFunction"
end

local eventRemoteCache = {}
local eventRemoteSource = "Network.Fired GetRemoteEvent upvalue"

local function getEventRemote(commandName)
    local cached = eventRemoteCache[commandName]
    if typeof(cached) == "Instance" and cached:IsA("RemoteEvent")
        and cached:IsDescendantOf(ReplicatedStorage) then
        return cached, eventRemoteSource, remoteSessionIndex(cached), nil
    end
    eventRemoteCache[commandName] = nil

    local network = networkReady()
    if not network or type(network.Fired) ~= "function" then
        return nil, eventRemoteSource, nil, "Library.Network.Fired is unavailable"
    end

    local lastProblem = "GetRemoteEvent accessor was not exposed"
    for index = 1, 8 do
        local candidate, reader = functionUpvalueAt(network.Fired, index)
        if typeof(candidate) == "Instance" and candidate:IsA("RemoteEvent")
            and candidate:IsDescendantOf(ReplicatedStorage) then
            eventRemoteCache[commandName] = candidate
            eventRemoteSource = "Network.Fired direct RemoteEvent upvalue #" .. tostring(index)
                .. " (" .. tostring(reader) .. ")"
            return candidate, eventRemoteSource, remoteSessionIndex(candidate), nil
        end

        if type(candidate) == "table" then
            local mapped = rawget(candidate, commandName)
            if typeof(mapped) == "Instance" and mapped:IsA("RemoteEvent")
                and mapped:IsDescendantOf(ReplicatedStorage) then
                eventRemoteCache[commandName] = mapped
                eventRemoteSource = "Network.Fired RemoteEvent map upvalue #" .. tostring(index)
                    .. " (" .. tostring(reader) .. ")"
                return mapped, eventRemoteSource, remoteSessionIndex(mapped), nil
            end
        elseif type(candidate) == "function" then
            local called, first, second, third = pcall(candidate, commandName)
            if called then
                local values = { first, second, third }
                for resultIndex = 1, 3 do
                    local remote = values[resultIndex]
                    if typeof(remote) == "Instance" and remote:IsA("RemoteEvent")
                        and remote:IsDescendantOf(ReplicatedStorage) then
                        eventRemoteCache[commandName] = remote
                        eventRemoteSource = "Network.Fired GetRemoteEvent upvalue #" .. tostring(index)
                            .. " (" .. tostring(reader) .. ")"
                        return remote, eventRemoteSource, remoteSessionIndex(remote), nil
                    end
                end
            else
                lastProblem = "upvalue #" .. tostring(index) .. " probe failed: " .. tostring(first)
            end
        end
    end

    return nil, eventRemoteSource, nil, lastProblem
end

local fireRemoteCache = {}
local fireRemoteSource = "Network.Fire GetRemoteEvent upvalue #2"

local function getFireRemote(commandName)
    local cached = fireRemoteCache[commandName]
    if typeof(cached) == "Instance" and cached:IsA("RemoteEvent")
        and cached:IsDescendantOf(ReplicatedStorage) then
        return cached, fireRemoteSource, remoteSessionIndex(cached), nil
    end
    fireRemoteCache[commandName] = nil

    local network = networkReady()
    if not network or type(network.Fire) ~= "function" then
        return nil, fireRemoteSource, nil, "Library.Network.Fire is unavailable"
    end
    local accessor, reader = functionUpvalueAt(network.Fire, 2)
    if type(accessor) ~= "function" then
        return nil, fireRemoteSource, nil,
            "GetRemoteEvent accessor is unavailable (" .. tostring(reader) .. ")"
    end

    local ok, first, second, third = pcall(accessor, commandName)
    if not ok then
        return nil, fireRemoteSource, nil, "GetRemoteEvent failed: " .. tostring(first)
    end
    for _, remote in ipairs({ first, second, third }) do
        if typeof(remote) == "Instance" and remote:IsA("RemoteEvent")
            and remote:IsDescendantOf(ReplicatedStorage) then
            fireRemoteCache[commandName] = remote
            local sourceName = fireRemoteSource .. " (" .. tostring(reader) .. ")"
            return remote, sourceName, remoteSessionIndex(remote), nil
        end
    end
    return nil, fireRemoteSource, nil,
        tostring(commandName) .. " did not resolve to a live RemoteEvent"
end

local function invokeCommand(commandName, ...)
    local arguments = table.pack(...)
    local remote, sourceName, sessionIndex, resolveProblem = getCommandRemote(commandName)
    if not remote then
        return false, false, resolveProblem, sourceName, sessionIndex
    end

    local result = table.pack(pcall(function()
        return remote:InvokeServer(table.unpack(arguments, 1, arguments.n))
    end))
    if not result[1] then
        commandRemoteCache[commandName] = nil
        return false, false, tostring(result[2]), sourceName, sessionIndex
    end
    return true, result[2] == true, result[3], sourceName, sessionIndex, result[4]
end

local function fireCommand(commandName, ...)
    local arguments = table.pack(...)
    local remote, sourceName, sessionIndex, resolveProblem = getFireRemote(commandName)
    if not remote then return false, resolveProblem, sourceName, sessionIndex end
    local ok, problem = pcall(function()
        remote:FireServer(table.unpack(arguments, 1, arguments.n))
    end)
    if not ok then
        fireRemoteCache[commandName] = nil
        return false, tostring(problem), sourceName, sessionIndex
    end
    return true, nil, sourceName, sessionIndex
end

-- The inventory-operation gate, event pet catalog and route report live in one
-- small lazy module. Keeping them outside the main chunk reduces compile load,
-- while every network action still uses this session's Library.Network readers.
local supportController
local supportLoadProblem
local supportRetryAt = 0
local supportContext = {
    Library = Library,
    Trace = trace,
    GetCommandRemote = getCommandRemote,
    GetFireRemote = getFireRemote,
}

local function ensureSupportModule()
    if supportController then return supportController, nil end
    if os.clock() < supportRetryAt then return nil, supportLoadProblem end

    local controller, problem = loadRemoteController(
        SUPPORT_MODULE_URL,
        "automation support coordinator"
    )
    if not controller then
        supportLoadProblem = tostring(problem or "unknown load error")
        supportRetryAt = os.clock() + 10
        return nil, supportLoadProblem
    end
    supportController = controller
    supportLoadProblem = nil
    supportRetryAt = 0
    return supportController, nil
end

local function acquireOperation(owner)
    local controller, problem = ensureSupportModule()
    if not controller then return false, "coordinator unavailable: " .. tostring(problem) end
    local called, acquired, currentOwner = pcall(controller, "acquire", supportContext, owner)
    if not called then return false, "coordinator error: " .. tostring(acquired) end
    return acquired, currentOwner
end

local function releaseOperation(owner)
    if not supportController then return false end
    local called, released = pcall(supportController, "release", supportContext, owner)
    return called and released == true
end

local function cancelOperation(owner)
    if not supportController then return false end
    local called, cancelled = pcall(supportController, "cancel", supportContext, owner)
    return called and cancelled == true
end

local function operationGateStatus()
    if not supportController then return "idle", 0 end
    local called, owner, waiting = pcall(supportController, "status", supportContext)
    if not called then return "coordinator error", 0 end
    return owner, waiting
end

local function getMachinePetCatalog(force)
    local controller, problem = ensureSupportModule()
    if not controller then return {}, {}, "catalog unavailable: " .. tostring(problem) end
    local called, ids, names, summary = pcall(controller, "catalog", supportContext, force == true)
    if not called then return {}, {}, "catalog error: " .. tostring(ids) end
    return ids, names, summary
end

local function resetSupportCoordinator()
    if supportController then pcall(supportController, "reset", supportContext) end
end

local function runtimeTableScore(candidate)
    if type(candidate) ~= "table" then return 0 end
    local score, checked = 0, 0
    for _, state in pairs(candidate) do
        checked = checked + 1
        if type(state) == "table" and state.uid ~= nil and state.physical ~= nil
            and state.owner ~= nil and state.farming ~= nil then
            score = score + 1
        end
        if checked >= 64 then break end
    end
    return score
end

local function inspectControllerHandler(handler)
    if petRuntime then return end
    local bestTable, bestScore = nil, 0
    for _, value in ipairs(functionUpvalues(handler)) do
        local functions = type(value) == "function" and { value } or {}
        if type(value) == "table" then
            local score = runtimeTableScore(value)
            if score > bestScore then bestTable, bestScore = value, score end
        end
        for _, nested in ipairs(functions) do
            for _, upvalue in ipairs(functionUpvalues(nested)) do
                local score = runtimeTableScore(upvalue)
                if score > bestScore then bestTable, bestScore = upvalue, score end
            end
        end
    end
    if bestScore > 0 then petRuntime = bestTable end
end

local function resolveControllerHandler(signalName)
    local cached = controllerHandlers[signalName]
    if type(cached) == "function" then return cached end
    if os.clock() < (nextControllerLookup[signalName] or 0) then return nil end
    nextControllerLookup[signalName] = os.clock() + 1

    local getter = type(getconnections) == "function" and getconnections
        or type(get_signal_cons) == "function" and get_signal_cons
    local signal = Library and Library.Signal
    if type(getter) ~= "function" or not signal or type(signal.Fired) ~= "function" then return nil end

    local eventOk, event = pcall(signal.Fired, signalName)
    if not eventOk or not event then return nil end
    local listOk, list = pcall(getter, event)
    if not listOk or type(list) ~= "table" then return nil end

    local candidates, preferred = {}, nil
    for _, connection in pairs(list) do
        local functionOk, callback = pcall(function() return connection.Function end)
        if functionOk and type(callback) == "function" then
            table.insert(candidates, callback)
            if debug and type(debug.info) == "function" then
                local sourceOk, source = pcall(debug.info, callback, "s")
                if sourceOk and string.find(string.lower(tostring(source)), "pets", 1, true) then
                    preferred = callback
                end
            end
        end
    end

    local handler = preferred or (#candidates == 1 and candidates[1] or nil)
    if handler then
        controllerHandlers[signalName] = handler
        inspectControllerHandler(handler)
        runtimeDriverReady = petRuntime ~= nil
    end
    return handler
end

local function getRecordModel(record)
    if record and record.Model and record.Model.Parent then return record.Model end
    if not record then return nil end
    local id = tostring(record.Id)
    local indexed = coinIndex.Models[id]
    if indexed and indexed.Parent then
        record.Model = indexed
        record.NextModelLookupAt = nil
        return indexed
    end
    local now = os.clock()
    if now < (record.NextModelLookupAt or 0) then return nil end
    record.NextModelLookupAt = now + 0.75
    local things = workspace:FindFirstChild("__THINGS")
    local folder = things and things:FindFirstChild("Coins")
    if not folder then return nil end
    local direct = folder:FindFirstChild(id)
    if direct then
        record.Model = direct
        coinIndex.Models[id] = direct
        coinIndex.IdByModel[direct] = id
        record.NextModelLookupAt = nil
        return direct
    end
    return nil
end

function petFarm:RuntimeStateForPet(petId)
    if type(petRuntime) ~= "table" then return nil end
    petId = tostring(petId)
    self.RuntimeByUid = self.RuntimeByUid or {}
    local indexed = self.RuntimeByUid[petId]
    if type(indexed) == "table" and indexed.owner == player then return indexed end
    local direct = rawget(petRuntime, petId)
    if type(direct) == "table" and direct.owner == player then
        self.RuntimeByUid[petId] = direct
        return direct
    end
    for key, runtimeState in pairs(petRuntime) do
        if type(runtimeState) == "table" and runtimeState.owner == player
            and tostring(runtimeState.uid or key) == petId then
            self.RuntimeByUid[petId] = runtimeState
            return runtimeState
        end
    end
    return nil
end

function petFarm:BindRuntimePet(petId, record, model)
    local runtimeState = self:RuntimeStateForPet(petId)
    model = model or getRecordModel(record)
    local target = model and model:FindFirstChild("POS")
    if not runtimeState or not target then return false end
    if runtimeState.farming and runtimeState.target == target then return true end

    if type(runtimeState.selectionFunc) == "function" then pcall(runtimeState.selectionFunc) end
    runtimeState.selectionFunc = nil
    runtimeState.farming = true
    runtimeState.target = target
    runtimeState.follower = nil
    runtimeState.arrived = false
    runtimeState.targetuid = (tonumber(runtimeState.targetuid) or 0) + 1
    runtimeState.randomRotation = math.random() * 360
    return true
end

function petFarm:TargetContainsPet(record, petId)
    if not record then return false end
    petId = tostring(petId)
    return (record.Pets and record.Pets[petId] == true)
        or (record.PetsFarming and record.PetsFarming[petId] == true)
end

function petFarm:FireNamed(command, ...)
    local sent = fireCommand(command, ...)
    if sent == true then return true end
    local network = networkReady()
    if not network then return false end
    return pcall(network.Fire, command, ...)
end

function petFarm:MaintainLock(petId, state, record, now, source)
    local health = tonumber(record and record.Health)
    if health and (state.LastHealth == nil or health < state.LastHealth) then
        state.LastProgressAt = now
    end
    state.LastHealth = health or state.LastHealth

    if state.Phase ~= "locked" and now >= (state.DeadlineAt or math.huge) then
        petStates[petId] = nil
        releaseWait[petId] = nil
        idleRecoveryCount = idleRecoveryCount + 1
        lastRecovery = "expired " .. tostring(source or "UID") .. " request on "
            .. string.sub(tostring(petId), 1, 8)
        driverStatus = "expired UID request recovered"
        if type(requestAllocatorPulse) == "function" then requestAllocatorPulse() end
        return false
    end

    local stalled = state.Phase == "locked" and state.FarmSent == true
        and now - (state.LastProgressAt or now) >= 0.75
        and (state.WireRepairs or 0) < 2
    local signalMissing = state.Phase == "locked"
        and (state.TargetSent == false or state.FarmSent == false)
    if (stalled or signalMissing) and now >= (state.NextWireRepair or 0) then
        local targetOk = self:FireNamed(
            "Change Pet Target", petId, "Coin", tostring(record.Id))
        local farmOk = self:FireNamed("Farm Coin", tostring(record.Id), petId)
        state.TargetSent = targetOk == true or state.TargetSent
        state.FarmSent = farmOk == true or state.FarmSent
        state.WireRepairs = (state.WireRepairs or 0) + 1
        state.NextWireRepair = now + 0.75
        driverStatus = "repaired the same locked target signals"
    end
    return true
end

function petFarm:RefreshStats()
    if not self.Engine then return self.StatsCache end
    local ok, stats = pcall(self.Engine, "stats")
    if ok and type(stats) == "table" then self.StatsCache = stats end
    return self.StatsCache
end

function petFarm:EnsureEngine()
    if self.Engine then return true end
    if self.Loading then return false, "engine load already in progress" end
    self.Loading = true
    self.Problem = nil
    driverStatus = "loading high-throughput UID engine"

    local controller, problem = loadRemoteController(
        PET_FARM_ENGINE_URL,
        "pet farm engine",
        function(message) driverStatus = tostring(message) end
    )
    if not controller then
        self.Loading = false
        self.Problem = tostring(problem)
        driverStatus = "pet engine unavailable: " .. self.Problem
        return false, self.Problem
    end

    local context = {
        Running = running,
        Enabled = function() return config.PetFarm end,
        Resetting = function() return farmResetRunning or farmResetRequested end,
        NetworkReady = networkReady,
        GetCommandRemote = getCommandRemote,
        GetFireRemote = getFireRemote,
        RecordAlive = recordAlive,
        StateCurrent = function(petId, state)
            return petStates[tostring(petId)] == state
        end,
        TargetContainsPet = function(record, petId) return self:TargetContainsPet(record, petId) end,
        OnAccepted = function(petId, state, record, model, attempt, route)
            petId = tostring(petId)
            if petStates[petId] ~= state or not recordAlive(record) then return false end
            local now = os.clock()
            state.Phase = "locked"
            state.AcceptedAt = now
            state.ConfirmedAt = now
            state.JoinAttempts = attempt
            state.Route = route
            state.LastHealth = tonumber(record.Health)
            state.LastProgressAt = now
            state.Runtime = self:BindRuntimePet(petId, record, model)
            state.NextRuntimeRepair = now + 0.2
            state.WireRepairs = state.WireRepairs or 0
            state.ArrivalFarmSent = false
            state.DeadlineAt = nil
            record.Pets = record.Pets or {}
            record.Pets[petId] = true
            driverStatus = "UID-direct assignment accepted"
            return true
        end,
        OnSignalsSent = function(petId, state, _, targetSent, farmSent, targetRoute, farmRoute)
            if petStates[tostring(petId)] ~= state then return end
            state.TargetSent = targetSent == true
            state.FarmSent = farmSent == true
            state.TargetRoute = targetRoute
            state.FarmRoute = farmRoute
            state.SignalsAt = os.clock()
            state.NextWireRepair = os.clock() + 0.12
        end,
        OnRetry = function(petId, state, _, reason, nextAttempt)
            if petStates[tostring(petId)] ~= state then return end
            state.Phase = "retry"
            state.JoinAttempts = math.max(tonumber(nextAttempt) - 1, 1)
            state.LastProblem = tostring(reason)
            state.DeadlineAt = os.clock() + 3
            driverStatus = "retrying the same pet target"
        end,
        OnFailed = function(petId, state, record, reason)
            petId = tostring(petId)
            if petStates[petId] ~= state then return end
            petStates[petId] = nil
            releaseWait[petId] = nil
            if record then rejectedUntil[tostring(record.Id)] = os.clock() + 0.18 end
            idleRecoveryCount = idleRecoveryCount + 1
            lastRecovery = "join failed for " .. string.sub(petId, 1, 8)
            driverStatus = "UID join exhausted; selecting a fresh target"
            trace("pet dispatch exhausted", tostring(reason))
            if type(requestAllocatorPulse) == "function" then requestAllocatorPulse() end
        end,
        OnStaleAccepted = function(record, petIds)
            local network = networkReady()
            if not network or not record then return end
            pcall(network.Invoke, "Leave Coin", tostring(record.Id), petIds)
            for _, petId in ipairs(petIds) do
                petId = tostring(petId)
                -- A destroyed coin can finish an old Invoke after this pet has
                -- already received its next lock. Never let stale cleanup
                -- overwrite that newer target with Player.
                if not petStates[petId] then
                    pcall(network.Fire, "Change Pet Target", petId, "Player")
                end
            end
        end,
        Pulse = function()
            if type(requestAllocatorPulse) == "function" then requestAllocatorPulse() end
        end,
        Trace = trace,
        MinLanes = 4,
        InitialLanes = 16,
        MaxLanes = 16,
    }
    local started, accepted, startProblem = pcall(controller, "start", context)
    self.Loading = false
    if not started or accepted ~= true then
        self.Problem = tostring(started and startProblem or accepted)
        driverStatus = "pet engine start failed: " .. self.Problem
        return false, self.Problem
    end

    self.Engine = controller
    local resolvedRoutes = 0
    for _, command in ipairs({ "Join Coin", "Leave Coin" }) do
        local remote = getCommandRemote(command)
        if remote then resolvedRoutes = resolvedRoutes + 1 end
    end
    for _, command in ipairs({ "Change Pet Target", "Farm Coin" }) do
        local remote = getFireRemote(command)
        if remote then resolvedRoutes = resolvedRoutes + 1 end
    end
    self.RouteSummary = "named routes " .. tostring(resolvedRoutes) .. "/4"
    self:RefreshStats()
    driverStatus = "high-throughput UID engine ready"
    if type(requestAllocatorPulse) == "function" then requestAllocatorPulse() end
    return true
end

local function syncRuntimeAssignments(equipped)
    if not runtimeDriverReady or type(petRuntime) ~= "table" then return false, nil end

    local now = os.clock()
    local observed, runtimeSeen = {}, {}
    petFarm.RuntimeByUid = petFarm.RuntimeByUid or {}
    table.clear(petFarm.RuntimeByUid)
    for key, runtimeState in pairs(petRuntime) do
        if type(runtimeState) == "table" and runtimeState.owner == player then
            local petId = tostring(runtimeState.uid or key)
            if equipped[petId] then
                petFarm.RuntimeByUid[petId] = runtimeState
                runtimeSeen[petId] = runtimeState
                local target = runtimeState.target
                local coinModel = runtimeState.farming and target and target.Parent or nil
                if coinModel and coinModel.Parent then
                    local coinId = readObjectValue(coinModel, "ID") or coinModel.Name
                    local record = coinId ~= nil and coinRecords[tostring(coinId)] or nil
                    if coinId ~= nil and recordAlive(record) then
                        observed[petId] = tostring(coinId)
                    end
                end
            end
        end
    end

    -- Adopt a pre-existing game assignment only when this allocator has no
    -- intent for the pet. A stale/conflicting runtime target never overwrites a
    -- live UID lock created by this script.
    for petId, coinId in pairs(observed) do
        if not petStates[petId] then
            petStates[petId] = {
                CoinId = coinId,
                Phase = "locked",
                Runtime = true,
                ConfirmedAt = now,
                AcceptedAt = now,
                External = true,
            }
        end
    end

    for petId, state in pairs(petStates) do
        local record = coinRecords[tostring(state.CoinId)]
        if not equipped[petId] then
            petStates[petId] = nil
            releaseWait[petId] = nil
        elseif not recordAlive(record) then
            queuePetRelease(petId, now)
        else
            local runtimeState = runtimeSeen[petId]
            local intendedModel = getRecordModel(record)
            local intendedTarget = intendedModel and intendedModel:FindFirstChild("POS")
            local runtimeMatches = runtimeState and runtimeState.farming
                and intendedTarget and runtimeState.target == intendedTarget

            if runtimeMatches then
                state.Runtime = true
                state.RuntimeSeenAt = now
                state.RuntimeMismatchSince = nil
                if runtimeState.arrived == true and not state.ArrivalFarmSent then
                    state.ArrivalFarmSent = true
                    state.FarmSent = petFarm:FireNamed(
                        "Farm Coin", tostring(record.Id), petId) or state.FarmSent
                    driverStatus = "arrival-confirmed farm signal sent"
                end
            elseif state.Phase == "locked" then
                state.Runtime = false
                state.RuntimeMismatchSince = state.RuntimeMismatchSince or now
                if now >= (state.NextRuntimeRepair or 0) then
                    state.Runtime = petFarm:BindRuntimePet(petId, record, intendedModel)
                    state.NextRuntimeRepair = now + 0.2
                end
            end

            petFarm:MaintainLock(petId, state, record, now, "runtime")
        end
    end

    for petId, releaseState in pairs(releaseWait) do
        if not equipped[petId] then
            releaseWait[petId] = nil
        elseif now >= (releaseState.ReadyAt or now) then
            releaseWait[petId] = nil
        end
    end
    return true, runtimeSeen
end

local function currentFarmSignature()
    return table.concat({
        tostring(config.Mode),
        tostring(getSelectedWorld() or ""),
        tostring(getSelectedZone() or ""),
    }, "|")
end

local function addAssignedPet(groups, allPets, coinId, petId)
    if petId == nil then return end
    petId = tostring(petId)
    allPets[petId] = true
    if coinId == nil then return end
    coinId = tostring(coinId)
    local pets = groups[coinId]
    if not pets then pets = {}; groups[coinId] = pets end
    pets[petId] = true
end

local function collectAssignmentsForReset()
    resolveControllerHandler("Select Coin")

    local groups, allPets = {}, {}
    local equipped = {}
    for _, petId in ipairs(getEquippedPetIds()) do
        equipped[tostring(petId)] = true
        allPets[tostring(petId)] = true
    end

    for petId, state in pairs(petStates) do
        addAssignedPet(groups, allPets, state.CoinId, petId)
    end

    for _, record in pairs(coinRecords) do
        if recordAlive(record) then
            for _, petSet in ipairs({ record.Pets or {}, record.PetsFarming or {} }) do
                for petId in pairs(petSet) do
                    petId = tostring(petId)
                    if equipped[petId] then addAssignedPet(groups, allPets, record.Id, petId) end
                end
            end
        end
    end

    if type(petRuntime) == "table" then
        for key, runtimeState in pairs(petRuntime) do
            if type(runtimeState) == "table" and runtimeState.owner == player then
                local petId = tostring(runtimeState.uid or key)
                local target = runtimeState.target
                local coinModel = runtimeState.farming and target and target.Parent or nil
                local coinId = coinModel and (readObjectValue(coinModel, "ID") or coinModel.Name) or nil
                if runtimeState.farming then addAssignedPet(groups, allPets, coinId, petId) end

                if runtimeState.selectionFunc then pcall(runtimeState.selectionFunc) end
                runtimeState.selectionFunc = nil
                runtimeState.farming = false
                runtimeState.target = nil
                runtimeState.follower = nil
                runtimeState.arrived = false
                if type(runtimeState.targetuid) == "number" then
                    runtimeState.targetuid = runtimeState.targetuid + 1
                end
            end
        end
    end

    return groups, allPets
end

local function clearAssignments(sendBack)
    if petFarm.Engine then pcall(petFarm.Engine, "reset") end
    local groups, allPets = collectAssignmentsForReset()
    local network = sendBack and networkReady() or nil
    if network then
        local ok, snapshot = pcall(network.Invoke, "Get Coins")
        if ok and type(snapshot) == "table" then
            for coinId, data in pairs(snapshot) do
                if type(data) == "table" then
                    local serverSets = {
                        normalizePetSet(data.pets or data.Pets),
                        normalizePetSet(data.petsFarming or data.PetsFarming),
                    }
                    for _, petSet in ipairs(serverSets) do
                        for petId in pairs(petSet) do
                            petId = tostring(petId)
                            if allPets[petId] then addAssignedPet(groups, allPets, coinId, petId) end
                        end
                    end
                end
            end
        end
    end

    table.clear(petStates)
    table.clear(rejectedUntil)
    table.clear(releaseWait)
    for _, record in pairs(coinRecords) do
        for petId in pairs(allPets) do
            if record.Pets then record.Pets[petId] = nil end
            if record.PetsFarming then record.PetsFarming[petId] = nil end
        end
    end

    if not sendBack then return true end
    if not network then return false end

    for coinId, petSet in pairs(groups) do
        local petIds = {}
        for petId in pairs(petSet) do table.insert(petIds, petId) end
        table.sort(petIds)
        if #petIds > 0 then pcall(network.Invoke, "Leave Coin", coinId, petIds) end
    end
    for petId in pairs(allPets) do
        pcall(network.Fire, "Change Pet Target", petId, "Player")
    end
    return true
end

requestFarmReset = function(reason)
    farmResetReason = tostring(reason or "configuration changed")
    farmSelectionSignature = currentFarmSignature()
    farmResetRequested = true
    if farmResetRunning or not running() then return end

    farmResetRunning = true
    task.spawn(function()
        while running() and allocatorBusy do RunService.Heartbeat:Wait() end
        if not running() then farmResetRunning = false; return end

        repeat
            farmResetRequested = false
            driverStatus = "resetting: " .. farmResetReason
            local networkCleaned = clearAssignments(true)
            nextSnapshotAt = 0
            if config.PetFarm and not networkCleaned then
                driverStatus = "waiting for Network before reset"
                while running() and config.PetFarm and not farmResetRequested and not networkReady() do
                    RunService.Heartbeat:Wait()
                end
                if running() and config.PetFarm and networkReady() then farmResetRequested = true end
            end
            RunService.Heartbeat:Wait()
        until not running() or not farmResetRequested

        farmResetRunning = false
        if not running() then return end
        if farmResetRequested then
            requestFarmReset(farmResetReason)
            return
        end

        farmSelectionSignature = currentFarmSignature()
        driverStatus = config.PetFarm and "reset complete" or "farm disabled"
        if config.PetFarm and type(requestAllocatorPulse) == "function" then
            requestAllocatorPulse()
        end
    end)
end

local function dispatchPlan(record, petIds)
    if not recordAlive(record) or #petIds == 0 then return end
    if not petFarm.Engine then
        driverStatus = petFarm.Loading and "high-throughput engine is loading"
            or "high-throughput engine is unavailable"
        return
    end
    local model = getRecordModel(record)
    if model and not model:FindFirstChild("POS") then model = nil end

    local coinId = tostring(record.Id)
    local entries = {}
    local startedAt = os.clock()
    for _, petId in ipairs(petIds) do
        petId = tostring(petId)
        local state = {
            CoinId = coinId,
            Phase = "pending",
            StartedAt = startedAt,
            StartedHealth = tonumber(record.Health),
            LastHealth = tonumber(record.Health),
            LastProgressAt = startedAt,
            JoinAttempts = 1,
            DeadlineAt = startedAt + 3,
        }
        state.Runtime = petFarm:BindRuntimePet(petId, record, model)
        state.NextRuntimeRepair = startedAt + 0.2
        petStates[petId] = state
        entries[#entries + 1] = { PetId = petId, State = state }
    end

    local called, accepted, problem = pcall(petFarm.Engine, "dispatch", {
        Record = record,
        Model = model,
        CoinId = coinId,
        Entries = entries,
    })
    if not called or accepted ~= true then
        for _, entry in ipairs(entries) do
            if petStates[entry.PetId] == entry.State then petStates[entry.PetId] = nil end
        end
        rejectedUntil[coinId] = os.clock() + 0.12
        driverStatus = "UID dispatch queue error: " .. tostring(called and problem or accepted)
        if type(requestAllocatorPulse) == "function" then requestAllocatorPulse() end
    end
end

local function syncServerAssignments(equipped)
    local now = os.clock()
    local observed = {}
    for _, record in pairs(coinRecords) do
        if recordAlive(record) then
            for _, petSet in ipairs({ record.Pets or {}, record.PetsFarming or {} }) do
                for petId in pairs(petSet) do
                    petId = tostring(petId)
                    if equipped[petId] then
                        local choices = observed[petId]
                        if not choices then choices = {}; observed[petId] = choices end
                        choices[tostring(record.Id)] = record
                    end
                end
            end
        end
    end

    for petId, choices in pairs(observed) do
        local state = petStates[petId]
        if state and choices[tostring(state.CoinId)] then
            state.ConfirmedAt = now
            state.MembershipSeenAt = now
        elseif not state then
            local coinId
            local bestRevision = -1
            for candidateId, record in pairs(choices) do
                local revision = tonumber(record.EventRevision) or 0
                if revision > bestRevision
                    or revision == bestRevision and (coinId == nil or candidateId < coinId) then
                    coinId = candidateId
                    bestRevision = revision
                end
            end
            if coinId then
                petStates[petId] = {
                    CoinId = coinId,
                    Phase = "locked",
                    ConfirmedAt = now,
                    AcceptedAt = now,
                    External = true,
                }
            end
        end
    end

    for petId, state in pairs(petStates) do
        local record = coinRecords[tostring(state.CoinId)]
        if not equipped[petId] then
            petStates[petId] = nil
            releaseWait[petId] = nil
        elseif not recordAlive(record) then
            queuePetRelease(petId, now)
        else
            petFarm:MaintainLock(petId, state, record, now, "server")
        end
    end

    for petId, releaseState in pairs(releaseWait) do
        if not equipped[petId] or now >= (releaseState.ReadyAt or now) then
            releaseWait[petId] = nil
        end
    end
end

local function assignmentCount()
    local count = 0
    for _ in pairs(petStates) do count = count + 1 end
    return count
end

function petFarm:PhaseCounts()
    local locked, pending = 0, 0
    for _, state in pairs(petStates) do
        if state.Phase == "locked" then locked = locked + 1 else pending = pending + 1 end
    end
    return locked, pending
end

local function runtimePetCounts(petIds)
    if not runtimeDriverReady or type(petRuntime) ~= "table" then return nil end
    local equipped = {}
    for _, petId in ipairs(petIds) do equipped[tostring(petId)] = true end

    local seen, active = 0, 0
    for key, runtimeState in pairs(petRuntime) do
        if type(runtimeState) == "table" and runtimeState.owner == player then
            local petId = tostring(runtimeState.uid or key)
            if equipped[petId] then
                seen = seen + 1
                if runtimeState.farming then active = active + 1 end
            end
        end
    end
    return active, math.max(seen - active, 0), math.max(#petIds - seen, 0)
end

local statusViews = {}
local statusSetters = {}
statusSetters.Cache = {}
function statusSetters.Set(key, text)
    local view = statusViews[key]
    if not view then return end
    text = tostring(text)
    if statusSetters.Cache[key] == text then return end
    statusSetters.Cache[key] = text
    pcall(function() view:SetDesc(text) end)
end
function statusSetters.Farm(text)
    statusSetters.Set("Farm", text)
end
function statusSetters.Health(text)
    statusSetters.Set("Health", text)
end
function statusSetters.Rate(text)
    statusSetters.Set("Rate", text)
end
function statusSetters.Diamond(text)
    statusSetters.Set("Diamond", text)
end
function statusSetters.Gold(text)
    statusSetters.Set("Gold", text)
end
function statusSetters.Rainbow(text)
    statusSetters.Set("Rainbow", text)
end
function statusSetters.DarkMatter(text)
    statusSetters.Set("DarkMatter", text)
end
function statusSetters.Egg(text)
    statusSetters.Set("Egg", text)
end
function statusSetters.EggCatalog(text)
    statusSetters.Set("EggCatalog", text)
end
function statusSetters.Boost(text)
    statusSetters.Set("Boost", text)
end
function statusSetters.Routes(text)
    statusSetters.Set("Routes", text)
end
local function getRewardSave()
    if not Library.Save or type(Library.Save.Get) ~= "function" then return nil end
    local save
    pcall(function() save = Library.Save.Get() end)
    return type(save) == "table" and save or nil
end

local rewardClockRetryAt = 0
local rewardClockProblem

local function getRewardServerTime()
    if rewardServerTime ~= nil and rewardClockStarted ~= nil then
        return rewardServerTime + (os.clock() - rewardClockStarted), nil
    end
    if os.clock() < rewardClockRetryAt then
        return nil, rewardClockProblem or "server clock retry pending"
    end

    local remote, _, _, resolveProblem = getCommandRemote("Get OSTime")
    if not remote then
        rewardClockRetryAt = os.clock() + 10
        rewardClockProblem = resolveProblem
        return nil, resolveProblem
    end

    local ok, rawValue = pcall(function() return remote:InvokeServer() end)
    local value = ok and tonumber(rawValue) or nil
    if value == nil then
        commandRemoteCache["Get OSTime"] = nil
        rewardClockRetryAt = os.clock() + 10
        rewardClockProblem = ok and "Get OSTime returned a non-number"
            or ("Get OSTime transport error: " .. tostring(rawValue))
        return nil, rewardClockProblem
    end

    rewardServerTime = value
    rewardClockStarted = os.clock()
    rewardClockProblem = nil
    return value, nil
end

local function getRewardTiming(kind)
    local save = getRewardSave()
    if not save then return nil, nil, "player save is unavailable" end

    local serverTime, clockProblem = getRewardServerTime()
    if serverTime == nil then
        return nil, nil, clockProblem or "server clock is unavailable"
    end

    if kind == "VIP" then
        local lastClaim = tonumber(save.VIPCooldown)
        if lastClaim == nil then
            return nil, VIP_REWARD_COOLDOWN, "VIPCooldown is unavailable; no claim sent"
        end
        return math.max(0, VIP_REWARD_COOLDOWN - (serverTime - lastClaim)),
            VIP_REWARD_COOLDOWN, nil
    end

    local rankTimer = tonumber(save.RankTimer)
    local ranks = Library.Directory and Library.Directory.Ranks
    local rankData = type(ranks) == "table" and ranks[save.Rank] or nil
    if type(rankData) ~= "table" then
        return nil, nil, "current rank data is unavailable; no claim sent"
    end
    if type(rankData.rewards) == "table" and #rankData.rewards == 0 then
        return nil, nil, "current rank has no rewards"
    end

    local cooldown = tonumber(rankData.rewardCooldown)
    if rankTimer == nil or cooldown == nil then
        return nil, cooldown, "rank timer is unavailable; no claim sent"
    end
    return math.max(0, cooldown - (serverTime - rankTimer)), cooldown, nil
end

local function routeText(sourceName, sessionIndex)
    return tostring(sourceName or commandRemoteSource)
        .. " [session index " .. tostring(sessionIndex or "?") .. "]"
end

local function formatDuration(seconds)
    seconds = math.max(0, math.floor(tonumber(seconds) or 0))
    local hours = math.floor(seconds / 3600)
    local minutes = math.floor(seconds % 3600 / 60)
    local secs = seconds % 60
    if hours > 0 then return string.format("%dh %02dm %02ds", hours, minutes, secs) end
    return string.format("%dm %02ds", minutes, secs)
end

local AUTO_EGG_MODULE_URL = RAW_MODULE_BASE .. "auto_egg_module.lua"
local autoEggController
local autoEggLoading = false
local autoEggLoadProblem
local autoEggToggleControl
local refreshEggDropdown

local function stopAutoEggModule(statusText)
    if autoEggController then pcall(autoEggController, "stop") end
    if statusText then statusSetters.Egg(statusText) end
end

local function disableAutoEgg(reason)
    config.AutoEgg = false
    statusSetters.Egg(tostring(reason or "Auto hatch stopped by its safety controller"))
    task.defer(function()
        if running() and autoEggToggleControl and type(autoEggToggleControl.Set) == "function" then
            pcall(function() autoEggToggleControl:Set(false) end)
        end
    end)
end

local function ensureAutoEggModule()
    if autoEggController then return true end
    if autoEggLoading then
        local deadline = os.clock() + 12
        while autoEggLoading and running() and os.clock() < deadline do task.wait(0.05) end
        if autoEggController then return true end
        return false, autoEggLoadProblem or "auto egg module load timed out"
    end
    autoEggLoading = true
    autoEggLoadProblem = nil
    local controller, problem = loadRemoteController(
        AUTO_EGG_MODULE_URL,
        "auto egg module",
        statusSetters.Egg
    )
    autoEggLoading = false
    if not controller then
        autoEggLoadProblem = tostring(problem)
        return false, autoEggLoadProblem
    end
    autoEggController = controller
    return true
end

local function inspectEggThroughModule(eggId, count, animation)
    if not autoEggController then return false, "Auto egg module is not loaded" end
    return autoEggController("inspect", {
        Library = Library,
        Player = player,
        Egg = eggId,
        Count = count,
        Animation = animation,
        GetCurrency = getCurrentCurrency,
        FormatNumber = formatRateNumber,
    })
end

local function startAutoEggModule()
    if not config.AutoEgg or not running() then return end
    local loaded, loadProblem = ensureAutoEggModule()
    if not loaded then
        disableAutoEgg("Auto egg module could not be loaded; no purchase was sent: " .. tostring(loadProblem))
        return
    end
    if not config.AutoEgg or not running() then return end
    if refreshEggDropdown then refreshEggDropdown(true) end
    local context = {
        Library = Library,
        Player = player,
        Running = running,
        Enabled = function() return config.AutoEgg end,
        GetOptions = function()
            return {
                Egg = config.EggName,
                Count = config.EggCount,
                Animation = config.EggAnimation,
            }
        end,
        InspectEgg = inspectEggThroughModule,
        InvokeCommand = invokeCommand,
        GetEventRemote = getEventRemote,
        RouteText = routeText,
        AcquireOperation = acquireOperation,
        ReleaseOperation = releaseOperation,
        CancelOperation = cancelOperation,
        OperationOwner = "AutoEgg",
        SetStatus = statusSetters.Egg,
        Trace = trace,
        Disable = disableAutoEgg,
    }
    local called, accepted, problem = pcall(autoEggController, "start", context)
    if not called or accepted == false then
        local reason = not called and accepted or problem
        disableAutoEgg("Auto egg worker failed to start; no purchase was sent: " .. tostring(reason))
    end
end

local machineModules = {
    Gold = {
        URL = RAW_MODULE_BASE .. "gold_machine_module.lua",
        ConfigKeys = { "AutoGoldenGalaxyFox" },
        Label = "gold machine",
        SetStatus = statusSetters.Gold,
    },
    Rainbow = {
        URL = RAW_MODULE_BASE .. "rainbow_machine_module.lua",
        ConfigKeys = { "AutoRainbowGalaxyFox" },
        Label = "rainbow machine",
        SetStatus = statusSetters.Rainbow,
    },
    DarkMatter = {
        URL = RAW_MODULE_BASE .. "dark_matter_module.lua",
        ConfigKeys = { "AutoDarkMatterGalaxyFox", "AutoClaimDarkMatter" },
        Label = "dark matter machine",
        SetStatus = statusSetters.DarkMatter,
    },
}

function machineModules:Enabled(entry)
    for _, key in ipairs(entry and entry.ConfigKeys or {}) do
        if config[key] then return true end
    end
    return false
end

function machineModules:Disable(entry)
    for _, key in ipairs(entry and entry.ConfigKeys or {}) do config[key] = false end
end

function machineModules:Stop(kind)
    local entry = self[kind]
    if entry and entry.Controller then pcall(entry.Controller, "stop") end
end

function machineModules:StopAll()
    self:Stop("Gold")
    self:Stop("Rainbow")
    self:Stop("DarkMatter")
end

function machineModules:Start(kind)
    local entry = self[kind]
    if not entry or entry.Loading or not self:Enabled(entry) or not running() then return end
    entry.Loading = true

    if not entry.Controller then
        local controller, problem = loadRemoteController(entry.URL, entry.Label .. " module", entry.SetStatus)
        if not controller then
            entry.Loading = false
            self:Disable(entry)
            entry.SetStatus("Module could not be loaded; no pets were sent: " .. tostring(problem))
            return
        end
        entry.Controller = controller
    end

    entry.Loading = false
    if not self:Enabled(entry) or not running() then return end
    local context = {
        Library = Library,
        Running = running,
        Enabled = function() return machineModules:Enabled(entry) end,
        CreateEnabled = function() return config.AutoDarkMatterGalaxyFox end,
        ClaimEnabled = function() return config.AutoClaimDarkMatter end,
        GetSave = getRewardSave,
        GetCurrency = getCurrentCurrency,
        FormatNumber = formatRateNumber,
        GetMachinePetCatalog = getMachinePetCatalog,
        BatchSize = function()
            return kind == "DarkMatter" and config.DarkMatterBatchSize or config.MachineBatchSize
        end,
        MaxWaitSeconds = function()
            if kind ~= "DarkMatter" then return nil end
            local hours = tonumber(config.DarkMatterMaxWaitHours) or 0
            return hours > 0 and hours * 3600 or nil
        end,
        GetCommandRemote = getCommandRemote,
        InvalidateCommand = function(commandName) commandRemoteCache[commandName] = nil end,
        InvokeCommand = invokeCommand,
        RouteText = routeText,
        AcquireOperation = acquireOperation,
        ReleaseOperation = releaseOperation,
        CancelOperation = cancelOperation,
        OperationOwner = kind .. "Machine",
        SetStatus = entry.SetStatus,
        Trace = trace,
    }
    local called, accepted, problem = pcall(entry.Controller, "start", context)
    if not called or accepted == false then
        self:Disable(entry)
        local reason = not called and accepted or problem
        entry.SetStatus("Module failed to start; no pets were sent: " .. tostring(reason))
        trace(entry.Label .. " module", "start failed: " .. tostring(reason))
    end
end

local BOOST_MODULE_URL = RAW_MODULE_BASE .. "boost_module.lua"
local boostController
local boostLoading = false
local boostLoadProblem

local function boostAutomationEnabled()
    return config.AutoBoostBundle or config.AutoTripleCoins or config.AutoTripleDamage
        or config.AutoSuperLucky or config.AutoUltraLucky
end

local function stopBoostModule(statusText)
    if boostController then pcall(boostController, "stop") end
    if statusText then statusSetters.Boost(statusText) end
end

local function startBoostModule()
    if boostLoading or not boostAutomationEnabled() or not running() then return end
    boostLoading = true
    if not boostController then
        local controller, problem = loadRemoteController(
            BOOST_MODULE_URL,
            "auto boost module",
            statusSetters.Boost
        )
        if not controller then
            boostLoadProblem = tostring(problem)
            boostLoading = false
            statusSetters.Boost("Boost module could not be loaded; no request was sent: " .. boostLoadProblem)
            return
        end
        boostController = controller
    end
    boostLoading = false
    if not boostAutomationEnabled() or not running() then return end

    local context = {
        Library = Library,
        Running = running,
        Enabled = boostAutomationEnabled,
        GetOptions = function()
            return {
                AutoBoostBundle = config.AutoBoostBundle,
                AutoTripleCoins = config.AutoTripleCoins,
                AutoTripleDamage = config.AutoTripleDamage,
                AutoSuperLucky = config.AutoSuperLucky,
                AutoUltraLucky = config.AutoUltraLucky,
                RenewBefore = config.BoostRenewBefore,
            }
        end,
        GetSave = getRewardSave,
        GetCurrency = getCurrentCurrency,
        FormatNumber = formatRateNumber,
        GetCommandRemote = getCommandRemote,
        GetFireRemote = getFireRemote,
        InvokeCommand = invokeCommand,
        FireCommand = fireCommand,
        RouteText = routeText,
        AcquireOperation = acquireOperation,
        ReleaseOperation = releaseOperation,
        CancelOperation = cancelOperation,
        OperationStatus = operationGateStatus,
        OperationOwner = "Boosts",
        SetStatus = statusSetters.Boost,
        Trace = trace,
    }
    local called, accepted, problem = pcall(boostController, "start", context)
    if not called or accepted == false then
        local reason = not called and accepted or problem
        statusSetters.Boost("Boost worker failed to start; no request was sent: " .. tostring(reason))
        trace("auto boost module", "start failed: " .. tostring(reason))
    end
end

local function reconcileBoostModule()
    if boostAutomationEnabled() then
        task.spawn(startBoostModule)
    else
        stopBoostModule("Disabled. Boost timers and inventory remain untouched.")
    end
end

local routeHealthBusy = false

local function refreshRouteHealth()
    if routeHealthBusy then return end
    routeHealthBusy = true

    statusSetters.Routes("Loading the small diagnostics coordinator in the serial module lane...")
    local controller, loadProblem = ensureSupportModule()
    local checked, result = false, loadProblem
    if controller then
        checked, result = pcall(controller, "route-health", supportContext)
    end
    if checked and type(result) == "string" then
        statusSetters.Routes(result)
    else
        statusSetters.Routes("Local route preflight recovered from an error: " .. tostring(result)
            .. "\nNo server request was sent. Press Refresh to retry.")
        trace("route preflight", tostring(result))
    end
    routeHealthBusy = false
end

local function invokeReward(kind)
    local state = rewardStates[kind]
    local transportOk, accepted, serverMessage, sourceName, sessionIndex =
        invokeCommand(state.Command)
    local reply
    local succeeded = false

    if not transportOk then
        reply = "Route/transport error; no claim confirmed: " .. tostring(serverMessage)
    elseif accepted then
        succeeded = true
        reply = "Claimed via " .. routeText(sourceName, sessionIndex)
    else
        local reason = serverMessage ~= nil and tostring(serverMessage)
            or "request rejected (cooldown/not eligible)"
        reply = "Server reached via " .. routeText(sourceName, sessionIndex) .. ": " .. reason
    end

    trace(string.lower(state.Label) .. " reward", reply)
    return succeeded
end

local function runDiamondPackCheck()
    if diamondPackBusy then return end
    diamondPackBusy = true

    local balance = getCurrentCurrency("Tech Coins")
    local balanceText = balance ~= nil and formatRateNumber(balance) or "unknown"
    local status

    if balance == nil then
        status = "Local check: Tech Coins balance was not found; no request sent."
    elseif balance < DIAMOND_PACK_MINIMUM then
        status = "Local threshold hold: " .. balanceText
            .. " is below 1T Tech Coins; no server request sent."
    else
        local transportOk, accepted, serverMessage, sourceName, sessionIndex =
            invokeCommand("Buy DiamondPack", DIAMOND_PACK_TIER)
        if not transportOk then
            status = "Route/transport error; purchase not confirmed: " .. tostring(serverMessage)
        elseif accepted then
            status = "Tier 4 purchase succeeded via " .. routeText(sourceName, sessionIndex)
                .. " | balance before: " .. balanceText
        else
            local reason = serverMessage ~= nil and tostring(serverMessage)
                or "request rejected"
            status = "Server reached via " .. routeText(sourceName, sessionIndex) .. ": "
                .. reason .. " | balance: " .. balanceText .. " | configured floor: 1T"
        end
    end

    diamondPackNextCheck = os.clock() + DIAMOND_PACK_INTERVAL
    diamondPackBusy = false
    trace("diamond pack", status)
    statusSetters.Diamond(status .. "\nNext local check in 3 minutes.")
end

local allocatorPass

function petFarm:ScheduleAllocatorPass()
    if self.AllocatorScheduled or allocatorBusy or not running() then return end
    self.AllocatorScheduled = true
    task.spawn(function()
        -- Collapse every New/Remove/Update Coin and worker callback produced in
        -- one render frame into one allocator pass on the following frame.
        RunService.Heartbeat:Wait()
        self.AllocatorScheduled = false
        if running() then allocatorPass() end
    end)
end

allocatorPass = function()
    if allocatorBusy then
        allocatorRequested = true
        return
    end
    allocatorBusy = true
    allocatorRequested = false
    local ok, problem = pcall(function()
        if os.clock() >= nextSnapshotAt and not snapshotBusy then task.spawn(refreshCoinSnapshot) end
        connectCoinSignals()

        if not config.PetFarm or farmResetRunning or farmResetRequested then return end

        if not petFarm.Engine then
            if not petFarm.Loading then
                task.spawn(function()
                    local ready, engineProblem = petFarm:EnsureEngine()
                    if not ready then trace("pet engine load", tostring(engineProblem)) end
                end)
            end
            driverStatus = petFarm.Loading and "loading high-throughput UID engine"
                or "waiting for high-throughput UID engine"
            return
        end

        local signature = currentFarmSignature()
        if farmSelectionSignature ~= signature then
            requestFarmReset("selection changed")
            return
        end

        local petIds = getEquippedPetIds()
        local equipped = {}
        for _, petId in ipairs(petIds) do equipped[petId] = true end
        if #petIds == 0 then return end

        if not runtimeDriverReady then resolveControllerHandler("Select Coin") end
        local usingRuntime = syncRuntimeAssignments(equipped)
        if not usingRuntime then syncServerAssignments(equipped) end

        local freePets = {}
        for _, petId in ipairs(petIds) do
            if not petStates[petId] and not releaseWait[petId] then
                table.insert(freePets, petId)
            end
        end
        if #freePets == 0 then
            pcall(petFarm.Engine, "pump")
            return
        end

        local targets = orderedTargets(config.Mode)
        local targetIds = {}
        for _, record in ipairs(targets) do targetIds[tostring(record.Id)] = true end
        for _, state in pairs(petStates) do
            local coinId = tostring(state.CoinId)
            if recordAlive(coinRecords[coinId]) and not targetIds[coinId] then
                requestFarmReset("active target left selected zone")
                return
            end
        end

        local usable = {}
        for _, record in ipairs(targets) do
            if os.clock() >= (rejectedUntil[tostring(record.Id)] or 0) then
                table.insert(usable, record)
            end
        end
        if #usable == 0 then return end

        local plans, plansById = {}, {}
        if config.Mode == "All on Strongest Regular" or config.Mode == "Boss Chest Only" then
            local groupTarget
            for _, state in pairs(petStates) do
                local coinId = tostring(state.CoinId)
                local record = coinRecords[coinId]
                local matchesMode = config.Mode == "Boss Chest Only" and isBossChest(record)
                    or config.Mode == "All on Strongest Regular" and not isBossChest(record)
                if matchesMode and recordAlive(record) and targetIds[coinId] then
                    groupTarget = record
                    break
                end
            end
            groupTarget = groupTarget or usable[1]
            plans[1] = { Record = groupTarget, Pets = freePets }
        else
            local claimed = {}
            for _, state in pairs(petStates) do
                local coinId = tostring(state.CoinId)
                if targetIds[coinId] and recordAlive(coinRecords[coinId]) then claimed[coinId] = true end
            end
            local unique = {}
            for _, record in ipairs(usable) do
                if not claimed[tostring(record.Id)] then table.insert(unique, record) end
            end
            local uniqueIndex, sharedIndex = 1, 1
            for _, petId in ipairs(freePets) do
                local record = unique[uniqueIndex]
                uniqueIndex = uniqueIndex + 1
                if not record then
                    record = usable[((sharedIndex - 1) % #usable) + 1]
                    sharedIndex = sharedIndex + 1
                end
                local recordId = tostring(record.Id)
                local plan = plansById[recordId]
                if not plan then
                    plan = { Record = record, Pets = {} }
                    plansById[recordId] = plan
                    plans[#plans + 1] = plan
                end
                table.insert(plan.Pets, petId)
                claimed[recordId] = true
            end
        end
        for _, plan in ipairs(plans) do dispatchPlan(plan.Record, plan.Pets) end
    end)
    if not ok then driverStatus = "allocator error: " .. tostring(problem) end

    allocatorBusy = false
    if allocatorRequested then petFarm:ScheduleAllocatorPass() end
end

requestAllocatorPulse = function()
    allocatorRequested = true
    petFarm:ScheduleAllocatorPass()
end

task.spawn(function()
    local petLifecycleSignals = {}
    local function connectPetLifecycleSignal(name, removed)
        if petLifecycleSignals[name] then return true end
        local signal = Library and Library.Signal
        if not signal or type(signal.Fired) ~= "function" then return false end

        local eventOk, event = pcall(signal.Fired, name)
        if not eventOk or not event or type(event.Connect) ~= "function" then return false end
        local connected, connection = pcall(function()
            return event:Connect(function(rawPetId)
                local petId = rawPetId ~= nil and tostring(rawPetId) or nil
                nextPetScanAt = 0
                if removed and petId then
                    petStates[petId] = nil
                    releaseWait[petId] = nil
                end
                if config.PetFarm then
                    driverStatus = removed and "pet unequipped; assignments reconciled"
                        or "equipped pet detected; assigning target"
                    requestAllocatorPulse()
                end
            end)
        end)
        if not connected or not connection then return false end
        petLifecycleSignals[name] = connection
        track(connection)
        return true
    end

    while running() do
        local added = connectPetLifecycleSignal("Added Client Pet", false)
        local removed = connectPetLifecycleSignal("Removed Client Pet", true)
        if added and removed then break end
        task.wait(0.5)
    end
end)

task.spawn(function()
    while running() do
        requestAllocatorPulse()
        task.wait(config.PetFarm and 0.08 or 0.4)
    end
end)

task.spawn(function()
    while task.wait(0.15) do
        if not running() then break end
        if not config.Orbs and not config.Lootbags then continue end
        local character = player.Character
        local root = character and character:FindFirstChild("HumanoidRootPart")
        local things = workspace:FindFirstChild("__THINGS")
        if root and things then
            local function collect(folderName, limit)
                local folder = things:FindFirstChild(folderName)
                if not folder then return end
                local items = folder:GetChildren()
                for index = 1, math.min(#items, limit) do
                    local item = items[index]
                    pcall(function()
                        local part = item:IsA("BasePart") and item or item:FindFirstChildWhichIsA("BasePart", true)
                        if part then
                            part.CanCollide = false
                            part.CFrame = root.CFrame * CFrame.new(0, -3, 0)
                            if type(firetouchinterest) == "function" then
                                firetouchinterest(root, part, 0)
                                firetouchinterest(root, part, 1)
                            end
                        end
                    end)
                end
            end
            if config.Orbs then collect("Orbs", 40) end
            if config.Lootbags then collect("Lootbags", 20) end
        end
    end
end)

track(player.Idled:Connect(function()
    if config.AntiAFK and running() then
        local activeCamera = workspace.CurrentCamera or camera
        if not activeCamera then return end
        pcall(function() VirtualUser:Button2Down(Vector2.new(0, 0), activeCamera.CFrame) end)
        task.wait(0.25)
        pcall(function() VirtualUser:Button2Up(Vector2.new(0, 0), activeCamera.CFrame) end)
    end
end))

local function startInterfaceAndWorkers()
local function uiStageYield(stage)
    if not running() then return end
    if stage then trace("UI stage", stage) end
    RunService.Heartbeat:Wait()
end

WindUI:AddTheme({
    Name = "Nova Stable",
    Accent = Color3.fromRGB(56, 189, 248),
    Background = Color3.fromRGB(7, 12, 23),
    Outline = Color3.fromRGB(71, 85, 105),
    Text = Color3.fromRGB(248, 250, 252),
    Placeholder = Color3.fromRGB(148, 163, 184),
    Button = Color3.fromRGB(18, 29, 48),
    Icon = Color3.fromRGB(45, 212, 191),
})

local UI = {}
local Window = WindUI:CreateWindow({
    Title = "PSX OG | Nova Develop",
    Icon = "sparkles",
    Author = "Reliable automation suite | v" .. VERSION,
    Folder = "PSX_Nova_Stable",
    Size = UDim2.fromOffset(820, 570),
    MinSize = Vector2.new(650, 430),
    MaxSize = Vector2.new(1120, 780),
    ToggleKey = Enum.KeyCode.RightShift,
    Transparent = true,
    Theme = "Nova Stable",
    Resizable = true,
    SideBarWidth = 174,
    HideSearchBar = true,
    ScrollBarEnabled = true,
    Acrylic = false,
})
uiStageYield("window ready")

if Window.ConfigManager then
    local created, profile = pcall(function()
        return Window.ConfigManager:Config("default", false)
    end)
    if created then
        UI.Profile = profile
        local inspected, exists = pcall(function()
            return type(isfile) == "function" and isfile(profile.Path)
        end)
        UI.ProfileExists = inspected and exists == true
    else
        UI.ProfileProblem = tostring(profile)
    end
else
    UI.ProfileProblem = "executor filesystem API is unavailable"
end

for index, definition in ipairs({
    { "FarmTab", "Farm", "paw-print" },
    { "MonitorTab", "Monitor", "activity" },
    { "EggTab", "Eggs", "egg" },
    { "MachinesTab", "Machines", "settings" },
    { "BoostsTab", "Boosts", "zap" },
    { "LootTab", "Loot", "package-open" },
    { "RewardsTab", "Rewards", "gift" },
    { "GraphicsTab", "Graphics", "monitor" },
    { "SessionTab", "Session", "shield-check" },
}) do
    UI[definition[1]] = Window:Tab({ Title = definition[2], Icon = definition[3] })
    if index % 2 == 0 then uiStageYield("tabs " .. tostring(index) .. "/9") end
end
uiStageYield("tabs complete")

refreshEggDropdown = function(force)
    local now = os.clock()
    if not force and UI.LastEggRefreshAt and now - UI.LastEggRefreshAt < 0.6 then return end
    UI.LastEggRefreshAt = now
    if not autoEggController then
        statusSetters.EggCatalog("Egg catalog worker is loading; no server request is involved.")
        return
    end
    local called, options, selectedLabel, selectedId, summary, labelMap = pcall(autoEggController, "catalog", {
        Library = Library,
        Player = player,
        Scope = config.EggScope,
        Selected = config.EggName,
        PreserveSelected = config.AutoEgg,
        GetCurrency = getCurrentCurrency,
        FormatNumber = formatRateNumber,
    })
    if not called or type(options) ~= "table" then
        statusSetters.EggCatalog("Local egg catalog error: " .. tostring(called and summary or options))
        return
    end
    config.EggName = selectedId ~= "" and selectedId or nil
    eggLabelToId = type(labelMap) == "table" and labelMap or {}
    eggIdToLabel = {}
    for label, eggId in pairs(eggLabelToId) do eggIdToLabel[eggId] = label end
    local signature = tostring(config.EggScope) .. "|" .. tostring(selectedLabel)
        .. "|" .. table.concat(options, "\0")
    statusSetters.EggCatalog(summary)
    if not UI.EggDropdown or (not force and signature == UI.LastEggSignature) then return end
    UI.LastEggSignature = signature
    pcall(function() UI.EggDropdown:Refresh(options) end)
    if selectedLabel then pcall(function() UI.EggDropdown:Select(selectedLabel) end) end
end

UI.FarmHero = UI.FarmTab:Section({ Title = "01 / Adaptive Routing", Box = true, Opened = true })
UI.FarmHero:Paragraph({
    Title = "RESERVE > JOIN > FARM > BREAK",
    Desc = "Explicit UID routing fills up to 16 transport lanes while every accepted pet stays locked to one live target.",
})
UI.FarmHero:Toggle({
    Flag = "pet_farm",
    Title = "Enable Pet Farm",
    Desc = "A target remains locked until the game confirms that the coin is destroyed",
    Value = false,
    Callback = function(value)
        local enabled = value == true
        if config.PetFarm == enabled then return end
        config.PetFarm = enabled
        if enabled and not petFarm.Engine and not petFarm.Loading then
            task.spawn(function()
                local ready, problem = petFarm:EnsureEngine()
                if not ready then trace("pet engine load", tostring(problem)) end
            end)
        end
        requestFarmReset(config.PetFarm and "farm enabled" or "farm disabled")
    end,
})
UI.FarmHero:Dropdown({
    Flag = "assignment_strategy",
    Title = "Assignment Strategy",
    Desc = "Choose how equipped pets are distributed across valid targets",
    Values = { "Different Strongest", "Different Weakest", "All on Strongest Regular", "Boss Chest Only" },
    Value = "Different Strongest",
    Multi = false,
    AllowNone = false,
    Callback = function(value)
        if config.Mode == value then return end
        config.Mode = value
        if config.PetFarm then requestFarmReset("assignment mode changed") end
    end,
})
uiStageYield("farm controls")

UI.WorldValues = { "Current World" }
for _, worldName in ipairs(WorldOrder) do table.insert(UI.WorldValues, worldName) end
UI.TargetSection = UI.FarmTab:Section({ Title = "02 / Target Space", Box = true, Opened = true })

local function refreshZoneDropdown(force)
    if not UI.ZoneDropdown then return end
    local options, resolvedWorld = getZoneOptions(config.World)
    local signature = config.World .. "|" .. tostring(resolvedWorld) .. "|" .. table.concat(options, "\0")
    if not force and signature == UI.LastZoneSignature then return end
    local selected, valid = config.Zone, false
    for _, option in ipairs(options) do
        if option == selected then valid = true; break end
    end
    if not valid then selected = config.World == "Current World" and "Player Zone" or options[1] end
    UI.LastZoneSignature = signature
    UI.ZoneDropdown:Refresh(options)
    if selected then
        config.Zone = selected
        pcall(function() UI.ZoneDropdown:Select(selected) end)
    end
end

UI.WorldDropdown = UI.TargetSection:Dropdown({
    Flag = "target_world",
    Title = "World",
    Desc = "Current World follows teleports and rebuilds the zone catalog automatically",
    Values = UI.WorldValues,
    Value = "Current World",
    Multi = false,
    AllowNone = false,
    Callback = function(value)
        local changed = config.World ~= value
        config.World = value
        refreshZoneDropdown(true)
        if changed and config.PetFarm then requestFarmReset("world selection changed") end
    end,
})

UI.InitialZones = getZoneOptions("Current World")
UI.ZoneDropdown = UI.TargetSection:Dropdown({
    Flag = "target_zone",
    Title = "Zone",
    Desc = "Player Zone follows your character without restarting the farm",
    Values = UI.InitialZones,
    Value = "Player Zone",
    Multi = false,
    AllowNone = false,
    Callback = function(value)
        if config.Zone == value then return end
        config.Zone = value
        if config.PetFarm then requestFarmReset("zone selection changed") end
    end,
})
UI.LastZoneSignature = "Current World|" .. tostring(getCurrentWorld()) .. "|" .. table.concat(UI.InitialZones, "\0")
uiStageYield("target controls")

UI.MonitorHero = UI.MonitorTab:Section({ Title = "Live Telemetry", Box = true, Opened = true })
UI.MonitorHero:Paragraph({
    Title = "REAL-TIME CONTROL PLANE",
    Desc = "Assignments, game-controller state and balance-derived income update independently.",
})
statusViews.Farm = UI.MonitorHero:Paragraph({
    Title = "Assignment Status",
    Desc = "Waiting for the game pet controller and location data...",
})
statusViews.Health = UI.MonitorHero:Paragraph({
    Title = "Controller Health",
    Desc = "Runtime discovery is starting...",
})

UI.PerformanceSection = UI.MonitorTab:Section({ Title = "Balance Intelligence", Box = true, Opened = true })
UI.PerformanceSection:Dropdown({
    Flag = "tracked_currency",
    Title = "Tracked Currency",
    Desc = "Active Balances discovers real gains; Auto follows the selected world",
    Values = CurrencyChoices,
    Value = "Active Balances",
    Multi = false,
    AllowNone = false,
    Callback = function(value)
        if config.TrackedCurrency == value then return end
        config.TrackedCurrency = value
        currencyMonitor:Reset()
        statusSetters.Rate("Reading exact balances; no orb or visual-event estimates are used...")
    end,
})
statusViews.Rate = UI.PerformanceSection:Paragraph({
    Title = "Balance Farm Rate",
    Desc = "Enable Pet Farm. Income is derived only from positive Library.Save balance changes.",
})
uiStageYield("monitor controls")

do
    trace("06A automation UI loading")
    local automationUIController, automationUILoadProblem = loadRemoteController(
        AUTOMATION_UI_MODULE_URL,
        "automation UI module"
    )
    if not automationUIController then
        error("Automation UI module could not be loaded: " .. tostring(automationUILoadProblem), 0)
    end
    local automationUIBuilt, automationUIAccepted, automationUIControls = pcall(
        automationUIController,
        "build",
        {
            UI = UI,
            Config = config,
            StatusViews = statusViews,
            RefreshEggs = function(force) refreshEggDropdown(force) end,
            EnsureAutoEgg = ensureAutoEggModule,
            InvalidateEggCatalog = function()
                if autoEggController then pcall(autoEggController, "invalidate-catalog") end
            end,
            StartAutoEgg = startAutoEggModule,
            StopAutoEgg = stopAutoEggModule,
            EggIdForLabel = function(label) return eggLabelToId[label] end,
            SetEggCatalogStatus = statusSetters.EggCatalog,
            RefreshRoutes = refreshRouteHealth,
            SetRouteStatus = statusSetters.Routes,
            GetMachinePetCatalog = getMachinePetCatalog,
            StartMachine = function(kind) machineModules:Start(kind) end,
            StopMachine = function(kind) machineModules:Stop(kind) end,
            SetGoldStatus = statusSetters.Gold,
            SetRainbowStatus = statusSetters.Rainbow,
            SetDarkMatterStatus = statusSetters.DarkMatter,
            ReconcileBoost = reconcileBoostModule,
            BoostEnabled = boostAutomationEnabled,
            StartBoost = startBoostModule,
            YieldUI = uiStageYield,
        }
    )
    if not automationUIBuilt or automationUIAccepted ~= true or type(automationUIControls) ~= "table" then
        error(
            "Automation UI module failed to build: "
                .. tostring(not automationUIBuilt and automationUIAccepted or automationUIControls),
            0
        )
    end
    autoEggToggleControl = automationUIControls.AutoEggToggle
    UI.EggScopeDropdown = automationUIControls.EggScopeDropdown
    UI.EggDropdown = automationUIControls.EggDropdown
    refreshEggDropdown(true)
    trace("06B automation UI ready")
end
uiStageYield("automation controls")

UI.DiamondSection = UI.MachinesTab:Section({ Title = "Tech Diamond Exchange", Box = true, Opened = true })
UI.DiamondSection:Toggle({
    Flag = "auto_tech_diamond_pack",
    Title = "Auto Best Tech Diamond Pack",
    Desc = "Tier 4 only / checks every 3 minutes / requires at least 1T Tech Coins",
    Value = false,
    Callback = function(value)
        config.AutoTechDiamondPack = value == true
        diamondPackNextCheck = 0
        if config.AutoTechDiamondPack then
            statusSetters.Diamond("Enabled. A local balance check will run now; below 1T no request is sent.")
        else
            statusSetters.Diamond("Disabled. No purchase requests will be sent.")
        end
    end,
})
statusViews.Diamond = UI.DiamondSection:Paragraph({
    Title = "Diamond Exchange Status",
    Desc = "Disabled / the live purchase remote is resolved independently each session",
})
uiStageYield("diamond controls")

UI.LootHero = UI.LootTab:Section({ Title = "Local Pickup Layer", Box = true, Opened = true })
UI.LootHero:Paragraph({
    Title = "FAST COLLECTION",
    Desc = "Moves local drops to the character while server-side pet assignments continue uninterrupted.",
})
UI.LootHero:Toggle({
    Flag = "collect_orbs",
    Title = "Collect Orbs",
    Desc = "Pulls up to 40 live orbs per pass",
    Value = false,
    Callback = function(value) config.Orbs = value == true end,
})
UI.LootHero:Toggle({
    Flag = "collect_lootbags",
    Title = "Collect Lootbags",
    Desc = "Pulls up to 20 live lootbags per pass",
    Value = false,
    Callback = function(value) config.Lootbags = value == true end,
})
uiStageYield("loot controls")

UI.RewardsHero = UI.RewardsTab:Section({ Title = "Timer-Gated Rewards", Box = true, Opened = true })
UI.RewardsHero:Paragraph({
    Title = "CLAIM ONLY WHEN READY",
    Desc = "Uses the server clock and save timers. No speculative claim spam and no world restriction.",
})
UI.RewardsHero:Toggle({
    Flag = "auto_vip_rewards",
    Title = "Auto VIP Rewards",
    Desc = "Claims when the four-hour VIP cooldown reaches zero",
    Value = false,
    Callback = function(value)
        local enabled = value == true
        config.AutoVIPRewards = enabled
        local state = rewardStates.VIP
        state.NextAttempt = 0
        state.LastTimingError = nil
        state.ArmedReported = false
    end,
})
UI.RewardsHero:Toggle({
    Flag = "auto_rank_rewards",
    Title = "Auto Rank Rewards",
    Desc = "Uses the cooldown for your current rank and its live RankTimer",
    Value = false,
    Callback = function(value)
        local enabled = value == true
        config.AutoRankRewards = enabled
        local state = rewardStates.Rank
        state.NextAttempt = 0
        state.LastTimingError = nil
        state.ArmedReported = false
    end,
})
UI.RewardsHero:Paragraph({
    Title = "Remote Policy",
    Desc = "VIP and Rank resolve separate live remotes; every accepted or rejected server response is logged.",
})
uiStageYield("reward controls")

UI.GraphicsHero = UI.GraphicsTab:Section({ Title = "Client Performance Profile", Box = true, Opened = true })
UI.GraphicsHero:Paragraph({
    Title = "VISIBLE WORLD / LOWER COST",
    Desc = "Keeps navigation readable while simplifying the map and dense coin/chest visuals.",
})
UI.GraphicsHero:Toggle({
    Flag = "balanced_potato_mode",
    Title = "Balanced Potato Mode",
    Desc = "Stops future processing when disabled; rejoin to restore visuals already simplified",
    Value = false,
    Callback = function(value) setPotatoMode(value == true) end,
})
UI.GraphicsHero:Dropdown({
    Flag = "fps_limit",
    Title = "FPS Limit",
    Desc = "Independent from Potato Mode / Unlimited maps to a safe 999 cap",
    Values = { "Unchanged", "30", "45", "60", "90", "120", "144", "165", "240", "Unlimited" },
    Value = "Unchanged",
    Multi = false,
    AllowNone = false,
    Callback = applyFPSLimit,
})
UI.GraphicsHero:Paragraph({
    Title = "Preservation Boundary",
    Desc = "Animations and geometry stay active. Dynamic eggs, pets, coins and chests are texture-locked while POS, _SELECTIONFX and Network workers remain untouched.",
})
uiStageYield("graphics controls")

UI.SessionSection = UI.SessionTab:Section({ Title = "Session Control", Box = true, Opened = true })
UI.SessionSection:Paragraph({
    Title = "SAFE START / CLEAN STOP",
    Desc = "RightShift toggles the window. STOP disconnects workers before final pet cleanup.",
})
UI.SessionSection:Toggle({
    Flag = "anti_afk",
    Title = "Anti-AFK",
    Desc = "Prevents the Roblox idle kick",
    Value = true,
    Callback = function(value) config.AntiAFK = value == true end,
})

UI.ProfileSection = UI.SessionTab:Section({ Title = "Default Configuration", Box = true, Opened = true })
UI.ProfileSection:Paragraph({
    Title = "SAVE ONCE / AUTO-LOAD EVERY RUN",
    Desc = "The default profile restores controls through WindUI and then reapplies World before Zone.",
})
UI.ProfileStatus = UI.ProfileSection:Paragraph({
    Title = "Configuration Status",
    Desc = UI.Profile and (UI.ProfileExists
        and "Saved profile found. Automatic loading is armed."
        or "No saved profile yet. Press SAVE PROFILE to create one.")
        or ("Profiles unavailable: " .. tostring(UI.ProfileProblem or "unknown filesystem error")),
})

function UI.SetProfileStatus(text)
    if UI.ProfileStatus then
        pcall(function() UI.ProfileStatus:SetDesc(tostring(text)) end)
    end
end

function UI.ReconcileProfile(label)
    if not UI.Profile or not running() then return end
    local savedWorld = UI.Profile:Get("selected_world")
    local savedZone = UI.Profile:Get("selected_zone")
    local savedEgg = UI.Profile:Get("selected_egg_id")
    local savedEggScope = UI.Profile:Get("selected_egg_scope")
    if savedEggScope == "Nearby Eggs" or savedEggScope == "All Hatchable Eggs" then
        config.EggScope = savedEggScope
        pcall(function() UI.EggScopeDropdown:Select(savedEggScope) end)
    end
    local directory = Library.Directory and Library.Directory.Eggs
    local savedEggEntry = type(directory) == "table" and directory[tostring(savedEgg or "")] or nil
    if type(savedEggEntry) == "table" and savedEggEntry.disabled ~= true and savedEggEntry.hatchable ~= false then
        config.EggName = tostring(savedEgg)
    end
    refreshEggDropdown(true)
    local savedEggLabel = config.EggName and eggIdToLabel[config.EggName]
    if savedEggLabel then pcall(function() UI.EggDropdown:Select(savedEggLabel) end) end
    local worldValid = false
    for _, value in ipairs(UI.WorldValues) do
        if value == savedWorld then worldValid = true; break end
    end
    if not worldValid then savedWorld = config.World end
    pcall(function() UI.WorldDropdown:Select(savedWorld) end)

    task.delay(0.12, function()
        if not running() then return end
        refreshZoneDropdown(true)
        local options = getZoneOptions(config.World)
        local zoneValid = false
        for _, value in ipairs(options) do
            if value == savedZone then zoneValid = true; break end
        end
        if not zoneValid then savedZone = config.Zone end
        pcall(function() UI.ZoneDropdown:Select(savedZone) end)
        UI.SetProfileStatus(string.format(
            "%s\nWorld: %s | Zone: %s | Egg: %s | auto-load: enabled",
            tostring(label or "Profile synchronized"),
            tostring(config.World),
            tostring(config.Zone),
            tostring(config.EggName or "none")
        ))
    end)
end

function UI.SaveProfile()
    if not UI.Profile then
        UI.SetProfileStatus("Save unavailable: " .. tostring(UI.ProfileProblem or "filesystem API missing"))
        return
    end
    UI.Profile:Set("selected_world", config.World)
    UI.Profile:Set("selected_zone", config.Zone)
    UI.Profile:Set("selected_egg_id", config.EggName or "")
    UI.Profile:Set("selected_egg_scope", config.EggScope)
    UI.Profile:Set("script_version", VERSION)
    UI.Profile:Set("nova_autoload", true)
    UI.Profile:SetAutoLoad(false)
    local saved, result = pcall(function() return UI.Profile:Save() end)
    if not saved then
        UI.SetProfileStatus("Save failed: " .. tostring(result))
        return
    end
    UI.ProfileExists = true
    UI.SetProfileStatus(string.format(
        "Profile saved successfully.\nWorld: %s | Zone: %s | Egg: %s | auto-load: enabled",
        tostring(config.World),
        tostring(config.Zone),
        tostring(config.EggName or "none")
    ))
    trace("config saved", tostring(UI.Profile.Path))
end

function UI.LoadProfile(label)
    if not UI.Profile then
        UI.SetProfileStatus("Load unavailable: " .. tostring(UI.ProfileProblem or "filesystem API missing"))
        return
    end
    local called, result, problem = pcall(function() return UI.Profile:Load() end)
    if not called then
        UI.SetProfileStatus("Load failed: " .. tostring(result))
        return
    end
    if result == false then
        UI.SetProfileStatus("Load failed: " .. tostring(problem))
        return
    end
    UI.SetProfileStatus("Profile loaded. Synchronizing controls and target location...")
    task.delay(0.3, function() UI.ReconcileProfile(label or "Manual load complete") end)
end

UI.ProfileSection:Button({
    Title = "SAVE PROFILE",
    Desc = "Stores every flagged control and enables automatic loading",
    Icon = "save",
    Callback = UI.SaveProfile,
})
UI.ProfileSection:Button({
    Title = "LOAD PROFILE",
    Desc = "Restores the saved profile immediately without restarting the script",
    Icon = "folder-open",
    Callback = function() UI.LoadProfile() end,
})

if UI.Profile and UI.ProfileExists then
    task.delay(0.8, function() UI.LoadProfile("Automatic load complete") end)
end

local shutdownStarted = false

local function hideInterface()
    for _, key in ipairs({ "ScreenGui", "NotificationGui", "DropdownGui", "TooltipGui" }) do
        local gui = WindUI and WindUI[key]
        if gui then pcall(function() gui.Enabled = false end) end
    end
end

local function finishShutdown()
    local shutdownDeadline = os.clock() + 1
    while (farmResetRunning or allocatorBusy) and os.clock() < shutdownDeadline do
        RunService.Heartbeat:Wait()
    end

    local cleaned, problem = pcall(clearAssignments, true)
    if not cleaned then warn("[PSX SLIM] shutdown cleanup: " .. tostring(problem)) end
end

local function shutdown(reason)
    if shutdownStarted then return end
    shutdownStarted = true
    trace("stop requested", tostring(reason or "reload"))
    config.PetFarm = false
    config.AutoTechDiamondPack = false
    config.AutoVIPRewards = false
    config.AutoRankRewards = false
    config.AutoGoldenGalaxyFox = false
    config.AutoRainbowGalaxyFox = false
    config.AutoDarkMatterGalaxyFox = false
    config.AutoClaimDarkMatter = false
    config.AutoBoostBundle = false
    config.AutoTripleCoins = false
    config.AutoTripleDamage = false
    config.AutoSuperLucky = false
    config.AutoUltraLucky = false
    config.AutoEgg = false
    if petFarm.Engine then pcall(petFarm.Engine, "reset") end
    stopAutoEggModule()
    machineModules:StopAll()
    stopBoostModule()
    resetSupportCoordinator()
    moduleLoadState.Busy = false
    moduleLoadState.Owner = nil
    moduleLoadState.NextAt = 0
    config.PotatoMode = false
    stopGraphics()
    farmResetRequested = false
    if env.PSX_OG_SLIM_TOKEN == token then env.PSX_OG_SLIM_TOKEN = nil end
    disconnectAll()
    if env.PSX_OG_SLIM_CLEANUP == shutdown then env.PSX_OG_SLIM_CLEANUP = nil end
    if env.PSX_OG_UI_CLEANUP == shutdown then env.PSX_OG_UI_CLEANUP = nil end

    hideInterface()
    local destroyed, problem = pcall(function() Window:Destroy() end)
    if not destroyed then
        warn("[PSX SLIM] window destroy: " .. tostring(problem))
        pcall(function() WindUI:Destroy() end)
    end

    task.delay(0.6, function()
        for _, key in ipairs({ "ScreenGui", "NotificationGui", "DropdownGui", "TooltipGui" }) do
            local gui = WindUI and WindUI[key]
            if gui then pcall(function() gui:Destroy() end) end
        end
    end)

    if reason == "button" then
        task.spawn(finishShutdown)
    else
        finishShutdown()
    end
end

env.PSX_OG_SLIM_CLEANUP = shutdown
env.PSX_OG_UI_CLEANUP = shutdown

UI.SessionSection:Button({
    Title = "STOP SCRIPT",
    Desc = "Stops workers instantly; pet cleanup finishes in the background",
    Icon = "power",
    Callback = function()
        shutdown("button")
    end,
})

task.spawn(function()
    while task.wait(1) do
        if not running() then break end
        if config.AutoTechDiamondPack and not diamondPackBusy and os.clock() >= diamondPackNextCheck then
            local ok, problem = pcall(runDiamondPackCheck)
            if not ok then
                diamondPackBusy = false
                diamondPackNextCheck = os.clock() + DIAMOND_PACK_INTERVAL
                local status = "Worker error: " .. tostring(problem)
                trace("diamond pack", status)
                statusSetters.Diamond(status .. "\nNext retry in 3 minutes.")
            end
        end
    end
end)

task.spawn(function()
    local order = { "VIP", "Rank" }
    while task.wait(1) do
        if not running() then break end
        local now = os.clock()

        for _, kind in ipairs(order) do
            local state = rewardStates[kind]
            if config[state.ConfigKey] then
                local remaining, cooldown, timingError = getRewardTiming(kind)
                if remaining == nil then
                    if timingError ~= state.LastTimingError then
                        state.LastTimingError = timingError
                        trace(string.lower(state.Label) .. " reward timer", timingError)
                    end
                elseif remaining > 0 then
                    state.LastTimingError = nil
                    state.NextAttempt = 0
                    if not state.ArmedReported then
                        local remote, sourceName, sessionIndex, routeProblem =
                            getCommandRemote(state.Command)
                        local route = remote and routeText(sourceName, sessionIndex)
                            or ("route pending: " .. tostring(routeProblem))
                        trace(string.lower(state.Label) .. " reward armed",
                            "ready in " .. formatDuration(remaining) .. " | " .. route)
                        state.ArmedReported = true
                    end
                elseif now >= state.NextAttempt then
                    state.LastTimingError = nil
                    local succeeded = invokeReward(kind)
                    state.ArmedReported = false
                    state.NextAttempt = now
                        + (succeeded and math.max(cooldown or 0, REWARD_RETRY_DELAY)
                            or REWARD_RETRY_DELAY)
                end
            end
        end
    end
end)

task.spawn(function()
    local lastSelection, lastRateText = nil, nil
    while task.wait(1) do
        if not running() then break end

        local selection = config.TrackedCurrency
        if selection == "Auto" then selection = selection .. "|" .. tostring(getTrackedCurrencyName()) end
        if selection ~= lastSelection then
            lastSelection = selection
            currencyMonitor:Reset()
        end

        local rateText
        if not config.PetFarm then
            currencyMonitor:Reset()
            rateText = "Balance farm rate: pet farm disabled"
        else
            local now = os.clock()
            local currencyNames = currencyMonitor:TrackedNames()
            local balances = currencyMonitor:GetBalances(currencyNames)
            local available = 0
            local active = {}

            for _, currencyName in ipairs(currencyNames) do
                local currentAmount = balances[currencyName]
                if currentAmount ~= nil then
                    available = available + 1
                    local sample = currencyMonitor:Update(currencyName, currentAmount, now)
                    if config.TrackedCurrency ~= "Active Balances" or sample.TotalEarned > 0 then
                        active[#active + 1] = { Name = currencyName, Sample = sample }
                    end
                end
            end

            table.sort(active, function(left, right)
                local leftGain = left.Sample.PerMinute or 0
                local rightGain = right.Sample.PerMinute or 0
                if leftGain == rightGain then return left.Name < right.Name end
                return leftGain > rightGain
            end)

            if available == 0 then
                currencyMonitor:Reset()
                rateText = "Balance farm rate: currencies were not found in Library.Save"
            elseif #active == 0 then
                local elapsed = math.max(0, now - (currencyMonitor.StartedAt or now))
                rateText = string.format(
                    "Watching %d exact balances | waiting for a positive change...\nSession: %ds | no orb/event estimates",
                    available,
                    math.floor(elapsed + 0.5)
                )
            else
                local lines = {}
                local limit = math.min(#active, 4)
                for index = 1, limit do
                    local entry = active[index]
                    lines[#lines + 1] = currencyMonitor:RateLine(entry.Name, entry.Sample, now)
                end
                if #active > limit then lines[#lines + 1] = "+" .. tostring(#active - limit) .. " more active balance(s)" end
                rateText = table.concat(lines, "\n")
            end
        end

        if rateText ~= lastRateText then
            lastRateText = rateText
            statusSetters.Rate(rateText)
        end
    end
end)

task.spawn(function()
    local nextZoneRefreshAt, nextEggRefreshAt = 0, 0
    while task.wait(0.75) do
        if not running() then break end
        local now = os.clock()
        if now >= nextZoneRefreshAt then
            nextZoneRefreshAt = now + 1.5
            refreshZoneDropdown(false)
        end
        if now >= nextEggRefreshAt then
            nextEggRefreshAt = now + 2
            refreshEggDropdown(false)
        end
        local targets, world, zone = orderedTargets(config.Mode)
        local equippedIds = getEquippedPetIds()
        local equippedCount = #equippedIds
        local assignedCount = assignmentCount()
        local lockedCount, pendingCount = petFarm:PhaseCounts()
        local dispatchStats = petFarm:RefreshStats()
        local networkState = networkReady() and "ready" or "waiting"
        local signalState = Library.Signal and type(Library.Signal.Fire) == "function" and "ready" or "waiting"
        local controllerState = runtimeDriverReady and "linked" or signalState
        local runtimeActive, runtimeIdle, runtimeMissing = runtimePetCounts(equippedIds)
        local runtimeLine = runtimeActive ~= nil
            and string.format("Visual runtime: %d moving/farming | %d ready | %d unseen",
                runtimeActive, runtimeIdle, runtimeMissing)
            or "Visual runtime: optional game-state mirror is still being discovered"
        statusSetters.Farm(string.format(
            "%s  >  %s\nTargets: %d | locks: %d/%d | joining: %d | idle: %d\n%s",
            tostring(world or "unknown"),
            tostring(zone or "unknown"),
            #targets,
            lockedCount,
            equippedCount,
            pendingCount,
            math.max(equippedCount - assignedCount, 0),
            runtimeLine
        ))
        statusSetters.Health(string.format(
            "Network: %s | %s | runtime mirror: %s | allocator: %s\nUID lanes: %d | active/queued: %d/%d | avg RTT: %dms\nJoin ok/retry/reject/error: %d/%d/%d/%d\nRecoveries: %d | last: %s\nDriver: %s",
            networkState,
            petFarm.RouteSummary,
            controllerState,
            farmResetRunning and "reconfiguring" or "stable",
            tonumber(dispatchStats.Limit) or 0,
            tonumber(dispatchStats.Active) or 0,
            tonumber(dispatchStats.Queued) or 0,
            math.floor((tonumber(dispatchStats.AverageRTT) or 0) * 1000 + 0.5),
            tonumber(dispatchStats.Accepted) or 0,
            tonumber(dispatchStats.Retries) or 0,
            tonumber(dispatchStats.Rejected) or 0,
            tonumber(dispatchStats.Errors) or 0,
            idleRecoveryCount,
            lastRecovery,
            driverStatus
        ))
    end
end)

pcall(function() UI.FarmTab:Select() end)
trace("07 startup complete")
task.defer(function()
    local ready, problem = petFarm:EnsureEngine()
    if not ready and problem ~= "engine load already in progress" then
        trace("pet engine preload", tostring(problem))
    end
end)
end

startInterfaceAndWorkers()
