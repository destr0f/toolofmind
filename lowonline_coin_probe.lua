-- LowOnline coin catalog probe.
-- Read-only: no remotes, hooks, instance writes, or physics changes.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Library = require(
    ReplicatedStorage:WaitForChild("Framework"):WaitForChild("Library")
)

local deadline = os.clock() + 15
while not Library.Loaded and os.clock() < deadline do
    game:GetService("RunService").Heartbeat:Wait()
end

local function normalize(value)
    local text = string.lower(tostring(value or ""))
    text = text:gsub("[_%-%/]+", " ")
    text = text:gsub("[^%w%s']", "")
    text = text:gsub("%s+", " ")
    return text:match("^%s*(.-)%s*$")
end

local function findThings()
    if typeof(Library.Things) == "Instance" and Library.Things.Parent ~= nil then
        return Library.Things, "Library.Things"
    end
    for _, name in ipairs({ "__ITEMS", "__THINGS" }) do
        local root = workspace:FindFirstChild(name)
        if root then return root, "workspace." .. name end
    end
    return nil, "not found"
end

local function attributesOf(object)
    if not object then return {} end
    local ok, attributes = pcall(object.GetAttributes, object)
    return ok and type(attributes) == "table" and attributes or {}
end

local function readValue(object, name)
    if not object then return nil, nil end
    local attributes = attributesOf(object)
    if attributes[name] ~= nil then return attributes[name], "attribute:" .. name end
    if attributes[name .. "_Attr"] ~= nil then
        return attributes[name .. "_Attr"], "attribute:" .. name .. "_Attr"
    end
    for _, childName in ipairs({ name, name .. "_Attr" }) do
        local child = object:FindFirstChild(childName)
        if child and child:IsA("ValueBase") then
            return child.Value, "value:" .. childName
        end
    end
    return nil, nil
end

local function positionOf(object)
    if not object then return nil, nil end
    local pos = object:FindFirstChild("POS") or object:FindFirstChild("Coin")
    if pos then
        if pos:IsA("BasePart") then return pos.Position, pos:GetFullName() end
        local part = pos:FindFirstChildWhichIsA("BasePart", true)
        if part then return part.Position, part:GetFullName() end
    end
    if object:IsA("BasePart") then return object.Position, object:GetFullName() end
    if object:IsA("Model") then
        local ok, pivot = pcall(object.GetPivot, object)
        if ok then return pivot.Position, object:GetFullName() .. ":GetPivot()" end
    end
    local part = object:FindFirstChildWhichIsA("BasePart", true)
    return part and part.Position or nil, part and part:GetFullName() or nil
end

local function classify(name)
    name = normalize(name)
    if name == "magma chest" or name == "volcano magma chest" then
        return "Boss Chest"
    end
    if name:find("chest", 1, true) then return "Chest" end
    if name:find("vault", 1, true) or name:find("safe", 1, true) then
        return "Vault"
    end
    if name:find("gift", 1, true)
        or name:find("present", 1, true)
        or name:find("crate", 1, true) then
        return "Breakable"
    end
    if name:find("diamond", 1, true) or name:find("gem", 1, true) then
        return "Diamonds"
    end
    if name:find("coin", 1, true) then return "Coins" end
    return "Unknown"
end

local function primitiveDirectoryData(name)
    local coins = Library.Directory and Library.Directory.Coins
    local entry = coins and coins[name]
    local result = {}
    if type(entry) ~= "table" then return result end
    for key, value in pairs(entry) do
        local valueType = typeof(value)
        if valueType == "string" or valueType == "number"
            or valueType == "boolean" or valueType == "Vector3" then
            result[tostring(key)] = value
        end
    end
    return result
end

local function visualSignatures(object)
    local signatures, seen = {}, {}
    for _, descendant in ipairs(object:GetDescendants()) do
        local signature
        if descendant:IsA("MeshPart") then
            signature = table.concat({
                "MeshPart",
                descendant.MeshId,
                descendant.TextureID,
                tostring(descendant.Size),
            }, "|")
        elseif descendant:IsA("SpecialMesh") then
            signature = table.concat({
                "SpecialMesh",
                descendant.MeshId,
                descendant.TextureId,
                tostring(descendant.MeshType),
                tostring(descendant.Scale),
            }, "|")
        elseif descendant:IsA("SurfaceAppearance") then
            signature = table.concat({
                "SurfaceAppearance",
                descendant.ColorMap,
                descendant.NormalMap,
                descendant.RoughnessMap,
                descendant.MetalnessMap,
            }, "|")
        end
        if signature and not seen[signature] then
            seen[signature] = true
            signatures[#signatures + 1] = signature
            if #signatures >= 12 then break end
        end
    end
    table.sort(signatures)
    return signatures
end

local function formatMap(map)
    local parts = {}
    for key, value in pairs(map or {}) do
        parts[#parts + 1] = tostring(key) .. "=" .. tostring(value)
    end
    table.sort(parts)
    return #parts > 0 and table.concat(parts, ", ") or "(none)"
end

local things, rootSource = findThings()
local coins = things and things:FindFirstChild("Coins")
assert(coins, "LowOnline probe: Coins folder was not found via " .. rootSource)

local report = {
    Version = "1.0.0",
    Root = things,
    RootSource = rootSource,
    CoinsFolder = coins,
    Count = 0,
    Coins = {},
    Groups = {},
    AttributeKeys = {},
}

for _, object in ipairs(coins:GetChildren()) do
    local id = tostring(select(1, readValue(object, "ID")) or object.Name)
    local name, nameSource = readValue(object, "Name")
    local health, healthSource = readValue(object, "Health")
    local maxHealth, maxHealthSource = readValue(object, "MaxHealth")
    local area, areaSource = readValue(object, "Area")
    local world, worldSource = readValue(object, "World")
    local position, positionSource = positionOf(object)
    name = tostring(name or object.Name)

    local objectAttributes = attributesOf(object)
    for key in pairs(objectAttributes) do report.AttributeKeys[key] = true end

    local row = {
        Id = id,
        Name = name,
        Kind = classify(name),
        Health = tonumber(health),
        MaxHealth = tonumber(maxHealth),
        Area = area and tostring(area) or nil,
        World = world and tostring(world) or nil,
        Position = position,
        Sources = {
            Name = nameSource,
            Health = healthSource,
            MaxHealth = maxHealthSource,
            Area = areaSource,
            World = worldSource,
            Position = positionSource,
        },
        Attributes = objectAttributes,
        PosAttributes = attributesOf(object:FindFirstChild("POS")),
        CoinAttributes = attributesOf(object:FindFirstChild("Coin")),
        Directory = primitiveDirectoryData(name),
        VisualSignatures = visualSignatures(object),
    }
    report.Count = report.Count + 1
    report.Coins[id] = row

    local groupKey = table.concat({
        row.Name,
        row.Area or "?",
        row.Kind,
    }, " | ")
    local group = report.Groups[groupKey]
    if not group then
        group = {
            Name = row.Name,
            Area = row.Area,
            Kind = row.Kind,
            Count = 0,
            MinHealth = math.huge,
            MaxHealth = 0,
            ExampleIds = {},
            Directory = row.Directory,
        }
        report.Groups[groupKey] = group
    end
    group.Count = group.Count + 1
    if row.Health then
        group.MinHealth = math.min(group.MinHealth, row.Health)
        group.MaxHealth = math.max(group.MaxHealth, row.Health)
    end
    if #group.ExampleIds < 3 then group.ExampleIds[#group.ExampleIds + 1] = id end
end

local attributeKeys = {}
for key in pairs(report.AttributeKeys) do attributeKeys[#attributeKeys + 1] = key end
table.sort(attributeKeys)

local groups = {}
for _, group in pairs(report.Groups) do
    if group.MinHealth == math.huge then group.MinHealth = nil end
    groups[#groups + 1] = group
end
table.sort(groups, function(left, right)
    if tostring(left.Area) ~= tostring(right.Area) then
        return tostring(left.Area) < tostring(right.Area)
    end
    return left.Name < right.Name
end)

local environment = type(getgenv) == "function" and getgenv() or _G
environment.LOWONLINE_COIN_PROBE = report
environment.LOWONLINE_COIN_PROBE_DUMP = function(rawId)
    local row = report.Coins[tostring(rawId)]
    if not row then
        warn("[LOWONLINE PROBE] unknown coin id " .. tostring(rawId))
        return nil
    end
    print(string.format(
        "[LOWONLINE PROBE DUMP] id=%s | name=%s | kind=%s | health=%s/%s | area=%s | world=%s | position=%s",
        row.Id,
        row.Name,
        row.Kind,
        tostring(row.Health or "?"),
        tostring(row.MaxHealth or "?"),
        tostring(row.Area or "?"),
        tostring(row.World or "?"),
        tostring(row.Position or "?")
    ))
    print("[LOWONLINE PROBE DUMP] attributes: " .. formatMap(row.Attributes))
    print("[LOWONLINE PROBE DUMP] POS attributes: " .. formatMap(row.PosAttributes))
    print("[LOWONLINE PROBE DUMP] Coin attributes: " .. formatMap(row.CoinAttributes))
    print("[LOWONLINE PROBE DUMP] directory: " .. formatMap(row.Directory))
    print("[LOWONLINE PROBE DUMP] visual: "
        .. (#row.VisualSignatures > 0
            and table.concat(row.VisualSignatures, " || ") or "(none)"))
    return row
end

print(string.format(
    "[LOWONLINE PROBE] root=%s | coins=%d | attribute keys=%s",
    rootSource,
    report.Count,
    #attributeKeys > 0 and table.concat(attributeKeys, ", ") or "(none)"
))
for _, group in ipairs(groups) do
    print(string.format(
        "[LOWONLINE PROBE] area=%s | name=%s | kind=%s | count=%d | health=%s..%s | ids=%s",
        tostring(group.Area or "?"),
        group.Name,
        group.Kind,
        group.Count,
        tostring(group.MinHealth or "?"),
        tostring(group.MaxHealth or "?"),
        table.concat(group.ExampleIds, ",")
    ))
end
print("[LOWONLINE PROBE] full report: getgenv().LOWONLINE_COIN_PROBE")
print("[LOWONLINE PROBE] inspect one ID: getgenv().LOWONLINE_COIN_PROBE_DUMP(\"723\")")

return report
