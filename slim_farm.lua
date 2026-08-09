local VERSION = "1.4.1-dev.49-minimal.1"
local FLAVOR = "thin-eco.1"
local RUNTIME_MANIFEST = nil --[[__PSX_RUNTIME_MANIFEST__]]

local ENV = (type(getgenv) == "function" and getgenv()) or _G
local env = ENV
local function runtimeModuleCacheBuster(entry)
	return "?psxv=" .. tostring(entry.djb2)
end
env.PSX_OG_RUNTIME_MANIFEST = RUNTIME_MANIFEST
local PREFIX = "[PSX THIN]"

local function now()
	return os.clock()
end

local function log(stage, detail)
	local text = PREFIX .. " " .. tostring(stage)
	if detail ~= nil and detail ~= "" then
		text = text .. " | " .. tostring(detail)
	end
	print(text)
end

local function safeCall(fn, ...)
	if type(fn) ~= "function" then
		return false, "not a function"
	end
	return pcall(fn, ...)
end

local function disconnectAll(list)
	for i = #list, 1, -1 do
		local item = list[i]
		list[i] = nil
		if item then
			pcall(function()
				item:Disconnect()
			end)
		end
	end
end

if type(ENV.PSX_THIN_CLEANUP) == "function" then
	pcall(ENV.PSX_THIN_CLEANUP)
end
if type(ENV.PSX_OG_SLIM_CLEANUP) == "function" then
	pcall(ENV.PSX_OG_SLIM_CLEANUP)
end

ENV.PSX_OG_STOP_REQUESTED = true
ENV.PSX_OG_ACTIVE_GENERATION = (tonumber(ENV.PSX_OG_ACTIVE_GENERATION) or 0) + 1

local GEN = ENV.PSX_OG_ACTIVE_GENERATION
local Run = {
	Alive = true,
	Connections = {},
	Threads = {},
	UI = nil,
	Library = nil,
	Coins = {},
	Assignments = {},
	CoinCooldown = {},
	PendingOrbs = {},
	PendingBags = {},
	LastTargetScan = 0,
	LastPetScan = 0,
	EquippedPets = {},
	Config = {
		Farm = false,
		Orbs = false,
		Lootbags = false,
		AntiLag = true,
		ModeIndex = 1,
		ZoneIndex = 2,
		FpsCap = 90,
		OrbBatch = 64,
		BagBatch = 32,
	},
	Stats = {
		FarmSent = 0,
		FarmOk = 0,
		FarmFail = 0,
		OrbBatches = 0,
		OrbIds = 0,
		BagSent = 0,
		RouteHit = 0,
		RouteMiss = 0,
		LastError = "none",
		LastFarm = "idle",
	},
}

ENV.PSX_THIN = Run
ENV.PSX_THIN_CLEANUP = function()
	Run.Alive = false
	disconnectAll(Run.Connections)
	if Run.UI then
		pcall(function()
			Run.UI:Destroy()
		end)
		Run.UI = nil
	end
end

local function alive()
	return Run.Alive and ENV.PSX_OG_ACTIVE_GENERATION == GEN
end

local function trackConnection(conn)
	if conn then
		Run.Connections[#Run.Connections + 1] = conn
	end
	return conn
end

log("01 enter", VERSION .. " / " .. FLAVOR)

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")
local VirtualUser = game:GetService("VirtualUser")
local StatsService = game:GetService("Stats")
local LocalPlayer = Players.LocalPlayer

pcall(function()
	trackConnection(LocalPlayer.Idled:Connect(function()
		VirtualUser:Button2Down(Vector2.new(0, 0), workspace.CurrentCamera and workspace.CurrentCamera.CFrame or CFrame.new())
		task.wait(0.1)
		VirtualUser:Button2Up(Vector2.new(0, 0), workspace.CurrentCamera and workspace.CurrentCamera.CFrame or CFrame.new())
	end))
end)

local function rootPart()
	local character = LocalPlayer.Character
	if not character then
		return nil
	end
	return character:FindFirstChild("HumanoidRootPart")
end

local function setFpsCap(value)
	local cap = tonumber(value)
	if cap and cap > 0 and type(setfpscap) == "function" then
		pcall(setfpscap, math.floor(cap))
	end
end

setFpsCap(Run.Config.FpsCap)

local function requireLibrary()
	local framework = ReplicatedStorage:WaitForChild("Framework", 30)
	if not framework then
		return nil, "Framework missing"
	end
	local libModule = framework:WaitForChild("Library", 30)
	if not libModule then
		return nil, "Library missing"
	end
	local ok, lib = pcall(require, libModule)
	if not ok or type(lib) ~= "table" then
		return nil, lib
	end
	local deadline = now() + 30
	while alive() and lib.Loaded ~= true and now() < deadline do
		RunService.Heartbeat:Wait()
	end
	if lib.Loaded ~= true then
		return nil, "Library load timeout"
	end
	return lib, nil
end

local Library, libErr = requireLibrary()
if not Library then
	Run.Stats.LastError = "library: " .. tostring(libErr)
	log("02 library failed", libErr)
	return
end
Run.Library = Library
log("02 library ready", tostring(game.PlaceId))

local bit = bit32
local SHA256_K = {
	0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
	0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
	0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
	0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
	0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
	0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
	0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
	0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

local function rrotate(value, amount)
	return bit.rrotate(value, amount)
end

local function sha256(message)
	local bytes = { string.byte(message, 1, #message) }
	local bitLen = #bytes * 8
	bytes[#bytes + 1] = 0x80
	while (#bytes % 64) ~= 56 do
		bytes[#bytes + 1] = 0
	end
	local high = math.floor(bitLen / 4294967296)
	local low = bitLen % 4294967296
	for shift = 24, 0, -8 do
		bytes[#bytes + 1] = bit.band(bit.rshift(high, shift), 0xff)
	end
	for shift = 24, 0, -8 do
		bytes[#bytes + 1] = bit.band(bit.rshift(low, shift), 0xff)
	end

	local h0, h1, h2, h3 = 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a
	local h4, h5, h6, h7 = 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
	for chunk = 1, #bytes, 64 do
		local w = {}
		for i = 0, 15 do
			local j = chunk + i * 4
			w[i] = bit.bor(bit.lshift(bytes[j], 24), bit.lshift(bytes[j + 1], 16), bit.lshift(bytes[j + 2], 8), bytes[j + 3])
		end
		for i = 16, 63 do
			local s0 = bit.bxor(rrotate(w[i - 15], 7), rrotate(w[i - 15], 18), bit.rshift(w[i - 15], 3))
			local s1 = bit.bxor(rrotate(w[i - 2], 17), rrotate(w[i - 2], 19), bit.rshift(w[i - 2], 10))
			w[i] = (w[i - 16] + s0 + w[i - 7] + s1) % 4294967296
		end
		local a, b, c, d = h0, h1, h2, h3
		local e, f, g, h = h4, h5, h6, h7
		for i = 0, 63 do
			local s1 = bit.bxor(rrotate(e, 6), rrotate(e, 11), rrotate(e, 25))
			local ch = bit.bxor(bit.band(e, f), bit.band(bit.bnot(e), g))
			local temp1 = (h + s1 + ch + SHA256_K[i + 1] + w[i]) % 4294967296
			local s0 = bit.bxor(rrotate(a, 2), rrotate(a, 13), rrotate(a, 22))
			local maj = bit.bxor(bit.band(a, b), bit.band(a, c), bit.band(b, c))
			local temp2 = (s0 + maj) % 4294967296
			h = g
			g = f
			f = e
			e = (d + temp1) % 4294967296
			d = c
			c = b
			b = a
			a = (temp1 + temp2) % 4294967296
		end
		h0 = (h0 + a) % 4294967296
		h1 = (h1 + b) % 4294967296
		h2 = (h2 + c) % 4294967296
		h3 = (h3 + d) % 4294967296
		h4 = (h4 + e) % 4294967296
		h5 = (h5 + f) % 4294967296
		h6 = (h6 + g) % 4294967296
		h7 = (h7 + h) % 4294967296
	end
	return string.format("%08x%08x%08x%08x%08x%08x%08x%08x", h0, h1, h2, h3, h4, h5, h6, h7)
end

local function routeHash(kind, command)
	local job = game.JobId or ""
	local seed = "duskissexyyyyy123iloveudUsk/Network4/"
		.. tostring(game.GameId) .. "/" .. tostring(game.PlaceId) .. "/" .. tostring(game.PlaceVersion)
		.. "/" .. tostring(job) .. "/" .. tostring(kind) .. "/" .. tostring(command)
	return string.sub(sha256(seed), 5, 36)
end

local Net = {
	EventCache = {},
	FunctionCache = {},
	Aliases = {
		["Join Coin"] = { "Join The Coin", "Join Coin" },
		["Farm Coin"] = { "Farm The Coin", "Farm Coin" },
		["Change Pet Target"] = { "Change Pet Target NOW", "Change Pet Target" },
		["Leave Coin"] = { "Leave The Coin", "Leave Coin" },
		["Claim Orbs"] = { "Claim Orbs" },
		["Collect Lootbag"] = { "Collect Lootbag" },
		["Get Coins"] = { "Get Coins" },
		["Buy Egg"] = { "Buy Egg Yay", "Buy Egg" },
	},
}

local function aliasList(command)
	return Net.Aliases[command] or { command }
end

local function validRemote(instance, kind)
	if kind == 1 then
		return typeof(instance) == "Instance" and instance:IsA("RemoteEvent")
	end
	return typeof(instance) == "Instance" and instance:IsA("RemoteFunction")
end

local function resolveRemote(kind, command)
	local cache = kind == 1 and Net.EventCache or Net.FunctionCache
	local cached = cache[command]
	if validRemote(cached, kind) then
		return cached, command
	end
	for _, name in ipairs(aliasList(command)) do
		local hash = routeHash(kind, name)
		local remote = ReplicatedStorage:FindFirstChild(hash)
		if validRemote(remote, kind) then
			cache[command] = remote
			Run.Stats.RouteHit += 1
			return remote, name
		end
	end
	Run.Stats.RouteMiss += 1
	return nil, nil
end

function Net:fire(command, ...)
	local remote, routed = resolveRemote(1, command)
	if remote then
		local ok, err = pcall(function(...)
			remote:FireServer(...)
		end, ...)
		if ok then
			return true, nil, "remote:" .. tostring(routed)
		end
		Run.Stats.LastError = "fire " .. tostring(command) .. ": " .. tostring(err)
		self.EventCache[command] = nil
	end
	local network = Library.Network
	if network and type(network.Fire) == "function" then
		for _, name in ipairs(aliasList(command)) do
			local ok, err = pcall(network.Fire, name, ...)
			if ok then
				return true, nil, "named:" .. tostring(name)
			end
			Run.Stats.LastError = "named fire " .. tostring(name) .. ": " .. tostring(err)
		end
	end
	return false, Run.Stats.LastError, "none"
end

function Net:invoke(command, ...)
	local remote, routed = resolveRemote(2, command)
	if remote then
		local packed = table.pack(pcall(function(...)
			return remote:InvokeServer(...)
		end, ...))
		if packed[1] then
			return true, packed[2], "remote:" .. tostring(routed)
		end
		Run.Stats.LastError = "invoke " .. tostring(command) .. ": " .. tostring(packed[2])
		self.FunctionCache[command] = nil
	end
	local network = Library.Network
	if network and type(network.Invoke) == "function" then
		for _, name in ipairs(aliasList(command)) do
			local packed = table.pack(pcall(network.Invoke, name, ...))
			if packed[1] then
				return true, packed[2], "named:" .. tostring(name)
			end
			Run.Stats.LastError = "named invoke " .. tostring(name) .. ": " .. tostring(packed[2])
		end
	end
	return false, nil, Run.Stats.LastError
end

function Net:fired(command, callback)
	local remote = resolveRemote(1, command)
	if remote and remote.OnClientEvent then
		return remote.OnClientEvent:Connect(callback)
	end
	local fired = Library.Network and Library.Network.Fired
	if type(fired) == "function" then
		for _, name in ipairs(aliasList(command)) do
			local ok, signal = pcall(fired, name)
			if ok and signal and type(signal.Connect) == "function" then
				return signal:Connect(callback)
			end
		end
	end
	return nil
end

local Zones = {
	"Player Zone",
	"Pixel Vault",
	"Pixel Alps",
	"Pixel Forest",
	"Hacker Portal",
	"Axolotl Cave",
	"Axolotl Ocean",
	"Alien Forest",
	"Alien Lab",
	"Steampunk Chest",
	"Giant Alien Chest",
	"All",
}

local Modes = {
	"Boss Chest Only",
	"Different Strongest",
	"All on Strongest",
}

local BossHints = {
	["pixel vault"] = { "pixel vault", "giant pixel", "pixel chest", "pixel vault chest" },
	["hacker portal"] = { "hacker portal", "hacker chest", "giant hacker", "portal chest" },
	["axolotl cave"] = { "axolotl cave", "giant axolotl", "axolotl chest" },
	["axolotl ocean"] = { "axolotl ocean", "axolotl chest" },
	["steampunk chest"] = { "steampunk chest", "giant steampunk" },
	["giant alien chest"] = { "giant alien chest", "alien chest" },
}

local function cleanName(value)
	local text = tostring(value or ""):lower()
	text = text:gsub("[_%-%p]+", " "):gsub("%s+", " ")
	return text:match("^%s*(.-)%s*$") or text
end

local function textHas(text, part)
	return string.find(cleanName(text), cleanName(part), 1, true) ~= nil
end

local function getSave()
	if Library.Save and type(Library.Save.Get) == "function" then
		local ok, save = pcall(Library.Save.Get)
		if ok and type(save) == "table" then
			return save
		end
	end
	return nil
end

local function numberFrom(value)
	if typeof(value) == "NumberRange" then
		return value.Max
	end
	local n = tonumber(value)
	if n then
		return n
	end
	return nil
end

local function modelPosition(instance)
	if typeof(instance) ~= "Instance" then
		return nil
	end
	if instance:IsA("BasePart") then
		return instance.Position
	end
	if instance:IsA("Model") then
		local pivotOk, pivot = pcall(function()
			return instance:GetPivot()
		end)
		if pivotOk and typeof(pivot) == "CFrame" then
			return pivot.Position
		end
		local primary = instance.PrimaryPart or instance:FindFirstChildWhichIsA("BasePart", true)
		if primary then
			return primary.Position
		end
	end
	return nil
end

local function dataPosition(data, instance)
	if typeof(data) == "Vector3" then
		return data
	end
	if typeof(data) == "CFrame" then
		return data.Position
	end
	if type(data) == "table" then
		for _, key in ipairs({ "p", "pos", "position", "Position" }) do
			local value = data[key]
			if typeof(value) == "Vector3" then
				return value
			end
			if typeof(value) == "CFrame" then
				return value.Position
			end
		end
	end
	return modelPosition(instance)
end

local function dataField(data, keys)
	if type(data) ~= "table" then
		return nil
	end
	for _, key in ipairs(keys) do
		local value = data[key]
		if value ~= nil then
			return value
		end
	end
	return nil
end

local function getCoinsFolder()
	local things = workspace:FindFirstChild("__THINGS")
	return things and things:FindFirstChild("Coins") or nil
end

local function getOrbsFolder()
	local things = workspace:FindFirstChild("__THINGS")
	return things and things:FindFirstChild("Orbs") or nil
end

local function getLootbagsFolder()
	local things = workspace:FindFirstChild("__THINGS")
	return things and (things:FindFirstChild("Lootbags") or things:FindFirstChild("Loot Bags")) or nil
end

local isBoss
local AreaCache = { At = 0, Entries = {} }

local function areaBounds(area)
	if typeof(area) ~= "Instance" then
		return nil, nil
	end
	if area:IsA("BasePart") then
		return area.CFrame, area.Size
	end
	if area:IsA("Model") then
		local ok, cf, size = pcall(function()
			return area:GetBoundingBox()
		end)
		if ok and cf and size then
			return cf, size
		end
	end
	local low, high = nil, nil
	for _, part in ipairs(area:GetDescendants()) do
		if part:IsA("BasePart") then
			local half = part.Size / 2
			local a = part.Position - half
			local b = part.Position + half
			low = low and Vector3.new(math.min(low.X, a.X), math.min(low.Y, a.Y), math.min(low.Z, a.Z)) or a
			high = high and Vector3.new(math.max(high.X, b.X), math.max(high.Y, b.Y), math.max(high.Z, b.Z)) or b
		end
	end
	if low and high then
		return CFrame.new((low + high) / 2), high - low
	end
	return nil, nil
end

local function areaEntries()
	if now() - AreaCache.At < 5 and #AreaCache.Entries > 0 then
		return AreaCache.Entries
	end
	AreaCache.At = now()
	table.clear(AreaCache.Entries)
	local map = workspace:FindFirstChild("__MAP")
	local areas = map and map:FindFirstChild("Areas")
	if not areas then
		return AreaCache.Entries
	end
	for _, area in ipairs(areas:GetChildren()) do
		local cf, size = areaBounds(area)
		if cf and size then
			AreaCache.Entries[#AreaCache.Entries + 1] = {
				Name = area.Name,
				CFrame = cf,
				Size = size,
				Volume = math.max(size.X, 1) * math.max(size.Z, 1),
			}
		end
	end
	return AreaCache.Entries
end

local function areaForPosition(position)
	if typeof(position) ~= "Vector3" then
		return nil
	end
	local bestInside, bestVolume = nil, math.huge
	local bestNear, bestDistance = nil, math.huge
	for _, entry in ipairs(areaEntries()) do
		local point = entry.CFrame:PointToObjectSpace(position)
		local half = entry.Size / 2 + Vector3.new(10, 35, 10)
		if math.abs(point.X) <= half.X and math.abs(point.Y) <= half.Y and math.abs(point.Z) <= half.Z then
			if entry.Volume < bestVolume then
				bestInside = entry.Name
				bestVolume = entry.Volume
			end
		end
		local distance = (entry.CFrame.Position - position).Magnitude
		if distance < bestDistance then
			bestNear = entry.Name
			bestDistance = distance
		end
	end
	return bestInside or bestNear
end

local function zoneAnchor(zone)
	for _, record in pairs(Run.Coins) do
		if record.Position and isBoss(record, zone) then
			return record.Position
		end
	end
	for _, entry in ipairs(areaEntries()) do
		if textHas(entry.Name, zone) then
			return entry.CFrame.Position
		end
	end
	return nil
end

local function rememberCoin(id, data, instance)
	if id == nil then
		return
	end
	local coinId = tostring(id)
	local record = Run.Coins[coinId] or { Id = coinId }
	record.Instance = instance or record.Instance
	record.Name = tostring(dataField(data, { "n", "name", "Name", "coin", "Coin" }) or (instance and instance.Name) or record.Name or coinId)
	record.Area = tostring(dataField(data, { "a", "area", "Area", "zone", "Zone" }) or record.Area or "")
	record.World = tostring(dataField(data, { "w", "world", "World" }) or record.World or "")
	record.Health = numberFrom(dataField(data, { "h", "health", "Health" })) or record.Health
	record.MaxHealth = numberFrom(dataField(data, { "mh", "maxHealth", "MaxHealth", "m" })) or record.MaxHealth or record.Health or 1
	record.Position = dataPosition(data, instance) or record.Position
	if record.Position and (not record.Area or record.Area == "") then
		record.Area = areaForPosition(record.Position) or record.Area
	end
	record.UpdatedAt = now()
	record.Alive = true
	Run.Coins[coinId] = record
	return record
end

local function forgetCoin(id)
	local coinId = tostring(id)
	Run.Coins[coinId] = nil
	Run.CoinCooldown[coinId] = now() + 1
	for petId, assignment in pairs(Run.Assignments) do
		if assignment.CoinId == coinId then
			Run.Assignments[petId] = nil
		end
	end
end

local function scanCoinFolder()
	local folder = getCoinsFolder()
	if not folder then
		return
	end
	for _, child in ipairs(folder:GetChildren()) do
		rememberCoin(child.Name, nil, child)
	end
end

local function pullCoinSnapshot()
	local ok, result = Net:invoke("Get Coins")
	if not ok or type(result) ~= "table" then
		return
	end
	for id, data in pairs(result) do
		rememberCoin(id, data, nil)
	end
end

function isBoss(record, selectedZone)
	local blob = cleanName((record.Name or "") .. " " .. (record.Area or "") .. " " .. (record.World or "") .. " " .. tostring(record.Id))
	local zone = cleanName(selectedZone)
	local hints = BossHints[zone]
	if hints then
		for _, hint in ipairs(hints) do
			if string.find(blob, cleanName(hint), 1, true) then
				return true
			end
		end
	end
	return string.find(blob, "chest", 1, true) ~= nil or string.find(blob, "vault", 1, true) ~= nil or string.find(blob, "portal", 1, true) ~= nil
end

local function currentZone()
	return Zones[Run.Config.ZoneIndex] or "Player Zone"
end

local function currentMode()
	return Modes[Run.Config.ModeIndex] or "Boss Chest Only"
end

local function selectedZoneAccepts(record)
	local zone = currentZone()
	if zone == "All" then
		return true
	end
	if zone == "Player Zone" then
		local hrp = rootPart()
		if not hrp or not record.Position then
			return true
		end
		return (hrp.Position - record.Position).Magnitude <= 650
	end
	local blob = (record.Name or "") .. " " .. (record.Area or "") .. " " .. (record.World or "")
	if textHas(blob, zone) then
		return true
	end
	if isBoss(record, zone) then
		return true
	end
	if record.Position then
		local detected = areaForPosition(record.Position)
		if detected and textHas(detected, zone) then
			record.Area = detected
			return true
		end
		local anchor = zoneAnchor(zone)
		if anchor and (record.Position - anchor).Magnitude <= 260 then
			return true
		end
	end
	return false
end

local function validTarget(record)
	if not record or record.Alive == false then
		return false
	end
	if Run.CoinCooldown[record.Id] and Run.CoinCooldown[record.Id] > now() then
		return false
	end
	if record.Instance and typeof(record.Instance) == "Instance" and not record.Instance:IsDescendantOf(workspace) then
		return false
	end
	return selectedZoneAccepts(record)
end

local function targetList()
	if now() - Run.LastTargetScan > 2 then
		Run.LastTargetScan = now()
		scanCoinFolder()
		if next(Run.Coins) == nil then
			pullCoinSnapshot()
		end
	end
	local list = {}
	local mode = currentMode()
	local zone = currentZone()
	for _, record in pairs(Run.Coins) do
		if validTarget(record) then
			local boss = isBoss(record, zone)
			if mode ~= "Boss Chest Only" or boss then
				list[#list + 1] = record
			end
		end
	end
	if #list == 0 and now() - (Run.LastSnapshotPull or 0) > 4 then
		Run.LastSnapshotPull = now()
		pullCoinSnapshot()
	end
	if #list == 0 and mode == "Boss Chest Only" then
		for _, record in pairs(Run.Coins) do
			if validTarget(record) then
				list[#list + 1] = record
			end
		end
	end
	table.sort(list, function(a, b)
		return (a.MaxHealth or a.Health or 0) > (b.MaxHealth or b.Health or 0)
	end)
	return list
end

local function refreshPets(force)
	if not force and now() - Run.LastPetScan < 0.75 then
		return Run.EquippedPets
	end
	Run.LastPetScan = now()
	local save = getSave()
	local pets = {}
	if save and type(save.Pets) == "table" then
		for _, pet in pairs(save.Pets) do
			if type(pet) == "table" and (pet.e == true or pet.equipped == true or pet.Equipped == true) then
				local uid = pet.uid or pet.id or pet.UID
				if uid ~= nil then
					pets[#pets + 1] = tostring(uid)
				end
			end
		end
	end
	Run.EquippedPets = pets
	return pets
end

local function assignmentAlive(petId)
	local assignment = Run.Assignments[petId]
	if not assignment then
		return false
	end
	local record = Run.Coins[assignment.CoinId]
	if not validTarget(record) then
		Run.Assignments[petId] = nil
		return false
	end
	return true
end

local function freePets()
	local pets = refreshPets(false)
	local result = {}
	for _, petId in ipairs(pets) do
		if not assignmentAlive(petId) then
			result[#result + 1] = petId
		end
	end
	return result
end

local function acceptJoin(value)
	if value == false then
		return false
	end
	return true
end

local function dispatchGroup(coinId, pets)
	if #pets == 0 or not coinId then
		return
	end
	Run.Stats.FarmSent += 1
	local ok, result, route = Net:invoke("Join Coin", coinId, pets)
	if not ok or not acceptJoin(result) then
		Run.Stats.FarmFail += 1
		Run.CoinCooldown[tostring(coinId)] = now() + 0.75
		Run.Stats.LastFarm = "join rejected " .. tostring(coinId)
		return
	end
	Run.Stats.FarmOk += 1
	Run.Stats.LastFarm = "joined " .. tostring(coinId) .. " x" .. tostring(#pets) .. " " .. tostring(route)
	for _, petId in ipairs(pets) do
		Run.Assignments[petId] = { CoinId = tostring(coinId), At = now() }
		Net:fire("Change Pet Target", petId, coinId)
		Net:fire("Farm Coin", coinId, petId)
	end
end

local function dispatchFarm()
	if not Run.Config.Farm or Run.Dispatching then
		return
	end
	Run.Dispatching = true
	task.spawn(function()
		local ok, err = pcall(function()
			local pets = freePets()
			local targets = targetList()
			if #pets == 0 or #targets == 0 then
				if #targets == 0 then
					Run.Stats.LastFarm = "no targets"
				end
				return
			end
			local mode = currentMode()
			if mode == "All on Strongest" or mode == "Boss Chest Only" then
				dispatchGroup(targets[1].Id, pets)
				return
			end
			local groups = {}
			for i, petId in ipairs(pets) do
				local target = targets[((i - 1) % #targets) + 1]
				local group = groups[target.Id]
				if not group then
					group = {}
					groups[target.Id] = group
				end
				group[#group + 1] = petId
			end
			for coinId, group in pairs(groups) do
				dispatchGroup(coinId, group)
				task.wait(0.03)
			end
		end)
		if not ok then
			Run.Stats.LastError = "farm dispatch: " .. tostring(err)
		end
		Run.Dispatching = false
	end)
end

local function stopFarmAssignments()
	for coinId in pairs(Run.Coins) do
		Net:fire("Leave Coin", coinId)
	end
	table.clear(Run.Assignments)
end

local function collectOrbId(id)
	if id ~= nil then
		Run.PendingOrbs[tostring(id)] = true
	end
end

local function collectBag(instance)
	if typeof(instance) == "Instance" then
		Run.PendingBags[instance] = true
	end
end

local function bindCoinSignals()
	trackConnection(Net:fired("New Coin", function(id, data)
		rememberCoin(id, data, nil)
		dispatchFarm()
	end))
	trackConnection(Net:fired("Update Coin Health", function(id, health)
		local record = Run.Coins[tostring(id)]
		if record then
			record.Health = numberFrom(health) or record.Health
			record.UpdatedAt = now()
			if record.Health and record.Health <= 0 then
				forgetCoin(id)
				dispatchFarm()
			end
		end
	end))
	trackConnection(Net:fired("Remove Coin", function(id)
		forgetCoin(id)
		dispatchFarm()
	end))
	local folder = getCoinsFolder()
	if folder then
		trackConnection(folder.ChildAdded:Connect(function(child)
			rememberCoin(child.Name, nil, child)
			dispatchFarm()
		end))
		trackConnection(folder.ChildRemoved:Connect(function(child)
			forgetCoin(child.Name)
			dispatchFarm()
		end))
	end
end

local function bindLootSignals()
	local orbFolder = getOrbsFolder()
	if orbFolder then
		for _, child in ipairs(orbFolder:GetChildren()) do
			collectOrbId(child.Name)
		end
		trackConnection(orbFolder.ChildAdded:Connect(function(child)
			collectOrbId(child.Name)
		end))
	end
	trackConnection(Net:fired("Orb Added", function(id)
		collectOrbId(id)
	end))
	local bagFolder = getLootbagsFolder()
	if bagFolder then
		for _, child in ipairs(bagFolder:GetChildren()) do
			collectBag(child)
		end
		trackConnection(bagFolder.ChildAdded:Connect(function(child)
			collectBag(child)
		end))
	end
	trackConnection(Net:fired("Spawn Lootbag", function(id)
		collectBag(id)
	end))
end

local function flushOrbs()
	if not Run.Config.Orbs then
		return
	end
	local folder = getOrbsFolder()
	if folder and next(Run.PendingOrbs) == nil then
		for _, child in ipairs(folder:GetChildren()) do
			collectOrbId(child.Name)
		end
	end
	local ids = {}
	for id in pairs(Run.PendingOrbs) do
		ids[#ids + 1] = tonumber(id) or id
		Run.PendingOrbs[id] = nil
		if #ids >= Run.Config.OrbBatch then
			break
		end
	end
	if #ids > 0 then
		Net:fire("Claim Orbs", ids)
		Run.Stats.OrbBatches += 1
		Run.Stats.OrbIds += #ids
		if folder then
			for _, id in ipairs(ids) do
				local child = folder:FindFirstChild(tostring(id))
				if child then
					pcall(function()
						child:Destroy()
					end)
				end
			end
		end
	end
end

local LootCollectFn = false
local function getLootCollect()
	if LootCollectFn ~= false then
		return LootCollectFn
	end
	LootCollectFn = nil
	if type(getsenv) == "function" then
		local scripts = LocalPlayer:FindFirstChild("PlayerScripts")
		scripts = scripts and scripts:FindFirstChild("Scripts")
		scripts = scripts and scripts:FindFirstChild("Game")
		if scripts then
			for _, child in ipairs(scripts:GetChildren()) do
				if textHas(child.Name, "loot") then
					local ok, env = pcall(getsenv, child)
					if ok and type(env) == "table" and type(env.Collect) == "function" then
						LootCollectFn = env.Collect
						return LootCollectFn
					end
				end
			end
		end
	end
	return nil
end

local function flushBags()
	if not Run.Config.Lootbags then
		return
	end
	local folder = getLootbagsFolder()
	if folder and next(Run.PendingBags) == nil then
		for _, child in ipairs(folder:GetChildren()) do
			collectBag(child)
		end
	end
	local sent = 0
	local collect = getLootCollect()
	for bag in pairs(Run.PendingBags) do
		Run.PendingBags[bag] = nil
		if typeof(bag) == "Instance" and bag:IsDescendantOf(workspace) then
			local pos = modelPosition(bag)
			if collect then
				pcall(collect, bag)
			else
				Net:fire("Collect Lootbag", bag.Name, pos)
			end
			pcall(function()
				bag:Destroy()
			end)
			sent += 1
			Run.Stats.BagSent += 1
			if sent >= Run.Config.BagBatch then
				break
			end
		end
	end
end

local function muteInstance(instance)
	if typeof(instance) ~= "Instance" then
		return
	end
	pcall(function()
		if instance:IsA("ParticleEmitter") or instance:IsA("Trail") or instance:IsA("Beam") or instance:IsA("Smoke") or instance:IsA("Fire") or instance:IsA("Sparkles") then
			instance.Enabled = false
		elseif instance:IsA("MeshPart") then
			instance.TextureID = ""
			instance.CastShadow = false
			instance.Material = Enum.Material.SmoothPlastic
			instance.Reflectance = 0
		elseif instance:IsA("BasePart") then
			instance.CastShadow = false
			instance.Material = Enum.Material.SmoothPlastic
			instance.Reflectance = 0
		elseif instance:IsA("Decal") or instance:IsA("Texture") then
			instance.Transparency = 1
		end
	end)
end

local function applyAntiLag()
	if not Run.Config.AntiLag then
		return
	end
	pcall(function()
		Lighting.GlobalShadows = false
		Lighting.FogEnd = 100000
	end)
	local roots = {
		workspace:FindFirstChild("__DEBRIS"),
		workspace:FindFirstChild("__THINGS"),
		workspace:FindFirstChild("__MAP"),
	}
	local processed = 0
	for _, root in ipairs(roots) do
		if root then
			for _, obj in ipairs(root:GetDescendants()) do
				muteInstance(obj)
				processed += 1
				if processed % 350 == 0 then
					task.wait()
					if not alive() then
						return
					end
				end
			end
		end
	end
	log("03 antilag pass", processed)
end

local function makeButton(parent, text, y, callback)
	local button = Instance.new("TextButton")
	button.BackgroundColor3 = Color3.fromRGB(24, 35, 42)
	button.BorderSizePixel = 0
	button.Position = UDim2.new(0, 10, 0, y)
	button.Size = UDim2.new(0, 250, 0, 28)
	button.Font = Enum.Font.GothamMedium
	button.TextColor3 = Color3.fromRGB(225, 245, 245)
	button.TextSize = 13
	button.TextXAlignment = Enum.TextXAlignment.Left
	button.Text = "  " .. text
	button.Parent = parent
	Instance.new("UICorner", button).CornerRadius = UDim.new(0, 8)
	trackConnection(button.MouseButton1Click:Connect(callback))
	return button
end

local function pingText()
	local ok, value = pcall(function()
		local net = StatsService.Network.ServerStatsItem["Data Ping"]
		return math.floor(net:GetValue())
	end)
	if ok then
		return tostring(value) .. "ms"
	end
	return "n/a"
end

local UI = {}
local function refreshUi()
	if not UI.Status then
		return
	end
	UI.Farm.Text = "  Farm: " .. (Run.Config.Farm and "ON" or "OFF")
	UI.Orbs.Text = "  Orbs: " .. (Run.Config.Orbs and "ON" or "OFF") .. " / batch " .. tostring(Run.Config.OrbBatch)
	UI.Bags.Text = "  Lootbags: " .. (Run.Config.Lootbags and "ON" or "OFF")
	UI.Mode.Text = "  Mode: " .. currentMode()
	UI.Zone.Text = "  Zone: " .. currentZone()
	local locked = 0
	for _ in pairs(Run.Assignments) do
		locked += 1
	end
	local targetCount = 0
	for _, record in pairs(Run.Coins) do
		if validTarget(record) then
			targetCount += 1
		end
	end
	UI.Status.Text = "ping " .. pingText()
		.. " | pets " .. tostring(locked) .. "/" .. tostring(#refreshPets(false))
		.. " | targets " .. tostring(targetCount) .. "/" .. tostring(#Run.Coins)
		.. "\nfarm ok/fail " .. tostring(Run.Stats.FarmOk) .. "/" .. tostring(Run.Stats.FarmFail)
		.. " | orbs " .. tostring(Run.Stats.OrbIds) .. " in " .. tostring(Run.Stats.OrbBatches)
		.. " | bags " .. tostring(Run.Stats.BagSent)
		.. "\nlast: " .. tostring(Run.Stats.LastFarm)
		.. "\nerr: " .. tostring(Run.Stats.LastError)
end

local function createUi()
	local gui = Instance.new("ScreenGui")
	gui.Name = "PSX_THIN_ECO"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	local parent = game:GetService("CoreGui")
	pcall(function()
		gui.Parent = parent
	end)
	if not gui.Parent then
		gui.Parent = LocalPlayer:WaitForChild("PlayerGui", 10) or LocalPlayer
	end

	local frame = Instance.new("Frame")
	frame.BackgroundColor3 = Color3.fromRGB(10, 18, 23)
	frame.BackgroundTransparency = 0.08
	frame.BorderSizePixel = 0
	frame.Position = UDim2.new(0, 20, 0, 120)
	frame.Size = UDim2.new(0, 270, 0, 318)
	frame.Parent = gui
	Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 12)

	local title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.Position = UDim2.new(0, 10, 0, 8)
	title.Size = UDim2.new(0, 250, 0, 36)
	title.Font = Enum.Font.GothamBold
	title.TextColor3 = Color3.fromRGB(78, 255, 232)
	title.TextSize = 14
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Text = "PSX THIN ECO\n" .. FLAVOR
	title.Parent = frame

	UI.Farm = makeButton(frame, "Farm: OFF", 50, function()
		Run.Config.Farm = not Run.Config.Farm
		if Run.Config.Farm then
			pullCoinSnapshot()
			dispatchFarm()
		else
			stopFarmAssignments()
		end
		refreshUi()
	end)
	UI.Mode = makeButton(frame, "Mode", 84, function()
		Run.Config.ModeIndex = (Run.Config.ModeIndex % #Modes) + 1
		table.clear(Run.Assignments)
		dispatchFarm()
		refreshUi()
	end)
	UI.Zone = makeButton(frame, "Zone", 118, function()
		Run.Config.ZoneIndex = (Run.Config.ZoneIndex % #Zones) + 1
		table.clear(Run.Assignments)
		dispatchFarm()
		refreshUi()
	end)
	UI.Orbs = makeButton(frame, "Orbs: OFF", 152, function()
		Run.Config.Orbs = not Run.Config.Orbs
		refreshUi()
	end)
	UI.Bags = makeButton(frame, "Lootbags: OFF", 186, function()
		Run.Config.Lootbags = not Run.Config.Lootbags
		refreshUi()
	end)

	UI.Status = Instance.new("TextLabel")
	UI.Status.BackgroundColor3 = Color3.fromRGB(16, 27, 34)
	UI.Status.BorderSizePixel = 0
	UI.Status.Position = UDim2.new(0, 10, 0, 220)
	UI.Status.Size = UDim2.new(0, 250, 0, 88)
	UI.Status.Font = Enum.Font.Code
	UI.Status.TextColor3 = Color3.fromRGB(210, 240, 240)
	UI.Status.TextSize = 10
	UI.Status.TextXAlignment = Enum.TextXAlignment.Left
	UI.Status.TextYAlignment = Enum.TextYAlignment.Top
	UI.Status.TextWrapped = true
	UI.Status.Parent = frame
	Instance.new("UICorner", UI.Status).CornerRadius = UDim.new(0, 8)

	local dragging = false
	local dragStart = nil
	local startPos = nil
	trackConnection(frame.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			dragStart = input.Position
			startPos = frame.Position
		end
	end))
	trackConnection(frame.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end))
	trackConnection(game:GetService("UserInputService").InputChanged:Connect(function(input)
		if dragging and dragStart and startPos and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			local delta = input.Position - dragStart
			frame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
		end
	end))
	Run.UI = gui
	refreshUi()
end

createUi()
log("04 ui ready", "manual toggles only")

bindCoinSignals()
bindLootSignals()
scanCoinFolder()
task.spawn(applyAntiLag)

task.spawn(function()
	while alive() do
		if Run.Config.Farm then
			dispatchFarm()
		end
		task.wait(0.25)
	end
end)

task.spawn(function()
	while alive() do
		flushOrbs()
		flushBags()
		task.wait(0.65)
	end
end)

task.spawn(function()
	while alive() do
		refreshUi()
		task.wait(1)
	end
end)

log("05 ready", "farm disabled; enable in THIN panel")
