local VERSION = "1.1.0"
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
Orbs = false,
Lootbags = false,
AntiAFK = true,
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
local WorldOrder = {
"Spawn World", "Fantasy World", "Tech World", "Axolotl Ocean",
"Pixel World", "Cat World", "The Void", "Doodle World",
"Kawaii World", "Dog World", "Diamond Mine", "Christmas Event", "Trading Plaza",
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
end
local pets = data.pets or data.Pets
if pets ~= nil then record.Pets = normalizePetSet(pets) end
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
end
coinRecords[id] = nil
peakHealth[id] = nil
end
local nextWorkspaceScanAt = 0
local function refreshWorkspaceCoins()
if os.clock() < nextWorkspaceScanAt then return end
nextWorkspaceScanAt = os.clock() + 0.1
local things = workspace:FindFirstChild("__THINGS")
local folder = things and things:FindFirstChild("Coins")
if not folder then return end
local seen = {}
for _, model in ipairs(folder:GetChildren()) do
local id = tostring(readObjectValue(model, "ID") or model.Name)
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
table.clear(boundsCache)
currentZone = nil
currentZoneAnchor = nil
nextZoneCheck = 0
cachedWorld = nil
nextWorldCheck = 0
nextWorkspaceScanAt = 0
nextSnapshotAt = 0
end))
end)
end
coinSignalsReady = true
end
local cachedPetIds = {}
local nextPetScanAt = 0
local function getEquippedPetIds()
if os.clock() < nextPetScanAt then return cachedPetIds end
nextPetScanAt = os.clock() + 0.2
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
return nil
end
local function recordInZone(record, zone, zoneAnchor)
if not recordAlive(record) or not zone then return false end
local normalizedName = normalize(record.Name)
local bossZone = BossChestZones[normalizedName]
if bossZone and namesMatch(bossZone, zone) then return true end
if zoneAnchor and record.Position and (record.Position - zoneAnchor).Magnitude <= 180 then return true end
if record.Area and namesMatch(record.Area, zone) then return true end
local detected = record.Position and areaForPosition(record.Position)
return detected ~= nil and namesMatch(detected, zone)
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
local farmWasEnabled = false
local driverStatus = "waiting for first target"
local controllerHandlers = {}
local nextControllerLookup = {}
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
if handler then controllerHandlers[signalName] = handler end
return handler
end
local function callPetController(signalName, model)
local handler = resolveControllerHandler(signalName)
if handler then
local ok, problem = pcall(handler, model)
if ok then
driverStatus = "game Pets handler"
return true
end
controllerHandlers[signalName] = nil
nextControllerLookup[signalName] = 0
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
local deadline = os.clock() + 0.75
repeat
RunService.Heartbeat:Wait()
until not running() or not config.PetFarm or coinPetRevision > revision or os.clock() >= deadline
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
local function clearAssignments(sendBack)
if sendBack then
local groups = {}
for petId, state in pairs(petStates) do
local ids = groups[state.CoinId]
if not ids then ids = {}; groups[state.CoinId] = ids end
table.insert(ids, tostring(petId))
end
task.spawn(function()
local network = networkReady()
if not network then return end
for coinId, petIds in pairs(groups) do
pcall(network.Invoke, "Leave Coin", tostring(coinId), petIds)
for _, petId in ipairs(petIds) do
pcall(network.Fire, "Change Pet Target", petId, "Player")
end
end
end)
end
table.clear(petStates)
table.clear(rejectedUntil)
end
local function dispatchPlan(record, petIds, groupMode)
if not recordAlive(record) or #petIds == 0 then return end
local model = getRecordModel(record)
if not model or not model:FindFirstChild("POS") then
driverStatus = "coin model/POS unavailable"
rejectedUntil[record.Id] = os.clock() + 0.4
return
end
local coinId = tostring(record.Id)
local stateTokens = {}
for _, petId in ipairs(petIds) do
local state = { CoinId = coinId, Phase = "pending", StartedAt = os.clock() }
petStates[petId] = state
stateTokens[petId] = state
end
local firedAny = false
if groupMode then
firedAny = callPetController("Group Select Coin", model)
else
for _, petId in ipairs(petIds) do
local state = stateTokens[petId]
if running() and config.PetFarm and recordAlive(record) and petStates[petId] == state then
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
rejectedUntil[coinId] = os.clock() + 0.4
end
end
local function syncServerAssignments(equipped)
local now = os.clock()
local authoritative = {}
for _, record in pairs(coinRecords) do
if recordAlive(record) then
for petId in pairs(record.Pets or {}) do
petId = tostring(petId)
if equipped[petId] then authoritative[petId] = tostring(record.Id) end
end
end
end
for petId, coinId in pairs(authoritative) do
local state = petStates[petId]
if not state or state.CoinId ~= coinId or state.Phase ~= "locked" then
petStates[petId] = { CoinId = coinId, Phase = "locked", ConfirmedAt = now }
else
state.ConfirmedAt = now
state.MissingSince = nil
end
end
for petId, state in pairs(petStates) do
local record = coinRecords[state.CoinId]
if not equipped[petId] or not recordAlive(record) then
petStates[petId] = nil
elseif not authoritative[petId] then
if state.Phase == "pending" then
if now - (state.StartedAt or now) > 1.25 then
petStates[petId] = nil
rejectedUntil[state.CoinId] = now + 0.35
end
else
state.MissingSince = state.MissingSince or now
if now - state.MissingSince > 0.75 then petStates[petId] = nil end
end
end
end
end
local function assignmentCount()
local count = 0
for _ in pairs(petStates) do count = count + 1 end
return count
end
local statusParagraph
local function setStatus(text)
if statusParagraph then pcall(function() statusParagraph:SetDesc(text) end) end
end
task.spawn(function()
while running() do
if os.clock() >= nextSnapshotAt and not snapshotBusy then task.spawn(refreshCoinSnapshot) end
connectCoinSignals()
if not config.PetFarm then
if farmWasEnabled then clearAssignments(true) end
farmWasEnabled = false
task.wait(0.1)
continue
end
farmWasEnabled = true
RunService.Heartbeat:Wait()
local petIds = getEquippedPetIds()
local equipped = {}
for _, petId in ipairs(petIds) do equipped[petId] = true end
syncServerAssignments(equipped)
local freePets = {}
for _, petId in ipairs(petIds) do
if not petStates[petId] then table.insert(freePets, petId) end
end
if #freePets == 0 then continue end
local targets = orderedTargets(config.Mode)
local usable = {}
for _, record in ipairs(targets) do
if os.clock() >= (rejectedUntil[record.Id] or 0) then table.insert(usable, record) end
end
if #usable == 0 then
task.wait(0.05)
continue
end
local plans = {}
if config.Mode == "All on Strongest Regular" or config.Mode == "Boss Chest Only" then
local groupTarget
for _, state in pairs(petStates) do
local record = coinRecords[state.CoinId]
local matchesMode = config.Mode == "Boss Chest Only" and isBossChest(record)
or config.Mode == "All on Strongest Regular" and not isBossChest(record)
if matchesMode and recordAlive(record) then
groupTarget = record
break
end
end
groupTarget = groupTarget or usable[1]
plans[groupTarget.Id] = { Record = groupTarget, Pets = freePets }
else
local claimed = {}
for _, state in pairs(petStates) do
if recordAlive(coinRecords[state.CoinId]) then claimed[state.CoinId] = true end
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
for _, plan in pairs(plans) do dispatchPlan(plan.Record, plan.Pets, groupMode) end
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
Name = "PSX Slim",
Accent = Color3.fromRGB(56, 189, 248),
Background = Color3.fromRGB(11, 18, 32),
Outline = Color3.fromRGB(125, 211, 252),
Text = Color3.fromRGB(248, 250, 252),
Placeholder = Color3.fromRGB(148, 163, 184),
Button = Color3.fromRGB(23, 36, 58),
Icon = Color3.fromRGB(186, 230, 253),
})
local Window = WindUI:CreateWindow({
Title = "PSX OG | Slim Farm",
Author = "Pet farm, loot and anti-AFK",
Folder = "PSX_Slim_Farm",
Size = UDim2.fromOffset(680, 470),
MinSize = Vector2.new(560, 380),
MaxSize = Vector2.new(980, 700),
ToggleKey = Enum.KeyCode.RightShift,
Transparent = true,
Theme = "PSX Slim",
Resizable = true,
SideBarWidth = 175,
HideSearchBar = true,
ScrollBarEnabled = true,
Acrylic = false,
})
local PetsTab = Window:Tab({ Title = "Pet Farm" })
local LootTab = Window:Tab({ Title = "Loot" })
local MiscTab = Window:Tab({ Title = "Misc" })
local PetsSection = PetsTab:Section({ Title = "Pet Farm", Box = true, Opened = true })
PetsSection:Toggle({
Title = "Enable Pet Farm",
Desc = "Targets are locked until the coin is completely destroyed",
Value = false,
Callback = function(value) config.PetFarm = value == true end,
})
PetsSection:Dropdown({
Title = "Assignment Mode",
Values = { "Different Strongest", "Different Weakest", "All on Strongest Regular", "Boss Chest Only" },
Value = "Different Strongest",
Multi = false,
AllowNone = false,
Callback = function(value) config.Mode = value end,
})
local worldValues = { "Current World" }
for _, worldName in ipairs(WorldOrder) do table.insert(worldValues, worldName) end
local zoneDropdown, lastZoneSignature
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
PetsSection:Dropdown({
Title = "World",
Desc = "Current World follows teleports and updates its zone list",
Values = worldValues,
Value = "Current World",
Multi = false,
AllowNone = false,
Callback = function(value)
config.World = value
refreshZoneDropdown(true)
end,
})
local initialZones = getZoneOptions("Current World")
zoneDropdown = PetsSection:Dropdown({
Title = "Zone",
Desc = "Player Zone follows your character dynamically",
Values = initialZones,
Value = "Player Zone",
Multi = false,
AllowNone = false,
Callback = function(value) config.Zone = value end,
})
lastZoneSignature = "Current World|" .. tostring(getCurrentWorld()) .. "|" .. table.concat(initialZones, "\0")
statusParagraph = PetsSection:Paragraph({
Title = "Farm Status",
Desc = "Waiting for the game pet controller and location data...",
})
local LootSection = LootTab:Section({ Title = "Loot Magnet", Box = true, Opened = true })
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
MiscSection:Toggle({
Title = "Anti-AFK",
Desc = "Prevents the Roblox idle kick",
Value = true,
Callback = function(value) config.AntiAFK = value == true end,
})
local function shutdown()
if not running() then return end
config.PetFarm = false
clearAssignments(true)
env.PSX_OG_SLIM_TOKEN = nil
disconnectAll()
if env.PSX_OG_SLIM_CLEANUP == shutdown then env.PSX_OG_SLIM_CLEANUP = nil end
if env.PSX_OG_UI_CLEANUP == shutdown then env.PSX_OG_UI_CLEANUP = nil end
pcall(function() Window:Destroy() end)
pcall(function() WindUI:Destroy() end)
end
env.PSX_OG_SLIM_CLEANUP = shutdown
env.PSX_OG_UI_CLEANUP = shutdown
MiscSection:Button({
Title = "STOP SCRIPT",
Desc = "Return pets, stop all workers and close the menu",
Callback = shutdown,
})
task.spawn(function()
while task.wait(0.4) do
if not running() then break end
refreshZoneDropdown(false)
local targets, world, zone = orderedTargets(config.Mode)
local equippedCount = #getEquippedPetIds()
local networkState = networkReady() and "ready" or "waiting"
local signalState = Library.Signal and type(Library.Signal.Fire) == "function" and "ready" or "waiting"
setStatus(string.format(
"World: %s | Zone: %s\nTargets: %d | pets: %d/%d | Network: %s | Select Coin: %s\nDriver: %s",
tostring(world or "unknown"),
tostring(zone or "unknown"),
#targets,
assignmentCount(),
equippedCount,
networkState,
signalState,
driverStatus
))
end
end)
pcall(function() PetsTab:Select() end)
trace("07 startup complete")
