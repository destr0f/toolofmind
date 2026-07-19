local VERSION = "1.2.6-dev.3"
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
local connection = env.PSX_OG_FastEggState.Connection
if connection and type(connection.Disconnect) == "function" then
pcall(function() connection:Disconnect() end)
end
env.PSX_OG_FastEggState = nil
end
for _, key in ipairs({ "PSX_OG_RewardInvokeCaptureState", "PSX_OG_BoostRemoteCaptureState" }) do
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
TrackedCurrency = "Auto",
Orbs = false,
Lootbags = false,
AntiAFK = true,
AutoTechDiamondPack = false,
AutoVIPRewards = false,
AutoRankRewards = false,
}
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
ProbePending = false,
NextAttempt = 0,
},
Rank = {
Label = "Rank",
Command = "Redeem Rank Rewards",
ConfigKey = "AutoRankRewards",
ProbePending = false,
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
local initialized, WindUI = pcall(windChunk)
windChunk = nil
if not initialized then error("WindUI initialization failed: " .. tostring(WindUI), 0) end
trace("06 WindUI initialized")
local function networkReady()
local network = Library and Library.Network
if not network or type(network.Fire) ~= "function" or type(network.Invoke) ~= "function" then
return nil
end
if Library.Loaded ~= nil and Library.Loaded ~= true then return nil end
return network
end
local function normalize(value)
value = string.lower(tostring(value or ""))
value = string.gsub(value, "[%p_]+", " ")
value = string.gsub(value, "%s+", " ")
return string.match(value, "^%s*(.-)%s*$") or value
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
local function parseShortAmount(value)
if type(value) == "number" then return value end
if type(value) ~= "string" then return nil end
local compact = string.lower(value)
compact = string.gsub(compact, "[,%s]", "")
local numberText, suffix = string.match(compact, "^([%d%.]+)([kmbt]?)")
local amount = tonumber(numberText)
if not amount then return nil end
local multipliers = { k = 1e3, m = 1e6, b = 1e9, t = 1e12 }
return amount * (multipliers[suffix] or 1)
end
local function getDiamondPackCost(tier)
local framework = ReplicatedStorage:FindFirstChild("Framework")
local modules = framework and framework:FindFirstChild("Modules")
local directory = modules and modules:FindFirstChild("1 - Directory")
local configModule = directory and directory:FindFirstChild("ExclusiveShopConfig")
if not configModule then return nil end
local ok, shopConfig = pcall(require, configModule)
if not ok or type(shopConfig) ~= "table" or type(shopConfig.DiamondPacks) ~= "table" then
return nil
end
local pack = shopConfig.DiamondPacks[tonumber(tier) or DIAMOND_PACK_TIER]
if type(pack) ~= "table" then return nil end
for _, key in ipairs({ "displayCost", "DisplayCost", "currencyCost", "CurrencyCost", "cost", "Cost", "price", "Price" }) do
local parsed = parseShortAmount(pack[key])
if parsed then return parsed end
end
for key, value in pairs(pack) do
local keyName = string.lower(tostring(key))
if string.find(keyName, "cost", 1, true) or string.find(keyName, "price", 1, true) then
local parsed = parseShortAmount(value)
if parsed then return parsed end
end
end
return nil
end
local WorldOrder = {
"Spawn World", "Fantasy World", "Tech World", "Axolotl Ocean",
"Pixel World", "Cat World", "The Void", "Doodle World",
"Kawaii World", "Dog World", "Diamond Mine", "Christmas Event", "Trading Plaza",
}
local CurrencyChoices = {
"Auto", "Coins", "Diamonds", "Fantasy Coins", "Tech Coins",
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
if config.TrackedCurrency ~= "Auto" then return config.TrackedCurrency end
return CurrencyByWorld[getSelectedWorld()] or "Coins"
end
local currencySamples = {}
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
local coinPetRevision = 0
local removalRevisions = {}
local removedUntil = {}
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
local record = coinRecords[id] or { Id = id, Pets = {} }
coinRecords[id] = record
local health = tonumber(data.h or data.Health or data.health)
local maxHealth = tonumber(data.mh or data.MaxHealth or data.maxHealth)
local position = data.p or data.Position or data.position
local world = data.w or data.World or data.world
if typeof(position) == "CFrame" then position = position.Position end
if data.a ~= nil or data.Area ~= nil or data.area ~= nil then
record.Area = tostring(data.a or data.Area or data.area)
end
if data.n ~= nil or data.Name ~= nil or data.name ~= nil then
record.Name = tostring(data.n or data.Name or data.name)
end
if world ~= nil then record.World = tostring(world) end
if typeof(position) == "Vector3" then record.Position = position end
if health ~= nil then record.Health = health end
if maxHealth ~= nil then record.MaxHealth = maxHealth end
record.Health = tonumber(record.Health) or 0
peakHealth[id] = math.max(peakHealth[id] or 0, record.Health, tonumber(record.MaxHealth) or 0)
record.MaxHealth = math.max(tonumber(record.MaxHealth) or 0, peakHealth[id], record.Health)
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
removedUntil[id] = os.clock() + 0.75
if type(releaseAssignmentsForCoin) == "function" then releaseAssignmentsForCoin(id) end
if type(requestAllocatorPulse) == "function" then requestAllocatorPulse() end
end
local nextWorkspaceScanAt = 0
local function refreshWorkspaceCoins()
if os.clock() < nextWorkspaceScanAt then return end
nextWorkspaceScanAt = os.clock() + 0.1
local things = workspace:FindFirstChild("__THINGS")
local folder = things and things:FindFirstChild("Coins")
if not folder then return end
local now = os.clock()
for id, expiresAt in pairs(removedUntil) do
if now >= expiresAt then removedUntil[id] = nil end
end
local seen = {}
for _, model in ipairs(folder:GetChildren()) do
local id = tostring(readObjectValue(model, "ID") or model.Name)
if removedUntil[id] == nil then
seen[id] = true
local record = coinRecords[id] or { Id = id, Pets = {} }
coinRecords[id] = record
record.Model = model
record.Position = getInstancePosition(model) or record.Position
record.Area = readObjectValue(model, "Area") or record.Area
record.Name = readObjectValue(model, "Name") or record.Name or model.Name
record.World = readObjectValue(model, "World") or record.World
local health = tonumber(readObjectValue(model, "Health"))
if health ~= nil then
if record.FromServer and tonumber(record.Health) ~= nil then
record.Health = math.min(tonumber(record.Health), health)
else
record.Health = health
end
peakHealth[id] = math.max(peakHealth[id] or 0, health)
record.MaxHealth = math.max(tonumber(record.MaxHealth) or 0, peakHealth[id])
end
record.Removed = false
end
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
coinPetRevision = coinPetRevision + 1
record.Pets = normalizePetSet(pets)
record.EventRevision = coinEventRevision
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
coinPetRevision = 0
table.clear(coinRecords)
table.clear(peakHealth)
table.clear(removalRevisions)
table.clear(removedUntil)
table.clear(boundsCache)
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
if record.Model and record.Model.Parent == nil then return false end
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
local detected = record.Position and areaForPosition(record.Position)
if detected ~= nil then return namesMatch(detected, zone) end
return zoneAnchor ~= nil and record.Position ~= nil
and (record.Position - zoneAnchor).Magnitude <= 240
end
local function orderedTargets(mode)
refreshWorkspaceCoins()
local world = getSelectedWorld()
local zone = getSelectedZone()
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
local function queuePetRelease(petId, now)
petStates[petId] = nil
releaseWait[petId] = {
ReadyAt = now + 0.04,
ForceAt = now + 0.25,
}
end
releaseAssignmentsForCoin = function(rawId)
if rawId == nil then
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
local bulkGetter = debug and type(debug.getupvalues) == "function" and debug.getupvalues
or type(getupvalues) == "function" and getupvalues
if type(bulkGetter) == "function" then
local ok, result = pcall(bulkGetter, callback)
if ok and type(result) == "table" then
for _, value in pairs(result) do table.insert(values, value) end
return values
end
end
local singleGetter = debug and type(debug.getupvalue) == "function" and debug.getupvalue
or type(getupvalue) == "function" and getupvalue
if type(singleGetter) == "function" then
for index = 1, 32 do
local ok, first, second = pcall(singleGetter, callback, index)
if not ok or (first == nil and second == nil) then break end
table.insert(values, second ~= nil and second or first)
end
end
return values
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
local function runtimeTargetCount(model)
if type(petRuntime) ~= "table" or not model then return nil end
local target = model:FindFirstChild("POS")
if not target then return nil end
local count = 0
for _, runtimeState in pairs(petRuntime) do
if type(runtimeState) == "table" and runtimeState.owner == player
and runtimeState.farming and runtimeState.target == target then
count = count + 1
end
end
return count
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
local function callPetController(signalName, model)
local handler = resolveControllerHandler(signalName)
if handler then
local targetCountBefore = runtimeTargetCount(model)
local ok, problem = pcall(handler, model)
if ok then
inspectControllerHandler(handler)
runtimeDriverReady = petRuntime ~= nil
local targetCountAfter = runtimeTargetCount(model)
if targetCountBefore ~= nil and targetCountAfter ~= nil
and targetCountAfter <= targetCountBefore then
driverStatus = "game handler rejected target"
return false
end
driverStatus = runtimeDriverReady and "game Pets handler + local state" or "game Pets handler"
return true
end
controllerHandlers[signalName] = nil
nextControllerLookup[signalName] = 0
runtimeDriverReady = false
driverStatus = "handler error: " .. tostring(problem)
end
local signal = Library and Library.Signal
if not signal or type(signal.Fire) ~= "function" then
driverStatus = "Library.Signal.Fire unavailable"
return false
end
local revision = coinPetRevision
local ok, problem = pcall(signal.Fire, signalName, model)
if not ok then
driverStatus = "signal error: " .. tostring(problem)
return false
end
driverStatus = "Library.Signal fallback"
local deadline = os.clock() + 0.25
repeat
RunService.Heartbeat:Wait()
until not running() or not config.PetFarm or farmResetRunning or farmResetRequested
or coinPetRevision > revision or os.clock() >= deadline
if farmResetRunning or farmResetRequested then return false end
if coinPetRevision <= revision then driverStatus = "signal sent; awaiting server" end
return true
end
local function getRecordModel(record)
if record and record.Model and record.Model.Parent then return record.Model end
local things = workspace:FindFirstChild("__THINGS")
local folder = things and things:FindFirstChild("Coins")
if not folder or not record then return nil end
local direct = folder:FindFirstChild(tostring(record.Id))
if direct then
record.Model = direct
return direct
end
for _, model in ipairs(folder:GetChildren()) do
if tostring(readObjectValue(model, "ID") or model.Name) == tostring(record.Id) then
record.Model = model
return model
end
end
return nil
end
local function syncRuntimeAssignments(equipped)
if not runtimeDriverReady or type(petRuntime) ~= "table" then return false, nil end
local now = os.clock()
local observed, runtimeSeen, localPets = {}, {}, 0
for key, runtimeState in pairs(petRuntime) do
if type(runtimeState) == "table" and runtimeState.owner == player then
local petId = tostring(runtimeState.uid or key)
if equipped[petId] then
localPets = localPets + 1
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
if localPets == 0 then return true, runtimeSeen end
for petId, coinId in pairs(observed) do
releaseWait[petId] = nil
local state = petStates[petId]
if not state or tostring(state.CoinId) ~= coinId then
petStates[petId] = {
CoinId = coinId,
Phase = "locked",
Runtime = true,
ConfirmedAt = now,
}
else
state.Phase = "locked"
state.Runtime = true
state.ConfirmedAt = now
state.RuntimeIdleChecks = nil
end
end
for petId, state in pairs(petStates) do
local record = coinRecords[tostring(state.CoinId)]
if not equipped[petId] then
petStates[petId] = nil
releaseWait[petId] = nil
elseif not recordAlive(record) then
queuePetRelease(petId, now)
elseif observed[petId] == nil then
local runtimeState = runtimeSeen[petId]
if runtimeState and runtimeState.farming == false then
state.RuntimeIdleChecks = (state.RuntimeIdleChecks or 0) + 1
if state.RuntimeIdleChecks >= 2 then
petStates[petId] = nil
releaseWait[petId] = nil
idleRecoveryCount = idleRecoveryCount + 1
local petLabel = tostring(petId)
lastRecovery = "idle lock on " .. string.sub(petLabel, 1, 8)
driverStatus = "idle pet recovered; assigning next target"
trace("pet recovery", petLabel)
end
else
state.RuntimeIdleChecks = nil
end
end
end
for petId, releaseState in pairs(releaseWait) do
if not equipped[petId] then
releaseWait[petId] = nil
else
local runtimeState = runtimeSeen[petId]
if runtimeState and runtimeState.farming == false then
releaseWait[petId] = nil
elseif runtimeState == nil and now >= (releaseState.ReadyAt or now) then
releaseWait[petId] = nil
elseif now >= (releaseState.ForceAt or math.huge) then
releaseWait[petId] = nil
end
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
local function dispatchPlan(record, petIds, groupMode)
if not recordAlive(record) or #petIds == 0 then return end
local model = getRecordModel(record)
if not model or not model:FindFirstChild("POS") then
driverStatus = "coin model/POS unavailable"
rejectedUntil[record.Id] = os.clock() + 0.12
return
end
local coinId = tostring(record.Id)
local stateTokens = {}
for _, petId in ipairs(petIds) do
local state = {
CoinId = coinId,
Phase = "pending",
StartedAt = os.clock(),
StartedHealth = tonumber(record.Health),
}
petStates[petId] = state
stateTokens[petId] = state
end
local firedAny = false
if groupMode then
if not farmResetRunning and not farmResetRequested then
firedAny = callPetController("Group Select Coin", model)
end
else
for _, petId in ipairs(petIds) do
local state = stateTokens[petId]
if running() and config.PetFarm and not farmResetRunning and not farmResetRequested
and recordAlive(record) and petStates[petId] == state then
local ok = callPetController("Select Coin", model)
firedAny = ok or firedAny
if not ok then petStates[petId] = nil end
end
end
end
if not firedAny then
for petId, state in pairs(stateTokens) do
if petStates[petId] == state then petStates[petId] = nil end
end
rejectedUntil[coinId] = os.clock() + 0.12
end
end
local function syncServerAssignments(equipped)
local now = os.clock()
local observed = {}
for _, record in pairs(coinRecords) do
if recordAlive(record) then
for petId in pairs(record.Pets or {}) do
petId = tostring(petId)
if equipped[petId] then
local choices = observed[petId]
if not choices then choices = {}; observed[petId] = choices end
choices[tostring(record.Id)] = record
end
end
end
end
for petId, choices in pairs(observed) do
releaseWait[petId] = nil
local state = petStates[petId]
local coinId = state and tostring(state.CoinId) or nil
if not coinId or not choices[coinId] then
local bestRevision = -1
coinId = nil
for candidateId, record in pairs(choices) do
local revision = tonumber(record.EventRevision) or 0
if revision > bestRevision
or revision == bestRevision and (coinId == nil or candidateId < coinId) then
coinId = candidateId
bestRevision = revision
end
end
end
if not state or tostring(state.CoinId) ~= coinId then
petStates[petId] = { CoinId = coinId, Phase = "locked", ConfirmedAt = now }
else
state.Phase = "locked"
state.ConfirmedAt = now
end
end
for petId, state in pairs(petStates) do
local record = coinRecords[tostring(state.CoinId)]
if not equipped[petId] then
petStates[petId] = nil
releaseWait[petId] = nil
elseif not recordAlive(record) then
queuePetRelease(petId, now)
end
end
for petId, releaseState in pairs(releaseWait) do
if not equipped[petId] or observed[petId] ~= nil
or now >= (releaseState.ReadyAt or now) then
releaseWait[petId] = nil
end
end
end
local function assignmentCount()
local count = 0
for _ in pairs(petStates) do count = count + 1 end
return count
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
local statusParagraph, healthParagraph, rateParagraph, diamondPackParagraph, rewardParagraph
local rewardLines = { VIP = "Disabled.", Rank = "Disabled." }
local lastRewardText
local function setStatus(text)
if statusParagraph then pcall(function() statusParagraph:SetDesc(text) end) end
end
local function setHealth(text)
if healthParagraph then pcall(function() healthParagraph:SetDesc(text) end) end
end
local function setRate(text)
if rateParagraph then pcall(function() rateParagraph:SetDesc(text) end) end
end
local function setDiamondPackStatus(text)
if diamondPackParagraph then pcall(function() diamondPackParagraph:SetDesc(text) end) end
end
local function setRewardLine(kind, text)
rewardLines[kind] = text
local combined = "VIP: " .. tostring(rewardLines.VIP) .. "\nRank: " .. tostring(rewardLines.Rank)
if combined == lastRewardText then return end
lastRewardText = combined
if rewardParagraph then pcall(function() rewardParagraph:SetDesc(combined) end) end
end
local function formatRewardTime(seconds)
seconds = math.max(0, math.floor((tonumber(seconds) or 0) + 0.5))
local days = math.floor(seconds / 86400)
local hours = math.floor(seconds % 86400 / 3600)
local minutes = math.floor(seconds % 3600 / 60)
local secs = seconds % 60
if days > 0 then return string.format("%dd %02dh %02dm", days, hours, minutes) end
if hours > 0 then return string.format("%dh %02dm %02ds", hours, minutes, secs) end
return string.format("%dm %02ds", minutes, secs)
end
local function getRewardSave()
if not Library.Save or type(Library.Save.Get) ~= "function" then return nil end
local save
pcall(function() save = Library.Save.Get() end)
return type(save) == "table" and save or nil
end
local function getRewardServerTime()
if rewardServerTime ~= nil and rewardClockStarted ~= nil then
return rewardServerTime + (os.clock() - rewardClockStarted)
end
local network = networkReady()
if not network then return nil end
local ok, value = pcall(function() return network.Invoke("Get OSTime") end)
value = ok and tonumber(value) or nil
if value == nil then return nil end
rewardServerTime = value
rewardClockStarted = os.clock()
return value
end
local function getRewardTiming(kind)
local save = getRewardSave()
if not save then return nil, nil, "player save is unavailable" end
local serverTime = getRewardServerTime()
if serverTime == nil then return nil, nil, "server clock is unavailable" end
if kind == "VIP" then
local lastClaim = tonumber(save.VIPCooldown)
if lastClaim == nil then return nil, VIP_REWARD_COOLDOWN, "VIPCooldown is unavailable" end
return math.max(0, VIP_REWARD_COOLDOWN - (serverTime - lastClaim)), VIP_REWARD_COOLDOWN
end
local rankTimer = tonumber(save.RankTimer)
local ranks = Library.Directory and Library.Directory.Ranks
local rankData = type(ranks) == "table" and ranks[save.Rank] or nil
if type(rankData) ~= "table" then return nil, nil, "rank data is unavailable" end
if type(rankData.rewards) == "table" and #rankData.rewards == 0 then
return nil, nil, "current rank has no rewards"
end
local cooldown = tonumber(rankData.rewardCooldown)
if rankTimer == nil or cooldown == nil then return nil, cooldown, "rank timer is unavailable" end
return math.max(0, cooldown - (serverTime - rankTimer)), cooldown
end
local function invokeReward(kind)
local state = rewardStates[kind]
local network = networkReady()
local reply
local succeeded = false
if not network then
reply = "Local error: Library.Network is not ready; no request sent."
else
local callOk, accepted, serverMessage = pcall(function()
return network.Invoke(state.Command)
end)
if not callOk then
reply = "Transport error: " .. tostring(accepted)
elseif accepted then
succeeded = true
reply = "Server accepted: reward redeemed."
else
local reason = serverMessage ~= nil and tostring(serverMessage)
or "request rejected (cooldown/not eligible)"
reply = "Server reached: " .. reason
end
end
state.LastReply = reply
state.LastSucceeded = succeeded
trace(string.lower(state.Label) .. " reward", reply)
setRewardLine(kind, reply)
return succeeded
end
local function runManualDiamondPackTest(tier)
tier = tonumber(tier)
if not tier or tier < 1 or tier > 4 then return end
if diamondPackBusy then
setDiamondPackStatus("Another Diamond Pack request is already running.")
return
end
diamondPackBusy = true
local network = networkReady()
local balance = getCurrentCurrency("Tech Coins")
local balanceText = balance ~= nil and formatRateNumber(balance) or "unknown"
local packCost = getDiamondPackCost(tier)
local costText = packCost ~= nil and formatRateNumber(packCost) or "unknown"
local status
if not network then
status = string.format("Tier %d manual test | Local error: Library.Network is not ready; no request sent.", tier)
else
local callOk, accepted, serverMessage = pcall(function()
return network.Invoke("Buy DiamondPack", tier)
end)
if not callOk then
status = string.format("Tier %d manual test | Transport error: %s", tier, tostring(accepted))
elseif accepted then
status = string.format(
"Tier %d manual test | Server accepted: real purchase succeeded | balance before: %s",
tier,
balanceText
)
else
local reason = serverMessage ~= nil and tostring(serverMessage)
or "request rejected (insufficient funds/tier unavailable)"
status = string.format(
"Tier %d manual test | Server reached: %s | balance: %s | detected price: %s",
tier,
reason,
balanceText,
costText
)
end
end
if config.AutoTechDiamondPack then
diamondPackNextCheck = os.clock() + DIAMOND_PACK_INTERVAL
end
diamondPackBusy = false
trace("diamond pack", status)
setDiamondPackStatus(status .. "\nManual test complete; automatic tier 4 settings were not changed.")
end
local function runDiamondPackCheck()
if diamondPackBusy then return end
diamondPackBusy = true
local balance = getCurrentCurrency("Tech Coins")
local balanceText = balance ~= nil and formatRateNumber(balance) or "unknown"
local status
if balance == nil then
status = "Local check: Tech Coins balance was not found; no request sent."
else
local network = networkReady()
if not network then
status = "Local check: Library.Network is not ready; no request sent."
else
local packCost = getDiamondPackCost()
local shouldBuy = balance >= DIAMOND_PACK_MINIMUM
local safeProbe = not shouldBuy and packCost ~= nil and balance < packCost
if shouldBuy or safeProbe then
local callOk, accepted, serverMessage = pcall(function()
return network.Invoke("Buy DiamondPack", DIAMOND_PACK_TIER)
end)
if not callOk then
status = "Transport error: " .. tostring(accepted)
elseif accepted then
status = (shouldBuy and "Server purchase succeeded" or "WARNING: probe unexpectedly purchased the pack")
.. " | balance before: " .. balanceText
else
local reason = serverMessage ~= nil and tostring(serverMessage)
or "request rejected (insufficient funds expected)"
status = "Server reached: " .. reason
.. " | balance: " .. balanceText
.. " | required floor: 1T"
end
elseif packCost == nil then
status = "Local safety hold: pack price could not be read, so an underfunded probe was not sent."
else
status = "Local threshold hold: " .. balanceText
.. " is enough for the " .. formatRateNumber(packCost)
.. " pack but below the configured 1T minimum; no request sent."
end
end
end
diamondPackNextCheck = os.clock() + DIAMOND_PACK_INTERVAL
diamondPackBusy = false
trace("diamond pack", status)
setDiamondPackStatus(status .. "\nNext check in 3 minutes.")
end
local function allocatorPass()
if allocatorBusy then
allocatorRequested = true
return
end
allocatorBusy = true
repeat
allocatorRequested = false
local ok, problem = pcall(function()
if os.clock() >= nextSnapshotAt and not snapshotBusy then task.spawn(refreshCoinSnapshot) end
connectCoinSignals()
if not config.PetFarm or farmResetRunning or farmResetRequested then return end
local signature = currentFarmSignature()
if farmSelectionSignature ~= signature then
requestFarmReset("selection changed")
return
end
local petIds = getEquippedPetIds()
local equipped = {}
for _, petId in ipairs(petIds) do equipped[petId] = true end
if not runtimeDriverReady then resolveControllerHandler("Select Coin") end
local usingRuntime, runtimeSeen = syncRuntimeAssignments(equipped)
if not usingRuntime then syncServerAssignments(equipped) end
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
local freePets = {}
for _, petId in ipairs(petIds) do
local runtimeReady = not usingRuntime or runtimeSeen[petId] ~= nil
if runtimeReady and not petStates[petId] and not releaseWait[petId] then
table.insert(freePets, petId)
end
end
if #freePets == 0 then return end
local usable = {}
for _, record in ipairs(targets) do
if os.clock() >= (rejectedUntil[record.Id] or 0) then table.insert(usable, record) end
end
if #usable == 0 then
return
end
local plans = {}
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
plans[groupTarget.Id] = { Record = groupTarget, Pets = freePets }
else
local claimed = {}
for _, state in pairs(petStates) do
local coinId = tostring(state.CoinId)
if targetIds[coinId] and recordAlive(coinRecords[coinId]) then claimed[coinId] = true end
end
local unique = {}
for _, record in ipairs(usable) do
if not claimed[record.Id] then table.insert(unique, record) end
end
local sharedIndex = 1
for _, petId in ipairs(freePets) do
local record = table.remove(unique, 1)
if not record then
record = usable[((sharedIndex - 1) % #usable) + 1]
sharedIndex = sharedIndex + 1
end
local plan = plans[record.Id]
if not plan then
plan = { Record = record, Pets = {} }
plans[record.Id] = plan
end
table.insert(plan.Pets, petId)
claimed[record.Id] = true
end
end
local groupMode = config.Mode == "All on Strongest Regular" or config.Mode == "Boss Chest Only"
local useGroupHandler = groupMode and assignmentCount() == 0 and #freePets == #petIds
for _, plan in pairs(plans) do dispatchPlan(plan.Record, plan.Pets, useGroupHandler) end
end)
if not ok then driverStatus = "allocator error: " .. tostring(problem) end
until not allocatorRequested or not running()
allocatorBusy = false
end
requestAllocatorPulse = function()
allocatorRequested = true
if not allocatorBusy and running() then task.defer(allocatorPass) end
end
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
task.spawn(function()
while running() do
local added = connectPetLifecycleSignal("Added Client Pet", false)
local removed = connectPetLifecycleSignal("Removed Client Pet", true)
if added and removed then break end
task.wait(0.5)
end
end)
task.spawn(function()
while running() do
allocatorPass()
RunService.Heartbeat:Wait()
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
WindUI:AddTheme({
Name = "PSX Aurora",
Accent = Color3.fromRGB(99, 102, 241),
Background = Color3.fromRGB(8, 15, 29),
Outline = Color3.fromRGB(34, 211, 238),
Text = Color3.fromRGB(248, 250, 252),
Placeholder = Color3.fromRGB(165, 180, 252),
Button = Color3.fromRGB(24, 34, 58),
Icon = Color3.fromRGB(103, 232, 249),
})
local Window = WindUI:CreateWindow({
Title = "PSX OG | Nova Farm",
Icon = "sparkles",
Author = "Adaptive routing | v" .. VERSION,
Folder = "PSX_Slim_Farm",
Size = UDim2.fromOffset(720, 520),
MinSize = Vector2.new(590, 400),
MaxSize = Vector2.new(1024, 760),
ToggleKey = Enum.KeyCode.RightShift,
Transparent = true,
Theme = "PSX Aurora",
Resizable = true,
SideBarWidth = 185,
HideSearchBar = true,
ScrollBarEnabled = true,
Acrylic = false,
})
local PetsTab = Window:Tab({ Title = "Pet Farm", Icon = "paw-print" })
local LootTab = Window:Tab({ Title = "Loot", Icon = "package-open" })
local MiscTab = Window:Tab({ Title = "Session", Icon = "shield-check" })
local PetsSection = PetsTab:Section({ Title = "Farm Control", Box = true, Opened = true })
PetsSection:Paragraph({
Title = "Adaptive Pet Allocator",
Desc = "Zone-aware target locks with live idle-pet recovery. Pets stay on a coin until the game confirms that they are free.",
})
PetsSection:Toggle({
Title = "Enable Pet Farm",
Desc = "Targets are locked until the coin is completely destroyed",
Value = false,
Callback = function(value)
local enabled = value == true
if config.PetFarm == enabled then return end
config.PetFarm = enabled
requestFarmReset(config.PetFarm and "farm enabled" or "farm disabled")
end,
})
PetsSection:Dropdown({
Title = "Assignment Mode",
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
local worldValues = { "Current World" }
for _, worldName in ipairs(WorldOrder) do table.insert(worldValues, worldName) end
local zoneDropdown, lastZoneSignature
local TargetSection = PetsTab:Section({ Title = "Target Location", Box = true, Opened = true })
local function refreshZoneDropdown(force)
if not zoneDropdown then return end
local options, resolvedWorld = getZoneOptions(config.World)
local signature = config.World .. "|" .. tostring(resolvedWorld) .. "|" .. table.concat(options, "\0")
if not force and signature == lastZoneSignature then return end
local selected = config.Zone
local valid = false
for _, option in ipairs(options) do
if option == selected then valid = true; break end
end
if not valid then selected = config.World == "Current World" and "Player Zone" or options[1] end
lastZoneSignature = signature
zoneDropdown:Refresh(options)
if selected then
config.Zone = selected
pcall(function() zoneDropdown:Select(selected) end)
end
end
TargetSection:Dropdown({
Title = "World",
Desc = "Current World follows teleports and updates its zone list",
Values = worldValues,
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
local initialZones = getZoneOptions("Current World")
zoneDropdown = TargetSection:Dropdown({
Title = "Zone",
Desc = "Player Zone follows your character dynamically",
Values = initialZones,
Value = "Player Zone",
Multi = false,
AllowNone = false,
Callback = function(value)
if config.Zone == value then return end
config.Zone = value
if config.PetFarm then requestFarmReset("zone selection changed") end
end,
})
lastZoneSignature = "Current World|" .. tostring(getCurrentWorld()) .. "|" .. table.concat(initialZones, "\0")
local MonitorSection = PetsTab:Section({ Title = "Live Monitor", Box = true, Opened = true })
statusParagraph = MonitorSection:Paragraph({
Title = "Assignment Status",
Desc = "Waiting for the game pet controller and location data...",
})
healthParagraph = MonitorSection:Paragraph({
Title = "Controller Health",
Desc = "Runtime discovery is starting...",
})
local PerformanceSection = PetsTab:Section({ Title = "Farm Performance", Box = true, Opened = true })
PerformanceSection:Dropdown({
Title = "Tracked Currency",
Desc = "Auto follows the selected world; spending starts a fresh measurement session",
Values = CurrencyChoices,
Value = "Auto",
Multi = false,
AllowNone = false,
Callback = function(value)
if config.TrackedCurrency == value then return end
config.TrackedCurrency = value
table.clear(currencySamples)
setRate("Collecting a fresh currency sample...")
end,
})
rateParagraph = PerformanceSection:Paragraph({
Title = "Currency per Minute",
Desc = "Enable Pet Farm to measure the full farming session, including rare chest payouts.",
})
local LootSection = LootTab:Section({ Title = "Loot Magnet", Box = true, Opened = true })
LootSection:Paragraph({
Title = "Instant Collection",
Desc = "Pull nearby drops to your character while pet farming continues independently.",
})
LootSection:Toggle({
Title = "Collect Orbs",
Value = false,
Callback = function(value) config.Orbs = value == true end,
})
LootSection:Toggle({
Title = "Collect Lootbags",
Value = false,
Callback = function(value) config.Lootbags = value == true end,
})
local MiscSection = MiscTab:Section({ Title = "Session", Box = true, Opened = true })
MiscSection:Paragraph({
Title = "Session Protection",
Desc = "Keep the session active and stop every worker cleanly when you are done.",
})
MiscSection:Toggle({
Title = "Anti-AFK",
Desc = "Prevents the Roblox idle kick",
Value = true,
Callback = function(value) config.AntiAFK = value == true end,
})
local DiamondPackSection = MiscTab:Section({ Title = "Develop: Diamond Pack", Box = true, Opened = true })
DiamondPackSection:Toggle({
Title = "Auto Best Tech Diamond Pack",
Desc = "Every 3 minutes: buys tier 4 only at 1T+ Tech Coins; safely probes the server while truly underfunded",
Value = false,
Callback = function(value)
config.AutoTechDiamondPack = value == true
diamondPackNextCheck = 0
if config.AutoTechDiamondPack then
setDiamondPackStatus("Enabled. The first server check will run now.")
else
setDiamondPackStatus("Disabled. No purchase requests will be sent.")
end
end,
})
diamondPackParagraph = DiamondPackSection:Paragraph({
Title = "Diamond Pack Server Status",
Desc = "Auto tier 4 is disabled. Manual tier 3/2/1 tests below send one real server purchase request.",
})
for _, tier in ipairs({ 3, 2, 1 }) do
local selectedTier = tier
DiamondPackSection:Button({
Title = "Test Diamond Pack Tier " .. tostring(selectedTier),
Desc = "Sends one Buy DiamondPack request. If the balance is sufficient, this performs a real purchase.",
Callback = function()
task.spawn(function()
if not running() then return end
local ok, problem = pcall(runManualDiamondPackTest, selectedTier)
if not ok then
diamondPackBusy = false
local status = "Tier " .. tostring(selectedTier) .. " manual test | Worker error: " .. tostring(problem)
trace("diamond pack", status)
setDiamondPackStatus(status)
end
end)
end,
})
end
local RewardsSection = MiscTab:Section({ Title = "Develop: Auto Rewards", Box = true, Opened = true })
RewardsSection:Toggle({
Title = "Auto VIP Rewards",
Desc = "Runs one server probe immediately, then redeems automatically when the four-hour timer is ready",
Value = false,
Callback = function(value)
local enabled = value == true
config.AutoVIPRewards = enabled
local state = rewardStates.VIP
state.ProbePending = enabled
state.NextAttempt = 0
state.LastReply = nil
state.LastSucceeded = nil
setRewardLine("VIP", enabled and "Enabled; initial server probe pending..." or "Disabled.")
end,
})
RewardsSection:Toggle({
Title = "Auto Rank Rewards",
Desc = "Runs one server probe immediately, then follows the current rank reward cooldown",
Value = false,
Callback = function(value)
local enabled = value == true
config.AutoRankRewards = enabled
local state = rewardStates.Rank
state.ProbePending = enabled
state.NextAttempt = 0
state.LastReply = nil
state.LastSucceeded = nil
setRewardLine("Rank", enabled and "Enabled; initial server probe pending..." or "Disabled.")
end,
})
rewardParagraph = RewardsSection:Paragraph({
Title = "Reward Server Status",
Desc = "VIP: Disabled.\nRank: Disabled.",
})
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
MiscSection:Button({
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
setDiamondPackStatus(status .. "\nNext retry in 3 minutes.")
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
if state.ProbePending then
state.ProbePending = false
local succeeded = invokeReward(kind)
local _, cooldown = getRewardTiming(kind)
state.NextAttempt = now + (succeeded and (cooldown or REWARD_RETRY_DELAY) or REWARD_RETRY_DELAY)
else
local remaining, cooldown, timingError = getRewardTiming(kind)
if remaining == nil then
if timingError ~= "current rank has no rewards" and now >= state.NextAttempt then
local succeeded = invokeReward(kind)
state.NextAttempt = now + (succeeded and (cooldown or REWARD_RETRY_DELAY) or REWARD_RETRY_DELAY)
else
local prefix = state.LastReply and (state.LastReply .. " | ") or ""
setRewardLine(kind, prefix .. "Timer: " .. tostring(timingError))
end
elseif remaining > 0 then
local prefix = state.LastReply and (state.LastReply .. " | ") or ""
setRewardLine(kind, prefix .. "ready in " .. formatRewardTime(remaining))
elseif now >= state.NextAttempt then
local succeeded = invokeReward(kind)
state.NextAttempt = now + (succeeded and (cooldown or REWARD_RETRY_DELAY) or REWARD_RETRY_DELAY)
else
local prefix = state.LastReply and (state.LastReply .. " | ") or ""
local waitLabel = state.LastSucceeded and "next check in " or "retry in "
setRewardLine(kind, prefix .. waitLabel .. formatRewardTime(state.NextAttempt - now))
end
end
end
end
end
end)
task.spawn(function()
local activeCurrency, lastRateText = nil, nil
while task.wait(1) do
if not running() then break end
local currencyName = getTrackedCurrencyName()
if currencyName ~= activeCurrency then
activeCurrency = currencyName
table.clear(currencySamples)
end
local rateText
if not config.PetFarm then
table.clear(currencySamples)
rateText = currencyName .. "/min: farm disabled"
else
local currentAmount = getCurrentCurrency(currencyName)
if currentAmount == nil then
table.clear(currencySamples)
rateText = currencyName .. "/min: currency not found in player data"
else
local now = os.clock()
local previousValue = currencySamples.LastValue
if currencySamples.StartTime == nil
or previousValue == nil
or currentAmount < previousValue
then
table.clear(currencySamples)
currencySamples.StartTime = now
currencySamples.StartValue = currentAmount
elseif currentAmount > previousValue then
currencySamples.LastGainAt = now
currencySamples.LastGain = currentAmount - previousValue
end
currencySamples.LastValue = currentAmount
local elapsed = now - currencySamples.StartTime
local gained = math.max(0, currentAmount - currencySamples.StartValue)
if gained <= 0 then
rateText = string.format(
"%s/min: waiting for first payout...\nSession: %ds | balance: %s",
currencyName,
math.floor(elapsed + 0.5),
formatRateNumber(currentAmount)
)
else
local perMinute = (gained / elapsed) * 60
local sinceLastGain = currencySamples.LastGainAt
and math.max(0, now - currencySamples.LastGainAt)
or elapsed
rateText = string.format(
"%s/min: %s\nSession: +%s over %ds | last payout: %ds ago | balance: %s",
currencyName,
formatRateNumber(perMinute),
formatRateNumber(gained),
math.floor(elapsed + 0.5),
math.floor(sinceLastGain + 0.5),
formatRateNumber(currentAmount)
)
end
end
end
if rateText ~= lastRateText then
lastRateText = rateText
setRate(rateText)
end
end
end)
task.spawn(function()
while task.wait(0.4) do
if not running() then break end
refreshZoneDropdown(false)
local targets, world, zone = orderedTargets(config.Mode)
local equippedIds = getEquippedPetIds()
local equippedCount = #equippedIds
local assignedCount = assignmentCount()
local networkState = networkReady() and "ready" or "waiting"
local signalState = Library.Signal and type(Library.Signal.Fire) == "function" and "ready" or "waiting"
local controllerState = runtimeDriverReady and "linked" or signalState
local runtimeActive, runtimeIdle, runtimeMissing = runtimePetCounts(equippedIds)
local runtimeLine = runtimeActive ~= nil
and string.format("Runtime: %d active | %d ready | %d unseen", runtimeActive, runtimeIdle, runtimeMissing)
or "Runtime: discovering game pet state"
setStatus(string.format(
"%s  >  %s\nTargets: %d | reserved: %d/%d | local idle: %d\n%s",
tostring(world or "unknown"),
tostring(zone or "unknown"),
#targets,
assignedCount,
equippedCount,
math.max(equippedCount - assignedCount, 0),
runtimeLine
))
setHealth(string.format(
"Network: %s | pet controller: %s | allocator: %s\nRecoveries: %d | last: %s\nDriver: %s",
networkState,
controllerState,
farmResetRunning and "reconfiguring" or "stable",
idleRecoveryCount,
lastRecovery,
driverStatus
))
end
end)
pcall(function() PetsTab:Select() end)
trace("07 startup complete")
