  -- ====================================================================================
  -- PET SIMULATOR X | ANTI-CRASH & OPTIMIZED FARM HUB (DUAL MODE + HOTKEY 'F')
  -- ====================================================================================
  
  local env = getgenv()

  -- Отключаем состояние экспериментального reward-hook из предыдущего запуска.
  if type(env.PSX_OG_RewardInvokeCaptureState) == "table" then
      env.PSX_OG_RewardInvokeCaptureState.active = false
      env.PSX_OG_RewardInvokeCaptureState.remote = nil
  end
  if type(env.PSX_OG_BoostRemoteCaptureState) == "table" then
      env.PSX_OG_BoostRemoteCaptureState.active = false
      env.PSX_OG_BoostRemoteCaptureState.remote = nil
  end

  if type(env.PSX_OG_RunConnections) == "table" then
      for _, connection in ipairs(env.PSX_OG_RunConnections) do
          pcall(function()
              if connection and type(connection.Disconnect) == "function" then
                  connection:Disconnect()
              end
          end)
      end
  end
  env.PSX_OG_RunConnections = {}

  local function trackRunConnection(connection)
      table.insert(env.PSX_OG_RunConnections, connection)
      return connection
  end
  
  -- Старые версии использовали общий boolean и оживали после повторного запуска.
  -- Оставляем его выключенным навсегда, а новый экземпляр определяем уникальным токеном.
  env.PSX_OG_Running = false
  
  local runToken = {}
  env.PSX_OG_RunToken = runToken
  
  local function isScriptRunning()
      return env.PSX_OG_RunToken == runToken
  end
  
  -- Настройки
  local _G = {
      AutoFarm = false,
      FarmMode = "ТП + Периметр (Мелкие монеты)", -- Режим по умолчанию
      AutoOrbs = false,
      AutoLootbags = false,
      AutoEgg = false,
      TargetEgg = nil,
      EggOpenMode = "Single",
      SkipAnim = true,
      FarmDelay = 0.1,
      EggDelay = 0.12,
      AutoBoosts = false,
      BoostRenewBefore = 5,
      AutoRankRewards = false,
      AutoVIPRewards = false,
      EnabledBoosts = {
          ["Super Lucky"] = true,
          ["Ultra Lucky"] = true,
          ["Triple Coins"] = true,
          ["Triple Damage"] = true
      },
      TrackedCurrency = "Coins",
      AutoPetCoins = false,
      PetFarmMode = "DifferentStrongest",
      BigCoinThreshold = 65,
      FarmLocation = "Текущий мир",
      FarmZone = "Зона игрока"
  }
  
  -- ИНИЦИАЛИЗАЦИЯ ИНТЕРФЕЙСА WINDUI
  if type(env.PSX_OG_UI_CLEANUP) == "function" then
      pcall(env.PSX_OG_UI_CLEANUP)
  end

  local WindUI = loadstring(game:HttpGet("https://github.com/Footagesus/WindUI/releases/latest/download/main.lua"))()

  WindUI:AddTheme({
      Name = "PSX Glass",
      Accent = Color3.fromRGB(56, 189, 248),
      Background = Color3.fromRGB(11, 18, 32),
      Outline = Color3.fromRGB(125, 211, 252),
      Text = Color3.fromRGB(248, 250, 252),
      Placeholder = Color3.fromRGB(148, 163, 184),
      Button = Color3.fromRGB(23, 36, 58),
      Icon = Color3.fromRGB(186, 230, 253)
  })

  local Window = WindUI:CreateWindow({
      Title = "PSX OG | Hook Hub",
      Icon = "paw-print",
      Author = "WindUI edition",
      Folder = "PSX_Temp_Hub",
      Size = UDim2.fromOffset(760, 540),
      MinSize = Vector2.new(620, 420),
      MaxSize = Vector2.new(1100, 780),
      ToggleKey = Enum.KeyCode.RightShift,
      Transparent = true,
      Theme = "PSX Glass",
      Resizable = true,
      SideBarWidth = 190,
      HideSearchBar = false,
      ScrollBarEnabled = true,
      Acrylic = false
  })

  local function destroyWindUI()
      local destroyed = false
      if Window and type(Window.Destroy) == "function" then
          destroyed = pcall(function() Window:Destroy() end)
      end
      if not destroyed and WindUI and type(WindUI.Destroy) == "function" then
          pcall(function() WindUI:Destroy() end)
      end
  end

  env.PSX_OG_UI_CLEANUP = destroyWindUI
  
  -- Сервисы
  local Players = game:GetService("Players")
  local ReplicatedStorage = game:GetService("ReplicatedStorage")
  local VirtualInputManager = game:GetService("VirtualInputManager")
  local RunService = game:GetService("RunService")
  local UserInputService = game:GetService("UserInputService")
  local camera = workspace.CurrentCamera
  local localPlayer = Players.LocalPlayer
  
  -- Переменные для кликера
  local lastClickTime = 0
  local clickAngle = 0
  local clickRadius = 45 -- Радиус разброса кликов
  local lastChestTarget = nil -- В режиме сундука кликаем по одной цели только один раз
  
  -- Состояние счётчика валюты
  local currencySamples = {}
  local currencyTrackerLabel = nil
  local cachedPSXLibrary = nil
  local lastLibraryLookup = 0
  
  -- Папки
  local thingsFolder = workspace:FindFirstChild("__THINGS")
  local coinsFolder = thingsFolder and thingsFolder:FindFirstChild("Coins")
  local orbsFolder = thingsFolder and thingsFolder:FindFirstChild("Orbs")
  local lootbagsFolder = thingsFolder and thingsFolder:FindFirstChild("Lootbags")
  
  local TeleportAreaAliases = {
      ["Fantasy Shop"] = "Shop",
      ["Tech Shop"] = "Shop",
      ["Doodle Shop"] = "Shop",
      ["Steampunk Chest Area"] = "Steampunk Chest"
  }

  local WorldOrder = {
      "Spawn World", "Fantasy World", "Tech World", "Axolotl Ocean",
      "Pixel World", "Cat World", "The Void", "Doodle World",
      "Kawaii World", "Dog World", "Diamond Mine", "Christmas Event",
      "Trading Plaza"
  }

  local WorldZones = {
      ["Spawn World"] = {
          "Shop", "Town", "Forest", "Beach", "Mine", "Winter", "Glacier",
          "Desert", "Volcano", "Cave", "VIP", "Tech Entry"
      },
      ["Fantasy World"] = {
          "Fantasy Shop", "Enchanted Forest", "Portals", "Ancient Island",
          "Samurai Island", "Candy Island", "Haunted Island", "Hell Island",
          "Heaven Island", "Heaven's Gate"
      },
      ["Tech World"] = {
          "Tech Shop", "Tech City", "Dark Tech", "Steampunk",
          "Steampunk Chest", "Alien Lab", "Alien Forest", "Giant Alien Chest",
          "Glitch", "Hacker Portal"
      },
      ["Axolotl Ocean"] = {
          "Axolotl Ocean", "Axolotl Deep Ocean", "Axolotl Cave"
      },
      ["Pixel World"] = {
          "Pixel Forest", "Pixel Kyoto", "Pixel Alps", "Pixel Vault"
      },
      ["Cat World"] = {
          "Cat Paradise", "Cat Backyard", "Cat Taiga", "Cat Kingdom", "Cat Throne Room"
      },
      ["The Void"] = { "The Void" },
      ["Doodle World"] = {
          "Doodle Shop", "Doodle Meadow", "Doodle Peaks", "Doodle Farm",
          "Doodle Barn", "Doodle Oasis", "Doodle Woodlands", "Doodle Safari",
          "Doodle Fairyland", "Doodle Cave"
      },
      ["Kawaii World"] = {
          "Kawaii Tokyo", "Kawaii Village", "Kawaii Candyland", "Kawaii Temple", "Kawaii Dojo"
      },
      ["Dog World"] = {
          "Dog Park", "Dog City", "Dog Firehouse", "Dog Mansion", "Dog Club"
      },
      ["Diamond Mine"] = { "Paradise Cave", "Cyber Cavern", "Mystic Mine" },
      ["Christmas Event"] = { "Christmas Event" },
      ["Trading Plaza"] = { "Trading Plaza" }
  }

  local WorldDetectionSignatures = {
      ["Spawn World"] = {
          "town", "forest", "beach", "mine", "winter", "glacier", "desert",
          "volcano", "cave", "vip", "tech entry", "tech"
      },
      ["Fantasy World"] = {
          "enchanted", "portals", "teleports", "ancient", "temple", "samurai",
          "candy", "haunted", "hell", "heaven"
      },
      ["Tech World"] = {
          "tech city", "dark tech", "city", "dark", "steampunk", "alien lab",
          "alien forest", "alien", "giant alien", "glitch", "hacker"
      },
      ["Axolotl Ocean"] = { "axolotl", "deep ocean", "ocean", "deep" },
      ["Pixel World"] = { "pixel", "kyoto", "alps", "vault" },
      ["Cat World"] = {
          "cat paradise", "cat backyard", "cat taiga", "cat kingdom",
          "paradise", "backyard", "taiga", "kingdom", "throne"
      },
      ["The Void"] = { "the void", "void" },
      ["Doodle World"] = {
          "doodle", "meadow", "peaks", "farm", "barn", "oasis",
          "woodlands", "safari", "fairyland"
      },
      ["Kawaii World"] = { "kawaii", "tokyo", "village", "candyland", "dojo" },
      ["Dog World"] = {
          "dog park", "dog city", "dog firehouse", "dog mansion", "dog club",
          "park", "firehouse", "mansion", "club"
      },
      ["Diamond Mine"] = { "paradise cave", "cyber cavern", "mystic mine", "diamond mine" },
      ["Christmas Event"] = { "christmas" },
      ["Trading Plaza"] = { "trading plaza" }
  }

  local function normalizeAreaName(name)
      name = string.lower(tostring(name or ""))
      name = string.gsub(name, "[%p_]+", " ")
      name = string.gsub(name, "%s+", " ")
      return string.match(name, "^%s*(.-)%s*$") or name
  end

  local function areaNamesMatch(left, right)
      local a = normalizeAreaName(left)
      local b = normalizeAreaName(right)
      if a == b then return true end
      if #a < 4 or #b < 4 then return false end
      return string.find(a, b, 1, true) ~= nil
          or string.find(b, a, 1, true) ~= nil
  end

  local function getLiveMapAreaNames()
      local names = {}
      local map = workspace:FindFirstChild("__MAP")
      local areas = map and map:FindFirstChild("Areas")
      if areas then
          for _, area in ipairs(areas:GetChildren()) do
              table.insert(names, area.Name)
          end
      end
      table.sort(names)
      return names
  end

  local cachedCurrentWorld = nil
  local nextCurrentWorldRefresh = 0

  local function getCurrentWorldName()
      local now = os.clock()
      if now < nextCurrentWorldRefresh and cachedCurrentWorld then
          return cachedCurrentWorld
      end
      nextCurrentWorldRefresh = now + 0.25

      local evidence = getLiveMapAreaNames()
      local bestWorld, bestScore = nil, 0
      for _, worldName in ipairs(WorldOrder) do
          local score = 0
          for _, rawAreaName in ipairs(evidence) do
              local areaName = normalizeAreaName(rawAreaName)
              for _, signature in ipairs(WorldDetectionSignatures[worldName] or {}) do
                  if areaName == signature or string.find(areaName, signature, 1, true) then
                      score = score + 1
                      break
                  end
              end
          end
          if score > bestScore then
              bestWorld, bestScore = worldName, score
          end
      end

      cachedCurrentWorld = bestWorld or "Неизвестный мир"
      return cachedCurrentWorld
  end

  local function getWorldZoneOptions(worldChoice)
      local options = {}
      local seen = {}
      local resolvedWorld = worldChoice
      if worldChoice == "Текущий мир" then
          table.insert(options, "Зона игрока")
          seen["Зона игрока"] = true
          resolvedWorld = getCurrentWorldName()
      end

      local catalog = WorldZones[resolvedWorld]
      if catalog then
          for _, zoneName in ipairs(catalog) do
              if not seen[zoneName] then
                  seen[zoneName] = true
                  table.insert(options, zoneName)
              end
          end
      elseif worldChoice == "Текущий мир" then
          for _, zoneName in ipairs(getLiveMapAreaNames()) do
              if not seen[zoneName] then
                  seen[zoneName] = true
                  table.insert(options, zoneName)
              end
          end
      end

      return options, resolvedWorld
  end
  
  local function getCoinAreaName(coinModel)
      local areaValue = coinModel:GetAttribute("Area_Attr")
          or coinModel:GetAttribute("Area")
      if areaValue ~= nil then
          return tostring(areaValue)
      end
  
      local areaObject = coinModel:FindFirstChild("Area_Attr")
      if areaObject then
          local success, value = pcall(function() return areaObject.Value end)
          if success and value ~= nil then
              return tostring(value)
          end
      end
      return nil
  end
  
  local getCoinPosition

  local DedicatedChestZoneByCoinName = {
      ["giant alien chest"] = "Giant Alien Chest",
      ["giant steampunk chest"] = "Steampunk Chest",
      ["grand heaven chest"] = "Heaven's Gate",
      ["heavens gate grand heaven chest"] = "Heaven's Gate",
      ["magma chest"] = "Volcano",
      ["volcano magma chest"] = "Volcano",
      ["giant tech chest"] = "Tech Entry",
      ["tech entry giant tech chest"] = "Tech Entry",
      ["hacker chest"] = "Hacker Portal",
      ["giant hacker chest"] = "Hacker Portal"
  }
  local DEDICATED_CHEST_ZONE_RADIUS = 180
  local DedicatedChestZoneAnchors = {}
  local nextDedicatedChestAnchorRefresh = 0

  local function getEarlyCoinName(coin)
      if not coin then return "" end
      local nameObject = coin:FindFirstChild("Name_Attr")
      if nameObject then
          local success, value = pcall(function() return nameObject.Value end)
          if success and value ~= nil then return tostring(value) end
      end
      local value = coin:GetAttribute("Name_Attr") or coin:GetAttribute("Name")
      return value ~= nil and tostring(value) or ""
  end

  local function getDedicatedChestZoneForCoin(coin)
      return DedicatedChestZoneByCoinName[normalizeAreaName(getEarlyCoinName(coin))]
  end

  local function refreshDedicatedChestZoneAnchors()
      local now = os.clock()
      if now < nextDedicatedChestAnchorRefresh then return end
      nextDedicatedChestAnchorRefresh = now + 0.1
      if not coinsFolder or not getCoinPosition then return end

      local currentWorld = getCurrentWorldName()
      for _, coin in ipairs(coinsFolder:GetChildren()) do
          local zoneName = getDedicatedChestZoneForCoin(coin)
          if zoneName then
              local coinPosition = getCoinPosition(coin)
              if coinPosition then
                  DedicatedChestZoneAnchors[currentWorld .. "|" .. zoneName] = coinPosition
              end
          end
      end
  end

  local function getDedicatedChestZoneAtPosition(position)
      if not position or not coinsFolder or not getCoinPosition then return nil end

      refreshDedicatedChestZoneAnchors()
      local currentWorld = getCurrentWorldName()
      local nearestZone = nil
      local nearestDistance = math.huge
      for key, anchorPosition in pairs(DedicatedChestZoneAnchors) do
          local worldName, zoneName = string.match(key, "^(.-)|(.+)$")
          if worldName == currentWorld then
              local distance = (position - anchorPosition).Magnitude
              if distance < nearestDistance then
                  nearestZone, nearestDistance = zoneName, distance
              end
          end
      end

      if nearestDistance <= DEDICATED_CHEST_ZONE_RADIUS then
          return nearestZone
      end
      return nil
  end

  local function isPositionInDedicatedChestZone(position, selectedZone)
      if not position or not selectedZone or not coinsFolder or not getCoinPosition then return false end

      refreshDedicatedChestZoneAnchors()
      local currentWorld = getCurrentWorldName()
      for key, anchorPosition in pairs(DedicatedChestZoneAnchors) do
          local worldName, zoneName = string.match(key, "^(.-)|(.+)$")
          if worldName == currentWorld
              and areaNamesMatch(zoneName, selectedZone)
              and (position - anchorPosition).Magnitude <= DEDICATED_CHEST_ZONE_RADIUS then
              return true
          end
      end
      return false
  end
  
  local function getAreaBounds(area)
      if area:IsA("BasePart") then
          return area.CFrame, area.Size
      end
  
      if area:IsA("Model") then
          local success, cf, size = pcall(function()
              return area:GetBoundingBox()
          end)
          if success and cf and size then return cf, size end
      end
  
      local minPos, maxPos
      for _, object in ipairs(area:GetDescendants()) do
          if object:IsA("BasePart") then
              local half = object.Size / 2
              local p = object.Position
              local low = p - half
              local high = p + half
              minPos = minPos and Vector3.new(
                  math.min(minPos.X, low.X), math.min(minPos.Y, low.Y), math.min(minPos.Z, low.Z)
              ) or low
              maxPos = maxPos and Vector3.new(
                  math.max(maxPos.X, high.X), math.max(maxPos.Y, high.Y), math.max(maxPos.Z, high.Z)
              ) or high
          end
      end
  
      if minPos and maxPos then
          return CFrame.new((minPos + maxPos) / 2), maxPos - minPos
      end
      return nil
  end
  
  local function isPointInsideBounds(position, cf, size)
      local point = cf:PointToObjectSpace(position)
      local half = size / 2 + Vector3.new(8, 20, 8)
      return math.abs(point.X) <= half.X
          and math.abs(point.Y) <= half.Y
          and math.abs(point.Z) <= half.Z
  end
  
  local function getAreaForPosition(position)
      if not position then return nil end
      local map = workspace:FindFirstChild("__MAP")
      local areas = map and map:FindFirstChild("Areas")
      if not areas then return nil end
  
      local containingName, containingVolume = nil, math.huge
      local nearestName, nearestDistance = nil, math.huge
      for _, area in ipairs(areas:GetChildren()) do
          local cf, size = getAreaBounds(area)
          if cf and size then
              if isPointInsideBounds(position, cf, size) then
                  local volume = math.max(size.X, 1) * math.max(size.Z, 1)
                  if volume < containingVolume then
                      containingName, containingVolume = area.Name, volume
                  end
              end
              local distance = (cf.Position - position).Magnitude
              if distance < nearestDistance then
                  nearestName, nearestDistance = area.Name, distance
              end
          end
      end
      return containingName or nearestName
  end

  local cachedPlayerArea = nil
  local nextPlayerAreaRefresh = 0

  local function getPlayerAreaName()
      local now = os.clock()
      if now < nextPlayerAreaRefresh then return cachedPlayerArea end
      nextPlayerAreaRefresh = now + 0.08

      local character = localPlayer.Character
      local root = character and character:FindFirstChild("HumanoidRootPart")
      cachedPlayerArea = root and (
          getDedicatedChestZoneAtPosition(root.Position)
          or getAreaForPosition(root.Position)
      ) or nil
      return cachedPlayerArea
  end

  local function getSelectedFarmZone()
      if _G.FarmZone == "Зона игрока" then
          return getPlayerAreaName()
      end
      return TeleportAreaAliases[_G.FarmZone] or _G.FarmZone
  end

  local function getSelectedFarmWorld()
      if _G.FarmLocation == "Текущий мир" then
          return getCurrentWorldName()
      end
      return _G.FarmLocation
  end

  local function getFarmContextKey()
      return tostring(game.PlaceId)
          .. "|" .. tostring(getSelectedFarmWorld() or "Неизвестный мир")
          .. "|" .. tostring(getSelectedFarmZone() or "Неизвестная зона")
  end
  
  -- Кэш актуальных точек появления монет. Он обновляется во время игры,
  -- поэтому координаты из старой локации не используются после телепорта.
  local CoinPositionCache = {}
  local CoinSpatialAreaCache = setmetatable({}, { __mode = "k" })
  
  getCoinPosition = function(coinModel)
      if not coinModel then return nil end
  
      local posObject = coinModel:FindFirstChild("POS")
      if posObject then
          if posObject:IsA("BasePart") then
              return posObject.Position
          end
          local posPart = posObject:FindFirstChildWhichIsA("BasePart", true)
          if posPart then return posPart.Position end
      end
  
      local coinObject = coinModel:FindFirstChild("Coin")
      if coinObject then
          if coinObject:IsA("BasePart") then
              return coinObject.Position
          end
          local coinPart = coinObject:FindFirstChildWhichIsA("BasePart", true)
          if coinPart then return coinPart.Position end
      end
  
      if coinModel:IsA("BasePart") then
          return coinModel.Position
      end
  
      if coinModel:IsA("Model") and coinModel.PrimaryPart then
          return coinModel.PrimaryPart.Position
      end
  
      local anyPart = coinModel:FindFirstChildWhichIsA("BasePart", true)
      if anyPart then return anyPart.Position end
  
      return coinModel:GetPivot().Position
  end
  
  local function refreshCoinPositionCache()
      local currentThings = workspace:FindFirstChild("__THINGS")
      coinsFolder = currentThings and currentThings:FindFirstChild("Coins")
      table.clear(CoinPositionCache)
      if not coinsFolder then return end
  
      for _, coinModel in ipairs(coinsFolder:GetChildren()) do
          local position = getCoinPosition(coinModel)
          if position then
              local area = getCoinAreaName(coinModel) or "Неизвестная зона"
              CoinPositionCache[area] = CoinPositionCache[area] or {}
              table.insert(CoinPositionCache[area], {
                  Id = coinModel.Name,
                  Position = position,
                  Instance = coinModel
              })
          end
      end
  end
  
  -- Поиск монеты (исходная логика)
  local function coinIsInLocation(coinModel)
      local selectedWorld = getSelectedFarmWorld()
      local loadedWorld = getCurrentWorldName()
      if _G.FarmLocation ~= "Текущий мир"
          and loadedWorld ~= "Неизвестный мир"
          and selectedWorld ~= loadedWorld then
          return false
      end

      local selectedZone = getSelectedFarmZone()
      if not selectedZone then return false end

      local dedicatedZone = getDedicatedChestZoneForCoin(coinModel)
      if areaNamesMatch(dedicatedZone, selectedZone) then return true end

      local coinPosition = getCoinPosition(coinModel)
      if isPositionInDedicatedChestZone(coinPosition, selectedZone) then return true end
  
      local areaName = getCoinAreaName(coinModel)
      if areaNamesMatch(areaName, selectedZone) then return true end

      -- Area_Attr и названия моделей карты не всегда совпадают
      -- (например, телепорт Heaven's Gate может находиться внутри модели Heaven).
      local spatialAreaName = CoinSpatialAreaCache[coinModel]
      if spatialAreaName == nil then
          spatialAreaName = getAreaForPosition(getCoinPosition(coinModel)) or false
          CoinSpatialAreaCache[coinModel] = spatialAreaName
      end
      if spatialAreaName == false then spatialAreaName = nil end
      if areaNamesMatch(spatialAreaName, selectedZone) then return true end
  
      local node = coinModel
      while node and node ~= workspace do
          if areaNamesMatch(node.Name, selectedZone) then return true end
          node = node.Parent
      end
      return false
  end
  
  local function getClosestCoinPosition()
      if not coinsFolder then return nil end
      local root = localPlayer.Character and localPlayer.Character:FindFirstChild("HumanoidRootPart")
      if not root then return nil end
      
      local myPos = root.Position
      local closestCoin = nil
      local closestPos = nil
      local shortestDistance = math.huge
      
      for _, coinModel in pairs(coinsFolder:GetChildren()) do
          if not coinIsInLocation(coinModel) then continue end
          local targetPos = getCoinPosition(coinModel)
          
          if targetPos then
              local distance = (myPos - targetPos).Magnitude
              if distance < shortestDistance then
                  shortestDistance = distance
                  closestCoin = coinModel
                  closestPos = targetPos
              end
          end
      end
      -- Возвращаем сам объект только для ограничения трёх кликов.
      return closestCoin, closestPos
  end
  
  task.spawn(function()
      while task.wait(0.5) do
          if not isScriptRunning() then break end
          refreshCoinPositionCache()
      end
  end)
  
  local function formatCurrency(amount)
      amount = tonumber(amount) or 0
  
      local suffixes = {
          {1e15, "Q"},
          {1e12, "T"},
          {1e9, "B"},
          {1e6, "M"},
          {1e3, "K"}
      }
  
      for _, suffixData in ipairs(suffixes) do
          local threshold = suffixData[1]
          local suffix = suffixData[2]
  
          if math.abs(amount) >= threshold then
              return string.format("%.2f%s", amount / threshold, suffix)
          end
      end
  
      return tostring(math.floor(amount + 0.5))
  end
  
  local function normalizeCurrencyName(name)
      return tostring(name):lower():gsub("[%s_%-]", "")
  end
  
  local function readNumericValue(value)
      if type(value) == "number" then
          return value
      end
  
      if type(value) == "string" then
          return tonumber(value)
      end
  
      if typeof(value) == "Instance"
          and (value:IsA("IntValue") or value:IsA("NumberValue")) then
          return value.Value
      end
  
      return nil
  end
  
  local function getPSXLibrary()
      if cachedPSXLibrary then
          return cachedPSXLibrary
      end
  
      if os.clock() - lastLibraryLookup < 5 then
          return nil
      end
  
      lastLibraryLookup = os.clock()
  
      pcall(function()
          local framework = ReplicatedStorage:FindFirstChild("Framework")
          local libraryModule = framework and framework:FindFirstChild("Library")
  
          if libraryModule and libraryModule:IsA("ModuleScript") then
              cachedPSXLibrary = require(libraryModule)
          end
      end)

      return cachedPSXLibrary
  end

  local networkRemoteCache = {}

  local function readUpvaluesForRemote(fn)
      local reader = type(getupvalues) == "function" and getupvalues
          or (debug and type(debug.getupvalues) == "function" and debug.getupvalues)
      if type(reader) ~= "function" then return {} end
      local success, values = pcall(reader, fn)
      return success and type(values) == "table" and values or {}
  end

  local function resolveRemoteRegistryValue(value, expectedClass, seen, depth)
      if depth > 3 then return nil end
      if typeof(value) == "Instance" then
          return value:IsA(expectedClass) and value or nil
      end

      if type(value) == "string" then
          local object = ReplicatedStorage:FindFirstChild(value, true)
          return object and object:IsA(expectedClass) and object or nil
      end

      if type(value) ~= "table" and type(value) ~= "function" then return nil end
      if seen[value] then return nil end
      seen[value] = true

      if type(value) == "function" then
          for _, upvalue in pairs(readUpvaluesForRemote(value)) do
              local remote = resolveRemoteRegistryValue(upvalue, expectedClass, seen, depth + 1)
              if remote then return remote end
          end
          return nil
      end

      for _, key in ipairs({"Remote", "remote", "Instance", "instance", "Object", "object"}) do
          local nested = rawget(value, key)
          if nested ~= nil then
              local remote = resolveRemoteRegistryValue(nested, expectedClass, seen, depth + 1)
              if remote then return remote end
          end
      end

      for _, nested in pairs(value) do
          local nestedType = type(nested)
          if typeof(nested) == "Instance" or nestedType == "table" or nestedType == "function" then
              local remote = resolveRemoteRegistryValue(nested, expectedClass, seen, depth + 1)
              if remote then return remote end
          end
      end
      return nil
  end

  local function findCommandRemoteInValue(value, commandName, expectedClass, seen, depth)
      if depth > 5 then return nil end
      local valueType = type(value)
      if valueType ~= "table" and valueType ~= "function" then return nil end
      if seen[value] then return nil end
      seen[value] = true

      if valueType == "table" then
          local mapped = rawget(value, commandName)
          if mapped ~= nil then
              local remote = resolveRemoteRegistryValue(mapped, expectedClass, {}, 0)
              if remote then return remote end
          end

          for _, nested in pairs(value) do
              local remote = findCommandRemoteInValue(
                  nested,
                  commandName,
                  expectedClass,
                  seen,
                  depth + 1
              )
              if remote then return remote end
          end
          return nil
      end

      for _, upvalue in pairs(readUpvaluesForRemote(value)) do
          local remote = findCommandRemoteInValue(
              upvalue,
              commandName,
              expectedClass,
              seen,
              depth + 1
          )
          if remote then return remote end
      end
      return nil
  end

  local function cacheNetworkRemote(cacheKey, remote, source)
      local entry = {
          remote = remote,
          index = table.find(ReplicatedStorage:GetChildren(), remote),
          source = source
      }
      networkRemoteCache[cacheKey] = entry
      return entry.remote, entry.index, entry.source
  end

  local function findNetworkRemote(commandName, expectedClass, fallbackIndex)
      local cacheKey = expectedClass .. "\0" .. commandName
      local cached = networkRemoteCache[cacheKey]
      if cached and cached.remote and cached.remote.Parent and cached.remote:IsA(expectedClass) then
          cached.index = table.find(ReplicatedStorage:GetChildren(), cached.remote)
          return cached.remote, cached.index, cached.source
      end

      local library = getPSXLibrary()
      local network = library and library.Network
      local methodName = expectedClass == "RemoteFunction" and "Invoke" or "Fire"
      local networkMethod = network and network[methodName]
      if type(networkMethod) == "function" then
          local remote = findCommandRemoteInValue(
              networkMethod,
              commandName,
              expectedClass,
              {},
              0
          )
          if remote then
              return cacheNetworkRemote(cacheKey, remote, "Network." .. methodName .. " upvalues")
          end
      end

      if type(getgc) == "function" then
          local success, objects = pcall(getgc, true)
          if not success then
              success, objects = pcall(getgc)
          end
          if success and type(objects) == "table" then
              for _, object in ipairs(objects) do
                  if type(object) == "table" then
                      local mapped = rawget(object, commandName)
                      if mapped ~= nil then
                          local remote = resolveRemoteRegistryValue(mapped, expectedClass, {}, 0)
                          if remote then
                              return cacheNetworkRemote(cacheKey, remote, "Network registry")
                          end
                      end
                  end
              end
          end
      end

      local fallback = ReplicatedStorage:GetChildren()[fallbackIndex]
      if fallback and fallback:IsA(expectedClass) then
          return cacheNetworkRemote(cacheKey, fallback, "session fallback")
      end

      return nil, nil, "not found"
  end

  local function findBuyEggRemote()
      return findNetworkRemote("Buy Egg Yay", "RemoteFunction", 9)
  end

  local function readCurrencyFromTable(container, currencyName)
      if type(container) ~= "table" then
          return nil
      end
  
      local normalizedTarget = normalizeCurrencyName(currencyName)
  
      for key, value in pairs(container) do
          if normalizeCurrencyName(key) == normalizedTarget then
              local numericValue = readNumericValue(value)
              if numericValue ~= nil then
                  return numericValue
              end
          end
      end
  
      return nil
  end
  
  
  local function getCurrentCurrency(currencyName)
      local library = getPSXLibrary()
  
      if library and library.Save and type(library.Save.Get) == "function" then
          local success, saveData = pcall(library.Save.Get)
  
          if success and type(saveData) == "table" then
              local value = readCurrencyFromTable(saveData, currencyName)
                  or readCurrencyFromTable(saveData.Currency, currencyName)
                  or readCurrencyFromTable(saveData.Currencies, currencyName)
  
              if value ~= nil then
                  return value
              end
          end
      end
  
      local normalizedTarget = normalizeCurrencyName(currencyName)
      local attributeValue = readNumericValue(localPlayer:GetAttribute(currencyName))
  
      if attributeValue ~= nil then
          return attributeValue
      end
  
      for _, object in ipairs(localPlayer:GetDescendants()) do
          if normalizeCurrencyName(object.Name) == normalizedTarget then
              local value = readNumericValue(object)
              if value ~= nil then
                  return value
              end
          end
      end
  
      return nil
  end
  
  -- ====================================================================================
  -- БУСТЫ И ЯЙЦА: ТОЛЬКО СТАБИЛЬНЫЕ КОМАНДЫ LIBRARY.NETWORK
  -- ====================================================================================
  local boostDefinitions = {
      { key = "Super Lucky", title = "Super Lucky", aliases = {"Super Lucky", "Lucky"} },
      { key = "Ultra Lucky", title = "Ultra Lucky", aliases = {"Ultra Lucky"} },
      { key = "Triple Coins", title = "Triple Coins", aliases = {"Triple Coins"} },
      { key = "Triple Damage", title = "Triple Damage", aliases = {"Triple Damage"} }
  }

  local boostNextAttempt = {}
  local boostPendingConfirmation = {}
  local boostLastConfirmedMethod = {}
  local boostDirectRemoteIndex = nil
  local boostDirectRemoteSource = "ещё не использовался"
  local boostStatusParagraph = nil
  local miscRewardStatusParagraph = nil
  local rewardLastResult = {}
  local rewardNextAttempt = {}
  local rewardServerTime = nil
  local rewardServerClock = nil
  local rewardNextTimeSync = 0
  local eggDropdown = nil
  local eggCatalogParagraph = nil
  local eggStatusParagraph = nil
  local eggStatusText = "Ожидание запуска"
  local eggDisplayToId = {}
  local eggIdToDisplay = {}
  local loadedEggsById = {}
  local lastEggCatalogSignature = nil
  local fastEggGateArmed = false

  local function getSaveData()
      local library = getPSXLibrary()
      if not library or not library.Save or type(library.Save.Get) ~= "function" then
          return nil
      end

      local success, saveData = pcall(library.Save.Get)
      if success and type(saveData) == "table" then
          return saveData
      end

      return nil
  end

  local function normalizeDataKey(value)
      return tostring(value or ""):lower():gsub("[%s_%-]", "")
  end

  local function resolveBoostName(saveData, definition)
      local inventory = type(saveData.BoostsInventory) == "table" and saveData.BoostsInventory or {}
      local active = type(saveData.Boosts) == "table" and saveData.Boosts or {}

      for _, alias in ipairs(definition.aliases) do
          if inventory[alias] ~= nil or active[alias] ~= nil then
              return alias
          end
      end

      for key in pairs(inventory) do
          local normalizedKey = normalizeDataKey(key)
          for _, alias in ipairs(definition.aliases) do
              if normalizedKey == normalizeDataKey(alias) then
                  return key
              end
          end
      end

      for key in pairs(active) do
          local normalizedKey = normalizeDataKey(key)
          for _, alias in ipairs(definition.aliases) do
              if normalizedKey == normalizeDataKey(alias) then
                  return key
              end
          end
      end

      return definition.aliases[1]
  end

  local function ensureBoostRemoteCaptureHook()
      local state = env.PSX_OG_BoostRemoteCaptureState
      if type(state) ~= "table" then
          state = {}
          env.PSX_OG_BoostRemoteCaptureState = state
      end

      if env.PSX_OG_BoostRemoteCaptureInstalled == true then
          return state, true
      end
      if type(hookmetamethod) ~= "function" or type(getnamecallmethod) ~= "function" then
          state.error = "hookmetamethod/getnamecallmethod недоступен"
          return state, false
      end

      local oldNamecall
      local function captureNamecall(self, ...)
          local current = env.PSX_OG_BoostRemoteCaptureState
          if current and current.active
              and getnamecallmethod() == "FireServer"
              and typeof(self) == "Instance"
              and self.ClassName == "RemoteEvent"
              and select(1, ...) == current.expectedBoost then
              current.remote = self
          end
          return oldNamecall(self, ...)
      end

      local wrapped = type(newcclosure) == "function"
          and newcclosure(captureNamecall)
          or captureNamecall
      local installed, hookResult = pcall(function()
          oldNamecall = hookmetamethod(game, "__namecall", wrapped)
      end)
      if not installed or type(oldNamecall) ~= "function" then
          state.error = tostring(hookResult or "не удалось установить __namecall hook")
          return state, false
      end

      env.PSX_OG_BoostRemoteCaptureInstalled = true
      state.error = nil
      return state, true
  end

  local function sendBoostThroughNetwork(library, boostName)
      local network = library and library.Network
      if not network or type(network.Fire) ~= "function" then
          return false, "Library.Network.Fire недоступен"
      end

      local captureState, captureReady = ensureBoostRemoteCaptureHook()
      if captureReady then
          captureState.expectedBoost = boostName
          captureState.remote = nil
          captureState.active = true
      end

      local success, err = pcall(network.Fire, "Activate Boost", boostName)
      if captureReady then
          captureState.active = false
          local capturedRemote = captureState.remote
          if capturedRemote and capturedRemote.Parent then
              local _, capturedIndex, capturedSource = cacheNetworkRemote(
                  "RemoteEvent\0Activate Boost",
                  capturedRemote,
                  "captured from Network.Fire"
              )
              boostDirectRemoteIndex = capturedIndex
              boostDirectRemoteSource = capturedSource
          end
      end

      return success, success and "Network.Fire" or tostring(err)
  end

  local function sendBoostThroughDirectFallback(boostName)
      local lookupOk, remote, remoteIndex, remoteSource = pcall(
          findNetworkRemote,
          "Activate Boost",
          "RemoteEvent",
          8
      )
      if not lookupOk then
          boostDirectRemoteSource = "ошибка парсинга: " .. tostring(remote)
          return false, boostDirectRemoteSource
      end
      if not remote then
          boostDirectRemoteSource = "RemoteEvent не найден"
          return false, boostDirectRemoteSource
      end

      boostDirectRemoteIndex = remoteIndex
      boostDirectRemoteSource = tostring(remoteSource)
      local sent, err = pcall(function()
          remote:FireServer(boostName)
      end)
      if not sent then
          return false, tostring(err)
      end
      return true, string.format(
          "direct remote [%s], %s",
          tostring(remoteIndex or "?"),
          tostring(remoteSource)
      )
  end

  local function getRewardServerTime(library)
      local now = os.clock()
      if now >= rewardNextTimeSync then
          rewardNextTimeSync = now + 60
          local network = library and library.Network
          if network and type(network.Invoke) == "function" then
              local success, serverTime = pcall(network.Invoke, "Get OSTime")
              if success and tonumber(serverTime) then
                  rewardServerTime = tonumber(serverTime)
                  rewardServerClock = now
              end
          end
      end

      if rewardServerTime and rewardServerClock then
          return rewardServerTime + (now - rewardServerClock)
      end
      return os.time()
  end

  local function invokeAutoReward(library, commandName)
      local network = library and library.Network
      if not network or type(network.Invoke) ~= "function" then
          return false, "Library.Network.Invoke недоступен"
      end

      local invokeOk, result = pcall(network.Invoke, commandName)
      if not invokeOk then
          return false, tostring(result)
      end
      if result then
          return true, "Network.Invoke"
      end

      return false, "сервер отклонил награду"
  end

  local function formatBoostTime(seconds)
      seconds = math.max(0, math.floor(tonumber(seconds) or 0))
      local hours = math.floor(seconds / 3600)
      local minutes = math.floor((seconds % 3600) / 60)
      local remainingSeconds = seconds % 60

      if hours > 0 then
          return string.format("%d:%02d:%02d", hours, minutes, remainingSeconds)
      end

      return string.format("%02d:%02d", minutes, remainingSeconds)
  end

  local function hasGamepass(saveData, gamepassName)
      if type(saveData) ~= "table" or type(saveData.Gamepasses) ~= "table" then
          return false
      end

      for key, value in pairs(saveData.Gamepasses) do
          if value == gamepassName or (key == gamepassName and value == true) then
              return true
          end
      end

      return false
  end

  local function readEggIdFromInstance(object)
      if not object then return nil end

      local idObject = object:FindFirstChild("ID_Attr")
      if idObject and idObject.Value ~= nil then
          return tostring(idObject.Value)
      end

      local success, value = pcall(function()
          return object:GetAttribute("ID_Attr") or object:GetAttribute("ID")
      end)
      if success and value ~= nil then
          return tostring(value)
      end

      return nil
  end

  local function getEggWorldPosition(eggObject)
      if not eggObject or not eggObject.Parent then return nil end

      local center = eggObject:FindFirstChild("Center")
      if center then
          if center:IsA("BasePart") then return center.Position end
          if center:IsA("Attachment") then return center.WorldPosition end
          if center:IsA("Model") then return center:GetPivot().Position end
          local centerPart = center:FindFirstChildWhichIsA("BasePart", true)
          if centerPart then return centerPart.Position end
      end

      if eggObject:IsA("BasePart") then return eggObject.Position end
      if eggObject:IsA("Model") then return eggObject:GetPivot().Position end
      local part = eggObject:FindFirstChildWhichIsA("BasePart", true)
      return part and part.Position or nil
  end

  local function getPlayerRootPosition()
      local character = localPlayer.Character
      local root = character and character:FindFirstChild("HumanoidRootPart")
      return root and root.Position or nil
  end

  local function scanLoadedEggs(eggDirectory)
      local found = {}
      local rootPosition = getPlayerRootPosition()
      local mapRoot = workspace:FindFirstChild("__MAP") or workspace
      local eggsRoot = mapRoot:FindFirstChild("Eggs", true) or mapRoot

      for _, object in ipairs(eggsRoot:GetDescendants()) do
          if (object:IsA("Model") or object:IsA("Folder"))
              and object:FindFirstChild("Center") then
              local eggId = readEggIdFromInstance(object)
              if eggId and eggDirectory[eggId] then
                  local position = getEggWorldPosition(object)
                  local distance = position and rootPosition and (position - rootPosition).Magnitude or math.huge
                  local previous = found[eggId]
                  if not previous or distance < previous.distance then
                      found[eggId] = {
                          instance = object,
                          position = position,
                          distance = distance
                      }
                  end
              end
          end
      end

      return found
  end

  local function rebuildEggCatalog()
      local library = getPSXLibrary()
      local eggDirectory = library and library.Directory and library.Directory.Eggs
      if type(eggDirectory) ~= "table" then
          eggDisplayToId = {}
          eggIdToDisplay = {}
          loadedEggsById = {}
          return {"Каталог яиц загружается..."}, nil, 0, 0
      end

      loadedEggsById = scanLoadedEggs(eggDirectory)
      local entries = {}
      local loadedCount = 0

      for rawId, config in pairs(eggDirectory) do
          if type(config) == "table" then
              local eggId = tostring(rawId)
              local displayName = tostring(config.displayName or config.name or eggId)
              local isLoaded = loadedEggsById[eggId] ~= nil
              if isLoaded then loadedCount = loadedCount + 1 end
              table.insert(entries, {
                  id = eggId,
                  name = displayName,
                  loaded = isLoaded
              })
          end
      end

      table.sort(entries, function(left, right)
          if left.loaded ~= right.loaded then return left.loaded end
          local leftName = left.name:lower()
          local rightName = right.name:lower()
          if leftName == rightName then return left.id < right.id end
          return leftName < rightName
      end)

      local options = {}
      local displayToId = {}
      local idToDisplay = {}
      local nearestId = nil
      local nearestDistance = math.huge

      for _, entry in ipairs(entries) do
          local marker = entry.loaded and "● " or "○ "
          local label = marker .. entry.name
          if entry.id ~= entry.name then
              label = label .. "  [" .. entry.id .. "]"
          end
          table.insert(options, label)
          displayToId[label] = entry.id
          idToDisplay[entry.id] = label

          local loadedInfo = loadedEggsById[entry.id]
          if loadedInfo and loadedInfo.distance < nearestDistance then
              nearestDistance = loadedInfo.distance
              nearestId = entry.id
          end
      end

      eggDisplayToId = displayToId
      eggIdToDisplay = idToDisplay

      if #options == 0 then
          options = {"Яйца не найдены"}
      end

      return options, nearestId, loadedCount, #entries
  end

  local function refreshEggDropdown(force)
      local options, nearestId, loadedCount, totalCount = rebuildEggCatalog()
      local signature = table.concat(options, "\0")

      if not _G.TargetEgg or not eggIdToDisplay[tostring(_G.TargetEgg)] then
          _G.TargetEgg = nearestId or eggDisplayToId[options[1]]
      end

      local selectedLabel = _G.TargetEgg and eggIdToDisplay[tostring(_G.TargetEgg)] or options[1]

      if eggDropdown and (force or signature ~= lastEggCatalogSignature) then
          lastEggCatalogSignature = signature
          pcall(function() eggDropdown:Refresh(options) end)
          if selectedLabel then
              pcall(function() eggDropdown:Select(selectedLabel) end)
          end
      end

      if eggCatalogParagraph then
          local targetInfo = _G.TargetEgg and loadedEggsById[tostring(_G.TargetEgg)]
          local distanceText = targetInfo and targetInfo.distance < math.huge
              and string.format(" | до выбранного %.1f", targetInfo.distance)
              or " | выбранное яйцо не загружено"
          pcall(function()
              eggCatalogParagraph:SetDesc(
                  string.format("● текущий мир: %d | всего в каталоге: %d%s", loadedCount, totalCount, distanceText)
              )
          end)
      end

      return options, selectedLabel
  end

  local function setEggAnimationGate(enabled)
      local library = getPSXLibrary()
      if library and library.Variables then
          pcall(function() library.Variables.OpeningEgg = enabled == true end)
      end
  end

  local function openEgg(eggName, triple)
      eggName = tostring(eggName or ""):match("^%s*(.-)%s*$")
      if eggName == "" then
          return false, "Укажи точное название яйца"
      end

      local library = getPSXLibrary()
      local network = library and library.Network
      if not network then
          return false, "Library.Network ещё не загружен"
      end
      if library.Loaded ~= true then
          return false, "Library ещё загружается"
      end

      if triple then
          local saveData = getSaveData()
          if not saveData then
              return false, "Сохранение игрока ещё не загружено"
          end
          if not hasGamepass(saveData, "Triple Egg Open") then
              return false, "Для x3 нужен геймпасс Triple Egg Open"
          end
      end

      local eggDirectory = library.Directory and library.Directory.Eggs
      if type(eggDirectory) ~= "table" or not eggDirectory[eggName] then
          return false, "В Library.Directory.Eggs нет ID: " .. eggName
      end

      local loadedInfo = loadedEggsById[eggName]
      if not loadedInfo or not loadedInfo.instance or not loadedInfo.instance.Parent then
          rebuildEggCatalog()
          loadedInfo = loadedEggsById[eggName]
      end

      local eggDistance = nil
      if loadedInfo then
          local eggPosition = getEggWorldPosition(loadedInfo.instance) or loadedInfo.position
          local rootPosition = getPlayerRootPosition()
          if eggPosition and rootPosition then
              eggDistance = (eggPosition - rootPosition).Magnitude
              loadedInfo.distance = eggDistance
          end
      end

      local buyEggRemote, remoteIndex, remoteSource = findBuyEggRemote()
      if not buyEggRemote then
          return false, "Buy Egg RemoteFunction не найден в Network registry"
      end

      local callOk, purchased, message = pcall(function()
          return buyEggRemote:InvokeServer(eggName, triple == true)
      end)
      if not callOk then
          return false, string.format(
              "Ошибка Buy Egg remote [%s] (%s): %s",
              tostring(remoteIndex or "?"),
              tostring(remoteSource),
              tostring(purchased)
          )
      end
      if purchased then
          return true, string.format(
              "%s | remote [%s], %s",
              triple and "Открыто x3" or "Открыто x1",
              tostring(remoteIndex or "?"),
              tostring(remoteSource)
          )
      end

      local failureText = tostring(message or "Сервер отклонил открытие")
      if eggDistance and eggDistance > 25 then
          failureText = failureText .. string.format(" | расстояние %.1f (штатный предел 25)", eggDistance)
      elseif not loadedInfo then
          failureText = failureText .. " | экземпляр яйца не найден в текущем Workspace"
      end
      return false, failureText
  end
  
  -- ВКЛАДКИ WINDUI
  local OverviewTab = Window:Tab({ Title = "Обзор", Icon = "layout-dashboard" })
  local ClickFarmTab = Window:Tab({ Title = "Клик-фарм", Icon = "mouse-pointer-click" })
  local PetsTab = Window:Tab({ Title = "Питомцы", Icon = "paw-print" })
  local LootTab = Window:Tab({ Title = "Лут", Icon = "package-open" })
  local BoostsTab = Window:Tab({ Title = "Бусты", Icon = "zap" })
  local EggTab = Window:Tab({ Title = "Яйца", Icon = "egg" })
  local MiscTab = Window:Tab({ Title = "Разное", Icon = "gift" })
  local SettingsTab = Window:Tab({ Title = "Настройки", Icon = "settings" })

  local OverviewSection = OverviewTab:Section({ Title = "Состояние", Box = true, Opened = true })
  OverviewSection:Paragraph({
      Title = "Управление",
      Desc = "RightShift — показать или скрыть меню\nF — включить или выключить клик-фарм"
  })

  local currencyTrackerParagraph = OverviewSection:Paragraph({
      Title = "Скорость фарма",
      Desc = "Coins/мин: включи клик-фарм или пет-фарм"
  })
  currencyTrackerLabel = {
      Set = function(_, text)
          pcall(function() currencyTrackerParagraph:SetDesc(text) end)
      end
  }

  OverviewSection:Dropdown({
      Title = "Валюта для подсчёта",
      Values = {"Coins", "Diamonds", "Fantasy Coins", "Tech Coins", "Rainbow Coins", "Cartoon Coins"},
      Value = "Coins",
      Multi = false,
      AllowNone = false,
      Callback = function(value)
          _G.TrackedCurrency = value
          table.clear(currencySamples)
          currencyTrackerLabel:Set(value .. "/мин: ожидание данных...")
      end
  })

  local ClickFarmSection = ClickFarmTab:Section({ Title = "Обычный фарм", Box = true, Opened = true })
  local AutoFarmToggle = ClickFarmSection:Toggle({
      Title = "Авто-наведение и клик",
      Desc = "Быстрое переключение — клавиша F",
      Value = false,
      Callback = function(value) _G.AutoFarm = value end
  })

  ClickFarmSection:Dropdown({
      Title = "Режим фарма",
      Values = {"Издалека (Биг Сундук)", "ТП + Периметр (Мелкие монеты)"},
      Value = "ТП + Периметр (Мелкие монеты)",
      Multi = false,
      AllowNone = false,
      Callback = function(value) _G.FarmMode = value end
  })

  ClickFarmSection:Slider({
      Title = "Задержка кликера",
      Desc = "Чем меньше значение, тем чаще отправляется клик",
      Step = 5,
      Value = { Min = 5, Max = 100, Default = 10 },
      Callback = function(value) _G.FarmDelay = value / 100 end
  })

  local PetBaseSection = PetsTab:Section({ Title = "Автофарм питомцев", Box = true, Opened = true })
  PetBaseSection:Toggle({
      Title = "Фармить монеты питомцами",
      Desc = "Питомцы закрепляются за целями выбранной зоны",
      Value = false,
      Callback = function(value)
          _G.AutoPetCoins = value
          if value and _G.AutoFarm then
              _G.AutoFarm = false
              pcall(function() AutoFarmToggle:Set(false) end)
          end
      end
  })

  local petModeLabels = {
      "Все на босс-сундук",
      "Все на крупную обычную цель",
      "По разным сильным обычным целям",
      "По разным слабым обычным целям"
  }
  local petModesByLabel = {
      ["Все на босс-сундук"] = "AllOneBossChest",
      ["Все на крупную обычную цель"] = "AllOneBigCoin",
      ["По разным сильным обычным целям"] = "DifferentStrongest",
      ["По разным слабым обычным целям"] = "DifferentWeakest"
  }
  local petModeSettingsSection = nil

  local function rebuildPetModeSettings(modeLabel)
      if petModeSettingsSection then
          pcall(function() petModeSettingsSection:Destroy() end)
      end

      petModeSettingsSection = PetsTab:Section({
          Title = "Параметры стратегии",
          Box = true,
          Opened = true
      })

      local mode = petModesByLabel[modeLabel] or "DifferentStrongest"
      if mode == "AllOneBossChest" then
          petModeSettingsSection:Paragraph({
              Title = "Босс-сундук",
              Desc = "Только постоянные сундуки из каталога: Magma, Grand Heaven, Giant Tech, Ancient, Alien и другие. Обычные Chest игнорируются."
          })
      elseif mode == "AllOneBigCoin" then
          petModeSettingsSection:Paragraph({
              Title = "Крупные обычные цели",
              Desc = "Все питомцы идут на одну наиболее прочную цель. Обычные Chest разрешены, исключены только босс-сундуки."
          })
          petModeSettingsSection:Slider({
              Title = "Минимальная сила монеты",
              Desc = "Процент от самой жирной найденной монеты в выбранной зоне",
              Step = 5,
              Value = { Min = 10, Max = 100, Default = _G.BigCoinThreshold },
              Callback = function(value) _G.BigCoinThreshold = value end
          })
      elseif mode == "DifferentWeakest" then
          petModeSettingsSection:Paragraph({
              Title = "Раздельный фарм слабых",
              Desc = "Каждый питомец получает отдельную слабую цель. Обычные Chest разрешены, босс-сундуки исключены."
          })
      else
          petModeSettingsSection:Paragraph({
              Title = "Раздельный фарм сильных",
              Desc = "Каждый питомец получает отдельную прочную цель. Обычные Chest разрешены, босс-сундуки исключены."
          })
      end
  end

  PetBaseSection:Dropdown({
      Title = "Стратегия распределения",
      Values = petModeLabels,
      Value = "По разным сильным обычным целям",
      Multi = false,
      AllowNone = false,
      Callback = function(value)
          _G.PetFarmMode = petModesByLabel[value] or "DifferentStrongest"
          rebuildPetModeSettings(value)
      end
  })

  local worldDropdownValues = { "Текущий мир" }
  for _, worldName in ipairs(WorldOrder) do
      table.insert(worldDropdownValues, worldName)
  end

  local zoneDropdown = nil
  local lastZoneOptionsSignature = nil

  local function refreshZoneDropdown(force)
      if not zoneDropdown then return end
      local options = getWorldZoneOptions(_G.FarmLocation)
      local signature = tostring(_G.FarmLocation) .. "|" .. table.concat(options, "\0")
      if not force and signature == lastZoneOptionsSignature then return end

      local selectedZone = _G.FarmZone
      local selectionIsValid = false
      for _, zoneName in ipairs(options) do
          if zoneName == selectedZone then
              selectionIsValid = true
              break
          end
      end

      if not selectionIsValid then
          selectedZone = _G.FarmLocation == "Текущий мир"
              and "Зона игрока"
              or options[1]
      end

      lastZoneOptionsSignature = signature
      zoneDropdown:Refresh(options)
      if selectedZone then
          _G.FarmZone = selectedZone
          pcall(function() zoneDropdown:Select(selectedZone) end)
      end
  end

  PetBaseSection:Dropdown({
      Title = "Мир",
      Desc = "Текущий мир обновляет список автоматически; конкретный мир показывает только свои зоны",
      Values = worldDropdownValues,
      Value = "Текущий мир",
      Multi = false,
      AllowNone = false,
      Callback = function(value)
          _G.FarmLocation = value
          refreshZoneDropdown(true)
      end
  })

  local initialZoneOptions = getWorldZoneOptions("Текущий мир")
  zoneDropdown = PetBaseSection:Dropdown({
      Title = "Зона",
      Values = initialZoneOptions,
      Value = "Зона игрока",
      Multi = false,
      AllowNone = false,
      Callback = function(value) _G.FarmZone = value end
  })

  refreshZoneDropdown(true)

  local currentZoneParagraph = PetBaseSection:Paragraph({
      Title = "Активный фильтр",
      Desc = "Определение мира и позиции игрока..."
  })

  rebuildPetModeSettings("По разным сильным обычным целям")

  local LootSection = LootTab:Section({ Title = "Автосбор", Box = true, Opened = true })
  LootSection:Toggle({
      Title = "Магнит Orbs",
      Desc = "Автоматически собирать сферы",
      Value = false,
      Callback = function(value) _G.AutoOrbs = value end
  })
  LootSection:Toggle({
      Title = "Магнит Lootbags",
      Desc = "Автоматически собирать мешки",
      Value = false,
      Callback = function(value) _G.AutoLootbags = value end
  })

  local BoostsSection = BoostsTab:Section({ Title = "Автопродление", Box = true, Opened = true })
  BoostsSection:Toggle({
      Title = "Автоматически использовать бусты",
      Desc = "Применяет выбранный буст до того, как его таймер обнулится",
      Value = false,
      Callback = function(value)
          _G.AutoBoosts = value == true
          if _G.AutoBoosts then
              table.clear(boostNextAttempt)
              table.clear(boostPendingConfirmation)
          end
      end
  })
  BoostsSection:Slider({
      Title = "Продлевать заранее",
      Desc = "За сколько секунд до окончания использовать следующий буст",
      Step = 1,
      Value = { Min = 1, Max = 30, Default = 5 },
      Callback = function(value) _G.BoostRenewBefore = value end
  })

  for _, definition in ipairs(boostDefinitions) do
      local currentDefinition = definition
      BoostsSection:Toggle({
          Title = currentDefinition.title,
          Desc = "Остаток и количество берутся из сохранения игрока",
          Value = true,
          Callback = function(value)
              _G.EnabledBoosts[currentDefinition.key] = value
          end
      })
  end

  boostStatusParagraph = BoostsSection:Paragraph({
      Title = "Состояние бустов",
      Desc = "Ожидание данных Library.Save..."
  })

  local RewardsSection = MiscTab:Section({ Title = "Автонаграды", Box = true, Opened = true })
  RewardsSection:Toggle({
      Title = "Автосбор Rank Rewards",
      Desc = "Забирает награду ранга сразу после окончания RankTimer",
      Value = false,
      Callback = function(value)
          _G.AutoRankRewards = value == true
          rewardNextAttempt["Redeem Rank Rewards"] = 0
      end
  })
  RewardsSection:Toggle({
      Title = "Автосбор VIP Rewards",
      Desc = "Забирает VIP-награду после четырёхчасового кулдауна",
      Value = false,
      Callback = function(value)
          _G.AutoVIPRewards = value == true
          rewardNextAttempt["Redeem VIP Rewards"] = 0
      end
  })
  miscRewardStatusParagraph = RewardsSection:Paragraph({
      Title = "Состояние наград",
      Desc = "Автосбор выключен"
  })

  local EggSection = EggTab:Section({ Title = "Автооткрытие", Box = true, Opened = true })
  local initialEggOptions, initialEggLabel = refreshEggDropdown(false)
  eggDropdown = EggSection:Dropdown({
      Title = "Яйцо",
      Desc = "● загружено в текущем мире, ○ есть в общем каталоге; сервер требует находиться рядом",
      Values = initialEggOptions,
      Value = initialEggLabel or initialEggOptions[1],
      Multi = false,
      AllowNone = false,
      Callback = function(value)
          local eggId = eggDisplayToId[value]
          if eggId then _G.TargetEgg = eggId end
      end
  })
  EggSection:Button({
      Title = "Обновить список яиц",
      Desc = "Повторно читает Library.Directory.Eggs и яйца текущего Workspace",
      Icon = "refresh-cw",
      Callback = function() refreshEggDropdown(true) end
  })
  eggCatalogParagraph = EggSection:Paragraph({
      Title = "Каталог",
      Desc = "Сканирование яиц текущего мира..."
  })
  EggSection:Dropdown({
      Title = "Количество за открытие",
      Desc = "Режим x3 требует геймпасс Triple Egg Open",
      Values = {"Одинарное (x1)", "Тройное (x3)"},
      Value = "Одинарное (x1)",
      Multi = false,
      AllowNone = false,
      Callback = function(value)
          _G.EggOpenMode = value == "Тройное (x3)" and "Triple" or "Single"
      end
  })
  EggSection:Slider({
      Title = "Интервал открытия",
      Desc = "В миллисекундах; без пропуска анимации применяется безопасный минимум",
      Step = 10,
      Value = { Min = 60, Max = 1000, Default = 120 },
      Callback = function(value) _G.EggDelay = value / 1000 end
  })
  local SkipAnimToggle = EggSection:Toggle({
      Title = "Пропуск анимации",
      Desc = "Блокирует обработчик Open Egg до создания моделей и интерфейса",
      Value = true,
      Callback = function(value)
          _G.SkipAnim = value == true
          fastEggGateArmed = false
          setEggAnimationGate(false)
      end
  })
  local AutoEggToggle = EggSection:Toggle({
      Title = "Автооткрытие яиц",
      Value = false,
      Callback = function(value)
          _G.AutoEgg = value == true
          fastEggGateArmed = false
          setEggAnimationGate(false)
      end
  })
  eggStatusParagraph = EggSection:Paragraph({
      Title = "Состояние",
      Desc = eggStatusText
  })
  refreshEggDropdown(true)

  local AppearanceSection = SettingsTab:Section({ Title = "Интерфейс", Box = true, Opened = true })
  AppearanceSection:Slider({
      Title = "Прозрачность окна",
      Desc = "0 — плотное, 90 — почти прозрачное",
      Step = 5,
      Value = { Min = 0, Max = 90, Default = 20 },
      Callback = function(value)
          pcall(function() Window:SetBackgroundTransparency(value / 100) end)
          pcall(function() Window:SetBackgroundImageTransparency(math.min(1, value / 100 + 0.1)) end)
      end
  })

  local ScriptSection = SettingsTab:Section({ Title = "Скрипт", Box = true, Opened = true })
  ScriptSection:Button({
      Title = "ВЫКЛЮЧИТЬ И УДАЛИТЬ СКРИПТ",
      Desc = "Остановить все циклы и закрыть интерфейс",
      Icon = "power",
      Callback = function()
          env.PSX_OG_Running = false
          if env.PSX_OG_RunToken == runToken then
              env.PSX_OG_RunToken = nil
          end
          if env.PSX_OG_UI_CLEANUP == destroyWindUI then
              env.PSX_OG_UI_CLEANUP = nil
          end
          setEggAnimationGate(false)
          pcall(function()
              local char = localPlayer.Character
              if char and char:FindFirstChild("HumanoidRootPart") then
                  char.HumanoidRootPart.Anchored = false
              end
              camera.CameraType = Enum.CameraType.Custom
              if char and char:FindFirstChild("Humanoid") then
                  camera.CameraSubject = char.Humanoid
              end
          end)
          destroyWindUI()
      end
  })
  
  -- ====================================================================================
  -- ГОРЯЧАЯ КЛАВИША [F] ДЛЯ АВТОФАРМА
  -- ====================================================================================
  trackRunConnection(UserInputService.InputBegan:Connect(function(input, gameProcessed)
      -- Не реагируем, если ты печатаешь в чат
      if gameProcessed then return end
      
      -- Проверяем, нажата ли кнопка F и жив ли скрипт
      if input.KeyCode == Enum.KeyCode.F and isScriptRunning() then
          -- Инвертируем тумблер (если был выкл - станет вкл, и наоборот)
          AutoFarmToggle:Set(not _G.AutoFarm)
      end
  end))
  
  -- ====================================================================================
  -- 1. ИДЕАЛЬНЫЙ АВТОФАРМ (ПОДХОД + КАМЕРА + ДВА РЕЖИМА)
  -- ====================================================================================
  trackRunConnection(RunService.RenderStepped:Connect(function()
      local char = localPlayer.Character
      local root = char and char:FindFirstChild("HumanoidRootPart")
      
      -- Разморозка и возврат камеры при выключении
      if not _G.AutoFarm or _G.AutoPetCoins or not isScriptRunning() then 
          lastChestTarget = nil
          pcall(function()
              if root and root.Anchored then 
                  root.Anchored = false 
              end
              if camera.CameraType == Enum.CameraType.Scriptable and not _G.SkipAnim then
                  camera.CameraType = Enum.CameraType.Custom
                  if char and char:FindFirstChild("Humanoid") then
                      camera.CameraSubject = char.Humanoid
                  end
              end
          end)
          return 
      end
      
      local coinTarget, coinPos = getClosestCoinPosition()
      if not coinPos then
          lastChestTarget = nil
          return
      end
      
      pcall(function()
          if camera.CameraType ~= Enum.CameraType.Scriptable then
              camera.CameraType = Enum.CameraType.Scriptable
          end
      end)
      
      if _G.FarmMode == "ТП + Периметр (Мелкие монеты)" then
          -- ИСХОДНЫЙ РЕЖИМ (ТП над монетой, заморозка, камера вниз)
          if root then
              root.Velocity = Vector3.new(0, 0, 0)
              root.CFrame = CFrame.new(coinPos + Vector3.new(0, 6, 0))
              root.Anchored = true
          end
          pcall(function()
              camera.CFrame = CFrame.new(coinPos + Vector3.new(0, 15, 0), coinPos)
          end)
      else
          -- ИСХОДНЫЙ РЕЖИМ (Биг Сундук, без ТП, камера смотрит из текущей позиции)
          if root and root.Anchored then
              root.Anchored = false
          end
          pcall(function()
              local upperChestPosition = coinPos + Vector3.new(0, 8, 0)
              camera.CFrame = CFrame.new(camera.CFrame.Position, upperChestPosition)
          end)
      end
      
      if _G.FarmMode == "Издалека (Биг Сундук)" then
          -- Единственное отличие от старой версии: три мгновенных клика на новую цель.
          if lastChestTarget ~= coinTarget then
              lastChestTarget = coinTarget
  
              local targetX = camera.ViewportSize.X / 2
              local targetY = camera.ViewportSize.Y / 2
  
              task.spawn(function()
                  for clickIndex = 1, 3 do
                      if _G.AutoPetCoins or not isScriptRunning() then break end
                      VirtualInputManager:SendMouseButtonEvent(targetX, targetY, 0, true, game, 0)
                      task.wait(0.01)
                      VirtualInputManager:SendMouseButtonEvent(targetX, targetY, 0, false, game, 0)
  
                      if clickIndex < 3 then
                          task.wait(0.01)
                      end
                  end
              end)
          end
      else
          lastChestTarget = nil
          local currentTime = os.clock()
          if currentTime - lastClickTime >= _G.FarmDelay then
              lastClickTime = currentTime
              task.spawn(function()
                  if _G.AutoPetCoins or not isScriptRunning() then return end
                  local targetX = camera.ViewportSize.X / 2
                  local targetY = camera.ViewportSize.Y / 2
  
                  clickAngle = clickAngle + math.rad(45)
                  if clickAngle >= math.pi * 2 then clickAngle = 0 end
  
                  targetX = targetX + (math.cos(clickAngle) * clickRadius)
                  targetY = targetY + (math.sin(clickAngle) * clickRadius)
  
                  VirtualInputManager:SendMouseButtonEvent(targetX, targetY, 0, true, game, 0)
                  task.wait(0.01)
                  VirtualInputManager:SendMouseButtonEvent(targetX, targetY, 0, false, game, 0)
              end)
          end
      end
  end))
  
  -- ====================================================================================
  -- 1.5. АВТОФАРМ ПИТОМЦАМИ ЧЕРЕЗ REMOTE-КАРТУ
  -- ====================================================================================
  local function selectCoinWithOnePet(coin)
      local library = getPSXLibrary()
      local signal = library and library.Signal
      if not signal or type(signal.Fire) ~= "function" then return false end
      local success = pcall(signal.Fire, "Select Coin", coin)
      if success and type(library.RenderStepped) == "function" then
          pcall(library.RenderStepped)
      end
      return success
  end

  local function selectCoinWithAllPets(coin)
      local library = getPSXLibrary()
      local signal = library and library.Signal
      if not signal or type(signal.Fire) ~= "function" then return false end
      local success = pcall(signal.Fire, "Group Select Coin", coin)
      if success and type(library.RenderStepped) == "function" then
          pcall(library.RenderStepped)
      end
      return success
  end
  
  local function getEquippedPetIds()
      local library = getPSXLibrary()
      local saveData
      if library and library.Save and type(library.Save.Get) == "function" then
          pcall(function() saveData = library.Save.Get() end)
      end
  
      local ids = {}
      for _, pet in pairs((saveData and saveData.Pets) or {}) do
          if type(pet) == "table" and pet.e and pet.uid then
              table.insert(ids, pet.uid)
          end
      end
      return ids
  end
  
  local function getCoinNetworkId(coin)
      if not coin then return nil end
      local idObject = coin:FindFirstChild("ID_Attr")
      if idObject then
          local success, value = pcall(function() return idObject.Value end)
          if success and value ~= nil then return tostring(value) end
      end
      local value = coin:GetAttribute("ID_Attr")
          or coin:GetAttribute("ID")
      return value ~= nil and tostring(value) or coin.Name
  end

  local cachedPetRuntimeStates = nil
  local lastPetRuntimeScan = 0

  local function isPetRuntimeEntry(entry, petId)
      if type(entry) ~= "table" or tostring(rawget(entry, "uid")) ~= tostring(petId) then
          return false
      end

      local physical = rawget(entry, "physical")
      return typeof(physical) == "Instance" and physical:IsA("BasePart")
  end

  local function getPetRuntimeStates(petId)
      petId = tostring(petId)
      if cachedPetRuntimeStates and isPetRuntimeEntry(rawget(cachedPetRuntimeStates, petId), petId) then
          return cachedPetRuntimeStates
      end

      if os.clock() - lastPetRuntimeScan < 2 then return nil end
      lastPetRuntimeScan = os.clock()

      local getGCObjects = getgc
      if type(getGCObjects) ~= "function" then return nil end

      local success, objects = pcall(getGCObjects, true)
      if not success then
          success, objects = pcall(getGCObjects)
      end
      if not success or type(objects) ~= "table" then return nil end

      for _, object in ipairs(objects) do
          if type(object) == "table" and isPetRuntimeEntry(rawget(object, petId), petId) then
              cachedPetRuntimeStates = object
              return object
          end
      end

      return nil
  end

  local function bindLocalPetTargetByUID(petId, coin)
      local pos = coin and coin:FindFirstChild("POS")
      if not pos then return false end

      petId = tostring(petId)
      local runtimeStates = getPetRuntimeStates(petId)
      local state = runtimeStates and rawget(runtimeStates, petId)
      if not isPetRuntimeEntry(state, petId) then return false end

      if state.farming and state.target == pos then return true end

      if type(state.selectionFunc) == "function" then
          pcall(state.selectionFunc)
      end

      state.selectionFunc = nil
      state.farming = true
      state.target = pos
      state.follower = nil
      state.arrived = false
      state.targetuid = (tonumber(state.targetuid) or 0) + 1
      state.randomRotation = Random.new():NextNumber(0, 360)
      return true
  end

  local function localPetArrivedAtCoin(petId, coin)
      local pos = coin and coin:FindFirstChild("POS")
      if not pos then return false end

      petId = tostring(petId)
      local runtimeStates = getPetRuntimeStates(petId)
      local state = runtimeStates and rawget(runtimeStates, petId)
      return isPetRuntimeEntry(state, petId)
          and state.farming
          and state.target == pos
          and state.arrived == true
  end
  
  local function syncPetTargetByUID(petId, coin)
      local library = getPSXLibrary()
      local network = library and library.Network
      if not network or type(network.Fire) ~= "function" then return false end

      petId = tostring(petId)
      local coinId = getCoinNetworkId(coin)
      if not coinId then return false end

      local targetSent = pcall(network.Fire, "Change Pet Target", petId, "Coin", coinId)
      local farmSent = pcall(network.Fire, "Farm Coin", coinId, petId)
      return targetSent and farmSent
  end

  local function fireFarmCoinByUID(petId, coin)
      local library = getPSXLibrary()
      local network = library and library.Network
      if not network or type(network.Fire) ~= "function" then return false end

      local coinId = getCoinNetworkId(coin)
      if not coinId then return false end
      return pcall(network.Fire, "Farm Coin", coinId, tostring(petId))
  end

  local function joinPetsToCoinByUID(coin, petIds)
      local acceptedPets = {}
      local library = getPSXLibrary()
      local network = library and library.Network
      if not network
          or type(network.Invoke) ~= "function"
          or type(network.Fire) ~= "function"
          or not coin
          or #petIds == 0 then
          return acceptedPets
      end

      local coinId = getCoinNetworkId(coin)
      if not coinId then return acceptedPets end

      local normalizedPetIds = {}
      for _, petId in ipairs(petIds) do
          table.insert(normalizedPetIds, tostring(petId))
      end

      local success, response = pcall(network.Invoke, "Join Coin", coinId, normalizedPetIds)
      if not success then return acceptedPets end

      if response == true then
          for _, petId in ipairs(normalizedPetIds) do acceptedPets[petId] = true end
      elseif type(response) == "table" then
          for _, petId in ipairs(normalizedPetIds) do
              local accepted = response[petId]
              if accepted == nil then
                  for responsePetId, responseValue in pairs(response) do
                      if tostring(responsePetId) == petId then
                          accepted = responseValue
                          break
                      end
                  end
              end
            acceptedPets[petId] = accepted ~= nil and accepted ~= false
          end
      end

      return acceptedPets
  end
  
  local function findCoinByNetworkId(coinId)
      if not coinsFolder or coinId == nil then return nil end
      coinId = tostring(coinId)
      for _, coin in ipairs(coinsFolder:GetChildren()) do
          if getCoinNetworkId(coin) == coinId then return coin end
      end
      return nil
  end
  
  local function getServerCoinTargets()
      local library = getPSXLibrary()
      local network = library and library.Network
      if not network or type(network.Invoke) ~= "function" then return nil end
  
      local success, targets = pcall(network.Invoke, "Get Coin Targets")
      if success and type(targets) == "table" then return targets end
      return nil
  end
  
  local function getCoinHealth(coin)
      local healthObject = coin:FindFirstChild("Health_Attr")
      if healthObject then
          local success, value = pcall(function() return healthObject.Value end)
          if success then return tonumber(value) or 0 end
      end
      return tonumber(coin:GetAttribute("Health_Attr")
          or coin:GetAttribute("Health")) or 0
  end

  local CoinPeakHealth = setmetatable({}, { __mode = "k" })

  local function getCoinPriorityHealth(coin)
      local currentHealth = getCoinHealth(coin)
      local peakHealth = math.max(CoinPeakHealth[coin] or 0, currentHealth)
      CoinPeakHealth[coin] = peakHealth
      return peakHealth
  end
  
  local function readCoinBool(coin, name)
      local object = coin:FindFirstChild(name .. "_Attr")
      if object then
          local success, value = pcall(function() return object.Value end)
          if success then return value end
      end
      local value = coin:GetAttribute(name .. "_Attr")
      if value ~= nil then return value end
      return coin:GetAttribute(name)
  end
  
  local function coinCanBeFarmed(coin)
      if not coin or not coin.Parent or not coin:FindFirstChild("POS") then return false end
      if getCoinHealth(coin) <= 0 then return false end
      if readCoinBool(coin, "IsFalling") == true then return false end
      if readCoinBool(coin, "HasLanded") == false then return false end
      return true
  end
  
  local function getCoinName(coin)
      local nameObject = coin and coin:FindFirstChild("Name_Attr")
      if nameObject then
          local success, value = pcall(function() return nameObject.Value end)
          if success and value ~= nil then return tostring(value) end
      end

      local value = coin and (coin:GetAttribute("Name_Attr")
          or coin:GetAttribute("Name"))
      if value ~= nil then return tostring(value) end
      return coin and coin.Name or ""
  end

  local function normalizeCoinName(name)
      name = string.lower(tostring(name or ""))
      name = string.gsub(name, "[%p_]+", " ")
      name = string.gsub(name, "%s+", " ")
      return string.match(name, "^%s*(.-)%s*$") or name
  end

  -- Только постоянные гигантские/AFK-сундуки из конечных зон.
  -- Обычные случайные Chest (например Enchanted Forest Chest) сюда не входят.
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
      ["giant doodle cave chest"] = true,
      ["giant doodle chest"] = true,
      ["kawaii temple chest"] = true,
      ["giant kawaii temple chest"] = true,
      ["dojo chest"] = true,
      ["kawaii dojo chest"] = true,
      ["kawaii alley chest"] = true,
      ["giant kawaii alley chest"] = true,
      ["giant dog chest"] = true,
      ["giant disco chest"] = true,
      ["afk chest"] = true,
      ["giant afk chest"] = true
  }

  local function isBossChestCoin(coin)
      return BossChestNames[normalizeCoinName(getCoinName(coin))] == true
  end

  local function getPriorityCoin(claimedCoins, failedCoins, strongestFirst, coinFilter)
      if not coinsFolder then return nil end

      claimedCoins = claimedCoins or {}
      failedCoins = failedCoins or {}
      local bestCoin = nil
      local bestHealth = strongestFirst and -math.huge or math.huge
      local bestId = nil

      for _, coin in ipairs(coinsFolder:GetChildren()) do
          if not claimedCoins[coin]
              and not failedCoins[coin]
              and coinCanBeFarmed(coin)
              and coinIsInLocation(coin) then
              local health = getCoinPriorityHealth(coin)
              if not coinFilter or coinFilter(coin, health) then
                  local coinId = tostring(getCoinNetworkId(coin) or coin.Name)
                  local isBetter = strongestFirst and (health > bestHealth
                          or health == bestHealth and (not bestId or coinId < bestId))
                      or not strongestFirst and (health < bestHealth
                          or health == bestHealth and (not bestId or coinId < bestId))
                  if isBetter then
                      bestCoin, bestHealth, bestId = coin, health, coinId
                  end
              end
          end
      end

      return bestCoin
  end

  local function getStrongestUnclaimedCoin(claimedCoins, failedCoins)
      return getPriorityCoin(claimedCoins, failedCoins, true)
  end

  local function getWeakestUnclaimedCoin(claimedCoins, failedCoins)
      return getPriorityCoin(claimedCoins, failedCoins, false)
  end

  local function getStrongestBossChest(failedCoins)
      return getPriorityCoin({}, failedCoins, true, function(coin)
          return isBossChestCoin(coin)
      end)
  end

  local function getStrongestRegularTarget(claimedCoins, failedCoins, minimumHealth)
      return getPriorityCoin(claimedCoins, failedCoins, true, function(coin, health)
          return not isBossChestCoin(coin) and (not minimumHealth or health >= minimumHealth)
      end)
  end

  local function getWeakestRegularTarget(claimedCoins, failedCoins)
      return getPriorityCoin(claimedCoins, failedCoins, false, function(coin)
          return not isBossChestCoin(coin)
      end)
  end

  task.spawn(function()
      local claimedCoins = {}
      local failedCoins = {}
      local lastAssignment = -math.huge
      local lastTargetSync = -math.huge
      local assignmentSyncDelay = 0.06
      local targetSyncDelay = 0.15
      local unconfirmedTimeout = 0.35
      local failedCoinCooldown = 0.75
      while false and task.wait(0.02) do
          if not isScriptRunning() then break end
          if not _G.AutoPetCoins then
              table.clear(claimedCoins)
              table.clear(failedCoins)
              lastAssignment = -math.huge
              lastTargetSync = -math.huge
              continue
          end
  
          -- Не переключаемся на новую монету, пока текущая ещё существует.
          local now = os.clock()
          for coin, expiresAt in pairs(failedCoins) do
              if not coin.Parent or now >= expiresAt then failedCoins[coin] = nil end
          end
  
          local equippedPetIds = getEquippedPetIds()
          local equippedPetSet = {}
          for _, petId in ipairs(equippedPetIds) do equippedPetSet[tostring(petId)] = true end
  
          if now - lastTargetSync >= targetSyncDelay then
              lastTargetSync = now
              local targets = getServerCoinTargets()
              if targets then
                  local serverClaimedCoins = {}
                  for petId, target in pairs(targets) do
                      if equippedPetSet[tostring(petId)] and type(target) == "table" and target.t == "Coin" then
                          local coin = findCoinByNetworkId(target.id)
                          if coin then serverClaimedCoins[coin] = true end
                      end
                  end
  
                  for coin, assignedAt in pairs(claimedCoins) do
                      if serverClaimedCoins[coin] then
                          claimedCoins[coin] = now
                      elseif now - assignedAt >= unconfirmedTimeout then
                          claimedCoins[coin] = nil
                          failedCoins[coin] = now + failedCoinCooldown
                      end
                  end
                  for coin in pairs(serverClaimedCoins) do
                      claimedCoins[coin] = now
                  end
              end
          end
  
          local claimedCount = 0
          local targetWasRemoved = false
          for coin in pairs(claimedCoins) do
              if not coin.Parent or not coinIsInLocation(coin) then
                  claimedCoins[coin] = nil
                  targetWasRemoved = true
              else
                  claimedCount = claimedCount + 1
              end
          end
  
          local equippedPetCount = #equippedPetIds
          if targetWasRemoved then
              local library = getPSXLibrary()
              if library and type(library.RenderStepped) == "function" then
                  pcall(library.RenderStepped)
              else
                  task.wait()
              end
          end
  
          if claimedCount < equippedPetCount
              and (targetWasRemoved or os.clock() - lastAssignment >= assignmentSyncDelay) then
              local coin = getStrongestUnclaimedCoin(claimedCoins, failedCoins)
              if coin and selectCoinWithOnePet(coin) then
                  claimedCoins[coin] = os.clock()
                  lastAssignment = os.clock()
              end
          end
      end
  end)
  
  -- ====================================================================================
  -- 2. БЕЗОПАСНЫЙ МАГНИТ (БЕЗ ЛАГОВ)
  -- ====================================================================================
  local confirmedPetCoins = {}
  local confirmedCoinPets = {}
  local rejectedCoins = {}
  local pendingCoin = nil
  local pendingCoinId = nil
  local pendingSince = 0
  local nextAssignmentAt = 0
  local joinObserverInstalled = false
  
  local function clearPetAssignment(petId)
      petId = tostring(petId)
      local coin = confirmedPetCoins[petId]
      if coin and confirmedCoinPets[coin] == petId then
          confirmedCoinPets[coin] = nil
      end
      confirmedPetCoins[petId] = nil
  end
  
  local function onJoinCoinObserved(coinId, requestedPets, joinedPets)
      if not _G.AutoPetCoins or not pendingCoin then return end
      if tostring(coinId) ~= tostring(pendingCoinId) then return end
  
      local coin = pendingCoin
      local acceptedAny = false
      if type(joinedPets) == "table" then
          for petId, accepted in pairs(joinedPets) do
              if accepted then
                  petId = tostring(petId)
                  clearPetAssignment(petId)
  
                  local previousPet = confirmedCoinPets[coin]
                  if previousPet and previousPet ~= petId then
                      confirmedPetCoins[previousPet] = nil
                  end
  
                  confirmedPetCoins[petId] = coin
                  confirmedCoinPets[coin] = petId
                  acceptedAny = true
              end
          end
      end
  
      if not acceptedAny and coin and coin.Parent then
          rejectedCoins[coin] = os.clock() + 0.6
      end
      pendingCoin = nil
      pendingCoinId = nil
      pendingSince = 0
  end
  
  task.spawn(function()
      while false and task.wait(0.02) do
          if not isScriptRunning() then break end
  
          if not joinObserverInstalled then
              joinObserverInstalled = installJoinCoinObserver(onJoinCoinObserved)
          end
  
          if not _G.AutoPetCoins then
              table.clear(confirmedPetCoins)
              table.clear(confirmedCoinPets)
              table.clear(rejectedCoins)
              pendingCoin = nil
              pendingCoinId = nil
              pendingSince = 0
              nextAssignmentAt = 0
              continue
          end
  
          if not joinObserverInstalled then continue end
  
          local now = os.clock()
          local equippedPetIds = getEquippedPetIds()
          local equippedPetSet = {}
          for _, petId in ipairs(equippedPetIds) do
              equippedPetSet[tostring(petId)] = true
          end
  
          for petId, coin in pairs(confirmedPetCoins) do
              if not equippedPetSet[petId]
                  or not coin.Parent then
                  local wasDestroyed = not coin.Parent
                  clearPetAssignment(petId)
                  if wasDestroyed then
                      -- Ждём, пока штатный Pets-скрипт увидит удаление цели и
                      -- переведёт именно освободившегося питомца в состояние Player.
                      nextAssignmentAt = math.max(nextAssignmentAt, now + 0.12)
                  end
              end
          end
  
          for coin, expiresAt in pairs(rejectedCoins) do
              if not coin.Parent or now >= expiresAt then rejectedCoins[coin] = nil end
          end
  
          if pendingCoin and (not pendingCoin.Parent or now - pendingSince >= 0.5) then
              if pendingCoin.Parent then rejectedCoins[pendingCoin] = now + 0.6 end
              pendingCoin = nil
              pendingCoinId = nil
              pendingSince = 0
          end
  
          local activePetCount = 0
          for petId in pairs(confirmedPetCoins) do
              if equippedPetSet[petId] then activePetCount = activePetCount + 1 end
          end
  
          if activePetCount < #equippedPetIds
              and not pendingCoin
              and now >= nextAssignmentAt then
              local claimedCoins = {}
              for coin in pairs(confirmedCoinPets) do claimedCoins[coin] = true end
  
              local coin = getStrongestUnclaimedCoin(claimedCoins, rejectedCoins)
              if coin then
                  pendingCoin = coin
                  pendingCoinId = getCoinNetworkId(coin)
                  pendingSince = now
  
                  if not selectCoinWithOnePet(coin) then
                      rejectedCoins[coin] = now + 0.6
                      pendingCoin = nil
                      pendingCoinId = nil
                      pendingSince = 0
                  end
              end
          end
      end
  
      local observer = env.PSX_OG_JoinObserver
      if observer then observer.Callback = nil end
  end)
  
  -- Консервативный распределитель: одно назначение на монету и никаких
  -- повторных Select Coin, пока сама модель цели не удалена из workspace.
  local observer = env.PSX_OG_JoinObserver
  if observer then observer.Callback = nil end
  
  task.spawn(function()
    local assignedCoins = {}
    local lastSelectionAt = -math.huge
    local urgentAssignments = 0
    local urgentReadyAt = 0
    local selectionSpacing = 0.35
    local petReleaseDelay = 0.12
  
    while false and task.wait(0.05) do
          if not isScriptRunning() then break end
  
          if not _G.AutoPetCoins then
            table.clear(assignedCoins)
            lastSelectionAt = -math.huge
            urgentAssignments = 0
            urgentReadyAt = 0
            continue
          end
  
        local now = os.clock()
        local assignedCount = 0
        for coin in pairs(assignedCoins) do
            if not coin.Parent or getCoinHealth(coin) <= 0 then
                assignedCoins[coin] = nil
                urgentAssignments = urgentAssignments + 1
                urgentReadyAt = math.max(urgentReadyAt, now + petReleaseDelay)
            else
                assignedCount = assignedCount + 1
            end
          end
  
        local equippedPetCount = #getEquippedPetIds()
        if assignedCount < equippedPetCount
            and ((urgentAssignments > 0 and now >= urgentReadyAt)
                or (urgentAssignments == 0 and now - lastSelectionAt >= selectionSpacing)) then
              if urgentAssignments > 0 then
                  local library = getPSXLibrary()
                  if library and type(library.RenderStepped) == "function" then
                      pcall(library.RenderStepped)
                  else
                      task.wait()
                  end
              end
  
              local coin = getStrongestUnclaimedCoin(assignedCoins, {})
              if coin and selectCoinWithOnePet(coin) then
                  assignedCoins[coin] = true
                  lastSelectionAt = os.clock()
                  if urgentAssignments > 0 then urgentAssignments = urgentAssignments - 1 end
              elseif urgentAssignments > 0 then
                  urgentAssignments = urgentAssignments - 1
              end
          end
      end
  end)
  
local function getMarkerPetUID(marker)
    local idObject = marker:FindFirstChild("ID_Attr")
    if idObject then
        local success, value = pcall(function() return idObject.Value end)
        if success and value ~= nil then return tostring(value) end
    end
    local value = marker:GetAttribute("ID_Attr")
        or marker:GetAttribute("ID")
    if value ~= nil then return tostring(value) end
    return marker.Name
end

local function readLiveCoinPetAssignments(equippedPetSet)
    local petCoins = {}
    local occupiedCoins = {}
    if not coinsFolder then return petCoins, occupiedCoins end

    for _, coin in ipairs(coinsFolder:GetChildren()) do
        local pets = coin:FindFirstChild("Pets")
        if pets and getCoinHealth(coin) > 0 then
            for _, marker in ipairs(pets:GetChildren()) do
                local petId = getMarkerPetUID(marker)
                if equippedPetSet[petId] then
                    petCoins[petId] = coin
                    occupiedCoins[coin] = true
                end
            end
        end
    end
    return petCoins, occupiedCoins
end

-- UID-распределитель: petUID блокируется за одной целью до её уничтожения.
-- Серверный Join Coin является авторитетным подтверждением назначения.
task.spawn(function()
    local petStates = {}
    local rejectedCoins = {}
    local lockedGroupCoin = nil
    local previousMode = _G.PetFarmMode
    local previousContext = getFarmContextKey()
    local bigCoinHealthAnchor = 0
    local requestSerial = 0

    local JOIN_RETRY_DELAY = 0.12
    local MAX_JOIN_RETRIES = 2
    local TARGET_SYNC_DELAY = 0.35
    local SLOW_TARGET_SYNC_DELAY = 1.5
    local FAST_TARGET_SYNC_ATTEMPTS = 3
    local FAILURE_COOLDOWN = 0.15

    local function targetIsAlive(coin)
        return coin and coin.Parent and getCoinHealth(coin) > 0
    end

    local function releasePetState(petId)
        petStates[tostring(petId)] = nil
    end

    local function resetTransientState()
        table.clear(rejectedCoins)
        lockedGroupCoin = nil
        bigCoinHealthAnchor = 0
    end

    local function resetAllState()
        table.clear(petStates)
        resetTransientState()
    end

    local function updateBigCoinHealthAnchor()
        if not coinsFolder then return nil end

        local currentAnchor = 0
        for _, coin in ipairs(coinsFolder:GetChildren()) do
            if coinCanBeFarmed(coin)
                and coinIsInLocation(coin)
                and not isBossChestCoin(coin) then
                currentAnchor = math.max(currentAnchor, getCoinPriorityHealth(coin))
            end
        end

        bigCoinHealthAnchor = currentAnchor
        if bigCoinHealthAnchor <= 0 then return nil end
        local thresholdPercent = math.clamp(tonumber(_G.BigCoinThreshold) or 65, 10, 100)
        return bigCoinHealthAnchor * (thresholdPercent / 100)
    end

    local function dispatchPetsToCoin(petIds, coin)
        if not targetIsAlive(coin) or #petIds == 0 then return end

        local requestTokens = {}
        for _, rawPetId in ipairs(petIds) do
            local petId = tostring(rawPetId)
            local state = petStates[petId]
            if not state then
                state = {
                    Coin = coin,
                    Phase = "reserved",
                    Retries = 0
                }
                petStates[petId] = state
            end

            if state.Coin == coin and state.Phase ~= "joining" then
                requestSerial = requestSerial + 1
                state.Phase = "joining"
                state.RequestId = requestSerial
                state.RequestedAt = os.clock()
                requestTokens[petId] = requestSerial
            end
        end

        local requestedPetIds = {}
        for petId in pairs(requestTokens) do table.insert(requestedPetIds, petId) end
        if #requestedPetIds == 0 then return end

        task.spawn(function()
            local acceptedPets = joinPetsToCoinByUID(coin, requestedPetIds)
            local finishedAt = os.clock()
            local acceptedAny = false

            for _, petId in ipairs(requestedPetIds) do
                local state = petStates[petId]
                if state
                    and state.Coin == coin
                    and state.RequestId == requestTokens[petId] then
                    if acceptedPets[petId] and _G.AutoPetCoins and isScriptRunning() and targetIsAlive(coin) then
                        acceptedAny = true
                        state.Phase = "assigned"
                        state.AcceptedAt = finishedAt
                        state.NextSyncAt = finishedAt + TARGET_SYNC_DELAY
                        state.NextFarmAt = finishedAt + 0.25
                        state.FarmAttemptsRemaining = 8
                        state.ArrivalFarmSent = false
                        state.MissingSince = nil
                        state.HadLiveConfirmation = false
                        state.SyncAttemptsRemaining = FAST_TARGET_SYNC_ATTEMPTS
                        state.LocalBound = bindLocalPetTargetByUID(petId, coin)
                        syncPetTargetByUID(petId, coin)
                    elseif targetIsAlive(coin) and state.Retries < MAX_JOIN_RETRIES and _G.AutoPetCoins then
                        state.Retries = state.Retries + 1
                        state.Phase = "retry"
                        state.RetryAt = finishedAt + JOIN_RETRY_DELAY
                    else
                        releasePetState(petId)
                    end
                end
            end

            if not acceptedAny and targetIsAlive(coin) then
                rejectedCoins[coin] = finishedAt + FAILURE_COOLDOWN
                if lockedGroupCoin == coin then lockedGroupCoin = nil end
            end
        end)
    end

    while task.wait(_G.AutoPetCoins and 0.02 or 0.25) do
        if not isScriptRunning() then break end

        local currentThings = workspace:FindFirstChild("__THINGS")
        coinsFolder = currentThings and currentThings:FindFirstChild("Coins")

        if not _G.AutoPetCoins then
            resetAllState()
            previousMode = _G.PetFarmMode
            previousContext = getFarmContextKey()
            continue
        end

        local now = os.clock()
        local mode = _G.PetFarmMode or "DifferentStrongest"
        local context = getFarmContextKey()
        if mode ~= previousMode or context ~= previousContext then
            -- Уже занятые питомцы заканчивают свои монеты; меняется только очередь новых целей.
            resetTransientState()
            previousMode = mode
            previousContext = context
        end

        local equippedPetIds = getEquippedPetIds()
        local normalizedPetIds = {}
        local equippedPetSet = {}
        for _, rawPetId in ipairs(equippedPetIds) do
            local petId = tostring(rawPetId)
            table.insert(normalizedPetIds, petId)
            equippedPetSet[petId] = true
        end

        if #normalizedPetIds == 0 then
            resetAllState()
            continue
        end

        local livePetCoins, occupiedCoins = readLiveCoinPetAssignments(equippedPetSet)

        for coin, expiresAt in pairs(rejectedCoins) do
            if not coin.Parent or now >= expiresAt then rejectedCoins[coin] = nil end
        end

        -- Удаляем блокировку только после смерти цели или снятия питомца с экипировки.
        for petId, state in pairs(petStates) do
            if not equippedPetSet[petId] or not targetIsAlive(state.Coin) then
                releasePetState(petId)
            end
        end

        -- Подхватываем назначения, уже подтверждённые сервером до запуска/после телепорта.
        for petId, liveCoin in pairs(livePetCoins) do
            local state = petStates[petId]
            if not state then
                petStates[petId] = {
                    Coin = liveCoin,
                    Phase = "confirmed",
                    Retries = 0,
                    NextSyncAt = now + TARGET_SYNC_DELAY,
                    HadLiveConfirmation = true,
                    SyncAttemptsRemaining = 0,
                    LocalBound = bindLocalPetTargetByUID(petId, liveCoin)
                }
            elseif state.Coin == liveCoin then
                state.Phase = "confirmed"
                state.MissingSince = nil
                state.HadLiveConfirmation = true
                state.SyncAttemptsRemaining = 0
                state.LocalBound = bindLocalPetTargetByUID(petId, state.Coin)
                state.NextSyncAt = now + TARGET_SYNC_DELAY
            end
        end

        -- Retry всегда относится к той же самой монете: сменить цель здесь невозможно.
        for petId, state in pairs(petStates) do
            if state.Phase == "retry" and now >= (state.RetryAt or 0) then
                dispatchPetsToCoin({ petId }, state.Coin)
            elseif state.Phase == "assigned" or state.Phase == "confirmed" then
                local liveIsDesired = livePetCoins[petId] == state.Coin
                if not liveIsDesired and state.HadLiveConfirmation then
                    state.HadLiveConfirmation = false
                    state.SyncAttemptsRemaining = FAST_TARGET_SYNC_ATTEMPTS
                    state.NextSyncAt = now
                end
                if not state.LocalBound then
                    state.LocalBound = bindLocalPetTargetByUID(petId, state.Coin)
                end
                if not state.ArrivalFarmSent and localPetArrivedAtCoin(petId, state.Coin) then
                    fireFarmCoinByUID(petId, state.Coin)
                    state.ArrivalFarmSent = true
                    state.FarmAttemptsRemaining = 0
                elseif (state.FarmAttemptsRemaining or 0) > 0 and now >= (state.NextFarmAt or 0) then
                    fireFarmCoinByUID(petId, state.Coin)
                    state.FarmAttemptsRemaining = state.FarmAttemptsRemaining - 1
                    state.NextFarmAt = now + 0.25
                end
                if not liveIsDesired and now >= (state.NextSyncAt or 0) then
                    syncPetTargetByUID(petId, state.Coin)
                    local fastAttempts = tonumber(state.SyncAttemptsRemaining) or 0
                    if fastAttempts > 0 then
                        state.SyncAttemptsRemaining = fastAttempts - 1
                        state.NextSyncAt = now + TARGET_SYNC_DELAY
                    else
                        state.NextSyncAt = now + SLOW_TARGET_SYNC_DELAY
                    end
                end
            end
        end

        local freePetIds = {}
        for _, petId in ipairs(normalizedPetIds) do
            if not petStates[petId] and not livePetCoins[petId] then
                table.insert(freePetIds, petId)
            end
        end

        if #freePetIds == 0 then continue end

        local isGroupMode = mode == "AllOneBossChest" or mode == "AllOneBigCoin"
        if isGroupMode then
            if lockedGroupCoin and not targetIsAlive(lockedGroupCoin) then
                lockedGroupCoin = nil
            end

            if not lockedGroupCoin then
                if mode == "AllOneBossChest" then
                    lockedGroupCoin = getStrongestBossChest(rejectedCoins)
                else
                    local minimumHealth = updateBigCoinHealthAnchor()
                    if minimumHealth then
                        lockedGroupCoin = getStrongestRegularTarget({}, rejectedCoins, minimumHealth)
                    end
                end
            end

            if lockedGroupCoin then
                dispatchPetsToCoin(freePetIds, lockedGroupCoin)
            end
            continue
        end

        local claimedCoins = {}
        for coin in pairs(occupiedCoins) do claimedCoins[coin] = true end
        for _, state in pairs(petStates) do
            if targetIsAlive(state.Coin) then claimedCoins[state.Coin] = true end
        end

        -- UID и цель резервируются до запуска сетевого запроса, поэтому параллельные
        -- Join Coin не могут выбрать одного питомца или одну монету дважды.
        for _, petId in ipairs(freePetIds) do
            local coin = nil
            if mode == "DifferentWeakest" then
                coin = getWeakestRegularTarget(claimedCoins, rejectedCoins)
            else
                coin = getStrongestRegularTarget(claimedCoins, rejectedCoins)
            end

            if coin then
                petStates[petId] = {
                    Coin = coin,
                    Phase = "reserved",
                    Retries = 0
                }
                claimedCoins[coin] = true
                dispatchPetsToCoin({ petId }, coin)
            end
        end
    end
end)

-- Штатный планировщик: Select Coin обновляет внутреннее состояние Pets-скрипта,
-- а резервирование слотов не позволяет повторно выбрать уже занятого питомца.
task.spawn(function()
    local petAssignments = {}
    local pendingRequests = {}
    local rejectedTargets = {}
    local lockedGroupCoin = nil
    local previousMode = _G.PetFarmMode
    local previousContext = getFarmContextKey()
    local autoWasEnabled = false
    local releaseReadyAt = 0
    local releaseNeedsSync = false
    local bigCoinHealthAnchor = 0

    local FAILURE_COOLDOWN = 0.12
    local RELEASE_FRAME_DELAY = 0.01

    local function targetIsAlive(coin)
        return coin and coin.Parent and getCoinHealth(coin) > 0
    end

    local function getRequestKey(coin)
        local coinId = getCoinNetworkId(coin)
        return coinId and tostring(coinId) or nil
    end

    local function resetTransientState()
        table.clear(rejectedTargets)
        lockedGroupCoin = nil
        bigCoinHealthAnchor = 0
    end

    local function resetAllState()
        table.clear(petAssignments)
        table.clear(pendingRequests)
        resetTransientState()
        releaseReadyAt = 0
        releaseNeedsSync = false
    end

    local function updateBigCoinHealthAnchor()
        if not coinsFolder then return nil end

        local currentAnchor = 0
        for _, coin in ipairs(coinsFolder:GetChildren()) do
            if coinCanBeFarmed(coin)
                and coinIsInLocation(coin)
                and not isBossChestCoin(coin) then
                currentAnchor = math.max(currentAnchor, getCoinPriorityHealth(coin))
            end
        end

        bigCoinHealthAnchor = currentAnchor
        if bigCoinHealthAnchor <= 0 then return nil end

        local thresholdPercent = math.clamp(tonumber(_G.BigCoinThreshold) or 65, 10, 100)
        return bigCoinHealthAnchor * (thresholdPercent / 100)
    end

    local function rememberAcceptedPet(petId, coin)
        petId = tostring(petId)
        if targetIsAlive(coin) then
            petAssignments[petId] = {
                Coin = coin,
                AssignedAt = os.clock()
            }
            return true
        end
        return false
    end

    local function adoptServerAssignments(equippedPetSet)
        local targets = getServerCoinTargets()
        if type(targets) ~= "table" then return end

        for petId, target in pairs(targets) do
            petId = tostring(petId)
            if equippedPetSet[petId] and type(target) == "table" and target.t == "Coin" then
                local coin = findCoinByNetworkId(target.id)
                if coin then rememberAcceptedPet(petId, coin) end
            end
        end
    end

    local function countPendingSlots()
        local count = 0
        for _, request in pairs(pendingRequests) do
            local confirmedCount = 0
            for _ in pairs(request.ConfirmedPets or {}) do
                confirmedCount = confirmedCount + 1
            end
            count = count + math.max(0, (request.Slots or 1) - confirmedCount)
        end
        return count
    end

    local function hasUnconfirmedRequest()
        for _, request in pairs(pendingRequests) do
            local confirmedCount = 0
            for _ in pairs(request.ConfirmedPets or {}) do
                confirmedCount = confirmedCount + 1
            end
            if confirmedCount < (request.Slots or 1) then
                return true
            end
        end
        return false
    end

    local function countActiveAssignments(equippedPetSet)
        local count = 0
        for petId, state in pairs(petAssignments) do
            if equippedPetSet[petId] and targetIsAlive(state.Coin) then
                count = count + 1
            end
        end
        return count
    end

    local function buildClaimedCoins()
        local claimedCoins = {}
        for _, state in pairs(petAssignments) do
            if targetIsAlive(state.Coin) then
                claimedCoins[state.Coin] = true
            end
        end
        for _, request in pairs(pendingRequests) do
            if targetIsAlive(request.Coin) then
                claimedCoins[request.Coin] = true
            end
        end
        return claimedCoins
    end

    local function beginSelection(coin, slots, selectAll)
        local key = getRequestKey(coin)
        if not key or pendingRequests[key] or not targetIsAlive(coin) then return false end

        pendingRequests[key] = {
            Coin = coin,
            Slots = slots,
            ConfirmedPets = {},
            StartedAt = os.clock()
        }

        local selected = selectAll and selectCoinWithAllPets(coin)
            or selectCoinWithOnePet(coin)
        if not selected then
            pendingRequests[key] = nil
            rejectedTargets[coin] = os.clock() + FAILURE_COOLDOWN
            return false
        end
        return true
    end

    while false and task.wait(0.02) do
        if not isScriptRunning() then break end

        local currentThings = workspace:FindFirstChild("__THINGS")
        coinsFolder = currentThings and currentThings:FindFirstChild("Coins")

        if not _G.AutoPetCoins then
            resetAllState()
            autoWasEnabled = false
            previousMode = _G.PetFarmMode
            previousContext = getFarmContextKey()
            continue
        end

        local now = os.clock()
        local mode = _G.PetFarmMode or "DifferentStrongest"
        local context = getFarmContextKey()
        if mode ~= previousMode or context ~= previousContext then
            resetTransientState()
            previousMode = mode
            previousContext = context
        end

        local equippedPetIds = getEquippedPetIds()
        local equippedPetSet = {}
        for _, rawPetId in ipairs(equippedPetIds) do
            equippedPetSet[tostring(rawPetId)] = true
        end

        if #equippedPetIds == 0 then
            resetAllState()
            continue
        end

        if not autoWasEnabled then
            adoptServerAssignments(equippedPetSet)
            autoWasEnabled = true
        end

        local livePetCoins = readLiveCoinPetAssignments(equippedPetSet)
        for petId, liveCoin in pairs(livePetCoins) do
            local liveKey = getRequestKey(liveCoin)
            local request = liveKey and pendingRequests[liveKey]
            if request then
                request.ConfirmedPets[petId] = true
            end
            local state = petAssignments[petId]
            if not state or not targetIsAlive(state.Coin) then
                rememberAcceptedPet(petId, liveCoin)
            end
        end

        local releasedAny = false
        for petId, state in pairs(petAssignments) do
            if not equippedPetSet[petId] or not targetIsAlive(state.Coin) then
                petAssignments[petId] = nil
                releasedAny = true
            end
        end

        if releasedAny then
            releaseNeedsSync = true
            releaseReadyAt = math.max(releaseReadyAt, now + RELEASE_FRAME_DELAY)
        end

        for key, request in pairs(pendingRequests) do
            if not targetIsAlive(request.Coin) then
                pendingRequests[key] = nil
            elseif now - (request.StartedAt or now) >= 0.45 then
                local confirmedCount = 0
                for _ in pairs(request.ConfirmedPets or {}) do
                    confirmedCount = confirmedCount + 1
                end

                pendingRequests[key] = nil
                if confirmedCount == 0 and targetIsAlive(request.Coin) then
                    rejectedTargets[request.Coin] = now + FAILURE_COOLDOWN
                end
            end
        end

        for coin, expiresAt in pairs(rejectedTargets) do
            if not coin.Parent or now >= expiresAt then
                rejectedTargets[coin] = nil
            end
        end

        if releaseNeedsSync then
            if now < releaseReadyAt then continue end

            local library = getPSXLibrary()
            if library and type(library.RenderStepped) == "function" then
                pcall(library.RenderStepped)
            else
                task.wait()
            end
            releaseNeedsSync = false
        end

        local activeCount = countActiveAssignments(equippedPetSet)
        local pendingSlots = countPendingSlots()
        local availableSlots = math.max(0, #equippedPetIds - activeCount - pendingSlots)
        if availableSlots == 0 then continue end
        if hasUnconfirmedRequest() then continue end

        local isGroupMode = mode == "AllOneBossChest" or mode == "AllOneBigCoin"
        if isGroupMode then
            if lockedGroupCoin and not targetIsAlive(lockedGroupCoin) then
                lockedGroupCoin = nil
            end

            if not lockedGroupCoin then
                if mode == "AllOneBossChest" then
                    lockedGroupCoin = getStrongestBossChest(rejectedTargets)
                else
                    local minimumHealth = updateBigCoinHealthAnchor()
                    if minimumHealth then
                        lockedGroupCoin = getStrongestRegularTarget({}, rejectedTargets, minimumHealth)
                    end
                end
            end

            if not lockedGroupCoin or rejectedTargets[lockedGroupCoin] then continue end

            if activeCount == 0 and pendingSlots == 0 then
                beginSelection(lockedGroupCoin, #equippedPetIds, true)
            else
                beginSelection(lockedGroupCoin, 1, false)
            end
            continue
        end

        local claimedCoins = buildClaimedCoins()
        local coin
        if mode == "DifferentWeakest" then
            coin = getWeakestRegularTarget(claimedCoins, rejectedTargets)
        else
            coin = getStrongestRegularTarget(claimedCoins, rejectedTargets)
        end

        if coin then
            beginSelection(coin, 1, false)
        end
    end

end)

local function countFarmableTargetsInZone()
    if not coinsFolder then return 0 end
    local count = 0
    for _, coin in ipairs(coinsFolder:GetChildren()) do
        if coinCanBeFarmed(coin) and coinIsInLocation(coin) then
            count = count + 1
        end
    end
    return count
end

task.spawn(function()
    while task.wait(0.25) do
        if not isScriptRunning() then break end
        refreshZoneDropdown(false)
        local loadedWorld = getCurrentWorldName()
        local selectedWorld = getSelectedFarmWorld() or "мир не определён"
        local zoneName = getSelectedFarmZone() or "зона не определена"
        local targetCount = countFarmableTargetsInZone()
        pcall(function()
            currentZoneParagraph:SetDesc(
                "Загружен: " .. loadedWorld
                .. " | фильтр: " .. selectedWorld .. " / " .. zoneName
                .. " | целей: " .. tostring(targetCount)
            )
        end)
    end
end)

task.spawn(function()
    while task.wait(0.2) do
          if not isScriptRunning() then break end
  
          local root = localPlayer.Character and localPlayer.Character:FindFirstChild("HumanoidRootPart")
          
          if root then
              if _G.AutoOrbs and orbsFolder then
                  local orbs = orbsFolder:GetChildren()
                  for i = 1, math.min(#orbs, 30) do
                      local orb = orbs[i]
                      pcall(function()
                          local p = orb:IsA("BasePart") and orb or orb:FindFirstChildOfClass("BasePart")
                          if p then
                              p.CanCollide = false
                              p.Transparency = 1
                              p.CFrame = root.CFrame * CFrame.new(0, -3, 0)
                              if firetouchinterest then
                                  firetouchinterest(root, p, 0)
                                  firetouchinterest(root, p, 1)
                              end
                          end
                      end)
                  end
              end
               
              if _G.AutoLootbags and lootbagsFolder then
                  local lootbags = lootbagsFolder:GetChildren()
                  for i = 1, math.min(#lootbags, 15) do
                      local bag = lootbags[i]
                      pcall(function()
                          local p = bag:IsA("BasePart") and bag or bag:FindFirstChildOfClass("BasePart")
                          if p then
                              p.CanCollide = false
                              p.Transparency = 1
                              p.CFrame = root.CFrame * CFrame.new(0, -3, 0)
                              if firetouchinterest then
                                  firetouchinterest(root, p, 0)
                                  firetouchinterest(root, p, 1)
                              end
                          end
                      end)
                  end
              end
          end
      end
  end)
  
  -- ====================================================================================
  -- 3. АВТОБУСТЫ + ОЧЕРЕДЬ ЯИЦ + ПРОПУСК АНИМАЦИИ
  -- ====================================================================================
  task.spawn(function()
      while task.wait(1) do
          if not isScriptRunning() then break end
          refreshEggDropdown(false)
      end
  end)

  task.spawn(function()
      while task.wait(0.25) do
          if not isScriptRunning() then break end

          local saveData = getSaveData()
          local library = getPSXLibrary()
          local statusLines = {}

          if not saveData then
              table.insert(statusLines, "Library.Save ещё не загружен")
          else
              local activeBoosts = type(saveData.Boosts) == "table" and saveData.Boosts or {}
              local boostInventory = type(saveData.BoostsInventory) == "table" and saveData.BoostsInventory or {}
              local isTradingPlaza = library and library.Shared and library.Shared.IsTradingPlaza == true
              local now = os.clock()
              table.insert(statusLines, string.format(
                  "Основной: Network.Fire | запасной: remote [%s], %s",
                  tostring(boostDirectRemoteIndex or "?"),
                  tostring(boostDirectRemoteSource)
              ))

              local boostSentThisTick = false
              for _, definition in ipairs(boostDefinitions) do
                  local boostName = resolveBoostName(saveData, definition)
                  local remaining = tonumber(activeBoosts[boostName]) or 0
                  local inventoryCount = tonumber(boostInventory[boostName]) or 0
                  local enabled = _G.EnabledBoosts[definition.key] == true
                  local state = "ожидание"
                  local pending = boostPendingConfirmation[definition.key]
                  local confirmedThisTick = false
                  local timedOutMethod = nil

                  if pending then
                      local inventoryChanged = inventoryCount < pending.inventory
                      local timerChanged = remaining > pending.remaining
                      if inventoryChanged or timerChanged then
                          boostLastConfirmedMethod[definition.key] = pending.method
                          boostPendingConfirmation[definition.key] = nil
                          boostNextAttempt[definition.key] = now + 0.2
                          pending = nil
                          confirmedThisTick = true
                      elseif now - pending.sentAt >= 0.75 then
                          timedOutMethod = pending.method
                          boostPendingConfirmation[definition.key] = nil
                          pending = nil
                          if timedOutMethod == "direct"
                              and not tostring(boostDirectRemoteSource):find("captured from Network.Fire", 1, true) then
                              networkRemoteCache["RemoteEvent\0Activate Boost"] = nil
                          end
                      end
                  end

                  if confirmedThisTick then
                      state = "применение подтверждено Save"
                  elseif not enabled then
                      state = "выкл"
                  elseif not _G.AutoBoosts then
                      state = "автобуст выключен"
                  elseif isTradingPlaza then
                      state = "пауза: Trading Plaza"
                  elseif inventoryCount <= 0 then
                      state = "нет в инвентаре"
                  elseif remaining > (tonumber(_G.BoostRenewBefore) or 5) then
                      state = "ждём последние секунды"
                  elseif pending then
                      state = "команда отправлена, ждём Save"
                  elseif now < (boostNextAttempt[definition.key] or 0) then
                      state = "короткая пауза после подтверждения"
                  elseif boostSentThisTick then
                      state = "очередь на следующий цикл"
                  else
                      local sent, sendMethod
                      local methodKind

                      if timedOutMethod == "Network.Fire" or timedOutMethod == "direct" then
                          sent, sendMethod = sendBoostThroughDirectFallback(boostName)
                          methodKind = "direct"
                      else
                          sent, sendMethod = sendBoostThroughNetwork(library, boostName)
                          methodKind = "Network.Fire"
                          if not sent then
                              sent, sendMethod = sendBoostThroughDirectFallback(boostName)
                              methodKind = "direct"
                          end
                      end

                      if sent then
                          boostSentThisTick = true
                          boostPendingConfirmation[definition.key] = {
                              inventory = inventoryCount,
                              remaining = remaining,
                              sentAt = now,
                              method = methodKind
                          }
                          state = "отправлено через " .. tostring(sendMethod) .. ", ждём Save"
                      else
                          state = "ошибка отправки: " .. tostring(sendMethod)
                          boostNextAttempt[definition.key] = now + 0.75
                      end
                  end

                  table.insert(statusLines, string.format(
                      "%s: %s | запас %d | %s%s",
                      definition.title,
                      formatBoostTime(remaining),
                      inventoryCount,
                      state,
                      boostLastConfirmedMethod[definition.key]
                          and (" | последнее: " .. boostLastConfirmedMethod[definition.key])
                          or ""
                  ))
              end
          end

          if boostStatusParagraph then
              pcall(function()
                  boostStatusParagraph:SetDesc(table.concat(statusLines, "\n"))
              end)
          end
      end
  end)

  task.spawn(function()
      local lastRenderedStatus = nil
      local nextStatusRender = 0

      while task.wait(1) do
          if not isScriptRunning() then break end

          local rankEnabled = _G.AutoRankRewards == true
          local vipEnabled = _G.AutoVIPRewards == true
          if not rankEnabled and not vipEnabled then
              local disabledStatus = "Автосбор выключен"
              if lastRenderedStatus ~= disabledStatus and miscRewardStatusParagraph then
                  lastRenderedStatus = disabledStatus
                  pcall(function()
                      miscRewardStatusParagraph:SetDesc(disabledStatus)
                  end)
              end
              continue
          end

          local library = getPSXLibrary()
          local saveData = getSaveData()
          local statusLines = {}
          local now = os.clock()

          if not library or not saveData then
              table.insert(statusLines, "Ожидание Library.Save...")
          else
              local serverNow = getRewardServerTime(library)

              local rankInfo = library.Directory
                  and library.Directory.Ranks
                  and library.Directory.Ranks[saveData.Rank]
              if not rankEnabled then
                  table.insert(statusLines, "Rank Rewards: выкл")
              elseif not rankInfo then
                  table.insert(statusLines, "Rank Rewards: данные текущего ранга не найдены")
              elseif type(rankInfo.rewards) == "table" and #rankInfo.rewards == 0 then
                  table.insert(statusLines, "Rank Rewards: у текущего ранга нет награды")
              else
                  local rankCooldown = tonumber(rankInfo.rewardCooldown) or 0
                  local rankTimer = tonumber(saveData.RankTimer) or 0
                  local rankRemaining = math.max(0, rankCooldown - (serverNow - rankTimer))
                  local rankState = rankRemaining > 0
                      and ("через " .. formatBoostTime(rankRemaining))
                      or "готово"

                  if rankRemaining <= 0
                      and now >= (rewardNextAttempt["Redeem Rank Rewards"] or 0) then
                      rewardNextAttempt["Redeem Rank Rewards"] = now + 30
                      local success, method = invokeAutoReward(library, "Redeem Rank Rewards")
                      rewardLastResult["Redeem Rank Rewards"] = success
                          and ("забрано через " .. tostring(method))
                          or ("ошибка: " .. tostring(method))
                  end

                  table.insert(statusLines, string.format(
                      "Rank Rewards: вкл | %s%s",
                      rankState,
                      rewardLastResult["Redeem Rank Rewards"]
                          and (" | " .. rewardLastResult["Redeem Rank Rewards"])
                          or ""
                  ))
              end

              if not vipEnabled then
                  table.insert(statusLines, "VIP Rewards: выкл")
              else
                  local vipCooldown = 14400
                  local vipTimer = tonumber(saveData.VIPCooldown) or 0
                  local vipRemaining = math.max(0, vipCooldown - (serverNow - vipTimer))
                  local vipState = vipRemaining > 0
                      and ("через " .. formatBoostTime(vipRemaining))
                      or "готово"

                  if vipRemaining <= 0
                      and now >= (rewardNextAttempt["Redeem VIP Rewards"] or 0) then
                      rewardNextAttempt["Redeem VIP Rewards"] = now + 30
                      local success, method = invokeAutoReward(library, "Redeem VIP Rewards")
                      rewardLastResult["Redeem VIP Rewards"] = success
                          and ("забрано через " .. tostring(method))
                          or ("ошибка: " .. tostring(method))
                  end

                  table.insert(statusLines, string.format(
                      "VIP Rewards: вкл | %s%s",
                      vipState,
                      rewardLastResult["Redeem VIP Rewards"]
                          and (" | " .. rewardLastResult["Redeem VIP Rewards"])
                          or ""
                  ))
              end
          end

          local statusText = table.concat(statusLines, "\n")
          if miscRewardStatusParagraph
              and statusText ~= lastRenderedStatus
              and now >= nextStatusRender then
              lastRenderedStatus = statusText
              nextStatusRender = now + 5
              pcall(function()
                  miscRewardStatusParagraph:SetDesc(statusText)
              end)
          end
      end
  end)

  local function setEggStatus(text)
      eggStatusText = tostring(text or "")
      if eggStatusParagraph then
          pcall(function() eggStatusParagraph:SetDesc(eggStatusText) end)
      end
  end

  local fastEggEventCount = 0
  local fastEggConnection = nil
  local lastEggServerEventAt = 0

  local function installFastEggEventListener()
      local library = getPSXLibrary()
      local network = library and library.Network
      if not network or type(network.Fired) ~= "function" or type(network.Fire) ~= "function" then
          return false
      end

      local previousState = env.PSX_OG_FastEggState
      if previousState and previousState.Token ~= runToken then
          local previousConnection = previousState.Connection
          if previousConnection and type(previousConnection.Disconnect) == "function" then
              pcall(function() previousConnection:Disconnect() end)
          end
      end
      env.PSX_OG_FastEggState = nil

      local success, signal = pcall(network.Fired, "Open Egg")
      if not success or not signal or type(signal.Connect) ~= "function" then
          return false
      end

      local function onOpenEgg(eggId, pets)
          if not isScriptRunning() or not _G.AutoEgg then return end

          fastEggEventCount = fastEggEventCount + 1
          lastEggServerEventAt = os.clock()

          if not _G.SkipAnim then
              setEggStatus(string.format(
                  "Сервер открыл: %s | ожидаю завершения штатной анимации",
                  tostring(eggId)
              ))
              return
          end

          -- Оригинальный визуальный callback пропускается через OpeningEgg=true,
          -- но серверное подтверждение из ProcessEggQueue сохраняем.
          if not fastEggGateArmed then
              -- Первое событие обрабатывает уже подключённый штатный Open Eggs callback.
              -- После его немедленного Opening Egg ACK блокируем только следующие анимации.
              fastEggGateArmed = true
              setEggAnimationGate(true)
              setEggStatus("Первое Open Egg получено — быстрый режим активирован")
              return
          end

          setEggAnimationGate(true)
          pcall(network.Fire, "Opening Egg", eggId, pets)
          setEggStatus(string.format(
              "Быстро открыто: %s | серверных событий %d",
              tostring(eggId),
              fastEggEventCount
          ))
      end

      local connected, connection = pcall(function()
          return signal:Connect(onOpenEgg)
      end)
      if not connected or not connection then
          return false
      end
      fastEggConnection = connection

      env.PSX_OG_FastEggState = {
          Token = runToken,
          Connection = fastEggConnection
      }
      return true
  end

  local eggRequestInFlight = false
  local nextEggRequestAt = 0
  local eggRequestStartedAt = 0
  local eggRequestSequence = 0
  local initialListenerOk, initialListenerResult = pcall(installFastEggEventListener)
  local fastEggListenerInstalled = initialListenerOk and initialListenerResult == true
  local nextFastEggListenerAttempt = fastEggListenerInstalled and math.huge or (os.clock() + 1)

  local function syncEggToggleState()
      local skipValue = SkipAnimToggle and SkipAnimToggle.Value
      local autoValue = AutoEggToggle and AutoEggToggle.Value

      if type(skipValue) == "boolean" and _G.SkipAnim ~= skipValue then
          _G.SkipAnim = skipValue
          fastEggGateArmed = false
          setEggAnimationGate(false)
      end

      if type(autoValue) == "boolean" and _G.AutoEgg ~= autoValue then
          _G.AutoEgg = autoValue
          fastEggGateArmed = false
          setEggAnimationGate(false)
          if _G.AutoEgg then
              setEggStatus("Автооткрытие включено — подготовка Buy Egg Yay...")
          else
              eggRequestSequence = eggRequestSequence + 1
              eggRequestInFlight = false
              setEggStatus("Автооткрытие выключено")
          end
      end
  end

  task.spawn(function()
      while task.wait(0.03) do
          if not isScriptRunning() then break end

          syncEggToggleState()
          local now = os.clock()

          if not fastEggListenerInstalled and now >= nextFastEggListenerAttempt then
              nextFastEggListenerAttempt = now + 1
              local listenerOk, listenerResult = pcall(installFastEggEventListener)
              fastEggListenerInstalled = listenerOk and listenerResult == true
          end

          if eggRequestInFlight and now - eggRequestStartedAt >= 5 then
              local receivedOpenEvent = lastEggServerEventAt >= eggRequestStartedAt
              eggRequestSequence = eggRequestSequence + 1
              eggRequestInFlight = false
              _G.AutoEgg = false
              setEggAnimationGate(false)
              if AutoEggToggle and type(AutoEggToggle.Set) == "function" then
                  pcall(function() AutoEggToggle:Set(false) end)
              end
              setEggStatus(receivedOpenEvent
                  and "Таймаут: Open Egg пришёл, но Buy Egg Yay не завершился; автооткрытие остановлено"
                  or "Таймаут: сервер не прислал Open Egg; автооткрытие остановлено")
          end

          if _G.AutoEgg and not eggRequestInFlight and now >= nextEggRequestAt then
              if _G.SkipAnim and not fastEggListenerInstalled then
                  setEggStatus("Ожидаю подключения Library.Network.Fired(\"Open Egg\")...")
                  continue
              end

              local library = getPSXLibrary()
              local openingEgg = library and library.Variables and library.Variables.OpeningEgg == true

              -- Штатный Open Eggs отбрасывает новые события, пока идёт предыдущая анимация.
              -- Быстрый режим обрабатывает Open Egg сам; обычный обязан дождаться OpeningEgg=false.
              if openingEgg and not _G.SkipAnim then
                  setEggStatus("Ожидаю завершения текущей анимации яйца...")
                  continue
              end

              eggRequestInFlight = true
              eggRequestStartedAt = now
              eggRequestSequence = eggRequestSequence + 1
              local requestId = eggRequestSequence
              local targetEgg = _G.TargetEgg
              local triple = _G.EggOpenMode == "Triple"
              nextEggRequestAt = now + math.max(0.06, tonumber(_G.EggDelay) or 0.12)
              setEggStatus(string.format(
                  "Отправляю Buy Egg Yay: %s (%s)",
                  tostring(targetEgg),
                  triple and "x3" or "x1"
              ))

              task.spawn(function()
                  local workerOk, success, message = pcall(openEgg, targetEgg, triple)
                  if requestId ~= eggRequestSequence then return end

                  if not workerOk then
                      setEggStatus("Ошибка openEgg: " .. tostring(success))
                      nextEggRequestAt = math.max(nextEggRequestAt, os.clock() + 0.5)
                  elseif success then
                      setEggStatus(tostring(message) .. " — " .. tostring(targetEgg))
                  else
                      setEggStatus(tostring(message or "Сервер отклонил открытие"))
                      -- Ошибки покупки (дистанция, валюта, геймпасс) не спамим каждый кадр.
                      nextEggRequestAt = math.max(nextEggRequestAt, os.clock() + 0.5)
                  end

                  eggRequestInFlight = false
              end)
          elseif not _G.AutoEgg and eggStatusText ~= "Автооткрытие выключено" then
              setEggAnimationGate(false)
              setEggStatus("Автооткрытие выключено")
          end
      end
      if env.PSX_OG_RunToken == nil or env.PSX_OG_RunToken == runToken then
          fastEggGateArmed = false
          setEggAnimationGate(false)
      end
      if fastEggConnection and type(fastEggConnection.Disconnect) == "function" then
          pcall(function() fastEggConnection:Disconnect() end)
      end
      local currentState = env.PSX_OG_FastEggState
      if currentState and currentState.Token == runToken then
          env.PSX_OG_FastEggState = nil
      end
  end)

  local lastEggGuiScan = 0

  local function hideEggAnimationObject(object)
      if object:IsA("ScreenGui") then
          object.Enabled = false
      elseif object:IsA("GuiObject") then
          object.Visible = false
      end
  end

  trackRunConnection(RunService.RenderStepped:Connect(function()
      if not isScriptRunning() then return end

      local shouldBlockAnimation = _G.SkipAnim and _G.AutoEgg and fastEggGateArmed

      pcall(function()
          local library = getPSXLibrary()
          if shouldBlockAnimation and library and library.Variables then
              -- Open Eggs.lua сразу выходит из обработчика "Open Egg", когда флаг уже true.
              library.Variables.OpeningEgg = true
          end

          if not shouldBlockAnimation then return end

          local libraryEggUI = library and library.GUI and library.GUI.EggOpenInfo
          if libraryEggUI then
              if libraryEggUI.Gui then libraryEggUI.Gui.Enabled = false end
              if libraryEggUI.SkipLabel then libraryEggUI.SkipLabel.Visible = false end
          end

          local PlayerGui = localPlayer:FindFirstChild("PlayerGui")
          if PlayerGui then
              local eggUI = PlayerGui:FindFirstChild("Egg Open Info", true)
              if eggUI then
                  hideEggAnimationObject(eggUI)
              end

              if os.clock() - lastEggGuiScan >= 0.1 then
                  lastEggGuiScan = os.clock()
                  for _, object in ipairs(PlayerGui:GetDescendants()) do
                      local normalizedName = normalizeDataKey(object.Name)
                      if normalizedName:find("eggopen", 1, true)
                          or normalizedName:find("hatchanimation", 1, true) then
                          hideEggAnimationObject(object)
                      end
                  end
              end
          end

          for _, object in ipairs(camera:GetChildren()) do
              local normalizedName = normalizeDataKey(object.Name)
              if object:IsA("Model")
                  and (normalizedName:find("egg", 1, true) or normalizedName:find("hatch", 1, true)) then
                  for _, descendant in ipairs(object:GetDescendants()) do
                      if descendant:IsA("BasePart") then
                          descendant.LocalTransparencyModifier = 1
                      end
                  end
              end
          end

          if camera.CameraType == Enum.CameraType.Scriptable and not _G.AutoFarm then
              local character = localPlayer.Character
              local humanoid = character and character:FindFirstChildOfClass("Humanoid")
              camera.CameraType = Enum.CameraType.Custom
              if humanoid then camera.CameraSubject = humanoid end
          end
      end)
  end))
  
  -- ====================================================================================
  -- 4. СЧЁТЧИК ФАРМА ВАЛЮТЫ ЗА МИНУТУ
  -- ====================================================================================
  task.spawn(function()
      local lastCurrencyName = _G.TrackedCurrency
  
      while task.wait(1) do
          if not isScriptRunning() then break end
  
          if lastCurrencyName ~= _G.TrackedCurrency then
              lastCurrencyName = _G.TrackedCurrency
              table.clear(currencySamples)
          end
  
          local targetCount = countFarmableTargetsInZone()
          if not _G.AutoFarm and not _G.AutoPetCoins then
              table.clear(currencySamples)
  
              if currencyTrackerLabel then
                  pcall(function()
                      currencyTrackerLabel:Set(
                          _G.TrackedCurrency .. "/мин: фарм выключен"
                          .. " | целей в зоне: " .. tostring(targetCount)
                      )
                  end)
              end
          else
              local currentAmount = getCurrentCurrency(_G.TrackedCurrency)
  
              if currentAmount == nil then
                  table.clear(currencySamples)
  
                  if currencyTrackerLabel then
                      pcall(function()
                          currencyTrackerLabel:Set(
                              _G.TrackedCurrency .. "/мин: валюта не найдена"
                              .. " | целей в зоне: " .. tostring(targetCount)
                          )
                      end)
                  end
              else
                  local now = os.clock()
                  local previousSample = currencySamples[#currencySamples]
  
                  -- После покупки/траты начинаем новое окно, чтобы не показывать отрицательный фарм.
                  if previousSample and currentAmount < previousSample.Value then
                      table.clear(currencySamples)
                  end
  
                  table.insert(currencySamples, {
                      Time = now,
                      Value = currentAmount
                  })
  
                  while #currencySamples > 1 and now - currencySamples[1].Time > 60 do
                      table.remove(currencySamples, 1)
                  end
  
                  local firstSample = currencySamples[1]
                  local elapsed = now - firstSample.Time
                  local gained = math.max(0, currentAmount - firstSample.Value)
                  local perMinute = elapsed > 0 and (gained / elapsed) * 60 or 0
  
                  if currencyTrackerLabel then
                      pcall(function()
                          if elapsed < 2 then
                              currencyTrackerLabel:Set(
                                  _G.TrackedCurrency .. "/мин: сбор данных..."
                                  .. " | целей в зоне: " .. tostring(targetCount)
                              )
                          else
                              currencyTrackerLabel:Set(
                                  _G.TrackedCurrency .. "/мин: " .. formatCurrency(perMinute)
                                  .. " | получено: +" .. formatCurrency(gained)
                                  .. " | целей в зоне: " .. tostring(targetCount)
                              )
                          end
                      end)
                  end
              end
          end
      end
  end)
  
  -- ====================================================================================
  -- 5. АНТИ-АФК
  -- ====================================================================================
  local VirtualUser = game:GetService("VirtualUser")
  trackRunConnection(localPlayer.Idled:Connect(function()
      if isScriptRunning() then
          VirtualUser:Button2Down(Vector2.new(0,0), camera.CFrame)
          task.wait(0.5)
          VirtualUser:Button2Up(Vector2.new(0,0), camera.CFrame)
      end
  end))
  
  pcall(function() OverviewTab:Select() end)
